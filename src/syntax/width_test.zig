const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const EventsType = @import("tree.zig").EventsType;
const Front = @import("front.zig").Front;
const Language = @import("language.zig").Language;
const Capacity = @import("front.zig").Front.Capacity;
const Options = @import("front.zig").Front.Options;
const Scratch = @import("front.zig").Front.Scratch;
const Structure = @import("tree.zig").Structure;
const Tokens = @import("tokens.zig");
const TreeType = @import("tree.zig").TreeType;
const bind = @import("python/bind.zig").bind;
const lex = @import("lex.zig").lex;
const python = @import("grammars.zig").python;
const raw_of = @import("raw.zig").raw_of;

const Bound = struct {
    binding_count: u32,
    complete: bool,
    parsed: Structure,
};

const Case = struct {
    close: []const u8,
    language: Language,
    name: []const u8,
    open: []const u8,
};

const Read = struct {
    error_count: u32,
    parsed: Front.Error!void,
};

const name_count: u32 = 4_096;
const source_bytes_max: u32 = 1 << 17;

const every_parameter_list = [_]Case{
    .{
        .close = ") {}\n",
        .language = .go,
        .name = "a parameter list",
        .open = "package held\n\nfunc Held(",
    },
    .{
        .close = ") {}\n",
        .language = .javascript,
        .name = "a parameter list",
        .open = "function held(",
    },
    .{
        .close = ") {}\n",
        .language = .odin,
        .name = "a parameter list",
        .open = "package held\n\nheld :: proc(",
    },
    .{
        .close = "):\n    pass\n",
        .language = .python,
        .name = "a parameter list",
        .open = "def held(",
    },
    .{
        .close = "):\n    pass\n",
        .language = .python,
        .name = "a base class list",
        .open = "class Held(",
    },
    .{
        .close = ") {}\n",
        .language = .rust,
        .name = "a parameter list",
        .open = "pub fn held(",
    },
    .{
        .close = ") {}\n",
        .language = .typescript,
        .name = "a parameter list",
        .open = "function held(",
    },
    .{
        .close = ") void {}\n",
        .language = .zig,
        .name = "a parameter list",
        .open = "pub fn held(",
    },
};

const every_pattern = [_]Case{
    .{
        .close = "] = held;\n",
        .language = .javascript,
        .name = "an array pattern",
        .open = "const [",
    },
    .{
        .close = "} = held;\n",
        .language = .javascript,
        .name = "an object pattern",
        .open = "const {",
    },
    .{
        .close = "] = held;\n",
        .language = .typescript,
        .name = "an array pattern",
        .open = "const [",
    },
    .{
        .close = "} = held;\n",
        .language = .typescript,
        .name = "an object pattern",
        .open = "const {",
    },
};

const capacity_test: Capacity = .{
    .diagnostic_count_max = 1 << 10,
    .event_count_max = 1 << 22,
    .node_count_max = 1 << 20,
    .semantic = .{
        .binding_count_max = 1 << 16,
        .fact_count_max = 1 << 14,
        .reference_count_max = 1 << 16,
        .scope_count_max = 1 << 14,
    },
    .tag_count_max = 1 << 14,
    .token_count_max = 1 << 20,
};

const options_test: Options = .{
    .globals = &.{},
    .python_version = .py310,
    .vocabulary = .empty,
};

const segment_count_max: u32 = 1 << 14;

fn case_expect_complete(case: *const Case, typed: bool, buffer: []u8) !void {
    assert(buffer.len == source_bytes_max);
    assert(case.name.len > 0);
    errdefer std.debug.print("{s} reads {d} names in {s}\n", .{
        case.language.name(),
        name_count,
        case.name,
    });

    const source = try source_of(case, typed, buffer);
    const held = try read(case.language, source);

    try held.parsed;
    try std.testing.expectEqual(0, held.error_count);
}

fn source_of(case: *const Case, typed: bool, buffer: []u8) ![]const u8 {
    assert(buffer.len == source_bytes_max);

    var writer: std.Io.Writer = .fixed(buffer);

    assert(case.open.len > 0);

    try writer.writeAll(case.open);

    for (0..name_count) |index| {
        if (index > 0) try writer.writeAll(", ");

        try name_write(&writer, case.language, @intCast(index), typed);
    }

    try writer.writeAll(case.close);

    return writer.buffered();
}

fn name_write(writer: *std.Io.Writer, language: Language, index: u32, typed: bool) !void {
    assert(index < name_count);
    assert(language != .markup);

    if (!typed) return writer.print("n{d}", .{index});

    switch (language) {
        .go => try writer.print("n{d} int", .{index}),
        .odin => try writer.print("n{d}: int", .{index}),
        .rust, .zig => try writer.print("n{d}: u32", .{index}),
        else => try writer.print("n{d}", .{index}),
    }
}

