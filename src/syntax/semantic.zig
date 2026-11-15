const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Fact = @import("fact.zig").Fact;
const Facts = @import("fact.zig").Facts;
const Span = @import("../stdx/bounded/span.zig");
const name_hash = std.hash.Fnv1a_32.hash;

pub const BindingClass = enum {
    constant,
    field,
    function,
    import,
    local,
    method,
    other,
    parameter,
    type,
    variant,
};

pub const Context = enum {
    delete,
    load,
    store,
};

pub const Limits = struct {
    binding_count_max: u32,
    fact_count_max: u32,
    reference_count_max: u32,
    scope_count_max: u32,
};

pub const Order = enum {
    from,
    from_or_self,
    unordered,
};

pub const Pick = enum {
    newest,
    oldest,
};

pub const Position = struct {
    crossed_function: bool,
    from_type: bool = false,
    redirected: bool,
    start: bool,
};

pub const Resolution = union(enum) {
    bound: u32,
    builtin,
    external,
    maybe,
    unresolved,
};

pub const ReferenceRow = struct {
    is_store: bool,
    name: Span,
    node: u32,
    resolution: Resolution,
    scope: u32,
};

pub const Row = struct {
    class: BindingClass,
    name: Span,
    node: u32,
    scope: u32,
};

pub const ScopeClass = enum {
    block,
    function,
    module,
    other,
    type,
};

pub const ScopeRow = struct {
    class: ScopeClass,
    node: u32,
    parent: ?u32,
};

fn DeclarationType(comptime Rules: type) type {
    return struct {
        dead_zone_end: u32,
        ext: Rules.BindingExtension,
        from: u32,
        kind: Rules.BindingKind,
        name: Span,
        node: u32,
    };
}

