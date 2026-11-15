const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const EventsType = @import("../syntax/tree.zig").EventsType;
const Language = @import("../syntax/language.zig").Language;
const Random = @import("../testing/random.zig");
const SourceType = @import("../syntax/language.zig").SourceType;
const Structure = @import("../syntax/tree.zig").Structure;
const Token = @import("../syntax/token.zig");
const Tokens = @import("../syntax/tokens.zig");
const TreeType = @import("../syntax/tree.zig").TreeType;
const corpus = @import("../testing/corpus.zig");
const fuzz = @import("../testing/fuzz.zig");
const fuzzing = @import("../syntax/testing/fuzzing.zig");
const grammars = @import("../syntax/grammars.zig");
const lex = @import("../syntax/lex.zig").lex;
const raw_of = @import("../syntax/raw.zig").raw_of;
const stripe = @import("../testing/stripe.zig");

const Generator = enum {
    flip,
    fragment,
    mutation,
    prefix,
    soup,
};

const Sources = std.ArrayList([]u8);
const diagnostic_count_max: u32 = 1 << 10;
const event_count_max: u32 = 1 << 19;
const file_count_max: u32 = 1 << 16;
const flip_bytes = [8]u8{ 0x00, '\n', '"', '\'', '\\', '{', '}', 0xFF };
const flip_offset_count_max: u32 = 32;
const fragment_count_max: u32 = 8;
const node_count_max: u32 = 1 << 16;
const prefix_count_max: u32 = 64;
const raw_count_max: u32 = 1 << 16;
const round_count_default: u32 = 256;
const seed_fragment: u64 = 0x2C4F_1E77_A93B_D501;
const seed_mutation: u64 = 0x7F19_4B2D_6E05_C3A7;
const seed_soup: u64 = 0x0F1A_35C9_D827_B64D;
const soup_lengths = [5]u32{ 0, 1, 7, 64, 4_096 };
const source_bytes_max: u32 = 1 << 24;
const stride_seed: u64 = 0x9E37_79B9_7F4A_7C15;
const token_count_max: u32 = 1 << 16;
const fixture_root = "tests/fixtures";

fn MachineType(comptime Module: type) type {
    comptime assert(@hasDecl(Module, "Kind"));
    comptime assert(@hasDecl(Module, "Parser"));

    return struct {
        events: Events,
        language: Language,
        tsx: bool,
        parser: Module.Parser,
        raw: ArrayType(Module.Kind),
        tokens: Tokens,
        tree: Tree,

        const Machine = @This();
        const Event = std.meta.Elem(@typeInfo(@TypeOf(Events.slice)).@"fn".return_type.?);
        const Events = EventsType(Module.Kind);
        const Tree = TreeType(Module.Kind);

        fn init(machine: *Machine, gpa: std.mem.Allocator, language: Language, tsx: bool) !void {
            machine.language = language;
            machine.tsx = tsx;

            try machine.events.init(gpa, event_count_max);
            errdefer machine.events.deinit(gpa);

            machine.raw = try .init(gpa, raw_count_max);
            errdefer machine.raw.deinit(gpa);

            machine.tokens = try .init(gpa, token_count_max);
            errdefer machine.tokens.deinit(gpa);

            machine.tree = try .init(gpa, node_count_max, diagnostic_count_max);

            assert(machine.raw.empty());
        }

        fn deinit(machine: *Machine, gpa: std.mem.Allocator) void {
            assert(machine.raw.capacity() == raw_count_max);

            machine.tree.deinit(gpa);
            machine.tokens.deinit(gpa);
            machine.raw.deinit(gpa);
            machine.events.deinit(gpa);
        }

        fn classified(machine: *Machine, source: []const u8) bool {
            assert(source.len <= std.math.maxInt(u32));

            const language = machine.language;
            const tokens = &machine.tokens;

            const source_type: SourceType = .{
                .flavor = if (machine.tsx) .tsx else .plain,
                .language = language,
            };

            tokens.clear();

            lex(source_type, source, tokens) catch |err| switch (err) {
                error.Truncated => {},
            };

            raw_of(Module.Kind, tokens.slice(), &machine.raw) catch |err| switch (err) {
                error.Truncated => return false,
            };

            return true;
        }

        fn built(machine: *Machine, source: []const u8) Structure {
            assert(source.len <= std.math.maxInt(u32));

            const dialected = comptime @hasDecl(Module, "Dialect");
            const held = if (dialected) dialect_of(Module, machine.language, machine.tsx) else {};
            const dialect = if (dialected) .{held.grammar(.module)} else .{};

            machine.tree.clear();

            return @call(.auto, Module.Parser.build, .{
                &machine.parser,
                source,
                machine.tokens.slice(),
                machine.raw.const_slice(),
                &machine.events,
                &machine.tree,
            } ++ dialect);
        }

        fn exercise(machine: *Machine, source: []const u8) !void {
            assert(source.len <= std.math.maxInt(u32));

            if (!machine.classified(source)) return machine.overflowed(source);

            try std.testing.expectEqual(machine.tokens.count(), machine.raw.count());

            const outcome = machine.built(source);

            machine.tree.verify(Token, machine.tokens.slice(), source);
            try std.testing.expect(machine.tree.diagnostic_slice().len <= diagnostic_count_max);
            try machine.repeats(source, outcome);
        }

        fn overflowed(machine: *Machine, source: []const u8) !void {
            assert(source.len <= std.math.maxInt(u32));

            const length: u32 = @intCast(source.len);
            const held = machine.tokens.slice();
            const consumed: u32 = if (held.len == 0) 0 else held[held.len - 1].end();

            try std.testing.expect(consumed <= length);

            for (held) |token| try std.testing.expect(token.end() <= length);

            fuzzing.gaps_tile(held, consumed);

            try std.testing.expect(!machine.classified(source));

            const again = machine.tokens.slice();
            const repeated: u32 = if (again.len == 0) 0 else again[again.len - 1].end();

            try std.testing.expectEqual(consumed, repeated);
        }

        fn repeats(machine: *Machine, source: []const u8, outcome: Structure) !void {
            const gpa = std.testing.allocator;
            const events = try gpa.dupe(Event, machine.events.slice());
            defer gpa.free(events);

            const nodes = try gpa.dupe(Tree.Node, machine.tree.slice());
            defer gpa.free(nodes);

            try std.testing.expect(machine.classified(source));
            try std.testing.expectEqual(outcome, machine.built(source));
            try std.testing.expectEqual(events.len, machine.events.slice().len);
            try std.testing.expectEqual(nodes.len, machine.tree.slice().len);

            try std.testing.expect(fuzz.rows_equal(Event, events, machine.events.slice()));
            try std.testing.expect(fuzz.rows_equal(Tree.Node, nodes, machine.tree.slice()));
        }
    };
}

