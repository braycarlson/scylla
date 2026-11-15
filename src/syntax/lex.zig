const std = @import("std");
const assert = std.debug.assert;
const Dialect = @import("javascript/dialect.zig").Dialect;
const Language = @import("language.zig").Language;
const SourceType = @import("language.zig").SourceType;
const Lexed = @import("testing/lexed.zig").Lexed;
const Token = @import("token.zig");
const Tokens = @import("tokens.zig");
const css = @import("css/lex.zig");
const go = @import("go/lex.zig");
const javascript = @import("javascript/lex.zig");
const odin = @import("odin/lex.zig");
const primitives = @import("lex/primitives.zig");
const python = @import("python/lex.zig");
const rust = @import("rust/lex.zig");
const zig = @import("zig/lex.zig");

pub fn lex(source_type: SourceType, source: []const u8, tokens: *Tokens) Tokens.CapacityError!void {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.count() == 0);
    assert(source_type.language.lexes());
    assert(source_type.valid());

    switch (source_type.language) {
        .css => try css.lex(source, tokens),
        .go => try go.lex(source, tokens),
        .javascript => try javascript.lex(source, tokens, .javascript),
        .odin => try odin.lex(source, tokens),
        .python => try python.lex(source, tokens),
        .rust => try rust.lex(source, tokens),
        .typescript => {
            const dialect: Dialect = if (source_type.flavor == .tsx) .tsx else .typescript;

            try javascript.lex(source, tokens, dialect);
        },
        .zig => try zig.lex(source, tokens),
        .markup => unreachable,
    }

    assert(tokens.end_previous <= source.len);
}

fn lex_bounded(language: Language, source: []const u8, token_count: u32) !bool {
    assert(token_count > 0);
    assert(source.len <= std.math.maxInt(u32));
    assert(language.lexes());

    var tokens: Tokens = try .init(std.testing.allocator, token_count);
    defer tokens.deinit(std.testing.allocator);

    lex(.of(language), source, &tokens) catch |err| switch (err) {
        error.Truncated => {
            assert(tokens.items.full());

            return false;
        },
    };

    return true;
}

const every_lexer = [_]Language{
    .go,
    .javascript,
    .odin,
    .python,
    .rust,
    .typescript,
    .zig,
};

fn invariants_hold(language: Language, source: []const u8) !void {
    assert(source.len <= std.math.maxInt(u32));
    assert(language.lexes());

    var lexed: Lexed = try .init(language, source);
    defer lexed.deinit();

    var end_previous: u32 = 0;

    for (lexed.tokens.slice()) |token| {
        try std.testing.expect(token.end() <= source.len);
        try std.testing.expect(token.offset >= end_previous);

        end_previous = token.end();
    }

    assert(end_previous == lexed.tokens.end_previous);

    var again: Lexed = try .init(language, source);
    defer again.deinit();

    try std.testing.expectEqualSlices(Token, lexed.tokens.slice(), again.tokens.slice());
}

test "a byte order mark is skipped rather than lexed" {
    for (every_lexer) |language| {
        var plain: Lexed = try .init(language, "fn helper() {}\n");
        defer plain.deinit();

        var marked: Lexed = try .init(language, "\xef\xbb\xbffn helper() {}\n");
        defer marked.deinit();

        try std.testing.expectEqual(plain.tokens.count(), marked.tokens.count());

        for (plain.tokens.slice(), marked.tokens.slice()) |bare, token| {
            try std.testing.expectEqual(bare.kind, token.kind);
            try std.testing.expectEqual(bare.length, token.length);
            try std.testing.expectEqual(bare.offset + 3, token.offset);
        }
    }
}

test "a mark on its own lexes to nothing that is not a line" {
    for (every_lexer) |language| {
        var lexed: Lexed = try .init(language, "\xef\xbb\xbf");
        defer lexed.deinit();

        for (lexed.tokens.slice()) |token| {
            try std.testing.expectEqual(Token.Kind.newline, token.kind);
        }
    }
}

test "a mark in the middle of a file is not a mark" {
    for (every_lexer) |language| {
        var plain: Lexed = try .init(language, "a\nb\n");
        defer plain.deinit();

        var inner: Lexed = try .init(language, "a\n\xef\xbb\xbfb\n");
        defer inner.deinit();

        try std.testing.expect(inner.tokens.count() >= plain.tokens.count());
    }
}

test "every lexer truncates rather than overrunning its token buffer" {
    const source = "a b c d e f g h i j k l m n o p q r s t u v w x y z\n";

    for (every_lexer) |language| {
        try std.testing.expect(!try lex_bounded(language, source, 4));
        try std.testing.expect(try lex_bounded(language, source, 4_096));
    }
}

