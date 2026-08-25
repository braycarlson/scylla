const std = @import("std");

const Slice = []const u8;
const Pointer = *u32;
const ConstPointer = *const u32;
const Many = [*]u8;
const Sentinel = [*:0]u8;
const SliceSentinel = [:0]const u8;
const Array = [4]u32;
const ArraySentinel = [4:0]u8;
const Optional = ?u32;
const Nested = ?*const []u32;
const Aligned = *align(16) u32;
const Errors = error{One} || error{Two};
const Result = error{One}!u32;
const Function = fn (u32, u32) u32;
const Tuple = struct { u32, u32 };

fn typed(value: anytype) @TypeOf(value) {
    return value;
}

fn slices(one: []const u8, two: [:0]const u8) usize {
    return one.len + two.len;
}
