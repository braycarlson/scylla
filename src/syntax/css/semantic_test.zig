const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const DefinitionKind = @import("semantic.zig").DefinitionKind;
const EventsType = @import("../tree.zig").EventsType;
const Kind = @import("kind.zig").Kind;
const Parser = @import("parse.zig").Parser;
const Semantic = @import("semantic.zig").Semantic;
const Tokens = @import("../tokens.zig");
const TreeType = @import("../tree.zig").TreeType;
const UseKind = @import("semantic.zig").UseKind;
const corpus = @import("../../testing/corpus.zig");
const environment = @import("../../testing/environment.zig");
const floor = @import("../../testing/floor.zig");
const lex = @import("lex.zig").lex;
const raw_of = @import("../raw.zig").raw_of;
const stripe = @import("../../testing/stripe.zig");
const tally = @import("../../testing/tally.zig");
const Events = EventsType(Kind);
const Tree = TreeType(Kind);
const Fixture = corpus.File;

const Golden = struct {
    broken: bool,
    definitions: std.ArrayList(Row),
    uses: std.ArrayList(Row),
};

const Outcome = struct {
    mine: Rows,
    recorded: Golden,
};

const PostcssWorker = struct {
    arena: std.heap.ArenaAllocator,
    machine: *Machine,
    shared: *const Shared,

    pub const Item = Fixture;
    pub const Shared = struct { carried: []const []const u8, root: []const u8 };
    pub const Tally = struct { abstained: u32, compared: u32, differing: u32 };
    pub const weight = Fixture.weight;

    pub fn init(worker: *PostcssWorker, gpa: std.mem.Allocator, shared: *const Shared) !void {
        assert(shared.root.len > 0);
        assert(shared.carried.len <= file_count_max);

        worker.machine = try gpa.create(Machine);
        errdefer gpa.destroy(worker.machine);

        try worker.machine.init();

        worker.arena = .init(gpa);
        worker.shared = shared;
    }

    pub fn deinit(worker: *PostcssWorker, gpa: std.mem.Allocator) void {
        assert(worker.shared.root.len > 0);
        assert(worker.shared.carried.len <= file_count_max);

        worker.arena.deinit();
        worker.machine.deinit();
        gpa.destroy(worker.machine);
        worker.* = undefined;
    }

    pub fn visit(worker: *PostcssWorker, fixture: *const Fixture, counted: *Tally) !void {
        const shared = worker.shared;

        assert(fixture.name.len > 0);
        assert(counted.differing <= counted.compared);

        if (carried_contains(shared.carried, fixture.name)) return;

        _ = worker.arena.reset(.retain_capacity);

        const arena = worker.arena.allocator();
        var outcome: Outcome = undefined;
        const verdict = try corpus_verdict(arena, worker.machine, shared.root, fixture.*, &outcome);

        if (verdict == .abstained) {
            counted.abstained += 1;

            return;
        }

        if (verdict == .agrees) {
            try tally.agree(suite, "postcss", fixture.name);
        } else {
            counted.differing += 1;
        }

        counted.compared += 1;
    }
};

const Quoted = struct {
    text: []const u8,
    after: usize,
};

const Row = struct {
    kind: []const u8,
    name: []const u8,
    offset: u32,

    fn eql(left: Row, right: Row) bool {
        assert(left.kind.len > 0);
        assert(right.kind.len > 0);

        return row_less_than({}, left, right) == row_less_than({}, right, left);
    }
};

const Rows = struct {
    definitions: std.ArrayList(Row),
    uses: std.ArrayList(Row),
};

const Tallied = struct {
    abstained: u32,
    compared: u32,
    differing: u32,
    shown_end: usize,
};

const Verdict = enum { abstained, agrees, differs };

