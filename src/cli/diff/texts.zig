const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const Span = @import("../../stdx/bounded/span.zig");

pub const Texts = struct {
    after: []const u8,
    before: []const u8,
};

pub const CapacityError = error{LinesExhausted};
pub const no_newline_note = "\\ No newline at end of file\n";

pub fn lines_exact_of(text: []const u8, out: *ArrayType(Span)) CapacityError!void {
    assert(out.empty());
    assert(text.len <= std.math.maxInt(u32));

    var start: u32 = 0;

    for (0..text.len) |_| {
        if (start >= text.len) break;
        if (out.full()) return error.LinesExhausted;

        const terminator = std.mem.findAnyPos(u8, text, start, "\r\n");
        var end: u32 = if (terminator) |at| @intCast(at + 1) else @intCast(text.len);

        if (terminator) |at| {
            const pair = std.mem.startsWith(u8, text[at..], "\r\n");

            if (pair) end += 1;
        }

        assert(end > start);

        out.push(.between(start, end));
        start = end;
    }

    assert(start == text.len);
    assert(out.count() <= out.capacity());
}

pub fn lines_of(text: []const u8, out: *ArrayType(Span)) CapacityError!void {
    assert(out.empty());
    assert(text.len <= std.math.maxInt(u32));

    var start: u32 = 0;

    for (0..text.len) |_| {
        if (start >= text.len) break;
        if (out.full()) return error.LinesExhausted;

        const newline = std.mem.findScalarPos(u8, text, start, '\n');
        const end: u32 = if (newline) |at| @intCast(at + 1) else @intCast(text.len);

        assert(end > start);

        out.push(.between(start, end));
        start = end;
    }

    assert(start == text.len);
    assert(out.count() <= out.capacity());
}

pub fn trimmed(text: []const u8, span: Span) []const u8 {
    assert(text.len <= std.math.maxInt(u32));
    assert(span.end() <= text.len);

    const held = span.text(text);
    const kept = std.mem.trimEnd(u8, held, "\r\n");

    assert(kept.len <= held.len);
    assert(std.mem.startsWith(u8, held, kept));

    return kept;
}

fn test_lines(text: []const u8, line_count_max: u32, exact: bool) !u32 {
    assert(text.len <= std.math.maxInt(u32));
    assert(line_count_max < std.math.maxInt(u32));

    var lines: ArrayType(Span) = try .init(std.testing.allocator, line_count_max);
    defer lines.deinit(std.testing.allocator);

    if (exact) {
        try lines_exact_of(text, &lines);
    } else {
        try lines_of(text, &lines);
    }

    return lines.count();
}

test "a text splits into its lines and keeps each terminator" {
    try std.testing.expectEqual(@as(u32, 3), try test_lines("a\r\nb\rc", 4, true));
    try std.testing.expectEqual(@as(u32, 2), try test_lines("a\r\nb\rc", 4, false));
    try std.testing.expectEqual(@as(u32, 0), try test_lines("", 1, true));
    try std.testing.expectEqualStrings("a", trimmed("a\r\n", .{ .offset = 0, .length = 3 }));
}

test "a text with more lines than the table holds is refused" {
    try std.testing.expectError(error.LinesExhausted, test_lines("a\nb\nc\n", 2, false));
    try std.testing.expectError(error.LinesExhausted, test_lines("a\nb\nc\n", 2, true));
    try std.testing.expectEqual(@as(u32, 2), try test_lines("a\nb\n", 2, false));
}
