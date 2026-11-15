const std = @import("std");
const assert = std.debug.assert;
const trivia = @import("../trivia.zig");
const Token = @import("../token.zig");

pub fn gaps_tile(tokens: []const Token, consumed: u32) void {
    assert(tokens.len <= std.math.maxInt(u32));
    assert(consumed < std.math.maxInt(u32));

    var gaps = trivia.gaps(Token, consumed, tokens);
    var covered: u64 = 0;
    var end_previous: u32 = 0;
    var gap_count: u32 = 0;

    while (gaps.next()) |gap| : (gap_count += 1) {
        assert(gap_count <= tokens.len);
        assert(gap.span.offset >= end_previous);
        assert(gap.token == gap_count);

        covered += gap.span.length;
        end_previous = gap.span.end();
    }

    for (tokens) |token| covered += token.length;

    assert(covered == consumed);
}

pub fn tokens_check(source: []const u8, tokens: []const Token) void {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    var end_previous: u32 = 0;

    for (tokens) |token| {
        assert(token.offset >= end_previous);
        assert(token.end() <= source.len);

        if (token.length == 0) {
            switch (token.kind) {
                .block_end, .block_start, .newline => {},
                else => unreachable,
            }
        }

        end_previous = token.end();
    }
}

pub fn tokens_equal(expected: []const Token, actual: []const Token) bool {
    if (expected.len != actual.len) return false;

    for (expected, actual) |first, second| {
        if (first.offset != second.offset) return false;
        if (first.length != second.length) return false;
        if (!first.kind.eql(second.kind)) return false;
    }

    return true;
}
