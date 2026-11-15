const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const EventsType = @import("../syntax/tree.zig").EventsType;
const Language = @import("../syntax/language.zig").Language;
const Tokens = @import("../syntax/tokens.zig");
const TreeType = @import("../syntax/tree.zig").TreeType;
const corpus = @import("../testing/corpus.zig");
const floor = @import("../testing/floor.zig");
const grammars = @import("../syntax/grammars.zig");
const lex_into = @import("../syntax/raw.zig").lex_into;
const scan = @import("../text/scan.zig");
const stripe = @import("../testing/stripe.zig");

const Family = enum {
    plain,
    python,
    script,
    typed,
};

const Grammar = struct {
    comment: []const u8,
    directory: []const u8,
    extension: []const u8,
    family: Family,
    language: Language,
    module: type,
    name: []const u8,
    wrapped: ?Wrapped,
};

const Link = struct {
    binding: u32,
    reference: u32,
};

const Renaming = struct {
    name: []const u8,
    replacement: []const u8,
};

const Summary = struct {
    bindings: std.ArrayList([]const u8),
    chain: std.ArrayList(Link),
    offsets: std.ArrayList(u32),
    parents: std.ArrayList(u32),
    references: std.ArrayList([]const u8),
    scopes: std.ArrayList([]const u8),

    const blank: Summary = .{
        .bindings = .empty,
        .chain = .empty,
        .offsets = .empty,
        .parents = .empty,
        .references = .empty,
        .scopes = .empty,
    };
};

const Wrapped = struct {
    plain: []const u8,
    wrapped: []const u8,
};

const annotation_count_max: u32 = 1 << 8;
const diagnostic_count_max: u32 = 1 << 12;
const event_count_max: u32 = 1 << 20;
const file_count_max: u32 = 1 << 20;
const fixture_count_min: u32 = 20;
const node_count_max: u32 = 1 << 18;
const none: u32 = std.math.maxInt(u32);
const source_bytes_max: u32 = 1 << 28;
const table_count_max: u32 = 1 << 16;
const token_count_max: u32 = 1 << 18;
const wrapped_count: u32 = 6;
const word_count_max: u32 = 1 << 12;

const every_grammar = [_]Grammar{
    .{
        .comment = "# scylla\n",
        .directory = "tests/fixtures/python-semantic",
        .extension = "py",
        .family = .python,
        .language = .python,
        .module = grammars.python,
        .name = "python",
        .wrapped = null,
    },
    .{
        .comment = "// scylla\n",
        .directory = "tests/fixtures/javascript-semantic",
        .extension = "js",
        .family = .script,
        .language = .javascript,
        .module = grammars.javascript,
        .name = "javascript",
        .wrapped = .{
            .plain = "const one = 1;\n\nfunction run() {\n    return one;\n}\n",
            .wrapped = "const one = 1;\n\nfunction run() {\n    {\n        return one;\n    }\n}\n",
        },
    },
    .{
        .comment = "// scylla\n",
        .directory = "tests/fixtures/typescript-semantic",
        .extension = "ts",
        .family = .typed,
        .language = .typescript,
        .module = grammars.javascript,
        .name = "typescript",
        .wrapped = .{
            .plain = "const one: number = 1;\n\nfunction run(): number {\n    return one;\n}\n",
            .wrapped = "const one: number = 1;\n\nfunction run(): number {\n    {\n" ++
                "        return one;\n    }\n}\n",
        },
    },
    .{
        .comment = "// scylla\n",
        .directory = "tests/fixtures/go-semantic",
        .extension = "go",
        .family = .plain,
        .language = .go,
        .module = grammars.go,
        .name = "go",
        .wrapped = .{
            .plain = "package sample\n\nconst one = 1\n\nfunc run() int {\n\treturn one\n}\n",
            .wrapped = "package sample\n\nconst one = 1\n\nfunc run() int {\n\t{\n\t\treturn one" ++
                "\n\t}\n}\n",
        },
    },
    .{
        .comment = "// scylla\n",
        .directory = "tests/fixtures/rust-semantic",
        .extension = "rs",
        .family = .plain,
        .language = .rust,
        .module = grammars.rust,
        .name = "rust",
        .wrapped = .{
            .plain = "const ONE: usize = 1;\n\nfn run() -> usize {\n    ONE\n}\n",
            .wrapped = "const ONE: usize = 1;\n\nfn run() -> usize {\n    {\n" ++
                "        ONE\n    }\n}\n",
        },
    },
    .{
        .comment = "// scylla\n",
        .directory = "tests/fixtures/zig-semantic",
        .extension = "zig",
        .family = .plain,
        .language = .zig,
        .module = grammars.zig,
        .name = "zig",
        .wrapped = .{
            .plain = "const one: usize = 1;\n\nfn run() usize {\n    return one;\n}\n",
            .wrapped = "const one: usize = 1;\n\nfn run() usize {\n    {\n" ++
                "        return one;\n    }\n}\n",
        },
    },
    .{
        .comment = "// scylla\n",
        .directory = "tests/fixtures/odin-semantic",
        .extension = "odin",
        .family = .plain,
        .language = .odin,
        .module = grammars.odin,
        .name = "odin",
        .wrapped = .{
            .plain = "package sample\n\nONE :: 1\n\nrun :: proc() -> int {\n\treturn ONE\n}\n",
            .wrapped = "package sample\n\nONE :: 1\n\nrun :: proc() -> int {\n\t{\n" ++
                "\t\treturn ONE\n\t}\n}\n",
        },
    },
};

