const std = @import("std");
const assert = std.debug.assert;
const Pool = @import("pool.zig");
const Tally = [item_count]std.atomic.Value(u32);
const item_count: u32 = 16;
const pool_count: u32 = 12;
const round_count: u32 = 64;
const worker_count: u32 = 8;

const Marking = struct {
    tally: *Tally,

    pub fn run(marking: *const Marking, index: u32) Pool.JobError!void {
        assert(index < marking.tally.len);

        if (index >= marking.tally.len) return;

        _ = marking.tally[index].fetchAdd(1, .monotonic);
    }
};

fn tally_once(tally: *const Tally) bool {
    for (tally) |*counter| {
        if (counter.load(.monotonic) != 1) return false;
    }

    return true;
}

fn paired(pool: *Pool, round: u32) bool {
    assert(round < round_count);

    var first: Tally = @splat(.init(0));
    const marking_first: Marking = .{ .tally = &first };

    pool.run(Marking, &marking_first, item_count) catch return false;

    if (!tally_once(&first)) return false;

    var second: Tally = @splat(.init(0));
    const second_marking: Marking = .{ .tally = &second };

    pool.run(Marking, &second_marking, item_count) catch return false;

    return tally_once(&second);
}

fn rounds_run(result: *bool) void {
    var pool: Pool = undefined;

    pool.init(std.testing.io, .{
        .stack_bytes = Pool.stack_bytes_default,
        .worker_count = worker_count,
    }) catch return;

    defer pool.deinit();

    assert(pool.count() == worker_count);

    result.* = true;

    for (0..round_count) |round| {
        if (!paired(&pool, @intCast(round))) {
            result.* = false;

            return;
        }
    }
}

test "a run never loses an index to a worker still waking from the run before" {
    var results: [pool_count]bool = @splat(false);
    var threads: [pool_count]std.Thread = undefined;

    for (&threads, &results) |*thread, *result| {
        thread.* = try std.Thread.spawn(.{}, rounds_run, .{result});
    }

    for (threads) |thread| thread.join();

    for (results) |result| try std.testing.expect(result);
}
