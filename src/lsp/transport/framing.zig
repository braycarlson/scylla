const std = @import("std");
const assert = std.debug.assert;
pub const header_bytes_max: u32 = 256;
pub const header_count_max: u32 = 16;
const content_length = "content-length";
const decimal_bytes_max: u32 = 20;

pub fn content_length_of(line: []const u8) ?u32 {
    assert(line.len <= std.math.maxInt(u32));

    const colon = std.mem.findScalar(u8, line, ':') orelse return null;
    const name = std.mem.trim(u8, line[0..colon], std.ascii.whitespace[0..]);
    if (name.len != content_length.len) return null;
    if (!std.ascii.eqlIgnoreCase(name, content_length)) return null;

    const value = std.mem.trim(u8, line[colon + 1 ..], std.ascii.whitespace[0..]);
    const read_value = decimal_read(value) orelse return null;

    return std.math.cast(u32, read_value);
}

fn decimal_read(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    if (text.len > decimal_bytes_max) return null;

    var value: u64 = 0;

    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) return null;

        value = std.math.mul(u64, value, 10) catch return null;
        value = std.math.add(u64, value, byte - '0') catch return null;
    }

    assert(text.len <= decimal_bytes_max);

    return value;
}

pub fn framed(out: *std.Io.Writer, message: []const u8) std.Io.Writer.Error!void {
    assert(message.len <= std.math.maxInt(u32));

    var header: [header_bytes_max]u8 = undefined;
    const written = header_write(&header, message.len);

    assert(written <= header_bytes_max);

    try out.writeAll(header[0..written]);
    try out.writeAll(message);
    try out.flush();
}

pub fn header_write(header: *[header_bytes_max]u8, length: u64) u32 {
    const prefix = "Content-Length: ";
    const suffix = "\r\n\r\n";

    comptime assert(prefix.len + decimal_bytes_max + suffix.len <= header_bytes_max);

    const written = std.mem.print(header, prefix ++ "{d}" ++ suffix, .{length}) catch unreachable;

    assert(written.len > prefix.len + suffix.len);
    assert(written.len <= header_bytes_max);

    if (length <= std.math.maxInt(u32)) {
        assert(content_length_of(written[0 .. written.len - suffix.len]).? == length);
    }

    return @intCast(written.len);
}

test "a header carries the length" {
    var header: [header_bytes_max]u8 = undefined;
    const long = header_write(&header, 4_096);

    try std.testing.expectEqualStrings("Content-Length: 4096\r\n\r\n", header[0..long]);

    const short = header_write(&header, 0);

    try std.testing.expectEqualStrings("Content-Length: 0\r\n\r\n", header[0..short]);
}

test "a length header parses case insensitively" {
    const none: ?u32 = null;

    try std.testing.expectEqual(@as(?u32, 42), content_length_of("Content-Length: 42"));
    try std.testing.expectEqual(@as(?u32, 42), content_length_of("content-length:42"));
    try std.testing.expectEqual(none, content_length_of("Content-Type: application/json"));
    try std.testing.expectEqual(none, content_length_of("Content-Length: "));
    try std.testing.expectEqual(none, content_length_of("Content-Length: 4a2"));
    try std.testing.expectEqual(none, content_length_of("Content-Length: 99999999999"));
    try std.testing.expectEqual(none, content_length_of("no colon"));
}
