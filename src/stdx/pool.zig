const std = @import("std");
const assert = std.debug.assert;

io: std.Io,
shared: Shared,
stack_bytes: usize,
thread_count: u32,
threads: [worker_count_max]std.Thread,
worker_count: u32,

const Pool = @This();
pub const Error = error{Poisoned};
pub const JobError = error{JobFailed};

pub const Options = struct {
    stack_bytes: usize,
    worker_count: u32,
};

pub const Job = struct {
    context: *anyopaque,
    run: *const fn (context: *anyopaque, worker: u32, index: u32) JobError!void,
};

pub const Shared = struct {
    done: std.atomic.Value(u32),
    finished: std.atomic.Value(u32),
    generation: std.atomic.Value(u32),
    item_count: u32,
    job: ?Job,
    next: std.atomic.Value(u32),
    poisoned: std.atomic.Value(bool),
    stopping: std.atomic.Value(bool),
};

pub const stack_bytes_default: usize = std.Thread.SpawnConfig.default_stack_size;
pub const wait_count_max: u64 = 1 << 48;
pub const worker_count_max: u32 = 64;
const batch_count_max: u64 = 1 << 48;
const item_count_max: u32 = std.math.maxInt(u32) - worker_count_max - 1;
const park_microseconds: i64 = 50;
const spin_yield_max: u32 = 256;

pub fn init(pool: *Pool, io: std.Io, options: Options) std.Thread.SpawnError!void {
    assert(options.worker_count > 0);
    assert(options.worker_count <= worker_count_max);
    assert(options.stack_bytes > 0);

    pool.* = .{
        .io = io,
        .shared = .{
            .done = .init(0),
            .finished = .init(0),
            .generation = .init(0),
            .item_count = 0,
            .job = null,
            .next = .init(0),
            .poisoned = .init(false),
            .stopping = .init(false),
        },
        .stack_bytes = options.stack_bytes,
        .thread_count = 0,
        .threads = undefined,
        .worker_count = options.worker_count,
    };

    errdefer pool.deinit();

    const config: std.Thread.SpawnConfig = .{ .stack_size = options.stack_bytes };

    for (0..options.worker_count) |worker| {
        const worker_index: u32 = @intCast(worker);

        pool.threads[worker] = try std.Thread.spawn(config, serve, .{ pool, worker_index });
        pool.thread_count += 1;
    }

    assert(pool.thread_count == pool.worker_count);
}

pub fn deinit(pool: *Pool) void {
    assert(pool.thread_count <= pool.worker_count);
    assert(pool.shared.job == null);

    pool.shared.stopping.store(true, .release);
    _ = pool.shared.generation.fetchAdd(1, .release);

    pool.io.futexWake(u32, &pool.shared.generation.raw, worker_count_max);

    for (pool.threads[0..pool.thread_count]) |thread| thread.join();

    pool.thread_count = 0;

    assert(pool.shared.stopping.load(.acquire));
}

pub fn count(pool: *const Pool) u32 {
    assert(pool.worker_count > 0);
    assert(pool.worker_count <= worker_count_max);

    return pool.worker_count;
}

pub fn run(pool: *Pool, comptime Task: type, task: *const Task, item_count: u32) Error!void {
    assert(item_count <= item_count_max);

    comptime task_check(Task);

    assert(pool.worker_count > 0);
    assert(pool.thread_count == pool.worker_count);

    var voids: [worker_count_max + 1]void = undefined;
    const states = states_of(Task, task, &voids, pool.worker_count + 1);

    if (item_count == 0) return;

    var batch: BatchType(Task) = .{ .states = states, .task = task };

    pool.dispatched(job_of(Task, &batch), item_count);
    pool.served(pool.worker_count);

    return pool.collected();
}

