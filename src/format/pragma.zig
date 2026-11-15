const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Span = @import("../stdx/bounded/span.zig");
const Token = @import("../syntax/token.zig");
const Tokens = @import("../syntax/tokens.zig");
const lex = @import("../syntax/lex.zig").lex;
const LineIndex = @import("../text/line_index.zig").LineIndex;
const scan = @import("../text/scan.zig");
const trivia = @import("../syntax/trivia.zig");

pub const Pragma = enum {
    format_off,
    format_on,
    format_skip,
    isort_off,
    isort_on,
    isort_skip,
    isort_split,
    type_ignore,
};

pub const PragmaAt = struct {
    kind: Pragma,
    line: u32,
    span: Span,
};

pub const Pragmas = struct {
    items: ArrayType(PragmaAt),

    pub fn init(gpa: std.mem.Allocator, pragma_count_max: u32) std.mem.Allocator.Error!Pragmas {
        assert(pragma_count_max > 0);

        const items: ArrayType(PragmaAt) = try .init(gpa, pragma_count_max);

        assert(items.capacity() == pragma_count_max);
        assert(items.empty());

        return .{ .items = items };
    }

    pub fn deinit(pragmas: *Pragmas, gpa: std.mem.Allocator) void {
        assert(pragmas.items.count() <= pragmas.items.capacity());
        assert(pragmas.items.capacity() > 0);

        pragmas.items.deinit(gpa);
        pragmas.* = undefined;
    }

    pub fn clear(pragmas: *Pragmas) void {
        assert(pragmas.items.count() <= pragmas.items.capacity());

        pragmas.items.clear();

        assert(pragmas.count() == 0);
    }

    pub fn const_slice(pragmas: *const Pragmas) []const PragmaAt {
        const held = pragmas.items.const_slice();

        assert(held.len == pragmas.items.count());
        assert(held.len <= pragmas.items.capacity());

        return held;
    }

    pub fn count(pragmas: *const Pragmas) u32 {
        const held = pragmas.items.count();

        assert(held <= pragmas.items.capacity());

        return held;
    }

    pub fn scan(
        pragmas: *Pragmas,
        source: []const u8,
        lexed: []const Token,
        index: *const LineIndex,
    ) error{Overflow}!void {
        assert(source.len <= std.math.maxInt(u32));
        assert(lexed.len <= std.math.maxInt(u32));

        pragmas.clear();

        for (lexed) |token| {
            if (token.kind != .comment) continue;

            const comment = token.span();

            assert(comment.end() <= source.len);

            const kind = pragma_of(source, comment) orelse continue;

            if (pragmas.items.full()) return error.Overflow;

            pragmas.items.push(.{
                .kind = kind,
                .line = index.line_of(comment.offset),
                .span = comment,
            });
        }

        assert(pragmas.count() <= lexed.len);
    }
};

const PragmaWord = struct {
    word: []const u8,
    kind: Pragma,
};

const pragma_words = [_]PragmaWord{
    .{ .word = "fmt:off", .kind = .format_off },
    .{ .word = "fmt:on", .kind = .format_on },
    .{ .word = "fmt:skip", .kind = .format_skip },
    .{ .word = "isort:off", .kind = .isort_off },
    .{ .word = "isort:on", .kind = .isort_on },
    .{ .word = "isort:skip", .kind = .isort_skip },
    .{ .word = "isort:split", .kind = .isort_split },
    .{ .word = "type:ignore", .kind = .type_ignore },
};

comptime {
    assert(pragma_words.len == @typeInfo(Pragma).@"enum".field_names.len);

    for (pragma_words, 0..) |entry, at| {
        assert(@backingInt(entry.kind) == at);
        assert(std.mem.findScalar(u8, entry.word, ':') != null);
    }
}

fn pragma_of(source: []const u8, comment: Span) ?Pragma {
    assert(comment.end() <= source.len);

    const start = trivia.comment_text_start(source, comment);
    const text = std.mem.trimEnd(u8, source[start..comment.end()], scan.ascii_whitespace);

    assert(text.len <= comment.length);

    for (pragma_words) |entry| {
        if (word_matches(text, entry.word)) return entry.kind;
    }

    return null;
}

