const oracle_names = @import("syntax/testing/names.zig");
const std = @import("std");
const assert = std.debug.assert;
const grammars = @import("syntax/grammars.zig");
const lex_into = @import("syntax/raw.zig").lex_into;
const lex = @import("syntax/lex.zig").lex;
const outline_module = @import("outline.zig");
const tree_module = @import("syntax/tree.zig");
const ArrayType = @import("stdx/bounded/array.zig").ArrayType;
const Bindings = @import("syntax/binding.zig").Bindings;
const Buffer = @import("stdx/bounded/buffer.zig");
const Calls = @import("syntax/calls.zig").Calls;
const CheckError = grammars.python.check.CheckError;
const Fact = @import("syntax/fact.zig").Fact;
const FormatCapacity = @import("format.zig").Formatters.Capacity;
const Formatters = @import("format.zig").Formatters;
const Front = @import("syntax/front.zig").Front;
const FrontCapacity = Front.Capacity;
const FrontOptions = Front.Options;
const Language = @import("syntax/language.zig").Language;
const OutlineJavaScript = @import("outline/javascript.zig").Outline;
const OutlinePython = @import("outline/python.zig").Outline;
const Brackets = @import("syntax/brackets.zig").Brackets;
const PythonSemantic = grammars.python.Semantic;
const Scratch = Front.Scratch;
const SourceType = @import("syntax/language.zig").SourceType;
const Span = @import("stdx/bounded/span.zig");
const StaticAllocator = @import("stdx/static_allocator.zig");
const Structure = tree_module.Structure;
const TreeType = tree_module.TreeType;
const Summary = @import("syntax/summary.zig").Summary;
const Token = @import("syntax/token.zig");
const Tokens = @import("syntax/tokens.zig");
const View = @import("syntax/view.zig").View;
const css_semantic_of = @import("syntax/front.zig").css_semantic_of;
const python_checks_of = @import("syntax/front.zig").python_checks_of;
const python_semantic = grammars.python.semantic;
const view_module = @import("syntax/view.zig");

const Level = enum {
    tokens,
    tree,
    semantics,
    format,
};

const Arguments = struct {
    corpus: []const u8,
    out: []const u8,
};

const Flag = struct {
    name: []const u8,
    set: bool,
};

const Syntaxes = struct {
    css: SyntaxType(grammars.css),
    go: SyntaxType(grammars.go),
    javascript: SyntaxType(grammars.javascript),
    odin: SyntaxType(grammars.odin),
    python: SyntaxType(grammars.python),
    rust: SyntaxType(grammars.rust),
    typescript: SyntaxType(grammars.javascript),
    zig: SyntaxType(grammars.zig),

    const field_names = @typeInfo(Syntaxes).@"struct".field_names;

    fn init(syntaxes: *Syntaxes, gpa: std.mem.Allocator) !void {
        comptime assert(field_names.len > 0);

        inline for (field_names, 0..) |name, index| {
            @field(syntaxes, name).init(gpa) catch |err| {
                inline for (field_names[0..index]) |done| @field(syntaxes, done).deinit(gpa);

                return err;
            };
        }

        inline for (field_names) |name| assert(@field(syntaxes, name).raw.empty());
    }

    fn deinit(syntaxes: *Syntaxes, gpa: std.mem.Allocator) void {
        comptime assert(field_names.len > 0);

        inline for (field_names) |name| {
            assert(@field(syntaxes, name).raw.capacity() == classified_count_max);

            @field(syntaxes, name).deinit(gpa);
        }
    }

    fn parses(language: Language) bool {
        if (!language.lexes()) return false;

        const result = switch (language) {
            inline else => |tag| @hasField(Syntaxes, field_of(tag)),
        };

        if (result) assert(language.lexes());
        if (language == .markup) assert(!result);

        return result;
    }

    fn field_of(comptime language: Language) []const u8 {
        comptime assert(@hasField(Language, @tagName(language)));

        const name = @tagName(language);

        return name;
    }
};

fn dialect_of(comptime Module: type, language: Language, tsx: bool) Module.Dialect {
    assert(language.lexes());

    if (tsx) return .tsx;
    return Module.Dialect.of_language(language);
}

fn kind_name_of(comptime Kind: type, code: ?u16) []const u8 {
    if (code) |held| assert(Kind.of_u16(held) != null);

    const held = code orelse return "-";
    const name = Kind.of_u16(held).?.name();

    assert(name.len > 0);

    return name;
}

fn SyntaxType(comptime Module: type) type {
    comptime assert(@hasDecl(Module, "Kind"));
    comptime assert(@hasDecl(Module, "Parser"));

    return struct {
        events: Events,
        parser: Module.Parser,
        raw: ArrayType(Module.Kind),
        tokens: Tokens,
        tree: Tree,

        const Syntax = @This();
        const Events = tree_module.EventsType(Module.Kind);
        const Tree = TreeType(Module.Kind);

        fn init(syntax: *Syntax, gpa: std.mem.Allocator) !void {
            try syntax.events.init(gpa, event_count_max);
            errdefer syntax.events.deinit(gpa);

            syntax.raw = try .init(gpa, classified_count_max);
            errdefer syntax.raw.deinit(gpa);

            syntax.tokens = try .init(gpa, classified_count_max);
            errdefer syntax.tokens.deinit(gpa);

            syntax.tree = try .init(gpa, node_count_max, diagnostic_count_max);

            assert(syntax.raw.capacity() == syntax.tokens.items.capacity());
            assert(syntax.raw.empty());
        }

        fn deinit(syntax: *Syntax, gpa: std.mem.Allocator) void {
            assert(syntax.raw.capacity() == classified_count_max);
            assert(syntax.tokens.items.capacity() == classified_count_max);

            syntax.tree.deinit(gpa);
            syntax.tokens.deinit(gpa);
            syntax.raw.deinit(gpa);
            syntax.events.deinit(gpa);
        }

        fn structure_of(
            syntax: *Syntax,
            source: []const u8,
            language: Language,
            tsx: bool,
        ) Structure {
            assert(source.len <= source_bytes_max);
            assert(language.lexes());

            const dialected = comptime @hasDecl(Module, "Dialect");

            const dialect = if (dialected) .{
                dialect_of(Module, language, tsx).grammar(.module),
            } else .{};

            syntax.tree.clear();

            const lexed = lex_into(
                Module.Kind,
                .{ .flavor = if (tsx) .tsx else .plain, .language = language },
                source,
                &syntax.tokens,
                &syntax.raw,
            );

            lexed catch |err| switch (err) {
                error.Truncated => return .{ .truncated = .tokens },
            };

            assert(syntax.tokens.count() == syntax.raw.count());

            return @call(.auto, Module.Parser.build, .{
                &syntax.parser,
                source,
                syntax.tokens.slice(),
                syntax.raw.const_slice(),
                &syntax.events,
                &syntax.tree,
            } ++ dialect);
        }

        fn write(syntax: *Syntax, writer: *std.Io.Writer, structure: Structure) !void {
            if (structure == .complete) assert(syntax.tree.count() > 0);

            const tree = &syntax.tree;

            assert(tree.diagnostic_slice().len <= diagnostic_count_max);
            assert(tree.count() <= node_count_max);

            try write_nodes(Tree, writer, tree);
            try writer.print("structure {s}\n", .{@tagName(structure)});
            try writer.print("errors {d}\n", .{tree.diagnostic_slice().len});

            for (tree.diagnostic_slice()) |held| {
                try writer.print("error {s} {d} {d} {s} {s}\n", .{
                    held.kind.name(),
                    held.span.offset,
                    held.span.end(),
                    kind_name_of(Module.Kind, held.expected),
                    kind_name_of(Module.Kind, held.found),
                });
            }
        }
    };
}

