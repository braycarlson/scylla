const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Buffer = @import("../stdx/bounded/buffer.zig");
const EventsType = @import("../syntax/tree.zig").EventsType;
const Formatter = @import("css.zig").Formatter;
const FormatterError = @import("formatters.zig").FormatterError;
const Input = @import("css.zig").Input;
const Kind = @import("../syntax/css/kind.zig").Kind;
const Parser = @import("../syntax/css/parse.zig").Parser;
const Span = @import("../stdx/bounded/span.zig");
const Structure = @import("../syntax/tree.zig").Structure;
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

    fn format(held: *Held, source: []const u8, out: *Buffer) HeldError!void {
        if (!held.lexed_of(source)) return error.Truncated;

        const input = held.input_of(source, held.parsed(source));

        assert(input.tokens.len == input.raw.len);
        assert(input.source.len == source.len);

        return held.formatter.format(&input, out);
    }

    fn range(
        held: *Held,
        source: []const u8,
        lines: walk.LineRange,
        out: *Buffer,
    ) HeldError!Span {
        if (!held.lexed_of(source)) return error.Truncated;

        const input = held.input_of(source, held.parsed(source));

        assert(input.tokens.len == input.raw.len);
        assert(lines.first <= lines.last);

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

    fn lexed_of(held: *Held, source: []const u8) bool {
        assert(source.len <= std.math.maxInt(u32));

        held.tokens.clear();

        lex(.of(.css), source, &held.tokens) catch |err| switch (err) {
            error.Truncated => return false,
        };

        raw_of(Kind, held.tokens.slice(), &held.raw) catch |err| switch (err) {
            error.Truncated => return false,
        };

        assert(held.raw.count() == held.tokens.count());
        assert(held.tokens.count() <= token_count_max);

        return true;
    }

    fn classified(held: *Held, source: []const u8) void {
        assert(source.len <= std.math.maxInt(u32));

        const lexed = held.lexed_of(source);

        assert(lexed);
        assert(held.raw.count() <= token_count_max);
    }

    fn words(held: *Held, arena: std.mem.Allocator, source: []const u8) ![]const []const u8 {
        assert(source.len <= std.math.maxInt(u32));

        const complete = held.lexed_of(source);

        assert(complete);

        const lexed = held.tokens.slice();
        var listed: std.ArrayList([]const u8) = try .initCapacity(arena, lexed.len);

        for (lexed) |token| {
            const structural = token.kind == .block_end or token.kind == .block_start or
                token.kind == .newline;

            if (structural) continue;
            if (token.length == 0) continue;

            const word: []const u8 = if (token.kind == .string) "<string>" else token.text(source);

            listed.appendAssumeCapacity(word);
        }

        assert(listed.items.len <= lexed.len);

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
            if (kind == .newline) continue;

            found.appendAssumeCapacity(kind);
        }

        assert(found.items.len <= raw.len);
        assert(raw.len == held.tokens.count());
    }

    fn comments(held: *Held, gpa: std.mem.Allocator, source: []const u8, found: *Comments) !void {
        assert(source.len <= std.math.maxInt(u32));

        held.classified(source);

        const raw = held.raw.const_slice();
        const tokens = held.tokens.slice();

        assert(raw.len == tokens.len);

        found.bytes.clearRetainingCapacity();
        found.ends.clearRetainingCapacity();

        for (raw, tokens) |kind, token| {
            if (kind != .comment) continue;

            const text = std.mem.trimEnd(u8, token.text(source), ascii_whitespace);

            try commented(gpa, text, &found.bytes);
            try found.ends.append(gpa, @intCast(found.bytes.items.len));
        }

        assert(found.ends.items.len <= raw.len);
    }
};

