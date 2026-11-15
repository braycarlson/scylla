const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Buffer = @import("../stdx/bounded/buffer.zig");
const Defaults = @import("python.zig").Defaults;
const EventsType = @import("../syntax/tree.zig").EventsType;
const Formatter = @import("python.zig").Formatter;
const FormatterError = @import("formatters.zig").FormatterError;
const Index = @import("../text/line_index.zig").LineIndex;
const Input = @import("python.zig").Input;
const Kind = @import("../syntax/python/kind.zig").Kind;
const LineEnding = @import("../text/line_ending.zig").LineEnding;
const Parser = @import("../syntax/python/parse.zig").Parser;
const PragmaAt = @import("pragma.zig").PragmaAt;
const Pragmas = @import("pragma.zig").Pragmas;
const QuotePreference = @import("python.zig").QuotePreference;
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
const Events = EventsType(Kind);
const HeldError = FormatterError || error{ Overflow, Truncated };
const Tree = TreeType(Kind);

const Held = struct {
    events: *Events,
    formatter: Formatter,
    index: Index,
    parser: *Parser,
    pragmas: Pragmas,
    raw: ArrayType(Kind),
    stub: bool,
    tokens: Tokens,
    tree: Tree,

    fn init(held: *Held, gpa: std.mem.Allocator) !void {
        held.events = try gpa.create(Events);
        errdefer gpa.destroy(held.events);

        try held.events.init(gpa, event_count_max);
        errdefer held.events.deinit(gpa);

        held.formatter = try .init(gpa, element_count_max, arena_bytes_max);
        errdefer held.formatter.deinit(gpa);

        held.index = try .init(gpa, line_count_max);
        errdefer held.index.deinit(gpa);

        held.parser = try gpa.create(Parser);
        errdefer gpa.destroy(held.parser);

        held.pragmas = try .init(gpa, pragma_count_max);
        errdefer held.pragmas.deinit(gpa);

        held.raw = try .init(gpa, token_count_max);
        errdefer held.raw.deinit(gpa);

        held.tokens = try .init(gpa, token_count_max);
        errdefer held.tokens.deinit(gpa);

        held.tree = try .init(gpa, node_count_max, diagnostic_count_max);
        held.stub = false;

        assert(held.raw.capacity() == held.tokens.items.capacity());
        assert(held.tree.count() == 0);
    }

    fn deinit(held: *Held, gpa: std.mem.Allocator) void {
        assert(held.raw.capacity() == token_count_max);
        assert(held.tokens.items.capacity() == token_count_max);

        held.tree.deinit(gpa);
        held.tokens.deinit(gpa);
        held.raw.deinit(gpa);
        held.pragmas.deinit(gpa);
        gpa.destroy(held.parser);
        held.index.deinit(gpa);
        held.formatter.deinit(gpa);
        held.events.deinit(gpa);
        gpa.destroy(held.events);
        held.* = undefined;
    }

    fn format(held: *Held, source: []const u8, out: *Buffer) HeldError!void {
        assert(source.len <= std.math.maxInt(u32));

        held.lexed_of(source);

        try held.index.build(source);
        try held.pragmas.scan(source, held.tokens.slice(), &held.index);
        try raw_of(Kind, held.tokens.slice(), &held.raw);

        const outcome = held.parsed(source);
        const pragmas = held.pragmas.const_slice();
        const input = held.input_of(source, outcome, pragmas, &Input.defaults);

        assert(pragmas.len <= pragma_count_max);
        assert(input.tokens.len == input.raw.len);

        return held.formatter.format(&input, out);
    }

    fn input_of(
        held: *const Held,
        source: []const u8,
        outcome: Structure,
        pragmas: []const PragmaAt,
        defaults: *const Defaults,
    ) Input {
        assert(held.raw.count() == held.tokens.count());
        assert(source.len <= std.math.maxInt(u32));
        assert(pragmas.len <= std.math.maxInt(u32));
        if (outcome == .complete) assert(held.tree.count() > 0);

        return .{
            .line_ending = defaults.line_ending,
            .magic_trailing_comma = defaults.magic_trailing_comma,
            .options = .default,
            .outcome = outcome,
            .pragmas = pragmas,
            .quote = defaults.quote,
            .raw = held.raw.const_slice(),
            .source = source,
            .stub = held.stub,
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

        lex(.of(.python), source, &held.tokens) catch |err| switch (err) {
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

            listed.appendAssumeCapacity(try word_of(arena, token, source));
        }

        assert(listed.items.len <= lexed.len);

        const found = try words_found(arena, listed.items);

        assert(found.len <= listed.items.len);

        return found;
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
            switch (kind) {
                .comment, .dedent, .indent => {},
                else => found.appendAssumeCapacity(kind),
            }
        }

        assert(found.items.len <= raw.len);
        assert(raw.len == held.tokens.count());
    }

    fn comments(
        held: *Held,
        gpa: std.mem.Allocator,
        source: []const u8,
        found: *std.ArrayList(u8),
    ) !void {
        assert(source.len <= std.math.maxInt(u32));

        held.classified(source);

        const raw = held.raw.const_slice();
        const tokens = held.tokens.slice();

        assert(raw.len == tokens.len);

        found.clearRetainingCapacity();

        for (raw, tokens) |kind, token| {
            if (kind != .comment) continue;

            const text = std.mem.trimEnd(u8, token.text(source), ascii_whitespace);

            try comment(gpa, text, found);
            try found.append(gpa, '\n');
        }

        assert(found.items.len <= source.len + raw.len);
    }
};

const Tuned = struct {
    held: Held,
    lexed: Tokens,
    out: Buffer,
    scratch: Buffer,

    fn init(tuned: *Tuned, gpa: std.mem.Allocator) !void {
        try tuned.held.init(gpa);
        errdefer tuned.held.deinit(gpa);

        tuned.lexed = try .init(gpa, token_count_max);
        errdefer tuned.lexed.deinit(gpa);

        tuned.out = try .init(gpa, tuned_bytes_max);
        errdefer tuned.out.deinit(gpa);

        tuned.scratch = try .init(gpa, tuned_bytes_max);

        assert(tuned.out.empty());
        assert(tuned.scratch.capacity() == tuned_bytes_max);
    }

    fn deinit(tuned: *Tuned, gpa: std.mem.Allocator) void {
        assert(tuned.out.capacity() == tuned_bytes_max);
        assert(tuned.scratch.capacity() == tuned_bytes_max);

        tuned.scratch.deinit(gpa);
        tuned.out.deinit(gpa);
        tuned.lexed.deinit(gpa);
        tuned.held.deinit(gpa);
        tuned.* = undefined;
    }

    fn prepare(tuned: *Tuned, source: []const u8) Structure {
        assert(source.len <= std.math.maxInt(u32));

        const held = &tuned.held;

        held.tree.clear();

        held.classified(source);
        held.index.build(source) catch unreachable;

        held.pragmas.scan(source, held.tokens.slice(), &held.index) catch |err| switch (err) {
            error.Overflow => std.debug.panic("the pragma table overflowed", .{}),
        };

        assert(held.index.count() > 0);
        assert(held.pragmas.count() <= pragma_count_max);

        return held.parsed(source);
    }

    fn formatted(
        tuned: *Tuned,
        source: []const u8,
        line_ending: LineEnding,
        magic_trailing_comma: bool,
        quote: QuotePreference,
    ) ![]const u8 {
        assert(source.len <= std.math.maxInt(u32));

        const outcome = tuned.prepare(source);

        const defaults: Defaults = .{
            .line_ending = line_ending,
            .magic_trailing_comma = magic_trailing_comma,
            .quote = quote,
        };

        const pragmas = tuned.held.pragmas.const_slice();
        const input = tuned.held.input_of(source, outcome, pragmas, &defaults);

        try tuned.held.formatter.format(&input, &tuned.out);

        assert(tuned.out.count() <= tuned_bytes_max);
        assert(input.source.ptr == source.ptr);

        return tuned.out.const_slice();
    }

    fn ranged(tuned: *Tuned, source: []const u8, range: Span) ?Ranged {
        assert(range.end() <= source.len);

        const outcome = tuned.prepare(source);
        const pragmas = tuned.held.pragmas.const_slice();
        const input = tuned.held.input_of(source, outcome, pragmas, &Input.defaults);
        const formatter = &tuned.held.formatter;

        const result = formatter.format_range(
            &input,
            range,
            &tuned.scratch,
            &tuned.lexed,
            &tuned.out,
        );

        const span = result catch return null;

        assert(span.end() <= source.len);

        return .{ .text = tuned.out.const_slice(), .span = span };
    }
};

const Twice = struct {
    first: Buffer,
    held: Held,
    second: Buffer,

    fn init(twice: *Twice, gpa: std.mem.Allocator) !void {
        twice.first = try .init(gpa, arena_bytes_max);
        errdefer twice.first.deinit(gpa);

        try twice.held.init(gpa);
        errdefer twice.held.deinit(gpa);

        twice.second = try .init(gpa, arena_bytes_max);

        assert(twice.first.empty());
        assert(twice.second.empty());
    }

    fn deinit(twice: *Twice, gpa: std.mem.Allocator) void {
        assert(twice.first.capacity() == arena_bytes_max);
        assert(twice.second.capacity() == arena_bytes_max);

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
    pub const Tally = struct { formatted: u32, refused: u32 };
    pub const weight = Fixture.weight;

    pub fn init(worker: *RelationsWorker, gpa: std.mem.Allocator, shared: *const Shared) !void {
        assert(@TypeOf(shared.*) == Shared);

        try worker.twice.init(gpa);

        worker.gpa = gpa;
        worker.relations = .empty;

        assert(worker.twice.first.empty());
    }

    pub fn deinit(worker: *RelationsWorker, gpa: std.mem.Allocator) void {
        assert(worker.twice.first.capacity() == arena_bytes_max);

        worker.relations.deinit(gpa);
        worker.twice.deinit(gpa);
        worker.* = undefined;
    }

    pub fn visit(worker: *RelationsWorker, fixture: *const Fixture, tally: *Tally) !void {
        assert(fixture.name.len > 0);
        assert(@TypeOf(tally.*) == Tally);

        const twice = &worker.twice;

        twice.held.format(fixture.source, &twice.first) catch {
            tally.refused += 1;

            return;
        };

        tally.formatted += 1;

        const once = twice.first.const_slice();

        try worker.relations.expect_kinds(worker.gpa, &twice.held, fixture, once);
        try worker.relations.expect_comments(worker.gpa, &twice.held, fixture, once);

        const second = twice.held.format(once, &twice.second);

        try require(is_complete(second), "{s}", .{fixture.name});

        if (difference_first(once, twice.second.const_slice())) |difference| {
            std.debug.print("{s} is not idempotent at line {d}:\n{s}\n{s}\n", .{
                fixture.name,
                difference.line,
                difference.left,
                difference.right,
            });

            return error.TestUnexpectedResult;
        }
    }
};

const Relations = struct {
    comments_after: std.ArrayList(u8),
    comments_before: std.ArrayList(u8),
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

        const kept = preserved(relations.kinds_before.items, relations.kinds_after.items);

        try require(kept, "{s} lost a token or gained one that is not a comma", .{fixture.name});
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

        assert(relations.comments_before.items.len <= fixture.source.len);
        assert(relations.comments_after.items.len <= once.len);

        const before = relations.comments_before.items;
        const after = relations.comments_after.items;

        try expect_text(fixture.name, "lost a comment", before, after);
    }
};

const Difference = struct {
    line: u32,
    left: []const u8,
    right: []const u8,
};

const Fixture = corpus.File;

const Ranged = struct {
    text: []const u8,
    span: Span,
};

const arena_bytes_max: u32 = 1 << 22;
const ascii_whitespace = " \t\n\x0c\r";
const element_count_max: u32 = 1 << 18;
const diagnostic_count_max: u32 = 1 << 12;
const event_count_max: u32 = 1 << 20;

const every_category = [_][]const u8{
    "literal-normalisation",
    "redundant-parentheses",
    "statement-separator",
    "verbatim-format-string",
};

const file_count_max: u32 = 1 << 20;
const fixture_count_min: u32 = 8;
const fixture_root = "tests/fixtures/python";
const golden_root = "tests/fixtures/golden-ruff-format";
const line_count_max: u32 = 1 << 14;
const line_width_max: u32 = 88;
const node_count_max: u32 = 1 << 18;
const path_bytes_max: u32 = 4096;
const pragma_count_max: u32 = 1 << 10;
const report_variable = "SCYLLA_REPORT";
const residue_name = "residue-format-python.json";
const source_bytes_max: u32 = 1 << 28;
const token_count_max: u32 = 1 << 18;
const tuned_bytes_max: u32 = 1 << 16;

fn plain(tuned: *Tuned, source: []const u8, quote: QuotePreference) ![]const u8 {
    assert(source.len > 0);
    assert(source.len <= tuned_bytes_max);

    return tuned.formatted(source, .line_feed, true, quote);
}

fn expect_plain(
    tuned: *Tuned,
    source: []const u8,
    quote: QuotePreference,
    wanted: []const u8,
) !void {
    assert(source.len > 0);
    assert(wanted.len > 0);

    try std.testing.expectEqualStrings(wanted, try plain(tuned, source, quote));
}

fn expect_held(source: []const u8, wanted: []const u8) !void {
    assert(source.len <= std.math.maxInt(u32));
    assert(wanted.len <= std.math.maxInt(u32));

    return expect_held_as(source, wanted, false);
}

fn expect_held_as(source: []const u8, wanted: []const u8, stub: bool) !void {
    const gpa = std.testing.allocator;

    assert(source.len > 0);
    assert(wanted.len > 0);

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    held.stub = stub;

    var out: Buffer = try .init(gpa, arena_bytes_max);
    defer out.deinit(gpa);

    try held.format(source, &out);
    try std.testing.expectEqualStrings(wanted, out.const_slice());
}

fn applied(tuned: *Tuned, buffer: []u8, source: []const u8, range: Span) ![]const u8 {
    assert(range.end() <= source.len);
    assert(buffer.len >= source.len);

    const held = tuned.ranged(source, range) orelse return error.TestUnexpectedResult;
    const before = source[0..held.span.offset];
    const after = source[held.span.end()..];

    return std.mem.print(buffer, "{s}{s}{s}", .{ before, held.text, after });
}

fn lines_fit(text: []const u8, width: u32) bool {
    assert(width > 0);
    assert(text.len <= std.math.maxInt(u32));

    var lines = std.mem.splitScalar(u8, text, '\n');

    for (0..text.len + 1) |_| {
        const line = lines.next() orelse break;

        assert(line.len <= text.len);

        if (line.len > width) return false;
    }

    return true;
}

fn word_of(arena: std.mem.Allocator, token: Token, source: []const u8) ![]const u8 {
    assert(token.length > 0);
    assert(token.end() <= source.len);

    return switch (token.kind) {
        .string => "<string>",
        .number => number(arena, token.text(source)),
        else => token.text(source),
    };
}

fn words_found(arena: std.mem.Allocator, held: []const []const u8) ![]const []const u8 {
    assert(held.len <= std.math.maxInt(u32));

    var found: std.ArrayList([]const u8) = try .initCapacity(arena, held.len);

    for (held, 0..) |word, index| {
        assert(word.len > 0);

        const next: []const u8 = if (index + 1 < held.len) held[index + 1] else "";
        const closed = next.len == 1 and std.mem.findScalar(u8, ")]}", next[0]) != null;
        const trailing = std.mem.eql(u8, word, ",") and closed;
        const grouping = std.mem.eql(u8, word, "(") or std.mem.eql(u8, word, ")");

        if (trailing) continue;
        if (grouping) continue;
        if (std.mem.eql(u8, word, ";")) continue;

        const last: []const u8 = if (found.items.len > 0) found.items[found.items.len - 1] else "";
        const joined = std.mem.eql(u8, word, "<string>") and std.mem.eql(u8, last, "<string>");
        if (joined) continue;

        const leaning = std.mem.eql(u8, last, ".") and std.ascii.isDigit(word[0]);

        if (leaning) {
            const dotted = try std.mem.concat(arena, u8, &.{ ".", word });

            found.items[found.items.len - 1] = try number(arena, dotted);

            continue;
        }

        assert(found.items.len <= index);

        found.appendAssumeCapacity(word);
    }

    assert(found.items.len <= held.len);

    return found.items;
}

fn number(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    assert(text.len > 0);

    const held = try arena.alloc(u8, text.len);

    _ = std.ascii.lowerString(held, text);

    const at = std.mem.findScalar(u8, held, '.') orelse return held;
    const before = held[0..at];
    const after = held[at + 1 ..];
    const leading = if (before.len == 0) "0" else before;
    const trailing = if (after.len == 0) "0" else after;
    const found = try std.mem.concat(arena, u8, &.{ leading, ".", trailing });

    assert(found.len >= held.len);
    assert(found[leading.len] == '.');

    return found;
}

fn comment(gpa: std.mem.Allocator, text: []const u8, found: *std.ArrayList(u8)) !void {
    assert(text.len <= std.math.maxInt(u32));

    const length = found.items.len;
    const spaced = std.mem.startsWith(u8, text, "# ");

    if (spaced) {
        try found.append(gpa, '#');
        try found.appendSlice(gpa, text[2..]);
    } else {
        try found.appendSlice(gpa, text);
    }

    assert(found.items.len >= length);
    if (spaced) assert(found.items.len + 1 == length + text.len);
}

fn difference_first(left: []const u8, right: []const u8) ?Difference {
    assert(left.len <= std.math.maxInt(u32));
    assert(right.len <= std.math.maxInt(u32));

    const line_count = @max(
        std.mem.countScalar(u8, left, '\n'),
        std.mem.countScalar(u8, right, '\n'),
    );

    assert(line_count <= left.len + right.len);

    var first = std.mem.splitScalar(u8, left, '\n');
    var second = std.mem.splitScalar(u8, right, '\n');

    for (0..line_count + 1) |index| {
        const held = first.next() orelse "";
        const other = second.next() orelse "";

        if (!std.mem.eql(u8, held, other)) {
            assert(index <= line_count);

            return .{ .line = @intCast(index + 1), .left = held, .right = other };
        }
    }

    return null;
}

fn strung(kind: Kind) bool {
    if (!kind.is_token()) return false;

    return switch (kind) {
        .f_string_end,
        .f_string_middle,
        .f_string_start,
        .string_bytes,
        .string_format,
        .string_plain,
        => true,
        else => false,
    };
}

fn collapsed(kinds: []Kind) []Kind {
    assert(kinds.len <= std.math.maxInt(u32));

    var count: usize = 0;

    for (0..kinds.len) |index| {
        const kind = kinds[index];

        assert(count <= index);

        if (!strung(kind)) {
            kinds[count] = kind;
            count += 1;

            continue;
        }

        if (count > 0) {
            if (strung(kinds[count - 1])) continue;
        }

        kinds[count] = .string_plain;
        count += 1;
    }

    assert(count <= kinds.len);

    return kinds[0..count];
}

fn preserved(source: []Kind, printed: []Kind) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(printed.len <= std.math.maxInt(u32));

    const before = collapsed(source);
    const after = collapsed(printed);
    var held: usize = 0;

    for (after) |kind| {
        held = preserved_skip(before, held, kind);

        assert(held <= before.len);

        if (held < before.len) {
            if (before[held] == kind) {
                held += 1;

                continue;
            }
        }

        const added = switch (kind) {
            .comma, .newline, .paren_close, .paren_open => true,
            else => false,
        };

        if (!added) return false;
    }

    held = preserved_skip(before, held, null);

    assert(held <= before.len);

    return held == before.len;
}

fn preserved_skip(before: []const Kind, start: usize, wanted: ?Kind) usize {
    assert(start <= before.len);
    if (wanted) |held| assert(held.is_token());

    for (before[start..], start..) |kind, position| {
        assert(position < before.len);

        if (wanted) |held| {
            if (kind == held) return position;
        }

        const dropped = switch (kind) {
            .newline, .paren_close, .paren_open, .semicolon => true,
            else => false,
        };

        if (!dropped) return position;
    }

    return before.len;
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
        if (!std.mem.eql(u8, std.Io.Dir.path.extension(entry.name), ".py")) continue;

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

    return std.mem.eql(u8, std.Io.Dir.path.extension(basename), ".py");
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

fn report(formatted: u32, refused: u32) !void {
    assert(formatted < std.math.maxInt(u32));
    assert(refused < std.math.maxInt(u32));

    var path_bytes: [environment.value_bytes_max]u8 = undefined;
    const path = environment.get(report_variable, &path_bytes) orelse return;
    const arguments = .{ formatted, refused };
    var buffer: [path_bytes_max]u8 = undefined;
    const text = try std.mem.print(&buffer, "formatted {d}, refused {d}\n", arguments);

    assert(path.len > 0);
    assert(text.len > 0);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = text });
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

    const length = @min(before.len, after.len);

    assert(name.len > 0);
    assert(length <= before.len);

    for (0..length) |index| {
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

test "a one element tuple holding a broken collection gets one comma" {
    const gpa = std.testing.allocator;
    const source = "a = (\n    (\n        None,\n        1,\n    ),\n)\n";
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, arena_bytes_max);
    defer out.deinit(gpa);

    try held.format(source, &out);
    try std.testing.expect(std.mem.find(u8, out.const_slice(), ",,") == null);
    try std.testing.expectEqualStrings(source, out.const_slice());
}

