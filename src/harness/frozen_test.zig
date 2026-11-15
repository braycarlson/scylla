const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Buffer = @import("../stdx/bounded/buffer.zig");
const Diagnostics = @import("../lint/diagnostics.zig");
const Dialect = @import("../syntax/javascript/dialect.zig").Dialect;
const EventsType = @import("../syntax/tree.zig").EventsType;
const FileID = @import("../stdx/file_id.zig").FileID;
const Fixes = @import("../lint/fixes.zig");
const Front = @import("../syntax/front.zig").Front;
const FrontCapacity = @import("../syntax/front.zig").Front.Capacity;
const FrontOptions = @import("../syntax/front.zig").Front.Options;
const FrontScratch = @import("../syntax/front.zig").Front.Scratch;
const Language = @import("../syntax/language.zig").Language;
const Options = @import("../format/print.zig").Options;
const OutlineJavaScript = @import("../outline/javascript.zig").Outline;
const OutlinePython = @import("../outline/python.zig").Outline;
const Brackets = @import("../syntax/brackets.zig").Brackets;
const Span = @import("../stdx/bounded/span.zig");
const StaticAllocator = @import("../stdx/static_allocator.zig");
const Structure = @import("../syntax/tree.zig").Structure;
const Summary = @import("../syntax/summary.zig").Summary;
const Suppressions = @import("../lint/suppress/suppressions.zig");
const Token = @import("../syntax/token.zig");
const Tokens = @import("../syntax/tokens.zig");
const TreeType = @import("../syntax/tree.zig").TreeType;
const bind = @import("../syntax/python/bind.zig").bind;
const bounded = @import("../stdx/bounded.zig");
const corpus = @import("../testing/corpus.zig");
const format_css = @import("../format/css.zig");
const format_go = @import("../format/go.zig");
const format_ir = @import("../format/ir.zig");
const format_javascript = @import("../format/javascript.zig");
const format_markup = @import("../format/markup.zig");
const format_odin = @import("../format/odin.zig");
const format_python = @import("../format/python.zig");
const format_rust = @import("../format/rust.zig");
const format_zig = @import("../format/zig.zig");
const grammars = @import("../syntax/grammars.zig");
const lex = @import("../syntax/lex.zig").lex;
const lex_into = @import("../syntax/raw.zig").lex_into;
const LineIndex = @import("../text/line_index.zig").LineIndex;
const markup = @import("../syntax/markup.zig");
const mask = @import("../text/mask.zig");
const outline = @import("../outline.zig");
const project = @import("../index.zig");
const summary = @import("../syntax/summary.zig");

const Grammar = struct {
    dialect: ?Dialect,
    directory: []const u8,
    extension: []const u8,
    language: Language,
    module: type,
};

const Fixture = struct {
    python: bool,
    source: []u8,
};

const Sources = struct {
    fixtures: std.ArrayList(Fixture),

    fn deinit(sources: *Sources, gpa: std.mem.Allocator) void {
        assert(sources.fixtures.items.len <= sources.fixtures.capacity);

        for (sources.fixtures.items) |fixture| gpa.free(fixture.source);

        sources.fixtures.deinit(gpa);
        sources.* = undefined;
    }

    fn slice(sources: *const Sources) []const Fixture {
        assert(sources.fixtures.items.len <= file_count_max);

        return sources.fixtures.items;
    }
};

const MarkupHeld = struct {
    document: markup.Document,
    index: LineIndex,

    fn init(held: *MarkupHeld, gpa: std.mem.Allocator, scale: MarkupScale) !void {
        assert(scale.token_count_max > 0);

        held.index = try .init(gpa, scale.line_count_max);
        errdefer held.index.deinit(gpa);

        held.document = try .init(gpa, .{
            .diagnostic_count_max = scale.diagnostic_count_max,
            .node_count_max = scale.node_count_max,
            .tag_count_max = scale.tag_count_max,
            .token_count_max = scale.token_count_max,
        });

        assert(held.document.node_count() == 0);
        assert(held.document.tokens().len == 0);
    }

    fn deinit(held: *MarkupHeld, gpa: std.mem.Allocator) void {
        assert(held.document.tokens().len <= held.document.source_length());
        assert(held.index.count() <= held.index.starts.capacity());

        held.document.deinit(gpa);
        held.index.deinit(gpa);
        held.* = undefined;
    }

    fn build(held: *MarkupHeld, source: []const u8) !void {
        assert(source.len <= std.math.maxInt(u32));

        var vocabulary: markup.Vocabulary = .empty;

        vocabulary.end_prefix = "end";

        try held.index.build(source);
        try held.document.parse(source, &vocabulary);

        assert(held.document.node_count() > 0 or source.len == 0);
    }
};

const MarkupScale = struct {
    diagnostic_count_max: u32,
    line_count_max: u32,
    node_count_max: u32,
    tag_count_max: u32,
    token_count_max: u32,
};

const FixEngine = struct {
    diagnostics: Diagnostics,
    fixes: Fixes,
    held: ArrayType(Fixes.Edit),
    out: Buffer,
    tokens: Tokens,

    fn init(engine: *FixEngine, gpa: std.mem.Allocator) !void {
        engine.diagnostics = try .init(gpa, .{
            .related_count_max = 1 << 10,
            .row_count_max = 1 << 10,
            .text_bytes_max = 1 << 16,
        });

        errdefer engine.diagnostics.deinit(gpa);

        engine.fixes = try .init(gpa, .{
            .edit_count_max = 1 << 11,
            .fix_count_max = 1 << 10,
            .text_bytes_max = 1 << 14,
        });

        errdefer engine.fixes.deinit(gpa);

        engine.held = try .init(gpa, 1 << 11);
        errdefer engine.held.deinit(gpa);

        engine.out = try .init(gpa, 1 << 20);
        errdefer engine.out.deinit(gpa);

        engine.tokens = try .init(gpa, 1 << 16);

        assert(engine.held.empty());
        assert(engine.fixes.count() == 0);
    }

    fn deinit(engine: *FixEngine, gpa: std.mem.Allocator) void {
        assert(engine.held.count() <= engine.held.capacity());

        engine.tokens.deinit(gpa);
        engine.out.deinit(gpa);
        engine.held.deinit(gpa);
        engine.fixes.deinit(gpa);
        engine.diagnostics.deinit(gpa);
        engine.* = undefined;
    }

    fn run(engine: *FixEngine, source: []const u8) !void {
        assert(source.len <= std.math.maxInt(u32));

        engine.diagnostics.clear();
        engine.fixes.clear();
        engine.held.clear();
        engine.tokens.clear();

        try lex(.of(.python), source, &engine.tokens);
        record_renames(engine.tokens.slice(), &engine.fixes, &engine.diagnostics);
        engine.diagnostics.sort();

        const applied = engine.fixes.apply(&engine.out, source, .safe) catch |err| switch (err) {
            error.EditsExhausted, error.TargetExhausted, error.TextExhausted => 0,
        };

        assert(applied <= engine.fixes.count());
        assert(engine.held.count() <= engine.held.capacity());
    }
};