const Comments = struct {
    bytes: std.ArrayList(u8),
    ends: std.ArrayList(u32),

    const empty: Comments = .{
        .bytes = .empty,
        .ends = .empty,
    };

    fn deinit(held: *Comments, gpa: std.mem.Allocator) void {
        assert(held.bytes.items.len <= held.bytes.capacity);
        assert(held.ends.items.len <= held.ends.capacity);

        held.ends.deinit(gpa);
        held.bytes.deinit(gpa);
        held.* = undefined;
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

    fn expect_stable(twice: *Twice, source: []const u8) ![]const u8 {
        assert(source.len <= std.math.maxInt(u32));

        try twice.held.format(source, &twice.first);

        const once = twice.first.const_slice();

        try twice.held.format(once, &twice.second);
        try std.testing.expectEqualStrings(once, twice.second.const_slice());

        assert(once.len == twice.second.count());

        return once;
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
    comments_after: Comments,
    comments_before: Comments,
    kinds_after: std.ArrayList(Kind),
    kinds_before: std.ArrayList(Kind),

    const empty: Relations = .{
        .comments_after = .empty,
        .comments_before = .empty,
        .kinds_after = .empty,
        .kinds_before = .empty,
    };

    fn deinit(relations: *Relations, gpa: std.mem.Allocator) void {
        assert(relations.kinds_after.items.len <= relations.kinds_after.capacity);
        assert(relations.kinds_before.items.len <= relations.kinds_before.capacity);

        relations.kinds_before.deinit(gpa);
        relations.kinds_after.deinit(gpa);
        relations.comments_before.deinit(gpa);
        relations.comments_after.deinit(gpa);
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

        assert(relations.kinds_before.items.len <= fixture.source.len);
        assert(relations.kinds_after.items.len <= once.len);

        const kept_all = preserved(relations.kinds_before.items, relations.kinds_after.items);

        try require(kept_all, "{s} lost or gained a token", .{fixture.name});
    }

    fn expect_comments(
        relations: *Relations,
        gpa: std.mem.Allocator,
        held: *Held,
        fixture: *const Fixture,
        once: []const u8,
    ) !void {
        assert(once.len <= std.math.maxInt(u32));

        try held.comments(gpa, fixture.source, &relations.comments_before);
        try held.comments(gpa, once, &relations.comments_after);

        const before = relations.comments_before.bytes.items;
        const after = relations.comments_after.bytes.items;

        assert(before.len <= fixture.source.len);
        assert(after.len <= once.len);

        try expect_text(fixture.name, "lost a comment", before, after);
    }

    fn expect_comment_list(
        relations: *Relations,
        gpa: std.mem.Allocator,
        held: *Held,
        fixture: *const Fixture,
        once: []const u8,
    ) !void {
        assert(once.len <= std.math.maxInt(u32));

        try relations.expect_comments(gpa, held, fixture, once);

        const before = relations.comments_before.ends.items;
        const after = relations.comments_after.ends.items;

        assert(before.len <= fixture.source.len);
        assert(after.len <= once.len);

        try require(std.mem.eql(u32, before, after), "{s} lost a comment", .{fixture.name});
    }
};

const Fixture = corpus.File;

const Taken = struct {
    after: usize,
    before: usize,
};

const ascii_whitespace = " \t\n\x0c\r";
const dump_variable = "SCYLLA_FORMAT_DUMP";
const element_count_max: u32 = 1 << 18;
const diagnostic_count_max: u32 = 1 << 12;
const event_count_max: u32 = 1 << 20;

const every_category = [_][]const u8{
    "biome-line-breaking",
    "biome-value-syntax",
};

const file_count_max: u32 = 1 << 20;
const fixture_count_min: u32 = 4;
const fixture_root = "tests/fixtures/css";
const golden_root = "tests/fixtures/golden-biome-css";
const node_count_max: u32 = 1 << 18;
const out_bytes_max: u32 = 1 << 22;
const path_bytes_max: u32 = 4096;
const residue_name = "residue-format-css.json";
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

fn expect_related(source: []const u8) ![]const u8 {
    assert(source.len > 0);

    const gpa = std.testing.allocator;
    const fixture: Fixture = .{ .name = "related.css", .source = source };
    const twice = try gpa.create(Twice);
    defer gpa.destroy(twice);

    try twice.init(gpa);
    defer twice.deinit(gpa);

    var relations: Relations = .empty;
    defer relations.deinit(gpa);

    const once = try twice.expect_stable(source);

    try relations.expect_kinds(gpa, &twice.held, &fixture, once);
    try relations.expect_comments(gpa, &twice.held, &fixture, once);

    return gpa.dupe(u8, once);
}

fn commented(gpa: std.mem.Allocator, text: []const u8, found: *std.ArrayList(u8)) !void {
    assert(text.len <= std.math.maxInt(u32));

    const length = found.items.len;

    if (!starred(text)) {
        try found.appendSlice(gpa, text);

        return;
    }

    var lines = std.mem.splitScalar(u8, text, '\n');

    try found.appendSlice(gpa, lines.first());

    for (0..text.len) |_| {
        const line = lines.next() orelse break;

        try found.append(gpa, '\n');
        try found.appendSlice(gpa, std.mem.trim(u8, line, ascii_whitespace));
    }

    assert(found.items.len >= length);
    assert(found.items.len <= length + text.len);
}

fn starred(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    var lines = std.mem.splitScalar(u8, text, '\n');
    if (!std.mem.startsWith(u8, lines.first(), "/**")) return false;
    if (std.mem.findScalar(u8, text, '\n') == null) return false;

    for (0..text.len) |_| {
        const line = lines.next() orelse break;
        const trimmed = std.mem.trimStart(u8, line, ascii_whitespace);
        if (!std.mem.startsWith(u8, trimmed, "*")) return false;
    }

    assert(text.len > 3);

    return true;
}

fn preserved(before: []const Kind, after: []const Kind) bool {
    assert(before.len <= std.math.maxInt(u32));
    assert(after.len <= std.math.maxInt(u32));

    var held: usize = 0;
    var index: usize = 0;

    for (0..after.len) |_| {
        if (index >= after.len) break;

        const taken = taken_of(before, held, after, index) orelse return false;

        assert(taken.after > 0);

        held += taken.before;
        index += taken.after;
    }

    assert(held <= before.len);

    return held == before.len;
}

fn taken_of(before: []const Kind, held: usize, after: []const Kind, index: usize) ?Taken {
    assert(index < after.len);
    assert(held <= before.len);

    if (held < before.len) {
        if (counted(before, held, after, index)) |taken| return .{ .after = taken, .before = 1 };
    }

    if (quoted_escape(before, held, after, index)) |taken| {
        return .{ .after = 1, .before = taken };
    }

    if (swapped(before, held, after, index)) return .{ .after = 2, .before = 2 };

    const kept_one = held < before.len and kept(before[held], after[index], after, index);
    if (kept_one) return .{ .after = 1, .before = 1 };
    if (after[index] != .semicolon) return null;
    return .{ .after = 1, .before = 0 };
}

fn swapped(before: []const Kind, held: usize, after: []const Kind, index: usize) bool {
    assert(before.len <= std.math.maxInt(u32));
    assert(held < std.math.maxInt(u32));
    assert(after.len <= std.math.maxInt(u32));
    assert(index < std.math.maxInt(u32));

    const comma = kind_is(before, held, .comma) and kind_is(before, held + 1, .comment);
    return comma and kind_is(after, index, .comment) and kind_is(after, index + 1, .comma);
}

fn counted(before: []const Kind, held: usize, after: []const Kind, index: usize) ?usize {
    assert(held < before.len);
    assert(index < after.len);

    const named_before = index > 0 and is_name(after[index - 1]);
    const signed = is_sign(after[index]) and kind_is(after, index + 1, .number) and named_before;
    const signs = signed and before[held] == .number;
    if (signs) return 2;

    const operated = kind_is_sign(after, index + 1) and kind_is(after, index + 2, .number);
    const stepped = is_name(after[index]) and operated and !kind_is(before, held + 1, .number);
    const steps = stepped and before[held] == .identifier;
    if (steps) return 3;
    return null;
}

fn quoted_escape(before: []const Kind, held: usize, after: []const Kind, index: usize) ?usize {
    assert(index < after.len);
    assert(held <= before.len);

    const operated = index > 0 and is_attribute_operator(after[index - 1]);
    const quoted = after[index] == .text and operated;
    if (!quoted) return null;

    var taken: usize = 0;
    var escaped = false;

    for (before[held..]) |kind| {
        const follows = taken == 0 or before[held + taken - 1] == .escape;
        const named = kind == .identifier or kind == .number or kind == .unit;
        const stops = kind != .escape and !(follows and named);
        if (stops) break;

        if (kind == .escape) escaped = true;

        taken += 1;
    }

    if (!escaped) return null;
    return taken;
}

fn kept(source: Kind, printed: Kind, after: []const Kind, index: usize) bool {
    assert(index < after.len);
    assert(after[index] == printed);

    if (collapsed(source) == collapsed(printed)) return true;

    if (is_name(source)) {
        if (is_name(printed)) return true;
    }

    const operated = index > 0 and is_attribute_operator(after[index - 1]);
    return source == .identifier and printed == .text and operated;
}

fn collapsed(kind: Kind) Kind {
    assert(kind.is_token());

    if (kind == .float) return .number;
    return kind;
}

fn is_attribute_operator(kind: Kind) bool {
    if (!kind.is_token()) return false;

    return switch (kind) {
        .bar_equal, .caret_equal, .dollar_equal, .equal, .star_equal, .tilde_equal => true,
        else => false,
    };
}

fn is_name(kind: Kind) bool {
    if (!kind.is_token()) return false;

    return kind == .identifier or kind == .unit;
}

fn is_sign(kind: Kind) bool {
    if (!kind.is_token()) return false;

    return kind == .minus or kind == .plus;
}

fn kind_is(kinds: []const Kind, at: usize, wanted: Kind) bool {
    if (at >= kinds.len) return false;
    assert(wanted.is_token());

    return kinds[at] == wanted;
}

fn kind_is_sign(kinds: []const Kind, at: usize) bool {
    if (at >= kinds.len) return false;
    return is_sign(kinds[at]);
}

fn worded(before: []const []const u8, after: []const []const u8) bool {
    assert(before.len <= std.math.maxInt(u32));
    assert(after.len <= std.math.maxInt(u32));

    var held: usize = 0;

    for (after, 0..) |word, index| {
        const attributed = index > 0 and is_attribute_word(after[index - 1]);
        const quoted = std.mem.eql(u8, word, "<string>") and attributed;
        const matched = held < before.len and (std.mem.eql(u8, before[held], word) or quoted);

        if (matched) {
            held += 1;

            continue;
        }

        if (!std.mem.eql(u8, word, ";")) return false;
    }

    assert(held <= before.len);

    return held == before.len;
}

fn is_attribute_word(word: []const u8) bool {
    assert(word.len <= std.math.maxInt(u32));

    const operators = [_][]const u8{ "*=", "=", "^=", "|=", "~=", "$=" };

    for (operators) |operator| {
        if (std.mem.eql(u8, word, operator)) return true;
    }

    return false;
}

fn lines_of(bytes: []const u8, lines: walk.LineRange) []const u8 {
    assert(lines.first <= lines.last);
    assert(bytes.len <= std.math.maxInt(u32));

    var line: u32 = 0;
    var start: usize = 0;
    var end: usize = bytes.len;

    for (bytes, 0..) |byte, offset| {
        if (byte != '\n') continue;

        line += 1;

        if (line == lines.first) start = offset + 1;

        if (line == lines.last + 1) {
            end = offset + 1;

            break;
        }
    }

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
        if (!std.mem.eql(u8, std.Io.Dir.path.extension(entry.name), ".css")) continue;

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

    return std.mem.eql(u8, std.Io.Dir.path.extension(basename), ".css");
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

        try relations.expect_comment_list(gpa, &held, fixture, out.const_slice());
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

        var path_buffer: [path_bytes_max]u8 = undefined;
        const path = try std.mem.print(&path_buffer, "{s}/{s}", .{ root, fixture.name });
        const file: std.Io.Dir.WriteFileOptions = .{ .sub_path = path, .data = out.const_slice() };

        assert(path.len > fixture.name.len);

        try std.Io.Dir.cwd().writeFile(std.testing.io, file);
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

        const outcome = held.format(fixture.source, &out);
        const refused = "{s} is refused and no residue row names it";

        try require(is_complete(outcome), refused, .{fixture.name});

        const golden = try read_under(gpa, golden_root, fixture.name);
        defer gpa.free(golden);

        const message = "diverges from biome and no residue row names it";

        try expect_text(fixture.name, message, golden, out.const_slice());

        compared += 1;
    }

    try require(
        compared >= floor.fixture_format_css,
        "the CSS fixtures lost a formatting: {d} compared, floor {d}",
        .{ compared, floor.fixture_format_css },
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

        held.format(source, &out) catch continue;

        const golden = try read_under(gpa, golden_root, name);
        defer gpa.free(golden);

        const diverged = !std.mem.eql(u8, out.const_slice(), golden);

        try require(diverged, "{s} matches biome and needs no residue row", .{name});
    }
}

test "a file that does not parse is refused" {
    const gpa = std.testing.allocator;
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    try std.testing.expectError(error.SourceInvalid, held.format("a {\n", &out));
    try std.testing.expect(out.empty());
}

test "a source that never closes a string or a comment is refused" {
    const gpa = std.testing.allocator;

    const sources = [_][]const u8{
        "\"",
        "' ",
        "/* ",
        "a { content: \"x; }\n",
        "a { content: 'x }\n",
    };

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    for (sources) |source| {
        try require(is_refused(held.format(source, &out)), "{s}", .{source});
    }
}

test "an escaped quote in a selector opens no string" {
    const gpa = std.testing.allocator;
    const source = ".tw\\:bg-\\[url\\(\\'x.png\\'\\)\\] { background: url(a.png); }\n";
    var twice: Twice = undefined;

    try twice.init(gpa);
    defer twice.deinit(gpa);

    const once = try twice.expect_stable(source);

    try std.testing.expect(std.mem.find(u8, once, "background: url(a.png)") != null);
}

test "a trailing escape reads the same with or without a final newline" {
    const gpa = std.testing.allocator;
    var twice: Twice = undefined;

    try twice.init(gpa);
    defer twice.deinit(gpa);

    try twice.held.format("gin: ol\\", &twice.first);
    try twice.held.format("gin: ol\\\n", &twice.second);
    try std.testing.expectEqualStrings(twice.first.const_slice(), twice.second.const_slice());
}

test "an escape stays inside the name it continues" {
    const cases = [_][2][]const u8{
        .{
            "#workbench\\.editor\\.settings2:focus { outline: none; }\n",
            "#workbench\\.editor\\.settings2:focus {\n    outline: none;\n}\n",
        },
        .{
            ".x img[src$=\\#gh-light-mode-only] { display: none; }\n",
            ".x img[src$=\"\\#gh-light-mode-only\"] {\n    display: none;\n}\n",
        },
        .{
            "@font-face { font-family: Font Awesome\\ 5 Brands; }\n",
            "@font-face {\n    font-family: Font Awesome\\ 5 Brands;\n}\n",
        },
        .{
            "a { font-family: \\5FAE\\8F6F\\96C5\\9ED1, Arial; }\n",
            "a {\n    font-family: \\5FAE\\8F6F\\96C5\\9ED1, Arial;\n}\n",
        },
        .{
            "[data-x=\\31 0] { color: red; }\n",
            "[data-x=\"\\31 0\"] {\n    color: red;\n}\n",
        },
        .{
            ".\\31 0 { color: red; }\n",
            ".\\31 0 {\n    color: red;\n}\n",
        },
        .{
            "\\31 0 { color: red; }\n",
            "\\31 0 {\n    color: red;\n}\n",
        },
    };

    for (cases) |case| {
        try expect_formatted(case[0], case[1]);
    }
}

test "a byte order mark is a selector of no width the first selector joins" {
    const gpa = std.testing.allocator;

    const cases = [_][2][]const u8{
        .{
            "\xef\xbb\xbf  body{color:red}",
            "\xef\xbb\xbfbody {\n    color: red;\n}\n",
        },
        .{
            "\xef\xbb\xbf/* c */\na, b{color:red}",
            "\xef\xbb\xbf/* c */ a,\nb {\n    color: red;\n}\n",
        },
        .{
            "\xef\xbb\xbf/*--\nd\n--*/\nbody\n{color:red}\n",
            "\xef\xbb\xbf    /*--\nd\n--*/ body {\n    color: red;\n}\n",
        },
        .{
            "\xef\xbb\xbf/* c\n*/ a > b ~ c + d e{color:red}",
            "\xef\xbb\xbf    /* c\n*/ a\n    > b\n    ~ c\n    + d\n    e {\n    color: red;\n}\n",
        },
        .{
            "\xef\xbb\xbf/**\n * doc\n */\nbody{color:red}\n",
            "\xef\xbb\xbf    /**\n     * doc\n     */ body {\n    color: red;\n}\n",
        },
        .{
            "\xef\xbb\xbf/* c */\n\n/* d */\n\nbody{color:red}",
            "\xef\xbb\xbf    /* c */ /* d */\n\n    body {\n    color: red;\n}\n",
        },
        .{
            "\xef\xbb\xbf .aaaaaaaaaaaaaaaaaaaaa .bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb " ++
                ".cccccccccccccccccccccccccccccccc .ddddddddd{color:red}",
            "\xef\xbb\xbf    .aaaaaaaaaaaaaaaaaaaaa\n" ++
                "    .bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n" ++
                "    .cccccccccccccccccccccccccccccccc\n    .ddddddddd {\n    color: red;\n}\n",
        },
    };

    var twice: Twice = undefined;

    try twice.init(gpa);
    defer twice.deinit(gpa);

    for (cases) |case| {
        const once = try twice.expect_stable(case[0]);

        try std.testing.expectEqualStrings(case[1], once);
    }
}

test "a descendant combinator before a pseudo class survives" {
    const gpa = std.testing.allocator;
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    try held.format("div :hover { color: red; }\n", &out);

    const spaced = std.mem.startsWith(u8, out.const_slice(), "div :hover");

    try require(spaced, "{s}", .{out.const_slice()});

    try held.format("div:hover { color: red; }\n", &out);

    const tight = std.mem.startsWith(u8, out.const_slice(), "div:hover");

    try require(tight, "{s}", .{out.const_slice()});
}

test "a declaration loses the space before its colon" {
    const gpa = std.testing.allocator;
    const source = "a { color : red; --held : blue; }\n";
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    try held.format(source, &out);

    const formatted = out.const_slice();

    try require(std.mem.find(u8, formatted, "color: red") != null, "{s}", .{formatted});
    try require(std.mem.find(u8, formatted, "--held: blue") != null, "{s}", .{formatted});
}

test "a dropped byte between two tokens writes no space before a comma" {
    const gpa = std.testing.allocator;
    var twice: Twice = undefined;

    try twice.init(gpa);
    defer twice.deinit(gpa);

    const once = try twice.expect_stable("E:2E%\xef\xbb\xbf,");

    try std.testing.expectEqualStrings("E:2E%,\n", once);
}

test "a dot run a selector wrote tight stays tight" {
    const gpa = std.testing.allocator;
    var twice: Twice = undefined;

    try twice.init(gpa);
    defer twice.deinit(gpa);

    const once = try twice.expect_stable("a:b...");

    try std.testing.expectEqualStrings("a:b...\n", once);
}

test "an at rule above a pseudo class selector formats twice" {
    const gpa = std.testing.allocator;
    var twice: Twice = undefined;

    try twice.init(gpa);
    defer twice.deinit(gpa);

    const once = try twice.expect_stable("@charset\nh :(\"\")");

    try std.testing.expect(once.len > 0);
}

test "a hash with no name inside a block is refused" {
    const gpa = std.testing.allocator;

    const sources = [_][]const u8{
        "{#}h:;",
        "{#} h:;\n",
        "{}{#}h:;",
    };

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    for (sources) |source| {
        try std.testing.expectError(error.SourceInvalid, held.format(source, &out));
    }
}

test "an item in a block with no property and no block of its own is refused" {
    const gpa = std.testing.allocator;
    const sources = [_][]const u8{ "{:}", "a{:}", "a{b}", "a{::}" };
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    for (sources) |source| {
        try std.testing.expectError(error.SourceInvalid, held.format(source, &out));
    }

    try held.format("a{*zoom:1}", &out);
}

test "a declaration holding a block or a separator of its own is refused" {
    const gpa = std.testing.allocator;

    const sources = [_][]const u8{
        "a {\n    --x: {\n        color: red;\n    };\n}\n",
        "a {\n    --x: { color: red; }\n}\n",
        "a {\n    --x: [1, {\"b\": 2}];\n}\n",
        "a {\n    --x: (b; c);\n}\n",
        "a {\n    b: f(a; b);\n}\n",
    };

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    for (sources) |source| {
        try std.testing.expectError(error.SourceInvalid, held.format(source, &out));
    }

    const data = "a {\n    background: url(data:image/png;base64,AAAA);\n}\n";

    try held.format(data, &out);
}

test "an unquoted url keeps every byte it was given" {
    const sources = [_][]const u8{
        "a {\n    background: url(data:image/png;base64,AAAA);\n}\n",
        "@import url(https://fonts.googleapis.com/css?family=Roboto:100,300,400&display=swap);\n",
        "a {\n    background: url(https://example.com/some/quite,long,url.jpg);\n}\n",
    };

    for (sources) |source| {
        try expect_formatted(source, source);
    }

    const spaced = "a {\n    background: url( \"x\" );\n}\n";

    try expect_formatted(spaced, "a {\n    background: url(\"x\");\n}\n");
}

test "a number glued to a dot keeps every dot" {
    const gpa = std.testing.allocator;
    var twice: Twice = undefined;

    try twice.init(gpa);
    defer twice.deinit(gpa);

    for ([_][]const u8{ "@1..", "@..1" }) |source| {
        const once = try twice.expect_stable(source);

        try std.testing.expect(std.mem.startsWith(u8, once, source));
    }
}

test "an id selector still takes the name written against it" {
    const gpa = std.testing.allocator;
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    try held.format("#main { color: #fff; }\n", &out);

    const formatted = out.const_slice();

    try require(std.mem.find(u8, formatted, "#main") != null, "{s}", .{formatted});
    try require(std.mem.find(u8, formatted, "#fff") != null, "{s}", .{formatted});
}

test "a range reads back the lines it names" {
    const gpa = std.testing.allocator;
    const source = ".a{\ncolor:red;\n}\n";
    const lines: walk.LineRange = .{ .first = 1, .last = 2 };
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var whole: Buffer = try .init(gpa, out_bytes_max);
    defer whole.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    try held.format(source, &whole);

    const formatted = whole.const_slice();
    const span = try held.range(source, lines, &out);

    try std.testing.expectEqualStrings(formatted, out.const_slice());
    try std.testing.expectEqualStrings(lines_of(formatted, lines), span.text(out.const_slice()));
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
        const message = "{s} split, joined, lost, or gained a word";

        try require(worded(before, after), message, .{fixture.name});
    }
}

