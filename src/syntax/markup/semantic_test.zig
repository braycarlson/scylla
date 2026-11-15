const std = @import("std");
const assert = std.debug.assert;
const Semantic = @import("semantic.zig").Semantic;
const Tokens = @import("tokens.zig").Tokens;
const Tree = @import("tree.zig").Tree;
const View = @import("view.zig").View;
const corpus = @import("../../testing/corpus.zig");
const environment = @import("../../testing/environment.zig");
const floor = @import("../../testing/floor.zig");
const lexer = @import("lex.zig");
const markup_testing = @import("../testing/markup.zig");
const semantic_module = @import("semantic.zig");
const stripe = @import("../../testing/stripe.zig");
const tree_module = @import("tree.zig");

const Row = struct {
    kind: []const u8,
    name: []const u8,
    offset: u32,

    fn less_than(context: void, left: Row, right: Row) bool {
        assert(@TypeOf(context) == void);
        assert(left.kind.len > 0);
        assert(right.kind.len > 0);

        switch (std.mem.order(u8, left.kind, right.kind)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }

        switch (std.mem.order(u8, left.name, right.name)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }

        return left.offset < right.offset;
    }

    fn equal(left: Row, right: Row) bool {
        assert(left.kind.len > 0);
        assert(right.kind.len > 0);

        if (left.offset != right.offset) return false;
        if (!std.mem.eql(u8, left.kind, right.kind)) return false;
        return std.mem.eql(u8, left.name, right.name);
    }
};

const Golden = struct {
    attributes: []const Row,
    broken: bool,
    definitions: []const Row,
    elements: []const Row,
    uses: []const Row,
};

const Names = struct {
    attributes: []const Row,
    elements: []const Row,
};

const Rows = struct {
    definitions: []const Row,
    uses: []const Row,
};

const Quoted = struct {
    text: []const u8,
    after: usize,
};

const Verdict = union(enum) {
    abstained,
    agreed,
    differing: []const u8,
};

