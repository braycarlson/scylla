const std = @import("std");
const assert = std.debug.assert;
const Kind = @import("kind.zig").Kind;
const Span = @import("../../stdx/bounded/span.zig");
const Tokens = @import("tokens.zig").Tokens;

pub const Token = struct {
    kind: Kind,
    length: u32,
    offset: u32,

    pub fn end(token: Token) u32 {
        assert(token.length <= std.math.maxInt(u32) - token.offset);

        return token.offset + token.length;
    }

    pub fn span(token: Token) Span {
        assert(token.length <= std.math.maxInt(u32) - token.offset);

        const held: Span = .{ .length = token.length, .offset = token.offset };

        assert(held.end() == token.end());

        return held;
    }

    pub fn text(token: Token, source: []const u8) []const u8 {
        assert(token.end() <= source.len);

        const stop = token.end();

        assert(stop <= source.len);
        assert(token.offset <= stop);

        return source[token.offset..stop];
    }

    pub fn unquote(token: Token, source: []const u8) ?Span {
        assert(token.kind.is_token());
        assert(source.len <= std.math.maxInt(u32));

        const spelled = token.text(source);
        if (spelled.len == 0) return null;

        const quote = spelled[0];

        if (quote != '"') {
            if (quote != '\'') return token.span();
        }

        if (spelled.len < 2) return null;
        if (spelled[spelled.len - 1] != quote) return null;

        assert(token.length >= 2);

        return .{ .length = token.length - 2, .offset = token.offset + 1 };
    }
};

pub fn source_length(source: []const u8) u32 {
    assert(source.len <= std.math.maxInt(u32));

    const held: u32 = @intCast(source.len);

    assert(held == source.len);

    return held;
}

test Token {
    const source = "{% include 'card.html' %}";
    const argument: Token = .{ .kind = .string, .length = 11, .offset = 11 };
    const inner = argument.unquote(source) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("'card.html'", argument.text(source));
    try std.testing.expectEqualStrings("card.html", inner.text(source));
    try std.testing.expectEqual(22, argument.end());
}

test "a push past the reservation overflows and keeps what was pushed" {
    var tokens: Tokens = try .init(std.testing.allocator, 1);
    defer tokens.deinit(std.testing.allocator);

    try tokens.push(.text, .between(0, 2));
    try std.testing.expectError(error.Overflow, tokens.push(.text, .between(2, 3)));
    try std.testing.expectEqual(1, tokens.count());
    try std.testing.expectEqual(2, tokens.end_previous);
    try std.testing.expectEqual(tokens.capacity(), tokens.count());
}
