const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const EventsType = @import("../tree.zig").EventsType;
const Kind = @import("kind.zig").Kind;
const Parser = @import("parse.zig").Parser;
const Random = @import("../../testing/random.zig");
const Span = @import("../../stdx/bounded/span.zig");
const Structure = @import("../tree.zig").Structure;
const Token = @import("../token.zig");
const Tokens = @import("../tokens.zig");
const TreeType = @import("../tree.zig").TreeType;
const blank_end = @import("lex.zig").blank_end;
const corpus = @import("../../testing/corpus.zig");
const environment = @import("../../testing/environment.zig");
const floor = @import("../../testing/floor.zig");
const lex = @import("lex.zig").lex;
const raw_of = @import("../raw.zig").raw_of;
const oracle = @import("../../testing/oracle.zig");
const oracle_names = @import("../testing/names.zig");
const stripe = @import("../../testing/stripe.zig");
const scan = @import("../../text/scan.zig");
const tally = @import("../../testing/tally.zig");
const trivia = @import("../trivia.zig");
const Events = EventsType(Kind);
const Node = Tree.Node;
const Row = oracle.Row;
const Tree = TreeType(Kind);

const Machine = struct {
    attributes: std.ArrayList(Row),
    comments: std.ArrayList(Span),
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
        machine.attributes = .empty;
        machine.comments = .empty;
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
        machine.comments.deinit(gpa);
        machine.attributes.deinit(gpa);
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
            error.Truncated => assert(machine.tokens.items.full()),
        };

        raw_of(Kind, machine.tokens.slice(), &machine.raw) catch |err| switch (err) {
            error.Truncated => return false,
        };

        assert(machine.raw.count() == machine.tokens.count());

        return true;
    }

    fn invalid(machine: *const Machine) ?u32 {
        const raw = machine.raw.const_slice();

        assert(raw.len == machine.tokens.count());

        const position = std.mem.findScalar(Kind, raw, .error_token) orelse return null;

        assert(raw[position] == .error_token);

        return @intCast(position);
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

        for (machine.tree.slice(), 0..) |node, index| {
            if (std.mem.findScalar(Kind, &skipped, node.kind) != null) continue;

            if (node.kind == .generics) {
                if (!machine.parameters_held(@intCast(index))) continue;
            }

            const span = machine.printed_span(node);
            const name = oracle_names.name_of(Kind, node.kind);

            if (node.kind == .file) {
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

    fn parameters_held(machine: *const Machine, node: u32) bool {
        assert(node < machine.tree.count());
        assert(machine.tree.kind_at(node) == .generics);

        var child = machine.tree.child_first_of(node);

        for (0..machine.tree.count()) |_| {
            const held = child orelse return false;

            switch (machine.tree.kind_at(held)) {
                .const_param, .lifetime_param, .type_param => return true,
                else => {},
            }

            child = machine.tree.sibling_next_of(held);
        }

        return false;
    }

    fn printed_span(machine: *const Machine, node: Tree.Node) Span {
        assert(node.token_start <= node.token_end);

        const tokens = machine.tokens.slice();
        const span = node.span(Token, tokens);
        const parameter = node.kind == .lifetime_param or node.kind == .type_param;
        if (!parameter) return span;
        if (node.token_end < node.token_start + 2) return span;
        if (machine.raw.const_slice()[node.token_end - 1] != .colon) return span;

        const end = tokens[node.token_end - 2].end();

        assert(end > span.offset);
        assert(end < span.end());

        return .{ .offset = span.offset, .length = end - span.offset };
    }

    fn comments_find(machine: *Machine, gpa: std.mem.Allocator) !void {
        const raw = machine.raw.const_slice();
        const tokens = machine.tokens.slice();

        assert(raw.len == tokens.len);

        machine.comments.clearRetainingCapacity();

        for (raw, tokens) |kind, token| {
            switch (kind) {
                .comment, .doc_comment => try machine.comments.append(gpa, .{
                    .offset = token.offset,
                    .length = token.length,
                }),
                else => {},
            }
        }

        const comments = machine.comments.items;

        assert(comments.len <= raw.len);
        if (comments.len > 1) assert(comments[0].end() <= comments[1].offset);
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

        assert(std.mem.findScalar(Kind, &kinds, .file) == null);

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
        try machine.comments_find(gpa);
        try machine.wanted(gpa, source, rows);

        assert(machine.held.items.len <= machine.tree.count());
        assert(machine.expected.items.len <= rows.len);

        return rows_equal(machine.held.items, machine.expected.items);
    }

    fn wanted(
        machine: *Machine,
        gpa: std.mem.Allocator,
        source: []const u8,
        rows: []const Row,
    ) !void {
        assert(source.len <= std.math.maxInt(u32));
        assert(rows.len <= std.math.maxInt(u32));

        const comments = machine.comments.items;
        const found = &machine.expected;
        const length: u32 = @intCast(source.len);

        try attributes_gather(gpa, rows, &machine.attributes);
        found.clearRetainingCapacity();

        const attributes = machine.attributes.items;

        for (rows) |row| {
            if (std.mem.eql(u8, row.name, "File")) {
                try found.append(gpa, .{ .name = row.name, .offset = 0, .end = length });

                continue;
            }

            if (row.offset >= row.end) continue;
            if (comment_covers(source, comments, row)) continue;

            const start = start_of(source, comments, attributes, rows.len, row);

            try found.append(gpa, .{ .name = row.name, .offset = start, .end = row.end });
        }

        std.mem.sort(Row, found.items, {}, Row.less_than);

        assert(found.items.len <= rows.len);
        if (found.items.len > 1) assert(!Row.less_than({}, found.items[1], found.items[0]));
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

const Construct = struct {
    name: []const u8,
    source: []const u8,
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

const Walked = enum {
    abstained,
    differs,
    matches,
};

const alphabet = "abc_09 \t\n\r()[]{}:,.=+-*/%<>!&|^~@;'\"\\#?$fnletmatchimplusewhere" ++
    "\x00\xff\xc3\xa9";

const alphabet_length: u32 = 66;
const diagnostic_count_max: u32 = 0x0000_0400;
const event_count_max: u32 = 0x0030_0000;
const every_category = [_][]const u8{ "not-rust", "shape" };
const file_count_max: u32 = 1 << 20;
const fixture_root = "tests/fixtures/rust";
const golden_root = "tests/fixtures/golden-rust";
const node_count_max: u32 = 0x0010_0000;
const none: u32 = std.math.maxInt(u32);
const not_rust = [_][]const u8{"not-rust"};
const raw_count_max: u32 = 0x0010_0000;
const report_lines_max: u32 = 24;
const report_shown_max: u32 = 3;
const residue_name = "residue-rust.json";
const skipped = [_]Kind{.error_node};
const soup_bytes_max: u32 = 512;
const soup_round_count: u32 = 512;
const source_bytes_max: u32 = 1 << 24;
const suite = "syntax_rust";
const token_count_max: u32 = 0x0010_0000;

const statements = [_][]const u8{
    "ImplItemConst",
    "ImplItemFn",
    "ImplItemType",
    "ItemConst",
    "ItemEnum",
    "ItemExternCrate",
    "ItemFn",
    "ItemForeignMod",
    "ItemImpl",
    "ItemMacro",
    "ItemMod",
    "ItemStatic",
    "ItemStruct",
    "ItemTrait",
    "ItemType",
    "ItemUnion",
    "ItemUse",
    "TraitItemConst",
    "TraitItemFn",
    "TraitItemType",
};

const constructs = [_]Construct{
    .{ .name = "a const trait bound", .source = "trait Held: const Other {}\n" },
    .{
        .name = "a bracketed const bound",
        .source = "fn held<T>()\nwhere\n    T: [const] Default,\n{\n}\n",
    },
    .{ .name = "an auto trait", .source = "auto trait Held {}\n" },
    .{ .name = "a const trait impl", .source = "impl const Other for Thing {}\n" },
    .{ .name = "a declarative macro", .source = "pub macro held($item:item) {}\n" },
    .{
        .name = "a declarative macro with rules",
        .source = "macro held {\n    () => {};\n}\n",
    },
    .{
        .name = "a const parameter default",
        .source = "struct Held<const WIDE: bool = false> {\n    held: bool,\n}\n",
    },
    .{
        .name = "a safe foreign function",
        .source = "unsafe extern \"C\" {\n    pub safe fn held(value: u32);\n}\n",
    },
    .{ .name = "a const extern function", .source = "pub const extern \"C\" fn held() {}\n" },
    .{
        .name = "a nested const unsafe function",
        .source = "fn held() {\n    const unsafe fn inner(value: usize) {}\n}\n",
    },
    .{
        .name = "a full range in a for header",
        .source = "fn held() {\n    for index in .. {}\n}\n",
    },
    .{
        .name = "a const closure",
        .source = "fn held() {\n    let counted = const || 1;\n}\n",
    },
    .{
        .name = "a trailing where clause on an associated type",
        .source = "impl Held for Thing {\n    type Value = u32\n    where\n" ++
            "        Self: Sized;\n}\n",
    },
    .{
        .name = "a frontmatter behind a shebang",
        .source = "#!/usr/bin/env cargo\n---cargo\n[package]\nedition = \"2024\"\n---\n" ++
            "fn held() {}\n",
    },
    .{
        .name = "a break before a block in a condition",
        .source = "fn held() {\n    if break {}\n    while break {}\n}\n",
    },
    .{
        .name = "closures behind a binder and coroutine qualifiers",
        .source = "fn held() {\n    let counted = for<'a> move || 1;\n    static move || {};\n" ++
            "    async move || {};\n    static async || {};\n}\n",
    },
    .{
        .name = "a tuple index written before a spaced dot",
        .source = "fn held() {\n    x.0. await;\n    x.0. call();\n}\n",
    },
    .{
        .name = "default items and members",
        .source = "default unsafe impl Held for Thing {\n    default fn held() {}\n" ++
            "    default type Value = u32;\n}\n",
    },
    .{
        .name = "trait objects led by a lifetime, a binder, or a parenthesized bound",
        .source = "type Held = 'static + Other;\ntype Boxed = Box<Other + 'static>;\n" ++
            "type Bound = for<'a> Other<'a> + Send;\nfn held<T: (Copy) + (?Sized)>() {}\n",
    },
    .{ .name = "a self path parameter", .source = "fn held(self::Thing: Thing) {}\n" },
    .{
        .name = "a variadic parameter with a pattern",
        .source = "unsafe extern \"C\" {\n    fn held(value: u32, _: ...);\n}\n",
    },
    .{
        .name = "const block patterns",
        .source = "fn held() {\n    let const { 15 } = ();\n    match 1 {\n" ++
            "        const { 0 }..const { 1 } => (),\n        _ => (),\n    }\n}\n",
    },
    .{
        .name = "a box pattern and an attributed rest",
        .source = "fn held() {\n    let box value = ();\n" ++
            "    let Thing { #[cfg(any())] .. } = ();\n}\n",
    },
    .{
        .name = "safe and unsafe foreign statics",
        .source = "unsafe extern {\n    pub safe static mut COUNTED: i32;\n" ++
            "    pub unsafe static HELD: u8;\n}\n",
    },
    .{
        .name = "a const item with a where clause",
        .source = "const HELD<T>: u32 = 0\nwhere\n    T: Copy;\n",
    },
    .{
        .name = "an attributed return value",
        .source = "fn held() -> u32 {\n    return #[allow(unused)] 1;\n}\n",
    },
    .{ .name = "a const impl block", .source = "const impl<T: [const] Clone> Held<T> {}\n" },
    .{
        .name = "a const bound after a binder",
        .source = "fn held(f: impl for<'a> [const] FnOnce(&'a u32)) {}\n",
    },
    .{
        .name = "super let, do yeet, and become",
        .source = "fn held() {\n    super let value = 1;\n    do yeet;\n    become held();\n}\n",
    },
    .{
        .name = "a builtin deref pattern",
        .source = "fn held() {\n    let builtin # deref(_) = 1;\n}\n",
    },
    .{ .name = "keyword field names", .source = "fn held() {\n    x.self;\n    x.Self;\n}\n" },
    .{
        .name = "field defaults, unsafe fields, rooted use trees, and dotted range patterns",
        .source = "struct Held {\n    f: f32 = 0.0,\n    unsafe c: u8,\n}\nuse std::{::io, *};\n" ++
            "fn held() {\n    match 1 {\n        0 ... 9 => (),\n        _ => (),\n    }\n}\n",
    },
    .{
        .name = "gen blocks and functions",
        .source = "gen fn held() {}\nasync gen fn other() {}\nfn third() {\n" ++
            "    gen { yield 1; };\n    async gen move { yield 1; };\n}\n",
    },
    .{
        .name = "return type notation and parenthesized bindings",
        .source = "fn held<T>()\nwhere\n    T::method(..): Send,\n{\n}\n" ++
            "type Held = Iter<Item(T): Clone, Item::<T> = u8>;\n" ++
            "type Boxed = Box<Fn::(i32) -> ()>;\n",
    },
    .{
        .name = "an impl restriction and a typed try block",
        .source = "pub impl(crate) unsafe trait Held {}\nimpl () {}\n" ++
            "fn held() {\n    let _ = try bikeshed T<U> {};\n}\n",
    },
};

comptime {
    assert(alphabet.len == alphabet_length);
    assert(alphabet_length < soup_bytes_max);
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

    return std.mem.eql(u8, std.Io.Dir.path.extension(basename), ".rs");
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

fn gap_blank(source: []const u8, gap: Span) bool {
    assert(gap.end() <= source.len);

    const mark: u32 = if (gap.offset == 0) @min(scan.mark_width(source), gap.length) else 0;
    const start = gap.offset + mark;

    return blank_end(source[0..gap.end()], start) == gap.end();
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
            gap_blank(source, gap.span),
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

                    const invalid = machine.invalid();

                    try require(
                        invalid == null,
                        "{s} classifies token {?d} to an ErrorToken",
                        .{ fixture.name, invalid },
                    );

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
    if (machine.invalid() != null) return true;

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

fn attributes_gather(
    gpa: std.mem.Allocator,
    rows: []const Row,
    attributes: *std.ArrayList(Row),
) !void {
    assert(rows.len <= std.math.maxInt(u32));

    attributes.clearRetainingCapacity();

    for (rows) |row| {
        if (std.mem.eql(u8, row.name, "Attribute")) try attributes.append(gpa, row);
    }

    std.mem.sort(Row, attributes.items, {}, attribute_less_than);

    assert(attributes.items.len <= rows.len);
    if (attributes.items.len > 1) assert(attributes.items[0].offset <= attributes.items[1].offset);
}

fn attribute_less_than(context: void, left: Row, right: Row) bool {
    _ = context;

    assert(left.name.len > 0);
    assert(right.name.len > 0);

    return left.offset < right.offset;
}

fn comment_covers(source: []const u8, comments: []const Span, row: Row) bool {
    assert(row.offset < row.end);
    assert(source.len <= std.math.maxInt(u32));
    assert(comments.len <= std.math.maxInt(u32));

    const comment = comment_before(comments, row.offset) orelse return false;
    const end = comment.end();
    const returned = end < source.len and source[end] == '\r';

    assert(comment.offset <= row.offset);
    assert(end <= source.len);

    return row.end <= end + @intFromBool(returned);
}

fn start_of(
    source: []const u8,
    comments: []const Span,
    attributes: []const Row,
    row_count: usize,
    row: Row,
) u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(comments.len <= std.math.maxInt(u32));
    assert(row.offset < row.end);

    const expression = std.mem.startsWith(u8, row.name, "Expr");
    var start = row.offset;

    assert(attributes.len <= row_count);

    for (0..comments.len + row_count + 1) |_| {
        const held = start;

        start = advanced(source, comments, start, row.end);

        if (expression) start = past_attributes(source, attributes, row_count, start, row.end);
        if (start == held) break;
    }

    return start;
}

fn past_attributes(
    source: []const u8,
    attributes: []const Row,
    row_count: usize,
    offset: u32,
    end: u32,
) u32 {
    assert(offset < none);
    assert(end < none);

    var held = offset;

    assert(attributes.len <= row_count);
    assert(source.len <= std.math.maxInt(u32));

    for (0..row_count) |_| {
        const found = attribute_at(attributes, held, end) orelse return held;

        held = blank_skipped(source, found.end, end);
    }

    return held;
}

fn attribute_at(attributes: []const Row, offset: u32, end: u32) ?Row {
    assert(attributes.len <= std.math.maxInt(u32));
    assert(offset < none);

    const first = std.sort.partitionPoint(Row, attributes, offset, attribute_before);

    assert(first <= attributes.len);
    if (first > 0) assert(attributes[first - 1].offset < offset);

    for (attributes[first..]) |attribute| {
        if (attribute.offset != offset) return null;
        if (attribute.end <= end) return attribute;
    }

    return null;
}

fn attribute_before(offset: u32, attribute: Row) bool {
    assert(attribute.offset <= attribute.end);

    return attribute.offset < offset;
}

fn advanced(source: []const u8, comments: []const Span, offset: u32, end: u32) u32 {
    assert(offset < none);
    assert(end < none);

    var held = offset;

    assert(source.len <= std.math.maxInt(u32));
    assert(comments.len <= raw_count_max);

    for (0..comments.len + 1) |_| {
        const comment = comment_at(comments, held) orelse break;

        held = blank_skipped(source, comment.end(), end);
    }

    return held;
}

fn comment_at(comments: []const Span, offset: u32) ?Span {
    assert(comments.len <= std.math.maxInt(u32));
    assert(offset < none);

    const comment = comment_before(comments, offset) orelse return null;

    assert(comment.offset <= offset);
    assert(comment.length > 0);

    if (comment.contains(offset)) return comment;
    return null;
}

fn comment_before(comments: []const Span, offset: u32) ?Span {
    assert(comments.len <= std.math.maxInt(u32));
    assert(offset < none);

    const after = std.sort.partitionPoint(Span, comments, offset, comment_started);

    assert(after <= comments.len);
    if (after < comments.len) assert(comments[after].offset > offset);

    if (after == 0) return null;
    return comments[after - 1];
}

fn comment_started(offset: u32, comment: Span) bool {
    assert(comment.length <= std.math.maxInt(u32) - comment.offset);

    return comment.offset <= offset;
}

fn blank_skipped(source: []const u8, offset: u32, end: u32) u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(offset < none);
    assert(end < none);

    var held = offset;

    while (held < end) : (held += 1) {
        if (!scan.is_ascii_whitespace(source[held])) break;
    }

    assert(held >= offset);
    if (held < end) assert(!scan.is_ascii_whitespace(source[held]));

    return held;
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

fn rows_contain(rows: []const Row, held: Row) bool {
    assert(held.name.len > 0);
    assert(held.offset <= held.end);
    assert(rows.len <= std.math.maxInt(u32));

    for (rows) |row| {
        if (row.order(held) == .eq) return true;
    }

    return false;
}

fn rows_named(rows: []const Row, name: []const u8) u32 {
    var found: u32 = 0;

    assert(name.len > 0);
    assert(rows.len <= node_count_max);

    for (rows) |row| {
        if (std.mem.eql(u8, row.name, name)) found += 1;
    }

    assert(found <= rows.len);

    return found;
}

fn row_at(rows: []const Row, name: []const u8, offset: u32) ?Row {
    assert(name.len > 0);
    assert(rows.len <= node_count_max);

    for (rows) |row| {
        if (row.offset != offset) continue;
        if (std.mem.eql(u8, row.name, name)) return row;
    }

    return null;
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

fn require(condition: bool, comptime format: []const u8, arguments: anytype) !void {
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    if (condition) return;

    std.debug.print(format ++ "\n", arguments);

    return error.TestUnexpectedResult;
}

fn walk_require(condition: bool, rows: []const Row, comptime message: []const u8) !void {
    comptime assert(message.len > 0);
    assert(rows.len <= node_count_max);

    if (condition) return;

    std.debug.print(message ++ "\n", .{});

    for (rows) |row| {
        std.debug.print("  {s} {d} {d}\n", .{ row.name, row.offset, row.end });
    }

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

test "a foreign module in a body closes with its function" {
    const gpa = std.testing.allocator;

    const source = "fn outer() {\n    unsafe extern \"C\" {\n        fn signal(number: i32) -> " ++
        "usize;\n    }\n}\n\nfn filler() {}\n";

    const length: u32 = source.len;
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    _ = try machine.parse(source);

    try machine.walk(gpa, length);

    const walk = machine.held.items;
    const outer = row_at(walk, "ItemFn", 0);

    try walk_require(outer != null, walk, "the outer function is a node");

    try walk_require(
        outer.?.end < length,
        walk,
        "the foreign module carried the function to the end of the file",
    );

    try walk_require(
        rows_named(walk, "ItemForeignMod") > 0,
        walk,
        "the foreign module is a node of its own",
    );

    try walk_require(
        rows_named(walk, "ItemFn") == 2,
        walk,
        "the outer function and the filler each stand alone",
    );

    try walk_require(
        rows_named(walk, "ForeignItemFn") > 0,
        walk,
        "the foreign declaration is its own node",
    );
}

test "classify runs the corpus without an unclaimed byte" {
    const gpa = std.testing.allocator;
    var found = try corpus_fixtures(gpa);
    defer found.deinit(gpa);

    if (found.slice().len == 0) return;

    var carried = try oracle.residue_of(gpa, residue_name, &not_rust);
    defer carried.deinit(gpa);

    const counted = try corpus_checked(.classify, gpa, &carried, null, found.slice());

    try require(
        counted.compared >= floor.corpus_classify_rust,
        "the corpus lost its Rust files: {d} classified, floor {d}",
        .{ counted.compared, floor.corpus_classify_rust },
    );
}

test "the tree holds its invariants over the corpus" {
    const gpa = std.testing.allocator;
    var found = try corpus_fixtures(gpa);
    defer found.deinit(gpa);

    if (found.slice().len == 0) return;

    var carried = try oracle.residue_of(gpa, residue_name, &not_rust);
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

test "a precise capture is one bound" {
    const gpa = std.testing.allocator;
    const source = "fn held<T>() -> impl Iterator<Item = T> + use<T> { core::iter::empty() }\n";
    const length: u32 = source.len;
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    try std.testing.expectEqual(Structure.complete, try machine.parse(source));
    try machine.walk(gpa, length);

    const capture: Row = .{ .name = "PreciseCapture", .offset = 42, .end = 48 };
    const walk = machine.held.items;

    try walk_require(rows_contain(walk, capture), walk, "the precise capture is one node");
}

test "a statement macro, a rest, a leading bar, and an inner arm attribute walk as syn does" {
    const gpa = std.testing.allocator;

    const source = "struct S(pub (A, u32));\n" ++
        "fn f(x: u8) -> u8 {\n" ++
        "    match x {\n" ++
        "        #![allow(unused)]\n" ++
        "        (..) => {}\n" ++
        "        | 1 => {}\n" ++
        "        _ => {}\n" ++
        "    }\n" ++
        "    quote! { a }.into()\n" ++
        "}\n";

    const length: u32 = source.len;
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    try std.testing.expectEqual(Structure.complete, try machine.parse(source));
    try std.testing.expectEqual(0, machine.tree.diagnostic_slice().len);
    try machine.walk(gpa, length);

    const walk = machine.held.items;
    const tuple: Row = .{ .name = "TypeTuple", .offset = 13, .end = 21 };
    const rest: Row = .{ .name = "PatTuple", .offset = 92, .end = 96 };
    const arm: Row = .{ .name = "Arm", .offset = 92, .end = 102 };
    const bar: Row = .{ .name = "PatOr", .offset = 111, .end = 114 };
    const call: Row = .{ .name = "ExprMethodCall", .offset = 147, .end = 166 };
    const invoked: Row = .{ .name = "ExprMacro", .offset = 147, .end = 159 };

    try walk_require(rows_contain(walk, tuple), walk, "a pub field holds a tuple type");
    try walk_require(rows_named(walk, "VisRestricted") == 0, walk, "pub (A, u32) is plain pub");
    try walk_require(rows_contain(walk, rest), walk, "a lone rest in parens is a tuple pattern");
    try walk_require(rows_contain(walk, arm), walk, "the first arm opens past the inner attribute");
    try walk_require(rows_contain(walk, bar), walk, "a leading bar opens an or-pattern");
    try walk_require(rows_contain(walk, call), walk, "a brace macro the dot follows is a receiver");
    try walk_require(rows_contain(walk, invoked), walk, "the brace macro is an expression");
}

test "a trait alias opens its own item" {
    const gpa = std.testing.allocator;
    const source = "trait Held = Clone + Send;\n";
    const length: u32 = source.len;
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    try std.testing.expectEqual(Structure.complete, try machine.parse(source));
    try machine.walk(gpa, length);

    const alias: Row = .{ .name = "ItemTraitAlias", .offset = 0, .end = 26 };
    const walk = machine.held.items;

    try walk_require(rows_contain(walk, alias), walk, "the trait alias is an item");
    try walk_require(rows_named(walk, "ItemTrait") == 0, walk, "the trait alias is no trait");
}

test "every recent construct parses without an error" {
    const gpa = std.testing.allocator;
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    for (constructs) |construct| {
        const outcome = try machine.parse(construct.source);
        const errors = machine.tree.diagnostic_slice();

        try require(outcome == .complete, "{s} does not parse whole", .{construct.name});
        try require(errors.len == 0, "{s} parses with {any}", .{ construct.name, errors });
        try require(machine.invalid() == null, "{s} classifies to an error", .{construct.name});
    }
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
        compared >= floor.fixture_walk_rust,
        "the Rust fixtures lost a walk: {d} compared, floor {d}",
        .{ compared, floor.fixture_walk_rust },
    );
}

test "the statement census matches the corpus goldens" {
    const gpa = std.testing.allocator;
    const held = corpus.named(.golden) orelse return;
    var found = try corpus_fixtures(gpa);
    defer found.deinit(gpa);

    if (found.slice().len == 0) return;

    var carried = try oracle.residue_of(gpa, residue_name, &not_rust);
    defer carried.deinit(gpa);

    const counted = try corpus_checked(.census, gpa, &carried, held, found.slice());

    try require(
        counted.compared >= floor.corpus_census_rust,
        "the corpus lost its Rust files: {d} counted, {d} abstained, floor {d}",
        .{ counted.compared, counted.abstained, floor.corpus_census_rust },
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
        named >= floor.corpus_walk_rust,
        "the corpus lost its Rust files: {d} named, {d} abstained, floor {d}",
        .{ named, counted.abstained, floor.corpus_walk_rust },
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

    _ = try machine.parse("struct S { a i32 }");

    try std.testing.expect(machine.tree.diagnostic_slice().len > 0);

    const held = machine.tree.diagnostic_slice()[0];

    try std.testing.expectEqual(Kind.colon, held.expected_kind(Kind).?);
    try std.testing.expectEqual(Kind.identifier, held.found_kind(Kind).?);

    const ended_source = "impl S";

    _ = try machine.parse(ended_source);

    try std.testing.expect(machine.tree.diagnostic_slice().len > 0);

    const ended = machine.tree.diagnostic_slice()[0];

    try std.testing.expectEqual(ended_source.len, ended.span.offset);
    try std.testing.expectEqual(0, ended.span.length);

    try std.testing.expectEqual(Kind.brace_open, ended.expected_kind(Kind).?);
    try std.testing.expectEqual(null, ended.found_kind(Kind));
}

test "a reference type takes no bounds and a generic list needs its closing angle" {
    const gpa = std.testing.allocator;
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    const broken = [_][]const u8{
        "struct Bar<'a> { w: &'a dyn Foo + Send }",
        "fn f(x: *const dyn Foo + Send) {}",
        "fn main() { if x as u32 < 4 {} }",
        "fn main() { let y: Foo<4 = v; }",
    };

    for (broken) |source| {
        _ = try machine.parse(source);

        try std.testing.expect(machine.tree.diagnostic_slice().len > 0);
    }

    const held = [_][]const u8{
        "struct Bar<'a> { w: &'a (dyn Foo + Send), v: Box<dyn Foo + Send> }",
        "fn main() { let y = x as Foo <u8>; let z: Vec< u8 > = v; let w: Vec<u8>= v; }",
        "fn f<T: Foo + Send>(x: impl Foo + Send) {}",
    };

    for (held) |source| {
        _ = try machine.parse(source);

        try std.testing.expectEqual(0, machine.tree.diagnostic_slice().len);
    }
}

test "a match arm needs a pattern and the arrow after it" {
    const gpa = std.testing.allocator;
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    const broken = [_][]const u8{
        "fn f() { match x { y } }",
        "fn f() { match x { {} => 1, } }",
        "fn f() { match x { A => 1, {} } }",
        "fn f() { match x { & => 1, } }",
    };

    for (broken) |source| {
        _ = try machine.parse(source);

        try std.testing.expect(machine.tree.diagnostic_slice().len > 0);
    }

    _ = try machine.parse("fn f() { match x { A | B => 1, &_ => {} } }");

    try std.testing.expectEqual(0, machine.tree.diagnostic_slice().len);
}

test "an unnamed variant, a binding without a type, and a where clause on a static are errors" {
    const gpa = std.testing.allocator;
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    const broken = [_][]const u8{
        "enum Held {#[attr]}\n",
        "fn held() -> impl Iterator<Item = , Item = > {}\n",
        "static HELD: u32 = 0\nwhere\n    u32: Copy;\n",
        "const HELD = 0;\n",
        "const mut HELD: u32 = 0;\n",
        "static _: i32 = 5;\n",
        "static HELD<i32>: u32 = 0;\n",
        "type Held = *();\n",
        "type Held = <()>;\n",
        "const _: [&];\n",
        "use crate::;\n",
        "unsafe async fn held() {}\n",
    };

    for (broken) |source| {
        _ = try machine.parse(source);

        try std.testing.expect(machine.tree.diagnostic_slice().len > 0);
    }
}

test "a postfix after an open range ends the closure, and a spaced tuple index splits its dot" {
    const gpa = std.testing.allocator;
    const source = "fn f() {\n    || 1.. .method();\n    x.0. await;\n}\n";
    const length: u32 = source.len;
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    try std.testing.expectEqual(Structure.complete, try machine.parse(source));
    try std.testing.expectEqual(0, machine.tree.diagnostic_slice().len);
    try machine.walk(gpa, length);

    const walk = machine.held.items;
    const call: Row = .{ .name = "ExprMethodCall", .offset = 13, .end = 29 };
    const closure: Row = .{ .name = "ExprClosure", .offset = 13, .end = 19 };
    const awaited: Row = .{ .name = "ExprAwait", .offset = 35, .end = 45 };
    const field: Row = .{ .name = "ExprField", .offset = 35, .end = 38 };

    try walk_require(rows_contain(walk, call), walk, "the method call takes the closure");
    try walk_require(rows_contain(walk, closure), walk, "the closure ends with its range");
    try walk_require(rows_contain(walk, awaited), walk, "the await reads the field");
    try walk_require(rows_contain(walk, field), walk, "the field index stops before the dot");
}

test "unclosed delimiters, open literals, and missing operands are errors" {
    const gpa = std.testing.allocator;
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    const broken = [_][]const u8{
        "fn held() {\n",
        "use std::{error::Error;\n",
        "fn held() { foo!(bar } }\n",
        "fn held() {}\n/* open",
        "fn held() { let x = \"open; }\n",
        "fn held() { 1 + }\n",
        "fn held() { (a, , b); }\n",
        "type Held = Held<0, ,T>;\n",
        "fn held() { 0..=; }\n",
        "fn held(a: A) {\n    a.\n}\n",
    };

    for (broken) |source| {
        _ = try machine.parse(source);

        try std.testing.expect(machine.tree.diagnostic_slice().len > 0);
    }
}

test "statements that run together or lose their parts are errors" {
    const gpa = std.testing.allocator;
    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    const broken = [_][]const u8{
        "fn held() { let _ = match x { _ => 1 } else { return }; }\n",
        "fn held() {#[attr]}\n",
        "fn held() {\n    foo(1)\n    return 92;\n}\n",
        "fn held() { S { field = foo }; }\n",
        "fn held() { let _ = async {} }\n",
        "fn held() { || -> () unsafe { () }; }\n",
        "fn held() { ..z = 2; }\n",
        "#![]\n",
        "#![p = ]\n",
        "#![p::]\n",
        "#![unsafe]\n",
        "struct Held<const N: i32 = i32::MAX>;\n",
        "fn held<T>() where T: ?for<'a> Sized {}\n",
        "fn held() {}\n/// documents nothing\n",
        "macro_rules! held { () => {} };\n",
    };

    for (broken) |source| {
        _ = try machine.parse(source);

        try std.testing.expect(machine.tree.diagnostic_slice().len > 0);
    }

    _ = try machine.parse("fn held() {\n    'outer: loop {}\n    let x = 1;\n    x\n}\n");

    try std.testing.expectEqual(0, machine.tree.diagnostic_slice().len);
}
