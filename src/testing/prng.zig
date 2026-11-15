const std = @import("std");
const assert = std.debug.assert;

state: [4]u64,

const PRNG = @This();
const attempt_count_max = 1 << 16;

pub fn init(seed: u64) PRNG {
    var mix = seed;

    const prng: PRNG = .{ .state = .{
        split_mix(&mix),
        split_mix(&mix),
        split_mix(&mix),
        split_mix(&mix),
    } };

    assert(mix != seed);
    assert(prng.state[0] | prng.state[1] | prng.state[2] | prng.state[3] != 0);

    return prng;
}

pub fn boolean(prng: *PRNG) bool {
    return prng.next() & 1 == 1;
}

pub fn enum_uniform(prng: *PRNG, comptime Enum: type) Enum {
    const values = comptime std.enums.values(Enum);

    comptime assert(values.len > 0);

    const index_chosen = prng.index(values.len);

    assert(index_chosen < values.len);

    return values[index_chosen];
}

fn fill(prng: *PRNG, target: []u8) void {
    assert(target.len <= std.math.maxInt(u32));

    var offset: usize = 0;

    while (offset < target.len) {
        var word = prng.next();
        const stop = @min(offset + 8, target.len);

        assert(stop > offset);

        while (offset < stop) : (offset += 1) {
            target[offset] = @truncate(word);
            word >>= 8;
        }
    }

    assert(offset == target.len);
}

pub fn index(prng: *PRNG, count: usize) usize {
    assert(count > 0);

    const chosen = prng.int_inclusive(usize, count - 1);

    assert(chosen < count);

    return chosen;
}

pub fn int(prng: *PRNG, comptime Int: type) Int {
    comptime assert(@typeInfo(Int).int.signedness == .unsigned);
    comptime assert(@bitSizeOf(Int) <= 64);

    return @truncate(prng.next());
}

pub fn int_inclusive(prng: *PRNG, comptime Int: type, max: Int) Int {
    comptime assert(@typeInfo(Int).int.signedness == .unsigned);
    comptime assert(@bitSizeOf(Int) <= 64);

    if (max == std.math.maxInt(Int)) return prng.int(Int);

    const bits = @typeInfo(Int).int.bits;
    const less_than = max + 1;
    var value = prng.int(Int);
    var product = std.math.mulWide(Int, value, less_than);
    var low: Int = @truncate(product);

    assert(less_than > 0);

    if (low < less_than) {
        const threshold = (0 -% less_than) % less_than;
        var attempt: u32 = 0;

        while (low < threshold) : (attempt += 1) {
            assert(attempt < attempt_count_max);

            value = prng.int(Int);
            product = std.math.mulWide(Int, value, less_than);
            low = @truncate(product);
        }
    }

    const result: Int = @intCast(product >> bits);

    assert(result <= max);

    return result;
}

pub fn range_inclusive(prng: *PRNG, comptime Int: type, min: Int, max: Int) Int {
    assert(min <= max);

    const result = min + prng.int_inclusive(Int, max - min);

    assert(result >= min);
    assert(result <= max);

    return result;
}

fn next(prng: *PRNG) u64 {
    const result = std.math.rotl(u64, prng.state[0] +% prng.state[3], 23) +% prng.state[0];
    const shifted = prng.state[1] << 17;

    prng.state[2] ^= prng.state[0];
    prng.state[3] ^= prng.state[1];
    prng.state[1] ^= prng.state[2];
    prng.state[0] ^= prng.state[3];
    prng.state[2] ^= shifted;
    prng.state[3] = std.math.rotl(u64, prng.state[3], 45);

    assert(prng.state[0] | prng.state[1] | prng.state[2] | prng.state[3] != 0);

    return result;
}

fn split_mix(mix: *u64) u64 {
    mix.* +%= 0x9e37_79b9_7f4a_7c15;

    var value = mix.*;

    value = (value ^ (value >> 30)) *% 0xbf58_476d_1ce4_e5b9;
    value = (value ^ (value >> 27)) *% 0x94d0_49bb_1331_11eb;

    return value ^ (value >> 31);
}

test PRNG {
    const fragments = [_][]const u8{ "fn", "const", "{" };
    var prng: PRNG = .init(0x5EED);
    var replay: PRNG = .init(0x5EED);

    for (0..64) |_| {
        const chosen = prng.index(fragments.len);

        try std.testing.expect(chosen < fragments.len);
        try std.testing.expectEqual(chosen, replay.index(fragments.len));
        try std.testing.expect(prng.int_inclusive(u8, 9) <= 9);
        try std.testing.expect(replay.int_inclusive(u8, 9) <= 9);
    }
}

test "an inclusive integer reaches every value up to its bound and none past it" {
    var prng: PRNG = .init(92);

    for (0..8) |bound| {
        var distribution: [8]u32 = @splat(0);

        for (0..256) |_| {
            distribution[prng.int_inclusive(u8, @intCast(bound))] += 1;
        }

        for (distribution[0 .. bound + 1]) |hits| try std.testing.expect(hits > 0);
        for (distribution[bound + 1 ..]) |hits| try std.testing.expectEqual(0, hits);
    }
}

test "a range reaches both of its ends" {
    var prng: PRNG = .init(92);

    for (0..8) |min| {
        for (min..8) |max| {
            var distribution: [8]u32 = @splat(0);

            for (0..256) |_| {
                distribution[prng.range_inclusive(usize, min, max)] += 1;
            }

            for (distribution, 0..) |hits, value| {
                const inside = min <= value and value <= max;

                try std.testing.expectEqual(inside, hits > 0);
            }
        }
    }
}

test "a seed reproduces its stream" {
    var first: PRNG = .init(0xDEAD_BEEF);
    var second: PRNG = .init(0xDEAD_BEEF);
    var other: PRNG = .init(0xDEAD_BEEF + 1);
    var differs = false;

    for (0..64) |_| {
        const value = first.int(u64);

        try std.testing.expectEqual(value, second.int(u64));

        if (value != other.int(u64)) differs = true;
    }

    try std.testing.expect(differs);
}

test "a fill covers every byte of its target" {
    var prng: PRNG = .init(32);
    var buffer: [67]u8 = undefined;

    for (0..buffer.len + 1) |size| {
        var touched: [67]bool = @splat(false);

        for (0..4) |_| {
            @memset(buffer[0..size], 0);
            prng.fill(buffer[0..size]);

            for (buffer[0..size], 0..) |byte, position| {
                if (byte != 0) touched[position] = true;
            }
        }

        for (touched[0..size]) |hit| try std.testing.expect(hit);
    }
}

test "a boolean lands on both sides" {
    var prng: PRNG = .init(92);
    var heads: u32 = 0;

    for (0..1_000) |_| {
        if (prng.boolean()) heads += 1;
    }

    try std.testing.expect(heads > 400);
    try std.testing.expect(heads < 600);
}

test "a uniform enum draws every variant" {
    const Color = enum { red, green, blue };
    var prng: PRNG = .init(7);
    var seen: [3]bool = @splat(false);

    for (0..64) |_| {
        seen[@backingInt(prng.enum_uniform(Color))] = true;
    }

    try std.testing.expect(seen[0]);
    try std.testing.expect(seen[1]);
    try std.testing.expect(seen[2]);
}

test "an index covers every position of its count" {
    var prng: PRNG = .init(41);
    var seen: [5]bool = @splat(false);

    for (0..256) |_| {
        seen[prng.index(seen.len)] = true;
    }

    for (seen) |hit| try std.testing.expect(hit);

    try std.testing.expectEqual(0, prng.index(1));
}
