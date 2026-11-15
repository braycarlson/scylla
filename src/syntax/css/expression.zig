const std = @import("std");
const assert = std.debug.assert;
const Kind = @import("kind.zig").Kind;
const scan = @import("../../text/scan.zig");
const unicode = @import("../../text/unicode.zig");

pub const Number = struct {
    kind: Kind,
    reach: u32,
};

const hex_width_max: u32 = 8;
const hex_width_min: u32 = 3;
pub const nest_depth_max: u32 = 64;
pub const scan_step_max: u32 = 1 << 16;

pub const selector_literals = [_][]const u8{
    "has",
    "host",
    "host-context",
    "is",
    "not",
    "nth-child",
    "nth-last-child",
    "where",
};

pub const nth_literals = [_][]const u8{ "nth-child", "nth-last-child" };
pub const query_joins = [_][]const u8{ "and", "or" };
pub const query_prefixes = [_][]const u8{ "not", "only" };

comptime {
    assert(hex_width_min < hex_width_max);
    assert(nest_depth_max > 0);
    assert(scan_step_max > nest_depth_max);
}

fn is_delimiter(byte: u8) bool {
    const result = switch (byte) {
        '\t', '\n', 0x0b, 0x0c, '\r', ' ', '!', '(', ')', ',', ';', '[', ']', '{', '}' => true,
        else => false,
    };

    if (result) assert(byte < 0x80);

    return result;
}

pub fn is_name_byte(byte: u8) bool {
    if (byte < '-') return false;

    const result = std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte >= 0x80;

    if (result) assert(!is_delimiter(byte));

    return result;
}

pub fn is_name_start(byte: u8) bool {
    if (byte < '-') return false;

    const result = std.ascii.isAlphabetic(byte) or byte == '_' or byte == '-' or byte >= 0x80;

    if (result) assert(is_name_byte(byte));

    return result;
}

fn is_unit_byte(byte: u8) bool {
    if (byte < '%') return false;

    const result = std.ascii.isAlphabetic(byte) or byte == '%';

    if (result) assert(!is_delimiter(byte));

    return result;
}

pub fn is_value_operator(kind: Kind) bool {
    assert(kind.is_token());

    return switch (kind) {
        .minus, .plus, .slash, .star => true,
        else => false,
    };
}

pub fn is_combinator(kind: Kind) bool {
    assert(kind.is_token());

    return switch (kind) {
        .greater, .pipe, .plus, .tilde => true,
        else => false,
    };
}

pub fn combinator_node(kind: Kind) Kind {
    assert(kind.is_token());

    const node: Kind = switch (kind) {
        .greater => .child_selector,
        .pipe => .namespace_selector,
        .plus => .adjacent_sibling_selector,
        else => .sibling_selector,
    };

    assert(node.is_node());

    return node;
}

pub fn opens_a_selector(kind: Kind) bool {
    assert(kind.is_token());

    return switch (kind) {
        .ampersand,
        .bracket_open,
        .colon,
        .colon_colon,
        .dot,
        .hash,
        .identifier,
        .star,
        .text,
        => true,
        else => false,
    };
}

pub fn is_tight_postfix(kind: Kind) bool {
    assert(kind.is_token());

    const result = kind == .dot;

    if (result) assert(opens_a_selector(kind));

    return result;
}

pub fn is_loose_postfix(kind: Kind) bool {
    assert(kind.is_token());

    return switch (kind) {
        .bracket_open, .colon, .colon_colon, .hash => true,
        else => false,
    };
}

fn escape_end(source: []const u8, start: u32) u32 {
    assert(start < source.len);
    assert(source[start] == '\\');

    return scan.escape_end(source, start);
}

pub fn identifier_end(source: []const u8, start: u32) ?u32 {
    assert(source.len <= std.math.maxInt(u32));

    if (start >= source.len) return null;

    const byte = source[start];
    if (!is_name_start(byte)) return null;

    if (byte == '-') {
        if (start + 1 >= source.len) return null;

        const next = source[start + 1];

        if (next != '-') {
            if (!is_name_start(next)) return null;
        }
    }

    const width: u32 = if (byte < 0x80)
        1
    else
        (unicode.decode(source, start) orelse return null).width;

    var offset = start + width;

    while (offset < source.len) {
        const held = source[offset];
        if (!is_name_byte(held)) break;

        if (held < 0x80) {
            offset += 1;

            continue;
        }

        const scalar = unicode.decode(source, offset) orelse break;

        offset += scalar.width;
    }

    assert(offset > start);
    assert(offset <= source.len);

    return offset;
}

pub fn plain_value_end(source: []const u8, start: u32) ?u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(start < std.math.maxInt(u32));

    var offset = start;

    for (0..source.len + 1) |_| {
        if (offset >= source.len) break;

        const byte = source[offset];
        const joiner = byte == '-' or byte == '_';

        if (joiner) {
            offset += 1;

            continue;
        }

        if (byte == '/') {
            if (slash_runs(source, offset)) {
                offset += 2;

                continue;
            }
        }

        break;
    }

    if (offset >= source.len) return null;
    if (!std.ascii.isAlphabetic(source[offset])) return null;

    offset += 1;

    const end = plain_value_tail(source, offset);

    assert(end >= offset);

    return end;
}

fn plain_value_tail(source: []const u8, start: u32) u32 {
    assert(start > 0);
    assert(start <= source.len);

    var offset = start;

    for (0..source.len + 1) |_| {
        if (offset >= source.len) break;

        const byte = source[offset];

        if (byte == '/') {
            if (!slash_runs(source, offset)) break;

            offset += 2;

            continue;
        }

        if (is_delimiter(byte)) break;
        if (scan.whitespace_width(source, offset) > 0) break;

        offset += 1;
    }

    assert(offset >= start);
    assert(offset <= source.len);

    return offset;
}

