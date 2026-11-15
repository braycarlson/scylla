const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const BindingClass = @import("../semantic.zig").BindingClass;
const EventsType = @import("../tree.zig").EventsType;
const FactKind = @import("../fact.zig").FactKind;
const Kind = @import("kind.zig").Kind;
const Parser = @import("parse.zig").Parser;
const Pick = @import("../semantic.zig").Pick;
const Position = @import("../semantic.zig").Position;
const Positions = @import("ast.zig").Positions;
const PythonVersion = @import("stdlib.zig").PythonVersion;
const Resource = @import("../tree.zig").Structure.Resource;
const ScopeClass = @import("../semantic.zig").ScopeClass;
const SemanticType = @import("../semantic.zig").SemanticType;
const Span = @import("../../stdx/bounded/span.zig");
const Structure = @import("../tree.zig").Structure;
const Tables = @import("bind.zig").Tables;
const Token = @import("../token.zig");
const Tokens = @import("../tokens.zig");
const TreeType = @import("../tree.zig").TreeType;
const View = @import("ast.zig").View;
const frame_depth_max = @import("../tree.zig").frame_depth_max;
const lex = @import("lex.zig").lex;
const literal = @import("literal.zig");
const name_hash = std.hash.Fnv1a_32.hash;
const none = @import("../semantic.zig").none;
const python_semantic = @This();
const raw_of = @import("../raw.zig").raw_of;
const stdlib = @import("stdlib.zig");
const walk = @import("../tree.zig").walk;
const walk_from = @import("../tree.zig").walk_from;
const StaticAllocator = @import("../../stdx/static_allocator.zig");
const bind = @import("bind.zig").bind;
const camel_of = @import("../category.zig").camel_of;
const Events = EventsType(Kind);
const Tree = TreeType(Kind);
const Binding = Semantic.Binding;
const Context = @import("../semantic.zig").Context;
const Reference = Semantic.Reference;
const Resolution = @import("../semantic.zig").Resolution;
pub const Semantic = SemanticType(Rules);

const Rules = struct {
    pub const BindingKind = python_semantic.BindingKind;
    pub const Extension = python_semantic.Extension;
    pub const Namespace = python_semantic.Namespace;
    pub const ScopeExtension = void;
    pub const ScopeKind = python_semantic.ScopeKind;
    pub const build = semantic_build;
    pub const class_of = python_semantic.BindingKind.class_of;
    pub const pick: Pick = .newest;
    pub const scope_class_of = python_semantic.ScopeKind.class_of;
    pub const scopes_in_walk_order: bool = true;

    pub const BindingExtension = struct {
        branch: u32,
        declared: ?Rules.BindingKind,
        flags: BindingFlags,
        order: u32,
    };

    pub const Options = struct {
        builtins: []const []const u8,
        version: PythonVersion,
    };

    pub const ReferenceExtension = struct {
        branch: u32,
        flags: ReferenceFlags,
        order: u32,
        relocated_by: u16,
    };

    pub fn after_resolve(semantic: *Semantic, source: []const u8, options: *const Options) void {
        assert(references_sorted(semantic.reference_slice()));
        assert(source.len <= std.math.maxInt(u32));
        assert(options.builtins.len <= std.math.maxInt(u32));

        mark_exports(semantic, source);
    }

    pub fn binds_in(kind: Rules.BindingKind, wanted: Rules.Namespace) bool {
        assert(wanted == .value);
        if (kind == .annotation) return false;

        return kind.answers();
    }

    pub fn chains_with(previous: Rules.BindingKind, kind: Rules.BindingKind) bool {
        assert(Rules.namespace_of(previous) == Rules.namespace_of(kind));

        return true;
    }

    pub fn crosses(scope: Rules.ScopeKind) bool {
        if (scope == .class) return false;

        const result = scope == .function or scope == .lambda;

        if (scope == .class) assert(!result);

        return result;
    }

    pub fn fallback(reference: *const Reference, dynamic_seen: bool) Resolution {
        assert(reference.resolution == .unresolved);
        assert(reference.namespace == .value);

        return if (dynamic_seen) .maybe else .unresolved;
    }

    pub fn is_builtin(name: []const u8, options: *const Options) bool {
        assert(name.len > 0);

        for (options.builtins) |builtin| {
            if (std.mem.eql(u8, builtin, name)) return true;
        }

        return stdlib.is_builtin(name, options.version);
    }

    pub fn lands(kind: Rules.BindingKind, scope: Rules.ScopeKind) bool {
        if (kind != .named) return true;
        if (scope != .comprehension) return true;

        const result = kind != .named or scope != .comprehension;

        if (kind != .named) assert(result);

        return result;
    }

    pub fn namespace_of(kind: Rules.BindingKind) Rules.Namespace {
        assert(@backingInt(kind) < @typeInfo(Rules.BindingKind).@"enum".field_names.len);

        return .value;
    }

    pub fn retry_namespace(reference: *const Reference) ?Rules.Namespace {
        assert(reference.namespace == .value);

        return null;
    }

    pub fn skips(scope: Rules.ScopeKind, position: Position) bool {
        if (scope != .class) return false;
        if (position.start) return false;

        const result = scope == .class and !position.start and !position.from_type;

        if (position.start) assert(!result);

        return result;
    }

    pub fn start_scope(
        semantic: *const Semantic,
        source: []const u8,
        reference: *const Reference,
    ) u32 {
        assert(reference.scope < semantic.scope_count());
        assert(reference.name.end() <= source.len);

        if (reference.ext.flags.forward) {
            if (forwarded(semantic, source, reference.name.text(source))) return 0;
        }

        const start = redirect_of(semantic, source, reference.scope, reference.name.text(source));
        if (start == reference.scope) return start;
        if (deleted_at_home(semantic, source, reference, start)) return reference.scope;
        return start;
    }

    pub fn types(scope: Rules.ScopeKind) bool {
        if (scope == .class) return false;

        const result = scope == .type or scope == .type_alias;

        if (scope == .class) assert(!result);

        return result;
    }

    pub fn visible(
        held: *const Binding,
        reference: *const Reference,
        scope: Rules.ScopeKind,
        position: Position,
    ) bool {
        assert(held.scope != none);
        assert(held.name.end() >= held.name.offset);
        if (position.redirected) assert(position.crossed_function);

        const flags = reference.ext.flags;
        const offset = reference.name.offset;
        const crossed = position.crossed_function;
        const positional = !flags.deferred and !position.redirected;

        if (reference.context == .delete) {
            if (!position.start) return false;
        }

        if (!positional) {
            if (crossed) return true;
            if (held.kind == .deletion) return held.from <= offset;
            return true;
        }

        if (crossed) return true;
        if (held.ext.order > reference.ext.order) return false;
        if (held.kind == .deletion) return held.from <= offset;

        const classed = scope == .class and held.kind != .named;
        const ordered = classed or held.kind.defines() or held.kind == .assignment;

        return !ordered or held.from <= offset;
    }
};

pub fn branch_slice(semantic: *const Semantic) []const Branch {
    const branches = semantic.ext.branches.const_slice();

    assert(branches.len <= semantic.ext.branches.capacity());
    if (branches.len > 0) assert(branches[0].parent == none);

    return branches;
}

pub fn branch_within(semantic: *const Semantic, branch: ?u32, ancestor: ?u32) bool {
    if (branch) |held| assert(held < std.math.maxInt(u32));

    const branches = &semantic.ext.branches;
    var held = branch;

    if (branch) |index| assert(index < branches.count());
    if (ancestor) |index| assert(index < branches.count());

    for (0..branch_depth_max + 1) |_| {
        if (held == ancestor) return true;

        const index = held orelse return false;
        const parent = branches.get(index).parent;

        held = if (parent == none) null else parent;
    }

    return false;
}

pub fn chain_used(semantic: *const Semantic, source: []const u8, binding: ?u32) bool {
    assert(source.len <= std.math.maxInt(u32));
    if (binding) |held| assert(held < std.math.maxInt(u32));

    const held = get(semantic, binding) orelse return false;
    var index = semantic.binding_newest(source, held.scope, held.name.text(source), null);

    assert(held.scope < semantic.scope_count());

    for (0..semantic.count() + 1) |_| {
        const current = index orelse break;
        if (is_used(semantic, current)) return true;

        const shadowed = semantic.at(current).name_previous;

        assert(shadowed == none or shadowed < current);

        if (shadowed == none) break;
        if (semantic.at(shadowed).kind == .deletion) break;

        index = shadowed;
    }

    return false;
}

pub fn export_slice(semantic: *const Semantic) []const Span {
    const exports = semantic.ext.exports.const_slice();

    assert(exports.len <= semantic.ext.exports.capacity());
    if (exports.len > 0) assert(semantic.scope_count() > 0);

    return exports;
}

pub fn get(semantic: *const Semantic, index: ?u32) ?Binding {
    if (index) |held| assert(held < std.math.maxInt(u32));

    const held = index orelse return null;
    if (held >= semantic.count()) return null;

    const binding = semantic.at(held);

    assert(binding.scope < semantic.scope_count());
    assert(binding.name_previous == none or binding.name_previous < held);

    return binding;
}

pub fn is_used(semantic: *const Semantic, binding: ?u32) bool {
    if (binding) |held| assert(held < std.math.maxInt(u32));

    const held = get(semantic, binding) orelse return false;

    assert(held.name_previous == none or held.name_previous < binding.?);
    assert(held.scope < semantic.scope_count());

    return held.reference_count > 0;
}

pub fn matches(
    semantic: *const Semantic,
    source: []const u8,
    view: View,
    module: []const u8,
    member: []const u8,
    out: *ArrayType(Span),
) bool {
    assert(member.len > 0);
    assert(module.len > 0);
    assert(source.len <= std.math.maxInt(u32));
    assert(view.span().end() <= source.len);

    const qualified = qualified_name_of(semantic, source, view, out);
    const written = out.const_slice();
    if (written.len == 0) return false;

    const head = written.len - 1;
    if (!std.mem.eql(u8, written[head].text(source), member)) return false;

    const segments = written[0..head];

    return switch (qualified) {
        .builtin => segments.len == 0 and std.mem.eql(u8, module, "builtins"),
        .resolved => path_is(source, segments, module) or
            (std.mem.eql(u8, module, "typing") and
                path_is(source, segments, "typing_extensions")),
        .local, .relative, .unresolved => false,
    };
}

pub fn qualified_name_of(
    semantic: *const Semantic,
    source: []const u8,
    view: View,
    out: *ArrayType(Span),
) Qualified {
    assert(source.len <= std.math.maxInt(u32));

    var chain: [attribute_depth_max]Span = undefined;
    var depth: u32 = 0;
    var held = view;

    out.clear();

    for (0..attribute_depth_max + 1) |_| {
        if (held.kind() != .attribute) break;
        if (depth == attribute_depth_max) return .unresolved;

        const position = position_last(held.positions_of(.identifier)) orelse
            return .unresolved;

        chain[depth] = held.token_at(position).span();
        depth += 1;
        held = held.child_first() orelse return .unresolved;
    }

    if (held.kind() != .name_node) return .unresolved;

    const reference = reference_of(semantic, held.index()) orelse return .unresolved;
    const resolution = semantic.reference_at(reference).resolution;
    const outcome = head_of(semantic, source, held, resolution, out);

    if (outcome == .unresolved) {
        out.clear();

        return outcome;
    }

    var index = depth;

    for (0..depth) |_| {
        index -= 1;

        if (out.full()) {
            out.clear();

            return .unresolved;
        }

        out.push(chain[index]);
    }

    assert(out.count() >= depth);
    assert(outcome != .unresolved);

    return outcome;
}

pub fn reference_of(semantic: *const Semantic, node: u32) ?u32 {
    const references = semantic.reference_slice();
    var low: u32 = 0;
    var high: u32 = @intCast(references.len);

    for (0..bisect_step_max) |_| {
        if (low >= high) break;

        const middle = low + @divFloor(high - low, 2);

        if (references[middle].node < node) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }

    assert(low == high);
    if (low > 0) assert(references[low - 1].node < node);

    if (low < references.len) {
        if (references[low].node == node) return low;
    }

    return null;
}

pub fn same_branch(semantic: *const Semantic, left: u32, right: u32) bool {
    assert(left < semantic.ext.branches.count());
    assert(right < semantic.ext.branches.count());

    return left == right;
}

pub const Extension = struct {
    branches: ArrayType(Branch),
    exports: ArrayType(Span),

    pub fn init(
        ext: *Extension,
        gpa: std.mem.Allocator,
        limits: *const Semantic.Limits,
    ) std.mem.Allocator.Error!void {
        assert(limits.binding_count_max > 0);
        assert(limits.fact_count_max > 0);

        ext.branches = try .init(gpa, limits.binding_count_max);
        errdefer ext.branches.deinit(gpa);

        ext.exports = try .init(gpa, limits.fact_count_max);

        assert(ext.branches.empty());
        assert(ext.exports.empty());
    }

    pub fn deinit(ext: *Extension, gpa: std.mem.Allocator) void {
        assert(ext.branches.count() <= ext.branches.capacity());
        assert(ext.exports.count() <= ext.exports.capacity());

        ext.exports.deinit(gpa);
        ext.branches.deinit(gpa);
        ext.* = undefined;
    }

    pub fn clear(ext: *Extension) void {
        ext.branches.clear();
        ext.exports.clear();

        assert(ext.branches.empty());
        assert(ext.exports.empty());
    }
};

pub const AnnotationScratch = struct {
    decoded: literal.Buffer,
    events: Events,
    origins: literal.Origins,
    parser: Parser,
    raw: ArrayType(Kind),
    tokens: Tokens,
    tree: Tree,

    pub const Limits = struct {
        node_count_max: u32,
        token_count_max: u32,
    };

    pub fn init(
        scratch: *AnnotationScratch,
        gpa: std.mem.Allocator,
        limits: *const Limits,
    ) std.mem.Allocator.Error!void {
        assert(limits.node_count_max > 0);
        assert(limits.token_count_max > 0);

        try scratch.events.init(gpa, limits.node_count_max * 4);
        errdefer scratch.events.deinit(gpa);

        scratch.decoded = try .init(gpa, annotation_bytes_max);
        errdefer scratch.decoded.deinit(gpa);

        scratch.origins = try .init(gpa, annotation_bytes_max);
        errdefer scratch.origins.deinit(gpa);

        scratch.raw = try .init(gpa, limits.token_count_max);
        errdefer scratch.raw.deinit(gpa);

        scratch.tokens = try .init(gpa, limits.token_count_max);
        errdefer scratch.tokens.deinit(gpa);

        scratch.tree = try .init(gpa, limits.node_count_max, annotation_depth_max);
        scratch.parser = undefined;

        assert(scratch.raw.capacity() == scratch.tokens.items.capacity());
        assert(scratch.tree.count() == 0);
        assert(scratch.decoded.capacity() == scratch.origins.capacity());
    }

    pub fn deinit(scratch: *AnnotationScratch, gpa: std.mem.Allocator) void {
        assert(scratch.raw.capacity() == scratch.tokens.items.capacity());
        assert(scratch.decoded.capacity() == scratch.origins.capacity());

        scratch.tree.deinit(gpa);
        scratch.tokens.deinit(gpa);
        scratch.raw.deinit(gpa);
        scratch.origins.deinit(gpa);
        scratch.events.deinit(gpa);
        scratch.decoded.deinit(gpa);
        scratch.* = undefined;
    }

    fn decoded_clear(scratch: *AnnotationScratch) void {
        scratch.decoded.clear();
        scratch.origins.clear();

        assert(scratch.decoded.empty());
        assert(scratch.origins.empty());
    }

    fn decoded_truncate(scratch: *AnnotationScratch, count: u32) void {
        assert(count <= scratch.decoded.count());
        assert(count <= scratch.origins.count());

        scratch.decoded.truncate(count);
        scratch.origins.truncate(count);
    }

    fn clear(scratch: *AnnotationScratch) void {
        scratch.raw.clear();
        scratch.tokens.clear();
        scratch.tree.clear();

        assert(scratch.raw.empty());
        assert(scratch.tree.count() == 0);
    }
};

pub const BindingFlags = packed struct(u9) {
    alias: bool = false,
    deleted: bool = false,
    export_explicit: bool = false,
    overload: bool = false,
    private: bool = false,
    redirected: bool = false,
    shadowed: bool = false,
    type_checking: bool = false,
    unpacked: bool = false,
};

pub const BindingKind = enum {
    annotation,
    assignment,
    augmented,
    class_definition,
    comprehension_variable,
    deletion,
    except_variable,
    function_definition,
    future_import,
    global,
    import,
    import_from,
    import_star,
    loop_variable,
    match_capture,
    named,
    nonlocal,
    parameter,
    submodule_import,
    type_alias,
    type_parameter,
    with_variable,

    pub fn answers(kind: BindingKind) bool {
        const result = switch (kind) {
            .annotation, .global, .nonlocal => false,
            else => true,
        };

        if (kind == .deletion) assert(result);
        if (!result) assert(!kind.binds());

        return result;
    }

    pub fn class_of(kind: BindingKind) BindingClass {
        const class: BindingClass = switch (kind) {
            .annotation,
            .assignment,
            .augmented,
            .comprehension_variable,
            .except_variable,
            .loop_variable,
            .match_capture,
            .named,
            .with_variable,
            => .local,
            .class_definition, .type_alias, .type_parameter => .type,
            .deletion, .global, .nonlocal => .other,
            .function_definition => .function,
            .future_import, .import, .import_from, .import_star, .submodule_import => .import,
            .parameter => .parameter,
        };

        if (kind.imports()) assert(class == .import);
        if (kind == .deletion) assert(class == .other);

        return class;
    }

    pub fn binds(kind: BindingKind) bool {
        const result = switch (kind) {
            .annotation, .deletion, .global, .nonlocal => false,
            else => true,
        };

        if (kind.imports()) assert(result);
        if (kind.defines()) assert(result);

        return result;
    }

    pub fn defines(kind: BindingKind) bool {
        const result = kind == .class_definition or kind == .function_definition;

        if (result) assert(!kind.imports());
        if (kind == .assignment) assert(!result);

        return result;
    }

    pub fn imports(kind: BindingKind) bool {
        const result = switch (kind) {
            .future_import, .import, .import_from, .import_star, .submodule_import => true,
            else => false,
        };

        if (kind == .parameter) assert(!result);
        if (kind == .import_star) assert(result);

        return result;
    }
};

pub const Branch = struct {
    node: u32,
    parent: u32,
};

pub const Namespace = enum {
    value,
};

pub const Qualified = union(enum) {
    builtin,
    local: u32,
    relative: u32,
    resolved,
    unresolved,
};

pub const ReferenceFlags = packed struct(u5) {
    annotation: bool = false,
    deferred: bool = false,
    forward: bool = false,
    type_checking: bool = false,
    typing_only: bool = false,
};

pub const ScopeKind = enum {
    class,
    comprehension,
    function,
    lambda,
    module,
    type,
    type_alias,

    pub fn class_of(kind: ScopeKind) ScopeClass {
        const class: ScopeClass = switch (kind) {
            .class => .type,
            .comprehension => .block,
            .function, .lambda => .function,
            .module => .module,
            .type, .type_alias => .other,
        };

        if (kind == .module) assert(class == .module);

        return class;
    }
};

pub const SemanticInput = struct {
    builtins: []const []const u8,
    raw: []const Kind,
    source: []const u8,
    tokens: []const Token,
    tree: *const Tree,
    version: PythonVersion,
};

const Argument = struct {
    keyword: bool,
    name: ?[]const u8,
    ordinal: u32,
    positional: u32,
    positionals: u32,
};

const Callable = enum {
    bool,
    cast,
    mypy_extension,
    named_tuple,
    new_type,
    type_alias_type,
    type_var,
    typed_dict,
};

const Entry = enum {
    key,
    unpacked,
    value,
};

const Located = struct {
    base: u32,
    origins: []const u32,
    relocated: ?u32,

    fn origin_at(located: Located, offset: u32) u32 {
        assert(offset < std.math.maxInt(u32));
        assert(located.origins.len <= std.math.maxInt(u32));

        if (located.origins.len == 0) {
            assert(located.base + offset < std.math.maxInt(u32));

            return located.base + offset;
        }

        return located.origins[offset];
    }

    fn span_of(located: Located, span: Span) ?Span {
        assert(located.origins.len <= std.math.maxInt(u32));
        assert(span.length <= std.math.maxInt(u32) - span.offset);

        if (located.origins.len == 0) return shifted(span, located.base);
        if (span.length == 0) return null;

        assert(located.relocated != null);
        assert(span.end() <= located.origins.len);

        const first = located.origins[span.offset];
        if (first == literal.origin_escaped) return null;

        for (located.origins[span.offset..span.end()], 0..) |origin, index| {
            if (origin != first + index) return null;
        }

        return .{ .offset = first, .length = span.length };
    }
};

const Named = struct {
    name: Span,
    relocated: ?u32,
};

const Nested = struct {
    count: u32,
    pending: [annotation_nest_max]Pending,
    seen: u32,
};

const Pending = struct {
    content: Span,
    relocated: ?u32,
};

const located_source: Located = .{ .base = 0, .origins = &.{}, .relocated = null };

const Parsed = enum {
    overflow,
    parsed,
    refused,
};

