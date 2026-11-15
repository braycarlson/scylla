const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Buffer = @import("../stdx/bounded/buffer.zig");
const EventsType = @import("../syntax/tree.zig").EventsType;
const Formatter = @import("zig.zig").Formatter;
const FormatterError = @import("formatters.zig").FormatterError;
const Input = @import("zig.zig").Input;
const Kind = @import("../syntax/zig/kind.zig").Kind;
const Parser = @import("../syntax/zig/parse.zig").Parser;
const Span = @import("../stdx/bounded/span.zig");
const Structure = @import("../syntax/tree.zig").Structure;
const Token = @import("../syntax/token.zig");
const Tokens = @import("../syntax/tokens.zig");
const TreeType = @import("../syntax/tree.zig").TreeType;
const raw_of = @import("../syntax/raw.zig").raw_of;
const corpus = @import("../testing/corpus.zig");
const environment = @import("../testing/environment.zig");
const floor = @import("../testing/floor.zig");
const lex = @import("../syntax/lex.zig").lex;
const oracle = @import("../testing/oracle.zig");
const stripe = @import("../testing/stripe.zig");
const walk = @import("walk.zig");
const Events = EventsType(Kind);
const HeldError = FormatterError || error{Truncated};
const Tree = TreeType(Kind);

const Held = struct {
    events: *Events,
    formatter: Formatter,
    parser: *Parser,
    raw: ArrayType(Kind),
    tokens: Tokens,
    tree: Tree,

    fn init(held: *Held, gpa: std.mem.Allocator) !void {
        held.events = try gpa.create(Events);
        errdefer gpa.destroy(held.events);

        try held.events.init(gpa, event_count_max);
        errdefer held.events.deinit(gpa);

        held.formatter = try .init(gpa, element_count_max, out_bytes_max);
        errdefer held.formatter.deinit(gpa);

        held.parser = try gpa.create(Parser);
        errdefer gpa.destroy(held.parser);

        held.raw = try .init(gpa, token_count_max);
        errdefer held.raw.deinit(gpa);

        held.tokens = try .init(gpa, token_count_max);
        errdefer held.tokens.deinit(gpa);

        held.tree = try .init(gpa, node_count_max, diagnostic_count_max);

        assert(held.raw.capacity() == held.tokens.items.capacity());
        assert(held.tree.count() == 0);
    }

    fn deinit(held: *Held, gpa: std.mem.Allocator) void {
        assert(held.raw.capacity() == token_count_max);
        assert(held.tokens.items.capacity() == token_count_max);

        held.tree.deinit(gpa);
        held.tokens.deinit(gpa);
        held.raw.deinit(gpa);
        gpa.destroy(held.parser);
        held.formatter.deinit(gpa);
        held.events.deinit(gpa);
        gpa.destroy(held.events);
        held.* = undefined;
    }

    fn format(held: *Held, source: []const u8, out: *Buffer) HeldError!void {
        assert(source.len <= std.math.maxInt(u32));

        try held.classified(source);

        const outcome = held.parsed(source);
        const input = held.input_of(source, outcome);

        assert(input.tokens.len == input.raw.len);
        assert(input.source.ptr == source.ptr);

        return held.formatter.format(&input, out);
    }

    fn range(
        held: *Held,
        source: []const u8,
        lines: walk.LineRange,
        out: *Buffer,
    ) HeldError!Span {
        assert(lines.first <= lines.last);
        assert(source.len <= std.math.maxInt(u32));

        try held.classified(source);

        const outcome = held.parsed(source);
        const input = held.input_of(source, outcome);

        assert(input.tokens.len == input.raw.len);

        return held.formatter.range(&input, lines, out);
    }

    fn input_of(held: *const Held, source: []const u8, outcome: Structure) Input {
        assert(held.raw.count() == held.tokens.count());
        assert(source.len <= std.math.maxInt(u32));
        if (outcome == .complete) assert(held.tree.count() > 0);

        return .{
            .options = .default,
            .outcome = outcome,
            .raw = held.raw.const_slice(),
            .source = source,
            .tokens = held.tokens.slice(),
            .tree = &held.tree,
        };
    }

    fn parsed(held: *Held, source: []const u8) Structure {
        const tokens = held.tokens.slice();
        const raw = held.raw.const_slice();

        assert(tokens.len == raw.len);
        assert(source.len <= std.math.maxInt(u32));

        return held.parser.build(source, tokens, raw, held.events, &held.tree);
    }

    fn classified(held: *Held, source: []const u8) error{Truncated}!void {
        assert(source.len <= std.math.maxInt(u32));

        held.tokens.clear();

        lex(.of(.zig), source, &held.tokens) catch |err| switch (err) {
            error.Truncated => assert(held.tokens.items.full()),
        };

        try raw_of(Kind, held.tokens.slice(), &held.raw);

        assert(held.raw.count() == held.tokens.count());
        assert(held.raw.count() <= token_count_max);
    }

    fn words(held: *Held, arena: std.mem.Allocator, source: []const u8) ![]const []const u8 {
        assert(source.len <= std.math.maxInt(u32));

        held.classified(source) catch unreachable;

        const tokens = held.tokens.slice();
        var listed: std.ArrayList([]const u8) = try .initCapacity(arena, tokens.len);

        for (tokens) |token| {
            const structural = token.kind == .block_end or token.kind == .block_start or
                token.kind == .newline;

            if (structural) continue;
            if (token.length == 0) continue;

            listed.appendAssumeCapacity(word_of(token, source));
        }

        assert(listed.items.len <= tokens.len);
        assert(listed.capacity >= tokens.len);

        return listed.items;
    }

    fn kinds(
        held: *Held,
        gpa: std.mem.Allocator,
        source: []const u8,
        found: *std.ArrayList(Kind),
    ) !void {
        assert(source.len <= std.math.maxInt(u32));

        try held.classified(source);

        const raw = held.raw.const_slice();

        found.clearRetainingCapacity();
        try found.ensureTotalCapacity(gpa, raw.len);

        for (raw) |kind| {
            if (kinds_skipped(kind)) continue;

            found.appendAssumeCapacity(kind);
        }

        assert(found.items.len <= raw.len);
        assert(raw.len == held.tokens.count());
    }

    fn comments(
        held: *Held,
        gpa: std.mem.Allocator,
        source: []const u8,
        text: *std.ArrayList(u8),
        ends: *std.ArrayList(u32),
    ) !void {
        assert(source.len <= std.math.maxInt(u32));

        try held.classified(source);

        const raw = held.raw.const_slice();
        const tokens = held.tokens.slice();

        assert(raw.len == tokens.len);

        text.clearRetainingCapacity();
        ends.clearRetainingCapacity();

        for (raw, tokens) |kind, token| {
            if (kind != .comment) continue;

            try text.appendSlice(gpa, std.mem.trimEnd(u8, token.text(source), ascii_whitespace));
            try ends.append(gpa, @intCast(text.items.len));
        }

        assert(ends.items.len <= raw.len);
        assert(text.items.len <= source.len);
    }
};

const Twice = struct {
    first: Buffer,
    held: Held,
    second: Buffer,

    fn init(twice: *Twice, gpa: std.mem.Allocator) !void {
        twice.first = try .init(gpa, out_bytes_max);
        errdefer twice.first.deinit(gpa);

        try twice.held.init(gpa);
        errdefer twice.held.deinit(gpa);

        twice.second = try .init(gpa, out_bytes_max);

        assert(twice.first.empty());
        assert(twice.second.empty());
    }

    fn deinit(twice: *Twice, gpa: std.mem.Allocator) void {
        assert(twice.first.capacity() == out_bytes_max);
        assert(twice.second.capacity() == out_bytes_max);

        twice.second.deinit(gpa);
        twice.held.deinit(gpa);
        twice.first.deinit(gpa);
        twice.* = undefined;
    }
};

const RelationsWorker = struct {
    gpa: std.mem.Allocator,
    relations: Relations,
    twice: Twice,

    pub const Item = Fixture;
    pub const Shared = struct {};
    pub const Tally = struct {};
    pub const weight = Fixture.weight;

    pub fn init(worker: *RelationsWorker, gpa: std.mem.Allocator, shared: *const Shared) !void {
        assert(@TypeOf(shared.*) == Shared);

        try worker.twice.init(gpa);

        worker.gpa = gpa;
        worker.relations = .empty;

        assert(worker.twice.first.empty());
    }

    pub fn deinit(worker: *RelationsWorker, gpa: std.mem.Allocator) void {
        assert(worker.twice.first.capacity() == out_bytes_max);

        worker.relations.deinit(gpa);
        worker.twice.deinit(gpa);
        worker.* = undefined;
    }

    pub fn visit(worker: *RelationsWorker, fixture: *const Fixture, tally: *Tally) !void {
        assert(fixture.name.len > 0);
        assert(@TypeOf(tally.*) == Tally);

        const twice = &worker.twice;

        twice.held.format(fixture.source, &twice.first) catch return;

        const once = twice.first.const_slice();

        try worker.relations.expect_kinds(worker.gpa, &twice.held, fixture, once);
        try worker.relations.expect_comments(worker.gpa, &twice.held, fixture, once);

        const second = twice.held.format(once, &twice.second);

        try require(is_complete(second), "{s}", .{fixture.name});
        try expect_text(fixture.name, "is not idempotent", once, twice.second.const_slice());
    }
};