test "a slash in a value parts from what it stands between" {
    const source = "a {\n    font: normal 16px/1 codicon;\n    grid-area: 1/2/3/4;\n" ++
        "    background: url(a/b.png);\n}\n";

    const wanted = "a {\n    font: normal 16px / 1 codicon;\n    grid-area: 1 / 2 / 3 / 4;\n" ++
        "    background: url(a/b.png);\n}\n";

    try expect_formatted(source, wanted);
}

test "a star led comment is written under the column it opens on" {
    const source = "a {\n\t/**\n\t * held\n\t */\n\tcolor: red;\n\t/*\n\t * held\n\t */\n" ++
        "\tmargin: 0;\n}\n";

    const wanted = "a {\n    /**\n     * held\n     */\n    color: red;\n" ++
        "    /*\n\t * held\n\t */\n    margin: 0;\n}\n";

    try expect_formatted(source, wanted);
}

test "a child count takes the one form the reference writes" {
    const source = "a:nth-last-child(n+3),\nb:nth-child(2N-1),\nc:nth-of-type(odd) {\n" ++
        "    color: red;\n}\n";

    const wanted = "a:nth-last-child(n + 3),\nb:nth-child(2n - 1),\nc:nth-of-type(odd) {\n" ++
        "    color: red;\n}\n";

    try expect_formatted(source, wanted);
}

