const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("array.zig").ArrayType;
const Random = @import("../../testing/random.zig");
const StaticAllocator = @import("../static_allocator.zig");

pub const Handle = struct {
    generation: u32,
    index: u32,
};

fn PoolType(comptime Value: type) type {
    comptime assert(@hasDecl(Value, "reset"));

    return struct {
        free: ArrayType(u32),
        slots: []Slot,

        const Slot = struct {
            generation: u32,
            occupied: bool,
            value: Value,
        };

        pub const Entry = struct {
            handle: Handle,
            value: *const Value,
        };

        pub const Iterator = struct {
            pool: *const Pool,
            index: u32,
            remaining: u32,

            pub fn next(iterator: *Iterator) ?Entry {
                const slots = iterator.pool.slots;

                assert(iterator.index <= slots.len);
                assert(iterator.remaining <= iterator.pool.count());

                if (iterator.remaining == 0) return null;

                for (slots[iterator.index..], iterator.index..) |*slot, index| {
                    if (!slot.occupied) continue;

                    iterator.index = @intCast(index + 1);
                    iterator.remaining -= 1;

                    assert(iterator.index <= slots.len);

                    return .{
                        .handle = .{ .generation = slot.generation, .index = @intCast(index) },
                        .value = &slot.value,
                    };
                }

                iterator.index = @intCast(slots.len);

                return null;
            }
        };

        const Pool = @This();

        pub fn init(
            gpa: std.mem.Allocator,
            slot_count: u32,
            context: anytype,
            comptime make: fn (@TypeOf(context), u32) Value,
        ) error{OutOfMemory}!Pool {
            comptime assert(@TypeOf(context) == void or @typeInfo(@TypeOf(context)) == .pointer);
            assert(slot_count > 0);

            var free: ArrayType(u32) = try .init(gpa, slot_count);
            errdefer free.deinit(gpa);

            const slots = try gpa.alloc(Slot, slot_count);

            for (slots, 0..) |*slot, index| {
                const position: u32 = @intCast(index);

                slot.* = .{ .generation = 0, .occupied = false, .value = make(context, position) };

                free.push(slot_count - position - 1);
            }

            assert(slots.len == slot_count);
            assert(free.full());

            return .{ .free = free, .slots = slots };
        }

        pub fn deinit(pool: *Pool, gpa: std.mem.Allocator) void {
            assert(pool.free.count() <= pool.slots.len);
            assert(pool.slots.len > 0);

            gpa.free(pool.slots);
            pool.free.deinit(gpa);
            pool.* = undefined;
        }

        pub fn acquire(pool: *Pool) ?Handle {
            assert(pool.free.count() <= pool.slots.len);

            const index = pool.free.pop() orelse return null;
            const slot = &pool.slots[index];

            assert(!slot.occupied);

            slot.occupied = true;

            const handle: Handle = .{ .generation = slot.generation, .index = index };

            assert(pool.contains(handle));

            return handle;
        }

        pub fn release(pool: *Pool, handle: Handle) void {
            assert(pool.contains(handle));

            const slot = &pool.slots[handle.index];

            slot.occupied = false;
            slot.generation +%= 1;

            slot.value.reset();
            pool.free.push(handle.index);

            assert(!pool.contains(handle));
            assert(pool.free.count() <= pool.slots.len);
        }

        pub fn capacity(pool: *const Pool) u32 {
            assert(pool.free.count() <= pool.slots.len);
            assert(pool.slots.len > 0);

            return @intCast(pool.slots.len);
        }

        pub fn contains(pool: *const Pool, handle: Handle) bool {
            assert(pool.slots.len > 0);

            if (handle.index >= pool.slots.len) return false;

            const slot = &pool.slots[handle.index];
            if (!slot.occupied) return false;
            return slot.generation == handle.generation;
        }

        pub fn count(pool: *const Pool) u32 {
            const occupied = pool.capacity() - pool.free.count();

            assert(occupied <= pool.capacity());

            return occupied;
        }

        pub fn get(pool: *const Pool, handle: Handle) *const Value {
            assert(pool.contains(handle));
            assert(handle.index < pool.slots.len);

            return &pool.slots[handle.index].value;
        }

        fn get_mutable(pool: *Pool, handle: Handle) *Value {
            assert(pool.contains(handle));
            assert(handle.index < pool.slots.len);

            return &pool.slots[handle.index].value;
        }
    };
}