test "an empty collection ending a call is no magic trailing comma" {
    const source = "self.assertEqual(Child.check(), [])\n";

    try expect_held(source, source);
}

test "a comment after the trailing comma keeps the comma before it" {
    const source = "from a import (\n    b,\n    c,  # note\n)\n";

    try expect_held(source, source);
}

test "a comment on a line of its own keeps that line" {
    const gpa = std.testing.allocator;
    const source = "x = [\n    1,\n    2,\n    # note\n]\n";
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, arena_bytes_max);
    defer out.deinit(gpa);

    try held.format(source, &out);

    const once = out.const_slice();

    try require(std.mem.find(u8, once, "2,\n") != null, "{s}", .{once});
    try require(std.mem.find(u8, once, "# note\n]") != null, "{s}", .{once});
}

test "a one line suite holding a semicolon stays on its line" {
    const gpa = std.testing.allocator;
    const source = "def f(t):\n    if t: a = 1; b = 2\n    else: a = 3; b = 4\n";
    var twice: Twice = undefined;

    try twice.init(gpa);
    defer twice.deinit(gpa);

    try twice.held.format(source, &twice.first);

    const once = twice.first.const_slice();

    try twice.held.format(once, &twice.second);
    try std.testing.expectEqualStrings(once, twice.second.const_slice());
}

test "a multiline string leaves the column its last line ends at" {
    const gpa = std.testing.allocator;

    const source = "def f():\n    try:\n        pass\n    except:\n        if d:\n" ++
        "            print(\"\"\"\nIf you would like to see debugging output,\n" ++
        "try: %s -d5\n\"\"\" % sys.argv[0])\n";

    var twice: Twice = undefined;

    try twice.init(gpa);
    defer twice.deinit(gpa);

    try twice.held.format(source, &twice.first);

    const once = twice.first.const_slice();

    try require(std.mem.find(u8, once, "sys.argv[0]") != null, "{s}", .{once});

    try twice.held.format(once, &twice.second);
    try std.testing.expectEqualStrings(once, twice.second.const_slice());
}

test "a format off region leaves the indentation it found" {
    const gpa = std.testing.allocator;

    const source = "def f(a):\n    if a:\n        # note\n        # fmt: off\n        x = (\n" ++
        "            1 or\n            2\n        )\n        # fmt: on\n        if x:\n" ++
        "            return x\n\n    return 0\n";

    var twice: Twice = undefined;

    try twice.init(gpa);
    defer twice.deinit(gpa);

    try twice.held.format(source, &twice.first);

    const once = twice.first.const_slice();

    try std.testing.expectEqualStrings(source, once);

    try twice.held.format(once, &twice.second);
}

test "formatting keeps every token it was given" {
    const gpa = std.testing.allocator;
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, arena_bytes_max);
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

    var out: Buffer = try .init(gpa, arena_bytes_max);
    defer out.deinit(gpa);

    var relations: Relations = .empty;
    defer relations.deinit(gpa);

    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    for (found.items) |*fixture| {
        try held.format(fixture.source, &out);
        try relations.expect_comments(gpa, &held, fixture, out.const_slice());
    }
}

test "the formatted output matches the oracle modulo residue" {
    const gpa = std.testing.allocator;
    var carried = try oracle.residue_of(gpa, residue_name, &every_category);
    defer carried.deinit(gpa);

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, arena_bytes_max);
    defer out.deinit(gpa);

    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    var compared: u32 = 0;

    for (found.items) |fixture| {
        if (carried.contains(fixture.name)) continue;

        try held.format(fixture.source, &out);

        const golden = try read_under(gpa, golden_root, fixture.name);
        defer gpa.free(golden);

        const message = "diverges from ruff and no residue row names it";

        try expect_text(fixture.name, message, golden, out.const_slice());

        compared += 1;
    }

    try require(
        compared >= floor.fixture_format_python,
        "the Python fixtures lost a formatting: {d} compared, floor {d}",
        .{ compared, floor.fixture_format_python },
    );
}

test "every residue row names a fixture that diverges" {
    const gpa = std.testing.allocator;
    var carried = try oracle.residue_of(gpa, residue_name, &every_category);
    defer carried.deinit(gpa);

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, arena_bytes_max);
    defer out.deinit(gpa);

    for (carried.fixtures.items) |name| {
        const source = try read_under(gpa, fixture_root, name);
        defer gpa.free(source);

        try held.format(source, &out);

        const golden = try read_under(gpa, golden_root, name);
        defer gpa.free(golden);

        const diverged = !std.mem.eql(u8, out.const_slice(), golden);

        try require(diverged, "{s} matches ruff and needs no residue row", .{name});
    }
}

test "a file that does not parse is refused" {
    const gpa = std.testing.allocator;
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, arena_bytes_max);
    defer out.deinit(gpa);

    try std.testing.expectError(error.SourceInvalid, held.format("def f(:\n", &out));
    try std.testing.expect(out.empty());
}

test "a file that assigns to or deletes what no target names is refused" {
    const gpa = std.testing.allocator;

    const refused = [_][]const u8{
        "del a == b\n",
        "f() = 1\n",
        "a, f() = 1, 2\n",
        "del [a, *b]\n",
        "for f() in a:\n    pass\n",
        "with a as f():\n    pass\n",
        "x = [a for f() in b]\n",
    };

    const formatted = [_][]const u8{
        "del a, b\n",
        "a.b, c[0], *d = e\n",
        "(a), [b, *c] = d\n",
        "x = f(), g()\n",
    };

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, arena_bytes_max);
    defer out.deinit(gpa);

    for (refused) |source| {
        out.clear();
        try std.testing.expectError(error.SourceInvalid, held.format(source, &out));
    }

    for (formatted) |source| {
        out.clear();
        try held.format(source, &out);
    }
}

test "a range reads back the lines it names" {
    const gpa = std.testing.allocator;
    const source = "x=1\ny=2\nz=3\n";
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, arena_bytes_max);
    defer out.deinit(gpa);

    held.classified(source);

    const outcome = held.parsed(source);
    const input = held.input_of(source, outcome, &.{}, &Input.defaults);
    const span = try held.formatter.range(&input, .{ .first = 1, .last = 1 }, &out);

    try std.testing.expectEqualStrings("x = 1\ny = 2\nz = 3\n", out.const_slice());
    try std.testing.expectEqualStrings("y = 2\n", span.text(out.const_slice()));
}

test "the three relations hold over the corpus" {
    const gpa = std.testing.allocator;
    const root = corpus.named(.root) orelse return;
    var files = try corpus.collect(gpa, root, source_bytes_max, corpus_selected);
    defer files.deinit(gpa);

    var tally: RelationsWorker.Tally = .{ .formatted = 0, .refused = 0 };

    try stripe.run(RelationsWorker, gpa, &.{}, files.slice(), &tally);
    try report(tally.formatted, tally.refused);
}

test "a single quoted file stays single quoted under that preference" {
    const gpa = std.testing.allocator;
    const source = "held = 'text'\nother = \"text\"\n";
    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    try expect_plain(&tuned, source, .single, "held = 'text'\nother = 'text'\n");
    try expect_plain(&tuned, source, .double, "held = \"text\"\nother = \"text\"\n");
    try expect_plain(&tuned, source, .preserve, "held = 'text'\nother = \"text\"\n");
}

test "a string holding the wanted quote stays as the author wrote it" {
    const gpa = std.testing.allocator;
    const source = "held = \"it's\"\n";
    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    try expect_plain(&tuned, source, .single, "held = \"it's\"\n");
}

test "a magic trailing comma breaks its bracket until it is turned off" {
    const gpa = std.testing.allocator;
    const source = "held = [\n    1,\n]\n";
    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    const kept = try tuned.formatted(source, .line_feed, true, .double);

    try std.testing.expectEqualStrings("held = [\n    1,\n]\n", kept);

    const joined = try tuned.formatted(source, .line_feed, false, .double);

    try std.testing.expectEqualStrings("held = [1]\n", joined);
}

test "a carriage return line feed file writes every line that way" {
    const gpa = std.testing.allocator;
    const source = "x = 1\ny   =   2\nz = 3\n";
    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    const held = try tuned.formatted(source, .carriage_return_line_feed, true, .double);

    try std.testing.expectEqualStrings("x = 1\r\ny = 2\r\nz = 3\r\n", held);
}

test "a line break inside a string takes the ending once" {
    const gpa = std.testing.allocator;
    const carriage = "x = \"\"\"a\r\nb\"\"\"\r\n";
    const feed = "x = \"\"\"a\nb\"\"\"\n";
    const crlf: LineEnding = .carriage_return_line_feed;
    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    try std.testing.expectEqualStrings(
        "x = \"\"\"a\r\nb\"\"\"\r\n",
        try tuned.formatted(carriage, crlf, true, .double),
    );

    try std.testing.expectEqualStrings(
        "x = \"\"\"a\r\nb\"\"\"\r\n",
        try tuned.formatted(feed, crlf, true, .double),
    );

    try std.testing.expectEqualStrings(
        "x = \"\"\"a\nb\"\"\"\n",
        try tuned.formatted(carriage, .line_feed, true, .double),
    );

    try std.testing.expectEqualStrings(
        "x = \"\"\"a\nb\"\"\"\n",
        try tuned.formatted(feed, .line_feed, true, .double),
    );
}

test "a stub owes no blank to the clause that continues its statement" {
    const gpa = std.testing.allocator;
    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    try expect_plain(
        &tuned,
        "if X:\n    def f(a) -> int: ...\nelse:\n    pass\n",
        .double,
        "if X:\n\n    def f(a) -> int: ...\nelse:\n    pass\n",
    );

    try expect_plain(
        &tuned,
        "try:\n    class C: ...\nexcept E:\n    pass\nfinally:\n    pass\n",
        .double,
        "try:\n\n    class C: ...\nexcept E:\n    pass\nfinally:\n    pass\n",
    );

    try expect_plain(
        &tuned,
        "if X:\n    def f(a) -> int: ...\n\n\nelse:\n    pass\n",
        .double,
        "if X:\n\n    def f(a) -> int: ...\n\n\nelse:\n    pass\n",
    );

    try expect_plain(
        &tuned,
        "if X:\n    def f(a) -> int: ...\ny = 1\n",
        .double,
        "if X:\n\n    def f(a) -> int: ...\n\n\ny = 1\n",
    );
}

test "a sole multiline string takes the hug a call gives it and no other bracket" {
    const gpa = std.testing.allocator;
    const hugged = "g(\n    a,\n    html=dedent(\"\"\"\n    <p>x</p>\"\"\"),\n)\n";
    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    try expect_plain(&tuned, hugged, .double, hugged);

    try expect_plain(
        &tuned,
        "g(\n    a,\n    html=(\"\"\"\n    <p>x</p>\"\"\"),\n)\n",
        .double,
        "g(\n    a,\n    html=(\n        \"\"\"\n    <p>x</p>\"\"\"\n    ),\n)\n",
    );

    try expect_plain(
        &tuned,
        "x = t[\"\"\"\n<p>x</p>\"\"\"]\n",
        .double,
        "x = t[\n    \"\"\"\n<p>x</p>\"\"\"\n]\n",
    );

    try expect_plain(
        &tuned,
        "x = [\"\"\"\n<p>x</p>\"\"\"]\n",
        .double,
        "x = [\n    \"\"\"\n<p>x</p>\"\"\"\n]\n",
    );
}

test "a multiline format string respaces every field and keeps its own lines" {
    const gpa = std.testing.allocator;
    const nested = "x = f\"\"\"\nhead {g('''\nz''')} mid\nend\"\"\"\n";
    const nested_broken = "x = f\"\"\"\nhead {\n    g('''\nz''')\n} mid\nend\"\"\"\n";
    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    try expect_plain(
        &tuned,
        "x = f\"\"\"\nhead {a+b} mid\n{'-'*40}\nend\"\"\"\n",
        .double,
        "x = f\"\"\"\nhead {a + b} mid\n{\"-\" * 40}\nend\"\"\"\n",
    );

    try expect_plain(
        &tuned,
        "x = rf\"\"\"\n{'-'*40}\\d\nend\"\"\"\n",
        .double,
        "x = rf\"\"\"\n{\"-\" * 40}\\d\nend\"\"\"\n",
    );

    try expect_plain(&tuned, nested, .double, nested_broken);
}

test "a value that is one bracket pair never takes the optional pair" {
    const gpa = std.testing.allocator;
    const commented = "  # added to allow handlers to be removed in reverse of order initialized\n";
    const values = [_][]const u8{ "[]", "()", "{}", "not []", "-[]", "([])" };
    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    for (values) |value| {
        var source_buffer: [path_bytes_max]u8 = undefined;
        var wanted_buffer: [path_bytes_max]u8 = undefined;

        const source = try std.mem.print(&source_buffer, "_handlerList = {s}{s}", .{
            value,
            commented,
        });

        const size = std.mem.replacementSize(u8, source, "([])", "[]");

        _ = std.mem.replace(u8, source, "([])", "[]", &wanted_buffer);

        try expect_plain(&tuned, source, .double, wanted_buffer[0..size]);
    }

    try expect_plain(
        &tuned,
        "_handlerList = [] + x" ++ commented,
        .double,
        "_handlerList = (\n    [] + x\n)" ++ commented,
    );

    try expect_plain(
        &tuned,
        "_handlerList = call()" ++ commented,
        .double,
        "_handlerList = (\n    call()\n)" ++ commented,
    );
}

test "a bare tuple value wider than the line takes the pair one element to a line" {
    const gpa = std.testing.allocator;
    const wide = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbb";
    const narrow = "self._connection = host, HTTPSConnection(a)\n";
    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    try expect_plain(
        &tuned,
        "self._connection = host, HTTPSConnection(" ++ wide ++ ")\n",
        .double,
        "self._connection = (\n    host,\n    HTTPSConnection(" ++ wide ++ "),\n)\n",
    );

    try expect_plain(&tuned, narrow, .double, narrow);

    try expect_plain(
        &tuned,
        "p = q = host, HTTPSConnection(" ++ wide ++ ")\n",
        .double,
        "p = q = (\n    host,\n    HTTPSConnection(" ++ wide ++ "),\n)\n",
    );
}

test "a comment run trailing an import keeps the gap the source gave it" {
    const gpa = std.testing.allocator;
    const run = "from a import b\n# one\n# two\n\nx = 1\n";
    const split = "from a import b\n# one\n\n# two\nx = 1\n";
    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    try expect_plain(&tuned, run, .double, run);

    try expect_plain(
        &tuned,
        "from a import b\n# remark\nx = 1\n",
        .double,
        "from a import b\n\n# remark\nx = 1\n",
    );

    try expect_plain(&tuned, split, .double, split);
}

test "a statement a redundant semicolon ends owes the next one no blank" {
    const gpa = std.testing.allocator;
    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    try expect_plain(&tuned, "x = 1;\n\ny = 2\n", .double, "x = 1\ny = 2\n");
    try expect_plain(&tuned, "x = 1; y = 2;\n\nz = 3\n", .double, "x = 1\ny = 2\nz = 3\n");

    try expect_plain(
        &tuned,
        "def g():\n    x = 1;\n\n    y = 2\n",
        .double,
        "def g():\n    x = 1\n    y = 2\n",
    );

    try expect_plain(
        &tuned,
        "x = 1;\n\ndef f():\n    pass\n",
        .double,
        "x = 1\n\n\ndef f():\n    pass\n",
    );

    try expect_plain(&tuned, "from a import b;\n\nx = 1\n", .double, "from a import b\n\nx = 1\n");
}

test "a stub body reads through the semicolon that ends it" {
    const gpa = std.testing.allocator;
    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    try expect_plain(&tuned, "def f(): ...;\nx = 1\n", .double, "def f(): ...\n\n\nx = 1\n");

    try expect_plain(
        &tuned,
        "def f():\n    ...;\nx = 1\n",
        .double,
        "def f(): ...\n\n\nx = 1\n",
    );

    try expect_plain(
        &tuned,
        "def f(): ...;  # r\nx = 1\n",
        .double,
        "def f(): ...  # r\n\n\nx = 1\n",
    );

    try expect_plain(
        &tuned,
        "def f(): ...; x = 1\n",
        .double,
        "def f():\n    ...\n    x = 1\n",
    );
}

test "a bare tuple statement takes the pair the source left off" {
    const gpa = std.testing.allocator;
    const wide = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const deleted = "del " ++ wide ++ ", bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb, ccccccccccccccccc\n";

    const listed = "del (\n    " ++ wide ++ ",\n    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,\n" ++
        "    ccccccccccccccccc,\n)\n";

    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    try expect_plain(&tuned, "call(a),\n", .double, "(call(a),)\n");
    try expect_plain(&tuned, "call(a), other\n", .double, "call(a), other\n");

    try expect_plain(
        &tuned,
        "call(" ++ wide ++ "), other_" ++ wide ++ "\n",
        .double,
        "(\n    call(" ++ wide ++ "),\n    other_" ++ wide ++ ",\n)\n",
    );

    try expect_plain(&tuned, deleted, .double, listed);
    try expect_plain(&tuned, listed, .double, listed);
}

test "a multiline string an operator follows takes the pair around it" {
    const gpa = std.testing.allocator;
    const alone = "x = \"\"\"\nabc\"\"\"\n";
    const tupled = "x = \"\"\"\nabc\"\"\" % (a, b)\n";
    const called = "x = \"\"\"\nabc\"\"\".strip()\n";
    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    try expect_plain(&tuned, alone, .double, alone);

    try expect_plain(
        &tuned,
        "x = \"\"\"\nabc\"\"\" % name\n",
        .double,
        "x = (\n    \"\"\"\nabc\"\"\"\n    % name\n)\n",
    );

    try expect_plain(
        &tuned,
        "x = name + \"\"\"\nabc\"\"\"\n",
        .double,
        "x = (\n    name\n    + \"\"\"\nabc\"\"\"\n)\n",
    );

    try expect_plain(&tuned, tupled, .double, tupled);
    try expect_plain(&tuned, called, .double, called);
}

test "a format string joined onto a plain one measures at its joined width" {
    const gpa = std.testing.allocator;

    const source = "class C:\n" ++
        "    _make.__func__.__doc__ = (f'Make a new {typename} object from a" ++
        " sequence '\n                              'or iterable')\n";

    const wanted = "class C:\n" ++
        "    _make.__func__.__doc__ = f\"Make a new {typename} object from a" ++
        " sequence or iterable\"\n";

    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    try expect_plain(&tuned, source, .double, wanted);
}

test "a triple quoted format string keeps a quote that ends one of its parts" {
    const gpa = std.testing.allocator;
    const quoted = "script = f'''\n   tell application \"{name}\"\n   '''\n";
    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    try expect_plain(&tuned, quoted, .double, quoted);

    try expect_plain(
        &tuned,
        "script = f'''\n   tell application\n   '''\n",
        .double,
        "script = f\"\"\"\n   tell application\n   \"\"\"\n",
    );

    try expect_plain(
        &tuned,
        "script = f'''\n   tell \"x\" here {name}\n   '''\n",
        .double,
        "script = f\"\"\"\n   tell \"x\" here {name}\n   \"\"\"\n",
    );

    try expect_plain(
        &tuned,
        "script = f'''\n   tell {d[\"k\"]} here\n   '''\n",
        .double,
        "script = f\"\"\"\n   tell {d[\"k\"]} here\n   \"\"\"\n",
    );

    try expect_plain(
        &tuned,
        "script = '''\n   tell application \"x\"\n   '''\n",
        .double,
        "script = \"\"\"\n   tell application \"x\"\n   \"\"\"\n",
    );
}

test "a one element tuple in a replacement field takes the pair" {
    const gpa = std.testing.allocator;
    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    try expect_plain(&tuned, "x = f\"{a,}\"\n", .double, "x = f\"{(a,)}\"\n");
    try expect_plain(&tuned, "x = f\"{a,:>10}\"\n", .double, "x = f\"{(a,):>10}\"\n");
    try expect_plain(&tuned, "x = f\"{a,!r}\"\n", .double, "x = f\"{(a,)!r}\"\n");
    try expect_plain(&tuned, "x = f\"{a, b}\"\n", .double, "x = f\"{a, b}\"\n");
    try expect_plain(&tuned, "x = f\"{d[a, b]}\"\n", .double, "x = f\"{d[a, b]}\"\n");
    try expect_plain(&tuned, "x = f\"{a,=}\"\n", .double, "x = f\"{a,=}\"\n");
}

