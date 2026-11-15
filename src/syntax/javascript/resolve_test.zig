const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const Dialect = @import("dialect.zig").Dialect;
const EventsType = @import("../tree.zig").EventsType;
const Kind = @import("kind.zig").Kind;
const ModuleKind = @import("semantic.zig").ModuleKind;
const Parser = @import("parse.zig").Parser;
const Semantic = @import("semantic.zig").Semantic;
const Structure = @import("../tree.zig").Structure;
const Tokens = @import("../tokens.zig");
const TreeType = @import("../tree.zig").TreeType;
const raw_of = @import("../raw.zig").raw_of;
const corpus = @import("../../testing/corpus.zig");
const environment = @import("../../testing/environment.zig");
const floor = @import("../../testing/floor.zig");
const lex = @import("lex.zig").lex;
const oracle = @import("../../testing/oracle.zig");
const stripe = @import("../../testing/stripe.zig");
const tally = @import("../../testing/tally.zig");
const Events = EventsType(Kind);
const Tree = TreeType(Kind);

const CompareWorker = struct {
    arena: std.heap.ArenaAllocator,
    carried: *const oracle.Residue,
    held: []const u8,
    machine: *Machine,

    pub const Item = corpus.File;

    pub const Shared = struct {
        carried: *const oracle.Residue,
        held: []const u8,
    };

    pub const Tally = struct { compared: u32, differing: u32 };
    pub const weight = corpus.File.weight;

    fn verdict_of(worker: *CompareWorker, file: *const corpus.File) !Verdict {
        assert(file.name.len > 0);
        assert(worker.held.len > 0);

        _ = worker.arena.reset(.retain_capacity);

        return try corpus_compare(worker.arena.allocator(), worker.machine, worker.held, file);
    }

    pub fn deinit(worker: *CompareWorker, gpa: std.mem.Allocator) void {
        assert(worker.held.len > 0);
        assert(worker.machine.tokens.items.capacity() == token_count_max);

        worker.arena.deinit();
        worker.machine.destroy(gpa);
        worker.* = undefined;
    }

    pub fn init(worker: *CompareWorker, gpa: std.mem.Allocator, shared: *const Shared) !void {
        assert(shared.held.len > 0);
        assert(shared.carried.fixtures.items.len <= file_count_max);

        worker.* = .{
            .arena = .init(gpa),
            .carried = shared.carried,
            .held = shared.held,
            .machine = try Machine.create(gpa),
        };

        assert(worker.held.len == shared.held.len);
        assert(worker.carried == shared.carried);
    }

    pub fn visit(worker: *CompareWorker, file: *const corpus.File, counts: *Tally) !void {
        assert(file.name.len > 0);
        assert(counts.differing <= counts.compared);

        if (worker.carried.contains(file.name)) return;

        switch (try worker.verdict_of(file)) {
            .skipped => {},
            .agreed => {
                try tally.agree(suite, "scope", file.name);

                counts.compared += 1;
            },
            .differing => {
                counts.compared += 1;
                counts.differing += 1;
            },
        }
    }
};

const DivergeWorker = struct {
    arena: std.heap.ArenaAllocator,
    carried: *const oracle.Residue,
    held: []const u8,
    machine: *Machine,

    pub const Item = corpus.File;
    pub const Shared = CompareWorker.Shared;
    pub const Tally = struct { matched: u32, named: u32 };
    pub const weight = corpus.File.weight;

    pub fn deinit(worker: *DivergeWorker, gpa: std.mem.Allocator) void {
        assert(worker.held.len > 0);
        assert(worker.machine.tokens.items.capacity() == token_count_max);

        worker.arena.deinit();
        worker.machine.destroy(gpa);
        worker.* = undefined;
    }

    pub fn init(worker: *DivergeWorker, gpa: std.mem.Allocator, shared: *const Shared) !void {
        assert(shared.held.len > 0);
        assert(shared.carried.fixtures.items.len <= file_count_max);

        worker.* = .{
            .arena = .init(gpa),
            .carried = shared.carried,
            .held = shared.held,
            .machine = try Machine.create(gpa),
        };

        assert(worker.held.len == shared.held.len);
        assert(worker.carried == shared.carried);
    }

    pub fn visit(worker: *DivergeWorker, file: *const corpus.File, counts: *Tally) !void {
        assert(file.name.len > 0);
        assert(counts.matched <= counts.named);

        if (!worker.carried.contains(file.name)) return;

        _ = worker.arena.reset(.retain_capacity);

        const fixture = fixture_of(file);
        const arena = worker.arena.allocator();

        counts.named += 1;

        if (!try diverges(arena, worker.machine, worker.held, fixture)) {
            std.debug.print("{s} matches its golden and needs no residue row\n", .{file.name});

            counts.matched += 1;
        }
    }
};

