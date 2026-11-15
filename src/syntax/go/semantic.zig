const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const BindingClass = @import("../semantic.zig").BindingClass;
const EventsType = @import("../tree.zig").EventsType;
const Fact = @import("../fact.zig").Fact;
const Kind = @import("kind.zig").Kind;
const Order = @import("../semantic.zig").Order;
const Parser = @import("parse.zig").Parser;
const Pick = @import("../semantic.zig").Pick;
const Position = @import("../semantic.zig").Position;
const ScopeClass = @import("../semantic.zig").ScopeClass;
const SemanticType = @import("../semantic.zig").SemanticType;
const Span = @import("../../stdx/bounded/span.zig");
const Structure = @import("../tree.zig").Structure;
const Token = @import("../token.zig");
const Tokens = @import("../tokens.zig");
const TreeType = @import("../tree.zig").TreeType;
const camel_of = @import("../category.zig").camel_of;
const lex = @import("lex.zig").lex;
const none = @import("../semantic.zig").none;
const raw_of = @import("../raw.zig").raw_of;
const walk = @import("../tree.zig").walk;
const Tree = TreeType(Kind);
const Limits = @import("../semantic.zig").Limits;
const Reference = Semantic.Reference;
const Resolution = @import("../semantic.zig").Resolution;
pub const Semantic = SemanticType(Rules);

const Rules = struct {
    pub const BindingExtension = void;
    pub const Extension = void;
    pub const ReferenceExtension = void;
    pub const ScopeExtension = void;
    pub const pick: Pick = .oldest;
    pub const scopes_in_walk_order: bool = true;

    pub const BindingKind = enum {
        @"const",
        field,
        function,
        import,
        import_blank,
        import_dot,
        label,
        method,
        parameter,
        receiver,
        result,
        short,
        type,
        type_parameter,
        @"var",

        pub fn hoists(kind: BindingKind) bool {
            const result = switch (kind) {
                .@"const", .function, .method, .type, .@"var" => true,
                .field, .import, .import_blank, .import_dot, .label => false,
                .parameter, .receiver, .result, .short, .type_parameter => false,
            };

            if (kind == .short) assert(!result);
            if (kind == .function) assert(result);

            return result;
        }
    };

    pub const Namespace = enum {
        label,
        method,
        value,
    };

    pub const Options = struct {
        globals: []const []const u8,
    };

    pub const ScopeKind = enum {
        block,
        file,
        function,
        package,

        fn is_ordered(kind: ScopeKind) bool {
            const result = kind == .block or kind == .function;

            if (kind == .package) assert(!result);
            if (kind == .block) assert(result);

            return result;
        }
    };

    pub fn after_resolve(
        semantic: *const Semantic,
        source: []const u8,
        options: *const Options,
    ) void {
        assert(semantic.scope_count() >= 2);
        assert(source.len <= std.math.maxInt(u32));
        assert(options.globals.len <= std.math.maxInt(u32));
    }

    pub fn binds_in(kind: BindingKind, wanted: Namespace) bool {
        return namespace_of(kind) == wanted;
    }

    pub fn build(
        semantic: *Semantic,
        source: []const u8,
        tokens: []const Token,
        raw: []const Kind,
        tree: *const Tree,
        universe: []const []const u8,
    ) Structure {
        assert(source.len <= std.math.maxInt(u32));
        assert(tokens.len == raw.len);
        assert(semantic.scopes.capacity() >= 2);
        assert(universe.len <= std.math.maxInt(u32));

        semantic.clear();
        semantic.scope_root(.package, 0, {});

        const file = semantic.scope_open(0, .file, 0, {}) catch unreachable;

        assert(file == 1);

        var builder: Builder = .{
            .depth = 0,
            .outcome = .complete,
            .pending = @splat(none),
            .raw = raw,
            .semantic = semantic,
            .source = source,
            .stack = @splat(0),
            .tokens = tokens,
            .tree = tree,
        };

        builder.collect();
        semantic.resolve(source, &.{ .globals = universe });

        assert(semantic.scope_count() >= 2);
        assert(semantic.scope_at(1).parent == 0);

        return builder.outcome;
    }

    pub fn chains_with(previous: BindingKind, kind: BindingKind) bool {
        return namespace_of(previous) == namespace_of(kind);
    }

    pub fn class_of(kind: BindingKind) BindingClass {
        const class: BindingClass = switch (kind) {
            .@"const" => .constant,
            .field => .field,
            .function => .function,
            .import, .import_blank, .import_dot => .import,
            .label => .other,
            .method => .method,
            .parameter, .receiver => .parameter,
            .result, .short, .@"var" => .local,
            .type, .type_parameter => .type,
        };

        if (kind == .label) assert(class == .other);
        if (kind == .receiver) assert(class == .parameter);

        return class;
    }

    pub fn crosses(scope: ScopeKind) bool {
        assert(@backingInt(scope) < @typeInfo(ScopeKind).@"enum".field_names.len);

        return false;
    }

    pub fn fallback(reference: *const Reference, dynamic_seen: bool) Resolution {
        assert(reference.resolution == .unresolved);
        assert(reference.scope != none);

        if (dynamic_seen) return .maybe;
        return .unresolved;
    }

    pub fn is_builtin(name: []const u8, options: *const Options) bool {
        assert(name.len > 0);

        for (options.globals) |builtin| {
            if (std.mem.eql(u8, builtin, name)) return true;
        }

        return false;
    }

    pub fn lands(kind: BindingKind, scope: ScopeKind) bool {
        const result = !(scope == .file and kind.hoists());

        if (scope != .file) assert(result);
        if (!result) assert(kind.hoists());

        return result;
    }

    pub fn namespace_of(kind: BindingKind) Namespace {
        const result: Namespace = switch (kind) {
            .label => .label,
            .method => .method,
            .@"const", .field, .function, .import, .import_blank, .import_dot => .value,
            .parameter, .receiver, .result, .short, .type, .type_parameter, .@"var" => .value,
        };

        if (kind == .label) assert(result == .label);
        if (kind == .method) assert(result == .method);

        return result;
    }

    pub fn order(reference: *const Reference, scope: ScopeKind, position: Position) Order {
        assert(reference.scope != none);
        assert(!position.redirected);

        if (reference.namespace != .value) return .unordered;
        if (scope.is_ordered()) return .from_or_self;
        return .unordered;
    }

    pub fn retry_namespace(reference: *const Reference) ?Namespace {
        assert(reference.scope != none);

        return null;
    }

    pub fn scope_class_of(kind: ScopeKind) ScopeClass {
        const class: ScopeClass = switch (kind) {
            .block => .block,
            .file, .package => .module,
            .function => .function,
        };

        if (kind == .file) assert(class == .module);

        return class;
    }

    pub fn skips(scope: ScopeKind, position: Position) bool {
        assert(@backingInt(scope) < @typeInfo(ScopeKind).@"enum".field_names.len);
        assert(!position.redirected);

        return false;
    }

    pub fn start_scope(
        semantic: *const Semantic,
        source: []const u8,
        reference: *const Reference,
    ) u32 {
        assert(reference.scope < semantic.scope_count());
        assert(reference.name.end() <= source.len);

        return reference.scope;
    }
};

