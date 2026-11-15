const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Random = @import("../testing/random.zig");
const Span = @import("../stdx/bounded/span.zig");
const scan = @import("scan.zig");

pub const LineIndex = struct {
    starts: ArrayType(u32),

    pub const CapacityError = error{Truncated};

    pub const Encoding = enum {
        utf16,
        utf32,
        utf8,

        pub fn count(encoding: Encoding, text: []const u8) u32 {
            assert(text.len <= std.math.maxInt(u32));

            var units: u32 = 0;
            var offset: usize = 0;

            while (offset < text.len) {
                const character_bytes = character_length(text, offset);

                assert(character_bytes <= text.len - offset);

                units += encoding.width(character_bytes);
                offset += character_bytes;
            }

            assert(offset == text.len);
            assert(units <= text.len);

            return units;
        }

        pub fn name(encoding: Encoding) []const u8 {
            const result: []const u8 = switch (encoding) {
                .utf16 => "utf-16",
                .utf32 => "utf-32",
                .utf8 => "utf-8",
            };

            assert(std.mem.startsWith(u8, result, "utf-"));

            return result;
        }

        pub fn of(text: []const u8) ?Encoding {
            assert(text.len <= std.math.maxInt(u32));

            const names = std.StaticStringMap(Encoding).initComptime(.{
                .{ "utf-16", .utf16 },
                .{ "utf-32", .utf32 },
                .{ "utf-8", .utf8 },
            });

            const found = names.get(text);

            if (found) |held| assert(std.mem.eql(u8, held.name(), text));

            return found;
        }

        pub fn width(encoding: Encoding, character_bytes: u32) u32 {
            assert(character_bytes >= 1);
            assert(character_bytes <= 4);

            return switch (encoding) {
                .utf16 => if (character_bytes == 4) 2 else 1,
                .utf32 => 1,
                .utf8 => character_bytes,
            };
        }
    };

    pub const Plan = struct {
        added: u32,
        first: u32,
        last: u32,
    };

    pub const Point = struct {
        line: u32,
        character: u32,
    };

    pub const Range = struct {
        start: Point,
        end: Point,
    };

    pub fn init(gpa: std.mem.Allocator, line_count_max: u32) std.mem.Allocator.Error!LineIndex {
        assert(line_count_max > 0);

        var index: LineIndex = .{ .starts = try .init(gpa, line_count_max) };

        index.clear();

        assert(index.count() == 1);
        assert(index.capacity() == line_count_max);

        return index;
    }

    pub fn deinit(index: *LineIndex, gpa: std.mem.Allocator) void {
        assert(index.starts.capacity() > 0);
        assert(index.starts.get(0) == 0);

        index.starts.deinit(gpa);
        index.* = undefined;
    }

    pub fn build(index: *LineIndex, source: []const u8) CapacityError!void {
        assert(source.len <= std.math.maxInt(u32));

        index.clear();

        for (source, 0..) |byte, offset| {
            if (byte != '\n') continue;

            if (index.starts.full()) {
                index.clear();

                return error.Truncated;
            }

            index.starts.push(@intCast(offset + 1));
        }

        assert(index.count() > 0);
        assert(index.starts.get(0) == 0);
    }

    pub fn capacity(index: *const LineIndex) u32 {
        assert(index.starts.count() <= index.starts.capacity());

        return index.starts.capacity();
    }

    pub fn clear(index: *LineIndex) void {
        index.starts.clear();
        index.starts.push(0);

        assert(index.count() == 1);
    }

    pub fn count(index: *const LineIndex) u32 {
        const line_count = index.starts.count();

        assert(line_count > 0);
        assert(line_count <= index.starts.capacity());

        return line_count;
    }

    pub fn line_end(index: *const LineIndex, line: u32, source: []const u8) u32 {
        assert(line < index.count());
        assert(source.len <= std.math.maxInt(u32));

        if (line + 1 < index.count()) {
            assert(index.starts.get(line + 1) <= source.len);

            return index.starts.get(line + 1);
        }

        assert(line + 1 == index.count());

        return @intCast(source.len);
    }

    pub fn line_of(index: *const LineIndex, offset: u32) u32 {
        assert(offset < std.math.maxInt(u32));

        const starts = index.starts.const_slice();
        const after = std.sort.partitionPoint(u32, starts, offset, starts_at_or_before);

        assert(after > 0);
        assert(after <= starts.len);

        const line: u32 = @intCast(after - 1);

        assert(index.starts.get(line) <= offset);

        return line;
    }

    pub fn line_start(index: *const LineIndex, line: u32) u32 {
        assert(line < index.count());

        const start = index.starts.get(line);

        assert(start <= index.starts.get(index.count() - 1));

        return start;
    }

    fn line_start_after_mark(index: *const LineIndex, line: u32, source: []const u8) u32 {
        assert(line < index.count());
        assert(source.len <= std.math.maxInt(u32));

        const start = index.starts.get(line);
        if (line > 0) return start;

        assert(start == 0);

        return start + scan.mark_width(source);
    }

    pub fn line_span(index: *const LineIndex, line: u32, source: []const u8) Span {
        assert(line < index.count());
        assert(source.len <= std.math.maxInt(u32));

        const start = index.line_start_after_mark(line, source);

        const end: u32 = if (line + 1 < index.count())
            terminator_start(source, index.starts.get(line + 1) - 1, start)
        else
            @intCast(source.len);

        assert(start <= end);
        assert(end <= source.len);

        return Span.between(start, end);
    }

    pub fn line_span_terminated(index: *const LineIndex, line: u32, source: []const u8) Span {
        assert(line < index.count());
        assert(source.len <= std.math.maxInt(u32));

        const start = index.line_start_after_mark(line, source);

        const end: u32 = if (line + 1 < index.count())
            index.starts.get(line + 1)
        else
            @intCast(source.len);

        assert(start <= end);
        assert(end <= source.len);

        return Span.between(start, end);
    }

    fn terminator_of(index: *const LineIndex, line: u32, source: []const u8) []const u8 {
        assert(line < index.count());
        assert(source.len <= std.math.maxInt(u32));

        const span = index.line_span(line, source);
        const terminated = index.line_span_terminated(line, source);

        assert(span.end() <= terminated.end());

        const result = source[span.end()..terminated.end()];

        assert(result.len <= 2);

        return result;
    }

    pub fn splice_plan(index: *const LineIndex, replaced: Span, inserted: []const u8) ?Plan {
        assert(replaced.length <= std.math.maxInt(u32) - replaced.offset);
        assert(inserted.len <= std.math.maxInt(u32));

        const start = replaced.offset;
        const end = replaced.end();

        assert(start <= end);

        const starts = index.starts.const_slice();
        const first = std.sort.partitionPoint(u32, starts, start, starts_at_or_before);
        const last = std.sort.partitionPoint(u32, starts, end, starts_at_or_before);
        const added: u32 = @intCast(std.mem.count(u8, inserted, "\n"));

        assert(first <= last);
        assert(first > 0);
        assert(last <= index.count());

        const line_count = first + added + (index.count() - last);
        if (line_count > index.capacity()) return null;
        return .{ .added = added, .first = @intCast(first), .last = @intCast(last) };
    }

    pub fn splice_apply(
        index: *LineIndex,
        replaced: Span,
        inserted: []const u8,
        plan: *const Plan,
    ) void {
        assert(replaced.length <= std.math.maxInt(u32) - replaced.offset);
        assert(inserted.len <= std.math.maxInt(u32));

        const start = replaced.offset;
        const end = replaced.end();

        assert(start <= end);
        assert(plan.first <= plan.last);
        assert(plan.first > 0);

        const delta = @as(i64, @intCast(inserted.len)) - @as(i64, end - start);

        index.starts.shift_tail(.{ .from = plan.last, .to = plan.first + plan.added });

        var cursor = plan.first;

        for (inserted, 0..) |byte, position| {
            if (byte != '\n') continue;

            index.starts.buffer[cursor] = start + @as(u32, @intCast(position)) + 1;
            cursor += 1;
        }

        assert(cursor == plan.first + plan.added);

        for (index.starts.slice()[cursor..]) |*offset| {
            offset.* = @intCast(@as(i64, offset.*) + delta);
        }

        assert(index.starts.get(0) == 0);
    }

    fn offset_clamped(
        index: *const LineIndex,
        source: []const u8,
        position: Point,
        encoding: Encoding,
    ) u32 {
        assert(source.len <= std.math.maxInt(u32));

        const length: u32 = @intCast(source.len);
        const line = @min(position.line, index.count() - 1);
        const start = index.line_start(line);

        const text = text_between(source, start, index.line_end(line, source)) orelse {
            return start;
        };

        var offset = start;
        var units: u32 = 0;
        var cursor: usize = 0;

        assert(line < index.count());

        while (cursor < text.len) {
            if (units >= position.character) break;
            if (text[cursor] == '\n') break;

            const character_bytes = character_length(text, cursor);

            units += encoding.width(character_bytes);
            offset += character_bytes;
            cursor += character_bytes;
        }

        assert(offset >= start);
        assert(cursor <= text.len);

        return @min(offset, length);
    }

    pub fn point_clamped(
        index: *const LineIndex,
        source: []const u8,
        offset: u32,
        encoding: Encoding,
    ) Point {
        assert(source.len <= std.math.maxInt(u32));
        assert(offset < std.math.maxInt(u32));

        const at: u32 = @intCast(@min(offset, source.len));
        const line = index.line_of(at);
        const text = text_between(source, index.line_start(line), at);
        const character = if (text) |held| encoding.count(held) else 0;

        assert(line < index.count());
        if (text) |held| assert(character <= held.len);

        return .{ .line = line, .character = character };
    }

    pub fn offset_of(
        index: *const LineIndex,
        source: []const u8,
        position: Point,
        encoding: Encoding,
    ) ?u32 {
        if (position.line >= index.count()) return null;
        assert(source.len <= std.math.maxInt(u32));

        const start = index.starts.get(position.line);
        const end = index.line_end(position.line, source);
        const text = slice_of(source, start, end);
        var units: u32 = 0;
        var cursor: u32 = 0;

        while (cursor < text.len) {
            if (units == position.character) {
                assert(start + cursor <= end);

                return start + cursor;
            }

            const character_bytes = character_length(text, cursor);

            units += encoding.width(character_bytes);
            cursor += character_bytes;
        }

        assert(cursor == text.len);
        assert(units <= text.len);

        if (units == position.character) return end;
        return null;
    }

    pub fn point_of(
        index: *const LineIndex,
        source: []const u8,
        offset: u32,
        encoding: Encoding,
    ) Point {
        assert(offset <= source.len);

        const line = index.line_of(offset);
        const start = index.starts.get(line);

        assert(start <= offset);

        const character = encoding.count(slice_of(source, start, offset));

        assert(character <= offset - start);

        return .{ .line = line, .character = character };
    }

    fn push(index: *LineIndex, start: u32) CapacityError!void {
        if (index.starts.full()) return error.Truncated;
        assert(start < std.math.maxInt(u32));

        index.starts.push(start);
    }

    pub fn range_of(
        index: *const LineIndex,
        source: []const u8,
        span: Span,
        encoding: Encoding,
    ) Range {
        assert(source.len <= std.math.maxInt(u32));
        assert(span.length <= std.math.maxInt(u32) - span.offset);

        const range: Range = .{
            .start = index.point_clamped(source, span.offset, encoding),
            .end = index.point_clamped(source, span.end(), encoding),
        };

        assert(range.start.line <= range.end.line);

        return range;
    }

    fn shift_tail(index: *LineIndex, from: u32, to: u32) CapacityError!void {
        assert(from <= index.count());
        assert(to < std.math.maxInt(u32));

        if (to + (index.count() - from) > index.capacity()) return error.Truncated;

        index.starts.shift_tail(.{ .from = from, .to = to });
    }

    pub fn span_of(
        index: *const LineIndex,
        source: []const u8,
        range: Range,
        encoding: Encoding,
    ) Span {
        assert(source.len <= std.math.maxInt(u32));

        const first = index.offset_clamped(source, range.start, encoding);
        const second = index.offset_clamped(source, range.end, encoding);

        assert(first <= source.len);
        assert(second <= source.len);

        return Span.between(@min(first, second), @max(first, second));
    }

    pub fn validate(index: *const LineIndex, length: u32) void {
        assert(index.count() > 0);
        assert(index.starts.get(0) == 0);
        assert(index.starts.get(index.count() - 1) <= length);
    }
};

