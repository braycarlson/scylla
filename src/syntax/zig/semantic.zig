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
        capture,
        @"const",
        field,
        function,
        label,
        parameter,
        @"var",
    };

    pub const Namespace = enum {
        field,
        label,
        value,
    };

    pub const Options = struct {
        globals: []const []const u8,
    };

    pub const ScopeKind = enum {
        block,
        container,
        function,

        pub fn is_ordered(kind: ScopeKind) bool {
            const result = kind != .container;

            if (kind == .container) assert(!result);
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
        semantic.scope_root(.container, 0, {});

        var builder: Builder = .{
            .depth = 0,
            .outcome = .complete,
            .raw = raw,
            .semantic = semantic,
            .source = source,
            .stack = undefined,
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
        return namespace_of(previous) == namespace_of(kind);
    }

    pub fn class_of(kind: BindingKind) BindingClass {
        const class: BindingClass = switch (kind) {
            .capture, .@"var" => .local,
            .@"const" => .constant,
            .field => .field,
            .function => .function,
            .label => .other,
            .parameter => .parameter,
        };

        if (kind == .field) assert(class == .field);
        if (kind == .label) assert(class == .other);

        return class;
    }

    pub fn crosses(scope: ScopeKind) bool {
        assert(@backingInt(scope) < @typeInfo(ScopeKind).@"enum".field_names.len);

        return false;
    }

    pub fn fallback(reference: *const Reference, dynamic_seen: bool) Resolution {
        assert(reference.resolution == .unresolved);
        assert(!dynamic_seen);

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
        const result: Namespace = switch (kind) {
            .field => .field,
            .label => .label,
            .capture, .@"const", .function, .parameter, .@"var" => .value,
        };

        if (kind == .field) assert(result == .field);
        if (kind == .label) assert(result == .label);

        return result;
    }

    pub fn order(reference: *const Reference, scope: ScopeKind, position: Position) Order {
        assert(reference.scope != none);
        assert(!position.redirected);
        assert(@backingInt(scope) < @typeInfo(ScopeKind).@"enum".field_names.len);

        return .from;
    }

    pub fn retry_namespace(reference: *const Reference) ?Namespace {
        assert(reference.scope != none);

        return null;
    }

    pub fn scope_class_of(kind: ScopeKind) ScopeClass {
        const class: ScopeClass = switch (kind) {
            .block => .block,
            .container => .type,
            .function => .function,
        };

        if (kind == .container) assert(class == .type);

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

    fn span_at(builder: *const Builder, position: u32) Span {
        assert(builder.raw.len == builder.tokens.len);
        assert(position < std.math.maxInt(u32));

        if (position >= builder.tokens.len) return Span.empty;

        const span = builder.tokens[position].span();

        assert(span.end() <= builder.source.len);

        return span;
    }

    fn own_next(builder: *const Builder, node: u32, from: u32) ?u32 {
        assert(node < none);
        assert(from < none);

        const held = builder.tree.at(node);
        var position = from;

        while (position < held.token_end) {
            if (builder.child_end_at(node, position)) |end| {
                assert(end > position);

                position = end;

                continue;
            }

            if (!builder.at(position).is_trivia()) return position;

            position += 1;
        }

        assert(position >= from);

        return null;
    }

    fn child_end_at(builder: *const Builder, node: u32, position: u32) ?u32 {
        assert(node < none);

        var held = builder.children(node);

        for (0..builder.tree.count()) |_| {
            const child = held.next() orelse break;
            const inner = builder.tree.at(child);

            assert(child > node);

            if (position >= inner.token_start) {
                if (position < inner.token_end) return inner.token_end;
            }
        }

        assert(held.node == null);

        return null;
    }

    fn opens(builder: *const Builder, node: u32) ?Rules.ScopeKind {
        assert(node < builder.tree.count());

        const kind = builder.kind_of(node);

        if (kind == .fn_proto) {
            if (builder.kind_of(builder.parent_of(node)) == .fn_decl) return null;
        }

        const scope_kind = scope_kind_of(kind);

        if (scope_kind) |held| assert(held != .function or kind == .fn_decl or kind == .fn_proto);

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
        assert(builder.kind_of(node) == kind);
        assert(builder.depth > 0);

        switch (kind) {
            .container_field => builder.field_declare(node),
            .fn_decl, .fn_proto => builder.function_declare(node),
            .var_decl => builder.variable_declare(node),
            else => {},
        }
    }

    fn after(builder: *Builder, node: u32, kind: Kind) void {
        assert(builder.kind_of(node) == kind);
        assert(builder.depth > 0);

        switch (kind) {
            .asm_output => builder.output_refer(node),
            .block => builder.label_declare(node),
            .@"break", .@"continue" => builder.branch_refer(node),
            .fn_decl, .fn_proto => builder.parameters_declare(node),
            .identifier_node => builder.name_refer(node),
            .@"catch",
            .@"errdefer",
            .@"for",
            .@"if",
            .switch_case,
            .@"while",
            => builder.captures_declare(node),
            else => {},
        }
    }

    fn variable_declare(builder: *Builder, node: u32) void {
        assert(builder.kind_of(node) == .var_decl);

        const keyword = builder.keyword_of(node, .const_keyword, .var_keyword) orelse return;
        const held = builder.own_next(node, keyword + 1) orelse return;

        assert(held > keyword);

        if (builder.at(held) != .identifier) return;

        const kind: Rules.BindingKind = if (builder.at(keyword) == .const_keyword)
            .@"const"
        else
            .@"var";

        const name = builder.span_at(held);

        const binding = builder.record(&.{
            .from = builder.end_of(node),
            .kind = kind,
            .name = name,
            .node = node,
        });

        builder.import_record(node, name, binding);
    }

    fn keyword_of(builder: *const Builder, node: u32, one: Kind, two: Kind) ?u32 {
        assert(one.is_token());
        assert(two.is_token());
        assert(node < none);

        var position = builder.tree.at(node).token_start;

        for (0..step_max) |_| {
            position = builder.own_next(node, position) orelse return null;

            const held = builder.at(position);
            if (held == one) return position;
            if (held == two) return position;

            position += 1;
        }

        return null;
    }

    fn import_record(builder: *Builder, node: u32, name: Span, binding: ?u32) void {
        assert(name.end() <= builder.source.len);
        assert(node < none);
        if (binding) |held| assert(held < std.math.maxInt(u32));

        var specifier = Span.empty;
        var held = builder.children(node);

        for (0..builder.tree.count()) |_| {
            const child = held.next() orelse break;
            if (builder.kind_of(child) != .builtin_call) continue;

            const call = builder.span_at(builder.tree.at(child).token_start);
            if (!std.mem.eql(u8, builder.text_of(call), "@import")) continue;

            specifier = builder.specifier_of(child) orelse specifier;
        }

        if (std.meta.eql(specifier, Span.empty)) return;

        assert(specifier.end() <= builder.source.len);

        builder.fact_push(&.{
            .binding = .of(binding),
            .kind = .import_named,
            .local = name,
            .remote = specifier,
            .specifier = specifier,
        });
    }

    fn specifier_of(builder: *const Builder, call: u32) ?Span {
        assert(builder.kind_of(call) == .builtin_call);

        var specifier: ?Span = null;
        var held = builder.children(call);

        for (0..builder.tree.count()) |_| {
            const inner = held.next() orelse break;
            if (builder.kind_of(inner) != .string_literal) continue;

            specifier = unquoted(builder.span_of(inner));
        }

        if (specifier) |span| assert(span.end() <= builder.source.len);

        return specifier;
    }

    fn function_declare(builder: *Builder, node: u32) void {
        assert(builder.kind_of(node) == .fn_decl or builder.kind_of(node) == .fn_proto);

        const signature = builder.signature_of(node) orelse return;
        const keyword = builder.keyword_of(signature, .fn_keyword, .fn_keyword) orelse return;
        const held = builder.own_next(signature, keyword + 1) orelse return;

        assert(held > keyword);

        if (builder.at(held) != .identifier) return;

        _ = builder.record(&.{
            .from = builder.end_of(node),
            .kind = .function,
            .name = builder.span_at(held),
            .node = node,
        });
    }

    fn signature_of(builder: *const Builder, node: u32) ?u32 {
        assert(node < none);

        const kind = builder.kind_of(node);

        assert(kind == .fn_decl or kind == .fn_proto);

        const signature = switch (kind) {
            .fn_decl => builder.proto_of(node),
            else => if (builder.kind_of(builder.parent_of(node)) == .fn_decl) null else node,
        };

        if (signature) |held| assert(builder.kind_of(held) == .fn_proto);

        return signature;
    }

    fn proto_of(builder: *const Builder, node: u32) ?u32 {
        assert(builder.kind_of(node) == .fn_decl);

        var held = builder.children(node);

        for (0..builder.tree.count()) |_| {
            const child = held.next() orelse break;
            if (builder.kind_of(child) == .fn_proto) return child;
        }

        assert(held.node == null);

        return null;
    }

    fn parameters_declare(builder: *Builder, node: u32) void {
        assert(builder.kind_of(node) == .fn_decl or builder.kind_of(node) == .fn_proto);

        const signature = builder.signature_of(node) orelse return;
        var position = builder.tree.at(signature).token_start;
        var depth: i32 = 0;

        assert(builder.kind_of(signature) == .fn_proto);

        for (0..step_max) |_| {
            position = builder.own_next(signature, position) orelse return;

            switch (builder.at(position)) {
                .paren_open => depth += 1,
                .paren_close => depth -= 1,
                .identifier => if (depth == 1) builder.parameter_declare(signature, position),
                else => {},
            }

            position += 1;
        }
    }

    fn parameter_declare(builder: *Builder, signature: u32, position: u32) void {
        assert(builder.kind_of(signature) == .fn_proto);
        assert(builder.at(position) == .identifier);

        const after_name = builder.own_next(signature, position + 1) orelse return;
        if (builder.at(after_name) != .colon) return;

        _ = builder.record(&.{
            .from = 0,
            .kind = .parameter,
            .name = builder.span_at(position),
            .node = signature,
        });
    }

    fn captures_declare(builder: *Builder, node: u32) void {
        assert(node < none);

        var position = builder.tree.at(node).token_start;
        var open_at: ?u32 = null;

        assert(builder.opens(node) == .block);

        for (0..step_max) |_| {
            position = builder.own_next(node, position) orelse break;

            if (builder.at(position) == .pipe) {
                if (open_at) |held| {
                    builder.captures_record(node, .{ .open = held, .close = position });
                    open_at = null;
                } else {
                    open_at = position;
                }
            }

            position += 1;
        }

        if (open_at) |held| assert(builder.at(held) == .pipe);
    }

    fn captures_record(builder: *Builder, node: u32, pipes: Pipes) void {
        assert(pipes.open < pipes.close);
        assert(builder.at(pipes.close) == .pipe);
        assert(node < none);

        const from = builder.span_at(pipes.close).offset + 1;
        var position = pipes.open + 1;

        while (position < pipes.close) : (position += 1) {
            if (builder.at(position) != .identifier) continue;

            _ = builder.record(&.{
                .from = from,
                .kind = .capture,
                .name = builder.span_at(position),
                .node = node,
            });
        }
    }

    fn field_declare(builder: *Builder, node: u32) void {
        assert(builder.kind_of(node) == .container_field);

        const position = builder.tree.at(node).token_start;
        if (builder.at(position) != .identifier) return;

        const binding = builder.record(&.{
            .from = 0,
            .kind = .field,
            .name = builder.span_at(position),
            .node = node,
        });

        if (binding) |held| assert(builder.semantic.at(held).namespace == .field);
    }

    fn label_declare(builder: *Builder, node: u32) void {
        assert(builder.kind_of(node) == .block);

        const position = builder.tree.at(node).token_start;
        if (builder.at(position) != .identifier) return;
        if (builder.at(position + 1) != .colon) return;

        const binding = builder.record(&.{
            .from = 0,
            .kind = .label,
            .name = builder.span_at(position),
            .node = node,
        });

        if (binding) |held| assert(builder.semantic.at(held).namespace == .label);
    }

    fn branch_refer(builder: *Builder, node: u32) void {
        assert(node < none);

        var position = builder.tree.at(node).token_start;
        var colon = false;

        assert(builder.kind_of(node) == .@"break" or builder.kind_of(node) == .@"continue");
        assert(builder.depth > 0);

        for (0..step_max) |_| {
            position = builder.own_next(node, position) orelse return;

            if (builder.at(position) == .colon) {
                colon = true;
            } else if (colon) {
                if (builder.at(position) == .identifier) {
                    builder.reference_push(.{
                        .context = .load,
                        .name = builder.span_at(position),
                        .namespace = .label,
                        .node = node,
                    });

                    return;
                }
            } else {}

            position += 1;
        }
    }

    fn name_refer(builder: *Builder, node: u32) void {
        assert(builder.kind_of(node) == .identifier_node);
        assert(node > 0);

        const parent = builder.parent_of(node);

        if (builder.kind_of(parent) == .container_field) {
            const start = builder.tree.at(node).token_start;
            if (builder.tree.at(parent.?).token_start == start) return;
        }

        const name = builder.span_of(node);
        if (std.mem.eql(u8, builder.text_of(name), "_")) return;

        builder.reference_push(.{
            .context = if (builder.stores(node)) .store else .load,
            .name = name,
            .namespace = .value,
            .node = node,
        });
    }

    fn output_refer(builder: *Builder, node: u32) void {
        assert(node < none);

        var position = builder.tree.at(node).token_start;
        var opening: ?u32 = null;

        assert(builder.kind_of(node) == .asm_output);
        assert(builder.depth > 0);

        for (0..step_max) |_| {
            position = builder.own_next(node, position) orelse return;

            if (builder.at(position) == .paren_open) {
                opening = position;

                break;
            }

            position += 1;
        }

        const operand = builder.own_next(node, (opening orelse return) + 1) orelse return;
        if (builder.at(operand) != .identifier) return;

        const name = builder.span_at(operand);
        if (std.mem.eql(u8, builder.text_of(name), "_")) return;

        builder.reference_push(.{
            .context = .store,
            .name = name,
            .namespace = .value,
            .node = node,
        });
    }

    fn stores(builder: *const Builder, node: u32) bool {
        assert(node < builder.tree.count());

        const parent = builder.parent_of(node) orelse return false;

        assert(parent < node);

        if (!assigns(builder.kind_of(parent))) return false;
        return builder.tree.at(parent).child_first == node;
    }

    fn reference_push(builder: *Builder, referred: Referred) void {
        const scope = builder.scope_current();
        const reference_count_before = builder.semantic.reference_count();

        assert(referred.name.end() <= builder.source.len);

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

        const index = semantic.declare(builder.source, scope, &.{
            .dead_zone_end = none,
            .ext = {},
            .from = if (ordered) declared.from else 0,
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

const Pipes = struct {
    open: u32,
    close: u32,
};

const Referred = struct {
    context: Context,
    name: Span,
    namespace: Rules.Namespace,
    node: u32,
};

const scope_depth_max = @import("../semantic.zig").scope_depth_max;
const step_max: u32 = 1 << 12;

comptime {
    assert(scope_depth_max < step_max);
}

fn scope_kind_of(kind: Kind) ?Rules.ScopeKind {
    assert(kind.is_node());

    const scope_kind: ?Rules.ScopeKind = switch (kind) {
        .container_decl, .error_set_decl, .tagged_union => .container,
        .fn_decl, .fn_proto => .function,
        .block, .@"catch", .@"errdefer", .@"for", .@"if", .switch_case, .@"while" => .block,
        else => null,
    };

    if (scope_kind != null) assert(kind.is_node());
    if (kind.is_token()) assert(scope_kind == null);

    return scope_kind;
}

fn assigns(kind: Kind) bool {
    assert(kind.is_node());

    const result = switch (kind) {
        .assign,
        .assign_add,
        .assign_add_sat,
        .assign_add_wrap,
        .assign_bit_and,
        .assign_bit_or,
        .assign_bit_xor,
        .assign_destructure,
        .assign_div,
        .assign_mod,
        .assign_mul,
        .assign_mul_sat,
        .assign_mul_wrap,
        .assign_shl,
        .assign_shl_sat,
        .assign_shr,
        .assign_sub,
        .assign_sub_sat,
        .assign_sub_wrap,
        => true,
        else => false,
    };

    if (result) assert(kind.is_node());
    if (kind.is_token()) assert(!result);

    return result;
}

fn unquoted(held: Span) Span {
    assert(held.length <= std.math.maxInt(u32) - held.offset);

    if (held.length < 2) return held;

    const inner: Span = .{ .offset = held.offset + 1, .length = held.length - 2 };

    assert(inner.end() + 1 == held.end());
    assert(inner.length + 2 == held.length);

    return inner;
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

            const actual = if (scope.parent == none)
                try std.mem.print(&buffer, "{s} none", .{kind})
            else
                try std.mem.print(&buffer, "{s} under {d}", .{ kind, scope.parent });

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

        assert(references.len <= limits_fixture.reference_count_max);
        assert(fixture.source.len > 0);
        var bound: [row_bytes_max]u8 = undefined;

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
            const actual = try std.mem.print(&buffer, "{s} {s} {s}", .{
                fact.kind.name(),
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

const universe_test = [_][]const u8{
    "bool",
    "false",
    "null",
    "true",
    "u8",
    "undefined",
    "usize",
    "void",
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

const blocks_bindings = [_][]const u8{
    "Function run scope 0 from 0",
    "Parameter one scope 1 from 0",
    "Const held scope 2 from 47",
    "Var kept scope 2 from 75",
    "Const held scope 3 from 109",
    "Const value scope 2 from 225",
    "Label blk scope 4 from 0",
    "Const inner scope 4 from 191",
    "Var index scope 2 from 252",
};

const blocks_facts = [_][]const u8{};

const blocks_references = [_][]const u8{
    "usize Value Builtin scope 1",
    "usize Value Builtin scope 1",
    "one Value Bound(1) scope 2",
    "usize Value Builtin scope 2",
    "held Value Bound(2) scope 2",
    "kept Value Bound(3) scope 3",
    "kept Value Bound(3) scope 3 store",
    "held Value Bound(4) scope 3",
    "kept Value Bound(3) scope 4",
    "blk Label Bound(6) scope 4",
    "inner Value Bound(7) scope 4",
    "usize Value Builtin scope 2",
    "index Value Bound(8) scope 5",
    "value Value Bound(5) scope 5",
    "index Value Bound(8) scope 5 store",
    "kept Value Bound(3) scope 6 store",
    "index Value Bound(8) scope 6",
    "kept Value Bound(3) scope 2",
    "value Value Bound(5) scope 2",
};

const blocks_scopes = [_][]const u8{
    "Container none",
    "Function under 0",
    "Block under 1",
    "Block under 2",
    "Block under 2",
    "Block under 2",
    "Block under 5",
};

const captures_bindings = [_][]const u8{
    "Function maybe scope 0 from 0",
    "Parameter value scope 1 from 0",
    "Function risky scope 0 from 0",
    "Parameter value scope 3 from 0",
    "Function teardown scope 0 from 0",
    "Parameter value scope 5 from 0",
    "Function run scope 0 from 0",
    "Parameter items scope 7 from 0",
    "Parameter seed scope 7 from 0",
    "Var held scope 8 from 223",
    "Capture value scope 9 from 254",
    "Capture err scope 11 from 320",
    "Capture item scope 13 from 425",
    "Capture index scope 13 from 425",
    "Capture value scope 15 from 496",
    "Capture other scope 18 from 594",
};

const captures_facts = [_][]const u8{};

const captures_references = [_][]const u8{
    "usize Value Builtin scope 1",
    "usize Value Builtin scope 1",
    "value Value Bound(1) scope 2",
    "usize Value Builtin scope 3",
    "usize Value Builtin scope 3",
    "value Value Bound(3) scope 4",
    "usize Value Builtin scope 5",
    "void Value Builtin scope 5",
    "value Value Bound(5) scope 6",
    "u8 Value Builtin scope 7",
    "usize Value Builtin scope 7",
    "usize Value Builtin scope 7",
    "seed Value Bound(8) scope 8",
    "maybe Value Bound(0) scope 9",
    "held Value Bound(9) scope 9",
    "held Value Bound(9) scope 10 store",
    "value Value Bound(10) scope 10",
    "held Value Bound(9) scope 8 store",
    "risky Value Bound(2) scope 11",
    "held Value Bound(9) scope 11",
    "teardown Value Bound(4) scope 12",
    "seed Value Bound(8) scope 12",
    "err Value Bound(11) scope 12",
    "items Value Bound(7) scope 13",
    "held Value Bound(9) scope 14 store",
    "item Value Bound(12) scope 14",
    "index Value Bound(13) scope 14",
    "maybe Value Bound(0) scope 15",
    "held Value Bound(9) scope 15",
    "held Value Bound(9) scope 16 store",
    "value Value Bound(14) scope 16",
    "held Value Bound(9) scope 8",
    "held Value Bound(9) scope 17 store",
    "held Value Bound(9) scope 18 store",
    "other Value Bound(15) scope 18",
    "held Value Bound(9) scope 8",
};

const captures_scopes = [_][]const u8{
    "Container none",
    "Function under 0",
    "Block under 1",
    "Function under 0",
    "Block under 3",
    "Function under 0",
    "Block under 5",
    "Function under 0",
    "Block under 7",
    "Block under 8",
    "Block under 9",
    "Block under 8",
    "Block under 11",
    "Block under 8",
    "Block under 13",
    "Block under 8",
    "Block under 15",
    "Block under 8",
    "Block under 8",
};

const containers_bindings = [_][]const u8{
    "Const Shade scope 0 from 0",
    "Field light scope 1 from 0",
    "Field dark scope 1 from 0",
    "Const Holder scope 0 from 0",
    "Field field scope 2 from 0",
    "Field shade scope 2 from 0",
    "Function build scope 2 from 0",
    "Parameter one scope 3 from 0",
    "Function read scope 2 from 0",
    "Parameter self scope 5 from 0",
    "Const Tagged scope 0 from 0",
    "Field light scope 7 from 0",
    "Field dark scope 7 from 0",
    "Const TOP scope 0 from 0",
    "Function top scope 0 from 0",
};

const containers_facts = [_][]const u8{};

const containers_references = [_][]const u8{
    "usize Value Builtin scope 2",
    "Shade Value Bound(0) scope 2",
    "usize Value Builtin scope 3",
    "Holder Value Bound(3) scope 3",
    "Holder Value Bound(3) scope 4",
    "one Value Bound(7) scope 4",
    "Holder Value Bound(3) scope 5",
    "usize Value Builtin scope 5",
    "self Value Bound(9) scope 6",
    "TOP Value Bound(13) scope 6",
    "Shade Value Bound(0) scope 7",
    "usize Value Builtin scope 7",
    "usize Value Builtin scope 7",
    "usize Value Builtin scope 0",
    "usize Value Builtin scope 8",
    "TOP Value Bound(13) scope 9",
};

const containers_scopes = [_][]const u8{
    "Container none",
    "Container under 0",
    "Container under 0",
    "Function under 2",
    "Block under 3",
    "Function under 2",
    "Block under 5",
    "Container under 0",
    "Function under 0",
    "Block under 8",
};

const deferred_bindings = [_][]const u8{
    "Function teardown scope 0 from 0",
    "Parameter value scope 1 from 0",
    "Function run scope 0 from 0",
    "Parameter seed scope 3 from 0",
    "Const held scope 4 from 100",
    "Const early scope 6 from 197",
    "Const one scope 7 from 278",
};

const deferred_facts = [_][]const u8{};

const deferred_references = [_][]const u8{
    "usize Value Builtin scope 1",
    "void Value Builtin scope 1",
    "value Value Bound(1) scope 2",
    "usize Value Builtin scope 3",
    "usize Value Builtin scope 3",
    "seed Value Bound(3) scope 4",
    "teardown Value Bound(0) scope 4",
    "held Value Bound(4) scope 4",
    "teardown Value Bound(0) scope 5",
    "held Value Bound(4) scope 5",
    "early Value Bound(5) scope 6",
    "held Value Bound(4) scope 4",
    "one Value Bound(6) scope 7",
};

const deferred_scopes = [_][]const u8{
    "Container none",
    "Function under 0",
    "Block under 1",
    "Function under 0",
    "Block under 3",
    "Block under 4",
    "Block under 4",
    "Block under 0",
};

const imports_bindings = [_][]const u8{
    "Const std scope 0 from 0",
    "Const builtin scope 0 from 0",
    "Const mem scope 0 from 0",
    "Function run scope 0 from 0",
    "Parameter one scope 1 from 0",
};

const imports_facts = [_][]const u8{
    "ImportNamed std std",
    "ImportNamed builtin builtin",
};

const imports_references = [_][]const u8{
    "std Value Bound(0) scope 0",
    "u8 Value Builtin scope 1",
    "usize Value Builtin scope 1",
    "mem Value Bound(2) scope 2",
    "one Value Bound(4) scope 2",
    "builtin Value Bound(1) scope 2",
};

const imports_scopes = [_][]const u8{
    "Container none",
    "Function under 0",
    "Block under 1",
};

test "a local opens at the end of the statement that writes it" {
    try fixture_expect(blocks_source, &.{
        .bindings = &blocks_bindings,
        .facts = &blocks_facts,
        .references = &blocks_references,
        .scopes = &blocks_scopes,
    });
}

test "a capture names its payload for the body it guards" {
    try fixture_expect(captures_source, &.{
        .bindings = &captures_bindings,
        .facts = &captures_facts,
        .references = &captures_references,
        .scopes = &captures_scopes,
    });
}

test "a container declaration is read from anywhere in its container" {
    try fixture_expect(containers_source, &.{
        .bindings = &containers_bindings,
        .facts = &containers_facts,
        .references = &containers_references,
        .scopes = &containers_scopes,
    });
}

test "a defer body reads the scope that holds the defer" {
    try fixture_expect(deferred_source, &.{
        .bindings = &deferred_bindings,
        .facts = &deferred_facts,
        .references = &deferred_references,
        .scopes = &deferred_scopes,
    });
}

test "an import binds through the constant it is assigned to" {
    try fixture_expect(imports_source, &.{
        .bindings = &imports_bindings,
        .facts = &imports_facts,
        .references = &imports_references,
        .scopes = &imports_scopes,
    });
}

test "every reference resolves into a scope on its own chain" {
    const sources = [_][]const u8{
        blocks_source,
        captures_source,
        containers_source,
        deferred_source,
        imports_source,
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

    try std.testing.expect(try fixture.build(containers_source) != .complete);
    try std.testing.expect(fixture.semantic.count() <= limits_starved.binding_count_max);
}

test "a zig binding kind maps onto the shared class" {
    const source = "fn run(one: usize) void {\n    _ = one;\n}\n";
    var fixture: Fixture = undefined;

    try fixture.init(&limits_fixture);
    defer fixture.deinit();

    try std.testing.expectEqual(.complete, try fixture.build(source));

    const row = fixture.semantic.row(1);

    try std.testing.expectEqual(BindingClass.local, Rules.class_of(.capture));
    try std.testing.expectEqual(BindingClass.parameter, row.class);
    try std.testing.expectEqual(fixture.semantic.at(1).node, row.node);
    try std.testing.expectEqual(ScopeClass.type, fixture.semantic.scope_row(0).class);
    try std.testing.expectEqual(null, fixture.semantic.scope_row(0).parent);
    try std.testing.expectEqual(0, fixture.semantic.scope_row(1).parent.?);
}

test "a bare enum field is a declaration and not also a reference to itself" {
    const source = "const Colour = enum { red, green };\n";
    var fixture: Fixture = undefined;
    var fields: u32 = 0;

    try fixture.init(&limits_fixture);
    defer fixture.deinit();

    try std.testing.expectEqual(.complete, try fixture.build(source));

    for (fixture.semantic.binding_slice()) |binding| {
        if (binding.kind != .field) continue;

        if (std.mem.eql(u8, binding.name.text(source), "red")) fields += 1;
    }

    try std.testing.expectEqual(1, fields);

    for (fixture.semantic.reference_slice()) |reference| {
        try std.testing.expect(!std.mem.eql(u8, reference.name.text(source), "red"));
    }
}

test "an asm output writes the variable it names" {
    const source = "fn run() u32 {\n" ++
        "    var held: u32 = undefined;\n" ++
        "    asm volatile (\"\"\n" ++
        "        : [_] \"=r\" (held),\n" ++
        "        : [_] \"r\" (held),\n" ++
        "    );\n" ++
        "    return held;\n" ++
        "}\n";

    var fixture: Fixture = undefined;
    var loads: u32 = 0;
    var stores: u32 = 0;

    try fixture.init(&limits_fixture);
    defer fixture.deinit();

    try std.testing.expectEqual(.complete, try fixture.build(source));

    for (fixture.semantic.reference_slice()) |reference| {
        if (!std.mem.eql(u8, reference.name.text(source), "held")) continue;

        const index = switch (reference.resolution) {
            .bound => |held| held,
            .builtin, .external, .maybe, .unresolved => return error.TestUnexpectedResult,
        };

        try std.testing.expectEqualStrings("held", fixture.semantic.at(index).name.text(source));

        switch (reference.context) {
            .delete => return error.TestUnexpectedResult,
            .load => loads += 1,
            .store => stores += 1,
        }
    }

    try std.testing.expectEqual(1, stores);
    try std.testing.expectEqual(2, loads);
}

const blocks_source =
    \\fn run(one: usize) usize {
    \\    const held = one;
    \\    var kept: usize = held;
    \\
    \\    {
    \\        const held = kept;
    \\
    \\        kept = held;
    \\    }
    \\
    \\    const value = blk: {
    \\        const inner = kept;
    \\
    \\        break :blk inner;
    \\    };
    \\
    \\    var index: usize = 0;
    \\
    \\    while (index < value) : (index += 1) {
    \\        kept += index;
    \\    }
    \\
    \\    return kept + value;
    \\}
    \\
;

const captures_source =
    \\fn maybe(value: usize) ?usize {
    \\    return value;
    \\}
    \\
    \\fn risky(value: usize) !usize {
    \\    return value;
    \\}
    \\
    \\fn teardown(value: usize) void {
    \\    _ = value;
    \\}
    \\
    \\fn run(items: []const u8, seed: usize) usize {
    \\    var held = seed;
    \\
    \\    if (maybe(held)) |value| {
    \\        held = value;
    \\    }
    \\
    \\    held = risky(held) catch |err| {
    \\        teardown(seed);
    \\        _ = err;
    \\
    \\        return 0;
    \\    };
    \\
    \\    for (items, 0..) |item, index| {
    \\        held += item + index;
    \\    }
    \\
    \\    while (maybe(held)) |value| {
    \\        held = value;
    \\    }
    \\
    \\    switch (held) {
    \\        0 => held = 1,
    \\        else => |other| held = other,
    \\    }
    \\
    \\    return held;
    \\}
    \\
;

const containers_source =
    \\const Shade = enum {
    \\    light,
    \\    dark,
    \\};
    \\
    \\const Holder = struct {
    \\    field: usize,
    \\    shade: Shade,
    \\
    \\    fn build(one: usize) Holder {
    \\        return Holder{ .field = one, .shade = .light };
    \\    }
    \\
    \\    fn read(self: Holder) usize {
    \\        return self.field + TOP;
    \\    }
    \\};
    \\
    \\const Tagged = union(Shade) {
    \\    light: usize,
    \\    dark: usize,
    \\};
    \\
    \\const TOP: usize = 4;
    \\
    \\fn top() usize {
    \\    return TOP;
    \\}
    \\
;

const deferred_source =
    \\fn teardown(value: usize) void {
    \\    _ = value;
    \\}
    \\
    \\fn run(seed: usize) usize {
    \\    const held = seed;
    \\
    \\    defer teardown(held);
    \\    errdefer teardown(held);
    \\
    \\    comptime {
    \\        const early = 1;
    \\
    \\        _ = early;
    \\    }
    \\
    \\    return held;
    \\}
    \\
    \\test "named" {
    \\    const one = 1;
    \\
    \\    _ = one;
    \\}
    \\
;

const imports_source =
    \\const std = @import("std");
    \\const builtin = @import("builtin");
    \\const mem = std.mem;
    \\
    \\fn run(one: []const u8) usize {
    \\    return mem.len(one) + @intFromBool(builtin.is_test);
    \\}
    \\
;
