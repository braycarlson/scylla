const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Front = @import("front.zig").Front;
const Fronts = @import("fronts.zig").Fronts;
const Span = @import("../stdx/bounded/span.zig");
const Token = @import("token.zig");
const category_module = @import("category.zig");
const frame_depth_max = @import("tree.zig").frame_depth_max;
const go = @import("go/ast.zig");
const javascript = @import("javascript/ast.zig");
const odin = @import("odin/ast.zig");
const python = @import("python/ast.zig");
const rust = @import("rust/ast.zig");
const zig = @import("zig/ast.zig");
const Tag = enum { go, javascript, odin, python, rust, zig };

pub const View = union(Tag) {
    go: go.View,
    javascript: javascript.View,
    odin: odin.View,
    python: python.View,
    rust: rust.View,
    zig: zig.View,

    pub const Category = category_module.Category;

    fn children_filtered(view: View, wanted: ?Category) Children {
        assert(view.index() < view.node_count());
        if (wanted) |held| assert(held != .other);

        const inner: ChildrenInner = switch (view) {
            inline else => |held, tag| @unionInit(ChildrenInner, @tagName(tag), held.children()),
        };

        assert(std.meta.activeTag(inner) == std.meta.activeTag(view));

        return .of(wanted, inner);
    }

    fn token_limit(view: View) u32 {
        assert(view.index() < view.node_count());

        switch (view) {
            inline else => |held| {
                assert(held.node < held.tree.count());
                assert(held.tokens.len == held.raw.len);

                return @intCast(held.tokens.len);
            },
        }
    }

    pub fn node_count(view: *const View) u32 {
        switch (view.*) {
            inline else => |held| {
                assert(held.node < held.tree.count());
                assert(held.tokens.len == held.raw.len);

                return held.tree.count();
            },
        }
    }

    pub fn ancestor_of(view: View, wanted: Category) ?View {
        assert(view.index() < view.node_count());
        assert(wanted != .other);

        var current = view.parent();

        for (0..frame_depth_max) |_| {
            const held = current orelse return null;

            assert(held.index() < view.index());

            if (held.category() == wanted) return held;

            current = held.parent();
        }

        assert(current != null);

        return null;
    }

    pub fn ancestors(view: View) Ancestors {
        assert(view.index() < view.node_count());

        return .{ .current = view, .remaining = view.index() };
    }

    pub fn as_call(view: View) ?Call {
        if (view.category() != .call) return null;

        assert(view.category() == .call);
        assert(view.index() < view.node_count());

        return .{ .view = view };
    }

    pub fn as_constant(view: View) ?Constant {
        assert(view.index() < view.node_count());

        const held = switch (view) {
            .go => |inner| inner.kind() == .basic_lit,
            .javascript => |inner| inner.as_constant() != null,
            .odin => |inner| switch (inner.kind()) {
                .boolean, .character, .float, .nil, .number, .string => true,
                else => false,
            },
            .python => |inner| inner.as_constant() != null,
            .rust => |inner| inner.as_constant() != null,
            .zig => |inner| switch (inner.kind()) {
                .char_literal,
                .multiline_string_literal,
                .number_literal,
                .string_literal,
                => true,
                else => false,
            },
        };

        if (!held) return null;

        assert(held);

        return .{ .view = view };
    }

    pub fn as_container(view: View) ?Container {
        assert(view.index() < view.node_count());

        const held = switch (view) {
            .go => |inner| inner.kind() == .type_spec,
            .javascript => |inner| script_is_container(inner),
            .odin => |inner| inner.as_container() != null,
            .python => |inner| inner.as_class() != null,
            .rust => |inner| inner.as_definition() != null,
            .zig => |inner| inner.as_container() != null,
        };

        if (!held) return null;

        assert(held);

        return .{ .view = view };
    }

    pub fn as_declaration(view: View) ?Declaration {
        assert(view.index() < view.node_count());

        const held = switch (view) {
            .go => |inner| go_is_declaration(inner),
            .javascript => |inner| script_is_declaration(inner),
            .odin => |inner| odin_is_declaration(inner),
            .python => |inner| inner.as_assign() != null and inner.kind() != .aug_assign,
            .rust => |inner| switch (inner.kind()) {
                .item_const, .item_static, .local => true,
                else => false,
            },
            .zig => |inner| inner.as_declaration() != null,
        };

        if (!held) return null;

        assert(held);

        return .{ .view = view };
    }

    pub fn as_field(view: View) ?Field {
        assert(view.index() < view.node_count());

        const held = switch (view) {
            .go => |inner| inner.as_field() != null,
            .javascript => |inner| script_is_field(inner),
            .odin => |inner| inner.as_field() != null,
            .python => false,
            .rust => |inner| inner.as_field() != null,
            .zig => |inner| inner.as_field() != null,
        };

        if (!held) return null;

        assert(view != .python);

        assert(view.index() < view.node_count());

        return .{ .view = view };
    }

    pub fn as_function(view: View) ?Function {
        assert(view.index() < view.node_count());

        const class = view.category();

        if (class != .function) {
            if (class != .lambda) return null;
        }

        assert(class == .function or class == .lambda);

        return .{ .view = view };
    }

    pub fn as_import(view: View) ?Import {
        assert(view.index() < view.node_count());

        const held = switch (view) {
            .go => |inner| inner.kind() == .import_spec,
            .javascript => |inner| inner.as_import() != null,
            .odin => |inner| inner.kind() == .import_declaration,
            .python => |inner| inner.as_import() != null,
            .rust => |inner| inner.as_use() != null,
            .zig => false,
        };

        if (!held) return null;

        assert(view != .zig);

        assert(view.index() < view.node_count());

        return .{ .view = view };
    }

    pub fn as_operation(view: View) ?Operation {
        assert(view.index() < view.node_count());

        const held = switch (view) {
            inline else => |inner| inner.as_operation() != null,
        };

        if (!held) return null;

        assert(held);

        return .{ .view = view };
    }

    pub fn as_statement(view: View) ?Statement {
        assert(view.index() < view.node_count());

        const held = switch (view) {
            inline else => |inner| inner.as_statement() != null,
        };

        if (!held) return null;

        assert(held);

        return .{ .view = view };
    }

    pub fn category(view: View) Category {
        assert(view.index() < view.node_count());

        switch (view) {
            inline else => |held| {
                const kind = held.kind();

                assert(kind.is_node());
                assert(held.node < held.tree.count());

                return kind.category();
            },
        }
    }

    pub fn child_first(view: View) ?View {
        assert(view.index() < view.node_count());

        switch (view) {
            inline else => |held, tag| {
                const child = held.child_first() orelse return null;

                assert(child.node > held.node);
                assert(child.tree == held.tree);

                return wrap(tag, child);
            },
        }
    }

    pub fn child_first_of(view: View, wanted: Category) ?View {
        assert(view.index() < view.node_count());
        assert(wanted != .other);

        var found = view.children_of(wanted);
        const held = found.next() orelse return null;

        assert(held.category() == wanted);
        assert(held.index() > view.index());

        return held;
    }

    pub fn children(view: View) Children {
        assert(view.index() < view.node_count());

        const found = view.children_filtered(null);

        assert(found.category == null);
        assert(found.remaining <= view.node_count());

        return found;
    }

    pub fn children_of(view: View, wanted: Category) Children {
        assert(view.index() < view.node_count());
        assert(wanted != .other);

        const found = view.children_filtered(wanted);

        assert(found.category.? == wanted);
        assert(found.remaining <= view.node_count());

        return found;
    }

    pub fn declares_a_container(view: View) bool {
        assert(view.index() < view.node_count());

        const declaration = view.as_declaration() orelse return false;
        const value = declaration.value() orelse return false;

        assert(value.index() > view.index());
        assert(std.meta.activeTag(value) == std.meta.activeTag(view));

        return value.category() == .@"struct";
    }

    pub fn declaring_of(view: View) View {
        assert(view.index() < view.node_count());

        var current = view;

        for (0..frame_depth_max) |_| {
            if (current.category() != .name) return current;

            const above = current.parent() orelse return current;

            assert(above.index() < current.index());

            current = above;
        }

        assert(current.index() < view.index());

        return current;
    }

    pub fn enclosing_function(view: View) ?View {
        assert(view.index() < view.node_count());

        var current = view.parent();

        for (0..frame_depth_max) |_| {
            const held = current orelse return null;

            assert(held.index() < view.index());

            switch (held.category()) {
                .function, .lambda => return held,
                else => {},
            }

            current = held.parent();
        }

        assert(current != null);

        return null;
    }

    pub fn holds(view: View, wanted: Category) bool {
        assert(view.index() < view.node_count());
        assert(wanted != .other);

        const held = view.child_first_of(wanted) orelse return false;

        assert(held.category() == wanted);
        assert(held.index() > view.index());

        return true;
    }

    pub fn index(view: *const View) u32 {
        switch (view.*) {
            inline else => |held| {
                assert(held.node < held.tree.count());
                assert(held.tokens.len == held.raw.len);

                return held.node;
            },
        }
    }

    pub fn is_an_arm(view: View) bool {
        assert(view.index() < view.node_count());

        const above = view.parent() orelse return false;

        assert(above.index() < view.index());

        if (above.category() == .match) return true;
        if (above.category() != .block) return false;

        const outer = above.parent() orelse return false;

        assert(outer.index() < above.index());

        return outer.category() == .match;
    }

    pub fn is_inside_parameters(view: View) bool {
        assert(view.index() < view.node_count());

        const above = view.parent() orelse return false;
        const outer = above.parent() orelse return false;

        assert(above.index() < view.index());
        assert(outer.index() < above.index());

        return outer.category() == .parameters;
    }

    pub fn is_inside_signature(view: View) bool {
        if (view.is_inside_parameters()) return true;

        const offset = view.span().offset;
        var current = view.parent();

        for (0..frame_depth_max) |_| {
            const held = current orelse return false;

            assert(held.index() < view.index());

            if (held.as_function()) |function| {
                if (function.parameters_span()) |covered| {
                    if (span_covers(covered, offset)) return true;
                }
            }

            current = held.parent();
        }

        assert(current != null);

        return false;
    }

    pub fn name_token(view: View) ?u32 {
        assert(view.index() < view.node_count());

        if (view.as_declaration()) |declaration| {
            var names = declaration.names();
            return names.next();
        }

        if (view.as_function()) |function| return function.name_token();
        if (view.as_field()) |field| return field.name_token();
        if (view.as_container()) |container| return container.name_token();

        var name = view.child_first_of(.name) orelse return null;

        for (0..frame_depth_max) |_| {
            const inner = name.child_first_of(.name) orelse break;

            assert(inner.index() > name.index());

            name = inner;
        }

        assert(name.category() == .name);

        var found = name.positions();
        return found.next();
    }

    pub fn parent(view: View) ?View {
        assert(view.index() < view.node_count());

        switch (view) {
            inline else => |held, tag| {
                const above = held.parent() orelse return null;

                assert(above.node < held.node);
                assert(above.tree == held.tree);

                return wrap(tag, above);
            },
        }
    }

    pub fn positions(view: View) Positions {
        assert(view.token_start() <= view.token_end());

        const inner: PositionsInner = switch (view) {
            inline else => |held, tag| @unionInit(PositionsInner, @tagName(tag), held.positions()),
        };

        assert(std.meta.activeTag(inner) == std.meta.activeTag(view));

        return .of(inner);
    }

    pub fn signature_covers(view: View, offset: u32) bool {
        assert(view.index() < view.node_count());

        const function = view.as_function() orelse return false;
        const extent = view.span();
        if (!span_covers(extent, offset)) return false;

        assert(offset >= extent.offset);

        if (function.body()) |body| {
            assert(body.index() > view.index());

            return offset < body.span().offset;
        }

        if (view.category() == .lambda) {
            const parameters = function.parameters_span() orelse return false;
            return offset < parameters.end();
        }

        return true;
    }

    pub fn span(view: View) Span {
        assert(view.index() < view.node_count());

        switch (view) {
            inline else => |held| {
                const extent = held.span();

                assert(extent.length <= std.math.maxInt(u32) - extent.offset);
                assert(held.node < held.tree.count());

                return extent;
            },
        }
    }

    pub fn spread_call(view: View) ?Call {
        assert(view.index() < view.node_count());

        const held: ?View = switch (view) {
            .go => |inner| wrap_optional(.go, go_spread_call(inner)),
            .javascript => |inner| wrap_optional(.javascript, script_spread_call(inner)),
            .odin => |inner| wrap_optional(.odin, odin_spread_call(inner)),
            .python => |inner| wrap_optional(.python, python_spread_call(inner)),
            .rust, .zig => null,
        };

        const call = held orelse return null;

        assert(call.index() < view.index());
        assert(std.meta.activeTag(call) == std.meta.activeTag(view));

        return call.as_call();
    }

    pub fn text(view: View, source: []const u8) []const u8 {
        assert(view.span().end() <= source.len);

        switch (view) {
            inline else => |held| {
                const bytes = held.text(source);

                assert(bytes.len <= source.len);
                assert(held.node < held.tree.count());

                return bytes;
            },
        }
    }

    pub fn token_at(view: View, position: u32) Token {
        assert(view.index() < view.node_count());
        assert(position < std.math.maxInt(u32));

        switch (view) {
            inline else => |held| {
                assert(position < held.tokens.len);
                assert(held.tokens.len == held.raw.len);

                return held.token_at(position);
            },
        }
    }

    pub fn token_end(view: View) u32 {
        assert(view.index() < view.node_count());

        switch (view) {
            inline else => |held| {
                const end = held.token_end();

                assert(end <= held.tokens.len);
                assert(held.token_start() <= end);

                return end;
            },
        }
    }

    pub fn token_start(view: View) u32 {
        assert(view.index() < view.node_count());

        switch (view) {
            inline else => |held| {
                const start = held.token_start();

                assert(start <= held.tokens.len);
                assert(start <= held.token_end());

                return start;
            },
        }
    }

    pub fn type_of(view: View) ?View {
        assert(view.index() < view.node_count());

        if (view.as_declaration()) |declaration| return declaration.type_of();
        if (view.as_field()) |field| return field.type_of();

        const class = view.category();
        if (class == .declaration) return view.child_first_of(.type);
        if (class != .parameter) return null;

        assert(class == .parameter);

        assert(view.index() < view.node_count());

        if (view.child_first_of(.type)) |held| return held;
        return view.child_first();
    }

    pub const Literal = enum {
        boolean,
        bytes,
        character,
        nil,
        number,
        other,
        regex,
        template,
        text,
    };

    pub const Call = struct {
        view: View,

        pub fn arguments(call: Call) Children {
            assert(call.view.category() == .call);

            const inner: ChildrenInner = switch (call.view) {
                .go => |held| .{ .go = skip_first(held.children(), 1) },
                .javascript => |held| .{
                    .javascript = (held.child_first_of(.arguments) orelse held).children(),
                },
                .odin => |held| .{ .odin = skip_first(odin_call(held).children(), 1) },
                .python => |held| .{ .python = skip_first(held.children(), 1) },
                .rust => |held| .{ .rust = rust_arguments(held) },
                .zig => |held| .{
                    .zig = skip_first(held.children(), @intFromBool(held.kind() == .call)),
                },
            };

            assert(std.meta.activeTag(inner) == std.meta.activeTag(call.view));

            return .of(null, inner);
        }

        pub fn callee(call: Call) ?View {
            assert(call.view.category() == .call);

            const held: ?View = switch (call.view) {
                .go => |inner| wrap_optional(.go, (inner.as_call() orelse return null).callee()),
                .javascript => |inner| wrap_optional(
                    .javascript,
                    (inner.as_call() orelse return null).callee(),
                ),
                .odin => |inner| wrap_optional(.odin, odin_call(inner).child_first()),
                .python => |inner| wrap_optional(
                    .python,
                    (inner.as_call() orelse return null).callee(),
                ),
                .rust => |inner| wrap_optional(.rust, rust_callee(inner)),
                .zig => |inner| wrap_optional(.zig, (inner.as_call() orelse return null).callee()),
            };

            if (held) |found| assert(found.index() > call.view.index());

            return held;
        }

        pub fn name_token(call: Call) ?u32 {
            assert(call.view.category() == .call);

            const position: ?u32 = switch (call.view) {
                .go => |held| (held.as_call() orelse return null).name_token(),
                .javascript => |held| script_call_name(held),
                .odin => |held| (odin_call(held).as_call() orelse return null).name_token(),
                .python => |held| python_call_name(held),
                .rust => |held| rust_call_name(held),
                .zig => |held| (held.as_call() orelse return null).name_token(),
            };

            if (position) |found| assert(found < call.view.token_end());

            return position;
        }

        pub fn receiver(call: Call) ?View {
            assert(call.view.category() == .call);

            const held: ?View = switch (call.view) {
                .go => |inner| wrap_optional(.go, go_receiver(inner)),
                .javascript => |inner| wrap_optional(.javascript, script_receiver(inner)),
                .odin => |inner| wrap_optional(.odin, odin_receiver(inner)),
                .python => |inner| wrap_optional(.python, python_receiver(inner)),
                .rust => |inner| wrap_optional(.rust, rust_receiver(inner)),
                .zig => |inner| wrap_optional(.zig, zig_receiver(inner)),
            };

            if (held) |found| assert(std.meta.activeTag(found) == std.meta.activeTag(call.view));

            return held;
        }
    };

    pub const Constant = struct {
        view: View,

        pub fn literal_class(constant: Constant, source: []const u8) Literal {
            assert(source.len <= std.math.maxInt(u32));
            assert(constant.view.index() < constant.view.node_count());

            const class: Literal = switch (constant.view) {
                .go => |held| switch (go.literal_class(held.text(source))) {
                    .number => .number,
                    .rune => .character,
                    .text => .text,
                },
                .javascript => |held| script_literal(held),
                .odin => |held| switch (odin.literal_class(held.text(source))) {
                    .character => .character,
                    .number => .number,
                    .raw, .text => .text,
                },
                .python => |held| python_literal(held),
                .rust => |held| rust_literal(held),
                .zig => |held| switch (zig.literal_class(held.text(source))) {
                    .character => .character,
                    .multiline, .text => .text,
                    .number => .number,
                },
            };

            if (constant.view == .go) assert(class != .other);

            return class;
        }
    };

    pub const Container = struct {
        view: View,

        pub fn bases(container: Container) Bases {
            assert(container.view.index() < container.view.node_count());

            const inner: BasesInner = switch (container.view) {
                .go, .odin, .rust, .zig => .empty,
                .javascript => |held| .{ .javascript = script_bases(held) },
                .python => |held| .{
                    .python = (held.as_class() orelse return .{
                        .inner = .empty,
                        .remaining = 0,
                    }).bases(),
                },
            };

            const remaining = container.view.node_count() - container.view.index();

            assert(remaining > 0);
            assert(remaining <= child_count_max);

            return .{ .inner = inner, .remaining = remaining };
        }

        pub fn body(container: Container) View {
            assert(container.view.index() < container.view.node_count());

            const held: ?View = switch (container.view) {
                .go => |inner| wrap_optional(.go, go_container_body(inner)),
                .javascript => |inner| wrap_optional(.javascript, script_body(inner)),
                .odin, .zig => null,
                .python => |inner| wrap_optional(
                    .python,
                    (inner.as_class() orelse return container.view).body(),
                ),
                .rust => |inner| wrap_optional(.rust, rust_fields_of(inner)),
            };

            const found = held orelse return container.view;

            assert(found.index() > container.view.index());
            assert(std.meta.activeTag(found) == std.meta.activeTag(container.view));

            return found;
        }

        pub fn fields(container: Container) Children {
            assert(container.view.index() < container.view.node_count());

            const inner: ChildrenInner = switch (container.view) {
                .go => |held| .{
                    .go = if (go_container_body(held)) |found| found.children() else empty_of(held),
                },
                .javascript => |held| .{ .javascript = script_body_children(held) },
                .odin => |held| .{ .odin = held.children_of(.field) },
                .python => |held| .{ .python = empty_of(held) },
                .rust => |held| .{ .rust = rust_fields(held) },
                .zig => |held| .{ .zig = held.children_of(.container_field) },
            };

            assert(std.meta.activeTag(inner) == std.meta.activeTag(container.view));

            return .of(.declaration, inner);
        }

        pub fn members(container: Container) Children {
            assert(container.view.index() < container.view.node_count());

            const inner: ChildrenInner = switch (container.view) {
                .go => |held| .{ .go = empty_of(held) },
                .javascript => |held| .{ .javascript = script_body_children(held) },
                .odin => |held| .{ .odin = empty_of(held) },
                .python => |held| .{ .python = python_class_children(held) },
                .rust => |held| .{ .rust = held.children() },
                .zig => |held| .{ .zig = held.children_of(.fn_decl) },
            };

            assert(std.meta.activeTag(inner) == std.meta.activeTag(container.view));

            return .of(.function, inner);
        }

        pub fn name_token(container: Container) ?u32 {
            assert(container.view.index() < container.view.node_count());

            const position: ?u32 = switch (container.view) {
                .go => |held| position_first((held.child_first_of(.ident) orelse return null)),
                .javascript => |held| script_container_name(held),
                .odin => |held| (held.as_container() orelse return null).name_token(),
                .python => |held| (held.as_class() orelse return null).name_token(),
                .rust => |held| (held.as_definition() orelse return null).name_token(),
                .zig => |held| zig_container_name(held),
            };

            if (position) |found| assert(found < container.view.token_limit());

            return position;
        }
    };

    pub const Declaration = struct {
        view: View,

        pub fn is_constant(declaration: Declaration) bool {
            assert(declaration.view.index() < declaration.view.node_count());

            const held = switch (declaration.view) {
                .go => |inner| go_is_constant(inner),
                .javascript => |inner| script_is_constant(inner),
                .odin => |inner| if (inner.as_declaration()) |found| found.is_constant() else false,
                .python => false,
                .rust => |inner| inner.kind() == .item_const,
                .zig => |inner| if (inner.as_declaration()) |found| !found.is_mutable() else false,
            };

            if (declaration.view == .python) assert(!held);

            return held;
        }

        pub fn is_mutable(declaration: Declaration) bool {
            assert(declaration.view.index() < declaration.view.node_count());

            const held = switch (declaration.view) {
                .rust => |inner| rust_is_mutable(inner),
                else => !declaration.is_constant(),
            };

            if (declaration.view == .python) assert(held);

            return held;
        }

        pub fn is_public(declaration: Declaration) bool {
            assert(declaration.view.index() < declaration.view.node_count());

            const held = switch (declaration.view) {
                .rust => |inner| rust_is_public(inner),
                .zig => |inner| if (inner.as_declaration()) |found| found.is_public() else false,
                .go, .javascript, .odin, .python => false,
            };

            if (held) assert(declaration.view == .rust or declaration.view == .zig);

            return held;
        }

        pub fn name_token(declaration: Declaration) ?u32 {
            assert(declaration.view.index() < declaration.view.node_count());

            const position: ?u32 = switch (declaration.view) {
                .go => |held| position_first((held.child_first_of(.ident) orelse return null)),
                .javascript => |held| script_declared_name(held),
                .odin => |held| odin_declared_name(held),
                .python => |held| python_declared_name(held),
                .rust => |held| rust_declared_name(held),
                .zig => |held| (held.as_declaration() orelse return null).name_token(),
            };

            if (position) |found| assert(found < declaration.view.token_limit());

            return position;
        }

        pub fn names(declaration: Declaration) Names {
            assert(declaration.view.index() < declaration.view.node_count());

            const found: Names = switch (declaration.view) {
                .go, .odin => .{ .children = declaration.view.children_of(.name) },
                .javascript => |held| .{ .children = script_names(.javascript, held) },
                .python => |held| .{ .children = python_names(held) },
                .rust => |held| rust_names(rust_declared(held)),
                .zig => |held| .{ .positions = .of(.{ .zig = held.positions_of(.identifier) }) },
            };

            if (declaration.view == .zig) assert(found == .positions);

            return found;
        }

        pub fn type_of(declaration: Declaration) ?View {
            assert(declaration.view.index() < declaration.view.node_count());

            const held: ?View = switch (declaration.view) {
                .go => |inner| wrap_optional(.go, go_declared_type(inner)),
                .javascript => |inner| wrap_optional(
                    .javascript,
                    inner.child_first_of(.type_annotation),
                ),
                .odin => |inner| wrap_optional(
                    .odin,
                    (inner.as_declaration() orelse return null).type_of(),
                ),
                .python => |inner| wrap_optional(
                    .python,
                    (inner.as_assign() orelse return null).annotation(),
                ),
                .rust => |inner| wrap_optional(.rust, rust_declared_type(inner)),
                .zig => |inner| wrap_optional(
                    .zig,
                    (inner.as_declaration() orelse return null).type_of(),
                ),
            };

            if (held) |found| assert(found.index() > declaration.view.index());

            return held;
        }

        pub fn value(declaration: Declaration) ?View {
            assert(declaration.view.index() < declaration.view.node_count());

            const held: ?View = switch (declaration.view) {
                .go => |inner| wrap_optional(.go, go_declared_value(inner)),
                .javascript => |inner| wrap_optional(.javascript, script_declared_value(inner)),
                .odin => |inner| wrap_optional(.odin, odin_declared_value(inner)),
                .python => |inner| wrap_optional(
                    .python,
                    (inner.as_assign() orelse return null).value(),
                ),
                .rust => |inner| wrap_optional(.rust, rust_declared_value(inner)),
                .zig => |inner| wrap_optional(
                    .zig,
                    (inner.as_declaration() orelse return null).value(),
                ),
            };

            if (held) |found| assert(found.index() > declaration.view.index());

            return held;
        }
    };

    pub const Field = struct {
        view: View,

        pub fn name_token(field: Field) ?u32 {
            assert(field.view.index() < field.view.node_count());

            const position: ?u32 = switch (field.view) {
                .go => |held| go_field_name(held),
                .javascript => |held| position_first((held.child_first() orelse return null)),
                .odin => |held| odin_field_name(held),
                .python => null,
                .rust => |held| (held.as_field() orelse return null).name_token(),
                .zig => |held| (held.as_field() orelse return null).name_token(),
            };

            if (field.view == .python) assert(position == null);
            if (position) |found| assert(found < field.view.token_limit());

            return position;
        }

        pub fn type_of(field: Field) ?View {
            assert(field.view.index() < field.view.node_count());

            const held: ?View = switch (field.view) {
                .go => |inner| wrap_optional(.go, (inner.as_field() orelse return null).type_of()),
                .javascript => |inner| wrap_optional(
                    .javascript,
                    inner.child_first_of(.type_annotation),
                ),
                .odin => |inner| wrap_optional(
                    .odin,
                    (inner.as_field() orelse return null).type_of(),
                ),
                .python => null,
                .rust => |inner| wrap_optional(
                    .rust,
                    (inner.as_field() orelse return null).type_of(),
                ),
                .zig => |inner| wrap_optional(
                    .zig,
                    (inner.as_field() orelse return null).type_of(),
                ),
            };

            if (held) |found| assert(found.index() > field.view.index());

            return held;
        }

        pub fn value(field: Field) ?View {
            assert(field.view.index() < field.view.node_count());

            const held: ?View = switch (field.view) {
                .javascript => |inner| wrap_optional(.javascript, script_field_value(inner)),
                .zig => |inner| wrap_optional(.zig, (inner.as_field() orelse return null).value()),
                .go, .odin, .python, .rust => null,
            };

            if (held) |found| assert(found.index() > field.view.index());
            if (field.view == .go) assert(held == null);

            return held;
        }
    };

    pub const Function = struct {
        view: View,

        fn parameters_holder(function: Function) ?View {
            assert(function.view.index() < function.view.node_count());

            const holder: ?View = switch (function.view) {
                .python => |held| if (held.kind() == .lambda)
                    function.view
                else
                    function.view.child_first_of(.parameters),
                .go => go_parameters_holder(function),
                .odin => |held| wrap_optional(
                    .odin,
                    (held.as_function() orelse return null).parameters(),
                ),
                .javascript, .rust, .zig => parenthesised_parameters(function.view),
            };

            if (holder) |found| assert(found.index() >= function.view.index());

            return holder;
        }

        pub fn body(function: Function) ?View {
            assert(function.view.index() < function.view.node_count());

            const typed: ?View = switch (function.view) {
                .go => |held| wrap_optional(
                    .go,
                    if (held.as_function()) |found| found.body() else null,
                ),
                .javascript => |held| wrap_optional(
                    .javascript,
                    if (held.as_function()) |found| found.body() else null,
                ),
                .odin => |held| wrap_optional(
                    .odin,
                    if (held.as_function()) |found| found.body() else null,
                ),
                .python => |held| wrap_optional(.python, python_function_body(held)),
                .rust => |held| wrap_optional(
                    .rust,
                    if (held.as_function()) |found| found.body() else null,
                ),
                .zig => |held| wrap_optional(
                    .zig,
                    if (held.as_function()) |found| found.body() else null,
                ),
            };

            if (typed) |found| return found;

            const blocks = function.view.children_of(.block);
            const held = blocks.last() orelse return null;

            assert(held.category() == .block);
            assert(held.index() > function.view.index());

            return held;
        }

        pub fn is_anonymous(function: Function) bool {
            if (function.view.category() == .lambda) return true;

            assert(function.view.category() == .function);
            assert(function.view.index() < function.view.node_count());

            return function.name_token() == null;
        }

        pub fn is_async(function: Function) bool {
            assert(function.view.index() < function.view.node_count());

            const held = switch (function.view) {
                .javascript => |inner| if (inner.as_function()) |found| found.is_async() else false,
                .python => |inner| if (inner.as_function()) |found| found.is_async() else false,
                .rust => |inner| if (inner.as_function()) |found| found.is_async() else false,
                .go, .odin, .zig => false,
            };

            if (function.view == .go) assert(!held);

            return held;
        }

        pub fn is_public(function: Function) bool {
            assert(function.view.index() < function.view.node_count());

            const held = switch (function.view) {
                .rust => |inner| rust_is_public(inner),
                .zig => |inner| if (inner.as_function()) |found| found.is_public() else false,
                .go, .javascript, .odin, .python => false,
            };

            if (held) assert(function.view == .rust or function.view == .zig);

            return held;
        }

        pub fn name_token(function: Function) ?u32 {
            assert(function.view.index() < function.view.node_count());

            const typed: ?u32 = switch (function.view) {
                .odin => |held| odin_function_name(held),
                inline else => |held| if (held.as_function()) |found| found.name_token() else null,
            };

            if (typed) |position| {
                assert(position < function.view.token_limit());

                return position;
            }

            const name = function.view.child_first_of(.name) orelse return null;

            assert(name.index() > function.view.index());

            return position_first_of(name);
        }

        pub fn parameter_nodes(function: Function) Children {
            assert(function.view.index() < function.view.node_count());

            const holder = parenthesised_parameters(function.view);

            const found = if (holder) |held|
                held.children_of(.parameter)
            else
                function.view.children_of(.parameter);

            assert(found.category.? == .parameter);
            assert(found.remaining <= function.view.node_count());

            return found;
        }

        pub fn parameters(function: Function) Parameters {
            assert(function.view.index() < function.view.node_count());

            const inner: ParametersInner = switch (function.view) {
                .go => |held| go_parameters(held),
                .javascript => |held| script_parameters(.javascript, held),
                .odin => |held| odin_parameters(held),
                .python => |held| python_parameters(held),
                .rust => |held| rust_parameters(held),
                .zig => |held| zig_parameters(held),
            };

            if (inner != .empty) assert(std.mem.eql(u8, @tagName(inner), @tagName(function.view)));

            return .{ .inner = inner, .remaining = parameter_count_max };
        }

        pub fn parameters_span(function: Function) ?Span {
            assert(function.view.index() < function.view.node_count());

            const holder = function.parameters_holder() orelse return null;
            var found = holder.positions();
            var open: ?u32 = null;
            var close: ?u32 = null;

            for (0..child_count_max) |_| {
                const position = found.next() orelse break;
                const token = holder.token_at(position);

                if (open == null) {
                    if (token.is_punctuation(.paren_open)) open = position;
                }

                if (token.is_punctuation(.paren_close)) close = position;
            }

            const first = holder.token_at(open orelse return null);
            const last = holder.token_at(close orelse return null);

            assert(holder.index() >= function.view.index());
            assert(last.end() >= first.offset);

            return .{ .length = last.end() - first.offset, .offset = first.offset };
        }

        pub fn receiver(function: Function) ?View {
            assert(function.view.index() < function.view.node_count());

            const held: ?View = switch (function.view) {
                .go => |inner| wrap_optional(
                    .go,
                    (inner.as_function() orelse return null).receiver(),
                ),
                .rust => |inner| wrap_optional(.rust, rust_receiver_of(inner)),
                .javascript, .odin, .python, .zig => null,
            };

            if (held) |found| assert(found.index() > function.view.index());
            if (function.view == .zig) assert(held == null);

            return held;
        }

        pub fn returns(function: Function) ?View {
            assert(function.view.index() < function.view.node_count());

            const held: ?View = switch (function.view) {
                .go => |inner| wrap_optional(.go, go_returns(inner)),
                .javascript => |inner| wrap_optional(.javascript, script_returns(inner)),
                .odin => |inner| wrap_optional(
                    .odin,
                    (inner.as_function() orelse return null).returns(),
                ),
                .python => |inner| wrap_optional(
                    .python,
                    (inner.as_function() orelse return null).returns_annotation(),
                ),
                .rust => |inner| wrap_optional(.rust, rust_returns(inner)),
                .zig => |inner| wrap_optional(
                    .zig,
                    (inner.as_function() orelse return null).returns(),
                ),
            };

            if (held) |found| assert(found.index() > function.view.index());

            return held;
        }

        pub fn returns_span(function: Function) ?Span {
            assert(function.view.index() < function.view.node_count());

            const node = function.returns() orelse return null;
            const extent = node.span();

            assert(node.index() > function.view.index());

            const held = switch (function.view) {
                .zig => |inner| inner,
                else => return extent,
            };

            const declared = held.as_function() orelse return null;
            const prototype = declared.prototype() orelse return null;
            const close = prototype.token_first(.paren_close) orelse return null;

            assert(close < node.token_start());

            return zig_returns_span(prototype, close, node.token_start(), extent);
        }
    };

    pub const Import = struct {
        view: View,

        pub const CapacityError = error{Truncated};

        pub fn is_wildcard(import: Import) bool {
            assert(import.view.index() < import.view.node_count());

            const held = switch (import.view) {
                .go => |inner| inner.token_first(.dot) != null,
                .javascript => |inner| inner.token_first(.star) != null,
                .python => |inner| inner.token_first(.star) != null,
                .rust => |inner| inner.token_first(.star) != null or rust_use_glob(inner),
                .odin, .zig => false,
            };

            if (import.view == .odin) assert(!held);

            return held;
        }

        pub fn segments(import: Import, out: *ArrayType(Span)) CapacityError!void {
            out.clear();

            assert(out.capacity() > 0);
            assert(import.view.index() < import.view.node_count());

            switch (import.view) {
                .go => |held| {
                    const specification = held.as_specification() orelse return;
                    const path = specification.path() orelse return;

                    try segment_push(out, path.span());
                },
                .javascript => |held| {
                    const statement = held.as_import() orelse return;
                    const source = statement.source() orelse return;

                    try segment_push(out, source.span());
                },
                .odin => |held| {
                    const path = held.child_first_of(.string) orelse return;

                    try segment_push(out, path.span());
                },
                .python => |held| try python_import_segments(held, out),
                .rust => |held| try rust_use_segments(held, out),
                .zig => {},
            }
        }
    };

    pub const Operation = struct {
        view: View,

        pub fn operands(operation: Operation) Children {
            assert(operation.view.as_operation() != null);

            const found = operation.view.children();

            assert(found.category == null);

            return found;
        }

        pub fn operator_tokens(operation: Operation) Positions {
            assert(operation.view.as_operation() != null);

            const found = operation.view.positions();

            assert(found.remaining <= operation.view.token_end());

            return found;
        }
    };

    pub const Parameter = struct {
        default: ?View,
        group: u32,
        name: ?u32,
        node: View,
        span: Span,
        type_of: ?View,
        type_span: ?Span,
        variadic: bool,
    };

    pub const Statement = struct {
        view: View,

        pub fn body(statement: Statement) ?View {
            assert(statement.view.index() < statement.view.node_count());

            switch (statement.view) {
                inline else => |held, tag| {
                    const found = held.as_statement() orelse return null;
                    const inner = found.body() orelse return null;

                    assert(inner.node >= held.node);
                    assert(inner.tree == held.tree);

                    return wrap(tag, inner);
                },
            }
        }

        pub fn clauses(statement: Statement) Clauses {
            assert(statement.view.index() < statement.view.node_count());

            const header_index = if (statement.header()) |held| held.index() else null;
            const body_index = if (statement.body()) |held| held.index() else null;
            const cases = statement.view.category() == .match;

            const holder: View = switch (statement.view) {
                .javascript => |held| wrap(
                    .javascript,
                    held.child_first_of(.switch_body) orelse held,
                ),
                .go, .odin, .python, .rust, .zig => if (cases)
                    statement.body() orelse statement.view
                else
                    statement.view,
            };

            const inside_body = holder.index() != statement.view.index();

            assert(holder.index() >= statement.view.index());
            if (inside_body) assert(holder.index() > statement.view.index());

            return .{
                .body = if (inside_body) null else body_index,
                .children = holder.children(),
                .header = if (inside_body) null else header_index,
            };
        }

        pub fn header(statement: Statement) ?View {
            assert(statement.view.index() < statement.view.node_count());

            switch (statement.view) {
                inline else => |held, tag| {
                    const found = held.as_statement() orelse return null;
                    const inner = found.header() orelse return null;

                    assert(inner.node > held.node);
                    assert(inner.tree == held.tree);

                    return wrap(tag, inner);
                },
            }
        }
    };

    pub const Ancestors = struct {
        current: View,
        remaining: u32,

        pub fn count(iterator: *const Ancestors) u32 {
            var rest = iterator.*;
            var total: u32 = 0;

            for (0..iterator.remaining) |_| {
                _ = rest.next() orelse break;

                total += 1;
            }

            assert(total <= iterator.remaining);

            const rest_next = rest.next();

            assert(rest_next == null);

            return total;
        }

        pub fn next(iterator: *Ancestors) ?View {
            assert(iterator.remaining <= iterator.current.index());

            if (iterator.remaining == 0) return null;

            const above = iterator.current.parent() orelse return null;

            assert(above.index() < iterator.current.index());

            iterator.current = above;
            iterator.remaining = @min(iterator.remaining - 1, above.index());

            return above;
        }
    };

    pub const Bases = struct {
        inner: BasesInner,
        remaining: u32,

        pub fn count(iterator: *const Bases) u32 {
            var rest = iterator.*;
            var total: u32 = 0;

            for (0..iterator.remaining) |_| {
                _ = rest.next() orelse break;

                total += 1;
            }

            assert(total <= iterator.remaining);

            const rest_next = rest.next();

            assert(rest_next == null);

            return total;
        }

        pub fn next(iterator: *Bases) ?View {
            assert(iterator.remaining <= child_count_max);

            if (iterator.remaining == 0) return null;

            const found: ?View = switch (iterator.inner) {
                .empty => null,
                .javascript => |*inner| wrap_optional(.javascript, script_base_next(inner)),
                .python => |*inner| wrap_optional(.python, inner.next()),
            };

            const held = found orelse {
                iterator.remaining = 0;

                return null;
            };

            iterator.remaining -= 1;

            return held;
        }
    };

    pub const Children = struct {
        category: ?Category,
        inner: ChildrenInner,
        remaining: u32,

        fn of(wanted: ?Category, inner: ChildrenInner) Children {
            if (wanted) |held| assert(held != .other);
            assert(switch (inner) {
                inline else => |*held| held.current == null or held.current.? <= held.tree.count(),
            });

            const remaining: u32 = switch (inner) {
                inline else => |*held| if (held.current) |first| held.tree.count() - first else 0,
            };

            const found: Children = .{ .category = wanted, .inner = inner, .remaining = remaining };

            assert(found.remaining <= found.node_count());

            return found;
        }

        fn inner_next(iterator: *Children) ?View {
            switch (iterator.inner) {
                inline else => |*inner, tag| {
                    const held = inner.next() orelse return null;

                    assert(held.node < held.tree.count());
                    assert(held.tokens.len == held.raw.len);

                    return wrap(tag, held);
                },
            }
        }

        fn node_count(iterator: *const Children) u32 {
            const result = switch (iterator.inner) {
                inline else => |*inner| inner.tree.count(),
            };

            assert(result <= child_count_max);

            return result;
        }

        pub fn count(iterator: *const Children) u32 {
            var rest = iterator.*;
            var total: u32 = 0;

            for (0..iterator.remaining) |_| {
                _ = rest.next() orelse break;

                total += 1;
            }

            assert(total <= iterator.remaining);

            const rest_next = rest.next();

            assert(rest_next == null);

            return total;
        }

        pub fn last(iterator: *const Children) ?View {
            var rest = iterator.*;
            var found: ?View = null;

            for (0..iterator.remaining) |_| {
                found = rest.next() orelse break;
            }

            const rest_next = rest.next();

            assert(rest_next == null);
            if (found) |held| assert(held.index() < held.node_count());

            return found;
        }

        pub fn next(iterator: *Children) ?View {
            assert(iterator.remaining <= iterator.node_count());

            for (0..iterator.remaining) |_| {
                iterator.remaining -= 1;

                const held = iterator.inner_next() orelse {
                    iterator.remaining = 0;

                    return null;
                };

                const wanted = iterator.category orelse return held;
                if (held.category() == wanted) return held;
            }

            assert(iterator.remaining == 0);

            return null;
        }
    };

    pub const Clauses = struct {
        body: ?u32,
        children: Children,
        header: ?u32,

        pub fn count(clauses: *const Clauses) u32 {
            var rest = clauses.*;
            var total: u32 = 0;

            for (0..clauses.children.remaining) |_| {
                _ = rest.next() orelse break;

                total += 1;
            }

            assert(total <= clauses.children.remaining);

            const rest_next = rest.next();

            assert(rest_next == null);

            return total;
        }

        pub fn next(clauses: *Clauses) ?View {
            for (0..clauses.children.remaining) |_| {
                const held = clauses.children.next() orelse return null;
                const node = held.index();

                if (clauses.body) |skipped| {
                    if (node == skipped) continue;
                }

                if (clauses.header) |skipped| {
                    if (node == skipped) continue;
                }

                switch (held.category()) {
                    .block, .branch, .except => {
                        assert(node != clauses.body);
                        assert(node != clauses.header);

                        return held;
                    },
                    else => {},
                }
            }

            return null;
        }
    };

    pub const Names = union(enum) {
        children: Children,
        positions: Positions,
        rust: rust.Children,

        pub fn count(names: *const Names) u32 {
            const bound = names.remaining();
            var rest = names.*;
            var total: u32 = 0;

            for (0..bound) |_| {
                _ = rest.next() orelse break;

                total += 1;
            }

            assert(total <= bound);
            assert(std.meta.activeTag(rest) == std.meta.activeTag(names.*));

            return total;
        }

        pub fn remaining(names: *const Names) u32 {
            const result = switch (names.*) {
                .children => |*held| held.remaining,
                .positions => |*held| held.remaining,
                .rust => |*held| if (held.current) |first| held.tree.count() - first else 0,
            };

            assert(result <= child_count_max);

            return result;
        }

        pub fn next(names: *Names) ?u32 {
            switch (names.*) {
                .children => |*walk| {
                    for (0..walk.remaining) |_| {
                        const held = walk.next() orelse return null;

                        assert(held.index() < held.node_count());

                        if (name_position_of(held)) |position| return position;
                    }

                    assert(walk.remaining == 0);

                    return null;
                },
                .positions => |*walk| {
                    const position = walk.next() orelse return null;

                    assert(position < walk.inner_limit());

                    return position;
                },
                .rust => |*walk| {
                    for (0..walk.tree.count()) |_| {
                        const held = walk.next() orelse return null;

                        assert(held.node < held.tree.count());

                        if (rust_name_of(held)) |position| return position;
                    }

                    return null;
                },
            }
        }
    };

    pub const Parameters = struct {
        inner: ParametersInner,
        remaining: u32,

        pub fn count(parameters: *const Parameters) u32 {
            var rest = parameters.*;
            var total: u32 = 0;

            for (0..parameters.remaining) |_| {
                _ = rest.next() orelse break;

                total += 1;
            }

            assert(total <= parameter_count_max);
            assert(total <= parameters.remaining);

            return total;
        }

        pub fn next(parameters: *Parameters) ?Parameter {
            assert(parameters.remaining <= parameter_count_max);

            if (parameters.remaining == 0) return null;

            parameters.remaining -= 1;

            const found: ?Parameter = switch (parameters.inner) {
                .empty => null,
                .go => |*inner| go_parameter_next(inner),
                .javascript => |*inner| script_parameter(inner.next() orelse return null),
                .odin => |*inner| odin_parameter_next(inner),
                .python => |*inner| python_parameter(inner.next() orelse return null),
                .rust => |*inner| rust_parameter_next(inner),
                .zig => |*inner| zig_parameter_next(inner),
            };

            if (parameters.inner == .empty) assert(found == null);

            return found;
        }

        pub fn truncated(parameters: *const Parameters) bool {
            assert(parameters.remaining <= parameter_count_max);

            if (parameters.remaining > 0) return false;

            var rest: Parameters = .{ .inner = parameters.inner, .remaining = 1 };
            return rest.next() != null;
        }
    };

    pub const Positions = struct {
        inner: PositionsInner,
        remaining: u32,

        fn of(inner: PositionsInner) Positions {
            assert(switch (inner) {
                inline else => |*held| held.limit <= held.raw.len,
            });

            const remaining: u32 = switch (inner) {
                inline else => |*held| held.limit -| held.position,
            };

            const found: Positions = .{ .inner = inner, .remaining = remaining };

            assert(found.remaining <= found.inner_limit());

            return found;
        }

        fn inner_limit(iterator: *const Positions) u32 {
            const limit = switch (iterator.inner) {
                inline else => |*held| held.limit,
            };

            assert(limit <= std.math.maxInt(u32));

            return limit;
        }

        pub fn count(iterator: *const Positions) u32 {
            var rest = iterator.*;
            var total: u32 = 0;

            for (0..iterator.remaining) |_| {
                _ = rest.next() orelse break;

                total += 1;
            }

            assert(total <= iterator.remaining);

            const rest_next = rest.next();

            assert(rest_next == null);

            return total;
        }

        pub fn next(iterator: *Positions) ?u32 {
            assert(iterator.remaining <= iterator.inner_limit());

            if (iterator.remaining == 0) return null;

            iterator.remaining -= 1;

            switch (iterator.inner) {
                inline else => |*inner| {
                    const position = inner.next() orelse {
                        iterator.remaining = 0;

                        return null;
                    };

                    assert(position < inner.limit);

                    return position;
                },
            }
        }
    };
};

