const std = @import("std");
const assert = std.debug.assert;
const Span = @import("../stdx/bounded/span.zig");
const scan = @import("../text/scan.zig");

const Gap = struct {
    span: Span,
    token: u32,
};

fn GapsType(comptime T: type) type {
    comptime assert(@hasField(T, "offset"));
    comptime assert(@hasDecl(T, "end"));

    return struct {
        tokens: []const T,
        length: u32,
        position: u32,
        end_previous: u32,

        const Gaps = @This();

        pub fn next(walk: *Gaps) ?Gap {
            const token_count: u32 = @intCast(walk.tokens.len);

            assert(walk.end_previous <= walk.length);

            if (walk.position > token_count) return null;

            const offset = walk.end_previous;

            const end = if (walk.position == token_count)
                walk.length
            else
                walk.tokens[walk.position].offset;

            assert(end >= offset);
            assert(end <= walk.length);

            if (walk.position < token_count) {
                walk.end_previous = walk.tokens[walk.position].end();
            }

            const gap: Gap = .{
                .span = .{ .offset = offset, .length = end - offset },
                .token = walk.position,
            };

            walk.position += 1;

            return gap;
        }
    };
}

pub fn comment_text_start(source: []const u8, comment: Span) u32 {
    assert(comment.end() <= source.len);

    const text = source[comment.offset..comment.end()];
    const skipped = std.mem.findNone(u8, text, "#\t ") orelse text.len;
    const start = comment.offset + @as(u32, @intCast(skipped));

    assert(start >= comment.offset);
    assert(start <= comment.end());

    return start;
}

pub fn gaps(comptime T: type, length: u32, tokens: []const T) GapsType(T) {
    assert(tokens.len <= std.math.maxInt(u32));

    if (tokens.len > 0) assert(tokens[tokens.len - 1].end() <= length);

    return .{ .tokens = tokens, .length = length, .position = 0, .end_previous = 0 };
}

pub fn gap_is_blank(source: []const u8, gap: Span, continuation: ?u8) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(gap.end() <= source.len);
    if (continuation) |byte| assert(!scan.is_ascii_whitespace(byte));

    var offset = gap.offset;

    if (offset == 0) {
        if (std.mem.startsWith(u8, source, scan.byte_order_mark)) {
            offset += @min(scan.byte_order_mark.len, gap.length);
        }
    }

    while (offset < gap.end()) {
        if (is_blank(source[offset], continuation)) {
            offset += 1;

            continue;
        }

        const width = scan.whitespace_width(source, offset);
        if (width == 0) return false;

        offset += width;
    }

    assert(offset >= gap.end());

    return true;
}

fn is_blank(byte: u8, continuation: ?u8) bool {
    if (continuation) |held| assert(!std.ascii.isWhitespace(held));

    switch (byte) {
        '\t', '\n', 0x0b, 0x0c, '\r', ' ' => return true,
        else => {},
    }

    return byte == continuation;
}

test "the gaps between tokens cover the source around them" {
    const Token = @import("token.zig");

    const tokens = [_]Token{
        .{ .offset = 2, .length = 3, .kind = .identifier },
        .{ .offset = 5, .length = 1, .kind = .identifier },
    };

    var walk = gaps(Token, 9, &tokens);

    const expected = [_]Gap{
        .{ .span = .{ .offset = 0, .length = 2 }, .token = 0 },
        .{ .span = .{ .offset = 5, .length = 0 }, .token = 1 },
        .{ .span = .{ .offset = 6, .length = 3 }, .token = 2 },
    };

    for (expected) |gap| {
        const found = walk.next().?;

        try std.testing.expectEqual(gap, found);
    }

    const after = walk.next();

    try std.testing.expectEqual(null, after);
}

test "a gap of spaces and line breaks is blank and a gap with a byte is not" {
    const source = "\xef\xbb\xbf  \\\n x";

    try std.testing.expect(gap_is_blank(source, .{ .offset = 0, .length = 5 }, null));
    try std.testing.expect(!gap_is_blank(source, .{ .offset = 0, .length = 6 }, null));
    try std.testing.expect(gap_is_blank(source, .{ .offset = 0, .length = 7 }, '\\'));
    try std.testing.expect(!gap_is_blank(source, .{ .offset = 0, .length = 9 }, '\\'));
}