pub fn SemanticType(comptime Rules: type) type {
    comptime rules_check(Rules);

    return struct {
        bindings: ArrayType(Binding),
        ext: Rules.Extension,
        facts: Facts,
        heads: ArrayType(u32),
        reference_first: ArrayType(u32),
        reference_next: ArrayType(u32),
        references: ArrayType(Reference),
        references_sorted: bool,
        scopes: ArrayType(Scope),

        const Semantic = @This();
        pub const Declaration = DeclarationType(Rules);
        pub const Limits = SemanticLimits;
        pub const build = Rules.build;

        pub const Binding = struct {
            dead_zone_end: u32,
            ext: Rules.BindingExtension,
            from: u32,
            kind: Rules.BindingKind,
            name: Span,
            name_hash: u32,
            name_previous: u32,
            namespace: Rules.Namespace,
            node: u32,
            reference_count: u32,
            scope: u32,
            scope_previous: u32,
        };

        const BindingReferences = struct {
            binding: u32,
            pending: ?u32,
            semantic: *const Semantic,
            steps: u32,

            pub fn next(iterator: *BindingReferences) ?Reference {
                if (iterator.pending == null) {
                    const binding = iterator.semantic.at(iterator.binding);

                    assert(iterator.steps == binding.reference_count);

                    return null;
                }

                const index = iterator.pending.?;
                const reference = iterator.semantic.reference_at(index);

                assert(reference.resolution.bound == iterator.binding);

                iterator.pending = iterator.semantic.reference_next_of(index);
                iterator.steps += 1;

                assert(iterator.steps <= iterator.semantic.reference_count());

                return reference;
            }
        };

        pub const Reference = struct {
            context: Context,
            dead_zone: bool,
            ext: Rules.ReferenceExtension,
            name: Span,
            name_hash: u32,
            namespace: Rules.Namespace,
            node: u32,
            resolution: Resolution,
            scope: u32,
        };

        const Scope = struct {
            dynamic: bool,
            ext: Rules.ScopeExtension,
            kind: Rules.ScopeKind,
            node: u32,
            parent: u32,
        };

        const ScopeBindings = struct {
            index: u32,
            scope: u32,
            semantic: *const Semantic,
            steps: u32,

            pub fn next(iterator: *ScopeBindings) ?u32 {
                const total = iterator.semantic.count();

                while (iterator.index < total) {
                    const index = iterator.index;

                    iterator.index += 1;

                    if (iterator.semantic.at(index).scope != iterator.scope) continue;

                    iterator.steps += 1;

                    assert(iterator.steps <= total);

                    return index;
                }

                assert(iterator.index == total);

                return null;
            }
        };

        const Found = struct {
            dynamic_seen: bool,
            index: ?u32,
        };

        pub fn init(
            semantic: *Semantic,
            gpa: std.mem.Allocator,
            limits: *const SemanticLimits,
        ) std.mem.Allocator.Error!void {
            assert(limits.binding_count_max > 0);
            assert(limits.fact_count_max > 0);
            assert(limits.reference_count_max > 0);
            assert(limits.scope_count_max > 0);

            semantic.bindings = try .init(gpa, limits.binding_count_max);
            errdefer semantic.bindings.deinit(gpa);

            semantic.facts = try .init(gpa, limits.fact_count_max);
            errdefer semantic.facts.deinit(gpa);

            semantic.heads = try .init(gpa, bucket_count_of(limits.binding_count_max));
            errdefer semantic.heads.deinit(gpa);

            semantic.reference_first = try .init(gpa, limits.binding_count_max);
            errdefer semantic.reference_first.deinit(gpa);

            semantic.reference_next = try .init(gpa, limits.reference_count_max);
            errdefer semantic.reference_next.deinit(gpa);

            semantic.references = try .init(gpa, limits.reference_count_max);
            errdefer semantic.references.deinit(gpa);

            semantic.references_sorted = true;

            semantic.scopes = try .init(gpa, limits.scope_count_max);
            errdefer semantic.scopes.deinit(gpa);

            if (Rules.Extension != void) try semantic.ext.init(gpa, limits);

            semantic.heads.fill(none);

            assert(semantic.heads.full());
            assert(semantic.count() == 0);
        }

        pub fn deinit(semantic: *Semantic, gpa: std.mem.Allocator) void {
            assert(semantic.heads.full());
            assert(std.math.isPowerOfTwo(semantic.heads.count()));

            if (Rules.Extension != void) semantic.ext.deinit(gpa);

            semantic.scopes.deinit(gpa);
            semantic.references.deinit(gpa);
            semantic.reference_next.deinit(gpa);
            semantic.reference_first.deinit(gpa);
            semantic.heads.deinit(gpa);
            semantic.facts.deinit(gpa);
            semantic.bindings.deinit(gpa);
            semantic.* = undefined;
        }

        pub fn clear(semantic: *Semantic) void {
            assert(semantic.heads.full());

            const heads = semantic.heads.slice();

            for (semantic.bindings.const_slice()) |held| {
                heads[semantic.bucket_of(held.scope, held.name_hash)] = none;
            }

            semantic.bindings.clear();
            semantic.facts.clear();
            semantic.reference_first.clear();
            semantic.reference_next.clear();
            semantic.references.clear();
            semantic.references_sorted = true;

            semantic.scopes.clear();

            if (Rules.Extension != void) semantic.ext.clear();

            assert(semantic.count() == 0);
            assert(semantic.scope_count() == 0);
        }

        pub fn scope_root(
            semantic: *Semantic,
            kind: Rules.ScopeKind,
            node: u32,
            ext: Rules.ScopeExtension,
        ) void {
            assert(semantic.scope_count() == 0);
            assert(semantic.count() == 0);
            assert(node == 0);

            semantic.scopes.push(.{
                .dynamic = false,
                .ext = ext,
                .kind = kind,
                .node = node,
                .parent = none,
            });

            assert(semantic.scope_count() == 1);
        }

        pub fn scope_open(
            semantic: *Semantic,
            parent: u32,
            kind: Rules.ScopeKind,
            node: u32,
            ext: Rules.ScopeExtension,
        ) error{Truncated}!u32 {
            assert(parent < semantic.scope_count());

            if (semantic.scopes.full()) return error.Truncated;

            const index = semantic.scope_count();

            semantic.scopes.push(.{
                .dynamic = false,
                .ext = ext,
                .kind = kind,
                .node = node,
                .parent = parent,
            });

            assert(semantic.scope_count() == index + 1);
            assert(semantic.scope_at(index).parent == parent);

            return index;
        }

        pub fn scope_mark_dynamic(semantic: *Semantic, scope: u32) void {
            assert(scope < semantic.scope_count());

            semantic.scopes.slice()[scope].dynamic = true;

            assert(semantic.scope_at(scope).dynamic);
        }

        pub fn scope_landing(semantic: *const Semantic, scope: u32, kind: Rules.BindingKind) u32 {
            assert(scope < semantic.scope_count());

            var current = scope;

            for (0..scope_depth_max + 1) |_| {
                const held = semantic.scope_at(current);
                if (Rules.lands(kind, held.kind)) break;
                if (held.parent == none) break;

                current = held.parent;
            }

            assert(current < semantic.scope_count());
            assert(current <= scope or !Rules.scopes_in_walk_order);

            return current;
        }

        pub fn declare(
            semantic: *Semantic,
            source: []const u8,
            scope: u32,
            declaration: *const Declaration,
        ) error{Truncated}!u32 {
            assert(scope < semantic.scope_count());
            assert(declaration.name.end() <= source.len);

            if (semantic.bindings.full()) return error.Truncated;

            const name = declaration.name.text(source);
            const hash = name_hash(name);
            const index = semantic.count();
            const bucket = semantic.bucket_of(scope, hash);
            const previous = semantic.chained(source, scope, name, hash, declaration.kind);

            semantic.bindings.push(.{
                .dead_zone_end = declaration.dead_zone_end,
                .ext = declaration.ext,
                .from = declaration.from,
                .kind = declaration.kind,
                .name = declaration.name,
                .name_hash = hash,
                .name_previous = previous orelse none,
                .namespace = Rules.namespace_of(declaration.kind),
                .node = declaration.node,
                .reference_count = 0,
                .scope = scope,
                .scope_previous = semantic.heads.get(bucket),
            });

            semantic.heads.slice()[bucket] = index;

            assert(semantic.count() == index + 1);
            assert(semantic.heads.get(bucket) == index);

            return index;
        }

        pub fn refer(
            semantic: *Semantic,
            source: []const u8,
            reference: *const Reference,
        ) error{Truncated}!void {
            assert(reference.scope < semantic.scope_count());
            assert(reference.name.end() <= source.len);
            assert(reference.resolution == .unresolved);

            if (semantic.references.full()) return error.Truncated;

            const reference_count_before = semantic.reference_count();
            var held = reference.*;

            held.dead_zone = false;
            held.name_hash = name_hash(reference.name.text(source));

            semantic.references.push(held);

            assert(semantic.reference_count() == reference_count_before + 1);
        }

        pub fn fact_push(semantic: *Semantic, fact: Fact) error{Truncated}!void {
            assert(fact.local.length <= std.math.maxInt(u32) - fact.local.offset);

            const fact_count_before = semantic.facts.count();

            try semantic.facts.push(fact);

            assert(semantic.facts.count() == fact_count_before + 1);
        }

        pub fn binding_newest(
            semantic: *const Semantic,
            source: []const u8,
            scope: u32,
            name: []const u8,
            namespace: ?Rules.Namespace,
        ) ?u32 {
            assert(scope < semantic.scope_count());
            assert(name.len > 0);
            assert(source.len <= std.math.maxInt(u32));

            const hash = name_hash(name);
            var index = semantic.heads.get(semantic.bucket_of(scope, hash));

            for (0..semantic.count() + 1) |_| {
                if (index == none) break;

                const held = semantic.at(index);

                assert(held.scope_previous == none or held.scope_previous < index);

                const same = held.scope == scope and held.name_hash == hash;

                if (same) {
                    const wanted = namespace orelse held.namespace;

                    if (held.namespace == wanted) {
                        if (std.mem.eql(u8, held.name.text(source), name)) return index;
                    }
                }

                index = held.scope_previous;
            }

            return null;
        }

        pub fn resolve(
            semantic: *Semantic,
            source: []const u8,
            options: *const Rules.Options,
        ) void {
            assert(source.len <= std.math.maxInt(u32));

            const references = semantic.references.slice();

            assert(references.len <= semantic.references.capacity());

            for (references) |*reference| {
                assert(reference.scope < semantic.scope_count());

                const start = Rules.start_scope(semantic, source, reference);
                const found = semantic.found_of(source, reference, start);

                if (found.index) |index| {
                    semantic.bind(reference, index);

                    continue;
                }

                const name = reference.name.text(source);

                reference.resolution = if (Rules.is_builtin(name, options))
                    .builtin
                else
                    Rules.fallback(reference, found.dynamic_seen);

                assert(reference.resolution != .bound);
            }

            Rules.after_resolve(semantic, source, options);
            semantic.references_chain();

            assert(references.len == semantic.reference_count());
        }

        pub fn at(semantic: *const Semantic, index: u32) Binding {
            assert(index < semantic.count());

            const binding = semantic.bindings.get(index);

            assert(binding.scope < semantic.scope_count());
            assert(binding.name_previous == none or binding.name_previous < index);

            return binding;
        }

        pub fn binding_slice(semantic: *const Semantic) []const Binding {
            const bindings = semantic.bindings.const_slice();

            assert(bindings.len == semantic.count());
            if (bindings.len > 0) assert(semantic.scope_count() > 0);

            return bindings;
        }

        pub fn bindings_of(semantic: *const Semantic, scope: u32) ScopeBindings {
            assert(scope < semantic.scope_count());

            return .{ .index = 0, .scope = scope, .semantic = semantic, .steps = 0 };
        }

        pub fn count(semantic: *const Semantic) u32 {
            const result = semantic.bindings.count();

            assert(result <= semantic.bindings.capacity());

            return result;
        }

        pub fn fact_slice(semantic: *const Semantic) []const Fact {
            return semantic.facts.slice();
        }

        pub fn reference_at(semantic: *const Semantic, index: u32) Reference {
            assert(index < semantic.reference_count());

            const reference = semantic.references.get(index);

            assert(reference.scope < semantic.scope_count());

            return reference;
        }

        pub fn reference_count(semantic: *const Semantic) u32 {
            const result = semantic.references.count();

            assert(result <= semantic.references.capacity());

            return result;
        }

        pub fn reference_row(semantic: *const Semantic, index: u32) ReferenceRow {
            assert(index < none);

            const reference = semantic.reference_at(index);

            return .{
                .is_store = reference.context != .load,
                .name = reference.name,
                .node = reference.node,
                .resolution = reference.resolution,
                .scope = reference.scope,
            };
        }

        pub fn reference_slice(semantic: *const Semantic) []const Reference {
            const references = semantic.references.const_slice();

            assert(references.len == semantic.reference_count());

            return references;
        }

        pub fn reference_bound_named(semantic: *const Semantic, name: Span) ?u32 {
            assert(name.length <= std.math.maxInt(u32) - name.offset);

            const references = semantic.references.const_slice();
            const sorted = semantic.references_sorted;
            const offset = name.offset;

            const start = if (sorted)
                std.sort.partitionPoint(Reference, references, offset, reference_before)
            else
                0;

            const stop = if (sorted)
                std.sort.partitionPoint(Reference, references, offset, reference_at_or_before)
            else
                references.len;

            assert(start <= stop);
            assert(stop <= references.len);

            for (references[start..stop], start..) |*held, index| {
                if (held.name.offset != name.offset) continue;
                if (held.name.length != name.length) continue;
                if (held.resolution != .bound) continue;
                assert(index < std.math.maxInt(u32));

                return @intCast(index);
            }

            return null;
        }

        pub fn reference_first_of(semantic: *const Semantic, binding: u32) ?u32 {
            assert(binding < semantic.count());
            assert(semantic.reference_first.count() == semantic.count());

            const first = semantic.reference_first.get(binding);

            if (first != none) assert(first < semantic.reference_count());

            return if (first == none) null else first;
        }

        pub fn reference_next_of(semantic: *const Semantic, index: u32) ?u32 {
            assert(index < semantic.reference_count());
            assert(semantic.reference_next.count() == semantic.reference_count());

            const next = semantic.reference_next.get(index);

            if (next != none) assert(next > index);

            return if (next == none) null else next;
        }

        pub fn references_of(semantic: *const Semantic, binding: u32) BindingReferences {
            assert(binding < semantic.count());

            return .{
                .binding = binding,
                .pending = semantic.reference_first_of(binding),
                .semantic = semantic,
                .steps = 0,
            };
        }

        pub fn row(semantic: *const Semantic, index: u32) Row {
            assert(index < none);

            const binding = semantic.at(index);

            return .{
                .class = Rules.class_of(binding.kind),
                .name = binding.name,
                .node = binding.node,
                .scope = binding.scope,
            };
        }

        pub fn scope_at(semantic: *const Semantic, index: u32) Scope {
            assert(index < semantic.scope_count());

            const scope = semantic.scopes.get(index);

            if (Rules.scopes_in_walk_order) assert(scope.parent == none or scope.parent < index);

            return scope;
        }

        pub fn scope_count(semantic: *const Semantic) u32 {
            const result = semantic.scopes.count();

            assert(result <= semantic.scopes.capacity());

            return result;
        }

        pub fn scope_row(semantic: *const Semantic, index: u32) ScopeRow {
            assert(index < none);

            const scope = semantic.scope_at(index);

            return .{
                .class = Rules.scope_class_of(scope.kind),
                .node = scope.node,
                .parent = if (scope.parent == none) null else scope.parent,
            };
        }

        pub fn scope_slice(semantic: *const Semantic) []const Scope {
            const scopes = semantic.scopes.const_slice();

            assert(scopes.len == semantic.scope_count());

            return scopes;
        }

        fn reference_at_or_before(offset: u32, reference: Reference) bool {
            assert(reference.name.length <= std.math.maxInt(u32) - reference.name.offset);

            return reference.name.offset <= offset;
        }

        fn reference_before(offset: u32, reference: Reference) bool {
            assert(reference.name.length <= std.math.maxInt(u32) - reference.name.offset);

            return reference.name.offset < offset;
        }

        fn references_chain(semantic: *Semantic) void {
            const references = semantic.references.const_slice();

            semantic.reference_first.clear();
            semantic.reference_next.clear();

            for (0..semantic.count()) |_| semantic.reference_first.push(none);
            for (0..references.len) |_| semantic.reference_next.push(none);

            const first = semantic.reference_first.slice();
            const next = semantic.reference_next.slice();
            var sorted = true;

            for (0..references.len) |offset| {
                const index = references.len - 1 - offset;

                if (index > 0) {
                    if (references[index - 1].name.offset > references[index].name.offset) {
                        sorted = false;
                    }
                }

                switch (references[index].resolution) {
                    .bound => |binding| {
                        next[index] = first[binding];
                        first[binding] = @intCast(index);
                    },
                    else => {},
                }
            }

            semantic.references_sorted = sorted;

            assert(first.len == semantic.count());
            assert(next.len == references.len);
        }

        fn bind(semantic: *Semantic, reference: *Reference, index: u32) void {
            assert(index < semantic.count());

            const binding = &semantic.bindings.slice()[index];

            assert(binding.name_hash == reference.name_hash);
            assert(binding.reference_count < semantic.references.capacity());

            binding.reference_count += 1;
            reference.resolution = .{ .bound = index };

            reference.dead_zone = binding.dead_zone_end != none and
                reference.name.offset < binding.dead_zone_end;

            assert(reference.resolution.bound == index);
        }

        fn bucket_of(semantic: *const Semantic, scope: u32, hash: u32) u32 {
            const bucket_count = semantic.heads.count();
            const bucket = (hash ^ (scope *% 2_654_435_761)) & (bucket_count - 1);

            assert(std.math.isPowerOfTwo(bucket_count));
            assert(bucket < bucket_count);

            return bucket;
        }

        fn chained(
            semantic: *const Semantic,
            source: []const u8,
            scope: u32,
            name: []const u8,
            hash: u32,
            kind: Rules.BindingKind,
        ) ?u32 {
            assert(scope < semantic.scope_count());
            assert(source.len <= std.math.maxInt(u32));
            assert(name.len <= std.math.maxInt(u32));
            assert(hash < none);

            var index = semantic.heads.get(semantic.bucket_of(scope, hash));

            for (0..semantic.count() + 1) |_| {
                if (index == none) break;

                const held = semantic.at(index);

                assert(held.scope_previous == none or held.scope_previous < index);

                const same = held.scope == scope and held.name_hash == hash;

                if (same) {
                    if (Rules.chains_with(held.kind, kind)) {
                        if (std.mem.eql(u8, held.name.text(source), name)) return index;
                    }
                }

                index = held.scope_previous;
            }

            return null;
        }

        fn found_of(
            semantic: *const Semantic,
            source: []const u8,
            reference: *const Reference,
            start: u32,
        ) Found {
            assert(start < semantic.scope_count());
            assert(source.len <= std.math.maxInt(u32));

            const found = semantic.lookup(source, reference, reference.namespace, start);
            if (found.index != null) return found;

            const retry = Rules.retry_namespace(reference) orelse return found;
            const again = semantic.lookup(source, reference, retry, start);

            if (again.index == null) assert(again.dynamic_seen == found.dynamic_seen);

            return again;
        }

        fn lookup(
            semantic: *const Semantic,
            source: []const u8,
            reference: *const Reference,
            wanted: Rules.Namespace,
            start: u32,
        ) Found {
            assert(start < semantic.scope_count());
            assert(source.len <= std.math.maxInt(u32));

            assert(wanted == reference.namespace or
                (Rules.retry_namespace(reference) orelse reference.namespace) == wanted);

            var scope = start;
            var dynamic_seen = false;

            var position: Position = .{
                .crossed_function = start != reference.scope,
                .redirected = start != reference.scope,
                .start = true,
            };

            for (0..scope_depth_max + 1) |_| {
                if (scope == none) break;

                const held = semantic.scope_at(scope);

                if (!Rules.skips(held.kind, position)) {
                    const match = semantic.match_in(source, reference, wanted, scope, position);
                    if (match) |index| return .{ .dynamic_seen = dynamic_seen, .index = index };
                }

                const typed = if (comptime @hasDecl(Rules, "types"))
                    Rules.types(held.kind)
                else
                    false;

                dynamic_seen = dynamic_seen or held.dynamic;
                position.from_type = position.start and typed;
                position.start = false;
                position.crossed_function = position.crossed_function or Rules.crosses(held.kind);
                scope = held.parent;
            }

            return .{ .dynamic_seen = dynamic_seen, .index = null };
        }

        fn match_in(
            semantic: *const Semantic,
            source: []const u8,
            reference: *const Reference,
            wanted: Rules.Namespace,
            scope: u32,
            position: Position,
        ) ?u32 {
            assert(scope < semantic.scope_count());
            assert(source.len <= std.math.maxInt(u32));

            assert(wanted == reference.namespace or
                (Rules.retry_namespace(reference) orelse reference.namespace) == wanted);

            if (position.redirected) assert(position.crossed_function);

            const kind = semantic.scope_at(scope).kind;

            const order: Order = if (comptime @hasDecl(Rules, "order"))
                Rules.order(reference, kind, position)
            else
                .unordered;

            const name = reference.name.text(source);
            const offset = reference.name.offset;
            var index = semantic.heads.get(semantic.bucket_of(scope, reference.name_hash));
            var picked: ?u32 = null;

            for (0..semantic.count() + 1) |_| {
                if (index == none) break;

                const held = semantic.at(index);

                assert(held.scope_previous == none or held.scope_previous < index);

                const visible = if (comptime @hasDecl(Rules, "visible"))
                    Rules.visible(&held, reference, kind, position)
                else switch (order) {
                    .from => held.from <= offset,
                    .from_or_self => held.from <= offset or held.name.offset == offset,
                    .unordered => true,
                };

                const same = held.scope == scope and held.name_hash == reference.name_hash;
                const candidate = same and visible and Rules.binds_in(held.kind, wanted);

                if (candidate) {
                    if (std.mem.eql(u8, held.name.text(source), name)) {
                        if (Rules.pick == .newest) return index;

                        picked = index;
                    }
                }

                index = held.scope_previous;
            }

            if (picked) |held| assert(semantic.at(held).scope == scope);

            return picked;
        }
    };
}