const ProjectFile = struct {
    language: Language,
    path: []const u8,
    source: []const u8,
};

const ProjectResolver = struct {
    pub fn resolve(
        resolver: *const ProjectResolver,
        specifier: []const u8,
        from: FileID,
        store: *const project.Store,
    ) ?u32 {
        _ = resolver;
        _ = from;

        assert(specifier.len > 0);
        assert(store.count() <= store.limits.file_count_max);

        return store.find(std.hash.Fnv1a_64.hash(specifier));
    }
};

const Extraction = struct {
    front: Front,
    islands: OutlineJavaScript,
    outline: OutlinePython,
    pairs: Brackets,
    scratch: FrontScratch,
    tokens: Tokens,

    fn init(extraction: *Extraction, gpa: std.mem.Allocator, scale: ExtractionScale) !void {
        assert(scale.token_count_max > 0);

        const capacity = scale.front_capacity();

        try extraction.scratch.init(gpa, &capacity, .initOne(.python));
        errdefer extraction.scratch.deinit(gpa);

        try extraction.front.init(gpa, &capacity, .python);
        errdefer extraction.front.deinit(gpa);

        try extraction.islands.init(gpa, .{
            .row_count_max = scale.row_count_max,
            .segment_count_max = scale.segment_count_max,
            .token_count_max = scale.token_count_max,
        });

        errdefer extraction.islands.deinit(gpa);

        try extraction.outline.init(gpa, .{
            .row_count_max = scale.row_count_max,
            .segment_count_max = scale.segment_count_max,
        });

        errdefer extraction.outline.deinit(gpa);

        extraction.pairs = try .init(gpa, scale.token_count_max);
        errdefer extraction.pairs.deinit(gpa);

        extraction.tokens = try .init(gpa, scale.token_count_max);

        assert(extraction.tokens.count() == 0);
        assert(extraction.front.node_count() == 0);
    }

    fn deinit(extraction: *Extraction, gpa: std.mem.Allocator) void {
        assert(extraction.tokens.count() <= extraction.tokens.items.capacity());
        assert(extraction.outline.definitions.count() <= extraction.outline.definitions.capacity());

        extraction.tokens.deinit(gpa);
        extraction.pairs.deinit(gpa);
        extraction.outline.deinit(gpa);
        extraction.islands.deinit(gpa);
        extraction.front.deinit(gpa);
        extraction.scratch.deinit(gpa);
        extraction.* = undefined;
    }

    fn python_build(extraction: *Extraction, source: []const u8) void {
        assert(source.len <= std.math.maxInt(u32));

        extraction.lexed(.python, source);

        const tokens = extraction.tokens.slice();
        const scratch = &extraction.scratch;
        const parsed = extraction.front.parse(scratch, .of(.python), source, &front_options);
        const complete = if (parsed) |_| true else |_| false;

        const held = extraction.front.root() orelse {
            assert(!complete or tokens.len == 0);

            extraction.outline.clear();

            return;
        };

        const root = switch (held) {
            .python => |view| view,
            else => unreachable,
        };

        extraction.tokens.clear();

        for (root.tokens) |token| {
            extraction.tokens.push(source, token) catch |err| switch (err) {
                error.Truncated => {},
            };
        }

        assert(extraction.tokens.count() == root.tokens.len);

        extraction.pairs.build(source, extraction.tokens.slice()) catch |err| switch (err) {
            error.DepthExceeded => {},
        };

        outline.python.build(source, &extraction.pairs, root, &extraction.outline);

        assert(extraction.tokens.count() <= extraction.tokens.items.capacity());
    }

    fn javascript_build(extraction: *Extraction, source: []const u8) void {
        assert(source.len <= std.math.maxInt(u32));

        extraction.lexed(.javascript, source);

        outline.javascript.build(
            source,
            extraction.tokens.slice(),
            &extraction.pairs,
            &extraction.islands,
        );

        assert(extraction.tokens.count() <= extraction.tokens.items.capacity());
    }

    fn lexed(extraction: *Extraction, language: Language, source: []const u8) void {
        assert(source.len <= std.math.maxInt(u32));
        assert(language.lexes());

        extraction.tokens.clear();

        lex(.of(language), source, &extraction.tokens) catch |err| switch (err) {
            error.Truncated => {},
        };

        extraction.pairs.build(source, extraction.tokens.slice()) catch |err| switch (err) {
            error.DepthExceeded => {},
        };

        assert(extraction.tokens.count() <= extraction.tokens.items.capacity());
    }
};

const ExtractionScale = struct {
    node_count_max: u32,
    row_count_max: u32,
    segment_count_max: u32,
    token_count_max: u32,

    fn front_capacity(scale: ExtractionScale) FrontCapacity {
        assert(scale.node_count_max > 0);
        assert(scale.token_count_max > 0);

        return .{
            .diagnostic_count_max = 1 << 8,
            .event_count_max = 2 * scale.token_count_max,
            .node_count_max = scale.node_count_max,
            .semantic = .{
                .binding_count_max = scale.row_count_max,
                .fact_count_max = scale.row_count_max,
                .reference_count_max = scale.token_count_max,
                .scope_count_max = scale.row_count_max,
            },
            .tag_count_max = 1 << 6,
            .token_count_max = scale.token_count_max,
        };
    }
};

const front_options: FrontOptions = .{
    .globals = &.{},
    .python_version = .py310,
    .vocabulary = .empty,
};

const Shard = struct {
    failed: bool,
    files: []const FileID,
    found: u32,
    out: Diagnostics,
    position: u32,
    store: *const project.Store,

    fn run(shard: *Shard) void {
        assert(shard.found == 0);
        assert(shard.position < shard_count);

        for (shard.files, 0..) |file, position| {
            if (position % shard_count != shard.position) continue;

            shard.out.clear();

            fan_out_rule(shard.store, file, &shard.out) catch {
                shard.failed = true;

                return;
            };

            shard.found += shard.out.count();
        }
    }
};

