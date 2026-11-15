const std = @import("std");
const assert = std.debug.assert;
const Kind = @import("kind.zig").Kind;
const TreeType = @import("../tree.zig").TreeType;
const Tree = TreeType(Kind);

pub fn iteration_target(tree: *const Tree, head: u32) bool {
    assert(head < tree.count());

    var held = head;

    switch (tree.kind_at(head)) {
        .array_pattern, .object_pattern => return true,
        else => {},
    }

    for (0..tree.count()) |_| {
        switch (tree.kind_at(held)) {
            .identifier_node, .undefined => return true,
            .call_expression => return call_assignable(tree, held),
            .member_expression, .subscript_expression => return !optionally_chained(tree, held),
            .as_expression, .instantiation_expression => {},
            .non_null_expression, .satisfies_expression => {},
            .parenthesized_expression, .type_assertion => {
                held = child_last(tree, held) orelse return false;

                continue;
            },
            else => return false,
        }

        held = tree.child_first_of(held) orelse return false;
    }

    return false;
}

fn call_assignable(tree: *const Tree, node: u32) bool {
    assert(node < std.math.maxInt(u32));

    const callee = tree.child_first_of(node) orelse return false;
    const arguments = child_last(tree, node) orelse return false;

    assert(tree.kind_at(node) == .call_expression);

    assert(callee <= arguments);

    switch (tree.kind_at(callee)) {
        .import_node, .super => return false,
        else => {},
    }

    if (tree.kind_at(arguments) != .arguments) return false;
    return !optionally_chained(tree, node);
}

pub fn target_refused(tree: *const Tree, node: u32) bool {
    assert(node < std.math.maxInt(u32));

    var child = node;
    var parent = tree.parent_of(node) orelse return false;

    assert(node < tree.count());

    assert(parent < node);

    for (0..tree.count()) |_| {
        if (tree.kind_at(parent) != .parenthesized_expression) break;

        child = parent;
        parent = tree.parent_of(parent) orelse return false;
    }

    const chained = optionally_chained(tree, node);
    const first = tree.child_first_of(parent) == child;

    return switch (tree.kind_at(parent)) {
        .formal_parameters => true,
        .optional_parameter, .required_parameter => parameter_pattern(tree, parent) == child,
        .array_pattern, .rest_pattern, .update_expression => chained,
        .assignment_expression, .assignment_pattern => chained and first,
        .augmented_assignment_expression => chained and first,
        .pair_pattern => chained and !first,
        else => false,
    };
}

pub fn operand_unparenthesized(tree: *const Tree, node: u32) bool {
    assert(node < std.math.maxInt(u32));

    const parent = tree.parent_of(node) orelse return false;

    assert(node < tree.count());

    assert(parent < node);

    return switch (tree.kind_at(parent)) {
        .intersection_type, .union_type => true,
        else => false,
    };
}

pub fn mapped_shared(tree: *const Tree, node: u32) bool {
    assert(node < std.math.maxInt(u32));

    const parent = tree.parent_of(node) orelse return false;

    assert(node < tree.count());

    assert(parent < node);

    if (tree.kind_at(parent) != .object_type) return false;

    var mapped = false;
    var members: u32 = 0;
    var child = tree.child_first_of(node);

    for (0..tree.count()) |_| {
        const held = child orelse break;

        if (tree.kind_at(held) == .mapped_type_clause) mapped = true;

        child = tree.sibling_next_of(held);
    }

    if (!mapped) return false;

    child = tree.child_first_of(parent);

    for (0..tree.count()) |_| {
        const held = child orelse break;

        if (tree.kind_at(held) != .comment) members += 1;

        child = tree.sibling_next_of(held);
    }

    return members > 1;
}

fn parameter_pattern(tree: *const Tree, parameter: u32) ?u32 {
    assert(parameter < tree.count());

    var child = tree.child_first_of(parameter);

    for (0..tree.count()) |_| {
        const held = child orelse return null;

        assert(held > parameter);

        switch (tree.kind_at(held)) {
            .accessibility_modifier, .decorator, .override_modifier => {},
            else => return held,
        }

        child = tree.sibling_next_of(held);
    }

    return null;
}

fn optionally_chained(tree: *const Tree, node: u32) bool {
    assert(node < tree.count());

    var held = node;

    for (0..tree.count()) |_| {
        switch (tree.kind_at(held)) {
            .call_expression, .member_expression => {},
            .non_null_expression, .subscript_expression => {},
            else => return false,
        }

        var child = tree.child_first_of(held);

        for (0..tree.count()) |_| {
            const sibling = child orelse break;
            if (tree.kind_at(sibling) == .optional_chain) return true;

            child = tree.sibling_next_of(sibling);
        }

        held = tree.child_first_of(held) orelse return false;
    }

    return false;
}

fn child_last(tree: *const Tree, node: u32) ?u32 {
    assert(node < std.math.maxInt(u32));

    var held = tree.child_first_of(node) orelse return null;

    assert(node < held);

    for (0..tree.count()) |_| {
        held = tree.sibling_next_of(held) orelse return held;
    }

    return held;
}