fn read(language: Language, source: []const u8) !Read {
    const gpa = std.testing.allocator;

    assert(source.len <= source_bytes_max);
    assert(language != .markup);

    var scratch: Scratch = undefined;

    try scratch.init(gpa, &capacity_test, .initOne(language));
    defer scratch.deinit(gpa);

    var front: Front = undefined;

    try front.init(gpa, &capacity_test, language);
    defer front.deinit(gpa);

    const parsed = front.parse(&scratch, .of(front.language), source, &options_test);
    return .{ .error_count = @intCast(front.diagnostics().len), .parsed = parsed };
}

fn bound(source: []const u8) !Bound {
    const gpa = std.testing.allocator;

    assert(source.len > 0);
    assert(source.len <= source_bytes_max);

    var tokens: Tokens = try .init(gpa, capacity_test.token_count_max);
    defer tokens.deinit(gpa);

    var raw: ArrayType(python.Kind) = try .init(gpa, capacity_test.token_count_max);
    defer raw.deinit(gpa);

    const events = try gpa.create(EventsType(python.Kind));
    defer gpa.destroy(events);

    try events.init(gpa, capacity_test.event_count_max);
    defer events.deinit(gpa);

    var tree: TreeType(python.Kind) = try .init(
        gpa,
        capacity_test.node_count_max,
        capacity_test.diagnostic_count_max,
    );

    defer tree.deinit(gpa);

    const parser = try gpa.create(python.Parser);
    defer gpa.destroy(parser);

    var tables: python.bind.Tables = undefined;

    try tables.init(gpa, &.{
        .binding_count_max = capacity_test.semantic.?.binding_count_max,
        .reference_count_max = capacity_test.semantic.?.reference_count_max,
        .scope_count_max = capacity_test.semantic.?.scope_count_max,
        .segment_count_max = segment_count_max,
    });

    defer tables.deinit(gpa);

    try lex(.of(.python), source, &tokens);
    try raw_of(python.Kind, tokens.slice(), &raw);

    const parsed = parser.build(source, tokens.slice(), raw.const_slice(), events, &tree);
    const held = bind(source, tokens.slice(), raw.const_slice(), &tree, &tables);

    return .{
        .binding_count = tables.bindings.count(),
        .complete = if (held) |_| true else |_| false,
        .parsed = parsed,
    };
}

test "a wide parameter list is not nesting" {
    const gpa = std.testing.allocator;
    const buffer = try gpa.alloc(u8, source_bytes_max);
    defer gpa.free(buffer);

    for (&every_parameter_list) |*case| {
        try case_expect_complete(case, std.mem.eql(u8, case.name, "a parameter list"), buffer);
    }
}

test "a wide pattern is not nesting" {
    const gpa = std.testing.allocator;
    const buffer = try gpa.alloc(u8, source_bytes_max);
    defer gpa.free(buffer);

    for (&every_pattern) |*case| {
        try case_expect_complete(case, false, buffer);
    }
}

test "a wide comprehension reads every target" {
    const gpa = std.testing.allocator;
    const buffer = try gpa.alloc(u8, source_bytes_max);
    defer gpa.free(buffer);

    var writer: std.Io.Writer = .fixed(buffer);

    try writer.writeAll("held = [x");

    for (0..name_count) |index| {
        try writer.print(" for x in s{d}", .{index});
    }

    try writer.writeAll("]\n");

    const held = try read(.python, writer.buffered());

    try held.parsed;
    try std.testing.expectEqual(0, held.error_count);
}

test "the binder reads a flat literal of any width" {
    const gpa = std.testing.allocator;
    const buffer = try gpa.alloc(u8, source_bytes_max);
    defer gpa.free(buffer);

    var writer: std.Io.Writer = .fixed(buffer);

    try writer.writeAll("held = [");

    for (0..name_count) |index| {
        if (index > 0) try writer.writeAll(", ");

        try writer.print("{d}", .{index % 9});
    }

    try writer.writeAll("]\n");

    const held = try bound(writer.buffered());

    try std.testing.expectEqual(Structure.complete, held.parsed);
    try std.testing.expect(held.complete);
}

test "the binder reads a wide target tuple in full" {
    const gpa = std.testing.allocator;
    const buffer = try gpa.alloc(u8, source_bytes_max);
    defer gpa.free(buffer);

    var writer: std.Io.Writer = .fixed(buffer);

    for (0..name_count) |index| {
        if (index > 0) try writer.writeAll(", ");

        try writer.print("n{d}", .{index});
    }

    try writer.writeAll(" = xs\n");

    const held = try bound(writer.buffered());

    try std.testing.expectEqual(Structure.complete, held.parsed);
    try std.testing.expect(held.complete);
    try std.testing.expectEqual(name_count, held.binding_count);
}