const Builder = struct {
    depth: u32,
    outcome: Structure,
    pending: [scope_depth_max]u32,
    raw: []const Kind,
    semantic: *Semantic,
    source: []const u8,
    stack: [scope_depth_max]u32,
    tokens: []const Token,
    tree: *const Tree,

    fn collect(builder: *Builder) void {
        if (builder.tree.count() == 0) return;

        builder.stack[0] = 1;
        builder.depth = 1;

        var steps = walk(Tree, builder.tree);

        for (0..steps.step_max) |_| {
            const step = steps.next() orelse break;

            switch (step) {
                .enter => |node| builder.enter(node),
                .leave => |node| builder.leave(node),
            }
        }

        assert(steps.node == null);
        assert(builder.depth >= 1);
    }

    fn scope_current(builder: *const Builder) u32 {
        assert(builder.depth > 0);
        assert(builder.depth <= scope_depth_max);

        const scope = builder.stack[builder.depth - 1];

        assert(scope < builder.semantic.scope_count());

        return scope;
    }

    fn scope_hoisted(builder: *const Builder, kind: Rules.BindingKind) u32 {
        assert(kind == .@"const" or kind == .label or kind == .type or
            kind == .type_parameter or kind == .@"var");

        const held = builder.scope_current();
        const scope = builder.semantic.scope_landing(held, kind);

        assert(scope <= held);
        if (scope == 0) assert(kind.hoists() or held == 0);

        return scope;
    }

    fn kind_of(builder: *const Builder, node: ?u32) Kind {
        if (node) |held| assert(held < std.math.maxInt(u32));

        const held = node orelse return .error_node;

        assert(held < builder.tree.count());

        const kind = builder.tree.kind_at(held);

        assert(kind.is_node());

        return kind;
    }

    fn children(builder: *const Builder, node: u32) Children {
        assert(node < builder.tree.count());

        const child_first = builder.tree.child_first_of(node);

        if (child_first) |held| assert(held > node);

        return .{ .node = child_first, .tree = builder.tree };
    }

    fn child_at(builder: *const Builder, node: u32, index: u32) ?u32 {
        assert(node < builder.tree.count());
        assert(index < builder.tree.count());

        var held = builder.children(node);
        var position: u32 = 0;

        for (0..builder.tree.count()) |_| {
            const child = held.next() orelse return null;
            if (position == index) return child;

            position += 1;
        }

        return null;
    }

    fn child_of_kind(builder: *const Builder, node: u32, kind: Kind) ?u32 {
        assert(node < builder.tree.count());
        assert(kind.is_node());

        var held = builder.children(node);

        for (0..builder.tree.count()) |_| {
            const child = held.next() orelse return null;
            if (builder.kind_of(child) == kind) return child;
        }

        return null;
    }

    fn parent_of(builder: *const Builder, node: ?u32) ?u32 {
        if (node) |held| assert(held < std.math.maxInt(u32));

        const held = node orelse return null;

        assert(held < builder.tree.count());

        const parent = builder.tree.parent_of(held);

        if (parent) |above| assert(above < held);

        return parent;
    }

    fn span_of(builder: *const Builder, node: u32) Span {
        assert(node < builder.tree.count());

        const span = builder.tree.at(node).span(Token, builder.tokens);

        assert(span.end() <= builder.source.len);

        return span;
    }

    fn end_of(builder: *const Builder, node: u32) u32 {
        assert(node < none);

        const span = builder.span_of(node);
        const end = span.end();

        assert(end >= span.offset);
        assert(end <= builder.source.len);

        return end;
    }

    fn text_of(builder: *const Builder, name: Span) []const u8 {
        assert(name.end() <= builder.source.len);

        const text = name.text(builder.source);

        assert(text.len == name.length);

        return text;
    }

    fn at(builder: *const Builder, position: u32) Kind {
        assert(builder.raw.len == builder.tokens.len);
        assert(position < std.math.maxInt(u32));

        if (position >= builder.raw.len) return .error_token;

        const kind = builder.raw[position];

        assert(kind.is_token());

        return kind;
    }

    fn holds(builder: *const Builder, node: u32, kind: Kind) bool {
        assert(node < none);

        const held = builder.tree.at(node);

        assert(held.token_end <= builder.raw.len);
        assert(kind.is_token());

        for (builder.raw[held.token_start..held.token_end]) |token_kind| {
            if (token_kind == kind) return true;
        }

        return false;
    }

    fn significant(builder: *const Builder, from: u32) u32 {
        assert(builder.raw.len == builder.tokens.len);
        assert(from < none);

        var position = from;

        while (position < builder.raw.len) : (position += 1) {
            if (!builder.raw[position].is_trivia()) break;
        }

        assert(position >= from);

        return position;
    }

    fn token_of(builder: *const Builder, node: u32, kind: Kind) ?u32 {
        assert(node < none);

        const held = builder.tree.at(node);
        var position = held.token_start;
        var child = builder.tree.child_first_of(node);

        assert(held.token_end <= builder.raw.len);
        assert(kind.is_token());

        for (0..held.token_end - held.token_start + builder.tree.count()) |_| {
            if (position >= held.token_end) break;

            if (child) |inner| {
                const inner_node = builder.tree.at(inner);

                if (position >= inner_node.token_start) {
                    position = @max(position, inner_node.token_end);
                    child = builder.tree.sibling_next_of(inner);

                    continue;
                }
            }

            if (builder.raw[position] == kind) return position;

            position += 1;
        }

        return null;
    }

    fn opens_with(builder: *const Builder, node: u32, kind: Kind) bool {
        assert(node < none);

        const position = builder.significant(builder.tree.at(node).token_start);

        assert(kind.is_token());
        assert(position >= builder.tree.at(node).token_start);

        return builder.at(position) == kind;
    }

    fn leading_names(builder: *const Builder, node: u32) Names {
        assert(node < builder.tree.count());

        var child = builder.tree.child_first_of(node);
        var name_count: u32 = 0;

        for (0..builder.tree.count()) |_| {
            const held = child orelse break;

            if (builder.kind_of(held) != .ident) {
                return .{ .covered = false, .name_count = name_count };
            }

            name_count += 1;
            child = builder.tree.sibling_next_of(held);

            const after = builder.significant(builder.tree.at(held).token_end);
            if (builder.at(after) != .comma) break;
        }

        assert(name_count <= builder.tree.count());

        return .{ .covered = child == null, .name_count = name_count };
    }

    fn among_leading(builder: *const Builder, parent: u32, node: u32, name_count: u32) bool {
        assert(parent < node);
        assert(name_count <= builder.tree.count());

        var held = builder.children(parent);

        for (0..name_count) |_| {
            const child = held.next() orelse return false;
            if (child == node) return true;
        }

        return false;
    }

    fn opens(builder: *const Builder, node: u32) ?Rules.ScopeKind {
        assert(node < builder.tree.count());

        const scope_kind = scope_kind_of(builder.kind_of(node));

        if (scope_kind) |held| {
            assert(held != .file);
            assert(held != .package);
        }

        return scope_kind;
    }

    fn is_body(builder: *const Builder, node: u32) bool {
        assert(node < builder.tree.count());

        if (builder.kind_of(node) != .block_stmt) return false;

        const parent = builder.kind_of(builder.parent_of(node));

        assert(parent != .file);

        return parent == .func_decl or parent == .func_lit;
    }

    fn enter(builder: *Builder, node: u32) void {
        assert(node < none);

        const kind = builder.kind_of(node);

        builder.before(node, kind);

        if (builder.opens(node)) |held| {
            const written = if (builder.is_body(node)) builder.pending[builder.depth - 1] else none;

            if (written == none) {
                builder.open(node, held);
            } else {
                builder.push(written);
            }

            builder.opened(node, kind);
        }

        builder.name_refer(node, kind);

        assert(builder.depth > 0);
    }

    fn leave(builder: *Builder, node: u32) void {
        assert(builder.depth > 0);
        assert(node < none);

        if (builder.opens(node) == null) return;

        if (builder.depth > 1) builder.depth -= 1;

        assert(builder.depth >= 1);
    }

    fn open(builder: *Builder, node: u32, kind: Rules.ScopeKind) void {
        assert(node < none);
        assert(scope_kind_of(builder.kind_of(node)) == kind);

        const parent = builder.scope_current();
        const index = builder.scope_under(parent, node, kind) orelse return;

        assert(index > parent);
        assert(builder.semantic.scope_at(index).parent == parent);

        builder.push(index);
    }

    fn scope_under(builder: *Builder, parent: u32, node: u32, kind: Rules.ScopeKind) ?u32 {
        assert(parent < none);
        assert(kind == .function or kind == .block);
        if (node != none) assert(node < builder.tree.count());

        const semantic = builder.semantic;

        const index = semantic.scope_open(parent, kind, node, {}) catch |err| switch (err) {
            error.Truncated => {
                if (builder.outcome == .complete) builder.outcome = .{ .truncated = .scopes };

                return null;
            },
        };

        assert(index > parent);
        assert(semantic.scope_count() == index + 1);

        return index;
    }

    fn push(builder: *Builder, index: u32) void {
        assert(index < builder.semantic.scope_count());

        if (builder.depth >= scope_depth_max) {
            builder.outcome = .too_deep;

            return;
        }

        builder.stack[builder.depth] = index;
        builder.pending[builder.depth] = none;
        builder.depth += 1;

        assert(builder.scope_current() == index);
    }

    fn before(builder: *Builder, node: u32, kind: Kind) void {
        assert(builder.kind_of(node) == kind);
        assert(builder.depth > 0);

        switch (kind) {
            .assign_stmt => builder.short_declare(node, builder.end_of(node)),
            .func_decl => builder.function_declare(node),
            .func_type => builder.function_type_declare(node),
            .import_spec => builder.import_declare(node),
            .labeled_stmt => builder.label_declare(node),
            .type_spec => builder.type_declare(node),
            .value_spec => builder.value_declare(node),
            else => {},
        }
    }

    fn opened(builder: *Builder, node: u32, kind: Kind) void {
        assert(builder.kind_of(node) == kind);
        assert(builder.depth > 0);

        switch (kind) {
            .func_decl, .func_lit => {
                const body = builder.body_open(node);

                if (kind == .func_decl) builder.receiver_declare(node, body);

                builder.signature_declare(node, body);
            },
            .case_clause => builder.guard_declare(node),
            .range_stmt => builder.range_declare(node),
            .type_spec => builder.type_parameters_declare(node),
            else => {},
        }
    }

    fn body_open(builder: *Builder, node: u32) ?u32 {
        assert(node < none);

        const parent = builder.scope_current();
        const held = builder.child_of_kind(node, .block_stmt);
        const index = builder.scope_under(parent, held orelse none, .function) orelse return null;

        if (held != null) builder.pending[builder.depth - 1] = index;

        assert(index > parent);
        assert(builder.semantic.scope_at(index).kind == .function);

        return index;
    }

    fn function_declare(builder: *Builder, node: u32) void {
        assert(node < none);

        const signature = builder.child_of_kind(node, .func_type) orelse return;
        const held = builder.child_of_kind(signature, .ident) orelse return;
        const method = builder.receiver_of(signature) != null;
        const kind: Rules.BindingKind = if (method) .method else .function;
        const name = builder.span_of(held);

        assert(held > signature);
        assert(signature > node);

        _ = builder.record_within(0, &.{
            .from = name.offset,
            .kind = kind,
            .name = name,
            .node = held,
        });
    }

    fn receiver_of(builder: *const Builder, signature: u32) ?u32 {
        assert(builder.kind_of(signature) == .func_type);

        var held = builder.children(signature);

        for (0..builder.tree.count()) |_| {
            const child = held.next() orelse break;
            const kind = builder.kind_of(child);
            if (kind == .ident) return null;
            if (kind == .field_list) return child;
        }

        assert(held.node == null);

        return null;
    }

    fn receiver_declare(builder: *Builder, node: u32, body: ?u32) void {
        assert(builder.kind_of(node) == .func_decl);
        if (body) |held| assert(held < std.math.maxInt(u32));

        const signature = builder.child_of_kind(node, .func_type) orelse return;
        const held = builder.receiver_of(signature) orelse return;

        assert(held > signature);

        builder.field_list_declare(body, held, .receiver);
        builder.receiver_parameters_declare(held);
    }

    fn receiver_parameters_declare(builder: *Builder, node: u32) void {
        assert(builder.kind_of(node) == .field_list);

        var stack: [stack_depth_max]u32 = undefined;
        var depth: u32 = 1;

        stack[0] = node;

        for (0..step_max) |_| {
            if (depth == 0) return;

            depth -= 1;

            const held = stack[depth];

            switch (builder.kind_of(held)) {
                .index_expr, .index_list_expr => {
                    builder.receiver_type_parameters_declare(held);

                    continue;
                },
                else => {},
            }

            var inner = builder.children(held);

            for (0..builder.tree.count()) |_| {
                const child = inner.next() orelse break;

                if (depth >= stack_depth_max) return;

                stack[depth] = child;
                depth += 1;
            }
        }

        assert(depth <= stack_depth_max);
    }

    fn receiver_type_parameters_declare(builder: *Builder, node: u32) void {
        assert(node < builder.tree.count());

        var held = builder.children(node);

        _ = held.next();

        for (0..builder.tree.count()) |_| {
            const child = held.next() orelse break;
            if (builder.kind_of(child) != .ident) continue;

            _ = builder.record(.type_parameter, child);
        }

        assert(held.node == null);
    }

    fn function_type_declare(builder: *Builder, node: u32) void {
        assert(builder.kind_of(node) == .func_type);

        switch (builder.kind_of(builder.parent_of(node))) {
            .func_decl, .func_lit => return,
            else => {},
        }

        const held = builder.scope_current();
        const scope = builder.scope_under(held, node, .function);

        if (scope) |index| assert(index > held);

        builder.parameters_declare(node, &.{ .named = none, .parameters = scope, .types = scope });
    }

    fn signature_declare(builder: *Builder, node: u32, body: ?u32) void {
        assert(node < builder.tree.count());
        if (body) |held| assert(held < std.math.maxInt(u32));

        const signature = builder.child_of_kind(node, .func_type) orelse return;
        const named = builder.child_of_kind(signature, .ident);

        assert(signature > node);

        builder.parameters_declare(signature, &.{
            .named = named orelse none,
            .parameters = body,
            .types = builder.scope_current(),
        });
    }

    fn parameters_declare(builder: *Builder, signature: u32, lists: *const Lists) void {
        assert(builder.kind_of(signature) == .func_type);
        assert(lists.named == none or lists.named > signature);

        var seen = lists.named == none;
        var parameters = false;
        var held = builder.children(signature);

        for (0..builder.tree.count()) |_| {
            const child = held.next() orelse break;

            if (child == lists.named) {
                seen = true;

                continue;
            }

            if (!seen) continue;
            if (builder.kind_of(child) != .field_list) continue;

            if (builder.opens_with(child, .bracket_open)) {
                builder.field_list_declare(lists.types, child, .type_parameter);

                continue;
            }

            const kind: Rules.BindingKind = if (parameters) .result else .parameter;

            parameters = true;

            builder.field_list_declare(lists.parameters, child, kind);
        }
    }

    fn field_list_declare(
        builder: *Builder,
        scope: ?u32,
        node: u32,
        kind: Rules.BindingKind,
    ) void {
        if (scope) |held| assert(held < std.math.maxInt(u32));
        assert(node < none);

        const target = scope orelse return;
        var held = builder.children(node);

        assert(target < builder.semantic.scope_count());
        assert(builder.kind_of(node) == .field_list);

        for (0..builder.tree.count()) |_| {
            const child = held.next() orelse break;
            if (builder.kind_of(child) != .field) continue;

            const names = builder.leading_names(child);
            if (names.covered) continue;

            builder.names_record(child, names.name_count, &.{
                .from = null,
                .kind = kind,
                .scope = target,
            });
        }
    }

    fn names_record(builder: *Builder, node: u32, name_count: u32, recorded: *const Recorded) void {
        assert(node < builder.tree.count());
        assert(name_count <= builder.tree.count());

        var held = builder.children(node);

        for (0..name_count) |_| {
            const name = held.next() orelse break;
            const span = builder.span_of(name);

            _ = builder.record_within(recorded.scope, &.{
                .from = recorded.from orelse span.offset,
                .kind = recorded.kind,
                .name = span,
                .node = name,
            });
        }
    }

    fn value_declare(builder: *Builder, node: u32) void {
        assert(node > 0);

        const parent = builder.parent_of(node).?;
        const constant = builder.holds(parent, .const_keyword);
        const kind: Rules.BindingKind = if (constant) .@"const" else .@"var";
        const names = builder.leading_names(node);

        assert(parent < node);

        builder.names_record(node, names.name_count, &.{
            .from = builder.end_of(node),
            .kind = kind,
            .scope = builder.scope_hoisted(kind),
        });
    }

    fn type_declare(builder: *Builder, node: u32) void {
        assert(builder.kind_of(node) == .type_spec);

        const held = builder.child_at(node, 0) orelse return;
        if (builder.kind_of(held) != .ident) return;

        assert(held > node);

        _ = builder.record(.type, held);
    }

    fn type_parameters_declare(builder: *Builder, node: u32) void {
        assert(builder.kind_of(node) == .type_spec);

        const parameters = builder.child_at(node, 1) orelse return;
        if (builder.kind_of(parameters) != .field_list) return;

        assert(parameters > node);

        builder.field_list_declare(builder.scope_current(), parameters, .type_parameter);
    }

    fn short_declare(builder: *Builder, node: u32, from: u32) void {
        assert(node < builder.tree.count());
        assert(from < none);

        const colon_equal = builder.token_of(node, .colon_equal) orelse return;
        var held = builder.children(node);

        assert(colon_equal < builder.raw.len);

        for (0..builder.tree.count()) |_| {
            const child = held.next() orelse break;
            if (builder.tree.at(child).token_start >= colon_equal) break;
            if (builder.kind_of(child) != .ident) continue;

            const name = builder.span_of(child);
            if (builder.scope_holds(name)) continue;

            _ = builder.record_within(builder.scope_current(), &.{
                .from = from,
                .kind = .short,
                .name = name,
                .node = child,
            });
        }
    }

    fn range_declare(builder: *Builder, node: u32) void {
        assert(builder.kind_of(node) == .range_stmt);

        const block = builder.child_of_kind(node, .block_stmt);
        const from = if (block) |held| builder.span_of(held).offset else builder.end_of(node);

        assert(from <= builder.source.len);

        builder.short_declare(node, from);
    }

    fn guard_declare(builder: *Builder, node: u32) void {
        assert(builder.kind_of(node) == .case_clause);

        const block = builder.parent_of(node) orelse return;
        const switch_node = builder.parent_of(block) orelse return;
        if (builder.kind_of(switch_node) != .type_switch_stmt) return;

        const held = builder.guard_of(switch_node) orelse return;
        const name = builder.span_of(held);

        assert(held > switch_node);

        _ = builder.record_within(builder.scope_current(), &.{
            .from = name.offset,
            .kind = .short,
            .name = name,
            .node = held,
        });
    }

    fn guard_of(builder: *const Builder, switch_node: u32) ?u32 {
        assert(builder.kind_of(switch_node) == .type_switch_stmt);

        var held = builder.children(switch_node);

        for (0..builder.tree.count()) |_| {
            const child = held.next() orelse break;
            if (builder.kind_of(child) != .assign_stmt) continue;
            if (!builder.holds(child, .type_keyword)) continue;

            const first = builder.child_at(child, 0);
            if (builder.kind_of(first) == .ident) return first;
        }

        assert(held.node == null);

        return null;
    }

    fn label_declare(builder: *Builder, node: u32) void {
        assert(builder.kind_of(node) == .labeled_stmt);

        const held = builder.child_at(node, 0) orelse return;
        if (builder.kind_of(held) != .ident) return;

        assert(held > node);

        _ = builder.record(.label, held);
    }

    fn import_declare(builder: *Builder, node: u32) void {
        assert(node < none);

        const held = builder.child_at(node, 0);
        const specifier = builder.specifier_of(node);
        const named = builder.kind_of(held) == .ident;
        const name = if (named) builder.span_of(held.?) else package_of(builder.source, specifier);
        const text = builder.text_of(name);

        const kind: Rules.BindingKind = if (std.mem.eql(u8, text, "_"))
            .import_blank
        else if (std.mem.eql(u8, text, "."))
            .import_dot
        else
            .import;

        assert(builder.kind_of(node) == .import_spec);
        assert(specifier.end() <= builder.source.len);

        if (kind == .import_dot) builder.semantic.scope_mark_dynamic(builder.scope_current());

        const binding = if (kind == .import) builder.record_within(1, &.{
            .from = name.offset,
            .kind = kind,
            .name = name,
            .node = node,
        }) else null;

        builder.fact_push(&.{
            .binding = .of(binding),
            .kind = .import_named,
            .local = name,
            .remote = specifier,
            .specifier = specifier,
        });
    }

    fn specifier_of(builder: *const Builder, node: u32) Span {
        assert(node < builder.tree.count());

        const literal = builder.child_of_kind(node, .basic_lit) orelse return Span.empty;
        const held = builder.span_of(literal);

        assert(literal > node);

        if (held.length < 2) return held;
        return .{ .offset = held.offset + 1, .length = held.length - 2 };
    }

    fn scope_holds(builder: *const Builder, name: Span) bool {
        assert(name.length <= std.math.maxInt(u32) - name.offset);

        const text = builder.text_of(name);
        const scope = builder.scope_current();

        assert(scope != none);
        assert(text.len == name.length);

        return builder.semantic.binding_newest(builder.source, scope, text, .value) != null;
    }

    fn name_refer(builder: *Builder, node: u32, kind: Kind) void {
        assert(builder.kind_of(node) == kind);

        if (kind != .ident) return;

        const name = builder.span_of(node);
        if (std.mem.eql(u8, builder.text_of(name), "_")) return;
        if (!builder.reads(node)) return;

        const labelled = builder.kind_of(builder.parent_of(node)) == .branch_stmt;
        const namespace: Rules.Namespace = if (labelled) .label else .value;

        assert(name.end() <= builder.source.len);

        builder.semantic.refer(builder.source, &.{
            .context = .load,
            .dead_zone = false,
            .ext = {},
            .name = name,
            .name_hash = 0,
            .namespace = namespace,
            .node = node,
            .resolution = .unresolved,
            .scope = builder.scope_current(),
        }) catch |err| switch (err) {
            error.Truncated => {
                if (builder.outcome == .complete) builder.outcome = .{ .truncated = .references };
            },
        };
    }

    fn reads(builder: *const Builder, node: u32) bool {
        assert(builder.kind_of(node) == .ident);

        const parent = builder.parent_of(node) orelse return true;

        assert(parent < node);

        return switch (builder.kind_of(parent)) {
            .file => false,
            .func_type => builder.child_of_kind(parent, .ident) != node,
            .selector_expr => builder.child_at(parent, 0) == node,
            .key_value_expr => builder.child_at(parent, 0) != node,
            .field, .import_spec, .labeled_stmt, .type_spec => !builder.declares(parent, node),
            .value_spec => !builder.declares(parent, node),
            .assign_stmt, .range_stmt => builder.reads_short(parent, node),
            else => true,
        };
    }

    fn reads_short(builder: *const Builder, parent: u32, node: u32) bool {
        assert(parent < node);
        assert(builder.kind_of(node) == .ident);

        if (!builder.declares(parent, node)) return true;
        if (builder.guards(parent)) return false;
        return builder.scope_holds(builder.span_of(node));
    }

    fn guards(builder: *const Builder, node: u32) bool {
        assert(node < builder.tree.count());

        const parent = builder.parent_of(node) orelse return false;

        assert(parent < node);

        if (builder.kind_of(parent) != .type_switch_stmt) return false;
        return builder.holds(node, .type_keyword);
    }

    fn declares(builder: *const Builder, parent: u32, node: u32) bool {
        assert(parent < node);

        const kind = builder.kind_of(parent);

        switch (kind) {
            .import_spec, .labeled_stmt, .type_spec => return builder.child_at(parent, 0) == node,
            .assign_stmt, .range_stmt => {
                const declares_at = builder.token_of(parent, .colon_equal) orelse return false;
                return builder.tree.at(node).token_start < declares_at;
            },
            else => {},
        }

        const names = builder.leading_names(parent);

        assert(names.name_count <= builder.tree.count());

        if (names.covered) {
            if (kind == .field) return false;
        }

        return builder.among_leading(parent, node, names.name_count);
    }

    fn fact_push(builder: *Builder, fact: *const Fact) void {
        assert(fact.local.end() <= builder.source.len);
        assert(fact.specifier.end() <= builder.source.len);

        builder.semantic.fact_push(fact.*) catch |err| switch (err) {
            error.Truncated => {
                if (builder.outcome == .complete) builder.outcome = .{ .truncated = .facts };
            },
        };
    }

    fn record(builder: *Builder, kind: Rules.BindingKind, node: u32) ?u32 {
        assert(node < none);
        assert(kind == .label or kind == .type or kind == .type_parameter);

        const name = builder.span_of(node);
        const scope = builder.scope_hoisted(kind);

        assert(scope < builder.semantic.scope_count());
        assert(builder.kind_of(node) == .ident);

        return builder.record_within(scope, &.{
            .from = name.offset,
            .kind = kind,
            .name = name,
            .node = node,
        });
    }

    fn record_within(builder: *Builder, scope: u32, declared: *const Declared) ?u32 {
        assert(scope < none);

        const text = builder.text_of(declared.name);
        if (std.mem.eql(u8, text, "_")) return null;

        const semantic = builder.semantic;

        const index = semantic.declare(builder.source, scope, &.{
            .dead_zone_end = none,
            .ext = {},
            .from = if (declared.kind == .type_parameter) 0 else declared.from,
            .kind = declared.kind,
            .name = declared.name,
            .node = declared.node,
        }) catch |err| switch (err) {
            error.Truncated => {
                if (builder.outcome == .complete) builder.outcome = .{ .truncated = .bindings };

                return null;
            },
        };

        assert(semantic.count() == index + 1);
        assert(semantic.at(index).scope == scope);

        return index;
    }
};

