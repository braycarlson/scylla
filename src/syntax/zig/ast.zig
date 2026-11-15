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
pub const Literal = enum { character, multiline, number, text };

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

    pub fn as_container(view: View) ?Container {
        assert(view.node < view.tree.count());

        const held = view.cast(&container_kinds) orelse return null;

        assert(kind_in(held.kind(), &container_kinds));
        assert(held.node == view.node);

        return .{ .view = held };
    }

    pub fn as_declaration(view: View) ?Declaration {
        assert(view.node < view.tree.count());

        const held = view.cast(&.{.var_decl}) orelse return null;

        assert(held.kind() == .var_decl);
        assert(held.node == view.node);

        return .{ .view = held };
    }

    pub fn as_field(view: View) ?Field {
        assert(view.node < view.tree.count());

        const held = view.cast(&.{.container_field}) orelse return null;

        assert(held.kind() == .container_field);
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

    pub fn positions_of(view: View, wanted: Kind) Positions {
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

        if (call.view.kind() == .call) _ = found.next();

        if (found.current) |child| assert(child > call.view.node);

        return found;
    }

    pub fn callee(call: Call) ?View {
        assert(kind_in(call.view.kind(), &call_kinds));

        if (call.view.kind() == .builtin_call) return null;

        const held = call.view.child_first() orelse return null;

        assert(held.node > call.view.node);

        return held;
    }

    pub fn name_token(call: Call) ?u32 {
        assert(kind_in(call.view.kind(), &call_kinds));

        if (call.view.kind() == .builtin_call) return call.view.token_first(.builtin);

        const held = call.callee() orelse return null;
        if (held.kind() == .field_access) return held.positions_of(.identifier).last();

        const position = held.token_first(.identifier) orelse return null;

        assert(held.token_kind(position) == .identifier);

        return position;
    }
};

pub const Container = struct {
    view: View,

    pub fn declarations(container: Container) Children {
        assert(kind_in(container.view.kind(), &container_kinds));

        const found = container.view.children_of(.var_decl);

        assert(found.kind.? == .var_decl);

        return found;
    }

    pub fn fields(container: Container) Children {
        assert(kind_in(container.view.kind(), &container_kinds));

        const found = container.view.children_of(.container_field);

        assert(found.kind.? == .container_field);

        return found;
    }

    pub fn functions(container: Container) Children {
        assert(kind_in(container.view.kind(), &container_kinds));

        const found = container.view.children_of(.fn_decl);

        assert(found.kind.? == .fn_decl);

        return found;
    }

    fn is_tagged(container: Container) bool {
        assert(container.view.node < container.view.tree.count());

        const held = container.view.kind();

        assert(kind_in(held, &container_kinds));
        assert(held.is_node());

        return held == .tagged_union;
    }

    pub fn keyword(container: Container) ?Kind {
        assert(kind_in(container.view.kind(), &container_kinds));

        var found = container.view.positions();
        const position = found.next() orelse return null;

        assert(position >= container.view.token_start());

        return container.view.token_kind(position);
    }
};