pub const none: u32 = std.math.maxInt(u32);
pub const reference_count_max: u32 = 1 << 20;
pub const scope_depth_max: u32 = 1 << 8;
const SemanticLimits = Limits;
const bucket_count_min: u32 = 16;

const rules_types = [_][]const u8{
    "BindingExtension",
    "BindingKind",
    "Extension",
    "Namespace",
    "Options",
    "ReferenceExtension",
    "ScopeExtension",
    "ScopeKind",
};

const rules_functions = [_][]const u8{
    "after_resolve",
    "binds_in",
    "build",
    "chains_with",
    "class_of",
    "crosses",
    "fallback",
    "is_builtin",
    "lands",
    "namespace_of",
    "retry_namespace",
    "scope_class_of",
    "skips",
    "start_scope",
};

comptime {
    assert(std.math.isPowerOfTwo(bucket_count_min));
    assert(scope_depth_max < reference_count_max);
}

fn bucket_count_of(binding_count_max: u32) u32 {
    assert(binding_count_max > 0);
    assert(binding_count_max <= 1 << 31);

    const power = std.math.ceilPowerOfTwoAssert(u32, binding_count_max);
    const bucket_count = @max(power, bucket_count_min);

    assert(std.math.isPowerOfTwo(bucket_count));
    assert(bucket_count >= binding_count_max);

    return bucket_count;
}

