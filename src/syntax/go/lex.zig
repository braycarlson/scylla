const std = @import("std");
const assert = std.debug.assert;
const Kind = @import("kind.zig").Kind;
const Token = @import("../token.zig");
const Tokens = @import("../tokens.zig");
const primitives = @import("../lex/primitives.zig");
const scan = @import("../../text/scan.zig");
const unicode = @import("../../text/unicode.zig");
const Lexed = @import("../testing/lexed.zig").Lexed;
const expect_kind = @import("../testing/lexed.zig").expect_kind;
const expect_texts = @import("../testing/lexed.zig").expect_texts;

const Scanned = struct {
    kind: Token.Kind,
    end: u32,
    code: Kind,
};

const assert_methods = [_][]const u8{
    "Contains",
    "Empty",
    "Equal",
    "EqualError",
    "EqualValues",
    "Error",
    "ErrorAs",
    "ErrorIs",
    "False",
    "Greater",
    "GreaterOrEqual",
    "Len",
    "Less",
    "LessOrEqual",
    "Nil",
    "NoError",
    "NotContains",
    "NotEmpty",
    "NotEqual",
    "NotNil",
    "NotZero",
    "Panics",
    "Positive",
    "Same",
    "True",
    "Zero",
};

const declare_word = "func";
const receiver_bytes_max: u32 = 256;
const statement_ends = [_][]const u8{ ")", "++", "--", ":", "]" };

const words = std.StaticStringMap(Token.Kind).initComptime(.{
    .{ "break", Token.Kind{ .keyword = .@"break" } },
    .{ "case", Token.Kind{ .keyword = .other } },
    .{ "chan", Token.Kind{ .keyword = .other } },
    .{ "const", Token.Kind{ .keyword = .constant } },
    .{ "continue", Token.Kind{ .keyword = .@"continue" } },
    .{ "default", Token.Kind{ .keyword = .other } },
    .{ "defer", Token.Kind{ .keyword = .other } },
    .{ "else", Token.Kind{ .keyword = .branch_else } },
    .{ "fallthrough", Token.Kind{ .keyword = .other } },
    .{ "go", Token.Kind{ .keyword = .other } },
    .{ "goto", Token.Kind{ .keyword = .goto } },
    .{ "if", Token.Kind{ .keyword = .branch } },
    .{ "import", Token.Kind{ .keyword = .import } },
    .{ "interface", Token.Kind{ .keyword = .other } },
    .{ "map", Token.Kind{ .keyword = .other } },
    .{ "package", Token.Kind{ .keyword = .other } },
    .{ "range", Token.Kind{ .keyword = .other } },
    .{ "return", Token.Kind{ .keyword = .@"return" } },
    .{ "select", Token.Kind{ .keyword = .match } },
    .{ "struct", Token.Kind{ .keyword = .@"struct" } },
    .{ "switch", Token.Kind{ .keyword = .match } },
    .{ "type", Token.Kind{ .keyword = .@"struct" } },
    .{ "var", Token.Kind{ .keyword = .mutable } },
});

const keywords = std.StaticStringMap(Kind).initComptime(.{
    .{ "break", .break_keyword },
    .{ "case", .case_keyword },
    .{ "chan", .chan_keyword },
    .{ "const", .const_keyword },
    .{ "continue", .continue_keyword },
    .{ "default", .default_keyword },
    .{ "defer", .defer_keyword },
    .{ "else", .else_keyword },
    .{ "fallthrough", .fallthrough_keyword },
    .{ "for", .for_keyword },
    .{ "func", .func_keyword },
    .{ "go", .go_keyword },
    .{ "goto", .goto_keyword },
    .{ "if", .if_keyword },
    .{ "import", .import_keyword },
    .{ "interface", .interface_keyword },
    .{ "map", .map_keyword },
    .{ "package", .package_keyword },
    .{ "range", .range_keyword },
    .{ "return", .return_keyword },
    .{ "select", .select_keyword },
    .{ "struct", .struct_keyword },
    .{ "switch", .switch_keyword },
    .{ "type", .type_keyword },
    .{ "var", .var_keyword },
});

const operators_three = std.StaticStringMap(Kind).initComptime(.{
    .{ "&^=", .ampersand_caret_equal },
    .{ "<<=", .less_less_equal },
    .{ ">>=", .greater_greater_equal },
    .{ "...", .dot_dot_dot },
});

const operators_two = std.StaticStringMap(Kind).initComptime(.{
    .{ "!=", .bang_equal },
    .{ "%=", .percent_equal },
    .{ "&&", .ampersand_ampersand },
    .{ "&=", .ampersand_equal },
    .{ "&^", .ampersand_caret },
    .{ "*=", .star_equal },
    .{ "++", .plus_plus },
    .{ "+=", .plus_equal },
    .{ "--", .minus_minus },
    .{ "-=", .minus_equal },
    .{ "/=", .slash_equal },
    .{ ":=", .colon_equal },
    .{ "<-", .arrow },
    .{ "<<", .less_less },
    .{ "<=", .less_equal },
    .{ "==", .equal_equal },
    .{ ">=", .greater_equal },
    .{ ">>", .greater_greater },
    .{ "^=", .caret_equal },
    .{ "|=", .bar_equal },
    .{ "||", .bar_bar },
});

pub fn lex(source: []const u8, tokens: *Tokens) error{Truncated}!void {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.count() == 0);

    var offset = scan.mark_width(source);
    var ends = false;

    while (offset < source.len) {
        if (source[offset] == '\n') {
            if (ends) try tokens.push(source, newline_of(offset, 1));

            ends = false;
            offset += 1;

            continue;
        }

        const blank = scan.whitespace_end(source, offset);

        if (blank > offset) {
            offset = blank;

            continue;
        }

        const token = token_of(source, offset);

        assert(token.offset == offset);
        assert(token.length > 0);

        try tokens.push(source, token);
        offset = token.end();

        if (token.kind != .comment) {
            ends = ends_statement(token.kind, token.text(source));

            continue;
        }

        if (ends) {
            if (comment_spans_lines(source, token)) {
                try tokens.push(source, newline_of(offset, 0));

                ends = false;
            }
        }
    }

    assert(offset == source.len);

    if (ends) try tokens.push(source, newline_of(offset, 0));
}

fn word_of(text: []const u8) ?Token.Kind {
    assert(text.len > 0);

    return words.get(text);
}