const Children = struct {
    node: ?u32,
    tree: *const Tree,

    fn next(held: *Children) ?u32 {
        const node = held.node orelse return null;

        held.node = held.tree.sibling_next_of(node);

        if (held.node) |sibling| assert(sibling > node);

        return node;
    }
};

const Declared = struct {
    from: u32,
    kind: Rules.BindingKind,
    name: Span,
    node: u32,
};

const Lists = struct {
    named: u32,
    parameters: ?u32,
    types: ?u32,
};

const Names = struct {
    covered: bool,
    name_count: u32,
};

const Recorded = struct {
    from: ?u32,
    kind: Rules.BindingKind,
    scope: u32,
};

const scope_depth_max = @import("../semantic.zig").scope_depth_max;
const stack_depth_max: u32 = 1 << 6;
const step_max: u32 = 1 << 12;

comptime {
    assert(scope_depth_max < step_max);
    assert(stack_depth_max < step_max);
}

fn scope_kind_of(kind: Kind) ?Rules.ScopeKind {
    assert(kind.is_node());

    const scope_kind: ?Rules.ScopeKind = switch (kind) {
        .func_decl, .func_lit, .type_spec => .function,
        .block_stmt, .case_clause, .comm_clause, .for_stmt, .if_stmt => .block,
        .range_stmt, .select_stmt, .switch_stmt, .type_switch_stmt => .block,
        else => null,
    };

    if (kind == .func_lit) assert(scope_kind.? == .function);
    if (kind == .file) assert(scope_kind == null);

    return scope_kind;
}

