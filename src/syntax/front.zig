const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const binding_module = @import("binding.zig");
const Category = @import("category.zig").Category;
const CheckError = @import("python/check.zig").CheckError;
const Dialect = @import("javascript/dialect.zig").Dialect;
const Goal = @import("javascript/dialect.zig").Goal;
const EventsType = @import("tree.zig").EventsType;
const Facts = @import("fact.zig").Facts;
const fact_module = @import("fact.zig");
const IndexType = @import("tree.zig").IndexType;
const Language = @import("language.zig").Language;
const stdlib = @import("python/stdlib.zig");
const Span = @import("../stdx/bounded/span.zig");
const StaticAllocator = @import("../stdx/static_allocator.zig");
const Structure = @import("tree.zig").Structure;
const SourceType = @import("language.zig").SourceType;
const diagnostic_module = @import("diagnostic.zig");
const Token = @import("token.zig");
const Tokens = @import("tokens.zig");
const TreeType = @import("tree.zig").TreeType;
const View = @import("view.zig").View;
const check = @import("python/check.zig").check;
const child_count_max = @import("view.zig").child_count_max;
const css = @import("grammars.zig").css;
const go = @import("grammars.zig").go;
const javascript = @import("grammars.zig").javascript;
const javascript_relex = @import("javascript/relex.zig");
const lex_into = @import("raw.zig").lex_into;
const markup_facts = @import("markup/facts.zig");
const markup_module = @import("markup.zig");
const odin = @import("grammars.zig").odin;
const python = @import("grammars.zig").python;
const reference_count_max = @import("semantic.zig").reference_count_max;
const rust = @import("grammars.zig").rust;
const zig = @import("grammars.zig").zig;

