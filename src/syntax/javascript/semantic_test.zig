const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const Binding = @import("semantic.zig").Semantic.Binding;
const BindingKind = @import("semantic.zig").BindingKind;
const Dialect = @import("dialect.zig").Dialect;
const EventsType = @import("../tree.zig").EventsType;
const Kind = @import("kind.zig").Kind;
const ModuleKind = @import("semantic.zig").ModuleKind;
const Namespace = @import("semantic.zig").Namespace;
const Parser = @import("parse.zig").Parser;
const Reference = @import("semantic.zig").Semantic.Reference;
const Role = @import("semantic.zig").Role;
const ScopeKind = @import("semantic.zig").ScopeKind;
const Semantic = @import("semantic.zig").Semantic;
const Span = @import("../../stdx/bounded/span.zig");
const Structure = @import("../tree.zig").Structure;
const Token = @import("../token.zig");
const Tokens = @import("../tokens.zig");
const TreeType = @import("../tree.zig").TreeType;
const raw_of = @import("../raw.zig").raw_of;
const corpus = @import("../../testing/corpus.zig");
const environment = @import("../../testing/environment.zig");
const floor = @import("../../testing/floor.zig");
const is_ascii_whitespace = @import("../../text/scan.zig").is_ascii_whitespace;
const lex = @import("lex.zig").lex;
const oracle = @import("../../testing/oracle.zig");
const parameter_none = @import("semantic.zig").parameter_none;
const role_of_kind = @import("semantic.zig").role_of_kind;
const stripe = @import("../../testing/stripe.zig");
const tally_file = @import("../../testing/tally.zig");
const Events = EventsType(Kind);
const Tree = TreeType(Kind);

const Assigned = enum {
    other,
    own,
    pattern,
};

const Detected = struct {
    dialect: ?Dialect,
};

const Fixture = struct {
    dialect: ?Dialect,
    name: []const u8,
    source: []const u8,
};

const Directive = enum {
    disable,
    disable_line,
    disable_next_line,
    enable,
};

const ForPart = enum {
    body_part,
    init_part,
    test_part,
    update_part,
};

const Golden = struct {
    broken: bool,
    rows: std.ArrayList(Row),
    text: []u8,

    fn deinit(golden: *Golden, gpa: std.mem.Allocator) void {
        assert(golden.rows.items.len <= golden.text.len);
        assert(golden.rows.items.len <= golden.rows.capacity);

        golden.rows.deinit(gpa);
        gpa.free(golden.text);
        golden.* = undefined;
    }
};

const Found = struct {
    directive: Directive,
    rest: []const u8,
};

const Group = struct {
    count: u32,
    exported: bool,
    first: u32,
    merged: bool,
    read: bool,
};

const Interval = struct {
    rule: []const u8,
    start: u32,
    stop: u32,
};

