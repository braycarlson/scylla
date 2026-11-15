const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Language = @import("language.zig").Language;
const Random = @import("../testing/random.zig");
const Brackets = @import("brackets.zig").Brackets;
const Span = @import("../stdx/bounded/span.zig");
const Token = @import("token.zig");
const Tokens = @import("tokens.zig");
const lex = @import("lex.zig").lex;
const stream = @import("stream.zig");

pub const Summary = union(enum) {
    call: Call,
    dotted_name: DottedName,
    dynamic,
    literal: Literal,
    sequence: Sequence,

    pub const Call = struct {
        callee_count: u32,
        callee_first: u32,
        paren_open: u32,
    };

    pub const DottedName = struct {
        segment_count: u32,
        segment_first: u32,
    };

    pub const Literal = struct {
        content: Span,
    };

    pub const Sequence = struct {
        item_count: u32,
        item_first: u32,
    };
};

pub const Run = struct {
    token_end: u32,
    token_start: u32,
};

pub const Tables = struct {
    items: *ArrayType(Summary),
    segments: *ArrayType(Span),
};

const Reader = struct {
    end: u32,
    pairs: *const Brackets,
    source: []const u8,
    start: u32,
    tables: Tables,
    tokens: []const Token,

    fn classify(reader: *Reader) Reading {
        assert(reader.start < reader.end);
        assert(reader.end <= reader.tokens.len);

        const first = reader.significant_next(reader.start) orelse return .{ .summary = .dynamic };
        const last = reader.significant_last() orelse return .{ .summary = .dynamic };

        assert(first <= last);

        if (first == last) return .{ .summary = reader.read_single(first) };

        if (reader.opens(first)) {
            if (reader.pairs.partner_of(first) == last) {
                return .{ .sequence = .{ .first = first, .last = last } };
            }
        }

        if (!reader.is_name(first)) return .{ .summary = .dynamic };

        const chain = reader.chain_end(first);

        if (chain == last) {
            return .{ .summary = .{ .dotted_name = reader.push_segments(first, last) } };
        }

        const paren = reader.significant_next(chain + 1) orelse return .{ .summary = .dynamic };
        if (!reader.tokens[paren].is_punctuation(.paren_open)) return .{ .summary = .dynamic };
        if (reader.pairs.partner_of(paren) != last) return .{ .summary = .dynamic };

        const callee = reader.push_segments(first, chain);

        assert(paren > chain);

        return .{ .summary = .{ .call = .{
            .callee_count = callee.segment_count,
            .callee_first = callee.segment_first,
            .paren_open = paren,
        } } };
    }

    fn read_sequence(reader: *Reader, first: u32, last: u32) Summary {
        assert(first < last);
        assert(reader.pairs.partner_of(first) == last);

        const depth = reader.pairs.depth_of(first) + 1;
        const item_first = reader.tables.items.count();
        var item_count: u32 = 0;
        var element = first + 1;
        var index = first + 1;

        while (index <= last) : (index += 1) {
            if (!reader.splits(index, last, depth)) continue;

            if (reader.significant_within(element, index)) {
                const summary = reader.read_element(element, index);

                if (!reader.tables.items.full()) {
                    reader.tables.items.push(summary);
                    item_count += 1;
                }
            }

            element = index + 1;
        }

        assert(item_first + item_count == reader.tables.items.count());

        return .{ .sequence = .{ .item_count = item_count, .item_first = item_first } };
    }

    fn read_element(reader: *Reader, start: u32, end: u32) Summary {
        assert(start < end);
        assert(end <= reader.end);

        const held_end = reader.end;
        const held_start = reader.start;

        reader.end = end;
        reader.start = start;

        const reading = reader.classify();

        reader.end = held_end;
        reader.start = held_start;

        return switch (reading) {
            .sequence => .dynamic,
            .summary => |summary| summary,
        };
    }

    fn read_single(reader: *Reader, index: u32) Summary {
        assert(index >= reader.start);
        assert(index < reader.end);

        const token = reader.tokens[index];

        return switch (token.kind) {
            .string => literal_of_string(token, reader.source),
            .number => .{ .literal = .{ .content = token.span() } },
            .identifier, .keyword => reader.read_word(index),
            .block_end, .block_start, .comment, .newline, .punctuation => .dynamic,
        };
    }

    fn read_word(reader: *Reader, index: u32) Summary {
        assert(index < reader.end);
        assert(reader.is_name(index));

        const token = reader.tokens[index];

        if (is_literal_word(token.text(reader.source))) {
            return .{ .literal = .{ .content = token.span() } };
        }

        return .{ .dotted_name = reader.push_segments(index, index) };
    }

    fn chain_end(reader: *const Reader, first: u32) u32 {
        assert(first < reader.end);
        assert(reader.is_name(first));

        var last = first;
        var segment_count: u32 = 1;

        while (segment_count < dotted_path_depth_max) : (segment_count += 1) {
            const dot = reader.significant_next(last + 1) orelse break;
            if (!reader.tokens[dot].is_punctuation(.dot)) break;

            const name = reader.significant_next(dot + 1) orelse break;
            if (!reader.is_name(name)) break;

            last = name;
        }

        assert(last >= first);
        assert(last < reader.end);

        return last;
    }

    fn push_segments(reader: *Reader, first: u32, last: u32) Summary.DottedName {
        assert(first <= last);
        assert(last < reader.end);

        const segment_first = reader.tables.segments.count();
        var segment_count: u32 = 0;
        var index = first;

        while (index <= last) : (index += 1) {
            if (!reader.is_name(index)) continue;
            if (reader.tables.segments.full()) continue;

            reader.tables.segments.push(reader.tokens[index].span());
            segment_count += 1;
        }

        assert(segment_first + segment_count == reader.tables.segments.count());

        return .{ .segment_count = segment_count, .segment_first = segment_first };
    }

    fn splits(reader: *const Reader, index: u32, last: u32, depth: u32) bool {
        assert(index <= last);
        assert(depth > 0);

        if (index == last) return true;
        if (!reader.tokens[index].is_punctuation(.comma)) return false;
        return reader.pairs.depth_of(index) == depth;
    }

    fn opens(reader: *const Reader, index: u32) bool {
        assert(index < reader.end);

        const classified = Brackets.classify(reader.source, reader.tokens[index]) orelse {
            return false;
        };

        return classified.opens;
    }

    fn is_name(reader: *const Reader, index: u32) bool {
        assert(index < reader.tokens.len);

        return switch (reader.tokens[index].kind) {
            .identifier, .keyword => true,
            .block_end, .block_start, .comment, .newline, .number, .punctuation, .string => false,
        };
    }

    fn is_significant(reader: *const Reader, index: u32) bool {
        assert(index < reader.tokens.len);

        return Token.is_significant(reader.tokens[index].kind);
    }

    fn significant_last(reader: *const Reader) ?u32 {
        assert(reader.start <= reader.end);

        var index = reader.end;

        while (index > reader.start) {
            index -= 1;

            if (reader.is_significant(index)) return index;
        }

        assert(index == reader.start);

        return null;
    }

    fn significant_next(reader: *const Reader, from: u32) ?u32 {
        assert(from < std.math.maxInt(u32));

        return stream.significant_next(reader.tokens, from, reader.end);
    }

    fn significant_within(reader: *const Reader, from: u32, end: u32) bool {
        assert(from <= end);

        return stream.significant_next(reader.tokens, from, end) != null;
    }
};

