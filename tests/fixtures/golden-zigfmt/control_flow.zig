const std = @import("std");

fn run(values: []const u32, flag: bool) u32 {
    var total: u32 = 0;

    if (flag) {
        total += 1;
    } else if (values.len > 0) {
        total += 2;
    } else {
        total = 3;
    }

    const picked = if (flag) values.len else 0;

    total += @intCast(picked);

    var index: usize = 0;

    while (index < values.len) : (index += 1) {
        total += values[index];
    }

    while (index > 0) {
        index -= 1;
    }

    outer: for (values) |value| {
        if (value == 0) continue :outer;
        if (value == 1) break :outer;

        total += value;
    }

    for (values, 0..) |value, position| {
        total += value + @as(u32, @intCast(position));
    }

    inline for (.{ 1, 2 }) |held| {
        total += held;
    }

    switch (total) {
        0 => {},
        1, 2 => total = 4,
        3...9 => total = 5,
        else => |other| total = other,
    }

    const named = blk: {
        break :blk total;
    };

    defer total = 0;
    errdefer |failure| std.debug.print("{}\n", .{failure});

    comptime {
        var held: u32 = 0;
        held += 1;
    }

    return named;
}

fn waited() void {
    suspend {}

    nosuspend held();

    resume frame;
}

var frame: anyframe = undefined;
var typed: anyframe->u32 = undefined;
