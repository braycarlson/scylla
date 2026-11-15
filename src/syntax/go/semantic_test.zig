const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const EventsType = @import("../tree.zig").EventsType;
const Kind = @import("kind.zig").Kind;
const Parser = @import("parse.zig").Parser;
const Reference = @import("semantic.zig").Semantic.Reference;
const Semantic = @import("semantic.zig").Semantic;
const Structure = @import("../tree.zig").Structure;
const Token = @import("../token.zig");
const Tokens = @import("../tokens.zig");
const TreeType = @import("../tree.zig").TreeType;
const corpus = @import("../../testing/corpus.zig");
const environment = @import("../../testing/environment.zig");
const floor = @import("../../testing/floor.zig");
const lex = @import("lex.zig").lex;
const raw_of = @import("../raw.zig").raw_of;
const oracle = @import("../../testing/oracle.zig");
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
            .binding_count_max = binding_count_max,
            .fact_count_max = fact_count_max,
            .reference_count_max = reference_count_max,
            .scope_count_max = scope_count_max,
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

    fn run(machine: *Machine, source: []const u8) Structure {
        assert(source.len <= std.math.maxInt(u32));

        machine.tokens.clear();

        lex(source, &machine.tokens) catch |err| switch (err) {
            error.Truncated => return .{ .truncated = .tokens },
        };

        raw_of(Kind, machine.tokens.slice(), &machine.raw) catch |err| switch (err) {
            error.Truncated => std.debug.panic("the lexer overran its tokens", .{}),
        };

        assert(machine.raw.count() == machine.tokens.count());

        const parsed = machine.parser.build(
            source,
            machine.tokens.slice(),
            machine.raw.const_slice(),
            &machine.events,
            &machine.tree,
        );

        const held = machine.semantic.build(
            source,
            machine.tokens.slice(),
            machine.raw.const_slice(),
            &machine.tree,
            &universe,
        );

        if (parsed != .complete) return parsed;
        return held;
    }

    fn self_initialized(machine: *const Machine, row: Pair) bool {
        assert(row.definition >= -1);

        const definition = std.math.cast(u32, row.definition) orelse return false;
        const bindings = machine.semantic.binding_slice();

        assert(bindings.len <= binding_count_max);

        if (row.offset <= definition) return false;

        for (bindings) |held| {
            if (held.name.offset != definition) continue;

            var current = held.node;

            for (0..spec_depth_max) |_| {
                const parent = machine.tree.parent_of(current) orelse return false;

                if (machine.tree.kind_at(parent) == .value_spec) {
                    const span = machine.tree.at(parent).span(Token, machine.tokens.slice());
                    return row.offset < span.end();
                }

                current = parent;
            }

            return false;
        }

        return false;
    }

    fn rows(machine: *const Machine, gpa: std.mem.Allocator, found: *std.ArrayList(Pair)) !void {
        const bindings = machine.semantic.binding_slice();
        const references = machine.semantic.reference_slice();

        assert(bindings.len <= binding_count_max);
        assert(references.len <= reference_count_max);

        found.clearRetainingCapacity();

        for (bindings) |held| {
            try found.append(gpa, .{ .offset = held.name.offset, .definition = held.name.offset });
        }

        for (references) |held| {
            const definition: i64 = switch (held.resolution) {
                .bound => |index| bindings[index].name.offset,
                .builtin, .external, .maybe => -1,
                .unresolved => continue,
            };

            try found.append(gpa, .{ .offset = held.name.offset, .definition = definition });
        }

        std.mem.sort(Pair, found.items, {}, Pair.less_than);
        dedup(found);
    }
};

