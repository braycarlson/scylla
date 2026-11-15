const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const BindingKind = @import("bind.zig").BindingKind;
const EventsType = @import("../tree.zig").EventsType;
const Index = @import("../../text/line_index.zig").LineIndex;
const Kind = @import("kind.zig").Kind;
const Parser = @import("parse.zig").Parser;
const Random = @import("../../testing/random.zig");
const Span = @import("../../stdx/bounded/span.zig");
const Structure = @import("../tree.zig").Structure;
const Token = @import("../token.zig");
const Tokens = @import("../tokens.zig");
const TreeType = @import("../tree.zig").TreeType;
const View = @import("ast.zig").View;
const bind = @import("bind.zig").bind;
const raw_of = @import("../raw.zig").raw_of;
const corpus = @import("../../testing/corpus.zig");
const environment = @import("../../testing/environment.zig");
const floor = @import("../../testing/floor.zig");
const lex = @import("lex.zig").lex;
const oracle = @import("../../testing/oracle.zig");
const oracle_names = @import("../testing/names.zig");
const python = @import("../../testing/python.zig");
const stripe = @import("../../testing/stripe.zig");
const tally = @import("../../testing/tally.zig");
const trivia = @import("../trivia.zig");
const Events = EventsType(Kind);
const Golden = python.Golden;
const Node = Tree.Node;
const Row = oracle.Row;
const Scope = @import("bind.zig").Scope;
const ScopeRow = python.Scope;
const Tables = @import("bind.zig").Tables;
const Tree = TreeType(Kind);

const Machine = struct {
    arena: std.heap.ArenaAllocator,
    events: Events,
    expected: std.ArrayList(Row),
    held: std.ArrayList(Row),
    lines: Index,
    parser: Parser,
    raw: ArrayType(Kind),
    stack: ArrayType(u32),
    tables: Tables,
    tokens: Tokens,
    tree: Tree,

    fn create(gpa: std.mem.Allocator) !*Machine {
        const machine = try gpa.create(Machine);
        errdefer gpa.destroy(machine);

        try machine.events.init(gpa, event_count_max);
        errdefer machine.events.deinit(gpa);

        machine.lines = try .init(gpa, line_count_max);
        errdefer machine.lines.deinit(gpa);

        machine.raw = try .init(gpa, raw_count_max);
        errdefer machine.raw.deinit(gpa);

        machine.stack = try .init(gpa, node_count_max);
        errdefer machine.stack.deinit(gpa);

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
        machine.arena = .init(gpa);
        machine.expected = .empty;
        machine.held = .empty;

        assert(machine.raw.capacity() == machine.tokens.items.capacity());
        assert(machine.tree.count() == 0);

        return machine;
    }

    fn destroy(machine: *Machine, gpa: std.mem.Allocator) void {
        assert(machine.raw.capacity() == raw_count_max);
        assert(machine.tokens.items.capacity() == token_count_max);

        machine.held.deinit(gpa);
        machine.expected.deinit(gpa);
        machine.arena.deinit();
        machine.tree.deinit(gpa);
        machine.tokens.deinit(gpa);
        machine.tables.deinit(gpa);
        machine.stack.deinit(gpa);
        machine.raw.deinit(gpa);
        machine.lines.deinit(gpa);
        machine.events.deinit(gpa);
        gpa.destroy(machine);
    }

    fn complete(machine: *Machine, source: []const u8) bool {
        assert(source.len <= std.math.maxInt(u32));

        machine.tokens.clear();

        lex(source, &machine.tokens) catch |err| switch (err) {
            error.Truncated => return false,
        };

        assert(!machine.tokens.items.full() or machine.tokens.count() > 0);

        return true;
    }

    fn run(machine: *Machine, source: []const u8) bool {
        assert(source.len <= std.math.maxInt(u32));

        machine.tokens.clear();

        lex(source, &machine.tokens) catch |err| switch (err) {
            error.Truncated => assert(machine.tokens.items.full()),
        };

        raw_of(Kind, machine.tokens.slice(), &machine.raw) catch |err| switch (err) {
            error.Truncated => return false,
        };

        assert(machine.raw.count() == machine.tokens.count());

        return true;
    }

    fn invalid(machine: *const Machine) ?u32 {
        const raw = machine.raw.const_slice();

        assert(raw.len == machine.tokens.count());

        const position = std.mem.findScalar(Kind, raw, .error_token) orelse return null;

        assert(raw[position] == .error_token);

        return @intCast(position);
    }

    fn parse(machine: *Machine, source: []const u8) !Structure {
        assert(source.len <= std.math.maxInt(u32));

        try require(machine.run(source), "the source overran its tokens", .{});

        assert(machine.raw.count() == machine.tokens.count());
        assert(machine.events.count() <= event_count_max);

        return machine.parser.build(
            source,
            machine.tokens.slice(),
            machine.raw.const_slice(),
            &machine.events,
            &machine.tree,
        );
    }

    fn view_of(machine: *const Machine, node: u32) View {
        const tokens = machine.tokens.slice();
        const raw = machine.raw.const_slice();

        assert(node < machine.tree.count());
        assert(tokens.len == raw.len);

        return View.init(&machine.tree, tokens, raw, node);
    }

    fn walk(machine: *Machine, gpa: std.mem.Allocator, length: u32) !void {
        assert(length < none);

        const node_count = machine.tree.count();

        machine.held.clearRetainingCapacity();
        machine.stack.clear();

        if (node_count == 0) return;

        machine.stack.push(0);

        for (0..node_count) |_| {
            const node = machine.stack.pop() orelse break;
            const view = machine.view_of(node);

            try machine.walk_visit(gpa, view, length);

            var children = view.children();

            for (0..node_count) |_| {
                const child = children.next() orelse break;

                machine.stack.push(child.node);
            }
        }

        assert(machine.stack.empty());
        assert(machine.held.items.len <= node_count);

        std.mem.sort(Row, machine.held.items, {}, Row.less_than);
    }

    fn walk_visit(machine: *Machine, gpa: std.mem.Allocator, view: View, length: u32) !void {
        assert(view.node < view.tree.count());

        const name = oracle_name(oracle_names.name_of(Kind, view.kind()));
        const span = echo_span(view) orelse view.span();

        assert(name.len > 0);
        assert(span.end() <= length);

        if (std.mem.eql(u8, name, "Module")) {
            try machine.held.append(gpa, .{ .name = name, .offset = 0, .end = length });

            return;
        }

        if (names_contain(&skipped, name)) return;

        try machine.held.append(gpa, .{ .name = name, .offset = span.offset, .end = span.end() });
    }

    fn walk_matches(
        machine: *Machine,
        gpa: std.mem.Allocator,
        length: u32,
        rows: []const Row,
    ) !bool {
        assert(length < none);
        assert(rows.len <= std.math.maxInt(u32));

        try machine.walk(gpa, length);

        machine.expected.clearRetainingCapacity();

        try machine.expected.appendSlice(gpa, rows);
        std.mem.sort(Row, machine.expected.items, {}, Row.less_than);

        assert(machine.held.items.len <= machine.tree.count());
        assert(machine.expected.items.len == rows.len);

        return rows_equal(machine.held.items, machine.expected.items);
    }

    fn census(machine: *const Machine) Census {
        var kinds: [statements.len]Kind = undefined;
        var found: Census = @splat(0);

        for (statements, &kinds) |name, *kind| {
            const held = oracle_names.kind_of(Kind, name);

            assert(held != null);

            kind.* = held.?;
        }

        for (machine.tree.slice()) |node| {
            const index = std.mem.findScalar(Kind, &kinds, node.kind) orelse continue;

            found[index] += 1;
        }

        assert(std.mem.findScalar(Kind, &kinds, .module) == null);

        return found;
    }

    fn bind_tables(machine: *Machine, source: []const u8) !bool {
        assert(source.len <= std.math.maxInt(u32));

        const built = if (machine.lines.build(source)) |_| true else |err| switch (err) {
            error.Truncated => false,
        };

        try require(built, "the source overran its line index", .{});

        assert(machine.lines.count() > 0);
        assert(machine.raw.count() == machine.tokens.count());

        bind(
            source,
            machine.tokens.slice(),
            machine.raw.const_slice(),
            &machine.tree,
            &machine.tables,
        ) catch |err| switch (err) {
            error.BindingsFull,
            error.ImportsFull,
            error.JobsFull,
            error.ReferencesFull,
            error.ScopesFull,
            error.SegmentsFull,
            => return false,
        };

        return true;
    }

    fn scopes(machine: *Machine, source: []const u8) ![]const ScopeRow {
        assert(source.len <= std.math.maxInt(u32));

        _ = machine.arena.reset(.retain_capacity);

        var symtable = try Symtable.init(machine.arena.allocator(), machine, source);

        try symtable.gather();
        try symtable.propagate();
        try symtable.globalise();

        const rows = try symtable.rows();

        assert(rows.len == machine.tables.scopes.count());
        if (rows.len > 1) assert(!ScopeRow.less_than({}, rows[1], rows[0]));

        return rows;
    }
};