const TablesWorker = struct {
    gpa: std.mem.Allocator,
    machine: *Machine,

    pub const Item = Fixture;
    pub const Shared = struct {};
    pub const Tally = struct { compared: u32 };
    pub const weight = Fixture.weight;

    pub fn init(worker: *TablesWorker, gpa: std.mem.Allocator, shared: *const Shared) !void {
        comptime assert(@sizeOf(Shared) == 0);

        _ = shared;

        worker.machine = try gpa.create(Machine);
        errdefer gpa.destroy(worker.machine);

        try worker.machine.init();

        worker.gpa = gpa;

        assert(worker.machine.tokens.items.capacity() == token_count_max);
    }

    pub fn deinit(worker: *TablesWorker, gpa: std.mem.Allocator) void {
        assert(worker.machine.tokens.items.capacity() == token_count_max);
        assert(worker.gpa.vtable == gpa.vtable);

        worker.machine.deinit();
        gpa.destroy(worker.machine);
        worker.* = undefined;
    }

    pub fn visit(worker: *TablesWorker, fixture: *const Fixture, counted: *Tally) !void {
        assert(fixture.name.len > 0);
        assert(counted.compared <= file_count_max);

        if (!worker.machine.build(fixture.source)) return;

        try invariants_hold(worker.machine, fixture.source);
        try tally.agree(suite, "tables", fixture.name);

        counted.compared += 1;
    }
};

const Machine = struct {
    events: Events,
    parser: *Parser,
    raw: ArrayType(Kind),
    semantic: Semantic,
    tokens: Tokens,
    tree: Tree,

    fn init(machine: *Machine) !void {
        const gpa = std.testing.allocator;

        try machine.events.init(gpa, event_count_max);
        errdefer machine.events.deinit(gpa);

        machine.parser = try gpa.create(Parser);
        errdefer gpa.destroy(machine.parser);

        machine.raw = try .init(gpa, token_count_max);
        errdefer machine.raw.deinit(gpa);

        try machine.semantic.init(gpa, &limits_table);
        errdefer machine.semantic.deinit(gpa);

        machine.tokens = try .init(gpa, token_count_max);
        errdefer machine.tokens.deinit(gpa);

        machine.tree = try .init(gpa, node_count_max, diagnostic_count_max);

        assert(machine.raw.capacity() == token_count_max);
        assert(machine.semantic.count() == 0);
    }

    fn deinit(machine: *Machine) void {
        const gpa = std.testing.allocator;

        assert(machine.raw.capacity() == token_count_max);
        assert(machine.tokens.items.capacity() == token_count_max);

        machine.tree.deinit(gpa);
        machine.tokens.deinit(gpa);
        machine.semantic.deinit(gpa);
        machine.raw.deinit(gpa);
        gpa.destroy(machine.parser);
        machine.events.deinit(gpa);
        machine.* = undefined;
    }

    fn build(machine: *Machine, source: []const u8) bool {
        assert(source.len <= source_bytes_max);
        assert(machine.raw.capacity() == token_count_max);

        machine.tokens.clear();

        lex(source, &machine.tokens) catch return false;
        raw_of(Kind, machine.tokens.slice(), &machine.raw) catch return false;

        _ = machine.parser.build(
            source,
            machine.tokens.slice(),
            machine.raw.const_slice(),
            &machine.events,
            &machine.tree,
        );

        const outcome = machine.semantic.build(
            source,
            machine.tokens.slice(),
            machine.raw.const_slice(),
            &machine.tree,
        );

        return outcome == .complete;
    }

    fn names(
        machine: *const Machine,
        source: []const u8,
        kind: DefinitionKind,
        named: *std.ArrayList([]const u8),
    ) !void {
        const gpa = std.testing.allocator;

        assert(named.items.len == 0);
        assert(source.len <= source_bytes_max);

        for (machine.semantic.definition_slice()) |held| {
            if (held.kind != kind) continue;

            try named.append(gpa, held.name.text(source));
        }
    }

    fn unresolved(
        machine: *const Machine,
        source: []const u8,
        named: *std.ArrayList([]const u8),
    ) !void {
        const gpa = std.testing.allocator;

        assert(named.items.len == 0);
        assert(source.len <= source_bytes_max);

        for (machine.semantic.use_slice()) |held| {
            if (held.definition != none) continue;

            try named.append(gpa, held.name.text(source));
        }
    }

    fn rows(machine: *const Machine, gpa: std.mem.Allocator, source: []const u8) !Rows {
        var found: Rows = .{ .definitions = .empty, .uses = .empty };

        assert(source.len <= source_bytes_max);
        assert(machine.semantic.count() <= table_count_max);

        for (machine.semantic.definition_slice()) |held| {
            const named: []const u8 = switch (held.kind) {
                .custom_property => "custom-property",
                .font_family => "font-family",
                .keyframes => "keyframes",
                .class, .id => continue,
            };

            try found.definitions.append(gpa, .{
                .kind = named,
                .name = held.name.text(source),
                .offset = held.name.offset,
            });
        }

        for (machine.semantic.use_slice()) |held| {
            const named: []const u8 = switch (held.kind) {
                .custom_property => "custom-property",
                .font_family => "font-family",
                .keyframes => "keyframes",
            };

            try found.uses.append(gpa, .{
                .kind = named,
                .name = held.name.text(source),
                .offset = held.name.offset,
            });
        }

        std.mem.sort(Row, found.definitions.items, {}, row_less_than);
        std.mem.sort(Row, found.uses.items, {}, row_less_than);

        return found;
    }
};

