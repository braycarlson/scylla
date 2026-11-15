const std = @import("std");
const assert = std.debug.assert;
const scan = @import("../../text/scan.zig");
const unicode = @import("../../text/unicode.zig");
pub const comment_depth_max: u32 = 64;

const Lines = enum {
    continued,
    many,
    one,
};

const Numbers = struct {
    dot_may_lead: bool,
    dot_may_trail: bool,
    ranges: bool,

    pub const default: Numbers = .{
        .dot_may_lead = false,
        .dot_may_trail = false,
        .ranges = false,
    };

    pub const one_sided: Numbers = .{
        .dot_may_lead = true,
        .dot_may_trail = true,
        .ranges = false,
    };

    pub const ranged: Numbers = .{
        .dot_may_lead = true,
        .dot_may_trail = true,
        .ranges = true,
    };
};

pub fn identifier_scan(source: []const u8, start: u32) u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(start < std.math.maxInt(u32));

    return identifier_scan_with(source, start, scan.is_identifier_part, unicode.is_xid_continue);
}

pub fn never_part(scalar: u21) bool {
    assert(scalar >= 0x80);
    assert(scalar <= 0x10ffff);

    return false;
}

pub fn identifier_scan_with(
    source: []const u8,
    start: u32,
    comptime part: fn (u8) bool,
    comptime scalar_part: fn (u21) bool,
) u32 {
    assert(start < source.len);

    var offset = start;

    while (offset < source.len) {
        const byte = source[offset];

        if (byte < 0x80) {
            if (!part(byte)) break;

            offset += 1;

            continue;
        }

        const scalar = unicode.decode(source, offset) orelse break;
        if (!scalar_part(scalar.value)) break;

        offset += scalar.width;
    }

    assert(offset > start);
    assert(offset <= source.len);

    return offset;
}

pub fn is_identifier_start(byte: u8) bool {
    if (std.ascii.isAlphabetic(byte)) return true;
    return byte == '_';
}

pub fn is_identifier_start_at(source: []const u8, offset: u32) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(offset < std.math.maxInt(u32));

    return is_identifier_start_with(source, offset, is_identifier_start, unicode.is_xid_start);
}

pub fn is_identifier_start_with(
    source: []const u8,
    offset: u32,
    comptime start: fn (u8) bool,
    comptime scalar_start: fn (u21) bool,
) bool {
    assert(offset <= source.len);

    if (offset == source.len) return false;

    const byte = source[offset];
    if (byte < 0x80) return start(byte);

    const scalar = unicode.decode(source, offset) orelse return false;
    return scalar_start(scalar.value);
}

pub fn line_scan_trimmed(source: []const u8, start: u32) u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(start < std.math.maxInt(u32));

    const end = scan.line_end(source, start);
    var held = end;

    while (held > start) {
        if (source[held - 1] != '\r') break;

        held -= 1;
    }

    assert(held >= start);
    assert(held <= end);
    if (held < end) assert(source[held] == '\r');

    return held;
}

pub fn number_scan(source: []const u8, start: u32) u32 {
    assert(start < source.len);

    const end = number_scan_bounded(source, start, .default);

    assert(end <= source.len);

    return end;
}

pub fn number_scan_bounded(source: []const u8, start: u32, numbers: Numbers) u32 {
    if (numbers.ranges) assert(numbers.dot_may_trail);
    assert(start < source.len);

    if (!std.ascii.isDigit(source[start])) {
        assert(numbers.dot_may_lead);
        assert(source[start] == '.');
    }

    const marked = is_hexadecimal_mark(scan.byte_at(source, start + 1));
    const hexadecimal = source[start] == '0' and marked;
    var dotted = source[start] == '.';
    var offset = start + @intFromBool(dotted);

    while (offset < source.len) {
        const byte = source[offset];
        const exponent = std.ascii.toLower(byte) == @as(u8, if (hexadecimal) 'p' else 'e');

        if (exponent) {
            if (is_sign(scan.byte_at(source, offset + 1))) {
                offset += 2;

                continue;
            }
        }

        if (byte == '.') {
            if (dotted) break;
            if (!fraction_follows(source, offset + 1, hexadecimal, numbers)) break;

            dotted = true;
        } else {
            if (!scan.is_identifier_part(byte)) break;
        }

        offset += 1;
    }

    assert(offset > start);
    assert(offset <= source.len);

    return offset;
}