const Symtable = struct {
    arena: std.mem.Allocator,
    bindings: []Key,
    machine: *const Machine,
    references: []Key,
    source: []const u8,
    symbols: []std.ArrayList(Symbol),

    fn init(arena: std.mem.Allocator, machine: *const Machine, source: []const u8) !Symtable {
        assert(source.len <= std.math.maxInt(u32));

        const tables = &machine.tables;

        const symtable: Symtable = .{
            .arena = arena,
            .bindings = try arena.alloc(Key, tables.bindings.count()),
            .machine = machine,
            .references = try arena.alloc(Key, tables.references.count()),
            .source = source,
            .symbols = try arena.alloc(std.ArrayList(Symbol), tables.scopes.count()),
        };

        for (tables.bindings.const_slice(), symtable.bindings, 0..) |binding, *key, position| {
            key.* = .{
                .name = binding.name.text(source),
                .position = @intCast(position),
                .scope = binding.scope,
            };
        }

        for (tables.references.const_slice(), symtable.references, 0..) |held, *key, position| {
            key.* = .{
                .name = held.name.text(source),
                .position = @intCast(position),
                .scope = held.scope,
            };
        }

        @memset(symtable.symbols, .empty);
        std.mem.sort(Key, symtable.bindings, {}, Key.less_than);
        std.mem.sort(Key, symtable.references, {}, Key.less_than);

        assert(symtable.bindings.len == tables.bindings.count());
        assert(symtable.references.len == tables.references.count());

        return symtable;
    }

    fn gather(symtable: *Symtable) !void {
        const arena = symtable.arena;

        assert(symtable.symbols.len == symtable.scope_count());

        for (symtable.symbols, 0..) |*list, position| {
            const index: u32 = @intCast(position);

            assert(list.items.len == 0);

            if (symtable.scope_at(index).kind == .comprehension) {
                try list.append(arena, .{ .name = ".0", .letters = "lp" });
            }

            try list.appendSlice(arena, symtable.compiler_state(index));

            const names = try symtable.symbol_names(index);

            if (symtable.class_cell(index)) |letters| {
                if (!names_contain(names, "__class__")) {
                    try list.append(arena, .{ .name = "__class__", .letters = letters });
                }
            }

            const owner = try symtable.mangling(index);

            for (names) |name| {
                try list.append(arena, .{
                    .name = try symtable.mangled(name, owner),
                    .letters = try symtable.letters_of(index, name),
                });
            }
        }
    }

    fn propagate(symtable: *Symtable) !void {
        const count = symtable.scope_count();

        assert(symtable.symbols.len == count);

        for (0..count) |_| {
            var added = false;

            for (0..count) |index| {
                const scope_added = try symtable.propagate_scope(@intCast(index));

                added = added or scope_added;
            }

            if (!added) return;
        }
    }

    fn propagate_scope(symtable: *Symtable, index: u32) !bool {
        assert(index < symtable.symbols.len);

        const parent = symtable.scope_at(index).parent;
        var added = false;

        assert(index < symtable.scope_count());
        assert(parent != index);

        for (symtable.symbols[index].items) |symbol| {
            if (std.mem.findScalar(u8, symbol.letters, 'f') == null) continue;
            if (synthetic(symbol.name)) continue;
            if (parent == none) continue;

            const owner = if (std.mem.eql(u8, symbol.name, "__class__"))
                symtable.class_owner(index)
            else
                symtable.owner_of(index, symbol.name);

            if (parent == owner) continue;
            if (symtable.scope_at(parent).kind == .module) continue;
            if (symbols_contain(symtable.symbols[parent].items, symbol.name)) continue;

            try symtable.symbols[parent].append(symtable.arena, .{
                .name = symbol.name,
                .letters = "f",
            });

            added = true;
        }

        return added;
    }

    fn globalise(symtable: *Symtable) !void {
        const bindings = symtable.machine.tables.bindings.const_slice();

        if (symtable.scope_count() == 0) {
            assert(bindings.len == 0);

            return;
        }

        const module = symtable.module_scope();

        assert(module < symtable.scope_count());

        for (bindings) |binding| {
            if (binding.kind != .global) continue;

            const name = binding.name.text(symtable.source);
            if (symbols_contain(symtable.symbols[module].items, name)) continue;

            try symtable.symbols[module].append(symtable.arena, .{ .name = name, .letters = "g" });
        }
    }

    fn module_scope(symtable: *const Symtable) u32 {
        const scopes = symtable.machine.tables.scopes.const_slice();

        assert(scopes.len > 0);
        assert(scopes.len == symtable.symbols.len);

        for (scopes, 0..) |scope, index| {
            if (scope.kind == .module) {
                assert(index < scopes.len);

                return @intCast(index);
            }
        }

        return 0;
    }

    fn rows(symtable: *Symtable) ![]const ScopeRow {
        const found = try symtable.arena.alloc(ScopeRow, symtable.scope_count());

        assert(found.len == symtable.symbols.len);

        for (found, symtable.symbols, 0..) |*row, list, position| {
            const index: u32 = @intCast(position);

            std.mem.sort(Symbol, list.items, {}, Symbol.less_than);

            row.* = .{
                .kind = symtable.scope_kind(index),
                .name = try symtable.scope_name(index),
                .line = symtable.scope_line(index),
                .symbols = try symtable.joined(list.items),
            };
        }

        std.mem.sort(ScopeRow, found, {}, ScopeRow.less_than);

        if (found.len > 0) assert(found[0].kind.len > 0);

        return found;
    }

    fn joined(symtable: *const Symtable, symbols: []const Symbol) ![]const u8 {
        var text: std.ArrayList(u8) = .empty;

        assert(symbols.len <= symtable.bindings.len + symtable.references.len + state_count_max);

        for (symbols, 0..) |symbol, position| {
            if (position > 0) try text.append(symtable.arena, ',');

            try text.print(symtable.arena, "{f}:{s}", .{
                std.unicode.fmtUtf8(symbol.name),
                symbol.letters,
            });
        }

        assert(text.items.len >= symbols.len);

        return text.items;
    }

    fn compiler_state(symtable: *const Symtable, index: u32) []const Symbol {
        assert(index < symtable.scope_count());

        const scope = symtable.scope_at(index);

        if (scope.kind == .class) {
            if (scope.parent == none) return &.{};
            if (symtable.scope_at(scope.parent).kind == .type) return &state_class_generic;
            return &.{};
        }

        if (scope.kind != .type) return &.{};

        const owner = symtable.machine.tree.at(scope.node).parent;

        assert(owner != none);

        return switch (symtable.raw_kind(owner)) {
            .async_function_def, .function_def => state: {
                if (scope.parent == none) break :state &state_function;
                if (symtable.scope_at(scope.parent).kind == .class) break :state &state_method;

                break :state &state_function;
            },
            .class_def => &state_class,
            else => &.{},
        };
    }

    fn symbol_names(symtable: *const Symtable, index: u32) ![]const []const u8 {
        assert(index < none);

        const bound = keys_of(symtable.bindings, index, null);
        const referenced = keys_of(symtable.references, index, null);
        const names = try symtable.arena.alloc([]const u8, bound.len + referenced.len);
        var unique: usize = 0;

        for (bound, names[0..bound.len]) |key, *name| name.* = key.name;
        for (referenced, names[bound.len..]) |key, *name| name.* = key.name;

        std.mem.sort([]const u8, names, {}, name_less_than);

        for (names) |name| {
            const repeated = unique > 0 and std.mem.eql(u8, names[unique - 1], name);
            if (repeated) continue;

            names[unique] = name;
            unique += 1;
        }

        assert(unique <= names.len);
        if (unique > 1) assert(name_less_than({}, names[0], names[1]));

        return names[0..unique];
    }

    fn letters_of(symtable: *const Symtable, index: u32, name: []const u8) ![]const u8 {
        assert(index < none);
        assert(name.len > 0);

        const held = symtable.marks_of(index, name);
        const module = symtable.scope_at(index).kind == .module;
        const local = held.bound and !held.declared_global and !held.declared_nonlocal;
        const enclosed = held.declared_nonlocal or symtable.owner_of(index, name) != none;
        const free = !local and !held.declared_global and enclosed;
        const global = module or held.declared_global or (!local and !free);

        const flags = [letters_all.len]bool{
            held.assigned,
            free,
            global,
            held.imported,
            local,
            held.parameter,
        };

        var buffer: [letters_all.len]u8 = undefined;
        var letter_count: usize = 0;

        for (flags, letters_all) |flag, letter| {
            if (!flag) continue;

            buffer[letter_count] = letter;
            letter_count += 1;
        }

        if (local) assert(!free);
        assert(letter_count <= letters_all.len);

        return symtable.arena.dupe(u8, buffer[0..letter_count]);
    }

    fn marks_of(symtable: *const Symtable, index: u32, name: []const u8) Marks {
        assert(index < none);
        assert(name.len > 0);

        const bindings = symtable.machine.tables.bindings.const_slice();
        const references = symtable.machine.tables.references.const_slice();
        var held: Marks = .empty;
        var isolated = false;
        var comprehension_only = false;
        var outside = false;

        for (keys_of(symtable.bindings, index, name)) |key| {
            const kind = bindings[key.position].kind;
            const assigning = kind.assigns() and kind != .comprehension_target;

            switch (kind) {
                .global => held.declared_global = true,
                .nonlocal => held.declared_nonlocal = true,
                .comprehension_target => comprehension_only = true,
                .parameter => held.parameter = true,
                .import => held.imported = true,
                .assignment,
                .class_def,
                .function_def,
                .pattern_capture,
                .type_parameter,
                .walrus_target,
                => {},
            }

            if (isolating(kind)) {
                held.bound = true;
                isolated = true;
            }

            if (assigning) held.assigned = true;
        }

        for (keys_of(symtable.references, index, name)) |key| {
            if (!references[key.position].comprehension) outside = true;
        }

        const inferred = comprehension_only and !isolated and !outside;

        if (inferred) {
            held.bound = true;
            held.assigned = true;
        }

        if (!held.bound) {
            if (symtable.walrus_above(index, name)) held.assigned = true;
        }

        if (isolated) assert(held.bound);

        return held;
    }

    fn walrus_above(symtable: *const Symtable, index: u32, name: []const u8) bool {
        assert(index < symtable.scope_count());

        const bindings = symtable.machine.tables.bindings.const_slice();
        var held = symtable.scope_at(index).parent;

        assert(name.len > 0);

        if (symtable.scope_at(index).kind != .comprehension) return false;

        for (0..symtable.scope_count()) |_| {
            if (held == none) return false;

            for (keys_of(symtable.bindings, held, name)) |key| {
                if (bindings[key.position].kind == .walrus_target) return true;
            }

            held = symtable.scope_at(held).parent;
        }

        return false;
    }

    fn declares(
        symtable: *const Symtable,
        scope: u32,
        name: []const u8,
        declared: BindingKind,
    ) bool {
        assert(name.len > 0);

        const bindings = symtable.machine.tables.bindings.const_slice();

        assert(scope < symtable.scope_count());
        assert(declared == .global or declared == .nonlocal);

        for (keys_of(symtable.bindings, scope, name)) |key| {
            if (bindings[key.position].kind == declared) return true;
        }

        return false;
    }

    fn binds(symtable: *const Symtable, scope: u32, name: []const u8) bool {
        const bindings = symtable.machine.tables.bindings.const_slice();

        assert(scope < symtable.scope_count());
        assert(name.len > 0);

        if (symtable.declares(scope, name, .nonlocal)) return false;

        for (keys_of(symtable.bindings, scope, name)) |key| {
            switch (bindings[key.position].kind) {
                .global, .nonlocal => {},
                else => return true,
            }
        }

        return false;
    }

    fn captures(symtable: *const Symtable, reader: u32, owner: u32, name: []const u8) bool {
        assert(reader < symtable.scope_count());
        assert(owner < symtable.scope_count());
        assert(name.len > 0);

        const bindings = symtable.machine.tables.bindings.const_slice();
        const tree = &symtable.machine.tree;
        const keys = keys_of(symtable.bindings, owner, name);
        var node = tree.at(symtable.scope_at(reader).node).parent;

        for (0..tree.count()) |_| {
            if (node == none) return false;

            switch (symtable.raw_kind(node)) {
                .dict_comp, .list_comp, .set_comp => {
                    const span = symtable.machine.view_of(node).span();

                    for (keys) |key| {
                        const binding = bindings[key.position];

                        const inside = span.offset <= binding.name.offset and
                            binding.name.end() <= span.end();

                        const bound = binding.kind == .comprehension_target and inside;
                        if (bound) return true;
                    }
                },
                else => {},
            }

            node = tree.at(node).parent;
        }

        return false;
    }

    fn owner_of(symtable: *const Symtable, scope: u32, name: []const u8) u32 {
        assert(scope < symtable.scope_count());

        var held = symtable.scope_at(scope).parent;

        assert(name.len > 0);

        for (0..symtable.scope_count()) |_| {
            if (held == none) return none;

            const kind = symtable.scope_at(held).kind;
            const enclosing = kind == .module or kind == .class;

            if (enclosing) {
                if (symtable.captures(scope, held, name)) return held;
                if (kind == .module) return none;
            } else {
                if (symtable.declares(held, name, .global)) return none;
                if (symtable.binds(held, name)) return held;
            }

            held = symtable.scope_at(held).parent;
        }

        return none;
    }

    fn class_owner(symtable: *const Symtable, index: u32) u32 {
        assert(index < symtable.scope_count());

        var held = symtable.scope_at(index).parent;

        assert(held != index);

        for (0..symtable.scope_count()) |_| {
            if (held == none) return none;

            const kind = symtable.scope_at(held).kind;
            if (kind == .class) return held;
            if (kind == .module) return none;

            held = symtable.scope_at(held).parent;
        }

        return none;
    }

    fn class_cell(symtable: *const Symtable, index: u32) ?[]const u8 {
        assert(index < symtable.scope_count());

        const scope = symtable.scope_at(index);

        assert(scope.parent != index);

        switch (scope.kind) {
            .class, .function, .lambda => {},
            else => return null,
        }

        const supers = keys_of(symtable.references, index, "super");
        const cells = keys_of(symtable.references, index, "__class__");
        if (supers.len + cells.len == 0) return null;
        if (scope.kind == .class) return "g";
        if (symtable.class_owner(index) != none) return "f";
        return "g";
    }

    fn mangling(symtable: *const Symtable, index: u32) ![]const u8 {
        assert(index < symtable.scope_count());

        var held = index;

        assert(symtable.symbols.len == symtable.scope_count());

        for (0..symtable.scope_count()) |_| {
            const scope = symtable.scope_at(held);

            if (scope.kind == .class) {
                const name = try symtable.scope_name(held);
                return std.mem.trimStart(u8, name, "_");
            }

            if (scope.parent == none) break;

            held = scope.parent;
        }

        return "";
    }

    fn mangled(symtable: *const Symtable, name: []const u8, owner: []const u8) ![]const u8 {
        assert(name.len > 0);
        assert(symtable.symbols.len == symtable.scope_count());
        assert(owner.len <= std.math.maxInt(u32));

        if (owner.len == 0) return name;
        if (!std.mem.startsWith(u8, name, "__")) return name;
        if (std.mem.endsWith(u8, name, "__")) return name;
        return std.mem.concat(symtable.arena, u8, &.{ "_", owner, name });
    }

    fn scope_name(symtable: *const Symtable, index: u32) ![]const u8 {
        assert(index < symtable.scope_count());

        const scope = symtable.scope_at(index);

        switch (scope.kind) {
            .module => return "top",
            .comprehension => return "genexpr",
            .lambda => return "lambda",
            .type, .type_alias, .type_variable => return symtable.owner_name(index),
            .class, .function => {},
        }

        const view = symtable.machine.view_of(scope.node);
        const position = view.token_first(.identifier);

        try require(position != null, "a definition names itself", .{});

        return symtable.lossy(view.token_at(position.?).text(symtable.source));
    }

    fn owner_name(symtable: *const Symtable, index: u32) ![]const u8 {
        assert(index < symtable.scope_count());

        var node = symtable.scope_at(index).node;

        if (symtable.raw_kind(node) == .type_params) node = symtable.machine.tree.at(node).parent;

        const view = symtable.machine.view_of(node);

        if (symtable.raw_kind(node) == .type_alias) {
            if (view.child_first_of(.name_node)) |named| {
                if (named.token_first(.identifier)) |position| {
                    return symtable.lossy(named.token_at(position).text(symtable.source));
                }
            }
        }

        const position = view.token_first(.identifier) orelse return "";

        assert(position < view.token_end());

        return symtable.lossy(view.token_at(position).text(symtable.source));
    }

    fn lossy(symtable: *const Symtable, bytes: []const u8) ![]const u8 {
        assert(bytes.len <= symtable.source.len);
        assert(symtable.symbols.len == symtable.scope_count());

        if (std.unicode.utf8ValidateSlice(bytes)) return bytes;
        return symtable.arena.print("{f}", .{std.unicode.fmtUtf8(bytes)});
    }

    fn raw_kind(symtable: *const Symtable, node: u32) Kind {
        const tree = &symtable.machine.tree;

        assert(node < tree.count());
        assert(tree.count() > 0);

        return tree.kind_at(node);
    }

    fn scope_kind(symtable: *const Symtable, index: u32) []const u8 {
        assert(index < symtable.scope_count());
        assert(symtable.symbols.len == symtable.scope_count());

        return switch (symtable.scope_at(index).kind) {
            .class => "class",
            .module => "module",
            .type => "type parameters",
            .type_alias => "type alias",
            .type_variable => "type variable",
            .comprehension, .function, .lambda => "function",
        };
    }

    fn scope_line(symtable: *const Symtable, index: u32) u32 {
        assert(index < symtable.scope_count());

        const scope = symtable.scope_at(index);

        if (scope.kind == .module) return 0;

        const offset = symtable.machine.view_of(scope.node).span().offset;

        assert(offset <= symtable.source.len);

        return symtable.machine.lines.line_of(offset) + 1;
    }

    fn scope_at(symtable: *const Symtable, index: u32) Scope {
        const scopes = &symtable.machine.tables.scopes;

        assert(index < scopes.count());
        assert(scopes.count() == symtable.symbols.len);

        return scopes.get(index);
    }

    fn scope_count(symtable: *const Symtable) u32 {
        const count = symtable.machine.tables.scopes.count();

        assert(count <= scope_count_max);
        assert(count == symtable.symbols.len);

        return count;
    }
};

