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

pub const Literal = enum {
    boolean,
    byte,
    byte_string,
    c_string,
    character,
    float,
    integer,
    text,
};

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

        const held = view.cast(&call_kinds) orelse return null;

        assert(kind_in(held.kind(), &call_kinds));
        assert(held.node == view.node);

        return .{ .view = held };
    }

    pub fn as_constant(view: View) ?Constant {
        assert(view.node < view.tree.count());

        const held = view.cast(&constant_kinds) orelse return null;

        assert(kind_in(held.kind(), &constant_kinds));
        assert(held.node == view.node);

        return .{ .view = held };
    }

    pub fn as_definition(view: View) ?Definition {
        assert(view.node < view.tree.count());

        const held = view.cast(&definition_kinds) orelse return null;

        assert(kind_in(held.kind(), &definition_kinds));
        assert(held.node == view.node);

        return .{ .view = held };
    }

    pub fn as_field(view: View) ?Field {
        assert(view.node < view.tree.count());

        const held = view.cast(&field_kinds) orelse return null;

        assert(kind_in(held.kind(), &field_kinds));
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

    pub fn as_local(view: View) ?Local {
        assert(view.node < view.tree.count());

        const held = view.cast(&.{.local}) orelse return null;

        assert(held.kind() == .local);
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

    fn as_path(view: View) ?PathView {
        assert(view.node < view.tree.count());

        const held = view.cast(&.{.path}) orelse return null;

        assert(held.kind() == .path);
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

    pub fn as_use(view: View) ?Use {
        assert(view.node < view.tree.count());

        const held = view.cast(&.{.item_use}) orelse return null;

        assert(held.kind() == .item_use);
        assert(held.node == view.node);

        return .{ .view = held };
    }

    pub fn at(view: View, node: u32) View {
        assert(node < view.tree.count());
        assert(view.tokens.len == view.raw.len);

        return .{ .node = node, .raw = view.raw, .tokens = view.tokens, .tree = view.tree };
    }

    pub fn child_at(view: View, ordinal: u32) ?View {
        assert(view.node < view.tree.count());

        var found = view.children();

        if (ordinal >= view.tree.count()) return null;

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
        assert(kind_in(call.view.kind(), &call_kinds));

        var found = call.view.children();

        if (call.view.kind() != .expr_macro) _ = found.next();

        if (found.current) |child| assert(child > call.view.node);

        return found;
    }

    pub fn callee(call: Call) ?View {
        assert(kind_in(call.view.kind(), &call_kinds));

        const held = call.view.child_first() orelse return null;

        assert(held.node > call.view.node);

        return held;
    }

    pub fn name_token(call: Call) ?u32 {
        assert(kind_in(call.view.kind(), &call_kinds));

        if (call.view.kind() == .expr_method_call) return ident_token(call.view);

        const held = call.callee() orelse return null;
        const path = held.child_first_of(.path) orelse return null;
        const segment = path.children_of(.path_segment).last() orelse return null;

        assert(segment.kind() == .path_segment);

        return ident_token(segment);
    }
};

pub const Constant = struct {
    view: View,

    pub fn literal_class(constant: Constant) Literal {
        assert(constant.view.node < constant.view.tree.count());

        const held = constant.view.kind();

        assert(kind_in(held, &constant_kinds));
        assert(held.is_node());

        return switch (held) {
            .lit_bool => .boolean,
            .lit_byte => .byte,
            .lit_byte_str => .byte_string,
            .lit_c_str => .c_string,
            .lit_char => .character,
            .lit_float => .float,
            .lit_int => .integer,
            else => .text,
        };
    }
};

pub const Definition = struct {
    view: View,

    pub fn fields(definition: Definition) Fields {
        assert(kind_in(definition.view.kind(), &definition_kinds));

        const groups = definition.view.children();

        const found: Fields = .{
            .groups = groups,
            .members = definition.view.children_empty(),
            .remaining = groups.remaining,
        };

        assert(found.members.current == null);

        return found;
    }

    pub fn generics(definition: Definition) ?View {
        assert(kind_in(definition.view.kind(), &definition_kinds));

        const held = definition.view.child_first_of(.generics) orelse return null;

        assert(held.kind() == .generics);

        return held;
    }

    pub fn members(definition: Definition) Matching {
        assert(kind_in(definition.view.kind(), &definition_kinds));

        const children = definition.view.children();

        const found: Matching = .{
            .children = children,
            .kinds = &member_kinds,
            .remaining = children.remaining,
        };

        assert(found.children.kind == null);

        return found;
    }

    pub fn name_token(definition: Definition) ?u32 {
        assert(kind_in(definition.view.kind(), &definition_kinds));

        const position = ident_token(definition.view) orelse return null;

        assert(position >= definition.view.token_start());

        return position;
    }

    pub fn variants(definition: Definition) Children {
        assert(kind_in(definition.view.kind(), &definition_kinds));

        const found = definition.view.children_of(.variant);

        assert(found.kind.? == .variant);

        return found;
    }

    fn where_clause(definition: Definition) ?View {
        assert(kind_in(definition.view.kind(), &definition_kinds));

        const held = definition.view.child_first_of(.where_clause) orelse return null;

        assert(held.kind() == .where_clause);

        return held;
    }
};

pub const Field = struct {
    view: View,

    pub fn attributes(field: Field) Children {
        assert(kind_in(field.view.kind(), &field_kinds));

        const found = field.view.children_of(.attribute);

        assert(found.kind.? == .attribute);

        return found;
    }

    pub fn name_token(field: Field) ?u32 {
        assert(kind_in(field.view.kind(), &field_kinds));

        const position = ident_token(field.view) orelse return null;

        assert(position >= field.view.token_start());

        return position;
    }

    pub fn type_of(field: Field) ?View {
        assert(kind_in(field.view.kind(), &field_kinds));

        var found = field.view.children();

        for (0..field.view.tree.count()) |_| {
            const held = found.next() orelse return null;
            if (!held.kind().is_type()) continue;

            assert(held.node > field.view.node);

            return held;
        }

        return null;
    }
};

pub const Function = struct {
    view: View,

    fn holds(function: Function, wanted: Kind) bool {
        assert(kind_in(function.view.kind(), &function_kinds));
        assert(wanted.is_token());

        const held = function.signature() orelse return false;
        return held.holds(wanted);
    }

    pub fn attributes(function: Function) Children {
        assert(kind_in(function.view.kind(), &function_kinds));

        const found = function.view.children_of(.attribute);

        assert(found.kind.? == .attribute);

        return found;
    }

    pub fn body(function: Function) ?View {
        assert(kind_in(function.view.kind(), &function_kinds));

        const held = function.view.child_first_of(.block) orelse return null;

        assert(held.kind() == .block);

        return held;
    }

    pub fn is_async(function: Function) bool {
        assert(kind_in(function.view.kind(), &function_kinds));

        const held = function.holds(.async_keyword);

        if (held) assert(function.signature() != null);

        return held;
    }

    fn is_const(function: Function) bool {
        assert(kind_in(function.view.kind(), &function_kinds));

        const held = function.holds(.const_keyword);

        if (held) assert(function.signature() != null);

        return held;
    }

    fn is_unsafe(function: Function) bool {
        assert(kind_in(function.view.kind(), &function_kinds));

        const held = function.holds(.unsafe_keyword);

        if (held) assert(function.signature() != null);

        return held;
    }

    pub fn name_token(function: Function) ?u32 {
        assert(kind_in(function.view.kind(), &function_kinds));

        const held = function.signature() orelse return null;
        const position = ident_token(held) orelse return null;

        assert(position >= held.token_start());

        return position;
    }

    pub fn parameters(function: Function) Matching {
        assert(kind_in(function.view.kind(), &function_kinds));

        const held = function.signature() orelse {
            return .{
                .children = function.view.children_empty(),
                .kinds = &parameter_kinds,
                .remaining = 0,
            };
        };

        const children = held.children();

        assert(held.kind() == .signature);

        return .{
            .children = children,
            .kinds = &parameter_kinds,
            .remaining = children.remaining,
        };
    }

    pub fn signature(function: Function) ?View {
        assert(kind_in(function.view.kind(), &function_kinds));

        const held = function.view.child_first_of(.signature) orelse return null;

        assert(held.kind() == .signature);

        return held;
    }
};

pub const Local = struct {
    view: View,

    pub fn target(local: Local) ?View {
        assert(local.view.kind() == .local);

        const held = child_first_besides(local.view, .attribute) orelse return null;

        assert(held.kind() != .attribute);

        return held;
    }

    pub fn value(local: Local) ?View {
        assert(local.view.kind() == .local);

        const found = local.view.children();
        const held = found.last() orelse return null;

        assert(held.node > local.view.node);

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

const PathView = struct {
    view: View,

    fn is_rooted(path: PathView) bool {
        assert(path.view.kind() == .path);

        const position = path.view.token_first(.colon_colon) orelse return false;

        assert(position >= path.view.token_start());

        return position == path.view.token_start();
    }

    pub fn segments(path: PathView) Children {
        assert(path.view.kind() == .path);

        const found = path.view.children_of(.path_segment);

        assert(found.kind.? == .path_segment);

        return found;
    }
};

pub const Statement = struct {
    view: View,

    pub fn arms(statement: Statement) Children {
        assert(kind_in(statement.view.kind(), &statement_kinds));

        const found = statement.view.children_of(.arm);

        assert(found.kind.? == .arm);

        return found;
    }

    pub fn body(statement: Statement) ?View {
        assert(kind_in(statement.view.kind(), &statement_kinds));

        const held = statement.view.child_first_of(.block) orelse return null;

        assert(held.kind() == .block);

        return held;
    }

    pub fn header(statement: Statement) ?View {
        assert(kind_in(statement.view.kind(), &statement_kinds));

        const held = statement.view.child_first() orelse return null;

        assert(held.node > statement.view.node);

        return held;
    }
};

pub const Use = struct {
    view: View,

    pub fn tree(use: Use) ?View {
        assert(use.view.kind() == .item_use);

        const held = child_first_besides(use.view, .attribute) orelse return null;

        assert(held.kind() != .attribute);

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

pub const Fields = struct {
    groups: Children,
    members: Children,
    remaining: u32,

    pub fn next(fields: *Fields) ?View {
        assert(fields.groups.kind == null);
        assert(fields.remaining <= fields.groups.tree.count());

        if (fields.remaining == 0) return null;

        for (0..fields.groups.tree.count() + 1) |_| {
            if (fields.members.next()) |held| {
                assert(kind_in(held.parent().?.kind(), &field_group_kinds));

                fields.remaining -= 1;

                return held;
            }

            const group = fields.groups.next() orelse return null;

            if (kind_in(group.kind(), &field_group_kinds)) fields.members = group.children();
        }

        assert(fields.groups.current == null);

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

const call_kinds = [_]Kind{ .expr_call, .expr_macro, .expr_method_call };

const constant_kinds = [_]Kind{
    .lit_bool,
    .lit_byte,
    .lit_byte_str,
    .lit_c_str,
    .lit_char,
    .lit_float,
    .lit_int,
    .lit_str,
};

const definition_kinds = [_]Kind{
    .item_enum,
    .item_impl,
    .item_struct,
    .item_trait,
    .item_type,
    .item_union,
};

const field_group_kinds = [_]Kind{ .fields_named, .fields_unnamed };
const field_kinds = [_]Kind{ .field, .variant };

const function_kinds = [_]Kind{
    .expr_closure,
    .foreign_item_fn,
    .impl_item_fn,
    .item_fn,
    .trait_item_fn,
};

const member_kinds = [_]Kind{
    .impl_item_const,
    .impl_item_fn,
    .impl_item_type,
    .trait_item_const,
    .trait_item_fn,
    .trait_item_type,
};

const operation_kinds = [_]Kind{
    .expr_assign,
    .expr_binary,
    .expr_cast,
    .expr_range,
    .expr_unary,
};

const parameter_kinds = [_]Kind{ .pat_type, .receiver };

const statement_kinds = [_]Kind{
    .expr_for_loop,
    .expr_if,
    .expr_loop,
    .expr_match,
    .expr_unsafe,
    .expr_while,
};

const tally_max: u32 = 1 << 16;

fn child_first_besides(view: View, skipped: Kind) ?View {
    assert(view.node < view.tree.count());

    var found = view.children();

    assert(skipped.is_node());

    for (0..view.tree.count()) |_| {
        const held = found.next() orelse return null;
        if (held.kind() == skipped) continue;

        assert(held.node > view.node);

        return held;
    }

    return null;
}

fn ident_token(view: View) ?u32 {
    assert(view.node < view.tree.count());

    const held = view.child_first_of(.ident) orelse return null;
    var found = held.positions();
    const position = found.next() orelse return null;

    assert(position >= held.token_start());
    assert(position < held.token_end());

    return position;
}

fn kind_in(kind: Kind, kinds: []const Kind) bool {
    assert(kinds.len > 0);
    if (kind == .error_node) return false;

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
    const source = "pub async unsafe fn run(one: u32, two: &str) -> u32 { one }\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const held = fixture.find(.item_fn).as_function().?;
    const position = held.name_token().?;

    try std.testing.expect(held.is_async());
    try std.testing.expect(held.is_unsafe());
    try std.testing.expect(!held.is_const());
    try std.testing.expectEqual(2, tally(held.parameters()));
    try std.testing.expectEqual(Kind.block, held.body().?.kind());
    try std.testing.expectEqualStrings("run", held.view.token_at(position).text(source));
}

test "a struct reads its name and its fields" {
    const source = "pub struct Widget<T> { pub one: u32, two: T }\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const held = fixture.find(.item_struct).as_definition().?;
    const position = held.name_token().?;

    try std.testing.expectEqual(2, tally(held.fields()));
    try std.testing.expect(held.generics() != null);
    try std.testing.expectEqualStrings("Widget", held.view.token_at(position).text(source));
}

test "an impl reads its members" {
    const source = "impl Widget { const ONE: u32 = 1; fn run(&self) {} }\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const held = fixture.find(.item_impl).as_definition().?;

    try std.testing.expectEqual(2, tally(held.members()));
}

test "a call reads its callee and its arguments" {
    const source = "fn run() { helper(one, two); }\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const held = fixture.find(.expr_call).as_call().?;
    const position = held.name_token().?;

    try std.testing.expectEqual(2, held.arguments().count());
    try std.testing.expectEqualStrings("helper", held.view.token_at(position).text(source));
}

test "a method call names itself" {
    const source = "fn run() { value.method(one); }\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const held = fixture.find(.expr_method_call).as_call().?;
    const position = held.name_token().?;

    try std.testing.expectEqualStrings("method", held.view.token_at(position).text(source));
}

test "a local reads its target and its value" {
    const source = "fn run() { let one: u32 = 1; }\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const held = fixture.find(.local).as_local().?;

    try std.testing.expectEqual(Kind.pat_type, held.target().?.kind());
    try std.testing.expectEqualStrings("1", held.value().?.text(source));
}

test "a constant reads its class" {
    const source = "const ONE: f32 = 1.5;\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const held = fixture.find(.lit_float).as_constant().?;

    try std.testing.expectEqual(Literal.float, held.literal_class());
}

test "a path reads its segments" {
    const source = "fn run() { ::std::mem::drop(one); }\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const held = fixture.find(.path).as_path().?;

    try std.testing.expectEqual(3, held.segments().count());
    try std.testing.expect(held.is_rooted());
}

test "a match reads its arms" {
    const source = "fn run() { match one { 1 => 2, _ => 3 } }\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const held = fixture.find(.expr_match).as_statement().?;

    try std.testing.expectEqual(2, held.arms().count());
}

test "a use reads its tree" {
    const source = "use std::collections::HashMap;\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const held = fixture.find(.item_use).as_use().?;

    try std.testing.expectEqual(Kind.use_path, held.tree().?.kind());
}

test "an operation reads its operands" {
    const source = "fn run() { let held = one + two; }\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const held = fixture.find(.expr_binary).as_operation().?;

    try std.testing.expectEqual(2, held.operands().count());
    try std.testing.expectEqual(1, tally(held.operator_tokens()));
}

test View {
    const gpa = std.testing.allocator;
    const fronts = try gpa.create(Fronts);
    defer gpa.destroy(fronts);

    try fronts.init(gpa, &capacity_doctest, .initOne(.rust), &.{});
    defer fronts.deinit(gpa);

    const source = "fn greet(name: &str) -> &str {\n    name\n}\n";
    const parsed = try fronts.parse(.of(.rust), source);
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