pub const Front = struct {
    builds: u32,
    flavor: SourceType.Flavor,
    language: Language,
    outcome: ?Structure,
    source: []const u8,
    tables: Tables,

    pub const CapacityError = error{
        BindingsExhausted,
        ChecksExhausted,
        DepthExceeded,
        DiagnosticsExhausted,
        EventsExhausted,
        FactsExhausted,
        IntermediatesExhausted,
        NodesExhausted,
        ReferencesExhausted,
        ScopesExhausted,
        TagsExhausted,
        TokensExhausted,
    };

    pub const Error = CapacityError;
    pub const Bindings = binding_module.Bindings;
    pub const Diagnostic = diagnostic_module.Diagnostic;
    pub const Fact = fact_module.Fact;
    pub const Outcome = Structure;

    pub const Capacity = struct {
        diagnostic_count_max: u32,
        event_count_max: u32,
        node_count_max: u32,
        semantic: ?Semantic,
        tag_count_max: u32,
        token_count_max: u32,

        pub const Semantic = struct {
            binding_count_max: u32,
            fact_count_max: u32,
            reference_count_max: u32,
            scope_count_max: u32,
        };
    };

    pub const Options = struct {
        globals: []const []const u8 = &.{},
        javascript_goal: Goal = .module,
        python_version: PythonVersion = .py310,
        vocabulary: markup_module.Vocabulary = .empty,

        pub const PythonVersion = stdlib.PythonVersion;
    };

    pub const Scratch = struct {
        css: ?*ParseType(css),
        go: ?*ParseType(go),
        javascript: ?*ParseType(javascript),
        odin: ?*ParseType(odin),
        python: ?*ParseType(python),
        python_annotation: ?*PythonAnnotation,
        python_names: ?*PythonNames,
        rust: ?*ParseType(rust),
        zig: ?*ParseType(zig),

        const field_names = @typeInfo(Scratch).@"struct".field_names;
        const field_types = @typeInfo(Scratch).@"struct".field_types;

        pub fn init(
            scratch: *Scratch,
            gpa: std.mem.Allocator,
            capacity: *const Capacity,
            languages: std.EnumSet(Language),
        ) std.mem.Allocator.Error!void {
            assert(capacity.event_count_max > 0);
            assert(languages.count() > 0);

            inline for (field_names) |name| @field(scratch, name) = null;
            errdefer scratch.deinit(gpa);

            inline for (field_names, field_types) |name, Field| {
                if (wants(capacity, languages, name)) {
                    const held = try StaticAllocator.create(HeldType(Field), gpa);
                    errdefer StaticAllocator.destroy(HeldType(Field), gpa, held);

                    try held.init(gpa, capacity);

                    @field(scratch, name) = held;
                }
            }

            inline for (field_names) |name| {
                assert(wants(capacity, languages, name) == (@field(scratch, name) != null));
            }
        }

        pub fn deinit(scratch: *Scratch, gpa: std.mem.Allocator) void {
            inline for (field_names) |name| {
                if (@field(scratch, name)) |held| {
                    held.deinit(gpa);
                    StaticAllocator.destroy(@TypeOf(held.*), gpa, held);
                }
            }

            scratch.* = undefined;
        }

        fn HeldType(comptime Field: type) type {
            comptime assert(@typeInfo(Field) == .optional);
            comptime assert(@typeInfo(@typeInfo(Field).optional.child) == .pointer);

            return @typeInfo(@typeInfo(Field).optional.child).pointer.child;
        }

        fn wants(
            capacity: *const Capacity,
            languages: std.EnumSet(Language),
            comptime name: []const u8,
        ) bool {
            assert(name.len <= std.math.maxInt(u32));
            if (languages.count() == 0) return false;

            const language = comptime language_of(name);

            comptime assert(@hasField(Scratch, name));

            if (comptime is_semantic(name)) {
                if (capacity.semantic == null) return false;
            }

            if (language == .javascript) {
                return languages.contains(.javascript) or languages.contains(.typescript);
            }

            return languages.contains(language);
        }

        fn is_semantic(comptime name: []const u8) bool {
            comptime assert(@hasField(Scratch, name));

            if (comptime std.mem.eql(u8, name, "python_annotation")) return true;
            if (comptime std.mem.eql(u8, name, "python_names")) return true;
            return false;
        }

        fn language_of(comptime name: []const u8) Language {
            comptime assert(@hasField(Scratch, name));
            comptime assert(name.len > 0);

            if (comptime is_semantic(name)) return .python;
            return @field(Language, name);
        }
    };

    fn capacity_checked(outcome: Structure) Error!void {
        if (outcome == .too_deep) return error.DepthExceeded;

        return switch (outcome) {
            .complete => {},
            .too_deep => error.DepthExceeded,
            .truncated => |resource| switch (resource) {
                .bindings => error.BindingsExhausted,
                .checks => error.ChecksExhausted,
                .diagnostics => error.DiagnosticsExhausted,
                .events => error.EventsExhausted,
                .facts => error.FactsExhausted,
                .intermediates => error.IntermediatesExhausted,
                .lines => unreachable,
                .nodes => error.NodesExhausted,
                .references => error.ReferencesExhausted,
                .scopes => error.ScopesExhausted,
                .tags => error.TagsExhausted,
                .tokens => error.TokensExhausted,
            },
        };
    }

    fn complete(front: *const Front) bool {
        const outcome = front.outcome orelse return false;

        if (outcome == .complete) assert(front.builds > 0);

        return outcome == .complete;
    }

    fn markup_tables(front: *const Front) ?*const MarkupTables {
        switch (front.tables) {
            .markup => |*tables| {
                assert(front.language == .markup);
                assert(tables.document.tokens().len <= tables.document.lexed.capacity());

                return tables;
            },
            else => {
                assert(front.language != .markup);

                return null;
            },
        }
    }

    fn resolved(front: *const Front) bool {
        assert(front.tables_match());

        return switch (front.tables) {
            .markup => |*tables| tables.facts != null,
            inline else => |*tables| tables.semantic != null,
        };
    }

    fn tables_match(front: *const Front) bool {
        return std.mem.eql(u8, @tagName(front.tables), @tagName(front.language));
    }

    fn view_before(front: *const Front, node: u32, offset: u32) bool {
        assert(node < std.math.maxInt(u32));

        const held = front.view(node) orelse return false;

        assert(held.index() == node);

        assert(node < front.node_count());

        return held.span().offset < offset;
    }

    fn view_partition(front: *const Front, positions: []const u32, offset: u32) usize {
        assert(positions.len <= std.math.maxInt(u32));
        assert(offset < std.math.maxInt(u32));

        var size = positions.len;
        var base: usize = 0;

        if (size == 0) return 0;

        for (0..64) |_| {
            if (size <= 1) break;

            const half = size / 2;
            const middle = base + half;

            if (front.view_before(positions[middle], offset)) base = middle;

            size -= half;
        }

        assert(size == 1);
        assert(base < positions.len);

        return base + @intFromBool(front.view_before(positions[base], offset));
    }

    pub fn init(
        front: *Front,
        gpa: std.mem.Allocator,
        capacity: *const Capacity,
        language: Language,
    ) std.mem.Allocator.Error!void {
        assert(capacity.node_count_max > 0);
        assert(capacity.node_count_max <= child_count_max);
        assert(capacity.token_count_max > 0);

        if (capacity.semantic) |semantic| {
            assert(semantic.reference_count_max <= reference_count_max);
        }

        front.builds = 0;
        front.flavor = .plain;
        front.language = language;
        front.outcome = null;
        front.source = &.{};

        switch (language) {
            inline else => |tag| {
                front.tables = @unionInit(Tables, @tagName(tag), undefined);

                try @field(front.tables, @tagName(tag)).init(gpa, capacity);
            },
        }

        assert(front.node_count() == 0);
        assert(std.mem.eql(u8, @tagName(front.tables), @tagName(language)));
    }

    pub fn deinit(front: *Front, gpa: std.mem.Allocator) void {
        if (front.outcome != null) assert(front.builds > 0);
        assert(std.mem.eql(u8, @tagName(front.tables), @tagName(front.language)));

        switch (front.tables) {
            inline else => |*held| held.deinit(gpa),
        }

        front.* = undefined;
    }

    pub fn parse(
        front: *Front,
        scratch: *Scratch,
        source_type: SourceType,
        source: []const u8,
        options: *const Options,
    ) Error!void {
        assert(source_type.language == front.language);
        assert(source_type.valid());
        assert(source.len <= std.math.maxInt(u32));

        front.builds +%= 1;

        front.tables.clear();
        front.flavor = source_type.flavor;
        front.source = source;

        const outcome: Structure = switch (front.tables) {
            .css => |*held| build_css(source, held, scratch),
            .markup => |*held| build_markup(source, held, options),
            .go => |*held| build_go(source, held, scratch, options.globals),
            .javascript => |*held| build_javascript(source, held, scratch, &.{
                .dialect = .javascript,
                .globals = options.globals,
                .goal = options.javascript_goal,
            }),
            .typescript => |*held| build_javascript(source, held, scratch, &.{
                .dialect = if (front.flavor == .tsx) .tsx else .typescript,
                .globals = options.globals,
                .goal = options.javascript_goal,
            }),
            .odin => |*held| build_odin(source, held, scratch, options.globals),
            .python => |*held| build_python(source, held, scratch, options),
            .rust => |*held| build_rust(source, held, scratch, options.globals),
            .zig => |*held| build_zig(source, held, scratch, options.globals),
        };

        front.outcome = outcome;

        switch (outcome) {
            .complete => front.tables.index_build(),
            .too_deep, .truncated => if (!front.tables.keeps_partial()) front.tables.clear(),
        }

        if (outcome != .complete) assert(front.bindings().count() == 0);

        if (front.markup_tables()) |held| {
            if (held.lex == .truncated) assert(outcome == .truncated);
        }

        return capacity_checked(outcome);
    }

    pub fn bindings(front: *const Front) Bindings {
        if (!front.complete()) return .empty;
        if (!front.resolved()) return .empty;

        const held: Bindings = switch (front.tables) {
            .css, .markup => .empty,
            .go => |*tables| .{ .go = &tables.semantic.? },
            .javascript => |*tables| .{ .javascript = &tables.semantic.? },
            .typescript => |*tables| .{ .javascript = &tables.semantic.? },
            .odin => |*tables| .{ .odin = &tables.semantic.? },
            .python => |*tables| .{ .python = &tables.semantic.? },
            .rust => |*tables| .{ .rust = &tables.semantic.? },
            .zig => |*tables| .{ .zig = &tables.semantic.? },
        };

        const unbound = switch (front.tables) {
            .css, .markup => true,
            else => false,
        };

        assert((held == .empty) == unbound);
        assert(front.complete());

        return held;
    }

    pub fn clear(front: *Front) void {
        front.builds +%= 1;
        front.outcome = null;
        front.source = &.{};

        front.tables.clear();

        assert(front.node_count() == 0);
        assert(front.facts().len == 0);
    }

    pub fn node_count(front: *const Front) u32 {
        assert(front.tables_match());

        if (front.markup_tables()) |tables| return tables.document.node_count();

        const counted = front.tables.count();

        if (!front.complete()) assert(counted == 0);

        return counted;
    }

    pub fn declaration_of(front: *const Front, name: []const u8) ?u32 {
        const source = front.source;

        assert(name.len > 0);
        assert(source.len <= std.math.maxInt(u32));

        if (front.tables == .markup) return null;
        if (!front.resolved()) return null;

        if (front.tables == .css) {
            return declared_of_css(&front.tables.css.semantic.?, source, name);
        }

        const held = front.bindings();
        var found: ?u32 = null;

        for (0..held.count()) |index| {
            const binding = held.at(@intCast(index));
            if (binding.scope != 0) continue;
            if (binding.name.length == 0) continue;
            if (!std.mem.eql(u8, binding.name.text(source), name)) continue;

            found = binding.node;
        }

        if (found) |node| assert(node < front.node_count());

        return found;
    }

    pub fn diagnostic_write(
        front: *const Front,
        diagnostic: Diagnostic,
        out: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        assert(diagnostic.span.end() <= front.source.len);
        assert(front.tables != .markup);

        return diagnostic.message_write(out, .{
            .expected = if (diagnostic.expected) |code| front.kind_name(code) else null,
            .found = if (diagnostic.found) |code| front.kind_name(code) else null,
        });
    }

    pub fn diagnostics(front: *const Front) []const Diagnostic {
        assert(front.tables_match());

        if (front.tables == .markup) return &.{};

        const held = front.tables.diagnostics();

        if (!front.complete()) assert(front.node_count() == 0);

        return held;
    }

    pub fn facts(front: *const Front) []const Fact {
        if (!front.resolved()) return &.{};
        if (front.markup_tables()) |tables| return tables.facts.?.slice();

        const held = switch (front.tables) {
            .css => |*tables| tables.semantic.?.fact_slice(),
            .markup => unreachable,
            .go => |*tables| tables.semantic.?.fact_slice(),
            .javascript => |*tables| tables.semantic.?.fact_slice(),
            .typescript => |*tables| tables.semantic.?.fact_slice(),
            .odin => |*tables| tables.semantic.?.fact_slice(),
            .python => |*tables| tables.semantic.?.fact_slice(),
            .rust => |*tables| tables.semantic.?.fact_slice(),
            .zig => |*tables| tables.semantic.?.fact_slice(),
        };

        if (!front.complete()) assert(held.len == 0);
        if (held.len > 0) assert(front.bindings().scope_count() > 0 or front.tables == .css);

        return held;
    }

    pub fn function_at(front: *const Front, offset: u32) ?View {
        if (front.tables == .markup) return null;
        if (offset >= front.source.len) return null;

        var found: ?View = null;

        for ([_]Category{ .function, .lambda }) |category| {
            for (front.nodes_of(category)) |position| {
                const held = front.view(position) orelse continue;
                const span = held.span();
                if (span.offset > offset) continue;
                if (span.end() <= offset) continue;

                if (found) |inner| {
                    if (inner.span().offset > span.offset) continue;
                }

                found = held;
            }
        }

        if (found) |held| assert(held.span().contains(offset));
        if (front.tables == .css) assert(found == null);

        return found;
    }

    pub fn has_diagnostics(front: *const Front) bool {
        if (front.tables == .markup) assert(front.diagnostics().len == 0);
        if (front.diagnostics().len > 0) return true;

        const held = front.markup() orelse return false;
        return held.diagnostics().len > 0;
    }

    pub fn nodes_of(front: *const Front, category: Category) []const u32 {
        assert(category != .other);

        const held = switch (front.tables) {
            .markup => return &.{},
            inline else => |*tables| tables.syntax.index.of(category),
        };

        if (!front.complete()) assert(held.len == 0);
        assert(held.len <= front.node_count());

        return held;
    }

    fn kind_name(front: *const Front, code: u16) ?[]const u8 {
        assert(front.tables_match());
        assert(code < std.math.maxInt(u16));

        const name: []const u8 = switch (front.tables) {
            .css => css.Kind.of_u16(code).?.name(),
            .go => go.Kind.of_u16(code).?.name(),
            .javascript, .typescript => javascript.Kind.of_u16(code).?.name(),
            .markup => return null,
            .odin => odin.Kind.of_u16(code).?.name(),
            .python => python.Kind.of_u16(code).?.name(),
            .rust => rust.Kind.of_u16(code).?.name(),
            .zig => zig.Kind.of_u16(code).?.name(),
        };

        assert(name.len > 0);

        return name;
    }

    pub fn markup(front: *const Front) ?*const markup_module.Document {
        const tables = front.markup_tables() orelse return null;

        if (front.outcome == null) assert(tables.document.node_count() == 0);

        return &tables.document;
    }

    pub fn root(front: *const Front) ?View {
        if (front.node_count() == 0) return null;

        const held = front.view(0) orelse return null;

        assert(held.index() == 0);
        assert(held.parent() == null);

        return held;
    }

    pub fn tokens(front: *const Front) []const Token {
        assert(front.tables_match());

        if (front.tables == .markup) return &.{};

        const held = front.tables.tokens();

        if (!front.complete()) assert(front.node_count() == 0);

        return held;
    }

    pub fn root_as(front: *const Front, comptime T: type) T {
        const held = front.view_as(T, 0);

        assert(held.node == 0);

        return held;
    }

    pub fn view_as(front: *const Front, comptime T: type, node: u32) T {
        const Kind = comptime ViewKindType(T);

        assert(front.complete());
        assert(node < front.node_count());

        switch (front.tables) {
            .markup => unreachable,
            inline else => |*tables| {
                if (comptime @TypeOf(tables.syntax.raw.const_slice()) != []const Kind) unreachable;

                const held = &tables.syntax;
                return .init(&held.tree, held.tokens.slice(), held.raw.const_slice(), node);
            },
        }
    }

    pub fn view(front: *const Front, node: u32) ?View {
        assert(node < std.math.maxInt(u32));

        if (front.markup_tables()) |tables| {
            assert(node < tables.document.node_count());

            return null;
        }

        assert(front.complete());

        return front.tables.view(node);
    }

    pub fn view_at(front: *const Front, category: Category, offset: u32) ?View {
        assert(offset < std.math.maxInt(u32));
        assert(category != .other);

        const positions = front.nodes_of(category);
        const first = front.view_partition(positions, offset);

        assert(first <= positions.len);

        if (first == positions.len) return null;

        const held = front.view(positions[first]) orelse return null;
        if (held.span().offset != offset) return null;

        assert(held.category() == category);

        return held;
    }
};

