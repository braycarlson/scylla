const std = @import("std");
const assert = std.debug.assert;
const Kind = @import("kind.zig").Kind;
const PRNG = @import("../../testing/prng.zig");
const Token = @import("../token.zig");
const Tokens = @import("../tokens.zig");
const expression = @import("expression.zig");
const primitives = @import("../lex/primitives.zig");
const scan = @import("../../text/scan.zig");
const unicode = @import("../../text/unicode.zig");
const Lexed = @import("../testing/lexed.zig").Lexed;

const Scanned = struct {
    kind: Kind,
    end: u32,
};

const operators_wide = std.StaticStringMap(Kind).initComptime(.{
    .{ "::", .colon_colon },
    .{ "$=", .dollar_equal },
    .{ "*=", .star_equal },
    .{ "^=", .caret_equal },
    .{ "|=", .bar_equal },
    .{ "~=", .tilde_equal },
});

pub fn lex(source: []const u8, tokens: *Tokens) error{Truncated}!void {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.count() == 0);

    var offset = scan.mark_width(source);

    while (offset < source.len) {
        const blank = scan.whitespace_end(source, offset);

        if (blank > offset) {
            offset = blank;

            continue;
        }

        const scanned = scanned_of(source, offset);

        assert(scanned.end > offset);
        assert(scanned.end <= source.len);

        try tokens.push(source, token_of(scanned.kind, offset, scanned.end));
        offset = scanned.end;

        if (!is_numeric(scanned.kind)) continue;

        const unit = expression.unit_end(source, offset) orelse continue;

        assert(unit > offset);

        try tokens.push(source, token_of(.unit, offset, unit));
        offset = unit;
    }

    assert(offset == source.len);
}

fn token_of(kind: Kind, offset: u32, end: u32) Token {
    assert(kind.is_token());
    assert(end > offset);

    return .{
        .offset = offset,
        .length = end - offset,
        .kind = kind.token_kind(),
        .code = kind.to_u16(),
    };
}

fn is_numeric(kind: Kind) bool {
    if (kind.token_kind() != .number) return false;

    const result = kind == .number or kind == .float;

    if (result) assert(kind.token_kind() == .number);

    return result;
}

fn scanned_of(source: []const u8, offset: u32) Scanned {
    assert(offset < source.len);
    assert(scan.whitespace_width(source, offset) == 0);

    const byte = source[offset];

    return switch (byte) {
        '\\' => .{ .kind = .escape, .end = scan.escape_end(source, offset) },
        '/' => if (scan.byte_at(source, offset + 1) == '*') .{
            .kind = .comment,
            .end = comment_end(source, offset),
        } else operator_of(source, offset),
        '"', '\'' => .{
            .kind = .text,
            .end = primitives.string_scan_multiline(source, offset, byte),
        },
        '{' => .{ .kind = .brace_open, .end = offset + 1 },
        '}' => .{ .kind = .brace_close, .end = offset + 1 },
        '@' => .{ .kind = .at, .end = offset + 1 },
        else => number_or_name_of(source, offset),
    };
}

fn number_or_name_of(source: []const u8, offset: u32) Scanned {
    assert(offset < source.len);

    const byte = source[offset];
    const numeric = std.ascii.isDigit(byte) or byte == '+' or byte == '-' or byte == '.';

    if (numeric) {
        if (expression.number_end(source, offset)) |number| {
            return .{ .kind = number.kind, .end = number.reach };
        }
    }

    if (is_name_start_at(source, offset)) {
        if (expression.identifier_end(source, offset)) |end| {
            return .{ .kind = .identifier, .end = end };
        }
    }

    return operator_of(source, offset);
}