const Semantics = struct {
    calls: Calls,
    fronts: [Language.count]?Front,
    outlines: Outlines,
    scratch: Scratch,
    segments: ArrayType(Span),

    fn init(semantics: *Semantics, gpa: std.mem.Allocator) !void {
        var wanted: std.EnumSet(Language) = .empty;

        for (std.enums.values(Language)) |language| {
            if (!language.lexes()) continue;

            wanted.insert(language);
        }

        assert(wanted.count() > 0);
        assert(!wanted.contains(.markup));

        try semantics.scratch.init(gpa, &semantic_limits, wanted);
        errdefer semantics.scratch.deinit(gpa);

        semantics.fronts = @splat(null);
        errdefer semantics.fronts_deinit(gpa);

        semantics.segments = try .init(gpa, view_module.segment_count_max);
        errdefer semantics.segments.deinit(gpa);

        try semantics.calls.init(gpa, call_capacity);
        errdefer semantics.calls.deinit(gpa);

        for (std.enums.values(Language)) |language| {
            if (!wanted.contains(language)) continue;

            var front: Front = undefined;

            try front.init(gpa, &semantic_limits, language);

            semantics.fronts[@backingInt(language)] = front;
        }

        try semantics.outlines.init(gpa);

        assert(semantics.fronts[@backingInt(Language.zig)] != null);
    }

    fn deinit(semantics: *Semantics, gpa: std.mem.Allocator) void {
        assert(semantics.fronts[@backingInt(Language.zig)] != null);
        assert(semantics.scratch.zig != null);

        semantics.outlines.deinit(gpa);
        semantics.calls.deinit(gpa);
        semantics.fronts_deinit(gpa);
        semantics.scratch.deinit(gpa);
        semantics.segments.deinit(gpa);
        semantics.* = undefined;
    }

    fn fronts_deinit(semantics: *Semantics, gpa: std.mem.Allocator) void {
        for (&semantics.fronts) |*held| {
            if (held.*) |*front| {
                assert(front.language.lexes());

                front.deinit(gpa);
            }

            held.* = null;
        }

        assert(semantics.fronts[@backingInt(Language.zig)] == null);
    }
};

const Outlines = struct {
    javascript: OutlineJavaScript,
    pairs: Brackets,
    python: OutlinePython,

    fn init(outlines: *Outlines, gpa: std.mem.Allocator) !void {
        outlines.pairs = try .init(gpa, classified_count_max);
        errdefer outlines.pairs.deinit(gpa);

        try outlines.javascript.init(gpa, .{
            .row_count_max = semantic_count_max,
            .segment_count_max = semantic_count_max,
            .token_count_max = token_count_max,
        });

        errdefer outlines.javascript.deinit(gpa);

        try outlines.python.init(gpa, .{
            .row_count_max = semantic_count_max,
            .segment_count_max = semantic_count_max,
        });

        assert(outlines.python.definitions.count() == 0);
        assert(outlines.pairs.count() == 0);
    }

    fn deinit(outlines: *Outlines, gpa: std.mem.Allocator) void {
        assert(outlines.python.definitions.count() <= semantic_count_max);
        assert(outlines.pairs.count() <= classified_count_max);

        outlines.python.deinit(gpa);
        outlines.javascript.deinit(gpa);
        outlines.pairs.deinit(gpa);
        outlines.* = undefined;
    }

    fn write(
        outlines: *Outlines,
        writer: *std.Io.Writer,
        language: Language,
        source: []const u8,
        tokens: []const Token,
        front: *const Front,
    ) !void {
        assert(source.len <= source_bytes_max);
        assert(tokens.len <= token_count_max);
        assert(front.language == language);

        switch (language) {
            .python => try outlines.write_python(writer, source, front),
            .javascript, .typescript => try outlines.write_javascript(writer, source, tokens),
            .css, .go, .markup, .odin, .rust, .zig => {},
        }
    }

    fn write_python(
        outlines: *Outlines,
        writer: *std.Io.Writer,
        source: []const u8,
        front: *const Front,
    ) !void {
        assert(front.language == .python);
        assert(front.source.len == source.len);

        const python = &outlines.python;

        if (front.root()) |held| {
            const root = switch (held) {
                .python => |view| view,
                else => unreachable,
            };

            assert(root.tokens.len <= classified_count_max);

            outlines.pairs.build(source, root.tokens) catch |err| switch (err) {
                error.DepthExceeded => {},
            };

            outline_module.python.build(source, &outlines.pairs, root, python);

            assert(outlines.pairs.count() == root.tokens.len);
        } else {
            python.clear();
        }

        try write_python_arguments(writer, python);
        try write_python_assignments(writer, python);
        try write_python_bases(writer, python);
        try write_python_calls(writer, python);
        try write_python_decorators(writer, python);
        try write_python_items(writer, python);
        try write_segments(writer, python.segments.const_slice());
    }

    fn write_javascript(
        outlines: *Outlines,
        writer: *std.Io.Writer,
        source: []const u8,
        tokens: []const Token,
    ) !void {
        assert(tokens.len <= token_count_max);
        assert(source.len <= std.math.maxInt(u32));

        outlines.pairs.build(source, tokens) catch |err| switch (err) {
            error.DepthExceeded => {},
        };

        outline_module.javascript.build(source, tokens, &outlines.pairs, &outlines.javascript);

        const outline = &outlines.javascript;

        assert(outline.braces.count() == tokens.len);

        try write_javascript_scopes(writer, outline);
        try write_javascript_declarations(writer, outline);
        try write_javascript_objects(writer, outline);
        try write_javascript_members(writer, outline);
        try write_javascript_calls(writer, outline, source, tokens);
        try write_javascript_assigned(writer, outline);
        try write_javascript_statements(writer, outline);
        try write_segments(writer, outline.segments.const_slice());
        try write_javascript_braces(writer, outline);
    }
};

