const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const Kind = @import("kind.zig").Kind;
const Span = @import("../../stdx/bounded/span.zig");
const Token = @import("../token.zig");
const TreeType = @import("../tree.zig").TreeType;
const Tree = TreeType(Kind);

pub const Tables = struct {
    bindings: ArrayType(Binding),
    imports: ArrayType(Import),
    references: ArrayType(Reference),
    scopes: ArrayType(Scope),
    segments: ArrayType(Span),

    pub const Limits = struct {
        binding_count_max: u32,
        reference_count_max: u32,
        scope_count_max: u32,
        segment_count_max: u32,
    };

    pub fn init(
        tables: *Tables,
        gpa: std.mem.Allocator,
        limits: *const Limits,
    ) std.mem.Allocator.Error!void {
        assert(limits.binding_count_max > 0);
        assert(limits.scope_count_max > 0);

        tables.bindings = try .init(gpa, limits.binding_count_max);
        errdefer tables.bindings.deinit(gpa);

        tables.imports = try .init(gpa, limits.binding_count_max);
        errdefer tables.imports.deinit(gpa);

        tables.references = try .init(gpa, limits.reference_count_max);
        errdefer tables.references.deinit(gpa);

        tables.scopes = try .init(gpa, limits.scope_count_max);
        errdefer tables.scopes.deinit(gpa);

        tables.segments = try .init(gpa, limits.segment_count_max);

        assert(tables.imports.capacity() == tables.bindings.capacity());
        assert(tables.scopes.empty());
    }

    pub fn deinit(tables: *Tables, gpa: std.mem.Allocator) void {
        assert(tables.imports.capacity() == tables.bindings.capacity());
        assert(tables.scopes.capacity() > 0);

        tables.segments.deinit(gpa);
        tables.scopes.deinit(gpa);
        tables.references.deinit(gpa);
        tables.imports.deinit(gpa);
        tables.bindings.deinit(gpa);
        tables.* = undefined;
    }

    pub fn clear(tables: *Tables) void {
        tables.bindings.clear();
        tables.imports.clear();
        tables.references.clear();
        tables.scopes.clear();
        tables.segments.clear();

        assert(tables.bindings.empty());
        assert(tables.scopes.empty());
    }
};

pub const Binding = struct {
    kind: BindingKind,
    name: Span,
    scope: u32,
};

pub const BindingKind = enum {
    assignment,
    class_def,
    comprehension_target,
    function_def,
    global,
    import,
    nonlocal,
    parameter,
    pattern_capture,
    type_parameter,
    walrus_target,

    pub fn assigns(kind: BindingKind) bool {
        const result = switch (kind) {
            .assignment,
            .class_def,
            .comprehension_target,
            .function_def,
            .pattern_capture,
            .type_parameter,
            .walrus_target,
            => true,
            .global, .import, .nonlocal, .parameter => false,
        };

        if (kind == .global) assert(!result);
        if (kind == .walrus_target) assert(result);

        return result;
    }
};

pub const Error = error{
    BindingsFull,
    ImportsFull,
    JobsFull,
    ReferencesFull,
    ScopesFull,
    SegmentsFull,
};

pub const Import = struct {
    alias: Span,
    binding: u32,
    level: u32,
    segment_count: u32,
    segment_first: u32,
};

const Reference = struct {
    comprehension: bool,
    name: Span,
    scope: u32,
};

pub const Scope = struct {
    kind: ScopeKind,
    node: u32,
    parent: u32,
};

pub const ScopeKind = enum {
    class,
    comprehension,
    function,
    lambda,
    module,
    type,
    type_alias,
    type_variable,

    pub fn name(kind: ScopeKind) []const u8 {
        const text: []const u8 = switch (kind) {
            .class => "class",
            .comprehension => "comprehension",
            .function => "function",
            .lambda => "lambda",
            .module => "module",
            .type => "type",
            .type_alias => "type alias",
            .type_variable => "type variable",
        };

        assert(text.len > 0);
        assert(std.ascii.isLower(text[0]));

        return text;
    }
};

const Limit = enum {
    bindings,
    imports,
    jobs,
    references,
    scopes,
    segments,
};

const Mode = enum {
    load,
    store,
};

const Mark = struct {
    comprehension: bool,
    kind: BindingKind,
    mode: Mode,
    scope: u32,
};