fn is_sign(byte: ?u8) bool {
    if (byte == null) return false;

    const held = byte orelse return false;
    return held == '+' or held == '-';
}

fn is_hexadecimal_mark(byte: ?u8) bool {
    if (byte == null) return false;

    const held = byte orelse return false;
    return held == 'x' or held == 'X';
}

fn fraction_follows(source: []const u8, offset: u32, hexadecimal: bool, numbers: Numbers) bool {
    if (numbers.ranges) assert(numbers.dot_may_trail);
    assert(offset > 0);
    assert(offset <= source.len);
    assert(source[offset - 1] == '.');

    const byte = scan.byte_at(source, offset) orelse return numbers.dot_may_trail;
    if (std.ascii.isDigit(byte)) return true;

    if (hexadecimal) {
        if (std.ascii.isHex(byte)) return true;
    }

    if (!numbers.dot_may_trail) return false;
    if (!numbers.ranges) return true;
    return byte != '.';
}

pub fn string_scan(source: []const u8, start: u32, quote: u8) u32 {
    assert(start < source.len);
    assert(source[start] == quote);

    const end = string_scan_bounded(source, start, quote, .one);

    assert(end > start);
    assert(end <= source.len);

    return end;
}

pub fn string_scan_continued(source: []const u8, start: u32, quote: u8) u32 {
    assert(start < source.len);
    assert(source[start] == quote);

    const end = string_scan_bounded(source, start, quote, .continued);

    assert(end > start);
    assert(end <= source.len);

    return end;
}

pub fn string_scan_multiline(source: []const u8, start: u32, quote: u8) u32 {
    assert(start < source.len);
    assert(source[start] == quote);

    const end = string_scan_bounded(source, start, quote, .many);

    assert(end > start);
    assert(end <= source.len);

    return end;
}

fn string_scan_bounded(source: []const u8, start: u32, quote: u8, lines: Lines) u32 {
    assert(start < source.len);
    assert(source[start] == quote);

    const bounded = lines != .many;
    var offset = start + 1;

    while (offset < source.len) {
        const byte = source[offset];

        if (bounded) {
            if (scan.line_break_width(source, offset) > 0) return offset;
        }

        if (byte == '\\') {
            const width = escape_width(source, offset, lines) orelse {
                assert(offset + 1 <= source.len);

                return offset + 1;
            };

            offset +|= width;

            continue;
        }

        if (byte == quote) {
            assert(offset + 1 <= source.len);

            return offset + 1;
        }

        offset += 1;
    }

    assert(offset >= source.len);

    return @intCast(@min(offset, source.len));
}

fn escape_width(source: []const u8, offset: u32, lines: Lines) ?u32 {
    assert(offset < source.len);
    assert(source[offset] == '\\');

    const joined = scan.line_break_width(source, offset + 1);

    switch (lines) {
        .one => {
            if (joined > 0) return null;
            if (offset + 1 == source.len) return null;
        },
        .continued => {
            if (joined > 0) {
                assert(1 + joined <= source.len - offset);

                return 1 + joined;
            }
        },
        .many => {},
    }

    return 2;
}

test "a number stops at a field access" {
    try std.testing.expectEqual(1, number_scan("0.map(f)", 0));
    try std.testing.expectEqual(3, number_scan("1.5", 0));
    try std.testing.expectEqual(1, number_scan("0..8", 0));
    try std.testing.expectEqual(4, number_scan("0x1f", 0));
}

test "a scan stops at the source end" {
    try std.testing.expectEqual(5, identifier_scan("value", 0));
    try std.testing.expectEqual(5, identifier_scan("value=1", 0));
    try std.testing.expectEqual(6, scan.line_end("a line", 0));
    try std.testing.expectEqual(6, scan.line_end("a line\nnext", 0));
    try std.testing.expectEqual(0, scan.line_end("", 0));
}

