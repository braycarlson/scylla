const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const Binding = @import("semantic.zig").Semantic.Binding;
const EventsType = @import("../tree.zig").EventsType;
const Kind = @import("kind.zig").Kind;
const Parser = @import("parse.zig").Parser;
const Reference = @import("semantic.zig").Semantic.Reference;
const Semantic = @import("semantic.zig").Semantic;
const Tokens = @import("../tokens.zig");
const TreeType = @import("../tree.zig").TreeType;
const corpus = @import("../../testing/corpus.zig");
const environment = @import("../../testing/environment.zig");
const floor = @import("../../testing/floor.zig");
const raw_of = @import("../raw.zig").raw_of;
const lex = @import("lex.zig").lex;
const oracle = @import("../../testing/oracle.zig");
const stripe = @import("../../testing/stripe.zig");
const tally = @import("../../testing/tally.zig");
const Events = EventsType(Kind);
const Tree = TreeType(Kind);
const diagnostic_count_max: u32 = 1 << 12;
const event_count_max: u32 = 1 << 21;
const file_count_max: u32 = 1 << 20;
const golden_bytes_max: u32 = 1 << 28;
const moved_shown_max: usize = 6;
const node_count_max: u32 = 1 << 18;
const none: u32 = std.math.maxInt(u32);
const path_bytes_max: u32 = 4096;
const report_shown_max: usize = 3;
const residue_bytes_max: u32 = 1 << 24;
const residue_path = "tests/residue-zig-resolve.json";
const source_bytes_max: u32 = 1 << 24;
const suite = "resolve_zig";
const table_count_max: u32 = 1 << 16;
const token_count_max: u32 = 1 << 18;