fn ViewKindType(comptime T: type) type {
    inline for (.{ css, go, javascript, odin, python, rust, zig }) |grammar| {
        if (T == grammar.ast.View) return grammar.Kind;
    }

    @compileError("Front.view_as takes a grammar view such as scylla.python.View, not " ++
        @typeName(T));
}

pub fn SyntaxType(comptime Kind: type) type {
    return struct {
        kinds: []const Kind,
        tokens: []const Token,
        tree: *const TreeType(Kind),
    };
}

pub fn capacity_shrunk(capacity: *const Front.Capacity, shift: u32) Front.Capacity {
    assert(shift < 32);

    const semantic: ?Front.Capacity.Semantic = if (capacity.semantic) |held| .{
        .binding_count_max = count_shrunk(held.binding_count_max, shift),
        .fact_count_max = count_shrunk(held.fact_count_max, shift),
        .reference_count_max = count_shrunk(held.reference_count_max, shift),
        .scope_count_max = count_shrunk(held.scope_count_max, shift),
    } else null;

    const result: Front.Capacity = .{
        .diagnostic_count_max = count_shrunk(capacity.diagnostic_count_max, shift),
        .event_count_max = count_shrunk(capacity.event_count_max, shift),
        .node_count_max = count_shrunk(capacity.node_count_max, shift),
        .semantic = semantic,
        .tag_count_max = count_shrunk(capacity.tag_count_max, shift),
        .token_count_max = count_shrunk(capacity.token_count_max, shift),
    };

    assert(result.node_count_max <= @max(capacity.node_count_max, 1));
    assert((result.semantic == null) == (capacity.semantic == null));

    return result;
}

pub fn count_shrunk(count_max: u32, shift: u32) u32 {
    assert(shift < 32);
    assert(count_max < std.math.maxInt(u32));

    const held = @max(count_max >> @as(u5, @intCast(shift)), 1);

    assert(held >= 1);
    assert(held <= @max(count_max, 1));

    return held;
}

pub fn css_semantic_of(front: *const Front) ?*const css.Semantic {
    assert(front.tables_match());

    return switch (front.tables) {
        .css => |*tables| if (tables.semantic) |*semantic| semantic else null,
        else => null,
    };
}

pub fn python_checks_of(front: *const Front) []const CheckError {
    const held: []const CheckError = switch (front.tables) {
        .python => |*tables| tables.checks.const_slice(),
        else => &.{},
    };

    if (!front.complete()) assert(held.len == 0);
    if (front.tables != .python) assert(held.len == 0);

    return held;
}

pub fn syntax_of(front: *const Front, comptime Kind: type) ?SyntaxType(Kind) {
    assert(front.tables_match());

    switch (front.tables) {
        .markup => return null,
        inline else => |*tables| {
            if (comptime @TypeOf(tables.syntax.raw.const_slice()) != []const Kind) return null;

            assert(tables.syntax.raw.count() == tables.syntax.tokens.count());

            return .{
                .kinds = tables.syntax.raw.const_slice(),
                .tokens = tables.syntax.tokens.slice(),
                .tree = &tables.syntax.tree,
            };
        },
    }
}

const Tables = union(enum) {
    css: TablesType(css),
    go: TablesType(go),
    javascript: TablesType(javascript),
    markup: MarkupTables,
    odin: TablesType(odin),
    python: PythonTables,
    rust: TablesType(rust),
    typescript: TablesType(javascript),
    zig: TablesType(zig),

    fn clear(tables: *Tables) void {
        switch (tables.*) {
            inline else => |*held| held.clear(),
        }

        assert(tables.count() == 0);
    }

    fn count(tables: *const Tables) u32 {
        switch (tables.*) {
            .markup => |*held| return held.document.node_count(),
            inline else => |*held| {
                const node_count = held.syntax.tree.count();

                assert(node_count <= held.syntax.tree.nodes.capacity());
                assert(held.syntax.index.count() <= node_count);

                return node_count;
            },
        }
    }

    fn diagnostics(tables: *const Tables) []const Front.Diagnostic {
        switch (tables.*) {
            .markup => return &.{},
            inline else => |*held| {
                const found = held.syntax.tree.diagnostic_slice();

                assert(found.len <= held.syntax.tree.diagnostics.capacity());
                assert(held.syntax.tokens.count() == held.syntax.raw.count());

                return found;
            },
        }
    }

    fn index_build(tables: *Tables) void {
        switch (tables.*) {
            .markup => {},
            inline else => |*held| held.syntax.index_build(),
        }

        if (tables.* != .markup) assert(!tables.keeps_partial());
    }

    fn keeps_partial(tables: *const Tables) bool {
        const result = switch (tables.*) {
            .css => false,
            .go => false,
            .javascript => false,
            .markup => true,
            .odin => false,
            .python => false,
            .rust => false,
            .typescript => false,
            .zig => false,
        };

        if (tables.* == .zig) assert(!result);
        if (tables.* == .markup) assert(result);

        return result;
    }

    fn tokens(tables: *const Tables) []const Token {
        switch (tables.*) {
            .markup => return &.{},
            inline else => |*held| {
                const found = held.syntax.tokens.slice();

                assert(found.len == held.syntax.raw.count());
                assert(found.len <= held.syntax.raw.capacity());

                return found;
            },
        }
    }

    fn view(tables: *const Tables, node: u32) ?View {
        assert(node < std.math.maxInt(u32));

        switch (tables.*) {
            .markup => return null,
            inline else => |*held, tag| {
                const name = comptime view_name_of(@tagName(tag));
                if (comptime !@hasField(View, name)) return null;

                const syntax = &held.syntax;

                assert(node < syntax.tree.count());
                assert(syntax.tokens.count() == syntax.raw.count());

                return @unionInit(View, name, .init(
                    &syntax.tree,
                    syntax.tokens.slice(),
                    syntax.raw.const_slice(),
                    node,
                ));
            },
        }
    }

    fn view_name_of(comptime name: []const u8) []const u8 {
        comptime assert(name.len > 0);
        comptime assert(@hasField(Tables, name));

        if (comptime std.mem.eql(u8, name, "typescript")) return "javascript";
        return name;
    }
};

const Lex = enum {
    complete,
    truncated,
};

