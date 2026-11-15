const std = @import("std");
const assert = std.debug.assert;

const Failure = struct {
    index: ?u32,
    err: anyerror,
};

const thread_count_max: u32 = 64;
const item_count_max: u32 = 1 << 20;
const weight_per_thread_min: u64 = 1 << 14;

pub fn run(
    comptime Worker: type,
    gpa: std.mem.Allocator,
    shared: *const Worker.Shared,
    items: []const Worker.Item,
    tally: *Worker.Tally,
) !void {
    comptime assert(@hasDecl(Worker, "Item"));
    comptime assert(@hasDecl(Worker, "Shared"));
    comptime assert(@hasDecl(Worker, "Tally"));
    comptime assert(@hasDecl(Worker, "deinit"));
    comptime assert(@hasDecl(Worker, "init"));
    comptime assert(@hasDecl(Worker, "visit"));
    comptime assert(@hasDecl(Worker, "weight"));
    assert(items.len <= item_count_max);

    const Runner = RunnerType(Worker);

    if (items.len == 0) return;

    var weight_total: u64 = 0;

    for (items) |*item| weight_total += Worker.weight(item);

    const thread_count = thread_count_of(@intCast(items.len), weight_total);
    const order = try gpa.alloc(u32, items.len);
    defer gpa.free(order);

    Runner.plan(items, order);

    var queue: Runner.Queue = .{
        .gpa = gpa,
        .items = items,
        .next = .init(0),
        .order = order,
        .shared = shared,
    };

    var slots: [thread_count_max]Runner.Slot = undefined;
    var threads: [thread_count_max]std.Thread = undefined;
    const spawned = try Runner.spawned(&queue, thread_count, &slots, &threads);

    assert(spawned == thread_count);

    for (threads[0..spawned]) |thread| thread.join();

    const failure = Runner.merged(slots[0..spawned], tally);
    if (failure) |held| return held.err;

    assert(queue.next.load(.acquire) >= order.len);
}

fn thread_count_of(item_count: u32, weight_total: u64) u32 {
    assert(item_count > 0);
    assert(item_count <= item_count_max);

    const available: u32 = available: {
        const cpu_count = std.Thread.getCpuCount() catch break :available 1;

        break :available @intCast(@min(cpu_count, thread_count_max));
    };

    const weighted: u32 = @intCast(@min(@divFloor(weight_total, weight_per_thread_min), available));
    const thread_count = @max(1, @min(available, item_count, weighted));

    assert(thread_count >= 1);
    assert(thread_count <= thread_count_max);

    return thread_count;
}

fn RunnerType(comptime Worker: type) type {
    return struct {
        const Queue = struct {
            gpa: std.mem.Allocator,
            items: []const Worker.Item,
            next: std.atomic.Value(u32),
            order: []const u32,
            shared: *const Worker.Shared,
        };

        const Slot = struct {
            tally: Worker.Tally,
            failure: ?Failure,
        };

        fn plan(items: []const Worker.Item, order: []u32) void {
            assert(order.len == items.len);

            for (order, 0..) |*index, at| index.* = @intCast(at);

            std.mem.sort(u32, order, items, heavier);

            if (order.len > 1) {
                const heaviest = Worker.weight(&items[order[0]]);
                const lightest = Worker.weight(&items[order[order.len - 1]]);

                assert(heaviest >= lightest);
            }
        }

        fn heavier(items: []const Worker.Item, left: u32, right: u32) bool {
            assert(left < items.len);
            assert(right < items.len);

            const left_weight = Worker.weight(&items[left]);
            const right_weight = Worker.weight(&items[right]);
            if (left_weight != right_weight) return left_weight > right_weight;
            return left < right;
        }

        fn spawned(
            queue: *Queue,
            thread_count: u32,
            slots: *[thread_count_max]Slot,
            threads: *[thread_count_max]std.Thread,
        ) !u32 {
            assert(thread_count >= 1);
            assert(thread_count <= thread_count_max);

            var count: u32 = 0;
            errdefer for (threads[0..count]) |thread| thread.join();

            for (0..thread_count) |thread| {
                slots[thread] = .{ .tally = std.mem.zeroes(Worker.Tally), .failure = null };
                threads[thread] = try std.Thread.spawn(.{}, work, .{ queue, &slots[thread] });
                count += 1;
            }

            assert(count == thread_count);

            return count;
        }

        fn work(queue: *Queue, slot: *Slot) void {
            assert(slot.failure == null);
            assert(queue.order.len == queue.items.len);

            var worker: Worker = undefined;

            worker.init(queue.gpa, queue.shared) catch |err| {
                slot.failure = .{ .index = null, .err = err };

                return;
            };

            defer worker.deinit(queue.gpa);

            for (0..queue.order.len) |_| {
                const claimed = queue.next.fetchAdd(1, .monotonic);
                if (claimed >= queue.order.len) return;

                const index = queue.order[claimed];

                worker.visit(&queue.items[index], &slot.tally) catch |err| {
                    slot.failure = .{ .index = index, .err = err };

                    return;
                };
            }
        }

        fn merged(slots: []const Slot, tally: *Worker.Tally) ?Failure {
            assert(slots.len >= 1);
            assert(slots.len <= thread_count_max);

            const field_names = @typeInfo(Worker.Tally).@"struct".field_names;
            var failure: ?Failure = null;

            for (slots) |slot| {
                inline for (field_names) |name| @field(tally, name) += @field(slot.tally, name);

                const held = slot.failure orelse continue;

                if (failure) |first| {
                    if (failure_before(held, first)) failure = held;
                } else {
                    failure = held;
                }
            }

            return failure;
        }
    };
}

