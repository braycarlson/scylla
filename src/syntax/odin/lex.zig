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

const Scanned = struct {
    kind: Kind,
    end: u32,
};

const statement_end_operators = [_][]const u8{ ")", "++", "--", "---", "?", "]", "^" };

const statement_end_words = [_][]const u8{
    "context",
    "fallthrough",
    "or_break",
    "or_continue",
    "or_return",
    "typeid",
};

const keyword_kinds = [_]struct { []const u8, Kind }{
    .{ "asm", .asm_keyword },
    .{ "auto_cast", .auto_cast_keyword },
    .{ "bit_field", .bit_field_keyword },
    .{ "bit_set", .bit_set_keyword },
    .{ "break", .break_keyword },
    .{ "case", .case_keyword },
    .{ "cast", .cast_keyword },
    .{ "context", .context_keyword },
    .{ "continue", .continue_keyword },
    .{ "defer", .defer_keyword },
    .{ "distinct", .distinct_keyword },
    .{ "do", .do_keyword },
    .{ "dynamic", .dynamic_keyword },
    .{ "else", .else_keyword },
    .{ "enum", .enum_keyword },
    .{ "fallthrough", .fallthrough_keyword },
    .{ "false", .false_keyword },
    .{ "for", .for_keyword },
    .{ "foreign", .foreign_keyword },
    .{ "if", .if_keyword },
    .{ "import", .import_keyword },
    .{ "in", .in_keyword },
    .{ "map", .map_keyword },
    .{ "matrix", .matrix_keyword },
    .{ "nil", .nil_keyword },
    .{ "not_in", .not_in_keyword },
    .{ "or_break", .or_break_keyword },
    .{ "or_continue", .or_continue_keyword },
    .{ "or_else", .or_else_keyword },
    .{ "or_return", .or_return_keyword },
    .{ "package", .package_keyword },
    .{ "proc", .proc_keyword },
    .{ "return", .return_keyword },
    .{ "struct", .struct_keyword },
    .{ "switch", .switch_keyword },
    .{ "transmute", .transmute_keyword },
    .{ "true", .true_keyword },
    .{ "typeid", .typeid_keyword },
    .{ "union", .union_keyword },
    .{ "using", .using_keyword },
    .{ "when", .when_keyword },
    .{ "where", .where_keyword },
};

const operator_kinds = [_]struct { []const u8, Kind }{
    .{ "%%=", .percent_percent_equal },
    .{ "&&=", .ampersand_ampersand_equal },
    .{ "&~=", .ampersand_tilde_equal },
    .{ "---", .minus_minus_minus },
    .{ "...", .dot_dot_dot },
    .{ "..<", .dot_dot_less },
    .{ "..=", .dot_dot_equal },
    .{ "<<=", .less_less_equal },
    .{ ">>=", .greater_greater_equal },
    .{ "||=", .bar_bar_equal },
    .{ "!=", .bang_equal },
    .{ "%%", .percent_percent },
    .{ "%=", .percent_equal },
    .{ "&&", .ampersand_ampersand },
    .{ "&=", .ampersand_equal },
    .{ "&~", .ampersand_tilde },
    .{ "*=", .star_equal },
    .{ "+=", .plus_equal },
    .{ "->", .arrow },
    .{ "-=", .minus_equal },
    .{ "..", .dot_dot },
    .{ "/=", .slash_equal },
    .{ "::", .colon_colon },
    .{ ":=", .colon_equal },
    .{ "<<", .less_less },
    .{ "<=", .less_equal },
    .{ "==", .equal_equal },
    .{ "=>", .fat_arrow },
    .{ ">=", .greater_equal },
    .{ ">>", .greater_greater },
    .{ "|=", .bar_equal },
    .{ "||", .bar_bar },
    .{ "~=", .tilde_equal },
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
    .{ "?", .question },
    .{ "@", .at },
    .{ "[", .bracket_open },
    .{ "]", .bracket_close },
    .{ "^", .caret },
    .{ "{", .brace_open },
    .{ "|", .bar },
    .{ "}", .brace_close },
    .{ "~", .tilde },
    .{ "$", .dollar },
};

const keywords = std.StaticStringMap(Kind).initComptime(keyword_kinds);
const operators = std.StaticStringMap(Kind).initComptime(operator_kinds);
const operator_width_max = 3;

