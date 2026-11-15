const std = @import("std");
const assert = std.debug.assert;
const AnnotationScratch = @import("semantic.zig").AnnotationScratch;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const Binding = @import("semantic.zig").Semantic.Binding;
const BindingKind = @import("semantic.zig").BindingKind;
const CheckError = @import("check.zig").CheckError;
const Completion = @import("check.zig").Completion;
const EventsType = @import("../tree.zig").EventsType;
const Index = @import("../../text/line_index.zig").LineIndex;
const Kind = @import("kind.zig").Kind;
const Parser = @import("parse.zig").Parser;
const Reference = @import("semantic.zig").Semantic.Reference;
const Semantic = @import("semantic.zig").Semantic;
const Span = @import("../../stdx/bounded/span.zig");
const Structure = @import("../tree.zig").Structure;
const Suppressions = @import("../../lint/suppress/suppressions.zig");
const Tables = @import("bind.zig").Tables;
const Token = @import("../token.zig");
const Tokens = @import("../tokens.zig");
const TreeType = @import("../tree.zig").TreeType;
const bind = @import("bind.zig").bind;
const chain_used = @import("semantic.zig").chain_used;
const check = @import("check.zig").check;
const raw_of = @import("../raw.zig").raw_of;
const corpus = @import("../../testing/corpus.zig");
const environment = @import("../../testing/environment.zig");
const floor = @import("../../testing/floor.zig");
const get = @import("semantic.zig").get;
const is_used = @import("semantic.zig").is_used;
const lex = @import("lex.zig").lex;
const oracle = @import("../../testing/oracle.zig");
const branch_slice = @import("semantic.zig").branch_slice;
const same_branch = @import("semantic.zig").same_branch;
const stripe = @import("../../testing/stripe.zig");
const tally_file = @import("../../testing/tally.zig");
const Events = EventsType(Kind);
const Row = oracle.Row;
const Tree = TreeType(Kind);

const Fixture = struct {
    name: []u8,
    source: []u8,
};

