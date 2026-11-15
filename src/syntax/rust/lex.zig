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
    kind: Kind,
    coarse: Token.Kind,
    end: u32,
};

const Front = struct {
    start: u32,
    end: u32,
};

const Lexer = struct {
    coarse: Token.Kind,
    coarse_end: u32,
    kind_previous: Kind,
    lifetime: bool,
    previous: ?Token,
    source: []const u8,
    tokens: *Tokens,
};

const assertion_prefixes = [_][]const u8{ "assert", "debug_assert", "prop_assert", "unreachable" };
const character_bytes_max: u32 = 24;
const dash_count_max: u32 = 255;
const expression_ending_words = [_][]const u8{ "?", "await", "self" };
const hash_count_max: u32 = 255;
const prefixes_string = [_][]const u8{ "b", "br", "c", "cr", "rb" };

const keywords = std.StaticStringMap(Kind).initComptime(.{
    .{ "Self", .self_upper },
    .{ "as", .as_keyword },
    .{ "async", .async_keyword },
    .{ "await", .await_keyword },
    .{ "break", .break_keyword },
    .{ "const", .const_keyword },
    .{ "continue", .continue_keyword },
    .{ "crate", .crate_keyword },
    .{ "dyn", .dyn_keyword },
    .{ "else", .else_keyword },
    .{ "enum", .enum_keyword },
    .{ "extern", .extern_keyword },
    .{ "false", .false_keyword },
    .{ "fn", .fn_keyword },
    .{ "for", .for_keyword },
    .{ "if", .if_keyword },
    .{ "impl", .impl_keyword },
    .{ "in", .in_keyword },
    .{ "let", .let_keyword },
    .{ "loop", .loop_keyword },
    .{ "macro", .macro_keyword },
    .{ "match", .match_keyword },
    .{ "mod", .mod_keyword },
    .{ "move", .move_keyword },
    .{ "mut", .mut_keyword },
    .{ "pub", .pub_keyword },
    .{ "ref", .ref_keyword },
    .{ "return", .return_keyword },
    .{ "self", .self_lower },
    .{ "static", .static_keyword },
    .{ "struct", .struct_keyword },
    .{ "super", .super_keyword },
    .{ "trait", .trait_keyword },
    .{ "true", .true_keyword },
    .{ "try", .try_keyword },
    .{ "type", .type_keyword },
    .{ "union", .union_keyword },
    .{ "unsafe", .unsafe_keyword },
    .{ "use", .use_keyword },
    .{ "where", .where_keyword },
    .{ "while", .while_keyword },
    .{ "yield", .yield_keyword },
});

const operators_three = std.StaticStringMap(Kind).initComptime(.{
    .{ "<<=", .less_less_equal },
    .{ ">>=", .greater_greater_equal },
    .{ "..=", .dot_dot_equal },
    .{ "...", .dot_dot_dot },
});

const operators_two = std.StaticStringMap(Kind).initComptime(.{
    .{ "!=", .bang_equal },
    .{ "%=", .percent_equal },
    .{ "&=", .ampersand_equal },
    .{ "*=", .star_equal },
    .{ "+=", .plus_equal },
    .{ "-=", .minus_equal },
    .{ "->", .r_arrow },
    .{ "..", .dot_dot },
    .{ "/=", .slash_equal },
    .{ "::", .colon_colon },
    .{ "<=", .less_equal },
    .{ "==", .equal_equal },
    .{ "=>", .fat_arrow },
    .{ ">=", .greater_equal },
    .{ "^=", .caret_equal },
    .{ "|=", .or_equal },
    .{ "||", .or_or },
});

comptime {
    assert(character_bytes_max > "'\\u{10FFFF}'".len);
    assert(hash_count_max == std.math.maxInt(u8));
}

pub fn lex(source: []const u8, tokens: *Tokens) error{Truncated}!void {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.count() == 0);

    var lexer: Lexer = .{
        .coarse = .newline,
        .coarse_end = 0,
        .kind_previous = .error_token,
        .lifetime = false,
        .previous = null,
        .source = source,
        .tokens = tokens,
    };

    const front = front_of(source);
    var offset = scan.mark_width(source);

    while (offset < source.len) {
        const blank = blank_end(source, offset);

        if (blank > offset) {
            offset = blank;

            continue;
        }

        const scanned: Scanned = if (front_at(front, offset)) |end| .{
            .kind = .comment,
            .coarse = .comment,
            .end = end,
        } else token_scan(&lexer, offset);

        assert(scanned.end > offset);
        assert(scanned.end <= source.len);

        try emit(&lexer, offset, scanned);
        offset = scanned.end;
    }

    assert(offset == source.len);
}

fn emit_one(lexer: *Lexer, offset: u32, scanned: Scanned) error{Truncated}!void {
    assert(scanned.end > offset);
    assert(scanned.kind.is_token());

    const token: Token = .{
        .offset = offset,
        .length = scanned.end - offset,
        .kind = scanned.coarse,
        .code = scanned.kind.to_u16(),
    };

    try lexer.tokens.push(lexer.source, token);

    if (scanned.coarse != .comment) lexer.previous = token;

    if (scanned.kind == .number) {
        if (lexer.source[scanned.end - 1] == '.') {
            const dot: Token.Kind = .{ .punctuation = .dot };

            lexer.previous = .{ .offset = scanned.end - 1, .length = 1, .kind = dot };
        }
    }

    lexer.kind_previous = scanned.kind;
    lexer.lifetime = scanned.kind == .apostrophe;
}

fn emit(lexer: *Lexer, offset: u32, scanned: Scanned) error{Truncated}!void {
    assert(scanned.end > offset);

    const split = scanned.kind == .number and lexer.kind_previous == .dot;
    if (!split) return emit_one(lexer, offset, scanned);

    const text = lexer.source[offset..scanned.end];
    const index = std.mem.findScalar(u8, text, '.') orelse return emit_one(lexer, offset, scanned);
    const middle = offset + @as(u32, @intCast(index));
    const dot: Token.Kind = .{ .punctuation = .dot };

    assert(middle > offset);
    assert(middle < scanned.end);

    try emit_one(lexer, offset, .{ .kind = .number, .coarse = .number, .end = middle });
    try emit_one(lexer, middle, .{ .kind = .dot, .coarse = dot, .end = middle + 1 });

    if (middle + 1 == scanned.end) return;

    assert(std.ascii.isDigit(lexer.source[middle + 1]));

    try emit_one(lexer, middle + 1, .{ .kind = .number, .coarse = .number, .end = scanned.end });
}

fn token_scan(lexer: *Lexer, offset: u32) Scanned {
    const source = lexer.source;

    assert(offset < source.len);

    const byte = source[offset];
    const next = scan.byte_at(source, offset + 1) orelse 0;

    if (lexer.lifetime) return word_scan(lexer, offset);

    return switch (byte) {
        '/' => switch (next) {
            '/' => comment_scanned(source, offset, primitives.line_scan_trimmed(source, offset)),
            '*' => comment_scanned(source, offset, comment_block_scan(source, offset)),
            else => operator_scan(lexer, offset),
        },
        '#' => if (is_shebang(source, offset))
            comment_scanned(source, offset, primitives.line_scan_trimmed(source, offset))
        else
            operator_scan(lexer, offset),
        '{' => .{ .kind = .brace_open, .coarse = .block_start, .end = offset + 1 },
        '}' => .{ .kind = .brace_close, .coarse = .block_end, .end = offset + 1 },
        '"' => scanned: {
            const end = primitives.string_scan_multiline(source, offset, '"');

            break :scanned string_scanned(source, offset, end);
        },
        '\'' => character_scan(lexer, offset),
        '0'...'9' => number_scanned(source, offset),
        'r' => raw_string_of(source, offset) orelse
            raw_identifier_of(source, offset) orelse
            word_scan(lexer, offset),
        'b', 'c' => prefixed_of(source, offset) orelse word_scan(lexer, offset),
        else => if (primitives.is_identifier_start_at(source, offset))
            word_scan(lexer, offset)
        else
            operator_scan(lexer, offset),
    };
}

