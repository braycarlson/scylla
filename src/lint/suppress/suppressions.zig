const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const Language = @import("../../syntax/language.zig").Language;
const Span = @import("../../stdx/bounded/span.zig");
const StaticAllocator = @import("../../stdx/static_allocator.zig");
const Token = @import("../../syntax/token.zig");
const Tokens = @import("../../syntax/tokens.zig");
const byte_at = @import("../../text/scan.zig").byte_at;
const is_ascii_whitespace = @import("../../text/scan.zig").is_ascii_whitespace;
const lex = @import("../../syntax/lex.zig").lex;
const LineIndex = @import("../../text/line_index.zig").LineIndex;
const markup = @import("../../syntax/markup.zig");
const trivia = @import("../../syntax/trivia.zig");

codes: ArrayType(Span),
consumed: ArrayType(bool),
file: ArrayType(u32),
items: ArrayType(Directive),
placed: ArrayType(u32),
runs: ArrayType(Joined),

const Suppressions = @This();

pub const Capacity = struct {
    code_count_max: u32,
    directive_count_max: u32,
};

pub const CapacityError = error{ CodesExhausted, DirectivesExhausted, RunsExhausted };

pub const Directive = struct {
    blanket: bool,
    code_count: u32,
    code_start: u32,
    line: u32,
    span: Span,
};

pub const Joined = struct {
    line_first: u32,
    line_last: u32,
};

pub const Unconsumed = struct {
    index: u32,
    remaining: u32,
    suppressions: *const Suppressions,

    pub fn next(iterator: *Unconsumed) ?u32 {
        const total = iterator.suppressions.count();

        assert(iterator.index <= total);
        assert(iterator.remaining <= total);

        if (iterator.remaining == 0) return null;

        const consumed = iterator.suppressions.consumed.const_slice();

        for (iterator.index..total) |position| {
            iterator.index = @intCast(position + 1);

            if (!consumed[position]) {
                iterator.remaining -= 1;

                assert(position < std.math.maxInt(u32));

                return @intCast(position);
            }
        }

        iterator.index = total;

        assert(iterator.index == total);

        return null;
    }
};

const Reading = struct {
    blanket: bool,
    end: u32,
    invalid: bool,
    overflowed: bool,
};

const Run = union(enum) {
    code: Span,
    malformed,
    prose,
};

const file_line: u32 = std.math.maxInt(u32) - 1;

pub fn init(gpa: std.mem.Allocator, capacity: Capacity) std.mem.Allocator.Error!Suppressions {
    assert(capacity.directive_count_max > 0);
    assert(capacity.code_count_max > 0);

    var codes: ArrayType(Span) = try .init(gpa, capacity.code_count_max);
    errdefer codes.deinit(gpa);

    var consumed: ArrayType(bool) = try .init(gpa, capacity.directive_count_max);
    errdefer consumed.deinit(gpa);

    var file: ArrayType(u32) = try .init(gpa, capacity.directive_count_max);
    errdefer file.deinit(gpa);

    var items: ArrayType(Directive) = try .init(gpa, capacity.directive_count_max);
    errdefer items.deinit(gpa);

    var placed: ArrayType(u32) = try .init(gpa, capacity.directive_count_max);
    errdefer placed.deinit(gpa);

    const runs: ArrayType(Joined) = try .init(gpa, capacity.directive_count_max);

    assert(items.capacity() == capacity.directive_count_max);
    assert(codes.capacity() == capacity.code_count_max);

    return .{
        .codes = codes,
        .consumed = consumed,
        .file = file,
        .items = items,
        .placed = placed,
        .runs = runs,
    };
}

pub fn deinit(suppressions: *Suppressions, gpa: std.mem.Allocator) void {
    assert(suppressions.items.count() == suppressions.consumed.count());
    assert(suppressions.items.count() == suppressions.placed.count());

    suppressions.codes.deinit(gpa);
    suppressions.consumed.deinit(gpa);
    suppressions.file.deinit(gpa);
    suppressions.items.deinit(gpa);
    suppressions.placed.deinit(gpa);
    suppressions.runs.deinit(gpa);
    suppressions.* = undefined;
}

pub fn clear(suppressions: *Suppressions) void {
    suppressions.codes.clear();
    suppressions.consumed.clear();
    suppressions.file.clear();
    suppressions.items.clear();
    suppressions.placed.clear();
    suppressions.runs.clear();

    assert(suppressions.count() == 0);
    assert(suppressions.runs.empty());
}