const universe = [_][]const u8{
    "None",
    "Self",
    "Some",
    "bool",
    "console",
    "error",
    "eval",
    "int",
    "len",
    "print",
    "require",
    "string",
    "usize",
    "void",
};

fn CorpusWorkerType(comptime grammar: Grammar) type {
    assert(grammar.comment.len <= std.math.maxInt(u32));

    return struct {
        arena: std.heap.ArenaAllocator,
        machine: *MachineType(grammar),

        const CorpusWorker = @This();
        pub const Item = corpus.File;
        pub const Shared = struct {};
        pub const Tally = struct { built: u32, renamed: u32 };
        pub const weight = corpus.File.weight;

        pub fn deinit(worker: *CorpusWorker, gpa: std.mem.Allocator) void {
            assert(grammar.name.len > 0);
            assert(grammar.extension.len > 0);

            worker.machine.destroy(gpa);
            worker.arena.deinit();
            worker.* = undefined;
        }

        pub fn init(worker: *CorpusWorker, gpa: std.mem.Allocator, shared: *const Shared) !void {
            assert(@TypeOf(shared.*) == Shared);
            assert(grammar.comment.len > 0);

            worker.arena = .init(gpa);
            errdefer worker.arena.deinit();

            worker.machine = try MachineType(grammar).create(gpa);
        }

        pub fn visit(worker: *CorpusWorker, file: *const corpus.File, tally: *Tally) !void {
            assert(file.name.len > 0);
            assert(tally.renamed <= tally.built);

            _ = worker.arena.reset(.retain_capacity);

            const arena = worker.arena.allocator();
            const machine = worker.machine;
            const name = file.name;
            const source = file.source;
            var renaming: Renaming = undefined;

            if (!machine.built(source)) return;

            const held = try machine.summary(arena, source);

            tally.built += 1;

            try chain_checked(grammar, name, &held);
            try shifts(grammar, machine, arena, name, source, &held);

            if (!try renaming_of(arena, source, &held, &renaming)) return;

            const swapped_source = try renamed(arena, source, renaming);

            try require(swapped_source.len == source.len, "{s}: {s}", .{ grammar.name, name });

            if (!machine.built(swapped_source)) return;

            const found = try machine.summary(arena, swapped_source);
            const expected = try substituted(arena, &held, renaming);
            const format = "{s}: {s} reads {s} as {s} differently";

            try require(summary_equal(&found, &expected), format, .{
                grammar.name,
                name,
                renaming.name,
                renaming.replacement,
            });

            tally.renamed += 1;
        }

        fn selected(basename: []const u8) bool {
            assert(basename.len > 0);

            const dotted = std.Io.Dir.path.extension(basename);

            if (dotted.len == 0) return false;
            return std.mem.eql(u8, dotted[1..], grammar.extension);
        }
    };
}

