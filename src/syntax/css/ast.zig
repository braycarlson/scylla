const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const EventsType = @import("../tree.zig").EventsType;
const Kind = @import("kind.zig").Kind;
const Parser = @import("parse.zig").Parser;
const Span = @import("../../stdx/bounded/span.zig");
const Token = @import("../token.zig");
const Tokens = @import("../tokens.zig");
const TreeType = @import("../tree.zig").TreeType;
const lex = @import("lex.zig").lex;
const raw_of = @import("../raw.zig").raw_of;
const Front = @import("../front.zig").Front;
const Fronts = @import("../fronts.zig").Fronts;
const Events = EventsType(Kind);
const Tree = TreeType(Kind);
pub const Literal = enum { colour, dimension, text, word };

pub const View = struct {
    node: u32,
    raw: []const Kind,
    tokens: []const Token,
    tree: *const Tree,

    pub fn init(tree: *const Tree, tokens: []const Token, raw: []const Kind, node: u32) View {
        assert(node < tree.count());
        assert(tokens.len == raw.len);

        return .{ .node = node, .raw = raw, .tokens = tokens, .tree = tree };
    }

    fn cast(view: View, kinds: []const Kind) ?View {
        assert(kinds.len > 0);
        assert(view.node < view.tree.count());

        if (kind_in(view.kind(), kinds)) return view;
        return null;
    }

    fn children_empty(view: View) Children {
        assert(view.node < view.tree.count());

        var found = view.children_of_kind(null);

        found.current = null;
        found.remaining = 0;

        assert(found.kind == null);
        assert(found.current == null);

        return found;
    }

    fn children_of_kind(view: View, wanted: ?Kind) Children {
        if (wanted) |held| assert(held.is_node());
        assert(view.node < view.tree.count());

        const found: Children = .{
            .current = view.tree.child_first_of(view.node),
            .kind = wanted,
            .raw = view.raw,
            .remaining = view.tree.count() - view.node - 1,
            .tokens = view.tokens,
            .tree = view.tree,
        };

        if (found.current) |child| assert(child > view.node);
        assert(found.remaining < view.tree.count());

        return found;
    }

    fn positions_of_kind(view: View, wanted: ?Kind) Positions {
        assert(view.node < view.tree.count());

        const node = view.tree.at(view.node);

        if (wanted) |held| assert(held.is_token());
        assert(node.token_end <= view.raw.len);

        return .{
            .child = view.tree.child_first_of(view.node),
            .kind = wanted,
            .limit = node.token_end,
            .position = node.token_start,
            .raw = view.raw,
            .remaining = node.token_end - node.token_start,
            .tree = view.tree,
        };
    }

    pub fn as_call(view: View) ?Call {
        assert(view.node < view.tree.count());

        const held = view.cast(&.{.call_expression}) orelse return null;

        assert(held.kind() == .call_expression);
        assert(held.node == view.node);

        return .{ .view = held };
    }

    pub fn as_declaration(view: View) ?Declaration {
        assert(view.node < view.tree.count());

        const held = view.cast(&.{.declaration}) orelse return null;

        assert(held.kind() == .declaration);
        assert(held.node == view.node);

        return .{ .view = held };
    }

    pub fn as_rule(view: View) ?Rule {
        assert(view.node < view.tree.count());

        const held = view.cast(&.{.rule_set}) orelse return null;

        assert(held.kind() == .rule_set);
        assert(held.node == view.node);

        return .{ .view = held };
    }

    pub fn as_selector(view: View) ?Selector {
        assert(view.node < view.tree.count());

        const held = view.cast(&selector_kinds) orelse return null;

        assert(kind_in(held.kind(), &selector_kinds));
        assert(held.node == view.node);

        return .{ .view = held };
    }

    fn as_statement(view: View) ?Statement {
        assert(view.node < view.tree.count());

        const held = view.cast(&statement_kinds) orelse return null;

        assert(kind_in(held.kind(), &statement_kinds));
        assert(held.node == view.node);

        return .{ .view = held };
    }

    pub fn at(view: View, node: u32) View {
        assert(node < view.tree.count());
        assert(view.tokens.len == view.raw.len);

        return .{ .node = node, .raw = view.raw, .tokens = view.tokens, .tree = view.tree };
    }

    pub fn child_first_of(view: View, wanted: Kind) ?View {
        assert(view.node < view.tree.count());
        assert(wanted.is_node());

        var found = view.children_of(wanted);
        const held = found.next() orelse return null;

        assert(held.kind() == wanted);
        assert(held.node > view.node);

        return held;
    }

    pub fn children(view: View) Children {
        assert(view.node < view.tree.count());
        assert(view.tokens.len == view.raw.len);

        return view.children_of_kind(null);
    }

    fn children_of(view: View, wanted: Kind) Children {
        assert(wanted.is_node());
        assert(view.node < view.tree.count());

        return view.children_of_kind(wanted);
    }

    pub fn holds(view: View, wanted: Kind) bool {
        assert(wanted.is_token());
        assert(view.node < view.tree.count());

        const position = view.token_first(wanted) orelse return false;

        assert(view.raw[position] == wanted);
        assert(position < view.token_end());

        return true;
    }

    pub fn index(view: View) u32 {
        assert(view.node < view.tree.count());
        assert(view.tokens.len == view.raw.len);

        return view.node;
    }

    pub fn kind(view: View) Kind {
        assert(view.node < view.tree.count());

        const held = view.tree.kind_at(view.node);

        assert(held.is_node());

        return held;
    }

    pub fn parent(view: View) ?View {
        assert(view.node < view.tree.count());

        const above = view.tree.parent_of(view.node) orelse return null;

        assert(above < view.node);

        assert(view.node > 0);

        return view.at(above);
    }

    pub fn positions(view: View) Positions {
        assert(view.node < view.tree.count());
        assert(view.tokens.len == view.raw.len);

        return view.positions_of_kind(null);
    }

    fn positions_of(view: View, wanted: Kind) Positions {
        assert(wanted.is_token());
        assert(view.node < view.tree.count());

        return view.positions_of_kind(wanted);
    }

    pub fn span(view: View) Span {
        assert(view.node < view.tree.count());

        const node = view.tree.at(view.node);
        const extent = node.span(Token, view.tokens);

        assert(node.token_end <= view.tokens.len);
        if (extent.length > 0) assert(node.token_start < node.token_end);

        return extent;
    }

    pub fn text(view: View, source: []const u8) []const u8 {
        assert(view.span().end() <= source.len);

        const extent = view.span();

        assert(source.len <= std.math.maxInt(u32));
        assert(extent.end() <= source.len);

        return extent.text(source);
    }

    fn token_end(view: View) u32 {
        assert(view.node < view.tree.count());

        const node = view.tree.at(view.node);

        assert(node.token_start <= node.token_end);
        assert(node.token_end <= view.tokens.len);

        return node.token_end;
    }

    fn token_first(view: View, wanted: Kind) ?u32 {
        assert(view.node < view.tree.count());
        assert(wanted.is_token());

        var found = view.positions_of(wanted);
        const position = found.next() orelse return null;

        assert(view.raw[position] == wanted);
        assert(position >= view.token_start());

        return position;
    }

    pub fn token_kind(view: View, position: u32) Kind {
        assert(position < view.raw.len);
        assert(view.raw[position].is_token());

        return view.raw[position];
    }

    fn token_start(view: View) u32 {
        assert(view.node < view.tree.count());

        const node = view.tree.at(view.node);

        assert(node.token_start <= node.token_end);
        assert(node.token_start <= view.tokens.len);

        return node.token_start;
    }
};