const Job = struct {
    mark: Mark,
    node: u32,
    siblings: bool,
    stop: u32,
};

const Binder = struct {
    deferred: bool,
    full: ?Limit,
    job_count: u32,
    jobs: [job_count_max]Job,
    raw: []const Kind,
    source: []const u8,
    staged: u32,
    tables: *Tables,
    tokens: []const Token,
    tree: *const Tree,

    fn kind_of(binder: *const Binder, node: u32) Kind {
        assert(node < binder.tree.count());

        const kind = binder.tree.kind_at(node);

        assert(kind.is_node());

        return kind;
    }

    fn text_of(binder: *const Binder, position: u32) Span {
        assert(position < binder.tokens.len);

        const span = binder.tokens[position].span();

        assert(span.end() <= binder.source.len);

        return span;
    }

    fn stop(binder: *Binder, limit: Limit) void {
        assert(binder.job_count <= job_count_max);

        if (binder.full == null) binder.full = limit;

        assert(binder.full != null);
    }

    fn push(binder: *Binder, job: *const Job) void {
        assert(binder.job_count <= job_count_max);
        assert(job.node < binder.tree.count());

        if (binder.job_count >= job_count_max) {
            binder.stop(.jobs);

            return;
        }

        binder.jobs[binder.job_count] = job.*;
        binder.job_count += 1;
    }

    fn pop(binder: *Binder) ?Job {
        assert(binder.job_count <= job_count_max);

        if (binder.job_count == 0) return null;

        binder.job_count -= 1;

        const job = binder.jobs[binder.job_count];

        assert(job.node < binder.tree.count());

        return job;
    }

    fn children_marked(binder: *Binder, node: u32, mark: Mark) void {
        assert(node < binder.tree.count());
        assert(mark.scope < binder.tables.scopes.count());

        const child = binder.tree.child_first_of(node) orelse return;

        assert(child > node);

        binder.push(&.{ .mark = mark, .node = child, .siblings = true, .stop = none });
    }

    fn stage_open(binder: *Binder) void {
        assert(binder.job_count <= job_count_max);

        binder.staged = binder.job_count;

        assert(binder.staged <= binder.job_count);
    }

    fn stage(binder: *Binder, node: u32, mark: Mark) void {
        assert(node < none);
        assert(mark.scope < binder.tables.scopes.count());

        const stop_node = binder.tree.sibling_next_of(node) orelse none;

        assert(stop_node == none or stop_node > node);
        assert(binder.staged <= binder.job_count);

        if (binder.job_count > binder.staged) {
            const last = &binder.jobs[binder.job_count - 1];
            const merges = last.stop == node and std.meta.eql(last.mark, mark);

            if (merges) {
                last.stop = stop_node;

                return;
            }
        }

        binder.push(&.{ .mark = mark, .node = node, .siblings = true, .stop = stop_node });
    }

    fn commit(binder: *Binder) void {
        assert(binder.staged <= binder.job_count);
        assert(binder.job_count <= job_count_max);

        std.mem.reverse(Job, binder.jobs[binder.staged..binder.job_count]);
    }

    fn child_of(binder: *const Binder, node: u32, kind: Kind) ?u32 {
        assert(kind.is_node());
        assert(node < none);

        var child = binder.tree.child_first_of(node);

        for (0..binder.tree.count()) |_| {
            const held = child orelse return null;
            if (binder.kind_of(held) == kind) return held;

            child = binder.tree.sibling_next_of(held);
        }

        assert(child == null);

        return null;
    }

    fn child_at(binder: *const Binder, node: u32, ordinal: u32) ?u32 {
        assert(node < binder.tree.count());
        assert(ordinal < binder.tree.count());

        var child = binder.tree.child_first_of(node);

        for (0..ordinal) |_| {
            const held = child orelse return null;

            child = binder.tree.sibling_next_of(held);
        }

        return child;
    }

    fn scope_open(binder: *Binder, kind: ScopeKind, node: u32, parent: u32) u32 {
        const index = binder.tables.scopes.count();

        assert(node < binder.tree.count() or binder.tree.count() == 0);
        assert(parent == none or parent < index);

        if (binder.tables.scopes.full()) {
            binder.stop(.scopes);

            return parent;
        }

        binder.tables.scopes.push(.{ .kind = kind, .node = node, .parent = parent });

        return index;
    }

    fn binding_add(binder: *Binder, kind: BindingKind, name: Span, scope: u32) ?u32 {
        const index = binder.tables.bindings.count();

        assert(name.end() <= binder.source.len);
        assert(scope == none or scope < binder.tables.scopes.count());

        if (binder.tables.bindings.full()) {
            binder.stop(.bindings);

            return null;
        }

        binder.tables.bindings.push(.{ .kind = kind, .name = name, .scope = scope });

        return index;
    }

    fn refer(binder: *Binder, name: Span, scope: u32, comprehension: bool) void {
        assert(name.end() <= binder.source.len);
        assert(scope == none or scope < binder.tables.scopes.count());

        if (binder.tables.references.full()) {
            binder.stop(.references);

            return;
        }

        binder.tables.references.push(.{
            .comprehension = comprehension,
            .name = name,
            .scope = scope,
        });
    }

    fn own_tokens(
        binder: *const Binder,
        node: u32,
        kind: Kind,
        out: *[own_token_count_max]u32,
    ) u32 {
        assert(node < none);

        const held = binder.tree.at(node);
        var child = binder.tree.child_first_of(node);
        var position = held.token_start;
        var count: u32 = 0;

        assert(kind.is_token());
        assert(held.token_end <= binder.raw.len);

        for (0..held.token_end - held.token_start + binder.tree.count() + 1) |_| {
            if (position >= held.token_end) break;
            if (count >= own_token_count_max) break;

            if (child) |inner| {
                const covering = binder.tree.at(inner);

                if (covering.token_start <= position) {
                    if (covering.token_end > position) {
                        position = covering.token_end;
                        child = binder.tree.sibling_next_of(inner);

                        continue;
                    }
                }

                if (covering.token_end <= position) {
                    child = binder.tree.sibling_next_of(inner);

                    continue;
                }
            }

            if (binder.raw[position] == kind) {
                out[count] = position;
                count += 1;
            }

            position += 1;
        }

        assert(count <= own_token_count_max);

        return count;
    }

    fn run(binder: *Binder) void {
        const module = binder.scope_open(.module, 0, none);

        if (binder.tree.count() == 0) return;

        binder.push(&.{
            .mark = loaded(module, false),
            .node = 0,
            .siblings = false,
            .stop = none,
        });

        for (0..binder.tree.count() + 1) |_| {
            const job = binder.pop() orelse break;

            if (job.siblings) {
                if (binder.tree.sibling_next_of(job.node)) |next| {
                    if (next != job.stop) {
                        binder.push(&.{
                            .mark = job.mark,
                            .node = next,
                            .siblings = true,
                            .stop = job.stop,
                        });
                    }
                }
            }

            binder.step(&job);

            if (binder.full != null) return;
        }

        assert(binder.job_count == 0);
        assert(binder.full == null);
    }

    fn step(binder: *Binder, job: *const Job) void {
        assert(job.node < binder.tree.count());
        assert(binder.full == null);

        if (job.mark.mode == .store) {
            binder.store(job);

            return;
        }

        binder.load(job);
    }

    fn enclosing(binder: *const Binder, scope: u32) u32 {
        assert(scope < none);

        const scopes = binder.tables.scopes.const_slice();
        var held = scope;

        assert(scope < scopes.len);

        for (0..scopes.len) |_| {
            const found = scopes[held];
            if (found.kind != .comprehension) return held;
            if (found.parent == none) return held;

            held = found.parent;
        }

        assert(held < scopes.len);

        return held;
    }

    fn store(binder: *Binder, job: *const Job) void {
        const kind = binder.kind_of(job.node);

        assert(job.mark.mode == .store);

        if (kind == .name_node) {
            const name = binder.text_of(binder.tree.at(job.node).token_start);

            const scope = if (job.mark.kind == .walrus_target)
                binder.enclosing(job.mark.scope)
            else
                job.mark.scope;

            if (scope != job.mark.scope) binder.refer(name, job.mark.scope, true);

            _ = binder.binding_add(job.mark.kind, name, scope);

            return;
        }

        var mark = job.mark;

        switch (kind) {
            .list, .parenthesized, .starred, .tuple => {},
            else => mark.mode = .load,
        }

        assert(mark.kind == job.mark.kind);

        binder.children_marked(job.node, mark);
    }

    fn load(binder: *Binder, job: *const Job) void {
        const kind = binder.kind_of(job.node);

        assert(job.mark.mode == .load);

        switch (kind) {
            .name_node => {
                const name = binder.text_of(binder.tree.at(job.node).token_start);

                binder.refer(name, job.mark.scope, job.mark.comprehension);
            },
            .async_function_def, .function_def => binder.definition(job),
            .class_def => binder.class(job),
            .lambda => binder.lambda(job),
            .generator_exp => binder.generator(job),
            else => {
                if (binder.statement(job, kind)) return;

                binder.children_marked(job.node, .{
                    .comprehension = job.mark.comprehension,
                    .kind = .assignment,
                    .mode = .load,
                    .scope = job.mark.scope,
                });
            },
        }
    }

    fn statement(binder: *Binder, job: *const Job, kind: Kind) bool {
        assert(kind == binder.kind_of(job.node));
        assert(job.mark.mode == .load);

        switch (kind) {
            .assign => {
                const stored = binder.children_count(job.node) -| 1;

                binder.split(job, stored, .assignment);
            },
            .aug_assign, .async_for, .@"for" => binder.split(job, 1, .assignment),
            .ann_assign => binder.annotated(job),
            .comprehension => {
                const held: BindingKind = if (job.mark.comprehension)
                    .comprehension_target
                else
                    .assignment;

                binder.split(job, 1, held);
            },
            .dict_comp, .list_comp, .set_comp => binder.inlined(job),
            .named_expr => binder.split(job, 1, .walrus_target),
            else => return binder.bound(job, kind),
        }

        return true;
    }

    fn bound(binder: *Binder, job: *const Job, kind: Kind) bool {
        assert(kind == binder.kind_of(job.node));
        assert(job.mark.mode == .load);

        switch (kind) {
            .delete => binder.children_marked(job.node, .{
                .comprehension = job.mark.comprehension,
                .kind = .assignment,
                .mode = .store,
                .scope = job.mark.scope,
            }),
            .with_item => binder.with_item(job),
            .except_handler => binder.handler(job),
            else => return binder.declared(job, kind),
        }

        return true;
    }

    fn declared(binder: *Binder, job: *const Job, kind: Kind) bool {
        assert(kind == binder.kind_of(job.node));
        assert(job.mark.mode == .load);

        switch (kind) {
            .import, .import_from => binder.import(job, kind),
            .global, .nonlocal => binder.declaration(job, kind),
            .match_as, .match_mapping, .match_star => binder.capture(job),
            .type_alias => binder.type_alias(job),
            else => return false,
        }

        return true;
    }

    fn type_alias(binder: *Binder, job: *const Job) void {
        var carried: [own_token_count_max]u32 = undefined;
        const named = binder.child_of(job.node, .name_node);
        const count = if (named) |held| binder.own_tokens(held, .identifier, &carried) else 0;

        assert(binder.kind_of(job.node) == .type_alias);

        if (count > 0) {
            _ = binder.binding_add(.assignment, binder.text_of(carried[0]), job.mark.scope);
        }

        const outer = binder.type_scope(job.node, job.mark.scope);
        const inner = binder.scope_open(.type_alias, job.node, outer);
        var child = binder.tree.child_first_of(job.node);
        var first = true;

        binder.stage_open();

        for (0..binder.tree.count()) |_| {
            const held = child orelse break;
            const kind = binder.kind_of(held);
            const heading = first and kind == .name_node;

            first = first and !heading;

            if (!heading) {
                if (kind != .type_params) binder.stage(held, loaded(inner, false));
            }

            child = binder.tree.sibling_next_of(held);
        }

        assert(child == null);

        binder.commit();
    }

    fn type_scope(binder: *Binder, node: u32, parent: u32) u32 {
        assert(node < none);
        assert(parent < none);

        var child = binder.tree.child_first_of(node);

        assert(node < binder.tree.count());

        for (0..binder.tree.count()) |_| {
            const held = child orelse break;

            if (binder.kind_of(held) == .type_params) {
                const scope = binder.scope_open(.type, held, parent);

                binder.type_parameters(held, scope);

                return scope;
            }

            child = binder.tree.sibling_next_of(held);
        }

        assert(child == null);

        return parent;
    }

    fn type_parameters(binder: *Binder, node: u32, scope: u32) void {
        assert(node < none);
        assert(scope < none);

        var child = binder.tree.child_first_of(node);

        assert(binder.kind_of(node) == .type_params);

        for (0..binder.tree.count()) |_| {
            const held = child orelse break;

            switch (binder.kind_of(held)) {
                .param_spec, .type_var, .type_var_tuple => {
                    var names: [own_token_count_max]u32 = undefined;
                    const count = binder.own_tokens(held, .identifier, &names);

                    if (count > 0) {
                        _ = binder.binding_add(.type_parameter, binder.text_of(names[0]), scope);
                    }

                    binder.type_bound(held, scope);
                },
                else => {},
            }

            child = binder.tree.sibling_next_of(held);
        }

        assert(child == null);
    }

    fn type_bound(binder: *Binder, node: u32, scope: u32) void {
        assert(node < none);
        assert(scope < none);

        const first = binder.tree.child_first_of(node) orelse return;
        const inner = binder.scope_open(.type_variable, node, scope);
        var child: ?u32 = first;

        assert(first > node);

        binder.stage_open();

        for (0..binder.tree.count()) |_| {
            const held = child orelse break;

            binder.stage(held, loaded(inner, false));

            child = binder.tree.sibling_next_of(held);
        }

        assert(child == null);

        binder.commit();
    }

    fn inlined(binder: *Binder, job: *const Job) void {
        const head = binder.child_of(job.node, .comprehension);
        const target: u32 = if (head) |held| binder.child_at(held, 0) orelse none else none;
        const iterable: u32 = if (head) |held| binder.child_at(held, 1) orelse none else none;

        assert(target == none or target > job.node);

        if (iterable != none) {
            binder.push(&.{
                .mark = loaded(job.mark.scope, job.mark.comprehension),
                .node = iterable,
                .siblings = false,
                .stop = none,
            });
        }

        var child = binder.tree.child_first_of(job.node);

        binder.stage_open();

        for (0..binder.tree.count()) |_| {
            const held = child orelse break;

            const mark: Mark = .{
                .comprehension = true,
                .kind = .comprehension_target,
                .mode = .load,
                .scope = job.mark.scope,
            };

            if (held == head) {
                binder.inlined_clauses(held, iterable, target, mark);
            } else {
                binder.stage(held, mark);
            }

            child = binder.tree.sibling_next_of(held);
        }

        assert(child == null);

        binder.commit();
    }

    fn inlined_clauses(binder: *Binder, head: u32, iterable: u32, target: u32, mark: Mark) void {
        assert(head < none);

        var clause = binder.tree.child_first_of(head);

        assert(binder.kind_of(head) == .comprehension);
        assert(mark.mode == .load);

        for (0..binder.tree.count()) |_| {
            const held = clause orelse break;

            if (held != iterable) {
                var staged = mark;

                if (held == target) staged.mode = .store;

                binder.stage(held, staged);
            }

            clause = binder.tree.sibling_next_of(held);
        }

        assert(clause == null);
    }

    fn annotated(binder: *Binder, job: *const Job) void {
        var child = binder.tree.child_first_of(job.node);
        var index: u32 = 0;

        assert(binder.kind_of(job.node) == .ann_assign);

        binder.stage_open();

        for (0..binder.tree.count()) |_| {
            const held = child orelse break;
            const skipped = index == 1 and binder.deferred;

            if (!skipped) {
                binder.stage(held, .{
                    .comprehension = job.mark.comprehension,
                    .kind = .assignment,
                    .mode = if (index == 0) .store else .load,
                    .scope = job.mark.scope,
                });
            }

            index += 1;
            child = binder.tree.sibling_next_of(held);
        }

        assert(child == null);

        binder.commit();
    }

    fn children_count(binder: *const Binder, node: u32) u32 {
        assert(node < none);

        var child = binder.tree.child_first_of(node);
        var count: u32 = 0;

        for (0..binder.tree.count()) |_| {
            const held = child orelse break;

            child = binder.tree.sibling_next_of(held);
            count += 1;
        }

        assert(child == null);
        assert(count < binder.tree.count());

        return count;
    }

    fn split(binder: *Binder, job: *const Job, stored: u32, kind: BindingKind) void {
        assert(stored < none);

        var child = binder.tree.child_first_of(job.node);
        var index: u32 = 0;

        assert(job.mark.mode == .load);

        binder.stage_open();

        for (0..binder.tree.count()) |_| {
            const held = child orelse break;

            binder.stage(held, .{
                .comprehension = job.mark.comprehension,
                .kind = kind,
                .mode = if (index < stored) .store else .load,
                .scope = job.mark.scope,
            });

            index += 1;
            child = binder.tree.sibling_next_of(held);
        }

        assert(child == null);

        binder.commit();
    }

    fn with_item(binder: *Binder, job: *const Job) void {
        const count = binder.children_count(job.node);
        const plain = loaded(job.mark.scope, job.mark.comprehension);

        assert(binder.kind_of(job.node) == .with_item);

        if (count < 2) {
            binder.children_marked(job.node, plain);

            return;
        }

        const target = binder.child_at(job.node, 1).?;
        const value = binder.child_at(job.node, 0).?;
        var stored = plain;

        stored.mode = .store;

        assert(value < target);

        binder.push(&.{ .mark = stored, .node = target, .siblings = false, .stop = none });
        binder.push(&.{ .mark = plain, .node = value, .siblings = false, .stop = none });
    }

    fn handler(binder: *Binder, job: *const Job) void {
        var names: [own_token_count_max]u32 = undefined;
        const count = binder.own_tokens(job.node, .identifier, &names);

        assert(binder.kind_of(job.node) == .except_handler);

        if (count > 0) {
            _ = binder.binding_add(.assignment, binder.text_of(names[count - 1]), job.mark.scope);
        }

        binder.children_marked(job.node, loaded(job.mark.scope, job.mark.comprehension));
    }

    fn capture(binder: *Binder, job: *const Job) void {
        var names: [own_token_count_max]u32 = undefined;
        const count = binder.own_tokens(job.node, .identifier, &names);

        assert(count <= own_token_count_max);

        for (names[0..count]) |position| {
            const name = binder.text_of(position);
            if (std.mem.eql(u8, name.text(binder.source), "_")) continue;

            _ = binder.binding_add(.pattern_capture, name, job.mark.scope);
        }

        binder.children_marked(job.node, loaded(job.mark.scope, job.mark.comprehension));
    }

    fn declaration(binder: *Binder, job: *const Job, kind: Kind) void {
        assert(kind == .global or kind == .nonlocal);

        var names: [own_token_count_max]u32 = undefined;
        const held: BindingKind = if (kind == .global) .global else .nonlocal;
        const count = binder.own_tokens(job.node, .identifier, &names);

        for (names[0..count]) |position| {
            _ = binder.binding_add(held, binder.text_of(position), job.mark.scope);
        }
    }

    fn import(binder: *Binder, job: *const Job, kind: Kind) void {
        assert(kind == .import or kind == .import_from);

        const level = if (kind == .import_from) binder.import_level(job.node) else 0;
        var child = binder.tree.child_first_of(job.node);

        for (0..binder.tree.count()) |_| {
            const held = child orelse break;

            if (binder.kind_of(held) == .alias) binder.alias(held, job.mark.scope, level);

            child = binder.tree.sibling_next_of(held);
        }

        assert(child == null);
    }

    fn import_level(binder: *const Binder, node: u32) u32 {
        assert(node < none);

        const held = binder.tree.at(node);
        var found: u32 = 0;

        assert(held.token_end <= binder.raw.len);

        for (held.token_start..held.token_end) |position| {
            switch (binder.raw[position]) {
                .dot => found += 1,
                .ellipsis => found += 3,
                .from_keyword => {},
                else => break,
            }
        }

        assert(found <= 3 * (held.token_end - held.token_start));

        return found;
    }

    fn alias(binder: *Binder, node: u32, scope: u32, level: u32) void {
        assert(node < none);
        assert(scope < none);
        assert(level < none);

        var names: [own_token_count_max]u32 = undefined;
        const count = binder.own_tokens(node, .identifier, &names);
        if (count == 0) return;

        const held = binder.tree.at(node);

        const renamed = std.mem.findScalar(
            Kind,
            binder.raw[held.token_start..held.token_end],
            .as_keyword,
        ) != null;

        const name = binder.text_of(if (renamed) names[count - 1] else names[0]);
        const binding = binder.binding_add(.import, name, scope) orelse none;
        const segment_first = binder.tables.segments.count();
        const segment_count = if (renamed) count - 1 else count;

        assert(segment_count <= count);

        for (names[0..segment_count]) |position| {
            if (binder.tables.segments.full()) {
                binder.stop(.segments);

                return;
            }

            binder.tables.segments.push(binder.text_of(position));
        }

        if (binder.tables.imports.full()) {
            binder.stop(.imports);

            return;
        }

        binder.tables.imports.push(.{
            .alias = name,
            .binding = binding,
            .level = level,
            .segment_count = segment_count,
            .segment_first = segment_first,
        });
    }

    fn definition(binder: *Binder, job: *const Job) void {
        var names: [own_token_count_max]u32 = undefined;
        const count = binder.own_tokens(job.node, .identifier, &names);

        if (count > 0) {
            _ = binder.binding_add(.function_def, binder.text_of(names[0]), job.mark.scope);
        }

        const outer = binder.type_scope(job.node, job.mark.scope);
        const inner = binder.scope_open(.function, job.node, outer);
        var child = binder.tree.child_first_of(job.node);

        assert(binder.kind_of(job.node) == .function_def or
            binder.kind_of(job.node) == .async_function_def);

        for (0..binder.tree.count()) |_| {
            const held = child orelse break;

            if (binder.kind_of(held) == .arguments) binder.parameters(held, inner, outer);

            child = binder.tree.sibling_next_of(held);
        }

        child = binder.tree.child_first_of(job.node);

        binder.stage_open();

        for (0..binder.tree.count()) |_| {
            const held = child orelse break;

            switch (binder.kind_of(held)) {
                .arguments, .type_params => {},
                .block => binder.stage(held, loaded(inner, false)),
                else => if (!binder.deferred) binder.stage(held, loaded(outer, false)),
            }

            child = binder.tree.sibling_next_of(held);
        }

        assert(child == null);

        binder.commit();
    }

    fn parameters(binder: *Binder, node: u32, inner: u32, outer: u32) void {
        assert(node < none);
        assert(outer < none);

        var child = binder.tree.child_first_of(node);

        assert(binder.kind_of(node) == .arguments);
        assert(inner < binder.tables.scopes.count());

        binder.stage_open();

        for (0..binder.tree.count()) |_| {
            const held = child orelse break;

            if (binder.kind_of(held) == .arg) {
                var names: [own_token_count_max]u32 = undefined;
                const count = binder.own_tokens(held, .identifier, &names);

                if (count > 0) {
                    _ = binder.binding_add(.parameter, binder.text_of(names[0]), inner);
                }

                if (!binder.deferred) binder.stage(held, loaded(outer, false));
            } else {
                binder.stage(held, loaded(outer, false));
            }

            child = binder.tree.sibling_next_of(held);
        }

        binder.commit();
    }

    fn class(binder: *Binder, job: *const Job) void {
        var names: [own_token_count_max]u32 = undefined;
        const count = binder.own_tokens(job.node, .identifier, &names);

        assert(binder.kind_of(job.node) == .class_def);

        if (count > 0) {
            _ = binder.binding_add(.class_def, binder.text_of(names[0]), job.mark.scope);
        }

        const outer = binder.type_scope(job.node, job.mark.scope);
        const inner = binder.scope_open(.class, job.node, outer);
        var child = binder.tree.child_first_of(job.node);

        binder.stage_open();

        for (0..binder.tree.count()) |_| {
            const held = child orelse break;

            switch (binder.kind_of(held)) {
                .block => binder.stage(held, loaded(inner, false)),
                .type_params => {},
                else => binder.stage(held, loaded(outer, false)),
            }

            child = binder.tree.sibling_next_of(held);
        }

        assert(child == null);

        binder.commit();
    }

    fn lambda(binder: *Binder, job: *const Job) void {
        const inner = binder.scope_open(.lambda, job.node, job.mark.scope);
        var child = binder.tree.child_first_of(job.node);

        assert(binder.kind_of(job.node) == .lambda);

        binder.stage_open();

        for (0..binder.tree.count()) |_| {
            const held = child orelse break;
            const next = binder.tree.sibling_next_of(held);

            if (binder.kind_of(held) == .arg) {
                var names: [own_token_count_max]u32 = undefined;
                const seen = binder.own_tokens(held, .identifier, &names);

                if (seen > 0) _ = binder.binding_add(.parameter, binder.text_of(names[0]), inner);
            } else if (next == null) {
                binder.stage(held, loaded(inner, false));
            } else {
                binder.stage(held, loaded(job.mark.scope, job.mark.comprehension));
            }

            child = next;
        }

        assert(child == null);

        binder.commit();
    }

    fn generator(binder: *Binder, job: *const Job) void {
        const inner = binder.scope_open(.comprehension, job.node, job.mark.scope);
        var child = binder.tree.child_first_of(job.node);
        var first = true;

        assert(binder.kind_of(job.node) == .generator_exp);

        binder.stage_open();

        for (0..binder.tree.count()) |_| {
            const held = child orelse break;
            const leading = first and binder.kind_of(held) == .comprehension;

            if (leading) {
                first = false;

                binder.generator_clauses(held, inner, job);
            } else {
                binder.stage(held, loaded(inner, false));
            }

            child = binder.tree.sibling_next_of(held);
        }

        assert(child == null);

        binder.commit();
    }

    fn generator_clauses(binder: *Binder, head: u32, inner: u32, job: *const Job) void {
        assert(head < none);

        const target = binder.child_at(head, 0);
        var clause = binder.tree.child_first_of(head);
        var index: u32 = 0;

        assert(binder.kind_of(head) == .comprehension);
        assert(inner < binder.tables.scopes.count());

        for (0..binder.tree.count()) |_| {
            const held = clause orelse break;

            binder.stage(held, .{
                .comprehension = job.mark.comprehension,
                .kind = .assignment,
                .mode = if (held == target) .store else .load,
                .scope = if (index == 1) job.mark.scope else inner,
            });

            index += 1;
            clause = binder.tree.sibling_next_of(held);
        }

        assert(clause == null);
    }
};