pub fn scan(
    suppressions: *Suppressions,
    source: []const u8,
    comments: []const Span,
    word: []const u8,
    file_prefixes: []const []const u8,
    index: *const LineIndex,
) CapacityError!void {
    assert(word.len > 0);
    assert(index.count() > 0);
    assert(source.len <= std.math.maxInt(u32));
    assert(comments.len <= std.math.maxInt(u32));
    assert(file_prefixes.len <= std.math.maxInt(u32));

    suppressions.clear();

    for (comments) |comment| {
        assert(comment.end() <= source.len);

        const start = word_in(source, comment, word, file_prefixes) orelse continue;

        if (suppressions.items.full()) return error.DirectivesExhausted;

        const after = start + @as(u32, @intCast(word.len));
        const reading = suppressions.scan_read_codes(source, comment, after);
        if (reading.invalid) continue;

        const file_wide = file_prefixed(source, comment, start, file_prefixes);

        assert(reading.end <= comment.end());

        suppressions.scan_record(start, &reading, index.line_of(start), file_wide);

        if (reading.overflowed) return error.CodesExhausted;
    }

    assert(suppressions.count() <= comments.len);
}

pub fn matches(
    suppressions: *const Suppressions,
    line: u32,
    code: []const u8,
    source: []const u8,
) ?u32 {
    assert(code.len > 0);
    assert(source.len <= std.math.maxInt(u32));
    assert(line < std.math.maxInt(u32));

    for (suppressions.file.const_slice()) |directive| {
        if (suppressions.matches_covers(directive, code, source)) return directive;
    }

    const target = suppressions.matches_joined_of(line);
    const from = suppressions.matches_placed_from(target);
    const placed = suppressions.placed.const_slice();
    const items = suppressions.items.const_slice();

    for (from..items.len) |position| {
        if (placed[position] != target) break;
        if (items[position].line != target) continue;

        if (suppressions.matches_covers(@intCast(position), code, source)) {
            assert(position < items.len);

            return @intCast(position);
        }
    }

    return null;
}

pub fn join(
    suppressions: *Suppressions,
    source: []const u8,
    tokens: []const Token,
    index: *const LineIndex,
) CapacityError!void {
    assert(source.len <= std.math.maxInt(u32));
    assert(index.count() > 0);
    assert(tokens.len <= std.math.maxInt(u32));

    suppressions.runs.clear();

    for (tokens, 0..) |token, position| {
        if (token.kind == .string) {
            const line_first = index.line_of(token.offset);
            const line_last = index.line_of(token.end() -| 1);

            try suppressions.join_merge(line_first, line_last);
        }

        if (position + 1 >= tokens.len) continue;

        const next = tokens[position + 1];

        try suppressions.join_continuations(source, index, token.end(), next.offset);
    }

    assert(suppressions.runs.count() <= suppressions.runs.capacity());
}

pub fn joined(suppressions: *const Suppressions) []const Joined {
    const held = suppressions.runs.const_slice();

    assert(held.len <= suppressions.runs.capacity());
    assert(suppressions.runs.capacity() == suppressions.items.capacity());

    return held;
}

pub fn at(suppressions: *const Suppressions, index: u32) Directive {
    assert(suppressions.items.count() <= suppressions.items.capacity());
    assert(index < suppressions.count());

    return suppressions.items.get(index);
}

pub fn code_of(suppressions: *const Suppressions, index: u32) Span {
    assert(index < suppressions.codes.count());

    const span = suppressions.codes.get(index);

    assert(span.length > 0);

    return span;
}

pub fn consume(suppressions: *Suppressions, directive: u32) void {
    assert(directive < suppressions.count());

    suppressions.consumed.slice()[directive] = true;

    assert(suppressions.consumed.get(directive));
}

pub fn count(suppressions: *const Suppressions) u32 {
    const held = suppressions.items.count();

    assert(held == suppressions.consumed.count());
    assert(held == suppressions.placed.count());

    return held;
}

pub fn unconsumed(suppressions: *const Suppressions) Unconsumed {
    assert(suppressions.count() <= suppressions.items.capacity());
    assert(suppressions.count() == suppressions.consumed.count());

    return .{ .index = 0, .remaining = suppressions.count(), .suppressions = suppressions };
}

fn join_merge(suppressions: *Suppressions, line_first: u32, line_last: u32) CapacityError!void {
    assert(line_first < std.math.maxInt(u32));
    assert(line_last < std.math.maxInt(u32));

    if (line_last <= line_first) return;

    const runs = suppressions.runs.slice();

    if (runs.len > 0) {
        const held = runs[runs.len - 1];

        if (line_first <= held.line_last) {
            runs[runs.len - 1] = .{
                .line_first = held.line_first,
                .line_last = @max(held.line_last, line_last),
            };

            return;
        }
    }

    if (suppressions.runs.full()) return error.RunsExhausted;

    suppressions.runs.push(.{ .line_first = line_first, .line_last = line_last });

    assert(suppressions.runs.count() > 0);
}

fn join_continuations(
    suppressions: *Suppressions,
    source: []const u8,
    index: *const LineIndex,
    from: u32,
    to: u32,
) CapacityError!void {
    assert(source.len <= std.math.maxInt(u32));
    assert(from < std.math.maxInt(u32));
    assert(to < std.math.maxInt(u32));

    const end = @min(to, @as(u32, @intCast(source.len)));
    if (from >= end) return;

    var offset = from;

    for (from..end) |_| {
        if (offset + 1 >= end) break;

        if (source[offset] != '\\') {
            offset += 1;

            continue;
        }

        const width = continuation_width(source, offset);

        if (width == 0) {
            offset += 1;

            continue;
        }

        const line = index.line_of(offset);

        if (line + 1 < index.count()) try suppressions.join_merge(line, line + 1);

        offset += width;
    }

    assert(offset >= from);
}

