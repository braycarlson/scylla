const std = @import("std");
const assert = std.debug.assert;
const Blocks = @import("../syntax/markup/blocks.zig").Blocks;
const Buffer = @import("../stdx/bounded/buffer.zig");
const Formatter = @import("markup.zig").Formatter;
const FormatterError = @import("formatters.zig").FormatterError;
const Index = @import("../text/line_index.zig").LineIndex;
const Input = @import("markup.zig").Input;
const Kind = @import("../syntax/markup/kind.zig").Kind;
const TagSpecification = @import("../syntax/markup/vocabulary.zig").Vocabulary.TagSpecification;
const Tokens = @import("../syntax/markup/tokens.zig").Tokens;
const Tree = @import("../syntax/markup/tree.zig").Tree;
const Vocabulary = @import("../syntax/markup/vocabulary.zig").Vocabulary;
const blocks = @import("../syntax/markup/blocks.zig");
const corpus = @import("../testing/corpus.zig");
const floor = @import("../testing/floor.zig");
const lexer = @import("../syntax/markup/lex.zig");
const markup_testing = @import("../syntax/testing/markup.zig");
const markup_tree = @import("../syntax/markup/tree.zig");
const scan = @import("../text/scan.zig");
const stripe = @import("../testing/stripe.zig");
const HeldError = FormatterError || error{Truncated};

const Held = struct {
    formatter: Formatter,
    index: Index,
    map: Blocks,
    tokens: Tokens,
    tree: Tree,

    fn init(held: *Held, gpa: std.mem.Allocator) !void {
        held.formatter = try .init(gpa, element_count_max, line_count_max, out_bytes_max);
        errdefer held.formatter.deinit(gpa);

        held.index = try .init(gpa, line_count_max);
        errdefer held.index.deinit(gpa);

        held.map = try .init(gpa, tag_count_max);
        errdefer held.map.deinit(gpa);

        held.tokens = try .init(gpa, token_count_max);
        errdefer held.tokens.deinit(gpa);

        held.tree = try .init(gpa, node_count_max, diagnostic_count_max);

        assert(held.tokens.count() == 0);
        assert(held.index.count() == 1);
    }

    fn deinit(held: *Held, gpa: std.mem.Allocator) void {
        assert(held.tokens.capacity() == token_count_max);
        assert(held.index.capacity() == line_count_max);

        held.tree.deinit(gpa);
        held.tokens.deinit(gpa);
        held.map.deinit(gpa);
        held.index.deinit(gpa);
        held.formatter.deinit(gpa);
        held.* = undefined;
    }

    fn built(held: *Held, source: []const u8) error{Truncated}!Input {
        assert(source.len < std.math.maxInt(u32));

        held.tokens.clear();

        try held.index.build(source);
        try lexer.lex_with(source, &held.tokens, &markup_testing.raw_text_tags);
        _ = markup_tree.build(source, held.tokens.slice(), &held.tree);

        const tokens = held.tokens.slice();
        const structure = blocks.build(&held.map, source, tokens, &held.tree, &block_vocabulary);
        if (structure != .complete) return error.Truncated;

        assert(held.tree.count() > 0);

        return .{
            .index = &held.index,
            .map = &held.map,
            .options = .default,
            .source = source,
            .tokens = held.tokens.slice(),
            .tree = &held.tree,
        };
    }

    fn format(held: *Held, source: []const u8, out: *Buffer) HeldError!void {
        assert(source.len < std.math.maxInt(u32));

        const input = try held.built(source);

        assert(input.source.len == source.len);

        return held.formatter.format(&input, out);
    }

    fn kinds(held: *Held, arena: std.mem.Allocator, source: []const u8) ![]const Row {
        assert(source.len <= std.math.maxInt(u32));

        try lexer.lex_with(source, &held.tokens, &markup_testing.raw_text_tags);

        var rows: std.ArrayList(Row) = .empty;

        for (held.tokens.slice()) |token| {
            if (token.kind == .whitespace) continue;

            const bytes = try compacted(arena, token.text(source));

            if (token.kind == .text) {
                if (bytes.len == 0) continue;
            }

            try rows.append(arena, .{ .bytes = bytes, .kind = token.kind });
        }

        assert(rows.items.len <= held.tokens.count());

        return rows.items;
    }

    fn comments(held: *Held, arena: std.mem.Allocator, source: []const u8) ![]const []const u8 {
        assert(source.len <= std.math.maxInt(u32));

        try lexer.lex_with(source, &held.tokens, &markup_testing.raw_text_tags);

        var found: std.ArrayList([]const u8) = .empty;

        for (held.tokens.slice()) |token| {
            switch (token.kind) {
                .comment_text, .html_comment_open => {},
                else => continue,
            }

            try found.append(arena, std.mem.trim(u8, token.text(source), ascii_whitespace));
        }

        assert(found.items.len <= held.tokens.count());

        return found.items;
    }
};

