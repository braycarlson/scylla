const std = @import("std");
const assert = std.debug.assert;
const Token = @import("../syntax/token.zig");
const TreeType = @import("../syntax/tree.zig").TreeType;
const mask = @import("mask.zig");
const solo_walk_max: u32 = 64;
const none: u32 = std.math.maxInt(u32);

pub fn holds(
    comptime Kind: type,
    nodes: []const TreeType(Kind).Node,
    comptime rules: *const mask.RulesType(Kind),
    node: *const TreeType(Kind).Node,
) bool {
    if (!rules.soles(node.kind)) return false;
    if (node.child_first == none) return false;

    assert(node.child_first < nodes.len);

    return nodes[node.child_first].sibling_next == none;
}

pub fn led(
    comptime Kind: type,
    nodes: []const TreeType(Kind).Node,
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const mask.RulesType(Kind),
    paren: *const TreeType(Kind).Node,
) ?u32 {
    var held = paren.*;

    assert(rules.parens(paren.kind));
    assert(nodes.len < none);

    for (0..solo_walk_max) |_| {
        if (!rules.parens(held.kind)) break;
        if (held.child_first == none) return null;

        held = nodes[held.child_first];
    }

    if (!holds(Kind, nodes, rules, &held)) return null;
    if (held.token_start >= tokens.len) return null;
    if (!std.mem.eql(u8, tokens[held.token_start].text(source), "|")) return null;
    return held.token_start;
}

pub fn raised(
    comptime Kind: type,
    nodes: []const TreeType(Kind).Node,
    comptime rules: *const mask.RulesType(Kind),
    index: u32,
) u32 {
    assert(index < nodes.len);

    var held = index;

    assert(nodes.len < none);

    for (0..solo_walk_max) |_| {
        const parent = nodes[held].parent;
        if (parent == none) break;
        if (nodes[parent].parent == none) break;
        if (!holds(Kind, nodes, rules, &nodes[parent])) break;

        held = parent;
    }

    assert(held < nodes.len);

    return held;
}
