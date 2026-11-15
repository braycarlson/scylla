const std = @import("std");
const assert = std.debug.assert;
const AnnotationScratch = @import("semantic.zig").AnnotationScratch;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const Binding = @import("semantic.zig").Semantic.Binding;
const EventsType = @import("../tree.zig").EventsType;
const Kind = @import("kind.zig").Kind;
const Parser = @import("parse.zig").Parser;
const PythonVersion = @import("stdlib.zig").PythonVersion;
const Semantic = @import("semantic.zig").Semantic;
const Span = @import("../../stdx/bounded/span.zig");
const Token = @import("../token.zig");
const Tokens = @import("../tokens.zig");
const TreeType = @import("../tree.zig").TreeType;
const View = @import("ast.zig").View;
const get = @import("semantic.zig").get;
const raw_of = @import("../raw.zig").raw_of;
const lex = @import("lex.zig").lex;
const literal = @import("literal.zig");
const reference_of = @import("semantic.zig").reference_of;
const scope_depth_max = @import("semantic.zig").scope_depth_max;
const walk = @import("../tree.zig").walk;
const walk_from = @import("../tree.zig").walk_from;
const Events = EventsType(Kind);
const Tree = TreeType(Kind);

pub const CheckError = struct {
    kind: CheckKind,
    span: Span,
};

const CheckKind = union(enum) {
    await_outside_async,
    await_outside_function,
    duplicate_parameter,
    except_not_last,
    future_import_late,
    global_after_use,
    irrefutable_case_not_last,
    nonlocal_at_module,
    nonlocal_without_binding,
    return_outside_function,
    starred_multiple,
    starred_target_alone,
    target_assign_invalid,
    target_delete_invalid,
    unsupported: Feature,
    walrus_in_comprehension_iterable,
    walrus_rebinds_comprehension_variable,
    yield_outside_function,

    pub fn code(kind: CheckKind) []const u8 {
        const text: []const u8 = switch (kind) {
            .await_outside_async => "PLE1142",
            .await_outside_function, .yield_outside_function => "F704",
            .except_not_last => "F707",
            .future_import_late => "F404",
            .global_after_use => "PLE0118",
            .nonlocal_without_binding => "PLE0117",
            .return_outside_function => "F706",
            .starred_multiple => "F622",
            .duplicate_parameter,
            .irrefutable_case_not_last,
            .nonlocal_at_module,
            .starred_target_alone,
            .target_assign_invalid,
            .target_delete_invalid,
            .unsupported,
            .walrus_in_comprehension_iterable,
            .walrus_rebinds_comprehension_variable,
            => "invalid-syntax",
        };

        assert(text.len > 0);
        if (kind == .unsupported) assert(std.mem.eql(u8, text, "invalid-syntax"));

        return text;
    }

    pub fn message(kind: CheckKind) []const u8 {
        const text: []const u8 = switch (kind) {
            .await_outside_async => "`await` should be used within an async function",
            .await_outside_function => "`await` statement outside of a function",
            .duplicate_parameter => "Duplicate parameter",
            .except_not_last => "An `except` block as not the last exception handler",
            .future_import_late => "`from __future__` imports must occur at the beginning " ++
                "of the file",
            .global_after_use => "Name is used prior to global declaration",
            .irrefutable_case_not_last => "wildcard makes remaining patterns unreachable",
            .nonlocal_at_module => "nonlocal declaration not allowed at module level",
            .nonlocal_without_binding => "Nonlocal name found without binding",
            .return_outside_function => "`return` statement outside of a function/method",
            .starred_multiple => "Two starred expressions in assignment",
            .starred_target_alone => "starred assignment target must be in a list or tuple",
            .target_assign_invalid => "Invalid assignment target",
            .target_delete_invalid => "Invalid delete target",
            .unsupported => |feature| feature.message(),
            .walrus_in_comprehension_iterable => "assignment expression cannot be used in a " ++
                "comprehension iterable expression",
            .walrus_rebinds_comprehension_variable => "assignment expression cannot rebind " ++
                "comprehension variable",
            .yield_outside_function => "`yield` statement outside of a function",
        };

        assert(text.len > 0);
        assert(text[text.len - 1] != '.');

        return text;
    }
};

pub const Completion = enum {
    complete,
    errors_full,
    frames_full,
    scratch_full,
    target_stack_full,
};

const Feature = enum {
    except_star,
    match_statement,
    parenthesized_with_items,
    template_string,
    type_alias_statement,
    type_parameter_defaults,
    type_parameters,
    unparenthesized_except_tuple,

    pub fn message(feature: Feature) []const u8 {
        const text: []const u8 = switch (feature) {
            .except_star => "Cannot use `except*`",
            .match_statement => "Cannot use `match` statement",
            .parenthesized_with_items => "Cannot use parentheses within a `with` statement",
            .template_string => "Cannot use t-strings",
            .type_alias_statement => "Cannot use `type` alias statement",
            .type_parameter_defaults => "Cannot set default type for a type parameter",
            .type_parameters => "Cannot use type parameter lists",
            .unparenthesized_except_tuple => "Multiple exception types must be parenthesized",
        };

        assert(text.len > 0);
        assert(std.ascii.isUpper(text[0]));

        return text;
    }

    pub fn name(feature: Feature) []const u8 {
        const text: []const u8 = switch (feature) {
            .except_star => "`except*`",
            .match_statement => "`match` statement",
            .parenthesized_with_items => "parentheses within a `with` statement",
            .template_string => "t-strings",
            .type_alias_statement => "`type` alias statement",
            .type_parameter_defaults => "type parameter defaults",
            .type_parameters => "type parameter lists",
            .unparenthesized_except_tuple => "unparenthesized except tuples",
        };

        assert(text.len > 0);
        assert(text.len < feature.message().len);

        return text;
    }

    fn since(feature: Feature) PythonVersion {
        const version: PythonVersion = switch (feature) {
            .parenthesized_with_items => .py39,
            .match_statement => .py310,
            .except_star => .py311,
            .type_alias_statement, .type_parameters => .py312,
            .type_parameter_defaults => .py313,
            .template_string, .unparenthesized_except_tuple => .py314,
        };

        assert(version.at_least(.py39));
        if (feature == .match_statement) assert(!PythonVersion.py39.at_least(version));

        return version;
    }
};

pub const Input = struct {
    raw: []const Kind,
    semantic: *const Semantic,
    source: []const u8,
    tokens: []const Token,
    tree: *const Tree,
    version: PythonVersion,
};

