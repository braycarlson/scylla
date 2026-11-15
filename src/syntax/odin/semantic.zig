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
const Context = @import("../semantic.zig").Context;
const Limits = @import("../semantic.zig").Limits;
const Reference = Semantic.Reference;
const Resolution = @import("../semantic.zig").Resolution;
pub const Semantic = SemanticType(Rules);

const Rules = struct {
    pub const BindingExtension = void;
    pub const Extension = void;
    pub const ReferenceExtension = void;
    pub const ScopeExtension = void;
    pub const pick: Pick = .newest;
    pub const scopes_in_walk_order: bool = true;

    pub const BindingKind = enum {
        @"const",
        field,
        import,
        label,
        member,
        parameter,
        procedure,
        result,
        type,
        @"var",

        pub fn annotated(kind: BindingKind) bool {
            const result = switch (kind) {
                .field, .parameter => true,
                else => false,
            };

            if (result) assert(kind.hoists());
            if (kind == .@"var") assert(!result);

            return result;
        }

        pub fn hoists(kind: BindingKind) bool {
            const result = kind != .@"var";

            if (!result) assert(kind.namespace() == .value);
            if (kind == .label) assert(result);

            return result;
        }

        pub fn namespace(kind: BindingKind) Namespace {
            const held: Namespace = if (kind == .label) .label else .value;

            if (held == .label) assert(kind == .label);
            if (kind == .@"var") assert(held == .value);

            return held;
        }
    };

    pub const Namespace = enum {
        label,
        value,
    };

    pub const Options = struct {
        globals: []const []const u8,
    };

    pub const ScopeKind = enum {
        block,
        file,
        item,
        procedure,

        pub fn is_ordered(kind: ScopeKind) bool {
            const result = switch (kind) {
                .block, .procedure => true,
                .file, .item => false,
            };

            if (kind == .file) assert(!result);
            if (kind == .procedure) assert(result);

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
        assert(universe.len <= std.math.maxInt(u32));

        semantic.clear();
        semantic.scope_root(.file, 0, {});

        var builder: Builder = .{
            .depth = 0,
            .outcome = .complete,
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
        assert(semantic.scope_at(0).kind == .file);
        assert(semantic.scope_at(0).parent == none);

        return builder.outcome;
    }

    pub fn chains_with(previous: BindingKind, kind: BindingKind) bool {
        return namespace_of(previous) == namespace_of(kind);
    }

    pub fn class_of(kind: BindingKind) BindingClass {
        const class: BindingClass = switch (kind) {
            .@"const" => .constant,
            .field, .member => .field,
            .import => .import,
            .label => .other,
            .parameter => .parameter,
            .procedure => .function,
            .result, .@"var" => .local,
            .type => .type,
        };

        if (kind == .label) assert(class == .other);
        if (kind == .member) assert(class == .field);

        return class;
    }

    pub fn crosses(scope: ScopeKind) bool {
        assert(@backingInt(scope) < @typeInfo(ScopeKind).@"enum".field_names.len);

        return false;
    }

    pub fn fallback(reference: *const Reference, dynamic_seen: bool) Resolution {
        assert(reference.resolution == .unresolved);

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

        return .from_or_self;
    }

    pub fn retry_namespace(reference: *const Reference) ?Namespace {
        assert(reference.scope != none);

        return null;
    }

    pub fn scope_class_of(kind: ScopeKind) ScopeClass {
        const class: ScopeClass = switch (kind) {
            .block => .block,
            .file => .module,
            .item => .other,
            .procedure => .function,
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

    fn child_of(builder: *const Builder, node: u32, kind: Kind) ?u32 {
        assert(node < builder.tree.count());
        assert(kind.is_node());

        var held = builder.children(node);

        for (0..builder.tree.count()) |_| {
            const child = held.next() orelse return null;
            if (builder.kind_of(child) == kind) return child;
        }

        return null;
    }

    fn leads(builder: *const Builder, parent: u32, node: u32) bool {
        assert(parent < builder.tree.count());
        assert(node < builder.tree.count());

        const child = builder.tree.child_first_of(parent) orelse return false;
        return child == node;
    }

    fn parent_of(builder: *const Builder, node: u32) ?u32 {
        assert(node < builder.tree.count());

        const parent = builder.tree.parent_of(node);

        if (parent) |above| assert(above < node);

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

    fn leading_names(builder: *const Builder, node: u32, names: *Names) void {
        assert(node < builder.tree.count());

        var child = builder.tree.child_first_of(node);

        names.name_count = 0;

        for (0..builder.tree.count()) |_| {
            const held = child orelse break;
            if (builder.kind_of(held) != .tag) break;

            child = builder.tree.sibling_next_of(held);
        }

        for (0..name_count_max) |_| {
            const held = child orelse break;
            if (builder.kind_of(held) != .identifier_node) break;

            names.items[names.name_count] = held;
            names.name_count += 1;
            child = builder.tree.sibling_next_of(held);
        }

        assert(names.name_count <= name_count_max);
    }

    fn opens(builder: *const Builder, node: u32) ?Rules.ScopeKind {
        assert(node < builder.tree.count());

        const kind = builder.kind_of(node);

        if (kind == .block) {
            const parent = builder.parent_of(node);
            if (builder.kind_of(parent) == .foreign_block) return null;
        }

        const scope_kind = scope_kind_of(kind);

        if (kind == .foreign_block) assert(scope_kind == null);

        return scope_kind;
    }

    fn enter(builder: *Builder, node: u32) void {
        assert(node < none);

        const kind = builder.kind_of(node);

        builder.before(node, kind);

        if (builder.opens(node)) |held| builder.open(node, held);

        builder.after(node, kind);

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

        const index = builder.semantic.scope_open(parent, kind, node, {}) catch |err| switch (err) {
            error.Truncated => {
                if (builder.outcome == .complete) builder.outcome = .{ .truncated = .scopes };

                return;
            },
        };

        assert(parent < index);

        if (builder.depth >= scope_depth_max) {
            builder.outcome = .too_deep;

            return;
        }

        builder.stack[builder.depth] = index;
        builder.depth += 1;

        assert(builder.scope_current() == index);
        assert(builder.semantic.scope_at(index).parent == parent);
    }

    fn before(builder: *Builder, node: u32, kind: Kind) void {
        assert(node < builder.tree.count());
        assert(kind.is_node());

        switch (kind) {
            .assignment_statement => builder.short_declare(node),
            .bit_field_declaration => builder.declaration_record(node, .type),
            .const_declaration => builder.declaration_record(node, .@"const"),
            .const_type_declaration => builder.declaration_record(node, .type),
            .enum_declaration => builder.declaration_record(node, .type),
            .import_declaration => builder.import_declare(node),
            .label_statement => builder.declaration_record(node, .label),
            .overloaded_procedure_declaration => builder.declaration_record(node, .procedure),
            .procedure_declaration => builder.declaration_record(node, .procedure),
            .struct_declaration => builder.declaration_record(node, .type),
            .union_declaration => builder.declaration_record(node, .type),
            .using_statement => builder.using_mark(),
            .var_declaration, .variable_declaration => builder.variable_declare(node),
            else => {},
        }
    }

    fn after(builder: *Builder, node: u32, kind: Kind) void {
        assert(node < builder.tree.count());
        assert(kind.is_node());

        switch (kind) {
            .enum_declaration => builder.members_declare(node),
            .field => builder.group_declare(node, .field),
            .for_statement => builder.iteration_declare(node),
            .identifier_node => builder.name_refer(node),
            .named_type => builder.result_declare(node),
            .parameter => builder.group_declare(node, .parameter),
            .struct_member => builder.member_declare(node),
            else => {},
        }
    }

    fn declaration_record(builder: *Builder, node: u32, kind: Rules.BindingKind) void {
        assert(kind.hoists());
        assert(!kind.annotated());
        assert(node < none);

        const held = builder.child_of(node, .identifier_node) orelse return;

        assert(held > node);

        _ = builder.record(&.{
            .from = 0,
            .kind = kind,
            .name = builder.span_of(held),
            .node = held,
        });
    }

    fn member_declare(builder: *Builder, node: u32) void {
        assert(builder.kind_of(node) == .struct_member);
        assert(node < builder.tree.count());

        if (builder.token_of(node, .colon) == null) return;

        builder.group_declare(node, .field);
    }

    fn group_declare(builder: *Builder, node: u32, kind: Rules.BindingKind) void {
        assert(kind.annotated());
        assert(node < builder.tree.count());

        const assigned = builder.token_of(node, .equal);
        const from = builder.end_of(node);
        var names: Names = undefined;

        builder.leading_names(node, &names);

        for (names.slice()) |held| {
            if (assigned) |position| {
                if (builder.tree.at(held).token_start > position) break;
            }

            _ = builder.record(&.{
                .from = from,
                .kind = kind,
                .name = builder.span_of(held),
                .node = held,
            });
        }
    }

    fn members_declare(builder: *Builder, node: u32) void {
        assert(builder.kind_of(node) == .enum_declaration);

        const declared = builder.child_of(node, .identifier_node) orelse none;
        var held = builder.children(node);

        assert(declared == none or declared > node);

        for (0..builder.tree.count()) |_| {
            const child = held.next() orelse break;
            if (child == declared) continue;
            if (builder.kind_of(child) != .identifier_node) continue;

            _ = builder.record(&.{
                .from = 0,
                .kind = .member,
                .name = builder.span_of(child),
                .node = child,
            });
        }
    }

    fn result_declare(builder: *Builder, node: u32) void {
        assert(builder.kind_of(node) == .named_type);

        const held = builder.child_of(node, .identifier_node) orelse return;

        assert(held > node);

        _ = builder.record(&.{
            .from = 0,
            .kind = .result,
            .name = builder.span_of(held),
            .node = held,
        });
    }

    fn variable_declare(builder: *Builder, node: u32) void {
        assert(node < builder.tree.count());

        const from = builder.end_of(node);
        var names: Names = undefined;

        builder.leading_names(node, &names);

        for (names.slice()) |held| {
            _ = builder.record(&.{
                .from = from,
                .kind = .@"var",
                .name = builder.span_of(held),
                .node = held,
            });
        }

        assert(names.name_count <= name_count_max);
    }

    fn short_declare(builder: *Builder, node: u32) void {
        assert(builder.kind_of(node) == .assignment_statement);

        const position = builder.token_of(node, .colon_equal) orelse return;

        assert(position >= builder.tree.at(node).token_start);

        builder.locals_record(node, &.{ .from = builder.end_of(node), .token_limit = position });
    }

    fn iteration_declare(builder: *Builder, node: u32) void {
        assert(builder.kind_of(node) == .for_statement);

        const position = builder.token_of(node, .in_keyword) orelse return;
        const body = builder.child_of(node, .block);
        const from = if (body) |held| builder.span_of(held).offset else builder.end_of(node);

        assert(position >= builder.tree.at(node).token_start);

        builder.locals_record(node, &.{ .from = from, .token_limit = position });
    }

    fn locals_record(builder: *Builder, node: u32, locals: *const Locals) void {
        assert(node < builder.tree.count());
        assert(locals.token_limit < builder.tree.at(node).token_end);

        var held = builder.children(node);

        for (0..builder.tree.count()) |_| {
            const child = held.next() orelse break;
            if (builder.tree.at(child).token_start >= locals.token_limit) break;
            if (builder.kind_of(child) != .identifier_node) continue;

            _ = builder.record(&.{
                .from = locals.from,
                .kind = .@"var",
                .name = builder.span_of(child),
                .node = child,
            });
        }
    }

    fn using_mark(builder: *Builder) void {
        const scope = builder.scope_current();

        builder.semantic.scope_mark_dynamic(scope);

        assert(builder.semantic.scope_at(scope).dynamic);
    }

    fn import_declare(builder: *Builder, node: u32) void {
        assert(builder.kind_of(node) == .import_declaration);

        const specifier = builder.specifier_of(node);
        if (std.meta.eql(specifier, Span.empty)) return;

        const alias = builder.child_of(node, .identifier_node);
        const package = package_of(builder.source, specifier);
        const name = if (alias) |held| builder.span_of(held) else package;

        assert(name.end() <= builder.source.len);
        assert(package.end() == specifier.end());

        const binding = builder.record(&.{
            .from = 0,
            .kind = .import,
            .name = name,
            .node = node,
        });

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

        const held = builder.child_of(node, .string) orelse return Span.empty;
        if (builder.child_of(held, .string_content)) |inner| return builder.span_of(inner);

        const quoted = builder.span_of(held);
        if (quoted.length < 2) return Span.empty;

        assert(quoted.end() <= builder.source.len);

        return .{ .offset = quoted.offset + 1, .length = quoted.length - 2 };
    }

    fn name_refer(builder: *Builder, node: u32) void {
        assert(builder.kind_of(node) == .identifier_node);

        if (builder.declares(node)) return;
        if (builder.selects(node)) return;
        if (builder.decorates(node)) return;

        const name = builder.span_of(node);
        if (std.mem.eql(u8, builder.text_of(name), "_")) return;

        builder.reference_push(&.{
            .context = if (builder.stores(node)) .store else .load,
            .name = name,
            .namespace = if (builder.branches(node)) .label else .value,
            .node = node,
        });
    }

    fn decorates(builder: *const Builder, node: u32) bool {
        assert(node < builder.tree.count());
        assert(builder.kind_of(node) == .identifier_node);

        var held: ?u32 = node;

        for (0..step_max) |_| {
            const current = held orelse return false;

            switch (builder.kind_of(current)) {
                .attribute, .attributes, .package_declaration => return true,
                else => {},
            }

            held = builder.parent_of(current);
        }

        return false;
    }

    fn branches(builder: *const Builder, node: u32) bool {
        assert(node < builder.tree.count());

        const parent = builder.parent_of(node);

        const result = switch (builder.kind_of(parent)) {
            .break_statement, .continue_statement => true,
            else => false,
        };

        if (result) assert(parent != null);

        return result;
    }

    fn selects(builder: *const Builder, node: u32) bool {
        assert(node < builder.tree.count());

        const parent = builder.parent_of(node) orelse return false;

        assert(parent < node);

        switch (builder.kind_of(parent)) {
            .member_expression, .selector_call_expression => return !builder.leads(parent, node),
            .call_expression => {},
            else => return false,
        }

        if (!builder.leads(parent, node)) return false;

        const above = builder.parent_of(parent) orelse return false;

        switch (builder.kind_of(above)) {
            .member_expression, .selector_call_expression => {},
            else => return false,
        }

        return !builder.leads(above, parent);
    }

    fn declares(builder: *const Builder, node: u32) bool {
        assert(node < none);

        const parent = builder.parent_of(node) orelse return false;
        const kind = builder.kind_of(parent);

        assert(parent < node);

        assert(builder.kind_of(node) == .identifier_node);

        switch (kind) {
            .bit_field_declaration,
            .const_declaration,
            .const_type_declaration,
            .enum_declaration,
            .field,
            .import_declaration,
            .label_statement,
            .named_type,
            .overloaded_procedure_declaration,
            .parameter,
            .procedure_declaration,
            .struct_declaration,
            .struct_field,
            .union_declaration,
            => return builder.declared_by(parent, node),
            .var_declaration, .variable_declaration => {
                var names: Names = undefined;

                builder.leading_names(parent, &names);

                return std.mem.findScalar(u32, names.slice(), node) != null;
            },
            .assignment_statement, .for_statement => {
                const marker: Kind = if (kind == .for_statement) .in_keyword else .colon_equal;
                const position = builder.token_of(parent, marker) orelse return false;

                return builder.tree.at(node).token_start < position;
            },
            else => return false,
        }
    }

    fn declared_by(builder: *const Builder, parent: u32, node: u32) bool {
        assert(parent < node);
        assert(node < builder.tree.count());

        const kind = builder.kind_of(parent);
        if (kind == .enum_declaration) return true;
        if (kind == .overloaded_procedure_declaration) return builder.leads(parent, node);

        const held = builder.child_of(parent, .identifier_node) orelse return false;
        return held == node;
    }

    fn stores(builder: *const Builder, node: u32) bool {
        assert(node < builder.tree.count());

        const parent = builder.parent_of(node) orelse return false;

        assert(parent < node);

        switch (builder.kind_of(parent)) {
            .assignment_statement, .update_statement => return builder.leads(parent, node),
            else => return false,
        }
    }

    fn reference_push(builder: *Builder, referred: *const Referred) void {
        const scope = builder.scope_current();
        const reference_count_before = builder.semantic.reference_count();

        assert(referred.name.end() <= builder.source.len);
        if (referred.namespace == .label) assert(referred.context == .load);

        builder.semantic.refer(builder.source, &.{
            .context = referred.context,
            .dead_zone = false,
            .ext = {},
            .name = referred.name,
            .name_hash = 0,
            .namespace = referred.namespace,
            .node = referred.node,
            .resolution = .unresolved,
            .scope = scope,
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

    fn record(builder: *Builder, declared: *const Declared) ?u32 {
        const text = builder.text_of(declared.name);
        if (std.mem.eql(u8, text, "_")) return null;

        const semantic = builder.semantic;
        const scope = builder.scope_current();
        const ordered = semantic.scope_at(scope).kind.is_ordered();
        const opens_at = ordered or declared.kind.annotated();

        const index = semantic.declare(builder.source, scope, &.{
            .dead_zone_end = none,
            .ext = {},
            .from = if (opens_at) declared.from else 0,
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

const Locals = struct {
    from: u32,
    token_limit: u32,
};

const Names = struct {
    items: [name_count_max]u32,
    name_count: u32,

    fn slice(names: *const Names) []const u32 {
        assert(names.name_count <= name_count_max);

        const held = names.items[0..names.name_count];

        assert(held.len == names.name_count);

        return held;
    }
};

const Referred = struct {
    context: Context,
    name: Span,
    namespace: Rules.Namespace,
    node: u32,
};

const scope_depth_max = @import("../semantic.zig").scope_depth_max;
const name_count_max: u32 = 1 << 6;
const step_max: u32 = 1 << 12;

comptime {
    assert(scope_depth_max < step_max);
    assert(name_count_max < step_max);
}

fn scope_kind_of(kind: Kind) ?Rules.ScopeKind {
    assert(kind.is_node());

    const scope_kind: ?Rules.ScopeKind = switch (kind) {
        .procedure, .procedure_type => .procedure,
        .bit_field_declaration, .enum_declaration => .item,
        .struct_declaration, .union_declaration => .item,
        .block, .for_statement, .if_statement => .block,
        .switch_case, .switch_statement, .when_statement => .block,
        else => null,
    };

    if (kind == .procedure_type) assert(scope_kind.? == .procedure);
    if (kind == .foreign_block) assert(scope_kind == null);

    return scope_kind;
}

fn package_of(source: []const u8, specifier: Span) Span {
    assert(specifier.end() <= source.len);

    const text = specifier.text(source);
    var start: u32 = 0;

    for (text, 0..) |byte, index| {
        switch (byte) {
            ':', '/' => start = @intCast(index + 1),
            else => {},
        }
    }

    assert(start <= specifier.length);

    return .{ .offset = specifier.offset + start, .length = specifier.length - start };
}

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
            const dynamic = if (scope.dynamic) " using" else "";

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
                inline else => |_, tag| comptime camel_of(@tagName(tag)),
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
            const kind = switch (fact.kind) {
                inline else => |_, tag| comptime camel_of(@tagName(tag)),
            };

            const actual = try std.mem.print(&buffer, "{s} {s} {s}", .{
                kind,
                fact.local.text(fixture.source),
                fact.specifier.text(fixture.source),
            });

            try std.testing.expectEqualStrings(row, actual);
        }
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
    .binding_count_max = 2,
    .fact_count_max = 2,
    .reference_count_max = 2,
    .scope_count_max = 2,
};

const universe_test = [_][]const u8{ "bool", "false", "int", "nil", "string", "true" };

test "a file scope declaration is read from anywhere in the file" {
    try fixture_expect(declarations_source, &.{
        .bindings = &declarations_bindings,
        .facts = &declarations_facts,
        .references = &declarations_references,
        .scopes = &declarations_scopes,
    });
}

test "a foreign block binds each entry into the file that holds it" {
    try fixture_expect(foreign_source, &.{
        .bindings = &foreign_bindings,
        .facts = &foreign_facts,
        .references = &foreign_references,
        .scopes = &foreign_scopes,
    });
}

test "a procedure names its parameters its results and its locals" {
    try fixture_expect(procedures_source, &.{
        .bindings = &procedures_bindings,
        .facts = &procedures_facts,
        .references = &procedures_references,
        .scopes = &procedures_scopes,
    });
}

test "a using leaves an unresolved name a maybe rather than a mistake" {
    try fixture_expect(using_source, &.{
        .bindings = &using_bindings,
        .facts = &using_facts,
        .references = &using_references,
        .scopes = &using_scopes,
    });
}

test "a nested constant is read from inside its own body" {
    const source = "package p\n\nouter :: proc() {\n" ++
        "\tinner :: proc(a: int) -> bool {\n\t\treturn inner(a)\n\t}\n\n\tx := inner(1)\n}\n";

    var fixture: Fixture = undefined;
    var bound: u32 = 0;

    try fixture.init(&limits_fixture);
    defer fixture.deinit();

    try std.testing.expectEqual(.complete, try fixture.build(source));

    for (fixture.semantic.reference_slice()) |reference| {
        if (!std.mem.eql(u8, reference.name.text(source), "inner")) continue;

        try std.testing.expect(reference.resolution == .bound);

        bound += 1;
    }

    try std.testing.expectEqual(2, bound);
}

test "every reference resolves into a scope on its own chain" {
    const sources = [_][]const u8{
        declarations_source,
        foreign_source,
        procedures_source,
        using_source,
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

    try std.testing.expect(try fixture.build(procedures_source) != .complete);
    try std.testing.expect(fixture.semantic.count() <= limits_starved.binding_count_max);
}

test "an odin binding kind maps onto the shared class" {
    var fixture: Fixture = undefined;

    try fixture.init(&limits_fixture);
    defer fixture.deinit();

    try std.testing.expectEqual(.complete, try fixture.build(declarations_source));

    const row = fixture.semantic.row(4);
    const item = fixture.semantic.scope_row(1);

    try std.testing.expectEqual(BindingClass.field, Rules.class_of(.member));
    try std.testing.expectEqual(BindingClass.field, row.class);
    try std.testing.expectEqual(fixture.semantic.at(4).node, row.node);
    try std.testing.expectEqual(ScopeClass.other, item.class);
    try std.testing.expectEqual(0, item.parent.?);
    try std.testing.expectEqual(null, fixture.semantic.scope_row(0).parent);
}

const declarations_bindings = [_][]const u8{
    "Import fmt scope 0 from 0",
    "Import str scope 0 from 0",
    "Const TOP scope 0 from 0",
    "Type Shade scope 0 from 0",
    "Member Light scope 1 from 0",
    "Member Dark scope 1 from 0",
    "Type Holder scope 0 from 0",
    "Field field scope 2 from 135",
    "Field shade scope 2 from 150",
    "Procedure Handler scope 0 from 0",
    "Parameter one scope 3 from 179",
    "Procedure top scope 0 from 0",
};

const declarations_facts = [_][]const u8{
    "ImportNamed fmt core:fmt",
    "ImportNamed str core:strings",
};

const declarations_references = [_][]const u8{
    "int Value Builtin scope 2",
    "Shade Value Bound(3) scope 2",
    "int Value Builtin scope 3",
    "int Value Builtin scope 3",
    "int Value Builtin scope 4",
    "fmt Value Bound(0) scope 5",
    "str Value Bound(1) scope 5",
    "TOP Value Bound(2) scope 5",
};

const declarations_scopes = [_][]const u8{
    "File none",
    "Item under 0",
    "Item under 0",
    "Procedure under 0",
    "Procedure under 0",
    "Block under 4",
};

const declarations_source =
    "package sample\n" ++
    "\n" ++
    "import \"core:fmt\"\n" ++
    "import str \"core:strings\"\n" ++
    "\n" ++
    "TOP :: 4\n" ++
    "\n" ++
    "Shade :: enum {\n" ++
    "\tLight,\n" ++
    "\tDark,\n" ++
    "}\n" ++
    "\n" ++
    "Holder :: struct {\n" ++
    "\tfield: int,\n" ++
    "\tshade: Shade,\n" ++
    "}\n" ++
    "\n" ++
    "Handler :: proc(one: int) -> int\n" ++
    "\n" ++
    "top :: proc() -> int {\n" ++
    "\tfmt.println(str.to_upper(\"x\"))\n" ++
    "\n" ++
    "\treturn TOP\n" ++
    "}\n";

const foreign_bindings = [_][]const u8{
    "Import c scope 0 from 0",
    "Import lib scope 0 from 0",
    "Procedure native scope 0 from 0",
    "Parameter one scope 1 from 140",
    "Procedure call scope 0 from 0",
};

const foreign_facts = [_][]const u8{
    "ImportNamed c core:c",
    "ImportNamed lib system:lib",
};

const foreign_references = [_][]const u8{
    "lib Value Bound(1) scope 0",
    "int Value Builtin scope 1",
    "int Value Builtin scope 1",
    "int Value Builtin scope 2",
    "native Value Bound(2) scope 3",
};

const foreign_scopes = [_][]const u8{
    "File none",
    "Procedure under 0",
    "Procedure under 0",
    "Block under 2",
};

const foreign_source =
    "package sample\n" ++
    "\n" ++
    "import \"core:c\"\n" ++
    "\n" ++
    "foreign import lib \"system:lib\"\n" ++
    "\n" ++
    "@(default_calling_convention = \"c\")\n" ++
    "foreign lib {\n" ++
    "\tnative :: proc(one: int) -> int ---\n" ++
    "}\n" ++
    "\n" ++
    "call :: proc() -> int {\n" ++
    "\treturn native(1)\n" ++
    "}\n";

const procedures_bindings = [_][]const u8{
    "Procedure build scope 0 from 0",
    "Parameter one scope 1 from 38",
    "Parameter two scope 1 from 51",
    "Result held scope 1 from 0",
    "Result ok scope 1 from 0",
    "Var kept scope 2 from 104",
    "Var total scope 2 from 122",
    "Var item scope 3 from 149",
    "Var index scope 3 from 149",
    "Var inner scope 6 from 204",
    "Label outer scope 2 from 0",
    "Procedure teardown scope 0 from 0",
    "Parameter one scope 12 from 390",
    "Procedure read scope 0 from 0",
    "Parameter one scope 14 from 418",
    "Procedure group scope 0 from 0",
};

const procedures_facts = [_][]const u8{};

const procedures_references = [_][]const u8{
    "int Value Builtin scope 1",
    "string Value Builtin scope 1",
    "int Value Builtin scope 1",
    "bool Value Builtin scope 1",
    "held Value Bound(3) scope 2 store",
    "one Value Bound(1) scope 2",
    "two Value Bound(2) scope 2",
    "int Value Builtin scope 2",
    "one Value Bound(1) scope 2",
    "kept Value Bound(5) scope 3",
    "total Value Bound(6) scope 4 store",
    "index Value Bound(8) scope 4",
    "total Value Bound(6) scope 5",
    "total Value Bound(6) scope 6",
    "total Value Bound(6) scope 6 store",
    "inner Value Bound(9) scope 6",
    "total Value Bound(6) scope 7",
    "total Value Bound(6) scope 8 store",
    "total Value Bound(6) scope 9 store",
    "outer Label Bound(10) scope 11",
    "teardown Value Bound(11) scope 2",
    "total Value Bound(6) scope 2",
    "total Value Bound(6) scope 2",
    "int Value Builtin scope 12",
    "int Value Builtin scope 14",
    "int Value Builtin scope 14",
    "one Value Bound(14) scope 15",
    "build Value Bound(0) scope 0",
    "read Value Bound(13) scope 0",
};

const procedures_scopes = [_][]const u8{
    "File none",
    "Procedure under 0",
    "Block under 1",
    "Block under 2",
    "Block under 3",
    "Block under 2",
    "Block under 5",
    "Block under 2",
    "Block under 7",
    "Block under 7",
    "Block under 2",
    "Block under 10",
    "Procedure under 0",
    "Block under 12",
    "Procedure under 0",
    "Block under 14",
};

const procedures_source =
    "package sample\n" ++
    "\n" ++
    "build :: proc(one: int, two: string) -> (held: int, ok: bool) {\n" ++
    "\theld = one\n" ++
    "\tkept := two\n" ++
    "\ttotal: int = one\n" ++
    "\n" ++
    "\tfor item, index in kept {\n" ++
    "\t\ttotal += index\n" ++
    "\t}\n" ++
    "\n" ++
    "\tif total > 0 {\n" ++
    "\t\tinner := total\n" ++
    "\n" ++
    "\t\ttotal = inner\n" ++
    "\t}\n" ++
    "\n" ++
    "\tswitch total {\n" ++
    "\tcase 0:\n" ++
    "\t\ttotal = 1\n" ++
    "\tcase:\n" ++
    "\t\ttotal = 2\n" ++
    "\t}\n" ++
    "\n" ++
    "\touter: for {\n" ++
    "\t\tbreak outer\n" ++
    "\t}\n" ++
    "\n" ++
    "\tdefer teardown(total)\n" ++
    "\n" ++
    "\treturn total, true\n" ++
    "}\n" ++
    "\n" ++
    "teardown :: proc(one: int) {\n" ++
    "}\n" ++
    "\n" ++
    "read :: proc(one: int) -> int {\n" ++
    "\treturn one\n" ++
    "}\n" ++
    "\n" ++
    "group :: proc{build, read}\n";

const using_bindings = [_][]const u8{
    "Type Holder scope 0 from 0",
    "Field field scope 1 from 46",
    "Procedure read scope 0 from 0",
    "Parameter self scope 2 from 76",
    "Procedure plain scope 0 from 0",
    "Parameter self scope 4 from 143",
};

const using_facts = [_][]const u8{};

const using_references = [_][]const u8{
    "int Value Builtin scope 1",
    "Holder Value Bound(0) scope 2",
    "int Value Builtin scope 2",
    "self Value Bound(3) scope 3",
    "field Value Maybe scope 3",
    "Holder Value Bound(0) scope 4",
    "int Value Builtin scope 4",
    "missing Value Unresolved scope 5",
};

const using_scopes = [_][]const u8{
    "File none",
    "Item under 0",
    "Procedure under 0",
    "Block under 2 using",
    "Procedure under 0",
    "Block under 4",
};

const using_source =
    "package sample\n" ++
    "\n" ++
    "Holder :: struct {\n" ++
    "\tfield: int,\n" ++
    "}\n" ++
    "\n" ++
    "read :: proc(self: Holder) -> int {\n" ++
    "\tusing self\n" ++
    "\n" ++
    "\treturn field\n" ++
    "}\n" ++
    "\n" ++
    "plain :: proc(self: Holder) -> int {\n" ++
    "\treturn missing\n" ++
    "}\n";