fn matches_covers(
    suppressions: *const Suppressions,
    index: u32,
    code: []const u8,
    source: []const u8,
) bool {
    assert(index < std.math.maxInt(u32));
    assert(code.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));

    const directive = suppressions.items.get(index);
    if (directive.blanket) return true;

    const end = directive.code_start + directive.code_count;

    assert(end <= suppressions.codes.count());

    for (suppressions.codes.const_slice()[directive.code_start..end]) |span| {
        if (std.mem.eql(u8, span.text(source), code)) return true;
    }

    return false;
}

fn matches_joined_of(suppressions: *const Suppressions, line: u32) u32 {
    assert(line < std.math.maxInt(u32));

    const runs = suppressions.runs.const_slice();
    const after = std.sort.partitionPoint(Joined, runs, line, joined_starts_at_or_before);
    if (after == 0) return line;

    const held = runs[after - 1];

    assert(held.line_first <= line);
    assert(held.line_first < held.line_last);

    if (line <= held.line_last) return held.line_last;
    return line;
}

fn joined_starts_at_or_before(line: u32, run: Joined) bool {
    return run.line_first <= line;
}

fn matches_placed_from(suppressions: *const Suppressions, line: u32) u32 {
    assert(line < std.math.maxInt(u32));

    const placed = suppressions.placed.const_slice();
    const from = std.sort.partitionPoint(u32, placed, line, placed_before);

    assert(from <= placed.len);

    if (from < placed.len) assert(placed[from] >= line);

    return @intCast(from);
}

fn placed_before(line: u32, placed: u32) bool {
    return placed < line;
}

fn scan_read_codes(
    suppressions: *Suppressions,
    source: []const u8,
    comment: Span,
    after: u32,
) Reading {
    assert(after <= comment.end());
    assert(source.len <= std.math.maxInt(u32));

    const end = comment.end();
    const colon = after < end and source[after] == ':';

    const opened = code_start_of(source, comment, after) orelse {
        return .{ .blanket = true, .end = after, .invalid = false, .overflowed = false };
    };

    const codes_before = suppressions.codes.count();
    var offset = opened;
    var written = opened;

    for (0..comment.length) |_| {
        if (offset >= end) break;

        const byte = source[offset];

        if (byte == ',') {
            offset += 1;

            continue;
        }

        if (is_ascii_whitespace(byte)) {
            offset += 1;

            continue;
        }

        const code = switch (code_at(source, offset, end)) {
            .code => |span| span,
            .prose => break,
            .malformed => {
                suppressions.codes.truncate(codes_before);

                return .{ .blanket = !colon, .end = after, .invalid = colon, .overflowed = false };
            },
        };

        if (suppressions.codes.full()) {
            return .{ .blanket = false, .end = written, .invalid = false, .overflowed = true };
        }

        suppressions.codes.push(code);
        offset = code.end();
        written = code.end();
    }

    const empty = written == opened;
    return .{ .blanket = empty, .end = written, .invalid = colon and empty, .overflowed = false };
}

fn scan_record(
    suppressions: *Suppressions,
    start: u32,
    reading: *const Reading,
    placed: u32,
    file_wide: bool,
) void {
    assert(reading.end >= start);
    assert(!suppressions.items.full());
    assert(placed < std.math.maxInt(u32));

    const code_start = suppressions.record_code_start();
    const placed_held = suppressions.placed.const_slice();

    if (placed_held.len > 0) assert(placed_held[placed_held.len - 1] <= placed);

    suppressions.items.push(.{
        .blanket = reading.blanket,
        .code_count = suppressions.codes.count() - code_start,
        .code_start = code_start,
        .line = if (file_wide) file_line else placed,
        .span = Span.between(start, reading.end),
    });

    suppressions.consumed.push(false);
    suppressions.placed.push(placed);

    if (file_wide) suppressions.file.push(suppressions.items.count() - 1);

    assert(suppressions.count() == suppressions.placed.count());
}

fn record_code_start(suppressions: *const Suppressions) u32 {
    const items = suppressions.items.const_slice();
    if (items.len == 0) return 0;

    const held = items[items.len - 1];
    const start = held.code_start + held.code_count;

    assert(start <= suppressions.codes.count());

    return start;
}

fn file_prefixed(
    source: []const u8,
    comment: Span,
    start: u32,
    prefixes: []const []const u8,
) bool {
    assert(start <= comment.end());
    assert(source.len <= std.math.maxInt(u32));
    assert(prefixes.len <= std.math.maxInt(u32));

    const text = trivia.comment_text_start(source, comment);

    for (prefixes) |prefix| {
        const width: u32 = @intCast(prefix.len);
        if (start < text + width) continue;
        if (!std.mem.eql(u8, source[text..][0..width], prefix)) continue;

        const between = source[text + width .. start];
        if (std.mem.findNone(u8, between, "\t ") == null) return true;
    }

    return false;
}

