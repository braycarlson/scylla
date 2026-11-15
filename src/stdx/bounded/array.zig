const std = @import("std");
const assert = std.debug.assert;
const Random = @import("../../testing/random.zig");
const StaticAllocator = @import("../static_allocator.zig");

pub fn ArrayType(comptime T: type) type {
    comptime assert(@sizeOf(T) > 0);

    return struct {
        allocated: bool,
        buffer: []T,
        item_count: u32,

        const Array = @This();

        pub const Shift = struct {
            from: u32,
            to: u32,
        };

        pub fn init(gpa: std.mem.Allocator, capacity_max: u32) std.mem.Allocator.Error!Array {
            assert(capacity_max > 0);

            const buffer = try StaticAllocator.reserve(T, gpa, capacity_max);

            assert(buffer.len == capacity_max);

            return .{ .allocated = true, .buffer = buffer, .item_count = 0 };
        }

        pub fn init_storage(storage: []T) Array {
            assert(storage.len > 0);
            assert(storage.len <= std.math.maxInt(u32));

            return .{ .allocated = false, .buffer = storage, .item_count = 0 };
        }

        pub fn deinit(array: *Array, gpa: std.mem.Allocator) void {
            assert(array.allocated);
            assert(array.item_count <= array.buffer.len);
            assert(array.buffer.len > 0);

            StaticAllocator.release(T, gpa, array.buffer);
            array.* = undefined;
        }

        pub fn capacity(array: *const Array) u32 {
            assert(array.item_count <= array.buffer.len);
            assert(array.buffer.len > 0);

            return @intCast(array.buffer.len);
        }

        pub fn clear(array: *Array) void {
            assert(array.item_count <= array.buffer.len);
            assert(array.buffer.len > 0);

            array.item_count = 0;
        }

        pub fn const_slice(array: *const Array) []const T {
            assert(array.item_count <= array.buffer.len);
            assert(array.buffer.len > 0);

            return array.buffer[0..array.item_count];
        }

        pub fn count(array: *const Array) u32 {
            assert(array.item_count <= array.buffer.len);
            assert(array.buffer.len > 0);

            return array.item_count;
        }

        pub fn dedup(array: *Array, comptime Equivalence: type) void {
            comptime equivalence_check(Equivalence);

            const item_count_before = array.item_count;

            assert(item_count_before <= array.buffer.len);

            if (item_count_before == 0) return;

            var kept: u32 = 1;

            for (array.buffer[1..item_count_before]) |item| {
                if (Equivalence.same(array.buffer[kept - 1], item)) continue;

                array.buffer[kept] = item;
                kept += 1;
            }

            assert(kept <= item_count_before);

            for (array.buffer[1..kept], 0..) |item, position| {
                assert(!Equivalence.same(array.buffer[position], item));
            }

            array.item_count = kept;
        }

        fn equivalence_check(comptime Equivalence: type) void {
            const signature = "pub fn same(" ++ @typeName(T) ++ ", " ++ @typeName(T) ++ ") bool";
            const owner = @typeName(Equivalence);
            const expected = "dedup expects " ++ owner ++ " to declare " ++ signature;

            if (!@hasDecl(Equivalence, "same")) @compileError(expected);

            const same = @typeInfo(@TypeOf(Equivalence.same)).@"fn";

            if (same.param_types.len != 2) @compileError(expected);
            if ((same.param_types[0] orelse void) != T) @compileError(expected);
            if ((same.param_types[1] orelse void) != T) @compileError(expected);
            if ((same.return_type orelse void) != bool) @compileError(expected);
        }

        pub fn empty(array: *const Array) bool {
            assert(array.item_count <= array.buffer.len);
            assert(array.buffer.len > 0);

            return array.item_count == 0;
        }

        pub fn fill(array: *Array, item: T) void {
            assert(array.item_count <= array.buffer.len);
            assert(array.buffer.len > 0);

            for (array.buffer[array.item_count..]) |*slot| slot.* = item;

            array.item_count = @intCast(array.buffer.len);

            assert(array.full());
        }

        pub fn full(array: *const Array) bool {
            assert(array.item_count <= array.buffer.len);
            assert(array.buffer.len > 0);

            return array.item_count == array.buffer.len;
        }

        pub fn get(array: *const Array, index: u32) T {
            assert(index < array.item_count);
            assert(array.item_count <= array.buffer.len);

            return array.buffer[index];
        }

        pub fn pop(array: *Array) ?T {
            assert(array.item_count <= array.buffer.len);
            assert(array.buffer.len > 0);

            if (array.item_count == 0) return null;

            array.item_count -= 1;

            assert(array.item_count < array.buffer.len);

            return array.buffer[array.item_count];
        }

        pub fn push(array: *Array, item: T) void {
            assert(array.item_count < array.buffer.len);

            array.buffer[array.item_count] = item;
            array.item_count += 1;

            assert(array.item_count <= array.buffer.len);
        }

        pub fn push_slice(array: *Array, items: []const T) void {
            assert(items.len <= array.buffer.len - array.item_count);

            const start = array.item_count;

            @memcpy(array.buffer[start..][0..items.len], items);
            array.item_count += @intCast(items.len);

            assert(array.item_count <= array.buffer.len);
        }

        pub fn pushed(array: *Array, item: T) error{Overflow}!void {
            assert(array.item_count <= array.buffer.len);

            if (array.item_count == array.buffer.len) return error.Overflow;

            array.buffer[array.item_count] = item;
            array.item_count += 1;

            assert(array.item_count > 0);
        }

        pub fn shift_tail(array: *Array, shift: Shift) void {
            assert(array.item_count <= array.buffer.len);
            assert(shift.from <= array.item_count);

            const tail = array.item_count - shift.from;
            const item_count_new = shift.to + tail;

            assert(item_count_new <= array.buffer.len);

            const source = array.buffer[shift.from..][0..tail];
            const target = array.buffer[shift.to..][0..tail];

            @memmove(target, source);
            array.item_count = item_count_new;
        }

        pub fn slice(array: *Array) []T {
            assert(array.item_count <= array.buffer.len);
            assert(array.buffer.len > 0);

            return array.buffer[0..array.item_count];
        }

        pub fn truncate(array: *Array, item_count_new: u32) void {
            assert(item_count_new <= array.item_count);

            array.item_count = item_count_new;

            assert(array.count() == item_count_new);
        }

        pub fn unused_capacity(array: *const Array) u32 {
            assert(array.item_count <= array.buffer.len);
            assert(array.buffer.len > 0);

            return @intCast(array.buffer.len - array.item_count);
        }
    };
}