const Census = [statements.len]u32;

const Check = enum {
    census,
    classify,
    invariants,
    scope,
    walk,
};

const CorpusShared = struct {
    carried: *const oracle.Residue,
    golden: ?[]const u8,
};

const CorpusTally = struct {
    abstained: u32,
    carried: u32,
    compared: u32,
    differing: u32,
};

const Construct = struct {
    name: []const u8,
    source: []const u8,
};

const Differing = struct {
    count: u32,
    shown_end: usize,
    shown_max: u32,
    text: std.ArrayList(u8),

    fn noted(differing: *Differing) void {
        differing.count += 1;

        if (differing.count <= differing.shown_max) differing.shown_end = differing.text.items.len;

        assert(differing.count > 0);
        assert(differing.shown_end <= differing.text.items.len);
    }
};

const Fixture = corpus.File;

const Key = struct {
    name: []const u8,
    position: u32,
    scope: u32,

    fn less_than(context: void, left: Key, right: Key) bool {
        _ = context;

        assert(left.scope != none);
        assert(right.scope != none);

        if (left.scope != right.scope) return left.scope < right.scope;
        return std.mem.lessThan(u8, left.name, right.name);
    }
};

const Marks = struct {
    assigned: bool,
    bound: bool,
    declared_global: bool,
    declared_nonlocal: bool,
    imported: bool,
    parameter: bool,

    const empty: Marks = .{
        .assigned = false,
        .bound = false,
        .declared_global = false,
        .declared_nonlocal = false,
        .imported = false,
        .parameter = false,
    };
};

const Outcome = enum {
    abstained,
    compared,
};

const Walked = enum {
    abstained,
    differs,
    matches,
};

const Probe = struct {
    name: ?[]const u8,
    scope: u32,

    fn order(probe: Probe, key: Key) std.math.Order {
        assert(probe.scope != none);
        assert(key.scope != none);

        if (probe.scope != key.scope) return std.math.order(probe.scope, key.scope);

        const name = probe.name orelse return .eq;
        return std.mem.order(u8, name, key.name);
    }
};

const Residues = struct {
    carried: *const oracle.Residue,
    corpus_held: bool,
    named: *std.ArrayList([]const u8),
    scoped: *const oracle.Residue,
};

const Symbol = struct {
    letters: []const u8,
    name: []const u8,

    fn less_than(context: void, left: Symbol, right: Symbol) bool {
        _ = context;

        assert(left.name.len > 0);
        assert(right.name.len > 0);

        const by_name = std.mem.order(u8, left.name, right.name);
        if (by_name != .eq) return by_name == .lt;
        return std.mem.lessThan(u8, left.letters, right.letters);
    }
};

const alphabet = "abc_09 \t\n\r()[]{}:,.=+-*/%<>!&|^~@;'\"\\#defclassifrtuwyn\x00\xff\xc3\xa9";
const binding_count_max: u32 = 1 << 16;
const continuation: u8 = '\\';
const element_count: u32 = 4_000;
const diagnostic_count_max: u32 = 0x0000_0400;
const event_count_max: u32 = 0x000C_0000;
const every_category = [_][]const u8{"not-python"};
const file_count_max: u32 = 1 << 20;
const fixture_root = "tests/fixtures/python";
const golden_root = "tests/fixtures/golden-python";
const letters_all = "afgilp";
const line_count_max: u32 = 1 << 16;
const node_count_max: u32 = 0x0004_0000;
const none: u32 = std.math.maxInt(u32);
const not_python = [_][]const u8{"not-python"};
const raw_count_max: u32 = 0x0004_0000;
const reference_count_max: u32 = 1 << 18;
const report_extra_max: u32 = 12;
const report_missing_max: u32 = 24;
const residue_name = "residue-python.json";
const scope_category = [_][]const u8{"not-python"};
const scope_count_max: u32 = 1 << 12;
const scope_extra_max: u32 = 6;
const scope_missing_max: u32 = 12;
const scope_shown_max: u32 = 2;
const scopes_only = [_][]const u8{"pep-695-type-parameter-scopes"};
const segment_count_max: u32 = 1 << 14;
const soup_bytes_max: u32 = 512;
const soup_round_count: u32 = 512;
const source_bytes_max: u32 = 1 << 24;
const state_count_max: u32 = 3;
const suite = "syntax_python";
const token_count_max: u32 = 0x0004_0000;
const walk_shown_max: u32 = 3;

const state_class = [_]Symbol{
    .{ .name = ".generic_base", .letters = "al" },
    .{ .name = ".type_params", .letters = "al" },
};

const state_class_generic = [_]Symbol{
    .{ .name = ".type_params", .letters = "f" },
    .{ .name = "__type_params__", .letters = "al" },
};

const state_function = [_]Symbol{
    .{ .name = ".defaults", .letters = "lp" },
};

const state_method = [_]Symbol{
    .{ .name = ".defaults", .letters = "lp" },
    .{ .name = "__classdict__", .letters = "f" },
};

const statements = [_][]const u8{
    "AnnAssign",
    "Assert",
    "Assign",
    "AsyncFor",
    "AsyncFunctionDef",
    "AsyncWith",
    "AugAssign",
    "Break",
    "ClassDef",
    "Continue",
    "Delete",
    "Expr",
    "For",
    "FunctionDef",
    "Global",
    "If",
    "Import",
    "ImportFrom",
    "Match",
    "Nonlocal",
    "Pass",
    "Raise",
    "Return",
    "Try",
    "TryStar",
    "TypeAlias",
    "While",
    "With",
};

const renamed = [_][2][]const u8{
    .{ "Alias", "alias" },
    .{ "Arg", "arg" },
    .{ "Keyword", "keyword" },
};

const skipped = [_][]const u8{
    "Arguments",
    "Block",
    "Comprehension",
    "Decorator",
    "ElseClause",
    "ErrorNode",
    "FinallyClause",
    "MatchCase",
    "Parenthesized",
    "TypeParams",
    "WithItem",
};

const synthetic_names = [_][]const u8{
    ".defaults",
    ".generic_base",
    ".type_params",
    "__classdict__",
    "__type_params__",
};

comptime {
    assert(alphabet.len == 58);
    assert(alphabet.len < soup_bytes_max);
    assert(state_class_generic.len <= state_count_max);
    assert(state_method.len <= state_count_max);
}

fn corpus_fixtures(gpa: std.mem.Allocator) !corpus.Files {
    const root = corpus.named(.root) orelse return .{ .list = .empty };
    const found = try corpus.collect(gpa, root, source_bytes_max, corpus_selected);

    assert(root.len > 0);
    assert(found.slice().len <= file_count_max);

    return found;
}

fn corpus_selected(basename: []const u8) bool {
    assert(basename.len > 0);

    return std.mem.eql(u8, std.Io.Dir.path.extension(basename), ".py");
}

fn fixtures(gpa: std.mem.Allocator) !corpus.Files {
    const found = try corpus.collect(gpa, fixture_root, source_bytes_max, corpus_selected);

    assert(found.slice().len <= file_count_max);
    if (found.slice().len > 1) assert(Fixture.less_than({}, found.slice()[0], found.slice()[1]));

    return found;
}

fn soup(random: *Random, buffer: *[soup_bytes_max]u8) []const u8 {
    const length = random.below(soup_bytes_max) + 1;

    assert(length > 0);
    assert(length <= buffer.len);

    for (buffer[0..length]) |*byte| byte.* = alphabet[random.below(alphabet.len)];

    return buffer[0..length];
}

fn gaps_are_blank(source: []const u8, tokens: []const Token, name: []const u8) !void {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len < std.math.maxInt(u32));

    const length: u32 = @intCast(source.len);
    var gaps = trivia.gaps(Token, length, tokens);
    var end_previous: u32 = 0;
    var gap_count: u32 = 0;

    assert(name.len > 0);

    while (gaps.next()) |gap| : (gap_count += 1) {
        assert(gap_count <= tokens.len);

        try require(
            trivia.gap_is_blank(source, gap.span, continuation),
            "{s} carries a non-blank gap at {d} of {d} bytes",
            .{ name, gap.span.offset, gap.span.length },
        );

        try require(gap.span.offset >= end_previous, "{s} runs its gaps backwards", .{name});
        try require(gap.token == gap_count, "{s} numbers its gaps out of order", .{name});

        end_previous = gap.span.end();
    }

    try require(
        gap_count == tokens.len + 1,
        "{s} owes one gap per token plus a trailing one",
        .{name},
    );

    try require(end_previous == length, "{s} leaves bytes past its last gap", .{name});
}

fn invariants_hold(machine: *const Machine, name: []const u8) !void {
    const nodes = machine.tree.slice();
    const node_count = machine.tree.count();
    const token_count = machine.tokens.count();

    assert(nodes.len == node_count);
    assert(name.len > 0);

    for (nodes, 0..) |node, position| {
        const index: u32 = @intCast(position);
        const parent_held = node.parent == none or node.parent < index;
        const child_held = node.child_first == none or node.child_first > index;
        const sibling_held = node.sibling_next == none or node.sibling_next < node_count;

        try require(node.token_start <= node.token_end, "{s}: node {d}", .{ name, index });

        try require(
            node.token_end <= token_count,
            "{s}: node {d} runs past the tokens",
            .{ name, index },
        );

        try require(parent_held, "{s}: node {d} names a parent out of preorder", .{ name, index });
        try require(child_held, "{s}: node {d} names a child out of preorder", .{ name, index });

        try require(
            sibling_held,
            "{s}: node {d} names a sibling out of bounds",
            .{ name, index },
        );

        try children_hold(nodes, index, name);
    }
}