const Machine = struct {
    semantic: Semantic,
    tokens: Tokens,
    tree: Tree,

    fn init(machine: *Machine, gpa: std.mem.Allocator) !void {
        try machine.semantic.init(gpa, .{
            .definition_count_max = definition_count_max,
            .use_count_max = use_count_max,
        });

        errdefer machine.semantic.deinit(gpa);

        machine.tokens = try .init(gpa, token_count_max);
        errdefer machine.tokens.deinit(gpa);

        machine.tree = try .init(gpa, node_count_max, diagnostic_count_max);

        assert(machine.tree.count() == 0);
    }

    fn deinit(machine: *Machine, gpa: std.mem.Allocator) void {
        assert(machine.tokens.capacity() == token_count_max);

        machine.tree.deinit(gpa);
        machine.tokens.deinit(gpa);
        machine.semantic.deinit(gpa);
        machine.* = undefined;
    }

    fn build(machine: *Machine, source: []const u8) bool {
        assert(source.len <= std.math.maxInt(u32));

        lexer.lex_with(source, &machine.tokens, &raw_text_tags) catch |err| switch (err) {
            error.Truncated => assert(machine.tokens.end_previous == source.len),
        };

        const tokens = machine.tokens.slice();
        if (tree_module.build(source, tokens, &machine.tree) != .complete) return false;
        return machine.semantic.build(source, tokens, &machine.tree) == .complete;
    }

    fn named(machine: *const Machine, arena: std.mem.Allocator, source: []const u8) !Names {
        assert(source.len <= std.math.maxInt(u32));

        var attributes: std.ArrayList(Row) = .empty;
        var elements: std.ArrayList(Row) = .empty;
        var steps = tree_module.walk(&machine.tree);

        for (0..steps.step_max) |_| {
            const step = steps.next() orelse break;

            const node = switch (step) {
                .enter => |held| held,
                .leave => continue,
            };

            const view: View = .init(&machine.tree, machine.tokens.slice(), @fromBackingInt(node));

            if (view.as_element()) |held| {
                const open = held.open_tag() orelse continue;

                if (open.token_first(.element_name)) |index| {
                    try elements.append(arena, try machine.row(arena, "element", source, index));
                }

                continue;
            }

            const held = view.as_attribute() orelse continue;
            const index = held.name_token() orelse continue;
            const tokens = machine.tokens.slice();
            if (semantic_module.attribute_repeated(&machine.tree, tokens, source, node)) continue;

            try attributes.append(arena, try machine.row(arena, "attribute", source, index));
        }

        std.mem.sort(Row, attributes.items, {}, Row.less_than);
        std.mem.sort(Row, elements.items, {}, Row.less_than);

        return .{ .attributes = attributes.items, .elements = elements.items };
    }

    fn row(
        machine: *const Machine,
        arena: std.mem.Allocator,
        kind: []const u8,
        source: []const u8,
        index: u32,
    ) !Row {
        assert(kind.len > 0);
        assert(index < machine.tokens.count());
        assert(source.len <= std.math.maxInt(u32));

        const token = machine.tokens.slice()[index];
        const name = try lossy(arena, token.text(source));

        return .{ .kind = kind, .name = name, .offset = token.offset };
    }

    fn rows(machine: *const Machine, arena: std.mem.Allocator, source: []const u8) !Rows {
        assert(source.len <= std.math.maxInt(u32));

        const held_definitions = machine.semantic.definition_slice();
        const held_uses = machine.semantic.use_slice();
        const definitions = try arena.alloc(Row, held_definitions.len);
        const uses = try arena.alloc(Row, held_uses.len);

        for (held_definitions, definitions) |held, *item| {
            item.* = .{
                .kind = "id",
                .name = try lossy(arena, held.name.text(source)),
                .offset = held.name.offset,
            };
        }

        for (held_uses, uses) |held, *item| {
            item.* = .{
                .kind = "id",
                .name = try lossy(arena, held.name.text(source)),
                .offset = held.name.offset,
            };
        }

        std.mem.sort(Row, definitions, {}, Row.less_than);
        std.mem.sort(Row, uses, {}, Row.less_than);

        return .{ .definitions = definitions, .uses = uses };
    }
};

const CompareWorker = struct {
    arena: std.heap.ArenaAllocator,
    machine: Machine,
    shared: *const Shared,

    pub const Item = corpus.File;

    pub const Shared = struct {
        carried: []const []const u8,
        golden_root: []const u8,
        residue: bool,
    };

    pub const Tally = struct {
        abstained: u32,
        agreeing: u32,
        compared: u32,
        differing: u32,
        rows: u64,
    };

    pub const weight = corpus.File.weight;

    pub fn init(worker: *CompareWorker, gpa: std.mem.Allocator, shared: *const Shared) !void {
        assert(shared.golden_root.len > 0);

        try worker.machine.init(gpa);

        worker.arena = .init(gpa);
        worker.shared = shared;
    }

    pub fn deinit(worker: *CompareWorker, gpa: std.mem.Allocator) void {
        assert(worker.shared.golden_root.len > 0);

        worker.arena.deinit();
        worker.machine.deinit(gpa);
        worker.* = undefined;
    }

    pub fn visit(worker: *CompareWorker, file: *const corpus.File, tally: *Tally) !void {
        assert(file.name.len > 0);
        assert(file.source.len <= std.math.maxInt(u32));

        const carried = names_contain(worker.shared.carried, file.name);
        if (carried != worker.shared.residue) return;
        defer _ = worker.arena.reset(.retain_capacity);

        switch (try worker.verdict_of(file, &tally.rows)) {
            .abstained => tally.abstained += 1,
            .agreed => {
                tally.compared += 1;

                if (worker.shared.residue) {
                    std.debug.print(
                        "{s} names what parse5 names and needs no residue row\n",
                        .{file.name},
                    );

                    tally.agreeing += 1;
                }
            },
            .differing => {
                tally.compared += 1;
                tally.differing += 1;
            },
        }
    }

    fn verdict_of(worker: *CompareWorker, file: *const corpus.File, rows: *u64) !Verdict {
        const arena = worker.arena.allocator();

        const recorded = golden(arena, worker.shared.golden_root, file.name) catch |err| {
            switch (err) {
                error.GoldenMissing => return .abstained,
                else => return err,
            }
        };

        assert(file.name.len > 0);

        if (recorded.broken) return .abstained;
        if (!worker.machine.build(file.source)) return .abstained;

        const names = try worker.machine.named(arena, file.source);
        const held = try worker.machine.rows(arena, file.source);

        rows.* += names.attributes.len + names.elements.len;
        rows.* += held.definitions.len + held.uses.len;

        const lines = try differing_of(arena, file.name, &names, &held, &recorded);
        if (lines.len == 0) return .agreed;
        return .{ .differing = lines };
    }
};