const Checker = struct {
    completion: Completion,
    depth: u32,
    errors: *ArrayType(CheckError),
    frames: [scope_depth_max]Frame,
    future_allowed: bool,
    raw: []const Kind,
    scratch: *ArrayType(Span),
    semantic: *const Semantic,
    source: []const u8,
    target_stack: [target_stack_max]u32,
    tokens: []const Token,
    tree: *const Tree,
    version: PythonVersion,

    fn run(checker: *Checker) void {
        assert(checker.depth == 0);
        assert(checker.tree.count() > 0);

        checker.frames[0] = .{ .asynchronous = false, .kind = .module, .node = 0 };
        checker.depth = 1;
        var steps = walk(Tree, checker.tree);

        for (0..steps.step_max) |_| {
            const step = steps.next() orelse break;

            switch (step) {
                .enter => |node| checker.enter(node),
                .leave => |node| checker.leave(node),
            }
        }

        assert(steps.node == null);
        assert(checker.depth == 1);
        assert(checker.frames[0].kind == .module);
    }

    fn enter(checker: *Checker, node: u32) void {
        assert(node < none);

        const kind = checker.kind_of(node);

        assert(checker.depth >= 1);
        assert(checker.depth <= scope_depth_max);

        checker.frame_open(node, kind);
        checker.future_track(node, kind);
        checker.flow(node, kind);
        checker.declarations(node, kind);
        checker.targets(node, kind);
        checker.clauses(node, kind);
        checker.parameters(node, kind);
        checker.walrus(node, kind);
        checker.gate(node, kind);
    }

    fn leave(checker: *Checker, node: u32) void {
        assert(checker.depth >= 1);
        assert(node < checker.tree.count());

        if (checker.depth > 1) {
            if (checker.frames[checker.depth - 1].node == node) checker.depth -= 1;
        }
    }

    fn frame_open(checker: *Checker, node: u32, kind: Kind) void {
        assert(node < none);
        assert(kind.is_node());

        if (!opens_frame(kind)) return;

        if (checker.depth >= scope_depth_max) {
            checker.overrun(.frames_full);

            return;
        }

        checker.frames[checker.depth] = .{
            .asynchronous = kind == .async_function_def,
            .kind = frame_kind_of(kind),
            .node = node,
        };

        checker.depth += 1;

        assert(checker.depth > 1);
        assert(checker.depth <= scope_depth_max);
    }

    fn enclosing(checker: *const Checker) Frame {
        var index = checker.depth;

        assert(index >= 1);
        assert(index <= scope_depth_max);

        for (0..scope_depth_max) |_| {
            if (index <= 1) break;

            const held = checker.frames[index - 1];
            if (held.kind != .comprehension) return held;

            index -= 1;
        }

        assert(checker.frames[0].kind == .module);

        return checker.frames[0];
    }

    fn flow(checker: *Checker, node: u32, kind: Kind) void {
        assert(checker.kind_of(node) == kind);

        switch (kind) {
            .@"return" => return checker.flow_report(node, .return_outside_function),
            .yield, .yield_from => return checker.flow_report(node, .yield_outside_function),
            .async_for, .async_with, .await => {},
            else => return,
        }

        if (kind == .await) checker.flow_report(node, .await_outside_function);

        const held = checker.enclosing();
        const asynchronous = held.kind == .function and held.asynchronous;

        if (held.asynchronous) assert(held.kind == .function);

        if (!asynchronous) checker.report(.await_outside_async, checker.span_of(node));
    }

    fn flow_report(checker: *Checker, node: u32, kind: CheckKind) void {
        assert(node < checker.tree.count());
        assert(kind != .unsupported);

        if (checker.enclosing().kind == .function) return;

        checker.report(kind, checker.span_of(node));
    }

    fn declarations(checker: *Checker, node: u32, kind: Kind) void {
        assert(checker.kind_of(node) == kind);
        assert(checker.depth >= 1);

        if (kind == .global) return checker.global_uses(node);
        if (kind != .nonlocal) return;

        if (checker.frames[checker.depth - 1].kind == .module) {
            checker.report(.nonlocal_at_module, checker.span_of(node));

            return;
        }

        checker.nonlocal_bindings(node);
    }

    fn global_uses(checker: *Checker, node: u32) void {
        const bindings = checker.semantic.binding_slice();

        assert(checker.kind_of(node) == .global);
        assert(bindings.len <= std.math.maxInt(u32));

        for (bindings) |held| {
            if (held.node != node) continue;
            if (held.kind != .global) continue;

            const name = held.name.text(checker.source);

            checker.global_references(node, held.scope, name);
            checker.global_bindings(node, held.scope, name);
        }
    }

    fn global_references(checker: *Checker, node: u32, scope: u32, name: []const u8) void {
        assert(name.len <= std.math.maxInt(u32));

        const references = checker.semantic.reference_slice();

        assert(scope < checker.semantic.scope_slice().len);
        assert(node < checker.tree.count());

        for (references) |reference| {
            if (reference.scope != scope) continue;
            if (reference.node >= node) continue;

            if (std.mem.eql(u8, reference.name.text(checker.source), name)) {
                checker.report(.global_after_use, reference.name);
            }
        }
    }

    fn global_bindings(checker: *Checker, node: u32, scope: u32, name: []const u8) void {
        assert(name.len <= std.math.maxInt(u32));

        const bindings = checker.semantic.binding_slice();

        assert(scope < checker.semantic.scope_slice().len);
        assert(node < checker.tree.count());

        for (bindings) |*earlier| {
            if (!checker.global_use_binding(earlier, scope, node, name)) continue;

            checker.report(.global_after_use, earlier.name);
        }
    }

    fn global_use_binding(
        checker: *const Checker,
        binding: *const Binding,
        scope: u32,
        node: u32,
        name: []const u8,
    ) bool {
        assert(binding.scope < checker.semantic.scope_slice().len);
        assert(scope < checker.semantic.scope_slice().len);

        if (binding.scope != scope) return false;
        if (binding.node >= node) return false;
        if (binding.kind == .global) return false;
        if (binding.kind == .nonlocal) return false;
        if (!std.mem.eql(u8, binding.name.text(checker.source), name)) return false;
        return reference_of(checker.semantic, binding.node) == null;
    }

    fn nonlocal_bindings(checker: *Checker, node: u32) void {
        const bindings = checker.semantic.binding_slice();

        assert(checker.kind_of(node) == .nonlocal);
        assert(checker.depth > 1);

        for (bindings) |held| {
            if (held.node != node) continue;
            if (held.kind != .nonlocal) continue;
            if (checker.nonlocal_bound(held.scope, held.name.text(checker.source))) continue;

            checker.report(.nonlocal_without_binding, held.name);
        }
    }

    fn nonlocal_bound(checker: *const Checker, scope: u32, name: []const u8) bool {
        assert(name.len <= std.math.maxInt(u32));

        const scopes = checker.semantic.scope_slice();

        assert(scope < scopes.len);
        assert(scopes[0].kind == .module);

        var held = scopes[scope].parent;

        for (0..scope_depth_max) |_| {
            if (held == none) return false;

            const outer = scopes[held];

            switch (outer.kind) {
                .comprehension, .function, .lambda => {
                    const found = checker.semantic.binding_newest(checker.source, held, name, null);
                    const binding = get(checker.semantic, found);

                    if (binding) |bound| {
                        if (bound.kind.binds()) return true;
                    }
                },
                else => {},
            }

            if (outer.kind == .module) return false;

            held = outer.parent;
        }

        return false;
    }

    fn future_track(checker: *Checker, node: u32, kind: Kind) void {
        assert(checker.kind_of(node) == kind);

        if (kind == .import_from) {
            if (checker.is_future_import(node)) {
                if (!checker.future_allowed) {
                    checker.report(.future_import_late, checker.span_of(node));
                }

                return;
            }
        }

        if (node == 0) return;

        const parent = checker.tree.parent_of(node) orelse return;
        if (parent != 0) return;

        const first = checker.tree.child_first_of(0) orelse none;

        if (first == node) {
            if (checker.is_docstring(node)) return;
        }

        checker.future_allowed = false;

        assert(node > 0);
    }

    fn is_future_import(checker: *const Checker, node: u32) bool {
        assert(node < none);

        const held = checker.view(node);
        const import = held.as_import() orelse return false;

        assert(held.kind() == .import_from);

        if (import.level() != 0) return false;

        var positions = held.positions();
        var found = false;

        for (0..checker.tokens.len + 1) |_| {
            const position = positions.next() orelse break;
            const kind = held.token_kind(position);
            if (kind == .import_keyword) break;
            if (kind != .identifier) continue;
            if (found) return false;

            const text = held.token_at(position).text(checker.source);
            if (!std.mem.eql(u8, text, "__future__")) return false;

            found = true;
        }

        if (found) assert(import.level() == 0);

        return found;
    }

    fn is_docstring(checker: *const Checker, node: u32) bool {
        if (checker.kind_of(node) != .expr) return false;

        const child = checker.view(node).child_first() orelse return false;
        if (child.kind() != .constant) return false;

        const held = checker.tree.at(child.index());

        assert(held.token_start <= held.token_end);
        assert(held.token_end <= checker.raw.len);

        if (held.token_end <= held.token_start) return false;

        const kind = checker.raw[held.token_start];
        return kind == .string_format or kind == .string_plain;
    }

    fn targets(checker: *Checker, node: u32, kind: Kind) void {
        assert(node < none);

        const held = checker.view(node);
        var children = held.children();

        assert(held.kind() == kind);

        if (kind == .delete) {
            for (0..checker.tree.count()) |_| {
                const child = children.next() orelse break;

                checker.target(child.index(), .target_delete_invalid);
            }

            return;
        }

        if (binds_first_child(kind)) {
            const target_first = held.child_first() orelse return;

            checker.assign_target(target_first.index(), target_first.kind());

            return;
        }

        if (kind == .with_item) {
            _ = children.next() orelse return;

            for (0..checker.tree.count()) |_| {
                const child = children.next() orelse break;

                checker.assign_target(child.index(), child.kind());
            }

            return;
        }

        if (kind != .assign) return;

        const assign = held.as_assign() orelse return;
        var found = assign.targets();

        for (0..checker.tree.count()) |_| {
            const child = found.next() orelse break;

            checker.assign_target(child.index(), child.kind());
        }

        assert(found.remaining == 0);
    }

    fn assign_target(checker: *Checker, node: u32, kind: Kind) void {
        assert(checker.kind_of(node) == kind);
        assert(node > 0);

        if (kind == .starred) {
            checker.report(.starred_target_alone, checker.span_of(node));

            return;
        }

        checker.target(node, .target_assign_invalid);
    }

    fn target(checker: *Checker, node: u32, kind: CheckKind) void {
        var depth: u32 = 1;

        assert(kind == .target_assign_invalid or kind == .target_delete_invalid);
        assert(node < checker.tree.count());

        checker.target_stack[0] = node;

        for (0..checker.tree.count() + 1) |_| {
            if (depth == 0) return;

            depth -= 1;
            const held = checker.target_stack[depth];
            if (!checker.target_holds(held, kind)) continue;

            depth = checker.target_push(held, depth);
        }

        unreachable;
    }

    fn target_holds(checker: *Checker, node: u32, kind: CheckKind) bool {
        assert(node < none);

        const form = checker.kind_of(node);

        assert(kind == .target_assign_invalid or kind == .target_delete_invalid);

        switch (form) {
            .attribute, .name_node, .subscript => return false,
            else => {},
        }

        const deleted = form == .starred and kind == .target_delete_invalid;
        const invalid = !holds_targets(form) or deleted;

        if (invalid) {
            checker.report(kind, checker.span_of(node));

            return false;
        }

        if (kind == .target_assign_invalid) checker.starred(node);

        assert(holds_targets(form));

        return true;
    }

    fn target_push(checker: *Checker, node: u32, depth: u32) u32 {
        assert(node < none);
        assert(depth < target_stack_max);

        var children = checker.view(node).children();
        var held = depth;

        assert(holds_targets(checker.kind_of(node)));

        for (0..checker.tree.count()) |_| {
            const child = children.next() orelse break;

            if (held == target_stack_max) {
                checker.overrun(.target_stack_full);

                return 0;
            }

            checker.target_stack[held] = child.index();
            held += 1;
        }

        assert(held <= target_stack_max);

        return held;
    }

    fn starred(checker: *Checker, node: u32) void {
        assert(node < none);

        const held = checker.view(node);

        assert(holds_targets(held.kind()));

        switch (held.kind()) {
            .list, .tuple => {},
            else => return,
        }

        const found = held.children_of(.starred).count();

        assert(found < checker.tree.count());

        if (found > 1) checker.report(.starred_multiple, checker.span_of(node));
    }

    fn clauses(checker: *Checker, node: u32, kind: Kind) void {
        assert(checker.kind_of(node) == kind);
        assert(node < checker.tree.count());

        switch (kind) {
            .@"try", .try_star => checker.handlers(node),
            .match => checker.cases(node),
            else => {},
        }
    }

    fn handlers(checker: *Checker, node: u32) void {
        assert(node < none);

        const held = checker.view(node);
        var found = held.children_of(.except_handler);
        const handler_final = found.last() orelse return;

        assert(handler_final.index() > node);

        for (0..checker.tree.count()) |_| {
            const handler = found.next() orelse break;
            if (handler.index() == handler_final.index()) break;

            const blocks = handler.children_of(.block).count();
            const children = handler.children().count();

            assert(blocks <= children);

            if (blocks == children) {
                checker.report(.except_not_last, checker.span_of(handler.index()));
            }
        }
    }

    fn cases(checker: *Checker, node: u32) void {
        assert(node < none);

        const held = checker.view(node);
        var found = held.children_of(.match_case);
        const case_final = found.last() orelse return;

        assert(case_final.index() > node);

        for (0..checker.tree.count()) |_| {
            const case = found.next() orelse break;
            if (case.index() == case_final.index()) break;
            if (case.children().count() > 2) continue;

            const pattern = case.child_first() orelse continue;

            assert(pattern.index() > case.index());

            if (irrefutable(pattern)) {
                checker.report(.irrefutable_case_not_last, checker.span_of(pattern.index()));
            }
        }
    }

    fn parameters(checker: *Checker, node: u32, kind: Kind) void {
        assert(checker.kind_of(node) == kind);

        switch (kind) {
            .arguments, .lambda => {},
            else => return,
        }

        var found = checker.view(node).children_of(.arg);

        checker.scratch.clear();

        for (0..checker.tree.count()) |_| {
            const child = found.next() orelse break;
            const argument = child.as_argument() orelse continue;
            const position = argument.name_token() orelse continue;
            const name = child.token_at(position).span();

            if (checker.seen(name)) {
                checker.report(.duplicate_parameter, name);

                continue;
            }

            if (checker.scratch.full()) {
                checker.overrun(.scratch_full);

                return;
            }

            checker.scratch.push(name);
        }

        assert(checker.scratch.count() <= checker.scratch.capacity());
    }

    fn seen(checker: *const Checker, name: Span) bool {
        assert(name.end() <= checker.source.len);

        const text = name.text(checker.source);

        assert(checker.scratch.count() <= checker.scratch.capacity());

        for (checker.scratch.const_slice()) |held| {
            if (std.mem.eql(u8, held.text(checker.source), text)) return true;
        }

        return false;
    }

    fn walrus(checker: *Checker, node: u32, kind: Kind) void {
        assert(checker.kind_of(node) == kind);
        assert(node < checker.tree.count());

        if (kind == .comprehension) return checker.walrus_iterable(node);
        if (!opens_comprehension(kind)) return;

        checker.walrus_rebind(node);
    }

    fn walrus_iterable(checker: *Checker, node: u32) void {
        assert(node < none);

        const iterable = checker.view(node).child_at(1) orelse return;
        var steps = walk_from(Tree, checker.tree, iterable.index());

        assert(iterable.index() > node);

        for (0..steps.step_max) |_| {
            const step = steps.next() orelse break;

            const held = switch (step) {
                .enter => |entered| entered,
                .leave => continue,
            };

            if (checker.kind_of(held) == .named_expr) {
                checker.report(.walrus_in_comprehension_iterable, checker.span_of(held));
            }
        }

        assert(steps.node == null);
    }

    fn walrus_rebind(checker: *Checker, node: u32) void {
        assert(opens_comprehension(checker.kind_of(node)));

        checker.comprehension_targets(node);

        var steps = walk_from(Tree, checker.tree, node);

        for (0..steps.step_max) |_| {
            const step = steps.next() orelse break;

            const held = switch (step) {
                .enter => |entered| entered,
                .leave => continue,
            };

            if (checker.kind_of(held) != .named_expr) continue;

            const target_first = checker.view(held).child_first() orelse continue;

            if (checker.seen(target_first.span())) {
                checker.report(.walrus_rebinds_comprehension_variable, checker.span_of(held));
            }
        }

        assert(steps.node == null);
    }

    fn comprehension_targets(checker: *Checker, node: u32) void {
        assert(node < none);

        var clauses_found = checker.view(node).children_of(.comprehension);

        assert(opens_comprehension(checker.kind_of(node)));

        checker.scratch.clear();

        for (0..checker.tree.count()) |_| {
            const clause = clauses_found.next() orelse break;
            const target_first = clause.child_first() orelse continue;
            var steps = walk_from(Tree, checker.tree, target_first.index());

            for (0..steps.step_max) |_| {
                const step = steps.next() orelse break;

                const held = switch (step) {
                    .enter => |entered| entered,
                    .leave => continue,
                };

                if (checker.kind_of(held) != .name_node) continue;

                if (checker.scratch.full()) {
                    checker.overrun(.scratch_full);

                    return;
                }

                checker.scratch.push(checker.span_of(held));
            }
        }

        assert(checker.scratch.count() <= checker.scratch.capacity());
    }

    fn gate(checker: *Checker, node: u32, kind: Kind) void {
        assert(checker.kind_of(node) == kind);
        assert(node < checker.tree.count());

        switch (kind) {
            .match => checker.unsupported(.match_statement, checker.span_of(node)),
            .type_alias => checker.unsupported(.type_alias_statement, checker.span_of(node)),
            .type_params => checker.unsupported(.type_parameters, checker.span_of(node)),
            .except_handler => {
                checker.gate_handler(node);
                checker.gate_except_tuple(node);
            },
            .param_spec, .type_var, .type_var_tuple => checker.gate_type_parameter(node),
            .async_with, .with => checker.gate_with(node),
            .constant, .joined_str => checker.gate_string(node),
            else => {},
        }
    }

    fn gate_handler(checker: *Checker, node: u32) void {
        assert(node < none);

        const parent = checker.tree.parent_of(node) orelse return;

        assert(parent < node);
        assert(checker.kind_of(node) == .except_handler);

        if (checker.kind_of(parent) != .try_star) return;

        const held = checker.view(node);
        const position = held.token_first(.star) orelse return;

        checker.unsupported(.except_star, held.token_at(position).span());
    }

    fn gate_type_parameter(checker: *Checker, node: u32) void {
        assert(node < none);

        const held = checker.view(node);
        const position = held.token_first(.equal) orelse return;

        assert(position >= held.token_start());
        assert(position < held.token_end());

        checker.unsupported(.type_parameter_defaults, held.token_at(position).span());
    }

    fn gate_except_tuple(checker: *Checker, node: u32) void {
        assert(node < none);

        const held = checker.view(node).child_first_of(.tuple) orelse return;
        const span = held.span();

        assert(held.index() > node);
        assert(span.end() <= checker.source.len);

        if (span.offset < checker.source.len) {
            if (checker.source[span.offset] == '(') return;
        }

        checker.unsupported(.unparenthesized_except_tuple, span);
    }

    fn gate_with(checker: *Checker, node: u32) void {
        assert(node < none);

        const held = checker.view(node);

        assert(held.kind() == .with or held.kind() == .async_with);

        if (held.children_of(.with_item).count() < 2) return;

        const position = held.token_first(.paren_open) orelse return;

        assert(position >= held.token_start());

        checker.unsupported(.parenthesized_with_items, held.token_at(position).span());
    }

    fn gate_string(checker: *Checker, node: u32) void {
        assert(node < none);

        const held = checker.view(node);
        var positions = held.positions();

        assert(held.kind() == .constant or held.kind() == .joined_str);

        for (0..checker.tokens.len + 1) |_| {
            const position = positions.next() orelse break;

            switch (held.token_kind(position)) {
                .f_string_start, .string_bytes, .string_format, .string_plain => {},
                else => continue,
            }

            const token = held.token_at(position);
            if (!literal.prefix_of(token.text(checker.source)).template) continue;

            checker.unsupported(.template_string, token.span());
        }

        assert(positions.position >= positions.limit);
    }

    fn unsupported(checker: *Checker, feature: Feature, span: Span) void {
        assert(span.end() <= checker.source.len);
        assert(feature.since().at_least(.py39));

        if (checker.version.at_least(feature.since())) return;

        checker.report(.{ .unsupported = feature }, span);
    }

    fn report(checker: *Checker, kind: CheckKind, span: Span) void {
        assert(span.end() <= checker.source.len);
        assert(checker.errors.count() <= checker.errors.capacity());

        if (checker.errors.full()) {
            checker.overrun(.errors_full);

            return;
        }

        checker.errors.push(.{ .kind = kind, .span = span });
    }

    fn overrun(checker: *Checker, completion: Completion) void {
        assert(completion != .complete);

        if (checker.completion == .complete) checker.completion = completion;

        assert(checker.completion != .complete);
    }

    fn kind_of(checker: *const Checker, node: u32) Kind {
        assert(node < checker.tree.count());

        const kind = checker.tree.kind_at(node);

        assert(kind.is_node());

        return kind;
    }

    fn span_of(checker: *const Checker, node: u32) Span {
        assert(node < checker.tree.count());

        const span = checker.tree.at(node).span(Token, checker.tokens);

        assert(span.end() <= checker.source.len);

        return span;
    }

    fn view(checker: *const Checker, node: u32) View {
        assert(node < checker.tree.count());
        assert(checker.tokens.len == checker.raw.len);

        return View.init(checker.tree, checker.tokens, checker.raw, node);
    }
};

