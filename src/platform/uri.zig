const std = @import("std");
const assert = std.debug.assert;
const Buffer = @import("../stdx/bounded/buffer.zig");
pub const CapacityError = error{Overflow};
pub const Error = CapacityError || SyntaxError;
pub const SyntaxError = error{SchemeNotFile};
const authority_mark = "://";
const escape_bytes: u32 = 3;
const hex_base: u8 = 16;
const hex_digits = "0123456789ABCDEF";
const hex_letter: u8 = 10;
const localhost = "localhost";
const nibble_mask: u8 = 0x0F;
const nibble_shift: u3 = 4;
const out_capacity: u32 = 1 << 10;
const scheme = "file://";
const unreserved_marks = "/-._~:";

comptime {
    assert(hex_digits.len == hex_base);
    assert(hex_base == @as(u16, nibble_mask) + 1);
}

pub fn bytes_max(path_bytes_max: u32) u32 {
    assert(path_bytes_max > 0);

    const bytes: u32 = @as(u32, scheme.len) + 1 + path_bytes_max * escape_bytes;

    assert(bytes > path_bytes_max);

    return bytes;
}

pub fn decode(target: *Buffer, uri: []const u8) Error!void {
    assert(uri.len <= std.math.maxInt(u32));

    target.clear();

    const body = body_of(uri) orelse return error.SchemeNotFile;

    assert(body.len <= uri.len);

    try decoded(target, body);

    if (is_drive_rooted(target.const_slice())) {
        const length = target.count();

        target.splice(.between(0, 1), "") catch unreachable;

        assert(target.count() + 1 == length);
    }

    assert(target.count() <= body.len);
}

pub fn encode(target: *Buffer, path: []const u8) CapacityError!void {
    assert(path.len <= std.math.maxInt(u32));

    target.clear();

    try target.push(scheme);

    const rooted = std.mem.startsWith(u8, path, "/");

    if (!rooted) try target.push_byte('/');

    try encoded(target, path);

    assert(std.mem.startsWith(u8, target.const_slice(), scheme));
    assert(target.count() >= scheme.len + path.len);
}

fn decoded(target: *Buffer, text: []const u8) CapacityError!void {
    assert(text.len <= std.math.maxInt(u32));

    const written_before = target.count();
    var index: usize = 0;

    while (index < text.len) {
        const escaped = escape_at(text, index);

        if (escaped) |byte| {
            try target.push_byte(byte);
            index += 3;

            continue;
        }

        try target.push_byte(text[index]);
        index += 1;
    }

    assert(index == text.len);
    assert(target.count() - written_before <= text.len);
}

fn encoded(target: *Buffer, path: []const u8) CapacityError!void {
    assert(path.len <= std.math.maxInt(u32));

    const written_before = target.count();

    for (path) |byte| {
        const held: u8 = if (byte == '\\') '/' else byte;

        if (is_unreserved(held)) {
            try target.push_byte(held);

            continue;
        }

        const high = hex_digits[held >> nibble_shift];
        const low = hex_digits[held & nibble_mask];

        try target.push(&.{ '%', high, low });
    }

    assert(target.count() - written_before >= path.len);
    assert(target.count() - written_before <= path.len * escape_bytes);
}

fn is_unreserved(byte: u8) bool {
    if (std.ascii.isAlphanumeric(byte)) return true;
    return std.mem.findScalar(u8, unreserved_marks, byte) != null;
}

fn escape_at(text: []const u8, index: usize) ?u8 {
    assert(index < text.len);

    if (text[index] != '%') return null;
    if (index + 2 >= text.len) return null;

    const high = nibble_of(text[index + 1]) orelse return null;
    const low = nibble_of(text[index + 2]) orelse return null;

    assert(high < hex_base);
    assert(low < hex_base);

    return high * hex_base + low;
}

fn body_of(uri: []const u8) ?[]const u8 {
    assert(uri.len <= std.math.maxInt(u32));

    if (!std.mem.startsWith(u8, uri, scheme)) {
        if (std.mem.find(u8, uri, authority_mark) != null) return null;
        return uri;
    }

    const rest = uri[scheme.len..];

    assert(rest.len + scheme.len == uri.len);

    if (std.mem.startsWith(u8, rest, localhost)) {
        const path = rest[localhost.len..];
        if (std.mem.startsWith(u8, path, "/")) return path;
    }

    return rest;
}

fn is_drive_rooted(path: []const u8) bool {
    if (path.len < 3) return false;
    if (path[0] != '/') return false;
    if (!std.ascii.isAlphabetic(path[1])) return false;

    assert(path.len >= 3);

    return path[2] == ':' or path[2] == '|';
}

fn nibble_of(byte: u8) ?u8 {
    if (!std.ascii.isHex(byte)) return null;

    const nibble: ?u8 = switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + hex_letter,
        'A'...'F' => byte - 'A' + hex_letter,
        else => null,
    };

    if (nibble) |value| assert(value < hex_base);

    return nibble;
}