fn comment_scanned(source: []const u8, offset: u32, end: u32) Scanned {
    assert(end > offset);
    assert(end <= source.len);

    return .{ .kind = comment_of(source[offset..end]), .coarse = .comment, .end = end };
}

fn comment_of(bytes: []const u8) Kind {
    assert(bytes.len >= 2);

    if (std.mem.startsWith(u8, bytes, "///")) return .doc_comment;
    if (std.mem.startsWith(u8, bytes, "//!")) return .doc_comment;
    if (std.mem.startsWith(u8, bytes, "/*!")) return .doc_comment;
    if (!std.mem.startsWith(u8, bytes, "/**")) return .comment;
    if (std.mem.startsWith(u8, bytes, "/**/")) return .comment;
    return .doc_comment;
}

fn string_scanned(source: []const u8, offset: u32, end: u32) Scanned {
    assert(end > offset);
    assert(end <= source.len);

    const suffixed = suffix_end(source, end);

    assert(suffixed >= end);

    return .{ .kind = string_of(source[offset..end]), .coarse = .string, .end = suffixed };
}

fn string_of(bytes: []const u8) Kind {
    assert(bytes.len <= std.math.maxInt(u32));

    const end = prefix_end(bytes);

    assert(end <= bytes.len);

    const prefix = bytes[0..end];
    const quote = if (end < bytes.len) bytes[end] else '"';
    const character = quote == '\'';

    if (std.mem.eql(u8, prefix, "b")) {
        if (character) return .byte_literal;
        return .byte_string_literal;
    }

    if (std.mem.eql(u8, prefix, "br")) return .byte_string_literal;
    if (std.mem.eql(u8, prefix, "rb")) return .byte_string_literal;
    if (std.mem.eql(u8, prefix, "c")) return .c_string_literal;
    if (std.mem.eql(u8, prefix, "cr")) return .c_string_literal;
    if (character) return .char_literal;
    return .string_literal;
}

fn prefix_end(bytes: []const u8) usize {
    assert(bytes.len > 0);

    for (bytes, 0..) |byte, index| {
        switch (byte) {
            '"', '\'', '#' => return index,
            else => {},
        }
    }

    return bytes.len;
}

fn suffix_end(source: []const u8, end: u32) u32 {
    assert(end > 0);
    assert(end <= source.len);

    if (!primitives.is_identifier_start_at(source, end)) return end;
    return primitives.identifier_scan(source, end);
}

fn number_scanned(source: []const u8, offset: u32) Scanned {
    assert(offset < source.len);
    assert(std.ascii.isDigit(source[offset]));

    const body = number_body_end(source, offset);
    const end = suffix_end(source, body);

    assert(body > offset);
    assert(end >= body);

    return .{ .kind = .number, .coarse = .number, .end = end };
}

fn number_body_end(source: []const u8, start: u32) u32 {
    assert(start < source.len);
    assert(std.ascii.isDigit(source[start]));

    const mark: u8 = if (source[start] == '0') scan.byte_at(source, start + 1) orelse 0 else 0;
    const based = mark == 'b' or mark == 'o' or mark == 'x';
    const digits = digits_end(source, start + 1 + @intFromBool(based), mark == 'x');

    assert(digits > start);

    if (scan.byte_at(source, digits) != '.') return exponent_end(source, digits);
    if (!fraction_opens(source, digits + 1)) return digits;

    const fraction = scan.byte_at(source, digits + 1) orelse {
        assert(digits + 1 == source.len);

        return digits + 1;
    };

    if (!std.ascii.isDigit(fraction)) {
        assert(digits + 1 < source.len);

        return digits + 1;
    }

    assert(digits + 1 < source.len);

    return exponent_end(source, digits_end(source, digits + 1, false));
}

fn digits_end(source: []const u8, start: u32, hexadecimal: bool) u32 {
    assert(start <= source.len);

    var offset = start;

    while (offset < source.len) : (offset += 1) {
        const byte = source[offset];
        const digit = if (hexadecimal) std.ascii.isHex(byte) else std.ascii.isDigit(byte);

        if (!digit) {
            if (byte != '_') break;
        }
    }

    assert(offset >= start);
    assert(offset <= source.len);

    return offset;
}

fn fraction_opens(source: []const u8, offset: u32) bool {
    assert(offset > 0);
    assert(offset <= source.len);
    assert(source[offset - 1] == '.');

    const byte = scan.byte_at(source, offset) orelse return true;
    if (byte == '.') return false;
    return !primitives.is_identifier_start_at(source, offset);
}

fn exponent_end(source: []const u8, start: u32) u32 {
    assert(start <= source.len);

    const byte = scan.byte_at(source, start) orelse return start;

    if (byte != 'e') {
        if (byte != 'E') return start;
    }

    const sign = scan.byte_at(source, start + 1) orelse 0;
    const signed = sign == '+' or sign == '-';

    assert(start < source.len);

    return digits_end(source, start + 1 + @intFromBool(signed), false);
}

fn comment_block_scan(source: []const u8, start: u32) u32 {
    assert(start + 1 < source.len);
    assert(source[start] == '/');
    assert(source[start + 1] == '*');

    var depth: u32 = 0;
    var offset = start;

    while (offset + 1 < source.len) {
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
            assert(depth > 0);

            depth -= 1;
            offset += 2;

            if (depth == 0) return offset;

            continue;
        }

        offset += 1;
    }

    assert(source.len <= std.math.maxInt(u32));

    return @intCast(source.len);
}

fn is_shebang(source: []const u8, offset: u32) bool {
    assert(offset < source.len);
    assert(source[offset] == '#');

    if (offset != scan.mark_width(source)) return false;
    if (scan.byte_at(source, offset + 1) != '!') return false;
    return !shebang_attributed(source, offset + 2);
}

fn shebang_attributed(source: []const u8, start: u32) bool {
    assert(start <= source.len);

    var offset = start;

    while (offset < source.len) {
        const width = pattern_space_width(source, offset);

        if (width > 0) {
            offset += width;

            continue;
        }

        const end = comment_plain_end(source, offset) orelse return source[offset] == '[';

        assert(end > offset);

        offset = end;
    }

    return false;
}

fn comment_plain_end(source: []const u8, offset: u32) ?u32 {
    assert(offset < source.len);

    const rest = source[offset..];

    if (std.mem.startsWith(u8, rest, "//")) {
        const outer = std.mem.startsWith(u8, rest, "///") and !std.mem.startsWith(u8, rest, "////");
        if (outer) return null;
        if (std.mem.startsWith(u8, rest, "//!")) return null;
        return scan.line_end(source, offset);
    }

    if (!std.mem.startsWith(u8, rest, "/*")) return null;
    if (std.mem.startsWith(u8, rest, "/*!")) return null;

    const outer = std.mem.startsWith(u8, rest, "/**") and !std.mem.startsWith(u8, rest, "/***") and
        !std.mem.startsWith(u8, rest, "/**/");

    if (outer) return null;
    return comment_block_scan(source, offset);
}

pub fn blank_end(source: []const u8, start: u32) u32 {
    assert(start <= source.len);

    var offset = start;

    while (offset < source.len) {
        const width = pattern_space_width(source, offset);
        if (width == 0) break;

        offset += width;
    }

    assert(offset <= source.len);

    return offset;
}

fn pattern_space_width(source: []const u8, offset: u32) u32 {
    assert(offset < source.len);

    const rest = source[offset..];

    switch (rest[0]) {
        '\t', '\n', 0x0b, 0x0c, '\r', ' ' => return 1,
        else => {},
    }

    if (std.mem.startsWith(u8, rest, "\u{85}")) return 2;

    const wide = [_][]const u8{ "\u{200E}", "\u{200F}", "\u{2028}", "\u{2029}" };

    for (wide) |held| {
        if (std.mem.startsWith(u8, rest, held)) return 3;
    }

    return 0;
}

pub fn front_skip(source: []const u8) u32 {
    assert(source.len <= std.math.maxInt(u32));

    const held = front_of(source) orelse return 0;

    assert(held.end <= source.len);

    return held.end;
}