const Stores = struct {
    count: u32,
    spans: [annotation_store_max]Span,
};

const Subscripted = enum {
    annotated,
    generic,
    literal,
    typed_dict,
};

const Typed = enum {
    climb,
    literal,
    type,
    value,
};

const Usage = struct {
    context: Context,
    kind: ?BindingKind,
    unpacked: bool,
};

const Builder = struct {
    annotation_root: ?u32,
    annotation_scratch: *AnnotationScratch,
    branch_depth: u32,
    branch_stack: [branch_depth_max]u32,
    decorator_run: [decorator_depth_max]bool,
    deferred_type_root: ?u32,
    depth: u32,
    future_annotations: bool,
    outcome: Structure,
    overload_pending: bool,
    permuted_call_count: u32,
    permuted_calls: [permuted_call_depth_max]u32,
    raw: []const Kind,
    semantic: *Semantic,
    source: []const u8,
    stack: [scope_depth_max]u32,
    tokens: []const Token,
    tree: *const Tree,
    tree_depth: u32,
    type_checking_block: ?u32,
    type_definition_root: ?u32,

    fn init(semantic: *Semantic, input: *const SemanticInput, scratch: *AnnotationScratch) Builder {
        assert(input.tokens.len == input.raw.len);
        assert(input.source.len <= std.math.maxInt(u32));

        return .{
            .annotation_root = null,
            .annotation_scratch = scratch,
            .branch_depth = 0,
            .branch_stack = undefined,
            .decorator_run = @splat(false),
            .deferred_type_root = null,
            .depth = 0,
            .future_annotations = false,
            .outcome = .complete,
            .overload_pending = false,
            .permuted_call_count = 0,
            .permuted_calls = undefined,
            .raw = input.raw,
            .semantic = semantic,
            .source = input.source,
            .stack = undefined,
            .tokens = input.tokens,
            .tree = input.tree,
            .tree_depth = 0,
            .type_checking_block = null,
            .type_definition_root = null,
        };
    }

    fn collect(builder: *Builder) void {
        if (builder.tree.count() == 0) return;

        builder.branch_stack[0] = 0;
        builder.branch_depth = 1;
        builder.stack[0] = 0;
        builder.depth = 1;

        var steps = walk(Tree, builder.tree);

        for (0..steps.step_max) |_| {
            const step = steps.next() orelse break;

            switch (step) {
                .enter => |node| builder.entered(node),
                .leave => |node| {
                    assert(builder.tree_depth > 0);

                    builder.tree_depth -= 1;

                    builder.leave(node);
                },
            }
        }

        assert(steps.node == null);
        assert(builder.tree_depth == 0);
    }

    fn entered(builder: *Builder, node: u32) void {
        const slot = builder.tree_depth;

        assert(node < builder.tree.count());

        builder.overload_pending = slot < decorator_depth_max and builder.decorator_run[slot];

        builder.decorator_note(node);
        builder.enter(node);
        builder.tree_depth += 1;

        if (builder.tree_depth < decorator_depth_max) {
            builder.decorator_run[builder.tree_depth] = false;
        }

        assert(builder.tree_depth == slot + 1);
    }

    fn decorator_note(builder: *Builder, node: u32) void {
        const slot = builder.tree_depth;

        assert(node < builder.tree.count());

        if (slot >= decorator_depth_max) return;

        if (builder.kind_of(node) != .decorator) {
            builder.decorator_run[slot] = false;

            return;
        }

        const span = builder.tree.at(node).span(Token, builder.tokens);
        const named = std.mem.endsWith(u8, span.text(builder.source), "overload");

        assert(span.end() <= builder.source.len);

        builder.decorator_run[slot] = builder.decorator_run[slot] or named;
    }

    fn branch_current(builder: *const Builder) u32 {
        assert(builder.branch_depth > 0);
        assert(builder.branch_depth <= branch_depth_max);

        return builder.branch_stack[builder.branch_depth - 1];
    }

    fn scope_current(builder: *const Builder) u32 {
        assert(builder.depth > 0);
        assert(builder.depth <= scope_depth_max);

        return builder.stack[builder.depth - 1];
    }

    fn reading_scope(builder: *const Builder, node: u32) u32 {
        const scope = builder.scope_current();
        const held = builder.semantic.scope_at(scope);

        assert(node < builder.tree.count());

        switch (held.kind) {
            .type, .type_alias => return scope,
            else => {},
        }

        if (held.parent == none) return scope;
        if (!builder.reads_outside(node)) return scope;

        assert(held.parent < builder.semantic.scope_count());

        return held.parent;
    }

    fn reads_outside(builder: *const Builder, node: u32) bool {
        assert(node < builder.tree.count());

        var below: u32 = none;
        var held = node;

        for (0..builder.tree.count()) |_| {
            const parent = builder.tree.parent_of(held) orelse return false;
            const kind = builder.kind_of(parent);

            if (!opens_a_scope(kind)) {
                below = held;
                held = parent;

                continue;
            }

            assert(parent < held);

            switch (kind) {
                .async_function_def, .function_def => return builder.kind_of(held) != .block,
                .dict_comp, .generator_exp, .list_comp, .set_comp => {},
                else => return false,
            }

            if (builder.kind_of(held) != .comprehension) return false;
            if (builder.clause_first(parent) != held) return false;
            return (builder.iterable_of(held) orelse none) == below;
        }

        return false;
    }

    fn clause_first(builder: *const Builder, node: u32) ?u32 {
        assert(node < none);

        const held = builder.view_of(node).child_first_of(.comprehension) orelse return null;

        assert(held.index() > node);
        assert(held.kind() == .comprehension);

        return held.index();
    }

    fn iterable_of(builder: *const Builder, node: u32) ?u32 {
        assert(node < none);

        const first = builder.tree.child_first_of(node) orelse return null;
        const second = builder.tree.sibling_next_of(first);

        assert(first > node);
        if (second) |held| assert(held > first);

        return second;
    }

    fn view_of(builder: *const Builder, node: u32) View {
        assert(node < builder.tree.count());
        assert(builder.tokens.len == builder.raw.len);

        return View.init(builder.tree, builder.tokens, builder.raw, node);
    }

    fn kind_of(builder: *const Builder, node: u32) Kind {
        assert(node < builder.tree.count());

        const kind = builder.tree.kind_at(node);

        assert(kind.is_node());

        return kind;
    }

    fn text_of(builder: *const Builder, name: Span) []const u8 {
        assert(name.end() <= builder.source.len);
        assert(builder.source.len <= std.math.maxInt(u32));

        return name.text(builder.source);
    }

    fn outcome_truncate(builder: *Builder, resource: Resource) void {
        assert(builder.semantic.scope_count() > 0);

        if (builder.outcome == .complete) builder.outcome = .{ .truncated = resource };

        assert(builder.outcome != .complete);
    }

    fn enter(builder: *Builder, node: u32) void {
        assert(node < none);

        const kind = builder.kind_of(node);

        assert(builder.depth > 0);
        assert(builder.branch_depth > 0);

        if (builder.opens_a_branch(node, kind)) builder.branch_open(node);

        if (builder.type_checking_block == null) {
            if (builder.guards_type_checking(node, kind)) builder.type_checking_block = node;
        }

        if (builder.annotation_root == null) {
            if (builder.annotates(node)) builder.annotation_root = node;
        }

        if (builder.type_definition_root == null) {
            if (builder.defines_a_type(node, kind)) builder.type_definition_root = node;
        }

        if (builder.deferred_type_root == null) {
            if (builder.defers_a_type(node, kind)) builder.deferred_type_root = node;
        }

        if (kind == .constant) builder.annotation_string(node);
        if (kind == .call) builder.call_enter(node);

        builder.statement(node, kind);

        if (builder.type_params_of(node, kind)) |held| {
            builder.scope_enter(held);
            builder.type_parameters(node);
        }

        if (opens_a_scope(kind)) {
            if (kind != .class_def) {
                builder.scope_enter(node);
                builder.scope_entered(node, kind);
            }
        }

        if (builder.bodies_a_class(node, kind)) {
            const held = builder.tree.parent_of(node).?;

            builder.scope_enter(held);
            builder.scope_entered(held, .class_def);
        }
    }

    fn bodies_a_class(builder: *const Builder, node: u32, kind: Kind) bool {
        assert(kind == builder.kind_of(node));

        if (kind != .block) return false;

        const parent = builder.tree.parent_of(node) orelse return false;

        assert(parent < node);

        return builder.kind_of(parent) == .class_def;
    }

    fn type_params_of(builder: *const Builder, node: u32, kind: Kind) ?u32 {
        assert(kind == builder.kind_of(node));

        switch (kind) {
            .async_function_def, .class_def, .function_def, .type_alias => {},
            else => return null,
        }

        const held = builder.view_of(node).child_first_of(.type_params) orelse return null;

        assert(held.index() > node);

        return held.index();
    }

    fn leave(builder: *Builder, node: u32) void {
        assert(node < none);

        const kind = builder.kind_of(node);

        assert(builder.depth > 0);
        assert(builder.branch_depth > 0);

        if (kind == .except_handler) builder.unhandled(node);
        if (kind == .call) builder.call_leave(node);
        if (builder.annotation_root == node) builder.annotation_root = null;
        if (builder.type_checking_block == node) builder.type_checking_block = null;
        if (builder.type_definition_root == node) builder.type_definition_root = null;
        if (builder.deferred_type_root == node) builder.deferred_type_root = null;

        if (builder.opens_a_branch(node, kind)) {
            if (builder.branch_depth > 1) {
                const top = builder.branch_current();

                if (builder.semantic.ext.branches.get(top).node == node) builder.branch_depth -= 1;
            }
        }

        if (opens_a_scope(kind)) {
            if (kind != .class_def) builder.depth_pop();
        }

        if (builder.bodies_a_class(node, kind)) builder.depth_pop();
        if (builder.type_params_of(node, kind) != null) builder.depth_pop();
    }

    fn depth_pop(builder: *Builder) void {
        assert(builder.depth > 0);
        assert(builder.depth <= scope_depth_max);

        if (builder.depth > 1) builder.depth -= 1;
    }

    fn call_enter(builder: *Builder, node: u32) void {
        const count = builder.permuted_call_count;

        assert(builder.kind_of(node) == .call);
        assert(count <= permuted_call_depth_max);

        if (count == permuted_call_depth_max) return;
        if (!builder.call_permuted(node)) return;

        builder.permuted_calls[count] = node;
        builder.permuted_call_count = count + 1;
    }

    fn call_leave(builder: *Builder, node: u32) void {
        const count = builder.permuted_call_count;

        assert(builder.kind_of(node) == .call);
        assert(count <= permuted_call_depth_max);

        if (count == 0) return;
        if (builder.permuted_calls[count - 1] != node) return;

        builder.permuted_call_count = count - 1;
    }

    fn call_permuted(builder: *const Builder, node: u32) bool {
        assert(node < none);

        const tree = builder.tree;
        const callee = tree.child_first_of(node) orelse return false;
        var argument = tree.sibling_next_of(callee);
        var keyworded = false;

        assert(builder.kind_of(node) == .call);

        for (0..tree.count()) |_| {
            const held = argument orelse return false;

            if (tree.kind_at(held) == .keyword) {
                keyworded = true;
            } else if (keyworded) {
                return true;
            } else {}

            argument = tree.sibling_next_of(held);
        }

        return false;
    }

    fn call_held(builder: *const Builder, node: u32) bool {
        assert(builder.permuted_call_count <= permuted_call_depth_max);

        for (builder.permuted_calls[0..builder.permuted_call_count]) |held| {
            if (held == node) return true;
        }

        return false;
    }

    fn order_of(builder: *const Builder, node: u32) u32 {
        if (node != none) assert(node < builder.tree.count());

        const count = builder.tree.count();

        if (node == none) return none;

        assert(node < count);

        var order: i64 = node;
        var child = node;

        for (0..count) |_| {
            const parent = builder.tree.parent_of(child) orelse break;

            order += builder.order_shift(parent, child);
            child = parent;
        }

        assert(order >= 0);
        assert(order < count);

        return @intCast(order);
    }

    fn order_shift(builder: *const Builder, parent: u32, child: u32) i64 {
        assert(parent < none);

        const tree = builder.tree;
        const first = tree.child_first_of(parent) orelse return 0;
        const second = tree.sibling_next_of(first) orelse return 0;
        const head = @as(i64, second) - first;
        const end: i64 = builder.subtree_end(parent);

        assert(child >= first);
        assert(tree.parent_of(child) == parent);

        const shift: i64 = switch (builder.kind_of(parent)) {
            .async_for, .aug_assign, .comprehension, .@"for", .if_exp, .named_expr => moved: {
                if (child == second) break :moved -head;
                if (child != first) break :moved 0;

                const after = tree.sibling_next_of(second) orelse builder.subtree_end(parent);
                break :moved @as(i64, after) - second;
            },
            .ann_assign, .generator_exp, .list_comp, .set_comp => moved: {
                if (child == first) break :moved end - second;
                break :moved -head;
            },
            .dict_comp => moved: {
                const third = tree.sibling_next_of(second) orelse break :moved 0;
                const entry = child == first or child == second;

                if (entry) break :moved end - third;
                break :moved -(@as(i64, third) - first);
            },
            .assign => moved: {
                const value = builder.child_last(parent);
                if (child == value) break :moved -(@as(i64, value) - first);
                break :moved end - value;
            },
            .call => moved: {
                if (child == first) break :moved 0;
                if (!builder.call_held(parent)) break :moved 0;
                break :moved builder.call_shift(parent, child);
            },
            else => 0,
        };

        assert(@abs(shift) <= end);

        return shift;
    }

    fn call_shift(builder: *const Builder, node: u32, child: u32) i64 {
        assert(builder.kind_of(node) == .call);
        assert(child < none);

        const tree = builder.tree;
        const keyword = tree.kind_at(child) == .keyword;
        const end = builder.subtree_end(node);
        var argument = tree.sibling_next_of(tree.child_first_of(node).?);
        var passed = false;
        var shift: i64 = 0;

        assert(tree.parent_of(child) == node);

        for (0..tree.count()) |_| {
            const held = argument orelse break;
            const next = tree.sibling_next_of(held);
            const size = @as(i64, next orelse end) - held;
            const named = tree.kind_at(held) == .keyword;

            if (held == child) {
                passed = true;
            } else if (passed) {
                if (keyword) {
                    if (!named) shift += size;
                }
            } else {
                if (!keyword) {
                    if (named) shift -= size;
                }
            }

            argument = next;
        }

        assert(passed);

        return shift;
    }

    fn child_last(builder: *const Builder, node: u32) u32 {
        assert(node < none);

        const tree = builder.tree;
        var held = tree.child_first_of(node).?;

        for (0..tree.count()) |_| {
            held = tree.sibling_next_of(held) orelse return held;
        }

        return held;
    }

    fn subtree_end(builder: *const Builder, node: u32) u32 {
        assert(node < none);

        const tree = builder.tree;
        var held = node;

        assert(node < tree.count());

        for (0..tree.count()) |_| {
            if (tree.sibling_next_of(held)) |next| return next;

            held = tree.parent_of(held) orelse return tree.count();
        }

        return tree.count();
    }

    fn opens_a_branch(builder: *const Builder, node: u32, kind: Kind) bool {
        assert(kind == builder.kind_of(node));

        switch (kind) {
            .except_handler, .finally_clause, .match_case, .@"try", .try_star => return true,
            .block, .else_clause => {},
            else => return false,
        }

        const parent = builder.tree.parent_of(node) orelse return false;

        assert(parent < node);

        return switch (builder.kind_of(parent)) {
            .@"if" => true,
            .async_with, .with => kind == .block,
            else => false,
        };
    }

    fn branch_open(builder: *Builder, node: u32) void {
        assert(node < none);

        const parent = builder.branch_current();

        assert(parent < builder.semantic.ext.branches.count());

        if (builder.branch_depth >= branch_depth_max) {
            builder.outcome = .too_deep;

            return;
        }

        const index = builder.semantic.ext.branches.count();

        if (builder.semantic.ext.branches.full()) {
            builder.outcome = .too_deep;

            return;
        }

        builder.semantic.ext.branches.push(.{ .node = node, .parent = parent });
        builder.branch_stack[builder.branch_depth] = index;
        builder.branch_depth += 1;

        assert(builder.branch_current() == index);
    }

    fn guards_type_checking(builder: *const Builder, node: u32, kind: Kind) bool {
        assert(kind == builder.kind_of(node));

        if (kind != .block) return false;

        const parent = builder.tree.parent_of(node) orelse return false;
        if (builder.kind_of(parent) != .@"if") return false;

        const condition = builder.view_of(parent).child_first() orelse return false;
        const text = condition.text(builder.source);

        assert(condition.index() > parent);

        return switch (condition.kind()) {
            .attribute => std.mem.endsWith(u8, text, ".TYPE_CHECKING"),
            .name_node => std.mem.eql(u8, text, "TYPE_CHECKING"),
            else => false,
        };
    }

    fn annotation_string(builder: *Builder, node: u32) void {
        assert(node < none);

        const held = builder.view_of(node);
        const root = builder.type_root();

        if (!plain_string(held, builder.source)) return;

        if (root != null) {
            if (builder.inside_literal(node)) return;
        }

        if (builder.typed_of(held, root, located_source) != .type) return;

        builder.annotation_scratch.decoded_clear();

        const first = builder.annotation_first(held, builder.source, located_source) orelse return;

        builder.annotation_names(node, first);
    }

    fn inside_literal(builder: *const Builder, node: u32) bool {
        assert(node < builder.tree.count());

        var held = builder.tree.parent_of(node);

        assert(builder.type_root() != null);

        for (0..attribute_depth_max + 1) |_| {
            const current = held orelse return false;

            if (builder.kind_of(current) == .subscript) {
                if (builder.view_of(current).child_first()) |target| {
                    const text = target.text(builder.source);
                    if (std.mem.endsWith(u8, text, "Literal")) return true;
                }
            }

            if (builder.type_root() == current) return false;

            held = builder.tree.parent_of(current);
        }

        return false;
    }

    fn annotation_first(
        builder: *const Builder,
        string: View,
        text: []const u8,
        located: Located,
    ) ?Pending {
        assert(plain_string(string, text));
        assert(located.origins.len <= std.math.maxInt(u32));

        const scratch = builder.annotation_scratch;
        const start = scratch.decoded.count();
        var positions = string.positions();

        assert(start == scratch.origins.count());

        for (0..positions_total(string.positions())) |_| {
            const position = positions.next() orelse break;
            const token = string.token_at(position).span();
            const written = scratch.decoded.count();

            const outcome = literal.decode_traced(
                token.text(text),
                &scratch.decoded,
                &scratch.origins,
            );

            if (outcome != .complete) {
                scratch.decoded_truncate(start);

                return null;
            }

            for (scratch.origins.slice()[written..]) |*origin| {
                if (origin.* == literal.origin_escaped) continue;

                origin.* = located.origin_at(token.offset + origin.*);
            }
        }

        const decoded: Span = .{ .offset = start, .length = scratch.decoded.count() - start };

        if (located.relocated == null) {
            const spelled = decoded.text(scratch.decoded.const_slice());

            if (simple_content(string, text, spelled)) |content| {
                scratch.decoded_truncate(start);

                return .{ .content = shifted(content, located.base), .relocated = null };
            }
        }

        const relocated = located.relocated orelse located.origin_at(string.span().offset);

        assert(decoded.end() == scratch.origins.count());

        return .{ .content = decoded, .relocated = relocated };
    }

    fn annotation_names(builder: *Builder, node: u32, first: Pending) void {
        assert(node < none);
        assert(first.content.length <= std.math.maxInt(u32) - first.content.offset);

        var found: [annotation_depth_max]Named = undefined;
        var stores: Stores = .{ .count = 0, .spans = undefined };
        const total = builder.annotation_parse(first, &found, &stores);
        const branch = builder.branch_current();
        const ending: u32 = @intCast(builder.source.len);
        const scope = builder.reading_scope(node);
        const type_checking = builder.type_checking_block != null;
        const order = builder.order_of(node);

        assert(total <= annotation_depth_max);

        for (found[0..total]) |named| {
            const relocated_by = relocation_of(named) orelse continue;

            assert(named.name.end() <= builder.source.len);

            builder.refer(&.{
                .context = .load,
                .dead_zone = false,
                .ext = .{
                    .branch = branch,
                    .flags = .{
                        .annotation = true,
                        .deferred = true,
                        .forward = true,
                        .type_checking = type_checking,
                        .typing_only = true,
                    },
                    .order = order,
                    .relocated_by = relocated_by,
                },
                .name = named.name,
                .name_hash = name_hash(builder.text_of(named.name)),
                .namespace = .value,
                .node = node,
                .resolution = .unresolved,
                .scope = scope,
            });
        }

        for (stores.spans[0..stores.count]) |name| {
            assert(name.end() <= builder.source.len);

            builder.record_visible(.assignment, name, node, .{}, ending);
        }
    }

    fn annotation_parse(
        builder: *Builder,
        first: Pending,
        found: *[annotation_depth_max]Named,
        stores: *Stores,
    ) u32 {
        assert(first.content.length <= std.math.maxInt(u32) - first.content.offset);

        var nested: Nested = .{ .count = 0, .pending = undefined, .seen = 0 };
        var total: u32 = 0;
        var pending = first;

        assert(stores.count == 0);

        if (first.relocated == null) assert(first.content.offset > 0);

        for (0..annotation_nest_max + 1) |round| {
            switch (builder.annotation_parsed(pending, found, &total, &nested, stores)) {
                .overflow => {
                    stores.count = 0;

                    return 0;
                },
                .parsed => {},
                .refused => if (round == 0) return 0,
            }

            if (nested.count == 0) break;

            nested.count -= 1;
            pending = nested.pending[nested.count];
        }

        assert(total <= annotation_depth_max);
        assert(nested.seen <= annotation_nest_max);

        return total;
    }

    fn annotation_parsed(
        builder: *Builder,
        pending: Pending,
        found: *[annotation_depth_max]Named,
        total: *u32,
        nested: *Nested,
        stores: *Stores,
    ) Parsed {
        if (pending.relocated == null) assert(pending.content.offset > 0);

        const scratch = builder.annotation_scratch;
        const relocated = pending.relocated != null;

        const text = if (relocated)
            pending.content.text(scratch.decoded.const_slice())
        else
            builder.text_of(pending.content);

        const located: Located = if (relocated) .{
            .base = 0,
            .origins = scratch.origins.const_slice()[pending.content.offset..pending.content.end()],
            .relocated = pending.relocated,
        } else .{ .base = pending.content.offset, .origins = &.{}, .relocated = null };

        assert(total.* <= annotation_depth_max);
        assert(located.origins.len == if (relocated) text.len else 0);

        scratch.clear();

        lex(text, &scratch.tokens) catch |err| switch (err) {
            error.Truncated => return .refused,
        };

        if (!relocated) {
            if (std.mem.findAny(u8, text, "\n\r") != null) scratch.tokens.layout_drop();
        }

        raw_of(Kind, scratch.tokens.slice(), &scratch.raw) catch |err| switch (err) {
            error.Truncated => return .refused,
        };

        const built = scratch.parser.build(
            text,
            scratch.tokens.slice(),
            scratch.raw.const_slice(),
            &scratch.events,
            &scratch.tree,
        );

        assert(scratch.tokens.count() == scratch.raw.count());

        if (built != .complete) return .refused;
        if (scratch.tree.diagnostic_slice().len > 0) return .refused;

        const tokens = scratch.tokens.slice();
        const raw = scratch.raw.const_slice();
        const root = expression_root(&scratch.tree, tokens, raw) orelse return .refused;
        const rest = found[total.*..];
        const listed = annotation_names_of(&scratch.tree, tokens, raw, text, located, rest);
        const added = listed orelse return .overflow;
        const expression = View.init(&scratch.tree, tokens, raw, root);

        total.* += added;

        annotation_stores_of(expression, text, located, stores);
        builder.annotation_nested(expression, text, located, nested);

        return .parsed;
    }

    fn annotation_nested(
        builder: *const Builder,
        root: View,
        text: []const u8,
        located: Located,
        nested: *Nested,
    ) void {
        assert(root.node < root.tree.count());
        assert(text.len <= std.math.maxInt(u32));
        assert(located.origins.len <= std.math.maxInt(u32));

        var steps = walk_from(Tree, root.tree, root.index());

        assert(nested.count <= nested.seen);

        for (0..steps.step_max) |_| {
            const step = steps.next() orelse break;

            const inner = switch (step) {
                .enter => |held| held,
                .leave => continue,
            };

            if (root.tree.kind_at(inner) != .constant) continue;

            const string = root.at(inner);
            if (!plain_string(string, text)) continue;
            if (builder.typed_of(string, root.index(), located) != .type) continue;
            if (nested.seen == annotation_nest_max) return;

            const pending = builder.annotation_first(string, text, located) orelse continue;

            nested.pending[nested.count] = pending;
            nested.count += 1;
            nested.seen += 1;
        }
    }

    fn typed_of(builder: *const Builder, string: View, root: ?u32, located: Located) Typed {
        assert(string.kind() == .constant);
        if (root) |held| assert(held < std.math.maxInt(u32));
        assert(located.origins.len <= std.math.maxInt(u32));

        var path: [typed_depth_max]u32 = undefined;
        var depth: u32 = 0;
        var child = string;

        for (0..typed_depth_max) |_| {
            if (root) |held| {
                if (child.index() == held) return .type;
            }

            const parent = child.parent() orelse return .value;

            path[depth] = child.index();
            depth += 1;

            const step: Typed = switch (parent.kind()) {
                .call => builder.typed_call(parent, path[0..depth], located),
                .subscript => builder.typed_subscript(parent, path[0..depth], located),
                .type_alias => typed_alias(parent, child),
                else => if (typed_through(parent.kind())) .climb else .value,
            };

            if (step != .climb) return step;

            child = parent;
        }

        return .value;
    }

    fn typed_call(builder: *const Builder, call: View, path: []const u32, located: Located) Typed {
        assert(path.len > 0);
        assert(call.node < call.tree.count());
        assert(located.origins.len <= std.math.maxInt(u32));

        const callee = call.child_first() orelse return .value;
        const child = call.at(path[path.len - 1]);

        assert(call.kind() == .call);

        if (callee.index() == child.index()) return .climb;

        const callable = builder.callable_of(callee, located) orelse return .value;
        const argument = builder.argument_of(call, child, located);
        const named = argument.name orelse "";
        const keyword = argument.keyword;
        const positional = !keyword;
        const first = argument.ordinal == 0;
        const second = argument.ordinal == 1;

        return switch (callable) {
            .bool => .climb,
            .cast => typed_if(if (keyword) std.mem.eql(u8, named, "typ") else first),
            .mypy_extension => typed_if(if (argument.positionals > 0)
                positional and argument.positional == 0
            else
                std.mem.eql(u8, named, "type")),
            .named_tuple => if (keyword)
                typed_named_entry(call, path, argument)
            else if (argument.positional == 0) .value else typed_named_fields(call, path),
            .new_type => typed_if(if (keyword) std.mem.eql(u8, named, "tp") else second),
            .type_alias_type => typed_if(if (keyword)
                std.mem.eql(u8, named, "value") or std.mem.eql(u8, named, "type_params")
            else
                second),
            .type_var => typed_if(if (keyword)
                std.mem.eql(u8, named, "bound") or std.mem.eql(u8, named, "default")
            else
                argument.positional > 0),
            .typed_dict => if (keyword)
                .type
            else if (argument.positional == 0) .value else typed_dict_entry(call, path, .type),
        };
    }

    fn typed_subscript(
        builder: *const Builder,
        subscript: View,
        path: []const u32,
        located: Located,
    ) Typed {
        assert(subscript.node < subscript.tree.count());
        assert(located.origins.len <= std.math.maxInt(u32));

        const target = subscript.child_first() orelse return .value;

        assert(path.len > 0);

        assert(subscript.kind() == .subscript);

        if (target.index() == path[path.len - 1]) return .climb;

        const subscripted = builder.subscripted_of(target, located) orelse return .climb;

        return switch (subscripted) {
            .annotated => typed_metadata(subscript, path),
            .generic => .type,
            .literal => .literal,
            .typed_dict => typed_dict_entry(subscript, path, .value),
        };
    }

    fn callable_of(builder: *const Builder, callee: View, located: Located) ?Callable {
        assert(callee.node < callee.tree.count());
        assert(located.origins.len <= std.math.maxInt(u32));

        var buffer: [qualified_bytes_max]u8 = undefined;
        const qualified = builder.qualified_text(callee, located, &buffer) orelse return null;

        return callable_names.get(qualified);
    }

    fn subscripted_of(builder: *const Builder, target: View, located: Located) ?Subscripted {
        assert(target.node < target.tree.count());
        assert(located.origins.len <= std.math.maxInt(u32));

        var buffer: [qualified_bytes_max]u8 = undefined;
        const qualified = builder.qualified_text(target, located, &buffer) orelse return null;

        return subscript_names.get(qualified);
    }

    fn qualified_text(
        builder: *const Builder,
        view: View,
        located: Located,
        buffer: *[qualified_bytes_max]u8,
    ) ?[]const u8 {
        assert(located.origins.len <= std.math.maxInt(u32));

        var segments: [attribute_depth_max]Span = undefined;
        var depth: u32 = 0;
        var held = view;

        for (0..attribute_depth_max + 1) |_| {
            if (held.kind() != .attribute) break;
            if (depth == attribute_depth_max) return null;

            const position = position_last(held.positions_of(.identifier)) orelse return null;

            segments[depth] = located.span_of(held.token_at(position).span()) orelse return null;
            depth += 1;
            held = held.child_first() orelse return null;
        }

        if (held.kind() != .name_node) return null;

        const head = located.span_of(held.span()) orelse return null;
        var length = builder.head_qualified(head, buffer) orelse return null;
        var index = depth;

        for (0..depth) |_| {
            index -= 1;

            const segment = builder.text_of(segments[index]);
            if (length + 1 + segment.len > buffer.len) return null;

            buffer[length] = '.';

            @memcpy(buffer[length + 1 ..][0..segment.len], segment);
            length += 1 + @as(u32, @intCast(segment.len));
        }

        assert(length <= buffer.len);

        return buffer[0..length];
    }

    fn head_qualified(builder: *const Builder, name: Span, buffer: *[qualified_bytes_max]u8) ?u32 {
        assert(name.length <= std.math.maxInt(u32) - name.offset);

        const text = builder.text_of(name);

        const binding = get(builder.semantic, builder.bound_of(name)) orelse
            return joined(buffer, "builtins", text);

        assert(text.len > 0);

        switch (binding.kind) {
            .import => {
                const module = upto(builder.view_of(binding.node), .as_keyword);
                return joined(buffer, builder.text_of(module), "");
            },
            .import_from => {
                const alias = builder.view_of(binding.node);
                const imported = alias.parent() orelse return null;
                const module = between(imported, .from_keyword, .import_keyword);
                const remote = upto(alias, .as_keyword);

                return joined(buffer, builder.text_of(module), builder.text_of(remote));
            },
            .submodule_import => return joined(buffer, text, ""),
            else => return null,
        }
    }

    fn argument_of(builder: *const Builder, call: View, child: View, located: Located) Argument {
        assert(call.node < call.tree.count());
        assert(child.node < child.tree.count());
        assert(located.origins.len <= std.math.maxInt(u32));

        var children = call.children();

        var argument: Argument = .{
            .keyword = child.kind() == .keyword,
            .name = null,
            .ordinal = 0,
            .positional = 0,
            .positionals = 0,
        };

        var reached = false;

        _ = children.next();

        for (0..call.tree.count()) |_| {
            const held = children.next() orelse break;
            const keyword = held.kind() == .keyword;

            if (held.index() == child.index()) reached = true;
            if (!keyword) argument.positionals += 1;
            if (reached) continue;

            argument.ordinal += 1;

            if (!keyword) argument.positional += 1;
        }

        assert(reached);
        assert(argument.positional <= argument.ordinal);

        if (argument.keyword) {
            const cast = child.as_keyword().?;

            if (cast.name_token()) |position| {
                if (located.span_of(child.token_at(position).span())) |name| {
                    argument.name = builder.text_of(name);
                }
            }
        }

        return argument;
    }

    fn type_root(builder: *const Builder) ?u32 {
        const root = builder.annotation_root orelse builder.type_definition_root;

        if (root) |held| assert(held < builder.tree.count());
        if (builder.annotation_root != null) assert(root == builder.annotation_root);

        return root;
    }

    fn defers_a_type(builder: *const Builder, node: u32, kind: Kind) bool {
        assert(kind == builder.kind_of(node));

        const parent = builder.tree.parent_of(node) orelse return false;

        assert(parent < node);

        switch (builder.kind_of(parent)) {
            .param_spec, .type_var, .type_var_tuple => return true,
            .type_alias => {},
            else => return false,
        }

        if (kind == .type_params) return false;
        if (builder.tree.child_first_of(parent) == node) return false;
        return builder.tree.sibling_next_of(node) == null;
    }

    fn defines_a_type(builder: *const Builder, node: u32, kind: Kind) bool {
        assert(kind == builder.kind_of(node));

        if (kind == .arguments) return false;

        const parent = builder.tree.parent_of(node) orelse return false;
        const held = builder.view_of(parent);

        assert(parent < node);

        if (builder.kind_of(parent) == .ann_assign) {
            const value = held.child_at(2) orelse return false;
            if (value.index() != node) return false;

            const annotation = held.child_at(1) orelse return false;
            const text = annotation.text(builder.source);
            if (!std.mem.endsWith(u8, text, "TypeAlias")) return false;
            return builder.names(annotation, "typing", "TypeAlias");
        }

        if (builder.kind_of(parent) != .call) return false;

        const argument = held.child_at(1) orelse return false;
        if (argument.index() != node) return false;

        const callee = held.child_first() orelse return false;
        if (!std.mem.endsWith(u8, callee.text(builder.source), "cast")) return false;
        return builder.names(callee, "typing", "cast");
    }

    fn names(builder: *const Builder, view: View, module: []const u8, member: []const u8) bool {
        assert(module.len > 0);
        assert(member.len > 0);
        assert(view.node < view.tree.count());

        if (view.kind() == .name_node) {
            if (!std.mem.eql(u8, view.text(builder.source), member)) return false;
            return builder.imported_from(builder.bound_of(view.span()), module);
        }

        if (view.kind() != .attribute) return false;

        const position = position_last(view.positions_of(.identifier)) orelse return false;

        if (!std.mem.eql(u8, builder.text_of(view.token_at(position).span()), member)) {
            return false;
        }

        const head = view.child_first() orelse return false;
        if (head.kind() != .name_node) return false;
        return builder.module_named(builder.bound_of(head.span()), module);
    }

    fn bound_of(builder: *const Builder, name: Span) ?u32 {
        assert(name.end() <= builder.source.len);

        const reference: Reference = .{
            .context = .load,
            .dead_zone = false,
            .ext = .{ .branch = 0, .flags = .{}, .order = none, .relocated_by = 0 },
            .name = name,
            .name_hash = name_hash(builder.text_of(name)),
            .namespace = .value,
            .node = none,
            .resolution = .unresolved,
            .scope = builder.scope_current(),
        };

        assert(reference.scope < builder.semantic.scope_count());

        return bound_in(builder.semantic, builder.source, &reference);
    }

    fn imported_from(builder: *const Builder, binding: ?u32, module: []const u8) bool {
        if (binding) |held| assert(held < std.math.maxInt(u32));

        const held = get(builder.semantic, binding) orelse return false;

        assert(module.len > 0);

        if (held.kind != .import_from) return false;

        const statement_view = builder.view_of(held.node).parent() orelse return false;
        const span = between(statement_view, .from_keyword, .import_keyword);

        assert(span.end() <= builder.source.len);

        return forwards(builder.text_of(span), module);
    }

    fn module_named(builder: *const Builder, binding: ?u32, module: []const u8) bool {
        if (binding) |held| assert(held < std.math.maxInt(u32));

        const held = get(builder.semantic, binding) orelse return false;

        assert(module.len > 0);

        switch (held.kind) {
            .import, .submodule_import => {},
            else => return false,
        }

        const span = upto(builder.view_of(held.node), .as_keyword);

        assert(span.end() <= builder.source.len);

        return forwards(builder.text_of(span), module);
    }

    fn annotates(builder: *const Builder, node: u32) bool {
        assert(node < none);

        const parent = builder.tree.parent_of(node) orelse return false;
        const held = builder.view_of(parent);

        assert(parent < node);

        switch (builder.kind_of(parent)) {
            .ann_assign => {
                const annotation = held.child_at(1) orelse return false;
                return annotation.index() == node;
            },
            .arg => {
                const first = held.child_first() orelse return false;
                return first.index() == node;
            },
            .async_function_def, .function_def => {},
            else => return false,
        }

        const function = held.as_function() orelse return false;
        const returns = function.returns_annotation() orelse return false;

        assert(returns.index() > parent);

        return returns.index() == node;
    }

    fn scope_enter(builder: *Builder, node: u32) void {
        assert(node < none);

        const kind = scope_kind_of(builder.kind_of(node));

        const parent = switch (kind) {
            .comprehension, .lambda => builder.reading_scope(node),
            else => builder.scope_current(),
        };

        if (builder.depth >= scope_depth_max) {
            builder.outcome = .too_deep;

            return;
        }

        const scope = builder.semantic.scope_open(parent, kind, node, {}) catch |err| switch (err) {
            error.Truncated => return builder.outcome_truncate(.scopes),
        };

        builder.stack[builder.depth] = scope;
        builder.depth += 1;

        assert(builder.scope_current() == scope);
        assert(parent < scope);
    }

    fn scope_entered(builder: *Builder, node: u32, kind: Kind) void {
        assert(node < builder.tree.count());
        assert(opens_a_scope(kind));

        switch (kind) {
            .async_function_def, .function_def, .lambda => builder.parameters(node),
            else => {},
        }
    }

    fn statement(builder: *Builder, node: u32, kind: Kind) void {
        assert(kind == builder.kind_of(node));
        assert(kind.is_node());

        switch (kind) {
            .async_function_def, .function_def => builder.definition(node, .function_definition),
            .class_def => builder.definition(node, .class_definition),
            .except_handler => builder.handler(node),
            .global => builder.declaration(node, .global),
            .import => builder.import(node),
            .import_from => builder.import_from(node),
            .match_as, .match_mapping, .match_star => builder.capture(node),
            .name_node => builder.name_visit(node),
            .nonlocal => builder.declaration(node, .nonlocal),
            .type_alias => builder.type_alias(node),
            .ann_assign, .assign, .aug_assign => builder.exported(node),
            else => {},
        }
    }

    fn definition(builder: *Builder, node: u32, kind: BindingKind) void {
        assert(node < none);

        const held = builder.view_of(node);
        const position = held.token_first(.identifier) orelse return;
        const name = held.token_at(position).span();

        assert(kind.defines());
        assert(position >= held.token_start());

        builder.record_with(kind, name, node, .{ .overload = builder.overloaded(node) });
    }

    fn overloaded(builder: *const Builder, node: u32) bool {
        assert(node < none);

        if (builder.tree_depth < decorator_depth_max) return builder.overload_pending;

        assert(builder.tree_depth >= decorator_depth_max);

        const parent = builder.tree.parent_of(node) orelse return false;
        var child = builder.tree.child_first_of(parent);
        var decorated = false;

        assert(parent < node);

        for (0..builder.tree.count() + 1) |_| {
            const current = child orelse break;
            if (current == node) break;

            const held = builder.tree.at(current);

            if (held.kind == .decorator) {
                const span = held.span(Token, builder.tokens);
                const text = span.text(builder.source);

                decorated = decorated or std.mem.endsWith(u8, text, "overload");
            } else {
                decorated = false;
            }

            child = builder.tree.sibling_next_of(current);
        }

        return decorated;
    }

    fn parameters(builder: *Builder, node: u32) void {
        assert(node < none);

        const view = builder.view_of(node);
        const held = view.child_first_of(.arguments) orelse view;
        var children = held.children();

        assert(held.index() >= node);

        for (0..builder.tree.count()) |_| {
            const child = children.next() orelse break;
            if (child.kind() != .arg) continue;

            const position = child.token_first(.identifier) orelse continue;

            builder.record(.parameter, child.token_at(position).span(), child.index());
        }

        assert(children.current == null);
    }

    fn type_parameters(builder: *Builder, node: u32) void {
        assert(node < none);

        const held = builder.view_of(node).child_first_of(.type_params) orelse return;
        var children = held.children();

        assert(held.index() > node);

        for (0..builder.tree.count()) |_| {
            const child = children.next() orelse break;

            switch (child.kind()) {
                .param_spec, .type_var, .type_var_tuple => {},
                else => continue,
            }

            const position = child.token_first(.identifier) orelse continue;

            builder.record(.type_parameter, child.token_at(position).span(), child.index());
        }

        assert(children.current == null);
    }

    fn handler(builder: *Builder, node: u32) void {
        assert(node < none);

        const name = builder.handler_name(node) orelse return;

        assert(builder.kind_of(node) == .except_handler);
        assert(name.end() <= builder.source.len);

        builder.record(.except_variable, name, node);
    }

    fn handler_name(builder: *const Builder, node: u32) ?Span {
        assert(node < none);

        const held = builder.view_of(node);
        const position = position_last(held.positions_of(.identifier)) orelse return null;

        assert(position >= held.token_start());
        assert(position < held.token_end());

        return held.token_at(position).span();
    }

    fn unhandled(builder: *Builder, node: u32) void {
        assert(node < none);

        const name = builder.handler_name(node) orelse return;
        const after = builder.after_of(node);

        assert(after > node);
        assert(after <= builder.tree.count());

        const placed = @min(after, builder.tree.count() - 1);

        builder.record_visible(.deletion, name, placed, .{}, builder.view_of(node).span().end());
    }

    fn after_of(builder: *const Builder, node: u32) u32 {
        assert(node < none);

        var found = node;
        var steps = walk_from(Tree, builder.tree, node);

        for (0..steps.step_max) |_| {
            const step = steps.next() orelse break;

            switch (step) {
                .enter => |held| found = @max(found, held),
                .leave => {},
            }
        }

        assert(steps.node == null);
        assert(found < builder.tree.count());

        return found + 1;
    }

    fn declaration(builder: *Builder, node: u32, kind: BindingKind) void {
        assert(node < none);

        const held = builder.view_of(node);
        var positions = held.positions_of(.identifier);

        assert(kind == .global or kind == .nonlocal);

        for (0..held.raw.len + 1) |_| {
            const position = positions.next() orelse break;

            builder.record(kind, held.token_at(position).span(), node);
        }

        assert(positions.position >= positions.limit);
    }

    fn import(builder: *Builder, node: u32) void {
        assert(node < none);

        const held = builder.view_of(node);
        var children = held.children_of(.alias);

        assert(held.kind() == .import);

        for (0..builder.tree.count()) |_| {
            const child = children.next() orelse break;
            const name = alias_name(child) orelse continue;
            const module = upto(child, .as_keyword);
            const chosen: BindingKind = if (submodule(child)) .submodule_import else .import;

            builder.record_with(chosen, name, child.index(), .{
                .alias = builder.reexports(child, module),
            });

            builder.fact(.import_named, name, module, module);
        }

        assert(children.current == null);
    }

    fn fact(builder: *Builder, kind: FactKind, local: Span, remote: Span, specifier: Span) void {
        assert(local.length <= std.math.maxInt(u32) - local.offset);

        const binding = builder.fact_binding(local);

        assert(local.end() <= builder.source.len);
        assert(specifier.end() <= builder.source.len);

        builder.semantic.fact_push(.{
            .binding = .of(binding),
            .kind = kind,
            .local = local,
            .remote = remote,
            .specifier = specifier,
        }) catch |err| switch (err) {
            error.Truncated => builder.outcome_truncate(.facts),
        };
    }

    fn fact_binding(builder: *const Builder, local: Span) ?u32 {
        if (local.length == 0) return null;

        const text = builder.text_of(local);
        const binding = builder.semantic.binding_newest(builder.source, 0, text, null);

        if (binding) |index| assert(builder.semantic.at(index).scope == 0);
        assert(!span_empty(local));

        return binding;
    }

    fn import_from(builder: *Builder, node: u32) void {
        assert(node < none);

        const held = builder.view_of(node);
        const future = builder.future_import(node);
        const module = between(held, .from_keyword, .import_keyword);
        var children = held.children_of(.alias);

        assert(held.kind() == .import_from);

        for (0..builder.tree.count()) |_| {
            const child = children.next() orelse break;

            if (std.mem.eql(u8, child.text(builder.source), "*")) {
                builder.import_star(child, module);

                continue;
            }

            const name = alias_name(child) orelse continue;
            const kind: BindingKind = if (future) .future_import else .import_from;
            const remote = upto(child, .as_keyword);

            if (future) {
                if (std.mem.eql(u8, builder.text_of(remote), "annotations")) {
                    builder.future_annotations = true;
                }
            }

            builder.record_with(kind, name, child.index(), .{
                .alias = builder.reexports(child, remote),
            });

            builder.fact(.import_named, name, remote, module);
        }

        assert(children.current == null);
    }

    fn import_star(builder: *Builder, child: View, module: Span) void {
        assert(module.length <= std.math.maxInt(u32) - module.offset);

        const scope = builder.scope_current();

        assert(child.kind() == .alias);

        builder.record(.import_star, child.span(), child.index());
        builder.fact(.import_namespace, Span.empty, Span.empty, module);
        builder.semantic.scope_mark_dynamic(scope);

        assert(builder.semantic.scope_at(scope).dynamic);
    }

    fn future_import(builder: *const Builder, node: u32) bool {
        assert(node < none);

        const held = builder.view_of(node);
        const position = held.token_first(.identifier) orelse return false;
        const text = held.token_at(position).text(builder.source);

        assert(held.kind() == .import_from);
        assert(text.len > 0);

        return std.mem.eql(u8, text, "__future__");
    }

    fn reexports(builder: *const Builder, alias: View, remote: Span) bool {
        assert(alias.node < alias.tree.count());

        const cast = alias.as_alias() orelse return false;
        const position = cast.asname_token() orelse return false;

        if (span_empty(remote)) return false;

        const renamed = builder.text_of(alias.token_at(position).span());

        assert(position > alias.token_start());
        assert(renamed.len > 0);

        return std.mem.eql(u8, renamed, builder.text_of(remote));
    }

    fn capture(builder: *Builder, node: u32) void {
        assert(node < none);

        const held = builder.view_of(node);
        var positions = held.positions_of(.identifier);

        assert(node < builder.tree.count());

        for (0..held.raw.len + 1) |_| {
            const position = positions.next() orelse break;

            builder.record(.match_capture, held.token_at(position).span(), node);
        }

        assert(positions.position >= positions.limit);
    }

    fn type_alias(builder: *Builder, node: u32) void {
        assert(node < none);

        const name = builder.view_of(node).child_first_of(.name_node) orelse return;

        assert(name.index() > node);
        assert(builder.kind_of(node) == .type_alias);

        builder.record(.type_alias, name.span(), node);
    }

    fn name_visit(builder: *Builder, node: u32) void {
        assert(node < none);

        const name = builder.view_of(node).span();
        const usage = builder.context_of(node);

        assert(builder.kind_of(node) == .name_node);
        if (usage.context == .delete) assert(usage.kind == .deletion);

        if (usage.kind) |kind| {
            const skipped = kind == .deletion and builder.conditional(node);

            if (!skipped) {
                builder.record_with(kind, name, node, .{
                    .unpacked = usage.unpacked and kind == .assignment,
                });
            }
        }

        if (usage.kind == .augmented) return builder.augmented_read(node, name);

        if (usage.context == .store) {
            if (usage.kind != null) return;
        }

        if (builder.names_an_alias(node)) return;

        const annotation = builder.annotation_root != null;
        const postponed = annotation and builder.future_annotations;
        const deferred = postponed or builder.deferred_type_root != null;
        const type_checking = builder.type_checking_block != null;

        builder.refer(&.{
            .context = usage.context,
            .dead_zone = false,
            .ext = .{
                .branch = builder.branch_current(),
                .flags = .{
                    .annotation = annotation,
                    .deferred = deferred,
                    .forward = postponed,
                    .type_checking = type_checking,
                    .typing_only = postponed or type_checking,
                },
                .order = builder.order_of(node),
                .relocated_by = 0,
            },
            .name = name,
            .name_hash = name_hash(builder.text_of(name)),
            .namespace = .value,
            .node = node,
            .resolution = .unresolved,
            .scope = builder.reading_scope(node),
        });
    }

    fn augmented_read(builder: *Builder, node: u32, name: Span) void {
        assert(node < none);

        var augmented = builder.tree.parent_of(node);

        assert(builder.kind_of(node) == .name_node);
        assert(name.end() <= builder.source.len);

        for (0..builder.tree.count()) |_| {
            const held = augmented orelse return;
            if (builder.kind_of(held) == .aug_assign) break;

            augmented = builder.tree.parent_of(held);
        }

        builder.refer(&.{
            .context = .load,
            .dead_zone = false,
            .ext = .{
                .branch = builder.branch_current(),
                .flags = .{ .type_checking = builder.type_checking_block != null },
                .order = builder.order_of(augmented.?),
                .relocated_by = 0,
            },
            .name = name,
            .name_hash = name_hash(builder.text_of(name)),
            .namespace = .value,
            .node = node,
            .resolution = .unresolved,
            .scope = builder.reading_scope(node),
        });
    }

    fn names_an_alias(builder: *const Builder, node: u32) bool {
        assert(node < none);

        const parent = builder.tree.parent_of(node) orelse return false;

        assert(builder.kind_of(node) == .name_node);

        if (builder.kind_of(parent) != .type_alias) return false;
        return builder.tree.child_first_of(parent) == node;
    }

    fn conditional(builder: *const Builder, node: u32) bool {
        assert(node < builder.tree.count());

        var held = builder.tree.parent_of(node);

        assert(builder.kind_of(node) == .name_node);

        for (0..builder.tree.count() + 1) |_| {
            const current = held orelse return false;
            const kind = builder.kind_of(current);

            switch (kind) {
                .async_function_def, .class_def, .function_def, .lambda, .module => return false,
                .except_handler, .@"if", .match_case, .@"while" => return true,
                else => {},
            }

            const parent = builder.tree.parent_of(current);

            if (kind == .else_clause) {
                if (parent) |above| {
                    if (builder.kind_of(above) == .@"try") return true;
                }
            }

            held = parent;
        }

        return false;
    }

    fn context_of(builder: *const Builder, node: u32) Usage {
        assert(node < builder.tree.count());

        var child = node;
        var parent = builder.tree.parent_of(child);
        var unpacked = false;

        assert(builder.kind_of(node) == .name_node);

        for (0..frame_depth_max) |_| {
            const above = parent orelse break;
            const kind = builder.kind_of(above);

            switch (kind) {
                .list, .parenthesized, .starred, .tuple => {},
                else => {
                    var usage = builder.context_in(above, child, kind);

                    usage.unpacked = unpacked;

                    return usage;
                },
            }

            unpacked = unpacked or kind == .list or kind == .tuple;
            child = above;
            parent = builder.tree.parent_of(above);
        }

        return .{ .context = .load, .kind = null, .unpacked = unpacked };
    }

    fn context_in(builder: *const Builder, parent: u32, child: u32, kind: Kind) Usage {
        assert(builder.tree.parent_of(child) == parent);
        assert(kind.is_node());

        var children = builder.view_of(parent).children();
        var position: u32 = none;
        var total: u32 = 0;

        for (0..builder.tree.count()) |_| {
            const found = children.next() orelse break;

            if (position == none) {
                if (found.index() == child) position = total;
            }

            total += 1;
        }

        assert(position < total);

        return usage_of(kind, position, total);
    }

    fn exported(builder: *Builder, node: u32) void {
        assert(node < none);

        const kind = builder.kind_of(node);

        assert(kind == .ann_assign or kind == .assign or kind == .aug_assign);

        if (builder.scope_current() != 0) return;

        const held = builder.view_of(node);
        const target = held.child_first() orelse return;
        if (target.kind() != .name_node) return;
        if (!std.mem.eql(u8, target.text(builder.source), "__all__")) return;

        const value = exported_value(held, kind) orelse return;
        var current = bare(value);

        for (0..builder.tree.count()) |_| {
            if (current.kind() != .bin_op) return builder.exported_elements(current);

            const left = current.child_at(0) orelse return;
            const right = current.child_at(1) orelse return;

            builder.exported_elements(bare(right));
            current = bare(left);
        }
    }

    fn exported_elements(builder: *Builder, value: View) void {
        var current = value;

        for (0..builder.tree.count()) |_| {
            switch (current.kind()) {
                .list, .tuple => return builder.exported_items(current),
                .call => {
                    const listed = listed_of(builder.source, current) orelse return;
                    return builder.exported_items(listed);
                },
                .named_expr => {
                    const named = current.child_at(1) orelse return;

                    current = bare(named);
                },
                else => return,
            }
        }
    }

    fn exported_items(builder: *Builder, list: View) void {
        assert(list.kind() == .list or list.kind() == .set or list.kind() == .tuple);

        var items = list.children();

        for (0..builder.tree.count()) |_| {
            const item = items.next() orelse break;
            if (item.kind() != .constant) continue;

            const constant = item.as_constant() orelse continue;
            if (constant.literal_class() != .text) continue;

            const span = constant.content_span(builder.source);

            if (builder.semantic.ext.exports.full()) {
                builder.outcome_truncate(.facts);
            } else {
                builder.semantic.ext.exports.push(span);
            }

            builder.fact(.export_named, span, span, Span.empty);
        }

        assert(items.current == null);
    }

    fn visible_from(builder: *const Builder, node: u32) u32 {
        assert(node < none);

        if (node >= builder.tree.count()) return 0;

        var held = node;

        for (0..builder.tree.count() + 1) |_| {
            const parent = builder.tree.parent_of(held) orelse break;

            switch (builder.kind_of(parent)) {
                .block, .module => break,
                else => {},
            }

            if (builder.view_of(parent).child_first_of(.block) != null) break;

            held = parent;
        }

        assert(held < builder.tree.count());

        const deferred = switch (builder.kind_of(held)) {
            .async_function_def, .function_def => true,
            else => false,
        };

        if (builder.view_of(held).child_first_of(.block)) |body| {
            if (deferred) return body.span().offset;
        }

        assert(held <= node);

        return builder.view_of(held).span().end();
    }

    fn record(builder: *Builder, kind: BindingKind, name: Span, node: u32) void {
        assert(node < builder.tree.count());
        assert(name.end() <= builder.source.len);

        builder.record_with(kind, name, node, .{});
    }

    fn record_with(
        builder: *Builder,
        kind: BindingKind,
        name: Span,
        node: u32,
        flags: BindingFlags,
    ) void {
        assert(node < builder.tree.count());
        assert(!flags.private);
        assert(name.length <= std.math.maxInt(u32) - name.offset);

        builder.record_visible(kind, name, node, flags, builder.visible_from(node));
    }

    fn record_visible(
        builder: *Builder,
        kind: BindingKind,
        name: Span,
        node: u32,
        flags: BindingFlags,
        visible: u32,
    ) void {
        assert(name.length <= std.math.maxInt(u32) - name.offset);
        assert(node < none);
        assert(visible < none);

        const text = builder.text_of(name);
        const natural = builder.natural_of(kind, node);
        const scope = builder.target_of(kind, name, natural);
        var held = flags;

        assert(scope < builder.semantic.scope_count());
        assert(name.end() <= builder.source.len);

        held.private = text.len > 0 and text[0] == '_';
        held.redirected = scope != natural;
        held.type_checking = builder.type_checking_block != null;

        const index = builder.semantic.declare(builder.source, scope, &.{
            .dead_zone_end = none,
            .ext = .{
                .branch = builder.branch_current(),
                .declared = null,
                .flags = held,
                .order = builder.order_of(node),
            },
            .from = visible,
            .kind = kind,
            .name = name,
            .node = node,
        }) catch |err| switch (err) {
            error.Truncated => return builder.outcome_truncate(.bindings),
        };

        chain_note(builder.semantic, index);
    }

    fn refer(builder: *Builder, reference: *const Reference) void {
        assert(reference.ext.branch < builder.semantic.ext.branches.count());
        assert(reference.namespace == .value);

        builder.semantic.refer(builder.source, reference) catch |err| switch (err) {
            error.Truncated => builder.outcome_truncate(.references),
        };
    }

    fn natural_of(builder: *const Builder, kind: BindingKind, node: u32) u32 {
        assert(node < builder.tree.count());

        const scope = if (kind == .named)
            builder.containing(builder.reading_scope(node))
        else
            builder.scope_current();

        assert(scope < builder.semantic.scope_count());

        return scope;
    }

    fn target_of(builder: *const Builder, kind: BindingKind, name: Span, natural: u32) u32 {
        assert(name.end() <= builder.source.len);
        assert(natural < builder.semantic.scope_count());

        switch (kind) {
            .deletion, .global, .nonlocal => return natural,
            else => {},
        }

        return redirect_of(builder.semantic, builder.source, natural, builder.text_of(name));
    }

    fn containing(builder: *const Builder, start: u32) u32 {
        assert(start < none);

        var scope = start;

        assert(scope < builder.semantic.scope_count());

        for (0..scope_depth_max + 1) |_| {
            const held = builder.semantic.scope_at(scope);
            if (held.kind != .comprehension) return scope;
            if (held.parent == none) return scope;

            scope = held.parent;
        }

        assert(scope < builder.semantic.scope_count());

        return scope;
    }
};