const Linter = struct {
    found: std.ArrayList(Row),
    heads: std.ArrayList(u32),
    intervals: std.ArrayList(Interval),
    machine: *Machine,
    nexts: std.ArrayList(u32),
    opened: std.ArrayList(Interval),
    used: std.ArrayList(u8),

    fn create(gpa: std.mem.Allocator) !Linter {
        const machine = try Machine.create(gpa);
        errdefer machine.destroy(gpa);

        var found = try std.ArrayList(Row).initCapacity(gpa, row_count_max);
        errdefer found.deinit(gpa);

        var heads = try std.ArrayList(u32).initCapacity(gpa, binding_count_max);
        errdefer heads.deinit(gpa);

        var nexts = try std.ArrayList(u32).initCapacity(gpa, reference_count_max);
        errdefer nexts.deinit(gpa);

        var intervals = try std.ArrayList(Interval).initCapacity(gpa, directive_count_max);
        errdefer intervals.deinit(gpa);

        var opened = try std.ArrayList(Interval).initCapacity(gpa, directive_count_max);
        errdefer opened.deinit(gpa);

        const used = try std.ArrayList(u8).initCapacity(gpa, scope_count_max);

        assert(found.capacity >= row_count_max);
        assert(heads.capacity >= binding_count_max);

        return .{
            .found = found,
            .heads = heads,
            .intervals = intervals,
            .machine = machine,
            .nexts = nexts,
            .opened = opened,
            .used = used,
        };
    }

    fn destroy(linter: *Linter, gpa: std.mem.Allocator) void {
        assert(linter.found.capacity >= row_count_max);
        assert(linter.nexts.capacity >= reference_count_max);

        linter.used.deinit(gpa);
        linter.opened.deinit(gpa);
        linter.nexts.deinit(gpa);
        linter.intervals.deinit(gpa);
        linter.heads.deinit(gpa);
        linter.found.deinit(gpa);
        linter.machine.destroy(gpa);
        linter.* = undefined;
    }

    fn rows(linter: *Linter, source: []const u8) ![]const Row {
        assert(source.len <= std.math.maxInt(u32));

        linter.found.clearRetainingCapacity();
        linter.link(source);

        try linter.undefined_rows(source);
        try linter.unused_rows(source);
        try linter.redeclared_rows(source);
        try linter.directives(source);

        var kept: usize = 0;

        for (linter.found.items) |row| {
            if (linter.suppressed(row)) continue;

            linter.found.items[kept] = row;
            kept += 1;
        }

        linter.found.shrinkRetainingCapacity(kept);
        std.mem.sort(Row, linter.found.items, {}, Row.less_than);

        assert(linter.found.items.len == kept);
        assert(kept <= row_count_max);

        return linter.found.items;
    }

    fn directives(linter: *Linter, source: []const u8) !void {
        var disabled: ?u32 = null;

        assert(source.len <= source_bytes_max);
        assert(linter.intervals.capacity >= directive_count_max);

        linter.intervals.clearRetainingCapacity();
        linter.opened.clearRetainingCapacity();

        for (linter.machine.tokens.slice()) |token| {
            if (token.kind != .comment) continue;

            const content = comment_content(source, token) orelse continue;
            const comment = source[content.offset..content.end()];
            const text = std.mem.trimStart(u8, comment, directive_blanks);
            const found = directive_of(text) orelse continue;
            const listed = std.mem.trim(u8, rules_listed(found.rest), directive_separators);

            switch (found.directive) {
                .disable => {
                    if (listed.len == 0) {
                        if (disabled == null) disabled = content.end();
                    } else {
                        try linter.opens(listed, content.end());
                    }
                },
                .disable_line => {
                    const before = source[0..content.offset];
                    const start = if (std.mem.findScalarLast(u8, before, '\n')) |at| at + 1 else 0;

                    try linter.covers(listed, @intCast(start), content.offset);
                },
                .disable_next_line => {
                    const stop = next_line_end(source, content.end());

                    try linter.covers(listed, content.end(), stop);
                },
                .enable => {
                    if (listed.len == 0) {
                        if (disabled) |start| try linter.interval("", start, content.offset);

                        disabled = null;
                    } else {
                        try linter.closes(listed, content.offset);
                    }
                },
            }
        }

        const length: u32 = @intCast(source.len);

        if (disabled) |start| try linter.interval("", start, length);

        for (linter.opened.items) |held| try linter.interval(held.rule, held.start, length);
    }

    fn opens(linter: *Linter, listed: []const u8, start: u32) !void {
        assert(listed.len > 0);
        assert(start < none);

        var names = std.mem.tokenizeAny(u8, listed, directive_separators);

        assert(linter.opened.items.len <= directive_count_max);

        for (0..listed.len + 1) |_| {
            const name = names.next() orelse break;
            if (linter.opened_index(name) != null) continue;
            if (linter.opened.items.len == linter.opened.capacity) return error.Overflow;

            linter.opened.appendAssumeCapacity(.{ .rule = name, .start = start, .stop = start });
        }
    }

    fn closes(linter: *Linter, listed: []const u8, stop: u32) !void {
        assert(listed.len > 0);
        assert(stop < none);

        var names = std.mem.tokenizeAny(u8, listed, directive_separators);

        assert(linter.opened.items.len <= directive_count_max);

        for (0..listed.len + 1) |_| {
            const name = names.next() orelse break;
            const at = linter.opened_index(name) orelse continue;
            const held = linter.opened.swapRemove(at);

            try linter.interval(held.rule, held.start, stop);
        }
    }

    fn covers(linter: *Linter, listed: []const u8, start: u32, stop: u32) !void {
        assert(listed.len <= std.math.maxInt(u32));

        var names = std.mem.tokenizeAny(u8, listed, directive_separators);

        assert(start <= stop);
        assert(linter.intervals.items.len <= directive_count_max);

        if (listed.len == 0) return linter.interval("", start, stop);

        for (0..listed.len + 1) |_| {
            const name = names.next() orelse break;

            try linter.interval(name, start, stop);
        }
    }

    fn opened_index(linter: *const Linter, name: []const u8) ?usize {
        assert(name.len > 0);
        assert(linter.opened.items.len <= directive_count_max);

        for (linter.opened.items, 0..) |held, index| {
            if (std.mem.eql(u8, held.rule, name)) return index;
        }

        return null;
    }

    fn interval(linter: *Linter, rule: []const u8, start: u32, stop: u32) !void {
        assert(start <= stop);
        assert(linter.intervals.items.len <= linter.intervals.capacity);

        if (linter.intervals.items.len == linter.intervals.capacity) return error.Overflow;
        assert(rule.len <= std.math.maxInt(u32));

        linter.intervals.appendAssumeCapacity(.{ .rule = rule, .start = start, .stop = stop });
    }

    fn suppressed(linter: *const Linter, row: Row) bool {
        assert(row.code.len > 0);
        assert(linter.intervals.items.len <= directive_count_max);

        for (linter.intervals.items) |held| {
            if (row.offset < held.start) continue;
            if (row.offset >= held.stop) continue;
            if (held.rule.len == 0) return true;

            const slash = std.mem.findScalarLast(u8, held.rule, '/');
            const base = if (slash) |at| held.rule[at + 1 ..] else held.rule;
            if (std.mem.eql(u8, base, row.code)) return true;
        }

        return false;
    }

    fn push(linter: *Linter, code: []const u8, offset: u32) !void {
        assert(code.len > 0);
        assert(linter.found.items.len <= linter.found.capacity);

        if (linter.found.items.len == linter.found.capacity) return error.Overflow;
        assert(offset < none);

        linter.found.appendAssumeCapacity(.{ .code = code, .offset = offset });
    }

    fn link(linter: *Linter, source: []const u8) void {
        assert(source.len <= std.math.maxInt(u32));

        const semantic = &linter.machine.semantic;
        const references = semantic.reference_slice();

        assert(semantic.count() <= linter.heads.capacity);
        assert(references.len <= linter.nexts.capacity);

        linter.heads.clearRetainingCapacity();
        linter.heads.appendNTimesAssumeCapacity(none, semantic.count());
        linter.nexts.clearRetainingCapacity();
        linter.nexts.appendNTimesAssumeCapacity(none, references.len);

        for (0..references.len) |step| {
            const index = references.len - 1 - step;
            const retargeted = linter.signature_bound(source, &references[index]);

            const resolved = switch (references[index].resolution) {
                .bound => |held| held,
                else => retargeted orelse continue,
            };

            const bound = retargeted orelse
                linter.checked_binding(source, &references[index], resolved) orelse
                continue;

            linter.nexts.items[index] = linter.heads.items[bound];
            linter.heads.items[bound] = @intCast(index);
        }
    }

    fn checked_binding(
        linter: *const Linter,
        source: []const u8,
        reference: *const Reference,
        bound: u32,
    ) ?u32 {
        assert(source.len <= std.math.maxInt(u32));
        assert(bound < none);

        const semantic = &linter.machine.semantic;
        const held = semantic.at(bound);

        assert(bound < semantic.count());
        assert(reference.resolution == .bound);

        if (held.kind != .type_parameter) return bound;
        if (!linter.check_typed(reference.node, held)) return bound;

        const name = held.name.text(source);
        var scope = semantic.scope_at(held.scope).parent;

        for (0..semantic.scope_count()) |_| {
            if (scope == none) return null;
            if (semantic.binding_newest(source, scope, name, .type)) |found| return found;
            if (semantic.binding_newest(source, scope, name, .any)) |found| return found;

            scope = semantic.scope_at(scope).parent;
        }

        return null;
    }

    fn signature_bound(
        linter: *const Linter,
        source: []const u8,
        reference: *const Reference,
    ) ?u32 {
        const semantic = &linter.machine.semantic;

        const stop = switch (reference.resolution) {
            .bound => |held| semantic.at(held).scope,
            .builtin, .external, .maybe, .unresolved => none,
        };

        var scope = reference.scope;

        assert(reference.scope < semantic.scope_count());
        assert(reference.name.end() <= source.len);

        if (!linter.machine.typed) return null;

        switch (reference.namespace) {
            .query, .type => {},
            .any, .value => return null,
        }

        for (0..semantic.scope_count()) |_| {
            if (scope == none) return null;
            if (scope == stop) return null;

            const held = semantic.scope_at(scope);

            if (held.kind == .function) {
                if (linter.body_bound(source, reference, scope)) |found| return found;
            }

            scope = held.parent;
        }

        return null;
    }

    fn body_bound(
        linter: *const Linter,
        source: []const u8,
        reference: *const Reference,
        function: u32,
    ) ?u32 {
        assert(source.len <= std.math.maxInt(u32));
        assert(function < none);

        const machine = linter.machine;
        const semantic = &machine.semantic;
        const tree = &machine.tree;
        const node = semantic.scope_at(function).node;

        assert(semantic.scope_at(function).kind == .function);
        assert(node < tree.count());

        const body = child_last(tree, node);
        if (body == none) return null;
        if (tree.kind_at(body) != .statement_block) return null;

        const start = tree.at(body).span(Token, machine.tokens.slice()).offset;
        if (reference.name.offset >= start) return null;

        const name = reference.name.text(source);

        if (body_scope_of(semantic, function, body)) |block| {
            if (binding_spaced(semantic, source, block, name, reference.namespace)) |found| {
                return found;
            }
        }

        const hoisted = binding_spaced(semantic, source, function, name, reference.namespace) orelse
            return null;

        if (semantic.at(hoisted).from == 0) return null;
        return hoisted;
    }

    fn check_typed(linter: *const Linter, node: u32, held: Binding) bool {
        assert(node <= node_count_max);
        assert(held.name.length > 0);

        const machine = linter.machine;
        const tree = &machine.tree;
        const conditional = machine.semantic.scope_at(held.scope).node;

        assert(tree.count() <= node_count_max);

        if (node == none) return false;
        if (held.node == none) return false;
        if (conditional == none) return false;
        if (role_at(tree, held.node) != .infer_type) return false;
        if (role_at(tree, conditional) != .conditional_type) return false;

        var child = node;

        for (0..tree.count()) |_| {
            if (child >= tree.count()) return false;

            const parent = tree.at(child).parent;
            if (parent == none) return false;
            if (parent == conditional) return tree.child_first_of(conditional) == child;

            child = parent;
        }

        return false;
    }

    fn undefined_rows(linter: *Linter, source: []const u8) !void {
        const references = linter.machine.semantic.reference_slice();

        assert(references.len <= reference_count_max);
        assert(source.len <= source_bytes_max);

        for (references) |held| {
            switch (held.resolution) {
                .bound, .builtin, .external => continue,
                .maybe, .unresolved => {},
            }

            if (held.namespace == .type) continue;
            if (linter.signature_bound(source, &held) != null) continue;
            if (linter.aliased(held.node)) continue;
            if (linter.signed(source, held.node, held.name.text(source))) continue;
            if (linter.role_above_is(held.node, 1, .type_predicate)) continue;
            if (linter.default_exported(held.node)) continue;
            if (linter.namespace_exported(source, held.node)) continue;

            if (typeof_at(source, held.name.offset)) {
                if (!linter.queried(held.node)) {
                    if (!linter.role_above_is(held.node, 1, .member_expression)) continue;
                }
            }

            try linter.push("no-undef", held.name.offset);
        }
    }

    fn unused_rows(linter: *Linter, source: []const u8) !void {
        assert(source.len <= std.math.maxInt(u32));

        const machine = linter.machine;
        if (machine.declaration) return;

        const bindings = machine.semantic.binding_slice();

        assert(bindings.len <= binding_count_max);

        for (bindings, 0..) |held, position| {
            const index: u32 = @intCast(position);
            const name = held.name.text(source);

            if (!reportable(held.kind)) continue;
            if (linter.names_itself(index)) continue;
            if (linter.factory(held.kind, name)) continue;
            if (ignorable(held.kind, name)) continue;
            if (linter.exported(held.name)) continue;
            if (linter.global_declared(held.scope)) continue;
            if (linter.ambient_allowed(held)) continue;

            const group = linter.group_of(source, index);
            if (group.exported) continue;

            if (group.merged) {
                if (index != group.first) continue;
                if (group.read) continue;

                try linter.push("no-unused-vars", held.name.offset);

                continue;
            }

            if (group.count > 1) {
                if (index != group.first) continue;
                if (group.read) continue;
            } else {
                if (linter.read(index)) continue;
            }

            if (linter.looped_return(held.node)) continue;

            try linter.push("no-unused-vars", held.name.offset);
        }

        try linter.unused_parameters(source);
    }

    fn looped_return(linter: *const Linter, node: u32) bool {
        const tree = &linter.machine.tree;

        if (node == none) return false;
        if (node >= tree.count()) return false;

        const loop = tree.at(node).parent;
        if (loop == none) return false;
        if (tree.kind_at(loop) != .for_in_statement) return false;
        return returns_first(tree, loop, node);
    }

    fn iterated_return(linter: *const Linter, reference: Reference, held: Binding) bool {
        assert(reference.context == .store);
        assert(held.name.length > 0);

        const tree = &linter.machine.tree;
        var child = reference.node;

        assert(reference.node < tree.count());

        switch (held.kind) {
            .@"const", .let, .parameter, .@"var" => {},
            else => return false,
        }

        for (0..tree.count() + 1) |_| {
            const parent = tree.at(child).parent;
            if (parent == none) return false;

            switch (role_at(tree, parent)) {
                .array_pattern, .object_pattern, .parenthesized_expression => {},
                .for_in_statement => return returns_first(tree, parent, child),
                else => return false,
            }

            child = parent;
        }

        return false;
    }

    fn unused_parameters(linter: *Linter, source: []const u8) !void {
        assert(source.len <= std.math.maxInt(u32));

        const semantic = &linter.machine.semantic;
        const bindings = semantic.binding_slice();

        assert(semantic.scope_slice().len <= linter.used.capacity);
        assert(bindings.len <= binding_count_max);

        linter.used.clearRetainingCapacity();
        linter.used.appendNTimesAssumeCapacity(0, semantic.scope_slice().len);

        const used = linter.used.items;

        for (bindings, 0..) |held, position| {
            const index: u32 = @intCast(position);
            const property = held.kind == .parameter_property;
            const counted = property or held.kind == .parameter;
            if (!counted) continue;
            if (held.ext.parameter == parameter_none) continue;

            if (!property) {
                if (!linter.read(index)) {
                    if (!linter.shadowed(source, index)) continue;
                }
            }

            if (spread_at(source, held.name.offset)) continue;

            used[held.scope] = @max(used[held.scope], held.ext.parameter);
        }

        for (bindings, 0..) |held, position| {
            const index: u32 = @intCast(position);

            if (held.kind != .parameter) continue;
            if (held.ext.parameter == parameter_none) continue;
            if (linter.parameter_repeated(source, index)) continue;

            if (held.ext.parameter < used[held.scope]) {
                if (!linter.patterned(held.node)) continue;
            }

            if (linter.parameter_read(source, index)) continue;

            if (linter.shadowed_declared(source, index)) {
                if (linter.group_of(source, index).read) continue;
            }

            if (ignorable(held.kind, held.name.text(source))) continue;

            if (!spread_at(source, held.name.offset)) {
                if (linter.accessed(source, held.scope, "override")) continue;
            }

            if (linter.accessed(source, held.scope, "set")) continue;

            try linter.push("no-unused-vars", held.name.offset);
        }
    }

    fn redeclared_rows(linter: *Linter, source: []const u8) !void {
        assert(source.len <= std.math.maxInt(u32));

        const semantic = &linter.machine.semantic;
        const bindings = semantic.binding_slice();
        const script = semantic.scope_slice()[0].kind == .global;

        assert(bindings.len <= binding_count_max);
        assert(semantic.scope_slice().len >= 1);

        for (bindings, 0..) |held, position| {
            const index: u32 = @intCast(position);
            const name = held.name.text(source);
            const global_shadow = script and shadows_a_global(name);

            if (!linter.redeclares(held)) continue;

            if (linter.names_itself(index)) {
                if (global_shadow) try linter.push("no-redeclare", held.name.offset);

                continue;
            }

            var earlier = false;

            for (bindings[0..index], 0..) |seen, before| {
                if (seen.scope != held.scope) continue;
                if (!std.mem.eql(u8, seen.name.text(source), name)) continue;

                const own = linter.names_itself(@intCast(before));

                earlier = linter.redeclares(seen) and !own;
            }

            if (!earlier) {
                if (!global_shadow) continue;
            }

            try linter.push("no-redeclare", held.name.offset);
        }
    }

    fn redeclares(linter: *const Linter, held: Binding) bool {
        const tree = &linter.machine.tree;

        assert(tree.count() <= node_count_max);
        assert(held.scope < linter.machine.semantic.scope_count());

        if (declares(held.kind)) return true;
        if (held.kind != .type_parameter) return false;
        if (held.node == none) return false;
        if (held.node >= tree.count()) return false;
        return role_at(tree, held.node) == .infer_type;
    }

    fn factory(linter: *const Linter, kind: BindingKind, name: []const u8) bool {
        assert(name.len > 0);
        assert(reportable(kind));

        if (!linter.machine.jsx) return false;

        switch (kind) {
            .import, .import_default, .import_namespace => {},
            else => return false,
        }

        return std.mem.eql(u8, name, "React") or std.mem.eql(u8, name, "h");
    }

    fn default_exported(linter: *const Linter, node: u32) bool {
        assert(node <= node_count_max);

        const tree = &linter.machine.tree;
        const parent = tree.at(node).parent;

        assert(node < tree.count());
        assert(tree.count() <= node_count_max);

        if (parent == none) return false;
        return role_at(tree, parent) == .export_statement;
    }

    fn namespace_exported(linter: *const Linter, source: []const u8, node: u32) bool {
        assert(node <= node_count_max);

        const machine = linter.machine;
        const tree = &machine.tree;
        const parent = tree.at(node).parent;

        assert(node < tree.count());
        assert(source.len <= source_bytes_max);

        if (parent == none) return false;
        if (role_at(tree, parent) != .export_statement) return false;

        const tokens = machine.tokens.slice();
        const start = tree.at(parent).token_start;
        const end = tree.at(parent).token_end;
        const words = [_][]const u8{ "export", "as", "namespace" };
        var scan = start;

        assert(end <= tokens.len);

        for (words) |word| {
            for (0..end - start) |_| {
                if (scan >= end) return false;

                if (tokens[scan].kind != .comment) {
                    if (tokens[scan].kind != .newline) break;
                }

                scan += 1;
            }

            if (scan >= end) return false;
            if (!std.mem.eql(u8, tokens[scan].text(source), word)) return false;

            scan += 1;
        }

        return true;
    }

    fn global_declared(linter: *const Linter, scope: u32) bool {
        assert(scope <= scope_count_max);

        const machine = linter.machine;
        const scopes = machine.semantic.scope_slice();
        var held = scope;

        assert(scope < scopes.len);
        assert(scopes.len <= scope_count_max);

        if (!machine.typed) return false;

        for (0..scopes.len + 1) |_| {
            const found = scopes[held];

            if (found.kind == .ambient) {
                if (found.node != none) {
                    if (machine.tree.kind_at(found.node) == .statement_block) return true;
                }
            }

            if (found.parent == none) return false;

            held = found.parent;
        }

        return false;
    }

    fn ambient_allowed(linter: *const Linter, held: Binding) bool {
        if (!linter.machine.typed) return false;
        assert(held.name.length > 0);

        return switch (held.kind) {
            .class => linter.declare_written(held.node),
            .interface, .type_alias => linter.module_declared(held.scope),
            .namespace => linter.declare_written(held.node) or linter.dotted(held.node) or
                linter.module_declared(held.scope),
            .signature => linter.declare_written(held.node) or linter.module_declared(held.scope),
            .type_parameter => linter.ambient_interfaced(held.scope),
            else => false,
        };
    }

    fn ambient_interfaced(linter: *const Linter, scope: u32) bool {
        assert(scope <= scope_count_max);

        const machine = linter.machine;
        const scopes = machine.semantic.scope_slice();
        const tree = &machine.tree;
        const held = scopes[scope];

        assert(scope < scopes.len);
        assert(machine.typed);

        if (held.node == none) return false;
        if (tree.kind_at(held.node) != .interface_declaration) return false;
        if (held.parent == none) return false;

        const parent = scopes[held.parent];
        if (parent.kind != .ambient) return false;
        if (parent.node == none) return false;

        return switch (tree.kind_at(parent.node)) {
            .internal_module, .module => true,
            else => false,
        };
    }

    fn declare_written(linter: *const Linter, node: u32) bool {
        const tree = &linter.machine.tree;

        assert(linter.machine.typed);

        if (node == none) return false;

        assert(node < tree.count());

        const parent = tree.at(node).parent;
        if (parent == none) return false;
        return tree.kind_at(parent) == .ambient_declaration;
    }

    fn dotted(linter: *const Linter, node: u32) bool {
        assert(node <= node_count_max);

        const tree = &linter.machine.tree;
        var child = if (node == none) null else tree.child_first_of(node);

        assert(linter.machine.typed);

        for (0..tree.count()) |_| {
            const held = child orelse return false;
            if (tree.kind_at(held) == .nested_identifier) return true;

            child = tree.sibling_next_of(held);
        }

        return false;
    }

    fn module_declared(linter: *const Linter, scope: u32) bool {
        assert(scope <= scope_count_max);

        const machine = linter.machine;
        const scopes = machine.semantic.scope_slice();
        var held = scope;

        assert(scope < scopes.len);
        assert(scopes.len <= scope_count_max);
        assert(machine.typed);

        for (0..scopes.len + 1) |_| {
            const found = scopes[held];

            if (found.kind == .ambient) {
                if (found.node != none) {
                    if (linter.module_unexported(found.node)) return true;
                }
            }

            if (found.parent == none) return false;

            held = found.parent;
        }

        return false;
    }

    fn module_unexported(linter: *const Linter, node: u32) bool {
        const tree = &linter.machine.tree;

        assert(node < tree.count());
        assert(linter.machine.typed);

        switch (tree.kind_at(node)) {
            .statement_block => return true,
            .internal_module, .module => {},
            else => return false,
        }

        var block: ?u32 = null;
        var child = tree.child_first_of(node);

        for (0..tree.count()) |_| {
            const held = child orelse break;
            if (tree.kind_at(held) == .nested_identifier) return true;

            if (tree.kind_at(held) == .statement_block) block = held;

            child = tree.sibling_next_of(held);
        }

        child = tree.child_first_of(block orelse return true);

        for (0..tree.count()) |_| {
            const held = child orelse return true;
            if (role_at(tree, held) == .export_statement) return false;

            child = tree.sibling_next_of(held);
        }

        return true;
    }

    fn exported(linter: *const Linter, name: Span) bool {
        const facts = linter.machine.semantic.fact_slice();

        assert(facts.len <= fact_count_max);
        assert(name.length > 0);

        for (facts) |held| {
            switch (held.kind) {
                .export_default, .export_named => {},
                else => continue,
            }

            if (std.meta.eql(held.local, name)) return true;
        }

        return false;
    }

    fn group_of(linter: *const Linter, source: []const u8, index: u32) Group {
        assert(source.len <= std.math.maxInt(u32));
        assert(index < none);

        const bindings = linter.machine.semantic.binding_slice();
        const held = bindings[index];
        const name = held.name.text(source);

        var group: Group = .{
            .count = 1,
            .exported = false,
            .first = index,
            .merged = merges(held.kind),
            .read = linter.read(index),
        };

        var counted: u32 = 1;

        for (bindings, 0..) |seen, position| {
            const other: u32 = @intCast(position);
            if (other == index) continue;
            if (seen.scope != held.scope) continue;
            if (!std.mem.eql(u8, seen.name.text(source), name)) continue;
            if (linter.names_itself(other)) continue;

            group.exported = group.exported or linter.exported(seen.name);
            group.merged = group.merged or merges(seen.kind);
            group.read = group.read or linter.read(other);
            group.first = @min(group.first, other);
            counted += 1;
        }

        group.merged = group.merged and counted > 1;
        group.count = counted;

        assert(group.first <= index);
        assert(counted >= 1);

        return group;
    }

    fn read(linter: *const Linter, index: u32) bool {
        assert(index < linter.heads.items.len);

        const semantic = &linter.machine.semantic;
        const held = semantic.binding_slice()[index];
        const references = semantic.reference_slice();
        var cursor = linter.heads.items[index];

        assert(index < semantic.count());
        assert(linter.heads.items.len == semantic.count());

        for (0..references.len + 1) |_| {
            if (cursor == none) return false;

            const reference = references[cursor];

            cursor = linter.nexts.items[cursor];

            if (reference.context != .load) {
                if (linter.iterated_return(reference, held)) return true;

                continue;
            }

            if (linter.predicate_subject(reference)) continue;
            if (linter.read_ignored(reference, held, index)) continue;
            if (linter.recursive(reference, held)) continue;
            return true;
        }

        return false;
    }

    fn read_ignored(linter: *const Linter, reference: Reference, held: Binding, index: u32) bool {
        assert(reference.context == .load);
        assert(index < linter.heads.items.len);

        if (reference.namespace == .type) return false;
        if (!variable(held.kind)) return false;
        if (linter.self_reassigned(reference, held, index)) return true;
        return linter.read_discarded(reference, index);
    }

    fn predicate_subject(linter: *const Linter, reference: Reference) bool {
        assert(reference.name.end() > reference.name.offset);
        assert(reference.scope != none);

        if (reference.namespace != .value) return false;
        return linter.role_above_is(reference.node, 1, .type_predicate);
    }

    fn self_reassigned(
        linter: *const Linter,
        reference: Reference,
        held: Binding,
        index: u32,
    ) bool {
        assert(reference.context == .load);
        assert(index < none);
        assert(held.name.length > 0);

        const tree = &linter.machine.tree;
        var used = true;
        var updated = false;
        var child = reference.node;

        assert(reference.node < tree.count());

        for (0..tree.count() + 1) |_| {
            const parent = tree.at(child).parent;
            if (parent == none) break;

            switch (tree.kind_at(parent)) {
                .field_definition, .jsx_expression, .public_field_definition => return false,
                .variable_declarator => return false,
                .formal_parameters, .optional_parameter, .required_parameter => {
                    if (updated) return linter.read_discarded(reference, index);
                },
                .call_expression => {
                    if (tree.kind_at(child) == .arguments) return false;
                },
                .update_expression => {
                    if (!linter.for_headed(parent)) {
                        if (!membered(tree, child)) {
                            used = false;
                            updated = true;
                        }
                    }
                },
                .assignment_expression, .augmented_assignment_expression => {
                    switch (linter.assigned(parent, reference, held, index)) {
                        .other => return false,
                        .own => used = false,
                        .pattern => {},
                    }
                },
                .do_statement => {
                    if (child == child_last(tree, parent)) return false;
                },
                .if_statement => {
                    if (child == tree.at(parent).child_first) return false;
                },
                .while_statement => return child != tree.at(parent).child_first and !used,
                .for_in_statement, .function_declaration, .generator_function_declaration => break,
                .expression_statement => {
                    if (looped(tree, parent)) return false;
                    return !returned(tree, parent) and !used;
                },
                .arrow_function => {
                    if (arrow_expressed(tree, parent)) return false;
                },
                .return_statement => return linter.returns_itself(parent, held),
                .yield_expression => return false,
                else => {},
            }

            child = parent;
        }

        return !used;
    }

    fn assigned(
        linter: *const Linter,
        assignment: u32,
        reference: Reference,
        held: Binding,
        index: u32,
    ) Assigned {
        assert(assignment < none);
        assert(index < none);
        assert(held.name.length > 0);
        assert(reference.name.length > 0);

        const tree = &linter.machine.tree;
        const target = unparenthesized(tree, tree.at(assignment).child_first);

        assert(assignment < tree.count());
        assert(target != none);

        switch (tree.kind_at(target)) {
            .identifier_node => {
                if (!linter.refers(target, index)) return .other;

                const scope = linter.functional(reference.scope);
                if (scope != linter.functional(held.scope)) return .other;
                return .own;
            },
            .member_expression, .subscript_expression => return .other,
            .as_expression, .non_null_expression, .satisfies_expression, .type_assertion => {
                if (membered(tree, target)) return .other;
                return .pattern;
            },
            else => return .pattern,
        }
    }

    fn refers(linter: *const Linter, node: u32, index: u32) bool {
        assert(index < linter.heads.items.len);

        const references = linter.machine.semantic.reference_slice();
        var cursor = linter.heads.items[index];

        assert(node < linter.machine.tree.count());

        for (0..references.len + 1) |_| {
            if (cursor == none) return false;
            if (references[cursor].node == node) return true;

            cursor = linter.nexts.items[cursor];
        }

        return false;
    }

    fn returns_itself(linter: *const Linter, statement: u32, held: Binding) bool {
        assert(statement < none);
        assert(held.name.length > 0);

        const tree = &linter.machine.tree;
        var arrowed = false;
        var child = statement;

        assert(statement < tree.count());
        assert(tree.kind_at(statement) == .return_statement);

        for (0..tree.count() + 1) |_| {
            const parent = tree.at(child).parent;
            if (parent == none) return false;

            switch (tree.kind_at(parent)) {
                .function_declaration, .function_expression => {
                    return held.kind == .function and held.node == parent;
                },
                .generator_function, .generator_function_declaration => {
                    return held.kind == .function and held.node == parent;
                },
                .method_definition, .program => return false,
                .arrow_function => arrowed = true,
                .variable_declarator => {
                    if (arrowed) return held.node == tree.at(parent).child_first;
                },
                else => {},
            }

            child = parent;
        }

        return false;
    }

    fn read_discarded(linter: *const Linter, reference: Reference, index: u32) bool {
        assert(reference.name.length > 0);

        const tree = &linter.machine.tree;
        var current = reference.node;
        var below: u32 = none;

        assert(reference.node < tree.count());
        assert(index < linter.heads.items.len);

        for (0..tree.count() + 1) |_| {
            const direct = relevant_child(tree, current);
            const above = tree.at(direct).parent;
            if (above == none) return false;

            const kind = tree.kind_at(current);
            const grand = tree.kind_at(above);
            const invoked = grand == .call_expression or grand == .new_expression;

            if (invoked) {
                if (current != reference.node) return false;
            } else if (linter.discard_kept(current, below, grand, index)) {
                return false;
            } else if (grand == .sequence_expression) {
                if (!sequence_passes(tree, current, kind)) {
                    if (direct != child_last(tree, above)) return true;
                }
            } else {}

            below = direct;
            current = above;
        }

        return false;
    }

    fn discard_kept(linter: *const Linter, current: u32, below: u32, grand: Kind, index: u32) bool {
        if (!grand.is_node()) return false;

        const tree = &linter.machine.tree;

        assert(current < tree.count());
        assert(index < linter.heads.items.len);

        switch (tree.kind_at(current)) {
            .member_expression, .subscript_expression => return grand == .update_expression,
            .assignment_expression, .augmented_assignment_expression => {
                const target = unparenthesized(tree, tree.at(current).child_first);
                if (tree.kind_at(target) != .identifier_node) return true;
                return !linter.refers(target, index);
            },
            .ternary_expression => return below == tree.at(current).child_first,
            .binary_expression => {
                if (below != tree.at(current).child_first) return false;
                if (!assigning(tree, child_last(tree, current))) return false;
                return linter.guards(current);
            },
            else => return false,
        }
    }

    fn guards(linter: *const Linter, binary: u32) bool {
        assert(binary < none);

        const tree = &linter.machine.tree;
        const raw = linter.machine.raw.const_slice();
        const left = tree.at(binary).child_first;
        const right = child_last(tree, binary);

        assert(left != none);
        assert(right != none);

        for (tree.at(left).token_end..tree.at(right).token_start) |position| {
            switch (raw[position]) {
                .comment => continue,
                .ampersand_ampersand, .bar_bar, .question_question => return true,
                .greater, .greater_equal, .in_keyword, .instanceof_keyword => return true,
                .less, .less_equal => return true,
                else => return false,
            }
        }

        return false;
    }

    fn for_headed(linter: *const Linter, update: u32) bool {
        assert(update < none);

        const tree = &linter.machine.tree;
        var child = update;

        assert(update < tree.count());
        assert(tree.kind_at(update) == .update_expression);

        for (0..tree.count() + 1) |_| {
            const parent = tree.at(child).parent;
            if (parent == none) return false;

            if (tree.kind_at(parent) == .for_statement) {
                return switch (linter.for_part(parent, child)) {
                    .test_part, .update_part => true,
                    .body_part, .init_part => false,
                };
            }

            if (stated(tree, parent)) return false;

            child = parent;
        }

        return false;
    }

    fn for_part(linter: *const Linter, statement: u32, child: u32) ForPart {
        assert(child < none);

        const tree = &linter.machine.tree;
        const raw = linter.machine.raw.const_slice();
        const start = tree.at(child).token_start;
        var depth: u32 = 0;
        var semicolons: u32 = 0;

        assert(tree.kind_at(statement) == .for_statement);
        assert(tree.at(child).parent == statement);

        for (tree.at(statement).token_start..tree.at(statement).token_end) |position| {
            switch (raw[position]) {
                .brace_open, .bracket_open, .paren_open, .substitution_start => depth += 1,
                .brace_close, .bracket_close, .paren_close => {
                    depth -|= 1;

                    if (depth == 0) return if (start < position) .update_part else .body_part;
                },
                .semicolon => {
                    if (depth != 1) continue;
                    if (start < position) return if (semicolons == 0) .init_part else .test_part;

                    semicolons += 1;
                },
                else => {},
            }
        }

        return .body_part;
    }

    fn recursive(linter: *const Linter, reference: Reference, held: Binding) bool {
        assert(held.name.length > 0);

        const body = linter.self_body(held) orelse return false;
        const machine = linter.machine;

        assert(body != none);
        assert(reference.node != none);

        return inside(&machine.tree, reference.node, body);
    }

    fn self_body(linter: *const Linter, held: Binding) ?u32 {
        assert(held.node != none);
        assert(held.scope != none);

        switch (held.kind) {
            .class, .function, .type_parameter => return held.node,
            .@"const", .let, .@"var" => {},
            else => return null,
        }

        const declarator = linter.parent_at(held.node);
        if (declarator == none) return null;
        if (linter.role_of(declarator) != .variable_declarator) return null;

        const value = linter.child_last_at(declarator);

        return switch (linter.role_of(value)) {
            .arrow_function, .class, .function_expression => value,
            else => null,
        };
    }

    fn parent_at(linter: *const Linter, node: u32) u32 {
        const machine = linter.machine;

        assert(node != none);

        return machine.tree.at(node).parent;
    }

    fn child_last_at(linter: *const Linter, node: u32) u32 {
        const machine = linter.machine;

        assert(node != none);

        return child_last(&machine.tree, node);
    }

    fn role_of(linter: *const Linter, node: u32) Role {
        const machine = linter.machine;

        assert(node != none);

        return role_at(&machine.tree, node);
    }

    fn role_above_is(linter: *const Linter, node: u32, steps: u32, role: Role) bool {
        assert(node <= node_count_max);

        const machine = linter.machine;

        assert(steps >= 1);
        assert(steps <= 2);

        const held = role_above(&machine.tree, node, steps) orelse return false;
        return held == role;
    }

    fn functional(linter: *const Linter, scope: u32) u32 {
        assert(scope <= scope_count_max);

        const scopes = linter.machine.semantic.scope_slice();
        var held = scope;

        assert(scope < scopes.len);
        assert(scopes.len <= scope_count_max);

        for (0..scopes.len + 1) |_| {
            const found = scopes[held];

            switch (found.kind) {
                .function, .global, .module => return held,
                else => {},
            }

            if (found.parent == none) return held;

            held = found.parent;
        }

        return held;
    }

    fn names_itself(linter: *const Linter, index: u32) bool {
        assert(index < none);

        const semantic = &linter.machine.semantic;
        const held = semantic.binding_slice()[index];

        assert(index < semantic.count());
        assert(held.scope < semantic.scope_slice().len);

        return semantic.scope_slice()[held.scope].node == held.node;
    }

    fn aliased(linter: *const Linter, node: u32) bool {
        const machine = linter.machine;
        if (!machine.typed) return false;
        if (node == none) return false;

        const tree = &machine.tree;
        var held = node;

        assert(tree.count() <= node_count_max);

        for (0..tree.count()) |_| {
            if (held >= tree.count()) return false;

            const found = tree.at(held);
            if (found.parent == none) return false;
            if (found.parent >= tree.count()) return false;

            const parent = tree.at(found.parent);
            if (parent.kind == .import_alias) return true;
            if (parent.kind != .nested_identifier) return false;

            held = found.parent;
        }

        return false;
    }

    fn signed(linter: *const Linter, source: []const u8, node: u32, name: []const u8) bool {
        assert(source.len <= std.math.maxInt(u32));

        const machine = linter.machine;
        if (!machine.typed) return false;
        if (node == none) return false;

        const tree = &machine.tree;
        var held = node;

        assert(tree.count() <= node_count_max);
        assert(name.len > 0);

        for (0..tree.count()) |_| {
            if (held >= tree.count()) return false;

            const parent = tree.at(held).parent;
            if (parent == none) return false;
            if (parent >= tree.count()) return false;

            switch (role_at(tree, parent)) {
                .call_signature, .function_signature, .function_type, .method_signature => {
                    if (linter.parameter_named(source, parent, name)) return true;
                },
                else => {},
            }

            held = parent;
        }

        return false;
    }

    fn parameter_named(
        linter: *const Linter,
        source: []const u8,
        signed_node: u32,
        name: []const u8,
    ) bool {
        assert(source.len <= std.math.maxInt(u32));
        assert(signed_node < none);

        const tree = &linter.machine.tree;
        const tokens = linter.machine.tokens.slice();
        var child = tree.at(signed_node).child_first;

        assert(signed_node < tree.count());
        assert(name.len > 0);

        for (0..tree.count()) |_| {
            if (child == none) return false;
            if (role_at(tree, child) == .formal_parameters) break;

            child = tree.at(child).sibling_next;
        }

        if (child == none) return false;

        var parameter = tree.at(child).child_first;

        for (0..tree.count()) |_| {
            if (parameter == none) return false;

            const start = tree.at(parameter).token_start;

            if (start < tokens.len) {
                const token = tokens[start];

                if (token.kind == .identifier) {
                    if (std.mem.eql(u8, token.text(source), name)) return true;
                }
            }

            parameter = tree.at(parameter).sibling_next;
        }

        return false;
    }

    fn queried(linter: *const Linter, node: u32) bool {
        const machine = linter.machine;
        if (!machine.typed) return false;
        if (node == none) return false;

        const tree = &machine.tree;
        var held = node;

        assert(tree.count() <= node_count_max);

        for (0..tree.count()) |_| {
            if (held >= tree.count()) return false;

            const found = tree.at(held);
            if (found.parent == none) return false;
            if (found.parent >= tree.count()) return false;

            const parent = tree.at(found.parent);
            if (parent.kind == .type_query) return true;

            switch (parent.kind) {
                .instantiation_expression, .member_expression => {},
                else => return false,
            }

            held = found.parent;
        }

        return false;
    }

    fn patterned(linter: *const Linter, node: u32) bool {
        const machine = linter.machine;

        assert(node != none);

        return pattern_above(&machine.tree, node);
    }

    fn accessed(linter: *const Linter, source: []const u8, scope: u32, word: []const u8) bool {
        assert(source.len <= std.math.maxInt(u32));
        assert(scope <= scope_count_max);

        const head = linter.signature(source, scope) orelse return false;
        var words = std.mem.tokenizeAny(u8, head, ascii_whitespace);

        assert(word.len > 0);
        assert(head.len <= source.len);

        for (0..head.len + 1) |_| {
            const found = words.next() orelse return false;
            if (std.mem.eql(u8, found, word)) return words.next() != null;
        }

        return false;
    }

    fn signature(linter: *const Linter, source: []const u8, scope: u32) ?[]const u8 {
        assert(scope <= scope_count_max);

        const machine = linter.machine;
        const held = machine.semantic.scope_slice()[scope];

        assert(scope < machine.semantic.scope_slice().len);

        if (held.node == none) return null;
        if (held.node >= machine.tree.count()) return null;

        const span = machine.tree.at(held.node).span(Token, machine.tokens.slice());
        if (span.end() > source.len) return null;

        const text = span.text(source);
        const paren = std.mem.findScalar(u8, text, '(') orelse return text;

        assert(paren < text.len);

        return text[0..paren];
    }

    fn parameter_repeated(linter: *const Linter, source: []const u8, index: u32) bool {
        assert(source.len <= std.math.maxInt(u32));
        assert(index < none);

        const bindings = linter.machine.semantic.binding_slice();
        const held = bindings[index];
        const name = held.name.text(source);

        assert(index < bindings.len);
        assert(held.kind == .parameter);

        for (bindings[0..index]) |found| {
            if (found.scope != held.scope) continue;
            if (found.kind != .parameter) continue;
            if (std.mem.eql(u8, found.name.text(source), name)) return true;
        }

        return false;
    }

    fn parameter_read(linter: *const Linter, source: []const u8, index: u32) bool {
        assert(source.len <= std.math.maxInt(u32));
        assert(index < none);

        const bindings = linter.machine.semantic.binding_slice();
        const held = bindings[index];
        const name = held.name.text(source);

        assert(index < bindings.len);
        assert(held.kind == .parameter);

        if (linter.read(index)) return true;

        for (bindings[index + 1 ..], index + 1..) |found, position| {
            if (found.scope != held.scope) continue;
            if (found.kind != .parameter) continue;
            if (!std.mem.eql(u8, found.name.text(source), name)) continue;
            if (linter.read(@intCast(position))) return true;
        }

        return false;
    }

    fn shadowed_declared(linter: *const Linter, source: []const u8, index: u32) bool {
        assert(source.len <= std.math.maxInt(u32));
        assert(index < none);

        const bindings = linter.machine.semantic.binding_slice();
        const held = bindings[index];
        const name = held.name.text(source);

        assert(index < bindings.len);
        assert(name.len > 0);

        for (bindings[index + 1 ..]) |found| {
            if (found.scope != held.scope) continue;
            if (found.kind == .parameter) continue;
            if (std.mem.eql(u8, found.name.text(source), name)) return true;
        }

        return false;
    }

    fn shadowed(linter: *const Linter, source: []const u8, index: u32) bool {
        assert(source.len <= std.math.maxInt(u32));
        assert(index < none);

        const bindings = linter.machine.semantic.binding_slice();
        const held = bindings[index];
        const name = held.name.text(source);

        assert(index < bindings.len);
        assert(name.len > 0);

        for (bindings[index + 1 ..]) |found| {
            if (found.scope != held.scope) continue;
            if (std.mem.eql(u8, found.name.text(source), name)) return true;
        }

        return false;
    }
};