test "a custom property fills its value where a named one parts it" {
    const source = "a {\n    --held-shadow-value: inset 0 1px 0 rgba(255, 255, 255, 0.15), " ++
        "0 1px 1px rgba(0, 0, 0, 0.075);\n    box-shadow: inset 0 1px 0 rgba(255, 255, 255, " ++
        "0.15), 0 1px 1px rgba(0, 0, 0, 0.075);\n}\n";

    const wanted = "a {\n    --held-shadow-value:\n        inset 0 1px 0 rgba(255, 255, 255, " ++
        "0.15), 0 1px 1px rgba(0, 0, 0, 0.075);\n    box-shadow:\n        inset 0 1px 0 " ++
        "rgba(255, 255, 255, 0.15),\n        0 1px 1px rgba(0, 0, 0, 0.075);\n}\n";

    try expect_formatted(source, wanted);
}

test "a commented rule of two compounds parts them at its own level" {
    const source = "/* held */\n.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa " ++
        ".bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb {\n    color: red;\n}\n";

    const wanted = "/* held */\n.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n" ++
        ".bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb {\n    color: red;\n}\n";

    try expect_formatted(source, wanted);
}

test "a comment past a declaration counts toward the width its value parts at" {
    const source = "a {\n    zoom: var(--zoom-factor); /* helps to position the menu " ++
        "properly when counter zooming */\n}\n";

    const wanted = "a {\n    zoom: var(\n        --zoom-factor\n    ); /* helps to position " ++
        "the menu properly when counter zooming */\n}\n";

    try expect_formatted(source, wanted);
}