fn slash_runs(source: []const u8, offset: u32) bool {
    assert(offset < source.len);
    assert(source[offset] == '/');

    if (offset + 1 >= source.len) return false;

    const byte = source[offset + 1];
    return byte != '*' and !is_delimiter(byte);
}

pub fn number_end(source: []const u8, start: u32) ?Number {
    assert(source.len <= std.math.maxInt(u32));

    if (start >= source.len) return null;

    const byte = source[start];
    const signed = byte == '+' or byte == '-';
    var offset = start + @intFromBool(signed);
    var digits: u32 = 0;

    while (offset < source.len) : (offset += 1) {
        if (!std.ascii.isDigit(source[offset])) break;

        digits += 1;
    }

    const dotted = digit_follows_dot(source, offset);

    if (digits == 0) {
        if (!dotted) return null;
    }

    var float = dotted;

    if (dotted) {
        offset += 1;

        while (offset < source.len) : (offset += 1) {
            if (!std.ascii.isDigit(source[offset])) break;
        }
    }

    if (exponent_end(source, offset)) |reach| {
        float = true;
        offset = reach;
    }

    assert(offset > start);
    assert(offset <= source.len);

    return .{ .kind = if (float) .float else .number, .reach = offset };
}

fn digit_follows_dot(source: []const u8, offset: u32) bool {
    assert(offset <= source.len);
    assert(source.len <= std.math.maxInt(u32));

    if (offset + 1 >= source.len) return false;
    if (source[offset] != '.') return false;
    return std.ascii.isDigit(source[offset + 1]);
}

fn exponent_end(source: []const u8, start: u32) ?u32 {
    assert(start <= source.len);

    if (start >= source.len) return null;

    if (source[start] != 'e') {
        if (source[start] != 'E') return null;
    }

    const negative = start + 1 < source.len and source[start + 1] == '-';
    var offset = start + 1 + @intFromBool(negative);
    if (offset >= source.len) return null;
    if (!std.ascii.isDigit(source[offset])) return null;

    while (offset < source.len) : (offset += 1) {
        if (!std.ascii.isDigit(source[offset])) break;
    }

    assert(offset > start);
    assert(offset <= source.len);

    return offset;
}

pub fn unit_end(source: []const u8, start: u32) ?u32 {
    assert(start <= source.len);

    var offset = start;

    while (offset < source.len) : (offset += 1) {
        if (!is_unit_byte(source[offset])) break;
    }

    if (offset == start) return null;

    if (plain_value_end(source, start)) |reach| {
        if (reach > offset) return null;
    }

    assert(offset > start);

    return offset;
}

pub fn hex_end(source: []const u8, start: u32) ?u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(start < std.math.maxInt(u32));

    const stop: u32 = @intCast(@min(start +| hex_width_max, source.len));
    var offset = start;

    while (offset < stop) : (offset += 1) {
        if (!std.ascii.isHex(source[offset])) break;
    }

    if (offset < start + hex_width_min) return null;

    assert(offset - start >= hex_width_min);
    assert(offset - start <= hex_width_max);

    return offset;
}

test "a plain value stops at a delimiter and swallows a slash" {
    try std.testing.expectEqual(3, plain_value_end("red;", 0));
    try std.testing.expectEqual(5, plain_value_end("a.png)", 0));
    try std.testing.expectEqual(6, plain_value_end("px/1.5 x", 0));
    try std.testing.expectEqual(13, plain_value_end("//x.com/a.png)", 0));
    try std.testing.expectEqual(null, plain_value_end("/* note */", 0));
    try std.testing.expectEqual(null, plain_value_end("100%", 0));
    try std.testing.expectEqual(20, plain_value_end("startColorstr='#fff')", 0));
}

test "an identifier runs over its name bytes" {
    try std.testing.expectEqual(9, identifier_end("-webkit-x(", 0));
    try std.testing.expectEqual(5, identifier_end("--gap)", 0));
    try std.testing.expectEqual(null, identifier_end("1px", 0));
}

test "a number splits from its unit unless a plain value is longer" {
    try std.testing.expectEqual(Number{ .kind = .number, .reach = 2 }, number_end("10px", 0));
    try std.testing.expectEqual(4, unit_end("10px", 2));
    try std.testing.expectEqual(Number{ .kind = .float, .reach = 3 }, number_end("1.5em", 0));
    try std.testing.expectEqual(5, unit_end("1.5em", 3));
    try std.testing.expectEqual(Number{ .kind = .number, .reach = 3 }, number_end("-50%", 0));
    try std.testing.expectEqual(4, unit_end("-50%", 3));
    try std.testing.expectEqual(Number{ .kind = .number, .reach = 2 }, number_end("12px/1.5", 0));
    try std.testing.expectEqual(null, unit_end("12px/1.5", 2));
    try std.testing.expectEqual(Number{ .kind = .float, .reach = 2 }, number_end(".5;", 0));
    try std.testing.expectEqual(Number{ .kind = .float, .reach = 3 }, number_end("1e5;", 0));
    try std.testing.expectEqual(null, number_end("px", 0));
}

test "a colour takes three to eight hexadecimal digits" {
    try std.testing.expectEqual(3, hex_end("fff;", 0));
    try std.testing.expectEqual(8, hex_end("aabbccdd;", 0));
    try std.testing.expectEqual(8, hex_end("aabbccddee;", 0));
    try std.testing.expectEqual(null, hex_end("ff;", 0));
}

test "an escape takes its digits or its one byte" {
    try std.testing.expectEqual(4, escape_end("\\41 y", 0));
    try std.testing.expectEqual(2, escape_end("\\:e", 0));
    try std.testing.expectEqual(1, escape_end("\\", 0));
}