fn operator_of(source: []const u8, offset: u32) Scanned {
    assert(offset < source.len);

    if (source.len - offset >= 2) {
        if (operators_wide.get(source[offset..][0..2])) |kind| {
            return .{ .kind = kind, .end = offset + 2 };
        }
    }

    const kind: Kind = switch (source[offset]) {
        '!' => .bang,
        '#' => .hash,
        '$' => .dollar,
        '%' => .percent,
        '&' => .ampersand,
        '(' => .paren_open,
        ')' => .paren_close,
        '*' => .star,
        '+' => .plus,
        ',' => .comma,
        '-' => .minus,
        '.' => .dot,
        '/' => .slash,
        ':' => .colon,
        ';' => .semicolon,
        '<' => .less,
        '=' => .equal,
        '>' => .greater,
        '?' => .question,
        '[' => .bracket_open,
        ']' => .bracket_close,
        '^' => .caret,
        '|' => .pipe,
        '~' => .tilde,
        else => .error_token,
    };

    assert(kind.is_token());

    return .{ .kind = kind, .end = offset + 1 };
}

fn comment_end(source: []const u8, start: u32) u32 {
    assert(start + 2 <= source.len);
    assert(source[start] == '/');
    assert(source[start + 1] == '*');

    const end: u32 = if (std.mem.findPos(u8, source, start + 2, "*/")) |close|
        @intCast(close + 2)
    else
        @intCast(source.len);

    assert(end >= start + 2);
    assert(end <= source.len);

    return end;
}

fn is_name_start_at(source: []const u8, offset: u32) bool {
    assert(offset < source.len);

    const byte = source[offset];
    if (byte < 0x80) return expression.is_name_start(byte);
    return unicode.decode(source, offset) != null;
}

const Expected = struct {
    kind: Kind,
    text: []const u8,
};

fn expect_spans(source: []const u8, expected: []const Expected) !void {
    assert(source.len <= std.math.maxInt(u32));

    var lexed: Lexed = try .init(.css, source);
    defer lexed.deinit();

    try std.testing.expectEqual(expected.len, lexed.tokens.count());

    for (expected, lexed.tokens.slice()) |span, token| {
        try std.testing.expectEqual(span.kind, token.exact_kind(Kind).?);
        try std.testing.expectEqual(span.kind.token_kind(), token.kind);
        try std.testing.expectEqualStrings(span.text, token.text(source));
    }
}

fn expect_span_at(source: []const u8, index: u32, expected: Expected) !void {
    assert(source.len <= std.math.maxInt(u32));
    assert(index < std.math.maxInt(u32));
    assert(expected.text.len > 0);

    var lexed: Lexed = try .init(.css, source);
    defer lexed.deinit();

    try lexed.expect_kind_at(index, expected.kind.token_kind());
    try std.testing.expectEqual(expected.kind, lexed.token(index).exact_kind(Kind).?);
    try std.testing.expectEqualStrings(expected.text, lexed.text_at(index));
}

fn expect_in_bounds(lexed: *const Lexed) !void {
    var end_previous: u32 = 0;

    for (lexed.tokens.slice()) |token| {
        try std.testing.expect(token.end() <= lexed.source.len);
        try std.testing.expect(token.offset >= end_previous);
        try std.testing.expect(token.exact_kind(Kind) != null);

        end_previous = token.end();
    }
}

test "a declaration lexes to a name a colon a value and a semicolon" {
    try expect_spans("color: red;", &.{
        .{ .kind = .identifier, .text = "color" },
        .{ .kind = .colon, .text = ":" },
        .{ .kind = .identifier, .text = "red" },
        .{ .kind = .semicolon, .text = ";" },
    });
}

test "a hyphenated property stays one name" {
    const name: Expected = .{ .kind = .identifier, .text = "background-color" };

    try expect_span_at("background-color: blue;", 0, name);
}

test "an at rule splits its mark from its name" {
    try expect_spans("@media print {}", &.{
        .{ .kind = .at, .text = "@" },
        .{ .kind = .identifier, .text = "media" },
        .{ .kind = .identifier, .text = "print" },
        .{ .kind = .brace_open, .text = "{" },
        .{ .kind = .brace_close, .text = "}" },
    });
}

test "a rule body opens and closes a block" {
    var lexed: Lexed = try .init(.css, "a { b: c }");
    defer lexed.deinit();

    const kinds = [_]Token.Kind{
        .identifier,
        .block_start,
        .identifier,
        .{ .punctuation = .colon },
        .identifier,
        .block_end,
    };

    try std.testing.expectEqual(kinds.len, lexed.tokens.count());

    for (kinds, lexed.tokens.slice()) |kind, token| {
        try std.testing.expectEqual(kind, token.kind);
    }
}

