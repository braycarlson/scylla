const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Language = @import("language.zig").Language;
const Token = @import("token.zig");
const Tokens = @import("tokens.zig");
const corpus = @import("../testing/corpus.zig");
const floor = @import("../testing/floor.zig");
const lex = @import("lex.zig").lex;
const stripe = @import("../testing/stripe.zig");
const trivia = @import("trivia.zig");

const Lexer = struct {
    directory: []const u8,
    extensions: []const []const u8,
    language: Language,
};

const Mode = enum {
    corpus,
    fixture,
    truncated,
};

const Outcome = enum {
    complete,
    truncated,
};

const TileWorker = struct {
    buffer: ArrayType(u8),
    mode: Mode,
    tokens: Tokens,

    pub const Item = corpus.File;

    pub const Shared = struct {
        mode: Mode,
        token_capacity: u32,
    };

    pub const Tally = struct { tiled: u32 };
    pub const weight = corpus.File.weight;

    pub fn init(worker: *TileWorker, gpa: std.mem.Allocator, shared: *const Shared) !void {
        assert(shared.token_capacity > 0);
        assert(shared.token_capacity <= token_count_max);

        worker.buffer = try .init(gpa, source_bytes_max);
        errdefer worker.buffer.deinit(gpa);

        worker.tokens = try .init(gpa, shared.token_capacity);
        worker.mode = shared.mode;
    }

    pub fn deinit(worker: *TileWorker, gpa: std.mem.Allocator) void {
        assert(worker.buffer.capacity() == source_bytes_max);
        assert(worker.tokens.items.capacity() > 0);

        worker.tokens.deinit(gpa);
        worker.buffer.deinit(gpa);
        worker.* = undefined;
    }

    pub fn visit(worker: *TileWorker, file: *const corpus.File, tally: *Tally) !void {
        assert(@TypeOf(tally.*) == Tally);
        assert(file.name.len > 0);

        const language = language_of(file.name);
        errdefer std.debug.print("{s}: {s}\n", .{ language.name(), file.name });

        if (try walk_file(worker, language, file.source)) tally.tiled += 1;
    }
};

const fixture_bytes_max: u32 = 1 << 28;
const source_bytes_max: u32 = 1 << 22;
const token_budget_small: u32 = 64;
const token_count_max: u32 = 1 << 20;

const every_lexer = [_]Lexer{
    .{ .directory = "css", .extensions = &.{"css"}, .language = .css },
    .{ .directory = "go", .extensions = &.{"go"}, .language = .go },
    .{
        .directory = "javascript",
        .extensions = &.{ "cjs", "js", "jsx", "mjs" },
        .language = .javascript,
    },
    .{ .directory = "odin", .extensions = &.{"odin"}, .language = .odin },
    .{ .directory = "python", .extensions = &.{ "py", "pyi" }, .language = .python },
    .{ .directory = "rust", .extensions = &.{"rs"}, .language = .rust },
    .{
        .directory = "typescript",
        .extensions = &.{ "cts", "mts", "ts", "tsx" },
        .language = .typescript,
    },
    .{ .directory = "zig", .extensions = &.{"zig"}, .language = .zig },
};

fn SelectedType(comptime lexer: Lexer) type {
    comptime assert(lexer.extensions.len > 0);

    return struct {
        fn selected(basename: []const u8) bool {
            assert(basename.len <= std.math.maxInt(u32));

            return extension_matches(basename, lexer.extensions);
        }
    };
}

fn corpus_selected(basename: []const u8) bool {
    assert(basename.len > 0);
    assert(every_lexer.len > 0);

    for (&every_lexer) |*lexer| {
        if (extension_matches(basename, lexer.extensions)) return true;
    }

    return false;
}

fn language_of(name: []const u8) Language {
    assert(name.len > 0);

    const basename = std.Io.Dir.path.basename(name);

    assert(basename.len > 0);

    for (&every_lexer) |*lexer| {
        if (extension_matches(basename, lexer.extensions)) return lexer.language;
    }

    unreachable;
}

fn walk_tree(
    root: []const u8,
    comptime selected: fn (basename: []const u8) bool,
    shared: *const TileWorker.Shared,
    tally: *TileWorker.Tally,
) !u32 {
    const gpa = std.testing.allocator;

    assert(root.len > 0);
    assert(shared.token_capacity <= token_count_max);

    const limit: u32 = switch (shared.mode) {
        .corpus => source_bytes_max + 1,
        .fixture, .truncated => fixture_bytes_max,
    };

    var files = try corpus.collect(gpa, root, limit, selected);
    defer files.deinit(gpa);

    try stripe.run(TileWorker, gpa, shared, files.slice(), tally);

    assert(files.slice().len <= std.math.maxInt(u32));

    return @intCast(files.slice().len);
}

