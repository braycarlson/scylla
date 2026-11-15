const std = @import("std");
const assert = std.debug.assert;
const Id = @import("rpc.zig").Id;

slots: []Slot,

const Pending = @This();

pub const Cancellation = struct {
    generation: u32,
    state: *const std.atomic.Value(u32),

    pub fn is_cancelled(token: *const Cancellation) bool {
        const state = token.state.load(.acquire);
        const moved = state >> 1 != token.generation;

        assert(token.generation > 0);
        if (!moved) assert(state >> 1 > 0);

        return moved or state & cancelled_bit == cancelled_bit;
    }
};

pub const Error = error{
    IdOutgrown,
    PendingOutgrown,
};

pub fn init(gpa: std.mem.Allocator, pending_count_max: u32) error{OutOfMemory}!Pending {
    assert(pending_count_max > 0);

    const slots = try gpa.alloc(Slot, pending_count_max);

    for (slots) |*slot| slot.* = .{ .key = .empty, .state = .init(0), .used = false };

    assert(slots.len == pending_count_max);

    return .{ .slots = slots };
}

pub fn deinit(pending: *Pending, gpa: std.mem.Allocator) void {
    assert(pending.slots.len > 0);

    gpa.free(pending.slots);
    pending.* = undefined;
}

pub fn cancel(pending: *Pending, id: Id) bool {
    assert(id != .absent);

    const slot = pending.find(id) orelse return false;
    const state = slot.state.load(.acquire);

    assert(slot.used);
    assert(state >> 1 > 0);

    slot.state.store(state | cancelled_bit, .release);
    slot.used = false;

    return true;
}

pub fn cancellation(pending: *Pending, id: Id) ?Cancellation {
    assert(id != .absent);

    const slot = pending.find(id) orelse return null;
    const generation = slot.state.load(.acquire) >> 1;
    const held: Cancellation = .{ .generation = generation, .state = &slot.state };

    assert(slot.used);
    assert(held.generation > 0);

    return held;
}

pub fn complete(pending: *Pending, id: Id) bool {
    assert(id != .absent);

    const slot = pending.find(id) orelse return false;

    assert(slot.used);

    slot.used = false;

    assert(pending.find(id) == null);

    return true;
}

pub fn register(pending: *Pending, id: Id) Error!void {
    assert(id.is_request());
    assert(pending.find(id) == null);

    const key = try Key.of(id);

    for (pending.slots) |*slot| {
        if (slot.used) continue;

        const generation = (slot.state.load(.acquire) >> 1) + 1;

        slot.key = key;
        slot.used = true;
        slot.state.store(generation << 1, .release);

        assert(pending.find(id) == slot);

        return;
    }

    return error.PendingOutgrown;
}

fn find(pending: *Pending, id: Id) ?*Slot {
    assert(id != .absent);

    const key = Key.of(id) catch return null;

    for (pending.slots) |*slot| {
        if (!slot.used) continue;
        if (slot.key.equals(&key)) return slot;
    }

    return null;
}

const Key = struct {
    bytes: [id_bytes_max]u8,
    length: u8,
    number: i64,
    quoted: bool,

    const empty: Key = .{ .bytes = @splat(0), .length = 0, .number = 0, .quoted = false };

    fn of(id: Id) Error!Key {
        assert(id != .absent);

        var key: Key = .empty;

        switch (id) {
            .absent => unreachable,
            .number => |value| key.number = value,
            .string => |text| {
                if (text.len > id_bytes_max) return error.IdOutgrown;

                @memcpy(key.bytes[0..text.len], text);
                key.length = @intCast(text.len);
                key.quoted = true;
            },
        }

        assert(key.length <= id_bytes_max);

        return key;
    }

    fn equals(key: *const Key, other: *const Key) bool {
        if (key.quoted != other.quoted) return false;
        if (!key.quoted) return key.number == other.number;

        return std.mem.eql(u8, key.bytes[0..key.length], other.bytes[0..other.length]);
    }
};

const Slot = struct {
    key: Key,
    state: std.atomic.Value(u32),
    used: bool,
};

const cancelled_bit: u32 = 1;
const id_bytes_max = 64;
const pending_count_test: u32 = 8;

comptime {
    assert(id_bytes_max <= std.math.maxInt(u8));
}

fn id_test(number: i64) Id {
    assert(number > 0);

    return .{ .number = number };
}

test "a registered request is pending until it completes" {
    var pending: Pending = try .init(std.testing.allocator, pending_count_test);
    defer pending.deinit(std.testing.allocator);

    try pending.register(id_test(1));

    try std.testing.expect(pending.complete(id_test(1)));
    try std.testing.expect(!pending.complete(id_test(1)));
}

test "a request answered twice is only pending once" {
    var pending: Pending = try .init(std.testing.allocator, pending_count_test);
    defer pending.deinit(std.testing.allocator);

    try pending.register(id_test(1));

    try std.testing.expect(pending.complete(id_test(1)));
    try std.testing.expect(!pending.complete(id_test(1)));
}

test "cancelling flips the token the worker already holds" {
    var pending: Pending = try .init(std.testing.allocator, pending_count_test);
    defer pending.deinit(std.testing.allocator);

    try pending.register(id_test(1));

    const held = pending.cancellation(id_test(1)) orelse return error.TestExpectedToken;

    try std.testing.expect(!held.is_cancelled());
    try std.testing.expect(pending.cancel(id_test(1)));
    try std.testing.expect(held.is_cancelled());
    try std.testing.expect(!pending.complete(id_test(1)));
}

test "cancelling a request that already answered says nothing" {
    var pending: Pending = try .init(std.testing.allocator, pending_count_test);
    defer pending.deinit(std.testing.allocator);

    try pending.register(id_test(1));

    try std.testing.expect(pending.complete(id_test(1)));
    try std.testing.expect(!pending.cancel(id_test(1)));
}

test "a request that never registered hands out no token" {
    var pending: Pending = try .init(std.testing.allocator, pending_count_test);
    defer pending.deinit(std.testing.allocator);

    try std.testing.expect(pending.cancellation(id_test(9)) == null);
}

test "the same token is handed out every time" {
    var pending: Pending = try .init(std.testing.allocator, pending_count_test);
    defer pending.deinit(std.testing.allocator);

    try pending.register(id_test(1));

    const first = pending.cancellation(id_test(1)) orelse return error.TestExpectedToken;
    const second = pending.cancellation(id_test(1)) orelse return error.TestExpectedToken;

    try std.testing.expect(pending.cancel(id_test(1)));
    try std.testing.expect(first.is_cancelled());
    try std.testing.expect(second.is_cancelled());
}

test "a reused slot leaves the earlier token cancelled" {
    var pending: Pending = try .init(std.testing.allocator, 1);
    defer pending.deinit(std.testing.allocator);

    try pending.register(id_test(1));

    const first = pending.cancellation(id_test(1)) orelse return error.TestExpectedToken;

    try std.testing.expect(pending.complete(id_test(1)));
    try pending.register(.{ .string = "two" });

    const second = pending.cancellation(.{ .string = "two" }) orelse {
        return error.TestExpectedToken;
    };

    try std.testing.expect(first.is_cancelled());
    try std.testing.expect(!second.is_cancelled());
    try std.testing.expectError(error.PendingOutgrown, pending.register(id_test(3)));
}