const Linter = struct {
    found: std.ArrayList(Row),
    machine: *Machine,
    suppressions: Suppressions,

    fn create(gpa: std.mem.Allocator) !Linter {
        const machine = try Machine.create(gpa);
        errdefer machine.destroy(gpa);

        var found = try std.ArrayList(Row).initCapacity(gpa, row_count_max);
        errdefer found.deinit(gpa);

        const suppressions = try Suppressions.init(gpa, .{
            .code_count_max = binding_count_max,
            .directive_count_max = binding_count_max,
        });

        assert(found.capacity >= row_count_max);
        assert(machine.semantic.count() == 0);

        return .{ .found = found, .machine = machine, .suppressions = suppressions };
    }

    fn destroy(linter: *Linter, gpa: std.mem.Allocator) void {
        assert(linter.found.capacity >= row_count_max);
        assert(linter.found.items.len <= linter.found.capacity);

        linter.suppressions.deinit(gpa);
        linter.found.deinit(gpa);
        linter.machine.destroy(gpa);
        linter.* = undefined;
    }

    fn run(linter: *Linter, source: []const u8) bool {
        const machine = linter.machine;

        assert(source.len <= source_bytes_max);

        if (!machine.run(source)) return false;

        assert(machine.lines.count() > 0);

        const comments = machine.comments.const_slice();
        const suppressions = &linter.suppressions;

        suppressions.scan(source, comments, "noqa", &file_prefixes, &machine.lines) catch |err| {
            switch (err) {
                error.CodesExhausted,
                error.DirectivesExhausted,
                error.RunsExhausted,
                => return false,
            }
        };

        suppressions.join(source, machine.tokens.slice(), &machine.lines) catch |err| {
            switch (err) {
                error.CodesExhausted,
                error.DirectivesExhausted,
                error.RunsExhausted,
                => return false,
            }
        };

        return true;
    }

    fn errored(linter: *const Linter) bool {
        assert(linter.machine.tree.count() <= node_count_max);
        assert(linter.machine.tree.diagnostic_slice().len <= diagnostic_count_max);

        return linter.machine.tree.diagnostic_slice().len > 0;
    }

    fn rows(linter: *Linter, source: []const u8) ![]const Row {
        assert(source.len <= std.math.maxInt(u32));

        linter.found.clearRetainingCapacity();

        try linter.unused_imports(source);
        try linter.redefinitions(source);
        try linter.undefined_rows(source);
        try linter.unused_variables(source);
        try linter.checked();

        var kept: usize = 0;

        for (linter.found.items) |row| {
            if (linter.suppressed(source, row)) continue;

            linter.found.items[kept] = row;
            kept += 1;
        }

        linter.found.shrinkRetainingCapacity(kept);
        std.mem.sort(Row, linter.found.items, {}, Row.less_than);

        assert(linter.found.items.len == kept);
        assert(kept <= row_count_max);

        return linter.found.items;
    }

    fn push(linter: *Linter, code: []const u8, offset: u32) !void {
        assert(offset < none);

        const line = linter.machine.lines.line_of(offset);
        const column = offset - linter.machine.lines.line_start(line) + 1;

        assert(code.len > 0);
        assert(linter.found.items.len <= linter.found.capacity);

        if (linter.found.items.len == linter.found.capacity) return error.Overflow;

        linter.found.appendAssumeCapacity(.{ .name = code, .offset = line + 1, .end = column });
    }

    fn suppressed(linter: *const Linter, source: []const u8, row: Row) bool {
        assert(row.offset >= 1);
        assert(row.name.len > 0);

        if (std.mem.eql(u8, row.name, "invalid-syntax")) return false;
        assert(source.len <= std.math.maxInt(u32));

        return linter.suppressions.matches(row.offset - 1, row.name, source) != null;
    }

    fn suppressed_at(linter: *const Linter, source: []const u8, code: []const u8, node: u32) bool {
        assert(source.len <= std.math.maxInt(u32));
        assert(node != none);

        const machine = linter.machine;
        const span = machine.tree.at(node).span(Token, machine.tokens.slice());
        const line = machine.lines.line_of(span.offset);

        assert(code.len > 0);

        return linter.suppressions.matches(line, code, source) != null;
    }

    fn checked(linter: *Linter) !void {
        const checks = linter.machine.checks.const_slice();

        assert(checks.len <= diagnostic_count_max);
        assert(linter.found.items.len <= row_count_max);

        for (checks) |held| try linter.push(held.kind.code(), held.span.offset);
    }

    fn unused_imports(linter: *Linter, source: []const u8) !void {
        assert(source.len <= std.math.maxInt(u32));

        const machine = linter.machine;
        const semantic = &machine.semantic;
        const scopes = semantic.scope_slice();

        assert(semantic.count() <= binding_count_max);
        assert(scopes.len >= 1);

        for (semantic.binding_slice(), 0..) |held, position| {
            const index: u32 = @intCast(position);

            switch (held.kind) {
                .import, .import_from, .submodule_import => {},
                else => continue,
            }

            if (held.ext.flags.redirected) continue;
            if (linter.import_read(index)) continue;
            if (linter.shadowed_plainly(index)) continue;
            if (held.ext.flags.export_explicit) continue;
            if (scopes[held.scope].kind == .class) continue;

            if (held.ext.declared != null) {
                if (held.scope != module_scope) continue;
            }

            const statement = machine.tree.at(held.node).parent;

            if (statement != none) {
                if (linter.suppressed_at(source, "F401", statement)) continue;
            }

            if (held.ext.flags.deleted) continue;
            if (held.ext.flags.alias) continue;
            if (linter.package_alias_used(source, held)) continue;

            try linter.push("F401", held.name.offset);
        }
    }

    fn plain_previous(linter: *const Linter, held: Binding) ?u32 {
        assert(held.name.length > 0);

        const semantic = &linter.machine.semantic;
        var index = held.name_previous;

        assert(semantic.count() <= binding_count_max);

        for (0..semantic.count() + 1) |_| {
            if (index == none) return null;

            const earlier = semantic.at(index);
            if (!earlier.ext.flags.redirected) return index;

            index = earlier.name_previous;
        }

        return null;
    }

    fn shadowed_plainly(linter: *const Linter, index: u32) bool {
        assert(index < none);

        const bindings = linter.machine.semantic.binding_slice();
        var current = index;

        assert(index < bindings.len);

        if (!bindings[index].ext.flags.shadowed) return false;

        for (0..bindings.len) |_| {
            const successor = successor_of(bindings, current) orelse return false;
            const later = bindings[successor];
            if (!later.ext.flags.redirected) return later.kind.binds();

            current = successor;
        }

        return false;
    }

    fn package_alias_used(linter: *const Linter, source: []const u8, held: Binding) bool {
        assert(source.len <= std.math.maxInt(u32));
        assert(held.name.length > 0);

        const machine = linter.machine;
        const name = held.name.text(source);
        const segments = machine.tables.segments.const_slice();

        assert(name.len > 0);
        assert(segments.len <= segment_count_max);

        if (held.kind != .submodule_import) return false;

        for (machine.tables.imports.const_slice()) |import| {
            const alias = import.alias.text(source);

            if (import.level != 0) continue;
            if (import.segment_count != 1) continue;
            if (std.mem.eql(u8, alias, name)) continue;
            if (import.segment_first >= segments.len) continue;
            if (!std.mem.eql(u8, segments[import.segment_first].text(source), name)) continue;

            const newest = machine.semantic.binding_newest(source, held.scope, alias, null);
            if (is_used(&machine.semantic, newest)) return true;
        }

        return false;
    }

    fn binds_a_lambda(linter: *const Linter, held: Binding) bool {
        const tree = &linter.machine.tree;

        assert(tree.count() <= node_count_max);
        assert(held.scope != none);

        if (held.kind != .assignment) return false;
        if (held.node == none) return false;

        const parent = tree.at(held.node).parent;
        if (parent == none) return false;

        var child = tree.at(parent).child_first;

        for (0..tree.count() + 1) |_| {
            if (child == none) return false;
            if (tree.kind_at(child) == .lambda) return true;

            child = tree.at(child).sibling_next;
        }

        return false;
    }

    fn reads_locals(linter: *const Linter, source: []const u8, scope: u32) bool {
        assert(source.len <= std.math.maxInt(u32));

        const references = linter.machine.semantic.reference_slice();

        assert(scope != none);
        assert(references.len <= reference_count_max);

        for (references) |reference| {
            if (reference.scope != scope) continue;
            if (std.mem.eql(u8, reference.name.text(source), "locals")) return true;
        }

        return false;
    }

    fn redefinitions(linter: *Linter, source: []const u8) !void {
        assert(source.len <= std.math.maxInt(u32));

        const machine = linter.machine;
        const semantic = &machine.semantic;

        assert(semantic.count() <= binding_count_max);
        assert(semantic.scope_slice().len >= 1);

        for (semantic.binding_slice()) |held| {
            if (held.name_previous == none) continue;
            if (held.node >= machine.tree.count()) continue;
            if (held.kind == .loop_variable) continue;
            if (held.ext.flags.redirected) continue;

            const previous = linter.plain_previous(held) orelse continue;
            const earlier = get(semantic, previous) orelse continue;
            if (!linter.redefines(source, held, earlier)) continue;

            if (held.scope == module_scope) {
                const parent = machine.tree.at(held.node).parent;
                if (!linter.stands_at_module_level(parent)) continue;
            }

            if (is_used(semantic, previous)) continue;
            if (linter.read_between(source, earlier, held)) continue;

            if (dummy(held.name.text(source))) {
                if (!earlier.kind.imports()) continue;
            }

            if (!linter.same_statement_branch(earlier, held)) continue;
            if (earlier.ext.flags.overload) continue;
            if (held.ext.flags.overload) continue;

            try linter.push("F811", held.name.offset);
        }

        for (semantic.binding_slice()) |held| {
            const shadows_import = linter.shadows_an_import(source, held);
            const shadows_global = linter.shadows_a_global(source, held);

            if (!shadows_import) {
                if (!shadows_global) continue;
            }

            try linter.push("F811", held.name.offset);
        }
    }

    fn shadows_a_global(linter: *const Linter, source: []const u8, held: Binding) bool {
        assert(source.len <= std.math.maxInt(u32));

        const machine = linter.machine;
        const semantic = &machine.semantic;

        assert(held.scope != none);
        assert(semantic.count() <= binding_count_max);

        if (!definition(held.kind)) return false;
        if (held.scope != module_scope) return false;
        if (!linter.stands_at_module_level(machine.tree.at(held.node).parent)) return false;

        const name = held.name.text(source);

        for (semantic.binding_slice(), 0..) |global, position| {
            if (global.kind != .global) continue;
            if (!std.mem.eql(u8, global.name.text(source), name)) continue;
            if (is_used(semantic, @intCast(position))) continue;

            const hoist = linter.hoist_of(global) orelse continue;
            if (hoist <= held.name.offset) return true;
        }

        return false;
    }

    fn stands_at_module_level(linter: *const Linter, node: u32) bool {
        assert(node <= node_count_max);

        const tree = &linter.machine.tree;
        var held = node;

        assert(tree.count() <= node_count_max);
        assert(node == none or node < tree.count());

        for (0..tree.count() + 1) |_| {
            if (held == none) return true;

            switch (tree.kind_at(held)) {
                .async_function_def, .function_def, .lambda => return false,
                else => {},
            }

            held = tree.at(held).parent;
        }

        return false;
    }

    fn hoist_of(linter: *const Linter, global: Binding) ?u32 {
        const machine = linter.machine;
        const scopes = machine.semantic.scope_slice();

        assert(global.kind == .global);
        assert(scopes.len >= 1);

        if (global.scope >= scopes.len) return null;

        const owner = scopes[global.scope];
        if (owner.kind != .function) return null;
        if (!linter.eager_in(owner.parent, module_scope)) return null;
        return machine.tree.at(owner.node).span(Token, machine.tokens.slice()).offset;
    }

    fn shadows_an_import(linter: *const Linter, source: []const u8, held: Binding) bool {
        assert(source.len <= std.math.maxInt(u32));

        const semantic = &linter.machine.semantic;
        const scopes = semantic.scope_slice();

        assert(held.scope < scopes.len);
        assert(scopes.len <= scope_count_max);

        if (held.name_previous != none) return false;
        if (held.kind == .loop_variable) return false;
        if (scopes[held.scope].kind == .class) return false;

        const name = held.name.text(source);
        var scope = scopes[held.scope].parent;

        for (0..scopes.len + 1) |_| {
            if (scope == none) return false;

            if (semantic.binding_newest(source, scope, name, null)) |index| {
                const earlier = get(semantic, index) orelse return false;
                if (!earlier.kind.imports()) return false;
                if (earlier.ext.flags.export_explicit) return false;
                if (earlier.ext.flags.type_checking != held.ext.flags.type_checking) return false;
                if (is_used(semantic, index)) return false;
                if (!linter.same_statement_branch(earlier, held)) return false;
                return linter.redefines(source, held, earlier);
            }

            scope = scopes[scope].parent;
        }

        return false;
    }

    fn read_between(
        linter: *const Linter,
        source: []const u8,
        earlier: Binding,
        held: Binding,
    ) bool {
        assert(source.len <= std.math.maxInt(u32));
        assert(earlier.name.length > 0);
        assert(held.name.length > 0);

        const semantic = &linter.machine.semantic;
        const name = held.name.text(source);
        const point = linter.effect_of(held);

        assert(name.len > 0);
        assert(point >= held.name.offset);

        for (semantic.reference_slice()) |reference| {
            if (reference.context != .load) continue;
            if (reference.name.offset <= earlier.name.offset) continue;
            if (reference.name.offset >= point) continue;
            if (!std.mem.eql(u8, reference.name.text(source), name)) continue;

            const bound = switch (reference.resolution) {
                .bound => |index| index,
                else => continue,
            };

            const target = get(semantic, bound) orelse continue;
            if (target.scope != held.scope) continue;
            if (linter.eager_in(reference.scope, held.scope)) return true;
        }

        return false;
    }

    fn redefines(linter: *const Linter, source: []const u8, held: Binding, earlier: Binding) bool {
        assert(source.len <= std.math.maxInt(u32));
        assert(held.name.length > 0);
        assert(earlier.name.length > 0);

        switch (held.kind) {
            .import, .import_from => if (earlier.kind == .submodule_import) {
                return linter.same_qualified(source, held, earlier);
            },
            .submodule_import => switch (earlier.kind) {
                .import, .import_from, .submodule_import => {
                    return linter.same_qualified(source, held, earlier);
                },
                else => {},
            },
            .annotation, .augmented, .deletion, .future_import, .global, .nonlocal => {
                return false;
            },
            else => {
                if (assigns(held.kind)) {
                    if (assigns(earlier.kind)) return false;
                }
            },
        }

        return switch (earlier.kind) {
            .class_definition, .function_definition, .import, .import_from => true,
            .augmented => false,
            else => assigns(earlier.kind),
        };
    }

    fn same_statement_branch(linter: *const Linter, earlier: Binding, held: Binding) bool {
        assert(earlier.name.length > 0);
        assert(held.name.length > 0);

        const semantic = &linter.machine.semantic;
        const left = linter.statement_branch(earlier);
        const right = linter.statement_branch(held);

        return same_branch(semantic, left, right);
    }

    fn statement_branch(linter: *const Linter, held: Binding) u32 {
        assert(held.name.length > 0);

        const tree = &linter.machine.tree;
        const branches = branch_slice(&linter.machine.semantic);
        const statement = linter.clause_statement(held) orelse return held.ext.branch;
        var branch = held.ext.branch;

        assert(branch < branches.len);

        for (0..branches.len) |_| {
            const record = branches[branch];
            if (record.node == none) return branch;
            if (!descends(tree, record.node, statement)) return branch;
            if (record.parent == none) return branch;

            branch = record.parent;
        }

        return branch;
    }

    fn clause_statement(linter: *const Linter, held: Binding) ?u32 {
        assert(held.name.length > 0);

        const tree = &linter.machine.tree;
        var node = held.node;

        switch (held.kind) {
            .except_variable, .match_capture => {},
            else => return null,
        }

        if (node >= tree.count()) return null;

        for (0..tree.count()) |_| {
            switch (tree.kind_at(node)) {
                .match, .@"try", .try_star => return node,
                else => {},
            }

            node = tree.at(node).parent;

            if (node == none) return null;
        }

        return null;
    }

    fn same_qualified(
        linter: *const Linter,
        source: []const u8,
        held: Binding,
        earlier: Binding,
    ) bool {
        assert(source.len <= std.math.maxInt(u32));
        assert(held.name.length > 0);
        assert(earlier.name.length > 0);

        var left: [qualified_bytes_max]u8 = undefined;
        var right: [qualified_bytes_max]u8 = undefined;
        const mine = linter.qualified_of(source, held, &left) orelse return false;
        const theirs = linter.qualified_of(source, earlier, &right) orelse return false;

        return std.mem.eql(u8, mine, theirs);
    }

    fn qualified_of(
        linter: *const Linter,
        source: []const u8,
        held: Binding,
        buffer: *[qualified_bytes_max]u8,
    ) ?[]const u8 {
        assert(source.len <= std.math.maxInt(u32));

        const machine = linter.machine;
        const tree = &machine.tree;
        const raw = machine.raw.const_slice();
        const tokens = machine.tokens.slice();
        var length: u32 = 0;

        if (held.node >= tree.count()) return null;

        const alias = tree.at(held.node);
        const statement = alias.parent;
        if (statement == none) return null;

        if (tree.kind_at(statement) == .import_from) {
            const node = tree.at(statement);
            var inside = false;

            for (node.token_start..node.token_end) |position| {
                switch (raw[position]) {
                    .from_keyword => inside = true,
                    .import_keyword => break,
                    else => if (inside) {
                        length = written(buffer, length, tokens[position].text(source)) orelse
                            return null;
                    },
                }
            }

            length = written(buffer, length, ".") orelse return null;
        }

        for (alias.token_start..alias.token_end) |position| {
            if (raw[position] == .as_keyword) break;

            length = written(buffer, length, tokens[position].text(source)) orelse return null;
        }

        assert(length <= buffer.len);

        return buffer[0..length];
    }

    fn same_module_path(
        linter: *const Linter,
        source: []const u8,
        earlier: Binding,
        held: Binding,
    ) bool {
        assert(earlier.name.length > 0);
        assert(held.name.length > 0);

        if (earlier.kind != .submodule_import) return true;
        assert(source.len <= std.math.maxInt(u32));

        const left = linter.module_path(earlier) orelse return false;
        const right = linter.module_path(held) orelse return false;
        if (left.len != right.len) return false;

        for (left, right) |one, two| {
            if (!std.mem.eql(u8, one.text(source), two.text(source))) return false;
        }

        return true;
    }

    fn module_path(linter: *const Linter, held: Binding) ?[]const Span {
        const tables = &linter.machine.tables;
        const segments = tables.segments.const_slice();

        assert(held.name.length > 0);
        assert(segments.len <= segment_count_max);

        for (tables.imports.const_slice()) |import| {
            if (!std.meta.eql(import.alias, held.name)) continue;

            const end = import.segment_first + import.segment_count;
            if (end > segments.len) return null;
            return segments[import.segment_first..end];
        }

        return null;
    }

    fn effect_of(linter: *const Linter, held: Binding) u32 {
        const machine = linter.machine;

        assert(held.name.length > 0);
        assert(held.scope != none);

        if (held.kind != .class_definition) return held.name.offset;
        return machine.tree.at(held.node).span(Token, machine.tokens.slice()).end();
    }

    fn eager_in(linter: *const Linter, scope: u32, wanted: u32) bool {
        assert(scope <= scope_count_max);

        const scopes = linter.machine.semantic.scope_slice();
        var held = scope;

        assert(wanted < scopes.len);
        assert(scopes.len <= scope_count_max);

        for (0..scopes.len + 1) |_| {
            if (held == wanted) return true;
            if (held >= scopes.len) return false;

            switch (scopes[held].kind) {
                .function, .lambda => return false,
                else => {},
            }

            held = scopes[held].parent;
        }

        return false;
    }

    fn undefined_rows(linter: *Linter, source: []const u8) !void {
        const semantic = &linter.machine.semantic;

        assert(semantic.reference_slice().len <= reference_count_max);
        assert(source.len <= source_bytes_max);

        for (semantic.reference_slice()) |held| {
            const deleted: ?Binding = switch (held.resolution) {
                .bound => |index| bound: {
                    if (held.context == .store) break :bound null;

                    const target = get(semantic, index) orelse break :bound null;

                    break :bound if (target.kind == .deletion) target else null;
                },
                else => null,
            };

            const gone = deleted != null or held.resolution == .unresolved;
            if (!gone) continue;
            if (linter.declared_global_above(source, held, deleted)) continue;
            if (linter.global_synthesized(source, held, deleted)) continue;
            if (linter.probed_for_a_name(source, held.node)) continue;
            if (linter.rebound_past_a_clause(held)) continue;

            try linter.push("F821", held.name.offset - held.ext.relocated_by);
        }
    }

    fn import_read(linter: *const Linter, index: u32) bool {
        assert(index < none);

        const semantic = &linter.machine.semantic;
        const scope = semantic.at(index).scope;
        var current = index;

        assert(index < semantic.count());
        assert(semantic.count() <= binding_count_max);

        for (0..semantic.count() + 1) |_| {
            const plain = current == index or !semantic.at(current).ext.flags.redirected;

            if (plain) {
                if (linter.read_directly(current, scope)) return true;
            }

            const shadowed = semantic.at(current).name_previous;
            if (shadowed == none) return false;
            if (semantic.at(shadowed).kind == .deletion) return false;

            current = shadowed;
        }

        return false;
    }

    fn read_directly(linter: *const Linter, index: u32, scope: u32) bool {
        assert(index < none);

        const semantic = &linter.machine.semantic;
        var references = semantic.references_of(index);

        assert(index < semantic.count());
        assert(semantic.reference_count() <= reference_count_max);

        for (0..semantic.reference_count() + 1) |_| {
            const held = references.next() orelse return false;
            const declared_away = held.context == .delete and held.scope != scope;
            if (!declared_away) return true;
        }

        return false;
    }

    fn declared_global_above(
        linter: *const Linter,
        source: []const u8,
        held: Reference,
        deleted: ?Binding,
    ) bool {
        assert(source.len <= std.math.maxInt(u32));
        assert(held.name.length > 0);
        if (deleted) |binding| assert(binding.name.length > 0);

        const semantic = &linter.machine.semantic;
        const scopes = semantic.scope_slice();
        const name = held.name.text(source);
        var scope = held.scope;

        assert(name.len > 0);
        assert(held.scope < scopes.len);

        if (deleted) |target| {
            if (target.scope != 0) return false;
        }

        for (0..scopes.len + 1) |_| {
            if (scope >= scopes.len) return false;
            if (scopes[scope].kind == .module) return false;

            const looked = scope == held.scope or scopes[scope].kind != .class;

            if (looked) {
                if (semantic.binding_newest(source, scope, name, null)) |newest| {
                    if (semantic.at(newest).ext.declared == .global) return true;
                }
            }

            scope = scopes[scope].parent;
        }

        return false;
    }

    fn global_synthesized(
        linter: *const Linter,
        source: []const u8,
        held: Reference,
        deleted: ?Binding,
    ) bool {
        assert(source.len <= std.math.maxInt(u32));
        assert(held.name.length > 0);
        if (deleted) |binding| assert(binding.name.length > 0);

        const semantic = &linter.machine.semantic;
        const name = held.name.text(source);
        const deferred = linter.deferred_in(held.scope, true);

        assert(name.len > 0);
        assert(held.scope < semantic.scope_slice().len);

        if (held.context == .delete) {
            if (held.scope != 0) return false;
        }

        if (deleted) |target| {
            if (target.scope != 0) return false;
        }

        for (semantic.binding_slice()) |declaration| {
            if (declaration.kind != .global) continue;
            if (declaration.scope == 0) continue;
            if (!std.mem.eql(u8, declaration.name.text(source), name)) continue;
            if (linter.deferred_in(declaration.scope, false)) continue;

            const offset = declaration.name.offset;
            const ordered = deferred or offset < held.name.offset;
            const fresh = if (deleted) |target| offset > target.name.offset else true;

            if (ordered) {
                if (fresh) return true;
            }
        }

        return false;
    }

    fn deferred_in(linter: *const Linter, scope: u32, inclusive: bool) bool {
        assert(scope <= scope_count_max);

        const scopes = linter.machine.semantic.scope_slice();
        var held = if (inclusive) scope else scopes[scope].parent;

        assert(scope < scopes.len);
        assert(scopes.len <= scope_count_max);

        for (0..scopes.len + 1) |_| {
            if (held >= scopes.len) return false;

            switch (scopes[held].kind) {
                .function, .lambda => return true,
                else => {},
            }

            held = scopes[held].parent;
        }

        return false;
    }

    fn rebound_past_a_clause(linter: *const Linter, held: Reference) bool {
        assert(held.name.length > 0);

        const machine = linter.machine;

        const index = switch (held.resolution) {
            .bound => |bound| bound,
            else => return false,
        };

        assert(index < machine.semantic.count());

        const handler = linter.clause_of(index) orelse return false;
        const clause = get(&machine.semantic, handler) orelse return false;
        if (clause.name_previous == none) return false;

        const span = machine.tree.at(clause.node).span(Token, machine.tokens.slice());
        const outside = held.name.offset < span.offset or held.name.offset >= span.end();

        assert(span.end() >= span.offset);

        if (!outside) return false;
        return machine.tree.kind_at(clause.node) == .except_handler;
    }

    fn clause_of(linter: *const Linter, deletion: u32) ?u32 {
        assert(deletion < none);

        const semantic = &linter.machine.semantic;
        var index = deletion;

        assert(deletion < semantic.count());
        assert(semantic.count() <= binding_count_max);

        for (0..semantic.count() + 1) |_| {
            if (index == none) return null;

            const held = get(semantic, index) orelse return null;
            if (held.kind == .except_variable) return index;

            index = held.name_previous;
        }

        return null;
    }

    fn probed_for_a_name(linter: *const Linter, source: []const u8, node: u32) bool {
        assert(source.len <= std.math.maxInt(u32));
        assert(node != none);

        const tree = &linter.machine.tree;
        var child = node;
        var held = tree.at(node).parent;

        assert(tree.count() <= node_count_max);

        for (0..tree.count() + 1) |_| {
            if (held == none) return false;

            const kind = tree.kind_at(held);

            switch (kind) {
                .async_function_def, .function_def, .lambda => return false,
                else => {},
            }

            if (kind == .@"try") {
                if (tree.kind_at(child) == .block) {
                    if (linter.catches_a_name_error(source, held)) return true;
                }
            }

            child = held;
            held = tree.at(held).parent;
        }

        return false;
    }

    fn catches_a_name_error(linter: *const Linter, source: []const u8, node: u32) bool {
        assert(source.len <= std.math.maxInt(u32));
        assert(node != none);

        const tree = &linter.machine.tree;
        var child = tree.at(node).child_first;

        assert(tree.count() <= node_count_max);

        for (0..tree.count() + 1) |_| {
            if (child == none) return false;

            if (tree.kind_at(child) == .except_handler) {
                if (linter.names_a_name_error(source, child)) return true;
            }

            child = tree.at(child).sibling_next;
        }

        return false;
    }

    fn names_a_name_error(linter: *const Linter, source: []const u8, handler: u32) bool {
        assert(source.len <= std.math.maxInt(u32));
        assert(handler != none);

        const machine = linter.machine;
        const tree = &machine.tree;
        const held = tree.at(handler);
        var end = held.token_end;
        var child = held.child_first;

        assert(held.token_start <= held.token_end);

        for (0..tree.count() + 1) |_| {
            if (child == none) break;

            if (tree.kind_at(child) == .block) {
                end = tree.at(child).token_start;

                break;
            }

            child = tree.at(child).sibling_next;
        }

        const raw = machine.raw.const_slice();
        const tokens = machine.tokens.slice();

        for (held.token_start..@max(held.token_start, end)) |position| {
            if (position >= raw.len) return false;
            if (raw[position] != .identifier) continue;
            if (position >= tokens.len) return false;
            if (std.mem.eql(u8, tokens[position].text(source), "NameError")) return true;
        }

        return false;
    }

    fn unused_variables(linter: *Linter, source: []const u8) !void {
        assert(source.len <= std.math.maxInt(u32));

        const semantic = &linter.machine.semantic;
        const scopes = semantic.scope_slice();

        assert(semantic.count() <= binding_count_max);
        assert(scopes.len >= 1);

        for (semantic.binding_slice(), 0..) |held, position| {
            const index: u32 = @intCast(position);

            switch (held.kind) {
                .assignment, .except_variable, .named, .with_variable => {},
                else => continue,
            }

            if (linter.unpacking(held.node)) continue;

            const alone = held.kind == .except_variable;

            if (!alone) {
                if (held.ext.flags.shadowed) continue;

                switch (scopes[held.scope].kind) {
                    .function, .lambda => {},
                    else => continue,
                }
            }

            const name = held.name.text(source);
            if (dummy(name)) continue;

            if (!alone) {
                if (debugger_named(name)) continue;
            }

            if (linter.reads_locals(source, held.scope)) continue;

            const dropped = held.ext.flags.deleted and !alone;

            const used = if (alone)
                is_used(semantic, index) or linter.read_in_the_clause(source, held)
            else
                chain_used(semantic, source, index);

            if (used) continue;
            if (dropped) continue;
            if (linter.declared_nonlocal(source, held)) continue;

            try linter.push("F841", held.name.offset);
        }
    }

    fn read_in_the_clause(linter: *const Linter, source: []const u8, held: Binding) bool {
        assert(source.len <= std.math.maxInt(u32));
        assert(held.name.length > 0);

        const machine = linter.machine;
        const name = held.name.text(source);
        const span = machine.tree.at(held.node).span(Token, machine.tokens.slice());

        assert(name.len > 0);
        assert(span.end() >= span.offset);

        for (machine.semantic.reference_slice()) |reference| {
            if (reference.context != .load) continue;
            if (reference.name.offset < span.offset) continue;
            if (reference.name.offset >= span.end()) continue;
            if (std.mem.eql(u8, reference.name.text(source), name)) return true;
        }

        return false;
    }

    fn declared_nonlocal(linter: *const Linter, source: []const u8, held: Binding) bool {
        assert(source.len <= std.math.maxInt(u32));
        assert(held.name.length > 0);

        const semantic = &linter.machine.semantic;
        const name = held.name.text(source);

        assert(name.len > 0);
        assert(semantic.count() <= binding_count_max);

        for (semantic.binding_slice()) |declaration| {
            if (declaration.kind != .nonlocal) continue;
            if (!std.mem.eql(u8, declaration.name.text(source), name)) continue;
            if (!linter.within(declaration.scope, held.scope)) continue;
            if (linter.reaches_a_binding(source, declaration, name)) return true;
        }

        return false;
    }

    fn reaches_a_binding(
        linter: *const Linter,
        source: []const u8,
        declaration: Binding,
        name: []const u8,
    ) bool {
        assert(source.len <= std.math.maxInt(u32));

        const semantic = &linter.machine.semantic;
        const scopes = semantic.scope_slice();

        assert(name.len > 0);
        assert(scopes.len <= scope_count_max);

        if (declaration.scope >= scopes.len) return false;

        var scope = scopes[declaration.scope].parent;

        for (0..scopes.len + 1) |_| {
            if (scope >= scopes.len) return false;

            const named = scopes[scope];

            if (named.kind == .function) {
                if (semantic.binding_newest(source, scope, name, null) != null) return true;
            }

            scope = named.parent;
        }

        return false;
    }

    fn within(linter: *const Linter, scope: u32, ancestor: u32) bool {
        assert(scope <= scope_count_max);

        const scopes = linter.machine.semantic.scope_slice();
        var held = scope;

        assert(ancestor < scopes.len);
        assert(scopes.len <= scope_count_max);

        for (0..scopes.len + 1) |_| {
            if (held == ancestor) return true;
            if (held >= scopes.len) return false;

            held = scopes[held].parent;
        }

        return false;
    }

    fn unpacking(linter: *const Linter, node: u32) bool {
        assert(node <= node_count_max);

        const tree = &linter.machine.tree;
        const statement = linter.statement_of(node) orelse return false;

        assert(node != none);

        assert(statement != node);

        return switch (tree.kind_at(statement)) {
            .assign => linter.assign_unpacks(statement, node),
            .async_with, .with => linter.with_unpacks(statement, node),
            else => false,
        };
    }

    fn statement_of(linter: *const Linter, node: u32) ?u32 {
        assert(node != none);

        const tree = &linter.machine.tree;
        var held = node;

        assert(tree.count() <= node_count_max);

        for (0..tree.count() + 1) |_| {
            const parent = tree.at(held).parent;
            if (parent == none) return null;

            switch (tree.kind_at(parent)) {
                .block, .module => return if (held == node) null else held,
                else => {},
            }

            held = parent;
        }

        return null;
    }

    fn assign_unpacks(linter: *const Linter, statement: u32, node: u32) bool {
        assert(statement < none);
        assert(node <= node_count_max);

        const tree = &linter.machine.tree;
        const value = linter.child_last(statement) orelse return false;
        const value_displayed = displays(tree.kind_at(linter.unwrapped(value)));
        var targets_displayed = true;
        var child_displayed = false;
        var target = tree.at(statement).child_first;

        assert(tree.kind_at(statement) == .assign);
        assert(value != none);

        for (0..tree.count() + 1) |_| {
            if (target == none) break;
            if (target == value) break;

            const displayed = displays(tree.kind_at(linter.unwrapped(target)));

            targets_displayed = targets_displayed and displayed;

            if (displayed) {
                if (linter.encloses(target, node)) child_displayed = true;
            }

            target = tree.at(target).sibling_next;
        }

        const in_display = targets_displayed or child_displayed;

        if (in_display) {
            if (!value_displayed) return true;
            return !targets_displayed;
        }

        return false;
    }

    fn with_unpacks(linter: *const Linter, statement: u32, node: u32) bool {
        assert(statement < none);

        const tree = &linter.machine.tree;
        var item = tree.at(statement).child_first;

        assert(node != none);
        assert(tree.count() <= node_count_max);

        for (0..tree.count() + 1) |_| {
            if (item == none) return false;

            if (tree.kind_at(item) == .with_item) {
                const context = tree.at(item).child_first;
                const target = if (context == none) none else tree.at(context).sibling_next;

                if (target != none) {
                    const tupled = tree.kind_at(linter.unwrapped(target)) == .tuple;
                    const enclosed = tupled and linter.encloses(target, node);
                    if (enclosed) return true;
                }
            }

            item = tree.at(item).sibling_next;
        }

        return false;
    }

    fn unwrapped(linter: *const Linter, node: u32) u32 {
        assert(node != none);

        const tree = &linter.machine.tree;
        var held = node;

        assert(tree.count() <= node_count_max);

        for (0..tree.count() + 1) |_| {
            if (tree.kind_at(held) != .parenthesized) return held;

            const inner = tree.at(held).child_first;
            if (inner == none) return held;

            held = inner;
        }

        return held;
    }

    fn encloses(linter: *const Linter, ancestor: u32, node: u32) bool {
        assert(node != none);

        const tree = &linter.machine.tree;
        var held = node;

        assert(ancestor != none);

        for (0..tree.count() + 1) |_| {
            if (held == ancestor) return true;
            if (held == none) return false;

            held = tree.at(held).parent;
        }

        return false;
    }

    fn child_last(linter: *const Linter, node: u32) ?u32 {
        assert(node != none);

        const tree = &linter.machine.tree;
        var child = tree.at(node).child_first;
        var last: ?u32 = null;

        assert(tree.count() <= node_count_max);

        for (0..tree.count() + 1) |_| {
            if (child == none) return last;

            last = child;
            child = tree.at(child).sibling_next;
        }

        return last;
    }
};