fn front_of(source: []const u8) ?Front {
    assert(source.len <= std.math.maxInt(u32));

    const mark = scan.mark_width(source);
    const shebang = mark < source.len and source[mark] == '#' and is_shebang(source, mark);
    const after = if (shebang) scan.line_end(source, mark) else mark;
    const start = front_start(source, after) orelse return null;
    const end = front_end(source, start) orelse return null;

    assert(start < end);
    assert(end <= source.len);

    return .{ .start = start, .end = end };
}

fn front_at(front: ?Front, offset: u32) ?u32 {
    if (front == null) return null;

    const held = front.?;
    if (held.start != offset) return null;

    assert(held.end > offset);

    return held.end;
}

fn front_start(source: []const u8, from: u32) ?u32 {
    assert(from <= source.len);

    var offset = from;
    var line_last = false;

    while (offset < source.len) {
        const width = pattern_space_width(source, offset);
        if (width == 0) break;

        line_last = source[offset] == '\n';
        offset += width;
    }

    if (offset > from) {
        if (!line_last) return null;
    }

    if (!std.mem.startsWith(u8, source[offset..], "---")) return null;
    return offset;
}

fn front_end(source: []const u8, start: u32) ?u32 {
    assert(std.mem.startsWith(u8, source[start..], "---"));

    const fence_end = dashes_end(source, start);
    const dashes = fence_end - start;
    if (dashes > dash_count_max) return null;

    const info_end = front_info_end(source, fence_end);
    const line_end = line_break_at(source, info_end) orelse return null;
    const close = front_close(source, line_end, dashes) orelse return null;
    const closed = scan.line_end(source, close);
    const cr_trailing = closed > close and closed < source.len and source[closed - 1] == '\r';
    const end = if (cr_trailing) closed - 1 else closed;

    assert(close > line_end);
    assert(end >= close + dashes);

    if (cr_bare(source[line_end..close])) return null;
    if (dashes_end(source, close) - close != dashes) return null;
    if (!horizontal_only(source[close + dashes .. end])) return null;
    return end;
}

fn front_info_end(source: []const u8, start: u32) u32 {
    assert(start <= source.len);

    var offset = horizontal_end(source, start);

    if (primitives.is_identifier_start_at(source, offset)) {
        offset = info_word_end(source, offset);
    }

    return horizontal_end(source, offset);
}

fn info_word_end(source: []const u8, start: u32) u32 {
    assert(start < source.len);

    var offset = start + (if (source[start] < 0x80) 1 else unicode.decode(source, start).?.width);

    while (offset < source.len) {
        const byte = source[offset];
        const punctuated = byte == '-' or byte == '.';
        const ascii_part = punctuated or (byte < 0x80 and scan.is_identifier_part(byte));

        if (ascii_part) {
            offset += 1;

            continue;
        }

        if (byte < 0x80) break;

        const scalar = unicode.decode(source, offset) orelse break;
        if (!unicode.is_xid_continue(scalar.value)) break;

        offset += scalar.width;
    }

    assert(offset > start);
    assert(offset <= source.len);

    return offset;
}

fn front_close(source: []const u8, from: u32, dashes: u32) ?u32 {
    assert(from < source.len);
    assert(dashes >= 3);

    var offset = from;

    while (offset < source.len) {
        const found = std.mem.findScalarPos(u8, source, offset, '\n') orelse break;
        const line: u32 = @intCast(found + 1);

        if (dashes_end(source, line) - line >= dashes) {
            assert(line <= source.len);

            return line;
        }

        offset = line;
    }

    return null;
}

fn line_break_at(source: []const u8, offset: u32) ?u32 {
    assert(offset <= source.len);

    if (offset == source.len) return null;
    if (source[offset] == '\n') return offset;
    if (source[offset] != '\r') return null;
    if (scan.byte_at(source, offset + 1) != '\n') return null;
    assert(source[offset + 1] == '\n');

    return offset + 1;
}

fn dashes_end(source: []const u8, start: u32) u32 {
    assert(start <= source.len);

    var offset = start;

    while (offset < source.len) : (offset += 1) {
        if (source[offset] != '-') break;
    }

    return offset;
}

fn horizontal_end(source: []const u8, start: u32) u32 {
    assert(start <= source.len);

    var offset = start;

    while (offset < source.len) : (offset += 1) {
        switch (source[offset]) {
            ' ', '\t' => {},
            else => break,
        }
    }

    return offset;
}

fn horizontal_only(bytes: []const u8) bool {
    assert(bytes.len <= std.math.maxInt(u32));

    return std.mem.findNone(u8, bytes, " \t") == null;
}

fn cr_bare(bytes: []const u8) bool {
    assert(bytes.len <= std.math.maxInt(u32));

    var offset: usize = 0;

    while (offset < bytes.len) {
        const found = std.mem.findScalarPos(u8, bytes, offset, '\r') orelse break;
        if (found + 1 >= bytes.len) return true;
        if (bytes[found + 1] != '\n') return true;

        offset = found + 1;
    }

    return false;
}

fn character_scan(lexer: *Lexer, start: u32) Scanned {
    const source = lexer.source;

    assert(start < source.len);
    assert(source[start] == '\'');

    if (character_end(source, start)) |end| return string_scanned(source, start, end);

    if (primitives.is_identifier_start_at(source, start + 1)) {
        return .{ .kind = .apostrophe, .coarse = .identifier, .end = start + 1 };
    }

    return .{ .kind = .identifier, .coarse = .{ .punctuation = .other }, .end = start + 1 };
}

fn character_end(source: []const u8, start: u32) ?u32 {
    assert(start < source.len);
    assert(source[start] == '\'');

    const reach: u32 = @intCast(source.len - start);
    const limit = start + @min(reach, character_bytes_max);
    const escaped = scan.byte_at(source, start + 1) == '\\';
    const first = start + 1 + @intFromBool(escaped);
    const body = if (first < limit) first + 1 else first;

    assert(body <= limit);

    if (escaped) return character_escaped_end(source, body, limit);
    return character_plain_end(source, body, limit);
}

fn character_escaped_end(source: []const u8, body: u32, limit: u32) ?u32 {
    assert(body <= limit);
    assert(limit <= source.len);

    var offset = body;

    while (offset < limit) : (offset += 1) {
        if (source[offset] == '\n') return null;

        if (source[offset] == '\'') {
            assert(offset + 1 <= limit);

            return offset + 1;
        }
    }

    return null;
}

fn character_plain_end(source: []const u8, body: u32, limit: u32) ?u32 {
    assert(body <= limit);
    assert(limit <= source.len);

    var offset = body;

    while (offset < limit) : (offset += 1) {
        if (source[offset] & 0xc0 != 0x80) break;
    }

    if (scan.byte_at(source, offset) != '\'') return null;
    assert(source[offset] == '\'');

    return offset + 1;
}

fn raw_string_of(source: []const u8, prefix: u32) ?Scanned {
    assert(prefix < source.len);
    assert(source[prefix] == 'r');

    const end = raw_string_end_of(source, prefix) orelse return null;
    return string_scanned(source, prefix, end);
}

fn raw_string_end_of(source: []const u8, prefix: u32) ?u32 {
    assert(prefix < source.len);
    assert(source[prefix] == 'r');

    const hashes = raw_string_hashes(source, prefix + 1);
    const quote = prefix + 1 + hashes;
    if (scan.byte_at(source, quote) != '"') return null;

    const end = raw_string_end(source, quote + 1, hashes);

    assert(end > quote);
    assert(end <= source.len);

    return end;
}

fn raw_string_hashes(source: []const u8, start: u32) u32 {
    assert(start > 0);
    assert(start <= source.len);

    var offset = start;

    while (offset < source.len) : (offset += 1) {
        if (source[offset] != '#') break;
        if (offset - start == hash_count_max) break;
    }

    const hashes = offset - start;

    assert(hashes <= hash_count_max);

    return hashes;
}