const Machine = struct {
    declaration: bool,
    events: Events,
    jsx: bool,
    parser: Parser,
    raw: ArrayType(Kind),
    semantic: Semantic,
    tokens: Tokens,
    tree: Tree,
    typed: bool,

    fn create(gpa: std.mem.Allocator) !*Machine {
        const machine = try gpa.create(Machine);
        errdefer gpa.destroy(machine);

        try machine.events.init(gpa, event_count_max);
        errdefer machine.events.deinit(gpa);

        machine.raw = try .init(gpa, token_count_max);
        errdefer machine.raw.deinit(gpa);

        try machine.semantic.init(gpa, &.{
            .binding_count_max = binding_count_max,
            .fact_count_max = fact_count_max,
            .reference_count_max = reference_count_max,
            .scope_count_max = scope_count_max,
        });

        errdefer machine.semantic.deinit(gpa);

        machine.tokens = try .init(gpa, token_count_max);
        errdefer machine.tokens.deinit(gpa);

        machine.tree = try .init(gpa, node_count_max, diagnostic_count_max);
        errdefer machine.tree.deinit(gpa);

        machine.declaration = false;
        machine.jsx = false;
        machine.typed = false;

        assert(machine.raw.capacity() == machine.tokens.items.capacity());
        assert(machine.tree.count() == 0);

        return machine;
    }

    fn destroy(machine: *Machine, gpa: std.mem.Allocator) void {
        assert(machine.raw.capacity() == token_count_max);
        assert(machine.tokens.items.capacity() == token_count_max);

        machine.tree.deinit(gpa);
        machine.tokens.deinit(gpa);
        machine.semantic.deinit(gpa);
        machine.raw.deinit(gpa);
        machine.events.deinit(gpa);
        gpa.destroy(machine);
    }

    fn run(
        machine: *Machine,
        source: []const u8,
        dialect: Dialect,
        module: ?ModuleKind,
    ) !Structure {
        assert(source.len <= std.math.maxInt(u32));

        machine.jsx = dialect.allows_jsx();
        machine.typed = dialect.typed();

        machine.tokens.clear();

        var lexed: Structure = .complete;

        lex(source, &machine.tokens, dialect) catch |err| switch (err) {
            error.Truncated => {
                assert(machine.tokens.items.full());

                lexed = .{ .truncated = .tokens };
            },
        };

        try raw_of(Kind, machine.tokens.slice(), &machine.raw);

        assert(machine.raw.count() == machine.tokens.count());

        const parsed = machine.parser.build(
            source,
            machine.tokens.slice(),
            machine.raw.const_slice(),
            &machine.events,
            &machine.tree,
            .{ .dialect = dialect, .goal = .module },
        );

        const built = machine.semantic.build(
            source,
            machine.tokens.slice(),
            machine.raw.const_slice(),
            &machine.tree,
            &.{ .globals = &globals, .module = module, .typed = dialect.typed() },
        );

        if (lexed != .complete) return lexed;
        if (parsed != .complete) return parsed;
        return built;
    }

    fn run_fixture(machine: *Machine, fixture: Fixture) !Structure {
        assert(fixture.name.len > 0);
        assert(fixture.source.len <= source_bytes_max);

        const name = fixture.name;

        machine.declaration = std.mem.endsWith(u8, name, ".d.ts") or
            std.mem.endsWith(u8, name, ".d.cts") or
            std.mem.endsWith(u8, name, ".d.mts");

        const dialect = fixture.dialect orelse .javascript;
        return machine.run(fixture.source, dialect, module_of_name(name));
    }
};

