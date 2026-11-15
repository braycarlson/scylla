const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const EventsType = @import("../tree.zig").EventsType;
const Dialect = @import("dialect.zig").Dialect;
const Kind = @import("kind.zig").Kind;
const PRNG = @import("../../testing/prng.zig");
const Parser = @import("parse.zig").Parser;
const Structure = @import("../tree.zig").Structure;
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const Token = @import("../token.zig");
const Tokens = @import("../tokens.zig");
const TreeType = @import("../tree.zig").TreeType;
const fuzz = @import("../../testing/fuzz.zig");
const fuzzing = @import("../testing/fuzzing.zig");
const relex = @import("relex.zig");
const Events = EventsType(Kind);
const Tree = TreeType(Kind);

const Limits = struct {
    diagnostic_count_max: u32,
    event_count_max: u32,
    node_count_max: u32,
    token_count_max: u32,
};

const Run = struct {
    events: Events,
    parser: Parser,
    raw: ArrayType(Kind),
    tokens: Tokens,
    tree: Tree,

    fn init(run: *Run, gpa: std.mem.Allocator, limits: *const Limits) !void {
        try run.events.init(gpa, limits.event_count_max);
        errdefer run.events.deinit(gpa);

        run.raw = try .init(gpa, limits.token_count_max);
        errdefer run.raw.deinit(gpa);

        run.tokens = try .init(gpa, limits.token_count_max);
        errdefer run.tokens.deinit(gpa);

        run.tree = try .init(gpa, limits.node_count_max, limits.diagnostic_count_max);

        assert(run.raw.capacity() == run.tokens.items.capacity());
        assert(run.raw.empty());
    }

    fn deinit(run: *Run, gpa: std.mem.Allocator) void {
        run.tree.deinit(gpa);
        run.tokens.deinit(gpa);
        run.raw.deinit(gpa);
        run.events.deinit(gpa);
    }

    fn parse(run: *Run, source: []const u8, dialect: Dialect) ?Structure {
        assert(source.len <= std.math.maxInt(u32));

        run.tree.clear();
        run.tokens.clear();

        return relex.build(
            &run.parser,
            source,
            .{ .raw = &run.raw, .tokens = &run.tokens },
            &run.events,
            &run.tree,
            .{ .dialect = dialect, .goal = .module },
        ) catch null;
    }
};

const Harness = struct {
    dialect: Dialect,
    limits: Limits,
    first: *Run,
    again: *Run,

    fn init(harness: *Harness, gpa: std.mem.Allocator, limits: Limits, dialect: Dialect) !void {
        assert(limits.token_count_max > 0);
        assert(limits.node_count_max > 0);

        harness.dialect = dialect;
        harness.limits = limits;
        harness.first = try gpa.create(Run);
        errdefer gpa.destroy(harness.first);

        try harness.first.init(gpa, &harness.limits);
        errdefer harness.first.deinit(gpa);

        harness.again = try gpa.create(Run);
        errdefer gpa.destroy(harness.again);

        try harness.again.init(gpa, &harness.limits);
    }

    fn deinit(harness: *Harness, gpa: std.mem.Allocator) void {
        harness.again.deinit(gpa);
        gpa.destroy(harness.again);
        harness.first.deinit(gpa);
        gpa.destroy(harness.first);
    }

    fn check(harness: *Harness, source: []const u8) void {
        assert(source.len <= std.math.maxInt(u32));

        const outcome = harness.first.parse(source, harness.dialect) orelse {
            harness.overflowed(source);

            return;
        };

        const tree = &harness.first.tree;

        tree.verify(Token, harness.first.tokens.slice(), source);

        assert(tree.diagnostic_slice().len <= harness.limits.diagnostic_count_max);

        const repeated = harness.again.parse(source, harness.dialect).?;

        assert(std.meta.eql(repeated, outcome));

        assert(fuzz.rows_equal(
            Events.Event,
            harness.first.events.slice(),
            harness.again.events.slice(),
        ));

        assert(fuzz.rows_equal(Tree.Node, tree.slice(), harness.again.tree.slice()));

        assert(fuzz.rows_equal(
            Diagnostic,
            tree.diagnostic_slice(),
            harness.again.tree.diagnostic_slice(),
        ));
    }

    fn overflowed(harness: *Harness, source: []const u8) void {
        const tokens = harness.first.tokens.slice();
        const consumed = if (tokens.len == 0) 0 else tokens[tokens.len - 1].end();
        var end_previous: u32 = 0;

        assert(consumed <= source.len);

        for (tokens) |token| {
            assert(token.offset >= end_previous);
            assert(token.end() <= source.len);

            end_previous = token.end();
        }

        fuzzing.gaps_tile(tokens, consumed);
        const repeated = harness.again.parse(source, harness.dialect);
        const again = harness.again.tokens.slice();
        const consumed_again = if (again.len == 0) 0 else again[again.len - 1].end();

        assert(repeated == null);
        assert(consumed_again == consumed);
    }
};