fn raw_string_end(source: []const u8, start: u32, hashes: u32) u32 {
    assert(start <= source.len);
    assert(hashes <= hash_count_max);

    var offset = start;

    while (offset < source.len) : (offset += 1) {
        if (source[offset] != '"') continue;

        if (raw_string_closes(source, offset + 1, hashes)) {
            assert(offset + 1 + hashes <= source.len);

            return offset + 1 + hashes;
        }
    }

    assert(source.len <= std.math.maxInt(u32));

    return @intCast(source.len);
}

fn raw_string_closes(source: []const u8, start: u32, hashes: u32) bool {
    assert(start <= source.len);
    assert(hashes <= hash_count_max);

    if (hashes > source.len - start) return false;
    return std.mem.allEqual(u8, source[start..][0..hashes], '#');
}

fn raw_identifier_of(source: []const u8, offset: u32) ?Scanned {
    assert(offset < source.len);
    assert(source[offset] == 'r');

    if (scan.byte_at(source, offset + 1) != '#') return null;

    const name = raw_name_start(source, offset + 2) orelse return null;
    const end = primitives.identifier_scan(source, name);

    assert(end > name);

    return .{ .kind = .identifier, .coarse = .identifier, .end = end };
}

fn raw_name_start(source: []const u8, offset: u32) ?u32 {
    assert(offset <= source.len);

    if (primitives.is_identifier_start_at(source, offset)) return offset;
    if (scan.byte_at(source, offset) != '\'') return null;
    if (character_end(source, offset) != null) return null;
    if (!primitives.is_identifier_start_at(source, offset + 1)) return null;
    assert(offset + 1 < source.len);

    return offset + 1;
}

fn prefixed_of(source: []const u8, offset: u32) ?Scanned {
    assert(offset < source.len);
    assert(source[offset] == 'b' or source[offset] == 'c');

    const next = scan.byte_at(source, offset + 1) orelse return null;

    return switch (next) {
        '"' => scanned: {
            const end = primitives.string_scan_multiline(source, offset + 1, '"');

            break :scanned string_scanned(source, offset, end);
        },
        'r' => string_scanned(
            source,
            offset,
            raw_string_end_of(source, offset + 1) orelse return null,
        ),
        else => null,
    };
}

fn word_scan(lexer: *Lexer, offset: u32) Scanned {
    const source = lexer.source;

    assert(primitives.is_identifier_start_at(source, offset));

    const end = primitives.identifier_scan(source, offset);
    const text = source[offset..end];

    assert(end > offset);

    if (!lexer.lifetime) {
        if (string_prefix_end(source, text, end)) |closed| {
            return string_scanned(source, offset, closed);
        }
    }

    const kind = word_kind(text);
    if (lexer.lifetime) return .{ .kind = kind, .coarse = .identifier, .end = end };

    if (is_assertion(source, text, end)) {
        return .{ .kind = kind, .coarse = .{ .keyword = .assert }, .end = end };
    }

    return .{ .kind = kind, .coarse = Kind.token_kind(kind), .end = end };
}

fn word_kind(text: []const u8) Kind {
    assert(text.len > 0);

    if (std.mem.eql(u8, text, "_")) return .underscore;
    return keywords.get(text) orelse .identifier;
}

fn string_prefix_end(source: []const u8, text: []const u8, end: u32) ?u32 {
    assert(end <= source.len);

    if (!scan.word_in(&prefixes_string, text)) return null;

    const quote = scan.byte_at(source, end) orelse return null;
    if (quote == '"') return primitives.string_scan_multiline(source, end, '"');
    if (quote != '\'') return null;
    return character_end(source, end);
}

fn escapes_a_keyword(source: []const u8, offset: u32) bool {
    assert(offset <= source.len);

    if (offset < 2) return false;
    if (source[offset - 1] != '#') return false;
    if (source[offset - 2] != 'r') return false;
    if (offset == 2) return true;
    return !scan.is_identifier_part(source[offset - 3]);
}

fn is_assertion(source: []const u8, text: []const u8, end: u32) bool {
    assert(text.len > 0);
    assert(end <= source.len);

    if (scan.byte_at(source, end) != '!') return false;

    for (assertion_prefixes) |prefix| {
        if (std.mem.startsWith(u8, text, prefix)) return true;
    }

    return false;
}

fn operator_scan(lexer: *Lexer, offset: u32) Scanned {
    const source = lexer.source;

    assert(offset < source.len);

    if (source[offset] >= 0x80) {
        const width: u32 = if (unicode.decode(source, offset)) |scalar| scalar.width else 1;
        const other: Token.Kind = .{ .punctuation = .other };

        return .{ .kind = .identifier, .coarse = other, .end = offset + width };
    }

    if (offset >= lexer.coarse_end) coarse_advance(lexer, offset);

    assert(offset < lexer.coarse_end);

    const joined = operator_join(source, offset);

    assert(joined.end > offset);

    return .{ .kind = joined.kind, .coarse = lexer.coarse, .end = joined.end };
}

fn coarse_advance(lexer: *Lexer, offset: u32) void {
    const source = lexer.source;

    assert(offset < source.len);
    assert(source[offset] < 0x80);

    const operator = scan.punctuation_of(source, offset);
    const lambda = source[offset] == '|' and opens_a_closure(source, lexer.previous);
    const bar: Token.Kind = .{ .keyword = .lambda };

    assert(operator.length > 0);
    assert(operator.length <= unicode.width_max);

    lexer.coarse = if (lambda) bar else .{ .punctuation = operator.punctuation };
    lexer.coarse_end = offset + operator.length;
}

const Joined = struct {
    kind: Kind,
    end: u32,
};

fn operator_join(source: []const u8, offset: u32) Joined {
    assert(offset < source.len);

    if (offset + 3 <= source.len) {
        if (operators_three.get(source[offset..][0..3])) |kind| {
            return .{ .kind = kind, .end = offset + 3 };
        }
    }

    if (offset + 2 <= source.len) {
        if (operators_two.get(source[offset..][0..2])) |kind| {
            return .{ .kind = kind, .end = offset + 2 };
        }
    }

    return .{ .kind = operator_one(source[offset]), .end = offset + 1 };
}

fn operator_one(byte: u8) Kind {
    assert(!std.ascii.isAlphanumeric(byte));

    const kind: Kind = switch (byte) {
        '!' => .bang,
        '#' => .pound,
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
        '@' => .at,
        '[' => .bracket_open,
        ']' => .bracket_close,
        '^' => .caret,
        '{' => .brace_open,
        '|' => .@"or",
        '}' => .brace_close,
        '~' => .tilde,
        else => .error_token,
    };

    assert(kind.is_token());

    return kind;
}

fn opens_a_closure(source: []const u8, previous: ?Token) bool {
    if (previous == null) return true;

    const token = previous.?;

    assert(token.length > 0);
    assert(token.end() <= source.len);

    if (scan.word_in(&expression_ending_words, token.text(source))) return false;

    return switch (token.kind) {
        .block_end, .identifier, .number, .string => false,
        .punctuation => !token.closes_a_group(),
        .block_start, .keyword, .newline => true,
        .comment => unreachable,
    };
}

test "a bar pair after an expression ending word is an operator" {
    const source = "fn f(other: bool, bytes: &[u8]) -> bool {\n" ++
        "    let first = self || other;\n" ++
        "    let second = bytes.is_empty()? || other;\n" ++
        "    let third = task.await || other;\n" ++
        "    let stored = move || other;\n" ++
        "    first && second && third\n}\n";

    var lexed = try Lexed.init(.rust, source);
    defer lexed.deinit();

    try std.testing.expectEqual(1, lexed.count_of(.{ .keyword = .lambda }));
}

test "a raw identifier escapes the word behind its own prefix" {
    try std.testing.expect(escapes_a_keyword("r#fn", 2));
    try std.testing.expect(escapes_a_keyword(" r#fn", 3));
    try std.testing.expect(escapes_a_keyword("(r#fn", 3));
    try std.testing.expect(!escapes_a_keyword("ar#fn", 3));
    try std.testing.expect(!escapes_a_keyword("r_#fn", 3));
    try std.testing.expect(!escapes_a_keyword("#fn", 1));
    try std.testing.expect(!escapes_a_keyword("rfn", 2));
    try std.testing.expect(!escapes_a_keyword("fn", 0));
}

