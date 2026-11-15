const std = @import("std");
const assert = std.debug.assert;
const Buffer = @import("../stdx/bounded/buffer.zig");
const Front = @import("../syntax/front.zig").Front;
const Fronts = @import("../syntax/fronts.zig").Fronts;
const Language = @import("../syntax/language.zig").Language;
const LineIndex = @import("../text/line_index.zig").LineIndex;
const Pragmas = @import("pragma.zig").Pragmas;
const PrintOptions = @import("print.zig").Options;
const SourceType = @import("../syntax/language.zig").SourceType;
const Vocabulary = @import("../syntax/markup.zig").Vocabulary;
const css = @import("css.zig");
const go = @import("go.zig");
const javascript = @import("javascript.zig");
const markup = @import("markup.zig");
const odin = @import("odin.zig");
const python = @import("python.zig");
const rust = @import("rust.zig");
const style = @import("../syntax/python/style.zig");
const syntax_of = @import("../syntax/front.zig").syntax_of;
const typescript = @import("typescript.zig");
const zig = @import("zig.zig");

pub const Formatters = struct {
    css: ?css.Formatter,
    fronts: Fronts,
    go: ?go.Formatter,
    javascript: ?javascript.Formatter,
    markup: ?MarkupFormatter,
    odin: ?odin.Formatter,
    options: Options,
    python: ?PythonFormatter,
    rust: ?rust.Formatter,
    typescript: ?typescript.Formatter,
    zig: ?zig.Formatter,

    pub const Capacity = struct {
        arena_bytes_max: u32,
        element_count_max: u32,
        front: Front.Capacity,
        line_count_max: u32,
        pragma_count_max: u32,
    };

    pub const CapacityError = error{
        DepthExceeded,
        DiagnosticsExhausted,
        EventsExhausted,
        IntermediatesExhausted,
        LinesExhausted,
        NodesExhausted,
        OutputExhausted,
        PragmasExhausted,
        TagsExhausted,
        TokensExhausted,
    };

    pub const Error = CapacityError || SyntaxError;

    pub const Options = struct {
        indent_width: u32 = PrintOptions.default.indent_width,
        line_ending: ?LineEnding = null,
        line_width: u32 = PrintOptions.default.line_width,
        magic_trailing_comma: bool = true,
        quote: Quote = .double,
        tabs: bool = PrintOptions.default.tabs,
        vocabulary: Vocabulary = .empty,

        pub const LineEnding = @import("../text/line_ending.zig").LineEnding;
        pub const Quote = python.QuotePreference;

        fn printed(options: *const Options) PrintOptions {
            assert(options.indent_width > 0);
            assert(options.line_width > 0);

            return .{
                .indent_width = options.indent_width,
                .line_width = options.line_width,
                .tabs = options.tabs,
            };
        }
    };

    pub const SyntaxError = error{SourceInvalid};

    fn engines_deinit(formatters: *Formatters, gpa: std.mem.Allocator) void {
        if (formatters.css) |*held| held.deinit(gpa);
        if (formatters.go) |*held| held.deinit(gpa);
        if (formatters.javascript) |*held| held.deinit(gpa);
        if (formatters.markup) |*held| held.deinit(gpa);
        if (formatters.odin) |*held| held.deinit(gpa);
        if (formatters.python) |*held| held.deinit(gpa);
        if (formatters.rust) |*held| held.deinit(gpa);
        if (formatters.typescript) |*held| held.deinit(gpa);
        if (formatters.zig) |*held| held.deinit(gpa);
    }

    fn init_brace(
        comptime Module: type,
        gpa: std.mem.Allocator,
        capacity: *const Capacity,
    ) std.mem.Allocator.Error!Module.Formatter {
        comptime assert(@hasDecl(Module, "Formatter"));
        assert(capacity.element_count_max > 0);
        assert(capacity.arena_bytes_max > 0);

        return Module.Formatter.init(gpa, capacity.element_count_max, capacity.arena_bytes_max);
    }

    fn supports(formatters: *const Formatters, language: Language) bool {
        assert(@backingInt(language) < Language.count);

        const supported = switch (language) {
            .css => formatters.css != null,
            .go => formatters.go != null,
            .javascript => formatters.javascript != null,
            .markup => formatters.markup != null,
            .odin => formatters.odin != null,
            .python => formatters.python != null,
            .rust => formatters.rust != null,
            .typescript => formatters.typescript != null,
            .zig => formatters.zig != null,
        };

        if (language == .markup) assert(supported == (formatters.markup != null));

        return supported;
    }

    pub fn init(
        formatters: *Formatters,
        gpa: std.mem.Allocator,
        capacity: *const Capacity,
        reserved: std.EnumSet(Language),
        options: *const Options,
    ) std.mem.Allocator.Error!void {
        assert(capacity.element_count_max > 0);
        assert(capacity.arena_bytes_max > 0);
        assert(capacity.front.semantic == null);
        assert(reserved.count() > 0);
        assert(options.indent_width > 0);
        assert(options.line_width > 0);

        const front_options: Front.Options = .{
            .globals = &.{},
            .python_version = .py310,
            .vocabulary = options.vocabulary,
        };

        try formatters.fronts.init(gpa, &capacity.front, reserved, &front_options);
        errdefer formatters.fronts.deinit(gpa);

        formatters.css = null;
        formatters.go = null;
        formatters.javascript = null;
        formatters.markup = null;
        formatters.odin = null;
        formatters.options = options.*;
        formatters.python = null;
        formatters.rust = null;
        formatters.typescript = null;
        formatters.zig = null;
        errdefer formatters.engines_deinit(gpa);

        if (reserved.contains(.css)) formatters.css = try init_brace(css, gpa, capacity);
        if (reserved.contains(.go)) formatters.go = try init_brace(go, gpa, capacity);

        if (reserved.contains(.javascript)) {
            formatters.javascript = try init_brace(javascript, gpa, capacity);
        }

        if (reserved.contains(.markup)) {
            formatters.markup = try MarkupFormatter.init(gpa, capacity);
        }

        if (reserved.contains(.odin)) formatters.odin = try init_brace(odin, gpa, capacity);

        if (reserved.contains(.python)) {
            formatters.python = try PythonFormatter.init(gpa, capacity);
        }

        if (reserved.contains(.rust)) formatters.rust = try init_brace(rust, gpa, capacity);

        if (reserved.contains(.typescript)) {
            formatters.typescript = try init_brace(typescript, gpa, capacity);
        }

        if (reserved.contains(.zig)) formatters.zig = try init_brace(zig, gpa, capacity);

        assert(formatters.languages().eql(reserved));
    }

    pub fn deinit(formatters: *Formatters, gpa: std.mem.Allocator) void {
        assert(formatters.options.indent_width > 0);
        assert(formatters.options.line_width > 0);

        formatters.engines_deinit(gpa);
        formatters.fronts.deinit(gpa);
        formatters.* = undefined;
    }

    pub fn format(
        formatters: *Formatters,
        source_type: SourceType,
        source: []const u8,
        out: *Buffer,
    ) Error!void {
        assert(source_type.valid());

        const language = source_type.language;
        const options = &formatters.options;

        assert(source.len <= std.math.maxInt(u32));
        assert(formatters.supports(language));

        const front = formatters.fronts.parse(source_type, source) catch |err| switch (err) {
            error.BindingsExhausted,
            error.ChecksExhausted,
            error.FactsExhausted,
            error.ReferencesExhausted,
            error.ScopesExhausted,
            => unreachable,
            error.DepthExceeded,
            error.DiagnosticsExhausted,
            error.EventsExhausted,
            error.IntermediatesExhausted,
            error.NodesExhausted,
            error.TagsExhausted,
            error.TokensExhausted,
            => |exhausted| return exhausted,
        };

        assert(front.language == language);
        assert(front.outcome.? == .complete);

        return switch (language) {
            .css => format_brace(css, &formatters.css.?, front, source, options, out),
            .go => format_brace(go, &formatters.go.?, front, source, options, out),
            .javascript => format_brace(
                javascript,
                &formatters.javascript.?,
                front,
                source,
                options,
                out,
            ),
            .markup => formatters.markup.?.format(front, source, options, out),
            .odin => format_brace(odin, &formatters.odin.?, front, source, options, out),
            .python => formatters.python.?.format(front, source, options, out),
            .rust => format_brace(rust, &formatters.rust.?, front, source, options, out),
            .typescript => format_typescript(&formatters.typescript.?, front, source, options, out),
            .zig => format_brace(zig, &formatters.zig.?, front, source, options, out),
        };
    }

    pub fn languages(formatters: *const Formatters) std.EnumSet(Language) {
        var reserved: std.EnumSet(Language) = .empty;

        for (std.enums.values(Language)) |language| {
            if (formatters.supports(language)) reserved.insert(language);
        }

        assert(reserved.count() > 0);

        return reserved;
    }

    test Capacity {
        const gpa = std.testing.allocator;

        const capacity: Capacity = .{
            .arena_bytes_max = 1 << 14,
            .element_count_max = 1 << 12,
            .front = .{
                .diagnostic_count_max = 1 << 6,
                .event_count_max = 1 << 12,
                .node_count_max = 1 << 10,
                .semantic = null,
                .tag_count_max = 1 << 6,
                .token_count_max = 1 << 10,
            },
            .line_count_max = 1 << 8,
            .pragma_count_max = 1 << 4,
        };

        var formatters: Formatters = undefined;

        try formatters.init(gpa, &capacity, .initOne(.python), &.{});
        defer formatters.deinit(gpa);

        var out: Buffer = try .init(gpa, 1 << 12);
        defer out.deinit(gpa);

        const line = "import a\n";
        const repeated: [1 << 7][line.len]u8 = @splat(line.*);
        const source: []const u8 = std.mem.asBytes(&repeated);

        try formatters.format(.of(.python), source, &out);

        try std.testing.expectEqualStrings(source, out.const_slice());
    }
};