fn package_of(source: []const u8, specifier: Span) Span {
    assert(source.len <= std.math.maxInt(u32));
    assert(specifier.end() <= source.len);

    const text = specifier.text(source);
    var start = segment_of(text);
    var end: u32 = specifier.length;

    if (start > 0) {
        if (versioned(text[start..])) {
            end = start - 1;
            start = segment_of(text[0..end]);
        }
    }

    assert(start <= end);
    assert(end <= text.len);

    return .{ .offset = specifier.offset + start, .length = end - start };
}

fn segment_of(path: []const u8) u32 {
    assert(path.len <= std.math.maxInt(u32));

    const slash = std.mem.findScalarLast(u8, path, '/');
    const start: u32 = if (slash) |index| @intCast(index + 1) else 0;

    assert(start <= path.len);
    if (start > 0) assert(path[start - 1] == '/');

    return start;
}

fn versioned(segment: []const u8) bool {
    if (segment.len < 2) return false;
    if (segment[0] != 'v') return false;

    for (segment[1..]) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }

    assert(segment.len >= 2);
    assert(segment[0] == 'v');

    return true;
}

const Fixture = struct {
    events: Events,
    parser: *Parser,
    raw: ArrayType(Kind),
    semantic: Semantic,
    source: []const u8,
    tokens: Tokens,
    tree: Tree,

    fn init(fixture: *Fixture) !void {
        const gpa = std.testing.allocator;

        try fixture.events.init(gpa, fixture_event_count_max);
        errdefer fixture.events.deinit(gpa);

        fixture.parser = try gpa.create(Parser);
        errdefer gpa.destroy(fixture.parser);

        fixture.raw = try .init(gpa, fixture_token_count_max);
        errdefer fixture.raw.deinit(gpa);

        try fixture.semantic.init(gpa, &limits_fixture);
        errdefer fixture.semantic.deinit(gpa);

        fixture.tokens = try .init(gpa, fixture_token_count_max);
        errdefer fixture.tokens.deinit(gpa);

        fixture.tree = try .init(gpa, fixture_token_count_max, fixture_error_count_max);
        fixture.source = "";

        assert(fixture.raw.capacity() == fixture.tokens.items.capacity());
        assert(fixture.semantic.count() == 0);
    }

    fn deinit(fixture: *Fixture) void {
        const gpa = std.testing.allocator;

        assert(fixture.raw.capacity() == fixture_token_count_max);
        assert(fixture.tokens.items.capacity() == fixture_token_count_max);

        fixture.tree.deinit(gpa);
        fixture.tokens.deinit(gpa);
        fixture.semantic.deinit(gpa);
        fixture.raw.deinit(gpa);
        gpa.destroy(fixture.parser);
        fixture.events.deinit(gpa);
        fixture.* = undefined;
    }

    fn build(fixture: *Fixture, source: []const u8) !void {
        assert(source.len < fixture_token_count_max);
        assert(source.len > 0);

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

        try std.testing.expectEqual(.complete, parsed);

        const built = fixture.semantic.build(
            source,
            fixture.tokens.slice(),
            fixture.raw.const_slice(),
            &fixture.tree,
            &universe_test,
        );

        try std.testing.expectEqual(.complete, built);
    }

    fn binding_row(fixture: *const Fixture, index: u32, buffer: []u8) ![]const u8 {
        assert(index < none);

        const binding = fixture.semantic.at(index);

        assert(buffer.len == row_bytes_max);
        assert(binding.name.end() <= fixture.source.len);

        return std.mem.print(buffer, "{s} {s} scope {d} from {d}", .{
            title_of(Rules.BindingKind, binding.kind),
            binding.name.text(fixture.source),
            binding.scope,
            binding.from,
        });
    }

    fn reference_row(fixture: *const Fixture, index: u32, buffer: []u8) ![]const u8 {
        assert(index < none);

        const reference = fixture.semantic.reference_slice()[index];
        var bound: [row_bytes_max]u8 = undefined;

        assert(buffer.len == row_bytes_max);
        assert(reference.name.end() <= fixture.source.len);

        const resolution = switch (reference.resolution) {
            .bound => |binding| try std.mem.print(&bound, "Bound({d})", .{binding}),
            inline else => |_, tag| comptime camel_of(@tagName(tag)),
        };

        return std.mem.print(buffer, "{s} {s} {s} scope {d}{s}", .{
            reference.name.text(fixture.source),
            title_of(Rules.Namespace, reference.namespace),
            resolution,
            reference.scope,
            if (reference.context == .store) " store" else "",
        });
    }

    fn binding_matches(fixture: *const Fixture, pattern: *const Pattern) !u32 {
        var buffer: [row_bytes_max]u8 = undefined;
        var matched: u32 = 0;

        assert(pattern.prefix.len > 0);

        for (0..fixture.semantic.count()) |index| {
            const row = try fixture.binding_row(@intCast(index), &buffer);

            if (pattern.matches(row)) matched += 1;
        }

        assert(matched <= fixture.semantic.count());

        return matched;
    }

    fn reference_matches(fixture: *const Fixture, pattern: *const Pattern) !u32 {
        var buffer: [row_bytes_max]u8 = undefined;
        var matched: u32 = 0;
        const reference_count = fixture.semantic.reference_slice().len;

        assert(pattern.prefix.len > 0);

        for (0..reference_count) |index| {
            const row = try fixture.reference_row(@intCast(index), &buffer);

            if (pattern.matches(row)) matched += 1;
        }

        assert(matched <= reference_count);

        return matched;
    }
};