fn starts_at_or_before(offset: u32, start: u32) bool {
    return start <= offset;
}

fn character_length(text: []const u8, offset: usize) u32 {
    assert(offset < text.len);

    const length = std.unicode.utf8ByteSequenceLength(text[offset]) catch 1;

    assert(length >= 1);

    const result: u32 = @min(length, @as(u32, @intCast(text.len - offset)));

    assert(result >= 1);
    assert(result <= 4);

    return result;
}

fn terminator_start(source: []const u8, newline: u32, start: u32) u32 {
    assert(newline >= start);
    assert(newline < source.len);
    assert(source[newline] == '\n');

    if (newline > start) {
        if (source[newline - 1] == '\r') {
            assert(newline - 1 >= start);

            return newline - 1;
        }
    }

    return newline;
}

fn text_between(source: []const u8, start: u32, end: u32) ?[]const u8 {
    assert(start <= source.len);
    assert(end < std.math.maxInt(u32));

    const stop = @max(start, end);
    if (stop > source.len) return null;

    const text = source[start..stop];
    if (!std.unicode.utf8ValidateSlice(text)) return null;
    return text;
}

fn slice_of(source: []const u8, start: u32, end: u32) []const u8 {
    assert(start <= end);
    assert(end <= source.len);

    const text = source[start..end];

    assert(std.unicode.utf8ValidateSlice(text));

    return text;
}