const Case = struct {
    word: []const u8,
    source: []const u8,
    kind: Token.Kind,
};

const keyword_strict_cases = [_]Case{
    .{
        .word = "as",
        .source = "use std::io as system;\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "async",
        .source = "async fn f() {}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "await",
        .source = "async fn f(task: Task) {\n    task.await;\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "break",
        .source = "fn f() {\n    loop {\n        break;\n    }\n}\n",
        .kind = .{ .keyword = .@"break" },
    },
    .{
        .word = "const",
        .source = "const LIMIT: u32 = 4;\n",
        .kind = .{ .keyword = .constant },
    },
    .{
        .word = "continue",
        .source = "fn f() {\n    for index in 0..4 {\n        continue;\n    }\n}\n",
        .kind = .{ .keyword = .@"continue" },
    },
    .{
        .word = "crate",
        .source = "use crate::lex;\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "dyn",
        .source = "fn f(handler: &dyn Fn(u32)) {}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "else",
        .source = "fn f(flag: bool) {\n    if flag {\n    } else {\n    }\n}\n",
        .kind = .{ .keyword = .branch_else },
    },
    .{
        .word = "enum",
        .source = "enum Kind {\n    Null,\n}\n",
        .kind = .{ .keyword = .@"struct" },
    },
    .{
        .word = "extern",
        .source = "extern \"C\" fn f() {}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "false",
        .source = "const FLAG: bool = false;\n",
        .kind = .identifier,
    },
    .{
        .word = "fn",
        .source = "fn f() {}\n",
        .kind = .{ .keyword = .function },
    },
    .{
        .word = "for",
        .source = "fn f() {\n    for index in 0..4 {\n    }\n}\n",
        .kind = .{ .keyword = .loop },
    },
    .{
        .word = "if",
        .source = "fn f(flag: bool) {\n    if flag {\n    }\n}\n",
        .kind = .{ .keyword = .branch },
    },
    .{
        .word = "impl",
        .source = "impl Store {\n}\n",
        .kind = .{ .keyword = .@"struct" },
    },
    .{
        .word = "in",
        .source = "fn f() {\n    for index in 0..4 {\n    }\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "let",
        .source = "fn f() {\n    let value = 1;\n}\n",
        .kind = .{ .keyword = .declare },
    },
    .{
        .word = "loop",
        .source = "fn f() {\n    loop {\n        break;\n    }\n}\n",
        .kind = .{ .keyword = .loop_unbounded },
    },
    .{
        .word = "match",
        .source = "fn f(value: u32) {\n    match value {\n        _ => {}\n    }\n}\n",
        .kind = .{ .keyword = .match },
    },
    .{
        .word = "mod",
        .source = "mod inner {\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "move",
        .source = "fn f() {\n    let closure = move || 1;\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "mut",
        .source = "fn f() {\n    let mut value = 1;\n}\n",
        .kind = .{ .keyword = .mutable },
    },
    .{
        .word = "pub",
        .source = "pub fn f() {}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "ref",
        .source = "fn f(value: u32) {\n    let ref held = value;\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "return",
        .source = "fn f() -> u32 {\n    return 0;\n}\n",
        .kind = .{ .keyword = .@"return" },
    },
    .{
        .word = "self",
        .source = "impl Store {\n    fn read(self) {}\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "Self",
        .source = "impl Store {\n    fn read() -> Self {\n        Store\n    }\n}\n",
        .kind = .identifier,
    },
    .{
        .word = "static",
        .source = "static LIMIT: u32 = 4;\n",
        .kind = .{ .keyword = .constant },
    },
    .{
        .word = "struct",
        .source = "struct Store {\n}\n",
        .kind = .{ .keyword = .@"struct" },
    },
    .{
        .word = "super",
        .source = "use super::lex;\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "trait",
        .source = "trait Read {\n}\n",
        .kind = .{ .keyword = .@"struct" },
    },
    .{
        .word = "true",
        .source = "const FLAG: bool = true;\n",
        .kind = .identifier,
    },
    .{
        .word = "type",
        .source = "type Count = u32;\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "unsafe",
        .source = "unsafe fn f() {}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "use",
        .source = "use std::io;\n",
        .kind = .{ .keyword = .import },
    },
    .{
        .word = "where",
        .source = "fn f<T>(value: T)\nwhere\n    T: Copy,\n{\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "while",
        .source = "fn f(flag: bool) {\n    while flag {\n    }\n}\n",
        .kind = .{ .keyword = .loop },
    },
};

const keyword_reserved_cases = [_]Case{
    .{
        .word = "abstract",
        .source = "fn f() {\n    abstract;\n}\n",
        .kind = .identifier,
    },
    .{
        .word = "become",
        .source = "fn f() {\n    become;\n}\n",
        .kind = .identifier,
    },
    .{
        .word = "box",
        .source = "fn f() {\n    box;\n}\n",
        .kind = .identifier,
    },
    .{
        .word = "do",
        .source = "fn f() {\n    do;\n}\n",
        .kind = .identifier,
    },
    .{
        .word = "final",
        .source = "fn f() {\n    final;\n}\n",
        .kind = .identifier,
    },
    .{
        .word = "gen",
        .source = "fn f() {\n    gen;\n}\n",
        .kind = .identifier,
    },
    .{
        .word = "macro",
        .source = "fn f() {\n    macro;\n}\n",
        .kind = .identifier,
    },
    .{
        .word = "override",
        .source = "fn f() {\n    override;\n}\n",
        .kind = .identifier,
    },
    .{
        .word = "priv",
        .source = "fn f() {\n    priv;\n}\n",
        .kind = .identifier,
    },
    .{
        .word = "try",
        .source = "fn f() {\n    try;\n}\n",
        .kind = .identifier,
    },
    .{
        .word = "typeof",
        .source = "fn f() {\n    typeof;\n}\n",
        .kind = .identifier,
    },
    .{
        .word = "unsized",
        .source = "fn f() {\n    unsized;\n}\n",
        .kind = .identifier,
    },
    .{
        .word = "virtual",
        .source = "fn f() {\n    virtual;\n}\n",
        .kind = .identifier,
    },
    .{
        .word = "yield",
        .source = "fn f() {\n    yield;\n}\n",
        .kind = .identifier,
    },
};