const InvariantsWorker = struct {
    machine: Machine,

    pub const Item = corpus.File;
    pub const Shared = struct {};
    pub const Tally = struct { compared: u32 };
    pub const weight = corpus.File.weight;

    pub fn init(worker: *InvariantsWorker, gpa: std.mem.Allocator, shared: *const Shared) !void {
        assert(@TypeOf(shared.*) == Shared);

        try worker.machine.init(gpa);

        assert(worker.machine.semantic.count() == 0);
    }

    pub fn deinit(worker: *InvariantsWorker, gpa: std.mem.Allocator) void {
        assert(worker.machine.tokens.capacity() == token_count_max);

        worker.machine.deinit(gpa);
        worker.* = undefined;
    }

    pub fn visit(worker: *InvariantsWorker, file: *const corpus.File, tally: *Tally) !void {
        assert(file.name.len > 0);
        assert(file.source.len <= std.math.maxInt(u32));

        if (!worker.machine.build(file.source)) return;

        try invariants_hold(&worker.machine, file.source, file.name);

        tally.compared += 1;
    }
};

const definition_count_max: u32 = 1 << 14;
const diagnostic_count_max: u32 = 1 << 10;
const golden_bytes_max: u32 = 1 << 28;
const node_count_max: u32 = 1 << 17;
const path_bytes_max: u32 = 4096;
const raw_text_tags = markup_testing.raw_text_tags;
const report_row_max: u32 = 4;
const report_shown_max: u32 = 3;
const residue_name = "residue-markup-semantic.json";
const source_bytes_max: u32 = 1 << 28;
const token_count_max: u32 = 1 << 18;
const use_count_max: u32 = 1 << 14;

fn lossy(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    assert(bytes.len <= std.math.maxInt(u32));

    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;

    const replaced = try arena.print("{f}", .{std.unicode.fmtUtf8(bytes)});

    assert(replaced.len > 0);

    return replaced;
}

fn quoted(
    arena: std.mem.Allocator,
    text: []const u8,
    from: usize,
) error{ OutOfMemory, Unquoted }!Quoted {
    assert(text.len <= std.math.maxInt(u32));
    assert(from < std.math.maxInt(u32));

    const open = std.mem.findScalarPos(u8, text, from, '"') orelse return error.Unquoted;
    var found: std.ArrayList(u8) = .empty;
    var offset = open + 1;

    for (0..text.len) |_| {
        if (offset >= text.len) return error.Unquoted;

        const byte = text[offset];

        offset += 1;

        if (byte == '"') return .{ .text = found.items, .after = offset };

        if (byte != '\\') {
            try found.append(arena, byte);

            continue;
        }

        if (offset >= text.len) return error.Unquoted;

        const held = text[offset];

        offset += 1;

        switch (held) {
            'n' => try found.append(arena, '\n'),
            'r' => try found.append(arena, '\r'),
            't' => try found.append(arena, '\t'),
            'u' => {
                const value = escape_value(text, offset) orelse return error.Unquoted;
                var buffer: [4]u8 = undefined;

                const encoded = std.unicode.utf8Encode(value, &buffer) catch
                    return error.Unquoted;

                offset += 4;

                try found.appendSlice(arena, buffer[0..encoded]);
            },
            else => try found.append(arena, held),
        }
    }

    return error.Unquoted;
}