fn code_start_of(source: []const u8, comment: Span, after: u32) ?u32 {
    assert(after <= comment.end());
    assert(source.len <= std.math.maxInt(u32));

    const end = comment.end();

    if (after < end) {
        if (source[after] == ':') {
            assert(after + 1 <= source.len);

            return after + 1;
        }
    }

    var offset = after;

    for (source[after..end]) |byte| {
        if (!blank(byte)) break;

        offset += 1;
    }

    if (offset == after) return null;
    if (offset >= end) return null;

    switch (code_at(source, offset, end)) {
        .prose => return null,
        .code, .malformed => {},
    }

    assert(offset < end);

    return offset;
}

fn code_at(source: []const u8, offset: u32, end: u32) Run {
    assert(offset < end);
    assert(end <= source.len);

    var cursor = offset;

    for (source[offset..end]) |byte| {
        if (!std.ascii.isUpper(byte)) break;

        cursor += 1;
    }

    const letters = cursor - offset;

    for (source[cursor..end]) |byte| {
        if (!std.ascii.isDigit(byte)) break;

        cursor += 1;
    }

    const digits = cursor - offset - letters;

    if (letters == 0) return .prose;
    if (digits == 0) return .prose;

    if (cursor < end) {
        const byte = source[cursor];
        if (std.ascii.isAlphanumeric(byte)) return .malformed;
        if (byte == '-') return .malformed;
        if (byte == '_') return .malformed;
    }

    return .{ .code = Span.between(offset, cursor) };
}

fn blank(byte: u8) bool {
    return switch (byte) {
        '\t', ' ' => true,
        else => false,
    };
}

fn continuation_width(source: []const u8, offset: u32) u32 {
    assert(offset < source.len);
    assert(source[offset] == '\\');

    const next = byte_at(source, offset + 1);
    if (next == '\n') return 1;
    if (next != '\r') return 0;
    if (byte_at(source, offset + 2) == '\n') return 2;
    return 1;
}

fn word_in(
    source: []const u8,
    comment: Span,
    word: []const u8,
    prefixes: []const []const u8,
) ?u32 {
    assert(word.len > 0);
    assert(comment.end() <= source.len);
    assert(prefixes.len <= std.math.maxInt(u32));

    const width: u32 = @intCast(word.len);
    if (comment.length < width) return null;

    for (comment.offset..comment.end() - width + 1) |position| {
        const start: u32 = @intCast(position);
        if (!std.ascii.eqlIgnoreCase(source[start..][0..width], word)) continue;

        if (!opens_at(source, comment, start)) {
            if (!file_prefixed(source, comment, start, prefixes)) continue;
        }

        if (!closes_at(source, comment, start + width)) continue;
        assert(start <= source.len);

        return start;
    }

    return null;
}

fn closes_at(source: []const u8, comment: Span, end: u32) bool {
    assert(end >= comment.offset);

    if (end >= comment.end()) return true;
    assert(source.len <= std.math.maxInt(u32));

    const byte = source[end];
    if (byte == ':') return true;
    return is_ascii_whitespace(byte);
}

fn opens_at(source: []const u8, comment: Span, start: u32) bool {
    assert(start >= comment.offset);
    assert(start <= comment.end());
    assert(source.len <= std.math.maxInt(u32));

    var cursor = start;

    for (comment.offset..start) |_| {
        if (!blank(source[cursor - 1])) break;

        cursor -= 1;
    }

    if (cursor == comment.offset) return true;

    return switch (source[cursor - 1]) {
        '#', '*', '/' => true,
        else => false,
    };
}

const TestLexed = struct {
    index: LineIndex,
    lexed: Tokens,

    fn init(language: Language, source: []const u8) !TestLexed {
        assert(language.lexes());

        const gpa = std.testing.allocator;

        assert(source.len > 0);

        var lexed: Tokens = try .init(gpa, 1 << 12);
        errdefer lexed.deinit(gpa);

        var index: LineIndex = try .init(gpa, 64);
        errdefer index.deinit(gpa);

        try lex(.of(language), source, &lexed);
        try index.build(source);

        assert(index.count() > 0);

        return .{ .index = index, .lexed = lexed };
    }

    fn deinit(held: *TestLexed) void {
        assert(held.index.count() > 0);

        held.index.deinit(std.testing.allocator);
        held.lexed.deinit(std.testing.allocator);
        held.* = undefined;
    }

    fn comments(held: *const TestLexed, buffer: []Span) []Span {
        assert(buffer.len > 0);

        var found: u32 = 0;

        for (held.lexed.slice()) |token| {
            if (token.kind != .comment) continue;

            buffer[found] = token.span();
            found += 1;
        }

        assert(found <= buffer.len);

        return buffer[0..found];
    }
};

const test_word = "noqa";
const test_file_prefixes = [_][]const u8{ "flake8:", "ruff:" };
const test_comment_count_max: u32 = 16;