test "an operator ahead of a concatenation keeps the line the first part opens" {
    const gpa = std.testing.allocator;

    const source = "f(\n    g(\"Manual porting required\") + \"\\n\"\n" ++
        "    \"  Your migrations contained functions that must be manually \"\n" ++
        "    \"copied over.\"\n)\n";

    const tailed = "raise E(\n" ++
        "    \"  * At least one of the expected database tables is missing.\\n\"\n" ++
        "    \"Hint: Look at the output of 'django-admin sqlflush'. \"\n" ++
        "    \"That's the SQL this command wasn't able to run.\"\n" ++
        "    % (connection.settings_dict[\"NAME\"],)\n)\n";

    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    try expect_plain(&tuned, source, .double, source);
    try expect_plain(&tuned, tailed, .double, tailed);
}

test "a format string part records the element level a plain one records" {
    const gpa = std.testing.allocator;

    const source = "f(\n    f\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\n\"\n" ++
        "    f\"  See the comment at the top of the squashed migration for details.\\n\"\n" ++
        "    + black_warning,\n)\n";

    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    try expect_plain(&tuned, source, .double, source);

    try expect_plain(
        &tuned,
        "f(\n    f\"aaa\"\n    f\"bbb\"\n    + w,\n)\n",
        .double,
        "f(\n    f\"aaabbb\" + w,\n)\n",
    );
}

test "a wrap head inside a bracket measures from the element it stands in" {
    const gpa = std.testing.allocator;

    const source = "d = {\n    \"__hash__\": default_hash,\n" ++
        "    \"__str__\": lambda self: f\"{type(self).__name__}\",\n" ++
        "    \"__fspath__\": lambda self: f\"{type(self).__name__}" ++
        "/{self._extract_mock_name()}/{id(self)}\",\n}\n";

    const wanted = "d = {\n    \"__hash__\": default_hash,\n" ++
        "    \"__str__\": lambda self: f\"{type(self).__name__}\",\n" ++
        "    \"__fspath__\": lambda self: (\n        f\"{type(self).__name__}" ++
        "/{self._extract_mock_name()}/{id(self)}\"\n    ),\n}\n";

    const called = "item = make_objecttreeitem(\n    str(key) + \" =\",\n    value,\n" ++
        "    lambda value, key=key, object_=self.object: setattr(object_, key, value),\n)\n";

    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    try expect_plain(&tuned, source, .double, wanted);
    try expect_plain(&tuned, called, .double, called);
}

test "a lambda body ends where the comprehension clause after it opens" {
    const gpa = std.testing.allocator;

    const source = "g = f(\n    (\n" ++
        "        lambda addrinfo=addrinfo: self._connect_sock(exceptions," ++
        " addrinfo, laddr_infos)\n        for addrinfo in infos\n    ),\n    delay,\n)\n";

    const awaited = "async def q():\n    g = (\n        self._connect_sock(\n" ++
        "            exceptions, addrinfo, laddr_infos, aaaaaaaaaaaaaaaaaaaaaaaaaaaa\n" ++
        "        )\n        async for addrinfo in infos\n    )\n";

    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    try expect_plain(&tuned, source, .double, source);
    try expect_plain(&tuned, awaited, .double, awaited);
}

test "a doubled pair of grouping parentheses collapses to one" {
    const gpa = std.testing.allocator;
    const quoted = "def f():\n    return \"%s=%s\" % ((quote(k, safe), quote(v, safe)))\n";
    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    try expect_plain(
        &tuned,
        "def f():\n    if (a) or ((b)):\n        return\n",
        .double,
        "def f():\n    if (a) or (b):\n        return\n",
    );

    try expect_plain(&tuned, "x = (((a)))\n", .double, "x = a\n");
    try expect_plain(&tuned, "f((a))\n", .double, "f((a))\n");
    try expect_plain(&tuned, quoted, .double, quoted);
}

test "a concatenation the head cannot hold parts from its operator" {
    const gpa = std.testing.allocator;

    const held = "def f():\n    self.assertTrue(\n        template_name in template_names,\n" ++
        "        msg_prefix + \"Template '%s' was not a template used to render\"\n" ++
        "        \" the response. Actual template(s) used: %s\"\n" ++
        "        % (template_name, \", \".join(template_names)),\n    )\n";

    const parted = "x = Label(\n    self.frame,\n" ++
        "    text=\"Key bindings are specified using Tkinter keysyms as\\n\"\n" ++
        "    + \"in these samples: <Control-f>, <Shift-F2>, <F12>,\\n\"\n" ++
        "    \"<Control-space>, <Meta-less>, <Control-Alt-Shift-X>.\\n\",\n)\n";

    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    try expect_plain(&tuned, held, .double, held);
    try expect_plain(&tuned, parted, .double, parted);
}

test "a return annotation drops the pair the source wrapped it in" {
    const gpa = std.testing.allocator;

    const source = "def iter_attrs() -> (\n" ++
        "    Iterable[Tuple[str, Any, Optional[Callable[[Any], str]]," ++
        " Held, Moreeee]]\n):\n    pass\n";

    const wanted = "def iter_attrs() -> Iterable[\n" ++
        "    Tuple[str, Any, Optional[Callable[[Any], str]]," ++
        " Held, Moreeee]\n]:\n    pass\n";

    const commented = "def f() -> (  # r\n    int\n):\n    pass\n";
    const parameters = "def f(\n    a,\n    b,\n):\n    pass\n";
    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    try expect_plain(&tuned, source, .double, wanted);

    try expect_plain(
        &tuned,
        "def f() -> (int):\n    pass\n",
        .double,
        "def f() -> int:\n    pass\n",
    );

    try expect_plain(&tuned, commented, .double, commented);
    try expect_plain(&tuned, parameters, .double, parameters);
}

test "only a definition head owes the magic comma its line opens with" {
    const gpa = std.testing.allocator;

    const chained = "async def q():\n    async for s in SimpleModel.objects.prefetch_related(\n" ++
        "        Prefetch(\"relatedmodel_set\", to_attr=\"prefetched_relatedmodel\")\n" ++
        "    ).aiterator(chunk_size=2000):\n        pass\n";

    const parameters = "async def q(\n    a,\n    b,\n):\n    pass\n";
    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    try expect_plain(&tuned, chained, .double, chained);
    try expect_plain(&tuned, parameters, .double, parameters);
}

test "a parted list owes its separator ahead of an own line comment" {
    const gpa = std.testing.allocator;
    const listed = "__all__ = [\n    \"walk\",\n    # Do not include _structure().\n]\n";
    const lone = "x = [\n    a\n    # remark\n]\n";
    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    try expect_plain(
        &tuned,
        "f(\n    a,\n    b\n    # remark\n)\n",
        .double,
        "f(\n    a,\n    b,\n    # remark\n)\n",
    );

    try expect_plain(
        &tuned,
        "f(\n    a,\n    b\n    # one\n    # two\n)\n",
        .double,
        "f(\n    a,\n    b,\n    # one\n    # two\n)\n",
    );

    try expect_plain(&tuned, listed, .double, listed);
    try expect_plain(&tuned, lone, .double, lone);
}

test "an operator after a concatenation keeps the comment that rides it" {
    const gpa = std.testing.allocator;

    const held = "f(\n    r\"(^[ \\t]*)\"  # at beginning\n" ++
        "    r\"(?![ \\t]*(?:\" +  # not followed by\n    # pattern matching\n" ++
        "    r\"|\".join(k for k in kw) + r\")\\b))\",\n    other,\n)\n";

    const wanted = "f(\n    r\"(^[ \\t]*)\"  # at beginning\n" ++
        "    r\"(?![ \\t]*(?:\" +  # not followed by\n    # pattern matching\n" ++
        "    r\"|\".join(k for k in kw)\n    + r\")\\b))\",\n    other,\n)\n";

    const lone = "x = (\n    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa +  # remark\n" ++
        "    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n)\n";

    const parted = "x = (\n    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  # remark\n" ++
        "    + bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n)\n";

    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    try expect_plain(&tuned, held, .double, wanted);
    try expect_plain(&tuned, lone, .double, parted);
}

test "a binary value leading with a spanning string omits the pair alone" {
    const gpa = std.testing.allocator;

    const paired = "def f():\n    if p:\n        result = result + \"\"\"\n<tr><td>%s</td>\"\"\"" ++
        " % (cls, marginalia, gap)\n";

    const wanted = "def f():\n    if p:\n        result = (\n            result\n" ++
        "            + \"\"\"\n<tr><td>%s</td>\"\"\"\n            % (cls, marginalia, gap)\n" ++
        "        )\n";

    const bare = "def f():\n    if p:\n        result = \"\"\"\n<tr><td>%s</td>\"\"\"" ++
        " % (cls, marginalia, gap)\n";

    const nested = "def f():\n    if p:\n        result = result + self.section(\n" ++
        "            \"MODULE REFERENCE\",\n            docloc\n            + \"\"\"\n\n" ++
        "The following documentation is generated.\n\"\"\",\n        )\n";

    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    try expect_plain(&tuned, paired, .double, wanted);
    try expect_plain(&tuned, bare, .double, bare);
    try expect_plain(&tuned, nested, .double, nested);
}

test "a docstring holding an escaped newline keeps every line it was given" {
    const gpa = std.testing.allocator;
    const escaped = "def f():\n    \"\"\"head \\\n        rest.\n        tail.\n    \"\"\"\n";
    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    try expect_plain(&tuned, escaped, .double, escaped);

    try expect_plain(
        &tuned,
        "def f():\n    '''head.\n        mid \\\\\n        rest.   \n    '''\n",
        .double,
        "def f():\n    \"\"\"head.\n        mid \\\\\n        rest.   \n    \"\"\"\n",
    );

    try expect_plain(
        &tuned,
        "def f():\n    \"\"\"head.\n        mid \\t dle.\n        tail.\n    \"\"\"\n",
        .double,
        "def f():\n    \"\"\"head.\n    mid \\t dle.\n    tail.\n    \"\"\"\n",
    );
}

test "a single quoted docstring is requoted and reindented together" {
    const gpa = std.testing.allocator;
    const source = "def f():\n    '''doc\n        more\n      '''\n";
    const doubled = "def f():\n    \"\"\"doc\n    more\n    \"\"\"\n";
    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    try expect_plain(&tuned, source, .double, doubled);
    try expect_plain(&tuned, source, .single, doubled);
    try expect_plain(&tuned, source, .preserve, "def f():\n    '''doc\n    more\n    '''\n");
    try expect_plain(&tuned, "def f():\n    'doc'\n", .single, "def f():\n    \"doc\"\n");

    try expect_plain(
        &tuned,
        "def f():\n    '''say \"hi\"\n    x'''\n",
        .double,
        "def f():\n    \"\"\"say \"hi\"\n    x\"\"\"\n",
    );
}

test "a dot after an integer keeps the space that makes it an attribute" {
    const gpa = std.testing.allocator;
    const source = "x = 3 .real\ny = a . b\nz = (3).real\nw = 3.5.real\nv = 0x1 .real\n";
    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    const held = try tuned.formatted(source, .line_feed, true, .double);

    try std.testing.expectEqualStrings(
        "x = 3 .real\ny = a.b\nz = (3).real\nw = 3.5.real\nv = 0x1.real\n",
        held,
    );
}

test "a format off region is reproduced byte for byte" {
    const gpa = std.testing.allocator;
    const source = "# fmt: off\nmatrix = [\n    1,  0,\n    0,  1,\n]\n# fmt: on\nheld   =   1\n";
    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    const held = try tuned.formatted(source, .line_feed, true, .double);

    try std.testing.expectEqualStrings(
        "# fmt: off\nmatrix = [\n    1,  0,\n    0,  1,\n]\n# fmt: on\nheld = 1\n",
        held,
    );
}

test "a format skip statement is reproduced and the next one is not" {
    const gpa = std.testing.allocator;
    const source = "held   =   1  # fmt: skip\nother   =   2\n";
    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    const held = try tuned.formatted(source, .line_feed, true, .double);

    try std.testing.expectEqualStrings("held   =   1  # fmt: skip\nother = 2\n", held);
}

test "a range over the middle statement changes only that statement" {
    const gpa = std.testing.allocator;
    const source = "x = 1\ny   =   2\nz = 3\n";
    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    const ranged = tuned.ranged(source, .{ .offset = 8, .length = 1 }) orelse {
        return error.TestUnexpectedResult;
    };

    try std.testing.expectEqualStrings("y   =   2\n", ranged.span.text(source));
    try std.testing.expectEqualStrings("y = 2\n", ranged.text);
}

test "a range edit applied to the file matches ruff" {
    const gpa = std.testing.allocator;
    const bracketed: Span = .{ .offset = 4, .length = 1 };
    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    var buffer: [path_bytes_max]u8 = undefined;

    try std.testing.expectEqualStrings(
        "x=1\nprint(y)\nz=3\n",
        try applied(&tuned, &buffer, "x=1\nprint( y )\nz=3\n", bracketed),
    );

    try std.testing.expectEqualStrings(
        "x=1\nresult = call(a, b)\ny=2\n",
        try applied(&tuned, &buffer, "x=1\nresult = call(\n    a, b\n)\ny=2\n", .{
            .offset = 20,
            .length = 1,
        }),
    );

    try std.testing.expectEqualStrings(
        "x=1\n@dec\ndef f(a):\n    pass\ny=2\n",
        try applied(&tuned, &buffer, "x=1\n@dec\ndef f( a ):\n    pass\ny=2\n", .{
            .offset = 10,
            .length = 1,
        }),
    );

    try std.testing.expectEqualStrings(
        "x=1\nprint(y)  # note\nz=3\n",
        try applied(&tuned, &buffer, "x=1\nprint( y )  # note\nz=3\n", bracketed),
    );
}

test "a range over two statements covers both" {
    const gpa = std.testing.allocator;
    const source = "x   =   1\ny   =   2\nz = 3\n";
    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    const ranged = tuned.ranged(source, .{ .offset = 0, .length = 12 }) orelse {
        return error.TestUnexpectedResult;
    };

    try std.testing.expectEqualStrings("x   =   1\ny   =   2\n", ranged.span.text(source));
    try std.testing.expectEqualStrings("x = 1\ny = 2\n", ranged.text);
}

test "a range that meets no statement reports none" {
    const gpa = std.testing.allocator;
    const source = "x = 1\n";
    var tuned: Tuned = undefined;

    try tuned.init(gpa);
    defer tuned.deinit(gpa);

    try std.testing.expect(tuned.ranged(source, .{ .offset = 6, .length = 0 }) == null);
}

test "formatting keeps every word it was given" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, arena_bytes_max);
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

test "a statement drops the parentheses that only group its operand" {
    const source = "while (i > 0):\n    pass\nif (a and b):\n    pass\nelif (c):\n    pass\n" ++
        "assert (x), (y)\nfor (i, row) in (held):\n    pass\n";

    const wanted = "while i > 0:\n    pass\nif a and b:\n    pass\nelif c:\n    pass\n" ++
        "assert x, y\nfor i, row in held:\n    pass\n";

    try expect_held(source, wanted);
}

test "a pair the grammar wants is kept" {
    const source = "u = (v := 10)\n\n\ndef f():\n    return (a, b)\n    return (a,)\n" ++
        "    return ()\n    return (x for x in y)\n    return (a)[0]\n";

    try expect_held(source, source);
}

test "a pair the line needs back is kept" {
    const gpa = std.testing.allocator;

    const source = "def f():\n" ++
        "    if (aaaaaaaaaaaaaaaaaaaaaaaaa and bbbbbbbbbbbbbbbbbbbbbbbbbbbb and " ++
        "cccccccccccccccccccccc):\n        pass\n";

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, arena_bytes_max);
    defer out.deinit(gpa);

    try held.format(source, &out);
    try require(lines_fit(out.const_slice(), line_width_max), "{s}", .{out.const_slice()});
}

test "a format field leaves the literal a value the parentheses may hold" {
    const source = "def f(context, name):\n" ++
        "    context[\"widget\"][\"attrs\"][\"aria-describedby\"] = " ++
        "f\"plain_{name}_value_that_is_long12\"\n";

    const wanted = "def f(context, name):\n" ++
        "    context[\"widget\"][\"attrs\"][\"aria-describedby\"] = (\n" ++
        "        f\"plain_{name}_value_that_is_long12\"\n    )\n";

    try expect_held(source, wanted);
}

test "a bare tuple takes the parentheses the reference writes around it" {
    const source = "__all__ = \"BaseProactorEventLoop\",\na = 1, 2\nb = 1,\nd = \"x\", \"y\",\n" ++
        "\n\ndef g():\n    return 1,\n\n\ndef h():\n    return bytes([1, 2, 3, 4]),\n";

    const wanted = "__all__ = (\"BaseProactorEventLoop\",)\na = 1, 2\nb = (1,)\nd = (\n" ++
        "    \"x\",\n    \"y\",\n)\n\n\ndef g():\n    return (1,)\n\n\ndef h():\n" ++
        "    return (bytes([1, 2, 3, 4]),)\n";

    try expect_held(source, wanted);
}

test "a value takes the parentheses the reference writes where no bracket parts it" {
    const source = "def f():\n" ++
        "    aaaaaaaaaaaaaaaaaaa = salted_hmac(key_salt, self.password, secret=secret, " ++
        "alg=\"x\").hex()\n" ++
        "    ccccccccccccccccccc = salted_hmac(key_salt, self.password, " ++
        "sec=secret).hexdigest().upper()\n" ++
        "    ddddddddddddddddddd = " ++
        "alpha.beta.gamma.delta.epsilon.zeta.eta.theta.iota.kappa.lambdaa.mu\n" ++
        "    ggggggggggggggggggg = await " ++
        "cls.get_model_class().objects.filter(expire=now()).adelete_now()\n" ++
        "    frame_no_here = ((time - self.start_time) * self.speed) / (self.interval / 1000.0) " ++
        "+ off\n" ++
        "    response_ab_c = await sync_to_async(response.render, " ++
        "thread_sensitive=True_value_xyz)()\n" ++
        "    hhhhhhhhhhhhhhhhhhh = some_dictionary_name[\"a key that is long\"][\"another key " ++
        "here\"][\"m\"]\n";

    const wanted = "def f():\n    aaaaaaaaaaaaaaaaaaa = salted_hmac(\n" ++
        "        key_salt, self.password, secret=secret, alg=\"x\"\n    ).hex()\n" ++
        "    ccccccccccccccccccc = (\n" ++
        "        salted_hmac(key_salt, self.password, sec=secret).hexdigest().upper()\n    )\n" ++
        "    ddddddddddddddddddd = (\n" ++
        "        alpha.beta.gamma.delta.epsilon.zeta.eta.theta.iota.kappa.lambdaa.mu\n    )\n" ++
        "    ggggggggggggggggggg = (\n" ++
        "        await cls.get_model_class().objects.filter(expire=now()).adelete_now()\n    )\n" ++
        "    frame_no_here = ((time - self.start_time) * self.speed) / (\n" ++
        "        self.interval / 1000.0\n    ) + off\n    response_ab_c = await sync_to_async(\n" ++
        "        response.render, thread_sensitive=True_value_xyz\n    )()\n" ++
        "    hhhhhhhhhhhhhhhhhhh = some_dictionary_name[\"a key that is long\"][\n" ++
        "        \"another key here\"\n    ][\"m\"]\n";

    try expect_held(source, wanted);
}

test "a header takes the parentheses its condition needs and closes them on the colon" {
    const source = "def f():\n" ++
        "    if caller_frame and not caller_frame.f_trace and caller_frame is not " ++
        "self.botframe_x:\n        pass\n" ++
        "    if " ++
        "some_object.attribute_one.attribute_two.attribute_three.attribute_four.attr_fivex:\n" ++
        "        pass\n" ++
        "    while some_dictionary[\"a key that is long\"][\"another key here\"][\"and one more " ++
        "key!!\"]:\n        pass\n" ++
        "    return long_call_name(argument_one, argument_two, argument_three_here), " ++
        "False_value_x\n";

    const wanted = "def f():\n    if (\n        caller_frame\n" ++
        "        and not caller_frame.f_trace\n        and caller_frame is not self.botframe_x\n" ++
        "    ):\n        pass\n" ++
        "    if " ++
        "some_object.attribute_one.attribute_two.attribute_three.attribute_four.attr_fivex:\n" ++
        "        pass\n" ++
        "    while some_dictionary[\"a key that is long\"][\"another key here\"][\n" ++
        "        \"and one more key!!\"\n    ]:\n        pass\n    return long_call_name(\n" ++
        "        argument_one, argument_two, argument_three_here\n    ), False_value_x\n";

    try expect_held(source, wanted);
}