fn escape_value(text: []const u8, offset: usize) ?u21 {
    assert(offset <= text.len);

    if (text.len - offset < 4) return null;

    var value: u21 = 0;

    for (text[offset .. offset + 4]) |digit| {
        const held = std.fmt.charToDigit(digit, 16) catch return null;

        value = value * 16 + held;
    }

    assert(value <= 0xFFFF);

    return value;
}

fn rows_of(arena: std.mem.Allocator, text: []const u8, key: []const u8) ![]const Row {
    assert(text.len <= std.math.maxInt(u32));
    assert(key.len <= std.math.maxInt(u32));

    const start = std.mem.find(u8, text, key) orelse return &.{};
    var found: std.ArrayList(Row) = .empty;
    var offset = start + key.len;

    for (0..text.len) |_| {
        if (offset >= text.len) break;
        if (text[offset] != '[') break;

        const kind = quoted(arena, text, offset) catch |err| switch (err) {
            error.Unquoted => break,
            error.OutOfMemory => return err,
        };

        const name = quoted(arena, text, kind.after) catch |err| switch (err) {
            error.Unquoted => break,
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

    std.mem.sort(Row, found.items, {}, Row.less_than);

    return found.items;
}

fn golden(arena: std.mem.Allocator, root: []const u8, name: []const u8) !Golden {
    assert(root.len > 0);
    assert(name.len > 0);

    var path_buffer: [path_bytes_max]u8 = undefined;
    const path = try std.mem.print(&path_buffer, "{s}/{s}.json", .{ root, name });
    const limit: std.Io.Limit = .limited(golden_bytes_max);

    const text = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena, limit) catch
        return error.GoldenMissing;

    return .{
        .attributes = try rows_of(arena, text, "\"attributes\":["),
        .broken = std.mem.find(u8, text, "\"broken\":true") != null,
        .definitions = try rows_of(arena, text, "\"definitions\":["),
        .elements = try rows_of(arena, text, "\"elements\":["),
        .uses = try rows_of(arena, text, "\"uses\":["),
    };
}

fn invariants_hold(machine: *const Machine, source: []const u8, name: []const u8) !void {
    assert(name.len > 0);
    assert(source.len <= std.math.maxInt(u32));

    try definitions_hold(machine, source, name);
    try uses_hold(machine, source, name);
    try uses_of_hold(machine, name);
}

fn definitions_hold(machine: *const Machine, source: []const u8, name: []const u8) !void {
    assert(source.len <= std.math.maxInt(u32));
    assert(name.len > 0);

    const source_length: u32 = @intCast(source.len);

    for (machine.semantic.definition_slice(), 0..) |definition, index| {
        const chained = if (definition.name_previous) |previous| previous < index else true;

        try check(
            definition.name.end() <= source_length,
            "{s}: definition {d} names bytes past the source",
            .{ name, index },
        );

        const named = definition.name.length > 0;

        try check(named, "{s}: definition {d} names nothing", .{ name, index });
        try check(chained, "{s}: definition {d} chains forward", .{ name, index });
    }
}

fn uses_hold(machine: *const Machine, source: []const u8, name: []const u8) !void {
    assert(source.len <= std.math.maxInt(u32));
    assert(name.len > 0);

    const source_length: u32 = @intCast(source.len);
    const definition_count = machine.semantic.definition_slice().len;

    for (machine.semantic.use_slice(), 0..) |held, index| {
        try check(
            held.name.end() <= source_length,
            "{s}: use {d} names bytes past the source",
            .{ name, index },
        );

        try check(held.name.length > 0, "{s}: use {d} names nothing", .{ name, index });

        const resolved = held.definition orelse {
            const absent = held.definition_count == 0;

            try check(absent, "{s}: use {d} counts an absent id", .{ name, index });

            continue;
        };

        const inside = resolved < definition_count;

        try check(inside, "{s}: use {d} resolves past the table", .{ name, index });

        const definition = machine.semantic.get(resolved) orelse return error.TestUnexpectedResult;
        const spelled = std.mem.eql(u8, definition.name.text(source), held.name.text(source));

        try check(
            definition.kind.reads(held.kind),
            "{s}: use {d} resolves to a definition that does not read it",
            .{ name, index },
        );

        try check(spelled, "{s}: use {d} resolves to a name spelled differently", .{ name, index });
    }
}

fn uses_of_hold(machine: *const Machine, name: []const u8) !void {
    const uses = machine.semantic.use_slice();

    assert(name.len > 0);

    for (0..machine.semantic.definition_slice().len) |position| {
        const index: u32 = @intCast(position);
        var found = machine.semantic.uses_of(index);

        for (0..uses.len + 1) |_| {
            const held = found.next() orelse break;
            const resolved = uses[held].definition == index;

            try check(
                resolved,
                "{s}: uses_of({d}) yields a use of something else",
                .{ name, index },
            );
        }
    }
}

fn check(condition: bool, comptime format: []const u8, arguments: anytype) !void {
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    if (condition) return;

    std.debug.print(format ++ "\n", arguments);

    return error.TestUnexpectedResult;
}

fn names_contain(names: []const []const u8, wanted: []const u8) bool {
    assert(wanted.len > 0);
    assert(names.len <= std.math.maxInt(u32));

    for (names) |name| {
        if (std.mem.eql(u8, name, wanted)) return true;
    }

    return false;
}

fn rows_contain(rows: []const Row, wanted: Row) bool {
    assert(wanted.kind.len > 0);
    assert(rows.len <= std.math.maxInt(u32));

    for (rows) |held| {
        if (Row.equal(held, wanted)) return true;
    }

    return false;
}

fn rows_equal(left: []const Row, right: []const Row) bool {
    if (left.len != right.len) return false;

    for (left, right) |held, wanted| {
        if (!Row.equal(held, wanted)) return false;
    }

    return true;
}

fn differing_of(
    arena: std.mem.Allocator,
    name: []const u8,
    names: *const Names,
    rows: *const Rows,
    wanted: *const Golden,
) ![]const u8 {
    var lines: std.ArrayList(u8) = .empty;

    assert(name.len > 0);

    if (!rows_equal(names.elements, wanted.elements)) {
        try report(arena, &lines, name, names.elements, wanted.elements, "elements");
    }

    if (!rows_equal(names.attributes, wanted.attributes)) {
        try report(arena, &lines, name, names.attributes, wanted.attributes, "attributes");
    }

    if (!rows_equal(rows.definitions, wanted.definitions)) {
        try report(arena, &lines, name, rows.definitions, wanted.definitions, "definitions");
    }

    if (!rows_equal(rows.uses, wanted.uses)) {
        try report(arena, &lines, name, rows.uses, wanted.uses, "uses");
    }

    return lines.items;
}

fn report(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(u8),
    name: []const u8,
    held: []const Row,
    wanted: []const Row,
    label: []const u8,
) !void {
    assert(name.len > 0);
    assert(label.len > 0);
    assert(held.len <= std.math.maxInt(u32));
    assert(wanted.len <= std.math.maxInt(u32));

    try lines.print(arena, "=== {s} {s}\n", .{ name, label });
    try report_missing(arena, lines, "scylla", held, wanted);
    try report_missing(arena, lines, "parse5", wanted, held);
}

fn report_missing(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(u8),
    side: []const u8,
    held: []const Row,
    wanted: []const Row,
) !void {
    assert(side.len > 0);
    assert(held.len <= std.math.maxInt(u32));
    assert(wanted.len <= std.math.maxInt(u32));

    var shown: u32 = 0;

    for (held) |row| {
        if (shown == report_row_max) break;
        if (rows_contain(wanted, row)) continue;

        try lines.print(arena, "  {s} {s} {s} {d}\n", .{ side, row.kind, row.name, row.offset });
        shown += 1;
    }

    assert(shown <= report_row_max);
}

fn corpus_files(gpa: std.mem.Allocator) !corpus.Files {
    const root = corpus.named(.root) orelse return .{ .list = .empty };
    const files = try corpus.collect(gpa, root, source_bytes_max, markup_testing.template_selected);

    assert(files.slice().len <= std.math.maxInt(u32));

    return files;
}

fn differing_entries(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    shared: *const CompareWorker.Shared,
    files: []const corpus.File,
) !std.ArrayList([]const u8) {
    assert(files.len <= std.math.maxInt(u32));

    var entries: std.ArrayList([]const u8) = .empty;
    var rows: u64 = 0;
    var worker: CompareWorker = undefined;

    assert(!shared.residue);

    try worker.init(gpa, shared);
    defer worker.deinit(gpa);

    for (files) |*file| {
        if (names_contain(shared.carried, file.name)) continue;

        switch (try worker.verdict_of(file, &rows)) {
            .abstained, .agreed => {},
            .differing => |entry| try entries.append(arena, try arena.dupe(u8, entry)),
        }
    }

    assert(entries.items.len <= files.len);

    return entries;
}

fn differing_report(arena: std.mem.Allocator, differing: []const []const u8) !void {
    assert(differing.len <= std.math.maxInt(u32));

    if (differing.len == 0) return;

    const joined = try std.mem.concat(arena, u8, differing);
    var path_bytes: [environment.value_bytes_max]u8 = undefined;

    if (environment.get("SCYLLA_REPORT", &path_bytes)) |path| {
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = joined });
    }

    const shown_end = @min(differing.len, report_shown_max);
    const shown = try std.mem.concat(arena, u8, differing[0..shown_end]);

    assert(shown.len <= joined.len);

    std.debug.print("{d} files name something else\n{s}", .{ differing.len, shown });

    return error.TestUnexpectedResult;
}

