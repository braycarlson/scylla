const std = @import("std");
const assert = std.debug.assert;
const Kind = @import("kind.zig").Kind;
const Random = @import("../../testing/random.zig");
const Token = @import("token.zig").Token;
const Tokens = @import("tokens.zig").Tokens;
const corpus = @import("../../testing/corpus.zig");
const floor = @import("../../testing/floor.zig");
const lexer = @import("lex.zig");
const markup_testing = @import("../testing/markup.zig");
const oracle_names = @import("../testing/names.zig");
const stripe = @import("../../testing/stripe.zig");
const tree = @import("tree.zig");
const Step = @import("../tree.zig").Step;
const Structure = @import("../tree.zig").Structure;
const View = @import("view.zig").View;
const Tree = tree.Tree;

const InvariantsWorker = struct {
    built: Tree,
    tokens: Tokens,

    pub const Item = corpus.File;
    pub const Shared = struct {};
    pub const Tally = struct { compared: u32 };
    pub const weight = corpus.File.weight;

    pub fn init(worker: *InvariantsWorker, gpa: std.mem.Allocator, shared: *const Shared) !void {
        assert(@TypeOf(shared.*) == Shared);

        worker.tokens = try .init(gpa, token_count_max);
        errdefer worker.tokens.deinit(gpa);

        worker.built = try .init(gpa, node_count_max, diagnostic_count_max);

        assert(worker.built.count() == 0);
    }

    pub fn deinit(worker: *InvariantsWorker, gpa: std.mem.Allocator) void {
        assert(worker.tokens.capacity() == token_count_max);

        worker.built.deinit(gpa);
        worker.tokens.deinit(gpa);
        worker.* = undefined;
    }

    pub fn visit(worker: *InvariantsWorker, file: *const corpus.File, tally: *Tally) !void {
        assert(file.name.len > 0);
        assert(file.source.len <= std.math.maxInt(u32));

        lex_and_build(file.source, &worker.tokens, &worker.built);

        try invariants_hold(&worker.built, worker.tokens.slice(), file.name);

        tally.compared += 1;
    }
};

const diagnostic_count_max: u32 = 1 << 10;
const node_count_max: u32 = 1 << 17;
const raw_text_tags = markup_testing.raw_text_tags;
const soup_case_count: u32 = 512;
const soup_length_max: u32 = 256;
const source_bytes_max: u32 = 1 << 28;
const token_count_max: u32 = 1 << 18;

fn lex_and_build(source: []const u8, tokens: *Tokens, built: *Tree) void {
    assert(source.len <= std.math.maxInt(u32));

    lexer.lex_with(source, tokens, &raw_text_tags) catch |err| switch (err) {
        error.Truncated => assert(tokens.end_previous == source.len),
    };

    _ = tree.build(source, tokens.slice(), built);

    assert(built.count() > 0);
}

fn invariants_hold(built: *const Tree, tokens: []const Token, name: []const u8) !void {
    assert(tokens.len <= std.math.maxInt(u32));
    assert(name.len > 0);

    const nodes = built.slice();

    for (nodes, 0..) |node, position| {
        const index: u32 = @intCast(position);
        const span = node.span(Token, tokens);

        try expect_named(node.token_start <= node.token_end, name, index, "runs backwards");
        try expect_named(node.token_end <= tokens.len, name, index, "ends past the stream");

        if (built.parent_of(index)) |parent| {
            const outer = nodes[parent].span(Token, tokens);

            try expect_named(outer.offset <= span.offset, name, index, "starts before its parent");
            try expect_named(span.end() <= outer.end(), name, index, "ends after its parent");
            try expect_named(parent < index, name, index, "names a later parent");
        }

        try children_are_disjoint(built, tokens, name, index);
    }
}

fn children_are_disjoint(
    built: *const Tree,
    tokens: []const Token,
    name: []const u8,
    index: u32,
) !void {
    assert(tokens.len <= std.math.maxInt(u32));
    assert(name.len > 0);
    assert(index < std.math.maxInt(u32));

    var child = built.child_first_of(index);
    var end_previous: u32 = 0;
    var seen: u32 = 0;

    while (child) |held| {
        try expect_named(seen <= built.count(), name, index, "has a sibling cycle");

        const span = built.at(held).span(Token, tokens);

        try expect_named(built.parent_of(held) == index, name, held, "is not its parent's child");
        try expect_named(span.offset >= end_previous, name, held, "overlaps its sibling");

        end_previous = span.end();
        child = built.sibling_next_of(held);
        seen += 1;
    }
}