const element_count_max: u32 = 1 << 18;
const diagnostic_count_max: u32 = 1 << 10;
const file_count_max: u32 = 1 << 12;
const grammar_css = grammar_of("css", "css", "css");
const grammar_go = grammar_of("go", "go", "go");
const grammar_javascript = grammar_of("javascript", "javascript", "js");
const grammar_odin = grammar_of("odin", "odin", "odin");
const grammar_python = grammar_of("python", "python", "py");
const grammar_rust = grammar_of("rust", "rust", "rs");
const grammar_zig = grammar_of("zig", "zig", "zig");
const node_count_max: u32 = 1 << 16;
const out_bytes_max: u32 = 1 << 20;
const scratch_bytes_max: u32 = 1 << 20;
const shard_count: u32 = 4;
const source_bytes_max: u32 = 1 << 24;
const stack_depth_max: u32 = 1 << 10;
const token_count_max: u32 = 1 << 16;
const walk_step_max: u32 = 1 << 16;

const grammar_typescript: Grammar = .{
    .dialect = .typescript,
    .directory = "typescript",
    .extension = "ts",
    .language = .typescript,
    .module = grammars.javascript,
};

const template =
    "<div x-data=\"{ open: false, async load() { await go(); } }\">\n" ++
    "{% for a in b %}{{ a|title }}{% endfor %}\n" ++
    "<script>const url = 1;</script>\n</div>\n";

const code =
    "class Widget(models.Model):\n" ++
    "    name = models.CharField(max_length=10)\n\n" ++
    "def run():\n" ++
    "    return build(self, name=\"x\")\n";

fn tsx_of(comptime grammar: Grammar) bool {
    assert(grammar.directory.len <= std.math.maxInt(u32));

    const held = grammar.dialect orelse return false;
    return held == .tsx;
}

fn grammar_of(
    comptime module: []const u8,
    comptime directory: []const u8,
    comptime extension: []const u8,
) Grammar {
    comptime assert(module.len > 0);
    comptime assert(extension.len > 0);
    assert(directory.len <= std.math.maxInt(u32));

    const dialect: ?Dialect = if (std.mem.eql(u8, module, "javascript")) .javascript else null;

    return .{
        .dialect = dialect,
        .directory = directory,
        .extension = extension,
        .language = @field(Language, module),
        .module = @field(grammars, module),
    };
}

fn HeldType(comptime grammar: Grammar) type {
    comptime assert(@hasDecl(grammar.module, "Kind"));
    comptime assert(@hasDecl(grammar.module, "Parser"));

    return struct {
        events: *Events,
        parser: *grammar.module.Parser,
        raw: ArrayType(grammar.module.Kind),
        tokens: Tokens,
        tree: Tree,

        const Held = @This();
        const Events = EventsType(grammar.module.Kind);
        const Tree = TreeType(grammar.module.Kind);

        fn init(held: *Held, gpa: std.mem.Allocator, event_count_max: u32) !void {
            assert(event_count_max > 0);

            held.events = try gpa.create(Events);
            errdefer gpa.destroy(held.events);

            try held.events.init(gpa, event_count_max);
            errdefer held.events.deinit(gpa);

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
            held.events.deinit(gpa);
            gpa.destroy(held.events);
            held.* = undefined;
        }

        fn build(held: *Held, source: []const u8) !Structure {
            assert(source.len <= std.math.maxInt(u32));

            try lex_into(
                grammar.module.Kind,
                .{ .flavor = if (tsx_of(grammar)) .tsx else .plain, .language = grammar.language },
                source,
                &held.tokens,
                &held.raw,
            );

            const tokens = held.tokens.slice();
            const raw = held.raw.const_slice();

            assert(tokens.len == raw.len);

            if (grammar.dialect) |dialect| {
                return held.parser.build(
                    source,
                    tokens,
                    raw,
                    held.events,
                    &held.tree,
                    .{ .dialect = dialect, .goal = .module },
                );
            }

            return held.parser.build(source, tokens, raw, held.events, &held.tree);
        }

        fn walk(held: *const Held, source: []const u8) !u32 {
            assert(source.len <= std.math.maxInt(u32));

            const tree = &held.tree;
            const tokens = held.tokens.slice();
            var stack: [stack_depth_max]u32 = undefined;
            var depth: u32 = 0;
            var seen: u32 = 0;

            if (tree.count() > 0) {
                stack[depth] = 0;
                depth += 1;
            }

            while (depth > 0) {
                assert(seen <= tree.count());

                depth -= 1;

                const node = stack[depth];
                const span = tree.slice()[node].span(Token, tokens);

                try std.testing.expect(span.end() <= source.len);

                seen += 1;
                depth = push_children(Tree, tree, node, &stack, depth);
            }

            assert(seen <= tree.count());

            return seen;
        }
    };
}

fn push_children(
    comptime Tree: type,
    tree: *const Tree,
    node: u32,
    stack: *[stack_depth_max]u32,
    depth_start: u32,
) u32 {
    assert(node < tree.count());
    assert(depth_start <= stack_depth_max);

    var depth = depth_start;
    var child = tree.child_first_of(node);
    var visited: u32 = 0;

    while (child) |held| : (visited += 1) {
        assert(visited < tree.count());

        if (depth >= stack_depth_max) break;

        stack[depth] = held;
        depth += 1;
        child = tree.sibling_next_of(held);
    }

    assert(depth <= stack_depth_max);

    return depth;
}

fn fixtures_of(gpa: std.mem.Allocator, directory: []const u8, extension: []const u8) !Sources {
    assert(directory.len > 0);
    assert(extension.len > 0);

    return fixtures_among(gpa, directory, &.{extension});
}

fn fixtures_among(
    gpa: std.mem.Allocator,
    directory: []const u8,
    extensions: []const []const u8,
) !Sources {
    const io = std.testing.io;

    assert(directory.len > 0);
    assert(extensions.len > 0);

    var path_buffer: [256]u8 = undefined;
    const root_path = try std.mem.print(&path_buffer, "tests/fixtures/{s}", .{directory});
    var sources: Sources = .{ .fixtures = .empty };
    errdefer sources.deinit(gpa);

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
        if (!extension_among(dotted[1..], extensions)) continue;

        const limit: std.Io.Limit = .limited(source_bytes_max);
        const source = entry.dir.readFileAlloc(io, entry.basename, gpa, limit) catch continue;
        errdefer gpa.free(source);

        const python = std.mem.eql(u8, dotted[1..], "py");

        try sources.fixtures.append(gpa, .{ .python = python, .source = source });
    }

    assert(sources.fixtures.items.len <= file_count_max);

    return sources;
}

fn extension_among(extension: []const u8, extensions: []const []const u8) bool {
    assert(extensions.len > 0);
    assert(extensions.len <= file_count_max);
    assert(extension.len <= std.math.maxInt(u32));

    for (extensions) |wanted| {
        if (std.mem.eql(u8, extension, wanted)) return true;
    }

    return false;
}