fn children_hold(nodes: []const Node, index: u32, name: []const u8) !void {
    assert(nodes.len <= std.math.maxInt(u32));
    assert(index < nodes.len);
    assert(name.len > 0);

    const node = nodes[index];
    const node_count: u32 = @intCast(nodes.len);
    var child = node.child_first;
    var end_previous = node.token_start;

    assert(index < node_count);
    assert(node.token_start <= node.token_end);

    for (0..node_count) |_| {
        if (child == none) break;

        try require(child < node_count, "{s}: node {d} names no node", .{ name, child });

        const held = nodes[child];

        try require(held.parent == index, "{s}: node {d} disowns its parent", .{ name, child });

        try require(
            held.token_start >= end_previous,
            "{s}: node {d} overlaps its sibling",
            .{ name, child },
        );

        try require(
            held.token_end <= node.token_end,
            "{s}: node {d} runs past its parent",
            .{ name, child },
        );

        end_previous = held.token_end;
        child = held.sibling_next;
    }

    try require(child == none, "{s}: node {d} loops over its children", .{ name, index });
}

fn CorpusWorkerType(comptime check: Check) type {
    return struct {
        gpa: std.mem.Allocator,
        machine: *Machine,
        shared: *const CorpusShared,

        const CorpusWorker = @This();
        pub const Item = Fixture;
        pub const Shared = CorpusShared;
        pub const Tally = CorpusTally;
        pub const weight = Fixture.weight;

        pub fn init(worker: *CorpusWorker, gpa: std.mem.Allocator, shared: *const Shared) !void {
            assert(shared.carried.fixtures.items.len <= file_count_max);
            assert((shared.golden == null) == (check == .classify or check == .invariants));

            worker.* = .{ .gpa = gpa, .machine = try Machine.create(gpa), .shared = shared };

            assert(worker.machine.tree.count() == 0);
        }

        pub fn deinit(worker: *CorpusWorker, gpa: std.mem.Allocator) void {
            assert(worker.gpa.vtable == gpa.vtable);
            assert(worker.shared.carried.fixtures.items.len <= file_count_max);

            worker.machine.destroy(gpa);
            worker.* = undefined;
        }

        pub fn visit(worker: *CorpusWorker, fixture: *const Fixture, counted: *Tally) !void {
            const gpa = worker.gpa;
            const machine = worker.machine;

            assert(fixture.name.len > 0);
            assert(counted.differing <= counted.compared);

            if (!machine.complete(fixture.source)) return;

            if (worker.shared.carried.contains(fixture.name)) {
                if (check == .classify) counted.carried += 1;

                return;
            }

            switch (check) {
                .census => {
                    const root = worker.shared.golden.?;

                    switch (try census_against_corpus(gpa, machine, root, fixture)) {
                        .abstained => counted.abstained += 1,
                        .compared => counted.compared += 1,
                    }
                },
                .classify => {
                    try require(machine.run(fixture.source), "{s} overran", .{fixture.name});

                    const invalid = machine.invalid();

                    try require(
                        invalid == null,
                        "{s} classifies token {?d} to an ErrorToken",
                        .{ fixture.name, invalid },
                    );

                    try gaps_are_blank(fixture.source, machine.tokens.slice(), fixture.name);
                    try tally.agree(suite, "classify", fixture.name);
                    counted.compared += 1;
                },
                .invariants => {
                    _ = try machine.parse(fixture.source);

                    try invariants_hold(machine, fixture.name);
                    try tally.agree(suite, "invariants", fixture.name);
                },
                .scope => {
                    const root = worker.shared.golden.?;
                    const walked = try scope_against_corpus(gpa, machine, root, fixture, null);

                    try walked_counted(walked, "scope", fixture.name, counted);
                },
                .walk => {
                    const root = worker.shared.golden.?;
                    const walked = try walk_against_corpus(gpa, machine, root, fixture, null);

                    try walked_counted(walked, "walk", fixture.name, counted);
                },
            }
        }
    };
}

fn corpus_checked(
    comptime check: Check,
    gpa: std.mem.Allocator,
    carried: *const oracle.Residue,
    golden: ?[]const u8,
    found: []const Fixture,
) !CorpusTally {
    if (golden) |held| assert(held.len <= std.math.maxInt(u32));

    const shared: CorpusShared = .{ .carried = carried, .golden = golden };
    var counted: CorpusTally = .{ .abstained = 0, .carried = 0, .compared = 0, .differing = 0 };

    assert(found.len > 0);
    assert(found.len <= file_count_max);

    try stripe.run(CorpusWorkerType(check), gpa, &shared, found, &counted);

    assert(counted.differing <= counted.compared);
    assert(counted.abstained + counted.carried + counted.compared <= found.len);

    return counted;
}

fn walked_counted(
    walked: Walked,
    comptime test_name: []const u8,
    name: []const u8,
    counted: *CorpusTally,
) !void {
    assert(name.len > 0);
    assert(counted.differing <= counted.compared);
    assert(test_name.len <= std.math.maxInt(u32));

    switch (walked) {
        .abstained => counted.abstained += 1,
        .differs => {
            counted.compared += 1;
            counted.differing += 1;
        },
        .matches => {
            try tally.agree(suite, test_name, name);
            counted.compared += 1;
        },
    }
}

fn differing_reported(
    comptime check: Check,
    gpa: std.mem.Allocator,
    carried: *const oracle.Residue,
    root: []const u8,
    found: []const Fixture,
    counted: *const CorpusTally,
) !void {
    comptime assert(check == .scope or check == .walk);

    assert(root.len > 0);
    assert(counted.differing <= counted.compared);
    assert(found.len <= std.math.maxInt(u32));

    if (counted.differing == 0) return;

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    var differing: Differing = .{
        .count = 0,
        .shown_end = 0,
        .shown_max = if (check == .walk) walk_shown_max else scope_shown_max,
        .text = .empty,
    };

    defer differing.text.deinit(gpa);

    for (found) |*fixture| {
        if (!machine.complete(fixture.source)) continue;
        if (carried.contains(fixture.name)) continue;

        if (check == .walk) {
            _ = try walk_against_corpus(gpa, machine, root, fixture, &differing);
        } else {
            _ = try scope_against_corpus(gpa, machine, root, fixture, &differing);
        }
    }

    assert(differing.count == counted.differing);

    if (check == .walk) {
        try differing_fail(&differing, counted.compared, "SCYLLA_REPORT", "differ");
    } else {
        try differing_fail(&differing, counted.compared, "SCYLLA_SCOPE_REPORT", "bind differently");
    }
}

fn walk_diverges(
    gpa: std.mem.Allocator,
    machine: *Machine,
    root: []const u8,
    fixture: *const Fixture,
) !bool {
    var golden: Golden = undefined;
    if (!try python.golden(gpa, root, fixture.name, &golden)) return true;
    defer golden.deinit(gpa);

    assert(root.len > 0);
    assert(fixture.name.len > 0);

    if (!machine.run(fixture.source)) return true;
    if (machine.invalid() != null) return true;

    _ = try machine.parse(fixture.source);

    const length: u32 = @intCast(fixture.source.len);
    const matches = try machine.walk_matches(gpa, length, golden.ast.items);

    return !matches;
}

fn scopes_diverge(
    gpa: std.mem.Allocator,
    machine: *Machine,
    root: []const u8,
    fixture: *const Fixture,
) !bool {
    var golden: Golden = undefined;
    if (!try python.golden(gpa, root, fixture.name, &golden)) return true;
    defer golden.deinit(gpa);

    assert(root.len > 0);
    assert(fixture.name.len > 0);

    _ = try machine.parse(fixture.source);

    if (!try machine.bind_tables(fixture.source)) return true;

    const held = try machine.scopes(fixture.source);
    return !scopes_equal(held, golden.scopes.items);
}

fn residue_diverges(
    gpa: std.mem.Allocator,
    machine: *Machine,
    root: []const u8,
    fixture: *const Fixture,
    residue: *const Residues,
) !void {
    const where = if (residue.corpus_held) "corpus " else "";

    assert(root.len > 0);
    assert(fixture.name.len > 0);

    if (residue.carried.contains(fixture.name)) {
        try residue.named.append(gpa, fixture.name);

        try require(
            try walk_diverges(gpa, machine, root, fixture),
            "{s} matches its {s}golden and needs no residue row",
            .{ fixture.name, where },
        );
    }

    if (residue.scoped.contains(fixture.name)) {
        try residue.named.append(gpa, fixture.name);

        try require(
            try scopes_diverge(gpa, machine, root, fixture),
            "{s} binds the scopes its {s}golden records and needs no residue row",
            .{ fixture.name, where },
        );
    }
}

fn census_against_corpus(
    gpa: std.mem.Allocator,
    machine: *Machine,
    root: []const u8,
    fixture: *const Fixture,
) !Outcome {
    assert(root.len <= std.math.maxInt(u32));

    var golden: Golden = undefined;
    if (!try python.golden(gpa, root, fixture.name, &golden)) return .abstained;
    defer golden.deinit(gpa);

    assert(root.len > 0);

    assert(fixture.name.len > 0);

    _ = try machine.parse(fixture.source);

    try census_matches(machine, golden.ast.items, fixture.name);
    try tally.agree(suite, "census", fixture.name);

    return .compared;
}

fn walk_against_corpus(
    gpa: std.mem.Allocator,
    machine: *Machine,
    root: []const u8,
    fixture: *const Fixture,
    differing: ?*Differing,
) !Walked {
    if (differing) |held| assert(held.text.items.len <= held.text.capacity);
    assert(root.len <= std.math.maxInt(u32));

    var golden: Golden = undefined;
    if (!try python.golden(gpa, root, fixture.name, &golden)) return .abstained;
    defer golden.deinit(gpa);

    assert(root.len > 0);

    assert(fixture.name.len > 0);

    _ = try machine.parse(fixture.source);

    const length: u32 = @intCast(fixture.source.len);
    if (try machine.walk_matches(gpa, length, golden.ast.items)) return .matches;

    if (differing) |shown| {
        try report(gpa, &shown.text, fixture.name, machine.held.items, machine.expected.items);
        shown.noted();
    }

    return .differs;
}

fn scope_against_corpus(
    gpa: std.mem.Allocator,
    machine: *Machine,
    root: []const u8,
    fixture: *const Fixture,
    differing: ?*Differing,
) !Walked {
    if (differing) |held| assert(held.text.items.len <= held.text.capacity);
    assert(root.len <= std.math.maxInt(u32));

    var golden: Golden = undefined;
    if (!try python.golden(gpa, root, fixture.name, &golden)) return .abstained;
    defer golden.deinit(gpa);

    assert(root.len > 0);

    assert(fixture.name.len > 0);

    _ = try machine.parse(fixture.source);

    try require(try machine.bind_tables(fixture.source), "{s} overran", .{fixture.name});

    const held = try machine.scopes(fixture.source);
    const wanted = golden.scopes.items;
    if (scopes_equal(held, wanted)) return .matches;

    if (differing) |shown| {
        try scope_report(gpa, &shown.text, fixture.name, held, wanted);
        shown.noted();
    }

    return .differs;
}

fn census_matches(machine: *const Machine, rows: []const Row, name: []const u8) !void {
    assert(rows.len <= std.math.maxInt(u32));

    const held = machine.census();
    const expected = census_of(rows);

    assert(name.len > 0);
    assert(held.len == expected.len);

    try require(
        std.meta.eql(held, expected),
        "{s} counts its statements differently: {any} against {any}",
        .{ name, held, expected },
    );
}

fn differing_fail(
    differing: *const Differing,
    compared: u32,
    comptime variable: []const u8,
    comptime verb: []const u8,
) !void {
    assert(differing.count <= compared);
    assert(differing.shown_end <= differing.text.items.len);
    assert(variable.len <= std.math.maxInt(u32));
    assert(verb.len <= std.math.maxInt(u32));

    if (differing.count == 0) return;

    var path_bytes: [environment.value_bytes_max]u8 = undefined;

    if (environment.get(variable, &path_bytes)) |path| {
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{
            .sub_path = path,
            .data = differing.text.items,
        });
    }

    std.debug.print("{d} of {d} corpus files " ++ verb ++ "\n{s}", .{
        differing.count,
        compared,
        differing.text.items[0..differing.shown_end],
    });

    return error.TestUnexpectedResult;
}

