const std = @import("std");

const Set = enum {
    @"GLSL.std.450",
    @"OpenCL.std",
};

fn run(set: Set) bool {
    std.debug.assert(set != .@"OpenCL.std");

    return set == .@"GLSL.std.450";
}