const punctuation_cases = [_]Case{
    .{
        .word = "!",
        .source = "fn f(flag: bool) -> bool {\n    !flag\n}\n",
        .kind = .{ .punctuation = .bang },
    },
    .{
        .word = "!=",
        .source = "fn f(a: u32, b: u32) -> bool {\n    a != b\n}\n",
        .kind = .{ .punctuation = .not_equal },
    },
    .{
        .word = "&",
        .source = "fn f(value: &u32) {}\n",
        .kind = .{ .punctuation = .ampersand },
    },
    .{
        .word = "(",
        .source = "fn f() {}\n",
        .kind = .{ .punctuation = .paren_open },
    },
    .{
        .word = ")",
        .source = "fn f() {}\n",
        .kind = .{ .punctuation = .paren_close },
    },
    .{
        .word = "*",
        .source = "fn f(a: u32, b: u32) -> u32 {\n    a * b\n}\n",
        .kind = .{ .punctuation = .star },
    },
    .{
        .word = "+",
        .source = "fn f(a: u32, b: u32) -> u32 {\n    a + b\n}\n",
        .kind = .{ .punctuation = .other },
    },
    .{
        .word = ",",
        .source = "fn f(a: u32, b: u32) {}\n",
        .kind = .{ .punctuation = .comma },
    },
    .{
        .word = "-",
        .source = "fn f(a: u32, b: u32) -> u32 {\n    a - b\n}\n",
        .kind = .{ .punctuation = .other },
    },
    .{
        .word = "->",
        .source = "fn f() -> u32 {\n    0\n}\n",
        .kind = .{ .punctuation = .arrow },
    },
    .{
        .word = ".",
        .source = "fn f(value: Store) {\n    value.read();\n}\n",
        .kind = .{ .punctuation = .dot },
    },
    .{
        .word = "/",
        .source = "fn f(a: u32, b: u32) -> u32 {\n    a / b\n}\n",
        .kind = .{ .punctuation = .slash },
    },
    .{
        .word = ":",
        .source = "fn f(value: u32) {}\n",
        .kind = .{ .punctuation = .colon },
    },
    .{
        .word = ";",
        .source = "fn f() {\n    let value = 1;\n}\n",
        .kind = .{ .punctuation = .semicolon },
    },
    .{
        .word = "<",
        .source = "fn f(a: u32, b: u32) -> bool {\n    a < b\n}\n",
        .kind = .{ .punctuation = .less },
    },
    .{
        .word = "<=",
        .source = "fn f(a: u32, b: u32) -> bool {\n    a <= b\n}\n",
        .kind = .{ .punctuation = .less_equal },
    },
    .{
        .word = "=",
        .source = "fn f() {\n    let value = 1;\n}\n",
        .kind = .{ .punctuation = .assign },
    },
    .{
        .word = "==",
        .source = "fn f(a: u32, b: u32) -> bool {\n    a == b\n}\n",
        .kind = .{ .punctuation = .equal },
    },
    .{
        .word = ">",
        .source = "fn f(a: u32, b: u32) -> bool {\n    a > b\n}\n",
        .kind = .{ .punctuation = .greater },
    },
    .{
        .word = ">=",
        .source = "fn f(a: u32, b: u32) -> bool {\n    a >= b\n}\n",
        .kind = .{ .punctuation = .greater_equal },
    },
    .{
        .word = "[",
        .source = "fn f(values: [u32; 4]) {}\n",
        .kind = .{ .punctuation = .bracket_open },
    },
    .{
        .word = "]",
        .source = "fn f(values: [u32; 4]) {}\n",
        .kind = .{ .punctuation = .bracket_close },
    },
    .{
        .word = "^",
        .source = "fn f(a: u32, b: u32) -> u32 {\n    a ^ b\n}\n",
        .kind = .{ .punctuation = .other },
    },
    .{
        .word = "{",
        .source = "fn f() {}\n",
        .kind = .block_start,
    },
    .{
        .word = "|",
        .source = "fn f(a: u32, b: u32) -> u32 {\n    a | b\n}\n",
        .kind = .{ .punctuation = .other },
    },
    .{
        .word = "||",
        .source = "fn f(a: bool, b: bool) -> bool {\n    a || b\n}\n",
        .kind = .{ .punctuation = .bar_double },
    },
    .{
        .word = "}",
        .source = "fn f() {}\n",
        .kind = .block_end,
    },
};

const assertion_words = [_][]const u8{
    "assert",
    "assert_eq",
    "assert_ne",
    "debug_assert",
    "debug_assert_eq",
    "debug_assert_ne",
};

test "an escaped quote closes its character literal" {
    const source = "fn f(text: &str) -> bool {\n    text.contains('\\'')\n}\n";

    try expect_texts(.rust, source, .string, &.{"'\\''"});
}

test "every strict keyword of the reference lexes to its kind" {
    try std.testing.expectEqual(38, keyword_strict_cases.len);

    for (keyword_strict_cases) |case| {
        try expect_kind(.rust, case.source, case.word, case.kind);
    }
}

test "every reserved keyword of the reference lexes as an identifier" {
    try std.testing.expectEqual(14, keyword_reserved_cases.len);

    for (keyword_reserved_cases) |case| {
        try expect_kind(.rust, case.source, case.word, case.kind);
    }
}

test "every punctuation of the reference lexes to its kind" {
    for (punctuation_cases) |case| {
        try expect_kind(.rust, case.source, case.word, case.kind);
    }
}

test "a double ampersand is two ampersand tokens under one double ampersand kind" {
    var lexed = try Lexed.init(.rust, "fn f(a: bool, b: bool) -> bool {\n    a && b\n}\n");
    defer lexed.deinit();

    try std.testing.expectEqual(2, lexed.count_of(.{ .punctuation = .ampersand_double }));
    try std.testing.expectEqual(0, lexed.count_of(.{ .punctuation = .ampersand }));
    try std.testing.expectEqual(1, lexed.find("&").?.length);
}

test "a function lexes to its parts" {
    var lexed = try Lexed.init(.rust, "pub fn main() {\n    let value = 1;\n}\n");
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .{ .keyword = .other });
    try lexed.expect_kind_at(1, .{ .keyword = .function });
    try lexed.expect_kind_at(2, .identifier);
    try std.testing.expectEqualStrings("main", lexed.text_at(2));
    try lexed.expect_kind_at(3, .{ .punctuation = .paren_open });
    try lexed.expect_kind_at(5, .block_start);
    try std.testing.expectEqual(Token.Kind.block_end, lexed.tokens.last().?.kind);
}

test "a comment covers its line" {
    var lexed = try Lexed.init(.rust, "// a note\nfn f() {}\n");
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .comment);
    try std.testing.expectEqualStrings("// a note", lexed.text_at(0));
}

test "a nested block comment closes once" {
    var lexed = try Lexed.init(.rust, "/* outer /* inner */ still */ fn f() {}");
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .comment);
    try std.testing.expectEqualStrings("/* outer /* inner */ still */", lexed.text_at(0));
    try lexed.expect_kind_at(1, .{ .keyword = .function });
}

test "a raw string holds its hashes" {
    var lexed = try Lexed.init(.rust, "let text = r#\"a \"quoted\" value\"#;");
    defer lexed.deinit();

    try lexed.expect_kind_at(3, .string);
    try std.testing.expectEqualStrings("r#\"a \"quoted\" value\"#", lexed.text_at(3));
}

test "a lifetime is not a character" {
    var lexed = try Lexed.init(.rust, "fn f<'a>(value: &'a str) -> char { 'x' }");
    defer lexed.deinit();

    try std.testing.expectEqual(1, lexed.count_of(.string));
}

test "a multi byte character is a string" {
    const source = "let accent = '\u{00e9}'; let face = '\u{1F600}';";

    try expect_texts(.rust, source, .string, &.{ "'\u{00e9}'", "'\u{1F600}'" });
}

test "an escaped character is a string" {
    const source = "let line = '\\n'; let face = '\\u{1F600}';";

    try expect_texts(.rust, source, .string, &.{ "'\\n'", "'\\u{1F600}'" });
}

test "a character past the byte limit is not a string" {
    var lexed = try Lexed.init(.rust, "let value = 'aaaaaaaaaaaaaaaa';");
    defer lexed.deinit();

    try std.testing.expectEqual(0, lexed.count_of(.string));
}

test "an escaped character stops at its newline" {
    var lexed = try Lexed.init(.rust, "let value = '\\\nlet next = 1;");
    defer lexed.deinit();

    try std.testing.expectEqual(0, lexed.count_of(.string));
}

test "a lifetime after a quote is an apostrophe then an identifier" {
    try expect_texts(.rust, "fn f<'lifetime>() {}", .identifier, &.{ "f", "'", "lifetime" });
}

test "a character at the source start closes" {
    var lexed = try Lexed.init(.rust, "'x'");
    defer lexed.deinit();

    try std.testing.expectEqual(1, lexed.tokens.count());
    try lexed.expect_kind_at(0, .string);
    try std.testing.expectEqual(3, lexed.token(0).length);
}

test "a block comment ending in a star runs to the source end" {
    var lexed = try Lexed.init(.rust, "/* ending in a star *");
    defer lexed.deinit();

    try std.testing.expectEqual(1, lexed.tokens.count());
    try lexed.expect_kind_at(0, .comment);
    try std.testing.expectEqual(21, lexed.token(0).length);
}

test "a raw prefix at the source end is a name" {
    var lexed = try Lexed.init(.rust, "let value = r");
    defer lexed.deinit();

    const last = lexed.tokens.last().?;

    try std.testing.expectEqual(Token.Kind.identifier, last.kind);
    try std.testing.expectEqual(1, last.length);
}