fn token_of(source: []const u8, offset: u32) Token {
    assert(offset < source.len);

    const byte = source[offset];
    const next = scan.byte_at(source, offset + 1) orelse 0;

    const scanned: Scanned = switch (byte) {
        '/' => switch (next) {
            '/' => comment_scanned(primitives.line_scan_trimmed(source, offset)),
            '*' => comment_scanned(comment_block_scan(source, offset)),
            else => operator_scanned(source, offset),
        },
        '{' => .{ .kind = .block_start, .end = offset + 1, .code = .brace_open },
        '}' => .{ .kind = .block_end, .end = offset + 1, .code = .brace_close },
        '"' => string_scanned(primitives.string_scan(source, offset, byte), .string_literal),
        '\'' => string_scanned(primitives.string_scan(source, offset, byte), .rune_literal),
        '`' => string_scanned(string_raw_scan(source, offset), .string_literal),
        '0'...'9' => number_scanned(source, offset),
        '.' => if (std.ascii.isDigit(next))
            number_scanned(source, offset)
        else
            operator_scanned(source, offset),
        else => word_or_operator_scanned(source, offset),
    };

    assert(scanned.end > offset);
    assert(scanned.end <= source.len);
    assert(scanned.code.is_token());

    return .{
        .offset = offset,
        .length = scanned.end - offset,
        .kind = scanned.kind,
        .code = scanned.code.to_u16(),
    };
}

fn comment_scanned(end: u32) Scanned {
    assert(end < std.math.maxInt(u32));

    return .{ .kind = .comment, .end = end, .code = .comment };
}

fn string_scanned(end: u32, code: Kind) Scanned {
    assert(code == .string_literal or code == .rune_literal);
    assert(end < std.math.maxInt(u32));

    return .{ .kind = .string, .end = end, .code = code };
}

fn number_scanned(source: []const u8, offset: u32) Scanned {
    assert(offset < source.len);

    const scanned = primitives.number_scan_bounded(source, offset, .one_sided);

    assert(scanned > offset);
    assert(scanned <= source.len);

    const end = number_end(source, scanned);

    assert(end >= scanned);
    assert(end <= source.len);

    return .{ .kind = .number, .end = end, .code = .number };
}

fn number_end(source: []const u8, end: u32) u32 {
    assert(end <= source.len);

    if (end >= source.len) return end;
    if (source[end] != '.') return end;

    if (end + 1 >= source.len) {
        assert(end + 1 == source.len);

        return end + 1;
    }

    const after = source[end + 1];
    const continues = std.ascii.isAlphabetic(after) or after == '.' or after == '_';
    if (continues) return end;
    assert(end + 1 < source.len);

    return end + 1;
}

fn operator_scanned(source: []const u8, offset: u32) Scanned {
    assert(offset < source.len);

    if (source[offset] >= 0x80) {
        const width: u32 = if (unicode.decode(source, offset)) |scalar| scalar.width else 1;

        assert(offset + width <= source.len);

        return .{ .kind = .{ .punctuation = .other }, .end = offset + width, .code = .error_token };
    }

    if (offset + 3 <= source.len) {
        if (operators_three.get(source[offset..][0..3])) |code| {
            return .{ .kind = code.token_kind(), .end = offset + 3, .code = code };
        }
    }

    if (offset + 2 <= source.len) {
        if (operators_two.get(source[offset..][0..2])) |code| {
            return .{ .kind = code.token_kind(), .end = offset + 2, .code = code };
        }
    }

    const code = operator_one(source[offset]);
    return .{ .kind = code.token_kind(), .end = offset + 1, .code = code };
}

fn operator_one(byte: u8) Kind {
    assert(!std.ascii.isAlphanumeric(byte));

    const code: Kind = switch (byte) {
        '!' => .bang,
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
        '[' => .bracket_open,
        ']' => .bracket_close,
        '^' => .caret,
        '|' => .bar,
        '~' => .tilde,
        else => .error_token,
    };

    assert(code.is_token());
    assert(code != .brace_open);
    assert(code != .brace_close);

    return code;
}

fn word_or_operator_scanned(source: []const u8, offset: u32) Scanned {
    assert(offset < source.len);

    if (is_identifier_start_at(source, offset)) return word_scanned(source, offset);
    return operator_scanned(source, offset);
}

fn word_scanned(source: []const u8, offset: u32) Scanned {
    assert(is_identifier_start_at(source, offset));

    const end = identifier_scan(source, offset);
    const text = source[offset..end];
    const code = keywords.get(text) orelse .identifier;

    assert(end > offset);

    if (code == .func_keyword) {
        return .{ .kind = .{ .keyword = function_keyword(source, end) }, .end = end, .code = code };
    }

    if (code == .for_keyword) {
        return .{ .kind = .{ .keyword = loop_keyword(source, end) }, .end = end, .code = code };
    }

    if (is_assertion(source, offset, end)) {
        assert(code == .identifier);

        return .{ .kind = .{ .keyword = .assert }, .end = end, .code = code };
    }

    return .{ .kind = word_of(text) orelse .identifier, .end = end, .code = code };
}

fn newline_of(offset: u32, length: u32) Token {
    assert(length <= 1);
    assert(offset < std.math.maxInt(u32));

    return .{ .offset = offset, .length = length, .kind = .newline, .code = Kind.newline.to_u16() };
}

fn comment_block_scan(source: []const u8, start: u32) u32 {
    assert(start + 1 < source.len);
    assert(source[start] == '/');
    assert(source[start + 1] == '*');

    const close = std.mem.findPos(u8, source, start + 2, "*/") orelse {
        assert(source.len <= std.math.maxInt(u32));

        return @intCast(source.len);
    };

    assert(close >= start + 2);
    assert(close + 2 <= source.len);

    return @intCast(close + 2);
}

fn string_raw_scan(source: []const u8, start: u32) u32 {
    assert(start < source.len);
    assert(source[start] == '`');

    const close = std.mem.findScalarPos(u8, source, start + 1, '`') orelse {
        assert(source.len <= std.math.maxInt(u32));

        return @intCast(source.len);
    };

    assert(close > start);
    assert(close < source.len);

    return @intCast(close + 1);
}

fn function_keyword(source: []const u8, end: u32) Token.Keyword {
    assert(end <= source.len);

    const start = space_skip(source, end);
    if (start == source.len) return .lambda;
    if (is_identifier_start_at(source, start)) return .function;
    if (source[start] != '(') return .lambda;

    const close = paren_close(source, start) orelse return .lambda;
    const name = space_skip(source, close + 1);

    assert(close > start);

    if (!is_identifier_start_at(source, name)) return .lambda;

    const stop = identifier_scan(source, name);

    assert(stop > name);

    if (names_a_type(source[name..stop])) return .lambda;
    if (scan.byte_at(source, space_skip(source, stop)) == '(') return .function;
    return .lambda;
}

