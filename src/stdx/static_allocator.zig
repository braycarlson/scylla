const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const log = @import("log.zig");

allocation_count: u64,
heap_bytes_allocated: u64,
heap_bytes_released: u64,
parent: std.mem.Allocator,
report_allocates: bool,
reporting: bool,
state: State,

pub const State = enum {
    init,
    static,
    deinit,
};

const StaticAllocator = @This();
const exit_code_max: u8 = 125;

pub const FreezeScope = struct {
    static_allocator: *StaticAllocator,

    pub fn leave(scope: *FreezeScope) void {
        assert(scope.static_allocator.state == .static);

        scope.static_allocator.state = .init;

        assert(!scope.static_allocator.is_static());
    }
};

const Report = struct {
    allocation_count: u64,
    heap_bytes_allocated: u64,
    heap_bytes_live: u64,
};

const ReportScope = struct {
    static_allocator: *StaticAllocator,

    pub fn enter(static_allocator: *StaticAllocator) ?ReportScope {
        if (static_allocator.reporting) return null;

        static_allocator.reporting = true;

        assert(static_allocator.reporting);

        return .{ .static_allocator = static_allocator };
    }

    pub fn leave(scope: *ReportScope) void {
        assert(scope.static_allocator.reporting);

        scope.static_allocator.reporting = false;

        assert(!scope.static_allocator.reporting);
    }
};

pub fn init(parent: std.mem.Allocator) StaticAllocator {
    return .{
        .allocation_count = 0,
        .heap_bytes_allocated = 0,
        .heap_bytes_released = 0,
        .parent = parent,
        .report_allocates = false,
        .reporting = false,
        .state = .init,
    };
}

pub fn deinit(static_allocator: *StaticAllocator) void {
    assert(static_allocator.state != .static);

    static_allocator.* = undefined;
}

