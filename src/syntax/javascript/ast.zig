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
const raw_of = @import("../raw.zig").raw_of;
const lex = @import("lex.zig").lex;
const Front = @import("../front.zig").Front;
const Fronts = @import("../fronts.zig").Fronts;
const Events = EventsType(Kind);
const Tree = TreeType(Kind);
pub const Literal = enum { boolean, null, number, regex, template, text, undefined };
pub const Member = enum { field, getter, method, setter, static_block };

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

        const held = view.cast(&call_kinds) orelse return null;

        assert(kind_in(held.kind(), &call_kinds));
        assert(held.node == view.node);

        return .{ .view = held };
    }

    pub fn as_class(view: View) ?ClassDeclaration {
        assert(view.node < view.tree.count());

        const held = view.cast(&class_kinds) orelse return null;

        assert(kind_in(held.kind(), &class_kinds));
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

    pub fn as_declarator(view: View) ?Declarator {
        assert(view.node < view.tree.count());

        const held = view.cast(&.{.variable_declarator}) orelse return null;

        assert(held.kind() == .variable_declarator);
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

    pub fn as_import(view: View) ?ImportStatement {
        assert(view.node < view.tree.count());

        const held = view.cast(&.{.import_statement}) orelse return null;

        assert(held.kind() == .import_statement);
        assert(held.node == view.node);

        return .{ .view = held };
    }

    pub fn as_member(view: View) ?MemberExpression {
        assert(view.node < view.tree.count());

        const held = view.cast(&member_kinds) orelse return null;

        assert(kind_in(held.kind(), &member_kinds));
        assert(held.node == view.node);

        return .{ .view = held };
    }

    fn as_method(view: View) ?MethodDefinition {
        assert(view.node < view.tree.count());

        const held = view.cast(&method_kinds) orelse return null;

        assert(kind_in(held.kind(), &method_kinds));
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

    fn as_pair(view: View) ?Pair {
        assert(view.node < view.tree.count());

        const held = view.cast(&pair_kinds) orelse return null;

        assert(kind_in(held.kind(), &pair_kinds));
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

    pub fn child_at(view: View, ordinal: u32) ?View {
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

    pub fn node_count(view: View) u32 {
        assert(view.node < view.tree.count());

        const held = view.tree.count();

        assert(view.node < held);

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

    pub fn sibling_next(view: View) ?View {
        assert(view.node < view.tree.count());

        const sibling = view.tree.sibling_next_of(view.node) orelse return null;

        assert(sibling > view.node);

        return view.at(sibling);
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

    pub fn token_count(view: View) u32 {
        assert(view.tokens.len == view.raw.len);
        assert(view.tokens.len <= std.math.maxInt(u32));

        return @intCast(view.tokens.len);
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

        const held = call.view.child_first_of(.arguments) orelse return children_empty(call.view);
        const found = held.children();

        assert(found.kind == null);

        return found;
    }

    pub fn callee(call: Call) ?View {
        assert(kind_in(call.view.kind(), &call_kinds));

        const held = call.view.child_first() orelse return null;

        assert(held.node > call.view.node);

        return held;
    }

    fn is_optional(call: Call) bool {
        assert(kind_in(call.view.kind(), &call_kinds));

        const held = call.view.child_first_of(.optional_chain);

        if (held) |chain| assert(chain.node > call.view.node);

        return held != null;
    }
};

pub const ClassDeclaration = struct {
    view: View,

    pub fn body(class: ClassDeclaration) ?View {
        assert(kind_in(class.view.kind(), &class_kinds));

        const held = class.view.child_first_of(.class_body) orelse return null;

        assert(held.kind() == .class_body);

        return held;
    }

    pub fn heritage(class: ClassDeclaration) ?View {
        assert(kind_in(class.view.kind(), &class_kinds));

        const clause = class.view.child_first_of(.class_heritage) orelse return null;
        const extends = clause.child_first_of(.extends_clause) orelse clause;
        const held = extends.child_first() orelse return null;

        assert(held.node > extends.node);

        return held;
    }

    pub fn members(class: ClassDeclaration) Children {
        assert(kind_in(class.view.kind(), &class_kinds));

        const held = class.body() orelse return children_empty(class.view);
        const found = held.children();

        assert(found.kind == null);

        return found;
    }

    pub fn name_token(class: ClassDeclaration) ?u32 {
        assert(kind_in(class.view.kind(), &class_kinds));

        const held = class.view.child_first_of(.identifier_node) orelse return null;
        var found = held.positions();
        const position = found.next() orelse return null;

        assert(position >= held.token_start());

        return position;
    }
};

pub const Constant = struct {
    view: View,

    fn content_span(constant: Constant) Span {
        assert(constant.view.node < constant.view.tree.count());

        const extent = constant.view.span();

        const quoted = switch (constant.literal_class()) {
            .regex, .template, .text => true,
            else => false,
        };

        if (!quoted) return extent;
        if (extent.length < 2) return extent;

        const inner: Span = .{ .offset = extent.offset + 1, .length = extent.length - 2 };

        assert(inner.offset > extent.offset);
        assert(inner.end() + 1 == extent.end());

        return inner;
    }

    pub fn literal_class(constant: Constant) Literal {
        assert(kind_in(constant.view.kind(), &constant_kinds));

        const class: Literal = switch (constant.view.kind()) {
            .false, .true => .boolean,
            .null => .null,
            .number_node => .number,
            .regex_node => .regex,
            .template_string => .template,
            .undefined => .undefined,
            else => .text,
        };

        if (class == .text) assert(constant.view.kind() == .string_node);

        return class;
    }
};

pub const Declarator = struct {
    view: View,

    pub fn target(declarator: Declarator) ?View {
        assert(declarator.view.kind() == .variable_declarator);

        const held = declarator.view.child_first() orelse return null;

        assert(held.node > declarator.view.node);

        return held;
    }

    pub fn value(declarator: Declarator) ?View {
        assert(declarator.view.kind() == .variable_declarator);

        var rest = declarator.view.children();

        _ = rest.next();

        for (0..declarator.view.tree.count()) |_| {
            const held = rest.next() orelse return null;
            if (held.kind() != .type_annotation) return held;
        }

        assert(rest.current == null);

        return null;
    }
};

pub const Function = struct {
    view: View,

    pub fn body(function: Function) ?View {
        assert(kind_in(function.view.kind(), &function_kinds));

        const held = function.view.children().last() orelse return null;

        assert(held.node > function.view.node);

        return held;
    }

    pub fn is_async(function: Function) bool {
        assert(kind_in(function.view.kind(), &function_kinds));

        const result = function.view.holds(.async_keyword);

        if (result) assert(function.view.token_end() > function.view.token_start());

        return result;
    }

    fn is_generator(function: Function) bool {
        assert(kind_in(function.view.kind(), &function_kinds));

        if (kind_in(function.view.kind(), &generator_kinds)) return true;

        const result = function.view.holds(.star);

        if (result) assert(function.view.token_end() > function.view.token_start());

        return result;
    }

    pub fn name_token(function: Function) ?u32 {
        assert(kind_in(function.view.kind(), &function_kinds));

        const held = child_first_in(function.view, &name_kinds) orelse return null;
        var found = held.positions();
        const position = found.next() orelse return null;

        assert(position >= held.token_start());
        assert(position < held.token_end());

        return position;
    }

    pub fn parameters(function: Function) Children {
        assert(kind_in(function.view.kind(), &function_kinds));

        const held = function.view.child_first_of(.formal_parameters) orelse {
            return children_empty(function.view);
        };

        const found = held.children();

        assert(found.kind == null);

        return found;
    }
};

pub const ImportStatement = struct {
    view: View,

    pub fn clause(import: ImportStatement) ?View {
        assert(import.view.kind() == .import_statement);

        const held = import.view.child_first_of(.import_clause) orelse return null;

        assert(held.kind() == .import_clause);

        return held;
    }

    pub fn source(import: ImportStatement) ?View {
        assert(import.view.kind() == .import_statement);

        const held = import.view.child_first_of(.string_node) orelse return null;

        assert(held.kind() == .string_node);

        return held;
    }

    fn specifiers(import: ImportStatement) Specifiers {
        assert(import.view.kind() == .import_statement);

        const empty = children_empty(import.view);
        const outer = if (import.clause()) |held| held.children() else empty;

        assert(outer.kind == null);

        return .{ .inner = empty, .outer = outer, .remaining = outer.remaining };
    }
};

pub const MemberExpression = struct {
    view: View,

    fn is_optional(member: MemberExpression) bool {
        assert(kind_in(member.view.kind(), &member_kinds));

        var found = member.view.children_of(.optional_chain);
        const held = found.next();

        if (held) |chain| assert(chain.kind() == .optional_chain);

        return held != null;
    }

    pub fn object(member: MemberExpression) ?View {
        assert(kind_in(member.view.kind(), &member_kinds));

        const held = member.view.child_first() orelse return null;

        assert(held.node > member.view.node);

        return held;
    }

    pub fn property(member: MemberExpression) ?View {
        assert(kind_in(member.view.kind(), &member_kinds));

        const held = member.view.children().last() orelse return null;
        const first = member.view.child_first().?;

        assert(held.node > member.view.node);
        assert(first.node <= held.node);

        if (first.node == held.node) return null;
        if (held.kind() == .optional_chain) return null;
        return held;
    }
};

const MethodDefinition = struct {
    view: View,

    fn names(method: MethodDefinition, word: []const u8) bool {
        assert(word.len > 0);
        assert(kind_in(method.view.kind(), &method_kinds));

        const position = method.view.token_first(.identifier) orelse return false;
        return method.view.token_at(position).length == word.len;
    }

    fn is_static(method: MethodDefinition) bool {
        assert(kind_in(method.view.kind(), &method_kinds));

        const result = method.view.holds(.static_keyword);

        if (result) assert(method.view.token_end() > method.view.token_start());

        return result;
    }

    pub fn key(method: MethodDefinition) ?View {
        assert(kind_in(method.view.kind(), &method_kinds));

        const held = method.view.child_first() orelse return null;

        assert(held.node > method.view.node);

        return held;
    }

    fn member_class(method: MethodDefinition) Member {
        assert(kind_in(method.view.kind(), &method_kinds));

        if (method.view.kind() == .class_static_block) return .static_block;
        if (method.view.kind() == .field_definition) return .field;
        if (method.view.kind() == .public_field_definition) return .field;
        if (method.names("get")) return .getter;
        if (method.names("set")) return .setter;

        assert(method.view.kind() == .method_definition);

        return .method;
    }

    pub fn value(method: MethodDefinition) ?View {
        assert(kind_in(method.view.kind(), &method_kinds));

        const held = method.view.children().last() orelse return null;

        assert(held.node > method.view.node);

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

const Pair = struct {
    view: View,

    pub fn key(pair: Pair) ?View {
        assert(kind_in(pair.view.kind(), &pair_kinds));

        const held = pair.view.child_first() orelse return null;

        assert(held.node > pair.view.node);

        return held;
    }

    pub fn value(pair: Pair) ?View {
        assert(kind_in(pair.view.kind(), &pair_kinds));

        const held = pair.view.children().last() orelse return null;

        assert(held.node > pair.view.node);

        return held;
    }
};

pub const Statement = struct {
    view: View,

    pub fn body(statement: Statement) ?View {
        assert(kind_in(statement.view.kind(), &statement_kinds));

        const held = statement.view.child_first_of(.statement_block) orelse return null;

        assert(held.kind() == .statement_block);

        return held;
    }

    pub fn cases(statement: Statement) Children {
        assert(kind_in(statement.view.kind(), &statement_kinds));

        const held = statement.view.child_first_of(.switch_body) orelse {
            return children_empty(statement.view);
        };

        const found = held.children();

        assert(found.kind == null);

        return found;
    }

    fn else_clause(statement: Statement) ?View {
        assert(kind_in(statement.view.kind(), &statement_kinds));

        const held = statement.view.child_first_of(.else_clause) orelse return null;

        assert(held.kind() == .else_clause);

        return held;
    }

    fn finally_clause(statement: Statement) ?View {
        assert(kind_in(statement.view.kind(), &statement_kinds));

        const held = statement.view.child_first_of(.finally_clause) orelse return null;

        assert(held.kind() == .finally_clause);

        return held;
    }

    pub fn handlers(statement: Statement) Children {
        assert(kind_in(statement.view.kind(), &statement_kinds));

        const found = statement.view.children_of(.catch_clause);

        assert(found.kind.? == .catch_clause);

        return found;
    }

    pub fn header(statement: Statement) ?View {
        assert(kind_in(statement.view.kind(), &statement_kinds));

        const held = statement.view.child_first_of(.parenthesized_expression) orelse
            statement.view.child_first() orelse return null;

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

const Specifiers = struct {
    inner: Children,
    outer: Children,
    remaining: u32,

    pub fn next(specifiers: *Specifiers) ?View {
        assert(specifiers.inner.kind == null);
        assert(specifiers.outer.kind == null);
        assert(specifiers.remaining <= specifiers.outer.tree.count());

        if (specifiers.remaining == 0) return null;

        for (0..specifiers.outer.tree.count()) |_| {
            if (specifiers.inner.next()) |nested| {
                specifiers.remaining -= 1;

                return nested;
            }

            const held = specifiers.outer.next() orelse return null;

            if (held.kind() != .named_imports) {
                specifiers.remaining -= 1;

                return held;
            }

            specifiers.inner = held.children();
        }

        assert(specifiers.outer.current == null);

        return null;
    }
};

const call_kinds = [_]Kind{ .call_expression, .new_expression };
const class_kinds = [_]Kind{ .class, .class_declaration };

const constant_kinds = [_]Kind{
    .false,
    .null,
    .number_node,
    .regex_node,
    .string_node,
    .template_string,
    .true,
    .undefined,
};

const function_kinds = [_]Kind{
    .arrow_function,
    .function_declaration,
    .function_expression,
    .generator_function,
    .generator_function_declaration,
    .method_definition,
};

const generator_kinds = [_]Kind{ .generator_function, .generator_function_declaration };
const member_kinds = [_]Kind{ .member_expression, .subscript_expression };

const method_kinds = [_]Kind{
    .class_static_block,
    .field_definition,
    .method_definition,
    .public_field_definition,
};

const name_kinds = [_]Kind{
    .identifier_node,
    .private_property_identifier,
    .property_identifier,
};

const operation_kinds = [_]Kind{
    .assignment_expression,
    .augmented_assignment_expression,
    .binary_expression,
    .ternary_expression,
    .unary_expression,
    .update_expression,
};

const pair_kinds = [_]Kind{ .pair, .pair_pattern };

const statement_kinds = [_]Kind{
    .do_statement,
    .for_in_statement,
    .for_statement,
    .if_statement,
    .labeled_statement,
    .return_statement,
    .switch_statement,
    .throw_statement,
    .try_statement,
    .while_statement,
    .with_statement,
};

const tally_max: u32 = 1 << 16;

fn child_first_in(view: View, kinds: []const Kind) ?View {
    assert(view.node < view.tree.count());

    var found = view.children();

    assert(kinds.len > 0);

    for (0..view.tree.count()) |_| {
        const held = found.next() orelse return null;
        if (kind_in(held.kind(), kinds)) return held;
    }

    assert(found.current == null);

    return null;
}

fn children_empty(view: View) Children {
    assert(view.node < view.tree.count());
    assert(view.tokens.len == view.raw.len);

    return .{
        .current = null,
        .kind = null,
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

        try lex(source, &fixture.tokens, .typescript);
        try raw_of(Kind, fixture.tokens.slice(), &fixture.raw);

        const structure = parser.build(
            source,
            fixture.tokens.slice(),
            fixture.raw.const_slice(),
            &events,
            &fixture.tree,
            .{ .dialect = .typescript, .goal = .module },
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

        assert(held.kind() == .program);
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

test "a view steps to its next sibling and counts the whole source" {
    const source = "first();\nsecond();\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const root = fixture.root();
    const first = root.child_first() orelse return error.FirstMissing;
    const second = first.sibling_next() orelse return error.SecondMissing;
    const by_ordinal = root.child_at(1) orelse return error.OrdinalMissing;

    try std.testing.expectEqual(by_ordinal.index(), second.index());
    try std.testing.expect(second.sibling_next() == null);
    try std.testing.expect(root.sibling_next() == null);
    try std.testing.expectEqual(fixture.tree.count(), first.node_count());
    try std.testing.expectEqual(fixture.raw.count(), second.token_count());
}

test "a call reads its callee and its arguments" {
    const source = "handler(one, two);\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const call = fixture.find(.call_expression).as_call().?;

    try std.testing.expectEqualStrings("handler", call.callee().?.text(source));
    try std.testing.expectEqual(2, call.arguments().count());
    try std.testing.expect(!call.is_optional());
}

test "a function reads its name parameters and body" {
    const source = "async function* run(one, two) { return one; }\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const function = fixture.find(.generator_function_declaration).as_function().?;
    const position = function.name_token().?;

    try std.testing.expect(function.is_async());
    try std.testing.expect(function.is_generator());
    try std.testing.expectEqual(2, function.parameters().count());
    try std.testing.expectEqual(Kind.statement_block, function.body().?.kind());
    try std.testing.expectEqualStrings("run", function.view.token_at(position).text(source));
}

test "a class reads its heritage and its members" {
    const source = "class Widget extends Base { static run() {} field = 1; }\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const class = fixture.find(.class_declaration).as_class().?;

    try std.testing.expectEqualStrings("Base", class.heritage().?.text(source));
    try std.testing.expectEqual(2, class.members().count());

    var members = class.members();
    const method = members.next().?.as_method().?;

    try std.testing.expect(method.is_static());
    try std.testing.expectEqual(Member.method, method.member_class());
}

test "a member expression reads its object and its property" {
    const source = "target?.field;\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const member = fixture.find(.member_expression).as_member().?;

    try std.testing.expect(member.is_optional());
    try std.testing.expectEqualStrings("target", member.object().?.text(source));
    try std.testing.expectEqualStrings("field", member.property().?.text(source));
}

test "a member expression missing its property reads no property" {
    const sources = [_][]const u8{ "target.(\n", "target.;\n", "target?.;\n" };

    for (sources) |source| {
        var fixture: Fixture = undefined;

        try fixture.init(source);
        defer fixture.deinit();

        const member = fixture.find(.member_expression).as_member().?;

        try std.testing.expectEqualStrings("target", member.object().?.text(source));
        try std.testing.expectEqual(null, member.property());
    }
}

test "a declarator reads its target and its value" {
    const source = "const one = 1;\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const declarator = fixture.find(.variable_declarator).as_declarator().?;

    try std.testing.expectEqualStrings("one", declarator.target().?.text(source));
    try std.testing.expectEqualStrings("1", declarator.value().?.text(source));
}

test "an import reads its source and its specifiers" {
    const source = "import one, { two as three } from \"module\";\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const import = fixture.find(.import_statement).as_import().?;

    try std.testing.expectEqualStrings("\"module\"", import.source().?.text(source));
    try std.testing.expectEqual(2, tally(import.specifiers()));
}

test "a constant reads its class and its content" {
    const source = "const text = \"body\";\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const constant = fixture.find(.string_node).as_constant().?;

    try std.testing.expectEqual(Literal.text, constant.literal_class());
    try std.testing.expectEqualStrings("body", constant.content_span().text(source));
}

test "a pair reads its key and its value" {
    const source = "const held = { one: 1 };\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const pair = fixture.find(.pair).as_pair().?;

    try std.testing.expectEqualStrings("one", pair.key().?.text(source));
    try std.testing.expectEqualStrings("1", pair.value().?.text(source));
}

test "a statement reads its header and its body" {
    const source = "if (one) { two(); } else { three(); }\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const statement = fixture.find(.if_statement).as_statement().?;

    try std.testing.expectEqualStrings("(one)", statement.header().?.text(source));
    try std.testing.expectEqual(Kind.statement_block, statement.body().?.kind());
    try std.testing.expect(statement.else_clause() != null);
}

test "an operation reads its operands and its operators" {
    const source = "const held = one + two;\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const operation = fixture.find(.binary_expression).as_operation().?;

    try std.testing.expectEqual(2, operation.operands().count());
    try std.testing.expectEqual(1, tally(operation.operator_tokens()));
}

test View {
    const gpa = std.testing.allocator;
    const fronts = try gpa.create(Fronts);
    defer gpa.destroy(fronts);

    try fronts.init(gpa, &capacity_doctest, .initOne(.javascript), &.{});
    defer fronts.deinit(gpa);

    const source = "function greet(name) {\n    return name;\n}\n";
    const parsed = try fronts.parse(.of(.javascript), source);
    const top = parsed.root_as(View);
    const function = parsed.view_as(View, parsed.nodes_of(.function)[0]).as_function().?;
    const name = top.token_at(function.name_token().?).text(source);

    try std.testing.expectEqual(Kind.program, top.kind());
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
