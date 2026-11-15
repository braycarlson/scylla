const std = @import("std");
const assert = std.debug.assert;
const Kind = @import("kind.zig").Kind;
const Random = @import("../../testing/random.zig");
const Token = @import("token.zig").Token;
const Tokens = @import("tokens.zig").Tokens;
const corpus = @import("../../testing/corpus.zig");
const floor = @import("../../testing/floor.zig");
const lexer = @import("lex.zig");
const markup_testing = @import("../testing/markup.zig");
const oracle_names = @import("../testing/names.zig");
const stripe = @import("../../testing/stripe.zig");

const LosslessWorker = struct {
    tokens: Tokens,

    pub const Item = corpus.File;
    pub const Shared = struct {};
    pub const Tally = struct { compared: u32 };
    pub const weight = corpus.File.weight;

    pub fn init(worker: *LosslessWorker, gpa: std.mem.Allocator, shared: *const Shared) !void {
        assert(@TypeOf(shared.*) == Shared);

        worker.tokens = try .init(gpa, token_count_max);

        assert(worker.tokens.count() == 0);
    }

    pub fn deinit(worker: *LosslessWorker, gpa: std.mem.Allocator) void {
        assert(worker.tokens.capacity() == token_count_max);

        worker.tokens.deinit(gpa);
        worker.* = undefined;
    }

    pub fn visit(worker: *LosslessWorker, file: *const corpus.File, tally: *Tally) !void {
        assert(file.name.len > 0);
        assert(file.source.len <= std.math.maxInt(u32));

        lex_ignoring_truncation(file.source, &worker.tokens);

        try lossless(file.source, &worker.tokens, file.name);

        tally.compared += 1;
    }
};

const raw_text_tags = markup_testing.raw_text_tags;
const soup_case_count: u32 = 512;
const soup_length_max: u32 = 256;
const source_bytes_max: u32 = 1 << 28;
const token_count_max: u32 = 1 << 18;

fn lex_ignoring_truncation(source: []const u8, tokens: *Tokens) void {
    assert(source.len <= std.math.maxInt(u32));

    lexer.lex_with(source, tokens, &raw_text_tags) catch |err| switch (err) {
        error.Truncated => assert(tokens.end_previous == source.len),
    };
}

fn lossless(source: []const u8, tokens: *const Tokens, name: []const u8) !void {
    assert(source.len <= std.math.maxInt(u32));
    assert(name.len > 0);

    var end_previous: u32 = 0;

    for (tokens.slice(), 0..) |held, index| {
        if (held.offset != end_previous) {
            std.debug.print("{s}: token {d} leaves a gap or overlaps\n", .{ name, index });

            return error.TestUnexpectedResult;
        }

        if (held.length == 0) {
            std.debug.print("{s}: token {d} covers no byte\n", .{ name, index });

            return error.TestUnexpectedResult;
        }

        end_previous = held.end();
    }

    if (end_previous != source.len) {
        std.debug.print("{s}: the stream stops short of the source end\n", .{name});

        return error.TestUnexpectedResult;
    }
}

fn soup_fill(random: *Random, alphabet: []const u8, source: *std.ArrayList(u8)) void {
    assert(alphabet.len > 0);

    const length = random.below(soup_length_max);

    source.clearRetainingCapacity();

    for (0..length) |_| {
        const index = random.below(@intCast(alphabet.len));

        source.appendAssumeCapacity(alphabet[index]);
    }

    assert(source.items.len == length);
}

test "every fixture lexes to the token stream the oracle recorded" {
    const gpa = std.testing.allocator;
    var tokens: Tokens = try .init(gpa, token_count_max);
    defer tokens.deinit(gpa);

    var fixtures = try markup_testing.fixtures_read(gpa);
    defer fixtures.deinit(gpa);

    for (fixtures.items) |*fixture| {
        try lexer.lex_with(fixture.source, &tokens, &raw_text_tags);

        const lexed = tokens.slice();
        const recorded = fixture.tokens;

        if (lexed.len != recorded.len) {
            std.debug.print("{s}: the token counts differ\n", .{fixture.name});
        }

        try std.testing.expectEqual(recorded.len, lexed.len);

        for (lexed, recorded, 0..) |held, row, index| {
            const kind = oracle_names.kind_of(Kind, row.name) orelse {
                std.debug.print("the oracle names a kind the library lacks: {s}\n", .{row.name});

                return error.TestUnexpectedResult;
            };

            const same = held.kind == kind and held.offset == row.offset and held.end() == row.end;

            if (!same) {
                std.debug.print("{s}: token {d} differs\n", .{ fixture.name, index });
            }

            try std.testing.expectEqual(kind, held.kind);
            try std.testing.expectEqual(row.offset, held.offset);
            try std.testing.expectEqual(row.end, held.end());
        }
    }
}

