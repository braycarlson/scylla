const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const BindingClass = @import("../semantic.zig").BindingClass;
const Dialect = @import("dialect.zig").Dialect;
const EventsType = @import("../tree.zig").EventsType;
const FactKind = @import("../fact.zig").FactKind;
const Kind = @import("kind.zig").Kind;
const Parser = @import("parse.zig").Parser;
const Pick = @import("../semantic.zig").Pick;
const Position = @import("../semantic.zig").Position;
const ScopeClass = @import("../semantic.zig").ScopeClass;
const SemanticType = @import("../semantic.zig").SemanticType;
const Span = @import("../../stdx/bounded/span.zig");
const Structure = @import("../tree.zig").Structure;
const Token = @import("../token.zig");
const Tokens = @import("../tokens.zig");
const Tree = TreeType(Kind);
const TreeType = @import("../tree.zig").TreeType;
const frame_depth_max = @import("../tree.zig").frame_depth_max;
const is_ascii_whitespace = @import("../../text/scan.zig").is_ascii_whitespace;
const javascript_semantic = @This();
const lex = @import("lex.zig").lex;
const none = @import("../semantic.zig").none;
const raw_of = @import("../raw.zig").raw_of;
const scope_depth_max = @import("../semantic.zig").scope_depth_max;
const walk = @import("../tree.zig").walk;
const Binding = Semantic.Binding;
const Limits = @import("../semantic.zig").Limits;
const Reference = Semantic.Reference;
const Resolution = @import("../semantic.zig").Resolution;
pub const Semantic = SemanticType(Rules);