fn displays(kind: Kind) bool {
    assert(kind.is_node());

    const result = switch (kind) {
        .list, .set, .tuple => true,
        else => false,
    };

    if (result) assert(kind.is_node());

    return result;
}

const Machine = struct {
    annotations: AnnotationScratch,
    checks: ArrayType(CheckError),
    comments: ArrayType(Span),
    events: Events,
    lines: Index,
    names: ArrayType(Span),
    parser: Parser,
    raw: ArrayType(Kind),
    semantic: Semantic,
    tables: Tables,
    tokens: Tokens,
    tree: Tree,

    fn analyze(machine: *Machine, source: []const u8) bool {
        assert(source.len <= std.math.maxInt(u32));
        assert(machine.tokens.count() == machine.raw.count());

        const built = machine.semantic.build(&.{
            .builtins = &.{},
            .raw = machine.raw.const_slice(),
            .source = source,
            .tokens = machine.tokens.slice(),
            .tree = &machine.tree,
            .version = .py310,
        }, &machine.annotations);

        if (built != Structure.complete) return false;

        const completion = check(&.{
            .raw = machine.raw.const_slice(),
            .semantic = &machine.semantic,
            .source = source,
            .tokens = machine.tokens.slice(),
            .tree = &machine.tree,
            .version = .py314,
        }, &machine.checks, &machine.names);

        return completion == Completion.complete;
    }

    fn comments_gather(machine: *Machine) bool {
        machine.comments.clear();

        assert(machine.comments.empty());
        assert(machine.comments.capacity() == token_count_max);

        for (machine.tokens.slice()) |token| {
            if (token.kind != .comment) continue;
            if (machine.comments.full()) return false;

            machine.comments.push(token.span());
        }

        return true;
    }

    fn create(gpa: std.mem.Allocator) !*Machine {
        const machine = try gpa.create(Machine);
        errdefer gpa.destroy(machine);

        try machine.annotations.init(gpa, &.{
            .node_count_max = annotation_count_max,
            .token_count_max = annotation_count_max,
        });

        errdefer machine.annotations.deinit(gpa);

        machine.checks = try .init(gpa, diagnostic_count_max);
        errdefer machine.checks.deinit(gpa);

        machine.comments = try .init(gpa, token_count_max);
        errdefer machine.comments.deinit(gpa);

        try machine.events.init(gpa, event_count_max);
        errdefer machine.events.deinit(gpa);

        machine.lines = try .init(gpa, line_count_max);
        errdefer machine.lines.deinit(gpa);

        machine.names = try .init(gpa, binding_count_max);
        errdefer machine.names.deinit(gpa);

        machine.raw = try .init(gpa, token_count_max);
        errdefer machine.raw.deinit(gpa);

        try machine.semantic.init(gpa, &.{
            .binding_count_max = binding_count_max,
            .fact_count_max = fact_count_max,
            .reference_count_max = reference_count_max,
            .scope_count_max = scope_count_max,
        });

        errdefer machine.semantic.deinit(gpa);

        try machine.tables.init(gpa, &.{
            .binding_count_max = binding_count_max,
            .reference_count_max = reference_count_max,
            .scope_count_max = scope_count_max,
            .segment_count_max = segment_count_max,
        });

        errdefer machine.tables.deinit(gpa);

        machine.tokens = try .init(gpa, token_count_max);
        errdefer machine.tokens.deinit(gpa);

        machine.tree = try .init(gpa, node_count_max, diagnostic_count_max);

        assert(machine.raw.capacity() == token_count_max);
        assert(machine.semantic.count() == 0);

        return machine;
    }

    fn destroy(machine: *Machine, gpa: std.mem.Allocator) void {
        assert(machine.raw.capacity() == token_count_max);
        assert(machine.comments.capacity() == token_count_max);

        machine.tree.deinit(gpa);
        machine.tokens.deinit(gpa);
        machine.tables.deinit(gpa);
        machine.semantic.deinit(gpa);
        machine.raw.deinit(gpa);
        machine.names.deinit(gpa);
        machine.lines.deinit(gpa);
        machine.events.deinit(gpa);
        machine.comments.deinit(gpa);
        machine.checks.deinit(gpa);
        machine.annotations.deinit(gpa);
        gpa.destroy(machine);
    }

    fn run(machine: *Machine, source: []const u8) bool {
        assert(source.len <= std.math.maxInt(u32));
        assert(machine.tokens.count() <= token_count_max);

        machine.tokens.clear();

        lex(source, &machine.tokens) catch return false;
        raw_of(Kind, machine.tokens.slice(), &machine.raw) catch return false;

        const structure = machine.parser.build(
            source,
            machine.tokens.slice(),
            machine.raw.const_slice(),
            &machine.events,
            &machine.tree,
        );

        if (structure != Structure.complete) return false;

        bind(
            source,
            machine.tokens.slice(),
            machine.raw.const_slice(),
            &machine.tree,
            &machine.tables,
        ) catch return false;

        machine.lines.build(source) catch return false;

        if (!machine.comments_gather()) return false;
        return machine.analyze(source);
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

        const root = shared.golden_root;
        const diverged = try diverges(worker.gpa, &worker.linter, root, file.source, file.name);

        try require(diverged, "{s} matches its corpus golden and needs no residue row", .{
            file.name,
        });
    }
};

