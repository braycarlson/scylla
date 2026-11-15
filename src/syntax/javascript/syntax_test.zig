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

    fn complete(machine: *Machine, source: []const u8) bool {
        assert(source.len <= std.math.maxInt(u32));

        machine.tokens.clear();

        lex(source, &machine.tokens, .javascript) catch |err| switch (err) {
            error.Truncated => return false,
        };

        assert(!machine.tokens.items.full() or machine.tokens.count() > 0);

        return true;
    }

    fn run(machine: *Machine, source: []const u8) bool {
        assert(source.len <= std.math.maxInt(u32));

        machine.tokens.clear();

        lex(source, &machine.tokens, .javascript) catch |err| switch (err) {
            error.Truncated => assert(machine.tokens.items.full()),
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

        if (machine.tokens.items.full()) {
            return machine.parser.build(
                source,
                machine.tokens.slice(),
                machine.raw.const_slice(),
                &machine.events,
                &machine.tree,
                .{ .dialect = .javascript, .goal = .module },
            );
        }

        return relex.build(
            &machine.parser,
            source,
            .{ .raw = &machine.raw, .tokens = &machine.tokens },
            &machine.events,
            &machine.tree,
            .{ .dialect = .javascript, .goal = .module },
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
const event_count_max: u32 = 0x000C_0000;
const every_category = [_][]const u8{ "jsx", "not-javascript", "shape" };
const extensions = [_][]const u8{ ".cjs", ".js", ".mjs" };
const file_count_max: u32 = 1 << 20;
const fixture_root = "tests/fixtures/javascript";
const golden_root = "tests/fixtures/golden-javascript";
const node_count_max: u32 = 0x0004_0000;
const none: u32 = std.math.maxInt(u32);
const not_javascript = [_][]const u8{ "jsx", "not-javascript" };
const raw_count_max: u32 = 0x0004_0000;
const report_lines_max: u32 = 24;
const report_shown_max: u32 = 3;
const residue_name = "residue-javascript.json";
const skipped = [_]Kind{.error_node};
const soup_bytes_max: u32 = 512;
const soup_round_count: u32 = 512;
const source_bytes_max: u32 = 1 << 24;
const suite = "syntax_javascript";
const token_count_max: u32 = 0x0004_0000;

const statements = [_][]const u8{
    "break_statement",
    "class_declaration",
    "continue_statement",
    "debugger_statement",
    "do_statement",
    "empty_statement",
    "export_statement",
    "expression_statement",
    "for_in_statement",
    "for_statement",
    "function_declaration",
    "generator_function_declaration",
    "if_statement",
    "import_statement",
    "labeled_statement",
    "lexical_declaration",
    "return_statement",
    "statement_block",
    "switch_statement",
    "throw_statement",
    "try_statement",
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

fn corpus_fixtures(gpa: std.mem.Allocator) !corpus.Files {
    const root = corpus.named(.root) orelse return .{ .list = .empty };
    const found = try corpus.collect(gpa, root, source_bytes_max, corpus_selected);

    assert(root.len > 0);
    assert(found.slice().len <= file_count_max);

    return found;
}

fn corpus_selected(basename: []const u8) bool {
    assert(basename.len > 0);

    return is_javascript(basename);
}

fn fixtures(gpa: std.mem.Allocator) !corpus.Files {
    const found = try corpus.collect(gpa, fixture_root, source_bytes_max, corpus_selected);

    assert(found.slice().len <= file_count_max);
    if (found.slice().len > 1) assert(Fixture.less_than({}, found.slice()[0], found.slice()[1]));

    return found;
}

fn is_javascript(basename: []const u8) bool {
    assert(basename.len > 0);

    const extension = std.Io.Dir.path.extension(basename);

    assert(extensions.len == 3);

    for (extensions) |held| {
        if (std.mem.eql(u8, extension, held)) return true;
    }

    return false;
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
            if (!machine.complete(fixture.source)) return;

            switch (check) {
                .census => {
                    const root = worker.shared.golden.?;

                    switch (try census_against_corpus(worker.gpa, machine, root, fixture)) {
                        .abstained => counted.abstained += 1,
                        .compared => counted.compared += 1,
                    }
                },
                .classify => {
                    try require(machine.run(fixture.source), "{s} overran", .{fixture.name});

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

fn verdicts_hold(
    machine: *Machine,
    sources: []const []const u8,
    valid: []const []const u8,
) !void {
    assert(sources.len > 0);
    assert(valid.len > 0);

    for (sources) |source| {
        _ = try machine.parse(source);

        try require(
            machine.tree.diagnostic_slice().len > 0,
            "\"{s}\" parsed without an error",
            .{source},
        );
    }

    for (valid) |source| {
        try std.testing.expectEqual(Structure.complete, try machine.parse(source));

        try require(
            machine.tree.diagnostic_slice().len == 0,
            "\"{s}\" parsed with an error",
            .{source},
        );
    }
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

    var carried = try oracle.residue_of(gpa, residue_name, &not_javascript);
    defer carried.deinit(gpa);

    const counted = try corpus_checked(.classify, gpa, &carried, null, found.slice());

    try require(
        counted.compared >= floor.corpus_classify_javascript,
        "the corpus lost its JavaScript files: {d} classified, floor {d}",
        .{ counted.compared, floor.corpus_classify_javascript },
    );
}

test "the tree holds its invariants over the corpus" {
    const gpa = std.testing.allocator;
    var found = try corpus_fixtures(gpa);
    defer found.deinit(gpa);

    if (found.slice().len == 0) return;

    var carried = try oracle.residue_of(gpa, residue_name, &not_javascript);
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

test "an import attribute follows the module string" {
    const gpa = std.testing.allocator;
    const source = "import held from \"./held.json\" with { type: \"json\" };\n";
    const length: u32 = @intCast(source.len);
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    try std.testing.expectEqual(Structure.complete, try machine.parse(source));
    try machine.walk(gpa, length);

    const attribute: Row = .{ .name = "import_attribute", .offset = 31, .end = 52 };

    try require(walk_contains(machine.held.items, attribute), "{any}", .{machine.held.items});
}

test "a stray error token at the top level does not end the program" {
    const gpa = std.testing.allocator;
    const source = "\\;\nfunction walk(n) {\n    walk(n);\n}\n";
    const length: u32 = @intCast(source.len);
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    _ = try machine.parse(source);

    try machine.walk(gpa, length);

    const walked = machine.held.items;

    try require(walk_names(walked, "function_declaration"), "{any}", .{walked});
}

test "a backslash outside a unicode escape is an error" {
    const gpa = std.testing.allocator;
    const sources = [_][]const u8{ "/\\/~", "a\\b", "\\" };
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

    const escaped = "let \\u0041 = 1;\n";

    try std.testing.expectEqual(Structure.complete, try machine.parse(escaped));
    try std.testing.expectEqual(@as(usize, 0), machine.tree.diagnostic_slice().len);
}

test "an operator owed an operand or a group left open is an error" {
    const gpa = std.testing.allocator;

    const sources = [_][]const u8{
        "x=",
        "a+",
        "+",
        "&x",
        "return&x",
        "x=>",
        "x=>,",
        "a?:b",
        "import.",
        "import.=",
        "(a",
        "[a",
        "f(a",
        "x={a:1",
        "`a",
        "`a${b",
    };

    const valid = [_][]const u8{
        "function* g() {\n    yield;\n}\n",
        "x = import.meta;\n",
        "a = `b${c}d`;\n",
        "f(a)(b);\n",
        "x = (a) => ({ b: 1 });\n",
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

    for (valid) |source| {
        try std.testing.expectEqual(Structure.complete, try machine.parse(source));

        try require(
            machine.tree.diagnostic_slice().len == 0,
            "\"{s}\" parsed with an error",
            .{source},
        );
    }
}

test "a with statement after a module string stays a statement" {
    const gpa = std.testing.allocator;
    const source = "import held from \"./held\"\nwith (held) {}\n";
    const length: u32 = @intCast(source.len);
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    try std.testing.expectEqual(Structure.complete, try machine.parse(source));
    try machine.walk(gpa, length);

    const walked = machine.held.items;

    try require(walk_names(walked, "with_statement"), "{any}", .{walked});
    try require(!walk_names(walked, "import_attribute"), "{any}", .{walked});
}

test "a semicolon after an exported declaration is a statement of its own" {
    const gpa = std.testing.allocator;
    const source = "export function f() {}\n;\nexport default function () {}\n;\n";
    const length: u32 = @intCast(source.len);
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    try std.testing.expectEqual(Structure.complete, try machine.parse(source));
    try machine.walk(gpa, length);

    const walked = machine.held.items;
    const declared: Row = .{ .name = "export_statement", .offset = 0, .end = 22 };
    const emptied: Row = .{ .name = "empty_statement", .offset = 23, .end = 24 };
    const trailed: Row = .{ .name = "export_statement", .offset = 25, .end = 56 };

    try require(walk_contains(walked, declared), "{any}", .{walked});
    try require(walk_contains(walked, emptied), "{any}", .{walked});
    try require(walk_contains(walked, trailed), "{any}", .{walked});
}

test "a parameter spelled undefined is an undefined pattern and a declarator name is not" {
    const gpa = std.testing.allocator;
    const source = "function f(undefined) {}\nvar undefined;\ntry {} catch (undefined) {}\n";
    const length: u32 = @intCast(source.len);
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    try std.testing.expectEqual(Structure.complete, try machine.parse(source));
    try machine.walk(gpa, length);

    const walked = machine.held.items;
    const parameter: Row = .{ .name = "undefined", .offset = 11, .end = 20 };
    const declared: Row = .{ .name = "identifier", .offset = 29, .end = 38 };
    const caught: Row = .{ .name = "identifier", .offset = 54, .end = 63 };

    try require(walk_contains(walked, parameter), "{any}", .{walked});
    try require(walk_contains(walked, declared), "{any}", .{walked});
    try require(walk_contains(walked, caught), "{any}", .{walked});
}

test "a member of a literal is an assignment target and never a binding" {
    const gpa = std.testing.allocator;

    const sources = [_][]const u8{
        "let [{ a: 1 }.b] = x;\n",
        "let { c: [1][0] } = x;\n",
        "let [a.b] = x;\n",
        "let { ...a.b } = x;\n",
        "function f(a.b) {}\n",
        "function g([a.b]) {}\n",
        "try {} catch ({ a: b.c }) {}\n",
        "for (const [a.b] of x);\n",
    };

    const valid = [_][]const u8{
        "[[1, 2][0], { a }.a] = x;\n",
        "({ a: { b: 1 }.b = 2 } = x);\n",
        "({ ...a.b } = x);\n",
        "for ({ a: { b: 1 }.b } of x);\n",
        "({ options: { set value(o) {} }.value } = x);\n",
    };

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    try verdicts_hold(machine, &sources, &valid);

    const source = valid[valid.len - 1];
    const length: u32 = @intCast(source.len);

    try machine.walk(gpa, length);

    const walked = machine.held.items;
    const target: Row = .{ .name = "member_expression", .offset = 12, .end = 37 };

    try require(walk_contains(walked, target), "{any}", .{walked});
    try require(walk_names(walked, "method_definition"), "{any}", .{walked});
}

test "a try statement owes a catch or a finally clause" {
    const gpa = std.testing.allocator;

    const sources = [_][]const u8{
        "try {}\n",
        "try {} x;\n",
        "function f() {\n    try {\n    }\n}\n",
    };

    const valid = [_][]const u8{
        "try {} catch {}\n",
        "try {} finally {}\n",
        "try {} catch (e) {} finally {}\n",
    };

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    try verdicts_hold(machine, &sources, &valid);
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
        compared >= floor.fixture_walk_javascript,
        "the JavaScript fixtures lost a walk: {d} compared, floor {d}",
        .{ compared, floor.fixture_walk_javascript },
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
        counted.compared >= floor.corpus_census_javascript,
        "the corpus lost its JavaScript files: {d} counted, {d} abstained, floor {d}",
        .{ counted.compared, counted.abstained, floor.corpus_census_javascript },
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
        named >= floor.corpus_walk_javascript,
        "the corpus lost its JavaScript files: {d} named, {d} abstained, floor {d}",
        .{ named, counted.abstained, floor.corpus_walk_javascript },
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

test "a syntax error names the kind it expected and the kind it found" {
    const gpa = std.testing.allocator;
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    _ = try machine.parse("if x) {}");

    try std.testing.expect(machine.tree.diagnostic_slice().len > 0);

    const held = machine.tree.diagnostic_slice()[0];

    try std.testing.expectEqual(Kind.paren_open, held.expected_kind(Kind).?);
    try std.testing.expectEqual(Kind.identifier, held.found_kind(Kind).?);

    const ended_source = "let a =";

    _ = try machine.parse(ended_source);

    try std.testing.expect(machine.tree.diagnostic_slice().len > 0);

    const ended = machine.tree.diagnostic_slice()[0];

    try std.testing.expectEqual(ended_source.len, ended.span.offset);
    try std.testing.expectEqual(0, ended.span.length);

    try std.testing.expectEqual(null, ended.expected_kind(Kind));
    try std.testing.expectEqual(null, ended.found_kind(Kind));
}
