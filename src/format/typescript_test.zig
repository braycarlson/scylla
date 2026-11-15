const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Buffer = @import("../stdx/bounded/buffer.zig");
const Dialect = @import("../syntax/javascript/dialect.zig").Dialect;
const EventsType = @import("../syntax/tree.zig").EventsType;
const Formatter = @import("typescript.zig").Formatter;
const FormatterError = @import("formatters.zig").FormatterError;
const Input = @import("typescript.zig").Input;
const Kind = @import("../syntax/javascript/kind.zig").Kind;
const Parser = @import("../syntax/javascript/parse.zig").Parser;
const Span = @import("../stdx/bounded/span.zig");
const Structure = @import("../syntax/tree.zig").Structure;
const Token = @import("../syntax/token.zig");
const Tokens = @import("../syntax/tokens.zig");
const TreeType = @import("../syntax/tree.zig").TreeType;
const javascript_lex = @import("../syntax/javascript/lex.zig").lex;
const corpus = @import("../testing/corpus.zig");
const environment = @import("../testing/environment.zig");
const floor = @import("../testing/floor.zig");
const keyed_name = @import("text.zig").named_key;
const lex = @import("../syntax/lex.zig");
const oracle = @import("../testing/oracle.zig");
const raw_of = @import("../syntax/raw.zig").raw_of;
const stripe = @import("../testing/stripe.zig");
const renumbered = @import("text.zig").renumbered;
const unicode = @import("../text/unicode.zig");
const walk = @import("walk.zig");
const Events = EventsType(Kind);
const Tree = TreeType(Kind);

const Held = struct {
    dialect: Dialect,
    events: *Events,
    formatter: Formatter,
    parser: *Parser,
    raw: ArrayType(Kind),
    tokens: Tokens,
    tree: Tree,

    fn init(held: *Held, gpa: std.mem.Allocator) !void {
        held.dialect = .typescript;

        held.events = try gpa.create(Events);
        errdefer gpa.destroy(held.events);

        try held.events.init(gpa, event_count_max);
        errdefer held.events.deinit(gpa);

        held.formatter = try .init(gpa, element_count_max, out_bytes_max);
        errdefer held.formatter.deinit(gpa);

        held.parser = try gpa.create(Parser);
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
        held.formatter.deinit(gpa);
        held.events.deinit(gpa);
        gpa.destroy(held.events);
        held.* = undefined;
    }

    fn format(held: *Held, source: []const u8, out: *Buffer) FormatterError!void {
        assert(source.len <= std.math.maxInt(u32));

        held.classified(source);

        const input = held.input_of(source, held.parsed(source));

        assert(input.tokens.len == input.raw.len);
        assert(input.source.len == source.len);

        return held.formatter.format(&input, out);
    }

    fn range(
        held: *Held,
        source: []const u8,
        lines: walk.LineRange,
        out: *Buffer,
    ) FormatterError!Span {
        assert(source.len <= std.math.maxInt(u32));

        held.classified(source);

        const input = held.input_of(source, held.parsed(source));

        assert(input.tokens.len == input.raw.len);
        assert(lines.first <= lines.last);

        return held.formatter.range(&input, lines, out);
    }

    fn input_of(held: *const Held, source: []const u8, outcome: Structure) Input {
        assert(held.raw.count() == held.tokens.count());
        assert(source.len <= std.math.maxInt(u32));
        if (outcome == .complete) assert(held.tree.count() > 0);

        return .{
            .options = .default,
            .outcome = outcome,
            .raw = held.raw.const_slice(),
            .source = source,
            .tokens = held.tokens.slice(),
            .tree = &held.tree,
            .tsx = held.dialect.is_tsx(),
        };
    }

    fn parsed(held: *Held, source: []const u8) Structure {
        const tokens = held.tokens.slice();
        const raw = held.raw.const_slice();
        const grammar = held.dialect.grammar(.module);

        assert(tokens.len == raw.len);
        assert(source.len <= std.math.maxInt(u32));

        return held.parser.build(source, tokens, raw, held.events, &held.tree, grammar);
    }

    fn words(held: *Held, arena: std.mem.Allocator, source: []const u8) ![]const []const u8 {
        assert(source.len <= std.math.maxInt(u32));

        held.classified(source);

        var kept: std.ArrayList(Token) = try .initCapacity(arena, held.tokens.count());

        for (held.tokens.slice()) |token| {
            if (word_skipped(token)) continue;

            kept.appendAssumeCapacity(token);
        }

        const written = try arena.alloc([]const u8, kept.items.len);

        for (written, 0..) |*word, index| {
            word.* = try word_written(arena, source, kept.items, index);
        }

        assert(written.len <= held.tokens.count());

        return written;
    }

    fn classified(held: *Held, source: []const u8) void {
        assert(source.len <= std.math.maxInt(u32));

        held.tokens.clear();

        javascript_lex(source, &held.tokens, held.dialect) catch |err| switch (err) {
            error.Truncated => assert(held.tokens.items.full()),
        };

        raw_of(Kind, held.tokens.slice(), &held.raw) catch unreachable;

        assert(held.raw.count() == held.tokens.count());
        assert(held.raw.count() <= token_count_max);
    }

    fn comments(held: *Held, arena: std.mem.Allocator, source: []const u8) ![]const u8 {
        assert(source.len <= std.math.maxInt(u32));

        held.classified(source);

        const raw = held.raw.const_slice();
        const tokens = held.tokens.slice();
        var found: std.ArrayList(u8) = .empty;

        assert(raw.len == tokens.len);

        for (raw, tokens) |kind, token| {
            if (kind != .comment) continue;

            const text = std.mem.trimEnd(u8, token.text(source), ascii_whitespace);

            try trimmed(arena, text, &found);
        }

        assert(found.items.len <= source.len);

        return found.items;
    }

    fn kinds(held: *Held, arena: std.mem.Allocator, source: []const u8) ![]const Kind {
        assert(source.len <= std.math.maxInt(u32));

        held.classified(source);

        const raw = held.raw.const_slice();
        const tokens = held.tokens.slice();
        const items = try arena.alloc(Item, raw.len);

        assert(raw.len == tokens.len);

        for (raw, tokens, items) |kind, token, *item| {
            item.* = .{ .kind = kind, .token = token };
        }

        const spaced = try jsx_spaced(arena, source, items);
        const joined = try unioned(arena, source, spaced);
        const ordered = try modifier_ordered(arena, source, joined);

        assert(spaced.len <= items.len);
        assert(joined.len <= spaced.len);
        assert(ordered.len == joined.len);

        return keyed_kinds(arena, source, ordered);
    }

    fn templates(held: *Held, arena: std.mem.Allocator, source: []const u8) ![]const []const u8 {
        assert(source.len <= std.math.maxInt(u32));

        held.classified(source);

        const raw = held.raw.const_slice();
        const tokens = held.tokens.slice();
        var found: std.ArrayList([]const u8) = .empty;

        assert(raw.len == tokens.len);

        for (raw, tokens) |kind, token| {
            if (kind != .template_chars) continue;

            try found.append(arena, token.text(source));
        }

        assert(found.items.len <= raw.len);

        return found.items;
    }
};

const Session = struct {
    held: Held,
    out: Buffer,

    fn init(session: *Session, gpa: std.mem.Allocator) !void {
        try session.held.init(gpa);
        errdefer session.held.deinit(gpa);

        session.out = try .init(gpa, out_bytes_max);

        assert(session.out.empty());
        assert(session.held.dialect == .typescript);
    }

    fn deinit(session: *Session, gpa: std.mem.Allocator) void {
        assert(session.out.capacity() == out_bytes_max);
        assert(session.out.count() <= out_bytes_max);

        session.out.deinit(gpa);
        session.held.deinit(gpa);
        session.* = undefined;
    }

    fn expect(session: *Session, source: []const u8, wanted: []const u8) !void {
        assert(source.len > 0);
        assert(wanted.len > 0);

        try session.held.format(source, &session.out);
        try std.testing.expectEqualStrings(wanted, session.out.const_slice());
        try session.held.format(wanted, &session.out);
        try std.testing.expectEqualStrings(wanted, session.out.const_slice());
    }
};

const Case = struct {
    source: []const u8,
    wanted: []const u8,
};

const Divergence = struct {
    printed: usize,
    source: usize,
};

const Fixture = corpus.File;

const RelationsWorker = struct {
    arena: std.heap.ArenaAllocator,
    first: Buffer,
    held: Held,
    residue: *const oracle.Residue,
    second: Buffer,

    pub const Item = Fixture;
    pub const Shared = struct { residue: *const oracle.Residue };
    pub const Tally = struct { settling: u32 };
    pub const weight = Fixture.weight;

    pub fn init(worker: *RelationsWorker, gpa: std.mem.Allocator, shared: *const Shared) !void {
        assert(shared.residue.fixtures.items.len <= file_count_max);

        worker.arena = .init(gpa);
        errdefer worker.arena.deinit();

        worker.first = try .init(gpa, out_bytes_max);
        errdefer worker.first.deinit(gpa);

        try worker.held.init(gpa);
        errdefer worker.held.deinit(gpa);

        worker.second = try .init(gpa, out_bytes_max);
        worker.residue = shared.residue;

        assert(worker.first.empty());
        assert(worker.second.empty());
    }

    pub fn deinit(worker: *RelationsWorker, gpa: std.mem.Allocator) void {
        assert(worker.first.capacity() == out_bytes_max);
        assert(worker.second.capacity() == out_bytes_max);

        worker.second.deinit(gpa);
        worker.held.deinit(gpa);
        worker.first.deinit(gpa);
        worker.arena.deinit();
        worker.* = undefined;
    }

    pub fn visit(worker: *RelationsWorker, fixture: *const Fixture, tally: *Tally) !void {
        assert(fixture.name.len > 0);
        assert(tally.settling <= file_count_max);

        _ = worker.arena.reset(.retain_capacity);
        worker.held.dialect = dialect_of(fixture.name);

        worker.held.format(fixture.source, &worker.first) catch return;

        const allocator = worker.arena.allocator();
        const once = worker.first.const_slice();

        try expect_relations(&worker.held, allocator, fixture.source, once, fixture.name);

        const residue = worker.residue;
        const settled = try settles(&worker.held, once, &worker.second, fixture.name, residue);

        if (settled) tally.settling += 1;
    }
};

const Item = struct {
    kind: Kind,
    token: Token,
};

const JsxFrame = enum {
    children,
    closing,
    hole,
    tag,
};

const JsxSpace = struct {
    meaningful: bool,
    width: usize,
};

const assigning = [_]Kind{
    .ampersand_ampersand,
    .ampersand_ampersand_equal,
    .ampersand_equal,
    .bar_bar,
    .bar_bar_equal,
    .bar_equal,
    .caret_equal,
    .equal,
    .greater_greater_equal,
    .greater_greater_greater_equal,
    .less_less_equal,
    .minus_equal,
    .percent_equal,
    .plus_equal,
    .question_question,
    .question_question_equal,
    .slash_equal,
    .star_equal,
    .star_star_equal,
};

const assigning_words = [_][]const u8{
    "%=",
    "&&",
    "&&=",
    "&=",
    "**=",
    "*=",
    "+=",
    "-=",
    "/=",
    "<<=",
    "=",
    ">>=",
    ">>>=",
    "??",
    "??=",
    "^=",
    "|=",
    "||",
    "||=",
};

const calls_excluded_words = [_][]const u8{
    "case",
    "catch",
    "do",
    "else",
    "for",
    "if",
    "in",
    "instanceof",
    "of",
    "return",
    "switch",
    "throw",
    "typeof",
    "void",
    "while",
    "with",
    "yield",
};

const modifier_words = [_][]const u8{
    "abstract",
    "accessor",
    "declare",
    "override",
    "private",
    "protected",
    "public",
    "readonly",
    "static",
};

const ascii_whitespace = " \t\n\x0c\r";
const dump_variable = "SCYLLA_FORMAT_DUMP";
const element_count_max: u32 = 1 << 18;
const diagnostic_count_max: u32 = 1 << 12;
const event_count_max: u32 = 1 << 20;

const every_category = [_][]const u8{
    "biome-jsx-forced-break",
    "biome-jsx-layout",
    "biome-line-breaking",
    "biome-literal-normalisation",
    "biome-template-literals",
};

const file_count_max: u32 = 1 << 20;
const fixture_count_min: u32 = 4;
const fixture_root = "tests/fixtures/typescript";
const golden_root = "tests/fixtures/golden-biome-typescript";
const jsx_blanks = " \t\n\r";
const node_count_max: u32 = 1 << 18;
const number_bytes_max: u32 = 1 << 8;
const out_bytes_max: u32 = 1 << 22;
const paren_pass_max: u32 = 32;
const path_bytes_max: u32 = 4096;

const every_unsettled = [_][]const u8{
    "reference-unstable",
    "scylla-unstable",
};

const residue_name = "residue-format-typescript.json";
const residue_relations_name = "residue-relations-typescript.json";
const source_bytes_max: u32 = 1 << 28;
const token_count_max: u32 = 1 << 18;
const tsx_fixture_count: u32 = 6;

pub fn expect_formatted(source: []const u8, wanted: []const u8) !void {
    const gpa = std.testing.allocator;

    assert(source.len > 0);
    assert(wanted.len > 0);

    var session: Session = undefined;

    try session.init(gpa);
    defer session.deinit(gpa);

    try session.expect(source, wanted);
}

pub fn expect_formatted_tsx(source: []const u8, wanted: []const u8) !void {
    const gpa = std.testing.allocator;

    assert(source.len > 0);
    assert(wanted.len > 0);

    var session: Session = undefined;

    try session.init(gpa);
    defer session.deinit(gpa);

    session.held.dialect = .tsx;

    try session.expect(source, wanted);
}

fn expect_cases(cases: []const Case) !void {
    const gpa = std.testing.allocator;

    assert(cases.len > 0);
    assert(cases.len <= file_count_max);

    var session: Session = undefined;

    try session.init(gpa);
    defer session.deinit(gpa);

    for (cases) |case| {
        try session.expect(case.source, case.wanted);
    }
}

fn dialect_of(name: []const u8) Dialect {
    assert(name.len > 0);

    const dot = std.mem.findScalarLast(u8, name, '.');
    const extension = if (dot) |at| name[at + 1 ..] else "ts";
    const result = Dialect.of_extension(extension) orelse unreachable;

    assert(extension.len > 0);

    return result;
}

fn fixtures(gpa: std.mem.Allocator) !std.ArrayList(Fixture) {
    const io = std.testing.io;
    var found: std.ArrayList(Fixture) = .empty;
    errdefer fixtures_free(gpa, &found);

    var directory = try std.Io.Dir.cwd().openDir(io, fixture_root, .{ .iterate = true });
    defer directory.close(io);

    var iterator = directory.iterate();

    for (0..file_count_max) |_| {
        const entry = try iterator.next(io) orelse break;
        const extension = std.Io.Dir.path.extension(entry.name);
        if (extension.len == 0) continue;
        if (Dialect.of_extension(extension[1..]) == null) continue;

        const limit: std.Io.Limit = .limited(source_bytes_max);
        const source = try directory.readFileAlloc(io, entry.name, gpa, limit);
        errdefer gpa.free(source);

        const name = try gpa.dupe(u8, entry.name);
        errdefer gpa.free(name);

        try found.append(gpa, .{ .name = name, .source = source });
    }

    std.mem.sort(Fixture, found.items, {}, fixture_less_than);

    try require(found.items.len > fixture_count_min, "{s} holds too few fixtures", .{fixture_root});

    assert(found.items.len <= file_count_max);
    assert(fixture_less_than({}, found.items[0], found.items[1]));

    return found;
}

fn corpus_selected(basename: []const u8) bool {
    assert(basename.len > 0);

    const dotted = std.Io.Dir.path.extension(basename);
    if (dotted.len < 2) return false;

    const dialect = Dialect.of_extension(dotted[1..]) orelse return false;
    return dialect.typed();
}

fn fixtures_free(gpa: std.mem.Allocator, found: *std.ArrayList(Fixture)) void {
    assert(found.items.len <= found.capacity);
    assert(found.items.len <= file_count_max);

    for (found.items) |fixture| {
        gpa.free(fixture.name);
        gpa.free(fixture.source);
    }

    found.deinit(gpa);
    found.* = undefined;
}

fn fixture_less_than(context: void, left: Fixture, right: Fixture) bool {
    _ = context;

    assert(left.name.len > 0);
    assert(right.name.len > 0);

    return std.mem.lessThan(u8, left.name, right.name);
}

fn read_under(gpa: std.mem.Allocator, root: []const u8, name: []const u8) ![]u8 {
    assert(root.len > 0);
    assert(name.len > 0);

    var path_buffer: [path_bytes_max]u8 = undefined;
    const path = try std.mem.print(&path_buffer, "{s}/{s}", .{ root, name });
    const limit: std.Io.Limit = .limited(source_bytes_max);

    assert(path.len > name.len);

    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, limit);
}

fn is_complete(result: FormatterError!void) bool {
    if (std.meta.isError(result)) return false;

    return true;
}

fn is_refused(result: FormatterError!void) bool {
    if (!std.meta.isError(result)) return false;

    result catch |err| switch (err) {
        error.OutputExhausted => return false,
        error.SourceInvalid => return true,
    };

    return false;
}

fn require(condition: bool, comptime format: []const u8, arguments: anytype) !void {
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    if (condition) return;

    std.debug.print(format ++ "\n", arguments);

    return error.TestUnexpectedResult;
}

fn expect_text(
    name: []const u8,
    comptime message: []const u8,
    expected: []const u8,
    actual: []const u8,
) !void {
    comptime assert(message.len > 0);
    assert(name.len > 0);
    assert(expected.len <= std.math.maxInt(u32));
    assert(actual.len <= std.math.maxInt(u32));

    if (std.mem.eql(u8, expected, actual)) return;

    std.debug.print("{s} " ++ message ++ "\n", .{name});

    return std.testing.expectEqualStrings(expected, actual);
}

fn trimmed(arena: std.mem.Allocator, text: []const u8, found: *std.ArrayList(u8)) !void {
    assert(text.len <= std.math.maxInt(u32));

    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_count: u32 = 0;

    while (lines.next()) |line| : (line_count += 1) {
        assert(line_count <= text.len);

        if (line_count > 0) try found.append(arena, '\n');

        try found.appendSlice(arena, std.mem.trim(u8, line, ascii_whitespace));
    }

    assert(line_count > 0);
}

fn expect_kept(
    held: *Held,
    arena: std.mem.Allocator,
    source: []const u8,
    printed: []const u8,
    name: []const u8,
) !void {
    assert(name.len > 0);
    assert(source.len <= std.math.maxInt(u32));
    assert(printed.len <= std.math.maxInt(u32));

    const before = try held.comments(arena, source);
    const after = try held.comments(arena, printed);

    try expect_text(name, "lost a comment", before, after);

    const templates_before = try held.templates(arena, source);
    const templates_after = try held.templates(arena, printed);
    const edited = "{s} edited a template's characters";

    try require(templates_before.len == templates_after.len, edited, .{name});

    for (templates_before, templates_after) |left, right| {
        try expect_text(name, "edited a template's characters", left, right);
    }
}

fn related(arena: std.mem.Allocator, kinds: []const Kind) ![]const Kind {
    assert(kinds.len <= std.math.maxInt(u32));

    const separated = try listed(arena, kinds);
    const lone = try parenthesised(arena, separated);
    const functions = try called(arena, lone);
    const assignments = try assigned(arena, functions);
    const result = try wrapped(arena, assignments);

    assert(separated.len <= kinds.len);
    assert(result.len <= assignments.len);

    return result;
}

fn kind_is(kinds: []const Kind, at: usize, wanted: Kind) bool {
    assert(kinds.len <= token_count_max);
    assert(at <= kinds.len);
    assert(wanted.is_token());

    return at < kinds.len and kinds[at] == wanted;
}

fn item_is(items: []const Item, at: usize, wanted: Kind) bool {
    assert(items.len <= token_count_max);
    assert(at <= items.len);
    assert(wanted.is_token());

    return at < items.len and items[at].kind == wanted;
}

fn bare_name(text: []const u8) ?[]const u8 {
    if (!keyed_name(text)) return null;

    assert(text.len > 0);

    return text;
}

fn named_key(text: []const u8) ?[]const u8 {
    if (text.len < 2) return null;

    const quote = text[0];
    const quoted = quote == '"' or quote == '\'';
    if (!quoted) return null;
    if (text[text.len - 1] != quote) return null;
    return bare_name(text[1 .. text.len - 1]);
}

fn bare_key(text: []const u8) ?[]const u8 {
    assert(text.len <= std.math.maxInt(u32));

    return named_key(text) orelse bare_name(text);
}

fn is_cast_word(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    const cast = std.mem.eql(u8, text, "as") or std.mem.eql(u8, text, "is");
    return cast or std.mem.eql(u8, text, "satisfies");
}

fn leading_bar(source: []const u8, items: []const Item, index: usize) bool {
    assert(index < items.len);
    assert(source.len <= std.math.maxInt(u32));

    var at = index;

    while (at > 0) {
        assert(at <= items.len);

        at -= 1;

        const item = items[at];
        if (item.kind == .comment) continue;

        return switch (item.kind) {
            .arrow,
            .bracket_open,
            .colon,
            .comma,
            .equal,
            .extends_keyword,
            .less,
            .paren_open,
            .question,
            => true,
            .identifier => is_cast_word(item.token.text(source)),
            else => false,
        };
    }

    return false;
}

fn jsx_child_space(source: []const u8, items: []const Item, index: usize) ?JsxSpace {
    assert(index < items.len);
    assert(source.len <= std.math.maxInt(u32));

    const item = items[index];

    if (item.kind == .jsx_chars) {
        const text = item.token.text(source);

        assert(text.len > 0);

        if (std.mem.trim(u8, text, jsx_blanks).len > 0) return null;

        const lined = std.mem.findAny(u8, text, "\n\r") != null;
        return .{ .meaningful = !lined, .width = 1 };
    }

    if (item.kind != .brace_open) return null;
    if (!item_is(items, index + 1, .string)) return null;
    if (!item_is(items, index + 2, .brace_close)) return null;

    const text = items[index + 1].token.text(source);
    const spaced = std.mem.eql(u8, text, "\" \"") or std.mem.eql(u8, text, "' '");
    if (!spaced) return null;
    return .{ .meaningful = true, .width = 3 };
}

fn jsx_framed(frames: *std.ArrayList(JsxFrame), kind: Kind) void {
    assert(frames.items.len < frames.capacity);
    assert(kind.is_token());

    const top = frames.last() orelse {
        if (kind == .jsx_tag_start) frames.appendAssumeCapacity(.tag);

        return;
    };

    const at = frames.items.len - 1;

    switch (top) {
        .children => switch (kind) {
            .brace_open => frames.appendAssumeCapacity(.hole),
            .jsx_tag_start => frames.appendAssumeCapacity(.tag),
            .jsx_tag_start_close => frames.items[at] = .closing,
            else => {},
        },
        .closing => {
            if (kind == .jsx_tag_end) _ = frames.pop();
        },
        .hole => switch (kind) {
            .brace_open, .substitution_start => frames.appendAssumeCapacity(.hole),
            .brace_close => _ = frames.pop(),
            .jsx_tag_start => frames.appendAssumeCapacity(.tag),
            else => {},
        },
        .tag => switch (kind) {
            .brace_open => frames.appendAssumeCapacity(.hole),
            .jsx_tag_end => frames.items[at] = .children,
            .jsx_tag_end_self => _ = frames.pop(),
            .jsx_tag_start => frames.appendAssumeCapacity(.tag),
            else => {},
        },
    }
}

fn jsx_spaced(arena: std.mem.Allocator, source: []const u8, items: []const Item) ![]const Item {
    assert(source.len <= std.math.maxInt(u32));
    assert(items.len <= std.math.maxInt(u32));

    var found: std.ArrayList(Item) = try .initCapacity(arena, items.len);
    var frames: std.ArrayList(JsxFrame) = try .initCapacity(arena, items.len);
    var index: usize = 0;

    while (index < items.len) {
        const item = items[index];
        const childed = if (frames.last()) |top| top == .children else false;

        if (childed) {
            if (jsx_child_space(source, items, index)) |space| {
                if (space.meaningful) jsx_text_append(&found, item);

                index += space.width;

                continue;
            }

            if (item.kind == .jsx_chars) {
                jsx_text_append(&found, item);
                index += 1;

                continue;
            }
        }

        jsx_framed(&frames, item.kind);
        found.appendAssumeCapacity(item);
        index += 1;
    }

    assert(found.items.len <= items.len);

    return found.items;
}

fn jsx_text_append(found: *std.ArrayList(Item), item: Item) void {
    assert(found.items.len < found.capacity);
    assert(item.kind.is_token());

    if (found.last()) |top| {
        if (top.kind == .jsx_chars) return;
    }

    found.appendAssumeCapacity(.{ .kind = .jsx_chars, .token = item.token });
}

fn unioned(arena: std.mem.Allocator, source: []const u8, items: []const Item) ![]const Item {
    assert(source.len <= std.math.maxInt(u32));
    assert(items.len <= std.math.maxInt(u32));

    var found: std.ArrayList(Item) = try .initCapacity(arena, items.len);

    for (items, 0..) |item, index| {
        const joining = item.kind == .ampersand or item.kind == .bar;

        if (joining) {
            if (leading_bar(source, items, index)) continue;
        }

        found.appendAssumeCapacity(item);
    }

    assert(found.items.len <= items.len);

    return found.items;
}

fn modifier_ordered(
    arena: std.mem.Allocator,
    source: []const u8,
    items: []const Item,
) ![]const Item {
    assert(source.len <= std.math.maxInt(u32));
    assert(items.len <= std.math.maxInt(u32));

    const found = try arena.dupe(Item, items);
    var index: usize = 0;

    while (index < found.len) {
        const count = modifier_run(source, found, index);

        assert(index + count <= found.len);

        if (count > 1) {
            std.sort.insertion(Item, found[index .. index + count], source, modifier_less);
        }

        index += @max(count, 1);
    }

    assert(found.len == items.len);

    return found;
}

fn modifier_run(source: []const u8, items: []const Item, from: usize) usize {
    assert(from < items.len);
    assert(items.len <= token_count_max);
    assert(source.len <= std.math.maxInt(u32));

    var count: usize = 0;

    while (from + count < items.len) {
        const at = from + count;
        if (!modifier_word(items[at].token.text(source))) break;
        if (modifier_broken(source, items, at)) break;

        count += 1;
    }

    if (count == 0) return 0;
    if (modifier_named(items, from + count)) return count;
    assert(count - 1 < std.math.maxInt(u32));

    return count - 1;
}

fn modifier_broken(source: []const u8, items: []const Item, at: usize) bool {
    assert(at < items.len);
    assert(items[at].token.end() <= source.len);

    if (std.mem.eql(u8, items[at].token.text(source), "static")) return false;
    if (at + 1 >= items.len) return false;

    const gap = source[items[at].token.end()..items[at + 1].token.offset];
    return std.mem.findAny(u8, gap, "\n\r") != null;
}

fn modifier_word(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    for (modifier_words) |word| {
        if (std.mem.eql(u8, text, word)) return true;
    }

    return false;
}

fn modifier_named(items: []const Item, from: usize) bool {
    assert(from <= items.len);
    assert(items.len <= token_count_max);

    for (items[from..]) |item| {
        if (item.kind == .comment) continue;

        return switch (item.kind) {
            .bang,
            .brace_close,
            .colon,
            .comma,
            .equal,
            .less,
            .paren_close,
            .paren_open,
            .question,
            .semicolon,
            => false,
            else => true,
        };
    }

    return false;
}

fn modifier_less(source: []const u8, left: Item, right: Item) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(left.token.end() <= source.len);
    assert(right.token.end() <= source.len);

    const left_text = left.token.text(source);
    const right_text = right.token.text(source);

    assert(modifier_word(left_text));
    assert(modifier_word(right_text));

    return std.mem.order(u8, left_text, right_text) == .lt;
}

fn colons(arena: std.mem.Allocator, items: []const Item) ![]bool {
    assert(items.len <= std.math.maxInt(u32));

    const found = try arena.alloc(bool, items.len);
    var owed: std.ArrayList(u32) = try .initCapacity(arena, items.len + 1);

    @memset(found, false);
    owed.appendAssumeCapacity(0);

    for (items, 0..) |item, at| {
        const colon_next = item_is(items, at + 1, .colon);
        const frame = &owed.items[owed.items.len - 1];

        switch (item.kind) {
            .brace_open, .bracket_open, .paren_open, .substitution_start => {
                owed.appendAssumeCapacity(0);
            },
            .brace_close, .bracket_close, .paren_close => {
                if (owed.items.len > 1) _ = owed.pop();
            },
            .comma, .semicolon => frame.* = 0,
            .case_keyword, .question => {
                if (!colon_next) frame.* += 1;
            },
            .colon => {
                if (frame.* > 0) {
                    frame.* -= 1;
                    found[at] = true;
                }
            },
            else => {},
        }
    }

    assert(owed.items.len >= 1);

    return found;
}

fn keyed_kinds(arena: std.mem.Allocator, source: []const u8, items: []const Item) ![]const Kind {
    assert(source.len <= std.math.maxInt(u32));
    assert(items.len <= std.math.maxInt(u32));

    const asked = try colons(arena, items);
    const found = try arena.alloc(Kind, items.len);

    for (found, 0..) |*kind, index| {
        kind.* = key_kind(source, items, asked, index);
    }

    assert(found.len == items.len);

    return found;
}

fn key_kind(source: []const u8, items: []const Item, asked: []const bool, index: usize) Kind {
    assert(source.len <= std.math.maxInt(u32));
    assert(asked.len == items.len);
    assert(index < items.len);

    const item = items[index];
    const text = item.token.text(source);

    if (item_is(items, index + 1, .equal)) {
        if (item.kind == .string) {
            if (named_key(text) != null) return .identifier;
        }
    }

    var at: usize = index + 2;

    if (item_is(items, index + 1, .colon)) {
        at = index + 1;
    } else if (item_is(items, index + 1, .question)) {
        if (!item_is(items, index + 2, .colon)) return item.kind;
    } else {
        return item.kind;
    }

    if (asked[at]) return item.kind;
    if (bare_key(text) == null) return item.kind;
    return .identifier;
}

fn closing(kinds: []const Kind, from: usize) bool {
    assert(from <= kinds.len);
    assert(kinds.len <= token_count_max);

    for (kinds[from..]) |kind| {
        if (kind == .comment) continue;

        return switch (kind) {
            .brace_close, .bracket_close, .greater, .paren_close => true,
            else => false,
        };
    }

    return false;
}

fn listed(arena: std.mem.Allocator, kinds: []const Kind) ![]const Kind {
    assert(kinds.len <= std.math.maxInt(u32));

    var found: std.ArrayList(Kind) = try .initCapacity(arena, kinds.len);

    for (kinds, 0..) |kind, index| {
        const separator = kind == .comma or kind == .semicolon;

        if (separator) {
            if (closing(kinds, index + 1)) continue;
        }

        found.appendAssumeCapacity(if (kind == .comma) .semicolon else kind);
    }

    assert(found.items.len <= kinds.len);

    return found.items;
}

