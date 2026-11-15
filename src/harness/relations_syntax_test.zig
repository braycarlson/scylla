const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Category = @import("../syntax/category.zig").Category;
const Dialect = @import("../syntax/javascript/dialect.zig").Dialect;
const EventsType = @import("../syntax/tree.zig").EventsType;
const IndexType = @import("../syntax/tree.zig").IndexType;
const Language = @import("../syntax/language.zig").Language;
const SourceType = @import("../syntax/language.zig").SourceType;
const Token = @import("../syntax/token.zig");
const Tokens = @import("../syntax/tokens.zig");
const TreeType = @import("../syntax/tree.zig").TreeType;
const corpus = @import("../testing/corpus.zig");
const floor = @import("../testing/floor.zig");
const grammars = @import("../syntax/grammars.zig");
const lex = @import("../syntax/lex.zig").lex;
const raw_of = @import("../syntax/raw.zig").raw_of;
const scan = @import("../text/scan.zig");
const stripe = @import("../testing/stripe.zig");
const Fixture = corpus.File;

const Grammar = struct {
    dialect: ?Dialect,
    directory: []const u8,
    extension: []const u8,
    language: Language,
    module: type,
    note: []const u8,
    relation: floor.Relation,
    skipped: []const []const u8,
};

const Pair = struct {
    offset: u32,
    length: u32,
};

const Trace = struct {
    kinds: []const []const u8,
    spans: []const Pair,
    token_count: u32,
};

const diagnostic_count_max: u32 = 1 << 12;
const event_count_max: u32 = 1 << 21;
const file_count_max: u32 = 1 << 20;
const node_count_max: u32 = 1 << 18;
const source_bytes_max: u32 = 1 << 28;
const token_count_max: u32 = 1 << 18;

const every_grammar = [_]Grammar{
    grammar_of("css", "css", "css", "/* relation */\n", &.{}, floor.relation_css),
    grammar_of("go", "go", "go", "// relation\n", &.{}, floor.relation_go),
    grammar_of(
        "javascript",
        "javascript",
        "js",
        "// relation\n",
        &.{"jsx_text.js"},
        floor.relation_javascript,
    ),
    grammar_of("odin", "odin", "odin", "// relation\n", &.{}, floor.relation_odin),
    grammar_of("python", "python", "py", "# relation\n", &.{}, floor.relation_python),
    grammar_of("rust", "rust", "rs", "// relation\n", &.{}, floor.relation_rust),
    typescript_of("ts", .typescript, &.{}, floor.relation_typescript),
    grammar_of("zig", "zig", "zig", "// relation\n", &.{}, floor.relation_zig),
    typescript_of("tsx", .tsx, &.{"tsx_text.tsx"}, floor.relation_tsx),
};

fn tsx_of(comptime grammar: Grammar) bool {
    assert(grammar.directory.len <= std.math.maxInt(u32));

    const held = grammar.dialect orelse return false;
    return held == .tsx;
}

fn grammar_of(
    comptime module: []const u8,
    comptime directory: []const u8,
    comptime extension: []const u8,
    comptime note: []const u8,
    comptime skipped: []const []const u8,
    comptime relation: floor.Relation,
) Grammar {
    assert(module.len <= std.math.maxInt(u32));
    assert(directory.len <= std.math.maxInt(u32));
    assert(extension.len <= std.math.maxInt(u32));
    assert(note.len <= std.math.maxInt(u32));
    assert(skipped.len <= std.math.maxInt(u32));
    comptime assert(relation.every > 0);
    comptime assert(relation.window <= relation.every);

    const dialect: ?Dialect = if (std.mem.eql(u8, module, "javascript")) .javascript else null;

    return .{
        .dialect = dialect,
        .directory = directory,
        .extension = extension,
        .language = @field(Language, module),
        .module = @field(grammars, module),
        .note = note,
        .relation = relation,
        .skipped = skipped,
    };
}

fn typescript_of(
    comptime extension: []const u8,
    comptime dialect: Dialect,
    comptime skipped: []const []const u8,
    comptime relation: floor.Relation,
) Grammar {
    assert(extension.len <= std.math.maxInt(u32));
    assert(skipped.len <= std.math.maxInt(u32));
    comptime assert(relation.every > 0);
    comptime assert(relation.window <= relation.every);
    comptime assert(dialect.typed());

    return .{
        .dialect = dialect,
        .directory = "typescript",
        .extension = extension,
        .language = .typescript,
        .module = grammars.javascript,
        .note = "// relation\n",
        .relation = relation,
        .skipped = skipped,
    };
}

