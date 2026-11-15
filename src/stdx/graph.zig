const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("bounded/array.zig").ArrayType;

pub const Scratch = struct {
    index: ArrayType(u32),
    low: ArrayType(u32),
    order: ArrayType(u32),
    pending: ArrayType(u32),
    resident: ArrayType(bool),
    stack: ArrayType(u32),

    pub fn init(gpa: std.mem.Allocator, node_count_max: u32) std.mem.Allocator.Error!Scratch {
        assert(node_count_max > 0);

        var index: ArrayType(u32) = try .init(gpa, node_count_max);
        errdefer index.deinit(gpa);

        var low: ArrayType(u32) = try .init(gpa, node_count_max);
        errdefer low.deinit(gpa);

        var order: ArrayType(u32) = try .init(gpa, node_count_max);
        errdefer order.deinit(gpa);

        var pending: ArrayType(u32) = try .init(gpa, node_count_max);
        errdefer pending.deinit(gpa);

        var resident: ArrayType(bool) = try .init(gpa, node_count_max);
        errdefer resident.deinit(gpa);

        const scratch: Scratch = .{
            .index = index,
            .low = low,
            .order = order,
            .pending = pending,
            .resident = resident,
            .stack = try .init(gpa, node_count_max),
        };

        assert(scratch.capacity() == node_count_max);
        assert(scratch.stack.empty());

        return scratch;
    }

    pub fn deinit(scratch: *Scratch, gpa: std.mem.Allocator) void {
        assert(scratch.capacity() > 0);
        assert(scratch.stack.count() <= scratch.capacity());

        scratch.index.deinit(gpa);
        scratch.low.deinit(gpa);
        scratch.order.deinit(gpa);
        scratch.pending.deinit(gpa);
        scratch.resident.deinit(gpa);
        scratch.stack.deinit(gpa);
        scratch.* = undefined;
    }

    fn enter(scratch: *Scratch, node: u32, counter: *u32) void {
        assert(scratch.index.get(node) == unvisited);
        assert(counter.* < scratch.index.count());

        scratch.index.slice()[node] = counter.*;
        scratch.low.slice()[node] = counter.*;
        scratch.order.slice()[node] = 0;
        scratch.resident.slice()[node] = true;
        counter.* += 1;

        scratch.pending.push(node);
        scratch.stack.push(node);
    }

    fn pending_last(scratch: *const Scratch) ?u32 {
        const pending = scratch.pending.const_slice();
        if (pending.len == 0) return null;

        const node = pending[pending.len - 1];

        assert(node < scratch.index.count());
        assert(scratch.index.get(node) != unvisited);

        return node;
    }

    fn reset(scratch: *Scratch, node_count: u32) void {
        assert(node_count <= scratch.capacity());

        scratch.index.clear();
        scratch.low.clear();
        scratch.order.clear();
        scratch.pending.clear();
        scratch.resident.clear();
        scratch.stack.clear();

        for (0..node_count) |_| {
            scratch.index.push(unvisited);
            scratch.low.push(0);
            scratch.order.push(0);
            scratch.resident.push(false);
        }

        assert(scratch.index.count() == node_count);
        assert(scratch.resident.count() == node_count);
    }

    fn step(scratch: *Scratch, current: u32, target: u32, counter: *u32) void {
        assert(scratch.resident.get(current));
        assert(target < scratch.index.count());

        if (target == current) return;

        if (scratch.index.get(target) == unvisited) {
            scratch.enter(target, counter);

            return;
        }

        if (!scratch.resident.get(target)) return;

        const low = @min(scratch.low.get(current), scratch.index.get(target));

        scratch.low.slice()[current] = low;
    }

    pub fn capacity(scratch: *const Scratch) u32 {
        const held = scratch.index.capacity();

        assert(scratch.resident.capacity() == held);
        assert(scratch.stack.capacity() == held);

        return held;
    }
};

const fixture_edge_count_max: u32 = 8;
const fixture_member_count_max: u32 = 4;
const fixture_node_count_max: u32 = 4;
const unvisited: u32 = std.math.maxInt(u32);

pub fn components(
    comptime Topology: type,
    comptime Visitor: type,
    node_count: u32,
    scratch: *Scratch,
    topology: *const Topology,
    visitor: *Visitor,
) error{Truncated}!void {
    assert(node_count < std.math.maxInt(u32));

    comptime topology_check(Topology);
    comptime visitor_check(Visitor);

    scratch.reset(node_count);

    const step_max = step_max_of(Topology, node_count, topology);
    var counter: u32 = 0;

    for (0..node_count) |root_index| {
        const root: u32 = @intCast(root_index);
        if (scratch.index.get(root) != unvisited) continue;
        if (!topology.holds(root)) continue;

        scratch.enter(root, &counter);
        try walk(Topology, Visitor, scratch, &counter, topology, visitor, step_max);
    }

    assert(counter <= node_count);
    assert(scratch.pending.empty());
}