fn golden_held(
    gpa: std.mem.Allocator,
    root: []const u8,
    name: []const u8,
    golden: *Golden,
) !void {
    assert(root.len > 0);
    assert(name.len > 0);

    const found = try python.golden(gpa, root, name, golden);

    try require(found, "{s} has no golden", .{name});
}

fn census_of(rows: []const Row) Census {
    assert(rows.len <= std.math.maxInt(u32));

    var found: Census = @splat(0);
    var counted: u32 = 0;

    for (rows) |row| {
        const index = statement_index(row.name) orelse continue;

        found[index] += 1;
        counted += 1;
    }

    assert(counted <= rows.len);
    assert(std.mem.findScalar(u32, &found, counted + 1) == null);

    return found;
}

fn statement_index(name: []const u8) ?usize {
    assert(statements.len > 0);
    assert(statements[0].len > 0);
    assert(name.len > 0);

    for (statements, 0..) |statement, index| {
        if (std.mem.eql(u8, statement, name)) return index;
    }

    return null;
}

fn oracle_name(name: []const u8) []const u8 {
    assert(name.len > 0);
    assert(renamed.len > 0);

    for (renamed) |entry| {
        if (std.mem.eql(u8, entry[0], name)) return entry[1];
    }

    return name;
}

fn synthetic(name: []const u8) bool {
    assert(name.len > 0);
    assert(synthetic_names.len > 0);

    return names_contain(&synthetic_names, name);
}

fn keys_of(keys: []const Key, scope: u32, name: ?[]const u8) []const Key {
    assert(keys.len <= std.math.maxInt(u32));
    assert(scope <= scope_count_max);
    if (name) |held| assert(held.len <= std.math.maxInt(u32));

    const probe: Probe = .{ .name = name, .scope = scope };
    const range = std.sort.equalRange(Key, keys, probe, Probe.order);

    assert(range[0] <= range[1]);
    assert(range[1] <= keys.len);

    return keys[range[0]..range[1]];
}

fn isolating(kind: BindingKind) bool {
    if (kind == .comprehension_target) return false;

    const result = switch (kind) {
        .assignment,
        .class_def,
        .function_def,
        .import,
        .parameter,
        .pattern_capture,
        .type_parameter,
        .walrus_target,
        => true,
        .comprehension_target, .global, .nonlocal => false,
    };

    if (kind == .global) assert(!result);
    if (kind == .parameter) assert(result);

    return result;
}

fn name_less_than(context: void, left: []const u8, right: []const u8) bool {
    _ = context;

    assert(left.len > 0);
    assert(right.len > 0);

    return std.mem.lessThan(u8, left, right);
}

fn symbols_contain(symbols: []const Symbol, name: []const u8) bool {
    assert(name.len > 0);
    assert(symbols.len <= binding_count_max + reference_count_max + state_count_max);

    for (symbols) |symbol| {
        if (std.mem.eql(u8, symbol.name, name)) return true;
    }

    return false;
}

fn rows_equal(held: []const Row, expected: []const Row) bool {
    if (held.len != expected.len) return false;

    for (held, expected) |left, right| {
        if (left.order(right) != .eq) return false;
    }

    return true;
}

fn rows_contain(rows: []const Row, held: Row) bool {
    assert(held.name.len > 0);
    assert(rows.len <= node_count_max);

    return std.sort.binarySearch(Row, rows, held, Row.order) != null;
}

fn rows_named(rows: []const Row, name: []const u8) u32 {
    var found: u32 = 0;

    assert(name.len > 0);
    assert(rows.len <= node_count_max);

    for (rows) |row| {
        if (std.mem.eql(u8, row.name, name)) found += 1;
    }

    assert(found <= rows.len);

    return found;
}

fn scopes_equal(held: []const ScopeRow, expected: []const ScopeRow) bool {
    if (held.len != expected.len) return false;

    for (held, expected) |left, right| {
        if (left.order(right) != .eq) return false;
    }

    return true;
}

fn scopes_contain(rows: []const ScopeRow, held: ScopeRow) bool {
    assert(held.kind.len > 0);
    assert(rows.len <= scope_count_max);

    for (rows) |row| {
        if (row.order(held) == .eq) return true;
    }

    return false;
}

fn report(
    gpa: std.mem.Allocator,
    lines: *std.ArrayList(u8),
    name: []const u8,
    held: []const Row,
    wanted: []const Row,
) !void {
    var shown: u32 = 0;

    assert(name.len > 0);
    assert(!rows_equal(held, wanted));

    try lines.print(gpa, "{s}: the walks differ\n", .{name});

    for (held) |row| {
        if (!rows_contain(wanted, row)) {
            try lines.print(gpa, "  extra   {s} {d} {d}\n", .{ row.name, row.offset, row.end });
            shown += 1;
        }

        if (shown > report_extra_max) return;
    }

    for (wanted) |row| {
        if (!rows_contain(held, row)) {
            try lines.print(gpa, "  missing {s} {d} {d}\n", .{ row.name, row.offset, row.end });
            shown += 1;
        }

        if (shown > report_missing_max) return;
    }
}

fn scope_report(
    gpa: std.mem.Allocator,
    lines: *std.ArrayList(u8),
    name: []const u8,
    held: []const ScopeRow,
    wanted: []const ScopeRow,
) !void {
    var shown: u32 = 0;

    assert(name.len > 0);
    assert(!scopes_equal(held, wanted));

    try lines.print(gpa, "{s}: the scopes differ\n", .{name});

    for (held) |row| {
        if (!scopes_contain(wanted, row)) {
            try scope_report_row(gpa, lines, "extra  ", row);
            shown += 1;
        }

        if (shown > scope_extra_max) return;
    }

    for (wanted) |row| {
        if (!scopes_contain(held, row)) {
            try scope_report_row(gpa, lines, "missing", row);
            shown += 1;
        }

        if (shown > scope_missing_max) return;
    }
}

fn scope_report_row(
    gpa: std.mem.Allocator,
    lines: *std.ArrayList(u8),
    label: []const u8,
    row: ScopeRow,
) !void {
    assert(row.kind.len > 0);

    const lines_before = lines.items.len;

    assert(label.len == "missing".len);

    try lines.print(gpa, "  {s} {s} {s} {d} {s}\n", .{
        label,
        row.kind,
        row.name,
        row.line,
        row.symbols,
    });

    assert(lines.items.len > lines_before);
}

fn names_contain(names: []const []const u8, name: []const u8) bool {
    assert(name.len > 0);
    assert(names.len <= file_count_max);

    for (names) |held| {
        if (std.mem.eql(u8, held, name)) return true;
    }

    return false;
}

fn acceptance_expect(
    gpa: std.mem.Allocator,
    accepted: []const []const u8,
    rejected: []const []const u8,
) !void {
    assert(accepted.len + rejected.len > 0);

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    for (accepted) |source| {
        _ = try machine.parse(source);

        const errors = machine.tree.diagnostic_slice();

        try require(errors.len == 0, "\"{s}\" reported an error", .{source});
    }

    for (rejected) |source| {
        _ = try machine.parse(source);

        const errors = machine.tree.diagnostic_slice();

        try require(errors.len > 0, "\"{s}\" parsed without an error", .{source});
    }
}

fn require(condition: bool, comptime format: []const u8, arguments: anytype) !void {
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    if (condition) return;

    std.debug.print(format ++ "\n", arguments);

    return error.TestUnexpectedResult;
}

fn echo_span(view: View) ?Span {
    if (view.kind() != .constant) return null;

    const field = view.parent() orelse return null;
    if (field.kind() != .formatted_value) return null;
    if (view.token_end() == view.token_start()) return null;
    if (view.token_kind(view.token_end() - 1) != .equal) return null;

    const brace = view.token_at(field.token_start());
    var position = view.token_end();

    assert(view.token_kind(field.token_start()) == .brace_open);

    for (0..view.tokens.len) |_| {
        if (position >= view.tokens.len) return null;
        if (view.token_kind(position) != .comment) break;

        position += 1;
    }

    const start = brace.offset + brace.length;
    const terminator = view.token_at(position);

    assert(start <= terminator.offset);

    return .{ .offset = start, .length = terminator.offset - start };
}

fn walk_require(condition: bool, rows: []const Row, comptime message: []const u8) !void {
    comptime assert(message.len > 0);
    assert(rows.len <= node_count_max);

    if (condition) return;

    std.debug.print(message ++ "\n", .{});

    for (rows) |row| {
        std.debug.print("  {s} {d} {d}\n", .{ row.name, row.offset, row.end });
    }

    return error.TestUnexpectedResult;
}

test "classify is total over the fixtures" {
    const gpa = std.testing.allocator;
    var found = try fixtures(gpa);
    defer found.deinit(gpa);

    try require(found.slice().len > 0, "{s} holds no source", .{fixture_root});

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    for (found.slice()) |*fixture| {
        try require(machine.run(fixture.source), "{s} overran", .{fixture.name});

        const errors = std.mem.countScalar(Kind, machine.raw.const_slice(), .error_token);

        try require(errors == 0, "{s} classifies to an ErrorToken", .{fixture.name});
        try std.testing.expectEqual(machine.raw.count(), machine.tokens.count());
    }
}

test "the gaps over the fixtures hold only blank bytes" {
    const gpa = std.testing.allocator;
    var found = try fixtures(gpa);
    defer found.deinit(gpa);

    try require(found.slice().len > 0, "{s} holds no source", .{fixture_root});

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    for (found.slice()) |*fixture| {
        _ = machine.run(fixture.source);

        try gaps_are_blank(fixture.source, machine.tokens.slice(), fixture.name);
    }
}

test "classify is total on byte soup" {
    const gpa = std.testing.allocator;
    var random: Random = .init(0x2545_F491_4F6C_DD1D);
    var buffer: [soup_bytes_max]u8 = undefined;
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    for (0..soup_round_count) |round| {
        const source = soup(&random, &buffer);

        try require(machine.run(source), "round {d} overran", .{round});
        try std.testing.expectEqual(machine.raw.count(), machine.tokens.count());
        try gaps_are_blank(source, machine.tokens.slice(), "byte soup");
    }
}

test "the parser holds its invariants on byte soup" {
    const gpa = std.testing.allocator;
    var random: Random = .init(0x9E37_79B9_7F4A_7C15);
    var buffer: [soup_bytes_max]u8 = undefined;
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    for (0..soup_round_count) |round| {
        const source = soup(&random, &buffer);

        _ = try machine.parse(source);

        try invariants_hold(machine, "byte soup");

        const first = try gpa.dupe(Node, machine.tree.slice());
        defer gpa.free(first);

        _ = try machine.parse(source);
        errdefer std.debug.print("round {d} parses differently the second time\n", .{round});

        try std.testing.expectEqualSlices(Node, first, machine.tree.slice());
    }
}

test "classify runs the corpus without an unclaimed byte" {
    const gpa = std.testing.allocator;
    var found = try corpus_fixtures(gpa);
    defer found.deinit(gpa);

    if (found.slice().len == 0) return;

    var carried = try python.residue_of(gpa, residue_name, &not_python);
    defer carried.deinit(gpa);

    const counted = try corpus_checked(.classify, gpa, &carried, null, found.slice());

    try require(
        counted.carried == carried.fixtures.items.len,
        "tests/residue-python.json names a file the corpus does not carry",
        .{},
    );

    try require(
        counted.compared >= floor.corpus_classify_python,
        "the corpus lost its Python files: {d} classified, floor {d}",
        .{ counted.compared, floor.corpus_classify_python },
    );
}

test "the statement census matches the goldens" {
    const gpa = std.testing.allocator;
    var found = try fixtures(gpa);
    defer found.deinit(gpa);

    try require(found.slice().len > 0, "{s} holds no source", .{fixture_root});

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    var compared: u32 = 0;

    for (found.slice()) |*fixture| {
        var golden: Golden = undefined;

        try golden_held(gpa, golden_root, fixture.name, &golden);
        defer golden.deinit(gpa);

        const outcome = try machine.parse(fixture.source);

        try require(outcome == .complete, "{s}", .{fixture.name});
        try census_matches(machine, golden.ast.items, fixture.name);

        compared += 1;
    }

    try require(compared == found.slice().len, "a fixture went uncompared", .{});
}