const RuffWorker = struct {
    gpa: std.mem.Allocator,
    linter: Linter,
    shared: *const Shared,

    pub const Item = corpus.File;
    pub const Shared = struct { carried: *const oracle.Residue, golden_root: []const u8 };
    pub const Tally = struct { compared: u32, differing: u32 };
    pub const weight = corpus.File.weight;

    pub fn init(worker: *RuffWorker, gpa: std.mem.Allocator, shared: *const Shared) !void {
        assert(shared.golden_root.len > 0);

        worker.gpa = gpa;
        worker.shared = shared;
        worker.linter = try Linter.create(gpa);

        assert(worker.linter.found.items.len == 0);
    }

    pub fn deinit(worker: *RuffWorker, gpa: std.mem.Allocator) void {
        assert(worker.shared.golden_root.len > 0);

        worker.linter.destroy(gpa);
        worker.* = undefined;
    }

    pub fn visit(worker: *RuffWorker, file: *const corpus.File, tally: *Tally) !void {
        const shared = worker.shared;
        const gpa = worker.gpa;

        assert(file.name.len > 0);
        assert(shared.golden_root.len > 0);

        if (shared.carried.contains(file.name)) return;

        var golden: oracle.Golden = undefined;
        if (!try oracle.golden(gpa, shared.golden_root, file.name, &golden)) return;
        defer golden.deinit(gpa);

        if (!worker.linter.run(file.source)) {
            tally.differing += 1;

            return;
        }

        if (worker.linter.errored()) return;

        const rows = try worker.linter.rows(file.source);

        std.mem.sort(Row, golden.ast.items, {}, Row.less_than);
        tally.compared += 1;

        if (rows_equal(rows, golden.ast.items)) {
            try tally_file.agree("semantic_python", "ruff", file.name);

            return;
        }

        tally.differing += 1;
    }
};