fn walk(
    comptime Topology: type,
    comptime Visitor: type,
    scratch: *Scratch,
    counter: *u32,
    topology: *const Topology,
    visitor: *Visitor,
    step_max: u64,
) error{Truncated}!void {
    assert(scratch.pending.count() == 1);
    assert(step_max > 0);

    for (0..@intCast(step_max)) |_| {
        const current = scratch.pending_last() orelse return;
        const cursor = scratch.order.get(current);

        if (cursor < topology.edge_count_of(current)) {
            scratch.order.slice()[current] = cursor + 1;

            const target = topology.edge_target_of(current, cursor) orelse continue;

            if (topology.holds(target)) scratch.step(current, target, counter);

            continue;
        }

        _ = scratch.pending.pop();

        if (scratch.low.get(current) == scratch.index.get(current)) {
            try component_close(Topology, Visitor, scratch, current, topology, visitor);
        }

        const parent = scratch.pending_last() orelse continue;
        const low = @min(scratch.low.get(parent), scratch.low.get(current));

        scratch.low.slice()[parent] = low;
    }

    assert(scratch.pending.empty());
}

fn component_close(
    comptime Topology: type,
    comptime Visitor: type,
    scratch: *Scratch,
    root: u32,
    topology: *const Topology,
    visitor: *Visitor,
) error{Truncated}!void {
    assert(root < std.math.maxInt(u32));

    const stack = scratch.stack.const_slice();
    var position: usize = stack.len;

    for (0..stack.len) |_| {
        position -= 1;

        if (stack[position] == root) break;
    }

    const members = stack[position..];

    assert(members.len > 0);
    assert(members.len <= scratch.capacity());

    for (members) |member| {
        scratch.resident.slice()[member] = false;
    }

    const cycle = members.len > 1;
    const looping = cycle or (topology.holds(root) and names_itself(Topology, root, topology));
    const result = visitor.component(members, looping);

    scratch.stack.truncate(@intCast(position));

    return result;
}

fn names_itself(comptime Topology: type, node: u32, topology: *const Topology) bool {
    assert(topology.holds(node));

    const edge_count = topology.edge_count_of(node);

    for (0..edge_count) |ordinal| {
        const target = topology.edge_target_of(node, @intCast(ordinal)) orelse continue;
        if (target == node) return true;
    }

    return false;
}

fn step_max_of(comptime Topology: type, node_count: u32, topology: *const Topology) u64 {
    assert(node_count < std.math.maxInt(u32));

    var total: u64 = 0;

    for (0..node_count) |node_index| {
        const node: u32 = @intCast(node_index);
        if (!topology.holds(node)) continue;

        total += @as(u64, topology.edge_count_of(node)) + 1;
    }

    assert(total <= @as(u64, node_count) << 32);
    if (node_count == 0) assert(total == 0);

    return total;
}

fn topology_check(comptime Topology: type) void {
    assert(@hasDecl(Topology, "edge_count_of"));
    assert(@hasDecl(Topology, "edge_target_of"));
    assert(@hasDecl(Topology, "holds"));
}

fn visitor_check(comptime Visitor: type) void {
    assert(@hasDecl(Visitor, "component"));

    const Component = @TypeOf(Visitor.component);

    assert(@typeInfo(Component).@"fn".param_types.len == 3);
}

const Listed = struct {
    edges: []const [2]u32,

    pub fn edge_count_of(listed: *const Listed, node: u32) u32 {
        var total: u32 = 0;

        assert(listed.edges.len <= fixture_edge_count_max);

        for (listed.edges) |edge| {
            if (edge[0] == node) total += 1;
        }

        assert(total <= listed.edges.len);

        return total;
    }

    pub fn edge_target_of(listed: *const Listed, node: u32, ordinal: u32) ?u32 {
        var seen: u32 = 0;

        assert(ordinal < listed.edge_count_of(node));

        for (listed.edges) |edge| {
            if (edge[0] != node) continue;
            if (seen == ordinal) return edge[1];

            seen += 1;
        }

        assert(seen <= ordinal);

        return null;
    }

    pub fn holds(listed: *const Listed, node: u32) bool {
        assert(node < fixture_node_count_max);
        assert(listed.edges.len <= fixture_edge_count_max);

        return true;
    }
};

const Recorded = struct {
    looping: bool,
    member_count: u32,
    members: [fixture_member_count_max]u32,

    fn slice(recorded: *const Recorded) []const u32 {
        assert(recorded.member_count > 0);
        assert(recorded.member_count <= fixture_member_count_max);

        return recorded.members[0..recorded.member_count];
    }
};