const Pattern = struct {
    contains: []const u8 = "",
    exact: bool = false,
    prefix: []const u8,
    suffix: []const u8 = "",

    fn matches(pattern: *const Pattern, row: []const u8) bool {
        assert(pattern.prefix.len > 0);
        assert(row.len > 0);

        if (pattern.exact) return std.mem.eql(u8, row, pattern.prefix);
        if (!std.mem.startsWith(u8, row, pattern.prefix)) return false;
        if (!std.mem.endsWith(u8, row, pattern.suffix)) return false;
        return std.mem.find(u8, row, pattern.contains) != null;
    }
};

const Events = EventsType(Kind);
const fixture_error_count_max: u32 = 1 << 8;
const fixture_event_count_max: u32 = 1 << 16;
const fixture_token_count_max: u32 = 1 << 14;
const row_bytes_max = 128;

const limits_fixture: Semantic.Limits = .{
    .binding_count_max = 1 << 10,
    .fact_count_max = 1 << 10,
    .reference_count_max = 1 << 12,
    .scope_count_max = 1 << 10,
};

const universe_test = [_][]const u8{
    "any",
    "append",
    "bool",
    "error",
    "false",
    "int",
    "len",
    "make",
    "nil",
    "panic",
    "string",
    "true",
};

fn title_of(comptime Enum: type, value: Enum) []const u8 {
    comptime assert(@typeInfo(@TypeOf(value)) == .@"enum");

    const title: []const u8 = switch (value) {
        inline else => |tag| comptime camel_of(@tagName(tag)),
    };

    assert(title.len > 0);
    assert(std.ascii.isUpper(title[0]));

    return title;
}