const CorpusWorker = struct {
    expected: Golden,
    gpa: std.mem.Allocator,
    held: std.ArrayList(Pair),
    kept: std.ArrayList(Pair),
    machine: *Machine,
    shared: *const Shared,

    pub const Item = Fixture;
    pub const Shared = struct { residue: *const oracle.Residue, root: []const u8 };
    pub const Tally = struct { compared: u32, differing: u32 };
    pub const weight = Fixture.weight;

    fn verdict(worker: *CorpusWorker, fixture: *const Fixture) !Verdict {
        const gpa = worker.gpa;
        const shared = worker.shared;

        assert(fixture.name.len > 0);
        assert(shared.root.len > 0);

        if (shared.residue.contains(fixture.name)) return .skipped;
        if (!try golden(gpa, shared.root, fixture.name, &worker.expected)) return .skipped;
        if (worker.expected.broken) return .skipped;
        if (worker.machine.run(fixture.source) != .complete) return .skipped;

        try worker.machine.rows(gpa, &worker.held);

        var kept: usize = 0;

        for (worker.expected.rows.items) |row| {
            if (worker.machine.self_initialized(row)) continue;

            worker.expected.rows.items[kept] = row;
            kept += 1;
        }

        worker.expected.rows.shrinkRetainingCapacity(kept);

        try placed(gpa, worker.held.items, worker.expected.rows.items, &worker.kept);

        if (pairs_equal(worker.kept.items, worker.expected.rows.items)) return .agrees;
        return .differs;
    }

    pub fn init(worker: *CorpusWorker, gpa: std.mem.Allocator, shared: *const Shared) !void {
        assert(shared.root.len > 0);
        assert(shared.residue.fixtures.items.len <= file_count_max);

        worker.machine = try Machine.create(gpa);
        worker.expected = .{ .broken = false, .rows = .empty };
        worker.gpa = gpa;
        worker.held = .empty;
        worker.kept = .empty;
        worker.shared = shared;

        assert(worker.machine.semantic.count() == 0);
    }

    pub fn deinit(worker: *CorpusWorker, gpa: std.mem.Allocator) void {
        assert(worker.held.items.len <= worker.held.capacity);
        assert(worker.kept.items.len <= worker.kept.capacity);

        worker.kept.deinit(gpa);
        worker.held.deinit(gpa);
        worker.expected.rows.deinit(gpa);
        worker.machine.destroy(gpa);
        worker.* = undefined;
    }

    pub fn visit(worker: *CorpusWorker, fixture: *const Fixture, counted: *Tally) !void {
        assert(fixture.name.len > 0);
        assert(counted.differing <= counted.compared);

        const held = try worker.verdict(fixture);
        if (held == .skipped) return;

        if (held == .agrees) {
            try tally.agree(suite, "gotypes", fixture.name);
        } else {
            counted.differing += 1;
        }

        counted.compared += 1;
    }
};

const Fixture = corpus.File;

const Golden = struct {
    broken: bool,
    rows: std.ArrayList(Pair),
};

const Number = struct {
    value: u32,
    after: usize,
};

const Pair = struct {
    offset: u32,
    definition: i64,

    fn less_than(context: void, left: Pair, right: Pair) bool {
        _ = context;

        assert(left.definition >= -1);
        assert(right.definition >= -1);

        if (left.offset != right.offset) return left.offset < right.offset;
        return left.definition < right.definition;
    }
};

const Signed = struct {
    value: i64,
    after: usize,
};

const Verdict = enum { agrees, differs, skipped };
const binding_count_max: u32 = 1 << 16;
const diagnostic_count_max: u32 = 1 << 12;
const event_count_max: u32 = 1 << 21;
const every_category = [_][]const u8{ "gotypes", "not-go", "scylla" };
const fact_count_max: u32 = 1 << 13;
const file_count_max: u32 = 1 << 20;
const fixture_root = "tests/fixtures/go-semantic";
const golden_bytes_max: u32 = 1 << 28;
const golden_root = "tests/fixtures/golden-gotypes";
const node_count_max: u32 = 1 << 19;
const none: u32 = std.math.maxInt(u32);
const path_bytes_max: u32 = 4096;
const reference_count_max: u32 = 1 << 18;
const report_lines_max: u32 = 24;
const report_shown_max: u32 = 3;
const residue_name = "residue-go-semantic.json";
const scope_count_max: u32 = 1 << 16;
const scope_steps_max: u32 = 1 << 8;
const source_bytes_max: u32 = 1 << 24;
const spec_depth_max: u32 = 8;
const suite = "semantic_go";
const token_count_max: u32 = 1 << 19;

const universe = [_][]const u8{
    "any",
    "append",
    "bool",
    "byte",
    "cap",
    "clear",
    "close",
    "comparable",
    "complex",
    "complex128",
    "complex64",
    "copy",
    "delete",
    "error",
    "false",
    "float32",
    "float64",
    "imag",
    "int",
    "int16",
    "int32",
    "int64",
    "int8",
    "iota",
    "len",
    "make",
    "max",
    "min",
    "new",
    "nil",
    "panic",
    "print",
    "println",
    "real",
    "recover",
    "rune",
    "string",
    "true",
    "uint",
    "uint16",
    "uint32",
    "uint64",
    "uint8",
    "uintptr",
};