fn test_scanned(source: []const u8, spans: []const Span) !Suppressions {
    assert(source.len <= std.math.maxInt(u32));
    assert(spans.len <= std.math.maxInt(u32));

    const gpa = std.testing.allocator;
    var index: LineIndex = try .init(gpa, 64);
    defer index.deinit(gpa);

    try index.build(source);

    var suppressions: Suppressions = try .init(gpa, .{
        .code_count_max = 16,
        .directive_count_max = 8,
    });

    errdefer suppressions.deinit(gpa);

    try suppressions.scan(source, spans, test_word, &test_file_prefixes, &index);

    return suppressions;
}

fn test_one(source: []const u8) !Suppressions {
    assert(source.len <= std.math.maxInt(u32));

    return test_scanned(source, &.{test_comment_of(source)});
}

fn test_comment_of(source: []const u8) Span {
    assert(source.len <= std.math.maxInt(u32));

    return .{ .offset = 0, .length = @intCast(source.len) };
}

fn test_span(offset: u32, length: u32) Span {
    assert(offset < std.math.maxInt(u32));
    assert(length < std.math.maxInt(u32));

    return .{ .offset = offset, .length = length };
}

fn test_python(source: []const u8) !Suppressions {
    assert(source.len <= std.math.maxInt(u32));

    const gpa = std.testing.allocator;
    var held: TestLexed = try .init(.python, source);
    defer held.deinit();

    var buffer: [test_comment_count_max]Span = undefined;
    const spans = held.comments(&buffer);

    var suppressions: Suppressions = try .init(gpa, .{
        .code_count_max = 64,
        .directive_count_max = 32,
    });

    errdefer suppressions.deinit(gpa);

    try suppressions.scan(source, spans, test_word, &test_file_prefixes, &held.index);

    try suppressions.join(source, held.lexed.slice(), &held.index);

    return suppressions;
}

fn test_lexed_scan(language: Language, source: []const u8, code: []const u8) !void {
    assert(language.lexes());
    assert(source.len <= std.math.maxInt(u32));

    const gpa = std.testing.allocator;
    var held: TestLexed = try .init(language, source);
    defer held.deinit();

    var buffer: [test_comment_count_max]Span = undefined;
    const spans = held.comments(&buffer);
    var suppressions = try test_scanned(source, spans);
    defer suppressions.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expectEqual(@as(?u32, 0), suppressions.matches(0, code, source));
}

fn test_unconsumed(suppressions: *const Suppressions, buffer: []u32) []u32 {
    assert(buffer.len >= suppressions.count());

    var iterator = suppressions.unconsumed();
    var found: u32 = 0;

    for (0..buffer.len) |_| {
        const directive = iterator.next() orelse break;

        buffer[found] = directive;
        found += 1;
    }

    assert(found <= suppressions.count());

    return buffer[0..found];
}

fn test_expect_codes(
    suppressions: *const Suppressions,
    directive_index: u32,
    source: []const u8,
    expected: []const []const u8,
) !void {
    assert(directive_index < std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));

    const directive = suppressions.at(directive_index);

    try std.testing.expectEqual(expected.len, directive.code_count);

    for (expected, 0..) |code, position| {
        const span = suppressions.code_of(directive.code_start + @as(u32, @intCast(position)));

        try std.testing.expectEqualStrings(code, span.text(source));
    }
}

test "a word inside a longer identifier is not a directive" {
    const sources = [_][]const u8{
        "# noqable",
        "# a_noqa_thing",
        "# (noqa)",
        "# (noqa ",
        "# noqa1",
        "# remove noqa comments later",
    };

    for (sources) |source| {
        var suppressions = try test_one(source);
        defer suppressions.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(u32, 0), suppressions.count());
        try std.testing.expectEqual(@as(?u32, null), suppressions.matches(0, "E501", source));
    }
}

test "a word at every boundary form is a directive" {
    const sources = [_][]const u8{
        "noqa",
        "# noqa",
        "# noqa ",
        "# noqa   ",
        "#noqa",
        "#\tnoqa",
        "# fixed # noqa",
        "# noqa:E501",
        "# NOQA",
        "# NoQA: F401",
    };

    for (sources) |source| {
        var suppressions = try test_one(source);
        defer suppressions.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(u32, 1), suppressions.count());
    }
}

test "a directive in another case names its codes" {
    const source = "# NoQA: F401";
    var suppressions = try test_one(source);
    defer suppressions.deinit(std.testing.allocator);

    try test_expect_codes(&suppressions, 0, source, &.{"F401"});
    try std.testing.expectEqual(@as(?u32, 0), suppressions.matches(0, "F401", source));
    try std.testing.expectEqual(@as(?u32, null), suppressions.matches(0, "E501", source));
}