const Malformed = error{ OutOfMemory, Unterminated };
const diagnostic_count_max: u32 = 1 << 12;
const event_count_max: u32 = 1 << 21;
const file_count_max: u32 = 1 << 20;
const fixture_root = "tests/fixtures/css-semantic";
const node_count_max: u32 = 1 << 18;
const report_shown_max: u32 = 3;
const none: u32 = std.math.maxInt(u32);
const source_bytes_max: u32 = 1 << 24;
const suite = "semantic_css";
const table_count_max: u32 = 1 << 16;
const token_count_max: u32 = 1 << 18;

const limits_table: Semantic.Limits = .{
    .binding_count_max = table_count_max,
    .fact_count_max = table_count_max,
    .reference_count_max = table_count_max,
    .scope_count_max = table_count_max,
};

fn invariants_hold(machine: *const Machine, source: []const u8) !void {
    const count = machine.semantic.count();

    assert(source.len <= source_bytes_max);
    assert(count <= table_count_max);

    for (machine.semantic.definition_slice(), 0..) |held, position| {
        const index: u32 = @intCast(position);

        try std.testing.expect(held.name.end() <= source.len);
        try std.testing.expect(held.name.length > 0);

        if (held.name_previous == none) continue;

        try std.testing.expect(held.name_previous < count);
        try std.testing.expect(held.name_previous != index);
    }

    try uses_hold(machine, source);
    try uses_of_hold(machine);
}

fn uses_hold(machine: *const Machine, source: []const u8) !void {
    assert(source.len <= source_bytes_max);
    assert(machine.semantic.count() <= table_count_max);

    for (machine.semantic.use_slice()) |held| {
        try std.testing.expect(held.name.end() <= source.len);

        if (held.definition == none) continue;

        const definition = machine.semantic.get(held.definition) orelse {
            return error.TestUnexpectedResult;
        };

        try std.testing.expect(definition.kind.reads(held.kind));
        try std.testing.expectEqualStrings(definition.name.text(source), held.name.text(source));
    }
}

fn uses_of_hold(machine: *const Machine) !void {
    const count = machine.semantic.count();

    assert(count <= table_count_max);
    assert(machine.semantic.use_slice().len <= table_count_max);

    for (0..count) |position| {
        const index: u32 = @intCast(position);
        var uses = machine.semantic.uses_of(index);

        for (0..table_count_max + 1) |_| {
            const held = uses.next() orelse break;

            try std.testing.expectEqual(index, machine.semantic.use_slice()[held].definition);
        }
    }
}

fn fixture_read(gpa: std.mem.Allocator, name: []const u8) ![]const u8 {
    const io = std.testing.io;

    assert(name.len > 0);
    assert(std.mem.endsWith(u8, name, ".css"));

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.mem.print(&path_buffer, "{s}/{s}", .{ fixture_root, name });
    const limit: std.Io.Limit = .limited(source_bytes_max);

    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, limit);
}

fn fixtures(gpa: std.mem.Allocator) !corpus.Files {
    const found = try corpus.collect(gpa, fixture_root, source_bytes_max, corpus_selected);
    const slice = found.slice();

    assert(slice.len <= file_count_max);
    if (slice.len > 1) assert(Fixture.less_than({}, slice[0], slice[1]));

    return found;
}

