const std = @import("std");
const assert = std.debug.assert;
const PRNG = @import("../testing/prng.zig");
const fuzz = @import("../testing/fuzz.zig");
const markup = @import("markup.zig");
const walk = @import("tree.zig").walk;
const Blocks = markup.Document.Blocks;
const Document = markup.Document;
const Token = markup.Token;
const Tree = markup.Document.Tree;
const Vocabulary = markup.Vocabulary;

const Harness = struct {
    capacity: Document.Capacity,
    document: Document,

    pub fn init(
        harness: *Harness,
        gpa: std.mem.Allocator,
        capacity: Document.Capacity,
    ) std.mem.Allocator.Error!void {
        assert(capacity.node_count_max > 0);
        assert(capacity.token_count_max > 0);

        harness.capacity = capacity;
        harness.document = try .init(gpa, capacity);

        assert(harness.document.node_count() == 0);
        assert(harness.document.tokens().len == 0);
    }

    pub fn deinit(harness: *Harness, gpa: std.mem.Allocator) void {
        assert(harness.capacity.token_count_max > 0);
        assert(harness.document.tokens().len <= harness.capacity.token_count_max);

        harness.document.deinit(gpa);
        harness.* = undefined;
    }

    pub fn check(harness: *Harness, source: []const u8) void {
        assert(harness.capacity.token_count_max > 0);
        assert(source.len <= std.math.maxInt(u32));

        if (source.len > std.math.maxInt(u32)) return;

        const parsed = harness.document.parse(source, &vocabulary);

        const complete = if (parsed) |_| true else |err| switch (err) {
            error.TokensExhausted => false,
            error.BlockDepthExceeded => true,
            error.DepthExceeded => true,
            error.DiagnosticsExhausted => true,
            error.IntermediatesExhausted => true,
            error.NodesExhausted => true,
            error.TagsExhausted => true,
        };

        const tokens = harness.document.tokens();
        const tree = harness.document.tree();

        tiles(source, tokens, complete);
        links_hold(tree);
        walk_holds(tree);
        nodes_hold(tree, tokens, source);
        blocks_hold(harness.document.blocks(), source);

        const errors = harness.document.diagnostics();

        assert(errors.len <= harness.capacity.diagnostic_count_max);

        for (errors) |held| {
            assert(held.span.end() <= source.len);
            assert(held.name.end() <= source.len);
        }
    }
};

const capacity_default: Document.Capacity = .{
    .diagnostic_count_max = 1 << 10,
    .node_count_max = 1 << 17,
    .tag_count_max = 1 << 13,
    .token_count_max = 1 << 18,
};

const capacity_starved: Document.Capacity = .{
    .diagnostic_count_max = 4,
    .node_count_max = 64,
    .tag_count_max = 4,
    .token_count_max = 96,
};

const raw_text_tags = [_]Vocabulary.RawTextTag{
    .{ .body = .text, .end = "endraw", .name = "raw", .stage = .lexer },
};

const specifications = [_]Vocabulary.TagSpecification{
    .{ .intermediates = &.{"empty"}, .name = "for" },
    .{ .intermediates = &.{"else"}, .name = "if" },
};

const vocabulary: Vocabulary = .{
    .dialect = .html,
    .end_prefix = "end",
    .extends_tags = &.{},
    .intermediate_words = &.{ "else", "empty" },
    .only_word = null,
    .raw_text_tags = &raw_text_tags,
    .specifications = &specifications,
    .template_imports = &.{},
};

const atoms = [_][]const u8{
    "{% if a %}",
    "{% else %}",
    "{% endif %}",
    "{% for x in y %}",
    "{% empty %}",
    "{% endfor %}",
    "{% raw %}",
    "{% endraw %}",
    "{% block b %}",
    "{% endblock %}",
    "{% include 'c.html' only %}",
    "{{ x }}",
    "{{ x|f:'a' }}",
    "{# c #}",
    "{%",
    "%}",
    "{{",
    "}}",
    "{#",
    "#}",
    "<p>",
    "</p>",
    "<div class=\"a\">",
    "</div>",
    "<br/>",
    "<a href='",
    "'>",
    "</a>",
    "<!-- ",
    " -->",
    "<script>",
    "</script>",
    "<style>",
    "</style>",
    "<textarea>",
    "</textarea>",
    "<!DOCTYPE html>",
    "<![CDATA[",
    "]]>",
    "&amp;",
    "<",
    ">",
    "/",
    "=",
    "\"",
    "'",
    "a",
    " ",
    "\n",
    "\xff",
};

const atom_count_max = 1_024;
const atom_bytes_max = 32;
const event_count_default = 512;
const source_bytes_max = atom_count_max * atom_bytes_max;