pub const annotation_bytes_max: u32 = 1 << 14;
pub const annotation_depth_max: u32 = 1 << 6;
pub const attribute_depth_max: u32 = 1 << 6;
pub const branch_depth_max: u32 = 1 << 8;
pub const decorator_depth_max: u32 = 1 << 8;
pub const scope_depth_max: u32 = 1 << 8;
pub const segment_count_max: u32 = 1 << 6;
const annotation_nest_max: u32 = 1 << 4;
const annotation_store_max: u32 = 1 << 4;
const bisect_step_max: u32 = 33;
const permuted_call_depth_max: u32 = 1 << 6;
const qualified_bytes_max: u32 = 1 << 8;
const typed_depth_max: u32 = 1 << 6;

const callable_names = std.StaticStringMap(Callable).initComptime(.{
    .{ "_typeshed.NamedTuple", .named_tuple },
    .{ "_typeshed.NewType", .new_type },
    .{ "_typeshed.TypeAliasType", .type_alias_type },
    .{ "_typeshed.TypeVar", .type_var },
    .{ "_typeshed.TypedDict", .typed_dict },
    .{ "_typeshed.cast", .cast },
    .{ "builtins.bool", .bool },
    .{ "mypy_extensions.Arg", .mypy_extension },
    .{ "mypy_extensions.DefaultArg", .mypy_extension },
    .{ "mypy_extensions.DefaultNamedArg", .mypy_extension },
    .{ "mypy_extensions.KwArg", .mypy_extension },
    .{ "mypy_extensions.NamedArg", .mypy_extension },
    .{ "mypy_extensions.VarArg", .mypy_extension },
    .{ "typing.NamedTuple", .named_tuple },
    .{ "typing.NewType", .new_type },
    .{ "typing.TypeAliasType", .type_alias_type },
    .{ "typing.TypeVar", .type_var },
    .{ "typing.TypedDict", .typed_dict },
    .{ "typing.cast", .cast },
    .{ "typing_extensions.NamedTuple", .named_tuple },
    .{ "typing_extensions.NewType", .new_type },
    .{ "typing_extensions.TypeAliasType", .type_alias_type },
    .{ "typing_extensions.TypeVar", .type_var },
    .{ "typing_extensions.TypedDict", .typed_dict },
    .{ "typing_extensions.cast", .cast },
});