fn rules_check(comptime Rules: type) void {
    comptime {
        for (rules_types) |name| assert(@hasDecl(Rules, name));
        for (rules_functions) |name| assert(@hasDecl(Rules, name));

        assert(@hasDecl(Rules, "order") != @hasDecl(Rules, "visible"));

        assert(@hasDecl(Rules, "pick"));
        assert(@hasDecl(Rules, "scopes_in_walk_order"));
        assert(@TypeOf(Rules.pick) == Pick);
        assert(@TypeOf(Rules.scopes_in_walk_order) == bool);
        assert(@typeInfo(Rules.BindingKind) == .@"enum");
        assert(@typeInfo(Rules.Namespace) == .@"enum");
        assert(@typeInfo(Rules.ScopeKind) == .@"enum");
    }
}

const TestExtension = struct {
    resolved: u32,

    pub fn init(
        ext: *TestExtension,
        gpa: std.mem.Allocator,
        limits: *const Limits,
    ) std.mem.Allocator.Error!void {
        _ = gpa;

        assert(limits.binding_count_max > 0);

        ext.resolved = 0;
    }

    pub fn deinit(ext: *TestExtension, gpa: std.mem.Allocator) void {
        _ = gpa;
        ext.* = undefined;
    }

    pub fn clear(ext: *TestExtension) void {
        ext.resolved = 0;
    }
};

