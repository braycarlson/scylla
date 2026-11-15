const std = @import("std");
const assert = std.debug.assert;
const Random = @import("../testing/random.zig");
const Span = @import("../stdx/bounded/span.zig");

pub fn write(source: []const u8, region: Span, holes: []const Span, out: []u8) u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(region.end() <= source.len);
    assert(out.len >= region.length);
    assert(holes.len <= std.math.maxInt(u32));

    const masked = out[0..region.length];

    @memcpy(masked, region.text(source));

    for (holes) |hole| {
        blank(region, hole, masked);
    }

    assert(masked.len == region.length);

    return region.length;
}

fn blank(region: Span, hole: Span, masked: []u8) void {
    assert(masked.len == region.length);
    assert(hole.length <= std.math.maxInt(u32) - hole.offset);

    const start = @max(hole.offset, region.offset);
    const end = @min(hole.end(), region.end());
    if (end <= start) return;

    const first = start - region.offset;
    const last = end - region.offset;

    assert(last <= masked.len);

    for (masked[first..last]) |*byte| {
        if (byte.* != '\n') byte.* = ' ';
    }
}

test "a region without holes copies verbatim" {
    var out: [32]u8 = undefined;
    const region: Span = .{ .offset = 6, .length = 6 };
    const written = write("before<body>after", region, &.{}, &out);

    try std.testing.expectEqual(6, written);
    try std.testing.expectEqualStrings("<body>", out[0..6]);
}

test "a hole is blanked and the length is preserved" {
    var out: [32]u8 = undefined;
    const region: Span = .{ .offset = 0, .length = 14 };
    const hole: Span = .{ .offset = 2, .length = 10 };
    const written = write("a {{ name }} b", region, &.{hole}, &out);

    try std.testing.expectEqual(14, written);
    try std.testing.expectEqualStrings("a            b", out[0..14]);
}

test "a hole keeps its line breaks" {
    var out: [32]u8 = undefined;
    const region: Span = .{ .offset = 0, .length = 26 };

    const holes = [_]Span{
        .{ .offset = 2, .length = 10 },
        .{ .offset = 13, .length = 11 },
    };

    const written = write("a {% if x %}\n{% endif %} b", region, &holes, &out);

    try std.testing.expectEqual(26, written);
    try std.testing.expect(std.mem.findScalar(u8, out[0..written], '\n') != null);
    try std.testing.expect(std.mem.findScalar(u8, out[0..12], '\n') == null);
    try std.testing.expectEqualStrings("a           \n            b", out[0..written]);
}

test "a hole outside the region changes nothing" {
    var out: [16]u8 = undefined;
    const region: Span = .{ .offset = 3, .length = 4 };

    const holes = [_]Span{
        .{ .offset = 0, .length = 2 },
        .{ .offset = 8, .length = 2 },
    };

    const written = write("0123456789", region, &holes, &out);

    try std.testing.expectEqual(4, written);
    try std.testing.expectEqualStrings("3456", out[0..4]);
}

test "a hole that straddles the region edge is clipped" {
    var out: [16]u8 = undefined;
    const region: Span = .{ .offset = 3, .length = 4 };
    const hole: Span = .{ .offset = 1, .length = 4 };
    const written = write("0123456789", region, &.{hole}, &out);

    try std.testing.expectEqual(4, written);
    try std.testing.expectEqualStrings("  56", out[0..4]);
}

test "byte soup masks without running off the region" {
    const alphabet = " \nabc{}";
    var random: Random = .init(0x51ED_270B_6996_1E71);
    var out: [256]u8 = undefined;
    var source_buffer: [200]u8 = undefined;

    for (0..256) |_| {
        const length = random.below(200) + 1;
        const source = source_buffer[0..length];

        for (source) |*byte| byte.* = alphabet[random.below(alphabet.len)];

        const offset = random.below(length);

        const region: Span = .{
            .offset = offset,
            .length = random.below(length - offset + 1),
        };

        const hole_length = random.below(32);

        const hole: Span = .{
            .offset = random.below(length),
            .length = hole_length,
        };

        const written = write(source, region, &.{hole}, &out);

        try std.testing.expectEqual(region.length, written);

        for (out[0..written], region.text(source)) |byte, held| {
            if (byte != held) try std.testing.expectEqual(' ', byte);
        }
    }
}

test "a prepared offset maps back by adding the region start" {
    var out: [32]u8 = undefined;
    const region: Span = .{ .offset = 3, .length = 18 };
    const hole: Span = .{ .offset = 8, .length = 7 };
    const written = write("xxx<div>{{ a }}</div>", region, &.{hole}, &out);
    const found = std.mem.find(u8, out[0..written], "</div>").?;

    try std.testing.expectEqual(15, found + region.offset);
}