const BasesInner = union(enum) {
    empty,
    javascript: javascript.Children,
    python: python.Excluding,
};

const ChildrenInner = union(Tag) {
    go: go.Children,
    javascript: javascript.Children,
    odin: odin.Children,
    python: python.Children,
    rust: rust.Children,
    zig: zig.Children,
};

const GoNames = struct {
    children: go.Children,
    owner: go.View,
    remaining: u32,
};

const GoParameters = struct {
    fields: go.Children,
    names: ?GoNames,
};

const OdinNames = struct {
    children: odin.Children,
    owner: odin.View,
};

const OdinParameters = struct {
    names: ?OdinNames,
    parameters: odin.Children,
};

const ParametersInner = union(enum) {
    empty,
    go: GoParameters,
    javascript: javascript.Children,
    odin: OdinParameters,
    python: python.Children,
    rust: rust.Children,
    zig: ZigParameters,
};

const PositionsInner = union(Tag) {
    go: go.Positions,
    javascript: javascript.Positions,
    odin: odin.Positions,
    python: python.Positions,
    rust: rust.Positions,
    zig: zig.Positions,
};

const ZigParameters = struct {
    close: u32,
    cursor: u32,
    prototype: zig.View,
};

pub const child_count_max: u32 = 1 << 22;
pub const parameter_count_max: u32 = 1 << 8;
pub const segment_count_max: u32 = 1 << 6;
const close_none: u32 = std.math.maxInt(u32);