pub fn run_reporting(
    pool: *Pool,
    comptime Task: type,
    comptime Drainer: type,
    task: *const Task,
    drainer: *Drainer,
    item_count: u32,
) Error!void {
    assert(item_count <= item_count_max);

    comptime task_check(Task);
    comptime drainer_check(Drainer);

    assert(pool.worker_count > 0);
    assert(pool.thread_count == pool.worker_count);

    var voids: [worker_count_max + 1]void = undefined;
    const states = states_of(Task, task, &voids, pool.worker_count);

    if (item_count == 0) {
        _ = drainer.drain();

        return;
    }

    var batch: BatchType(Task) = .{ .states = states, .task = task };

    pool.dispatched(job_of(Task, &batch), item_count);
    pool.drained(Drainer, drainer);

    return pool.collected();
}

fn serve(pool: *Pool, worker: u32) void {
    assert(worker < pool.worker_count);
    assert(pool.worker_count <= worker_count_max);

    var seen: u32 = 0;

    for (0..batch_count_max) |_| {
        seen = pool.awaited(seen);

        if (pool.shared.stopping.load(.acquire)) return;

        pool.served(worker);

        const finished = pool.shared.finished.fetchAdd(1, .acq_rel);

        assert(finished < pool.worker_count);

        pool.io.futexWake(u32, &pool.shared.finished.raw, 1);
    } else unreachable;
}

fn awaited(pool: *Pool, seen: u32) u32 {
    assert(pool.worker_count > 0);
    assert(pool.worker_count <= worker_count_max);
    assert(seen < std.math.maxInt(u32));

    for (0..wait_count_max) |_| {
        const generation = pool.shared.generation.load(.acquire);
        if (generation != seen) return generation;

        pool.io.futexWaitUncancelable(u32, &pool.shared.generation.raw, seen);
    } else unreachable;
}

fn dispatched(pool: *Pool, job: Job, item_count: u32) void {
    assert(item_count > 0);
    assert(item_count <= item_count_max);
    assert(pool.shared.job == null);
    assert(pool.shared.finished.load(.acquire) == 0);

    pool.shared.job = job;
    pool.shared.item_count = item_count;

    pool.shared.done.store(0, .release);
    pool.shared.next.store(0, .release);
    pool.shared.poisoned.store(false, .release);

    _ = pool.shared.generation.fetchAdd(1, .release);

    pool.io.futexWake(u32, &pool.shared.generation.raw, pool.worker_count);
}

fn served(pool: *Pool, worker: u32) void {
    const job = pool.shared.job.?;
    const item_count = pool.shared.item_count;

    assert(worker <= pool.worker_count);
    assert(item_count > 0);

    for (0..item_count) |_| {
        const index = pool.claimed() orelse return;

        job.run(job.context, worker, index) catch |err| switch (err) {
            error.JobFailed => pool.shared.poisoned.store(true, .release),
        };

        const done = pool.shared.done.fetchAdd(1, .acq_rel);

        assert(done < item_count);
    }
}

fn claimed(pool: *Pool) ?u32 {
    assert(pool.shared.item_count > 0);

    if (pool.shared.poisoned.load(.acquire)) return null;

    const index = pool.shared.next.fetchAdd(1, .acq_rel);
    if (index >= pool.shared.item_count) return null;

    assert(index < pool.shared.item_count);

    return index;
}

fn collected(pool: *Pool) Error!void {
    assert(pool.shared.job != null);
    assert(pool.shared.item_count > 0);

    for (0..wait_count_max) |_| {
        const finished = pool.shared.finished.load(.acquire);
        if (finished == pool.worker_count) break;

        assert(finished < pool.worker_count);

        pool.io.futexWaitUncancelable(u32, &pool.shared.finished.raw, finished);
    } else unreachable;

    const poisoned = pool.shared.poisoned.load(.acquire);

    pool.shared.finished.store(0, .release);
    pool.shared.job = null;

    if (poisoned) return error.Poisoned;

    assert(pool.shared.done.load(.acquire) == pool.shared.item_count);
}

