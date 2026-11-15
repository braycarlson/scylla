const std = @import("std");
const assert = std.debug.assert;
const Token = @import("../syntax/token.zig");
const TreeType = @import("../syntax/tree.zig").TreeType;
const mask = @import("mask.zig");
const body_links = true;
const body_nests = true;
const body_walk_max: u32 = 512;
const none: u32 = std.math.maxInt(u32);

pub const Flat = struct {
    open: u32,
    stop: u32,
};

pub fn sole_flat(
    comptime Kind: type,
    nodes: []const TreeType(Kind).Node,
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const mask.TailsType(Kind),
    inner: *const TreeType(Kind).Node,
    flat: Flat,
) bool {
    assert(flat.stop <= tokens.len);
    assert(nodes.len < none);

    if (flat.open >= flat.stop) return false;

    const from = tokens[flat.open].offset;
    const to = tokens[flat.stop - 1].end();
    if (std.mem.findScalar(u8, source[from..to], '\n') != null) return false;
    return !body_any(Kind, nodes, source, tokens, rules, inner, sole_capped_node);
}

fn sole_capped_node(
    comptime Kind: type,
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const mask.TailsType(Kind),
    node: *const TreeType(Kind).Node,
) bool {
    assert(tokens.len <= std.math.maxInt(u32));

    const end: u32 = @min(node.token_end, @as(u32, @intCast(tokens.len)));

    assert(end <= tokens.len);
    assert(node.token_start <= node.token_end);

    if (capped_node(Kind, source, tokens, rules, node)) return true;
    if (!rules.chained(node.kind)) return false;
    if (node.token_start >= end) return false;
    if (mask.linked(tokens, node.token_start, end) < 2) return false;
    return mask.spelled(source, tokens, node.token_start, end) > rules.bodies(node.kind);
}

pub fn capped_parts(
    comptime Kind: type,
    nodes: []const TreeType(Kind).Node,
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const mask.TailsType(Kind),
    body: *const TreeType(Kind).Node,
) bool {
    assert(body.token_start <= body.token_end);
    assert(nodes.len < none);
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    return body_any(Kind, nodes, source, tokens, rules, body, capped_node);
}

fn capped_node(
    comptime Kind: type,
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const mask.TailsType(Kind),
    node: *const TreeType(Kind).Node,
) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    const end: u32 = @min(node.token_end, @as(u32, @intCast(tokens.len)));
    const width = rules.bodies(node.kind);

    assert(end <= tokens.len);
    assert(node.token_start <= node.token_end);

    if (width == 0) return false;
    if (node.token_start >= end) return false;
    if (!rules.argued(node.kind)) return false;

    const head = mask.argued(tokens, source, node.token_start, end);
    if (mask.soled(tokens, source, head, end)) return false;
    if (head + 1 >= end) return false;
    return mask.spelled(source, tokens, head + 1, end - 1) > width;
}

pub fn brokens(
    comptime Kind: type,
    nodes: []const TreeType(Kind).Node,
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const mask.TailsType(Kind),
    body: *const TreeType(Kind).Node,
) bool {
    assert(body.token_start <= body.token_end);
    assert(nodes.len < none);

    if (!body_nests) return false;
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    return body_any(Kind, nodes, source, tokens, rules, body, brokens_node);
}

fn brokens_node(
    comptime Kind: type,
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const mask.TailsType(Kind),
    node: *const TreeType(Kind).Node,
) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    const end: u32 = @min(node.token_end, @as(u32, @intCast(tokens.len)));
    const width = rules.bodies(node.kind);

    assert(end <= tokens.len);
    assert(node.token_start <= node.token_end);

    if (width == 0) return false;
    if (node.token_start >= end) return false;

    const head = if (rules.argued(node.kind))
        mask.argued(tokens, source, node.token_start, end)
    else
        node.token_start;

    const chained = body_links and rules.chained(node.kind) and
        mask.linked(tokens, node.token_start, end) < 2;

    if (chained) return false;
    return mask.spelled(source, tokens, head, end) > width;
}

fn body_any(
    comptime Kind: type,
    nodes: []const TreeType(Kind).Node,
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const mask.TailsType(Kind),
    body: *const TreeType(Kind).Node,
    comptime visit: fn (
        comptime type,
        []const u8,
        []const Token,
        comptime *const mask.TailsType(Kind),
        *const TreeType(Kind).Node,
    ) bool,
) bool {
    assert(source.len <= std.math.maxInt(u32));

    var stack: [mask.body_stack_max]u32 = @splat(none);
    var depth: u32 = 0;
    var found = body.child_first;

    assert(found == none or found < nodes.len);
    assert(tokens.len < none);

    for (0..body_walk_max) |_| {
        if (found == none) {
            if (depth == 0) return false;

            depth -= 1;
            found = stack[depth];

            continue;
        }

        const node = &nodes[found];
        if (visit(Kind, source, tokens, rules, node)) return true;

        const descends = node.child_first != none and depth < mask.body_stack_max;

        if (descends) {
            stack[depth] = node.sibling_next;
            depth += 1;
            found = node.child_first;
        } else {
            found = node.sibling_next;
        }
    }

    return false;
}