const Dumper = struct {
    io: std.Io,
    arguments: Arguments,
    source_buffer: []u8,
    record_buffer: []u8,
    tokens: Tokens,
    syntaxes: *Syntaxes,
    semantics: *Semantics,
    formatted: Buffer,
    formatters: Formatters,
    flavor: SourceType.Flavor,

    fn init(dumper: *Dumper, gpa: std.mem.Allocator, io: std.Io, arguments: Arguments) !void {
        const source_buffer = try gpa.alloc(u8, source_bytes_max + 1);
        errdefer gpa.free(source_buffer);

        const record_buffer = try gpa.alloc(u8, record_buffer_bytes);
        errdefer gpa.free(record_buffer);

        var tokens: Tokens = try .init(gpa, token_count_max);
        errdefer tokens.deinit(gpa);

        const syntaxes = try gpa.create(Syntaxes);
        errdefer gpa.destroy(syntaxes);

        try syntaxes.init(gpa);
        errdefer syntaxes.deinit(gpa);

        const semantics = try gpa.create(Semantics);
        errdefer gpa.destroy(semantics);

        try semantics.init(gpa);
        errdefer semantics.deinit(gpa);

        var formatted: Buffer = try .init(gpa, format_out_bytes_max);
        errdefer formatted.deinit(gpa);

        dumper.* = .{
            .io = io,
            .arguments = arguments,
            .source_buffer = source_buffer,
            .record_buffer = record_buffer,
            .tokens = tokens,
            .syntaxes = syntaxes,
            .semantics = semantics,
            .formatted = formatted,
            .formatters = undefined,
            .flavor = .plain,
        };

        try dumper.formatters.init(gpa, &format_capacity, .initMany(&formatted_languages), &.{});

        assert(dumper.source_buffer.len > source_bytes_max);
        assert(dumper.record_buffer.len == record_buffer_bytes);
    }

    fn deinit(dumper: *Dumper, gpa: std.mem.Allocator) void {
        assert(dumper.source_buffer.len == source_bytes_max + 1);
        assert(dumper.record_buffer.len == record_buffer_bytes);

        dumper.formatters.deinit(gpa);
        dumper.formatted.deinit(gpa);
        dumper.semantics.deinit(gpa);
        gpa.destroy(dumper.semantics);
        dumper.syntaxes.deinit(gpa);
        gpa.destroy(dumper.syntaxes);
        dumper.tokens.deinit(gpa);
        gpa.free(dumper.record_buffer);
        gpa.free(dumper.source_buffer);
        dumper.* = undefined;
    }

    fn dump(dumper: *Dumper, relative: []const u8, language: Language) !bool {
        assert(relative.len > 0);
        assert(relative.len < path_bytes_max);
        assert(Language.of_path(relative) == language);

        const source = dumper.read_source(relative) orelse return false;
        var written = false;

        dumper.flavor = if (std.mem.endsWith(u8, relative, ".pyi"))
            .stub
        else if (std.mem.endsWith(u8, relative, ".tsx"))
            .tsx
        else
            .plain;

        assert(source.len <= source_bytes_max);

        inline for (comptime std.enums.values(Level)) |level| {
            if (dumper.supports(level, language)) {
                try dumper.write_record(level, relative, language, source);

                written = true;
            }
        }

        return written;
    }

    fn lex_flavor(dumper: *const Dumper) SourceType.Flavor {
        const flavor: SourceType.Flavor = if (dumper.flavor == .tsx) .tsx else .plain;

        assert(flavor != .stub);

        return flavor;
    }

    fn read_source(dumper: *Dumper, relative: []const u8) ?[]const u8 {
        assert(relative.len > 0);
        assert(relative.len < path_bytes_max);

        var buffer: [path_bytes_max]u8 = undefined;

        const path = std.mem.print(&buffer, "{s}/{s}", .{
            dumper.arguments.corpus,
            relative,
        }) catch return null;

        const source = std.Io.Dir.cwd().readFile(dumper.io, path, dumper.source_buffer) catch {
            return null;
        };

        if (source.len > source_bytes_max) return null;
        return source;
    }

    fn supports(dumper: *const Dumper, comptime level: Level, language: Language) bool {
        assert(dumper.source_buffer.len > source_bytes_max);
        if (language == .markup) return false;

        const result = switch (level) {
            .tokens => language.lexes(),
            .tree => Syntaxes.parses(language),
            .semantics => language.lexes(),
            .format => language.lexes(),
        };

        if (result) assert(language.lexes());

        return result;
    }

    fn write_record(
        dumper: *Dumper,
        comptime level: Level,
        relative: []const u8,
        language: Language,
        source: []const u8,
    ) !void {
        assert(relative.len > 0);
        assert(source.len <= source_bytes_max);
        assert(Language.of_path(relative) == language);

        var buffer: [path_bytes_max]u8 = undefined;

        const path = try std.mem.print(&buffer, "{s}/{s}/{s}", .{
            dumper.arguments.out,
            @tagName(level),
            relative,
        });

        assert(path.len > dumper.arguments.out.len);

        const directory = std.Io.Dir.path.dirname(path) orelse return error.BadPath;
        const cwd = std.Io.Dir.cwd();

        try cwd.createDirPath(dumper.io, directory);

        const file = try cwd.createFile(dumper.io, path, .{});
        defer file.close(dumper.io);

        var writer = file.writer(dumper.io, dumper.record_buffer);

        switch (level) {
            .tokens => try dumper.write_tokens(&writer.interface, language, source),
            .tree => try dumper.write_tree(&writer.interface, language, source),
            .semantics => try dumper.write_semantics(&writer.interface, language, source),
            .format => try dumper.write_format(&writer.interface, language, source),
        }

        try writer.interface.flush();
    }

    fn write_tokens(
        dumper: *Dumper,
        writer: *std.Io.Writer,
        language: Language,
        source: []const u8,
    ) !void {
        assert(source.len <= source_bytes_max);

        const source_type: SourceType = .{ .flavor = dumper.lex_flavor(), .language = language };

        dumper.tokens.clear();

        const outcome = if (lex(source_type, source, &dumper.tokens)) |_|
            "complete"
        else |err| switch (err) {
            error.Truncated => "truncated",
        };

        assert(dumper.tokens.end_previous <= source.len);

        for (dumper.tokens.slice()) |token| {
            try writer.print("{d} {d} ", .{ token.offset, token.length });
            try write_kind(writer, token.kind);
            try writer.writeByte('\n');
        }

        try writer.print("lex {s}\n", .{outcome});
    }

    fn write_tree(
        dumper: *Dumper,
        writer: *std.Io.Writer,
        language: Language,
        source: []const u8,
    ) !void {
        assert(Syntaxes.parses(language));
        assert(source.len <= source_bytes_max);

        switch (language) {
            inline else => |tag| {
                if (comptime !@hasField(Syntaxes, Syntaxes.field_of(tag))) unreachable;

                const syntax = &@field(dumper.syntaxes, Syntaxes.field_of(tag));
                const structure = syntax.structure_of(source, language, dumper.flavor == .tsx);

                try syntax.write(writer, structure);
            },
        }
    }

    fn write_format(
        dumper: *Dumper,
        writer: *std.Io.Writer,
        language: Language,
        source: []const u8,
    ) !void {
        assert(language.lexes());
        assert(source.len <= source_bytes_max);

        const lex_type: SourceType = .{ .flavor = dumper.lex_flavor(), .language = language };

        dumper.tokens.clear();

        const complete = if (lex(lex_type, source, &dumper.tokens)) |_|
            true
        else |err| switch (err) {
            error.Truncated => false,
        };

        if (!complete) return writer.writeAll("outcome refusal\n");

        const front = &dumper.semantics.fronts[@backingInt(language)].?;

        assert(front.language == language);

        dumper.formatted.clear();

        const source_type: SourceType = .{
            .flavor = dumper.flavor,
            .language = language,
        };

        dumper.formatters.format(source_type, source, &dumper.formatted) catch |err| {
            const word = switch (err) {
                error.SourceInvalid => "refusal",
                else => "overflow",
            };

            return writer.print("outcome {s}\n", .{word});
        };

        try writer.writeAll(dumper.formatted.const_slice());
    }

    fn write_semantics(
        dumper: *Dumper,
        writer: *std.Io.Writer,
        language: Language,
        source: []const u8,
    ) !void {
        assert(language.lexes());
        assert(source.len <= source_bytes_max);

        const lex_type: SourceType = .{ .flavor = dumper.lex_flavor(), .language = language };

        dumper.tokens.clear();

        lex(lex_type, source, &dumper.tokens) catch |err| switch (err) {
            error.Truncated => {},
        };

        const semantics = dumper.semantics;
        const front = &semantics.fronts[@backingInt(language)].?;
        const lexed = dumper.tokens.slice();

        const source_type: SourceType = .{
            .flavor = dumper.flavor,
            .language = language,
        };

        const parsed = front.parse(&semantics.scratch, source_type, source, &semantic_options);
        const structure: Structure = if (parsed) |_| .complete else |_| front.outcome.?;

        assert(front.language == language);

        try writer.print("structure {s}\n", .{@tagName(structure)});
        try write_scopes(writer, front.bindings());
        try write_bindings(writer, front.bindings());
        try write_references(writer, front.bindings());
        try write_facts(writer, front.facts(), front.bindings().count());
        try write_detail(writer, front);
        try write_views(writer, front, source, &semantics.segments);

        if (returns_of(language)) |returns| {
            semantics.calls.build(front, &returns);
            try write_calls(writer, &semantics.calls);
        }

        try semantics.outlines.write(writer, language, source, lexed, front);
    }
};

const arguments_count_max = 8;
const classified_count_max = 1 << 22;
const diagnostic_count_max = 1 << 16;
const event_count_max = 1 << 23;
const index_none = std.math.maxInt(u32);
const format_out_bytes_max = 1 << 26;
const node_count_max = 1 << 22;
const path_bytes_max = 4096;
const paths_bytes_max = 1 << 26;
const paths_count_max = 1 << 20;
const record_buffer_bytes = 1 << 16;
const semantic_count_max = 1 << 20;
const source_bytes_max = 1 << 26;
const token_count_max = 1 << 22;
const usage = "usage: parity --corpus <directory> --out <directory> < paths";
const view_list_count_max = 1 << 10;

const call_capacity: Calls.Capacity = .{
    .edge_count_max = semantic_count_max,
    .function_count_max = semantic_count_max,
};

const format_capacity: FormatCapacity = .{
    .arena_bytes_max = 1 << 26,
    .element_count_max = 1 << 23,
    .front = syntax_capacity,
    .line_count_max = 1 << 18,
    .pragma_count_max = 1 << 12,
};

const semantic_limits: FrontCapacity = .{
    .diagnostic_count_max = diagnostic_count_max,
    .event_count_max = event_count_max,
    .node_count_max = node_count_max,
    .semantic = .{
        .binding_count_max = semantic_count_max,
        .fact_count_max = semantic_count_max,
        .reference_count_max = semantic_count_max,
        .scope_count_max = semantic_count_max,
    },
    .tag_count_max = semantic_count_max,
    .token_count_max = classified_count_max,
};

const syntax_capacity: FrontCapacity = syntax: {
    var held = semantic_limits;

    held.semantic = null;

    break :syntax held;
};

const semantic_options: FrontOptions = .{
    .globals = &.{},
    .python_version = .py310,
    .vocabulary = .empty,
};

const formatted_languages = [_]Language{
    .css,
    .go,
    .javascript,
    .odin,
    .python,
    .rust,
    .typescript,
    .zig,
};