comptime {
    assert(keyword_kinds.len == 42);
    assert(operator_kinds.len == 59);

    for (operator_kinds) |entry| {
        assert(entry[0].len > 0);
        assert(entry[0].len <= operator_width_max);
    }
}

pub fn lex(source: []const u8, tokens: *Tokens) error{Truncated}!void {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.count() == 0);

    var offset = scan.mark_width(source);
    var ends = false;

    while (offset < source.len) {
        const joined = continuation_width(source, offset);

        if (joined > 0) {
            offset += joined;

            continue;
        }

        if (source[offset] == '\n') {
            if (ends) try tokens.push(source, token_of_kind(.newline, offset, 1));

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

        if (token.kind != .comment) ends = ends_statement(token.kind, token.text(source));

        offset = token.end();
    }

    assert(offset == source.len);
}

fn word_of(text: []const u8) Kind {
    assert(text.len > 0);

    return keywords.get(text) orelse .identifier;
}

fn continuation_width(source: []const u8, offset: u32) u32 {
    assert(offset < source.len);

    if (source[offset] != '\\') return 0;

    const cursor = run_scan(source, offset + 1, is_blank);
    const terminator = scan.line_break_width(source, cursor);
    if (terminator == 0) return 0;

    const width = cursor + terminator - offset;

    assert(width >= 2);
    assert(offset + width <= source.len);

    return width;
}

fn ends_statement(kind: Token.Kind, text: []const u8) bool {
    assert(kind != .comment);
    assert(text.len > 0);

    return switch (kind) {
        .block_end, .identifier, .number, .string => true,
        .keyword => |keyword| switch (keyword) {
            .@"break", .@"continue", .@"return" => true,
            else => scan.word_in(&statement_end_words, text),
        },
        .punctuation => scan.word_in(&statement_end_operators, text),
        .block_start, .comment, .newline => false,
    };
}

fn token_of(source: []const u8, offset: u32) Token {
    assert(offset < source.len);

    const byte = source[offset];
    const next = scan.byte_at(source, offset + 1) orelse 0;

    const scanned: Scanned = switch (byte) {
        '/' => switch (next) {
            '/' => .{ .kind = .comment, .end = primitives.line_scan_trimmed(source, offset) },
            '*' => .{ .kind = .comment_block, .end = comment_block_scan(source, offset) },
            else => operator_of(source, offset),
        },
        '{' => .{ .kind = .brace_open, .end = offset + 1 },
        '}' => .{ .kind = .brace_close, .end = offset + 1 },
        '\'' => .{ .kind = .character, .end = string_end_of(source, offset, byte) },
        '"', '`' => .{ .kind = .text, .end = string_end_of(source, offset, byte) },
        '#' => marked_scanned(source, offset),
        '.' => if (std.ascii.isDigit(next))
            number_scanned(source, offset)
        else
            operator_of(source, offset),
        '0'...'9' => number_scanned(source, offset),
        else => if (is_identifier_start_at(source, offset))
            word_scanned(source, offset)
        else
            operator_of(source, offset),
    };

    assert(scanned.end > offset);
    assert(scanned.end <= source.len);

    return token_of_kind(scanned.kind, offset, scanned.end - offset);
}

fn token_of_kind(kind: Kind, offset: u32, length: u32) Token {
    assert(kind.is_token());
    assert(offset < std.math.maxInt(u32));
    assert(length < std.math.maxInt(u32));

    return .{
        .offset = offset,
        .length = length,
        .kind = Kind.token_kind(kind),
        .code = kind.to_u16(),
    };
}

fn comment_block_scan(source: []const u8, start: u32) u32 {
    assert(start < source.len);
    assert(std.mem.startsWith(u8, source[start..], "/*"));

    var offset = start + 2;
    var depth: u32 = 1;

    while (offset + 1 < source.len) {
        assert(depth > 0);
        assert(depth <= primitives.comment_depth_max);

        const pair = source[offset..][0..2];

        if (std.mem.eql(u8, pair, "/*")) {
            if (depth == primitives.comment_depth_max) {
                assert(source.len <= std.math.maxInt(u32));

                return @intCast(source.len);
            }

            depth += 1;
            offset += 2;

            continue;
        }

        if (std.mem.eql(u8, pair, "*/")) {
            depth -= 1;
            offset += 2;

            if (depth == 0) {
                assert(offset <= source.len);

                return offset;
            }

            continue;
        }

        offset += 1;
    }

    assert(source.len <= std.math.maxInt(u32));

    return @intCast(source.len);
}