fn MachineType(comptime grammar: Grammar) type {
    assert(grammar.comment.len <= std.math.maxInt(u32));

    const module = grammar.module;
    const Kind = module.Kind;
    const python = grammar.family == .python;

    return struct {
        events: EventsType(Kind),
        parser: module.Parser,
        raw: ArrayType(Kind),
        scratch: if (python) module.AnnotationScratch else void,
        semantic: module.Semantic,
        tokens: Tokens,
        tree: TreeType(Kind),

        const Machine = @This();

        fn built(machine: *Machine, source: []const u8) bool {
            assert(source.len <= std.math.maxInt(u32));

            const language = grammar.language;
            const tokens = &machine.tokens;

            lex_into(Kind, .of(language), source, tokens, &machine.raw) catch return false;

            assert(machine.raw.count() == machine.tokens.count());

            machine.parsed(source);

            if (machine.tree.diagnostic_slice().len > 0) return false;
            return machine.resolved(source);
        }

        fn create(gpa: std.mem.Allocator) !*Machine {
            const machine = try gpa.create(Machine);
            errdefer gpa.destroy(machine);

            try machine.events.init(gpa, event_count_max);
            errdefer machine.events.deinit(gpa);

            machine.raw = try .init(gpa, token_count_max);
            errdefer machine.raw.deinit(gpa);

            machine.tokens = try .init(gpa, token_count_max);
            errdefer machine.tokens.deinit(gpa);

            machine.tree = try .init(gpa, node_count_max, diagnostic_count_max);
            errdefer machine.tree.deinit(gpa);

            try machine.create_semantic(gpa);

            assert(machine.raw.capacity() == machine.tokens.items.capacity());
            assert(machine.tree.count() == 0);

            return machine;
        }

        fn create_semantic(machine: *Machine, gpa: std.mem.Allocator) !void {
            assert(machine.raw.capacity() == token_count_max);
            assert(machine.tokens.items.capacity() == token_count_max);

            try machine.semantic.init(gpa, &.{
                .binding_count_max = table_count_max,
                .fact_count_max = table_count_max,
                .reference_count_max = table_count_max,
                .scope_count_max = table_count_max,
            });

            if (!python) return;
            errdefer machine.semantic.deinit(gpa);

            try machine.scratch.init(gpa, &.{
                .node_count_max = annotation_count_max,
                .token_count_max = annotation_count_max,
            });
        }

        fn destroy(machine: *Machine, gpa: std.mem.Allocator) void {
            assert(machine.raw.capacity() == token_count_max);
            assert(machine.tokens.items.capacity() == token_count_max);

            if (python) machine.scratch.deinit(gpa);

            machine.semantic.deinit(gpa);
            machine.tree.deinit(gpa);
            machine.tokens.deinit(gpa);
            machine.raw.deinit(gpa);
            machine.events.deinit(gpa);
            gpa.destroy(machine);
        }

        fn parsed(machine: *Machine, source: []const u8) void {
            const tokens = machine.tokens.slice();
            const raw = machine.raw.const_slice();

            assert(tokens.len == raw.len);
            assert(source.len <= std.math.maxInt(u32));

            switch (grammar.family) {
                .typed => _ = machine.parser.build(
                    source,
                    tokens,
                    raw,
                    &machine.events,
                    &machine.tree,
                    .{ .dialect = .typescript, .goal = .module },
                ),
                .script => _ = machine.parser.build(
                    source,
                    tokens,
                    raw,
                    &machine.events,
                    &machine.tree,
                    .{ .dialect = .javascript, .goal = .module },
                ),
                else => _ = machine.parser.build(
                    source,
                    tokens,
                    raw,
                    &machine.events,
                    &machine.tree,
                ),
            }
        }

        fn resolved(machine: *Machine, source: []const u8) bool {
            assert(source.len <= std.math.maxInt(u32));

            const tokens = machine.tokens.slice();
            const raw = machine.raw.const_slice();

            assert(tokens.len == raw.len);
            assert(machine.tree.diagnostic_slice().len == 0);

            const structure = switch (grammar.family) {
                .plain => machine.semantic.build(source, tokens, raw, &machine.tree, &universe),
                .python => machine.semantic.build(&.{
                    .builtins = &universe,
                    .raw = raw,
                    .source = source,
                    .tokens = tokens,
                    .tree = &machine.tree,
                    .version = .py310,
                }, &machine.scratch),
                .script, .typed => machine.semantic.build(
                    source,
                    tokens,
                    raw,
                    &machine.tree,
                    &.{ .globals = &universe, .module = null, .typed = grammar.family == .typed },
                ),
            };

            return structure == .complete;
        }

        fn summary(machine: *Machine, arena: std.mem.Allocator, source: []const u8) !Summary {
            assert(source.len <= std.math.maxInt(u32));
            assert(machine.tokens.items.capacity() == token_count_max);

            return try summary_of(arena, &machine.semantic, source);
        }
    };
}

