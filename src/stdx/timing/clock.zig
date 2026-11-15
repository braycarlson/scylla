const std = @import("std");
const assert = std.debug.assert;

io: std.Io,
started: std.Io.Timestamp,

const Clock = @This();

pub fn init(io: std.Io) Clock {
    const started = std.Io.Timestamp.now(io, .awake);

    assert(started.nanoseconds >= 0);

    return .{ .io = io, .started = started };
}

pub fn nanoseconds(clock: *const Clock) u64 {
    assert(clock.started.nanoseconds >= 0);

    const elapsed = clock.started.untilNow(clock.io, .awake).toNanoseconds();

    assert(elapsed >= 0);
    assert(elapsed <= std.math.maxInt(u64));

    return @intCast(elapsed);
}

test Clock {
    const clock: Clock = .init(std.testing.io);
    const elapsed = clock.nanoseconds();

    try std.testing.expect(elapsed < std.math.maxInt(u64));
    try std.testing.expect(clock.nanoseconds() >= elapsed);
}

test "a clock reads forward on a frozen thread" {
    const clock: Clock = .init(std.testing.io);
    const nanoseconds_before = clock.nanoseconds();
    const nanoseconds_after = clock.nanoseconds();

    try std.testing.expect(nanoseconds_before <= nanoseconds_after);
    try std.testing.expect(nanoseconds_after < std.math.maxInt(u64));
}