test "a code list closes on the first run that is not a code" {
    const sources = [_][]const u8{
        "# noqa: E501 or F401",
        "# noqa:E501 or F401",
        "# noqa: E501, or F401",
        "# noqa: E501 trailing",
    };

    for (sources) |source| {
        var suppressions = try test_one(source);
        defer suppressions.deinit(std.testing.allocator);

        try test_expect_codes(&suppressions, 0, source, &.{"E501"});
        try std.testing.expectEqual(@as(?u32, null), suppressions.matches(0, "F401", source));
    }
}

test "a malformed code after the colon drops the directive" {
    const sources = [_][]const u8{
        "# noqa:",
        "# noqa: because",
        "# noqa: f401",
        "# noqa: F401x",
        "# noqa: F401-E501",
        "# noqa: E501, F401x",
    };

    for (sources) |source| {
        var suppressions = try test_one(source);
        defer suppressions.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(u32, 0), suppressions.count());
        try std.testing.expectEqual(@as(u32, 0), suppressions.codes.count());
        try std.testing.expectEqual(@as(?u32, null), suppressions.matches(0, "F401", source));
    }
}

test "a malformed code without the colon leaves a blanket" {
    const source = "# noqa F401x";
    var suppressions = try test_one(source);
    defer suppressions.deinit(std.testing.allocator);

    const directive = suppressions.at(0);

    try std.testing.expect(directive.blanket);
    try std.testing.expectEqual(@as(u32, 0), directive.code_count);
    try std.testing.expectEqual(@as(?u32, 0), suppressions.matches(0, "F401", source));
}

test "a doubled separator still reads the code after it" {
    const source = "# noqa: F401,,E501";
    var suppressions = try test_one(source);
    defer suppressions.deinit(std.testing.allocator);

    try test_expect_codes(&suppressions, 0, source, &.{ "F401", "E501" });
}

test "a directive without a code list is a blanket" {
    const source = "# noqa";
    var suppressions = try test_one(source);
    defer suppressions.deinit(std.testing.allocator);

    const directive = suppressions.at(0);

    try std.testing.expect(directive.blanket);
    try std.testing.expectEqual(@as(u32, 0), directive.code_count);
    try std.testing.expectEqual(@as(u32, 0), directive.line);
    try std.testing.expectEqual(@as(?u32, 0), suppressions.matches(0, "E501", source));
    try std.testing.expectEqual(@as(?u32, null), suppressions.matches(1, "E501", source));
}

test "a one code list names one code" {
    const source = "# noqa:E501";
    var suppressions = try test_one(source);
    defer suppressions.deinit(std.testing.allocator);

    const directive = suppressions.at(0);

    try std.testing.expect(!directive.blanket);
    try std.testing.expectEqual(@as(u32, 1), directive.code_count);
    try test_expect_codes(&suppressions, 0, source, &.{"E501"});
    try std.testing.expectEqual(@as(?u32, 0), suppressions.matches(0, "E501", source));
    try std.testing.expectEqual(@as(?u32, null), suppressions.matches(0, "F401", source));
}

test "a three code list names three codes" {
    const source = "# noqa: E501, F401 W605";
    var suppressions = try test_one(source);
    defer suppressions.deinit(std.testing.allocator);

    try test_expect_codes(&suppressions, 0, source, &.{ "E501", "F401", "W605" });
    try std.testing.expectEqual(@as(?u32, 0), suppressions.matches(0, "W605", source));
}

test "a trailing separator closes the list" {
    const source = "# noqa: E501, F401,  ";
    var suppressions = try test_one(source);
    defer suppressions.deinit(std.testing.allocator);

    const directive = suppressions.at(0);

    try std.testing.expectEqual(@as(u32, 2), directive.code_count);
    try std.testing.expectEqual(@as(u32, 18), directive.span.end());
}

test "a lookup finds the row on its line among many" {
    const source = "a = 1  # noqa: E501\nb = 2\n# ruff: noqa: F401\nc = 3  # noqa\n" ++
        "d = 4  # noqa: W605\n";

    var held = try test_python(source);
    defer held.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 4), held.count());
    try std.testing.expectEqual(@as(?u32, 0), held.matches(0, "E501", source));
    try std.testing.expectEqual(@as(?u32, null), held.matches(0, "W605", source));
    try std.testing.expectEqual(@as(?u32, null), held.matches(1, "E501", source));
    try std.testing.expectEqual(@as(?u32, 1), held.matches(1, "F401", source));
    try std.testing.expectEqual(@as(?u32, 1), held.matches(2, "F401", source));
    try std.testing.expectEqual(@as(?u32, null), held.matches(2, "E501", source));
    try std.testing.expectEqual(@as(?u32, 2), held.matches(3, "E501", source));
    try std.testing.expectEqual(@as(?u32, 3), held.matches(4, "W605", source));
    try std.testing.expectEqual(@as(?u32, null), held.matches(4, "E501", source));
    try std.testing.expectEqual(@as(?u32, null), held.matches(5, "E501", source));
}