fn walk_file(worker: *TileWorker, language: Language, source: []const u8) !bool {
    assert(worker.buffer.capacity() == source_bytes_max);
    assert(worker.tokens.items.capacity() > 0);
    assert(source.len <= std.math.maxInt(u32));
    assert(language.lexes());

    if (source.len > source_bytes_max) {
        try std.testing.expectEqual(Mode.corpus, worker.mode);

        return false;
    }

    worker.tokens.clear();

    const outcome = lex_outcome(language, source, &worker.tokens);

    switch (worker.mode) {
        .corpus => {},
        .fixture => try std.testing.expectEqual(Outcome.complete, outcome),
        .truncated => {
            if (outcome == .complete) return false;

            try std.testing.expectEqual(token_budget_small, worker.tokens.count());
        },
    }

    try tiles(source, worker.tokens.slice(), outcome, &worker.buffer);

    return true;
}

fn lex_outcome(language: Language, source: []const u8, tokens: *Tokens) Outcome {
    assert(source.len <= source_bytes_max);
    assert(tokens.count() == 0);
    assert(language.lexes());

    lex(.of(language), source, tokens) catch |err| switch (err) {
        error.Truncated => return .truncated,
    };

    return .complete;
}

fn tiles(
    source: []const u8,
    tokens: []const Token,
    outcome: Outcome,
    buffer: *ArrayType(u8),
) !void {
    assert(tokens.len <= std.math.maxInt(u32));

    const token_count: u32 = @intCast(tokens.len);
    var end_previous: u32 = 0;

    assert(source.len <= source_bytes_max);
    assert(token_count <= token_count_max);

    for (tokens) |token| {
        try std.testing.expect(token.offset >= end_previous);
        try std.testing.expect(token.end() <= source.len);

        end_previous = token.end();
    }

    const prefix_end: u32 = switch (outcome) {
        .complete => @intCast(source.len),
        .truncated => end_previous,
    };

    try std.testing.expect(prefix_end <= source.len);

    buffer.clear();

    var gaps = trivia.gaps(Token, prefix_end, tokens);

    while (gaps.next()) |gap| {
        try std.testing.expect(buffer_push(buffer, gap.span.text(source)));

        if (gap.token == token_count) continue;

        try std.testing.expect(buffer_push(buffer, tokens[gap.token].text(source)));
    }

    try std.testing.expectEqualSlices(u8, source[0..prefix_end], buffer.const_slice());
}

fn buffer_push(buffer: *ArrayType(u8), bytes: []const u8) bool {
    assert(buffer.capacity() == source_bytes_max);
    assert(bytes.len <= source_bytes_max);

    if (buffer.unused_capacity() < bytes.len) return false;

    buffer.push_slice(bytes);

    return true;
}

fn extension_matches(basename: []const u8, extensions: []const []const u8) bool {
    assert(basename.len > 0);
    assert(extensions.len > 0);

    const dot = std.mem.findScalarLast(u8, basename, '.') orelse return false;
    if (dot == 0) return false;

    for (extensions) |extension| {
        if (std.mem.eql(u8, basename[dot + 1 ..], extension)) return true;
    }

    return false;
}

test "every fixture is tiled by its tokens and gaps" {
    const shared: TileWorker.Shared = .{ .mode = .fixture, .token_capacity = token_count_max };
    var tally: TileWorker.Tally = .{ .tiled = 0 };

    inline for (every_lexer) |lexer| {
        const root = "tests/fixtures/" ++ lexer.directory;
        const found = try walk_tree(root, SelectedType(lexer).selected, &shared, &tally);

        try std.testing.expect(found > 0);
    }

    try std.testing.expect(tally.tiled >= floor.fixture_lossless);
}

test "every corpus file is tiled by its tokens and gaps" {
    const root = corpus.named(.root) orelse return;
    const shared: TileWorker.Shared = .{ .mode = .corpus, .token_capacity = token_count_max };
    var tally: TileWorker.Tally = .{ .tiled = 0 };

    _ = try walk_tree(root, corpus_selected, &shared, &tally);

    try std.testing.expect(tally.tiled >= floor.corpus_lossless);
}

test "a truncated lex is tiled over the prefix it consumed" {
    const shared: TileWorker.Shared = .{ .mode = .truncated, .token_capacity = token_budget_small };
    var tally: TileWorker.Tally = .{ .tiled = 0 };

    inline for (every_lexer) |lexer| {
        const root = "tests/fixtures/" ++ lexer.directory;

        _ = try walk_tree(root, SelectedType(lexer).selected, &shared, &tally);
    }

    try std.testing.expect(tally.tiled > 0);
}