const job_count_max: u32 = 1 << 10;
const none: u32 = std.math.maxInt(u32);
const own_token_count_max: u32 = 16;

comptime {
    assert(job_count_max > own_token_count_max);
    assert(std.math.isPowerOfTwo(job_count_max));
}

pub fn bind(
    source: []const u8,
    tokens: []const Token,
    raw: []const Kind,
    tree: *const Tree,
    tables: *Tables,
) Error!void {
    assert(tokens.len == raw.len);
    assert(source.len <= std.math.maxInt(u32));

    tables.clear();

    var binder: Binder = .{
        .deferred = defers_annotations(source, tokens, raw),
        .full = null,
        .job_count = 0,
        .jobs = undefined,
        .raw = raw,
        .source = source,
        .staged = 0,
        .tables = tables,
        .tokens = tokens,
        .tree = tree,
    };

    binder.run();

    const limit = binder.full orelse return;

    switch (limit) {
        .bindings => assert(tables.bindings.full()),
        .imports => assert(tables.imports.full()),
        .jobs => assert(binder.job_count >= job_count_max),
        .references => assert(tables.references.full()),
        .scopes => assert(tables.scopes.full()),
        .segments => assert(tables.segments.full()),
    }

    return switch (limit) {
        .bindings => error.BindingsFull,
        .imports => error.ImportsFull,
        .jobs => error.JobsFull,
        .references => error.ReferencesFull,
        .scopes => error.ScopesFull,
        .segments => error.SegmentsFull,
    };
}

fn loaded(scope: u32, comprehension: bool) Mark {
    const mark: Mark = .{
        .comprehension = comprehension,
        .kind = .assignment,
        .mode = .load,
        .scope = scope,
    };

    assert(mark.mode == .load);
    assert(mark.kind == .assignment);

    return mark;
}

fn defers_annotations(source: []const u8, tokens: []const Token, raw: []const Kind) bool {
    assert(source.len <= std.math.maxInt(u32));

    var future = false;

    assert(tokens.len == raw.len);

    for (raw, tokens) |kind, token| {
        if (kind == .from_keyword) future = false;
        if (kind != .identifier) continue;

        const text = token.text(source);

        if (std.mem.eql(u8, text, "__future__")) {
            future = true;

            continue;
        }

        if (future) {
            if (std.mem.eql(u8, text, "annotations")) return true;
        }
    }

    assert(!future or raw.len > 0);

    return false;
}