test "the statement census matches the corpus goldens" {
    const gpa = std.testing.allocator;
    const held = corpus.named(.golden) orelse return;
    var found = try corpus_fixtures(gpa);
    defer found.deinit(gpa);

    if (found.slice().len == 0) return;

    var carried = try python.residue_of(gpa, residue_name, &not_python);
    defer carried.deinit(gpa);

    const counted = try corpus_checked(.census, gpa, &carried, held, found.slice());

    try require(
        counted.compared >= floor.corpus_census_python,
        "the corpus lost its Python files: {d} counted, {d} abstained, floor {d}",
        .{ counted.compared, counted.abstained, floor.corpus_census_python },
    );
}

test "the tree holds its invariants over the corpus" {
    const gpa = std.testing.allocator;
    var found = try corpus_fixtures(gpa);
    defer found.deinit(gpa);

    if (found.slice().len == 0) return;

    var carried = try python.residue_of(gpa, residue_name, &not_python);
    defer carried.deinit(gpa);

    _ = try corpus_checked(.invariants, gpa, &carried, null, found.slice());
}

test "an operator without the operands it owes is an error" {
    const gpa = std.testing.allocator;
    const sources = [_][]const u8{ "/", "*", "<", "==", "1 +", "x /", "/ x", "x ==" };

    const whole = [_][]const u8{
        "x = 1 + 2\n",
        "y = -1\n",
        "z = not a\n",
        "w = a if b else c\n",
        "v = a < b < c\n",
        "u = 3 .real\n",
        "t = 3.5.real\n",
        "s = 0x1 .real\n",
        "r = 3j.real\n",
    };

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    for (sources) |source| {
        _ = try machine.parse(source);

        const errors = machine.tree.diagnostic_slice();

        try require(errors.len > 0, "\"{s}\" parsed without an error", .{source});
    }

    for (whole) |source| {
        _ = try machine.parse(source);

        const errors = machine.tree.diagnostic_slice();

        try require(errors.len == 0, "\"{s}\" reported an error", .{source});
    }
}

test "a type parameter carries a default" {
    const gpa = std.testing.allocator;
    const source = "def read[Held = int]() -> Held:\n    return Held()\n";
    const length: u32 = source.len;
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    try std.testing.expectEqual(Structure.complete, try machine.parse(source));
    try machine.walk(gpa, length);

    const variable: Row = .{ .name = "TypeVar", .offset = 9, .end = 19 };
    const default: Row = .{ .name = "Name", .offset = 16, .end = 19 };
    const walk = machine.held.items;

    try walk_require(rows_contain(walk, variable), walk, "the type variable spans its default");
    try walk_require(rows_contain(walk, default), walk, "the default is its own name");
}

test "an except clause reads an unparenthesized tuple" {
    const gpa = std.testing.allocator;
    const source = "try:\n    pass\nexcept ValueError, TypeError:\n    pass\n";
    const length: u32 = source.len;
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    try std.testing.expectEqual(Structure.complete, try machine.parse(source));
    try machine.walk(gpa, length);

    const tuple: Row = .{ .name = "Tuple", .offset = 21, .end = 42 };
    const walk = machine.held.items;

    try walk_require(rows_contain(walk, tuple), walk, "the handler types are one tuple");
}

test "a lone unpacking in a subscript is a tuple" {
    const gpa = std.testing.allocator;
    const source = "held = Select[*tuple[Any, ...]]\n";
    const length: u32 = source.len;
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    try std.testing.expectEqual(Structure.complete, try machine.parse(source));
    try machine.walk(gpa, length);

    const tuple: Row = .{ .name = "Tuple", .offset = 14, .end = 30 };
    const starred: Row = .{ .name = "Starred", .offset = 14, .end = 30 };
    const walk = machine.held.items;

    try walk_require(rows_contain(walk, tuple), walk, "the lone unpacking is a tuple");
    try walk_require(rows_contain(walk, starred), walk, "the tuple holds the unpacking");
}

test "a literal before a debug field in the next part reaches the field brace" {
    const gpa = std.testing.allocator;
    const source = "held = f\"a, \" f\"{b=}c\"\nplain = f\"a\" f\"{b}\"\n";
    const length: u32 = source.len;
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    try std.testing.expectEqual(Structure.complete, try machine.parse(source));
    try machine.walk(gpa, length);

    const reaching: Row = .{ .name = "Constant", .offset = 9, .end = 16 };
    const echoed: Row = .{ .name = "Constant", .offset = 17, .end = 19 };
    const kept: Row = .{ .name = "Constant", .offset = 33, .end = 34 };
    const walk = machine.held.items;

    try walk_require(rows_contain(walk, reaching), walk, "the literal reaches the brace");
    try walk_require(rows_contain(walk, echoed), walk, "the debug text is its own constant");
    try walk_require(rows_contain(walk, kept), walk, "a plain field leaves the literal alone");
}

test "the debug text spans the bytes between the field brace and its terminator" {
    const gpa = std.testing.allocator;

    const source = "a = f\"{x = !r}\"\nb = f\"{ y = }\"\n" ++
        "c = f\"\"\"{z = # c\n:>3}\"\"\"\nd = f\"{w=}\"\n";

    const length: u32 = source.len;
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    try std.testing.expectEqual(Structure.complete, try machine.parse(source));
    try machine.walk(gpa, length);

    const converted: Row = .{ .name = "Constant", .offset = 7, .end = 11 };
    const padded: Row = .{ .name = "Constant", .offset = 23, .end = 28 };
    const commented: Row = .{ .name = "Constant", .offset = 40, .end = 48 };
    const bare: Row = .{ .name = "Constant", .offset = 63, .end = 65 };
    const walk = machine.held.items;

    try walk_require(rows_contain(walk, converted), walk, "the debug text reaches the conversion");
    try walk_require(rows_contain(walk, padded), walk, "the debug text keeps its padding");
    try walk_require(rows_contain(walk, commented), walk, "the debug text passes a comment");
    try walk_require(rows_contain(walk, bare), walk, "a bare debug text ends at the brace");
}

test "a global declaration hides an enclosing binding from nested scopes" {
    const gpa = std.testing.allocator;

    const sources = [_][]const u8{
        "def outer():\n    global held\n    held = 1\n\n    def inner():\n" ++
            "        return held\n\n    return inner\n",
        "def outer():\n    global Held\n\n    class Held:\n        pass\n\n" ++
            "    class Child(Held):\n        def read(self):\n            return Held\n\n" ++
            "    return Child\n",
    };

    const wanted = [_]ScopeRow{
        .{ .kind = "function", .name = "inner", .line = 5, .symbols = "held:g" },
        .{ .kind = "class", .name = "Child", .line = 7, .symbols = "read:al" },
        .{ .kind = "function", .name = "read", .line = 8, .symbols = "Held:g,self:lp" },
    };

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    var found: u32 = 0;

    for (sources) |source| {
        _ = try machine.parse(source);

        try require(try machine.bind_tables(source), "the source overran", .{});

        const held = try machine.scopes(source);

        for (wanted) |row| {
            for (held) |scope| {
                if (!std.mem.eql(u8, scope.name, row.name)) continue;
                if (scope.line != row.line) continue;

                try std.testing.expectEqualStrings(row.kind, scope.kind);
                try std.testing.expectEqualStrings(row.symbols, scope.symbols);

                found += 1;
            }
        }
    }

    try std.testing.expectEqual(@as(u32, wanted.len), found);
}

test "a lambda inside an inlined comprehension closes over the names the comprehension binds" {
    const gpa = std.testing.allocator;

    const Case = struct {
        rows: []const ScopeRow,
        source: []const u8,
    };

    const cases = [_]Case{
        .{
            .rows = &.{
                .{ .kind = "function", .name = "lambda", .line = 1, .symbols = "dtyp:f,f:g,q:lp" },
            },
            .source = "x = [[lambda q: f(q, d=dtyp), {}] for dtyp in A]\n",
        },
        .{
            .rows = &.{
                .{ .kind = "class", .name = "C", .line = 1, .symbols = "K:g,k:al,y:al" },
                .{ .kind = "function", .name = "lambda", .line = 2, .symbols = "k:f" },
            },
            .source = "class C:\n    y = [lambda: k for k in K]\n",
        },
        .{
            .rows = &.{
                .{ .kind = "function", .name = "genexpr", .line = 1, .symbols = ".0:lp,_:al,m:f" },
                .{ .kind = "function", .name = "lambda", .line = 1, .symbols = "m:f" },
            },
            .source = "z = [(lambda: m for _ in R) for m in M]\n",
        },
    };

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    for (cases) |case| {
        _ = try machine.parse(case.source);

        try require(try machine.bind_tables(case.source), "the source overran", .{});

        const held = try machine.scopes(case.source);
        var found: u32 = 0;

        for (case.rows) |row| {
            for (held) |scope| {
                if (!std.mem.eql(u8, scope.name, row.name)) continue;
                if (scope.line != row.line) continue;

                try std.testing.expectEqualStrings(row.kind, scope.kind);
                try std.testing.expectEqualStrings(row.symbols, scope.symbols);

                found += 1;
            }
        }

        try std.testing.expectEqual(@as(u32, @intCast(case.rows.len)), found);
    }
}

test "a lambda reads the enclosing scope for a name the inlined comprehension does not bind" {
    const gpa = std.testing.allocator;

    const Case = struct {
        rows: []const ScopeRow,
        source: []const u8,
    };

    const cases = [_]Case{
        .{
            .rows = &.{
                .{
                    .kind = "function",
                    .name = "g",
                    .line = 1,
                    .symbols = "c:al,cols:g,formatters:al,self:lp",
                },
                .{ .kind = "function", .name = "lambda", .line = 2, .symbols = "c:lp,x:lp" },
            },
            .source = "def g(self):\n" ++
                "    formatters = {c: (lambda x, c=c: f\"{c}: {x}\") for c in cols}\n" ++
                "    return formatters\n",
        },
        .{
            .rows = &.{
                .{ .kind = "function", .name = "lambda", .line = 1, .symbols = "t:g" },
                .{ .kind = "function", .name = "lambda", .line = 2, .symbols = "n:g" },
            },
            .source = "u = [lambda: t for _ in T]\nr = lambda: n\ns = [n for n in N]\n",
        },
    };

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    for (cases) |case| {
        _ = try machine.parse(case.source);

        try require(try machine.bind_tables(case.source), "the source overran", .{});

        const held = try machine.scopes(case.source);
        var found: u32 = 0;

        for (case.rows) |row| {
            for (held) |scope| {
                if (!std.mem.eql(u8, scope.name, row.name)) continue;
                if (scope.line != row.line) continue;

                try std.testing.expectEqualStrings(row.kind, scope.kind);
                try std.testing.expectEqualStrings(row.symbols, scope.symbols);

                found += 1;
            }
        }

        try std.testing.expectEqual(@as(u32, @intCast(case.rows.len)), found);
    }
}

test "a literal pattern takes a complex number and only a minus sign" {
    const gpa = std.testing.allocator;

    const accepted = [_][]const u8{
        "match x:\n    case 1 + 2j:\n        pass\n",
        "match x:\n    case -1 - 2j:\n        pass\n",
        "match x:\n    case -1j:\n        pass\n",
        "match x:\n    case [1 + 2j, -3 - 4j]:\n        pass\n",
        "match x:\n    case {-1: y, 1 + 2j: z}:\n        pass\n",
    };

    const rejected = [_][]const u8{
        "match x:\n    case +1:\n        pass\n",
        "match x:\n    case 1 + 2:\n        pass\n",
        "match x:\n    case 1j + 2j:\n        pass\n",
        "match x:\n    case 1 + -2j:\n        pass\n",
        "match x:\n    case -\"a\":\n        pass\n",
    };

    try acceptance_expect(gpa, &accepted, &rejected);
}

