const std = @import("std");
const assert = std.debug.assert;
const PRNG = @import("prng.zig");

pub const Arguments = struct {
    seed: u64,
    events_max: ?u32,
};

pub fn parse_seed(text: []const u8) error{InvalidSeed}!u64 {
    if (text.len == 0) return error.InvalidSeed;

    if (text.len == git_commit_length) {
        comptime assert(git_commit_length * 4 == @bitSizeOf(u160));

        const commit = std.fmt.parseUnsigned(u160, text, 16) catch return error.InvalidSeed;
        const seed: u64 = @truncate(commit);

        assert(@as(u160, seed) == commit & std.math.maxInt(u64));

        return seed;
    }

    const seed = std.fmt.parseUnsigned(u64, text, 10) catch return error.InvalidSeed;

    assert(text.len < git_commit_length);

    return seed;
}

pub fn rows_equal(comptime Row: type, expected: []const Row, actual: []const Row) bool {
    if (expected.len != actual.len) return false;

    for (expected, actual) |first, second| {
        if (!std.meta.eql(first, second)) return false;
    }

    return true;
}

pub fn source_generate(prng: *PRNG, fragments: []const []const u8, buffer: []u8) []const u8 {
    assert(fragments.len > 0);
    assert(buffer.len > 0);

    const fragment_count = prng.int_inclusive(u32, fragment_count_max);
    var length: u32 = 0;

    for (0..fragment_count) |_| {
        const fragment = fragments[prng.index(fragments.len)];
        if (length + fragment.len > buffer.len) break;

        @memcpy(buffer[length..][0..fragment.len], fragment);
        length += @intCast(fragment.len);
    }

    assert(length <= buffer.len);

    return buffer[0..length];
}

const fragment_count_max = 256;
const git_commit_length = 40;

test "a seed reads as a decimal or as a commit hash" {
    try std.testing.expectEqual(123, try parse_seed("123"));

    try std.testing.expectEqual(
        0xfedcba9876543210,
        try parse_seed("0123456789abcdef0123456789abcdeffedcba9876543210"[8..]),
    );

    try std.testing.expectError(error.InvalidSeed, parse_seed(""));
    try std.testing.expectError(error.InvalidSeed, parse_seed("seed"));
}

test "a generated source joins whole fragments within its buffer" {
    var prng = PRNG.init(7);
    var buffer: [16]u8 = undefined;

    for (0..64) |_| {
        const source = source_generate(&prng, &.{ "ab", "c" }, &buffer);
        const pairs = std.mem.count(u8, source, "ab");
        const seconds = std.mem.countScalar(u8, source, 'b');

        try std.testing.expect(source.len <= buffer.len);
        try std.testing.expectEqual(pairs, seconds);
    }
}

test "rows compare by every field" {
    const Row = struct { first: u16, second: u32 };
    const left = [_]Row{ .{ .first = 1, .second = 2 }, .{ .first = 3, .second = 4 } };
    const right = [_]Row{ .{ .first = 1, .second = 2 }, .{ .first = 3, .second = 5 } };

    try std.testing.expect(rows_equal(Row, &left, &left));
    try std.testing.expect(!rows_equal(Row, &left, &right));
    try std.testing.expect(!rows_equal(Row, &left, left[0..1]));
}
