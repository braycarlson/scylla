const std = @import("std");
const assert = std.debug.assert;
const Span = @import("../stdx/bounded/span.zig");
const scan = @import("../text/scan.zig");

offset: u32,
length: u32,
kind: Kind,
code: u16 = code_none,

pub const Kind = union(enum) {
    block_end,
    block_start,
    comment,
    identifier,
    keyword: Keyword,
    newline,
    number,
    punctuation: Punctuation,
    string,

    pub fn eql(kind: Kind, other: Kind) bool {
        if (std.meta.activeTag(kind) != std.meta.activeTag(other)) return false;

        const equal = std.meta.eql(kind, other);

        if (equal) assert(std.meta.activeTag(kind) == std.meta.activeTag(other));

        return equal;
    }

    pub fn name(kind: Kind) []const u8 {
        const result: []const u8 = switch (kind) {
            .keyword => "keyword",
            .punctuation => "punctuation",
            inline else => |_, tag| comptime scan.kebab_of(@tagName(tag)),
        };

        assert(result.len > 0);
        assert(std.mem.findScalar(u8, result, '_') == null);

        return result;
    }
};

pub const Keyword = enum(u8) {
    assert,
    branch,
    branch_else,
    @"break",
    constant,
    @"continue",
    declare,
    except,
    function,
    global,
    goto,
    import,
    lambda,
    loop,
    loop_unbounded,
    match,
    mutable,
    other,
    @"return",
    @"struct",
    @"try",

    pub fn name(keyword: Keyword) []const u8 {
        const result: []const u8 = switch (keyword) {
            inline else => |tag| comptime scan.kebab_of(@tagName(tag)),
        };

        assert(result.len > 0);
        assert(std.mem.findScalar(u8, result, '_') == null);

        return result;
    }
};

pub const Punctuation = scan.Punctuation;
const Token = @This();
const code_none: u16 = std.math.maxInt(u16);

comptime {
    assert(@sizeOf(Kind) == 2);
    assert(@sizeOf(Token) == 12);
}

pub fn closes_a_group(token: Token) bool {
    if (token.is_punctuation(.paren_close)) return true;
    return token.is_punctuation(.bracket_close);
}

pub fn closes_a_group_or_block(token: Token) bool {
    if (token.kind == .block_end) return true;

    const closes = token.closes_a_group();

    if (closes) assert(!token.opens_a_group());

    return closes;
}

pub fn end(token: Token) u32 {
    assert(token.length <= std.math.maxInt(u32) - token.offset);

    return token.offset + token.length;
}

pub fn ends_a_value(token: Token) bool {
    assert(token.length <= std.math.maxInt(u32) - token.offset);

    const ends = switch (token.kind) {
        .block_end, .identifier, .number, .string => true,
        .keyword => |keyword| keyword == .other,
        .punctuation => token.closes_a_group(),
        .block_start, .comment, .newline => false,
    };

    if (ends) assert(!token.opens_a_group_or_block());

    return ends;
}

pub fn exact_kind(token: Token, comptime LanguageKind: type) ?LanguageKind {
    comptime {
        const grammar = @hasDecl(LanguageKind, "of_u16") and @hasDecl(LanguageKind, "is_token");

        if (!grammar) {
            @compileError("Token.exact_kind takes a grammar kind such as scylla.python.Kind, " ++
                "not " ++ @typeName(LanguageKind));
        }
    }

    if (token.code == code_none) return null;

    const kind = LanguageKind.of_u16(token.code).?;

    assert(kind.is_token());

    return kind;
}

pub fn is_keyword(token: Token, keyword: Keyword) bool {
    assert(token.length <= std.math.maxInt(u32) - token.offset);

    return switch (token.kind) {
        .keyword => |held| held == keyword,
        else => false,
    };
}

pub fn is_punctuation(token: Token, punctuation: Punctuation) bool {
    assert(token.length <= std.math.maxInt(u32) - token.offset);

    return switch (token.kind) {
        .punctuation => |held| held == punctuation,
        else => false,
    };
}

pub fn is_significant(kind: Kind) bool {
    if (kind == .comment) return false;

    return switch (kind) {
        .comment, .newline => false,
        else => true,
    };
}

pub fn opens_a_group(token: Token) bool {
    if (token.is_punctuation(.paren_open)) return true;
    return token.is_punctuation(.bracket_open);
}

pub fn opens_a_group_or_block(token: Token) bool {
    if (token.kind == .block_start) return true;

    const opens = token.opens_a_group();

    if (opens) assert(!token.closes_a_group_or_block());

    return opens;
}

pub fn span(token: Token) Span {
    assert(token.length <= std.math.maxInt(u32) - token.offset);

    const result: Span = .{ .offset = token.offset, .length = token.length };

    assert(result.end() == token.end());

    return result;
}

pub fn text(token: Token, source: []const u8) []const u8 {
    assert(token.end() <= source.len);

    const result = source[token.offset..token.end()];

    assert(result.len == token.length);

    return result;
}

test Token {
    const source = "one = two";
    const token: Token = .{ .offset = 6, .length = 3, .kind = .identifier };

    try std.testing.expectEqualStrings("two", token.text(source));
    try std.testing.expectEqual(9, token.end());
    try std.testing.expect(!token.is_punctuation(.assign));
    try std.testing.expect(Token.is_significant(token.kind));
}

test "every kind keyword and punctuation has a kebab name" {
    try std.testing.expectEqualStrings("block-start", (Kind{ .block_start = {} }).name());
    try std.testing.expectEqualStrings("keyword", (Kind{ .keyword = .assert }).name());
    try std.testing.expectEqualStrings("loop-unbounded", Keyword.loop_unbounded.name());
    try std.testing.expectEqualStrings("assign-declare", Punctuation.assign_declare.name());
    try std.testing.expectEqualStrings("star", Punctuation.star.name());
}