fn corpus_files(gpa: std.mem.Allocator) !corpus.Files {
    const root = corpus.named(.root) orelse return .{ .list = .empty };
    const found = try corpus.collect(gpa, root, source_bytes_max, corpus_selected);

    assert(root.len > 0);
    assert(found.slice().len <= file_count_max);

    return found;
}

fn corpus_selected(basename: []const u8) bool {
    assert(basename.len > 0);

    return std.mem.eql(u8, std.Io.Dir.path.extension(basename), ".css");
}

fn string_less_than(context: void, left: []const u8, right: []const u8) bool {
    _ = context;
    assert(left.len <= std.math.maxInt(u32));
    assert(right.len <= std.math.maxInt(u32));

    return std.mem.order(u8, left, right) == .lt;
}

fn deduplicated(named: *std.ArrayList([]const u8)) void {
    var kept: usize = 0;

    assert(named.items.len <= table_count_max);

    for (named.items) |held| {
        if (kept > 0) {
            if (std.mem.eql(u8, named.items[kept - 1], held)) continue;
        }

        named.items[kept] = held;
        kept += 1;
    }

    named.shrinkRetainingCapacity(kept);

    assert(named.items.len == kept);
}

fn row_less_than(context: void, left: Row, right: Row) bool {
    _ = context;
    assert(left.kind.len > 0);
    assert(right.kind.len > 0);

    const by_kind = std.mem.order(u8, left.kind, right.kind);
    if (by_kind != .eq) return by_kind == .lt;

    const by_name = std.mem.order(u8, left.name, right.name);
    if (by_name != .eq) return by_name == .lt;
    return left.offset < right.offset;
}

fn rows_equal(mine: []const Row, theirs: []const Row) bool {
    assert(mine.len <= table_count_max);
    assert(theirs.len <= table_count_max);

    if (mine.len != theirs.len) return false;

    for (mine, theirs) |left, right| {
        if (!left.eql(right)) return false;
    }

    return true;
}

fn rows_contain(rows: []const Row, wanted: Row) bool {
    assert(rows.len <= table_count_max);
    assert(wanted.kind.len > 0);

    for (rows) |held| {
        if (held.eql(wanted)) return true;
    }

    return false;
}

fn quoted(arena: std.mem.Allocator, text: []const u8, from: usize) Malformed!Quoted {
    assert(text.len <= std.math.maxInt(u32));
    assert(from < none);

    const open = std.mem.findScalarPos(u8, text, from, '"') orelse return error.Unterminated;
    var found: std.ArrayList(u8) = .empty;
    var offset = open + 1;

    assert(open >= from);
    assert(offset <= text.len);

    while (offset < text.len) {
        assert(found.items.len < text.len);

        const byte = text[offset];

        offset += 1;

        if (byte == '"') return .{ .text = found.items, .after = offset };

        if (byte != '\\') {
            try found.append(arena, byte);

            continue;
        }

        if (offset >= text.len) return error.Unterminated;

        const held = text[offset];

        offset += 1;

        switch (held) {
            'n' => try found.append(arena, '\n'),
            'r' => try found.append(arena, '\r'),
            't' => try found.append(arena, '\t'),
            'u' => offset = try escaped(arena, text, offset, &found),
            else => try found.append(arena, held),
        }
    }

    return error.Unterminated;
}

fn escaped(
    arena: std.mem.Allocator,
    text: []const u8,
    from: usize,
    found: *std.ArrayList(u8),
) Malformed!usize {
    var value: u21 = 0;

    assert(from <= text.len);
    assert(found.items.len < text.len);

    if (from + 4 > text.len) return error.Unterminated;

    for (text[from .. from + 4]) |digit| {
        const nibble = std.fmt.charToDigit(digit, 16) catch return error.Unterminated;

        value = value * 16 + nibble;
    }

    var buffer: [4]u8 = undefined;
    const written = std.unicode.utf8Encode(value, &buffer) catch return error.Unterminated;

    try found.appendSlice(arena, buffer[0..written]);

    assert(from + 4 <= text.len);

    return from + 4;
}