fn parenthesised(arena: std.mem.Allocator, kinds: []const Kind) ![]const Kind {
    assert(kinds.len <= std.math.maxInt(u32));

    var found: std.ArrayList(Kind) = try .initCapacity(arena, kinds.len);
    var index: usize = 0;

    while (index < kinds.len) {
        assert(found.items.len <= index);

        const opened = kind_is(kinds, index, .paren_open) and
            kind_is(kinds, index + 1, .identifier);

        const lone = opened and kind_is(kinds, index + 2, .paren_close) and
            kind_is(kinds, index + 3, .arrow);

        if (lone) {
            found.appendAssumeCapacity(.identifier);
            index += 3;

            continue;
        }

        found.appendAssumeCapacity(kinds[index]);
        index += 1;
    }

    assert(found.items.len <= kinds.len);

    return found.items;
}

fn called(arena: std.mem.Allocator, kinds: []const Kind) ![]const Kind {
    assert(kinds.len <= std.math.maxInt(u32));

    var found: std.ArrayList(Kind) = try .initCapacity(arena, kinds.len);
    var owed: std.ArrayList(u32) = try .initCapacity(arena, kinds.len);
    var depth: u32 = 0;

    for (kinds, 0..) |kind, index| {
        if (kind == .paren_open) {
            depth += 1;

            const asynchronous = kind_is(kinds, index + 1, .async_keyword) and
                kind_is(kinds, index + 2, .function_keyword);

            const functions = kind_is(kinds, index + 1, .function_keyword) or asynchronous;

            if (functions) {
                owed.appendAssumeCapacity(depth);

                continue;
            }
        }

        if (kind == .paren_close) {
            const dropped = owed.items.len > 0 and owed.items[owed.items.len - 1] == depth;

            depth -|= 1;

            if (dropped) {
                _ = owed.pop();

                continue;
            }
        }

        found.appendAssumeCapacity(kind);
    }

    assert(found.items.len <= kinds.len);

    return found.items;
}

fn partners(arena: std.mem.Allocator, kinds: []const Kind) ![]usize {
    assert(kinds.len <= std.math.maxInt(u32));

    const found = try arena.alloc(usize, kinds.len);
    var stack: std.ArrayList(usize) = try .initCapacity(arena, kinds.len);

    for (found, 0..) |*partner, at| partner.* = at;

    for (kinds, 0..) |kind, at| {
        if (kind == .paren_open) {
            stack.appendAssumeCapacity(at);

            continue;
        }

        if (kind != .paren_close) continue;

        const from = stack.pop() orelse continue;

        found[from] = at;
        found[at] = from;
    }

    assert(found.len == kinds.len);

    return found;
}

fn calling(kinds: []const Kind, open: usize) bool {
    assert(open < kinds.len);

    if (open == 0) return false;

    return switch (kinds[open - 1]) {
        .bracket_close,
        .identifier,
        .paren_close,
        .property_identifier,
        .super_keyword,
        .this_keyword,
        => true,
        else => false,
    };
}

fn assigns(kinds: []const Kind, open: usize, close: usize) bool {
    assert(open < close);
    assert(close <= kinds.len);

    var depth: u32 = 0;

    for (kinds[open + 1 .. close]) |kind| {
        switch (kind) {
            .brace_open, .bracket_open, .paren_open => depth += 1,
            .brace_close, .bracket_close, .paren_close => depth -|= 1,
            else => {
                if (depth > 0) continue;
                if (std.mem.findScalar(Kind, &assigning, kind) != null) return true;
            },
        }
    }

    return false;
}

fn assigned(arena: std.mem.Allocator, kinds: []const Kind) ![]const Kind {
    assert(kinds.len <= std.math.maxInt(u32));

    var held = kinds;

    for (0..paren_pass_max) |_| {
        const found = try unassigned(arena, held);
        if (found.len == held.len) return found;

        held = found;
    }

    assert(held.len <= kinds.len);

    return held;
}

fn unassigned(arena: std.mem.Allocator, kinds: []const Kind) ![]const Kind {
    assert(kinds.len <= std.math.maxInt(u32));

    const pairs = try partners(arena, kinds);
    var found: std.ArrayList(Kind) = try .initCapacity(arena, kinds.len);
    var skips: std.ArrayList(usize) = try .initCapacity(arena, kinds.len);
    var index: usize = 0;

    while (index < kinds.len) : (index += 1) {
        assert(found.items.len <= index);

        const skipped = skips.items.len > 0 and skips.items[skips.items.len - 1] == index;

        if (skipped) {
            _ = skips.pop();

            continue;
        }

        const opened = kinds[index] == .paren_open and pairs[index] > index;
        const dropped = opened and !calling(kinds, index) and assigns(kinds, index, pairs[index]);

        if (dropped) {
            skips.appendAssumeCapacity(pairs[index]);

            continue;
        }

        found.appendAssumeCapacity(kinds[index]);
    }

    assert(found.items.len <= kinds.len);

    return found.items;
}

fn wraps_at(kinds: []const Kind, pairs: []const usize, index: usize) bool {
    assert(index < kinds.len);
    assert(pairs.len == kinds.len);

    const worded = kinds[index] == .return_keyword or kinds[index] == .throw_keyword;
    if (!worded) return false;
    if (!kind_is(kinds, index + 1, .paren_open)) return false;
    if (pairs[index + 1] <= index + 1) return false;

    const after = pairs[index + 1] + 1;
    if (after >= kinds.len) return true;
    return kinds[after] == .semicolon or kinds[after] == .brace_close;
}

fn wrapped(arena: std.mem.Allocator, kinds: []const Kind) ![]const Kind {
    assert(kinds.len <= std.math.maxInt(u32));

    const pairs = try partners(arena, kinds);
    var found: std.ArrayList(Kind) = try .initCapacity(arena, kinds.len);
    var skips: std.ArrayList(usize) = try .initCapacity(arena, kinds.len);
    var index: usize = 0;

    while (index < kinds.len) {
        assert(found.items.len <= index);

        if (wraps_at(kinds, pairs, index)) {
            found.appendAssumeCapacity(kinds[index]);
            skips.appendAssumeCapacity(pairs[index + 1]);
            index += 2;

            continue;
        }

        const skipped = skips.items.len > 0 and skips.items[skips.items.len - 1] == index;

        if (skipped) {
            _ = skips.pop();
            index += 1;

            continue;
        }

        found.appendAssumeCapacity(kinds[index]);
        index += 1;
    }

    assert(found.items.len <= kinds.len);

    return found.items;
}

fn voided(kinds: []const Kind, at: usize) bool {
    assert(at < kinds.len);

    if (at == 0) return true;

    return switch (kinds[at - 1]) {
        .brace_open, .brace_close, .colon, .semicolon => true,
        else => false,
    };
}

fn skippable(source: []const Kind, held: usize) bool {
    assert(held <= source.len);

    if (kind_is(source, held, .paren_open)) return true;
    if (kind_is(source, held, .paren_close)) return true;
    if (!kind_is(source, held, .semicolon)) return false;
    return voided(source, held);
}

fn divergence(source: []const Kind, printed: []const Kind) ?Divergence {
    assert(source.len <= std.math.maxInt(u32));
    assert(printed.len <= std.math.maxInt(u32));

    var held: usize = 0;
    var at: usize = 0;

    while (at < printed.len) {
        assert(held <= source.len);

        const carried = printed[at];

        if (kind_is(source, held, carried)) {
            at += 1;
            held += 1;

            continue;
        }

        if (skippable(source, held)) {
            held += 1;

            continue;
        }

        const dropped = carried == .paren_open or carried == .paren_close or
            carried == .semicolon;

        if (!dropped) return .{ .printed = at, .source = held };

        at += 1;
    }

    while (skippable(source, held)) {
        assert(held < source.len);

        held += 1;
    }

    if (held == source.len) return null;
    return .{ .printed = printed.len, .source = held };
}

fn commented(arena: std.mem.Allocator, kinds: []const Kind) ![]const Kind {
    assert(kinds.len <= std.math.maxInt(u32));

    var found: std.ArrayList(Kind) = try .initCapacity(arena, kinds.len);

    for (kinds) |kind| {
        if (kind == .comment) continue;

        found.appendAssumeCapacity(kind);
    }

    assert(found.items.len <= kinds.len);

    return found.items;
}

fn constructed(arena: std.mem.Allocator, kinds: []const Kind) ![]const Kind {
    assert(kinds.len <= std.math.maxInt(u32));

    var held: std.ArrayList(Kind) = try .initCapacity(arena, kinds.len);
    var skips: std.ArrayList(usize) = try .initCapacity(arena, kinds.len);
    var depth: usize = 0;

    for (kinds, 0..) |kind, index| {
        if (kind == .paren_open) {
            const newed = index > 0 and kinds[index - 1] == .new_keyword;
            const opens = newed and kind_is(kinds, index + 1, .class_keyword);

            depth += 1;

            if (opens) {
                skips.appendAssumeCapacity(depth);

                continue;
            }
        } else if (kind == .paren_close) {
            const closes = skips.items.len > 0 and skips.items[skips.items.len - 1] == depth;

            depth -|= 1;

            if (closes) {
                _ = skips.pop();

                continue;
            }
        } else {}

        held.appendAssumeCapacity(kind);
    }

    assert(held.items.len <= kinds.len);

    return constructed_calls(arena, held.items);
}

fn constructed_calls(arena: std.mem.Allocator, held: []const Kind) ![]const Kind {
    assert(held.len <= std.math.maxInt(u32));

    var found: std.ArrayList(Kind) = try .initCapacity(arena, held.len);
    var scan: usize = 0;

    while (scan < held.len) {
        assert(found.items.len <= scan);

        const closed = held[scan] == .brace_close and kind_is(held, scan + 1, .paren_open);
        const call = closed and kind_is(held, scan + 2, .paren_close);

        found.appendAssumeCapacity(held[scan]);
        scan += if (call) 3 else 1;
    }

    assert(found.items.len <= held.len);

    return found.items;
}

fn corpus_related(arena: std.mem.Allocator, kinds: []const Kind) ![]const Kind {
    assert(kinds.len <= std.math.maxInt(u32));

    const plain = try commented(arena, kinds);
    const separated = try listed(arena, plain);
    const lone = try parenthesised(arena, separated);
    const functions = try called(arena, lone);
    const assignments = try assigned(arena, functions);
    const result = try wrapped(arena, try constructed(arena, assignments));

    assert(plain.len <= kinds.len);
    assert(result.len <= assignments.len);

    return result;
}

fn expect_relations(
    held: *Held,
    arena: std.mem.Allocator,
    source: []const u8,
    printed: []const u8,
    name: []const u8,
) !void {
    assert(source.len <= std.math.maxInt(u32));
    assert(printed.len <= std.math.maxInt(u32));

    const before = try corpus_related(arena, try held.kinds(arena, source));
    const after = try corpus_related(arena, try held.kinds(arena, printed));

    assert(name.len > 0);

    if (divergence(before, after)) |found| {
        std.debug.print("{s} lost a token\n  source  {d} of {d}\n  printed {d} of {d}\n", .{
            name,
            found.source,
            before.len,
            found.printed,
            after.len,
        });

        return error.TestUnexpectedResult;
    }

    try expect_kept(held, arena, source, printed, name);
}

fn settles(
    held: *Held,
    once: []const u8,
    second: *Buffer,
    name: []const u8,
    residue: *const oracle.Residue,
) !bool {
    assert(once.len <= std.math.maxInt(u32));
    assert(name.len > 0);

    const formatted = is_complete(held.format(once, second));

    if (residue.contains(name)) {
        try require(
            !formatted or !std.mem.eql(u8, second.const_slice(), once),
            "{s} is a fixed point and needs no residue row",
            .{name},
        );

        return true;
    }

    try require(formatted, "{s}", .{name});
    try expect_text(name, "is not idempotent", once, second.const_slice());

    return false;
}

fn terminated(source: []const Kind, printed: []const Kind) bool {
    assert(source.len <= token_count_max);
    assert(printed.len <= token_count_max);

    return divergence(source, printed) == null;
}

fn words_related(arena: std.mem.Allocator, words: []const []const u8) ![]const []const u8 {
    assert(words.len <= std.math.maxInt(u32));

    const unlisted = try word_separated(arena, words);
    const unbracketed = try word_bracketed(arena, unlisted);
    const bare = try assigned_words(arena, unbracketed);
    const found = try word_opened(arena, bare);

    assert(found.len <= words.len);

    return found;
}

fn word_skipped(token: Token) bool {
    if (token.length == 0) return true;
    return token.kind == .newline;
}

fn word_written(
    arena: std.mem.Allocator,
    source: []const u8,
    tokens: []const Token,
    index: usize,
) ![]const u8 {
    assert(tokens.len <= std.math.maxInt(u32));
    assert(index < tokens.len);

    const token = tokens[index];

    assert(token.length > 0);
    assert(token.end() <= source.len);

    if (token.kind == .number) {
        var form: Buffer = try .init(arena, number_bytes_max);

        renumbered(&form, token.text(source)) catch unreachable;

        return form.const_slice();
    }

    if (token.kind != .string) return token.text(source);
    if (!string_keyed(source, tokens, index)) return "<string>";
    return named_key(token.text(source)) orelse "<string>";
}

fn string_keyed(source: []const u8, tokens: []const Token, index: usize) bool {
    assert(index < tokens.len);

    if (index + 1 >= tokens.len) return false;
    assert(source.len <= std.math.maxInt(u32));

    const next = tokens[index + 1].text(source);
    if (std.mem.eql(u8, next, ":")) return true;
    if (!std.mem.eql(u8, next, "?")) return false;
    if (index + 2 >= tokens.len) return false;
    return std.mem.eql(u8, tokens[index + 2].text(source), ":");
}

fn word_is(words: []const []const u8, at: usize, wanted: []const u8) bool {
    assert(wanted.len > 0);

    if (at >= words.len) return false;
    return std.mem.eql(u8, words[at], wanted);
}

fn word_in(word: []const u8, members: []const []const u8) bool {
    assert(members.len > 0);
    assert(word.len <= std.math.maxInt(u32));

    for (members) |member| {
        if (std.mem.eql(u8, word, member)) return true;
    }

    return false;
}

fn word_opens(word: []const u8) bool {
    assert(word.len <= std.math.maxInt(u32));

    return word_in(word, &.{ "{", "[", "(" });
}

fn word_shuts(word: []const u8) bool {
    assert(word.len <= std.math.maxInt(u32));

    return word_in(word, &.{ "}", "]", ")" });
}

fn word_partners(arena: std.mem.Allocator, words: []const []const u8) ![]usize {
    assert(words.len <= std.math.maxInt(u32));

    const found = try arena.alloc(usize, words.len);
    var stack: std.ArrayList(usize) = try .initCapacity(arena, words.len);

    for (found, 0..) |*partner, at| partner.* = at;

    for (words, 0..) |word, at| {
        if (std.mem.eql(u8, word, "(")) {
            stack.appendAssumeCapacity(at);

            continue;
        }

        if (!std.mem.eql(u8, word, ")")) continue;

        const from = stack.pop() orelse continue;

        found[from] = at;
        found[at] = from;
    }

    assert(found.len == words.len);
    assert(stack.items.len <= words.len);

    return found;
}

fn word_wraps_at(words: []const []const u8, pairs: []const usize, index: usize) bool {
    assert(index < words.len);
    assert(pairs.len == words.len);

    const worded = word_is(words, index, "return") or word_is(words, index, "throw");
    if (!worded) return false;
    if (!word_is(words, index + 1, "(")) return false;
    if (pairs[index + 1] <= index + 1) return false;

    const after = pairs[index + 1] + 1;
    if (after >= words.len) return true;
    return word_is(words, after, ";") or word_is(words, after, "}");
}

fn word_opened(arena: std.mem.Allocator, words: []const []const u8) ![]const []const u8 {
    assert(words.len <= std.math.maxInt(u32));

    const pairs = try word_partners(arena, words);
    var found: std.ArrayList([]const u8) = try .initCapacity(arena, words.len);
    var skips: std.ArrayList(usize) = try .initCapacity(arena, words.len);
    var index: usize = 0;

    while (index < words.len) {
        assert(found.items.len <= index);

        if (word_wraps_at(words, pairs, index)) {
            found.appendAssumeCapacity(words[index]);
            skips.appendAssumeCapacity(pairs[index + 1]);
            index += 2;

            continue;
        }

        const skipped = skips.items.len > 0 and skips.items[skips.items.len - 1] == index;

        if (skipped) {
            _ = skips.pop();
            index += 1;

            continue;
        }

        found.appendAssumeCapacity(words[index]);
        index += 1;
    }

    assert(found.items.len <= words.len);

    return found.items;
}

fn word_opens_name(word: []const u8) bool {
    assert(word.len > 0);

    const leading = word[0];

    if (leading < 0x80) {
        return std.ascii.isAlphanumeric(leading) or leading == '_' or leading == '$';
    }

    const width = std.unicode.utf8ByteSequenceLength(leading) catch return false;
    if (width > word.len) return false;

    const scalar = switch (width) {
        2 => std.unicode.utf8Decode2(word[0..2].*),
        3 => std.unicode.utf8Decode3(word[0..3].*),
        4 => std.unicode.utf8Decode4(word[0..4].*),
        else => unreachable,
    } catch return false;

    assert(scalar >= 0x80);

    return unicode.is_alphanumeric(scalar);
}

fn calls_words(words: []const []const u8, open: usize) bool {
    assert(open < words.len);

    if (open == 0) return false;

    const held = words[open - 1];

    assert(held.len > 0);

    if (word_in(held, &.{ "]", ")", "super", "this" })) return true;
    if (!word_opens_name(held)) return false;
    return !word_in(held, &calls_excluded_words);
}

fn assigns_words(words: []const []const u8, open: usize, close: usize) bool {
    assert(open < close);
    assert(close <= words.len);

    var depth: u32 = 0;

    for (words[open + 1 .. close]) |word| {
        if (word_opens(word)) {
            depth += 1;
        } else if (word_shuts(word)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (word_in(word, &assigning_words)) return true;
        } else {}
    }

    return false;
}

fn assigned_words(arena: std.mem.Allocator, words: []const []const u8) ![]const []const u8 {
    assert(words.len <= std.math.maxInt(u32));

    var held = words;

    for (0..paren_pass_max) |_| {
        const found = try unassigned_words(arena, held);
        if (found.len == held.len) return found;

        held = found;
    }

    assert(held.len <= words.len);

    return held;
}

fn unassigned_words(arena: std.mem.Allocator, words: []const []const u8) ![]const []const u8 {
    assert(words.len <= std.math.maxInt(u32));

    const pairs = try word_partners(arena, words);
    var found: std.ArrayList([]const u8) = try .initCapacity(arena, words.len);
    var skips: std.ArrayList(usize) = try .initCapacity(arena, words.len);
    var index: usize = 0;

    while (index < words.len) : (index += 1) {
        assert(found.items.len <= index);

        const skipped = skips.items.len > 0 and skips.items[skips.items.len - 1] == index;

        if (skipped) {
            _ = skips.pop();

            continue;
        }

        const paired = word_is(words, index, "(") and pairs[index] > index;

        const dropped = paired and !calls_words(words, index) and
            assigns_words(words, index, pairs[index]);

        if (dropped) {
            skips.appendAssumeCapacity(pairs[index]);

            continue;
        }

        found.appendAssumeCapacity(words[index]);
    }

    assert(found.items.len <= words.len);

    return found.items;
}

fn word_separated(arena: std.mem.Allocator, words: []const []const u8) ![]const []const u8 {
    assert(words.len <= std.math.maxInt(u32));

    var found: std.ArrayList([]const u8) = try .initCapacity(arena, words.len);

    for (words, 0..) |word, index| {
        const separator = word_in(word, &.{ ",", ";" });

        if (separator) {
            if (word_closes(words, index + 1)) continue;
        }

        const comma = std.mem.eql(u8, word, ",");

        found.appendAssumeCapacity(if (comma) ";" else word);
    }

    assert(found.items.len <= words.len);

    return found.items;
}

fn word_closes(words: []const []const u8, from: usize) bool {
    assert(from <= words.len);

    var at = from;

    while (at < words.len) : (at += 1) {
        const line_comment = std.mem.startsWith(u8, words[at], "//");
        const block_comment = std.mem.startsWith(u8, words[at], "/*");

        if (!line_comment) {
            if (!block_comment) break;
        }
    }

    assert(at <= words.len);

    if (at == words.len) return false;
    return word_in(words[at], &.{ ")", "]", "}" });
}

fn word_bracketed(arena: std.mem.Allocator, words: []const []const u8) ![]const []const u8 {
    assert(words.len <= std.math.maxInt(u32));

    var found: std.ArrayList([]const u8) = try .initCapacity(arena, words.len);
    var index: usize = 0;

    while (index < words.len) {
        assert(found.items.len <= index);

        const lone = word_is(words, index, "(") and word_is(words, index + 2, ")") and
            word_is(words, index + 3, "=>");

        if (lone) {
            found.appendAssumeCapacity(words[index + 1]);
            index += 3;

            continue;
        }

        found.appendAssumeCapacity(words[index]);
        index += 1;
    }

    assert(found.items.len <= words.len);

    return found.items;
}

fn word_emptied(words: []const []const u8, at: usize) bool {
    assert(at < words.len);

    if (at == 0) return true;
    return word_in(words[at - 1], &.{ "{", "}", ";" });
}

fn word_skippable(source: []const []const u8, held: usize) bool {
    if (held >= source.len) return false;
    if (word_is(source, held, "(")) return true;
    if (word_is(source, held, ")")) return true;
    if (!word_is(source, held, ";")) return false;
    return word_emptied(source, held);
}

fn word_ended(source: []const []const u8, printed: []const []const u8) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(printed.len <= std.math.maxInt(u32));

    var held: usize = 0;
    var at: usize = 0;

    while (at < printed.len) {
        assert(held <= source.len);

        const word = printed[at];

        if (word_is(source, held, word)) {
            at += 1;
            held += 1;

            continue;
        }

        if (word_skippable(source, held)) {
            held += 1;

            continue;
        }

        if (word_in(word, &.{ "(", ")", ";" })) {
            at += 1;

            continue;
        }

        return false;
    }

    while (word_skippable(source, held)) {
        assert(held < source.len);

        held += 1;
    }

    return held == source.len;
}

fn lines_of(bytes: []const u8, first: u32, last: u32) []const u8 {
    assert(first <= last);
    assert(bytes.len <= std.math.maxInt(u32));

    var line: u32 = 0;
    var start: usize = 0;
    var end: usize = bytes.len;

    for (bytes, 0..) |byte, offset| {
        if (byte != '\n') continue;

        line += 1;

        if (line == first) start = offset + 1;

        if (line == last + 1) {
            end = offset + 1;

            break;
        }
    }

    assert(start <= end);

    return bytes[start..end];
}

test "formatting formatted output changes nothing" {
    const gpa = std.testing.allocator;
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var first: Buffer = try .init(gpa, out_bytes_max);
    defer first.deinit(gpa);

    var second: Buffer = try .init(gpa, out_bytes_max);
    defer second.deinit(gpa);

    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    for (found.items) |fixture| {
        held.dialect = dialect_of(fixture.name);

        held.format(fixture.source, &first) catch continue;

        const once = first.const_slice();
        const outcome = held.format(once, &second);

        try require(is_complete(outcome), "{s}", .{fixture.name});
        try expect_text(fixture.name, "is not idempotent", once, second.const_slice());
    }
}

test "formatting keeps every token it was given" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    for (found.items) |fixture| {
        held.dialect = dialect_of(fixture.name);

        held.format(fixture.source, &out) catch continue;

        _ = arena.reset(.retain_capacity);

        const allocator = arena.allocator();
        const before = try related(allocator, try held.kinds(allocator, fixture.source));
        const after = try related(allocator, try held.kinds(allocator, out.const_slice()));

        try require(terminated(before, after), "{s} lost or gained a token", .{fixture.name});
    }
}

test "formatting keeps every word it was given" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    for (found.items) |fixture| {
        held.dialect = dialect_of(fixture.name);

        held.format(fixture.source, &out) catch continue;

        _ = arena.reset(.retain_capacity);

        const allocator = arena.allocator();
        const before = try words_related(allocator, try held.words(allocator, fixture.source));
        const after = try words_related(allocator, try held.words(allocator, out.const_slice()));

        try require(
            word_ended(before, after),
            "{s} split, joined, lost, or gained a word",
            .{fixture.name},
        );
    }
}

test "formatting keeps every comment it was given" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    for (found.items) |fixture| {
        held.dialect = dialect_of(fixture.name);

        held.format(fixture.source, &out) catch continue;

        _ = arena.reset(.retain_capacity);

        const printed = out.const_slice();

        try expect_kept(&held, arena.allocator(), fixture.source, printed, fixture.name);
    }
}

test "a dump writes the formatted fixtures" {
    const gpa = std.testing.allocator;
    var root_bytes: [environment.value_bytes_max]u8 = undefined;
    const root = environment.get(dump_variable, &root_bytes) orelse return;
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    for (found.items) |fixture| {
        held.dialect = dialect_of(fixture.name);

        held.format(fixture.source, &out) catch continue;

        var path_buffer: [path_bytes_max]u8 = undefined;
        const path = try std.mem.print(&path_buffer, "{s}/{s}", .{ root, fixture.name });
        const file: std.Io.Dir.WriteFileOptions = .{ .sub_path = path, .data = out.const_slice() };

        assert(path.len > fixture.name.len);

        try std.Io.Dir.cwd().writeFile(std.testing.io, file);
    }
}

test "every tsx fixture is formatted or refused by its own row" {
    const gpa = std.testing.allocator;
    var carried = try oracle.residue_of(gpa, residue_name, &every_category);
    defer carried.deinit(gpa);

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    var walked: u32 = 0;

    for (found.items) |fixture| {
        held.dialect = dialect_of(fixture.name);

        if (!held.dialect.is_tsx()) continue;

        walked += 1;

        const outcome = held.format(fixture.source, &out);
        if (is_complete(outcome)) continue;

        try require(is_refused(outcome), "{s}", .{fixture.name});

        const named = carried.contains(fixture.name);

        try require(named, "{s} is refused and no residue row names it", .{fixture.name});
    }

    try require(walked == tsx_fixture_count, "the tsx fixtures are not walked", .{});
}

test "the formatted output matches the oracle modulo residue" {
    const gpa = std.testing.allocator;
    var carried = try oracle.residue_of(gpa, residue_name, &every_category);
    defer carried.deinit(gpa);

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    var compared: u32 = 0;

    for (found.items) |fixture| {
        held.dialect = dialect_of(fixture.name);

        if (carried.contains(fixture.name)) continue;

        const outcome = held.format(fixture.source, &out);
        const refused = "{s} is refused and no residue row names it";

        try require(is_complete(outcome), refused, .{fixture.name});

        const golden = try read_under(gpa, golden_root, fixture.name);
        defer gpa.free(golden);

        const message = "diverges from biome and no residue row names it";

        try expect_text(fixture.name, message, golden, out.const_slice());

        compared += 1;
    }

    try require(
        compared >= floor.fixture_format_typescript,
        "the TypeScript fixtures lost a formatting: {d} compared, floor {d}",
        .{ compared, floor.fixture_format_typescript },
    );
}

test "every residue row names a fixture that diverges" {
    const gpa = std.testing.allocator;
    var carried = try oracle.residue_of(gpa, residue_name, &every_category);
    defer carried.deinit(gpa);

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    for (carried.fixtures.items) |name| {
        const source = try read_under(gpa, fixture_root, name);
        defer gpa.free(source);

        held.dialect = dialect_of(name);

        held.format(source, &out) catch continue;

        const golden = try read_under(gpa, golden_root, name);
        defer gpa.free(golden);

        const diverged = !std.mem.eql(u8, out.const_slice(), golden);

        try require(diverged, "{s} matches biome and needs no residue row", .{name});
    }
}

test "a file that does not parse is refused" {
    const gpa = std.testing.allocator;
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    try std.testing.expectError(error.SourceInvalid, held.format("function f( {\n", &out));
    try std.testing.expect(out.empty());
}

test "a property key drops the quotes it does not need" {
    const cases = [_]Case{
        .{ .source = "const o = { \"a\": 1 };\n", .wanted = "const o = { a: 1 };\n" },
        .{ .source = "const o = { \"a-b\": 1 };\n", .wanted = "const o = { \"a-b\": 1 };\n" },
        .{ .source = "const o = { \"0\": 1 };\n", .wanted = "const o = { \"0\": 1 };\n" },
        .{ .source = "const o = { \"new\": 1 };\n", .wanted = "const o = { \"new\": 1 };\n" },
        .{ .source = "const o = { \"default\": 1 };\n", .wanted = "const o = { default: 1 };\n" },
        .{ .source = "const o = { \"$_a9\": 1 };\n", .wanted = "const o = { $_a9: 1 };\n" },
        .{ .source = "type T = { \"a\"?: string };\n", .wanted = "type T = { a?: string };\n" },
        .{
            .source = "const o = held ? \"a\" : \"b\";\n",
            .wanted = "const o = held ? \"a\" : \"b\";\n",
        },
    };

    try expect_cases(&cases);
}

test "a number takes the form biome writes" {
    const cases = [_]Case{
        .{ .source = "a = 0.90;\n", .wanted = "a = 0.9;\n" },
        .{ .source = "a = 1.0;\n", .wanted = "a = 1.0;\n" },
        .{ .source = "a = 1.00;\n", .wanted = "a = 1.0;\n" },
        .{ .source = "a = .5;\n", .wanted = "a = 0.5;\n" },
        .{ .source = "a = 5.;\n", .wanted = "a = 5;\n" },
        .{ .source = "a = 0XABCDEF;\n", .wanted = "a = 0xabcdef;\n" },
        .{ .source = "a = 1E+05;\n", .wanted = "a = 1e5;\n" },
        .{ .source = "a = 1e-5;\n", .wanted = "a = 1e-5;\n" },
        .{ .source = "a = 0.1e0;\n", .wanted = "a = 0.1;\n" },
        .{ .source = "a = 1_000_000;\n", .wanted = "a = 1_000_000;\n" },
        .{ .source = "a = 0XFFn;\n", .wanted = "a = 0xffn;\n" },
        .{ .source = "a = 1..toString();\n", .wanted = "a = 1..toString();\n" },
    };

    try expect_cases(&cases);
}

test "a call hugs the bracket its last argument opens" {
    const gpa = std.testing.allocator;

    const hugged = "vscode.Uri.from({ scheme: \"copilotcli\", " ++
        "path: \"/untitled-temp-steering-resource-held\" });\n";

    const wanted = "vscode.Uri.from({\n" ++
        "    scheme: \"copilotcli\",\n" ++
        "    path: \"/untitled-temp-steering-resource-held\",\n" ++
        "});\n";

    const parted = "assert.deepStrictEqual({ status: resultOfTheRun.status }, " ++
        "{ status: expectedRun.status });\n";

    const owed = "assert.deepStrictEqual(\n" ++
        "    { status: resultOfTheRun.status },\n" ++
        "    { status: expectedRun.status },\n" ++
        ");\n";

    var session: Session = undefined;

    try session.init(gpa);
    defer session.deinit(gpa);

    try session.expect(hugged, wanted);
    try session.expect(parted, owed);
}

