const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const Binding = @import("semantic.zig").Semantic.Binding;
const EventsType = @import("../tree.zig").EventsType;
const Kind = @import("kind.zig").Kind;
const Namespace = @FieldType(@import("semantic.zig").Semantic.Binding, "namespace");
const Parser = @import("parse.zig").Parser;
const Reference = @import("semantic.zig").Semantic.Reference;
const Semantic = @import("semantic.zig").Semantic;
const Token = @import("../token.zig");
const Tokens = @import("../tokens.zig");
const TreeType = @import("../tree.zig").TreeType;
const corpus = @import("../../testing/corpus.zig");
const environment = @import("../../testing/environment.zig");
const floor = @import("../../testing/floor.zig");
const lex = @import("lex.zig").lex;
const raw_of = @import("../raw.zig").raw_of;
const stripe = @import("../../testing/stripe.zig");
const tally = @import("../../testing/tally.zig");
const Events = EventsType(Kind);
const Tree = TreeType(Kind);

const Machine = struct {
    events: Events,
    parser: Parser,
    raw: ArrayType(Kind),
    semantic: Semantic,
    tokens: Tokens,
    tree: Tree,

    fn create(gpa: std.mem.Allocator) !*Machine {
        const machine = try gpa.create(Machine);
        errdefer gpa.destroy(machine);

        try machine.events.init(gpa, event_count_max);
        errdefer machine.events.deinit(gpa);

        machine.raw = try .init(gpa, token_count_max);
        errdefer machine.raw.deinit(gpa);

        machine.tokens = try .init(gpa, token_count_max);
        errdefer machine.tokens.deinit(gpa);

        machine.tree = try .init(gpa, node_count_max, diagnostic_count_max);
        errdefer machine.tree.deinit(gpa);

        try machine.semantic.init(gpa, &.{
            .binding_count_max = table_count_max,
            .fact_count_max = table_count_max,
            .reference_count_max = table_count_max,
            .scope_count_max = table_count_max,
        });

        assert(machine.raw.capacity() == machine.tokens.items.capacity());
        assert(machine.semantic.count() == 0);

        return machine;
    }

    fn destroy(machine: *Machine, gpa: std.mem.Allocator) void {
        assert(machine.raw.capacity() == token_count_max);
        assert(machine.tokens.items.capacity() == token_count_max);

        machine.semantic.deinit(gpa);
        machine.tree.deinit(gpa);
        machine.tokens.deinit(gpa);
        machine.raw.deinit(gpa);
        machine.events.deinit(gpa);
        gpa.destroy(machine);
    }

    fn build(machine: *Machine, source: []const u8) bool {
        assert(source.len <= std.math.maxInt(u32));

        machine.tokens.clear();

        lex(source, &machine.tokens) catch |err| switch (err) {
            error.Truncated => return false,
        };

        raw_of(Kind, machine.tokens.slice(), &machine.raw) catch |err| switch (err) {
            error.Truncated => return false,
        };

        assert(machine.raw.count() == machine.tokens.count());

        _ = machine.parser.build(
            source,
            machine.tokens.slice(),
            machine.raw.const_slice(),
            &machine.events,
            &machine.tree,
        );

        if (machine.tree.diagnostic_slice().len != 0) return false;

        const held = machine.semantic.build(
            source,
            machine.tokens.slice(),
            machine.raw.const_slice(),
            &machine.tree,
            &universe,
        );

        return held == .complete;
    }

    fn binding_at(machine: *const Machine, offset: u32) ?Binding {
        const bindings = machine.semantic.binding_slice();

        assert(bindings.len <= table_count_max);

        for (bindings) |held| {
            if (held.name.offset == offset) return held;
        }

        return null;
    }

    fn reference_at(machine: *const Machine, offset: u32) ?Reference {
        const references = machine.semantic.reference_slice();

        assert(references.len <= table_count_max);

        for (references) |held| {
            if (held.name.offset == offset) return held;
        }

        return null;
    }

    fn conditional(machine: *const Machine, source: []const u8, offset: u32) bool {
        assert(source.len <= std.math.maxInt(u32));
        assert(offset < none);

        const reference = machine.reference_at(offset) orelse return false;

        const index = switch (reference.resolution) {
            .bound => |index| index,
            .builtin, .external, .maybe, .unresolved => return false,
        };

        const bindings = machine.semantic.binding_slice();
        const scopes = machine.semantic.scope_slice();

        assert(bindings.len <= table_count_max);
        assert(scopes.len <= table_count_max);

        if (index >= bindings.len) return false;

        const binding = bindings[index];
        if (binding.scope >= scopes.len) return false;
        if (scopes[binding.scope].kind.is_ordered()) return false;

        const name = binding.name.text(source);
        var repeated: u32 = 0;

        for (bindings) |held| {
            if (held.scope != binding.scope) continue;
            if (!std.mem.eql(u8, held.name.text(source), name)) continue;

            repeated += 1;
        }

        assert(repeated >= 1);

        return repeated > 1;
    }

    fn reachable(machine: *const Machine, offset: u32, landing: u32) bool {
        assert(offset < none);
        assert(landing < none);

        const reference = machine.reference_at(offset) orelse return false;
        const binding = machine.binding_at(landing) orelse return false;
        const scopes = machine.semantic.scope_slice();

        assert(scopes.len <= table_count_max);
        assert(binding.name.offset == landing);

        var scope = reference.scope;

        for (0..scopes.len + 1) |_| {
            if (scope == binding.scope) return true;
            if (scope >= scopes.len) return false;

            const held = scopes[scope];
            if (held.parent == none) return false;

            scope = held.parent;
        }

        return false;
    }

    fn declares(machine: *const Machine, offset: u32) bool {
        const bindings = machine.semantic.binding_slice();

        assert(bindings.len <= table_count_max);
        assert(every_namespace.len == 5);

        for (bindings) |held| {
            if (held.name.offset != offset) continue;

            for (every_namespace) |namespace| {
                if (held.kind.opens(namespace)) return true;
            }
        }

        return false;
    }

    fn invokes(machine: *const Machine, offset: u32, landing: u32) bool {
        assert(offset < none);

        const reference = machine.reference_at(offset) orelse return false;
        const bindings = machine.semantic.binding_slice();

        assert(bindings.len <= table_count_max);
        assert(reference.name.offset == offset);

        if (reference.namespace != .macro) return false;

        for (bindings) |held| {
            if (held.name.offset != landing) continue;
            if (held.kind.opens(.macro)) return false;
        }

        return true;
    }

    fn shadows(machine: *const Machine, offset: u32, landing: u32, mine: u32) bool {
        assert(landing < none);
        assert(mine < none);

        const inner = machine.binding_at(mine) orelse return false;
        const outer = machine.binding_at(landing) orelse return false;
        const scopes = machine.semantic.scope_slice();

        assert(scopes.len <= table_count_max);
        assert(inner.name.offset == mine);

        if (mine == landing) return false;

        if (mine > offset) {
            if (!inner.kind.hoists()) return false;
        }

        if (inner.scope == outer.scope) {
            if (mine < landing) return false;
        }

        var scope = inner.scope;

        for (0..scopes.len + 1) |_| {
            if (scope == outer.scope) return machine.visible_after(inner.node, offset);
            if (scope >= scopes.len) return false;

            const held = scopes[scope];
            if (held.parent == none) return false;

            scope = held.parent;
        }

        return false;
    }

    fn visible_after(machine: *const Machine, node: u32, offset: u32) bool {
        assert(node < machine.tree.count());

        const tokens = machine.tokens.slice();
        var current = node;

        for (0..machine.tree.count()) |_| {
            const parent = machine.tree.parent_of(current) orelse return true;
            const span = machine.tree.at(parent).span(Token, tokens);

            switch (machine.tree.kind_at(parent)) {
                .local, .expr_let => return offset >= span.end(),
                .expr_for_loop => {
                    var children = machine.tree.child_first_of(parent);

                    for (0..machine.tree.count()) |_| {
                        const child = children orelse return false;

                        if (machine.tree.kind_at(child) == .block) {
                            const body = machine.tree.at(child).span(Token, tokens);
                            return offset >= body.offset and offset < body.end();
                        }

                        children = machine.tree.sibling_next_of(child);
                    }

                    return false;
                },
                .arm, .block, .expr_closure, .file, .impl_item_fn, .item_fn => return true,
                else => current = parent,
            }
        }

        return false;
    }

    fn landing_of(machine: *const Machine, offset: u32) ?i64 {
        assert(offset < none);

        const held = machine.reference_at(offset) orelse return null;
        const bindings = machine.semantic.binding_slice();

        assert(bindings.len <= table_count_max);
        assert(held.name.offset == offset);

        switch (held.resolution) {
            .bound => |index| {
                if (index >= bindings.len) return null;

                const binding = bindings[index];
                if (binding.kind == .import) return null;
                return binding.name.offset;
            },
            .builtin, .external, .maybe => return null,
            .unresolved => return -1,
        }
    }
};