test "an id reaches every attribute that names it" {
    const gpa = std.testing.allocator;
    const source = "<div id=\"main\"><a href=\"#main\">go</a><label for=\"main\">l</label></div>";
    var machine: Machine = undefined;

    try machine.init(gpa);
    defer machine.deinit(gpa);

    try std.testing.expect(machine.build(source));
    try std.testing.expectEqual(1, machine.semantic.definition_slice().len);
    try std.testing.expectEqual(2, machine.semantic.use_slice().len);

    for (machine.semantic.use_slice()) |held| {
        try std.testing.expectEqual(0, held.definition);
        try std.testing.expectEqual(1, held.definition_count);
    }

    try invariants_hold(&machine, source, "an id and its references");
}

test "a templated value names nothing" {
    const gpa = std.testing.allocator;
    const source = "<div id=\"{{ slug }}\"><a href=\"#{{ slug }}\">go</a></div>";
    var machine: Machine = undefined;

    try machine.init(gpa);
    defer machine.deinit(gpa);

    try std.testing.expect(machine.build(source));
    try std.testing.expectEqual(0, machine.semantic.definition_slice().len);
    try std.testing.expectEqual(0, machine.semantic.use_slice().len);
}

test "a listed relation names each id it holds" {
    const gpa = std.testing.allocator;
    const source = "<i id=\"a\"></i><i id=\"b\"></i><p aria-labelledby=\"a b missing\">x</p>";
    var machine: Machine = undefined;

    try machine.init(gpa);
    defer machine.deinit(gpa);

    try std.testing.expect(machine.build(source));
    try std.testing.expectEqual(3, machine.semantic.use_slice().len);

    var unresolved: u32 = 0;

    for (machine.semantic.use_slice()) |held| {
        if (held.definition == null) unresolved += 1;
    }

    try std.testing.expectEqual(1, unresolved);
    try invariants_hold(&machine, source, "a listed relation");
}

