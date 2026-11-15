const std = @import("std");
const assert = std.debug.assert;
const Span = @import("../stdx/bounded/span.zig");
const unicode = @import("unicode.zig");

const Class = packed struct(u8) {
    identifier_part: bool,
    whitespace: bool,
    blank: bool,
    padding: u5 = 0,
};

pub const Punctuation = enum(u8) {
    ampersand,
    ampersand_double,
    arrow,
    assign,
    assign_declare,
    bang,
    bar_double,
    bracket_close,
    bracket_open,
    colon,
    comma,
    dot,
    equal,
    greater,
    greater_equal,
    less,
    less_equal,
    not_equal,
    other,
    paren_close,
    paren_open,
    semicolon,
    slash,
    star,

    pub fn name(punctuation: Punctuation) []const u8 {
        const result: []const u8 = switch (punctuation) {
            inline else => |tag| comptime kebab_of(@tagName(tag)),
        };

        assert(result.len > 0);
        assert(std.mem.findScalar(u8, result, '_') == null);

        return result;
    }
};

pub const PunctuationScan = struct {
    punctuation: Punctuation,
    length: u32,
};

pub const ascii_whitespace = " \t\n\x0c\r";
pub const byte_order_mark = "\xef\xbb\xbf";
pub const decimal_bytes_max: u32 = 20;
const escape_digit_max: u32 = 6;
const group_peel_max: u32 = 4;
const tab_columns: u32 = 4;
const vertical_tab: u8 = 0x0b;
const classes: [256]Class = classes_build();

comptime {
    assert(@sizeOf(Class) == 1);
    assert(byte_order_mark.len == 3);
    assert(decimal_width(std.math.maxInt(u64)) == decimal_bytes_max);
}

pub fn mark_width(source: []const u8) u32 {
    assert(source.len <= std.math.maxInt(u32));

    if (std.mem.startsWith(u8, source, byte_order_mark)) return byte_order_mark.len;
    return 0;
}

fn character_start_before(source: []const u8, end: u32) u32 {
    assert(end > 0);
    assert(end <= source.len);

    var start = end - 1;
    var steps: u32 = 0;

    while (start > 0) {
        if (steps == 3) break;
        if (source[start] & 0xc0 != 0x80) break;

        start -= 1;
        steps += 1;
    }

    assert(start < end);
    assert(end - start <= 4);
    assert(steps <= 3);

    return start;
}

fn classes_build() [256]Class {
    @setEvalBranchQuota(16_384);

    var table: [256]Class = undefined;

    for (&table, 0..) |*class, index| {
        const byte: u8 = @intCast(index);
        const whitespace = std.ascii.isWhitespace(byte);
        const line_break = byte == '\n' or byte == '\r';

        class.* = .{
            .identifier_part = is_identifier_part(byte),
            .whitespace = whitespace,
            .blank = whitespace and !line_break,
        };
    }

    assert(table['_'].identifier_part);
    assert(table[' '].blank);
    assert(!table['\n'].blank);
    assert(table[vertical_tab].whitespace);

    return table;
}

pub fn is_ascii_whitespace(byte: u8) bool {
    if (byte > ' ') return false;

    const result: bool = switch (byte) {
        ' ', '\t', '\n', 0x0c, '\r' => true,
        else => false,
    };

    if (result) assert(classes[byte].whitespace);

    return result;
}

pub fn is_identifier_part(byte: u8) bool {
    if (std.ascii.isAlphanumeric(byte)) return true;
    return byte == '_';
}

pub fn is_javascript_identifier_part(byte: u8) bool {
    if (byte == '$') return true;
    return is_identifier_part(byte);
}

pub fn whitespace_width(source: []const u8, offset: u32) u32 {
    assert(offset < source.len);

    const byte = source[offset];
    if (byte < 0x80) return @intFromBool(classes[byte].whitespace);

    const scalar = unicode.decode(source, offset) orelse return 0;
    const spaced = unicode.is_whitespace(scalar.value) or unicode.is_line_terminator(scalar.value);
    const width: u32 = if (spaced) scalar.width else 0;

    assert(width <= 3);
    assert(offset + width <= source.len);

    return width;
}

pub fn whitespace_end(source: []const u8, start: u32) u32 {
    assert(start <= source.len);

    var offset = start;

    while (offset < source.len) : (offset += 1) {
        const byte = source[offset];
        if (byte >= 0x80) break;
        if (!classes[byte].blank) break;
    }

    if (offset == start) {
        if (start < source.len) {
            const end = start + whitespace_width(source, start);

            assert(end <= source.len);

            return end;
        }
    }

    assert(offset <= source.len);
    if (offset > start) assert(classes[source[start]].blank);

    return offset;
}