test "a star in a value parts and a known at rule is lowercased" {
    const source = "@IMporT url(\"held.css\");\na {\n" ++
        "    padding-right: calc(var(--held-font-size)*0.5);\n}\n";

    const wanted = "@import url(\"held.css\");\na {\n" ++
        "    padding-right: calc(var(--held-font-size) * 0.5);\n}\n";

    try expect_formatted(source, wanted);
}

test "a value of several components indents the call it holds one level in" {
    const source = ".a {\n    border-image: linear-gradient(90deg, " ++
        "var(--aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa), var(--bbbbbbbbbbbbbbbbbb)) 1;\n}\n";

    const wanted = ".a {\n    border-image: linear-gradient(\n            90deg,\n" ++
        "            var(--aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa),\n" ++
        "            var(--bbbbbbbbbbbbbbbbbb)\n        )\n        1;\n}\n";

    try expect_formatted(source, wanted);
}

test "a layer parts at its own call and the layer past it opens a line" {
    const source = ".a {\n    background:\n        radial-gradient(ellipse 128% 102% at 100% " ++
        "100%, color-mix(in srgb, var(--vscode-agentsGradient-tintColor) 9%, transparent) " ++
        "0%, transparent 60%),\n        var(--vscode-agents-background);\n}\n";

    const wanted = ".a {\n    background:\n        radial-gradient(\n" ++
        "            ellipse 128% 102% at 100% 100%,\n" ++
        "            color-mix(in srgb, var(--vscode-agentsGradient-tintColor) 9%, " ++
        "transparent)\n                0%,\n            transparent 60%\n        ),\n" ++
        "        var(--vscode-agents-background);\n}\n";

    try expect_formatted(source, wanted);
}

test "an argument is measured without the comma it ends on" {
    const source = ".a {\n    border-image: linear-gradient(90deg, " ++
        "var(--vscode-editorGutter-addedBackground) var(--inline-chat-frame-progress), " ++
        "var(--vscode-button-background)) 1;\n}\n";

    const wanted = ".a {\n    border-image: linear-gradient(\n            90deg,\n" ++
        "            var(--vscode-editorGutter-addedBackground) " ++
        "var(--inline-chat-frame-progress),\n            var(--vscode-button-background)\n" ++
        "        )\n        1;\n}\n";

    try expect_formatted(source, wanted);
}

test "a compound parts at the pseudo that runs past the next break" {
    const source = ".input-group > :not(:first-child):not(.dropdown-menu):not(.valid-tooltip)" ++
        ":not(.valid-feedback):not(.invalid-tooltip):not(.invalid-feedback) {\n" ++
        "    margin-left: 0;\n}\n";

    const wanted = ".input-group\n    > :not(:first-child):not(.dropdown-menu):not(" ++
        ".valid-tooltip):not(\n        .valid-feedback\n    ):not(.invalid-tooltip)" ++
        ":not(.invalid-feedback) {\n    margin-left: 0;\n}\n";

    try expect_formatted(source, wanted);
}

test "a rules own brace takes a blank whatever the source wrote" {
    const source = "@keyframes held {\n    0%{\n        opacity: 0;\n    }\n}\n";
    const wanted = "@keyframes held {\n    0% {\n        opacity: 0;\n    }\n}\n";

    try expect_formatted(source, wanted);
}