const RelationsWorker = struct {
    arena: std.heap.ArenaAllocator,
    first: Buffer,
    held: Held,
    second: Buffer,

    pub const Item = corpus.File;
    pub const Shared = struct {};
    pub const Tally = struct { compared: u32 };
    pub const weight = corpus.File.weight;

    pub fn init(worker: *RelationsWorker, gpa: std.mem.Allocator, shared: *const Shared) !void {
        assert(@TypeOf(shared.*) == Shared);

        worker.arena = .init(gpa);
        errdefer worker.arena.deinit();

        worker.first = try .init(gpa, out_bytes_max);
        errdefer worker.first.deinit(gpa);

        try worker.held.init(gpa);
        errdefer worker.held.deinit(gpa);

        worker.second = try .init(gpa, out_bytes_max);

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

    pub fn visit(worker: *RelationsWorker, file: *const corpus.File, tally: *Tally) !void {
        assert(file.name.len > 0);
        assert(file.source.len <= std.math.maxInt(u32));

        worker.held.format(file.source, &worker.first) catch return;

        _ = worker.arena.reset(.retain_capacity);

        const arena = worker.arena.allocator();
        const once = worker.first.const_slice();

        try expect_tokens_kept(&worker.held, arena, file.name, file.source, once);
        try expect_comments_kept(&worker.held, arena, file.name, file.source, once);
        try expect_idempotent(&worker.held, file.name, once, &worker.second);

        tally.compared += 1;
    }
};

const Row = struct {
    bytes: []const u8,
    kind: Kind,
};

const ascii_whitespace = " \t\n\x0c\r";

const block_vocabulary: Vocabulary = .{
    .dialect = .html,
    .end_prefix = "end",
    .extends_tags = &.{},
    .intermediate_words = &words,
    .only_word = null,
    .raw_text_tags = &markup_testing.raw_text_tags,
    .specifications = &specifications,
    .template_imports = &.{},
};

const element_count_max: u32 = 1 << 18;
const diagnostic_count_max: u32 = 1 << 12;
const fixture_count_min: u32 = 300;
const fixture_root = "tests/fixtures/templates";
const line_count_max: u32 = 1 << 16;
const node_count_max: u32 = 1 << 17;
const out_bytes_max: u32 = 1 << 22;
const refusal_count: u32 = 23;
const source_bytes_max: u32 = 1 << 28;

const specifications = [_]TagSpecification{
    .{ .intermediates = &.{"empty"}, .name = "for" },
    .{ .intermediates = &.{ "elif", "else" }, .name = "if" },
    .{ .intermediates = &.{"else"}, .name = "ifequal" },
    .{ .intermediates = &.{"else"}, .name = "ifnotequal" },
    .{ .intermediates = &.{"plural"}, .name = "blocktranslate" },
};

const tag_count_max: u32 = 1 << 14;
const token_count_max: u32 = 1 << 18;
const words = [_][]const u8{ "elif", "else", "empty", "plural" };

fn fixtures(gpa: std.mem.Allocator) !corpus.Files {
    var files = try corpus.collect(
        gpa,
        fixture_root,
        source_bytes_max,
        markup_testing.template_selected,
    );

    errdefer files.deinit(gpa);

    if (files.slice().len <= fixture_count_min) {
        std.debug.print("{d} fixture templates under {s}\n", .{ files.slice().len, fixture_root });

        return error.TestUnexpectedResult;
    }

    return files;
}

fn compacted(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    assert(text.len < std.math.maxInt(u32));

    var bytes: std.ArrayList(u8) = try .initCapacity(arena, text.len);

    for (text) |byte| {
        if (scan.is_ascii_whitespace(byte)) continue;

        bytes.appendAssumeCapacity(byte);
    }

    assert(bytes.items.len <= text.len);

    return bytes.items;
}

fn rows_equal(before: []const Row, after: []const Row) bool {
    if (before.len != after.len) return false;

    for (before, after) |left, right| {
        if (left.kind != right.kind) return false;
        if (!std.mem.eql(u8, left.bytes, right.bytes)) return false;
    }

    return true;
}

fn texts_equal(before: []const []const u8, after: []const []const u8) bool {
    if (before.len != after.len) return false;

    for (before, after) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }

    return true;
}

fn is_complete(result: HeldError!void) bool {
    if (std.meta.isError(result)) return false;

    return true;
}

fn is_refused(result: HeldError!void) bool {
    if (!std.meta.isError(result)) return false;

    result catch |err| switch (err) {
        error.OutputExhausted, error.Truncated => return false,
        error.SourceInvalid => return true,
    };

    return false;
}

