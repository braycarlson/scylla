const std = @import("std");
const assert = std.debug.assert;
const Lexed = @import("testing/lexed.zig").Lexed;
const Span = @import("../stdx/bounded/span.zig");
const Token = @import("token.zig");

pub fn expression_start(tokens: []const Token, source: []const u8, index: u32) u32 {
    assert(index < tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    const line = line_start_of_token(tokens, source, index);
    var first = line;

    assert(line <= index);

    for (tokens[line..index], line..) |token, position| {
        if (token.is_punctuation(.assign)) first = @intCast(position + 1);
        if (token.is_punctuation(.assign_declare)) first = @intCast(position + 1);
    }

    assert(first >= line);
    assert(first <= index);
    if (first > line) assert(tokens[first - 1].kind == .punctuation);

    return first;
}

pub fn index_at(comptime T: type, items: []const T, offset: u32) ?u32 {
    comptime assert(@hasField(T, "offset"));
    assert(items.len <= std.math.maxInt(u32));

    const index = index_from(T, items, offset);

    assert(index <= items.len);

    if (index < items.len) {
        if (items[index].offset == offset) return index;
    }

    if (index < items.len) assert(items[index].offset > offset);

    return null;
}

pub fn index_from(comptime T: type, items: []const T, offset: u32) u32 {
    comptime assert(@hasField(T, "offset"));
    comptime assert(@hasDecl(T, "end"));
    assert(items.len <= std.math.maxInt(u32));

    const index = std.sort.partitionPoint(T, items, offset, PredicatesType(T).ends_before);

    assert(index <= items.len);
    if (index < items.len) assert(items[index].offset >= offset);
    if (index > 0) assert(items[index - 1].offset <= offset);

    return @intCast(index);
}

pub fn index_from_hint(comptime T: type, items: []const T, offset: u32, hint: u32) u32 {
    comptime assert(@hasField(T, "offset"));

    assert(hint <= items.len);
    if (hint > 0) assert(PredicatesType(T).ends_before(offset, items[hint - 1]));

    for (items[hint..], hint..) |item, index| {
        if (PredicatesType(T).ends_before(offset, item)) continue;

        assert(item.offset >= offset);

        return @intCast(index);
    }

    assert(items.len == 0 or PredicatesType(T).ends_before(offset, items[items.len - 1]));

    return @intCast(items.len);
}

pub fn index_touching(comptime T: type, items: []const T, offset: u32) ?u32 {
    comptime assert(@hasField(T, "offset"));
    assert(items.len <= std.math.maxInt(u32));

    const after = std.sort.partitionPoint(T, items, offset, PredicatesType(T).opens_before);

    assert(after <= items.len);
    if (after < items.len) assert(items[after].offset >= offset);
    if (after > 0) assert(items[after - 1].offset < offset);

    if (after > 0) {
        if (offset <= items[after - 1].end()) {
            assert(after - 1 < items.len);

            return @intCast(after - 1);
        }
    }

    if (after < items.len) {
        if (items[after].offset == offset) {
            assert(after < items.len);

            return @intCast(after);
        }
    }

    return null;
}

pub fn index_starting_from(comptime T: type, items: []const T, offset: u32) u32 {
    comptime assert(@hasField(T, "offset"));
    assert(items.len <= std.math.maxInt(u32));

    const index = std.sort.partitionPoint(T, items, offset, PredicatesType(T).opens_before);

    assert(index <= items.len);
    if (index < items.len) assert(items[index].offset >= offset);
    if (index > 0) assert(items[index - 1].offset < offset);

    return @intCast(index);
}

pub fn in_span(comptime T: type, items: []const T, within: Span) []const T {
    comptime assert(@hasField(T, "offset"));
    assert(items.len <= std.math.maxInt(u32));
    assert(within.length <= std.math.maxInt(u32) - within.offset);

    const first = index_from(T, items, within.offset);

    const reach = std.sort.partitionPoint(
        T,
        items,
        within.end(),
        PredicatesType(T).opens_before,
    );

    const last = @max(reach, first);

    assert(first <= last);
    assert(last <= items.len);
    assert(reach <= items.len);
    if (last > first) assert(items[first].offset >= within.offset);

    return items[first..last];
}

pub fn keyword_count(tokens: []const Token, keyword: Token.Keyword) u32 {
    assert(tokens.len <= std.math.maxInt(u32));
    assert(keyword != .other);

    var count: u32 = 0;

    for (tokens) |token| {
        if (token.is_keyword(keyword)) count += 1;
    }

    assert(count <= tokens.len);

    return count;
}

pub fn label_start(tokens: []const Token, source: []const u8, index: u32) ?u32 {
    assert(index < tokens.len);

    if (index < 2) return null;

    const colon = index - 1;
    const label = index - 2;

    if (!tokens[colon].is_punctuation(.colon)) return null;
    if (tokens[label].kind != .identifier) return null;
    if (label == line_start_of_token(tokens, source, label)) return null;
    assert(label < index);

    return label;
}

pub fn line_start_of_token(tokens: []const Token, source: []const u8, index: u32) u32 {
    assert(index < tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    var first = index;

    while (first > 0) {
        const previous = tokens[first - 1];

        switch (previous.kind) {
            .newline, .block_start, .block_end => break,
            else => {},
        }

        const gap = previous.end();
        const current = tokens[first].offset;
        if (gap > current) break;
        if (current > source.len) break;
        if (std.mem.findScalar(u8, source[gap..current], '\n') != null) break;

        first -= 1;
    }

    assert(first <= index);
    if (first < index) assert(tokens[first].kind != .newline);

    return first;
}

pub fn opens_a_statement(tokens: []const Token, index: u32) bool {
    assert(index <= tokens.len);

    var offset = index;

    while (offset > 0) {
        offset -= 1;

        const token = tokens[offset];

        switch (token.kind) {
            .comment => continue,
            .block_end, .block_start, .newline => return true,
            else => return token.is_punctuation(.semicolon),
        }
    }

    assert(offset == 0);

    return true;
}

pub fn significant_next(tokens: []const Token, from: u32, until: u32) ?u32 {
    assert(until <= tokens.len);
    assert(from < std.math.maxInt(u32));

    var index = from;

    while (index < until) : (index += 1) {
        if (Token.is_significant(tokens[index].kind)) return index;
    }

    return null;
}

pub fn significant_previous(tokens: []const Token, before: u32) ?u32 {
    assert(before <= tokens.len);

    var index = before;

    while (index > 0) {
        index -= 1;

        if (Token.is_significant(tokens[index].kind)) return index;
    }

    assert(index == 0);

    return null;
}

pub fn significant_previous_in_line(tokens: []const Token, before: u32) ?u32 {
    assert(before <= tokens.len);

    var index = before;

    while (index > 0) {
        index -= 1;

        switch (tokens[index].kind) {
            .block_end, .block_start, .newline => {},
            else => return index,
        }
    }

    assert(index == 0);

    return null;
}

pub fn span_of_range(tokens: []const Token, start: u32, until: u32) Span {
    assert(start < until);
    assert(until <= tokens.len);

    const opened = tokens[start].offset;
    const closed = tokens[until - 1].end();

    assert(closed >= opened);

    return Span.between(opened, closed);
}

pub fn statement_end(tokens: []const Token, start: u32) u32 {
    assert(start <= tokens.len);

    var offset = start;

    while (offset < tokens.len) : (offset += 1) {
        switch (tokens[offset].kind) {
            .newline, .block_start, .block_end => return offset,
            .punctuation => |punctuation| if (punctuation == .semicolon) return offset,
            else => {},
        }
    }

    assert(offset == tokens.len);

    return @intCast(tokens.len);
}

pub fn text_of_range(source: []const u8, tokens: []const Token, first: u32, last: u32) []const u8 {
    assert(first <= last);
    assert(last < tokens.len);

    const start = tokens[first].offset;
    const stop = tokens[last].end();

    assert(start <= stop);
    assert(stop <= source.len);

    return source[start..stop];
}

fn PredicatesType(comptime T: type) type {
    return struct {
        fn ends_before(offset: u32, item: T) bool {
            assert(item.end() >= item.offset);

            if (item.offset < offset) return true;
            if (item.offset > offset) return false;
            return item.end() == offset;
        }

        fn opens_before(offset: u32, item: T) bool {
            assert(item.end() >= item.offset);

            return item.offset < offset;
        }
    };
}

fn spaced(comptime pairs: []const [2]u32) [pairs.len]Token {
    assert(pairs.len <= std.math.maxInt(u32));

    var tokens: [pairs.len]Token = undefined;

    for (pairs, &tokens) |pair, *token| {
        assert(pair[1] <= std.math.maxInt(u32) - pair[0]);

        token.* = .{ .offset = pair[0], .length = pair[1], .kind = .identifier };
    }

    return tokens;
}

fn word_index(lexed: *const Lexed, word: []const u8) u32 {
    assert(word.len <= std.math.maxInt(u32));

    for (lexed.tokens.slice(), 0..) |token, index| {
        if (std.mem.eql(u8, token.text(lexed.source), word)) {
            assert(index < lexed.tokens.slice().len);

            return @intCast(index);
        }
    }

    unreachable;
}

test "an index at an offset names the token that opens there" {
    const tokens = spaced(&.{ .{ 0, 2 }, .{ 3, 0 }, .{ 3, 4 }, .{ 8, 1 } });

    try std.testing.expectEqual(0, index_at(Token, &tokens, 0));
    try std.testing.expectEqual(2, index_at(Token, &tokens, 3));
    try std.testing.expectEqual(3, index_at(Token, &tokens, 8));
    try std.testing.expectEqual(null, index_at(Token, &tokens, 1));
    try std.testing.expectEqual(null, index_at(Token, &tokens, 9));
    try std.testing.expectEqual(null, index_at(Token, &tokens, 2));
    try std.testing.expectEqual(null, index_at(Token, &.{}, 0));
}

test "an index from an offset is the first token not ending before it" {
    const tokens = spaced(&.{ .{ 0, 2 }, .{ 3, 0 }, .{ 3, 4 }, .{ 8, 1 } });

    try std.testing.expectEqual(0, index_from(Token, &tokens, 0));
    try std.testing.expectEqual(1, index_from(Token, &tokens, 1));
    try std.testing.expectEqual(2, index_from(Token, &tokens, 3));
    try std.testing.expectEqual(4, index_from(Token, &tokens, 9));
    try std.testing.expectEqual(0, index_from(Token, &.{}, 5));
}

test "a touching index prefers the token the offset ends or lands in" {
    const tokens = spaced(&.{ .{ 0, 2 }, .{ 3, 4 }, .{ 8, 1 } });

    try std.testing.expectEqual(0, index_touching(Token, &tokens, 0));
    try std.testing.expectEqual(0, index_touching(Token, &tokens, 1));
    try std.testing.expectEqual(0, index_touching(Token, &tokens, 2));
    try std.testing.expectEqual(1, index_touching(Token, &tokens, 3));
    try std.testing.expectEqual(1, index_touching(Token, &tokens, 7));
    try std.testing.expectEqual(2, index_touching(Token, &tokens, 8));
    try std.testing.expectEqual(null, index_touching(Token, &tokens, 10));
    try std.testing.expectEqual(null, index_touching(Token, &.{}, 0));
}

test "the tokens in a span are those opening inside it" {
    const tokens = spaced(&.{ .{ 0, 2 }, .{ 3, 4 }, .{ 8, 1 }, .{ 10, 2 } });

    try std.testing.expectEqual(2, in_span(Token, &tokens, Span.between(3, 9)).len);
    try std.testing.expectEqual(1, in_span(Token, &tokens, Span.between(3, 8)).len);
    try std.testing.expectEqual(4, in_span(Token, &tokens, Span.between(0, 12)).len);
    try std.testing.expectEqual(0, in_span(Token, &tokens, Span.between(1, 3)).len);
    try std.testing.expectEqual(0, in_span(Token, &tokens, Span.between(12, 12)).len);
    try std.testing.expectEqual(0, in_span(Token, &.{}, Span.between(0, 4)).len);
}

test "an expression starts after the assignment on its line" {
    const source = "fn held() {\n    let value = first + second;\n}\n";
    var lexed: Lexed = try .init(.rust, source);
    defer lexed.deinit();

    const second = word_index(&lexed, "second");
    const start = expression_start(lexed.tokens.slice(), source, second);

    try std.testing.expectEqual(word_index(&lexed, "first"), start);
}

test "an expression with no assignment starts at its line" {
    const source = "fn held() {\n    call(first, second);\n}\n";
    var lexed: Lexed = try .init(.rust, source);
    defer lexed.deinit();

    const second = word_index(&lexed, "second");
    const start = expression_start(lexed.tokens.slice(), source, second);

    try std.testing.expectEqual(word_index(&lexed, "call"), start);
}

test "an index from a hint matches the index from the start" {
    const tokens = spaced(&.{ .{ 0, 2 }, .{ 3, 4 }, .{ 8, 1 } });

    for ([_]u32{ 0, 1, 3, 5, 8, 9 }) |offset| {
        const index = index_from(Token, &tokens, offset);

        try std.testing.expectEqual(index, index_from_hint(Token, &tokens, offset, 0));
        try std.testing.expectEqual(index, index_from_hint(Token, &tokens, offset, index));
    }
}

test "an index starting from an offset is the first token opening at or after it" {
    const tokens = spaced(&.{ .{ 0, 2 }, .{ 3, 4 }, .{ 8, 1 } });

    try std.testing.expectEqual(0, index_starting_from(Token, &tokens, 0));
    try std.testing.expectEqual(1, index_starting_from(Token, &tokens, 1));
    try std.testing.expectEqual(2, index_starting_from(Token, &tokens, 5));
    try std.testing.expectEqual(3, index_starting_from(Token, &tokens, 9));
}

test "a label starts two tokens before the block it names" {
    const source = "fn f() void {\n    const x = outer: {\n        break :outer 1;\n    };\n}\n";
    var lexed: Lexed = try .init(.zig, source);
    defer lexed.deinit();

    const label = word_index(&lexed, "outer");
    const brace = label + 2;

    try std.testing.expectEqual(label, label_start(lexed.tokens.slice(), source, brace));
    try std.testing.expectEqual(null, label_start(lexed.tokens.slice(), source, 1));
}

test "a line starts at the first token after the preceding break" {
    const source = "fn f() {\n    let a = b;\n}\n";
    var lexed: Lexed = try .init(.rust, source);
    defer lexed.deinit();

    const tokens = lexed.tokens.slice();
    const named = word_index(&lexed, "b");
    const start = line_start_of_token(tokens, source, named);

    try std.testing.expectEqual(word_index(&lexed, "let"), start);
    try std.testing.expectEqual(0, line_start_of_token(tokens, source, 2));
}

test "a statement opens after a break or a semicolon" {
    const source = "fn f() {\n    a; b\n}\n";
    var lexed: Lexed = try .init(.rust, source);
    defer lexed.deinit();

    const tokens = lexed.tokens.slice();

    try std.testing.expect(opens_a_statement(tokens, 0));
    try std.testing.expect(opens_a_statement(tokens, word_index(&lexed, "b")));
    try std.testing.expect(!opens_a_statement(tokens, word_index(&lexed, "f")));
}

test "the next significant token skips comments and breaks" {
    const source = "x = 1  # note\ny\n";
    var lexed: Lexed = try .init(.python, source);
    defer lexed.deinit();

    const tokens = lexed.tokens.slice();
    const one = word_index(&lexed, "1");
    const until: u32 = @intCast(tokens.len);

    try std.testing.expectEqual(word_index(&lexed, "y"), significant_next(tokens, one + 1, until));
    try std.testing.expectEqual(null, significant_next(tokens, one + 1, one + 2));
}

test "the previous significant token skips comments and breaks" {
    const source = "x = 1  # note\ny\n";
    var lexed: Lexed = try .init(.python, source);
    defer lexed.deinit();

    const tokens = lexed.tokens.slice();
    const named = word_index(&lexed, "y");

    try std.testing.expectEqual(word_index(&lexed, "1"), significant_previous(tokens, named - 1));
    try std.testing.expectEqual(null, significant_previous(tokens, 0));
}

test "the previous significant token in a line skips only breaks" {
    const source = "x = 1\ny\n";
    var lexed: Lexed = try .init(.python, source);
    defer lexed.deinit();

    const tokens = lexed.tokens.slice();
    const named = word_index(&lexed, "y");
    const previous = significant_previous_in_line(tokens, named);

    try std.testing.expectEqual(word_index(&lexed, "1"), previous);
    try std.testing.expectEqual(null, significant_previous_in_line(tokens, 0));
}

test "a range spans from the first token to the end of the last" {
    const tokens = spaced(&.{ .{ 0, 2 }, .{ 3, 4 }, .{ 8, 1 } });

    try std.testing.expectEqual(Span.between(0, 7), span_of_range(&tokens, 0, 2));
    try std.testing.expectEqual(Span.between(8, 9), span_of_range(&tokens, 2, 3));
}

test "a statement ends at a semicolon or a break" {
    const source = "fn f() {\n    a; b\n}\n";
    var lexed: Lexed = try .init(.rust, source);
    defer lexed.deinit();

    const tokens = lexed.tokens.slice();
    const end: u32 = @intCast(tokens.len);
    const first = word_index(&lexed, "a");

    try std.testing.expectEqual(first + 1, statement_end(tokens, first));
    try std.testing.expectEqual(end, statement_end(tokens, end));
}

test "the text of a range runs from the first token through the last" {
    const source = "let value = first + second;\n";
    var lexed: Lexed = try .init(.rust, source);
    defer lexed.deinit();

    const first = word_index(&lexed, "first");
    const last = word_index(&lexed, "second");
    const text = text_of_range(source, lexed.tokens.slice(), first, last);

    try std.testing.expectEqualStrings("first + second", text);
}
