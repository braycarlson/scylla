const std = @import("std");
const assert = std.debug.assert;
const scan = @import("scan.zig");

pub const LineEnding = enum {
    carriage_return,
    carriage_return_line_feed,
    line_feed,

    pub fn bytes(ending: LineEnding) []const u8 {
        const result: []const u8 = switch (ending) {
            .carriage_return => "\r",
            .carriage_return_line_feed => "\r\n",
            .line_feed => "\n",
        };

        assert(result.len > 0);
        assert(result.len <= 2);

        return result;
    }

    pub fn of_source(source: []const u8) LineEnding {
        assert(source.len <= std.math.maxInt(u32));

        const found = std.mem.findAny(u8, source, "\r\n") orelse return .line_feed;
        if (source[found] == '\n') return .line_feed;

        assert(source[found] == '\r');
        if (scan.byte_at(source, @intCast(found + 1)) == '\n') return .carriage_return_line_feed;
        return .carriage_return;
    }
};

test "a line ending is read from the first break of a source" {
    try std.testing.expectEqual(LineEnding.line_feed, LineEnding.of_source("a\nb\r\n"));
    const crlf = LineEnding.carriage_return_line_feed;

    try std.testing.expectEqual(crlf, LineEnding.of_source("a\r\nb\n"));
    try std.testing.expectEqual(LineEnding.carriage_return, LineEnding.of_source("a\rb"));
    try std.testing.expectEqual(LineEnding.line_feed, LineEnding.of_source("ab"));
    try std.testing.expectEqualStrings("\r\n", LineEnding.carriage_return_line_feed.bytes());
}
