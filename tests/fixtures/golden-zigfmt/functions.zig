const std = @import("std");

fn add(left: u32, right: u32) u32 {
    return left + right;
}

pub fn divide(left: u32, right: u32) !u32 {
    if (right == 0) return error.DivideByZero;

    return left / right;
}

fn generic(comptime T: type, value: T) T {
    return value;
}

fn variadic(format: []const u8, arguments: anytype) void {
    _ = format;
    _ = arguments;
}

fn takesFunction(callback: fn (u32) u32) u32 {
    return callback(1);
}

inline fn small(value: u32) u32 {
    return value +% 1;
}

fn aligned() align(8) void {}

fn callConvention() callconv(.c) void {}

test "add sums its operands" {
    try std.testing.expectEqual(@as(u32, 3), add(1, 2));
}

test {
    try std.testing.expect(true);
}