fn dedup(found: *std.ArrayList(Pair)) void {
    var kept: usize = 0;

    assert(found.items.len <= found.capacity);

    for (found.items) |pair| {
        const repeated = kept > 0 and pair_equal(found.items[kept - 1], pair);
        if (repeated) continue;

        found.items[kept] = pair;
        kept += 1;
    }

    assert(kept <= found.items.len);

    found.shrinkRetainingCapacity(kept);
}

fn pair_equal(left: Pair, right: Pair) bool {
    assert(left.definition >= -1);
    assert(right.definition >= -1);

    return left.offset == right.offset and left.definition == right.definition;
}

fn pairs_equal(left: []const Pair, right: []const Pair) bool {
    assert(left.len <= std.math.maxInt(u32));
    assert(right.len <= std.math.maxInt(u32));

    if (left.len != right.len) return false;

    for (left, right) |mine, theirs| {
        if (!pair_equal(mine, theirs)) return false;
    }

    return true;
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

    return std.mem.eql(u8, std.Io.Dir.path.extension(basename), ".go");
}

fn fixtures(gpa: std.mem.Allocator) !corpus.Files {
    const found = try corpus.collect(gpa, fixture_root, source_bytes_max, corpus_selected);
    const slice = found.slice();

    assert(slice.len <= file_count_max);
    if (slice.len > 1) assert(Fixture.less_than({}, slice[0], slice[1]));

    return found;
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

    const key = "\"ast\":[";
    const start = std.mem.find(u8, text, key) orelse return true;
    var offset = start + key.len;

    for (0..text.len) |_| {
        const opened = offset < text.len and text[offset] == '[';
        if (!opened) break;

        const position = number(text, offset);
        const tail = quoted(text, position.after) orelse break;
        const next = quoted(text, tail) orelse break;
        const definition = signed(text, next);

        try held.rows.append(gpa, .{ .offset = position.value, .definition = definition.value });

        offset = definition.after;

        const closed = offset < text.len and text[offset] == ']';

        if (closed) offset += 1;

        const separated = offset < text.len and text[offset] == ',';
        if (!separated) break;

        offset += 1;
    }

    std.mem.sort(Pair, held.rows.items, {}, Pair.less_than);
    dedup(&held.rows);

    return true;
}

fn number(text: []const u8, from: usize) Number {
    assert(text.len <= std.math.maxInt(u32));
    assert(from < none);

    var offset = from;

    while (offset < text.len) : (offset += 1) {
        assert(offset >= from);

        if (std.ascii.isDigit(text[offset])) break;
    }

    var value: u32 = 0;

    while (offset < text.len) : (offset += 1) {
        assert(offset >= from);

        if (!std.ascii.isDigit(text[offset])) break;

        value = value * 10 + (text[offset] - '0');
    }

    return .{ .value = value, .after = offset };
}

fn signed(text: []const u8, from: usize) Signed {
    assert(text.len <= std.math.maxInt(u32));
    assert(from < none);

    var offset = from;

    while (offset < text.len) : (offset += 1) {
        assert(offset >= from);

        const digit = std.ascii.isDigit(text[offset]);
        if (digit) break;
        if (text[offset] == '-') break;
    }

    const negative = offset < text.len and text[offset] == '-';

    if (negative) offset += 1;

    var value: i64 = 0;

    while (offset < text.len) : (offset += 1) {
        assert(offset > from or !negative);

        if (!std.ascii.isDigit(text[offset])) break;

        value = value * 10 + (text[offset] - '0');
    }

    if (negative) return .{ .value = -value, .after = offset };
    return .{ .value = value, .after = offset };
}

fn quoted(text: []const u8, from: usize) ?usize {
    assert(text.len <= std.math.maxInt(u32));
    assert(from < none);

    var offset = from;

    while (offset < text.len) : (offset += 1) {
        assert(offset >= from);

        if (text[offset] == '"') break;
    }

    if (offset >= text.len) return null;

    offset += 1;

    for (0..text.len) |_| {
        if (offset >= text.len) break;

        const byte = text[offset];

        offset += 1;

        if (byte == '\\') {
            offset += 1;

            continue;
        }

        if (byte == '"') return offset;
    }

    return null;
}