test "a delete takes a trailing comma and an import only the targets its form allows" {
    const gpa = std.testing.allocator;

    const accepted = [_][]const u8{
        "del a, b,\n",
        "del a,; x = 1\n",
        "from a import (b, c,)\n",
        "from a import *\n",
        "from a import b, \\\n    c\n",
        "import a.b.c as d, e\n",
    };

    const rejected = [_][]const u8{
        "import a,\n",
        "import *\n",
        "from a import b,\n",
        "from a import *, b\n",
        "from a import b, *\n",
        "from a import (*)\n",
        "from a import b.c\n",
    };

    try acceptance_expect(gpa, &accepted, &rejected);
}

test "a dictionary entry takes one key and a lambda may be that key" {
    const gpa = std.testing.allocator;

    const accepted = [_][]const u8{
        "x = {lambda: a: b}\n",
        "x = {lambda d=1: d: e, f: g}\n",
        "x = {a: lambda d=1: d}\n",
        "x = {**a, b: c}\n",
        "x = {*a, b}\n",
        "x = y[lambda: a : b]\n",
        "x = 0x_1F + 0b_1 + 0o_7 + 0_0\n",
    };

    const rejected = [_][]const u8{
        "x = {a: b: c}\n",
        "x = {a: lambda: b: c}\n",
        "x = {a, b: c}\n",
        "x = {a: b, c}\n",
        "x = {a: b, **c, d}\n",
        "x = (lambda: a: b)\n",
        "x = 01\n",
    };

    try acceptance_expect(gpa, &accepted, &rejected);
}

test "a target, a condition and an argument list take only what the grammar allows" {
    const gpa = std.testing.allocator;

    const accepted = [_][]const u8{
        "(a) += 1\n",
        "a.b[0].c += 1\n",
        "self.x: int = 1\n",
        "if (a, b):\n    pass\n",
        "@a.b(c)\ndef f():\n    pass\n",
        "f(a, *b, c=1, **d)\n",
        "f(x for x in y if z)\n",
        "del a[*b], c\n",
    };

    const rejected = [_][]const u8{
        "a, b += 1\n",
        "[a] += 1\n",
        "f() += 1\n",
        "(a, b): int\n",
        "if a, b:\n    pass\n",
        "while a, b:\n    pass\n",
        "@a, b\ndef f():\n    pass\n",
        "type X = a, b\n",
        "f(**a, *b)\n",
        "f(a for a in b, c)\n",
        "f(c, a for a in b)\n",
        "del *a, b\n",
    };

    try acceptance_expect(gpa, &accepted, &rejected);
}

test "a mapping pattern key holds the whole complex number" {
    const gpa = std.testing.allocator;
    const source = "match x:\n    case {-1 + 2j: y}:\n        pass\n";
    const length: u32 = source.len;
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    try std.testing.expectEqual(Structure.complete, try machine.parse(source));
    try machine.walk(gpa, length);

    const number: Row = .{ .name = "BinOp", .offset = 19, .end = 26 };
    const walk = machine.held.items;

    try walk_require(rows_contain(walk, number), walk, "the key is one binary operation");
}

test "a bare yield stands only where the grammar takes one" {
    const gpa = std.testing.allocator;

    const accepted = [_][]const u8{
        "def g():\n    x = yield\n",
        "def g():\n    x = f\"{yield!r}\"\n",
        "def g():\n    x = f\"{yield:>10}\"\n",
        "def g():\n    with (yield):\n        pass\n",
        "def g():\n    f((yield))\n",
        "def g():\n    x = yield a, *b\n",
    };

    const rejected = [_][]const u8{
        "def g():\n    f(yield)\n",
        "def g():\n    x = 1 + yield\n",
        "def g():\n    return yield\n",
        "def g():\n    x = yield from\n",
        "def g():\n    yield from a, b\n",
        "def g():\n    x = (yield a for b in c)\n",
        "def g():\n    yield a := 1\n",
        "def g():\n    x = {yield: 1}\n",
    };

    try acceptance_expect(gpa, &accepted, &rejected);
}

test "a named expression binds one name where the grammar takes one" {
    const gpa = std.testing.allocator;

    const accepted = [_][]const u8{
        "if a := 1:\n    pass\n",
        "while a := b():\n    pass\n",
        "@a := b\ndef f():\n    pass\n",
        "x = (a := 1)\n",
        "f(a := 1)\n",
        "x = [a := 1, b := 2]\n",
        "x = a[b := 1]\n",
        "match a := b:\n    case 1:\n        pass\n",
        "class C(a := 1):\n    pass\n",
        "x = f\"{a := 1}\"\n",
        "x = (a := lambda: 1)\n",
        "x = [a := 1 for b in c]\n",
    };

    const rejected = [_][]const u8{
        "a := 1\n",
        "x = a := 1\n",
        "assert a := 1\n",
        "x = (a.b := 1)\n",
        "x = ((a) := 1)\n",
        "f(a=b := 1)\n",
        "x = {a: b := 1}\n",
        "x = {a := 1: 2}\n",
        "x = a[1:b := 2]\n",
        "x = a[b := 1:2]\n",
        "x = [a for a in b if c := 1]\n",
        "x = lambda: a := 1\n",
        "x = (a := b := 1)\n",
        "def f(a=b := 1):\n    pass\n",
    };

    try acceptance_expect(gpa, &accepted, &rejected);
}

test "an unpacking leads an element only where the grammar takes one" {
    const gpa = std.testing.allocator;

    const accepted = [_][]const u8{
        "x = *a, b\n",
        "x = *a\n",
        "f(*a or b)\n",
        "x = a[*b]\n",
        "x = [*a, *b]\n",
        "x = {**a, b: c}\n",
        "for *a, b in c:\n    pass\n",
        "x = [i for *a, b in c]\n",
        "x = [i for a, *b in c]\n",
        "with a as *b:\n    pass\n",
        "def f(*a: *b):\n    pass\n",
        "with (*a, b):\n    pass\n",
        "x = f\"{*a}\"\n",
        "f(a=1, *b, c=2)\n",
    };

    const rejected = [_][]const u8{
        "x = a + *b\n",
        "x = (*a)\n",
        "x = [*a for a in b]\n",
        "x = {**a for a in b}\n",
        "f(*a for a in b)\n",
        "x = a[*b:c]\n",
        "x = lambda: *a\n",
        "f(a=*b)\n",
        "x = {*a: 1}\n",
        "with *a:\n    pass\n",
        "if *a:\n    pass\n",
        "match *a:\n    case 1:\n        pass\n",
        "x = **a\n",
        "x = [*a or b]\n",
        "x = [*not a]\n",
        "def f(a: *b):\n    pass\n",
        "f(**a, b)\n",
        "f(a=1, b)\n",
        "class C(**a, b):\n    pass\n",
    };

    try acceptance_expect(gpa, &accepted, &rejected);
}

test "a prefix operator takes only the operands its level allows" {
    const gpa = std.testing.allocator;

    const accepted = [_][]const u8{
        "x = -await a\n",
        "x = not -a\n",
        "x = not not a\n",
        "x = a and not b\n",
        "x = a ** -b\n",
        "x = a if b else lambda: c\n",
        "f(*not a)\n",
        "x = [a for a in not b]\n",
    };

    const rejected = [_][]const u8{
        "x = await -a\n",
        "x = await await a\n",
        "x = -not a\n",
        "x = a + not b\n",
        "x = a < not b\n",
        "x = not lambda: a\n",
        "x = a and lambda: b\n",
        "x = a if lambda: b else c\n",
        "x = [a for a in lambda: b]\n",
        "x = [a for a in b, c]\n",
        "x = [a for a in b if c, d]\n",
    };

    try acceptance_expect(gpa, &accepted, &rejected);
}

test "a parameter list keeps the order the grammar sets" {
    const gpa = std.testing.allocator;

    const accepted = [_][]const u8{
        "def f(a, b=1, /, c=2, *d, e, f=3, **g):\n    pass\n",
        "def f(*, a):\n    pass\n",
        "def f(**a,):\n    pass\n",
        "x = lambda a, /, b=1, *, c: 0\n",
        "x = lambda *a, **b: 0\n",
    };

    const rejected = [_][]const u8{
        "def f(a=1, b):\n    pass\n",
        "def f(*):\n    pass\n",
        "def f(*, **a):\n    pass\n",
        "def f(**a, b):\n    pass\n",
        "def f(/):\n    pass\n",
        "def f(*a, /):\n    pass\n",
        "def f(*a=1):\n    pass\n",
        "x = lambda a=1, b: 0\n",
        "x = lambda *: 0\n",
        "x = lambda *,: 0\n",
        "x = lambda **a, b: 0\n",
    };

    try acceptance_expect(gpa, &accepted, &rejected);
}

test "a pattern takes only the forms the grammar allows" {
    const gpa = std.testing.allocator;

    const accepted = [_][]const u8{
        "match x:\n    case f\"x\":\n        pass\n",
        "match x:\n    case \"a\" f\"b\" | \"c\":\n        pass\n",
        "match x:\n    case {f\"x\": 1}:\n        pass\n",
        "match x:\n    case C(a, b=1):\n        pass\n",
        "match x:\n    case C(a=1 | 2):\n        pass\n",
        "match x:\n    case *a, b:\n        pass\n",
        "match x:\n    case (*a,):\n        pass\n",
        "match x:\n    case {a.b: 1, **r}:\n        pass\n",
        "match x:\n    case (a as b) | c:\n        pass\n",
        "match x:\n    case _ as a:\n        pass\n",
    };

    const rejected = [_][]const u8{
        "match x:\n    case a as b as c:\n        pass\n",
        "match x:\n    case a as _:\n        pass\n",
        "match x:\n    case a as b | c:\n        pass\n",
        "match x:\n    case *a:\n        pass\n",
        "match x:\n    case (*a):\n        pass\n",
        "match x:\n    case C(*a):\n        pass\n",
        "match x:\n    case C(a=1, b):\n        pass\n",
        "match x:\n    case {a: 1}:\n        pass\n",
        "match x:\n    case {**r, a.b: 1}:\n        pass\n",
        "match x:\n    case {**_}:\n        pass\n",
        "match x:\n    case [*a | b]:\n        pass\n",
        "match x:\n    case -f\"x\":\n        pass\n",
    };

    try acceptance_expect(gpa, &accepted, &rejected);
}

test "a try, an import and a format string keep the parts the grammar requires" {
    const gpa = std.testing.allocator;

    const accepted = [_][]const u8{
        "try:\n    pass\nexcept* a:\n    pass\n",
        "try:\n    pass\nfinally:\n    pass\n",
        "x = f\"a}}b\"\n",
    };

    const rejected = [_][]const u8{
        "from a import\n",
        "import\n",
        "try:\n    pass\nelse:\n    pass\n",
        "try:\n    pass\n",
        "try:\n    pass\nexcept* a:\n    pass\nexcept b:\n    pass\n",
        "try:\n    pass\nexcept*:\n    pass\n",
        "x = f\"a}b\"\n",
        "x = f\"{a}}\"\n",
    };

    try acceptance_expect(gpa, &accepted, &rejected);
}

test "a compound statement takes an indented block" {
    const gpa = std.testing.allocator;

    const accepted = [_][]const u8{
        "if x: pass\n",
        "if x:\n    pass\n",
        "with a:\n    # c\n    pass\n",
        "def g():\n    for x in (\n    a\n):\n        pass\n",
    };

    const rejected = [_][]const u8{
        "if x:\npass\n",
        "def f():\nreturn 1\n",
        "class C:\n\nx = 1\n",
        "if x:\n",
        "while x:\n    pass\nelse:\npass\n",
        "def g():\n    for x in (\n    a\n):\n    pass\n",
    };

    try acceptance_expect(gpa, &accepted, &rejected);
}

test "a flat literal is not nesting" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);

    var dict: std.ArrayList(u8) = .empty;
    defer dict.deinit(gpa);

    var tuple: std.ArrayList(u8) = .empty;
    defer tuple.deinit(gpa);

    try list.appendSlice(gpa, "held = [");
    try dict.appendSlice(gpa, "held = {");
    try tuple.appendSlice(gpa, "held = (");

    for (0..element_count) |index| {
        try list.print(gpa, "{d}, ", .{index});
        try dict.print(gpa, "\"k{d}\": {d}, ", .{ index, index });
        try tuple.print(gpa, "{d}, ", .{index});
    }

    try list.appendSlice(gpa, "]\n");
    try dict.appendSlice(gpa, "}\n");
    try tuple.appendSlice(gpa, ")\n");

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    const literals = [_]Construct{
        .{ .name = "a list", .source = list.items },
        .{ .name = "a dict", .source = dict.items },
        .{ .name = "a tuple", .source = tuple.items },
    };

    for (literals) |literal| {
        const outcome = try machine.parse(literal.source);
        const errors = machine.tree.diagnostic_slice();

        try require(
            outcome == .complete,
            "{s} of {d} elements does not parse whole",
            .{ literal.name, element_count },
        );

        try require(
            errors.len == 0,
            "{s} of {d} elements parses with {any}",
            .{ literal.name, element_count, errors },
        );
    }
}

