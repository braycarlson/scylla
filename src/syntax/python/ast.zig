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
const literal = @import("literal.zig");
const Front = @import("../front.zig").Front;
const Fronts = @import("../fronts.zig").Fronts;
const Events = EventsType(Kind);
const Tree = TreeType(Kind);
pub const Literal = enum { boolean, bytes, ellipsis, none, number, text };
pub const Parameter = enum { keyword, keyword_rest, positional, positional_only, positional_rest };

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

    pub fn as_alias(view: View) ?Alias {
        assert(view.node < view.tree.count());

        const held = view.cast(&.{.alias}) orelse return null;

        assert(held.kind() == .alias);
        assert(held.node == view.node);

        return .{ .view = held };
    }

    pub fn as_argument(view: View) ?Arg {
        assert(view.node < view.tree.count());

        const held = view.cast(&.{.arg}) orelse return null;

        assert(held.kind() == .arg);
        assert(held.node == view.node);

        return .{ .view = held };
    }

    pub fn as_assign(view: View) ?Assign {
        assert(view.node < view.tree.count());

        const held = view.cast(&assign_kinds) orelse return null;

        assert(kind_in(held.kind(), &assign_kinds));
        assert(held.node == view.node);

        return .{ .view = held };
    }

    pub fn as_call(view: View) ?Call {
        assert(view.node < view.tree.count());

        const held = view.cast(&.{.call}) orelse return null;

        assert(held.kind() == .call);
        assert(held.node == view.node);

        return .{ .view = held };
    }

    pub fn as_class(view: View) ?ClassDef {
        assert(view.node < view.tree.count());

        const held = view.cast(&.{.class_def}) orelse return null;

        assert(held.kind() == .class_def);
        assert(held.node == view.node);

        return .{ .view = held };
    }

    pub fn as_constant(view: View) ?Constant {
        assert(view.node < view.tree.count());

        const held = view.cast(&.{.constant}) orelse return null;

        assert(held.kind() == .constant);
        assert(held.node == view.node);

        return .{ .view = held };
    }

    pub fn as_function(view: View) ?FunctionDef {
        assert(view.node < view.tree.count());

        const held = view.cast(&definition_kinds) orelse return null;

        assert(kind_in(held.kind(), &definition_kinds));
        assert(held.node == view.node);

        return .{ .view = held };
    }

    pub fn as_import(view: View) ?Import {
        assert(view.node < view.tree.count());

        const held = view.cast(&import_kinds) orelse return null;

        assert(kind_in(held.kind(), &import_kinds));
        assert(held.node == view.node);

        return .{ .view = held };
    }

    pub fn as_keyword(view: View) ?Keyword {
        assert(view.node < view.tree.count());

        const held = view.cast(&.{.keyword}) orelse return null;

        assert(held.kind() == .keyword);
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

    pub fn positions_of(view: View, wanted: Kind) Positions {
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

pub const Alias = struct {
    view: View,

    pub const CapacityError = error{Truncated};

    pub fn asname_token(alias: Alias) ?u32 {
        assert(alias.view.kind() == .alias);

        var found = alias.view.positions();
        var seen = false;

        for (0..alias.view.raw.len + 1) |_| {
            const position = found.next() orelse return null;

            if (seen) {
                assert(position > alias.view.token_start());

                return position;
            }

            if (alias.view.token_kind(position) == .as_keyword) seen = true;
        }

        return null;
    }

    pub fn name_segments(alias: Alias, out: *ArrayType(Span)) CapacityError!void {
        assert(alias.view.kind() == .alias);

        const asname = alias.asname_token();
        var identifiers = alias.view.positions_of(.identifier);

        for (0..alias.view.raw.len + 1) |_| {
            const position = identifiers.next() orelse return;

            assert(alias.view.token_kind(position) == .identifier);

            if (asname) |held| {
                if (position >= held) return;
            }

            if (out.full()) return error.Truncated;

            out.push(alias.view.token_at(position).span());
        }
    }
};

pub const Arg = struct {
    view: View,

    pub fn annotation(argument: Arg) ?View {
        assert(argument.view.kind() == .arg);

        const held = argument.view.child_first() orelse return null;

        assert(held.node > argument.view.node);

        return held;
    }

    pub fn default(argument: Arg) ?View {
        assert(argument.view.kind() == .arg);

        const sibling = argument.view.tree.sibling_next_of(argument.view.node) orelse return null;
        const held = argument.view.at(sibling);
        if (held.kind() == .arg) return null;

        assert(held.node > argument.view.node);

        return held;
    }

    pub fn name_token(argument: Arg) ?u32 {
        assert(argument.view.kind() == .arg);

        const position = argument.view.token_first(.identifier) orelse return null;

        assert(argument.view.token_kind(position) == .identifier);

        return position;
    }
};

pub const Assign = struct {
    view: View,

    pub fn annotation(assign: Assign) ?View {
        assert(kind_in(assign.view.kind(), &assign_kinds));

        if (assign.view.kind() != .ann_assign) return null;

        const held = assign.view.child_at(1) orelse return null;

        assert(held.node > assign.view.node);

        return held;
    }

    pub fn kind(assign: Assign) Kind {
        assert(assign.view.node < assign.view.tree.count());

        const held = assign.view.kind();

        assert(kind_in(held, &assign_kinds));
        assert(held.is_node());

        return held;
    }

    pub fn operator_token(assign: Assign) ?u32 {
        assert(assign.view.node < assign.view.tree.count());

        var found = assign.view.positions();
        const position = found.next() orelse return null;

        assert(position >= assign.view.token_start());
        assert(position < assign.view.token_end());

        return position;
    }

    pub fn targets(assign: Assign) Targets {
        assert(kind_in(assign.view.kind(), &assign_kinds));

        const total = assign.view.children().count();
        const remaining: u32 = if (assign.view.kind() == .assign) total -| 1 else 1;

        assert(remaining <= assign.view.tree.count());

        return .{ .children = assign.view.children(), .remaining = remaining };
    }

    pub fn value(assign: Assign) ?View {
        assert(kind_in(assign.view.kind(), &assign_kinds));

        const found = assign.view.children();

        if (assign.view.kind() == .ann_assign) {
            if (found.count() < 3) return null;
        }

        const held = found.last() orelse return null;

        assert(held.node > assign.view.node);

        return held;
    }
};

pub const Call = struct {
    view: View,

    pub fn arguments(call: Call) Excluding {
        assert(call.view.kind() == .call);

        var rest = call.view.children();

        _ = rest.next();

        if (rest.current) |child| assert(child > call.view.node);

        return .{ .children = rest, .excluded = &keyword_kinds, .remaining = rest.remaining };
    }

    pub fn callee(call: Call) ?View {
        assert(call.view.kind() == .call);

        const held = call.view.child_first() orelse return null;

        assert(held.tree.parent_of(held.node).? == call.view.node);

        return held;
    }

    pub fn keywords(call: Call) Keywords {
        assert(call.view.kind() == .call);

        const children = call.view.children_of(.keyword);
        const found: Keywords = .{ .children = children, .remaining = children.remaining };

        assert(found.children.kind.? == .keyword);

        return found;
    }
};

pub const ClassDef = struct {
    view: View,

    pub fn bases(class: ClassDef) Excluding {
        assert(class.view.kind() == .class_def);

        const children = class.view.children();

        const found: Excluding = .{
            .children = children,
            .excluded = &class_skipped_kinds,
            .remaining = children.remaining,
        };

        assert(found.children.kind == null);

        return found;
    }

    pub fn body(class: ClassDef) ?View {
        assert(class.view.kind() == .class_def);

        const held = class.view.child_first_of(.block) orelse return null;

        assert(held.kind() == .block);

        return held;
    }

    pub fn decorators(class: ClassDef) Decorators {
        assert(class.view.kind() == .class_def);

        const found = decorators_of(class.view);

        assert(found.index == class.view.node);

        return found;
    }

    pub fn keywords(class: ClassDef) Keywords {
        assert(class.view.kind() == .class_def);

        const children = class.view.children_of(.keyword);
        const found: Keywords = .{ .children = children, .remaining = children.remaining };

        assert(found.children.kind.? == .keyword);

        return found;
    }

    pub fn name_token(class: ClassDef) ?u32 {
        assert(class.view.kind() == .class_def);

        const position = class.view.token_first(.identifier) orelse return null;

        assert(class.view.token_kind(position) == .identifier);

        return position;
    }

    pub fn type_params(class: ClassDef) ?View {
        assert(class.view.kind() == .class_def);

        const held = class.view.child_first_of(.type_params) orelse return null;

        assert(held.kind() == .type_params);

        return held;
    }
};

pub const Constant = struct {
    view: View,

    pub fn content_span(constant: Constant, source: []const u8) Span {
        assert(constant.view.kind() == .constant);

        const node = constant.view.tree.at(constant.view.node);

        assert(source.len <= std.math.maxInt(u32));

        if (node.token_end <= node.token_start) return constant.view.span();

        const token = constant.view.token_at(node.token_start);
        const written = token.text(source);
        const shape = literal.shape_of(written, token.offset) orelse return constant.view.span();

        assert(shape.content.end() <= source.len);

        return shape.content;
    }

    pub fn literal_class(constant: Constant) Literal {
        assert(constant.view.kind() == .constant);

        const node = constant.view.tree.at(constant.view.node);

        assert(node.token_end <= constant.view.raw.len);

        if (node.token_end <= node.token_start) return .text;

        return switch (constant.view.token_kind(node.token_start)) {
            .ellipsis => .ellipsis,
            .false_keyword, .true_keyword => .boolean,
            .none_keyword => .none,
            .string_bytes => .bytes,
            .number_binary,
            .number_complex,
            .number_float,
            .number_hexadecimal,
            .number_integer,
            .number_octal,
            => .number,
            else => .text,
        };
    }

    pub fn pieces(constant: Constant) Pieces {
        assert(constant.view.kind() == .constant);

        const positions = constant.view.positions();
        const found: Pieces = .{ .positions = positions, .remaining = positions.remaining };

        assert(found.positions.kind == null);

        return found;
    }
};

pub const FunctionDef = struct {
    view: View,

    fn is_rest(function: FunctionDef, argument: Arg, marker: Kind) bool {
        assert(marker.is_token());
        assert(function.view.node < function.view.tree.count());
        assert(argument.view.node < argument.view.tree.count());

        const arguments = function.view.child_first_of(.arguments) orelse return false;
        const start = arguments.tree.at(argument.view.node).token_start;
        var markers = arguments.positions_of(marker);

        assert(start < arguments.token_end());

        for (0..arguments.raw.len + 1) |_| {
            const position = markers.next() orelse return false;
            if (position + 1 == start) return true;
        }

        return false;
    }

    fn positional_only(function: FunctionDef, argument: Arg) bool {
        assert(argument.view.kind() == .arg);
        assert(function.view.node < function.view.tree.count());

        const arguments = function.view.child_first_of(.arguments) orelse return false;
        const start = arguments.tree.at(argument.view.node).token_start;
        var slashes = arguments.positions_of(.slash);

        assert(start < arguments.token_end());

        for (0..arguments.raw.len + 1) |_| {
            const position = slashes.next() orelse return false;
            if (position > start) return true;
        }

        return false;
    }

    pub fn body(function: FunctionDef) ?View {
        assert(kind_in(function.view.kind(), &definition_kinds));

        const held = function.view.child_first_of(.block) orelse return null;

        assert(held.kind() == .block);

        return held;
    }

    pub fn decorators(function: FunctionDef) Decorators {
        assert(kind_in(function.view.kind(), &definition_kinds));

        const found = decorators_of(function.view);

        assert(found.index == function.view.node);

        return found;
    }

    pub fn is_async(function: FunctionDef) bool {
        assert(function.view.node < function.view.tree.count());

        const held = function.view.kind();

        assert(kind_in(held, &definition_kinds));
        assert(held.is_node());

        return held == .async_function_def;
    }

    pub fn name_token(function: FunctionDef) ?u32 {
        assert(kind_in(function.view.kind(), &definition_kinds));

        const position = function.view.token_first(.identifier) orelse return null;

        assert(function.view.token_kind(position) == .identifier);

        return position;
    }

    pub fn parameter_class(function: FunctionDef, argument: Arg) Parameter {
        assert(argument.view.kind() == .arg);
        assert(function.view.node < function.view.tree.count());

        const arguments = function.view.child_first_of(.arguments) orelse return .positional;
        const start = arguments.tree.at(argument.view.node).token_start;
        var found = arguments.positions();
        var class: Parameter = .positional;
        var slash = false;

        assert(start < arguments.token_end());

        for (0..arguments.raw.len + 1) |_| {
            const position = found.next() orelse break;
            if (position >= start) break;

            switch (arguments.token_kind(position)) {
                .slash => slash = true,
                .star => class = .positional_rest,
                .star_star => class = .keyword_rest,
                else => {},
            }
        }

        if (class == .positional_rest) {
            if (!function.is_rest(argument, .star)) return .keyword;
        }

        if (class == .positional) {
            if (slash) return .positional;
            if (function.positional_only(argument)) return .positional_only;
        }

        return class;
    }

    pub fn parameters(function: FunctionDef) Parameters {
        assert(kind_in(function.view.kind(), &definition_kinds));

        if (function.view.child_first_of(.arguments)) |arguments| {
            const children = arguments.children_of(.arg);

            assert(arguments.kind() == .arguments);

            return .{ .children = children, .remaining = children.remaining };
        }

        var empty = function.view.children_of(.arg);
        empty.current = null;
        empty.remaining = 0;

        return .{ .children = empty, .remaining = 0 };
    }

    pub fn returns_annotation(function: FunctionDef) ?View {
        assert(kind_in(function.view.kind(), &definition_kinds));

        var rest = function.view.children();
        var found: ?View = null;

        for (0..function.view.tree.count()) |_| {
            const held = rest.next() orelse break;
            if (kind_in(held.kind(), &signature_kinds)) continue;

            found = held;
        }

        if (found) |held| assert(!kind_in(held.kind(), &signature_kinds));

        return found;
    }

    pub fn type_params(function: FunctionDef) ?View {
        assert(kind_in(function.view.kind(), &definition_kinds));

        const held = function.view.child_first_of(.type_params) orelse return null;

        assert(held.kind() == .type_params);

        return held;
    }
};

pub const Import = struct {
    view: View,

    pub const CapacityError = error{Truncated};

    pub fn aliases(import: Import) Aliases {
        assert(kind_in(import.view.kind(), &import_kinds));

        const children = import.view.children_of(.alias);
        const found: Aliases = .{ .children = children, .remaining = children.remaining };

        assert(found.children.kind.? == .alias);

        return found;
    }

    pub fn level(import: Import) u32 {
        assert(kind_in(import.view.kind(), &import_kinds));

        var found = import.view.positions();
        var dots: u32 = 0;

        for (0..import.view.raw.len + 1) |_| {
            const position = found.next() orelse break;

            switch (import.view.token_kind(position)) {
                .dot => dots += 1,
                .ellipsis => dots += 3,
                .from_keyword => {},
                else => break,
            }
        }

        assert(dots <= 3 * (import.view.token_end() - import.view.token_start()));

        return dots;
    }

    pub fn module_segments(import: Import, out: *ArrayType(Span)) CapacityError!void {
        assert(kind_in(import.view.kind(), &import_kinds));

        if (import.view.kind() != .import_from) return;

        var found = import.view.positions();

        for (0..import.view.raw.len + 1) |_| {
            const position = found.next() orelse return;
            const held = import.view.token_kind(position);
            if (held == .import_keyword) return;
            if (held != .identifier) continue;
            if (out.full()) return error.Truncated;

            out.push(import.view.token_at(position).span());

            assert(out.count() > 0);
        }
    }
};

pub const Keyword = struct {
    view: View,

    pub fn name_token(keyword: Keyword) ?u32 {
        assert(keyword.view.kind() == .keyword);

        const position = keyword.view.token_first(.identifier) orelse return null;

        assert(keyword.view.token_kind(position) == .identifier);

        return position;
    }

    pub fn value(keyword: Keyword) ?View {
        assert(keyword.view.kind() == .keyword);

        const held = keyword.view.child_first() orelse return null;

        assert(held.node > keyword.view.node);

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

    pub fn operator_tokens(operation: Operation) Positions {
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

        const held = statement.view.child_first_of(.block) orelse return null;

        assert(held.kind() == .block);

        return held;
    }

    pub fn cases(statement: Statement) Children {
        assert(kind_in(statement.view.kind(), &statement_kinds));

        const found = statement.view.children_of(.match_case);

        assert(found.kind.? == .match_case);

        return found;
    }

    pub fn else_clause(statement: Statement) ?View {
        assert(kind_in(statement.view.kind(), &statement_kinds));

        const held = statement.view.child_first_of(.else_clause) orelse return null;

        assert(held.kind() == .else_clause);

        return held;
    }

    pub fn finally_clause(statement: Statement) ?View {
        assert(kind_in(statement.view.kind(), &statement_kinds));

        const held = statement.view.child_first_of(.finally_clause) orelse return null;

        assert(held.kind() == .finally_clause);

        return held;
    }

    pub fn handlers(statement: Statement) Children {
        assert(kind_in(statement.view.kind(), &statement_kinds));

        const found = statement.view.children_of(.except_handler);

        assert(found.kind.? == .except_handler);

        return found;
    }

    pub fn header(statement: Statement) ?View {
        assert(kind_in(statement.view.kind(), &statement_kinds));

        const children = statement.view.children();

        var others: Excluding = .{
            .children = children,
            .excluded = &clause_kinds,
            .remaining = children.remaining,
        };

        const held = others.next() orelse return null;

        assert(!kind_in(held.kind(), &clause_kinds));

        return held;
    }

    pub fn items(statement: Statement) Children {
        assert(kind_in(statement.view.kind(), &statement_kinds));

        const found = statement.view.children_of(.with_item);

        assert(found.kind.? == .with_item);

        return found;
    }
};

pub const Aliases = CastsType(Alias);
pub const Keywords = CastsType(Keyword);
pub const Parameters = CastsType(Arg);

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

pub const Decorators = struct {
    children: Children,
    index: u32,
    remaining: u32,

    pub fn next(decorators: *Decorators) ?View {
        assert(decorators.index < decorators.children.tree.count());
        assert(decorators.remaining <= decorators.children.tree.count());

        if (decorators.remaining == 0) return null;

        for (0..decorators.children.tree.count()) |_| {
            const held = decorators.children.next() orelse return null;

            if (held.node >= decorators.index) {
                decorators.children.current = null;

                return null;
            }

            if (held.kind() != .decorator) continue;

            assert(held.node < decorators.index);

            decorators.remaining -= 1;

            return held;
        }

        assert(decorators.children.current == null);

        return null;
    }
};

pub const Excluding = struct {
    children: Children,
    excluded: []const Kind,
    remaining: u32,

    pub fn next(excluding: *Excluding) ?View {
        assert(excluding.excluded.len > 0);
        assert(excluding.remaining <= excluding.children.tree.count());

        if (excluding.remaining == 0) return null;

        for (0..excluding.children.tree.count()) |_| {
            const held = excluding.children.next() orelse return null;
            if (kind_in(held.kind(), excluding.excluded)) continue;

            assert(excluding.children.tree.parent_of(held.node) != null);

            excluding.remaining -= 1;

            return held;
        }

        assert(excluding.children.current == null);

        return null;
    }
};

pub const Pieces = struct {
    positions: Positions,
    remaining: u32,

    pub fn next(pieces: *Pieces) ?u32 {
        assert(pieces.positions.kind == null);
        assert(pieces.remaining <= pieces.positions.raw.len);

        if (pieces.remaining == 0) return null;

        for (0..pieces.positions.raw.len + 1) |_| {
            const position = pieces.positions.next() orelse return null;
            if (!kind_in(pieces.positions.raw[position], &piece_kinds)) continue;

            assert(position < pieces.positions.limit);

            pieces.remaining -= 1;

            return position;
        }

        assert(pieces.positions.position >= pieces.positions.limit);

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

pub const Targets = struct {
    children: Children,
    remaining: u32,

    pub fn next(targets: *Targets) ?View {
        assert(targets.remaining <= targets.children.tree.count());

        if (targets.remaining == 0) return null;

        const held = targets.children.next() orelse return null;

        targets.remaining -= 1;

        assert(targets.children.tree.parent_of(held.node) != null);

        return held;
    }
};

const assign_kinds = [_]Kind{ .ann_assign, .assign, .aug_assign };
const class_skipped_kinds = [_]Kind{ .block, .keyword, .type_params };

const clause_kinds = [_]Kind{
    .block,
    .else_clause,
    .except_handler,
    .finally_clause,
    .match_case,
    .with_item,
};

const definition_kinds = [_]Kind{ .async_function_def, .function_def };
const import_kinds = [_]Kind{ .import, .import_from };
const keyword_kinds = [_]Kind{.keyword};
const operation_kinds = [_]Kind{ .bin_op, .bool_op, .compare, .unary_op };
const piece_kinds = [_]Kind{ .string_bytes, .string_format, .string_plain };
const signature_kinds = [_]Kind{ .arguments, .block, .type_params };

const statement_kinds = [_]Kind{
    .async_for,
    .async_with,
    .delete,
    .@"for",
    .@"if",
    .match,
    .raise,
    .@"return",
    .@"try",
    .try_star,
    .@"while",
    .with,
};

const tally_max: u32 = 1 << 16;

fn CastsType(comptime Item: type) type {
    comptime assert(@hasField(Item, "view"));
    comptime assert(@sizeOf(Item) == @sizeOf(View));

    return struct {
        children: Children,
        remaining: u32,

        const Casts = @This();

        pub fn next(casts: *Casts) ?Item {
            assert(casts.children.kind != null);
            assert(casts.remaining <= casts.children.tree.count());

            if (casts.remaining == 0) return null;

            const held = casts.children.next() orelse return null;

            assert(held.kind() == casts.children.kind.?);

            casts.remaining -= 1;

            return .{ .view = held };
        }
    };
}

fn decorators_of(view: View) Decorators {
    assert(view.node < view.tree.count());

    const holder = view.parent() orelse view;

    const found: Decorators = .{
        .children = holder.children(),
        .index = view.node,
        .remaining = view.node - holder.node,
    };

    assert(holder.node <= view.node);
    if (found.children.current) |child| assert(child > holder.node);

    return found;
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

        assert(held.kind() == .module);
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
    const source = "first = 1\nsecond = 2\n";
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

test "a function view reads its name parameters and body" {
    const source = "@decorated\ndef greet(name: str, count=1) -> bool:\n    return True\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const view = fixture.find(.function_def);
    const function = view.as_function().?;

    try std.testing.expect(!function.is_async());

    try std.testing.expectEqualStrings(
        "greet",
        view.token_at(function.name_token().?).text(source),
    );

    var parameters = function.parameters();

    for ([_][]const u8{ "name", "count" }) |name| {
        const argument = parameters.next().?;

        try std.testing.expectEqualStrings(
            name,
            view.token_at(argument.name_token().?).text(source),
        );
    }

    const after = parameters.next();
    var others = function.parameters();
    const annotated = others.next().?;

    try std.testing.expect(after == null);
    try std.testing.expectEqualStrings("str", annotated.annotation().?.text(source));
    try std.testing.expectEqualStrings("bool", function.returns_annotation().?.text(source));
    try std.testing.expectEqual(1, tally(function.decorators()));
    try std.testing.expectEqual(1, function.body().?.children().count());
}

test "a class view reads its bases and keywords" {
    const source = "class Held(Base, metaclass=Meta):\n    pass\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const view = fixture.find(.class_def);
    const class = view.as_class().?;

    try std.testing.expectEqualStrings("Held", view.token_at(class.name_token().?).text(source));
    try std.testing.expectEqual(1, tally(class.bases()));
    try std.testing.expectEqual(1, tally(class.keywords()));

    var keywords = class.keywords();
    const keyword = keywords.next().?;

    try std.testing.expectEqualStrings(
        "metaclass",
        view.token_at(keyword.name_token().?).text(source),
    );

    try std.testing.expectEqualStrings("Meta", keyword.value().?.text(source));
    try std.testing.expect(class.body() != null);
}

test "a call view separates arguments from keywords" {
    const source = "send(first, second, key=1)\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const view = fixture.find(.call);
    const call = view.as_call().?;

    try std.testing.expectEqualStrings("send", call.callee().?.text(source));
    try std.testing.expectEqual(2, tally(call.arguments()));
    try std.testing.expectEqual(1, tally(call.keywords()));
}

test "an assignment view separates its targets from its value" {
    const source = "first = second = 3\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const view = fixture.find(.assign);
    const assign = view.as_assign().?;

    try std.testing.expectEqual(2, tally(assign.targets()));
    try std.testing.expectEqualStrings("3", assign.value().?.text(source));
    try std.testing.expect(assign.annotation() == null);
}

test "an annotated assignment view reads its annotation" {
    const source = "count: int = 3\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const view = fixture.find(.ann_assign);
    const assign = view.as_assign().?;

    try std.testing.expectEqual(1, tally(assign.targets()));
    try std.testing.expectEqualStrings("int", assign.annotation().?.text(source));
    try std.testing.expectEqualStrings("3", assign.value().?.text(source));
}

test "an import view reads its level and segments" {
    const gpa = std.testing.allocator;
    const source = "from ..deep.module import thing as other\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const view = fixture.find(.import_from);
    const import = view.as_import().?;

    try std.testing.expectEqual(2, import.level());

    var segments: ArrayType(Span) = try .init(gpa, 8);
    defer segments.deinit(gpa);

    try import.module_segments(&segments);
    try std.testing.expectEqual(2, segments.count());
    try std.testing.expectEqualStrings("deep", segments.get(0).text(source));
    try std.testing.expectEqualStrings("module", segments.get(1).text(source));

    var aliases = import.aliases();
    const alias = aliases.next().?;

    try std.testing.expectEqualStrings("other", view.token_at(alias.asname_token().?).text(source));

    var parts: ArrayType(Span) = try .init(gpa, 8);
    defer parts.deinit(gpa);

    try alias.name_segments(&parts);
    try std.testing.expectEqual(1, parts.count());
    try std.testing.expectEqualStrings("thing", parts.get(0).text(source));
}

test "a constant view names its literal class and content" {
    const source = "held = rb'''bytes'''\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const view = fixture.find(.constant);
    const constant = view.as_constant().?;

    try std.testing.expectEqual(Literal.bytes, constant.literal_class());
    try std.testing.expectEqualStrings("bytes", constant.content_span(source).text(source));
}

test "a statement view reads its clauses" {
    const source = "try:\n    pass\nexcept ValueError:\n    pass\nelse:\n    pass\nfinally:\n" ++
        "    pass\n";

    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const view = fixture.find(.@"try");
    const statement = view.as_statement().?;

    try std.testing.expectEqual(1, statement.handlers().count());
    try std.testing.expect(statement.else_clause() != null);
    try std.testing.expect(statement.finally_clause() != null);
    try std.testing.expect(statement.body() != null);
}

test "an operation view reads its operands and operators" {
    const source = "held = first < second <= third\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const view = fixture.find(.compare);
    const operation = view.as_operation().?;

    try std.testing.expectEqual(3, operation.operands().count());
    try std.testing.expectEqual(2, tally(operation.operator_tokens()));
}

test "a parameter view reads the default the signature wrote beside it" {
    const source = "def held(first, second: int = 3, *, third=len):\n    pass\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const view = fixture.find(.function_def);
    const function = view.as_function().?;
    var parameters = function.parameters();
    const plain = parameters.next().?;
    const annotated = parameters.next().?;
    const keyword = parameters.next().?;
    const after = parameters.next();

    try std.testing.expect(plain.default() == null);
    try std.testing.expectEqualStrings("3", annotated.default().?.text(source));
    try std.testing.expectEqualStrings("len", keyword.default().?.text(source));
    try std.testing.expect(after == null);
}

test "a parameter view names its class" {
    const source = "def held(first, second, /, third, *rest, fourth, **extra):\n    pass\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const view = fixture.find(.function_def);
    const function = view.as_function().?;
    var parameters = function.parameters();

    const expected = [_]Parameter{
        .positional_only,
        .positional_only,
        .positional,
        .positional_rest,
        .keyword,
        .keyword_rest,
    };

    for (expected) |class| {
        const argument = parameters.next().?;

        try std.testing.expectEqual(class, function.parameter_class(argument));
    }

    const after = parameters.next();

    try std.testing.expect(after == null);
}

test "a cast to the wrong view returns nothing" {
    const source = "held = 1\n";
    var fixture: Fixture = undefined;

    try fixture.init(source);
    defer fixture.deinit();

    const view = fixture.find(.constant);

    try std.testing.expect(view.as_call() == null);
    try std.testing.expect(view.as_function() == null);
    try std.testing.expect(view.as_constant() != null);
    try std.testing.expectEqual(Kind.assign, view.parent().?.kind());
}

test View {
    const gpa = std.testing.allocator;
    const fronts = try gpa.create(Fronts);
    defer gpa.destroy(fronts);

    try fronts.init(gpa, &capacity_doctest, .initOne(.python), &.{});
    defer fronts.deinit(gpa);

    const source = "def greet(name):\n    return name\n";
    const parsed = try fronts.parse(.of(.python), source);
    const top = parsed.root_as(View);
    const function = parsed.view_as(View, parsed.nodes_of(.function)[0]).as_function().?;
    const name = top.token_at(function.name_token().?).text(source);

    try std.testing.expectEqual(Kind.module, top.kind());
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