fn expect_named(held: bool, name: []const u8, index: u32, message: []const u8) !void {
    assert(message.len > 0);
    assert(name.len > 0);
    assert(index < std.math.maxInt(u32));

    if (held) return;

    std.debug.print("{s}: node {d} {s}\n", .{ name, index, message });

    return error.TestUnexpectedResult;
}

fn step_code(step: Step) u64 {
    if (step == .enter) assert(step.enter < std.math.maxInt(u32));
    if (step == .leave) assert(step.leave < std.math.maxInt(u32));

    return switch (step) {
        .enter => |node| @as(u64, node) * 2,
        .leave => |node| @as(u64, node) * 2 + 1,
    };
}

fn walked_codes(gpa: std.mem.Allocator, walk: *tree.Walk, codes: *std.ArrayList(u64)) !void {
    codes.clearRetainingCapacity();

    for (0..walk.step_max) |_| {
        const step = walk.next() orelse break;

        try codes.append(gpa, step_code(step));
    }
}

fn view_walked_codes(gpa: std.mem.Allocator, steps: *View.Walk, codes: *std.ArrayList(u64)) !void {
    codes.clearRetainingCapacity();

    for (0..steps.remaining) |_| {
        const step = steps.next() orelse break;

        const code: Step = switch (step) {
            .enter => |entered| .{ .enter = entered.index },
            .leave => |left| .{ .leave = left.index },
        };

        try codes.append(gpa, step_code(code));
    }

    const steps_next = steps.next();

    assert(steps_next == null);
}

fn reference_order(gpa: std.mem.Allocator, built: *const Tree, order: *std.ArrayList(u64)) !void {
    var stack: std.ArrayList(Step) = .empty;
    defer stack.deinit(gpa);

    var children: std.ArrayList(u32) = .empty;
    defer children.deinit(gpa);

    order.clearRetainingCapacity();

    var node = built.count();

    while (node > 0) {
        node -= 1;

        if (built.parent_of(node) == null) try stack.append(gpa, .{ .enter = node });
    }

    while (stack.pop()) |step| {
        try order.append(gpa, step_code(step));

        const entered = switch (step) {
            .enter => |held| held,
            .leave => continue,
        };

        try stack.append(gpa, .{ .leave = entered });

        children.clearRetainingCapacity();

        var child = built.child_first_of(entered);

        while (child) |held| {
            try children.append(gpa, held);
            child = built.sibling_next_of(held);
        }

        var remaining = children.items.len;

        while (remaining > 0) {
            remaining -= 1;

            try stack.append(gpa, .{ .enter = children.items[remaining] });
        }
    }
}

fn soup_fill(random: *Random, alphabet: []const u8, source: *std.ArrayList(u8)) void {
    assert(alphabet.len > 0);

    const length = random.below(soup_length_max);

    source.clearRetainingCapacity();

    for (0..length) |_| {
        const index = random.below(@intCast(alphabet.len));

        source.appendAssumeCapacity(alphabet[index]);
    }

    assert(source.items.len == length);
}

fn residue_contains(residue: []const []const u8, name: []const u8) bool {
    assert(residue.len <= std.math.maxInt(u32));
    assert(name.len > 0);

    for (residue) |held| {
        if (std.mem.eql(u8, held, name)) return true;
    }

    return false;
}

test "every fixture builds the node walk the oracle recorded" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var tokens: Tokens = try .init(gpa, token_count_max);
    defer tokens.deinit(gpa);

    var built: Tree = try .init(gpa, node_count_max, diagnostic_count_max);
    defer built.deinit(gpa);

    var fixtures = try markup_testing.fixtures_read(gpa);
    defer fixtures.deinit(gpa);

    const residue = try markup_testing.residue_read(arena.allocator(), "residue.json");
    var classified: usize = 0;

    for (fixtures.items) |*fixture| {
        try lexer.lex_with(fixture.source, &tokens, &raw_text_tags);

        const outcome = tree.build(fixture.source, tokens.slice(), &built);

        try std.testing.expectEqual(Structure.complete, outcome);

        if (residue_contains(residue.items, fixture.name)) {
            classified += 1;

            continue;
        }

        const nodes = built.slice();

        if (nodes.len != fixture.tree.len) {
            std.debug.print("{s}: the node counts differ\n", .{fixture.name});
        }

        try std.testing.expectEqual(fixture.tree.len, nodes.len);

        for (nodes, fixture.tree, 0..) |node, row, index| {
            const span = node.span(Token, tokens.slice());
            const named = oracle_names.kind_of(Kind, row.name);
            const kind = named orelse return error.TestUnexpectedResult;
            const same = node.kind == kind and span.offset == row.offset and span.end() == row.end;

            if (!same) {
                const arguments = .{ fixture.name, index, row.name };

                std.debug.print("{s}: node {d} ({s}) differs\n", arguments);
            }

            try std.testing.expectEqual(kind, node.kind);
            try std.testing.expectEqual(row.offset, span.offset);
            try std.testing.expectEqual(row.end, span.end());
        }
    }

    try std.testing.expectEqual(residue.items.len, classified);
}