pub fn main(init: std.process.Init) !void {
    assert(init.minimal.args.vector.len > 0);

    const gpa = init.gpa;
    const io = init.io;
    const arguments = try arguments_of(try init.minimal.args.toSlice(init.arena.allocator()));
    var buffer: [1 << 16]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &buffer);
    const paths = try stdin.interface.allocRemaining(gpa, .limited(paths_bytes_max));
    defer gpa.free(paths);

    var static_allocator: StaticAllocator = .init(gpa);
    defer static_allocator.deinit();

    var dumper: Dumper = undefined;

    try dumper.init(static_allocator.allocator(), io, arguments);
    defer dumper.deinit(static_allocator.allocator());

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    var count: u32 = 0;
    var seen: u32 = 0;
    var lines = std.mem.splitScalar(u8, paths, '\n');

    while (lines.next()) |relative| {
        seen += 1;

        assert(seen <= paths_count_max);

        if (relative.len == 0) continue;

        assert(relative.len < path_bytes_max);

        const language = Language.of_path(relative) orelse continue;

        if (try dumper.dump(relative, language)) count += 1;
    }

    assert(count <= seen);

    std.debug.print("parity: {d} files\n", .{count});
}

fn arguments_of(given: []const [:0]const u8) !Arguments {
    var corpus: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var index: usize = 1;

    assert(given.len >= 1);

    for (0..arguments_count_max + 1) |pair| {
        if (index >= given.len) break;
        if (pair == arguments_count_max) return fault("too many arguments\n{s}", .{usage});

        const flag = given[index];
        if (index + 1 >= given.len) return fault("{s} takes a value\n{s}", .{ flag, usage });

        const value = given[index + 1];

        index += 2;

        if (std.mem.eql(u8, flag, "--corpus")) {
            corpus = value;
        } else {
            if (!std.mem.eql(u8, flag, "--out")) {
                return fault("unknown flag {s}\n{s}", .{ flag, usage });
            }

            out = value;
        }
    } else unreachable;

    return .{
        .corpus = corpus orelse return fault("no --corpus\n{s}", .{usage}),
        .out = out orelse return fault("no --out\n{s}", .{usage}),
    };
}

fn fault(comptime format: []const u8, values: anytype) error{Usage} {
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(values)) == .@"struct");

    std.debug.print("parity: " ++ format ++ "\n", values);

    return error.Usage;
}

fn write_nodes(comptime Tree: type, writer: *std.Io.Writer, tree: *const Tree) !void {
    var steps = tree_module.walk(Tree, tree);
    var depth: u32 = 0;

    for (0..steps.step_max) |_| {
        const step = steps.next() orelse break;

        switch (step) {
            .enter => |node| {
                const held = tree.at(node);

                try writer.print("{d} {s} {d} {d}\n", .{
                    depth,
                    oracle_names.name_of(@TypeOf(held.kind), held.kind),
                    held.token_start,
                    held.token_end,
                });

                depth += 1;
            },
            .leave => {
                assert(depth > 0);

                depth -= 1;
            },
        }
    }

    assert(depth == 0);
    assert(steps.node == null);
}

fn write_scopes(writer: *std.Io.Writer, bindings: Bindings) !void {
    if (bindings != .empty) assert(bindings.scope_count() > 0);

    const scope_count = bindings.scope_count();

    try writer.print("scopes {d}\n", .{scope_count});

    for (0..scope_count) |index| {
        const scope = bindings.scope_at(@intCast(index));

        if (scope.parent) |parent| assert(parent < scope_count);
        if (scope.parent == null) assert(index == 0);

        try writer.print("{d} {s} {d} ", .{ index, @tagName(scope.class), scope.node });
        try write_index(writer, scope.parent orelse index_none);
        try writer.writeByte('\n');
    }
}

fn write_bindings(writer: *std.Io.Writer, bindings: Bindings) !void {
    if (bindings != .empty) assert(bindings.scope_count() > 0);

    const binding_count = bindings.count();

    try writer.print("bindings {d}\n", .{binding_count});

    for (0..binding_count) |index| {
        const binding = bindings.at(@intCast(index));

        assert(binding.name.end() >= binding.name.offset);
        assert(binding.scope < bindings.scope_count());

        try writer.print("{d} {s} {d} {d} {d} ", .{
            index,
            @tagName(binding.class),
            binding.name.offset,
            binding.name.end(),
            binding.node,
        });

        try write_index(writer, binding.scope);
        try writer.writeByte('\n');
    }
}

fn write_references(writer: *std.Io.Writer, bindings: Bindings) !void {
    if (bindings != .empty) assert(bindings.scope_count() > 0);

    const reference_count = bindings.reference_count();

    try writer.print("references {d}\n", .{reference_count});

    for (0..reference_count) |index| {
        const reference = bindings.reference_at(@intCast(index));
        const context = if (reference.is_store) "store" else "load";

        assert(reference.name.end() >= reference.name.offset);
        if (reference.resolution == .bound) assert(reference.resolution.bound < bindings.count());

        try writer.print("{d} {s} {d} {d} {d} ", .{
            index,
            context,
            reference.name.offset,
            reference.name.end(),
            reference.node,
        });

        try write_index(writer, reference.scope);

        switch (reference.resolution) {
            .bound => |binding| try writer.print(" bound {d}\n", .{binding}),
            .builtin, .external, .maybe, .unresolved => |_, tag| {
                try writer.print(" {s}\n", .{@tagName(tag)});
            },
        }
    }
}

fn write_facts(writer: *std.Io.Writer, facts: []const Fact, binding_count: u32) !void {
    assert(facts.len <= std.math.maxInt(u32));

    try writer.print("facts {d}\n", .{facts.len});

    for (facts, 0..) |fact, index| {
        const kind = switch (fact.kind) {
            .include => |include| if (include.only) "include_only" else "include",
            else => @tagName(fact.kind),
        };

        assert(fact.local.end() >= fact.local.offset);
        if (fact.binding.unwrap()) |held| assert(held < binding_count);

        try writer.print("{d} {s} ", .{ index, kind });
        try write_index(writer, fact.binding.unwrap() orelse index_none);

        try writer.print(" {d} {d} {d} {d} {d} {d}\n", .{
            fact.local.offset,
            fact.local.end(),
            fact.remote.offset,
            fact.remote.end(),
            fact.specifier.offset,
            fact.specifier.end(),
        });
    }
}

fn write_views(
    writer: *std.Io.Writer,
    front: *const Front,
    source: []const u8,
    segments: *ArrayType(Span),
) !void {
    assert(front.source.len == source.len);

    if (front.language == .css) return;

    const node_count = front.node_count();

    assert(front.language != .markup);
    assert(segments.capacity() == view_module.segment_count_max);

    try writer.print("views {d}\n", .{node_count});

    for (0..node_count) |node| {
        const held = front.view(@intCast(node)) orelse {
            try writer.print("{d} missing\n", .{node});

            continue;
        };

        try write_view(writer, held, source, segments);
    }
}

fn write_calls(writer: *std.Io.Writer, tables: *const Calls) !void {
    const functions = tables.functions();

    assert(functions.len <= semantic_count_max);

    try writer.print("calls {d}\n", .{functions.len});

    for (functions, 0..) |*function, index| {
        try writer.print("{d} ", .{index});
        try write_position(writer, function.binding);
        try writer.writeByte(' ');
        try write_span(writer, function.name);
        try writer.print(" {d} ", .{function.node});
        try write_span(writer, function.container orelse .empty);
        try writer.print(" {d} {d} ", .{ function.edge_start, function.edge_count });

        try write_flags(writer, &.{
            .{ .name = "comptime", .set = function.@"comptime" },
            .{ .name = "fallible", .set = function.fallible },
            .{ .name = "recursive", .set = function.recursive },
            .{ .name = "value", .set = function.value },
        });

        try writer.writeByte('\n');

        for (tables.edges_of(function)) |edge| {
            assert(edge.source == index);
            assert(edge.target < functions.len);

            try writer.writeAll("edge ");
            try write_span(writer, edge.call);
            try writer.print(" {d} {d}\n", .{ edge.source, edge.target });
        }
    }
}