fn syntax_layer(
    comptime grammar: Grammar,
    source_count_floor: u32,
    event_count_max: u32,
) !void {
    assert(source_count_floor > 0);
    assert(event_count_max > 0);
    assert(grammar.directory.len <= std.math.maxInt(u32));

    const gpa = std.testing.allocator;
    var sources = try fixtures_of(gpa, grammar.directory, grammar.extension);
    defer sources.deinit(gpa);

    try std.testing.expect(sources.slice().len > source_count_floor);

    var static_allocator: StaticAllocator = .init(gpa);
    defer static_allocator.deinit();

    var held: HeldType(grammar) = undefined;

    try held.init(static_allocator.allocator(), event_count_max);
    defer held.deinit(static_allocator.allocator());

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    for (sources.slice()) |fixture| {
        const source = fixture.source;

        _ = try held.build(source);

        const seen = try held.walk(source);

        try std.testing.expect(seen > 0);
    }

    try std.testing.expect(static_allocator.is_static());
}

fn semantic_model(
    comptime grammar: Grammar,
    directory: []const u8,
    source_count_floor: u32,
    globals: []const []const u8,
) !void {
    assert(directory.len > 0);
    assert(source_count_floor > 0);
    assert(globals.len <= std.math.maxInt(u32));
    assert(grammar.directory.len <= std.math.maxInt(u32));

    const gpa = std.testing.allocator;
    const Semantic = grammar.module.Semantic;
    var sources = try fixtures_of(gpa, directory, grammar.extension);
    defer sources.deinit(gpa);

    try std.testing.expect(sources.slice().len > source_count_floor);

    var static_allocator: StaticAllocator = .init(gpa);
    defer static_allocator.deinit();

    var held: HeldType(grammar) = undefined;

    try held.init(static_allocator.allocator(), 1 << 18);
    defer held.deinit(static_allocator.allocator());

    var semantic: Semantic = undefined;

    try semantic.init(static_allocator.allocator(), &.{
        .binding_count_max = 1 << 12,
        .fact_count_max = 1 << 10,
        .reference_count_max = 1 << 14,
        .scope_count_max = 1 << 10,
    });

    defer semantic.deinit(static_allocator.allocator());

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    for (sources.slice()) |fixture| {
        const source = fixture.source;

        _ = try held.build(source);

        const outcome = semantic_build(grammar, &semantic, &held, source, globals);

        try std.testing.expectEqual(Structure.complete, outcome);
        try std.testing.expect(semantic.count() > 0);
    }

    try std.testing.expect(static_allocator.is_static());
}

fn semantic_build(
    comptime grammar: Grammar,
    semantic: *grammar.module.Semantic,
    held: *const HeldType(grammar),
    source: []const u8,
    globals: []const []const u8,
) Structure {
    assert(globals.len <= std.math.maxInt(u32));
    assert(grammar.directory.len <= std.math.maxInt(u32));

    const tokens = held.tokens.slice();
    const raw = held.raw.const_slice();

    assert(tokens.len == raw.len);
    assert(source.len <= std.math.maxInt(u32));

    return switch (grammar.language) {
        .css => semantic.build(source, tokens, raw, &held.tree),
        .javascript, .typescript => semantic.build(
            source,
            tokens,
            raw,
            &held.tree,
            &.{ .globals = globals, .module = null, .typed = grammar.language == .typescript },
        ),
        else => semantic.build(source, tokens, raw, &held.tree, globals),
    };
}

fn formatter_run(
    comptime grammar: Grammar,
    comptime Module: type,
    source_count_floor: u32,
    complete_required: bool,
) !void {
    comptime assert(@hasDecl(Module, "Formatter"));
    comptime assert(@hasDecl(Module, "Input"));
    assert(grammar.directory.len <= std.math.maxInt(u32));

    const gpa = std.testing.allocator;
    var sources = try fixtures_of(gpa, grammar.directory, grammar.extension);
    defer sources.deinit(gpa);

    try std.testing.expect(sources.slice().len > source_count_floor);

    var static_allocator: StaticAllocator = .init(gpa);
    defer static_allocator.deinit();

    var held: HeldType(grammar) = undefined;

    try held.init(static_allocator.allocator(), 1 << 18);
    defer held.deinit(static_allocator.allocator());

    var formatter = try Module.Formatter.init(
        static_allocator.allocator(),
        element_count_max,
        scratch_bytes_max,
    );

    defer formatter.deinit(static_allocator.allocator());

    var out = try Buffer.init(static_allocator.allocator(), out_bytes_max);
    defer out.deinit(static_allocator.allocator());

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    for (sources.slice()) |fixture| {
        const source = fixture.source;
        const outcome = try held.build(source);

        const input: Module.Input = .{
            .options = Options.default,
            .outcome = outcome,
            .raw = held.raw.const_slice(),
            .source = source,
            .tokens = held.tokens.slice(),
            .tree = &held.tree,
        };

        const formatted = formatter.format(&input, &out);

        if (complete_required) {
            try formatted;
        } else {
            formatted catch |err| switch (err) {
                error.OutputExhausted => return err,
                error.SourceInvalid => {},
            };
        }
    }

    try std.testing.expect(static_allocator.is_static());
}

fn tables_init(tables: *grammars.python.bind.Tables, gpa: std.mem.Allocator) !void {
    try tables.init(gpa, &.{
        .binding_count_max = 1 << 14,
        .reference_count_max = 1 << 16,
        .scope_count_max = 1 << 10,
        .segment_count_max = 1 << 12,
    });

    assert(tables.scopes.count() == 0);
    assert(tables.bindings.count() == 0);
}

fn record_renames(tokens: []const Token, fixes: *Fixes, diagnostics: *Diagnostics) void {
    assert(fixes.count() == 0);
    assert(diagnostics.count() == 0);
    assert(tokens.len <= std.math.maxInt(u32));

    for (tokens) |token| {
        if (token.kind != .identifier) continue;

        fixes.open("Rename", .safe, null);

        fixes.edit(token.span(), "held") catch |err| switch (err) {
            error.EditsExhausted, error.TargetExhausted, error.TextExhausted => {
                _ = fixes.close();

                break;
            },
        };

        const index = fixes.close() orelse break;

        diagnostics.push(.{
            .code = "PR001",
            .fix = index,
            .message = .{ .static = "a name is renamed" },
            .related_count = 0,
            .related_start = 0,
            .rule = null,
            .severity = .warning,
            .span = token.span(),
        }) catch break;
    }
}