test "a word that opens a statement takes the pair its own operand needs" {
    const source = "async def f():\n" ++
        "    assert " ++
        "some_object.attribute_one.attribute_two.attribute_three.attribute_four.attrxyz\n" ++
        "    assert some_object.attribute_one.attribute_two.attribute_three.attrxy, \"a message " ++
        "ok!\"\n" ++
        "    await " ++
        "some_object.attribute_one.attribute_two.attribute_three.attribute_four.attribxyz\n" ++
        "    with " ++
        "some_object.attribute_one.attribute_two.attribute_three.attribute_four.attribxyz:\n" ++
        "        pass\n" ++
        "    with GzipFile(filename=filename, mode=\"wb\", compresslevel=6, fileobj=buf) as " ++
        "zfile_ab:\n        pass\n";

    const wanted = "async def f():\n    assert (\n" ++
        "        " ++
        "some_object.attribute_one.attribute_two.attribute_three.attribute_four.attrxyz\n    )\n" ++
        "    assert some_object.attribute_one.attribute_two.attribute_three.attrxy, (\n" ++
        "        \"a message ok!\"\n    )\n    await (\n" ++
        "        " ++
        "some_object.attribute_one.attribute_two.attribute_three.attribute_four.attribxyz\n" ++
        "    )\n    with (\n" ++
        "        " ++
        "some_object.attribute_one.attribute_two.attribute_three.attribute_four.attribxyz\n" ++
        "    ):\n        pass\n    with GzipFile(\n" ++
        "        filename=filename, mode=\"wb\", compresslevel=6, fileobj=buf\n" ++
        "    ) as zfile_ab:\n        pass\n";

    try expect_held(source, wanted);
}

test "a docstring a comment stands above owes the comment below it a cap" {
    const source = "#!/bin/sh\n\"\"\"Doc.\"\"\"\n# a remark\n\n\nimport os\n";
    const wanted = "#!/bin/sh\n\"\"\"Doc.\"\"\"\n# a remark\n\nimport os\n";

    try expect_held(source, wanted);
}

test "a join takes the quote that spells its parts with the fewest backslashes" {
    const source = "def f(self, bits):\n" ++
        "    a = '\"count\" in %r tag expected exactly ' \"one keyword argument.\"\n" ++
        "    b = \"No handlers could be found for logger\" \" \\\"%s\\\"\\n\" % self.name\n" ++
        "    c = \"plain part one \" \"and plain part two\"\n";

    const wanted = "def f(self, bits):\n" ++
        "    a = '\"count\" in %r tag expected exactly one keyword argument.'\n" ++
        "    b = 'No handlers could be found for logger \"%s\"\\n' % self.name\n" ++
        "    c = \"plain part one and plain part two\"\n";

    try expect_held(source, wanted);
}

test "a format field is written with the spacing the expression it holds takes" {
    const source = "def f(a, b, ip_str, x, width, items):\n    p = f\"{a+1}\"\n" ++
        "    q = f\"{f(a,b)}\"\n" ++
        "    r = f\"{ip_str[:45]}({len(ip_str)-90} chars elided){ip_str[-45:]}\"\n" ++
        "    s = f\"{-a}\"\n    t = f\"{not a}\"\n    v = f\"{f(a=1,b=2)}\"\n    w = f\"{x=}\"\n" ++
        "    y = f\"{x!r}\"\n    z = f\"{x:{width}}\"\n    aa = f\"{a.b.c(d)[e]}\"\n" ++
        "    ac = f\"{ {'k': 1} }\"\n    ad = f\"{a**2}\"\n    ah = f\"{(lambda q: q+1)}\"\n" ++
        "    ai = f'{a<b and c>=d}'\n";

    const wanted = "def f(a, b, ip_str, x, width, items):\n    p = f\"{a + 1}\"\n" ++
        "    q = f\"{f(a, b)}\"\n" ++
        "    r = f\"{ip_str[:45]}({len(ip_str) - 90} chars elided){ip_str[-45:]}\"\n" ++
        "    s = f\"{-a}\"\n    t = f\"{not a}\"\n    v = f\"{f(a=1, b=2)}\"\n" ++
        "    w = f\"{x=}\"\n    y = f\"{x!r}\"\n    z = f\"{x:{width}}\"\n" ++
        "    aa = f\"{a.b.c(d)[e]}\"\n    ac = f\"{ {'k': 1} }\"\n    ad = f\"{a**2}\"\n" ++
        "    ah = f\"{(lambda q: q + 1)}\"\n    ai = f\"{a < b and c >= d}\"\n";

    try expect_held(source, wanted);
}

test "a join is measured with the separator the group holding it owes" {
    const source = "held = {\n    \"key\": {\n" ++
        "        \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"\n" ++
        "        \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\n    },\n}\n";

    const wanted = "held = {\n    \"key\": {\n" ++
        "        " ++
        "\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\n" ++
        "    },\n}\n";

    try expect_held(source, wanted);
}

test "a join the separator takes past the width parts where it stands" {
    const source = "held = {\n    \"key\": {\n" ++
        "        \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"\n" ++
        "        \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\n    },\n}\n";

    try expect_held(source, source);
}

test "a comment under a module docstring keeps the one line it owes" {
    const source = "\"\"\"Doc.\"\"\"\n\n# note\n\n\nimport sys\n";
    const wanted = "\"\"\"Doc.\"\"\"\n\n# note\n\nimport sys\n";

    try expect_held(source, wanted);
}

test "a pair holding a product is no unpacking and goes" {
    const source = "def f():\n    return (a * b)\n";
    const wanted = "def f():\n    return a * b\n";

    try expect_held(source, wanted);
}

test "a comment past the statement keeps the pair it owes" {
    const source = "def g(new_args, field):\n    new_args[field] = (\n        \"X\" * 250\n" ++
        "    )  # a value that runs the line it stands on well past the width it answers to.\n";

    try expect_held(source, source);
}

test "a pair whose head fits goes and the bracket it holds parts" {
    const source = "def h():\n" ++
        "    cfile = (importlib.util.cache_from_source(fullname_value, " ++
        "optimization=option_value))\n";

    const wanted = "def h():\n" ++
        "    cfile = importlib.util.cache_from_source(fullname_value, " ++
        "optimization=option_value)\n";

    try expect_held(source, wanted);
}

test "a pair whose head runs past the width stays" {
    const source = "def i(task_backends):\n    if True:\n" ++
        "        task_backends._settings = task_backends.settings = (\n" ++
        "            task_backends.configure_settings(None)\n        )\n";

    try expect_held(source, source);
}

test "an import list takes the parentheses the width needs and no others" {
    const source = "from _csv import Error, writer, reader, register_dialect, " ++
        "unregister_dialect, get_dialect\nfrom x import (a, b)\n";

    const wanted = "from _csv import (\n    Error,\n    writer,\n    reader,\n" ++
        "    register_dialect,\n    unregister_dialect,\n    get_dialect,\n)\n" ++
        "from x import a, b\n";

    try expect_held(source, wanted);
}

test "an import list of one name takes the separator it parts with" {
    const source = "def f():\n    if True:\n        if True:\n            if True:\n" ++
        "                if True:\n                    if True:\n" ++
        "                        if True:\n                            if True:\n" ++
        "                                from pip._vendor.rich._win32_console import " ++
        "LegacyWindowsTerm\n";

    const wanted = "def f():\n    if True:\n        if True:\n            if True:\n" ++
        "                if True:\n                    if True:\n" ++
        "                        if True:\n                            if True:\n" ++
        "                                from pip._vendor.rich._win32_console import (\n" ++
        "                                    LegacyWindowsTerm,\n" ++
        "                                )\n";

    try expect_held(source, wanted);
}

test "a dict entrys break goes into the value the key leaves room for" {
    const source = "d = {\n" ++
        "    \"%s__pkXXX\" % self.content_type_field_name: " ++
        "ContentType.objects.db_manager(usingxxxx),\n" ++
        "    \"%s__inXX\" % GeoColumn.table_name_col(): [\"gis_neighborhoodxxx\", " ++
        "\"gis_householdxxxx\"],\n" ++
        "    \"_prefetch_related_val_%sXX\" % f.attnamex: \"%s.%s\" % (qn(join_table), " ++
        "qn(source_col)),\n" ++
        "    \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaXX\" % " ++
        "bbbbbbbbbbbbbbbbbbbbbbbbb: cc,\n" ++
        "    \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaXXX\" % bbbbbbbbbbbbbbbbbbbbbbbbb: " ++
        "ccccccccccccccccccccc,\n}\n";

    const wanted = "d = {\n" ++
        "    \"%s__pkXXX\" % self.content_type_field_name: ContentType.objects.db_manager(\n" ++
        "        usingxxxx\n    ),\n    \"%s__inXX\" % GeoColumn.table_name_col(): [\n" ++
        "        \"gis_neighborhoodxxx\",\n        \"gis_householdxxxx\",\n    ],\n" ++
        "    \"_prefetch_related_val_%sXX\" % f.attnamex: \"%s.%s\"\n" ++
        "    % (qn(join_table), qn(source_col)),\n" ++
        "    \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaXX\"\n" ++
        "    % bbbbbbbbbbbbbbbbbbbbbbbbb: cc,\n    \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaXXX\"\n" ++
        "    % bbbbbbbbbbbbbbbbbbbbbbbbb: ccccccccccccccccccccc,\n}\n";

    try expect_held(source, wanted);
}

test "a trailing comment run past a closed block takes the gap the source wrote" {
    const source = "if x:\n\n    def held():\n        return 1\n\nelse:\n\n    def held():\n" ++
        "        return 2\n\n#\n# a run the blank below detaches\n#\n\nclass S:\n    pass\n\n\n" ++
        "def other():\n    return 3\n\n# a run that leads the statement below\ny = 2\n";

    const wanted = "if x:\n\n    def held():\n        return 1\n\nelse:\n\n    def held():\n" ++
        "        return 2\n\n#\n# a run the blank below detaches\n#\n\n\nclass S:\n    pass\n\n" ++
        "\ndef other():\n    return 3\n\n\n# a run that leads the statement below\ny = 2\n";

    try expect_held(source, wanted);
}

test "an element a comment defers opens its groups at an f string too" {
    const source = "a = [\n    (x, y),\n    # a remark\n    f\"aaa\" if PYPY else \"0-0-0\",\n" ++
        "]\n";

    const wanted = "a = [\n    (x, y),\n    # a remark\n    f\"aaa\" if PYPY else \"0-0-0\",\n" ++
        "]\n";

    try expect_held(source, wanted);
}

test "a target list takes the pair the values own wrap leaves no room for" {
    const source = "class C:\n    def f(self, chunk):\n        try:\n" ++
        "            wFormatTag, self._nchannels, self._framerate, dwAvgBytesPerSec, " ++
        "wBlockAlign = struct.unpack_from(\"<HHLLH\", chunk.read(14))\n" ++
        "        except struct.error:\n            raise EOFError from None\n" ++
        "        wFormatTag, self._nchannels, wBlockAlign = struct.unpack_from(\"<HHLLH\", " ++
        "chunk)\n";

    const wanted = "class C:\n    def f(self, chunk):\n        try:\n            (\n" ++
        "                wFormatTag,\n                self._nchannels,\n" ++
        "                self._framerate,\n                dwAvgBytesPerSec,\n" ++
        "                wBlockAlign,\n" ++
        "            ) = struct.unpack_from(\"<HHLLH\", chunk.read(14))\n" ++
        "        except struct.error:\n            raise EOFError from None\n" ++
        "        wFormatTag, self._nchannels, wBlockAlign = struct.unpack_from(\"<HHLLH\", " ++
        "chunk)\n";

    try expect_held(source, wanted);
}

test "a unary prefixs power operand takes the parentheses" {
    const source = "a = -2**31\nb = ~a ** 2\nc = -256 ** (digits - 1)\nd = -(-1) ** self._sign\n" ++
        "e = 2**31\nf = a**-b\ng = -2**31 + 1\nh = not a**2\n";

    const wanted = "a = -(2**31)\nb = ~(a**2)\nc = -(256 ** (digits - 1))\n" ++
        "d = -((-1) ** self._sign)\ne = 2**31\nf = a**-b\ng = -(2**31) + 1\nh = not (a**2)\n";

    try expect_held(source, wanted);
}

test "a targets last bracket parts where the values own head runs past the width" {
    const source = "obj.fields[\"groups\"].help_text = \"These groups give the users the " ++
        "different rights they hold\"\n" ++
        "obj.fieldsandmore[\"groups\"] = \"These groups give the users the different rights " ++
        "they hold\"\n" ++
        "obj.fields[\"action\"].choices = " ++
        "self.get_the_action_choices_for_this_given_location(request)\n" ++
        "obj.fields[\"action\"].choices = " ++
        "self.get_the_action_choices_for_this_given_location_and_more(request)\n";

    const wanted = "obj.fields[\n    \"groups\"\n" ++
        "].help_text = \"These groups give the users the different rights they hold\"\n" ++
        "obj.fieldsandmore[\"groups\"] = (\n" ++
        "    \"These groups give the users the different rights they hold\"\n)\n" ++
        "obj.fields[\"action\"].choices = self.get_the_action_choices_for_this_given_location(\n" ++
        "    request\n)\nobj.fields[\n    \"action\"\n" ++
        "].choices = self.get_the_action_choices_for_this_given_location_and_more(request)\n";

    try expect_held(source, wanted);
}

test "a chains pair stands at the last target whose own head fits" {
    const source = "self.hideid = self.keypressid = self.listupdateid = self.winconfigid = " ++
        "self.keyreleaseid = self.doubleclickid = None\n" ++
        "real_test_settings[\"USER\"] = real_settings[\"USER\"] = test_settings[\"USER\"] = (\n" ++
        "    self.connection.settings_dict[\"USER\"]\n) = parameters[\"user\"]\n";

    const wanted = "self.hideid = self.keypressid = self.listupdateid = self.winconfigid = (\n" ++
        "    self.keyreleaseid\n) = self.doubleclickid = None\n" ++
        "real_test_settings[\"USER\"] = real_settings[\"USER\"] = test_settings[\n    \"USER\"\n" ++
        "] = self.connection.settings_dict[\"USER\"] = parameters[\"user\"]\n";

    try expect_held(source, wanted);
}

test "a wrapped tuple breaks each element only when the element does not fit" {
    const source = "if x:\n" ++
        "    aaaa_aaaa_aaaa_aaaa_aaaa, bbbb_bbbb_bbbb_bbbb_bbbb = xxxxxxxxxxxxxxxxxx + ptr_fi" ++
        "eld.byte_offset, xxxxxxxxxxxxxxxxxx + len_field.byte_offset\n";

    const wanted = "if x:\n" ++
        "    aaaa_aaaa_aaaa_aaaa_aaaa, bbbb_bbbb_bbbb_bbbb_bbbb = (\n" ++
        "        xxxxxxxxxxxxxxxxxx + ptr_field.byte_offset,\n" ++
        "        xxxxxxxxxxxxxxxxxx + len_field.byte_offset,\n" ++
        "    )\n";

    try expect_held(source, wanted);
    try expect_held(wanted, wanted);
}

test "a comparison closing on a multiline string keeps the pair it breaks in" {
    const cmp1_source = "assert (result == \"\"\"a\nb\"\"\")\n";
    const cmp1_wanted = "assert (\n    result\n    == \"\"\"a\nb\"\"\"\n)\n";
    const cmp2_source = "x = (f(result) == \"\"\"a\nb\"\"\")\n";
    const cmp2_wanted = "x = (\n    f(result)\n    == \"\"\"a\nb\"\"\"\n)\n";

    try expect_held(cmp1_source, cmp1_wanted);
    try expect_held(cmp1_wanted, cmp1_wanted);
    try expect_held(cmp2_source, cmp2_wanted);
    try expect_held(cmp2_wanted, cmp2_wanted);
}

test "a prefix on a multiline string takes no pair" {
    const pre1_source = "assert not \"\"\"a\nb\"\"\"\n";
    const pre2_source = "assert (not \"\"\"a\nb\"\"\")\n";
    const pre2_wanted = "assert not \"\"\"a\nb\"\"\"\n";
    const pre3_source = "x = ~\"\"\"a\nb\"\"\"\n";

    try expect_held(pre1_source, pre1_source);
    try expect_held(pre2_source, pre2_wanted);
    try expect_held(pre3_source, pre3_source);
}

test "a multiline string leads its operator only where ruff lets it" {
    const lead1_source = "x = \"\"\"a\nb\"\"\" and f(x)\n";
    const lead1_wanted = "x = (\n    \"\"\"a\nb\"\"\"\n    and f(x)\n)\n";
    const lead2_source = "x = \"\"\"a\nb\"\"\" == f(x) == g(y)\n";
    const lead3_source = "x = \"\"\"a\nb\"\"\".format(a) + f(x)\n";
    const lead3_wanted = "x = (\n    \"\"\"a\nb\"\"\".format(a)\n    + f(x)\n)\n";
    const lead4_source = "x = not \"\"\"a\nb\"\"\" == f(x)\n";
    const lead5_source = "x = \"\"\"a\nb\"\"\" ** 2\n";
    const lead5_wanted = "x = (\n    \"\"\"a\nb\"\"\"\n    ** 2\n)\n";

    try expect_held(lead1_source, lead1_wanted);
    try expect_held(lead2_source, lead2_source);
    try expect_held(lead3_source, lead3_wanted);
    try expect_held(lead4_source, lead4_source);
    try expect_held(lead5_source, lead5_wanted);
}

test "an arithmetic expression statement takes the pair its width needs" {
    const ar1_source = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >> bbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbbbbbbbbb\n";

    const ar1_wanted = "(\n" ++
        "    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n" ++
        "    >> bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n)\n";

    const ar2_source = "x = 1\na + b\n";
    const ar3_source = "if x:\n    a + b\n";

    const ar4_source = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa * bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbbbbbbbb\n";

    try expect_held(ar1_source, ar1_wanted);
    try expect_held(ar2_source, ar2_source);
    try expect_held(ar3_source, ar3_source);
    try expect_held(ar4_source, ar4_source);
}

test "a lambda body that spans lines keeps the pairs ruff gives it" {
    const lam1_source = "x = (lambda: \"\"\"a\nb\"\"\")\n";
    const lam1_wanted = "x = lambda: (\n    \"\"\"a\nb\"\"\"\n)\n";
    const lam2_source = "assert (lambda: \"\"\"a\nb\"\"\")\n";
    const lam2_wanted = "assert (\n    lambda: (\n        \"\"\"a\nb\"\"\"\n    )\n)\n";

    try expect_held(lam1_source, lam1_wanted);
    try expect_held(lam1_wanted, lam1_wanted);
    try expect_held(lam2_source, lam2_wanted);
    try expect_held(lam2_wanted, lam2_wanted);
}

test "a pair that leaves the head past the width is not taken" {
    const fit1_source = "xxxxxx = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb(c)\n";

    const fit1_wanted = "xxxxxx = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb(\n    c\n)\n";

    const fit2_source = "assert x, aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++
        "aaa.bbbbbbbbbbbbbbbbbbb(c)\n";

    const fit2_wanted = "assert x, (\n" ++
        "    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbb" ++
        "b(\n        c\n    )\n)\n";

    const fit3_source = "with aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.b" ++
        "bbbbbbbbbbbbbbbbbb(c) as f:\n    pass\n";

    const fit3_wanted = "with (\n" ++
        "    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbb" ++
        "b(\n        c\n    ) as f\n):\n    pass\n";

    try expect_held(fit1_source, fit1_wanted);
    try expect_held(fit2_source, fit2_wanted);
    try expect_held(fit2_wanted, fit2_wanted);
    try expect_held(fit3_source, fit3_wanted);
    try expect_held(fit3_wanted, fit3_wanted);
}

test "a comparison holding a multiline call keeps its pair" {
    const deep1_source = "assert f(\"\"\"a\nb\"\"\") == y\n";
    const deep1_wanted = "assert (\n    f(\"\"\"a\nb\"\"\")\n    == y\n)\n";

    try expect_held(deep1_source, deep1_wanted);
    try expect_held(deep1_wanted, deep1_wanted);
}

test "a broken power spaces its operator and splits inside a pair" {
    const pw1_source = "x = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ** bbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n";

    const pw1_wanted = "x = (\n" ++
        "    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n" ++
        "    ** bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n)\n";

    const pw2_source = "x = (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ** bbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)\n";

    const pw2_wanted = "x = (\n" ++
        "    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n" ++
        "    ** bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n)\n";

    const pw3_source = "x = (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.b(c).d ** bbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbbbbbbbbbbbbb)\n";

    const pw3_wanted = "x = (\n" ++
        "    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.b(c).d\n" ++
        "    ** bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n)\n";

    try expect_held(pw1_source, pw1_wanted);
    try expect_held(pw1_wanted, pw1_wanted);
    try expect_held(pw2_source, pw2_wanted);
    try expect_held(pw2_wanted, pw2_wanted);
    try expect_held(pw3_source, pw3_wanted);
    try expect_held(pw3_wanted, pw3_wanted);
}

test "a negated power breaks inside the parentheses it takes" {
    const ng1_source = "x = -aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbb ** 2\n";

    const ng1_wanted = "x = -(\n" ++
        "    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb**2" ++
        "\n)\n";

    const ng2_source = "x = not aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbbbbb ** 2\n";

    const ng2_wanted = "x = not (\n" ++
        "    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb**2" ++
        "\n)\n";

    try expect_held(ng1_source, ng1_wanted);
    try expect_held(ng1_wanted, ng1_wanted);
    try expect_held(ng2_source, ng2_wanted);
    try expect_held(ng2_wanted, ng2_wanted);
}