pub const FormatterError = error{OutputExhausted} || Formatters.SyntaxError;

const MarkupFormatter = struct {
    formatter: markup.Formatter,
    lines: LineIndex,

    fn init(
        gpa: std.mem.Allocator,
        capacity: *const Formatters.Capacity,
    ) std.mem.Allocator.Error!MarkupFormatter {
        assert(capacity.element_count_max > 0);
        assert(capacity.line_count_max > 0);

        var formatter: markup.Formatter = try .init(
            gpa,
            capacity.element_count_max,
            capacity.line_count_max,
            capacity.arena_bytes_max,
        );

        errdefer formatter.deinit(gpa);

        const lines: LineIndex = try .init(gpa, capacity.line_count_max);
        return .{ .formatter = formatter, .lines = lines };
    }

    fn deinit(held: *MarkupFormatter, gpa: std.mem.Allocator) void {
        assert(held.lines.count() <= held.lines.capacity());

        held.lines.deinit(gpa);
        held.formatter.deinit(gpa);
        held.* = undefined;
    }

    fn format(
        held: *MarkupFormatter,
        front: *const Front,
        source: []const u8,
        options: *const Formatters.Options,
        out: *Buffer,
    ) Formatters.Error!void {
        assert(front.language == .markup);
        assert(front.outcome.? == .complete);
        assert(source.len <= std.math.maxInt(u32));

        held.lines.build(source) catch |err| switch (err) {
            error.Truncated => return error.LinesExhausted,
        };

        const tables = front.markup().?;

        const markup_input: markup.Input = .{
            .index = &held.lines,
            .map = tables.blocks(),
            .options = options.printed(),
            .source = source,
            .tokens = tables.tokens(),
            .tree = tables.tree(),
        };

        return held.formatter.format(&markup_input, out);
    }
};