const Rules = struct {
    pub const BindingKind = javascript_semantic.BindingKind;
    pub const Extension = void;
    pub const Namespace = javascript_semantic.Namespace;
    pub const ScopeKind = javascript_semantic.ScopeKind;
    pub const binds_in = javascript_semantic.BindingKind.binds_in;
    pub const build = semantic_build;
    pub const class_of = javascript_semantic.BindingKind.class_of;
    pub const namespace_of = javascript_semantic.BindingKind.namespace_of;
    pub const pick: Pick = .newest;
    pub const scope_class_of = javascript_semantic.ScopeKind.class_of;
    pub const scopes_in_walk_order: bool = true;

    pub const BindingExtension = struct {
        parameter: u8,
    };

    pub const Options = struct {
        globals: []const []const u8,
        module: ?ModuleKind,
        typed: bool,
    };

    pub const ReferenceExtension = struct {
        positional: bool,
    };

    pub const ScopeExtension = struct {
        arrow: bool,
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

    pub fn chains_with(previous: Rules.BindingKind, kind: Rules.BindingKind) bool {
        assert(@backingInt(previous) < @typeInfo(Rules.BindingKind).@"enum".field_names.len);
        assert(@backingInt(kind) < @typeInfo(Rules.BindingKind).@"enum".field_names.len);

        return true;
    }

    pub fn crosses(scope: Rules.ScopeKind) bool {
        assert(@backingInt(scope) < @typeInfo(Rules.ScopeKind).@"enum".field_names.len);

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

        for (options.globals) |global| {
            if (std.mem.eql(u8, global, name)) return true;
        }

        return false;
    }

    pub fn lands(kind: Rules.BindingKind, scope: Rules.ScopeKind) bool {
        if (!kind.hoists()) return true;
        if (scope.holds_a_function()) return true;

        const result = !kind.hoists() or scope.holds_a_function();

        if (!kind.hoists()) assert(result);
        if (scope.is_root()) assert(result);

        return result;
    }

    pub fn retry_namespace(reference: *const Reference) ?Rules.Namespace {
        assert(reference.scope != none);

        return null;
    }

    pub fn skips(scope: Rules.ScopeKind, position: Position) bool {
        assert(@backingInt(scope) < @typeInfo(Rules.ScopeKind).@"enum".field_names.len);
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

    pub fn visible(
        held: *const Binding,
        reference: *const Reference,
        scope: Rules.ScopeKind,
        position: Position,
    ) bool {
        assert(reference.scope != none);
        assert(!position.redirected);
        assert(@backingInt(scope) < @typeInfo(Rules.ScopeKind).@"enum".field_names.len);

        if (held.from > 0) assert(held.kind.hoists());

        return reference.name.offset >= held.from;
    }
};

fn function_scope_of(semantic: *const Semantic, from: u32) ?u32 {
    assert(from < semantic.scope_count());

    var scope = from;

    for (0..scope_depth_max + 1) |_| {
        if (scope == none) return null;

        const held = semantic.scope_at(scope);

        assert(held.parent == none or held.parent < scope);

        if (held.kind.holds_a_function()) {
            if (!held.ext.arrow) return scope;
        }

        scope = held.parent;
    }

    return null;
}

fn semantic_build(
    semantic: *Semantic,
    source: []const u8,
    tokens: []const Token,
    raw: []const Kind,
    tree: *const TreeType(Kind),
    options: *const Rules.Options,
) Structure {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len == raw.len);

    semantic.clear();

    const held = options.module orelse module_of(tree);

    const kind: ScopeKind = switch (held) {
        .module => .module,
        .script => .global,
    };

    semantic.scope_root(kind, 0, .{ .arrow = false });

    var builder: Builder = .{
        .annex = !options.typed and held == .script,
        .depth = 0,
        .outcome = .complete,
        .parameter = parameter_none,
        .raw = raw,
        .semantic = semantic,
        .source = source,
        .stack = @splat(0),
        .tokens = tokens,
        .tree = tree,
    };

    builder.collect();
    semantic.resolve(source, options);

    assert(semantic.scope_count() >= 1);
    assert(semantic.scope_at(0).kind.is_root());

    return builder.outcome;
}

pub const BindingKind = enum {
    catch_parameter,
    class,
    @"const",
    @"enum",
    enum_member,
    function,
    import,
    import_default,
    import_namespace,
    import_type,
    interface,
    let,
    mapped_key,
    namespace,
    parameter,
    parameter_property,
    signature,
    type_alias,
    type_parameter,
    @"var",

    pub fn binds_in(kind: BindingKind, space: Namespace) bool {
        const result = switch (kind) {
            .class, .@"enum", .import, .import_default, .import_namespace, .namespace => true,
            .import_type => true,
            .interface, .mapped_key, .type_alias, .type_parameter => switch (space) {
                .any, .type => true,
                .query, .value => false,
            },
            .catch_parameter, .@"const", .enum_member, .function, .let => space != .type,
            .parameter, .parameter_property, .signature, .@"var" => space != .type,
        };

        if (space == .any) assert(result);
        if (kind.namespace_of() == space) assert(result);

        return result;
    }

    pub fn hoists(kind: BindingKind) bool {
        const result = switch (kind) {
            .function, .signature, .@"var" => true,
            else => false,
        };

        if (result) assert(kind.namespace_of() == .value);
        if (result) assert(!kind.zones());

        return result;
    }

    pub fn imports(kind: BindingKind) bool {
        const result = switch (kind) {
            .import, .import_default, .import_namespace, .import_type => true,
            else => false,
        };

        if (result) assert(!kind.hoists());
        if (result) assert(!kind.zones());

        return result;
    }

    pub fn namespace_of(kind: BindingKind) Namespace {
        const result: Namespace = switch (kind) {
            .import_type, .interface, .mapped_key, .type_alias, .type_parameter => .type,
            else => .value,
        };

        assert(result != .any);
        if (kind == .class) assert(result == .value);

        return result;
    }

    fn zones(kind: BindingKind) bool {
        const result = switch (kind) {
            .class, .@"const", .let => true,
            else => false,
        };

        if (result) assert(kind.namespace_of() == .value);
        if (kind == .@"var") assert(!result);

        return result;
    }

    pub fn class_of(kind: BindingKind) BindingClass {
        const class: BindingClass = switch (kind) {
            .catch_parameter, .parameter => .parameter,
            .class, .@"enum", .interface, .mapped_key, .type_alias, .type_parameter => .type,
            .@"const" => .constant,
            .enum_member => .variant,
            .function, .signature => .function,
            .import, .import_default, .import_namespace, .import_type => .import,
            .let, .@"var" => .local,
            .namespace => .other,
            .parameter_property => .field,
        };

        if (kind.imports()) assert(class == .import);
        if (kind == .parameter_property) assert(class == .field);

        return class;
    }
};

pub const ModuleKind = enum {
    module,
    script,
};

pub const Namespace = enum {
    any,
    query,
    type,
    value,
};

pub const Role = enum {
    ambient,
    arguments,
    array_pattern,
    arrow_function,
    assignment_expression,
    assignment_pattern,
    async_keyword,
    augmented_assignment,
    call_expression,
    call_signature,
    catch_clause,
    class,
    class_body,
    class_declaration,
    class_static_block,
    comma,
    comment,
    conditional_type,
    const_keyword,
    constant,
    default_keyword,
    enum_body,
    enum_declaration,
    equal,
    export_clause,
    export_specifier,
    export_statement,
    expression_statement,
    field_definition,
    for_in_statement,
    for_statement,
    formal_parameters,
    function_declaration,
    function_expression,
    function_signature,
    function_type,
    identifier,
    identifier_node,
    import_alias,
    import_clause,
    import_require,
    import_specifier,
    import_statement,
    index_signature,
    infer_type,
    interface_declaration,
    jsx_tag,
    labeled_statement,
    let_keyword,
    lexical_declaration,
    mapped_type_clause,
    member_expression,
    method_definition,
    method_signature,
    modifier,
    named_imports,
    namespace,
    namespace_export,
    namespace_import,
    nested_type,
    object_assignment_pattern,
    object_pattern,
    other,
    pair,
    pair_pattern,
    parameter,
    parenthesized_expression,
    program,
    property_identifier,
    rest_pattern,
    sequence_expression,
    shorthand_pattern_name,
    shorthand_property,
    star,
    statement_block,
    statement_identifier,
    string_node,
    switch_body,
    type_alias_declaration,
    type_identifier,
    type_parameter,
    type_parameters,
    type_predicate,
    type_query,
    undefined_name,
    update_expression,
    var_keyword,
    variable_declaration,
    variable_declarator,
    with_statement,
};

pub const ScopeKind = enum {
    ambient,
    block,
    @"catch",
    class,
    function,
    function_name,
    global,
    module,
    with,

    fn holds_a_function(kind: ScopeKind) bool {
        const result = switch (kind) {
            .ambient, .function, .global, .module => true,
            .block, .@"catch", .class, .function_name, .with => false,
        };

        if (kind.is_root()) assert(result);
        if (kind == .block) assert(!result);

        return result;
    }

    fn is_root(kind: ScopeKind) bool {
        const result = kind == .global or kind == .module;

        if (result) assert(kind != .function);
        if (kind == .ambient) assert(!result);

        return result;
    }

    pub fn class_of(kind: ScopeKind) ScopeClass {
        const class: ScopeClass = switch (kind) {
            .block, .@"catch", .with => .block,
            .class => .type,
            .function => .function,
            .function_name => .other,
            .ambient, .global, .module => .module,
        };

        if (kind.is_root()) assert(class == .module);
        if (kind == .class) assert(class == .type);

        return class;
    }
};

const Builder = struct {
    annex: bool,
    depth: u32,
    outcome: Structure,
    parameter: u8,
    raw: []const Kind,
    semantic: *Semantic,
    source: []const u8,
    stack: [scope_depth_max]u32,
    tokens: []const Token,
    tree: *const Tree,

    const roles = roles_of();

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

    fn role_of(builder: *const Builder, node: ?u32) Role {
        if (node) |held| assert(held < std.math.maxInt(u32));

        const held = node orelse return .other;

        assert(held < builder.tree.count());

        const kind = builder.tree.kind_at(held);

        assert(kind.is_node());

        return roles[@backingInt(kind)];
    }

    fn token_role(builder: *const Builder, position: u32) Role {
        assert(builder.raw.len == builder.tokens.len);
        assert(position < builder.raw.len);

        return roles[@backingInt(builder.raw[position])];
    }

    fn token_text(builder: *const Builder, position: u32) []const u8 {
        assert(builder.raw.len == builder.tokens.len);
        assert(position < builder.tokens.len);

        return builder.tokens[position].text(builder.source);
    }

    fn step_count(builder: *const Builder) u32 {
        const steps = builder.tree.count() *| 2 +| 1;

        assert(steps > 0);
        assert(steps >= builder.tree.count());

        return steps;
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

        var each = builder.children(node);
        var position: u32 = 0;

        for (0..builder.tree.count()) |_| {
            const child = each.next() orelse return null;
            if (position == index) return child;

            position += 1;
        }

        return null;
    }

    fn child_last(builder: *const Builder, node: u32) ?u32 {
        assert(node < builder.tree.count());

        var each = builder.children(node);
        var last: ?u32 = null;

        for (0..builder.tree.count()) |_| {
            last = each.next() orelse break;
        }

        if (last) |held| assert(held > node);

        return last;
    }

    fn parent_of(builder: *const Builder, node: ?u32) ?u32 {
        if (node) |held| assert(held < std.math.maxInt(u32));

        const held = node orelse return null;

        assert(held < builder.tree.count());

        const parent = builder.tree.parent_of(held);

        if (parent) |above| assert(above < held);

        return parent;
    }

    fn position_of(builder: *const Builder, parent: u32, child: u32) ?u32 {
        assert(parent < child);

        var each = builder.children(parent);
        var position: u32 = 0;

        for (0..builder.tree.count()) |_| {
            const held = each.next() orelse return null;
            if (held == child) return position;

            position += 1;
        }

        return null;
    }

    fn span_of(builder: *const Builder, node: u32) Span {
        assert(node < builder.tree.count());

        const span = builder.tree.at(node).span(Token, builder.tokens);

        assert(span.end() <= builder.source.len);

        return span;
    }

    fn text_of(builder: *const Builder, name: Span) []const u8 {
        assert(name.end() <= builder.source.len);

        const text = name.text(builder.source);

        assert(text.len == name.length);

        return text;
    }

    fn word_at(builder: *const Builder, node: u32, index: u32) []const u8 {
        assert(node < none);

        const held = builder.tree.at(node);
        var seen: u32 = 0;

        assert(held.token_start <= held.token_end);

        for (held.token_start..held.token_end) |position| {
            if (builder.token_role(@intCast(position)) == .comment) continue;
            if (seen == index) return builder.token_text(@intCast(position));

            seen += 1;
        }

        assert(seen <= held.token_end - held.token_start);

        return "";
    }

    fn typed_import(builder: *const Builder, node: u32) bool {
        assert(node < builder.tree.count());

        const typed = std.mem.eql(u8, builder.word_at(node, 1), "type");
        if (!typed) return false;
        return !std.mem.eql(u8, builder.word_at(node, 2), "from");
    }

    fn typed_specifier(builder: *const Builder, node: u32) bool {
        assert(node < builder.tree.count());

        if (!std.mem.eql(u8, builder.word_at(node, 0), "type")) return false;
        if (builder.word_at(node, 1).len == 0) return false;
        if (!std.mem.eql(u8, builder.word_at(node, 1), "as")) return true;
        return builder.word_at(node, 3).len != 0;
    }

    fn holds_token(builder: *const Builder, node: u32, role: Role, word: []const u8) bool {
        assert(node < none);
        assert(word.len <= std.math.maxInt(u32));

        const held = builder.tree.at(node);

        assert(held.token_start <= held.token_end);
        assert(role != .other);

        for (held.token_start..held.token_end) |position| {
            if (builder.token_role(@intCast(position)) != role) continue;
            if (word.len == 0) return true;
            if (std.mem.eql(u8, builder.token_text(@intCast(position)), word)) return true;
        }

        return false;
    }

    fn scope_kind_at(builder: *const Builder, node: u32, role: Role) ?ScopeKind {
        assert(node < builder.tree.count());

        const kind = scope_kind_of(role) orelse return null;
        const parent = builder.role_of(builder.parent_of(node));

        if (parent == .ambient) {
            if (role == .namespace) return .ambient;
            if (role == .statement_block) return .ambient;
        }

        if (parent == .namespace) {
            if (role == .statement_block) return null;
        }

        return kind;
    }

    fn enter(builder: *Builder, node: u32) void {
        assert(node < builder.tree.count());
        assert(builder.depth > 0);

        const role = builder.role_of(node);

        builder.before(node, role);

        if (builder.declines_the_conditional(node)) builder.escape();

        if (builder.scope_kind_at(node, role)) |kind| {
            if (builder.names_itself(node, role)) {
                builder.open(node, .function_name, false);
                builder.own_name(node, role);
            }

            builder.open(node, kind, role == .arrow_function);
            builder.opened(node, role);
        }

        if (builder.decorates_a_method(node)) builder.lift();

        builder.name_refer(node, role);
    }

    fn leave(builder: *Builder, node: u32) void {
        assert(node < builder.tree.count());
        assert(builder.depth > 0);

        const role = builder.role_of(node);

        if (role == .export_statement) builder.export_leave(node);

        if (builder.decorates_a_method(node)) {
            if (builder.depth > 1) builder.depth -= 1;

            return;
        }

        if (builder.scope_kind_at(node, role) == null) return;

        if (builder.depth > 1) builder.depth -= 1;
        if (!builder.names_itself(node, role)) return;

        if (builder.depth > 1) builder.depth -= 1;
    }

    fn names_itself(builder: *const Builder, node: u32, role: Role) bool {
        assert(node < builder.tree.count());

        if (role != .function_expression) return false;
        return builder.name_token_of(node) != null;
    }

    fn declines_the_conditional(builder: *const Builder, node: u32) bool {
        assert(node < none);

        const parent = builder.parent_of(node) orelse return false;

        assert(parent < node);

        if (builder.role_of(parent) != .conditional_type) return false;

        const child = builder.child_at(parent, 3) orelse return false;
        return child == node;
    }

    fn decorates_a_method(builder: *const Builder, node: u32) bool {
        assert(node < builder.tree.count());

        if (builder.tree.kind_at(node) != .decorator) return false;

        const parameter = builder.parent_of(node) orelse return false;
        const parameters = builder.parent_of(parameter) orelse return false;
        const method = builder.parent_of(parameters) orelse return false;

        if (builder.role_of(parameter) != .parameter) return false;
        if (builder.role_of(parameters) != .formal_parameters) return false;
        return builder.role_of(method) == .method_definition;
    }

    fn lift(builder: *Builder) void {
        const held = builder.scope_current();
        const parent = builder.semantic.scope_at(held).parent;

        assert(parent == none or parent < held);

        if (builder.depth >= scope_depth_max) {
            builder.outcome = .too_deep;

            return;
        }

        builder.stack[builder.depth] = if (parent == none) held else parent;
        builder.depth += 1;
    }

    fn escape(builder: *Builder) void {
        const held = builder.scope_current();
        const parent = builder.semantic.scope_at(held).parent;

        assert(parent == none or parent < held);

        if (parent != none) builder.stack[builder.depth - 1] = parent;
    }

    fn open(builder: *Builder, node: u32, kind: ScopeKind, arrow: bool) void {
        assert(node < none);

        const parent = builder.scope_current();
        const semantic = builder.semantic;

        assert(parent < semantic.scope_count());
        assert(!kind.is_root());

        const index = semantic.scope_open(parent, kind, node, .{ .arrow = arrow }) catch {
            if (builder.outcome == .complete) builder.outcome = .{ .truncated = .scopes };

            return;
        };

        if (kind == .with) semantic.scope_mark_dynamic(index);

        if (builder.depth >= scope_depth_max) {
            builder.outcome = .too_deep;

            return;
        }

        builder.stack[builder.depth] = index;
        builder.depth += 1;
    }

    fn opened(builder: *Builder, node: u32, role: Role) void {
        assert(node < builder.tree.count());
        assert(scope_kind_of(role) != null);

        switch (role) {
            .arrow_function => builder.arrow_parameter(node),
            .catch_clause => builder.catch_parameter(node),
            .enum_declaration => builder.enum_members(node),
            .for_in_statement => builder.iteration_declare(node),
            .class, .class_declaration => builder.own_name(node, role),
            else => {},
        }

        switch (role) {
            .arrow_function, .call_signature, .class, .class_declaration => {},
            .function_declaration, .function_expression, .function_signature => {},
            .function_type, .interface_declaration, .method_definition => {},
            .method_signature, .type_alias_declaration => {},
            else => return,
        }

        builder.type_parameters(node);
    }

    fn own_name(builder: *Builder, node: u32, role: Role) void {
        assert(node < none);

        const name = builder.name_token_of(node) orelse return;

        const kind: BindingKind = switch (role) {
            .class, .class_declaration => .class,
            else => .function,
        };

        assert(name.end() <= builder.source.len);
        assert(role != .other);

        builder.record_in(builder.scope_current(), &.{
            .dead_zone_end = none,
            .kind = kind,
            .name = name,
            .node = node,
        });
    }

    fn name_token_of(builder: *const Builder, node: u32) ?Span {
        assert(node < builder.tree.count());

        var held = node;

        for (0..builder.tree.count() + 1) |_| {
            var nested: ?u32 = null;
            var each = builder.children(held);

            for (0..builder.tree.count()) |_| {
                const child = each.next() orelse break;
                const role = builder.role_of(child);
                if (role == .identifier_node) return builder.span_of(child);
                if (role == .type_identifier) return builder.span_of(child);

                if (nested == null) {
                    if (role == .member_expression) nested = child;
                }
            }

            held = nested orelse return null;

            assert(held > node);
        }

        return null;
    }

    fn type_parameters(builder: *Builder, node: u32) void {
        assert(node < builder.tree.count());

        var each = builder.children(node);

        for (0..builder.tree.count()) |_| {
            const child = each.next() orelse break;
            if (builder.role_of(child) != .type_parameters) continue;

            var inner = builder.children(child);

            for (0..builder.tree.count()) |_| {
                const held = inner.next() orelse break;
                if (builder.role_of(held) != .type_parameter) continue;

                const name = builder.name_token_of(held) orelse continue;

                builder.record(&.{
                    .dead_zone_end = none,
                    .kind = .type_parameter,
                    .name = name,
                    .node = held,
                });
            }
        }

        assert(builder.depth > 0);
    }

    fn before(builder: *Builder, node: u32, role: Role) void {
        assert(node < builder.tree.count());
        assert(builder.depth > 0);

        switch (role) {
            .call_expression => builder.call_check(node),
            .class_declaration => builder.declaration_record(node, .class),
            .enum_declaration => builder.declaration_record(node, .@"enum"),
            .formal_parameters => builder.parameters_declare(node),
            .function_declaration => builder.function_record(node, .function),
            .function_signature => builder.function_record(node, .signature),
            .import_alias, .import_require => builder.import_equals(node),
            .import_statement => builder.import_declare(node),
            .infer_type => builder.infer_declare(node),
            .interface_declaration => builder.declaration_record(node, .interface),
            .lexical_declaration => builder.lexical_declare(node),
            .mapped_type_clause => builder.mapped_declare(node),
            .namespace => builder.declaration_record(node, .namespace),
            .type_alias_declaration => builder.declaration_record(node, .type_alias),
            .variable_declaration => builder.variable_declare(node),
            else => {},
        }
    }

    fn function_record(builder: *Builder, node: u32, kind: BindingKind) void {
        assert(node < none);

        const name = builder.name_token_of(node) orelse return;
        const scope = builder.scope_current();
        const landing = builder.semantic.scope_landing(scope, kind);
        const body = builder.body_scope(scope, landing);
        const hoisted = body == scope or builder.annexed(node, name, landing, body);

        assert(kind.hoists());
        assert(landing < builder.semantic.scope_count());

        builder.record_in(if (hoisted) landing else scope, &.{
            .dead_zone_end = none,
            .kind = kind,
            .name = name,
            .node = node,
        });
    }

    fn body_scope(builder: *const Builder, scope: u32, landing: u32) u32 {
        assert(scope < none);

        const semantic = builder.semantic;
        var held = scope;

        assert(scope < semantic.scope_count());
        assert(landing < semantic.scope_count());

        if (semantic.scope_at(landing).kind.is_root()) return landing;

        for (0..scope_depth_max + 1) |_| {
            if (held == landing) return landing;

            const parent = semantic.scope_at(held).parent;
            if (parent == none) return landing;
            if (parent == landing) break;

            held = parent;
        }

        const block = semantic.scope_at(held).node;
        const function = semantic.scope_at(landing).node;
        if (builder.parent_of(block) == function) return held;
        return landing;
    }

    fn body_start(builder: *const Builder, scope: u32, landing: u32, kind: BindingKind) u32 {
        assert(scope < builder.semantic.scope_count());
        assert(landing <= scope);

        if (!kind.hoists()) return 0;
        if (scope == landing) return 0;

        const block = builder.body_scope(scope, landing);
        if (block == landing) return 0;

        assert(builder.semantic.scope_at(block).parent == landing);

        const start = builder.span_of(builder.semantic.scope_at(block).node).offset;

        assert(start > 0);

        return start;
    }

    fn annexed(builder: *const Builder, node: u32, name: Span, landing: u32, body: u32) bool {
        assert(node < none);
        assert(name.length <= std.math.maxInt(u32) - name.offset);

        const first = builder.tree.at(node).token_start;
        const text = builder.text_of(name);
        const semantic = builder.semantic;

        assert(first < builder.tokens.len);
        assert(landing < semantic.scope_count());

        if (!builder.annex) return false;
        if (builder.tree.kind_at(node) == .generator_function_declaration) return false;
        if (builder.token_role(first) == .async_keyword) return false;
        if (builder.strict_at(node)) return false;
        if (semantic.binding_newest(builder.source, landing, text, null) != null) return false;
        if (body == landing) return true;
        return semantic.binding_newest(builder.source, body, text, null) == null;
    }

    fn strict_at(builder: *const Builder, node: u32) bool {
        assert(node < builder.tree.count());

        var held = builder.parent_of(node);

        assert(builder.annex);

        for (0..builder.tree.count()) |_| {
            const ancestor = held orelse return false;

            switch (builder.role_of(ancestor)) {
                .class, .class_declaration => return true,
                .program => return builder.directed(ancestor),
                .arrow_function, .function_declaration, .function_expression => {
                    if (builder.body_directed(ancestor)) return true;
                },
                .method_definition => {
                    if (builder.body_directed(ancestor)) return true;
                },
                else => {},
            }

            held = builder.parent_of(ancestor);
        }

        return false;
    }

    fn body_directed(builder: *const Builder, function: u32) bool {
        assert(function < builder.tree.count());

        var each = builder.children(function);

        assert(builder.annex);

        for (0..builder.tree.count()) |_| {
            const child = each.next() orelse return false;
            if (builder.role_of(child) == .statement_block) return builder.directed(child);
        }

        return false;
    }

    fn directed(builder: *const Builder, container: u32) bool {
        assert(container < builder.tree.count());

        var each = builder.children(container);

        assert(builder.annex);

        for (0..builder.tree.count()) |_| {
            const child = each.next() orelse return false;
            if (builder.role_of(child) != .expression_statement) return false;

            const held = builder.tree.at(child);
            const count = held.token_end - held.token_start;
            const terminated = count == 2 and builder.raw[held.token_end - 1] == .semicolon;

            if (builder.raw[held.token_start] != .string) return false;

            if (count != 1) {
                if (!terminated) return false;
            }

            const spelling = builder.token_text(held.token_start);
            if (std.mem.eql(u8, spelling, "\"use strict\"")) return true;
            if (std.mem.eql(u8, spelling, "'use strict'")) return true;
        }

        return false;
    }

    fn declaration_record(builder: *Builder, node: u32, kind: BindingKind) void {
        assert(node < none);

        const name = builder.name_token_of(node) orelse return;
        const zone = if (kind.zones()) builder.span_of(node).end() else none;

        assert(name.end() <= builder.source.len);
        assert(!kind.imports());

        builder.record(&.{ .dead_zone_end = zone, .kind = kind, .name = name, .node = node });
    }

    fn lexical_declare(builder: *Builder, node: u32) void {
        assert(node < none);

        const keyword = builder.holds_token(node, .const_keyword, "");
        const constant = keyword or builder.resource(node);
        const kind: BindingKind = if (constant) .@"const" else .let;
        var each = builder.children(node);

        assert(kind.zones());

        for (0..builder.tree.count()) |_| {
            const child = each.next() orelse break;
            if (builder.role_of(child) != .variable_declarator) continue;

            const zone = builder.span_of(child).end();
            const target = builder.child_at(child, 0);

            builder.pattern(target, .{ .bind = .{ .kind = kind, .zone = zone } });
        }

        assert(builder.depth > 0);
    }

    fn resource(builder: *const Builder, node: u32) bool {
        assert(node < none);

        const text = builder.text_of(builder.span_of(node));
        const head = if (std.mem.startsWith(u8, text, "await")) text["await".len..] else text;
        var start: usize = 0;

        assert(head.len <= text.len);

        for (head) |byte| {
            if (!is_ascii_whitespace(byte)) break;

            start += 1;
        }

        assert(start <= head.len);

        return std.mem.startsWith(u8, head[start..], "using");
    }

    fn variable_declare(builder: *Builder, node: u32) void {
        assert(node < builder.tree.count());

        var each = builder.children(node);

        for (0..builder.tree.count()) |_| {
            const child = each.next() orelse break;
            if (builder.role_of(child) != .variable_declarator) continue;

            const target = builder.child_at(child, 0);

            builder.pattern(target, .{ .bind = .{ .kind = .@"var", .zone = none } });
        }

        assert(builder.depth > 0);
    }

    fn parameters_declare(builder: *Builder, node: u32) void {
        assert(builder.parameter == parameter_none);
        assert(node < none);

        if (signs(builder.role_of(builder.parent_of(node)))) return;

        var position: u8 = 0;
        var each = builder.children(node);

        for (0..builder.tree.count()) |_| {
            const child = each.next() orelse break;

            const target = if (builder.role_of(child) == .parameter)
                builder.parameter_target(child)
            else
                child;

            const kind: BindingKind = if (builder.declares_a_field(child))
                .parameter_property
            else
                .parameter;

            const zone = builder.span_of(child).end();

            builder.parameter = position;

            builder.pattern(target, .{ .bind = .{ .kind = kind, .zone = zone } });
            position = @min(position +| 1, parameter_max);
        }

        builder.parameter = parameter_none;

        assert(position <= parameter_max);
    }

    fn parameter_target(builder: *const Builder, node: u32) ?u32 {
        assert(node < builder.tree.count());

        var each = builder.children(node);

        for (0..builder.tree.count()) |_| {
            const child = each.next() orelse break;
            if (builder.role_of(child) != .modifier) return child;
        }

        return null;
    }

    fn declares_a_field(builder: *const Builder, node: u32) bool {
        assert(node < none);

        const held = builder.tree.at(node);

        const stop = if (builder.parameter_target(node)) |target|
            builder.tree.at(target).token_start
        else
            held.token_end;

        assert(held.token_start <= stop);
        assert(stop <= held.token_end);

        for (held.token_start..stop) |position| {
            if (builder.token_role(@intCast(position)) == .comment) continue;

            const text = builder.token_text(@intCast(position));

            for (field_modifiers) |modifier| {
                if (std.mem.eql(u8, text, modifier)) return true;
            }
        }

        return false;
    }

    fn import_equals(builder: *Builder, node: u32) void {
        assert(node < none);

        const name = builder.name_token_of(node) orelse return;

        assert(name.end() <= builder.source.len);

        builder.record(&.{
            .dead_zone_end = none,
            .kind = .import,
            .name = name,
            .node = node,
        });

        const specifier = builder.specifier_of(node);
        if (is_empty(specifier)) return;

        assert(specifier.end() <= builder.source.len);

        builder.fact_push(.import_namespace, name, Span.empty, specifier);
    }

    fn infer_declare(builder: *Builder, node: u32) void {
        assert(node < none);

        const name = builder.name_token_of(node) orelse return;
        const scope = builder.conditional_scope();

        assert(scope < builder.semantic.scope_count());
        assert(name.end() <= builder.source.len);

        builder.record_in(scope, &.{
            .dead_zone_end = none,
            .kind = .type_parameter,
            .name = name,
            .node = node,
        });
    }

    fn mapped_declare(builder: *Builder, node: u32) void {
        assert(node < none);

        const name = builder.name_token_of(node) orelse return;
        const scope = builder.scope_current();

        assert(scope < builder.semantic.scope_count());
        assert(name.end() <= builder.source.len);

        builder.record_in(scope, &.{
            .dead_zone_end = none,
            .kind = .mapped_key,
            .name = name,
            .node = node,
        });
    }

    fn conditional_scope(builder: *const Builder) u32 {
        const innermost = builder.scope_current();
        var scope = innermost;

        for (0..scope_depth_max + 1) |_| {
            const held = builder.semantic.scope_at(scope);
            const role = builder.role_of(held.node);
            if (role == .conditional_type) return scope;
            if (held.parent == none) return innermost;

            if (!signs(role)) {
                if (role != .index_signature) return innermost;
            }

            assert(held.parent < scope);

            scope = held.parent;
        }

        assert(scope < builder.semantic.scope_count());

        return innermost;
    }

    fn arrow_parameter(builder: *Builder, node: u32) void {
        assert(node < none);

        const target = builder.child_at(node, 0) orelse return;
        if (builder.role_of(target) != .identifier_node) return;

        assert(target > node);
        assert(builder.parameter == parameter_none);

        builder.parameter = 0;

        builder.record(&.{
            .dead_zone_end = none,
            .kind = .parameter,
            .name = builder.span_of(target),
            .node = target,
        });

        builder.parameter = parameter_none;
    }

    fn enum_members(builder: *Builder, node: u32) void {
        assert(node < none);

        const body = builder.child_last(node) orelse return;
        if (builder.role_of(body) != .enum_body) return;

        assert(body > node);

        var each = builder.children(body);

        for (0..builder.tree.count()) |_| {
            const member = each.next() orelse break;
            const named = builder.member_name_of(member) orelse continue;

            builder.record(&.{
                .dead_zone_end = none,
                .kind = .enum_member,
                .name = builder.span_of(named),
                .node = named,
            });
        }

        assert(builder.depth > 0);
    }

    fn member_name_of(builder: *const Builder, member: u32) ?u32 {
        assert(member < builder.tree.count());

        if (names_a_member(builder.role_of(member))) return member;

        const first = builder.tree.child_first_of(member) orelse return null;

        assert(first > member);

        if (names_a_member(builder.role_of(first))) return first;
        return null;
    }

    fn iteration_declare(builder: *Builder, node: u32) void {
        assert(node < none);

        const target = builder.child_at(node, 0);
        const kind = builder.iteration_kind(node, target) orelse return;

        assert(target.? > node);
        assert(!kind.imports());

        builder.pattern(target, .{ .bind = .{ .kind = kind, .zone = none } });
    }

    fn iteration_kind(builder: *const Builder, node: u32, target: ?u32) ?BindingKind {
        assert(node < none);
        if (target) |held| assert(held < std.math.maxInt(u32));

        const found = target orelse return null;
        const held = builder.tree.at(node);
        const limit = builder.tree.at(found).token_start;

        assert(found > node);
        assert(held.token_start <= limit);

        for (held.token_start..limit) |position| {
            switch (builder.token_role(@intCast(position))) {
                .const_keyword => return .@"const",
                .let_keyword => return .let,
                .var_keyword => return .@"var",
                .identifier => {
                    const text = builder.token_text(@intCast(position));
                    if (std.mem.eql(u8, text, "using")) return .@"const";
                },
                else => {},
            }
        }

        return null;
    }

    fn catch_parameter(builder: *Builder, node: u32) void {
        assert(node < none);

        const target = builder.child_at(node, 0);

        assert(node < builder.tree.count());

        switch (builder.role_of(target)) {
            .statement_block, .other => return,
            else => {},
        }

        assert(target.? > node);

        builder.pattern(target, .{ .bind = .{ .kind = .catch_parameter, .zone = none } });
    }

    fn bound_record(builder: *Builder, node: u32, target: Target) void {
        assert(node < none);

        if (target == .bind) assert(target.bind.zone == none or
            target.bind.zone <= builder.source.len);

        const name = builder.span_of(node);

        assert(name.end() <= builder.source.len);
        assert(node < builder.tree.count());

        switch (target) {
            .bind => |bind| builder.record(&.{
                .dead_zone_end = bind.zone,
                .kind = bind.kind,
                .name = name,
                .node = node,
            }),
            .@"export" => builder.fact_push(.export_named, name, name, Span.empty),
        }
    }

    fn pattern(builder: *Builder, node: ?u32, target: Target) void {
        if (node) |held| assert(held < std.math.maxInt(u32));

        if (target == .bind) assert(target.bind.zone == none or
            target.bind.zone <= builder.source.len);

        const root = node orelse return;
        var stack: [pattern_depth_max]Pending = undefined;
        var depth: u32 = 1;

        stack[0] = .{ .node = root, .stop = builder.tree.sibling_next_of(root) };

        for (0..builder.step_count()) |_| {
            if (depth == 0) return;

            depth -= 1;

            const held = stack[depth];

            if (builder.pending_sibling(held)) |sibling| {
                stack[depth] = sibling;
                depth += 1;
            }

            const role = builder.role_of(held.node);

            switch (role) {
                .identifier_node, .shorthand_pattern_name, .undefined_name => {
                    builder.bound_record(held.node, target);

                    continue;
                },
                else => {},
            }

            const inner = inner_of(role) orelse continue;

            if (depth >= pattern_depth_max) {
                builder.outcome = .too_deep;

                return;
            }

            stack[depth] = builder.pending_inner(held.node, inner) orelse continue;
            depth += 1;
        }

        builder.outcome = .too_deep;
    }

    fn pending_sibling(builder: *const Builder, held: Pending) ?Pending {
        if (held.stop) |stop| assert(stop > held.node);

        const sibling = builder.tree.sibling_next_of(held.node) orelse return null;

        assert(sibling > held.node);

        if (held.stop) |stop| {
            if (stop == sibling) return null;
        }

        assert(sibling < builder.tree.count());

        return .{ .node = sibling, .stop = held.stop };
    }

    fn pending_inner(builder: *const Builder, node: u32, inner: Inner) ?Pending {
        assert(node < builder.tree.count());

        if (inner == .every) {
            const first = builder.tree.child_first_of(node) orelse return null;
            return .{ .node = first, .stop = null };
        }

        const index: u32 = if (inner == .first) 0 else 1;
        const child = builder.child_at(node, index) orelse return null;

        assert(child > node);

        return .{ .node = child, .stop = builder.tree.sibling_next_of(child) };
    }

    fn import_declare(builder: *Builder, node: u32) void {
        assert(node < none);

        const typed = builder.typed_import(node);
        const specifier = builder.specifier_of(node);
        var clauses: u32 = 0;
        var each = builder.children(node);

        assert(specifier.end() <= builder.source.len);

        for (0..builder.tree.count()) |_| {
            const child = each.next() orelse break;
            if (builder.role_of(child) != .import_clause) continue;

            clauses += 1;

            var inner = builder.children(child);

            for (0..builder.tree.count()) |_| {
                const held = inner.next() orelse break;

                builder.import_of(held, typed);
                builder.import_fact(held, typed, specifier);
            }
        }

        if (clauses > 0) return;
        if (is_empty(specifier)) return;

        builder.fact_push(.import_side_effect, Span.empty, Span.empty, specifier);
    }

    fn import_fact(builder: *Builder, node: u32, typed: bool, specifier: Span) void {
        assert(node < builder.tree.count());
        assert(specifier.end() <= builder.source.len);

        switch (builder.role_of(node)) {
            .identifier_node => {
                const local = builder.span_of(node);

                builder.fact_push(.import_default, local, Span.empty, specifier);
            },
            .namespace_import => {
                const local = builder.name_token_of(node) orelse Span.empty;

                builder.fact_push(.import_namespace, local, Span.empty, specifier);
            },
            .named_imports => {
                var each = builder.children(node);

                for (0..builder.tree.count()) |_| {
                    const held = each.next() orelse break;
                    if (builder.role_of(held) != .import_specifier) continue;

                    builder.import_specifier(held, typed, specifier);
                }
            },
            else => {},
        }
    }

    fn import_specifier(builder: *Builder, node: u32, typed: bool, specifier: Span) void {
        assert(node < none);

        const kind: FactKind = if (typed or builder.typed_specifier(node))
            .import_type
        else
            .import_named;

        const spans = builder.spans_named(node);

        assert(spans.last.end() <= builder.source.len);
        assert(specifier.end() <= builder.source.len);

        builder.fact_push(kind, spans.last, spans.first, specifier);
    }

    fn spans_named(builder: *const Builder, node: u32) Spans {
        assert(node < builder.tree.count());

        var spans: Spans = .{ .first = Span.empty, .last = Span.empty };
        var each = builder.children(node);

        for (0..builder.tree.count()) |_| {
            const child = each.next() orelse break;

            switch (builder.role_of(child)) {
                .identifier_node, .string_node, .type_identifier => {},
                else => continue,
            }

            const found = builder.span_of(child);

            if (is_empty(spans.first)) spans.first = found;

            spans.last = found;
        }

        if (is_empty(spans.last)) assert(is_empty(spans.first));

        return spans;
    }

    fn specifier_of(builder: *const Builder, node: u32) Span {
        assert(node < builder.tree.count());

        var each = builder.children(node);

        for (0..builder.tree.count()) |_| {
            const child = each.next() orelse break;
            if (builder.role_of(child) != .string_node) continue;

            const held = builder.span_of(child);
            if (held.length < 2) return held;

            switch (builder.source[held.offset]) {
                '"', '\'', '`' => {},
                else => return held,
            }

            assert(held.end() <= builder.source.len);

            return .{ .length = held.length - 2, .offset = held.offset + 1 };
        }

        return Span.empty;
    }

    fn fact_push(
        builder: *Builder,
        kind: FactKind,
        local: Span,
        remote: Span,
        specifier: Span,
    ) void {
        assert(local.end() <= builder.source.len);
        assert(remote.end() <= builder.source.len);

        builder.semantic.fact_push(.{
            .binding = .of(builder.binding_at(local)),
            .kind = kind,
            .local = local,
            .remote = remote,
            .specifier = specifier,
        }) catch |err| switch (err) {
            error.Truncated => {
                if (builder.outcome == .complete) builder.outcome = .{ .truncated = .facts };
            },
        };
    }

    fn binding_at(builder: *const Builder, local: Span) ?u32 {
        if (is_empty(local)) return null;

        const name = builder.text_of(local);

        const index = builder.semantic.binding_newest(builder.source, 0, name, null) orelse {
            return null;
        };

        assert(index < builder.semantic.count());
        assert(builder.semantic.at(index).scope == 0);

        return index;
    }

    fn export_leave(builder: *Builder, node: u32) void {
        assert(node < none);

        const specifier = builder.specifier_of(node);
        var named = false;
        var each = builder.children(node);

        assert(specifier.end() <= builder.source.len);

        for (0..builder.tree.count()) |_| {
            const child = each.next() orelse break;

            named = builder.export_of(child, specifier) or named;
        }

        if (named) return;

        if (builder.holds_token(node, .default_keyword, "")) {
            const local = builder.name_token_of(node) orelse Span.empty;

            builder.fact_push(.export_default, local, Span.empty, Span.empty);

            return;
        }

        if (is_empty(specifier)) return;

        builder.fact_push(.export_all, Span.empty, Span.empty, specifier);
    }

    fn export_of(builder: *Builder, node: u32, specifier: Span) bool {
        assert(node < none);
        assert(specifier.length <= std.math.maxInt(u32) - specifier.offset);

        var stack: [pattern_depth_max]Pending = undefined;
        var depth: u32 = 1;
        var named = false;

        stack[0] = .{ .node = node, .stop = builder.tree.sibling_next_of(node) };

        for (0..builder.step_count()) |_| {
            if (depth == 0) break;

            depth -= 1;

            const held = stack[depth];

            if (builder.pending_sibling(held)) |sibling| {
                stack[depth] = sibling;
                depth += 1;
            }

            if (builder.role_of(held.node) != .ambient) {
                named = builder.export_leaf(held.node, specifier) or named;

                continue;
            }

            const first = builder.tree.child_first_of(held.node) orelse continue;

            if (depth >= pattern_depth_max) break;

            stack[depth] = .{ .node = first, .stop = null };
            depth += 1;
        }

        assert(depth <= pattern_depth_max);

        return named;
    }

    fn export_leaf(builder: *Builder, node: u32, specifier: Span) bool {
        assert(node < builder.tree.count());
        assert(specifier.end() <= builder.source.len);

        switch (builder.role_of(node)) {
            .export_clause => {
                var each = builder.children(node);

                for (0..builder.tree.count()) |_| {
                    const held = each.next() orelse break;
                    if (builder.role_of(held) != .export_specifier) continue;

                    builder.export_specifier(held, specifier);
                }
            },
            .namespace_export => {
                const local = builder.name_token_of(node) orelse Span.empty;

                builder.fact_push(.export_all, local, Span.empty, specifier);
            },
            .class_declaration, .enum_declaration, .function_declaration, .function_signature => {
                builder.export_named(node);
            },
            .import_alias, .import_require, .interface_declaration => {
                builder.export_named(node);
            },
            .namespace, .type_alias_declaration => builder.export_named(node),
            .lexical_declaration, .variable_declaration => builder.export_declaration(node),
            else => return false,
        }

        return true;
    }

    fn export_named(builder: *Builder, node: u32) void {
        assert(node < none);

        const local = builder.name_token_of(node) orelse Span.empty;

        assert(local.end() <= builder.source.len);
        assert(node < builder.tree.count());

        builder.fact_push(.export_named, local, local, Span.empty);
    }

    fn export_declaration(builder: *Builder, node: u32) void {
        assert(node < builder.tree.count());

        var each = builder.children(node);

        for (0..builder.tree.count()) |_| {
            const child = each.next() orelse break;
            if (builder.role_of(child) != .variable_declarator) continue;

            builder.pattern(builder.child_at(child, 0), .@"export");
        }

        assert(builder.depth > 0);
    }

    fn export_specifier(builder: *Builder, node: u32, specifier: Span) void {
        assert(node < none);

        const spans = builder.spans_named(node);

        assert(spans.first.end() <= builder.source.len);
        assert(specifier.end() <= builder.source.len);

        if (is_empty(specifier)) {
            builder.fact_push(.export_named, spans.first, spans.last, Span.empty);

            return;
        }

        builder.fact_push(.reexport, spans.last, spans.first, specifier);
    }

    fn import_of(builder: *Builder, node: u32, typed: bool) void {
        assert(node < builder.tree.count());

        switch (builder.role_of(node)) {
            .identifier_node => builder.record(&.{
                .dead_zone_end = none,
                .kind = if (typed) .import_type else .import_default,
                .name = builder.span_of(node),
                .node = node,
            }),
            .namespace_import => {
                const name = builder.name_token_of(node) orelse return;

                builder.record(&.{
                    .dead_zone_end = none,
                    .kind = if (typed) .import_type else .import_namespace,
                    .name = name,
                    .node = node,
                });
            },
            .named_imports => {
                var each = builder.children(node);

                for (0..builder.tree.count()) |_| {
                    const held = each.next() orelse break;
                    if (builder.role_of(held) != .import_specifier) continue;

                    builder.specifier_bind(held, typed);
                }
            },
            else => {},
        }

        assert(builder.depth > 0);
    }

    fn specifier_bind(builder: *Builder, node: u32, typed: bool) void {
        assert(node < none);

        const kind: BindingKind = if (typed or builder.typed_specifier(node))
            .import_type
        else
            .import;

        var name: ?Span = null;
        var each = builder.children(node);

        assert(kind.imports());

        for (0..builder.tree.count()) |_| {
            const child = each.next() orelse break;

            switch (builder.role_of(child)) {
                .identifier_node, .type_identifier => name = builder.span_of(child),
                else => {},
            }
        }

        const found = name orelse return;

        assert(found.end() <= builder.source.len);

        builder.record(&.{ .dead_zone_end = none, .kind = kind, .name = found, .node = node });
    }

    fn call_check(builder: *Builder, node: u32) void {
        assert(node < none);

        const callee = builder.child_at(node, 0) orelse return;
        if (builder.role_of(callee) != .identifier_node) return;

        const name = builder.text_of(builder.span_of(callee));

        assert(callee > node);

        if (std.mem.eql(u8, name, "eval")) {
            builder.dynamic_flag();

            return;
        }

        if (!std.mem.eql(u8, name, "require")) return;

        const arguments = builder.child_at(node, 1) orelse return;
        if (builder.role_of(arguments) != .arguments) return;

        const first = builder.child_at(arguments, 0) orelse return;

        if (builder.role_of(first) != .string_node) {
            builder.dynamic_flag();

            return;
        }

        const specifier = builder.specifier_of(arguments);
        const local = builder.required_by(node);
        const kind: FactKind = if (is_empty(local)) .import_side_effect else .import_default;

        assert(specifier.end() <= builder.source.len);

        builder.fact_push(kind, local, Span.empty, specifier);
    }

    fn required_by(builder: *const Builder, node: u32) Span {
        assert(node < none);

        const parent = builder.parent_of(node) orelse return Span.empty;
        if (builder.role_of(parent) != .variable_declarator) return Span.empty;

        const target = builder.child_at(parent, 0) orelse return Span.empty;
        if (builder.role_of(target) != .identifier_node) return Span.empty;

        assert(parent < node);
        assert(target > parent);

        return builder.span_of(target);
    }

    fn dynamic_flag(builder: *Builder) void {
        const scope = builder.scope_current();

        assert(scope < builder.semantic.scope_count());

        builder.semantic.scope_mark_dynamic(scope);
    }

    fn name_refer(builder: *Builder, node: u32, role: Role) void {
        assert(node < none);

        switch (role) {
            .identifier_node, .shorthand_pattern_name, .shorthand_property => {},
            .type_identifier, .undefined_name => {},
            else => return,
        }

        const standing = builder.standing_of(node);
        if (standing == .bound) return;
        if (standing == .skip) return;

        const namespace = builder.namespace_at(node, role);

        if (role == .undefined_name) {
            if (namespace == .type) return;
        }

        builder.semantic.refer(builder.source, &.{
            .context = if (standing == .store) .store else .load,
            .dead_zone = false,
            .ext = .{ .positional = builder.positional_at(node) },
            .name = builder.span_of(node),
            .name_hash = 0,
            .namespace = namespace,
            .node = node,
            .resolution = .unresolved,
            .scope = builder.scope_current(),
        }) catch |err| switch (err) {
            error.Truncated => {
                if (builder.outcome == .complete) builder.outcome = .{ .truncated = .references };

                return;
            },
        };

        assert(builder.semantic.reference_count() > 0);
        assert(standing == .load or standing == .store);
    }

    fn namespace_at(builder: *const Builder, node: u32, role: Role) Namespace {
        assert(node < builder.tree.count());
        assert(role != .other);

        if (builder.role_of(builder.parent_of(node)) == .export_specifier) return .any;

        switch (builder.past_members(node)) {
            .export_statement => return .any,
            .type_query => return .query,
            else => {},
        }

        if (role == .type_identifier) return .type;
        if (builder.nested_type(node)) return .type;
        return .value;
    }

    fn nested_type(builder: *const Builder, node: u32) bool {
        assert(node < builder.tree.count());

        var held = builder.parent_of(node);

        for (0..frame_depth_max) |_| {
            const above = held orelse return false;
            const role = builder.role_of(above);
            if (role == .nested_type) return true;
            if (role != .member_expression) return false;

            held = builder.parent_of(above);
        }

        assert(held != null);

        return false;
    }

    fn past_members(builder: *const Builder, node: u32) Role {
        assert(node < builder.tree.count());

        var held = builder.parent_of(node);

        for (0..frame_depth_max) |_| {
            const above = held orelse return .other;
            const role = builder.role_of(above);

            const passed = switch (role) {
                .member_expression, .nested_type => true,
                else => builder.instantiation_queried(above),
            };

            if (!passed) return role;

            held = builder.parent_of(above);
        }

        assert(held != null);

        return .other;
    }

    fn instantiation_queried(builder: *const Builder, node: u32) bool {
        assert(node < builder.tree.count());

        if (builder.tree.kind_at(node) != .instantiation_expression) return false;
        return builder.role_of(builder.parent_of(node)) == .type_query;
    }

    fn positional_at(builder: *const Builder, node: u32) bool {
        assert(node < builder.tree.count());

        var held = builder.parent_of(node);

        for (0..frame_depth_max) |_| {
            const above = held orelse return false;
            const role = builder.role_of(above);
            if (role == .formal_parameters) return true;
            if (scope_kind_of(role) != null) return false;

            held = builder.parent_of(above);
        }

        assert(held != null);

        return false;
    }

    fn intrinsic(builder: *const Builder, node: u32) bool {
        assert(node < builder.tree.count());

        const name = builder.text_of(builder.span_of(node));

        if (name.len == 0) return false;
        if (std.ascii.isLower(name[0])) return true;
        return std.mem.findScalar(u8, name, '-') != null;
    }

    fn standing_of(builder: *const Builder, node: u32) Standing {
        assert(node < builder.tree.count());

        var child = node;
        var parent = builder.parent_of(node);

        for (0..frame_depth_max) |_| {
            const above = parent orelse break;
            const role = builder.role_of(above);
            const position = builder.position_of(above, child) orelse none;

            assert(above < child);

            if (builder.standing_special(above, child, role, position)) |held| return held;
            if (standing_in(role, position)) |held| return held;

            child = above;
            parent = builder.parent_of(above);
        }

        return .load;
    }

    fn standing_special(
        builder: *const Builder,
        parent: u32,
        child: u32,
        role: Role,
        position: u32,
    ) ?Standing {
        assert(parent < child);
        assert(child < builder.tree.count());

        switch (role) {
            .export_statement => return builder.reexports(parent),
            .jsx_tag => return if (builder.intrinsic(child)) .skip else .load,
            .for_in_statement => {
                if (position != 0) return null;

                const kind = builder.iteration_kind(parent, builder.child_at(parent, 0));
                return if (kind == null) .store else .bound;
            },
            .parameter => {
                const target = builder.parameter_target(parent) orelse none;
                return if (target == child) .bound else .load;
            },
            .member_expression => {
                if (position != 0) return null;
                if (builder.role_of(builder.parent_of(parent)) != .namespace) return null;
                return .bound;
            },
            else => return null,
        }
    }

    fn reexports(builder: *const Builder, node: u32) Standing {
        assert(node < builder.tree.count());

        var each = builder.children(node);

        for (0..builder.tree.count()) |_| {
            const child = each.next() orelse break;
            if (builder.role_of(child) == .string_node) return .skip;
        }

        assert(builder.role_of(node) == .export_statement);

        return .load;
    }

    fn record(builder: *Builder, declared: *const Declared) void {
        const scope = builder.semantic.scope_landing(builder.scope_current(), declared.kind);

        assert(scope < builder.semantic.scope_count());
        assert(declared.name.end() <= builder.source.len);

        builder.record_in(scope, declared);
    }

    fn record_in(builder: *Builder, scope: u32, declared: *const Declared) void {
        assert(scope < builder.semantic.scope_count());
        assert(declared.node < builder.tree.count());

        const from = builder.body_start(builder.scope_current(), scope, declared.kind);

        _ = builder.semantic.declare(builder.source, scope, &.{
            .dead_zone_end = declared.dead_zone_end,
            .ext = .{ .parameter = builder.parameter },
            .from = from,
            .kind = declared.kind,
            .name = declared.name,
            .node = declared.node,
        }) catch |err| switch (err) {
            error.Truncated => {
                if (builder.outcome == .complete) builder.outcome = .{ .truncated = .bindings };
            },
        };
    }
};

const Declared = struct {
    dead_zone_end: u32,
    kind: BindingKind,
    name: Span,
    node: u32,
};

const Inner = enum {
    every,
    first,
    second,
};

const Pending = struct {
    node: u32,
    stop: ?u32,
};

const Spans = struct {
    first: Span,
    last: Span,
};

const Standing = enum {
    bound,
    load,
    skip,
    store,
};

const Target = union(enum) {
    bind: Bind,
    @"export",

    const Bind = struct {
        kind: BindingKind,
        zone: u32,
    };
};

const parameter_max: u8 = std.math.maxInt(u8) - 1;
pub const parameter_none: u8 = std.math.maxInt(u8);
const pattern_depth_max: u32 = 1 << 8;
const field_modifiers = [_][]const u8{ "override", "private", "protected", "public", "readonly" };

comptime {
    assert(parameter_max < parameter_none);
    assert(pattern_depth_max <= scope_depth_max);
}

fn inner_of(role: Role) ?Inner {
    const inner: ?Inner = switch (role) {
        .array_pattern, .object_pattern => .every,
        .assignment_pattern, .object_assignment_pattern, .parameter, .rest_pattern => .first,
        .pair_pattern => .second,
        else => null,
    };

    if (role == .pair_pattern) assert(inner.? == .second);
    if (role == .other) assert(inner == null);

    return inner;
}

fn is_empty(span: Span) bool {
    assert(span.length <= std.math.maxInt(u32) - span.offset);

    const result = span.offset == 0 and span.length == 0;

    if (result) assert(span.end() == 0);
    if (span.length > 0) assert(!result);

    return result;
}

fn module_of(tree: *const TreeType(Kind)) ModuleKind {
    const roles = comptime roles_of();

    assert(tree.count() == tree.slice().len);

    for (tree.slice(), 0..) |node, index| {
        if (index == 0) continue;
        if (node.parent != 0) continue;

        switch (roles[@backingInt(node.kind)]) {
            .export_statement, .import_statement => return .module,
            else => {},
        }
    }

    assert(tree.count() < std.math.maxInt(u32));

    return .script;
}

fn names_a_member(role: Role) bool {
    const result = role == .property_identifier or role == .string_node;

    if (role == .other) assert(!result);
    if (role == .identifier_node) assert(!result);

    return result;
}

const RolePair = struct {
    kind: Kind,
    role: Role,
};

pub fn role_of_kind(kind: Kind) Role {
    const roles = comptime roles_of();

    comptime assert(roles.len == @typeInfo(Kind).@"enum".field_names.len);
    assert(@backingInt(kind) < roles.len);

    return roles[@backingInt(kind)];
}

fn roles_of() [@typeInfo(Kind).@"enum".field_names.len]Role {
    const pairs = &role_pairs;
    var roles: [@typeInfo(Kind).@"enum".field_names.len]Role = @splat(.other);

    @setEvalBranchQuota(1 << 16);

    for (pairs) |pair| {
        assert(roles[@backingInt(pair.kind)] == .other);

        roles[@backingInt(pair.kind)] = pair.role;
    }

    assert(roles[0] == .other);

    return roles;
}

fn scope_kind_of(role: Role) ?ScopeKind {
    const kind: ?ScopeKind = switch (role) {
        .arrow_function, .call_signature, .class_static_block, .function_declaration => .function,
        .function_expression, .function_signature, .function_type => .function,
        .method_definition, .method_signature, .namespace => .function,
        .catch_clause => .@"catch",
        .class, .class_declaration => .class,
        .conditional_type, .enum_declaration, .for_in_statement, .for_statement => .block,
        .index_signature, .interface_declaration, .statement_block, .switch_body => .block,
        .type_alias_declaration => .block,
        .with_statement => .with,
        else => null,
    };

    if (kind) |held| assert(!held.is_root());
    if (role == .other) assert(kind == null);

    return kind;
}

fn signs(role: Role) bool {
    const result = switch (role) {
        .call_signature, .function_signature, .function_type, .method_signature => true,
        else => false,
    };

    if (result) assert(scope_kind_of(role).? == .function);
    if (role == .function_declaration) assert(!result);

    return result;
}

fn standing_declared(role: Role, position: u32) ?Standing {
    const head: Standing = if (position == 0) .bound else .load;

    const standing: ?Standing = switch (role) {
        .formal_parameters, .parameter => .bound,
        .catch_clause, .class, .class_declaration, .enum_declaration => head,
        .function_declaration, .function_expression, .function_signature => head,
        .infer_type, .interface_declaration, .mapped_type_clause, .namespace => head,
        .type_alias_declaration, .type_parameter, .variable_declarator => head,
        .import_alias, .import_require => head,
        .import_clause, .import_specifier, .named_imports, .namespace_import => .bound,
        else => null,
    };

    if (role == .other) assert(standing == null);
    if (standing) |held| assert(held == .bound or held == .load);

    return standing;
}

fn standing_in(role: Role, position: u32) ?Standing {
    assert(position < none);

    if (standing_declared(role, position)) |held| return held;

    const head = position == 0;

    const standing: ?Standing = switch (role) {
        .array_pattern, .object_pattern, .rest_pattern, .export_clause => null,
        .parenthesized_expression => null,
        .assignment_pattern, .object_assignment_pattern => if (head) null else .load,
        .pair_pattern => if (position == 1) null else .skip,
        .export_specifier, .nested_type => if (head) null else .skip,
        .index_signature => if (head) .skip else .load,
        .namespace_export, .labeled_statement => .skip,
        .assignment_expression => if (head) .store else .load,
        .arrow_function => if (head) .bound else .load,
        else => .load,
    };

    if (role == .other) assert(standing.? == .load);
    if (role == .export_clause) assert(standing == null);

    return standing;
}

const role_pairs = [_]RolePair{
    .{ .kind = .async_keyword, .role = .async_keyword },
    .{ .kind = .comma, .role = .comma },
    .{ .kind = .comment, .role = .comment },
    .{ .kind = .const_keyword, .role = .const_keyword },
    .{ .kind = .default_keyword, .role = .default_keyword },
    .{ .kind = .equal, .role = .equal },
    .{ .kind = .identifier, .role = .identifier },
    .{ .kind = .let_keyword, .role = .let_keyword },
    .{ .kind = .star, .role = .star },
    .{ .kind = .var_keyword, .role = .var_keyword },
    .{ .kind = .abstract_class_declaration, .role = .class_declaration },
    .{ .kind = .abstract_method_signature, .role = .method_signature },
    .{ .kind = .accessibility_modifier, .role = .modifier },
    .{ .kind = .ambient_declaration, .role = .ambient },
    .{ .kind = .arguments, .role = .arguments },
    .{ .kind = .array_pattern, .role = .array_pattern },
    .{ .kind = .arrow_function, .role = .arrow_function },
    .{ .kind = .asserts, .role = .type_predicate },
    .{ .kind = .assignment_expression, .role = .assignment_expression },
    .{ .kind = .assignment_pattern, .role = .assignment_pattern },
    .{ .kind = .augmented_assignment_expression, .role = .augmented_assignment },
    .{ .kind = .call_expression, .role = .call_expression },
    .{ .kind = .call_signature, .role = .call_signature },
    .{ .kind = .catch_clause, .role = .catch_clause },
    .{ .kind = .class, .role = .class },
    .{ .kind = .class_body, .role = .class_body },
    .{ .kind = .class_declaration, .role = .class_declaration },
    .{ .kind = .class_static_block, .role = .class_static_block },
    .{ .kind = .conditional_type, .role = .conditional_type },
    .{ .kind = .construct_signature, .role = .call_signature },
    .{ .kind = .constructor_type, .role = .function_type },
    .{ .kind = .decorator, .role = .modifier },
    .{ .kind = .enum_body, .role = .enum_body },
    .{ .kind = .enum_declaration, .role = .enum_declaration },
    .{ .kind = .field_definition, .role = .field_definition },
    .{ .kind = .export_clause, .role = .export_clause },
    .{ .kind = .export_specifier, .role = .export_specifier },
    .{ .kind = .export_statement, .role = .export_statement },
    .{ .kind = .expression_statement, .role = .expression_statement },
    .{ .kind = .for_in_statement, .role = .for_in_statement },
    .{ .kind = .for_statement, .role = .for_statement },
    .{ .kind = .formal_parameters, .role = .formal_parameters },
    .{ .kind = .function_declaration, .role = .function_declaration },
    .{ .kind = .function_expression, .role = .function_expression },
    .{ .kind = .function_signature, .role = .function_signature },
    .{ .kind = .function_type, .role = .function_type },
    .{ .kind = .generator_function, .role = .function_expression },
    .{ .kind = .generator_function_declaration, .role = .function_declaration },
    .{ .kind = .identifier_node, .role = .identifier_node },
    .{ .kind = .import_alias, .role = .import_alias },
    .{ .kind = .import_clause, .role = .import_clause },
    .{ .kind = .import_require_clause, .role = .import_require },
    .{ .kind = .import_specifier, .role = .import_specifier },
    .{ .kind = .import_statement, .role = .import_statement },
    .{ .kind = .index_signature, .role = .index_signature },
    .{ .kind = .infer_type, .role = .infer_type },
    .{ .kind = .interface_declaration, .role = .interface_declaration },
    .{ .kind = .internal_module, .role = .namespace },
    .{ .kind = .jsx_closing_element, .role = .jsx_tag },
    .{ .kind = .jsx_opening_element, .role = .jsx_tag },
    .{ .kind = .jsx_self_closing_element, .role = .jsx_tag },
    .{ .kind = .labeled_statement, .role = .labeled_statement },
    .{ .kind = .lexical_declaration, .role = .lexical_declaration },
    .{ .kind = .mapped_type_clause, .role = .mapped_type_clause },
    .{ .kind = .member_expression, .role = .member_expression },
    .{ .kind = .method_definition, .role = .method_definition },
    .{ .kind = .method_signature, .role = .method_signature },
    .{ .kind = .module, .role = .namespace },
    .{ .kind = .named_imports, .role = .named_imports },
    .{ .kind = .namespace_export, .role = .namespace_export },
    .{ .kind = .namespace_import, .role = .namespace_import },
    .{ .kind = .nested_identifier, .role = .member_expression },
    .{ .kind = .nested_type_identifier, .role = .nested_type },
    .{ .kind = .number_node, .role = .constant },
    .{ .kind = .object_assignment_pattern, .role = .object_assignment_pattern },
    .{ .kind = .object_pattern, .role = .object_pattern },
    .{ .kind = .optional_parameter, .role = .parameter },
    .{ .kind = .override_modifier, .role = .modifier },
    .{ .kind = .pair, .role = .pair },
    .{ .kind = .pair_pattern, .role = .pair_pattern },
    .{ .kind = .parenthesized_expression, .role = .parenthesized_expression },
    .{ .kind = .program, .role = .program },
    .{ .kind = .property_identifier, .role = .property_identifier },
    .{ .kind = .public_field_definition, .role = .field_definition },
    .{ .kind = .regex_node, .role = .constant },
    .{ .kind = .required_parameter, .role = .parameter },
    .{ .kind = .rest_pattern, .role = .rest_pattern },
    .{ .kind = .rest_type, .role = .rest_pattern },
    .{ .kind = .sequence_expression, .role = .sequence_expression },
    .{ .kind = .shorthand_property_identifier, .role = .shorthand_property },
    .{ .kind = .shorthand_property_identifier_pattern, .role = .shorthand_pattern_name },
    .{ .kind = .statement_block, .role = .statement_block },
    .{ .kind = .statement_identifier, .role = .statement_identifier },
    .{ .kind = .string_node, .role = .string_node },
    .{ .kind = .switch_body, .role = .switch_body },
    .{ .kind = .template_string, .role = .constant },
    .{ .kind = .type_alias_declaration, .role = .type_alias_declaration },
    .{ .kind = .type_identifier, .role = .type_identifier },
    .{ .kind = .type_parameter, .role = .type_parameter },
    .{ .kind = .type_parameters, .role = .type_parameters },
    .{ .kind = .type_predicate, .role = .type_predicate },
    .{ .kind = .type_query, .role = .type_query },
    .{ .kind = .undefined, .role = .undefined_name },
    .{ .kind = .update_expression, .role = .update_expression },
    .{ .kind = .variable_declaration, .role = .variable_declaration },
    .{ .kind = .variable_declarator, .role = .variable_declarator },
    .{ .kind = .with_statement, .role = .with_statement },
};

const Expected = struct {
    kind: BindingKind,
    name: []const u8,
    scope: u32,
};

const ExpectedReference = struct {
    name: []const u8,
    resolution: Resolution,
};

const Found = struct {
    binding: Binding,
    index: u32,
};

const Fixture = struct {
    semantic: Semantic,
    source: []const u8,

    fn init(
        fixture: *Fixture,
        source: []const u8,
        dialect: ?Dialect,
        module: ?ModuleKind,
    ) !void {
        assert(source.len > 0);
        assert(source.len < fixture_token_count_max);

        try fixture.semantic.init(std.testing.allocator, &fixture_limits);
        errdefer fixture.semantic.deinit(std.testing.allocator);

        fixture.source = source;

        try fixture.parse(dialect orelse .javascript, module);
    }

    fn deinit(fixture: *Fixture) void {
        assert(fixture.source.len > 0);
        assert(fixture.semantic.heads.full());

        fixture.semantic.deinit(std.testing.allocator);
        fixture.* = undefined;
    }

    fn parse(fixture: *Fixture, dialect: Dialect, module: ?ModuleKind) !void {
        const gpa = std.testing.allocator;
        const source = fixture.source;

        assert(source.len > 0);
        assert(fixture.semantic.count() == 0);

        var tokens: Tokens = try .init(gpa, fixture_token_count_max);
        defer tokens.deinit(gpa);

        var raw: ArrayType(Kind) = try .init(gpa, fixture_token_count_max);
        defer raw.deinit(gpa);

        var events: EventsType(Kind) = undefined;

        try events.init(gpa, fixture_event_count_max);
        defer events.deinit(gpa);

        var tree: TreeType(Kind) = try .init(gpa, fixture_token_count_max, 1 << 8);
        defer tree.deinit(gpa);

        const parser = try gpa.create(Parser);
        defer gpa.destroy(parser);

        try lex(source, &tokens, dialect);
        try raw_of(Kind, tokens.slice(), &raw);

        const parsed = parser.build(
            source,
            tokens.slice(),
            raw.const_slice(),
            &events,
            &tree,
            .{ .dialect = dialect, .goal = .module },
        );

        try std.testing.expectEqual(.complete, parsed);

        const built = fixture.semantic.build(
            source,
            tokens.slice(),
            raw.const_slice(),
            &tree,
            &.{ .globals = &globals_test, .module = module, .typed = dialect.typed() },
        );

        try std.testing.expectEqual(.complete, built);
    }

    fn text_of(fixture: *const Fixture, span: Span) []const u8 {
        assert(span.end() <= fixture.source.len);
        assert(fixture.source.len > 0);

        return span.text(fixture.source);
    }

    fn field_of(fixture: *const Fixture, span: Span) []const u8 {
        assert(span.end() <= fixture.source.len);
        assert(fixture.source.len > 0);

        if (is_empty(span)) return ".";
        return fixture.text_of(span);
    }

    fn binding_at(fixture: *const Fixture, name: []const u8, nth: u32) !Found {
        var seen: u32 = 0;

        assert(name.len > 0);
        assert(fixture.semantic.scopes.count() > 0);

        for (fixture.semantic.binding_slice(), 0..) |held, index| {
            if (!std.mem.eql(u8, fixture.text_of(held.name), name)) continue;
            if (seen == nth) return .{ .binding = held, .index = @intCast(index) };

            seen += 1;
        }

        return error.TestUnexpectedResult;
    }

    fn reference_of(fixture: *const Fixture, name: []const u8, nth: u32) !Reference {
        var seen: u32 = 0;

        assert(name.len > 0);
        assert(fixture.semantic.scopes.count() > 0);

        for (fixture.semantic.reference_slice()) |held| {
            if (!std.mem.eql(u8, fixture.text_of(held.name), name)) continue;
            if (seen == nth) return held;

            seen += 1;
        }

        return error.TestUnexpectedResult;
    }

    fn resolution_of(fixture: *const Fixture, name: []const u8, nth: u32) Resolution {
        assert(name.len > 0);
        assert(fixture.semantic.scopes.count() > 0);
        assert(nth < none);

        const reference = fixture.reference_of(name, nth) catch return .unresolved;
        return reference.resolution;
    }

    fn scope_kind_of_binding(fixture: *const Fixture, binding: *const Binding) ScopeKind {
        assert(binding.scope < fixture.semantic.scopes.count());
        assert(binding.name.end() <= fixture.source.len);

        return fixture.semantic.scopes.get(binding.scope).kind;
    }

    fn expect_bindings(fixture: *const Fixture, expected: []const Expected) !void {
        const bindings = fixture.semantic.binding_slice();

        assert(expected.len > 0);
        assert(bindings.len == fixture.semantic.count());

        try std.testing.expectEqual(expected.len, bindings.len);

        for (expected, bindings) |want, held| {
            try std.testing.expectEqual(want.kind, held.kind);
            try std.testing.expectEqualStrings(want.name, fixture.text_of(held.name));
            try std.testing.expectEqual(want.scope, held.scope);
        }
    }

    fn expect_references(fixture: *const Fixture, expected: []const ExpectedReference) !void {
        const references = fixture.semantic.reference_slice();

        assert(expected.len > 0);
        assert(references.len <= fixture.semantic.references.capacity());

        try std.testing.expectEqual(expected.len, references.len);

        for (expected, references) |want, held| {
            try std.testing.expectEqualStrings(want.name, fixture.text_of(held.name));
            try std.testing.expectEqual(want.resolution, held.resolution);
        }
    }

    fn expect_facts(fixture: *const Fixture, expected: []const []const u8) !void {
        const facts = fixture.semantic.fact_slice();
        var buffer: [256]u8 = undefined;

        assert(expected.len > 0);
        assert(facts.len <= fixture.semantic.facts.items.capacity());

        try std.testing.expectEqual(expected.len, facts.len);

        for (expected, facts) |want, fact| {
            const line = try std.mem.print(&buffer, "{s} {s} {s} {s}", .{
                @tagName(fact.kind),
                fixture.field_of(fact.local),
                fixture.field_of(fact.remote),
                fixture.field_of(fact.specifier),
            });

            try std.testing.expectEqualStrings(want, line);
        }
    }
};

const fixture_event_count_max: u32 = 1 << 16;

const fixture_limits: Semantic.Limits = .{
    .binding_count_max = 1 << 10,
    .fact_count_max = 1 << 10,
    .reference_count_max = 1 << 12,
    .scope_count_max = 1 << 10,
};

const fixture_token_count_max: u32 = 1 << 14;
const globals_test = [_][]const u8{ "console", "eval", "require", "undefined" };

test "the scope chain runs block then function then the root" {
    var fixture: Fixture = undefined;

    try fixture.init(source_chain, null, null);
    defer fixture.deinit();

    const scopes = fixture.semantic.scope_slice();

    try std.testing.expectEqual(4, scopes.len);
    try std.testing.expectEqual(ScopeKind.global, scopes[0].kind);
    try std.testing.expectEqual(none, scopes[0].parent);
    try std.testing.expectEqual(ScopeKind.function, scopes[1].kind);
    try std.testing.expectEqual(0, scopes[1].parent);
    try std.testing.expectEqual(ScopeKind.block, scopes[2].kind);
    try std.testing.expectEqual(1, scopes[2].parent);
    try std.testing.expectEqual(ScopeKind.block, scopes[3].kind);
    try std.testing.expectEqual(2, scopes[3].parent);
    try std.testing.expectEqual(Resolution{ .bound = 0 }, fixture.resolution_of("outer", 0));
    try std.testing.expectEqual(Resolution{ .bound = 2 }, fixture.resolution_of("held", 0));
    try std.testing.expectEqual(Resolution{ .bound = 3 }, fixture.resolution_of("inner", 0));
}

test "a function declaration hoists and an expression names only itself" {
    var fixture: Fixture = undefined;

    try fixture.init(source_functions, null, null);
    defer fixture.deinit();

    const call = try fixture.binding_at("call", 0);
    const named = try fixture.binding_at("named", 0);

    try std.testing.expectEqual(BindingKind.function, call.binding.kind);
    try std.testing.expect(call.binding.kind.hoists());
    try std.testing.expectEqual(0, call.binding.scope);

    try std.testing.expectEqual(
        Resolution{ .bound = call.index },
        fixture.resolution_of("call", 0),
    );

    try std.testing.expect(named.binding.scope != 0);
    try std.testing.expectEqual(.unresolved, fixture.resolution_of("named", 0));

    try std.testing.expectEqual(
        Resolution{ .bound = named.index },
        fixture.resolution_of("named", 1),
    );
}

test "a named function expression keeps its name in a scope above its body" {
    var fixture: Fixture = undefined;

    try fixture.init(source_named, null, null);
    defer fixture.deinit();

    const name = try fixture.binding_at("range", 0);
    const shadow = try fixture.binding_at("range", 1);
    const parameter = try fixture.binding_at("inner", 1);
    const recur = try fixture.binding_at("recur", 0);

    try std.testing.expectEqual(.function_name, fixture.scope_kind_of_binding(&name.binding));
    try std.testing.expectEqual(.function, fixture.scope_kind_of_binding(&shadow.binding));
    try std.testing.expectEqual(none, shadow.binding.name_previous);

    try std.testing.expectEqual(
        fixture.semantic.scope_at(shadow.binding.scope).parent,
        name.binding.scope,
    );

    try std.testing.expectEqual(
        Resolution{ .bound = shadow.index },
        fixture.resolution_of("range", 0),
    );

    try std.testing.expectEqual(
        Resolution{ .bound = parameter.index },
        fixture.resolution_of("inner", 0),
    );

    try std.testing.expectEqual(
        Resolution{ .bound = recur.index },
        fixture.resolution_of("recur", 0),
    );
}

test "a var climbs past a block and merges with the var before it" {
    var fixture: Fixture = undefined;

    try fixture.init(source_var, null, null);
    defer fixture.deinit();

    const first = try fixture.binding_at("held", 0);
    const second = try fixture.binding_at("held", 1);
    const climbed = try fixture.binding_at("inner", 0);

    try std.testing.expectEqual(first.binding.scope, second.binding.scope);
    try std.testing.expect(first.binding.kind.hoists());
    try std.testing.expect(second.binding.kind.hoists());
    try std.testing.expectEqual(first.index, second.binding.name_previous);
    try std.testing.expectEqual(.function, fixture.scope_kind_of_binding(&first.binding));

    try std.testing.expectEqual(
        Resolution{ .bound = climbed.index },
        fixture.resolution_of("inner", 0),
    );
}

test "a lexical binding carries a dead zone and a redeclaration chains" {
    var fixture: Fixture = undefined;

    try fixture.init(source_lexical, null, null);
    defer fixture.deinit();

    const early = try fixture.binding_at("late", 0);
    const second = try fixture.binding_at("late", 1);
    const held = try fixture.reference_of("late", 0);
    const shape = try fixture.binding_at("Shape", 0);
    const redeclared = try fixture.binding_at("Shape", 2);

    try std.testing.expect(early.binding.dead_zone_end != none);
    try std.testing.expectEqual(early.index, second.binding.name_previous);
    try std.testing.expect(held.dead_zone);
    try std.testing.expect(held.resolution == .bound);
    try std.testing.expectEqual(shape.index, redeclared.binding.name_previous);
    try std.testing.expect(redeclared.binding.dead_zone_end != none);
}

test "a parameter binds in the function and a default reads only the ones before it" {
    var fixture: Fixture = undefined;

    try fixture.init(source_parameters, null, null);
    defer fixture.deinit();

    const first = try fixture.binding_at("first", 0);

    try std.testing.expectEqual(BindingKind.parameter, first.binding.kind);
    try std.testing.expectEqual(.function, fixture.scope_kind_of_binding(&first.binding));

    try std.testing.expectEqual(
        Resolution{ .bound = first.index },
        fixture.resolution_of("first", 0),
    );

    try std.testing.expectEqual(.unresolved, fixture.resolution_of("body", 0));
}

test "a signature resolves past the declarations its body hoists" {
    var fixture: Fixture = undefined;

    try fixture.init(source_signatures, .typescript, null);
    defer fixture.deinit();

    const outer = try fixture.binding_at("held", 0);
    const inner = try fixture.binding_at("held", 1);
    const named = try fixture.binding_at("named", 0);

    try std.testing.expectEqual(BindingKind.@"var", inner.binding.kind);
    try std.testing.expectEqual(.function, fixture.scope_kind_of_binding(&inner.binding));

    try std.testing.expectEqual(
        Resolution{ .bound = outer.index },
        fixture.resolution_of("held", 0),
    );

    try std.testing.expectEqual(
        Resolution{ .bound = inner.index },
        fixture.resolution_of("held", 1),
    );

    try std.testing.expectEqual(.unresolved, fixture.resolution_of("named", 0));

    try std.testing.expectEqual(
        Resolution{ .bound = named.index },
        fixture.resolution_of("named", 1),
    );
}

test "a default reads a parameter written after it inside that parameter's dead zone" {
    var fixture: Fixture = undefined;

    try fixture.init(source_forward, null, null);
    defer fixture.deinit();

    const first = try fixture.binding_at("first", 0);
    const second = try fixture.binding_at("second", 0);
    const early = try fixture.reference_of("second", 0);
    const late = try fixture.reference_of("first", 0);

    try std.testing.expectEqual(BindingKind.parameter, second.binding.kind);
    try std.testing.expectEqual(Resolution{ .bound = second.index }, early.resolution);
    try std.testing.expect(early.dead_zone);
    try std.testing.expectEqual(Resolution{ .bound = first.index }, late.resolution);
    try std.testing.expect(!late.dead_zone);
}

test "a decorator on a method parameter resolves outside the method" {
    var fixture: Fixture = undefined;

    try fixture.init(source_decorated, .typescript, null);
    defer fixture.deinit();

    const token = try fixture.binding_at("token", 0);
    const property = try fixture.binding_at("token", 1);

    try std.testing.expectEqual(BindingKind.@"const", token.binding.kind);
    try std.testing.expectEqual(BindingKind.parameter_property, property.binding.kind);

    try std.testing.expectEqual(
        Resolution{ .bound = token.index },
        fixture.resolution_of("token", 0),
    );

    try std.testing.expectEqual(.unresolved, fixture.resolution_of("first", 0));
}

test "an exported overload signature is an export of its own" {
    var fixture: Fixture = undefined;

    try fixture.init(source_overloads, .typescript, null);
    defer fixture.deinit();

    try fixture.expect_facts(&.{
        "export_named f f .",
        "export_named f f .",
        "export_named g g .",
    });
}

test "a catch parameter binds in its own scope and a var climbs past it" {
    var fixture: Fixture = undefined;

    try fixture.init(source_catch, null, null);
    defer fixture.deinit();

    const held = try fixture.binding_at("held", 0);
    const climbed = try fixture.binding_at("climbed", 0);

    try std.testing.expectEqual(BindingKind.catch_parameter, held.binding.kind);
    try std.testing.expectEqual(.@"catch", fixture.scope_kind_of_binding(&held.binding));

    try std.testing.expectEqual(
        Resolution{ .bound = held.index },
        fixture.resolution_of("held", 0),
    );

    try std.testing.expectEqual(.function, fixture.scope_kind_of_binding(&climbed.binding));

    try std.testing.expectEqual(
        Resolution{ .bound = climbed.index },
        fixture.resolution_of("climbed", 0),
    );
}

test "a method name is a property and a class expression names itself" {
    var fixture: Fixture = undefined;

    try fixture.init(source_classes, null, null);
    defer fixture.deinit();

    const named = try fixture.binding_at("Named", 0);

    try std.testing.expectError(error.TestUnexpectedResult, fixture.binding_at("area", 0));
    try std.testing.expectError(error.TestUnexpectedResult, fixture.binding_at("other", 0));
    try std.testing.expectEqual(.class, fixture.scope_kind_of_binding(&named.binding));

    try std.testing.expectEqual(
        Resolution{ .bound = named.index },
        fixture.resolution_of("Named", 0),
    );

    try std.testing.expectEqual(.unresolved, fixture.resolution_of("Named", 1));
}

test "an arrow owns no arguments and reads the function around it" {
    var fixture: Fixture = undefined;

    try fixture.init(source_arrows, null, null);
    defer fixture.deinit();

    const held = try fixture.reference_of("arguments", 0);
    const scope = fixture.semantic.scopes.get(held.scope);
    const owner = function_scope_of(&fixture.semantic, held.scope).?;

    try std.testing.expect(scope.ext.arrow);
    try std.testing.expectEqual(ScopeKind.function, scope.kind);
    try std.testing.expect(owner != held.scope);
    try std.testing.expect(!fixture.semantic.scopes.get(owner).ext.arrow);
}

test "a with statement and an eval call degrade a failed load to maybe" {
    var fixture: Fixture = undefined;

    try fixture.init(source_dynamic, null, null);
    defer fixture.deinit();

    try std.testing.expectEqual(.maybe, fixture.resolution_of("missing", 0));
    try std.testing.expectEqual(.maybe, fixture.resolution_of("absent", 0));
    try std.testing.expectEqual(.unresolved, fixture.resolution_of("elsewhere", 0));
}

test "an export reads its local and a reexport reads none" {
    var fixture: Fixture = undefined;

    try fixture.init(source_exports, null, null);
    defer fixture.deinit();

    const local = try fixture.binding_at("local", 0);

    try fixture.expect_references(&.{
        .{ .name = "local", .resolution = .{ .bound = local.index } },
        .{ .name = "local", .resolution = .{ .bound = local.index } },
    });

    try std.testing.expectEqual(ScopeKind.module, fixture.semantic.scope_at(0).kind);
}

test "an import binds each clause by its form" {
    var fixture: Fixture = undefined;

    try fixture.init(source_imports, null, null);
    defer fixture.deinit();

    try fixture.expect_bindings(&.{
        .{ .kind = .import_default, .name = "fallback", .scope = 0 },
        .{ .kind = .import_namespace, .name = "space", .scope = 0 },
        .{ .kind = .import, .name = "named", .scope = 0 },
        .{ .kind = .import, .name = "renamed", .scope = 0 },
        .{ .kind = .@"const", .name = "held", .scope = 0 },
    });
}

test "the module kind falls out of the syntax and the caller can override it" {
    var script: Fixture = undefined;

    try script.init("var held = 1;\n", null, null);
    defer script.deinit();

    var module: Fixture = undefined;

    try module.init("var held = 1;\n", null, .module);
    defer module.deinit();

    try std.testing.expectEqual(ScopeKind.global, script.semantic.scopes.get(0).kind);
    try std.testing.expectEqual(ScopeKind.module, module.semantic.scopes.get(0).kind);
}

test "the module facts name every form the source writes" {
    var fixture: Fixture = undefined;

    try fixture.init(source_facts, null, null);
    defer fixture.deinit();

    try fixture.expect_facts(&.{
        "import_default fallback . ./one",
        "import_namespace space . two",
        "import_named named named ./three/four",
        "import_named renamed aliased ./three/four",
        "import_side_effect . . ./side-effect",
        "import_default required . ./five",
        "import_side_effect . . ./six",
        "export_named first first .",
        "export_named second second .",
        "export_named Third Third .",
        "export_named first first .",
        "export_named second alias .",
        "export_default first . .",
        "export_all . . ./seven",
        "export_all bundle . ./eight",
        "reexport remote remote ./nine",
        "reexport renamedRemote other ./nine",
    });
}

test "every javascript specifier slices back to the text the source wrote" {
    var fixture: Fixture = undefined;

    try fixture.init(source_facts, null, null);
    defer fixture.deinit();

    var buffer: [256]u8 = undefined;
    var compared: u32 = 0;

    for (fixture.semantic.fact_slice()) |fact| {
        if (is_empty(fact.specifier)) continue;

        const quoted = try std.mem.print(&buffer, "\"{s}\"", .{fixture.text_of(fact.specifier)});

        try std.testing.expect(std.mem.find(u8, fixture.source, quoted) != null);

        compared += 1;
    }

    try std.testing.expect(compared > 6);
}

test "a binding a fact names carries the name the fact carries" {
    var fixture: Fixture = undefined;

    try fixture.init(source_facts, null, null);
    defer fixture.deinit();

    var compared: u32 = 0;

    for (fixture.semantic.fact_slice()) |fact| {
        const binding = fact.binding.unwrap() orelse continue;
        const held = fixture.semantic.at(binding);

        try std.testing.expectEqualStrings(fixture.text_of(held.name), fixture.text_of(fact.local));

        compared += 1;
    }

    try std.testing.expect(compared > 6);
}

test "a declaration merge chains both bindings" {
    var fixture: Fixture = undefined;

    try fixture.init(source_merges, .typescript, null);
    defer fixture.deinit();

    const first = try fixture.binding_at("Shape", 0);
    const second = try fixture.binding_at("Shape", 1);
    const class = try fixture.binding_at("Widget", 0);
    const own = try fixture.binding_at("Widget", 1);
    const interface = try fixture.binding_at("Widget", 2);
    const function = try fixture.binding_at("overload", 0);
    const namespace = try fixture.binding_at("overload", 1);

    try std.testing.expectEqual(first.index, second.binding.name_previous);
    try std.testing.expectEqual(BindingKind.class, class.binding.kind);
    try std.testing.expectEqual(BindingKind.class, own.binding.kind);
    try std.testing.expect(own.binding.scope != class.binding.scope);
    try std.testing.expectEqual(none, own.binding.name_previous);
    try std.testing.expectEqual(BindingKind.interface, interface.binding.kind);
    try std.testing.expectEqual(class.index, interface.binding.name_previous);
    try std.testing.expectEqual(BindingKind.function, function.binding.kind);
    try std.testing.expectEqual(BindingKind.namespace, namespace.binding.kind);
    try std.testing.expectEqual(function.index, namespace.binding.name_previous);
}

test "a type alias binds in the type space alone and a type only import in both" {
    var fixture: Fixture = undefined;

    try fixture.init(source_namespaces, .typescript, null);
    defer fixture.deinit();

    const alias = try fixture.binding_at("Alias", 0);
    const colour = try fixture.binding_at("Colour", 0);
    const remote = try fixture.binding_at("Remote", 0);

    try std.testing.expectEqual(Namespace.type, alias.binding.namespace);
    try std.testing.expect(!alias.binding.kind.binds_in(.value));

    try std.testing.expectEqual(
        Resolution{ .bound = alias.index },
        fixture.resolution_of("Alias", 0),
    );

    try std.testing.expect(colour.binding.kind.binds_in(.type));
    try std.testing.expect(colour.binding.kind.binds_in(.value));

    try std.testing.expectEqual(
        Resolution{ .bound = colour.index },
        fixture.resolution_of("Colour", 0),
    );

    try std.testing.expectEqual(
        Resolution{ .bound = colour.index },
        fixture.resolution_of("Colour", 1),
    );

    try std.testing.expectEqual(BindingKind.import_type, remote.binding.kind);
    try std.testing.expect(remote.binding.kind.binds_in(.type));
    try std.testing.expect(remote.binding.kind.binds_in(.value));

    try std.testing.expectEqual(
        Resolution{ .bound = remote.index },
        fixture.resolution_of("Remote", 0),
    );

    try std.testing.expectEqual(
        Resolution{ .bound = remote.index },
        fixture.resolution_of("Remote", 1),
    );
}

test "a type parameter binds beside the declaration that opens it" {
    var fixture: Fixture = undefined;

    try fixture.init(source_generics, .typescript, null);
    defer fixture.deinit();

    const held = try fixture.binding_at("Held", 0);
    const inner = try fixture.binding_at("Inner", 0);

    try std.testing.expectEqual(BindingKind.type_parameter, held.binding.kind);
    try std.testing.expectEqual(.function, fixture.scope_kind_of_binding(&held.binding));

    try std.testing.expectEqual(
        Resolution{ .bound = held.index },
        fixture.resolution_of("Held", 0),
    );

    try std.testing.expectEqual(.unresolved, fixture.resolution_of("Held", 2));

    try std.testing.expectEqual(
        Resolution{ .bound = inner.index },
        fixture.resolution_of("Inner", 0),
    );
}

test "a variance modifier leaves a type parameter its own name" {
    var fixture: Fixture = undefined;

    try fixture.init("interface O<out Shape, in A, const B> {}\n", .typescript, null);
    defer fixture.deinit();

    try fixture.expect_bindings(&.{
        .{ .kind = .interface, .name = "O", .scope = 0 },
        .{ .kind = .type_parameter, .name = "Shape", .scope = 1 },
        .{ .kind = .type_parameter, .name = "A", .scope = 1 },
        .{ .kind = .type_parameter, .name = "B", .scope = 1 },
    });
}

test "a type parameter may itself be named out" {
    var fixture: Fixture = undefined;

    try fixture.init("type Q<out> = out;\n", .typescript, null);
    defer fixture.deinit();

    const held = try fixture.binding_at("out", 0);

    try std.testing.expectEqual(BindingKind.type_parameter, held.binding.kind);
    try std.testing.expectEqual(Resolution{ .bound = held.index }, fixture.resolution_of("out", 0));
}

test "a signature names its parameters and declares none" {
    var fixture: Fixture = undefined;

    try fixture.init(
        \\type F = (k: string) => void;
        \\interface I { m(k: number): void; (k: number): void }
        \\declare function h(k: number): void;
        \\
    , .typescript, null);

    defer fixture.deinit();

    for (fixture.semantic.binding_slice()) |held| {
        try std.testing.expect(held.kind != .parameter);
    }
}

test "a parameter carrying a member modifier declares a field" {
    var fixture: Fixture = undefined;

    const source = "class C extends B { constructor(readonly cfg: T, private x: U, " ++
        "override span: V, plain: W) { super(); } }\n";

    try fixture.init(source, .typescript, null);
    defer fixture.deinit();

    const cfg = try fixture.binding_at("cfg", 0);
    const x = try fixture.binding_at("x", 0);
    const span = try fixture.binding_at("span", 0);
    const plain = try fixture.binding_at("plain", 0);

    try std.testing.expectEqual(BindingKind.parameter_property, cfg.binding.kind);
    try std.testing.expectEqual(BindingKind.parameter_property, x.binding.kind);
    try std.testing.expectEqual(BindingKind.parameter_property, span.binding.kind);
    try std.testing.expectEqual(BindingKind.parameter, plain.binding.kind);
}

test "a pattern binds its names in the order the source writes them" {
    var fixture: Fixture = undefined;

    try fixture.init("function f([first, second], { third }) {}\n", null, null);
    defer fixture.deinit();

    try fixture.expect_bindings(&.{
        .{ .kind = .function, .name = "f", .scope = 0 },
        .{ .kind = .parameter, .name = "first", .scope = 1 },
        .{ .kind = .parameter, .name = "second", .scope = 1 },
        .{ .kind = .parameter, .name = "third", .scope = 1 },
    });
}

test "a parameter carries the position it stands at" {
    var fixture: Fixture = undefined;

    try fixture.init("function f(first, [second, third]) {}\n", null, null);
    defer fixture.deinit();

    const first = try fixture.binding_at("first", 0);
    const second = try fixture.binding_at("second", 0);
    const third = try fixture.binding_at("third", 0);
    const named = try fixture.binding_at("f", 0);

    try std.testing.expectEqual(0, first.binding.ext.parameter);
    try std.testing.expectEqual(1, second.binding.ext.parameter);
    try std.testing.expectEqual(1, third.binding.ext.parameter);
    try std.testing.expectEqual(parameter_none, named.binding.ext.parameter);
}

test "a javascript binding kind maps onto the shared class" {
    var fixture: Fixture = undefined;

    try fixture.init("class Store {\n    constructor(private held) {}\n}\n", .typescript, null);
    defer fixture.deinit();

    const held = try fixture.binding_at("held", 0);
    const row = fixture.semantic.row(held.index);
    const scope = fixture.semantic.scope_row(held.binding.scope);

    try std.testing.expectEqual(BindingClass.field, row.class);
    try std.testing.expectEqual(held.binding.node, row.node);
    try std.testing.expectEqual(BindingClass.field, Rules.class_of(.parameter_property));
    try std.testing.expectEqual(ScopeClass.block, Rules.scope_class_of(.with));
    try std.testing.expectEqual(ScopeClass.function, scope.class);
    try std.testing.expectEqual(null, fixture.semantic.scope_row(0).parent);
}

test "a built in jsx tag looks for no declaration" {
    var fixture: Fixture = undefined;

    try fixture.init(
        \\import Comp from "m";
        \\const held = <div><Comp /><foo-bar /></div>;
        \\
    , .tsx, null);

    defer fixture.deinit();

    const comp = try fixture.binding_at("Comp", 0);

    try fixture.expect_references(&.{
        .{ .name = "Comp", .resolution = .{ .bound = comp.index } },
    });
}

test "a jsx component reads at its opening and its closing tag" {
    var fixture: Fixture = undefined;

    try fixture.init("const held = <Ns.T>text</Ns.T>;\n", .tsx, null);
    defer fixture.deinit();

    try fixture.expect_references(&.{
        .{ .name = "Ns", .resolution = .unresolved },
        .{ .name = "Ns", .resolution = .unresolved },
    });
}

test "an inline type specifier types only its own import" {
    var fixture: Fixture = undefined;

    try fixture.init("import { type A, b, type C, d } from \"m\";\n", .typescript, null);
    defer fixture.deinit();

    try fixture.expect_bindings(&.{
        .{ .kind = .import_type, .name = "A", .scope = 0 },
        .{ .kind = .import, .name = "b", .scope = 0 },
        .{ .kind = .import_type, .name = "C", .scope = 0 },
        .{ .kind = .import, .name = "d", .scope = 0 },
    });
}

test "an import named type is not a type only import" {
    var fixture: Fixture = undefined;
    const source = "import type from \"m\";\nimport { type as held } from \"m\";\n";

    try fixture.init(source, .typescript, null);
    defer fixture.deinit();

    try fixture.expect_bindings(&.{
        .{ .kind = .import_default, .name = "type", .scope = 0 },
        .{ .kind = .import, .name = "held", .scope = 0 },
    });
}

test "an import equals binds the name it writes" {
    var fixture: Fixture = undefined;

    try fixture.init("import held = require(\"m\");\nimport alias = A.B;\n", .typescript, null);
    defer fixture.deinit();

    try fixture.expect_bindings(&.{
        .{ .kind = .import, .name = "held", .scope = 0 },
        .{ .kind = .import, .name = "alias", .scope = 0 },
    });

    try fixture.expect_facts(&.{"import_namespace held . m"});
}

test "an exported pattern hands out every name it binds" {
    var fixture: Fixture = undefined;

    try fixture.init("export const { first, second: [third] } = held;\n", null, null);
    defer fixture.deinit();

    try fixture.expect_facts(&.{ "export_named first first .", "export_named third third ." });
}

test "an export clause reaches either space and names no alias" {
    var fixture: Fixture = undefined;

    try fixture.init("interface Held {}\nexport { Held, Held as other };\n", .typescript, null);
    defer fixture.deinit();

    const held = try fixture.binding_at("Held", 0);

    try fixture.expect_references(&.{
        .{ .name = "Held", .resolution = .{ .bound = held.index } },
        .{ .name = "Held", .resolution = .{ .bound = held.index } },
    });
}

test "an infer binds for the conditional type that holds it" {
    var fixture: Fixture = undefined;
    const source = "type J<T> = T extends (k: infer Held) => void ? Held : never;\n";

    try fixture.init(source, .typescript, null);
    defer fixture.deinit();

    const held = try fixture.binding_at("Held", 0);

    try std.testing.expectEqual(BindingKind.type_parameter, held.binding.kind);

    try std.testing.expectEqual(
        Resolution{ .bound = held.index },
        fixture.resolution_of("Held", 0),
    );
}

test "an infer under a mapped type or an index signature binds for the conditional type" {
    const sources = [_][]const u8{
        "type B<A, Key extends 'q'> = A extends { [K in Key]: infer Q } ? Q : never;\n",
        "type C<A> = A extends { [k: string]: infer Q } ? Q : never;\n",
        "type D<A> = A extends { [K in keyof A]: (x: infer Q) => void } ? Q : never;\n",
    };

    for (sources) |source| {
        var fixture: Fixture = undefined;

        try fixture.init(source, .typescript, null);
        defer fixture.deinit();

        const held = try fixture.binding_at("Q", 0);

        try std.testing.expectEqual(BindingKind.type_parameter, held.binding.kind);

        try std.testing.expectEqual(
            Resolution{ .bound = held.index },
            fixture.resolution_of("Q", 0),
        );
    }

    var fixture: Fixture = undefined;
    const source = "type E<A> = A extends { [K in keyof A]: infer Q } ? 1 : Q;\n";

    try fixture.init(source, .typescript, null);
    defer fixture.deinit();

    try std.testing.expectEqual(Resolution.unresolved, fixture.resolution_of("Q", 0));
}

test "a type predicate reads its parameter and an index signature names nothing" {
    var fixture: Fixture = undefined;

    try fixture.init(
        \\type P = (k: unknown) => k is string;
        \\interface I { [key: string]: unknown }
        \\
    , .typescript, null);

    defer fixture.deinit();

    try fixture.expect_references(&.{.{ .name = "k", .resolution = .unresolved }});
}

test "a dotted type name reads only its qualifier" {
    var fixture: Fixture = undefined;

    try fixture.init("import type { Ns } from \"m\";\ntype A = Ns.Props;\n", .typescript, null);
    defer fixture.deinit();

    const ns = try fixture.binding_at("Ns", 0);

    try fixture.expect_references(&.{.{ .name = "Ns", .resolution = .{ .bound = ns.index } }});
}

test "a typeof in the type space reaches a type only import" {
    var fixture: Fixture = undefined;
    const source = "import type { held } from \"m\";\ntype A = typeof held;\n";

    try fixture.init(source, .typescript, null);
    defer fixture.deinit();

    const binding = try fixture.binding_at("held", 0);

    try std.testing.expectEqual(
        Resolution{ .bound = binding.index },
        fixture.resolution_of("held", 0),
    );

    try std.testing.expectEqual(Namespace.query, (try fixture.reference_of("held", 0)).namespace);
}

test "a typeof with type arguments queries the value it instantiates" {
    var fixture: Fixture = undefined;

    const source = "const held = <T>(value: T) => value;\n" ++
        "type A = typeof held<string>;\n" ++
        "type B = typeof Math.max<number>;\n";

    try fixture.init(source, .typescript, null);
    defer fixture.deinit();

    const binding = try fixture.binding_at("held", 0);

    try std.testing.expectEqual(
        Resolution{ .bound = binding.index },
        fixture.resolution_of("held", 0),
    );

    try std.testing.expectEqual(Namespace.query, (try fixture.reference_of("held", 0)).namespace);
    try std.testing.expectEqual(Namespace.query, (try fixture.reference_of("Math", 0)).namespace);
}

test "an ambient module opens a scope of its own" {
    var fixture: Fixture = undefined;

    try fixture.init("declare module \"m\" { interface Held { a: number } }\n", .typescript, null);
    defer fixture.deinit();

    const held = try fixture.binding_at("Held", 0);
    const scope = fixture.semantic.scopes.get(held.binding.scope);

    try std.testing.expectEqual(ScopeKind.ambient, scope.kind);
    try std.testing.expectEqual(ScopeKind.global, fixture.semantic.scopes.get(scope.parent).kind);
}

test "a namespace written without declare opens a function scope" {
    var fixture: Fixture = undefined;

    try fixture.init("namespace M { interface Held { a: number } }\n", .typescript, null);
    defer fixture.deinit();

    const held = try fixture.binding_at("Held", 0);
    const scope = fixture.semantic.scopes.get(held.binding.scope);

    try std.testing.expectEqual(ScopeKind.function, scope.kind);
    try std.testing.expectEqual(ScopeKind.global, fixture.semantic.scopes.get(scope.parent).kind);
}

test "a name below a chain deeper than the scope bound still resolves" {
    const operands: [400][4]u8 = @splat(" | a".*);
    const members: [400][2]u8 = @splat(".b".*);

    const source = "const a = 1;\na" ++ std.mem.asBytes(&operands) ++ ";\na" ++
        std.mem.asBytes(&members) ++ ";\n";

    var fixture: Fixture = undefined;

    try fixture.init(source, null, null);
    defer fixture.deinit();

    const held = try fixture.binding_at("a", 0);
    const bound: Resolution = .{ .bound = held.index };

    try std.testing.expectEqual(bound, fixture.resolution_of("a", 0));
    try std.testing.expectEqual(bound, fixture.resolution_of("a", 400));
    try std.testing.expectEqual(bound, fixture.resolution_of("a", 401));
    try std.testing.expect(!(try fixture.reference_of("a", 0)).ext.positional);
}

const source_arrows =
    \\function outer() {
    \\    const inner = () => arguments;
    \\
    \\    return inner;
    \\}
    \\
;

const source_catch =
    \\function outer() {
    \\    try {
    \\        return 1;
    \\    } catch (held) {
    \\        var climbed = held;
    \\    }
    \\
    \\    return climbed;
    \\}
    \\
;

const source_chain =
    \\const outer = 1;
    \\
    \\function middle() {
    \\    const held = outer;
    \\
    \\    {
    \\        const inner = held;
    \\
    \\        return inner;
    \\    }
    \\}
    \\
;

const source_classes =
    \\class Shape {
    \\    area() {
    \\        return 1;
    \\    }
    \\}
    \\
    \\const held = class Named {
    \\    other() {
    \\        return Named;
    \\    }
    \\};
    \\
    \\const outside = Named;
    \\
;

const source_dynamic =
    \\function outer() {
    \\    with (held) {
    \\        return missing;
    \\    }
    \\}
    \\
    \\function other() {
    \\    eval("1");
    \\
    \\    return absent;
    \\}
    \\
    \\function third() {
    \\    return elsewhere;
    \\}
    \\
;

const source_exports =
    \\const local = 1;
    \\
    \\export { local };
    \\
    \\export default local;
    \\
    \\export * from "other";
    \\
    \\export { remote } from "other";
    \\
;

const source_facts =
    \\import fallback from "./one";
    \\import * as space from "two";
    \\import { named, aliased as renamed } from "./three/four";
    \\import "./side-effect";
    \\
    \\const required = require("./five");
    \\
    \\require("./six");
    \\
    \\export const first = 1;
    \\
    \\export function second() {}
    \\
    \\export class Third {}
    \\
    \\export { first, second as alias };
    \\
    \\export default first;
    \\
    \\export * from "./seven";
    \\
    \\export * as bundle from "./eight";
    \\
    \\export { remote, other as renamedRemote } from "./nine";
    \\
;

const source_forward =
    \\function outer(first = second, second = 1) {
    \\    return first;
    \\}
    \\
;

const source_functions =
    \\call();
    \\
    \\function call() {
    \\    return named;
    \\}
    \\
    \\const held = function named() {
    \\    return named;
    \\};
    \\
    \\const unnamed = function () {
    \\    return held;
    \\};
    \\
;

const source_imports =
    \\import fallback from "one";
    \\import * as space from "two";
    \\import { named, aliased as renamed } from "three";
    \\import "four";
    \\
    \\const held = [fallback, space, named, renamed];
    \\
;

const source_lexical =
    \\{
    \\    const early = late;
    \\    let late = 1;
    \\    let late = 2;
    \\}
    \\
    \\class Shape {}
    \\class Shape {}
    \\
;

const source_named =
    \\const held = function range(size) {
    \\    var range = size;
    \\
    \\    return range;
    \\};
    \\
    \\const other = function inner(inner) {
    \\    return inner;
    \\};
    \\
    \\const third = function recur() {
    \\    return recur;
    \\};
    \\
;

const source_parameters =
    \\function outer(first, second = first, third = body) {
    \\    const body = 1;
    \\
    \\    return second + third;
    \\}
    \\
;

const source_var =
    \\function outer() {
    \\    var held = 1;
    \\
    \\    {
    \\        var held = 2;
    \\
    \\        var inner = held;
    \\    }
    \\
    \\    return inner;
    \\}
    \\
;

const source_decorated =
    \\const token = 1;
    \\
    \\class Holder {
    \\    constructor(@Inject(token) public token: string) {}
    \\
    \\    method(first: number, @Inject(first) second: number) {
    \\        return second;
    \\    }
    \\}
    \\
;

const source_generics =
    \\function identity<Held>(one: Held): Held {
    \\    return one;
    \\}
    \\
    \\class Box<Inner> {
    \\    held: Inner;
    \\}
    \\
    \\type Pair<Left, Right> = [Left, Right];
    \\
    \\const escaped: Held = 1;
    \\
;

const source_merges =
    \\interface Shape {
    \\    area: number;
    \\}
    \\
    \\interface Shape {
    \\    name: string;
    \\}
    \\
    \\class Widget {}
    \\
    \\interface Widget {
    \\    extra: number;
    \\}
    \\
    \\function overload(one: number): number {
    \\    return one;
    \\}
    \\
    \\namespace overload {
    \\    export const version = 1;
    \\}
    \\
    \\const held: Shape = { area: 1, name: "a" };
    \\
;

const source_namespaces =
    \\type Alias = number;
    \\
    \\enum Colour {
    \\    Red,
    \\    Blue,
    \\}
    \\
    \\interface Only {
    \\    field: Alias;
    \\}
    \\
    \\import type { Remote } from "other";
    \\
    \\const value: Colour = Colour.Red;
    \\
    \\const typed: Remote = value;
    \\
    \\const missing: Only = value;
    \\
    \\const keyed = { [Remote]: value };
    \\
;

const source_overloads =
    \\export function f(value: string): string;
    \\export function f(value: unknown) {
    \\    return value;
    \\}
    \\
    \\export declare function g(): void;
    \\
;

const source_signatures =
    \\var held = 1;
    \\
    \\function outer(): typeof held {
    \\    var held = 2;
    \\
    \\    return held;
    \\}
    \\
    \\function other(): typeof named {
    \\    function named() {}
    \\
    \\    return named;
    \\}
    \\
;