test "a full run table reports the overflow" {
    const gpa = std.testing.allocator;
    const source = "a = \"\"\"one\ntwo\"\"\"\nb = \"\"\"one\ntwo\"\"\"\n";
    var held: TestLexed = try .init(.python, source);
    defer held.deinit();

    var suppressions: Suppressions = try .init(gpa, .{
        .code_count_max = 1,
        .directive_count_max = 1,
    });

    defer suppressions.deinit(gpa);

    try std.testing.expectError(
        error.RunsExhausted,
        suppressions.join(source, held.lexed.slice(), &held.index),
    );

    try std.testing.expectEqual(@as(usize, 1), suppressions.joined().len);
}

test "a full directive table stops the scan" {
    const gpa = std.testing.allocator;
    const source = "# noqa\n# noqa\n# noqa\n";
    var index: LineIndex = try .init(gpa, 64);
    defer index.deinit(gpa);

    try index.build(source);

    var suppressions: Suppressions = try .init(gpa, .{
        .code_count_max = 8,
        .directive_count_max = 2,
    });

    defer suppressions.deinit(gpa);

    const spans = [_]Span{ test_span(0, 6), test_span(7, 6), test_span(14, 6) };
    const scanned = suppressions.scan(source, &spans, test_word, &test_file_prefixes, &index);

    try std.testing.expectError(error.DirectivesExhausted, scanned);

    try std.testing.expectEqual(@as(u32, 2), suppressions.count());
    try std.testing.expectEqual(@as(?u32, 1), suppressions.matches(1, "E501", source));
    try std.testing.expectEqual(@as(?u32, null), suppressions.matches(2, "E501", source));
}

test "a full code table stops the scan" {
    const gpa = std.testing.allocator;
    const source = "# noqa: E501, F401, W605";
    var index: LineIndex = try .init(gpa, 64);
    defer index.deinit(gpa);

    try index.build(source);

    var suppressions: Suppressions = try .init(gpa, .{
        .code_count_max = 2,
        .directive_count_max = 4,
    });

    defer suppressions.deinit(gpa);

    const comments = [_]Span{test_comment_of(source)};
    const scanned = suppressions.scan(source, &comments, test_word, &test_file_prefixes, &index);

    try std.testing.expectError(error.CodesExhausted, scanned);

    try std.testing.expectEqual(@as(u32, 1), suppressions.count());

    const directive = suppressions.at(0);

    try std.testing.expect(!directive.blanket);
    try std.testing.expectEqual(@as(u32, 2), directive.code_count);
    try std.testing.expectEqual(@as(?u32, null), suppressions.matches(0, "W605", source));
}

test "a carriage return source reports the lines a line feed source does" {
    const gpa = std.testing.allocator;
    const feed = "a = 1\n# noqa: E501\nb = 2\n";
    const carriage = "a = 1\r\n# noqa: E501\r\nb = 2\r\n";
    var held = try test_scanned(feed, &.{test_span(6, 12)});
    defer held.deinit(gpa);

    var other = try test_scanned(carriage, &.{test_span(7, 12)});
    defer other.deinit(gpa);

    try std.testing.expectEqual(@as(u32, 1), held.count());
    try std.testing.expectEqual(@as(u32, 1), other.count());
    try std.testing.expectEqual(held.at(0).line, other.at(0).line);
    try std.testing.expectEqual(@as(?u32, 0), held.matches(1, "E501", feed));
    try std.testing.expectEqual(@as(?u32, 0), other.matches(1, "E501", carriage));
}

test "a consumed directive leaves the unconsumed behind" {
    const gpa = std.testing.allocator;
    const source = "# noqa\n# noqa: E501\n";
    var index: LineIndex = try .init(gpa, 64);
    defer index.deinit(gpa);

    try index.build(source);

    var suppressions: Suppressions = try .init(gpa, .{
        .code_count_max = 8,
        .directive_count_max = 8,
    });

    defer suppressions.deinit(gpa);

    const spans = [_]Span{ test_span(0, 6), test_span(7, 12) };

    try suppressions.scan(source, &spans, test_word, &test_file_prefixes, &index);

    var buffer: [test_comment_count_max]u32 = undefined;

    try std.testing.expectEqual(@as(usize, 2), test_unconsumed(&suppressions, &buffer).len);

    suppressions.consume(0);

    try std.testing.expectEqualSlices(u32, &.{1}, test_unconsumed(&suppressions, &buffer));
}

test "a ruff file directive suppresses every line" {
    const source = "# ruff: noqa\nimport os\n";
    var held = try test_python(source);
    defer held.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), held.count());
    try std.testing.expectEqual(file_line, held.at(0).line);
    try std.testing.expect(held.matches(1, "F401", source) != null);
    try std.testing.expect(held.matches(9, "E501", source) != null);
}

test "a flake8 file directive suppresses every line" {
    const source = "# flake8: noqa\nimport os\n";
    var held = try test_python(source);
    defer held.deinit(std.testing.allocator);

    try std.testing.expect(held.matches(1, "F401", source) != null);
}

test "a file directive naming codes suppresses only those" {
    const source = "# flake8: noqa: F401\nimport os\n";
    var held = try test_python(source);
    defer held.deinit(std.testing.allocator);

    try std.testing.expect(held.matches(1, "F401", source) != null);
    try std.testing.expectEqual(@as(?u32, null), held.matches(1, "E501", source));
}