const OxlintWorker = struct {
    gpa: std.mem.Allocator,
    linter: Linter,
    shared: *const Shared,

    pub const Item = corpus.File;
    pub const Shared = struct { carried: *const oracle.Residue, golden_root: []const u8 };
    pub const Tally = struct { abstained: u32, compared: u32, differing: u32 };
    pub const weight = corpus.File.weight;

    pub fn init(worker: *OxlintWorker, gpa: std.mem.Allocator, shared: *const Shared) !void {
        assert(shared.golden_root.len > 0);

        worker.gpa = gpa;
        worker.shared = shared;
        worker.linter = try Linter.create(gpa);

        assert(worker.linter.found.items.len == 0);
    }

    pub fn deinit(worker: *OxlintWorker, gpa: std.mem.Allocator) void {
        assert(worker.shared.golden_root.len > 0);

        worker.linter.destroy(gpa);
        worker.* = undefined;
    }

    pub fn visit(worker: *OxlintWorker, file: *const corpus.File, tally: *Tally) !void {
        const shared = worker.shared;

        assert(file.name.len > 0);
        assert(tally.differing <= tally.compared);

        if (shared.carried.contains(file.name)) return;

        var held: Golden = undefined;

        if (!try golden_of(worker.gpa, shared.golden_root, file.name, &held)) {
            tally.abstained += 1;

            return;
        }

        defer held.deinit(worker.gpa);

        if (held.broken) return;

        const fixture = fixture_of(file);
        if (try worker.linter.machine.run_fixture(fixture) != .complete) return;

        const rows = try worker.linter.rows(fixture.source);

        tally.compared += 1;

        if (rows_equal(rows, held.rows.items)) {
            try tally_file.agree("semantic_javascript", "oxlint", file.name);

            return;
        }

        tally.differing += 1;
    }
};