test "a calc parts a parenthesised operand and the operator rides the line it closes" {
    const source = ".d {\n    width: calc(var(--aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa) - 1px);\n}\n.e {\n    width: calc((var(" ++
        "--aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa) - var(--bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        ")) / 2);\n}\n";

    const wanted = ".d {\n    width: calc(\n        var(\n            --aaaaaaaaaaaaaaaaaaaa" ++
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n        ) -\n" ++
        "        1px\n    );\n}\n.e {\n    width: calc(\n        (\n            var(" ++
        "--aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa) -\n            var(--bbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbb)\n        ) /\n        2\n    );\n}\n";

    try expect_formatted(source, wanted);
}

test "a compound parts every pseudo argument the line does not hold" {
    const source = ".chat-rich-link:is([data-chat-rich-link-kind=\"session\"], " ++
        "[data-chat-rich-link-kind=\"chat\"]):is([data-chat-rich-link-status=\"pending\"], " ++
        "[data-chat-rich-link-status=\"warning\"], [data-chat-rich-link-status=\"error\"]) " ++
        ".chat-rich-link-primary-status {\n    display: inline-flex;\n}\n.a {\n    .b {\n" ++
        "        > .monaco-scrollable-element:has(.chat-used-context-list." ++
        "chat-thinking-collapsible:not(.chat-thinking-streaming)) {\n" ++
        "            overflow: hidden;\n        }\n    }\n}\n";

    const wanted = ".chat-rich-link:is(\n        [data-chat-rich-link-kind=\"session\"],\n" ++
        "        [data-chat-rich-link-kind=\"chat\"]\n    ):is(\n" ++
        "        [data-chat-rich-link-status=\"pending\"],\n" ++
        "        [data-chat-rich-link-status=\"warning\"],\n" ++
        "        [data-chat-rich-link-status=\"error\"]\n    )\n" ++
        "    .chat-rich-link-primary-status {\n    display: inline-flex;\n}\n.a {\n    .b {\n" ++
        "        > .monaco-scrollable-element:has(\n" ++
        "                .chat-used-context-list.chat-thinking-collapsible:not(\n" ++
        "                        .chat-thinking-streaming\n                    )\n" ++
        "            ) {\n            overflow: hidden;\n        }\n    }\n}\n";

    try expect_formatted(source, wanted);
}

test "a brace past a trailing comment keeps the line the comment ends" {
    const source = "#monaco-workbench-editor-drop-overlay " ++
        ".editor-group-overlay-drop-into-prompt i /* Style keybinding */ {\n" ++
        "    padding: 0 8px;\n}\n";

    const wanted = "#monaco-workbench-editor-drop-overlay\n" ++
        "    .editor-group-overlay-drop-into-prompt\n    i /* Style keybinding */ {\n" ++
        "    padding: 0 8px;\n}\n";

    try expect_formatted(source, wanted);
}

test "a commented rule joins its first two compounds only under a named head" {
    const source = "/* The stroke lives on the fill. */\n:is(.hc-black, .hc-light)" ++
        ".modern-ui-tabs.monaco-workbench .part.editor > .content .editor-group-container > " ++
        ".title {\n    outline: none;\n}\n/* The stroke lives on the fill. */\n" ++
        ".aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa .bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb " ++
        ".ccccccccccccccccccccccc {\n    outline: none;\n}\n";

    const wanted = "/* The stroke lives on the fill. */\n:is(.hc-black, .hc-light)" ++
        ".modern-ui-tabs.monaco-workbench\n    .part.editor\n    > .content\n" ++
        "    .editor-group-container\n    > .title {\n    outline: none;\n}\n" ++
        "/* The stroke lives on the fill. */\n" ++
        ".aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa .bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n" ++
        "    .ccccccccccccccccccccccc {\n    outline: none;\n}\n";

    try expect_formatted(source, wanted);
}

test "a value holding a slash opens the line under the property it names" {
    const source = ".a {\n    background: url(\"../../../../browser/media/code-icon.svg\") " ++
        "center / contain no-repeat;\n}\n.b {\n    .c {\n        font: normal normal normal " ++
        "calc(var(--vscode-testing-coverage-lineHeight) / 2) / 1 codicon;\n    }\n}\n";

    const wanted = ".a {\n    background:\n" ++
        "        url(\"../../../../browser/media/code-icon.svg\") " ++
        "center / contain no-repeat;\n}\n.b {\n    .c {\n        font:\n            normal " ++
        "normal normal calc(var(--vscode-testing-coverage-lineHeight) / 2) / 1\n" ++
        "            codicon;\n    }\n}\n";

    try expect_formatted(source, wanted);
}

test "a paired compounds pseudo argument steps one level from the rule" {
    const source = "/* remark */\n.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:not(" ++
        ".bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb) .ccc {\n    a: 1;\n}\n" ++
        ".aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:not(" ++
        ".bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb) .ccc {\n    a: 1;\n}\n";

    const wanted = "/* remark */\n" ++
        ".aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:not(\n" ++
        "    .bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n)\n.ccc {\n    a: 1;\n}\n" ++
        ".aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:not(\n" ++
        "        .bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n    )\n    .ccc {\n    a: 1;\n}\n";

    try expect_formatted(source, wanted);
}

test "a blank line inside a selector list is dropped" {
    try expect_formatted(".a,\n\n.b {\n    color: red;\n}\n", ".a,\n.b {\n    color: red;\n}\n");
}

test "a selector past a comment inside a list opens one level in" {
    const source = ".head,\n/* one */\n.a .b .c,\n/* two */\n.d,\n/* three */\n.e .f {\n" ++
        "    color: red;\n}\n";

    const wanted = ".head,\n/* one */\n    .a .b\n    .c,\n/* two */\n    .d,\n/* three */\n" ++
        ".e .f {\n    color: red;\n}\n";

    try expect_formatted(source, wanted);
}

test "a comment standing inside a value writes no break and counts toward the width" {
    const source = "body {\n    background: #d3d6d8 /*url(\"does.not.exist.png\")*/ " ++
        "url(/static/cached/img/relative.png);\n}\nbody {\n    background: #d3d6d8 /*u*/ " ++
        "url(/static/img/rel.png);\n}\n";

    const wanted = "body {\n    background: #d3d6d8 /*url(\"does.not.exist.png\")*/\n" ++
        "        url(/static/cached/img/relative.png);\n}\nbody {\n    background: #d3d6d8 " ++
        "/*u*/ url(/static/img/rel.png);\n}\n";

    try expect_formatted(source, wanted);
}

