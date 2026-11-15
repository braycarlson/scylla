const std = @import("std");
const assert = std.debug.assert;
const Pool = @import("pool.zig");

const Immediate = struct {
    pub fn drain(immediate: *Immediate) bool {
        assert(@TypeOf(immediate.*) == Immediate);

        return true;
    }
};

pub const item_count_serial_max: u32 = 256;
pub const stack_reserve_bytes: usize = 1 << 26;

pub fn striped(
    pool: *Pool,
    comptime T: type,
    values: []T,
    serial_max: u32,
    context: anytype,
    comptime build: fn (@TypeOf(context), u32) T,
) void {
    assert(values.len <= std.math.maxInt(u32));
    assert(pool.count() > 0);
    comptime assert(@TypeOf(context) == void or @typeInfo(@TypeOf(context)) == .pointer);

    const Task = TaskType(T, @TypeOf(context), build);
    const task: Task = .{ .context = context, .values = values };
    const item_count: u32 = @intCast(values.len);
    if (item_count <= serial_max) return task.serial();

    pool.run(Task, &task, item_count) catch |err| switch (err) {
        error.Poisoned => unreachable,
    };
}

pub fn striped_into(
    pool: *Pool,
    comptime T: type,
    values: []T,
    context: anytype,
    comptime build: fn (@TypeOf(context), u32) T,
    sink: anytype,
) void {
    assert(values.len <= std.math.maxInt(u32));
    assert(pool.stack_bytes >= stack_reserve_bytes);
    comptime assert(@TypeOf(context) == void or @typeInfo(@TypeOf(context)) == .pointer);
    comptime assert(@hasDecl(@TypeOf(sink), "take"));

    const Task = TaskType(T, @TypeOf(context), build);
    const task: Task = .{ .context = context, .values = values };
    const item_count: u32 = @intCast(values.len);
    var immediate: Immediate = .{};

    pool.run_reporting(Task, Immediate, &task, &immediate, item_count) catch |err| switch (err) {
        error.Poisoned => unreachable,
    };

    for (values) |value| sink.take(value);
}

fn TaskType(comptime T: type, comptime Context: type, comptime build: fn (Context, u32) T) type {
    return struct {
        context: Context,
        values: []T,

        const Task = @This();

        pub fn run(task: *const Task, index: u32) Pool.JobError!void {
            assert(index < task.values.len);
            assert(task.values.len <= std.math.maxInt(u32));

            task.values[index] = build(task.context, index);
        }

        fn serial(task: *const Task) void {
            assert(task.values.len <= std.math.maxInt(u32));

            for (task.values, 0..) |*value, index| value.* = build(task.context, @intCast(index));
        }
    };
}

const Identity = struct {
    fn index_of(context: void, index: u32) u32 {
        assert(@TypeOf(context) == void);

        return index;
    }
};

fn test_started(pool: *Pool, stack_bytes: usize) !void {
    assert(stack_bytes < std.math.maxInt(u32));

    try pool.init(std.testing.io, .{ .stack_bytes = stack_bytes, .worker_count = 3 });

    assert(pool.count() == 3);
    assert(pool.stack_bytes == stack_bytes);
}

test "an empty count builds nothing" {
    var pool: Pool = undefined;

    try test_started(&pool, Pool.stack_bytes_default);
    defer pool.deinit();

    const values: []u32 = &.{};

    striped(&pool, u32, values, item_count_serial_max, {}, Identity.index_of);
    try std.testing.expectEqual(@as(usize, 0), values.len);
}

test "a small count stays serial and ordered" {
    var pool: Pool = undefined;

    try test_started(&pool, Pool.stack_bytes_default);
    defer pool.deinit();

    const values = try std.testing.allocator.alloc(u32, item_count_serial_max);
    defer std.testing.allocator.free(values);

    striped(&pool, u32, values, item_count_serial_max, {}, Identity.index_of);
    try std.testing.expectEqual(item_count_serial_max, @as(u32, @intCast(values.len)));

    for (values, 0..) |held, at| try std.testing.expectEqual(@as(u32, @intCast(at)), held);
}

test "a sink takes every value a deep stack built" {
    const Pair = struct { u32, u32 };

    const Build = struct {
        fn pair_of(context: void, index: u32) Pair {
            assert(@TypeOf(context) == void);
            assert(index < std.math.maxInt(u32));

            return .{ index, index * 2 };
        }
    };

    const Sink = struct {
        seen: *std.ArrayList(Pair),

        pub fn take(sink: @This(), pair: Pair) void {
            assert(sink.seen.items.len < sink.seen.capacity);
            assert(pair[1] == pair[0] * 2);

            sink.seen.appendAssumeCapacity(pair);
        }
    };

    var pool: Pool = undefined;

    try test_started(&pool, stack_reserve_bytes);
    defer pool.deinit();

    const item_count = item_count_serial_max * 4 + 1;
    const values = try std.testing.allocator.alloc(Pair, item_count);
    defer std.testing.allocator.free(values);

    var seen: std.ArrayList(Pair) = .empty;
    defer seen.deinit(std.testing.allocator);

    try seen.ensureTotalCapacity(std.testing.allocator, item_count);
    striped_into(&pool, Pair, values, {}, Build.pair_of, Sink{ .seen = &seen });
    try std.testing.expectEqual(item_count, @as(u32, @intCast(seen.items.len)));

    for (seen.items, 0..) |held, at| {
        const position: u32 = @intCast(at);

        try std.testing.expectEqual(position, held[0]);
        try std.testing.expectEqual(position * 2, held[1]);
    }
}

test "a large count stripes and weaves in order" {
    const Build = struct {
        fn tripled(context: void, index: u32) u64 {
            assert(@TypeOf(context) == void);

            return @as(u64, index) * 3;
        }
    };

    var pool: Pool = undefined;

    try test_started(&pool, Pool.stack_bytes_default);
    defer pool.deinit();

    const item_count = item_count_serial_max * 8 + 3;
    const values = try std.testing.allocator.alloc(u64, item_count);
    defer std.testing.allocator.free(values);

    striped(&pool, u64, values, item_count_serial_max, {}, Build.tripled);
    try std.testing.expectEqual(item_count, @as(u32, @intCast(values.len)));

    for (values, 0..) |held, at| try std.testing.expectEqual(@as(u64, at) * 3, held);
}

test "a serial threshold of zero stripes a small count in order" {
    const Build = struct {
        fn successor(context: void, index: u32) u32 {
            assert(@TypeOf(context) == void);
            assert(index < std.math.maxInt(u32));

            return index + 1;
        }
    };

    var pool: Pool = undefined;

    try test_started(&pool, Pool.stack_bytes_default);
    defer pool.deinit();

    var values: [8]u32 = undefined;

    striped(&pool, u32, &values, 0, {}, Build.successor);
    try std.testing.expectEqual(@as(usize, 8), values.len);

    for (values, 0..) |held, at| try std.testing.expectEqual(@as(u32, @intCast(at)) + 1, held);
}