const ResidueWorker = struct {
    gpa: std.mem.Allocator,
    linter: Linter,
    shared: *const Shared,

    pub const Item = corpus.File;
    pub const Shared = struct { carried: *const oracle.Residue, golden_root: []const u8 };
    pub const Tally = struct { named: u32 };
    pub const weight = corpus.File.weight;

    pub fn init(worker: *ResidueWorker, gpa: std.mem.Allocator, shared: *const Shared) !void {
        assert(shared.golden_root.len > 0);

        worker.gpa = gpa;
        worker.shared = shared;
        worker.linter = try Linter.create(gpa);

        assert(worker.linter.found.items.len == 0);
    }

    pub fn deinit(worker: *ResidueWorker, gpa: std.mem.Allocator) void {
        assert(worker.shared.golden_root.len > 0);

        worker.linter.destroy(gpa);
        worker.* = undefined;
    }

    pub fn visit(worker: *ResidueWorker, file: *const corpus.File, tally: *Tally) !void {
        const shared = worker.shared;

        assert(file.name.len > 0);
        assert(shared.golden_root.len > 0);

        if (!shared.carried.contains(file.name)) return;

        tally.named += 1;

        const fixture = fixture_of(file);
        const diverged = try diverges(worker.gpa, &worker.linter, shared.golden_root, fixture);

        try require(diverged, "{s} matches its corpus golden and needs no residue row", .{
            file.name,
        });
    }
};

const Row = struct {
    code: []const u8,
    offset: u32,

    fn less_than(context: void, left: Row, right: Row) bool {
        _ = context;
        assert(left.offset < std.math.maxInt(u32));
        assert(right.offset < std.math.maxInt(u32));

        const by_code = std.mem.order(u8, left.code, right.code);
        if (by_code != .eq) return by_code == .lt;
        return left.offset < right.offset;
    }
};

const ascii_whitespace = " \t\n\x0c\r";
const directive_blanks = " \t\n\x0b\x0c\r";
const directive_count_max: u32 = 1 << 12;
const directive_separators = ", \t\n\x0b\x0c\r";

const directive_words = [_]struct { []const u8, Directive }{
    .{ "disable-next-line", .disable_next_line },
    .{ "disable-line", .disable_line },
    .{ "disable", .disable },
    .{ "enable", .enable },
};

const binding_count_max: u32 = 1 << 16;
const diagnostic_count_max: u32 = 1 << 12;
const every_category = [_][]const u8{ "not-javascript", "oxlint", "scylla" };
const event_count_max: u32 = 1 << 21;
const fact_count_max: u32 = 1 << 14;
const file_count_max: u32 = 1 << 20;

const fixture_roots = [_][]const u8{
    "tests/fixtures/javascript-semantic",
    "tests/fixtures/typescript-semantic",
};

const globals = [_][]const u8{
    "AggregateError",
    "arguments",
    "Array",
    "ArrayBuffer",
    "AsyncDisposableStack",
    "Atomics",
    "BigInt",
    "BigInt64Array",
    "BigUint64Array",
    "Boolean",
    "DataView",
    "Date",
    "decodeURI",
    "decodeURIComponent",
    "DisposableStack",
    "encodeURI",
    "encodeURIComponent",
    "Error",
    "escape",
    "eval",
    "EvalError",
    "FinalizationRegistry",
    "Float16Array",
    "Float32Array",
    "Float64Array",
    "Function",
    "globalThis",
    "Infinity",
    "Int16Array",
    "Int32Array",
    "Int8Array",
    "Intl",
    "isFinite",
    "isNaN",
    "Iterator",
    "JSON",
    "Map",
    "Math",
    "NaN",
    "Number",
    "Object",
    "parseFloat",
    "parseInt",
    "Promise",
    "Proxy",
    "RangeError",
    "ReferenceError",
    "Reflect",
    "RegExp",
    "Set",
    "SharedArrayBuffer",
    "String",
    "SuppressedError",
    "Symbol",
    "SyntaxError",
    "TypeError",
    "Uint16Array",
    "Uint32Array",
    "Uint8Array",
    "Uint8ClampedArray",
    "undefined",
    "unescape",
    "URIError",
    "WeakMap",
    "WeakRef",
    "WeakSet",
};

