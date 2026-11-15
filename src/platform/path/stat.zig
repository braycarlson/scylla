const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const path_platform = @import("platform.zig");

pub const Stat = struct {
    mode: u32,
    nanoseconds: i64,
    seconds: i64,
    size: u64,
};

const native = path_platform.PathType(path_platform.platform_native);
const nanoseconds_per_second: i96 = std.time.ns_per_s;

pub fn stat_of(io: std.Io, bytes: []const u8) ?Stat {
    assert(bytes.len <= std.math.maxInt(u32));

    const held = native.path_of(bytes) orelse return null;

    assert(held.len == bytes.len);

    const stat = std.Io.Dir.cwd().statFile(io, held, .{}) catch return null;
    const modified = stat.mtime.nanoseconds;
    const seconds = @divFloor(modified, nanoseconds_per_second);
    const nanoseconds = @mod(modified, nanoseconds_per_second);

    assert(nanoseconds >= 0);
    assert(nanoseconds < nanoseconds_per_second);

    return .{
        .mode = mode_of(stat.permissions),
        .nanoseconds = @intCast(nanoseconds),
        .seconds = std.math.cast(i64, seconds) orelse 0,
        .size = stat.size,
    };
}

fn mode_of(permissions: std.Io.File.Permissions) u32 {
    const mode: u32 = switch (builtin.target.os.tag) {
        .windows => @backingInt(permissions) & 1,
        else => @intCast(permissions.toMode()),
    };

    assert(mode <= std.math.maxInt(u16));

    return mode;
}

test stat_of {
    const io = std.testing.io;
    const build = stat_of(io, "build.zig") orelse return error.TestUnexpectedResult;

    try std.testing.expect(build.size > 0);
    try std.testing.expect(build.seconds > 1_600_000_000);
    try std.testing.expect(build.nanoseconds < std.time.ns_per_s);
    try std.testing.expect(stat_of(io, "/nonexistent/scylla") == null);
}
