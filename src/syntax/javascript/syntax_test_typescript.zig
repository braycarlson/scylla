const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const EventsType = @import("../tree.zig").EventsType;
const Kind = @import("kind.zig").Kind;
const Dialect = @import("dialect.zig").Dialect;
const Goal = @import("dialect.zig").Goal;
const Parser = @import("parse.zig").Parser;
const Random = @import("../../testing/random.zig");
const Structure = @import("../tree.zig").Structure;
const Token = @import("../token.zig");
const Tokens = @import("../tokens.zig");
const TreeType = @import("../tree.zig").TreeType;
const raw_of = @import("../raw.zig").raw_of;
const relex = @import("relex.zig");
const corpus = @import("../../testing/corpus.zig");
const environment = @import("../../testing/environment.zig");
const floor = @import("../../testing/floor.zig");
const lex = @import("lex.zig").lex;
const oracle = @import("../../testing/oracle.zig");
const oracle_names = @import("../testing/names.zig");
const stripe = @import("../../testing/stripe.zig");
const tally = @import("../../testing/tally.zig");
const trivia = @import("../trivia.zig");
const Events = EventsType(Kind);
const Node = Tree.Node;
const Row = oracle.Row;
const Tree = TreeType(Kind);

const Machine = struct {
    events: Events,
    expected: std.ArrayList(Row),
    held: std.ArrayList(Row),
    parser: Parser,
    raw: ArrayType(Kind),
    tokens: Tokens,
    tree: Tree,

    fn create(gpa: std.mem.Allocator) !*Machine {
        const machine = try gpa.create(Machine);
        errdefer gpa.destroy(machine);

        try machine.events.init(gpa, event_count_max);
        errdefer machine.events.deinit(gpa);

        machine.raw = try .init(gpa, raw_count_max);
        errdefer machine.raw.deinit(gpa);

        machine.tokens = try .init(gpa, token_count_max);
        errdefer machine.tokens.deinit(gpa);

        machine.tree = try .init(gpa, node_count_max, diagnostic_count_max);
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
        machine.tree.deinit(gpa);
        machine.tokens.deinit(gpa);
        machine.raw.deinit(gpa);
        machine.events.deinit(gpa);
        gpa.destroy(machine);
    }

    fn complete(machine: *Machine, source: []const u8, dialect: Dialect) bool {
        assert(source.len <= std.math.maxInt(u32));
        assert(dialect.typed());

        machine.tokens.clear();

        lex(source, &machine.tokens, dialect) catch |err| switch (err) {
            error.Truncated => return false,
        };

        assert(!machine.tokens.items.full() or machine.tokens.count() > 0);

        return true;
    }

    fn run(machine: *Machine, source: []const u8, dialect: Dialect) bool {
        assert(source.len <= std.math.maxInt(u32));

        machine.tokens.clear();

        lex(source, &machine.tokens, dialect) catch |err| switch (err) {
            error.Truncated => assert(machine.tokens.items.full()),
        };

        raw_of(Kind, machine.tokens.slice(), &machine.raw) catch |err| switch (err) {
            error.Truncated => return false,
        };

        assert(machine.raw.count() == machine.tokens.count());

        return true;
    }

    fn parse(machine: *Machine, source: []const u8, dialect: Dialect) !Structure {
        assert(source.len <= std.math.maxInt(u32));
        assert(dialect.typed());

        return machine.parse_goal(source, dialect, .module);
    }

    fn parse_goal(machine: *Machine, source: []const u8, dialect: Dialect, goal: Goal) !Structure {
        assert(source.len <= std.math.maxInt(u32));

        try require(machine.run(source, dialect), "the source overran its tokens", .{});

        assert(machine.raw.count() == machine.tokens.count());
        assert(machine.events.count() <= event_count_max);

        if (machine.tokens.items.full()) {
            return machine.parser.build(
                source,
                machine.tokens.slice(),
                machine.raw.const_slice(),
                &machine.events,
                &machine.tree,
                .{ .dialect = dialect, .goal = goal },
            );
        }

        return relex.build(
            &machine.parser,
            source,
            .{ .raw = &machine.raw, .tokens = &machine.tokens },
            &machine.events,
            &machine.tree,
            .{ .dialect = dialect, .goal = goal },
        );
    }

    fn walk(machine: *Machine, gpa: std.mem.Allocator, length: u32) !void {
        const tokens = machine.tokens.slice();

        assert(tokens.len == machine.raw.count());
        if (tokens.len > 0) assert(tokens[tokens.len - 1].end() <= length);

        machine.held.clearRetainingCapacity();

        if (machine.tree.count() == 0) return;

        for (machine.tree.slice()) |node| {
            if (std.mem.findScalar(Kind, &skipped, node.kind) != null) continue;

            const span = node.span(Token, tokens);
            const name = oracle_names.name_of(Kind, node.kind);

            if (node.kind == .program) {
                try machine.held.append(gpa, .{
                    .name = name,
                    .offset = span.offset,
                    .end = length,
                });

                continue;
            }

            try machine.held.append(gpa, .{
                .name = name,
                .offset = span.offset,
                .end = span.end(),
            });
        }

        std.mem.sort(Row, machine.held.items, {}, Row.less_than);
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

        assert(std.mem.findScalar(Kind, &kinds, .program) == null);

        return found;
    }

    fn walk_matches(
        machine: *Machine,
        gpa: std.mem.Allocator,
        source: []const u8,
        rows: []const Row,
    ) !bool {
        assert(source.len <= std.math.maxInt(u32));
        assert(rows.len <= std.math.maxInt(u32));

        const length: u32 = @intCast(source.len);

        try machine.walk(gpa, length);
        try wanted(gpa, source, rows, &machine.expected);

        assert(machine.held.items.len <= machine.tree.count());
        assert(machine.expected.items.len <= rows.len);

        return rows_equal(machine.held.items, machine.expected.items);
    }
};

const Census = [statements.len]u32;

const Check = enum {
    census,
    classify,
    invariants,
    walk,
};

const CorpusShared = struct {
    carried: *const oracle.Residue,
    golden: ?[]const u8,
};

const CorpusTally = struct {
    abstained: u32,
    compared: u32,
    differing: u32,
};

const Differing = struct {
    count: u32,
    shown_end: usize,
    text: std.ArrayList(u8),

    fn noted(differing: *Differing) void {
        differing.count += 1;

        if (differing.count <= report_shown_max) differing.shown_end = differing.text.items.len;

        assert(differing.count > 0);
        assert(differing.shown_end <= differing.text.items.len);
    }
};

const Fixture = corpus.File;

const Outcome = enum {
    abstained,
    compared,
};

const Range = struct {
    offset: u32,
    end: u32,
};

const Walked = enum {
    abstained,
    differs,
    matches,
};

const alphabet = "abc_09 \t\n\r()[]{}:,.=+-*/%<>!&|^~@;'\"\\#?$`newclassfunctionrtu" ++
    "\x00\xff\xc3\xa9";

const diagnostic_count_max: u32 = 0x0000_0400;
const event_count_max: u32 = 0x0060_0000;
const every_category = [_][]const u8{ "grammar", "not-typescript", "shape", "tsx" };
const file_count_max: u32 = 1 << 20;
const fixture_root = "tests/fixtures/typescript";
const golden_root_ts = "tests/fixtures/golden-typescript";
const golden_root_tsx = "tests/fixtures/golden-typescript-tsx";
const node_count_max: u32 = 0x0020_0000;
const none: u32 = std.math.maxInt(u32);
const not_typescript = [_][]const u8{ "not-typescript", "tsx" };
const raw_count_max: u32 = 0x0020_0000;
const report_lines_max: u32 = 24;
const report_shown_max: u32 = 3;
const residue_name = "residue-typescript.json";
const skipped = [_]Kind{.error_node};
const soup_bytes_max: u32 = 512;
const soup_round_count: u32 = 512;
const source_bytes_max: u32 = 1 << 24;
const suite = "syntax_typescript";
const token_count_max: u32 = 0x0020_0000;

const statements = [_][]const u8{
    "abstract_class_declaration",
    "ambient_declaration",
    "break_statement",
    "class_declaration",
    "continue_statement",
    "debugger_statement",
    "do_statement",
    "empty_statement",
    "enum_declaration",
    "export_statement",
    "expression_statement",
    "for_in_statement",
    "for_statement",
    "function_declaration",
    "function_signature",
    "generator_function_declaration",
    "if_statement",
    "import_alias",
    "import_statement",
    "interface_declaration",
    "internal_module",
    "labeled_statement",
    "lexical_declaration",
    "module",
    "return_statement",
    "statement_block",
    "switch_statement",
    "throw_statement",
    "try_statement",
    "type_alias_declaration",
    "variable_declaration",
    "while_statement",
    "with_statement",
};

const unrepresented = [_][]const u8{
    "comment",
    "escape_sequence",
    "hash_bang_line",
    "html_character_reference",
    "html_comment",
    "regex_flags",
    "regex_pattern",
    "string_fragment",
};

fn golden_root(dialect: Dialect) []const u8 {
    assert(dialect.typed());

    const root = switch (dialect) {
        .javascript => unreachable,
        .typescript => golden_root_ts,
        .tsx => golden_root_tsx,
    };

    assert(root.len > 0);
    assert(std.mem.startsWith(u8, root, "tests/fixtures/golden-typescript"));

    return root;
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

    return dialect_of(basename) != null;
}

fn fixtures(gpa: std.mem.Allocator) !corpus.Files {
    const found = try corpus.collect(gpa, fixture_root, source_bytes_max, corpus_selected);

    assert(found.slice().len <= file_count_max);
    if (found.slice().len > 1) assert(Fixture.less_than({}, found.slice()[0], found.slice()[1]));

    return found;
}