fn built(source: []const u8, line_count_max: u32) !LineIndex {
    assert(source.len <= std.math.maxInt(u32));
    assert(line_count_max < std.math.maxInt(u32));

    var index: LineIndex = try .init(std.testing.allocator, line_count_max);
    errdefer index.deinit(std.testing.allocator);

    try index.build(source);

    assert(index.count() == std.mem.count(u8, source, "\n") + 1);

    return index;
}

fn is_boundary(source: []const u8, offset: usize) bool {
    assert(offset <= source.len);

    if (offset == source.len) return true;
    return source[offset] & 0xc0 != 0x80;
}

test LineIndex {
    const gpa = std.testing.allocator;
    const source = "one\ntwo\nthree";
    var index: LineIndex = try .init(gpa, 8);
    defer index.deinit(gpa);

    try index.build(source);

    const point = index.point_of(source, 5, .utf16);

    try std.testing.expectEqual(3, index.count());
    try std.testing.expectEqual(1, index.line_of(5));
    try std.testing.expectEqualStrings("two", index.line_span(1, source).text(source));
    try std.testing.expectEqual(LineIndex.Point{ .line = 1, .character = 1 }, point);
}

test "an empty source carries one line" {
    var index = try built("", 64);
    defer index.deinit(std.testing.allocator);

    try std.testing.expectEqual(1, index.count());
    try std.testing.expectEqual(0, index.line_start(0));
    try std.testing.expectEqual(0, index.line_end(0, ""));
}