fn project_front_capacity(shift: u32) FrontCapacity {
    assert(shift <= 2);

    return .{
        .diagnostic_count_max = @as(u32, 1 << 8) >> @intCast(shift),
        .event_count_max = @as(u32, 1 << 14) >> @intCast(shift),
        .node_count_max = @as(u32, 1 << 13) >> @intCast(shift),
        .semantic = .{
            .binding_count_max = @as(u32, 1 << 10) >> @intCast(shift),
            .fact_count_max = @as(u32, 1 << 10) >> @intCast(shift),
            .reference_count_max = @as(u32, 1 << 10) >> @intCast(shift),
            .scope_count_max = @as(u32, 1 << 8) >> @intCast(shift),
        },
        .tag_count_max = @as(u32, 1 << 10) >> @intCast(shift),
        .token_count_max = @as(u32, 1 << 12) >> @intCast(shift),
    };
}

fn project_limits() project.Store.Limits {
    var slots: [Language.count][project.Store.class_count]u32 = @splat(@splat(0));
    const class = project.Store.Limits.class_of(1 << 14);

    assert(class < project.Store.class_count);

    slots[@backingInt(Language.css)][class] = 1;
    slots[@backingInt(Language.go)][class] = 1;
    slots[@backingInt(Language.markup)][class] = 1;
    slots[@backingInt(Language.python)][class] = 2;
    slots[@backingInt(Language.rust)][class] = 1;
    slots[@backingInt(Language.typescript)][class] = 1;

    return .{
        .file_count_max = 7,
        .front = project_front_capacity(0),
        .line_count_max = 1 << 10,
        .slots = slots,
        .source_bytes_max = 1 << 14,
    };
}

fn project_small_limits(project_file_count: u32) project.Store.Limits {
    var slots: [Language.count][project.Store.class_count]u32 = @splat(@splat(0));

    assert(project_file_count > 0);

    const class = project.Store.Limits.class_of(1 << 10);

    slots[@backingInt(Language.python)][class] = project_file_count;

    return .{
        .file_count_max = project_file_count,
        .front = project_front_capacity(2),
        .line_count_max = 1 << 8,
        .slots = slots,
        .source_bytes_max = 1 << 10,
    };
}

fn fan_out_rule(store: *const project.Store, file: FileID, out: *Diagnostics) !void {
    assert(@backingInt(file) != std.math.maxInt(u32));

    var walk = project.view.walk(store, file);

    for (0..walk_step_max) |_| {
        const step = walk.next() orelse break;

        const node = switch (step) {
            .enter => |held| held,
            .leave => continue,
        };

        const held = project.view.python(store, file, node) orelse continue;

        try out.push(.{
            .code = "PRJ901",
            .fix = null,
            .message = .{ .static = "a recorded finding" },
            .related_count = 0,
            .related_start = 0,
            .rule = null,
            .severity = .hint,
            .span = held.span(),
        });
    }

    assert(out.count() <= walk_step_max);
}

fn fan_out_single(store: *const project.Store, files: []const FileID, out: *Diagnostics) !u32 {
    var found: u32 = 0;

    assert(files.len > 0);
    assert(files.len <= store.limits.file_count_max);

    for (files) |file| {
        out.clear();
        try fan_out_rule(store, file, out);

        found += out.count();
    }

    return found;
}

fn fan_out_threads(shards: *[shard_count]Shard, files: []const FileID) !void {
    var threads: [shard_count]std.Thread = undefined;
    var spawned: u32 = 0;
    defer for (threads[0..spawned]) |thread| thread.join();

    assert(files.len > 0);

    for (shards) |*shard| {
        shard.files = files;
        threads[spawned] = try std.Thread.spawn(.{}, Shard.run, .{shard});
        spawned += 1;
    }

    assert(spawned == shard_count);
}

test "the javascript syntax layer runs on a frozen thread" {
    try syntax_layer(grammar_javascript, 4, 1 << 18);
}

test "the rust syntax layer runs on a frozen thread" {
    try syntax_layer(grammar_rust, 4, 1 << 19);
}

test "the go syntax layer runs on a frozen thread" {
    try syntax_layer(grammar_go, 4, 1 << 19);
}

test "the zig syntax layer runs on a frozen thread" {
    try syntax_layer(grammar_zig, 4, 1 << 19);
}

test "the odin syntax layer runs on a frozen thread" {
    try syntax_layer(grammar_odin, 4, 1 << 19);
}

test "the css syntax layer runs on a frozen thread" {
    try syntax_layer(grammar_css, 4, 1 << 19);
}

test "the typescript syntax layer runs on a frozen thread" {
    try syntax_layer(grammar_typescript, 4, 1 << 19);
}

test "the javascript semantic model runs on a frozen thread" {
    const globals = [_][]const u8{ "console", "eval", "require" };

    try semantic_model(grammar_javascript, "javascript-semantic", 8, &globals);
}

test "the typescript semantic model runs on a frozen thread" {
    const globals = [_][]const u8{ "console", "eval", "require" };

    try semantic_model(grammar_typescript, "typescript-semantic", 2, &globals);
}

test "the go semantic model runs on a frozen thread" {
    const universe = [_][]const u8{ "error", "len", "string" };

    try semantic_model(grammar_go, "go-semantic", 3, &universe);
}

test "the rust semantic model runs on a frozen thread" {
    const universe = [_][]const u8{ "Self", "usize", "Some" };

    try semantic_model(grammar_rust, "rust-semantic", 6, &universe);
}

test "the zig semantic model runs on a frozen thread" {
    const universe = [_][]const u8{ "bool", "usize", "void" };

    try semantic_model(grammar_zig, "zig-semantic", 4, &universe);
}

test "the odin semantic model runs on a frozen thread" {
    const universe = [_][]const u8{ "bool", "int", "string" };

    try semantic_model(grammar_odin, "odin-semantic", 3, &universe);
}

test "the css reference model runs on a frozen thread" {
    try semantic_model(grammar_css, "css-semantic", 3, &.{});
}

test "the go formatter runs on a frozen thread" {
    try formatter_run(grammar_go, format_go, 4, true);
}

test "the rust formatter runs on a frozen thread" {
    try formatter_run(grammar_rust, format_rust, 4, true);
}

test "the zig formatter runs on a frozen thread" {
    try formatter_run(grammar_zig, format_zig, 4, true);
}

test "the css formatter runs on a frozen thread" {
    try formatter_run(grammar_css, format_css, 3, true);
}

test "the javascript formatter runs on a frozen thread" {
    try formatter_run(grammar_javascript, format_javascript, 8, false);
}

test "the odin formatter runs on a frozen thread" {
    try formatter_run(grammar_odin, format_odin, 3, true);
}

