const std = @import("std");
const assert = std.debug.assert;
const fuzz = @import("testing/fuzz.zig");
const log = std.log.scoped(.fuzz);

const Fuzzers = .{
    .canary = {},
    .lex = @import("syntax/lex_fuzz.zig"),
    .markup = @import("syntax/markup_fuzz.zig"),
    .parse_css = @import("syntax/css/parse_fuzz.zig"),
    .parse_go = @import("syntax/go/parse_fuzz.zig"),
    .parse_javascript = @import("syntax/javascript/parse_fuzz.zig"),
    .parse_odin = @import("syntax/odin/parse_fuzz.zig"),
    .parse_python = @import("syntax/python/parse_fuzz.zig"),
    .parse_rust = @import("syntax/rust/parse_fuzz.zig"),
    .parse_zig = @import("syntax/zig/parse_fuzz.zig"),
    .smoke = {},
    .sweep = @import("format/sweep_fuzz.zig"),
};

const Fuzzer = std.meta.FieldEnum(@TypeOf(Fuzzers));

const Arguments = struct {
    fuzzer: Fuzzer,
    seed: ?u64,
    events_max: ?u32,
};

const arguments_count_max = 8;
const smoke_seed = 123;
const usage = "usage: fuzz [--events-max=<count>] <fuzzer> [seed]";

comptime {
    assert(arguments_count_max >= 3);
    assert(@TypeOf(Fuzzers.canary) == void);
    assert(@TypeOf(Fuzzers.smoke) == void);
}

pub fn main(init: std.process.Init) !void {
    assert(init.minimal.args.vector.len > 0);

    const gpa = init.gpa;
    const arguments = try arguments_of(gpa, init.minimal.args);

    switch (arguments.fuzzer) {
        .smoke => {
            assert(arguments.seed == null);

            try main_smoke(gpa);
        },
        else => try main_single(gpa, init.io, arguments),
    }
}

fn main_smoke(gpa: std.mem.Allocator) !void {
    inline for (comptime std.enums.values(Fuzzer)) |fuzzer| {
        const events_max: ?u32 = switch (fuzzer) {
            .canary, .smoke => continue,
            .lex => 256,
            .markup => 128,
            .parse_css => 128,
            .parse_go => 128,
            .parse_javascript => 128,
            .parse_odin => 128,
            .parse_python => 128,
            .parse_rust => 128,
            .parse_zig => 128,
            .sweep => 32_768,
        };

        comptime assert(events_max.? > 0);
        comptime assert(@hasDecl(@field(Fuzzers, @tagName(fuzzer)), "main"));

        try @field(Fuzzers, @tagName(fuzzer)).main(gpa, .{
            .seed = smoke_seed,
            .events_max = events_max,
        });
    }

    log.info("smoke done", .{});
}

fn main_single(gpa: std.mem.Allocator, io: std.Io, arguments: Arguments) !void {
    assert(arguments.fuzzer != .smoke);

    const seed = arguments.seed orelse seed_random(io);

    log.info("fuzz seed = {d}", .{seed});

    switch (arguments.fuzzer) {
        .smoke => unreachable,
        .canary => {
            if (seed % 100 == 0) return error.Canary;
        },
        inline else => |fuzzer| {
            comptime assert(@hasDecl(@field(Fuzzers, @tagName(fuzzer)), "main"));

            try @field(Fuzzers, @tagName(fuzzer)).main(gpa, .{
                .seed = seed,
                .events_max = arguments.events_max,
            });
        },
    }
}

fn seed_random(io: std.Io) u64 {
    var bytes: [8]u8 = undefined;

    io.random(&bytes);

    return std.mem.readInt(u64, &bytes, .little);
}

fn arguments_of(gpa: std.mem.Allocator, args: std.process.Args) !Arguments {
    assert(args.vector.len > 0);

    var fuzzer: ?Fuzzer = null;
    var seed: ?u64 = null;
    var events_max: ?u32 = null;
    var seen: u32 = 0;
    var held = try args.iterateAllocator(gpa);
    defer held.deinit();

    _ = held.skip();

    while (held.next()) |argument| {
        seen += 1;

        assert(seen <= arguments_count_max);

        if (fuzzer == null) assert(seed == null);

        if (std.mem.startsWith(u8, argument, "--events-max=")) {
            const count = argument["--events-max=".len..];
            const parsed = std.fmt.parseUnsigned(u32, count, 10) catch return usage_error();
            if (parsed == 0) return usage_error();

            events_max = parsed;
        } else {
            if (fuzzer == null) {
                fuzzer = std.meta.stringToEnum(Fuzzer, argument) orelse return usage_error();
            } else {
                seed = fuzz.parse_seed(argument) catch return usage_error();
            }
        }
    }

    if (seed != null) assert(fuzzer != null);
    if (seed != null) assert(seen >= 2);

    return .{
        .fuzzer = fuzzer orelse return usage_error(),
        .seed = seed,
        .events_max = events_max,
    };
}

fn usage_error() error{Usage} {
    std.debug.print("{s}\n", .{usage});

    return error.Usage;
}