pub const Declaration = struct {
    view: View,

    fn value_start(declaration: Declaration) u32 {
        assert(declaration.view.kind() == .var_decl);

        const end = declaration.view.token_end();
        const start = declaration.view.token_first(.equal) orelse end;

        assert(start <= end);

        return start;
    }

    pub fn is_mutable(declaration: Declaration) bool {
        assert(declaration.view.kind() == .var_decl);

        const held = declaration.view.holds(.var_keyword);

        if (held) assert(declaration.view.token_start() < declaration.view.token_end());

        return held;
    }

    pub fn is_public(declaration: Declaration) bool {
        assert(declaration.view.kind() == .var_decl);

        const held = declaration.view.holds(.pub_keyword);

        if (held) assert(declaration.view.token_start() < declaration.view.token_end());

        return held;
    }

    pub fn name_token(declaration: Declaration) ?u32 {
        assert(declaration.view.kind() == .var_decl);

        const position = declaration.view.token_first(.identifier) orelse return null;

        assert(declaration.view.token_kind(position) == .identifier);

        return position;
    }

    pub fn type_of(declaration: Declaration) ?View {
        assert(declaration.view.node < declaration.view.tree.count());

        const colon = declaration.view.token_first(.colon) orelse return null;
        const stop = declaration.value_start();
        var found = declaration.view.children();

        assert(declaration.view.kind() == .var_decl);

        assert(colon < declaration.view.token_end());

        for (0..declaration.view.tree.count()) |_| {
            const held = found.next() orelse return null;
            if (held.token_start() <= colon) continue;
            if (held.token_end() > stop) continue;

            assert(held.node > declaration.view.node);

            return held;
        }

        return null;
    }

    pub fn value(declaration: Declaration) ?View {
        assert(declaration.view.kind() == .var_decl);

        const equal = declaration.view.token_first(.equal) orelse return null;
        const held = child_after(declaration.view, equal) orelse return null;

        assert(held.token_start() > equal);

        return held;
    }
};

pub const Field = struct {
    view: View,

    fn is_named(field: Field) bool {
        assert(field.view.kind() == .container_field);

        const held = field.view.holds(.colon);

        if (held) assert(field.view.token_start() < field.view.token_end());

        return held;
    }

    pub fn name_token(field: Field) ?u32 {
        assert(field.view.kind() == .container_field);

        const position = field.view.token_first(.identifier) orelse return null;

        assert(field.view.token_kind(position) == .identifier);

        return position;
    }

    pub fn type_of(field: Field) ?View {
        assert(field.view.kind() == .container_field);

        const held = field.view.child_first() orelse return null;

        assert(held.node > field.view.node);

        return held;
    }

    pub fn value(field: Field) ?View {
        assert(field.view.kind() == .container_field);

        const equal = field.view.token_first(.equal) orelse return null;
        const held = child_after(field.view, equal) orelse return null;

        assert(held.token_start() > equal);

        return held;
    }
};