comptime {
    for (atoms) |atom| {
        assert(atom.len > 0);
        assert(atom.len <= atom_bytes_max);
    }
}

pub fn main(gpa: std.mem.Allocator, args: fuzz.Arguments) !void {
    if (args.events_max) |events_max| assert(events_max > 0);

    var prng: PRNG = .init(args.seed);
    const event_count = args.events_max orelse event_count_default;
    const source_buffer = try gpa.alloc(u8, source_bytes_max);
    defer gpa.free(source_buffer);

    const plenty = try gpa.create(Harness);
    defer gpa.destroy(plenty);

    try plenty.init(gpa, capacity_default);
    defer plenty.deinit(gpa);

    const starved = try gpa.create(Harness);
    defer gpa.destroy(starved);

    try starved.init(gpa, capacity_starved);
    defer starved.deinit(gpa);

    for (0..event_count) |_| {
        const source = source_generate(&prng, source_buffer);

        plenty.check(source);
        starved.check(source);
    }
}

fn source_generate(prng: *PRNG, buffer: []u8) []const u8 {
    assert(buffer.len == source_bytes_max);

    const atom_count = prng.int_inclusive(u32, atom_count_max);
    var length: usize = 0;

    for (0..atom_count) |_| {
        const atom = atoms[prng.index(atoms.len)];

        @memcpy(buffer[length..][0..atom.len], atom);
        length += atom.len;
    }

    assert(length <= buffer.len);

    return buffer[0..length];
}

fn blocks_hold(map: *const Blocks, source: []const u8) void {
    assert(source.len <= std.math.maxInt(u32));

    const end: u32 = @intCast(source.len);
    var offset_previous: u32 = 0;
    var end_previous: u32 = 0;

    for (map.block_slice()) |*block| {
        assert(block.span.end() <= end);
        assert(block.span.offset >= offset_previous);
        if (block.span.offset == offset_previous) assert(block.span.end() >= end_previous);
        assert(block.open.span.end() <= end);
        if (block.close) |close| assert(close.span.end() <= end);
        assert(block.open.span.offset == block.span.offset);
        assert(map.intermediates_of(block).len == block.intermediate_count);

        offset_previous = block.span.offset;
        end_previous = block.span.end();
    }

    for (map.tag_slice()) |tag| assert(tag.span.end() <= end);
}

fn links_hold(tree: *const Tree) void {
    const node_count = tree.count();

    for (0..node_count) |index| {
        const node: u32 = @intCast(index);

        if (tree.child_first_of(node)) |child| assert(child < node_count);
        if (tree.parent_of(node)) |parent| assert(parent < node_count);
        if (tree.sibling_next_of(node)) |sibling| assert(sibling < node_count);
    }
}

fn nodes_hold(tree: *const Tree, tokens: []const Token, source: []const u8) void {
    assert(tokens.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));

    for (0..tree.count()) |position| {
        const index: u32 = @intCast(position);
        const node = tree.at(index);

        assert(node.token_start <= node.token_end);
        assert(node.token_end <= tokens.len);

        const span = node.span(Token, tokens);

        assert(span.end() <= source.len);

        if (tree.parent_of(index)) |parent| {
            const outer = tree.at(parent).span(Token, tokens);

            assert(outer.offset <= span.offset);
            assert(span.end() <= outer.end());
        }
    }
}

fn tiles(source: []const u8, tokens: []const Token, complete: bool) void {
    assert(tokens.len <= std.math.maxInt(u32));

    var end_previous: u32 = 0;

    for (tokens) |token| {
        assert(token.offset == end_previous);
        assert(token.length > 0);

        end_previous = token.end();
    }

    assert(end_previous <= source.len);

    if (complete) assert(end_previous == source.len);
}

fn walk_holds(tree: *const Tree) void {
    var steps = walk(Tree, tree);
    var step_count: u32 = 0;

    for (0..steps.step_max) |_| {
        const step = steps.next() orelse break;

        switch (step) {
            .enter, .leave => |node| assert(node < tree.count()),
        }

        step_count += 1;
    }

    assert(step_count == 2 * tree.count());
}

test "a harness accepts a paired template" {
    const gpa = std.testing.allocator;
    var harness: Harness = undefined;

    try harness.init(gpa, .{
        .diagnostic_count_max = 1 << 4,
        .node_count_max = 1 << 10,
        .tag_count_max = 1 << 6,
        .token_count_max = 1 << 10,
    });

    defer harness.deinit(gpa);

    harness.check(
        "{% if a %}<p>{% raw %}{{ x }}{% endraw %}</p>{% else %}b{% endif %}<div>",
    );

    harness.check("{% endif %}{% for %}<!-- ");
    harness.check("");
}

test "a markup fuzz run holds its invariants" {
    try main(std.testing.allocator, .{ .seed = 42, .events_max = 8 });
}