const MarkupTables = struct {
    document: markup_module.Document,
    facts: ?Facts,
    lex: Lex,

    fn init(
        tables: *MarkupTables,
        gpa: std.mem.Allocator,
        capacity: *const Front.Capacity,
    ) std.mem.Allocator.Error!void {
        assert(capacity.tag_count_max > 0);
        assert(capacity.token_count_max > 0);

        tables.document = try .init(gpa, .{
            .diagnostic_count_max = capacity.diagnostic_count_max,
            .node_count_max = capacity.node_count_max,
            .tag_count_max = capacity.tag_count_max,
            .token_count_max = capacity.token_count_max,
        });

        errdefer tables.document.deinit(gpa);

        tables.facts = if (capacity.semantic) |semantic|
            try .init(gpa, semantic.fact_count_max)
        else
            null;

        tables.lex = .complete;

        assert(tables.document.node_count() == 0);
        assert(tables.document.tokens().len == 0);
    }

    fn deinit(tables: *MarkupTables, gpa: std.mem.Allocator) void {
        if (tables.lex == .truncated) assert(tables.document.tokens().len > 0);
        if (tables.facts) |*facts| assert(facts.count() <= tables.document.node_count());

        if (tables.facts) |*facts| facts.deinit(gpa);
        tables.document.deinit(gpa);
        tables.* = undefined;
    }

    fn clear(tables: *MarkupTables) void {
        tables.document.clear();
        if (tables.facts) |*facts| facts.clear();
        tables.lex = .complete;

        assert(tables.document.node_count() == 0);
        assert(tables.document.tokens().len == 0);
    }
};

fn build_markup(
    source: []const u8,
    tables: *MarkupTables,
    options: *const Front.Options,
) Structure {
    const vocabulary = &options.vocabulary;
    const document = &tables.document;

    assert(source.len <= std.math.maxInt(u32));
    assert(document.tokens().len == 0);

    const outcome: Structure = if (document.parse(source, vocabulary)) |_|
        .complete
    else |err| switch (err) {
        error.BlockDepthExceeded, error.DepthExceeded => .too_deep,
        error.DiagnosticsExhausted => .{ .truncated = .diagnostics },
        error.IntermediatesExhausted => .{ .truncated = .intermediates },
        error.NodesExhausted => .{ .truncated = .nodes },
        error.TagsExhausted => .{ .truncated = .tags },
        error.TokensExhausted => .{ .truncated = .tokens },
    };

    tables.lex = switch (outcome) {
        .complete, .too_deep => .complete,
        .truncated => |resource| if (resource == .tokens) .truncated else .complete,
    };

    if (outcome != .complete) return outcome;

    const facts = if (tables.facts) |*held| held else return .complete;

    const gathered = markup_facts.build(source, document.tokens(), document.tree(), facts, &.{
        .extends = vocabulary.extends_tags,
        .names = vocabulary.template_imports,
        .only_word = vocabulary.only_word,
    });

    assert(facts.count() <= document.node_count());

    return gathered;
}

fn declared_of_css(semantic: *const css.Semantic, source: []const u8, name: []const u8) ?u32 {
    assert(source.len <= std.math.maxInt(u32));

    var found: ?u32 = null;

    assert(name.len > 0);

    for (semantic.definition_slice()) |definition| {
        if (definition.name.length == 0) continue;
        if (!std.mem.eql(u8, definition.name.text(source), name)) continue;

        found = definition.node;
    }

    if (found) |node| assert(node < std.math.maxInt(u32));

    return found;
}

fn ParseType(comptime Module: type) type {
    comptime assert(@hasDecl(Module, "Kind"));
    comptime assert(@hasDecl(Module, "Parser"));

    return struct {
        events: EventsType(Module.Kind),
        parser: Module.Parser,

        const Parse = @This();

        fn init(
            held: *Parse,
            gpa: std.mem.Allocator,
            capacity: *const Front.Capacity,
        ) std.mem.Allocator.Error!void {
            assert(capacity.event_count_max > 0);

            try held.events.init(gpa, capacity.event_count_max);

            assert(held.events.count() == 0);
        }

        fn deinit(held: *Parse, gpa: std.mem.Allocator) void {
            assert(held.events.count() <= held.events.items.capacity());

            held.events.deinit(gpa);
        }
    };
}

const PythonAnnotation = struct {
    scratch: python.AnnotationScratch,

    fn init(
        held: *PythonAnnotation,
        gpa: std.mem.Allocator,
        capacity: *const Front.Capacity,
    ) std.mem.Allocator.Error!void {
        assert(capacity.event_count_max > 0);

        try held.scratch.init(gpa, &.{
            .node_count_max = annotation_node_count_max,
            .token_count_max = annotation_token_count_max,
        });

        assert(held.scratch.tree.count() == 0);
    }

    fn deinit(held: *PythonAnnotation, gpa: std.mem.Allocator) void {
        assert(held.scratch.tree.nodes.capacity() == annotation_node_count_max);

        held.scratch.deinit(gpa);
    }
};

const PythonNames = struct {
    spans: ArrayType(Span),

    fn init(
        held: *PythonNames,
        gpa: std.mem.Allocator,
        capacity: *const Front.Capacity,
    ) std.mem.Allocator.Error!void {
        const semantic = capacity.semantic.?;

        assert(semantic.binding_count_max > 0);

        held.spans = try .init(gpa, semantic.binding_count_max);

        assert(held.spans.empty());
    }

    fn deinit(held: *PythonNames, gpa: std.mem.Allocator) void {
        assert(held.spans.count() <= held.spans.capacity());

        held.spans.deinit(gpa);
    }
};

const PythonTables = struct {
    checks: ArrayType(CheckError),
    semantic: ?python.Semantic,
    syntax: SyntaxTablesType(python.Kind),

    fn init(
        tables: *PythonTables,
        gpa: std.mem.Allocator,
        capacity: *const Front.Capacity,
    ) std.mem.Allocator.Error!void {
        tables.checks = try .init(gpa, python.check.error_count_max_default);
        errdefer tables.checks.deinit(gpa);

        tables.semantic = if (capacity.semantic) |*semantic|
            try semantic_reserved(python.Semantic, gpa, semantic)
        else
            null;

        errdefer if (tables.semantic) |*semantic| semantic.deinit(gpa);

        try tables.syntax.init(gpa, capacity);

        assert(tables.checks.empty());
    }

    fn deinit(tables: *PythonTables, gpa: std.mem.Allocator) void {
        assert(tables.checks.count() <= tables.checks.capacity());

        tables.syntax.deinit(gpa);
        if (tables.semantic) |*semantic| semantic.deinit(gpa);
        tables.checks.deinit(gpa);
        tables.* = undefined;
    }

    fn clear(tables: *PythonTables) void {
        tables.checks.clear();
        if (tables.semantic) |*semantic| semantic.clear();
        tables.syntax.clear();

        assert(tables.checks.empty());
        assert(tables.syntax.tree.count() == 0);
    }
};

fn SyntaxTablesType(comptime Kind: type) type {
    return struct {
        index: IndexType(Kind),
        raw: ArrayType(Kind),
        tokens: Tokens,
        tree: TreeType(Kind),

        const Syntax = @This();

        fn init(syntax: *Syntax, gpa: std.mem.Allocator, capacity: *const Front.Capacity) !void {
            syntax.index = try .init(gpa, capacity.node_count_max);
            errdefer syntax.index.deinit(gpa);

            syntax.raw = try .init(gpa, capacity.token_count_max);
            errdefer syntax.raw.deinit(gpa);

            syntax.tokens = try .init(gpa, capacity.token_count_max);
            errdefer syntax.tokens.deinit(gpa);

            syntax.tree = try .init(gpa, capacity.node_count_max, capacity.diagnostic_count_max);

            assert(syntax.raw.capacity() == syntax.tokens.items.capacity());
            assert(syntax.tree.count() == 0);
        }

        fn deinit(syntax: *Syntax, gpa: std.mem.Allocator) void {
            assert(syntax.raw.capacity() == syntax.tokens.items.capacity());
            assert(syntax.index.count() <= syntax.tree.count());

            syntax.tree.deinit(gpa);
            syntax.tokens.deinit(gpa);
            syntax.raw.deinit(gpa);
            syntax.index.deinit(gpa);
            syntax.* = undefined;
        }

        fn clear(syntax: *Syntax) void {
            syntax.index.clear();
            syntax.raw.clear();
            syntax.tokens.clear();
            syntax.tree.clear();

            assert(syntax.raw.count() == 0);
            assert(syntax.tree.count() == 0);
        }

        fn index_build(syntax: *Syntax) void {
            syntax.index.build(&syntax.tree);

            assert(syntax.index.count() == syntax.tree.count());
            assert(syntax.tokens.count() == syntax.raw.count());
        }

        fn lex_source(
            syntax: *Syntax,
            source: []const u8,
            source_type: SourceType,
        ) error{Truncated}!void {
            assert(source.len <= std.math.maxInt(u32));
            assert(syntax.tree.count() == 0);
            assert(source_type.valid());

            try lex_into(Kind, source_type, source, &syntax.tokens, &syntax.raw);

            assert(syntax.tokens.count() == syntax.raw.count());
        }
    };
}

