const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../../stdx/bounded/array.zig").ArrayType;
const Children = @import("../../../syntax/python/ast.zig").Children;
const Fixture = @import("fixture.zig");
const Semantic = @import("../../../syntax/python/semantic.zig").Semantic;
const Span = @import("../../../stdx/bounded/span.zig");
const View = @import("../../../syntax/python/ast.zig").View;
const matches = @import("../../../syntax/python/semantic.zig").matches;
pub const annotation_stack_max: u32 = 1 << 6;
const annotated_modules = [_][]const u8{ "typing", "typing_extensions" };

const immutable_plain = [_][2][]const u8{
    .{ "builtins", "bool" },
    .{ "builtins", "bytes" },
    .{ "builtins", "complex" },
    .{ "builtins", "float" },
    .{ "builtins", "int" },
    .{ "builtins", "object" },
    .{ "builtins", "range" },
    .{ "builtins", "str" },
    .{ "collections.abc", "Sized" },
    .{ "typing", "LiteralString" },
    .{ "typing", "Sized" },
};

const immutable_generic = [_][2][]const u8{
    .{ "builtins", "frozendict" },
    .{ "builtins", "frozenset" },
    .{ "builtins", "tuple" },
    .{ "collections.abc", "ByteString" },
    .{ "collections.abc", "Collection" },
    .{ "collections.abc", "Container" },
    .{ "collections.abc", "Iterable" },
    .{ "collections.abc", "Mapping" },
    .{ "collections.abc", "Reversible" },
    .{ "collections.abc", "Sequence" },
    .{ "collections.abc", "Set" },
    .{ "typing", "AbstractSet" },
    .{ "typing", "ByteString" },
    .{ "typing", "Callable" },
    .{ "typing", "Collection" },
    .{ "typing", "Container" },
    .{ "typing", "FrozenSet" },
    .{ "typing", "Iterable" },
    .{ "typing", "Literal" },
    .{ "typing", "Mapping" },
    .{ "typing", "Never" },
    .{ "typing", "NoReturn" },
    .{ "typing", "Reversible" },
    .{ "typing", "Sequence" },
    .{ "typing", "Tuple" },
};

const mutable_calls = [_][2][]const u8{
    .{ "builtins", "dict" },
    .{ "builtins", "list" },
    .{ "builtins", "set" },
    .{ "collections", "Counter" },
    .{ "collections", "OrderedDict" },
    .{ "collections", "defaultdict" },
    .{ "collections", "deque" },
};

comptime {
    assert(immutable_plain.len == 11);
    assert(immutable_generic.len == 25);
    assert(mutable_calls.len == 7);
}

pub fn is_immutable_annotation(
    source: []const u8,
    semantic: *const Semantic,
    view: View,
    out: *ArrayType(Span),
    stack: *ArrayType(u32),
) error{Overflow}!bool {
    assert(stack.capacity() > 0);
    assert(view.index() < view.tree.count());
    assert(source.len <= std.math.maxInt(u32));

    stack.clear();

    try stack_push(stack, view.index());

    for (0..view.tree.count() + 1) |_| {
        const node = stack.pop() orelse return true;
        if (!try immutable_at(source, semantic, view.at(node), out, stack)) return false;
    }

    return false;
}

pub fn is_mutable_expression(
    source: []const u8,
    semantic: *const Semantic,
    view: View,
    out: *ArrayType(Span),
) bool {
    assert(view.index() < view.tree.count());
    assert(source.len <= std.math.maxInt(u32));

    switch (view.kind()) {
        .dict, .dict_comp, .list, .list_comp, .set, .set_comp => return true,
        .call => {},
        else => return false,
    }

    const callee = view.child_first() orelse return false;

    assert(callee.index() > view.index());

    for (mutable_calls) |path| {
        if (matches(semantic, source, callee, path[0], path[1], out)) return true;
    }

    return false;
}

