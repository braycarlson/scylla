const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const BindingClass = @import("../semantic.zig").BindingClass;
const EventsType = @import("../tree.zig").EventsType;
const Fact = @import("../fact.zig").Fact;
const FactKind = @import("../fact.zig").FactKind;
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
const Context = @import("../semantic.zig").Context;
const Limits = @import("../semantic.zig").Limits;
const Reference = Semantic.Reference;
const Resolution = @import("../semantic.zig").Resolution;
pub const Semantic = SemanticType(Rules);
const scope_depth_max = @import("../semantic.zig").scope_depth_max;

const Rules = struct {
    pub const BindingExtension = void;
    pub const Extension = void;
    pub const ScopeExtension = void;
    pub const pick: Pick = .newest;
    pub const scopes_in_walk_order: bool = true;

    pub const BindingKind = enum {
        associated_const,
        associated_function,
        associated_type,
        @"const",
        const_parameter,
        @"enum",
        field,
        function,
        import,
        label,
        lifetime,
        local,
        macro,
        module,
        parameter,
        static,
        @"struct",
        trait,
        trait_alias,
        type_alias,
        type_parameter,
        @"union",
        variant,

        pub fn hoists(kind: BindingKind) bool {
            const result = kind != .local and kind != .macro;

            if (kind == .local) assert(!result);
            if (kind == .import) assert(result);

            return result;
        }

        pub fn namespace(kind: BindingKind) Namespace {
            const result: Namespace = switch (kind) {
                .label => .label,
                .lifetime => .lifetime,
                .macro => .macro,
                .associated_type,
                .@"enum",
                .module,
                .trait,
                .trait_alias,
                .type_alias,
                .type_parameter,
                => .type,
                .associated_const,
                .associated_function,
                .@"const",
                .const_parameter,
                .field,
                .function,
                .import,
                .local,
                .parameter,
                .static,
                .@"struct",
                .@"union",
                .variant,
                => .value,
            };

            if (kind == .module) assert(result == .type);
            if (kind == .@"struct") assert(result == .value);

            return result;
        }

        pub fn opens(kind: BindingKind, wanted: Namespace) bool {
            const result = switch (kind) {
                .import => wanted != .label and wanted != .lifetime,
                .@"struct", .@"union" => wanted == .type or wanted == .value,
                .associated_const, .associated_function, .associated_type => false,
                .@"const",
                .const_parameter,
                .@"enum",
                .field,
                .function,
                .label,
                .lifetime,
                .local,
                .macro,
                .module,
                .parameter,
                .static,
                .trait,
                .trait_alias,
                .type_alias,
                .type_parameter,
                .variant,
                => kind.namespace() == wanted,
            };

            if (kind == .associated_function) assert(!result);
            if (wanted == kind.namespace()) assert(result or kind.associated());

            return result;
        }

        fn associated(kind: BindingKind) bool {
            const result = switch (kind) {
                .associated_const, .associated_function, .associated_type => true,
                else => false,
            };

            if (result) assert(kind.hoists());
            if (kind == .local) assert(!result);

            return result;
        }
    };

    pub const Namespace = enum {
        label,
        lifetime,
        macro,
        type,
        value,
    };

    pub const Options = struct {
        globals: []const []const u8,
    };

    pub const ReferenceExtension = struct {
        generic: bool,
        qualified: bool,
    };

    pub const ScopeKind = enum {
        block,
        function,
        item,
        module,

        pub fn is_ordered(kind: ScopeKind) bool {
            const result = kind == .block or kind == .function;

            if (kind == .module) assert(!result);
            if (kind == .block) assert(result);

            return result;
        }
    };

    pub fn after_resolve(
        semantic: *const Semantic,
        source: []const u8,
        options: *const Options,
    ) void {
        assert(semantic.scope_count() >= 1);
        assert(source.len <= std.math.maxInt(u32));
        assert(options.globals.len <= std.math.maxInt(u32));
    }

    pub fn binds_in(kind: BindingKind, wanted: Namespace) bool {
        return kind.opens(wanted);
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
        assert(universe.len <= std.math.maxInt(u32));

        semantic.clear();
        semantic.scope_root(.module, 0, {});

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

        assert(semantic.scope_count() >= 1);
        assert(semantic.scope_at(0).parent == none);

        return builder.outcome;
    }

    pub fn chains_with(previous: BindingKind, kind: BindingKind) bool {
        return previous.namespace() == kind.namespace();
    }

    pub fn class_of(kind: BindingKind) BindingClass {
        const class: BindingClass = switch (kind) {
            .associated_const, .@"const", .static => .constant,
            .associated_function => .method,
            .associated_type,
            .const_parameter,
            .@"enum",
            .@"struct",
            .trait,
            .trait_alias,
            .type_alias,
            .type_parameter,
            .@"union",
            => .type,
            .field => .field,
            .function => .function,
            .import => .import,
            .label, .lifetime, .macro, .module => .other,
            .local => .local,
            .parameter => .parameter,
            .variant => .variant,
        };

        if (kind == .associated_function) assert(class == .method);
        if (kind == .module) assert(class == .other);

        return class;
    }

    pub fn crosses(scope: ScopeKind) bool {
        assert(@backingInt(scope) < @typeInfo(ScopeKind).@"enum".field_names.len);

        return false;
    }

    pub fn fallback(reference: *const Reference, dynamic_seen: bool) Resolution {
        assert(reference.resolution == .unresolved);
        assert(reference.scope != none);

        if (reference.ext.qualified) return .external;
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
        assert(@backingInt(kind) < @typeInfo(BindingKind).@"enum".field_names.len);
        assert(@backingInt(scope) < @typeInfo(ScopeKind).@"enum".field_names.len);

        return true;
    }

    pub fn namespace_of(kind: BindingKind) Namespace {
        return kind.namespace();
    }

    pub fn order(reference: *const Reference, scope: ScopeKind, position: Position) Order {
        assert(reference.scope != none);
        assert(!position.redirected);
        assert(@backingInt(scope) < @typeInfo(ScopeKind).@"enum".field_names.len);

        return .from;
    }

    pub fn retry_namespace(reference: *const Reference) ?Namespace {
        assert(reference.scope != none);

        if (!reference.ext.generic) return null;
        if (reference.namespace == .macro) return null;
        if (reference.namespace == .value) return null;
        return .value;
    }

    pub fn scope_class_of(kind: ScopeKind) ScopeClass {
        const class: ScopeClass = switch (kind) {
            .block => .block,
            .function => .function,
            .item => .other,
            .module => .module,
        };

        if (kind == .module) assert(class == .module);
        if (kind == .item) assert(class == .other);

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

        builder.stack[0] = 0;
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
        assert(index < step_max);

        var iterator = builder.children(node);

        for (0..index) |_| {
            _ = iterator.next() orelse return null;
        }

        return iterator.next();
    }

    fn child_of(builder: *const Builder, node: ?u32, kind: Kind) ?u32 {
        if (node) |held| assert(held < std.math.maxInt(u32));

        const held = node orelse return null;
        var iterator = builder.children(held);

        assert(kind.is_node());

        for (0..builder.tree.count()) |_| {
            const child = iterator.next() orelse break;
            if (builder.kind_of(child) == kind) return child;
        }

        return null;
    }

    fn child_count_of(builder: *const Builder, node: u32, kind: ?Kind) u32 {
        assert(node < none);
        if (kind) |held| assert(held.is_node());

        var iterator = builder.children(node);
        var found: u32 = 0;

        for (0..builder.tree.count()) |_| {
            const child = iterator.next() orelse break;

            if (kind) |wanted| {
                if (builder.kind_of(child) == wanted) found += 1;
            } else {
                found += 1;
            }
        }

        assert(iterator.node == null);
        assert(found < builder.tree.count());

        return found;
    }

    fn parent_of(builder: *const Builder, node: ?u32) ?u32 {
        if (node) |held| assert(held < std.math.maxInt(u32));

        const held = node orelse return null;

        assert(held < builder.tree.count());

        const parent = builder.tree.parent_of(held);

        if (parent) |above| assert(above < held);

        return parent;
    }

    fn ancestor_of(builder: *const Builder, node: ?u32, one: Kind, two: Kind) ?u32 {
        if (node) |held| assert(held < std.math.maxInt(u32));

        var held = node;

        assert(one.is_node());
        assert(two.is_node());

        for (0..step_max) |_| {
            const above = held orelse return null;
            const kind = builder.kind_of(above);
            if (kind == one) return above;
            if (kind == two) return above;

            held = builder.parent_of(above);
        }

        return null;
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

    fn holds(builder: *const Builder, node: u32, kind: Kind) bool {
        assert(node < none);
        assert(kind.is_token());

        const held = builder.tree.at(node);

        assert(held.token_start <= held.token_end);
        assert(held.token_end <= builder.raw.len);

        for (builder.raw[held.token_start..held.token_end]) |raw| {
            if (raw == kind) return true;
        }

        return false;
    }

    fn enter(builder: *Builder, node: u32) void {
        assert(node < none);

        const kind = builder.kind_of(node);

        builder.before(node, kind);

        if (scope_kind_of(kind)) |held| {
            if (builder.written_of(node, kind)) |written| {
                builder.push(written);
            } else {
                builder.open(node, held);
            }
        }

        builder.after(node, kind);

        assert(builder.depth > 0);
    }

    fn written_of(builder: *Builder, node: u32, kind: Kind) ?u32 {
        assert(builder.depth > 0);
        assert(node < builder.tree.count());

        if (kind != .block) return null;

        const parent = builder.parent_of(node) orelse return null;
        if (!guards(builder.kind_of(parent))) return null;

        const body = builder.child_of(parent, .block) orelse return null;
        if (body != node) return null;

        const held = builder.pending[builder.depth - 1];

        builder.pending[builder.depth - 1] = none;

        if (held == none) return null;
        assert(held < std.math.maxInt(u32));

        return held;
    }

    fn leave(builder: *Builder, node: u32) void {
        assert(builder.depth > 0);
        assert(node < none);

        if (scope_kind_of(builder.kind_of(node)) == null) return;

        if (builder.depth > 1) builder.depth -= 1;

        assert(builder.depth >= 1);
    }

    fn open(builder: *Builder, node: u32, kind: Rules.ScopeKind) void {
        assert(node < none);
        assert(scope_kind_of(builder.kind_of(node)) == kind);

        const parent = builder.scope_current();
        const index = builder.scope_under(parent, node, kind) orelse return;

        builder.push(index);

        assert(index > parent);
        assert(builder.semantic.scope_at(index).node == node);
    }

    fn scope_under(builder: *Builder, parent: u32, node: u32, kind: Rules.ScopeKind) ?u32 {
        assert(node < none);
        if (kind == .module) assert(builder.kind_of(node) == .item_mod);

        const semantic = builder.semantic;
        const index = semantic.scope_count();

        assert(parent < index);

        const opened = semantic.scope_open(parent, kind, node, {}) catch |err| switch (err) {
            error.Truncated => {
                if (builder.outcome == .complete) builder.outcome = .{ .truncated = .scopes };

                return null;
            },
        };

        assert(opened == index);
        assert(semantic.scope_count() == index + 1);

        return opened;
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
        assert(node < builder.tree.count());
        assert(builder.depth > 0);
        assert(kind.is_node());

        switch (kind) {
            .item_extern_crate => builder.extern_crate(node),
            .item_macro => builder.macro_rules(node),
            .label => builder.tick(node, .label),
            .lifetime_param => builder.tick(node, .lifetime),
            .pat_ident => builder.pattern(node),
            .receiver => builder.receiver(node),
            .use_glob => builder.glob(node),
            .use_name, .use_rename => builder.import(node, kind),
            else => if (item_kind_of(kind)) |held| builder.item(node, held),
        }
    }

    fn after(builder: *Builder, node: u32, kind: Kind) void {
        assert(node < builder.tree.count());
        assert(builder.depth > 0);
        assert(kind.is_node());

        switch (kind) {
            .expr_for_loop, .expr_if, .expr_while => builder.guarded(node),
            .ident => builder.ident_reference(node),
            .lifetime => builder.lifetime_reference(node),
            else => {},
        }
    }

    fn guarded(builder: *Builder, node: u32) void {
        assert(guards(builder.kind_of(node)));

        const body = builder.child_of(node, .block) orelse return;
        const parent = builder.scope_current();
        const index = builder.scope_under(parent, body, .block) orelse return;

        builder.pending[builder.depth - 1] = index;

        assert(index > parent);
    }

    fn item(builder: *Builder, node: u32, kind: Rules.BindingKind) void {
        assert(kind != .import);
        assert(kind != .local);
        assert(node < none);

        const held = builder.named_by(node) orelse return;

        _ = builder.record(kind, builder.span_of(held), held);
    }

    fn named_by(builder: *const Builder, node: u32) ?u32 {
        assert(node < builder.tree.count());

        const signature = builder.child_of(node, .signature);
        const held = builder.child_of(signature orelse node, .ident);

        if (held) |name| assert(name > node);

        return held;
    }

    fn macro_rules(builder: *Builder, node: u32) void {
        assert(builder.kind_of(node) == .item_macro);

        const held = builder.child_of(builder.child_of(node, .macro), .ident) orelse return;
        const from = if (builder.holds(node, .macro_keyword)) 0 else builder.end_of(node);

        _ = builder.record_within(builder.scope_current(), &.{
            .from = from,
            .kind = .macro,
            .name = builder.span_of(held),
            .node = held,
        });
    }

    fn extern_crate(builder: *Builder, node: u32) void {
        assert(builder.kind_of(node) == .item_extern_crate);

        const held = builder.child_at(node, 0) orelse return;
        if (builder.kind_of(held) != .ident) return;

        const renamed = builder.child_at(node, 1) orelse held;
        const local = if (builder.kind_of(renamed) == .ident) renamed else held;
        const name = builder.span_of(local);
        const binding = builder.record(.import, name, held);
        const specifier = builder.span_of(held);

        builder.fact_push(&.{
            .binding = .of(binding),
            .kind = .import_named,
            .local = name,
            .remote = specifier,
            .specifier = specifier,
        });
    }

    fn import(builder: *Builder, node: u32, kind: Kind) void {
        assert(kind == .use_name or kind == .use_rename);
        assert(node < none);

        const first = builder.child_at(node, 0) orelse return;
        if (builder.kind_of(first) != .ident) return;

        const held = switch (kind) {
            .use_rename => builder.child_at(node, 1) orelse return,
            else => first,
        };

        if (builder.kind_of(held) != .ident) return;

        const name = builder.span_of(held);
        const binding = builder.record(.import, name, held);

        builder.fact_push(&.{
            .binding = .of(binding),
            .kind = builder.import_kind(node),
            .local = name,
            .remote = builder.span_of(first),
            .specifier = builder.prefix_of(node),
        });
    }

    fn glob(builder: *Builder, node: u32) void {
        const scope = builder.scope_current();

        assert(builder.kind_of(node) == .use_glob);

        builder.semantic.scope_mark_dynamic(scope);

        builder.fact_push(&.{
            .binding = .none,
            .kind = .import_namespace,
            .local = Span.empty,
            .remote = Span.empty,
            .specifier = builder.prefix_of(node),
        });

        assert(builder.semantic.scope_at(scope).dynamic);
    }

    fn import_kind(builder: *const Builder, node: u32) FactKind {
        assert(node < none);

        const held = builder.ancestor_of(builder.parent_of(node), .item_use, .item_use);
        const item_use = held orelse return .import_named;

        assert(item_use < node);
        assert(builder.kind_of(item_use) == .item_use);

        if (builder.holds(item_use, .pub_keyword)) return .reexport;
        return .import_named;
    }

    fn prefix_of(builder: *const Builder, node: u32) Span {
        assert(node < none);

        var held = builder.parent_of(node);
        var first: ?u32 = null;
        var last: ?u32 = null;

        for (0..step_max) |_| {
            const above = held orelse break;
            const kind = builder.kind_of(above);

            switch (kind) {
                .use_path => {
                    const named = builder.child_of(above, .ident) orelse break;

                    if (last == null) last = named;

                    first = named;
                },
                .use_group => {},
                else => break,
            }

            held = builder.parent_of(above);
        }

        const outer = first orelse return Span.empty;
        const inner = last orelse return Span.empty;

        assert(outer <= inner);

        return Span.between(builder.span_of(outer).offset, builder.end_of(inner));
    }

    fn tick(builder: *Builder, node: u32, kind: Rules.BindingKind) void {
        assert(kind == .label or kind == .lifetime);
        assert(node < builder.tree.count());

        const held = builder.child_of(node, .lifetime) orelse return;

        _ = builder.record(kind, builder.span_of(held), held);
    }

    fn receiver(builder: *Builder, node: u32) void {
        assert(builder.kind_of(node) == .receiver);

        const held = builder.self_of(node) orelse return;

        assert(held > node);

        _ = builder.record(.parameter, builder.span_of(held), held);
    }

    fn self_of(builder: *const Builder, node: u32) ?u32 {
        assert(node < none);

        var stack: [descent_max]u32 = undefined;
        var depth: u32 = 1;

        stack[0] = node;

        for (0..step_max) |_| {
            if (depth == 0) return null;

            depth -= 1;

            const held = stack[depth];

            if (builder.kind_of(held) == .ident) {
                if (std.mem.eql(u8, builder.text_of(builder.span_of(held)), "self")) return held;
            }

            var iterator = builder.children(held);

            for (0..builder.tree.count()) |_| {
                const child = iterator.next() orelse break;

                if (depth >= descent_max) return null;

                stack[depth] = child;
                depth += 1;
            }

            assert(depth <= descent_max);
        }

        return null;
    }

    fn pattern(builder: *Builder, node: u32) void {
        assert(node < none);

        const held = builder.child_of(node, .ident) orelse return;
        const name = builder.span_of(held);

        if (builder.constant(name)) {
            if (builder.child_count_of(node, null) == 1) {
                builder.reference_push(&.{
                    .context = .load,
                    .generic = false,
                    .name = name,
                    .namespace = .value,
                    .node = held,
                    .qualified = false,
                });

                return;
            }
        }

        const binder = builder.binder_of(node);
        const kind = builder.kind_of(binder);

        if (parameterizes(kind)) {
            _ = builder.record(.parameter, name, held);

            return;
        }

        const pending = if (kind == .expr_for_loop) builder.pending[builder.depth - 1] else none;
        const scope = if (pending == none) builder.scope_current() else pending;
        const from = if (pending == none) builder.opening_of(binder, kind) else name.offset;

        _ = builder.record_within(scope, &.{
            .from = from,
            .kind = .local,
            .name = name,
            .node = held,
        });
    }

    fn constant(builder: *const Builder, name: Span) bool {
        assert(name.length <= std.math.maxInt(u32) - name.offset);

        const text = builder.text_of(name);
        const result = text.len > 0 and std.ascii.isUpper(text[0]);

        if (result) assert(name.length > 0);
        if (text.len == 0) assert(!result);

        return result;
    }

    fn binder_of(builder: *const Builder, node: u32) ?u32 {
        assert(node < none);

        var held = builder.parent_of(node);

        for (0..step_max) |_| {
            const above = held orelse return null;
            if (binds(builder.kind_of(above))) return above;

            held = builder.parent_of(above);
        }

        return null;
    }

    fn opening_of(builder: *const Builder, binder: ?u32, kind: Kind) u32 {
        if (binder) |held| assert(held < std.math.maxInt(u32));

        const held = binder orelse return 0;

        assert(kind == builder.kind_of(held));

        if (kind == .arm) {
            const first = builder.child_at(held, 0) orelse return builder.end_of(held);
            return builder.end_of(first);
        }

        if (kind == .expr_for_loop) {
            if (builder.child_of(held, .block)) |body| return builder.span_of(body).offset;
        }

        return builder.end_of(held);
    }

    fn lifetime_reference(builder: *Builder, node: u32) void {
        assert(node < none);

        const parent = builder.kind_of(builder.parent_of(node));

        assert(builder.kind_of(node) == .lifetime);

        if (parent == .label) return;
        if (parent == .lifetime_param) return;

        const namespace: Rules.Namespace = switch (parent) {
            .expr_break, .expr_continue => .label,
            else => .lifetime,
        };

        builder.reference_push(&.{
            .context = .load,
            .generic = false,
            .name = builder.span_of(node),
            .namespace = namespace,
            .node = node,
            .qualified = false,
        });
    }

    fn ident_reference(builder: *Builder, node: u32) void {
        assert(builder.kind_of(node) == .ident);

        const parent = builder.parent_of(node) orelse return;
        const kind = builder.kind_of(parent);
        if (kind == .use_path) return builder.rooted(node, parent);
        if (kind != .path_segment) return;
        if ((builder.child_at(parent, 0) orelse none) != node) return;

        const path = builder.parent_of(parent) orelse return;
        if ((builder.child_of(path, .path_segment) orelse none) != parent) return;
        if (builder.ancestor_of(path, .attribute, .vis_restricted) != null) return;
        if (builder.ancestor_of(path, .receiver, .receiver) != null) return;

        const owner = builder.parent_of(path);
        const held = builder.kind_of(owner);

        if (held == .macro) {
            if (builder.kind_of(builder.parent_of(owner)) == .item_macro) return;
        }

        const qualified = builder.child_count_of(path, .path_segment) > 1;
        const namespace: Rules.Namespace = if (qualified) .type else path_namespace_of(held);

        builder.reference_push(&.{
            .context = if (builder.stores(owner)) .store else .load,
            .generic = builder.generic_of(path),
            .name = builder.span_of(node),
            .namespace = namespace,
            .node = node,
            .qualified = qualified,
        });
    }

    fn generic_of(builder: *const Builder, path: u32) bool {
        assert(path < builder.tree.count());

        var held = builder.parent_of(path);

        for (0..step_max) |_| {
            const above = held orelse return false;
            const kind = builder.kind_of(above);

            if (kind == .type_path) {
                const outer = builder.kind_of(builder.parent_of(above));
                if (outer == .path_segment) return true;
                if (outer == .type_path) return true;
            }

            switch (kind.category()) {
                .name, .type => held = builder.parent_of(above),
                .call => return true,
                else => return false,
            }
        }

        return false;
    }

    fn rooted(builder: *Builder, node: u32, parent: u32) void {
        assert(builder.kind_of(parent) == .use_path);
        assert(node < none);

        const named = builder.child_of(parent, .ident) orelse return;
        if (named != node) return;
        if (builder.kind_of(builder.parent_of(parent)) != .item_use) return;

        builder.reference_push(&.{
            .context = .load,
            .generic = false,
            .name = builder.span_of(node),
            .namespace = .type,
            .node = node,
            .qualified = true,
        });
    }

    fn stores(builder: *const Builder, node: ?u32) bool {
        if (node) |held| assert(held < std.math.maxInt(u32));

        const held = node orelse return false;
        if (builder.kind_of(held) != .expr_path) return false;

        const parent = builder.parent_of(held) orelse return false;
        if (builder.kind_of(parent) != .expr_assign) return false;

        const first = builder.child_at(parent, 0) orelse return false;

        assert(first > parent);

        return first == held;
    }

    fn reference_push(builder: *Builder, referred: *const Referred) void {
        assert(referred.name.end() <= builder.source.len);
        assert(referred.node < builder.tree.count());

        if (std.mem.eql(u8, builder.text_of(referred.name), "_")) return;

        const reference_count_before = builder.semantic.reference_count();

        builder.semantic.refer(builder.source, &.{
            .context = referred.context,
            .dead_zone = false,
            .ext = .{ .generic = referred.generic, .qualified = referred.qualified },
            .name = referred.name,
            .name_hash = 0,
            .namespace = referred.namespace,
            .node = referred.node,
            .resolution = .unresolved,
            .scope = builder.scope_current(),
        }) catch |err| switch (err) {
            error.Truncated => {
                if (builder.outcome == .complete) builder.outcome = .{ .truncated = .references };

                return;
            },
        };

        assert(builder.semantic.reference_count() == reference_count_before + 1);
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

    fn record(builder: *Builder, kind: Rules.BindingKind, name: Span, node: u32) ?u32 {
        assert(name.end() <= builder.source.len);
        assert(node < builder.tree.count());

        return builder.record_within(builder.scope_current(), &.{
            .from = name.offset,
            .kind = kind,
            .name = name,
            .node = node,
        });
    }

    fn record_within(builder: *Builder, scope: u32, declared: *const Declared) ?u32 {
        const semantic = builder.semantic;
        const text = builder.text_of(declared.name);

        assert(scope < semantic.scope_count());
        assert(declared.node < builder.tree.count());

        if (std.mem.eql(u8, text, "_")) return null;

        const index = semantic.declare(builder.source, scope, &.{
            .dead_zone_end = none,
            .ext = {},
            .from = if (declared.kind.hoists()) 0 else declared.from,
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

const Referred = struct {
    context: Context,
    generic: bool,
    name: Span,
    namespace: Rules.Namespace,
    node: u32,
    qualified: bool,
};

const descent_max: u32 = 1 << 6;
const step_max: u32 = 1 << 12;

comptime {
    assert(scope_depth_max < step_max);
    assert(descent_max < step_max);
}

fn scope_kind_of(kind: Kind) ?Rules.ScopeKind {
    assert(kind.is_node());

    const result: ?Rules.ScopeKind = switch (kind) {
        .item_mod => .module,
        .expr_closure, .foreign_item_fn, .impl_item_fn, .item_fn, .trait_item_fn => .function,
        .item_enum,
        .item_impl,
        .item_struct,
        .item_trait,
        .item_trait_alias,
        .item_type,
        .item_union,
        => .item,
        .arm, .block, .expr_for_loop, .expr_if, .expr_loop, .expr_while => .block,
        else => null,
    };

    if (result) |held| assert(held != .module or kind == .item_mod);
    if (guards(kind)) assert(result.? == .block);

    return result;
}

fn item_kind_of(kind: Kind) ?Rules.BindingKind {
    assert(kind.is_node());

    const result: ?Rules.BindingKind = switch (kind) {
        .const_param => .const_parameter,
        .field => .field,
        .foreign_item_fn, .item_fn => .function,
        .foreign_item_static, .item_static => .static,
        .foreign_item_type, .item_type => .type_alias,
        .impl_item_const, .trait_item_const => .associated_const,
        .impl_item_fn, .trait_item_fn => .associated_function,
        .impl_item_type, .trait_item_type => .associated_type,
        .item_const => .@"const",
        .item_enum => .@"enum",
        .item_mod => .module,
        .item_struct => .@"struct",
        .item_trait => .trait,
        .item_trait_alias => .trait_alias,
        .item_union => .@"union",
        .type_param => .type_parameter,
        .variant => .variant,
        else => null,
    };

    if (result) |held| assert(held.hoists());
    if (kind == .item_macro) assert(result == null);

    return result;
}

fn guards(kind: Kind) bool {
    assert(kind.is_node());

    const result = switch (kind) {
        .expr_for_loop, .expr_if, .expr_while => true,
        else => false,
    };

    if (result) assert(kind.is_node());
    if (kind == .expr_loop) assert(!result);

    return result;
}

fn binds(kind: Kind) bool {
    assert(kind.is_node());

    const result = switch (kind) {
        .arm, .expr_for_loop, .expr_let, .local => true,
        else => parameterizes(kind),
    };

    if (parameterizes(kind)) assert(result);
    if (kind == .block) assert(!result);

    return result;
}

fn parameterizes(kind: Kind) bool {
    assert(kind.is_node());

    const result = switch (kind) {
        .expr_closure,
        .foreign_item_fn,
        .impl_item_fn,
        .item_fn,
        .signature,
        .trait_item_fn,
        => true,
        else => false,
    };

    if (result) assert(kind.is_node());
    if (kind == .expr_let) assert(!result);

    return result;
}

fn path_namespace_of(kind: Kind) Rules.Namespace {
    assert(kind.is_node());

    const result: Rules.Namespace = switch (kind) {
        .macro => .macro,
        .constraint,
        .expr_struct,
        .item_impl,
        .pat_struct,
        .trait_bound,
        .type_path,
        => .type,
        else => .value,
    };

    if (kind == .macro) assert(result == .macro);
    if (kind == .expr_path) assert(result == .value);

    return result;
}

const Expected = struct {
    bindings: []const []const u8,
    facts: []const []const u8,
    references: []const []const u8,
    scopes: []const []const u8,
};

const Fixture = struct {
    events: Events,
    parser: *Parser,
    raw: ArrayType(Kind),
    semantic: Semantic,
    source: []const u8,
    tokens: Tokens,
    tree: Tree,

    fn init(fixture: *Fixture, limits: *const Semantic.Limits) !void {
        const gpa = std.testing.allocator;

        try fixture.events.init(gpa, fixture_event_count_max);
        errdefer fixture.events.deinit(gpa);

        fixture.parser = try gpa.create(Parser);
        errdefer gpa.destroy(fixture.parser);

        fixture.raw = try .init(gpa, fixture_token_count_max);
        errdefer fixture.raw.deinit(gpa);

        try fixture.semantic.init(gpa, limits);
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

    fn build(fixture: *Fixture, source: []const u8) !Structure {
        assert(source.len < fixture_token_count_max);

        fixture.source = source;

        fixture.tokens.clear();

        try lex(source, &fixture.tokens);
        try raw_of(Kind, fixture.tokens.slice(), &fixture.raw);

        assert(fixture.tokens.count() == fixture.raw.count());

        const parsed = fixture.parser.build(
            source,
            fixture.tokens.slice(),
            fixture.raw.const_slice(),
            &fixture.events,
            &fixture.tree,
        );

        try std.testing.expectEqual(.complete, parsed);

        return fixture.semantic.build(
            source,
            fixture.tokens.slice(),
            fixture.raw.const_slice(),
            &fixture.tree,
            &universe_test,
        );
    }

    fn expect(fixture: *const Fixture, expected: *const Expected) !void {
        assert(expected.scopes.len > 0);
        assert(fixture.semantic.scope_slice().len > 0);

        try fixture.scopes_expect(expected.scopes);
        try fixture.bindings_expect(expected.bindings);
        try fixture.references_expect(expected.references);
        try fixture.facts_expect(expected.facts);
    }

    fn scopes_expect(fixture: *const Fixture, expected: []const []const u8) !void {
        const scopes = fixture.semantic.scope_slice();
        var buffer: [row_bytes_max]u8 = undefined;

        assert(scopes.len <= limits_fixture.scope_count_max);
        assert(fixture.source.len > 0);

        try std.testing.expectEqual(expected.len, scopes.len);

        for (scopes, expected) |scope, row| {
            const kind = title_of(Rules.ScopeKind, scope.kind);
            const dynamic = if (scope.dynamic) " glob" else "";

            const actual = if (scope.parent == none)
                try std.mem.print(&buffer, "{s} none{s}", .{ kind, dynamic })
            else
                try std.mem.print(&buffer, "{s} under {d}{s}", .{ kind, scope.parent, dynamic });

            try std.testing.expectEqualStrings(row, actual);
        }
    }

    fn bindings_expect(fixture: *const Fixture, expected: []const []const u8) !void {
        const bindings = fixture.semantic.binding_slice();
        var buffer: [row_bytes_max]u8 = undefined;

        assert(bindings.len <= limits_fixture.binding_count_max);
        assert(fixture.source.len > 0);

        try std.testing.expectEqual(expected.len, bindings.len);

        for (bindings, expected) |binding, row| {
            const actual = try std.mem.print(&buffer, "{s} {s} scope {d} from {d}", .{
                title_of(Rules.BindingKind, binding.kind),
                binding.name.text(fixture.source),
                binding.scope,
                binding.from,
            });

            try std.testing.expectEqualStrings(row, actual);
        }
    }

    fn references_expect(fixture: *const Fixture, expected: []const []const u8) !void {
        const references = fixture.semantic.reference_slice();
        var buffer: [row_bytes_max]u8 = undefined;
        var bound: [row_bytes_max]u8 = undefined;

        assert(references.len <= limits_fixture.reference_count_max);
        assert(fixture.source.len > 0);

        try std.testing.expectEqual(expected.len, references.len);

        for (references, expected) |reference, row| {
            const resolution = switch (reference.resolution) {
                .bound => |index| try std.mem.print(&bound, "Bound({d})", .{index}),
                .builtin => "Builtin",
                .external => "External",
                .maybe => "Maybe",
                .unresolved => "Unresolved",
            };

            const actual = try std.mem.print(&buffer, "{s} {s} {s} scope {d}{s}", .{
                reference.name.text(fixture.source),
                title_of(Rules.Namespace, reference.namespace),
                resolution,
                reference.scope,
                if (reference.context == .store) " store" else "",
            });

            try std.testing.expectEqualStrings(row, actual);
        }
    }

    fn facts_expect(fixture: *const Fixture, expected: []const []const u8) !void {
        const facts = fixture.semantic.fact_slice();
        var buffer: [row_bytes_max]u8 = undefined;

        assert(facts.len <= limits_fixture.fact_count_max);
        assert(fixture.source.len > 0);

        try std.testing.expectEqual(expected.len, facts.len);

        for (facts, expected) |fact, row| {
            const actual = try std.mem.print(&buffer, "{s} {s} {s} {s}", .{
                fact.kind.name(),
                fixture.field_of(fact.local),
                fixture.field_of(fact.remote),
                fixture.field_of(fact.specifier),
            });

            try std.testing.expectEqualStrings(row, actual);
        }
    }

    fn field_of(fixture: *const Fixture, span: Span) []const u8 {
        assert(span.end() <= fixture.source.len);

        if (span.offset == 0) {
            if (span.length == 0) return ".";
        }

        const text = span.text(fixture.source);

        assert(text.len > 0);

        return text;
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

const limits_starved: Semantic.Limits = .{
    .binding_count_max = 4,
    .fact_count_max = 4,
    .reference_count_max = 4,
    .scope_count_max = 4,
};

const universe_test = [_][]const u8{
    "None",
    "Option",
    "Self",
    "Some",
    "bool",
    "false",
    "len",
    "size_of",
    "speak",
    "str",
    "swap",
    "true",
    "u8",
    "usize",
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

fn fixture_expect(source: []const u8, expected: *const Expected) !void {
    assert(source.len > 0);
    assert(expected.scopes.len > 0);

    var fixture: Fixture = undefined;

    try fixture.init(&limits_fixture);
    defer fixture.deinit();

    try std.testing.expectEqual(.complete, try fixture.build(source));
    try fixture.expect(expected);
}

test "a generic names its parameters for itself and no sibling" {
    try fixture_expect(generics_source, &.{
        .bindings = &generics_bindings,
        .facts = &generics_facts,
        .references = &generics_references,
        .scopes = &generics_scopes,
    });
}

test "an item is read from anywhere in the block that holds it" {
    try fixture_expect(items_source, &.{
        .bindings = &items_bindings,
        .facts = &items_facts,
        .references = &items_references,
        .scopes = &items_scopes,
    });
}

test "a label is read inside the loop that writes it" {
    try fixture_expect(labels_source, &.{
        .bindings = &labels_bindings,
        .facts = &labels_facts,
        .references = &labels_references,
        .scopes = &labels_scopes,
    });
}

test "a local opens at the end of the statement that writes it" {
    try fixture_expect(locals_source, &.{
        .bindings = &locals_bindings,
        .facts = &locals_facts,
        .references = &locals_references,
        .scopes = &locals_scopes,
    });
}

test "a macro is read below its definition and nowhere above it" {
    try fixture_expect(macros_source, &.{
        .bindings = &macros_bindings,
        .facts = &macros_facts,
        .references = &macros_references,
        .scopes = &macros_scopes,
    });
}

test "a first segment this file does not declare names another crate" {
    try fixture_expect(paths_source, &.{
        .bindings = &paths_bindings,
        .facts = &paths_facts,
        .references = &paths_references,
        .scopes = &paths_scopes,
    });
}

test "a use tree binds its last segment and records the path it came from" {
    try fixture_expect(uses_source, &.{
        .bindings = &uses_bindings,
        .facts = &uses_facts,
        .references = &uses_references,
        .scopes = &uses_scopes,
    });
}

test "a bare call reads past an associated item of the same name" {
    var fixture: Fixture = undefined;

    try fixture.init(&limits_fixture);
    defer fixture.deinit();

    try std.testing.expectEqual(.complete, try fixture.build(bare_call_source));

    var found: ?Reference = null;

    for (fixture.semantic.reference_slice()) |reference| {
        if (reference.namespace != .value) continue;

        if (std.mem.eql(u8, reference.name.text(bare_call_source), "helper")) {
            found = reference;

            break;
        }
    }

    const index = found.?.resolution.bound;

    try std.testing.expectEqual(Rules.BindingKind.function, fixture.semantic.at(index).kind);
}

test "every reference resolves into a scope on its own chain" {
    const sources = [_][]const u8{
        generics_source,
        items_source,
        labels_source,
        locals_source,
        macros_source,
        paths_source,
        uses_source,
    };

    var fixture: Fixture = undefined;

    try fixture.init(&limits_fixture);
    defer fixture.deinit();

    for (sources) |source| {
        try std.testing.expectEqual(.complete, try fixture.build(source));

        const scopes = fixture.semantic.scope_slice();

        for (fixture.semantic.reference_slice()) |reference| {
            const index = switch (reference.resolution) {
                .bound => |held| held,
                .builtin, .external, .maybe, .unresolved => continue,
            };

            const binding = fixture.semantic.at(index);
            var scope = reference.scope;
            var walked = false;

            for (0..scope_depth_max + 1) |_| {
                if (scope == none) break;

                if (scope == binding.scope) {
                    walked = true;

                    break;
                }

                scope = scopes[scope].parent;
            }

            try std.testing.expect(walked);
        }
    }
}

test "a table that fills reports rather than grows" {
    var fixture: Fixture = undefined;

    try fixture.init(&limits_starved);
    defer fixture.deinit();

    try std.testing.expect(try fixture.build(items_source) != .complete);
    try std.testing.expect(fixture.semantic.count() <= limits_starved.binding_count_max);
}

test "a rust binding kind maps onto the shared class" {
    var fixture: Fixture = undefined;

    try fixture.init(&limits_fixture);
    defer fixture.deinit();

    try std.testing.expectEqual(.complete, try fixture.build(bare_call_source));

    const row = fixture.semantic.row(0);

    try std.testing.expectEqual(BindingClass.method, Rules.class_of(.associated_function));
    try std.testing.expectEqual(BindingClass.function, row.class);
    try std.testing.expectEqual(fixture.semantic.at(0).node, row.node);
    try std.testing.expectEqual(ScopeClass.module, fixture.semantic.scope_row(0).class);
    try std.testing.expectEqual(ScopeClass.other, Rules.scope_class_of(.item));
    try std.testing.expectEqual(null, fixture.semantic.scope_row(0).parent);
    try std.testing.expectEqual(0, fixture.semantic.scope_row(1).parent.?);
}

const generics_bindings = [_][]const u8{
    "Struct Holder scope 0 from 0",
    "TypeParameter T scope 1 from 0",
    "Field field scope 1 from 0",
    "Struct Other scope 0 from 0",
    "TypeParameter T scope 2 from 0",
    "Field field scope 2 from 0",
    "TypeParameter T scope 3 from 0",
    "AssociatedFunction new scope 3 from 0",
    "Parameter field scope 4 from 0",
    "Trait Speak scope 0 from 0",
    "Lifetime 'a scope 6 from 0",
    "TypeParameter T scope 6 from 0",
    "AssociatedFunction speak scope 6 from 0",
    "Parameter self scope 7 from 0",
    "Parameter held scope 7 from 0",
    "Function work scope 0 from 0",
    "Lifetime 'a scope 8 from 0",
    "TypeParameter T scope 8 from 0",
    "ConstParameter N scope 8 from 0",
    "Parameter one scope 8 from 0",
    "Parameter two scope 8 from 0",
    "Local held scope 9 from 317",
    "TypeAlias Pair scope 0 from 0",
    "Lifetime 'a scope 10 from 0",
    "TypeParameter T scope 10 from 0",
};

const generics_facts = [_][]const u8{};

const generics_references = [_][]const u8{
    "T Type Bound(1) scope 1",
    "T Type Bound(4) scope 2",
    "Holder Type Bound(0) scope 3",
    "T Type Bound(6) scope 3",
    "T Type Bound(6) scope 4",
    "Self Type Builtin scope 4",
    "Holder Type Bound(0) scope 5",
    "field Value Bound(8) scope 5",
    "'a Lifetime Bound(10) scope 7",
    "'a Lifetime Bound(10) scope 7",
    "T Type Bound(11) scope 7",
    "T Type Bound(11) scope 7",
    "Speak Type Bound(9) scope 8",
    "'a Lifetime Bound(16) scope 8",
    "usize Type Builtin scope 8",
    "usize Type Builtin scope 8",
    "T Type Bound(17) scope 8",
    "'a Lifetime Bound(16) scope 8",
    "str Type Builtin scope 8",
    "usize Type Builtin scope 8",
    "N Value Bound(18) scope 9",
    "one Value Bound(19) scope 9",
    "held Value Bound(21) scope 9",
    "two Value Bound(20) scope 9",
    "'a Lifetime Bound(23) scope 10",
    "T Type Bound(24) scope 10",
    "T Type Bound(24) scope 10",
};

const generics_scopes = [_][]const u8{
    "Module none",
    "Item under 0",
    "Item under 0",
    "Item under 0",
    "Function under 3",
    "Block under 4",
    "Item under 0",
    "Function under 6",
    "Function under 0",
    "Block under 8",
    "Item under 0",
};

const items_bindings = [_][]const u8{
    "Const TOP scope 0 from 0",
    "Static NAME scope 0 from 0",
    "Struct Holder scope 0 from 0",
    "Field field scope 1 from 0",
    "Struct Wrapper scope 0 from 0",
    "Enum Shade scope 0 from 0",
    "Variant Light scope 3 from 0",
    "Variant Dark scope 3 from 0",
    "Union Bits scope 0 from 0",
    "Field one scope 4 from 0",
    "Trait Speak scope 0 from 0",
    "AssociatedConst LOUD scope 5 from 0",
    "AssociatedType Out scope 5 from 0",
    "AssociatedFunction speak scope 5 from 0",
    "Parameter self scope 6 from 0",
    "AssociatedConst LOUD scope 7 from 0",
    "AssociatedType Out scope 7 from 0",
    "AssociatedFunction speak scope 7 from 0",
    "Parameter self scope 8 from 0",
    "TypeAlias Alias scope 0 from 0",
    "Module inner scope 0 from 0",
    "Const SIZE scope 11 from 0",
    "Function size scope 11 from 0",
    "Const SIZE scope 0 from 0",
    "Function build scope 0 from 0",
};

const items_facts = [_][]const u8{};

const items_references = [_][]const u8{
    "usize Type Builtin scope 0",
    "SIZE Value Bound(23) scope 0",
    "str Type Builtin scope 0",
    "usize Type Builtin scope 1",
    "usize Type Builtin scope 2",
    "u8 Type Builtin scope 3",
    "u8 Type Builtin scope 4",
    "bool Type Builtin scope 5",
    "Self Type Builtin scope 6",
    "Speak Type Bound(10) scope 7",
    "Holder Type Bound(2) scope 7",
    "bool Type Builtin scope 7",
    "usize Type Builtin scope 7",
    "Self Type Builtin scope 8",
    "self Value Bound(18) scope 9",
    "Holder Type Bound(2) scope 10",
    "usize Type Builtin scope 11",
    "usize Type Builtin scope 12",
    "SIZE Value Bound(21) scope 13",
    "usize Type Builtin scope 0",
    "Wrapper Type Bound(4) scope 14",
    "Wrapper Value Bound(4) scope 15",
    "TOP Value Bound(0) scope 15",
};

const items_scopes = [_][]const u8{
    "Module none",
    "Item under 0",
    "Item under 0",
    "Item under 0",
    "Item under 0",
    "Item under 0",
    "Function under 5",
    "Item under 0",
    "Function under 7",
    "Block under 8",
    "Item under 0",
    "Module under 0",
    "Function under 11",
    "Block under 12",
    "Function under 0",
    "Block under 14",
};

const labels_bindings = [_][]const u8{
    "Function run scope 0 from 0",
    "Parameter limit scope 1 from 0",
    "Local held scope 2 from 53",
    "Label 'outer scope 3 from 0",
    "Label 'inner scope 5 from 0",
    "Local item scope 8 from 127",
};

const labels_facts = [_][]const u8{};

const labels_references = [_][]const u8{
    "usize Type Builtin scope 1",
    "usize Type Builtin scope 1",
    "held Value Bound(2) scope 5",
    "limit Value Bound(1) scope 5",
    "limit Value Bound(1) scope 7",
    "item Value Bound(5) scope 9",
    "'outer Label Bound(3) scope 10",
    "item Value Bound(5) scope 11",
    "'inner Label Bound(4) scope 12",
    "held Value Bound(2) scope 6",
    "held Value Bound(2) scope 2",
};

const labels_scopes = [_][]const u8{
    "Module none",
    "Function under 0",
    "Block under 1",
    "Block under 2",
    "Block under 3",
    "Block under 4",
    "Block under 5",
    "Block under 6",
    "Block under 7",
    "Block under 8",
    "Block under 9",
    "Block under 8",
    "Block under 11",
};

const locals_bindings = [_][]const u8{
    "Function run scope 0 from 0",
    "Parameter one scope 1 from 0",
    "Parameter two scope 1 from 0",
    "Local held scope 2 from 61",
    "Local held scope 2 from 88",
    "Local left scope 2 from 125",
    "Local right scope 2 from 125",
    "Local left scope 3 from 158",
    "Function shadow scope 0 from 0",
    "Local held scope 5 from 230",
    "Local held scope 5 from 251",
    "Function guarded scope 0 from 0",
    "Parameter value scope 6 from 0",
    "Local found scope 7 from 368",
    "Local inner scope 9 from 400",
    "Local one scope 11 from 475",
    "Function walked scope 0 from 0",
    "Parameter items scope 13 from 0",
    "Local total scope 14 from 572",
    "Local item scope 16 from 582",
    "Function closed scope 0 from 0",
    "Parameter one scope 17 from 0",
    "Local held scope 18 from 717",
    "Parameter two scope 19 from 0",
};

const locals_facts = [_][]const u8{};

const locals_references = [_][]const u8{
    "usize Type Builtin scope 1",
    "usize Type Builtin scope 1",
    "usize Type Builtin scope 1",
    "one Value Bound(1) scope 2",
    "held Value Bound(3) scope 2",
    "two Value Bound(2) scope 2",
    "held Value Bound(4) scope 2",
    "one Value Bound(1) scope 2",
    "right Value Bound(6) scope 3",
    "left Value Bound(7) scope 3",
    "usize Type Builtin scope 4",
    "held Value Bound(9) scope 5",
    "held Value Bound(10) scope 5",
    "Option Type Builtin scope 6",
    "usize Type Builtin scope 6",
    "usize Type Builtin scope 6",
    "Some Value Builtin scope 7",
    "value Value Bound(12) scope 7",
    "Some Value Builtin scope 9",
    "value Value Bound(12) scope 9",
    "inner Value Bound(14) scope 10",
    "found Value Bound(13) scope 10",
    "value Value Bound(12) scope 7",
    "Some Value Builtin scope 11",
    "one Value Bound(15) scope 11",
    "None Value Builtin scope 12",
    "usize Type Builtin scope 13",
    "usize Type Builtin scope 13",
    "items Value Bound(17) scope 15",
    "total Value Bound(18) scope 16",
    "item Value Bound(19) scope 16",
    "total Value Bound(18) scope 14",
    "usize Type Builtin scope 17",
    "usize Type Builtin scope 17",
    "usize Type Builtin scope 19",
    "one Value Bound(21) scope 19",
    "two Value Bound(23) scope 19",
    "held Value Bound(22) scope 18",
};

const locals_scopes = [_][]const u8{
    "Module none",
    "Function under 0",
    "Block under 1",
    "Block under 2",
    "Function under 0",
    "Block under 4",
    "Function under 0",
    "Block under 6",
    "Block under 7",
    "Block under 7",
    "Block under 9",
    "Block under 7",
    "Block under 7",
    "Function under 0",
    "Block under 13",
    "Block under 14",
    "Block under 15",
    "Function under 0",
    "Block under 17",
    "Function under 18",
};

const macros_bindings = [_][]const u8{
    "Macro shout scope 0 from 51",
    "Function run scope 0 from 0",
    "Function early scope 0 from 0",
    "Macro whisper scope 0 from 182",
};

const macros_facts = [_][]const u8{};

const macros_references = [_][]const u8{
    "usize Type Builtin scope 1",
    "shout Macro Bound(0) scope 2",
    "usize Type Builtin scope 3",
    "whisper Macro Unresolved scope 4",
};

const macros_scopes = [_][]const u8{
    "Module none",
    "Function under 0",
    "Block under 1",
    "Function under 0",
    "Block under 3",
};

const paths_bindings = [_][]const u8{
    "Struct Holder scope 0 from 0",
    "Field field scope 1 from 0",
    "Function run scope 0 from 0",
    "Local held scope 3 from 92",
    "Function reach scope 0 from 0",
    "Function stored scope 0 from 0",
    "Parameter held scope 6 from 0",
};

const paths_facts = [_][]const u8{};

const paths_references = [_][]const u8{
    "usize Type Builtin scope 1",
    "usize Type Builtin scope 2",
    "Holder Type Bound(0) scope 3",
    "held Value Bound(3) scope 3",
    "usize Type Builtin scope 4",
    "crate Type External scope 5",
    "super Type External scope 5",
    "std Type External scope 5",
    "usize Type Builtin scope 5",
    "missing Value Unresolved scope 5",
    "usize Type Builtin scope 6",
    "usize Type Builtin scope 6",
    "held Value Bound(6) scope 7 store",
    "held Value Bound(6) scope 7",
};

const paths_scopes = [_][]const u8{
    "Module none",
    "Item under 0",
    "Function under 0",
    "Block under 2",
    "Function under 0",
    "Block under 4",
    "Function under 0",
    "Block under 6",
};

const uses_bindings = [_][]const u8{
    "Import HashMap scope 0 from 0",
    "Import Load scope 0 from 0",
    "Import Write scope 0 from 0",
    "Import swap scope 0 from 0",
    "Import Held scope 0 from 0",
    "Import Kept scope 0 from 0",
    "Import serde scope 0 from 0",
    "Module inner scope 0 from 0",
    "Struct Held scope 1 from 0",
    "Struct Kept scope 1 from 0",
    "Function run scope 0 from 0",
    "Parameter map scope 4 from 0",
    "Parameter sink scope 4 from 0",
    "Parameter held scope 4 from 0",
    "Function maybe scope 0 from 0",
};

const uses_facts = [_][]const u8{
    "ImportNamed HashMap HashMap std::collections",
    "ImportNamed Load Read std::io",
    "ImportNamed Write Write std::io",
    "ImportNamespace . . std::fmt",
    "Reexport swap swap std::mem",
    "ImportNamed Held Held crate::inner",
    "ImportNamed Kept Kept self::inner",
    "ImportNamed serde serde serde",
};

const uses_references = [_][]const u8{
    "std Type External scope 0",
    "std Type External scope 0",
    "std Type External scope 0",
    "std Type External scope 0",
    "crate Type External scope 0",
    "self Type External scope 0",
    "HashMap Type Bound(0) scope 4",
    "Write Type Bound(2) scope 4",
    "Held Type Bound(4) scope 4",
    "Load Type Bound(1) scope 4",
    "swap Value Bound(3) scope 5",
    "map Value Bound(11) scope 5",
    "sink Value Bound(12) scope 5",
    "Kept Value Bound(5) scope 5",
    "usize Type Builtin scope 6",
    "unknown Value Maybe scope 7",
};

const uses_scopes = [_][]const u8{
    "Module none glob",
    "Module under 0",
    "Item under 1",
    "Item under 1",
    "Function under 0",
    "Block under 4",
    "Function under 0",
    "Block under 6",
};

const generics_source =
    \\struct Holder<T> {
    \\    field: T,
    \\}
    \\
    \\struct Other<T> {
    \\    field: T,
    \\}
    \\
    \\impl<T> Holder<T> {
    \\    fn new(field: T) -> Self {
    \\        Holder { field }
    \\    }
    \\}
    \\
    \\trait Speak<'a, T> {
    \\    fn speak(&'a self, held: T) -> T;
    \\}
    \\
    \\fn work<'a, T: Speak<'a, usize>, const N: usize>(one: T, two: &'a str) -> usize {
    \\    let held = N;
    \\
    \\    one.speak(held);
    \\
    \\    two.len()
    \\}
    \\
    \\type Pair<'a, T> = (&'a T, T);
    \\
;

const items_source =
    \\const TOP: usize = SIZE;
    \\
    \\static NAME: &str = "scylla";
    \\
    \\struct Holder {
    \\    field: usize,
    \\}
    \\
    \\struct Wrapper(usize);
    \\
    \\enum Shade {
    \\    Light,
    \\    Dark(u8),
    \\}
    \\
    \\union Bits {
    \\    one: u8,
    \\}
    \\
    \\trait Speak {
    \\    const LOUD: bool;
    \\
    \\    type Out;
    \\
    \\    fn speak(&self) -> Self::Out;
    \\}
    \\
    \\impl Speak for Holder {
    \\    const LOUD: bool = true;
    \\
    \\    type Out = usize;
    \\
    \\    fn speak(&self) -> Self::Out {
    \\        self.field
    \\    }
    \\}
    \\
    \\type Alias = Holder;
    \\
    \\mod inner {
    \\    pub const SIZE: usize = 4;
    \\
    \\    pub fn size() -> usize {
    \\        SIZE
    \\    }
    \\}
    \\
    \\const SIZE: usize = 8;
    \\
    \\fn build() -> Wrapper {
    \\    Wrapper(TOP)
    \\}
    \\
;

const labels_source =
    \\fn run(limit: usize) -> usize {
    \\    let mut held = 0;
    \\
    \\    'outer: loop {
    \\        'inner: while held < limit {
    \\            for item in 0..limit {
    \\                if item > 2 {
    \\                    break 'outer;
    \\                }
    \\
    \\                if item > 1 {
    \\                    continue 'inner;
    \\                }
    \\            }
    \\
    \\            held += 1;
    \\        }
    \\
    \\        break;
    \\    }
    \\
    \\    held
    \\}
    \\
;

const locals_source =
    \\fn run(one: usize, two: usize) -> usize {
    \\    let held = one;
    \\    let held = held + two;
    \\    let (left, right) = (held, one);
    \\
    \\    {
    \\        let left = right;
    \\
    \\        return left;
    \\    }
    \\}
    \\
    \\fn shadow() -> usize {
    \\    let held = 1;
    \\    let held = held;
    \\
    \\    held
    \\}
    \\
    \\fn guarded(value: Option<usize>) -> usize {
    \\    let Some(found) = value else {
    \\        return 0;
    \\    };
    \\
    \\    if let Some(inner) = value {
    \\        return inner + found;
    \\    }
    \\
    \\    match value {
    \\        Some(one) => one,
    \\        None => 0,
    \\    }
    \\}
    \\
    \\fn walked(items: &[usize]) -> usize {
    \\    let mut total = 0;
    \\
    \\    for item in items {
    \\        total += item;
    \\    }
    \\
    \\    total
    \\}
    \\
    \\fn closed(one: usize) -> usize {
    \\    let held = move |two: usize| one + two;
    \\
    \\    held(1)
    \\}
    \\
;

const macros_source =
    \\macro_rules! shout {
    \\    () => {
    \\        1
    \\    };
    \\}
    \\
    \\fn run() -> usize {
    \\    shout!()
    \\}
    \\
    \\fn early() -> usize {
    \\    whisper!()
    \\}
    \\
    \\macro_rules! whisper {
    \\    () => {
    \\        0
    \\    };
    \\}
    \\
;

const paths_source =
    \\struct Holder {
    \\    field: usize,
    \\}
    \\
    \\fn run() -> usize {
    \\    let held = Holder { field: 1 };
    \\
    \\    held.field
    \\}
    \\
    \\fn reach() -> usize {
    \\    crate::run();
    \\    super::run();
    \\    std::mem::size_of::<usize>();
    \\
    \\    missing()
    \\}
    \\
    \\fn stored(mut held: usize) -> usize {
    \\    held = 2;
    \\
    \\    held
    \\}
    \\
;

const uses_source =
    \\use std::collections::HashMap;
    \\use std::io::{Read as Load, Write};
    \\use std::fmt::*;
    \\pub use std::mem::swap;
    \\use crate::inner::Held;
    \\use self::inner::Kept;
    \\
    \\extern crate serde;
    \\
    \\mod inner {
    \\    pub struct Held;
    \\
    \\    pub struct Kept;
    \\}
    \\
    \\fn run(map: HashMap, sink: Write, held: Held) -> Load {
    \\    swap(map, sink);
    \\
    \\    Kept
    \\}
    \\
    \\fn maybe() -> usize {
    \\    unknown()
    \\}
    \\
;

const bare_call_source =
    \\fn helper(a: u32) -> u32 { a }
    \\
    \\struct S;
    \\
    \\impl S {
    \\    fn helper(&self, a: u32) -> u32 {
    \\        helper(a)
    \\    }
    \\}
    \\
;