fn fixture_build(fixture: *Fixture, source: []const u8) !void {
    assert(source.len > 0);

    try fixture.init();
    errdefer fixture.deinit();

    try fixture.build(source);

    assert(fixture.semantic.scope_slice().len >= 2);
}

test "a short declaration reads the name that stood before it inside its own right hand side" {
    var fixture: Fixture = undefined;

    try fixture_build(&fixture, source_short_shadow);
    defer fixture.deinit();

    const outer: Pattern = .{ .exact = true, .prefix = "key Value Bound(0) scope 4" };
    const inner: Pattern = .{ .exact = true, .prefix = "key Value Bound(2) scope 4" };

    try std.testing.expect(try fixture.reference_matches(&outer) > 0);
    try std.testing.expect(try fixture.reference_matches(&inner) > 0);
}

test "a short declaration of a name the scope already holds reads it as well as writes it" {
    var fixture: Fixture = undefined;

    try fixture_build(&fixture, source_short_again);
    defer fixture.deinit();

    const written: Pattern = .{ .prefix = "Short one " };
    const read: Pattern = .{ .prefix = "one Value Bound(1) " };

    try std.testing.expectEqual(1, try fixture.binding_matches(&written));
    try std.testing.expectEqual(3, try fixture.reference_matches(&read));
}