const CompareWorker = struct {
    arena: std.heap.ArenaAllocator,
    carried: []const []const u8,
    gpa: std.mem.Allocator,
    held: []const u8,
    lines: std.ArrayList(u8),
    machine: *Machine,
    recorded: Golden,

    pub const Item = Fixture;
    pub const Shared = struct { carried: []const []const u8, held: []const u8 };
    pub const Tally = struct { abstained: u32, compared: u32, differing: u32, rows: u64 };
    pub const weight = Fixture.weight;

    fn verdict_of(worker: *CompareWorker, fixture: *const Fixture, rows: *u64) !Verdict {
        assert(fixture.name.len > 0);
        assert(worker.held.len > 0);

        _ = worker.arena.reset(.retain_capacity);
        worker.lines = .empty;

        const present = try golden(worker.gpa, worker.held, fixture.name, &worker.recorded);
        if (!present) return .abstained;

        const built = !worker.recorded.broken and worker.machine.build(fixture.source);
        if (!built) return .abstained;

        const moved = try moved_rows(
            worker.arena.allocator(),
            fixture.source,
            worker.recorded.rows.items,
            worker.machine,
            rows,
            &worker.lines,
        );

        return if (moved == 0) .agreed else .moved;
    }

    pub fn deinit(worker: *CompareWorker, gpa: std.mem.Allocator) void {
        assert(worker.held.len > 0);
        assert(worker.recorded.rows.items.len <= worker.recorded.rows.capacity);

        worker.recorded.rows.deinit(gpa);
        worker.arena.deinit();
        worker.machine.destroy(gpa);
        worker.* = undefined;
    }

    pub fn init(worker: *CompareWorker, gpa: std.mem.Allocator, shared: *const Shared) !void {
        assert(shared.held.len > 0);
        assert(shared.carried.len <= file_count_max);

        worker.* = .{
            .arena = .init(gpa),
            .carried = shared.carried,
            .gpa = gpa,
            .held = shared.held,
            .lines = .empty,
            .machine = try Machine.create(gpa),
            .recorded = .{ .broken = false, .rows = .empty },
        };

        assert(worker.lines.items.len == 0);
        assert(worker.recorded.rows.items.len == 0);
    }

    pub fn visit(worker: *CompareWorker, fixture: *const Fixture, counts: *Tally) !void {
        assert(fixture.name.len > 0);
        assert(counts.differing <= counts.compared);

        if (contains(worker.carried, fixture.name)) return;

        switch (try worker.verdict_of(fixture, &counts.rows)) {
            .abstained => counts.abstained += 1,
            .agreed => {
                try tally.agree(suite, "scip", fixture.name);

                counts.compared += 1;
            },
            .moved => {
                counts.compared += 1;
                counts.differing += 1;
            },
        }
    }
};