const Frame = struct {
    asynchronous: bool,
    kind: FrameKind,
    node: u32,
};

const FrameKind = enum {
    class,
    comprehension,
    function,
    module,
};

pub const error_count_max_default: u32 = 1 << 10;
const none: u32 = std.math.maxInt(u32);
const target_stack_max: u32 = 1 << 8;

comptime {
    assert(std.math.isPowerOfTwo(error_count_max_default));
    assert(std.math.isPowerOfTwo(target_stack_max));
    assert(@sizeOf(CheckError) <= 16);
    assert(@sizeOf(Frame) <= 8);
}

pub fn check(
    input: *const Input,
    errors: *ArrayType(CheckError),
    scratch: *ArrayType(Span),
) Completion {
    assert(input.tokens.len == input.raw.len);
    assert(input.source.len <= std.math.maxInt(u32));

    errors.clear();
    scratch.clear();

    assert(errors.empty());

    if (input.tree.count() == 0) return .complete;

    var checker: Checker = .{
        .completion = .complete,
        .depth = 0,
        .errors = errors,
        .frames = @splat(.{ .asynchronous = false, .kind = .module, .node = none }),
        .future_allowed = true,
        .raw = input.raw,
        .scratch = scratch,
        .semantic = input.semantic,
        .source = input.source,
        .target_stack = @splat(none),
        .tokens = input.tokens,
        .tree = input.tree,
        .version = input.version,
    };

    checker.run();

    if (checker.completion == .errors_full) assert(errors.full());

    return checker.completion;
}