fn fixtures_collect(gpa: std.mem.Allocator, extension: []const u8, found: *Sources) !void {
    const io = std.testing.io;

    assert(extension.len > 0);

    var directory = try std.Io.Dir.cwd().openDir(io, fixture_root, .{ .iterate = true });
    defer directory.close(io);

    var walker = try corpus.Walker.init(gpa, directory);
    defer walker.deinit();

    for (0..file_count_max) |_| {
        if (!try walker.advance(io)) break;

        const entry = walker.entry;
        const extension_found = std.Io.Dir.path.extension(entry.basename);
        if (extension_found.len < 2) continue;
        if (!std.mem.eql(u8, extension_found[1..], extension)) continue;

        const limit: std.Io.Limit = .limited(source_bytes_max);
        const source = try entry.dir.readFileAlloc(io, entry.basename, gpa, limit);
        errdefer gpa.free(source);

        try found.append(gpa, source);
    }

    std.mem.sort([]u8, found.items, {}, source_less_than);
}

fn source_less_than(context: void, left: []u8, right: []u8) bool {
    _ = context;
    assert(left.len <= std.math.maxInt(u32));
    assert(right.len <= std.math.maxInt(u32));

    return std.mem.lessThan(u8, left, right);
}

fn sources_free(gpa: std.mem.Allocator, found: *Sources) void {
    assert(found.items.len <= found.capacity);

    for (found.items) |source| gpa.free(source);

    found.deinit(gpa);
}

fn seed_of(generator: Generator, name: []const u8) u64 {
    assert(name.len > 0);

    const base: u64 = switch (generator) {
        .fragment => seed_fragment,
        .mutation => seed_mutation,
        .soup => seed_soup,
        .flip, .prefix => unreachable,
    };

    var stride: u64 = 0;

    for (name) |byte| stride = stride *% stride_seed +% byte;

    return (base ^ stride) | 1;
}

fn inputs(
    gpa: std.mem.Allocator,
    generator: Generator,
    name: []const u8,
    held: []const []u8,
) !Sources {
    assert(name.len > 0);
    assert(held.len <= std.math.maxInt(u32));

    var found: Sources = .empty;
    errdefer sources_free(gpa, &found);

    switch (generator) {
        .flip => try flips(gpa, held, &found),
        .prefix => try prefixes(gpa, held, &found),
        .fragment, .mutation, .soup => {
            var random: Random = .init(seed_of(generator, name));

            for (0..round_count_default) |_| {
                const source = switch (generator) {
                    .fragment => try fragment(gpa, &random, held),
                    .mutation => try mutation(gpa, &random, held),
                    .soup => try soup(gpa, &random),
                    .flip, .prefix => unreachable,
                };

                errdefer gpa.free(source);

                try found.append(gpa, source);
            }
        },
    }

    return found;
}