const PythonFormatter = struct {
    formatter: python.Formatter,
    lines: LineIndex,
    pragmas: Pragmas,

    fn init(
        gpa: std.mem.Allocator,
        capacity: *const Formatters.Capacity,
    ) std.mem.Allocator.Error!PythonFormatter {
        assert(capacity.line_count_max > 0);
        assert(capacity.pragma_count_max > 0);

        var formatter: python.Formatter = try .init(
            gpa,
            capacity.element_count_max,
            capacity.arena_bytes_max,
        );

        errdefer formatter.deinit(gpa);

        var lines: LineIndex = try .init(gpa, capacity.line_count_max);
        errdefer lines.deinit(gpa);

        const pragmas: Pragmas = try .init(gpa, capacity.pragma_count_max);
        return .{ .formatter = formatter, .lines = lines, .pragmas = pragmas };
    }

    fn deinit(held: *PythonFormatter, gpa: std.mem.Allocator) void {
        assert(held.pragmas.items.count() <= held.pragmas.items.capacity());

        held.pragmas.deinit(gpa);
        held.lines.deinit(gpa);
        held.formatter.deinit(gpa);
        held.* = undefined;
    }

    fn format(
        held: *PythonFormatter,
        front: *const Front,
        source: []const u8,
        options: *const Formatters.Options,
        out: *Buffer,
    ) Formatters.Error!void {
        assert(front.language == .python);
        assert(source.len <= std.math.maxInt(u32));

        const syntax = syntax_of(front, python.Kind).?;
        const tokens = syntax.tokens;

        held.lines.build(source) catch |err| switch (err) {
            error.Truncated => return error.LinesExhausted,
        };

        held.pragmas.scan(source, tokens, &held.lines) catch |err| switch (err) {
            error.Overflow => return error.PragmasExhausted,
        };

        const detected = style.detect(source, tokens);

        const python_input: python.Input = .{
            .line_ending = options.line_ending orelse detected.line_ending,
            .magic_trailing_comma = options.magic_trailing_comma,
            .options = options.printed(),
            .outcome = front.outcome.?,
            .pragmas = held.pragmas.const_slice(),
            .quote = options.quote,
            .raw = syntax.kinds,
            .source = source,
            .stub = front.flavor == .stub,
            .tokens = tokens,
            .tree = syntax.tree,
        };

        assert(python_input.raw.len == python_input.tokens.len);

        return held.formatter.format(&python_input, out);
    }
};