test "a selectors own separator stands past the comment that trails it" {
    const source = ".monaco-list:focus .selected .monaco-icon-label, /* list */\n" ++
        ".monaco-list:focus .selected .monaco-icon-label::after {\n    color: inherit;\n}\n";

    const wanted = ".monaco-list:focus .selected .monaco-icon-label /* list */,\n" ++
        ".monaco-list:focus .selected .monaco-icon-label::after {\n    color: inherit;\n}\n";

    try expect_formatted(source, wanted);
}

test "a layers own call stands at the level the layer opens on" {
    const source = ".a {\n    cursor: image-set(url(\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\") 1x, url(\"bbbbbbbbbbbb\") 2x) 5 8, text;\n" ++
        "}\n";

    const wanted = ".a {\n    cursor:\n        image-set(\n            url(\"aaaaaaaaaaaaaaaaaaa" ++
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\")\n                1x," ++
        "\n            url(\"bbbbbbbbbbbb\") 2x\n        )\n        5 8,\n        text;\n}\n";

    try expect_formatted(source, wanted);
}

test "a grid shorthand keeps the lines the source gave its value" {
    const source = ".b {\n    grid-template-areas:\n    \"x y\"\n    \"z w\";\n    grid-area:\n" ++
        "        one\n        two;\n}\n";

    const wanted = ".b {\n    grid-template-areas:\n        \"x y\"\n        \"z w\";\n" ++
        "    grid-area: one two;\n}\n";

    try expect_formatted(source, wanted);
}

test "a custom property past the fill cap keeps the lines the source gave it" {
    const source = ":root {\n    --wide:\n        aaaaaaaaaa,\n        bbbbbbbbbb,\n" ++
        "        cccccccccc,\n        dddddddddd,\n        eeeeeeeeee,\n        ffffffffff,\n" ++
        "        gggggggggg,\n        hhhhhhhhhh,\n        iiiiiiiiii,\n        jjjjjjjjjj,\n" ++
        "        kkkkkkkkkk,\n        llllllllll,\n        mmmmmmmmmm;\n    --slim:\n" ++
        "        aa,\n        bb,\n        cc;\n}\n";

    const wanted = ":root {\n    --wide:\n        aaaaaaaaaa,\n        bbbbbbbbbb,\n" ++
        "        cccccccccc,\n        dddddddddd,\n        eeeeeeeeee,\n        ffffffffff,\n" ++
        "        gggggggggg,\n        hhhhhhhhhh,\n        iiiiiiiiii,\n        jjjjjjjjjj,\n" ++
        "        kkkkkkkkkk,\n        llllllllll,\n        mmmmmmmmmm;\n" ++
        "    --slim: aa, bb, cc;\n}\n";

    try expect_formatted(source, wanted);
}