fn placed(
    gpa: std.mem.Allocator,
    held: []const Pair,
    expected: []const Pair,
    found: *std.ArrayList(Pair),
) !void {
    var theirs: usize = 0;

    assert(held.len <= std.math.maxInt(u32));
    assert(expected.len <= std.math.maxInt(u32));

    found.clearRetainingCapacity();

    for (held) |row| {
        while (theirs < expected.len) : (theirs += 1) {
            assert(theirs < expected.len);

            if (expected[theirs].offset >= row.offset) break;
        }

        const matched = theirs < expected.len and expected[theirs].offset == row.offset;

        if (matched) try found.append(gpa, row);
    }
}

fn fixture_diverges(
    gpa: std.mem.Allocator,
    machine: *Machine,
    root: []const u8,
    fixture: *const Fixture,
) !bool {
    var expected: Golden = .{ .broken = false, .rows = .empty };
    defer expected.rows.deinit(gpa);

    assert(root.len > 0);
    assert(fixture.name.len > 0);

    if (!try golden(gpa, root, fixture.name, &expected)) return true;

    _ = machine.run(fixture.source);

    var held: std.ArrayList(Pair) = .empty;
    defer held.deinit(gpa);

    try machine.rows(gpa, &held);

    return !pairs_equal(held.items, expected.rows.items);
}

fn corpus_report(
    gpa: std.mem.Allocator,
    shared: *const CorpusWorker.Shared,
    files: []const Fixture,
    counted: CorpusWorker.Tally,
) !void {
    assert(counted.differing <= counted.compared);
    assert(files.len <= file_count_max);

    if (counted.differing == 0) return;

    var worker: CorpusWorker = undefined;

    try worker.init(gpa, shared);
    defer worker.deinit(gpa);

    var differing: std.ArrayList(u8) = .empty;
    defer differing.deinit(gpa);

    var differing_count: u32 = 0;
    var shown_end: usize = 0;

    for (files) |*fixture| {
        if (try worker.verdict(fixture) != .differs) continue;

        try report(gpa, &differing, fixture.name, worker.kept.items, worker.expected.rows.items);
        differing_count += 1;

        if (differing_count <= report_shown_max) shown_end = differing.items.len;
    }

    assert(differing_count == counted.differing);

    try differing_report(differing.items, differing_count, shown_end, counted.compared);
}

fn corpus_diverges(
    gpa: std.mem.Allocator,
    machine: *Machine,
    root: []const u8,
    fixture: *const Fixture,
) !bool {
    var expected: Golden = .{ .broken = false, .rows = .empty };
    defer expected.rows.deinit(gpa);

    assert(root.len > 0);
    assert(fixture.name.len > 0);

    if (!try golden(gpa, root, fixture.name, &expected)) return true;
    if (expected.broken) return true;
    if (machine.run(fixture.source) != .complete) return true;

    var held: std.ArrayList(Pair) = .empty;
    defer held.deinit(gpa);

    var kept: std.ArrayList(Pair) = .empty;
    defer kept.deinit(gpa);

    try machine.rows(gpa, &held);
    try placed(gpa, held.items, expected.rows.items, &kept);

    return !pairs_equal(kept.items, expected.rows.items);
}

fn report(
    gpa: std.mem.Allocator,
    lines: *std.ArrayList(u8),
    name: []const u8,
    held: []const Pair,
    expected: []const Pair,
) !void {
    assert(held.len <= std.math.maxInt(u32));
    assert(expected.len <= std.math.maxInt(u32));

    var shown: u32 = 0;
    var mine: usize = 0;
    var theirs: usize = 0;

    assert(name.len > 0);

    try lines.print(gpa, "{s}: the pairs differ\n", .{name});

    for (0..held.len + expected.len) |_| {
        const drained = mine >= held.len and theirs >= expected.len;
        if (drained) break;
        if (shown >= report_lines_max) break;

        const extra = theirs >= expected.len or
            (mine < held.len and Pair.less_than({}, held[mine], expected[theirs]));

        if (extra) {
            const row = held[mine];

            try lines.print(gpa, "  extra   {d} -> {d}\n", .{ row.offset, row.definition });

            mine += 1;
            shown += 1;

            continue;
        }

        const missing = mine >= held.len or Pair.less_than({}, expected[theirs], held[mine]);

        if (missing) {
            const row = expected[theirs];

            try lines.print(gpa, "  missing {d} -> {d}\n", .{ row.offset, row.definition });

            theirs += 1;
            shown += 1;

            continue;
        }

        mine += 1;
        theirs += 1;
    }

    assert(shown <= report_lines_max);
}