pub const Call = struct {
    view: View,

    pub fn arguments(call: Call) Flattened {
        assert(call.view.kind() == .call_expression);

        const groups = call.view.children_of(.arguments);

        const found: Flattened = .{
            .groups = groups,
            .members = call.view.children_empty(),
            .remaining = groups.remaining,
        };

        assert(found.members.current == null);

        return found;
    }

    pub fn name(call: Call) ?View {
        assert(call.view.kind() == .call_expression);

        const held = call.view.child_first_of(.function_name) orelse return null;

        assert(held.kind() == .function_name);

        return held;
    }
};

pub const Declaration = struct {
    view: View,

    fn is_important(declaration: Declaration) bool {
        assert(declaration.view.kind() == .declaration);

        const held = declaration.view.child_first_of(.important) orelse return false;

        assert(held.kind() == .important);

        return true;
    }

    pub fn property(declaration: Declaration) ?View {
        assert(declaration.view.kind() == .declaration);

        const held = declaration.view.child_first_of(.property_name) orelse return null;

        assert(held.kind() == .property_name);

        return held;
    }

    pub fn values(declaration: Declaration) Matching {
        assert(declaration.view.kind() == .declaration);

        const children = declaration.view.children();

        const found: Matching = .{
            .children = children,
            .kinds = &value_kinds,
            .remaining = children.remaining,
        };

        assert(found.children.kind == null);

        return found;
    }
};