const Fixture = corpus.File;

const Golden = struct {
    broken: bool,
    rows: std.ArrayList(Row),
};

const Quoted = struct {
    text: []const u8,
    after: usize,
};

const Row = struct {
    offset: u32,
    landed: i64,
};

const Verdict = enum {
    abstained,
    agreed,
    moved,
};

const diagnostic_count_max: u32 = 1 << 12;
const event_count_max: u32 = 1 << 23;
const file_count_max: u32 = 1 << 20;
const golden_bytes_max: u32 = 1 << 28;
const moved_shown_max: u32 = 6;
const node_count_max: u32 = 1 << 20;
const none: u32 = std.math.maxInt(u32);
const path_bytes_max: u32 = 4096;
const residue_bytes_max: u32 = 1 << 24;
const residue_path = "tests/residue-rust-resolve.json";
const shown_max: u32 = 3;
const source_bytes_max: u32 = 1 << 24;
const suite = "resolve_rust";
const table_count_max: u32 = 1 << 18;
const token_count_max: u32 = 1 << 20;

const every_namespace = [_]Namespace{
    .label,
    .lifetime,
    .macro,
    .type,
    .value,
};

const universe = [_][]const u8{
    "Err",
    "None",
    "Ok",
    "Self",
    "Some",
    "bool",
    "console",
    "error",
    "int",
    "len",
    "print",
    "string",
    "usize",
    "void",
};