test "an operator whose right side opens with a comment stands alone" {
    const op1_source = "x = (\n    aaaa +  # comment\n    # leading\n    bbbb\n)\n";
    const op1_wanted = "x = (\n    aaaa  # comment\n    +\n    # leading\n    bbbb\n)\n";
    const op2_source = "x = (\n    aaaa +  # c1\n    # c2\n    # c3\n    bbbb\n)\n";
    const op2_wanted = "x = (\n    aaaa  # c1\n    +\n    # c2\n    # c3\n    bbbb\n)\n";
    const op3_source = "x = (\n    aaaa and  # comment\n    # leading\n    bbbb\n)\n";
    const op3_wanted = "x = (\n    aaaa  # comment\n    and\n    # leading\n    bbbb\n)\n";

    try expect_held(op1_source, op1_wanted);
    try expect_held(op1_wanted, op1_wanted);
    try expect_held(op2_source, op2_wanted);
    try expect_held(op2_wanted, op2_wanted);
    try expect_held(op3_source, op3_wanted);
    try expect_held(op3_wanted, op3_wanted);
}

test "a concatenation a comment interrupts keeps its parts" {
    const cc1_source = "x = (\n    \"a\" \"b\" +  # comment\n    # leading\n    bbbb + cccc\n)\n";

    const cc1_wanted = "x = (\n" ++
        "    \"a\"\n    \"b\" +  # comment\n    # leading\n    bbbb\n    + cccc\n)\n";

    const cc2_source = "x = (\n    \"a\" \"b\" +\n    # leading\n    bbbb\n)\n";
    const cc2_wanted = "x = (\n    \"a\"\n    \"b\" +\n    # leading\n    bbbb\n)\n";
    const cc3_source = "x = (\n    y + \"a\" \"b\"  # comment\n)\n";
    const cc3_wanted = "x = (\n    y + \"ab\"  # comment\n)\n";

    try expect_held(cc1_source, cc1_wanted);
    try expect_held(cc1_wanted, cc1_wanted);
    try expect_held(cc2_source, cc2_wanted);
    try expect_held(cc2_wanted, cc2_wanted);
    try expect_held(cc3_source, cc3_wanted);
    try expect_held(cc3_wanted, cc3_wanted);
}

test "a for target breaks first when its line runs past the width" {
    const ft_items_source = "def f():\n" ++
        "    if x:\n" ++
        "        for key, value in aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbb" ++
        "bbbbb.items():\n            pass\n";

    const ft_items_wanted = "def f():\n" ++
        "    if x:\n" ++
        "        for (\n" ++
        "            key,\n" ++
        "            value,\n" ++
        "        ) in aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbb.items()" ++
        ":\n            pass\n";

    const ft_sub_source = "def f():\n" ++
        "    if x:\n" ++
        "        for path in aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbb[cccccccccccccccc]:\n            pass\n";

    const ft_sub_wanted = "def f():\n" ++
        "    if x:\n" ++
        "        for (\n" ++
        "            path\n" ++
        "        ) in aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb[" ++
        "\n            cccccccccccccccc\n        ]:\n            pass\n";

    const ft_nested_source = "def f():\n" ++
        "    if x:\n" ++
        "        for (a, b), value in aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbb" ++
        "bbbbbbbb.items():\n            pass\n";

    const ft_nested_wanted = "def f():\n" ++
        "    if x:\n" ++
        "        for (\n" ++
        "            (a, b),\n" ++
        "            value,\n" ++
        "        ) in aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbb.items()" ++
        ":\n            pass\n";

    const ft_attr_source = "def f():\n" ++
        "    if x:\n" ++
        "        for key, value in aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbb" ++
        "bbbbbbbbbbbbbb:\n            pass\n";

    const ft_attr_wanted = "def f():\n" ++
        "    if x:\n" ++
        "        for (\n" ++
        "            key,\n" ++
        "            value,\n" ++
        "        ) in (\n" ++
        "            aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "\n        ):\n            pass\n";

    try expect_held(ft_items_source, ft_items_wanted);
    try expect_held(ft_items_wanted, ft_items_wanted);
    try expect_held(ft_sub_source, ft_sub_wanted);
    try expect_held(ft_sub_wanted, ft_sub_wanted);
    try expect_held(ft_nested_source, ft_nested_wanted);
    try expect_held(ft_nested_wanted, ft_nested_wanted);
    try expect_held(ft_attr_source, ft_attr_wanted);
    try expect_held(ft_attr_wanted, ft_attr_wanted);
}

test "a for target drops its parentheses unless it breaks" {
    const ft_paren_source = "def f():\n" ++
        "    if x:\n" ++
        "        for (key, value) in aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbb" ++
        "bbbbbbb.items():\n            pass\n";

    const ft_paren_wanted = "def f():\n" ++
        "    if x:\n" ++
        "        for (\n" ++
        "            key,\n" ++
        "            value,\n" ++
        "        ) in aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbb.items()" ++
        ":\n            pass\n";

    const ft_zip_source = "def f():\n" ++
        "    if x:\n" ++
        "        for (key, value) in zip(aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbb):\n            pass\n";

    const ft_zip_wanted = "def f():\n" ++
        "    if x:\n" ++
        "        for key, value in zip(\n" ++
        "            aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,\n" ++
        "            bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,\n        ):\n            pass\n";

    const ft_one_source = "def f():\n" ++
        "    if x:\n" ++
        "        for (key) in aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbb.items():\n            pass\n";

    const ft_one_wanted = "def f():\n" ++
        "    if x:\n" ++
        "        for key in aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "bbb.items():\n            pass\n";

    try expect_held(ft_paren_source, ft_paren_wanted);
    try expect_held(ft_paren_wanted, ft_paren_wanted);
    try expect_held(ft_zip_source, ft_zip_wanted);
    try expect_held(ft_zip_wanted, ft_zip_wanted);
    try expect_held(ft_one_source, ft_one_wanted);
    try expect_held(ft_one_wanted, ft_one_wanted);
}

test "a for iterable takes the pair only when the target cannot break" {
    const it_empty_source = "def f():\n" ++
        "    if x:\n" ++
        "        for x in aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbb" ++
        "bbbb():\n            pass\n";

    const it_empty_wanted = "def f():\n" ++
        "    if x:\n" ++
        "        for x in (\n" ++
        "            aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbb(" ++
        ")\n        ):\n            pass\n";

    const it_str_source = "def f():\n" ++
        "    if x:\n" ++
        "        for x in \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbb" ++
        "bbbbb\":\n            pass\n";

    const it_str_wanted = "def f():\n" ++
        "    if x:\n" ++
        "        for x in (\n" ++
        "            \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbb" ++
        "\"\n        ):\n            pass\n";

    try expect_held(it_empty_source, it_empty_wanted);
    try expect_held(it_empty_wanted, it_empty_wanted);
    try expect_held(it_str_source, it_str_wanted);
    try expect_held(it_str_wanted, it_str_wanted);
}

test "a bare return annotation takes the pair unless its bracket fits" {
    const rt_sub_source = "def f() -> aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbb" ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbb[c]:\n    pass\n";

    const rt_sub_wanted = "def f() -> (\n" ++
        "    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "b[\n        c\n    ]\n):\n    pass\n";

    const rt_list_source = "def f() -> list[aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, " ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb]:\n    pass\n";

    const rt_list_wanted = "def f() -> list[\n" ++
        "    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,\n" ++
        "    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,\n]:\n    pass\n";

    const rt_call_source = "def f() -> aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbb" ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbb(c):\n    pass\n";

    const rt_call_wanted = "def f() -> (\n" ++
        "    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "b(\n        c\n    )\n):\n    pass\n";

    const rt_union_source = "def f() -> aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa | bbb" ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb | None:\n    pass\n";

    const rt_union_wanted = "def f() -> (\n" ++
        "    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n" ++
        "    | bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n    | None\n):\n    pass\n";

    try expect_held(rt_sub_source, rt_sub_wanted);
    try expect_held(rt_sub_wanted, rt_sub_wanted);
    try expect_held(rt_list_source, rt_list_wanted);
    try expect_held(rt_list_wanted, rt_list_wanted);
    try expect_held(rt_call_source, rt_call_wanted);
    try expect_held(rt_call_wanted, rt_call_wanted);
    try expect_held(rt_union_source, rt_union_wanted);
    try expect_held(rt_union_wanted, rt_union_wanted);
}

test "a walrus breaks ahead of its operator when its head runs long" {
    const wl_bare_source = "if y := aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbb" ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbb(c):\n    pass\n";

    const wl_bare_wanted = "if (\n" ++
        "    y\n" ++
        "    := aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbb(\n        c\n    )\n):\n    pass\n";

    const wl_fits_source = "if (y := f(aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, bbbbb" ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)):\n    pass\n";

    const wl_fits_wanted = "if y := f(\n" ++
        "    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,\n" ++
        "    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,\n):\n    pass\n";

    const wl_name_source = "if (yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy := aaaaaaaaaaaaaaaaaaaaaaaaaaa" ++
        "aaaaaaaaaaaaaaaaaaaaaaabbbbbbbbbb):\n    pass\n";

    const wl_name_wanted = "if (\n" ++
        "    yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy\n" ++
        "    := aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbbbbbbbbb\n):\n    pass\n";

    try expect_held(wl_bare_source, wl_bare_wanted);
    try expect_held(wl_bare_wanted, wl_bare_wanted);
    try expect_held(wl_fits_source, wl_fits_wanted);
    try expect_held(wl_fits_wanted, wl_fits_wanted);
    try expect_held(wl_name_source, wl_name_wanted);
    try expect_held(wl_name_wanted, wl_name_wanted);
}

test "a leading bracket keeps the pair unless what follows it fits" {
    const fb_binop_source = "if (a + b) and aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabb" ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:\n    pass\n";

    const fb_binop_wanted = "if (\n" ++
        "    (a + b)\n" ++
        "    and aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbb\n):\n    pass\n";

    const fb_list_source = "if [a, b] and aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbbb" ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:\n    pass\n";

    const fb_list_wanted = "if (\n" ++
        "    [a, b]\n" ++
        "    and aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbb\n):\n    pass\n";

    try expect_held(fb_binop_source, fb_binop_wanted);
    try expect_held(fb_binop_wanted, fb_binop_wanted);
    try expect_held(fb_list_source, fb_list_wanted);
    try expect_held(fb_list_wanted, fb_list_wanted);
}

test "a match guard takes the pair it needs" {
    const mg_call_source = "match x:\n" ++
        "    case 1 if aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbb(c):\n        pass\n";

    const mg_call_wanted = "match x:\n" ++
        "    case 1 if (\n" ++
        "        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "b(\n            c\n        )\n    ):\n        pass\n";

    const mg_args_source = "match x:\n" ++
        "    case 1 if f(aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb):\n        pass\n";

    const mg_args_wanted = "match x:\n" ++
        "    case 1 if f(\n" ++
        "        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,\n" ++
        "        bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,\n    ):\n        pass\n";

    try expect_held(mg_call_source, mg_call_wanted);
    try expect_held(mg_call_wanted, mg_call_wanted);
    try expect_held(mg_args_source, mg_args_wanted);
    try expect_held(mg_args_wanted, mg_args_wanted);
}

test "a case pattern takes the pair and sheds the redundant one" {
    const mp_or_source = "match x:\n" ++
        "    case aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "b | cccccccccccc:\n        pass\n";

    const mp_or_wanted = "match x:\n" ++
        "    case (\n" ++
        "        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "\n        | cccccccccccc\n    ):\n        pass\n";

    const mp_open_source = "match x:\n" ++
        "    case aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbb:\n        pass\n";

    const mp_open_wanted = "match x:\n" ++
        "    case (\n" ++
        "        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,\n" ++
        "        bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,\n    ):\n        pass\n";

    const mp_call_source = "case(aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbb" ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)\n";

    const mp_call_wanted = "case(\n" ++
        "    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,\n" ++
        "    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,\n)\n";

    const pe_neg_source = "match x:\n    case (-1 + 2j):\n        pass\n";
    const pe_neg_wanted = "match x:\n    case -1 + 2j:\n        pass\n";
    const pe_single_source = "match x:\n    case (a,):\n        pass\n";
    const pe_or_source = "match x:\n    case (1 | 2):\n        pass\n";
    const pe_or_wanted = "match x:\n    case 1 | 2:\n        pass\n";

    try expect_held(mp_or_source, mp_or_wanted);
    try expect_held(mp_or_wanted, mp_or_wanted);
    try expect_held(mp_open_source, mp_open_wanted);
    try expect_held(mp_open_wanted, mp_open_wanted);
    try expect_held(mp_call_source, mp_call_wanted);
    try expect_held(mp_call_wanted, mp_call_wanted);
    try expect_held(pe_neg_source, pe_neg_wanted);
    try expect_held(pe_neg_wanted, pe_neg_wanted);
    try expect_held(pe_single_source, pe_single_source);
    try expect_held(pe_or_source, pe_or_wanted);
    try expect_held(pe_or_wanted, pe_or_wanted);
}

test "an over-long match subject wraps the way a returned value does" {
    const match_tuple_source = "match aaaaaaaaaaaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbb, cccccccccccccccccccccccc:\n    case _:\n        pass\n";

    const match_tuple_wanted = "match (\n" ++
        "    aaaaaaaaaaaaaaaaaaaaaaaaaaaaa,\n" ++
        "    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,\n" ++
        "    cccccccccccccccccccccccc,\n):\n    case _:\n        pass\n";

    const match_call_source = "match some_function_name(aaaaaaaaaaaaaaaaaaaaaaaaaaaaa, bbbbbb" ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb, ccccc):\n    case _:\n        pass\n";

    const match_call_wanted = "match some_function_name(\n" ++
        "    aaaaaaaaaaaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb, ccccc\n" ++
        "):\n    case _:\n        pass\n";

    const match_short_source = "match a, b:\n    case _:\n        pass\n";

    try expect_held(match_tuple_source, match_tuple_wanted);
    try expect_held(match_tuple_wanted, match_tuple_wanted);
    try expect_held(match_call_source, match_call_wanted);
    try expect_held(match_call_wanted, match_call_wanted);
    try expect_held(match_short_source, match_short_source);
}

test "an as pattern or an or pattern takes parentheses whenever it expands" {
    const pa_as_source = "match x:\n" ++
        "    case aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbbcc as yyyyy:\n        pass\n";

    const pa_as_wanted = "match x:\n" ++
        "    case (\n" ++
        "        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbcc as yyyyy\n    ):\n        pass\n";

    const pa_kept_source = "match x:\n" ++
        "    case (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbbb as yyyyy):\n        pass\n";

    const pa_kept_wanted = "match x:\n" ++
        "    case (\n" ++
        "        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbb as yyyyy\n    ):\n        pass\n";

    const pa_or_source = "match x:\n" ++
        "    case aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa | bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb | ccc" ++
        "ccccccccccccccccccccccc:\n        pass\n";

    const pa_or_wanted = "match x:\n" ++
        "    case (\n" ++
        "        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n" ++
        "        | bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n" ++
        "        | cccccccccccccccccccccccccc\n    ):\n        pass\n";

    const pa_split_source = "match x:\n" ++
        "    case Cccccccccccccccccccccc(aaaaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbbbb, ccccc" ++
        "ccccc) as yyyyy:\n        pass\n";

    const pa_split_wanted = "match x:\n" ++
        "    case Cccccccccccccccccccccc(\n" ++
        "        aaaaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbbbb, cccccccccc\n" ++
        "    ) as yyyyy:\n        pass\n";

    try expect_held(pa_as_source, pa_as_wanted);
    try expect_held(pa_as_wanted, pa_as_wanted);
    try expect_held(pa_kept_source, pa_kept_wanted);
    try expect_held(pa_kept_wanted, pa_kept_wanted);
    try expect_held(pa_or_source, pa_or_wanted);
    try expect_held(pa_or_wanted, pa_or_wanted);
    try expect_held(pa_split_source, pa_split_wanted);
    try expect_held(pa_split_wanted, pa_split_wanted);
}

test "a guard takes parentheses even when the header before it overflows" {
    const gd_name_source = "match x:\n" ++
        "    case aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbbbbb if cond:\n        pass\n";

    const gd_name_wanted = "match x:\n" ++
        "    case aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbbbbb if (\n        cond\n    ):\n        pass\n";

    const gd_call_source = "match x:\n" ++
        "    case aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbbbbb if f(x):\n        pass\n";

    const gd_call_wanted = "match x:\n" ++
        "    case aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbbbbb if (\n        f(x)\n    ):\n        pass\n";

    try expect_held(gd_name_source, gd_name_wanted);
    try expect_held(gd_name_wanted, gd_name_wanted);
    try expect_held(gd_call_source, gd_call_wanted);
    try expect_held(gd_call_wanted, gd_call_wanted);
}

test "an over-long global or nonlocal continues with backslashes" {
    const gl_global_source = "def f():\n" ++
        "    global aaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbb, cccccccccccccccccccc, ddddddddddddd" ++
        "ddddddddd, eeeeeeeeeeeeeeee\n";

    const gl_global_wanted = "def f():\n" ++
        "    global \\\n" ++
        "        aaaaaaaaaaaaaaaa, \\\n" ++
        "        bbbbbbbbbbbbbbbbbbbbb, \\\n" ++
        "        cccccccccccccccccccc, \\\n" ++
        "        dddddddddddddddddddddd, \\\n        eeeeeeeeeeeeeeee\n";

    const gl_nonlocal_source = "def f():\n" ++
        "    def g():\n" ++
        "        nonlocal aaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbb, cccccccccccccccccccc, ddddddd" ++
        "ddddddddddddddd\n";

    const gl_nonlocal_wanted = "def f():\n" ++
        "    def g():\n" ++
        "        nonlocal \\\n" ++
        "            aaaaaaaaaaaaaaaa, \\\n" ++
        "            bbbbbbbbbbbbbbbbbbbbb, \\\n" ++
        "            cccccccccccccccccccc, \\\n            dddddddddddddddddddddd\n";

    const gl_comment_source = "global aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, bbbbbb" ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  # c\n";

    const gl_one_source = "global a, b\n" ++
        "global aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++
        "aaaaaaaaaaa\n";

    const gl_one_wanted = "global a, b\n" ++
        "global \\\n" ++
        "    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++
        "aaaaaaaa\n";

    const gl_line_source = "def f():\n" ++
        "    global aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbbbbbbbbbbb; x = 1\n";

    const gl_line_wanted = "def f():\n" ++
        "    global \\\n" ++
        "        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, \\\n" ++
        "        bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n    x = 1\n";

    try expect_held(gl_global_source, gl_global_wanted);
    try expect_held(gl_global_wanted, gl_global_wanted);
    try expect_held(gl_nonlocal_source, gl_nonlocal_wanted);
    try expect_held(gl_nonlocal_wanted, gl_nonlocal_wanted);
    try expect_held(gl_comment_source, gl_comment_source);
    try expect_held(gl_one_source, gl_one_wanted);
    try expect_held(gl_one_wanted, gl_one_wanted);
    try expect_held(gl_line_source, gl_line_wanted);
    try expect_held(gl_line_wanted, gl_line_wanted);
}

test "a parenthesized string that opens a body is its docstring" {
    const dp_def_source = "def f():\n    (\"\"\"Docstring here.\"\"\")\n    return 1\n";
    const dp_def_wanted = "def f():\n    \"\"\"Docstring here.\"\"\"\n    return 1\n";
    const dp_class_source = "class C:\n    (\n        \"doc\"\n    )\n    x = 1\n";
    const dp_class_wanted = "class C:\n    \"doc\"\n\n    x = 1\n";
    const dp_module_source = "(\"\"\"Module doc.\"\"\")\nimport os\n";
    const dp_module_wanted = "\"\"\"Module doc.\"\"\"\n\nimport os\n";
    const dp_comment_source = "def f():\n    (  # c\n        \"doc\"\n    )\n    return 1\n";
    const dp_comment_wanted = "def f():\n    # c\n    \"doc\"\n    return 1\n";
    const dp_joined_source = "def f():\n    (\"doc\" \"concat\")\n";
    const dp_joined_wanted = "def f():\n    \"docconcat\"\n";
    const dp_line_source = "def f(): (\"doc\")\n";
    const dp_line_wanted = "def f():\n    \"doc\"\n";
    const dp_doubled_source = "class C:\n    ((\"doc\"))\n    x = 1\n";
    const dp_doubled_wanted = "class C:\n    \"doc\"\n\n    x = 1\n";
    const dp_later_source = "def f():\n    x = 1\n    (\"not a doc\")\n";
    const dp_called_source = "def f():\n    (\"doc\").strip()\n";

    try expect_held(dp_def_source, dp_def_wanted);
    try expect_held(dp_def_wanted, dp_def_wanted);
    try expect_held(dp_class_source, dp_class_wanted);
    try expect_held(dp_class_wanted, dp_class_wanted);
    try expect_held(dp_module_source, dp_module_wanted);
    try expect_held(dp_module_wanted, dp_module_wanted);
    try expect_held(dp_comment_source, dp_comment_wanted);
    try expect_held(dp_comment_wanted, dp_comment_wanted);
    try expect_held(dp_joined_source, dp_joined_wanted);
    try expect_held(dp_joined_wanted, dp_joined_wanted);
    try expect_held(dp_line_source, dp_line_wanted);
    try expect_held(dp_line_wanted, dp_line_wanted);
    try expect_held(dp_doubled_source, dp_doubled_wanted);
    try expect_held(dp_doubled_wanted, dp_doubled_wanted);
    try expect_held(dp_later_source, dp_later_source);
    try expect_held(dp_called_source, dp_called_source);
}