const golden_bytes_max: u32 = 1 << 28;
const node_count_max: u32 = 1 << 19;
const none: u32 = std.math.maxInt(u32);
const oxlint_fixture_root = "tests/fixtures/golden-oxlint";
const path_bytes_max = 4096;
const reference_count_max: u32 = 1 << 18;
const report_count_max: u32 = 3;
const report_line_count_max: u32 = 24;
const residue_name = "residue-javascript-semantic.json";
const row_count_max: u32 = binding_count_max * 2 + reference_count_max;
const scope_count_max: u32 = 1 << 16;
const source_bytes_max: u32 = 1 << 26;
const step_count_max: u32 = 1 << 8;
const token_count_max: u32 = 1 << 19;

fn collect(gpa: std.mem.Allocator, root: []const u8, found: *std.ArrayList(Fixture)) !void {
    const io = std.testing.io;

    assert(root.len > 0);
    assert(found.items.len <= file_count_max);

    var directory = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| {
        switch (err) {
            error.FileNotFound => return,
            else => return err,
        }
    };

    defer directory.close(io);

    var walker = try corpus.Walker.init(gpa, directory);
    defer walker.deinit();

    var walked: u32 = 0;

    while (try walker.advance(io)) : (walked += 1) {
        assert(walked < file_count_max);

        const entry = walker.entry;
        const outcome = dialect_of(entry.basename) orelse continue;
        const limit: std.Io.Limit = .limited(source_bytes_max);
        const source = entry.dir.readFileAlloc(io, entry.basename, gpa, limit) catch continue;
        errdefer gpa.free(source);

        const name = try gpa.dupe(u8, entry.path);
        errdefer gpa.free(name);

        std.mem.replaceScalar(u8, name, '\\', '/');
        try found.append(gpa, .{ .dialect = outcome.dialect, .name = name, .source = source });
    }
}

fn module_of_name(name: []const u8) ?ModuleKind {
    assert(name.len > 0);

    if (std.mem.endsWith(u8, name, ".mjs")) return .module;
    if (std.mem.endsWith(u8, name, ".cjs")) return .script;
    return null;
}

fn dialect_of(basename: []const u8) ?Detected {
    assert(basename.len > 0);

    const extension = std.Io.Dir.path.extension(basename);

    assert(extension.len == 0 or extension[0] == '.');

    if (extension.len == 0) return null;

    const held = extension[1..];
    const untyped = [_][]const u8{ "cjs", "js", "mjs" };

    for (untyped) |plain| {
        if (std.mem.eql(u8, held, plain)) return .{ .dialect = null };
    }

    const dialect = Dialect.of_extension(held) orelse return null;
    return .{ .dialect = dialect };
}

fn fixture_free(gpa: std.mem.Allocator, fixture: Fixture) void {
    assert(fixture.name.len > 0);
    assert(fixture.source.len <= source_bytes_max);

    gpa.free(fixture.name);
    gpa.free(fixture.source);
}

fn fixture_less_than(_: void, left: Fixture, right: Fixture) bool {
    assert(left.name.len > 0);
    assert(right.name.len > 0);

    return std.mem.order(u8, left.name, right.name) == .lt;
}

fn fixtures(gpa: std.mem.Allocator) !std.ArrayList(Fixture) {
    var found: std.ArrayList(Fixture) = .empty;
    errdefer fixtures_free(gpa, &found);

    for (fixture_roots) |root| try collect(gpa, root, &found);

    std.mem.sort(Fixture, found.items, {}, fixture_less_than);

    assert(found.items.len <= file_count_max);
    if (found.items.len > 1) assert(!fixture_less_than({}, found.items[1], found.items[0]));

    return found;
}

fn fixtures_free(gpa: std.mem.Allocator, found: *std.ArrayList(Fixture)) void {
    assert(found.items.len <= found.capacity);
    assert(found.items.len <= file_count_max);

    for (found.items) |fixture| fixture_free(gpa, fixture);

    found.deinit(gpa);
    found.* = undefined;
}

fn require(condition: bool, comptime format: []const u8, arguments: anytype) !void {
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    if (condition) return;

    std.debug.print(format ++ "\n", arguments);

    return error.TestUnexpectedResult;
}

fn total(machine: *const Machine, fixture: Fixture) !void {
    assert(fixture.name.len > 0);

    const scopes = machine.semantic.scope_slice();
    const scope_count: u32 = @intCast(scopes.len);

    assert(scope_count >= 1);
    assert(scope_count <= scope_count_max);

    for (scopes) |held| {
        const parented = held.parent == none or held.parent < scope_count;

        try require(parented, "{s}: a scope parent is out of range", .{fixture.name});
    }

    for (machine.semantic.binding_slice()) |held| {
        const named = held.name.end() <= fixture.source.len;

        try require(held.scope < scope_count, "{s}: a binding scope is out of range", .{
            fixture.name,
        });

        try require(named, "{s}: a binding name is out of range", .{fixture.name});
    }
}

fn walks(machine: *const Machine, fixture: Fixture) !void {
    assert(fixture.name.len > 0);

    const scopes = machine.semantic.scope_slice();
    const bindings = machine.semantic.binding_slice();

    assert(scopes.len >= 1);
    assert(bindings.len <= binding_count_max);

    for (machine.semantic.reference_slice()) |held| {
        const index = switch (held.resolution) {
            .bound => |bound| bound,
            else => continue,
        };

        const binding = bindings[index];
        var scope = held.scope;
        var walked = false;

        for (0..step_count_max + 1) |_| {
            if (scope == none) break;

            if (scope == binding.scope) {
                walked = true;

                break;
            }

            scope = scopes[scope].parent;
        }

        try require(walked, "{s}: a reference resolves outside its own scope chain", .{
            fixture.name,
        });
    }
}

fn role_at(tree: *const Tree, node: u32) Role {
    assert(node != none);
    assert(node < tree.count());

    return role_of_kind(tree.kind_at(node));
}

fn role_above(
    tree: *const Tree,
    node: u32,
    steps: u32,
) ?Role {
    assert(node <= node_count_max);

    var held = node;

    assert(steps >= 1);
    assert(tree.count() <= node_count_max);

    for (0..steps) |_| {
        if (held >= tree.count()) return null;

        held = tree.at(held).parent;

        if (held == none) return null;
    }

    if (held >= tree.count()) return null;
    return role_at(tree, held);
}

fn looped(tree: *const Tree, statement: u32) bool {
    assert(statement < tree.count());

    var child = statement;

    assert(tree.kind_at(statement) == .expression_statement);

    for (0..tree.count() + 1) |_| {
        const parent = tree.at(child).parent;
        if (parent == none) return false;

        switch (tree.kind_at(parent)) {
            .for_in_statement, .for_statement, .while_statement => {
                return child == child_last(tree, parent);
            },
            .do_statement => return child == tree.at(parent).child_first,
            .arrow_function, .function_declaration, .function_expression => return false,
            .generator_function, .generator_function_declaration => return false,
            .method_definition, .program => return false,
            else => {},
        }

        child = parent;
    }

    return false;
}

fn returned(tree: *const Tree, statement: u32) bool {
    assert(statement < tree.count());

    var child = statement;

    assert(tree.kind_at(statement) == .expression_statement);

    for (0..tree.count() + 1) |_| {
        const parent = tree.at(child).parent;
        if (parent == none) return false;

        const kind = tree.kind_at(parent);
        if (kind == .return_statement) return true;

        switch (kind) {
            .arrow_function => {
                if (arrow_expressed(tree, parent)) return true;
            },
            .expression_statement => {},
            else => {
                if (stated(tree, parent)) return false;
            },
        }

        child = parent;
    }

    return false;
}

fn stated(tree: *const Tree, node: u32) bool {
    assert(node < tree.count());
    assert(tree.count() <= node_count_max);

    return switch (tree.kind_at(node)) {
        .break_statement, .continue_statement, .debugger_statement, .do_statement => true,
        .empty_statement, .expression_statement, .for_in_statement, .for_statement => true,
        .if_statement, .labeled_statement, .lexical_declaration, .return_statement => true,
        .switch_statement, .throw_statement, .try_statement, .variable_declaration => true,
        .while_statement, .with_statement => true,
        .statement_block => !function_body(tree, node),
        else => false,
    };
}

fn body_scope_of(semantic: *const Semantic, function: u32, body: u32) ?u32 {
    assert(function < semantic.scope_count());
    assert(body != none);

    for (function + 1..semantic.scope_count()) |index| {
        const held = semantic.scope_at(@intCast(index));
        if (held.parent == none) return null;
        if (held.parent < function) return null;

        if (held.parent == function) {
            if (held.node == body) {
                assert(index < std.math.maxInt(u32));

                return @intCast(index);
            }
        }
    }

    return null;
}

fn binding_spaced(
    semantic: *const Semantic,
    source: []const u8,
    scope: u32,
    name: []const u8,
    space: Namespace,
) ?u32 {
    assert(scope < semantic.scope_count());
    assert(name.len > 0);
    assert(source.len <= std.math.maxInt(u32));

    for ([_]Namespace{ .type, .value }) |namespace| {
        const found = semantic.binding_newest(source, scope, name, namespace) orelse continue;
        if (semantic.at(found).kind.binds_in(space)) return found;
    }

    return null;
}

fn function_body(tree: *const Tree, block: u32) bool {
    assert(block < tree.count());

    const parent = tree.at(block).parent;

    assert(tree.kind_at(block) == .statement_block);

    if (parent == none) return false;

    return switch (tree.kind_at(parent)) {
        .arrow_function, .class_static_block, .function_declaration, .function_expression => true,
        .generator_function, .generator_function_declaration, .method_definition => true,
        else => false,
    };
}

fn arrow_expressed(tree: *const Tree, arrow: u32) bool {
    assert(arrow < tree.count());

    const body = child_last(tree, arrow);

    assert(tree.kind_at(arrow) == .arrow_function);

    if (body == none) return false;
    return tree.kind_at(body) != .statement_block;
}

fn relevant_child(tree: *const Tree, node: u32) u32 {
    assert(node < tree.count());

    var held = node;

    assert(tree.count() <= node_count_max);

    for (0..tree.count() + 1) |_| {
        const parent = tree.at(held).parent;
        if (parent == none) return held;
        if (!transparent(tree.kind_at(parent))) return held;

        held = parent;
    }

    return held;
}

fn transparent(kind: Kind) bool {
    if (!kind.is_node()) return false;

    return switch (kind) {
        .arguments, .computed_property_name, .template_substitution => true,
        .as_expression, .instantiation_expression, .non_null_expression => true,
        .parenthesized_expression, .satisfies_expression, .type_assertion => true,
        else => false,
    };
}

fn sequence_passes(tree: *const Tree, node: u32, kind: Kind) bool {
    assert(node < tree.count());
    assert(tree.kind_at(node) == kind);

    return switch (kind) {
        .await_expression, .call_expression, .yield_expression => true,
        .member_expression, .subscript_expression => chained(tree, node),
        else => false,
    };
}

fn chained(tree: *const Tree, node: u32) bool {
    assert(node < tree.count());

    var held = node;

    assert(tree.count() <= node_count_max);

    for (0..tree.count() + 1) |_| {
        switch (tree.kind_at(held)) {
            .call_expression, .member_expression, .subscript_expression => {},
            else => return false,
        }

        if (optional_linked(tree, held)) return true;

        held = tree.at(held).child_first;

        if (held == none) return false;
    }

    return false;
}