fn names_a_type(word: []const u8) bool {
    assert(word.len > 0);

    if (std.mem.eql(u8, word, declare_word)) return true;
    return word_of(word) != null;
}

fn paren_close(source: []const u8, open: u32) ?u32 {
    assert(open < source.len);
    assert(source[open] == '(');

    const limit: u32 = @intCast(@min(source.len, @as(usize, open) + receiver_bytes_max));
    var depth: u32 = 0;

    for (source[open..limit], open..) |byte, offset| {
        switch (byte) {
            '(' => depth += 1,
            ')' => {
                assert(depth > 0);

                depth -= 1;

                if (depth == 0) {
                    assert(source[offset] == ')');

                    return @intCast(offset);
                }
            },
            else => {},
        }
    }

    return null;
}

fn loop_keyword(source: []const u8, end: u32) Token.Keyword {
    assert(end <= source.len);

    const start = space_skip(source, end);

    assert(start >= end);

    if (scan.byte_at(source, start) == '{') return .loop_unbounded;
    return .loop;
}

fn space_skip(source: []const u8, start: u32) u32 {
    assert(start <= source.len);

    var offset = start;

    while (offset < source.len) {
        const byte = source[offset];

        if (scan.is_ascii_whitespace(byte)) {
            offset += 1;

            continue;
        }

        if (byte != '/') break;

        const skipped = switch (scan.byte_at(source, offset + 1) orelse 0) {
            '/' => scan.line_end(source, offset),
            '*' => comment_block_scan(source, offset),
            else => break,
        };

        assert(skipped > offset);

        offset = skipped;
    }

    assert(offset >= start);
    assert(offset <= source.len);

    return offset;
}

fn is_assertion(source: []const u8, start: u32, end: u32) bool {
    assert(start < end);
    assert(end <= source.len);

    if (!is_assert_name(source, start, end)) return false;
    if (declares_a_name(source, start)) return false;
    return !binds_a_name(source, end);
}

fn is_assert_name(source: []const u8, start: u32, end: u32) bool {
    assert(start < end);
    assert(end <= source.len);

    const text = source[start..end];
    if (std.mem.eql(u8, text, "assert")) return true;
    if (!std.mem.eql(u8, text, "require")) return false;
    if (scan.byte_at(source, end) != '.') return false;

    const method = end + 1;
    if (!is_identifier_start_at(source, method)) return false;
    return scan.word_in(&assert_methods, source[method..identifier_scan(source, method)]);
}

fn declares_a_name(source: []const u8, start: u32) bool {
    assert(start < source.len);

    const cursor = space_skip_back(source, start);

    assert(cursor <= start);

    if (follows_word(source, cursor, declare_word)) return true;
    if (cursor == 0) return false;
    if (source[cursor - 1] != ')') return false;

    const open = paren_open(source, cursor - 1) orelse return false;
    return follows_word(source, space_skip_back(source, open), declare_word);
}

fn follows_word(source: []const u8, cursor: u32, word: []const u8) bool {
    assert(cursor <= source.len);
    assert(word.len > 0);

    if (cursor < word.len) return false;

    const start: u32 = @intCast(cursor - word.len);
    if (!std.mem.eql(u8, source[start..cursor], word)) return false;
    if (start == 0) return true;
    return !scan.is_identifier_part(source[start - 1]);
}

fn paren_open(source: []const u8, close: u32) ?u32 {
    assert(close < source.len);
    assert(source[close] == ')');

    const floor = close -| receiver_bytes_max;
    var depth: u32 = 0;
    var offset = close + 1;

    while (offset > floor) {
        offset -= 1;

        switch (source[offset]) {
            ')' => depth += 1,
            '(' => {
                assert(depth > 0);

                depth -= 1;

                if (depth == 0) {
                    assert(source[offset] == '(');

                    return offset;
                }
            },
            else => {},
        }
    }

    return null;
}

fn space_skip_back(source: []const u8, start: u32) u32 {
    assert(start <= source.len);

    var cursor = start;

    while (cursor > 0) {
        if (source[cursor - 1] != ' ') break;

        cursor -= 1;
    }

    assert(cursor <= start);

    return cursor;
}

fn binds_a_name(source: []const u8, end: u32) bool {
    assert(end <= source.len);

    const cursor = space_skip_forward(source, end);

    assert(cursor >= end);

    if (scan.byte_at(source, cursor) != ':') return false;
    return scan.byte_at(source, cursor + 1) == '=';
}

fn space_skip_forward(source: []const u8, start: u32) u32 {
    assert(start <= source.len);

    var cursor = start;

    while (cursor < source.len) {
        if (source[cursor] != ' ') break;

        cursor += 1;
    }

    assert(cursor >= start);

    return cursor;
}

fn identifier_scan(source: []const u8, start: u32) u32 {
    assert(is_identifier_start_at(source, start));

    const part = scan.is_identifier_part;
    return primitives.identifier_scan_with(source, start, part, unicode.is_alphanumeric);
}

fn is_identifier_start_at(source: []const u8, offset: u32) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(offset < std.math.maxInt(u32));

    const first = primitives.is_identifier_start;
    return primitives.is_identifier_start_with(source, offset, first, unicode.is_alphabetic);
}

fn ends_statement(kind: Token.Kind, text: []const u8) bool {
    assert(text.len > 0);
    if (kind == .keyword) assert(std.ascii.isLower(text[0]));

    return switch (kind) {
        .block_end, .identifier, .number, .string => true,
        .keyword => |keyword| switch (keyword) {
            .assert, .@"break", .@"continue", .@"return" => true,
            else => std.mem.eql(u8, text, "fallthrough"),
        },
        .punctuation => scan.word_in(&statement_ends, text),
        .block_start, .comment, .newline => false,
    };
}

fn comment_spans_lines(source: []const u8, token: Token) bool {
    assert(token.kind == .comment);
    assert(token.end() <= source.len);

    return std.mem.findScalar(u8, token.text(source), '\n') != null;
}

const Case = struct {
    word: []const u8,
    source: []const u8,
    kind: Token.Kind,
};