fn string_end_of(source: []const u8, offset: u32, quote: u8) u32 {
    assert(offset < source.len);
    assert(source[offset] == quote);

    const doubled = std.mem.startsWith(u8, source[offset + 1 ..], &.{ quote, quote });
    const tripled = doubled and quote != '\'';
    if (tripled) return string_triple_scan(source, offset, quote);
    if (quote == '`') return string_raw_scan(source, offset);
    return primitives.string_scan(source, offset, quote);
}

fn string_triple_scan(source: []const u8, start: u32, quote: u8) u32 {
    assert(quote == '"' or quote == '`');
    assert(std.mem.startsWith(u8, source[start..], &.{ quote, quote, quote }));

    const escapes = quote == '"';
    var offset = start + 3;

    while (offset < source.len) {
        const byte = source[offset];
        const escaped = escapes and byte == '\\';

        if (escaped) {
            if (offset + 1 == source.len) break;

            offset += 2;

            continue;
        }

        if (byte == quote) {
            if (std.mem.startsWith(u8, source[offset + 1 ..], &.{ quote, quote })) {
                assert(offset + 3 <= source.len);

                return offset + 3;
            }
        }

        offset += 1;
    }

    assert(source.len <= std.math.maxInt(u32));

    return @intCast(source.len);
}

fn string_raw_scan(source: []const u8, start: u32) u32 {
    assert(start < source.len);
    assert(source[start] == '`');

    const close = std.mem.findScalarPos(u8, source, start + 1, '`') orelse {
        assert(source.len <= std.math.maxInt(u32));

        return @intCast(source.len);
    };

    assert(close > start);

    return @intCast(close + 1);
}

fn marked_scanned(source: []const u8, start: u32) Scanned {
    assert(start < source.len);
    assert(source[start] == '#');

    if (opens_a_tag(source, start)) {
        return .{ .kind = .comment_tag, .end = tag_scan(source, start) };
    }

    const name = start + 1;

    if (is_identifier_start_at(source, name)) {
        return .{ .kind = .directive, .end = identifier_scan(source, name) };
    }

    return .{ .kind = .error_token, .end = name };
}

fn opens_a_tag(source: []const u8, start: u32) bool {
    assert(start < source.len);
    assert(source[start] == '#');

    const next = scan.byte_at(source, start + 1) orelse return false;
    if (next == '+') return true;
    if (next != '!') return false;
    return start == scan.mark_width(source);
}

fn tag_scan(source: []const u8, start: u32) u32 {
    assert(start <= source.len);

    const line = primitives.line_scan_trimmed(source, start);
    const comment = std.mem.findPos(u8, source[0..line], start, "//");
    const end: u32 = if (comment) |found| @intCast(found) else line;
    const trimmed = run_scan_back(source, start, end, is_blank);

    assert(trimmed >= start);
    assert(trimmed <= line);

    return trimmed;
}

fn operator_of(source: []const u8, offset: u32) Scanned {
    assert(offset < source.len);

    var width: u32 = operator_width_max;

    while (width > 0) : (width -= 1) {
        if (offset + width > source.len) continue;

        if (operators.get(source[offset..][0..width])) |kind| {
            return .{ .kind = kind, .end = offset + width };
        }
    }

    assert(width == 0);

    const stray = scan.punctuation_of(source, offset);

    assert(stray.length > 0);
    if (source[offset] < 0x80) assert(stray.length == 1);
    if (source[offset] < 0x80) return .{ .kind = .error_token, .end = offset + 1 };
    return .{ .kind = .identifier, .end = offset + stray.length };
}

fn number_scanned(source: []const u8, offset: u32) Scanned {
    assert(offset < source.len);

    const end = primitives.number_scan_bounded(source, offset, .ranged);

    assert(end > offset);

    return .{ .kind = number_of(source[offset..end]), .end = end };
}