const TestOptions = struct {
    globals: []const []const u8,
};

const TestReferenceExtension = struct {
    generic: bool = false,
    global: bool = false,
};

fn TestRulesType(comptime pick_wanted: Pick, comptime order_wanted: Order) type {
    return struct {
        pub const BindingExtension = void;
        pub const BindingKind = enum { class, constant, function, local, parameter, type_alias };
        pub const Extension = TestExtension;
        pub const Namespace = enum { type, value };
        pub const Options = TestOptions;
        pub const ReferenceExtension = TestReferenceExtension;
        pub const ScopeExtension = void;
        pub const ScopeKind = enum { block, class, function, module };
        pub const pick: Pick = pick_wanted;
        pub const scopes_in_walk_order: bool = true;

        pub fn after_resolve(semantic: anytype, source: []const u8, options: *const Options) void {
            _ = source;
            _ = options;
            comptime assert(@typeInfo(@TypeOf(semantic)) == .pointer);

            semantic.ext.resolved += 1;
        }

        pub fn binds_in(kind: BindingKind, wanted: Namespace) bool {
            return namespace_of(kind) == wanted;
        }

        pub fn build(semantic: *SemanticType(@This()), source: []const u8) u32 {
            assert(source.len <= std.math.maxInt(u32));

            semantic.clear();
            semantic.scope_root(.module, 0, {});

            return semantic.scope_count();
        }

        pub fn chains_with(previous: BindingKind, kind: BindingKind) bool {
            return namespace_of(previous) == namespace_of(kind);
        }

        pub fn class_of(kind: BindingKind) BindingClass {
            return switch (kind) {
                .class, .type_alias => .type,
                .constant => .constant,
                .function => .function,
                .local => .local,
                .parameter => .parameter,
            };
        }

        pub fn crosses(scope: ScopeKind) bool {
            return scope == .function;
        }

        pub fn fallback(
            reference: *const SemanticType(@This()).Reference,
            dynamic_seen: bool,
        ) Resolution {
            _ = reference;

            return if (dynamic_seen) .maybe else .unresolved;
        }

        pub fn is_builtin(name: []const u8, options: *const Options) bool {
            assert(name.len <= std.math.maxInt(u32));

            for (options.globals) |global| {
                if (std.mem.eql(u8, global, name)) return true;
            }

            return false;
        }

        pub fn lands(kind: BindingKind, scope: ScopeKind) bool {
            if (kind != .function) return true;
            return scope == .function or scope == .module;
        }

        pub fn namespace_of(kind: BindingKind) Namespace {
            return switch (kind) {
                .class, .type_alias => .type,
                .constant, .function, .local, .parameter => .value,
            };
        }

        pub fn order(
            reference: *const SemanticType(@This()).Reference,
            scope: ScopeKind,
            position: Position,
        ) Order {
            _ = reference;
            _ = position;

            return switch (scope) {
                .block, .function => order_wanted,
                .class, .module => .unordered,
            };
        }

        pub fn retry_namespace(reference: *const SemanticType(@This()).Reference) ?Namespace {
            if (!reference.ext.generic) return null;
            if (reference.namespace != .type) return null;
            return .value;
        }

        pub fn scope_class_of(kind: ScopeKind) ScopeClass {
            return switch (kind) {
                .block => .block,
                .class => .type,
                .function => .function,
                .module => .module,
            };
        }

        pub fn skips(scope: ScopeKind, position: Position) bool {
            return scope == .class and !position.start;
        }

        pub fn start_scope(
            semantic: anytype,
            source: []const u8,
            reference: *const SemanticType(@This()).Reference,
        ) u32 {
            _ = semantic;
            _ = source;

            return if (reference.ext.global) 0 else reference.scope;
        }
    };
}

