const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Buffer = @import("../stdx/bounded/buffer.zig");
const EventsType = @import("../syntax/tree.zig").EventsType;
const Formatter = @import("go.zig").Formatter;
const FormatterError = @import("formatters.zig").FormatterError;
const Input = @import("go.zig").Input;
const Kind = @import("../syntax/go/kind.zig").Kind;
const Options = @import("print.zig").Options;
const Parser = @import("../syntax/go/parse.zig").Parser;
const Span = @import("../stdx/bounded/span.zig");
const Structure = @import("../syntax/tree.zig").Structure;
const Token = @import("../syntax/token.zig");
const Tokens = @import("../syntax/tokens.zig");
const TreeType = @import("../syntax/tree.zig").TreeType;
const corpus = @import("../testing/corpus.zig");
const environment = @import("../testing/environment.zig");
const floor = @import("../testing/floor.zig");
const lex = @import("../syntax/lex.zig").lex;
const raw_of = @import("../syntax/raw.zig").raw_of;
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

    fn classified(held: *Held, source: []const u8) error{Truncated}!void {
        assert(source.len <= std.math.maxInt(u32));

        held.tokens.clear();

        lex(.of(.go), source, &held.tokens) catch |err| switch (err) {
            error.Truncated => assert(held.tokens.items.full()),
        };

        try raw_of(Kind, held.tokens.slice(), &held.raw);

        assert(held.raw.count() == held.tokens.count());
        assert(held.raw.count() <= token_count_max);
    }

    fn comments(held: *Held, arena: std.mem.Allocator, source: []const u8) ![]const []const u8 {
        assert(source.len <= std.math.maxInt(u32));

        held.classified(source) catch unreachable;

        const raw = held.raw.const_slice();
        const tokens = held.tokens.slice();

        assert(raw.len == tokens.len);

        var listed: std.ArrayList([]const u8) = .empty;

        for (raw, tokens) |kind, token| {
            if (kind != .comment) continue;

            const text = token.text(source);
            if (constraining(text)) continue;

            var split = std.mem.tokenizeAny(u8, bodied(text), ascii_whitespace);

            for (0..text.len) |_| {
                const word = split.next() orelse break;

                try listed.append(arena, word);
            }
        }

        assert(listed.items.len <= source.len);

        return listed.items;
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

    fn kinds(held: *Held, arena: std.mem.Allocator, source: []const u8) ![]const Kind {
        assert(source.len <= std.math.maxInt(u32));

        held.classified(source) catch unreachable;

        const raw = held.raw.const_slice();
        const tokens = held.tokens.slice();

        assert(raw.len == tokens.len);

        var found: std.ArrayList(Kind) = try .initCapacity(arena, raw.len);
        var commented = false;

        for (raw, tokens) |kind, token| {
            if (kinds_skipped(kind)) continue;

            const comment = kind == .comment;

            if (comment) {
                if (constraining(token.text(source))) continue;
                if (commented) continue;
            }

            found.appendAssumeCapacity(kind);
            commented = comment;
        }

        assert(found.items.len <= raw.len);

        return found.items;
    }

    fn parsed(held: *Held, source: []const u8) Structure {
        const tokens = held.tokens.slice();
        const raw = held.raw.const_slice();

        assert(tokens.len == raw.len);
        assert(source.len <= std.math.maxInt(u32));

        return held.parser.build(source, tokens, raw, held.events, &held.tree);
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

const Fixture = corpus.File;

const RelationsWorker = struct {
    arena: std.heap.ArenaAllocator,
    twice: Twice,

    pub const Item = Fixture;
    pub const Shared = struct {};
    pub const Tally = struct {};
    pub const weight = Fixture.weight;

    pub fn init(worker: *RelationsWorker, gpa: std.mem.Allocator, shared: *const Shared) !void {
        assert(@TypeOf(shared.*) == Shared);

        worker.arena = .init(gpa);
        errdefer worker.arena.deinit();

        try worker.twice.init(gpa);

        assert(worker.twice.first.empty());
    }

    pub fn deinit(worker: *RelationsWorker, gpa: std.mem.Allocator) void {
        assert(worker.twice.first.capacity() == out_bytes_max);

        worker.twice.deinit(gpa);
        worker.arena.deinit();
        worker.* = undefined;
    }

    pub fn visit(worker: *RelationsWorker, fixture: *const Fixture, tally: *Tally) !void {
        assert(@TypeOf(tally.*) == Tally);
        assert(fixture.name.len > 0);

        const twice = &worker.twice;

        twice.held.format(fixture.source, &twice.first) catch return;

        _ = worker.arena.reset(.retain_capacity);

        const allocator = worker.arena.allocator();
        const once = twice.first.const_slice();
        const before = try twice.held.kinds(allocator, fixture.source);
        const after = try twice.held.kinds(allocator, once);
        const tokens_kept = try kept(allocator, before, after);

        try require(tokens_kept, "{s} lost a token", .{fixture.name});
        try expect_sorted_comments(allocator, &twice.held, fixture, once);

        const second = twice.held.format(once, &twice.second);

        try require(is_complete(second), "{s}", .{fixture.name});
        try expect_text(fixture.name, "is not idempotent", once, twice.second.const_slice());
    }
};

const ascii_whitespace = " \t\n\x0c\r";
const declaring_words = [_][]const u8{ "const ", "func ", "type ", "var " };
const dump_variable = "SCYLLA_FORMAT_DUMP";
const element_count_max: u32 = 1 << 18;
const diagnostic_count_max: u32 = 1 << 12;
const event_count_max: u32 = 1 << 20;

const every_category = [_][]const u8{
    "gofmt-declaration-context",
    "gofmt-import-grouping",
    "gofmt-operator-precedence-spacing",
};

const extension = ".go";
const file_count_max: u32 = 1 << 20;
const fixture_count_min: u32 = 4;
const fixture_root = "tests/fixtures/go";
const golden_root = "tests/fixtures/golden-gofmt";
const node_count_max: u32 = 1 << 18;

const options: Options = .{
    .indent_width = 8,
    .line_width = Options.default.line_width,
    .tabs = true,
};

const out_bytes_max: u32 = 1 << 22;
const path_bytes_max: u32 = 4096;
const residue_name = "residue-format-go.json";
const skipped_names = [_][]const u8{ "dedent", "indent", "newline" };
const source_bytes_max: u32 = 1 << 28;
const token_count_max: u32 = 1 << 18;

fn bodied(text: []const u8) []const u8 {
    assert(text.len <= std.math.maxInt(u32));

    const opened = std.mem.startsWith(u8, text, "//") or std.mem.startsWith(u8, text, "/*");
    const held = if (opened) text["//".len..] else text;
    const closed = std.mem.endsWith(u8, held, "*/");
    const body = if (closed) held[0 .. held.len - "*/".len] else held;

    assert(held.len <= text.len);
    assert(body.len <= held.len);

    return body;
}

fn constraining(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    const held = std.mem.trimStart(u8, text, ascii_whitespace);

    assert(held.len <= text.len);

    if (std.mem.startsWith(u8, held, "//go:build")) return true;
    if (!std.mem.startsWith(u8, held, "//")) return false;

    const rest = std.mem.trimStart(u8, held["//".len..], ascii_whitespace);

    assert(rest.len < held.len);

    return std.mem.startsWith(u8, rest, "+build");
}

fn corpus_selected(basename: []const u8) bool {
    assert(basename.len > 0);

    return std.mem.eql(u8, std.Io.Dir.path.extension(basename), extension);
}

fn declares(line: []const u8) bool {
    assert(line.len <= std.math.maxInt(u32));

    for (declaring_words) |word| {
        if (std.mem.startsWith(u8, line, word)) return true;
    }

    return false;
}

fn droppable(kind: Kind) bool {
    if (!kind.is_token()) return false;

    return switch (kind) {
        .comma, .paren_close, .paren_open, .semicolon => true,
        else => false,
    };
}

fn expect_containing(source: []const u8, needle: []const u8) !void {
    const gpa = std.testing.allocator;

    assert(source.len > 0);
    assert(needle.len > 0);

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    try held.format(source, &out);

    const formatted = out.const_slice();
    const contained = std.mem.find(u8, formatted, needle) != null;

    try require(contained, "{s}", .{formatted});
}

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

fn expect_kinds(
    arena: std.mem.Allocator,
    held: *Held,
    fixture: *const Fixture,
    formatted: []const u8,
) !void {
    assert(formatted.len <= std.math.maxInt(u32));

    const before = try held.kinds(arena, fixture.source);
    const after = try held.kinds(arena, formatted);
    const head_before = try held.kinds(arena, fixture.source[0..imports_end(fixture.source)]);
    const head_after = try held.kinds(arena, formatted[0..imports_end(formatted)]);
    const split_before = (try sequenced(arena, before[0..head_before.len])).len;
    const split_after = (try sequenced(arena, after[0..head_after.len])).len;
    const order_before = try sequenced(arena, before);
    const order_after = try sequenced(arena, after);
    const settled_before = try settled(Kind, arena, order_before, split_before, kind_less_than);
    const settled_after = try settled(Kind, arena, order_after, split_after, kind_less_than);

    assert(settled_before.len <= before.len);
    assert(settled_after.len <= after.len);

    const same = std.mem.eql(Kind, settled_before, settled_after);

    if (!same) std.debug.print("{s} lost or gained a token\n", .{fixture.name});

    try std.testing.expectEqualSlices(Kind, settled_before, settled_after);

    const comments_kept = comments_of(before) == comments_of(after);

    try require(comments_kept, "{s} lost or gained a comment", .{fixture.name});
}

fn expect_settled_words(
    arena: std.mem.Allocator,
    held: *Held,
    fixture: *const Fixture,
    formatted: []const u8,
) !void {
    assert(formatted.len <= std.math.maxInt(u32));

    const before = try held.words(arena, fixture.source);
    const after = try held.words(arena, formatted);
    const head_before = try held.words(arena, fixture.source[0..imports_end(fixture.source)]);
    const head_after = try held.words(arena, formatted[0..imports_end(formatted)]);
    const settled_before = try settled([]const u8, arena, before, head_before.len, word_less_than);
    const settled_after = try settled([]const u8, arena, after, head_after.len, word_less_than);
    const message = "split, joined, lost, or gained a word";

    assert(settled_before.len == before.len);
    assert(settled_after.len == after.len);

    try expect_words(fixture.name, message, settled_before, settled_after);
}

fn expect_sorted_comments(
    arena: std.mem.Allocator,
    held: *Held,
    fixture: *const Fixture,
    once: []const u8,
) !void {
    assert(once.len <= std.math.maxInt(u32));

    const before = try held.comments(arena, fixture.source);
    const after = try held.comments(arena, once);
    const sorted_before = try settled([]const u8, arena, before, before.len, word_less_than);
    const sorted_after = try settled([]const u8, arena, after, after.len, word_less_than);
    const joined_before = try std.mem.join(arena, " ", sorted_before);
    const joined_after = try std.mem.join(arena, " ", sorted_after);

    assert(sorted_before.len == before.len);
    assert(sorted_after.len == after.len);

    try expect_text(fixture.name, "lost a comment", joined_before, joined_after);
}

fn expect_stable_containing(source: []const u8, needle: []const u8) !void {
    const gpa = std.testing.allocator;

    assert(source.len > 0);
    assert(needle.len > 0);

    var twice: Twice = undefined;

    try twice.init(gpa);
    defer twice.deinit(gpa);

    try twice.held.format(source, &twice.first);

    const once = twice.first.const_slice();
    const contained = std.mem.find(u8, once, needle) != null;

    try require(contained, "{s}", .{once});
    try twice.held.format(once, &twice.second);
    try std.testing.expectEqualStrings(once, twice.second.const_slice());
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

fn expect_words(
    name: []const u8,
    comptime message: []const u8,
    before: []const []const u8,
    after: []const []const u8,
) !void {
    assert(before.len <= std.math.maxInt(u32));
    assert(after.len <= std.math.maxInt(u32));

    const shared = @min(before.len, after.len);

    comptime assert(message.len > 0);
    assert(name.len > 0);
    assert(shared <= before.len);

    for (0..shared) |index| {
        if (std.mem.eql(u8, before[index], after[index])) continue;

        const changed = "{s} " ++ message ++ ": word {d} `{s}` became `{s}`\n";

        std.debug.print(changed, .{ name, index, before[index], after[index] });

        return error.TestUnexpectedResult;
    }

    try require(
        before.len == after.len,
        "{s} " ++ message ++ ": {d} words became {d}",
        .{ name, before.len, after.len },
    );
}

fn fixture_less_than(context: void, left: Fixture, right: Fixture) bool {
    _ = context;

    assert(left.name.len > 0);
    assert(right.name.len > 0);

    return std.mem.lessThan(u8, left.name, right.name);
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

fn imports_end(source: []const u8) usize {
    assert(source.len <= std.math.maxInt(u32));

    var lines = std.mem.splitScalar(u8, source, '\n');
    var offset: usize = 0;

    for (0..source.len + 1) |_| {
        const line = lines.next() orelse break;
        if (declares(line)) return offset;

        offset += line.len + 1;
    }

    assert(offset == source.len + 1);

    return source.len;
}

fn kept(arena: std.mem.Allocator, before: []const Kind, after: []const Kind) !bool {
    assert(before.len <= std.math.maxInt(u32));
    assert(after.len <= std.math.maxInt(u32));

    const held = try sequenced(arena, before);
    const printing = try sequenced(arena, after);
    var printed: usize = 0;
    var source: usize = 0;

    for (0..held.len) |_| {
        if (printed == printing.len) break;

        if (held[source] == printing[printed]) {
            printed += 1;
            source += 1;

            continue;
        }

        if (!droppable(held[source])) return false;

        source += 1;
    }

    for (held[source..]) |kind| {
        if (!droppable(kind)) break;

        source += 1;
    }

    assert(source <= held.len);
    assert(printed <= printing.len);

    return source == held.len and printed == printing.len;
}

fn kind_less_than(context: void, left: Kind, right: Kind) bool {
    _ = context;

    assert(left.is_token());
    assert(right.is_token());

    return @backingInt(left) < @backingInt(right);
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

fn read_under(gpa: std.mem.Allocator, root: []const u8, name: []const u8) ![]u8 {
    assert(root.len > 0);
    assert(name.len > 0);

    var path_buffer: [path_bytes_max]u8 = undefined;
    const path = try std.mem.print(&path_buffer, "{s}/{s}", .{ root, name });
    const limit: std.Io.Limit = .limited(source_bytes_max);

    assert(path.len > name.len);

    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, limit);
}

fn comments_of(kinds: []const Kind) usize {
    assert(kinds.len <= std.math.maxInt(u32));

    var count: usize = 0;

    for (kinds) |kind| {
        if (kind == .comment) count += 1;
    }

    assert(count <= kinds.len);

    return count;
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

fn outcome_name(result: HeldError!void) []const u8 {
    result catch |err| return @errorName(err);

    return "complete";
}

fn require(condition: bool, comptime format: []const u8, arguments: anytype) !void {
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    if (condition) return;

    std.debug.print(format ++ "\n", arguments);

    return error.TestUnexpectedResult;
}

fn sequenced(arena: std.mem.Allocator, kinds: []const Kind) ![]const Kind {
    assert(kinds.len <= std.math.maxInt(u32));

    var listed: std.ArrayList(Kind) = try .initCapacity(arena, kinds.len);

    for (kinds) |kind| {
        if (kind == .comment) continue;

        listed.appendAssumeCapacity(kind);
    }

    assert(listed.items.len <= kinds.len);
    assert(listed.capacity >= kinds.len);

    return listed.items;
}

fn settled(
    comptime T: type,
    arena: std.mem.Allocator,
    items: []const T,
    split: usize,
    comptime less_than: fn (void, T, T) bool,
) ![]const T {
    assert(items.len <= std.math.maxInt(u32));
    assert(split < std.math.maxInt(u32));

    const bound = @min(split, items.len);
    const sorted = try arena.dupe(T, items);

    std.mem.sort(T, sorted[0..bound], {}, less_than);

    assert(sorted.len == items.len);
    assert(bound <= sorted.len);

    return sorted;
}

fn word_less_than(context: void, left: []const u8, right: []const u8) bool {
    _ = context;

    assert(left.len > 0);
    assert(right.len > 0);

    return std.mem.lessThan(u8, left, right);
}

fn word_of(token: Token, source: []const u8) []const u8 {
    assert(token.length > 0);
    assert(token.end() <= source.len);

    if (token.kind == .string) return "<string>";
    return token.text(source);
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
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    for (found.items) |*fixture| {
        try held.format(fixture.source, &out);

        _ = arena.reset(.retain_capacity);

        try expect_kinds(arena.allocator(), &held, fixture, out.const_slice());
    }
}

test "formatting keeps every comment it was given" {
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
        try held.format(fixture.source, &out);

        _ = arena.reset(.retain_capacity);

        const before = try held.comments(arena.allocator(), fixture.source);
        const after = try held.comments(arena.allocator(), out.const_slice());

        try expect_words(fixture.name, "lost a comment", before, after);
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

        const message = "diverges from gofmt and no residue row names it";

        try expect_text(fixture.name, message, golden, out.const_slice());

        compared += 1;
    }

    try require(
        compared >= floor.fixture_format_go,
        "the Go fixtures lost a formatting: {d} compared, floor {d}",
        .{ compared, floor.fixture_format_go },
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

        try require(diverged, "{s} matches gofmt and needs no residue row", .{name});
    }
}

test "a file that does not parse is refused" {
    const gpa = std.testing.allocator;
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    try std.testing.expectError(error.SourceInvalid, held.format("func f( {\n", &out));
    try std.testing.expect(out.empty());
}

test "a source that never closes a string or a comment is refused" {
    const gpa = std.testing.allocator;

    const sources = [_][]const u8{
        "package packa/*iex",
        "package fixtUre/* ",
        "package p\n\nfunc f() {\n\ts := \"open\n}\n",
    };

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    for (sources) |source| {
        const outcome = held.format(source, &out);

        try require(is_refused(outcome), "{s} for \"{s}\"", .{ outcome_name(outcome), source });
    }
}

test "alignment leaves a block comment the text it was given" {
    const gpa = std.testing.allocator;

    const source = "package p\n\n" ++
        "func f() {\n" ++
        "\t/* 0 = block */\n" ++
        "\t/* 8 = stream */\n" ++
        "\ta := 1\n" ++
        "\tbb := 2\n" ++
        "}\n";

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    try held.format(source, &out);

    const before = try held.comments(arena.allocator(), source);
    const after = try held.comments(arena.allocator(), out.const_slice());

    try std.testing.expectEqualDeep(before, after);
}

test "alignment leaves the bytes of a raw string alone" {
    const source = "package i\n\n" ++
        "func run() {\n" ++
        "\ttext := `n*/\n" ++
        "\t_ =\n" ++
        "\t=  =_ =`\n" ++
        "}\n";

    try expect_containing(source, "`n*/\n\t_ =\n\t=  =_ =`");
}

test "a quoted backtick does not open a raw string for alignment" {
    const source = "package i\n\n" ++
        "var (\n" ++
        "\ttick = \"`\"\n" ++
        "\tone = 1\n" ++
        "\tlonger = 2\n" ++
        ")\n";

    try expect_stable_containing(source, "one    = 1");
}

test "a comment above an empty statement stays on its own line" {
    const source = "package p\n\n" ++
        "func f() {\n" ++
        "\tx := 1 // c\n" ++
        "\t;\n" ++
        "\t_ = x\n" ++
        "}\n";

    try expect_stable_containing(source, "\tx := 1 // c\n");
}

test "a blank line between the comments of an otherwise empty body is kept" {
    const source = "package p\n\n" ++
        "func f() {\n" ++
        "\t// a\n\n" ++
        "\t// b\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a channel arrow beside a unary minus formats twice" {
    const gpa = std.testing.allocator;
    const sources = [_][]const u8{ "package i\nfunc {m<--l:}", "package i\nfunc {m<--\nn:}" };
    var twice: Twice = undefined;

    try twice.init(gpa);
    defer twice.deinit(gpa);

    for (sources) |source| {
        twice.held.format(source, &twice.first) catch continue;

        const once = twice.first.const_slice();
        const second = twice.held.format(once, &twice.second);

        try require(is_complete(second), "{s}", .{once});
        try std.testing.expectEqualStrings(once, twice.second.const_slice());
    }
}

test "a channel send keeps its unary minus apart" {
    const source = "package i\n\n" ++
        "func run(c chan int, x int) {\n" ++
        "\tc <--x\n" ++
        "}\n";

    try expect_containing(source, "c <- -x");
}

test "a range reads back the lines it names" {
    const gpa = std.testing.allocator;
    const source = "package main\n\nfunc f() {\nx := 1\n_ = x\n}\n";
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

    for (found.items) |*fixture| {
        held.format(fixture.source, &out) catch continue;

        _ = arena.reset(.retain_capacity);

        try expect_settled_words(arena.allocator(), &held, fixture, out.const_slice());
    }
}

test "a field comment takes no column of its own" {
    const source = "package p\n\n" ++
        "type T struct {\n" ++
        "\tA int `x` // a\n" ++
        "\tBcd string // b\n" ++
        "\tEf bool `yy` // e\n" ++
        "}\n";

    const wanted = "package p\n\n" ++
        "type T struct {\n" ++
        "\tA   int    `x` // a\n" ++
        "\tBcd string // b\n" ++
        "\tEf  bool   `yy` // e\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a field type takes a column only where a cell stands past it" {
    const source = "package p\n\n" ++
        "type A struct {\n" ++
        "\tA int\n" ++
        "\tBcd string\n" ++
        "}\n\n" ++
        "type B struct {\n" ++
        "\tA int // a\n" ++
        "\tBcd string // b\n" ++
        "}\n";

    const wanted = "package p\n\n" ++
        "type A struct {\n" ++
        "\tA   int\n" ++
        "\tBcd string\n" ++
        "}\n\n" ++
        "type B struct {\n" ++
        "\tA   int    // a\n" ++
        "\tBcd string // b\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a statement that reads like a field takes no type column" {
    const source = "package p\n\n" ++
        "func f() {\n" ++
        "\tline1 := \"one\"\n" ++
        "\trestData := \"two\"\n" ++
        "\tuse(line1 + \"lib\" + restData)\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "an operator that would glue into a longer one keeps its blanks" {
    const source = "package p\n\n" ++
        "func f(x, y, z int) {\n" ++
        "\tif x & ^(y|z) != 0 {\n" ++
        "\t}\n" ++
        "\t_ = x&y + z\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a comment under a continuation stands where the source put it" {
    const source = "package p\n\n" ++
        "const q = \"\" +\n" ++
        "\t\"a\" +\n" ++
        "\t\"\"\n" ++
        "\t// the run's own remark\n\n" ++
        "func f() {\n" ++
        "\tskip := 1 +\n" ++
        "\t\t2 +\n" ++
        "\t\t3\n" ++
        "\t// the statement's remark\n" ++
        "\tskip += 4\n" ++
        "\theld := 1 +\n" ++
        "\t\t2\n" ++
        "\t\t// the run's own remark\n" ++
        "\theld += 3\n" ++
        "\t_ = held\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a spec group gives its type a column of its own" {
    const source = "package p\n\n" ++
        "const (\n" ++
        "RecvDir ChanDir = 1 << iota // one\n" ++
        "SendDir // two\n" ++
        "BothDir = RecvDir | SendDir // three\n" ++
        ")\n";

    const wanted = "package p\n\n" ++
        "const (\n" ++
        "\tRecvDir ChanDir             = 1 << iota // one\n" ++
        "\tSendDir                                 // two\n" ++
        "\tBothDir = RecvDir | SendDir             // three\n" ++
        ")\n";

    try expect_formatted(source, wanted);
}

test "a spec whose comment is a block comment holds the name column open" {
    const source = "package p\n\n" ++
        "const (\n" ++
        "C_NONE = iota\n" ++
        "C_REGP /* even gpr pair */\n" ++
        "C_LONGNAME /* long */\n" ++
        ")\n";

    const wanted = "package p\n\n" ++
        "const (\n" ++
        "\tC_NONE     = iota\n" ++
        "\tC_REGP     /* even gpr pair */\n" ++
        "\tC_LONGNAME /* long */\n" ++
        ")\n";

    try expect_formatted(source, wanted);
}

test "a line of two elements takes the key column and ends the run" {
    const source = "package p\n\n" ++
        "var x = T{\n" ++
        "Name: \"a\",\n" ++
        "Mode: 0644,\n" ++
        "Uid: 1000, Gid: 1000,\n" ++
        "Uname: \"b\",\n" ++
        "}\n";

    const wanted = "package p\n\n" ++
        "var x = T{\n" ++
        "\tName: \"a\",\n" ++
        "\tMode: 0644,\n" ++
        "\tUid:  1000, Gid: 1000,\n" ++
        "\tUname: \"b\",\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a line that closes the literal it stands in still holds a key" {
    const source = "package p\n\n" ++
        "var z = Dialer{\n" ++
        "KeepAlive: def,\n" ++
        "KeepAliveConfig: cfg}\n";

    const wanted = "package p\n\n" ++
        "var z = Dialer{\n" ++
        "\tKeepAlive:       def,\n" ++
        "\tKeepAliveConfig: cfg}\n";

    try expect_formatted(source, wanted);
}

test "a comment column ends at the element that spells its own lines" {
    const source = "package p\n\n" ++
        "var decoders = []decoder{\n" ++
        "func(b *buffer) error { return decodeA(b) }, // one\n" ++
        "func(b *buffer) error { return decodeBB(b) }, // two\n" ++
        "func(b *buffer) error { // three spans lines\n" ++
        "return nil\n" ++
        "},\n" ++
        "}\n\n" ++
        "func f(edit E, src string) {\n" ++
        "if edit.Start > 0 && src[edit.Start-1] != 'x' || // not at line start\n" ++
        "edit.End > 0 && src[edit.End-1] != 'y' { // partial insert\n" ++
        "goto expand // slow path\n" ++
        "}\n" ++
        "}\n";

    const wanted = "package p\n\n" ++
        "var decoders = []decoder{\n" ++
        "\tfunc(b *buffer) error { return decodeA(b) },  // one\n" ++
        "\tfunc(b *buffer) error { return decodeBB(b) }, // two\n" ++
        "\tfunc(b *buffer) error { // three spans lines\n" ++
        "\t\treturn nil\n" ++
        "\t},\n" ++
        "}\n\n" ++
        "func f(edit E, src string) {\n" ++
        "\tif edit.Start > 0 && src[edit.Start-1] != 'x' || // not at line start\n" ++
        "\t\tedit.End > 0 && src[edit.End-1] != 'y' { // partial insert\n" ++
        "\t\tgoto expand // slow path\n" ++
        "\t}\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a spec group reads its binary operators at the declarations own depth" {
    const source = "package p\n\n" ++
        "const (\n" ++
        "lineBits, lineMax = 20, 1<<lineBits - 2\n" ++
        "_, _ uint64 = 2 * iota, 1 << iota\n" ++
        ")\n";

    const wanted = "package p\n\n" ++
        "const (\n" ++
        "\tlineBits, lineMax        = 20, 1<<lineBits - 2\n" ++
        "\t_, _              uint64 = 2 * iota, 1 << iota\n" ++
        ")\n";

    try expect_formatted(source, wanted);
}

test "a doc comment writes its indented run as a block of its own" {
    const source = "package p\n\n" ++
        "//Doc says what f does.\n" ++
        "//\n" ++
        "// ParamFlags\n" ++
        "//   0 ParamFeedsIfOrSwitch\n" ++
        "// <endpropsdump>\n" ++
        "func f() {}\n\n" ++
        "// Held is a value.\n" ++
        "//   - a list item the printer lays out itself\n" ++
        "//   - a second item\n" ++
        "var Held = 1\n\n" ++
        "//go:noinline\n" ++
        "func g() {}\n";

    const wanted = "package p\n\n" ++
        "// Doc says what f does.\n" ++
        "//\n" ++
        "// ParamFlags\n" ++
        "//\n" ++
        "//\t0 ParamFeedsIfOrSwitch\n" ++
        "//\n" ++
        "// <endpropsdump>\n" ++
        "func f() {}\n\n" ++
        "// Held is a value.\n" ++
        "//   - a list item the printer lays out itself\n" ++
        "//   - a second item\n" ++
        "var Held = 1\n\n" ++
        "//go:noinline\n" ++
        "func g() {}\n";

    try expect_formatted(source, wanted);
}

test "a field name spelled outside ascii still opens a column" {
    const source = "package p\n\n" ++
        "type parameters struct {\n" ++
        "k, l int // dimensions of A\n" ++
        "\xCE\xB7 int // bound for secret coefficients\n" ++
        "\xCE\xB31 int // log of gamma\n" ++
        "}\n";

    const wanted = "package p\n\n" ++
        "type parameters struct {\n" ++
        "\tk, l int // dimensions of A\n" ++
        "\t\xCE\xB7    int // bound for secret coefficients\n" ++
        "\t\xCE\xB31   int // log of gamma\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a line of two elements takes the comment column and ends the run" {
    const source = "package p\n\n" ++
        "var der = []byte{\n" ++
        "0x30, 6, // SEQUENCE\n" ++
        "0x02, 1, // INTEGER, 1 byte\n" ++
        "0xff, // -1\n" ++
        "0x02, 1, // INTEGER, 1 byte\n" ++
        "3,\n" ++
        "}\n";

    const wanted = "package p\n\n" ++
        "var der = []byte{\n" ++
        "\t0x30, 6, // SEQUENCE\n" ++
        "\t0x02, 1, // INTEGER, 1 byte\n" ++
        "\t0xff,    // -1\n" ++
        "\t0x02, 1, // INTEGER, 1 byte\n" ++
        "\t3,\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a key run is ranked by the width of the key rather than its column" {
    const source = "package p\n\n" ++
        "func f() {\n" ++
        "want := map[string]int{\n" ++
        "\"Package path: \" + mainPkgPath + \"/dep\": 0,\n" ++
        "\"Func: Dep1\": 0,\n" ++
        "\"Func: PDep\": 0,\n" ++
        "}\n" ++
        "_ = want\n" ++
        "}\n";

    const wanted = "package p\n\n" ++
        "func f() {\n" ++
        "\twant := map[string]int{\n" ++
        "\t\t\"Package path: \" + mainPkgPath + \"/dep\": 0,\n" ++
        "\t\t\"Func: Dep1\":                            0,\n" ++
        "\t\t\"Func: PDep\":                            0,\n" ++
        "\t}\n" ++
        "\t_ = want\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a body brace column reads through a signatures block comment" {
    const source = "package p\n\n" ++
        "func (T1) m /* ERROR \"already declared\" */ () {}\n" ++
        "func (T2) m(io.Writer) {}\n";

    const wanted = "package p\n\n" ++
        "func (T1) m /* ERROR \"already declared\" */ () {}\n" ++
        "func (T2) m(io.Writer)                        {}\n";

    try expect_formatted(source, wanted);
}

test "an embedded field holds its tag in a column of its own" {
    const source = "package p\n\n" ++
        "type LayerOne struct {\n" ++
        "Value *float64 `xml:\"value,omitempty\"`\n" ++
        "*LayerTwo `xml:\",omitempty\"`\n" ++
        "}\n";

    const wanted = "package p\n\n" ++
        "type LayerOne struct {\n" ++
        "\tValue     *float64 `xml:\"value,omitempty\"`\n" ++
        "\t*LayerTwo `xml:\",omitempty\"`\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a body of one member stays on the line the source wrote it on" {
    const source = "package p\n\n" ++
        "type A interface{ M() }\n" ++
        "type B interface{ M(); N() }\n" ++
        "type C struct{ x int }\n" ++
        "type D struct{}\n" ++
        "type E struct{ x int /* c */ }\n" ++
        "type F interface{ *P | []P | chan P | map[string]P }\n" ++
        "type G interface{ *P | []P | chan P }\n" ++
        "type H struct{ abcdefghij int; }\n" ++
        "type I struct{ aaaaaaaaaaaaaaaaaaaaaaaaaaaa int }\n";

    const wanted = "package p\n\n" ++
        "type A interface{ M() }\n" ++
        "type B interface {\n" ++
        "\tM()\n" ++
        "\tN()\n" ++
        "}\n" ++
        "type C struct{ x int }\n" ++
        "type D struct{}\n" ++
        "type E struct {\n" ++
        "\tx int /* c */\n" ++
        "}\n" ++
        "type F interface {\n" ++
        "\t*P | []P | chan P | map[string]P\n" ++
        "}\n" ++
        "type G interface{ *P | []P | chan P }\n" ++
        "type H struct{ abcdefghij int }\n" ++
        "type I struct{ aaaaaaaaaaaaaaaaaaaaaaaaaaaa int }\n";

    try expect_formatted(source, wanted);
}

test "a block comment closes up against the separator and the close past it" {
    const source = "package p\n\n" ++
        "func f() {\n" ++
        "_ = append(nil /* one */ , s)\n" ++
        "_ = T{ /* two */ }\n" ++
        "_ = T{a, b /* three */ }\n" ++
        "_ = g(a /* four */ )\n" ++
        "_ = h( /* five */ )\n" ++
        "x = y /* six */ * 10\n" ++
        "}\n";

    const wanted = "package p\n\n" ++
        "func f() {\n" ++
        "\t_ = append(nil /* one */, s)\n" ++
        "\t_ = T{ /* two */ }\n" ++
        "\t_ = T{a, b /* three */}\n" ++
        "\t_ = g(a /* four */)\n" ++
        "\t_ = h( /* five */ )\n" ++
        "\tx = y /* six */ * 10\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a files build constraints are written from the expression they spell" {
    const source = "// Package doc.\n\n" ++
        "//go:build linux && go1.2 || windows\n" ++
        "// +build !bad\n" ++
        "// +build !worse\n\n" ++
        "package p\n";

    const wanted = "// Package doc.\n\n" ++
        "//go:build (linux && go1.2) || windows\n" ++
        "// +build linux,go1.2 windows\n\n" ++
        "package p\n";

    try expect_formatted(source, wanted);
}

test "a key run ends above a value that spells its own lines" {
    const source = "package p\n\n" ++
        "var held = &command{\n" ++
        "UsageLine: \"one two\",\n" ++
        "Short: \"short text\",\n" ++
        "Long: `first line\n" ++
        "second line\n" ++
        "`,\n" ++
        "Name: \"n\",\n" ++
        "}\n";

    const wanted = "package p\n\n" ++
        "var held = &command{\n" ++
        "\tUsageLine: \"one two\",\n" ++
        "\tShort:     \"short text\",\n" ++
        "\tLong: `first line\n" ++
        "second line\n" ++
        "`,\n" ++
        "\tName: \"n\",\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a line directive the source began at column zero keeps that column" {
    const source = "package p\n\n" ++
        "func main() {\n" ++
        "if flag {\n" ++
        "//line fmthello.go:999\n" ++
        "x()\n" ++
        "//go:noinline\n" ++
        "y()\n" ++
        "}\n" ++
        "}\n";

    const wanted = "package p\n\n" ++
        "func main() {\n" ++
        "\tif flag {\n" ++
        "//line fmthello.go:999\n" ++
        "\t\tx()\n" ++
        "\t\t//go:noinline\n" ++
        "\t\ty()\n" ++
        "\t}\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a line directive the source indented takes the blocks own column" {
    const source = "package p\n\n" ++
        "func main() {\n" ++
        "if flag {\n" ++
        "\t\t//line a.go:9\n" ++
        "x()\n" ++
        "}\n" ++
        "}\n";

    const wanted = "package p\n\n" ++
        "func main() {\n" ++
        "\tif flag {\n" ++
        "\t\t//line a.go:9\n" ++
        "\t\tx()\n" ++
        "\t}\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a keyword takes the blank a parenthesis past it owes" {
    const source = "package p\n\n" ++
        "const(\n" ++
        "\tA = 1\n" ++
        ")\n\n" ++
        "func f() int { return(1) }\n\n" ++
        "type _ interface {\n" ++
        "\tfunc(int) int\n" ++
        "}\n";

    const wanted = "package p\n\n" ++
        "const (\n" ++
        "\tA = 1\n" ++
        ")\n\n" ++
        "func f() int { return (1) }\n\n" ++
        "type _ interface {\n" ++
        "\tfunc(int) int\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a body brace takes the blank a comment ahead of it leaves" {
    const source = "package p\n\n" ++
        "func a() int { return 0 /* c */}\n\n" ++
        "func b() { g(1 /* c */) }\n";

    const wanted = "package p\n\n" ++
        "func a() int { return 0 /* c */ }\n\n" ++
        "func b() { g(1 /* c */) }\n";

    try expect_formatted(source, wanted);
}

test "a signature word inside a bracket hugs its own parenthesis" {
    const source = "package p\n\n" ++
        "type _ interface {\n" ++
        "\tfunc()\n" ++
        "}\n\n" ++
        "func (t T) m() int { return 0 }\n";

    const wanted = "package p\n\n" ++
        "type _ interface {\n" ++
        "\tfunc()\n" ++
        "}\n\n" ++
        "func (t T) m() int { return 0 }\n";

    try expect_formatted(source, wanted);
}

test "a close standing ahead of an open takes no blank from it" {
    const source = "package p\n\n" ++
        "func a[P any] (x P) P { return x }\n\n" ++
        "var u = struct{ a int } {a: 1}\n";

    const wanted = "package p\n\n" ++
        "func a[P any](x P) P { return x }\n\n" ++
        "var u = struct{ a int }{a: 1}\n";

    try expect_formatted(source, wanted);
}

test "a comment reached across a specs own column stands against the name" {
    const source = "package p\n\n" ++
        "type (\n" ++
        "\tT0 int\n" ++
        "\tT1 /* note */ T1\n" ++
        ")\n\n" ++
        "const (\n" ++
        "\tC1 /* note */\n" ++
        ")\n";

    const wanted = "package p\n\n" ++
        "type (\n" ++
        "\tT0 int\n" ++
        "\tT1/* note */ T1\n" ++
        ")\n\n" ++
        "const (\n" ++
        "\tC1 /* note */\n" ++
        ")\n";

    try expect_formatted(source, wanted);
}