test "a long custom property opens its value and breaks only the call that overflows" {
    const source = ":host {\n" ++
        "  --x: inset 4px 4px 0px 0px var(--shadow-light),\n" ++
        "    inset -4px -4px 0px 0px var(--shadow-darker), 4px 0px 0px 0px " ++
        "var(--border-color),\n" ++
        "    0px 4px 0px 0px var(--border-color), -4px 0px 0px 0px " ++
        "var(--border-color);\n" ++
        "}\n";

    const wanted = ":host {\n" ++
        "    --x:\n" ++
        "        inset 4px 4px 0px 0px var(--shadow-light),\n" ++
        "        inset -4px -4px 0px 0px var(--shadow-darker), 4px 0px 0px 0px var(\n" ++
        "            --border-color\n" ++
        "        ),\n" ++
        "        0px 4px 0px 0px var(--border-color), -4px 0px 0px 0px " ++
        "var(--border-color);\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a grid template opens its value only when a later track starts a line" {
    const source = ".a {\n" ++
        "  grid-template-columns: [full-start] minmax(1em, 1fr)\n" ++
        "    [main-start] minmax(0, 40em) [main-end] minmax(1em, 1fr) [full-end] " ++
        "minmax(1em, 1fr) [last];\n" ++
        "  grid-template-rows:\n" ++
        "    repeat(2, 1fr);\n" ++
        "}\n";

    const wanted = ".a {\n" ++
        "    grid-template-columns:\n" ++
        "        [full-start] minmax(1em, 1fr)\n" ++
        "        [main-start] minmax(0, 40em) [main-end] minmax(1em, 1fr) [full-end] " ++
        "minmax(\n" ++
        "            1em,\n" ++
        "            1fr\n" ++
        "        ) [last];\n" ++
        "    grid-template-rows: repeat(2, 1fr);\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a kept value line closing its block takes the semicolon" {
    const source = ":host {\n" ++
        "  --shadow:\n" ++
        "    inset 4px 4px 0px 0px var(--shadow-light),\n" ++
        "    inset -4px -4px 0px 0px aaaaaaaaaaaaaaa, 4px 0px 0px 0px " ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,\n" ++
        "    0px 4px 0px 0px var(--border-color), -4px 0px 0px 0px " ++
        "var(--border-color)\n" ++
        "}\n";

    const wanted = ":host {\n" ++
        "    --shadow:\n" ++
        "        inset 4px 4px 0px 0px var(--shadow-light),\n" ++
        "        inset -4px -4px 0px 0px aaaaaaaaaaaaaaa, 4px 0px 0px 0px " ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,\n" ++
        "        0px 4px 0px 0px var(--border-color), -4px 0px 0px 0px " ++
        "var(--border-color);\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a kept value line breaks an overflowing call one argument per line" {
    const source = ":host {\n" ++
        "  --shadow:\n" ++
        "    inset 4px 4px 0px 0px var(--shadow-light), /* one */\n" ++
        "    inset -4px -4px 0px 0px var(--shadow-dark), 4px 0px 0px color-mix(in " ++
        "srgb, #fff 20%, red),\n" ++
        "    0px 4px 0px 0px var(--border-color), -4px 0px 0px 0px " ++
        "var(--border-color);\n" ++
        "}\n";

    const wanted = ":host {\n" ++
        "    --shadow:\n" ++
        "        inset 4px 4px 0px 0px var(--shadow-light), /* one */\n" ++
        "        inset -4px -4px 0px 0px var(--shadow-dark), 4px 0px 0px color-mix(\n" ++
        "            in srgb,\n" ++
        "            #fff 20%,\n" ++
        "            red\n" ++
        "        ),\n" ++
        "        0px 4px 0px 0px var(--border-color), -4px 0px 0px 0px " ++
        "var(--border-color);\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a value under the size threshold fills where a long list keeps its lines" {
    const source = ".a {\n" ++
        "  --x: a b c d e f g h i j k l m n o p q r s t u v w x y z aa bb cc dd ee " ++
        "ff gg hh ii jj kk, ll;\n" ++
        "  --z: 1px 2px 3px red, 1px 2px 3px blue, 4px 5px 6px green, 7px 8px 9px " ++
        "yellow, 1px 1px 1px black;\n" ++
        "  font-family: aaaaaaa, bbbbbbbb, cccccccc, dddddddd, eeeeeee, ffffffff,\n" ++
        "     gggggggg, hhhhhhhh, iiiiiiii, jjjjjjjj, kkkkkkk, llllllll, mmmmmmm;\n" ++
        "}\n";

    const wanted = ".a {\n" ++
        "    --x:\n" ++
        "        a b c d e f g h i j k l m n o p q r s t u v w x y z aa bb cc dd ee " ++
        "ff gg hh ii\n" ++
        "        jj kk,\n" ++
        "        ll;\n" ++
        "    --z:\n" ++
        "        1px 2px 3px red, 1px 2px 3px blue, 4px 5px 6px green, 7px 8px 9px " ++
        "yellow,\n" ++
        "        1px 1px 1px black;\n" ++
        "    font-family:\n" ++
        "        aaaaaaa, bbbbbbbb, cccccccc, dddddddd, eeeeeee, ffffffff,\n" ++
        "        gggggggg, hhhhhhhh, iiiiiiii, jjjjjjjj, kkkkkkk, llllllll, " ++
        "mmmmmmm;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a kept value line normalises its numbers and colours" {
    const source = ":host {\n" ++
        "  --shadow:\n" ++
        "    inset .5px 4px 0px 0px #FFFFFF,\n" ++
        "    inset -4px -4.50px 0px 0px var(--shadow-dark), 4px 0px 0px 0px " ++
        "var(--border-color),\n" ++
        "    0px 4px 0px 0px var(--border-color), -4px 0px 0px 0px " ++
        "var(--border-color);\n" ++
        "}\n";

    const wanted = ":host {\n" ++
        "    --shadow:\n" ++
        "        inset 0.5px 4px 0px 0px #ffffff,\n" ++
        "        inset -4px -4.5px 0px 0px var(--shadow-dark), 4px 0px 0px 0px var(\n" ++
        "            --border-color\n" ++
        "        ),\n" ++
        "        0px 4px 0px 0px var(--border-color), -4px 0px 0px 0px " ++
        "var(--border-color);\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a comment past a comma in an at rule prelude stays past it" {
    const cases = [_][2][]const u8{
        .{
            "@media /* c69 */ screen /* c70 */ , /* c71 */ print /* c72 */ {}\n",
            "@media /* c69 */ screen /* c70 */, /* c71 */ print /* c72 */ {\n}\n",
        },
        .{ "@import url(x) a, /* c */ b;\n", "@import url(x) a, /* c */ b;\n" },
        .{ "/* lead */ @media a, /* c */ b {}\n", "/* lead */ @media a, /* c */ b {\n}\n" },
    };

    for (cases) |case| {
        try expect_formatted(case[0], case[1]);
    }
}

test "a comment that closes a call stands against the paren" {
    const cases = [_][2][]const u8{
        .{ "a { width: calc(1px /* c */); }\n", "a {\n    width: calc(1px /* c */);\n}\n" },
        .{ "@media (min-width: 1px /* c */) {}\n", "@media (min-width: 1px /* c */) {\n}\n" },
    };

    for (cases) |case| {
        try expect_formatted(case[0], case[1]);
    }
}

test "only a name is quoted as an attribute value" {
    const gpa = std.testing.allocator;

    try expect_formatted("a[id=--x] {}\n", "a[id=\"--x\"] {\n}\n");
    try expect_formatted("a[id=b\\ c] {}\n", "a[id=\"b\\ c\"] {\n}\n");

    const sources = [_][]const u8{ "a[id=func(\"foo\")] {\n}\n", "a[data-x=1] {\n}\n" };

    for (sources) |source| {
        const once = try expect_related(source);
        defer gpa.free(once);

        try std.testing.expectEqualStrings(source, once);
    }
}

test "a substring match in an at rule prelude keeps its operator whole" {
    const gpa = std.testing.allocator;
    const source = "@custom-selector :--icon i[class^='icon-'], i[ class *= ' icon-' ];\n";
    const once = try expect_related(source);
    defer gpa.free(once);

    try require(std.mem.find(u8, once, "* =") == null, "{s}", .{once});
    try require(std.mem.find(u8, once, "*=") != null, "{s}", .{once});
}

test "a value line that opens onto a comment reads as one line" {
    const gpa = std.testing.allocator;

    const sources = [_][]const u8{
        "@font-face {\n    src: /* comment 16 */ local(/* comment 17 */ \"Prettier\" " ++
            "/* comment 18 */), /* comment 19 */\n        /* comment 20 */ " ++
            "url(\"http://prettier.com/font.woff\") /* comment 21 */ ; /* comment 22 */\n}\n",
        ".foo {/* comment 23 */color/* comment 24 */:/* comment 25 */blue" ++
            "/* comment 26 */;/* comment 27 */transform/* comment 28 */:/* comment 29 */" ++
            "translate(/* comment 30 */10px/* comment 31 */)/* comment 32 */;/* comment 33 */}\n",
        "/* comment 11 */ @import /* comment 12 */\n    /* comment 13 */ url(\"bluish.css\") " ++
            "/* comment 14 */\n    /* comment 15 */ projection /* comment 16 */,\n" ++
            "    /* comment 17 */ tv /* comment 18 */; /* comment 19 */\n",
    };

    for (sources) |source| {
        gpa.free(try expect_related(source));
    }
}

test "a comment alone on a line inside a declaration leaves the declaration joined" {
    const gpa = std.testing.allocator;

    const source = ".foo {\n    /* comment 46 */ color  /* comment 47 */\n    /* comment 48 */\n" ++
        "    /* comment 49 */ :  /* comment 50 */\n    /* comment 51 */\n" ++
        "    /* comment 52 */ blue  /* comment 53 */\n    /* comment 54 */\n" ++
        "    /* comment 55 */ ;  /* comment 56 */\n}\n";

    gpa.free(try expect_related(source));
}

test "a value past a comment is read as a value" {
    const cases = [_][2][]const u8{
        .{ "a { margin: 1px /* c */ .5em; }\n", "a {\n    margin: 1px /* c */ 0.5em;\n}\n" },
        .{ "@media /* c */ (min-width: .5em) {}\n", "@media /* c */ (min-width: 0.5em) {\n}\n" },
        .{
            "/* c */ @MEDIA (min-width: 10PX) and (max-width: 2E3px) {}\n",
            "/* c */ @media (min-width: 10px) and (max-width: 2e3px) {\n}\n",
        },
    };

    for (cases) |case| {
        try expect_formatted(case[0], case[1]);
    }
}