fn immutable_at(
    source: []const u8,
    semantic: *const Semantic,
    view: View,
    out: *ArrayType(Span),
    stack: *ArrayType(u32),
) error{Overflow}!bool {
    assert(stack.count() <= stack.capacity());
    assert(source.len <= std.math.maxInt(u32));
    assert(view.span().end() <= source.len);

    return switch (view.kind()) {
        .attribute, .name_node => immutable_name(source, semantic, view, out),
        .bin_op => immutable_union(view, stack),
        .constant => immutable_constant(view),
        .parenthesized => {
            try push_all(view.children(), stack);

            return true;
        },
        .subscript => immutable_subscript(source, semantic, view, out, stack),
        else => false,
    };
}

fn immutable_constant(view: View) bool {
    assert(view.kind() == .constant);

    const held = view.as_constant() orelse return false;
    return held.literal_class() == .none;
}

fn immutable_union(view: View, stack: *ArrayType(u32)) error{Overflow}!bool {
    assert(view.kind() == .bin_op);

    const operation = view.as_operation() orelse return false;
    var operators = operation.operator_tokens();
    const operator = operators.next() orelse return false;
    if (view.token_kind(operator) != .bar) return false;

    try push_all(view.children(), stack);

    return true;
}

fn immutable_subscript(
    source: []const u8,
    semantic: *const Semantic,
    view: View,
    out: *ArrayType(Span),
    stack: *ArrayType(u32),
) error{Overflow}!bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(view.span().end() <= source.len);

    const head = view.child_first() orelse return false;
    const slice = view.child_at(1) orelse return false;

    assert(view.kind() == .subscript);

    for (immutable_generic) |path| {
        if (matches(semantic, source, head, path[0], path[1], out)) return true;
    }

    if (matches(semantic, source, head, "typing", "Union", out)) {
        if (slice.kind() != .tuple) return false;

        try push_all(slice.children(), stack);

        return true;
    }

    if (matches(semantic, source, head, "typing", "Optional", out)) {
        try stack_push(stack, slice.index());

        return true;
    }

    if (!immutable_subscript_annotated(source, semantic, head, out)) return false;
    if (slice.kind() != .tuple) return false;

    const first = slice.child_first() orelse return false;

    try stack_push(stack, first.index());

    return true;
}

fn immutable_subscript_annotated(
    source: []const u8,
    semantic: *const Semantic,
    head: View,
    out: *ArrayType(Span),
) bool {
    assert(out.capacity() > 0);
    assert(source.len <= std.math.maxInt(u32));
    assert(head.span().end() <= source.len);

    for (annotated_modules) |module| {
        if (matches(semantic, source, head, module, "Annotated", out)) return true;
    }

    return false;
}

fn immutable_name(
    source: []const u8,
    semantic: *const Semantic,
    view: View,
    out: *ArrayType(Span),
) bool {
    assert(out.capacity() > 0);
    assert(source.len <= std.math.maxInt(u32));
    assert(view.span().end() <= source.len);

    for (immutable_plain) |path| {
        if (matches(semantic, source, view, path[0], path[1], out)) return true;
    }

    for (immutable_generic) |path| {
        if (matches(semantic, source, view, path[0], path[1], out)) return true;
    }

    return false;
}

fn push_all(children: Children, stack: *ArrayType(u32)) error{Overflow}!void {
    var held = children;
    const child_count = held.count();
    const stack_count = stack.count();

    for (0..child_count) |_| {
        const child = held.next() orelse break;

        try stack_push(stack, child.index());
    }

    assert(stack.count() == stack_count + child_count);
}

fn stack_push(stack: *ArrayType(u32), node: u32) error{Overflow}!void {
    if (stack.full()) return error.Overflow;
    assert(node < std.math.maxInt(u32));

    stack.push(node);

    assert(stack.count() > 0);
}

fn annotated(source: []const u8) !bool {
    assert(source.len <= std.math.maxInt(u32));

    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;

    try fixture.init(gpa);
    defer fixture.deinit();

    var stack: ArrayType(u32) = try .init(gpa, annotation_stack_max);
    defer stack.deinit(gpa);

    try fixture.build(source);

    const assign = fixture.view(fixture.first(.ann_assign).?).as_assign().?;
    const annotation = assign.annotation().?;

    return is_immutable_annotation(
        fixture.source,
        &fixture.semantic,
        annotation,
        &fixture.out,
        &stack,
    );
}

