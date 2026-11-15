const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../../stdx/bounded/array.zig").ArrayType;
const ClassDef = @import("../../../syntax/python/ast.zig").ClassDef;
const Fixture = @import("fixture.zig");
const Semantic = @import("../../../syntax/python/semantic.zig").Semantic;
const Span = @import("../../../stdx/bounded/span.zig");
const decorator_of = @import("visibility.zig").decorator_of;
const matches = @import("../../../syntax/python/semantic.zig").matches;

const dataclasses = [_][2][]const u8{
    .{ "attr", "s" },
    .{ "attrs", "define" },
    .{ "attrs", "frozen" },
    .{ "dataclasses", "dataclass" },
};

const enumerations = [_][]const u8{
    "Enum",
    "Flag",
    "IntEnum",
    "IntFlag",
    "ReprEnum",
    "StrEnum",
};

pub fn base_matches(
    source: []const u8,
    semantic: *const Semantic,
    class: ClassDef,
    module: []const u8,
    member: []const u8,
    out: *ArrayType(Span),
) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(class.view.index() < class.view.tree.count());

    var bases = class.bases();
    const node_count = class.view.tree.count();

    assert(module.len > 0);
    assert(member.len > 0);

    for (0..node_count) |_| {
        const base = bases.next() orelse break;
        if (matches(semantic, source, base, module, member, out)) return true;
    }

    return false;
}

pub fn is_dataclass(
    source: []const u8,
    semantic: *const Semantic,
    class: ClassDef,
    out: *ArrayType(Span),
) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(class.view.kind() == .class_def);

    var decorators = class.decorators();
    const node_count = class.view.tree.count();

    for (0..node_count) |_| {
        const decorator = decorators.next() orelse break;
        const held = decorator_of(decorator) orelse continue;

        for (dataclasses) |path| {
            if (matches(semantic, source, held, path[0], path[1], out)) return true;
        }
    }

    return false;
}

pub fn is_enumeration(
    source: []const u8,
    semantic: *const Semantic,
    class: ClassDef,
    out: *ArrayType(Span),
) bool {
    assert(class.view.kind() == .class_def);
    assert(out.capacity() > 0);
    assert(source.len <= std.math.maxInt(u32));

    for (enumerations) |member| {
        if (base_matches(source, semantic, class, "enum", member, out)) return true;
    }

    return false;
}

const Question = enum { dataclass, enumeration };

fn asked(source: []const u8, question: Question) !bool {
    assert(source.len <= std.math.maxInt(u32));

    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(source);

    const class = fixture.view(fixture.first(.class_def).?).as_class().?;

    return switch (question) {
        .dataclass => is_dataclass(fixture.source, &fixture.semantic, class, &fixture.out),
        .enumeration => is_enumeration(fixture.source, &fixture.semantic, class, &fixture.out),
    };
}

test "a base reads through the import that bound it" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build("import enum\nclass Held(enum.Enum):\n    pass\n");

    const class = fixture.view(fixture.first(.class_def).?).as_class().?;
    const source = fixture.source;
    const semantic = &fixture.semantic;

    try std.testing.expect(base_matches(source, semantic, class, "enum", "Enum", &fixture.out));
    try std.testing.expect(!base_matches(source, semantic, class, "enum", "Flag", &fixture.out));
}

test "each enum base reads as an enumeration" {
    const named = "from enum import Enum\nclass Held(Enum):\n    pass\n";
    const dotted = "import enum\nclass Held(enum.IntFlag):\n    pass\n";

    try std.testing.expect(try asked(named, .enumeration));
    try std.testing.expect(try asked(dotted, .enumeration));
    try std.testing.expect(!try asked("class Held(object):\n    pass\n", .enumeration));
}

test "each dataclass decorator reads as a dataclass" {
    const dotted = "import dataclasses\n@dataclasses.dataclass\nclass Held:\n    pass\n";

    const called = "from dataclasses import dataclass\n@dataclass(frozen=True)\n" ++
        "class Held:\n    pass\n";

    const frozen = "import attrs\n@attrs.frozen\nclass Held:\n    pass\n";

    try std.testing.expect(try asked(dotted, .dataclass));
    try std.testing.expect(try asked(called, .dataclass));
    try std.testing.expect(try asked(frozen, .dataclass));
    try std.testing.expect(!try asked("class Held:\n    pass\n", .dataclass));
}
