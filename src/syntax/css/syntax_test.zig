const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const EventsType = @import("../tree.zig").EventsType;
const Kind = @import("kind.zig").Kind;
const Parser = @import("parse.zig").Parser;
const Random = @import("../../testing/random.zig");
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
            error.Truncated => return false,
        };

        raw_of(Kind, machine.tokens.slice(), &machine.raw) catch |err| switch (err) {
            error.Truncated => return false,
        };

        assert(machine.raw.count() == machine.tokens.count());

        return true;
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

            if (node.kind == .stylesheet) {
                try machine.held.append(gpa, .{ .name = name, .offset = 0, .end = length });

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

        assert(std.mem.findScalar(Kind, &kinds, .stylesheet) == null);

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
    invariants,
    tokens,
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

const Escape = struct {
    source: []const u8,
    kind: []const u8,
    name: []const u8,
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

const alphabet = "abc-_09 \t\n\r(){}[]:;,.#@!%&*+/<>=~^|$?'\"\\mediahoverpxcalcurl" ++
    "\x00\xff\xc3\xa9";

const diagnostic_count_max: u32 = 0x0000_0400;
const event_count_max: u32 = 0x000C_0000;
const every_category = [_][]const u8{ "grammar", "not-css", "shape" };
const file_count_max: u32 = 1 << 20;
const fixture_root = "tests/fixtures/css";
const golden_root = "tests/fixtures/golden-css";
const node_count_max: u32 = 0x0004_0000;
const none: u32 = std.math.maxInt(u32);
const not_css = [_][]const u8{"not-css"};
const raw_count_max: u32 = 0x0004_0000;
const report_lines_max: u32 = 24;
const report_shown_max: u32 = 3;
const residue_name = "residue-css.json";
const skipped = [_]Kind{.error_node};
const soup_bytes_max: u32 = 512;
const soup_round_count: u32 = 512;
const source_bytes_max: u32 = 1 << 24;
const suite = "syntax_css";
const token_count_max: u32 = 0x0004_0000;

const statements = [_][]const u8{
    "at_rule",
    "block",
    "call_expression",
    "class_selector",
    "declaration",
    "descendant_selector",
    "feature_query",
    "id_selector",
    "media_statement",
    "plain_value",
    "property_name",
    "pseudo_class_selector",
    "rule_set",
    "selectors",
    "tag_name",
};

const unrepresented = [_][]const u8{ "comment", "escape_sequence", "js_comment", "string_content" };

fn corpus_fixtures(gpa: std.mem.Allocator) !corpus.Files {
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
            assert((shared.golden == null) == (check == .tokens or check == .invariants));

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
            if (!machine.complete(fixture.source)) return;

            switch (check) {
                .census => {
                    const root = worker.shared.golden.?;

                    switch (try census_against_corpus(worker.gpa, machine, root, fixture)) {
                        .abstained => counted.abstained += 1,
                        .compared => counted.compared += 1,
                    }
                },
                .tokens => {
                    try require(machine.run(fixture.source), "{s} overran", .{fixture.name});

                    for (machine.raw.const_slice(), 0..) |kind, position| {
                        try require(
                            kind != .error_token,
                            "{s} lexes token {d} to an ErrorToken",
                            .{ fixture.name, position },
                        );
                    }

                    try gaps_are_blank(fixture.source, machine.tokens.slice(), fixture.name);
                    try tally.agree(suite, "classify", fixture.name);
                    counted.compared += 1;
                },
                .invariants => {
                    _ = try machine.parse(fixture.source);

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
        if (!machine.complete(fixture.source)) continue;

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
    if (!machine.run(fixture.source)) return true;
    if (std.mem.findScalar(Kind, machine.raw.const_slice(), .error_token) != null) return true;

    _ = try machine.parse(fixture.source);

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

    var golden: oracle.Golden = undefined;
    if (!try oracle.golden(gpa, root, fixture.name, &golden)) return .abstained;
    defer golden.deinit(gpa);

    assert(root.len > 0);

    assert(fixture.name.len > 0);

    if (golden.broken) return .abstained;

    _ = try machine.parse(fixture.source);

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

        if (std.mem.eql(u8, row.name, "stylesheet")) {
            try found.append(gpa, .{ .name = row.name, .offset = 0, .end = length });

            continue;
        }

        if (row.offset >= row.end) continue;

        try found.append(gpa, .{
            .name = row.name,
            .offset = row.offset,
            .end = trimmed(source, comments.items, row.offset, row.end),
        });
    }

    std.mem.sort(Row, found.items, {}, Row.less_than);

    assert(found.items.len <= rows.len);
    if (found.items.len > 0) assert(found.items[0].offset <= found.items[0].end);
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
    assert(comments.len <= std.math.maxInt(u32));
    assert(offset < end);

    var held = end;

    assert(end <= source.len);

    for (0..comments.len + 1) |_| {
        held = blank_trimmed(source, offset, held);

        const comment = comment_across(comments, offset, held) orelse break;

        held = comment.offset;
    }

    assert(held >= offset);
    assert(held <= end);

    return held;
}

fn blank_trimmed(source: []const u8, offset: u32, end: u32) u32 {
    assert(offset <= end);

    var held = end;

    assert(end <= source.len);

    for (0..end - offset) |_| {
        if (held <= offset) break;
        if (!std.ascii.isWhitespace(source[held - 1])) break;

        held -= 1;
    }

    assert(held >= offset);

    return held;
}

fn comment_across(comments: []const Range, offset: u32, held: u32) ?Range {
    assert(offset <= held);
    assert(comments.len <= std.math.maxInt(u32));

    for (comments) |comment| {
        if (comment.end != held) continue;
        if (comment.offset <= offset) continue;
        return comment;
    }

    return null;
}

fn is_comment(name: []const u8) bool {
    assert(name.len > 0);
    assert(name.len < std.math.maxInt(u32));

    if (std.mem.eql(u8, name, "comment")) return true;
    return std.mem.eql(u8, name, "js_comment");
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

fn escape_named(rows: []const Row, case: Escape) bool {
    assert(case.kind.len > 0);
    assert(case.name.len > 0);
    assert(rows.len <= std.math.maxInt(u32));

    for (rows) |row| {
        if (!std.mem.eql(u8, row.name, case.kind)) continue;
        if (std.mem.eql(u8, case.source[row.offset..row.end], case.name)) return true;
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

test "the lexer is total over the fixtures" {
    const gpa = std.testing.allocator;
    var found = try fixtures(gpa);
    defer found.deinit(gpa);

    try require(found.slice().len > 0, "{s} holds no source", .{fixture_root});

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    for (found.slice()) |*fixture| {
        try require(machine.run(fixture.source), "{s} overran", .{fixture.name});

        const errors = std.mem.countScalar(Kind, machine.raw.const_slice(), .error_token);

        try require(errors == 0, "{s} lexes to an ErrorToken", .{fixture.name});
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

test "the lexer is total on byte soup" {
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

test "the lexer runs the corpus without an unclaimed byte" {
    const gpa = std.testing.allocator;
    var found = try corpus_fixtures(gpa);
    defer found.deinit(gpa);

    if (found.slice().len == 0) return;

    var carried = try oracle.residue_of(gpa, residue_name, &not_css);
    defer carried.deinit(gpa);

    const counted = try corpus_checked(.tokens, gpa, &carried, null, found.slice());

    try require(
        counted.compared >= floor.corpus_classify_css,
        "the corpus lost its CSS files: {d} classified, floor {d}",
        .{ counted.compared, floor.corpus_classify_css },
    );
}

test "the tree holds its invariants over the corpus" {
    const gpa = std.testing.allocator;
    var found = try corpus_fixtures(gpa);
    defer found.deinit(gpa);

    if (found.slice().len == 0) return;

    var carried = try oracle.residue_of(gpa, residue_name, &not_css);
    defer carried.deinit(gpa);

    _ = try corpus_checked(.invariants, gpa, &carried, null, found.slice());
}

test "a pseudo element without a name is an error" {
    const gpa = std.testing.allocator;
    const sources = [_][]const u8{ "::;", "::;z:;" };

    const named = [_][]const u8{
        "a::before {\n    color: red;\n}\n",
        "p::first-line {\n    color: red;\n}\n",
        "a::-moz-selection {\n    color: red;\n}\n",
    };

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    for (sources) |source| {
        _ = try machine.parse(source);

        try require(
            machine.tree.diagnostic_slice().len > 0,
            "\"{s}\" parsed without an error",
            .{source},
        );
    }

    for (named) |source| {
        try std.testing.expectEqual(Structure.complete, try machine.parse(source));

        try require(
            machine.tree.diagnostic_slice().len == 0,
            "\"{s}\" reported an error",
            .{source},
        );
    }
}

test "an escape continues the name it stands in" {
    const gpa = std.testing.allocator;

    const cases = [_]Escape{
        .{
            .source = "#workbench\\.editor\\.settings2:focus {}\n",
            .kind = "id_name",
            .name = "workbench\\.editor\\.settings2",
        },
        .{
            .source = "img[src$=\\#gh-light-mode-only] {}\n",
            .kind = "plain_value",
            .name = "\\#gh-light-mode-only",
        },
        .{
            .source = "a { font-family: Font Awesome\\ 5 Brands; }\n",
            .kind = "plain_value",
            .name = "Awesome\\ 5",
        },
        .{
            .source = "a { font-family: \\5FAE\\8F6F, Arial; }\n",
            .kind = "plain_value",
            .name = "\\5FAE\\8F6F",
        },
        .{ .source = ".\\31 0 {}\n", .kind = "class_name", .name = "\\31 0" },
        .{ .source = "\\31 0 {}\n", .kind = "tag_name", .name = "\\31 0" },
    };

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    for (cases) |case| {
        try std.testing.expectEqual(Structure.complete, try machine.parse(case.source));

        try require(
            machine.tree.diagnostic_slice().len == 0,
            "\"{s}\" reported an error",
            .{case.source},
        );

        try machine.walk(gpa, @intCast(case.source.len));

        try require(
            escape_named(machine.held.items, case),
            "\"{s}\" holds no {s} over \"{s}\"",
            .{ case.source, case.kind, case.name },
        );
    }
}

test "a keyframes name may open with an escape" {
    const gpa = std.testing.allocator;
    const source = "@keyframes \\@mymove {\n    from {\n        top: 0;\n    }\n}\n";
    const case: Escape = .{ .source = source, .kind = "keyframes_name", .name = "\\@mymove" };
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    try std.testing.expectEqual(Structure.complete, try machine.parse(source));
    try require(machine.tree.diagnostic_slice().len == 0, "\"{s}\" reported an error", .{source});
    try machine.walk(gpa, @intCast(source.len));
    try require(escape_named(machine.held.items, case), "\"{s}\" names no keyframes", .{source});
}

test "a namespaced attribute name holds its prefix and its name" {
    const gpa = std.testing.allocator;
    const source = "[foo|att=val] {}\n[*|att] {}\n[|att] {}\n[att] {}\n";
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    try std.testing.expectEqual(Structure.complete, try machine.parse(source));
    try require(machine.tree.diagnostic_slice().len == 0, "\"{s}\" reported an error", .{source});
    try machine.walk(gpa, @intCast(source.len));

    var tags: std.ArrayList([]const u8) = .empty;
    defer tags.deinit(gpa);

    var universal_count: u32 = 0;

    for (machine.held.items) |row| {
        const text = source[row.offset..row.end];

        if (std.mem.eql(u8, row.name, "tag_name")) {
            try tags.append(gpa, text);
        }

        if (std.mem.eql(u8, row.name, "universal_selector")) {
            try std.testing.expectEqualStrings("*", text);

            universal_count += 1;
        }
    }

    try std.testing.expectEqual(1, universal_count);
    try std.testing.expectEqual(4, tags.items.len);
    try std.testing.expectEqualStrings("foo", tags.items[0]);

    for (tags.items[1..]) |tag| {
        try std.testing.expectEqualStrings("att", tag);
    }
}

test "a plain value ends at a multi byte space" {
    const gpa = std.testing.allocator;
    const sources = [_][]const u8{ "a:i:\u{feff}:", "a:i: :" };
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    for (sources) |source| {
        _ = try machine.parse(source);

        try require(
            machine.tree.diagnostic_slice().len > 0,
            "\"{s}\" parsed without an error",
            .{source},
        );
    }
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

        try golden_held(gpa, golden_root, fixture.name, &golden);
        defer golden.deinit(gpa);

        try require(!golden.broken, "{s} does not parse", .{fixture.name});

        const outcome = try machine.parse(fixture.source);

        try require(outcome == .complete, "{s}", .{fixture.name});
        try census_matches(machine, golden.ast.items, fixture.name);

        compared += 1;
    }

    try require(compared == found.slice().len, "a fixture went uncompared", .{});
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

        try golden_held(gpa, golden_root, fixture.name, &golden);
        defer golden.deinit(gpa);

        _ = try machine.parse(fixture.source);

        if (!try machine.walk_matches(gpa, fixture.source, golden.ast.items)) {
            try report(gpa, &lines, fixture.name, machine.held.items, machine.expected.items);
            std.debug.print("{s}", .{lines.items});

            return error.TestUnexpectedResult;
        }

        compared += 1;
    }

    try require(
        compared >= floor.fixture_walk_css,
        "the CSS fixtures lost a walk: {d} compared, floor {d}",
        .{ compared, floor.fixture_walk_css },
    );
}

test "the statement census matches the corpus goldens" {
    const gpa = std.testing.allocator;
    const held = corpus.named(.golden) orelse return;
    var found = try corpus_fixtures(gpa);
    defer found.deinit(gpa);

    if (found.slice().len == 0) return;

    var carried = try oracle.residue_of(gpa, residue_name, &not_css);
    defer carried.deinit(gpa);

    const counted = try corpus_checked(.census, gpa, &carried, held, found.slice());

    try require(
        counted.compared >= floor.corpus_census_css,
        "the corpus lost its CSS files: {d} counted, {d} abstained, floor {d}",
        .{ counted.compared, counted.abstained, floor.corpus_census_css },
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
        named >= floor.corpus_walk_css,
        "the corpus lost its CSS files: {d} named, {d} abstained, floor {d}",
        .{ named, counted.abstained, floor.corpus_walk_css },
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
            try diverges(gpa, machine, golden_root, fixture),
            "{s} matches its golden and needs no residue row",
            .{fixture.name},
        );
    }

    const held = corpus.named(.golden) orelse return;
    var found_corpus = try corpus_fixtures(gpa);
    defer found_corpus.deinit(gpa);

    for (found_corpus.slice()) |*fixture| {
        if (!carried.contains(fixture.name)) continue;
        if (!machine.complete(fixture.source)) continue;

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

test "a syntax error names the kind it found" {
    const gpa = std.testing.allocator;
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    _ = try machine.parse("a { color; }");

    try std.testing.expect(machine.tree.diagnostic_slice().len > 0);

    const held = machine.tree.diagnostic_slice()[0];

    try std.testing.expectEqual(null, held.expected_kind(Kind));
    try std.testing.expectEqual(Kind.semicolon, held.found_kind(Kind).?);
}