fn summary_of(arena: std.mem.Allocator, semantic: anytype, source: []const u8) !Summary {
    assert(source.len <= std.math.maxInt(u32));
    comptime assert(@typeInfo(@TypeOf(semantic)) == .pointer);

    const bindings = semantic.binding_slice();
    const references = semantic.reference_slice();
    var summary: Summary = .blank;

    assert(bindings.len <= table_count_max);
    assert(references.len <= table_count_max);

    for (semantic.scope_slice()) |held| {
        const parent: i64 = held.parent;

        try summary.parents.append(arena, held.parent);

        try summary.scopes.append(arena, try arena.print("{s} {d}", .{
            try camel_of(arena, @tagName(held.kind)),
            parent,
        }));
    }

    for (bindings) |held| {
        const text = held.name.text(source);

        try summary.offsets.append(arena, held.name.offset);

        try summary.bindings.append(arena, try arena.print("{s} {s} {d}", .{
            try camel_of(arena, @tagName(held.kind)),
            text,
            held.scope,
        }));
    }

    for (references) |held| {
        const text = held.name.text(source);

        const target = switch (held.resolution) {
            .bound => |bound| target: {
                const binding = bindings[bound];

                try summary.chain.append(arena, .{
                    .binding = binding.scope,
                    .reference = held.scope,
                });

                break :target try arena.print("{s} {d}", .{
                    binding.name.text(source),
                    binding.scope,
                });
            },
            else => try camel_of(arena, @tagName(held.resolution)),
        };

        try summary.references.append(arena, try arena.print("{s} {s}", .{ text, target }));
    }

    assert(summary.offsets.items.len == bindings.len);

    return summary;
}

fn bounded(source: []const u8, offset: usize) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(offset <= source.len);

    if (offset >= source.len) return false;

    const byte = source[offset];
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn camel_of(arena: std.mem.Allocator, tag: []const u8) ![]const u8 {
    assert(tag.len > 0);

    var found: std.ArrayList(u8) = try .initCapacity(arena, tag.len);
    var raised = true;

    assert(tag[0] != '_');

    for (tag) |byte| {
        if (byte == '_') {
            raised = true;

            continue;
        }

        found.appendAssumeCapacity(if (raised) std.ascii.toUpper(byte) else byte);
        raised = false;
    }

    assert(found.items.len <= tag.len);

    return found.items;
}

fn chain_checked(comptime grammar: Grammar, name: []const u8, held: *const Summary) !void {
    assert(name.len > 0);
    assert(held.parents.items.len == held.scopes.items.len);
    assert(grammar.comment.len <= std.math.maxInt(u32));

    for (held.chain.items) |link| {
        const walked = walks_to(held, link.reference, link.binding);

        try require(walked, "{s}: {s} resolves a reference outside its own scope chain", .{
            grammar.name,
            name,
        });
    }
}

