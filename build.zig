const std = @import("std");
const assert = std.debug.assert;
const partitions = @import("src/testing/partitions.zig").partitions;
const example_name = "parse";
const example_root = "examples/parse.zig";

const Modules = struct {
    json: *std.Build.Module,
    scylla: *std.Build.Module,
};

const supported_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &.{};

    const steps = .{
        .check = b.step("check", "Compile every artifact for Linux and Windows"),
        .ci = b.step("ci", "Run every check, test, and fuzz smoke"),
        .example = b.step("example", "Build and run the example against the module"),
        .fuzz = b.step("fuzz", "Run a fuzzer: zig build fuzz -- <fuzzer> [seed]"),
        .fuzz_build = b.step("fuzz:build", "Compile the fuzzers without running them"),
        .parity = b.step("parity", "Build the parity dumper"),
        .@"test" = b.step("test", "Run every test suite and the format check"),
        .test_fmt = b.step("test:fmt", "Check that every source file is formatted"),
        .test_unit = b.step("test:unit", "Run the unit tests and the tidy check"),
    };

    const json = b.dependency("json", .{}).module("json");

    const module = b.addModule("scylla", .{
        .root_source_file = b.path("src/scylla.zig"),
        .imports = &.{.{ .name = "json", .module = json }},
    });

    const parity = executable(b, &target, "parity", "src/parity.zig");
    const fuzz = executable(b, &target, "fuzz", "src/fuzz_tests.zig");
    const probe = executable(b, &target, "guard_probe", "src/guard_probe.zig");
    const probe_install = b.addInstallArtifact(probe, .{});

    tests_wired(b, &target, optimize, json, filters, &probe_install.step, steps.test_unit);
    checks_wired(b, optimize, .{ .json = json, .scylla = module }, filters, steps.check);

    const fuzz_run = b.addRunArtifact(fuzz);

    fuzz_run.addPassthruArgs();

    const fuzz_smoke = b.addRunArtifact(fuzz);

    fuzz_smoke.addArg("smoke");

    const example_run = b.addRunArtifact(example(b, &target, optimize, module));

    const fmt = b.addFmt(.{
        .paths = b.pathList(&.{ "build.zig", "examples", "src" }),
        .check = true,
    });

    steps.example.dependOn(&example_run.step);
    steps.parity.dependOn(&b.addInstallArtifact(parity, .{}).step);
    steps.fuzz.dependOn(&fuzz_run.step);
    steps.fuzz_build.dependOn(&b.addInstallArtifact(fuzz, .{}).step);
    steps.test_fmt.dependOn(&fmt.step);
    steps.@"test".dependOn(steps.test_unit);
    steps.@"test".dependOn(steps.test_fmt);
    steps.ci.dependOn(steps.check);
    steps.ci.dependOn(steps.example);
    steps.ci.dependOn(steps.@"test");
    steps.ci.dependOn(&fuzz_smoke.step);
    steps.ci.dependOn(steps.parity);
}

fn checks_wired(
    b: *std.Build,
    optimize: std.lang.Optimize,
    modules: Modules,
    filters: []const []const u8,
    step: *std.Build.Step,
) void {
    assert(filters.len <= std.math.maxInt(u32));
    assert(modules.json != modules.scylla);

    for (supported_targets) |query| {
        const resolved = b.resolveTargetQuery(query);

        step.dependOn(&executable(b, &resolved, "parity", "src/parity.zig").step);
        step.dependOn(&executable(b, &resolved, "fuzz", "src/fuzz_tests.zig").step);
        step.dependOn(&executable(b, &resolved, "guard_probe", "src/guard_probe.zig").step);
        step.dependOn(&example(b, &resolved, optimize, modules.scylla).step);
        step.dependOn(&tests_of(b, &resolved, optimize, modules.json, "unit_tests", filters).step);
    }
}

fn example(
    b: *std.Build,
    target: *const std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    module: *std.Build.Module,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = example_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(example_root),
            .target = target.*,
            .optimize = optimize,
            .imports = &.{.{ .name = "scylla", .module = module }},
        }),
    });
}

fn executable(
    b: *std.Build,
    target: *const std.Build.ResolvedTarget,
    name: []const u8,
    root: []const u8,
) *std.Build.Step.Compile {
    assert(name.len > 0);
    assert(root.len > 0);

    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target.*,
            .optimize = .safe,
            .omit_frame_pointer = false,
        }),
    });
}

fn tests_wired(
    b: *std.Build,
    target: *const std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    json: *std.Build.Module,
    filters: []const []const u8,
    probe: *std.Build.Step,
    step: *std.Build.Step,
) void {
    assert(filters.len <= std.math.maxInt(u32));

    if (filters.len > 0) {
        const run = tests_run_of(b, target, optimize, json, "unit_tests", filters);

        run.step.dependOn(probe);
        step.dependOn(&run.step);

        return;
    }

    for (partitions) |partition| {
        const name = b.fmt("tests_{s}", .{partition.name});
        const run = tests_run_of(b, target, optimize, json, name, partition.filters);

        run.step.dependOn(probe);
        step.dependOn(&run.step);
    }
}

fn tests_of(
    b: *std.Build,
    target: *const std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    json: *std.Build.Module,
    name: []const u8,
    filters: []const []const u8,
) *std.Build.Step.Compile {
    assert(name.len > 0);
    assert(filters.len <= std.math.maxInt(u32));

    return b.addTest(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unit_tests.zig"),
            .target = target.*,
            .optimize = optimize,
            .imports = &.{.{ .name = "json", .module = json }},
        }),
        .filters = filters,
    });
}

fn tests_run_of(
    b: *std.Build,
    target: *const std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    json: *std.Build.Module,
    name: []const u8,
    filters: []const []const u8,
) *std.Build.Step.Run {
    assert(name.len > 0);
    assert(filters.len <= std.math.maxInt(u32));

    const run = b.addRunArtifact(tests_of(b, target, optimize, json, name, filters));

    run.has_side_effects = true;

    run.setCwd(b.path("."));

    return run;
}