const subscript_names = std.StaticStringMap(Subscripted).initComptime(.{
    .{ "builtins.dict", .generic },
    .{ "builtins.frozenset", .generic },
    .{ "builtins.list", .generic },
    .{ "builtins.set", .generic },
    .{ "builtins.tuple", .generic },
    .{ "builtins.type", .generic },
    .{ "collections.ChainMap", .generic },
    .{ "collections.Counter", .generic },
    .{ "collections.OrderedDict", .generic },
    .{ "collections.abc.AsyncGenerator", .generic },
    .{ "collections.abc.AsyncIterable", .generic },
    .{ "collections.abc.AsyncIterator", .generic },
    .{ "collections.abc.Awaitable", .generic },
    .{ "collections.abc.ByteString", .generic },
    .{ "collections.abc.Callable", .generic },
    .{ "collections.abc.Collection", .generic },
    .{ "collections.abc.Container", .generic },
    .{ "collections.abc.Coroutine", .generic },
    .{ "collections.abc.Generator", .generic },
    .{ "collections.abc.ItemsView", .generic },
    .{ "collections.abc.Iterable", .generic },
    .{ "collections.abc.Iterator", .generic },
    .{ "collections.abc.KeysView", .generic },
    .{ "collections.abc.Mapping", .generic },
    .{ "collections.abc.MappingView", .generic },
    .{ "collections.abc.MutableMapping", .generic },
    .{ "collections.abc.MutableSequence", .generic },
    .{ "collections.abc.MutableSet", .generic },
    .{ "collections.abc.Reversible", .generic },
    .{ "collections.abc.Sequence", .generic },
    .{ "collections.abc.Set", .generic },
    .{ "collections.abc.ValuesView", .generic },
    .{ "collections.defaultdict", .generic },
    .{ "collections.deque", .generic },
    .{ "contextlib.AbstractAsyncContextManager", .generic },
    .{ "contextlib.AbstractContextManager", .generic },
    .{ "re.Match", .generic },
    .{ "re.Pattern", .generic },
    .{ "typing.AbstractSet", .generic },
    .{ "typing.Annotated", .annotated },
    .{ "typing.AsyncContextManager", .generic },
    .{ "typing.AsyncGenerator", .generic },
    .{ "typing.AsyncIterator", .generic },
    .{ "typing.Awaitable", .generic },
    .{ "typing.BinaryIO", .generic },
    .{ "typing.ByteString", .generic },
    .{ "typing.Callable", .generic },
    .{ "typing.ChainMap", .generic },
    .{ "typing.ClassVar", .generic },
    .{ "typing.Collection", .generic },
    .{ "typing.Concatenate", .generic },
    .{ "typing.Container", .generic },
    .{ "typing.ContextManager", .generic },
    .{ "typing.Coroutine", .generic },
    .{ "typing.Counter", .generic },
    .{ "typing.DefaultDict", .generic },
    .{ "typing.Deque", .generic },
    .{ "typing.Dict", .generic },
    .{ "typing.Final", .generic },
    .{ "typing.FrozenSet", .generic },
    .{ "typing.Generator", .generic },
    .{ "typing.Generic", .generic },
    .{ "typing.IO", .generic },
    .{ "typing.ItemsView", .generic },
    .{ "typing.Iterable", .generic },
    .{ "typing.Iterator", .generic },
    .{ "typing.KeysView", .generic },
    .{ "typing.List", .generic },
    .{ "typing.Literal", .literal },
    .{ "typing.Mapping", .generic },
    .{ "typing.Match", .generic },
    .{ "typing.MutableMapping", .generic },
    .{ "typing.MutableSequence", .generic },
    .{ "typing.MutableSet", .generic },
    .{ "typing.Optional", .generic },
    .{ "typing.OrderedDict", .generic },
    .{ "typing.Pattern", .generic },
    .{ "typing.Reversible", .generic },
    .{ "typing.Sequence", .generic },
    .{ "typing.Set", .generic },
    .{ "typing.TextIO", .generic },
    .{ "typing.Tuple", .generic },
    .{ "typing.Type", .generic },
    .{ "typing.TypeGuard", .generic },
    .{ "typing.TypedDict", .typed_dict },
    .{ "typing.Union", .generic },
    .{ "typing.Unpack", .generic },
    .{ "typing.ValuesView", .generic },
    .{ "typing.io.BinaryIO", .generic },
    .{ "typing.io.IO", .generic },
    .{ "typing.io.TextIO", .generic },
    .{ "typing.re.Match", .generic },
    .{ "typing.re.Pattern", .generic },
    .{ "typing_extensions.Annotated", .annotated },
    .{ "typing_extensions.AsyncContextManager", .generic },
    .{ "typing_extensions.AsyncGenerator", .generic },
    .{ "typing_extensions.AsyncIterable", .generic },
    .{ "typing_extensions.AsyncIterator", .generic },
    .{ "typing_extensions.Awaitable", .generic },
    .{ "typing_extensions.ChainMap", .generic },
    .{ "typing_extensions.ClassVar", .generic },
    .{ "typing_extensions.Concatenate", .generic },
    .{ "typing_extensions.ContextManager", .generic },
    .{ "typing_extensions.Coroutine", .generic },
    .{ "typing_extensions.Counter", .generic },
    .{ "typing_extensions.DefaultDict", .generic },
    .{ "typing_extensions.Deque", .generic },
    .{ "typing_extensions.Literal", .literal },
    .{ "typing_extensions.Type", .generic },
    .{ "typing_extensions.TypedDict", .typed_dict },
    .{ "weakref.WeakKeyDictionary", .generic },
    .{ "weakref.WeakSet", .generic },
    .{ "weakref.WeakValueDictionary", .generic },
});