fn optional_linked(tree: *const Tree, node: u32) bool {
    assert(node < tree.count());

    var child = tree.at(node).child_first;

    assert(tree.count() <= node_count_max);

    for (0..tree.count() + 1) |_| {
        if (child == none) return false;
        if (tree.kind_at(child) == .optional_chain) return true;

        child = tree.at(child).sibling_next;
    }

    return false;
}

fn membered(tree: *const Tree, node: u32) bool {
    assert(node < tree.count());

    var held = node;

    assert(tree.count() <= node_count_max);

    for (0..tree.count() + 1) |_| {
        switch (tree.kind_at(held)) {
            .member_expression, .subscript_expression => return true,
            .as_expression, .non_null_expression, .parenthesized_expression => {},
            .satisfies_expression, .type_assertion => {},
            else => return false,
        }

        held = wrapped_inner(tree, held);

        if (held == none) return false;
    }

    return false;
}

fn assigning(tree: *const Tree, node: u32) bool {
    assert(node <= node_count_max);

    var held = node;

    assert(tree.count() <= node_count_max);

    for (0..tree.count() + 1) |_| {
        if (held == none) return false;

        switch (tree.kind_at(held)) {
            .assignment_expression, .augmented_assignment_expression => return true,
            .as_expression, .non_null_expression, .parenthesized_expression => {},
            .satisfies_expression, .type_assertion => {},
            else => return false,
        }

        held = wrapped_inner(tree, held);
    }

    return false;
}

fn unparenthesized(tree: *const Tree, node: u32) u32 {
    assert(node <= node_count_max);

    var held = node;

    assert(tree.count() <= node_count_max);

    for (0..tree.count() + 1) |_| {
        if (held == none) return none;
        if (tree.kind_at(held) != .parenthesized_expression) return held;

        held = wrapped_inner(tree, held);
    }

    return held;
}

fn wrapped_inner(tree: *const Tree, wrapper: u32) u32 {
    assert(wrapper < tree.count());

    var child = tree.at(wrapper).child_first;

    assert(tree.count() <= node_count_max);

    if (tree.kind_at(wrapper) == .type_assertion) return child_last(tree, wrapper);

    for (0..tree.count() + 1) |_| {
        if (child == none) return none;
        if (tree.kind_at(child) != .comment) return child;

        child = tree.at(child).sibling_next;
    }

    return none;
}

fn child_last(tree: *const Tree, node: u32) u32 {
    assert(node != none);

    var child = tree.at(node).child_first;
    var last: u32 = none;

    assert(node < tree.count());

    for (0..tree.count() + 1) |_| {
        if (child == none) return last;

        last = child;
        child = tree.at(child).sibling_next;
    }

    return last;
}

fn inside(tree: *const Tree, node: u32, ancestor: u32) bool {
    assert(node <= node_count_max);

    var held = node;

    assert(ancestor != none);
    assert(tree.count() <= node_count_max);

    for (0..tree.count() + 1) |_| {
        if (held == ancestor) return true;
        if (held == none) return false;

        held = tree.at(held).parent;
    }

    return false;
}

fn pattern_above(tree: *const Tree, node: u32) bool {
    assert(node != none);

    var held = node;

    assert(tree.count() <= node_count_max);

    for (0..tree.count() + 1) |_| {
        if (held == none) return false;

        switch (role_at(tree, held)) {
            .array_pattern, .object_pattern => return true,
            .formal_parameters => return false,
            else => {},
        }

        held = tree.at(held).parent;
    }

    return false;
}

fn comment_content(source: []const u8, token: Token) ?Span {
    assert(token.end() <= source.len);

    const text = token.text(source);

    assert(token.kind == .comment);

    if (text.len < 2) return null;

    if (std.mem.startsWith(u8, text, "//")) {
        return .{ .offset = token.offset + 2, .length = token.length - 2 };
    }

    if (!std.mem.startsWith(u8, text, "/*")) return null;

    const closed = text.len >= 4 and std.mem.endsWith(u8, text, "*/");
    const trimmed: u32 = if (closed) 4 else 2;

    return .{ .offset = token.offset + 2, .length = token.length - trimmed };
}

fn directive_of(text: []const u8) ?Found {
    assert(text.len <= std.math.maxInt(u32));

    const prefixed = std.mem.startsWith(u8, text, "eslint-") or
        std.mem.startsWith(u8, text, "oxlint-");

    if (!prefixed) return null;

    const rest = text["eslint-".len..];

    for (directive_words) |entry| {
        const word, const directive = entry;
        if (!std.mem.startsWith(u8, rest, word)) continue;

        const after = rest[word.len..];

        if (after.len > 0) {
            if (!directive_blank(after[0])) continue;
        }

        return .{ .directive = directive, .rest = after };
    }

    return null;
}

fn rules_listed(rest: []const u8) []const u8 {
    assert(rest.len <= source_bytes_max);

    for (0..rest.len) |index| {
        if (rest[index] != '-') continue;
        if (index + 1 >= rest.len) continue;

        const next = rest[index + 1];
        if (next == '-') return rest[0..index];
        if (index == 0) continue;

        if (directive_blank(rest[index - 1])) {
            if (directive_blank(next)) return rest[0..index];
        }
    }

    return rest;
}

fn directive_blank(byte: u8) bool {
    if (byte > ' ') return false;

    return std.mem.findScalar(u8, directive_blanks, byte) != null;
}

fn next_line_end(source: []const u8, from: u32) u32 {
    assert(from <= source.len);
    assert(source.len <= source_bytes_max);

    const first = std.mem.findScalarPos(u8, source, from, '\n') orelse {
        assert(source.len <= std.math.maxInt(u32));

        return @intCast(source.len);
    };
    const second = std.mem.findScalarPos(u8, source, first + 1, '\n') orelse source.len;
    var stop = second;

    for (0..second - first) |_| {
        if (stop <= first + 1) break;
        if (source[stop - 1] != '\r') break;

        stop -= 1;
    }

    assert(stop <= source.len);

    return @intCast(stop);
}

fn shadows_a_global(name: []const u8) bool {
    assert(name.len > 0);
    assert(globals.len > 0);

    if (std.mem.eql(u8, name, "arguments")) return false;

    for (globals) |global| {
        if (std.mem.eql(u8, global, name)) return true;
    }

    return false;
}

fn merges(kind: BindingKind) bool {
    if (kind == .let) return false;

    return switch (kind) {
        .@"enum", .interface, .namespace, .type_alias => true,
        else => false,
    };
}

fn declares(kind: BindingKind) bool {
    if (kind == .mapped_key) return false;

    return switch (kind) {
        .mapped_key, .signature, .type_parameter => false,
        else => true,
    };
}

fn spread_at(source: []const u8, offset: u32) bool {
    assert(offset <= source.len);

    var held: usize = offset;

    assert(source.len <= source_bytes_max);

    for (0..offset) |_| {
        if (held == 0) break;
        if (!is_ascii_whitespace(source[held - 1])) break;

        held -= 1;
    }

    if (held < 3) return false;
    return std.mem.eql(u8, source[held - 3 .. held], "...");
}

fn typeof_at(source: []const u8, offset: u32) bool {
    assert(offset <= source.len);

    const word = "typeof";
    var held: usize = offset;

    assert(source.len <= source_bytes_max);

    for (0..offset) |_| {
        if (held == 0) break;
        if (!is_ascii_whitespace(source[held - 1])) break;

        held -= 1;
    }

    if (held < word.len) return false;
    if (!std.mem.eql(u8, source[held - word.len .. held], word)) return false;

    if (held != word.len) {
        if (is_name_byte(source[held - word.len - 1])) return false;
    }

    var after: usize = offset;

    while (after < source.len) : (after += 1) {
        if (!is_name_byte(source[after])) break;
    }

    while (after < source.len) : (after += 1) {
        if (!is_ascii_whitespace(source[after])) break;
    }

    if (after == source.len) return true;

    return switch (source[after]) {
        '.', '[', '(' => false,
        else => true,
    };
}

fn is_name_byte(byte: u8) bool {
    if (byte < '$') return false;

    return std.ascii.isAlphanumeric(byte) or byte == '$' or byte == '_';
}

fn ignorable(kind: BindingKind, name: []const u8) bool {
    assert(name.len > 0);
    assert(name.len <= source_bytes_max);

    if (kind == .catch_parameter) return false;
    if (!std.mem.startsWith(u8, name, "_")) return false;
    if (kind != .parameter) return true;
    return name.len > 1;
}

fn returns_first(tree: *const Tree, loop: u32, head: u32) bool {
    assert(tree.kind_at(loop) == .for_in_statement);

    const body = child_last(tree, loop);

    assert(head < tree.count());

    if (body == none) return false;
    if (body == head) return false;
    if (tree.kind_at(body) != .statement_block) return tree.kind_at(body) == .return_statement;

    var statement = tree.at(body).child_first;

    for (0..tree.count() + 1) |_| {
        if (statement == none) return false;
        if (tree.kind_at(statement) != .comment) break;

        statement = tree.at(statement).sibling_next;
    }

    if (statement == none) return false;
    return tree.kind_at(statement) == .return_statement;
}

fn variable(kind: BindingKind) bool {
    if (kind == .class) return false;

    return switch (kind) {
        .catch_parameter, .@"const", .let, .parameter, .parameter_property, .@"var" => true,
        else => false,
    };
}

fn reportable(kind: BindingKind) bool {
    if (kind == .mapped_key) return false;

    return switch (kind) {
        .catch_parameter,
        .class,
        .@"const",
        .@"enum",
        .function,
        .import,
        .import_default,
        .import_namespace,
        .import_type,
        .interface,
        .let,
        .namespace,
        .signature,
        .type_alias,
        .type_parameter,
        .@"var",
        => true,
        else => false,
    };
}

fn golden_of(gpa: std.mem.Allocator, root: []const u8, name: []const u8, held: *Golden) !bool {
    assert(root.len > 0);
    assert(name.len > 0);

    const io = std.testing.io;
    var path_buffer: [path_bytes_max]u8 = undefined;
    const path = try std.mem.print(&path_buffer, "{s}/{s}.json", .{ root, name });
    const limit: std.Io.Limit = .limited(golden_bytes_max);

    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, limit) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };

    held.* = .{
        .broken = std.mem.find(u8, text, "\"broken\":true") != null,
        .rows = .empty,
        .text = text,
    };

    errdefer held.deinit(gpa);

    try golden_rows(gpa, held);
    std.mem.sort(Row, held.rows.items, {}, Row.less_than);

    return true;
}

fn golden_rows(gpa: std.mem.Allocator, golden: *Golden) !void {
    const text = golden.text;
    const key = "\"ast\":[";
    const start = std.mem.find(u8, text, key) orelse return;
    var offset = start + key.len;

    assert(golden.rows.items.len == 0);
    assert(offset <= text.len);

    for (0..text.len + 1) |_| {
        if (offset >= text.len) break;
        if (text[offset] != '[') break;

        const open = std.mem.findScalarPos(u8, text, offset, '"') orelse break;
        const close = std.mem.findScalarPos(u8, text, open + 1, '"') orelse break;
        var cursor = close + 1;

        while (cursor < text.len) : (cursor += 1) {
            if (std.ascii.isDigit(text[cursor])) break;
        }

        var position: u32 = 0;

        while (cursor < text.len) : (cursor += 1) {
            if (!std.ascii.isDigit(text[cursor])) break;

            position = position * 10 + (text[cursor] - '0');
        }

        try golden.rows.append(gpa, .{ .code = text[open + 1 .. close], .offset = position });

        offset = cursor;

        if (offset < text.len) {
            if (text[offset] == ']') offset += 1;
        }

        if (offset >= text.len) break;
        if (text[offset] != ',') break;

        offset += 1;
    }
}