const TestRules = TestRulesType(.newest, .from_or_self);
const TestSemantic = SemanticType(TestRules);
const sample = "aaaaaaaaaa bbbbbbbbbb cccccccccc";
const no_globals: TestOptions = .{ .globals = &.{} };

const test_limits: Limits = .{
    .binding_count_max = 8,
    .fact_count_max = 2,
    .reference_count_max = 8,
    .scope_count_max = 4,
};

fn test_declare(
    semantic: anytype,
    scope: u32,
    kind: anytype,
    offset: u32,
    from: u32,
    dead_zone_end: u32,
) !u32 {
    assert(scope < none);
    assert(offset < none);
    assert(from < none);
    assert(dead_zone_end == none or dead_zone_end >= offset);
    comptime assert(@typeInfo(@TypeOf(semantic)) == .pointer);

    return semantic.declare(sample, scope, &.{
        .dead_zone_end = dead_zone_end,
        .ext = {},
        .from = from,
        .kind = kind,
        .name = .{ .offset = offset, .length = 1 },
        .node = offset,
    });
}

fn test_refer(semantic: anytype, scope: u32, offset: u32, ext: TestReferenceExtension) !void {
    assert(scope < none);
    assert(offset < none);
    if (ext.global) assert(!ext.generic);
    comptime assert(@typeInfo(@TypeOf(semantic)) == .pointer);

    try semantic.refer(sample, &.{
        .context = .load,
        .dead_zone = false,
        .ext = ext,
        .name = .{ .offset = offset, .length = 1 },
        .name_hash = 0,
        .namespace = if (ext.generic) .type else .value,
        .node = offset,
        .resolution = .unresolved,
        .scope = scope,
    });
}

fn expect_bound(semantic: anytype, reference: u32, binding: u32) !void {
    assert(reference <= reference_count_max);
    comptime assert(@typeInfo(@TypeOf(semantic)) == .pointer);

    const held = semantic.reference_at(reference);

    try std.testing.expectEqual(Resolution{ .bound = binding }, held.resolution);
}

fn test_semantic(semantic: anytype) !void {
    comptime assert(@typeInfo(@TypeOf(semantic)) == .pointer);

    try semantic.init(std.testing.allocator, &test_limits);

    semantic.scope_root(.module, 0, {});
}

test "a binding declared in a scope resolves a reference in that scope" {
    var semantic: TestSemantic = undefined;

    try test_semantic(&semantic);
    defer semantic.deinit(std.testing.allocator);

    const a = try test_declare(&semantic, 0, .local, 0, 0, none);

    try test_refer(&semantic, 0, 3, .{});
    try test_refer(&semantic, 0, 12, .{});
    semantic.resolve(sample, &no_globals);

    try std.testing.expectEqual(Resolution{ .bound = a }, semantic.reference_at(0).resolution);
    try std.testing.expectEqual(Resolution.unresolved, semantic.reference_at(1).resolution);
    try std.testing.expectEqual(1, semantic.at(a).reference_count);
    try std.testing.expectEqual(1, semantic.ext.resolved);
    try std.testing.expectEqual(BindingClass.local, semantic.row(a).class);
    try std.testing.expectEqual(ScopeClass.module, semantic.scope_row(0).class);
    try std.testing.expectEqual(null, semantic.scope_row(0).parent);
}

test "shadowing picks the newest binding and oldest when the rules say so" {
    var newest: TestSemantic = undefined;

    try test_semantic(&newest);
    defer newest.deinit(std.testing.allocator);

    var oldest: SemanticType(TestRulesType(.oldest, .from_or_self)) = undefined;

    try test_semantic(&oldest);
    defer oldest.deinit(std.testing.allocator);

    const first = try test_declare(&newest, 0, .local, 0, 0, none);
    const second = try test_declare(&newest, 0, .local, 1, 1, none);
    _ = try test_declare(&oldest, 0, .local, 0, 0, none);
    _ = try test_declare(&oldest, 0, .local, 1, 1, none);

    try test_refer(&newest, 0, 5, .{});
    try test_refer(&oldest, 0, 5, .{});
    newest.resolve(sample, &no_globals);
    oldest.resolve(sample, &no_globals);

    try std.testing.expectEqual(Resolution{ .bound = second }, newest.reference_at(0).resolution);
    try std.testing.expectEqual(Resolution{ .bound = first }, oldest.reference_at(0).resolution);
    try std.testing.expectEqual(first, newest.at(second).name_previous);
}

test "an ordered scope hides a later binding except at the binding's own name" {
    var semantic: TestSemantic = undefined;

    try test_semantic(&semantic);
    defer semantic.deinit(std.testing.allocator);

    const block = try semantic.scope_open(0, .block, 1, {});
    const later = try test_declare(&semantic, block, .local, 6, 6, none);

    try test_refer(&semantic, block, 2, .{});
    try test_refer(&semantic, block, 6, .{});
    try test_refer(&semantic, block, 8, .{});
    semantic.resolve(sample, &no_globals);

    try std.testing.expectEqual(Resolution.unresolved, semantic.reference_at(0).resolution);
    try std.testing.expectEqual(Resolution{ .bound = later }, semantic.reference_at(1).resolution);
    try std.testing.expectEqual(Resolution{ .bound = later }, semantic.reference_at(2).resolution);
}