test "every fixture records the errors the oracle recorded" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var tokens: Tokens = try .init(gpa, token_count_max);
    defer tokens.deinit(gpa);

    var built: Tree = try .init(gpa, node_count_max, diagnostic_count_max);
    defer built.deinit(gpa);

    var fixtures = try markup_testing.fixtures_read(gpa);
    defer fixtures.deinit(gpa);

    const residue = try markup_testing.residue_read(arena.allocator(), "residue.json");

    for (fixtures.items) |*fixture| {
        if (residue_contains(residue.items, fixture.name)) continue;

        lex_and_build(fixture.source, &tokens, &built);

        const found = built.diagnostic_slice();

        if (found.len != fixture.errors.len) {
            std.debug.print("{s}: the error counts differ\n", .{fixture.name});
        }

        try std.testing.expectEqual(fixture.errors.len, found.len);

        for (found, fixture.errors) |held, row| {
            try std.testing.expectEqualStrings(row.name, held.kind.title());
            try std.testing.expectEqual(row.offset, held.span.offset);
        }
    }
}

test "every fixture walks the order the links describe" {
    const gpa = std.testing.allocator;
    var tokens: Tokens = try .init(gpa, token_count_max);
    defer tokens.deinit(gpa);

    var built: Tree = try .init(gpa, node_count_max, diagnostic_count_max);
    defer built.deinit(gpa);

    var fixtures = try markup_testing.fixtures_read(gpa);
    defer fixtures.deinit(gpa);

    var walked: std.ArrayList(u64) = .empty;
    defer walked.deinit(gpa);

    var order: std.ArrayList(u64) = .empty;
    defer order.deinit(gpa);

    var subtree: std.ArrayList(u64) = .empty;
    defer subtree.deinit(gpa);

    for (fixtures.items) |*fixture| {
        lex_and_build(fixture.source, &tokens, &built);

        var walk = tree.walk(&built);

        try walked_codes(gpa, &walk, &walked);
        try reference_order(gpa, &built, &order);

        try std.testing.expectEqualSlices(u64, order.items, walked.items);
        try std.testing.expectEqual(2 * built.count(), walked.items.len);

        for (0..built.count()) |position| {
            const node: u32 = @intCast(position);
            var walk_node = tree.walk_from(&built, node);

            try walked_codes(gpa, &walk_node, &subtree);

            const enter = std.mem.findScalar(u64, walked.items, step_code(.{ .enter = node }));
            const leave = std.mem.findScalar(u64, walked.items, step_code(.{ .leave = node }));

            try std.testing.expect(enter != null);
            try std.testing.expect(leave != null);

            const expected = walked.items[enter.? .. leave.? + 1];

            try std.testing.expectEqualSlices(u64, expected, subtree.items);
        }
    }
}

test "a view walk steps through the subtree the tree walk describes" {
    const gpa = std.testing.allocator;
    var tokens: Tokens = try .init(gpa, token_count_max);
    defer tokens.deinit(gpa);

    var built: Tree = try .init(gpa, node_count_max, diagnostic_count_max);
    defer built.deinit(gpa);

    var fixtures = try markup_testing.fixtures_read(gpa);
    defer fixtures.deinit(gpa);

    var expected: std.ArrayList(u64) = .empty;
    defer expected.deinit(gpa);

    var viewed: std.ArrayList(u64) = .empty;
    defer viewed.deinit(gpa);

    for (fixtures.items) |*fixture| {
        lex_and_build(fixture.source, &tokens, &built);

        for (0..built.count()) |position| {
            const node: u32 = @intCast(position);
            var walk_node = tree.walk_from(&built, node);
            var view_walk = View.init(&built, tokens.slice(), @fromBackingInt(node)).walk();

            try walked_codes(gpa, &walk_node, &expected);
            try view_walked_codes(gpa, &view_walk, &viewed);
            try std.testing.expectEqualSlices(u64, expected.items, viewed.items);
        }
    }
}