test "a lambda whose body spans lines takes parentheses around it in a header" {
    const lh_assert_source = "assert lambda: \"\"\"a\nb\"\"\"\n";
    const lh_assert_wanted = "assert (\n    lambda: (\n        \"\"\"a\nb\"\"\"\n    )\n)\n";
    const lh_if_source = "if lambda: \"\"\"a\nb\"\"\":\n    pass\n";
    const lh_if_wanted = "if (\n    lambda: (\n        \"\"\"a\nb\"\"\"\n    )\n):\n    pass\n";
    const lh_message_source = "assert a, lambda: \"\"\"a\nb\"\"\"\n";
    const lh_message_wanted = "assert a, (\n    lambda: (\n        \"\"\"a\nb\"\"\"\n    )\n)\n";
    const lh_enclosed_source = "assert a, (lambda: \"\"\"a\nb\"\"\")\n";
    const lh_enclosed_wanted = "assert a, (\n    lambda: (\n        \"\"\"a\nb\"\"\"\n    )\n)\n";
    const lh_while_source = "while lambda: \"\"\"a\nb\"\"\":\n    pass\n";

    const lh_while_wanted = "while (\n" ++
        "    lambda: (\n        \"\"\"a\nb\"\"\"\n    )\n):\n    pass\n";

    const lh_for_source = "for a in lambda: \"\"\"a\nb\"\"\":\n    pass\n";

    const lh_for_wanted = "for a in (\n" ++
        "    lambda: (\n        \"\"\"a\nb\"\"\"\n    )\n):\n    pass\n";

    const lh_elif_source = "if x:\n    pass\nelif lambda: \"\"\"a\nb\"\"\":\n    pass\n";

    const lh_elif_wanted = "if x:\n" ++
        "    pass\nelif (\n    lambda: (\n        \"\"\"a\nb\"\"\"\n    )\n):\n    pass\n";

    const lh_guard_source = "match x:\n    case y if lambda: \"\"\"a\nb\"\"\":\n        pass\n";

    const lh_guard_wanted = "match x:\n" ++
        "    case y if (\n" ++
        "        lambda: (\n            \"\"\"a\nb\"\"\"\n        )\n    ):\n        pass\n";

    const lh_tested_source = "assert lambda: \"\"\"a\nb\"\"\", \"message\"\n";

    const lh_tested_wanted = "assert (\n" ++
        "    lambda: (\n        \"\"\"a\nb\"\"\"\n    )\n), \"message\"\n";

    const lh_flat_source = "assert lambda: x\n";

    try expect_held(lh_assert_source, lh_assert_wanted);
    try expect_held(lh_assert_wanted, lh_assert_wanted);
    try expect_held(lh_if_source, lh_if_wanted);
    try expect_held(lh_if_wanted, lh_if_wanted);
    try expect_held(lh_message_source, lh_message_wanted);
    try expect_held(lh_message_wanted, lh_message_wanted);
    try expect_held(lh_enclosed_source, lh_enclosed_wanted);
    try expect_held(lh_enclosed_wanted, lh_enclosed_wanted);
    try expect_held(lh_while_source, lh_while_wanted);
    try expect_held(lh_while_wanted, lh_while_wanted);
    try expect_held(lh_for_source, lh_for_wanted);
    try expect_held(lh_for_wanted, lh_for_wanted);
    try expect_held(lh_elif_source, lh_elif_wanted);
    try expect_held(lh_elif_wanted, lh_elif_wanted);
    try expect_held(lh_guard_source, lh_guard_wanted);
    try expect_held(lh_guard_wanted, lh_guard_wanted);
    try expect_held(lh_tested_source, lh_tested_wanted);
    try expect_held(lh_tested_wanted, lh_tested_wanted);
    try expect_held(lh_flat_source, lh_flat_source);
}

test "an over-long lambda in a header takes the pair around the whole lambda" {
    const lo_message_source = "assert aaaaaaaaaaaaaaaaaa, lambda: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n";

    const lo_message_wanted = "assert aaaaaaaaaaaaaaaaaa, (\n" ++
        "    lambda: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "\n)\n";

    const lo_test_source = "assert lambda: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbbbbbbbbbb, \"m\"\n";

    const lo_test_wanted = "assert (\n" ++
        "    lambda: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "\n), \"m\"\n";

    const lo_while_source = "while lambda: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbbbbbbbbbb:\n    pass\n";

    const lo_while_wanted = "while (\n" ++
        "    lambda: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "\n):\n    pass\n";

    const lo_for_source = "for x in lambda: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbbbbbbbbbbb:\n    pass\n";

    const lo_for_wanted = "for x in (\n" ++
        "    lambda: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "\n):\n    pass\n";

    const lo_guard_source = "match x:\n" ++
        "    case y if lambda: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbbbb:\n        pass\n";

    const lo_guard_wanted = "match x:\n" ++
        "    case y if (\n" ++
        "        lambda: (\n" ++
        "            bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "\n        )\n    ):\n        pass\n";

    const lo_comment_source = "def f():\n" ++
        "    if q:\n" ++
        "        for aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb in lambda: q" ++
        ":  # trailing comment\n            pass\n        else:\n            pass\n";

    const lo_comment_wanted = "def f():\n" ++
        "    if q:\n" ++
        "        for aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb in (\n" ++
        "            lambda: q\n" ++
        "        ):  # trailing comment\n            pass\n        else:\n            pass\n";

    const lo_fits_source = "assert a, lambda: b\n";

    try expect_held(lo_message_source, lo_message_wanted);
    try expect_held(lo_message_wanted, lo_message_wanted);
    try expect_held(lo_test_source, lo_test_wanted);
    try expect_held(lo_test_wanted, lo_test_wanted);
    try expect_held(lo_while_source, lo_while_wanted);
    try expect_held(lo_while_wanted, lo_while_wanted);
    try expect_held(lo_for_source, lo_for_wanted);
    try expect_held(lo_for_wanted, lo_for_wanted);
    try expect_held(lo_guard_source, lo_guard_wanted);
    try expect_held(lo_guard_wanted, lo_guard_wanted);
    try expect_held(lo_comment_source, lo_comment_wanted);
    try expect_held(lo_comment_wanted, lo_comment_wanted);
    try expect_held(lo_fits_source, lo_fits_source);
}

test "a parenthesized value with only a trailing comment loses its pair when it fits" {
    const rm_name_source = "x = (\n    a  # comment\n)\n";
    const rm_name_wanted = "x = a  # comment\n";
    const rm_string_source = "x = (\n    \"ab\"  # comment\n)\n";
    const rm_string_wanted = "x = \"ab\"  # comment\n";
    const rm_attribute_source = "x = (\n    a.b  # comment\n)\n";
    const rm_joined_source = "x = (\n    \"a\" \"b\"  # comment\n)\n";
    const rm_joined_wanted = "x = \"ab\"  # comment\n";
    const rm_format_source = "x = (\n    f\"x{a}\"  # comment\n)\n";
    const rm_format_wanted = "x = f\"x{a}\"  # comment\n";
    const rm_list_source = "x = (\n    [a]  # comment\n)\n";
    const rm_list_wanted = "x = [a]  # comment\n";
    const rm_return_source = "def g():\n    return (\n    a  # comment\n)\n";
    const rm_return_wanted = "def g():\n    return a  # comment\n";
    const rm_assert_source = "def g():\n    assert (\n    a  # comment\n)\n";
    const rm_assert_wanted = "def g():\n    assert (\n        a  # comment\n    )\n";
    const rm_augmented_source = "def g():\n    x += (\n    a  # comment\n)\n";
    const rm_augmented_wanted = "def g():\n    x += a  # comment\n";

    const rm_wide_source = "x = (\n" ++
        "    40  # a very long comment that pushes the unwrapped line past the line width limit" ++
        "\n)\n";

    const rm_wide_wanted = "x = 40  # a very long comment that pushes the unwrapped line past th" ++
        "e line width limit\n";

    try expect_held(rm_name_source, rm_name_wanted);
    try expect_held(rm_name_wanted, rm_name_wanted);
    try expect_held(rm_string_source, rm_string_wanted);
    try expect_held(rm_string_wanted, rm_string_wanted);
    try expect_held(rm_attribute_source, rm_attribute_source);
    try expect_held(rm_joined_source, rm_joined_wanted);
    try expect_held(rm_joined_wanted, rm_joined_wanted);
    try expect_held(rm_format_source, rm_format_wanted);
    try expect_held(rm_format_wanted, rm_format_wanted);
    try expect_held(rm_list_source, rm_list_wanted);
    try expect_held(rm_list_wanted, rm_list_wanted);
    try expect_held(rm_return_source, rm_return_wanted);
    try expect_held(rm_return_wanted, rm_return_wanted);
    try expect_held(rm_assert_source, rm_assert_wanted);
    try expect_held(rm_assert_wanted, rm_assert_wanted);
    try expect_held(rm_augmented_source, rm_augmented_wanted);
    try expect_held(rm_augmented_wanted, rm_augmented_wanted);
    try expect_held(rm_wide_source, rm_wide_wanted);
    try expect_held(rm_wide_wanted, rm_wide_wanted);
}

test "a comment riding an inner opening bracket leaves the outer pair free to go" {
    const ro_operator_source = "x = (\n    \"a\" \"b\" % (  # comment\n        bbbb\n    )\n)\n";
    const ro_operator_wanted = "x = \"ab\" % (  # comment\n    bbbb\n)\n";
    const ro_call_source = "x = (\n    \"a\" \"b\".format(  # comment\n        bbbb\n    )\n)\n";
    const ro_call_wanted = "x = \"ab\".format(  # comment\n    bbbb\n)\n";

    try expect_held(ro_operator_source, ro_operator_wanted);
    try expect_held(ro_operator_wanted, ro_operator_wanted);
    try expect_held(ro_call_source, ro_call_wanted);
    try expect_held(ro_call_wanted, ro_call_wanted);
}

test "scouted lambda and comment shapes format stably and keep what the source means" {
    const lambda_width_source = "x = core_schema.typed_dict_field(\n" ++
        "    core_schema.any_schema(), serialization_exclude_if=lambda x:" ++
        " isinstance(x, int) and x >= 2 and bbbbbbbbbbbbbbb\n" ++
        ")\n";

    const lambda_width_wanted = "x = core_schema.typed_dict_field(\n" ++
        "    core_schema.any_schema(),\n" ++
        "    serialization_exclude_if=lambda x: (\n" ++
        "        isinstance(x, int) and x >= 2 and bbbbbbbbbbbbbbb\n" ++
        "    ),\n" ++
        ")\n";

    const bare_return_source = "def f():\n" ++
        "    return  # prevent recursion on a definition that was already" ++
        " visited and more words\n";

    const bare_return_wanted = "def f():\n" ++
        "    return  # prevent recursion on a definition that was already" ++
        " visited and more words\n";

    const import_comment_source = "def f():\n" ++
        "    if x:\n" ++
        "        from mypy.server.deps import merge_dependencies  # Lazy " ++
        "import to speed up startup\n";

    const import_comment_wanted = "def f():\n" ++
        "    if x:\n" ++
        "        from mypy.server.deps import (\n" ++
        "            merge_dependencies,\n" ++
        "        )  # Lazy import to speed up startup\n";

    const debug_field_source = "print(f'{x = }')\n" ++
        "print(f'{d[\"k\"] = }')\n";

    const debug_field_wanted = "print(f\"{x = }\")\n" ++
        "print(f'{d[\"k\"] = }')\n";

    const power_comment_source = "if (\n" ++
        "    aaa  # c1\n" ++
        "    **\n" ++
        "    # own line\n" ++
        "    bbb\n" ++
        "):\n" ++
        "    pass\n";

    const power_comment_wanted = "if (\n" ++
        "    aaa  # c1\n" ++
        "    **\n" ++
        "    # own line\n" ++
        "    bbb\n" ++
        "):\n" ++
        "    pass\n";

    try expect_held(lambda_width_source, lambda_width_wanted);
    try expect_held(lambda_width_wanted, lambda_width_wanted);
    try expect_held(bare_return_source, bare_return_wanted);
    try expect_held(bare_return_wanted, bare_return_wanted);
    try expect_held(import_comment_source, import_comment_wanted);
    try expect_held(import_comment_wanted, import_comment_wanted);
    try expect_held(debug_field_source, debug_field_wanted);
    try expect_held(debug_field_wanted, debug_field_wanted);
    try expect_held(power_comment_source, power_comment_wanted);
    try expect_held(power_comment_wanted, power_comment_wanted);
}

test "scouted message and chain shapes format stably and keep what the source means" {
    const pragma_source = "def test():\n" ++
        "    InnerModel.__pydantic_complete__ = True  # pyright: ignore[r" ++
        "eportAttributeAccessIssue]\n";

    const pragma_wanted = "def test():\n" ++
        "    InnerModel.__pydantic_complete__ = True  # pyright: ignore[r" ++
        "eportAttributeAccessIssue]\n";

    const message_source = "assert len(args) == 1, f\"The type key of core schemas must be a " ++
        "Literal form with a single {x}\"\n";

    const message_wanted = "assert len(args) == 1, (\n" ++
        "    f\"The type key of core schemas must be a Literal form with a" ++
        " single {x}\"\n" ++
        ")\n";

    const raw_concat_source = "msg = (r'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' rf\"bbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbbbbbbbbbbbbbb\")\n";

    const raw_concat_wanted = "msg = (\n" ++
        "    r\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\" rf\"bbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbbbbbbbbbbb\"\n" ++
        ")\n";

    const later_chain_source = "def f():\n" ++
        "    if spec is not None:\n" ++
        "        with self.file_context(file_node, options, info):\n" ++
        "            ok = ok and dataclasses_plugin.DataclassTransformer(" ++
        "defn, defn, spec, self).transform()\n" ++
        "\n" ++
        "    return ok\n" ++
        "\n" ++
        "\n" ++
        "x = a().b\n";

    const later_chain_wanted = "def f():\n" ++
        "    if spec is not None:\n" ++
        "        with self.file_context(file_node, options, info):\n" ++
        "            ok = (\n" ++
        "                ok\n" ++
        "                and dataclasses_plugin.DataclassTransformer(\n" ++
        "                    defn, defn, spec, self\n" ++
        "                ).transform()\n" ++
        "            )\n" ++
        "\n" ++
        "    return ok\n" ++
        "\n" ++
        "\n" ++
        "x = a().b\n";

    try expect_held(pragma_source, pragma_wanted);
    try expect_held(pragma_wanted, pragma_wanted);
    try expect_held(message_source, message_wanted);
    try expect_held(message_wanted, message_wanted);
    try expect_held(raw_concat_source, raw_concat_wanted);
    try expect_held(raw_concat_wanted, raw_concat_wanted);
    try expect_held(later_chain_source, later_chain_wanted);
    try expect_held(later_chain_wanted, later_chain_wanted);
}

test "httpx session expressions format the way ruff does and hold their output" {
    const doubled_source = "x = against(config, \"mysql\") and ((config.db.dialect._is_maria" ++
        "db and config.db.dialect.server_version_info_long >= (10, 2)))\n";

    const doubled_wanted = "x = against(config, \"mysql\") and (\n" ++
        "    config.db.dialect._is_mariadb\n" ++
        "    and config.db.dialect.server_version_info_long >= (10, 2)\n" ++
        ")\n";

    const template_source = "x = T\"a {b}\"\n" ++
        "y = tr\"a\\\\b\"\n";

    const template_wanted = "x = t\"a {b}\"\n" ++
        "y = rt\"a\\\\b\"\n";

    const named_source = "x = \"\\N{em dash}\" + f\"{a}\\N{greek small letter pi}\"\n";
    const named_wanted = "x = \"\\N{EM DASH}\" + f\"{a}\\N{GREEK SMALL LETTER PI}\"\n";

    const walrus_source = "if flip := (self.step < 0):\n" ++
        "    pass\n";

    const walrus_wanted = "if flip := (self.step < 0):\n" ++
        "    pass\n";

    const slices_source = "a.iloc[:5, f.columns.get_loc(\"A\")] = x[a.b:c, d]\n" ++
        "ser[lambda x: \"A\"] = -1\n";

    const slices_wanted = "a.iloc[:5, f.columns.get_loc(\"A\")] = x[a.b : c, d]\n" ++
        "ser[lambda x: \"A\"] = -1\n";

    try expect_held(doubled_source, doubled_wanted);
    try expect_held(doubled_wanted, doubled_wanted);
    try expect_held(template_source, template_wanted);
    try expect_held(template_wanted, template_wanted);
    try expect_held(named_source, named_wanted);
    try expect_held(named_wanted, named_wanted);
    try expect_held(walrus_source, walrus_wanted);
    try expect_held(walrus_wanted, walrus_wanted);
    try expect_held(slices_source, slices_wanted);
    try expect_held(slices_wanted, slices_wanted);
}

test "httpx session lambda bodies and annotations format the way ruff does and hold their output" {
    const lambda_body_source = "def f():\n" ++
        "    return succeeds_if(\n" ++
        "        lambda config: (\n" ++
        "            config.db.dialect.insert_null_pk_still_autoincrements\n" ++
        "        )\n" ++
        "    )\n";

    const lambda_body_wanted = "def f():\n" ++
        "    return succeeds_if(\n" ++
        "        lambda config: config.db.dialect.insert_null_pk_still_autoincrements\n" ++
        "    )\n";

    const annotation_source = "class A:\n" ++
        "    previousSibling: _DocumentChildren | _ElementChildren | _DocumentFragmentChildr" ++
        "en | None\n" ++
        "    x: (int) = 5\n" ++
        "    value: Any  # Note: bytes if _CT == c_char, str if _CT == c_wchar, unavailable " ++
        "otherwise\n";

    const annotation_wanted = "class A:\n" ++
        "    previousSibling: (\n" ++
        "        _DocumentChildren | _ElementChildren | _DocumentFragmentChildren | None\n" ++
        "    )\n" ++
        "    x: int = 5\n" ++
        "    value: Any  # Note: bytes if _CT == c_char, str if _CT == c_wchar, unavailable " ++
        "otherwise\n";

    try expect_held(lambda_body_source, lambda_body_wanted);
    try expect_held(lambda_body_wanted, lambda_body_wanted);
    try expect_held(annotation_source, annotation_wanted);
    try expect_held(annotation_wanted, annotation_wanted);
}

test "httpx session headers and bodies format the way ruff does and hold their output" {
    const returns_source = "def a(self, call: CallExpr, fullname: str) -> None | tuple[list[" ++
        "str], list[Type], list[Expression], str, list[TypeVarLikeType], bool]:\n" ++
        "    pass\n";

    const returns_wanted = "def a(\n" ++
        "    self, call: CallExpr, fullname: str\n" ++
        ") -> (\n" ++
        "    None\n" ++
        "    | tuple[list[str], list[Type], list[Expression], str, list[TypeVarLikeType], bo" ++
        "ol]\n" ++
        "):\n" ++
        "    pass\n";

    const with_items_source = "def f():\n" ++
        "    with self._config_wrapper_stack.push(config_wrapper), self._ns_resolver.push(cl" ++
        "s_value):\n" ++
        "        pass\n";

    const with_items_wanted = "def f():\n" ++
        "    with (\n" ++
        "        self._config_wrapper_stack.push(config_wrapper),\n" ++
        "        self._ns_resolver.push(cls_value),\n" ++
        "    ):\n" ++
        "        pass\n";

    const subscript_tuple_source = "assert_type(np.where([True, True, False]), tuple[npt.Arr" ++
        "ay1D[np.intp],])\n";

    const subscript_tuple_wanted = "assert_type(np.where([True, True, False]), tuple[npt.Arr" ++
        "ay1D[np.intp],])\n";

    const ternary_lambda_source = "getter = operator.itemgetter(*cls.__pydantic_fields__.key" ++
        "s()) if cls.__pydantic_fields__ else lambda _: 0\n";

    const ternary_lambda_wanted = "getter = (\n" ++
        "    operator.itemgetter(*cls.__pydantic_fields__.keys())\n" ++
        "    if cls.__pydantic_fields__\n" ++
        "    else lambda _: 0\n" ++
        ")\n";

    const leading_comment_source = "class A(B):\n" ++
        "# comment\n" ++
        "    def f(self) -> None:\n" ++
        "        pass\n";

    const leading_comment_wanted = "class A(B):\n" ++
        "    # comment\n" ++
        "    def f(self) -> None:\n" ++
        "        pass\n";

    const docstring_source = "def f():\n" ++
        "    \"\"\" \"\"\"\n";

    const docstring_wanted = "def f():\n" ++
        "    \"\"\" \"\"\"\n";

    try expect_held(returns_source, returns_wanted);
    try expect_held(returns_wanted, returns_wanted);
    try expect_held(with_items_source, with_items_wanted);
    try expect_held(with_items_wanted, with_items_wanted);
    try expect_held(subscript_tuple_source, subscript_tuple_wanted);
    try expect_held(subscript_tuple_wanted, subscript_tuple_wanted);
    try expect_held(ternary_lambda_source, ternary_lambda_wanted);
    try expect_held(ternary_lambda_wanted, ternary_lambda_wanted);
    try expect_held(leading_comment_source, leading_comment_wanted);
    try expect_held(leading_comment_wanted, leading_comment_wanted);
    try expect_held(docstring_source, docstring_wanted);
    try expect_held(docstring_wanted, docstring_wanted);
}