fn TablesType(comptime Module: type) type {
    comptime assert(@hasDecl(Module, "Kind"));
    comptime assert(@hasDecl(Module, "Semantic"));

    return struct {
        semantic: ?Module.Semantic,
        syntax: SyntaxTablesType(Module.Kind),

        const LanguageTables = @This();

        fn init(
            tables: *LanguageTables,
            gpa: std.mem.Allocator,
            capacity: *const Front.Capacity,
        ) std.mem.Allocator.Error!void {
            tables.semantic = if (capacity.semantic) |*semantic|
                try semantic_reserved(Module.Semantic, gpa, semantic)
            else
                null;

            errdefer if (tables.semantic) |*semantic| semantic.deinit(gpa);

            try tables.syntax.init(gpa, capacity);

            assert(tables.syntax.tree.count() == 0);
        }

        fn deinit(tables: *LanguageTables, gpa: std.mem.Allocator) void {
            assert(tables.syntax.tree.count() <= tables.syntax.tree.nodes.capacity());

            tables.syntax.deinit(gpa);
            if (tables.semantic) |*semantic| semantic.deinit(gpa);
            tables.* = undefined;
        }

        fn clear(tables: *LanguageTables) void {
            if (tables.semantic) |*semantic| semantic.clear();
            tables.syntax.clear();

            assert(tables.syntax.tree.count() == 0);
        }
    };
}

fn semantic_reserved(
    comptime Semantic: type,
    gpa: std.mem.Allocator,
    capacity: *const Front.Capacity.Semantic,
) error{OutOfMemory}!Semantic {
    var semantic: Semantic = undefined;

    try semantic.init(gpa, &.{
        .binding_count_max = capacity.binding_count_max,
        .fact_count_max = capacity.fact_count_max,
        .reference_count_max = capacity.reference_count_max,
        .scope_count_max = capacity.scope_count_max,
    });

    assert(semantic.count() == 0);

    return semantic;
}

fn build_rust(
    source: []const u8,
    tables: *TablesType(rust),
    scratch: *Front.Scratch,
    globals: []const []const u8,
) Structure {
    assert(source.len <= std.math.maxInt(u32));
    assert(tables.syntax.tree.count() == 0);
    assert(globals.len <= std.math.maxInt(u32));

    const parse = scratch.rust.?;
    const syntax = &tables.syntax;

    syntax.lex_source(source, .of(.rust)) catch return .{ .truncated = .tokens };

    const built = parse.parser.build(
        source,
        syntax.tokens.slice(),
        syntax.raw.const_slice(),
        &parse.events,
        &syntax.tree,
    );

    if (built != .complete) return built;

    const semantic = if (tables.semantic) |*held| held else return .complete;

    return semantic.build(
        source,
        syntax.tokens.slice(),
        syntax.raw.const_slice(),
        &syntax.tree,
        globals,
    );
}

fn build_css(
    source: []const u8,
    tables: *TablesType(css),
    scratch: *Front.Scratch,
) Structure {
    assert(source.len <= std.math.maxInt(u32));
    assert(tables.syntax.tree.count() == 0);

    const parse = scratch.css.?;
    const syntax = &tables.syntax;

    syntax.lex_source(source, .of(.css)) catch return .{ .truncated = .tokens };

    const built = parse.parser.build(
        source,
        syntax.tokens.slice(),
        syntax.raw.const_slice(),
        &parse.events,
        &syntax.tree,
    );

    if (built != .complete) return built;

    const semantic = if (tables.semantic) |*held| held else return .complete;

    return semantic.build(
        source,
        syntax.tokens.slice(),
        syntax.raw.const_slice(),
        &syntax.tree,
    );
}

fn build_go(
    source: []const u8,
    tables: *TablesType(go),
    scratch: *Front.Scratch,
    globals: []const []const u8,
) Structure {
    assert(source.len <= std.math.maxInt(u32));
    assert(tables.syntax.tree.count() == 0);
    assert(globals.len <= std.math.maxInt(u32));

    const parse = scratch.go.?;
    const syntax = &tables.syntax;

    syntax.lex_source(source, .of(.go)) catch return .{ .truncated = .tokens };

    const built = parse.parser.build(
        source,
        syntax.tokens.slice(),
        syntax.raw.const_slice(),
        &parse.events,
        &syntax.tree,
    );

    if (built != .complete) return built;

    const semantic = if (tables.semantic) |*held| held else return .complete;

    return semantic.build(
        source,
        syntax.tokens.slice(),
        syntax.raw.const_slice(),
        &syntax.tree,
        globals,
    );
}

const JavaScriptOptions = struct {
    dialect: Dialect,
    globals: []const []const u8,
    goal: Goal,
};

fn build_javascript(
    source: []const u8,
    tables: *TablesType(javascript),
    scratch: *Front.Scratch,
    options: *const JavaScriptOptions,
) Structure {
    assert(source.len <= std.math.maxInt(u32));
    assert(tables.syntax.tree.count() == 0);

    const parse = scratch.javascript.?;
    const syntax = &tables.syntax;
    const dialect = options.dialect;

    const built = javascript_relex.build(
        &parse.parser,
        source,
        .{ .raw = &syntax.raw, .tokens = &syntax.tokens },
        &parse.events,
        &syntax.tree,
        dialect.grammar(options.goal),
    ) catch return .{ .truncated = .tokens };

    if (built != .complete) return built;

    const semantic = if (tables.semantic) |*held| held else return .complete;

    return semantic.build(
        source,
        syntax.tokens.slice(),
        syntax.raw.const_slice(),
        &syntax.tree,
        &.{ .globals = options.globals, .module = null, .typed = dialect.typed() },
    );
}

fn build_odin(
    source: []const u8,
    tables: *TablesType(odin),
    scratch: *Front.Scratch,
    globals: []const []const u8,
) Structure {
    assert(source.len <= std.math.maxInt(u32));
    assert(tables.syntax.tree.count() == 0);
    assert(globals.len <= std.math.maxInt(u32));

    const parse = scratch.odin.?;
    const syntax = &tables.syntax;

    syntax.lex_source(source, .of(.odin)) catch return .{ .truncated = .tokens };

    const built = parse.parser.build(
        source,
        syntax.tokens.slice(),
        syntax.raw.const_slice(),
        &parse.events,
        &syntax.tree,
    );

    if (built != .complete) return built;

    const semantic = if (tables.semantic) |*held| held else return .complete;

    return semantic.build(
        source,
        syntax.tokens.slice(),
        syntax.raw.const_slice(),
        &syntax.tree,
        globals,
    );
}

fn build_python(
    source: []const u8,
    tables: *PythonTables,
    scratch: *Front.Scratch,
    options: *const Front.Options,
) Structure {
    assert(source.len <= std.math.maxInt(u32));
    assert(tables.syntax.tree.count() == 0);

    const parse = scratch.python.?;
    const syntax = &tables.syntax;
    const parsed = parse_python(source, syntax, parse);
    if (parsed != .complete) return parsed;

    const semantic = if (tables.semantic) |*held| held else return .complete;
    const names = scratch.python_names.?;
    const annotation = scratch.python_annotation.?;

    const model = semantic.build(&.{
        .builtins = options.globals,
        .raw = syntax.raw.const_slice(),
        .source = source,
        .tokens = syntax.tokens.slice(),
        .tree = &syntax.tree,
        .version = options.python_version,
    }, &annotation.scratch);

    if (model != .complete) return model;
    return check_python(source, tables, semantic, &names.spans, options.python_version);
}

fn parse_python(
    source: []const u8,
    syntax: *SyntaxTablesType(python.Kind),
    parse: *ParseType(python),
) Structure {
    assert(source.len <= std.math.maxInt(u32));
    assert(syntax.tree.count() == 0);

    syntax.lex_source(source, .of(.python)) catch return .{ .truncated = .tokens };

    return parse.parser.build(
        source,
        syntax.tokens.slice(),
        syntax.raw.const_slice(),
        &parse.events,
        &syntax.tree,
    );
}

fn check_python(
    source: []const u8,
    tables: *PythonTables,
    semantic: *const python.Semantic,
    names: *ArrayType(Span),
    version: stdlib.PythonVersion,
) Structure {
    assert(source.len <= std.math.maxInt(u32));

    const syntax = &tables.syntax;

    assert(syntax.tokens.count() == syntax.raw.count());
    assert(tables.checks.empty());

    const completion = check(&.{
        .raw = syntax.raw.const_slice(),
        .semantic = semantic,
        .source = source,
        .tokens = syntax.tokens.slice(),
        .tree = &syntax.tree,
        .version = version,
    }, &tables.checks, names);

    return switch (completion) {
        .complete => .complete,
        .errors_full => .{ .truncated = .checks },
        .frames_full => .too_deep,
        .scratch_full => .{ .truncated = .bindings },
        .target_stack_full => .too_deep,
    };
}