fn opens_comprehension(kind: Kind) bool {
    assert(kind.is_node());

    const result = switch (kind) {
        .dict_comp, .generator_exp, .list_comp, .set_comp => true,
        else => false,
    };

    if (result) assert(kind.is_node());
    if (result) assert(kind != .comprehension);

    return result;
}

fn opens_frame(kind: Kind) bool {
    assert(kind.is_node());

    const own = switch (kind) {
        .async_function_def, .class_def, .function_def, .lambda => true,
        else => false,
    };

    const result = own or opens_comprehension(kind);

    if (own) assert(!opens_comprehension(kind));
    if (result) assert(kind.is_node());

    return result;
}

fn frame_kind_of(kind: Kind) FrameKind {
    assert(opens_frame(kind));

    const frame: FrameKind = if (opens_comprehension(kind))
        .comprehension
    else if (kind == .class_def)
        .class
    else
        .function;

    assert(frame != .module);

    return frame;
}

fn binds_first_child(kind: Kind) bool {
    assert(kind.is_node());

    const result = switch (kind) {
        .async_for, .comprehension, .@"for" => true,
        else => false,
    };

    if (result) assert(kind.is_node());
    if (result) assert(!opens_frame(kind));

    return result;
}

fn holds_targets(kind: Kind) bool {
    assert(kind.is_node());

    const result = switch (kind) {
        .list, .parenthesized, .starred, .tuple => true,
        else => false,
    };

    if (result) assert(kind.is_node());
    if (result) assert(!opens_frame(kind));

    return result;
}