fn differing_report(
    differing: []const u8,
    differing_count: u32,
    shown_end: usize,
    compared: u32,
) !void {
    assert(shown_end <= differing.len);
    assert(differing_count <= compared);

    if (differing_count == 0) return;

    var path_bytes: [environment.value_bytes_max]u8 = undefined;

    if (environment.get("SCYLLA_REPORT", &path_bytes)) |path| {
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{
            .sub_path = path,
            .data = differing,
        });
    }

    std.debug.print("{d} of {d} corpus files differ\n{s}", .{
        differing_count,
        compared,
        differing[0..shown_end],
    });

    return error.TestUnexpectedResult;
}

fn require(condition: bool, comptime format: []const u8, arguments: anytype) !void {
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    if (condition) return;

    std.debug.print(format ++ "\n", arguments);

    return error.TestUnexpectedResult;
}

test "a name neither side can place is absent from the rows both are compared through" {
    const gpa = std.testing.allocator;
    const source = "package p\n\nfunc run() {\n\t_ = sibling\n}\n";

    comptime assert(source.len > 0);

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    assert(machine.semantic.count() == 0);

    try std.testing.expectEqual(Structure.complete, machine.run(source));

    var unresolved: ?Reference = null;

    for (machine.semantic.reference_slice()) |held| {
        if (held.resolution == .unresolved) {
            unresolved = held;

            break;
        }
    }

    try require(unresolved != null, "a name no file in the set declares is unresolved", .{});

    var rows: std.ArrayList(Pair) = .empty;
    defer rows.deinit(gpa);

    try machine.rows(gpa, &rows);

    for (rows.items) |row| {
        try std.testing.expect(row.offset != unresolved.?.name.offset);
    }
}

test "the model is total over the fixtures" {
    const gpa = std.testing.allocator;
    var found = try fixtures(gpa);
    defer found.deinit(gpa);

    try require(found.slice().len > 0, "tests/fixtures/go-semantic holds no source", .{});

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    assert(found.slice().len <= file_count_max);
    assert(machine.semantic.count() == 0);

    for (found.slice()) |fixture| {
        const outcome = machine.run(fixture.source);

        try require(outcome == .complete, "{s}", .{fixture.name});
        try require(machine.semantic.count() > 0, "{s}", .{fixture.name});
    }
}

test "a range over a written out composite literal binds inside the loop body" {
    const gpa = std.testing.allocator;

    const source = "package p\n\nfunc f() {\n\tfor _, po := range []*poset{a, b} {\n" ++
        "\t\tuse(po)\n\t}\n}\n";

    comptime assert(source.len > 0);

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    assert(machine.semantic.count() == 0);

    _ = machine.run(source);

    var bound: u32 = 0;

    for (machine.semantic.reference_slice()) |held| {
        if (held.resolution != .bound) continue;
        if (!std.mem.eql(u8, held.name.text(source), "po")) continue;

        bound += 1;
    }

    try require(bound == 2, "the loop variable is unresolved inside the body", .{});
}

test "every scope a reference resolves into is on its own chain" {
    const gpa = std.testing.allocator;
    var found = try fixtures(gpa);
    defer found.deinit(gpa);

    try require(found.slice().len > 0, "tests/fixtures/go-semantic holds no source", .{});

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    assert(found.slice().len <= file_count_max);
    assert(machine.semantic.count() == 0);

    for (found.slice()) |fixture| {
        _ = machine.run(fixture.source);

        const bindings = machine.semantic.binding_slice();
        const scopes = machine.semantic.scope_slice();

        for (machine.semantic.reference_slice()) |held| {
            const index = switch (held.resolution) {
                .bound => |bound| bound,
                .builtin, .external, .maybe, .unresolved => continue,
            };

            const binding = bindings[index];
            var scope = held.scope;
            var walked = false;

            for (0..scope_steps_max + 1) |_| {
                if (scope == none) break;

                if (scope == binding.scope) {
                    walked = true;

                    break;
                }

                scope = scopes[scope].parent;
            }

            try require(
                walked,
                "{s}: a reference resolves outside its own scope chain",
                .{fixture.name},
            );
        }
    }
}