const annotation_count_max: u32 = 1 << 8;
const binding_count_max: u32 = 1 << 16;

const debugger_names = [_][]const u8{
    "__debuggerskip__",
    "__traceback_info__",
    "__traceback_supplement__",
    "__tracebackhide__",
};

const diagnostic_count_max: u32 = 1 << 10;
const every_category = [_][]const u8{ "check", "model", "not-python", "ruff" };
const event_count_max: u32 = 1 << 21;
const fact_count_max: u32 = 1 << 16;
const file_count_max: u32 = 1 << 20;
const file_prefixes = [_][]const u8{ "flake8:", "ruff:" };
const fixture_root = "tests/fixtures/python-semantic";
const line_count_max: u32 = 1 << 16;
const module_scope: u32 = 0;
const node_count_max: u32 = 1 << 19;
const none: u32 = std.math.maxInt(u32);
const qualified_bytes_max: u32 = 1 << 8;
const reference_count_max: u32 = 1 << 18;
const report_count_max: u32 = 3;
const report_line_count_max: u32 = 24;
const residue_name = "residue-semantic.json";
const row_count_max: u32 = binding_count_max * 2 + reference_count_max + diagnostic_count_max;
const ruff_fixture_root = "tests/fixtures/golden-ruff";
const scope_count_max: u32 = 1 << 12;
const segment_count_max: u32 = 1 << 14;
const source_bytes_max: u32 = 1 << 26;
const token_count_max: u32 = 1 << 19;