fn whitespace_scan_back(source: []const u8, end: u32) u32 {
    assert(end <= source.len);

    var start = end;

    while (start > 0) {
        const byte = source[start - 1];

        if (byte < 0x80) {
            if (!classes[byte].whitespace) break;

            start -= 1;

            continue;
        }

        const lead = character_start_before(source, start);
        const width = whitespace_width(source, lead);
        if (width == 0) break;
        if (lead + width != start) break;

        start = lead;
    }

    assert(start <= end);
    if (start < end) assert(whitespace_width(source, start) > 0);

    return start;
}

pub fn line_end(source: []const u8, start: u32) u32 {
    assert(start <= source.len);

    const end: u32 = if (std.mem.findScalarPos(u8, source, start, '\n')) |found|
        @intCast(found)
    else
        @intCast(source.len);

    assert(end >= start);
    if (end < source.len) assert(source[end] == '\n');

    return end;
}

pub fn line_break_width(source: []const u8, offset: u32) u32 {
    assert(offset <= source.len);

    if (offset == source.len) return 0;

    const width: u32 = switch (source[offset]) {
        '\r' => if (byte_at(source, offset + 1) == '\n') 2 else 1,
        '\n' => 1,
        else => 0,
    };

    assert(width <= 2);
    assert(offset + width <= source.len);

    return width;
}

fn escape_holds(source: []const u8, start: u32) bool {
    if (byte_at(source, start) != '\\') return false;

    const escaped = start + 1;
    if (escaped >= source.len) return false;
    return line_break_width(source, escaped) == 0;
}

pub fn escape_end(source: []const u8, start: u32) u32 {
    assert(start < source.len);
    assert(source[start] == '\\');

    var offset = start + 1;
    if (!escape_holds(source, start)) return offset;

    if (!std.ascii.isHex(source[offset])) {
        assert(offset + 1 <= source.len);

        return offset + 1;
    }

    const stop: u32 = @intCast(@min(offset + escape_digit_max, source.len));

    while (offset < stop) : (offset += 1) {
        if (!std.ascii.isHex(source[offset])) break;
    }

    if (offset < source.len) {
        if (line_break_width(source, offset) == 0) offset += whitespace_width(source, offset);
    }

    assert(offset > start);
    assert(offset <= source.len);

    return offset;
}

pub fn punctuation_of(source: []const u8, start: u32) PunctuationScan {
    assert(start < source.len);

    const byte = source[start];

    if (byte >= 0x80) {
        const width: u32 = if (unicode.decode(source, start)) |scalar| scalar.width else 1;

        assert(start + width <= source.len);

        return .{ .punctuation = .other, .length = width };
    }

    const next = byte_at(source, start + 1) orelse 0;
    const third = byte_at(source, start +| 2) orelse 0;

    if (third == '=') {
        if (is_triple_assignment(byte, next)) return .{ .punctuation = .other, .length = 3 };
    }

    if (pair_of(byte, next)) |punctuation| return .{ .punctuation = punctuation, .length = 2 };

    const single: Punctuation = switch (byte) {
        '!' => .bang,
        '&' => .ampersand,
        '(' => .paren_open,
        ')' => .paren_close,
        '*' => .star,
        ',' => .comma,
        '.' => .dot,
        '/' => .slash,
        ':' => .colon,
        ';' => .semicolon,
        '<' => .less,
        '=' => .assign,
        '>' => .greater,
        '[' => .bracket_open,
        ']' => .bracket_close,
        else => .other,
    };

    return .{ .punctuation = single, .length = 1 };
}

fn is_triple_assignment(byte: u8, next: u8) bool {
    if (byte == next) {
        return switch (byte) {
            '<', '>', '*', '/' => true,
            else => false,
        };
    }

    return switch (byte) {
        '+', '-', '*' => next == '%' or next == '|',
        else => false,
    };
}

fn pair_of(byte: u8, next: u8) ?Punctuation {
    if (next == '=') {
        return switch (byte) {
            '=' => .equal,
            '>' => .greater_equal,
            '<' => .less_equal,
            '!' => .not_equal,
            '+', '-', '*', '/', '%', '&', '|', '^' => .other,
            else => null,
        };
    }

    return switch (byte) {
        '&' => if (next == '&') .ampersand_double else null,
        '-' => if (next == '>') .arrow else null,
        '=' => if (next == '>') .other else null,
        '|' => if (next == '|') .bar_double else null,
        else => null,
    };
}

pub fn kebab_of(comptime snake: []const u8) []const u8 {
    assert(snake.len <= std.math.maxInt(u32));

    comptime {
        var buffer: [snake.len]u8 = snake[0..snake.len].*;

        for (&buffer) |*byte| {
            if (byte.* == '_') byte.* = '-';
        }

        assert(std.mem.findScalar(u8, &buffer, '_') == null);

        const kebab = buffer;
        return &kebab;
    }
}