const Detected = struct {
    dialect: ?Dialect,
};

const Fixture = struct {
    dialect: ?Dialect,
    name: []const u8,
    source: []const u8,
};

const Golden = struct {
    broken: bool,
    rows: std.ArrayList(Row),
};

const Number = struct {
    after: usize,
    value: u32,
};

const Quoted = struct {
    after: usize,
    text: []const u8,
};

const Row = struct {
    landed: i64,
    offset: u32,

    fn equal(left: Row, right: Row) bool {
        assert(left.offset < std.math.maxInt(u32));
        assert(right.offset < std.math.maxInt(u32));

        const same = left.offset == right.offset and left.landed == right.landed;

        assert(!same or left.offset == right.offset);
        assert(!same or left.landed == right.landed);

        return same;
    }

    fn less_than(context: void, left: Row, right: Row) bool {
        assert(@TypeOf(context) == void);
        assert(@sizeOf(Row) > 0);

        if (left.offset != right.offset) return left.offset < right.offset;
        return left.landed < right.landed;
    }
};

const Signed = struct {
    after: usize,
    value: i64,
};

const Step = enum {
    both,
    moved,
    ours,
    theirs,

    fn of(left: ?Row, right: ?Row) ?Step {
        if (left) |held| assert(held.offset < std.math.maxInt(u32));
        if (right) |held| assert(held.offset < std.math.maxInt(u32));

        const one = left orelse {
            if (right == null) return null;
            return .theirs;
        };

        const two = right orelse return .ours;

        assert(left != null);

        assert(right != null);

        if (one.equal(two)) return .both;
        if (one.offset == two.offset) return .moved;
        if (one.offset < two.offset) return .ours;
        return .theirs;
    }
};

const Verdict = union(enum) {
    agreed,
    differing: []const u8,
    skipped,
};

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

    fn head_of(machine: *const Machine, index: u32) u32 {
        assert(index < none);

        const bindings = machine.semantic.binding_slice();
        var held = index;

        assert(index < bindings.len);
        assert(bindings.len <= binding_count_max);

        for (0..bindings.len) |_| {
            const previous = bindings[held].name_previous;
            if (previous == none) break;

            assert(previous < held);

            held = previous;
        }

        assert(bindings[held].name_previous == none);

        return held;
    }

    fn rows(machine: *const Machine, arena: std.mem.Allocator) !std.ArrayList(Row) {
        const bindings = machine.semantic.binding_slice();
        const references = machine.semantic.reference_slice();
        var found: std.ArrayList(Row) = .empty;

        assert(bindings.len <= binding_count_max);
        assert(references.len <= reference_count_max);

        try found.ensureTotalCapacity(arena, bindings.len + references.len);

        for (bindings) |held| {
            found.appendAssumeCapacity(.{ .landed = held.name.offset, .offset = held.name.offset });
        }

        for (references) |held| {
            const landed: i64 = switch (held.resolution) {
                .bound => |index| bindings[machine.head_of(index)].name.offset,
                .builtin, .external, .maybe, .unresolved => -1,
            };

            found.appendAssumeCapacity(.{ .landed = landed, .offset = held.name.offset });
        }

        rows_settle(&found);

        assert(found.items.len <= bindings.len + references.len);

        return found;
    }

    fn run(machine: *Machine, fixture: Fixture) Structure {
        assert(fixture.name.len > 0);
        assert(fixture.source.len <= source_bytes_max);

        const dialect = fixture.dialect orelse .javascript;
        return machine.run_source(fixture.source, dialect, module_of_name(fixture.name));
    }

    fn run_source(
        machine: *Machine,
        source: []const u8,
        dialect: Dialect,
        module: ?ModuleKind,
    ) Structure {
        assert(source.len <= std.math.maxInt(u32));

        machine.tokens.clear();

        var lexed: Structure = .complete;

        lex(source, &machine.tokens, dialect) catch |err| switch (err) {
            error.Truncated => {
                assert(machine.tokens.items.full());

                lexed = .{ .truncated = .tokens };
            },
        };

        raw_of(Kind, machine.tokens.slice(), &machine.raw) catch |err| switch (err) {
            error.Truncated => return .{ .truncated = .tokens },
        };

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
};