test "a type parameter is read by the sibling that is written before the word declaring it" {
    var fixture: Fixture = undefined;

    try fixture_build(&fixture, source_type_parameters);
    defer fixture.deinit();

    const written: Pattern = .{ .prefix = "TypeParameter K ", .suffix = " from 0" };
    const read: Pattern = .{ .prefix = "K Value Bound(" };

    try std.testing.expect(try fixture.binding_matches(&written) > 0);
    try std.testing.expect(try fixture.reference_matches(&read) > 0);
}

test "a dot import leaves an unresolved name a maybe rather than a mistake" {
    var fixture: Fixture = undefined;

    try fixture_build(&fixture, source_dot_import);
    defer fixture.deinit();

    var dynamic = false;

    for (fixture.semantic.scope_slice()) |scope| dynamic = dynamic or scope.dynamic;

    const maybe: Pattern = .{ .prefix = "Pi Value Maybe " };

    try std.testing.expect(dynamic);
    try std.testing.expect(try fixture.reference_matches(&maybe) > 0);
}

test "a parameter and a result bind in the body rather than in the signature" {
    var fixture: Fixture = undefined;

    try fixture_build(&fixture, source_signature);
    defer fixture.deinit();

    const expected = [_][]const u8{
        "Function run scope 0 from 16",
        "Parameter one scope 3 from 20",
        "Result two scope 3 from 30",
    };

    var buffer: [row_bytes_max]u8 = undefined;

    try std.testing.expectEqual(expected.len, fixture.semantic.count());

    for (expected, 0..) |row, index| {
        try std.testing.expectEqualStrings(row, try fixture.binding_row(@intCast(index), &buffer));
    }

    const read: Pattern = .{ .exact = true, .prefix = "one Value Bound(1) scope 3" };

    try std.testing.expect(try fixture.reference_matches(&read) > 0);
}