test "the corpus names what parse5 names" {
    const gpa = std.testing.allocator;
    const held = corpus.named(.markup) orelse return;
    var files = try corpus_files(gpa);
    defer files.deinit(gpa);

    if (files.slice().len == 0) return;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const carried = try markup_testing.residue_read(arena, residue_name);

    const shared: CompareWorker.Shared = .{
        .carried = carried.items,
        .golden_root = held,
        .residue = false,
    };

    var tally: CompareWorker.Tally = .{
        .abstained = 0,
        .agreeing = 0,
        .compared = 0,
        .differing = 0,
        .rows = 0,
    };

    try stripe.run(CompareWorker, gpa, &shared, files.slice(), &tally);

    const named_count = tally.compared + carried.items.len;

    if (named_count < floor.corpus_parse5_markup.files) {
        std.debug.print(
            "the corpus lost its markup files: {d} named, {d} abstained, floor {d}\n",
            .{ named_count, tally.abstained, floor.corpus_parse5_markup.files },
        );
    }

    try std.testing.expect(named_count >= floor.corpus_parse5_markup.files);

    if (tally.rows < floor.corpus_parse5_markup.rows) {
        std.debug.print(
            "{d} names compared, floor {d}\n",
            .{ tally.rows, floor.corpus_parse5_markup.rows },
        );
    }

    try std.testing.expect(tally.rows >= floor.corpus_parse5_markup.rows);

    if (tally.differing == 0) return;

    const differing = try differing_entries(arena, gpa, &shared, files.slice());

    try std.testing.expectEqual(tally.differing, differing.items.len);
    try differing_report(arena, differing.items);
}