pub const Rule = struct {
    view: View,

    pub fn body(rule: Rule) ?View {
        assert(rule.view.kind() == .rule_set);

        const held = rule.view.child_first_of(.block) orelse return null;

        assert(held.kind() == .block);

        return held;
    }

    pub fn declarations(rule: Rule) Children {
        assert(rule.view.kind() == .rule_set);

        const held = rule.body() orelse return rule.view.children_empty();

        assert(held.kind() == .block);

        return held.children_of(.declaration);
    }

    pub fn selectors(rule: Rule) Flattened {
        assert(rule.view.kind() == .rule_set);

        const groups = rule.view.children_of(.selectors);

        const found: Flattened = .{
            .groups = groups,
            .members = rule.view.children_empty(),
            .remaining = groups.remaining,
        };

        assert(found.members.current == null);

        return found;
    }
};

pub const Selector = struct {
    view: View,

    pub fn name(selector: Selector) ?View {
        assert(selector.view.node < selector.view.tree.count());

        const held = selector.view;

        const found = switch (held.kind()) {
            .class_selector, .pseudo_class_selector => held.children_of(.class_name).last(),
            .attribute_selector => held.child_first_of(.attribute_name),
            .id_selector => held.child_first_of(.id_name),
            .pseudo_element_selector => held.children_of(.tag_name).last(),
            else => null,
        };

        assert(kind_in(held.kind(), &selector_kinds));
        if (found) |child| assert(child.node > held.node);

        return found;
    }

    pub fn parts(selector: Selector) Children {
        assert(kind_in(selector.view.kind(), &selector_kinds));

        const found = selector.view.children();

        assert(found.kind == null);

        return found;
    }
};

const Statement = struct {
    view: View,

    pub fn body(statement: Statement) ?View {
        assert(kind_in(statement.view.kind(), &statement_kinds));

        const children = statement.view.children();

        var found: Matching = .{
            .children = children,
            .kinds = &body_kinds,
            .remaining = children.remaining,
        };

        const held = found.next() orelse return null;

        assert(kind_in(held.kind(), &body_kinds));

        return held;
    }

    pub fn keyword(statement: Statement) ?View {
        assert(kind_in(statement.view.kind(), &statement_kinds));

        const held = statement.view.child_first_of(.at_keyword) orelse return null;

        assert(held.kind() == .at_keyword);

        return held;
    }

    pub fn queries(statement: Statement) Matching {
        assert(kind_in(statement.view.kind(), &statement_kinds));

        const children = statement.view.children();

        const found: Matching = .{
            .children = children,
            .kinds = &query_kinds,
            .remaining = children.remaining,
        };

        assert(found.children.kind == null);

        return found;
    }
};

pub const Children = struct {
    current: ?u32,
    kind: ?Kind,
    raw: []const Kind,
    remaining: u32,
    tokens: []const Token,
    tree: *const Tree,

    pub fn count(children: *const Children) u32 {
        var rest = children.*;
        var total: u32 = 0;

        for (0..children.tree.count()) |_| {
            if (rest.next() == null) break;

            total += 1;
        }

        assert(total < children.tree.count());
        assert(rest.current == null);

        return total;
    }

    pub fn last(children: *const Children) ?View {
        var rest = children.*;
        var found: ?View = null;

        for (0..children.tree.count()) |_| {
            found = rest.next() orelse break;
        }

        assert(rest.current == null);
        if (found) |held| assert(held.node < children.tree.count());

        return found;
    }

    pub fn next(children: *Children) ?View {
        assert(children.tokens.len == children.raw.len);
        assert(children.remaining <= children.tree.count());

        if (children.remaining == 0) return null;

        for (0..children.tree.count()) |_| {
            const current = children.current orelse return null;
            const node = children.tree.at(current);

            children.current = children.tree.sibling_next_of(current);

            if (children.current) |sibling| assert(sibling > current);

            if (children.kind) |wanted| {
                if (node.kind != wanted) continue;
            }

            children.remaining -= 1;

            return View.init(children.tree, children.tokens, children.raw, current);
        }

        assert(children.current == null);

        return null;
    }
};

pub const Flattened = struct {
    groups: Children,
    members: Children,
    remaining: u32,

    pub fn next(flattened: *Flattened) ?View {
        assert(flattened.groups.kind != null);
        assert(flattened.remaining <= flattened.groups.tree.count());

        if (flattened.remaining == 0) return null;

        for (0..flattened.groups.tree.count() + 1) |_| {
            if (flattened.members.next()) |held| {
                assert(held.parent().?.kind() == flattened.groups.kind.?);

                flattened.remaining -= 1;

                return held;
            }

            const group = flattened.groups.next() orelse return null;

            flattened.members = group.children();
        }

        assert(flattened.groups.current == null);

        return null;
    }
};