test "the token spans reproduce every fixture byte for byte" {
    const gpa = std.testing.allocator;
    var tokens: Tokens = try .init(gpa, token_count_max);
    defer tokens.deinit(gpa);

    var fixtures = try markup_testing.fixtures_read(gpa);
    defer fixtures.deinit(gpa);

    for (fixtures.items) |*fixture| {
        lex_ignoring_truncation(fixture.source, &tokens);

        try lossless(fixture.source, &tokens, fixture.name);
    }
}

test "every corpus template is tiled by its tokens" {
    const gpa = std.testing.allocator;
    const root = corpus.named(.root) orelse return;
    var files = try corpus.collect(gpa, root, source_bytes_max, markup_testing.template_selected);
    defer files.deinit(gpa);

    if (files.slice().len == 0) return;

    var tally: LosslessWorker.Tally = .{ .compared = 0 };

    try stripe.run(LosslessWorker, gpa, &.{}, files.slice(), &tally);

    if (tally.compared < floor.corpus_markup_lex) {
        std.debug.print(
            "{d} corpus templates lexed, floor {d}\n",
            .{ tally.compared, floor.corpus_markup_lex },
        );
    }

    try std.testing.expect(tally.compared >= floor.corpus_markup_lex);
}

test "the token spans reproduce byte soup byte for byte" {
    const gpa = std.testing.allocator;
    const alphabet = "<>/=\"'{}%#|:,. \n\t-!abcdivscriptylendverbatim";
    var random: Random = .init(0x2545_F491_4F6C_DD1D);
    var tokens: Tokens = try .init(gpa, token_count_max);
    defer tokens.deinit(gpa);

    var source: std.ArrayList(u8) = try .initCapacity(gpa, soup_length_max);
    defer source.deinit(gpa);

    var lexed: std.ArrayList(Token) = .empty;
    defer lexed.deinit(gpa);

    var name_buffer: [32]u8 = undefined;

    for (0..soup_case_count) |case| {
        soup_fill(&random, alphabet, &source);

        const name = try std.mem.print(&name_buffer, "soup {d}", .{case});

        lex_ignoring_truncation(source.items, &tokens);

        try lossless(source.items, &tokens, name);

        lexed.clearRetainingCapacity();
        try lexed.appendSlice(gpa, tokens.slice());

        lex_ignoring_truncation(source.items, &tokens);

        try std.testing.expectEqualSlices(Token, lexed.items, tokens.slice());
    }
}

test "a starved budget truncates and still covers every byte" {
    const gpa = std.testing.allocator;
    var fixtures = try markup_testing.fixtures_read(gpa);
    defer fixtures.deinit(gpa);

    var source: []const u8 = fixtures.items[0].source;

    for (fixtures.items) |*fixture| {
        if (fixture.source.len >= source.len) source = fixture.source;
    }

    var starved: Tokens = try .init(gpa, 4);
    defer starved.deinit(gpa);

    var generous: Tokens = try .init(gpa, token_count_max);
    defer generous.deinit(gpa);

    try std.testing.expectError(
        error.Truncated,
        lexer.lex_with(source, &starved, &raw_text_tags),
    );

    try lexer.lex_with(source, &generous, &raw_text_tags);

    try lossless(source, &starved, "the starved lex");
    try lossless(source, &generous, "the generous lex");

    try std.testing.expect(starved.count() <= 4);
    try std.testing.expect(generous.count() > starved.count());
}

test "an empty source is complete under any budget" {
    const gpa = std.testing.allocator;
    var tokens: Tokens = try .init(gpa, 1);
    defer tokens.deinit(gpa);

    try lexer.lex_with("", &tokens, &raw_text_tags);

    try std.testing.expectEqual(0, tokens.count());
}

test "every awkward source holds the lossless property" {
    const gpa = std.testing.allocator;

    const sources = [_][]const u8{
        "",
        "\n",
        "<",
        ">",
        "{",
        "{{",
        "{%",
        "{#",
        "{{ name",
        "{% block",
        "{# note",
        "<div class=\"open",
        "<!--",
        "<!-- {{ name }}",
        "<!DOCTYPE html>",
        "</div>",
        "</>",
        "<script>var a = 1;",
        "<style>a { b: c }",
        "{% verbatim %}{{ literal }}",
        "{% verbatim %}{{ literal }}{% endverbatim %}",
        "<div a=b c='d' e=\"f\"/>",
        "\xef\xbb\xbf<div>",
        "\xff\xfe not utf eight at all",
        "<p>a<p>b<p>c",
        "<div {{ attribute }}>",
    };

    var tokens: Tokens = try .init(gpa, token_count_max);
    defer tokens.deinit(gpa);

    for (sources) |source| {
        try lexer.lex_with(source, &tokens, &raw_text_tags);
        try lossless(source, &tokens, "an awkward source");
    }
}