fn collect(gpa: std.mem.Allocator, root: []const u8, found: *std.ArrayList(Fixture)) !void {
    const io = std.testing.io;

    assert(root.len > 0);
    assert(found.items.len == 0);

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
        if (!std.mem.eql(u8, std.Io.Dir.path.extension(entry.basename), ".py")) continue;

        const limit: std.Io.Limit = .limited(source_bytes_max);
        const source = entry.dir.readFileAlloc(io, entry.basename, gpa, limit) catch continue;
        errdefer gpa.free(source);

        const name = try gpa.dupe(u8, entry.path);
        errdefer gpa.free(name);

        std.mem.replaceScalar(u8, name, '\\', '/');

        try found.append(gpa, .{ .name = name, .source = source });
    }
}

fn fixture_free(gpa: std.mem.Allocator, fixture: Fixture) void {
    assert(fixture.name.len > 0);
    assert(fixture.source.len <= source_bytes_max);

    gpa.free(fixture.name);
    gpa.free(fixture.source);
}

fn fixture_less_than(context: void, left: Fixture, right: Fixture) bool {
    _ = context;

    assert(left.name.len > 0);
    assert(right.name.len > 0);

    return std.mem.order(u8, left.name, right.name) == .lt;
}

fn fixtures(gpa: std.mem.Allocator) !std.ArrayList(Fixture) {
    var found: std.ArrayList(Fixture) = .empty;
    errdefer fixtures_free(gpa, &found);

    try collect(gpa, fixture_root, &found);
    std.mem.sort(Fixture, found.items, {}, fixture_less_than);

    assert(found.items.len <= file_count_max);
    if (found.items.len > 1) assert(fixture_less_than({}, found.items[0], found.items[1]));

    return found;
}