test "a method takes a space of its own and leaves the universe where it was" {
    var fixture: Fixture = undefined;

    try fixture_build(&fixture, source_method);
    defer fixture.deinit();

    const method: Pattern = .{ .prefix = "Method string scope 0 " };
    const named: Pattern = .{ .prefix = "string" };
    const builtin: Pattern = .{ .contains = "Builtin", .prefix = "string" };

    try std.testing.expect(try fixture.binding_matches(&method) > 0);
    try std.testing.expect(try fixture.reference_matches(&named) > 0);

    try std.testing.expectEqual(
        try fixture.reference_matches(&named),
        try fixture.reference_matches(&builtin),
    );
}

test "a go binding kind maps onto the shared class" {
    var fixture: Fixture = undefined;

    try fixture_build(&fixture, source_method);
    defer fixture.deinit();

    var receivers: u32 = 0;

    for (0..fixture.semantic.count()) |index| {
        const held = fixture.semantic.at(@intCast(index));
        if (held.kind != .receiver) continue;

        const row = fixture.semantic.row(@intCast(index));

        try std.testing.expectEqual(BindingClass.parameter, row.class);
        try std.testing.expectEqual(held.node, row.node);

        receivers += 1;
    }

    try std.testing.expectEqual(1, receivers);
    try std.testing.expectEqual(BindingClass.other, Rules.class_of(.label));
    try std.testing.expectEqual(ScopeClass.module, fixture.semantic.scope_row(1).class);
    try std.testing.expectEqual(0, fixture.semantic.scope_row(1).parent.?);
    try std.testing.expectEqual(null, fixture.semantic.scope_row(0).parent);
}

test "an import names its package by the last segment that is not a version" {
    const source = "example.com/mod/v2";
    const specifier: Span = .{ .offset = 0, .length = source.len };

    try std.testing.expectEqualStrings("mod", package_of(source, specifier).text(source));
    const bare: Span = .{ .offset = 0, .length = 1 };

    try std.testing.expectEqualStrings("v", package_of("v", bare).text("v"));
    try std.testing.expect(versioned("v10"));
    try std.testing.expect(!versioned("v"));
    try std.testing.expect(!versioned("vx1"));
}

const source_dot_import =
    "package p\n\nimport (\n\t. \"math\"\n)\n\nfunc run() float64 {\n\treturn Pi\n}\n";

const source_method = "package p\n\ntype Directive struct{}\n\n" ++
    "func (d Directive) string() string {\n\treturn \"a\"\n}\n\n" ++
    "func use() string {\n\treturn string(nil)\n}\n";

const source_short_again = "package p\n\nfunc run() (int, int) {\n\tone, two := 1, 2\n" ++
    "\tone, three := 3, 4\n\treturn two + three - one\n}\n";

const source_short_shadow =
    "package p\n\ntype key struct{}\n\nfunc run() {\n\tkey := make(key)\n\t_ = key\n}\n";

const source_signature =
    "package p\n\nfunc run(one int) (two int) {\n\ttwo = one\n\n\treturn two\n}\n";

const source_type_parameters = "package p\n\n" ++
    "func run[Map ~map[K]V, K comparable, V any](held Map) {\n\t_ = held\n}\n";