fn irrefutable(pattern: View) bool {
    assert(pattern.index() > 0);

    const kind = pattern.kind();

    assert(pattern.tree.parent_of(pattern.index()) != null);

    if (kind == .match_as) return pattern.child_first() == null;
    if (kind != .match_or) return false;

    var alternatives = pattern.children_of(.match_as);

    for (0..pattern.tree.count()) |_| {
        const held = alternatives.next() orelse break;
        if (held.child_first() == null) return true;
    }

    return false;
}

const Fixture = struct {
    errors: ArrayType(CheckError),
    events: Events,
    gpa: std.mem.Allocator,
    names: ArrayType(Span),
    parser: *Parser,
    raw: ArrayType(Kind),
    scratch: *AnnotationScratch,
    semantic: Semantic,
    source: []const u8,
    tokens: Tokens,
    tree: Tree,

    fn init(fixture: *Fixture, gpa: std.mem.Allocator, error_count_max: u32) !void {
        assert(error_count_max > 0);
        assert(error_count_max <= error_count_max_default);

        fixture.gpa = gpa;
        fixture.source = "";
        fixture.errors = try .init(gpa, error_count_max);
        errdefer fixture.errors.deinit(gpa);

        try fixture.events.init(gpa, fixture_event_count_max);
        errdefer fixture.events.deinit(gpa);

        fixture.names = try .init(gpa, error_count_max_default);
        errdefer fixture.names.deinit(gpa);

        fixture.parser = try gpa.create(Parser);
        errdefer gpa.destroy(fixture.parser);

        fixture.raw = try .init(gpa, fixture_token_count_max);
        errdefer fixture.raw.deinit(gpa);

        fixture.scratch = try gpa.create(AnnotationScratch);
        errdefer gpa.destroy(fixture.scratch);

        try fixture.scratch.init(gpa, &.{ .node_count_max = 1 << 8, .token_count_max = 1 << 8 });
        errdefer fixture.scratch.deinit(gpa);

        try fixture.semantic.init(gpa, &.{
            .binding_count_max = 1 << 10,
            .fact_count_max = 1 << 8,
            .reference_count_max = 1 << 12,
            .scope_count_max = 1 << 8,
        });

        errdefer fixture.semantic.deinit(gpa);

        fixture.tokens = try .init(gpa, fixture_token_count_max);
        errdefer fixture.tokens.deinit(gpa);

        fixture.tree = try .init(gpa, fixture_token_count_max, fixture_tree_error_count_max);
    }

    fn deinit(fixture: *Fixture) void {
        const gpa = fixture.gpa;

        assert(fixture.raw.capacity() == fixture_token_count_max);
        assert(fixture.errors.count() <= fixture.errors.capacity());

        fixture.tree.deinit(gpa);
        fixture.tokens.deinit(gpa);
        fixture.semantic.deinit(gpa);
        fixture.scratch.deinit(gpa);
        gpa.destroy(fixture.scratch);
        fixture.raw.deinit(gpa);
        gpa.destroy(fixture.parser);
        fixture.names.deinit(gpa);
        fixture.events.deinit(gpa);
        fixture.errors.deinit(gpa);
        fixture.* = undefined;
    }

    fn completion_of(fixture: *Fixture, source: []const u8, version: PythonVersion) !Completion {
        assert(source.len > 0);
        assert(source.len < fixture_token_count_max);

        fixture.source = source;

        fixture.tokens.clear();

        try lex(source, &fixture.tokens);
        try raw_of(Kind, fixture.tokens.slice(), &fixture.raw);

        const structure = fixture.parser.build(
            source,
            fixture.tokens.slice(),
            fixture.raw.const_slice(),
            &fixture.events,
            &fixture.tree,
        );

        try std.testing.expectEqual(.complete, structure);

        const model = fixture.semantic.build(&.{
            .builtins = &.{},
            .raw = fixture.raw.const_slice(),
            .source = source,
            .tokens = fixture.tokens.slice(),
            .tree = &fixture.tree,
            .version = version,
        }, fixture.scratch);

        try std.testing.expectEqual(.complete, model);

        return check(&.{
            .raw = fixture.raw.const_slice(),
            .semantic = &fixture.semantic,
            .source = source,
            .tokens = fixture.tokens.slice(),
            .tree = &fixture.tree,
            .version = version,
        }, &fixture.errors, &fixture.names);
    }

    fn kinds_compare(fixture: *const Fixture, expected: []const CheckKind) !void {
        const errors = fixture.errors.const_slice();

        assert(fixture.source.len > 0);
        assert(expected.len <= error_count_max_default);

        try std.testing.expectEqual(expected.len, errors.len);

        for (errors, expected) |held, kind| try std.testing.expectEqual(kind, held.kind);
    }

    fn rows_compare(fixture: *const Fixture, expected: []const Row) !void {
        const errors = fixture.errors.const_slice();

        assert(fixture.source.len > 0);
        assert(expected.len <= error_count_max_default);

        try std.testing.expectEqual(expected.len, errors.len);

        for (errors, expected) |held, row| {
            try std.testing.expectEqual(row.kind, held.kind);
            try std.testing.expectEqualStrings(row.text, held.span.text(fixture.source));
        }
    }
};