fn CorpusWorkerType(comptime grammar: Grammar) type {
    assert(grammar.directory.len <= std.math.maxInt(u32));

    return struct {
        arena: std.heap.ArenaAllocator,
        held: HeldType(grammar),

        const CorpusWorker = @This();
        pub const Item = Fixture;
        pub const Shared = struct {};
        pub const Tally = struct { compared: u32 };
        pub const weight = Fixture.weight;

        pub fn init(worker: *CorpusWorker, gpa: std.mem.Allocator, shared: *const Shared) !void {
            assert(@TypeOf(shared.*) == Shared);
            assert(grammar.note.len > 0);

            worker.arena = .init(gpa);
            errdefer worker.arena.deinit();

            try worker.held.init(gpa);
        }

        pub fn deinit(worker: *CorpusWorker, gpa: std.mem.Allocator) void {
            assert(grammar.note.len > 0);
            assert(grammar.extension.len > 0);

            worker.held.deinit(gpa);
            worker.arena.deinit();
            worker.* = undefined;
        }

        pub fn visit(worker: *CorpusWorker, fixture: *const Fixture, tally: *Tally) !void {
            assert(fixture.name.len > 0);
            assert(tally.compared <= file_count_max);

            const width: u32 = @intCast(grammar.note.len);

            _ = worker.arena.reset(.retain_capacity);

            const allocator = worker.arena.allocator();

            const plain = worker.held.walk_checked(allocator, fixture.source) catch |err| {
                switch (err) {
                    error.Unwalkable => return,
                    else => return err,
                }
            };

            tally.compared += 1;

            try corpus_noted(grammar, &worker.held, allocator, fixture.*, &plain, width);
            try corpus_windowed(grammar, &worker.held, allocator, fixture.*, &plain);
        }

        fn selected(basename: []const u8) bool {
            assert(basename.len > 0);

            const dotted = std.Io.Dir.path.extension(basename);

            if (dotted.len == 0) return false;
            return std.mem.eql(u8, dotted[1..], grammar.extension);
        }
    };
}

fn HeldType(comptime grammar: Grammar) type {
    assert(grammar.directory.len <= std.math.maxInt(u32));

    return struct {
        events: *Events,
        index: Index,
        parser: *grammar.module.Parser,
        raw: ArrayType(grammar.module.Kind),
        tokens: Tokens,
        tree: Tree,

        const Held = @This();
        const Events = EventsType(grammar.module.Kind);
        const Index = IndexType(grammar.module.Kind);
        const Tree = TreeType(grammar.module.Kind);

        fn init(held: *Held, gpa: std.mem.Allocator) !void {
            held.events = try gpa.create(Events);
            errdefer gpa.destroy(held.events);

            try held.events.init(gpa, event_count_max);
            errdefer held.events.deinit(gpa);

            held.index = try .init(gpa, node_count_max);
            errdefer held.index.deinit(gpa);

            held.parser = try gpa.create(grammar.module.Parser);
            errdefer gpa.destroy(held.parser);

            held.raw = try .init(gpa, token_count_max);
            errdefer held.raw.deinit(gpa);

            held.tokens = try .init(gpa, token_count_max);
            errdefer held.tokens.deinit(gpa);

            held.tree = try .init(gpa, node_count_max, diagnostic_count_max);

            assert(held.raw.capacity() == held.tokens.items.capacity());
            assert(held.tree.count() == 0);
        }

        fn deinit(held: *Held, gpa: std.mem.Allocator) void {
            assert(held.raw.capacity() == token_count_max);
            assert(held.tokens.items.capacity() == token_count_max);

            held.tree.deinit(gpa);
            held.tokens.deinit(gpa);
            held.raw.deinit(gpa);
            gpa.destroy(held.parser);
            held.index.deinit(gpa);
            held.events.deinit(gpa);
            gpa.destroy(held.events);
            held.* = undefined;
        }

        fn built(held: *Held, source: []const u8) bool {
            assert(source.len <= std.math.maxInt(u32));

            held.tokens.clear();

            const tsx = comptime tsx_of(grammar);
            const Kind = grammar.module.Kind;

            const source_type: SourceType = .{
                .flavor = if (tsx) .tsx else .plain,
                .language = grammar.language,
            };

            var complete = true;

            lex(source_type, source, &held.tokens) catch |err| switch (err) {
                error.Truncated => complete = false,
            };

            raw_of(Kind, held.tokens.slice(), &held.raw) catch |err| switch (err) {
                error.Truncated => return false,
            };

            held.parsed(source);

            assert(held.raw.count() == held.tokens.count());

            return complete;
        }

        fn parsed(held: *Held, source: []const u8) void {
            assert(source.len <= std.math.maxInt(u32));

            const tokens = held.tokens.slice();
            const raw = held.raw.const_slice();

            assert(tokens.len == raw.len);

            if (grammar.dialect) |dialect| {
                _ = held.parser.build(
                    source,
                    tokens,
                    raw,
                    held.events,
                    &held.tree,
                    .{ .dialect = dialect, .goal = .module },
                );
            } else {
                _ = held.parser.build(source, tokens, raw, held.events, &held.tree);
            }

            assert(held.tree.count() <= node_count_max);
        }

        fn walk(held: *Held, arena: std.mem.Allocator, source: []const u8) !Trace {
            assert(source.len <= std.math.maxInt(u32));

            const classified = held.built(source);

            assert(classified or held.tokens.items.full());

            return held.walked(arena);
        }

        fn walk_checked(held: *Held, arena: std.mem.Allocator, source: []const u8) !Trace {
            if (!held.built(source)) return error.Unwalkable;
            if (held.tree.diagnostic_slice().len > 0) return error.Unwalkable;
            return held.walked(arena);
        }

        fn walked(held: *Held, arena: std.mem.Allocator) !Trace {
            const nodes = held.tree.slice();
            const tokens = held.tokens.slice();
            const kinds = try arena.alloc([]const u8, nodes.len);
            const spans = try arena.alloc(Pair, nodes.len);

            for (nodes, kinds, spans) |node, *kind, *pair| {
                const span = node.span(Token, tokens);

                kind.* = node.kind.name();
                pair.* = .{ .offset = span.offset, .length = span.length };
            }

            assert(kinds.len == spans.len);

            return .{
                .kinds = kinds,
                .spans = spans,
                .token_count = @intCast(tokens.len),
            };
        }
    };
}

