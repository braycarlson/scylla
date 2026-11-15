const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Buffer = @import("../stdx/bounded/buffer.zig");
const EventsType = @import("../syntax/tree.zig").EventsType;
const Formatter = @import("odin.zig").Formatter;
const FormatterError = @import("formatters.zig").FormatterError;
const Input = @import("odin.zig").Input;
const Kind = @import("../syntax/odin/kind.zig").Kind;
const Options = @import("print.zig").Options;
const Parser = @import("../syntax/odin/parse.zig").Parser;
const Span = @import("../stdx/bounded/span.zig");
const Structure = @import("../syntax/tree.zig").Structure;
const Token = @import("../syntax/token.zig");
const Tokens = @import("../syntax/tokens.zig");
const TreeType = @import("../syntax/tree.zig").TreeType;
const corpus = @import("../testing/corpus.zig");
const environment = @import("../testing/environment.zig");
const floor = @import("../testing/floor.zig");
const lex = @import("../syntax/lex.zig").lex;
const oracle = @import("../testing/oracle.zig");
const raw_of = @import("../syntax/raw.zig").raw_of;
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

        held.lexed_of(source);

        try raw_of(Kind, held.tokens.slice(), &held.raw);

        const outcome = held.parsed(source);
        const input = held.input_of(source, outcome);

        assert(input.tokens.len == input.raw.len);
        assert(input.options.tabs);

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

        held.lexed_of(source);

        try raw_of(Kind, held.tokens.slice(), &held.raw);

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
            .options = options,
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

    fn lexed_of(held: *Held, source: []const u8) void {
        assert(source.len <= std.math.maxInt(u32));

        held.tokens.clear();

        lex(.of(.odin), source, &held.tokens) catch |err| switch (err) {
            error.Truncated => assert(held.tokens.items.full()),
        };

        assert(held.tokens.count() <= token_count_max);
    }

    fn classified(held: *Held, source: []const u8) void {
        assert(source.len <= std.math.maxInt(u32));

        held.lexed_of(source);

        raw_of(Kind, held.tokens.slice(), &held.raw) catch unreachable;

        assert(held.raw.count() == held.tokens.count());
        assert(held.raw.count() <= token_count_max);
    }

    fn words(held: *Held, arena: std.mem.Allocator, source: []const u8) ![]const []const u8 {
        assert(source.len <= std.math.maxInt(u32));

        held.lexed_of(source);

        const lexed = held.tokens.slice();
        var listed: std.ArrayList([]const u8) = try .initCapacity(arena, lexed.len);

        for (lexed) |token| {
            const structural = token.kind == .block_end or token.kind == .block_start or
                token.kind == .newline;

            if (structural) continue;
            if (token.length == 0) continue;

            listed.appendAssumeCapacity(word_of(token, source));
        }

        assert(listed.items.len <= lexed.len);
        assert(listed.capacity >= lexed.len);

        return listed.items;
    }

    fn kinds(
        held: *Held,
        gpa: std.mem.Allocator,
        source: []const u8,
        found: *std.ArrayList(Kind),
    ) !void {
        assert(source.len <= std.math.maxInt(u32));

        held.classified(source);

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

        held.classified(source);

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

    fn expect_stable(twice: *Twice, source: []const u8) !void {
        assert(source.len > 0);
        assert(twice.first.capacity() == out_bytes_max);

        const first = twice.held.format(source, &twice.first);

        try require(is_complete(first), "{s} is not formatted", .{source});

        const once = twice.first.const_slice();
        const second = twice.held.format(once, &twice.second);

        try require(is_complete(second), "{s} is not formatted twice", .{source});
        try expect_text(source, "is not idempotent", once, twice.second.const_slice());
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
const dump_variable = "SCYLLA_FORMAT_DUMP";
const element_count_max: u32 = 1 << 18;
const diagnostic_count_max: u32 = 1 << 12;
const event_count_max: u32 = 1 << 20;
const every_category = [_][]const u8{"odinfmt-absent"};
const extension = ".odin";
const file_count_max: u32 = 1 << 20;
const fixture_count_min: u32 = 4;
const fixture_root = "tests/fixtures/odin";
const golden_root = "tests/fixtures/golden-odinfmt";
const node_count_max: u32 = 1 << 18;

const options: Options = .{
    .indent_width = Options.default.indent_width,
    .line_width = Options.default.line_width,
    .tabs = true,
};

const out_bytes_max: u32 = 1 << 22;
const path_bytes_max: u32 = 4096;
const residue_name = "residue-format-odin.json";
const skipped_names = [_][]const u8{ "dedent", "indent", "newline" };
const source_bytes_max: u32 = 1 << 28;
const token_count_max: u32 = 1 << 18;

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
    return token.text(source);
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

fn dumped(root: []const u8) bool {
    const io = std.testing.io;

    assert(root.len > 0);

    var directory = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return false;
    defer directory.close(io);

    var iterator = directory.iterate();
    const entry = iterator.next(io) catch return true;

    if (entry) |held| assert(held.name.len > 0);

    return entry != null;
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

fn is_refused(result: HeldError!void) bool {
    if (!std.meta.isError(result)) return false;

    result catch |err| switch (err) {
        error.OutputExhausted, error.Truncated => return false,
        error.SourceInvalid => return true,
    };

    return false;
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
        twice.held.format(fixture.source, &twice.first) catch continue;

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
        held.format(fixture.source, &out) catch continue;

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
        held.format(fixture.source, &out) catch continue;

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
        held.format(fixture.source, &out) catch continue;

        try write_under(root, fixture.name, out.const_slice());
    }
}

test "the formatted output matches the oracle modulo residue" {
    const gpa = std.testing.allocator;
    var carried = try oracle.residue_of(gpa, residue_name, &every_category);
    defer carried.deinit(gpa);

    if (!dumped(golden_root)) return;

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

        const outcome = held.format(fixture.source, &out);
        const refused = "{s} is refused and no residue row names it";

        try require(is_complete(outcome), refused, .{fixture.name});

        const golden = try read_under(gpa, golden_root, fixture.name);
        defer gpa.free(golden);

        const message = "diverges from odinfmt and no residue row names it";

        try expect_text(fixture.name, message, golden, out.const_slice());

        compared += 1;
    }

    try require(
        compared >= floor.fixture_format_odin,
        "the Odin fixtures lost a formatting: {d} compared, floor {d}",
        .{ compared, floor.fixture_format_odin },
    );
}

test "every residue row names a fixture that diverges" {
    const gpa = std.testing.allocator;
    var carried = try oracle.residue_of(gpa, residue_name, &every_category);
    defer carried.deinit(gpa);

    if (!dumped(golden_root)) return;

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    for (carried.fixtures.items) |name| {
        const source = try read_under(gpa, fixture_root, name);
        defer gpa.free(source);

        held.format(source, &out) catch continue;

        const golden = try read_under(gpa, golden_root, name);
        defer gpa.free(golden);

        const diverged = !std.mem.eql(u8, out.const_slice(), golden);

        try require(diverged, "{s} matches odinfmt and needs no residue row", .{name});
    }
}

test "a file that does not parse is refused" {
    const gpa = std.testing.allocator;
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    try std.testing.expectError(error.SourceInvalid, held.format("main :: proc( {\n", &out));
    try std.testing.expect(out.empty());
}

test "a line continuation does not break the statement it joins" {
    const gpa = std.testing.allocator;

    const source = "package p\n\nf :: proc() {\n\tif a == 1 \\\n\t|| b == 2 {\n" ++
        "\t\tc := 3\n\t}\n}\n";

    var twice: Twice = undefined;

    try twice.init(gpa);
    defer twice.deinit(gpa);

    try twice.expect_stable(source);
}

test "an unclosed triple quoted string is refused" {
    const gpa = std.testing.allocator;

    const sources = [_][]const u8{
        "\"\"\"",
        "\"\"\"\n",
        "```",
        "\"\"\"\"\"\"\"\"\"\"\"\"\"\"\"",
    };

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    for (sources) |source| {
        const outcome = held.format(source, &out);

        try require(is_refused(outcome), "{s} is not refused", .{source});
    }
}

test "a closed triple quoted string still formats" {
    const gpa = std.testing.allocator;
    const source = "main :: proc() {\n\ttext := \"\"\"a\nb\"\"\"\n}\n";
    var twice: Twice = undefined;

    try twice.init(gpa);
    defer twice.deinit(gpa);

    try twice.expect_stable(source);
}

test "a mark that was apart from its name is not glued to it" {
    const gpa = std.testing.allocator;
    const source = "@\x0c@\x0c\xc0";
    var twice: Twice = undefined;

    try twice.init(gpa);
    defer twice.deinit(gpa);

    try twice.expect_stable(source);
}

test "a mark written against its name stays against it" {
    const gpa = std.testing.allocator;
    const source = "@(private)\nmain :: proc() {\n\t#partial switch x {\n\t}\n}\n";
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    try held.format(source, &out);

    const formatted = out.const_slice();

    try require(std.mem.find(u8, formatted, "@(private)") != null, "{s}", .{formatted});
    try require(std.mem.find(u8, formatted, "#partial switch") != null, "{s}", .{formatted});
}

test "a build tag keeps no blank between itself and the comment it trails" {
    const gpa = std.testing.allocator;

    const sources = [_][]const u8{
        "#+build linux // only there\npackage main\n",
        "#+private //x\n",
        "#+//&",
    };

    var twice: Twice = undefined;

    try twice.init(gpa);
    defer twice.deinit(gpa);

    for (sources) |source| {
        try twice.expect_stable(source);
    }
}

test "a block comment that never closes its nesting is refused" {
    const gpa = std.testing.allocator;
    const sources = [_][]const u8{ "/*/*/", "x/*/*/", "/* /*" };
    const closed = [_][]const u8{ "/* a */\n", "/* /* b */ */\n" };
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    for (sources) |source| {
        const outcome = held.format(source, &out);

        try require(is_refused(outcome), "{s} is not refused", .{source});
    }

    for (closed) |source| {
        const outcome = held.format(source, &out);

        try require(is_complete(outcome), "{s} is not formatted", .{source});
    }
}

test "a dot apart from a digit is not glued into a number" {
    const gpa = std.testing.allocator;
    const source = "d.\x0c0";
    var twice: Twice = undefined;

    try twice.init(gpa);
    defer twice.deinit(gpa);

    try twice.expect_stable(source);
}

test "a dot written against its field stays against it" {
    const gpa = std.testing.allocator;
    const source = "main :: proc() {\n\tx := held . field\n\ty := held.other\n}\n";
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    try held.format(source, &out);

    const formatted = out.const_slice();

    try require(std.mem.find(u8, formatted, "held.field") != null, "{s}", .{formatted});
    try require(std.mem.find(u8, formatted, "held.other") != null, "{s}", .{formatted});
}

test "a range reads back the lines it names" {
    const gpa = std.testing.allocator;
    const source = "main :: proc() {\nx:=1\n}\n";
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

test "the fixtures are already formatted" {
    const gpa = std.testing.allocator;
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    for (found.items) |fixture| {
        const outcome = held.format(fixture.source, &out);

        try require(is_complete(outcome), "{s}", .{fixture.name});

        const message = "is not what the formatter writes";

        try expect_text(fixture.name, message, fixture.source, out.const_slice());
    }
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
