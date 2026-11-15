const std = @import("std");
const assert = std.debug.assert;

pub const Dedent = struct {
    first: u32,
    index: u32,
    indent: usize,
    last: u32,
    lines: std.mem.SplitIterator(u8, .scalar),
    remaining: u32,

    pub fn init(documentation: []const u8) Dedent {
        assert(documentation.len <= std.math.maxInt(u32));

        var lines = std.mem.splitScalar(u8, documentation, '\n');
        var indent: usize = std.math.maxInt(usize);
        var first: u32 = std.math.maxInt(u32);
        var last: u32 = 0;

        for (0..line_count_max) |index| {
            const line = lines.next() orelse break;
            const body = std.mem.trimStart(u8, line, whitespace);

            if (std.mem.trim(u8, line, whitespace).len == 0) continue;

            indent = @min(indent, line.len - body.len);
            first = @min(first, @as(u32, @intCast(index)));
            last = @intCast(index);
        }

        if (first == std.math.maxInt(u32)) indent = 0;

        assert(indent != std.math.maxInt(usize));
        assert(first == std.math.maxInt(u32) or first <= last);

        const remaining = if (first == std.math.maxInt(u32)) 0 else last - first + 1;

        return .{
            .first = first,
            .index = 0,
            .indent = indent,
            .last = last,
            .lines = std.mem.splitScalar(u8, documentation, '\n'),
            .remaining = remaining,
        };
    }

    pub fn next(dedent: *Dedent) ?[]const u8 {
        assert(dedent.remaining <= line_count_max);

        if (dedent.remaining == 0) return null;

        const found = dedent.found_next() orelse return null;

        dedent.remaining -= 1;

        return found;
    }

    fn found_next(dedent: *Dedent) ?[]const u8 {
        for (0..line_count_max) |_| {
            if (dedent.first == std.math.maxInt(u32)) return null;
            if (dedent.index > dedent.last) return null;

            const line = dedent.lines.next() orelse return null;
            const index = dedent.index;

            dedent.index += 1;

            if (index < dedent.first) continue;

            const rest = if (dedent.indent <= line.len) line[dedent.indent..] else "";

            assert(rest.len <= line.len);

            return std.mem.trimEnd(u8, rest, whitespace);
        }

        unreachable;
    }
};

pub const Wrap = struct {
    buffer: *[line_bytes_max]u8,
    dedent: Dedent,
    fenced: bool,
    fold: ?Fold,
    remaining: u32,
    width_columns: u32,

    const Fold = struct {
        first: bool,
        hang: usize,
        lead: usize,
        pending: ?[]const u8,
        words: std.mem.TokenIterator(u8, .any),
    };

    pub fn init(documentation: []const u8, width_columns: u32, buffer: *[line_bytes_max]u8) Wrap {
        assert(width_columns >= width_columns_min);
        assert(documentation.len > 0);
        assert(documentation.len < std.math.maxInt(u32) / 2);

        return .{
            .buffer = buffer,
            .dedent = .init(documentation),
            .fenced = false,
            .fold = null,
            .remaining = @intCast(documentation.len * 2 + 1),
            .width_columns = width_columns,
        };
    }

    pub fn next(wrap: *Wrap) ?[]const u8 {
        if (wrap.remaining == 0) return null;

        const found = wrap.found_next() orelse return null;

        wrap.remaining -= 1;

        return found;
    }

    fn found_next(wrap: *Wrap) ?[]const u8 {
        for (0..line_count_max) |_| {
            if (wrap.fold != null) {
                if (wrap.folded_next()) |line| return line;

                wrap.fold = null;

                continue;
            }

            const line = wrap.dedent.next() orelse return null;

            if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, whitespace), "```")) {
                wrap.fenced = !wrap.fenced;

                return line;
            }

            if (wrap.fenced) return line;
            if (line.len == 0) return line;
            if (line[0] == '#') return line;

            wrap.fold_start(line);
        }

        unreachable;
    }

    fn fold_start(wrap: *Wrap, line: []const u8) void {
        assert(line.len > 0);

        const body = std.mem.trimStart(u8, line, whitespace);
        const lead = line.len - body.len;
        const bulleted = std.mem.startsWith(u8, body, "- ") or std.mem.startsWith(u8, body, "* ");

        wrap.fold = .{
            .first = true,
            .hang = if (bulleted) lead + 2 else lead,
            .lead = lead,
            .pending = null,
            .words = std.mem.tokenizeAny(u8, body, whitespace),
        };

        assert(wrap.fold.?.hang >= lead);
    }

    fn folded_next(wrap: *Wrap) ?[]const u8 {
        const fold = &wrap.fold.?;
        const indent = if (fold.first) fold.lead else fold.hang;

        assert(indent < line_bytes_max);

        @memset(wrap.buffer[0..indent], ' ');

        var length = indent;
        var empty = true;

        for (0..line_count_max) |_| {
            const word = fold.pending orelse fold.words.next() orelse break;

            fold.pending = null;

            if (!empty) {
                if (length + word.len >= wrap.width_columns) {
                    fold.pending = word;
                    fold.first = false;

                    return wrap.buffer[0..length];
                }

                wrap.buffer[length] = ' ';
                length += 1;
            }

            assert(length + word.len <= line_bytes_max);

            @memcpy(wrap.buffer[length..][0..word.len], word);
            length += word.len;
            empty = false;
        }

        fold.first = false;

        if (empty) return null;

        return wrap.buffer[0..length];
    }
};