const keyword_cases = [_]Case{
    .{
        .word = "break",
        .source = "func f() {\n\tfor {\n\t\tbreak\n\t}\n}\n",
        .kind = .{ .keyword = .@"break" },
    },
    .{
        .word = "case",
        .source = "func f(v int) {\n\tswitch v {\n\tcase 1:\n\t}\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "chan",
        .source = "func f(c chan int) {\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "const",
        .source = "const limit = 4\n",
        .kind = .{ .keyword = .constant },
    },
    .{
        .word = "continue",
        .source = "func f() {\n\tfor i := 0; i < 4; i++ {\n\t\tcontinue\n\t}\n}\n",
        .kind = .{ .keyword = .@"continue" },
    },
    .{
        .word = "default",
        .source = "func f(v int) {\n\tswitch v {\n\tdefault:\n\t}\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "defer",
        .source = "func f(c chan int) {\n\tdefer close(c)\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "else",
        .source = "func f(v int) {\n\tif v > 0 {\n\t} else {\n\t}\n}\n",
        .kind = .{ .keyword = .branch_else },
    },
    .{
        .word = "fallthrough",
        .source = "func f(v int) {\n\tswitch v {\n\tcase 1:\n\t\tfallthrough\n\t}\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "for",
        .source = "func f() {\n\tfor i := 0; i < 4; i++ {\n\t}\n}\n",
        .kind = .{ .keyword = .loop },
    },
    .{
        .word = "func",
        .source = "func f() {\n}\n",
        .kind = .{ .keyword = .function },
    },
    .{
        .word = "go",
        .source = "func f(c chan int) {\n\tgo close(c)\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "goto",
        .source = "func f() {\n\tgoto done\ndone:\n}\n",
        .kind = .{ .keyword = .goto },
    },
    .{
        .word = "if",
        .source = "func f(v int) {\n\tif v > 0 {\n\t}\n}\n",
        .kind = .{ .keyword = .branch },
    },
    .{
        .word = "import",
        .source = "import \"fmt\"\n",
        .kind = .{ .keyword = .import },
    },
    .{
        .word = "interface",
        .source = "type Reader interface {\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "map",
        .source = "func f(m map[string]int) {\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "package",
        .source = "package fixture\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "range",
        .source = "func f(v []int) {\n\tfor _, x := range v {\n\t}\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "return",
        .source = "func f() int {\n\treturn 0\n}\n",
        .kind = .{ .keyword = .@"return" },
    },
    .{
        .word = "select",
        .source = "func f() {\n\tselect {\n\t}\n}\n",
        .kind = .{ .keyword = .match },
    },
    .{
        .word = "struct",
        .source = "type Point struct {\n}\n",
        .kind = .{ .keyword = .@"struct" },
    },
    .{
        .word = "switch",
        .source = "func f(v int) {\n\tswitch v {\n\t}\n}\n",
        .kind = .{ .keyword = .match },
    },
    .{
        .word = "type",
        .source = "type Count int\n",
        .kind = .{ .keyword = .@"struct" },
    },
    .{
        .word = "var",
        .source = "var count = 0\n",
        .kind = .{ .keyword = .mutable },
    },
};

const punctuation_cases = [_]Case{
    .{
        .word = "!",
        .source = "func f(v bool) bool {\n\treturn !v\n}\n",
        .kind = .{ .punctuation = .bang },
    },
    .{
        .word = "!=",
        .source = "func f(a int, b int) bool {\n\treturn a != b\n}\n",
        .kind = .{ .punctuation = .not_equal },
    },
    .{
        .word = "&",
        .source = "func f(a int, b int) int {\n\treturn a & b\n}\n",
        .kind = .{ .punctuation = .ampersand },
    },
    .{
        .word = "&&",
        .source = "func f(a bool, b bool) bool {\n\treturn a && b\n}\n",
        .kind = .{ .punctuation = .ampersand_double },
    },
    .{
        .word = "(",
        .source = "func f() {\n}\n",
        .kind = .{ .punctuation = .paren_open },
    },
    .{
        .word = ")",
        .source = "func f() {\n}\n",
        .kind = .{ .punctuation = .paren_close },
    },
    .{
        .word = "*",
        .source = "func f(a int, b int) int {\n\treturn a * b\n}\n",
        .kind = .{ .punctuation = .star },
    },
    .{
        .word = "+",
        .source = "func f(a int, b int) int {\n\treturn a + b\n}\n",
        .kind = .{ .punctuation = .other },
    },
    .{
        .word = "++",
        .source = "func f() {\n\tfor i := 0; i < 4; i++ {\n\t}\n}\n",
        .kind = .{ .punctuation = .other },
    },
    .{
        .word = ",",
        .source = "func f(a int, b int) {\n}\n",
        .kind = .{ .punctuation = .comma },
    },
    .{
        .word = "-",
        .source = "func f(a int, b int) int {\n\treturn a - b\n}\n",
        .kind = .{ .punctuation = .other },
    },
    .{
        .word = "--",
        .source = "func f() {\n\tfor i := 4; i > 0; i-- {\n\t}\n}\n",
        .kind = .{ .punctuation = .other },
    },
    .{
        .word = ".",
        .source = "func f() {\n\tfmt.Println()\n}\n",
        .kind = .{ .punctuation = .dot },
    },
    .{
        .word = "/",
        .source = "func f(a int, b int) int {\n\treturn a / b\n}\n",
        .kind = .{ .punctuation = .slash },
    },
    .{
        .word = ":",
        .source = "func f(v int) {\n\tswitch v {\n\tcase 1:\n\t}\n}\n",
        .kind = .{ .punctuation = .colon },
    },
    .{
        .word = ":=",
        .source = "func f() {\n\tcount := 0\n}\n",
        .kind = .{ .punctuation = .assign_declare },
    },
    .{
        .word = ";",
        .source = "func f() {\n\tfor i := 0; i < 4; i++ {\n\t}\n}\n",
        .kind = .{ .punctuation = .semicolon },
    },
    .{
        .word = "<",
        .source = "func f(a int, b int) bool {\n\treturn a < b\n}\n",
        .kind = .{ .punctuation = .less },
    },
    .{
        .word = "<=",
        .source = "func f(a int, b int) bool {\n\treturn a <= b\n}\n",
        .kind = .{ .punctuation = .less_equal },
    },
    .{
        .word = "=",
        .source = "func f() {\n\tvar count int\n\tcount = 1\n}\n",
        .kind = .{ .punctuation = .assign },
    },
    .{
        .word = "==",
        .source = "func f(a int, b int) bool {\n\treturn a == b\n}\n",
        .kind = .{ .punctuation = .equal },
    },
    .{
        .word = ">",
        .source = "func f(a int, b int) bool {\n\treturn a > b\n}\n",
        .kind = .{ .punctuation = .greater },
    },
    .{
        .word = ">=",
        .source = "func f(a int, b int) bool {\n\treturn a >= b\n}\n",
        .kind = .{ .punctuation = .greater_equal },
    },
    .{
        .word = "[",
        .source = "func f(v []int) {\n}\n",
        .kind = .{ .punctuation = .bracket_open },
    },
    .{
        .word = "]",
        .source = "func f(v []int) {\n}\n",
        .kind = .{ .punctuation = .bracket_close },
    },
    .{
        .word = "^",
        .source = "func f(a int, b int) int {\n\treturn a ^ b\n}\n",
        .kind = .{ .punctuation = .other },
    },
    .{
        .word = "{",
        .source = "func f() {\n}\n",
        .kind = .block_start,
    },
    .{
        .word = "|",
        .source = "func f(a int, b int) int {\n\treturn a | b\n}\n",
        .kind = .{ .punctuation = .other },
    },
    .{
        .word = "||",
        .source = "func f(a bool, b bool) bool {\n\treturn a || b\n}\n",
        .kind = .{ .punctuation = .bar_double },
    },
    .{
        .word = "}",
        .source = "func f() {\n}\n",
        .kind = .block_end,
    },
};