const Row = struct {
    kind: CheckKind,
    text: []const u8,
};

const fixture_event_count_max: u32 = 1 << 16;
const fixture_token_count_max: u32 = 1 << 14;
const fixture_tree_error_count_max: u32 = 1 << 8;
const gated_source = "try:\n    pass\nexcept* ValueError:\n    pass\n";

fn kinds_expect(source: []const u8, version: PythonVersion, expected: []const CheckKind) !void {
    var fixture: Fixture = undefined;

    assert(source.len > 0);
    assert(expected.len <= error_count_max_default);

    try fixture.init(std.testing.allocator, error_count_max_default);
    defer fixture.deinit();

    try std.testing.expectEqual(.complete, try fixture.completion_of(source, version));
    try fixture.kinds_compare(expected);
}

fn rows_expect(source: []const u8, version: PythonVersion, expected: []const Row) !void {
    var fixture: Fixture = undefined;

    assert(source.len > 0);
    assert(expected.len <= error_count_max_default);

    try fixture.init(std.testing.allocator, error_count_max_default);
    defer fixture.deinit();

    try std.testing.expectEqual(.complete, try fixture.completion_of(source, version));
    try fixture.rows_compare(expected);
}

test "an unsupported feature reads its message and its first version" {
    const kind: CheckKind = .{ .unsupported = .match_statement };

    try std.testing.expectEqualStrings("Cannot use `match` statement", kind.message());
    try std.testing.expectEqualStrings("invalid-syntax", kind.code());
    try std.testing.expectEqual(PythonVersion.py310, Feature.match_statement.since());
    try std.testing.expectEqualStrings("`except*`", Feature.except_star.name());
}