fn wrap(comptime tag: Tag, held: anytype) View {
    assert(held.node < held.tree.count());

    const view = @unionInit(View, @tagName(tag), held);

    assert(std.meta.activeTag(view) == tag);

    return view;
}

fn wrap_optional(comptime tag: Tag, held: anytype) ?View {
    if (held) |inner| assert(inner.node < inner.tree.count());

    const inner = held orelse return null;

    assert(inner.node < inner.tree.count());
    assert(inner.tokens.len == inner.raw.len);

    return wrap(tag, inner);
}

fn span_covers(span: Span, offset: u32) bool {
    assert(span.length <= std.math.maxInt(u32) - span.offset);

    if (offset < span.offset) return false;

    assert(offset >= span.offset);

    return offset < span.end();
}

fn skip_first(children: anytype, skipped: u32) @TypeOf(children) {
    var rest = children;

    assert(skipped <= 2);

    for (0..skipped) |_| {
        if (rest.next() == null) break;
    }

    if (rest.current) |current| assert(current < rest.tree.count());

    return rest;
}

fn empty_of(held: anytype) @TypeOf(held.children()) {
    assert(held.node < held.tree.count());

    const found = held.children_of(.error_node);

    assert(found.kind.? == .error_node);

    return found;
}

fn position_first(held: anytype) ?u32 {
    assert(held.node < held.tree.count());

    var found = held.positions();
    const position = found.next() orelse return null;

    assert(position >= held.token_start());
    assert(position < held.token_end());

    return position;
}