fn rows_of(arena: std.mem.Allocator, text: []const u8, key: []const u8) !std.ArrayList(Row) {
    assert(text.len <= std.math.maxInt(u32));
    assert(key.len <= std.math.maxInt(u32));

    var found: std.ArrayList(Row) = .empty;
    const start = std.mem.find(u8, text, key) orelse return found;
    var offset = start + key.len;

    assert(key.len > 0);

    assert(offset <= text.len);

    for (0..text.len + 1) |_| {
        if (offset >= text.len) break;
        if (text[offset] != '[') break;

        const kind = quoted(arena, text, offset) catch |err| switch (err) {
            error.Unterminated => break,
            error.OutOfMemory => return err,
        };

        const name = quoted(arena, text, kind.after) catch |err| switch (err) {
            error.Unterminated => break,
            error.OutOfMemory => return err,
        };

        var cursor = name.after;

        while (cursor < text.len) : (cursor += 1) {
            if (std.ascii.isDigit(text[cursor])) break;
        }

        var number: u32 = 0;

        while (cursor < text.len) : (cursor += 1) {
            if (!std.ascii.isDigit(text[cursor])) break;

            number = number * 10 + (text[cursor] - '0');
        }

        try found.append(arena, .{ .kind = kind.text, .name = name.text, .offset = number });

        cursor = std.mem.findScalarPos(u8, text, cursor, ']') orelse text.len;
        cursor += 1;

        if (cursor < text.len) {
            if (text[cursor] == ',') cursor += 1;
        }

        offset = cursor;
    }

    std.mem.sort(Row, found.items, {}, row_less_than);

    return found;
}

fn golden(arena: std.mem.Allocator, root: []const u8, name: []const u8) !Golden {
    const io = std.testing.io;

    assert(root.len > 0);
    assert(name.len > 0);

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.mem.print(&path_buffer, "{s}/{s}.json", .{ root, name });
    const limit: std.Io.Limit = .limited(source_bytes_max);

    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, limit) catch {
        return error.Missing;
    };

    return .{
        .broken = std.mem.find(u8, text, "\"broken\":true") != null,
        .definitions = try rows_of(arena, text, "\"definitions\":["),
        .uses = try rows_of(arena, text, "\"uses\":["),
    };
}

fn residue(arena: std.mem.Allocator) !std.ArrayList([]const u8) {
    const io = std.testing.io;
    const limit: std.Io.Limit = .limited(source_bytes_max);
    var found: std.ArrayList([]const u8) = .empty;
    const path = "tests/residue-css-semantic.json";
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, limit) catch return found;
    var offset: usize = 0;

    assert(text.len < source_bytes_max);

    for (0..text.len + 1) |_| {
        const start = std.mem.findPos(u8, text, offset, "\"fixture\":") orelse break;

        const name = quoted(arena, text, start + 10) catch |err| switch (err) {
            error.Unterminated => break,
            error.OutOfMemory => return err,
        };

        try found.append(arena, name.text);
        offset = name.after;
    }

    assert(offset <= text.len);

    return found;
}

fn carried_contains(carried: []const []const u8, name: []const u8) bool {
    assert(name.len > 0);
    assert(carried.len <= file_count_max);

    for (carried) |held| {
        if (std.mem.eql(u8, held, name)) return true;
    }

    return false;
}

fn report(
    arena: std.mem.Allocator,
    written: *std.ArrayList(u8),
    name: []const u8,
    mine: Rows,
    theirs: Golden,
) !void {
    assert(theirs.definitions.items.len <= std.math.maxInt(u32));

    const definitions = theirs.definitions.items;

    assert(name.len > 0);
    assert(mine.definitions.items.len <= table_count_max);

    try written.print(arena, "=== {s}\n", .{name});
    try report_side(arena, written, "definitions", mine.definitions.items, definitions);
    try report_side(arena, written, "uses", mine.uses.items, theirs.uses.items);
}