fn expect_named(held: bool, name: []const u8, comptime message: []const u8) !void {
    comptime assert(message.len > 0);
    assert(name.len > 0);

    if (held) return;

    std.debug.print("{s} " ++ message ++ "\n", .{name});

    return error.TestUnexpectedResult;
}

fn expect_tokens_kept(
    held: *Held,
    arena: std.mem.Allocator,
    name: []const u8,
    source: []const u8,
    once: []const u8,
) !void {
    assert(name.len > 0);
    assert(once.len < std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));

    const before = try held.kinds(arena, source);
    const after = try held.kinds(arena, once);

    try expect_named(rows_equal(before, after), name, "lost or gained a token");
}

fn expect_comments_kept(
    held: *Held,
    arena: std.mem.Allocator,
    name: []const u8,
    source: []const u8,
    once: []const u8,
) !void {
    assert(name.len > 0);
    assert(once.len < std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));

    const before = try held.comments(arena, source);
    const after = try held.comments(arena, once);

    try expect_named(texts_equal(before, after), name, "lost a comment");
}

fn expect_idempotent(held: *Held, name: []const u8, once: []const u8, second: *Buffer) !void {
    assert(name.len > 0);
    assert(once.len < std.math.maxInt(u32));

    const outcome = held.format(once, second);

    try expect_named(is_complete(outcome), name, "refuses its own output");

    if (std.mem.eql(u8, once, second.const_slice())) return;

    std.debug.print("{s} is not idempotent\n", .{name});

    return std.testing.expectEqualStrings(once, second.const_slice());
}

test "the three relations hold over the corpus" {
    const gpa = std.testing.allocator;
    const root = corpus.named(.root) orelse return;
    var files = try corpus.collect(gpa, root, source_bytes_max, markup_testing.template_selected);
    defer files.deinit(gpa);

    if (files.slice().len == 0) return;

    var tally: RelationsWorker.Tally = .{ .compared = 0 };

    try stripe.run(RelationsWorker, gpa, &.{}, files.slice(), &tally);

    if (tally.compared >= floor.corpus_format_markup) return;

    std.debug.print(
        "{d} corpus templates formatted, floor {d}\n",
        .{ tally.compared, floor.corpus_format_markup },
    );

    return error.TestUnexpectedResult;
}

test "formatting formatted output changes nothing" {
    const gpa = std.testing.allocator;
    var first: Buffer = try .init(gpa, out_bytes_max);
    defer first.deinit(gpa);

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var second: Buffer = try .init(gpa, out_bytes_max);
    defer second.deinit(gpa);

    var files = try fixtures(gpa);
    defer files.deinit(gpa);

    for (files.slice()) |file| {
        held.format(file.source, &first) catch continue;

        try expect_idempotent(&held, file.name, first.const_slice(), &second);
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

    var files = try fixtures(gpa);
    defer files.deinit(gpa);

    for (files.slice()) |file| {
        held.format(file.source, &out) catch continue;

        _ = arena.reset(.retain_capacity);

        try expect_tokens_kept(&held, arena.allocator(), file.name, file.source, out.const_slice());
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

    var files = try fixtures(gpa);
    defer files.deinit(gpa);

    for (files.slice()) |file| {
        held.format(file.source, &out) catch continue;

        _ = arena.reset(.retain_capacity);

        const allocator = arena.allocator();

        try expect_comments_kept(&held, allocator, file.name, file.source, out.const_slice());
    }
}

test "a file that does not parse is refused" {
    const gpa = std.testing.allocator;
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    try std.testing.expectError(error.SourceInvalid, held.format("<div>\n", &out));
    try std.testing.expect(out.empty());
    try std.testing.expectError(error.SourceInvalid, held.format("{{ a \n", &out));
    try std.testing.expect(out.empty());
}

test "a range reads back the lines it names" {
    const gpa = std.testing.allocator;
    const source = "<div>\n<p>a</p>\n</div>\n";
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    const input = try held.built(source);
    const span = try held.formatter.range(&input, .{ .first = 1, .last = 1 }, &out);

    try std.testing.expectEqualStrings("<div>\n    <p>a</p>\n</div>\n", out.const_slice());
    try std.testing.expectEqualStrings("    <p>a</p>\n", span.text(out.const_slice()));
}

test "the refusal set holds its count" {
    const gpa = std.testing.allocator;
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    var files = try fixtures(gpa);
    defer files.deinit(gpa);

    var refused: u32 = 0;

    for (files.slice()) |file| {
        if (!is_refused(held.format(file.source, &out))) continue;

        refused += 1;
    }

    try std.testing.expectEqual(refusal_count, refused);
}