fn assigned(source: []const u8) !bool {
    assert(source.len <= std.math.maxInt(u32));

    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(source);

    const children = fixture.view(fixture.first(.assign).?).children();
    const value = children.last().?;

    return is_mutable_expression(fixture.source, &fixture.semantic, value, &fixture.out);
}

test "an immutable builtin reads as immutable" {
    try std.testing.expect(try annotated("held: int = 1\n"));
    try std.testing.expect(try annotated("held: str = \"text\"\n"));
    try std.testing.expect(try annotated("held: frozenset = frozenset()\n"));
    try std.testing.expect(try annotated("held: tuple = ()\n"));
    try std.testing.expect(!try annotated("held: list = []\n"));
    try std.testing.expect(!try annotated("held: dict = {}\n"));
}

test "a union and an optional carry their arguments" {
    try std.testing.expect(try annotated("import typing\nheld: typing.Optional[int] = None\n"));
    try std.testing.expect(try annotated("import typing\nheld: typing.Union[int, str] = 1\n"));
    try std.testing.expect(!try annotated("import typing\nheld: typing.Optional[list] = None\n"));
    try std.testing.expect(!try annotated("import typing\nheld: typing.Union[int, list] = 1\n"));
}

test "an annotated reads its first argument alone" {
    const typing_annotated = "import typing\nheld: typing.Annotated[int, list] = 1\n";
    const typing_list = "import typing\nheld: typing.Annotated[list, int] = []\n";

    const extensions = "import typing_extensions\n" ++
        "held: typing_extensions.Annotated[int, 1] = 1\n";

    try std.testing.expect(try annotated(typing_annotated));
    try std.testing.expect(!try annotated(typing_list));
    try std.testing.expect(try annotated(extensions));
}

test "an immutable generic passes whatever it is subscripted with" {
    const named = "from typing import Sequence\nheld: Sequence[list] = ()\n";
    const literal = "import typing\nheld: typing.Literal[\"one\"] = \"one\"\n";
    const tuple = "import typing\nheld: typing.Tuple[int, list] = (1, [])\n";
    const abstract = "import collections.abc\nheld: collections.abc.Sequence = ()\n";

    try std.testing.expect(try annotated("import typing\nheld: typing.Sequence[int] = ()\n"));
    try std.testing.expect(try annotated(named));
    try std.testing.expect(try annotated(literal));
    try std.testing.expect(try annotated(tuple));
    try std.testing.expect(try annotated(abstract));
}

test "a final and a class var read as mutable the way ruff reads them" {
    try std.testing.expect(!try annotated("import typing\nheld: typing.Final[int] = 1\n"));
    try std.testing.expect(!try annotated("import typing\nheld: typing.ClassVar[int] = 1\n"));
}

test "a union written with a bar reads both sides" {
    try std.testing.expect(try annotated("held: int | str = 1\n"));
    try std.testing.expect(try annotated("held: int | None = 1\n"));
    try std.testing.expect(try annotated("held: None = None\n"));
    try std.testing.expect(!try annotated("held: int | list = 1\n"));
    try std.testing.expect(!try annotated("held: int + str = 1\n"));
}

test "each container literal reads as mutable" {
    try std.testing.expect(try assigned("held = []\n"));
    try std.testing.expect(try assigned("held = {}\n"));
    try std.testing.expect(try assigned("held = {1}\n"));
    try std.testing.expect(try assigned("held = [value for value in values]\n"));
    try std.testing.expect(!try assigned("held = ()\n"));
    try std.testing.expect(!try assigned("held = 1\n"));
}

test "each container constructor reads as mutable" {
    try std.testing.expect(try assigned("held = list()\n"));
    try std.testing.expect(try assigned("held = dict()\n"));

    const deferred = "import collections\nheld = collections.defaultdict(list)\n";

    try std.testing.expect(try assigned(deferred));
    try std.testing.expect(!try assigned("held = tuple()\n"));
    try std.testing.expect(!try assigned("held = read()\n"));
}