test "a ruff file directive naming another code leaves the row standing" {
    const source = "# ruff: noqa: E501\nimport os\n";
    var held = try test_python(source);
    defer held.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?u32, null), held.matches(1, "F401", source));
}

test "a directive with no colon still names its codes" {
    const source = "import sys  # noqa F401\n";
    var held = try test_python(source);
    defer held.deinit(std.testing.allocator);

    try std.testing.expect(held.matches(0, "F401", source) != null);
    try std.testing.expectEqual(@as(?u32, null), held.matches(0, "E501", source));
    try test_expect_codes(&held, 0, source, &.{"F401"});
}

test "a directive followed by prose stays a blanket" {
    const source = "import sys  # noqa because reasons\n";
    var held = try test_python(source);
    defer held.deinit(std.testing.allocator);

    try std.testing.expect(held.at(0).blanket);
    try std.testing.expect(held.matches(0, "E501", source) != null);
}

test "a directive on a closing line covers the whole string" {
    const source = "held = \"\"\"one\n" ++ "two\n" ++ "three\"\"\"  # noqa: E501\n";
    var held = try test_python(source);
    defer held.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(
        Joined,
        &.{.{ .line_first = 0, .line_last = 2 }},
        held.joined(),
    );

    try std.testing.expect(held.matches(1, "E501", source) != null);
    try std.testing.expect(held.matches(2, "E501", source) != null);
}

test "a backslash continuation carries its line forward" {
    const source = "held = 1 + \\" ++ "\n    2  # noqa: E501\n";
    var held = try test_python(source);
    defer held.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(
        Joined,
        &.{.{ .line_first = 0, .line_last = 1 }},
        held.joined(),
    );

    try std.testing.expect(held.matches(0, "E501", source) != null);
}

test "a line that stands alone maps to itself" {
    const source = "held = 1  # noqa: E501\n";
    var held = try test_python(source);
    defer held.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), held.joined().len);
    try std.testing.expect(held.matches(0, "E501", source) != null);
    try std.testing.expectEqual(@as(?u32, null), held.matches(1, "E501", source));
}

test "a directive with blanks after it suppresses its line" {
    const source = "import os  # noqa   \n";
    var held = try test_python(source);
    defer held.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), held.count());
    try std.testing.expectEqual(@as(?u32, 0), held.matches(0, "F401", source));
}

test "a python comment carries a directive" {
    try test_lexed_scan(.python, "import os  # noqa: F401\n", "F401");
}

test "a rust comment carries a directive" {
    try test_lexed_scan(.rust, "let value = 1; // noqa: TS032\n", "TS032");
}

test "a go block comment carries a directive" {
    try test_lexed_scan(.go, "var value = 1 /* noqa: TS032 */\n", "TS032");
}

test "a scan runs on a frozen thread" {
    const source = "# noqa: E501\nvalue = 1  # noqa\n";
    var static_allocator = StaticAllocator.init(std.testing.allocator);
    defer static_allocator.deinit();

    const gpa = static_allocator.allocator();
    var index: LineIndex = try .init(gpa, 64);
    defer index.deinit(gpa);

    try index.build(source);

    var suppressions: Suppressions = try .init(gpa, .{
        .code_count_max = 8,
        .directive_count_max = 8,
    });

    defer suppressions.deinit(gpa);

    const spans = [_]Span{ test_span(0, 12), test_span(24, 6) };

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    try suppressions.scan(source, &spans, test_word, &test_file_prefixes, &index);

    try std.testing.expectEqual(@as(u32, 2), suppressions.count());
    try std.testing.expectEqual(@as(?u32, 0), suppressions.matches(0, "E501", source));
    try std.testing.expectEqual(@as(?u32, 1), suppressions.matches(1, "F401", source));

    suppressions.consume(1);

    var buffer: [test_comment_count_max]u32 = undefined;

    try std.testing.expectEqual(@as(usize, 1), test_unconsumed(&suppressions, &buffer).len);
}

test "a markup comment carries a directive" {
    const gpa = std.testing.allocator;
    const source = "<div>{# noqa: TS032 #}</div>\n";

    var document: markup.Document = try .init(gpa, .{
        .diagnostic_count_max = 1,
        .node_count_max = 64,
        .tag_count_max = 1,
        .token_count_max = 1_024,
    });

    defer document.deinit(gpa);

    try document.parse(source, &.empty);

    var buffer: [test_comment_count_max]Span = undefined;
    var found: u32 = 0;

    for (document.tokens()) |token| {
        if (token.kind != .comment_text) continue;

        buffer[found] = token.span();
        found += 1;
    }

    var suppressions = try test_scanned(source, buffer[0..found]);
    defer suppressions.deinit(gpa);

    try std.testing.expectEqual(@as(u32, 1), found);
    try std.testing.expectEqual(@as(?u32, 0), suppressions.matches(0, "TS032", source));
}
