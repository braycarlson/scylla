const std = @import("std");
const assert = std.debug.assert;
const Language = @import("../language.zig").Language;
const Token = @import("../token.zig");
const Tokens = @import("../tokens.zig");
const lex = @import("../lex.zig").lex;

pub const Lexed = struct {
    source: []const u8,
    tokens: Tokens,

    pub fn init(language: Language, source: []const u8) !Lexed {
        assert(source.len <= std.math.maxInt(u32));
        assert(language.lexes());

        var tokens: Tokens = try .init(std.testing.allocator, token_count_max);
        errdefer tokens.deinit(std.testing.allocator);

        try lex(.of(language), source, &tokens);

        assert(tokens.end_previous <= source.len);

        return .{ .source = source, .tokens = tokens };
    }

    pub fn deinit(lexed: *Lexed) void {
        assert(lexed.tokens.end_previous <= lexed.source.len);
        assert(lexed.tokens.count() <= token_count_max);

        lexed.tokens.deinit(std.testing.allocator);
        lexed.* = undefined;
    }

    pub fn at_offset(lexed: *const Lexed, offset: u32) ?Token {
        assert(offset <= lexed.source.len);

        for (lexed.tokens.slice()) |held| {
            assert(held.end() <= lexed.source.len);

            if (held.offset == offset) return held;
        }

        return null;
    }

    pub fn count_of(lexed: *const Lexed, kind: Token.Kind) u32 {
        assert(lexed.tokens.count() <= token_count_max);

        var count: u32 = 0;

        for (lexed.tokens.slice()) |held| {
            if (held.kind.eql(kind)) count += 1;
        }

        assert(count <= lexed.tokens.count());

        return count;
    }

    pub fn expect_kind_at(lexed: *const Lexed, index: u32, kind: Token.Kind) !void {
        assert(lexed.tokens.end_previous <= lexed.source.len);

        try std.testing.expect(index < lexed.tokens.count());
        try std.testing.expectEqual(kind, lexed.token(index).kind);
    }

    pub fn find(lexed: *const Lexed, word: []const u8) ?Token {
        assert(word.len > 0);
        assert(lexed.tokens.end_previous <= lexed.source.len);

        for (lexed.tokens.slice()) |held| {
            if (std.mem.eql(u8, held.text(lexed.source), word)) return held;
        }

        return null;
    }

    pub fn text_at(lexed: *const Lexed, index: u32) []const u8 {
        assert(index < lexed.tokens.count());

        return lexed.token(index).text(lexed.source);
    }

    pub fn token(lexed: *const Lexed, index: u32) Token {
        assert(index < lexed.tokens.count());

        const held = lexed.tokens.slice()[index];

        assert(held.end() <= lexed.source.len);

        return held;
    }
};

const token_count_max = 4_096;

pub fn expect_kind(
    language: Language,
    source: []const u8,
    word: []const u8,
    kind: Token.Kind,
) !void {
    assert(source.len <= std.math.maxInt(u32));
    assert(word.len > 0);
    assert(std.mem.find(u8, source, word) != null);
    assert(language.lexes());

    var lexed: Lexed = try .init(language, source);
    defer lexed.deinit();

    const found = lexed.find(word) orelse {
        std.debug.print("{s} is not lexed as a token of its own\n", .{word});

        return error.TestUnexpectedResult;
    };

    try std.testing.expectEqual(kind, found.kind);
}

pub fn expect_texts(
    language: Language,
    source: []const u8,
    kind: Token.Kind,
    expected: []const []const u8,
) !void {
    assert(source.len <= std.math.maxInt(u32));
    assert(expected.len <= token_count_max);
    assert(language.lexes());

    var lexed: Lexed = try .init(language, source);
    defer lexed.deinit();

    var matched: u32 = 0;

    for (lexed.tokens.slice()) |held| {
        if (!held.kind.eql(kind)) continue;

        try std.testing.expect(matched < expected.len);
        try std.testing.expectEqualStrings(expected[matched], held.text(source));

        matched += 1;
    }

    try std.testing.expectEqual(expected.len, matched);
}
