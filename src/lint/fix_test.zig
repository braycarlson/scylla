const std = @import("std");
const assert = std.debug.assert;
const bounded = @import("../stdx/bounded.zig");
const Diagnostics = @import("diagnostics.zig");
const Fixes = @import("fixes.zig");
const Token = @import("../syntax/token.zig");
const Tokens = @import("../syntax/tokens.zig");
const python = @import("../syntax/python/lex.zig");
const Buffer = bounded.Buffer;
const arena_bytes_max: u32 = 1 << 10;
const diagnostic_count_max: u32 = 1 << 6;
const edit_count_max: u32 = 1 << 6;
const fix_count_max: u32 = 1 << 6;
const round_max: u32 = 4;
const source_text = "def f(l):\n    return l\n";
const source_bytes_max: u32 = 1 << 12;
const token_count_max: u32 = 1 << 10;

const Round = struct {
    applied: u32,
    diagnostics: Diagnostics,
    fixes: Fixes,
    tokens: Tokens,

    fn init(gpa: std.mem.Allocator) !Round {
        var diagnostics = try Diagnostics.init(gpa, .{
            .related_count_max = diagnostic_count_max,
            .row_count_max = diagnostic_count_max,
            .text_bytes_max = arena_bytes_max,
        });

        errdefer diagnostics.deinit(gpa);

        var fixes = try Fixes.init(gpa, .{
            .edit_count_max = edit_count_max,
            .fix_count_max = fix_count_max,
            .text_bytes_max = arena_bytes_max,
        });

        errdefer fixes.deinit(gpa);

        const tokens = try Tokens.init(gpa, token_count_max);
        return .{ .applied = 0, .diagnostics = diagnostics, .fixes = fixes, .tokens = tokens };
    }

    fn deinit(round: *Round, gpa: std.mem.Allocator) void {
        round.diagnostics.deinit(gpa);
        round.fixes.deinit(gpa);
        round.tokens.deinit(gpa);
    }

    fn record(round: *Round, source: []const u8) !u32 {
        assert(source.len <= std.math.maxInt(u32));

        round.applied = 0;

        round.diagnostics.clear();
        round.fixes.clear();
        round.tokens.clear();

        try python.lex(source, &round.tokens);

        for (round.tokens.slice()) |token| {
            if (!renamed(source, token)) continue;

            round.fixes.open("Rename", .safe, null);
            try round.fixes.edit(token.span(), "value");

            const index = round.fixes.close();

            try round.diagnostics.push(.{
                .code = "PR001",
                .fix = index,
                .message = .{ .static = "the name is renamed" },
                .severity = .warning,
                .span = token.span(),
            });
        }

        round.diagnostics.sort();

        assert(round.diagnostics.count() == round.fixes.count());

        return round.diagnostics.count();
    }

    fn apply(round: *Round, source: []const u8, out: *Buffer) !void {
        assert(source.len <= std.math.maxInt(u32));

        round.applied = try round.fixes.apply(out, source, .safe);

        assert(round.applied <= round.fixes.count());
    }
};

fn renamed(source: []const u8, token: Token) bool {
    assert(token.span().end() <= source.len);

    if (token.kind != .identifier) return false;
    return std.mem.eql(u8, token.text(source), "l");
}

test "a recorded rename applies and then converges" {
    const gpa = std.testing.allocator;
    var out = try Buffer.init(gpa, source_bytes_max);
    defer out.deinit(gpa);

    var round = try Round.init(gpa);
    defer round.deinit(gpa);

    var source_bytes: [source_bytes_max]u8 = undefined;
    var source_length: usize = source_text.len;
    var rounds: u32 = 0;

    @memcpy(source_bytes[0..source_length], source_text);

    for (0..round_max) |_| {
        const count = try round.record(source_bytes[0..source_length]);
        if (count == 0) break;

        try round.apply(source_bytes[0..source_length], &out);

        source_length = out.count();

        @memcpy(source_bytes[0..source_length], out.const_slice());
        rounds += 1;
    }

    try std.testing.expectEqual(1, rounds);

    try std.testing.expectEqualStrings(
        "def f(value):\n    return value\n",
        source_bytes[0..source_length],
    );

    try std.testing.expectEqual(0, try round.record(source_bytes[0..source_length]));
}

test "a first round records two fixed diagnostics" {
    const gpa = std.testing.allocator;
    var round = try Round.init(gpa);
    defer round.deinit(gpa);

    try std.testing.expectEqual(2, try round.record(source_text));
    try std.testing.expectEqual(2, round.fixes.count());

    var offset_previous: u32 = 0;

    for (round.diagnostics.slice()) |*diagnostic| {
        try std.testing.expectEqualStrings("PR001", diagnostic.code);
        try std.testing.expect(diagnostic.fix != null);
        try std.testing.expect(diagnostic.span.offset >= offset_previous);

        offset_previous = diagnostic.span.offset;
    }
}

test "an apply lands every disjoint fix in one pass" {
    const gpa = std.testing.allocator;
    var out = try Buffer.init(gpa, source_bytes_max);
    defer out.deinit(gpa);

    var round = try Round.init(gpa);
    defer round.deinit(gpa);

    try std.testing.expectEqual(2, try round.record(source_text));
    try round.apply(source_text, &out);
    try std.testing.expectEqual(2, round.applied);
    try std.testing.expectEqual(round.fixes.count(), round.applied);
    try std.testing.expectEqualStrings("def f(value):\n    return value\n", out.const_slice());
}

test "an empty edit set copies the source" {
    const gpa = std.testing.allocator;
    var out = try Buffer.init(gpa, source_bytes_max);
    defer out.deinit(gpa);

    var round = try Round.init(gpa);
    defer round.deinit(gpa);

    try round.apply(source_text, &out);
    try std.testing.expectEqual(0, round.fixes.count());
    try std.testing.expectEqual(0, round.applied);
    try std.testing.expectEqualStrings(source_text, out.const_slice());
}