test "a raw prefix with hashes at the source end is a name" {
    var lexed = try Lexed.init(.rust, "let value = r##");
    defer lexed.deinit();

    try std.testing.expectEqual(0, lexed.count_of(.string));
}

test "a character at the source end closes" {
    var lexed = try Lexed.init(.rust, "let value = 'x'");
    defer lexed.deinit();

    const last = lexed.tokens.last().?;

    try std.testing.expectEqual(Token.Kind.string, last.kind);
    try std.testing.expectEqual(12, last.offset);
    try std.testing.expectEqual(3, last.length);
}

test "an unclosed character at the source end is not a string" {
    var lexed = try Lexed.init(.rust, "let value = 'x");
    defer lexed.deinit();

    try std.testing.expectEqual(0, lexed.count_of(.string));
}

test "a bare quote at the source end is punctuation" {
    var lexed = try Lexed.init(.rust, "let value = '");
    defer lexed.deinit();

    const last = lexed.tokens.last().?;

    try std.testing.expect(last.kind.eql(.{ .punctuation = .other }));
    try std.testing.expectEqual(1, last.length);
}

test "an escaped character at the source end closes" {
    const source = "let line = '\\n'";
    var lexed = try Lexed.init(.rust, source);
    defer lexed.deinit();

    const last = lexed.tokens.last().?;

    try std.testing.expectEqual(Token.Kind.string, last.kind);
    try std.testing.expectEqualStrings("'\\n'", last.text(source));
}

test "a nested block comment closes at its outer end" {
    var lexed = try Lexed.init(.rust, "/* outer /* inner */ still */ let value = 1;");
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .comment);
    try std.testing.expectEqual(29, lexed.token(0).length);
    try std.testing.expectEqualStrings("let", lexed.text_at(1));
}

test "an unclosed block comment runs to the source end" {
    var lexed = try Lexed.init(.rust, "/* outer");
    defer lexed.deinit();

    try std.testing.expectEqual(1, lexed.tokens.count());
    try lexed.expect_kind_at(0, .comment);
    try std.testing.expectEqual(8, lexed.token(0).length);
}

test "a two character quote is not a string" {
    var lexed = try Lexed.init(.rust, "let value = 'ab';");
    defer lexed.deinit();

    try std.testing.expectEqual(0, lexed.count_of(.string));
}

test "an assert is a keyword" {
    var lexed = try Lexed.init(.rust, "assert!(value > 0);");
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .{ .keyword = .assert });
    try lexed.expect_kind_at(1, .{ .punctuation = .bang });
}

test "a prefixed assertion is a keyword" {
    const source = "debug_assert!(value > 0);\nprop_assert_eq!(a, b);\n";
    var lexed = try Lexed.init(.rust, source);
    defer lexed.deinit();

    try std.testing.expectEqual(2, lexed.count_of(.{ .keyword = .assert }));
}

test "an assertion word without a bang is an identifier" {
    inline for (assertion_words) |word| {
        var lexed = try Lexed.init(.rust, "let " ++ word ++ " = 1;");
        defer lexed.deinit();

        try lexed.expect_kind_at(1, .identifier);
    }
}

test "an assertion word with a bang is a keyword" {
    inline for (assertion_words) |word| {
        var lexed = try Lexed.init(.rust, word ++ "!(value);");
        defer lexed.deinit();

        try lexed.expect_kind_at(0, .{ .keyword = .assert });
    }
}

test "a raw string without hashes closes at its quote" {
    var lexed = try Lexed.init(.rust, "let text = r\"a value\";");
    defer lexed.deinit();

    try lexed.expect_kind_at(3, .string);
    try std.testing.expectEqualStrings("r\"a value\"", lexed.text_at(3));
}

test "a c string closes where a string closes" {
    var lexed = try Lexed.init(.rust, "let text = cr#\"say \"hi\"");
    defer lexed.deinit();

    try lexed.expect_kind_at(3, .string);
    try std.testing.expectEqualStrings("cr#\"say \"hi\"", lexed.text_at(3));

    var plained = try Lexed.init(.rust, "let text = c\"say\";\nfn later() {}\n");
    defer plained.deinit();

    try plained.expect_kind_at(3, .string);
    try std.testing.expectEqualStrings("c\"say\"", plained.text_at(3));
    try std.testing.expectEqual(Token.Kind{ .keyword = .function }, plained.find("fn").?.kind);
}

test "a nine hash raw string is still a string" {
    const source = "let text = r#########\"a value\"#########;";
    var lexed = try Lexed.init(.rust, source);
    defer lexed.deinit();

    try lexed.expect_kind_at(3, .string);
}

test "a union call is not a struct" {
    try expect_kind(.rust, "let both = left.union(&right);\n", "union", .identifier);
}

test "a raw identifier does not promote to a keyword" {
    try expect_kind(.rust, "let r#fn = 1;\n", "r#fn", .identifier);
    try expect_kind(.rust, "let r#struct = 1;\n", "r#struct", .identifier);
    try expect_kind(.rust, "fn helper() {}\n", "fn", .{ .keyword = .function });
}

test "a shebang is a comment and an inner attribute is not" {
    var lexed = try Lexed.init(.rust, "#!/usr/bin/env cargo\nfn main() {}\n");
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .comment);
    try std.testing.expectEqualStrings("#!/usr/bin/env cargo", lexed.text_at(0));

    var attributed = try Lexed.init(.rust, "#![allow(dead_code)]\nfn main() {}\n");
    defer attributed.deinit();

    try std.testing.expect(attributed.token(0).kind != .comment);
}

test "a long unicode escape stays inside its character literal" {
    var lexed = try Lexed.init(.rust, "let face = '\\u{01_F600}';\n");
    defer lexed.deinit();

    try lexed.expect_kind_at(3, .string);
    try std.testing.expectEqualStrings("'\\u{01_F600}'", lexed.text_at(3));
    try std.testing.expectEqual(0, lexed.count_of(.block_start));
}

test "a raw string stops taking hashes at the limit" {
    const inside: [hash_count_max]u8 = @splat('#');
    const outside: [hash_count_max + 1]u8 = @splat('#');
    const held = "r" ++ inside ++ "\"a value\"" ++ inside;
    const over = "r" ++ outside ++ "\"a value\"" ++ outside;
    var lexed = try Lexed.init(.rust, "let text = " ++ held ++ ";\n");
    defer lexed.deinit();

    try lexed.expect_kind_at(3, .string);
    try std.testing.expectEqualStrings(held, lexed.text_at(3));

    var overrun = try Lexed.init(.rust, "let text = " ++ over ++ ";\n");
    defer overrun.deinit();

    try overrun.expect_kind_at(3, .identifier);
    try std.testing.expectEqualStrings("r", overrun.text_at(3));
}

test "an escaped character that never closes stops at the source end" {
    var lexed = try Lexed.init(.rust, "let value = '\\n");
    defer lexed.deinit();

    try std.testing.expect(lexed.tokens.count() > 0);

    var stopped = try Lexed.init(.rust, "let value = '\\");
    defer stopped.deinit();

    try std.testing.expect(stopped.tokens.count() > 0);
}

test "a raw string needs as many hashes to close" {
    const source = "let text = r#\"a \"quoted\" value\"#; let next = 1;";
    var lexed = try Lexed.init(.rust, source);
    defer lexed.deinit();

    try std.testing.expectEqualStrings("r#\"a \"quoted\" value\"#", lexed.text_at(3));
    try std.testing.expectEqualStrings("let", lexed.text_at(5));
}

test "an unclosed raw string runs to the source end" {
    var lexed = try Lexed.init(.rust, "let text = r#\"unterminated");
    defer lexed.deinit();

    const last = lexed.tokens.last().?;

    try std.testing.expectEqual(Token.Kind.string, last.kind);
    try std.testing.expectEqual(11, last.offset);
}