fn report_side(
    arena: std.mem.Allocator,
    written: *std.ArrayList(u8),
    label: []const u8,
    mine: []const Row,
    theirs: []const Row,
) !void {
    assert(label.len > 0);
    assert(mine.len <= table_count_max);
    assert(theirs.len <= std.math.maxInt(u32));

    for (mine) |row| {
        if (rows_contain(theirs, row)) continue;

        try written.print(arena, "  scylla only {s} {s} {s} {d}\n", .{
            label,
            row.kind,
            row.name,
            row.offset,
        });
    }

    for (theirs) |row| {
        if (rows_contain(mine, row)) continue;

        try written.print(arena, "  postcss only {s} {s} {s} {d}\n", .{
            label,
            row.kind,
            row.name,
            row.offset,
        });
    }
}

fn directory_exists(path: []const u8) bool {
    const io = std.testing.io;

    assert(path.len > 0);
    assert(path.len < std.Io.Dir.max_path_bytes);

    var directory = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;

    directory.close(io);

    return true;
}

fn corpus_verdict(
    arena: std.mem.Allocator,
    machine: *Machine,
    root: []const u8,
    fixture: Fixture,
    outcome: *Outcome,
) !Verdict {
    assert(root.len > 0);
    assert(fixture.name.len > 0);

    const recorded = golden(arena, root, fixture.name) catch |err| switch (err) {
        error.Missing => return .abstained,
        else => return err,
    };

    if (recorded.broken) return .abstained;
    if (!machine.build(fixture.source)) return .abstained;

    const mine = try machine.rows(arena, fixture.source);
    const definitions_agree = rows_equal(mine.definitions.items, recorded.definitions.items);
    const uses_agree = rows_equal(mine.uses.items, recorded.uses.items);
    const agreed = definitions_agree and uses_agree;

    outcome.* = .{ .mine = mine, .recorded = recorded };

    if (agreed) return .agrees;
    return .differs;
}

fn corpus_report(
    gpa: std.mem.Allocator,
    shared: *const PostcssWorker.Shared,
    files: []const Fixture,
    counted: PostcssWorker.Tally,
) !void {
    assert(counted.differing <= counted.compared);
    assert(files.len <= file_count_max);

    if (counted.differing == 0) return;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const machine = try gpa.create(Machine);
    defer gpa.destroy(machine);

    try machine.init();
    defer machine.deinit();

    var tallied: Tallied = .{
        .abstained = counted.abstained,
        .compared = counted.compared,
        .differing = 0,
        .shown_end = 0,
    };

    var written: std.ArrayList(u8) = .empty;

    for (files) |fixture| {
        if (carried_contains(shared.carried, fixture.name)) continue;

        var outcome: Outcome = undefined;
        const verdict = try corpus_verdict(arena, machine, shared.root, fixture, &outcome);
        if (verdict != .differs) continue;

        try report(arena, &written, fixture.name, outcome.mine, outcome.recorded);

        tallied.differing += 1;

        if (tallied.differing == report_shown_max) tallied.shown_end = written.items.len;
    }

    assert(tallied.differing == counted.differing);

    try differing_fail(&tallied, written.items);
}

fn differing_fail(tallied: *const Tallied, written: []const u8) !void {
    assert(tallied.differing <= tallied.compared);
    assert(tallied.shown_end <= written.len);

    if (tallied.differing == 0) return;

    var path_bytes: [environment.value_bytes_max]u8 = undefined;

    if (environment.get("SCYLLA_REPORT", &path_bytes)) |path| {
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = written });
    }

    const shown_end = if (tallied.shown_end == 0) written.len else tallied.shown_end;

    std.debug.print("{d} files name something else\n{s}", .{
        tallied.differing,
        written[0..shown_end],
    });

    return error.TestUnexpectedResult;
}

test "a custom property reaches the declaration that names it" {
    const gpa = std.testing.allocator;
    const source = try fixture_read(gpa, "properties.css");
    defer gpa.free(source);

    const machine = try gpa.create(Machine);
    defer gpa.destroy(machine);

    try machine.init();
    defer machine.deinit();

    try std.testing.expect(machine.build(source));

    var named: std.ArrayList([]const u8) = .empty;
    defer named.deinit(gpa);

    try machine.names(source, .custom_property, &named);
    std.mem.sort([]const u8, named.items, {}, string_less_than);
    deduplicated(&named);

    try std.testing.expectEqual(2, named.items.len);
    try std.testing.expectEqualStrings("--brand", named.items[0]);
    try std.testing.expectEqualStrings("--space", named.items[1]);

    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(gpa);

    try machine.unresolved(source, &missing);

    try std.testing.expectEqual(1, missing.items.len);
    try std.testing.expectEqualStrings("--missing", missing.items[0]);

    try invariants_hold(machine, source);
}

