const std = @import("std");
const assert = std.debug.assert;
const Kind = @import("../python.zig").Kind;
const Tree = @import("../../syntax/tree.zig").TreeType(Kind);

pub fn invalid(tree: *const Tree) bool {
    assert(tree.count() <= tree.nodes.capacity());

    for (tree.slice(), 0..) |node, index| {
        switch (node.kind) {
            .attribute, .list, .name_node, .parenthesized, .subscript, .tuple => continue,
            else => {},
        }

        if (targeted(tree, @intCast(index))) return true;
    }

    return false;
}

fn targeted(tree: *const Tree, node: u32) bool {
    assert(node < tree.count());

    var child = node;
    var parent = tree.parent_of(node) orelse return false;

    for (0..tree.count()) |_| {
        switch (tree.at(parent).kind) {
            .list, .parenthesized, .starred, .tuple => {},
            else => break,
        }

        child = parent;
        parent = tree.parent_of(parent) orelse return false;
    }

    const statement = tree.at(parent).kind;
    const first = tree.child_first_of(parent) == child;

    const slot = switch (statement) {
        .delete => true,
        .assign => tree.sibling_next_of(child) != null,
        .async_for, .comprehension, .@"for" => first,
        .with_item => !first,
        else => false,
    };

    if (!slot) return false;
    if (tree.at(node).kind == .starred) return statement == .delete;
    return true;
}