fn position_first_of(view: View) ?u32 {
    assert(view.index() < view.node_count());

    var found = view.positions();
    const position = found.next() orelse return null;

    assert(position >= view.token_start());
    assert(position < view.token_end());

    return position;
}

fn name_position_of(held: View) ?u32 {
    assert(held.index() < held.node_count());

    if (held.category() == .name) {
        if (position_first_of(held)) |position| return position;
    }

    const name = held.child_first_of(.name) orelse return null;

    assert(name.index() > held.index());
    assert(name.category() == .name);

    return position_first_of(name);
}

fn is_parenthesised(held: View) bool {
    assert(held.token_start() <= held.token_end());

    var found = held.positions();

    for (0..found.remaining) |_| {
        const position = found.next() orelse return false;
        if (held.token_at(position).is_punctuation(.paren_open)) return true;
    }

    assert(found.remaining == 0);

    return false;
}

fn parenthesised_parameters(view: View) ?View {
    assert(view.index() < view.node_count());

    var found = view.children_of(.parameters);

    for (0..child_count_max) |_| {
        const held = found.next() orelse break;

        assert(held.category() == .parameters);

        if (is_parenthesised(held)) return held;
    }

    return view.child_first_of(.parameters);
}

fn segment_push(out: *ArrayType(Span), span: Span) error{Truncated}!void {
    if (out.full()) return error.Truncated;
    assert(span.length <= std.math.maxInt(u32) - span.offset);

    const before = out.count();

    out.push(span);

    assert(out.count() == before + 1);
    assert(out.count() <= out.capacity());
}