fn fixtures(
    gpa: std.mem.Allocator,
    root_path: []const u8,
    extension: []const u8,
) !std.ArrayList(Fixture) {
    const io = std.testing.io;

    assert(root_path.len > 0);
    assert(extension.len > 0);

    var found: std.ArrayList(Fixture) = .empty;
    errdefer fixtures_free(gpa, &found);

    var root = try std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
    defer root.close(io);

    var walker = try corpus.Walker.init(gpa, root);
    defer walker.deinit();

    var walked: u32 = 0;

    while (try walker.advance(io)) : (walked += 1) {
        assert(walked < file_count_max);

        const entry = walker.entry;
        const dotted = std.Io.Dir.path.extension(entry.basename);
        if (dotted.len == 0) continue;
        if (!std.mem.eql(u8, dotted[1..], extension)) continue;

        const limit: std.Io.Limit = .limited(source_bytes_max);
        const source = entry.dir.readFileAlloc(io, entry.basename, gpa, limit) catch continue;
        errdefer gpa.free(source);

        const name = try gpa.dupe(u8, entry.path);
        errdefer gpa.free(name);

        std.mem.replaceScalar(u8, name, '\\', '/');

        try found.append(gpa, .{ .name = name, .source = source });
    }

    std.mem.sort(Fixture, found.items, {}, fixture_less_than);

    assert(found.items.len <= file_count_max);

    return found;
}

fn fixture_less_than(context: void, left: Fixture, right: Fixture) bool {
    _ = context;

    assert(left.name.len > 0);
    assert(right.name.len > 0);

    return std.mem.order(u8, left.name, right.name) == .lt;
}

fn fixtures_free(gpa: std.mem.Allocator, found: *std.ArrayList(Fixture)) void {
    assert(found.items.len <= found.capacity);

    for (found.items) |fixture| {
        gpa.free(fixture.name);
        gpa.free(fixture.source);
    }

    found.deinit(gpa);
    found.* = undefined;
}

fn fixtures_of(gpa: std.mem.Allocator, comptime grammar: Grammar) !std.ArrayList(Fixture) {
    assert(grammar.directory.len <= std.math.maxInt(u32));

    const root_path = "tests/fixtures/" ++ grammar.directory;
    const found = try fixtures(gpa, root_path, grammar.extension);

    if (found.items.len == 0) {
        std.debug.print("no fixtures under {s}\n", .{root_path});

        return error.TestUnexpectedResult;
    }

    return found;
}

fn windows(arena: std.mem.Allocator, source: []const u8) ![]const u8 {
    assert(source.len <= std.math.maxInt(u32));

    var out: std.ArrayList(u8) = try .initCapacity(arena, source.len * 2);

    for (source) |byte| {
        if (byte == '\n') out.appendAssumeCapacity('\r');

        out.appendAssumeCapacity(byte);
    }

    assert(out.items.len >= source.len);

    return out.items;
}