fn fixtures(gpa: std.mem.Allocator, comptime grammar: Grammar) !corpus.Files {
    assert(grammar.directory.len > 0);

    const Selector = CorpusWorkerType(grammar);
    const io = std.testing.io;
    var files: corpus.Files = .{ .list = .empty };
    errdefer files.deinit(gpa);

    assert(grammar.extension.len > 0);

    var directory = std.Io.Dir.cwd().openDir(io, grammar.directory, .{ .iterate = true }) catch {
        return files;
    };

    defer directory.close(io);

    var iterator = directory.iterate();
    var walked: u32 = 0;

    while (try iterator.next(io)) |entry| : (walked += 1) {
        assert(walked < file_count_max);

        if (entry.kind == .directory) continue;
        if (!Selector.selected(entry.name)) continue;

        const limit: std.Io.Limit = .limited(source_bytes_max);
        const source = directory.readFileAlloc(io, entry.name, gpa, limit) catch continue;
        errdefer gpa.free(source);

        const name = try gpa.dupe(u8, entry.name);
        errdefer gpa.free(name);

        try files.list.append(gpa, .{ .name = name, .source = source });
    }

    std.mem.sort(corpus.File, files.list.items, {}, corpus.File.less_than);

    return files;
}

fn names_equal(left: []const []const u8, right: []const []const u8) bool {
    assert(left.len <= std.math.maxInt(u32));
    assert(right.len <= std.math.maxInt(u32));

    if (left.len != right.len) return false;

    for (left, right) |one, two| {
        if (!std.mem.eql(u8, one, two)) return false;
    }

    return true;
}

fn offsets_shifted(found: []const u32, held: []const u32, delta: u32) bool {
    assert(delta > 0);
    assert(held.len <= std.math.maxInt(u32));

    if (found.len != held.len) return false;

    for (found, held) |one, two| {
        if (one != two + delta) return false;
    }

    return true;
}

fn renamed(arena: std.mem.Allocator, source: []const u8, renaming: Renaming) ![]const u8 {
    assert(source.len <= std.math.maxInt(u32));
    assert(renaming.name.len <= std.math.maxInt(u32));

    const name = renaming.name;
    var found: std.ArrayList(u8) = try .initCapacity(arena, source.len);
    var offset: usize = 0;

    assert(name.len > 0);
    assert(renaming.replacement.len == name.len);

    for (0..source.len) |_| {
        if (offset >= source.len) break;

        if (renamed_at(source, offset, name)) {
            try found.appendSlice(arena, renaming.replacement);
            offset += name.len;

            continue;
        }

        try found.append(arena, source[offset]);
        offset += 1;
    }

    assert(offset >= source.len);

    return found.items;
}

fn renamed_at(source: []const u8, offset: usize, name: []const u8) bool {
    assert(offset < source.len);
    assert(name.len > 0);

    if (offset + name.len > source.len) return false;
    if (!std.mem.eql(u8, source[offset..][0..name.len], name)) return false;

    if (offset > 0) {
        if (bounded(source, offset - 1)) return false;
    }

    return !bounded(source, offset + name.len);
}

fn renaming_of(
    arena: std.mem.Allocator,
    source: []const u8,
    held: *const Summary,
    renaming: *Renaming,
) !bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(held.offsets.items.len == held.bindings.items.len);

    for (held.bindings.items) |row| {
        var words = std.mem.splitScalar(u8, row, ' ');
        const kind = words.next() orelse continue;
        const name = words.next() orelse continue;

        if (std.mem.find(u8, kind, "Import") != null) continue;
        if (std.mem.find(u8, kind, "Use") != null) continue;
        if (!renaming_eligible(held, name)) continue;

        const replacement = try replacement_of(arena, name);
        if (std.mem.find(u8, source, replacement) != null) continue;

        renaming.* = .{ .name = name, .replacement = replacement };

        return true;
    }

    return false;
}