fn expect_lexes_to(source: []const u8, expected: []const []const u8) !void {
    assert(source.len <= std.math.maxInt(u32));
    assert(expected.len <= std.math.maxInt(u32));

    var lexed: Lexed = try .init(.go, source);
    defer lexed.deinit();

    var matched: u32 = 0;

    for (lexed.tokens.slice()) |token| {
        if (token.kind == .newline) continue;

        try std.testing.expect(matched < expected.len);
        try std.testing.expectEqualStrings(expected[matched], token.text(source));

        matched += 1;
    }

    try std.testing.expectEqual(expected.len, matched);
}

fn index_of(lexed: *const Lexed, word: []const u8) ?u32 {
    assert(word.len > 0);

    for (lexed.tokens.slice(), 0..) |token, index| {
        if (std.mem.eql(u8, token.text(lexed.source), word)) {
            assert(index < lexed.tokens.slice().len);

            return @intCast(index);
        }
    }

    return null;
}

fn index_last_of(lexed: *const Lexed, word: []const u8) ?u32 {
    assert(word.len > 0);

    var found: ?u32 = null;

    for (lexed.tokens.slice(), 0..) |token, index| {
        if (std.mem.eql(u8, token.text(lexed.source), word)) found = @intCast(index);
    }

    return found;
}

fn newlines(source: []const u8) !u32 {
    assert(source.len <= std.math.maxInt(u32));

    var lexed: Lexed = try .init(.go, source);
    defer lexed.deinit();

    return lexed.count_of(.newline);
}

fn string_first(lexed: *const Lexed) ?Token {
    for (lexed.tokens.slice()) |token| {
        if (token.kind == .string) return token;
    }

    return null;
}

test "a rune literal ends where go scanner ends it" {
    const source = "func f() {\n\tr := 'a'\n\tq := '\\''\n\tw := '\\U0001F600'\n}\n";

    try expect_texts(.go, source, .string, &.{ "'a'", "'\\''", "'\\U0001F600'" });
}

test "a stray apostrophe closes at the next one and stops at the line" {
    try expect_texts(.go, "func f() {\n\ts := 'don't\n}\n", .string, &.{"'don'"});
    try expect_texts(.go, "func f() {\n\ts := 'a\n}\n", .string, &.{"'a"});
    try expect_texts(.go, "func f() {\n\ts := 'a", .string, &.{"'a"});
}

test "a double less wins over the receive arrow" {
    try expect_lexes_to("1<<-1", &.{ "1", "<<", "-", "1" });
    try expect_lexes_to("a <- b", &.{ "a", "<-", "b" });
    try expect_lexes_to("x <<= 1", &.{ "x", "<<=", "1" });
    try expect_lexes_to("a<<b", &.{ "a", "<<", "b" });
}

test "an identifier starts with a letter or an underscore" {
    try expect_lexes_to("\u{3b1}\u{3b2}", &.{"\u{3b1}\u{3b2}"});
    try expect_lexes_to("_x", &.{"_x"});
    try expect_lexes_to("x1", &.{"x1"});
    try expect_lexes_to("\u{65e5}\u{672c}\u{8a9e}", &.{"\u{65e5}\u{672c}\u{8a9e}"});
    try expect_lexes_to("\u{2639}x", &.{ "\u{2639}", "x" });

    var lexed: Lexed = try .init(.go, "\u{2639}x");
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .{ .punctuation = .other });
    try std.testing.expectEqual(3, lexed.token(0).length);
    try lexed.expect_kind_at(1, .identifier);
}

test "a short declaration binds only where both bytes stand" {
    try std.testing.expect(binds_a_name("assert := f", 6));
    try std.testing.expect(binds_a_name("assert:= f", 6));
    try std.testing.expect(!binds_a_name("assert = f", 6));
    try std.testing.expect(!binds_a_name("assert : f", 6));
    try std.testing.expect(!binds_a_name("assert", 6));
    try std.testing.expect(!binds_a_name("assert :", 6));
}

test "a blank run forward stops at the first byte that is not a space" {
    try std.testing.expectEqual(3, space_skip_forward("   x", 0));
    try std.testing.expectEqual(0, space_skip_forward("x  ", 0));
    try std.testing.expectEqual(3, space_skip_forward("   ", 0));
    try std.testing.expectEqual(0, space_skip_forward("", 0));
    try std.testing.expectEqual(1, space_skip_forward(" \t ", 0));
    try std.testing.expectEqual(3, space_skip_forward("a  b", 1));
}

test "a receiver list opens where its own parenthesis does" {
    try std.testing.expectEqual(0, paren_open("(a)", 2));
    try std.testing.expectEqual(0, paren_open("(a (b))", 6));
    try std.testing.expectEqual(2, paren_open("x (a)", 4));
    try std.testing.expectEqual(null, paren_open(")", 0));
}

test "every keyword of the specification lexes to its kind" {
    try std.testing.expectEqual(25, keyword_cases.len);

    for (keyword_cases) |case| {
        try expect_kind(.go, case.source, case.word, case.kind);
    }
}

test "the channel arrow lexes as one token" {
    const source = "func f(c chan int) {\n\tc <- 1\n}\n";

    try expect_kind(.go, source, "<-", .{ .punctuation = .less });
}

test "a channel arrow before a minus does not take a newline" {
    var lexed: Lexed = try .init(.go, "package i\nfunc f() {\n\tc <--x\n}\n");
    defer lexed.deinit();

    const arrow = index_of(&lexed, "<-").?;

    try std.testing.expectEqualStrings("-", lexed.text_at(arrow + 1));
    try std.testing.expectEqualStrings("x", lexed.text_at(arrow + 2));
    try lexed.expect_kind_at(arrow + 3, .newline);
}