comptime {
    assert(annotation_depth_max <= scope_depth_max);
    assert(bisect_step_max > @bitSizeOf(u32));
}

fn answers_in(semantic: *const Semantic, source: []const u8, scope: u32, name: []const u8) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(scope < semantic.scope_count());
    assert(name.len > 0);

    var index = semantic.binding_newest(source, scope, name, null);

    for (0..semantic.count() + 1) |_| {
        const current = index orelse return false;
        const held = semantic.at(current);
        if (held.kind.answers()) return true;

        index = if (held.name_previous == none) null else held.name_previous;
    }

    return false;
}

fn bound_in(semantic: *const Semantic, source: []const u8, reference: *const Reference) ?u32 {
    assert(source.len <= std.math.maxInt(u32));

    const start = Rules.start_scope(semantic, source, reference);
    var scope = start;

    var position: Position = .{
        .crossed_function = start != reference.scope,
        .redirected = start != reference.scope,
        .start = true,
    };

    assert(reference.scope < semantic.scope_count());
    assert(reference.namespace == .value);

    for (0..scope_depth_max + 1) |_| {
        if (scope == none) break;

        const held = semantic.scope_at(scope);

        if (!Rules.skips(held.kind, position)) {
            if (visible_in(semantic, source, reference, scope, position)) |index| return index;
        }

        position.from_type = position.start and Rules.types(held.kind);
        position.start = false;
        position.crossed_function = position.crossed_function or Rules.crosses(held.kind);
        scope = held.parent;
    }

    return null;
}

fn chain_note(semantic: *Semantic, index: u32) void {
    assert(index < none);

    const bindings = semantic.bindings.slice();
    const held = &bindings[index];

    assert(index + 1 == semantic.count());
    assert(held.ext.declared == null);

    if (held.name_previous != none) {
        const earlier = &bindings[held.name_previous];

        held.ext.declared = earlier.ext.declared;
        earlier.ext.flags.shadowed = earlier.ext.flags.shadowed or held.kind.binds();
        earlier.ext.flags.deleted = earlier.ext.flags.deleted or held.kind == .deletion;
    }

    if (held.ext.declared == null) {
        switch (held.kind) {
            .global, .nonlocal => held.ext.declared = held.kind,
            else => {},
        }
    }
}

fn head_of(
    semantic: *const Semantic,
    source: []const u8,
    head: View,
    resolution: Resolution,
    out: *ArrayType(Span),
) Qualified {
    assert(head.kind() == .name_node);
    assert(out.empty());
    assert(source.len <= std.math.maxInt(u32));
    if (resolution == .bound) assert(resolution.bound < semantic.count());

    const binding = switch (resolution) {
        .builtin => {
            if (out.full()) return .unresolved;

            out.push(head.span());

            return .builtin;
        },
        .bound => |index| index,
        .external => unreachable,
        .maybe, .unresolved => return .unresolved,
    };

    const bound = semantic.at(binding);

    if (!bound.kind.imports()) {
        if (out.full()) return .unresolved;

        out.push(head.span());

        return .{ .local = binding };
    }

    const alias = head.at(bound.node);

    switch (bound.kind) {
        .import, .submodule_import => {
            const cast = alias.as_alias() orelse return .unresolved;

            cast.name_segments(out) catch |err| switch (err) {
                error.Truncated => return .unresolved,
            };

            if (cast.asname_token() == null) out.truncate(1);

            return .resolved;
        },
        else => return remote_of(source, alias, out),
    }
}

fn mark_exports(semantic: *Semantic, source: []const u8) void {
    assert(source.len <= std.math.maxInt(u32));

    const exports = semantic.ext.exports.const_slice();

    assert(exports.len <= semantic.ext.exports.capacity());

    if (exports.len == 0) return;

    for (semantic.bindings.slice()) |*held| {
        if (held.scope != 0) continue;

        const name = held.name.text(source);
        var exported = false;

        for (exports) |span| {
            if (std.mem.eql(u8, span.text(source), name)) {
                exported = true;

                break;
            }
        }

        held.ext.flags.export_explicit = exported;
    }

    assert(exports.len > 0);
}

fn forwarded(semantic: *const Semantic, source: []const u8, name: []const u8) bool {
    assert(semantic.scope_count() > 0);
    assert(name.len > 0);
    assert(source.len <= std.math.maxInt(u32));

    var index = semantic.binding_newest(source, 0, name, null) orelse return false;

    for (0..semantic.count()) |_| {
        const held = semantic.at(index);

        switch (held.kind) {
            .global, .nonlocal => {},
            else => return held.kind.binds(),
        }

        if (held.name_previous == none) return false;

        index = held.name_previous;
    }

    return false;
}

fn redirect_of(semantic: *const Semantic, source: []const u8, scope: u32, name: []const u8) u32 {
    assert(scope < semantic.scope_count());
    assert(name.len > 0);
    assert(source.len <= std.math.maxInt(u32));

    const newest = semantic.binding_newest(source, scope, name, null) orelse return scope;
    const declared = semantic.at(newest).ext.declared orelse return scope;

    assert(declared == .global or declared == .nonlocal);

    if (declared == .global) return 0;

    var held = semantic.scope_at(scope).parent;

    for (0..scope_depth_max + 1) |_| {
        if (held == none) break;

        const enclosing = semantic.scope_at(held);

        if (enclosing.kind == .function) {
            if (answers_in(semantic, source, held, name)) return held;
        }

        held = enclosing.parent;
    }

    return scope;
}

fn bare(view: View) View {
    var current = view;

    for (0..view.tree.count()) |_| {
        if (current.kind() != .parenthesized) break;

        current = current.child_first() orelse break;
    }

    assert(current.kind() != .parenthesized or current.child_first() == null);

    return current;
}

fn exported_value(statement: View, kind: Kind) ?View {
    assert(statement.node < statement.tree.count());
    assert(kind.is_node());

    var children = statement.children();
    var last: ?View = null;
    var count: u32 = 0;

    for (0..statement.tree.count()) |_| {
        const child = children.next() orelse break;

        last = child;
        count += 1;
    }

    const owed: u32 = if (kind == .ann_assign) 3 else 2;
    if (count < owed) return null;
    return last;
}

fn listed_of(source: []const u8, call: View) ?View {
    assert(source.len <= std.math.maxInt(u32));
    assert(call.span().end() <= source.len);

    const held = call.as_call() orelse return null;
    var callee = held.callee() orelse return null;
    if (callee.kind() == .subscript) callee = callee.child_first() orelse return null;
    if (callee.kind() != .name_node) return null;

    const name = callee.text(source);

    if (!std.mem.eql(u8, name, "list")) {
        if (!std.mem.eql(u8, name, "tuple")) return null;
    }

    var keywords = held.keywords();
    if (keywords.next() != null) return null;

    var arguments = held.arguments();
    const argument = arguments.next() orelse return null;

    if (arguments.next() != null) return null;

    const inner = bare(argument);

    return switch (inner.kind()) {
        .list, .set, .tuple => inner,
        else => null,
    };
}

fn deleted_at_home(
    semantic: *const Semantic,
    source: []const u8,
    reference: *const Reference,
    target: u32,
) bool {
    assert(source.len <= std.math.maxInt(u32));

    const name = reference.name.text(source);
    const offset = reference.name.offset;
    var index = semantic.binding_newest(source, reference.scope, name, null);
    var deleted: ?u32 = null;

    assert(target != reference.scope);
    assert(target < semantic.scope_count());

    for (0..semantic.count() + 1) |_| {
        const current = index orelse break;
        const held = semantic.at(current);
        const visible = held.kind == .deletion and held.from <= offset;

        if (visible) {
            const later = deleted == null or held.name.offset > deleted.?;

            if (later) deleted = held.name.offset;
        }

        index = if (held.name_previous == none) null else held.name_previous;
    }

    const since = deleted orelse return false;

    assert(since < offset);

    return !rebound_between(semantic, source, target, name, since, offset);
}

fn rebound_between(
    semantic: *const Semantic,
    source: []const u8,
    scope: u32,
    name: []const u8,
    after: u32,
    before: u32,
) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(scope < semantic.scope_count());
    assert(name.len <= std.math.maxInt(u32));

    var index = semantic.binding_newest(source, scope, name, null);

    assert(after < before);

    for (0..semantic.count() + 1) |_| {
        const current = index orelse return false;
        const held = semantic.at(current);
        const inside = held.name.offset > after and held.name.offset < before;

        if (inside) {
            if (held.kind.binds()) return true;
        }

        index = if (held.name_previous == none) null else held.name_previous;
    }

    return false;
}

fn scope_kind_of(kind: Kind) ScopeKind {
    assert(kind.is_node());

    const result: ScopeKind = switch (kind) {
        .async_function_def, .function_def => .function,
        .class_def => .class,
        .dict_comp, .generator_exp, .list_comp, .set_comp => .comprehension,
        .lambda => .lambda,
        .type_alias => .type_alias,
        .type_params => .type,
        else => unreachable,
    };

    if (opens_a_scope(kind)) assert(result != .type);
    if (kind == .type_params) assert(result == .type);

    return result;
}

fn semantic_build(
    semantic: *Semantic,
    input: *const SemanticInput,
    scratch: *AnnotationScratch,
) Structure {
    assert(input.tokens.len == input.raw.len);
    assert(input.source.len <= std.math.maxInt(u32));

    semantic.clear();
    semantic.scope_root(.module, 0, {});
    semantic.ext.branches.push(.{ .node = none, .parent = none });

    var builder: Builder = .init(semantic, input, scratch);

    builder.collect();

    const outcome = builder.outcome;

    semantic.resolve(input.source, &.{ .builtins = input.builtins, .version = input.version });

    assert(semantic.ext.branches.count() >= 1);

    return outcome;
}

fn visible_in(
    semantic: *const Semantic,
    source: []const u8,
    reference: *const Reference,
    scope: u32,
    position: Position,
) ?u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(scope < semantic.scope_count());
    if (position.redirected) assert(position.crossed_function);

    const kind = semantic.scope_at(scope).kind;
    var index = semantic.binding_newest(source, scope, reference.name.text(source), null);

    assert(reference.namespace == .value);

    for (0..semantic.count() + 1) |_| {
        const current = index orelse return null;
        const held = semantic.at(current);

        if (Rules.binds_in(held.kind, reference.namespace)) {
            if (Rules.visible(&held, reference, kind, position)) return current;
        }

        index = if (held.name_previous == none) null else held.name_previous;
    }

    return null;
}

fn references_sorted(references: []const Reference) bool {
    assert(references.len <= std.math.maxInt(u32));

    if (references.len < 2) return true;

    assert(references.len >= 2);

    for (references[0 .. references.len - 1], references[1..]) |left, right| {
        if (left.node > right.node) return false;
    }

    return true;
}

fn opens_a_scope(kind: Kind) bool {
    assert(kind.is_node());

    const result = switch (kind) {
        .async_function_def,
        .class_def,
        .dict_comp,
        .function_def,
        .generator_exp,
        .lambda,
        .list_comp,
        .set_comp,
        .type_alias,
        => true,
        else => false,
    };

    if (result) assert(kind.is_node());
    if (kind == .block) assert(!result);

    return result;
}

fn usage_of(kind: Kind, position: u32, total: u32) Usage {
    assert(position < total);
    assert(kind.is_node());

    const held: Usage = switch (kind) {
        .delete => .{ .context = .delete, .kind = .deletion, .unpacked = false },
        .assign => if (position + 1 < total) stored(.assignment) else loaded,
        .ann_assign => if (position == 0)
            stored(if (total < 3) .annotation else .assignment)
        else
            loaded,
        .with_item => if (position > 0) stored(.with_variable) else loaded,
        .aug_assign => if (position == 0) stored(.augmented) else loaded,
        .async_for, .@"for" => if (position == 0) stored(.loop_variable) else loaded,
        .comprehension => if (position == 0) stored(.comprehension_variable) else loaded,
        .named_expr => if (position == 0) stored(.named) else loaded,
        else => loaded,
    };

    return held;
}

fn stored(kind: BindingKind) Usage {
    const usage: Usage = .{ .context = .store, .kind = kind, .unpacked = false };

    assert(usage.kind != null);
    assert(kind != .deletion);

    return usage;
}

const loaded: Usage = .{ .context = .load, .kind = null, .unpacked = false };

fn annotation_names_of(
    tree: *const Tree,
    tokens: []const Token,
    raw: []const Kind,
    text: []const u8,
    located: Located,
    found: []Named,
) ?u32 {
    assert(raw.len <= std.math.maxInt(u32));
    assert(text.len <= std.math.maxInt(u32));
    assert(located.origins.len <= std.math.maxInt(u32));

    var total: u32 = 0;
    var steps = walk(Tree, tree);

    assert(tree.count() > 0);
    assert(tokens.len <= std.math.maxInt(u32));
    assert(found.len <= annotation_depth_max);

    for (0..steps.step_max) |_| {
        const step = steps.next() orelse break;

        const inner = switch (step) {
            .enter => |held| held,
            .leave => continue,
        };

        if (tree.kind_at(inner) != .name_node) continue;
        if (bound_inside(View.init(tree, tokens, raw, inner), text)) continue;

        const name = located.span_of(tree.at(inner).span(Token, tokens)) orelse continue;

        if (total == found.len) return null;

        found[total] = .{ .name = name, .relocated = located.relocated };
        total += 1;
    }

    return total;
}

fn annotation_stores_of(root: View, text: []const u8, located: Located, stores: *Stores) void {
    assert(root.node < root.tree.count());
    assert(text.len <= std.math.maxInt(u32));
    assert(located.origins.len <= std.math.maxInt(u32));

    var steps = walk_from(Tree, root.tree, root.index());

    assert(stores.count <= annotation_store_max);

    for (0..steps.step_max) |_| {
        const step = steps.next() orelse break;

        const inner = switch (step) {
            .enter => |held| held,
            .leave => continue,
        };

        if (root.tree.kind_at(inner) != .named_expr) continue;

        const walrus = root.at(inner);
        const target = walrus.child_first() orelse continue;
        if (target.kind() != .name_node) continue;
        if (lambda_reads(walrus, target, text)) continue;

        const name = located.span_of(target.span()) orelse continue;

        if (stores.count == annotation_store_max) return;

        stores.spans[stores.count] = name;
        stores.count += 1;
    }
}

fn bound_inside(name: View, text: []const u8) bool {
    assert(name.kind() == .name_node);
    assert(text.len <= std.math.maxInt(u32));

    const spelled = name.text(text);
    var below: ?View = null;
    var child = name;
    var targeted = true;

    for (0..annotation_depth_max) |_| {
        const parent = child.parent() orelse return false;

        switch (parent.kind()) {
            .comprehension, .named_expr => {
                const target = parent.child_first() orelse return false;

                if (targeted) {
                    if (target.index() == child.index()) return true;
                }
            },
            .dict_comp, .generator_exp, .list_comp, .set_comp => {
                if (comprehension_binds(parent, child, below, spelled, text)) return true;
            },
            .lambda => if (lambda_binds(parent, child, spelled, text)) return true,
            else => {},
        }

        switch (parent.kind()) {
            .list, .parenthesized, .starred, .tuple => {},
            else => targeted = false,
        }

        below = child;
        child = parent;
    }

    return false;
}

fn comprehension_binds(
    construct: View,
    child: View,
    below: ?View,
    spelled: []const u8,
    text: []const u8,
) bool {
    assert(construct.node < construct.tree.count());
    assert(child.node < child.tree.count());
    assert(spelled.len <= std.math.maxInt(u32));
    assert(text.len <= std.math.maxInt(u32));
    if (below) |held| assert(held.node < held.tree.count());

    var clauses = construct.children_of(.comprehension);
    var first = true;

    for (0..construct.tree.count()) |_| {
        const clause = clauses.next() orelse break;
        const target = clause.child_first() orelse continue;
        defer first = false;

        if (first) {
            if (clause.index() == child.index()) {
                const iterable = clause.child_at(1) orelse return false;
                const held = below orelse return false;
                if (held.index() == iterable.index()) return false;
            }
        }

        if (names_spelled(target, spelled, text)) return true;
    }

    return false;
}

fn lambda_reads(walrus: View, target: View, text: []const u8) bool {
    assert(walrus.kind() == .named_expr);
    assert(target.node < target.tree.count());
    assert(text.len <= std.math.maxInt(u32));

    const spelled = target.text(text);
    var held = walrus;

    for (0..annotation_depth_max) |_| {
        const parent = held.parent() orelse return false;
        if (parent.kind() == .lambda) return names_read(parent, target, spelled, text);

        held = parent;
    }

    return false;
}

fn names_read(lambda: View, target: View, spelled: []const u8, text: []const u8) bool {
    assert(lambda.kind() == .lambda);
    assert(target.node < target.tree.count());
    assert(spelled.len <= std.math.maxInt(u32));
    assert(text.len <= std.math.maxInt(u32));

    var steps = walk_from(Tree, lambda.tree, lambda.index());

    for (0..steps.step_max) |_| {
        const step = steps.next() orelse break;

        const inner = switch (step) {
            .enter => |held| held,
            .leave => continue,
        };

        if (inner == target.index()) continue;
        if (lambda.tree.kind_at(inner) != .name_node) continue;
        if (std.mem.eql(u8, lambda.at(inner).text(text), spelled)) return true;
    }

    return false;
}

fn lambda_binds(lambda: View, child: View, spelled: []const u8, text: []const u8) bool {
    assert(lambda.node < lambda.tree.count());
    assert(spelled.len <= std.math.maxInt(u32));
    assert(text.len <= std.math.maxInt(u32));

    var children = lambda.children();
    var last: ?View = null;

    for (0..lambda.tree.count()) |_| {
        last = children.next() orelse break;
    }

    const body = last orelse return false;
    if (body.index() != child.index()) return false;

    var parameters = lambda.children_of(.arg);

    for (0..lambda.tree.count()) |_| {
        const parameter = parameters.next() orelse break;
        const position = parameter.token_first(.identifier) orelse continue;
        if (std.mem.eql(u8, parameter.token_at(position).text(text), spelled)) return true;
    }

    return walrus_spelled(body, spelled, text);
}

fn walrus_spelled(body: View, spelled: []const u8, text: []const u8) bool {
    assert(body.node < body.tree.count());
    assert(spelled.len <= std.math.maxInt(u32));
    assert(text.len <= std.math.maxInt(u32));

    var steps = walk_from(Tree, body.tree, body.index());

    for (0..steps.step_max) |_| {
        const step = steps.next() orelse break;

        const inner = switch (step) {
            .enter => |held| held,
            .leave => continue,
        };

        if (body.tree.kind_at(inner) != .named_expr) continue;

        const target = body.at(inner).child_first() orelse continue;
        if (target.kind() != .name_node) continue;
        if (std.mem.eql(u8, target.text(text), spelled)) return true;
    }

    return false;
}