fn fixtures_free(gpa: std.mem.Allocator, found: *std.ArrayList(Fixture)) void {
    assert(found.items.len <= found.capacity);
    assert(found.items.len <= file_count_max);

    for (found.items) |fixture| fixture_free(gpa, fixture);

    found.deinit(gpa);
    found.* = undefined;
}

fn total_expect(machine: *const Machine, name: []const u8) !void {
    const scope_count = machine.semantic.scope_slice().len;

    assert(name.len > 0);
    assert(machine.semantic.binding_slice().len <= binding_count_max);

    for (machine.semantic.reference_slice()) |held| {
        if (held.scope >= scope_count) {
            std.debug.print("{s}: a reference names a scope out of bounds\n", .{name});

            return error.TestUnexpectedResult;
        }
    }

    for (machine.semantic.binding_slice()) |held| {
        if (held.scope >= scope_count) {
            std.debug.print("{s}: a binding names a scope out of bounds\n", .{name});

            return error.TestUnexpectedResult;
        }

        const chained = held.name_previous == none or
            get(&machine.semantic, held.name_previous) != null;

        if (!chained) {
            std.debug.print("{s}: a binding chains to nothing\n", .{name});

            return error.TestUnexpectedResult;
        }
    }
}

fn assigns(kind: BindingKind) bool {
    if (kind == .import) return false;

    return switch (kind) {
        .assignment,
        .augmented,
        .comprehension_variable,
        .match_capture,
        .named,
        .type_alias,
        => true,
        else => false,
    };
}

fn definition(kind: BindingKind) bool {
    if (kind == .assignment) return false;

    return switch (kind) {
        .class_definition, .function_definition, .import, .import_from => true,
        else => false,
    };
}

fn descends(tree: *const Tree, node: u32, ancestor: u32) bool {
    assert(node <= node_count_max);

    var held = node;

    assert(ancestor < tree.count());

    for (0..tree.count()) |_| {
        if (held == ancestor) return true;
        if (held == none) return false;
        if (held < ancestor) return false;

        held = tree.at(held).parent;
    }

    return false;
}

fn debugger_named(name: []const u8) bool {
    assert(name.len > 0);

    for (debugger_names) |held| {
        if (std.mem.eql(u8, held, name)) return true;
    }

    return false;
}

fn dummy(name: []const u8) bool {
    assert(name.len > 0);

    if (name[0] != '_') return false;
    if (std.mem.findNone(u8, name, "_") == null) return true;

    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte)) {
            if (byte != '_') return false;
        }
    }

    return std.ascii.isAlphanumeric(name[name.len - 1]);
}

fn imports(kind: BindingKind) bool {
    if (kind == .assignment) return false;

    return switch (kind) {
        .import, .import_from, .submodule_import => true,
        else => false,
    };
}