test "httpx session concatenations and format-off regions format the way ruff does" {
    const concatenation_source = "raise ValueError(\n" ++
        "    f\"Length of ascending ({len(ascending)})\"  # type: ignore[arg-type]\n" ++
        "    f\" != length of by ({len(by)})\"\n" ++
        ")\n";

    const concatenation_wanted = "raise ValueError(\n" ++
        "    f\"Length of ascending ({len(ascending)})\"  # type: ignore[arg-type]\n" ++
        "    f\" != length of by ({len(by)})\"\n" ++
        ")\n";

    const format_on_source = "def t():\n" ++
        "    # fmt: off\n" ++
        "    class M:\n" ++
        "        def bar(self):\n" ++
        "            pass\n" ++
        "\n" ++
        "        a: int\n" ++
        "    # fmt: on\n" ++
        "    assert M\n";

    const format_on_wanted = "def t():\n" ++
        "    # fmt: off\n" ++
        "    class M:\n" ++
        "        def bar(self):\n" ++
        "            pass\n" ++
        "\n" ++
        "        a: int\n" ++
        "    # fmt: on\n" ++
        "    assert M\n";

    try expect_held(concatenation_source, concatenation_wanted);
    try expect_held(concatenation_wanted, concatenation_wanted);
    try expect_held(format_on_source, format_on_wanted);
    try expect_held(format_on_wanted, format_on_wanted);
}

test "httpx session assert comments and stubs format the way ruff does and hold their output" {
    const assert_comment_source = "def test():\n" ++
        "    assert a._double_x == 4  # Ensure properties with leading underscores work fine" ++
        " and don't become private attributes\n";

    const assert_comment_wanted = "def test():\n" ++
        "    assert (\n" ++
        "        a._double_x == 4\n" ++
        "    )  # Ensure properties with leading underscores work fine and don't become priv" ++
        "ate attributes\n";

    const stub_source = "def f(): ...\n" ++
        "def g(): ...\n" ++
        "\n" ++
        "class A: ...\n" ++
        "class B:\n" ++
        "    x: int\n" ++
        "    def h(self): ...\n" ++
        "\n" ++
        "    y: int\n" ++
        "if sys.version_info >= (3, 8):\n" ++
        "    ...\n" ++
        "else:\n" ++
        "    class C: ...\n" ++
        "z: int\n";

    const stub_wanted = "def f(): ...\n" ++
        "def g(): ...\n" ++
        "\n" ++
        "class A: ...\n" ++
        "\n" ++
        "class B:\n" ++
        "    x: int\n" ++
        "    def h(self): ...\n" ++
        "\n" ++
        "    y: int\n" ++
        "\n" ++
        "if sys.version_info >= (3, 8): ...\n" ++
        "else:\n" ++
        "    class C: ...\n" ++
        "\n" ++
        "z: int\n";

    try expect_held(assert_comment_source, assert_comment_wanted);
    try expect_held(assert_comment_wanted, assert_comment_wanted);
    try expect_held_as(stub_source, stub_wanted, true);
    try expect_held_as(stub_wanted, stub_wanted, true);
}

test "pydantic and fastapi decorators and lambda entries format the way ruff does" {
    const decorated_source = "class A:\n" ++
        "    x = 1\n" ++
        "\n" ++
        "    @property\n" ++
        "# c\n" ++
        "    def f(self):\n" ++
        "        pass\n";

    const decorated_wanted = "class A:\n" ++
        "    x = 1\n" ++
        "\n" ++
        "    @property\n" ++
        "    # c\n" ++
        "    def f(self):\n" ++
        "        pass\n";

    const lambda_entry_source = "_object_setattr = {\n" ++
        "    \"validate_assignment\": lambda model, name, val: model.__pydantic_validator__.vali" ++
        "date_assignment(model, name, val),\n" ++
        "}\n";

    const lambda_entry_wanted = "_object_setattr = {\n" ++
        "    \"validate_assignment\": lambda model, name, val: (\n" ++
        "        model.__pydantic_validator__.validate_assignment(model, name, val)\n" ++
        "    ),\n" ++
        "}\n";

    try expect_held(decorated_source, decorated_wanted);
    try expect_held(decorated_wanted, decorated_wanted);
    try expect_held(lambda_entry_source, lambda_entry_wanted);
    try expect_held(lambda_entry_wanted, lambda_entry_wanted);
}

test "pydantic and fastapi annotations, defaults and subscripts format the way ruff does" {
    const annotated_source = "class A:\n" ++
        "    get_pydantic_core_schema: Callable[[Any, GetCoreSchemaHandler], CoreSchema] | None " ++
        "= None\n" ++
        "    get_pydantic: Callable[[Any, X], CoreSchema] | None = some_function_name_long_long_" ++
        "xxx\n";

    const annotated_wanted = "class A:\n" ++
        "    get_pydantic_core_schema: (\n" ++
        "        Callable[[Any, GetCoreSchemaHandler], CoreSchema] | None\n" ++
        "    ) = None\n" ++
        "    get_pydantic: Callable[[Any, X], CoreSchema] | None = (\n" ++
        "        some_function_name_long_long_xxx\n" ++
        "    )\n";

    const defaulted_source = "async def read_items(q: str | None = Query(default=None, min_lengt" ++
        "h=3, max_length=50, pattern=\"^fixedquery$\")):\n" ++
        "    pass\n";

    const defaulted_wanted = "async def read_items(\n" ++
        "    q: str | None = Query(\n" ++
        "        default=None, min_length=3, max_length=50, pattern=\"^fixedquery$\"\n" ++
        "    ),\n" ++
        "):\n" ++
        "    pass\n";

    const subscripted_source = "typedefs[\"complex_long_double\"] = \"typedef union { struct {lo" ++
        "ng double r,i;}; npy_clongdouble _npy; } complex_long_double;\"\n";

    const subscripted_wanted = "typedefs[\"complex_long_double\"] = (\n" ++
        "    \"typedef union { struct {long double r,i;}; npy_clongdouble _npy; } complex_long_d" ++
        "ouble;\"\n" ++
        ")\n";

    try expect_held(annotated_source, annotated_wanted);
    try expect_held(annotated_wanted, annotated_wanted);
    try expect_held(defaulted_source, defaulted_wanted);
    try expect_held(defaulted_wanted, defaulted_wanted);
    try expect_held(subscripted_source, subscripted_wanted);
    try expect_held(subscripted_wanted, subscripted_wanted);
}

test "pydantic and fastapi pragmas and fields format the way ruff does and hold their output" {
    const pragma_source = "def f():\n" ++
        "    if x:\n" ++
        "        if y:\n" ++
        "            output += f\"ERROR: objects in {module_name}.__all__ but not in refguide::" ++
        "\\n\\n\"  # noqa: E501\n";

    const pragma_wanted = "def f():\n" ++
        "    if x:\n" ++
        "        if y:\n" ++
        "            output += (\n" ++
        "                f\"ERROR: objects in {module_name}.__all__ but not in refguide::\\n\\n" ++
        "\"  # noqa: E501\n" ++
        "            )\n";

    const fielded_source = "a = f\"{1.:f} {0XFF}\"\n" ++
        "b = [x for x, in q]\n";

    const fielded_wanted = "a = f\"{1.0:f} {0xFF}\"\n" ++
        "b = [x for (x,) in q]\n";

    try expect_held(pragma_source, pragma_wanted);
    try expect_held(pragma_wanted, pragma_wanted);
    try expect_held(fielded_source, fielded_wanted);
    try expect_held(fielded_wanted, fielded_wanted);
}

test "pydantic and fastapi logic and comments format the way ruff does and hold their output" {
    const logic_source = "class A:\n" ++
        "    def f(self):\n" ++
        "        is_non_unique_col = selected_obj.ndimxxxxx and selected_obj.columns.nunique() <" ++
        " len(selected_obj.c)\n" ++
        "        is_non_unique_colxxxxxxxxxxxxxxxxxxxxxx = selected_obj.columns.nunique() < len(" ++
        "selected_obj.c)\n";

    const logic_wanted = "class A:\n" ++
        "    def f(self):\n" ++
        "        is_non_unique_col = (\n" ++
        "            selected_obj.ndimxxxxx\n" ++
        "            and selected_obj.columns.nunique() < len(selected_obj.c)\n" ++
        "        )\n" ++
        "        is_non_unique_colxxxxxxxxxxxxxxxxxxxxxx = selected_obj.columns.nunique() < len(" ++
        "\n" ++
        "            selected_obj.c\n" ++
        "        )\n";

    const commented_source = "x = Annotated[\n" ++
        "    TV, mapped_column(info={\"hi\": \"there\"})  # type: ignore\n" ++
        "]\n" ++
        "\n" ++
        "\n" ++
        "def f(value):\n" ++
        "    return (\n" ++
        "        isinstance(value, dict)\n" ++
        "        or isinstance(value, Mapping)\n" ++
        "        # only do immutabledict\n" ++
        "    )\n";

    const commented_wanted = "x = Annotated[\n" ++
        "    TV, mapped_column(info={\"hi\": \"there\"})  # type: ignore\n" ++
        "]\n" ++
        "\n" ++
        "\n" ++
        "def f(value):\n" ++
        "    return (\n" ++
        "        isinstance(value, dict) or isinstance(value, Mapping)\n" ++
        "        # only do immutabledict\n" ++
        "    )\n";

    try expect_held(logic_source, logic_wanted);
    try expect_held(logic_wanted, logic_wanted);
    try expect_held(commented_source, commented_wanted);
    try expect_held(commented_wanted, commented_wanted);
}

test "pydantic and fastapi concatenations, stubs and templates format the way ruff does" {
    const concatenated_source = "class A:\n" ++
        "    def test(self):\n" ++
        "        self.assert_compile(\n" ++
        "            schema.CreateTable(t),\n" ++
        "            \"CREATE TABLE t (x INTEGER, y INTEGER GENERATED \"\n" ++
        "            \"ALWAYS AS (x + 2)%s)\" % text,\n" ++
        "        )\n";

    const concatenated_wanted = "class A:\n" ++
        "    def test(self):\n" ++
        "        self.assert_compile(\n" ++
        "            schema.CreateTable(t),\n" ++
        "            \"CREATE TABLE t (x INTEGER, y INTEGER GENERATED \"\n" ++
        "            \"ALWAYS AS (x + 2)%s)\" % text,\n" ++
        "        )\n";

    const stubbed_source = "class A: ...\n" ++
        "class B: ...\n" ++
        "\n" ++
        "\n" ++
        "def f():\n" ++
        "    sub = (\n" ++
        "        Sub.model_construct()\n" ++
        "    )  # Create a Sub instance without triggering validation (e.g., using model_constru" ++
        "ct)\n" ++
        "    required_label_name = effective_name = (\n" ++
        "        fallback_label_name\n" ++
        "    ) = c._tq_label_xxxxxxxxxxxxxxxxxxxx\n";

    const stubbed_wanted = "class A: ...\n" ++
        "\n" ++
        "\n" ++
        "class B: ...\n" ++
        "\n" ++
        "\n" ++
        "def f():\n" ++
        "    sub = Sub.model_construct()  # Create a Sub instance without triggering validation " ++
        "(e.g., using model_construct)\n" ++
        "    required_label_name = effective_name = fallback_label_name = (\n" ++
        "        c._tq_label_xxxxxxxxxxxxxxxxxxxx\n" ++
        "    )\n";

    const templated_source = "a = call(\n" ++
        "    t\"SELECT id, name FROM users WHERE id >= {min_id} \"\n" ++
        "    t\"AND id <= {max_id}\"\n" ++
        ")\n" ++
        "b = call(t\"a {x!r:>{w}} \" t\"b {y}\")\n";

    const templated_wanted = "a = call(t\"SELECT id, name FROM users WHERE id >= {min_id} AND id" ++
        " <= {max_id}\")\n" ++
        "b = call(t\"a {x!r:>{w}} b {y}\")\n";

    try expect_held(concatenated_source, concatenated_wanted);
    try expect_held(concatenated_wanted, concatenated_wanted);
    try expect_held(stubbed_source, stubbed_wanted);
    try expect_held(stubbed_wanted, stubbed_wanted);
    try expect_held(templated_source, templated_wanted);
    try expect_held(templated_wanted, templated_wanted);
}

test "pydantic and fastapi yields format the way ruff does and hold their output" {
    const yielded_source = "def f():\n" ++
        "    if a:\n" ++
        "        if b:\n" ++
        "            if c:\n" ++
        "                if d:\n" ++
        "                    yield stub_parameter_stub_arg_variable_name_is_not_keyword_onlyxxxx" ++
        "xx\n" ++
        "                    yield stub_parameter.stub_arg_variable_name.is_not_keyword_onlyxxxx" ++
        "x\n" ++
        "                    yield stub_parameter_stub_arg + variable_name_is_not_keyword_onlyxx" ++
        "xx\n" ++
        "                    yield stub_parameter_stub_arg(variable_name_is_not_keyword_onlyxxxx" ++
        "x)\n" ++
        "                    yield stub_parameter.stub_arg_variable_name.is_not_keyword_onlyxx()" ++
        "\n" ++
        "                    x = yield \"stub parameter {stub_arg.variable.name} is not keyword-" ++
        "only\"\n";

    const yielded_wanted = "def f():\n" ++
        "    if a:\n" ++
        "        if b:\n" ++
        "            if c:\n" ++
        "                if d:\n" ++
        "                    yield stub_parameter_stub_arg_variable_name_is_not_keyword_onlyxxxx" ++
        "xx\n" ++
        "                    yield stub_parameter.stub_arg_variable_name.is_not_keyword_onlyxxxx" ++
        "x\n" ++
        "                    yield (\n" ++
        "                        stub_parameter_stub_arg + variable_name_is_not_keyword_onlyxxxx" ++
        "\n" ++
        "                    )\n" ++
        "                    yield stub_parameter_stub_arg(\n" ++
        "                        variable_name_is_not_keyword_onlyxxxxx\n" ++
        "                    )\n" ++
        "                    yield stub_parameter.stub_arg_variable_name.is_not_keyword_onlyxx()" ++
        "\n" ++
        "                    x = yield \"stub parameter {stub_arg.variable.name} is not keyword-" ++
        "only\"\n";

    try expect_held(yielded_source, yielded_wanted);
    try expect_held(yielded_wanted, yielded_wanted);
}

test "pydantic and fastapi with items format the way ruff does and hold their output" {
    const withed_source = "def f(self):\n" ++
        "    with get_handle(\n" ++
        "        self._fname,\n" ++
        "        \"wb\",\n" ++
        "        compression=self._compression,\n" ++
        "    ) as self.handles:\n" ++
        "        pass\n" ++
        "def f(self):\n" ++
        "    with (\n" ++
        "        get_handle(\n" ++
        "            self._fname,\n" ++
        "            \"wb\",\n" ++
        "        ) as self.handles\n" ++
        "    ):\n" ++
        "        pass\n" ++
        "    with open_the_file_with_a_long_name(path_to_the_file_xxxxxxxxxxxxxxxxxxxxx) as hand" ++
        "le_name:\n" ++
        "        pass\n" ++
        "    with a.b.c.d.eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" ++
        "eeeeeeeeeee as x:\n" ++
        "        pass\n" ++
        "    with aaaaaaaaaaaaaaaaaaaaaaaaaaa + bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb(ccccccc" ++
        "cccccc) as x:\n" ++
        "        pass\n" ++
        "    if x:\n" ++
        "        with autocommit_iso_logging_engine.execution_options(\n" ++
        "            isolation_level=testing.db.dialect.default_isolation_level\n" ++
        "        ).connect() as conn:\n" ++
        "            conn.begin()\n";

    const withed_wanted = "def f(self):\n" ++
        "    with get_handle(\n" ++
        "        self._fname,\n" ++
        "        \"wb\",\n" ++
        "        compression=self._compression,\n" ++
        "    ) as self.handles:\n" ++
        "        pass\n" ++
        "\n" ++
        "\n" ++
        "def f(self):\n" ++
        "    with get_handle(\n" ++
        "        self._fname,\n" ++
        "        \"wb\",\n" ++
        "    ) as self.handles:\n" ++
        "        pass\n" ++
        "    with open_the_file_with_a_long_name(\n" ++
        "        path_to_the_file_xxxxxxxxxxxxxxxxxxxxx\n" ++
        "    ) as handle_name:\n" ++
        "        pass\n" ++
        "    with (\n" ++
        "        a.b.c.d.eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" ++
        "eeeeeeeeee as x\n" ++
        "    ):\n" ++
        "        pass\n" ++
        "    with aaaaaaaaaaaaaaaaaaaaaaaaaaa + bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb(\n" ++
        "        ccccccccccccc\n" ++
        "    ) as x:\n" ++
        "        pass\n" ++
        "    if x:\n" ++
        "        with autocommit_iso_logging_engine.execution_options(\n" ++
        "            isolation_level=testing.db.dialect.default_isolation_level\n" ++
        "        ).connect() as conn:\n" ++
        "            conn.begin()\n";

    try expect_held(withed_source, withed_wanted);
    try expect_held(withed_wanted, withed_wanted);
}

test "a parenthesized string value keeps the string statement after it apart" {
    const gpa = std.testing.allocator;

    const source = "JsonValue: TypeAlias = 'list[JsonValue] | dict[str, JsonValue] | str | bo" ++
        "ol | int | float | None'\n" ++
        "\"\"\"A `JsonValue` is used to represent a value that can be serialized to JSON.\"\"\"\n";

    const wanted = "JsonValue: TypeAlias = (\n" ++
        "    \"list[JsonValue] | dict[str, JsonValue] | str | bool | int | float | None\"\n" ++
        ")\n" ++
        "\"\"\"A `JsonValue` is used to represent a value that can be serialized to JSON.\"\"\"\n";

    const fixture: Fixture = .{ .name = "aliased.py", .source = source };
    var worker: RelationsWorker = undefined;

    try worker.init(gpa, &.{});
    defer worker.deinit(gpa);

    var tally: RelationsWorker.Tally = .{ .formatted = 0, .refused = 0 };

    try expect_held(source, wanted);
    try worker.visit(&fixture, &tally);
    try std.testing.expectEqual(1, tally.formatted);
    try std.testing.expectEqual(0, tally.refused);
}

test "an implicit concatenation keeps its parts where a comment holds them" {
    const trailed_source = "x = (\n" ++
        "    \"aaa\"\n" ++
        "    \"bbb\"  # c\n" ++
        ")\n";

    const trailed_wanted = "x = (\n" ++
        "    \"aaa\"\n" ++
        "    \"bbb\"  # c\n" ++
        ")\n";

    const crossed_source = "u = (\n" ++
        "    \"aaa\"\n" ++
        "    \"bbb\"\n" ++
        "    \"ccc\"  # c\n" ++
        "    \"ddd\"\n" ++
        ")\n";

    const crossed_wanted = "u = (\n" ++
        "    \"aaa\"\n" ++
        "    \"bbb\"\n" ++
        "    \"ccc\"  # c\n" ++
        "    \"ddd\"\n" ++
        ")\n";

    try expect_held(trailed_source, trailed_wanted);
    try expect_held(trailed_wanted, trailed_wanted);
    try expect_held(crossed_source, crossed_wanted);
    try expect_held(crossed_wanted, crossed_wanted);
}

test "an implicit concatenation in a call or a list keeps its parts where a comment holds them" {
    const argued_source = "f(\n" ++
        "    a,\n" ++
        "    \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"\n" ++
        "    \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"  # c\n" ++
        ")\n";

    const argued_wanted = "f(\n" ++
        "    a,\n" ++
        "    \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"\n" ++
        "    \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",  # c\n" ++
        ")\n";

    const listed_source = "x = [\n" ++
        "    \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"\n" ++
        "    \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"  # c\n" ++
        "]\n";

    const listed_wanted = "x = [\n" ++
        "    \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"\n" ++
        "    \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"  # c\n" ++
        "]\n";

    const commented_source = "def f():\n" ++
        "    g(\n" ++
        "        a,  # xx\n" ++
        "        \"NOT (EXISTS (SELECT 1 FROM nodes AS nodes_1 \"\n" ++
        "        \"WHERE nodes.id = nodes_1.parent_id)) aaaaaaaaaaaaaaaa\",\n" ++
        "        b,\n" ++
        "    )\n";

    const commented_wanted = "def f():\n" ++
        "    g(\n" ++
        "        a,  # xx\n" ++
        "        \"NOT (EXISTS (SELECT 1 FROM nodes AS nodes_1 \"\n" ++
        "        \"WHERE nodes.id = nodes_1.parent_id)) aaaaaaaaaaaaaaaa\",\n" ++
        "        b,\n" ++
        "    )\n";

    try expect_held(argued_source, argued_wanted);
    try expect_held(argued_wanted, argued_wanted);
    try expect_held(listed_source, listed_wanted);
    try expect_held(listed_wanted, listed_wanted);
    try expect_held(commented_source, commented_wanted);
    try expect_held(commented_wanted, commented_wanted);
}