const Recorder = struct {
    seen: [fixture_node_count_max]Recorded,
    total: u32,

    pub fn component(
        recorder: *Recorder,
        members: []const u32,
        looping: bool,
    ) error{Truncated}!void {
        assert(members.len > 0);
        assert(members.len <= fixture_member_count_max);

        if (recorder.total == recorder.seen.len) return error.Truncated;

        const held = &recorder.seen[recorder.total];

        held.looping = looping;
        held.member_count = @intCast(members.len);

        @memcpy(held.members[0..members.len], members);
        std.mem.sort(u32, held.members[0..members.len], {}, std.sort.asc(u32));
        recorder.total += 1;
    }

    fn looping_count(recorder: *const Recorder) u32 {
        var total: u32 = 0;

        assert(recorder.total <= fixture_node_count_max);

        for (recorder.seen[0..recorder.total]) |held| {
            if (held.looping) total += 1;
        }

        assert(total <= recorder.total);

        return total;
    }

    fn looping_first(recorder: *const Recorder) ?*const Recorded {
        assert(recorder.total <= fixture_node_count_max);

        for (recorder.seen[0..recorder.total]) |*held| {
            if (held.looping) return held;
        }

        assert(recorder.looping_count() == 0);

        return null;
    }
};

const Stopping = struct {
    seen: u32,

    pub fn component(
        stopping: *Stopping,
        members: []const u32,
        looping: bool,
    ) error{Truncated}!void {
        assert(members.len > 0);
        assert(members.len <= fixture_member_count_max);

        _ = looping;
        stopping.seen += 1;

        return error.Truncated;
    }
};

const Unresolved = struct {
    edge_count: u32,

    pub fn edge_count_of(unresolved: *const Unresolved, node: u32) u32 {
        assert(node < fixture_node_count_max);
        assert(unresolved.edge_count <= fixture_edge_count_max);

        return unresolved.edge_count;
    }

    pub fn edge_target_of(unresolved: *const Unresolved, node: u32, ordinal: u32) ?u32 {
        assert(node < fixture_node_count_max);
        assert(ordinal < unresolved.edge_count);

        return null;
    }

    pub fn holds(unresolved: *const Unresolved, node: u32) bool {
        assert(node < fixture_node_count_max);
        assert(unresolved.edge_count <= fixture_edge_count_max);

        return true;
    }
};

const Whole = struct {
    seen: u32,

    pub fn component(whole: *Whole, members: []const u32, looping: bool) error{Truncated}!void {
        assert(!looping);
        assert(members.len > 0);

        whole.seen += 1;
    }
};

fn walked(node_count: u32, edges: []const [2]u32) !Recorder {
    assert(node_count < std.math.maxInt(u32));
    assert(edges.len <= std.math.maxInt(u32));

    var scratch: Scratch = try .init(std.testing.allocator, @max(node_count, 1));
    defer scratch.deinit(std.testing.allocator);

    const topology: Listed = .{ .edges = edges };
    var recorder: Recorder = .{ .seen = undefined, .total = 0 };

    try components(Listed, Recorder, node_count, &scratch, &topology, &recorder);

    assert(recorder.total <= node_count);
    assert(scratch.stack.empty());

    return recorder;
}

test "a graph without a cycle loops nowhere" {
    const recorder = try walked(3, &.{ .{ 0, 1 }, .{ 1, 2 } });

    try std.testing.expectEqual(3, recorder.total);
    try std.testing.expectEqual(0, recorder.looping_count());
}

test "a self edge loops on its own" {
    const recorder = try walked(2, &.{ .{ 0, 0 }, .{ 0, 1 } });

    try std.testing.expectEqual(1, recorder.looping_count());
    try std.testing.expectEqualSlices(u32, &.{0}, recorder.looping_first().?.slice());
}

test "a cycle of three loops as one component" {
    const recorder = try walked(3, &.{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 0 } });

    try std.testing.expectEqual(1, recorder.looping_count());
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, recorder.looping_first().?.slice());
}

test "an unresolved edge reaches nothing" {
    var scratch: Scratch = try .init(std.testing.allocator, 2);
    defer scratch.deinit(std.testing.allocator);

    const topology: Unresolved = .{ .edge_count = 1 };
    var whole: Whole = .{ .seen = 0 };

    try components(Unresolved, Whole, 2, &scratch, &topology, &whole);
    try std.testing.expectEqual(2, whole.seen);
}

test "a visitor that stops ends the walk" {
    var scratch: Scratch = try .init(std.testing.allocator, 4);
    defer scratch.deinit(std.testing.allocator);

    const topology: Unresolved = .{ .edge_count = 0 };
    var stopping: Stopping = .{ .seen = 0 };
    const held = components(Unresolved, Stopping, 4, &scratch, &topology, &stopping);

    try std.testing.expectError(error.Truncated, held);
    try std.testing.expectEqual(1, stopping.seen);
}