test "every corpus file holds the table invariants" {
    const gpa = std.testing.allocator;
    var files = try corpus_files(gpa);
    defer files.deinit(gpa);

    if (files.slice().len == 0) return;

    var tally: InvariantsWorker.Tally = .{ .compared = 0 };

    try stripe.run(InvariantsWorker, gpa, &.{}, files.slice(), &tally);

    if (tally.compared < floor.corpus_markup_tree) {
        std.debug.print(
            "{d} markup files held the invariants, floor {d}\n",
            .{ tally.compared, floor.corpus_markup_tree },
        );
    }

    try std.testing.expect(tally.compared >= floor.corpus_markup_tree);
}

test "every residue row names a file that diverges" {
    const gpa = std.testing.allocator;
    const held = corpus.named(.markup) orelse return;
    var files = try corpus_files(gpa);
    defer files.deinit(gpa);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const carried = try markup_testing.residue_read(arena, residue_name);

    const shared: CompareWorker.Shared = .{
        .carried = carried.items,
        .golden_root = held,
        .residue = true,
    };

    var tally: CompareWorker.Tally = .{
        .abstained = 0,
        .agreeing = 0,
        .compared = 0,
        .differing = 0,
        .rows = 0,
    };

    try stripe.run(CompareWorker, gpa, &shared, files.slice(), &tally);
    try std.testing.expectEqual(0, tally.agreeing);

    for (carried.items) |name| {
        var found = false;

        for (files.slice()) |file| {
            if (std.mem.eql(u8, file.name, name)) found = true;
        }

        if (!found) {
            std.debug.print("the residue names `{s}` and the corpus does not carry it\n", .{name});
        }

        try std.testing.expect(found);
    }
}