test "a property writes its value under a key wide enough to pay for it" {
    const gpa = std.testing.allocator;

    const broken = "const o = {\n" ++
        "    layerbreaker: \"Bad layering. You are not allowed to access this from over here, " ++
        "allowed\",\n" ++
        "};\n";

    const wanted = "const o = {\n" ++
        "    layerbreaker:\n" ++
        "        \"Bad layering. You are not allowed to access this from over here, allowed\",\n" ++
        "};\n";

    const slight = "const o = {\n" ++
        "    amdX: \"Bad layering. You are not allowed to access this from over here, " ++
        "allowed thing\",\n" ++
        "};\n";

    var session: Session = undefined;

    try session.init(gpa);
    defer session.deinit(gpa);

    try session.expect(broken, wanted);
    try session.expect(slight, slight);
}

test "a body parts from the brace that holds it" {
    const cases = [_]Case{
        .{ .source = "if (x) { y(); }\n", .wanted = "if (x) {\n    y();\n}\n" },
        .{ .source = "class C { m() {} }\n", .wanted = "class C {\n    m() {}\n}\n" },
        .{ .source = "const o = { a: 1 };\n", .wanted = "const o = { a: 1 };\n" },
        .{
            .source = "type F = (a: string) => { b: 1 };\n",
            .wanted = "type F = (a: string) => { b: 1 };\n",
        },
        .{
            .source = "type U = \"a\" | { t: { x: 1 } };\n",
            .wanted = "type U = \"a\" | { t: { x: 1 } };\n",
        },
        .{
            .source = "function f(): T { return 1; }\n",
            .wanted = "function f(): T {\n    return 1;\n}\n",
        },
        .{
            .source = "interface I { a: string; b: number }\n",
            .wanted = "interface I {\n    a: string;\n    b: number;\n}\n",
        },
        .{ .source = "enum E { A, B }\n", .wanted = "enum E {\n    A,\n    B,\n}\n" },
        .{
            .source = "function g() { a(); b(); }\n",
            .wanted = "function g() {\n    a();\n    b();\n}\n",
        },
    };

    try expect_cases(&cases);
}

test "a clause parts from the statement it qualifies" {
    const gpa = std.testing.allocator;

    const source = "function f() {\n" ++
        "\tswitch (v) { case \"a\": run(); case \"b\": { g(); } default: h(); }\n" ++
        "}\n";

    const wanted = "function f() {\n" ++
        "    switch (v) {\n" ++
        "        case \"a\":\n" ++
        "            run();\n" ++
        "        case \"b\": {\n" ++
        "            g();\n" ++
        "        }\n" ++
        "        default:\n" ++
        "            h();\n" ++
        "    }\n" ++
        "}\n";

    const keyed = "const o = { default: { id: \"\" }, case: 1 };\n";
    var session: Session = undefined;

    try session.init(gpa);
    defer session.deinit(gpa);

    try session.expect(source, wanted);
    try session.expect(keyed, keyed);
}

test "a signature parts where its parameters declare properties" {
    const gpa = std.testing.allocator;

    const parted = "class A {\n" ++
        "    constructor(public a: any, public b: any) {}\n" ++
        "}\n";

    const wanted = "class A {\n" ++
        "    constructor(\n" ++
        "        public a: any,\n" ++
        "        public b: any,\n" ++
        "    ) {}\n" ++
        "}\n";

    const lone = "class B {\n" ++
        "    constructor(private readonly x: T) {}\n" ++
        "}\n";

    var session: Session = undefined;

    try session.init(gpa);
    defer session.deinit(gpa);

    try session.expect(parted, wanted);
    try session.expect(lone, lone);
}

test "a member spelled as a word of the language still names a call" {
    const source = "const carried = Registry.as<IConfigurationRegistry>(" ++
        "ConfigurationExtensions.Configuration);\n";

    const wanted = "const carried = Registry.as<IConfigurationRegistry>(\n" ++
        "    ConfigurationExtensions.Configuration,\n" ++
        ");\n";

    try expect_formatted(source, wanted);
}

