const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Span = @import("stdx/bounded/span.zig");
const StaticAllocator = @import("stdx/static_allocator.zig");

const Case = enum {
    allocate,
    deallocate,
    exit,
    report,
    shift,
};

pub const exit_code: u8 = 3;
pub const probe_bytes: u32 = 32;
const exit_usage: u8 = 2;

pub fn main(init: std.process.Init) void {
    assert(init.minimal.args.vector.len > 0);

    const arguments = init.minimal.args.toSlice(init.arena.allocator()) catch {
        std.process.exit(exit_usage);
    };

    if (arguments.len != 2) std.process.exit(exit_usage);

    const case = std.meta.stringToEnum(Case, arguments[1]) orelse std.process.exit(exit_usage);

    if (builtin.target.os.tag == .linux) {
        const linux = std.os.linux;

        _ = linux.prctl(@backingInt(linux.PR.SET_DUMPABLE), 0, 0, 0, 0);
    }

    var static_allocator: StaticAllocator = .init(std.heap.page_allocator);

    assert(!static_allocator.is_static());

    switch (case) {
        .allocate => allocated_frozen(&static_allocator),
        .deallocate => deallocated_frozen(&static_allocator),
        .exit => {
            static_allocator.transition_from_init_to_static();
            static_allocator.exit(exit_code);
        },
        .report => {
            static_allocator.report_allocates = true;

            allocated_frozen(&static_allocator);
        },
        .shift => shifted_past_end(),
    }

    std.process.exit(0);
}

fn allocated_frozen(static_allocator: *StaticAllocator) void {
    var scope = static_allocator.freeze_scope();
    defer scope.leave();

    assert(static_allocator.is_static());

    const memory = static_allocator.allocator().alloc(u8, probe_bytes) catch return;

    static_allocator.allocator().free(memory);
}

fn deallocated_frozen(static_allocator: *StaticAllocator) void {
    const memory = static_allocator.allocator().alloc(u8, probe_bytes) catch return;

    assert(memory.len == probe_bytes);

    var scope = static_allocator.freeze_scope();
    defer scope.leave();

    static_allocator.allocator().free(memory);
}

fn shifted_past_end() void {
    const span: Span = .{ .offset = probe_bytes, .length = probe_bytes };
    const moved = span.shifted(std.math.maxInt(u32) - probe_bytes);

    std.mem.doNotOptimizeAway(moved);
}