test "a line break opens the next line" {
    const source = "one\ntwo\nthree";
    var index = try built(source, 64);
    defer index.deinit(std.testing.allocator);

    try std.testing.expectEqual(3, index.count());
    try std.testing.expectEqual(0, index.line_start(0));
    try std.testing.expectEqual(4, index.line_start(1));
    try std.testing.expectEqual(8, index.line_start(2));
    try std.testing.expectEqual(8, index.line_end(1, source));
    try std.testing.expectEqual(13, index.line_end(2, source));
}

test "a trailing break opens an empty last line" {
    var index = try built("one\n", 64);
    defer index.deinit(std.testing.allocator);

    try std.testing.expectEqual(2, index.count());
    try std.testing.expectEqual(4, index.line_start(1));
    try std.testing.expectEqual(4, index.line_end(1, "one\n"));
}

test "an offset maps to its line and column" {
    const source = "one\ntwo\n";
    var index = try built(source, 64);
    defer index.deinit(std.testing.allocator);

    const expect = std.testing.expectEqual;

    try expect(LineIndex.Point{ .line = 0, .character = 0 }, index.point_of(source, 0, .utf8));
    try expect(LineIndex.Point{ .line = 1, .character = 0 }, index.point_of(source, 4, .utf8));
    try expect(LineIndex.Point{ .line = 1, .character = 2 }, index.point_of(source, 6, .utf8));
}

