const std = @import("std");
const assert = std.debug.assert;
const PRNG = @import("../../testing/prng.zig");
const StaticAllocator = @import("../static_allocator.zig");

pub fn FixedMapType(comptime Value: type) type {
    return struct {
        slots: []?Entry,
        entry_count: u32,
        entry_count_max: u32,

        const Entry = struct {
            key: []const u8,
            value: Value,
        };

        const FixedMap = @This();
        pub const CapacityError = error{Overflow};
        pub const Error = CapacityError || InputError;
        pub const InputError = error{Duplicate};

        pub fn init(gpa: std.mem.Allocator, entry_count_max: u32) std.mem.Allocator.Error!FixedMap {
            assert(entry_count_max > 0);
            assert(entry_count_max <= std.math.maxInt(u32) / 2);

            const slot_count = std.math.ceilPowerOfTwoAssert(u32, entry_count_max * 2);
            const slots = try gpa.alloc(?Entry, slot_count);

            @memset(slots, null);

            assert(slots.len >= entry_count_max * 2);
            assert(std.math.isPowerOfTwo(slots.len));

            return .{ .slots = slots, .entry_count = 0, .entry_count_max = entry_count_max };
        }

        pub fn deinit(map: *FixedMap, gpa: std.mem.Allocator) void {
            assert(map.entry_count <= map.entry_count_max);
            assert(std.math.isPowerOfTwo(map.slots.len));

            gpa.free(map.slots);
            map.* = undefined;
        }

        pub fn clear(map: *FixedMap) void {
            assert(map.entry_count <= map.entry_count_max);

            @memset(map.slots, null);
            map.entry_count = 0;

            assert(map.count() == 0);
        }

        pub fn count(map: *const FixedMap) u32 {
            assert(map.entry_count <= map.entry_count_max);
            assert(map.entry_count_max * 2 <= map.slots.len);

            return map.entry_count;
        }

        pub fn get(map: *const FixedMap, key: []const u8) ?Value {
            assert(key.len > 0);
            assert(key.len <= key_bytes_max);
            assert(map.entry_count < map.slots.len);

            var index = map.index_of(key);

            for (0..map.slots.len) |_| {
                const entry = map.slots[index] orelse return null;
                if (std.mem.eql(u8, entry.key, key)) return entry.value;

                index = map.index_next(index);
            }

            unreachable;
        }

        pub fn insert(map: *FixedMap, key: []const u8, value: Value) Error!void {
            assert(key.len > 0);
            assert(key.len <= key_bytes_max);
            assert(map.entry_count < map.slots.len);

            if (map.entry_count == map.entry_count_max) return error.Overflow;

            var index = map.index_of(key);

            for (0..map.slots.len) |_| {
                const held = map.slots[index] orelse {
                    map.slots[index] = .{ .key = key, .value = value };
                    map.entry_count += 1;

                    assert(map.entry_count <= map.entry_count_max);

                    return;
                };

                if (std.mem.eql(u8, held.key, key)) return error.Duplicate;

                index = map.index_next(index);
            }

            unreachable;
        }

        fn index_next(map: *const FixedMap, index: usize) usize {
            assert(index < map.slots.len);
            assert(std.math.isPowerOfTwo(map.slots.len));

            const successor = (index + 1) & (map.slots.len - 1);

            assert(successor < map.slots.len);

            return successor;
        }

        fn index_of(map: *const FixedMap, key: []const u8) usize {
            assert(key.len > 0);
            assert(std.math.isPowerOfTwo(map.slots.len));

            const mask: u64 = map.slots.len - 1;
            const index: usize = @intCast(std.hash.Fnv1a_64.hash(key) & mask);

            assert(index < map.slots.len);

            return index;
        }
    };
}

const key_bytes_max = 256;

test "lookup finds each registered key" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var map: FixedMapType(u32) = try .init(static_allocator.allocator(), 4);
    defer map.deinit(static_allocator.allocator());

    try map.insert("rs", 0);
    try map.insert("zig", 1);
    try map.insert("py", 2);

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    try std.testing.expectEqual(0, map.get("rs"));
    try std.testing.expectEqual(1, map.get("zig"));
    try std.testing.expectEqual(2, map.get("py"));
    try std.testing.expectEqual(null, map.get("go"));
    try std.testing.expectEqual(3, map.count());
}

test "insert refuses a duplicate key" {
    var map: FixedMapType(u32) = try .init(std.testing.allocator, 4);
    defer map.deinit(std.testing.allocator);

    try map.insert("rs", 0);

    const inserted = map.insert("rs", 1);

    try std.testing.expectError(error.Duplicate, inserted);
    try std.testing.expectEqual(0, map.get("rs"));
    try std.testing.expectEqual(1, map.count());
}

test "insert refuses past the registered count" {
    var map: FixedMapType(u32) = try .init(std.testing.allocator, 2);
    defer map.deinit(std.testing.allocator);

    try map.insert("rs", 0);
    try map.insert("zig", 1);

    const inserted = map.insert("py", 2);

    try std.testing.expectError(error.Overflow, inserted);
    try std.testing.expectEqual(2, map.count());
}

test "collisions resolve by probing" {
    const keys = [_][]const u8{
        "alpha",
        "beta",
        "gamma",
        "delta",
        "epsilon",
        "zeta",
        "eta",
        "theta",
    };

    var map: FixedMapType(u32) = try .init(std.testing.allocator, 8);
    defer map.deinit(std.testing.allocator);

    for (keys, 0..) |key, value| {
        try map.insert(key, @intCast(value));
    }

    var prng: PRNG = .init(0x9E37_79B9_7F4A_7C15);

    for (0..1_024) |_| {
        const index = prng.index(keys.len);

        try std.testing.expectEqual(@as(u32, @intCast(index)), map.get(keys[index]).?);
    }
}