const atoms = [_][]const u8{
    "let ",
    "const ",
    "var ",
    "function ",
    "f(",
    "(",
    ")",
    "[",
    "]",
    "{",
    "}",
    "a",
    "b",
    "1",
    "1.5",
    "\"s\"",
    "'c'",
    "`t${",
    "`r`",
    "/re/g",
    ",",
    ";",
    ":",
    "=",
    "=>",
    "+=",
    "++",
    "--",
    "?",
    "?.",
    "??",
    "!",
    "...",
    "<",
    ">",
    ">>",
    "<T>",
    "<div>",
    "</div>",
    "<a b={c} />",
    "&amp;",
    ".",
    "\n",
    " ",
    "// c\n",
    "/* c */",
    "/* open",
    "if ",
    "else ",
    "for ",
    "of ",
    "in ",
    "while ",
    "do ",
    "switch ",
    "case ",
    "default:",
    "return ",
    "break ",
    "continue ",
    "throw ",
    "try ",
    "catch ",
    "finally ",
    "class ",
    "extends ",
    "implements ",
    "interface ",
    "type ",
    "enum ",
    "namespace ",
    "declare ",
    "abstract ",
    "readonly ",
    "keyof ",
    "typeof ",
    "infer ",
    "as ",
    "satisfies ",
    "import ",
    "export ",
    "from ",
    "async ",
    "await ",
    "yield ",
    "new ",
    "this",
    "@d ",
    "x: number",
    "a is string",
    "asserts x",
    "\xff",
    "\xc3\xa9",
};

const prefixes = [_][]const u8{
    "",
    "let x = ",
    "function f() {\n",
    "type T = ",
    "class C {\n",
    "const v = <div>",
};

const nesting = [_][]const u8{
    "(",
    "f(",
    "[",
    "{",
    "() => {",
    "function () {",
    "if (a) ",
    "for (;;) ",
    "switch (a) { case 1:",
    "class { m() {",
    "x: { a: ",
    "{ a: ",
    "<T extends ",
    "keyof ",
    "Array<",
    "(a: ",
    "{ [k in ",
    "`${",
    "<div>",
    "<a b={",
    "-",
    "!",
};

const limits_default: Limits = .{
    .diagnostic_count_max = 1 << 10,
    .event_count_max = 1 << 19,
    .node_count_max = 1 << 16,
    .token_count_max = 1 << 16,
};

const limits_starved: Limits = .{
    .diagnostic_count_max = 4,
    .event_count_max = 256,
    .node_count_max = 64,
    .token_count_max = 96,
};

const atom_count_max = 1_024;
const atom_bytes_max = 32;
const event_count_default = 512;
const prefix_bytes_max = 32;
const source_bytes_max = atom_count_max * atom_bytes_max + prefix_bytes_max;

comptime {
    for (atoms ++ nesting) |atom| {
        assert(atom.len > 0);
        assert(atom.len <= atom_bytes_max);
    }

    for (prefixes) |prefix| assert(prefix.len <= prefix_bytes_max);
}

