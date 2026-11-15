const std = @import("std");
const assert = std.debug.assert;
const AnnotationScratch = @import("../../../syntax/python/semantic.zig").AnnotationScratch;
const ArrayType = @import("../../../stdx/bounded/array.zig").ArrayType;
const EventsType = @import("../../../syntax/tree.zig").EventsType;
const Kind = @import("../../../syntax/python/kind.zig").Kind;
const Parser = @import("../../../syntax/python/parse.zig").Parser;
const Semantic = @import("../../../syntax/python/semantic.zig").Semantic;
const Span = @import("../../../stdx/bounded/span.zig");
const Structure = @import("../../../syntax/tree.zig").Structure;
const Tokens = @import("../../../syntax/tokens.zig");
const TreeType = @import("../../../syntax/tree.zig").TreeType;
const View = @import("../../../syntax/python/ast.zig").View;
const raw_of = @import("../../../syntax/raw.zig").raw_of;
const lex = @import("../../../syntax/python/lex.zig").lex;
const Events = EventsType(Kind);
const Tree = TreeType(Kind);

events: Events,
gpa: std.mem.Allocator,
out: ArrayType(Span),
parser: *Parser,
raw: ArrayType(Kind),
scratch: *AnnotationScratch,
semantic: Semantic,
source: []const u8,
tokens: Tokens,
tree: Tree,

const Fixture = @This();
const diagnostic_count_max: u32 = 1 << 8;
const event_count_max: u32 = 1 << 16;
const out_count_max: u32 = 1 << 8;
const token_count_max: u32 = 1 << 14;

const limits_semantic: Semantic.Limits = .{
    .binding_count_max = 1 << 10,
    .fact_count_max = 1 << 8,
    .reference_count_max = 1 << 12,
    .scope_count_max = 1 << 8,
};

pub fn init(fixture: *Fixture, gpa: std.mem.Allocator) !void {
    fixture.gpa = gpa;

    try fixture.events.init(gpa, event_count_max);
    errdefer fixture.events.deinit(gpa);

    fixture.out = try .init(gpa, out_count_max);
    errdefer fixture.out.deinit(gpa);

    fixture.parser = try gpa.create(Parser);
    errdefer gpa.destroy(fixture.parser);

    fixture.raw = try .init(gpa, token_count_max);
    errdefer fixture.raw.deinit(gpa);

    fixture.scratch = try gpa.create(AnnotationScratch);
    errdefer gpa.destroy(fixture.scratch);

    try fixture.scratch.init(gpa, &.{ .node_count_max = 1 << 8, .token_count_max = 1 << 8 });
    errdefer fixture.scratch.deinit(gpa);

    try fixture.semantic.init(gpa, &limits_semantic);
    errdefer fixture.semantic.deinit(gpa);

    fixture.tokens = try .init(gpa, token_count_max);
    errdefer fixture.tokens.deinit(gpa);

    fixture.tree = try .init(gpa, token_count_max, diagnostic_count_max);
    fixture.source = "";

    assert(fixture.raw.capacity() == token_count_max);
    assert(fixture.semantic.count() == 0);
}

pub fn deinit(fixture: *Fixture) void {
    const gpa = fixture.gpa;

    assert(fixture.raw.capacity() == token_count_max);
    assert(fixture.out.capacity() == out_count_max);

    fixture.tree.deinit(gpa);
    fixture.tokens.deinit(gpa);
    fixture.semantic.deinit(gpa);
    fixture.scratch.deinit(gpa);
    gpa.destroy(fixture.scratch);
    fixture.raw.deinit(gpa);
    gpa.destroy(fixture.parser);
    fixture.out.deinit(gpa);
    fixture.events.deinit(gpa);
    fixture.* = undefined;
}

pub fn build(fixture: *Fixture, source: []const u8) !void {
    assert(source.len > 0);
    assert(source.len < token_count_max);

    fixture.source = source;

    fixture.tokens.clear();

    try lex(source, &fixture.tokens);
    try raw_of(Kind, fixture.tokens.slice(), &fixture.raw);

    const parsed = fixture.parser.build(
        source,
        fixture.tokens.slice(),
        fixture.raw.const_slice(),
        &fixture.events,
        &fixture.tree,
    );

    try std.testing.expectEqual(Structure.complete, parsed);

    const built = fixture.semantic.build(&.{
        .builtins = &.{},
        .raw = fixture.raw.const_slice(),
        .source = source,
        .tokens = fixture.tokens.slice(),
        .tree = &fixture.tree,
        .version = .py312,
    }, fixture.scratch);

    try std.testing.expectEqual(Structure.complete, built);
}

pub fn first(fixture: *const Fixture, kind: Kind) ?u32 {
    assert(kind.is_node());

    return fixture.nth(kind, 0);
}

pub fn nth(fixture: *const Fixture, kind: Kind, position: u32) ?u32 {
    const node_count = fixture.tree.count();
    var seen: u32 = 0;

    assert(kind.is_node());

    for (0..node_count) |index| {
        const node: u32 = @intCast(index);
        if (fixture.tree.kind_at(node) != kind) continue;

        if (seen == position) {
            assert(fixture.tree.kind_at(node) == kind);

            return node;
        }

        seen += 1;
    }

    assert(seen <= node_count);

    return null;
}

pub fn view(fixture: *const Fixture, node: u32) View {
    assert(node < fixture.tree.count());

    return View.init(&fixture.tree, fixture.tokens.slice(), fixture.raw.const_slice(), node);
}