test "a from order hides a later binding even at the binding's own name" {
    var semantic: SemanticType(TestRulesType(.newest, .from)) = undefined;

    try test_semantic(&semantic);
    defer semantic.deinit(std.testing.allocator);

    const block = try semantic.scope_open(0, .block, 1, {});
    const later = try test_declare(&semantic, block, .local, 6, 7, none);

    try test_refer(&semantic, block, 6, .{});
    try test_refer(&semantic, block, 8, .{});
    semantic.resolve(sample, &no_globals);

    try std.testing.expectEqual(Resolution.unresolved, semantic.reference_at(0).resolution);
    try std.testing.expectEqual(Resolution{ .bound = later }, semantic.reference_at(1).resolution);
}

test "the walker runs as the semantic's own build" {
    var semantic: TestSemantic = undefined;

    try test_semantic(&semantic);
    defer semantic.deinit(std.testing.allocator);

    _ = try test_declare(&semantic, 0, .local, 0, 0, none);

    try std.testing.expectEqual(1, semantic.build(sample));
    try std.testing.expectEqual(0, semantic.count());
}

test "an unordered scope sees a later binding" {
    var semantic: TestSemantic = undefined;

    try test_semantic(&semantic);
    defer semantic.deinit(std.testing.allocator);

    const later = try test_declare(&semantic, 0, .local, 6, 6, none);

    try test_refer(&semantic, 0, 2, .{});
    semantic.resolve(sample, &no_globals);

    try std.testing.expectEqual(Resolution{ .bound = later }, semantic.reference_at(0).resolution);
}

test "a hoisted declaration lands in the enclosing function scope" {
    var semantic: TestSemantic = undefined;

    try test_semantic(&semantic);
    defer semantic.deinit(std.testing.allocator);

    const function = try semantic.scope_open(0, .function, 1, {});
    const block = try semantic.scope_open(function, .block, 2, {});
    const landing = semantic.scope_landing(block, .function);
    const hoisted = try test_declare(&semantic, landing, .function, 6, 0, none);

    try test_refer(&semantic, block, 2, .{});
    semantic.resolve(sample, &no_globals);

    try std.testing.expectEqual(function, landing);
    try std.testing.expectEqual(block, semantic.scope_landing(block, .local));
    try expect_bound(&semantic, 0, hoisted);
}

test "a dead zone marks a reference before its end and leaves it bound" {
    var semantic: TestSemantic = undefined;

    try test_semantic(&semantic);
    defer semantic.deinit(std.testing.allocator);

    const constant = try test_declare(&semantic, 0, .constant, 4, 4, 6);

    try test_refer(&semantic, 0, 1, .{});
    try test_refer(&semantic, 0, 8, .{});
    semantic.resolve(sample, &no_globals);

    try expect_bound(&semantic, 0, constant);
    try std.testing.expect(semantic.reference_at(0).dead_zone);
    try expect_bound(&semantic, 1, constant);
    try std.testing.expect(!semantic.reference_at(1).dead_zone);
}

test "a dynamic scope on the path yields maybe and a clean path yields unresolved" {
    var semantic: TestSemantic = undefined;

    try test_semantic(&semantic);
    defer semantic.deinit(std.testing.allocator);

    const plain = try semantic.scope_open(0, .block, 1, {});
    const dynamic = try semantic.scope_open(0, .block, 2, {});

    semantic.scope_mark_dynamic(dynamic);

    try test_refer(&semantic, plain, 0, .{});
    try test_refer(&semantic, dynamic, 0, .{});
    semantic.resolve(sample, &no_globals);

    try std.testing.expectEqual(Resolution.unresolved, semantic.reference_at(0).resolution);
    try std.testing.expectEqual(Resolution.maybe, semantic.reference_at(1).resolution);
}

test "a builtin wins over the fallback" {
    var semantic: TestSemantic = undefined;

    try test_semantic(&semantic);
    defer semantic.deinit(std.testing.allocator);

    semantic.scope_mark_dynamic(0);

    try test_refer(&semantic, 0, 0, .{});
    try test_refer(&semantic, 0, 11, .{});
    semantic.resolve(sample, &.{ .globals = &.{"a"} });

    try std.testing.expectEqual(Resolution.builtin, semantic.reference_at(0).resolution);
    try std.testing.expectEqual(Resolution.maybe, semantic.reference_at(1).resolution);
}

test "a generic reference retries in the value namespace" {
    var semantic: TestSemantic = undefined;

    try test_semantic(&semantic);
    defer semantic.deinit(std.testing.allocator);

    const value = try test_declare(&semantic, 0, .local, 0, 0, none);

    try test_refer(&semantic, 0, 3, .{ .generic = true });
    try test_refer(&semantic, 0, 4, .{ .generic = false });
    semantic.resolve(sample, &no_globals);

    try std.testing.expectEqual(Resolution{ .bound = value }, semantic.reference_at(0).resolution);
    try std.testing.expectEqual(Resolution{ .bound = value }, semantic.reference_at(1).resolution);
}

test "a retry that binds below a dynamic scope binds" {
    var semantic: TestSemantic = undefined;

    try test_semantic(&semantic);
    defer semantic.deinit(std.testing.allocator);

    semantic.scope_mark_dynamic(0);

    const function = try semantic.scope_open(0, .function, 1, {});
    const value = try test_declare(&semantic, function, .local, 0, 0, none);

    try test_refer(&semantic, function, 3, .{ .generic = true });
    semantic.resolve(sample, &no_globals);

    try std.testing.expectEqual(Resolution{ .bound = value }, semantic.reference_at(0).resolution);
}

test "a class scope is skipped unless it is the start scope" {
    var semantic: TestSemantic = undefined;

    try test_semantic(&semantic);
    defer semantic.deinit(std.testing.allocator);

    const class = try semantic.scope_open(0, .class, 1, {});
    const method = try semantic.scope_open(class, .function, 2, {});
    const member = try test_declare(&semantic, class, .local, 0, 0, none);

    try test_refer(&semantic, class, 3, .{});
    try test_refer(&semantic, method, 3, .{});
    semantic.resolve(sample, &no_globals);

    try std.testing.expectEqual(Resolution{ .bound = member }, semantic.reference_at(0).resolution);
    try std.testing.expectEqual(Resolution.unresolved, semantic.reference_at(1).resolution);
}

