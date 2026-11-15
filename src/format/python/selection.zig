const std = @import("std");
const assert = std.debug.assert;
const Kind = @import("../python.zig").Kind;
const Run = @import("../python.zig").Run;
const Span = @import("../../stdx/bounded/span.zig");
const Token = @import("../../syntax/token.zig");
const Tree = @import("../../syntax/tree.zig").TreeType(Kind);
const byte_at = @import("../../text/scan.zig").byte_at;

pub fn is_word(kind: Token.Kind) bool {
    if (kind == .comment) return false;

    const result = switch (kind) {
        .identifier, .keyword, .number, .string => true,
        .block_end, .block_start, .comment, .newline, .punctuation => false,
    };

    if (result) assert(!is_line_edge(kind));
    if (result) assert(kind != .comment);

    return result;
}

pub fn words_before(tokens: []const Token, position: u32) u32 {
    assert(tokens.len <= std.math.maxInt(u32));
    assert(position < std.math.maxInt(u32));

    const end = @min(position, tokens.len);
    var found: u32 = 0;

    for (tokens[0..end]) |token| {
        if (is_word(token.kind)) found += 1;
    }

    assert(found <= end);
    assert(found <= position);

    return found;
}

pub fn statements_of(tree: *const Tree, tokens: []const Token, selection: Span) ?Run {
    assert(selection.length <= std.math.maxInt(u32) - selection.offset);

    if (tree.count() == 0) return null;
    assert(tokens.len <= std.math.maxInt(u32));

    var statements: ?Run = null;
    var child = tree.child_first_of(0);

    for (0..tree.count()) |_| {
        const held = child orelse break;
        const span = tree.at(held).span(Token, tokens);
        const end = @max(span.end(), span.offset +| 1);
        const overlaps = span.offset < selection.end() and selection.offset < end;

        if (overlaps) {
            if (statements) |*run| {
                run.last = held;
            } else {
                statements = .{ .first = held, .last = held };
            }
        }

        child = tree.sibling_next_of(held);
    }

    assert(child == null);

    const result = statements orelse return null;

    assert(result.first <= result.last);

    return result;
}

pub fn word_span(tokens: []const Token, before: u32, after: u32) ?Span {
    assert(after >= before);
    assert(tokens.len <= std.math.maxInt(u32));

    const positions = word_positions(tokens, before, after) orelse return null;
    const offset = tokens[line_start_of(tokens, positions.first)].offset;
    const close = tokens[line_end_of(tokens, positions.last)].end();

    assert(close >= offset);

    return .{ .offset = offset, .length = close - offset };
}

pub fn word_positions(tokens: []const Token, before: u32, after: u32) ?Run {
    assert(after >= before);
    assert(tokens.len <= std.math.maxInt(u32));

    var seen: u32 = 0;
    var first: ?u32 = null;
    var last: ?u32 = null;

    for (tokens, 0..) |token, position| {
        if (!is_word(token.kind)) continue;

        if (seen == before) first = @intCast(position);

        seen += 1;

        if (seen == after) {
            last = @intCast(position);

            break;
        }
    }

    const positions: Run = .{ .first = first orelse return null, .last = last orelse return null };

    assert(positions.first <= positions.last);

    return positions;
}

pub fn line_start_of(tokens: []const Token, position: u32) u32 {
    assert(position < tokens.len);

    var start = position;

    for (0..position) |_| {
        if (start == 0) break;
        if (is_line_edge(tokens[start - 1].kind)) break;

        start -= 1;
    }

    assert(start <= position);

    return start;
}

pub fn line_end_of(tokens: []const Token, position: u32) u32 {
    assert(position < tokens.len);

    var end = position;

    for (position..tokens.len) |_| {
        if (tokens[end].kind == .newline) break;
        if (end + 1 == tokens.len) break;

        end += 1;
    }

    assert(end >= position);
    assert(end < tokens.len);

    return end;
}

pub fn is_line_edge(kind: Token.Kind) bool {
    if (kind == .comment) return false;

    const result = switch (kind) {
        .block_end, .block_start, .newline => true,
        else => false,
    };

    if (result) assert(kind != .comment);
    if (result) assert(kind != .identifier);

    return result;
}

pub fn source_span(
    source: []const u8,
    tree: *const Tree,
    tokens: []const Token,
    statements: Run,
) Span {
    assert(statements.first <= statements.last);
    assert(statements.last < tree.count());
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    const opened = tree.at(statements.first).span(Token, tokens);
    const closed = tree.at(statements.last).span(Token, tokens);
    var end = closed.end();

    end += @intCast(std.mem.findNone(u8, source[end..], "\t ") orelse source.len - end);

    if (byte_at(source, end) == '#') {
        end += @intCast(std.mem.findAny(u8, source[end..], "\n\r") orelse source.len - end);
    }

    if (byte_at(source, end) == '\r') end += 1;
    if (byte_at(source, end) == '\n') end += 1;

    assert(end >= opened.offset);
    assert(end <= source.len);

    return .{ .offset = opened.offset, .length = end - opened.offset };
}

pub fn range_span(bytes: []const u8, lines: Run) ?Span {
    assert(lines.first <= lines.last);
    assert(bytes.len <= std.math.maxInt(u32));

    var line: u32 = 0;
    var offset: u32 = 0;
    var start: ?u32 = null;
    var end: u32 = @intCast(bytes.len);

    for (0..bytes.len + 1) |position| {
        if (line == lines.first) {
            if (start == null) start = offset;
        }

        if (line > lines.last) {
            end = offset;

            break;
        }

        if (position == bytes.len) break;

        if (bytes[position] == '\n') {
            line += 1;
            offset = @intCast(position + 1);
        }
    }

    const first = start orelse return null;

    assert(end >= first);

    return .{ .offset = first, .length = end - first };
}