fn is_space(byte: u8) bool {
    const result = switch (byte) {
        ' ', '\t', '\n', 0x0c, '\r' => true,
        else => false,
    };

    if (byte == ' ') assert(result);
    if (byte == 'a') assert(!result);

    return result;
}

fn is_word(byte: u8) bool {
    if (byte < '0') return false;

    const result = std.ascii.isAlphanumeric(byte) or byte == '_';

    if (byte == '_') assert(result);
    if (byte == ' ') assert(!result);

    return result;
}

fn shorthand(source: []const u8, offset: u32) bool {
    assert(offset < none);

    const start: usize = offset;

    assert(source.len <= std.math.maxInt(u32));

    if (start > source.len) return false;

    var before = start;

    while (before > 0) : (before -= 1) {
        assert(before <= start);

        if (!is_space(source[before - 1])) break;
    }

    if (before == 0) return false;

    const opener = source[before - 1];
    const opened = opener == '{' or opener == ',';
    if (!opened) return false;

    var after = start;

    while (after < source.len) : (after += 1) {
        assert(after >= start);

        if (!is_word(source[after])) break;
    }

    while (after < source.len) : (after += 1) {
        assert(after >= start);

        if (!is_space(source[after])) break;
    }

    if (after >= source.len) return false;

    const closer = source[after];
    return closer == '}' or closer == ',';
}

fn named(source: []const u8, offset: u32) []const u8 {
    assert(offset < none);

    const start: usize = offset;

    assert(source.len <= std.math.maxInt(u32));

    if (start >= source.len) return &.{};

    var end = start;

    while (end < source.len) : (end += 1) {
        assert(end >= start);

        if (!is_word(source[end])) break;
    }

    assert(end <= source.len);

    return source[start..end];
}

fn quoted(
    arena: std.mem.Allocator,
    text: []const u8,
    from: usize,
) error{ OutOfMemory, Unterminated }!Quoted {
    assert(text.len <= std.math.maxInt(u32));
    assert(from < none);

    var offset = from;

    while (offset < text.len) : (offset += 1) {
        assert(offset >= from);

        if (text[offset] == '"') break;
    }

    if (offset >= text.len) return error.Unterminated;

    offset += 1;

    var found: std.ArrayList(u8) = .empty;

    while (offset < text.len) {
        assert(offset > from);

        const byte = text[offset];

        offset += 1;

        if (byte == '\\') {
            offset += 1;

            continue;
        }

        if (byte == '"') return .{ .text = found.items, .after = offset };

        if (byte < 0x80) {
            try found.append(arena, byte);
        } else {
            try found.append(arena, 0xc0 | (byte >> 6));
            try found.append(arena, 0x80 | (byte & 0x3f));
        }
    }

    return error.Unterminated;
}