fn names_spelled(target: View, spelled: []const u8, text: []const u8) bool {
    assert(target.node < target.tree.count());
    assert(text.len <= std.math.maxInt(u32));

    var steps = walk_from(Tree, target.tree, target.index());

    assert(spelled.len > 0);

    for (0..steps.step_max) |_| {
        const step = steps.next() orelse break;

        const inner = switch (step) {
            .enter => |held| held,
            .leave => continue,
        };

        if (target.tree.kind_at(inner) != .name_node) continue;
        if (std.mem.eql(u8, target.at(inner).text(text), spelled)) return true;
    }

    return false;
}

fn dict_entry(entry: View) Entry {
    assert(entry.node < entry.tree.count());

    var before = entry.token_start();
    var after = entry.token_end();

    assert(before < after);
    assert(after <= entry.raw.len);

    for (0..entry.raw.len) |_| {
        if (before == 0) break;

        before -= 1;

        if (entry.raw[before] != .comment) break;
    }

    if (before < entry.token_start()) {
        if (entry.raw[before] == .star_star) return .unpacked;
    }

    for (0..entry.raw.len) |_| {
        if (after >= entry.raw.len) return .value;
        if (entry.raw[after] != .comment) break;

        after += 1;
    }

    if (after >= entry.raw.len) return .value;
    return if (entry.raw[after] == .colon) .key else .value;
}

fn expression_root(tree: *const Tree, tokens: []const Token, raw: []const Kind) ?u32 {
    if (tree.count() == 0) return null;
    assert(tokens.len <= std.math.maxInt(u32));
    assert(raw.len <= std.math.maxInt(u32));

    const module = View.init(tree, tokens, raw, 0);
    var statements = module.children();
    const statement = statements.next() orelse return null;

    if (statements.next() != null) return null;
    if (statement.kind() != .expr) return null;

    const expression = statement.child_first() orelse return null;

    assert(expression.index() > statement.index());

    return expression.index();
}

fn relocation_of(named: Named) ?u16 {
    assert(named.name.length <= std.math.maxInt(u32) - named.name.offset);

    const relocated = named.relocated orelse return 0;

    assert(relocated < named.name.offset);

    return std.math.cast(u16, named.name.offset - relocated);
}

fn plain_string(held: View, text: []const u8) bool {
    assert(held.node < held.tree.count());
    assert(text.len <= std.math.maxInt(u32));

    const total = positions_total(held.positions());
    var positions = held.positions();

    if (held.as_constant() == null) return false;
    if (total == 0) return false;

    for (0..total) |_| {
        const position = positions.next() orelse return false;
        if (held.token_kind(position) != .string_plain) return false;

        const prefix = literal.prefix_of(held.token_at(position).text(text));
        if (prefix.bytes) return false;
        if (prefix.format) return false;
        if (prefix.template) return false;
    }

    return true;
}

fn simple_content(string: View, text: []const u8, decoded: []const u8) ?Span {
    assert(string.node < string.tree.count());
    assert(text.len <= std.math.maxInt(u32));

    var positions = string.positions();
    if (positions_total(string.positions()) != 1) return null;

    const position = positions.next() orelse return null;
    const token = string.token_at(position).span();
    const shape = literal.shape_of(token.text(text), token.offset) orelse return null;

    assert(shape.content.end() <= token.end());

    if (!std.mem.eql(u8, shape.content.text(text), decoded)) return null;
    return shape.content;
}

fn joined(buffer: *[qualified_bytes_max]u8, head: []const u8, tail: []const u8) ?u32 {
    assert(head.len <= std.math.maxInt(u32));
    assert(tail.len <= std.math.maxInt(u32));

    const dotted: u32 = @intFromBool(tail.len > 0);
    const length = head.len + dotted + tail.len;

    if (head.len == 0) return null;
    if (length > buffer.len) return null;

    @memcpy(buffer[0..head.len], head);

    if (tail.len > 0) {
        buffer[head.len] = '.';

        @memcpy(buffer[head.len + 1 ..][0..tail.len], tail);
    }

    assert(length <= qualified_bytes_max);

    return @intCast(length);
}

fn shifted(span: Span, base: u32) Span {
    assert(span.end() <= std.math.maxInt(u32) - base);

    return .{ .offset = span.offset + base, .length = span.length };
}

fn typed_alias(alias: View, child: View) Typed {
    assert(alias.kind() == .type_alias);
    assert(child.node < child.tree.count());

    var children = alias.children();
    var last: ?View = null;

    for (0..alias.tree.count()) |_| {
        last = children.next() orelse break;
    }

    const value = last orelse return .value;
    return typed_if(value.index() == child.index());
}

fn typed_dict_entry(holder: View, path: []const u32, unpacked: Typed) Typed {
    assert(holder.node < holder.tree.count());
    assert(path.len > 0);

    const slot = unwrapped(holder, path, path.len - 1);
    const dict = holder.at(path[slot]);

    if (dict.kind() != .dict) return .value;
    if (slot == 0) return .value;

    return switch (dict_entry(holder.at(path[slot - 1]))) {
        .key => .value,
        .unpacked => unpacked,
        .value => .type,
    };
}

fn typed_if(condition: bool) Typed {
    return if (condition) .type else .value;
}

fn typed_metadata(subscript: View, path: []const u32) Typed {
    assert(subscript.kind() == .subscript);
    assert(path.len <= std.math.maxInt(u32));

    const slot = unwrapped(subscript, path, path.len - 1);
    const slice = subscript.at(path[slot]);

    if (slice.kind() != .tuple) return .climb;
    if (slot == 0) return .value;

    const first = slice.child_first() orelse return .value;
    return typed_if(first.index() == path[slot - 1]);
}

fn typed_named_entry(call: View, path: []const u32, argument: Argument) Typed {
    assert(argument.keyword);
    assert(path.len > 0);
    assert(call.node < call.tree.count());

    if (argument.name != null) return .type;
    if (path.len < 2) return .value;
    return typed_dict_entry(call, path[0 .. path.len - 1], .value);
}

fn typed_named_fields(call: View, path: []const u32) Typed {
    assert(call.kind() == .call);
    assert(path.len <= std.math.maxInt(u32));

    const slot = unwrapped(call, path, path.len - 1);
    const fields = call.at(path[slot]);

    switch (fields.kind()) {
        .list, .tuple => {},
        else => return .value,
    }

    if (slot == 0) return .value;

    const inner = unwrapped(call, path, slot - 1);
    const field = call.at(path[inner]);

    switch (field.kind()) {
        .list, .tuple => {},
        else => return .value,
    }

    if (inner == 0) return .value;

    var parts = field.children();
    const first = parts.next() orelse return .value;
    const second = parts.next() orelse return .value;

    if (parts.next() != null) return .value;

    assert(first.index() < second.index());

    return typed_if(path[inner - 1] == second.index());
}

fn typed_through(kind: Kind) bool {
    assert(kind.is_node());

    return switch (kind) {
        .attribute,
        .await,
        .bin_op,
        .bool_op,
        .compare,
        .comprehension,
        .dict,
        .dict_comp,
        .formatted_value,
        .generator_exp,
        .if_exp,
        .joined_str,
        .keyword,
        .lambda,
        .list,
        .list_comp,
        .named_expr,
        .parenthesized,
        .set,
        .set_comp,
        .slice,
        .starred,
        .tuple,
        .unary_op,
        .yield,
        .yield_from,
        => true,
        else => false,
    };
}

fn unwrapped(holder: View, path: []const u32, top: usize) usize {
    assert(holder.node < holder.tree.count());
    assert(top < path.len);

    var slot = top;

    for (0..path.len) |_| {
        if (slot == 0) break;
        if (holder.at(path[slot]).kind() != .parenthesized) break;

        slot -= 1;
    }

    assert(slot <= top);

    return slot;
}

fn position_last(positions: Positions) ?u32 {
    var rest = positions;
    var found: ?u32 = null;

    assert(rest.limit <= rest.raw.len);

    for (0..rest.raw.len + 1) |_| {
        found = rest.next() orelse break;
    }

    if (found) |position| assert(position < rest.limit);

    return found;
}

fn positions_total(positions: Positions) u32 {
    var rest = positions;
    var total: u32 = 0;

    assert(rest.limit <= rest.raw.len);

    for (0..rest.raw.len + 1) |_| {
        if (rest.next() == null) break;

        total += 1;
    }

    assert(total <= rest.limit);

    return total;
}

fn span_empty(span: Span) bool {
    assert(span.length <= std.math.maxInt(u32) - span.offset);

    const result = span.offset == 0 and span.length == 0;

    if (result) assert(span.end() == 0);
    if (span.length > 0) assert(!result);

    return result;
}

fn upto(held: View, close: Kind) Span {
    assert(held.node < held.tree.count());

    var positions = held.positions();
    var first = Span.empty;
    var last = Span.empty;

    assert(close.is_token());

    for (0..held.raw.len + 1) |_| {
        const position = positions.next() orelse break;
        if (held.token_kind(position) == close) break;

        const span = held.token_at(position).span();

        if (span_empty(first)) first = span;

        last = span;
    }

    if (span_empty(first)) return Span.empty;

    assert(last.end() >= first.offset);

    return .{ .offset = first.offset, .length = last.end() - first.offset };
}

fn between(held: View, open: Kind, close: Kind) Span {
    assert(held.node < held.tree.count());

    var positions = held.positions();
    var started = false;
    var first = Span.empty;
    var last = Span.empty;

    assert(open != close);

    for (0..held.raw.len + 1) |_| {
        const position = positions.next() orelse break;
        const kind = held.token_kind(position);
        if (kind == close) break;

        if (kind == open) {
            started = true;

            continue;
        }

        if (!started) continue;

        const span = held.token_at(position).span();

        if (span_empty(first)) first = span;

        last = span;
    }

    if (span_empty(first)) return Span.empty;

    assert(last.end() >= first.offset);

    return .{ .offset = first.offset, .length = last.end() - first.offset };
}

fn forwards(text: []const u8, module: []const u8) bool {
    assert(module.len > 0);
    assert(text.len <= std.math.maxInt(u32));

    if (std.mem.eql(u8, text, module)) return true;
    return std.mem.eql(u8, module, "typing") and std.mem.eql(u8, text, "typing_extensions");
}

fn submodule(alias: View) bool {
    assert(alias.kind() == .alias);

    if (alias.as_alias()) |cast| {
        if (cast.asname_token() != null) return false;
    }

    const identifiers = positions_total(alias.positions_of(.identifier));

    assert(identifiers <= alias.token_end() - alias.token_start());

    return identifiers > 1;
}

fn alias_name(alias: View) ?Span {
    assert(alias.node < alias.tree.count());

    var positions = alias.positions_of(.identifier);
    const first: ?Span = if (positions.next()) |position| alias.token_at(position).span() else null;
    const cast = alias.as_alias() orelse return first;
    const position = cast.asname_token() orelse return first;

    assert(position > alias.token_start());
    assert(position < alias.token_end());

    return alias.token_at(position).span();
}

fn remote_of(source: []const u8, alias: View, out: *ArrayType(Span)) Qualified {
    assert(alias.span().end() <= source.len);

    const statement = alias.parent() orelse return .unresolved;
    const cast = statement.as_import() orelse return .unresolved;

    assert(alias.kind() == .alias);

    cast.module_segments(out) catch |err| switch (err) {
        error.Truncated => return .unresolved,
    };

    const position = alias.token_first(.identifier) orelse return .unresolved;

    if (out.full()) return .unresolved;

    out.push(alias.token_at(position).span());

    assert(source.len > 0);

    const level = cast.level();
    if (level > 0) return .{ .relative = level };
    return .resolved;
}

fn path_is(source: []const u8, segments: []const Span, path: []const u8) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(path.len > 0);

    var rest = path;

    assert(segments.len <= attribute_depth_max);

    for (segments, 0..) |span, index| {
        if (index > 0) {
            if (!std.mem.startsWith(u8, rest, ".")) return false;

            rest = rest[1..];
        }

        const text = span.text(source);
        if (!std.mem.startsWith(u8, rest, text)) return false;

        rest = rest[text.len..];
    }

    return rest.len == 0;
}