fn failure_before(held: Failure, first: Failure) bool {
    if (held.index == null) return true;
    if (first.index == null) return false;

    const index_held = held.index.?;
    const index_first = first.index.?;

    assert(index_held != index_first);

    return index_held < index_first;
}

const Squares = struct {
    sum: u64,

    pub const Item = u32;
    pub const Shared = struct { factor: u64 };
    pub const Tally = struct { squares: u64, visited: u32 };

    pub fn init(squares: *Squares, gpa: std.mem.Allocator, shared: *const Shared) !void {
        assert(shared.factor > 0);
        assert(gpa.vtable == std.testing.allocator.vtable);

        squares.* = .{ .sum = 0 };
    }

    pub fn deinit(squares: *Squares, gpa: std.mem.Allocator) void {
        assert(gpa.vtable == std.testing.allocator.vtable);
        assert(squares.sum <= @as(u64, std.math.maxInt(u32)) * item_count_max);

        squares.* = undefined;
    }

    pub fn visit(squares: *Squares, item: *const Item, tally: *Tally) !void {
        if (item.* == failing_item) return error.Failing;

        squares.sum += item.*;
        tally.squares += @as(u64, item.*) * item.*;
        tally.visited += 1;
    }

    pub fn weight(item: *const Item) u64 {
        const returned = (@as(u64, item.* % 7) + 1) << 15;

        assert(returned < std.math.maxInt(u64));

        return returned;
    }

    const failing_item: u32 = 777;
};

test "every item is visited once and the tallies add up" {
    const gpa = std.testing.allocator;
    const items = try gpa.alloc(u32, 500);
    defer gpa.free(items);

    for (items, 0..) |*item, at| item.* = @intCast(at);

    var tally: Squares.Tally = .{ .squares = 0, .visited = 0 };

    try run(Squares, gpa, &.{ .factor = 1 }, items, &tally);

    var squares: u64 = 0;

    for (items) |item| squares += @as(u64, item) * item;

    try std.testing.expectEqual(@as(u32, 500), tally.visited);
    try std.testing.expectEqual(squares, tally.squares);
}

test "a failing item fails the run" {
    const gpa = std.testing.allocator;
    const items = try gpa.alloc(u32, 1000);
    defer gpa.free(items);

    for (items, 0..) |*item, at| item.* = @intCast(at);

    var tally: Squares.Tally = .{ .squares = 0, .visited = 0 };

    try std.testing.expectError(error.Failing, run(Squares, gpa, &.{ .factor = 1 }, items, &tally));
    try std.testing.expect(tally.visited < 1000);
}

test "an empty list visits nothing" {
    var tally: Squares.Tally = .{ .squares = 0, .visited = 0 };

    try run(Squares, std.testing.allocator, &.{ .factor = 1 }, &.{}, &tally);
    try std.testing.expectEqual(@as(u32, 0), tally.visited);
    try std.testing.expect(thread_count_of(1, 0) == 1);
    try std.testing.expect(thread_count_of(item_count_max, weight_per_thread_min - 1) == 1);
}