test "a statement ending word takes a newline" {
    inline for (.{ "break", "continue", "return", "fallthrough" }) |word| {
        var lexed: Lexed = try .init(.go, "func f() {\n\t" ++ word ++ "\n}\n");
        defer lexed.deinit();

        const index = index_of(&lexed, word).?;

        try lexed.expect_kind_at(index + 1, .newline);
    }
}

test "a statement ending punctuation takes a newline" {
    inline for (.{ ")", "]", "++", "--" }) |tail| {
        var lexed: Lexed = try .init(.go, "func f() {\n\tvalues" ++ tail ++ "\n}\n");
        defer lexed.deinit();

        const index = index_last_of(&lexed, tail).?;

        try lexed.expect_kind_at(index + 1, .newline);
    }
}

test "an opening word takes no newline" {
    var lexed: Lexed = try .init(.go, "func f() {\n\tvar\n\tvalue = 1\n}\n");
    defer lexed.deinit();

    const index = index_of(&lexed, "var").?;

    try std.testing.expect(lexed.token(index + 1).kind != .newline);
}

test "a function literal returning a function is not a declaration" {
    const source = "var build = func() func(int) int {\n\treturn nil\n}\n";
    var lexed: Lexed = try .init(.go, source);
    defer lexed.deinit();

    var lambdas: u32 = 0;

    for (lexed.tokens.slice()) |token| {
        if (!std.mem.eql(u8, token.text(source), "func")) continue;

        try std.testing.expectEqual(Token.Kind{ .keyword = .lambda }, token.kind);

        lambdas += 1;
    }

    try std.testing.expectEqual(2, lambdas);
}

test "a general comment that spans lines acts as a newline" {
    const spanning = "func f() {\n\ta := 1 /* note\n\t*/ b := a\n}\n";
    const enclosed = "func f() {\n\ta := 1 /* note */ b := a\n}\n";

    try std.testing.expectEqual(try newlines(enclosed) + 1, try newlines(spanning));
}

test "a last statement without a trailing newline still ends" {
    try std.testing.expectEqual(2, try newlines("func f() {\n\ta := 1\n}"));
    try std.testing.expectEqual(2, try newlines("func f() {\n\ta := 1\n}\n"));
}

test "a colon ends a statement though the specification does not" {
    const source = "func f(v int) int {\n\tswitch v {\n\tcase 1:\n\t\treturn 2\n\t}\n" ++
        "\treturn 0\n}\n";

    var lexed: Lexed = try .init(.go, source);
    defer lexed.deinit();

    const index = index_of(&lexed, ":").?;

    try lexed.expect_kind_at(index + 1, .newline);
}

test "a method named assert keeps its name" {
    var lexed: Lexed = try .init(.go, "func (t *T) assert(ok bool) {\n}\n");
    defer lexed.deinit();

    try std.testing.expectEqual(Token.Kind.identifier, lexed.find("assert").?.kind);
    try lexed.expect_kind_at(0, .{ .keyword = .function });
}

test "a bound assert name keeps its name" {
    const source = "func f() {\n\tassert := func(ok bool) {}\n\tassert(true)\n}\n";
    var lexed: Lexed = try .init(.go, source);
    defer lexed.deinit();

    try std.testing.expectEqual(1, lexed.count_of(.{ .keyword = .assert }));
}

test "a nested receiver group closes at its outer paren" {
    const source = "func (s *Store[map[string]int]) Read() int {\n\treturn 0\n}\n";
    var lexed: Lexed = try .init(.go, source);
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .{ .keyword = .function });
}

test "an unclosed receiver group is a lambda" {
    var lexed: Lexed = try .init(.go, "func (s *Store\n");
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .{ .keyword = .lambda });
}

test "a receiver group past the byte limit is a lambda" {
    const padding: [300]u8 = @splat(' ');
    const source = "func (s *Store" ++ padding ++ ") Read() int {\n\treturn 0\n}\n";
    var lexed: Lexed = try .init(.go, source);
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .{ .keyword = .lambda });
}

test "a method receiver names a function" {
    try expect_kind(.go, "func", "func", .{ .keyword = .lambda });

    var lexed: Lexed = try .init(.go, "func (s *Store) Read() int {\n\treturn 0\n}\n");
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .{ .keyword = .function });
}

test "a function literal is a lambda" {
    const source = "var f = func() int {\n\treturn 0\n}\n";

    try expect_kind(.go, source, "func", .{ .keyword = .lambda });
}

test "a bare for is an unbounded loop" {
    const bounded = "func f() {\n\tfor i := 0; i < 2; i++ {\n\t}\n}\n";
    const unbounded = "func f() {\n\tfor {\n\t}\n}\n";

    try expect_kind(.go, bounded, "for", .{ .keyword = .loop });
    try expect_kind(.go, unbounded, "for", .{ .keyword = .loop_unbounded });
}

test "a declared assert name is not an assertion" {
    var lexed: Lexed = try .init(.go, "func assert(value int) {\n}\n");
    defer lexed.deinit();

    try std.testing.expectEqual(0, lexed.count_of(.{ .keyword = .assert }));
}

test "a require method is an assertion" {
    var lexed: Lexed = try .init(.go, "func f() {\n\trequire.Equal(t, 1, 2)\n}\n");
    defer lexed.deinit();

    try std.testing.expectEqual(1, lexed.count_of(.{ .keyword = .assert }));
}

test "a require without a method is not an assertion" {
    var lexed: Lexed = try .init(.go, "func f() {\n\trequire(1)\n}\n");
    defer lexed.deinit();

    try std.testing.expectEqual(0, lexed.count_of(.{ .keyword = .assert }));
}

test "a comment between func and its name still names a function" {
    var lexed: Lexed = try .init(.go, "func /* here */ read() int {\n\treturn 0\n}\n");
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .{ .keyword = .function });
}

test "a line comment between func and its name still names a function" {
    var lexed: Lexed = try .init(.go, "func // here\nread() int {\n\treturn 0\n}\n");
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .{ .keyword = .function });
}

test "a comment before a loop brace still names an unbounded loop" {
    const source = "func f() {\n\tfor /* here */ {\n\t}\n}\n";

    try expect_kind(.go, source, "for", .{ .keyword = .loop_unbounded });
}