test "an empty source is complete under any budget" {
    for (every_lexer) |language| {
        try std.testing.expect(try lex_bounded(language, "", 1));
    }
}

test "every lexer holds its invariants on awkward sources" {
    const sources = [_][]const u8{
        "",
        "\n",
        "\r\n",
        "\xef\xbb\xbf",
        "\xef\xbb\xbffn helper() {}\n",
        "fn helper() {\r\n    let value = 1;\r\n}\r\n",
        "\"unterminated",
        "'unterminated",
        "/* unterminated",
        "// trailing comment without a newline",
        "#",
        "\x00",
        "a\x00b\n",
        "let s = \"\xf0\x9f\x98\x80\";\n",
        "\xff\xfe not utf eight at all\n",
        "((((((((((((((((((((\n",
        "))))))))))))))))))))\n",
        "r#\"raw \"quoted\" text\"#\n",
        "/* /* nested */ */\n",
        "\\",
        "0x",
        "1.",
        ".1",
        "1e",
        "a\tb\x0bc\x0cd\n",
    };

    for (every_lexer) |language| {
        for (sources) |source| {
            try invariants_hold(language, source);
        }
    }
}

test "a comment nested past the bound degrades rather than panicking" {
    const opens: [primitives.comment_depth_max + 8][2]u8 = @splat("/*".*);
    const deep = std.mem.asBytes(&opens);

    for (every_lexer) |language| {
        var lexed: Lexed = try .init(language, deep);
        defer lexed.deinit();

        try invariants_hold(language, deep);
        try std.testing.expect(lexed.tokens.count() > 0);
    }
}

fn expect_token_texts(language: Language, source: []const u8, expected: []const []const u8) !void {
    assert(source.len <= std.math.maxInt(u32));
    assert(expected.len <= std.math.maxInt(u32));
    assert(language.lexes());

    var lexed: Lexed = try .init(language, source);
    defer lexed.deinit();

    var matched: usize = 0;

    for (lexed.tokens.slice()) |held| {
        if (held.kind == .newline) continue;

        try std.testing.expect(matched < expected.len);
        try std.testing.expectEqualStrings(expected[matched], held.text(source));

        matched += 1;
    }

    try std.testing.expectEqual(expected.len, matched);
}

test "a no break space separates two words rather than gluing them" {
    for (every_lexer) |language| {
        if (language == .python) continue;
        if (language == .rust) continue;
        if (language == .zig) continue;

        try expect_token_texts(language, "const\u{00a0}value", &.{ "const", "value" });
    }

    for ([_]Language{ .python, .rust, .zig }) |language| {
        try expect_token_texts(language, "const\u{00a0}value", &.{ "const", "\u{00a0}", "value" });
    }
}

test "a latin letter continues an identifier everywhere but in zig" {
    const word = "wert\u{00e4}hnlich";

    for (every_lexer) |language| {
        if (language == .zig) continue;

        try expect_token_texts(language, word ++ " = 1", &.{ word, "=", "1" });
    }

    try expect_token_texts(.zig, word ++ " = 1", &.{ "wert", "\u{00e4}", "hnlich", "=", "1" });
}

test "an emoji is one token of its own width and never part of a name" {
    for (every_lexer) |language| {
        if (language == .css) continue;

        try expect_token_texts(language, "x\u{1f600}y", &.{ "x", "\u{1f600}", "y" });
    }

    try expect_token_texts(.css, "x\u{1f600}y", &.{"x\u{1f600}y"});
}

test "a malformed byte is one token and never joins a name" {
    for (every_lexer) |language| {
        try expect_token_texts(language, "a\xffb", &.{ "a", "\xff", "b" });
        try expect_token_texts(language, "a\xe2\x80b", &.{ "a", "\xe2", "\x80", "b" });
    }
}

test "a javascript line comment ends at a paragraph separator" {
    for ([_]Language{ .javascript, .typescript }) |language| {
        try expect_token_texts(language, "// c\u{2028}x", &.{ "// c", "x" });
        try expect_token_texts(language, "// c\u{2029}x", &.{ "// c", "x" });
        try expect_token_texts(language, "// c\u{00a0}x", &.{"// c\u{00a0}x"});
    }
}

test "a javascript identifier continues with a joiner and stops at a space of any width" {
    for ([_]Language{ .javascript, .typescript }) |language| {
        try expect_token_texts(language, "a\u{200d}b", &.{"a\u{200d}b"});
        try expect_token_texts(language, "a\u{2003}b", &.{ "a", "b" });
        try expect_token_texts(language, "\u{0663}a", &.{ "\u{0663}", "a" });
    }
}