pub fn word_listed(words: []const []const u8, word: []const u8) bool {
    assert(words.len <= std.math.maxInt(u32));
    assert(word.len <= std.math.maxInt(u32));

    for (words, 0..) |listed, index| {
        if (index > 0) assert(std.mem.order(u8, words[index - 1], listed) != .gt);

        if (std.mem.eql(u8, listed, word)) return true;
    }

    return false;
}

pub fn word_in(comptime words: []const []const u8, word: []const u8) bool {
    comptime assert(words.len > 0);
    assert(word.len <= std.math.maxInt(u32));

    const map = comptime std.StaticStringMap(void).initComptime(pairs_of(words));
    return map.has(word);
}

fn pairs_of(comptime words: []const []const u8) [words.len]struct { []const u8 } {
    assert(words.len <= std.math.maxInt(u32));

    var pairs: [words.len]struct { []const u8 } = undefined;

    for (words, &pairs) |word, *pair| {
        pair.* = .{word};
    }

    return pairs;
}

pub fn gap_is_blank(source: []const u8, gap: Span) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(gap.end() <= source.len);

    var offset = gap.offset;

    if (offset == 0) {
        if (std.mem.startsWith(u8, source, byte_order_mark)) {
            offset += @min(byte_order_mark.len, gap.length);
        }
    }

    while (offset < gap.end()) {
        if (std.ascii.isWhitespace(source[offset])) {
            offset += 1;

            continue;
        }

        const width = whitespace_width(source, offset);
        if (width == 0) return false;

        offset += width;
    }

    assert(offset >= gap.end());

    return true;
}

pub fn indent_width(line: []const u8) u32 {
    assert(line.len <= std.math.maxInt(u32));

    var width: u32 = 0;

    for (line) |byte| {
        if (byte == '\t') {
            width += tab_columns - width % tab_columns;
        } else {
            if (!is_ascii_whitespace(byte)) break;

            width += 1;
        }
    }

    assert(width <= line.len * tab_columns);

    return width;
}

pub fn trim_ascii(text: []const u8) []const u8 {
    assert(text.len <= std.math.maxInt(u32));

    const trimmed = std.mem.trim(u8, text, ascii_whitespace);

    assert(trimmed.len <= text.len);
    if (trimmed.len > 0) assert(!is_ascii_whitespace(trimmed[0]));
    if (trimmed.len > 0) assert(!is_ascii_whitespace(trimmed[trimmed.len - 1]));

    return trimmed;
}

pub fn byte_at(source: []const u8, offset: u32) ?u8 {
    assert(source.len <= std.math.maxInt(u32));

    if (offset >= source.len) return null;

    return source[offset];
}

fn line_at(text: []const u8, offset: u32) []const u8 {
    assert(text.len <= std.math.maxInt(u32));
    assert(offset < std.math.maxInt(u32));

    const start: u32 = @intCast(@min(offset, text.len));
    const end = line_end(text, start);

    assert(end >= start);
    assert(end <= text.len);

    return text[start..end];
}

fn line_first(text: []const u8) []const u8 {
    assert(text.len <= std.math.maxInt(u32));

    const line = trim_ascii(line_at(text, 0));

    assert(std.mem.findScalar(u8, line, '\n') == null);

    if (line.len > 0) assert(!is_ascii_whitespace(line[0]));

    return line;
}

pub fn line_start_of(source: []const u8, offset: u32) u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(offset < std.math.maxInt(u32));

    const end: u32 = @intCast(@min(offset, source.len));

    const start: u32 = if (std.mem.findScalarLast(u8, source[0..end], '\n')) |found|
        @intCast(found + 1)
    else
        0;

    assert(start <= end);

    if (start > 0) assert(source[start - 1] == '\n');

    return start;
}

fn string_scan_back(source: []const u8, end: u32, quote: u8) ?u32 {
    assert(end > 0);
    assert(end <= source.len);
    assert(source[end - 1] == quote);

    var cursor = end - 1;

    while (cursor > 0) {
        cursor -= 1;

        if (source[cursor] != quote) continue;
        if (!escaped_at(source, cursor)) return cursor;
    }

    assert(cursor == 0);

    return null;
}

fn escaped_at(source: []const u8, offset: u32) bool {
    assert(offset < source.len);

    var backslashes: u32 = 0;

    while (backslashes < offset) : (backslashes += 1) {
        if (source[offset - 1 - backslashes] != '\\') break;
    }

    assert(backslashes <= offset);
    if (backslashes < offset) assert(source[offset - 1 - backslashes] != '\\');

    return backslashes % 2 == 1;
}