fn prefixes(gpa: std.mem.Allocator, held: []const []u8, found: *Sources) !void {
    assert(held.len <= std.math.maxInt(u32));

    for (held) |source| {
        const length: u32 = @intCast(source.len);
        const stride = @max(length / prefix_count_max, 1);
        var offset: u32 = 0;

        for (0..prefix_count_max + 2) |_| {
            if (offset >= length) break;

            try found.append(gpa, try gpa.dupe(u8, source[0..offset]));

            offset += stride;
        }

        try found.append(gpa, try gpa.dupe(u8, source));
    }
}

fn flips(gpa: std.mem.Allocator, held: []const []u8, found: *Sources) !void {
    assert(held.len <= std.math.maxInt(u32));

    for (held) |source| {
        const length: u32 = @intCast(source.len);
        if (length == 0) continue;

        const stride = @max(length / flip_offset_count_max, 1);
        var offset: u32 = 0;

        for (0..flip_offset_count_max + 2) |_| {
            if (offset >= length) break;

            for (flip_bytes) |byte| {
                if (source[offset] == byte) continue;

                const flipped = try gpa.dupe(u8, source);
                flipped[offset] = byte;

                try found.append(gpa, flipped);
            }

            offset += stride;
        }
    }
}

fn fragment(gpa: std.mem.Allocator, random: *Random, held: []const []u8) ![]u8 {
    assert(held.len <= std.math.maxInt(u32));

    const count = random.below(fragment_count_max) + 1;
    var found: std.ArrayList(u8) = .empty;
    errdefer found.deinit(gpa);

    for (0..count) |_| {
        const source = held[random.below(@intCast(held.len))];
        if (source.len == 0) continue;

        const length: u32 = @intCast(source.len);
        const start = random.below(length);
        const end = start + random.below(length - start + 1);

        try found.appendSlice(gpa, source[start..end]);
    }

    return found.toOwnedSlice(gpa);
}

fn mutation(gpa: std.mem.Allocator, random: *Random, held: []const []u8) ![]u8 {
    assert(held.len <= std.math.maxInt(u32));

    var found: std.ArrayList(u8) = .empty;
    errdefer found.deinit(gpa);

    try found.appendSlice(gpa, held[random.below(@intCast(held.len))]);

    if (found.items.len == 0) return found.toOwnedSlice(gpa);

    const length: u32 = @intCast(found.items.len);
    const offset = random.below(length);

    switch (random.below(4)) {
        0 => found.items[offset] ^= @as(u8, 1) << @intCast(random.below(8)),
        1 => {
            const end = offset + random.below(length - offset + 1);

            found.replaceRangeAssumeCapacity(offset, end - offset, &.{});
        },
        2 => {
            const end = offset + random.below(length - offset + 1);
            const copied = try gpa.dupe(u8, found.items[offset..end]);
            defer gpa.free(copied);

            try found.insertSlice(gpa, offset, copied);
        },
        else => found.shrinkRetainingCapacity(offset),
    }

    return found.toOwnedSlice(gpa);
}

fn soup(gpa: std.mem.Allocator, random: *Random) ![]u8 {
    const length = soup_lengths[random.below(soup_lengths.len)];
    const found = try gpa.alloc(u8, length);

    for (found) |*byte| byte.* = @intCast(random.below(256));

    return found;
}

fn dialect_of(comptime Module: type, language: Language, tsx: bool) Module.Dialect {
    assert(language.lexes());

    if (tsx) return .tsx;
    return Module.Dialect.of_language(language);
}

fn language_sweep(
    comptime Module: type,
    language: Language,
    name: []const u8,
    extension: []const u8,
    generator: Generator,
) !void {
    assert(name.len > 0);
    assert(extension.len <= std.math.maxInt(u32));

    const tsx = std.mem.eql(u8, extension, "tsx");
    const gpa = std.testing.allocator;
    var held: Sources = .empty;
    defer sources_free(gpa, &held);

    try fixtures_collect(gpa, extension, &held);
    try std.testing.expect(held.items.len > 0);

    var found = try inputs(gpa, generator, name, held.items);
    defer sources_free(gpa, &found);

    const Worker = SweepWorkerType(Module);
    var tally: Worker.Tally = .{ .exercised = 0 };

    try stripe.run(Worker, gpa, &.{ .language = language, .tsx = tsx }, found.items, &tally);
    try std.testing.expectEqual(found.items.len, tally.exercised);
}

