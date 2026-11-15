const std = @import("std");
const assert = std.debug.assert;
const Brackets = @import("walk.zig").Brackets;
const Token = @import("../syntax/token.zig");
const is_close = @import("walk.zig").is_close;
const is_open = @import("walk.zig").is_open;
const opened_by = @import("walk.zig").opened_by;
const substituting = @import("walk.zig").substituting;
const optional_marks = true;
const short_element_max: u32 = 10;

pub fn branched(
    source: []const u8,
    tokens: []const Token,
    brackets: *const Brackets,
    position: u32,
) bool {
    assert(position <= tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    var depth: u32 = 0;
    var scan = position;

    while (scan > 0) {
        scan -= 1;

        const token = tokens[scan];

        if (is_close(token.kind)) {
            const jumped = if (depth == 0) brackets.open_of(scan) else null;

            if (jumped) |open| {
                assert(open < scan);

                scan = open;

                continue;
            }

            depth += 1;

            continue;
        }

        const opening = is_open(token.kind) or substituting(source, token);

        if (opening) {
            if (depth == 0) return false;

            depth -= 1;

            continue;
        }

        if (depth > 0) continue;

        if (std.mem.eql(u8, token.text(source), "?")) {
            const optional = optional_marks and optional_marked(tokens, brackets, scan);
            if (optional) continue;
            return true;
        }

        if (token.is_punctuation(.comma)) return false;
        if (token.is_punctuation(.semicolon)) return false;
    }

    return false;
}

pub fn short_elements(tokens: []const Token, open: u32, close: u32) bool {
    assert(tokens.len < std.math.maxInt(u32));
    if (open < close) assert(close < tokens.len);

    var depth: u32 = 0;
    var first: ?u32 = null;
    var last = open;
    var scan = open + 1;

    while (scan <= close) : (scan += 1) {
        const kind = tokens[scan].kind;
        const ended = scan == close or (depth == 0 and kind.eql(.{ .punctuation = .comma }));

        if (ended) {
            if (first) |held| {
                const from = tokens[held].offset;
                if (tokens[last].end() - from > short_element_max) return false;
            }

            first = null;
        }

        const counted = !ended and kind != .newline;

        if (counted) {
            if (first == null) first = scan;

            last = scan;
        }

        if (is_open(kind)) depth += 1;
        if (is_close(kind)) depth -|= 1;
    }

    assert(scan > close);

    return true;
}

pub fn opened(source: []const u8, tokens: []const Token, position: u32) ?u32 {
    assert(position < tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    const close = tokens[position].kind;
    const open = opened_by(close);
    var depth: u32 = 0;

    for (0..position + 1) |step| {
        const scan: u32 = position - @as(u32, @intCast(step));
        const held = tokens[scan];

        if (held.kind.eql(close)) {
            depth += 1;

            continue;
        }

        const substitutes = open == .block_start and substituting(source, held);
        const opening = held.kind.eql(open) or substitutes;
        if (!opening) continue;

        depth -|= 1;

        if (depth == 0) {
            assert(scan <= source.len);

            return scan;
        }
    }

    return null;
}

fn opening_statement(source: []const u8, tokens: []const Token, position: u32) bool {
    assert(position <= tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    var depth: u32 = 0;
    var scan = position;

    while (scan > 0) {
        scan -= 1;

        const token = tokens[scan];

        if (is_close(token.kind)) {
            depth += 1;

            continue;
        }

        const opening = is_open(token.kind) or substituting(source, token);

        if (opening) {
            if (depth == 0) return true;

            depth -= 1;

            continue;
        }

        if (depth > 0) continue;
        if (token.is_punctuation(.comma)) return false;

        const ends = token.kind == .block_end or token.kind == .comment;
        if (ends) return true;
        if (token.is_punctuation(.semicolon)) return true;
    }

    return true;
}

fn optional_marked(tokens: []const Token, brackets: *const Brackets, position: u32) bool {
    assert(position < tokens.len);

    const next = coded_after(tokens, position) orelse return false;
    const token = tokens[next];

    const ends = switch (token.kind) {
        .punctuation => |punctuation| switch (punctuation) {
            .colon, .comma, .semicolon, .paren_close => true,
            else => false,
        },
        else => false,
    };

    if (ends) return true;
    if (!token.is_punctuation(.paren_open)) return false;
    if (tokens[position].end() != token.offset) return false;

    const close = brackets.close_of(next) orelse return false;
    const after = coded_after(tokens, close) orelse return false;

    assert(after > close);

    return switch (tokens[after].kind) {
        .block_start => true,
        .punctuation => |punctuation| punctuation == .colon or punctuation == .semicolon,
        else => false,
    };
}

fn coded_after(tokens: []const Token, position: u32) ?u32 {
    assert(position < tokens.len);

    var scan = position + 1;

    while (scan < tokens.len) : (scan += 1) {
        const kind = tokens[scan].kind;
        if (kind == .newline) continue;
        if (kind == .comment) continue;

        assert(scan > position);

        return scan;
    }

    return null;
}

test "a question mark before the position branches unless it marks an optional" {
    var lexed = try Lexed.init(.typescript, "a ? b : c; f(x?: T)");
    defer lexed.deinit();

    const tokens = lexed.tokens.slice();
    var brackets: Brackets = try .init(std.testing.allocator, 32);
    defer brackets.deinit(std.testing.allocator);

    try brackets.build(lexed.source, tokens, &.{}, false);

    try std.testing.expect(branched(lexed.source, tokens, &brackets, 4));
    try std.testing.expect(!branched(lexed.source, tokens, &brackets, 1));
    try std.testing.expect(!branched(lexed.source, tokens, &brackets, 10));
}

test "elements are short while each stays within ten bytes" {
    var lexed = try Lexed.init(.javascript, "[1, 2, 3] [abcdefghijkl, b]");
    defer lexed.deinit();

    const tokens = lexed.tokens.slice();

    try std.testing.expect(short_elements(tokens, 0, 6));
    try std.testing.expect(!short_elements(tokens, 7, 11));
}

test "a close finds its open and a statement finds its start" {
    var lexed = try Lexed.init(.javascript, "f(a(b)); x = 1; g(c, d)");
    defer lexed.deinit();

    const tokens = lexed.tokens.slice();

    try std.testing.expectEqual(@as(?u32, 1), opened(lexed.source, tokens, 6));
    try std.testing.expectEqual(@as(?u32, 3), opened(lexed.source, tokens, 5));
    try std.testing.expectEqual(@as(?u32, null), opened(lexed.source, tokens, 0));
    try std.testing.expect(opening_statement(lexed.source, tokens, 8));
    try std.testing.expect(!opening_statement(lexed.source, tokens, 17));
    try std.testing.expect(opening_statement(lexed.source, tokens, 15));
}

const Lexed = @import("../syntax/testing/lexed.zig").Lexed;