fn group_scan_back(source: []const u8, end: u32) ?u32 {
    assert(end <= source.len);

    if (end == 0) return null;

    const closer = source[end - 1];

    const opener: u8 = switch (closer) {
        ')' => '(',
        ']' => '[',
        '}' => '{',
        else => return null,
    };

    var depth: u32 = 0;
    var cursor = end;

    while (cursor > 0) {
        const byte = source[cursor - 1];

        if (is_quote(byte)) {
            cursor = string_scan_back(source, cursor, byte) orelse return null;

            continue;
        }

        if (byte == closer) depth += 1;

        if (byte == opener) {
            assert(depth > 0);

            depth -= 1;

            if (depth == 0) {
                assert(source[cursor - 1] == opener);

                return cursor - 1;
            }
        }

        cursor -= 1;
    }

    assert(cursor == 0);

    return null;
}

fn is_quote(byte: u8) bool {
    return switch (byte) {
        '"', '\'', '`' => true,
        else => false,
    };
}

pub const Quoting = enum {
    escaped,
    raw,
};

pub fn string_is_terminated(text: []const u8, quoting: Quoting) bool {
    assert(text.len <= std.math.maxInt(u32));

    var prefix: u32 = 0;

    while (prefix < text.len) : (prefix += 1) {
        if (!std.ascii.isAlphabetic(text[prefix])) break;
    }

    assert(prefix <= text.len);

    const quote = byte_at(text, prefix) orelse return false;
    if (!is_quote(quote)) return false;

    const tripled = text.len >= prefix + 3 and std.mem.allEqual(u8, text[prefix..][0..3], quote);

    if (tripled) {
        if (text.len < prefix + 6) return false;
        return std.mem.allEqual(u8, text[text.len - 3 ..], quote);
    }

    if (text.len < prefix + 2) return false;
    if (text[text.len - 1] != quote) return false;

    if (quoting == .raw) {
        if (quote == '`') return true;
        if (std.mem.findScalar(u8, text[0..prefix], 'r') != null) return true;
    }

    return escape_run_back(text, prefix) % 2 == 0;
}

fn escape_run_back(text: []const u8, prefix: u32) u32 {
    assert(text.len >= prefix + 2);

    var offset: u32 = @intCast(text.len - 1);
    var escapes: u32 = 0;

    while (offset > prefix + 1) : (offset -= 1) {
        if (text[offset - 1] != '\\') break;

        escapes += 1;
    }

    assert(escapes <= text.len - prefix - 2);

    return escapes;
}

pub fn contains_folded(haystack: []const u8, needle: []const u8) bool {
    assert(haystack.len <= std.math.maxInt(u32));

    if (needle.len == 0) return false;
    if (needle.len > haystack.len) return false;

    for (0..haystack.len - needle.len + 1) |start| {
        if (starts_with_folded(haystack[start..], needle)) return true;
    }

    return false;
}

fn starts_with_folded(text: []const u8, prefix: []const u8) bool {
    if (prefix.len > text.len) return false;

    for (text[0..prefix.len], prefix) |byte, expected| {
        if (std.ascii.toLower(byte) != expected) return false;
    }

    return true;
}

pub fn find(haystack: []const u8, needle: []const u8) ?u32 {
    assert(haystack.len <= std.math.maxInt(u32));

    if (needle.len == 0) return null;

    const found = std.mem.find(u8, haystack, needle) orelse return null;

    assert(found + needle.len <= haystack.len);

    return @intCast(found);
}

fn is_word_byte(byte: u8) bool {
    if (byte >= 0x80) return true;
    return is_identifier_part(byte);
}

pub fn find_word(haystack: []const u8, name: []const u8) bool {
    assert(haystack.len <= std.math.maxInt(u32));

    if (name.len == 0) return false;

    var offset: u32 = 0;

    while (offset + name.len <= haystack.len) {
        const at = offset + (find(haystack[offset..], name) orelse return false);

        assert(at >= offset);

        const end = at + name.len;
        const opened = at == 0 or !is_word_byte(haystack[at - 1]);
        const closed = end == haystack.len or !is_word_byte(haystack[end]);

        assert(end <= haystack.len);

        if (opened) {
            if (closed) return true;
        }

        offset = at + 1;
    }

    return false;
}

pub fn utf8_or(bytes: []const u8, fallback: []const u8) []const u8 {
    assert(std.unicode.utf8ValidateSlice(fallback));
    assert(bytes.len <= std.math.maxInt(u32));

    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;
    return fallback;
}

pub const Replacement = struct {
    from: u8,
    to: u8,
};

