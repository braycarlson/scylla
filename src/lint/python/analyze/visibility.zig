const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../../stdx/bounded/array.zig").ArrayType;
const Fixture = @import("fixture.zig");
const FunctionDef = @import("../../../syntax/python/ast.zig").FunctionDef;
const Semantic = @import("../../../syntax/python/semantic.zig").Semantic;
const Span = @import("../../../stdx/bounded/span.zig");
const View = @import("../../../syntax/python/ast.zig").View;
const matches = @import("../../../syntax/python/semantic.zig").matches;
const stdlib = @import("../../../syntax/python/stdlib.zig");

pub const FunctionKind = enum {
    class_method,
    function,
    method,
    new,
    static_method,
};

const abstract_members = [_][]const u8{
    "abstractclassmethod",
    "abstractmethod",
    "abstractproperty",
    "abstractstaticmethod",
};

const implicit_class_methods = [_][]const u8{ "__init_subclass__", "__class_getitem__" };

pub fn function_kind(
    source: []const u8,
    semantic: *const Semantic,
    definition: FunctionDef,
    out: *ArrayType(Span),
) FunctionKind {
    assert(source.len <= std.math.maxInt(u32));
    assert(definition.view.index() < definition.view.tree.count());

    const view = definition.view;

    assert(view.index() < view.tree.count());

    if (enclosing_class(view) == null) return .function;

    if (decorated(source, semantic, definition, "builtins", "staticmethod", out)) {
        return .static_method;
    }

    if (decorated(source, semantic, definition, "builtins", "classmethod", out)) {
        return .class_method;
    }

    const position = definition.name_token() orelse return .method;
    const name = view.token_at(position).text(source);

    assert(name.len > 0);

    if (std.mem.eql(u8, name, "__new__")) return .new;

    for (implicit_class_methods) |implicit| {
        if (std.mem.eql(u8, name, implicit)) return .class_method;
    }

    return .method;
}

pub fn is_abstract(
    source: []const u8,
    semantic: *const Semantic,
    definition: FunctionDef,
    out: *ArrayType(Span),
) bool {
    assert(out.capacity() > 0);
    assert(source.len <= std.math.maxInt(u32));
    assert(definition.view.index() < definition.view.tree.count());

    for (abstract_members) |member| {
        if (decorated(source, semantic, definition, "abc", member, out)) return true;
    }

    return false;
}

pub fn is_magic(name: []const u8) bool {
    assert(name.len > 0);

    return stdlib.is_dunder(name);
}

pub fn is_overload(
    source: []const u8,
    semantic: *const Semantic,
    definition: FunctionDef,
    out: *ArrayType(Span),
) bool {
    assert(out.capacity() > 0);
    assert(source.len <= std.math.maxInt(u32));
    assert(definition.view.index() < definition.view.tree.count());

    return decorated(source, semantic, definition, "typing", "overload", out);
}

pub fn is_override(
    source: []const u8,
    semantic: *const Semantic,
    definition: FunctionDef,
    out: *ArrayType(Span),
) bool {
    assert(out.capacity() > 0);
    assert(source.len <= std.math.maxInt(u32));
    assert(definition.view.index() < definition.view.tree.count());

    return decorated(source, semantic, definition, "typing", "override", out);
}

pub fn is_property(
    source: []const u8,
    semantic: *const Semantic,
    definition: FunctionDef,
    out: *ArrayType(Span),
    extra: []const []const u8,
) bool {
    assert(out.capacity() > 0);

    if (decorated(source, semantic, definition, "builtins", "property", out)) return true;
    if (decorated(source, semantic, definition, "functools", "cached_property", out)) return true;
    assert(extra.len <= std.math.maxInt(u32));

    for (extra) |path| {
        const at = std.mem.findScalarLast(u8, path, '.') orelse continue;
        const module = path[0..at];
        const member = path[at + 1 ..];

        if (module.len == 0) continue;
        if (member.len == 0) continue;
        if (decorated(source, semantic, definition, module, member, out)) return true;
    }

    return false;
}

pub fn decorator_of(view: View) ?View {
    assert(view.index() < view.tree.count());

    const held = if (view.kind() == .decorator) view.child_first() orelse return null else view;
    if (held.kind() != .call) return held;

    const callee = held.child_first();

    if (callee) |found| assert(found.index() > held.index());

    return callee;
}

fn decorated(
    source: []const u8,
    semantic: *const Semantic,
    definition: FunctionDef,
    module: []const u8,
    member: []const u8,
    out: *ArrayType(Span),
) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(definition.view.index() < definition.view.tree.count());

    var decorators = definition.decorators();
    const node_count = definition.view.tree.count();

    assert(module.len > 0);
    assert(member.len > 0);

    for (0..node_count) |_| {
        const decorator = decorators.next() orelse break;
        const held = decorator_of(decorator) orelse continue;
        if (matches(semantic, source, held, module, member, out)) return true;
    }

    return false;
}

fn enclosing_class(view: View) ?u32 {
    assert(view.index() < view.tree.count());

    var held = view.parent();

    for (0..view.index() + 1) |_| {
        const node = held orelse return null;

        switch (node.kind()) {
            .class_def => return node.index(),
            .async_function_def, .function_def, .lambda => return null,
            else => {},
        }

        held = node.parent();
    }

    unreachable;
}