fn format_brace(
    comptime Module: type,
    formatter: *Module.Formatter,
    front: *const Front,
    source: []const u8,
    options: *const Formatters.Options,
    out: *Buffer,
) FormatterError!void {
    comptime assert(@hasDecl(Module, "Input"));
    comptime assert(@hasDecl(Module, "Kind"));
    assert(source.len <= std.math.maxInt(u32));

    const syntax = syntax_of(front, Module.Kind).?;

    const module_input: Module.Input = .{
        .options = options.printed(),
        .outcome = front.outcome.?,
        .raw = syntax.kinds,
        .source = source,
        .tokens = syntax.tokens,
        .tree = syntax.tree,
    };

    assert(module_input.raw.len == module_input.tokens.len);

    return formatter.format(&module_input, out);
}

fn format_typescript(
    formatter: *typescript.Formatter,
    front: *const Front,
    source: []const u8,
    options: *const Formatters.Options,
    out: *Buffer,
) FormatterError!void {
    assert(source.len <= std.math.maxInt(u32));

    const syntax = syntax_of(front, typescript.Kind).?;

    const typescript_input: typescript.Input = .{
        .options = options.printed(),
        .outcome = front.outcome.?,
        .raw = syntax.kinds,
        .source = source,
        .tokens = syntax.tokens,
        .tree = syntax.tree,
        .tsx = front.flavor == .tsx,
    };

    assert(typescript_input.raw.len == typescript_input.tokens.len);

    return formatter.format(&typescript_input, out);
}

const capacity_test: Formatters.Capacity = .{
    .arena_bytes_max = 1 << 14,
    .element_count_max = 1 << 12,
    .front = front_capacity_test,
    .line_count_max = 1 << 8,
    .pragma_count_max = 1 << 4,
};

const front_capacity_test: Front.Capacity = .{
    .diagnostic_count_max = 1 << 6,
    .event_count_max = 1 << 12,
    .node_count_max = 1 << 10,
    .semantic = null,
    .tag_count_max = 1 << 6,
    .token_count_max = 1 << 10,
};

const options_test: Formatters.Options = .{
    .vocabulary = .{
        .dialect = .html,
        .end_prefix = "end",
        .extends_tags = &.{},
        .intermediate_words = &.{"else"},
        .only_word = null,
        .raw_text_tags = &.{},
        .specifications = &.{.{ .intermediates = &.{"else"}, .name = "if" }},
        .template_imports = &.{},
    },
};

const TestFormatted = struct {
    formatters: Formatters,
    out: Buffer,

    fn init(held: *TestFormatted, reserved: std.EnumSet(Language)) !void {
        const gpa = std.testing.allocator;

        assert(reserved.count() > 0);

        try held.formatters.init(gpa, &capacity_test, reserved, &options_test);
        errdefer held.formatters.deinit(gpa);

        held.out = try .init(gpa, 1 << 12);

        assert(held.out.empty());
    }

    fn deinit(held: *TestFormatted) void {
        const gpa = std.testing.allocator;

        assert(held.out.capacity() == 1 << 12);

        held.out.deinit(gpa);
        held.formatters.deinit(gpa);
        held.* = undefined;
    }

    fn format(held: *TestFormatted, language: Language, source: []const u8) Formatters.Error!void {
        assert(source.len > 0);
        assert(held.formatters.supports(language));

        return held.formatters.format(.of(language), source, &held.out);
    }
};