pub const Matching = struct {
    children: Children,
    kinds: []const Kind,
    remaining: u32,

    pub fn next(matching: *Matching) ?View {
        assert(matching.kinds.len > 0);
        assert(matching.remaining <= matching.children.tree.count());

        if (matching.remaining == 0) return null;

        for (0..matching.children.tree.count()) |_| {
            const held = matching.children.next() orelse return null;
            if (!kind_in(held.kind(), matching.kinds)) continue;

            assert(held.parent() != null);

            matching.remaining -= 1;

            return held;
        }

        assert(matching.children.current == null);

        return null;
    }
};

pub const Positions = struct {
    child: ?u32,
    kind: ?Kind,
    limit: u32,
    position: u32,
    raw: []const Kind,
    remaining: u32,
    tree: *const Tree,

    pub fn next(positions: *Positions) ?u32 {
        assert(positions.limit <= positions.raw.len);
        assert(positions.remaining <= positions.raw.len);

        if (positions.remaining == 0) return null;

        for (0..positions.raw.len + positions.tree.count() + 1) |_| {
            if (positions.position >= positions.limit) return null;

            if (positions.child) |child| {
                const held = positions.tree.at(child);

                if (held.token_end <= positions.position) {
                    positions.child = positions.tree.sibling_next_of(child);

                    continue;
                }

                if (held.token_start <= positions.position) {
                    positions.child = positions.tree.sibling_next_of(child);
                    positions.position = held.token_end;

                    continue;
                }
            }

            const position = positions.position;
            positions.position += 1;

            if (positions.kind) |wanted| {
                if (positions.raw[position] != wanted) continue;
            }

            assert(position < positions.limit);

            positions.remaining -= 1;

            return position;
        }

        assert(positions.position >= positions.limit);

        return null;
    }
};

const body_kinds = [_]Kind{ .block, .keyframe_block_list };

const query_kinds = [_]Kind{
    .binary_query,
    .feature_query,
    .keyword_query,
    .parenthesized_query,
    .selector_query,
    .unary_query,
};

const selector_kinds = [_]Kind{
    .adjacent_sibling_selector,
    .attribute_selector,
    .child_selector,
    .class_selector,
    .descendant_selector,
    .id_selector,
    .namespace_selector,
    .nesting_selector,
    .pseudo_class_selector,
    .pseudo_element_selector,
    .sibling_selector,
    .universal_selector,
};

const statement_kinds = [_]Kind{
    .at_rule,
    .charset_statement,
    .import_statement,
    .keyframes_statement,
    .media_statement,
    .namespace_statement,
    .postcss_statement,
    .supports_statement,
};

const tally_max: u32 = 1 << 16;

const value_kinds = [_]Kind{
    .binary_expression,
    .call_expression,
    .color_value,
    .float_value,
    .grid_value,
    .important,
    .integer_value,
    .parenthesized_value,
    .plain_value,
    .string_value,
};

fn literal_class(text: []const u8) Literal {
    assert(text.len <= std.math.maxInt(u32));

    if (text.len == 0) return .word;

    const held: Literal = switch (text[0]) {
        '#' => .colour,
        '"', '\'' => .text,
        '+', '-', '.', '0'...'9' => .dimension,
        else => .word,
    };

    if (held == .dimension) assert(text[0] != '#');
    if (held == .word) assert(!std.ascii.isDigit(text[0]));

    return held;
}