const universe = [_][]const u8{
    "None",
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

const CompareWorker = struct {
    arena: std.heap.ArenaAllocator,
    carried: []const []const u8,
    held: []const u8,
    machine: *Machine,
    parsed: ?[]const u8,

    pub const Item = Fixture;

    pub const Shared = struct {
        carried: []const []const u8,
        held: []const u8,
        parsed: ?[]const u8,
    };

    pub const Tally = struct { abstained: u32, compared: usize, differing: usize, rows: usize };
    pub const weight = Fixture.weight;

    fn verdict_of(worker: *CompareWorker, fixture: *const Fixture, rows: *usize) !Verdict {
        assert(fixture.name.len > 0);
        assert(worker.held.len > 0);

        _ = worker.arena.reset(.retain_capacity);

        return try fixture_compare(
            worker.arena.allocator(),
            worker.machine,
            rows,
            worker.held,
            worker.parsed,
            fixture,
        );
    }

    pub fn deinit(worker: *CompareWorker, gpa: std.mem.Allocator) void {
        assert(worker.held.len > 0);
        assert(worker.carried.len <= file_count_max);

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
            .held = shared.held,
            .machine = try Machine.create(gpa),
            .parsed = shared.parsed,
        };

        assert(worker.held.len == shared.held.len);
        assert(worker.carried.len == shared.carried.len);
    }

    pub fn visit(worker: *CompareWorker, fixture: *const Fixture, counts: *Tally) !void {
        assert(fixture.name.len > 0);
        assert(counts.differing <= counts.compared);

        if (names_contain(worker.carried, fixture.name)) return;

        switch (try worker.verdict_of(fixture, &counts.rows)) {
            .abstained => counts.abstained += 1,
            .agreed => {
                try tally.agree(suite, "zls", fixture.name);

                counts.compared += 1;
            },
            .differing => {
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
    after: usize,
    text: []const u8,
};

const Row = struct {
    landed: i64,
    offset: u32,
};

const Verdict = union(enum) {
    abstained,
    agreed,
    differing: []const u8,
};

const Machine = struct {
    events: Events,
    parser: Parser,
    raw: ArrayType(Kind),
    semantic: Semantic,
    tokens: Tokens,
    tree: Tree,

    fn binding_at(machine: *const Machine, landing_offset: u32) ?Binding {
        const bindings = machine.semantic.binding_slice();

        assert(bindings.len <= table_count_max);
        assert(machine.tokens.items.capacity() == token_count_max);

        for (bindings) |held| {
            if (held.name.offset == landing_offset) return held;
        }

        return null;
    }

    fn build(machine: *Machine, source: []const u8) bool {
        assert(source.len <= std.math.maxInt(u32));

        if (!machine.parse(source)) return false;
        if (machine.tree.diagnostic_slice().len > 0) return false;

        const held = machine.semantic.build(
            source,
            machine.tokens.slice(),
            machine.raw.const_slice(),
            &machine.tree,
            &universe,
        );

        assert(machine.raw.count() == machine.tokens.count());

        return held == .complete;
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
        var same_count: u32 = 0;

        for (bindings) |held| {
            if (held.scope != binding.scope) continue;
            if (!std.mem.eql(u8, held.name.text(source), name)) continue;

            same_count += 1;
        }

        return same_count > 1;
    }

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

    fn landing(machine: *const Machine, offset: u32) ?i64 {
        assert(offset < none);

        const held = machine.reference_at(offset) orelse return null;
        const bindings = machine.semantic.binding_slice();

        assert(held.name.offset == offset);
        assert(bindings.len <= table_count_max);

        switch (held.resolution) {
            .bound => |index| {
                if (index >= bindings.len) return null;
                return bindings[index].name.offset;
            },
            .builtin, .external, .maybe, .unresolved => return -1,
        }
    }

    fn parse(machine: *Machine, source: []const u8) bool {
        assert(source.len <= std.math.maxInt(u32));

        machine.tokens.clear();

        lex(source, &machine.tokens) catch return false;
        raw_of(Kind, machine.tokens.slice(), &machine.raw) catch return false;

        assert(machine.raw.count() == machine.tokens.count());

        _ = machine.parser.build(
            source,
            machine.tokens.slice(),
            machine.raw.const_slice(),
            &machine.events,
            &machine.tree,
        );

        return true;
    }

    fn reachable(machine: *const Machine, offset: u32, landing_offset: u32) bool {
        assert(offset < none);
        assert(landing_offset < none);

        const reference = machine.reference_at(offset) orelse return false;
        const binding = machine.binding_at(landing_offset) orelse return false;
        const scopes = machine.semantic.scope_slice();
        var scope = reference.scope;

        assert(scopes.len <= table_count_max);
        assert(binding.name.offset == landing_offset);

        for (0..scopes.len + 1) |_| {
            if (scope == binding.scope) return true;
            if (scope >= scopes.len) return false;

            const held = scopes[scope];
            if (held.parent == none) return false;

            scope = held.parent;
        }

        return false;
    }

    fn reference_at(machine: *const Machine, offset: u32) ?Reference {
        const references = machine.semantic.reference_slice();

        assert(references.len <= table_count_max);
        assert(machine.tokens.items.capacity() == token_count_max);

        for (references) |held| {
            if (held.name.offset == offset) return held;
        }

        return null;
    }

    fn rejected(machine: *const Machine) ?u32 {
        const errors = machine.tree.diagnostic_slice();

        assert(errors.len <= diagnostic_count_max);
        assert(machine.tokens.items.capacity() == token_count_max);

        if (errors.len == 0) return null;
        return errors[0].span.offset;
    }
};

fn corpus_selected(basename: []const u8) bool {
    assert(basename.len > 0);

    return std.mem.eql(u8, std.Io.Dir.path.extension(basename), ".zig");
}

fn differing_entries(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    shared: *const CompareWorker.Shared,
    files: []const Fixture,
) !std.ArrayList([]const u8) {
    var entries: std.ArrayList([]const u8) = .empty;
    var rows: usize = 0;
    var worker: CompareWorker = undefined;

    assert(shared.held.len > 0);
    assert(files.len <= file_count_max);

    try worker.init(gpa, shared);
    defer worker.deinit(gpa);

    for (files) |*fixture| {
        if (names_contain(shared.carried, fixture.name)) continue;

        switch (try worker.verdict_of(fixture, &rows)) {
            .abstained, .agreed => {},
            .differing => |entry| try entries.append(arena, try arena.dupe(u8, entry)),
        }
    }

    assert(entries.items.len <= files.len);

    return entries;
}

fn differing_report(arena: std.mem.Allocator, differing: []const []const u8) !void {
    assert(differing.len <= file_count_max);

    if (differing.len == 0) return;

    const joined = try std.mem.concat(arena, u8, differing);
    var path_bytes: [environment.value_bytes_max]u8 = undefined;

    if (environment.get("SCYLLA_REPORT", &path_bytes)) |path| {
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{
            .sub_path = path,
            .data = joined,
        });
    }

    const shown_end = @min(differing.len, report_shown_max);
    const shown = try std.mem.concat(arena, u8, differing[0..shown_end]);

    assert(shown.len <= joined.len);

    std.debug.print("{d} files resolve differently\n{s}", .{ differing.len, shown });

    return error.TestUnexpectedResult;
}

fn digits(text: []const u8, cursor: *usize) u64 {
    var value: u64 = 0;

    assert(cursor.* <= text.len + 1);

    if (cursor.* >= text.len) return value;

    for (text[cursor.*..]) |byte| {
        if (!std.ascii.isDigit(byte)) break;

        value = value * 10 + (byte - '0');
        cursor.* += 1;
    }

    assert(cursor.* <= text.len);

    return value;
}

fn fixture_compare(
    arena: std.mem.Allocator,
    machine: *Machine,
    rows: *usize,
    held: []const u8,
    parsed: ?[]const u8,
    fixture: *const Fixture,
) !Verdict {
    if (parsed) |text| assert(text.len <= std.math.maxInt(u32));

    var place: u32 = 0;

    assert(held.len > 0);
    assert(fixture.name.len > 0);

    if (try rejected_of(arena, parsed, fixture.name, &place)) {
        return try rejected_compare(arena, machine, fixture, place);
    }

    var recorded: Golden = .{ .broken = false, .rows = .empty };
    if (!try golden(arena, held, fixture.name, &recorded)) return .abstained;
    if (recorded.broken) return .abstained;
    if (!machine.build(fixture.source)) return .abstained;

    var moved: std.ArrayList([]const u8) = .empty;

    try moved_rows(arena, fixture.source, recorded.rows.items, machine, rows, &moved);

    if (moved.items.len == 0) return .agreed;

    const joined = try std.mem.concat(arena, u8, moved.items);
    const entry = try arena.print("=== {s}\n{s}", .{ fixture.name, joined });

    return .{ .differing = entry };
}

fn golden(arena: std.mem.Allocator, root: []const u8, name: []const u8, held: *Golden) !bool {
    assert(root.len > 0);
    assert(name.len > 0);

    var path_buffer: [path_bytes_max]u8 = undefined;
    const path = try std.mem.print(&path_buffer, "{s}/{s}.json", .{ root, name });
    const limit: std.Io.Limit = .limited(golden_bytes_max);
    const io = std.testing.io;
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, limit) catch return false;
    const broken = std.mem.find(u8, text, "\"broken\":true") != null;

    held.* = .{ .broken = broken, .rows = .empty };

    const key = "\"rows\":[";
    const start = std.mem.find(u8, text, key) orelse return true;
    var offset = start + key.len;

    for (0..text.len) |_| {
        if (offset >= text.len) break;
        if (text[offset] != '[') break;

        try held.rows.append(arena, golden_row(text, &offset));
    }

    assert(held.rows.items.len <= text.len);

    return true;
}

fn golden_row(text: []const u8, cursor: *usize) Row {
    var offset = cursor.* + 1;

    assert(cursor.* < text.len);
    assert(text[cursor.*] == '[');

    const use_offset: u32 = @intCast(digits(text, &offset));

    offset = skipped(text, offset, ',') + 1;

    const negative = offset < text.len and text[offset] == '-';

    if (negative) offset += 1;

    const landed: i64 = @intCast(digits(text, &offset));

    offset = skipped(text, offset, ']') + 1;

    if (offset < text.len) {
        if (text[offset] == ',') offset += 1;
    }

    cursor.* = offset;

    return .{ .landed = if (negative) -landed else landed, .offset = use_offset };
}

fn moved_rows(
    arena: std.mem.Allocator,
    source: []const u8,
    recorded: []const Row,
    machine: *const Machine,
    rows: *usize,
    moved: *std.ArrayList([]const u8),
) !void {
    assert(source.len <= std.math.maxInt(u32));
    assert(moved.items.len == 0);
    assert(recorded.len <= std.math.maxInt(u32));

    for (recorded) |row| {
        const landing = std.math.cast(u32, row.landed) orelse continue;
        if (!std.mem.eql(u8, named(source, row.offset), named(source, landing))) continue;
        if (machine.conditional(source, row.offset)) continue;
        if (!machine.reachable(row.offset, landing)) continue;

        const mine = machine.landing(row.offset) orelse continue;

        rows.* += 1;

        if (mine != row.landed) {
            const format = "  {d} zls {d} scylla {d}\n";
            const line = try arena.print(format, .{ row.offset, row.landed, mine });

            try moved.append(arena, line);
        }
    }

    moved.shrinkRetainingCapacity(@min(moved.items.len, moved_shown_max));
}

fn named(source: []const u8, offset: u32) []const u8 {
    assert(source.len <= std.math.maxInt(u32));
    assert(offset < none);

    const start: usize = offset;
    if (start >= source.len) return &.{};

    var end = start;

    for (source[start..]) |byte| {
        const word = std.ascii.isAlphanumeric(byte) or byte == '_';
        if (!word) break;

        end += 1;
    }

    assert(end <= source.len);
    assert(end >= start);

    return source[start..end];
}

fn names_contain(names: []const []const u8, name: []const u8) bool {
    assert(name.len > 0);
    assert(names.len <= file_count_max);

    for (names) |held| {
        if (std.mem.eql(u8, held, name)) return true;
    }

    return false;
}

fn quoted(arena: std.mem.Allocator, text: []const u8, from: usize, held: *Quoted) !bool {
    assert(text.len <= std.math.maxInt(u32));
    assert(from < none);

    const open = skipped(text, from, '"');
    if (open >= text.len) return false;

    var found: std.ArrayList(u8) = .empty;
    var offset = open + 1;

    assert(text[open] == '"');
    assert(offset <= text.len);

    for (0..text.len) |_| {
        if (offset >= text.len) break;

        const byte = text[offset];

        offset += 1;

        if (byte == '\\') {
            offset += 1;

            continue;
        }

        if (byte == '"') {
            held.* = .{ .after = offset, .text = found.items };

            return true;
        }

        var encoded: [2]u8 = undefined;
        const encoded_bytes = std.unicode.utf8Encode(byte, &encoded) catch unreachable;

        try found.appendSlice(arena, encoded[0..encoded_bytes]);
    }

    return false;
}

fn rejected_compare(
    arena: std.mem.Allocator,
    machine: *Machine,
    fixture: *const Fixture,
    place: u32,
) !Verdict {
    assert(place < none);

    const ran = machine.parse(fixture.source);
    const mine = machine.rejected();
    const matched = if (mine) |offset| offset == place else false;
    const agreed = ran and matched;

    assert(fixture.name.len > 0);
    assert(fixture.source.len <= std.math.maxInt(u32));

    if (agreed) return .agreed;

    const shown = if (mine) |offset|
        try arena.print("Some({d})", .{offset})
    else
        "None";

    const format = "=== {s}\n  scylla rejects at {s} and std.zig.Ast at {d}\n";
    const entry = try arena.print(format, .{ fixture.name, shown, place });

    return .{ .differing = entry };
}

fn rejected_of(arena: std.mem.Allocator, parsed: ?[]const u8, name: []const u8, place: *u32) !bool {
    if (parsed) |text| assert(text.len <= std.math.maxInt(u32));

    const root = parsed orelse return false;
    var held: oracle.Golden = undefined;

    assert(root.len > 0);
    assert(name.len > 0);

    if (!try oracle.golden(arena, root, name, &held)) return false;

    const rejected = held.rejected orelse return false;

    place.* = rejected;

    return true;
}

fn require(condition: bool, comptime format: []const u8, arguments: anytype) !void {
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    if (condition) return;

    std.debug.print(format ++ "\n", arguments);

    return error.TestUnexpectedResult;
}

fn residue(arena: std.mem.Allocator) !std.ArrayList([]const u8) {
    var found: std.ArrayList([]const u8) = .empty;
    const limit: std.Io.Limit = .limited(residue_bytes_max);
    const io = std.testing.io;
    const text = std.Io.Dir.cwd().readFileAlloc(io, residue_path, arena, limit) catch return found;
    const key = "\"fixture\":";
    var offset: usize = 0;

    assert(text.len < residue_bytes_max);
    assert(key.len == 10);

    for (0..text.len) |_| {
        const start = std.mem.findPos(u8, text, offset, key) orelse break;
        var held: Quoted = undefined;
        if (!try quoted(arena, text, start + key.len, &held)) break;

        try found.append(arena, held.text);
        offset = held.after;
    }

    return found;
}

fn skipped(text: []const u8, from: usize, byte: u8) usize {
    assert(byte != 0);
    assert(from <= text.len + 1);

    if (from >= text.len) return from;

    for (from..text.len) |index| {
        if (text[index] == byte) return index;
    }

    return text.len;
}

test "the corpus resolves what zls resolves" {
    const gpa = std.testing.allocator;
    const held = corpus.named(.zls) orelse return;
    const root = corpus.named(.root) orelse return;
    var files = try corpus.collect(gpa, root, source_bytes_max, corpus_selected);
    defer files.deinit(gpa);

    if (files.slice().len == 0) return;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const carried = try residue(arena);

    const shared: CompareWorker.Shared = .{
        .carried = carried.items,
        .held = held,
        .parsed = corpus.named(.golden),
    };

    var counts = std.mem.zeroes(CompareWorker.Tally);

    assert(held.len > 0);
    assert(counts.differing == 0);

    try stripe.run(CompareWorker, gpa, &shared, files.slice(), &counts);

    const named_count = counts.compared + carried.items.len;

    try require(
        named_count >= floor.corpus_resolve_zig.files,
        "the corpus lost its Zig files: {d} named, {d} abstained, floor {d}",
        .{ named_count, counts.abstained, floor.corpus_resolve_zig.files },
    );

    try require(
        counts.rows >= floor.corpus_resolve_zig.rows,
        "{d} names compared, floor {d}",
        .{ counts.rows, floor.corpus_resolve_zig.rows },
    );

    if (counts.differing == 0) return;

    const differing = try differing_entries(arena, gpa, &shared, files.slice());

    assert(differing.items.len == counts.differing);

    try differing_report(arena, differing.items);
}