pub fn allocator(static_allocator: *StaticAllocator) std.mem.Allocator {
    return .{
        .ptr = static_allocator,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}

pub fn transition_from_init_to_static(static_allocator: *StaticAllocator) void {
    assert(static_allocator.state == .init);

    static_allocator.state = .static;

    assert(static_allocator.state == .static);
}

pub fn transition_from_static_to_deinit(static_allocator: *StaticAllocator) void {
    assert(static_allocator.state == .static);

    static_allocator.state = .deinit;

    assert(static_allocator.state == .deinit);
}

pub fn exit(static_allocator: *StaticAllocator, code: u8) noreturn {
    assert(code <= exit_code_max);

    if (static_allocator.state == .static) static_allocator.transition_from_static_to_deinit();

    assert(static_allocator.state != .static);
    assert(!static_allocator.is_static());

    std.process.exit(code);
}

pub fn freeze_scope(static_allocator: *StaticAllocator) FreezeScope {
    assert(static_allocator.state == .init);

    static_allocator.state = .static;

    assert(static_allocator.is_static());

    return .{ .static_allocator = static_allocator };
}

fn frozen(
    static_allocator: *StaticAllocator,
    context: anytype,
    comptime run: fn (@TypeOf(context)) void,
) void {
    comptime assert(@typeInfo(@TypeOf(context)) == .pointer);

    var scope = static_allocator.freeze_scope();
    defer scope.leave();

    assert(static_allocator.is_static());

    run(context);
}

pub fn is_static(static_allocator: *const StaticAllocator) bool {
    return static_allocator.state == .static;
}

fn report(static_allocator: *const StaticAllocator) Report {
    const allocated = static_allocator.heap_bytes_allocated;
    const released = static_allocator.heap_bytes_released;

    assert(allocated >= released);

    const result: Report = .{
        .allocation_count = static_allocator.allocation_count,
        .heap_bytes_allocated = allocated,
        .heap_bytes_live = allocated - released,
    };

    assert(result.heap_bytes_allocated >= result.heap_bytes_live);

    return result;
}

pub fn create(comptime T: type, gpa: std.mem.Allocator) std.mem.Allocator.Error!*T {
    const items = try reserve(T, gpa, 1);

    assert(items.len == 1);

    return &items[0];
}

pub fn destroy(comptime T: type, gpa: std.mem.Allocator, item: *T) void {
    release(T, gpa, item[0..1]);
}

pub fn release(comptime T: type, gpa: std.mem.Allocator, items: []T) void {
    comptime assert(@sizeOf(T) > 0);
    assert(items.len > 0);

    gpa.rawFree(std.mem.sliceAsBytes(items), .of(T), @returnAddress());
}

pub fn report_log(static_allocator: *const StaticAllocator) void {
    assert(static_allocator.is_static());

    const held = static_allocator.report();

    assert(held.allocation_count > 0);

    log.line("frozen: {d} bytes live of {d} bytes across {d} allocations", .{
        held.heap_bytes_live,
        held.heap_bytes_allocated,
        held.allocation_count,
    });
}

pub fn reserve(comptime T: type, gpa: std.mem.Allocator, count: u32) std.mem.Allocator.Error![]T {
    comptime assert(@sizeOf(T) > 0);
    assert(count > 0);

    const length = @as(usize, count) * @sizeOf(T);
    const raw = gpa.rawAlloc(length, .of(T), @returnAddress()) orelse return error.OutOfMemory;
    const items: [*]T = @ptrCast(@alignCast(raw));

    assert(@intFromPtr(items) % @alignOf(T) == 0);

    return items[0..count];
}

pub fn warm() void {
    const identifier = std.Thread.getCurrentId();

    assert(identifier == std.Thread.getCurrentId());
}

fn violation(static_allocator: *StaticAllocator, operation: []const u8, bytes: usize) void {
    assert(operation.len > 0);
    assert(bytes > 0);

    var scope = ReportScope.enter(static_allocator) orelse return;
    defer scope.leave();

    if (static_allocator.report_allocates) {
        const probe = static_allocator.allocator().alloc(u8, 48) catch return;

        static_allocator.allocator().free(probe);
    }

    log.line("allocation guard tripped: {s} of {d} bytes after freeze", .{ operation, bytes });
}

fn alloc(
    context: *anyopaque,
    length: usize,
    alignment: std.mem.Alignment,
    return_address: usize,
) ?[*]u8 {
    assert(length > 0);
    assert(return_address == 0 or return_address >= std.heap.page_size_min);
    assert(alignment.toByteUnits() <= std.heap.page_size_min);

    const static_allocator: *StaticAllocator = @ptrCast(@alignCast(context));

    if (static_allocator.state == .static) static_allocator.violation("allocation", length);

    assert(static_allocator.state == .init);

    const result = static_allocator.parent.rawAlloc(length, alignment, return_address);

    if (result) |pointer| {
        assert(alignment.check(@intFromPtr(pointer)));

        static_allocator.allocation_count += 1;
        static_allocator.heap_bytes_allocated += length;
    }

    return result;
}

fn resize(
    context: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    target_length: usize,
    return_address: usize,
) bool {
    assert(target_length > 0);
    assert(return_address == 0 or return_address >= std.heap.page_size_min);

    const static_allocator: *StaticAllocator = @ptrCast(@alignCast(context));

    if (static_allocator.state == .static) {
        static_allocator.violation("reallocation", target_length);
    }

    assert(static_allocator.state == .init);
    assert(memory.len > 0);
    assert(alignment.check(@intFromPtr(memory.ptr)));

    const resized = static_allocator.parent.rawResize(
        memory,
        alignment,
        target_length,
        return_address,
    );

    if (resized) static_allocator.account_moved(memory.len, target_length);

    return resized;
}

fn remap(
    context: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    target_length: usize,
    return_address: usize,
) ?[*]u8 {
    assert(target_length > 0);
    assert(return_address == 0 or return_address >= std.heap.page_size_min);

    const static_allocator: *StaticAllocator = @ptrCast(@alignCast(context));

    if (static_allocator.state == .static) {
        static_allocator.violation("reallocation", target_length);
    }

    assert(static_allocator.state == .init);
    assert(memory.len > 0);
    assert(alignment.check(@intFromPtr(memory.ptr)));

    const remapped = static_allocator.parent.rawRemap(
        memory,
        alignment,
        target_length,
        return_address,
    );

    if (remapped != null) static_allocator.account_moved(memory.len, target_length);

    return remapped;
}

fn free(
    context: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    return_address: usize,
) void {
    assert(memory.len > 0);
    assert(return_address == 0 or return_address >= std.heap.page_size_min);

    const static_allocator: *StaticAllocator = @ptrCast(@alignCast(context));

    if (static_allocator.state == .static) static_allocator.violation("deallocation", memory.len);

    assert(static_allocator.state != .static);
    assert(alignment.check(@intFromPtr(memory.ptr)));

    static_allocator.state = .deinit;
    static_allocator.heap_bytes_released += memory.len;

    static_allocator.parent.rawFree(memory, alignment, return_address);
}

fn account_moved(
    static_allocator: *StaticAllocator,
    memory_length: usize,
    target_length: usize,
) void {
    assert(memory_length > 0);
    assert(target_length > 0);

    static_allocator.heap_bytes_released += memory_length;
    static_allocator.heap_bytes_allocated += target_length;
}

test StaticAllocator {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    const gpa = static_allocator.allocator();
    const table = try StaticAllocator.reserve(u32, gpa, 8);
    defer StaticAllocator.release(u32, gpa, table);

    var scope = static_allocator.freeze_scope();
    defer scope.leave();

    @memset(table, 7);

    try std.testing.expect(static_allocator.is_static());
    try std.testing.expectEqual(8, table.len);
    try std.testing.expectEqual(7, table[7]);
}

test "an allocation under init reaches the parent" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    const gpa = static_allocator.allocator();
    const memory = try gpa.alloc(u8, 16);

    try std.testing.expectEqual(16, memory.len);
    try std.testing.expectEqual(State.init, static_allocator.state);

    gpa.free(memory);

    try std.testing.expectEqual(State.deinit, static_allocator.state);
}