const Counter = struct {
    resets: u32,
    value: u32,

    pub fn reset(counter: *Counter) void {
        counter.resets += 1;
        counter.value = 0;
    }
};

fn counter_make(context: void, index: u32) Counter {
    _ = context;
    _ = index;

    return .{ .resets = 0, .value = 0 };
}

fn pool_of(gpa: std.mem.Allocator, slot_count: u32) error{OutOfMemory}!PoolType(Counter) {
    assert(slot_count > 0);

    const pool: PoolType(Counter) = try .init(gpa, slot_count, {}, counter_make);

    assert(pool.capacity() == slot_count);

    return pool;
}

test "acquire stops at capacity" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var pool = try pool_of(static_allocator.allocator(), 2);
    defer pool.deinit(static_allocator.allocator());

    var scope = static_allocator.freeze_scope();
    defer scope.leave();

    const first = pool.acquire().?;
    const second = pool.acquire().?;

    try std.testing.expectEqual(pool.capacity(), pool.count());
    try std.testing.expectEqual(null, pool.acquire());
    try std.testing.expect(!std.meta.eql(first, second));
    try std.testing.expectEqual(2, pool.count());
}

test "release resets the slot and invalidates the handle" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var pool = try pool_of(static_allocator.allocator(), 1);
    defer pool.deinit(static_allocator.allocator());

    var scope = static_allocator.freeze_scope();
    defer scope.leave();

    const handle = pool.acquire().?;

    pool.get_mutable(handle).value = 7;

    try std.testing.expectEqual(7, pool.get(handle).value);

    pool.release(handle);

    try std.testing.expect(!pool.contains(handle));
    try std.testing.expectEqual(0, pool.count());

    const reused = pool.acquire().?;

    try std.testing.expect(!std.meta.eql(reused, handle));
    try std.testing.expectEqual(1, pool.count());
    try std.testing.expectEqual(0, pool.get(reused).value);
    try std.testing.expectEqual(1, pool.get(reused).resets);
}

test "a stale handle is rejected" {
    var pool = try pool_of(std.testing.allocator, 1);
    defer pool.deinit(std.testing.allocator);

    const handle = pool.acquire().?;

    pool.release(handle);

    try std.testing.expect(!pool.contains(handle));
}

test "churn holds the invariants" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var pool = try pool_of(static_allocator.allocator(), 8);
    defer pool.deinit(static_allocator.allocator());

    var live: ArrayType(Handle) = try .init(static_allocator.allocator(), 8);
    defer live.deinit(static_allocator.allocator());

    var random: Random = .init(0xDEAD_BEEF_CAFE_F00D);
    var scope = static_allocator.freeze_scope();
    defer scope.leave();

    for (0..4_096) |_| {
        const acquiring = random.below(2) == 0;

        if (acquiring) {
            if (pool.acquire()) |handle| live.push(handle);
        } else {
            if (live.pop()) |handle| pool.release(handle);
        }

        try std.testing.expectEqual(live.count(), pool.count());

        for (live.const_slice()) |handle| {
            try std.testing.expect(pool.contains(handle));
        }
    }
}

test "an iterator yields each occupied slot once" {
    var pool = try pool_of(std.testing.allocator, 4);
    defer pool.deinit(std.testing.allocator);

    const first = pool.acquire().?;
    const second = pool.acquire().?;
    const third = pool.acquire().?;

    pool.release(second);

    var iterator: PoolType(Counter).Iterator = .{
        .pool = &pool,
        .index = 0,
        .remaining = pool.count(),
    };

    const yielded_first = iterator.next().?;
    const yielded_second = iterator.next().?;

    try std.testing.expect(std.meta.eql(first, yielded_first.handle));
    try std.testing.expect(std.meta.eql(third, yielded_second.handle));

    const iterator_next = iterator.next();

    try std.testing.expectEqual(null, iterator_next);
    try std.testing.expectEqual(0, iterator.remaining);
}