pub const Function = struct {
    view: View,

    pub fn body(function: Function) ?View {
        assert(kind_in(function.view.kind(), &function_kinds));

        const held = function.view.child_first_of(.block) orelse return null;

        assert(held.kind() == .block);

        return held;
    }

    fn is_extern(function: Function) bool {
        assert(kind_in(function.view.kind(), &function_kinds));

        const signature = function.prototype() orelse return false;

        assert(signature.kind() == .fn_proto);

        return signature.holds(.extern_keyword);
    }

    pub fn is_public(function: Function) bool {
        assert(kind_in(function.view.kind(), &function_kinds));

        const signature = function.prototype() orelse return false;

        assert(signature.kind() == .fn_proto);

        return signature.holds(.pub_keyword);
    }

    pub fn name_token(function: Function) ?u32 {
        assert(kind_in(function.view.kind(), &function_kinds));

        const signature = function.prototype() orelse return null;
        const position = signature.token_first(.identifier) orelse return null;

        assert(signature.token_kind(position) == .identifier);

        return position;
    }

    pub fn parameters(function: Function) Parameters {
        assert(kind_in(function.view.kind(), &function_kinds));

        const signature = function.prototype() orelse {
            return .{
                .children = function.view.children_empty(),
                .closing = null,
                .remaining = 0,
            };
        };

        const children = signature.children();

        const found: Parameters = .{
            .children = children,
            .closing = signature.token_first(.paren_close),
            .remaining = children.remaining,
        };

        if (found.closing) |closing| assert(closing < signature.token_end());

        return found;
    }

    pub fn prototype(function: Function) ?View {
        assert(kind_in(function.view.kind(), &function_kinds));

        if (function.view.kind() == .fn_proto) return function.view;

        const held = function.view.child_first_of(.fn_proto) orelse return null;

        assert(held.node > function.view.node);

        return held;
    }

    pub fn returns(function: Function) ?View {
        assert(kind_in(function.view.kind(), &function_kinds));

        const signature = function.prototype() orelse return null;
        const closing = signature.token_first(.paren_close) orelse return null;
        const held = child_after(signature, closing) orelse return null;

        assert(held.token_start() > closing);

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

pub const Statement = struct {
    view: View,

    pub fn body(statement: Statement) ?View {
        assert(kind_in(statement.view.kind(), &statement_kinds));

        const found = statement.view.children_of(.block);
        const held = found.last() orelse return null;

        assert(held.kind() == .block);

        return held;
    }

    pub fn cases(statement: Statement) Children {
        assert(kind_in(statement.view.kind(), &statement_kinds));

        const found = statement.view.children_of(.switch_case);

        assert(found.kind.? == .switch_case);

        return found;
    }

    pub fn header(statement: Statement) ?View {
        assert(kind_in(statement.view.kind(), &statement_kinds));

        const held = statement.view.child_first() orelse return null;

        assert(held.node > statement.view.node);

        return held;
    }

    pub fn statements(statement: Statement) Children {
        assert(kind_in(statement.view.kind(), &statement_kinds));

        if (statement.view.kind() == .block) return statement.view.children();

        const held = statement.body() orelse return statement.view.children_empty();

        assert(held.kind() == .block);

        return held.children();
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

pub const Parameters = struct {
    children: Children,
    closing: ?u32,
    remaining: u32,

    pub fn next(parameters: *Parameters) ?View {
        assert(parameters.children.kind == null);
        assert(parameters.remaining <= parameters.children.tree.count());

        if (parameters.remaining == 0) return null;

        for (0..parameters.children.tree.count()) |_| {
            const held = parameters.children.next() orelse return null;
            const closing = parameters.closing orelse continue;
            if (held.token_end() > closing) continue;

            assert(held.token_end() <= closing);

            parameters.remaining -= 1;

            return held;
        }

        assert(parameters.children.current == null);

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

    pub fn last(positions: *const Positions) ?u32 {
        var rest = positions.*;
        var found: ?u32 = null;

        for (0..positions.raw.len + 1) |_| {
            found = rest.next() orelse break;
        }

        assert(rest.position >= rest.limit);
        if (found) |position| assert(position < positions.limit);

        return found;
    }

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

const call_kinds = [_]Kind{ .builtin_call, .call };
const container_kinds = [_]Kind{ .container_decl, .tagged_union };
const function_kinds = [_]Kind{ .fn_decl, .fn_proto };

const operation_kinds = [_]Kind{
    .address_of,
    .bit_not,
    .bool_not,
    .@"catch",
    .negation,
    .@"orelse",
    .@"try",
    .unwrap_optional,
};

const statement_kinds = [_]Kind{
    .block,
    .@"defer",
    .@"errdefer",
    .@"for",
    .@"if",
    .@"switch",
    .test_decl,
    .@"while",
};

const tally_max: u32 = 1 << 16;

pub fn literal_class(text: []const u8) Literal {
    assert(text.len <= std.math.maxInt(u32));

    if (text.len == 0) return .number;

    const held: Literal = switch (text[0]) {
        '"' => .text,
        '\'' => .character,
        '\\' => .multiline,
        else => .number,
    };

    if (held == .text) assert(text[0] == '"');
    if (held == .number) assert(text[0] != '"');

    return held;
}

fn child_after(view: View, position: u32) ?View {
    assert(position >= view.token_start());

    var found = view.children();

    assert(position < view.token_end());

    for (0..view.tree.count()) |_| {
        const held = found.next() orelse return null;
        if (held.token_start() <= position) continue;

        assert(held.node > view.node);

        return held;
    }

    return null;
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

        assert(held.kind() == .root);
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
    const source = "pub fn run(one: u32, two: []const u8) u32 {\n    return one;\n}\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const held = fixture.find(.fn_decl).as_function().?;
    const position = held.name_token().?;

    try std.testing.expect(held.is_public());
    try std.testing.expect(!held.is_extern());
    try std.testing.expectEqual(2, tally(held.parameters()));
    try std.testing.expectEqualStrings("u32", held.returns().?.text(source));
    try std.testing.expectEqual(Kind.block, held.body().?.kind());
    try std.testing.expectEqualStrings("run", held.view.token_at(position).text(source));
}

test "a declaration reads its type and its value" {
    const source = "pub var held: u32 = 1;\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const held = fixture.find(.var_decl).as_declaration().?;
    const position = held.name_token().?;

    try std.testing.expect(held.is_mutable());
    try std.testing.expect(held.is_public());
    try std.testing.expectEqualStrings("u32", held.type_of().?.text(source));
    try std.testing.expectEqualStrings("1", held.value().?.text(source));
    try std.testing.expectEqualStrings("held", held.view.token_at(position).text(source));
}

test "a container reads its fields and its functions" {
    const source = "const Held = struct {\n    one: u32 = 0,\n    fn run() void {}\n};\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const held = fixture.find(.container_decl).as_container().?;

    try std.testing.expect(!held.is_tagged());
    try std.testing.expectEqual(Kind.struct_keyword, held.keyword().?);
    try std.testing.expectEqual(1, held.fields().count());
    try std.testing.expectEqual(1, held.functions().count());

    var fields = held.fields();
    const field = fields.next().?.as_field().?;

    try std.testing.expect(field.is_named());
    try std.testing.expectEqualStrings("u32", field.type_of().?.text(source));
    try std.testing.expectEqualStrings("0", field.value().?.text(source));
}

test "a call reads its callee and its arguments" {
    const source = "fn run() void {\n    std.debug.print(one, two);\n}\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const held = fixture.find(.call).as_call().?;
    const position = held.name_token().?;

    try std.testing.expectEqual(2, held.arguments().count());
    try std.testing.expectEqualStrings("print", held.view.token_at(position).text(source));
}

test "a builtin call names itself" {
    const source = "const held = @import(\"std\");\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const held = fixture.find(.builtin_call).as_call().?;
    const position = held.name_token().?;

    try std.testing.expect(held.callee() == null);
    try std.testing.expectEqual(1, held.arguments().count());
    try std.testing.expectEqualStrings("@import", held.view.token_at(position).text(source));
}

test "a statement reads its body and its cases" {
    const source = "fn run(one: u32) void {\nswitch (one) {\n0 => {},\nelse => {},\n}\n}\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const held = fixture.find(.@"switch").as_statement().?;

    try std.testing.expectEqual(2, held.cases().count());
    try std.testing.expectEqualStrings("one", held.header().?.text(source));
}

test "a block reads its statements" {
    const source = "fn run() void {\n    one();\n    two();\n}\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const held = fixture.find(.block).as_statement().?;

    try std.testing.expectEqual(2, held.statements().count());
}

test "an operation reads its operands" {
    const source = "fn run() void {\n    const held = one orelse two;\n    _ = held;\n}\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const held = fixture.find(.@"orelse").as_operation().?;

    try std.testing.expectEqual(2, held.operands().count());
    try std.testing.expectEqual(1, tally(held.operator_tokens()));
}

test "a literal names its class" {
    try std.testing.expectEqual(Literal.number, literal_class("1"));
    try std.testing.expectEqual(Literal.character, literal_class("'c'"));
    try std.testing.expectEqual(Literal.text, literal_class("\"held\""));
    try std.testing.expectEqual(Literal.multiline, literal_class("\\\\held"));
}

test View {
    const gpa = std.testing.allocator;
    const fronts = try gpa.create(Fronts);
    defer gpa.destroy(fronts);

    try fronts.init(gpa, &capacity_doctest, .initOne(.zig), &.{});
    defer fronts.deinit(gpa);

    const source = "fn greet(name: []const u8) []const u8 {\n    return name;\n}\n";
    const parsed = try fronts.parse(.of(.zig), source);
    const top = parsed.root_as(View);
    const function = parsed.view_as(View, parsed.nodes_of(.function)[0]).as_function().?;
    const name = top.token_at(function.name_token().?).text(source);

    try std.testing.expectEqual(Kind.root, top.kind());
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
