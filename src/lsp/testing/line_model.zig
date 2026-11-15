const std = @import("std");
const assert = std.debug.assert;
const scan = @import("../../text/scan.zig");
const Encoding = @import("../../text/line_index.zig").LineIndex.Encoding;
const Point = @import("../../text/line_index.zig").LineIndex.Point;
const Span = @import("../../stdx/bounded/span.zig");
const TextDocument = @import("../text_document.zig").TextDocument;

pub const LineModel = struct {
    length: u32,
    line_count: u32,
    lines: [model_line_count_max]u32,
    text: [model_bytes_max]u8,

    pub const empty: LineModel = .{
        .length = 0,
        .line_count = 1,
        .lines = @splat(0),
        .text = @splat(0),
    };

    pub fn bytes(model: *const LineModel) []const u8 {
        assert(model.length <= model_bytes_max);
        assert(model.line_count >= 1);

        return model.text[0..model.length];
    }

    pub fn clear(model: *LineModel) void {
        model.length = 0;
        model.line_count = 1;
        model.lines[0] = 0;

        assert(model.bytes().len == 0);
    }

    pub fn boundary_at(model: *const LineModel, offset: u32) u32 {
        const text = model.bytes();

        assert(offset <= text.len);

        var candidate = offset;

        for (0..4) |_| {
            if (scan.is_char_boundary(text, candidate)) break;

            candidate -= 1;
        } else unreachable;

        assert(candidate <= offset);
        assert(scan.is_char_boundary(text, candidate));

        return candidate;
    }

    pub fn line_end(model: *const LineModel, line: u32) u32 {
        assert(model.line_count > 0);
        assert(line < model.line_count);

        if (line + 1 < model.line_count) {
            assert(model.lines[line + 1] < std.math.maxInt(u32));

            return model.lines[line + 1];
        }

        return model.length;
    }

    fn line_of(model: *const LineModel, offset: u32) u32 {
        assert(offset <= model.length);

        var line: u32 = 0;

        for (model.lines[0..model.line_count], 0..) |start, index| {
            if (start <= offset) line = @intCast(index);
        }

        assert(line < model.line_count);
        assert(model.lines[line] <= offset);

        return line;
    }

    pub fn line_start(model: *const LineModel, line: u32) u32 {
        assert(line < model.line_count);
        assert(model.lines[line] <= model.length);

        return model.lines[line];
    }

    pub fn offset_in(model: *const LineModel, position: Point, encoding: Encoding) ?u32 {
        if (position.line >= model.line_count) return null;

        const start = model.line_start(position.line);
        const end = model.line_end(position.line);
        const text = model.bytes()[start..end];

        assert(start <= end);

        var units: u32 = 0;
        var cursor: u32 = 0;

        for (0..text.len) |_| {
            if (cursor >= text.len) break;

            if (units == position.character) {
                assert(start + cursor < std.math.maxInt(u32));

                return start + cursor;
            }

            const character_bytes = character_length(text, cursor);

            units += encoding.width(character_bytes);
            cursor += character_bytes;
        }

        assert(cursor == text.len);

        if (units == position.character) return end;
        return null;
    }

    pub fn position_in(model: *const LineModel, offset: u32, encoding: Encoding) Point {
        assert(offset <= model.length);

        const line = model.line_of(offset);
        const start = model.line_start(line);

        assert(start <= offset);

        return .{ .character = encoding.count(model.bytes()[start..offset]), .line = line };
    }

    pub fn replaced(model: *LineModel, insertion: []const u8) TextDocument.Error!void {
        assert(insertion.len <= std.math.maxInt(u32));

        if (!std.unicode.utf8ValidateSlice(insertion)) {
            model.clear();

            return error.Utf8Invalid;
        }

        if (insertion.len > model_bytes_max) {
            model.clear();

            return error.TextExhausted;
        }

        if (newline_count(insertion) + 1 > model_line_count_max) {
            model.clear();

            return error.LinesExhausted;
        }

        @memcpy(model.text[0..insertion.len], insertion);
        model.length = @intCast(insertion.len);

        model.index_rebuild();

        assert(std.mem.eql(u8, model.bytes(), insertion));
    }

    pub fn spliced(
        model: *LineModel,
        removed: Span,
        insertion: []const u8,
    ) TextDocument.Error!void {
        assert(removed.length <= std.math.maxInt(u32) - removed.offset);

        const start = removed.offset;
        const end = removed.end();

        assert(start <= end);
        assert(end <= model.length);

        if (!std.unicode.utf8ValidateSlice(insertion)) return error.Utf8Invalid;
        if (insertion.len > model_bytes_max) return error.TextExhausted;

        const length = model.length - (end - start) + insertion.len;
        if (length > model_bytes_max) return error.TextExhausted;

        if (model.line_count_after(start, end, insertion) > model_line_count_max) {
            model.clear();

            return error.LinesExhausted;
        }

        const tail = model.length - end;

        @memmove(model.text[start + insertion.len ..][0..tail], model.text[end..][0..tail]);
        @memcpy(model.text[start..][0..insertion.len], insertion);
        model.length = @intCast(length);

        model.index_rebuild();

        assert(model.length == length);
    }

    pub fn units_of(model: *const LineModel, line: u32, encoding: Encoding) u32 {
        assert(line < std.math.maxInt(u32));

        const start = model.line_start(line);
        const end = model.line_end(line);

        assert(start <= end);
        assert(end <= model.length);

        return encoding.count(model.bytes()[start..end]);
    }

    fn index_rebuild(model: *LineModel) void {
        assert(model.length <= model_bytes_max);

        model.line_count = 1;
        model.lines[0] = 0;

        for (model.bytes(), 0..) |byte, offset| {
            if (byte != '\n') continue;

            assert(model.line_count < model_line_count_max);

            model.lines[model.line_count] = @intCast(offset + 1);
            model.line_count += 1;
        }

        assert(model.line_count <= model_line_count_max);
    }

    fn line_count_after(model: *const LineModel, start: u32, end: u32, insertion: []const u8) u32 {
        assert(start <= end);
        assert(insertion.len <= std.math.maxInt(u32));

        var first: u32 = 0;
        var last: u32 = 0;

        for (model.lines[0..model.line_count]) |offset| {
            if (offset <= start) first += 1;
            if (offset <= end) last += 1;
        }

        assert(first <= last);
        assert(last <= model.line_count);

        return first + newline_count(insertion) + (model.line_count - last);
    }
};