fn until(text: []const u8, from: usize, wanted: u8) usize {
    assert(text.len <= std.math.maxInt(u32));
    assert(from < none);

    var offset = from;

    assert(wanted != 0);

    while (offset < text.len) : (offset += 1) {
        assert(offset >= from);

        if (text[offset] == wanted) break;
    }

    return offset;
}

fn golden_row(
    gpa: std.mem.Allocator,
    text: []const u8,
    from: usize,
    rows: *std.ArrayList(Row),
) !usize {
    assert(text[from] == '[');

    var offset = from + 1;
    var use_offset: u32 = 0;

    while (offset < text.len) : (offset += 1) {
        assert(offset > from);

        if (!std.ascii.isDigit(text[offset])) break;

        use_offset = use_offset * 10 + (text[offset] - '0');
    }

    offset = until(text, offset, ',') + 1;

    const negative = offset < text.len and text[offset] == '-';

    if (negative) offset += 1;

    var landed: i64 = 0;

    while (offset < text.len) : (offset += 1) {
        assert(offset > from);

        if (!std.ascii.isDigit(text[offset])) break;

        landed = landed * 10 + (text[offset] - '0');
    }

    try rows.append(gpa, .{ .offset = use_offset, .landed = if (negative) -landed else landed });

    offset = until(text, offset, ']') + 1;

    if (offset < text.len) {
        if (text[offset] == ',') offset += 1;
    }

    return offset;
}

fn golden(gpa: std.mem.Allocator, root: []const u8, name: []const u8, held: *Golden) !bool {
    assert(root.len > 0);
    assert(name.len > 0);

    const io = std.testing.io;
    var path_buffer: [path_bytes_max]u8 = undefined;
    const path = try std.mem.print(&path_buffer, "{s}/{s}.json", .{ root, name });
    const limit: std.Io.Limit = .limited(golden_bytes_max);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, limit) catch return false;
    defer gpa.free(text);

    held.broken = std.mem.find(u8, text, "\"broken\":true") != null;

    held.rows.clearRetainingCapacity();

    const key = "\"rows\":[";
    const start = std.mem.find(u8, text, key) orelse return true;
    var offset = start + key.len;

    for (0..text.len) |_| {
        const opened = offset < text.len and text[offset] == '[';
        if (!opened) break;

        offset = try golden_row(gpa, text, offset, &held.rows);
    }

    return true;
}

fn residue(arena: std.mem.Allocator) !std.ArrayList([]const u8) {
    const io = std.testing.io;
    const key = "\"fixture\":";
    var found: std.ArrayList([]const u8) = .empty;

    comptime assert(key.len == 10);

    const limit: std.Io.Limit = .limited(residue_bytes_max);

    const text = std.Io.Dir.cwd().readFileAlloc(io, residue_path, arena, limit) catch {
        return found;
    };

    var offset: usize = 0;

    for (0..text.len) |_| {
        const start = std.mem.findPos(u8, text, offset, key) orelse break;

        const held = quoted(arena, text, start + key.len) catch |err| switch (err) {
            error.Unterminated => break,
            error.OutOfMemory => return err,
        };

        try found.append(arena, held.text);
        offset = held.after;
    }

    assert(offset <= text.len);
    assert(found.items.len <= text.len);

    return found;
}

fn corpus_selected(basename: []const u8) bool {
    assert(basename.len > 0);

    return std.mem.eql(u8, std.Io.Dir.path.extension(basename), ".rs");
}

fn contains(names: []const []const u8, name: []const u8) bool {
    assert(names.len <= file_count_max);
    assert(name.len > 0);

    for (names) |held| {
        if (std.mem.eql(u8, held, name)) return true;
    }

    return false;
}