test "a keyframes name reaches the at rule that declares it" {
    const gpa = std.testing.allocator;
    const source = try fixture_read(gpa, "keyframes.css");
    defer gpa.free(source);

    const machine = try gpa.create(Machine);
    defer gpa.destroy(machine);

    try machine.init();
    defer machine.deinit();

    try std.testing.expect(machine.build(source));

    var named: std.ArrayList([]const u8) = .empty;
    defer named.deinit(gpa);

    try machine.names(source, .keyframes, &named);

    try std.testing.expectEqual(1, named.items.len);
    try std.testing.expectEqualStrings("slide", named.items[0]);

    var reached = false;

    for (machine.semantic.use_slice()) |held| {
        if (held.kind != UseKind.keyframes) continue;

        if (held.definition != none) reached = true;
    }

    try std.testing.expect(reached);
    try invariants_hold(machine, source);
}

test "every fixture holds the table invariants" {
    const gpa = std.testing.allocator;
    var found = try fixtures(gpa);
    defer found.deinit(gpa);

    try std.testing.expect(found.slice().len > 0);

    const machine = try gpa.create(Machine);
    defer gpa.destroy(machine);

    try machine.init();
    defer machine.deinit();

    for (found.slice()) |fixture| {
        try std.testing.expect(machine.build(fixture.source));
        try invariants_hold(machine, fixture.source);
    }
}

test "every corpus file holds the table invariants" {
    const gpa = std.testing.allocator;
    var found = try corpus_files(gpa);
    defer found.deinit(gpa);

    if (found.slice().len == 0) return;

    var counted: TablesWorker.Tally = .{ .compared = 0 };

    try stripe.run(TablesWorker, gpa, &.{}, found.slice(), &counted);
    try std.testing.expect(counted.compared >= floor.corpus_semantic_css);
}

test "every fixture names what postcss names" {
    const gpa = std.testing.allocator;
    const held = corpus.named(.css) orelse return;
    const root = "tests/fixtures/golden-css-semantic";

    if (!directory_exists(root)) {
        if (!directory_exists(held)) return;
    }

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    var found = try fixtures(gpa);
    defer found.deinit(gpa);

    const machine = try gpa.create(Machine);
    defer gpa.destroy(machine);

    try machine.init();
    defer machine.deinit();

    var compared: usize = 0;

    for (found.slice()) |fixture| {
        const recorded = golden(arena, root, fixture.name) catch |err| switch (err) {
            error.Missing => continue,
            else => return err,
        };

        try std.testing.expect(machine.build(fixture.source));

        const mine = try machine.rows(arena, fixture.source);

        try std.testing.expect(rows_equal(mine.definitions.items, recorded.definitions.items));
        try std.testing.expect(rows_equal(mine.uses.items, recorded.uses.items));

        compared += 1;
    }

    try std.testing.expectEqual(found.slice().len, compared);
}

test "the corpus names what postcss names" {
    const gpa = std.testing.allocator;
    const held = corpus.named(.css) orelse return;
    var found = try corpus_files(gpa);
    defer found.deinit(gpa);

    if (found.slice().len == 0) return;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const carried = try residue(arena);
    const shared: PostcssWorker.Shared = .{ .carried = carried.items, .root = held };
    var counted: PostcssWorker.Tally = .{ .abstained = 0, .compared = 0, .differing = 0 };

    try stripe.run(PostcssWorker, gpa, &shared, found.slice(), &counted);

    const named_count = counted.compared + @as(u32, @intCast(carried.items.len));

    if (named_count < floor.corpus_postcss_css) {
        std.debug.print("the corpus lost its CSS files: {d} named, {d} abstained, floor {d}\n", .{
            named_count,
            counted.abstained,
            floor.corpus_postcss_css,
        });

        return error.TestUnexpectedResult;
    }

    try corpus_report(gpa, &shared, found.slice(), counted);
}