const Reading = union(enum) {
    sequence: Brackets.Range,
    summary: Summary,
};

const dotted_path_depth_max: u32 = 32;

pub const literal_words = [_][]const u8{
    "False",
    "None",
    "True",
    "false",
    "iota",
    "nil",
    "null",
    "true",
    "undefined",
};

comptime {
    assert(dotted_path_depth_max > 1);
    assert(literal_words.len == 9);
}

pub fn read(
    source: []const u8,
    tokens: []const Token,
    pairs: *const Brackets,
    run: Run,
    tables: Tables,
) Summary {
    assert(source.len <= std.math.maxInt(u32));
    assert(run.token_start <= run.token_end);
    assert(run.token_end <= tokens.len);

    if (run.token_start == run.token_end) return .dynamic;

    var reader: Reader = .{
        .end = run.token_end,
        .pairs = pairs,
        .source = source,
        .start = run.token_start,
        .tables = tables,
        .tokens = tokens,
    };

    return switch (reader.classify()) {
        .sequence => |sequence| reader.read_sequence(sequence.first, sequence.last),
        .summary => |summary| summary,
    };
}

fn is_literal_word(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    for (literal_words) |word| {
        if (std.mem.eql(u8, word, text)) return true;
    }

    return false;
}

fn literal_of_string(token: Token, source: []const u8) Summary {
    assert(source.len <= std.math.maxInt(u32));
    assert(token.end() <= source.len);

    const text = token.text(source);
    var prefix: u32 = 0;

    while (prefix < text.len) : (prefix += 1) {
        if (!std.ascii.isAlphabetic(text[prefix])) break;
    }

    for (text[0..prefix]) |letter| {
        const lower = std.ascii.toLower(letter);
        if (lower == 'f') return .dynamic;
        if (lower == 't') return .dynamic;
    }

    if (prefix == text.len) return .dynamic;

    const quote = text[prefix];
    const quoted = quote == '"' or quote == '\'';
    if (!quoted) return .dynamic;

    const tripled = std.mem.startsWith(u8, text[prefix..], &.{ quote, quote, quote });
    const opening: u32 = if (tripled) 3 else 1;
    const start = prefix + opening;
    const length: u32 = @intCast(text.len);

    const closes = length >= start + opening and
        std.mem.allEqual(u8, text[length - opening ..], quote);

    const end = if (closes) length - opening else length;
    if (end < start) return .dynamic;

    const content: Span = .{ .offset = token.offset + start, .length = end - start };

    assert(content.end() <= token.end());

    return .{ .literal = .{ .content = content } };
}

