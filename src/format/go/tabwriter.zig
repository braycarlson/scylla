const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const Buffer = @import("../../stdx/bounded/buffer.zig");

pub const Tabwriter = struct {
    cells: ArrayType(Cell),
    lines: ArrayType(u32),
    open: ArrayType(u32),
    runs: ArrayType(Run),
    staged: Buffer,

    pub fn init(
        gpa: std.mem.Allocator,
        cell_count_max: u32,
        scratch_bytes_max: u32,
    ) std.mem.Allocator.Error!Tabwriter {
        assert(cell_count_max > 0);
        assert(scratch_bytes_max > 0);

        var cells: ArrayType(Cell) = try .init(gpa, cell_count_max);
        errdefer cells.deinit(gpa);

        var lines: ArrayType(u32) = try .init(gpa, cell_count_max);
        errdefer lines.deinit(gpa);

        var open: ArrayType(u32) = try .init(gpa, cell_count_max);
        errdefer open.deinit(gpa);

        var runs: ArrayType(Run) = try .init(gpa, cell_count_max);
        errdefer runs.deinit(gpa);

        const staged: Buffer = try .init(gpa, scratch_bytes_max);

        assert(cells.capacity() == runs.capacity());
        assert(staged.capacity() == scratch_bytes_max);

        return .{
            .cells = cells,
            .lines = lines,
            .open = open,
            .runs = runs,
            .staged = staged,
        };
    }

    pub fn deinit(tabwriter: *Tabwriter, gpa: std.mem.Allocator) void {
        assert(tabwriter.cells.capacity() == tabwriter.lines.capacity());
        assert(tabwriter.open.capacity() == tabwriter.runs.capacity());

        tabwriter.staged.deinit(gpa);
        tabwriter.runs.deinit(gpa);
        tabwriter.open.deinit(gpa);
        tabwriter.lines.deinit(gpa);
        tabwriter.cells.deinit(gpa);
        tabwriter.* = undefined;
    }

    pub fn write(tabwriter: *Tabwriter, raw: []const u8, out: *Buffer) error{Overflow}!void {
        assert(raw.len < std.math.maxInt(u32));
        assert(tabwriter.lines.capacity() > 0);

        tabwriter.cells.clear();
        tabwriter.lines.clear();
        tabwriter.staged.clear();
        tabwriter.lines.push(0);

        var escaped = false;
        var start: u32 = 0;
        var width: u32 = 0;

        for (raw, 0..) |byte, position| {
            if (escaped) {
                if (byte == escape) {
                    escaped = false;
                } else {
                    width += @intFromBool(leads(byte));
                }

                continue;
            }

            const ended: u32 = @intCast(position);

            switch (byte) {
                escape => escaped = true,
                '\t', 0x0b, '\n', 0x0c => {
                    try tabwriter.cell_pushed(raw, byte, start, ended, width);

                    start = ended + 1;
                    width = 0;
                },
                else => width += @intFromBool(leads(byte)),
            }
        }

        const end: u32 = @intCast(raw.len);

        if (end > start) try tabwriter.cell_push(.{
            .htab = false,
            .run = 0,
            .size = end - start,
            .start = start,
            .width = width,
        });

        try tabwriter.flushed(raw);
        try trimmed(tabwriter.staged.const_slice(), out);

        assert(tabwriter.cells.empty());
        assert(tabwriter.lines.count() == 1);
    }

    fn cell_pushed(
        tabwriter: *Tabwriter,
        raw: []const u8,
        byte: u8,
        start: u32,
        ended: u32,
        width: u32,
    ) error{Overflow}!void {
        assert(start <= ended);
        assert(ended < raw.len);
        assert(width < std.math.maxInt(u32));
        assert(raw[ended] == byte);

        try tabwriter.cell_push(.{
            .htab = byte == '\t',
            .run = 0,
            .size = ended - start,
            .start = start,
            .width = width,
        });

        if (byte != '\n') {
            if (byte != 0x0c) return;
        }

        assert(!tabwriter.lines.empty());

        const line_start = tabwriter.lines.get(tabwriter.lines.count() - 1);
        const cell_count = tabwriter.cells.count() - line_start;

        if (tabwriter.lines.full()) return error.Overflow;

        tabwriter.lines.push(tabwriter.cells.count());

        const flushing = byte == 0x0c or cell_count == 1;

        if (flushing) try tabwriter.flushed(raw);
    }

    fn cell_push(tabwriter: *Tabwriter, cell: Cell) error{Overflow}!void {
        assert(cell.run == 0);
        assert(cell.width <= cell.size);

        if (tabwriter.cells.full()) return error.Overflow;

        tabwriter.cells.push(cell);
    }

    fn flushed(tabwriter: *Tabwriter, raw: []const u8) error{Overflow}!void {
        assert(!tabwriter.lines.empty());
        assert(tabwriter.lines.get(0) <= tabwriter.cells.count());
        assert(raw.len <= std.math.maxInt(u32));

        try tabwriter.flushed_runs();
        try tabwriter.flushed_lines(raw);

        tabwriter.cells.clear();
        tabwriter.lines.clear();
        tabwriter.lines.push(0);

        assert(tabwriter.lines.count() == 1);
    }

    fn flushed_runs(tabwriter: *Tabwriter) error{Overflow}!void {
        tabwriter.runs.clear();
        tabwriter.open.clear();

        const lines = tabwriter.lines.const_slice();
        const line_count = tabwriter.lines.count();

        for (0..line_count) |line| {
            const start = lines[line];
            const end = if (line + 1 < line_count) lines[line + 1] else tabwriter.cells.count();
            const ended = (end - start) -| 1;

            assert(start <= end);

            tabwriter.open.truncate(@min(tabwriter.open.count(), ended));

            for (0..ended) |column| {
                try tabwriter.flushed_column(start, @intCast(column));
            }
        }

        assert(tabwriter.open.count() <= tabwriter.runs.count());
    }

    fn flushed_column(tabwriter: *Tabwriter, start: u32, column: u32) error{Overflow}!void {
        assert(column <= tabwriter.open.count());
        assert(start + column < tabwriter.cells.count());

        if (column >= tabwriter.open.count()) {
            const opened = tabwriter.runs.count();

            if (tabwriter.runs.full()) return error.Overflow;

            tabwriter.runs.push(.{ .discardable = true, .width = 0 });

            if (tabwriter.open.full()) return error.Overflow;

            tabwriter.open.push(opened);
        }

        const run = tabwriter.open.get(column);
        const cell = &tabwriter.cells.slice()[start + column];
        const held = &tabwriter.runs.slice()[run];
        const empty = cell.width == 0 and !cell.htab;

        held.width = @max(held.width, cell.width + padding);
        held.discardable = held.discardable and empty;
        cell.run = run;

        assert(held.width > cell.width);
    }

    fn flushed_lines(tabwriter: *Tabwriter, raw: []const u8) error{Overflow}!void {
        assert(raw.len <= std.math.maxInt(u32));

        const lines = tabwriter.lines.const_slice();
        const line_count = tabwriter.lines.count();

        for (0..line_count) |line| {
            const start = lines[line];
            const last = line + 1 == line_count;
            const end = if (last) tabwriter.cells.count() else lines[line + 1];
            const ended = (end - start) -| 1;
            var tabbed = true;

            assert(start <= end);

            for (0..end - start) |position| {
                const column: u32 = @intCast(position);
                const cell = tabwriter.cells.get(start + column);
                const width = if (column < ended) tabwriter.width_of(cell) else 0;

                if (cell.size == 0) {
                    if (column < ended) try padded(&tabwriter.staged, 0, width, tabbed);

                    continue;
                }

                tabbed = false;

                assert(cell.start + cell.size <= raw.len);

                try tabwriter.staged.push(raw[cell.start..][0..cell.size]);

                if (column < ended) try padded(&tabwriter.staged, cell.width, width, false);
            }

            if (!last) try tabwriter.staged.push("\n");
        }
    }

    fn width_of(tabwriter: *const Tabwriter, cell: Cell) u32 {
        assert(cell.run < tabwriter.runs.count());

        const run = tabwriter.runs.get(cell.run);
        if (run.discardable) return 0;

        assert(run.width > 0);

        return run.width;
    }
};