pub fn translated(target: []u8, source: []const u8, replacement: Replacement) ?u32 {
    assert(replacement.from != replacement.to);

    const from = replacement.from;
    const to = replacement.to;

    assert(source.len <= std.math.maxInt(u32));

    if (target.len < source.len) return null;

    for (source, target[0..source.len]) |byte, *slot| {
        slot.* = if (byte == from) to else byte;
    }

    if (from != to) assert(std.mem.findScalar(u8, target[0..source.len], from) == null);

    return @intCast(source.len);
}

pub fn is_char_boundary(bytes: []const u8, offset: u32) bool {
    assert(offset <= bytes.len);

    if (offset == bytes.len) return true;
    return bytes[offset] & 0xc0 != 0x80;
}

pub fn balanced(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    var braces: u32 = 0;
    var brackets: u32 = 0;
    var parens: u32 = 0;

    for (text) |byte| {
        switch (byte) {
            '{' => braces += 1,
            '[' => brackets += 1,
            '(' => parens += 1,
            '}' => braces = std.math.sub(u32, braces, 1) catch return false,
            ']' => brackets = std.math.sub(u32, brackets, 1) catch return false,
            ')' => parens = std.math.sub(u32, parens, 1) catch return false,
            else => {},
        }
    }

    if (braces > 0) return false;
    if (brackets > 0) return false;
    return parens == 0;
}

pub fn stripped_group(text: []const u8) []const u8 {
    assert(text.len <= std.math.maxInt(u32));

    var stripped = trim_ascii(text);

    for (0..group_peel_max) |_| {
        if (stripped.len < 2) break;
        if (stripped[0] != '(') break;
        if (stripped[stripped.len - 1] != ')') break;

        const inner = stripped[1 .. stripped.len - 1];
        if (!balanced(inner)) break;

        stripped = trim_ascii(inner);
    }

    assert(stripped.len <= text.len);

    if (stripped.len > 0) assert(!is_ascii_whitespace(stripped[0]));

    return stripped;
}

pub fn decimal_read(text: []const u8) ?u64 {
    if (text.len == 0) return null;

    if (text.len > 1) {
        if (text[0] == '0') return null;
    }

    var value: u64 = 0;

    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) return null;

        const shifted = std.math.mul(u64, value, 10) catch return null;
        value = std.math.add(u64, shifted, byte - '0') catch return null;
    }

    assert(decimal_width(value) == text.len);
    assert(text.len <= decimal_bytes_max);

    return value;
}

pub fn decimal_width(value: u64) u32 {
    var digits: u32 = 1;
    var remaining = @divFloor(value, 10);

    while (remaining > 0) : (digits += 1) {
        remaining = @divFloor(remaining, 10);
    }

    assert(digits <= decimal_bytes_max);

    if (digits > 1) assert(value >= std.math.pow(u64, 10, digits - 1));
    if (digits < decimal_bytes_max) assert(value < std.math.pow(u64, 10, digits));

    return digits;
}

pub fn decimal_write(digits: []u8, value: u64) u32 {
    assert(digits.len >= decimal_bytes_max);
    assert(decimal_width(value) <= digits.len);

    var remaining = value;
    var length: u32 = 0;

    for (digits[0..decimal_bytes_max]) |*digit| {
        digit.* = '0' + @as(u8, @intCast(remaining % 10));
        remaining = @divFloor(remaining, 10);
        length += 1;

        if (remaining == 0) break;
    }

    assert(remaining == 0);
    assert(length == decimal_width(value));

    std.mem.reverse(u8, digits[0..length]);

    return length;
}

test "a compound assignment carries its whole operator" {
    for ([_][]const u8{ "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=" }) |operator| {
        try std.testing.expectEqual(
            PunctuationScan{ .punctuation = .other, .length = 2 },
            punctuation_of(operator, 0),
        );
    }
}

test "a three byte assignment carries all three" {
    const operators = [_][]const u8{ "<<=", ">>=", "**=", "//=", "+%=", "-%=", "*%=", "+|=" };

    for (operators) |operator| {
        try std.testing.expectEqual(
            PunctuationScan{ .punctuation = .other, .length = 3 },
            punctuation_of(operator, 0),
        );
    }
}

test "a doubled operator without an equals is not an assignment" {
    const expect = std.testing.expectEqual;

    try expect(PunctuationScan{ .punctuation = .less, .length = 1 }, punctuation_of("<<", 0));
    try expect(PunctuationScan{ .punctuation = .greater, .length = 1 }, punctuation_of(">>", 0));
    try expect(PunctuationScan{ .punctuation = .star, .length = 1 }, punctuation_of("**", 0));
    try expect(PunctuationScan{ .punctuation = .slash, .length = 1 }, punctuation_of("//", 0));
    try expect(PunctuationScan{ .punctuation = .other, .length = 1 }, punctuation_of("+%", 0));
    try expect(PunctuationScan{ .punctuation = .other, .length = 1 }, punctuation_of("+|", 0));
}