fn returns_of(language: Language) ?Calls.Returns {
    if (language == .css) return null;

    const returns: Calls.Returns = switch (language) {
        .css, .markup => return null,
        .go => .{ .nothing_words = &.{}, .optional_markers = &.{}, .spelled = true },
        .javascript, .typescript => .{
            .nothing_words = &.{"undefined"},
            .optional_markers = &.{ "null", "undefined" },
            .spelled = false,
        },
        .odin => .{ .nothing_words = &.{}, .optional_markers = &.{"Maybe("}, .spelled = true },
        .python => .{
            .nothing_words = &.{"None"},
            .optional_markers = &.{ "None", "Optional[" },
            .spelled = false,
        },
        .rust => .{
            .nothing_words = &.{},
            .optional_markers = &.{ "Option<", "Result<" },
            .spelled = true,
        },
        .zig => .{ .nothing_words = &.{}, .optional_markers = &.{ "!", "?" }, .spelled = true },
    };

    assert(language != .css);

    assert(returns.optional_markers.len <= 2);

    return returns;
}

fn write_view(
    writer: *std.Io.Writer,
    view: View,
    source: []const u8,
    segments: *ArrayType(Span),
) !void {
    assert(view.span().end() <= source.len);

    const span = view.span();

    assert(span.end() <= source.len);

    try writer.print("{d} {s} ", .{ view.index(), @tagName(view.category()) });
    try write_position(writer, view.name_token());
    try writer.writeByte(' ');
    try write_view_index(writer, view.type_of());
    try writer.print(" {d} ", .{view.declaring_of().index()});
    try write_view_index(writer, view.enclosing_function());
    try writer.writeByte(' ');

    try write_flags(writer, &.{
        .{ .name = "inside_parameters", .set = view.is_inside_parameters() },
        .{ .name = "inside_signature", .set = view.is_inside_signature() },
        .{ .name = "arm", .set = view.is_an_arm() },
        .{ .name = "declares_a_container", .set = view.declares_a_container() },
    });

    try writer.print(" {d} {d}\n", .{ span.offset, span.end() });
    try write_view_casts(writer, view, source);

    if (view.as_function()) |function| try write_function(writer, function);
    if (view.as_import()) |import| try write_import(writer, import, segments);
    if (view.as_operation()) |operation| try write_operation(writer, operation);
    if (view.as_statement()) |statement| try write_statement(writer, statement);
}

fn write_view_casts(writer: *std.Io.Writer, view: View, source: []const u8) !void {
    assert(source.len <= source_bytes_max);
    assert(writer.buffer.len > 0);
    assert(view.span().end() <= source.len);

    if (view.as_call()) |call| {
        try writer.writeAll("call ");
        try write_view_index(writer, call.callee());
        try writer.writeByte(' ');
        try write_position(writer, call.name_token());
        try writer.writeByte(' ');
        try write_view_index(writer, call.receiver());
        try writer.writeByte(' ');
        try write_list(writer, call.arguments());
        try writer.writeByte('\n');
    }

    if (view.as_constant()) |constant| {
        try writer.print("constant {s}\n", .{@tagName(constant.literal_class(source))});
    }

    if (view.as_container()) |container| {
        try writer.writeAll("container ");
        try write_position(writer, container.name_token());
        try writer.print(" {d} ", .{container.body().index()});
        try write_list(writer, container.fields());
        try writer.writeByte(' ');
        try write_list(writer, container.members());
        try writer.writeByte('\n');
    }

    if (view.as_declaration()) |declaration| try write_declaration(writer, declaration);
    if (view.as_field()) |field| try write_field(writer, field);
}

fn write_declaration(writer: *std.Io.Writer, declaration: View.Declaration) !void {
    assert(writer.buffer.len > 0);
    assert(declaration.view.as_declaration() != null);

    try writer.writeAll("declaration ");
    try write_list(writer, declaration.names());
    try writer.writeByte(' ');
    try write_position(writer, declaration.name_token());
    try writer.writeByte(' ');
    try write_view_index(writer, declaration.type_of());
    try writer.writeByte(' ');
    try write_view_index(writer, declaration.value());
    try writer.writeByte(' ');

    try write_flags(writer, &.{
        .{ .name = "constant", .set = declaration.is_constant() },
        .{ .name = "mutable", .set = declaration.is_mutable() },
        .{ .name = "public", .set = declaration.is_public() },
    });

    try writer.writeByte('\n');
}

fn write_field(writer: *std.Io.Writer, field: View.Field) !void {
    assert(writer.buffer.len > 0);
    assert(field.view.as_field() != null);

    try writer.writeAll("field ");
    try write_position(writer, field.name_token());
    try writer.writeByte(' ');
    try write_view_index(writer, field.type_of());
    try writer.writeByte(' ');
    try write_view_index(writer, field.value());
    try writer.writeByte('\n');
}

fn write_function(writer: *std.Io.Writer, function: View.Function) !void {
    assert(writer.buffer.len > 0);
    assert(function.view.as_function() != null);

    try writer.writeAll("function ");
    try write_position(writer, function.name_token());
    try writer.writeByte(' ');
    try write_span(writer, function.parameters_span());
    try writer.writeByte(' ');
    try write_list(writer, function.parameter_nodes());
    try writer.writeByte(' ');
    try write_view_index(writer, function.body());
    try writer.writeByte(' ');
    try write_view_index(writer, function.returns());
    try writer.writeByte(' ');
    try write_view_index(writer, function.receiver());
    try writer.writeByte(' ');
    try write_span(writer, function.returns_span());
    try writer.writeByte(' ');

    try write_flags(writer, &.{
        .{ .name = "async", .set = function.is_async() },
        .{ .name = "public", .set = function.is_public() },
        .{ .name = "anonymous", .set = function.is_anonymous() },
    });

    try writer.writeByte('\n');
    try write_parameters(writer, function);
}

fn write_parameters(writer: *std.Io.Writer, function: View.Function) !void {
    assert(function.view.index() < function.view.node_count());

    var parameters = function.parameters();

    assert(parameters.remaining == view_module.parameter_count_max);

    for (0..parameters.remaining) |_| {
        const parameter = parameters.next() orelse return;

        try writer.print("parameter {d} {d} ", .{ parameter.node.index(), parameter.group });
        try write_position(writer, parameter.name);
        try writer.writeByte(' ');
        try write_view_index(writer, parameter.default);
        try writer.writeByte(' ');
        try write_view_index(writer, parameter.type_of);
        try writer.writeByte(' ');
        try write_span(writer, parameter.span);
        try writer.writeByte(' ');
        try write_span(writer, parameter.type_span);
        try writer.writeByte('\n');
    }

    const exhausted = parameters.next() == null;

    assert(parameters.remaining == 0);
    assert(exhausted);

    if (parameters.truncated()) try writer.writeAll("parameter ...\n");
}

fn write_import(
    writer: *std.Io.Writer,
    import: View.Import,
    segments: *ArrayType(Span),
) !void {
    assert(import.view.index() < import.view.node_count());

    var complete = true;

    import.segments(segments) catch |err| switch (err) {
        error.Truncated => complete = false,
    };

    assert(segments.count() <= segments.capacity());
    if (!complete) assert(segments.full());

    try writer.writeAll("import ");

    for (segments.const_slice(), 0..) |segment, index| {
        if (index > 0) try writer.writeByte(',');

        try write_span(writer, segment);
    }

    if (segments.count() == 0) try writer.writeByte('-');

    const state = if (complete) "complete" else "truncated";

    try writer.print(" {s} {}\n", .{ state, import.is_wildcard() });
}

fn write_operation(writer: *std.Io.Writer, operation: View.Operation) !void {
    assert(writer.buffer.len > 0);
    assert(operation.view.as_operation() != null);

    try writer.writeAll("operation ");
    try write_list(writer, operation.operands());
    try writer.writeByte(' ');
    try write_list(writer, operation.operator_tokens());
    try writer.writeByte('\n');
}

fn write_statement(writer: *std.Io.Writer, statement: View.Statement) !void {
    assert(writer.buffer.len > 0);
    assert(statement.view.as_statement() != null);

    try writer.writeAll("statement ");
    try write_view_index(writer, statement.header());
    try writer.writeByte(' ');
    try write_view_index(writer, statement.body());
    try writer.writeByte(' ');
    try write_list(writer, statement.clauses());
    try writer.writeByte('\n');
}

fn write_list(writer: *std.Io.Writer, items: anytype) !void {
    var rest = items;
    var written: u32 = 0;

    assert(writer.buffer.len > 0);

    for (0..view_list_count_max + 1) |_| {
        const item = rest.next() orelse break;

        if (written == view_list_count_max) {
            try writer.writeAll(",...");

            break;
        }

        if (written > 0) try writer.writeByte(',');

        if (@TypeOf(item) == View) {
            try writer.print("{d}", .{item.index()});
        } else {
            try writer.print("{d}", .{item});
        }

        written += 1;
    }

    if (written == 0) try writer.writeByte('-');

    assert(written <= view_list_count_max);
}