const Cell = struct {
    htab: bool,
    run: u32,
    size: u32,
    start: u32,
    width: u32,
};

const Run = struct {
    discardable: bool,
    width: u32,
};

pub const escape: u8 = 0xff;
const padding: u32 = 1;
const tab_width: u32 = 8;

comptime {
    assert(padding > 0);
    assert(tab_width > 0);
}

fn leads(byte: u8) bool {
    return byte & 0xc0 != 0x80;
}

fn padded(out: *Buffer, text_width: u32, cell_width: u32, tabbed: bool) error{Overflow}!void {
    assert(text_width < std.math.maxInt(u32));
    assert(cell_width < std.math.maxInt(u32));

    if (!tabbed) {
        var column = text_width;

        while (column < cell_width) : (column += 1) {
            try out.push(" ");
        }

        assert(column >= cell_width);

        return;
    }

    assert(text_width == 0);

    const rounded = ceiling_of(cell_width, tab_width) * tab_width;
    const tab_count = ceiling_of(rounded - text_width, tab_width);

    assert(rounded >= cell_width);

    for (0..tab_count) |_| {
        try out.push("\t");
    }
}

fn ceiling_of(value: u32, divisor: u32) u32 {
    assert(divisor > 0);
    assert(value < std.math.maxInt(u32));

    const quotient = value / divisor;
    const result = quotient + @intFromBool(value % divisor != 0);

    assert(result >= quotient);

    return result;
}