fn successor_of(bindings: []const Binding, index: u32) ?u32 {
    assert(index < bindings.len);

    for (bindings[index + 1 ..], index + 1..) |later, position| {
        if (later.name_previous == index) {
            assert(position < std.math.maxInt(u32));

            return @intCast(position);
        }
    }

    return null;
}

fn written(buffer: *[qualified_bytes_max]u8, length: u32, text: []const u8) ?u32 {
    assert(length <= buffer.len);
    assert(text.len <= std.math.maxInt(u32));

    if (length + text.len > buffer.len) return null;

    @memcpy(buffer[length..][0..text.len], text);

    const returned = length + @as(u32, @intCast(text.len));

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn differing_fail(
    gpa: std.mem.Allocator,
    files: []const corpus.File,
    shared: *const RuffWorker.Shared,
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

    for (files) |file| {
        if (shared.carried.contains(file.name)) continue;

        var golden: oracle.Golden = undefined;
        if (!try oracle.golden(gpa, shared.golden_root, file.name, &golden)) continue;
        defer golden.deinit(gpa);

        if (linter.run(file.source)) {
            if (linter.errored()) continue;

            const rows = try linter.rows(file.source);

            std.mem.sort(Row, golden.ast.items, {}, Row.less_than);

            if (rows_equal(rows, golden.ast.items)) continue;

            try report(gpa, &lines, file.name, rows, golden.ast.items);
        } else {
            try lines.print(gpa, "{s}: the model overran\n", .{file.name});
        }

        count += 1;

        if (count <= report_count_max) shown_end = lines.items.len;
    }

    try differing_write(lines.items, lines.items[0..shown_end], count, compared);
}

fn differing_write(text: []const u8, shown: []const u8, count: u32, compared: u32) !void {
    assert(shown.len <= text.len);
    assert(text.len >= shown.len);
    assert(count < none);
    assert(compared < none);

    var path_bytes: [environment.value_bytes_max]u8 = undefined;

    if (environment.get("SCYLLA_REPORT", &path_bytes)) |path| {
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = text });
    }

    std.debug.print("{d} of {d} corpus files differ\n{s}", .{ count, compared, shown });

    return error.TestUnexpectedResult;
}

fn diverges(
    gpa: std.mem.Allocator,
    linter: *Linter,
    root: []const u8,
    source: []const u8,
    name: []const u8,
) !bool {
    var golden: oracle.Golden = undefined;

    assert(root.len > 0);
    assert(name.len > 0);

    if (!try oracle.golden(gpa, root, name, &golden)) return true;
    defer golden.deinit(gpa);

    if (golden.broken) return true;
    if (!linter.run(source)) return true;

    const rows = try linter.rows(source);

    std.mem.sort(Row, golden.ast.items, {}, Row.less_than);

    return !rows_equal(rows, golden.ast.items);
}

fn rows_equal(held: []const Row, expected: []const Row) bool {
    assert(held.len <= row_count_max);
    assert(expected.len <= std.math.maxInt(u32));

    if (held.len != expected.len) return false;

    for (held, expected) |mine, theirs| {
        if (mine.order(theirs) != .eq) return false;
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
    assert(expected.len <= std.math.maxInt(u32));

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

            try lines.print(gpa, "  extra   {s} {d} {d}\n", .{ row.name, row.offset, row.end });
            mine += 1;
            shown += 1;

            continue;
        }

        const missing = mine >= held.len or Row.less_than({}, expected[theirs], held[mine]);

        if (missing) {
            const row = expected[theirs];

            try lines.print(gpa, "  missing {s} {d} {d}\n", .{ row.name, row.offset, row.end });
            theirs += 1;
            shown += 1;

            continue;
        }

        mine += 1;
        theirs += 1;
    }
}

fn selected(basename: []const u8) bool {
    assert(basename.len > 0);
    assert(basename.len <= std.Io.Dir.max_name_bytes);

    return std.mem.eql(u8, std.Io.Dir.path.extension(basename), ".py");
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
    return std.sort.binarySearch(corpus.File, files, probe, file_order) != null;
}

fn file_order(probe: corpus.File, file: corpus.File) std.math.Order {
    assert(probe.name.len > 0);
    assert(file.name.len > 0);

    return std.mem.order(u8, probe.name, file.name);
}

fn require(condition: bool, comptime format: []const u8, arguments: anytype) !void {
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    if (condition) return;

    std.debug.print(format ++ "\n", arguments);

    return error.TestUnexpectedResult;
}

test "the model is total over the fixtures" {
    const gpa = std.testing.allocator;
    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    for (found.items) |fixture| {
        if (!machine.run(fixture.source)) {
            std.debug.print("{s} overran\n", .{fixture.name});

            return error.TestUnexpectedResult;
        }

        try total_expect(machine, fixture.name);
    }
}

test "every fixture reports the rows ruff reports" {
    const gpa = std.testing.allocator;
    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    try require(found.items.len > 0, "tests/fixtures/python-semantic holds no source", .{});

    var linter = try Linter.create(gpa);
    defer linter.destroy(gpa);

    var compared: u32 = 0;

    for (found.items) |fixture| {
        try require(linter.run(fixture.source), "{s} overran", .{fixture.name});

        const rows = try linter.rows(fixture.source);
        var golden: oracle.Golden = undefined;
        const golden_found = try oracle.golden(gpa, ruff_fixture_root, fixture.name, &golden);

        try require(golden_found, "{s} has no golden", .{fixture.name});
        defer golden.deinit(gpa);

        try require(!golden.broken, "{s}", .{fixture.name});
        std.mem.sort(Row, golden.ast.items, {}, Row.less_than);

        if (!rows_equal(rows, golden.ast.items)) {
            var lines: std.ArrayList(u8) = .empty;
            defer lines.deinit(gpa);

            try report(gpa, &lines, fixture.name, rows, golden.ast.items);
            std.debug.print("{s}", .{lines.items});

            return error.TestUnexpectedResult;
        }

        compared += 1;
    }

    try std.testing.expectEqual(found.items.len, compared);
}

test "the corpus reports the rows ruff reports" {
    const gpa = std.testing.allocator;
    const golden_root = corpus.named(.ruff) orelse return;
    const root = corpus.named(.root) orelse return;
    var files = try corpus.collect(gpa, root, source_bytes_max, selected);
    defer files.deinit(gpa);

    if (files.slice().len == 0) return;

    var carried = try oracle.residue_of(gpa, residue_name, &every_category);
    defer carried.deinit(gpa);

    const shared: RuffWorker.Shared = .{ .carried = &carried, .golden_root = golden_root };
    var tally: RuffWorker.Tally = .{ .compared = 0, .differing = 0 };

    try stripe.run(RuffWorker, gpa, &shared, files.slice(), &tally);

    const named: u32 = tally.compared + @as(u32, @intCast(carried.fixtures.items.len));
    const floor_held = floor.corpus_semantic_python;

    try require(named >= floor_held, "the corpus lost its Python files: {d} named, floor {d}", .{
        named,
        floor_held,
    });

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

        const root = ruff_fixture_root;
        const diverged = try diverges(gpa, &linter, root, fixture.source, fixture.name);

        try require(diverged, "{s} matches its golden and needs no residue row", .{fixture.name});
    }

    const golden_root = corpus.named(.golden) orelse return;

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