fn drained(pool: *Pool, comptime Drainer: type, drainer: *Drainer) void {
    assert(pool.shared.job != null);
    assert(pool.shared.item_count > 0);

    for (0..wait_count_max) |spin| {
        if (drainer.drain()) return;
        if (pool.shared.poisoned.load(.acquire)) return;

        waited(pool.io, spin);
    } else unreachable;
}

fn job_of(comptime Task: type, batch: *BatchType(Task)) Job {
    const Erased = struct {
        fn run(context: *anyopaque, worker: u32, index: u32) JobError!void {
            assert(index < std.math.maxInt(u32));

            const held: *BatchType(Task) = @ptrCast(@alignCast(context));
            const body = if (@hasDecl(Task, "State")) Task.run else StatelessType(Task).run;

            assert(worker < held.states.len);

            return body(held.task, &held.states[worker], index);
        }
    };

    assert(batch.states.len > 0);
    assert(batch.states.len <= worker_count_max + 1);

    return .{ .context = batch, .run = &Erased.run };
}

fn states_of(
    comptime Task: type,
    task: *const Task,
    voids: []void,
    state_count: u32,
) []StateType(Task) {
    assert(state_count > 0);
    assert(state_count <= voids.len);

    if (@hasDecl(Task, "State")) {
        const states = task.states();

        assert(states.len == state_count);

        return states;
    } else {
        return voids[0..state_count];
    }
}

fn task_check(comptime Task: type) void {
    const name = @typeName(Task);
    const stateless = "pub fn run(*const " ++ name ++ ", u32) JobError!void";
    const stateful = "pub fn run(*const " ++ name ++ ", *State, u32) JobError!void";
    const accessor = "pub fn states(*const " ++ name ++ ") []State";
    const shapes = stateless ++ ", or " ++ stateful ++ " beside pub const State and " ++ accessor;
    const expected = "Pool expects " ++ name ++ " to declare " ++ shapes;

    if (!@hasDecl(Task, "run")) @compileError(expected);

    const run_info = @typeInfo(@TypeOf(Task.run)).@"fn";
    const params = run_info.param_types;

    if ((run_info.return_type orelse void) != JobError!void) @compileError(expected);
    if (params.len == 0) @compileError(expected);
    if ((params[0] orelse void) != *const Task) @compileError(expected);
    if ((params[params.len - 1] orelse void) != u32) @compileError(expected);

    if (@hasDecl(Task, "State")) {
        if (!@hasDecl(Task, "states")) @compileError(expected);
        if (params.len != 3) @compileError(expected);
        if ((params[1] orelse void) != *Task.State) @compileError(expected);
        if (@TypeOf(Task.states) != fn (*const Task) []Task.State) @compileError(expected);
    } else {
        if (params.len != 2) @compileError(expected);
    }
}

fn drainer_check(comptime Drainer: type) void {
    const name = @typeName(Drainer);
    const expected = "Pool expects " ++ name ++ " to declare pub fn drain(*" ++ name ++ ") bool";

    if (!@hasDecl(Drainer, "drain")) @compileError(expected);

    const drain_info = @typeInfo(@TypeOf(Drainer.drain)).@"fn";

    if (drain_info.param_types.len != 1) @compileError(expected);
    if ((drain_info.return_type orelse void) != bool) @compileError(expected);
}

fn BatchType(comptime Task: type) type {
    return struct {
        states: []StateType(Task),
        task: *const Task,
    };
}

fn StateType(comptime Task: type) type {
    if (@hasDecl(Task, "State")) return Task.State;
    return void;
}

fn StatelessType(comptime Task: type) type {
    return struct {
        fn run(task: *const Task, state: *void, index: u32) JobError!void {
            assert(@TypeOf(state.*) == void);
            assert(index < std.math.maxInt(u32));

            return task.run(index);
        }
    };
}

pub fn waited(io: std.Io, spin: usize) void {
    assert(spin < wait_count_max);

    if (spin < spin_yield_max) {
        std.Thread.yield() catch |err| switch (err) {
            error.SystemCannotYield => {},
        };

        return;
    }

    io.sleep(.fromMicroseconds(park_microseconds), .awake) catch |err| switch (err) {
        error.Canceled => {},
    };
}