fn number_of(bytes: []const u8) Kind {
    assert(bytes.len > 0);

    if (std.mem.startsWith(u8, bytes, "0h")) return .float;
    if (std.mem.startsWith(u8, bytes, "0H")) return .float;

    const prefixes = [_][]const u8{ "0x", "0X", "0b", "0o", "0d", "0z" };

    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, bytes, prefix)) return .number;
    }

    if (std.mem.findAny(u8, bytes, ".eE") != null) return .float;
    return .number;
}

fn word_scanned(source: []const u8, offset: u32) Scanned {
    assert(is_identifier_start_at(source, offset));

    const end = identifier_scan(source, offset);

    assert(end > offset);

    return .{ .kind = word_of(source[offset..end]), .end = end };
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

fn run_scan(source: []const u8, start: u32, comptime holds: fn (u8) bool) u32 {
    assert(start <= source.len);

    var offset = start;

    while (offset < source.len) : (offset += 1) {
        if (!holds(source[offset])) break;
    }

    assert(offset >= start);
    assert(offset <= source.len);

    return offset;
}

fn run_scan_back(source: []const u8, floor: u32, end: u32, comptime holds: fn (u8) bool) u32 {
    assert(floor <= end);
    assert(end <= source.len);

    var offset = end;

    while (offset > floor) : (offset -= 1) {
        if (!holds(source[offset - 1])) break;
    }

    assert(offset >= floor);
    assert(offset <= end);

    return offset;
}

fn is_blank(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

const Case = struct {
    word: []const u8,
    source: []const u8,
    kind: Token.Kind,
};

const Shape = struct {
    source: []const u8,
    text: []const u8,
};

const StatementEnd = struct {
    source: []const u8,
    newlines: u32,
};

const keyword_cases = [_]Case{
    .{
        .word = "asm",
        .source = "f :: proc() {\n    asm() {}\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "auto_cast",
        .source = "f :: proc(value: int) {\n    other := auto_cast value\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "bit_field",
        .source = "Flags :: bit_field u8 {\n    a: bool | 1,\n}\n",
        .kind = .{ .keyword = .@"struct" },
    },
    .{
        .word = "bit_set",
        .source = "Modes :: bit_set[Mode]\n",
        .kind = .{ .keyword = .@"struct" },
    },
    .{
        .word = "break",
        .source = "f :: proc() {\n    for {\n        break\n    }\n}\n",
        .kind = .{ .keyword = .@"break" },
    },
    .{
        .word = "case",
        .source = "f :: proc(value: int) {\n    switch value {\n    case 1:\n    }\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "cast",
        .source = "f :: proc(value: int) {\n    other := cast(f32)value\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "context",
        .source = "f :: proc() {\n    other := context.allocator\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "continue",
        .source = "f :: proc() {\n    for {\n        continue\n    }\n}\n",
        .kind = .{ .keyword = .@"continue" },
    },
    .{
        .word = "defer",
        .source = "f :: proc() {\n    defer cleanup()\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "distinct",
        .source = "Id :: distinct int\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "do",
        .source = "f :: proc(ready: bool) {\n    if ready do cleanup()\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "dynamic",
        .source = "f :: proc() {\n    values: [dynamic]int\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "else",
        .source = "f :: proc(ready: bool) {\n    if ready {\n    } else {\n    }\n}\n",
        .kind = .{ .keyword = .branch_else },
    },
    .{
        .word = "enum",
        .source = "Mode :: enum {\n    Read,\n}\n",
        .kind = .{ .keyword = .@"struct" },
    },
    .{
        .word = "fallthrough",
        .source = "f :: proc(value: int) {\n    switch value {\n    case 1:\n" ++
            "        fallthrough\n    }\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "for",
        .source = "f :: proc() {\n    for index in 0 ..< 2 {\n    }\n}\n",
        .kind = .{ .keyword = .loop },
    },
    .{
        .word = "foreign",
        .source = "foreign import lib \"system:c\"\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "if",
        .source = "f :: proc(ready: bool) {\n    if ready {\n    }\n}\n",
        .kind = .{ .keyword = .branch },
    },
    .{
        .word = "import",
        .source = "package main\n\nimport \"core:fmt\"\n",
        .kind = .{ .keyword = .import },
    },
    .{
        .word = "in",
        .source = "f :: proc() {\n    for index in 0 ..< 2 {\n    }\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "inline",
        .source = "f :: proc() {\n    other := inline g()\n}\n",
        .kind = .identifier,
    },
    .{
        .word = "map",
        .source = "f :: proc() {\n    values: map[string]int\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "matrix",
        .source = "f :: proc() {\n    values: matrix[2, 2]f32\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "no_inline",
        .source = "f :: proc() {\n    other := no_inline g()\n}\n",
        .kind = .identifier,
    },
    .{
        .word = "not_in",
        .source = "f :: proc(values: map[string]int) -> bool {\n" ++
            "    return \"a\" not_in values\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "or_break",
        .source = "f :: proc() {\n    for {\n        value := g() or_break\n    }\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "or_continue",
        .source = "f :: proc() {\n    for {\n        value := g() or_continue\n    }\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "or_else",
        .source = "f :: proc() {\n    value := g() or_else 0\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "or_return",
        .source = "f :: proc() -> bool {\n    value := g() or_return\n    return true\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "package",
        .source = "package main\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "proc",
        .source = "f :: proc() {\n}\n",
        .kind = .{ .keyword = .function },
    },
    .{
        .word = "return",
        .source = "f :: proc() -> int {\n    return 0\n}\n",
        .kind = .{ .keyword = .@"return" },
    },
    .{
        .word = "struct",
        .source = "Point :: struct {\n    x: int,\n}\n",
        .kind = .{ .keyword = .@"struct" },
    },
    .{
        .word = "switch",
        .source = "f :: proc(value: int) {\n    switch value {\n    }\n}\n",
        .kind = .{ .keyword = .match },
    },
    .{
        .word = "transmute",
        .source = "f :: proc(value: int) {\n    other := transmute(f32)value\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "typeid",
        .source = "f :: proc(kind: typeid) {\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "union",
        .source = "Value :: union {\n    int,\n}\n",
        .kind = .{ .keyword = .@"struct" },
    },
    .{
        .word = "using",
        .source = "f :: proc() {\n    using fmt\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "when",
        .source = "f :: proc() {\n    when ODIN_DEBUG {\n    }\n}\n",
        .kind = .{ .keyword = .branch },
    },
    .{
        .word = "where",
        .source = "f :: proc($T: typeid) where size_of(T) > 0 {\n}\n",
        .kind = .{ .keyword = .other },
    },
};

const marked_cases = [_]Case{
    .{
        .word = "#+build linux",
        .source = "#+build linux\npackage main\n",
        .kind = .comment,
    },
    .{
        .word = "#config",
        .source = "value := #config(NAME, 1)\n",
        .kind = .identifier,
    },
    .{
        .word = "private",
        .source = "@(private)\nvalue := 1\n",
        .kind = .identifier,
    },
    .{
        .word = "#",
        .source = "value := a #  b\n",
        .kind = .{ .punctuation = .other },
    },
    .{
        .word = "#config",
        .source = "#config(NAME, 1)\n",
        .kind = .identifier,
    },
    .{
        .word = "@",
        .source = "@(private)\npackage main\n",
        .kind = .{ .punctuation = .other },
    },
};

const punctuation_cases = [_]Case{
    .{
        .word = "---",
        .source = "value: int = ---\n",
        .kind = .{ .punctuation = .other },
    },
    .{
        .word = ":=",
        .source = "value := 1\n",
        .kind = .{ .punctuation = .assign_declare },
    },
    .{
        .word = "::",
        .source = "Value :: 1\n",
        .kind = .{ .punctuation = .assign_declare },
    },
    .{
        .word = ":",
        .source = "value: int\n",
        .kind = .{ .punctuation = .colon },
    },
};

const comment_shapes = [_]Shape{
    .{ .source = "/* note */\nvalue := 1\n", .text = "/* note */" },
    .{ .source = "/**/\nvalue := 1\n", .text = "/**/" },
    .{ .source = "/* a\n   b */\nvalue := 1\n", .text = "/* a\n   b */" },
    .{
        .source = "/* outer /* inner */ still */\nvalue := 1\n",
        .text = "/* outer /* inner */ still */",
    },
    .{ .source = "// note\nvalue := 1\n", .text = "// note" },
    .{ .source = "value := 1 /* note */\n", .text = "/* note */" },
    .{ .source = "value := 1 /* a */ + 2\n", .text = "/* a */" },
    .{
        .source = "value := 1 /* outer /* inner */ still */ + 2\n",
        .text = "/* outer /* inner */ still */",
    },
    .{
        .source = "value := 1234567890 /* outer /* inner */ still */\n",
        .text = "/* outer /* inner */ still */",
    },
};

const raw_string_shapes = [_]Shape{
    .{ .source = "value := `raw`\n", .text = "`raw`" },
    .{ .source = "value := `a\nb`\n", .text = "`a\nb`" },
    .{ .source = "value := ``\n", .text = "``" },
    .{ .source = "value := `a\\b`\n", .text = "`a\\b`" },
};

const statement_ends = [_]StatementEnd{
    .{ .source = "value := 1\n", .newlines = 1 },
    .{ .source = "run :: proc() {\n}\n", .newlines = 1 },
    .{ .source = "value := call(1)\n", .newlines = 1 },
    .{ .source = "value := items[0]\n", .newlines = 1 },
    .{ .source = "value := pointer^\n", .newlines = 1 },
    .{ .source = "value := \"text\"\n", .newlines = 1 },
    .{ .source = "run :: proc() {\n\treturn\n}\n", .newlines = 2 },
    .{ .source = "run :: proc() {\n\tfor {\n\t\tbreak\n\t}\n}\n", .newlines = 3 },
    .{ .source = "run :: proc() {\n\tfor {\n\t\tcontinue\n\t}\n}\n", .newlines = 3 },
    .{ .source = "run :: proc(v: bool) {\n\tassert(v)\n}\n", .newlines = 2 },
    .{ .source = "run :: proc() {\n\tor_return\n}\n", .newlines = 2 },
    .{ .source = "run :: proc() {\n\tfallthrough\n}\n", .newlines = 2 },
    .{ .source = "value: i64 = ---\n", .newlines = 1 },
    .{ .source = "value := call() or_else 0 if ok else 1\n", .newlines = 1 },
    .{ .source = "value := maybe.?\n", .newlines = 1 },
    .{ .source = "kind: typeid\n", .newlines = 1 },
    .{ .source = "allocator := context\n", .newlines = 1 },
    .{ .source = "value := 1 +\n", .newlines = 0 },
    .{ .source = "// note\n", .newlines = 0 },
    .{ .source = "value :=\n", .newlines = 0 },
};

fn kind_count(source: []const u8, kind: Token.Kind) !u32 {
    assert(source.len <= std.math.maxInt(u32));

    var lexed: Lexed = try .init(.odin, source);
    defer lexed.deinit();

    return lexed.count_of(kind);
}

fn text_first(source: []const u8, kind: Token.Kind) ![]const u8 {
    assert(source.len <= std.math.maxInt(u32));

    var lexed: Lexed = try .init(.odin, source);
    defer lexed.deinit();

    for (lexed.tokens.slice()) |token| {
        if (token.kind.eql(kind)) return token.text(source);
    }

    std.debug.print("{s} carries no {s} token\n", .{ source, kind.name() });

    return error.TestUnexpectedResult;
}

test "a triple quoted string runs to its closing triple" {
    try std.testing.expectEqual(9, string_triple_scan("\"\"\"a\nb\"\"\"", 0, '"'));
    try std.testing.expectEqual(6, string_triple_scan("\"\"\"\"\"\"", 0, '"'));
    try std.testing.expectEqual(10, string_triple_scan("```a\\`b```", 0, '`'));
}

test "an escaped quote does not close a triple quoted string" {
    try std.testing.expectEqual(8, string_triple_scan("\"\"\"\\\"\"\"\"", 0, '"'));
    try std.testing.expectEqual(8, string_triple_scan("\"\"\"a\\\"\"\"", 0, '"'));
}

test "an unclosed triple quoted string runs to the source end" {
    try std.testing.expectEqual(6, string_triple_scan("\"\"\"a\"\"", 0, '"'));
    try std.testing.expectEqual(3, string_triple_scan("\"\"\"", 0, '"'));
    try std.testing.expectEqual(4, string_triple_scan("```a", 0, '`'));
}

test "a backslash at the source end leaves a triple quoted string at the source end" {
    try std.testing.expectEqual(5, string_triple_scan("\"\"\"a\\", 0, '"'));
    try std.testing.expectEqual(4, string_triple_scan("\"\"\"\\", 0, '"'));
    try std.testing.expectEqual(5, string_triple_scan("```a\\", 0, '`'));
}

test "a triple quoted string lexes as one token across lines" {
    try std.testing.expectEqual(1, try kind_count("s := \"\"\"\na \" b\n\"\"\"\n", .string));
    try std.testing.expectEqual(1, try kind_count("s := ```\na ` b\n```\n", .string));
    try std.testing.expectEqual(2, try kind_count("s := \"\" + \"a\"\n", .string));
}

test "a tag stops where a trailing comment starts" {
    try std.testing.expectEqual(13, tag_scan("#+build linux // only there\n", 0));
    try std.testing.expectEqual(13, tag_scan("#+build linux\t// only there\n", 0));
    try std.testing.expectEqual(13, tag_scan("#+build linux   \n", 0));
    try std.testing.expectEqual(13, tag_scan("#+build linux\n", 0));
    try std.testing.expectEqual(13, tag_scan("#+build linux", 0));
    try std.testing.expectEqual(0, tag_scan("//x\n", 0));
    try std.testing.expectEqual(4, tag_scan("#a/b\n", 0));
    try std.testing.expectEqual(0, tag_scan("", 0));
}

test "a continuation covers the backslash and what follows it" {
    try std.testing.expectEqual(2, continuation_width("\\\n", 0));
    try std.testing.expectEqual(4, continuation_width("\\  \n", 0));
    try std.testing.expectEqual(3, continuation_width("\\\t\n", 0));
    try std.testing.expectEqual(0, continuation_width("\\ x\n", 0));
    try std.testing.expectEqual(0, continuation_width("\\", 0));
    try std.testing.expectEqual(0, continuation_width("x\n", 0));
}

test "every comment shape lexes to one comment" {
    for (comment_shapes) |shape| {
        try std.testing.expectEqualStrings(shape.text, try text_first(shape.source, .comment));
    }
}

test "an unterminated block comment runs to the end" {
    try std.testing.expectEqualStrings("/* open\n", try text_first("/* open\n", .comment));
}

test "an unterminated nested block comment runs to the end" {
    const sources = [_][]const u8{
        "/* outer /* inner */\n",
        "/* open",
        "/* open*",
        "/* open/",
        "/*",
        "/*/",
        "/* outer /* inner *",
    };

    for (sources) |source| {
        try std.testing.expectEqualStrings(source, try text_first(source, .comment));
    }
}

test "every raw string shape lexes to one string" {
    for (raw_string_shapes) |shape| {
        try std.testing.expectEqualStrings(shape.text, try text_first(shape.source, .string));
    }
}

test "an unterminated raw string runs to the end" {
    try std.testing.expectEqualStrings("`open\n", try text_first("value := `open\n", .string));
}

test "a file tag leaves the comment after it alone" {
    var lexed: Lexed = try .init(.odin, "#+build linux // only there\npackage main\n");
    defer lexed.deinit();

    try std.testing.expectEqualStrings("#+build linux", lexed.text_at(0));
    try lexed.expect_kind_at(1, .comment);
    try std.testing.expectEqualStrings("// only there", lexed.text_at(1));
}

test "a shebang behind a byte order mark is still a shebang" {
    var lexed: Lexed = try .init(.odin, "\xef\xbb\xbf#!/usr/bin/env odin\npackage main\n");
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .comment);
    try std.testing.expectEqualStrings("#!/usr/bin/env odin", lexed.text_at(0));
}

test "a continuation tolerates a space before its newline" {
    try std.testing.expectEqual(1, try kind_count("value := 1 \\ \nother := 2\n", .newline));
    try std.testing.expectEqual(1, try kind_count("value := 1 \\\r\nother := 2\n", .newline));
}

test "every marked shape lexes to its kind" {
    for (marked_cases) |case| {
        try expect_kind(.odin, case.source, case.word, case.kind);
    }
}

test "a star behind a name does not open a comment" {
    var lexed: Lexed = try .init(.odin, "value := a*b\n");
    defer lexed.deinit();

    try std.testing.expect(lexed.tokens.count() > 0);
    try expect_kind(.odin, "value := a*b\n", "*", .{ .punctuation = .star });
}

test "every punctuation run lexes to its kind" {
    for (punctuation_cases) |case| {
        try expect_kind(.odin, case.source, case.word, case.kind);
    }
}

test "a shebang at the head of the file is a comment" {
    const comment = try text_first("#!/usr/bin/env odin\n", .comment);

    try std.testing.expectEqualStrings("#!/usr/bin/env odin", comment);
}

test "a mark at the end of the source is a punctuation" {
    try expect_kind(.odin, "value := a #", "#", .{ .punctuation = .other });
}

test "a one sided dot float is one number" {
    try expect_kind(.odin, "half := .5\n", ".5", .number);
    try expect_kind(.odin, "one := 1.\n", "1.", .number);
}

test "a range is not a trailing dot float" {
    try expect_kind(.odin, "for i in 1..<5 {\n}\n", "1", .number);
}

test "a backslash before a newline joins the line" {
    try std.testing.expectEqual(2, try kind_count("value := 1\nother := 2\n", .newline));
    try std.testing.expectEqual(2, try kind_count("value := \\\n1\nother := 2\n", .newline));
    try std.testing.expectEqual(2, try kind_count("value := 1 \\\n\nother := 2\n", .newline));
}

test "an undefined value ends its statement" {
    const source = "a: i64 = ---\nb: i64 = ---\nc: i64 = ---\n";

    try std.testing.expectEqual(3, try kind_count(source, .newline));
}

test "a line ends a statement only after a token that can end one" {
    for (statement_ends) |case| {
        try std.testing.expectEqual(case.newlines, try kind_count(case.source, .newline));
    }
}

test "every keyword of the specification lexes to its kind" {
    try std.testing.expectEqual(41, keyword_cases.len);

    for (keyword_cases) |case| {
        try expect_kind(.odin, case.source, case.word, case.kind);
    }
}

test "a comment nested inside the bound still closes where it should" {
    const depth = primitives.comment_depth_max - 1;
    const opens: [depth][2]u8 = @splat("/*".*);
    const closes: [depth][2]u8 = @splat("*/".*);
    const source = std.mem.asBytes(&opens) ++ std.mem.asBytes(&closes) ++ "\nx\n";
    var lexed: Lexed = try .init(.odin, source);
    defer lexed.deinit();

    try std.testing.expectEqual(1, lexed.count_of(.comment));
    try std.testing.expect(lexed.count_of(.identifier) > 0);
}

test "every keyword lexes to its exact kind" {
    for (keyword_kinds) |entry| {
        var lexed: Lexed = try .init(.odin, entry[0]);
        defer lexed.deinit();

        try std.testing.expectEqual(1, lexed.tokens.count());
        try std.testing.expectEqual(entry[1], lexed.token(0).exact_kind(Kind).?);
        try std.testing.expectEqual(Kind.token_kind(entry[1]), lexed.token(0).kind);
    }
}

test "every operator lexes to its exact kind as one token" {
    for (operator_kinds) |entry| {
        var lexed: Lexed = try .init(.odin, entry[0]);
        defer lexed.deinit();

        try std.testing.expectEqual(1, lexed.tokens.count());
        try std.testing.expectEqual(entry[0].len, lexed.token(0).length);
        try std.testing.expectEqual(entry[1], lexed.token(0).exact_kind(Kind).?);
    }
}

test "a marked name splits into its mark and the name" {
    var lexed: Lexed = try .init(.odin, "@private\n");
    defer lexed.deinit();

    try std.testing.expectEqual(3, lexed.tokens.count());
    try std.testing.expectEqual(Kind.at, lexed.token(0).exact_kind(Kind).?);
    try std.testing.expectEqual(Kind.identifier, lexed.token(1).exact_kind(Kind).?);
    try std.testing.expectEqualStrings("private", lexed.text_at(1));
}

test "a do body leaves no token behind" {
    var lexed: Lexed = try .init(.odin, "if x do y\nz := 1\n");
    defer lexed.deinit();

    for (lexed.tokens.slice()) |token| try std.testing.expect(token.length > 0);
}