fn decode_expect(target: *Buffer, uri: []const u8, expected: []const u8) !void {
    assert(uri.len <= std.math.maxInt(u32));

    try decode(target, uri);
    try std.testing.expectEqualStrings(expected, target.const_slice());
}

fn encode_expect(target: *Buffer, path: []const u8, expected: []const u8) !void {
    assert(path.len <= std.math.maxInt(u32));

    try encode(target, path);
    try std.testing.expectEqualStrings(expected, target.const_slice());
}

test decode {
    var target = try Buffer.init(std.testing.allocator, out_capacity);
    defer target.deinit(std.testing.allocator);

    try decode(&target, "file:///home/one%20two/page.html");
    try std.testing.expectEqualStrings("/home/one two/page.html", target.const_slice());
    try std.testing.expectError(error.SchemeNotFile, decode(&target, "http://example.com/a"));
}

test encode {
    const spaces: [out_capacity]u8 = @splat(' ');
    var target = try Buffer.init(std.testing.allocator, out_capacity);
    defer target.deinit(std.testing.allocator);

    try encode(&target, "/home/one two/page.html");
    try std.testing.expectEqualStrings("file:///home/one%20two/page.html", target.const_slice());
    try std.testing.expectError(error.Overflow, encode(&target, &spaces));
}

test "a uri reads back as its path" {
    var target = try Buffer.init(std.testing.allocator, out_capacity);
    defer target.deinit(std.testing.allocator);

    try decode_expect(&target, "file:///home/one/page.html", "/home/one/page.html");
    try decode_expect(&target, "file://localhost/home/one/page.html", "/home/one/page.html");
    try decode_expect(&target, "file://localhostile/page.html", "localhostile/page.html");
    try decode_expect(&target, "file:///home/one%20two/a%2Eb%2ec.html", "/home/one two/a.b.c.html");
    try decode_expect(&target, "/tmp/a.rs", "/tmp/a.rs");
}

test "an escape that is not two digits is left alone" {
    var target = try Buffer.init(std.testing.allocator, out_capacity);
    defer target.deinit(std.testing.allocator);

    try decode_expect(&target, "file:///tmp/100%.rs", "/tmp/100%.rs");
    try decode_expect(&target, "file:///tmp/%zz.rs", "/tmp/%zz.rs");
    try decode_expect(&target, "file:///tmp/a%2", "/tmp/a%2");
}

test "a windows drive loses the uris own slash" {
    var target = try Buffer.init(std.testing.allocator, out_capacity);
    defer target.deinit(std.testing.allocator);

    try decode_expect(&target, "file:///C:/one/page.html", "C:/one/page.html");
    try decode_expect(&target, "file:///c%3a/code/a.rs", "c:/code/a.rs");
    try decode_expect(&target, "file:///C|/code/a.rs", "C|/code/a.rs");
}

test "another scheme names no file" {
    var target = try Buffer.init(std.testing.allocator, out_capacity);
    defer target.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.SchemeNotFile,
        decode(&target, "http://example.com/page.html"),
    );

    try std.testing.expectError(error.SchemeNotFile, decode(&target, "untitled://a"));
}

test "a path writes back as a uri" {
    var target = try Buffer.init(std.testing.allocator, out_capacity);
    defer target.deinit(std.testing.allocator);

    try encode_expect(&target, "/home/one/page.html", "file:///home/one/page.html");
    try encode_expect(&target, "/home/one two/page.html", "file:///home/one%20two/page.html");
    try encode_expect(&target, "C:\\one\\page.html", "file:///C:/one/page.html");
}

test "every path survives the round trip" {
    var uri = try Buffer.init(std.testing.allocator, out_capacity);
    defer uri.deinit(std.testing.allocator);

    var path = try Buffer.init(std.testing.allocator, out_capacity);
    defer path.deinit(std.testing.allocator);

    const paths = [_][]const u8{
        "/home/one/page.html",
        "/home/one two/page.html",
        "/home/one+two/page.html",
        "/home/one%two/page.html",
        "C:/one/page.html",
    };

    for (paths) |held| {
        try encode(&uri, held);
        try decode(&path, uri.const_slice());
        try std.testing.expectEqualStrings(held, path.const_slice());
    }
}

test "the longest escaped path fits the uri bytes" {
    var target = try Buffer.init(std.testing.allocator, bytes_max(4));
    defer target.deinit(std.testing.allocator);

    try encode(&target, "    ");
    try std.testing.expectEqual(bytes_max(4), target.count());
}

test "a path that outgrows the buffer is refused" {
    var target = try Buffer.init(std.testing.allocator, 8);
    defer target.deinit(std.testing.allocator);

    try std.testing.expectError(error.Overflow, decode(&target, "file:///home/one/page.html"));
    try std.testing.expectError(error.Overflow, encode(&target, "/a"));
    try encode(&target, "");
    try std.testing.expectEqualStrings("file:///", target.const_slice());
}