const Fixture = struct {
    events: Events,
    gpa: std.mem.Allocator,
    out: ArrayType(Span),
    parser: *Parser,
    raw: ArrayType(Kind),
    scratch: *AnnotationScratch,
    semantic: Semantic,
    source: []const u8,
    tables: Tables,
    tokens: Tokens,
    tree: Tree,

    fn init(fixture: *Fixture, gpa: std.mem.Allocator) !void {
        fixture.gpa = gpa;

        try fixture.events.init(gpa, fixture_event_count_max);
        errdefer fixture.events.deinit(gpa);

        fixture.out = try .init(gpa, attribute_depth_max + segment_count_max);
        errdefer fixture.out.deinit(gpa);

        fixture.parser = try gpa.create(Parser);
        errdefer gpa.destroy(fixture.parser);

        fixture.raw = try .init(gpa, fixture_token_count_max);
        errdefer fixture.raw.deinit(gpa);

        fixture.scratch = try gpa.create(AnnotationScratch);
        errdefer gpa.destroy(fixture.scratch);

        try fixture.scratch.init(gpa, &.{ .node_count_max = 1 << 8, .token_count_max = 1 << 8 });
        errdefer fixture.scratch.deinit(gpa);

        try fixture.semantic.init(gpa, &limits_fixture);
        errdefer fixture.semantic.deinit(gpa);

        try fixture.tables.init(gpa, &tables_fixture);
        errdefer fixture.tables.deinit(gpa);

        fixture.tokens = try .init(gpa, fixture_token_count_max);
        errdefer fixture.tokens.deinit(gpa);

        fixture.tree = try .init(gpa, fixture_token_count_max, fixture_error_count_max);
        fixture.source = "";

        assert(fixture.raw.capacity() == fixture.tokens.items.capacity());
        assert(fixture.semantic.count() == 0);
    }

    fn deinit(fixture: *Fixture) void {
        const gpa = fixture.gpa;

        assert(fixture.raw.capacity() == fixture_token_count_max);
        assert(fixture.tokens.items.capacity() == fixture_token_count_max);

        fixture.tree.deinit(gpa);
        fixture.tokens.deinit(gpa);
        fixture.tables.deinit(gpa);
        fixture.semantic.deinit(gpa);
        fixture.scratch.deinit(gpa);
        gpa.destroy(fixture.scratch);
        fixture.raw.deinit(gpa);
        gpa.destroy(fixture.parser);
        fixture.out.deinit(gpa);
        fixture.events.deinit(gpa);
        fixture.* = undefined;
    }

    fn outcome_of(fixture: *Fixture, source: []const u8) !Structure {
        assert(source.len > 0);
        assert(source.len < fixture_token_count_max);

        fixture.source = source;

        fixture.tokens.clear();

        try lex(source, &fixture.tokens);
        try raw_of(Kind, fixture.tokens.slice(), &fixture.raw);

        _ = fixture.parser.build(
            source,
            fixture.tokens.slice(),
            fixture.raw.const_slice(),
            &fixture.events,
            &fixture.tree,
        );

        return fixture.semantic.build(&.{
            .builtins = &builtins_fixture,
            .raw = fixture.raw.const_slice(),
            .source = source,
            .tokens = fixture.tokens.slice(),
            .tree = &fixture.tree,
            .version = .py310,
        }, fixture.scratch);
    }

    fn build(fixture: *Fixture, source: []const u8) !void {
        assert(source.len > 0);

        try std.testing.expectEqual(.complete, try fixture.outcome_of(source));

        assert(fixture.semantic.scope_slice().len > 0);
    }

    fn bind_tables(fixture: *Fixture) !void {
        assert(fixture.source.len > 0);
        assert(fixture.tree.count() > 0);

        try bind(
            fixture.source,
            fixture.tokens.slice(),
            fixture.raw.const_slice(),
            &fixture.tree,
            &fixture.tables,
        );
    }

    fn bindings_expect(fixture: *const Fixture, expected: []const []const u8) !void {
        assert(expected.len <= std.math.maxInt(u32));

        const bindings = fixture.semantic.binding_slice();
        var buffer: [row_bytes_max]u8 = undefined;

        assert(fixture.source.len > 0);
        assert(bindings.len <= limits_fixture.binding_count_max);

        if (bindings.len != expected.len) {
            for (bindings) |held| {
                const kind = binding_title(held.kind);
                const name = fixture.text_of(held.name);

                std.debug.print("{s} {s} scope {d}\n", .{ kind, name, held.scope });
            }
        }

        try std.testing.expectEqual(expected.len, bindings.len);

        for (bindings, expected) |held, row| {
            const actual = try std.mem.print(&buffer, "{s} {s} scope {d}", .{
                binding_title(held.kind),
                fixture.text_of(held.name),
                held.scope,
            });

            try std.testing.expectEqualStrings(row, actual);
        }
    }

    fn resolutions_expect(fixture: *const Fixture, expected: []const []const u8) !void {
        const references = fixture.semantic.reference_slice();
        var buffer: [row_bytes_max]u8 = undefined;
        var bound: [row_bytes_max]u8 = undefined;

        assert(fixture.source.len > 0);
        assert(references.len <= limits_fixture.reference_count_max);

        try std.testing.expectEqual(expected.len, references.len);

        for (references, expected) |held, row| {
            const actual = try std.mem.print(&buffer, "{s} {s} scope {d}", .{
                fixture.text_of(held.name),
                try resolution_title(&bound, held.resolution),
                held.scope,
            });

            try std.testing.expectEqualStrings(row, actual);
        }
    }

    fn facts_expect(fixture: *const Fixture, expected: []const []const u8) !void {
        const facts = fixture.semantic.fact_slice();
        var buffer: [row_bytes_max]u8 = undefined;

        assert(fixture.source.len > 0);
        assert(facts.len <= limits_fixture.fact_count_max);

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

    fn segments_expect(fixture: *const Fixture, expected: []const []const u8) !void {
        const segments = fixture.out.const_slice();

        assert(fixture.source.len > 0);
        assert(segments.len <= attribute_depth_max + segment_count_max);

        try std.testing.expectEqual(expected.len, segments.len);

        for (segments, expected) |span, row| {
            try std.testing.expectEqualStrings(row, fixture.text_of(span));
        }
    }

    fn field_of(fixture: *const Fixture, name: Span) []const u8 {
        assert(name.end() <= fixture.source.len);
        assert(fixture.source.len > 0);

        if (span_empty(name)) return ".";
        return fixture.text_of(name);
    }

    fn text_of(fixture: *const Fixture, name: Span) []const u8 {
        assert(name.end() <= fixture.source.len);
        assert(fixture.source.len > 0);

        return name.text(fixture.source);
    }

    fn name_node(fixture: *const Fixture, wanted: []const u8, ordinal: u32) ?u32 {
        var seen: u32 = 0;

        assert(wanted.len > 0);
        assert(fixture.tree.count() > 0);

        for (0..fixture.tree.count()) |position| {
            const node: u32 = @intCast(position);
            if (fixture.tree.kind_at(node) != .name_node) continue;

            const raw = fixture.raw.const_slice();
            const view = View.init(&fixture.tree, fixture.tokens.slice(), raw, node);
            if (!std.mem.eql(u8, view.text(fixture.source), wanted)) continue;

            if (seen == ordinal) {
                assert(node < std.math.maxInt(u32));

                return node;
            }

            seen += 1;
        }

        return null;
    }

    fn binding_named(fixture: *const Fixture, name: []const u8) ?Binding {
        assert(name.len > 0);
        assert(fixture.source.len > 0);

        for (fixture.semantic.binding_slice()) |held| {
            if (std.mem.eql(u8, fixture.text_of(held.name), name)) return held;
        }

        return null;
    }

    fn reference_named(fixture: *const Fixture, name: []const u8) ?Reference {
        assert(name.len > 0);
        assert(fixture.source.len > 0);

        for (fixture.semantic.reference_slice()) |held| {
            if (std.mem.eql(u8, fixture.text_of(held.name), name)) return held;
        }

        return null;
    }

    fn read_last(fixture: *const Fixture, name: []const u8) View {
        const root = View.init(&fixture.tree, fixture.tokens.slice(), fixture.raw.const_slice(), 0);
        var found: ?u32 = null;

        assert(name.len > 0);
        assert(root.kind() == .module);

        for (0..fixture.tree.count()) |index| {
            const node: u32 = @intCast(index);

            switch (fixture.tree.kind_at(node)) {
                .attribute, .name_node => {},
                else => continue,
            }

            if (std.mem.eql(u8, root.at(node).text(fixture.source), name)) found = node;
        }

        return root.at(found.?);
    }
};

const builtins_fixture = [_][]const u8{ "len", "list", "print", "str", "sum", "tuple" };
const evaluation_node_count_max: u32 = 1 << 8;
const fixture_error_count_max: u32 = 1 << 11;
const fixture_event_count_max: u32 = 1 << 18;
const fixture_token_count_max: u32 = 1 << 16;
const row_bytes_max = 256;

const limits_fixture: Semantic.Limits = .{
    .binding_count_max = 1 << 12,
    .fact_count_max = 1 << 8,
    .reference_count_max = 1 << 14,
    .scope_count_max = 1 << 10,
};

const tables_fixture: Tables.Limits = .{
    .binding_count_max = 1 << 12,
    .reference_count_max = 1 << 14,
    .scope_count_max = 1 << 10,
    .segment_count_max = 1 << 12,
};

fn binding_title(kind: BindingKind) []const u8 {
    @setEvalBranchQuota(1 << 14);

    const title: []const u8 = switch (kind) {
        inline else => |tag| comptime camel_of(@tagName(tag)),
    };

    assert(title.len > 0);
    assert(std.ascii.isUpper(title[0]));

    return title;
}

fn resolution_title(buffer: []u8, resolution: Resolution) ![]const u8 {
    assert(buffer.len > 0);
    assert(buffer.len <= row_bytes_max);
    if (resolution == .bound) assert(resolution.bound < std.math.maxInt(u32));

    return switch (resolution) {
        .bound => |index| try std.mem.print(buffer, "Bound({d})", .{index}),
        .builtin => "Builtin",
        .external => unreachable,
        .maybe => "Maybe",
        .unresolved => "Unresolved",
    };
}

fn fixture_expect(
    source: []const u8,
    bindings: []const []const u8,
    resolutions: []const []const u8,
) !void {
    assert(resolutions.len <= std.math.maxInt(u32));

    var fixture: Fixture = undefined;

    assert(source.len > 0);
    assert(bindings.len > 0);

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(source);
    try fixture.bindings_expect(bindings);
    try fixture.resolutions_expect(resolutions);
}

fn elif_chain(buffer: []u8, links: u32) []const u8 {
    const head = "if value:\n    held = 1\n";
    const link = "elif value:\n    held = 1\n";
    var length: usize = head.len;

    assert(buffer.len >= head.len + links * link.len);
    assert(links > 0);

    @memcpy(buffer[0..head.len], head);

    for (0..links) |_| {
        @memcpy(buffer[length..][0..link.len], link);
        length += link.len;
    }

    return buffer[0..length];
}

fn tally(iterator: anytype) u32 {
    var rest = iterator;
    var total: u32 = 0;

    for (0..fixture_token_count_max) |_| {
        if (rest.next() == null) break;

        total += 1;
    }

    return total;
}

const builtins_source =
    \\value = len([1, 2, 3])
    \\text = str(value)
    \\print(text)
    \\missing(value)
    \\
;

const class_scope_source =
    \\field = 1
    \\
    \\
    \\class Holder:
    \\    field = 2
    \\    other = field
    \\
    \\    def read(self):
    \\        return field
    \\
;

const comprehensions_source =
    \\items = [1, 2, 3]
    \\squares = [item * item for item in items]
    \\pairs = {key: key for key in items}
    \\total = sum(value for value in items)
    \\item
    \\
;

const conditional_source =
    \\import os
    \\
    \\if os.name == "nt":
    \\    handle = 1
    \\else:
    \\    handle = 2
    \\
    \\print(handle)
    \\
;

const deletion_source =
    \\value = 1
    \\del value
    \\print(value)
    \\
    \\
    \\def run():
    \\    held = 2
    \\    del held
    \\    return held
    \\
    \\
    \\def caught():
    \\    try:
    \\        pass
    \\    except ValueError as error:
    \\        print(error)
    \\
    \\    return error
    \\
;

const evaluation_source =
    \\x = a if (b := c) else d
    \\y = [e for f in g if h]
    \\z = {i: j for k in l}
    \\m: n = o
    \\p += q
    \\for r in s:
    \\    pass
    \\t = u = v
    \\w(x1, k=(y1 := y2), *[y1], **z1)
    \\
;

const exports_source =
    \\__all__ = ["first", "second"]
    \\__all__ += ["third"]
    \\
    \\
    \\def first():
    \\    pass
    \\
    \\
    \\def second():
    \\    pass
    \\
    \\
    \\def third():
    \\    pass
    \\
;

const facts_source =
    \\import os
    \\import os.path as held
    \\from collections import OrderedDict
    \\from collections import deque as queue
    \\from . import sibling
    \\from ..package.module import thing
    \\from json import *
    \\
    \\__all__ = ["os", "held", "thing"]
    \\
;

const globals_source =
    \\counter = 0
    \\
    \\
    \\def bump():
    \\    global counter
    \\    counter = counter + 1
    \\
    \\
    \\def read():
    \\    return counter
    \\
;

const nonlocal_source =
    \\def outer():
    \\    held = 1
    \\
    \\    def inner():
    \\        nonlocal held
    \\        held = 2
    \\
    \\    inner()
    \\
    \\    return held
    \\
    \\
    \\def bare():
    \\    def inner():
    \\        nonlocal missing
    \\        missing = 1
    \\
    \\    return inner
    \\
;

const parameters_source =
    \\def run(first, second=1, *rest, keyword=2, **extra):
    \\    return first, second, rest, keyword, extra
    \\
    \\
    \\lam = lambda left, right=1: left + right
    \\
;

const qualified_source =
    \\import os
    \\import os.path
    \\import numpy as np
    \\
    \\from collections import OrderedDict as OD
    \\from . import sibling
    \\from ..pkg import thing
    \\
    \\
    \\def local():
    \\    return 1
    \\
    \\
    \\print(os.path.join("a"))
    \\print(np.array([]))
    \\print(OD.fromkeys([]))
    \\print(sibling.value)
    \\print(thing.value)
    \\print(local.__doc__)
    \\print(len.__doc__)
    \\
;

const redefinition_source =
    \\import os
    \\import os
    \\
    \\value = 1
    \\value = 2
    \\
    \\
    \\def run():
    \\    pass
    \\
    \\
    \\def run():
    \\    pass
    \\
;

const shadowing_source =
    \\value = 1
    \\
    \\
    \\def outer():
    \\    value = 2
    \\
    \\    def inner():
    \\        return value
    \\
    \\    return inner
    \\
    \\
    \\def reader():
    \\    return value
    \\
;

const star_source =
    \\from os.path import *
    \\
    \\print(join("a", "b"))
    \\print(missing_name)
    \\
;

const string_annotations_source =
    \\from typing import TYPE_CHECKING
    \\
    \\if TYPE_CHECKING:
    \\    from collections import OrderedDict
    \\    from decimal import Decimal
    \\
    \\import json
    \\
    \\
    \\def read(held: "OrderedDict[str, int]") -> "json.JSONDecoder":
    \\    return held
    \\
    \\
    \\value: "Decimal" = 1
    \\
;

const type_params_source =
    \\type Alias[T] = list[T]
    \\
    \\
    \\def run[T](value: T) -> T:
    \\    return value
    \\
    \\
    \\class Holder[T]:
    \\    def read(self) -> T:
    \\        return self
    \\
;

const unused_source =
    \\import os
    \\import sys as system
    \\
    \\
    \\def run():
    \\    held = 1
    \\    other = 2
    \\
    \\    return other
    \\
;

const walrus_source =
    \\items = [1, 2, 3]
    \\found = [total for value in items if (total := value * 2) > 2]
    \\print(total)
    \\
    \\
    \\def run():
    \\    if (held := len(items)) > 0:
    \\        return held
    \\
    \\    return 0
    \\
;

const builtins_bindings = [_][]const u8{ "Assignment value scope 0", "Assignment text scope 0" };

const builtins_resolutions = [_][]const u8{
    "len Builtin scope 0",
    "str Builtin scope 0",
    "value Bound(0) scope 0",
    "print Builtin scope 0",
    "text Bound(1) scope 0",
    "missing Unresolved scope 0",
    "value Bound(0) scope 0",
};

const class_scope_bindings = [_][]const u8{
    "Assignment field scope 0",
    "ClassDefinition Holder scope 0",
    "Assignment field scope 1",
    "Assignment other scope 1",
    "FunctionDefinition read scope 1",
    "Parameter self scope 2",
};

const class_scope_resolutions = [_][]const u8{
    "field Bound(2) scope 1",
    "field Bound(0) scope 2",
};

const comprehensions_bindings = [_][]const u8{
    "Assignment items scope 0",
    "Assignment squares scope 0",
    "ComprehensionVariable item scope 1",
    "Assignment pairs scope 0",
    "ComprehensionVariable key scope 2",
    "Assignment total scope 0",
    "ComprehensionVariable value scope 3",
};

const comprehensions_resolutions = [_][]const u8{
    "item Bound(2) scope 1",
    "item Bound(2) scope 1",
    "items Bound(0) scope 0",
    "key Bound(4) scope 2",
    "key Bound(4) scope 2",
    "items Bound(0) scope 0",
    "sum Builtin scope 0",
    "value Bound(6) scope 3",
    "items Bound(0) scope 0",
    "item Unresolved scope 0",
};

const conditional_bindings = [_][]const u8{
    "Import os scope 0",
    "Assignment handle scope 0",
    "Assignment handle scope 0",
};

const conditional_resolutions = [_][]const u8{
    "os Bound(0) scope 0",
    "print Builtin scope 0",
    "handle Bound(2) scope 0",
};

const deletion_bindings = [_][]const u8{
    "Assignment value scope 0",
    "Deletion value scope 0",
    "FunctionDefinition run scope 0",
    "Assignment held scope 1",
    "Deletion held scope 1",
    "FunctionDefinition caught scope 0",
    "ExceptVariable error scope 2",
    "Deletion error scope 2",
};

const deletion_resolutions = [_][]const u8{
    "value Bound(0) scope 0",
    "print Builtin scope 0",
    "value Bound(1) scope 0",
    "held Bound(3) scope 1",
    "held Bound(4) scope 1",
    "ValueError Builtin scope 2",
    "print Builtin scope 2",
    "error Bound(6) scope 2",
    "error Bound(7) scope 2",
};

const evaluation_pairs = [_][2][]const u8{
    .{ "c", "b" },
    .{ "b", "a" },
    .{ "a", "d" },
    .{ "g", "f" },
    .{ "f", "h" },
    .{ "h", "e" },
    .{ "l", "k" },
    .{ "k", "i" },
    .{ "i", "j" },
    .{ "n", "o" },
    .{ "o", "m" },
    .{ "q", "p" },
    .{ "s", "r" },
    .{ "v", "t" },
    .{ "t", "u" },
    .{ "x1", "y2" },
    .{ "y2", "z1" },
};

const exports_bindings = [_][]const u8{
    "Assignment __all__ scope 0",
    "Augmented __all__ scope 0",
    "FunctionDefinition first scope 0",
    "FunctionDefinition second scope 0",
    "FunctionDefinition third scope 0",
};

const facts_bindings = [_][]const u8{
    "Import os scope 0",
    "Import held scope 0",
    "ImportFrom OrderedDict scope 0",
    "ImportFrom queue scope 0",
    "ImportFrom sibling scope 0",
    "ImportFrom thing scope 0",
    "ImportStar * scope 0",
    "Assignment __all__ scope 0",
};

const facts_facts = [_][]const u8{
    "ImportNamed os os os",
    "ImportNamed held os.path os.path",
    "ImportNamed OrderedDict OrderedDict collections",
    "ImportNamed queue deque collections",
    "ImportNamed sibling sibling .",
    "ImportNamed thing thing ..package.module",
    "ImportNamespace . . json",
    "ExportNamed os os .",
    "ExportNamed held held .",
    "ExportNamed thing thing .",
};

const globals_bindings = [_][]const u8{
    "Assignment counter scope 0",
    "FunctionDefinition bump scope 0",
    "Global counter scope 1",
    "Assignment counter scope 0",
    "FunctionDefinition read scope 0",
};

const globals_resolutions = [_][]const u8{
    "counter Bound(3) scope 1",
    "counter Bound(3) scope 2",
};

const nonlocal_bindings = [_][]const u8{
    "FunctionDefinition outer scope 0",
    "Assignment held scope 1",
    "FunctionDefinition inner scope 1",
    "Nonlocal held scope 2",
    "Assignment held scope 1",
    "FunctionDefinition bare scope 0",
    "FunctionDefinition inner scope 3",
    "Nonlocal missing scope 4",
    "Assignment missing scope 4",
};

const nonlocal_resolutions = [_][]const u8{
    "inner Bound(2) scope 1",
    "held Bound(4) scope 1",
    "inner Bound(6) scope 3",
};

const parameters_bindings = [_][]const u8{
    "FunctionDefinition run scope 0",
    "Parameter first scope 1",
    "Parameter second scope 1",
    "Parameter rest scope 1",
    "Parameter keyword scope 1",
    "Parameter extra scope 1",
    "Assignment lam scope 0",
    "Parameter left scope 2",
    "Parameter right scope 2",
};

const parameters_resolutions = [_][]const u8{
    "first Bound(1) scope 1",
    "second Bound(2) scope 1",
    "rest Bound(3) scope 1",
    "keyword Bound(4) scope 1",
    "extra Bound(5) scope 1",
    "left Bound(7) scope 2",
    "right Bound(8) scope 2",
};

const redefinition_bindings = [_][]const u8{
    "Import os scope 0",
    "Import os scope 0",
    "Assignment value scope 0",
    "Assignment value scope 0",
    "FunctionDefinition run scope 0",
    "FunctionDefinition run scope 0",
};

const shadowing_bindings = [_][]const u8{
    "Assignment value scope 0",
    "FunctionDefinition outer scope 0",
    "Assignment value scope 1",
    "FunctionDefinition inner scope 1",
    "FunctionDefinition reader scope 0",
};

const shadowing_resolutions = [_][]const u8{
    "value Bound(2) scope 2",
    "inner Bound(3) scope 1",
    "value Bound(0) scope 3",
};

const star_bindings = [_][]const u8{"ImportStar * scope 0"};

const star_resolutions = [_][]const u8{
    "print Builtin scope 0",
    "join Maybe scope 0",
    "print Builtin scope 0",
    "missing_name Maybe scope 0",
};

const type_params_bindings = [_][]const u8{
    "TypeAlias Alias scope 0",
    "TypeParameter T scope 1",
    "FunctionDefinition run scope 0",
    "TypeParameter T scope 3",
    "Parameter value scope 4",
    "ClassDefinition Holder scope 0",
    "TypeParameter T scope 5",
    "FunctionDefinition read scope 6",
    "Parameter self scope 7",
};

const type_params_resolutions = [_][]const u8{
    "list Builtin scope 2",
    "T Bound(1) scope 2",
    "T Bound(3) scope 3",
    "T Bound(3) scope 3",
    "value Bound(4) scope 4",
    "T Bound(6) scope 6",
    "self Bound(8) scope 7",
};

const unused_bindings = [_][]const u8{
    "Import os scope 0",
    "Import system scope 0",
    "FunctionDefinition run scope 0",
    "Assignment held scope 1",
    "Assignment other scope 1",
};

const unused_resolutions = [_][]const u8{"other Bound(4) scope 1"};

const walrus_bindings = [_][]const u8{
    "Assignment items scope 0",
    "Assignment found scope 0",
    "ComprehensionVariable value scope 1",
    "Named total scope 0",
    "FunctionDefinition run scope 0",
    "Named held scope 2",
};

const walrus_resolutions = [_][]const u8{
    "total Bound(3) scope 1",
    "items Bound(0) scope 0",
    "value Bound(2) scope 1",
    "print Builtin scope 0",
    "total Bound(3) scope 0",
    "len Builtin scope 2",
    "items Bound(0) scope 2",
    "held Bound(5) scope 2",
};

test "a load without a binding is unresolved or a builtin" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(builtins_source);
    try fixture.bindings_expect(&builtins_bindings);
    try fixture.resolutions_expect(&builtins_resolutions);
    try std.testing.expect(!fixture.semantic.scope_at(0).dynamic);
}

test "a class scope is invisible to a function inside it" {
    try fixture_expect(class_scope_source, &class_scope_bindings, &class_scope_resolutions);
}

test "a comprehension keeps its iteration variable" {
    try fixture_expect(
        comprehensions_source,
        &comprehensions_bindings,
        &comprehensions_resolutions,
    );
}

test "a conditional binding reads as the last one" {
    try fixture_expect(conditional_source, &conditional_bindings, &conditional_resolutions);
}

test "a deletion binds and a handler name is gone below the block that caught it" {
    try fixture_expect(deletion_source, &deletion_bindings, &deletion_resolutions);
}

test "an all assignment records its exports" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(exports_source);
    try fixture.bindings_expect(&exports_bindings);
    try fixture.resolutions_expect(&.{"__all__ Bound(0) scope 0"});

    const exports = export_slice(&fixture.semantic);

    try std.testing.expectEqual(3, exports.len);
    try std.testing.expectEqualStrings("first", fixture.text_of(exports[0]));
    try std.testing.expectEqualStrings("second", fixture.text_of(exports[1]));
    try std.testing.expectEqualStrings("third", fixture.text_of(exports[2]));
}

test "the module facts name every import form and every export" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(facts_source);
    try fixture.bindings_expect(&facts_bindings);
    try fixture.resolutions_expect(&.{});
    try fixture.facts_expect(&facts_facts);
}

test "a global declaration redirects to the module scope" {
    try fixture_expect(globals_source, &globals_bindings, &globals_resolutions);
}

test "a nonlocal declaration redirects to the enclosing function" {
    try fixture_expect(nonlocal_source, &nonlocal_bindings, &nonlocal_resolutions);
}

test "a parameter binds in the scope it opens" {
    try fixture_expect(parameters_source, &parameters_bindings, &parameters_resolutions);
}

test "a redefinition chains to the binding it shadows" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(redefinition_source);
    try fixture.bindings_expect(&redefinition_bindings);
    try fixture.resolutions_expect(&.{});

    const expected = [_]u32{ none, 0, none, 2, none, 4 };

    for (fixture.semantic.binding_slice(), expected) |held, shadowed| {
        try std.testing.expectEqual(shadowed, held.name_previous);
    }
}

test "a load walks local then enclosing then module then builtins" {
    try fixture_expect(shadowing_source, &shadowing_bindings, &shadowing_resolutions);
}

test "a star import degrades a failed load to maybe" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(star_source);
    try fixture.bindings_expect(&star_bindings);
    try fixture.resolutions_expect(&star_resolutions);
    try std.testing.expect(fixture.semantic.scope_at(0).dynamic);
}

test "a type parameter binds beside its definition" {
    try fixture_expect(type_params_source, &type_params_bindings, &type_params_resolutions);
}

test "an import binds its alias and a load reads it" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(unused_source);
    try fixture.bindings_expect(&unused_bindings);
    try fixture.resolutions_expect(&unused_resolutions);
    try std.testing.expectEqual(0, tally(fixture.semantic.references_of(0)));
    try std.testing.expectEqual(1, tally(fixture.semantic.references_of(4)));
    try std.testing.expectEqual(2, tally(fixture.semantic.bindings_of(1)));
}

test "the evaluation order permutes the tree the way ruff visits it" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(evaluation_source);

    const input: SemanticInput = .{
        .builtins = &builtins_fixture,
        .raw = fixture.raw.const_slice(),
        .source = evaluation_source,
        .tokens = fixture.tokens.slice(),
        .tree = &fixture.tree,
        .version = .py310,
    };

    var builder: Builder = .init(&fixture.semantic, &input, fixture.scratch);
    var seen: [evaluation_node_count_max]bool = @splat(false);
    const count = fixture.tree.count();
    const call = fixture.tree.parent_of(fixture.name_node("w", 0).?).?;

    try std.testing.expect(count <= evaluation_node_count_max);

    builder.call_enter(call);

    for (0..count) |node| {
        const order = builder.order_of(@intCast(node));

        try std.testing.expect(!seen[order]);

        seen[order] = true;
    }

    for (evaluation_pairs) |pair| {
        const before = builder.order_of(fixture.name_node(pair[0], 0).?);
        const after = builder.order_of(fixture.name_node(pair[1], 0).?);

        try std.testing.expect(before < after);
    }

    const target = builder.order_of(fixture.name_node("y1", 0).?);
    const spread = builder.order_of(fixture.name_node("y1", 1).?);

    try std.testing.expect(spread < target);
}

test "a walrus inside a comprehension binds in the containing scope" {
    try fixture_expect(walrus_source, &walrus_bindings, &walrus_resolutions);
}

test "an except name binds the handler variable" {
    try fixture_expect(
        "try:\n    pass\nexcept ValueError as error:\n    print(error)\n",
        &.{ "ExceptVariable error scope 0", "Deletion error scope 0" },
        &.{
            "ValueError Builtin scope 0",
            "print Builtin scope 0",
            "error Bound(0) scope 0",
        },
    );
}

test "every python specifier slices back to the text the source wrote" {
    var fixture: Fixture = undefined;
    var compared: u32 = 0;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(facts_source);

    for (fixture.semantic.fact_slice()) |fact| {
        if (span_empty(fact.specifier)) continue;

        const held = fixture.text_of(fact.specifier);

        try std.testing.expectEqualStrings(fact.specifier.text(fixture.source), held);
        try std.testing.expect(held.len > 0);

        compared += 1;
    }

    try std.testing.expect(compared > 5);
}

test "a future import reads as its own kind" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build("from __future__ import annotations\n");
    try fixture.bindings_expect(&.{"FutureImport annotations scope 0"});
}

test "a binding in an if body and one after it sit on different branches" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build("if value:\n    left = 1\nright = 2\n");

    const bindings = fixture.semantic.binding_slice();

    try std.testing.expectEqual(2, bindings.len);
    try std.testing.expect(bindings[0].ext.branch != bindings[1].ext.branch);

    try std.testing.expect(!same_branch(
        &fixture.semantic,
        bindings[0].ext.branch,
        bindings[1].ext.branch,
    ));

    try std.testing.expect(branch_within(&fixture.semantic, bindings[0].ext.branch, 0));
}