test Formatters {
    const gpa = std.testing.allocator;
    var formatters: Formatters = undefined;

    try formatters.init(gpa, &capacity_test, .initOne(.zig), &.{});
    defer formatters.deinit(gpa);

    var out: Buffer = try .init(gpa, 1 << 10);
    defer out.deinit(gpa);

    try formatters.format(.of(.zig), "const  answer=42;\n", &out);

    try std.testing.expectEqualStrings("const answer = 42;\n", out.const_slice());

    const refused = formatters.format(.of(.zig), "const = ;\n", &out);

    try std.testing.expectError(error.SourceInvalid, refused);
}

test "a markup front formats through the table" {
    var held: TestFormatted = undefined;

    try held.init(.initMany(&.{ .markup, .python }));
    defer held.deinit();

    try held.format(.markup, "{% if a %}\n<p>b</p>\n{% endif %}\n");

    const wanted = "{% if a %}\n    <p>b</p>\n{% endif %}\n";

    try std.testing.expectEqualStrings(wanted, held.out.const_slice());
}

test "a source formats in one call" {
    var held: TestFormatted = undefined;

    try held.init(.initMany(&.{ .markup, .python }));
    defer held.deinit();

    try held.format(.python, "x  =  1\n");

    try std.testing.expectEqualStrings("x = 1\n", held.out.const_slice());
}

test "the formatters report the languages they reserved" {
    var held: TestFormatted = undefined;

    try held.init(.initOne(.python));
    defer held.deinit();

    const reserved = held.formatters.languages();

    try std.testing.expect(reserved.contains(.python));
    try std.testing.expect(!reserved.contains(.markup));
    try std.testing.expectEqual(1, reserved.count());
}

test "a python source past its pragma table is a capacity error" {
    var held: TestFormatted = undefined;

    try held.init(.initOne(.python));
    defer held.deinit();

    const line = "x = 1  # type: ignore\n";
    const repeated: [capacity_test.pragma_count_max + 1][line.len]u8 = @splat(line.*);
    const source: []const u8 = std.mem.asBytes(&repeated);

    try std.testing.expectError(error.PragmasExhausted, held.format(.python, source));
}

test "a source past the front's token table is the front's capacity error" {
    var held: TestFormatted = undefined;

    try held.init(.initOne(.python));
    defer held.deinit();

    const line = "x\n";
    const repeated: [front_capacity_test.token_count_max][line.len]u8 = @splat(line.*);
    const source: []const u8 = std.mem.asBytes(&repeated);

    try std.testing.expectError(error.TokensExhausted, held.format(.python, source));
    try std.testing.expect(held.out.empty());
}

test "a markup source past the line table is a capacity error" {
    var held: TestFormatted = undefined;

    try held.init(.initOne(.markup));
    defer held.deinit();

    const line = "a\n";
    const repeated: [capacity_test.line_count_max + 1][line.len]u8 = @splat(line.*);
    const source: []const u8 = std.mem.asBytes(&repeated);

    try std.testing.expectError(error.LinesExhausted, held.format(.markup, source));
}

test "a formatted source larger than the output buffer is a capacity error" {
    const gpa = std.testing.allocator;
    var formatters: Formatters = undefined;

    try formatters.init(gpa, &capacity_test, .initOne(.zig), &.{});
    defer formatters.deinit(gpa);

    var out: Buffer = try .init(gpa, 4);
    defer out.deinit(gpa);

    const formatted = formatters.format(.of(.zig), "const answer = 42;\n", &out);

    try std.testing.expectError(error.OutputExhausted, formatted);
}

test "a markup front with errors is refused" {
    var held: TestFormatted = undefined;

    try held.init(.initMany(&.{ .markup, .python }));
    defer held.deinit();

    try std.testing.expectError(error.SourceInvalid, held.format(.markup, "<p><span>a</p>\n"));
}