test "a check kind reads the rule code it reports under" {
    const late: CheckKind = .future_import_late;
    const yielded: CheckKind = .yield_outside_function;

    try std.testing.expectEqualStrings("F404", late.code());
    try std.testing.expectEqualStrings("F704", yielded.code());

    try std.testing.expectEqualStrings(
        "`yield` statement outside of a function",
        yielded.message(),
    );
}

test "a return outside a function reads as an error" {
    try rows_expect("value = 1\nreturn value\n", .py310, &.{
        .{ .kind = .return_outside_function, .text = "return value" },
    });
}

test "a return inside a function reads as nothing" {
    try kinds_expect("def read():\n    return 1\n", .py310, &.{});
}

test "a yield in a class body reads as an error" {
    try kinds_expect("class Holder:\n    yield 1\n", .py310, &.{.yield_outside_function});
}

test "an await in a synchronous function reads as an error" {
    try kinds_expect("def read(value):\n    return await value\n", .py310, &.{
        .await_outside_async,
    });
}

test "an await in a comprehension inherits the function it stands in" {
    try kinds_expect(
        "async def read(values):\n    return [await item for item in values]\n",
        .py310,
        &.{},
    );
}

test "an await in a lambda reads as an error inside an async function" {
    try kinds_expect("async def read(value):\n    return lambda: (await value)\n", .py310, &.{
        .await_outside_async,
    });
}

test "a bare except before another handler reads as an error" {
    try kinds_expect(
        "try:\n    pass\nexcept:\n    pass\nexcept ValueError:\n    pass\n",
        .py310,
        &.{.except_not_last},
    );
}

test "a bare except standing last reads as nothing" {
    try kinds_expect(
        "try:\n    pass\nexcept ValueError:\n    pass\nexcept:\n    pass\n",
        .py310,
        &.{},
    );
}

test "a duplicate parameter reads at the second one" {
    const source = "def read(value, value):\n    pass\n";
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator, error_count_max_default);
    defer fixture.deinit();

    try std.testing.expectEqual(.complete, try fixture.completion_of(source, .py310));
    try fixture.rows_compare(&.{.{ .kind = .duplicate_parameter, .text = "value" }});
    try std.testing.expectEqual(16, fixture.errors.get(0).span.offset);
}

test "a lambda repeating a parameter reads the same way" {
    try kinds_expect("read = lambda value, value: 0\n", .py310, &.{.duplicate_parameter});
}

test "a future import below a statement reads as late" {
    try kinds_expect("import os\nfrom __future__ import annotations\n", .py310, &.{
        .future_import_late,
    });
}

test "a future import below the docstring reads as nothing" {
    try kinds_expect(
        "\"doc\"\nfrom __future__ import annotations\nfrom __future__ import division\n",
        .py310,
        &.{},
    );
}

test "a global declared below a read names the read" {
    const source =
        \\counter = 0
        \\def read():
        \\    print(counter)
        \\    global counter
        \\    counter = 1
        \\
    ;

    try rows_expect(source, .py310, &.{.{ .kind = .global_after_use, .text = "counter" }});
}

test "a global declared above every read reads as nothing" {
    const source =
        \\counter = 0
        \\def read():
        \\    global counter
        \\    print(counter)
        \\
    ;

    try kinds_expect(source, .py310, &.{});
}

test "a nonlocal at module level reads as an error" {
    try kinds_expect("held = 1\nnonlocal held\n", .py310, &.{.nonlocal_at_module});
}

test "a nonlocal with no enclosing binding names the identifier" {
    const source =
        \\def outer():
        \\    def inner():
        \\        nonlocal missing
        \\        missing = 1
        \\
    ;

    try rows_expect(source, .py310, &.{
        .{ .kind = .nonlocal_without_binding, .text = "missing" },
    });
}

test "a nonlocal reaching past a class body reads as unbound" {
    const source =
        \\class Holder:
        \\    held = 1
        \\
        \\    def read(self):
        \\        nonlocal held
        \\
    ;

    try kinds_expect(source, .py310, &.{.nonlocal_without_binding});
}

test "a nonlocal finding a binding two scopes out reads as nothing" {
    const source =
        \\def outer():
        \\    def middle():
        \\        def inner():
        \\            nonlocal held
        \\            held = 1
        \\    held = 2
        \\
    ;

    try kinds_expect(source, .py310, &.{});
}

test "two starred targets read on the tuple that holds them" {
    try rows_expect("values = [1]\n*first, *second = values\n", .py310, &.{
        .{ .kind = .starred_multiple, .text = "*first, *second" },
    });
}

test "two starred targets nested one level read on the inner tuple" {
    try rows_expect("values = [1]\nfirst, (second, *third, *fourth) = values\n", .py310, &.{
        .{ .kind = .starred_multiple, .text = "(second, *third, *fourth)" },
    });
}

test "one starred value reads as nothing" {
    try kinds_expect("values = [1]\nfirst = *values, *values\n", .py310, &.{});
}

test "a call written to in a for target reads as an invalid assignment target" {
    try rows_expect("def read():\n    pass\nfor read() in [1]:\n    pass\n", .py310, &.{
        .{ .kind = .target_assign_invalid, .text = "read()" },
    });
}

test "a call written to in a with target reads as an invalid assignment target" {
    try rows_expect("def read():\n    pass\nwith read as read():\n    pass\n", .py310, &.{
        .{ .kind = .target_assign_invalid, .text = "read()" },
    });
}

test "a call written to in a comprehension target reads as an invalid assignment target" {
    try rows_expect("def read():\n    pass\nheld = [1 for read() in [1]]\n", .py310, &.{
        .{ .kind = .target_assign_invalid, .text = "read()" },
    });
}

test "two starred targets of a for read on the tuple" {
    try rows_expect("for *first, *second in [1]:\n    pass\n", .py310, &.{
        .{ .kind = .starred_multiple, .text = "*first, *second" },
    });
}

test "a call written to reads as an invalid assignment target" {
    try rows_expect("def read():\n    pass\nread() = 1\n", .py310, &.{
        .{ .kind = .target_assign_invalid, .text = "read()" },
    });
}

test "a call written to inside a tuple names the call" {
    try rows_expect("def read():\n    pass\nheld, read() = 1, 2\n", .py310, &.{
        .{ .kind = .target_assign_invalid, .text = "read()" },
    });
}