fn SweepWorkerType(comptime Module: type) type {
    return struct {
        machine: *MachineType(Module),

        const Worker = @This();
        pub const Item = []u8;
        pub const Shared = struct { language: Language, tsx: bool };
        pub const Tally = struct { exercised: u32 };

        pub fn init(worker: *Worker, gpa: std.mem.Allocator, shared: *const Shared) !void {
            const machine = try gpa.create(MachineType(Module));
            errdefer gpa.destroy(machine);

            try machine.init(gpa, shared.language, shared.tsx);

            worker.* = .{ .machine = machine };
        }

        pub fn deinit(worker: *Worker, gpa: std.mem.Allocator) void {
            worker.machine.deinit(gpa);
            gpa.destroy(worker.machine);
            worker.* = undefined;
        }

        pub fn visit(worker: *Worker, item: *const Item, tally: *Tally) !void {
            try worker.machine.exercise(item.*);

            tally.exercised += 1;
        }

        pub fn weight(item: *const Item) u64 {
            assert(item.len + 1 < std.math.maxInt(u64));

            return item.len + 1;
        }
    };
}

fn sweep(generator: Generator) !void {
    try language_sweep(grammars.css, .css, "css", "css", generator);
    try language_sweep(grammars.go, .go, "go", "go", generator);
    try language_sweep(grammars.javascript, .javascript, "javascript", "js", generator);
    try language_sweep(grammars.odin, .odin, "odin", "odin", generator);
    try language_sweep(grammars.python, .python, "python", "py", generator);
    try language_sweep(grammars.rust, .rust, "rust", "rs", generator);
    try language_sweep(grammars.javascript, .typescript, "typescript", "ts", generator);
    try language_sweep(grammars.javascript, .typescript, "tsx", "tsx", generator);
    try language_sweep(grammars.zig, .zig, "zig", "zig", generator);
}

fn chain_exercise(
    comptime Module: type,
    language: Language,
    head: []const u8,
    arm: []const u8,
    tail: []const u8,
) !void {
    assert(language.lexes());
    assert(head.len <= std.math.maxInt(u32));
    assert(arm.len <= std.math.maxInt(u32));
    assert(tail.len <= std.math.maxInt(u32));

    const gpa = std.testing.allocator;
    const arm_count: u32 = 10_000;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(gpa);

    try source.appendSlice(gpa, head);

    for (0..arm_count) |_| try source.appendSlice(gpa, arm);

    try source.appendSlice(gpa, tail);

    const machine = try gpa.create(MachineType(Module));
    defer gpa.destroy(machine);

    try machine.init(gpa, language, false);
    defer machine.deinit(gpa);

    try machine.exercise(source.items);
}

fn single_exercise(comptime Module: type, language: Language, source: []const u8) !void {
    assert(language.lexes());
    assert(source.len <= std.math.maxInt(u32));

    const gpa = std.testing.allocator;
    const machine = try gpa.create(MachineType(Module));
    defer gpa.destroy(machine);

    try machine.init(gpa, language, false);
    defer machine.deinit(gpa);

    try machine.exercise(source);
}

test "a long else if chain reports instead of overflowing" {
    try chain_exercise(
        grammars.rust,
        .rust,
        "fn held() {\n    if a {\n    }",
        " else if a {\n    }",
        "\n}\n",
    );

    try chain_exercise(
        grammars.go,
        .go,
        "package held\n\nfunc held() {\n\tif a {\n\t}",
        " else if a {\n\t}",
        "\n}\n",
    );
}

test "an empty node after trailing trivia stays inside its parent" {
    try single_exercise(grammars.css, .css, ":/**/;");
    try single_exercise(grammars.go, .go, "var/*");
    try single_exercise(grammars.javascript, .javascript, "switch/*");
    try single_exercise(grammars.odin, .odin, "struct{l//");
    try single_exercise(grammars.python, .python, "@\n");
    try single_exercise(grammars.rust, .rust, "enum//\n?");
}

test "byte soup holds every invariant" {
    try sweep(.soup);
}

test "fragment soup holds every invariant" {
    try sweep(.fragment);
}

test "a mutated fixture holds every invariant" {
    try sweep(.mutation);
}

test "every truncated prefix of a fixture holds every invariant" {
    try sweep(.prefix);
}

test "every single byte change to a fixture holds every invariant" {
    try sweep(.flip);
}