fn word_matches(text: []const u8, word: []const u8) bool {
    assert(word.len > 0);
    assert(std.mem.findScalar(u8, word, ':') != null);
    assert(text.len <= std.math.maxInt(u32));

    var read: u32 = 0;

    for (word) |byte| {
        if (scan.byte_at(text, read) != byte) return false;

        read += 1;

        if (byte == ':') {
            if (scan.byte_at(text, read) == ' ') read += 1;
        }
    }

    assert(read <= text.len);

    if (std.mem.eql(u8, word, "type:ignore")) return true;
    return read == text.len;
}

const Commented = struct {
    index: LineIndex,
    lexed: Tokens,

    fn init(source: []const u8) !Commented {
        const gpa = std.testing.allocator;

        assert(source.len > 0);

        var lexed: Tokens = try .init(gpa, 1 << 12);
        errdefer lexed.deinit(gpa);

        var index: LineIndex = try .init(gpa, 64);
        errdefer index.deinit(gpa);

        try lex(.of(.python), source, &lexed);
        try index.build(source);

        assert(lexed.count() > 0);

        return .{ .index = index, .lexed = lexed };
    }

    fn deinit(commented: *Commented) void {
        assert(commented.index.count() > 0);

        commented.index.deinit(std.testing.allocator);
        commented.lexed.deinit(std.testing.allocator);
        commented.* = undefined;
    }
};

fn expect_pragmas(source: []const u8, expected: []const Pragma) !void {
    const gpa = std.testing.allocator;

    assert(source.len > 0);
    assert(expected.len <= 32);

    var commented: Commented = try .init(source);
    defer commented.deinit();

    var pragmas: Pragmas = try .init(gpa, 32);
    defer pragmas.deinit(gpa);

    try pragmas.scan(source, commented.lexed.slice(), &commented.index);

    try std.testing.expectEqual(expected.len, pragmas.count());

    for (expected, pragmas.const_slice()) |kind, held| {
        try std.testing.expectEqual(kind, held.kind);
    }
}

test "each pragma reads as its own kind" {
    const source = "# fmt: off\n" ++
        "# fmt: on\n" ++
        "held = 1  # fmt: skip\n" ++
        "# isort: off\n" ++
        "# isort: on\n" ++
        "held = 2  # isort: skip\n" ++
        "# isort: split\n" ++
        "held = 3  # type: ignore[arg-type]\n";

    try expect_pragmas(source, &.{
        .format_off,
        .format_on,
        .format_skip,
        .isort_off,
        .isort_on,
        .isort_skip,
        .isort_split,
        .type_ignore,
    });
}

test "a pragma written without its blank reads the same" {
    try expect_pragmas("held = 1  # fmt:skip\n", &.{.format_skip});
}

test "a pragma with blanks after it reads the same" {
    try expect_pragmas("# fmt: off   \n", &.{.format_off});
    try expect_pragmas("held = 1  # fmt: skip  \n", &.{.format_skip});
    try expect_pragmas("# isort: split\t\n", &.{.isort_split});
}

test "a comment that only opens like a pragma is no pragma" {
    try expect_pragmas("# fmt: offside\n", &.{});
    try expect_pragmas("# format: off\n", &.{});
    try expect_pragmas("# isort: splitter\n", &.{});
}

test "a pragma past a full table overflows" {
    const gpa = std.testing.allocator;
    const source = "# fmt: off\n# fmt: on\n";
    var commented: Commented = try .init(source);
    defer commented.deinit();

    var pragmas: Pragmas = try .init(gpa, 1);
    defer pragmas.deinit(gpa);

    const scanned = pragmas.scan(source, commented.lexed.slice(), &commented.index);

    try std.testing.expectError(error.Overflow, scanned);
}

test "a pragma records the line it stands on" {
    const gpa = std.testing.allocator;
    const source = "held = 1\n# fmt: off\n";
    var commented: Commented = try .init(source);
    defer commented.deinit();

    var pragmas: Pragmas = try .init(gpa, 8);
    defer pragmas.deinit(gpa);

    try pragmas.scan(source, commented.lexed.slice(), &commented.index);

    try std.testing.expectEqual(@as(u32, 1), pragmas.count());
    try std.testing.expectEqual(Pragma.format_off, pragmas.const_slice()[0].kind);
    try std.testing.expectEqual(@as(u32, 1), pragmas.const_slice()[0].line);
}
