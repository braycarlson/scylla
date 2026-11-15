const std = @import("std");
const assert = std.debug.assert;
const Bindings = @import("binding.zig").Bindings;
const Category = @import("category.zig").Category;
const Front = @import("front.zig").Front;
const Language = @import("language.zig").Language;
const Capacity = @import("front.zig").Front.Capacity;
const Options = @import("front.zig").Front.Options;
const Resolution = @import("binding.zig").Bindings.Resolution;
const Scratch = @import("front.zig").Front.Scratch;

const Built = struct {
    front: Front,
    scratch: Scratch,

    fn init(built: *Built, language: Language) !void {
        const gpa = std.testing.allocator;

        assert(language != .css);
        assert(language != .markup);

        try built.scratch.init(gpa, &capacity_test, .initOne(language));
        errdefer built.scratch.deinit(gpa);

        try built.front.init(gpa, &capacity_test, language);

        assert(built.front.node_count() == 0);
    }

    fn deinit(built: *Built) void {
        const gpa = std.testing.allocator;

        assert(built.front.tokens().len <= capacity_test.token_count_max);
        assert(built.front.language != .markup);

        built.front.deinit(gpa);
        built.scratch.deinit(gpa);
        built.* = undefined;
    }

    fn build(built: *Built, source: []const u8) !void {
        assert(source.len <= source_bytes_max);
        assert(built.front.language != .markup);

        try built.front.parse(&built.scratch, .of(built.front.language), source, &options_test);
    }
};

const Semantic = struct {
    directory: []const u8,
    extension: []const u8,
    language: Language,
};

const fixture_count_max: u32 = 1 << 10;
const source_bytes_max: u32 = 1 << 22;

const every_semantic = [_]Semantic{
    .{ .directory = "go-semantic", .extension = ".go", .language = .go },
    .{ .directory = "javascript-semantic", .extension = ".js", .language = .javascript },
    .{ .directory = "odin-semantic", .extension = ".odin", .language = .odin },
    .{ .directory = "python-semantic", .extension = ".py", .language = .python },
    .{ .directory = "rust-semantic", .extension = ".rs", .language = .rust },
    .{ .directory = "zig-semantic", .extension = ".zig", .language = .zig },
};

const capacity_test: Capacity = .{
    .diagnostic_count_max = 1 << 8,
    .event_count_max = 1 << 18,
    .node_count_max = 1 << 16,
    .semantic = .{
        .binding_count_max = 1 << 12,
        .fact_count_max = 1 << 10,
        .reference_count_max = 1 << 13,
        .scope_count_max = 1 << 10,
    },
    .tag_count_max = 1 << 10,
    .token_count_max = 1 << 16,
};

const options_test: Options = .{
    .globals = &.{},
    .python_version = .py310,
    .vocabulary = .empty,
};

fn fixtures_expect(semantic: *const Semantic, buffer: []u8) !u32 {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    assert(buffer.len == source_bytes_max);
    assert(semantic.extension.len > 1);

    var built: Built = undefined;

    try built.init(semantic.language);
    defer built.deinit();

    var path_buffer: [64]u8 = undefined;
    const path = try std.mem.print(&path_buffer, "tests/fixtures/{s}", .{semantic.directory});
    const root = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer root.close(io);

    var walker = try root.walk(gpa);
    defer walker.deinit();

    var fixture_count: u32 = 0;

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, semantic.extension)) continue;

        assert(fixture_count < fixture_count_max);
        errdefer std.debug.print("{s}/{s}\n", .{ path, entry.path });

        const source = try entry.dir.readFile(io, entry.basename, buffer);

        try std.testing.expect(source.len < buffer.len);
        try built.build(source);
        try fixture_expect(&built.front);

        fixture_count += 1;
    }

    return fixture_count;
}

fn fixture_expect(front: *const Front) !void {
    const bindings = front.bindings();

    assert(front.outcome.? == .complete);
    assert(bindings.count() <= capacity_test.semantic.?.binding_count_max);

    for (0..bindings.count()) |index| {
        try fixture_expect_binding(front, @intCast(index));
    }

    for (0..bindings.reference_count()) |index| {
        switch (bindings.reference_at(@intCast(index)).resolution) {
            .bound => |binding| try std.testing.expect(binding < bindings.count()),
            else => {},
        }
    }

    for (0..bindings.scope_count()) |scope| {
        try fixture_expect_scope(bindings, @intCast(scope));
    }
}