fn noted(arena: std.mem.Allocator, note: []const u8, source: []const u8) ![]const u8 {
    assert(note.len > 0);
    assert(source.len <= std.math.maxInt(u32));

    const out = try arena.alloc(u8, note.len + source.len);

    @memcpy(out[0..note.len], note);
    @memcpy(out[note.len..], source);

    return out;
}

fn require(condition: bool, comptime format: []const u8, arguments: anytype) !void {
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    if (condition) return;

    std.debug.print(format ++ "\n", arguments);

    return error.TestUnexpectedResult;
}

fn kinds_equal(before: []const []const u8, after: []const []const u8) bool {
    if (before.len != after.len) return false;

    for (before, after) |one, two| {
        if (!std.mem.eql(u8, one, two)) return false;
    }

    return true;
}

fn expect_shifted(name: []const u8, plain: *const Trace, carried: *const Trace, width: u32) !void {
    assert(name.len > 0);

    const pair_count = @min(plain.spans.len, carried.spans.len);

    assert(width > 0);

    for (1..pair_count) |index| {
        const before = plain.spans[index];
        const after = carried.spans[index];
        const shifted = before.offset + width == after.offset;
        const kept = before.length == after.length;

        try require(shifted, "{s}: node {d} did not shift behind the note", .{ name, index });
        try require(kept, "{s}: node {d} did not shift behind the note", .{ name, index });
    }
}

fn corpus_relations(comptime grammar: Grammar, root_path: []const u8) !void {
    assert(root_path.len <= std.math.maxInt(u32));
    assert(grammar.directory.len <= std.math.maxInt(u32));

    const gpa = std.testing.allocator;
    const CorpusWorker = CorpusWorkerType(grammar);
    var files = try corpus.collect(gpa, root_path, source_bytes_max, CorpusWorker.selected);
    defer files.deinit(gpa);

    var tally: CorpusWorker.Tally = .{ .compared = 0 };

    try stripe.run(CorpusWorker, gpa, &.{}, files.slice(), &tally);

    try require(
        tally.compared >= grammar.relation.corpus,
        "{d} corpus files walked, floor {d}",
        .{ tally.compared, grammar.relation.corpus },
    );
}

fn corpus_noted(
    comptime grammar: Grammar,
    held: *HeldType(grammar),
    arena: std.mem.Allocator,
    fixture: Fixture,
    plain: *const Trace,
    width: u32,
) !void {
    assert(width < std.math.maxInt(u32));
    assert(fixture.name.len > 0);
    assert(grammar.directory.len <= std.math.maxInt(u32));

    const marked = fixture.source[scan.mark_width(fixture.source)..];
    if (std.mem.startsWith(u8, marked, "#!")) return;

    const source = try noted(arena, grammar.note, fixture.source);

    const carried = held.walk_checked(arena, source) catch |err| switch (err) {
        error.Unwalkable => return,
        else => return err,
    };

    const same = kinds_equal(plain.kinds, carried.kinds);

    try require(same, "{s}: the note changed the node kinds", .{fixture.name});
    try expect_shifted(fixture.name, plain, &carried, width);
}

fn corpus_windowed(
    comptime grammar: Grammar,
    held: *HeldType(grammar),
    arena: std.mem.Allocator,
    fixture: Fixture,
    plain: *const Trace,
) !void {
    assert(fixture.name.len > 0);
    assert(grammar.directory.len <= std.math.maxInt(u32));

    if (std.mem.findScalar(u8, fixture.source, '\r') != null) return;

    for (plain.kinds) |kind| {
        if (std.mem.startsWith(u8, kind, "jsx")) return;
    }

    const source = try windows(arena, fixture.source);

    const carried = held.walk_checked(arena, source) catch |err| switch (err) {
        error.Unwalkable => return,
        else => return err,
    };

    const same = kinds_equal(plain.kinds, carried.kinds);

    try require(same, "{s}: the line endings changed the node kinds", .{fixture.name});
}