fn go_container_body(held: go.View) ?go.View {
    assert(held.kind() == .type_spec);

    var found = held.children();

    for (0..child_count_max) |_| {
        const declared = found.next() orelse return null;

        switch (declared.kind()) {
            .interface_type, .struct_type => {
                assert(declared.node > held.node);

                return declared.child_first_of(.field_list);
            },
            else => {},
        }
    }

    return null;
}

fn go_declared_type(held: go.View) ?go.View {
    assert(held.node < held.tree.count());

    var found = held.children();

    for (0..child_count_max) |_| {
        const child = found.next() orelse return null;
        if (child.kind() == .ident) continue;
        if (child.kind().category() != .type) continue;

        assert(child.node > held.node);

        return child;
    }

    return null;
}

fn go_declared_value(held: go.View) ?go.View {
    assert(held.node < held.tree.count());

    if (held.as_specification()) |specification| {
        var values = specification.values();
        return values.next();
    }

    const assigned = held.token_first(.colon_equal) orelse return null;

    assert(assigned >= held.token_start());
    assert(assigned < held.token_end());

    return child_starting_after(held, assigned);
}

fn go_field_name(held: go.View) ?u32 {
    assert(held.node < held.tree.count());

    const field = held.as_field() orelse return null;
    var names = field.names();
    const name = names.next() orelse return null;

    assert(name.node > held.node);
    assert(name.tree == held.tree);

    return position_first(name);
}

fn go_is_constant(held: go.View) bool {
    assert(held.node < held.tree.count());

    const above = held.parent() orelse return false;
    const declaration = above.as_declaration() orelse return false;
    const keyword = declaration.keyword() orelse return false;

    assert(above.node < held.node);
    assert(keyword.is_token());

    return keyword == .const_keyword;
}

fn go_is_declaration(held: go.View) bool {
    if (held.kind() == .value_spec) return true;
    if (held.kind() != .assign_stmt) return false;

    assert(held.kind() == .assign_stmt);
    assert(held.node < held.tree.count());

    return held.token_first(.colon_equal) != null;
}

fn go_parameter_list(held: go.View) ?go.View {
    assert(held.node < held.tree.count());

    const function = held.as_function() orelse return null;
    const signature = function.signature() orelse return null;
    var skipped: u32 = @intFromBool(function.receiver() != null);
    var lists = signature.children_of(.field_list);

    assert(signature.node >= held.node);

    for (0..child_count_max) |_| {
        const list = lists.next() orelse return null;
        if (list.token_first(.paren_open) == null) continue;
        if (skipped == 0) return list;

        skipped -= 1;
    }

    assert(skipped <= 1);

    return null;
}

fn go_parameters(held: go.View) ParametersInner {
    assert(held.node < held.tree.count());

    const list = go_parameter_list(held) orelse return .empty;

    assert(list.kind() == .field_list);
    assert(list.node > held.node);

    return .{ .go = .{ .fields = list.children_of(.field), .names = null } };
}

fn go_parameters_holder(function: View.Function) ?View {
    assert(function.view.index() < function.view.node_count());

    const signature = function.view.child_first_of(.parameters) orelse return null;
    var skipped: u32 = @intFromBool(function.receiver() != null);
    var lists = signature.children_of(.parameters);

    assert(signature.index() > function.view.index());

    for (0..child_count_max) |_| {
        const list = lists.next() orelse return null;
        if (!is_parenthesised(list)) continue;
        if (skipped == 0) return list;

        skipped -= 1;
    }

    assert(skipped <= 1);

    return null;
}

fn go_parameter_next(state: *GoParameters) ?View.Parameter {
    for (0..parameter_count_max) |_| {
        if (state.names) |*names| {
            assert(names.remaining <= parameter_count_max);

            if (names.remaining > 0) {
                names.remaining -= 1;

                const name = names.children.next() orelse return null;
                return go_parameter(names.owner, position_first(name));
            }

            state.names = null;
        }

        const field = state.fields.next() orelse return null;
        const wrapped = field.as_field() orelse continue;
        var leading = wrapped.names();
        var total: u32 = 0;

        for (0..parameter_count_max) |_| {
            _ = leading.next() orelse break;

            total += 1;
        }

        if (total == 0) return go_parameter(field, null);

        assert(total <= parameter_count_max);

        state.names = .{ .children = field.children(), .owner = field, .remaining = total };
    }

    return null;
}

fn go_spread_call(held: go.View) ?go.View {
    assert(held.node < held.tree.count());

    const call = held.parent() orelse return null;
    if (call.kind() != .call_expr) return null;

    const callee = call.child_first() orelse return null;
    if (callee.node == held.node) return null;

    var position = held.token_end();

    assert(callee.node < held.node);

    for (0..held.raw.len) |_| {
        if (position >= call.token_end()) return null;
        if (!held.token_kind(position).is_trivia()) break;

        position += 1;
    }

    if (position >= call.token_end()) return null;
    if (held.token_kind(position) != .dot_dot_dot) return null;
    return call;
}

fn go_parameter(field: go.View, name: ?u32) View.Parameter {
    assert(field.kind() == .field);

    const typed = (field.as_field() orelse unreachable).type_of();
    const type_of = wrap_optional(.go, typed);
    const node = wrap(.go, field);
    const variadic = if (typed) |held| held.kind() == .ellipsis else false;

    if (name) |position| assert(position >= field.token_start());

    return .{
        .default = null,
        .group = node.index(),
        .name = name,
        .node = node,
        .span = node.span(),
        .type_of = type_of,
        .type_span = if (type_of) |held| held.span() else null,
        .variadic = variadic,
    };
}

fn go_receiver(held: go.View) ?go.View {
    assert(held.node < held.tree.count());

    const call = held.as_call() orelse return null;
    const callee = call.callee() orelse return null;

    assert(callee.node > held.node);

    if (callee.kind() != .selector_expr) return null;

    assert(callee.kind() == .selector_expr);

    return callee.child_first();
}

fn go_returns(held: go.View) ?go.View {
    assert(held.node < held.tree.count());

    const function = held.as_function() orelse return null;
    const signature = function.signature() orelse return null;
    const lists = signature.children_of(.field_list);
    const expected = @as(u32, 1) + @intFromBool(function.receiver() != null);

    assert(expected <= 2);

    if (lists.count() <= expected) return null;

    const found = lists.last() orelse return null;

    assert(found.kind() == .field_list);

    return found;
}

fn child_starting_after(held: anytype, position: u32) ?@TypeOf(held) {
    assert(position >= held.token_start());

    var found = held.children();

    assert(position < held.token_end());

    for (0..child_count_max) |_| {
        const child = found.next() orelse return null;
        if (child.token_start() > position) return child;
    }

    return null;
}

fn script_call_name(held: anytype) ?u32 {
    assert(held.node < held.tree.count());

    const call = held.as_call() orelse return null;
    const callee = call.callee() orelse return null;

    assert(callee.node > held.node);

    if (callee.as_member()) |member| {
        const property = member.property() orelse return null;

        assert(property.node > callee.node);

        return position_first(property);
    }

    return position_first(callee);
}

fn script_declared_name(held: anytype) ?u32 {
    assert(held.node < held.tree.count());

    const declarator = held.as_declarator() orelse return null;
    const target = declarator.target() orelse return null;

    assert(target.node > held.node);

    if (target.kind() != .identifier_node) return null;

    assert(target.kind() == .identifier_node);

    return position_first(target);
}

fn script_declared_value(held: anytype) @TypeOf(held.child_first()) {
    assert(held.node < held.tree.count());

    const declarator = held.as_declarator() orelse found: {
        const child = held.child_first_of(.variable_declarator) orelse return null;

        break :found child.as_declarator() orelse return null;
    };

    const value = declarator.value() orelse return null;

    assert(value.node > held.node);
    assert(value.tree == held.tree);

    return value;
}