test "a redirected reference starts at the root scope" {
    var semantic: TestSemantic = undefined;

    try test_semantic(&semantic);
    defer semantic.deinit(std.testing.allocator);

    const function = try semantic.scope_open(0, .function, 1, {});
    const outer = try test_declare(&semantic, 0, .local, 0, 0, none);
    const inner = try test_declare(&semantic, function, .local, 1, 1, none);

    try test_refer(&semantic, function, 3, .{ .global = true });
    try test_refer(&semantic, function, 3, .{});
    semantic.resolve(sample, &no_globals);

    try std.testing.expectEqual(Resolution{ .bound = outer }, semantic.reference_at(0).resolution);
    try std.testing.expectEqual(Resolution{ .bound = inner }, semantic.reference_at(1).resolution);
}

test "a name chain stays within a namespace when the rules do not chain across" {
    var semantic: TestSemantic = undefined;

    try test_semantic(&semantic);
    defer semantic.deinit(std.testing.allocator);

    const typed = try test_declare(&semantic, 0, .type_alias, 0, 0, none);
    const valued = try test_declare(&semantic, 0, .local, 1, 1, none);
    const retyped = try test_declare(&semantic, 0, .class, 2, 2, none);

    try std.testing.expectEqual(none, semantic.at(typed).name_previous);
    try std.testing.expectEqual(none, semantic.at(valued).name_previous);
    try std.testing.expectEqual(typed, semantic.at(retyped).name_previous);
    try std.testing.expectEqual(valued, semantic.binding_newest(sample, 0, "a", .value).?);
    try std.testing.expectEqual(retyped, semantic.binding_newest(sample, 0, "a", null).?);
    try std.testing.expectEqual(null, semantic.binding_newest(sample, 0, "b", null));
}

test "the iterators yield the bindings of a scope and the references of a binding" {
    var semantic: TestSemantic = undefined;

    try test_semantic(&semantic);
    defer semantic.deinit(std.testing.allocator);

    const block = try semantic.scope_open(0, .block, 1, {});
    const a = try test_declare(&semantic, 0, .local, 0, 0, none);
    const b = try test_declare(&semantic, block, .local, 11, 11, none);
    const c = try test_declare(&semantic, block, .local, 22, 22, none);

    try test_refer(&semantic, block, 3, .{});
    try test_refer(&semantic, block, 13, .{});
    try test_refer(&semantic, block, 5, .{});

    try semantic.fact_push(.{
        .binding = .of(a),
        .kind = .import_named,
        .local = .{ .offset = 0, .length = 1 },
        .remote = .{ .offset = 0, .length = 1 },
        .specifier = .{ .offset = 0, .length = 1 },
    });

    semantic.resolve(sample, &no_globals);

    var bindings = semantic.bindings_of(block);
    const bindings_first = bindings.next();
    const bindings_second = bindings.next();
    const bindings_third = bindings.next();

    try std.testing.expectEqual(b, bindings_first.?);
    try std.testing.expectEqual(c, bindings_second.?);
    try std.testing.expectEqual(null, bindings_third);

    var references = semantic.references_of(a);
    const references_first = references.next();
    const references_second = references.next();
    const references_third = references.next();

    try std.testing.expectEqual(3, references_first.?.name.offset);
    try std.testing.expectEqual(5, references_second.?.name.offset);
    try std.testing.expectEqual(null, references_third);
    try std.testing.expectEqual(2, semantic.at(a).reference_count);
    try std.testing.expectEqual(1, semantic.fact_slice().len);
    try std.testing.expect(!semantic.reference_row(0).is_store);
}

test "a full table truncates and keeps the rows pushed before it" {
    var semantic: TestSemantic = undefined;

    try test_semantic(&semantic);
    defer semantic.deinit(std.testing.allocator);

    for (0..test_limits.binding_count_max) |offset| {
        _ = try test_declare(&semantic, 0, .local, @intCast(offset), 0, none);
    }

    try std.testing.expectError(error.Truncated, test_declare(&semantic, 0, .local, 9, 0, none));
    try std.testing.expectEqual(test_limits.binding_count_max, semantic.count());

    for (0..test_limits.scope_count_max - 1) |_| _ = try semantic.scope_open(0, .block, 1, {});

    try std.testing.expectError(error.Truncated, semantic.scope_open(0, .block, 1, {}));
    try std.testing.expectEqual(test_limits.scope_count_max, semantic.scope_count());

    for (0..test_limits.reference_count_max) |_| try test_refer(&semantic, 0, 0, .{});

    try std.testing.expectError(error.Truncated, test_refer(&semantic, 0, 0, .{}));
    try std.testing.expectEqual(test_limits.reference_count_max, semantic.reference_count());
}

test "a cleared semantic is reused from empty" {
    var semantic: TestSemantic = undefined;

    try test_semantic(&semantic);
    defer semantic.deinit(std.testing.allocator);

    _ = try test_declare(&semantic, 0, .local, 0, 0, none);

    try test_refer(&semantic, 0, 3, .{});
    semantic.resolve(sample, &no_globals);
    semantic.clear();

    try std.testing.expectEqual(0, semantic.count());
    try std.testing.expectEqual(0, semantic.scope_count());
    try std.testing.expectEqual(0, semantic.reference_count());
    try std.testing.expectEqual(0, semantic.ext.resolved);

    for (semantic.heads.const_slice()) |head| try std.testing.expectEqual(none, head);

    semantic.scope_root(.module, 0, {});

    const again = try test_declare(&semantic, 0, .local, 0, 0, none);

    try test_refer(&semantic, 0, 3, .{});
    semantic.resolve(sample, &no_globals);

    try std.testing.expectEqual(Resolution{ .bound = again }, semantic.reference_at(0).resolution);
    try std.testing.expectEqual(none, semantic.at(again).scope_previous);
}