fn kind_in(kind: Kind, kinds: []const Kind) bool {
    assert(kinds.len > 0);
    if (!kind.is_node()) return false;

    const index = std.mem.findScalar(Kind, kinds, kind) orelse return false;

    assert(kinds[index] == kind);

    return true;
}

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    raw: ArrayType(Kind),
    tokens: Tokens,
    tree: Tree,

    fn init(fixture: *Fixture, source: []const u8) !void {
        assert(source.len <= std.math.maxInt(u32));

        fixture.arena = .init(std.testing.allocator);
        errdefer fixture.arena.deinit();

        const gpa = fixture.arena.allocator();
        const parser = try gpa.create(Parser);
        var events: Events = undefined;

        try events.init(gpa, 0x4000);
        fixture.raw = try .init(gpa, 4_096);
        fixture.tokens = try .init(gpa, 4_096);
        fixture.tree = try .init(gpa, 4_096, 64);

        try lex(source, &fixture.tokens);
        try raw_of(Kind, fixture.tokens.slice(), &fixture.raw);

        const structure = parser.build(
            source,
            fixture.tokens.slice(),
            fixture.raw.const_slice(),
            &events,
            &fixture.tree,
        );

        assert(structure == .complete);
        assert(fixture.tree.count() > 1);
    }

    fn deinit(fixture: *Fixture) void {
        assert(fixture.tree.count() > 0);
        assert(fixture.tokens.count() == fixture.raw.count());

        fixture.arena.deinit();
    }

    fn find(fixture: *const Fixture, wanted: Kind) View {
        assert(wanted.is_node());
        assert(fixture.tree.count() > 0);

        for (0..fixture.tree.count()) |node| {
            if (fixture.tree.kind_at(@intCast(node)) != wanted) continue;
            return fixture.root().at(@intCast(node));
        }

        std.debug.panic("the tree holds no {s}", .{wanted.name()});
    }

    fn root(fixture: *const Fixture) View {
        const held = View.init(&fixture.tree, fixture.tokens.slice(), fixture.raw.const_slice(), 0);

        assert(held.kind() == .stylesheet);
        assert(held.parent() == null);

        return held;
    }
};

fn tally(iterator: anytype) u32 {
    var rest = iterator;
    var total: u32 = 0;

    for (0..tally_max) |_| {
        if (rest.next() == null) break;

        total += 1;
    }

    const after = rest.next();

    assert(total < tally_max);
    assert(after == null);

    return total;
}

test "a rule reads its selectors and its declarations" {
    const source = ".card, #main {\n    color: red;\n    width: 10px;\n}\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const held = fixture.find(.rule_set).as_rule().?;

    try std.testing.expectEqual(2, tally(held.selectors()));
    try std.testing.expectEqual(2, held.declarations().count());
    try std.testing.expectEqual(Kind.block, held.body().?.kind());
}

test "a declaration reads its property and its values" {
    const source = "a { background: url(x.png) no-repeat !important; }\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const held = fixture.find(.declaration).as_declaration().?;

    try std.testing.expectEqualStrings("background", held.property().?.text(source));
    try std.testing.expectEqual(3, tally(held.values()));
    try std.testing.expect(held.is_important());
}

test "a call reads its name and its arguments" {
    const source = "a { width: calc(100% - 2px); }\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const held = fixture.find(.call_expression).as_call().?;

    try std.testing.expectEqualStrings("calc", held.name().?.text(source));
    try std.testing.expectEqual(1, tally(held.arguments()));
}

test "a selector reads the name its mark carries" {
    const source = "a.card:hover > #main[data-x] {}\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const class_selector = fixture.find(.class_selector).as_selector().?;
    const id_selector = fixture.find(.id_selector).as_selector().?;

    try std.testing.expectEqualStrings("card", class_selector.name().?.text(source));
    try std.testing.expectEqualStrings("main", id_selector.name().?.text(source));
}

test "a statement reads its queries and its body" {
    const source = "@media screen and (min-width: 100px) { a { b: c } }\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const held = fixture.find(.media_statement).as_statement().?;

    try std.testing.expectEqual(1, tally(held.queries()));
    try std.testing.expectEqual(Kind.block, held.body().?.kind());
}

test "a literal names its class" {
    try std.testing.expectEqual(Literal.colour, literal_class("#fff"));
    try std.testing.expectEqual(Literal.text, literal_class("\"held\""));
    try std.testing.expectEqual(Literal.dimension, literal_class("10px"));
    try std.testing.expectEqual(Literal.word, literal_class("red"));
}

test View {
    const gpa = std.testing.allocator;
    const fronts = try gpa.create(Fronts);
    defer gpa.destroy(fronts);

    try fronts.init(gpa, &capacity_doctest, .initOne(.css), &.{});
    defer fronts.deinit(gpa);

    const source = "a { color: red; }\n";
    const parsed = try fronts.parse(.of(.css), source);
    const top = parsed.root_as(View);
    var rules = top.children();
    const rule = rules.next().?.as_rule().?;
    var declarations = rule.declarations();
    const declaration = declarations.next().?.as_declaration().?;

    try std.testing.expectEqual(Kind.stylesheet, top.kind());
    try std.testing.expectEqualStrings("color", declaration.property().?.text(source));
}

const capacity_doctest: Front.Capacity = .{
    .diagnostic_count_max = 1 << 6,
    .event_count_max = 1 << 12,
    .node_count_max = 1 << 10,
    .semantic = null,
    .tag_count_max = 1 << 6,
    .token_count_max = 1 << 10,
};