pub const model_bytes_max: u32 = 4_096;
pub const model_line_count_max: u32 = 64;

comptime {
    assert(model_line_count_max <= model_bytes_max);
}

fn character_length(text: []const u8, offset: u32) u32 {
    assert(offset < text.len);

    const length = std.unicode.utf8ByteSequenceLength(text[offset]) catch unreachable;

    assert(length >= 1);
    assert(offset + length <= text.len);

    return length;
}

fn newline_count(text: []const u8) u32 {
    assert(text.len <= std.math.maxInt(u32));

    const count: u32 = @intCast(std.mem.countScalar(u8, text, '\n'));

    assert(count <= text.len);

    return count;
}

test LineModel {
    var model: LineModel = .empty;

    try model.replaced("one\ntwo");
    try model.spliced(.between(3, 4), " and ");
    try std.testing.expectEqualStrings("one and two", model.bytes());
    try std.testing.expectEqual(1, model.line_count);
    try std.testing.expectEqual(11, model.line_end(0));
    try std.testing.expectEqual(5, model.position_in(5, .utf8).character);
}

test "a model takes a replacement and indexes its lines" {
    var model: LineModel = .empty;

    try model.replaced("one\ntwo\n\u{e9}");

    try std.testing.expectEqual(@as(u32, 3), model.line_count);
    try std.testing.expectEqual(@as(u32, 4), model.line_start(1));
    try std.testing.expectEqual(@as(u32, 8), model.line_end(1));
    try std.testing.expectEqual(@as(u32, 10), model.line_end(2));
    try std.testing.expectEqual(@as(u32, 1), model.units_of(2, .utf16));
    try std.testing.expectEqual(@as(u32, 2), model.units_of(2, .utf8));
}

test "a model maps offsets and positions both ways" {
    var model: LineModel = .empty;

    try model.replaced("a\u{1F600}b\nc");

    const position = model.position_in(5, .utf16);
    const inside: Point = .{ .line = 0, .character = 2 };
    const below: Point = .{ .line = 2, .character = 0 };

    try std.testing.expectEqual(@as(u32, 0), position.line);
    try std.testing.expectEqual(@as(u32, 3), position.character);
    try std.testing.expectEqual(@as(?u32, 5), model.offset_in(position, .utf16));
    try std.testing.expectEqual(@as(?u32, null), model.offset_in(inside, .utf16));
    try std.testing.expectEqual(@as(?u32, null), model.offset_in(below, .utf8));
    try std.testing.expectEqual(@as(u32, 1), model.boundary_at(3));
}

test "a model splices and refuses what a document refuses" {
    var model: LineModel = .empty;

    try model.replaced("first\nsecond");
    try model.spliced(.between(5, 6), " and ");
    try std.testing.expectEqualStrings("first and second", model.bytes());
    try std.testing.expectEqual(@as(u32, 1), model.line_count);
    try std.testing.expectError(error.Utf8Invalid, model.spliced(.empty, "\xff"));
    try std.testing.expectEqualStrings("first and second", model.bytes());

    const lines: [model_line_count_max]u8 = @splat('\n');

    try std.testing.expectError(error.LinesExhausted, model.spliced(.empty, &lines));
    try std.testing.expectEqual(@as(u32, 0), model.length);
    try std.testing.expectError(error.Utf8Invalid, model.replaced("\xc3"));
}