fn script_is_constant(held: anytype) bool {
    if (held.token_first(.const_keyword) != null) return true;

    const above = held.parent() orelse return false;

    assert(above.node < held.node);
    assert(above.tree == held.tree);

    return above.token_first(.const_keyword) != null;
}

fn script_is_declaration(held: anytype) bool {
    if (held.as_declarator() != null) return true;

    const kind = held.kind();

    assert(kind.is_node());
    assert(held.node < held.tree.count());

    return kind == .lexical_declaration or kind == .variable_declaration;
}

fn script_literal(held: anytype) View.Literal {
    assert(held.node < held.tree.count());

    const constant = held.as_constant() orelse return .other;

    const class: View.Literal = switch (constant.literal_class()) {
        .boolean => .boolean,
        .null, .undefined => .nil,
        .number => .number,
        .regex => .regex,
        .template => .template,
        .text => .text,
    };

    assert(class != .other);
    assert(class != .bytes);

    return class;
}

fn script_names(comptime tag: Tag, held: anytype) View.Children {
    assert(held.node < held.tree.count());

    const kind = held.kind();

    assert(tag == .javascript);
    assert(kind.is_node());

    if (held.as_declarator()) |declarator| {
        if (declarator.target()) |target| {
            if (target.kind() == .identifier_node) {
                return wrap(tag, target.parent() orelse target).children_of(.name);
            }

            return wrap(tag, target).children_of(.name);
        }
    }

    if (kind == .lexical_declaration) return wrap(tag, held).children_of(.declaration);
    if (kind == .variable_declaration) return wrap(tag, held).children_of(.declaration);
    return wrap(tag, held).children_of(.name);
}

fn script_parameters(comptime tag: Tag, held: anytype) ParametersInner {
    assert(held.node < held.tree.count());

    const parameters = held.child_first_of(.formal_parameters) orelse return .empty;

    assert(tag == .javascript);
    assert(parameters.node > held.node);

    return @unionInit(ParametersInner, @tagName(tag), parameters.children());
}

fn script_receiver(held: anytype) @TypeOf(held.child_first()) {
    assert(held.node < held.tree.count());

    const call = held.as_call() orelse return null;
    const callee = call.callee() orelse return null;
    const member = callee.as_member() orelse return null;
    const object = member.object() orelse return null;

    assert(object.node > callee.node);
    assert(callee.node > held.node);

    return object;
}

fn script_nested_name(held: anytype) ?u32 {
    assert(held.node < held.tree.count());

    const child = held.child_first() orelse return null;

    assert(child.node > held.node);
    assert(child.tree == held.tree);

    if (child.kind() != .identifier_node) return null;
    return position_first(child);
}

fn script_body(held: javascript.View) ?javascript.View {
    assert(held.index() < held.node_count());

    if (held.as_class()) |class| return class.body();

    const found = held.children();
    const last = found.last() orelse return null;

    assert(last.node > held.node);
    assert(last.tree == held.tree);

    return last;
}

fn script_body_children(held: javascript.View) javascript.Children {
    assert(held.index() < held.node_count());

    const found = script_body(held) orelse return empty_of(held);

    assert(found.node > held.node);
    assert(found.tree == held.tree);

    return found.children();
}

fn script_returns(held: javascript.View) ?javascript.View {
    assert(held.index() < held.node_count());

    const found = held.child_first_of(.type_annotation) orelse
        held.child_first_of(.type_predicate_annotation) orelse
        held.child_first_of(.asserts_annotation) orelse
        return null;

    assert(found.node > held.node);
    assert(found.tree == held.tree);

    return found;
}

fn script_container_name(held: javascript.View) ?u32 {
    assert(held.index() < held.node_count());

    if (held.as_class()) |class| return class.name_token();

    const name = held.child_first_of(.identifier_node) orelse return null;

    assert(name.node > held.node);
    assert(name.kind() == .identifier_node);

    return position_first(name);
}

fn script_field_value(held: javascript.View) ?javascript.View {
    assert(held.kind() == .field_definition or held.kind() == .public_field_definition);

    const found = held.children();
    const last = found.last() orelse return null;
    if (last.kind() == .type_annotation) return null;
    if (found.count() <= 1) return null;

    assert(last.node > held.node);

    return last;
}

fn script_is_container(held: javascript.View) bool {
    if (held.as_class() != null) return true;

    const kind = held.kind();

    assert(kind.is_node());
    assert(held.node < held.tree.count());

    return switch (kind) {
        .abstract_class_declaration, .enum_declaration, .interface_declaration => true,
        else => false,
    };
}

fn script_bases(held: javascript.View) javascript.Children {
    assert(held.index() < held.node_count());

    const heritage = held.child_first_of(.class_heritage) orelse return empty_of(held);
    const extends = heritage.child_first_of(.extends_clause) orelse return heritage.children();

    assert(heritage.node > held.node);
    assert(extends.node > heritage.node);

    return extends.children();
}

fn script_base_next(children: *javascript.Children) ?javascript.View {
    for (0..child_count_max) |_| {
        const held = children.next() orelse return null;

        switch (held.kind()) {
            .implements_clause, .type_arguments => continue,
            else => return held,
        }
    }

    return null;
}

fn script_spread_call(held: javascript.View) ?javascript.View {
    assert(held.index() < held.node_count());

    const spread = held.parent() orelse return null;
    if (spread.kind() != .spread_element) return null;

    const arguments = spread.parent() orelse return null;
    if (arguments.kind() != .arguments) return null;

    const call = arguments.parent() orelse return null;

    assert(arguments.node > call.node);

    switch (call.kind()) {
        .call_expression, .new_expression => return call,
        else => return null,
    }
}

fn script_parameter(held: javascript.View) View.Parameter {
    assert(held.index() < held.node_count());

    const pattern = script_pattern(held);
    const node = wrap(.javascript, held);

    const name: ?u32 = switch (pattern.kind()) {
        .assignment_pattern, .rest_pattern => script_nested_name(pattern),
        .identifier_node => position_first(pattern),
        else => null,
    };

    const default = script_default(held, pattern);
    const annotation = held.child_first_of(.type_annotation);
    const annotated = if (annotation) |found| found.child_first() else null;
    const type_of = wrap_optional(.javascript, annotated);
    const variadic = held.kind() == .rest_pattern or pattern.kind() == .rest_pattern;

    assert(pattern.node >= held.node);
    if (default) |value| assert(value.node > held.node);

    return .{
        .default = wrap_optional(.javascript, default),
        .group = node.index(),
        .name = name,
        .node = node,
        .span = node.span(),
        .type_of = type_of,
        .type_span = if (type_of) |found| found.span() else null,
        .variadic = variadic,
    };
}

fn script_default(held: javascript.View, pattern: javascript.View) ?javascript.View {
    assert(held.index() < held.node_count());
    assert(pattern.index() < pattern.node_count());

    if (pattern.kind() == .assignment_pattern) return pattern.child_at(1);

    const found = held.children();
    const last = found.last() orelse return null;

    assert(last.node > held.node);

    assert(pattern.node >= held.node);

    if (held.token_first(.equal) == null) return null;
    if (last.node == pattern.node) return null;
    return last;
}

fn script_pattern(held: javascript.View) javascript.View {
    assert(held.node < held.tree.count());

    var found = held.children();

    for (0..child_count_max) |_| {
        const child = found.next() orelse break;

        switch (child.kind()) {
            .accessibility_modifier, .decorator, .type_annotation => {},
            else => {
                assert(child.node > held.node);

                return child;
            },
        }
    }

    return held;
}

fn script_is_field(held: javascript.View) bool {
    assert(held.node < held.tree.count());

    const kind = held.kind();

    return kind == .field_definition or kind == .public_field_definition;
}

fn odin_call(held: odin.View) odin.View {
    assert(held.node < held.tree.count());

    if (held.kind() != .selector_call_expression) return held;

    const call = held.child_first_of(.call_expression) orelse return held;

    assert(call.node > held.node);
    assert(call.kind() == .call_expression);

    return call;
}

fn odin_declared_name(held: odin.View) ?u32 {
    assert(held.node < held.tree.count());

    if (held.as_declaration()) |declaration| {
        var names = declaration.names();
        const identifier = names.next() orelse return null;

        return identifier.name_position();
    }

    const assigned = held.token_first(.colon_equal) orelse return null;
    var found = held.children();

    assert(assigned < held.token_end());

    for (0..child_count_max) |_| {
        const child = found.next() orelse return null;

        assert(child.node > held.node);

        if (child.token_start() < assigned) return child.name_position();
    }

    return null;
}

fn odin_declared_value(held: odin.View) ?odin.View {
    assert(held.node < held.tree.count());

    if (held.as_declaration()) |declaration| return declaration.value();

    const assigned = held.token_first(.colon_equal) orelse return null;

    assert(assigned >= held.token_start());
    assert(assigned < held.token_end());

    return child_starting_after(held, assigned);
}

fn odin_default(parameter: odin.View) ?View {
    assert(parameter.node < parameter.tree.count());

    const equal = parameter.token_first(.colon_equal) orelse
        parameter.token_first(.equal) orelse return null;

    assert(equal >= parameter.token_start());
    assert(equal < parameter.token_end());

    return wrap_optional(.odin, child_starting_after(parameter, equal));
}

fn odin_field_name(held: odin.View) ?u32 {
    assert(held.node < held.tree.count());

    const field = held.as_field() orelse return null;
    var names = field.names();
    const identifier = names.next() orelse return null;

    assert(identifier.node > held.node);
    assert(identifier.tree == held.tree);

    return identifier.name_position();
}

fn odin_function_name(held: odin.View) ?u32 {
    assert(held.node < held.tree.count());

    if (held.kind() == .procedure) {
        const above = held.parent() orelse return null;
        const identifier = above.child_first_of(.identifier_node) orelse return null;

        assert(above.node < held.node);
        assert(identifier.kind() == .identifier_node);

        return identifier.name_position();
    }

    const function = held.as_function() orelse return null;
    return function.name_token();
}

fn odin_is_declaration(held: odin.View) bool {
    assert(held.node < held.tree.count());

    if (held.as_declaration() != null) {
        if (held.kind() != .import_declaration) return true;
    }

    if (held.kind() != .assignment_statement) return false;

    assert(held.kind() == .assignment_statement);

    assert(held.node < held.tree.count());

    return held.token_first(.colon_equal) != null;
}

fn odin_parameters(held: odin.View) ParametersInner {
    assert(held.node < held.tree.count());

    const function = held.as_function() orelse return .empty;
    const parameters = function.parameters() orelse return .empty;

    assert(parameters.node > held.node);
    assert(parameters.tree == held.tree);

    return .{ .odin = .{ .names = null, .parameters = parameters.children() } };
}

fn odin_parameter_next(state: *OdinParameters) ?View.Parameter {
    for (0..parameter_count_max) |_| {
        if (state.names) |*names| {
            if (names.children.next()) |identifier| {
                assert(identifier.node > names.owner.node);

                return odin_parameter(names.owner, identifier.name_position(), true);
            }

            state.names = null;
        }

        const parameter = state.parameters.next() orelse return null;

        assert(parameter.node < parameter.tree.count());

        switch (parameter.kind()) {
            .default_parameter, .parameter => {},
            else => continue,
        }

        if (parameter.child_first_of(.identifier_node) == null) {
            return odin_parameter(parameter, null, false);
        }

        state.names = .{
            .children = parameter.children_of(.identifier_node),
            .owner = parameter,
        };
    }

    return null;
}

fn odin_spread_call(held: odin.View) ?odin.View {
    assert(held.node < held.tree.count());

    const spread = held.parent() orelse return null;
    if (spread.kind() != .variadic_expression) return null;

    const call = spread.parent() orelse return null;
    if (call.kind() != .call_expression) return null;

    assert(spread.node > call.node);
    assert(held.node > spread.node);

    return call;
}