test "a comment is one token and an unterminated one runs to the end" {
    const closed: Expected = .{ .kind = .comment, .text = "/* note */" };
    const open: Expected = .{ .kind = .comment, .text = "/* open" };

    try expect_span_at("/* note */ a {}", 0, closed);
    try expect_span_at("/* open", 0, open);
}

test "a string keeps its quotes and spans its lines" {
    const double: Expected = .{ .kind = .text, .text = "\"a b\"" };
    const single: Expected = .{ .kind = .text, .text = "'a b'" };

    try expect_span_at("content: \"a b\";", 2, double);
    try expect_span_at("content: 'a b';", 2, single);
}

test "a dimension splits its number from its unit" {
    try expect_spans("a{b:10px}", &.{
        .{ .kind = .identifier, .text = "a" },
        .{ .kind = .brace_open, .text = "{" },
        .{ .kind = .identifier, .text = "b" },
        .{ .kind = .colon, .text = ":" },
        .{ .kind = .number, .text = "10" },
        .{ .kind = .unit, .text = "px" },
        .{ .kind = .brace_close, .text = "}" },
    });

    try expect_span_at("a{b:100%}", 5, .{ .kind = .unit, .text = "%" });
    try expect_span_at("a{b:1.5em}", 4, .{ .kind = .float, .text = "1.5" });
    try expect_span_at("a{b:1.5em}", 5, .{ .kind = .unit, .text = "em" });
}

test "a signed number joins its sign and a spaced sign does not" {
    try expect_span_at("a{b:-50%}", 4, .{ .kind = .number, .text = "-50" });
    try expect_span_at("a{b:+1em}", 4, .{ .kind = .number, .text = "+1" });
    try expect_span_at("a{b:1 - 2}", 5, .{ .kind = .minus, .text = "-" });
}

test "a unit a plain value outruns stays an identifier" {
    try expect_spans("a{b:12px/1.5}", &.{
        .{ .kind = .identifier, .text = "a" },
        .{ .kind = .brace_open, .text = "{" },
        .{ .kind = .identifier, .text = "b" },
        .{ .kind = .colon, .text = ":" },
        .{ .kind = .number, .text = "12" },
        .{ .kind = .identifier, .text = "px" },
        .{ .kind = .slash, .text = "/" },
        .{ .kind = .float, .text = "1.5" },
        .{ .kind = .brace_close, .text = "}" },
    });
}

test "the selector marks carry their own kinds" {
    const expected = [_]Kind{
        .identifier,
        .colon_colon,
        .identifier,
        .dot,
        .identifier,
        .hash,
        .identifier,
        .bracket_open,
        .identifier,
        .tilde_equal,
        .identifier,
        .bracket_close,
        .brace_open,
        .brace_close,
    };

    var lexed: Lexed = try .init(.css, "a::b .c#d[e~=f]{}");
    defer lexed.deinit();

    try std.testing.expectEqual(expected.len, lexed.tokens.count());

    for (expected, lexed.tokens.slice()) |wanted, held| {
        try std.testing.expectEqual(wanted, held.exact_kind(Kind).?);
    }
}

test "an escape outside a string is its own token" {
    try expect_spans(".d\\:e{}", &.{
        .{ .kind = .dot, .text = "." },
        .{ .kind = .identifier, .text = "d" },
        .{ .kind = .escape, .text = "\\:" },
        .{ .kind = .identifier, .text = "e" },
        .{ .kind = .brace_open, .text = "{" },
        .{ .kind = .brace_close, .text = "}" },
    });
}

