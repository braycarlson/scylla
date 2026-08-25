const std = @import("std");

pub const minimum_zig_version = "0.16.0";

pub fn build(builder: *std.Build) void {
    const target = builder.standardTargetOptions(.{});
    const optimize = builder.standardOptimizeOption(.{});
    const exe = builder.addExecutable(.{
        .name = "oracle-zig",
        .root_module = builder.createModule(.{
            .root_source_file = builder.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    builder.installArtifact(exe);
}