test "a clamped position stops at the line and the source" {
    const source = "one\ntwo\n";
    var index = try built(source, 64);
    defer index.deinit(std.testing.allocator);

    const inside: LineIndex.Point = .{ .line = 1, .character = 1 };
    const wide: LineIndex.Point = .{ .line = 1, .character = 99 };
    const below: LineIndex.Point = .{ .line = 99, .character = 0 };

    try std.testing.expectEqual(5, index.offset_clamped(source, inside, .utf8));
    try std.testing.expectEqual(7, index.offset_clamped(source, wide, .utf8));
    try std.testing.expectEqual(8, index.offset_clamped(source, below, .utf8));
    try std.testing.expectEqual(2, index.point_clamped(source, 99, .utf8).line);
}

test "utf thirty two counts one unit a character" {
    const source = "a\u{1F600}b\n";
    const after: u32 = "a\u{1F600}".len;
    var index = try built(source, 64);
    defer index.deinit(std.testing.allocator);

    try std.testing.expectEqual(2, index.point_clamped(source, after, .utf32).character);
    try std.testing.expectEqual(3, index.point_clamped(source, after, .utf16).character);
    try std.testing.expectEqual(5, index.point_clamped(source, after, .utf8).character);
    try std.testing.expectEqual(LineIndex.Encoding.utf32, LineIndex.Encoding.of("utf-32").?);
    try std.testing.expectEqual(null, LineIndex.Encoding.of("utf-7"));
}

test "a surrogate pair counts as two utf sixteen units" {
    const source = "a\u{1F600}b\n";
    const after: u32 = "a\u{1F600}".len;
    var index = try built(source, 64);
    defer index.deinit(std.testing.allocator);

    const expect = std.testing.expectEqual;

    try expect(LineIndex.Point{ .line = 0, .character = 3 }, index.point_of(source, after, .utf16));
    try expect(LineIndex.Point{ .line = 0, .character = 5 }, index.point_of(source, after, .utf8));
}

test "a position maps back to its offset" {
    const source = "one\na\u{1F600}b\nthree";
    var index = try built(source, 64);
    defer index.deinit(std.testing.allocator);

    for (0..source.len) |offset| {
        if (!is_boundary(source, offset)) continue;

        const position = index.point_of(source, @intCast(offset), .utf16);
        const back = index.offset_of(source, position, .utf16).?;

        try std.testing.expectEqual(offset, back);
    }
}

test "a position past the last line maps to nothing" {
    const source = "one\n";
    var index = try built(source, 64);
    defer index.deinit(std.testing.allocator);

    const below: LineIndex.Point = .{ .line = 9, .character = 0 };
    const wide: LineIndex.Point = .{ .line = 0, .character = 9 };

    try std.testing.expectEqual(null, index.offset_of(source, below, .utf8));
    try std.testing.expectEqual(null, index.offset_of(source, wide, .utf8));
}

test "a column at the line end maps to the break" {
    const source = "one\ntwo";
    var index = try built(source, 64);
    defer index.deinit(std.testing.allocator);

    const end: LineIndex.Point = .{ .line = 0, .character = 3 };

    try std.testing.expectEqual(3, index.offset_of(source, end, .utf8).?);
}

test "a source with more lines than the budget is refused" {
    var index: LineIndex = try .init(std.testing.allocator, 4);
    defer index.deinit(std.testing.allocator);

    try std.testing.expectError(error.Truncated, index.build("a\nb\nc\nd\ne\nf\n"));
    try std.testing.expectEqual(1, index.count());
}

test "byte soup maps every offset back to itself" {
    const pieces = [_][]const u8{ "a", "\n", "\u{1F600}", "\u{00e4}", " " };
    var random: Random = .init(0x2B99_2DDF_A232_49D6);
    var index: LineIndex = try .init(std.testing.allocator, 1_024);
    defer index.deinit(std.testing.allocator);

    var buffer: [128 * 4]u8 = undefined;

    for (0..256) |_| {
        const piece_count = random.below(128);
        var length: usize = 0;

        for (0..piece_count) |_| {
            const piece = pieces[random.below(pieces.len)];

            @memcpy(buffer[length..][0..piece.len], piece);
            length += piece.len;
        }

        const source = buffer[0..length];

        try index.build(source);

        for (0..source.len) |offset| {
            if (!is_boundary(source, offset)) continue;

            const position = index.point_of(source, @intCast(offset), .utf16);
            const back = index.offset_of(source, position, .utf16).?;

            try std.testing.expectEqual(offset, back);
        }
    }
}