test "every operator reaches its kind" {
    const cases = [_]Expected{
        .{ .kind = .colon_colon, .text = "::" },
        .{ .kind = .dollar_equal, .text = "$=" },
        .{ .kind = .star_equal, .text = "*=" },
        .{ .kind = .caret_equal, .text = "^=" },
        .{ .kind = .bar_equal, .text = "|=" },
        .{ .kind = .tilde_equal, .text = "~=" },
        .{ .kind = .bang, .text = "!" },
        .{ .kind = .hash, .text = "#" },
        .{ .kind = .dollar, .text = "$" },
        .{ .kind = .percent, .text = "%" },
        .{ .kind = .ampersand, .text = "&" },
        .{ .kind = .paren_open, .text = "(" },
        .{ .kind = .paren_close, .text = ")" },
        .{ .kind = .star, .text = "*" },
        .{ .kind = .plus, .text = "+" },
        .{ .kind = .comma, .text = "," },
        .{ .kind = .minus, .text = "-" },
        .{ .kind = .dot, .text = "." },
        .{ .kind = .slash, .text = "/" },
        .{ .kind = .colon, .text = ":" },
        .{ .kind = .semicolon, .text = ";" },
        .{ .kind = .less, .text = "<" },
        .{ .kind = .equal, .text = "=" },
        .{ .kind = .greater, .text = ">" },
        .{ .kind = .question, .text = "?" },
        .{ .kind = .bracket_open, .text = "[" },
        .{ .kind = .bracket_close, .text = "]" },
        .{ .kind = .caret, .text = "^" },
        .{ .kind = .pipe, .text = "|" },
        .{ .kind = .tilde, .text = "~" },
    };

    for (cases) |case| {
        const scanned = operator_of(case.text, 0);

        try std.testing.expectEqual(case.kind, scanned.kind);
        try std.testing.expectEqual(case.text.len, scanned.end);
    }
}

test "a brace is a block kind at any depth and a stray closer is still one" {
    const opens: [72][3]u8 = @splat("a {".*);
    var lexed: Lexed = try .init(.css, std.mem.asBytes(&opens));
    defer lexed.deinit();

    try std.testing.expectEqual(72, lexed.count_of(.block_start));
    try expect_span_at("}", 0, .{ .kind = .brace_close, .text = "}" });
}

test "a selector keeps its marks apart from its name" {
    var lexed: Lexed = try .init(.css, ".card > #main a:hover {}");
    defer lexed.deinit();

    const texts = [_][]const u8{ ".", "card", ">", "#", "main", "a", ":", "hover", "{", "}" };

    try std.testing.expectEqual(texts.len, lexed.tokens.count());

    for (texts, lexed.tokens.slice()) |text, token| {
        try std.testing.expectEqualStrings(text, token.text(lexed.source));
    }
}

test "a non ascii name decodes and a malformed byte stands alone" {
    try expect_spans("caf\u{e9}: \u{2192};", &.{
        .{ .kind = .identifier, .text = "caf\u{e9}" },
        .{ .kind = .colon, .text = ":" },
        .{ .kind = .identifier, .text = "\u{2192}" },
        .{ .kind = .semicolon, .text = ";" },
    });

    try expect_spans("\xff\xfe a", &.{
        .{ .kind = .error_token, .text = "\xff" },
        .{ .kind = .error_token, .text = "\xfe" },
        .{ .kind = .identifier, .text = "a" },
    });
}

test "byte soup lexes in bounds and stably" {
    const alphabet = "{}:;/*\"'@.#-abc123 \n";
    var prng: PRNG = .init(0x7F4A_7C15_9E37_79B9);
    var buffer: [128]u8 = undefined;

    for (0..256) |_| {
        const source = buffer[0..prng.int_inclusive(u32, buffer.len - 1)];

        for (source) |*byte| {
            byte.* = alphabet[prng.index(alphabet.len)];
        }

        var first: Lexed = try .init(.css, source);
        defer first.deinit();

        var again: Lexed = try .init(.css, source);
        defer again.deinit();

        try std.testing.expectEqualSlices(Token, first.tokens.slice(), again.tokens.slice());
        try expect_in_bounds(&first);
    }
}

test "the lexer holds its invariants on awkward sources" {
    const sources = [_][]const u8{
        "",
        "\n",
        "{",
        "}",
        "@",
        "@media",
        "/*",
        "\"open",
        "a{b:c}",
        "\xef\xbb\xbfa {}",
        "\xff\xfe not utf eight",
        "-",
        "--custom-property: 1;",
        "\\",
        "1.",
        ".5em",
    };

    for (sources) |source| {
        var lexed: Lexed = try .init(.css, source);
        defer lexed.deinit();

        try expect_in_bounds(&lexed);
    }
}