test "the syntax layer runs on a frozen thread" {
    const gpa = std.testing.allocator;
    var sources = try fixtures_among(gpa, "python", &.{ "html", "py" });
    defer sources.deinit(gpa);

    try std.testing.expect(sources.slice().len > 8);

    var static_allocator: StaticAllocator = .init(gpa);
    defer static_allocator.deinit();

    var held: HeldType(grammar_python) = undefined;

    try held.init(static_allocator.allocator(), 1 << 18);
    defer held.deinit(static_allocator.allocator());

    var tables: grammars.python.bind.Tables = undefined;

    try tables_init(&tables, static_allocator.allocator());
    defer tables.deinit(static_allocator.allocator());

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    for (sources.slice()) |fixture| {
        const source = fixture.source;

        _ = try held.build(source);

        const seen = try held.walk(source);

        try std.testing.expect(seen > 0);

        try bind(source, held.tokens.slice(), held.raw.const_slice(), &held.tree, &tables);

        try std.testing.expect(tables.scopes.count() > 0);
    }

    try std.testing.expect(static_allocator.is_static());
}

test "the python semantic model runs on a frozen thread" {
    const gpa = std.testing.allocator;
    const builtins = [_][]const u8{ "len", "list", "print", "str" };
    var sources = try fixtures_of(gpa, "python-semantic", "py");
    defer sources.deinit(gpa);

    try std.testing.expect(sources.slice().len > 8);

    var static_allocator: StaticAllocator = .init(gpa);
    defer static_allocator.deinit();

    var held: HeldType(grammar_python) = undefined;

    try held.init(static_allocator.allocator(), 1 << 18);
    defer held.deinit(static_allocator.allocator());

    var semantic: grammars.python.Semantic = undefined;

    try semantic.init(static_allocator.allocator(), &.{
        .binding_count_max = 1 << 12,
        .fact_count_max = 1 << 12,
        .reference_count_max = 1 << 14,
        .scope_count_max = 1 << 12,
    });

    defer semantic.deinit(static_allocator.allocator());

    var scratch: grammars.python.AnnotationScratch = undefined;

    try scratch.init(
        static_allocator.allocator(),
        &.{ .node_count_max = 1 << 8, .token_count_max = 1 << 8 },
    );

    defer scratch.deinit(static_allocator.allocator());

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    for (sources.slice()) |fixture| {
        const source = fixture.source;

        _ = try held.build(source);

        const outcome = semantic.build(&.{
            .builtins = &builtins,
            .raw = held.raw.const_slice(),
            .source = source,
            .tokens = held.tokens.slice(),
            .tree = &held.tree,
            .version = .py310,
        }, &scratch);

        try std.testing.expectEqual(Structure.complete, outcome);
        try std.testing.expect(semantic.count() > 0);
    }

    try std.testing.expect(static_allocator.is_static());
}

test "the python formatter runs on a frozen thread" {
    const gpa = std.testing.allocator;
    var sources = try fixtures_of(gpa, "python", "py");
    defer sources.deinit(gpa);

    try std.testing.expect(sources.slice().len > 8);

    var static_allocator: StaticAllocator = .init(gpa);
    defer static_allocator.deinit();

    var held: HeldType(grammar_python) = undefined;

    try held.init(static_allocator.allocator(), 1 << 18);
    defer held.deinit(static_allocator.allocator());

    var formatter = try format_python.Formatter.init(
        static_allocator.allocator(),
        1 << 18,
        1 << 18,
    );

    defer formatter.deinit(static_allocator.allocator());

    var out = try Buffer.init(static_allocator.allocator(), out_bytes_max);
    defer out.deinit(static_allocator.allocator());

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    for (sources.slice()) |fixture| {
        const source = fixture.source;
        const outcome = try held.build(source);

        const input: format_python.Input = .{
            .line_ending = .line_feed,
            .magic_trailing_comma = true,
            .options = Options.default,
            .outcome = outcome,
            .pragmas = &.{},
            .quote = .double,
            .raw = held.raw.const_slice(),
            .source = source,
            .stub = false,
            .tokens = held.tokens.slice(),
            .tree = &held.tree,
        };

        try formatter.format(&input, &out);
        try std.testing.expect(!out.empty());
    }

    try std.testing.expect(static_allocator.is_static());
}

test "the markup layer runs on a frozen thread" {
    const gpa = std.testing.allocator;
    var static_allocator: StaticAllocator = .init(gpa);
    defer static_allocator.deinit();

    var held: MarkupHeld = undefined;

    try held.init(static_allocator.allocator(), .{
        .diagnostic_count_max = 128,
        .line_count_max = 256,
        .node_count_max = 1_024,
        .tag_count_max = 256,
        .token_count_max = 4_096,
    });

    defer held.deinit(static_allocator.allocator());

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    try held.build(template);
    try std.testing.expect(held.document.node_count() > 0);
    try std.testing.expect(held.document.blocks().tag_slice().len > 0);
    try std.testing.expect(static_allocator.is_static());
}

test "the markup formatter runs on a frozen thread" {
    const gpa = std.testing.allocator;
    var sources = try fixtures_among(gpa, "templates", &.{ "html", "py" });
    defer sources.deinit(gpa);

    try std.testing.expect(sources.slice().len > 300);

    var static_allocator: StaticAllocator = .init(gpa);
    defer static_allocator.deinit();

    var held: MarkupHeld = undefined;

    try held.init(static_allocator.allocator(), .{
        .diagnostic_count_max = 1 << 10,
        .line_count_max = 1 << 14,
        .node_count_max = 1 << 17,
        .tag_count_max = 1 << 12,
        .token_count_max = 1 << 18,
    });

    defer held.deinit(static_allocator.allocator());

    var formatter = try format_markup.Formatter.init(
        static_allocator.allocator(),
        1 << 18,
        1 << 14,
        1 << 20,
    );

    defer formatter.deinit(static_allocator.allocator());

    var out = try Buffer.init(static_allocator.allocator(), out_bytes_max);
    defer out.deinit(static_allocator.allocator());

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    for (sources.slice()) |fixture| {
        if (fixture.python) continue;

        try held.build(fixture.source);

        const input: format_markup.Input = .{
            .index = &held.index,
            .map = held.document.blocks(),
            .options = Options.default,
            .source = fixture.source,
            .tokens = held.document.tokens(),
            .tree = held.document.tree(),
        };

        formatter.format(&input, &out) catch |err| switch (err) {
            error.OutputExhausted => return err,
            error.SourceInvalid => {},
        };
    }

    try std.testing.expect(static_allocator.is_static());
}