fn odin_parameter(parameter: odin.View, name: ?u32, named: bool) View.Parameter {
    assert(parameter.kind() == .parameter or parameter.kind() == .default_parameter);

    const typed = parameter.child_first_of(.type);
    const type_of = wrap_optional(.odin, typed);
    const node = wrap(.odin, parameter);
    const variadic = if (typed) |held| held.child_first_of(.variadic_type) != null else false;

    if (!named) assert(name == null);

    return .{
        .default = if (named) odin_default(parameter) else null,
        .group = node.index(),
        .name = name,
        .node = node,
        .span = node.span(),
        .type_of = type_of,
        .type_span = if (type_of) |held| held.span() else null,
        .variadic = variadic,
    };
}

fn odin_receiver(held: odin.View) ?odin.View {
    assert(held.node < held.tree.count());

    if (held.kind() == .selector_call_expression) return held.child_first();

    const above = held.parent() orelse return null;

    assert(above.node < held.node);
    assert(above.tree == held.tree);

    if (above.kind() != .member_expression) return null;
    return above.child_first();
}

fn python_call_name(held: python.View) ?u32 {
    assert(held.index() < held.node_count());

    const call = held.as_call() orelse return null;
    const callee = call.callee() orelse return null;

    assert(callee.node > held.node);

    if (callee.kind() != .attribute) return position_first(callee);

    var found = callee.positions_of(.identifier);
    var last: ?u32 = null;

    for (0..child_count_max) |_| {
        last = found.next() orelse break;
    }

    if (last) |position| assert(position < callee.token_end());

    return last;
}

fn python_class_children(held: python.View) python.Children {
    assert(held.index() < held.node_count());

    const class = held.as_class() orelse return empty_of(held);
    const found = class.body() orelse return empty_of(held);

    assert(found.node > held.node);
    assert(found.tree == held.tree);

    return found.children();
}

fn python_declared_name(held: python.View) ?u32 {
    assert(held.index() < held.node_count());

    const assign = held.as_assign() orelse return null;
    var targets = assign.targets();
    const target = targets.next() orelse return null;

    assert(target.node > held.node);

    if (target.kind() != .name_node) return null;

    assert(target.kind() == .name_node);

    return position_first(target);
}

fn python_function_body(held: python.View) ?python.View {
    assert(held.index() < held.node_count());

    if (held.as_function()) |function| {
        if (function.body()) |found| return found;
    }

    if (held.kind() != .lambda) return null;

    const found = held.children();
    const last = found.last() orelse return null;

    assert(last.node > held.node);

    assert(held.kind() == .lambda);

    return last;
}

fn python_import_segments(held: python.View, out: *ArrayType(Span)) error{Truncated}!void {
    assert(held.index() < held.node_count());

    const import = held.as_import() orelse return;

    assert(out.count() == 0);

    if (held.kind() == .import_from) return import.module_segments(out);

    var aliases = import.aliases();
    const alias = aliases.next() orelse return;

    assert(alias.view.node > held.node);

    return alias.name_segments(out);
}

fn python_literal(held: python.View) View.Literal {
    assert(held.index() < held.node_count());

    const constant = held.as_constant() orelse return .other;

    const class: View.Literal = switch (constant.literal_class()) {
        .boolean => .boolean,
        .bytes => .bytes,
        .ellipsis => .other,
        .none => .nil,
        .number => .number,
        .text => .text,
    };

    assert(class != .regex);
    assert(class != .template);

    return class;
}

fn python_names(held: python.View) View.Children {
    assert(held.index() < held.node_count());

    const view = wrap(.python, held);
    const assign = held.as_assign() orelse return view.children_of(.name);
    var targets = assign.targets();
    const target = targets.next() orelse return view.children_of(.name);

    assert(target.node > held.node);
    assert(target.tree == held.tree);

    return switch (target.kind()) {
        .name_node => view.children_of(.name),
        .list, .tuple => wrap(.python, target).children_of(.name),
        else => wrap(.python, target).children_of(.parameters),
    };
}

fn python_spread_call(held: python.View) ?python.View {
    assert(held.index() < held.node_count());

    const spread = held.parent() orelse return null;
    const call = spread.parent() orelse return null;
    if (call.kind() != .call) return null;

    assert(held.node > spread.node);
    assert(spread.node > call.node);

    switch (spread.kind()) {
        .starred => return call,
        .keyword => {
            if (spread.token_kind(spread.token_start()) != .star_star) return null;
            return call;
        },
        else => return null,
    }
}

fn python_variadic(held: python.View) bool {
    assert(held.kind() == .arg);

    var position = held.token_start();

    for (0..position) |_| {
        position -= 1;

        const kind = held.token_kind(position);
        if (kind.is_trivia()) continue;
        return kind == .star or kind == .star_star;
    }

    return false;
}

fn python_parameter(held: python.View) View.Parameter {
    assert(held.kind() == .arg);

    const argument = held.as_argument();
    const node = wrap(.python, held);
    const annotation = if (argument) |found| found.annotation() else null;
    const type_of = wrap_optional(.python, annotation);
    const default = if (argument) |found| found.default() else null;

    if (type_of) |found| assert(found.index() > node.index());

    return .{
        .default = wrap_optional(.python, default),
        .group = node.index(),
        .name = if (argument) |found| found.name_token() else null,
        .node = node,
        .span = node.span(),
        .type_of = type_of,
        .type_span = if (type_of) |found| found.span() else null,
        .variadic = python_variadic(held),
    };
}

fn python_parameters(held: python.View) ParametersInner {
    assert(held.index() < held.node_count());

    const arguments = held.child_first_of(.arguments) orelse return .empty;

    assert(arguments.node > held.node);
    assert(arguments.kind() == .arguments);

    return .{ .python = arguments.children_of(.arg) };
}

fn python_receiver(held: python.View) ?python.View {
    assert(held.index() < held.node_count());

    const call = held.as_call() orelse return null;
    const callee = call.callee() orelse return null;

    assert(callee.node > held.node);

    if (callee.kind() != .attribute) return null;

    assert(callee.kind() == .attribute);

    return callee.child_first();
}

fn rust_arguments(held: rust.View) rust.Children {
    assert(held.node < held.tree.count());

    if (held.kind() == .expr_method_call) return skip_first(held.children(), 2);
    if (held.kind() == .expr_call) return skip_first(held.children(), 1);

    const found = rust_macro(held) orelse return skip_first(held.children(), 1);

    assert(found.kind() == .macro);
    assert(found.node >= held.node);

    return found.children();
}

fn rust_call_name(held: rust.View) ?u32 {
    assert(held.node < held.tree.count());

    if (held.as_call()) |call| return call.name_token();

    const found = rust_macro(held) orelse return null;
    const path = found.child_first_of(.path) orelse return null;
    const segment = path.children_of(.path_segment).last() orelse return null;
    const name = segment.child_first_of(.ident) orelse return null;

    assert(path.node > found.node);
    assert(name.node > segment.node);

    return position_first(name);
}

fn rust_callee(held: rust.View) ?rust.View {
    assert(held.node < held.tree.count());

    if (held.as_call()) |call| return call.callee();

    const found = rust_macro(held) orelse return null;
    const path = found.child_first_of(.path) orelse return null;

    assert(found.kind() == .macro);
    assert(path.node > found.node);

    return path;
}

fn rust_declared(held: rust.View) rust.View {
    assert(held.node < held.tree.count());

    const local = held.as_local() orelse return held;
    const target = local.target() orelse return held;

    assert(target.node > held.node);
    assert(target.tree == held.tree);

    if (target.kind() == .pat_type) return target.child_first() orelse target;
    return target;
}

fn rust_declared_name(held: rust.View) ?u32 {
    assert(held.node < held.tree.count());

    const declared = rust_declared(held);

    assert(declared.node >= held.node);

    switch (declared.kind()) {
        .ident, .pat_ident => {},
        else => return null,
    }

    var names = rust_names(declared);

    assert(names == .positions or names == .rust);

    return names.next();
}

fn rust_declared_type(held: rust.View) ?rust.View {
    assert(held.node < held.tree.count());

    if (held.as_local()) |local| {
        const target = local.target() orelse return null;
        if (target.kind() != .pat_type) return null;
        return target.child_at(1);
    }

    var found = held.children();

    for (0..child_count_max) |_| {
        const child = found.next() orelse return null;
        if (child.kind().is_type()) return child;
    }

    assert(found.current == null);

    return null;
}

fn rust_declared_value(held: rust.View) ?rust.View {
    assert(held.node < held.tree.count());

    if (held.as_local()) |local| {
        if (local.value()) |found| return found;
    }

    switch (held.kind()) {
        .item_const, .item_static => {},
        else => return null,
    }

    const equal = held.token_first(.equal) orelse return null;

    assert(equal >= held.token_start());
    assert(equal < held.token_end());

    return child_starting_after(held, equal);
}

fn rust_fields(held: rust.View) rust.Children {
    assert(held.node < held.tree.count());

    const found = rust_fields_of(held) orelse return held.children_of(.variant);

    assert(found.node > held.node);
    assert(found.tree == held.tree);

    return found.children();
}

fn rust_fields_of(held: rust.View) ?rust.View {
    assert(held.node < held.tree.count());

    var found = held.children();

    for (0..child_count_max) |_| {
        const child = found.next() orelse return null;

        switch (child.kind()) {
            .fields_named, .fields_unnamed => {
                assert(child.node > held.node);

                return child;
            },
            else => {},
        }
    }

    return null;
}

fn rust_is_mutable(held: rust.View) bool {
    assert(held.node < held.tree.count());

    if (held.kind() == .item_static) {
        if (held.token_first(.mut_keyword) != null) return true;
    }

    if (held.as_local() == null) return false;

    const declared = rust_declared(held);

    assert(declared.node >= held.node);

    assert(held.kind() == .local);

    return declared.token_first(.mut_keyword) != null;
}

fn rust_is_public(held: rust.View) bool {
    if (held.token_first(.pub_keyword) != null) return true;

    assert(held.node < held.tree.count());
    assert(held.tokens.len == held.raw.len);

    return held.child_first_of(.vis_restricted) != null;
}

fn rust_macro(held: rust.View) ?rust.View {
    assert(held.node < held.tree.count());

    if (held.kind() == .macro) return held;

    const found = held.child_first_of(.macro) orelse return null;

    assert(found.node > held.node);
    assert(found.kind() == .macro);

    return found;
}

fn rust_name_of(held: rust.View) ?u32 {
    assert(held.node < held.tree.count());

    const name = switch (held.kind()) {
        .ident => held,
        .pat_ident => held.child_first_of(.ident) orelse return null,
        else => return null,
    };

    assert(name.kind() == .ident);
    assert(name.node >= held.node);

    return position_first(name);
}

fn rust_names(declared: rust.View) View.Names {
    assert(declared.node < declared.tree.count());

    if (declared.kind() != .pat_ident) return .{ .rust = declared.children() };

    const name = declared.child_first_of(.ident) orelse declared;

    assert(name.node >= declared.node);

    assert(declared.kind() == .pat_ident);

    return .{ .positions = .of(.{ .rust = name.positions() }) };
}

fn rust_parameters(held: rust.View) ParametersInner {
    assert(held.node < held.tree.count());

    const function = held.as_function() orelse return .empty;
    const signature = function.signature() orelse return .empty;

    assert(signature.node > held.node);
    assert(signature.tree == held.tree);

    return .{ .rust = signature.children() };
}

fn rust_parameter_next(children: *rust.Children) ?View.Parameter {
    for (0..parameter_count_max) |_| {
        const held = children.next() orelse return null;

        assert(held.node < held.tree.count());
        assert(held.tokens.len == held.raw.len);

        switch (held.kind()) {
            .pat_type => return rust_parameter(held),
            .receiver => return rust_receiver_parameter(held),
            else => {},
        }
    }

    return null;
}