fn moved_rows(
    arena: std.mem.Allocator,
    source: []const u8,
    recorded: []const Row,
    machine: *const Machine,
    rows: *u64,
    lines: *std.ArrayList(u8),
) !u32 {
    assert(recorded.len <= std.math.maxInt(u32));

    var moved: u32 = 0;

    assert(source.len <= std.math.maxInt(u32));
    assert(lines.items.len == 0);

    for (recorded) |row| {
        const landing = std.math.cast(u32, row.landed) orelse continue;
        if (!std.mem.eql(u8, named(source, row.offset), named(source, landing))) continue;
        if (shorthand(source, row.offset)) continue;
        if (!machine.declares(landing)) continue;
        if (machine.invokes(row.offset, landing)) continue;
        if (machine.conditional(source, row.offset)) continue;
        if (!machine.reachable(row.offset, landing)) continue;

        const mine = machine.landing_of(row.offset) orelse continue;

        if (mine >= 0) {
            if (machine.shadows(row.offset, landing, @intCast(mine))) continue;
        }

        rows.* += 1;

        if (mine == row.landed) continue;

        if (moved < moved_shown_max) {
            const line = try arena.print(
                "  {d} scip {d} scylla {d}\n",
                .{ row.offset, row.landed, mine },
            );

            try lines.appendSlice(arena, line);
        }

        moved += 1;
    }

    return moved;
}

fn differing_blocks(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    shared: *const CompareWorker.Shared,
    files: []const Fixture,
) !std.ArrayList([]const u8) {
    var blocks: std.ArrayList([]const u8) = .empty;
    var rows: u64 = 0;
    var worker: CompareWorker = undefined;

    assert(shared.held.len > 0);
    assert(files.len <= file_count_max);

    try worker.init(gpa, shared);
    defer worker.deinit(gpa);

    for (files) |*fixture| {
        if (contains(shared.carried, fixture.name)) continue;
        if (try worker.verdict_of(fixture, &rows) != .moved) continue;

        const block = try arena.print("=== {s}\n{s}", .{ fixture.name, worker.lines.items });

        try blocks.append(arena, block);
    }

    assert(blocks.items.len <= files.len);

    return blocks;
}

fn require(condition: bool, comptime format: []const u8, arguments: anytype) !void {
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    if (condition) return;

    std.debug.print(format ++ "\n", arguments);

    return error.TestUnexpectedResult;
}

fn differing_report(arena: std.mem.Allocator, differing: []const []const u8) !void {
    assert(differing.len <= file_count_max);

    if (differing.len == 0) return;

    const joined = try std.mem.concat(arena, u8, differing);
    var path_bytes: [environment.value_bytes_max]u8 = undefined;

    if (environment.get("SCYLLA_REPORT", &path_bytes)) |path| {
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = joined });
    }

    const shown_end = @min(differing.len, shown_max);
    const shown = try std.mem.concat(arena, u8, differing[0..shown_end]);

    assert(shown.len <= joined.len);

    std.debug.print("{d} files resolve differently\n{s}", .{ differing.len, shown });

    return error.TestUnexpectedResult;
}

test "the corpus resolves what rust analyzer resolves" {
    const gpa = std.testing.allocator;
    const held = corpus.named(.scip) orelse return;
    const root = corpus.named(.root) orelse return;
    var files = try corpus.collect(gpa, root, source_bytes_max, corpus_selected);
    defer files.deinit(gpa);

    if (files.slice().len == 0) return;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const carried = try residue(arena);
    const shared: CompareWorker.Shared = .{ .carried = carried.items, .held = held };
    var counts = std.mem.zeroes(CompareWorker.Tally);

    try stripe.run(CompareWorker, gpa, &shared, files.slice(), &counts);

    const files_named: u64 = counts.compared + carried.items.len;

    assert(counts.compared <= files.slice().len);
    assert(counts.differing <= counts.compared);

    try require(
        files_named >= floor.corpus_resolve_rust.files,
        "the corpus lost its Rust files: {d} named, {d} abstained, floor {d}",
        .{ files_named, counts.abstained, floor.corpus_resolve_rust.files },
    );

    try require(
        counts.rows >= floor.corpus_resolve_rust.rows,
        "{d} names compared, floor {d}",
        .{ counts.rows, floor.corpus_resolve_rust.rows },
    );

    if (counts.differing == 0) return;

    const differing = try differing_blocks(arena, gpa, &shared, files.slice());

    assert(differing.items.len == counts.differing);

    try differing_report(arena, differing.items);
}