const Built = struct {
    items: ArrayType(Summary),
    pairs: Brackets,
    segments: ArrayType(Span),
    source: []const u8,
    summary: Summary,
    tokens: Tokens,

    fn init(built: *Built, language: Language, source: []const u8) !void {
        assert(source.len <= std.math.maxInt(u32));
        assert(language.lexes());

        const gpa = std.testing.allocator;

        built.source = source;
        built.tokens = try .init(gpa, token_count_test_max);
        errdefer built.tokens.deinit(gpa);

        try lex(.of(language), source, &built.tokens);

        built.pairs = try .init(gpa, token_count_test_max);
        errdefer built.pairs.deinit(gpa);

        try built.pairs.build(source, built.tokens.slice());

        built.segments = try .init(gpa, row_count_test_max);
        errdefer built.segments.deinit(gpa);

        built.items = try .init(gpa, row_count_test_max);

        const count = built.tokens.count();

        built.summary = read(source, built.tokens.slice(), &built.pairs, .{
            .token_end = count,
            .token_start = 0,
        }, .{ .items = &built.items, .segments = &built.segments });

        assert(built.pairs.count() == count);
    }

    fn deinit(built: *Built) void {
        const gpa = std.testing.allocator;

        assert(built.items.count() <= row_count_test_max);
        assert(built.segments.count() <= row_count_test_max);

        built.items.deinit(gpa);
        built.segments.deinit(gpa);
        built.pairs.deinit(gpa);
        built.tokens.deinit(gpa);
    }

    fn text_of(built: *const Built, span: Span) []const u8 {
        assert(span.end() <= built.source.len);

        return span.text(built.source);
    }

    fn segments_expect(
        built: *const Built,
        first: u32,
        count: u32,
        expected: []const []const u8,
    ) !void {
        assert(first + count <= built.segments.count());

        try std.testing.expectEqual(expected.len, count);

        for (expected, 0..) |word, offset| {
            const span = built.segments.get(first + @as(u32, @intCast(offset)));

            try std.testing.expectEqualStrings(word, built.text_of(span));
        }
    }
};

const row_count_test_max = 256;
const token_count_test_max = 4_096;

test "a lone string is a literal without its quotes" {
    var built: Built = undefined;

    try built.init(.python, "\"hello\"");
    defer built.deinit();

    try std.testing.expect(built.summary == .literal);
    try std.testing.expectEqualStrings("hello", built.text_of(built.summary.literal.content));
}

test "a raw string keeps its content and a format string is dynamic" {
    var raw: Built = undefined;

    try raw.init(.python, "r\"a\\b\"");
    defer raw.deinit();

    try std.testing.expect(raw.summary == .literal);
    try std.testing.expectEqualStrings("a\\b", raw.text_of(raw.summary.literal.content));

    var formatted: Built = undefined;

    try formatted.init(.python, "f\"{name}\"");
    defer formatted.deinit();

    try std.testing.expect(formatted.summary == .dynamic);
}

test "a triple quoted string drops all six quotes" {
    var built: Built = undefined;

    try built.init(.python, "\"\"\"body\"\"\"");
    defer built.deinit();

    try std.testing.expect(built.summary == .literal);
    try std.testing.expectEqualStrings("body", built.text_of(built.summary.literal.content));
}