fn rust_parameter(held: rust.View) View.Parameter {
    assert(held.node < held.tree.count());

    const pattern = rust_pattern(held);
    const node = wrap(.rust, held);
    const whole = node.span();
    const offset = if (pattern) |found| found.span().offset else whole.offset;
    const type_of = wrap_optional(.rust, rust_type_child(held));

    assert(offset >= whole.offset);
    assert(offset <= whole.end());

    return .{
        .default = null,
        .group = held.node,
        .name = rust_pattern_name(pattern),
        .node = node,
        .span = .{ .length = whole.end() - offset, .offset = offset },
        .type_of = type_of,
        .type_span = if (type_of) |found| found.span() else null,
        .variadic = false,
    };
}

fn rust_pattern(held: rust.View) ?rust.View {
    assert(held.kind() == .pat_type);

    var found = held.children();

    for (0..child_count_max) |_| {
        const child = found.next() orelse return null;
        if (child.kind() == .attribute) continue;

        assert(child.node > held.node);

        return child;
    }

    return null;
}

fn rust_pattern_name(pattern: ?rust.View) ?u32 {
    if (pattern == null) return null;

    const candidate = pattern.?;

    assert(candidate.node < candidate.tree.count());

    if (candidate.kind() != .pat_ident) return null;

    const ident = candidate.child_first_of(.ident) orelse return null;

    assert(ident.node > candidate.node);
    assert(ident.kind() == .ident);

    return position_first(ident);
}

fn rust_receiver_parameter(held: rust.View) View.Parameter {
    assert(held.kind() == .receiver);

    const node = wrap(.rust, held);
    var name: ?u32 = null;
    var position = held.token_end();

    for (0..held.tokens.len + 1) |_| {
        if (position <= held.token_start()) break;

        position -= 1;

        switch (held.token_kind(position)) {
            .ident, .self_lower => {
                name = position;

                break;
            },
            else => {},
        }
    }

    if (name) |found| assert(found < held.token_end());

    return .{
        .default = null,
        .group = node.index(),
        .name = name,
        .node = node,
        .span = node.span(),
        .type_of = null,
        .type_span = null,
        .variadic = false,
    };
}

fn rust_receiver(held: rust.View) ?rust.View {
    if (held.kind() != .expr_method_call) return null;

    const found = held.child_first() orelse return null;

    assert(found.node > held.node);
    assert(found.tree == held.tree);

    return found;
}

fn rust_receiver_of(held: rust.View) ?rust.View {
    assert(held.node < held.tree.count());

    const function = held.as_function() orelse return null;
    const signature = function.signature() orelse return null;
    const found = signature.child_first_of(.receiver) orelse return null;

    assert(found.node > signature.node);
    assert(signature.node > held.node);

    return found;
}

fn rust_returns(held: rust.View) ?rust.View {
    assert(held.node < held.tree.count());

    const function = held.as_function() orelse return null;
    const signature = function.signature() orelse return null;
    const arrow = signature.token_first(.r_arrow) orelse return null;
    var found = signature.children();

    assert(arrow < signature.token_end());

    for (0..child_count_max) |_| {
        const child = found.next() orelse return null;

        assert(child.node > signature.node);

        if (child.token_start() > arrow) return child;
    }

    return null;
}

fn rust_literal(held: rust.View) View.Literal {
    assert(held.node < held.tree.count());

    const constant = held.as_constant() orelse return .other;

    const class: View.Literal = switch (constant.literal_class()) {
        .boolean => .boolean,
        .byte, .character => .character,
        .byte_string, .c_string => .bytes,
        .float, .integer => .number,
        .text => .text,
    };

    assert(class != .other);
    assert(class != .nil);

    return class;
}

fn rust_type_child(held: rust.View) ?rust.View {
    assert(held.kind() == .pat_type);

    var found = held.children();

    for (0..child_count_max) |_| {
        const child = found.next() orelse return null;
        if (child.kind().category() != .type) continue;

        assert(child.node > held.node);

        return child;
    }

    return null;
}

fn rust_use_glob(held: rust.View) bool {
    assert(held.node < held.tree.count());

    var pending: [segment_count_max]u32 = undefined;
    var pending_count: u32 = 1;

    pending[0] = held.node;

    for (0..child_count_max) |_| {
        if (pending_count == 0) break;

        pending_count -= 1;

        const current = held.at(pending[pending_count]);
        if (current.kind() == .use_glob) return true;

        var found = current.children();

        for (0..child_count_max) |_| {
            const child = found.next() orelse break;

            if (pending_count < segment_count_max) {
                pending[pending_count] = child.node;
                pending_count += 1;
            }
        }

        assert(pending_count <= segment_count_max);
    }

    assert(pending_count <= segment_count_max);

    return false;
}

fn rust_use_segments(held: rust.View, out: *ArrayType(Span)) error{Truncated}!void {
    assert(held.node < held.tree.count());

    const use = held.as_use() orelse return;
    var current = use.tree() orelse return;

    assert(out.count() == 0);

    for (0..segment_count_max) |_| {
        switch (current.kind()) {
            .use_name, .use_path, .use_rename => {},
            else => return,
        }

        const name = current.child_first_of(.ident) orelse return;

        try segment_push(out, name.span());

        assert(out.count() <= segment_count_max);

        current = rust_use_next(current) orelse return;
    }
}

fn rust_use_next(current: rust.View) ?rust.View {
    assert(current.node < current.tree.count());

    var found = current.children();

    for (0..child_count_max) |_| {
        const child = found.next() orelse return null;
        if (child.kind() == .ident) continue;

        assert(child.node > current.node);

        return child;
    }

    return null;
}

fn zig_container_name(held: zig.View) ?u32 {
    assert(held.node < held.tree.count());

    const above = held.parent() orelse return null;
    const declaration = above.as_declaration() orelse return null;

    assert(above.node < held.node);
    assert(above.kind() == .var_decl);

    return declaration.name_token();
}

fn zig_receiver(held: zig.View) ?zig.View {
    assert(held.node < held.tree.count());

    const call = held.as_call() orelse return null;
    const callee = call.callee() orelse return null;

    assert(callee.node > held.node);

    if (callee.kind() != .field_access) return null;

    assert(callee.kind() == .field_access);

    return callee.child_first();
}

fn zig_parameters(held: zig.View) ParametersInner {
    assert(held.node < held.tree.count());

    const function = held.as_function() orelse return .empty;
    const prototype = function.prototype() orelse return .empty;
    const open = prototype.token_first(.paren_open) orelse return .empty;
    const close = prototype.token_first(.paren_close) orelse close_none;

    assert(prototype.node >= held.node);
    assert(open < close);

    return .{ .zig = .{ .close = close, .cursor = open + 1, .prototype = prototype } };
}

fn zig_parameter_next(state: *ZigParameters) ?View.Parameter {
    if (state.cursor >= state.close) return null;

    const prototype = state.prototype;
    const start = state.cursor;
    const end = zig_parameter_end(prototype, start, state.close);

    state.cursor = end +| 1;

    const name = zig_parameter_name(prototype, start, end);
    const type_of = zig_parameter_type(prototype, start, end);

    if (name == null) {
        if (type_of == null) {
            if (end == state.close) return null;
        }
    }

    assert(start <= end);
    assert(end <= state.close);

    const type_span = if (type_of) |held| held.span() else zig_anytype_span(prototype, start, end);
    const node = if (type_of) |held| wrap(.zig, held) else wrap(.zig, prototype);

    return .{
        .default = null,
        .group = name orelse start,
        .name = name,
        .node = node,
        .span = zig_parameter_span(prototype, name, type_span),
        .type_of = if (type_of) |held| wrap(.zig, held) else null,
        .type_span = type_span,
        .variadic = false,
    };
}

fn zig_anytype_span(prototype: zig.View, start: u32, end: u32) ?Span {
    assert(start <= end);
    assert(end <= prototype.tokens.len);

    for (start..end) |position| {
        switch (prototype.token_kind(@intCast(position))) {
            .anytype_keyword, .dot_dot_dot => {
                return prototype.token_at(@intCast(position)).span();
            },
            else => {},
        }
    }

    return null;
}

fn zig_parameter_end(prototype: zig.View, start: u32, close: u32) u32 {
    assert(prototype.node < prototype.tree.count());

    var found = prototype.positions();

    assert(start < close);

    for (0..prototype.tokens.len + 1) |_| {
        const position = found.next() orelse break;
        if (position <= start) continue;
        if (position >= close) break;

        if (prototype.token_kind(position) == .comma) {
            assert(position > start);

            return position;
        }
    }

    return close;
}

fn zig_parameter_name(prototype: zig.View, start: u32, end: u32) ?u32 {
    assert(prototype.node < prototype.tree.count());

    var found = prototype.positions();
    var name: ?u32 = null;

    assert(start <= end);

    for (0..prototype.tokens.len + 1) |_| {
        const position = found.next() orelse break;
        if (position < start) continue;
        if (position >= end) continue;
        if (prototype.token_kind(position) != .identifier) continue;
        if (position + 1 >= prototype.raw.len) continue;

        if (prototype.token_kind(position + 1) == .colon) name = position;
    }

    if (name) |position| assert(position >= start);

    return name;
}

fn zig_parameter_span(prototype: zig.View, name: ?u32, type_span: ?Span) Span {
    assert(prototype.node < prototype.tree.count());
    if (name) |held| assert(held < std.math.maxInt(u32));
    if (type_span) |held| assert(held.length <= std.math.maxInt(u32) - held.offset);

    const start: Span = if (name) |position|
        prototype.token_at(position).span()
    else
        type_span orelse wrap(.zig, prototype).span();

    const tail = if (type_span) |held| held.end() else start.end();
    const end = @max(tail, start.end());

    assert(end >= start.offset);
    assert(end >= start.end());

    return .{ .length = end - start.offset, .offset = start.offset };
}

fn zig_parameter_type(prototype: zig.View, start: u32, end: u32) ?zig.View {
    assert(prototype.node < prototype.tree.count());

    var found = prototype.children();

    assert(start <= end);

    for (0..child_count_max) |_| {
        const child = found.next() orelse return null;
        if (child.token_start() < start) continue;
        if (child.token_start() >= end) continue;

        assert(child.node > prototype.node);

        return child;
    }

    return null;
}

fn zig_returns_span(prototype: zig.View, close: u32, node_start: u32, span: Span) Span {
    assert(prototype.node < prototype.tree.count());
    assert(span.length <= std.math.maxInt(u32) - span.offset);

    var found = prototype.positions();
    var widened = span;

    assert(close < node_start);

    for (0..prototype.tokens.len + 1) |_| {
        const position = found.next() orelse break;
        if (position <= close) continue;
        if (position >= node_start) continue;

        switch (prototype.token_kind(position)) {
            .bang, .question => {},
            else => continue,
        }

        const token = prototype.token_at(position);

        if (token.offset < widened.offset) {
            widened = .{ .length = widened.end() - token.offset, .offset = token.offset };
        }
    }

    assert(widened.end() == span.end());
    assert(widened.offset <= span.offset);

    return widened;
}

test View {
    const gpa = std.testing.allocator;
    const fronts = try gpa.create(Fronts);
    defer gpa.destroy(fronts);

    try fronts.init(gpa, &capacity_test, .initOne(.python), &.{});
    defer fronts.deinit(gpa);

    const source = "def greet(name, punctuation='!'):\n    return name + punctuation\n";
    const front = try fronts.parse(.of(.python), source);
    const node = front.nodes_of(.function)[0];
    const function = front.view(node).?.as_function().?;
    var parameters = function.parameters();

    try std.testing.expectEqual(View.Category.function, front.view(node).?.category());
    try std.testing.expectEqual(2, parameters.count());

    const first = parameters.next().?;

    try std.testing.expectEqualStrings("name", front.tokens()[first.name.?].text(source));
}

const capacity_test: Front.Capacity = .{
    .diagnostic_count_max = 1 << 6,
    .event_count_max = 1 << 12,
    .node_count_max = 1 << 10,
    .semantic = null,
    .tag_count_max = 1 << 6,
    .token_count_max = 1 << 10,
};