const Relations = struct {
    comments_after: std.ArrayList(u8),
    comments_before: std.ArrayList(u8),
    ends_after: std.ArrayList(u32),
    ends_before: std.ArrayList(u32),
    kinds_after: std.ArrayList(Kind),
    kinds_before: std.ArrayList(Kind),

    const empty: Relations = .{
        .comments_after = .empty,
        .comments_before = .empty,
        .ends_after = .empty,
        .ends_before = .empty,
        .kinds_after = .empty,
        .kinds_before = .empty,
    };

    fn deinit(relations: *Relations, gpa: std.mem.Allocator) void {
        assert(relations.ends_after.items.len <= relations.ends_after.capacity);
        assert(relations.ends_before.items.len <= relations.ends_before.capacity);

        relations.comments_before.deinit(gpa);
        relations.comments_after.deinit(gpa);
        relations.kinds_before.deinit(gpa);
        relations.kinds_after.deinit(gpa);
        relations.ends_before.deinit(gpa);
        relations.ends_after.deinit(gpa);
        relations.* = undefined;
    }

    fn expect_kinds(
        relations: *Relations,
        gpa: std.mem.Allocator,
        held: *Held,
        fixture: *const Fixture,
        once: []const u8,
    ) !void {
        assert(once.len <= std.math.maxInt(u32));

        try held.kinds(gpa, fixture.source, &relations.kinds_before);
        try held.kinds(gpa, once, &relations.kinds_after);

        const before = relations.kinds_before.items;
        const after = relations.kinds_after.items;

        assert(before.len <= fixture.source.len);
        assert(after.len <= once.len);

        try require(before.len == after.len, "{s} lost a token", .{fixture.name});

        if (std.mem.eql(Kind, before, after)) return;

        std.debug.print("{s} lost or gained a token\n", .{fixture.name});

        return std.testing.expectEqualSlices(Kind, before, after);
    }

    fn expect_comments(
        relations: *Relations,
        gpa: std.mem.Allocator,
        held: *Held,
        fixture: *const Fixture,
        once: []const u8,
    ) !void {
        assert(once.len <= std.math.maxInt(u32));

        try held.comments(gpa, fixture.source, &relations.comments_before, &relations.ends_before);
        try held.comments(gpa, once, &relations.comments_after, &relations.ends_after);

        const before = relations.comments_before.items;
        const after = relations.comments_after.items;

        assert(before.len <= fixture.source.len);
        assert(after.len <= once.len);

        try expect_text(fixture.name, "lost a comment", before, after);
    }

    fn expect_comment_ends(relations: *const Relations, fixture: *const Fixture) !void {
        const before = relations.ends_before.items;
        const after = relations.ends_after.items;

        assert(before.len <= fixture.source.len);
        assert(std.mem.eql(u8, relations.comments_before.items, relations.comments_after.items));

        try require(std.mem.eql(u32, before, after), "{s} lost a comment", .{fixture.name});
    }
};

const Fixture = corpus.File;
const ascii_whitespace = " \t\n\x0c\r";
const casts = [_][]const u8{ "alignCast", "constCast", "ptrCast", "volatileCast" };
const dump_variable = "SCYLLA_FORMAT_DUMP";
const element_count_max: u32 = 1 << 18;
const diagnostic_count_max: u32 = 1 << 12;
const event_count_max: u32 = 1 << 20;
const every_category = [_][]const u8{ "zigfmt-declaration-context", "zigfmt-line-breaking" };
const extension = ".zig";
const file_count_max: u32 = 1 << 20;
const fixture_count_min: u32 = 4;
const fixture_root = "tests/fixtures/zig";
const golden_root = "tests/fixtures/golden-zigfmt";
const node_count_max: u32 = 1 << 18;
const out_bytes_max: u32 = 1 << 22;
const path_bytes_max: u32 = 4096;
const residue_name = "residue-format-zig.json";
const skipped_names = [_][]const u8{ "dedent", "indent", "newline" };
const source_bytes_max: u32 = 1 << 28;
const token_count_max: u32 = 1 << 18;

fn expect_formatted(source: []const u8, wanted: []const u8) !void {
    const gpa = std.testing.allocator;

    assert(source.len > 0);
    assert(wanted.len > 0);

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    try held.format(source, &out);
    try std.testing.expectEqualStrings(wanted, out.const_slice());

    var again: Buffer = try .init(gpa, out_bytes_max);
    defer again.deinit(gpa);

    try held.format(wanted, &again);
    try std.testing.expectEqualStrings(wanted, again.const_slice());
}

fn kinds_skipped(kind: Kind) bool {
    assert(kind.is_token());

    const name = kind.name();

    assert(name.len > 0);

    for (skipped_names) |skipped| {
        if (std.mem.eql(u8, name, skipped)) return true;
    }

    return false;
}

fn word_of(token: Token, source: []const u8) []const u8 {
    assert(token.length > 0);
    assert(token.end() <= source.len);

    if (token.kind == .string) return "<string>";

    const text = token.text(source);
    const name = std.mem.trimStart(u8, text, "@");

    for (casts) |cast| {
        if (std.mem.eql(u8, name, cast)) return "<cast>";
    }

    return text;
}

fn lines_of(bytes: []const u8, first: u32, last: u32) []const u8 {
    assert(first <= last);
    assert(bytes.len <= std.math.maxInt(u32));

    var line: u32 = 0;
    var start: usize = 0;
    var end: usize = bytes.len;

    for (bytes, 0..) |byte, offset| {
        if (byte != '\n') continue;

        line += 1;

        if (line == first) start = offset + 1;

        if (line == last + 1) {
            end = offset + 1;

            break;
        }
    }

    assert(start <= end);

    return bytes[start..end];
}

fn fixtures(gpa: std.mem.Allocator) !std.ArrayList(Fixture) {
    const io = std.testing.io;
    var found: std.ArrayList(Fixture) = .empty;
    errdefer fixtures_free(gpa, &found);

    var directory = try std.Io.Dir.cwd().openDir(io, fixture_root, .{ .iterate = true });
    defer directory.close(io);

    var iterator = directory.iterate();

    for (0..file_count_max) |_| {
        const entry = try iterator.next(io) orelse break;
        if (!std.mem.eql(u8, std.Io.Dir.path.extension(entry.name), extension)) continue;

        const limit: std.Io.Limit = .limited(source_bytes_max);
        const source = try directory.readFileAlloc(io, entry.name, gpa, limit);
        errdefer gpa.free(source);

        const name = try gpa.dupe(u8, entry.name);
        errdefer gpa.free(name);

        try found.append(gpa, .{ .name = name, .source = source });
    }

    std.mem.sort(Fixture, found.items, {}, fixture_less_than);

    try require(found.items.len > fixture_count_min, "{s} holds too few fixtures", .{fixture_root});

    assert(found.items.len <= file_count_max);
    assert(fixture_less_than({}, found.items[0], found.items[1]));

    return found;
}

fn corpus_selected(basename: []const u8) bool {
    assert(basename.len > 0);

    return std.mem.eql(u8, std.Io.Dir.path.extension(basename), extension);
}

fn fixtures_free(gpa: std.mem.Allocator, found: *std.ArrayList(Fixture)) void {
    assert(found.items.len <= found.capacity);
    assert(found.items.len <= file_count_max);

    for (found.items) |fixture| {
        gpa.free(fixture.name);
        gpa.free(fixture.source);
    }

    found.deinit(gpa);
    found.* = undefined;
}

fn fixture_less_than(context: void, left: Fixture, right: Fixture) bool {
    _ = context;

    assert(left.name.len > 0);
    assert(right.name.len > 0);

    return std.mem.lessThan(u8, left.name, right.name);
}

fn read_under(gpa: std.mem.Allocator, root: []const u8, name: []const u8) ![]u8 {
    assert(root.len > 0);
    assert(name.len > 0);

    var path_buffer: [path_bytes_max]u8 = undefined;
    const path = try std.mem.print(&path_buffer, "{s}/{s}", .{ root, name });
    const limit: std.Io.Limit = .limited(source_bytes_max);

    assert(path.len > name.len);

    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, limit);
}

fn write_under(root: []const u8, name: []const u8, data: []const u8) !void {
    assert(root.len <= std.math.maxInt(u32));
    assert(name.len > 0);
    assert(data.len <= std.math.maxInt(u32));

    var path_buffer: [path_bytes_max]u8 = undefined;
    const path = try std.mem.print(&path_buffer, "{s}/{s}", .{ root, name });

    assert(path.len == root.len + name.len + 1);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = data });
}

fn is_complete(result: HeldError!void) bool {
    if (std.meta.isError(result)) return false;

    return true;
}

fn require(condition: bool, comptime format: []const u8, arguments: anytype) !void {
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    if (condition) return;

    std.debug.print(format ++ "\n", arguments);

    return error.TestUnexpectedResult;
}

fn expect_text(
    name: []const u8,
    comptime message: []const u8,
    expected: []const u8,
    actual: []const u8,
) !void {
    comptime assert(message.len > 0);
    assert(name.len > 0);
    assert(expected.len <= std.math.maxInt(u32));
    assert(actual.len <= std.math.maxInt(u32));

    if (std.mem.eql(u8, expected, actual)) return;

    std.debug.print("{s} " ++ message ++ "\n", .{name});

    return std.testing.expectEqualStrings(expected, actual);
}