fn build_zig(
    source: []const u8,
    tables: *TablesType(zig),
    scratch: *Front.Scratch,
    globals: []const []const u8,
) Structure {
    assert(source.len <= std.math.maxInt(u32));
    assert(tables.syntax.tree.count() == 0);
    assert(globals.len <= std.math.maxInt(u32));

    const parse = scratch.zig.?;
    const syntax = &tables.syntax;

    syntax.lex_source(source, .of(.zig)) catch return .{ .truncated = .tokens };

    const built = parse.parser.build(
        source,
        syntax.tokens.slice(),
        syntax.raw.const_slice(),
        &parse.events,
        &syntax.tree,
    );

    if (built != .complete) return built;

    const semantic = if (tables.semantic) |*held| held else return .complete;

    return semantic.build(
        source,
        syntax.tokens.slice(),
        syntax.raw.const_slice(),
        &syntax.tree,
        globals,
    );
}

const annotation_node_count_max: u32 = 1 << 8;
const annotation_token_count_max: u32 = 1 << 8;

const capacity_test: Front.Capacity = .{
    .diagnostic_count_max = 1 << 6,
    .event_count_max = 1 << 12,
    .node_count_max = 1 << 10,
    .semantic = .{
        .binding_count_max = 1 << 8,
        .fact_count_max = 1 << 6,
        .reference_count_max = 1 << 8,
        .scope_count_max = 1 << 6,
    },
    .tag_count_max = 1 << 6,
    .token_count_max = 1 << 10,
};

const Held = struct {
    front: Front,
    scratch: Front.Scratch,

    fn init(
        held: *Held,
        capacity: *const Front.Capacity,
        language: Language,
    ) std.mem.Allocator.Error!void {
        const gpa = std.testing.allocator;

        try held.scratch.init(gpa, capacity, .initOne(language));
        errdefer held.scratch.deinit(gpa);

        try held.front.init(gpa, capacity, language);

        assert(held.front.language == language);
        assert(held.front.outcome == null);
    }

    fn deinit(held: *Held) void {
        assert(held.front.tables_match());

        held.front.deinit(std.testing.allocator);
        held.scratch.deinit(std.testing.allocator);
        held.* = undefined;
    }

    fn parse(held: *Held, source: []const u8, options: *const Front.Options) Front.Error!void {
        assert(source.len <= std.math.maxInt(u32));
        defer assert(held.front.outcome != null);

        return held.front.parse(&held.scratch, .of(held.front.language), source, options);
    }
};

const capacity_syntax_test: Front.Capacity = syntax: {
    var held = capacity_test;

    held.semantic = null;

    break :syntax held;
};

fn parsed_test(front: *Front, scratch: *Front.Scratch, source: []const u8) Front.Error!void {
    assert(source.len <= std.math.maxInt(u32));

    return front.parse(scratch, .of(front.language), source, &options_test);
}

const options_test: Front.Options = .{
    .globals = &.{ "u8", "usize" },
    .python_version = .py310,
    .vocabulary = .empty,
};

test Front {
    const gpa = std.testing.allocator;
    var scratch: Front.Scratch = undefined;

    try scratch.init(gpa, &capacity_test, .initOne(.python));
    defer scratch.deinit(gpa);

    var front: Front = undefined;

    try front.init(gpa, &capacity_test, .python);
    defer front.deinit(gpa);

    try front.parse(&scratch, .of(.python), source_python_test, &.{});

    const root = front.root_as(python.ast.View);

    try std.testing.expectEqual(python.Kind.module, root.kind());
    try std.testing.expectEqual(3, front.bindings().count());
    try std.testing.expectEqual(0, front.diagnostics().len);
    try std.testing.expectEqual(1, front.nodes_of(.function).len);

    var tight = capacity_test;
    tight.token_count_max = 8;

    var small: Front = undefined;

    try small.init(gpa, &tight, .python);
    defer small.deinit(gpa);

    const refused = small.parse(&scratch, .of(.python), source_python_test, &.{});

    try std.testing.expectError(error.TokensExhausted, refused);
    try std.testing.expectEqual(0, small.node_count());
}

test "a zig front binds its names and records its import" {
    const gpa = std.testing.allocator;
    var scratch: Front.Scratch = undefined;

    try scratch.init(gpa, &capacity_test, .initOne(.zig));
    defer scratch.deinit(gpa);

    var front: Front = undefined;

    try front.init(gpa, &capacity_test, .zig);
    defer front.deinit(gpa);

    try parsed_test(&front, &scratch, source_test);

    const bindings = front.bindings();

    try std.testing.expectEqual(3, bindings.count());
    try std.testing.expectEqual(1, front.facts().len);
    try std.testing.expectEqual(.import_named, front.facts()[0].kind);
    try std.testing.expectEqual(1, front.nodes_of(.function).len);

    var top = bindings.members_of(0);
    const top_first = top.next();
    const top_second = top.next();
    const top_third = top.next();

    try std.testing.expectEqual(0, top_first.?);
    try std.testing.expectEqual(1, top_second.?);
    try std.testing.expectEqual(null, top_third);

    var uses = bindings.references_of(2);
    const use = uses.next().?;
    const use_after = uses.next();

    try std.testing.expectEqualStrings("one", use.name.text(source_test));
    try std.testing.expect(!use.is_store);
    try std.testing.expectEqual(null, use_after);
}

test "a css front records its import and binds no name" {
    const gpa = std.testing.allocator;
    var scratch: Front.Scratch = undefined;

    try scratch.init(gpa, &capacity_test, .initOne(.css));
    defer scratch.deinit(gpa);

    var front: Front = undefined;

    try front.init(gpa, &capacity_test, .css);
    defer front.deinit(gpa);

    try parsed_test(&front, &scratch, source_css_test);

    const bindings = front.bindings();
    const facts = front.facts();

    try std.testing.expect(bindings == .empty);
    try std.testing.expectEqual(0, bindings.scope_count());
    try std.testing.expectEqual(1, facts.len);
    try std.testing.expectEqual(.import_side_effect, facts[0].kind);
    try std.testing.expectEqualStrings("reset.css", facts[0].specifier.text(source_css_test));
    try std.testing.expect(front.node_count() > 0);
}

test "a go front binds its names and records its import" {
    const gpa = std.testing.allocator;
    var scratch: Front.Scratch = undefined;

    try scratch.init(gpa, &capacity_test, .initOne(.go));
    defer scratch.deinit(gpa);

    var front: Front = undefined;

    try front.init(gpa, &capacity_test, .go);
    defer front.deinit(gpa);

    try parsed_test(&front, &scratch, source_go_test);

    const bindings = front.bindings();

    try std.testing.expectEqual(3, bindings.count());
    try std.testing.expectEqual(1, front.facts().len);
    try std.testing.expectEqual(.import_named, front.facts()[0].kind);
    try std.testing.expectEqual(0, front.facts()[0].binding.unwrap());
    try std.testing.expectEqual(1, front.nodes_of(.function).len);

    var uses = bindings.references_of(2);
    const use = uses.next().?;
    const use_after = uses.next();

    try std.testing.expectEqualStrings("one", use.name.text(source_go_test));
    try std.testing.expect(!use.is_store);
    try std.testing.expectEqual(null, use_after);
}

test "a javascript front binds its names and records its import" {
    const gpa = std.testing.allocator;
    var scratch: Front.Scratch = undefined;

    try scratch.init(gpa, &capacity_test, .initOne(.javascript));
    defer scratch.deinit(gpa);

    var front: Front = undefined;

    try front.init(gpa, &capacity_test, .javascript);
    defer front.deinit(gpa);

    try parsed_test(&front, &scratch, source_javascript_test);

    const bindings = front.bindings();

    try std.testing.expectEqual(2, bindings.count());
    try std.testing.expectEqual(1, front.facts().len);
    try std.testing.expectEqual(.import_default, front.facts()[0].kind);
    try std.testing.expectEqual(0, front.facts()[0].binding.unwrap());

    var uses = bindings.references_of(0);
    const use = uses.next().?;
    const use_after = uses.next();

    try std.testing.expectEqualStrings("one", use.name.text(source_javascript_test));
    try std.testing.expect(!use.is_store);
    try std.testing.expectEqual(null, use_after);
}