test "a parent covers its children and siblings never overlap" {
    const gpa = std.testing.allocator;
    var tokens: Tokens = try .init(gpa, token_count_max);
    defer tokens.deinit(gpa);

    var built: Tree = try .init(gpa, node_count_max, diagnostic_count_max);
    defer built.deinit(gpa);

    var fixtures = try markup_testing.fixtures_read(gpa);
    defer fixtures.deinit(gpa);

    for (fixtures.items) |*fixture| {
        lex_and_build(fixture.source, &tokens, &built);

        try invariants_hold(&built, tokens.slice(), fixture.name);
    }
}

test "every corpus template builds a tree that holds its invariants" {
    const gpa = std.testing.allocator;
    const root = corpus.named(.root) orelse return;
    var files = try corpus.collect(gpa, root, source_bytes_max, markup_testing.template_selected);
    defer files.deinit(gpa);

    if (files.slice().len == 0) return;

    var tally: InvariantsWorker.Tally = .{ .compared = 0 };

    try stripe.run(InvariantsWorker, gpa, &.{}, files.slice(), &tally);

    if (tally.compared < floor.corpus_markup_tree) {
        std.debug.print(
            "{d} corpus templates built, floor {d}\n",
            .{ tally.compared, floor.corpus_markup_tree },
        );
    }

    try std.testing.expect(tally.compared >= floor.corpus_markup_tree);
}

test "byte soup builds a tree that holds its invariants" {
    const gpa = std.testing.allocator;
    const alphabet = "<>/=\"'{}%#|:,. \n\t-!pdivlitroption";
    var random: Random = .init(0x0DDB_1A9F_4C1D_9CF3);
    var tokens: Tokens = try .init(gpa, token_count_max);
    defer tokens.deinit(gpa);

    var built: Tree = try .init(gpa, node_count_max, diagnostic_count_max);
    defer built.deinit(gpa);

    var source: std.ArrayList(u8) = try .initCapacity(gpa, soup_length_max);
    defer source.deinit(gpa);

    var name_buffer: [32]u8 = undefined;

    for (0..soup_case_count) |case| {
        soup_fill(&random, alphabet, &source);

        const name = try std.mem.print(&name_buffer, "soup {d}", .{case});

        lex_and_build(source.items, &tokens, &built);

        try invariants_hold(&built, tokens.slice(), name);
    }
}

test "a starved node budget truncates rather than overrunning" {
    const gpa = std.testing.allocator;
    var fixtures = try markup_testing.fixtures_read(gpa);
    defer fixtures.deinit(gpa);

    var fixture = &fixtures.items[0];

    for (fixtures.items) |*held| {
        if (held.tree.len >= fixture.tree.len) fixture = held;
    }

    var tokens: Tokens = try .init(gpa, token_count_max);
    defer tokens.deinit(gpa);

    var starved: Tree = try .init(gpa, 4, diagnostic_count_max);
    defer starved.deinit(gpa);

    lexer.lex_with(fixture.source, &tokens, &raw_text_tags) catch |err| switch (err) {
        error.Truncated => assert(tokens.end_previous == fixture.source.len),
    };

    const outcome = tree.build(fixture.source, tokens.slice(), &starved);

    try std.testing.expectEqual(Structure{ .truncated = .nodes }, outcome);
    try std.testing.expect(starved.count() <= 4);
}

test "a close tag ends at its trailing solidus" {
    const gpa = std.testing.allocator;
    const source = "<div>a</div/><p>b</p>";
    var tokens: Tokens = try .init(gpa, token_count_max);
    defer tokens.deinit(gpa);

    var built: Tree = try .init(gpa, node_count_max, diagnostic_count_max);
    defer built.deinit(gpa);

    lex_and_build(source, &tokens, &built);

    var close_ends: [2]u32 = @splat(0);
    var close_count: u32 = 0;
    var element_count: u32 = 0;

    for (built.slice()) |node| {
        if (node.kind == .element) element_count += 1;
        if (node.kind != .close_tag) continue;

        try std.testing.expect(close_count < close_ends.len);

        close_ends[close_count] = node.span(Token, tokens.slice()).end();
        close_count += 1;
    }

    try std.testing.expectEqual(0, built.diagnostic_slice().len);
    try std.testing.expectEqual(2, element_count);
    try std.testing.expectEqual(2, close_count);
    try std.testing.expectEqualSlices(u32, &.{ 13, 21 }, &close_ends);
    try invariants_hold(&built, tokens.slice(), "a trailing solidus");
}