fn write_position(writer: *std.Io.Writer, position: ?u32) !void {
    assert(writer.buffer.len > 0);
    if (position) |held| assert(held < index_none);

    if (position) |held| {
        try writer.print("{d}", .{held});
    } else {
        try writer.writeAll("none");
    }
}

fn write_span(writer: *std.Io.Writer, span: ?Span) !void {
    assert(writer.buffer.len > 0);
    if (span) |held| assert(held.length <= index_none - held.offset);

    if (span) |held| {
        try writer.print("{d}:{d}", .{ held.offset, held.end() });
    } else {
        try writer.writeAll("none");
    }
}

fn write_view_index(writer: *std.Io.Writer, view: ?View) !void {
    assert(writer.buffer.len > 0);
    if (view) |held| assert(held.index() < index_none);

    if (view) |held| {
        try writer.print("{d}", .{held.index()});
    } else {
        try writer.writeAll("none");
    }
}

fn write_python_arguments(writer: *std.Io.Writer, outline: *const OutlinePython) !void {
    const arguments = outline.arguments.const_slice();

    try writer.print("outline arguments {d}\n", .{arguments.len});

    for (arguments, 0..) |argument, index| {
        assert(argument.value_token_start <= argument.value_token_end);

        try writer.print("{d} ", .{index});
        try write_span(writer, argument.name);
        try writer.writeByte(' ');
        try write_summary(writer, argument.summary);
        try write_indexes(writer, &.{ argument.value_token_start, argument.value_token_end });
    }
}

fn write_python_assignments(writer: *std.Io.Writer, outline: *const OutlinePython) !void {
    const assignments = outline.assignments.const_slice();

    try writer.print("outline assignments {d}\n", .{assignments.len});

    for (assignments, 0..) |assignment, index| {
        assert(assignment.value_token_start <= assignment.value_token_end + 1);

        try writer.print("{d} ", .{index});
        try write_span(writer, assignment.annotation);
        try writer.writeByte(' ');
        try write_index(writer, assignment.scope orelse index_none);
        try writer.writeByte(' ');
        try write_span(writer, assignment.target);
        try writer.print(" {}", .{assignment.target_is_simple});
        try write_indexes(writer, &.{ assignment.value_token_start, assignment.value_token_end });
    }
}

fn write_python_bases(writer: *std.Io.Writer, outline: *const OutlinePython) !void {
    const bases = outline.bases.const_slice();

    try writer.print("outline bases {d}\n", .{bases.len});

    for (bases, 0..) |base, index| {
        try writer.print("{d} ", .{index});
        try write_index(writer, base.class_definition);
        try writer.writeByte(' ');
        try write_summary(writer, base.summary);
        try writer.writeByte('\n');
    }
}

fn write_python_calls(writer: *std.Io.Writer, outline: *const OutlinePython) !void {
    const calls = outline.calls.const_slice();

    try writer.print("outline calls {d}\n", .{calls.len});

    for (calls, 0..) |call, index| {
        assert(call.paren_open < call.paren_close);

        try writer.print("{d} ", .{index});
        try write_index(writer, call.argument_first);
        try writer.print(" {d} ", .{call.argument_count});
        try write_index(writer, call.callee_segment_first);
        try writer.print(" {d}", .{call.callee_segment_count});
        try write_indexes_open(writer, &.{ call.paren_open, call.paren_close });
        try writer.writeByte(' ');
        try write_index(writer, call.scope orelse index_none);
        try writer.writeByte('\n');
    }
}

fn write_python_decorators(writer: *std.Io.Writer, outline: *const OutlinePython) !void {
    const decorators = outline.decorators.const_slice();

    try writer.print("outline decorators {d}\n", .{decorators.len});

    for (decorators, 0..) |decorator, index| {
        try writer.print("{d} ", .{index});
        try write_index(writer, decorator.call orelse index_none);
        try writer.writeByte(' ');
        try write_index(writer, decorator.definition orelse index_none);
        try writer.writeByte(' ');
        try write_index(writer, decorator.segment_first);
        try writer.print(" {d}\n", .{decorator.segment_count});
    }
}

fn write_python_items(writer: *std.Io.Writer, outline: *const OutlinePython) !void {
    const items = outline.items.const_slice();

    try writer.print("outline items {d}\n", .{items.len});

    for (items, 0..) |item, index| {
        assert(item != .sequence);

        try writer.print("{d} ", .{index});
        try write_summary(writer, item);
        try writer.writeByte('\n');
    }
}

fn write_javascript_scopes(writer: *std.Io.Writer, outline: *const OutlineJavaScript) !void {
    const scopes = outline.scopes.const_slice();

    try writer.print("outline scopes {d}\n", .{scopes.len});

    for (scopes, 0..) |scope, index| {
        if (scope.parent) |parent| assert(parent < scopes.len);

        try writer.print("{d} {s} ", .{ index, @tagName(scope.kind) });
        try write_index(writer, scope.parent orelse index_none);
        try write_indexes(writer, &.{ scope.token_start, scope.token_end });
    }
}

fn write_javascript_declarations(
    writer: *std.Io.Writer,
    outline: *const OutlineJavaScript,
) !void {
    const declarations = outline.declarations.const_slice();

    try writer.print("outline declarations {d}\n", .{declarations.len});

    for (declarations, 0..) |declaration, index| {
        assert(declaration.scope_token_start <= declaration.scope_token_end);

        try writer.print("{d} {s} ", .{ index, @tagName(declaration.kind) });
        try write_span(writer, declaration.name);

        try write_indexes(writer, &.{
            declaration.scope_token_start,
            declaration.scope_token_end,
            declaration.value_token_start,
            declaration.value_token_end,
        });
    }
}

fn write_javascript_objects(writer: *std.Io.Writer, outline: *const OutlineJavaScript) !void {
    const objects = outline.objects.const_slice();

    try writer.print("outline objects {d}\n", .{objects.len});

    for (objects, 0..) |object, index| {
        assert(object.brace_open < object.brace_close);

        try writer.print("{d} ", .{index});
        try write_index(writer, object.brace_open);
        try write_indexes_open(writer, &.{ object.brace_close, object.member_first });
        try writer.print(" {d}\n", .{object.member_count});
    }
}

fn write_javascript_members(writer: *std.Io.Writer, outline: *const OutlineJavaScript) !void {
    const members = outline.members.const_slice();

    try writer.print("outline members {d}\n", .{members.len});

    for (members, 0..) |member, index| {
        try writer.print("{d} ", .{index});

        try write_flags(writer, &.{
            .{ .name = "await", .set = member.has_await },
            .{ .name = "async", .set = member.is_async },
            .{ .name = "method", .set = member.is_method },
            .{ .name = "shorthand", .set = member.is_shorthand },
            .{ .name = "spread", .set = member.is_spread },
        });

        try writer.writeByte(' ');
        try write_span(writer, member.name);

        try write_indexes(writer, &.{
            member.object,
            member.token_start,
            member.token_end,
            member.value_token_start,
            member.value_token_end,
        });
    }
}

fn write_javascript_calls(
    writer: *std.Io.Writer,
    outline: *const OutlineJavaScript,
    source: []const u8,
    tokens: []const Token,
) !void {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    const calls = outline.calls.const_slice();
    const statements = outline.statements.const_slice();

    try writer.print("outline calls {d}\n", .{calls.len});

    for (calls, 0..) |*call, index| {
        const fate = outline_module.javascript.chain_fate(call, source, tokens, statements);

        assert(call.paren_open < call.paren_close);

        try writer.print("{d} ", .{index});
        try write_index(writer, call.callee_segment_first);
        try writer.print(" {d}", .{call.callee_segment_count});
        try write_indexes_open(writer, &.{ call.paren_open, call.paren_close });
        try writer.writeByte(' ');
        try write_index(writer, call.scope orelse index_none);
        try writer.writeByte(' ');

        try write_flags(writer, &.{
            .{ .name = "chained", .set = fate.chained },
            .{ .name = "floating", .set = fate.floating },
        });

        try writer.writeByte('\n');
    }
}