test "a tsx front reads its component through the typescript tables" {
    const gpa = std.testing.allocator;
    var scratch: Front.Scratch = undefined;

    try scratch.init(gpa, &capacity_test, .initOne(.typescript));
    defer scratch.deinit(gpa);

    var front: Front = undefined;

    try front.init(gpa, &capacity_test, .typescript);
    defer front.deinit(gpa);

    const tsx: SourceType = .{ .flavor = .tsx, .language = .typescript };

    try front.parse(&scratch, tsx, source_tsx_test, &options_test);

    const bindings = front.bindings();

    try std.testing.expectEqual(SourceType.Flavor.tsx, front.flavor);
    try std.testing.expectEqual(2, bindings.count());
    try std.testing.expectEqual(.import, bindings.at(0).class);

    var uses = bindings.references_of(0);
    const use = uses.next().?;
    const use_after = uses.next();

    try std.testing.expectEqualStrings("Comp", use.name.text(source_tsx_test));
    try std.testing.expectEqual(null, use_after);
}

test "a typescript front exports an interface through the type space" {
    const gpa = std.testing.allocator;
    var scratch: Front.Scratch = undefined;

    try scratch.init(gpa, &capacity_test, .initOne(.typescript));
    defer scratch.deinit(gpa);

    var front: Front = undefined;

    try front.init(gpa, &capacity_test, .typescript);
    defer front.deinit(gpa);

    try parsed_test(&front, &scratch, source_typescript_test);

    const bindings = front.bindings();

    try std.testing.expectEqual(1, bindings.count());
    try std.testing.expectEqual(.type, bindings.at(0).class);
    try std.testing.expectEqual(1, front.facts().len);
    try std.testing.expectEqual(.export_named, front.facts()[0].kind);
    try std.testing.expectEqual(0, front.facts()[0].binding.unwrap());
}

test "an odin front binds its names and records its import" {
    const gpa = std.testing.allocator;
    var scratch: Front.Scratch = undefined;

    try scratch.init(gpa, &capacity_test, .initOne(.odin));
    defer scratch.deinit(gpa);

    var front: Front = undefined;

    try front.init(gpa, &capacity_test, .odin);
    defer front.deinit(gpa);

    try parsed_test(&front, &scratch, source_odin_test);

    const bindings = front.bindings();

    try std.testing.expectEqual(3, bindings.count());
    try std.testing.expectEqual(1, front.facts().len);
    try std.testing.expectEqual(.import_named, front.facts()[0].kind);
    try std.testing.expectEqual(0, front.facts()[0].binding.unwrap());

    var uses = bindings.references_of(2);
    const use = uses.next().?;
    const use_after = uses.next();

    try std.testing.expectEqualStrings("one", use.name.text(source_odin_test));
    try std.testing.expect(!use.is_store);
    try std.testing.expectEqual(null, use_after);
}

test "a python front binds its names and records its import" {
    const gpa = std.testing.allocator;
    var scratch: Front.Scratch = undefined;

    try scratch.init(gpa, &capacity_test, .initOne(.python));
    defer scratch.deinit(gpa);

    var front: Front = undefined;

    try front.init(gpa, &capacity_test, .python);
    defer front.deinit(gpa);

    try parsed_test(&front, &scratch, source_python_test);

    const bindings = front.bindings();

    try std.testing.expectEqual(3, bindings.count());
    try std.testing.expectEqual(.import, bindings.at(0).class);
    try std.testing.expectEqual(1, front.facts().len);
    try std.testing.expectEqual(.import_named, front.facts()[0].kind);
    try std.testing.expectEqual(0, front.facts()[0].binding.unwrap());
    try std.testing.expectEqual(0, python_checks_of(&front).len);

    var uses = bindings.references_of(2);
    const use = uses.next().?;
    const use_after = uses.next();

    try std.testing.expectEqualStrings("one", use.name.text(source_python_test));
    try std.testing.expect(!use.is_store);
    try std.testing.expectEqual(null, use_after);
}

test "a python method is a function under a type scope" {
    const gpa = std.testing.allocator;
    const source = "class Held:\n    def run(self):\n        return self\n";
    var scratch: Front.Scratch = undefined;

    try scratch.init(gpa, &capacity_test, .initOne(.python));
    defer scratch.deinit(gpa);

    var front: Front = undefined;

    try front.init(gpa, &capacity_test, .python);
    defer front.deinit(gpa);

    try parsed_test(&front, &scratch, source);

    const bindings = front.bindings();
    var found = false;

    for (0..bindings.count()) |index| {
        const binding = bindings.at(@intCast(index));
        if (binding.class != .function) continue;

        try std.testing.expectEqual(.type, bindings.scope_at(binding.scope).class);

        found = true;
    }

    try std.testing.expect(found);
}

test "a python front that cannot finish keeps nothing" {
    const gpa = std.testing.allocator;
    const capacity = capacity_shrunk(&capacity_test, 7);
    var scratch: Front.Scratch = undefined;

    try scratch.init(gpa, &capacity, .initOne(.python));
    defer scratch.deinit(gpa);

    var front: Front = undefined;

    try front.init(gpa, &capacity, .python);
    defer front.deinit(gpa);

    const parsed = parsed_test(&front, &scratch, source_python_test);

    try std.testing.expectError(error.TokensExhausted, parsed);
    try std.testing.expectEqual(0, front.node_count());
    try std.testing.expectEqual(0, front.bindings().scope_count());
    try std.testing.expectEqual(0, front.facts().len);
    try std.testing.expectEqual(0, python_checks_of(&front).len);
}

test "a python front reports a return outside a function" {
    const gpa = std.testing.allocator;
    const source = "value = 1\nreturn value\n";
    var scratch: Front.Scratch = undefined;

    try scratch.init(gpa, &capacity_test, .initOne(.python));
    defer scratch.deinit(gpa);

    var front: Front = undefined;

    try front.init(gpa, &capacity_test, .python);
    defer front.deinit(gpa);

    try parsed_test(&front, &scratch, source);

    const checks = python_checks_of(&front);

    try std.testing.expectEqual(1, checks.len);
    try std.testing.expectEqual(.return_outside_function, checks[0].kind);
    try std.testing.expectEqualStrings("return value", checks[0].span.text(source));
}

test "a zig front with a syntax error still binds and names what it found" {
    const gpa = std.testing.allocator;
    const source = "const a = 1;\nfn f() void { return ) }\n";
    var scratch: Front.Scratch = undefined;

    try scratch.init(gpa, &capacity_test, .initOne(.zig));
    defer scratch.deinit(gpa);

    var front: Front = undefined;

    try front.init(gpa, &capacity_test, .zig);
    defer front.deinit(gpa);

    try parsed_test(&front, &scratch, source);

    try std.testing.expect(front.has_diagnostics());
    try std.testing.expect(front.bindings().count() > 0);

    const held = front.diagnostics()[0];
    var buffer: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);

    try front.diagnostic_write(held, &out);
    try std.testing.expectEqualStrings("paren_close", front.kind_name(held.found.?).?);
    try std.testing.expectEqualStrings("semicolon", front.kind_name(held.expected.?).?);
    try std.testing.expect(std.mem.endsWith(u8, out.buffered(), ", found paren_close"));
}

test "a zig front that cannot finish keeps nothing" {
    const gpa = std.testing.allocator;
    const capacity = capacity_shrunk(&capacity_test, 7);
    var scratch: Front.Scratch = undefined;

    try scratch.init(gpa, &capacity, .initOne(.zig));
    defer scratch.deinit(gpa);

    var front: Front = undefined;

    try front.init(gpa, &capacity, .zig);
    defer front.deinit(gpa);

    const parsed = parsed_test(&front, &scratch, source_test);

    try std.testing.expectError(error.TokensExhausted, parsed);
    try std.testing.expectEqual(0, front.node_count());
    try std.testing.expect(front.bindings() == .empty);
    try std.testing.expectEqual(0, front.bindings().count());
    try std.testing.expectEqual(0, front.bindings().scope_count());
    try std.testing.expectEqual(0, front.facts().len);
}

test "a syntax front parses and binds nothing" {
    const gpa = std.testing.allocator;
    var scratch: Front.Scratch = undefined;

    try scratch.init(gpa, &capacity_syntax_test, .initOne(.zig));
    defer scratch.deinit(gpa);

    var front: Front = undefined;

    try front.init(gpa, &capacity_syntax_test, .zig);
    defer front.deinit(gpa);

    try parsed_test(&front, &scratch, source_test);

    try std.testing.expect(front.node_count() > 0);
    try std.testing.expectEqual(0, front.bindings().count());
    try std.testing.expectEqual(0, front.facts().len);

    front.clear();

    try std.testing.expectEqual(null, front.outcome);
}