test "a raw string runs to its backtick" {
    var lexed: Lexed = try .init(.go, "var text = `a \"quoted\" value`\n");
    defer lexed.deinit();

    const raw = string_first(&lexed).?;

    try std.testing.expectEqualStrings("`a \"quoted\" value`", raw.text(lexed.source));
}

test "an unclosed raw string runs to the source end" {
    var lexed: Lexed = try .init(.go, "var text = `unterminated");
    defer lexed.deinit();

    try std.testing.expectEqual(13, string_first(&lexed).?.length);
}

test "a raw string closing at the source end closes" {
    var lexed: Lexed = try .init(.go, "var text = `done`");
    defer lexed.deinit();

    try std.testing.expectEqualStrings("`done`", string_first(&lexed).?.text(lexed.source));
}

test "a block comment ending in a star runs to the source end" {
    var lexed: Lexed = try .init(.go, "/* ending in a star *");
    defer lexed.deinit();

    try std.testing.expectEqual(1, lexed.tokens.count());
    try lexed.expect_kind_at(0, .comment);
    try std.testing.expectEqual(21, lexed.token(0).length);
}

test "a receiver method without a signature is a lambda" {
    var lexed: Lexed = try .init(.go, "func (s *Store) Read");
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .{ .keyword = .lambda });
}

test "a receiver without a method name is a lambda" {
    var lexed: Lexed = try .init(.go, "func (s *Store) ");
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .{ .keyword = .lambda });
}

test "a for at the source end is a bounded loop" {
    try expect_kind(.go, "func f() {\n\tfor", "for", .{ .keyword = .loop });
}

test "an assert at the source start is an assertion" {
    var lexed: Lexed = try .init(.go, "assert(value)");
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .{ .keyword = .assert });
}

test "a require dot at the source end is not an assertion" {
    var lexed: Lexed = try .init(.go, "func f() {\n\trequire.");
    defer lexed.deinit();

    try std.testing.expectEqual(0, lexed.count_of(.{ .keyword = .assert }));
}

test "a lone slash before a name does not open a comment" {
    var lexed: Lexed = try .init(.go, "func f() {\n\tvalue := a / b\n}\n");
    defer lexed.deinit();

    try std.testing.expectEqual(0, lexed.count_of(.comment));
}

test "a block comment closes at its first end" {
    var lexed: Lexed = try .init(.go, "/* outer /* inner */ func f() {}\n");
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .comment);
    try std.testing.expectEqual(20, lexed.token(0).length);
    try std.testing.expectEqualStrings("func", lexed.text_at(1));
}

test "an unclosed block comment runs to the source end" {
    var lexed: Lexed = try .init(.go, "/* outer");
    defer lexed.deinit();

    try std.testing.expectEqual(1, lexed.tokens.count());
    try lexed.expect_kind_at(0, .comment);
    try std.testing.expectEqual(8, lexed.token(0).length);
}

test "a block comment ending at the source end closes" {
    var lexed: Lexed = try .init(.go, "/* outer */");
    defer lexed.deinit();

    try std.testing.expectEqual(1, lexed.tokens.count());
    try lexed.expect_kind_at(0, .comment);
    try std.testing.expectEqual(11, lexed.token(0).length);
}

test "every punctuation of the specification lexes to its kind" {
    for (punctuation_cases) |case| {
        try expect_kind(.go, case.source, case.word, case.kind);
    }
}

test "a function lexes to its parts" {
    var lexed: Lexed = try .init(.go, "func main() {\n\tcount := 0\n}\n");
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .{ .keyword = .function });
    try std.testing.expectEqualStrings("main", lexed.text_at(1));
    try lexed.expect_kind_at(4, .block_start);
    try std.testing.expectEqualStrings("count", lexed.text_at(5));
    try lexed.expect_kind_at(6, .{ .punctuation = .assign_declare });
    try lexed.expect_kind_at(8, .newline);
}

test "a method declares a function" {
    const source = "func (r *Reader) Read(buffer []byte) int {\n}\n";
    var lexed: Lexed = try .init(.go, source);
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .{ .keyword = .function });
}

test "a func literal is a lambda" {
    const source = "var double = func(value int) int {\n\treturn value\n}\n";
    var lexed: Lexed = try .init(.go, source);
    defer lexed.deinit();

    try lexed.expect_kind_at(3, .{ .keyword = .lambda });
}

test "a bare for is unbounded" {
    const source = "func main() {\n\tfor {\n\t}\n\tfor i := 0; i < 4; i++ {\n\t}\n}\n";
    var lexed: Lexed = try .init(.go, source);
    defer lexed.deinit();

    try std.testing.expectEqual(1, lexed.count_of(.{ .keyword = .loop_unbounded }));
    try std.testing.expectEqual(1, lexed.count_of(.{ .keyword = .loop }));
}

test "a raw string spans its lines" {
    var lexed: Lexed = try .init(.go, "var text = `one\ntwo`\n");
    defer lexed.deinit();

    try lexed.expect_kind_at(3, .string);
    try std.testing.expectEqualStrings("`one\ntwo`", lexed.text_at(3));
}

test "a rune is a string" {
    var lexed: Lexed = try .init(.go, "var byte = 'a'\n");
    defer lexed.deinit();

    try lexed.expect_kind_at(3, .string);
    try std.testing.expectEqualStrings("'a'", lexed.text_at(3));
}

test "a line ending in an operator carries on" {
    try std.testing.expectEqual(1, try newlines("var total = one +\n\ttwo\n"));
}

test "a trailing comment does not hide the line break" {
    try std.testing.expectEqual(2, try newlines("count := 0 // A note.\ntotal := 1\n"));
}

test "a star behind a name does not open a comment" {
    const source = "package main\n\nfunc a*b() {}\n";
    var lexed: Lexed = try .init(.go, source);
    defer lexed.deinit();

    try std.testing.expect(lexed.tokens.count() > 0);
    try expect_kind(.go, source, "func", .{ .keyword = .function });
}

test "a comment between func and its name is skipped" {
    const enclosed = "package main\n\nfunc /* note */ run() {}\n";
    const trailing = "package main\n\nfunc // note\nrun() {}\n";

    try expect_kind(.go, enclosed, "func", .{ .keyword = .function });
    try expect_kind(.go, trailing, "func", .{ .keyword = .function });
}

test "a block comment closes once" {
    var lexed: Lexed = try .init(.go, "/* A note. */ func main() {}");
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .comment);
    try std.testing.expectEqualStrings("/* A note. */", lexed.text_at(0));
    try lexed.expect_kind_at(1, .{ .keyword = .function });
}

