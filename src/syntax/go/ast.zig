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
pub const Literal = enum { number, rune, text };

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

        const held = view.cast(&.{.call_expr}) orelse return null;

        assert(held.kind() == .call_expr);
        assert(held.node == view.node);

        return .{ .view = held };
    }

    pub fn as_declaration(view: View) ?Declaration {
        assert(view.node < view.tree.count());

        const held = view.cast(&.{.gen_decl}) orelse return null;

        assert(held.kind() == .gen_decl);
        assert(held.node == view.node);

        return .{ .view = held };
    }

    pub fn as_field(view: View) ?Field {
        assert(view.node < view.tree.count());

        const held = view.cast(&.{.field}) orelse return null;

        assert(held.kind() == .field);
        assert(held.node == view.node);

        return .{ .view = held };
    }

    pub fn as_function(view: View) ?Function {
        assert(view.node < view.tree.count());

        const held = view.cast(&function_kinds) orelse return null;

        assert(kind_in(held.kind(), &function_kinds));
        assert(held.node == view.node);

        return .{ .view = held };
    }

    pub fn as_operation(view: View) ?Operation {
        assert(view.node < view.tree.count());

        const held = view.cast(&operation_kinds) orelse return null;

        assert(kind_in(held.kind(), &operation_kinds));
        assert(held.node == view.node);

        return .{ .view = held };
    }

    pub fn as_specification(view: View) ?Specification {
        assert(view.node < view.tree.count());

        const held = view.cast(&specification_kinds) orelse return null;

        assert(kind_in(held.kind(), &specification_kinds));
        assert(held.node == view.node);

        return .{ .view = held };
    }

    pub fn as_statement(view: View) ?Statement {
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

    fn child_at(view: View, ordinal: u32) ?View {
        assert(ordinal < view.tree.count());

        var found = view.children();

        for (0..ordinal) |_| {
            if (found.next() == null) return null;
        }

        const held = found.next() orelse return null;

        assert(held.node > view.node);
        assert(view.tree.parent_of(held.node).? == view.node);

        return held;
    }

    pub fn child_first(view: View) ?View {
        assert(view.node < view.tree.count());

        var found = view.children();
        const held = found.next() orelse return null;

        assert(held.node > view.node);
        assert(view.tree.parent_of(held.node).? == view.node);

        return held;
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

    pub fn children_of(view: View, wanted: Kind) Children {
        assert(wanted.is_node());
        assert(view.node < view.tree.count());

        return view.children_of_kind(wanted);
    }

    pub fn holds(view: View, wanted: Kind) bool {
        assert(view.node < view.tree.count());
        assert(wanted.is_token());

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

    pub fn token_at(view: View, position: u32) Token {
        assert(position < view.tokens.len);
        assert(view.tokens.len == view.raw.len);

        return view.tokens[position];
    }

    pub fn token_end(view: View) u32 {
        assert(view.node < view.tree.count());

        const node = view.tree.at(view.node);

        assert(node.token_start <= node.token_end);
        assert(node.token_end <= view.tokens.len);

        return node.token_end;
    }

    pub fn token_first(view: View, wanted: Kind) ?u32 {
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

    pub fn token_start(view: View) u32 {
        assert(view.node < view.tree.count());

        const node = view.tree.at(view.node);

        assert(node.token_start <= node.token_end);
        assert(node.token_start <= view.tokens.len);

        return node.token_start;
    }
};

pub const Call = struct {
    view: View,

    pub fn arguments(call: Call) Children {
        assert(call.view.kind() == .call_expr);

        var rest = call.view.children();

        _ = rest.next();

        if (rest.current) |child| assert(child > call.view.node);

        return rest;
    }

    pub fn callee(call: Call) ?View {
        assert(call.view.kind() == .call_expr);

        const held = call.view.child_first() orelse return null;

        assert(held.tree.parent_of(held.node).? == call.view.node);

        return held;
    }

    pub fn name_token(call: Call) ?u32 {
        assert(call.view.kind() == .call_expr);

        var named = call.callee() orelse return null;

        if (named.kind() == .selector_expr) {
            named = named.children_of(.ident).last() orelse return null;
        }

        var found = named.positions();
        const position = found.next() orelse return null;

        assert(position >= named.token_start());
        assert(position < named.token_end());

        return position;
    }
};

pub const Declaration = struct {
    view: View,

    pub fn keyword(declaration: Declaration) ?Kind {
        assert(declaration.view.node < declaration.view.tree.count());

        var found = declaration.view.positions();
        const position = found.next() orelse return null;
        const held = declaration.view.token_kind(position);

        assert(declaration.view.kind() == .gen_decl);

        assert(position >= declaration.view.token_start());

        return held;
    }

    pub fn specifications(declaration: Declaration) Children {
        assert(declaration.view.kind() == .gen_decl);

        const found = declaration.view.children();

        assert(found.kind == null);

        return found;
    }
};

pub const Field = struct {
    view: View,

    fn type_index(field: Field) u32 {
        assert(field.view.kind() == .field);

        const total = field.view.children().count();

        if (total == 0) return 0;

        const position = if (field.tag() == null) total - 1 else total -| 2;

        assert(position < total);

        return position;
    }

    pub fn names(field: Field) Leading {
        assert(field.view.kind() == .field);

        const found: Leading = .{
            .children = field.view.children(),
            .kind = null,
            .remaining = field.type_index(),
        };

        assert(found.remaining <= found.children.count());

        return found;
    }

    pub fn tag(field: Field) ?View {
        assert(field.view.kind() == .field);

        const held = field.view.children().last() orelse return null;

        if (held.kind() != .basic_lit) return null;

        assert(held.node > field.view.node);

        return held;
    }

    pub fn type_of(field: Field) ?View {
        assert(field.view.kind() == .field);

        const position = field.type_index();
        const held = field.view.child_at(position) orelse return null;

        assert(held.node > field.view.node);

        return held;
    }
};

pub const Function = struct {
    view: View,

    pub fn body(function: Function) ?View {
        assert(kind_in(function.view.kind(), &function_kinds));

        const held = function.view.child_first_of(.block_stmt) orelse return null;

        assert(held.kind() == .block_stmt);

        return held;
    }

    pub fn name_token(function: Function) ?u32 {
        assert(function.view.node < function.view.tree.count());

        const held = function.signature() orelse return null;
        const name = held.child_first_of(.ident) orelse return null;
        var found = name.positions();
        const position = found.next() orelse return null;

        assert(position >= name.token_start());
        assert(position < held.token_end());

        return position;
    }

    pub fn parameters(function: Function) Children {
        assert(kind_in(function.view.kind(), &function_kinds));

        const held = function.signature() orelse return children_empty(function.view, .field_list);
        const found = held.children_of(.field_list);

        assert(found.kind.? == .field_list);

        return found;
    }

    pub fn receiver(function: Function) ?View {
        assert(function.view.node < function.view.tree.count());

        const held = function.signature() orelse return null;

        if (function.name_token() == null) return null;

        const list = held.child_first() orelse return null;
        if (list.kind() != .field_list) return null;
        if (list.span().offset > held.span().offset +| receiver_gap_max) return null;

        assert(list.node > held.node);
        assert(held.node > function.view.node);

        return list;
    }

    pub fn signature(function: Function) ?View {
        assert(kind_in(function.view.kind(), &function_kinds));

        const held = function.view.child_first_of(.func_type) orelse return null;

        assert(held.kind() == .func_type);

        return held;
    }
};

pub const Operation = struct {
    view: View,

    pub fn operands(operation: Operation) Children {
        assert(kind_in(operation.view.kind(), &operation_kinds));

        const found = operation.view.children();

        assert(found.kind == null);

        return found;
    }

    fn operator_tokens(operation: Operation) Positions {
        assert(kind_in(operation.view.kind(), &operation_kinds));

        const found = operation.view.positions();

        assert(found.kind == null);

        return found;
    }
};

pub const Specification = struct {
    view: View,

    fn assigned(specification: Specification) u32 {
        assert(kind_in(specification.view.kind(), &specification_kinds));

        const position = specification.view.token_first(.equal) orelse {
            return std.math.maxInt(u32);
        };

        assert(specification.view.token_kind(position) == .equal);

        return position;
    }

    fn name_count(specification: Specification) u32 {
        assert(specification.view.node < specification.view.tree.count());

        const limit = specification.assigned();
        var commas = specification.view.positions_of(.comma);
        var total: u32 = 1;

        for (0..specification.view.raw.len + 1) |_| {
            const position = commas.next() orelse break;
            if (position >= limit) break;

            total += 1;
        }

        assert(total >= 1);
        assert(total <= specification.view.token_end() + 1);

        return total;
    }

    pub fn names(specification: Specification) Leading {
        assert(kind_in(specification.view.kind(), &specification_kinds));

        const children = specification.view.children();
        const name_total = specification.name_count();

        const found: Leading = .{
            .children = children,
            .kind = .ident,
            .remaining = @min(name_total, children.remaining),
        };

        assert(name_total > 0);

        return found;
    }

    pub fn path(specification: Specification) ?View {
        assert(kind_in(specification.view.kind(), &specification_kinds));

        const held = specification.view.child_first_of(.basic_lit) orelse return null;

        assert(held.kind() == .basic_lit);

        return held;
    }

    pub fn values(specification: Specification) Values {
        assert(kind_in(specification.view.kind(), &specification_kinds));

        const children = specification.view.children();

        const found: Values = .{
            .children = children,
            .remaining = children.remaining,
            .threshold = specification.assigned(),
        };

        assert(found.children.kind == null);

        return found;
    }
};

pub const Statement = struct {
    view: View,

    pub fn body(statement: Statement) ?View {
        assert(kind_in(statement.view.kind(), &statement_kinds));

        const held = statement.view.children_of(.block_stmt).last() orelse return null;

        assert(held.kind() == .block_stmt);

        return held;
    }

    pub fn clauses(statement: Statement) Children {
        assert(kind_in(statement.view.kind(), &statement_kinds));

        const held = statement.body() orelse return children_empty(statement.view, null);
        const found = held.children();

        assert(found.kind == null);

        return found;
    }

    pub fn header(statement: Statement) ?View {
        assert(kind_in(statement.view.kind(), &statement_kinds));

        const held = statement.view.child_first() orelse return null;

        assert(held.node > statement.view.node);

        return held;
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

pub const Leading = struct {
    children: Children,
    kind: ?Kind,
    remaining: u32,

    pub fn next(leading: *Leading) ?View {
        if (leading.kind) |wanted| assert(wanted.is_node());
        assert(leading.remaining <= leading.children.tree.count());

        if (leading.remaining == 0) return null;

        const held = leading.children.next() orelse return null;

        if (leading.kind) |wanted| {
            if (held.kind() != wanted) {
                leading.remaining = 0;

                return null;
            }
        }

        leading.remaining -= 1;

        assert(leading.children.tree.parent_of(held.node) != null);

        return held;
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

pub const Values = struct {
    children: Children,
    remaining: u32,
    threshold: u32,

    pub fn next(values: *Values) ?View {
        assert(values.children.kind == null);
        assert(values.remaining <= values.children.tree.count());

        if (values.remaining == 0) return null;

        for (0..values.children.tree.count()) |_| {
            const held = values.children.next() orelse return null;
            if (held.token_start() <= values.threshold) continue;

            assert(held.token_start() > values.threshold);

            values.remaining -= 1;

            return held;
        }

        assert(values.children.current == null);

        return null;
    }
};

const function_kinds = [_]Kind{ .func_decl, .func_lit };
const operation_kinds = [_]Kind{ .binary_expr, .key_value_expr, .star_expr, .unary_expr };
const receiver_gap_max: u32 = 5;
const specification_kinds = [_]Kind{ .import_spec, .type_spec, .value_spec };

const statement_kinds = [_]Kind{
    .assign_stmt,
    .for_stmt,
    .if_stmt,
    .range_stmt,
    .return_stmt,
    .select_stmt,
    .switch_stmt,
    .type_switch_stmt,
};

const tally_max: u32 = 1 << 16;

pub fn literal_class(text: []const u8) Literal {
    assert(text.len <= std.math.maxInt(u32));

    if (text.len == 0) return .number;

    const class: Literal = switch (text[0]) {
        '\'' => .rune,
        '"', '`' => .text,
        else => .number,
    };

    if (class == .number) assert(text[0] != '\'');

    return class;
}

fn children_empty(view: View, wanted: ?Kind) Children {
    if (wanted) |held| assert(held.is_node());
    assert(view.tokens.len == view.raw.len);

    return .{
        .current = null,
        .kind = wanted,
        .raw = view.raw,
        .remaining = 0,
        .tokens = view.tokens,
        .tree = view.tree,
    };
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

        assert(held.kind() == .file);
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

test "a function reads its name parameters and body" {
    const source = "package held\n\nfunc run(one int, two string) int {\n\treturn one\n}\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const function = fixture.find(.func_decl).as_function().?;
    const position = function.name_token().?;

    try std.testing.expect(function.receiver() == null);
    try std.testing.expectEqual(Kind.block_stmt, function.body().?.kind());
    try std.testing.expectEqualStrings("run", function.view.token_at(position).text(source));
}

test "a method reads its receiver" {
    const source = "package held\n\nfunc (h *Held) run() {}\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const function = fixture.find(.func_decl).as_function().?;

    try std.testing.expectEqualStrings("(h *Held)", function.receiver().?.text(source));
}

test "a declaration reads its specifications" {
    const source = "package held\n\nvar one, two = 1, 2\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const declaration = fixture.find(.gen_decl).as_declaration().?;

    try std.testing.expectEqual(Kind.var_keyword, declaration.keyword().?);
    try std.testing.expectEqual(1, declaration.specifications().count());

    var specifications = declaration.specifications();
    const specification = specifications.next().?.as_specification().?;

    try std.testing.expectEqual(2, tally(specification.names()));
    try std.testing.expectEqual(2, tally(specification.values()));
}

test "a field reads its names and its type" {
    const source = "package held\n\ntype Held struct {\n\tone, two int `tag`\n}\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const field = fixture.find(.field).as_field().?;

    try std.testing.expectEqual(2, tally(field.names()));
    try std.testing.expectEqualStrings("int", field.type_of().?.text(source));
    try std.testing.expectEqualStrings("`tag`", field.tag().?.text(source));
}

test "a call reads its callee and its arguments" {
    const source = "package held\n\nfunc run() {\n\tfmt.Println(one, two)\n}\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const call = fixture.find(.call_expr).as_call().?;
    const position = call.name_token().?;

    try std.testing.expectEqual(2, call.arguments().count());
    try std.testing.expectEqualStrings("Println", call.view.token_at(position).text(source));
}

test "a statement reads its header and its body" {
    const source = "package held\n\nfunc run() {\n\tif one {\n\t\ttwo()\n\t}\n}\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const statement = fixture.find(.if_stmt).as_statement().?;

    try std.testing.expectEqualStrings("one", statement.header().?.text(source));
    try std.testing.expectEqual(Kind.block_stmt, statement.body().?.kind());
}

test "a switch reads its clauses" {
    const source =
        "package held\n\nfunc run(one int) {\n\tswitch one {\n\tcase 1:\n\tdefault:\n\t}\n}\n";

    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const statement = fixture.find(.switch_stmt).as_statement().?;

    try std.testing.expectEqual(2, statement.clauses().count());
}

test "an operation reads its operands" {
    const source = "package held\n\nfunc run() {\n\tone := two + three\n}\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const operation = fixture.find(.binary_expr).as_operation().?;

    try std.testing.expectEqual(2, operation.operands().count());
    try std.testing.expectEqual(1, tally(operation.operator_tokens()));
}

test "a literal names its class" {
    try std.testing.expectEqual(Literal.number, literal_class("1"));
    try std.testing.expectEqual(Literal.rune, literal_class("'c'"));
    try std.testing.expectEqual(Literal.text, literal_class("\"held\""));
    try std.testing.expectEqual(Literal.text, literal_class("`held`"));
}

test View {
    const gpa = std.testing.allocator;
    const fronts = try gpa.create(Fronts);
    defer gpa.destroy(fronts);

    try fronts.init(gpa, &capacity_doctest, .initOne(.go), &.{});
    defer fronts.deinit(gpa);

    const source = "package main\n\nfunc greet(name string) string {\n\treturn name\n}\n";
    const parsed = try fronts.parse(.of(.go), source);
    const top = parsed.root_as(View);
    const function = parsed.view_as(View, parsed.nodes_of(.function)[0]).as_function().?;
    const name = top.token_at(function.name_token().?).text(source);

    try std.testing.expectEqual(Kind.file, top.kind());
    try std.testing.expectEqualStrings("greet", name);
}

const capacity_doctest: Front.Capacity = .{
    .diagnostic_count_max = 1 << 6,
    .event_count_max = 1 << 12,
    .node_count_max = 1 << 10,
    .semantic = null,
    .tag_count_max = 1 << 6,
    .token_count_max = 1 << 10,
};