test "a front without semantic capacity resolves nothing" {
    var python_held: Held = undefined;

    try python_held.init(&capacity_syntax_test, .python);
    defer python_held.deinit();

    var zig_held: Held = undefined;

    try zig_held.init(&capacity_syntax_test, .zig);
    defer zig_held.deinit();

    try python_held.parse(source_python_test, &options_test);
    try zig_held.parse(source_test, &options_test);
    try std.testing.expect(python_held.front.node_count() > 0);
    try std.testing.expect(zig_held.front.node_count() > 0);
    try std.testing.expectEqual(0, python_held.front.bindings().count());
    try std.testing.expectEqual(0, python_held.front.facts().len);
    try std.testing.expectEqual(0, python_checks_of(&python_held.front).len);
}

test "a node holding more children than the old cap iterates them all" {
    const statement_count = (1 << 16) + 1;
    const repeated: [statement_count][2]u8 = @splat("a\n".*);
    const source: []const u8 = std.mem.asBytes(&repeated);
    var capacity = capacity_syntax_test;
    capacity.event_count_max = 1 << 20;
    capacity.node_count_max = 1 << 18;
    capacity.token_count_max = 1 << 18;

    var held: Held = undefined;

    try held.init(&capacity, .python);
    defer held.deinit();

    try held.parse(source, &options_test);

    const children = held.front.root().?.children();

    try std.testing.expectEqual(statement_count, children.count());
}

test "a shrunk limit never reaches zero" {
    try std.testing.expectEqual(1, count_shrunk(1, 7));
    try std.testing.expectEqual(8, count_shrunk(1 << 10, 7));
    try std.testing.expectEqual(1, capacity_shrunk(&capacity_test, 31).node_count_max);
}

const options_markup_test: Front.Options = .{
    .globals = &.{},
    .python_version = .py310,
    .vocabulary = vocabulary_test,
};

const vocabulary_test: markup_module.Vocabulary = .{
    .dialect = .html,
    .end_prefix = "end",
    .extends_tags = &.{"extends"},
    .intermediate_words = &.{"else"},
    .only_word = "only",
    .raw_text_tags = &.{
        .{ .body = .text, .end = "endverbatim", .name = "verbatim", .stage = .lexer },
    },
    .specifications = &.{.{ .intermediates = &.{"else"}, .name = "if" }},
    .template_imports = &.{ "extends", "include" },
};

fn markup_built_test(
    held: *Held,
    source: []const u8,
    vocabulary: markup_module.Vocabulary,
) (error{OutOfMemory} || Front.Error)!void {
    assert(source.len <= std.math.maxInt(u32));

    var options = options_markup_test;

    options.vocabulary = vocabulary;
    options.vocabulary.template_imports = vocabulary_test.template_imports;

    try held.init(&capacity_test, .markup);
    errdefer held.deinit();

    assert(held.front.markup() != null);

    try held.parse(source, &options);
}

test "a markup front pairs its blocks and kinds its facts" {
    const source = "{% extends 'b.html' %}{% if a %}{% include 'c.html' only %}{% endif %}";
    var held_test: Held = undefined;

    try markup_built_test(&held_test, source, vocabulary_test);
    defer held_test.deinit();

    const front = &held_test.front;
    const blocks = front.markup().?.blocks();
    var closed_count: u32 = 0;

    for (blocks.block_slice()) |*block| {
        if (block.is_closed()) closed_count += 1;
    }

    try std.testing.expectEqual(Structure.complete, front.outcome.?);
    try std.testing.expectEqual(1, closed_count);
    try std.testing.expectEqual(0, blocks.unmatched_closer_slice().len);
    try std.testing.expectEqual(Front.Fact.Kind.extends, front.facts()[0].kind);

    try std.testing.expectEqual(
        Front.Fact.Kind{ .include = .{ .only = true } },
        front.facts()[1].kind,
    );

    const held = front.markup().?;

    try std.testing.expectEqual(markup_module.Kind.document, held.root().kind());
    try std.testing.expectEqual(front.node_count(), held.node_count());
}

test "a truncated lex keeps the tree" {
    const repeated: [64][8]u8 = @splat("<p>a</p>".*);
    const source: []const u8 = std.mem.asBytes(&repeated);
    var held: Held = undefined;

    try held.init(&capacity_shrunk(&capacity_test, 7), .markup);
    defer held.deinit();

    try std.testing.expectError(error.TokensExhausted, held.parse(source, &options_markup_test));

    const front = &held.front;

    try std.testing.expect(front.node_count() > 0);
    try std.testing.expect(front.markup().?.tokens().len > 0);
}

test "a block map past its tag table truncates the front" {
    const source = "{% if a %}{% if b %}{% endif %}{% endif %}";
    var capacity = capacity_test;
    capacity.tag_count_max = 2;

    var held: Held = undefined;

    try held.init(&capacity, .markup);
    defer held.deinit();

    try std.testing.expectError(error.TagsExhausted, held.parse(source, &options_markup_test));
}

test "an empty vocabulary pairs nothing and includes everything" {
    const source = "{% extends 'b.html' %}{% if a %}{% endif %}";
    var held: Held = undefined;

    try markup_built_test(&held, source, .empty);
    defer held.deinit();

    const front = &held.front;
    const blocks = front.markup().?.blocks();

    try std.testing.expectEqual(
        Front.Fact.Kind{ .include = .{ .only = false } },
        front.facts()[0].kind,
    );

    for (blocks.block_slice()) |*block| try std.testing.expect(!block.is_closed());

    try std.testing.expectEqual(0, blocks.block_slice().len);
}

test "a non markup front has no markup tables" {
    var held: Held = undefined;

    try held.init(&capacity_test, .python);
    defer held.deinit();

    const front = &held.front;

    try std.testing.expect(front.markup() == null);
    try std.testing.expect(syntax_of(front, python.Kind) != null);
    try std.testing.expect(syntax_of(front, zig.Kind) == null);
}

const source_javascript_test =
    \\import one from "one";
    \\const two = one;
    \\
;

const source_tsx_test =
    \\import Comp from "m";
    \\const held = <Comp />;
    \\
;

const source_typescript_test =
    \\interface Held {}
    \\export { Held };
    \\
;

const source_css_test = "@import \"reset.css\";\n\n.card {\n    color: var(--brand);\n}\n";

const source_go_test =
    \\package p
    \\
    \\import "strings"
    \\
    \\func run(one string) int {
    \\    return strings.Count(one, "")
    \\}
    \\
;

test "a rust front binds its names and records its import" {
    const gpa = std.testing.allocator;
    var scratch: Front.Scratch = undefined;

    try scratch.init(gpa, &capacity_test, .initOne(.rust));
    defer scratch.deinit(gpa);

    var front: Front = undefined;

    try front.init(gpa, &capacity_test, .rust);
    defer front.deinit(gpa);

    try parsed_test(&front, &scratch, source_rust_test);

    const bindings = front.bindings();

    try std.testing.expectEqual(3, bindings.count());
    try std.testing.expectEqual(1, front.facts().len);
    try std.testing.expectEqual(.import_named, front.facts()[0].kind);
    try std.testing.expectEqual(1, front.nodes_of(.function).len);

    var uses = bindings.references_of(2);
    const use = uses.next().?;
    const use_after = uses.next();

    try std.testing.expectEqualStrings("one", use.name.text(source_rust_test));
    try std.testing.expect(!use.is_store);
    try std.testing.expectEqual(null, use_after);
}

test "a rust front that cannot finish keeps nothing" {
    const gpa = std.testing.allocator;
    const capacity = capacity_shrunk(&capacity_test, 7);
    var scratch: Front.Scratch = undefined;

    try scratch.init(gpa, &capacity, .initOne(.rust));
    defer scratch.deinit(gpa);

    var front: Front = undefined;

    try front.init(gpa, &capacity, .rust);
    defer front.deinit(gpa);

    const parsed = parsed_test(&front, &scratch, source_rust_test);

    try std.testing.expectError(error.TokensExhausted, parsed);
    try std.testing.expectEqual(0, front.node_count());
    try std.testing.expectEqual(0, front.bindings().scope_count());
    try std.testing.expectEqual(0, front.facts().len);
}

const source_python_test =
    \\import os
    \\
    \\
    \\def run(one):
    \\    return os.path.join(one)
    \\
;

const source_odin_test = "package p\n\nimport \"core:fmt\"\n\n" ++
    "run :: proc(one: int) -> int {\n\treturn one\n}\n";

const source_test =
    \\const std = @import("std");
    \\
    \\fn run(one: u8) usize {
    \\    return std.mem.len(one);
    \\}
    \\
;

const source_rust_test =
    \\use std::mem;
    \\
    \\fn run(one: u8) -> usize {
    \\    mem::size_of_val(&one)
    \\}
    \\
;