test "a lone operator is not an assignment" {
    const expect = std.testing.expectEqual;

    try expect(PunctuationScan{ .punctuation = .other, .length = 1 }, punctuation_of("+", 0));
    try expect(PunctuationScan{ .punctuation = .other, .length = 1 }, punctuation_of("+ ", 0));
    try expect(PunctuationScan{ .punctuation = .equal, .length = 2 }, punctuation_of("==", 0));
    try expect(PunctuationScan{ .punctuation = .other, .length = 1 }, punctuation_of("~=", 0));
    const other: PunctuationScan = .{ .punctuation = .other, .length = 1 };
    const wide: PunctuationScan = .{ .punctuation = .other, .length = 3 };
    const widest: PunctuationScan = .{ .punctuation = .other, .length = 4 };

    try expect(wide, punctuation_of("\u{2192}", 0));
    try expect(widest, punctuation_of("\u{1f600}", 0));
    try expect(other, punctuation_of("\xff=", 0));
    try expect(other, punctuation_of("\xe2\x80", 0));
}

test "the class table names what reads it" {
    try std.testing.expect(classes['x'].identifier_part);
    try std.testing.expect(classes['5'].identifier_part);
    try std.testing.expect(classes['_'].identifier_part);
    try std.testing.expect(!classes[' '].identifier_part);

    try std.testing.expect(classes[' '].whitespace);
    try std.testing.expect(classes['\t'].whitespace);
    try std.testing.expect(classes['\n'].whitespace);
    try std.testing.expect(classes['\r'].whitespace);
    try std.testing.expect(classes[vertical_tab].whitespace);
    try std.testing.expect(!classes['x'].whitespace);

    try std.testing.expect(classes[' '].blank);
    try std.testing.expect(classes['\t'].blank);
    try std.testing.expect(classes[vertical_tab].blank);
    try std.testing.expect(!classes['\n'].blank);
    try std.testing.expect(!classes['\r'].blank);
}

test "every space the lexers skip carries its own width" {
    try std.testing.expectEqual(1, whitespace_width(" ", 0));
    try std.testing.expectEqual(1, whitespace_width("\n", 0));
    try std.testing.expectEqual(0, whitespace_width("x", 0));
    try std.testing.expectEqual(2, whitespace_width("\u{0085}", 0));
    try std.testing.expectEqual(2, whitespace_width("\u{00a0}", 0));
    try std.testing.expectEqual(3, whitespace_width("\u{1680}", 0));
    try std.testing.expectEqual(3, whitespace_width("\u{2000}", 0));
    try std.testing.expectEqual(3, whitespace_width("\u{200a}", 0));
    try std.testing.expectEqual(3, whitespace_width("\u{2028}", 0));
    try std.testing.expectEqual(3, whitespace_width("\u{2029}", 0));
    try std.testing.expectEqual(3, whitespace_width("\u{202f}", 0));
    try std.testing.expectEqual(3, whitespace_width("\u{205f}", 0));
    try std.testing.expectEqual(3, whitespace_width("\u{3000}", 0));
    try std.testing.expectEqual(3, whitespace_width("\u{feff}", 0));
    try std.testing.expectEqual(0, whitespace_width("\u{00e4}", 0));
    try std.testing.expectEqual(0, whitespace_width("\u{2013}", 0));
}

test "a blank run ends where the line does" {
    try std.testing.expectEqual(4, whitespace_end("    x", 0));
    try std.testing.expectEqual(3, whitespace_end("\t\t x", 0));
    try std.testing.expectEqual(0, whitespace_end("x", 0));
    try std.testing.expectEqual(4, whitespace_end("    ", 0));
    try std.testing.expectEqual(2, whitespace_end("  \n  ", 0));
    try std.testing.expectEqual(0, whitespace_end("", 0));
    try std.testing.expectEqual(2, whitespace_end("  x", 2));
}

test "a javascript identifier part admits a dollar sign" {
    try std.testing.expect(is_javascript_identifier_part('$'));
    try std.testing.expect(is_javascript_identifier_part('_'));
    try std.testing.expect(!is_javascript_identifier_part(0xc3));
    try std.testing.expect(!is_javascript_identifier_part('.'));
    try std.testing.expect(!is_identifier_part('$'));
}

