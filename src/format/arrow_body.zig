const std = @import("std");
const assert = std.debug.assert;
const Token = @import("../syntax/token.zig");
const TreeType = @import("../syntax/tree.zig").TreeType;
const mask = @import("mask.zig");
const walk = @import("walk.zig");
const head_walk_max: u32 = 64;
const none: u32 = std.math.maxInt(u32);

pub fn led(
    comptime Kind: type,
    nodes: []const TreeType(Kind).Node,
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const mask.RulesType(Kind),
    start: u32,
) ?u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));
    assert(start < nodes.len);

    var held = start;

    assert(nodes.len < none);

    for (0..head_walk_max) |_| {
        const node = &nodes[held];
        if (!node.kind.is_node()) return null;

        if (rules.leads(node.kind)) {
            return if (braced(source, tokens, node.token_start)) held else null;
        }

        if (rules.parens(node.kind)) {
            const inner = node.child_first;
            if (inner == none) return null;
            if (!rules.leads(nodes[inner].kind)) return null;
            return if (braced(source, tokens, nodes[inner].token_start)) held else null;
        }

        if (!passes(Kind, rules, node.kind)) return null;
        if (node.child_first == none) return null;

        held = node.child_first;
    }

    return null;
}

pub fn kept(
    comptime Kind: type,
    nodes: []const TreeType(Kind).Node,
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const mask.RulesType(Kind),
    index: u32,
) bool {
    assert(index < nodes.len);

    const inner = nodes[index].child_first;
    var held = index;

    assert(rules.parens(nodes[index].kind));

    if (inner == none) return false;
    if (!rules.leads(nodes[inner].kind)) return false;
    if (!braced(source, tokens, nodes[inner].token_start)) return false;

    for (0..head_walk_max) |_| {
        const parent = nodes[held].parent;
        if (parent == none) return false;
        if (rules.arrows(nodes[parent].kind)) return nodes[held].sibling_next == none;
        if (nodes[parent].child_first != held) return false;

        const linked = rules.parens(nodes[parent].kind) or passes(Kind, rules, nodes[parent].kind);
        if (!linked) return false;

        held = parent;
    }

    return false;
}

pub fn passes(comptime Kind: type, comptime rules: *const mask.RulesType(Kind), kind: Kind) bool {
    assert(kind.is_node());

    if (rules.chains(kind) != .none) return true;
    if (rules.links(kind)) return true;
    if (rules.casts(kind)) return true;
    return rules.mixes(kind) or rules.branches(kind);
}

fn braced(source: []const u8, tokens: []const Token, position: u32) bool {
    assert(tokens.len < none);

    if (position >= tokens.len) return false;
    assert(source.len <= std.math.maxInt(u32));

    return walk.text_is(tokens[position].text(source), "{");
}