test "a number carries its exponent and stops at the source end" {
    try std.testing.expectEqual(4, number_scan("1e+9", 0));
    try std.testing.expectEqual(4, number_scan("1e-9;", 0));
    try std.testing.expectEqual(6, number_scan("0x1p-4", 0));
    try std.testing.expectEqual(2, number_scan("1e", 0));
    try std.testing.expectEqual(3, number_scan("1e+", 0));
    try std.testing.expectEqual(1, number_scan("7", 0));
    try std.testing.expectEqual(1, number_scan("7 + 1", 0));
    try std.testing.expectEqual(9, number_scan("1_000_000", 0));
}

test "a string that never closes stops at the source end" {
    try std.testing.expectEqual(4, string_scan("\"abc", 0, '"'));
    try std.testing.expectEqual(4, string_scan("\"abc\ndef", 0, '"'));
    try std.testing.expectEqual(4, string_scan_multiline("\"abc", 0, '"'));
    try std.testing.expectEqual(8, string_scan_multiline("\"abc\ndef", 0, '"'));
    try std.testing.expectEqual(4, string_scan("\"ab\\", 0, '"'));
}

test "a hexadecimal literal does not read its own digits as an exponent" {
    try std.testing.expectEqual(4, number_scan("0x1e-1", 0));
    try std.testing.expectEqual(6, number_scan("0xCAFE-1", 0));
    try std.testing.expectEqual(3, number_scan("0XE-1", 0));
    try std.testing.expectEqual(4, number_scan("1e-1", 0));
    try std.testing.expectEqual(5, number_scan("1E+10", 0));
}

test "a hexadecimal float keeps its fraction and its exponent" {
    try std.testing.expectEqual(15, number_scan("0x1.fffffep+127", 0));
    try std.testing.expectEqual(8, number_scan("0x1.fp-2", 0));
    try std.testing.expectEqual(6, number_scan("1.5e-3", 0));
}

test "a decimal literal has no binary exponent" {
    try std.testing.expectEqual(2, number_scan("1p-2", 0));
}

test "a one sided dot is a number only where the language says so" {
    try std.testing.expectEqual(2, number_scan_bounded("1.", 0, .one_sided));
    try std.testing.expectEqual(2, number_scan_bounded("1..toString", 0, .one_sided));
    try std.testing.expectEqual(2, number_scan_bounded(".5", 0, .one_sided));
    try std.testing.expectEqual(1, number_scan_bounded("1..<5", 0, .ranged));
    try std.testing.expectEqual(2, number_scan_bounded("1.", 0, .ranged));
    try std.testing.expectEqual(1, number_scan("1.", 0));
}

test "a literal carries one dot and the next one opens a member" {
    try std.testing.expectEqual(3, number_scan_bounded("1.0.toString", 0, .one_sided));
    try std.testing.expectEqual(2, number_scan_bounded(".5.toString", 0, .one_sided));
    try std.testing.expectEqual(3, number_scan("1.5.hypot", 0));
}

test "a trailing backslash does not carry a one line string over the newline" {
    try std.testing.expectEqual(3, string_scan("\"a\\\nfn later() {}\n", 0, '"'));
    try std.testing.expectEqual(3, string_scan("\"a\\\r\nnext\n", 0, '"'));
    try std.testing.expectEqual(6, string_scan("\"a\\\"b\"", 0, '"'));
    try std.testing.expectEqual(6, string_scan_multiline("\"a\\\nb\"", 0, '"'));
}

test "a one line string ends at a carriage return" {
    try std.testing.expectEqual(3, string_scan("\"ab\r\ncd\"\n", 0, '"'));
}

test "a comment on a windows line leaves the carriage return outside it" {
    try std.testing.expectEqual(7, line_scan_trimmed("// note\r\nnext", 0));
    try std.testing.expectEqual(7, line_scan_trimmed("// note\nnext", 0));
    try std.testing.expectEqual(7, line_scan_trimmed("// note", 0));
    try std.testing.expectEqual(8, scan.line_end("// note\r\nnext", 0));
}