fn blank(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn trimmed(bytes: []const u8, out: *Buffer) error{Overflow}!void {
    assert(bytes.len <= std.math.maxInt(u32));

    out.clear();

    const count = bytes.len;
    var at: usize = 0;

    for (0..count) |_| {
        if (at >= count) break;

        const byte = bytes[at];

        if (byte == escape) {
            const end = std.mem.findScalarPos(u8, bytes, at + 1, escape) orelse count;

            try out.push(bytes[at + 1 .. end]);

            at = end + 1;

            continue;
        }

        var end = at;

        while (end < count) : (end += 1) {
            const held = bytes[end];
            if (blank(held) != blank(byte)) break;
            if (held == escape) break;
        }

        assert(end > at);

        const dropped = blank(byte) and (end == count or bytes[end] == '\n');

        if (!dropped) try out.push(bytes[at..end]);

        at = end;
    }

    assert(at >= count);
}

test "the tabwriter lays out cells as the Rust tabwriter does" {
    const gpa = std.testing.allocator;
    var tabwriter: Tabwriter = try .init(gpa, 256, 1 << 12);
    defer tabwriter.deinit(gpa);

    var out: Buffer = try .init(gpa, 1 << 12);
    defer out.deinit(gpa);

    for (expected_cases) |case| {
        try expect_written(&tabwriter, &out, case);
    }
}

test "the tabwriter refuses a layout that outgrows its cells" {
    const gpa = std.testing.allocator;
    var tabwriter: Tabwriter = try .init(gpa, 2, 64);
    defer tabwriter.deinit(gpa);

    var out: Buffer = try .init(gpa, 64);
    defer out.deinit(gpa);

    const outgrown = tabwriter.write("a\tb\tc\td\n", &out);

    try std.testing.expectError(error.Overflow, outgrown);
    try tabwriter.write("a\n", &out);
    try std.testing.expectEqualStrings("a\n", out.const_slice());
}

test "the tabwriter refuses a layout that outgrows its output" {
    const gpa = std.testing.allocator;
    var tabwriter: Tabwriter = try .init(gpa, 16, 64);
    defer tabwriter.deinit(gpa);

    var out: Buffer = try .init(gpa, 4);
    defer out.deinit(gpa);

    const outgrown = tabwriter.write("abcdef\n", &out);

    try std.testing.expectError(error.Overflow, outgrown);
    try tabwriter.write("abc\n", &out);
    try std.testing.expectEqualStrings("abc\n", out.const_slice());
}

const Expected = struct {
    raw: []const u8,
    written: []const u8,
};

fn expect_written(tabwriter: *Tabwriter, out: *Buffer, case: Expected) !void {
    assert(case.written.len <= case.raw.len + case.raw.len * tab_width);

    try tabwriter.write(case.raw, out);
    try std.testing.expectEqualStrings(case.written, out.const_slice());
}

const expected_cases = [_]Expected{
    .{ .raw = "", .written = "" },
    .{ .raw = "package main\n", .written = "package main\n" },
    .{ .raw = "a\x0bb\nccc\x0bd\n", .written = "a   b\nccc d\n" },
    .{ .raw = "\tx\x0b= 1\n\tlonger\x0b= 2\n", .written = "\tx      = 1\n\tlonger = 2\n" },
    .{
        .raw = "a\x0bb\x0bc\naaa\x0bbbbb\x0bc\n\x0cfoo\x0bbar\n",
        .written = "a   b    c\naaa bbbb c\n\nfoo bar\n",
    },
    .{
        .raw = "x\x0b// comment\nlong_name\x0b// other\n",
        .written = "x         // comment\nlong_name // other\n",
    },
    .{ .raw = "a  \t\nb \n", .written = "a\nb\n" },
    .{ .raw = "s\x0b\xff\"a\tb\"\xff\nlonger\x0b1\n", .written = "s      \"a\tb\"\nlonger 1\n" },
    .{ .raw = "\xc3\xa9\x0b1\nab\x0b2\n", .written = "\xc3\xa9  1\nab 2\n" },
    .{ .raw = "\x0b\x0bx\n\x0b\x0by\n", .written = "x\ny\n" },
    .{ .raw = "a\x0bb", .written = "a b" },
    .{ .raw = "\xffabc", .written = "abc" },
    .{ .raw = "\t\tx\n\t\ty\n", .written = "\t\tx\n\t\ty\n" },
    .{ .raw = "a\tb\tc\n", .written = "a b c\n" },
    .{ .raw = "a\x0b1\n\nbb\x0b2\n", .written = "a 1\n\nbb 2\n" },
    .{ .raw = "a\x0b1\x0cbbbb\x0b2\n", .written = "a 1\nbbbb 2\n" },
    .{
        .raw = "\ta\x0b\x0b// c\n\tbbb\x0bint\x0b// d\n\t\x0b\x0b\n",
        .written = "\ta       // c\n\tbbb int // d\n\n",
    },
    .{ .raw = "x \xff \xff y \n", .written = "x   y\n" },
};
