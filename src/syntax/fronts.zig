const std = @import("std");
const assert = std.debug.assert;
const Front = @import("front.zig").Front;
const Language = @import("language.zig").Language;
const SourceType = @import("language.zig").SourceType;

pub const Fronts = struct {
    held: [Language.count]Front,
    options: Front.Options,
    reserved: std.EnumSet(Language),
    scratch: Front.Scratch,

    pub fn init(
        fronts: *Fronts,
        gpa: std.mem.Allocator,
        capacity: *const Front.Capacity,
        languages: std.EnumSet(Language),
        options: *const Front.Options,
    ) std.mem.Allocator.Error!void {
        assert(languages.count() > 0);
        assert(capacity.event_count_max > 0);

        fronts.options = options.*;
        fronts.reserved = .empty;
        errdefer fronts.held_deinit(gpa);

        for (std.enums.values(Language)) |language| {
            if (!languages.contains(language)) continue;

            try fronts.held[@backingInt(language)].init(gpa, capacity, language);
            fronts.reserved.insert(language);
        }

        try fronts.scratch.init(gpa, capacity, fronts.reserved);

        assert(fronts.reserved.eql(languages));
    }

    pub fn deinit(fronts: *Fronts, gpa: std.mem.Allocator) void {
        assert(fronts.reserved.count() > 0);

        fronts.scratch.deinit(gpa);
        fronts.held_deinit(gpa);
        fronts.* = undefined;
    }

    pub fn front(fronts: *const Fronts, language: Language) *const Front {
        assert(fronts.reserved.contains(language));

        const held = &fronts.held[@backingInt(language)];

        assert(held.language == language);

        return held;
    }

    pub fn parse(
        fronts: *Fronts,
        source_type: SourceType,
        source: []const u8,
    ) Front.Error!*const Front {
        assert(fronts.reserved.contains(source_type.language));
        assert(source.len <= std.math.maxInt(u32));

        const held = &fronts.held[@backingInt(source_type.language)];

        try held.parse(&fronts.scratch, source_type, source, &fronts.options);

        assert(held.language == source_type.language);

        return held;
    }

    fn held_deinit(fronts: *Fronts, gpa: std.mem.Allocator) void {
        for (std.enums.values(Language)) |language| {
            if (fronts.reserved.contains(language)) fronts.held[@backingInt(language)].deinit(gpa);
        }

        fronts.reserved = .empty;
    }
};

const capacity_test: Front.Capacity = .{
    .diagnostic_count_max = 1 << 6,
    .event_count_max = 1 << 12,
    .node_count_max = 1 << 10,
    .semantic = .{
        .binding_count_max = 1 << 8,
        .fact_count_max = 1 << 6,
        .reference_count_max = 1 << 8,
        .scope_count_max = 1 << 6,
    },
    .tag_count_max = 1 << 6,
    .token_count_max = 1 << 10,
};

test Fronts {
    const gpa = std.testing.allocator;
    const fronts = try gpa.create(Fronts);
    defer gpa.destroy(fronts);

    try fronts.init(gpa, &capacity_test, .initMany(&.{ .python, .zig }), &.{});
    defer fronts.deinit(gpa);

    const front = try fronts.parse(.of(.zig), "const one = 1;\nconst two = one;\n");

    try std.testing.expectEqual(Language.zig, front.language);
    try std.testing.expectEqual(2, front.bindings().count());
    try std.testing.expectEqual(front, fronts.front(.zig));

    const repeated: [512][10]u8 = @splat("value = 1\n".*);
    const outgrown = fronts.parse(.of(.python), std.mem.asBytes(&repeated));

    try std.testing.expectError(error.TokensExhausted, outgrown);
    try std.testing.expectEqual(0, fronts.front(.python).node_count());
}

test "a source past the scope table reports the scopes exhausted" {
    const gpa = std.testing.allocator;
    const fronts = try gpa.create(Fronts);
    defer gpa.destroy(fronts);

    try fronts.init(gpa, &capacity_test, .initOne(.zig), &.{});
    defer fronts.deinit(gpa);

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    for (0..capacity_test.semantic.?.scope_count_max + 8) |index| {
        try writer.print("fn f{d}() void {{}}\n", .{index});
    }

    const outgrown = fronts.parse(.of(.zig), writer.buffered());

    try std.testing.expectError(error.ScopesExhausted, outgrown);
}

test "a front without semantic capacity reserves no semantic tables" {
    const gpa = std.testing.allocator;
    const fronts = try gpa.create(Fronts);
    defer gpa.destroy(fronts);

    var capacity = capacity_test;

    capacity.semantic = null;

    try fronts.init(gpa, &capacity, .initOne(.zig), &.{});
    defer fronts.deinit(gpa);

    const front = try fronts.parse(.of(.zig), "const one = 1;\n");

    try std.testing.expect(front.node_count() > 0);
    try std.testing.expectEqual(0, front.bindings().count());
    try std.testing.expectEqual(0, front.facts().len);
}