test "a type declaration names its struct" {
    var lexed: Lexed = try .init(.go, "type Point struct {\n\tX int\n}\n");
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .{ .keyword = .@"struct" });
    try std.testing.expectEqualStrings("Point", lexed.text_at(1));
    try lexed.expect_kind_at(2, .{ .keyword = .@"struct" });
}

test "an assertion package is an assertion" {
    const source = "func f(t *T) {\n\trequire.NoError(t, err)\n\tassert.True(t, ok)\n}\n";
    var lexed: Lexed = try .init(.go, source);
    defer lexed.deinit();

    try std.testing.expectEqual(2, lexed.count_of(.{ .keyword = .assert }));
}

test "an ordinary package is an identifier" {
    var lexed: Lexed = try .init(.go, "func f() {\n\tfmt.Println(value)\n}\n");
    defer lexed.deinit();

    try std.testing.expectEqual(0, lexed.count_of(.{ .keyword = .assert }));
}

test "a declared assert is not a keyword" {
    var lexed: Lexed = try .init(.go, "func assert(condition bool) {\n}\n");
    defer lexed.deinit();

    try std.testing.expectEqual(0, lexed.count_of(.{ .keyword = .assert }));
    try lexed.expect_kind_at(1, .identifier);
}

test "a digit of another script continues a name but cannot open one" {
    try expect_lexes_to("x\u{0663}", &.{"x\u{0663}"});
    try expect_lexes_to("\u{0663}x", &.{ "\u{0663}", "x" });
    try expect_lexes_to("a\xffb", &.{ "a", "\xff", "b" });
    try expect_lexes_to("\xe2\x98", &.{ "\xe2", "\x98" });
}

const exact_keyword_cases = [_]struct { []const u8, Kind }{
    .{ "break", .break_keyword },
    .{ "case", .case_keyword },
    .{ "chan", .chan_keyword },
    .{ "const", .const_keyword },
    .{ "continue", .continue_keyword },
    .{ "default", .default_keyword },
    .{ "defer", .defer_keyword },
    .{ "else", .else_keyword },
    .{ "fallthrough", .fallthrough_keyword },
    .{ "for", .for_keyword },
    .{ "func", .func_keyword },
    .{ "go", .go_keyword },
    .{ "goto", .goto_keyword },
    .{ "if", .if_keyword },
    .{ "import", .import_keyword },
    .{ "interface", .interface_keyword },
    .{ "map", .map_keyword },
    .{ "package", .package_keyword },
    .{ "range", .range_keyword },
    .{ "return", .return_keyword },
    .{ "select", .select_keyword },
    .{ "struct", .struct_keyword },
    .{ "switch", .switch_keyword },
    .{ "type", .type_keyword },
    .{ "var", .var_keyword },
};

const exact_operator_cases = [_]struct { []const u8, Kind }{
    .{ "&^=", .ampersand_caret_equal },
    .{ "<<=", .less_less_equal },
    .{ ">>=", .greater_greater_equal },
    .{ "...", .dot_dot_dot },
    .{ "!=", .bang_equal },
    .{ "%=", .percent_equal },
    .{ "&&", .ampersand_ampersand },
    .{ "&=", .ampersand_equal },
    .{ "&^", .ampersand_caret },
    .{ "*=", .star_equal },
    .{ "++", .plus_plus },
    .{ "+=", .plus_equal },
    .{ "--", .minus_minus },
    .{ "-=", .minus_equal },
    .{ "/=", .slash_equal },
    .{ ":=", .colon_equal },
    .{ "<-", .arrow },
    .{ "<<", .less_less },
    .{ "<=", .less_equal },
    .{ "==", .equal_equal },
    .{ ">=", .greater_equal },
    .{ ">>", .greater_greater },
    .{ "^=", .caret_equal },
    .{ "|=", .bar_equal },
    .{ "||", .bar_bar },
    .{ "!", .bang },
    .{ "%", .percent },
    .{ "&", .ampersand },
    .{ "(", .paren_open },
    .{ ")", .paren_close },
    .{ "*", .star },
    .{ "+", .plus },
    .{ ",", .comma },
    .{ "-", .minus },
    .{ ".", .dot },
    .{ "/", .slash },
    .{ ":", .colon },
    .{ ";", .semicolon },
    .{ "<", .less },
    .{ "=", .equal },
    .{ ">", .greater },
    .{ "[", .bracket_open },
    .{ "]", .bracket_close },
    .{ "^", .caret },
    .{ "|", .bar },
    .{ "~", .tilde },
};

test "every keyword lexes to its exact kind" {
    for (exact_keyword_cases) |entry| {
        const scanned = word_scanned(entry[0], 0);

        try std.testing.expectEqual(entry[1], scanned.code);
        try std.testing.expectEqual(entry[0].len, scanned.end);
    }
}

test "every operator lexes to its exact kind" {
    for (exact_operator_cases) |entry| {
        const scanned = operator_scanned(entry[0], 0);

        try std.testing.expectEqual(entry[1], scanned.code);
        try std.testing.expectEqual(entry[0].len, scanned.end);
        try std.testing.expect(scanned.kind.eql(entry[1].token_kind()));
    }
}

test "an exact kind never names more bytes than its token holds" {
    const sources = [_][]const u8{
        "package i\nfunc f() {\n\tm<<-l\n}\n",
        "package i\nfunc f() {\n\tm<<--l\n}\n",
        "package i\nfunc f() {\n\tm<--l\n}\n",
        "package i\nfunc f() {\n\tm&^^=l\n}\n",
    };

    for (sources) |source| {
        var lexed: Lexed = try .init(.go, source);
        defer lexed.deinit();

        for (lexed.tokens.slice()) |token| {
            const code = token.exact_kind(Kind).?;

            for (exact_operator_cases) |entry| {
                if (entry[1] != code) continue;

                try std.testing.expectEqualStrings(entry[0], token.text(source));
            }
        }
    }
}

test "a trailing dot joins its number" {
    try expect_texts(.go, "x := 1.\n", .number, &.{"1."});
    try expect_texts(.go, "x := 1.0\n", .number, &.{"1.0"});
    try expect_texts(.go, "x := 1.)\n", .number, &.{"1."});
}

test "a stray scalar is one punctuation other with no identifier code" {
    var lexed: Lexed = try .init(.go, "x \u{2192} y\n");
    defer lexed.deinit();

    const token = lexed.at_offset(2).?;

    try std.testing.expectEqual(Token.Kind{ .punctuation = .other }, token.kind);
    try std.testing.expectEqual(3, token.length);
    try std.testing.expectEqual(Kind.error_token, token.exact_kind(Kind).?);
}