fn expect_words(name: []const u8, before: []const []const u8, after: []const []const u8) !void {
    assert(before.len <= std.math.maxInt(u32));
    assert(after.len <= std.math.maxInt(u32));

    const shared = @min(before.len, after.len);

    assert(name.len > 0);
    assert(shared <= before.len);

    for (0..shared) |index| {
        if (std.mem.eql(u8, before[index], after[index])) continue;

        const message = "{s} split, joined, lost, or gained a word: word {d} `{s}` became `{s}`\n";

        std.debug.print(message, .{ name, index, before[index], after[index] });

        return error.TestUnexpectedResult;
    }

    try require(
        before.len == after.len,
        "{s} split, joined, lost, or gained a word: {d} words became {d}",
        .{ name, before.len, after.len },
    );
}

test "formatting formatted output changes nothing" {
    const gpa = std.testing.allocator;
    var twice: Twice = undefined;

    try twice.init(gpa);
    defer twice.deinit(gpa);

    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    for (found.items) |fixture| {
        const first = twice.held.format(fixture.source, &twice.first);

        try require(is_complete(first), "{s}", .{fixture.name});

        const once = twice.first.const_slice();
        const second = twice.held.format(once, &twice.second);

        try require(is_complete(second), "{s}", .{fixture.name});
        try expect_text(fixture.name, "is not idempotent", once, twice.second.const_slice());
    }
}

test "formatting keeps every token it was given" {
    const gpa = std.testing.allocator;
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    var relations: Relations = .empty;
    defer relations.deinit(gpa);

    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    for (found.items) |*fixture| {
        try held.format(fixture.source, &out);
        try relations.expect_kinds(gpa, &held, fixture, out.const_slice());
    }
}

test "formatting keeps every comment it was given" {
    const gpa = std.testing.allocator;
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    var relations: Relations = .empty;
    defer relations.deinit(gpa);

    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    for (found.items) |*fixture| {
        try held.format(fixture.source, &out);
        try relations.expect_comments(gpa, &held, fixture, out.const_slice());
        try relations.expect_comment_ends(fixture);
    }
}

test "a dump writes the formatted fixtures" {
    const gpa = std.testing.allocator;
    var root_bytes: [environment.value_bytes_max]u8 = undefined;
    const root = environment.get(dump_variable, &root_bytes) orelse return;
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    for (found.items) |fixture| {
        try held.format(fixture.source, &out);
        try write_under(root, fixture.name, out.const_slice());
    }
}

test "the formatted output matches the oracle modulo residue" {
    const gpa = std.testing.allocator;
    var carried = try oracle.residue_of(gpa, residue_name, &every_category);
    defer carried.deinit(gpa);

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    var compared: u32 = 0;

    for (found.items) |fixture| {
        if (carried.contains(fixture.name)) continue;

        try held.format(fixture.source, &out);

        const golden = try read_under(gpa, golden_root, fixture.name);
        defer gpa.free(golden);

        const message = "diverges from zig fmt and no residue row names it";

        try expect_text(fixture.name, message, golden, out.const_slice());

        compared += 1;
    }

    try require(
        compared >= floor.fixture_format_zig,
        "the Zig fixtures lost a formatting: {d} compared, floor {d}",
        .{ compared, floor.fixture_format_zig },
    );
}

test "every residue row names a fixture that diverges" {
    const gpa = std.testing.allocator;
    var carried = try oracle.residue_of(gpa, residue_name, &every_category);
    defer carried.deinit(gpa);

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    for (carried.fixtures.items) |name| {
        const source = try read_under(gpa, fixture_root, name);
        defer gpa.free(source);

        try held.format(source, &out);

        const golden = try read_under(gpa, golden_root, name);
        defer gpa.free(golden);

        const diverged = !std.mem.eql(u8, out.const_slice(), golden);

        try require(diverged, "{s} matches zig fmt and needs no residue row", .{name});
    }
}

test "a file that does not parse is refused" {
    const gpa = std.testing.allocator;
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    try std.testing.expectError(error.SourceInvalid, held.format("fn f( {\n", &out));
    try std.testing.expect(out.empty());
}

test "a range reads back the lines it names" {
    const gpa = std.testing.allocator;
    const source = "fn f() void {\nconst x=1;\n_=x;\n}\n";
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var whole: Buffer = try .init(gpa, out_bytes_max);
    defer whole.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    try held.format(source, &whole);

    const formatted = whole.const_slice();
    const span = try held.range(source, .{ .first = 1, .last = 2 }, &out);

    try std.testing.expectEqualStrings(formatted, out.const_slice());
    try std.testing.expectEqualStrings(lines_of(formatted, 1, 2), span.text(out.const_slice()));
}

test "the three relations hold over the corpus" {
    const gpa = std.testing.allocator;
    const root = corpus.named(.root) orelse return;
    var files = try corpus.collect(gpa, root, source_bytes_max, corpus_selected);
    defer files.deinit(gpa);

    var tally: RelationsWorker.Tally = .{};

    try stripe.run(RelationsWorker, gpa, &.{}, files.slice(), &tally);
}

test "formatting keeps every word it was given" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    for (found.items) |fixture| {
        held.format(fixture.source, &out) catch continue;

        _ = arena.reset(.retain_capacity);

        const before = try held.words(arena.allocator(), fixture.source);
        const after = try held.words(arena.allocator(), out.const_slice());

        try expect_words(fixture.name, before, after);
    }
}

test "a switch prong lists its cases without the columns a row takes" {
    const source = "const E = enum { aaa, b, cccccccccc, d };\n" ++
        "fn f(e: E) u8 {\n" ++
        "    return switch (e) {\n" ++
        "        .aaa, .b => 1,\n" ++
        "        .cccccccccc, .d => 2,\n" ++
        "    };\n" ++
        "}\n" ++
        "const t = [_]u32{\n" ++
        "    1, 2,\n" ++
        "    400, 5,\n" ++
        "};\n";

    const wanted = "const E = enum { aaa, b, cccccccccc, d };\n" ++
        "fn f(e: E) u8 {\n" ++
        "    return switch (e) {\n" ++
        "        .aaa, .b => 1,\n" ++
        "        .cccccccccc, .d => 2,\n" ++
        "    };\n" ++
        "}\n" ++
        "const t = [_]u32{\n" ++
        "    1,   2,\n" ++
        "    400, 5,\n" ++
        "};\n";

    try expect_formatted(source, wanted);
}