test "a loop body opens no branch of its own" {
    var fixture: Fixture = undefined;
    var branches: [2]u32 = undefined;
    var found: u32 = 0;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build("for item in value:\n    left = 1\nright = 2\n");

    for (fixture.semantic.binding_slice()) |held| {
        if (held.kind == .loop_variable) continue;

        branches[found] = held.ext.branch;
        found += 1;
    }

    try std.testing.expectEqual(2, found);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0 }, &branches);
}

test "the else of a try shares the arm its body stands on" {
    var fixture: Fixture = undefined;
    const source = "try:\n    left = 1\nexcept Exception:\n    pass\nelse:\n    right = 2\n";

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(source);

    const bindings = fixture.semantic.binding_slice();

    try std.testing.expectEqual(2, bindings.len);

    try std.testing.expect(same_branch(
        &fixture.semantic,
        bindings[0].ext.branch,
        bindings[1].ext.branch,
    ));
}

test "an elif body is its own branch" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build("if value:\n    held = 1\nelif other:\n    held = 2\n");

    const bindings = fixture.semantic.binding_slice();

    try std.testing.expectEqual(2, bindings.len);

    try std.testing.expect(!same_branch(
        &fixture.semantic,
        bindings[0].ext.branch,
        bindings[1].ext.branch,
    ));
}

test "two bindings in one block share a branch" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build("if value:\n    left = 1\n    right = 2\n");

    const bindings = fixture.semantic.binding_slice();

    try std.testing.expectEqual(2, bindings.len);
    try std.testing.expectEqual(bindings[0].ext.branch, bindings[1].ext.branch);

    try std.testing.expect(same_branch(
        &fixture.semantic,
        bindings[0].ext.branch,
        bindings[1].ext.branch,
    ));
}

test "a branch within its own ancestor reads true" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build("if value:\n    if other:\n        held = 1\nlast = 2\n");

    const bindings = fixture.semantic.binding_slice();

    try std.testing.expectEqual(2, bindings.len);

    const inner = bindings[0].ext.branch;

    try std.testing.expect(branch_within(&fixture.semantic, inner, 0));
    try std.testing.expect(branch_within(&fixture.semantic, inner, inner));
    try std.testing.expect(!branch_within(&fixture.semantic, 0, inner));
    try std.testing.expectEqual(0, bindings[1].ext.branch);
}

test "an import as itself is an alias" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build("import os as os\nfrom held import name as name\nimport io as f\n");

    const bindings = fixture.semantic.binding_slice();

    try std.testing.expectEqual(3, bindings.len);
    try std.testing.expect(bindings[0].ext.flags.alias);
    try std.testing.expect(bindings[1].ext.flags.alias);
    try std.testing.expect(!bindings[2].ext.flags.alias);
}

test "a dotted import renamed to its last segment is not an alias" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build("import os.path as path\n");

    const bindings = fixture.semantic.binding_slice();

    try std.testing.expectEqual(1, bindings.len);
    try std.testing.expect(!bindings[0].ext.flags.alias);
}

test "a tuple target is unpacked" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build("left, right = 1, 2\nheld = 3\n");

    const bindings = fixture.semantic.binding_slice();

    try std.testing.expectEqual(3, bindings.len);
    try std.testing.expect(bindings[0].ext.flags.unpacked);
    try std.testing.expect(bindings[1].ext.flags.unpacked);
    try std.testing.expect(!bindings[2].ext.flags.unpacked);
}

test "an overload decorator flags the definition" {
    var fixture: Fixture = undefined;
    var decorated: [2]bool = undefined;
    var found: u32 = 0;

    const source = "from typing import overload\n\n\n" ++
        "@overload\ndef read(value): ...\n" ++
        "def read(value): ...\n";

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(source);

    for (fixture.semantic.binding_slice()) |held| {
        if (held.kind != .function_definition) continue;

        decorated[found] = held.ext.flags.overload;
        found += 1;
    }

    try std.testing.expectEqual(2, found);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, &decorated);
}

test "a deletion flags the binding it removes" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build("held = 1\ndel held\n");

    const bindings = fixture.semantic.binding_slice();

    try std.testing.expectEqual(2, bindings.len);
    try std.testing.expect(bindings[0].ext.flags.deleted);
    try std.testing.expect(!bindings[0].ext.flags.shadowed);
}

test "a redefinition flags the binding it shadows" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build("held = 1\nheld = 2\n");

    const bindings = fixture.semantic.binding_slice();

    try std.testing.expectEqual(2, bindings.len);
    try std.testing.expect(bindings[0].ext.flags.shadowed);
    try std.testing.expect(!bindings[1].ext.flags.shadowed);
}

test "a name in dunder all is an explicit export" {
    var fixture: Fixture = undefined;
    var exported: [2]bool = undefined;
    var found: u32 = 0;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build("__all__ = [\"read\"]\n\n\ndef read(): ...\ndef write(): ...\n");

    for (fixture.semantic.binding_slice()) |held| {
        if (held.kind != .function_definition) continue;

        exported[found] = held.ext.flags.export_explicit;
        found += 1;
    }

    try std.testing.expectEqual(2, found);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, &exported);
}

test "a type checking block flags its bindings and references" {
    var fixture: Fixture = undefined;
    var guarded: u32 = 0;

    const source = "from typing import TYPE_CHECKING\n\n" ++
        "if TYPE_CHECKING:\n    import os\n\n    held = os\n";

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(source);

    for (fixture.semantic.binding_slice()) |held| {
        if (held.ext.flags.type_checking) guarded += 1;
    }

    try std.testing.expectEqual(2, guarded);

    const read = fixture.reference_named("os").?;

    try std.testing.expect(read.ext.flags.type_checking);
    try std.testing.expect(read.ext.flags.typing_only);
}

test "a future annotations import makes annotations typing only" {
    var fixture: Fixture = undefined;

    const source = "from __future__ import annotations\n\nimport os\n\n\n" ++
        "def read(value: os): ...\n";

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(source);

    const annotated = fixture.reference_named("os").?;

    try std.testing.expect(annotated.ext.flags.annotation);
    try std.testing.expect(annotated.ext.flags.typing_only);
    try std.testing.expect(!annotated.ext.flags.type_checking);
}

test "a future annotations import under an alias still defers annotations" {
    var fixture: Fixture = undefined;

    const source = "from __future__ import annotations as _annotations\n\n\n" ++
        "class Table:\n" ++
        "    def sorted(self) -> Table: ...\n";

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(source);

    const annotated = fixture.reference_named("Table").?;

    try std.testing.expect(annotated.ext.flags.annotation);
    try std.testing.expect(annotated.ext.flags.deferred);
    try std.testing.expect(annotated.ext.flags.typing_only);
}

test "a reference counts toward its binding" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build("held = 1\nprint(held)\nprint(held)\n");

    try std.testing.expectEqual(2, fixture.semantic.binding_slice()[0].reference_count);
    try std.testing.expect(is_used(&fixture.semantic, 0));
    try std.testing.expect(chain_used(&fixture.semantic, fixture.source, 0));
}

test "the branch stack overflow reads too deep" {
    var fixture: Fixture = undefined;
    var buffer: [1 << 13]u8 = undefined;
    const links = branch_depth_max;
    const source = elif_chain(&buffer, links);

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try std.testing.expect(links * 2 > branch_depth_max);
    try std.testing.expectEqual(.too_deep, try fixture.outcome_of(source));
}

test "an elif chain inside the branch bound builds" {
    var fixture: Fixture = undefined;
    var buffer: [1 << 13]u8 = undefined;
    const links = branch_depth_max / 4;
    const source = elif_chain(&buffer, links);

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try std.testing.expect(links * 2 + 1 < branch_depth_max);
    try std.testing.expectEqual(.complete, try fixture.outcome_of(source));
}

test "a string in a typing cast reads the import it names" {
    var fixture: Fixture = undefined;

    const source = "from typing import cast\n" ++
        "from decimal import Decimal\n\n" ++
        "print(cast(\"Decimal\", value))\n";

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(source);
    try std.testing.expectEqual(1, fixture.binding_named("Decimal").?.reference_count);
}

test "a string in a dotted cast reads the import it names" {
    var fixture: Fixture = undefined;

    const source = "import typing\n" ++
        "from decimal import Decimal\n\n" ++
        "print(typing.cast(\"Decimal\", value))\n";

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(source);
    try std.testing.expectEqual(1, fixture.binding_named("Decimal").?.reference_count);
}

test "a string in a type alias value reads the import it names" {
    var fixture: Fixture = undefined;

    const source = "from typing import Any, Callable, TypeAlias\n" ++
        "from decimal import Decimal\n\n" ++
        "Hook: TypeAlias = Callable[[\"Decimal\"], Any]\n";

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(source);
    try std.testing.expectEqual(1, fixture.binding_named("Decimal").?.reference_count);
}

test "a cast that names something else leaves its string alone" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build("from decimal import cast\n\nprint(cast(\"Decimal\", value))\n");
    try std.testing.expect(fixture.reference_named("Decimal") == null);
}

test "a string annotation reads a name bound after it" {
    var fixture: Fixture = undefined;
    const source = "def read(held: \"Decimal\"): ...\n\n\nfrom decimal import Decimal\n";

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(source);
    try std.testing.expectEqual(1, fixture.binding_named("Decimal").?.reference_count);
}

test "a plain annotation reads no name bound after it" {
    var fixture: Fixture = undefined;
    const source = "def read(held: Decimal): ...\n\n\nfrom decimal import Decimal\n";

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(source);
    try std.testing.expectEqual(0, fixture.binding_named("Decimal").?.reference_count);
}

test "a qualified name reads an import through its attribute chain" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(qualified_source);

    const held = fixture.read_last("os.path.join");
    const outcome = qualified_name_of(&fixture.semantic, fixture.source, held, &fixture.out);

    try std.testing.expectEqual(Qualified.resolved, outcome);
    try fixture.segments_expect(&.{ "os", "path", "join" });
}

test "a qualified name reads through an import alias" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(qualified_source);

    const held = fixture.read_last("np.array");
    const outcome = qualified_name_of(&fixture.semantic, fixture.source, held, &fixture.out);

    try std.testing.expectEqual(Qualified.resolved, outcome);
    try fixture.segments_expect(&.{ "numpy", "array" });
}

test "a qualified name reads a from import as its module and its remote name" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(qualified_source);

    const held = fixture.read_last("OD.fromkeys");
    const outcome = qualified_name_of(&fixture.semantic, fixture.source, held, &fixture.out);

    try std.testing.expectEqual(Qualified.resolved, outcome);
    try fixture.segments_expect(&.{ "collections", "OrderedDict", "fromkeys" });
}

test "a relative import reads its level and keeps its segments" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(qualified_source);

    const held = fixture.read_last("sibling.value");
    const outcome = qualified_name_of(&fixture.semantic, fixture.source, held, &fixture.out);

    try std.testing.expectEqual(Qualified{ .relative = 1 }, outcome);
    try fixture.segments_expect(&.{ "sibling", "value" });

    const deeper = fixture.read_last("thing.value");
    const nested = qualified_name_of(&fixture.semantic, fixture.source, deeper, &fixture.out);

    try std.testing.expectEqual(Qualified{ .relative = 2 }, nested);
    try fixture.segments_expect(&.{ "pkg", "thing", "value" });
}

test "a local definition and a builtin read apart from an import" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(qualified_source);

    const held = fixture.read_last("local.__doc__");
    const outcome = qualified_name_of(&fixture.semantic, fixture.source, held, &fixture.out);

    try std.testing.expect(outcome == .local);
    try fixture.segments_expect(&.{ "local", "__doc__" });

    const builtin = fixture.read_last("len.__doc__");
    const read = qualified_name_of(&fixture.semantic, fixture.source, builtin, &fixture.out);

    try std.testing.expectEqual(Qualified.builtin, read);
    try fixture.segments_expect(&.{ "len", "__doc__" });
}

test "a match reads a module member and accepts the forward port" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build("from typing import TYPE_CHECKING\n\nprint(TYPE_CHECKING)\n");

    const held = fixture.read_last("TYPE_CHECKING");
    const semantic = &fixture.semantic;
    const out = &fixture.out;

    try std.testing.expect(matches(semantic, fixture.source, held, "typing", "TYPE_CHECKING", out));
    try std.testing.expect(!matches(semantic, fixture.source, held, "os", "TYPE_CHECKING", out));

    try fixture.build("from typing_extensions import Self\n\nprint(Self)\n");

    const read = fixture.read_last("Self");

    try std.testing.expect(matches(semantic, fixture.source, read, "typing", "Self", out));
}

test "a python binding kind maps onto the shared class" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build("import os.path\nprint([held for held in os.path])\ndel os\n");

    const semantic = &fixture.semantic;
    const imported = semantic.at(0);
    const scope = semantic.scope_count() - 1;
    var deleted: ?u32 = null;

    for (semantic.reference_slice(), 0..) |held, index| {
        if (held.context == .delete) deleted = @intCast(index);
    }

    try std.testing.expectEqual(.submodule_import, imported.kind);
    try std.testing.expectEqual(BindingClass.import, semantic.row(0).class);
    try std.testing.expectEqual(imported.node, semantic.row(0).node);
    try std.testing.expectEqual(BindingClass.other, Rules.class_of(.deletion));
    try std.testing.expectEqual(.comprehension, semantic.scope_at(scope).kind);
    try std.testing.expectEqual(ScopeClass.block, semantic.scope_row(scope).class);
    try std.testing.expectEqual(0, semantic.scope_row(scope).parent.?);
    try std.testing.expectEqual(null, semantic.scope_row(0).parent);
    try std.testing.expect(semantic.reference_row(deleted.?).is_store);
    try std.testing.expect(semantic.reference_row(deleted.?).resolution == .bound);
}

test "a lambda in a default reads beside the function and not inside it" {
    try fixture_expect(
        "value = 1\n\n\ndef run(read=lambda: value):\n    value = 2\n    return read\n",
        &.{
            "Assignment value scope 0",
            "FunctionDefinition run scope 0",
            "Parameter read scope 1",
            "Assignment value scope 1",
        },
        &.{
            "value Bound(0) scope 2",
            "read Bound(2) scope 1",
        },
    );
}

test "a scope in a header or a first iterable opens in the enclosing scope" {
    var fixture: Fixture = undefined;

    const source =
        \\def run(read=lambda: 1):
        \\    return [cell for cell in (item for item in read)]
        \\
    ;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(source);

    const semantic = &fixture.semantic;

    try std.testing.expectEqual(5, semantic.scope_count());
    try std.testing.expectEqual(.lambda, semantic.scope_at(2).kind);
    try std.testing.expectEqual(0, semantic.scope_at(2).parent);
    try std.testing.expectEqual(.comprehension, semantic.scope_at(4).kind);
    try std.testing.expectEqual(1, semantic.scope_at(4).parent);
}

test "a walrus in a default binds beside the function" {
    try fixture_expect(
        "def run(held=(marker := object())):\n    return held is marker\n",
        &.{
            "FunctionDefinition run scope 0",
            "Parameter held scope 1",
            "Named marker scope 0",
        },
        &.{
            "object Builtin scope 0",
            "held Bound(1) scope 1",
            "marker Bound(2) scope 1",
        },
    );
}

test "a reference reads back from the node that made it" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build("held = 1\nprint(held)\n");

    const read = fixture.read_last("held");
    const index = reference_of(&fixture.semantic, read.index()).?;

    try std.testing.expectEqual(read.index(), fixture.semantic.reference_slice()[index].node);
    try std.testing.expectEqual(null, reference_of(&fixture.semantic, read.index() + 1_000));
}

test "a name in a string annotation reads the import it names" {
    var fixture: Fixture = undefined;
    var unused: u32 = 0;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(string_annotations_source);

    for (fixture.semantic.binding_slice()) |held| {
        if (!held.kind.imports()) continue;

        if (held.reference_count == 0) unused += 1;
    }

    try std.testing.expect(fixture.semantic.binding_slice().len > 4);
    try std.testing.expectEqual(0, unused);
}

test "a reference a string annotation made is typing only" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build("import json\n\n\ndef read(held: \"json.JSONDecoder\"): ...\n");

    const held = fixture.reference_named("json").?;

    try std.testing.expect(held.ext.flags.annotation);
    try std.testing.expect(held.ext.flags.typing_only);
    try std.testing.expect(held.resolution == .bound);
}

test "a string annotation a re lex cannot place back is left opaque" {
    var fixture: Fixture = undefined;
    const head = "import json\n\n\n";

    const sources = [_][]const u8{
        head ++ "def read(held: \"json.\\nJSONDecoder\"): ...\n",
        head ++ "def read(held: b\"json\"): ...\n",
        head ++ "def read(held: \"js\" \"on\"): ...\n",
    };

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    for (sources) |source| {
        try fixture.build(source);
        try std.testing.expect(!is_used(&fixture.semantic, 0));
    }
}

test "a string inside a literal subscript is a value and not a type" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build("import typing\n\n\ndef read(held: typing.Literal[\"adhoc\"]): ...\n");
    try std.testing.expect(fixture.reference_named("adhoc") == null);
}

test "a type parameter is read by the annotations of the definition that declares it" {
    var fixture: Fixture = undefined;
    var reads: u32 = 0;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build("def read[T](value: T) -> T:\n    return value\n");

    for (fixture.semantic.reference_slice()) |held| {
        if (!std.mem.eql(u8, fixture.text_of(held.name), "T")) continue;

        try std.testing.expectEqual(Resolution{ .bound = 1 }, held.resolution);

        reads += 1;
    }

    try std.testing.expectEqual(2, reads);
    try std.testing.expectEqual(.type_parameter, fixture.semantic.binding_slice()[1].kind);
}

test "a class base reads the type parameter the class declares" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build("class Holder[T](Base[T]):\n    pass\n");

    const read = fixture.reference_named("T").?;

    try std.testing.expectEqual(Resolution{ .bound = 1 }, read.resolution);
    try std.testing.expectEqual(.type_parameter, fixture.semantic.binding_slice()[1].kind);
}

test "a type alias leaves its parameter unbound in the scope that follows it" {
    var fixture: Fixture = undefined;
    var outside: [2]Resolution = undefined;
    var found: u32 = 0;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build("type Alias[T] = list[T]\n\nprint(T)\n");

    for (fixture.semantic.reference_slice()) |held| {
        if (!std.mem.eql(u8, fixture.text_of(held.name), "T")) continue;

        outside[found] = held.resolution;
        found += 1;
    }

    try std.testing.expectEqual(2, found);
    try std.testing.expectEqual(Resolution{ .bound = 1 }, outside[0]);
    try std.testing.expectEqual(Resolution.unresolved, outside[1]);
}

test "a binding kind reports whether it binds" {
    try std.testing.expect(BindingKind.assignment.binds());
    try std.testing.expect(!BindingKind.annotation.binds());
    try std.testing.expect(!BindingKind.deletion.binds());
    try std.testing.expect(!BindingKind.global.binds());
    try std.testing.expect(!BindingKind.nonlocal.binds());
    try std.testing.expect(BindingKind.import.imports());
    try std.testing.expect(BindingKind.import_star.imports());
    try std.testing.expect(!BindingKind.assignment.imports());
}

test "a model runs on a frozen thread" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var fixture: Fixture = undefined;
    const source = "import os\n\n\ndef run(value):\n    return os.path.join(value)\n";

    try fixture.init(static_allocator.allocator());

    static_allocator.transition_from_init_to_static();

    const outcome = fixture.outcome_of(source);
    const binding_count = fixture.semantic.count();

    static_allocator.transition_from_static_to_deinit();
    fixture.deinit();

    try std.testing.expectEqual(.complete, try outcome);
    try std.testing.expectEqual(3, binding_count);
}

test "a bound import keeps its alias, its level and its dotted segments" {
    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build("import os.path\nfrom ..pkg import thing as other\n");
    try fixture.bind_tables();

    const imports = fixture.tables.imports.const_slice();
    const segments = fixture.tables.segments.const_slice();

    try std.testing.expectEqual(2, imports.len);
    try std.testing.expectEqualStrings("os", fixture.text_of(imports[0].alias));
    try std.testing.expectEqual(0, imports[0].level);
    try std.testing.expectEqual(2, imports[0].segment_count);
    try std.testing.expectEqualStrings("path", fixture.text_of(segments[1]));
    try std.testing.expectEqualStrings("other", fixture.text_of(imports[1].alias));
    try std.testing.expectEqual(2, imports[1].level);
    try std.testing.expectEqual(1, imports[1].segment_count);
    try std.testing.expectEqualStrings("thing", fixture.text_of(segments[2]));
}

test "a bind table that fills reports rather than grows" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    var tables: Tables = undefined;

    try fixture.init(gpa);
    defer fixture.deinit();

    try fixture.build("def run():\n    pass\n");

    try tables.init(gpa, &.{
        .binding_count_max = 4,
        .reference_count_max = 4,
        .scope_count_max = 1,
        .segment_count_max = 4,
    });

    defer tables.deinit(gpa);

    const bound = bind(
        fixture.source,
        fixture.tokens.slice(),
        fixture.raw.const_slice(),
        &fixture.tree,
        &tables,
    );

    try std.testing.expectError(error.ScopesFull, bound);
    try std.testing.expectEqual(1, tables.scopes.count());
}