test "the derived tables run on a frozen thread" {
    const gpa = std.testing.allocator;
    const names = [_][]const u8{ "base.html", "partials/row.html", "index.html", "mail.txt" };
    var static_allocator: StaticAllocator = .init(gpa);
    defer static_allocator.deinit();

    var arena = try bounded.Buffer.init(static_allocator.allocator(), 4_096);
    defer arena.deinit(static_allocator.allocator());

    var table = try bounded.TableType(u32).init(static_allocator.allocator(), 64);
    defer table.deinit(static_allocator.allocator());

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    for (names, 0..) |name, row| {
        const key = try arena.intern(name);
        const probe: bounded.TableProbe = .{ .arena = &arena, .bytes = name };

        try table.insert(std.hash.Fnv1a_64.hash(name), key, @intCast(row), probe);
    }

    for (names, 0..) |name, row| {
        const probe: bounded.TableProbe = .{ .arena = &arena, .bytes = name };
        const expected: ?u32 = @intCast(row);

        try std.testing.expectEqual(expected, table.get(std.hash.Fnv1a_64.hash(name), probe));
    }

    try std.testing.expectEqual(4, table.count());

    table.clear();
    arena.clear();

    try std.testing.expect(table.empty());
    try std.testing.expect(arena.empty());
}

test "the fix engine runs on a frozen thread" {
    const gpa = std.testing.allocator;
    var sources = try fixtures_of(gpa, "python", "py");
    defer sources.deinit(gpa);

    try std.testing.expect(sources.slice().len > 8);

    var static_allocator: StaticAllocator = .init(gpa);
    defer static_allocator.deinit();

    var engine: FixEngine = undefined;

    try engine.init(static_allocator.allocator());
    defer engine.deinit(static_allocator.allocator());

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    for (sources.slice()) |fixture| try engine.run(fixture.source);

    try std.testing.expect(static_allocator.is_static());
}

test "the suppression scanner runs on a frozen thread" {
    const gpa = std.testing.allocator;
    var sources = try fixtures_of(gpa, "python", "py");
    defer sources.deinit(gpa);

    try std.testing.expect(sources.slice().len > 8);

    var static_allocator: StaticAllocator = .init(gpa);
    defer static_allocator.deinit();

    var index = try LineIndex.init(static_allocator.allocator(), 1 << 16);
    defer index.deinit(static_allocator.allocator());

    var spans = try ArrayType(Span).init(static_allocator.allocator(), 1 << 14);
    defer spans.deinit(static_allocator.allocator());

    var suppressions = try Suppressions.init(static_allocator.allocator(), .{
        .code_count_max = 1 << 13,
        .directive_count_max = 1 << 12,
    });

    defer suppressions.deinit(static_allocator.allocator());

    var tokens = try Tokens.init(static_allocator.allocator(), 1 << 16);
    defer tokens.deinit(static_allocator.allocator());

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    for (sources.slice()) |fixture| {
        const source = fixture.source;

        try index.build(source);
        spans.clear();
        tokens.clear();
        try lex(.of(.python), source, &tokens);

        for (tokens.slice()) |token| {
            if (token.kind != .comment) continue;
            if (spans.full()) break;

            spans.push(token.span());
        }

        const prefixes = [_][]const u8{ "flake8:", "ruff:" };

        try suppressions.scan(source, spans.const_slice(), "noqa", &prefixes, &index);

        for (0..suppressions.count()) |directive| {
            const held = suppressions.at(@intCast(directive));

            _ = suppressions.matches(held.line, "F401", source);
        }

        var unconsumed = suppressions.unconsumed();
        var visited: u32 = 0;

        while (unconsumed.next()) |_| : (visited += 1) {
            assert(visited < suppressions.count());
        }
    }

    try std.testing.expect(static_allocator.is_static());
}

test "the formatting document runs on a frozen thread" {
    const gpa = std.testing.allocator;
    var sources = try fixtures_of(gpa, "python", "py");
    defer sources.deinit(gpa);

    try std.testing.expect(sources.slice().len > 8);

    var static_allocator: StaticAllocator = .init(gpa);
    defer static_allocator.deinit();

    var document = try format_ir.Document.init(static_allocator.allocator(), 1 << 17, 1 << 4);
    defer document.deinit(static_allocator.allocator());

    var tokens = try Tokens.init(static_allocator.allocator(), 1 << 16);
    defer tokens.deinit(static_allocator.allocator());

    const comma = document.literal(",");
    const span = document.literal_span(comma);

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    for (sources.slice()) |fixture| {
        document.clear();
        tokens.clear();
        try lex(.of(.python), fixture.source, &tokens);

        document.push(.group_open) catch continue;

        for (tokens.slice()) |token| {
            const text: format_ir.Element = .{
                .text = .{ .source = .document, .span = token.span() },
            };

            document.push(text) catch break;
            document.push(.{ .if_broken = span }) catch break;
            document.push(.line) catch break;
        }

        try std.testing.expect(document.count() > 0);
    }

    try std.testing.expect(static_allocator.is_static());
}

test "the project store runs on a frozen thread" {
    const gpa = std.testing.allocator;
    const python_source = "import os\n\n\ndef run():\n    return os\n";
    const limits = project_limits();
    var static_allocator: StaticAllocator = .init(gpa);
    defer static_allocator.deinit();

    var store: project.Store = undefined;

    try store.init(static_allocator.allocator(), &limits, .least_recently_used);
    defer store.deinit(static_allocator.allocator());

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    const files = [_]ProjectFile{
        .{ .language = .css, .path = "a.css", .source = "a { color: red; }\n" },
        .{
            .language = .go,
            .path = "a.go",
            .source = "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(1)\n}\n",
        },
        .{
            .language = .markup,
            .path = "a.html",
            .source = "<div>{% block body %}{% endblock %}</div>\n",
        },
        .{ .language = .python, .path = "a.py", .source = python_source },
        .{ .language = .python, .path = "b.py", .source = python_source },
        .{ .language = .rust, .path = "a.rs", .source = "fn run() -> u32 {\n    1\n}\n" },
        .{
            .language = .typescript,
            .path = "a.ts",
            .source = "export const one: number = 1;\n",
        },
    };

    for (files) |file| {
        const key = std.hash.Fnv1a_64.hash(file.path);
        const index = try store.insert(key, .of(file.language), file.source);

        try std.testing.expectEqualStrings(file.source, store.source_of(.of(index)));
    }

    try std.testing.expectEqual(7, store.count());

    for (0..64) |round| {
        const path: []const u8 = if (round % 2 == 0) "c.py" else "d.py";
        const index = try store.insert(std.hash.Fnv1a_64.hash(path), .of(.python), python_source);

        store.touch(.of(index));
        store.evict(.of(index));
    }

    store.clear();

    try std.testing.expectEqual(0, store.count());
}