test "a number and a literal word are literals" {
    for ([_][]const u8{ "42", "3.5", "True", "None", "False" }) |source| {
        var built: Built = undefined;

        try built.init(.python, source);
        defer built.deinit();

        try std.testing.expect(built.summary == .literal);
    }

    for ([_][]const u8{ "null", "undefined", "true" }) |source| {
        var built: Built = undefined;

        try built.init(.javascript, source);
        defer built.deinit();

        try std.testing.expect(built.summary == .literal);
    }
}

test "a dotted chain records each segment" {
    var built: Built = undefined;

    try built.init(.python, "django.db.models.CharField");
    defer built.deinit();

    try std.testing.expect(built.summary == .dotted_name);

    const dotted = built.summary.dotted_name;

    try built.segments_expect(dotted.segment_first, dotted.segment_count, &.{
        "django",
        "db",
        "models",
        "CharField",
    });
}

test "a chain that ends in a call is a call" {
    var built: Built = undefined;

    try built.init(.python, "models.CharField(max_length=10)");
    defer built.deinit();

    try std.testing.expect(built.summary == .call);

    const call = built.summary.call;
    const paren = built.tokens.slice()[call.paren_open];

    try built.segments_expect(call.callee_first, call.callee_count, &.{ "models", "CharField" });
    try std.testing.expect(paren.is_punctuation(.paren_open));
    try std.testing.expect(built.pairs.partner_of(call.paren_open) != null);
}

test "a bracketed run is a sequence of its elements" {
    var built: Built = undefined;

    try built.init(.python, "[\"a\", \"b\", 3]");
    defer built.deinit();

    try std.testing.expect(built.summary == .sequence);

    const sequence = built.summary.sequence;

    try std.testing.expectEqual(3, sequence.item_count);

    for ([_][]const u8{ "a", "b", "3" }, 0..) |expected, offset| {
        const item = built.items.get(sequence.item_first + @as(u32, @intCast(offset)));

        try std.testing.expect(item == .literal);
        try std.testing.expectEqualStrings(expected, built.text_of(item.literal.content));
    }
}

test "a nested sequence inside an item is dynamic" {
    var built: Built = undefined;

    try built.init(.python, "[[\"a\"], \"b\"]");
    defer built.deinit();

    try std.testing.expect(built.summary == .sequence);

    const sequence = built.summary.sequence;

    try std.testing.expectEqual(2, sequence.item_count);
    try std.testing.expect(built.items.get(sequence.item_first) == .dynamic);
}

test "a trailing comma does not add an element" {
    var built: Built = undefined;

    try built.init(.python, "(\"a\", \"b\",)");
    defer built.deinit();

    try std.testing.expect(built.summary == .sequence);
    try std.testing.expectEqual(2, built.summary.sequence.item_count);
}

test "an expression the reader cannot classify is dynamic" {
    for ([_][]const u8{ "a + b", "a[0]", "-1", "lambda: 1" }) |source| {
        var built: Built = undefined;

        try built.init(.python, source);
        defer built.deinit();

        try std.testing.expect(built.summary == .dynamic);
    }
}

test "byte soup classifies without panicking" {
    const alphabet = "()[]{}\"'.,abc123 \nTrueNonef";
    var random: Random = .init(0x1234_5678_9ABC_DEF1);
    var source: [64]u8 = undefined;

    for (0..256) |_| {
        const length = random.below(source.len);

        for (source[0..length]) |*byte| {
            byte.* = alphabet[random.below(alphabet.len)];
        }

        var built: Built = undefined;

        try built.init(.python, source[0..length]);
        defer built.deinit();

        if (built.summary == .literal) {
            try std.testing.expect(built.summary.literal.content.end() <= length);
        }

        for (built.items.const_slice()) |item| {
            try std.testing.expect(item != .sequence);
        }
    }
}

test "a javascript template literal is dynamic" {
    var built: Built = undefined;

    try built.init(.javascript, "`a${b}c`");
    defer built.deinit();

    try std.testing.expect(built.summary == .dynamic);
}

test "the literal words are sorted and hold every language constant" {
    for (literal_words[1..], literal_words[0 .. literal_words.len - 1]) |word, previous| {
        try std.testing.expect(std.mem.order(u8, previous, word) == .lt);
    }

    for ([_][]const u8{ "iota", "nil", "None", "undefined" }) |word| {
        try std.testing.expect(is_literal_word(word));
    }
}