test "an offset inside the last line still names it" {
    var index = try built("one\ntwo", 64);
    defer index.deinit(std.testing.allocator);

    try std.testing.expectEqual(1, index.line_of(6));
    try std.testing.expectEqual(0, index.line_of(0));
    try std.testing.expectEqual(0, index.line_of(3));
    try std.testing.expectEqual(1, index.line_of(4));
}

test "a line span leaves its terminator outside" {
    const source = "one\r\ntwo\nthree";
    var index = try built(source, 8);
    defer index.deinit(std.testing.allocator);

    try std.testing.expectEqual(3, index.count());
    try std.testing.expectEqualStrings("one", index.line_span(0, source).text(source));
    try std.testing.expectEqualStrings("two", index.line_span(1, source).text(source));
    try std.testing.expectEqualStrings("three", index.line_span(2, source).text(source));
    try std.testing.expectEqualStrings("\r\n", index.terminator_of(0, source));
    try std.testing.expectEqualStrings("\n", index.terminator_of(1, source));
    try std.testing.expectEqualStrings("", index.terminator_of(2, source));
    const terminated = index.line_span_terminated(0, source);

    try std.testing.expectEqualStrings("one\r\n", terminated.text(source));
}

test "a first line starts after a byte order mark" {
    const source = "\xef\xbb\xbfone\ntwo";
    var index = try built(source, 8);
    defer index.deinit(std.testing.allocator);

    try std.testing.expectEqual(3, index.line_start_after_mark(0, source));
    try std.testing.expectEqual(7, index.line_start_after_mark(1, source));
    try std.testing.expectEqualStrings("one", index.line_span(0, source).text(source));
}

test "a splice patches the index the way a rebuild would" {
    const source = "one\ntwo\nthree\n";
    const inserted = "a\nb\n";
    var index = try built(source, 16);
    defer index.deinit(std.testing.allocator);

    const plan = index.splice_plan(Span.between(4, 8), inserted).?;

    index.splice_apply(Span.between(4, 8), inserted, &plan);

    var rebuilt = try built(source[0..4] ++ inserted ++ source[8..], 16);
    defer rebuilt.deinit(std.testing.allocator);

    try std.testing.expectEqual(rebuilt.count(), index.count());

    for (0..index.count()) |position| {
        const line: u32 = @intCast(position);

        try std.testing.expectEqual(rebuilt.line_start(line), index.line_start(line));
    }
}

test "a span maps to a range and back" {
    const source = "one\ntwo\nthree";
    var index = try built(source, 64);
    defer index.deinit(std.testing.allocator);

    const range = index.range_of(source, Span.between(4, 7), .utf16);

    try std.testing.expectEqual(LineIndex.Point{ .line = 1, .character = 0 }, range.start);
    try std.testing.expectEqual(LineIndex.Point{ .line = 1, .character = 3 }, range.end);
    try std.testing.expectEqual(Span.between(4, 7), index.span_of(source, range, .utf16));
}

test "a reversed range reads as the span between its ends" {
    const source = "one\ntwo\nthree";
    var index = try built(source, 64);
    defer index.deinit(std.testing.allocator);

    const reversed: LineIndex.Range = .{
        .start = .{ .line = 1, .character = 2 },
        .end = .{ .line = 0, .character = 0 },
    };

    try std.testing.expectEqual(Span.between(0, 6), index.span_of(source, reversed, .utf16));

    const past: LineIndex.Range = .{
        .start = .{ .line = 2, .character = 99 },
        .end = .{ .line = 99, .character = 99 },
    };

    try std.testing.expectEqual(Span.between(13, 13), index.span_of(source, past, .utf16));
}

test "a splice past the reserved lines answers no plan" {
    var index = try built("one\n", 3);
    defer index.deinit(std.testing.allocator);

    try std.testing.expectEqual(null, index.splice_plan(Span.between(0, 0), "a\nb\nc\nd\n"));
}
