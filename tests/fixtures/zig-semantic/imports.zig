const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;

fn run(one: []const u8) usize {
    return mem.len(one) + @intFromBool(builtin.is_test);
}
