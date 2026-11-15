const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const root = @import("root");

const Line = struct {
    bytes: [line_bytes_max]u8,
    length: u32,

    fn init() Line {
        var held: Line = .{ .bytes = undefined, .length = 0 };
        const installed = prefix();

        held.push(installed) catch unreachable;
        assert(held.length == installed.len);
        assert(held.length < content_bytes_max);

        return held;
    }

    fn emit(held: *Line) void {
        assert(held.length < line_bytes_max);

        held.bytes[held.length] = '\n';
        held.length += 1;

        assert(held.length <= line_bytes_max);

        if (builtin.is_test) return;

        var buffer: [64]u8 = undefined;
        const stderr = std.debug.lockStderr(&buffer);
        defer std.debug.unlockStderr();

        stderr.file_writer.interface.writeAll(held.bytes[0..held.length]) catch return;
        stderr.file_writer.interface.flush() catch return;
    }

    fn mark_truncated(held: *Line) void {
        const end: u32 = held.length + @as(u32, truncation.len);

        assert(held.length <= content_bytes_max);
        assert(end < line_bytes_max);

        @memcpy(held.bytes[held.length..end], truncation);
        held.length = end;
    }

    fn push(held: *Line, bytes: []const u8) error{Truncated}!void {
        if (bytes.len > content_bytes_max - held.length) return error.Truncated;

        const end: u32 = held.length + @as(u32, @intCast(bytes.len));

        @memcpy(held.bytes[held.length..end], bytes);
        held.length = end;

        assert(held.length <= content_bytes_max);
    }

    fn write(
        held: *Line,
        comptime format: []const u8,
        arguments: anytype,
    ) error{Truncated}!void {
        comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

        const room = held.bytes[held.length..content_bytes_max];

        const written = std.mem.print(room, format, arguments) catch |err| switch (err) {
            error.NoSpaceLeft => return error.Truncated,
        };

        assert(written.len <= room.len);
        held.length += @intCast(written.len);

        assert(held.length <= content_bytes_max);
    }
};

pub const line_bytes_max: u32 = 1_024;
const truncation = "[truncated]";
const content_bytes_max: u32 = line_bytes_max - @as(u32, truncation.len) - 1;
const prefix_installed: []const u8 = prefix_checked();

comptime {
    assert(content_bytes_max < line_bytes_max);
    assert(truncation.len < line_bytes_max);
    assert(prefix_installed.len < content_bytes_max);
}

pub fn line(comptime format: []const u8, arguments: anytype) void {
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    var held = Line.init();

    held.write(format, arguments) catch |err| switch (err) {
        error.Truncated => held.mark_truncated(),
    };

    assert(held.length < line_bytes_max);
    held.emit();
}

fn prefix() []const u8 {
    const installed = prefix_installed;

    assert(installed.len < content_bytes_max);
    assert(installed.len < line_bytes_max);

    return installed;
}

fn prefix_checked() []const u8 {
    if (!@hasDecl(root, "log_prefix")) return "";

    const Prefix = @TypeOf(root.log_prefix);

    if (!is_text(Prefix)) {
        @compileError("log_prefix in " ++ @typeName(root) ++ " is " ++ @typeName(Prefix) ++
            ", not text");
    }

    return root.log_prefix;
}

fn is_text(comptime T: type) bool {
    const info = switch (@typeInfo(T)) {
        .pointer => |pointer| pointer,
        else => return false,
    };

    if (info.size == .slice) return info.child == u8;
    if (info.size != .one) return false;

    return switch (@typeInfo(info.child)) {
        .array => |array| array.child == u8,
        else => false,
    };
}

test line {
    line("indexed {d} files", .{12});

    var held = Line.init();
    const start = held.length;

    try held.write("indexed {d} files", .{12});
    try std.testing.expectEqualStrings(prefix(), held.bytes[0..start]);
    try std.testing.expectEqualStrings("indexed 12 files", held.bytes[start..held.length]);
}

test "text is a slice or an array of bytes" {
    try std.testing.expect(comptime is_text([]const u8));
    try std.testing.expect(comptime is_text(*const [5:0]u8));
    try std.testing.expect(!comptime is_text(u32));
    try std.testing.expect(!comptime is_text([]const u16));
    try std.testing.expect(!comptime is_text(*const u8));
}

test "line holds prefix and content" {
    var held = Line.init();
    const start = held.length;

    try held.write("count {d}", .{@as(u32, 7)});
    try std.testing.expectEqualStrings("count 7", held.bytes[start..held.length]);
}

test "line refuses content past capacity" {
    var held = Line.init();
    const start = held.length;
    const overflow: [content_bytes_max + 1]u8 = @splat('x');
    const written = held.write("{s}", .{&overflow});

    try std.testing.expectError(error.Truncated, written);
    try std.testing.expectEqual(start, held.length);

    held.mark_truncated();

    try std.testing.expectEqual(start + truncation.len, held.length);
}

test "line fills to capacity without truncation" {
    var held = Line.init();
    const content: [content_bytes_max]u8 = @splat('x');

    try held.write("{s}", .{content[0 .. content_bytes_max - held.length]});
    try std.testing.expectEqual(content_bytes_max, held.length);
}