test "a starred target standing alone reads as an error" {
    try rows_expect("*held = [1]\n", .py310, &.{
        .{ .kind = .starred_target_alone, .text = "*held" },
    });

    try kinds_expect("*held, = [1]\n[*held] = [1]\n", .py310, &.{});
}

test "a call deleted reads as an invalid delete target" {
    try rows_expect("def read():\n    pass\ndel read()\n", .py310, &.{
        .{ .kind = .target_delete_invalid, .text = "read()" },
    });
}

test "a starred element deleted reads as an invalid delete target" {
    try rows_expect("held = [1]\ndel [held, *held]\n", .py310, &.{
        .{ .kind = .target_delete_invalid, .text = "*held" },
    });
}

test "an attribute and a subscript are targets the grammar allows" {
    try kinds_expect(
        "held = [0]\nheld[0] = 1\nheld.first = 2\ndel held[0], held.first\n",
        .py310,
        &.{},
    );
}

test "an irrefutable case before another names the pattern" {
    const source =
        \\def read(value):
        \\    match value:
        \\        case _:
        \\            return 0
        \\        case 1:
        \\            return 1
        \\
    ;

    try rows_expect(source, .py310, &.{.{ .kind = .irrefutable_case_not_last, .text = "_" }});
}

test "an irrefutable case under a guard reads as nothing" {
    const source =
        \\def read(value, other):
        \\    match value:
        \\        case _ if other:
        \\            return 0
        \\        case 1:
        \\            return 1
        \\
    ;

    try kinds_expect(source, .py310, &.{});
}

test "a walrus in a comprehension iterable reads as an error" {
    try rows_expect("values = [1]\nfound = [item for item in (other := values)]\n", .py310, &.{
        .{ .kind = .walrus_in_comprehension_iterable, .text = "other := values" },
    });
}

test "a walrus rebinding a comprehension variable reads as an error" {
    try kinds_expect("values = [1]\nfound = [item for item in values if (item := 0)]\n", .py310, &.{
        .walrus_rebinds_comprehension_variable,
    });
}

test "a walrus rebinding from the element expression reads the same way" {
    try kinds_expect("values = [1]\nfound = [(item := 2) for item in values]\n", .py310, &.{
        .walrus_rebinds_comprehension_variable,
    });
}

test "a walrus writing another name reads as nothing" {
    try kinds_expect(
        "values = [1]\nfound = [item for item in values if (other := item)]\n",
        .py310,
        &.{},
    );
}

test "a match statement is unsupported before python 310" {
    const source = "def read(value):\n    match value:\n        case 1:\n            return 1\n";

    try kinds_expect(source, .py39, &.{.{ .unsupported = .match_statement }});
    try kinds_expect(source, .py310, &.{});
}

test "a type alias statement is unsupported before python 312" {
    const source = "type Held = int\n";

    try kinds_expect(source, .py311, &.{.{ .unsupported = .type_alias_statement }});
    try kinds_expect(source, .py312, &.{});
}

test "a type parameter list is unsupported before python 312" {
    const source = "def read[Held](value: Held) -> Held:\n    return value\n";

    try kinds_expect(source, .py311, &.{.{ .unsupported = .type_parameters }});
    try kinds_expect(source, .py312, &.{});
}

test "a type parameter default is unsupported before python 313" {
    const source = "def read[Held = int]() -> Held:\n    return Held()\n";

    try rows_expect(source, .py312, &.{
        .{ .kind = .{ .unsupported = .type_parameter_defaults }, .text = "=" },
    });

    try kinds_expect(source, .py313, &.{});
}

test "an unparenthesized except tuple is unsupported before python 314" {
    const source = "try:\n    pass\nexcept ValueError, TypeError:\n    pass\n";
    const parenthesized = "try:\n    pass\nexcept (ValueError, TypeError):\n    pass\n";

    try rows_expect(source, .py313, &.{
        .{
            .kind = .{ .unsupported = .unparenthesized_except_tuple },
            .text = "ValueError, TypeError",
        },
    });

    try kinds_expect(source, .py314, &.{});
    try kinds_expect(parenthesized, .py313, &.{});
}

test "an except star is unsupported before python 311" {
    try kinds_expect(gated_source, .py310, &.{.{ .unsupported = .except_star }});
    try kinds_expect(gated_source, .py311, &.{});
}

test "parenthesized with items are unsupported before python 39" {
    const source =
        \\def read(first, second):
        \\    with (first as one, second as two):
        \\        return one, two
        \\
    ;

    try kinds_expect(source, .py38, &.{.{ .unsupported = .parenthesized_with_items }});
    try kinds_expect(source, .py39, &.{});
}

test "one parenthesized with item is no version gate at all" {
    const source = "def read(first):\n    with (first as one):\n        return one\n";

    try kinds_expect(source, .py38, &.{});
}

test "a template string is unsupported before python 314" {
    const source = "held = t\"text\"\n";

    try kinds_expect(source, .py313, &.{.{ .unsupported = .template_string }});
    try kinds_expect(source, .py314, &.{});
}

test "a plain string is no template however it is written" {
    try kinds_expect("held = \"text\"\nother = rb\"text\"\nthird = f\"{held}\"\n", .py38, &.{});
}

test "every feature names itself and the release that added it" {
    for (std.enums.values(Feature)) |feature| {
        try std.testing.expect(feature.name().len > 0);
        try std.testing.expect(feature.message().len > feature.name().len);
        try std.testing.expect(feature.since().at_least(.py39));
    }
}

test "an error table that fills reports the pass incomplete" {
    const source = "return 1\n" ++ "return 2\n";
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator, 1);
    defer fixture.deinit();

    try std.testing.expectEqual(.errors_full, try fixture.completion_of(source, .py310));
    try std.testing.expectEqual(1, fixture.errors.count());
}

test "every kind carries a code and a message" {
    const kinds = [_]CheckKind{
        .await_outside_async,
        .await_outside_function,
        .duplicate_parameter,
        .except_not_last,
        .future_import_late,
        .global_after_use,
        .irrefutable_case_not_last,
        .nonlocal_at_module,
        .nonlocal_without_binding,
        .return_outside_function,
        .starred_multiple,
        .starred_target_alone,
        .target_assign_invalid,
        .target_delete_invalid,
        .{ .unsupported = .match_statement },
        .walrus_in_comprehension_iterable,
        .walrus_rebinds_comprehension_variable,
        .yield_outside_function,
    };

    for (kinds) |kind| {
        try std.testing.expect(kind.code().len > 0);
        try std.testing.expect(kind.message().len > 0);
    }
}