fn renaming_eligible(held: *const Summary, name: []const u8) bool {
    assert(held.references.items.len <= table_count_max);
    assert(name.len <= source_bytes_max);

    if (name.len < 3) return false;

    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte)) return false;
    }

    if (!std.ascii.isAlphabetic(name[0])) return false;

    for (universe) |word| {
        if (std.mem.eql(u8, word, name)) return false;
    }

    for (held.references.items) |shown| {
        var words = std.mem.splitScalar(u8, shown, ' ');
        const first = words.next() orelse continue;
        if (!std.mem.eql(u8, first, name)) continue;
        if (std.mem.endsWith(u8, shown, " Builtin")) return false;
    }

    return true;
}

fn replacement_of(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    var shouted = true;

    assert(name.len >= 3);
    assert(std.ascii.isAlphabetic(name[0]));

    for (name) |byte| {
        if (std.ascii.isLower(byte)) shouted = false;
    }

    const capitalised = std.ascii.isUpper(name[0]);
    const head: []const u8 = if (shouted) "ZQ" else if (capitalised) "Zq" else "zq";
    const fill: u8 = if (shouted) 'X' else 'x';
    const replacement = try arena.alloc(u8, name.len);

    @memcpy(replacement[0..head.len], head);
    @memset(replacement[head.len..], fill);

    assert(replacement.len == name.len);

    return replacement;
}

fn require(condition: bool, comptime format: []const u8, arguments: anytype) !void {
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    if (condition) return;

    std.debug.print(format ++ "\n", arguments);

    return error.TestUnexpectedResult;
}

fn shifts(
    comptime grammar: Grammar,
    machine: *MachineType(grammar),
    arena: std.mem.Allocator,
    name: []const u8,
    source: []const u8,
    held: *const Summary,
) !void {
    assert(source.len <= std.math.maxInt(u32));
    assert(grammar.comment.len <= std.math.maxInt(u32));

    const written = try std.mem.concat(arena, u8, &.{ grammar.comment, source });
    const shebanged = std.mem.startsWith(u8, source[scan.mark_width(source)..], "#!");

    assert(name.len > 0);
    assert(written.len == grammar.comment.len + source.len);

    if (!machine.built(written)) return;

    const found = try machine.summary(arena, written);

    if (shebanged) return;

    const delta: u32 = @intCast(grammar.comment.len);
    const format = "{s}: {s}";
    const arguments = .{ grammar.name, name };

    try require(names_equal(found.bindings.items, held.bindings.items), format, arguments);
    try require(names_equal(found.references.items, held.references.items), format, arguments);
    try require(names_equal(found.scopes.items, held.scopes.items), format, arguments);
    try require(std.mem.eql(u32, found.parents.items, held.parents.items), format, arguments);

    try require(
        offsets_shifted(found.offsets.items, held.offsets.items, delta),
        "{s}: {s} does not shift its spans",
        arguments,
    );
}

fn substituted(arena: std.mem.Allocator, held: *const Summary, renaming: Renaming) !Summary {
    var summary: Summary = .{
        .bindings = .empty,
        .chain = held.chain,
        .offsets = held.offsets,
        .parents = held.parents,
        .references = .empty,
        .scopes = held.scopes,
    };

    assert(renaming.name.len > 0);
    assert(renaming.replacement.len == renaming.name.len);

    for (held.bindings.items) |row| {
        try summary.bindings.append(arena, try swapped(arena, row, renaming, 1));
    }

    for (held.references.items) |row| {
        try summary.references.append(arena, try swapped(arena, row, renaming, 0));
    }

    return summary;
}

fn summary_equal(left: *const Summary, right: *const Summary) bool {
    assert(left.offsets.items.len == left.bindings.items.len);
    assert(right.offsets.items.len == right.bindings.items.len);

    if (!names_equal(left.bindings.items, right.bindings.items)) return false;
    if (left.chain.items.len != right.chain.items.len) return false;

    for (left.chain.items, right.chain.items) |one, two| {
        if (one.binding != two.binding) return false;
        if (one.reference != two.reference) return false;
    }

    if (!std.mem.eql(u32, left.offsets.items, right.offsets.items)) return false;
    if (!std.mem.eql(u32, left.parents.items, right.parents.items)) return false;
    if (!names_equal(left.references.items, right.references.items)) return false;
    return names_equal(left.scopes.items, right.scopes.items);
}