pub fn worker_count_for(item_count: u32) u32 {
    const available: u32 = available: {
        const cpu_count = std.Thread.getCpuCount() catch break :available 1;

        break :available @intCast(@min(cpu_count, worker_count_max));
    };
    const capacity = @max(available, 1);

    assert(capacity >= 1);
    assert(capacity <= worker_count_max);

    if (item_count == 0) return 1;
    if (item_count >= capacity) return capacity;
    return item_count;
}

fn test_started(pool: *Pool, worker_count: u32) !void {
    assert(worker_count <= worker_count_max);

    try pool.init(std.testing.io, .{
        .stack_bytes = stack_bytes_default,
        .worker_count = worker_count,
    });

    assert(pool.count() == worker_count);
    assert(pool.thread_count == worker_count);
}

const Failing = struct {
    runners: []bool,

    pub const State = bool;

    pub fn run(failing: *const Failing, fails: *bool, index: u32) JobError!void {
        assert(failing.runners.len > 0);
        assert(index < 8);

        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch unreachable;

        if (fails.*) return error.JobFailed;
    }

    pub fn states(failing: *const Failing) []bool {
        assert(failing.runners.len > 0);

        return failing.runners;
    }
};

const Immediate = struct {
    pub fn drain(immediate: *Immediate) bool {
        assert(@TypeOf(immediate.*) == Immediate);

        return true;
    }
};

const Squares = struct {
    values: []u64,

    pub fn run(squares: *const Squares, index: u32) JobError!void {
        assert(index < squares.values.len);

        squares.values[index] = @as(u64, index) * index;
    }
};

test Pool {
    var pool: Pool = undefined;

    try pool.init(std.testing.io, .{ .stack_bytes = stack_bytes_default, .worker_count = 2 });
    defer pool.deinit();

    var values: [64]u64 = @splat(0);
    const squares: Squares = .{ .values = &values };

    try pool.run(Squares, &squares, values.len);

    for (values, 0..) |value, index| try std.testing.expectEqual(@as(u64, index * index), value);

    try std.testing.expectEqual(2, pool.count());
}

test "a job that panics poisons the pool instead of hanging it" {
    var pool: Pool = undefined;

    try test_started(&pool, 2);
    defer pool.deinit();

    var runners = [_]bool{ true, true, true };
    const failing: Failing = .{ .runners = &runners };

    try std.testing.expectError(error.Poisoned, pool.run(Failing, &failing, 8));
}

test "a poisoned batch leaves the pool ready for the next" {
    var pool: Pool = undefined;

    try test_started(&pool, 2);
    defer pool.deinit();

    var runners = [_]bool{ true, true, true };
    var spared = [_]bool{ false, false, false };
    const failing: Failing = .{ .runners = &runners };
    const sparing: Failing = .{ .runners = &spared };

    try std.testing.expectError(error.Poisoned, pool.run(Failing, &failing, 8));
    try pool.run(Failing, &sparing, 8);
    try std.testing.expectEqual(@as(u32, 8), pool.shared.done.load(.acquire));
}

test "a worker count is floored at one and capped by the items" {
    try std.testing.expectEqual(@as(u32, 1), worker_count_for(0));
    try std.testing.expectEqual(@as(u32, 1), worker_count_for(1));
    try std.testing.expect(worker_count_for(std.math.maxInt(u32)) <= worker_count_max);
    try std.testing.expect(worker_count_for(3) <= 3);
    try std.testing.expect(worker_count_for(3) >= 1);
}