fn write_javascript_assigned(writer: *std.Io.Writer, outline: *const OutlineJavaScript) !void {
    const assigned = outline.assigned.const_slice();

    try writer.print("outline assigned {d}\n", .{assigned.len});

    for (assigned, 0..) |held, index| {
        try writer.print("{d} ", .{index});
        try write_span(writer, held.name);
        try writer.writeByte('\n');
    }
}

fn write_javascript_statements(writer: *std.Io.Writer, outline: *const OutlineJavaScript) !void {
    const statements = outline.statements.const_slice();

    try writer.print("outline statements {d}\n", .{statements.len});

    for (statements, 0..) |statement, index| {
        assert(statement.token_start < statement.token_end);

        try writer.print("{d} ", .{index});
        try write_index(writer, statement.scope orelse index_none);
        try write_indexes(writer, &.{ statement.token_start, statement.token_end });
    }
}

fn write_javascript_braces(writer: *std.Io.Writer, outline: *const OutlineJavaScript) !void {
    var written = false;

    try writer.writeAll("outline braces ");

    for (0..outline.braces.count()) |position| {
        const kind = outline.brace_kind(@intCast(position));
        if (kind == .none) continue;

        if (written) try writer.writeByte(',');

        try writer.print("{d}:{s}", .{ position, @tagName(kind) });
        written = true;
    }

    if (!written) try writer.writeByte('-');

    try writer.writeByte('\n');
}

fn write_segments(writer: *std.Io.Writer, segments: []const Span) !void {
    assert(segments.len <= std.math.maxInt(u32));

    try writer.print("outline segments {d}\n", .{segments.len});

    for (segments, 0..) |segment, index| {
        try writer.print("{d} ", .{index});
        try write_span(writer, segment);
        try writer.writeByte('\n');
    }
}

fn write_summary(writer: *std.Io.Writer, summary: Summary) !void {
    if (summary == .call) assert(summary.call.callee_count > 0);

    switch (summary) {
        .call => |call| {
            try writer.writeAll("call ");
            try write_index(writer, call.callee_first);
            try writer.print(" {d} ", .{call.callee_count});
            try write_index(writer, call.paren_open);
        },
        .dotted_name => |dotted| {
            try writer.writeAll("dotted ");
            try write_index(writer, dotted.segment_first);
            try writer.print(" {d}", .{dotted.segment_count});
        },
        .dynamic => try writer.writeAll("dynamic"),
        .literal => |literal| {
            try writer.writeAll("literal ");
            try write_span(writer, literal.content);
        },
        .sequence => |sequence| {
            try writer.writeAll("sequence ");
            try write_index(writer, sequence.item_first);
            try writer.print(" {d}", .{sequence.item_count});
        },
    }
}

fn write_flags(writer: *std.Io.Writer, flags: []const Flag) !void {
    assert(flags.len > 0);

    var written = false;

    for (flags) |flag| {
        if (!flag.set) continue;

        if (written) try writer.writeByte(',');

        try writer.writeAll(flag.name);
        written = true;
    }

    if (!written) try writer.writeByte('-');
}

fn write_indexes(writer: *std.Io.Writer, indexes: []const u32) !void {
    assert(indexes.len > 0);

    try write_indexes_open(writer, indexes);
    try writer.writeByte('\n');
}

fn write_indexes_open(writer: *std.Io.Writer, indexes: []const u32) !void {
    assert(indexes.len > 0);

    for (indexes) |index| {
        try writer.writeByte(' ');
        try write_index(writer, index);
    }
}

fn write_detail(writer: *std.Io.Writer, front: *const Front) !void {
    assert(front.language.lexes());

    switch (front.bindings()) {
        .empty => if (front.language == .css) {
            if (front.outcome.? == .complete) try write_css(writer, css_semantic_of(front).?);
        } else {
            assert(front.outcome.? != .complete);
        },
        .python => |semantic| try write_python(writer, semantic, python_checks_of(front)),
        inline .go, .javascript, .odin, .rust, .zig => |semantic, tag| {
            assert(front.outcome.? == .complete);

            try write_detail_scopes(writer, @tagName(tag), semantic);
            try write_detail_bindings(writer, @tagName(tag), semantic);
            try write_detail_references(writer, @tagName(tag), semantic);
        },
    }
}

fn write_detail_scopes(
    writer: *std.Io.Writer,
    comptime prefix: []const u8,
    semantic: anytype,
) !void {
    assert(prefix.len <= std.math.maxInt(u32));
    comptime assert(@typeInfo(@TypeOf(semantic)) == .pointer);

    const scopes = semantic.scope_slice();
    const Scope = @typeInfo(@TypeOf(scopes)).pointer.child;

    try writer.print(prefix ++ " scopes {d}\n", .{scopes.len});

    for (scopes, 0..) |*scope, index| {
        if (index == 0) assert(scope.parent == index_none);
        if (scope.parent != index_none) assert(scope.parent < index);

        try writer.print("{d} {s} {d} ", .{ index, @tagName(scope.kind), scope.node });
        try write_index(writer, scope.parent);
        try writer.print(" {}", .{scope.dynamic});

        if (comptime ext_has(Scope, "arrow")) try writer.print(" {}", .{scope.ext.arrow});

        try writer.writeByte('\n');
    }
}

fn write_detail_bindings(
    writer: *std.Io.Writer,
    comptime prefix: []const u8,
    semantic: anytype,
) !void {
    assert(prefix.len <= std.math.maxInt(u32));
    comptime assert(@typeInfo(@TypeOf(semantic)) == .pointer);

    const bindings = semantic.binding_slice();
    const scope_count = semantic.scope_slice().len;
    const Binding = @typeInfo(@TypeOf(bindings)).pointer.child;

    try writer.print(prefix ++ " bindings {d}\n", .{bindings.len});

    for (bindings, 0..) |*binding, index| {
        assert(binding.scope < scope_count);
        if (binding.name_previous != index_none) assert(binding.name_previous < index);

        try writer.print("{d} {s} {s} {d} {d} {d} {d} ", .{
            index,
            @tagName(binding.kind),
            @tagName(binding.namespace),
            binding.name.offset,
            binding.name.end(),
            binding.name_hash,
            binding.node,
        });

        try write_index(writer, binding.scope);
        try writer.writeByte(' ');
        try write_index(writer, binding.name_previous);
        try writer.writeByte(' ');
        try write_index(writer, binding.scope_previous);

        const positioned = comptime ext_has(Binding, "parameter");

        if (@hasField(Binding, "from")) {
            if (!positioned) {
                try writer.writeByte(' ');
                try write_index(writer, binding.from);
            }
        }

        if (positioned) {
            try writer.writeByte(' ');
            try write_index(writer, binding.dead_zone_end);
            try writer.print(" {} {d}", .{ binding.kind.hoists(), binding.ext.parameter });
        }

        try writer.writeByte('\n');
    }
}

fn write_detail_references(
    writer: *std.Io.Writer,
    comptime prefix: []const u8,
    semantic: anytype,
) !void {
    assert(prefix.len <= std.math.maxInt(u32));
    comptime assert(@typeInfo(@TypeOf(semantic)) == .pointer);

    const references = semantic.reference_slice();
    const binding_count = semantic.count();
    const Reference = @typeInfo(@TypeOf(references)).pointer.child;

    try writer.print(prefix ++ " references {d}\n", .{references.len});

    for (references, 0..) |*reference, index| {
        assert(reference.name.end() >= reference.name.offset);
        if (reference.resolution == .bound) assert(reference.resolution.bound < binding_count);

        try writer.print("{d} {s} {s} {d} {d} {d} ", .{
            index,
            @tagName(reference.context),
            @tagName(reference.namespace),
            reference.name.offset,
            reference.name.end(),
            reference.node,
        });

        try write_index(writer, reference.scope);

        switch (reference.resolution) {
            .bound => |binding| try writer.print(" bound {d}", .{binding}),
            else => try writer.print(" {s}", .{@tagName(reference.resolution)}),
        }

        if (@hasField(Reference, "generic")) {
            try writer.print(" {} {}", .{ reference.generic, reference.qualified });
        }

        if (comptime ext_has(Reference, "generic")) {
            try writer.print(" {} {}", .{ reference.ext.generic, reference.ext.qualified });
        }

        if (comptime ext_has(Reference, "positional")) {
            try writer.print(" {} {}", .{ reference.dead_zone, reference.ext.positional });
        }

        try writer.writeByte('\n');
    }
}