test "the project graph runs on a frozen thread" {
    const gpa = std.testing.allocator;
    const limits = project_small_limits(5);

    const sources = [_][2][]const u8{
        .{ "a", "import b\nimport c\n" },
        .{ "b", "import d\n" },
        .{ "c", "import d\nimport missing\n" },
        .{ "d", "import a\n" },
        .{ "e", "x = 1\n" },
    };

    var static_allocator: StaticAllocator = .init(gpa);
    defer static_allocator.deinit();

    var store: project.Store = undefined;

    try store.init(static_allocator.allocator(), &limits, .reject);
    defer store.deinit(static_allocator.allocator());

    var graph = try project.Graph.init(static_allocator.allocator(), 1 << 8, 5);
    defer graph.deinit(static_allocator.allocator());

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    for (sources) |pair| {
        _ = try store.insert(std.hash.Fnv1a_64.hash(pair[0]), .of(.python), pair[1]);
    }

    for (0..64) |_| {
        try graph.build(&store, ProjectResolver, &.{});
        try std.testing.expectEqual(5, graph.order().len);

        var cycles = graph.cycles();
        var cycle_count: u32 = 0;

        while (cycles.next()) |_| : (cycle_count += 1) {
            assert(cycle_count < 5);
        }

        try std.testing.expectEqual(1, cycle_count);

        graph.clear();

        try std.testing.expectEqual(0, graph.count());
    }
}

test "every fixture runs on a frozen thread" {
    const gpa = std.testing.allocator;
    var sources = try fixtures_among(gpa, "templates", &.{ "html", "py" });
    defer sources.deinit(gpa);

    try std.testing.expect(sources.slice().len > 300);

    var static_allocator: StaticAllocator = .init(gpa);
    defer static_allocator.deinit();

    var extraction: Extraction = undefined;

    try extraction.init(static_allocator.allocator(), .{
        .node_count_max = 1 << 17,
        .row_count_max = 1 << 13,
        .segment_count_max = 1 << 14,
        .token_count_max = 1 << 17,
    });

    defer extraction.deinit(static_allocator.allocator());

    var held: MarkupHeld = undefined;

    try held.init(static_allocator.allocator(), .{
        .diagnostic_count_max = 1 << 10,
        .line_count_max = 1 << 16,
        .node_count_max = 1 << 17,
        .tag_count_max = 1 << 12,
        .token_count_max = 1 << 18,
    });

    defer held.deinit(static_allocator.allocator());

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    for (sources.slice()) |fixture| {
        if (fixture.python) {
            try held.index.build(fixture.source);
            extraction.python_build(fixture.source);

            continue;
        }

        try held.build(fixture.source);
        extraction.javascript_build(fixture.source);
    }

    try std.testing.expect(static_allocator.is_static());
}

test "the extraction layer runs on a frozen thread" {
    const gpa = std.testing.allocator;
    var static_allocator: StaticAllocator = .init(gpa);
    defer static_allocator.deinit();

    var extraction: Extraction = undefined;

    try extraction.init(static_allocator.allocator(), .{
        .node_count_max = 256,
        .row_count_max = 256,
        .segment_count_max = 512,
        .token_count_max = 4_096,
    });

    defer extraction.deinit(static_allocator.allocator());

    var segments = try ArrayType(Span).init(static_allocator.allocator(), 64);
    defer segments.deinit(static_allocator.allocator());

    var items = try ArrayType(Summary).init(static_allocator.allocator(), 64);
    defer items.deinit(static_allocator.allocator());

    const prepared = try static_allocator.allocator().alloc(u8, 4_096);
    defer static_allocator.allocator().free(prepared);

    @memset(prepared, 0);

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    extraction.python_build(code);

    const run: summary.Run = .{ .token_end = 4, .token_start = 0 };
    const tables: summary.Tables = .{ .items = &items, .segments = &segments };

    _ = summary.read(code, extraction.tokens.slice(), &extraction.pairs, run, tables);
    _ = mask.write(code, .{ .length = 21, .offset = 0 }, &.{}, prepared);

    extraction.javascript_build(code);

    try std.testing.expect(extraction.outline.calls.count() > 0);
    try std.testing.expect(extraction.islands.scopes.count() > 0);
}

const fan_out_capacity: Diagnostics.Capacity = .{
    .related_count_max = 1 << 12,
    .row_count_max = 1 << 12,
    .text_bytes_max = 1 << 16,
};

test "a project fan out runs on frozen threads" {
    const gpa = std.testing.allocator;
    const limits = project_small_limits(16);
    const source = "value = 1\n\n\ndef run():\n    return value\n";
    var static_allocator: StaticAllocator = .init(gpa);
    defer static_allocator.deinit();

    var store: project.Store = undefined;

    try store.init(static_allocator.allocator(), &limits, .reject);
    defer store.deinit(static_allocator.allocator());

    for (0..16) |index| {
        const tens: u8 = @intCast(index / 10);
        const units: u8 = @intCast(index % 10);
        const key = [_]u8{ 'f', '0' + tens, '0' + units };

        _ = try store.insert(std.hash.Fnv1a_64.hash(&key), .of(.python), source);
    }

    var shards: [shard_count]Shard = undefined;
    var shards_ready: u32 = 0;
    defer for (shards[0..shards_ready]) |*shard| shard.out.deinit(static_allocator.allocator());

    var files_buffer: [16]FileID = undefined;
    var file_count: u32 = 0;
    var files = store.files();

    for (&shards, 0..) |*shard, position| {
        shard.* = .{
            .failed = false,
            .files = &.{},
            .found = 0,
            .out = try .init(static_allocator.allocator(), fan_out_capacity),
            .position = @intCast(position),
            .store = &store,
        };

        shards_ready += 1;
    }

    var single_out = try Diagnostics.init(static_allocator.allocator(), fan_out_capacity);
    defer single_out.deinit(static_allocator.allocator());

    for (0..files_buffer.len) |_| {
        const file = files.next() orelse break;

        files_buffer[file_count] = file;
        file_count += 1;
    }

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    const held_files = files_buffer[0..file_count];
    const single = try fan_out_single(&store, held_files, &single_out);

    try fan_out_threads(&shards, held_files);

    var merged: u32 = 0;

    for (shards) |shard| {
        try std.testing.expect(!shard.failed);

        merged += shard.found;
    }

    try std.testing.expectEqual(single, merged);
    try std.testing.expect(merged > 0);
}