fn swapped(arena: std.mem.Allocator, row: []const u8, renaming: Renaming, from: u32) ![]const u8 {
    assert(row.len <= std.math.maxInt(u32));

    var found: std.ArrayList(u8) = try .initCapacity(arena, row.len);
    var words = std.mem.splitScalar(u8, row, ' ');
    var index: u32 = 0;

    assert(renaming.name.len > 0);
    assert(from <= 1);

    while (words.next()) |word| : (index += 1) {
        assert(index < word_count_max);

        if (index > 0) try found.append(arena, ' ');

        const chosen = index >= from;

        try found.appendSlice(arena, if (chosen) try renamed(arena, word, renaming) else word);
    }

    assert(found.items.len == row.len);

    return found.items;
}

fn walks_to(held: *const Summary, reference: u32, binding: u32) bool {
    assert(reference < none);

    const parents = held.parents.items;
    var scope = reference;

    assert(parents.len <= table_count_max);
    assert(reference < parents.len);

    for (0..parents.len + 1) |_| {
        if (scope == none) return false;
        if (scope == binding) return true;

        scope = parents[scope];
    }

    return false;
}

fn corpus_relations(comptime grammar: Grammar, root: []const u8) !void {
    assert(grammar.name.len > 0);
    assert(root.len > 0);

    const gpa = std.testing.allocator;
    const CorpusWorker = CorpusWorkerType(grammar);
    var files = try corpus.collect(gpa, root, source_bytes_max, CorpusWorker.selected);
    defer files.deinit(gpa);

    var tally: CorpusWorker.Tally = .{ .built = 0, .renamed = 0 };

    try stripe.run(CorpusWorker, gpa, &.{}, files.slice(), &tally);

    const relations = floor.corpus_relations_of(grammar.name);

    try require(tally.built >= relations.built, "{s}: {d} files built, floor {d}", .{
        grammar.name,
        tally.built,
        relations.built,
    });

    try require(tally.renamed >= relations.renamed, "{s}: {d} files renamed, floor {d}", .{
        grammar.name,
        tally.renamed,
        relations.renamed,
    });
}

fn fixture_chains(comptime grammar: Grammar, arena: *std.heap.ArenaAllocator) !u32 {
    assert(grammar.comment.len <= std.math.maxInt(u32));

    const gpa = std.testing.allocator;
    const machine = try MachineType(grammar).create(gpa);
    defer machine.destroy(gpa);

    var files = try fixtures(gpa, grammar);
    defer files.deinit(gpa);

    var compared: u32 = 0;

    for (files.slice()) |file| {
        _ = arena.reset(.retain_capacity);

        try require(machine.built(file.source), "{s}: {s} does not build", .{
            grammar.name,
            file.name,
        });

        const held = try machine.summary(arena.allocator(), file.source);

        try chain_checked(grammar, file.name, &held);

        compared += 1;
    }

    return compared;
}

fn fixture_renames(comptime grammar: Grammar, arena: *std.heap.ArenaAllocator) !u32 {
    assert(grammar.comment.len <= std.math.maxInt(u32));

    const gpa = std.testing.allocator;
    const machine = try MachineType(grammar).create(gpa);
    defer machine.destroy(gpa);

    var files = try fixtures(gpa, grammar);
    defer files.deinit(gpa);

    var compared: u32 = 0;

    for (files.slice()) |file| {
        _ = arena.reset(.retain_capacity);

        const allocator = arena.allocator();
        const name = file.name;
        var renaming: Renaming = undefined;

        try require(machine.built(file.source), "{s}: {s} does not build", .{ grammar.name, name });

        const held = try machine.summary(allocator, file.source);
        if (!try renaming_of(allocator, file.source, &held, &renaming)) continue;

        const written = try renamed(allocator, file.source, renaming);

        try require(written.len == file.source.len, "{s}: {s}", .{ grammar.name, name });

        try require(machine.built(written), "{s}: {s} does not build once renamed", .{
            grammar.name,
            name,
        });

        const found = try machine.summary(allocator, written);
        const expected = try substituted(allocator, &held, renaming);
        const format = "{s}: {s} reads {s} as {s} differently";

        try require(summary_equal(&found, &expected), format, .{
            grammar.name,
            name,
            renaming.name,
            renaming.replacement,
        });

        compared += 1;
    }

    return compared;
}