const binding_count_max: u32 = 1 << 16;
const diagnostic_count_max: u32 = 1 << 12;
const event_count_max: u32 = 1 << 21;
const every_category = [_][]const u8{ "function-body-scope", "not-javascript", "scylla" };
const fact_count_max: u32 = 1 << 14;
const file_count_max: u32 = 1 << 20;
const fixture_golden_root = "tests/fixtures/golden-tsscope";

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
const path_bytes_max: u32 = 4096;
const reference_count_max: u32 = 1 << 18;
const report_lines_max: u32 = 8;
const report_shown_max: usize = 3;
const residue_name = "residue-javascript-resolve.json";
const scope_count_max: u32 = 1 << 16;
const source_bytes_max: u32 = 1 << 26;
const suite = "resolve_javascript";
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

fn corpus_compare(
    arena: std.mem.Allocator,
    machine: *Machine,
    root: []const u8,
    file: *const corpus.File,
) !Verdict {
    assert(root.len > 0);
    assert(file.name.len > 0);

    const fixture = fixture_of(file);
    var expected: Golden = undefined;
    if (!try golden(arena, root, fixture.name, &expected)) return .skipped;
    if (expected.broken) return .skipped;
    if (machine.run(fixture) != .complete) return .skipped;

    const held = try machine.rows(arena);
    const rows = try placed(arena, held.items, expected.rows.items);
    if (rows_equal(rows.items, expected.rows.items)) return .agreed;
    return .{ .differing = try report(arena, fixture.name, rows.items, expected.rows.items) };
}