fn fixture_expect_binding(front: *const Front, index: u32) !void {
    assert(index < std.math.maxInt(u32));

    const bindings = front.bindings();
    const binding = bindings.at(index);

    assert(index < bindings.count());
    assert(front.outcome.? == .complete);

    try std.testing.expect(binding.node < front.node_count());
    try std.testing.expect(binding.scope < bindings.scope_count());

    if (binding.class == .function) {
        const category = front.view(binding.node).?.category();

        const placed = switch (category) {
            .declaration, .function, .lambda, .name => true,
            else => false,
        };

        try std.testing.expect(placed);
    }

    var references = bindings.references_of(index);

    while (references.next()) |reference| {
        try std.testing.expectEqual(Resolution{ .bound = index }, reference.resolution);
        try std.testing.expect(reference.node < front.node_count());
    }
}

fn fixture_expect_scope(bindings: Bindings, scope: u32) !void {
    assert(bindings != .empty);
    assert(scope < bindings.scope_count());

    const held = bindings.scope_at(scope);

    if (held.parent) |parent| try std.testing.expect(parent < bindings.scope_count());

    var members = bindings.members_of(scope);

    while (members.next()) |binding| {
        try std.testing.expect(binding < bindings.count());
    }
}

test "a rust function binding names its node and its callers" {
    const source = "fn run(one: u32) -> u32 {\n    run(one)\n}\n\n" ++
        "fn stop() {\n    run(1);\n}\n";

    var built: Built = undefined;

    try built.init(.rust);
    defer built.deinit();

    try built.build(source);

    const bindings = built.front.bindings();
    var function_first: ?u32 = null;
    var function_count: u32 = 0;

    for (0..bindings.count()) |index| {
        if (bindings.at(@intCast(index)).class != .function) continue;

        if (function_first == null) function_first = @intCast(index);

        function_count += 1;
    }

    try std.testing.expectEqual(2, function_count);

    const index = function_first.?;
    const run = bindings.at(index);
    const node = built.front.view(run.node).?;

    const declaration = if (node.category() == .function)
        node
    else
        node.ancestor_of(.function).?;

    try std.testing.expectEqualStrings("run", run.name.text(source));
    try std.testing.expectEqual(Category.function, declaration.category());
    try std.testing.expectEqual(0, declaration.span().offset);

    var callers: u32 = 0;
    var references = bindings.references_of(index);

    while (references.next()) |reference| : (callers += 1) {
        try std.testing.expectEqual(Resolution{ .bound = index }, reference.resolution);
        try std.testing.expectEqualStrings("run", reference.name.text(source));
        try std.testing.expect(!reference.is_store);
    }

    try std.testing.expectEqual(2, callers);
}

test "a rust macro call never binds the function that shares its name" {
    const source = "fn matches(interactive: bool) -> bool {\n" ++
        "    matches!(interactive, true)\n}\n";

    var built: Built = undefined;

    try built.init(.rust);
    defer built.deinit();

    try built.build(source);

    const bindings = built.front.bindings();
    var callers: u32 = 0;

    for (0..bindings.count()) |index| {
        if (bindings.at(@intCast(index)).class != .function) continue;

        var references = bindings.references_of(@intCast(index));

        while (references.next()) |_| {
            assert(callers < capacity_test.semantic.?.reference_count_max);

            callers += 1;
        }
    }

    try std.testing.expectEqual(0, callers);
}

test "a front without a complete build has no bindings" {
    const gpa = std.testing.allocator;
    var front: Front = undefined;

    try front.init(gpa, &capacity_test, .rust);
    defer front.deinit(gpa);

    try std.testing.expect(front.bindings() == .empty);
    try std.testing.expectEqual(0, front.bindings().count());
}

test "every semantic fixture projects its bindings and references" {
    const gpa = std.testing.allocator;
    const buffer = try gpa.alloc(u8, source_bytes_max);
    defer gpa.free(buffer);

    for (&every_semantic) |*semantic| {
        const fixture_count = try fixtures_expect(semantic, buffer);

        try std.testing.expect(fixture_count > 0);
    }
}