test "a literal reads back as the kind its brackets name" {
    const gpa = std.testing.allocator;

    const held = [_]Construct{
        .{ .name = "Dict", .source = "held = {}\n" },
        .{ .name = "Dict", .source = "held = {1: 2}\n" },
        .{ .name = "Set", .source = "held = {1}\n" },
        .{ .name = "Set", .source = "held = {1, 2}\n" },
        .{ .name = "Set", .source = "held = {1,}\n" },
        .{ .name = "Tuple", .source = "held = (1,)\n" },
    };

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    for (held) |literal| {
        _ = try machine.parse(literal.source);

        const length: u32 = @intCast(literal.source.len);

        try machine.walk(gpa, length);

        const walk = machine.held.items;

        try walk_require(rows_named(walk, literal.name) > 0, walk, "the literal reads as its kind");
    }
}

test "the normalized walk matches the goldens" {
    const gpa = std.testing.allocator;
    var carried = try python.residue_of(gpa, residue_name, &every_category);
    defer carried.deinit(gpa);

    var found = try fixtures(gpa);
    defer found.deinit(gpa);

    try require(found.slice().len > 0, "{s} holds no source", .{fixture_root});

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    var lines: std.ArrayList(u8) = .empty;
    defer lines.deinit(gpa);

    var compared: u32 = 0;

    for (found.slice()) |*fixture| {
        if (carried.contains(fixture.name)) continue;

        var golden: Golden = undefined;

        try golden_held(gpa, golden_root, fixture.name, &golden);
        defer golden.deinit(gpa);

        _ = try machine.parse(fixture.source);

        const length: u32 = @intCast(fixture.source.len);

        if (!try machine.walk_matches(gpa, length, golden.ast.items)) {
            try report(gpa, &lines, fixture.name, machine.held.items, machine.expected.items);
            std.debug.print("{s}", .{lines.items});

            return error.TestUnexpectedResult;
        }

        compared += 1;
    }

    try require(
        compared >= floor.fixture_walk_python,
        "the Python fixtures lost a walk: {d} compared, floor {d}",
        .{ compared, floor.fixture_walk_python },
    );
}

test "the normalized walk matches the corpus goldens" {
    const gpa = std.testing.allocator;
    const held = corpus.named(.golden) orelse return;
    var found = try corpus_fixtures(gpa);
    defer found.deinit(gpa);

    if (found.slice().len == 0) return;

    var carried = try python.residue_of(gpa, residue_name, &every_category);
    defer carried.deinit(gpa);

    const counted = try corpus_checked(.walk, gpa, &carried, held, found.slice());
    const named: u32 = counted.compared + @as(u32, @intCast(carried.fixtures.items.len));

    try require(
        named >= floor.corpus_walk_python,
        "the corpus lost its Python files: {d} named, {d} abstained, floor {d}",
        .{ named, counted.abstained, floor.corpus_walk_python },
    );

    try differing_reported(.walk, gpa, &carried, held, found.slice(), &counted);
}

test "the scope tables match the goldens" {
    const gpa = std.testing.allocator;
    var carried = try python.residue_of(gpa, residue_name, &scope_category);
    defer carried.deinit(gpa);

    var found = try fixtures(gpa);
    defer found.deinit(gpa);

    try require(found.slice().len > 0, "{s} holds no source", .{fixture_root});

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    var lines: std.ArrayList(u8) = .empty;
    defer lines.deinit(gpa);

    var compared: u32 = 0;

    for (found.slice()) |*fixture| {
        if (carried.contains(fixture.name)) continue;

        var golden: Golden = undefined;

        try golden_held(gpa, golden_root, fixture.name, &golden);
        defer golden.deinit(gpa);

        _ = try machine.parse(fixture.source);

        try require(try machine.bind_tables(fixture.source), "{s} overran", .{fixture.name});

        const scopes = try machine.scopes(fixture.source);

        if (!scopes_equal(scopes, golden.scopes.items)) {
            try scope_report(gpa, &lines, fixture.name, scopes, golden.scopes.items);

            std.debug.print("{s} binds its scopes differently\n{s}", .{
                fixture.name,
                lines.items,
            });

            return error.TestUnexpectedResult;
        }

        compared += 1;
    }

    try require(
        compared >= floor.fixture_scope_python,
        "the Python fixtures lost a scope table: {d} compared, floor {d}",
        .{ compared, floor.fixture_scope_python },
    );
}

test "the scope tables match the corpus goldens" {
    const gpa = std.testing.allocator;
    const held = corpus.named(.golden) orelse return;
    var found = try corpus_fixtures(gpa);
    defer found.deinit(gpa);

    if (found.slice().len == 0) return;

    var carried = try python.residue_of(gpa, residue_name, &scope_category);
    defer carried.deinit(gpa);

    const counted = try corpus_checked(.scope, gpa, &carried, held, found.slice());
    const named: u32 = counted.compared + @as(u32, @intCast(carried.fixtures.items.len));

    try require(
        named >= floor.corpus_scope_python,
        "the corpus lost its Python files: {d} named, {d} abstained, floor {d}",
        .{ named, counted.abstained, floor.corpus_scope_python },
    );

    try differing_reported(.scope, gpa, &carried, held, found.slice(), &counted);
}

test "every residue row names a file that diverges" {
    const gpa = std.testing.allocator;
    var carried = try python.residue_of(gpa, residue_name, &every_category);
    defer carried.deinit(gpa);

    var scoped = try python.residue_of(gpa, residue_name, &scopes_only);
    defer scoped.deinit(gpa);

    var named: std.ArrayList([]const u8) = .empty;
    defer named.deinit(gpa);

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    var found = try fixtures(gpa);
    defer found.deinit(gpa);

    const residue: Residues = .{
        .carried = &carried,
        .corpus_held = false,
        .named = &named,
        .scoped = &scoped,
    };

    for (found.slice()) |*fixture| {
        try residue_diverges(gpa, machine, golden_root, fixture, &residue);
    }

    const held = corpus.named(.golden) orelse return;
    var found_corpus = try corpus_fixtures(gpa);
    defer found_corpus.deinit(gpa);

    const residue_corpus: Residues = .{
        .carried = &carried,
        .corpus_held = true,
        .named = &named,
        .scoped = &scoped,
    };

    for (found_corpus.slice()) |*fixture| {
        const touched = carried.contains(fixture.name) or scoped.contains(fixture.name);
        if (!touched) continue;
        if (!machine.complete(fixture.source)) continue;

        try residue_diverges(gpa, machine, held, fixture, &residue_corpus);
    }

    for ([_]*const oracle.Residue{ &carried, &scoped }) |rows| {
        for (rows.fixtures.items) |name| {
            try require(
                names_contain(named.items, name),
                "the residue names `{s}` and neither the fixtures nor the corpus carry it",
                .{name},
            );
        }
    }
}

test "a syntax error names the kind it expected and the kind it found" {
    const gpa = std.testing.allocator;
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    _ = try machine.parse("for x y:\n    pass\n");

    try std.testing.expect(machine.tree.diagnostic_slice().len > 0);

    const held = machine.tree.diagnostic_slice()[0];

    try std.testing.expectEqual(Kind.in_keyword, held.expected_kind(Kind).?);
    try std.testing.expectEqual(Kind.identifier, held.found_kind(Kind).?);

    const ended_source = "x = 1 +";

    _ = try machine.parse(ended_source);

    try std.testing.expect(machine.tree.diagnostic_slice().len > 0);

    const ended = machine.tree.diagnostic_slice()[0];

    try std.testing.expectEqual(ended_source.len, ended.span.offset);
    try std.testing.expectEqual(0, ended.span.length);

    try std.testing.expectEqual(null, ended.expected_kind(Kind));
    try std.testing.expectEqual(null, ended.found_kind(Kind));
}

test "a format string field takes a comment where CPython does" {
    const gpa = std.testing.allocator;

    const accepted = [_][]const u8{
        "x = f\"\"\"{y!r # c\n}\"\"\"\n",
        "x = f\"\"\"{y = !r # c\n}\"\"\"\n",
        "x = f\"\"\"{y = # c\n}\"\"\"\n",
        "x = f\"\"\"{y = # c\n# d\n}\"\"\"\n",
        "x = f\"\"\"{y!r # c\n:>3}\"\"\"\n",
        "x = f\"{y = # c\n}\"\n",
        "x = f\"\"\"{y # {\n}\"\"\"\n",
        "x = f\"\"\"{y # c \"\"\"\n}\"\"\"\n",
        "x = f'{y:\"^5}'\n",
        "x = f'{y:{x}{{}'\n",
    };

    const rejected = [_][]const u8{
        "x = f\"{y = # c}\"\n",
        "x = f'{y # c}'\n",
        "x = f\"\"\"{y!r # c}\"\"\"\n",
        "x = f'{y:'}'\n",
        "x = f'{y:}}'\n",
        "x = f'{a:{b:{c:{d}}}}'\n",
    };

    try acceptance_expect(gpa, &accepted, &rejected);
}

test "a format string field takes one conversion and its parts in order" {
    const gpa = std.testing.allocator;

    const accepted = [_][]const u8{
        "x = f'{a!r}'\n",
        "x = f'{a!s:>3}'\n",
        "x = f'{a=!a}'\n",
        "x = f'{a, b}'\n",
        "x = f'{a!=b}'\n",
        "x = f'{a:{b:{c}}}'\n",
    };

    const rejected = [_][]const u8{
        "x = f'{a!x}'\n",
        "x = f'{a!}'\n",
        "x = f'{a!rr}'\n",
        "x = f'{a!r!s}'\n",
        "x = f'{a!r=}'\n",
        "x = f'{}'\n",
        "x = f'{a:{}}'\n",
        "x = f'{,}'\n",
        "x = f\"\" {y}\n",
    };

    try acceptance_expect(gpa, &accepted, &rejected);
}

test "an expression rejects a missing operand, else, body, key, or index" {
    const gpa = std.testing.allocator;

    const accepted = [_][]const u8{
        "x = (lambda: 1)\n",
        "x = {1: 2, **a}\n",
        "x = {**a, 'k': 1}\n",
        "x = a[:]\n",
        "x = a[::2]\n",
        "x = a[1:2, ::]\n",
        "x = [a for b in c if d]\n",
        "x = a if b else c if d else e\n",
        "x = lambda x=1, y=2: x\n",
        "x = f(*a, **b)\n",
        "x = a < b < c\n",
    };

    const rejected = [_][]const u8{
        "x = (1\n",
        "x = [1\n",
        "x = {\n",
        "x = [a if b]\n",
        "x = a if b else c else d\n",
        "x = lambda:\n",
        "x = (lambda: )\n",
        "x = {:1}\n",
        "x = {1: }\n",
        "x = a[]\n",
        "x = [][]\n",
        "x.\n",
        "x = (lambda x(): 1)\n",
        "x = [a for]\n",
        "x = [a for in b]\n",
        "x = a in < b\n",
        "x = a < b <\n",
        "x = [a, (and b)]\n",
        "x = lambda x=: 1\n",
        "x = {'': for y in b}\n",
        "x = (for y in b)\n",
        "x = a[:::]\n",
        "x = f(*y=1)\n",
        "x = a[f:and b]\n",
    };

    try acceptance_expect(gpa, &accepted, &rejected);
}

test "a dedent that lands between two levels or a bare base prefix is an error" {
    const gpa = std.testing.allocator;

    const accepted = [_][]const u8{
        "if x:\n    a\nb\n",
        "x = 0x_ff\n",
    };

    const rejected = [_][]const u8{
        "if x:\n    a\n  b\n",
        "for i in x:\n  s\n a\n",
        "x = 0or 1\n",
    };

    try acceptance_expect(gpa, &accepted, &rejected);
}