test "every run shape covers every item once" {
    const item_count: u32 = 100;

    const Mark = struct {
        seen: *[item_count]std.atomic.Value(u32),

        pub fn run(mark: *const @This(), index: u32) JobError!void {
            assert(index < item_count);

            _ = mark.seen[index].fetchAdd(1, .acq_rel);
        }
    };

    const MarkCounted = struct {
        mark: Mark,
        runs: []u32,

        pub const State = u32;

        pub fn run(counted: *const @This(), runs: *u32, index: u32) JobError!void {
            assert(index < std.math.maxInt(u32));

            runs.* += 1;

            return counted.mark.run(index);
        }

        pub fn states(counted: *const @This()) []u32 {
            return counted.runs;
        }
    };

    const Drainer = struct {
        seen: *[item_count]std.atomic.Value(u32),
        target: u32,

        pub fn drain(drainer: *@This()) bool {
            for (drainer.seen) |*held| {
                if (held.load(.acquire) < drainer.target) return false;
            }

            return true;
        }
    };

    var pool: Pool = undefined;

    try test_started(&pool, 3);
    defer pool.deinit();

    var seen: [item_count]std.atomic.Value(u32) = @splat(.init(0));
    var runs = [_]u32{ 0, 0, 0, 0 };
    var halfway: Drainer = .{ .seen = &seen, .target = 2 };
    var whole: Drainer = .{ .seen = &seen, .target = 4 };
    const mark: Mark = .{ .seen = &seen };
    const counted: MarkCounted = .{ .mark = mark, .runs = &runs };
    const counted_reporting: MarkCounted = .{ .mark = mark, .runs = runs[0..pool.count()] };

    try pool.run(Mark, &mark, item_count);
    try pool.run_reporting(Mark, Drainer, &mark, &halfway, item_count);
    try pool.run(MarkCounted, &counted, item_count);
    try pool.run_reporting(MarkCounted, Drainer, &counted_reporting, &whole, item_count);

    for (&seen) |*held| try std.testing.expectEqual(@as(u32, 4), held.load(.acquire));

    try std.testing.expectEqual(item_count * 2, runs[0] + runs[1] + runs[2] + runs[3]);
}

test "a worker serves every batch on the thread it started on" {
    const batch_count: u32 = 32;
    const item_count: u32 = 64;

    const Held = struct {
        identifier: ?std.Thread.Id,
        moved: bool,
    };

    const Witness = struct {
        held: []Held,

        pub const State = Held;

        pub fn run(witness: *const @This(), held: *Held, index: u32) JobError!void {
            assert(witness.held.len > 0);
            assert(index < item_count);

            const identifier = std.Thread.getCurrentId();

            if (held.identifier) |first| {
                if (first != identifier) held.moved = true;
            } else {
                held.identifier = identifier;
            }
        }

        pub fn states(witness: *const @This()) []Held {
            return witness.held;
        }
    };

    var pool: Pool = undefined;

    try test_started(&pool, 4);
    defer pool.deinit();

    var states: [4]Held = @splat(.{ .identifier = null, .moved = false });
    var immediate: Immediate = .{};
    var witnessed: u32 = 0;
    const witness: Witness = .{ .held = &states };

    for (0..batch_count) |_| {
        try pool.run_reporting(Witness, Immediate, &witness, &immediate, item_count);
    }

    for (states) |held| {
        try std.testing.expect(!held.moved);

        if (held.identifier) |identifier| {
            try std.testing.expect(identifier != std.Thread.getCurrentId());

            witnessed += 1;
        }
    }

    try std.testing.expect(witnessed > 0);
}

test "an empty batch runs nothing and still drains once" {
    const Counting = struct {
        drains: u32,

        pub fn drain(counting: *@This()) bool {
            counting.drains += 1;

            return true;
        }
    };

    var pool: Pool = undefined;

    try test_started(&pool, 2);
    defer pool.deinit();

    var values: [1]u64 = .{9};
    var counting: Counting = .{ .drains = 0 };
    const squares: Squares = .{ .values = &values };

    try pool.run(Squares, &squares, 0);
    try pool.run_reporting(Squares, Counting, &squares, &counting, 0);
    try std.testing.expectEqual(9, values[0]);
    try std.testing.expectEqual(1, counting.drains);
}