test "an indent counts the leading blanks" {
    try std.testing.expectEqual(4, indent_width("    let x = 1;"));
    try std.testing.expectEqual(4, indent_width("\tlet x = 1;"));
    try std.testing.expectEqual(4, indent_width("  \tlet x = 1;"));
    try std.testing.expectEqual(8, indent_width("\t\tlet x = 1;"));
    try std.testing.expectEqual(0, indent_width("let x = 1;"));
    try std.testing.expectEqual(4, indent_width("    "));
    try std.testing.expectEqual(0, indent_width(""));
}

test "a decimal reads its digits and refuses everything else" {
    try std.testing.expectEqual(0, decimal_read("0"));
    try std.testing.expectEqual(7, decimal_read("7"));
    try std.testing.expectEqual(1_024, decimal_read("1024"));
    try std.testing.expectEqual(std.math.maxInt(u64), decimal_read("18446744073709551615"));
    try std.testing.expectEqual(null, decimal_read(""));
    try std.testing.expectEqual(null, decimal_read("01"));
    try std.testing.expectEqual(null, decimal_read("1_0"));
    try std.testing.expectEqual(null, decimal_read("-1"));
    try std.testing.expectEqual(null, decimal_read("18446744073709551616"));
}

test "a decimal width matches what the writer writes" {
    const values = [_]u64{ 0, 9, 10, 99, 100, 1_000_000, std.math.maxInt(u64) };
    var digits: [decimal_bytes_max]u8 = undefined;

    for (values) |value| {
        const length = decimal_write(&digits, value);

        try std.testing.expectEqual(decimal_width(value), length);
        try std.testing.expectEqual(value, decimal_read(digits[0..length]));
    }
}

test "a folded prefix ignores the case of the text" {
    try std.testing.expect(starts_with_folded("Content-Length: 7", "content-length:"));
    try std.testing.expect(starts_with_folded("abc", "abc"));
    try std.testing.expect(starts_with_folded("abc", ""));
    try std.testing.expect(!starts_with_folded("ab", "abc"));
    try std.testing.expect(!starts_with_folded("abc", "ABC"));
}

test "a word is found only on an identifier boundary" {
    try std.testing.expect(find_word("let len = 0;", "len"));
    try std.testing.expect(find_word("len", "len"));
    try std.testing.expect(find_word("a.len()", "len"));
    try std.testing.expect(!find_word("let length = 0;", "len"));
    try std.testing.expect(!find_word("olen", "len"));
    try std.testing.expect(!find_word("", "len"));
    try std.testing.expect(!find_word("len", ""));
    try std.testing.expect(find_word("held(value)", "value"));
    try std.testing.expect(!find_word("held(values)", "value"));
    try std.testing.expect(!find_word("held(revalue)", "value"));
}

test "invalid text reads as its fallback" {
    try std.testing.expectEqualStrings("path", utf8_or("path", "<path>"));
    try std.testing.expectEqualStrings("<path>", utf8_or(&.{ 0xff, 0xfe }, "<path>"));
}

test "a boundary falls on a leading byte or the end" {
    const text = "a\u{e9}";

    try std.testing.expect(is_char_boundary(text, 0));
    try std.testing.expect(is_char_boundary(text, 1));
    try std.testing.expect(!is_char_boundary(text, 2));
    try std.testing.expect(is_char_boundary(text, 3));
}

test "a balanced text closes every bracket kind in order" {
    try std.testing.expect(balanced("f(a[0]) { }"));
    try std.testing.expect(balanced(""));
    try std.testing.expect(!balanced("f(a"));
    try std.testing.expect(!balanced("a)"));
    try std.testing.expect(!balanced("(]"));
}

test "a group peels its balanced parentheses" {
    try std.testing.expectEqualStrings("a", stripped_group("((a))"));
    try std.testing.expectEqualStrings("a", stripped_group("  ( a ) "));
    try std.testing.expectEqualStrings("(a) + (b)", stripped_group("(a) + (b)"));
    try std.testing.expectEqualStrings("a", stripped_group("a"));
    try std.testing.expectEqualStrings("value", stripped_group("((value))"));
}

test "a string token reports whether it closed" {
    try std.testing.expect(string_is_terminated("\"abc\"", .escaped));
    try std.testing.expect(string_is_terminated("'abc'", .escaped));
    try std.testing.expect(string_is_terminated("`abc`", .escaped));
    try std.testing.expect(string_is_terminated("r\"abc\"", .escaped));
    try std.testing.expect(string_is_terminated("\"a\\\\\"", .escaped));
    try std.testing.expect(string_is_terminated("\"\"", .escaped));

    try std.testing.expect(!string_is_terminated("\"abc", .escaped));
    try std.testing.expect(!string_is_terminated("'abc", .escaped));
    try std.testing.expect(!string_is_terminated("\"a\\\"", .escaped));
    try std.testing.expect(string_is_terminated("`a\\`", .raw));
    try std.testing.expect(string_is_terminated("r\"a\\\"", .raw));
    try std.testing.expect(!string_is_terminated("\"", .escaped));
    try std.testing.expect(!string_is_terminated("", .escaped));
    try std.testing.expect(!string_is_terminated("abc", .escaped));
}