pub fn main(gpa: std.mem.Allocator, args: fuzz.Arguments) !void {
    assert((args.events_max orelse 1) > 0);

    var prng: PRNG = .init(args.seed);
    const event_count = args.events_max orelse event_count_default;
    const source_buffer = try gpa.alloc(u8, source_bytes_max);
    defer gpa.free(source_buffer);

    var plenty: Harness = undefined;

    try plenty.init(gpa, limits_default, .typescript);
    defer plenty.deinit(gpa);

    var starved: Harness = undefined;

    try starved.init(gpa, limits_starved, .typescript);
    defer starved.deinit(gpa);

    var marked: Harness = undefined;

    try marked.init(gpa, limits_default, .tsx);
    defer marked.deinit(gpa);

    var marked_starved: Harness = undefined;

    try marked_starved.init(gpa, limits_starved, .tsx);
    defer marked_starved.deinit(gpa);

    for (0..event_count) |_| {
        const source = source_generate(&prng, source_buffer);

        plenty.check(source);
        starved.check(source);
        marked.check(source);
        marked_starved.check(source);
    }
}

fn source_generate(prng: *PRNG, buffer: []u8) []const u8 {
    assert(buffer.len == source_bytes_max);

    const nested = prng.int_inclusive(u32, 3) == 0;
    const atom_count = prng.int_inclusive(u32, atom_count_max);
    const repeated = nesting[prng.index(nesting.len)];
    const prefix = prefixes[prng.index(prefixes.len)];
    var length: usize = prefix.len;

    @memcpy(buffer[0..prefix.len], prefix);

    for (0..atom_count) |_| {
        const atom = if (nested) repeated else atoms[prng.index(atoms.len)];

        @memcpy(buffer[length..][0..atom.len], atom);
        length += atom.len;
    }

    assert(length <= buffer.len);

    return buffer[0..length];
}

test "a parse fuzz run holds its invariants" {
    try main(std.testing.allocator, .{ .seed = 42, .events_max = 8 });
}

test "a deep chain of nested if statements stops at the depth cut-off" {
    const gpa = std.testing.allocator;
    const prefix = "let x = 1;\n";
    const unit = "if (a) ";
    const depth = 300;
    var buffer: [prefix.len + unit.len * depth]u8 = undefined;

    @memcpy(buffer[0..prefix.len], prefix);

    for (0..depth) |index| {
        @memcpy(buffer[prefix.len + unit.len * index ..][0..unit.len], unit);
    }

    var harness: Harness = undefined;

    try harness.init(gpa, limits_default, .typescript);
    defer harness.deinit(gpa);

    const outcome = harness.first.parse(&buffer, harness.dialect);

    try std.testing.expectEqual(Structure.too_deep, outcome.?);
}

test "a chain of nested if statements as deep as generated validators write parses whole" {
    const gpa = std.testing.allocator;
    const prefix = "let x = 1;\n";
    const unit = "if (a) ";
    const depth = 200;
    var buffer: [prefix.len + unit.len * depth + 2]u8 = undefined;

    @memcpy(buffer[0..prefix.len], prefix);

    for (0..depth) |index| {
        @memcpy(buffer[prefix.len + unit.len * index ..][0..unit.len], unit);
    }

    @memcpy(buffer[prefix.len + unit.len * depth ..], "x;");

    var harness: Harness = undefined;

    try harness.init(gpa, limits_default, .typescript);
    defer harness.deinit(gpa);

    const outcome = harness.first.parse(&buffer, harness.dialect);

    try std.testing.expectEqual(Structure.complete, outcome.?);
}

test "a deep chain of nested parentheses stops at the expression depth cut-off" {
    const gpa = std.testing.allocator;
    const prefix = "let x = ";
    const unit = "(";
    const depth = 300;
    var buffer: [prefix.len + unit.len * depth]u8 = undefined;

    @memcpy(buffer[0..prefix.len], prefix);
    @memset(buffer[prefix.len..], '(');

    var harness: Harness = undefined;

    try harness.init(gpa, limits_default, .tsx);
    defer harness.deinit(gpa);

    const outcome = harness.first.parse(&buffer, harness.dialect);

    try std.testing.expectEqual(Structure.too_deep, outcome.?);
}