test "a format string field that spans lines keeps its comments and specs the way ruff writes it" {
    const commented_source = "x = f\"\"\"{\n" ++
        "    a  # c\n" ++
        "}\"\"\"\n";

    const commented_wanted = "x = f\"\"\"{\n" ++
        "    a  # c\n" ++
        "}\"\"\"\n";

    const riding_source = "x = f\"\"\"{  # c\n" ++
        "    a\n" ++
        "}\"\"\"\n";

    const riding_wanted = "x = f\"\"\"{  # c\n" ++
        "    a\n" ++
        "}\"\"\"\n";

    const specced_source = "x = f\"\"\"{a:>10\n" ++
        "}\"\"\"\n";

    const specced_wanted = "x = f\"\"\"{\n" ++
        "    a:>10\n" ++
        "}\"\"\"\n";

    const converted_source = "x = f\"\"\"{\n" ++
        "    a!r\n" ++
        "}\"\"\"\n";

    const converted_wanted = "x = f\"\"\"{a!r}\"\"\"\n";

    const argued_source = "call(f\"\"\"abc {\n" ++
        "    xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
        "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n" ++
        "}\"\"\")\n";

    const argued_wanted = "call(\n" ++
        "    f\"\"\"abc {\n" ++
        "        xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
        "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n" ++
        "    }\"\"\"\n" ++
        ")\n";

    const hugged_source = "call(f\"\"\"abc {\n" ++
        "    x\n" ++
        "}\"\"\")\n";

    const hugged_wanted = "call(f\"\"\"abc {x}\"\"\")\n";

    try expect_held(commented_source, commented_wanted);
    try expect_held(commented_wanted, commented_wanted);
    try expect_held(riding_source, riding_wanted);
    try expect_held(riding_wanted, riding_wanted);
    try expect_held(specced_source, specced_wanted);
    try expect_held(specced_wanted, specced_wanted);
    try expect_held(converted_source, converted_wanted);
    try expect_held(converted_wanted, converted_wanted);
    try expect_held(argued_source, argued_wanted);
    try expect_held(argued_wanted, argued_wanted);
    try expect_held(hugged_source, hugged_wanted);
    try expect_held(hugged_wanted, hugged_wanted);
}

test "a format string field that spans lines joins or holds the way ruff writes it" {
    const assigned_source = "variable_name = f\"\"\"a fairly long literal prefix that tak" ++
        "es room {\n" ++
        "    {\"a\": 1}[\"a\"]\n" ++
        "} suffix\"\"\"\n";

    const assigned_wanted = "variable_name = (\n" ++
        "    f\"\"\"a fairly long literal prefix that takes room { {" ++
        "\"a\": 1}[\"a\"] } suffix\"\"\"\n" ++
        ")\n";

    const overlong_source = "variable_name = f\"\"\"a fairly long literal prefix that tak" ++
        "es room {\n" ++
        "    {\"a\": 1}[\"a\"]\n" ++
        "} suffix and a lot more text that will never fit in any widt" ++
        "h at all\"\"\"\n";

    const overlong_wanted = "variable_name = f\"\"\"a fairly long literal prefix that tak" ++
        "es room {\n" ++
        "    {\"a\": 1}[\"a\"]\n" ++
        "} suffix and a lot more text that will never fit in any widt" ++
        "h at all\"\"\"\n";

    const braced_source = "x = f\"{ {1: 2}[1]}\"\n";
    const braced_wanted = "x = f\"{ {1: 2}[1] }\"\n";
    const summed_source = "x = f\"{x + {1}}\"\n";
    const summed_wanted = "x = f\"{x + {1}}\"\n";
    const tupled_source = "x = f\"{ {1},}\"\n";
    const tupled_wanted = "x = f\"{({1},)}\"\n";

    const nested_source = "x = f\"\"\"head {g('''\n" ++
        "z''')} mid\"\"\"\n";

    const nested_wanted = "x = f\"\"\"head {\n" ++
        "    g('''\n" ++
        "z''')\n" ++
        "} mid\"\"\"\n";

    try expect_held(assigned_source, assigned_wanted);
    try expect_held(assigned_wanted, assigned_wanted);
    try expect_held(overlong_source, overlong_wanted);
    try expect_held(overlong_wanted, overlong_wanted);
    try expect_held(braced_source, braced_wanted);
    try expect_held(braced_wanted, braced_wanted);
    try expect_held(summed_source, summed_wanted);
    try expect_held(summed_wanted, summed_wanted);
    try expect_held(tupled_source, tupled_wanted);
    try expect_held(tupled_wanted, tupled_wanted);
    try expect_held(nested_source, nested_wanted);
    try expect_held(nested_wanted, nested_wanted);
}

test "a format string field that spans lines in a raise or return is a group ruff writes" {
    const raised_source = "class C:\n" ++
        "    def f(self):\n" ++
        "        if x:\n" ++
        "            raise Error(f\"\"\"message {\"the values returne" ++
        "d appear to be\" if uncertain else \"this datatype produces" ++
        "\"\n" ++
        "} end\"\"\")\n";

    const raised_wanted = "class C:\n" ++
        "    def f(self):\n" ++
        "        if x:\n" ++
        "            raise Error(\n" ++
        "                f\"\"\"message {\n" ++
        "                    \"the values returned appear to be\"\n" ++
        "                    if uncertain\n" ++
        "                    else \"this datatype produces\"\n" ++
        "                } end\"\"\"\n" ++
        "            )\n";

    const returned_source = "def f():\n" ++
        "    return f\"\"\"{\n" ++
        "    self.dialect.type_compiler_instance.process(dbapi_type, " ++
        "identifier_preparer=self.preparer)\n" ++
        "}\"\"\"\n";

    const returned_wanted = "def f():\n" ++
        "    return f\"\"\"{\n" ++
        "        self.dialect.type_compiler_instance.process(\n" ++
        "            dbapi_type, identifier_preparer=self.preparer\n" ++
        "        )\n" ++
        "    }\"\"\"\n";

    try expect_held(raised_source, raised_wanted);
    try expect_held(raised_wanted, raised_wanted);
    try expect_held(returned_source, returned_wanted);
    try expect_held(returned_wanted, returned_wanted);
}

test "a format string that heads a statement keeps its trailers" {
    try expect_held(
        "f'{a}'(x)\nf'{a=}'(2.5 for x in b)\nf'{a}'.b(c)\nf'{a}'[0]\nf'{a}' (x)\nf'{a}'(\n    x)\n",
        "f\"{a}\"(x)\nf\"{a=}\"(2.5 for x in b)\nf\"{a}\".b(c)\nf\"{a}\"[0]\n" ++
            "f\"{a}\"(x)\nf\"{a}\"(x)\n",
    );
}

test "an operator ahead of a commented operand stands alone in any element" {
    const comprehended_source = "x = [\n" ++
        "    aaaa or\n" ++
        "    # comment\n" ++
        "    bbbb\n" ++
        "    for a in b\n" ++
        "]\n";

    const comprehended_wanted = "x = [\n" ++
        "    aaaa\n" ++
        "    or\n" ++
        "    # comment\n" ++
        "    bbbb\n" ++
        "    for a in b\n" ++
        "]\n";

    const tupled_source = "x = (\n" ++
        "    aaaa or\n" ++
        "    # comment\n" ++
        "    bbbb,\n" ++
        "    cccc\n" ++
        ")\n";

    const tupled_wanted = "x = (\n" ++
        "    aaaa\n" ++
        "    or\n" ++
        "    # comment\n" ++
        "    bbbb,\n" ++
        "    cccc,\n" ++
        ")\n";

    const tested_source = "x = (\n" ++
        "    aaaa if bbbb or\n" ++
        "    # comment\n" ++
        "    dddd else cccc\n" ++
        ")\n";

    const tested_wanted = "x = (\n" ++
        "    aaaa\n" ++
        "    if bbbb\n" ++
        "    or\n" ++
        "    # comment\n" ++
        "    dddd\n" ++
        "    else cccc\n" ++
        ")\n";

    try expect_held(comprehended_source, comprehended_wanted);
    try expect_held(comprehended_wanted, comprehended_wanted);
    try expect_held(tupled_source, tupled_wanted);
    try expect_held(tupled_wanted, tupled_wanted);
    try expect_held(tested_source, tested_wanted);
    try expect_held(tested_wanted, tested_wanted);
}

test "a conditional keyword follows the comments its operand leads" {
    const tested_source = "x = (\n" ++
        "    aaaa if\n" ++
        "    # comment\n" ++
        "    bbbb else cccc\n" ++
        ")\n";

    const tested_wanted = "x = (\n" ++
        "    aaaa\n" ++
        "    # comment\n" ++
        "    if bbbb\n" ++
        "    else cccc\n" ++
        ")\n";

    const otherwise_source = "x = (\n" ++
        "    aaaa if bbbb else\n" ++
        "    # comment\n" ++
        "    cccc\n" ++
        ")\n";

    const otherwise_wanted = "x = (\n" ++
        "    aaaa\n" ++
        "    if bbbb\n" ++
        "    # comment\n" ++
        "    else cccc\n" ++
        ")\n";

    const riding_source = "x = (\n" ++
        "    aaaa if  # comment\n" ++
        "    bbbb else cccc\n" ++
        ")\n";

    const riding_wanted = "x = (\n" ++
        "    aaaa\n" ++
        "    # comment\n" ++
        "    if bbbb\n" ++
        "    else cccc\n" ++
        ")\n";

    try expect_held(tested_source, tested_wanted);
    try expect_held(tested_wanted, tested_wanted);
    try expect_held(otherwise_source, otherwise_wanted);
    try expect_held(otherwise_wanted, otherwise_wanted);
    try expect_held(riding_source, riding_wanted);
    try expect_held(riding_wanted, riding_wanted);
}

test "a conditional keyword follows stacked comments and comments within a call argument" {
    const stacked_source = "x = (\n" ++
        "    aaaa if  # first\n" ++
        "    # second\n" ++
        "    bbbb else cccc\n" ++
        ")\n";

    const stacked_wanted = "x = (\n" ++
        "    aaaa\n" ++
        "    # first\n" ++
        "    # second\n" ++
        "    if bbbb\n" ++
        "    else cccc\n" ++
        ")\n";

    const argued_source = "call(\n" ++
        "    aaaa if\n" ++
        "    # comment\n" ++
        "    bbbb else cccc,\n" ++
        "    eeee,\n" ++
        ")\n";

    const argued_wanted = "call(\n" ++
        "    aaaa\n" ++
        "    # comment\n" ++
        "    if bbbb\n" ++
        "    else cccc,\n" ++
        "    eeee,\n" ++
        ")\n";

    try expect_held(stacked_source, stacked_wanted);
    try expect_held(stacked_wanted, stacked_wanted);
    try expect_held(argued_source, argued_wanted);
    try expect_held(argued_wanted, argued_wanted);
}

test "a parenthesized subscript at either end of an expression is no pair to split" {
    const source_last = "def f():\n" ++
        "    if x:\n" ++
        "        result_value_name = None | (tuple[list[str]," ++
        " list[Type], list[Expression], str, list[TypeVarLikeType]])\n";

    const wanted_last = "def f():\n" ++
        "    if x:\n" ++
        "        result_value_name = (\n" ++
        "            None\n" ++
        "            | (\n" ++
        "                tuple[\n" ++
        "                    list[str], list[Type]," ++
        " list[Expression], str, list[TypeVarLikeType]\n" ++
        "                ]\n" ++
        "            )\n" ++
        "        )\n";

    const source_first = "def f():\n" ++
        "    if x:\n" ++
        "        result_value_name = (tuple[list[str], list[Type]," ++
        " list[Expression], str, list[TypeVarLikeType]]) | None\n";

    const wanted_first = "def f():\n" ++
        "    if x:\n" ++
        "        result_value_name = (\n" ++
        "            (tuple[list[str], list[Type], list[Expression]," ++
        " str, list[TypeVarLikeType]])\n" ++
        "            | None\n" ++
        "        )\n";

    const bare_source = "def f() -> None | (tuple[list[str], list[Type]," ++
        " list[Expression], str, list[TypeVarLikeType], bool]):\n" ++
        "    pass\n";

    const bare_wanted = "def f() -> (\n" ++
        "    None\n" ++
        "    | (tuple[list[str], list[Type], list[Expression], str," ++
        " list[TypeVarLikeType], bool])\n" ++
        "):\n" ++
        "    pass\n";

    const called_source = "def f(\n" ++
        "    a,\n" ++
        ") -> function_call(list[str], list[Type], list[Expression]," ++
        " str, list[TypeVarLike]) | None:\n" ++
        "    pass\n";

    const called_wanted = "def f(\n" ++
        "    a,\n" ++
        ") -> (\n" ++
        "    function_call(list[str], list[Type], list[Expression]," ++
        " str, list[TypeVarLike])\n" ++
        "    | None\n" ++
        "):\n" ++
        "    pass\n";

    try expect_held(source_last, wanted_last);
    try expect_held(wanted_last, wanted_last);
    try expect_held(source_first, wanted_first);
    try expect_held(wanted_first, wanted_first);
    try expect_held(bare_source, bare_wanted);
    try expect_held(bare_wanted, bare_wanted);
    try expect_held(called_source, called_wanted);
    try expect_held(called_wanted, called_wanted);
}

test "a name return annotation takes the pair its trailing comment needs" {
    const stubbed_source = "class BasePattern:\n" ++
        "    def optimize(self) -> BasePattern: ...  # sic," ++
        " subclasses are free to optimize themselves into different" ++
        " patterns\n";

    const stubbed_wanted = "class BasePattern:\n" ++
        "    def optimize(\n" ++
        "        self,\n" ++
        "    ) -> (\n" ++
        "        BasePattern\n" ++
        "    ): ...  # sic, subclasses are free to optimize" ++
        " themselves into different patterns\n";

    const commented_source = "class BasePattern:\n" ++
        "    def optimize(self) -> BasePattern:  # sic, subclasses" ++
        " are free to optimize themselves into different patterns\n" ++
        "        pass\n";

    const commented_wanted = "class BasePattern:\n" ++
        "    def optimize(\n" ++
        "        self,\n" ++
        "    ) -> (\n" ++
        "        BasePattern\n" ++
        "    ):  # sic, subclasses are free to optimize themselves" ++
        " into different patterns\n" ++
        "        pass\n";

    const overlong_source = "class A:\n" ++
        "    def optimize(self) -> BasePattern:  # sic, subclasses" ++
        " are free to optimize themselves into differe more\n" ++
        "        pass\n";

    const overlong_wanted = "class A:\n" ++
        "    def optimize(\n" ++
        "        self,\n" ++
        "    ) -> (\n" ++
        "        BasePattern\n" ++
        "    ):  # sic, subclasses are free to optimize themselves" ++
        " into differe more\n" ++
        "        pass\n";

    const named_source = "class A:\n" ++
        "    def optimize(self) ->" ++
        " AbcdefghijAbcdefghijAbcdefghijAbcdefghijAbcdefghijAbcdefghi" ++
        "jAbcdefghijAbcdefghi:\n" ++
        "        pass\n";

    const named_wanted = "class A:\n" ++
        "    def optimize(\n" ++
        "        self,\n" ++
        "    ) -> (\n" ++
        "        AbcdefghijAbcdefghijAbcdefghijAbcdefghijAbcdefghijAb" ++
        "cdefghijAbcdefghijAbcdefghi\n" ++
        "    ):\n" ++
        "        pass\n";

    try expect_held_as(stubbed_source, stubbed_wanted, true);
    try expect_held_as(stubbed_wanted, stubbed_wanted, true);
    try expect_held(commented_source, commented_wanted);
    try expect_held(commented_wanted, commented_wanted);
    try expect_held(overlong_source, overlong_wanted);
    try expect_held(overlong_wanted, overlong_wanted);
    try expect_held(named_source, named_wanted);
    try expect_held(named_wanted, named_wanted);
}

test "comments inside a comprehension, argument, key or lambda break the levels ruff expands" {
    const comprehended_source = "def f(arrs):\n" ++
        "    return [\n" ++
        "        arr\n" ++
        "        if len(arr.categories)  # c\n" ++
        "        else b\n" ++
        "        for arr in arrs\n" ++
        "    ]\n";

    const comprehended_wanted = "def f(arrs):\n" ++
        "    return [\n" ++
        "        arr\n" ++
        "        if len(arr.categories)  # c\n" ++
        "        else b\n" ++
        "        for arr in arrs\n" ++
        "    ]\n";

    const argued_source = "foo(\n" ++
        "    aaa\n" ++
        "    + bbb  # c\n" ++
        "    + ccc,\n" ++
        "    d,\n" ++
        ")\n";

    const argued_wanted = "foo(\n" ++
        "    aaa\n" ++
        "    + bbb  # c\n" ++
        "    + ccc,\n" ++
        "    d,\n" ++
        ")\n";

    const keyed_source = "expected_output = {\n" ++
        "    (0, 6): \"           col1\\n\"\n" ++
        "    \"0  9.999000e-08\\n\"\n" ++
        "    \"1  1.000000e-07\\n\"\n" ++
        "    \"2  1.000100e-07\\n\"\n" ++
        "    \"3  2.000000e-07\\n\",\n" ++
        "}\n";

    const keyed_wanted = "expected_output = {\n" ++
        "    (0, 6): \"           col1\\n\"\n" ++
        "    \"0  9.999000e-08\\n\"\n" ++
        "    \"1  1.000000e-07\\n\"\n" ++
        "    \"2  1.000100e-07\\n\"\n" ++
        "    \"3  2.000000e-07\\n\",\n" ++
        "}\n";

    const lambdaed_source = "x = (\n" ++
        "    lambda q: aaa  # c\n" ++
        "    + bbb\n" ++
        ")\n";

    const lambdaed_wanted = "x = lambda q: (\n" ++
        "    aaa  # c\n" ++
        "    + bbb\n" ++
        ")\n";

    try expect_held(comprehended_source, comprehended_wanted);
    try expect_held(comprehended_wanted, comprehended_wanted);
    try expect_held(argued_source, argued_wanted);
    try expect_held(argued_wanted, argued_wanted);
    try expect_held(keyed_source, keyed_wanted);
    try expect_held(keyed_wanted, keyed_wanted);
    try expect_held(lambdaed_source, lambdaed_wanted);
    try expect_held(lambdaed_wanted, lambdaed_wanted);
}

test "joins inside a nested call, display, chain or operand break the levels ruff expands" {
    const nested_source = "x = (\n" ++
        "    foo(\n" ++
        "        aaa,  # c\n" ++
        "        bbb,\n" ++
        "    )\n" ++
        ")\n";

    const nested_wanted = "x = foo(\n" ++
        "    aaa,  # c\n" ++
        "    bbb,\n" ++
        ")\n";

    const displayed_source = "add_froms = {f for f in new_froms.values() if isinstance(f," ++
        " Join)}.difference(all_the_froms).difference(existing_from_obj)\n";

    const displayed_wanted = "add_froms = {f for f in new_froms.values() if isinstance(f," ++
        " Join)}.difference(\n" ++
        "    all_the_froms\n" ++
        ").difference(existing_from_obj)\n";

    const fluent_source = "foo(\n" ++
        "    sess.query(T).filter(T.value == True)  # noqa\n" ++
        "    .order_by(T.id).all(),\n" ++
        ")\n";

    const fluent_wanted = "foo(\n" ++
        "    sess.query(T)\n" ++
        "    .filter(T.value == True)  # noqa\n" ++
        "    .order_by(T.id)\n" ++
        "    .all(),\n" ++
        ")\n";

    const commented_source = "x = (\n" ++
        "    aaa\n" ++
        "    or (  # short\n" ++
        "        bbb\n" ++
        "        and ccc\n" ++
        "    )\n" ++
        ")\n";

    const commented_wanted = "x = aaa or (  # short\n" ++
        "    bbb and ccc\n" ++
        ")\n";

    try expect_held(nested_source, nested_wanted);
    try expect_held(nested_wanted, nested_wanted);
    try expect_held(displayed_source, displayed_wanted);
    try expect_held(displayed_wanted, displayed_wanted);
    try expect_held(fluent_source, fluent_wanted);
    try expect_held(fluent_wanted, fluent_wanted);
    try expect_held(commented_source, commented_wanted);
    try expect_held(commented_wanted, commented_wanted);
}
