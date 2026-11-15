const std = @import("std");
const assert = std.debug.assert;
const Random = @This();

state: u64,

pub fn init(seed: u64) Random {
    assert(seed > 0);

    const random: Random = .{ .state = seed };

    assert(random.state == seed);

    return random;
}

pub fn below(random: *Random, bound: u32) u32 {
    assert(bound > 0);

    const value = random.next() % bound;

    assert(value < bound);

    return @intCast(value);
}

pub fn next(random: *Random) u64 {
    var state = random.state;

    assert(state > 0);

    state ^= state << 13;
    state ^= state >> 7;
    state ^= state << 17;

    assert(state > 0);

    random.state = state;

    return state;
}

test Random {
    var random: Random = .init(0x2545_F491_4F6C_DD1D);
    var replay: Random = .init(0x2545_F491_4F6C_DD1D);

    for (0..64) |_| {
        const roll = random.below(6);

        try std.testing.expect(roll < 6);
        try std.testing.expectEqual(roll, replay.below(6));
    }
}

test "a random sequence repeats the xorshift the rust tests draw from" {
    var random: Random = .init(0x51ED_270B_6996_1E71);
    const first = random.next();
    const second = random.next();
    const third = random.next();

    try std.testing.expectEqual(0x51bd_e0b4_c516_8e0d, first);
    try std.testing.expectEqual(0xb1bc_5f1b_385c_8051, second);
    try std.testing.expectEqual(0x36ea_946c_9324_0d11, third);
}

test "a draw below a bound is the remainder of the next value" {
    var random: Random = .init(0x51ED_270B_6996_1E71);
    const wide = random.below(200);
    const narrow = random.below(1);

    try std.testing.expectEqual(13, wide);
    try std.testing.expectEqual(0, narrow);
}