test "every fixture names what go types names" {
    const gpa = std.testing.allocator;
    var carried = try oracle.residue_of(gpa, residue_name, &every_category);
    defer carried.deinit(gpa);

    var found = try fixtures(gpa);
    defer found.deinit(gpa);

    try require(found.slice().len > 0, "tests/fixtures/go-semantic holds no source", .{});

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    assert(found.slice().len <= file_count_max);
    assert(machine.semantic.count() == 0);

    var expected: Golden = .{ .broken = false, .rows = .empty };
    defer expected.rows.deinit(gpa);

    var held: std.ArrayList(Pair) = .empty;
    defer held.deinit(gpa);

    var lines: std.ArrayList(u8) = .empty;
    defer lines.deinit(gpa);

    var compared: u32 = 0;

    for (found.slice()) |fixture| {
        if (carried.contains(fixture.name)) continue;

        const present = try golden(gpa, golden_root, fixture.name, &expected);

        try require(present, "{s} has no golden", .{fixture.name});
        try require(!expected.broken, "{s} does not parse", .{fixture.name});

        _ = machine.run(fixture.source);

        try machine.rows(gpa, &held);

        if (!pairs_equal(held.items, expected.rows.items)) {
            lines.clearRetainingCapacity();
            try report(gpa, &lines, fixture.name, held.items, expected.rows.items);
            try require(false, "{s}", .{lines.items});
        }

        compared += 1;
    }

    try require(
        compared >= floor.fixture_semantic_go,
        "the Go fixtures lost a binding table: {d} compared, floor {d}",
        .{ compared, floor.fixture_semantic_go },
    );
}

test "the corpus names what go types names" {
    const gpa = std.testing.allocator;
    const root = corpus.named(.gotypes) orelse return;
    var found = try corpus_fixtures(gpa);
    defer found.deinit(gpa);

    if (found.slice().len == 0) return;

    assert(root.len > 0);
    assert(found.slice().len <= file_count_max);

    var carried = try oracle.residue_of(gpa, residue_name, &every_category);
    defer carried.deinit(gpa);

    const shared: CorpusWorker.Shared = .{ .residue = &carried, .root = root };
    var counted: CorpusWorker.Tally = .{ .compared = 0, .differing = 0 };

    try stripe.run(CorpusWorker, gpa, &shared, found.slice(), &counted);

    try require(
        counted.compared >= floor.corpus_semantic_go,
        "the corpus lost its Go files: {d} compared, floor {d}",
        .{ counted.compared, floor.corpus_semantic_go },
    );

    try corpus_report(gpa, &shared, found.slice(), counted);
}

test "every residue row names a file that diverges" {
    const gpa = std.testing.allocator;
    var carried = try oracle.residue_of(gpa, residue_name, &every_category);
    defer carried.deinit(gpa);

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    var named: std.ArrayList([]const u8) = .empty;
    defer named.deinit(gpa);

    var found = try fixtures(gpa);
    defer found.deinit(gpa);

    for (found.slice()) |*fixture| {
        if (!carried.contains(fixture.name)) continue;

        try named.append(gpa, fixture.name);

        const diverges = try fixture_diverges(gpa, machine, golden_root, fixture);

        try require(diverges, "{s} matches its golden and needs no residue row", .{fixture.name});
    }

    const root = corpus.named(.gotypes) orelse return;
    var corpus_found = try corpus_fixtures(gpa);
    defer corpus_found.deinit(gpa);

    for (corpus_found.slice()) |*fixture| {
        if (!carried.contains(fixture.name)) continue;

        try named.append(gpa, fixture.name);

        const diverges = try corpus_diverges(gpa, machine, root, fixture);

        try require(
            diverges,
            "{s} matches its corpus golden and needs no residue row",
            .{fixture.name},
        );
    }

    assert(root.len > 0);
    assert(named.items.len <= carried.fixtures.items.len);

    for (carried.fixtures.items) |name| {
        var present = false;

        for (named.items) |held| {
            if (std.mem.eql(u8, held, name)) present = true;
        }

        try require(
            present,
            "the residue names `{s}` and neither the fixtures nor the corpus carry it",
            .{name},
        );
    }
}