fn differing_fail(
    gpa: std.mem.Allocator,
    files: []const corpus.File,
    shared: *const OxlintWorker.Shared,
    compared: u32,
) !void {
    var linter = try Linter.create(gpa);
    defer linter.destroy(gpa);

    var lines: std.ArrayList(u8) = .empty;
    defer lines.deinit(gpa);

    var count: u32 = 0;
    var shown_end: usize = 0;

    assert(files.len <= file_count_max);
    assert(compared <= files.len);

    for (files) |*file| {
        if (shared.carried.contains(file.name)) continue;

        var held: Golden = undefined;
        if (!try golden_of(gpa, shared.golden_root, file.name, &held)) continue;
        defer held.deinit(gpa);

        if (held.broken) continue;

        const fixture = fixture_of(file);
        if (try linter.machine.run_fixture(fixture) != .complete) continue;

        const rows = try linter.rows(fixture.source);
        if (rows_equal(rows, held.rows.items)) continue;

        try report(gpa, &lines, file.name, rows, held.rows.items);
        count += 1;

        if (count <= report_count_max) shown_end = lines.items.len;
    }

    try differing_write(lines.items, lines.items[0..shown_end], count, compared);
}

fn differing_write(text: []const u8, shown: []const u8, count: u32, compared: u32) !void {
    assert(shown.len <= text.len);
    assert(count <= compared);

    var path_bytes: [environment.value_bytes_max]u8 = undefined;

    if (environment.get("SCYLLA_REPORT", &path_bytes)) |path| {
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = text });
    }

    std.debug.print("{d} of {d} corpus files differ\n{s}", .{ count, compared, shown });

    return error.TestUnexpectedResult;
}

fn diverges(gpa: std.mem.Allocator, linter: *Linter, root: []const u8, fixture: Fixture) !bool {
    assert(root.len > 0);
    assert(fixture.name.len > 0);

    var held: Golden = undefined;
    if (!try golden_of(gpa, root, fixture.name, &held)) return true;
    defer held.deinit(gpa);

    if (held.broken) return true;
    if (try linter.machine.run_fixture(fixture) != .complete) return true;

    const rows = try linter.rows(fixture.source);
    return !rows_equal(rows, held.rows.items);
}

fn rows_equal(held: []const Row, expected: []const Row) bool {
    assert(held.len <= row_count_max);
    assert(expected.len <= golden_bytes_max);

    if (held.len != expected.len) return false;

    for (held, expected) |mine, theirs| {
        if (mine.offset != theirs.offset) return false;
        if (!std.mem.eql(u8, mine.code, theirs.code)) return false;
    }

    return true;
}

fn report(
    gpa: std.mem.Allocator,
    lines: *std.ArrayList(u8),
    name: []const u8,
    held: []const Row,
    expected: []const Row,
) !void {
    assert(expected.len <= row_count_max);

    var shown: u32 = 0;
    var mine: usize = 0;
    var theirs: usize = 0;

    assert(name.len > 0);
    assert(held.len <= row_count_max);

    try lines.print(gpa, "{s}: the rows differ\n", .{name});

    for (0..held.len + expected.len + 1) |_| {
        if (shown >= report_line_count_max) break;

        if (mine >= held.len) {
            if (theirs >= expected.len) break;
        }

        const extra = theirs >= expected.len or
            (mine < held.len and Row.less_than({}, held[mine], expected[theirs]));

        if (extra) {
            const row = held[mine];

            try lines.print(gpa, "  extra   {s} {d}\n", .{ row.code, row.offset });
            mine += 1;
            shown += 1;

            continue;
        }

        const missing = mine >= held.len or Row.less_than({}, expected[theirs], held[mine]);

        if (missing) {
            const row = expected[theirs];

            try lines.print(gpa, "  missing {s} {d}\n", .{ row.code, row.offset });
            theirs += 1;
            shown += 1;

            continue;
        }

        mine += 1;
        theirs += 1;
    }
}

fn fixture_of(file: *const corpus.File) Fixture {
    const basename = std.Io.Dir.path.basename(file.name);
    const detected = dialect_of(basename) orelse unreachable;

    assert(file.name.len > 0);
    assert(file.source.len <= source_bytes_max);

    return .{ .dialect = detected.dialect, .name = file.name, .source = file.source };
}

fn selected(basename: []const u8) bool {
    assert(basename.len > 0);

    return dialect_of(basename) != null;
}

fn carried_by(found: []const Fixture, name: []const u8) bool {
    assert(name.len > 0);
    assert(found.len <= file_count_max);

    for (found) |fixture| {
        if (std.mem.eql(u8, fixture.name, name)) return true;
    }

    return false;
}

fn filed(files: []const corpus.File, name: []const u8) bool {
    assert(name.len > 0);
    assert(files.len <= file_count_max);

    const probe: corpus.File = .{ .name = name, .source = "" };
    const index = std.sort.binarySearch(corpus.File, files, probe, file_order);

    return index != null;
}

fn file_order(probe: corpus.File, file: corpus.File) std.math.Order {
    assert(probe.name.len > 0);
    assert(file.name.len > 0);

    return std.mem.order(u8, probe.name, file.name);
}

test "the model is total over the fixtures" {
    const gpa = std.testing.allocator;
    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    try require(found.items.len > 0, "tests/fixtures/javascript-semantic holds no source", .{});

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    assert(found.items.len <= file_count_max);
    assert(machine.semantic.count() == 0);

    for (found.items) |fixture| {
        const outcome = try machine.run_fixture(fixture);

        try require(outcome == .complete, "{s}", .{fixture.name});
        try require(machine.semantic.count() > 0, "{s}", .{fixture.name});
        try total(machine, fixture);
    }
}

test "every scope a reference resolves into is on its own chain" {
    const gpa = std.testing.allocator;
    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    try require(found.items.len > 0, "tests/fixtures/javascript-semantic holds no source", .{});

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    assert(found.items.len <= file_count_max);
    assert(machine.semantic.count() == 0);

    for (found.items) |fixture| {
        _ = try machine.run_fixture(fixture);

        try walks(machine, fixture);
    }
}

test "the root scope reports the module kind the source wrote" {
    const gpa = std.testing.allocator;
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    _ = try machine.run("var held = 1;\n", .javascript, null);

    assert(machine.semantic.scope_slice().len >= 1);

    try std.testing.expectEqual(ScopeKind.global, machine.semantic.scope_slice()[0].kind);

    _ = try machine.run("export const held = 1;\n", .javascript, null);

    assert(machine.semantic.scope_slice().len >= 1);

    try std.testing.expectEqual(ScopeKind.module, machine.semantic.scope_slice()[0].kind);
}

test "a truncated import alias leaves no empty name for the semantic builder" {
    const gpa = std.testing.allocator;
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    const sources = [_][]const u8{ "import n=", "import//\nc=", "\u{e9})import\nt=" };

    for (sources) |source| {
        _ = try machine.run(source, .typescript, null);

        try require(
            machine.tree.diagnostic_slice().len > 0,
            "`{s}` parsed without an error",
            .{source},
        );

        for (machine.tree.slice()) |node| {
            if (node.kind != .identifier_node) continue;

            try require(node.token_end > node.token_start, "`{s}` holds an empty name", .{source});
        }
    }
}

test "every fixture reports the rows oxlint reports" {
    const gpa = std.testing.allocator;
    var carried = try oracle.residue_of(gpa, residue_name, &every_category);
    defer carried.deinit(gpa);

    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    try require(found.items.len > 0, "tests/fixtures/javascript-semantic holds no source", .{});

    var linter = try Linter.create(gpa);
    defer linter.destroy(gpa);

    var compared: u32 = 0;

    for (found.items) |fixture| {
        if (carried.contains(fixture.name)) continue;

        var held: Golden = undefined;
        const golden_found = try golden_of(gpa, oxlint_fixture_root, fixture.name, &held);

        try require(golden_found, "{s} has no golden", .{fixture.name});
        defer held.deinit(gpa);

        if (held.broken) continue;

        _ = try linter.machine.run_fixture(fixture);

        const rows = try linter.rows(fixture.source);

        if (!rows_equal(rows, held.rows.items)) {
            var lines: std.ArrayList(u8) = .empty;
            defer lines.deinit(gpa);

            try report(gpa, &lines, fixture.name, rows, held.rows.items);
            std.debug.print("{s}", .{lines.items});

            return error.TestUnexpectedResult;
        }

        compared += 1;
    }

    const floor_held = floor.fixture_semantic_javascript;

    try require(compared >= floor_held, "the JavaScript fixtures lost a binding table: " ++
        "{d} compared, floor {d}", .{ compared, floor_held });
}

test "the corpus reports the rows oxlint reports" {
    const gpa = std.testing.allocator;
    const golden_root = corpus.named(.oxlint) orelse return;
    const root = corpus.named(.root) orelse return;
    var files = try corpus.collect(gpa, root, source_bytes_max, selected);
    defer files.deinit(gpa);

    if (files.slice().len == 0) return;

    var carried = try oracle.residue_of(gpa, residue_name, &every_category);
    defer carried.deinit(gpa);

    const shared: OxlintWorker.Shared = .{ .carried = &carried, .golden_root = golden_root };
    var tally: OxlintWorker.Tally = .{ .abstained = 0, .compared = 0, .differing = 0 };

    try stripe.run(OxlintWorker, gpa, &shared, files.slice(), &tally);

    const floor_held = floor.corpus_semantic_javascript;

    try require(tally.compared >= floor_held, "the corpus lost its JavaScript files: " ++
        "{d} compared, {d} abstained, floor {d}", .{ tally.compared, tally.abstained, floor_held });

    if (tally.differing > 0) try differing_fail(gpa, files.slice(), &shared, tally.compared);
}

test "every residue row names a file that diverges" {
    const gpa = std.testing.allocator;
    var carried = try oracle.residue_of(gpa, residue_name, &every_category);
    defer carried.deinit(gpa);

    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    var linter = try Linter.create(gpa);
    defer linter.destroy(gpa);

    for (found.items) |fixture| {
        if (!carried.contains(fixture.name)) continue;

        const diverged = try diverges(gpa, &linter, oxlint_fixture_root, fixture);

        try require(diverged, "{s} matches its golden and needs no residue row", .{fixture.name});
    }

    const golden_root = corpus.named(.oxlint) orelse return;

    var files: corpus.Files = if (corpus.named(.root)) |root|
        try corpus.collect(gpa, root, source_bytes_max, selected)
    else
        .{ .list = .empty };

    defer files.deinit(gpa);

    const shared: ResidueWorker.Shared = .{ .carried = &carried, .golden_root = golden_root };
    var tally: ResidueWorker.Tally = .{ .named = 0 };

    try stripe.run(ResidueWorker, gpa, &shared, files.slice(), &tally);

    for (carried.fixtures.items) |name| {
        const in_fixtures = carried_by(found.items, name);
        const in_corpus = filed(files.slice(), name);
        const carried_somewhere = in_fixtures or in_corpus;

        try require(carried_somewhere, "the residue names `{s}` and neither the fixtures " ++
            "nor the corpus carry it", .{name});
    }
}