test "a body whose head stands on a continuation indents from that line" {
    const source = "fn f() u8 {\n" ++
        "    const held =\n" ++
        "        for ([_]u8{ 1, 2, 3 }) |value| {\n" ++
        "            if (value == 2) break value;\n" ++
        "        } else 0;\n" ++
        "    return held;\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "an operator chain steps a level where the operators bind harder" {
    const source = "const a: u64 = 1;\n" ++
        "const b: u64 = 2;\n" ++
        "const c: u64 = 3;\n" ++
        "const d: u64 = 4;\n" ++
        "fn f() u64 {\n" ++
        "    const p =\n" ++
        "        a +\n" ++
        "        b *\n" ++
        "        c +\n" ++
        "        d;\n" ++
        "    const q =\n" ++
        "        a *\n" ++
        "        b +\n" ++
        "        c;\n" ++
        "    return p + q;\n" ++
        "}\n";

    const wanted = "const a: u64 = 1;\n" ++
        "const b: u64 = 2;\n" ++
        "const c: u64 = 3;\n" ++
        "const d: u64 = 4;\n" ++
        "fn f() u64 {\n" ++
        "    const p =\n" ++
        "        a +\n" ++
        "        b *\n" ++
        "            c +\n" ++
        "        d;\n" ++
        "    const q =\n" ++
        "        a *\n" ++
        "        b +\n" ++
        "        c;\n" ++
        "    return p + q;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a bracket inside a headers condition indents from the line it opened on" {
    const source = "fn f() void {\n" ++
        "    if (aaa and\n" ++
        "        other(\n" ++
        "        one,\n" ++
        "        two,\n" ++
        "    )) {\n" ++
        "        stage();\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn f() void {\n" ++
        "    if (aaa and\n" ++
        "        other(\n" ++
        "            one,\n" ++
        "            two,\n" ++
        "        ))\n" ++
        "    {\n" ++
        "        stage();\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a body whose header ends over indented takes a line of its own" {
    const source = "fn f() void {\n" ++
        "    if (aaa and\n" ++
        "        bbb) {\n" ++
        "        one();\n" ++
        "    }\n" ++
        "    if (call(\n" ++
        "        aaa,\n" ++
        "    ) == 0) {\n" ++
        "        two();\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn f() void {\n" ++
        "    if (aaa and\n" ++
        "        bbb)\n" ++
        "    {\n" ++
        "        one();\n" ++
        "    }\n" ++
        "    if (call(\n" ++
        "        aaa,\n" ++
        "    ) == 0) {\n" ++
        "        two();\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a headers body steps in from the header and its else steps back" {
    const source = "fn f() void {\n" ++
        "    const held =\n" ++
        "        if (a)\n" ++
        "        if (b)\n" ++
        "        one\n" ++
        "        else\n" ++
        "        two\n" ++
        "        else\n" ++
        "        three;\n" ++
        "    _ = held;\n" ++
        "}\n";

    const wanted = "fn f() void {\n" ++
        "    const held =\n" ++
        "        if (a)\n" ++
        "            if (b)\n" ++
        "                one\n" ++
        "            else\n" ++
        "                two\n" ++
        "        else\n" ++
        "            three;\n" ++
        "    _ = held;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a continuation opened inside another steps in from it" {
    const source = "fn f() void {\n" ++
        "    const held =\n" ++
        "        if (a)\n" ++
        "        one\n" ++
        "    else\n" ++
        "        two;\n" ++
        "    _ = held;\n" ++
        "}\n";

    const wanted = "fn f() void {\n" ++
        "    const held =\n" ++
        "        if (a)\n" ++
        "            one\n" ++
        "        else\n" ++
        "            two;\n" ++
        "    _ = held;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a comment takes the level of the code below it" {
    const source = "fn f() void {\n" ++
        "    const held = value.first()\n" ++
        "    // A remark standing inside a continuation.\n" ++
        "        .second();\n" ++
        "    _ = held;\n" ++
        "}\n";

    const wanted = "fn f() void {\n" ++
        "    const held = value.first()\n" ++
        "        // A remark standing inside a continuation.\n" ++
        "        .second();\n" ++
        "    _ = held;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a continue clause stands at the level its header took" {
    const source = "fn f() void {\n" ++
        "    var i: u8 = 0;\n" ++
        "    while (i < ten and\n" ++
        "        i < twenty) //\n" ++
        "        : (i += 1) {\n" ++
        "        one();\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn f() void {\n" ++
        "    var i: u8 = 0;\n" ++
        "    while (i < ten and\n" ++
        "        i < twenty) //\n" ++
        "    : (i += 1) {\n" ++
        "        one();\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a run of nested casts is written in one order" {
    const source = "fn f(ctx: *anyopaque) void {\n" ++
        "    const held = @constCast(@alignCast(@ptrCast(ctx)));\n" ++
        "    _ = held;\n" ++
        "}\n";

    const wanted = "fn f(ctx: *anyopaque) void {\n" ++
        "    const held = @ptrCast(@alignCast(@constCast(ctx)));\n" ++
        "    _ = held;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a slices own sentinel takes the blank a types sentinel does not" {
    const source = "fn f(buffer: []u8, read: usize) void {\n" ++
        "    var one: [614:0]u8 = undefined;\n" ++
        "    const two = buffer[0..read :0];\n" ++
        "    _ = one;\n" ++
        "    _ = two;\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a line past a multiline string steps back out of it" {
    const source = "fn f(buf: []u8) void {\n" ++
        "    const held = call(\n" ++
        "        \\\\one\n" ++
        "    ++\n" ++
        "        \\\\two\n" ++
        "        , buf);\n" ++
        "    const kept = .{\n" ++
        "        \\\\three\n" ++
        "        ,\n" ++
        "        4,\n" ++
        "    };\n" ++
        "    _ = held;\n" ++
        "    _ = kept;\n" ++
        "}\n";

    const wanted = "fn f(buf: []u8) void {\n" ++
        "    const held = call(\n" ++
        "        \\\\one\n" ++
        "    ++\n" ++
        "        \\\\two\n" ++
        "    , buf);\n" ++
        "    const kept = .{\n" ++
        "        \\\\three\n" ++
        "        ,\n" ++
        "        4,\n" ++
        "    };\n" ++
        "    _ = held;\n" ++
        "    _ = kept;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a sole element hugs the brace holding it however it parts" {
    const source = "fn f() void {\n" ++
        "    try p(\"a\", .{ sized(\n" ++
        "        one,\n" ++
        "    ) });\n" ++
        "    try p(\"a\", .{ one, sized(\n" ++
        "        two,\n" ++
        "    ) });\n" ++
        "}\n";

    const wanted = "fn f() void {\n" ++
        "    try p(\"a\", .{sized(\n" ++
        "        one,\n" ++
        "    )});\n" ++
        "    try p(\"a\", .{ one, sized(\n" ++
        "        two,\n" ++
        "    ) });\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an element spelling lines of its own takes a row of its own" {
    const source = "const held = .{\n" ++
        "    .{\n" ++
        "        one, Mapping{\n" ++
        "            .name = \"two\",\n" ++
        "        },\n" ++
        "    },\n" ++
        "    .{ three, Mapping{\n" ++
        "        .name = \"four\",\n" ++
        "    } },\n" ++
        "};\n";

    const wanted = "const held = .{\n" ++
        "    .{\n" ++
        "        one,\n" ++
        "        Mapping{\n" ++
        "            .name = \"two\",\n" ++
        "        },\n" ++
        "    },\n" ++
        "    .{ three, Mapping{\n" ++
        "        .name = \"four\",\n" ++
        "    } },\n" ++
        "};\n";

    try expect_formatted(source, wanted);
}

test "a payload the source parted steps in from the header opening it" {
    const source = "fn f() void {\n" ++
        "    for (one, two) |\n" ++
        "    first,\n" ++
        "    second,\n" ++
        "    | {\n" ++
        "        _ = .{ first, second };\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn f() void {\n" ++
        "    for (one, two) |\n" ++
        "        first,\n" ++
        "        second,\n" ++
        "    | {\n" ++
        "        _ = .{ first, second };\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a conditions operator under a trailing comment keeps the headers level" {
    const source = "fn f(link: []const u8) void {\n" ++
        "    if (one(link) // external.\n" ++
        "        or two(link) // email.\n" ++
        "    ) {\n" ++
        "        return;\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn f(link: []const u8) void {\n" ++
        "    if (one(link) // external.\n" ++
        "    or two(link) // email.\n" ++
        "    ) {\n" ++
        "        return;\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a comment between two operands keeps the precedence the chain stands at" {
    const source = "const a = if (element_count >=\n" ++
        "    // one\n" ++
        "    capacity +\n" ++
        "    // two\n" ++
        "    1 +\n" ++
        "    // three\n" ++
        "    2)\n" ++
        "    naive\n" ++
        "else\n" ++
        "    naive - 1;\n";

    const wanted = "const a = if (element_count >=\n" ++
        "    // one\n" ++
        "    capacity +\n" ++
        "        // two\n" ++
        "        1 +\n" ++
        "        // three\n" ++
        "        2)\n" ++
        "    naive\n" ++
        "else\n" ++
        "    naive - 1;\n";

    try expect_formatted(source, wanted);
}

test "an arm body under a comment run keeps the arms own level" {
    const source = "fn f(n: u8) ?u8 {\n" ++
        "    return switch (n) {\n" ++
        "        0 =>\n" ++
        "            // one\n" ++
        "            // two\n" ++
        "            call(\n" ++
        "                a,\n" ++
        "            ),\n" ++
        "        else => null,\n" ++
        "    };\n" ++
        "}\n";

    const wanted = "fn f(n: u8) ?u8 {\n" ++
        "    return switch (n) {\n" ++
        "        0 =>\n" ++
        "        // one\n" ++
        "        // two\n" ++
        "        call(\n" ++
        "            a,\n" ++
        "        ),\n" ++
        "        else => null,\n" ++
        "    };\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a struct initialiser field under a trailing comment keeps its own level" {
    const source = "const g = init(gpa, .{\n" ++
        "    .alpha = one,\n" ++
        "    .beta = //\n" ++
        "        two,\n" ++
        "});\n" ++
        "const v = struct {\n" ++
        "    alpha: u8 = //\n" ++
        "        one,\n" ++
        "};\n";

    const wanted = "const g = init(gpa, .{\n" ++
        "    .alpha = one,\n" ++
        "    .beta = //\n" ++
        "    two,\n" ++
        "});\n" ++
        "const v = struct {\n" ++
        "    alpha: u8 = //\n" ++
        "        one,\n" ++
        "};\n";

    try expect_formatted(source, wanted);
}

test "a body an orelse opens indents from the line it opened on" {
    const source = "fn f() void {\n" ++
        "    const held: i64 = if (client == 0)\n" ++
        "        @intCast(stamp)\n" ++
        "    else\n" ++
        "        clock.sync() orelse {\n" ++
        "        one();\n" ++
        "        return;\n" ++
        "    };\n" ++
        "    _ = held;\n" ++
        "}\n";

    const wanted = "fn f() void {\n" ++
        "    const held: i64 = if (client == 0)\n" ++
        "        @intCast(stamp)\n" ++
        "    else\n" ++
        "        clock.sync() orelse {\n" ++
        "            one();\n" ++
        "            return;\n" ++
        "        };\n" ++
        "    _ = held;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a wrapping negation closes up against its operand" {
    const source = "fn f(less_than: u64, x: u64) void {\n" ++
        "    const t = -%less_than;\n" ++
        "    const u = x -% less_than;\n" ++
        "    _ = .{ t, u };\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a break after an equals stays where the source wrote it" {
    const source = "fn f() void {\n" ++
        "    const prepare =\n" ++
        "        replica_storage.area_memory(.{ .wal_prepares = .{ .slot = slot } });\n" ++
        "    const wal_prepare: *const vsr.Header.Prepare =\n" ++
        "        std.mem.bytesAsValue(\n" ++
        "            vsr.Header.Prepare,\n" ++
        "            integrity.buffer_prepare[0..@sizeOf(vsr.Header)],\n" ++
        "        );\n" ++
        "    _ = .{ prepare, wal_prepare };\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a headers parenthesised operand keeps the breaks the source wrote" {
    const source = "fn f() void {\n" ++
        "    if ((repl.completion.prefix.count() + repl.completion.suffix.count() +\n" ++
        "        current_completion.len) >= repl_history_entry_bytes_without_nul)\n" ++
        "    {\n" ++
        "        return;\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a blank line between the comments of an otherwise empty block is kept" {
    const source = "fn f() void {\n" ++
        "    switch (err) {\n" ++
        "        error.SocketNotConnected => {\n" ++
        "            // This should only happen if we for some reason decide to terminate.\n" ++
        "\n" ++
        "            // TODO: This currently happens in other cases.\n" ++
        "        },\n" ++
        "        else => {},\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a merged error set inside a tagged union stays on its own line" {
    const source = "pub const IpAddress = union(enum) {\n" ++
        "    pub const ListenError = error{\n" ++
        "        /// The address is already taken.\n" ++
        "        AddressInUse,\n" ++
        "        /// One of the `ListenOptions` is not supported by the Io implementation.\n" ++
        "        OptionUnsupported,\n" ++
        "    } || Io.UnexpectedError || Io.Cancelable;\n" ++
        "\n" ++
        "    pub const ListenOptions = struct {\n" ++
        "        kernel_backlog: u31 = default_kernel_backlog,\n" ++
        "    };\n" ++
        "};\n";

    try expect_formatted(source, source);
}

test "an inline assembly operand spaces its constraint and steps two columns in" {
    const source = "fn f(x: u32) u32 {\n" ++
        "    asm volatile (\"\" ::: .{ .memory = true });\n" ++
        "    const result = asm volatile (\n" ++
        "        \\\\local.get %[ptr]\n" ++
        "        \\\\local.set %[ret]\n" ++
        "        : [ret] \"=r\" (-> u32),\n" ++
        "        : [ptr] \"r\" (x),\n" ++
        "          [expected] \"r\" (x),\n" ++
        "    );\n" ++
        "    return asm (\"mov\"\n" ++
        "        : [ret] \"=r\" (-> u32),\n" ++
        "        : [x] \"r\" (x),\n" ++
        "          [y] \"r\" (result),\n" ++
        "        : .{ .memory = true });\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a switch owns its brace and an assert binding reads its members" {
    const source = "fn f() void {\n" ++
        "    var fill: ?u8 = if (parser.peek(1)) |b|\n" ++
        "        switch (b) {\n" ++
        "            '<', '^', '>' => parser.char(),\n" ++
        "            else => null,\n" ++
        "        }\n" ++
        "    else\n" ++
        "        null;\n" ++
        "    switch (x) {\n" ++
        "        .static_assert => |assert| {\n" ++
        "            repr.data[0] = @intFromEnum(assert.cond);\n" ++
        "        },\n" ++
        "        else => {},\n" ++
        "    }\n" ++
        "    _ = &fill;\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a row measures its elements without the comments around them" {
    const source = "const exp2dt = [_]f64{\n" ++
        "    //  exp2(z + eps)          eps\n" ++
        "    0x1.6a09e667f3d5dp-1, 0x1.9880p-44,\n" ++
        "    0x1.6b052fa751744p-1, 0x1.8000p-50,\n" ++
        "};\n" ++
        "const args = .{\n" ++
        "    \"-rdynamic\", //\n" ++
        "    \"--dep\", \"Walk\", //\n" ++
        "    \"--dep\", \"html_render\", //\n" ++
        "};\n";

    try expect_formatted(source, source);
}

test "a region zig fmt turns off prints as the source wrote it" {
    const source = "const a = 1; // zig fmt: off\n" ++
        "const  b  =  2;\n" ++
        "\tconst  c = 3;\n" ++
        "//zig fmt: on   \n" ++
        "const  d = 4;\n";

    const wanted = "const a = 1; // zig fmt: off\n" ++
        "const  b  =  2;\n" ++
        "    const  c = 3;\n" ++
        "// zig fmt: on\n" ++
        "const d = 4;\n";

    try expect_formatted(source, wanted);
}

test "a list with a trailing comma takes one item per line" {
    const source = "const p = .{\n" ++
        "    .a = 1, .bb = 2,\n" ++
        "};\n" ++
        "const q = f(\n" ++
        "    a, bb,\n" ++
        ");\n" ++
        "fn g(\n" ++
        "    a: u8, b: u8,\n" ++
        ") void {}\n" ++
        "const E = enum {\n" ++
        "    a, b,\n" ++
        "};\n" ++
        "const Err = error{\n" ++
        "    A, B,\n" ++
        "};\n";

    const wanted = "const p = .{\n" ++
        "    .a = 1,\n" ++
        "    .bb = 2,\n" ++
        "};\n" ++
        "const q = f(\n" ++
        "    a,\n" ++
        "    bb,\n" ++
        ");\n" ++
        "fn g(\n" ++
        "    a: u8,\n" ++
        "    b: u8,\n" ++
        ") void {}\n" ++
        "const E = enum {\n" ++
        "    a,\n" ++
        "    b,\n" ++
        "};\n" ++
        "const Err = error{\n" ++
        "    A,\n" ++
        "    B,\n" ++
        "};\n";

    try expect_formatted(source, wanted);
}

test "a list without a trailing comma stands on one line" {
    const source = "const x = f(a,\n" ++
        "    b);\n" ++
        "fn h(a: u8,\n" ++
        "    b: u8) void {}\n" ++
        "const y = .{ .a = 1,\n" ++
        "    .b = 2 };\n";

    const wanted = "const x = f(a, b);\n" ++
        "fn h(a: u8, b: u8) void {}\n" ++
        "const y = .{ .a = 1, .b = 2 };\n";

    try expect_formatted(source, wanted);
}

test "a switch writes a case per line and a for joins its captures" {
    const source = "fn f(x: u8) u8 {\n" ++
        "    return switch (x) {\n" ++
        "        0 => 1, 1 => 2,\n" ++
        "        2,\n" ++
        "        3 => 4,\n" ++
        "        else => 0,\n" ++
        "    };\n" ++
        "}\n" ++
        "fn g(xs: []const u8) void {\n" ++
        "    for (xs,\n" ++
        "        0..) |x,\n" ++
        "        i| {\n" ++
        "        _ = .{ x, i };\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn f(x: u8) u8 {\n" ++
        "    return switch (x) {\n" ++
        "        0 => 1,\n" ++
        "        1 => 2,\n" ++
        "        2, 3 => 4,\n" ++
        "        else => 0,\n" ++
        "    };\n" ++
        "}\n" ++
        "fn g(xs: []const u8) void {\n" ++
        "    for (xs, 0..) |x, i| {\n" ++
        "        _ = .{ x, i };\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an array reflows to its first rows width and pads each section" {
    const source = "const a = .{\n" ++
        "    1, 2, 3,\n" ++
        "    4, 5,\n" ++
        "    6, 7, 8,\n" ++
        "};\n" ++
        "const b = .{\n" ++
        "    1, 22, 333, // c\n" ++
        "    4444, 5,\n" ++
        "    6, 7, 8,\n" ++
        "};\n";

    const wanted = "const a = .{\n" ++
        "    1, 2, 3,\n" ++
        "    4, 5, 6,\n" ++
        "    7, 8,\n" ++
        "};\n" ++
        "const b = .{\n" ++
        "    1,    22, 333, // c\n" ++
        "    4444, 5,  6,\n" ++
        "    7,    8,\n" ++
        "};\n";

    try expect_formatted(source, wanted);
}

test "a statement ends its line and a keyword stands a space off its parenthesis" {
    const source = "fn f() void { a(); b(); }\n" ++
        "fn g(x: bool) void {\n" ++
        "    if(x) { a(); } else { b(); }\n" ++
        "    while(x) {}\n" ++
        "}\n";

    const wanted = "fn f() void {\n" ++
        "    a();\n" ++
        "    b();\n" ++
        "}\n" ++
        "fn g(x: bool) void {\n" ++
        "    if (x) {\n" ++
        "        a();\n" ++
        "    } else {\n" ++
        "        b();\n" ++
        "    }\n" ++
        "    while (x) {}\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a body brace and an else join the line that heads them" {
    const source = "fn f(x: bool) void\n" ++
        "{\n" ++
        "    if (x)\n" ++
        "    {\n" ++
        "        a();\n" ++
        "    }\n" ++
        "    else {\n" ++
        "        b();\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn f(x: bool) void {\n" ++
        "    if (x) {\n" ++
        "        a();\n" ++
        "    } else {\n" ++
        "        b();\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a blank line at a brace stays only beside a comment" {
    const source = "fn f() void {\n" ++
        "\n" ++
        "    a();\n" ++
        "\n" ++
        "}\n" ++
        "const S = struct {\n" ++
        "\n" ++
        "    a: u8,\n" ++
        "\n" ++
        "};\n" ++
        "fn g() void {\n" ++
        "    a();\n" ++
        "    // tail\n" ++
        "\n" ++
        "}\n";

    const wanted = "fn f() void {\n" ++
        "    a();\n" ++
        "}\n" ++
        "const S = struct {\n" ++
        "    a: u8,\n" ++
        "};\n" ++
        "fn g() void {\n" ++
        "    a();\n" ++
        "    // tail\n" ++
        "\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a body below a continue expression steps in from its header" {
    const source = "fn f() void {\n" ++
        "    var i: usize = 0;\n" ++
        "    while (i < 10) : (i += 1)\n" ++
        "        g(i);\n" ++
        "    while (i < 10)\n" ++
        "        g(i);\n" ++
        "    for (xs) |x|\n" ++
        "        g(x);\n" ++
        "    if (a)\n" ++
        "        g(1)\n" ++
        "    else\n" ++
        "        g(2);\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a fallback below its catch steps in from the catch" {
    const source = "fn f() void {\n" ++
        "    const file = if (dep_file_name) |path|\n" ++
        "        d.comp.cwd.createFile(io, path, .{}) catch |er|\n" ++
        "            return d.fatal(\"x\", .{})\n" ++
        "    else\n" ++
        "        Io.File.stdout();\n" ++
        "    _ = file;\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a comment above an else keeps the level of the branch it follows" {
    const source = "fn f() void {\n" ++
        "    const T = if (int_info.bits < 32)\n" ++
        "        c_int\n" ++
        "        // otherwise, restore the original C type\n" ++
        "    else if (int_info.bits == 32)\n" ++
        "        c_uint\n" ++
        "    else\n" ++
        "        c_long;\n" ++
        "    _ = T;\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "an operator below a trailing comment steps in from its statement" {
    const source = "fn f() void {\n" ++
        "    x = ((x >> 2) & (~@as(UT, 0) / 5)) // 0x33...33, aggregate nibbles\n" ++
        "        + (x & (~@as(UT, 0) / 5));\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a list one item per line takes the comma its last item left off" {
    const source = "fn f(x: u8) void {\n" ++
        "    switch (x) {\n" ++
        "        0 => {},\n" ++
        "        else => {}\n" ++
        "    }\n" ++
        "    const S = struct {\n" ++
        "        a: u8, // c\n" ++
        "        b: u8\n" ++
        "    };\n" ++
        "    const p = .{\n" ++
        "        .a = 1, // c\n" ++
        "        .b = 2\n" ++
        "    };\n" ++
        "    _ = .{ S, p };\n" ++
        "}\n";

    const wanted = "fn f(x: u8) void {\n" ++
        "    switch (x) {\n" ++
        "        0 => {},\n" ++
        "        else => {},\n" ++
        "    }\n" ++
        "    const S = struct {\n" ++
        "        a: u8, // c\n" ++
        "        b: u8,\n" ++
        "    };\n" ++
        "    const p = .{\n" ++
        "        .a = 1, // c\n" ++
        "        .b = 2,\n" ++
        "    };\n" ++
        "    _ = .{ S, p };\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an or past a parenthesis steps its operands in once" {
    const source = "fn f() void {\n" ++
        "    const t = (@as(u32, buf[j]) |\n" ++
        "        (@as(u32, buf[j + 1]) << 8) |\n" ++
        "        (@as(u32, buf[j + 2]) << 16)) & 0x7fffff;\n" ++
        "    _ = t;\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a brace past a broken condition steps in from the line it opened" {
    const source = "fn f() void {\n" ++
        "    const x = .{\n" ++
        "        .dylib_symlinks = if (options.dylib_symlinks orelse (dest_dir != null and\n" ++
        "            artifact.isDynamicLibrary() and\n" ++
        "            std.Build.wantSharedLibSymLinks(artifact.rootModuleTarget()))) .{\n" ++
        "            .major_only_filename = artifact.major_only_filename.?,\n" ++
        "            .name_only_filename = artifact.name_only_filename.?,\n" ++
        "        } else null,\n" ++
        "    };\n" ++
        "    _ = x;\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a grouped branch gives back its indent before the catch past it" {
    const source = "fn f() void {\n" ++
        "    const type_node = (if (variable.initializer) |init|\n" ++
        "        t.transTypeInit(scope, init)\n" ++
        "    else\n" ++
        "        t.transType(scope, variable.qt)) catch |err| switch (err) {\n" ++
        "        error.UnsupportedType => {\n" ++
        "            return t.fail();\n" ++
        "        },\n" ++
        "        else => |e| return e,\n" ++
        "    };\n" ++
        "    _ = type_node;\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a brace a return type and a continue colon stand a space off" {
    const source = "fn f(x: u8)?u8 {\n" ++
        "    switch (x){\n" ++
        "        else => {},\n" ++
        "    }\n" ++
        "    p.*= 1;\n" ++
        "    while (i < 2): (i += 1) {}\n" ++
        "    return asm volatile(\"\"::: .{ .memory = true });\n" ++
        "}\n" ++
        "fn g(a:?*u8) void {}\n";

    const wanted = "fn f(x: u8) ?u8 {\n" ++
        "    switch (x) {\n" ++
        "        else => {},\n" ++
        "    }\n" ++
        "    p.* = 1;\n" ++
        "    while (i < 2) : (i += 1) {}\n" ++
        "    return asm volatile (\"\" ::: .{ .memory = true });\n" ++
        "}\n" ++
        "fn g(a: ?*u8) void {}\n";

    try expect_formatted(source, wanted);
}

test "an asm template steps in past the indent the asm realizes" {
    const source = "fn f(arch: Arch, abi: Abi) void {\n" ++
        "    switch (arch) {\n" ++
        "        .x86_64 => asm volatile (switch (abi) {\n" ++
        "                .gnux32 =>\n" ++
        "                \\\\  movl $0x4000000b, %%eax\n" ++
        "                \\\\  syscall\n" ++
        "                ,\n" ++
        "                else =>\n" ++
        "                \\\\  movl $11, %%eax\n" ++
        "                ,\n" ++
        "            }\n" ++
        "            :\n" ++
        "            : [ptr] \"{rdi}\" (ptr),\n" ++
        "        ),\n" ++
        "        else => {},\n" ++
        "    }\n" ++
        "    asm volatile (if (Gpr == u64)\n" ++
        "            \\\\ st.d $zero, $t0, 0\n" ++
        "            \\\\ st.d $ra, $t0, 8\n" ++
        "        else\n" ++
        "            \\\\ st.w $zero, $t0, 0\n" ++
        "        :\n" ++
        "        : [ctx] \"{$r12}\" (&ctx),\n" ++
        "        : .{ .memory = true });\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a multiline string keeps the indent of its first line" {
    const source = "fn f(c: bool, y: u8) void {\n" ++
        "    const x = if (c)\n" ++
        "        \\\\ a\n" ++
        "        \\\\ b\n" ++
        "    else\n" ++
        "        \\\\ c\n" ++
        "        \\\\ d\n" ++
        "    ;\n" ++
        "    const z = switch (y) {\n" ++
        "        0 => \"\",\n" ++
        "        else =>\n" ++
        "        \\\\ e\n" ++
        "        ,\n" ++
        "    };\n" ++
        "    _ = .{ x, z };\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "an asm operand or clobber bracket steps in two columns" {
    const source = "fn f(s: *Switch) void {\n" ++
        "    return asm volatile (\n" ++
        "        \\\\ mov sp, x4\n" ++
        "        : [received_message] \"={x1}\" (-> *const Switch),\n" ++
        "        : [message_to_send] \"{x1}\" (foo(\n" ++
        "            s,\n" ++
        "            1,\n" ++
        "          )),\n" ++
        "          [other] \"{x9}\" (1),\n" ++
        "        : .{\n" ++
        "          .x0 = true,\n" ++
        "          .memory = true,\n" ++
        "        });\n" ++
        "}\n" ++
        "fn g() void {\n" ++
        "    asm volatile (\"svc #0\" ::: .{\n" ++
        "            .memory = true,\n" ++
        "        });\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a multiline string breaks the line only around itself" {
    const source = "fn f() []const u8 {\n" ++
        "    dumpBadDirnameHelp(step,\n" ++
        "    asking_step,\n" ++
        "        \\\\dirname() attempted to traverse outside the cache root.\n" ++
        "        \\\\\n" ++
        "    , .{}) catch {};\n" ++
        "    const s = .{ .a = 1,\n" ++
        "    .b = \\\\x\n" ++
        "    , .c = 2 };\n" ++
        "    _ = s;\n" ++
        "    return \\\\abc\n" ++
        "    ;\n" ++
        "}\n" ++
        "fn g() [\n" ++
        "    directEnumArrayLen(E, max_unused_slots)]Data {\n" ++
        "    return undefined;\n" ++
        "}\n";

    const wanted = "fn f() []const u8 {\n" ++
        "    dumpBadDirnameHelp(step, asking_step,\n" ++
        "        \\\\dirname() attempted to traverse outside the cache root.\n" ++
        "        \\\\\n" ++
        "    , .{}) catch {};\n" ++
        "    const s = .{ .a = 1, .b =\n" ++
        "        \\\\x\n" ++
        "    , .c = 2 };\n" ++
        "    _ = s;\n" ++
        "    return\n" ++
        "    \\\\abc\n" ++
        "    ;\n" ++
        "}\n" ++
        "fn g() [\n" ++
        "    directEnumArrayLen(E, max_unused_slots)\n" ++
        "]Data {\n" ++
        "    return undefined;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a returned error union stands a space off its prototype" {
    const source = "pub fn write(self: Differ, writer: *Writer)!void {\n" ++
        "    _ = self;\n" ++
        "    _ = writer;\n" ++
        "}\n";

    const wanted = "pub fn write(self: Differ, writer: *Writer) !void {\n" ++
        "    _ = self;\n" ++
        "    _ = writer;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a labeled block that ends a slice takes no sentinel blank" {
    const source = "fn f(b: []const u8) []const u8 {\n" ++
        "    return b[0..len : {\n" ++
        "        break :len 1;\n" ++
        "    }];\n" ++
        "}\n";

    const wanted = "fn f(b: []const u8) []const u8 {\n" ++
        "    return b[0..len: {\n" ++
        "        break :len 1;\n" ++
        "    }];\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a block below its orelse or catch keeps its own line a level in" {
    const source = "fn f() void {\n" ++
        "    const a = g() orelse\n" ++
        "    {\n" ++
        "        return;\n" ++
        "    };\n" ++
        "    const b = g() catch |err|\n" ++
        "{\n" ++
        "        h(err);\n" ++
        "    };\n" ++
        "    _ = .{ a, b };\n" ++
        "}\n";

    const wanted = "fn f() void {\n" ++
        "    const a = g() orelse\n" ++
        "        {\n" ++
        "            return;\n" ++
        "        };\n" ++
        "    const b = g() catch |err|\n" ++
        "        {\n" ++
        "            h(err);\n" ++
        "        };\n" ++
        "    _ = .{ a, b };\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a labeled or inline loop on a continuation steps its body in from that line" {
    const source = "fn f() void {\n" ++
        "    const a: u8 =\n" ++
        "        blk: while (it.next()) |x| {\n" ++
        "            break :blk x;\n" ++
        "        } else 0;\n" ++
        "    const b: u8 =\n" ++
        "        inline for (xs) |x| {\n" ++
        "            break x;\n" ++
        "        };\n" ++
        "    _ = .{ a, b };\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a block continue expression gives the body the level of its header" {
    const source = "fn f() void {\n" ++
        "    while (a and\n" ++
        "        b) : ({\n" ++
        "        i += 1;\n" ++
        "    }) {\n" ++
        "        g();\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "an operator that leads its line takes the indent zig fmt has realized" {
    const source = "fn f() void {\n" ++
        "    const z = a +\n" ++
        "        b // c\n" ++
        "        + c;\n" ++
        "    const y = a // c\n" ++
        "        + b;\n" ++
        "    const x = .{\n" ++
        "        .a = b // c\n" ++
        "            + d,\n" ++
        "    };\n" ++
        "    _ = .{ x, y, z };\n" ++
        "}\n";

    const wanted = "fn f() void {\n" ++
        "    const z = a +\n" ++
        "        b // c\n" ++
        "    + c;\n" ++
        "    const y = a // c\n" ++
        "        + b;\n" ++
        "    const x = .{\n" ++
        "        .a = b // c\n" ++
        "        + d,\n" ++
        "    };\n" ++
        "    _ = .{ x, y, z };\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a bar past a call is an operator and opens no payload" {
    const source = "fn f() void {\n" ++
        "    const color = .{\n" ++
        "        .opts = f(a) |\n" ++
        "            b,\n" ++
        "    };\n" ++
        "    _ = color;\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a branch body opens its brackets a level past the branch" {
    const source = "fn f() !usize {\n" ++
        "    const pos = try convert(if (param) |p|\n" ++
        "        search(\n" ++
        "            p.value,\n" ++
        "        )\n" ++
        "    else\n" ++
        "        search(\n" ++
        "            str.ptr,\n" ++
        "        ));\n" ++
        "    return pos;\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "the last link of a chain opens its brackets from the base of the chain" {
    const source = "fn f() void {\n" ++
        "    const y = a\n" ++
        "        .b(\n" ++
        "            x,\n" ++
        "        )\n" ++
        "        .c(\n" ++
        "        y,\n" ++
        "    );\n" ++
        "    const z = .{\n" ++
        "        .accessor = gobject.ext\n" ++
        "            .privateFieldAccessor(\n" ++
        "            Self,\n" ++
        "        ),\n" ++
        "    };\n" ++
        "    _ = .{ y, z };\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a declaration literal heading a branch body is no link of a chain" {
    const source = "fn f() Pin {\n" ++
        "    return if (drag_pin.before(click_pin))\n" ++
        "        .init(\n" ++
        "            word_current.start(),\n" ++
        "            false,\n" ++
        "        )\n" ++
        "    else\n" ++
        "        .init(\n" ++
        "            word_start.start(),\n" ++
        "            false,\n" ++
        "        );\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a looser operator ending a line rebases the binding tiers" {
    const source = "test {\n" ++
        "    try testing.expect(\n" ++
        "        reflowed.total_rows - reflowed.rows <=\n" ++
        "            reflowed.limits.max(.lines) or\n" ++
        "            reflowed.pages.first.? ==\n" ++
        "                reflowed.getTopLeft(.active).node,\n" ++
        "    );\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "an inline initializer pushes no indent around a multiline string" {
    const source = "const x = [_]S{\n" ++
        "    .{ .label = \"main\", .snippet = \"main\" },\n" ++
        "    .{ .label = \"panic\", .snippet =\n" ++
        "    \\\\pub fn panic(\n" ++
        "    \\\\) noreturn {$0}\n" ++
        "    },\n" ++
        "};\n" ++
        "fn f() void {\n" ++
        "    foo(\n" ++
        "        .{ .b =\n" ++
        "        \\\\x\n" ++
        "    },\n" ++
        "        2,\n" ++
        "    );\n" ++
        "    bar(.{\n" ++
        "        .a = 1,\n" ++
        "    }, .{ .b =\n" ++
        "        \\\\x\n" ++
        "    });\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a comment below a multiline string keeps the level of the string" {
    const source = "test \"x\" {\n" ++
        "    try check(\n" ++
        "        \\\\const foo = value.foo();\n" ++
        "        //                  ^^^ resolving foo\n" ++
        "        //                      type parameter\n" ++
        "    , &.{\n" ++
        "        .{ \"const\", .keyword, .{} },\n" ++
        "    });\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "an index past an unwrap or a dereference stands a space off the else" {
    const source = "fn f(x: ?[]const u32, p: *[4]u32, y: ?u32) u32 {\n" ++
        "    const a = if (y) |i| x.?[i]else 0;\n" ++
        "    const b = if (y) |i| p.*[i]else 0;\n" ++
        "    return a + b;\n" ++
        "}\n";

    const wanted = "fn f(x: ?[]const u32, p: *[4]u32, y: ?u32) u32 {\n" ++
        "    const a = if (y) |i| x.?[i] else 0;\n" ++
        "    const b = if (y) |i| p.*[i] else 0;\n" ++
        "    return a + b;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a typed init in a braceless body keeps its brace on the line" {
    const source = "fn f(c: bool, x: []const u8, i: usize) Arg(Id) {\n" ++
        "    if (c)\n" ++
        "        return Arg(Id){ .param = param, .value = x[i + 1 ..] };\n" ++
        "    while (c)\n" ++
        "        y = Pair(u8, u8){ .a = 1 };\n" ++
        "    for (x) |b|\n" ++
        "        y = Pair(u8, u8){ .a = b };\n" ++
        "    if (aaaa and\n" ++
        "        bbbb)\n" ++
        "        y = union(enum) { a: u8 }{ .a = 1 };\n" ++
        "    while (aaaa and\n" ++
        "        bbbb) |*v| : (i += 1)\n" ++
        "    {\n" ++
        "        g(v);\n" ++
        "    }\n" ++
        "    return Arg(Id){ .param = param, .value = x[i..] };\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a pointer's bit range keeps its colons tight" {
    const source = "const A = *align(4: 0: 4) u8;\n" ++
        "const B = *align(@sizeOf(T) : 0 : @sizeOf(T)) const u8;\n" ++
        "const C = *align(blk: {\n" ++
        "    break :blk 4;\n" ++
        "}) u8;\n";

    const wanted = "const A = *align(4:0:4) u8;\n" ++
        "const B = *align(@sizeOf(T):0:@sizeOf(T)) const u8;\n" ++
        "const C = *align(blk: {\n" ++
        "    break :blk 4;\n" ++
        "}) u8;\n";

    try expect_formatted(source, wanted);
}

test "an init on a line a comptime statement leads hugs its type" {
    const source = "fn f() void {\n" ++
        "    comptime var nodes = [_]ListNode{ .{}, .{} };\n" ++
        "    comptime var s = S{ .f = 123 };\n" ++
        "    comptime g(Bar{ .X = 123 });\n" ++
        "    comptime {\n" ++
        "        h();\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a run of casts is reordered only when no cast repeats and no comment falls inside" {
    const source = "fn f() void {\n" ++
        "    _ = @alignCast(@ptrCast(@alignCast(p)));\n" ++
        "    _ = @constCast(@alignCast(@ptrCast(@constCast(@volatileCast(p)))));\n" ++
        "    _ = @alignCast(@ptrCast( // c\n" ++
        "        x));\n" ++
        "    _ = @volatileCast(@addrSpaceCast(@ptrCast(x)));\n" ++
        "    _ = @alignCast(@ptrCast(x, y));\n" ++
        "}\n";

    const wanted = "fn f() void {\n" ++
        "    _ = @alignCast(@ptrCast(@alignCast(p)));\n" ++
        "    _ = @constCast(@alignCast(@ptrCast(@constCast(@volatileCast(p)))));\n" ++
        "    _ = @alignCast(@ptrCast( // c\n" ++
        "        x));\n" ++
        "    _ = @ptrCast(@addrSpaceCast(@volatileCast(x)));\n" ++
        "    _ = @ptrCast(@ptrCast(x, y));\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an asm statement closes on its clobbers and joins its colons when it takes no operand" {
    const source = "fn f() void {\n" ++
        "    asm volatile (\n" ++
        "        \\\\syscall\n" ++
        "        :\n" ++
        "        : [number] \"{rax}\" (158),\n" ++
        "        : .{ .rcx = true, .r11 = true }\n" ++
        "    );\n" ++
        "    asm volatile (\"nop\"\n" ++
        "        :\n" ++
        "        :\n" ++
        "        : .{ .memory = true });\n" ++
        "    asm volatile (\"nop\" :: [a] \"r\" (b),);\n" ++
        "}\n";

    const wanted = "fn f() void {\n" ++
        "    asm volatile (\n" ++
        "        \\\\syscall\n" ++
        "        :\n" ++
        "        : [number] \"{rax}\" (158),\n" ++
        "        : .{ .rcx = true, .r11 = true });\n" ++
        "    asm volatile (\"nop\" ::: .{ .memory = true });\n" ++
        "    asm volatile (\"nop\"\n" ++
        "        :\n" ++
        "        : [a] \"r\" (b),\n" ++
        "    );\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a block a parted header moves to its own line stands at the header's line level" {
    const source = "fn f() void {\n" ++
        "    const x: i9 = @intCast(if (aaaa or\n" ++
        "        bbbb)\n" ++
        "    remaining: {\n" ++
        "        g();\n" ++
        "        break :remaining 0;\n" ++
        "    } else c);\n" ++
        "    const y: i9 = @intCast(if (aaaa or\n" ++
        "        bbbb)\n" ++
        "    {\n" ++
        "        g();\n" ++
        "    } else c);\n" ++
        "    const z = if (a orelse\n" ++
        "        b) |comment|\n" ++
        "    code: {\n" ++
        "        break :code comment;\n" ++
        "    } else full;\n" ++
        "    _ = .{ x, y, z };\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a block label joins a one-line header and leaves a parted one with its brace" {
    const source = "const a = if (c)\n" ++
        "blk: {\n" ++
        "    break :blk 1;\n" ++
        "} else 3;\n" ++
        "fn f() void {\n" ++
        "    const x: i9 = @intCast(if (aaaa or\n" ++
        "        bbbb) remaining: {\n" ++
        "        break :remaining 0;\n" ++
        "    } else c);\n" ++
        "    const y: i9 = @intCast(if (aaaa or\n" ++
        "        bbbb) {\n" ++
        "        g();\n" ++
        "    } else c);\n" ++
        "    _ = .{ x, y };\n" ++
        "}\n";

    const wanted = "const a = if (c) blk: {\n" ++
        "    break :blk 1;\n" ++
        "} else 3;\n" ++
        "fn f() void {\n" ++
        "    const x: i9 = @intCast(if (aaaa or\n" ++
        "        bbbb)\n" ++
        "    remaining: {\n" ++
        "        break :remaining 0;\n" ++
        "    } else c);\n" ++
        "    const y: i9 = @intCast(if (aaaa or\n" ++
        "        bbbb)\n" ++
        "    {\n" ++
        "        g();\n" ++
        "    } else c);\n" ++
        "    _ = .{ x, y };\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a catch operand line steps one level past the line its left operand starts on" {
    const source = "fn f() void {\n" ++
        "    const x = (if (c)\n" ++
        "        a()\n" ++
        "    else\n" ++
        "        b()) catch |e|\n" ++
        "        panic(\"x\", .{e});\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a declaration literal heading a branch body opens its brackets from its own line" {
    const source = "fn f() void {\n" ++
        "    switch (x) {\n" ++
        "        .optional => if (val) |some|\n" ++
        "            .fromInterned(try pt.intern(.{ .opt = .{\n" ++
        "                .ty = ty.toIntern(),\n" ++
        "                .val = 1,\n" ++
        "            } }))\n" ++
        "        else\n" ++
        "            try pt.nullValue(ty),\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "an operator continuation steps one level past the line its left operand starts on" {
    const source = "fn f() void {\n" ++
        "    if (isec.isDontDeadStripIfReferencesLive() and\n" ++
        "        !(mem.eql(u8, isec.sectName(), \"__eh_frame\") or\n" ++
        "            mem.eql(u8, isec.sectName(), \"__compact_unwind\") or\n" ++
        "            isec.attrs() & macho.S_ATTR_DEBUG != 0) and\n" ++
        "        !atom.isAlive() and refersLive(atom, macho_file))\n" ++
        "    {\n" ++
        "        markLive(atom, macho_file);\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "an else if condition under an equals that ended its line realizes no operator indent" {
    const source = "fn f() void {\n" ++
        "    const name =\n" ++
        "        if ((target.cpu.arch.isMIPS() or target.cpu.arch == .alpha) and field_name[0" ++
        "] == 'r') name: {\n" ++
        "            break :name c_name;\n" ++
        "        } else if ((target.cpu.arch.isMIPS() and (mem.startsWith(u8, field_name, \"f" ++
        "cc\") or field_name[0] == 'w')) or\n" ++
        "        ((target.cpu.arch.isMIPS() or target.cpu.arch == .alpha) and field_name[0] =" ++
        "= 'f') or\n" ++
        "        (target.cpu.arch == .kvx and !mem.eql(u8, field_name, \"memory\"))) name: {" ++
        "\n" ++
        "            break :name (&c_name_buf)[0 .. 1 + field_name.len];\n" ++
        "        } else if (target.cpu.arch.isSPARC() and\n" ++
        "        (mem.eql(u8, field_name, \"ccr\") or mem.eql(u8, field_name, \"icc\") or mem" ++
        ".eql(u8, field_name, \"xcc\"))) name: {\n" ++
        "            break :name \"icc\";\n" ++
        "        } else field_name;\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "an operator closed earlier on its line gives back the indent it realized" {
    const source = "fn logSecrets(w: *Writer, context: anytype, secrets: anytype) void {\n" ++
        "    inline for (@typeInfo(@TypeOf(secrets)).@\"struct\".fields) |field| w.print(\"{s" ++
        "}\" ++\n" ++
        "        (if (@hasField(@TypeOf(context), \"counter\")) \"_{d}\" else \"\") ++ \" {x}" ++
        " {x}\\n\", .{field.name} ++\n" ++
        "        (if (@hasField(@TypeOf(context), \"counter\")) .{context.counter} else .{}) " ++
        "++ .{\n" ++
        "        context.client_random,\n" ++
        "        @field(secrets, field.name),\n" ++
        "    }) catch {};\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a trailing comma call on an operator continuation raises its arguments" {
    const source = "fn f() void {\n" ++
        "    const ok_sent = dest_info.sentinel == null or\n" ++
        "        (src_info.sentinel != null and\n" ++
        "            dest_info.sentinel != null and\n" ++
        "            dest_info.sentinel.?.eql(\n" ++
        "                try pt.getCoerced(src_info.sentinel.?, dest_info.elem_type),\n" ++
        "                dest_info.elem_type,\n" ++
        "                zcu,\n" ++
        "            ));\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "an else branch call opens its brackets from the indent its line holds" {
    const source = "fn f() !void {\n" ++
        "    switch (x) {\n" ++
        "        .a => {\n" ++
        "            if (dis.enable_aliases and op == .add and S == false and elide_shift and" ++
        " imm12 == 0 and\n" ++
        "                (Rn.alias == .sp or Rd.alias == .sp)) try writer.print(\"{f}{s}{f}{s" ++
        "}{f}\", .{\n" ++
        "                fmtCase(.mov, dis.case),\n" ++
        "                Rn.fmtCase(dis.case),\n" ++
        "            }) else try writer.print(\"{f}{s}{s}{f}{s}{f}{s}#0x{x}\", .{\n" ++
        "                fmtCase(op, dis.case),\n" ++
        "                imm12,\n" ++
        "            });\n" ++
        "        },\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a switch body on a condition continuation steps from the indent count" {
    const source = "fn f() void {\n" ++
        "    if (is_linux and !mf.flags.fallocate_punch_hole_unsupported and\n" ++
        "        size >= mf.flags.block_size.toByteUnits() * 2 - 1) while (true)\n" ++
        "        switch (linux.errno(linux.fallocate(\n" ++
        "            mf.file.handle,\n" ++
        "            @intCast(size),\n" ++
        "        ))) {\n" ++
        "            .SUCCESS => return,\n" ++
        "            .INTR => continue,\n" ++
        "            else => |e| return std.posix.unexpectedErrno(e),\n" ++
        "        };\n" ++
        "    @memset(x, 0);\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "an init after a multiline string operand steps from its own line" {
    const source = "fn f() void {\n" ++
        "    errdefer std.debug.print(\n" ++
        "        \\\\prev : '{any}'\n" ++
        "        \\\\actual  : {}\n" ++
        "    ++ \"\\n\", .{\n" ++
        "        prev,                                           bytes,                      " ++
        "      old,\n" ++
        "        if (old < expected_len) expected_len else null, betterMatchLen(old, prev, by" ++
        "tes),\n" ++
        "    });\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "an init after an indented else branch steps from the if line" {
    const source = "fn f() void {\n" ++
        "    switch (x) {\n" ++
        "        .sse => if (abi_size <= 16) {\n" ++
        "            try self.asmMemoryRegister(if (self.hasFeature(.avx))\n" ++
        "                .{ .v_dqa, .mov }\n" ++
        "            else if (self.hasFeature(.sse2))\n" ++
        "                .{ ._dqa, .mov }\n" ++
        "            else\n" ++
        "                .{ ._ps, .mova }, .{\n" ++
        "                .base = .{ .frame = frame_index },\n" ++
        "                .mod = .{ .rm = .{ .size = .xword } },\n" ++
        "            }, src_reg.to128());\n" ++
        "        },\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a jump label keeps its space before the brace of an initializer" {
    const source = "fn f() void {\n" ++
        "    g(.{ .t = x orelse break :skip });\n" ++
        "    g(.{ .t = x orelse continue :skip });\n" ++
        "    g(.{ .t = x orelse break :skip, .u = 1 });\n" ++
        "    g(.{ x, break :b });\n" ++
        "    const a = .{ .t = x orelse break };\n" ++
        "}\n";

    try expect_formatted(source, source);
}