test "whitespace scans back across blanks and line breaks" {
    try std.testing.expectEqual(1, whitespace_scan_back("a  \n\t b", 6));
    try std.testing.expectEqual(4, whitespace_scan_back("a  b", 4));
    try std.testing.expectEqual(0, whitespace_scan_back("   ", 3));
    try std.testing.expectEqual(0, whitespace_scan_back("", 0));
    try std.testing.expectEqual(0, whitespace_scan_back("a ", 0));
    try std.testing.expectEqual(1, whitespace_scan_back("a\u{a0} b", 4));
    try std.testing.expectEqual(3, whitespace_scan_back("a\u{e9} ", 4));
}

test "a string scans back to its opening quote" {
    try std.testing.expectEqual(4, string_scan_back("x = \"a\"", 7, '"'));
    try std.testing.expectEqual(0, string_scan_back("\"a\\\"b\"", 6, '"'));
    try std.testing.expectEqual(0, string_scan_back("\"a\\\\\"", 5, '"'));
    try std.testing.expectEqual(null, string_scan_back("a\"", 2, '"'));
    try std.testing.expectEqual(0, string_scan_back("''", 2, '\''));
    try std.testing.expectEqual(0, string_scan_back("`a`", 3, '`'));
}

test "a group scans back to its opener over nested groups and strings" {
    try std.testing.expectEqual(1, group_scan_back("f(a, g(b))", 10));
    try std.testing.expectEqual(1, group_scan_back("x[\")\"]", 6));
    try std.testing.expectEqual(0, group_scan_back("{a: [1]}", 8));
    try std.testing.expectEqual(null, group_scan_back("a)", 2));
    try std.testing.expectEqual(null, group_scan_back("abc", 3));
    try std.testing.expectEqual(null, group_scan_back("()", 0));
    try std.testing.expectEqual(null, group_scan_back("", 0));
    try std.testing.expectEqual(null, group_scan_back("(\"", 2));
}

test "a translation swaps one byte for another when it fits" {
    var out: [8]u8 = @splat(0);
    var empty: [0]u8 = .{};

    try std.testing.expectEqual(5, translated(&out, "a_b_c", .{ .from = '_', .to = '-' }));
    try std.testing.expectEqualStrings("a-b-c", out[0..5]);
    try std.testing.expectEqual(0, translated(&out, "", .{ .from = '_', .to = '-' }));
    try std.testing.expectEqual(3, translated(&out, "abc", .{ .from = 'x', .to = 'y' }));
    try std.testing.expectEqualStrings("abc", out[0..3]);
    try std.testing.expectEqual(null, translated(&out, "123456789", .{ .from = '1', .to = '2' }));
    try std.testing.expectEqual(null, translated(&empty, "a", .{ .from = 'a', .to = 'b' }));
}

test "a line at an offset runs to the line break" {
    try std.testing.expectEqualStrings("one", line_at("one\ntwo\n", 0));
    try std.testing.expectEqualStrings("two", line_at("one\ntwo\n", 4));
    try std.testing.expectEqualStrings("two", line_at("one\ntwo", 4));
    try std.testing.expectEqualStrings("", line_at("one\ntwo", 3));
    try std.testing.expectEqualStrings("", line_at("one", 3));
    try std.testing.expectEqualStrings("", line_at("one", 9));
    try std.testing.expectEqualStrings("", line_at("", 0));
    try std.testing.expectEqualStrings("a\r", line_at("a\r\nb", 0));
}

test "the first line is trimmed" {
    try std.testing.expectEqualStrings("# head", line_first("  # head \r\nbody\n"));
    try std.testing.expectEqualStrings("head", line_first("head"));
    try std.testing.expectEqualStrings("", line_first("\nbody"));
    try std.testing.expectEqualStrings("", line_first(""));
}

test "a line starts after the break that precedes the offset" {
    try std.testing.expectEqual(0, line_start_of("one\ntwo", 2));
    try std.testing.expectEqual(0, line_start_of("one\ntwo", 3));
    try std.testing.expectEqual(4, line_start_of("one\ntwo", 4));
    try std.testing.expectEqual(4, line_start_of("one\ntwo", 6));
    try std.testing.expectEqual(4, line_start_of("one\ntwo", 99));
    try std.testing.expectEqual(0, line_start_of("", 0));
}