pub const line_bytes_max: u32 = 1 << 12;
pub const line_count_max: u32 = 1 << 12;
pub const whitespace = " \t\r\n\x0b\x0c";
pub const width_columns_min: u32 = 40;

fn wrapped_test(documentation: []const u8, width_columns: u32) ![]const u8 {
    assert(documentation.len > 0);
    assert(width_columns >= width_columns_min);

    var buffer: [line_bytes_max]u8 = undefined;
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer out.deinit();

    var wrap: Wrap = .init(documentation, width_columns, &buffer);

    for (0..line_count_max) |_| {
        const line = wrap.next() orelse break;

        try out.writer.writeAll(line);
        try out.writer.writeByte('\n');
    }

    return out.toOwnedSlice();
}

test "documentation dedents to its shallowest line and drops the blank edges" {
    var dedent: Dedent = .init("\n    first\n      second  \n\n    third\n\n");
    const first = dedent.next().?;
    const second = dedent.next().?;
    const third = dedent.next().?;
    const fourth = dedent.next().?;
    const fifth = dedent.next();

    try std.testing.expectEqualStrings("first", first);
    try std.testing.expectEqualStrings("  second", second);
    try std.testing.expectEqualStrings("", third);
    try std.testing.expectEqualStrings("third", fourth);
    try std.testing.expectEqual(null, fifth);

    var blank: Dedent = .init("  \n\n");
    const none = blank.next();

    try std.testing.expectEqual(null, none);
}

test "documentation dedents, keeps fences verbatim, and folds prose" {
    const documentation =
        \\
        \\        ## What it does
        \\        Checks for one thing that is long enough to need folding onto a second line.
        \\
        \\        ```html
        \\        <div x-data="{ open: false, close() {}, toggle() {}, extra: true }"></div>
        \\        ```
        \\
        \\        - a bullet whose words run past the width and so hang under the first word
        \\
    ;

    const text = try wrapped_test(documentation, 40);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings(
        \\## What it does
        \\Checks for one thing that is long enough
        \\to need folding onto a second line.
        \\
        \\```html
        \\<div x-data="{ open: false, close() {}, toggle() {}, extra: true }"></div>
        \\```
        \\
        \\- a bullet whose words run past the
        \\  width and so hang under the first word
        \\
    ,
        text,
    );
}