fn ext_has(comptime Row: type, comptime field: []const u8) bool {
    if (!@hasField(Row, "ext")) return false;
    assert(field.len <= std.math.maxInt(u32));

    const Ext = @FieldType(Row, "ext");
    if (@typeInfo(Ext) != .@"struct") return false;
    return @hasField(Ext, field);
}

fn write_css(writer: *std.Io.Writer, semantic: *const grammars.css.Semantic) !void {
    const definitions = semantic.definition_slice();
    const uses = semantic.use_slice();

    try writer.print("css definitions {d}\n", .{definitions.len});

    for (definitions, 0..) |*definition, index| {
        assert(definition.name.end() > definition.name.offset);
        if (definition.name_previous != index_none) assert(definition.name_previous < index);

        try writer.print("{d} {s} {d} {d} {d} ", .{
            index,
            @tagName(definition.kind),
            definition.name.offset,
            definition.name.end(),
            definition.name_hash,
        });

        try write_index(writer, definition.name_previous);
        try writer.print(" {d}\n", .{definition.node});
    }

    try writer.print("css uses {d}\n", .{uses.len});

    for (uses, 0..) |*held, index| {
        assert(held.name.end() >= held.name.offset);
        if (held.definition != index_none) assert(held.definition < definitions.len);

        try writer.print("{d} {s} {d} {d} {d} ", .{
            index,
            @tagName(held.kind),
            held.name.offset,
            held.name.end(),
            held.definition_count,
        });

        try write_index(writer, held.definition);
        try writer.print(" {d}\n", .{held.node});
    }
}

fn write_python(
    writer: *std.Io.Writer,
    semantic: *const PythonSemantic,
    checks: []const CheckError,
) !void {
    assert(semantic.scope_slice().len > 0);
    assert(python_semantic.branch_slice(semantic).len > 0);
    assert(checks.len <= std.math.maxInt(u32));

    try write_python_scopes(writer, semantic);
    try write_python_branches(writer, semantic);
    try write_python_bindings(writer, semantic);
    try write_python_references(writer, semantic);
    try write_python_exports(writer, semantic);
    try write_python_checks(writer, checks);
}

fn write_python_scopes(writer: *std.Io.Writer, semantic: *const PythonSemantic) !void {
    const scopes = semantic.scope_slice();

    try writer.print("python scopes {d}\n", .{scopes.len});

    for (scopes, 0..) |scope, index| {
        assert(scope.parent == index_none or scope.parent < scopes.len);
        if (index == 0) assert(scope.parent == index_none);

        try writer.print("{d} {s} {d} ", .{ index, @tagName(scope.kind), scope.node });
        try write_index(writer, scope.parent);
        try writer.writeByte('\n');
    }
}

fn write_python_branches(writer: *std.Io.Writer, semantic: *const PythonSemantic) !void {
    const branches = python_semantic.branch_slice(semantic);

    try writer.print("python branches {d}\n", .{branches.len});

    for (branches, 0..) |branch, index| {
        assert(branch.parent == index_none or branch.parent < index);
        if (index > 0) assert(branch.node != index_none);

        try writer.print("{d} {d} ", .{ index, branch.node });
        try write_index(writer, branch.parent);
        try writer.writeByte('\n');
    }
}

fn write_python_bindings(writer: *std.Io.Writer, semantic: *const PythonSemantic) !void {
    const bindings = semantic.binding_slice();

    try writer.print("python bindings {d}\n", .{bindings.len});

    for (bindings, 0..) |binding, index| {
        assert(binding.name.end() >= binding.name.offset);
        assert(binding.scope < semantic.scope_slice().len);

        try writer.print("{d} {s} ", .{ index, @tagName(binding.kind) });

        if (binding.ext.declared) |declared| {
            try writer.print("{s} ", .{@tagName(declared)});
        } else {
            try writer.writeAll("none ");
        }

        try write_flag_fields(writer, binding.ext.flags);

        try writer.print(" {d} {d} {d} {d} ", .{
            binding.name.offset,
            binding.name.end(),
            binding.name_hash,
            binding.node,
        });

        const indexes = [_]u32{
            binding.scope,
            binding.name_previous,
            binding.scope_previous,
            binding.from,
            binding.ext.branch,
        };

        for (indexes) |held| {
            try write_index(writer, held);
            try writer.writeByte(' ');
        }

        try writer.print("{d}\n", .{binding.reference_count});
    }
}

fn write_python_references(writer: *std.Io.Writer, semantic: *const PythonSemantic) !void {
    const references = semantic.reference_slice();

    try writer.print("python references {d}\n", .{references.len});

    for (references, 0..) |reference, index| {
        assert(reference.name.end() >= reference.name.offset);
        assert(reference.scope < semantic.scope_slice().len);

        try writer.print("{d} {s} ", .{ index, @tagName(reference.context) });
        try write_flag_fields(writer, reference.ext.flags);

        try writer.print(" {d} {d} {d} {d} ", .{
            reference.name.offset,
            reference.name.end(),
            reference.name_hash,
            reference.node,
        });

        try write_index(writer, reference.scope);
        try writer.writeByte(' ');
        try write_index(writer, reference.ext.branch);

        switch (reference.resolution) {
            .bound => |binding| try writer.print(" bound {d}\n", .{binding}),
            .builtin,
            .external,
            .maybe,
            .unresolved,
            => |_, tag| try writer.print(" {s}\n", .{@tagName(tag)}),
        }
    }
}

fn write_python_exports(writer: *std.Io.Writer, semantic: *const PythonSemantic) !void {
    const exports = python_semantic.export_slice(semantic);

    try writer.print("exports {d}\n", .{exports.len});

    for (exports, 0..) |span, index| {
        assert(span.end() >= span.offset);
        assert(index < exports.len);

        try writer.print("{d} {d} {d}\n", .{ index, span.offset, span.end() });
    }
}

fn write_python_checks(writer: *std.Io.Writer, checks: []const CheckError) !void {
    assert(checks.len <= std.math.maxInt(u32));

    try writer.print("checks {d}\n", .{checks.len});

    for (checks, 0..) |check, index| {
        assert(check.span.end() >= check.span.offset);
        assert(index < checks.len);

        try writer.print("{d} ", .{index});

        switch (check.kind) {
            .unsupported => |feature| try writer.print("unsupported.{s}", .{@tagName(feature)}),
            else => |_, tag| try writer.writeAll(@tagName(tag)),
        }

        try writer.print(" {d} {d}\n", .{ check.span.offset, check.span.end() });
    }
}

fn write_flag_fields(writer: *std.Io.Writer, flags: anytype) !void {
    comptime assert(@typeInfo(@TypeOf(flags)) == .@"struct");

    const field_names = @typeInfo(@TypeOf(flags)).@"struct".field_names;
    var written = false;

    comptime assert(field_names.len > 0);
    assert(writer.buffer.len > 0);

    inline for (field_names) |name| {
        if (@field(flags, name)) {
            if (written) try writer.writeByte(',');

            try writer.writeAll(name);
            written = true;
        }
    }

    if (!written) try writer.writeByte('-');
}

fn write_index(writer: *std.Io.Writer, index: u32) !void {
    assert(writer.buffer.len > 0);
    assert(index < std.math.maxInt(u32));

    if (index == index_none) {
        try writer.writeAll("none");
    } else {
        assert(index < index_none);

        try writer.print("{d}", .{index});
    }
}

fn write_kind(writer: *std.Io.Writer, kind: Token.Kind) !void {
    switch (kind) {
        .keyword => |keyword| try writer.print("keyword.{s}", .{@tagName(keyword)}),
        .punctuation => |punctuation| try writer.print("punctuation.{s}", .{@tagName(punctuation)}),
        else => try writer.writeAll(@tagName(kind)),
    }
}

test "a record level is named like its directory" {
    try std.testing.expectEqualStrings("tokens", @tagName(Level.tokens));
    try std.testing.expectEqualStrings("format", @tagName(Level.format));
}

test "a token kind is written the way the rust dumper writes it" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try write_kind(&writer, .{ .keyword = .loop_unbounded });
    try writer.writeByte(' ');
    try write_kind(&writer, .{ .punctuation = .assign_declare });
    try writer.writeByte(' ');
    try write_kind(&writer, .block_end);
    try writer.writeByte(' ');
    try write_kind(&writer, .{ .keyword = .@"return" });

    try std.testing.expectEqualStrings(
        "keyword.loop_unbounded punctuation.assign_declare block_end keyword.return",
        writer.buffered(),
    );
}