fn dialect_of(basename: []const u8) ?Dialect {
    assert(basename.len > 0);

    const extension = std.Io.Dir.path.extension(basename);

    if (extension.len == 0) return null;

    assert(extension[0] == '.');

    const held = Dialect.of_extension(extension[1..]) orelse return null;
    if (!held.typed()) return null;
    return held;
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
            trivia.gap_is_blank(source, gap.span, null),
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
    assert(name.len <= std.math.maxInt(u32));

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
            const machine = worker.machine;

            assert(fixture.name.len > 0);
            assert(counted.differing <= counted.compared);

            if (worker.shared.carried.contains(fixture.name)) return;
            if (!machine.complete(fixture.source, dialect_of(fixture.name).?)) return;

            switch (check) {
                .census => {
                    const root = worker.shared.golden.?;

                    switch (try census_against_corpus(worker.gpa, machine, root, fixture)) {
                        .abstained => counted.abstained += 1,
                        .compared => counted.compared += 1,
                    }
                },
                .classify => {
                    try require(
                        machine.run(fixture.source, dialect_of(fixture.name).?),
                        "{s} overran",
                        .{fixture.name},
                    );

                    for (machine.raw.const_slice(), 0..) |kind, position| {
                        try require(
                            kind != .error_token,
                            "{s} classifies token {d} to an ErrorToken",
                            .{ fixture.name, position },
                        );
                    }

                    try gaps_are_blank(fixture.source, machine.tokens.slice(), fixture.name);
                    try tally.agree(suite, "classify", fixture.name);
                    counted.compared += 1;
                },
                .invariants => {
                    _ = try machine.parse(fixture.source, dialect_of(fixture.name).?);

                    try invariants_hold(machine, fixture.name);
                    try tally.agree(suite, "invariants", fixture.name);
                },
                .walk => {
                    const root = worker.shared.golden.?;

                    switch (try walk_against_corpus(worker.gpa, machine, root, fixture, null)) {
                        .abstained => counted.abstained += 1,
                        .differs => {
                            counted.compared += 1;
                            counted.differing += 1;
                        },
                        .matches => {
                            try tally.agree(suite, "walk", fixture.name);
                            counted.compared += 1;
                        },
                    }
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
    var counted: CorpusTally = .{ .abstained = 0, .compared = 0, .differing = 0 };

    assert(found.len > 0);
    assert(found.len <= file_count_max);

    try stripe.run(CorpusWorkerType(check), gpa, &shared, found, &counted);

    assert(counted.differing <= counted.compared);
    assert(counted.abstained + counted.compared <= found.len);

    return counted;
}

fn walk_reported(
    gpa: std.mem.Allocator,
    carried: *const oracle.Residue,
    root: []const u8,
    found: []const Fixture,
    counted: *const CorpusTally,
) !void {
    assert(root.len > 0);
    assert(counted.differing <= counted.compared);
    assert(found.len <= std.math.maxInt(u32));

    if (counted.differing == 0) return;

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    var differing: Differing = .{ .count = 0, .shown_end = 0, .text = .empty };
    defer differing.text.deinit(gpa);

    for (found) |*fixture| {
        if (carried.contains(fixture.name)) continue;
        if (!machine.complete(fixture.source, dialect_of(fixture.name).?)) continue;

        _ = try walk_against_corpus(gpa, machine, root, fixture, &differing);
    }

    assert(differing.count == counted.differing);

    try differing_fail(&differing, counted.compared);
}

fn diverges(
    gpa: std.mem.Allocator,
    machine: *Machine,
    root: []const u8,
    fixture: *const Fixture,
) !bool {
    var golden: oracle.Golden = undefined;
    if (!try oracle.golden(gpa, root, fixture.name, &golden)) return true;
    defer golden.deinit(gpa);

    assert(root.len > 0);
    assert(fixture.name.len > 0);

    if (golden.broken) return true;
    if (!machine.run(fixture.source, dialect_of(fixture.name).?)) return true;
    if (std.mem.findScalar(Kind, machine.raw.const_slice(), .error_token) != null) return true;

    _ = try machine.parse(fixture.source, dialect_of(fixture.name).?);

    const matches = try machine.walk_matches(gpa, fixture.source, golden.ast.items);
    return !matches;
}

fn census_against_corpus(
    gpa: std.mem.Allocator,
    machine: *Machine,
    root: []const u8,
    fixture: *const Fixture,
) !Outcome {
    assert(root.len <= std.math.maxInt(u32));

    var golden: oracle.Golden = undefined;
    if (!try oracle.golden(gpa, root, fixture.name, &golden)) return .abstained;
    defer golden.deinit(gpa);

    assert(root.len > 0);

    assert(fixture.name.len > 0);

    if (golden.broken) return .abstained;

    _ = try machine.parse(fixture.source, dialect_of(fixture.name).?);

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

    var golden: oracle.Golden = undefined;
    if (!try oracle.golden(gpa, root, fixture.name, &golden)) return .abstained;
    defer golden.deinit(gpa);

    assert(root.len > 0);

    assert(fixture.name.len > 0);

    if (golden.broken) return .abstained;

    _ = try machine.parse(fixture.source, dialect_of(fixture.name).?);

    if (try machine.walk_matches(gpa, fixture.source, golden.ast.items)) return .matches;

    if (differing) |held| {
        try report(gpa, &held.text, fixture.name, machine.held.items, machine.expected.items);
        held.noted();
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

fn differing_fail(differing: *const Differing, compared: u32) !void {
    assert(differing.count <= compared);
    assert(differing.shown_end <= differing.text.items.len);

    if (differing.count == 0) return;

    var path_bytes: [environment.value_bytes_max]u8 = undefined;

    if (environment.get("SCYLLA_REPORT", &path_bytes)) |path| {
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{
            .sub_path = path,
            .data = differing.text.items,
        });
    }

    std.debug.print("{d} of {d} corpus files differ\n{s}", .{
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
    golden: *oracle.Golden,
) !void {
    assert(root.len > 0);
    assert(name.len > 0);

    const found = try oracle.golden(gpa, root, name, golden);

    try require(found, "{s} has no golden", .{name});
}

fn wanted(
    gpa: std.mem.Allocator,
    source: []const u8,
    rows: []const Row,
    found: *std.ArrayList(Row),
) !void {
    assert(source.len <= std.math.maxInt(u32));
    assert(rows.len <= std.math.maxInt(u32));

    const length: u32 = @intCast(source.len);
    var comments: std.ArrayList(Range) = .empty;
    defer comments.deinit(gpa);

    try comments_of(gpa, rows, &comments);
    found.clearRetainingCapacity();

    for (rows) |row| {
        if (names_contain(&unrepresented, row.name)) continue;

        if (std.mem.eql(u8, row.name, "program")) {
            try found.append(gpa, .{ .name = row.name, .offset = row.offset, .end = length });

            continue;
        }

        try found.append(gpa, .{
            .name = row.name,
            .offset = row.offset,
            .end = trimmed(source, comments.items, row.offset, row.end),
        });
    }

    std.mem.sort(Row, found.items, {}, Row.less_than);

    assert(found.items.len <= rows.len);
    assert(found.capacity >= found.items.len);
}

fn comments_of(gpa: std.mem.Allocator, rows: []const Row, comments: *std.ArrayList(Range)) !void {
    assert(comments.items.len == 0);
    assert(rows.len <= std.math.maxInt(u32));

    for (rows) |row| {
        if (!is_comment(row.name)) continue;

        try comments.append(gpa, .{ .offset = row.offset, .end = row.end });
    }

    assert(comments.items.len <= rows.len);
}

fn trimmed(source: []const u8, comments: []const Range, offset: u32, end: u32) u32 {
    assert(offset < none);
    assert(end <= source.len);

    var held = end;
    var cut = false;

    assert(comments.len <= std.math.maxInt(u32));

    for (0..comments.len + 1) |_| {
        const back = blank_trimmed(source, offset, held);
        const comment = comment_ending(comments, offset, back) orelse break;

        cut = true;
        held = comment.offset;
    }

    if (!cut) return held;

    held = blank_trimmed(source, offset, held);

    assert(held <= end);

    return held;
}

fn blank_trimmed(source: []const u8, offset: u32, end: u32) u32 {
    assert(offset < none);
    assert(end <= source.len);

    var held = end;

    for (0..end -| offset) |_| {
        if (held <= offset) break;
        if (!std.ascii.isWhitespace(source[held - 1])) break;

        held -= 1;
    }

    assert(held <= end);

    return held;
}

fn comment_ending(comments: []const Range, offset: u32, back: u32) ?Range {
    assert(comments.len <= std.math.maxInt(u32));
    assert(offset <= std.math.maxInt(u32));

    for (comments) |comment| {
        if (comment.end != back) continue;
        if (comment.offset <= offset) continue;
        return comment;
    }

    return null;
}

fn is_comment(name: []const u8) bool {
    assert(name.len > 0);
    assert(name.len < std.math.maxInt(u32));

    return std.mem.eql(u8, name, "comment");
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
    assert(name.len <= std.math.maxInt(u32));

    for (statements, 0..) |statement, index| {
        if (std.mem.eql(u8, statement, name)) return index;
    }

    return null;
}

fn rows_equal(held: []const Row, expected: []const Row) bool {
    if (held.len != expected.len) return false;

    for (held, expected) |left, right| {
        if (left.order(right) != .eq) return false;
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
    var shown: u32 = 0;
    var mine: usize = 0;
    var theirs: usize = 0;

    assert(name.len > 0);
    assert(!rows_equal(held, expected));

    try lines.print(gpa, "{s}: the walks differ\n", .{name});

    for (0..held.len + expected.len) |_| {
        const drained = mine >= held.len and theirs >= expected.len;

        if (shown >= report_lines_max) break;
        if (drained) break;

        const extra = theirs >= expected.len or
            (mine < held.len and held[mine].order(expected[theirs]) == .lt);

        if (extra) {
            try report_row(gpa, lines, "extra  ", held[mine]);
            mine += 1;
            shown += 1;

            continue;
        }

        const missing = mine >= held.len or expected[theirs].order(held[mine]) == .lt;

        if (missing) {
            try report_row(gpa, lines, "missing", expected[theirs]);
            theirs += 1;
            shown += 1;

            continue;
        }

        mine += 1;
        theirs += 1;
    }
}

fn report_row(
    gpa: std.mem.Allocator,
    lines: *std.ArrayList(u8),
    label: []const u8,
    row: Row,
) !void {
    assert(row.offset <= row.end);

    const lines_before = lines.items.len;

    assert(label.len == "missing".len);

    try lines.print(gpa, "  {s} {s} {d} {d}\n", .{ label, row.name, row.offset, row.end });

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

fn walk_contains(rows: []const Row, wanted_row: Row) bool {
    assert(wanted_row.name.len > 0);
    assert(wanted_row.offset <= wanted_row.end);
    assert(rows.len <= std.math.maxInt(u32));

    for (rows) |row| {
        if (row.order(wanted_row) == .eq) return true;
    }

    return false;
}

fn walk_names(rows: []const Row, name: []const u8) bool {
    assert(name.len > 0);
    assert(rows.len <= node_count_max);

    for (rows) |row| {
        if (std.mem.eql(u8, row.name, name)) return true;
    }

    return false;
}

fn require(condition: bool, comptime format: []const u8, arguments: anytype) !void {
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    if (condition) return;

    std.debug.print(format ++ "\n", arguments);

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
        try require(
            machine.run(fixture.source, dialect_of(fixture.name).?),
            "{s} overran",
            .{fixture.name},
        );

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
        _ = machine.run(fixture.source, dialect_of(fixture.name).?);

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

        try require(machine.run(source, .typescript), "round {d} overran", .{round});
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

        _ = try machine.parse(source, .typescript);

        try invariants_hold(machine, "byte soup");

        const first = try gpa.dupe(Node, machine.tree.slice());
        defer gpa.free(first);

        _ = try machine.parse(source, .typescript);
        errdefer std.debug.print("round {d} parses differently the second time\n", .{round});

        try std.testing.expectEqualSlices(Node, first, machine.tree.slice());
    }
}

test "classify runs the corpus without an unclaimed byte" {
    const gpa = std.testing.allocator;
    var found = try corpus_fixtures(gpa);
    defer found.deinit(gpa);

    if (found.slice().len == 0) return;

    var carried = try oracle.residue_of(gpa, residue_name, &not_typescript);
    defer carried.deinit(gpa);

    const counted = try corpus_checked(.classify, gpa, &carried, null, found.slice());

    try require(
        counted.compared >= floor.corpus_classify_typescript,
        "the corpus lost its TypeScript files: {d} classified, floor {d}",
        .{ counted.compared, floor.corpus_classify_typescript },
    );
}

test "the tree holds its invariants over the corpus" {
    const gpa = std.testing.allocator;
    var found = try corpus_fixtures(gpa);
    defer found.deinit(gpa);

    if (found.slice().len == 0) return;

    var carried = try oracle.residue_of(gpa, residue_name, &not_typescript);
    defer carried.deinit(gpa);

    _ = try corpus_checked(.invariants, gpa, &carried, null, found.slice());
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
        var golden: oracle.Golden = undefined;

        try golden_held(gpa, golden_root(dialect_of(fixture.name).?), fixture.name, &golden);
        defer golden.deinit(gpa);

        try require(!golden.broken, "{s} does not parse", .{fixture.name});

        const outcome = try machine.parse(fixture.source, dialect_of(fixture.name).?);

        try require(outcome == .complete, "{s}", .{fixture.name});
        try census_matches(machine, golden.ast.items, fixture.name);

        compared += 1;
    }

    try require(compared == found.slice().len, "a fixture went uncompared", .{});
}

test "an import attribute follows the module string" {
    const gpa = std.testing.allocator;
    const source = "import held from \"./held.json\" with { type: \"json\" };\n";
    const length: u32 = @intCast(source.len);
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    try std.testing.expectEqual(Structure.complete, try machine.parse(source, .typescript));
    try machine.walk(gpa, length);

    const attribute: Row = .{ .name = "import_attribute", .offset = 31, .end = 52 };

    try require(walk_contains(machine.held.items, attribute), "{any}", .{machine.held.items});
}

test "a stray error token at the top level does not end the program" {
    const gpa = std.testing.allocator;
    const source = "\\;\nfunction walk(n: number) {\n    walk(n);\n}\n";
    const length: u32 = @intCast(source.len);
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    _ = try machine.parse(source, .typescript);

    try machine.walk(gpa, length);

    const walked = machine.held.items;

    try require(walk_names(walked, "function_declaration"), "{any}", .{walked});
}

test "a with statement after a module string stays a statement" {
    const gpa = std.testing.allocator;
    const source = "import held from \"./held\"\nwith (held) {}\n";
    const length: u32 = @intCast(source.len);
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    try std.testing.expectEqual(Structure.complete, try machine.parse(source, .typescript));
    try machine.walk(gpa, length);

    const walked = machine.held.items;

    try require(walk_names(walked, "with_statement"), "{any}", .{walked});
    try require(!walk_names(walked, "import_attribute"), "{any}", .{walked});
}

test "a decorator ends where the computed member name it decorates begins" {
    const gpa = std.testing.allocator;

    const source = "class A {\n" ++
        "    @dec()[key]() {}\n" ++
        "    @a.b[key] = 1;\n" ++
        "    @(x[0]) m() {}\n" ++
        "}\n";

    const length: u32 = @intCast(source.len);
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    try std.testing.expectEqual(Structure.complete, try machine.parse(source, .typescript));
    try machine.walk(gpa, length);

    const walked = machine.held.items;
    const called: Row = .{ .name = "decorator", .offset = 14, .end = 20 };
    const computed: Row = .{ .name = "computed_property_name", .offset = 20, .end = 25 };
    const dotted: Row = .{ .name = "decorator", .offset = 35, .end = 39 };
    const field: Row = .{ .name = "computed_property_name", .offset = 39, .end = 44 };
    const grouped: Row = .{ .name = "decorator", .offset = 54, .end = 61 };
    const subscript: Row = .{ .name = "subscript_expression", .offset = 56, .end = 60 };

    try require(walk_contains(walked, called), "{any}", .{walked});
    try require(walk_contains(walked, computed), "{any}", .{walked});
    try require(walk_contains(walked, dotted), "{any}", .{walked});
    try require(walk_contains(walked, field), "{any}", .{walked});
    try require(walk_contains(walked, grouped), "{any}", .{walked});
    try require(walk_contains(walked, subscript), "{any}", .{walked});
}

test "a decorated class stands wherever an expression may" {
    const gpa = std.testing.allocator;

    const source = "const F = @x class {};\n" ++
        "function g() {\n" ++
        "    return @x class {};\n" ++
        "}\n";

    const length: u32 = @intCast(source.len);
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    try std.testing.expectEqual(Structure.complete, try machine.parse(source, .typescript));
    try machine.walk(gpa, length);

    const walked = machine.held.items;
    const assigned: Row = .{ .name = "class", .offset = 10, .end = 21 };
    const returned: Row = .{ .name = "class", .offset = 49, .end = 60 };
    const statement: Row = .{ .name = "return_statement", .offset = 42, .end = 61 };

    try require(walk_contains(walked, assigned), "{any}", .{walked});
    try require(walk_contains(walked, returned), "{any}", .{walked});
    try require(walk_contains(walked, statement), "{any}", .{walked});
    try require(!walk_names(walked, "class_declaration"), "{any}", .{walked});
}

const Verdict = struct {
    source: []const u8,
    dialect: Dialect,
    accepted: bool,
    goal: Goal = .module,
};

fn verdict_module(source: []const u8, accepted: bool) Verdict {
    assert(source.len <= std.math.maxInt(u32));

    return .{ .source = source, .dialect = .javascript, .accepted = accepted, .goal = .module };
}

fn verdict_script(source: []const u8, accepted: bool) Verdict {
    assert(source.len <= std.math.maxInt(u32));

    return .{ .source = source, .dialect = .javascript, .accepted = accepted, .goal = .script };
}

fn verdicts_hold(cases: []const Verdict) !void {
    assert(cases.len <= std.math.maxInt(u32));

    const gpa = std.testing.allocator;
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    for (cases) |case| {
        const structure = try machine.parse_goal(case.source, case.dialect, case.goal);
        const accepted = structure == .complete and machine.tree.diagnostics.count() == 0;

        try require(accepted == case.accepted, "{s} accepted {}, wanted {}", .{
            case.source,
            accepted,
            case.accepted,
        });
    }
}

test "a statement ends at a semicolon, a line break, a closing brace or the end" {
    const cases = [_]Verdict{
        .{ .source = "const x = a b;\n", .dialect = .typescript, .accepted = false },
        .{
            .source = "function f() {\n    return a b;\n}\n",
            .dialect = .typescript,
            .accepted = false,
        },
        .{
            .source = "function f() {\n    throw a b;\n}\n",
            .dialect = .typescript,
            .accepted = false,
        },
        .{ .source = "export default a b;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "class C {\n    x = a b;\n}\n", .dialect = .typescript, .accepted = false },
        .{ .source = "debugger x;\n", .dialect = .typescript, .accepted = false },
        .{
            .source = "x: while (1) {\n    break x y;\n}\n",
            .dialect = .typescript,
            .accepted = false,
        },
        .{ .source = "import x from \"y\" z;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "export { x } y;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "type A = B C;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "function f(): void g;\n", .dialect = .typescript, .accepted = false },
        .{
            .source = "class C {\n    m(): void x;\n    [key: string]: any y;\n}\n",
            .dialect = .typescript,
            .accepted = false,
        },
        .{ .source = "import x = a.b c;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "for (let i = 0 i < 3; i++) {}\n", .dialect = .typescript, .accepted = false },
        .{ .source = "const x = a\nb;\n", .dialect = .typescript, .accepted = true },
        .{
            .source = "class C {\n    x = a\n    y = b\n}\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{ .source = "function f() { return a }\n", .dialect = .typescript, .accepted = true },
        .{ .source = "const x = a\u{2028}b;\n", .dialect = .typescript, .accepted = true },
        .{ .source = "do x(); while (y) z();\n", .dialect = .typescript, .accepted = true },
    };

    try verdicts_hold(&cases);
}

test "an elided element stands only in an array" {
    const cases = [_]Verdict{
        .{ .source = "f(a, , b);\n", .dialect = .typescript, .accepted = false },
        .{ .source = "Uri.parse(uri, , true);\n", .dialect = .typescript, .accepted = false },
        .{ .source = "function f(a, , b) {}\n", .dialect = .typescript, .accepted = false },
        .{ .source = "const { a, , b } = x;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "x = { a, , b };\n", .dialect = .typescript, .accepted = false },
        .{ .source = "import { a, , b } from \"x\";\n", .dialect = .typescript, .accepted = false },
        .{ .source = "enum E { A,, B }\n", .dialect = .typescript, .accepted = false },
        .{
            .source = "interface I { a: string;; b: number }\n",
            .dialect = .typescript,
            .accepted = false,
        },
        .{ .source = "x = [a, , b];\n", .dialect = .typescript, .accepted = true },
        .{ .source = "const [a, , b] = x;\n", .dialect = .typescript, .accepted = true },
        .{ .source = "class C { ;; m() {} }\n", .dialect = .typescript, .accepted = true },
        .{ .source = "f(a,);\n", .dialect = .typescript, .accepted = true },
    };

    try verdicts_hold(&cases);
}

test "an operator holds a left operand inside its own group" {
    const cases = [_]Verdict{
        .{ .source = "f(=(c, 16));\n", .dialect = .typescript, .accepted = false },
        .{ .source = "f(? a : b);\n", .dialect = .typescript, .accepted = false },
        .{ .source = "x = a[= b];\n", .dialect = .typescript, .accepted = false },
        .{ .source = "d(c, . e);\n", .dialect = .typescript, .accepted = false },
        .{ .source = "x = `${}`;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "x = `${a,}`;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "x = `${a, b}`;\n", .dialect = .typescript, .accepted = true },
        .{ .source = "x = f(a = 1, b += 2);\n", .dialect = .typescript, .accepted = true },
    };

    try verdicts_hold(&cases);
}

test "every bracket closes" {
    const cases = [_]Verdict{
        .{ .source = "function f() {\n    return 1;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "if (a {}\n", .dialect = .typescript, .accepted = false },
        .{ .source = "import { a from \"x\";\n", .dialect = .typescript, .accepted = false },
        .{ .source = "class C<T {}\n", .dialect = .typescript, .accepted = false },
        .{ .source = "enum E\n", .dialect = .typescript, .accepted = false },
        .{
            .source = "let x: Array<Array<number>> = [];\n",
            .dialect = .typescript,
            .accepted = true,
        },
    };

    try verdicts_hold(&cases);
}

test "an export carries a declaration" {
    const cases = [_]Verdict{
        .{ .source = "export X = 1;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "export ;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "export * \"./x\";\n", .dialect = .typescript, .accepted = false },
        .{ .source = "export { a } \"./x\";\n", .dialect = .typescript, .accepted = false },
        .{ .source = "import * x from \"x\";\n", .dialect = .typescript, .accepted = false },
        .{ .source = "export as namespace X;\n", .dialect = .typescript, .accepted = true },
        .{ .source = "export import a = b.c;\n", .dialect = .typescript, .accepted = true },
        .{
            .source = "export declare const x: number;\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{ .source = "export * as x from \"./x\";\n", .dialect = .typescript, .accepted = true },
    };

    try verdicts_hold(&cases);
}

test "a literal closes and a number spells one" {
    const cases = [_]Verdict{
        .{ .source = "x = 'abc\n", .dialect = .javascript, .accepted = false },
        .{ .source = "x = 1new;\n", .dialect = .javascript, .accepted = false },
        .{ .source = "x = 0x;\n", .dialect = .javascript, .accepted = false },
        .{ .source = "x = 1__0;\n", .dialect = .javascript, .accepted = false },
        .{ .source = "x = 08n;\n", .dialect = .javascript, .accepted = false },
        .{ .source = "x = 017;\n", .dialect = .javascript, .accepted = true },
        .{ .source = "x = 1_000n;\n", .dialect = .javascript, .accepted = true },
        .{ .source = "x = 0b1_0;\n", .dialect = .javascript, .accepted = true },
        .{ .source = "x = 'a\\'';\n", .dialect = .javascript, .accepted = true },
        .{ .source = "x = 5.e3 + .5 + 1.;\n", .dialect = .javascript, .accepted = true },
    };

    try verdicts_hold(&cases);
}

test "a type list holds an entry and a modifier stands once" {
    const cases = [_]Verdict{
        .{ .source = "f<>();\n", .dialect = .typescript, .accepted = false },
        .{ .source = "class A<> {}\n", .dialect = .typescript, .accepted = false },
        .{
            .source = "class C { private private x = 1; }\n",
            .dialect = .typescript,
            .accepted = false,
        },
        .{
            .source = "class C { public private x = 1; }\n",
            .dialect = .typescript,
            .accepted = false,
        },
        .{
            .source = "class C { constructor(private private x: number) {} }\n",
            .dialect = .typescript,
            .accepted = false,
        },
        .{ .source = "class A<T,> {}\n", .dialect = .typescript, .accepted = true },
        .{
            .source = "class C { static async *m() {} }\n",
            .dialect = .typescript,
            .accepted = true,
        },
    };

    try verdicts_hold(&cases);
}

test "a spread, a decorator and an arrow stand only where they may" {
    const cases = [_]Verdict{
        .{ .source = "x = ...a;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "x = { a: ...b };\n", .dialect = .typescript, .accepted = false },
        .{ .source = "x = <A b={...c} />;\n", .dialect = .tsx, .accepted = false },
        .{ .source = "@dec return;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "@dec export const x = 1;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "f(! a => 1);\n", .dialect = .typescript, .accepted = false },
        .{ .source = "x = a || b => c;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "f.call=> (this);\n", .dialect = .typescript, .accepted = false },
        .{ .source = "x = (a)\n=> a;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "x = <A {...rest} />;\n", .dialect = .tsx, .accepted = true },
        .{ .source = "x = [...a, f(...b), { ...c }];\n", .dialect = .typescript, .accepted = true },
        .{ .source = "@dec export default class {}\n", .dialect = .typescript, .accepted = true },
        .{ .source = "x = a ? (b) => 1 : c => 2;\n", .dialect = .typescript, .accepted = true },
        .{ .source = "x = <T,>(a: T) => a;\n", .dialect = .typescript, .accepted = true },
    };

    try verdicts_hold(&cases);
}

test "a key, a binding and a value stand wherever the grammar owes one" {
    const cases = [_]Verdict{
        .{ .source = "type T = { : string };\n", .dialect = .typescript, .accepted = false },
        .{ .source = "interface I { ?: string }\n", .dialect = .typescript, .accepted = false },
        .{ .source = "function f(: number) {}\n", .dialect = .typescript, .accepted = false },
        .{
            .source = "class C { constructor(new x: number) {} }\n",
            .dialect = .typescript,
            .accepted = false,
        },
        .{ .source = "class C { x = ; }\n", .dialect = .typescript, .accepted = false },
        .{ .source = "function f(a: T = ) {}\n", .dialect = .typescript, .accepted = false },
        .{ .source = "enum E { A = , B }\n", .dialect = .typescript, .accepted = false },
        .{ .source = "class A extends extends B {}\n", .dialect = .typescript, .accepted = false },
        .{ .source = "x = { new };\n", .dialect = .typescript, .accepted = false },
        .{ .source = "let { new } = x;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "const { a: } = x;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "const { a = } = x;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "x = a[];\n", .dialect = .typescript, .accepted = false },
        .{
            .source = "function f(this: Window, [a, b] = [], { c } = {}) {}\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "({ a: this.x, b: y.z, c: [d] } = e);\n",
            .dialect = .javascript,
            .accepted = true,
        },
        .{
            .source = "class C { get; set = 1; static() {} }\n",
            .dialect = .typescript,
            .accepted = true,
        },
    };

    try verdicts_hold(&cases);
}

test "an operator, a trailer and a member stand only on what may carry them" {
    const cases = [_]Verdict{
        .{ .source = "function (a) {}\n", .dialect = .javascript, .accepted = false },
        .{ .source = "try {} catch () {}\n", .dialect = .javascript, .accepted = false },
        .{ .source = "for (const x xs) {}\n", .dialect = .javascript, .accepted = false },
        .{ .source = "function f(a, ...) {}\n", .dialect = .javascript, .accepted = false },
        .{ .source = "x = #x;\n", .dialect = .javascript, .accepted = false },
        .{ .source = "x = { a > b };\n", .dialect = .javascript, .accepted = false },
        .{ .source = "x = { a [\"b\"] };\n", .dialect = .javascript, .accepted = false },
        .{ .source = "x = { a() };\n", .dialect = .javascript, .accepted = false },
        .{ .source = "!a = b;\n", .dialect = .javascript, .accepted = false },
        .{ .source = "a + b = c;\n", .dialect = .javascript, .accepted = false },
        .{ .source = "x++ = 1;\n", .dialect = .javascript, .accepted = false },
        .{ .source = "x = new await F();\n", .dialect = .javascript, .accepted = false },
        .{
            .source = "class A extends B { m() { super?.m(); } }\n",
            .dialect = .javascript,
            .accepted = false,
        },
        .{
            .source = "type T = { [k in string]? V };\n",
            .dialect = .typescript,
            .accepted = false,
        },
        .{
            .source = "interface I { async a: string }\n",
            .dialect = .typescript,
            .accepted = false,
        },
        .{ .source = "export default function () {}\n", .dialect = .javascript, .accepted = true },
        .{ .source = "try {} catch {}\n", .dialect = .javascript, .accepted = true },
        .{ .source = "for (const of of xs) {}\n", .dialect = .javascript, .accepted = true },
        .{
            .source = "class C { #x; m(o) { return #x in o; } }\n",
            .dialect = .javascript,
            .accepted = true,
        },
        .{ .source = "({ a = 1 } = b);\n", .dialect = .javascript, .accepted = true },
        .{ .source = "new X().y = a[b] = (c) = 1;\n", .dialect = .javascript, .accepted = true },
        .{ .source = "x! = 1;\n", .dialect = .typescript, .accepted = true },
        .{ .source = "type T = { [k in string]? };\n", .dialect = .typescript, .accepted = true },
        .{
            .source = "interface I { get a(): string; set a(v); m?(): void }\n",
            .dialect = .typescript,
            .accepted = true,
        },
    };

    try verdicts_hold(&cases);
}

test "type arguments in an expression end where TypeScript lets them end" {
    const cases = [_]Verdict{
        .{ .source = "x = f<T> in y;\n", .dialect = .typescript, .accepted = true },
        .{ .source = "x = f<T>\ny;\n", .dialect = .typescript, .accepted = true },
        .{ .source = "let z: A<typeof of>;\n", .dialect = .typescript, .accepted = true },
        .{ .source = "x = a < b > -c;\n", .dialect = .typescript, .accepted = true },
        .{ .source = "x = f<T>.name;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "x = [f<T>, g<U>];\n", .dialect = .typescript, .accepted = true },
    };

    try verdicts_hold(&cases);
}

test "an import alias names what it aliases" {
    const cases = [_]Verdict{
        .{ .source = "import n=", .dialect = .typescript, .accepted = false },
        .{ .source = "import//\nc=", .dialect = .typescript, .accepted = false },
        .{ .source = "import n = ;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "import n = \"x\"\n", .dialect = .typescript, .accepted = false },
        .{ .source = "import n = a.b.c\n", .dialect = .typescript, .accepted = true },
        .{ .source = "import n = require(\"x\")\n", .dialect = .typescript, .accepted = true },
        .{ .source = "export import n = a\n", .dialect = .typescript, .accepted = true },
    };

    try verdicts_hold(&cases);
}

test "a re-export takes import attributes on the line of its source" {
    const cases = [_]Verdict{
        .{
            .source = "export { a } from \"./a.json\" with { type: \"json\" };\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "export * from \"y\" with { type: \"json\" };\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "export * as ns from \"y\" with { type: \"json\" };\n",
            .dialect = .javascript,
            .accepted = true,
        },
        .{
            .source = "export type { A } from \"./a\" with { \"resolution-mode\": \"import\" };\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "export { a } from \"y\" with {};\n",
            .dialect = .javascript,
            .accepted = true,
        },
        .{
            .source = "export { a } with { type: \"json\" };\n",
            .dialect = .typescript,
            .accepted = false,
        },
        .{
            .source = "export * from \"y\"\nwith { type: \"json\" };\n",
            .dialect = .typescript,
            .accepted = false,
        },
        .{
            .source = "export * from \"y\"\nwith ({}) {}\n",
            .dialect = .javascript,
            .accepted = true,
        },
        .{
            .source = "export * from \"y\" with { type: \"json\" } with { a: \"b\" };\n",
            .dialect = .typescript,
            .accepted = false,
        },
    };

    try verdicts_hold(&cases);
}

test "an import or a re-export takes the assert form on the line of its source" {
    const cases = [_]Verdict{
        .{
            .source = "import x from \"y\" assert { type: \"json\" };\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "import \"y\" assert { type: \"json\" };\n",
            .dialect = .javascript,
            .accepted = true,
        },
        .{
            .source = "export * from \"y\" assert { type: \"json\" };\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "import x from \"y\"\nassert { type: \"json\" };\n",
            .dialect = .typescript,
            .accepted = false,
        },
        .{
            .source = "import x from \"y\"\nassert(1);\n",
            .dialect = .javascript,
            .accepted = true,
        },
        .{
            .source = "import x from \"y\"\nwith { type: \"json\" };\n",
            .dialect = .typescript,
            .accepted = true,
        },
    };

    try verdicts_hold(&cases);
}

test "a using declaration names a binding of only where TypeScript reads one" {
    const cases = [_]Verdict{
        .{ .source = "for", .dialect = .typescript, .accepted = false },
        .{ .source = "for (", .dialect = .typescript, .accepted = false },
        .{ .source = "for await", .dialect = .javascript, .accepted = false },
        .{ .source = "for (await", .dialect = .typescript, .accepted = false },
        .{ .source = "for (await using", .dialect = .typescript, .accepted = false },
        .{ .source = "for (using of", .dialect = .typescript, .accepted = false },
        .{
            .source = "async function f() {\n    for (await using of of of);\n}\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "async function f() {\n    for (await using of = 1;;);\n}\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "function f() {\n    for (using of = 1;;);\n}\n",
            .dialect = .javascript,
            .accepted = true,
        },
        .{
            .source = "function f() {\n    for (using of: T = a;;);\n}\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "function f() {\n    for (using of of y);\n}\n",
            .dialect = .typescript,
            .accepted = false,
        },
        .{
            .source = "function f() {\n    for (using of, x = 1;;);\n}\n",
            .dialect = .typescript,
            .accepted = false,
        },
        .{
            .source = "async function f() {\n    for (await using of y);\n}\n",
            .dialect = .typescript,
            .accepted = false,
        },
        .{
            .source = "function f() {\n    for (using of y);\n}\n",
            .dialect = .typescript,
            .accepted = true,
        },
    };

    try verdicts_hold(&cases);
}

test "a type member ends at a line break where TypeScript ends it" {
    const cases = [_]Verdict{
        .{
            .source = "interface A {\n    m(): string\n    [key: string]: any\n}\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "interface A {\n    close(): Promise<void>\n\n    [k]: true\n}\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "type A = {\n    a: Set<string>\n    /** c */\n    [S]: true\n}\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "interface A {\n    (a: number): B & C\n    <S>(b: S): S\n}\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "interface A {\n    (a: number): B /* c\n */ <S>(b: S): S\n}\n",
            .dialect = .typescript,
            .accepted = true,
        },
    };

    try verdicts_hold(&cases);
}

test "a type ends at a line break where TypeScript ends it" {
    const cases = [_]Verdict{
        .{
            .source = "type Q = typeof x\n<T>(a: T) => T;\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{ .source = "type Q = typeof x /* c */ <T>;\n", .dialect = .typescript, .accepted = true },
        .{
            .source = "type I = import(\"x\").Y\n<T>(a: T) => T;\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{ .source = "type I = A\n<T>;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "type A = B\n[];\n", .dialect = .typescript, .accepted = true },
        .{ .source = "let a: B[\n\"k\"];\n", .dialect = .typescript, .accepted = true },
        .{
            .source = "type K = A\nextends B ? C : D;\n",
            .dialect = .typescript,
            .accepted = false,
        },
        .{
            .source = "type K = A extends B\n    ? C\n    : D;\n",
            .dialect = .typescript,
            .accepted = true,
        },
    };

    try verdicts_hold(&cases);
}

test "a type predicate ends at a line break where TypeScript ends it" {
    const cases = [_]Verdict{
        .{
            .source = "function f(x: unknown): x\n    is string {}\n",
            .dialect = .typescript,
            .accepted = false,
        },
        .{
            .source = "function f(x: unknown): asserts\n    x is string {}\n",
            .dialect = .typescript,
            .accepted = false,
        },
        .{
            .source = "function f(x: unknown): asserts x\n    is string {}\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "function f(this: A): this\n    is B {}\n",
            .dialect = .typescript,
            .accepted = false,
        },
        .{
            .source = "function f(x: unknown): x is string {}\n",
            .dialect = .typescript,
            .accepted = true,
        },
    };

    try verdicts_hold(&cases);
}

test "a bang after a line break starts a statement and never asserts non-null" {
    const cases = [_]Verdict{
        .{ .source = "const a = b()\n!c && d();\n", .dialect = .typescript, .accepted = true },
        .{ .source = "let a = b\n!c;\n", .dialect = .typescript, .accepted = true },
        .{ .source = "const a = b!\n.c;\n", .dialect = .typescript, .accepted = true },
        .{ .source = "const a = b!.c;\n", .dialect = .typescript, .accepted = true },
    };

    try verdicts_hold(&cases);
}

test "an as or satisfies after a line break ends the expression it follows" {
    const cases = [_]Verdict{
        .{ .source = "1\nas const;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "let x = y\nas T;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "let x = y\nsatisfies T;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "const a = (x\nas T);\n", .dialect = .typescript, .accepted = false },
        .{ .source = "const a = (x // c\n) as T;\n", .dialect = .typescript, .accepted = true },
        .{ .source = "const a = x as\nT;\n", .dialect = .typescript, .accepted = true },
        .{ .source = "const a = x satisfies\nT;\n", .dialect = .typescript, .accepted = true },
        .{ .source = "let as = 1;\nx\nas\nT;\n", .dialect = .typescript, .accepted = true },
    };

    try verdicts_hold(&cases);
}

test "a closing angle before an equals sign closes the type TypeScript closes" {
    const cases = [_]Verdict{
        .{ .source = "type X<T>=T[];\n", .dialect = .typescript, .accepted = true },
        .{ .source = "type Y<T = A<B>>=T[];\n", .dialect = .typescript, .accepted = true },
        .{ .source = "let x: A<B>=y;\n", .dialect = .typescript, .accepted = true },
        .{ .source = "let z: A<A<B>>=[];\n", .dialect = .typescript, .accepted = true },
        .{ .source = "const g = (): A<B>=>{};\n", .dialect = .typescript, .accepted = true },
        .{ .source = "class K { private x: A<B>=y; }\n", .dialect = .typescript, .accepted = true },
        .{ .source = "function f(p: A<B>=q) {}\n", .dialect = .typescript, .accepted = true },
        .{ .source = "function f(p, r?: B<C>=d) {}\n", .dialect = .typescript, .accepted = true },
        .{ .source = "let a = b>=c;\nx = y<z>=w;\n", .dialect = .typescript, .accepted = true },
    };

    try verdicts_hold(&cases);
}

test "a declaration and an index signature read what TypeScript reads" {
    const cases = [_]Verdict{
        .{
            .source = "{ using foo: Foo = new Foo(); }\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "async function f() { await using foo: Foo = new Foo(); }\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "class Foo { static [value: string]: Type; }\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "class Foo { static readonly [key: string]: number; }\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "class Foo { static [x]: number; }\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "type A = { [a: string, b: string]: string };\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "class C { readonly readonly x: number; }\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "class C { static static x = 1; }\n",
            .dialect = .typescript,
            .accepted = false,
        },
    };

    try verdicts_hold(&cases);
}

test "an infer reads what TypeScript reads" {
    const cases = [_]Verdict{
        .{
            .source = "type A<T> = T extends (infer U extends number ? 1 : 2) ? U : never;\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "type A<T> = T extends [infer U extends number ? 1 : 2] ? U : never;\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "type A<T> = T extends [infer U extends number?] ? U : never;\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "type A<T> = infer U extends number ? 1 : 2;\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "type A<T> = T extends infer U extends number ? 1 : 2;\n",
            .dialect = .typescript,
            .accepted = true,
        },
    };

    try verdicts_hold(&cases);
}

test "a parenthesis opens an arrow where TypeScript's arrow lookahead opens one" {
    const cases = [_]Verdict{
        .{
            .source = "const m = b ? (n as any) : (e, c) => {\n    return c;\n};\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "const r = o.r === e ? (o.r = {}) : o.r\nconst f = () => 1\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{ .source = "const f = a ? (b) : c => c;\n", .dialect = .typescript, .accepted = true },
        .{ .source = "const f = a ? (b) : (c) => c;\n", .dialect = .typescript, .accepted = true },
        .{
            .source = "const g = a ? b + (c) : d => e;\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "const g = a ? (b, c + d) : e => f;\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "const g = a ? ({ b }) : c => d;\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "const f = a ? (x): string => x : null;\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "const g = a ? f(x => (y): T => z) : w;\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "const g = a ? x => (y: T): U => v : w;\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "const g = a ? (x): T => { return x; } : y;\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "switch (k) {\n    case (x):\n        f()\n        const g = () => 1\n}\n",
            .dialect = .typescript,
            .accepted = true,
        },
    };

    try verdicts_hold(&cases);
}

test "an arrow's return type is a whole type and the arrow follows it" {
    const cases = [_]Verdict{
        .{
            .source = "const f = (x): <T>(y: T) => T => (y) => y;\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{ .source = "const f = (x): (y) => z => w;\n", .dialect = .typescript, .accepted = true },
        .{ .source = "const f = (x): (A | B) => x;\n", .dialect = .typescript, .accepted = true },
        .{ .source = "const f = (x): (string) => x;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "const f = (x): (A) => x;\n", .dialect = .typescript, .accepted = false },
    };

    try verdicts_hold(&cases);
}

test "a parenthesis opens a function type where TypeScript's type lookahead opens one" {
    const cases = [_]Verdict{
        .{
            .source = "type K<T> = T extends object ? (keyof T extends string ? 1 : 0) : 0\n" ++
                "const f = () => 1\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{ .source = "type T = (keyof A)[];\n", .dialect = .typescript, .accepted = true },
        .{ .source = "type T = (typeof a)[];\n", .dialect = .typescript, .accepted = true },
        .{ .source = "type T = (A)[];\n", .dialect = .typescript, .accepted = true },
        .{
            .source = "type T = (readonly string[])[];\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "type T = (this: Window) => void;\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{ .source = "type T = (a?) => void;\n", .dialect = .typescript, .accepted = true },
        .{ .source = "type T = (...a: B) => void;\n", .dialect = .typescript, .accepted = true },
        .{ .source = "type T = ([a, b]: C) => void;\n", .dialect = .typescript, .accepted = true },
        .{
            .source = "type T = ({ a: string }) => void;\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{ .source = "type T = (a) => void;\n", .dialect = .typescript, .accepted = true },
        .{ .source = "type T = (A | B) => void;\n", .dialect = .typescript, .accepted = false },
    };

    try verdicts_hold(&cases);
}

test "an exported word declares only when its declaration follows" {
    const cases = [_]Verdict{
        .{ .source = "export type = X = 1;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "export type\nX = 1;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "export interface = 1;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "type\nX = 1;\n", .dialect = .typescript, .accepted = true },
        .{ .source = "type = 5;\n", .dialect = .typescript, .accepted = true },
        .{ .source = "export module \"m\" {}\n", .dialect = .typescript, .accepted = true },
        .{ .source = "export abstract class C {}\n", .dialect = .typescript, .accepted = true },
    };

    try verdicts_hold(&cases);
}

test "a for-in head is a declaration or an assignment target" {
    const cases = [_]Verdict{
        .{ .source = "for (a + b in o) {}\n", .dialect = .javascript, .accepted = false },
        .{ .source = "for (f() in o) {}\n", .dialect = .javascript, .accepted = true },
        .{ .source = "for (f().g() of o) {}\n", .dialect = .javascript, .accepted = true },
        .{ .source = "for ((f()) in o) {}\n", .dialect = .javascript, .accepted = true },
        .{ .source = "for (f?.() in o) {}\n", .dialect = .javascript, .accepted = false },
        .{ .source = "for (a?.b() in o) {}\n", .dialect = .javascript, .accepted = false },
        .{ .source = "for (f`x` in o) {}\n", .dialect = .javascript, .accepted = false },
        .{ .source = "for (import(\"m\") in o) {}\n", .dialect = .javascript, .accepted = false },
        .{ .source = "for (new X in o) {}\n", .dialect = .javascript, .accepted = false },
        .{ .source = "for ((a + b) in o) {}\n", .dialect = .javascript, .accepted = false },
        .{ .source = "for (a?.b in o) {}\n", .dialect = .javascript, .accepted = false },
        .{ .source = "for (this in o) {}\n", .dialect = .javascript, .accepted = false },
        .{ .source = "for (([a]) in o) {}\n", .dialect = .javascript, .accepted = false },
        .{ .source = "for (x of a, b) {}\n", .dialect = .javascript, .accepted = false },
        .{ .source = "for ( in o) {}\n", .dialect = .javascript, .accepted = false },
        .{ .source = "for (x! in o) {}\n", .dialect = .javascript, .accepted = false },
        .{ .source = "for (a?.b.c in o) {}\n", .dialect = .typescript, .accepted = false },
        .{ .source = "for (y.z in o) {}\n", .dialect = .javascript, .accepted = true },
        .{ .source = "for (this.x[k] in o) {}\n", .dialect = .javascript, .accepted = true },
        .{ .source = "for ((y) in o) {}\n", .dialect = .javascript, .accepted = true },
        .{ .source = "for (((y.z)) of o);\n", .dialect = .javascript, .accepted = true },
        .{ .source = "for ([a].x in o) {}\n", .dialect = .javascript, .accepted = true },
        .{ .source = "for ({ a }.x in o) {}\n", .dialect = .javascript, .accepted = true },
        .{ .source = "for (f(a in b).c in o) {}\n", .dialect = .javascript, .accepted = true },
        .{ .source = "for ([a, b] of o) {}\n", .dialect = .javascript, .accepted = true },
        .{ .source = "for (x in a, b) {}\n", .dialect = .javascript, .accepted = true },
        .{ .source = "for ((a?.b).c in o) {}\n", .dialect = .typescript, .accepted = true },
        .{ .source = "for (x! in o) {}\n", .dialect = .typescript, .accepted = true },
        .{ .source = "for ((x as any).y of o) {}\n", .dialect = .typescript, .accepted = true },
    };

    try verdicts_hold(&cases);
}

test "a contextual keyword before an arrow is its parameter" {
    const cases = [_]Verdict{
        .{ .source = "await => 1;\n", .dialect = .javascript, .accepted = true },
        .{ .source = "yield => 1;\n", .dialect = .javascript, .accepted = true },
        .{ .source = "x = await => await;\n", .dialect = .javascript, .accepted = true },
        .{ .source = "for (async of => {}; ;) ;\n", .dialect = .javascript, .accepted = true },
        .{ .source = "for (async of => {}, x; ;) ;\n", .dialect = .javascript, .accepted = true },
        .{ .source = "for (async of []) ;\n", .dialect = .javascript, .accepted = true },
        .{ .source = "await\n=> 1;\n", .dialect = .javascript, .accepted = false },
        .{ .source = "a + await => 1;\n", .dialect = .javascript, .accepted = false },
    };

    try verdicts_hold(&cases);
}

test "await and yield before a slash follow the function that holds them" {
    const cases = [_]Verdict{
        verdict_script("x = await / 2 / 3;\n", true),
        verdict_script("x = await /x/;\n", false),
        verdict_script("x = yield / 2 / 3;\n", true),
        verdict_script("x = yield /x/;\n", false),
        verdict_script("function f() { x = await /x/ 2; }\n", true),
        verdict_script("function f() { x = await /x/; }\n", false),
        verdict_script("async function f() { x = await /x/; }\n", true),
        verdict_script("async function f() { x = await / 2 / 3; }\n", false),
        verdict_script("async function f() { () => await /x/ 2; }\n", true),
        verdict_script("async function f() { async () => await /x/; }\n", true),
        verdict_script("function* g() { x = yield /x/g; }\n", true),
        verdict_script("function* g() { x = yield / 2 / 3; }\n", false),
        verdict_script("function* g() { () => yield / 2 / 3; }\n", true),
        verdict_script("function* g() { function f() { x = yield / 2 / 3; } }\n", true),
        verdict_script("async function* g() { x = yield /x/g; x = await /y/; }\n", true),
        verdict_script("function f(a = await / 2 / 3) {}\n", true),
        verdict_module("x = await /x/.test(s);\n", true),
        verdict_module("x = await / 2 / 3;\n", false),
        verdict_module("async function f() { x = await /x/; }\n", true),
    };

    try verdicts_hold(&cases);
}

test "await and yield before a slash follow the member or arrow that holds them" {
    const cases = [_]Verdict{
        verdict_script("class A { m() { x = await / 2 / 3; } }\n", true),
        verdict_script("class A { async m() { x = await /x/; } }\n", true),
        verdict_script("class A { *g() { x = yield /x/g; } }\n", true),
        verdict_script("class A { y = await / 2 / 3; }\n", true),
        verdict_script("class A { [await / 2 / 3]() {} }\n", true),
        verdict_script("async function f() { class A { [await /x/]() {} } }\n", true),
        verdict_script("async function f() { class A { m() { x = await / 2 / 3; } } }\n", true),
        verdict_script("x = { async m() { await /x/; } };\n", true),
        verdict_script("x = { m() { x = await / 2 / 3; } };\n", true),
        verdict_script("x = { *g() { yield /x/g; } };\n", true),
        verdict_script("x = function* () { yield /x/g; };\n", true),
        verdict_script("x = async function () { await /x/; };\n", true),
        verdict_script("x = async function* () { await /x/; yield /y/; };\n", true),
        verdict_script("async () => await /x/.test(s);\n", true),
        verdict_script("async x => await /x/.test(s);\n", true),
        verdict_script("() => await / 2 / 3;\n", true),
        verdict_script("x => await / 2 / 3;\n", true),
        verdict_script("async function f() { x = async () => await /x/; }\n", true),
        verdict_module("class A { [await /x/]() {} }\n", true),
    };

    try verdicts_hold(&cases);
}

test "await reads as a name exactly where V8 reads it as one" {
    const cases = [_]Verdict{
        verdict_script("await(1);\n", true),
        verdict_script("await[0];\n", true),
        verdict_script("await - 1;\n", true),
        verdict_script("await--;\n", true),
        verdict_script("await++;\n", true),
        verdict_script("await + 1;\n", true),
        verdict_script("await`x`;\n", true),
        verdict_script("await;\n", true),
        verdict_script("await.x;\n", true),
        verdict_script("await = 1;\n", true),
        verdict_script("x = await ? 1 : 2;\n", true),
        verdict_script("await\n(1);\n", true),
        verdict_script("x = await\n1;\n", true),
        verdict_script("x = await\n[0];\n", true),
        verdict_script("x = await in y;\n", true),
        verdict_script("x = await instanceof y;\n", true),
        verdict_script("x = await < 1;\n", true),
        verdict_script("for (await of x);\n", true),
        verdict_script("label: await;\n", true),
        verdict_script("await: 1;\n", true),
        verdict_script("x = (await) => 1;\n", true),
        verdict_script("x = function await() {};\n", true),
        verdict_script("function f(await) {}\n", true),
        verdict_script("x = { await };\n", true),
        verdict_script("async function f() { await(1); }\n", true),
        verdict_script("async function f() { await[0]; }\n", true),
        verdict_script("async function f() { await - 1; }\n", true),
        verdict_script("async function f() { await\n[0]; }\n", true),
        verdict_script("async function f() { await`x`; }\n", true),
        verdict_script("async function f() { () => await(1); }\n", true),
        verdict_script("async function f() { () => await[0]; }\n", true),
        verdict_script("async function f() { async () => await(1); }\n", true),
        verdict_script("async function f() { function g() { await(1); } }\n", true),
        verdict_script("class A { m() { await(1); } }\n", true),
        verdict_script("x = await of;\n", false),
        verdict_script("async function f() { await++; }\n", false),
        verdict_script("async function f() { await < 1; }\n", false),
        verdict_script("async function f() { for (await of x); }\n", false),
        verdict_module("await(1);\n", true),
        verdict_module("await[0];\n", true),
        verdict_module("await - 1;\n", true),
        verdict_module("x = await\n1;\n", true),
    };

    try verdicts_hold(&cases);
}

test "yield reads as a name exactly where V8 reads it as one" {
    const cases = [_]Verdict{
        verdict_script("yield(1);\n", true),
        verdict_script("yield[0];\n", true),
        verdict_script("yield - 1;\n", true),
        verdict_script("yield;\n", true),
        verdict_script("yield = 1;\n", true),
        verdict_script("x = yield\n1;\n", true),
        verdict_script("x = yield\n[0];\n", true),
        verdict_script("x = yield in y;\n", true),
        verdict_script("for (yield of x);\n", true),
        verdict_script("yield: 1;\n", true),
        verdict_script("x = { yield };\n", true),
        verdict_script("function* g() { yield(1); }\n", true),
        verdict_script("function* g() { yield[0]; }\n", true),
        verdict_script("function* g() { yield - 1; }\n", true),
        verdict_script("function* g() { yield; }\n", true),
        verdict_script("function* g() { yield\n1; }\n", true),
        verdict_script("function* g() { yield\n[0]; }\n", true),
        verdict_script("function* g() { yield`x`; }\n", true),
        verdict_script("function* g() { function f() { yield(1); } }\n", true),
        verdict_script("function* g() { yield++; }\n", false),
        verdict_script("function* g() { yield < 1; }\n", false),
        verdict_script("function* g() { yield in y; }\n", false),
        verdict_script("function* g() { x = yield instanceof y; }\n", false),
        verdict_script("function* g() { for (yield of x); }\n", false),
    };

    try verdicts_hold(&cases);
}

test "a slash the lexer guessed wrong is lexed again as the parser reads it" {
    const cases = [_]Verdict{
        verdict_script("x = () => {}\n/foo/g.test(s);\n", true),
        verdict_script("function* g() { yield\n/x/g.test(s); }\n", true),
        verdict_script("a\n/x/g.test(s);\n", true),
        verdict_script("if (a === \"(\") /x/.test(s);\n", true),
        verdict_script("x = (s.indexOf(\")\") + 1) / 2;\n", true),
        verdict_script("do ; while (0) /x/g.test('x');\n", true),
        verdict_script("x = function () {} / 2;\n", true),
        verdict_script("x = class {} / 2;\n", true),
        verdict_script("{} /x/.test(s);\n", true),
        verdict_script("x = {a: 1}\n/foo/g.test(s);\n", true),
        verdict_script("x = a ? b : c / 2 / 3;\n", true),
        verdict_script("x = `${{} / 2}`;\n", true),
        verdict_script("switch (a) { case /x/.test(s): }\n", true),
        verdict_script("x = a\n/=b/g;\n", true),
        verdict_script("if (a) {} /x/.test(s);\n", true),
        verdict_script("while (f(\")\")) /x/.test(s);\n", true),
        verdict_script("label: /x/.test(s);\n", true),
        verdict_script("x = typeof /x/;\n", true),
        verdict_script("if (a) function f() {} /x/.test(s);\n", true),
        verdict_script("function f() {}\n/x/g.test(s);\n", true),
        verdict_script("x = () => {} / 2;\n", false),
    };

    try verdicts_hold(&cases);
}

test "a default export may name an interface but no other type declaration" {
    const cases = [_]Verdict{
        .{ .source = "export default interface Z {}\n", .dialect = .typescript, .accepted = true },
        .{ .source = "export default interface\nZ {}\n", .dialect = .typescript, .accepted = true },
        .{ .source = "export default interface {}\n", .dialect = .typescript, .accepted = false },
        .{ .source = "export default enum E {}\n", .dialect = .typescript, .accepted = false },
        .{ .source = "export default type T = 1;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "export default interface Z {}\n", .dialect = .javascript, .accepted = false },
    };

    try verdicts_hold(&cases);
}

test "a for head reads of as its keyword only after an iteration target" {
    const cases = [_]Verdict{
        .{
            .source = "for (se = [], ie = of(); ie;) x;\n",
            .dialect = .javascript,
            .accepted = true,
        },
        .{ .source = "for (of of of);\n", .dialect = .javascript, .accepted = true },
        .{ .source = "for (let of of x);\n", .dialect = .javascript, .accepted = true },
        .{ .source = "for (a.of of b);\n", .dialect = .javascript, .accepted = true },
        .{ .source = "for (using foo of o);\n", .dialect = .javascript, .accepted = true },
        .{ .source = "for (using foo in o);\n", .dialect = .javascript, .accepted = false },
    };

    try verdicts_hold(&cases);
}

test "a for head reads let as a name, takes a var initializer and requires its semicolons" {
    const cases = [_]Verdict{
        .{ .source = "for (var a = 1 in b);\n", .dialect = .javascript, .accepted = true },
        .{ .source = "for (var [a] = 1 in b);\n", .dialect = .javascript, .accepted = true },
        .{ .source = "for (var a = 1 of b);\n", .dialect = .javascript, .accepted = false },
        .{ .source = "for (var a = b in c in d);\n", .dialect = .javascript, .accepted = true },
        .{ .source = "for (let a = 1 in b);\n", .dialect = .javascript, .accepted = false },
        .{ .source = "for (var a = 1, b in x);\n", .dialect = .javascript, .accepted = false },
        .{ .source = "for (let.a in b);\n", .dialect = .javascript, .accepted = true },
        .{ .source = "for (let in x);\n", .dialect = .javascript, .accepted = true },
        .{ .source = "for (let = 1;;);\n", .dialect = .javascript, .accepted = true },
        .{ .source = "for (let;;);\n", .dialect = .javascript, .accepted = true },
        .{ .source = "for (let(); ;);\n", .dialect = .javascript, .accepted = true },
        .{ .source = "for (let[a] in x);\n", .dialect = .javascript, .accepted = true },
        .{ .source = "for (x y z);\n", .dialect = .javascript, .accepted = false },
        .{ .source = "for (x;y z);\n", .dialect = .javascript, .accepted = false },
        .{ .source = "for (x \\u006ff y);\n", .dialect = .javascript, .accepted = false },
    };

    try verdicts_hold(&cases);
}

test "an export star names any module export name and a type star exports types" {
    const cases = [_]Verdict{
        .{
            .source = "export * as default from \"a\";\n",
            .dialect = .javascript,
            .accepted = true,
        },
        .{
            .source = "export * as function from \"a\";\n",
            .dialect = .javascript,
            .accepted = true,
        },
        .{
            .source = "export * as \"a b\" from \"a\";\n",
            .dialect = .javascript,
            .accepted = true,
        },
        .{
            .source = "import * as default from \"a\";\n",
            .dialect = .javascript,
            .accepted = false,
        },
        .{ .source = "export type * from \"a\";\n", .dialect = .typescript, .accepted = true },
        .{
            .source = "export type * as ns from \"a\";\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{ .source = "export type * from \"a\";\n", .dialect = .javascript, .accepted = false },
        .{
            .source = "import type T = require(\"a\");\n",
            .dialect = .typescript,
            .accepted = true,
        },
    };

    try verdicts_hold(&cases);
}

test "a declare opens a declaration only before a declaration on its own line" {
    const cases = [_]Verdict{
        .{ .source = "export declare foo;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "declare\nconst x = 1;\n", .dialect = .typescript, .accepted = true },
        .{ .source = "declare global {}\n", .dialect = .typescript, .accepted = true },
        .{ .source = "global {}\n", .dialect = .typescript, .accepted = true },
        .{ .source = "namespace a.b.c {}\n", .dialect = .typescript, .accepted = true },
        .{ .source = "declare type T = number;\n", .dialect = .typescript, .accepted = true },
    };

    try verdicts_hold(&cases);
}

test "a modifier ends at a line break unless it is static, get or set" {
    const cases = [_]Verdict{
        .{
            .source = "class C {\n    static\n    static\n    static\n    a() {}\n}\n",
            .dialect = .javascript,
            .accepted = true,
        },
        .{
            .source = "class C {\n    static async\n    foo() {}\n}\n",
            .dialect = .javascript,
            .accepted = true,
        },
        .{
            .source = "class C {\n    get\n    foo() {}\n}\n",
            .dialect = .javascript,
            .accepted = true,
        },
        .{
            .source = "class C {\n    static accessor\n    bar;\n}\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "class C {\n    declare get foo();\n}\n",
            .dialect = .typescript,
            .accepted = false,
        },
        .{
            .source = "abstract class C {\n    abstract p = 1;\n}\n",
            .dialect = .typescript,
            .accepted = false,
        },
        .{
            .source = "abstract class C {\n    abstract m() {}\n}\n",
            .dialect = .typescript,
            .accepted = false,
        },
        .{ .source = "let x\n!function () {};\n", .dialect = .typescript, .accepted = true },
        .{ .source = "let x!: number;\n", .dialect = .typescript, .accepted = true },
        .{ .source = "let x! = 1;\n", .dialect = .javascript, .accepted = false },
    };

    try verdicts_hold(&cases);
}

test "a modifier word before a definite assignment names the field" {
    const gpa = std.testing.allocator;

    const source = "abstract class A {\n" ++
        "    get!: G;\n" ++
        "    static set!: S;\n" ++
        "    readonly!: R;\n" ++
        "}\n";

    const length: u32 = @intCast(source.len);
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    try std.testing.expectEqual(Structure.complete, try machine.parse(source, .typescript));
    try std.testing.expectEqual(0, machine.tree.diagnostics.count());
    try machine.walk(gpa, length);

    const walked = machine.held.items;
    const getter: Row = .{ .name = "property_identifier", .offset = 23, .end = 26 };
    const setter: Row = .{ .name = "property_identifier", .offset = 43, .end = 46 };
    const reader: Row = .{ .name = "property_identifier", .offset = 56, .end = 64 };

    try require(walk_contains(walked, getter), "{any}", .{walked});
    try require(walk_contains(walked, setter), "{any}", .{walked});
    try require(walk_contains(walked, reader), "{any}", .{walked});
    try require(!walk_names(walked, "method_definition"), "{any}", .{walked});

    const cases = [_]Verdict{
        .{
            .source = "class C {\n    get!: G;\n    set!: S;\n    static!: T;\n    async!: U;\n}\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "class C {\n    declare!: D;\n    private!: P;\n    override!: O;\n}\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{
            .source = "abstract class C {\n    abstract!: A;\n    accessor!: B;\n}\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{ .source = "class C {\n    get!() {}\n}\n", .dialect = .typescript, .accepted = false },
    };

    try verdicts_hold(&cases);
}

test "an optional chain is never a target and a member never a parameter" {
    const cases = [_]Verdict{
        .{ .source = "a?.b = 1;\n", .dialect = .javascript, .accepted = false },
        .{ .source = "a?.b++;\n", .dialect = .javascript, .accepted = false },
        .{ .source = "++a?.b;\n", .dialect = .javascript, .accepted = false },
        .{ .source = "(a?.b) = 1;\n", .dialect = .javascript, .accepted = false },
        .{ .source = "[a?.b] = c;\n", .dialect = .javascript, .accepted = false },
        .{ .source = "function f(a?.b) {}\n", .dialect = .javascript, .accepted = false },
        .{ .source = "function f(a.b) {}\n", .dialect = .javascript, .accepted = false },
        .{ .source = "(a?.b) => {};\n", .dialect = .javascript, .accepted = false },
        .{ .source = "[a.b, c[0]] = x;\n", .dialect = .javascript, .accepted = true },
        .{ .source = "function f(x = a?.b) {}\n", .dialect = .javascript, .accepted = true },
        .{ .source = "[x as any] = x;\n", .dialect = .typescript, .accepted = true },
        .{ .source = "[a!] = x;\n", .dialect = .typescript, .accepted = true },
        .{ .source = "({ a: (b as any) = 2 } = x);\n", .dialect = .typescript, .accepted = true },
    };

    try verdicts_hold(&cases);
}

test "a type constrains what its unions, mappings and constructors hold" {
    const cases = [_]Verdict{
        .{ .source = "type A = B | () => void;\n", .dialect = .typescript, .accepted = false },
        .{ .source = "type A = (() => void) | B;\n", .dialect = .typescript, .accepted = true },
        .{
            .source = "type M = { [K in X]: Y; a: b };\n",
            .dialect = .typescript,
            .accepted = false,
        },
        .{ .source = "type M = { [K in X]: Y };\n", .dialect = .typescript, .accepted = true },
        .{
            .source = "type T = abstract new () => void;\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{ .source = "class A extends (B<T>)<T> {}\n", .dialect = .typescript, .accepted = true },
        .{
            .source = "const f = <const T,>(x: T) => x;\n",
            .dialect = .typescript,
            .accepted = true,
        },
        .{ .source = "const f = <const T,>(x: T) => x;\n", .dialect = .tsx, .accepted = true },
    };

    try verdicts_hold(&cases);
}

test "an escape, a meta property and an accessor follow the grammar" {
    const cases = [_]Verdict{
        .{ .source = "x = \"\\xZ1\";\n", .dialect = .javascript, .accepted = false },
        .{ .source = "x = \"\\8\\u{41}\\x41\";\n", .dialect = .javascript, .accepted = true },
        .{ .source = "x = `\\u{prettier}`;\n", .dialect = .javascript, .accepted = false },
        .{ .source = "x = tag`\\u{prettier}`;\n", .dialect = .javascript, .accepted = true },
        .{ .source = "x = `\\8`;\n", .dialect = .javascript, .accepted = false },
        .{ .source = "const \\u{20} = 1;\n", .dialect = .javascript, .accepted = false },
        .{ .source = "const \\u0061b = 1;\n", .dialect = .javascript, .accepted = true },
        .{ .source = "x = import.source(\"a\");\n", .dialect = .javascript, .accepted = false },
        .{ .source = "x = import.defer(\"a\");\n", .dialect = .javascript, .accepted = true },
        .{ .source = "({ get *a() {} });\n", .dialect = .javascript, .accepted = false },
    };

    try verdicts_hold(&cases);
}

test "a jsx tag opens after trivia and its text holds no closing angle" {
    const cases = [_]Verdict{
        .{ .source = "x = <a b=<c /> />;\n", .dialect = .javascript, .accepted = true },
        .{ .source = "x = <a b=<></> />;\n", .dialect = .javascript, .accepted = true },
        .{ .source = "x = < /* c */ div />;\n", .dialect = .javascript, .accepted = true },
        .{ .source = "x = <div>(text)</div>;\n", .dialect = .javascript, .accepted = true },
        .{ .source = "x = <div>(text)</div>;\n", .dialect = .tsx, .accepted = true },
        .{ .source = "x = <div>a > b</div>;\n", .dialect = .javascript, .accepted = false },
        .{ .source = "x = <div>a } b</div>;\n", .dialect = .tsx, .accepted = false },
        .{ .source = "x = <T,>(a: T) => a;\n", .dialect = .tsx, .accepted = true },
    };

    try verdicts_hold(&cases);
}

test "the normalized walk matches the goldens" {
    const gpa = std.testing.allocator;
    var carried = try oracle.residue_of(gpa, residue_name, &every_category);
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

        var golden: oracle.Golden = undefined;

        try golden_held(gpa, golden_root(dialect_of(fixture.name).?), fixture.name, &golden);
        defer golden.deinit(gpa);

        _ = try machine.parse(fixture.source, dialect_of(fixture.name).?);

        if (!try machine.walk_matches(gpa, fixture.source, golden.ast.items)) {
            try report(gpa, &lines, fixture.name, machine.held.items, machine.expected.items);
            std.debug.print("{s}", .{lines.items});

            return error.TestUnexpectedResult;
        }

        compared += 1;
    }

    try require(
        compared >= floor.fixture_walk_typescript,
        "the TypeScript fixtures lost a walk: {d} compared, floor {d}",
        .{ compared, floor.fixture_walk_typescript },
    );
}

test "the statement census matches the corpus goldens" {
    const gpa = std.testing.allocator;
    const held = corpus.named(.golden) orelse return;
    var found = try corpus_fixtures(gpa);
    defer found.deinit(gpa);

    if (found.slice().len == 0) return;

    var carried = try oracle.residue_of(gpa, residue_name, &every_category);
    defer carried.deinit(gpa);

    const counted = try corpus_checked(.census, gpa, &carried, held, found.slice());

    try require(
        counted.compared >= floor.corpus_census_typescript,
        "the corpus lost its TypeScript files: {d} counted, {d} abstained, floor {d}",
        .{ counted.compared, counted.abstained, floor.corpus_census_typescript },
    );
}

test "the normalized walk matches the corpus goldens" {
    const gpa = std.testing.allocator;
    const held = corpus.named(.golden) orelse return;
    var found = try corpus_fixtures(gpa);
    defer found.deinit(gpa);

    if (found.slice().len == 0) return;

    var carried = try oracle.residue_of(gpa, residue_name, &every_category);
    defer carried.deinit(gpa);

    const counted = try corpus_checked(.walk, gpa, &carried, held, found.slice());
    const named: u32 = counted.compared + @as(u32, @intCast(carried.fixtures.items.len));

    try require(
        named >= floor.corpus_walk_typescript,
        "the corpus lost its TypeScript files: {d} named, {d} abstained, floor {d}",
        .{ named, counted.abstained, floor.corpus_walk_typescript },
    );

    try walk_reported(gpa, &carried, held, found.slice(), &counted);
}

test "every residue row names a file that diverges" {
    const gpa = std.testing.allocator;
    var carried = try oracle.residue_of(gpa, residue_name, &every_category);
    defer carried.deinit(gpa);

    var named: std.ArrayList([]const u8) = .empty;
    defer named.deinit(gpa);

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    var found = try fixtures(gpa);
    defer found.deinit(gpa);

    for (found.slice()) |*fixture| {
        if (!carried.contains(fixture.name)) continue;

        try named.append(gpa, fixture.name);

        try require(
            try diverges(gpa, machine, golden_root(dialect_of(fixture.name).?), fixture),
            "{s} matches its golden and needs no residue row",
            .{fixture.name},
        );
    }

    const held = corpus.named(.golden) orelse return;
    var found_corpus = try corpus_fixtures(gpa);
    defer found_corpus.deinit(gpa);

    for (found_corpus.slice()) |*fixture| {
        if (!carried.contains(fixture.name)) continue;
        if (!machine.complete(fixture.source, dialect_of(fixture.name).?)) continue;

        try named.append(gpa, fixture.name);

        try require(
            try diverges(gpa, machine, held, fixture),
            "{s} matches its corpus golden and needs no residue row",
            .{fixture.name},
        );
    }

    for (carried.fixtures.items) |name| {
        try require(
            names_contain(named.items, name),
            "the residue names `{s}` and neither the fixtures nor the corpus carry it",
            .{name},
        );
    }
}