const SameValue = struct {
    pub fn same(first: u32, second: u32) bool {
        return first == second;
    }
};

test ArrayType {
    const gpa = std.testing.allocator;
    var array: ArrayType(u32) = try .init(gpa, 4);
    defer array.deinit(gpa);

    array.push(7);
    array.push_slice(&.{ 8, 8, 9 });
    array.dedup(SameValue);

    try std.testing.expectEqualSlices(u32, &.{ 7, 8, 9 }, array.const_slice());
    try std.testing.expectEqual(1, array.unused_capacity());

    var storage: [2]u32 = undefined;
    var lent: ArrayType(u32) = .init_storage(&storage);

    lent.push(1);
    lent.push(2);

    try std.testing.expect(lent.full());

    const lent_popped = lent.pop();

    try std.testing.expectEqual(2, lent_popped);
    try std.testing.expectEqual(1, lent.count());
}

test "push stops at capacity" {
    var array: ArrayType(u32) = try .init(std.testing.allocator, 4);
    defer array.deinit(std.testing.allocator);

    for (0..4) |value| {
        array.push(@intCast(value));
    }

    try std.testing.expect(array.full());
    try std.testing.expectEqual(4, array.count());
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3 }, array.const_slice());
}

test "push assert rejects overflow" {
    var array: ArrayType(u32) = try .init(std.testing.allocator, 1);
    defer array.deinit(std.testing.allocator);

    try std.testing.expect(!array.full());

    array.push(0);

    try std.testing.expect(array.full());
}

test "push bytes writes all or nothing" {
    var array: ArrayType(u8) = try .init(std.testing.allocator, 8);
    defer array.deinit(std.testing.allocator);

    array.push_slice("abcd");

    try std.testing.expect(array.unused_capacity() < "efghi".len);
    try std.testing.expectEqualStrings("abcd", array.const_slice());

    array.push_slice("efgh");

    try std.testing.expectEqualStrings("abcdefgh", array.const_slice());
    try std.testing.expect(array.full());
}

test "capacity holds under a frozen thread" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var array: ArrayType(u32) = try .init(static_allocator.allocator(), 64);
    defer array.deinit(static_allocator.allocator());

    var random: Random = .init(0x2545_F491_4F6C_DD1D);
    var scope = static_allocator.freeze_scope();
    defer scope.leave();

    for (0..4_096) |_| {
        switch (random.below(3)) {
            0 => {
                const value = random.below(1_000);
                const pushed = !array.full();

                if (pushed) array.push(value);

                try std.testing.expect(pushed or array.full());
            },
            1 => {
                const popped = array.pop();

                try std.testing.expect(popped != null or array.empty());
            },
            else => array.clear(),
        }

        try std.testing.expect(array.count() <= 64);
    }
}

test "a tail shifts left and right and carries its items" {
    var array: ArrayType(u32) = try .init(std.testing.allocator, 8);
    defer array.deinit(std.testing.allocator);

    array.push_slice(&.{ 0, 1, 2, 3, 4 });
    array.shift_tail(.{ .from = 3, .to = 1 });

    try std.testing.expectEqualSlices(u32, &.{ 0, 3, 4 }, array.const_slice());

    array.shift_tail(.{ .from = 1, .to = 4 });

    try std.testing.expectEqual(6, array.count());
    try std.testing.expectEqualSlices(u32, &.{ 3, 4 }, array.const_slice()[4..]);
}

test "a dedup keeps the first of each run" {
    var array: ArrayType(u32) = try .init(std.testing.allocator, 8);
    defer array.deinit(std.testing.allocator);

    array.push_slice(&.{ 1, 1, 2, 3, 3, 3, 4 });
    array.dedup(SameValue);

    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, array.const_slice());

    array.dedup(SameValue);

    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, array.const_slice());
}

test "a dedup of nothing is nothing" {
    var array: ArrayType(u32) = try .init(std.testing.allocator, 8);
    defer array.deinit(std.testing.allocator);

    array.dedup(SameValue);

    try std.testing.expectEqual(0, array.count());
}

test "a lent array holds its items in the caller's storage" {
    var storage: [3]u32 = @splat(0);
    var array: ArrayType(u32) = .init_storage(&storage);

    array.push_slice(&.{ 4, 5 });
    array.shift_tail(.{ .from = 0, .to = 1 });

    try std.testing.expectEqual(3, array.count());
    try std.testing.expectEqualSlices(u32, &.{ 4, 4, 5 }, &storage);
    try std.testing.expect(!array.allocated);
}