test "a raw letter without a quote is a name" {
    var lexed = try Lexed.init(.rust, "let round = 1;");
    defer lexed.deinit();

    try lexed.expect_kind_at(1, .identifier);
    try std.testing.expectEqualStrings("round", lexed.text_at(1));
}

test "a raw letter with hashes but no quote is a name" {
    var lexed = try Lexed.init(.rust, "let value = r#type;");
    defer lexed.deinit();

    try std.testing.expectEqual(0, lexed.count_of(.string));
}

test "a byte raw string carries its prefix" {
    var lexed = try Lexed.init(.rust, "let text = br#\"a \"quoted\" value\"#;");
    defer lexed.deinit();

    try lexed.expect_kind_at(3, .string);
    try std.testing.expectEqualStrings("br#\"a \"quoted\" value\"#", lexed.text_at(3));
}

test "a byte letter before a name is not a raw string" {
    var lexed = try Lexed.init(.rust, "let brush = 1;");
    defer lexed.deinit();

    try lexed.expect_kind_at(1, .identifier);
    try std.testing.expectEqualStrings("brush", lexed.text_at(1));
}

test "a prefixed assertion without a bang is an identifier" {
    var lexed = try Lexed.init(.rust, "let prop_assert_eq = value;");
    defer lexed.deinit();

    try std.testing.expectEqual(0, lexed.count_of(.{ .keyword = .assert }));
}

test "a comment nested inside the bound still closes where it should" {
    const depth = primitives.comment_depth_max - 1;
    const opens: [depth][2]u8 = @splat("/*".*);
    const closes: [depth][2]u8 = @splat("*/".*);
    const source = std.mem.asBytes(&opens) ++ std.mem.asBytes(&closes) ++ "\nx\n";
    var lexed = try Lexed.init(.rust, source);
    defer lexed.deinit();

    try std.testing.expectEqual(1, lexed.count_of(.comment));
    try std.testing.expect(lexed.count_of(.identifier) > 0);
}

test "an extern block is not an import" {
    var lexed = try Lexed.init(.rust, "extern \"C\" fn on_done(packet: *mut T) {}\n");
    defer lexed.deinit();

    try std.testing.expect(!lexed.token(0).is_keyword(.import));
}

test "a number ends where the reference lexer ends it" {
    const Split = struct { source: []const u8, words: []const []const u8 };

    const cases = [_]Split{
        .{ .source = "0xff.count_ones()", .words = &.{ "0xff", ".", "count_ones", "(", ")" } },
        .{ .source = "x.0.1.2", .words = &.{ "x", ".", "0", ".", "1", ".", "2" } },
        .{ .source = "x.0.1u8", .words = &.{ "x", ".", "0", ".", "1u8" } },
        .{ .source = "1.5.6", .words = &.{ "1.5", ".", "6" } },
        .{ .source = "0x1p-4", .words = &.{ "0x1p", "-", "4" } },
        .{ .source = "1u8e+5", .words = &.{ "1u8e", "+", "5" } },
        .{ .source = "1.5e-3f32 1e+5 0b1_0u8", .words = &.{ "1.5e-3f32", "1e+5", "0b1_0u8" } },
        .{ .source = "(1.)", .words = &.{ "(", "1.", ")" } },
        .{ .source = "1..2", .words = &.{ "1", "..", "2" } },
        .{ .source = "1.\u{e9}", .words = &.{ "1", ".", "\u{e9}" } },
    };

    for (cases) |case| {
        var lexed = try Lexed.init(.rust, case.source);
        defer lexed.deinit();

        try std.testing.expectEqual(case.words.len, lexed.tokens.count());

        for (case.words, 0..) |word, index| {
            try std.testing.expectEqualStrings(word, lexed.text_at(@intCast(index)));
        }
    }
}

test "a frontmatter after a shebang is one comment" {
    const front = "---cargo\n[dependencies]\nclap = \"4\"\n---";
    const source = "#!/usr/bin/env cargo\n\n" ++ front ++ "\nfn main() {}\n";
    var lexed = try Lexed.init(.rust, source);
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .comment);
    try lexed.expect_kind_at(1, .comment);
    try std.testing.expectEqualStrings("#!/usr/bin/env cargo", lexed.text_at(0));
    try std.testing.expectEqualStrings(front, lexed.text_at(1));
    try std.testing.expectEqualStrings("fn", lexed.text_at(2));
}

test "a frontmatter takes carriage returns and stops before the break that closes it" {
    var lexed = try Lexed.init(.rust, "---\r\n[package]\r\n---  \r\nfn main() {}\r\n");
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .comment);
    try std.testing.expectEqualStrings("---\r\n[package]\r\n---  ", lexed.text_at(0));
    try std.testing.expectEqualStrings("fn", lexed.text_at(1));
}

test "an infostring takes dots and dashes after its first character" {
    const sources = [_][]const u8{
        "--- Cargo.toml \n---\n",
        "---cargo-script\n---\n",
        "----\n----\n",
        "---\n---",
    };

    for (sources) |source| {
        var lexed = try Lexed.init(.rust, source);
        defer lexed.deinit();

        try std.testing.expectEqual(1, lexed.tokens.count());
        try lexed.expect_kind_at(0, .comment);
    }
}

test "a frontmatter the reference rejects lexes as operators" {
    const outside: [dash_count_max + 1]u8 = @splat('-');

    const sources = [_][]const u8{
        " ---\n---\nfn main() {}\n",
        "---\n----\nfn main() {}\n",
        "----\n---\nfn main() {}\n",
        "---\n--- x\nfn main() {}\n",
        "---.toml\n---\nfn main() {}\n",
        "---cargo toml\n---\nfn main() {}\n",
        "---\na\rb\n---\nfn main() {}\n",
        "---\n[package]\nfn main() {}\n",
        "// lead\n---\n---\nfn main() {}\n",
        "---\n---\n---\n---\nfn main() {}\n",
        "---\n---\r",
        outside ++ "\n" ++ outside ++ "\n",
    };

    for (sources) |source| {
        var lexed = try Lexed.init(.rust, source);
        defer lexed.deinit();

        const minus = lexed.find("-") orelse return error.TestUnexpectedResult;

        try std.testing.expect(minus.kind != .comment);
        try std.testing.expect(lexed.count_of(.comment) <= 1);
    }
}

test "a shebang behind a byte order mark is still a shebang" {
    var lexed = try Lexed.init(.rust, "\u{feff}#!/usr/bin/env run\nfn main() {}\n");
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .comment);
    try std.testing.expectEqualStrings("#!/usr/bin/env run", lexed.text_at(0));
}

test "a bang before a bracket across blanks and plain comments opens an attribute" {
    const attributes = [_][]const u8{
        "#! [allow(dead_code)]\nfn main() {}\n",
        "#!\n[allow(dead_code)]\nfn main() {}\n",
        "#!// plain\n[allow(dead_code)]\nfn main() {}\n",
        "#!/* plain */[allow(dead_code)]\nfn main() {}\n",
        "#!//// plain\n[allow(dead_code)]\nfn main() {}\n",
    };

    for (attributes) |source| {
        var lexed = try Lexed.init(.rust, source);
        defer lexed.deinit();

        try std.testing.expect(lexed.token(0).kind != .comment);
        try std.testing.expectEqualStrings("#", lexed.text_at(0));
    }

    var documented = try Lexed.init(.rust, "#!/// outer\n[allow(dead_code)]\nfn main() {}\n");
    defer documented.deinit();

    try documented.expect_kind_at(0, .comment);
    try std.testing.expectEqualStrings("#!/// outer", documented.text_at(0));
}

test "a direction mark is whitespace and a no-break space is not" {
    var marked = try Lexed.init(.rust, "fn\u{200e}main\u{200f}() {}\n");
    defer marked.deinit();

    try std.testing.expectEqualStrings("fn", marked.text_at(0));
    try std.testing.expectEqualStrings("main", marked.text_at(1));

    var spaced = try Lexed.init(.rust, "fn\u{a0}main() {}\n");
    defer spaced.deinit();

    try std.testing.expectEqualStrings("\u{a0}", spaced.text_at(1));
}