test "a type writes its members where the source put them" {
    const source = "interface I {\n" ++
        "    comment: \"Optional details about how the action was run, e.g which keybinding\";\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a header parts at the operators its condition holds" {
    const gpa = std.testing.allocator;

    const chained = "function f() {\n" ++
        "    if (typeof carriedGlobal !== \"undefined\" && " ++
        "typeof carriedGlobal.process !== \"undefined\") {\n" ++
        "        a();\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "function f() {\n" ++
        "    if (\n" ++
        "        typeof carriedGlobal !== \"undefined\" &&\n" ++
        "        typeof carriedGlobal.process !== \"undefined\"\n" ++
        "    ) {\n" ++
        "        a();\n" ++
        "    }\n" ++
        "}\n";

    const claused = "function f() {\n" ++
        "    for (let i = idPath.length - 1; " ++
        "!ct.isCancellationRequested && i >= expandToLevel;) {\n" ++
        "        g();\n" ++
        "    }\n" ++
        "}\n";

    const owed = "function f() {\n" ++
        "    for (\n" ++
        "        let i = idPath.length - 1;\n" ++
        "        !ct.isCancellationRequested && i >= expandToLevel;\n" ++
        "    ) {\n" ++
        "        g();\n" ++
        "    }\n" ++
        "}\n";

    var session: Session = undefined;

    try session.init(gpa);
    defer session.deinit(gpa);

    try session.expect(chained, wanted);
    try session.expect(claused, owed);
}

test "a comment ahead of a conditional operator leads the branch after it" {
    const source = "const a = found\n" ++
        "    // c\n" ++
        "    ? one\n" ++
        "    : two;\n" ++
        "const top = maxTop > 20 ? // c\n" ++
        "    clamp(min, diff, maxTop) :\n" ++
        "    min;\n";

    const wanted = "const a = found\n" ++
        "    ? // c\n" ++
        "      one\n" ++
        "    : two;\n" ++
        "const top =\n" ++
        "    maxTop > 20\n" ++
        "        ? // c\n" ++
        "          clamp(min, diff, maxTop)\n" ++
        "        : min;\n";

    try expect_formatted(source, wanted);
}

test "a template keeps the characters that spell an operator" {
    const a55: [55]u8 = @splat('a');

    const source = "const f = `a${x}-` + `b`;\n" ++
        "const filename = `./bin/${arch}-` + `${abi}/client.node/" ++ a55 ++ "`;\n";

    const wanted = "const f = `a${x}-` + `b`;\n" ++
        "const filename =\n" ++
        "    `./bin/${arch}-` +\n" ++
        "    `${abi}/client.node/" ++ a55 ++ "`;\n";

    try expect_formatted(source, wanted);
}

test "an operator abuts the value it reads" {
    const source = "const x = ! (await f());\n" ++
        "const y = - (a + b);\n" ++
        "function g() {\n" ++
        "    return nodejs(platform, arch)!\n" ++
        "        .pipe(dest);\n" ++
        "}\n";

    const wanted = "const x = !(await f());\n" ++
        "const y = -(a + b);\n" ++
        "function g() {\n" ++
        "    return nodejs(platform, arch)!.pipe(dest);\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a brace after a statement word opens no body" {
    const source = "function f(): T {}\nconst { a, b } = g();\n";

    try expect_formatted(source, source);
}

test "a comparison opens no type argument list" {
    const source = "const q = {\n" ++
        "    c: size < 50,\n" ++
        "    d: 1,\n" ++
        "};\n" ++
        "function f() {\n" ++
        "    for (let j = 0, n = lines[i].commentStrOffset; " ++
        "column < minVisibleColumn && j < n; j++) {\n" ++
        "        a();\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "const q = {\n" ++
        "    c: size < 50,\n" ++
        "    d: 1,\n" ++
        "};\n" ++
        "function f() {\n" ++
        "    for (\n" ++
        "        let j = 0, n = lines[i].commentStrOffset;\n" ++
        "        column < minVisibleColumn && j < n;\n" ++
        "        j++\n" ++
        "    ) {\n" ++
        "        a();\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a comment leads a line of the body it stands in" {
    const a38: [38]u8 = @splat('a');
    const b28: [28]u8 = @splat('b');

    const source = "function f() {\n" ++
        "    return !!" ++ a38 ++ ".length && " ++ b28 ++ ".some((resource) => {\n" ++
        "        // c\n" ++
        "        return resource;\n" ++
        "    });\n" ++
        "}\n" ++
        "class T {\n" ++
        "    get onChange(): Event<boolean /* key */> { return this._onChange.event; }\n" ++
        "}\n";

    const wanted = "function f() {\n" ++
        "    return (\n" ++
        "        !!" ++ a38 ++ ".length &&\n" ++
        "        " ++ b28 ++ ".some((resource) => {\n" ++
        "            // c\n" ++
        "            return resource;\n" ++
        "        })\n" ++
        "    );\n" ++
        "}\n" ++
        "class T {\n" ++
        "    get onChange(): Event<boolean /* key */> {\n" ++
        "        return this._onChange.event;\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a tuple type drops the blank lines between its elements" {
    const source = "export type J = [\n    number,\n\n    string,\n];\n";
    const wanted = "export type J = [number, string];\n";

    try expect_formatted(source, wanted);
}

test "an operand too wide for its line still ends it with the operator" {
    const source = "function f() {\n" ++
        "    const markdown = \"See [the docs](https://example.com/docs), " ++
        "[mail us](mailto:team@example.com), \"\n" ++
        "        + \"[details](#details).\";\n" ++
        "}\n";

    const wanted = "function f() {\n" ++
        "    const markdown =\n" ++
        "        \"See [the docs](https://example.com/docs), " ++
        "[mail us](mailto:team@example.com), \" +\n" ++
        "        \"[details](#details).\";\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a modifier word read as a value declares no property" {
    const source = "function f() {\n" ++
        "    merged.set(mergeKey(override.name, override.version), injected);\n" ++
        "}\n" ++
        "export const m: {\n" ++
        "    value: X;\n" ++
        "} = {\n" ++
        "    value: 1,\n" ++
        "};\n";

    try expect_formatted(source, source);
}

test "a modifier run reads the same in any order and loses no word" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    const allocator = arena.allocator();
    const written = try held.kinds(allocator, "class A {\n    abstract static f();\n}\n");
    const sorted = try held.kinds(allocator, "class A {\n    static abstract f();\n}\n");
    const lost = try held.kinds(allocator, "class A {\n    abstract f();\n}\n");
    const named = try held.kinds(allocator, "class A {\n    readonly static;\n}\n");
    const flipped = try held.kinds(allocator, "class A {\n    static readonly;\n}\n");
    const broken = try held.kinds(allocator, "class A {\n    static accessor\n    bar;\n}\n");
    const separated = try held.kinds(allocator, "class A {\n    static accessor;\n    bar;\n}\n");

    try std.testing.expect(terminated(written, sorted));
    try std.testing.expect(!terminated(written, lost));
    try std.testing.expect(!terminated(named, flipped));
    try std.testing.expect(terminated(broken, separated));
}

test "a conditional type lays out as a conditional expression does" {
    const source = "type A<T> = T extends string ? \"STRING\" : T extends number ? \"NUMBER\" : " ++
        "T extends boolean ? \"BOOLEAN\" : never;\n" ++
        "type B<T> = T extends string\n" ++
        "    ? \"STRING\"\n" ++
        "    : never;\n";

    const wanted = "type A<T> = T extends string\n" ++
        "    ? \"STRING\"\n" ++
        "    : T extends number\n" ++
        "      ? \"NUMBER\"\n" ++
        "      : T extends boolean\n" ++
        "        ? \"BOOLEAN\"\n" ++
        "        : never;\n" ++
        "type B<T> = T extends string ? \"STRING\" : never;\n";

    try expect_formatted(source, wanted);
}

test "a statement reads past the comments and casts around it" {
    const a29: [29]u8 = @splat('a');
    const b34: [34]u8 = @splat('b');
    const c22: [22]u8 = @splat('c');

    const source = "function f(x: number) {\n" ++
        "    switch (x) {\n" ++
        "        case 1: return 2; // missing\n" ++
        "        case 2: return 3;\n" ++
        "    }\n" ++
        "}\n" ++
        "class A {\n" ++
        "    async getDirty(): Promise<(IWorkspaceBackupInfo | " ++
        "IFolderBackupInfoLongerNameHere)[]> { return []; }\n" ++
        "}\n" ++
        "function g() {\n" ++
        "    return " ++ a29 ++ " || " ++ b34 ++ " || " ++ c22 ++ " /* c */;\n" ++
        "}\n" ++
        "const foldRange = (from: number) =>\n" ++
        "    <FoldRange>{\n" ++
        "        startLineNumber: from,\n" ++
        "        source\n" ++
        "    };\n";

    const wanted = "function f(x: number) {\n" ++
        "    switch (x) {\n" ++
        "        case 1:\n" ++
        "            return 2; // missing\n" ++
        "        case 2:\n" ++
        "            return 3;\n" ++
        "    }\n" ++
        "}\n" ++
        "class A {\n" ++
        "    async getDirty(): Promise<\n" ++
        "        (IWorkspaceBackupInfo | IFolderBackupInfoLongerNameHere)[]\n" ++
        "    > {\n" ++
        "        return [];\n" ++
        "    }\n" ++
        "}\n" ++
        "function g() {\n" ++
        "    return (\n" ++
        "        " ++ a29 ++ " ||\n" ++
        "        " ++ b34 ++ " ||\n" ++
        "        " ++ c22 ++ " /* c */\n" ++
        "    );\n" ++
        "}\n" ++
        "const foldRange = (from: number) =>\n" ++
        "    <FoldRange>{\n" ++
        "        startLineNumber: from,\n" ++
        "        source,\n" ++
        "    };\n";

    try expect_formatted(source, wanted);
}

test "a union member stands on its own bar and an awaited loop keeps its empty body" {
    const a32: [32]u8 = @splat('A');
    const b41: [41]u8 = @splat('B');
    const c36: [36]u8 = @splat('C');

    const source = "type ConsoleText = " ++ a32 ++ " |\n" ++
        b41 ++ " |\n" ++
        c36 ++ ";\n" ++
        "async function f() {\n" ++
        "    for await (const c of r) {\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "type ConsoleText =\n" ++
        "    | " ++ a32 ++ "\n" ++
        "    | " ++ b41 ++ "\n" ++
        "    | " ++ c36 ++ ";\n" ++
        "async function f() {\n" ++
        "    for await (const c of r) {\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an annotation colon keeps no gap the source left" {
    const source = "function g(a : number) : string {\n    return \"\";\n}\n";
    const wanted = "function g(a: number): string {\n    return \"\";\n}\n";

    try expect_formatted(source, wanted);
}

test "a nested ternary keeps the blanks around the colon that closes the outer one" {
    const source = "const f = q ? y ? 2 : 3 : 4;\nconst g = q ? 1 : y ? 2 : 3;\n";
    const wanted = "const f = q ? (y ? 2 : 3) : 4;\nconst g = q ? 1 : y ? 2 : 3;\n";

    try expect_formatted(source, wanted);
}

test "a string takes the quote biome prefers" {
    const cases = [_]Case{
        .{ .source = "a = 'x';\n", .wanted = "a = \"x\";\n" },
        .{ .source = "a = \"x\";\n", .wanted = "a = \"x\";\n" },
        .{ .source = "a = 'it\\'s';\n", .wanted = "a = \"it's\";\n" },
        .{ .source = "a = 'say \"hi\"';\n", .wanted = "a = 'say \"hi\"';\n" },
        .{ .source = "a = 'both \" and \\'';\n", .wanted = "a = \"both \\\" and '\";\n" },
        .{ .source = "a = \"\\\"\";\n", .wanted = "a = '\"';\n" },
        .{ .source = "a = \"\\'\";\n", .wanted = "a = \"\\'\";\n" },
        .{ .source = "a = '\\n\\t';\n", .wanted = "a = \"\\n\\t\";\n" },
    };

    try expect_cases(&cases);
}

test "a range reads back the lines it names" {
    const gpa = std.testing.allocator;
    const source = "function f(): void {\nlet x=1;\n}\n";
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var whole: Buffer = try .init(gpa, out_bytes_max);
    defer whole.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    try held.format(source, &whole);

    const formatted = whole.const_slice();
    const span = try held.range(source, .{ .first = 1, .last = 2 }, &out);

    try std.testing.expectEqualStrings(formatted, out.const_slice());
    try std.testing.expectEqualStrings(lines_of(formatted, 1, 2), span.text(out.const_slice()));
}

test "the three relations hold over the corpus" {
    const gpa = std.testing.allocator;
    const root = corpus.named(.root) orelse return;
    var residue = try oracle.residue_of(gpa, residue_relations_name, &every_unsettled);
    defer residue.deinit(gpa);

    var files = try corpus.collect(gpa, root, source_bytes_max, corpus_selected);
    defer files.deinit(gpa);

    const stride = corpus.stride();

    files.strided(gpa, stride);

    var tally: RelationsWorker.Tally = .{ .settling = 0 };

    try stripe.run(RelationsWorker, gpa, &.{ .residue = &residue }, files.slice(), &tally);

    try require(
        stride > 1 or tally.settling == residue.fixtures.items.len,
        "{d} of the {d} residue rows name a corpus file the walk reached",
        .{ tally.settling, residue.fixtures.items.len },
    );
}

test "a class a construction reaches takes parentheses and a call" {
    const source = "const a = new class X {}();\n" ++
        "const b = new class extends Base<{}> {}(1, 2);\n" ++
        "const c = new Foo();\n";

    const wanted = "const a = new (class X {})();\n" ++
        "const b = new (class extends Base<{}> {})(1, 2);\n" ++
        "const c = new Foo();\n";

    try expect_formatted(source, wanted);
}

test "a signature holding one parameter property keeps the line it stands on" {
    const source = "class Lazy<T> {\n" ++
        "    constructor(\n" ++
        "        private readonly executor: () => T,\n" ++
        "    ) {}\n" ++
        "}\n" ++
        "class Other {\n" ++
        "    constructor(\n" ++
        "        private readonly first: () => T,\n" ++
        "        private readonly second: () => T,\n" ++
        "    ) {}\n" ++
        "}\n";

    const wanted = "class Lazy<T> {\n" ++
        "    constructor(private readonly executor: () => T) {}\n" ++
        "}\n" ++
        "class Other {\n" ++
        "    constructor(\n" ++
        "        private readonly first: () => T,\n" ++
        "        private readonly second: () => T,\n" ++
        "    ) {}\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a word the reference writes against a brace keeps the line that brace ends" {
    const source = "function f() {\n" ++
        "    if (a) {\n" ++
        "        b();\n" ++
        "    }\n" ++
        "    else {\n" ++
        "        c();\n" ++
        "    }\n" ++
        "    try {\n" ++
        "        d();\n" ++
        "    }\n" ++
        "    catch (e) {\n" ++
        "        g();\n" ++
        "    }\n" ++
        "    finally {\n" ++
        "        h();\n" ++
        "    }\n" ++
        "    do {\n" ++
        "        i();\n" ++
        "    }\n" ++
        "    while (j);\n" ++
        "    if (k) {\n" ++
        "        l();\n" ++
        "    }\n" ++
        "    while (m) {\n" ++
        "        n();\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "function f() {\n" ++
        "    if (a) {\n" ++
        "        b();\n" ++
        "    } else {\n" ++
        "        c();\n" ++
        "    }\n" ++
        "    try {\n" ++
        "        d();\n" ++
        "    } catch (e) {\n" ++
        "        g();\n" ++
        "    } finally {\n" ++
        "        h();\n" ++
        "    }\n" ++
        "    do {\n" ++
        "        i();\n" ++
        "    } while (j);\n" ++
        "    if (k) {\n" ++
        "        l();\n" ++
        "    }\n" ++
        "    while (m) {\n" ++
        "        n();\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an import list of one specifier stands on the line it opens" {
    const source = "import {\n" ++
        "    sole\n" ++
        "} from \"./held\";\n" ++
        "import {\n" ++
        "    aVeryLongSpecifierNameThatRunsOn\n" ++
        "} from \"./some/rather/long/module/path/that/runs/past/the/width\";\n";

    const wanted = "import { sole } from \"./held\";\n" ++
        "import { aVeryLongSpecifierNameThatRunsOn } from " ++
        "\"./some/rather/long/module/path/that/runs/past/the/width\";\n";

    try expect_formatted(source, wanted);
}

test "a statement the source left without one gains the separator the reference writes" {
    const source = "import fs from \"node:fs\"\n" ++
        "const a = 1\n" ++
        "let b = class {}\n" ++
        "export const c = 2\n" ++
        "export class D {}\n" ++
        "export default class E {}\n" ++
        "export function f() {}\n" ++
        "export { a }\n" ++
        "export * from \"x\"\n" ++
        "type T = { q: string }\n" ++
        "declare const g: number\n" ++
        "declare global {\n" ++
        "    const h: number\n" ++
        "}\n" ++
        "namespace N {\n" ++
        "    const i = 1\n" ++
        "}\n" ++
        "enum Q {\n" ++
        "    A,\n" ++
        "}\n" ++
        "throw new Error(\"e\")\n";

    const wanted = "import fs from \"node:fs\";\n" ++
        "const a = 1;\n" ++
        "let b = class {};\n" ++
        "export const c = 2;\n" ++
        "export class D {}\n" ++
        "export default class E {}\n" ++
        "export function f() {}\n" ++
        "export { a };\n" ++
        "export * from \"x\";\n" ++
        "type T = { q: string };\n" ++
        "declare const g: number;\n" ++
        "declare global {\n" ++
        "    const h: number;\n" ++
        "}\n" ++
        "namespace N {\n" ++
        "    const i = 1;\n" ++
        "}\n" ++
        "enum Q {\n" ++
        "    A,\n" ++
        "}\n" ++
        "throw new Error(\"e\");\n";

    try expect_formatted(source, wanted);
}

test "a type member takes its separator from the brace that holds it" {
    const source = "interface I {\n" ++
        "    name: string\n" ++
        "    go(): void\n" ++
        "    readonly z: number\n" ++
        "}\n" ++
        "class C {\n" ++
        "    field = 1\n" ++
        "    accessor acc = 2\n" ++
        "    method() {}\n" ++
        "}\n" ++
        "type T = { q: string }\n";

    const wanted = "interface I {\n" ++
        "    name: string;\n" ++
        "    go(): void;\n" ++
        "    readonly z: number;\n" ++
        "}\n" ++
        "class C {\n" ++
        "    field = 1;\n" ++
        "    accessor acc = 2;\n" ++
        "    method() {}\n" ++
        "}\n" ++
        "type T = { q: string };\n";

    try expect_formatted(source, wanted);
}

test "a parenthesis pair the reference re prints without is dropped" {
    const source = "const a = (b + c);\n" ++
        "f((d));\n" ++
        "const e = [(g)];\n" ++
        "h = (i);\n" ++
        "const j = { k: (l) };\n" ++
        "const m = ((n));\n" ++
        "throw (new Error(\"x\"));\n" ++
        "const o = p ? (q) : (r);\n";

    const wanted = "const a = b + c;\n" ++
        "f(d);\n" ++
        "const e = [g];\n" ++
        "h = i;\n" ++
        "const j = { k: l };\n" ++
        "const m = n;\n" ++
        "throw new Error(\"x\");\n" ++
        "const o = p ? q : r;\n";

    try expect_formatted(source, wanted);
}

test "a parenthesis pair the reference writes back is kept" {
    const source = "const a = (b, c);\n" ++
        "const d = (e = 1);\n" ++
        "const g = () => ({ h: 1 });\n" ++
        "const i = j ? (k ? 1 : 2) : 3;\n" ++
        "const l = (m + n) * o;\n" ++
        "const p = [...(q ?? [])];\n" ++
        "const r = (s) => (t ? 1 : 2);\n";

    try expect_formatted(source, source);
}

test "a statement ending on a dropped parenthesis still takes its separator" {
    const source = "const a = b ? c : (d || e)\n";
    const wanted = "const a = b ? c : d || e;\n";

    try expect_formatted(source, wanted);
}

test "a bracket the source parted at one separator parts at every one" {
    const source = "export type Held = {\n" ++
        "    first: string, second: number,\n" ++
        "    third: boolean,\n" ++
        "};\n";

    const wanted = "export type Held = {\n" ++
        "    first: string;\n" ++
        "    second: number;\n" ++
        "    third: boolean;\n" ++
        "};\n";

    try expect_formatted(source, wanted);
}

test "a bracket the source wrote whole keeps the line it stands on" {
    const source = "const a = { first: 1, second: 2 };\n" ++
        "const b = [\n" ++
        "    \"x\", // a remark\n" ++
        "    \"y\",\n" ++
        "];\n";

    try expect_formatted(source, source);
}

test "a type written inside an angle list is not a body the layout parts" {
    const source = "export class Held extends Base<PropsAreLongEnoughToRunPast, " ++
        "{ first: string; second: Held }[]> {\n" ++
        "    a = 1;\n" ++
        "}\n";

    const wanted = "export class Held extends Base<\n" ++
        "    PropsAreLongEnoughToRunPast,\n" ++
        "    { first: string; second: Held }[]\n" ++
        "> {\n" ++
        "    a = 1;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a list holding a rest element is one the layout owns" {
    const source = "class C {\n" ++
        "    setTimeout(callback: (...args: any[]) => void, ms: number, " ++
        "...args: any[]): Disposable {\n" ++
        "        return d;\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "class C {\n" ++
        "    setTimeout(\n" ++
        "        callback: (...args: any[]) => void,\n" ++
        "        ms: number,\n" ++
        "        ...args: any[]\n" ++
        "    ): Disposable {\n" ++
        "        return d;\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an argument list whose argument breaks parts unless the last one hugs the bracket" {
    const source = "disposables.add(input.onWillDispose(() => {\n" ++
        "    assert(true);\n" ++
        "}));\n" ++
        "disposables.add(() => {\n" ++
        "    assert(true);\n" ++
        "});\n" ++
        "setTimeout(() => {\n" ++
        "    assert(true);\n" ++
        "}, duration);\n" ++
        "useEffect(() => {\n" ++
        "    assert(true);\n" ++
        "}, [first, second]);\n";

    const wanted = "disposables.add(\n" ++
        "    input.onWillDispose(() => {\n" ++
        "        assert(true);\n" ++
        "    }),\n" ++
        ");\n" ++
        "disposables.add(() => {\n" ++
        "    assert(true);\n" ++
        "});\n" ++
        "setTimeout(() => {\n" ++
        "    assert(true);\n" ++
        "}, duration);\n" ++
        "useEffect(() => {\n" ++
        "    assert(true);\n" ++
        "}, [first, second]);\n";

    try expect_formatted(source, wanted);
}

test "an argument the bracket hugs may carry a return type or an object type" {
    const source = "const value = new Lazy<string>((): string => {\n" ++
        "    return value.value;\n" ++
        "});\n" ++
        "const set = preserve.reduce<Record<string, boolean>>((set, key) => {\n" ++
        "    set[key] = true;\n" ++
        "    return set;\n" ++
        "}, {});\n";

    try expect_formatted(source, source);
}

test "an array of lists of the same kind parts at any width" {
    const source = "const rows = [[\"name\", name], [\"country\", location]];\n" ++
        "const objs = [{ a: 1, b: 2 }, { a: 3, b: 4 }];\n" ++
        "const one = [[\"name\", name]];\n" ++
        "const mixed = [[\"a\", 1], { b: 2 }];\n" ++
        "const thin = [[\"a\"], [\"b\"]];\n";

    const wanted = "const rows = [\n" ++
        "    [\"name\", name],\n" ++
        "    [\"country\", location],\n" ++
        "];\n" ++
        "const objs = [\n" ++
        "    { a: 1, b: 2 },\n" ++
        "    { a: 3, b: 4 },\n" ++
        "];\n" ++
        "const one = [[\"name\", name]];\n" ++
        "const mixed = [[\"a\", 1], { b: 2 }];\n" ++
        "const thin = [[\"a\"], [\"b\"]];\n";

    try expect_formatted(source, wanted);
}

test "an arrow parameter list of more than one is one the layout owns" {
    const source = "const checkImport = (node: ESTree.LiteralNode, held: ESTree.NodeHeld, " ++
        "more: numbers) => {\n" ++
        "    return 1;\n" ++
        "};\n";

    const wanted = "const checkImport = (\n" ++
        "    node: ESTree.LiteralNode,\n" ++
        "    held: ESTree.NodeHeld,\n" ++
        "    more: numbers,\n" ++
        ") => {\n" ++
        "    return 1;\n" ++
        "};\n";

    try expect_formatted(source, wanted);
}

test "a return whose binaryish argument breaks takes parentheses around it" {
    const source = "function f() {\n" ++
        "    return this.lineEndOffsetByLineIndex[lineNumber - 1] - " ++
        "this.lineStartOffsetByLine[n];\n" ++
        "}\n" ++
        "function g() {\n" ++
        "    return this.lineCount === other.lineCount;\n" ++
        "}\n" ++
        "function h() {\n" ++
        "    return alpha === bravo ? charlieValueIsLong : " ++
        "deltaValueIsAlsoRatherLongHere + 1;\n" ++
        "}\n";

    const wanted = "function f() {\n" ++
        "    return (\n" ++
        "        this.lineEndOffsetByLineIndex[lineNumber - 1] - " ++
        "this.lineStartOffsetByLine[n]\n" ++
        "    );\n" ++
        "}\n" ++
        "function g() {\n" ++
        "    return this.lineCount === other.lineCount;\n" ++
        "}\n" ++
        "function h() {\n" ++
        "    return alpha === bravo ? charlieValueIsLong : " ++
        "deltaValueIsAlsoRatherLongHere + 1;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an assignment whose value is binaryish breaks after the operator" {
    const source = "const headersValuesHeld = typeof mimetype === \"string\" ? " ++
        "{ \"Content-Type\": mimetype } : {};\n";

    const wanted = "const headersValuesHeld =\n" ++
        "    typeof mimetype === \"string\" ? { \"Content-Type\": mimetype } : {};\n";

    try expect_formatted(source, wanted);
}

test "a member chain of more than two groups that does not fit parts at every group" {
    const source = "function f() {\n" ++
        "    const invalidFormatStartsWithHeldLonger = " ++
        "z.string().startsWith(\"abcd\").safeParse(\"invalidy\");\n" ++
        "    const short = a.b().c();\n" ++
        "    const twoGroups = " ++
        "someObject.property.getMatchingKernel(notebookTextModel).selected;\n" ++
        "}\n";

    const wanted = "function f() {\n" ++
        "    const invalidFormatStartsWithHeldLonger = z\n" ++
        "        .string()\n" ++
        "        .startsWith(\"abcd\")\n" ++
        "        .safeParse(\"invalidy\");\n" ++
        "    const short = a.b().c();\n" ++
        "    const twoGroups = " ++
        "someObject.property.getMatchingKernel(notebookTextModel).selected;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an accessor takes a blank before the computed name it reads" {
    const source = "class C {\n" ++
        "    get [Symbol.toStringTag](): string {\n" ++
        "        return \"C\";\n" ++
        "    }\n" ++
        "    set [Symbol.iterator](v: string) {}\n" ++
        "}\n" ++
        "function f(preserve: string[]) {\n" ++
        "    const set: Record<string, boolean> = {};\n" ++
        "    set[preserve[0]] = true;\n" ++
        "    return set;\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a word of the language used as a value hugs the dot past it" {
    const source = "declare const type: string;\nconst held = type.split(\"/\");\n";

    try expect_formatted(source, source);
}

test "a type literal is a list whose members a semicolon separates" {
    const source = "class C {\n" ++
        "    private held: { name: string; kind: string; location: Location; " ++
        "containerName: string };\n" ++
        "}\n" ++
        "const object = { first: 1, second: 2 };\n";

    const wanted = "class C {\n" ++
        "    private held: {\n" ++
        "        name: string;\n" ++
        "        kind: string;\n" ++
        "        location: Location;\n" ++
        "        containerName: string;\n" ++
        "    };\n" ++
        "}\n" ++
        "const object = { first: 1, second: 2 };\n";

    try expect_formatted(source, wanted);
}

test "a binaryish run past the width parts after every operator of its own rank" {
    const source = "const isSupported = someLongConditionName && anotherLongConditionName && " ++
        "aThirdConditionHere;\n" ++
        "function f() {\n" ++
        "    const value = alpha.beta.gamma + delta.epsilon.zeta + eta.theta.iota + " ++
        "kappa.lambda.mu;\n" ++
        "    const short = a + b;\n" ++
        "}\n";

    const wanted = "const isSupported =\n" ++
        "    someLongConditionName && anotherLongConditionName && aThirdConditionHere;\n" ++
        "function f() {\n" ++
        "    const value =\n" ++
        "        alpha.beta.gamma + delta.epsilon.zeta + eta.theta.iota + kappa.lambda.mu;\n" ++
        "    const short = a + b;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a binaryish run parts at its loosest rank and holds the operators under it" {
    const a22: [22]u8 = @splat('a');
    const b20: [20]u8 = @splat('b');
    const c20: [20]u8 = @splat('c');
    const source = "xxx.yyy = " ++ a22 ++ " + " ++ b20 ++ " * " ++ c20 ++ " + ddddddddddddd;\n";

    const wanted = "xxx.yyy =\n" ++
        "    " ++ a22 ++ " +\n" ++
        "    " ++ b20 ++ " * " ++ c20 ++ " +\n" ++
        "    ddddddddddddd;\n";

    try expect_formatted(source, wanted);
}

test "a binaryish run past a return parts inside the parentheses the layout adds" {
    const gpa = std.testing.allocator;

    const source = "class A {\n" ++
        "    isCancellationRequested(): boolean {\n" ++
        "        return this.currentRequestId !== undefined && !!this.shouldCancel && " ++
        "this.shouldCancel();\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "class A {\n" ++
        "    isCancellationRequested(): boolean {\n" ++
        "        return (\n" ++
        "            this.currentRequestId !== undefined &&\n" ++
        "            !!this.shouldCancel &&\n" ++
        "            this.shouldCancel()\n" ++
        "        );\n" ++
        "    }\n" ++
        "}\n";

    var session: Session = undefined;

    try session.init(gpa);
    defer session.deinit(gpa);

    try session.expect(source, wanted);

    session.out.clear();

    try session.expect(wanted, wanted);
}

test "a run of one operator holds where the operand behind it is the one that parts" {
    const source = "class A {\n" ++
        "    f(): void {\n" ++
        "        const controller: TerminalChatController | undefined =\n" ++
        "            terminalService.activeInstance?.getContribution(" ++
        "TerminalChatController.ID) ?? undefined;\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "class A {\n" ++
        "    f(): void {\n" ++
        "        const controller: TerminalChatController | undefined =\n" ++
        "            terminalService.activeInstance?.getContribution(\n" ++
        "                TerminalChatController.ID,\n" ++
        "            ) ?? undefined;\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a parameter list parts for a property modifier and not for a readonly type" {
    const source = "export function findMaxIdx<T>(\n" ++
        "    array: readonly T[],\n" ++
        "    comparator: Comparator<T>,\n" ++
        "): number {\n" ++
        "    return 1;\n" ++
        "}\n" ++
        "class C {\n" ++
        "    constructor(private readonly held: Held, other: Other) {}\n" ++
        "}\n";

    const wanted = "export function findMaxIdx<T>(array: readonly T[], " ++
        "comparator: Comparator<T>): number {\n" ++
        "    return 1;\n" ++
        "}\n" ++
        "class C {\n" ++
        "    constructor(\n" ++
        "        private readonly held: Held,\n" ++
        "        other: Other,\n" ++
        "    ) {}\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a template body is one element to a list whatever its substitutions lex as" {
    const gpa = std.testing.allocator;

    const source = "const nodePath = path.join(root, \".build\", \"node\", `v${version}`, " ++
        "`${platform}-${arch}`, node);\n";

    const wanted = "const nodePath = path.join(\n" ++
        "    root,\n" ++
        "    \".build\",\n" ++
        "    \"node\",\n" ++
        "    `v${version}`,\n" ++
        "    `${platform}-${arch}`,\n" ++
        "    node,\n" ++
        ");\n";

    var session: Session = undefined;

    try session.init(gpa);
    defer session.deinit(gpa);

    try session.expect(source, wanted);

    session.out.clear();

    try session.expect(wanted, wanted);
}

test "a rest parameter takes no separator and a spread argument takes one" {
    const source = "function held(firstParameterNameHere: number, " ++
        "...restOfTheParametersHere: string[]) {}\n" ++
        "element.append(...renderTheLabelWithIconsHere(theLabelToRender), " ++
        "...otherRenderedThings);\n";

    const wanted = "function held(firstParameterNameHere: number, " ++
        "...restOfTheParametersHere: string[]) {}\n" ++
        "element.append(\n" ++
        "    ...renderTheLabelWithIconsHere(theLabelToRender),\n" ++
        "    ...otherRenderedThings,\n" ++
        ");\n";

    try expect_formatted(source, wanted);
}

test "an assertion call names a call and the layout owns the arguments it opens" {
    const source = "function expectNodeLike(node: StatementNodeHere, spec: StatementNodeSpec, " ++
        "prefix = \"\") {}\n";

    const wanted = "function expectNodeLike(\n" ++
        "    node: StatementNodeHere,\n" ++
        "    spec: StatementNodeSpec,\n" ++
        "    prefix = \"\",\n" ++
        ") {}\n";

    try expect_formatted(source, wanted);
}

test "a sole arrow parameter the layout owns unless the parameter is one it hugs" {
    const source = "const checkImport = (node: ESTree.Literal & " ++
        "{ parent?: ESTree.Node & { kind?: string } }) => {};\n" ++
        "const hugged = ({ alpha, beta, gamma, delta, epsilon, zeta, eta, theta, iota }: " ++
        "Held) => {};\n" ++
        "const isTenative = (p: unknown): p is (TentativeBoundary & { inner: Held }) =>\n" ++
        "    p instanceof TentativeBoundary;\n";

    const wanted = "const checkImport = (\n" ++
        "    node: ESTree.Literal & { parent?: ESTree.Node & { kind?: string } },\n" ++
        ") => {};\n" ++
        "const hugged = ({\n" ++
        "    alpha,\n" ++
        "    beta,\n" ++
        "    gamma,\n" ++
        "    delta,\n" ++
        "    epsilon,\n" ++
        "    zeta,\n" ++
        "    eta,\n" ++
        "    theta,\n" ++
        "    iota,\n" ++
        "}: Held) => {};\n" ++
        "const isTenative = (p: unknown): p is TentativeBoundary & { inner: Held } =>\n" ++
        "    p instanceof TentativeBoundary;\n";

    try expect_formatted(source, wanted);
}

test "a call whose callee is a word of the language is a call" {
    const source = "class A extends B {\n" ++
        "    constructor() {\n" ++
        "        super(PolicyType.Boolean, name, category, minimumVersion, description, " ++
        "moduleName);\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "class A extends B {\n" ++
        "    constructor() {\n" ++
        "        super(\n" ++
        "            PolicyType.Boolean,\n" ++
        "            name,\n" ++
        "            category,\n" ++
        "            minimumVersion,\n" ++
        "            description,\n" ++
        "            moduleName,\n" ++
        "        );\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a header whose heritage clauses do not fit parts before each of them" {
    const source = "export class CompletionsObservableWorkspace extends VSCodeWorkspace " ++
        "implements ICompletionsObservableWorkspace {\n" ++
        "    x = 1;\n" ++
        "}\n" ++
        "export interface UnsupportedProtocolVersionErrorDataEx " ++
        "extends UnsupportedProtocolVersionErrorData {\n" ++
        "    z: number;\n" ++
        "}\n" ++
        "export class ValueWithChangeEventFromObservable<T> " ++
        "implements IValueWithChangeEvent<T> {\n" ++
        "    y = 2;\n" ++
        "}\n" ++
        "class Small implements Tiny {\n" ++
        "    a = 1;\n" ++
        "}\n";

    const wanted = "export class CompletionsObservableWorkspace\n" ++
        "    extends VSCodeWorkspace\n" ++
        "    implements ICompletionsObservableWorkspace\n" ++
        "{\n" ++
        "    x = 1;\n" ++
        "}\n" ++
        "export interface UnsupportedProtocolVersionErrorDataEx\n" ++
        "    extends UnsupportedProtocolVersionErrorData {\n" ++
        "    z: number;\n" ++
        "}\n" ++
        "export class ValueWithChangeEventFromObservable<T> " ++
        "implements IValueWithChangeEvent<T> {\n" ++
        "    y = 2;\n" ++
        "}\n" ++
        "class Small implements Tiny {\n" ++
        "    a = 1;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a class a new reaches measures the parenthesis the printing adds" {
    const source = "suite(\"g\", () => {\n" ++
        "\ttest(\"x\", () => {\n" ++
        "\t\tconst deserializer = new class " ++
        "implements IViewDeserializer<ISerializableView> {\n" ++
        "\t\t\tfromJSON(): number {\n" ++
        "\t\t\t\treturn 1;\n" ++
        "\t\t\t}\n" ++
        "\t\t};\n" ++
        "\t});\n" ++
        "});\n";

    const wanted = "suite(\"g\", () => {\n" ++
        "    test(\"x\", () => {\n" ++
        "        const deserializer = new (class\n" ++
        "            implements IViewDeserializer<ISerializableView>\n" ++
        "        {\n" ++
        "            fromJSON(): number {\n" ++
        "                return 1;\n" ++
        "            }\n" ++
        "        })();\n" ++
        "    });\n" ++
        "});\n";

    try expect_formatted(source, wanted);
}

test "a union type that does not fit parts before every bar it spells" {
    const source = "export type SemanticTokensProviderStyling = " ++
        "DocumentSemanticTokensProvider | DocumentRangeSemanticTokensProvider;\n" ++
        "export type Small = A | B;\n" ++
        "export type Maybe = " ++
        "SomeVeryLongReferenceTypeNameThatWouldNotFitOnOneLineAtAll | null;\n" ++
        "export interface Held {\n" ++
        "    readonly input: TabInputText | TabInputTextDiff | TabInputCustom | " ++
        "TabInputWebview | TabInputNotebook;\n" ++
        "    readonly small: A | B;\n" ++
        "}\n";

    const wanted = "export type SemanticTokensProviderStyling =\n" ++
        "    | DocumentSemanticTokensProvider\n" ++
        "    | DocumentRangeSemanticTokensProvider;\n" ++
        "export type Small = A | B;\n" ++
        "export type Maybe = " ++
        "SomeVeryLongReferenceTypeNameThatWouldNotFitOnOneLineAtAll | null;\n" ++
        "export interface Held {\n" ++
        "    readonly input:\n" ++
        "        | TabInputText\n" ++
        "        | TabInputTextDiff\n" ++
        "        | TabInputCustom\n" ++
        "        | TabInputWebview\n" ++
        "        | TabInputNotebook;\n" ++
        "    readonly small: A | B;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a member of a type body is no label however the source parted it" {
    const source = "export interface Alpha {\n" ++
        "    source:\n" ++
        "        | \"aaa\"\n" ++
        "        | \"bbb\";\n" ++
        "    other?: string;\n" ++
        "}\n";

    const wanted = "export interface Alpha {\n" ++
        "    source: \"aaa\" | \"bbb\";\n" ++
        "    other?: string;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an assignment whose value is a template never breaks past its operator" {
    const source = "function f(fn: string) {\n" ++
        "    const query = `CallExpression[callee.property.name='${fn}'], " ++
        "CallExpression[callee.name='${fn}']`;\n" ++
        "    const heldValue = someCallThatIsQuiteLongIndeed(alpha, beta) + " ++
        "anotherCallHere(gamma);\n" ++
        "}\n";

    const wanted = "function f(fn: string) {\n" ++
        "    const query = `CallExpression[callee.property.name='${fn}'], " ++
        "CallExpression[callee.name='${fn}']`;\n" ++
        "    const heldValue =\n" ++
        "        someCallThatIsQuiteLongIndeed(alpha, beta) + anotherCallHere(gamma);\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an optional members parameter list is one the layout owns" {
    const source = "export interface IHeld {\n" ++
        "    notifyQuestionCarouselAnswer?(toolCallId: string, question: IQuestion, " ++
        "response: UserInputResponse): Promise<void>;\n" ++
        "}\n";

    const wanted = "export interface IHeld {\n" ++
        "    notifyQuestionCarouselAnswer?(\n" ++
        "        toolCallId: string,\n" ++
        "        question: IQuestion,\n" ++
        "        response: UserInputResponse,\n" ++
        "    ): Promise<void>;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a ternarys branches stand one level in from the line its test opens on" {
    const source = "function f() {\n" ++
        "\tif (match) {\n" ++
        "\t\tconst directives = this.client.apiVersion.gte(API.v390)\n" ++
        "\t\t\t? tsDirectives390\n" ++
        "\t\t\t: tsDirectives;\n" ++
        "\t\treturn directives;\n" ++
        "\t}\n" ++
        "}\n" ++
        "const heldLongerName = alphaConditionValue\n" ++
        "\t? betaResultValue\n" ++
        "\t: gammaConditionValue\n" ++
        "\t\t? deltaResultValue\n" ++
        "\t\t: epsilonResultValue;\n";

    const wanted = "function f() {\n" ++
        "    if (match) {\n" ++
        "        const directives = this.client.apiVersion.gte(API.v390)\n" ++
        "            ? tsDirectives390\n" ++
        "            : tsDirectives;\n" ++
        "        return directives;\n" ++
        "    }\n" ++
        "}\n" ++
        "const heldLongerName = alphaConditionValue\n" ++
        "    ? betaResultValue\n" ++
        "    : gammaConditionValue\n" ++
        "      ? deltaResultValue\n" ++
        "      : epsilonResultValue;\n";

    try expect_formatted(source, wanted);
}

test "an object type in a type argument list is one the layout parts" {
    const source = "export interface IHeld {\n" ++
        "    readonly onDidChangeFullScreen: Event<{ window: IAuxiliaryWindow; " ++
        "fullscreen: boolean }>;\n" ++
        "    readonly small: Event<{ a: A }>;\n" ++
        "    held(selector: string, xoffset?: number): Promise<{ x: number; y: number }>;\n" ++
        "}\n";

    const wanted = "export interface IHeld {\n" ++
        "    readonly onDidChangeFullScreen: Event<{\n" ++
        "        window: IAuxiliaryWindow;\n" ++
        "        fullscreen: boolean;\n" ++
        "    }>;\n" ++
        "    readonly small: Event<{ a: A }>;\n" ++
        "    held(selector: string, xoffset?: number): Promise<{ x: number; y: number }>;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a union of objects that each fit parts before every bar" {
    const source = "export type Account = { type: \"apiKey\" } | " ++
        "{ type: \"chatgpt\"; email: string | null } | " ++
        "{ type: \"amazonBedrock\"; region: string };\n";

    const wanted = "export type Account =\n" ++
        "    | { type: \"apiKey\" }\n" ++
        "    | { type: \"chatgpt\"; email: string | null }\n" ++
        "    | { type: \"amazonBedrock\"; region: string };\n";

    try expect_formatted(source, wanted);
}

test "a union that fits is written flat and drops the bar the source spelled" {
    const source = "export namespace Held {\n" ++
        "    export type ElicitRequestParams =\n" ++
        "        | ElicitRequestFormParams\n" ++
        "        | ElicitRequestURLParams;\n" ++
        "}\n";

    const wanted = "export namespace Held {\n" ++
        "    export type ElicitRequestParams = " ++
        "ElicitRequestFormParams | ElicitRequestURLParams;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a calls arguments that compose functions part at every comma" {
    const source = "f(a.map((t) => t), b);\n" ++
        "f(a, (b) => b);\n" ++
        "f(new Foo(() => {}), b);\n" ++
        "f(a.b.c(x.map((t) => t)), y);\n" ++
        "f(a.map((t) => t));\n" ++
        "check(\"held\", !out.some((u) => u.name === \"good\"));\n" ++
        "useEffect(() => {\n" ++
        "    doThing();\n" ++
        "}, [a, b]);\n";

    const wanted = "f(\n" ++
        "    a.map((t) => t),\n" ++
        "    b,\n" ++
        ");\n" ++
        "f(a, (b) => b);\n" ++
        "f(new Foo(() => {}), b);\n" ++
        "f(a.b.c(x.map((t) => t)), y);\n" ++
        "f(a.map((t) => t));\n" ++
        "check(\"held\", !out.some((u) => u.name === \"good\"));\n" ++
        "useEffect(() => {\n" ++
        "    doThing();\n" ++
        "}, [a, b]);\n";

    try expect_formatted(source, wanted);
}

test "an arrow body that is a call stands on a line of its own when it does not fit" {
    const source = "const matched = targets.some((pattern) => " ++
        "minimatch(relativeFilenameHere, patternLonger));\n" ++
        "const held = targets.some(alpha, (pattern) => minimatch(relative, pattern));\n" ++
        "const wide = targets.some((pattern) => key.startsWith(\"bs\") && " ++
        "!key.startsWith(\"bsConfig\"));\n" ++
        "export function f<T>(g: () => Promise<T>): void {}\n";

    const wanted = "const matched = targets.some((pattern) =>\n" ++
        "    minimatch(relativeFilenameHere, patternLonger),\n" ++
        ");\n" ++
        "const held = targets.some(alpha, (pattern) => minimatch(relative, pattern));\n" ++
        "const wide = targets.some(\n" ++
        "    (pattern) => key.startsWith(\"bs\") && !key.startsWith(\"bsConfig\"),\n" ++
        ");\n" ++
        "export function f<T>(g: () => Promise<T>): void {}\n";

    try expect_formatted(source, wanted);
}

test "a call taking a function body is one the layout owns" {
    const source = "suite(\"x\", () => {\n" ++
        "    test(\"a name that is quite long indeed and pushes the line over the width\", " ++
        "() => {\n" ++
        "        assert.strictEqual(graph.lookup(normalize(path.join(tmpDir, \"a.js\"))), " ++
        "undefined);\n" ++
        "    });\n" ++
        "});\n";

    const wanted = "suite(\"x\", () => {\n" ++
        "    test(\"a name that is quite long indeed and pushes the line over the width\", " ++
        "() => {\n" ++
        "        assert.strictEqual(\n" ++
        "            graph.lookup(normalize(path.join(tmpDir, \"a.js\"))),\n" ++
        "            undefined,\n" ++
        "        );\n" ++
        "    });\n" ++
        "});\n";

    try expect_formatted(source, wanted);
}

test "a first argument that is a function hugs the short one behind it" {
    const source = "function d() {\n" ++
        "    timeout = setTimeout(\n" ++
        "        () => {\n" ++
        "            timeout = undefined;\n" ++
        "            fn();\n" ++
        "        },\n" ++
        "        duration,\n" ++
        "    );\n" ++
        "    const set = preserve.reduce(\n" ++
        "        (set, key) => {\n" ++
        "            set[key] = true;\n" ++
        "            return set;\n" ++
        "        },\n" ++
        "        {},\n" ++
        "    );\n" ++
        "}\n";

    const wanted = "function d() {\n" ++
        "    timeout = setTimeout(() => {\n" ++
        "        timeout = undefined;\n" ++
        "        fn();\n" ++
        "    }, duration);\n" ++
        "    const set = preserve.reduce((set, key) => {\n" ++
        "        set[key] = true;\n" ++
        "        return set;\n" ++
        "    }, {});\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a test calls arguments are written on the line the call opens" {
    const source = "suite(\"x\", () => {\n" ++
        "    test(\n" ++
        "        \"diffGeneratedTrees reports content, missing, and extra files " ++
        "(README ignored)\",\n" ++
        "        () => {\n" ++
        "            const commit = 1;\n" ++
        "        },\n" ++
        "    );\n" ++
        "    notATest(\n" ++
        "        \"this is not a test call and it is quite long indeed yes it is truly\",\n" ++
        "        () => {\n" ++
        "            doThing();\n" ++
        "        },\n" ++
        "    );\n" ++
        "});\n";

    const wanted = "suite(\"x\", () => {\n" ++
        "    test(\"diffGeneratedTrees reports content, missing, and extra files " ++
        "(README ignored)\", () => {\n" ++
        "        const commit = 1;\n" ++
        "    });\n" ++
        "    notATest(\n" ++
        "        \"this is not a test call and it is quite long indeed yes it is truly\",\n" ++
        "        () => {\n" ++
        "            doThing();\n" ++
        "        },\n" ++
        "    );\n" ++
        "});\n";

    try expect_formatted(source, wanted);
}

test "a line comment never takes the token behind it onto its line" {
    const source = "function f() {\n" ++
        "    if (a || // note\n" ++
        "        !b\n" ++
        "    ) {\n" ++
        "        return;\n" ++
        "    }\n" ++
        "    g( // note\n" ++
        "        x);\n" ++
        "    const y = a || // note\n" ++
        "        b;\n" ++
        "}\n";

    const wanted = "function f() {\n" ++
        "    if (\n" ++
        "        a || // note\n" ++
        "        !b\n" ++
        "    ) {\n" ++
        "        return;\n" ++
        "    }\n" ++
        "    g(\n" ++
        "        // note\n" ++
        "        x,\n" ++
        "    );\n" ++
        "    const y =\n" ++
        "        a || // note\n" ++
        "        b;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a template hole the expression breaks is laid out from its own width" {
    const source = "const u = `${[\n" ++
        "    \"a\",\n" ++
        "    \"b\"\n" ++
        "].join(\",\")}`;\n" ++
        "function g() {\n" ++
        "    this.logService.warn(`[lifecycle] onWillShutdown is taking a long time, " ++
        "pending operations: ${Array.from(pendingJoiners).map(joiner => joiner.id)" ++
        ".join(\", \")}`);\n" ++
        "}\n" ++
        "function h() {\n" ++
        "    if (x) {\n" ++
        "        md += `|CPUs|${this._data.systemInfo.cpus}|\n" ++
        "|GPU Status|${Object.keys(this._data.systemInfo.gpuStatus).map(key => " ++
        "`${key}: ${this._data.systemInfo!.gpuStatus[key]}`).join(\"<br>\")}|\n" ++
        "|Load (avg)|${this._data.systemInfo.load}|\n" ++
        "|VM|${this._data.systemInfo.vmHint}|`;\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "const u = `${[\"a\", \"b\"].join(\",\")}`;\n" ++
        "function g() {\n" ++
        "    this.logService.warn(\n" ++
        "        `[lifecycle] onWillShutdown is taking a long time, " ++
        "pending operations: ${Array.from(\n" ++
        "            pendingJoiners,\n" ++
        "        )\n" ++
        "            .map((joiner) => joiner.id)\n" ++
        "            .join(\", \")}`,\n" ++
        "    );\n" ++
        "}\n" ++
        "function h() {\n" ++
        "    if (x) {\n" ++
        "        md += `|CPUs|${this._data.systemInfo.cpus}|\n" ++
        "|GPU Status|${Object.keys(this._data.systemInfo.gpuStatus)\n" ++
        "            .map((key) => `${key}: ${this._data.systemInfo!.gpuStatus[key]}`)\n" ++
        "            .join(\"<br>\")}|\n" ++
        "|Load (avg)|${this._data.systemInfo.load}|\n" ++
        "|VM|${this._data.systemInfo.vmHint}|`;\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an arrows return type ends at its arrow" {
    const source = "export namespace TextEdit {\n" ++
        "    export const fromCodeEdit = (edit: Proto.CodeEdit): vscode.TextEdit =>\n" ++
        "        new vscode.TextEdit(\n" ++
        "            Range.fromTextSpan(edit),\n" ++
        "            edit.newText);\n" ++
        "}\n";

    const wanted = "export namespace TextEdit {\n" ++
        "    export const fromCodeEdit = (edit: Proto.CodeEdit): vscode.TextEdit =>\n" ++
        "        new vscode.TextEdit(Range.fromTextSpan(edit), edit.newText);\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a comment behind an arrows body leaves the body hugged" {
    const source = "schema.refine(\n    (val) => {\n        return 1;\n    } // c\n);\n";
    const wanted = "schema.refine(\n    (val) => {\n        return 1;\n    }, // c\n);\n";

    try expect_formatted(source, wanted);
}

test "an empty class body gives a value no line to break" {
    const source = "function f() {\n" ++
        "    if (x) {\n" ++
        "        const instantiationService = " ++
        "new (class extends mock<IInstantiationService>() {})();\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "function f() {\n" ++
        "    if (x) {\n" ++
        "        const instantiationService =\n" ++
        "            new (class extends mock<IInstantiationService>() {})();\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an intersection breaks at every ampersand or none" {
    const source = "export type TypeScriptRequests = StandardTsServerRequests & " ++
        "NoResponseTsServerRequests & AsyncTsServerRequests;\n" ++
        "export type CodeWindow = Window & typeof globalThis & {\n" ++
        "    readonly vscodeWindowId: number;\n" ++
        "};\n" ++
        "type PickItem = vscode.QuickPickItem & ({ state: State } | " ++
        "{ setTempDisabled: boolean; aaaaaaa: 1 });\n" ++
        "export type EmbedderTerminal = IShellLaunchConfig & " ++
        "Required<Pick<IShellLaunchConfig, \"customPtyImplementation\">>;\n" ++
        "const x = y as ICodexAuthenticateHarness & ICodexGitHubEndpointChangeHarness & " ++
        "{ _githubToken?: string; _gitHubMcpServerConfiguration?: object; };\n";

    const wanted = "export type TypeScriptRequests = StandardTsServerRequests &\n" ++
        "    NoResponseTsServerRequests &\n" ++
        "    AsyncTsServerRequests;\n" ++
        "export type CodeWindow = Window &\n" ++
        "    typeof globalThis & {\n" ++
        "        readonly vscodeWindowId: number;\n" ++
        "    };\n" ++
        "type PickItem = vscode.QuickPickItem &\n" ++
        "    ({ state: State } | { setTempDisabled: boolean; aaaaaaa: 1 });\n" ++
        "export type EmbedderTerminal = IShellLaunchConfig &\n" ++
        "    Required<Pick<IShellLaunchConfig, \"customPtyImplementation\">>;\n" ++
        "const x = y as ICodexAuthenticateHarness &\n" ++
        "    ICodexGitHubEndpointChangeHarness & {\n" ++
        "        _githubToken?: string;\n" ++
        "        _gitHubMcpServerConfiguration?: object;\n" ++
        "    };\n";

    try expect_formatted(source, wanted);
}

test "a conditional return type ends at the body and takes no parameter parens" {
    const source = "function f(obj: T): T extends { a: 1 } ? R : T {\n" ++
        "    return obj;\n" ++
        "}\n" ++
        "const g = (obj: T): T extends { a: 1 } ? R : T => {\n" ++
        "    return obj;\n" ++
        "};\n" ++
        "const h = (obj: T): T extends { a: 1 } ? R : T => obj;\n";

    try expect_formatted(source, source);
}

test "a cast chain on an object parenthesises the object alone" {
    const source = "const stub = (commands: X[] = []): TreeSitterCommandParser => ({\n" ++
        "\textractCommands: async () => commands,\n" ++
        "} as unknown as TreeSitterCommandParser);\n" ++
        "const sdk = {\n" ++
        "\tcreateSdkMcpServer: async (options: { name: string }) =>\n" ++
        "\t\t({ name: options.name, instance: { __fake: true } } as unknown as " ++
        "McpSdkServerConfigWithInstance),\n" ++
        "};\n" ++
        "const a = () => ({ x: 1 } as T);\n";

    const wanted = "const stub = (commands: X[] = []): TreeSitterCommandParser =>\n" ++
        "    ({\n" ++
        "        extractCommands: async () => commands,\n" ++
        "    }) as unknown as TreeSitterCommandParser;\n" ++
        "const sdk = {\n" ++
        "    createSdkMcpServer: async (options: { name: string }) =>\n" ++
        "        ({\n" ++
        "            name: options.name,\n" ++
        "            instance: { __fake: true },\n" ++
        "        }) as unknown as McpSdkServerConfigWithInstance,\n" ++
        "};\n" ++
        "const a = () => ({ x: 1 }) as T;\n";

    try expect_formatted(source, wanted);
}

test "a list that hugs its last argument steps no level for a run inside" {
    const source = "function getPick() {\n" ++
        "\treturn Promise.race([\n" ++
        "\t\tnew Promise<T>(c => quickpick.onDidAccept(() => " ++
        "quickpick.selectedItems.length > 0 && c(quickpick.selectedItems[0]))),\n" ++
        "\t\tx,\n" ++
        "\t]);\n" ++
        "}\n";

    const wanted = "function getPick() {\n" ++
        "    return Promise.race([\n" ++
        "        new Promise<T>((c) =>\n" ++
        "            quickpick.onDidAccept(\n" ++
        "                () =>\n" ++
        "                    quickpick.selectedItems.length > 0 && " ++
        "c(quickpick.selectedItems[0]),\n" ++
        "            ),\n" ++
        "        ),\n" ++
        "        x,\n" ++
        "    ]);\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a curried calls callee list breaks when the arguments after it must" {
    const source = "Event.any(a, b)((e) => {\n" ++
        "    x();\n" ++
        "});\n" ++
        "Event.any(a, b)((e) => x());\n" ++
        "foo(a)((e) => {\n" ++
        "    x();\n" ++
        "});\n" ++
        "foo(a)(b, (e) => {\n" ++
        "    x();\n" ++
        "});\n" ++
        "foo()(() => {\n" ++
        "    x();\n" ++
        "});\n" ++
        "const y = foo(a, b)((e) => {\n" ++
        "    x();\n" ++
        "});\n" ++
        "foo(a, b)(function () {\n" ++
        "    x();\n" ++
        "});\n" ++
        "foo(a, b)({\n" ++
        "    x: 1,\n" ++
        "});\n";

    const wanted = "Event.any(\n" ++
        "    a,\n" ++
        "    b,\n" ++
        ")((e) => {\n" ++
        "    x();\n" ++
        "});\n" ++
        "Event.any(a, b)((e) => x());\n" ++
        "foo(a)((e) => {\n" ++
        "    x();\n" ++
        "});\n" ++
        "foo(a)(b, (e) => {\n" ++
        "    x();\n" ++
        "});\n" ++
        "foo()(() => {\n" ++
        "    x();\n" ++
        "});\n" ++
        "const y = foo(\n" ++
        "    a,\n" ++
        "    b,\n" ++
        ")((e) => {\n" ++
        "    x();\n" ++
        "});\n" ++
        "foo(\n" ++
        "    a,\n" ++
        "    b,\n" ++
        ")(function () {\n" ++
        "    x();\n" ++
        "});\n" ++
        "foo(\n" ++
        "    a,\n" ++
        "    b,\n" ++
        ")({\n" ++
        "    x: 1,\n" ++
        "});\n";

    try expect_formatted(source, wanted);
}

test "a new expressions callee and a keyword member are no chain or header" {
    const source = "parts.push(\n" ++
        "    new vscode.MarkdownString().appendCodeblock(displayParts.join(\" \"), " ++
        "\"typescriptttttttt\"),\n" ++
        ");\n" ++
        "export const MENU_TERMINAL_CHAT_WIDGET_TOOLBAR = " ++
        "MenuId.for(\"terminalChatWidget.toolbar\");\n";

    const wanted = "parts.push(\n" ++
        "    new vscode.MarkdownString().appendCodeblock(\n" ++
        "        displayParts.join(\" \"),\n" ++
        "        \"typescriptttttttt\",\n" ++
        "    ),\n" ++
        ");\n" ++
        "export const MENU_TERMINAL_CHAT_WIDGET_TOOLBAR = MenuId.for(\n" ++
        "    \"terminalChatWidget.toolbar\",\n" ++
        ");\n";

    try expect_formatted(source, wanted);
}

test "an empty bracket and an object return type keep their lists levels" {
    const source = "assertIntervalSearch(\n" ++
        "    24, 24,\n" ++
        "    [\n" ++
        "    ]\n" ++
        ");\n" ++
        "f(a, [\n" ++
        "]);\n" ++
        "const x = [\n" ++
        "];\n" ++
        "f(a, {\n" ++
        "});\n" ++
        "export function f(options: {\n" ++
        "\tmatchLines?: number;\n" ++
        "} | undefined): {\n" ++
        "\tmatchLines: number;\n" ++
        "} {\n" ++
        "\treturn 1;\n" ++
        "}\n";

    const wanted = "assertIntervalSearch(24, 24, []);\n" ++
        "f(a, []);\n" ++
        "const x = [];\n" ++
        "f(a, {});\n" ++
        "export function f(\n" ++
        "    options:\n" ++
        "        | {\n" ++
        "              matchLines?: number;\n" ++
        "          }\n" ++
        "        | undefined,\n" ++
        "): {\n" ++
        "    matchLines: number;\n" ++
        "} {\n" ++
        "    return 1;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a lone void type argument never breaks" {
    const source = "suite(\"x\", () => {\n" ++
        "    async function assertNoLocalHistoryEntryAddedWithSettingsConfigured(): " ++
        "Promise<void> {\n" ++
        "        x();\n" ++
        "    }\n" ++
        "    async function assertNoLocalHistoryEntryAddedWithSettingsConfigu(): " ++
        "Promise<Aaaaaaa> {\n" ++
        "        x();\n" ++
        "    }\n" ++
        "});\n";

    try expect_formatted(source, source);
}

test "a conditionals colon in an object opens no property value" {
    const source = "const o1 = { k: () => r ? s._zod : s };\n" ++
        "const o2 = { k: () => r ? s.zod.def.innerType : s };\n" ++
        "const o3 = { k: () => r ? s.zod.innerType : s };\n" ++
        "const o4 = { k: () => r ? s.innerType : s };\n" ++
        "const o5 = { k: () => r ? s.def : s };\n" ++
        "const o1 = { k: () => r ? s.type : s };\n" ++
        "const o2 = { k: () => r ? s.xType : s };\n" ++
        "const o3 = { k: () => r ? s.typex : s };\n" ++
        "const o4 = { k: () => r ? s.xtype : s };\n" ++
        "const o5 = { k: () => r ? s.aaaaaaaaaaaaa : s };\n" ++
        "const o6 = { k: () => r ? s.aaaaaaaa : s };\n";

    const wanted = "const o1 = { k: () => (r ? s._zod : s) };\n" ++
        "const o2 = { k: () => (r ? s.zod.def.innerType : s) };\n" ++
        "const o3 = { k: () => (r ? s.zod.innerType : s) };\n" ++
        "const o4 = { k: () => (r ? s.innerType : s) };\n" ++
        "const o5 = { k: () => (r ? s.def : s) };\n" ++
        "const o1 = { k: () => (r ? s.type : s) };\n" ++
        "const o2 = { k: () => (r ? s.xType : s) };\n" ++
        "const o3 = { k: () => (r ? s.typex : s) };\n" ++
        "const o4 = { k: () => (r ? s.xtype : s) };\n" ++
        "const o5 = { k: () => (r ? s.aaaaaaaaaaaaa : s) };\n" ++
        "const o6 = { k: () => (r ? s.aaaaaaaa : s) };\n";

    try expect_formatted(source, wanted);
}

test "a conditional arrow between arguments keeps its parentheses" {
    const source = "const debounced = Event.debounce(\n" ++
        "    emitter.event,\n" ++
        "    (l, e) => l ? l + 1 : 1,\n" ++
        "    0,\n" ++
        "    /*leading=*/ true,\n" ++
        ");\n" ++
        "const debounced2 = Event.debounce(emitter.event, (l, e) => l ? l + 1 : 1, 0, true, " ++
        "aaaaaaaaaaaaaaaa);\n" ++
        "foo((l, e) => l ? l + 1 : 1, 0);\n";

    const wanted = "const debounced = Event.debounce(\n" ++
        "    emitter.event,\n" ++
        "    (l, e) => (l ? l + 1 : 1),\n" ++
        "    0,\n" ++
        "    /*leading=*/ true,\n" ++
        ");\n" ++
        "const debounced2 = Event.debounce(\n" ++
        "    emitter.event,\n" ++
        "    (l, e) => (l ? l + 1 : 1),\n" ++
        "    0,\n" ++
        "    true,\n" ++
        "    aaaaaaaaaaaaaaaa,\n" ++
        ");\n" ++
        "foo((l, e) => (l ? l + 1 : 1), 0);\n";

    try expect_formatted(source, wanted);
}

test "a label and the statement it names share a line" {
    const source = "function f() {\n" ++
        "    let n = 0;\n" ++
        "\n" ++
        "    forLoop:\n" ++
        "    for (let lineNumber = startLine, lineCount = endLine; " ++
        "lineNumber <= lineCount; lineNumber++) {\n" ++
        "        continue forLoop;\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "function f() {\n" ++
        "    let n = 0;\n" ++
        "\n" ++
        "    forLoop: for (\n" ++
        "        let lineNumber = startLine, lineCount = endLine;\n" ++
        "        lineNumber <= lineCount;\n" ++
        "        lineNumber++\n" ++
        "    ) {\n" ++
        "        continue forLoop;\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a class member past a flat method body opens its own line" {
    const source = "function f() {\n" ++
        "    reg.defineInstance(IActionWidgetService, " ++
        "new class extends mock<IActionWidgetService>() { override show() { } " ++
        "override hide() { } override get isVisible() { return false; } }());\n" ++
        "    const x = class { show() { } hide() { } };\n" ++
        "    class Y { show() { } hide() { } }\n" ++
        "}\n" ++
        "export abstract class WordDistance {\n" ++
        "\tstatic readonly None = new class extends WordDistance {\n" ++
        "\t\tdistance() { return 0; }\n" ++
        "\t};\n" ++
        "}\n";

    const wanted = "function f() {\n" ++
        "    reg.defineInstance(\n" ++
        "        IActionWidgetService,\n" ++
        "        new (class extends mock<IActionWidgetService>() {\n" ++
        "            override show() {}\n" ++
        "            override hide() {}\n" ++
        "            override get isVisible() {\n" ++
        "                return false;\n" ++
        "            }\n" ++
        "        })(),\n" ++
        "    );\n" ++
        "    const x = class {\n" ++
        "        show() {}\n" ++
        "        hide() {}\n" ++
        "    };\n" ++
        "    class Y {\n" ++
        "        show() {}\n" ++
        "        hide() {}\n" ++
        "    }\n" ++
        "}\n" ++
        "export abstract class WordDistance {\n" ++
        "    static readonly None = new (class extends WordDistance {\n" ++
        "        distance() {\n" ++
        "            return 0;\n" ++
        "        }\n" ++
        "    })();\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a template chunk spelled like an angle opens no type list" {
    const stack = "serverStac" ++ @as([66]u8, @splat('k'));

    const source = "foo([\n" ++
        "    `<${a}> T ${b}`,\n" ++
        "    serverMessage,\n" ++
        "    " ++ stack ++ "\n" ++
        "]);\n" ++
        "foo([\n" ++
        "    `<${a}> T (${b}`,\n" ++
        "    serverMessage,\n" ++
        "    " ++ stack ++ "\n" ++
        "]);\n" ++
        "foo([\n" ++
        "    `${b})`,\n" ++
        "    serverMessage,\n" ++
        "    " ++ stack ++ "\n" ++
        "]);\n";

    const wanted = "foo([\n" ++
        "    `<${a}> T ${b}`,\n" ++
        "    serverMessage,\n" ++
        "    " ++ stack ++ ",\n" ++
        "]);\n" ++
        "foo([\n" ++
        "    `<${a}> T (${b}`,\n" ++
        "    serverMessage,\n" ++
        "    " ++ stack ++ ",\n" ++
        "]);\n" ++
        "foo([\n" ++
        "    `${b})`,\n" ++
        "    serverMessage,\n" ++
        "    " ++ stack ++ ",\n" ++
        "]);\n";

    try expect_formatted(source, wanted);
}

test "a chain of names breaks below its object before its last member" {
    const member = "InlineEditsTriggerOnEditorChangeAfterSeconds" ++ @as([13]u8, @splat('x'));

    const source = "function f() {\n" ++
        "    if (x) {\n" ++
        "        foo(\n" ++
        "            a,\n" ++
        "            ConfigKey.Advanced." ++ member ++ ",\n" ++
        "        );\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "function f() {\n" ++
        "    if (x) {\n" ++
        "        foo(\n" ++
        "            a,\n" ++
        "            ConfigKey.Advanced\n" ++
        "                ." ++ member ++ ",\n" ++
        "        );\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a cast target keeps its parentheses and an element type drops them" {
    const source = "const serialize = new (await this._getSerializeConstructor())();\n" ++
        "(event.document as any) = null!;\n" ++
        "(<any>event).x = 1;\n" ++
        "(x as any) += 1;\n" ++
        "(x satisfies any) = 2;\n" ++
        "y = x as any;\n" ++
        "const list: (true)[] = [true, true];\n" ++
        "function f(expected: ({ uri: URI; range: [number, number][] })[], b: (A | B)[], " ++
        "c: (() => void)[], d: (keyof T)[], e: (typeof x)[], g: (string)[]) {}\n";

    const wanted = "const serialize = new (await this._getSerializeConstructor())();\n" ++
        "(event.document as any) = null!;\n" ++
        "(<any>event).x = 1;\n" ++
        "(x as any) += 1;\n" ++
        "(x satisfies any) = 2;\n" ++
        "y = x as any;\n" ++
        "const list: true[] = [true, true];\n" ++
        "function f(\n" ++
        "    expected: { uri: URI; range: [number, number][] }[],\n" ++
        "    b: (A | B)[],\n" ++
        "    c: (() => void)[],\n" ++
        "    d: (keyof T)[],\n" ++
        "    e: (typeof x)[],\n" ++
        "    g: string[],\n" ++
        ") {}\n";

    try expect_formatted(source, wanted);
}

test "a nested type assertion takes parentheses of its own" {
    const source = "const e1 = <IWebKitMouseWheelEvent><any>e;\n" ++
        "foo(<HTMLElement><any>new TestEditorDomElement());\n" ++
        "const e2 = <A>(<any>e);\n";

    const wanted = "const e1 = <IWebKitMouseWheelEvent>(<any>e);\n" ++
        "foo(<HTMLElement>(<any>new TestEditorDomElement()));\n" ++
        "const e2 = <A>(<any>e);\n";

    try expect_formatted(source, wanted);
}

test "a new whose callee is parenthesised takes call parentheses" {
    const source = "const serialize = new (await this._getSerializeConstructor());\n" ++
        "const a = new (foo());\n" ++
        "const b = new (foo())();\n" ++
        "const c = new Foo;\n";

    const wanted = "const serialize = new (await this._getSerializeConstructor())();\n" ++
        "const a = new (foo())();\n" ++
        "const b = new (foo())();\n" ++
        "const c = new Foo();\n";

    try expect_formatted(source, wanted);
}

test "a source break in front of an operator moves behind it" {
    const source = "function f() {\n" ++
        "    return (\n" ++
        "        wellKnownLanguages.get(languageId.toLowerCase())\n" ++
        "        ?? { languageId, lineComment: { start: '//' } }\n" ++
        "    );\n" ++
        "}\n" ++
        "const y = cccc || (!!file\n" ++
        "    && typeof x === \"s\");\n" ++
        "class A {\n" ++
        "    /** Iterates. */\n" ++
        "    *values() {\n" ++
        "        yield 1;\n" ++
        "    }\n" ++
        "}\n" ++
        "if (\n" ++
        "    this.enabledAutoUpdateExtensionsValue !== " ++
        "this.getEnabledAutoUpdateExtensionsValue() /* c */\n" ++
        "    || this.disabledAutoUpdateExtensionsValue !== " ++
        "this.getDisabledAutoUpdateExtensionsValue() /* c */\n" ++
        ") {\n" ++
        "    x();\n" ++
        "}\n";

    const wanted = "function f() {\n" ++
        "    return (\n" ++
        "        wellKnownLanguages.get(languageId.toLowerCase()) ?? {\n" ++
        "            languageId,\n" ++
        "            lineComment: { start: \"//\" },\n" ++
        "        }\n" ++
        "    );\n" ++
        "}\n" ++
        "const y = cccc || (!!file && typeof x === \"s\");\n" ++
        "class A {\n" ++
        "    /** Iterates. */\n" ++
        "    *values() {\n" ++
        "        yield 1;\n" ++
        "    }\n" ++
        "}\n" ++
        "if (\n" ++
        "    this.enabledAutoUpdateExtensionsValue !==\n" ++
        "        this.getEnabledAutoUpdateExtensionsValue() /* c */ ||\n" ++
        "    this.disabledAutoUpdateExtensionsValue !==\n" ++
        "        this.getDisabledAutoUpdateExtensionsValue() /* c */\n" ++
        ") {\n" ++
        "    x();\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a parenthesised operand of an arrow body run breaks its own run" {
    const a20: [20]u8 = @splat('a');
    const b32: [32]u8 = @splat('b');
    const c30: [30]u8 = @splat('c');
    const d31: [31]u8 = @splat('d');
    const e45: [45]u8 = @splat('e');

    const source = "const f1 = () => " ++ a20 ++ " && " ++ b32 ++ " && (" ++ c30 ++ " || " ++
        d31 ++ " || " ++ e45 ++ ");\n" ++
        "const f5 = (s: T): boolean => " ++ a20 ++ " && " ++ b32 ++ " && (c.d.e().f || " ++
        d31 ++ " || " ++ e45 ++ ");\n";

    const wanted = "const f1 = () =>\n" ++
        "    " ++ a20 ++ " &&\n" ++
        "    " ++ b32 ++ " &&\n" ++
        "    (" ++ c30 ++ " ||\n" ++
        "        " ++ d31 ++ " ||\n" ++
        "        " ++ e45 ++ ");\n" ++
        "const f5 = (s: T): boolean =>\n" ++
        "    " ++ a20 ++ " &&\n" ++
        "    " ++ b32 ++ " &&\n" ++
        "    (c.d.e().f ||\n" ++
        "        " ++ d31 ++ " ||\n" ++
        "        " ++ e45 ++ ");\n";

    try expect_formatted(source, wanted);
}

test "an object a logical operator inlines is no second head" {
    const source = "function f() {\n" ++
        "    const permissions = this._configService.getEffectiveValue(sessionKey, " ++
        "platformSessionSchema, SessionConfigKey.Permissions) ?? { allow: [], deny: [] };\n" ++
        "    const applicationItems = this.getStorage(StorageScope.APPLICATION)?.items ?? " ++
        "new Map<string, string>();\n" ++
        "}\n";

    const wanted = "function f() {\n" ++
        "    const permissions = this._configService.getEffectiveValue(\n" ++
        "        sessionKey,\n" ++
        "        platformSessionSchema,\n" ++
        "        SessionConfigKey.Permissions,\n" ++
        "    ) ?? { allow: [], deny: [] };\n" ++
        "    const applicationItems =\n" ++
        "        this.getStorage(StorageScope.APPLICATION)?.items ?? " ++
        "new Map<string, string>();\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a comment behind a line is no width of it and a tab is an indent wide" {
    const source = "function f() {\n" ++
        "    if (isLinux) {\n" ++
        "        options.icon = join(environmentMainService.appRoot, " ++
        "\"resources/linux/code.png\"); // always on Linux\n" ++
        "    }\n" ++
        "    test(\"x\", () => {\n" ++
        "        assert.strictEqual(query.originalLowercase, " ++
        "\" Hello   World  \t\".toLowerCase());\n" ++
        "    });\n" ++
        "}\n" ++
        "export enum NotebookDiffViewEventType {\n" ++
        "\tLayoutChanged = 1,\n" ++
        "\tCellLayoutChanged = 2\n" ++
        "\t// MetadataChanged = 2,\n" ++
        "\t// CellStateChanged = 3\n" ++
        "}\n";

    const wanted = "function f() {\n" ++
        "    if (isLinux) {\n" ++
        "        options.icon = join(environmentMainService.appRoot, " ++
        "\"resources/linux/code.png\"); // always on Linux\n" ++
        "    }\n" ++
        "    test(\"x\", () => {\n" ++
        "        assert.strictEqual(\n" ++
        "            query.originalLowercase,\n" ++
        "            \" Hello   World  \t\".toLowerCase(),\n" ++
        "        );\n" ++
        "    });\n" ++
        "}\n" ++
        "export enum NotebookDiffViewEventType {\n" ++
        "    LayoutChanged = 1,\n" ++
        "    CellLayoutChanged = 2,\n" ++
        "    // MetadataChanged = 2,\n" ++
        "    // CellStateChanged = 3\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a template hole closes no bracket a comment scan counts" {
    const source = "suite('Strings', () => {\n" ++
        "\tsuite('removeAnsiEscapeCodes', () => {\n" ++
        "\t\tfunction testSequence(sequence: string) {\n" ++
        "\t\t\tassert.strictEqual(strings.removeAnsiEscapeCodes(`hello${sequence}world`), " ++
        "'helloworld', `expect to remove ${JSON.stringify(sequence)}`);\n" ++
        "\t\t\tassert.deepStrictEqual(\n" ++
        "\t\t\t\t`expect to forAnsiStringParts ${JSON.stringify(sequence)}`\n" ++
        "\t\t\t);\n" ++
        "\t\t}\n" ++
        "\t\ttest('CSI sequences', () => {\n" ++
        "\t\t\tconst sequences = [\n" ++
        "\t\t\t\t`${CSI}42@`,\n" ++
        "\t\t\t\t`${CSI}38:2:0:255:255:255m`, // truecolor\n" ++
        "\t\t\t\t`${CSI}38;2;255;255;255m`, // truecolor alt\n" ++
        "\t\t\t];\n" ++
        "\t\t});\n" ++
        "\t});\n" ++
        "});\n";

    const wanted = "suite(\"Strings\", () => {\n" ++
        "    suite(\"removeAnsiEscapeCodes\", () => {\n" ++
        "        function testSequence(sequence: string) {\n" ++
        "            assert.strictEqual(\n" ++
        "                strings.removeAnsiEscapeCodes(`hello${sequence}world`),\n" ++
        "                \"helloworld\",\n" ++
        "                `expect to remove ${JSON.stringify(sequence)}`,\n" ++
        "            );\n" ++
        "            assert.deepStrictEqual(\n" ++
        "                `expect to forAnsiStringParts ${JSON.stringify(sequence)}`,\n" ++
        "            );\n" ++
        "        }\n" ++
        "        test(\"CSI sequences\", () => {\n" ++
        "            const sequences = [\n" ++
        "                `${CSI}42@`,\n" ++
        "                `${CSI}38:2:0:255:255:255m`, // truecolor\n" ++
        "                `${CSI}38;2;255;255;255m`, // truecolor alt\n" ++
        "            ];\n" ++
        "        });\n" ++
        "    });\n" ++
        "});\n";

    try expect_formatted(source, wanted);
}

test "a test call keeps its arguments and parameters on one line" {
    const source = "suite(\"x\", () => {\n" ++
        "\ttest(\"createQuickPick, match item by label derived from resourceUri123\", " ++
        "function (_done) {\n" ++
        "\t\tx();\n" ++
        "\t});\n" ++
        "\ttest(\"returns empty array when given empty array\" /* Regression test for " ++
        "https://github.com/microsoft/vscode/issues/1 */, async () => {\n" ++
        "\t\tx();\n" ++
        "\t});\n" ++
        "});\n";

    const wanted = "suite(\"x\", () => {\n" ++
        "    test(\"createQuickPick, match item by label derived from resourceUri123\", " ++
        "function (_done) {\n" ++
        "        x();\n" ++
        "    });\n" ++
        "    test(\"returns empty array when given empty array\" /* Regression test for " ++
        "https://github.com/microsoft/vscode/issues/1 */, async () => {\n" ++
        "        x();\n" ++
        "    });\n" ++
        "});\n";

    try expect_formatted(source, wanted);
}

test "a class field and a function type break their unions" {
    const source = "class A {\n" ++
        "    lastUpdate: { key: string; value: unknown; target?: ConfigurationTarget } | " ++
        "undefined;\n" ++
        "    readonly onUserPromptSubmitted?: () => { readonly additionalContext: string } | " ++
        "undefined;\n" ++
        "    onEvent: ((event: { name: string; data: Record<string, unknown> }) => void) | " ++
        "undefined;\n" ++
        "    lastUpdate2: { key: string; value: unknown; target?: ConfigurationTarget } | " ++
        "null;\n" ++
        "}\n" ++
        "function g() {\n" ++
        "    let acceptedInput: { storeToHistory: boolean | undefined; " ++
        "preserveFocus: boolean | undefined } | undefined;\n" ++
        "}\n" ++
        "function f(getLineChanges?: () => MarkdownPreviewLineChanges | " ++
        "Promise<MarkdownPreviewLineChanges | undefined> | undefined) {}\n";

    const wanted = "class A {\n" ++
        "    lastUpdate:\n" ++
        "        | { key: string; value: unknown; target?: ConfigurationTarget }\n" ++
        "        | undefined;\n" ++
        "    readonly onUserPromptSubmitted?: () =>\n" ++
        "        | { readonly additionalContext: string }\n" ++
        "        | undefined;\n" ++
        "    onEvent:\n" ++
        "        | ((event: { name: string; data: Record<string, unknown> }) => void)\n" ++
        "        | undefined;\n" ++
        "    lastUpdate2: { key: string; value: unknown; target?: ConfigurationTarget } | " ++
        "null;\n" ++
        "}\n" ++
        "function g() {\n" ++
        "    let acceptedInput:\n" ++
        "        | { storeToHistory: boolean | undefined; " ++
        "preserveFocus: boolean | undefined }\n" ++
        "        | undefined;\n" ++
        "}\n" ++
        "function f(\n" ++
        "    getLineChanges?: () =>\n" ++
        "        | MarkdownPreviewLineChanges\n" ++
        "        | Promise<MarkdownPreviewLineChanges | undefined>\n" ++
        "        | undefined,\n" ++
        ") {}\n";

    try expect_formatted(source, wanted);
}

test "a member read off parentheses breaks after them past its lookups" {
    const source = "async function f() {\n" ++
        "    if (x) {\n" ++
        "        if (y) {\n" ++
        "            const currentRemoteContent = " ++
        "(await testObject.getRemoteUserData(null)).syncData?.content;\n" ++
        "            const invokeArg = " ++
        "(tool.invoke as ReturnType<typeof vi.fn>).mock.calls[0][0];\n" ++
        "            const tunnelUrl = " ++
        "/Open this link in your browser (https?:\\/\\/[^\\s]+)/.exec(line)?.[1];\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "async function f() {\n" ++
        "    if (x) {\n" ++
        "        if (y) {\n" ++
        "            const currentRemoteContent = " ++
        "(await testObject.getRemoteUserData(null))\n" ++
        "                .syncData?.content;\n" ++
        "            const invokeArg = (tool.invoke as ReturnType<typeof vi.fn>).mock\n" ++
        "                .calls[0][0];\n" ++
        "            const tunnelUrl = " ++
        "/Open this link in your browser (https?:\\/\\/[^\\s]+)/.exec(\n" ++
        "                line,\n" ++
        "            )?.[1];\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a cast a new and a type argument union break where biome does" {
    const source = "class A {\n" ++
        "    f() {\n" ++
        "        const log = new FlushableSafeJSONLFile<InlineEditRequestLogContext>" ++
        "(logFilePath);\n" ++
        "        const responsePartAction = getActionEnvelope(responsePart).action as " ++
        "IResponsePartAction;\n" ++
        "    }\n" ++
        "}\n" ++
        "export interface IMonitoringContext {\n" ++
        "    instance: Pick<ITerminalInstance, \"sendText\" | \"instanceId\" | " ++
        "\"onDidInputData\" | \"onDisposed\" | \"onData\" | \"focus\" | " ++
        "\"registerMarker\">;\n" ++
        "}\n" ++
        "function f(provider: Pick<IAgentHostSessionsProvider, \"id\" | " ++
        "\"onDidChangeSessionConfig\" | \"getSessionConfig\" | " ++
        "\"setSessionConfigValue\">) {}\n";

    const wanted = "class A {\n" ++
        "    f() {\n" ++
        "        const log = new FlushableSafeJSONLFile<InlineEditRequestLogContext>(\n" ++
        "            logFilePath,\n" ++
        "        );\n" ++
        "        const responsePartAction = getActionEnvelope(responsePart)\n" ++
        "            .action as IResponsePartAction;\n" ++
        "    }\n" ++
        "}\n" ++
        "export interface IMonitoringContext {\n" ++
        "    instance: Pick<\n" ++
        "        ITerminalInstance,\n" ++
        "        | \"sendText\"\n" ++
        "        | \"instanceId\"\n" ++
        "        | \"onDidInputData\"\n" ++
        "        | \"onDisposed\"\n" ++
        "        | \"onData\"\n" ++
        "        | \"focus\"\n" ++
        "        | \"registerMarker\"\n" ++
        "    >;\n" ++
        "}\n" ++
        "function f(\n" ++
        "    provider: Pick<\n" ++
        "        IAgentHostSessionsProvider,\n" ++
        "        \"id\" | \"onDidChangeSessionConfig\" | \"getSessionConfig\" | " ++
        "\"setSessionConfigValue\"\n" ++
        "    >,\n" ++
        ") {}\n";

    try expect_formatted(source, wanted);
}

test "a sole type argument union and a parameter default break by width" {
    const import_path = "\"../../../../../platform/agentHost/common/state/protocol/common/" ++
        "commands.js\"";

    const source = "class A {\n" ++
        "    readonly initializeResult: IObservable<import(" ++ import_path ++
        ").InitializeResult | undefined>;\n" ++
        "    constructor(private readonly _handleLastObserverRemoved: (() => void) | " ++
        "undefined = undefined, private readonly _changeTracker: " ++
        "IChangeTracker<TChangeSummary> | undefined) {}\n" ++
        "}\n" ++
        "interface B {\n" ++
        "    properties?: Array<\"showHiddenFiles\" | \"createDirectory\" | " ++
        "\"treatPackageAsDirectory\" | \"showOverwriteConfirmation\">;\n" ++
        "    short?: Array<\"a\" | \"b\">;\n" ++
        "}\n" ++
        "abstract class ClassPropertyContextProvider<T extends tt.MethodDeclaration | " ++
        "tt.ConstructorDeclaration> {}\n";

    const wanted = "class A {\n" ++
        "    readonly initializeResult: IObservable<\n" ++
        "        | import(" ++ import_path ++ ").InitializeResult\n" ++
        "        | undefined\n" ++
        "    >;\n" ++
        "    constructor(\n" ++
        "        private readonly _handleLastObserverRemoved:\n" ++
        "            | (() => void)\n" ++
        "            | undefined = undefined,\n" ++
        "        private readonly _changeTracker: IChangeTracker<TChangeSummary> | " ++
        "undefined,\n" ++
        "    ) {}\n" ++
        "}\n" ++
        "interface B {\n" ++
        "    properties?: Array<\n" ++
        "        | \"showHiddenFiles\"\n" ++
        "        | \"createDirectory\"\n" ++
        "        | \"treatPackageAsDirectory\"\n" ++
        "        | \"showOverwriteConfirmation\"\n" ++
        "    >;\n" ++
        "    short?: Array<\"a\" | \"b\">;\n" ++
        "}\n" ++
        "abstract class ClassPropertyContextProvider<\n" ++
        "    T extends tt.MethodDeclaration | tt.ConstructorDeclaration,\n" ++
        "> {}\n";

    try expect_formatted(source, wanted);
}

test "a lookup past a non null assertion takes no trailing comma" {
    const a40: [40]u8 = @splat('a');
    const b38: [38]u8 = @splat('b');

    const source = "function f() {\n" ++
        "    if (a) {\n" ++
        "        const x = " ++ a40 ++ "." ++ b38 ++ "![someIndexValue];\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "function f() {\n" ++
        "    if (a) {\n" ++
        "        const x =\n" ++
        "            " ++ a40 ++ "." ++ b38 ++ "![\n" ++
        "                someIndexValue\n" ++
        "            ];\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a parenthesised function return type leaves the arrow body a value" {
    const source = "const f = (fn: X): ((a: T) => E) => (v) => ({ op: 1, update: fn(v) });\n";

    const wanted = "const f =\n" ++
        "    (fn: X): ((a: T) => E) =>\n" ++
        "    (v) => ({ op: 1, update: fn(v) });\n";

    try expect_formatted(source, wanted);
}

test "a paren after a block opens a statement owed no comma" {
    const source = "function f() {\n" ++
        "    for (const x of y) {\n" ++
        "        if (a) {\n" ++
        "            projected = 1;\n" ++
        "        } else {\n" ++
        "            projected = 3;\n" ++
        "        }\n" ++
        "\n" ++
        "        (direction === \"c2s\"\n" ++
        "            ? rounds[roundIndex].clientToServer\n" ++
        "            : rounds[roundIndex].serverToClient\n" ++
        "        ).push(projected);\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a decorated parameter breaks after its decorators where it has no room" {
    const source = "class A {\n" ++
        "    constructor(\n" ++
        "        @IFileService private readonly fileService: IFileService,\n" ++
        "        @IConfigurationService private readonly _configurationService: " ++
        "IConfigurationService,\n" ++
        "        @IInstantiationService instantiationService: IInstantiationService,\n" ++
        "        @IConfigurationService\n" ++
        "        private readonly short: IConfigurationService,\n" ++
        "        @IInstantiationService instantiationServiceWithAVeryLongName: " ++
        "IInstantiationService,\n" ++
        "        @A @B private readonly multi: SomeTypeThatIsLongEnoughToBreakTheLineHere,\n" ++
        "        @Inject(TOKEN_WITH_LONG_NAME) private readonly injected: " ++
        "SomeTypeThatIsLongEnough,\n" ++
        "        @IFoo private readonly fooWithDefault: IFooServiceLongName = " ++
        "defaultFooValue,\n" ++
        "    ) {}\n" ++
        "}\n" ++
        "class B {\n" ++
        "    m(@IFoo foo: IFoo, @IBarServiceWithLongName barServiceWithLongName: " ++
        "IBarServiceWithLongName) {}\n" ++
        "    constructor(@IFoo private readonly foo: IFoo) {}\n" ++
        "}\n";

    const wanted = "class A {\n" ++
        "    constructor(\n" ++
        "        @IFileService private readonly fileService: IFileService,\n" ++
        "        @IConfigurationService\n" ++
        "        private readonly _configurationService: IConfigurationService,\n" ++
        "        @IInstantiationService instantiationService: IInstantiationService,\n" ++
        "        @IConfigurationService\n" ++
        "        private readonly short: IConfigurationService,\n" ++
        "        @IInstantiationService\n" ++
        "        instantiationServiceWithAVeryLongName: IInstantiationService,\n" ++
        "        @A @B private readonly multi: SomeTypeThatIsLongEnoughToBreakTheLineHere,\n" ++
        "        @Inject(TOKEN_WITH_LONG_NAME)\n" ++
        "        private readonly injected: SomeTypeThatIsLongEnough,\n" ++
        "        @IFoo private readonly fooWithDefault: IFooServiceLongName = " ++
        "defaultFooValue,\n" ++
        "    ) {}\n" ++
        "}\n" ++
        "class B {\n" ++
        "    m(\n" ++
        "        @IFoo foo: IFoo,\n" ++
        "        @IBarServiceWithLongName barServiceWithLongName: IBarServiceWithLongName,\n" ++
        "    ) {}\n" ++
        "    constructor(@IFoo private readonly foo: IFoo) {}\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a decorator keeps a space before the computed member name it decorates" {
    const source = "class A {\n" ++
        "    @dec()[key]() {}\n" ++
        "    @a.b[key] = 1;\n" ++
        "    @a[b];\n" ++
        "    @a.b.c(d)[e]() {}\n" ++
        "}\n";

    const wanted = "class A {\n" ++
        "    @dec() [key]() {}\n" ++
        "    @a.b [key] = 1;\n" ++
        "    @a [b];\n" ++
        "    @a.b.c(d) [e]() {}\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a class's decorators stand on lines of their own" {
    const source = "@x class B {}\n" ++
        "\n" ++
        "@x export class C {}\n" ++
        "\n" ++
        "export @x class D {}\n" ++
        "\n" ++
        "@x @y class E {}\n" ++
        "\n" ++
        "const F = @x class {};\n" ++
        "\n" ++
        "@x\n" ++
        "class G {}\n" ++
        "\n" ++
        "export default @x class H {}\n" ++
        "\n" ++
        "@a.b() class I {}\n";

    const wanted = "@x\n" ++
        "class B {}\n" ++
        "\n" ++
        "@x\n" ++
        "export class C {}\n" ++
        "\n" ++
        "export\n" ++
        "@x\n" ++
        "class D {}\n" ++
        "\n" ++
        "@x\n" ++
        "@y\n" ++
        "class E {}\n" ++
        "\n" ++
        "const F =\n" ++
        "    @x\n" ++
        "    class {};\n" ++
        "\n" ++
        "@x\n" ++
        "class G {}\n" ++
        "\n" ++
        "export default\n" ++
        "@x\n" ++
        "class H {}\n" ++
        "\n" ++
        "@a.b()\n" ++
        "class I {}\n";

    try expect_formatted(source, wanted);
}

test "a decorated class expression breaks the group around it" {
    const source = "const F = @x class {};\n" ++
        "\n" ++
        "foo(@x class {});\n" ++
        "\n" ++
        "function g() {\n" ++
        "    return @x class {};\n" ++
        "}\n" ++
        "\n" ++
        "const G = [@x class {}];\n";

    const wanted = "const F =\n" ++
        "    @x\n" ++
        "    class {};\n" ++
        "\n" ++
        "foo(\n" ++
        "    @x\n" ++
        "    class {},\n" ++
        ");\n" ++
        "\n" ++
        "function g() {\n" ++
        "    return @x\n" ++
        "    class {};\n" ++
        "}\n" ++
        "\n" ++
        "const G = [\n" ++
        "    @x\n" ++
        "    class {},\n" ++
        "];\n";

    try expect_formatted(source, wanted);
}

test "a decorator's parentheses drop where the reference drops them" {
    const source = "class A {\n" ++
        "  @(x) a = 1;\n" ++
        "  @(a.b) b = 1;\n" ++
        "  @(a.b()) c = 1;\n" ++
        "  @(a[b]) d = 1;\n" ++
        "  @(a + b) e = 1;\n" ++
        "  @(a().b) f = 1;\n" ++
        "  @(a?.b) h = 1;\n" ++
        "  @(new A()) i = 1;\n" ++
        "  @(a`t`) j = 1;\n" ++
        "  @(a<T>) k = 1;\n" ++
        "  @(a!) l = 1;\n" ++
        "  @(a.b.c) m = 1;\n" ++
        "  @(a.#b) n = 1;\n" ++
        "  @(this.x) o = 1;\n" ++
        "}\n" ++
        "@(x) class B {}\n";

    const wanted = "class A {\n" ++
        "    @x a = 1;\n" ++
        "    @a.b b = 1;\n" ++
        "    @a.b() c = 1;\n" ++
        "    @(a[b]) d = 1;\n" ++
        "    @(a + b) e = 1;\n" ++
        "    @(a().b) f = 1;\n" ++
        "    @(a?.b) h = 1;\n" ++
        "    @(new A()) i = 1;\n" ++
        "    @(a`t`) j = 1;\n" ++
        "    @(a<T>) k = 1;\n" ++
        "    @(a!) l = 1;\n" ++
        "    @(a.b.c) m = 1;\n" ++
        "    @a.#b n = 1;\n" ++
        "    @(this.x) o = 1;\n" ++
        "}\n" ++
        "@x\n" ++
        "class B {}\n";

    try expect_formatted(source, wanted);
}

test "a typescript key loses its quotes only as a name" {
    const source = "var o = {\n" ++
        "  \"char\u{f1}\": 1,\n" ++
        "  \"\u{3c0}\": 2,\n" ++
        "  \"\u{2160}\": 3,\n" ++
        "  \"a\u{200d}b\": 4,\n" ++
        "  \"1.23\": 5,\n" ++
        "  \"0.0000001\": 6,\n" ++
        "  \"1234567890123456\": 7,\n" ++
        "  \"12345678901234567\": 8,\n" ++
        "  \"01\": 9,\n" ++
        "  \"1e3\": 10,\n" ++
        "  \"1.0\": 11,\n" ++
        "  \".5\": 12,\n" ++
        "  \"1_000\": 13,\n" ++
        "  \"0x10\": 14,\n" ++
        "  \"\\u0041\": 15,\n" ++
        "  \"new\": 16,\n" ++
        "  \"9007199254740993\": 17,\n" ++
        "  \"100\": 18,\n" ++
        "  \"0\": 19,\n" ++
        "  \"1.5e300\": 20,\n" ++
        "};\n";

    const wanted = "var o = {\n" ++
        "    char\u{f1}: 1,\n" ++
        "    \u{3c0}: 2,\n" ++
        "    \u{2160}: 3,\n" ++
        "    a\u{200d}b: 4,\n" ++
        "    \"1.23\": 5,\n" ++
        "    \"0.0000001\": 6,\n" ++
        "    \"1234567890123456\": 7,\n" ++
        "    \"12345678901234567\": 8,\n" ++
        "    \"01\": 9,\n" ++
        "    \"1e3\": 10,\n" ++
        "    \"1.0\": 11,\n" ++
        "    \".5\": 12,\n" ++
        "    \"1_000\": 13,\n" ++
        "    \"0x10\": 14,\n" ++
        "    \"\\u0041\": 15,\n" ++
        "    \"new\": 16,\n" ++
        "    \"9007199254740993\": 17,\n" ++
        "    \"100\": 18,\n" ++
        "    \"0\": 19,\n" ++
        "    \"1.5e300\": 20,\n" ++
        "};\n";

    try expect_formatted(source, wanted);
}

test "an in operator inside a for head keeps and gains the parentheses biome writes" {
    const source = "for (let i = (k in o) ? 1 : 0; i; ) {}\n" ++
        "for (x = f(a in b); ; ) {}\n" ++
        "for ((x as any)[k in o ? 1 : 0] in o) {}\n";

    const wanted = "for (let i = (k in o) ? 1 : 0; i; ) {}\n" ++
        "for (x = f((a in b)); ; ) {}\n" ++
        "for ((x as any)[(k in o) ? 1 : 0] in o) {\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a semicolon after a type declaration is an empty statement and is dropped" {
    const source = "export interface I {};\n" ++
        "export enum E {};\n" ++
        "export namespace N {};\n" ++
        "export abstract class A {};\n" ++
        "declare class X {};\n" ++
        "export declare class Y {};\n" ++
        "export default interface Z {};\n" ++
        "declare module \"m\" {};\n" ++
        "let n = {};\n";

    const wanted = "export interface I {}\n" ++
        "export enum E {}\n" ++
        "export namespace N {}\n" ++
        "export abstract class A {}\n" ++
        "declare class X {}\n" ++
        "export declare class Y {}\n" ++
        "export default interface Z {}\n" ++
        "declare module \"m\" {}\n" ++
        "let n = {};\n";

    try expect_formatted(source, wanted);
}

test "a parenthesized union closing a tuple takes no comma" {
    const source = "type X = [\n" ++
        "    \"always\" | \"never\",\n" ++
        "    (\n" ++
        "        | CapitalizedCommentsCommonOptions\n" ++
        "        | PartialPartialPartialPartialPartialPartialPartialPartialPartial\n" ++
        "    ),\n" ++
        "];\n";

    try expect_formatted(source, source);
}

test "a function type in a return type is no link of an arrow chain" {
    const source = "export const isFunction = (value: unknown): " ++
        "value is (...args: any[]) => any =>\n" ++
        "  typeof value === \"function\";\n" ++
        "const g = (v: unknown): (() => void) => () => {};\n" ++
        "const h = (v: unknown): v is () => void => typeof v === \"function\";\n";

    const wanted = "export const isFunction = (value: unknown): " ++
        "value is (...args: any[]) => any =>\n" ++
        "    typeof value === \"function\";\n" ++
        "const g =\n" ++
        "    (v: unknown): (() => void) =>\n" ++
        "    () => {};\n" ++
        "const h = (v: unknown): v is () => void => typeof v === \"function\";\n";

    try expect_formatted(source, wanted);
}

test "a typed parameter pattern breaks around a nested pattern it holds" {
    const source = "function f({ a: { b: { c } } }: T) {}\n" ++
        "function g({ a: { b } }: T = {}) {}\n" ++
        "function l({ a: { b: { c } } }: T = {}) {}\n" ++
        "const h = ({ a: { b: { c } } }: T) => c;\n" ++
        "const { a: { b } }: T = x;\n" ++
        "function k(this: T, { a: { b } }: U) {}\n";

    const wanted = "function f({\n" ++
        "    a: {\n" ++
        "        b: { c },\n" ++
        "    },\n" ++
        "}: T) {}\n" ++
        "function g({ a: { b } }: T = {}) {}\n" ++
        "function l({\n" ++
        "    a: {\n" ++
        "        b: { c },\n" ++
        "    },\n" ++
        "}: T = {}) {}\n" ++
        "const h = ({\n" ++
        "    a: {\n" ++
        "        b: { c },\n" ++
        "    },\n" ++
        "}: T) => c;\n" ++
        "const {\n" ++
        "    a: { b },\n" ++
        "}: T = x;\n" ++
        "function k(this: T, { a: { b } }: U) {}\n";

    try expect_formatted(source, wanted);
}

test "a yield operand keeps the parentheses its meaning needs" {
    const source = "function* k() {\n" ++
        "    x = (yield a) + 1;\n" ++
        "    z = (yield a) ? b : c;\n" ++
        "    v = (yield a) as T;\n" ++
        "    h(...yield a);\n" ++
        "}\n";

    const wanted = "function* k() {\n" ++
        "    x = (yield a) + 1;\n" ++
        "    z = (yield a) ? b : c;\n" ++
        "    v = (yield a) as T;\n" ++
        "    h(...(yield a));\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an optional chain behind a non-null assertion keeps its parentheses" {
    const source = "x = (a!?.b).foo;\n" ++
        "x = (a.b!?.c).foo;\n" ++
        "x = (a?.b!).c;\n";

    const wanted = "x = (a!?.b).foo;\n" ++
        "x = (a.b!?.c).foo;\n" ++
        "x = a?.b!.c;\n";

    try expect_formatted(source, wanted);
}

test "a sequence element drops the parentheses its meaning does not need" {
    const source = "x = ((a), b).c;\n" ++
        "y = f(((a), b));\n" ++
        "w = (a, (b, c));\n" ++
        "v = ((a, b), c);\n" ++
        "u = (a, (b = 1));\n" ++
        "s = (a, (b ? c : d));\n" ++
        "r = ((x) => x, b);\n" ++
        "q = (a, (b as T));\n" ++
        "o = ((function () {}), b);\n" ++
        "m = ((a || b), c);\n" ++
        "k = `${(a as any).b()}`;\n";

    const wanted = "x = (a, b).c;\n" ++
        "y = f((a, b));\n" ++
        "w = (a, b, c);\n" ++
        "v = (a, b, c);\n" ++
        "u = (a, (b = 1));\n" ++
        "s = (a, b ? c : d);\n" ++
        "r = ((x) => x, b);\n" ++
        "q = (a, b as T);\n" ++
        "o = (function () {}, b);\n" ++
        "m = (a || b, c);\n" ++
        "k = `${(a as any).b()}`;\n";

    try expect_formatted(source, wanted);
}

test "an intersection after a type parameter list that breaks measures from the closing angle" {
    const source = "export type ResolverProxy<\n" ++
        "  T extends AnyObject[] = AnyObject[],\n" ++
        "  R extends AnyObject[] = T\n" ++
        "> = Merge<T[number]> & ResolverCache<T, R>\n" ++
        "\n" ++
        "export type Short<T extends AnyObject[] = AnyObject[], " ++
        "R extends AnyObject[] = T> = A & B\n" ++
        "\n" ++
        "export type Long<\n" ++
        "  T extends AnyObject[] = AnyObject[],\n" ++
        "  R extends AnyObject[] = T\n" ++
        "> = Merge<T[number]> & ResolverCacheResolverCacheResolverCache<T, R> & " ++
        "SomethingElseEntirely<T>\n";

    const wanted = "export type ResolverProxy<\n" ++
        "    T extends AnyObject[] = AnyObject[],\n" ++
        "    R extends AnyObject[] = T,\n" ++
        "> = Merge<T[number]> & ResolverCache<T, R>;\n" ++
        "\n" ++
        "export type Short<T extends AnyObject[] = AnyObject[], " ++
        "R extends AnyObject[] = T> = A &\n" ++
        "    B;\n" ++
        "\n" ++
        "export type Long<\n" ++
        "    T extends AnyObject[] = AnyObject[],\n" ++
        "    R extends AnyObject[] = T,\n" ++
        "> = Merge<T[number]> &\n" ++
        "    ResolverCacheResolverCacheResolverCache<T, R> &\n" ++
        "    SomethingElseEntirely<T>;\n";

    try expect_formatted(source, wanted);
}

test "a signature in a nested interface whose type parameters carry defaults collapses" {
    const source = "namespace preact {\n" ++
        "    interface FunctionComponent<P = {}> {\n" ++
        "        (\n" ++
        "            props: string,\n" ++
        "            context?: any\n" ++
        "        ): void;\n" ++
        "    }\n" ++
        "}\n" ++
        "function f() {\n" ++
        "    interface Other<P = string, Q extends object = {}> {\n" ++
        "        (\n" ++
        "            props: P,\n" ++
        "            context?: Q\n" ++
        "        ): void;\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "namespace preact {\n" ++
        "    interface FunctionComponent<P = {}> {\n" ++
        "        (props: string, context?: any): void;\n" ++
        "    }\n" ++
        "}\n" ++
        "function f() {\n" ++
        "    interface Other<P = string, Q extends object = {}> {\n" ++
        "        (props: P, context?: Q): void;\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a function type in a return position drops the breaks its source wrote" {
    const source = "function g(x: number): (\n" ++
        "    a: string,\n" ++
        "    b: number\n" ++
        ") => void {}\n" ++
        "declare namespace preact {\n" ++
        "    export function createFactory(\n" ++
        "        type: _preact.VNode<any>['type']\n" ++
        "    ): (\n" ++
        "        props?: any,\n" ++
        "        ...children: _preact.ComponentChildren[]\n" ++
        "    ) => _preact.VNode<any>;\n" ++
        "}\n";

    const wanted = "function g(x: number): (a: string, b: number) => void {}\n" ++
        "declare namespace preact {\n" ++
        "    export function createFactory(\n" ++
        "        type: _preact.VNode<any>[\"type\"],\n" ++
        "    ): (props?: any, ...children: _preact.ComponentChildren[]) => _preact.VNode<any>;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a comment after a union's leading bar in a type argument keeps a single bar" {
    const source = "export type A = Array<\n" ++
        "\t| /** c */ Falsy\n" ++
        "\t| WebpackPluginInstanceWebpackPluginInstance\n" ++
        "\t| WebpackPluginInstanceWebpackPluginInstance2\n" ++
        ">;\n" ++
        "export type P = Array<\n" ++
        "\t| /** c */ Falsy\n" ++
        "\t| WebpackPluginInstance\n" ++
        ">;\n";

    const wanted = "export type A = Array<\n" ++
        "    | /** c */ Falsy\n" ++
        "    | WebpackPluginInstanceWebpackPluginInstance\n" ++
        "    | WebpackPluginInstanceWebpackPluginInstance2\n" ++
        ">;\n" ++
        "export type P = Array</** c */ Falsy | WebpackPluginInstance>;\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a dynamic import after a property colon is a value and no import type" {
    const source = "x = {\n" ++
        "  embeddedEditorComponent: import('../../editor/index')" ++
        ".then((c) => c.EmbeddedEditorxxxxx),\n" ++
        "};\n" ++
        "y = {\n" ++
        "  e: import('../../editor/index/cccccccccccccccccccccccccccccccc')" ++
        ".then(c).then(d).then(e),\n" ++
        "};\n" ++
        "let a: import('x').T;\n" ++
        "type B = { c?: import('y').D };\n";

    const wanted = "x = {\n" ++
        "    embeddedEditorComponent: import(\"../../editor/index\").then(\n" ++
        "        (c) => c.EmbeddedEditorxxxxx,\n" ++
        "    ),\n" ++
        "};\n" ++
        "y = {\n" ++
        "    e: import(\"../../editor/index/cccccccccccccccccccccccccccccccc\")\n" ++
        "        .then(c)\n" ++
        "        .then(d)\n" ++
        "        .then(e),\n" ++
        "};\n" ++
        "let a: import(\"x\").T;\n" ++
        "type B = { c?: import(\"y\").D };\n";

    try expect_formatted(source, wanted);
}

test "a typeof query in an arrow's return type takes no parameter parentheses" {
    const source = "let g = (a): typeof I => 1;\n" ++
        "function f() {\n" ++
        "  return (arg: FieldContext<any>): TReturn | typeof IGNORED => {\n" ++
        "    return 1;\n" ++
        "  };\n" ++
        "}\n";

    const wanted = "let g = (a): typeof I => 1;\n" ++
        "function f() {\n" ++
        "    return (arg: FieldContext<any>): TReturn | typeof IGNORED => {\n" ++
        "        return 1;\n" ++
        "    };\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an arrow called where it is valued keeps its parentheses tight" {
    const source = "const d: H | null = /* @__PURE__ */ (() =>\n" ++
        "  typeof document === 'undefined' ? null : document.documentElement)();\n" ++
        "dd = (() =>\n" ++
        "  typeof document === 'undefined' ? null : document.documentElementxxxxxxxxx" ++
        "xxxxxxxxxxxx)();\n" ++
        "const dd = (() =>\n" ++
        "  typeof document === 'undefined' ? null : document.documentElementxxxxxxxxx" ++
        "x)().foo;\n";

    const wanted = "const d: H | null = /* @__PURE__ */ (() =>\n" ++
        "    typeof document === \"undefined\" ? null : document.documentElement)();" ++
        "\n" ++
        "dd = (() =>\n" ++
        "    typeof document === \"undefined\"\n" ++
        "        ? null\n" ++
        "        : document.documentElementxxxxxxxxxxxxxxxxxxxxx)();\n" ++
        "const dd = (() =>\n" ++
        "    typeof document === \"undefined\" ? null : document.documentElementxxxxx" ++
        "xxxxx)().foo;\n";

    try expect_formatted(source, wanted);
}

test "a type parameter list biome broke leaves the parameters on its closing line" {
    const source = "export function ngDebugApiIsSupported<\n" ++
        "    T extends Partial<GlobalUtils>,\n" ++
        "    K extends keyof T,\n" ++
        ">(ng: T, api: K): ng is T & Record<K, NonNullable<T[K]>> {\n" ++
        "    return typeof ng[api] === \"function\";\n" ++
        "}\n";

    const wanted = "export function ngDebugApiIsSupported<\n" ++
        "    T extends Partial<GlobalUtils>,\n" ++
        "    K extends keyof T,\n" ++
        ">(ng: T, api: K): ng is T & Record<K, NonNullable<T[K]>> {\n" ++
        "    return typeof ng[api] === \"function\";\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a member after a non-null index keeps its value broken after the operator" {
    const source_a = "function f() {\n" ++
        "    const classProp =\n" ++
        "        inputs.getByBindingPropertyNamexxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx(att" ++
        "rName)![0]\n" ++
        "            .classPropertyName;\n" ++
        "}\n";

    const wanted_a = "function f() {\n" ++
        "    const classProp =\n" ++
        "        inputs.getByBindingPropertyNamexxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx(att" ++
        "rName)![0]\n" ++
        "            .classPropertyName;\n" ++
        "}\n";

    const source_b = "function f() {\n" ++
        "    const classProp = inputs.getByBindingPropertyNamexxxxxxxxxxxxxxxxxxxxx" ++
        "xxxxxxxxxx(attrName)![0].classPropertyName;\n" ++
        "}\n";

    const wanted_b = "function f() {\n" ++
        "    const classProp =\n" ++
        "        inputs.getByBindingPropertyNamexxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx(att" ++
        "rName)![0]\n" ++
        "            .classPropertyName;\n" ++
        "}\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
}

test "a union member of a spread type literal counts the semicolon written after it" {
    const source = "type X = {[code: string]: CurrenciesSymbols | [string | undefined, string | " ++
        "undefined, number]};\n" ++
        "type Y = {[code: string]: CurrenciesSymbols | [string | undefined, string | " ++
        "undefined, numbe]};\n";

    const wanted = "type X = {\n" ++
        "    [code: string]:\n" ++
        "        | CurrenciesSymbols\n" ++
        "        | [string | undefined, string | undefined, number];\n" ++
        "};\n" ++
        "type Y = {\n" ++
        "    [code: string]: CurrenciesSymbols | [string | undefined, string | undefi" ++
        "ned, numbe];\n" ++
        "};\n";

    try expect_formatted(source, wanted);
}

test "a line comment after a return type colon seats the union on the next line" {
    const source = "declare class A {\n" ++
        "    get oncurrententrychange(): // tslint:disable-next-line:no-any\n" ++
        "    ((this: Navigation, ev: NavigationCurrentEntryChangeEvent) => any) | nul" ++
        "l;\n" ++
        "}\n";

    const wanted = "declare class A {\n" ++
        "    get oncurrententrychange(): // tslint:disable-next-line:no-any\n" ++
        "    ((this: Navigation, ev: NavigationCurrentEntryChangeEvent) => any) | nul" ++
        "l;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a comment on its own line in a type argument list breaks the list" {
    const source = "type D = Record<\n" ++
        "  string,\n" ++
        "  // Basic case.\n" ++
        "  number\n" ++
        ">;\n" ++
        "type E = Record<\n" ++
        "  string,\n" ++
        "  // Basic case.\n" ++
        "  string | number\n" ++
        ">;\n" ++
        "type F = Array<\n" ++
        "  // Basic case.\n" ++
        "  string | number\n" ++
        ">;\n" ++
        "foo<\n" ++
        "  /* Comment */ Type\n" ++
        ">(\n" ++
        "  /* Comment */ value\n" ++
        ");\n";

    const wanted = "type D = Record<\n" ++
        "    string,\n" ++
        "    // Basic case.\n" ++
        "    number\n" ++
        ">;\n" ++
        "type E = Record<\n" ++
        "    string,\n" ++
        "    // Basic case.\n" ++
        "    string | number\n" ++
        ">;\n" ++
        "type F = Array<\n" ++
        "    // Basic case.\n" ++
        "    string | number\n" ++
        ">;\n" ++
        "foo</* Comment */ Type>(/* Comment */ value);\n";

    try expect_formatted(source, wanted);
}

test "a commented operand of a unary operator keeps its parentheses around the comment" {
    const source = "x = !!(\n" ++
        "    // Avoid breaking.\n" ++
        "    typeof customElements === 'object' && b\n" ++
        "  );\n" ++
        "y = !!(\n" ++
        "    // Avoid breaking.\n" ++
        "    a\n" ++
        "  );\n";

    const wanted = "x = !!(\n" ++
        "    // Avoid breaking.\n" ++
        "    (typeof customElements === \"object\" && b)\n" ++
        ");\n" ++
        "y = !!(\n" ++
        "    // Avoid breaking.\n" ++
        "    a\n" ++
        ");\n";

    try expect_formatted(source, wanted);
}

test "a mapped type key written across lines leaves its object type spread" {
    const source_a = "type InferObject<TSchema> = Simplify<\n" ++
        "    {\n" ++
        "        -readonly [K in keyof P as K extends R\n" ++
        "            ? K\n" ++
        "            : never]-?: I<P[K]>;\n" ++
        "    } & {\n" ++
        "        -readonly [K in keyof P as K]?: I<P[K]>;\n" ++
        "    } & A<T>\n" ++
        ">;\n";

    const wanted_a = "type InferObject<TSchema> = Simplify<\n" ++
        "    {\n" ++
        "        -readonly [K in keyof P as K extends R ? K : never]-?: I<P[K]>;\n" ++
        "    } & {\n" ++
        "        -readonly [K in keyof P as K]?: I<P[K]>;\n" ++
        "    } & A<T>\n" ++
        ">;\n";

    const source_b = "type InferObject<TSchema> = Simplify<{\n" ++
        "    -readonly [K in keyof Properties<TSchema> as K extends " ++
        "RequiredKeys<TSchema> ? K : never]-?: InferJsonSchema<Properties<TSchema>[" ++
        "K]>;\n" ++
        "} & AdditionalProperties<TSchema>>;\n";

    const wanted_b = "type InferObject<TSchema> = Simplify<\n" ++
        "    {\n" ++
        "        -readonly [K in keyof Properties<TSchema> as K extends " ++
        "RequiredKeys<TSchema>\n" ++
        "            ? K\n" ++
        "            : never]-?: InferJsonSchema<Properties<TSchema>[K]>;\n" ++
        "    } & AdditionalProperties<TSchema>\n" ++
        ">;\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
}

test "an own line comment between union members in a type argument keeps every bar" {
    const source_a = "type DirectiveInputs = Record<\n" ++
        "    string,\n" ++
        "    | string\n" ++
        "    // Complex input\n" ++
        "    | [flags: number]\n" ++
        "    | undefined\n" ++
        ">;\n";

    const wanted_a = "type DirectiveInputs = Record<\n" ++
        "    string,\n" ++
        "    | string\n" ++
        "    // Complex input\n" ++
        "    | [flags: number]\n" ++
        "    | undefined\n" ++
        ">;\n";

    const source_b = "type DirectiveInputs = Record<\n" ++
        "    string,\n" ++
        "    // Basic case. Mapping minified name to public name.\n" ++
        "    | string\n" ++
        "    // Complex input\n" ++
        "    | [flags: number]\n" ++
        "    | undefined\n" ++
        ">;\n";

    const wanted_b = "type DirectiveInputs = Record<\n" ++
        "    string,\n" ++
        "    // Basic case. Mapping minified name to public name.\n" ++
        "    | string\n" ++
        "    // Complex input\n" ++
        "    | [flags: number]\n" ++
        "    | undefined\n" ++
        ">;\n";

    const source_c = "let x: Array<\n" ++
        "    | string\n" ++
        "    // Complex input\n" ++
        "    | number\n" ++
        ">;\n";

    const wanted_c = "let x: Array<\n" ++
        "    | string\n" ++
        "    // Complex input\n" ++
        "    | number\n" ++
        ">;\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(source_c, wanted_c);
}

test "a broken type parameter list's trailing comma is not measured in a heritage that fits" {
    const source_a = "export class BaseRpcExceptionFilter<\n" ++
        "    T = any,\n" ++
        "    R = any,\n" ++
        "> implements RpcExceptionFilter<T> {\n" ++
        "    x = 1;\n" ++
        "}\n";

    const wanted_a = "export class BaseRpcExceptionFilter<T = any, R = any> implements " ++
        "RpcExceptionFilter<T> {\n" ++
        "    x = 1;\n" ++
        "}\n";

    const source_b = "export interface ConsumerExceptionBase<\n" ++
        "    T = any,\n" ++
        "    R = any,\n" ++
        "> extends RpcExceptionFilter<T> {\n" ++
        "    x: 1;\n" ++
        "}\n";

    const wanted_b = "export interface ConsumerExceptionBase<T = any, R = any> extends " ++
        "RpcExceptionFilter<T> {\n" ++
        "    x: 1;\n" ++
        "}\n";

    const source_c = "export class ServerGrpcExceptionHandler<\n" ++
        "    T = any,\n" ++
        "    R = any,\n" ++
        "> extends A<T> implements B<R> {\n" ++
        "    x = 1;\n" ++
        "}\n";

    const wanted_c = "export class ServerGrpcExceptionHandler<T = any, R = any> extends A<T> " ++
        "implements B<R> {\n" ++
        "    x = 1;\n" ++
        "}\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(source_c, wanted_c);
}

test "a decorated class reads the commas of its implements clause as a list" {
    const source_a = "@Injectable()\n" ++
        "class TestInjectable\n" ++
        "    implements OnApplicationShutdown, BeforeApplicationShutdown\n" ++
        "{\n" ++
        "    a() {\n" ++
        "        return 1;\n" ++
        "    }\n" ++
        "}\n";

    const wanted_a = "@Injectable()\n" ++
        "class TestInjectable implements OnApplicationShutdown, " ++
        "BeforeApplicationShutdown {\n" ++
        "    a() {\n" ++
        "        return 1;\n" ++
        "    }\n" ++
        "}\n";

    const source_b = "@Injectable()\n" ++
        "class TestInjectable\n" ++
        "    implements\n" ++
        "        OnApplicationBootstrap,\n" ++
        "        OnModuleInit,\n" ++
        "        OnModuleDestroy,\n" ++
        "        OnApplicationShutdown,\n" ++
        "        BeforeApplicationShutdown\n" ++
        "{\n" ++
        "    onApplicationBootstrap = vi.fn();\n" ++
        "}\n";

    const wanted_b = "@Injectable()\n" ++
        "class TestInjectable\n" ++
        "    implements\n" ++
        "        OnApplicationBootstrap,\n" ++
        "        OnModuleInit,\n" ++
        "        OnModuleDestroy,\n" ++
        "        OnApplicationShutdown,\n" ++
        "        BeforeApplicationShutdown\n" ++
        "{\n" ++
        "    onApplicationBootstrap = vi.fn();\n" ++
        "}\n";

    const source_c = "@Injectable()\n" ++
        "export class TestInjectable implements OnApplicationShutdown, " ++
        "BeforeApplicationShutdown {\n" ++
        "    a() {\n" ++
        "        return 1;\n" ++
        "    }\n" ++
        "}\n";

    const wanted_c = "@Injectable()\n" ++
        "export class TestInjectable\n" ++
        "    implements OnApplicationShutdown, BeforeApplicationShutdown\n" ++
        "{\n" ++
        "    a() {\n" ++
        "        return 1;\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(source_c, wanted_c);
}

test "a union in a type argument breaks around an object member written broken" {
    const source_a = "let x: Promise<{\n" ++
        "    moduleRef: Module;\n" ++
        "} | undefined>;\n";

    const wanted_a = "let x: Promise<\n" ++
        "    | {\n" ++
        "          moduleRef: Module;\n" ++
        "      }\n" ++
        "    | undefined\n" ++
        ">;\n";

    const source_b = "let x: Promise<string | {\n" ++
        "    moduleRef: Module;\n" ++
        "}>;\n";

    const wanted_b = "let x: Promise<\n" ++
        "    | string\n" ++
        "    | {\n" ++
        "          moduleRef: Module;\n" ++
        "      }\n" ++
        ">;\n";

    const source_c = "let x: Promise<{\n" ++
        "    moduleRef: Module;\n" ++
        "} | null>;\n";

    const wanted_c = "let x: Promise<{\n" ++
        "    moduleRef: Module;\n" ++
        "} | null>;\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(source_c, wanted_c);
}

test "a return type union with a broken object member breaks inside its angles" {
    const source_a = "async function addModule(\n" ++
        "    metatype: ModuleMetatype,\n" ++
        "    scope: ModuleScope,\n" ++
        "): Promise<\n" ++
        "    | {\n" ++
        "          moduleRef: Module;\n" ++
        "          inserted: boolean;\n" ++
        "      }\n" ++
        "    | undefined\n" ++
        "> {\n" ++
        "    return 1;\n" ++
        "}\n";

    const wanted_a = "async function addModule(\n" ++
        "    metatype: ModuleMetatype,\n" ++
        "    scope: ModuleScope,\n" ++
        "): Promise<\n" ++
        "    | {\n" ++
        "          moduleRef: Module;\n" ++
        "          inserted: boolean;\n" ++
        "      }\n" ++
        "    | undefined\n" ++
        "> {\n" ++
        "    return 1;\n" ++
        "}\n";

    const source_b = "class A {\n" ++
        "    public async addModule(\n" ++
        "        metatype: ModuleMetatype,\n" ++
        "        scope: ModuleScope,\n" ++
        "    ): Promise<{\n" ++
        "        moduleRef: Module;\n" ++
        "    } | undefined> {\n" ++
        "        return 1;\n" ++
        "    }\n" ++
        "}\n";

    const wanted_b = "class A {\n" ++
        "    public async addModule(\n" ++
        "        metatype: ModuleMetatype,\n" ++
        "        scope: ModuleScope,\n" ++
        "    ): Promise<\n" ++
        "        | {\n" ++
        "              moduleRef: Module;\n" ++
        "          }\n" ++
        "        | undefined\n" ++
        "    > {\n" ++
        "        return 1;\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
}

test "an arrow whose body is a dynamic import is not grouped as the last argument" {
    const source_a = "async function f() {\n" ++
        "    await tryLoadPackage(\"@nestjs/platform-express\", () => " ++
        "import(\"@nestjs/platform-express\"));\n" ++
        "}\n";

    const wanted_a = "async function f() {\n" ++
        "    await tryLoadPackage(\n" ++
        "        \"@nestjs/platform-express\",\n" ++
        "        () => import(\"@nestjs/platform-express\"),\n" ++
        "    );\n" ++
        "}\n";

    const source_b = "async function f() {\n" ++
        "    await tryLoadPackage(\"@nestjs/platform-express\", () => " ++
        "import(\"@nestjs/x\").then((m) => m));\n" ++
        "}\n";

    const wanted_b = "async function f() {\n" ++
        "    await tryLoadPackage(\"@nestjs/platform-express\", () =>\n" ++
        "        import(\"@nestjs/x\").then((m) => m),\n" ++
        "    );\n" ++
        "}\n";

    const source_c = "const kafkaPackage = await loadPackage(\"kafkajs\", ClientKafka.name, () " ++
        "=> import(\"kafkajs\"));\n";

    const wanted_c = "const kafkaPackage = await loadPackage(\n" ++
        "    \"kafkajs\",\n" ++
        "    ClientKafka.name,\n" ++
        "    () => import(\"kafkajs\"),\n" ++
        ");\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(source_c, wanted_c);
}

test "a cast last argument hugs unless the argument before it is the same cast" {
    const source_a = "async function f() {\n" ++
        "    const result = await pipe.transform({ name: \"test\" }, {\n" ++
        "        type: \"body\",\n" ++
        "        schema,\n" ++
        "    } as ArgumentMetadata);\n" ++
        "}\n";

    const wanted_a = "async function f() {\n" ++
        "    const result = await pipe.transform({ name: \"test\" }, {\n" ++
        "        type: \"body\",\n" ++
        "        schema,\n" ++
        "    } as ArgumentMetadata);\n" ++
        "}\n";

    const source_b = "async function f() {\n" ++
        "    const result = await injector.resolveComponentHost({} as any, { name: " ++
        "\"TestName\" } as any);\n" ++
        "}\n";

    const wanted_b = "async function f() {\n" ++
        "    const result = await injector.resolveComponentHost(\n" ++
        "        {} as any,\n" ++
        "        { name: \"TestName\" } as any,\n" ++
        "    );\n" ++
        "}\n";

    const source_c = "async function f() {\n" ++
        "    const result = await injector.resolveComponentHost(mock as any, { " ++
        "name: \"TestName\", metatype: 1 } as any);\n" ++
        "}\n";

    const wanted_c = "async function f() {\n" ++
        "    const result = await injector.resolveComponentHost(\n" ++
        "        mock as any,\n" ++
        "        { name: \"TestName\", metatype: 1 } as any,\n" ++
        "    );\n" ++
        "}\n";

    const source_d = "async function f() {\n" ++
        "    const result = await injector.resolveComponentHost({} satisfies any, " ++
        "{ name: \"TestName\", met: 1 } as any);\n" ++
        "}\n";

    const wanted_d = "async function f() {\n" ++
        "    const result = await injector.resolveComponentHost({} satisfies any, " ++
        "{\n" ++
        "        name: \"TestName\",\n" ++
        "        met: 1,\n" ++
        "    } as any);\n" ++
        "}\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(source_c, wanted_c);
    try expect_formatted(source_d, wanted_d);
}

test "a clause condition that fits joins its source breaks over an unbraced body" {
    const source_a = "function pctChange(newValue: number, oldValue: number): number | null {\n" ++
        "    if (\n" ++
        "        !Number.isFinite(newValue) ||\n" ++
        "        !Number.isFinite(oldValue) ||\n" ++
        "        oldValue === 0\n" ++
        "    )\n" ++
        "        return null;\n" ++
        "    return 1;\n" ++
        "}\n";

    const wanted_a = "function pctChange(newValue: number, oldValue: number): number | null {\n" ++
        "    if (!Number.isFinite(newValue) || !Number.isFinite(oldValue) || " ++
        "oldValue === 0)\n" ++
        "        return null;\n" ++
        "    return 1;\n" ++
        "}\n";

    const source_b = "function f() {\n" ++
        "  if (\n" ++
        "    !Number.isFinite(newValue) ||\n" ++
        "    !Number.isFinite(oldValue) ||\n" ++
        "    vvvvvvvvvvvvvv === 0\n" ++
        "  )\n" ++
        "    return null;\n" ++
        "  return 1;\n" ++
        "}\n";

    const wanted_b = "function f() {\n" ++
        "    if (\n" ++
        "        !Number.isFinite(newValue) ||\n" ++
        "        !Number.isFinite(oldValue) ||\n" ++
        "        vvvvvvvvvvvvvv === 0\n" ++
        "    )\n" ++
        "        return null;\n" ++
        "    return 1;\n" ++
        "}\n";

    const source_c = "function f() {\n" ++
        "  while (\n" ++
        "    !Number.isFinite(newValue) ||\n" ++
        "    !Number.isFinite(oldValue) ||\n" ++
        "    vvvvvvvv === 0\n" ++
        "  )\n" ++
        "    x++;\n" ++
        "  return 1;\n" ++
        "}\n";

    const wanted_c = "function f() {\n" ++
        "    while (!Number.isFinite(newValue) || !Number.isFinite(oldValue) || " ++
        "vvvvvvvv === 0)\n" ++
        "        x++;\n" ++
        "    return 1;\n" ++
        "}\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(source_c, wanted_c);
}

test "a statement level binary run that fits joins the break its source wrote" {
    const source_a = "function f() {\n" ++
        "    a &&\n" ++
        "        b();\n" ++
        "}\n";

    const wanted_a = "function f() {\n" ++
        "    a && b();\n" ++
        "}\n";

    const source_b = "class A {\n" ++
        "    public x() {\n" ++
        "        applicationRef.setErrorHandler &&\n" ++
        "            applicationRef.setErrorHandler(proxy, prefix);\n" ++
        "    }\n" ++
        "}\n";

    const wanted_b = "class A {\n" ++
        "    public x() {\n" ++
        "        applicationRef.setErrorHandler && " ++
        "applicationRef.setErrorHandler(proxy, prefix);\n" ++
        "    }\n" ++
        "}\n";

    const source_c = "function addition() {\n" ++
        "    0 +\n" ++
        "        // Comment\n" ++
        "        x;\n" ++
        "}\n";

    const wanted_c = "function addition() {\n" ++
        "    0 +\n" ++
        "        // Comment\n" ++
        "        x;\n" ++
        "}\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(source_c, wanted_c);
}

test "a typed arrow call in a broken object measures from its own property" {
    const source = "const m = {\n" ++
        "    findOne: vi.fn((id: number): Post => mockPost),\n" ++
        "    findAll: vi.fn((): Post[] => [mockPost]),\n" ++
        "};\n";

    const wanted = "const m = {\n" ++
        "    findOne: vi.fn((id: number): Post => mockPost),\n" ++
        "    findAll: vi.fn((): Post[] => [mockPost]),\n" ++
        "};\n";

    try expect_formatted(source, wanted);
}

test "a function type's broken type parameters keep a trailing comma" {
    const source_a = "export type HandleSseResponseFn = <TResult extends Observable<unknown> = " ++
        "any, TResponse extends HeaderStream = any>(result: TResult) => any;\n";

    const wanted_a = "export type HandleSseResponseFn = <\n" ++
        "    TResult extends Observable<unknown> = any,\n" ++
        "    TResponse extends HeaderStream = any,\n" ++
        ">(\n" ++
        "    result: TResult,\n" ++
        ") => any;\n";

    const source_b = "type C = new <TResult extends Observable<unknown> = any, TResponse " ++
        "extends HeaderStream = any>(result: TResult) => any;\n";

    const wanted_b = "type C = new <\n" ++
        "    TResult extends Observable<unknown> = any,\n" ++
        "    TResponse extends HeaderStream = any,\n" ++
        ">(\n" ++
        "    result: TResult,\n" ++
        ") => any;\n";

    const source_c = "const v = someFunctionNameHere<TypeArgumentNumberOne, " ++
        "TypeArgumentNumberTwo, TypeArgumentNumberThree>(a);\n";

    const wanted_c = "const v = someFunctionNameHere<\n" ++
        "    TypeArgumentNumberOne,\n" ++
        "    TypeArgumentNumberTwo,\n" ++
        "    TypeArgumentNumberThree\n" ++
        ">(a);\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(source_c, wanted_c);
}

test "an arrow's parameters break with the type parameters that overflow" {
    const source_a = "const handle = <TResult extends Observable<unknown> = any, TResponse " ++
        "extends HeaderStream = any>(result: TResult) => result;\n";

    const wanted_a = "const handle = <\n" ++
        "    TResult extends Observable<unknown> = any,\n" ++
        "    TResponse extends HeaderStream = any,\n" ++
        ">(\n" ++
        "    result: TResult,\n" ++
        ") => result;\n";

    const source_b = "f(<TResult extends Observable<unknown> = any, TResponse extends " ++
        "HeaderStream = any>(result: TResult) => result);\n";

    const wanted_b = "f(\n" ++
        "    <TResult extends Observable<unknown> = any, TResponse extends " ++
        "HeaderStream = any>(\n" ++
        "        result: TResult,\n" ++
        "    ) => result,\n" ++
        ");\n";

    const source_c = "class A {\n" ++
        "  private readonly handler = async <TResult extends Observable<unknown> = " ++
        "any, TResponse = any>(result: TResult, res: TResponse) => {\n" ++
        "    return 1;\n" ++
        "  };\n" ++
        "}\n";

    const wanted_c = "class A {\n" ++
        "    private readonly handler = async <\n" ++
        "        TResult extends Observable<unknown> = any,\n" ++
        "        TResponse = any,\n" ++
        "    >(\n" ++
        "        result: TResult,\n" ++
        "        res: TResponse,\n" ++
        "    ) => {\n" ++
        "        return 1;\n" ++
        "    };\n" ++
        "}\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(source_c, wanted_c);
}

test "a typed arrow argument is measured on the line its broken call gives it" {
    const source = "class A {\n" ++
        "    get paramMap(): Observable<ParamMap> {\n" ++
        "        this._paramMap ??= this.params.pipe(map((p: Params): ParamMap => " ++
        "convertToParamMap(p)));\n" ++
        "        return this._paramMap;\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "class A {\n" ++
        "    get paramMap(): Observable<ParamMap> {\n" ++
        "        this._paramMap ??= this.params.pipe(\n" ++
        "            map((p: Params): ParamMap => convertToParamMap(p)),\n" ++
        "        );\n" ++
        "        return this._paramMap;\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a mapped type key never breaks inside its brackets" {
    const source_a = "type EnvironmentPluginHooksContextMatched = {\n" ++
        "  [\n" ++
        "    K in keyof EnvironmentPluginHooksContext\n" ++
        "  ]: EnvironmentPluginHooksContext[K] extends PluginContextExtension\n" ++
        "    ? never\n" ++
        "    : false\n" ++
        "}\n";

    const wanted_a = "type EnvironmentPluginHooksContextMatched = {\n" ++
        "    [K in keyof EnvironmentPluginHooksContext]: " ++
        "EnvironmentPluginHooksContext[K] extends PluginContextExtension\n" ++
        "        ? never\n" ++
        "        : false;\n" ++
        "};\n";

    const source_b = "let m: { [\n" ++
        "  K in keyof X]: T } = 1\n";

    const wanted_b = "let m: {\n" ++
        "    [K in keyof X]: T;\n" ++
        "} = 1;\n";

    const source_c = "type M = {\n" ++
        "  [K in\n" ++
        "    keyof X\n" ++
        "  as\n" ++
        "    Y]: T\n" ++
        "}\n";

    const wanted_c = "type M = {\n" ++
        "    [K in keyof X as Y]: T;\n" ++
        "};\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(source_c, wanted_c);
}

test "a line break before a mapped type key name expands its braces" {
    const source_a = "type M = { [\n" ++
        "  K in keyof X]: T }\n";

    const wanted_a = "type M = {\n" ++
        "    [K in keyof X]: T;\n" ++
        "};\n";

    const source_b = "type M = { readonly\n" ++
        "  [K in keyof X]: T }\n";

    const wanted_b = "type M = {\n" ++
        "    readonly [K in keyof X]: T;\n" ++
        "};\n";

    const source_c = "type M = { -readonly [\n" ++
        "  K in keyof X]-?: T }\n";

    const wanted_c = "type M = {\n" ++
        "    -readonly [K in keyof X]-?: T;\n" ++
        "};\n";

    const source_d = "type M = { [K in keyof X]:\n" ++
        "  T }\n";

    const wanted_d = "type M = { [K in keyof X]: T };\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(source_c, wanted_c);
    try expect_formatted(source_d, wanted_d);
}

test "a function named like a type operator is not a union head" {
    const source_a = "export function unique<T>(arr: T[]): T[] {\n" ++
        "  return [...new Set(arr)]\n" ++
        "}\n" ++
        "\n" ++
        "export function getLocalhostAddressIfDiffersFromDNS():\n" ++
        "  | Promise<string | undefined>\n" ++
        "  | undefined {\n" ++
        "  return undefined\n" ++
        "}\n";

    const wanted_a = "export function unique<T>(arr: T[]): T[] {\n" ++
        "    return [...new Set(arr)];\n" ++
        "}\n" ++
        "\n" ++
        "export function getLocalhostAddressIfDiffersFromDNS():\n" ++
        "    | Promise<string | undefined>\n" ++
        "    | undefined {\n" ++
        "    return undefined;\n" ++
        "}\n";

    const source_b = "function unique(arr: T[]): T[] {\n" ++
        "  return 1\n" ++
        "}\n" ++
        "\n" ++
        "function g(): P<S | U> | U {\n" ++
        "  return 2\n" ++
        "}\n";

    const wanted_b = "function unique(arr: T[]): T[] {\n" ++
        "    return 1;\n" ++
        "}\n" ++
        "\n" ++
        "function g(): P<S | U> | U {\n" ++
        "    return 2;\n" ++
        "}\n";

    const source_c = "let x: unique symbol\n" ++
        "function f(x: unknown): asserts x is string {}\n" ++
        "const asserts = (x) => x\n" ++
        "function g(): asserts x {}\n";

    const wanted_c = "let x: unique symbol;\n" ++
        "function f(x: unknown): asserts x is string {}\n" ++
        "const asserts = (x) => x;\n" ++
        "function g(): asserts x {}\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(source_c, wanted_c);
}

test "a comment after a union bar leaves the bar a type operator" {
    const source_a = "export type Environment =\n" ++
        "  | DevEnvironment\n" ++
        "  | BuildEnvironment\n" ++
        "  | /** @internal */ ScanEnvironment\n" ++
        "  | UnknownEnvironment\n";

    const wanted_a = "export type Environment =\n" ++
        "    | DevEnvironment\n" ++
        "    | BuildEnvironment\n" ++
        "    | /** @internal */ ScanEnvironment\n" ++
        "    | UnknownEnvironment;\n";

    const source_b = "type E = A | /** c */ B | CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC" ++
        "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC\n";

    const wanted_b = "type E =\n" ++
        "    | A\n" ++
        "    | /** c */ B\n" ++
        "    | CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC" ++
        "CCCCCCCCCCCCCC;\n";

    const source_c = "type E = A | /** c */ B\n";
    const wanted_c = "type E = A | /** c */ B;\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(source_c, wanted_c);
}

test "a binary operand call written broken joins when it fits" {
    const source_a = "function z() {\n" ++
        "    this.warn(\n" ++
        "        `\\n` +\n" ++
        "            colors.reset(\n" ++
        "                generateCodeFrame(source, start, end),\n" ++
        "            ) +\n" ++
        "            colors.yellow(\n" ++
        "                `\\nThe above dynamic import cannot be analyzed by " ++
        "Vite.\\n`,\n" ++
        "            ),\n" ++
        "    );\n" ++
        "}\n";

    const wanted_a = "function z() {\n" ++
        "    this.warn(\n" ++
        "        `\\n` +\n" ++
        "            colors.reset(generateCodeFrame(source, start, end)) +\n" ++
        "            colors.yellow(`\\nThe above dynamic import cannot be analyzed " ++
        "by Vite.\\n`),\n" ++
        "    );\n" ++
        "}\n";

    const source_b = "x = a + foo({\n" ++
        "  b: 1,\n" ++
        "}) + c;\n";

    const wanted_b = "x =\n" ++
        "    a +\n" ++
        "    foo({\n" ++
        "        b: 1,\n" ++
        "    }) +\n" ++
        "    c;\n";

    const source_c = "x = a + foo(\n" ++
        "  b,\n" ++
        ") + c;\n";

    const wanted_c = "x = a + foo(b) + c;\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(source_c, wanted_c);
}

test "an empty statement after a case label or at the head of a labeled block drops" {
    const source_a = "switch (tag.injectTo) {\n" ++
        "  case 'body':\n" ++
        "    ;(bodyTags ??= []).push(tag)\n" ++
        "    break\n" ++
        "  default:\n" ++
        "    ;(headTags ??= []).push(tag)\n" ++
        "}\n";

    const wanted_a = "switch (tag.injectTo) {\n" ++
        "    case \"body\":\n" ++
        "        (bodyTags ??= []).push(tag);\n" ++
        "        break;\n" ++
        "    default:\n" ++
        "        (headTags ??= []).push(tag);\n" ++
        "}\n";

    const source_b = "foo: ;\n" ++
        "bar: {\n" ++
        "  ;(x)()\n" ++
        "}\n";

    const wanted_b = "foo:;\n" ++
        "bar: {\n" ++
        "    x();\n" ++
        "}\n";

    const source_c = "switch (a) {\n" ++
        "  case 1: ;\n" ++
        "  case 2:\n" ++
        "    ;\n" ++
        "    f()\n" ++
        "  default: ;\n" ++
        "}\n";

    const wanted_c = "switch (a) {\n" ++
        "    case 1:\n" ++
        "    case 2:\n" ++
        "        f();\n" ++
        "    default:\n" ++
        "}\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(source_c, wanted_c);
}

test "a bodiless ambient module owes its semicolon" {
    const source_a = "declare module 'babel-plugin-polyfill-corejs3'\n" ++
        "\n" ++
        "declare module 'babel-plugin-polyfill-regenerator'\n";

    const wanted_a = "declare module \"babel-plugin-polyfill-corejs3\";\n" ++
        "\n" ++
        "declare module \"babel-plugin-polyfill-regenerator\";\n";

    const source_b = "declare module 'a'\n" ++
        "declare module 'b' {\n" ++
        "  export const x: number\n" ++
        "}\n";

    const wanted_b = "declare module \"a\";\n" ++
        "declare module \"b\" {\n" ++
        "    export const x: number;\n" ++
        "}\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
}

test "a member or method named import is not a dynamic import" {
    const source_a = "async function f() {\n" ++
        "  const mod = await runner.import(\n" ++
        "    '/fixtures/test-dep-conditions-app/entry-with-module-xxxxxxxxxxxxxxxxx" ++
        "x',\n" ++
        "  )\n" ++
        "}\n";

    const wanted_a = "async function f() {\n" ++
        "    const mod = await runner.import(\n" ++
        "        \"/fixtures/test-dep-conditions-app/entry-with-module-xxxxxxxxxxxx" ++
        "xxxxxx\",\n" ++
        "    );\n" ++
        "}\n";

    const source_b = "async function f() {\n" ++
        "  const mod = await import(\n" ++
        "    '/fixtures/test-dep-conditions-app/entry-with-module-xxxxxxxxxxxxxxxxx" ++
        "xxxxxxx'\n" ++
        "  )\n" ++
        "}\n";

    const wanted_b = "async function f() {\n" ++
        "    const mod = await import(\n" ++
        "        \"/fixtures/test-dep-conditions-app/entry-with-module-xxxxxxxxxxxx" ++
        "xxxxxxxxxxxx\"\n" ++
        "    );\n" ++
        "}\n";

    const source_c = "const a = {\n" ++
        "  import(xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx, " ++
        "yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy) {}\n" ++
        "}\n";

    const wanted_c = "const a = {\n" ++
        "    import(\n" ++
        "        xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx,\n" ++
        "        yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy,\n" ++
        "    ) {},\n" ++
        "};\n";

    const source_d = "class A {\n" ++
        "  import(xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx: number, " ++
        "yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy): void {}\n" ++
        "}\n";

    const wanted_d = "class A {\n" ++
        "    import(\n" ++
        "        xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx: number,\n" ++
        "        yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy,\n" ++
        "    ): void {}\n" ++
        "}\n";

    const source_e = "const x = a ? import('/fixtures/test-dep-conditions-app/entry-with-module-" ++
        "xxxxxxxxxxxxx') : b\n";

    const wanted_e = "const x = a\n" ++
        "    ? import(\"/fixtures/test-dep-conditions-app/entry-with-module-xxxxxxx" ++
        "xxxxxx\")\n" ++
        "    : b;\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(source_c, wanted_c);
    try expect_formatted(source_d, wanted_d);
    try expect_formatted(source_e, wanted_e);
}

test "an export-from list written broken stays broken" {
    const source_a = "export {\n" ++
        "  a,\n" ++
        "  b,\n" ++
        "} from 'x'\n";

    const wanted_a = "export {\n" ++
        "    a,\n" ++
        "    b,\n" ++
        "} from \"x\";\n";

    const source_b = "export type {\n" ++
        "  TransformOptions,\n" ++
        "  TransformResult,\n" ++
        "} from './server/transformRequest'\n";

    const wanted_b = "export type {\n" ++
        "    TransformOptions,\n" ++
        "    TransformResult,\n" ++
        "} from \"./server/transformRequest\";\n";

    const source_c = "export {\n" ++
        "  a\n" ++
        "} from 'x'\n";

    const wanted_c = "export { a } from \"x\";\n";

    const source_d = "export { a,\n" ++
        "  b } from 'x'\n";

    const wanted_d = "export { a, b } from \"x\";\n";

    const source_e = "export {\n" ++
        "  a,\n" ++
        "  b,\n" ++
        "}\n";

    const wanted_e = "export { a, b };\n";

    const source_f = "import {\n" ++
        "  a,\n" ++
        "  b,\n" ++
        "} from 'x'\n";

    const wanted_f = "import { a, b } from \"x\";\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(source_c, wanted_c);
    try expect_formatted(source_d, wanted_d);
    try expect_formatted(source_e, wanted_e);
    try expect_formatted(source_f, wanted_f);
}

test "a returned angle that opens no group joins its source breaks" {
    const source_a = "async function tryBindServer(\n" ++
        "  httpServer: HttpServer,\n" ++
        "  port: number,\n" ++
        "  host: string | undefined,\n" ++
        "): Promise<\n" ++
        "  { success: true } | { success: false; error: NodeJS.ErrnoException }\n" ++
        "> {\n" ++
        "  return 1\n" ++
        "}\n";

    const wanted_a = "async function tryBindServer(\n" ++
        "    httpServer: HttpServer,\n" ++
        "    port: number,\n" ++
        "    host: string | undefined,\n" ++
        "): Promise<{ success: true } | { success: false; error: " ++
        "NodeJS.ErrnoException }> {\n" ++
        "    return 1;\n" ++
        "}\n";

    const source_b = "function f(): Promise<\n" ++
        "  A | B\n" ++
        "> {\n" ++
        "  return 1\n" ++
        "}\n";

    const wanted_b = "function f(): Promise<A | B> {\n" ++
        "    return 1;\n" ++
        "}\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
}

test "an arrow body led by a block comment keeps its template on the arrow line" {
    const source_a = "export const main = (view1Content) => /* html */ `\n" ++
        "  <div>\n" ++
        "    ${view1Content}\n" ++
        "  </div>\n" ++
        "`\n";

    const wanted_a = "export const main = (view1Content) => /* html */ `\n" ++
        "  <div>\n" ++
        "    ${view1Content}\n" ++
        "  </div>\n" ++
        "`;\n";

    const source_b = "items.map((item) => /* html */ `\n" ++
        "  <li>${item}</li>\n" ++
        "`)\n";

    const wanted_b = "items.map(\n" ++
        "    (item) => /* html */ `\n" ++
        "  <li>${item}</li>\n" ++
        "`,\n" ++
        ");\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
}

test "a blank line before a dropped empty class member survives" {
    const source_a = "class A {\n" ++
        "  a() {}\n" ++
        "\n" ++
        "  ;\n" ++
        "  b() {}\n" ++
        "}\n";

    const wanted_a = "class A {\n" ++
        "    a() {}\n" ++
        "\n" ++
        "    b() {}\n" ++
        "}\n";

    const source_b = "class A {\n" ++
        "  a() {}\n" ++
        "  ;\n" ++
        "\n" ++
        "  b() {}\n" ++
        "}\n";

    const wanted_b = "class A {\n" ++
        "    a() {}\n" ++
        "\n" ++
        "    b() {}\n" ++
        "}\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
}

test "a leading byte-order mark stays at the head of the output" {
    const source = "\xef\xbb\xbfconst x: number = 1\n";
    const wanted = "\xef\xbb\xbfconst x: number = 1;\n";

    try expect_formatted(source, wanted);
}

test "a type literal member ending in a block comment keeps its semicolon" {
    const source_a = "export type F = {\n" ++
        "  (...args: any[]): any\n" ++
        "  _n: boolean /* already normalized */\n" ++
        "  _ns: boolean /* nonScoped */\n" ++
        "}\n";

    const wanted_a = "export type F = {\n" ++
        "    (...args: any[]): any;\n" ++
        "    _n: boolean /* already normalized */;\n" ++
        "    _ns: boolean /* nonScoped */;\n" ++
        "};\n";

    const source_b = "export type F = {\n" ++
        "  a: T /* x */\n" ++
        "  b: U /* c1 */ /* c2 */\n" ++
        "}\n";

    const wanted_b = "export type F = {\n" ++
        "    a: T /* x */;\n" ++
        "    b: U /* c1 */ /* c2 */;\n" ++
        "};\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
}

test "every block comment trailing a member separator moves before it" {
    const source = "export type F = {\n" ++
        "  _n: boolean /* c1 */ /* c3 */\n" ++
        "  _ns: boolean\n" ++
        "}\n";

    const wanted = "export type F = {\n" ++
        "    _n: boolean /* c1 */ /* c3 */;\n" ++
        "    _ns: boolean;\n" ++
        "};\n";

    try expect_formatted(source, wanted);
}

test "an arrow's type parameter holding a function type joins when it fits" {
    const source_a = "export const withModifiers = <\n" ++
        "  T extends (event: Event, ...args: unknown[]) => any,\n" ++
        ">(\n" ++
        "  fn: T & { _withMods?: { [key: string]: T } },\n" ++
        "  modifiers: VOnModifiers[],\n" ++
        "): T => {\n" ++
        "  return fn\n" ++
        "}\n";

    const wanted_a = "export const withModifiers = <T extends (event: Event, ...args: " ++
        "unknown[]) => any>(\n" ++
        "    fn: T & { _withMods?: { [key: string]: T } },\n" ++
        "    modifiers: VOnModifiers[],\n" ++
        "): T => {\n" ++
        "    return fn;\n" ++
        "};\n";

    const source_b = "export const w = <\n" ++
        "  T extends (event: Event) => any,\n" ++
        ">(\n" ++
        "  fn: T,\n" ++
        "): T => {\n" ++
        "  return fn\n" ++
        "}\n";

    const wanted_b = "export const w = <T extends (event: Event) => any>(fn: T): T => {\n" ++
        "    return fn;\n" ++
        "};\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
}

test "a union alone in a broken type argument list measures from its own line" {
    const source = "const props = withDefaults(\n" ++
        "  defineProps<\n" ++
        "    { type: 'button'; buttonType?: 'submit' } | { type: 'link'; hrefsss: " ++
        "string }\n" ++
        "  >(),\n" ++
        "  {\n" ++
        "    type: 'button',\n" ++
        "  },\n" ++
        ")\n";

    const wanted = "const props = withDefaults(\n" ++
        "    defineProps<\n" ++
        "        { type: \"button\"; buttonType?: \"submit\" } | { type: \"link\"; " ++
        "hrefsss: string }\n" ++
        "    >(),\n" ++
        "    {\n" ++
        "        type: \"button\",\n" ++
        "    },\n" ++
        ");\n";

    try expect_formatted(source, wanted);
}

test "an interface's first heritage name stays on its extends line" {
    const source_a = "export interface TransformOptions\n" ++
        "  extends\n" ++
        "    SharedTransformCodegenOptions,\n" ++
        "    ErrorHandlingOptions,\n" ++
        "    CompilerCompatOptions {\n" ++
        "  a: string\n" ++
        "}\n";

    const wanted_a = "export interface TransformOptions\n" ++
        "    extends SharedTransformCodegenOptions,\n" ++
        "        ErrorHandlingOptions,\n" ++
        "        CompilerCompatOptions {\n" ++
        "    a: string;\n" ++
        "}\n";

    const source_b = "class A\n" ++
        "  extends\n" ++
        "    B {\n" ++
        "  a = 1\n" ++
        "}\n";

    const wanted_b = "class A extends B {\n" ++
        "    a = 1;\n" ++
        "}\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
}

test "an intersection written broken joins when it fits" {
    const source_a = "export type LegacyPublicInstance = ComponentPublicInstance &\n" ++
        "  LegacyPublicProperties\n";

    const wanted_a = "export type LegacyPublicInstance = ComponentPublicInstance & " ++
        "LegacyPublicProperties;\n";

    const source_b = "export type A = B &\n" ++
        "  C &\n" ++
        "  D\n";

    const wanted_b = "export type A = B & C & D;\n";

    const source_c = "export type A = {\n" ++
        "  b: B &\n" ++
        "    C\n" ++
        "}\n";

    const wanted_c = "export type A = {\n" ++
        "    b: B & C;\n" ++
        "};\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(source_c, wanted_c);
}

test "an access modifier name followed by parameters is a method name" {
    const source = "class Q {\n" ++
        "  private(a, b) {\n" ++
        "    return a;\n" ++
        "  }\n" ++
        "  public() {}\n" ++
        "  protected() {}\n" ++
        "  public [k]() {}\n" ++
        "  private [Symbol.iterator](): void {}\n" ++
        "}\n" ++
        "const o = { private(a) {}, public: 1, protected() {} };\n" ++
        "declare class A {\n" ++
        "  private (): void;\n" ++
        "}\n";

    const wanted = "class Q {\n" ++
        "    private(a, b) {\n" ++
        "        return a;\n" ++
        "    }\n" ++
        "    public() {}\n" ++
        "    protected() {}\n" ++
        "    public [k]() {}\n" ++
        "    private [Symbol.iterator](): void {}\n" ++
        "}\n" ++
        "const o = { private(a) {}, public: 1, protected() {} };\n" ++
        "declare class A {\n" ++
        "    private(): void;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a stray semicolon after a decorated class or a typed method is dropped" {
    const source_a = "@Injectable()\n" ++
        "export class B {\n" ++
        "  constructor() {}\n" ++
        "};\n";

    const wanted_a = "@Injectable()\n" ++
        "export class B {\n" ++
        "    constructor() {}\n" ++
        "}\n";

    const source_b = "export class R {\n" ++
        "  private g(): Observable<C[]> {\n" ++
        "    return c;\n" ++
        "  };\n" ++
        "  @Dec() h(): O {\n" ++
        "    return c;\n" ++
        "  };\n" ++
        "  x = () => {\n" ++
        "    return 1;\n" ++
        "  };\n" ++
        "}\n";

    const wanted_b = "export class R {\n" ++
        "    private g(): Observable<C[]> {\n" ++
        "        return c;\n" ++
        "    }\n" ++
        "    @Dec() h(): O {\n" ++
        "        return c;\n" ++
        "    }\n" ++
        "    x = () => {\n" ++
        "        return 1;\n" ++
        "    };\n" ++
        "}\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(wanted_a, wanted_a);
    try expect_formatted(wanted_b, wanted_b);
}

test "a conditional type alias breaks after the equals only when a side is a generic reference" {
    const source = "function f() {\n" ++
        "    it(\"x\", () => {\n" ++
        "        type HasStringNamedBufferTime = \"bufferTime\" extends keyof " ++
        "Observable<unknown> ? true : false;\n" ++
        "    });\n" ++
        "}\n" ++
        "type HasStringNamedBufferTimexxxxxx = \"bufferTime\" extends keyof " ++
        "Observable<unknown> ? true : false;\n" ++
        "type HasStringNamedBufferTimexxxxxx = \"bufferTime\" extends " ++
        "Observable<unknown> ? true : false;\n" ++
        "type HasStringNamedBufferTimexxxxxx = Array<string> extends keyof " ++
        "Observable ? true : false;\n" ++
        "type HasStringNamedBufferTimexxxxxxxxxxxxxxxxxxx = \"bufferTime\" extends " ++
        "keyof Observable ? true : false;\n";

    const wanted = "function f() {\n" ++
        "    it(\"x\", () => {\n" ++
        "        type HasStringNamedBufferTime = \"bufferTime\" extends keyof " ++
        "Observable<unknown>\n" ++
        "            ? true\n" ++
        "            : false;\n" ++
        "    });\n" ++
        "}\n" ++
        "type HasStringNamedBufferTimexxxxxx = \"bufferTime\" extends keyof " ++
        "Observable<unknown>\n" ++
        "    ? true\n" ++
        "    : false;\n" ++
        "type HasStringNamedBufferTimexxxxxx =\n" ++
        "    \"bufferTime\" extends Observable<unknown> ? true : false;\n" ++
        "type HasStringNamedBufferTimexxxxxx =\n" ++
        "    Array<string> extends keyof Observable ? true : false;\n" ++
        "type HasStringNamedBufferTimexxxxxxxxxxxxxxxxxxx = \"bufferTime\" extends " ++
        "keyof Observable\n" ++
        "    ? true\n" ++
        "    : false;\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a computed call after a new expression is a member chain group" {
    const source_a = "function f() {\n" ++
        "    new Observable<number>((subscriber) => " ++
        "subscriber.complete())[every]((value) => value > 0).subscribe({\n" ++
        "        next: (value) => emptyResults.push(value),\n" ++
        "        complete: () => emptyResults.push(\"complete\"),\n" ++
        "    });\n" ++
        "}\n";

    const wanted_a = "function f() {\n" ++
        "    new Observable<number>((subscriber) => subscriber.complete())\n" ++
        "        [every]((value) => value > 0)\n" ++
        "        .subscribe({\n" ++
        "            next: (value) => emptyResults.push(value),\n" ++
        "            complete: () => emptyResults.push(\"complete\"),\n" ++
        "        });\n" ++
        "}\n";

    const source_b = "function g() {\n" ++
        "    new Observable<number>((subscriber) => {\n" ++
        "        subscriber.next(1);\n" ++
        "        subscriber.error(failure);\n" ++
        "    })[pairwise]().subscribe({\n" ++
        "        next: (value) => errorEvents.push(value),\n" ++
        "        error: (error) => errors.push(error),\n" ++
        "    });\n" ++
        "}\n";

    const wanted_b = "function g() {\n" ++
        "    new Observable<number>((subscriber) => {\n" ++
        "        subscriber.next(1);\n" ++
        "        subscriber.error(failure);\n" ++
        "    })\n" ++
        "        [pairwise]()\n" ++
        "        .subscribe({\n" ++
        "            next: (value) => errorEvents.push(value),\n" ++
        "            error: (error) => errors.push(error),\n" ++
        "        });\n" ++
        "}\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(wanted_a, wanted_a);
    try expect_formatted(wanted_b, wanted_b);
}

test "a conditional type alias reads the generic test from its outermost extends" {
    const source = "export type AssertEqual<T, U> = (<V>() => V extends T ? 1 : 2) extends " ++
        "<V>() => V extends U ? 1 : 2 ? true : false;\n" ++
        "export type Wrapped<T> = (<V>() => V extends T ? 1 : 2) extends () => void " ++
        "? true : false;\n";

    const wanted = "export type AssertEqual<T, U> =\n" ++
        "    (<V>() => V extends T ? 1 : 2) extends <V>() => V extends U ? 1 : 2 ? " ++
        "true : false;\n" ++
        "export type Wrapped<T> =\n" ++
        "    (<V>() => V extends T ? 1 : 2) extends () => void ? true : false;\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a function expression's type parameters break before its assignment does" {
    const source = "Observable.prototype[catchError] = function <T, Replacement extends " ++
        "ObservableValue<any>>(\n" ++
        "  this: Observable<T>,\n" ++
        "  selector: (error: any, caught: Observable<T>) => Replacement\n" ++
        "): Observable<T | ObservedValueOf<Replacement>> {\n" ++
        "  const source = this;\n" ++
        "};\n" ++
        "Observable.prototype.catchErrorxxxxxxxxxx = function <T, Replacement " ++
        "extends ObservableValue<any>>(a: T) {\n" ++
        "  return a;\n" ++
        "};\n";

    const wanted = "Observable.prototype[catchError] = function <\n" ++
        "    T,\n" ++
        "    Replacement extends ObservableValue<any>,\n" ++
        ">(\n" ++
        "    this: Observable<T>,\n" ++
        "    selector: (error: any, caught: Observable<T>) => Replacement,\n" ++
        "): Observable<T | ObservedValueOf<Replacement>> {\n" ++
        "    const source = this;\n" ++
        "};\n" ++
        "Observable.prototype.catchErrorxxxxxxxxxx = function <\n" ++
        "    T,\n" ++
        "    Replacement extends ObservableValue<any>,\n" ++
        ">(a: T) {\n" ++
        "    return a;\n" ++
        "};\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "an annotation's type arguments join when the initializer can break after the equals" {
    const source = "export class OperatorDecisionTreeModule implements " ++
        "WithCustomElementComponent {\n" ++
        "  customElementComponent: Type<\n" ++
        "    OperatorDecisionTreeComponent\n" ++
        "  > = OperatorDecisionTreeComponent;\n" ++
        "}\n" ++
        "const customElementComponentxxxxxxxxx: Type<\n" ++
        "  OperatorDecisionTreeComponent\n" ++
        "> = OperatorDecisionTreeComponent;\n";

    const wanted = "export class OperatorDecisionTreeModule implements " ++
        "WithCustomElementComponent {\n" ++
        "    customElementComponent: Type<OperatorDecisionTreeComponent> =\n" ++
        "        OperatorDecisionTreeComponent;\n" ++
        "}\n" ++
        "const customElementComponentxxxxxxxxx: Type<OperatorDecisionTreeComponent> " ++
        "=\n" ++
        "    OperatorDecisionTreeComponent;\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "an arrow argument whose body compares a call is not hugged" {
    const source = "function f() {\n" ++
        "    function g() {\n" ++
        "        return this.announcements\n" ++
        "            .filter((announcement) => new " ++
        "Date(announcement.endDate).valueOf() > Date.now())[0];\n" ++
        "    }\n" ++
        "}\n" ++
        "const result = items.filter((announcement) => new " ++
        "Date(announcement.endDate).valueOf() > Date.now());\n";

    const wanted = "function f() {\n" ++
        "    function g() {\n" ++
        "        return this.announcements.filter(\n" ++
        "            (announcement) => new Date(announcement.endDate).valueOf() > " ++
        "Date.now(),\n" ++
        "        )[0];\n" ++
        "    }\n" ++
        "}\n" ++
        "const result = items.filter(\n" ++
        "    (announcement) => new Date(announcement.endDate).valueOf() > " ++
        "Date.now(),\n" ++
        ");\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a test call hugs an Angular test wrapper around its callback" {
    const source = "describe(\"x\", () => {\n" ++
        "    beforeEach(waitForAsync(() => {\n" ++
        "        locationService = jasmine.createSpyObj([\"subscribe\"]);\n" ++
        "        TestBed.configureTestingModule({ imports: [CommonModule, " ++
        "MatButtonModule, MatCardModule, MatRippleModule], declarations: " ++
        "[OperatorDecisionTreeComponent] });\n" ++
        "    }));\n" ++
        "\n" ++
        "    it(\"should debounce `updateScrollPositonInHistory()` when the user " ++
        "scrolls\", fakeAsync(() => {\n" ++
        "        window.dispatchEvent(new Event(\"scroll\"));\n" ++
        "        tick(249);\n" ++
        "    }));\n" ++
        "\n" ++
        "    it(\"should get the current search query from the location service\", " ++
        "fakeAsync(inject([LocationService], (location: MockLocationService) => {\n" ++
        "        location.search.and.returnValue({ search: \"initial search\" });\n" ++
        "    })));\n" ++
        "});\n";

    const wanted = "describe(\"x\", () => {\n" ++
        "    beforeEach(waitForAsync(() => {\n" ++
        "        locationService = jasmine.createSpyObj([\"subscribe\"]);\n" ++
        "        TestBed.configureTestingModule({\n" ++
        "            imports: [CommonModule, MatButtonModule, MatCardModule, " ++
        "MatRippleModule],\n" ++
        "            declarations: [OperatorDecisionTreeComponent],\n" ++
        "        });\n" ++
        "    }));\n" ++
        "\n" ++
        "    it(\"should debounce `updateScrollPositonInHistory()` when the user " ++
        "scrolls\", fakeAsync(() => {\n" ++
        "        window.dispatchEvent(new Event(\"scroll\"));\n" ++
        "        tick(249);\n" ++
        "    }));\n" ++
        "\n" ++
        "    it(\"should get the current search query from the location service\", " ++
        "fakeAsync(\n" ++
        "        inject([LocationService], (location: MockLocationService) => {\n" ++
        "            location.search.and.returnValue({ search: \"initial search\" " ++
        "});\n" ++
        "        }),\n" ++
        "    ));\n" ++
        "});\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a method's trailing pattern parameter breaks with its siblings" {
    const source = "class A {\n" ++
        "  retrySafariSessionxxxxxxxxxxxxxxx(create, { attempts, retryDelayMs, wait, " ++
        "xxxxxxxx }) {\n" ++
        "    return 1;\n" ++
        "  }\n" ++
        "}\n" ++
        "foo(create, { attempts, retryDelayMs, wait, " ++
        "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx });\n";

    const wanted = "class A {\n" ++
        "    retrySafariSessionxxxxxxxxxxxxxxx(\n" ++
        "        create,\n" ++
        "        { attempts, retryDelayMs, wait, xxxxxxxx },\n" ++
        "    ) {\n" ++
        "        return 1;\n" ++
        "    }\n" ++
        "}\n" ++
        "foo(create, {\n" ++
        "    attempts,\n" ++
        "    retryDelayMs,\n" ++
        "    wait,\n" ++
        "    xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx,\n" ++
        "});\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "an optional marker abuts its name however the source spaces it" {
    const source_a = "export class C {\n" ++
        "  bio?: string;\n" ++
        "  isFlipped ? = false;\n" ++
        "  other ?: number;\n" ++
        "  m ?(): void;\n" ++
        "}\n" ++
        "interface I {\n" ++
        "  a ?: number;\n" ++
        "  b ?(): void;\n" ++
        "}\n";

    const wanted_a = "export class C {\n" ++
        "    bio?: string;\n" ++
        "    isFlipped? = false;\n" ++
        "    other?: number;\n" ++
        "    m?(): void;\n" ++
        "}\n" ++
        "interface I {\n" ++
        "    a?: number;\n" ++
        "    b?(): void;\n" ++
        "}\n";

    const source_b = "type M<T> = { [K in keyof T] ?: T[K] };\n" ++
        "const x = a ? b : c;\n" ++
        "const y = a ?b:c;\n" ++
        "function f(a ?: number, c ?) {}\n" ++
        "const z = a ? [b] : c;\n";

    const wanted_b = "type M<T> = { [K in keyof T]?: T[K] };\n" ++
        "const x = a ? b : c;\n" ++
        "const y = a ? b : c;\n" ++
        "function f(a?: number, c?) {}\n" ++
        "const z = a ? [b] : c;\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(wanted_a, wanted_a);
    try expect_formatted(wanted_b, wanted_b);
}

test "a sole typed parameter still hugs its object type" {
    const source = "export function logValue(valueInfo: { directiveId: DirectivePosition; " ++
        "keyPath: string[] | null }): void {\n" ++
        "  return;\n" ++
        "}\n" ++
        "function logValues(first: string, valueInfo: { directiveId: " ++
        "DirectivePosition; keyPath: string[] | null }): void {\n" ++
        "  return;\n" ++
        "}\n";

    const wanted = "export function logValue(valueInfo: {\n" ++
        "    directiveId: DirectivePosition;\n" ++
        "    keyPath: string[] | null;\n" ++
        "}): void {\n" ++
        "    return;\n" ++
        "}\n" ++
        "function logValues(\n" ++
        "    first: string,\n" ++
        "    valueInfo: { directiveId: DirectivePosition; keyPath: string[] | null " ++
        "},\n" ++
        "): void {\n" ++
        "    return;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "same-line member decorators break onto their own line when the member overflows" {
    const source_a = "class HostComponent {\n" ++
        "  @ViewChild(CodeExampleComponent, {static: true}) codeExampleComponent: " ++
        "CodeExampleComponent;\n" ++
        "}\n" ++
        "class HostComponent {\n" ++
        "  @ViewChild(CodeExampleComponent, {static: true}) codeExample: " ++
        "CodeExample;\n" ++
        "}\n" ++
        "class HostComponent {\n" ++
        "  @Input() codeExampleComponentxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx: " ++
        "CodeExampleComponentxxxxxxx;\n" ++
        "}\n";

    const wanted_a = "class HostComponent {\n" ++
        "    @ViewChild(CodeExampleComponent, { static: true })\n" ++
        "    codeExampleComponent: CodeExampleComponent;\n" ++
        "}\n" ++
        "class HostComponent {\n" ++
        "    @ViewChild(CodeExampleComponent, { static: true }) codeExample: " ++
        "CodeExample;\n" ++
        "}\n" ++
        "class HostComponent {\n" ++
        "    @Input()\n" ++
        "    codeExampleComponentxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx: " ++
        "CodeExampleComponentxxxxxxx;\n" ++
        "}\n";

    const source_b = "class A {\n" ++
        "  @Input() a: string;\n" ++
        "  @Input() @Optional() bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb: " ++
        "SomeVeryLongTypeNameThatOverflows;\n" ++
        "  @Output()\n" ++
        "  changed = new EventEmitter<string>();\n" ++
        "  @HostListener('window:resize', ['$event']) onResize(event: Event) { " ++
        "this.x = 1; }\n" ++
        "  @ViewChild('ref', {static: false}) private readonly " ++
        "refxxxxxxxxxxxxxxxxx!: ElementRef<HTMLDivElement>;\n" ++
        "  static x = 1;\n" ++
        "  @Dec() static y = 2;\n" ++
        "  @Dec() get z() { return 1; }\n" ++
        "}\n";

    const wanted_b = "class A {\n" ++
        "    @Input() a: string;\n" ++
        "    @Input()\n" ++
        "    @Optional()\n" ++
        "    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb: " ++
        "SomeVeryLongTypeNameThatOverflows;\n" ++
        "    @Output()\n" ++
        "    changed = new EventEmitter<string>();\n" ++
        "    @HostListener(\"window:resize\", [\"$event\"]) onResize(event: Event) " ++
        "{\n" ++
        "        this.x = 1;\n" ++
        "    }\n" ++
        "    @ViewChild(\"ref\", { static: false })\n" ++
        "    private readonly refxxxxxxxxxxxxxxxxx!: ElementRef<HTMLDivElement>;\n" ++
        "    static x = 1;\n" ++
        "    @Dec() static y = 2;\n" ++
        "    @Dec() get z() {\n" ++
        "        return 1;\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(wanted_a, wanted_a);
    try expect_formatted(wanted_b, wanted_b);
}

test "a union in a hugged parameter's object type measures at the object's level" {
    const source = "declare global {\n" ++
        "  interface Observable<T> {\n" ++
        "    [retry](config?: {\n" ++
        "      count?: number;\n" ++
        "      delay?: number | ((error: any, retryCount: number) => " ++
        "ObservableValue<any>);\n" ++
        "      resetOnSuccess?: boolean;\n" ++
        "    }): Observable<T>;\n" ++
        "  }\n" ++
        "}\n" ++
        "interface Observable<T> {\n" ++
        "    retry(config?: {\n" ++
        "        count?: number;\n" ++
        "        delay?: number | ((error: any, retryCount: number) => " ++
        "ObservableValue<anyyyyy>);\n" ++
        "        resetOnSuccess?: boolean;\n" ++
        "    }): Observable<T>;\n" ++
        "}\n";

    const wanted = "declare global {\n" ++
        "    interface Observable<T> {\n" ++
        "        [retry](config?: {\n" ++
        "            count?: number;\n" ++
        "            delay?: number | ((error: any, retryCount: number) => " ++
        "ObservableValue<any>);\n" ++
        "            resetOnSuccess?: boolean;\n" ++
        "        }): Observable<T>;\n" ++
        "    }\n" ++
        "}\n" ++
        "interface Observable<T> {\n" ++
        "    retry(config?: {\n" ++
        "        count?: number;\n" ++
        "        delay?: number | ((error: any, retryCount: number) => " ++
        "ObservableValue<anyyyyy>);\n" ++
        "        resetOnSuccess?: boolean;\n" ++
        "    }): Observable<T>;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a computed callee with type arguments takes a trailing comma after its hugged arrow" {
    const source = "function f() {\n" ++
        "    it(\"x\", () => {\n" ++
        "        const created = source[createFromAnotherCompatibleCopy]<string>((sub" ++
        "scriber) => subscriber.complete());\n" ++
        "    });\n" ++
        "}\n";

    const wanted = "function f() {\n" ++
        "    it(\"x\", () => {\n" ++
        "        const created = source[createFromAnotherCompatibleCopy]<string>((sub" ++
        "scriber) =>\n" ++
        "            subscriber.complete(),\n" ++
        "        );\n" ++
        "    });\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a parenthesized member decorator keeps its parentheses tight" {
    const source = "class A {\n" ++
        "  @(decorators[0]) x = 1;\n" ++
        "  @(computed().volatile()) get y() { return 1; }\n" ++
        "  @(foo`bar`) z: string;\n" ++
        "}\n";

    const wanted = "class A {\n" ++
        "    @(decorators[0]) x = 1;\n" ++
        "    @(computed().volatile()) get y() {\n" ++
        "        return 1;\n" ++
        "    }\n" ++
        "    @(foo`bar`) z: string;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a call signature's type parameters join or break as a list" {
    const source_a = "interface A {\n" ++
        "  (a: number): B & C\n" ++
        "  <\n" ++
        "    S,\n" ++
        "    B\n" ++
        "  >(a: S): S\n" ++
        "  new <\n" ++
        "    S,\n" ++
        "  >(a: S): S\n" ++
        "}\n" ++
        "type E = {\n" ++
        "  <\n" ++
        "    S,\n" ++
        "    B\n" ++
        "  >(a: S): S, <T>(b: T): T\n" ++
        "}\n";

    const wanted_a = "interface A {\n" ++
        "    (a: number): B & C;\n" ++
        "    <S, B>(a: S): S;\n" ++
        "    new <S>(a: S): S;\n" ++
        "}\n" ++
        "type E = {\n" ++
        "    <S, B>(a: S): S;\n" ++
        "    <T>(b: T): T;\n" ++
        "};\n";

    const source_b = "export interface StoreCreator {\n" ++
        "  <\n" ++
        "    S,\n" ++
        "    A extends Action,\n" ++
        "    Ext extends {} = {},\n" ++
        "    StateExt extends {} = {},\n" ++
        "    PreloadedState = S\n" ++
        "  >(\n" ++
        "    reducer: Reducer<S, A, PreloadedState>,\n" ++
        "    preloadedState?: PreloadedState | undefined,\n" ++
        "    enhancer?: StoreEnhancer<Ext, StateExt>\n" ++
        "  ): Store<S, A, UnknownIfNonSpecific<StateExt>> & Ext\n" ++
        "}\n";

    const wanted_b = "export interface StoreCreator {\n" ++
        "    <\n" ++
        "        S,\n" ++
        "        A extends Action,\n" ++
        "        Ext extends {} = {},\n" ++
        "        StateExt extends {} = {},\n" ++
        "        PreloadedState = S,\n" ++
        "    >(\n" ++
        "        reducer: Reducer<S, A, PreloadedState>,\n" ++
        "        preloadedState?: PreloadedState | undefined,\n" ++
        "        enhancer?: StoreEnhancer<Ext, StateExt>,\n" ++
        "    ): Store<S, A, UnknownIfNonSpecific<StateExt>> & Ext;\n" ++
        "}\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(wanted_a, wanted_a);
    try expect_formatted(wanted_b, wanted_b);
}

test "a conditional type whose extends type is a union keeps its head on the equals line" {
    const source_a = "export type StateFromReducersMapObject<M> = M[keyof M] extends\n" ++
        "  | Reducer<any, any, any>\n" ++
        "  | undefined\n" ++
        "  ? {\n" ++
        "      [P in keyof M]: M[P] extends Reducer<infer S, any, any> ? S : " ++
        "never\n" ++
        "    }\n" ++
        "  : never\n";

    const wanted_a = "export type StateFromReducersMapObject<M> = M[keyof M] extends\n" ++
        "    | Reducer<any, any, any>\n" ++
        "    | undefined\n" ++
        "    ? {\n" ++
        "          [P in keyof M]: M[P] extends Reducer<infer S, any, any> ? S : " ++
        "never;\n" ++
        "      }\n" ++
        "    : never;\n";

    const source_b = "type Y<M> = MMMMMMM extends Reducer | undefined ? " ++
        "SomeResultTypeNameLongOne : AnotherResultType;\n";

    const wanted_b = "type Y<M> = MMMMMMM extends Reducer | undefined\n" ++
        "    ? SomeResultTypeNameLongOne\n" ++
        "    : AnotherResultType;\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(wanted_a, wanted_a);
    try expect_formatted(wanted_b, wanted_b);
}

test "a broken type parameter list owes its comma before a trailing line comment" {
    const source = "interface Foo {\n" ++
        " foo<\n" ++
        "  A// comment\n" ++
        " >(arg): any;\n" ++
        "}\n" ++
        "function f<\n" ++
        "  A // comment\n" ++
        ">(arg): any {}\n" ++
        "class B<\n" ++
        "  T, // first\n" ++
        "  U // second\n" ++
        "> {}\n";

    const wanted = "interface Foo {\n" ++
        "    foo<\n" ++
        "        A, // comment\n" ++
        "    >(arg): any;\n" ++
        "}\n" ++
        "function f<\n" ++
        "    A, // comment\n" ++
        ">(arg): any {}\n" ++
        "class B<\n" ++
        "    T, // first\n" ++
        "    U, // second\n" ++
        "> {}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a member access after a parenthesized jsx element stays on the closing parenthesis" {
    const source = "(<a />).method();\n" ++
        "(<a />)[\"computed\"]();\n" ++
        "(\n" ++
        "  <div>\n" ++
        "    <a>foo</a>\n" ++
        "  </div>\n" ++
        ")[\"computed\"];\n" ++
        "(\n" ++
        "  <div>\n" ++
        "    <a>foo</a>\n" ++
        "  </div>\n" ++
        ").method();\n";

    const wanted = "(<a />).method();\n" ++
        "(<a />)[\"computed\"]();\n" ++
        "(\n" ++
        "    <div>\n" ++
        "        <a>foo</a>\n" ++
        "    </div>\n" ++
        ")[\"computed\"];\n" ++
        "(\n" ++
        "    <div>\n" ++
        "        <a>foo</a>\n" ++
        "    </div>\n" ++
        ").method();\n";

    try expect_formatted_tsx(source, wanted);
}

test "parentheses an export default or an assertion target needs are kept" {
    const source_a = "export default (function log(){} as typeof console.log);\n";
    const wanted_a = "export default (function log() {} as typeof console.log);\n";

    const source_b = "export default (async function () {}.call());\n" ++
        "(<x>a) = 1;\n" ++
        "(<x>a) += 1;\n" ++
        "(<x>a)++;\n" ++
        "<x>a || {};\n";

    const wanted_b = "export default (async function () {}.call());\n" ++
        "(<x>a) = 1;\n" ++
        "(<x>a) += 1;\n" ++
        "(<x>a)++;\n" ++
        "<x>a || {};\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(wanted_a, wanted_a);
    try expect_formatted(wanted_b, wanted_b);
}

test "an intersection inside a union takes parentheses unless it has one member" {
    const source = "type C4 = & a | b;\n" ++
        "type C5 = & a & c | b;\n" ++
        "type C6 = a & c | b;\n" ++
        "type C7 = (a & c) | b;\n" ++
        "type C8 = b | & a;\n";

    const wanted = "type C4 = a | b;\n" ++
        "type C5 = (a & c) | b;\n" ++
        "type C6 = (a & c) | b;\n" ++
        "type C7 = (a & c) | b;\n" ++
        "type C8 = b | a;\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "an import alias's require call takes no trailing comma when it breaks" {
    const source = "import type T21 = require(\n" ++
        "// 11\n" ++
        "\"a\");\n" ++
        "import type T23 = require( /* 13 */\n" ++
        "  \"a\"\n" ++
        ");\n" ++
        "import B1 = require(\n" ++
        "// 1\n" ++
        "\"b\");\n" ++
        "const B2 = require(\n" ++
        "// 2\n" ++
        "\"b\");\n";

    const wanted = "import type T21 = require(\n" ++
        "    // 11\n" ++
        "    \"a\"\n" ++
        ");\n" ++
        "import type T23 = require(/* 13 */\n" ++
        "    \"a\"\n" ++
        ");\n" ++
        "import B1 = require(\n" ++
        "    // 1\n" ++
        "    \"b\"\n" ++
        ");\n" ++
        "const B2 = require(\n" ++
        "    // 2\n" ++
        "    \"b\",\n" ++
        ");\n";

    try expect_formatted(source, wanted);
}

test "a mapped type key takes no trailing comma when a comment breaks it" {
    const gpa = std.testing.allocator;
    const source = "type b = {\n  [\n    // prettier-ignore\n    A in B\n  ]: C  |  D\n};\n";
    var session: Session = undefined;

    try session.init(gpa);
    defer session.deinit(gpa);

    try session.held.format(source, &session.out);

    const once = try gpa.dupe(u8, session.out.const_slice());
    defer gpa.free(once);

    try std.testing.expect(std.mem.find(u8, once, "B,") == null);
    try session.expect(once, once);
}
