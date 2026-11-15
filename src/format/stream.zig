const std = @import("std");
const assert = std.debug.assert;
const Buffer = @import("../stdx/bounded/buffer.zig");
const Token = @import("../syntax/token.zig");
const spaced = @import("text.zig").spaced;
const ascii_whitespace = " \t\n\x0c\r";

pub fn prefix_width(line: []const u8, width: u32) u32 {
    assert(line.len < std.math.maxInt(u32));

    var held: u32 = 0;
    var blanks: u32 = 0;

    for (line) |byte| {
        switch (byte) {
            ' ' => held += 1,
            '\t' => held += width,
            else => break,
        }

        blanks += 1;
    }

    assert(blanks <= line.len);
    if (width > 0) assert(held >= blanks);

    return held;
}

pub fn restreamed(out: *Buffer, text: []const u8, width: u32) error{Overflow}!void {
    assert(text.len < std.math.maxInt(u32));
    assert(width < std.math.maxInt(u32));

    const line_count = std.mem.count(u8, text, "\n") + 1;
    var start: usize = 0;

    for (0..line_count) |line_index| {
        const stop = std.mem.findScalarPos(u8, text, start, '\n') orelse text.len;
        const line = text[start..stop];

        start = stop + 1;

        if (line_index == 0) {
            try out.push(std.mem.trimEnd(u8, line, ascii_whitespace));

            continue;
        }

        try out.push("\n");

        const body = std.mem.trim(u8, line, ascii_whitespace);
        if (body.len == 0) continue;

        try spaced(out, prefix_width(line, width));
        try out.push(body);
    }

    assert(start == text.len + 1);
}

pub fn spilled(tokens: []const Token, source: []const u8, position: u32, close: u32) bool {
    assert(source.len <= std.math.maxInt(u32));

    if (close < position) return false;

    assert(close < tokens.len);

    for (tokens[position .. close + 1]) |token| {
        const textual = token.kind == .comment or token.kind == .string;
        if (!textual) continue;
        if (std.mem.findScalar(u8, token.text(source), '\n') != null) return true;
    }

    return false;
}

test "a prefix width counts spaces once and tabs at the given width" {
    try std.testing.expectEqual(@as(u32, 6), prefix_width("  \tx", 4));
    try std.testing.expectEqual(@as(u32, 0), prefix_width("x  ", 4));
    try std.testing.expectEqual(@as(u32, 3), prefix_width("   ", 8));
}

test "a restreamed text reindents every line after the first" {
    var out: Buffer = try .init(std.testing.allocator, 64);
    defer out.deinit(std.testing.allocator);

    try restreamed(&out, "first  \n    second\n\n\tthird  ", 4);
    try std.testing.expectEqualStrings("first\n    second\n\n    third", out.const_slice());

    var small: Buffer = try .init(std.testing.allocator, 4);
    defer small.deinit(std.testing.allocator);

    try std.testing.expectError(error.Overflow, restreamed(&small, "ab\n  cd", 4));
}

test "a comment or string across lines spills" {
    var lexed = try Lexed.init(.javascript, "a /* x\ny */ b 'c'");
    defer lexed.deinit();

    const tokens = lexed.tokens.slice();
    const last: u32 = @intCast(tokens.len - 1);

    try std.testing.expect(spilled(tokens, lexed.source, 0, last));
    try std.testing.expect(!spilled(tokens, lexed.source, 0, 0));
    try std.testing.expect(!spilled(tokens, lexed.source, last, last));
    try std.testing.expect(!spilled(tokens, lexed.source, 1, 0));
}

const Lexed = @import("../syntax/testing/lexed.zig").Lexed;
