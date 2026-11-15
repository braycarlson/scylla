const std = @import("std");
const assert = std.debug.assert;
const Token = @import("../syntax/token.zig");
const TreeType = @import("../syntax/tree.zig").TreeType;
const mask = @import("mask.zig");
const jump_walk_max: u32 = 64;
const none: u32 = std.math.maxInt(u32);

pub fn led(
    comptime Kind: type,
    nodes: []const TreeType(Kind).Node,
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const mask.RulesType(Kind),
    index: u32,
) bool {
    assert(index < nodes.len);
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    const node = &nodes[index];

    assert(nodes.len < none);

    if (node.parent == none) return false;
    if (rules.parens(node.kind)) return false;
    if (!rules.jumps(node.kind, nodes[node.parent].kind)) return false;

    var held = node.child_first;

    for (0..jump_walk_max) |_| {
        if (held == none) return false;

        const inner = &nodes[held];
        if (inner.token_start != node.token_start) return false;
        if (rules.parens(inner.kind)) return led_commented(Kind, nodes, source, tokens, inner);

        held = inner.child_first;
    }

    return false;
}

fn led_commented(
    comptime Kind: type,
    nodes: []const TreeType(Kind).Node,
    source: []const u8,
    tokens: []const Token,
    paren: *const TreeType(Kind).Node,
) bool {
    assert(nodes.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));

    const inner = paren.child_first;

    assert(paren.token_start < paren.token_end);
    assert(paren.token_end <= tokens.len);

    if (inner == none) return false;
    return mask.jump_commented(source, tokens, paren.token_start + 1, nodes[inner].token_start);
}
