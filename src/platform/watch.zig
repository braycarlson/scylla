const std = @import("std");
const assert = std.debug.assert;
const bounded = @import("../stdx/bounded.zig");
const path = @import("path.zig");
const path_platform = @import("path/platform.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

pub const Stamps = struct {
    held: bounded.ArrayType(?path.Stat),

    pub const CapacityError = error{Overflow};
    pub const Change = enum { changed, unchanged };

    pub fn init(gpa: std.mem.Allocator, stamp_count_max: u32) std.mem.Allocator.Error!Stamps {
        assert(stamp_count_max > 0);

        const held = try bounded.ArrayType(?path.Stat).init(gpa, stamp_count_max);

        assert(held.capacity() == stamp_count_max);

        return .{ .held = held };
    }

    pub fn deinit(stamps: *Stamps, gpa: std.mem.Allocator) void {
        stamps.held.deinit(gpa);
        stamps.* = undefined;
    }

    pub fn capacity(stamps: *const Stamps) u32 {
        return stamps.held.capacity();
    }

    pub fn clear(stamps: *Stamps) void {
        stamps.held.clear();
        assert(stamps.held.empty());
    }

    pub fn count(stamps: *const Stamps) u32 {
        const stamp_count = stamps.held.count();

        assert(stamp_count <= stamps.held.capacity());

        return stamp_count;
    }

    pub fn record(stamps: *Stamps, index: u32, stamp: ?path.Stat) CapacityError!Change {
        if (stamp) |held| assert(held.nanoseconds >= 0);
        if (stamp) |held| assert(held.nanoseconds < std.time.ns_per_s);
        if (index >= stamps.held.capacity()) return error.Overflow;

        for (0..stamps.held.capacity()) |_| {
            if (stamps.held.count() > index) break;

            stamps.held.push(null);
        }

        assert(index < stamps.held.count());

        const slot = &stamps.held.slice()[index];
        const previous = slot.*;

        slot.* = stamp;

        if (std.meta.eql(previous, stamp)) return .unchanged;
        return .changed;
    }

    fn record_path(
        stamps: *Stamps,
        io: std.Io,
        index: u32,
        held: []const u8,
    ) CapacityError!Change {
        assert(held.len > 0);
        assert(index < std.math.maxInt(u32));

        return stamps.record(index, path.stat_of(io, held));
    }
};

const poll_milliseconds: u32 = 200;

pub fn rest(io: std.Io) std.Io.Cancelable!void {
    comptime assert(poll_milliseconds > 0);

    try io.sleep(.fromMilliseconds(poll_milliseconds), .awake);
}

fn stamp_in(io: std.Io, root: []const u8, name: []const u8) ?path.Stat {
    if (root.len == 0) return null;
    assert(name.len <= std.math.maxInt(u32));

    var buffer: [path_platform.path_bytes_max]u8 = undefined;
    const length = path.join(&buffer, .{ .base = root, .relative = name }) catch return null;

    assert(length <= buffer.len);
    assert(length > 0);

    return path.stat_of(io, buffer[0..length]);
}

test Stamps {
    const io = std.testing.io;
    var stamps: Stamps = try .init(std.testing.allocator, 4);
    defer stamps.deinit(std.testing.allocator);

    const stamp = path.stat_of(io, "build.zig");

    try expectEqual(4, stamps.capacity());
    try expectEqual(.changed, try stamps.record(0, stamp));
    try expectEqual(.unchanged, try stamps.record(0, stamp));
    try expectEqual(.changed, try stamps.record(0, null));
    try expectError(error.Overflow, stamps.record(4, stamp));
}

test rest {
    try rest(std.Io.failing);
}

test "a first look is a change" {
    const io = std.testing.io;
    var stamps = try Stamps.init(std.testing.allocator, 4);
    defer stamps.deinit(std.testing.allocator);

    const stamp = path.stat_of(io, "build.zig");

    try expect(stamp != null);
    try expectEqual(.changed, try stamps.record(2, stamp));
    try expectEqual(3, stamps.count());
    try expectEqual(.unchanged, try stamps.record(2, stamp));
    try expectEqual(.changed, try stamps.record(0, stamp));
    try expectEqual(.unchanged, try stamps.record_path(io, 2, "build.zig"));
}

test "a slot past the reservation records nothing" {
    const io = std.testing.io;
    var stamps = try Stamps.init(std.testing.allocator, 2);
    defer stamps.deinit(std.testing.allocator);

    try expectError(error.Overflow, stamps.record(2, path.stat_of(io, "build.zig")));
    try expectEqual(0, stamps.count());
}

test "a missing path has no stamp" {
    const io = std.testing.io;

    try expect(path.stat_of(io, "/nonexistent/scylla") == null);
    try expect(stamp_in(io, "", "build.zig") == null);
    try expect(stamp_in(io, "/nonexistent", "build.zig") == null);
    try expect(stamp_in(io, ".", "build.zig") != null);
}

test "a cleared table forgets every stamp" {
    const io = std.testing.io;
    var stamps = try Stamps.init(std.testing.allocator, 2);
    defer stamps.deinit(std.testing.allocator);

    const stamp = path.stat_of(io, "build.zig");

    try expectEqual(.changed, try stamps.record(0, stamp));

    stamps.clear();

    try expectEqual(0, stamps.count());
    try expectEqual(.changed, try stamps.record(0, stamp));
}