const Question = enum { abstract, overload, override };

fn definition_last(fixture: *const Fixture) ?u32 {
    const node_count = fixture.tree.count();
    var found: ?u32 = null;

    assert(node_count > 0);

    for (0..node_count) |index| {
        const node: u32 = @intCast(index);

        switch (fixture.tree.kind_at(node)) {
            .async_function_def, .function_def => found = node,
            else => {},
        }
    }

    return found;
}

fn kind_of(source: []const u8) !FunctionKind {
    assert(source.len <= std.math.maxInt(u32));

    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(source);

    const definition = fixture.view(definition_last(&fixture).?).as_function().?;
    return function_kind(fixture.source, &fixture.semantic, definition, &fixture.out);
}

fn asked(source: []const u8, question: Question) !bool {
    assert(source.len <= std.math.maxInt(u32));

    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(source);

    const definition = fixture.view(definition_last(&fixture).?).as_function().?;
    const semantic = &fixture.semantic;

    return switch (question) {
        .abstract => is_abstract(fixture.source, semantic, definition, &fixture.out),
        .overload => is_overload(fixture.source, semantic, definition, &fixture.out),
        .override => is_override(fixture.source, semantic, definition, &fixture.out),
    };
}

fn property_expect(source: []const u8, extra: []const []const u8, expected: bool) !void {
    assert(source.len <= std.math.maxInt(u32));
    assert(extra.len <= std.math.maxInt(u32));

    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(source);

    const definition = fixture.view(definition_last(&fixture).?).as_function().?;
    const semantic = &fixture.semantic;
    const found = is_property(fixture.source, semantic, definition, &fixture.out, extra);

    try std.testing.expectEqual(expected, found);
}

test "a definition outside a class is a plain function" {
    try std.testing.expectEqual(.function, try kind_of("def read():\n    pass\n"));
}

test "a definition inside a class is a method" {
    const source = "class Holder:\n    def read(self):\n        pass\n";

    try std.testing.expectEqual(.method, try kind_of(source));
}

test "a static and a class decorator each name their own kind" {
    const static = "class Holder:\n    @staticmethod\n    def read():\n        pass\n";
    const class = "class Holder:\n    @classmethod\n    def read(cls):\n        pass\n";

    try std.testing.expectEqual(.static_method, try kind_of(static));
    try std.testing.expectEqual(.class_method, try kind_of(class));
}

test "the three names cpython treats as implicit read that way" {
    const new = "class Holder:\n    def __new__(cls):\n        pass\n";
    const subclass = "class Holder:\n    def __init_subclass__(cls):\n        pass\n";

    try std.testing.expectEqual(.new, try kind_of(new));
    try std.testing.expectEqual(.class_method, try kind_of(subclass));
}

test "a decorator outranks the name cpython treats as implicit" {
    const static = "class Holder:\n    @staticmethod\n    def __class_getitem__(item):\n" ++
        "        pass\n";

    const class = "class Holder:\n    @classmethod\n    def __new__(cls):\n        pass\n";

    try std.testing.expectEqual(.static_method, try kind_of(static));
    try std.testing.expectEqual(.class_method, try kind_of(class));
}

test "a definition nested in a method is a plain function" {
    const source = "class Holder:\n    def read(self):\n        def inner():\n" ++
        "            pass\n";

    try std.testing.expectEqual(.function, try kind_of(source));
}

test "an abstract decorator reads as abstract however it is spelled" {
    const dotted = "import abc\nclass Holder:\n    @abc.abstractmethod\n" ++
        "    def read(self):\n        pass\n";

    const named = "from abc import abstractproperty\nclass Holder:\n    @abstractproperty\n" ++
        "    def read(self):\n        pass\n";

    try std.testing.expect(try asked(dotted, .abstract));
    try std.testing.expect(try asked(named, .abstract));
    try std.testing.expect(!try asked("def read():\n    pass\n", .abstract));
}

test "an overload and an override each read as themselves" {
    const overloaded = "import typing\n@typing.overload\ndef read():\n    pass\n";

    const overridden = "from typing import override\nclass Holder:\n    @override\n" ++
        "    def read(self):\n        pass\n";

    try std.testing.expect(try asked(overloaded, .overload));
    try std.testing.expect(try asked(overridden, .override));
}

test "a property reads through builtins functools and a caller s own path" {
    const cached = "import functools\nclass Holder:\n    @functools.cached_property\n" ++
        "    def read(self):\n        pass\n";

    const lazy = "import mypkg\nclass Holder:\n    @mypkg.lazy\n" ++
        "    def read(self):\n        pass\n";

    try property_expect(cached, &.{}, true);
    try property_expect(lazy, &.{"mypkg.lazy"}, true);
    try property_expect(lazy, &.{}, false);
}

test "a dunder name is magic and a private one is not" {
    try std.testing.expect(is_magic("__init__"));
    try std.testing.expect(!is_magic("_private"));
    try std.testing.expect(!is_magic("read"));
}