fn corpus_selected(basename: []const u8) bool {
    assert(basename.len > 0);

    return dialect_of(basename) != null;
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

fn differing_entries(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    shared: *const CompareWorker.Shared,
    files: []const corpus.File,
) !std.ArrayList([]const u8) {
    var entries: std.ArrayList([]const u8) = .empty;
    var worker: CompareWorker = undefined;

    assert(shared.held.len > 0);
    assert(files.len <= file_count_max);

    try worker.init(gpa, shared);
    defer worker.deinit(gpa);

    for (files) |*file| {
        if (shared.carried.contains(file.name)) continue;

        switch (try worker.verdict_of(file)) {
            .agreed, .skipped => {},
            .differing => |entry| try entries.append(arena, try arena.dupe(u8, entry)),
        }
    }

    assert(entries.items.len <= files.len);

    return entries;
}

fn differing_report(arena: std.mem.Allocator, differing: []const []const u8, compared: u32) !void {
    assert(differing.len <= file_count_max);
    assert(differing.len <= compared);

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

    const format = "{d} of {d} corpus files differ\n{s}";

    std.debug.print(format, .{ differing.len, compared, shown });

    return error.TestUnexpectedResult;
}

fn diverges(arena: std.mem.Allocator, machine: *Machine, root: []const u8, fixture: Fixture) !bool {
    assert(root.len > 0);
    assert(fixture.name.len > 0);

    var expected: Golden = undefined;
    if (!try golden(arena, root, fixture.name, &expected)) return true;
    if (expected.broken) return true;
    if (machine.run(fixture) != .complete) return true;

    const held = try machine.rows(arena);
    const rows = try placed(arena, held.items, expected.rows.items);

    return !rows_equal(rows.items, expected.rows.items);
}

fn files_contain(files: []const corpus.File, name: []const u8) bool {
    assert(name.len > 0);
    assert(files.len <= file_count_max);

    const found = std.sort.binarySearch(corpus.File, files, name, file_order);

    assert(found == null or std.mem.eql(u8, files[found.?].name, name));

    return found != null;
}

fn file_order(name: []const u8, file: corpus.File) std.math.Order {
    assert(name.len > 0);
    assert(file.name.len > 0);

    return std.mem.order(u8, name, file.name);
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

fn fixture_of(file: *const corpus.File) Fixture {
    assert(file.name.len > 0);
    assert(file.source.len <= source_bytes_max);

    const detected = dialect_of(std.Io.Dir.path.basename(file.name)) orelse unreachable;
    return .{ .dialect = detected.dialect, .name = file.name, .source = file.source };
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

    const key = "\"ast\":[";
    const start = std.mem.find(u8, text, key) orelse return true;
    var offset = start + key.len;

    for (0..text.len) |_| {
        if (offset >= text.len) break;
        if (text[offset] != '[') break;

        const position = number(text, offset);
        var kind: Quoted = undefined;
        var named: Quoted = undefined;

        if (!try quoted(arena, text, position.after, &kind)) break;
        if (!try quoted(arena, text, kind.after, &named)) break;

        const definition = signed(text, named.after);

        if (!std.mem.eql(u8, kind.text, "Signature")) {
            try held.rows.append(arena, .{ .landed = definition.value, .offset = position.value });
        }

        offset = definition.after;

        if (offset < text.len) {
            if (text[offset] == ']') offset += 1;
        }

        if (offset >= text.len) break;
        if (text[offset] != ',') break;

        offset += 1;
    }

    rows_settle(&held.rows);

    assert(held.rows.items.len <= text.len);

    return true;
}

fn names_contain(names: []const []const u8, name: []const u8) bool {
    assert(name.len > 0);
    assert(names.len <= file_count_max);

    for (names) |held| {
        if (std.mem.eql(u8, held, name)) return true;
    }

    return false;
}

fn number(text: []const u8, from: usize) Number {
    assert(from <= text.len);

    var offset = from;
    var value: u32 = 0;

    for (from..text.len) |index| {
        if (std.ascii.isDigit(text[index])) break;

        offset = index + 1;
    }

    for (offset..text.len) |index| {
        if (!std.ascii.isDigit(text[index])) break;

        value = value * 10 + (text[index] - '0');
        offset = index + 1;
    }

    assert(offset <= text.len);

    return .{ .after = offset, .value = value };
}

fn placed(arena: std.mem.Allocator, held: []const Row, expected: []const Row) !std.ArrayList(Row) {
    var found: std.ArrayList(Row) = .empty;
    var theirs: usize = 0;

    assert(held.len <= std.math.maxInt(u32));
    assert(expected.len <= std.math.maxInt(u32));

    for (held) |row| {
        for (theirs..expected.len) |_| {
            if (expected[theirs].offset >= row.offset) break;

            theirs += 1;
        }

        if (theirs >= expected.len) continue;
        if (expected[theirs].offset != row.offset) continue;

        try found.append(arena, row);
    }

    assert(found.items.len <= held.len);

    return found;
}

fn quoted(arena: std.mem.Allocator, text: []const u8, from: usize, held: *Quoted) !bool {
    assert(text.len <= std.math.maxInt(u32));
    assert(from < none);

    const open = std.mem.findScalarPos(u8, text, from, '"') orelse return false;
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

fn report(
    arena: std.mem.Allocator,
    name: []const u8,
    held: []const Row,
    expected: []const Row,
) ![]const u8 {
    assert(expected.len <= std.math.maxInt(u32));

    var text: std.ArrayList(u8) = .empty;
    var ours: usize = 0;
    var theirs: usize = 0;
    var shown: u32 = 0;

    assert(name.len > 0);
    assert(held.len <= std.math.maxInt(u32));

    try text.print(arena, "{s}:\n", .{name});

    for (0..held.len + expected.len) |_| {
        if (shown >= report_lines_max) break;

        const left: ?Row = if (ours < held.len) held[ours] else null;
        const right: ?Row = if (theirs < expected.len) expected[theirs] else null;
        const step = Step.of(left, right) orelse break;

        switch (step) {
            .both => {},
            .moved => {
                const format = "  {d} resolves to {d} and scope-manager resolves it to {d}\n";

                try text.print(arena, format, .{ left.?.offset, left.?.landed, right.?.landed });
            },
            .ours => try text.print(arena, "  scylla-only row at {d}\n", .{left.?.offset}),
            .theirs => {
                try text.print(arena, "  scope-manager-only row at {d}\n", .{right.?.offset});
            },
        }

        if (step != .theirs) ours += 1;
        if (step != .ours) theirs += 1;
        if (step != .both) shown += 1;
    }

    assert(shown <= report_lines_max);

    return text.items;
}

fn require(condition: bool, comptime format: []const u8, arguments: anytype) !void {
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    if (condition) return;

    std.debug.print(format ++ "\n", arguments);

    return error.TestUnexpectedResult;
}

fn rows_equal(left: []const Row, right: []const Row) bool {
    assert(left.len <= std.math.maxInt(u32));
    assert(right.len <= std.math.maxInt(u32));

    if (left.len != right.len) return false;

    for (left, right) |one, two| {
        if (!one.equal(two)) return false;
    }

    return true;
}

fn rows_settle(rows: *std.ArrayList(Row)) void {
    var kept: usize = 0;

    assert(rows.items.len <= rows.capacity);

    std.mem.sort(Row, rows.items, {}, Row.less_than);

    for (rows.items) |row| {
        if (kept > 0) {
            if (rows.items[kept - 1].equal(row)) continue;
        }

        rows.items[kept] = row;
        kept += 1;
    }

    rows.shrinkRetainingCapacity(kept);

    assert(rows.items.len == kept);
}

fn signed(text: []const u8, from: usize) Signed {
    assert(from <= text.len);

    var offset = from;
    var value: i64 = 0;

    for (from..text.len) |index| {
        const byte = text[index];
        if (std.ascii.isDigit(byte)) break;
        if (byte == '-') break;

        offset = index + 1;
    }

    const negative = offset < text.len and text[offset] == '-';

    if (negative) offset += 1;

    for (offset..text.len) |index| {
        if (!std.ascii.isDigit(text[index])) break;

        value = value * 10 + (text[index] - '0');
        offset = index + 1;
    }

    assert(offset <= text.len);

    return .{ .after = offset, .value = if (negative) -value else value };
}

fn root_present(root: []const u8) bool {
    const io = std.testing.io;

    assert(root.len > 0);
    assert(root[0] != '/' or root.len > 1);

    var directory = std.Io.Dir.cwd().openDir(io, root, .{}) catch return false;

    directory.close(io);

    return true;
}

test "the fixtures resolve what scope manager resolves" {
    const gpa = std.testing.allocator;

    if (!root_present(fixture_golden_root)) return;

    var carried = try oracle.residue_of(gpa, residue_name, &every_category);
    defer carried.deinit(gpa);

    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    var differing: std.ArrayList(u8) = .empty;
    defer differing.deinit(gpa);

    var differing_count: u32 = 0;
    var compared: u32 = 0;

    for (found.items) |fixture| {
        if (carried.contains(fixture.name)) continue;

        _ = arena_state.reset(.retain_capacity);

        const arena = arena_state.allocator();
        var expected: Golden = undefined;
        if (!try golden(arena, fixture_golden_root, fixture.name, &expected)) continue;

        try require(!expected.broken, "{s} has no golden to match", .{fixture.name});
        try require(machine.run(fixture) == .complete, "{s} does not parse", .{fixture.name});

        const held = try machine.rows(arena);
        const rows = try placed(arena, held.items, expected.rows.items);

        if (!rows_equal(rows.items, expected.rows.items)) {
            const entry = try report(arena, fixture.name, rows.items, expected.rows.items);

            try differing.appendSlice(gpa, entry);

            differing_count += 1;
        }

        compared += 1;
    }

    try require(
        compared >= floor.fixture_resolve_javascript,
        "the semantic fixtures lost a file: {d} compared, floor {d}",
        .{ compared, floor.fixture_resolve_javascript },
    );

    try require(
        differing_count == 0,
        "{d} of {d} fixtures differ\n{s}",
        .{ differing_count, compared, differing.items },
    );
}

test "the corpus resolves what scope manager resolves" {
    const gpa = std.testing.allocator;
    const held = corpus.named(.tsscope) orelse return;
    const root = corpus.named(.root) orelse return;
    var files = try corpus.collect(gpa, root, source_bytes_max, corpus_selected);
    defer files.deinit(gpa);

    if (files.slice().len == 0) return;

    var carried = try oracle.residue_of(gpa, residue_name, &every_category);
    defer carried.deinit(gpa);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const shared: CompareWorker.Shared = .{ .carried = &carried, .held = held };
    var counts = std.mem.zeroes(CompareWorker.Tally);

    assert(held.len > 0);
    assert(counts.differing == 0);

    try stripe.run(CompareWorker, gpa, &shared, files.slice(), &counts);

    try require(
        counts.compared >= floor.corpus_resolve_javascript,
        "the corpus lost its JavaScript files: {d} compared, floor {d}",
        .{ counts.compared, floor.corpus_resolve_javascript },
    );

    if (counts.differing == 0) return;

    const differing = try differing_entries(arena, gpa, &shared, files.slice());

    assert(differing.items.len == counts.differing);

    try differing_report(arena, differing.items, counts.compared);
}

test "every residue row names a file that diverges" {
    const gpa = std.testing.allocator;
    var carried = try oracle.residue_of(gpa, residue_name, &every_category);
    defer carried.deinit(gpa);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    var named: std.ArrayList([]const u8) = .empty;
    defer named.deinit(gpa);

    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    if (root_present(fixture_golden_root)) {
        const machine = try Machine.create(gpa);
        defer machine.destroy(gpa);

        for (found.items) |fixture| {
            if (!carried.contains(fixture.name)) continue;

            _ = arena_state.reset(.retain_capacity);

            const arena = arena_state.allocator();
            const diverged = try diverges(arena, machine, fixture_golden_root, fixture);

            try named.append(gpa, fixture.name);

            try require(diverged, "{s} matches its golden and needs no residue row", .{
                fixture.name,
            });
        }
    }

    const held = corpus.named(.tsscope) orelse return;
    const root = corpus.named(.root) orelse return;
    var files = try corpus.collect(gpa, root, source_bytes_max, corpus_selected);
    defer files.deinit(gpa);

    const shared: DivergeWorker.Shared = .{ .carried = &carried, .held = held };
    var counts = std.mem.zeroes(DivergeWorker.Tally);

    try stripe.run(DivergeWorker, gpa, &shared, files.slice(), &counts);
    try require(counts.matched == 0, "{d} residue files match their goldens", .{counts.matched});

    for (carried.fixtures.items) |row| {
        const message = "residue names `{s}`, which no fixture or corpus file carries";
        const carries = names_contain(named.items, row) or files_contain(files.slice(), row);

        try require(carries, message, .{row});
    }
}
