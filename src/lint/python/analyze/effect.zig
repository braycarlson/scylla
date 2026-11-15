const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../../stdx/bounded/array.zig").ArrayType;
const Fixture = @import("fixture.zig");
const Kind = @import("../../../syntax/python/kind.zig").Kind;
const Semantic = @import("../../../syntax/python/semantic.zig").Semantic;
const Span = @import("../../../stdx/bounded/span.zig");
const TreeType = @import("../../../syntax/tree.zig").TreeType;
const View = @import("../../../syntax/python/ast.zig").View;
const qualified_name_of = @import("../../../syntax/python/semantic.zig").qualified_name_of;
const walk_from = @import("../../../syntax/tree.zig").walk_from;
const Tree = TreeType(Kind);
const empty_builders = [_][]const u8{ "dict", "frozenset", "list", "set", "tuple" };

pub fn contains_effect(
    source: []const u8,
    semantic: *const Semantic,
    view: View,
    out: *ArrayType(Span),
) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(view.index() < view.tree.count());

    var steps = walk_from(Tree, view.tree, view.index());

    for (0..steps.step_max) |_| {
        const step = steps.next() orelse break;

        const node = switch (step) {
            .enter => |entered| entered,
            .leave => continue,
        };

        const held = view.at(node);

        if (held.kind() == .call) {
            if (contains_effect_empty_builder(source, semantic, held, out)) continue;
            return true;
        }

        switch (held.kind()) {
            .await, .named_expr, .subscript, .yield, .yield_from => return true,
            else => {},
        }

        if (contains_effect_operates_on_value(held)) return true;
    }

    assert(steps.node == null);

    return false;
}

fn contains_effect_empty_builder(
    source: []const u8,
    semantic: *const Semantic,
    call: View,
    out: *ArrayType(Span),
) bool {
    assert(call.kind() == .call);

    const children = call.children();
    if (children.count() != 1) return false;

    const callee = call.child_first() orelse return false;
    if (callee.kind() != .name_node) return false;
    if (qualified_name_of(semantic, source, callee, out) != .builtin) return false;

    const name = callee.text(source);

    assert(name.len > 0);

    for (empty_builders) |builder| {
        if (std.mem.eql(u8, name, builder)) return true;
    }

    return false;
}

fn contains_effect_operates_on_value(view: View) bool {
    assert(view.index() < view.node_count());

    switch (view.kind()) {
        .bin_op, .compare, .unary_op => {},
        else => return false,
    }

    var children = view.children();
    const child_count = children.count();

    assert(child_count > 0);

    for (0..child_count) |_| {
        const held = children.next() orelse break;
        if (held.kind() != .constant) return true;
    }

    return false;
}

fn assigned(source: []const u8) !bool {
    assert(source.len <= std.math.maxInt(u32));

    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(source);

    const node = fixture.first(.assign).?;
    const children = fixture.view(node).children();
    const value = children.last().?;

    return contains_effect(fixture.source, &fixture.semantic, value, &fixture.out);
}

test "a call that is no empty builtin runs code" {
    try std.testing.expect(try assigned("held = read()\n"));
    try std.testing.expect(try assigned("held = list(values)\n"));
    try std.testing.expect(try assigned("held = value[0]\n"));
}

test "an empty builtin constructor runs nothing" {
    try std.testing.expect(!try assigned("held = list()\n"));
    try std.testing.expect(!try assigned("held = dict()\n"));
    try std.testing.expect(!try assigned("held = set()\n"));
}

test "an operator over two literals runs nothing" {
    try std.testing.expect(!try assigned("held = 1 + 2\n"));
    try std.testing.expect(!try assigned("held = -1\n"));
    try std.testing.expect(!try assigned("held = 1 < 2\n"));
}

test "an operator over a name runs whatever the name carries" {
    try std.testing.expect(try assigned("held = value + 1\n"));
    try std.testing.expect(try assigned("held = -value\n"));
}

test "a walrus and an await both run code" {
    try std.testing.expect(try assigned("held = (other := 1)\n"));
    try std.testing.expect(try assigned("async def read(value):\n    held = await value\n"));
}

test "a plain name and a literal run nothing" {
    try std.testing.expect(!try assigned("held = value\n"));
    try std.testing.expect(!try assigned("held = \"text\"\n"));
    try std.testing.expect(!try assigned("held = [1, 2]\n"));
}