test "an identifier ends at the first byte that cannot continue it" {
    try std.testing.expectEqual(5, identifier_scan("value", 0));
    try std.testing.expectEqual(5, identifier_scan("value = 1", 0));
    try std.testing.expectEqual(4, identifier_scan("a1_b(", 0));
    const word = "wert\u{00e4}hnlich";

    try std.testing.expectEqual(word.len, identifier_scan(word ++ " = 1", 0));
    try std.testing.expectEqual("const".len, identifier_scan("const\u{00a0}value", 0));
    try std.testing.expectEqual("x".len, identifier_scan("x\u{1f600}", 0));
    try std.testing.expectEqual("x".len, identifier_scan("x\xc3", 0));
    try std.testing.expectEqual("x\u{0663}".len, identifier_scan("x\u{0663}", 0));
    const ascii = identifier_scan_with("x\u{00e4}", 0, scan.is_identifier_part, never_part);

    try std.testing.expectEqual("x".len, ascii);
    try std.testing.expect(is_identifier_start_at("\u{00e4}", 0));
    try std.testing.expect(!is_identifier_start_at("\u{0663}", 0));
    try std.testing.expect(!is_identifier_start_at("\u{00a0}", 0));
    try std.testing.expect(!is_identifier_start_at("\xff", 0));
    try std.testing.expect(!is_identifier_start_at("", 0));
    try std.testing.expect(!scan.is_identifier_part(0xc3));
    try std.testing.expect(!is_identifier_start(0xc3));
}

test "a trimmed line drops the return and nothing else" {
    try std.testing.expectEqual(0, line_scan_trimmed("\n", 0));
    try std.testing.expectEqual(0, line_scan_trimmed("", 0));
    try std.testing.expectEqual(3, line_scan_trimmed("one\r\ntwo", 0));
    try std.testing.expectEqual(3, line_scan_trimmed("one\ntwo", 0));
    try std.testing.expectEqual(3, line_scan_trimmed("one", 0));
    try std.testing.expectEqual(8, line_scan_trimmed("one\r\ntwo", 5));
}

test "a continued literal joins on a backslash and stops on a bare line break" {
    try std.testing.expectEqual(6, string_scan_continued("\"a\\\nb\"", 0, '"'));
    try std.testing.expectEqual(7, string_scan_continued("\"a\\\r\nb\"", 0, '"'));
    try std.testing.expectEqual(2, string_scan_continued("\"a\nb\"", 0, '"'));
    try std.testing.expectEqual(6, string_scan_continued("\"a\\\"b\"", 0, '"'));
    try std.testing.expectEqual(4, string_scan_continued("\"ab\"", 0, '"'));
    try std.testing.expectEqual(3, string_scan_continued("\"ab", 0, '"'));
}

test "a number records the base its exponent is read in" {
    try std.testing.expectEqual(4, number_scan("0e-1", 0));
    try std.testing.expectEqual(4, number_scan("0E+1", 0));
    try std.testing.expectEqual(4, number_scan("0x1e-1", 0));
    try std.testing.expectEqual(6, number_scan("0x1p-1", 0));
    try std.testing.expectEqual(4, number_scan("1e-1", 0));
    try std.testing.expectEqual(15, number_scan("0x1.fffffep+127", 0));
    try std.testing.expectEqual(2, number_scan("12 ", 0));
}

test "a leading dot is a number only where the language says so" {
    try std.testing.expectEqual(2, number_scan_bounded(".5+", 0, .one_sided));
    try std.testing.expectEqual(2, number_scan_bounded("1.", 0, .one_sided));
    try std.testing.expectEqual(3, number_scan_bounded("1.5", 0, .one_sided));
    try std.testing.expectEqual(1, number_scan_bounded("1..2", 0, .default));
    try std.testing.expectEqual(5, number_scan_bounded("0x1.f", 0, .default));
    try std.testing.expectEqual(1, number_scan_bounded("1.f", 0, .default));
}

test "a one line literal ends at its line terminator backslash or not" {
    try std.testing.expectEqual(3, string_scan("\"a\"x", 0, '"'));
    try std.testing.expectEqual(6, string_scan("\"a\\\"b\"", 0, '"'));
    try std.testing.expectEqual(2, string_scan("\"a\n\"", 0, '"'));
    try std.testing.expectEqual(3, string_scan("\"a\\\n\"b", 0, '"'));
    try std.testing.expectEqual(3, string_scan("\"a\\", 0, '"'));
    try std.testing.expectEqual(2, string_scan("\"a", 0, '"'));
}