test "a static allocator passes through static to deinit" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    const gpa = static_allocator.allocator();
    const memory = try gpa.alloc(u32, 4);

    static_allocator.transition_from_init_to_static();

    try std.testing.expectEqual(State.static, static_allocator.state);

    static_allocator.transition_from_static_to_deinit();
    gpa.free(memory);

    try std.testing.expectEqual(State.deinit, static_allocator.state);
}

const TestProbe = struct {
    stderr: []u8,
    stdout: []u8,
    term: std.process.Child.Term,

    fn deinit(probe: *const TestProbe) void {
        std.testing.allocator.free(probe.stderr);
        std.testing.allocator.free(probe.stdout);
    }

    fn guard_count(probe: *const TestProbe) usize {
        return std.mem.count(u8, probe.stderr, "allocation guard tripped");
    }
};

const test_probe_path = "zig-out/bin/guard_probe" ++ builtin.target.exeFileExt();

const test_term_panicked: std.process.Child.Term = switch (builtin.target.os.tag) {
    .windows => .{ .exited = 3 },
    else => .{ .signal = .ABRT },
};

fn test_probe(case: []const u8) !TestProbe {
    assert(case.len > 0);

    const done = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ test_probe_path, case },
    });

    assert(done.stderr.len <= std.math.maxInt(u32));

    return .{ .stderr = done.stderr, .stdout = done.stdout, .term = done.term };
}

test "allocation after scoped freeze panics" {
    const probe = try test_probe("allocate");
    defer probe.deinit();

    const found = std.mem.find(u8, probe.stderr, "allocation guard tripped: allocation of 32");

    try std.testing.expectEqual(test_term_panicked, probe.term);
    try std.testing.expect(found != null);
}

test "deallocation after scoped freeze panics" {
    const probe = try test_probe("deallocate");
    defer probe.deinit();

    const found = std.mem.find(u8, probe.stderr, "allocation guard tripped: deallocation of 32");

    try std.testing.expectEqual(test_term_panicked, probe.term);
    try std.testing.expect(found != null);
}

test "a report that allocates does not re enter the guard" {
    const probe = try test_probe("report");
    defer probe.deinit();

    try std.testing.expectEqual(test_term_panicked, probe.term);
    try std.testing.expect(probe.guard_count() <= 1);
}

test "allocation outside scoped freeze is permitted" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    {
        var scope = static_allocator.freeze_scope();
        defer scope.leave();

        try std.testing.expect(static_allocator.is_static());
    }

    const buffer = try static_allocator.allocator().alloc(u8, 32);
    defer static_allocator.allocator().free(buffer);

    try std.testing.expectEqual(@as(usize, 32), buffer.len);
    try std.testing.expect(!static_allocator.is_static());
}

test "report scope is reentrant safe" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var outer = ReportScope.enter(&static_allocator);
    const inner = ReportScope.enter(&static_allocator);

    try std.testing.expect(outer != null);
    try std.testing.expect(inner == null);
    try std.testing.expect(ReportScope.enter(&static_allocator) == null);

    outer.?.leave();

    var again = ReportScope.enter(&static_allocator);

    try std.testing.expect(again != null);

    again.?.leave();
}

test "report stays coherent" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    const memory = try static_allocator.allocator().alloc(u8, 16);
    const held = static_allocator.report();

    static_allocator.allocator().free(memory);

    try std.testing.expect(held.heap_bytes_allocated >= held.heap_bytes_live);
    try std.testing.expect(held.allocation_count > 0);
}

test "a report logs on a frozen thread" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    const memory = try static_allocator.allocator().alloc(u8, 16);
    defer static_allocator.allocator().free(memory);

    warm();
    static_allocator.frozen(@as(*const StaticAllocator, &static_allocator), report_log);

    try std.testing.expect(!static_allocator.is_static());
}

test "warming never touches the streams" {
    const Warmer = struct {
        fn run(warmed: *std.atomic.Value(bool)) void {
            warm();
            warmed.store(true, .release);
        }
    };

    var warmed: std.atomic.Value(bool) = .init(false);
    const thread = try std.Thread.spawn(.{}, Warmer.run, .{&warmed});

    thread.join();

    try std.testing.expect(warmed.load(.acquire));
}

test "an exit stands the guard down and ends the child" {
    const probe = try test_probe("exit");
    defer probe.deinit();

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 3 }, probe.term);
    try std.testing.expectEqual(@as(usize, 0), probe.guard_count());
}