fn fixture_shifts(comptime grammar: Grammar, arena: *std.heap.ArenaAllocator) !u32 {
    assert(grammar.comment.len <= std.math.maxInt(u32));

    const gpa = std.testing.allocator;
    const machine = try MachineType(grammar).create(gpa);
    defer machine.destroy(gpa);

    var files = try fixtures(gpa, grammar);
    defer files.deinit(gpa);

    var compared: u32 = 0;

    for (files.slice()) |file| {
        _ = arena.reset(.retain_capacity);

        const allocator = arena.allocator();
        const name = file.name;

        try require(machine.built(file.source), "{s}: {s} does not build", .{ grammar.name, name });

        const held = try machine.summary(allocator, file.source);
        const written = try std.mem.concat(allocator, u8, &.{ grammar.comment, file.source });

        try require(machine.built(written), "{s}: {s} does not build under a comment", .{
            grammar.name,
            name,
        });

        const found = try machine.summary(allocator, written);
        const delta: u32 = @intCast(grammar.comment.len);
        const format = "{s}: {s}";
        const arguments = .{ grammar.name, name };

        try require(names_equal(found.bindings.items, held.bindings.items), format, arguments);
        try require(names_equal(found.references.items, held.references.items), format, arguments);
        try require(names_equal(found.scopes.items, held.scopes.items), format, arguments);

        try require(
            offsets_shifted(found.offsets.items, held.offsets.items, delta),
            "{s}: {s} does not shift its spans",
            arguments,
        );

        compared += 1;
    }

    return compared;
}

fn wrapped_holds(comptime grammar: Grammar, arena: std.mem.Allocator) !bool {
    assert(grammar.comment.len <= std.math.maxInt(u32));

    const gpa = std.testing.allocator;
    const held = grammar.wrapped orelse return false;
    const machine = try MachineType(grammar).create(gpa);
    defer machine.destroy(gpa);

    try require(machine.built(held.plain), "{s}: the plain source does not build", .{
        grammar.name,
    });

    const plain = try machine.summary(arena, held.plain);

    try require(machine.built(held.wrapped), "{s}: the wrapped source does not build", .{
        grammar.name,
    });

    const found = try machine.summary(arena, held.wrapped);

    try require(
        found.scopes.items.len == plain.scopes.items.len + 1,
        "{s}: wrapping a body adds more than one scope",
        .{grammar.name},
    );

    try require(
        names_equal(found.references.items, plain.references.items),
        "{s}: wrapping a body moves a resolution",
        .{grammar.name},
    );

    return true;
}

test "every reference names a binding on its own scope chain" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compared: u32 = 0;

    inline for (every_grammar) |grammar| compared += try fixture_chains(grammar, &arena);

    try require(compared > fixture_count_min, "the fixtures went missing", .{});
}

test "renaming one identifier throughout a file changes no resolution" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compared: u32 = 0;

    inline for (every_grammar) |grammar| compared += try fixture_renames(grammar, &arena);

    try require(compared > fixture_count_min, "the fixtures went missing", .{});
}

test "prepending a comment shifts every span and changes nothing else" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compared: u32 = 0;

    inline for (every_grammar) |grammar| compared += try fixture_shifts(grammar, &arena);

    try require(compared > fixture_count_min, "the fixtures went missing", .{});
}

test "wrapping a body in one block adds one scope and moves no resolution" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var compared: u32 = 0;

    inline for (every_grammar) |grammar| {
        if (try wrapped_holds(grammar, arena.allocator())) compared += 1;
    }

    try require(compared == wrapped_count, "a language lost its wrapped pair", .{});
}

test "the three relations hold over the corpus" {
    const root = corpus.named(.root) orelse return;

    inline for (every_grammar) |grammar| try corpus_relations(grammar, root);
}
