const std = @import("std");

const Point = struct { x: i32, y: i32 };

fn run(values: []const u32) void {
    const sum = 1 + 2 * 3 - 4 / 5 % 6;
    const bits = (1 << 2) | (3 >> 1) & 4 ^ 5;
    const logic = true and false or !true;
    const compare = 1 == 2 or 3 != 4 or 5 < 6 or 7 > 8 or 9 <= 10 or 11 >= 12;
    const wrapped = 1 +% 2 -% 3 *% 4;
    const saturating = 1 +| 2 -| 3 *| 4;
    const joined = "left" ++ "right";
    const repeated = "ab" ** 3;
    const optional: ?u32 = null;
    const unwrapped = optional orelse 0;
    const forced = optional.?;
    const pointer = &sum;
    const pointed = pointer.*;
    const slice = values[1..3];
    const opened = values[1..];
    const one = values[0];
    const point = Point{ .x = 1, .y = 2 };
    const anonymous: Point = .{ .x = 3, .y = 4 };
    const array = [_]u32{ 1, 2, 3 };
    const tuple = .{ 1, "two", 3.0 };
    const nested = std.mem.eql(u8, "a", "b");
    const negated = -sum;
    const inverted = ~bits;
    const grouped = (sum + 1) * 2;
    const literal = 'x';
    const text =
        \\one
        \\two
    ;

    _ = .{
        bits,
        logic,
        compare,
        wrapped,
        saturating,
        joined,
        repeated,
        unwrapped,
        forced,
        pointed,
        slice,
        opened,
        one,
        point,
        anonymous,
        array,
        tuple,
        nested,
        negated,
        inverted,
        grouped,
        literal,
        text,
    };
}

// The compound assignments and the saturating forms no other fixture carries.
pub fn assigned(held: *u32) void {
    held.* += 1;
    held.* -= 1;
    held.* *= 2;
    held.* /= 2;
    held.* %= 2;
    held.* &= 1;
    held.* |= 1;
    held.* ^= 1;
    held.* <<= 1;
    held.* >>= 1;
    held.* +%= 1;
    held.* -%= 1;
    held.* *%= 2;
    held.* +|= 1;
    held.* -|= 1;
    held.* *|= 2;
    held.* <<|= 1;
}

fn saturating(held: u32) u32 {
    return held <<| 1;
}

fn wrapped(held: i32) i32 {
    return -%held;
}

fn destructured(pair: struct { u32, u32 }) void {
    const left, const right = pair;

    _ = left;
    _ = right;
}

fn stopped() noreturn {
    unreachable;
}

fn assembled(held: u32) u32 {
    return asm volatile ("mov %[held], %[out]"
        : [out] "=r" (-> u32),
        : [held] "r" (held),
    );
}