fn head_relations(comptime grammar: Grammar) !void {
    assert(grammar.directory.len <= std.math.maxInt(u32));

    const gpa = std.testing.allocator;
    const width: u32 = @intCast(grammar.note.len);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var held: HeldType(grammar) = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var found = try fixtures_of(gpa, grammar);
    defer fixtures_free(gpa, &found);

    var compared: u32 = 0;

    for (found.items) |fixture| {
        _ = arena.reset(.retain_capacity);

        const allocator = arena.allocator();
        const plain = try held.walk(allocator, fixture.source);
        const source = try noted(allocator, grammar.note, fixture.source);
        const carried = try held.walk(allocator, source);
        const same = kinds_equal(plain.kinds, carried.kinds);

        try require(same, "{s}: the note changed the node kinds", .{fixture.name});

        try require(
            carried.token_count <= plain.token_count + 2,
            "{s}: the note added {d} tokens",
            .{ fixture.name, carried.token_count -| plain.token_count },
        );

        try expect_shifted(fixture.name, &plain, &carried, width);

        compared += 1;
    }

    try require(
        compared >= grammar.relation.every,
        "the fixtures went uncompared: {d} compared, floor {d}",
        .{ compared, grammar.relation.every },
    );
}

fn bucket_relations(comptime grammar: Grammar) !void {
    assert(grammar.directory.len <= std.math.maxInt(u32));

    const gpa = std.testing.allocator;
    var held: HeldType(grammar) = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var found = try fixtures_of(gpa, grammar);
    defer fixtures_free(gpa, &found);

    var compared: u32 = 0;

    for (found.items) |fixture| {
        const classified = held.built(fixture.source);

        assert(classified or held.tokens.items.full());

        held.index.build(&held.tree);

        try require(
            held.index.count() == held.tree.count(),
            "{s}: the index lost a node",
            .{fixture.name},
        );

        const covered = try buckets_checked(grammar, &held, fixture.name);

        try require(
            covered == held.tree.count(),
            "{s}: the buckets do not cover the tree",
            .{fixture.name},
        );

        compared += 1;
    }

    try require(
        compared >= grammar.relation.every,
        "the fixtures went uncompared: {d} compared, floor {d}",
        .{ compared, grammar.relation.every },
    );
}

fn buckets_checked(comptime grammar: Grammar, held: *HeldType(grammar), name: []const u8) !u32 {
    assert(name.len > 0);
    assert(grammar.directory.len <= std.math.maxInt(u32));

    var covered: u32 = 0;

    for (std.enums.values(Category)) |category| {
        const bucket = held.index.of(category);
        var before: ?u32 = null;

        for (bucket) |position| {
            try require(
                position < held.tree.count(),
                "{s}: {d} sits past the tree",
                .{ name, position },
            );

            try require(
                held.tree.kind_at(position).category() == category,
                "{s}: node {d} sits in the wrong bucket",
                .{ name, position },
            );

            const ascending = if (before) |held_position| held_position < position else true;

            try require(ascending, "{s}: the {s} bucket runs backwards", .{
                name,
                @tagName(category),
            });

            before = position;
        }

        covered += @intCast(bucket.len);
    }

    assert(covered <= held.index.count());

    return covered;
}

fn window_relations(comptime grammar: Grammar) !void {
    assert(grammar.directory.len <= std.math.maxInt(u32));

    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var held: HeldType(grammar) = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var found = try fixtures_of(gpa, grammar);
    defer fixtures_free(gpa, &found);

    var compared: u32 = 0;

    for (found.items) |fixture| {
        if (std.mem.findScalar(u8, fixture.source, '\r') != null) continue;
        if (skipped_of(grammar, fixture.name)) continue;

        _ = arena.reset(.retain_capacity);

        const allocator = arena.allocator();
        const plain = try held.walk(allocator, fixture.source);
        const carried = try held.walk(allocator, try windows(allocator, fixture.source));
        const same = kinds_equal(plain.kinds, carried.kinds);

        try require(same, "{s}: the carriage returns changed the node kinds", .{fixture.name});

        compared += 1;
    }

    try require(
        compared >= grammar.relation.window,
        "the fixtures went uncompared: {d} compared, floor {d}",
        .{ compared, grammar.relation.window },
    );
}

fn skipped_of(comptime grammar: Grammar, name: []const u8) bool {
    assert(name.len > 0);
    assert(grammar.directory.len <= std.math.maxInt(u32));

    for (grammar.skipped) |skipped| {
        if (std.mem.eql(u8, skipped, name)) return true;
    }

    return false;
}

test "the relations hold over the corpus" {
    const root_path = corpus.named(.root) orelse return;

    inline for (every_grammar) |grammar| {
        try corpus_relations(grammar, root_path);
    }
}

test "a comment at the head shifts the spans and adds no node" {
    inline for (every_grammar) |grammar| {
        try head_relations(grammar);
    }
}

test "a category bucket holds ascending positions in bounds" {
    inline for (every_grammar) |grammar| {
        try bucket_relations(grammar);
    }
}

test "windows line endings change no node kind" {
    inline for (every_grammar) |grammar| {
        try window_relations(grammar);
    }
}
