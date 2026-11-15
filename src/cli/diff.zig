const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Span = @import("../stdx/bounded/span.zig");
const StaticAllocator = @import("../stdx/static_allocator.zig");
const Terminal = @import("terminal.zig");
const scan = @import("../text/scan.zig");
const texts_module = @import("diff/texts.zig");
const lines_exact_of = texts_module.lines_exact_of;
const lines_of = texts_module.lines_of;
const no_newline_note = texts_module.no_newline_note;
const trimmed = texts_module.trimmed;

after: ArrayType(Span),
before: ArrayType(Span),
exact: bool,
lengths: ArrayType(u16),
steps: ArrayType(Step),

const Diff = @This();
pub const CapacityError = error{LinesExhausted};
pub const Myers = @import("diff/myers.zig");

pub const Options = struct {
    context_line_count: u32 = context_line_count_default,
    exact: bool = false,
};

pub const Step = enum {
    delete,
    equal,
    insert,
};

pub const Texts = texts_module.Texts;

const Counts = struct {
    added: u32,
    left: u32,
    removed: u32,
    right: u32,
};

const Middle = struct {
    columns: u32,
    head: u32,
    rows: u32,
};

const context_line_count_default: u32 = 3;
const middle_line_count_max: u32 = 512;
const cell_count_max: u32 = (middle_line_count_max + 1) * (middle_line_count_max + 1);

comptime {
    assert(middle_line_count_max <= std.math.maxInt(u16));
    assert(context_line_count_default > 0);
}

pub fn init(gpa: std.mem.Allocator, line_count_max: u32) std.mem.Allocator.Error!Diff {
    assert(line_count_max > 0);

    const line_count = @max(line_count_max, middle_line_count_max + 1);
    var after: ArrayType(Span) = try .init(gpa, line_count);
    errdefer after.deinit(gpa);

    var before: ArrayType(Span) = try .init(gpa, line_count);
    errdefer before.deinit(gpa);

    var lengths: ArrayType(u16) = try .init(gpa, cell_count_max);
    errdefer lengths.deinit(gpa);

    const steps: ArrayType(Step) = try .init(gpa, line_count * 2);

    assert(steps.capacity() == after.capacity() * 2);

    return .{
        .after = after,
        .before = before,
        .exact = false,
        .lengths = lengths,
        .steps = steps,
    };
}

pub fn deinit(diff: *Diff, gpa: std.mem.Allocator) void {
    assert(diff.steps.capacity() == diff.after.capacity() * 2);
    assert(diff.before.capacity() == diff.after.capacity());

    diff.steps.deinit(gpa);
    diff.lengths.deinit(gpa);
    diff.before.deinit(gpa);
    diff.after.deinit(gpa);
    diff.* = undefined;
}

fn align_lines(diff: *Diff, texts: *const Texts) CapacityError!void {
    diff.after.clear();
    diff.before.clear();
    diff.steps.clear();

    if (diff.exact) {
        try lines_exact_of(texts.before, &diff.before);
        try lines_exact_of(texts.after, &diff.after);
    } else {
        try lines_of(texts.before, &diff.before);
        try lines_of(texts.after, &diff.after);
    }

    const head = diff.common_head(texts);
    const tail = diff.common_tail(texts, head);
    const before_middle = diff.before.count() - head - tail;
    const after_middle = diff.after.count() - head - tail;
    const middle_wide = @max(before_middle, after_middle) > middle_line_count_max;

    diff.push_steps(.equal, head);

    if (middle_wide) {
        diff.push_steps(.delete, before_middle);
        diff.push_steps(.insert, after_middle);
    } else {
        const middle: Middle = .{ .columns = after_middle, .head = head, .rows = before_middle };

        diff.align_middle(texts, middle);
        diff.walk_middle(texts, middle);
    }

    diff.push_steps(.equal, tail);

    assert(diff.steps.count() >= @max(diff.before.count(), diff.after.count()));
    assert(diff.steps.count() <= diff.before.count() + diff.after.count());
}

fn steps_slice(diff: *const Diff) []const Step {
    assert(diff.steps.count() <= diff.steps.capacity());
    assert(diff.steps.count() <= diff.before.count() + diff.after.count());

    return diff.steps.const_slice();
}

pub fn write_unified(
    diff: *Diff,
    out: *Terminal,
    path: []const u8,
    texts: *const Texts,
    options: Options,
) CapacityError!void {
    assert(options.context_line_count > 0);
    assert(!diff.exact);
    assert(path.len <= std.math.maxInt(u32));

    const context_lines = options.context_line_count;

    diff.exact = options.exact;
    defer diff.exact = false;

    try diff.align_lines(texts);

    if (std.mem.findNone(Step, diff.steps.const_slice(), &.{.equal}) == null) return;

    out.push_line("--- {s}\n+++ {s}", .{ path, path });

    const count = diff.steps.count();
    var at: u32 = 0;

    for (0..count) |_| {
        if (at >= count) break;

        const start = diff.next_change(at) orelse break;
        const hunk_start = @max(start -| context_lines, at);
        const hunk_end = diff.write_unified_end(start, context_lines);

        diff.write_hunk(out, texts, hunk_start, hunk_end);

        assert(hunk_end > at);

        at = hunk_end;
    }
}

pub fn write_window(
    diff: *Diff,
    out: *Terminal,
    texts: *const Texts,
    number_first: u32,
) CapacityError!void {
    assert(!diff.exact);
    assert(number_first < std.math.maxInt(u32));

    try diff.align_lines(texts);

    const width: usize = scan.decimal_width(number_first +| diff.after.count());
    var number = number_first;
    var left: u32 = 0;
    var right: u32 = 0;

    write_gutter(out, width);

    for (diff.steps.const_slice()) |step| {
        switch (step) {
            .delete => {
                const text = scan.utf8_or(trimmed(texts.before, diff.before.get(left)), "");

                left += 1;

                write_blank(out, width);
                write_moved(out, "-", text, Terminal.red);
            },
            .equal => {
                const text = scan.utf8_or(trimmed(texts.after, diff.after.get(right)), "");

                left += 1;
                right += 1;

                out.push_line("{[number]d:>[width]} | {[text]s}", .{
                    .number = number,
                    .width = width,
                    .text = text,
                });

                number +|= 1;
            },
            .insert => {
                const text = scan.utf8_or(trimmed(texts.after, diff.after.get(right)), "");

                right += 1;

                out.push_format("{[number]d:>[width]}", .{ .number = number, .width = width });
                write_moved(out, "+", text, Terminal.green);

                number +|= 1;
            },
        }
    }

    write_gutter(out, width);

    assert(left == diff.before.count());
    assert(right == diff.after.count());
}

fn push_steps(diff: *Diff, step: Step, step_count: u32) void {
    assert(step_count <= diff.steps.capacity() - diff.steps.count());

    for (0..step_count) |_| {
        diff.steps.push(step);
    }

    assert(diff.steps.count() <= diff.steps.capacity());
}

fn align_middle(diff: *Diff, texts: *const Texts, middle: Middle) void {
    assert(middle.rows <= middle_line_count_max);
    assert(middle.columns <= middle_line_count_max);

    const width = middle.columns + 1;

    diff.lengths.clear();

    for (0..(middle.rows + 1) * width) |_| {
        diff.lengths.push(0);
    }

    for (0..middle.rows) |row_reversed| {
        const row: u32 = middle.rows - 1 - @as(u32, @intCast(row_reversed));

        for (0..middle.columns) |column_reversed| {
            const column: u32 = middle.columns - 1 - @as(u32, @intCast(column_reversed));
            const same = diff.line_equal(texts, middle.head + row, middle.head + column);
            const value = diff.align_middle_cell(row, column, width, same);

            diff.lengths.slice()[row * width + column] = value;
        }
    }

    assert(diff.lengths.count() == (middle.rows + 1) * width);
}

fn align_middle_cell(diff: *const Diff, row: u32, column: u32, width: u32, same: bool) u16 {
    assert(column < width);
    assert(row < std.math.maxInt(u32));

    if (same) {
        const returned = diff.cell_at(row + 1, column + 1, width) + 1;

        assert(returned < std.math.maxInt(u16));

        return returned;
    }

    const down = diff.cell_at(row + 1, column, width);
    const right = diff.cell_at(row, column + 1, width);
    const value = @max(down, right);

    assert(value <= middle_line_count_max);

    return value;
}

fn walk_middle(diff: *Diff, texts: *const Texts, middle: Middle) void {
    assert(middle.rows <= middle_line_count_max);
    assert(middle.columns <= middle_line_count_max);

    const width = middle.columns + 1;
    var at_row: u32 = 0;
    var at_column: u32 = 0;

    for (0..middle.rows + middle.columns) |_| {
        const row_open = at_row < middle.rows;
        const column_open = at_column < middle.columns;
        const done = !row_open and !column_open;
        if (done) break;

        const both_open = row_open and column_open;

        const same = both_open and
            diff.line_equal(texts, middle.head + at_row, middle.head + at_column);

        if (same) {
            diff.steps.push(.equal);
            at_row += 1;
            at_column += 1;

            continue;
        }

        const down: u16 = if (row_open) diff.cell_at(at_row + 1, at_column, width) else 0;
        const right: u16 = if (column_open) diff.cell_at(at_row, at_column + 1, width) else 0;
        const delete = row_open and (!column_open or down >= right);

        if (delete) {
            diff.steps.push(.delete);
            at_row += 1;
        } else {
            diff.steps.push(.insert);
            at_column += 1;
        }
    }

    assert(at_row == middle.rows);
    assert(at_column == middle.columns);
}

fn common_head(diff: *const Diff, texts: *const Texts) u32 {
    const line_count = @min(diff.before.count(), diff.after.count());
    var count: u32 = 0;

    for (0..line_count) |_| {
        if (!diff.line_equal(texts, count, count)) break;

        count += 1;
    }

    assert(count <= diff.before.count());
    assert(count <= diff.after.count());

    return count;
}

fn common_tail(diff: *const Diff, texts: *const Texts, head: u32) u32 {
    assert(head <= diff.before.count());
    assert(head <= diff.after.count());

    const line_count = @min(diff.before.count(), diff.after.count()) - head;
    var count: u32 = 0;

    for (0..line_count) |_| {
        const left = diff.before.count() - count - 1;
        const right = diff.after.count() - count - 1;
        if (!diff.line_equal(texts, left, right)) break;

        count += 1;
    }

    assert(head + count <= diff.before.count());
    assert(head + count <= diff.after.count());

    return count;
}

fn cell_at(diff: *const Diff, row: u32, column: u32, width: u32) u16 {
    assert(column < width);
    assert(row < std.math.maxInt(u32));

    const index = row * width + column;

    assert(index < diff.lengths.count());

    return diff.lengths.get(index);
}

fn line_equal(diff: *const Diff, texts: *const Texts, left: u32, right: u32) bool {
    assert(left < diff.before.count());
    assert(right < diff.after.count());

    if (diff.exact) {
        const whole_left = diff.before.get(left).text(texts.before);
        const whole_right = diff.after.get(right).text(texts.after);

        return std.mem.eql(u8, whole_left, whole_right);
    }

    const held_left = trimmed(texts.before, diff.before.get(left));
    const held_right = trimmed(texts.after, diff.after.get(right));

    return std.mem.eql(u8, held_left, held_right);
}

fn change_end(diff: *const Diff, from: u32) u32 {
    assert(from <= diff.steps.count());

    const steps = diff.steps.const_slice();
    var at = from;

    for (steps[from..]) |step| {
        if (step == .equal) break;

        at += 1;
    }

    assert(at <= steps.len);

    return at;
}

fn next_change(diff: *const Diff, from: u32) ?u32 {
    assert(from <= diff.steps.count());

    const found = std.mem.findNonePos(Step, diff.steps.const_slice(), from, &.{.equal});

    if (found) |at| assert(at >= from);

    return if (found) |at| @intCast(at) else null;
}

fn write_unified_end(diff: *const Diff, start: u32, context_lines: u32) u32 {
    assert(context_lines < std.math.maxInt(u32));

    const count = diff.steps.count();

    assert(start < count);

    var hunk_end = start;

    for (0..count) |_| {
        const padded = @min(hunk_end +| context_lines, count);

        const next = diff.next_change(hunk_end) orelse {
            hunk_end = padded;

            break;
        };

        if (next - hunk_end > context_lines *| 2) {
            hunk_end = padded;

            break;
        }

        hunk_end = diff.change_end(next);
    }

    assert(hunk_end > start);
    assert(hunk_end <= count);

    return hunk_end;
}

fn write_hunk(diff: *const Diff, out: *Terminal, texts: *const Texts, start: u32, end: u32) void {
    assert(start <= end);
    assert(end <= diff.steps.count());

    const counts = diff.write_hunk_counts(start, end);

    out.push("@@ -");
    write_range(out, counts.left, counts.removed);
    out.push(" +");
    write_range(out, counts.right, counts.added);
    out.push(" @@\n");

    var at_left = counts.left;
    var at_right = counts.right;

    for (diff.steps.const_slice()[start..end]) |step| {
        switch (step) {
            .delete => {
                diff.write_line_of(out, "-", texts.before, diff.before.get(at_left));
                at_left += 1;
            },
            .insert => {
                diff.write_line_of(out, "+", texts.after, diff.after.get(at_right));
                at_right += 1;
            },
            .equal => {
                diff.write_line_of(out, " ", texts.after, diff.after.get(at_right));
                at_left += 1;
                at_right += 1;
            },
        }
    }

    assert(at_left == counts.left + counts.removed);
    assert(at_right == counts.right + counts.added);
}

fn write_hunk_counts(diff: *const Diff, start: u32, end: u32) Counts {
    assert(start <= end);

    var counts: Counts = .{ .added = 0, .left = 0, .removed = 0, .right = 0 };

    for (diff.steps.const_slice()[0..start]) |step| {
        if (step != .insert) counts.left += 1;
        if (step != .delete) counts.right += 1;
    }

    for (diff.steps.const_slice()[start..end]) |step| {
        if (step != .insert) counts.removed += 1;
        if (step != .delete) counts.added += 1;
    }

    assert(counts.left + counts.removed <= diff.before.count());
    assert(counts.right + counts.added <= diff.after.count());

    return counts;
}

fn write_line_of(
    diff: *const Diff,
    out: *Terminal,
    marker: []const u8,
    text: []const u8,
    line: Span,
) void {
    assert(marker.len == 1);
    assert(text.len <= std.math.maxInt(u32));
    assert(line.end() <= text.len);

    if (!diff.exact) return write_line(out, marker, text, line);

    const held = line.text(text);

    assert(held.len > 0);

    out.push(marker);
    out.push(held);

    const last = held[held.len - 1];
    const terminated = last == '\n' or last == '\r';

    if (!terminated) {
        out.push("\n");
        out.push(no_newline_note);
    }
}

fn write_blank(out: *Terminal, width: usize) void {
    assert(width > 0);
    assert(width <= scan.decimal_bytes_max);

    for (0..width) |_| {
        out.push(" ");
    }
}

fn write_gutter(out: *Terminal, width: usize) void {
    assert(width > 0);
    assert(width <= scan.decimal_bytes_max);

    write_blank(out, width);
    out.push(" |\n");
}

fn write_line(out: *Terminal, marker: []const u8, text: []const u8, line: Span) void {
    assert(marker.len == 1);
    assert(line.end() <= text.len);

    const held = line.text(text);

    out.push(marker);
    out.push(scan.utf8_or(trimmed(text, line), ""));
    out.push("\n");

    if (!std.mem.endsWith(u8, held, "\n")) out.push(no_newline_note);
}

fn write_moved(out: *Terminal, marker: []const u8, text: []const u8, ink: []const u8) void {
    assert(marker.len == 1);
    assert(ink.len > 0);
    assert(text.len <= std.math.maxInt(u32));

    out.push(" ");
    out.painted(marker, &.{ink});
    out.push(" ");
    out.painted(text, &.{ink});
    out.push("\n");
}

fn write_range(out: *Terminal, start: u32, count: u32) void {
    assert(start < std.math.maxInt(u32));
    assert(count < std.math.maxInt(u32));

    const shown = if (count == 0) start else start + 1;

    assert(shown >= start);

    if (count == 1) {
        out.push_format("{d}", .{shown});
    } else {
        out.push_format("{d},{d}", .{ shown, count });
    }
}

const test_out_bytes_max: u32 = 1 << 12;
const test_text_bytes_max: u32 = 1 << 13;

fn test_memory(gpa: std.mem.Allocator, buffer_bytes_max: u32) !Terminal {
    assert(buffer_bytes_max < std.math.maxInt(u32));

    return Terminal.init(gpa, &.{ .buffer_bytes_max = buffer_bytes_max, .target = .memory });
}

fn test_steps(before: []const u8, after: []const u8, expected: []const Step) !void {
    assert(before.len <= std.math.maxInt(u32));
    assert(after.len <= std.math.maxInt(u32));

    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    const gpa = static_allocator.allocator();
    var diff = try Diff.init(gpa, 1 << 6);
    defer diff.deinit(gpa);

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    try diff.align_lines(&.{ .after = after, .before = before });

    try std.testing.expectEqualSlices(Step, expected, diff.steps_slice());
}

fn test_unified(
    before: []const u8,
    after: []const u8,
    options: Options,
    expected: []const u8,
) !void {
    assert(before.len <= std.math.maxInt(u32));
    assert(after.len <= std.math.maxInt(u32));
    assert(options.context_line_count < std.math.maxInt(u32));

    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    const gpa = static_allocator.allocator();
    var diff = try Diff.init(gpa, 1 << 6);
    defer diff.deinit(gpa);

    var out = try test_memory(gpa, test_out_bytes_max);
    defer out.deinit(gpa);

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    try diff.write_unified(&out, "a.txt", &.{ .after = after, .before = before }, options);

    try std.testing.expectEqualStrings(expected, out.contents());
    try std.testing.expect(!diff.exact);
}

fn test_texts_fill(before: []u8, after: []u8, count: u32) ![2][]const u8 {
    assert(before.len == after.len);
    assert(count < std.math.maxInt(u32));

    var before_length: usize = 0;
    var after_length: usize = 0;

    for (0..count) |index| {
        const before_line = try std.mem.print(before[before_length..], "x{d}\n", .{index});
        const after_line = try std.mem.print(after[after_length..], "y{d}\n", .{index});

        before_length += before_line.len;
        after_length += after_line.len;
    }

    assert(before_length <= before.len);

    return .{ before[0..before_length], after[0..after_length] };
}

fn test_lines_marked(patch: []const u8, comptime mark: u8, comptime header: []const u8) u32 {
    assert(header.len == 3);
    assert(patch.len <= std.math.maxInt(u32));
    comptime assert(mark == '+' or mark == '-');

    var marked: u32 = 0;
    var lines = std.mem.splitScalar(u8, patch, '\n');

    for (0..patch.len + 1) |_| {
        const line = lines.next() orelse break;
        if (!std.mem.startsWith(u8, line, &.{mark})) continue;
        if (std.mem.startsWith(u8, line, header)) continue;

        marked += 1;
    }

    assert(marked <= patch.len);

    return marked;
}

test Diff {
    const gpa = std.testing.allocator;
    var diff: Diff = try .init(gpa, 16);
    defer diff.deinit(gpa);

    var out: Terminal = try .init(gpa, &.{ .buffer_bytes_max = 256, .target = .memory });
    defer out.deinit(gpa);

    const texts: Texts = .{ .after = "a\nB\nc\n", .before = "a\nb\nc\n" };

    try diff.write_unified(&out, "page.html", &texts, .{});

    try std.testing.expectEqualStrings(
        "--- page.html\n+++ page.html\n@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n",
        out.contents(),
    );
}

test "an identical text aligns as equal steps" {
    try test_steps("a\nb\n", "a\nb\n", &.{ .equal, .equal });
}

test "a replaced line aligns as a delete then an insert" {
    try test_steps("a\nb\nc\n", "a\nB\nc\n", &.{ .equal, .delete, .insert, .equal });
}

test "a line moved past another keeps the longest common run" {
    try test_steps("a\nb\nc\nd\n", "b\nc\nd\na\n", &.{ .delete, .equal, .equal, .equal, .insert });
}

test "the alignment keeps the longest common run" {
    const moved: []const Step = &.{ .delete, .equal, .equal, .equal, .insert };

    try test_steps("a\nb\nc\nd\n", "b\nc\nd\na\n", moved);
    try test_steps("", "a\n", &.{.insert});
    try test_steps("a\n", "", &.{.delete});
    try test_steps("", "", &.{});
}

test "a missing final newline is noted on both sides" {
    try test_unified(
        "a",
        "b",
        .{},
        "--- a.txt\n+++ a.txt\n@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+b\n" ++
            "\\ No newline at end of file\n",
    );
}

test "carriage returns do not make two lines differ" {
    try test_unified("a\r\nb\r\n", "a\nb\n", .{}, "");
}

test "an exact diff keeps each line terminator it compares" {
    try test_unified(
        "a",
        "a\n",
        .{ .exact = true },
        "--- a.txt\n+++ a.txt\n@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+a\n",
    );

    try test_unified(
        "a\r\nb\n",
        "a\nb\n",
        .{ .exact = true },
        "--- a.txt\n+++ a.txt\n@@ -1,2 +1,2 @@\n-a\r\n+a\n b\n",
    );

    try test_unified("a\rb\n", "a\rb\n", .{ .exact = true }, "");
}

test "a middle past the table is one removal and one insertion" {
    const gpa = std.testing.allocator;
    const count = middle_line_count_max + 88;
    var before_bytes: [test_text_bytes_max]u8 = undefined;
    var after_bytes: [test_text_bytes_max]u8 = undefined;
    const texts = try test_texts_fill(&before_bytes, &after_bytes, count);
    var diff = try Diff.init(gpa, 1 << 10);
    defer diff.deinit(gpa);

    var out = try test_memory(gpa, 1 << 16);
    defer out.deinit(gpa);

    try diff.write_unified(&out, "page.html", &.{ .after = texts[1], .before = texts[0] }, .{});

    const text = out.contents();
    var header_bytes: [64]u8 = undefined;
    const header = try std.mem.print(&header_bytes, "@@ -1,{d} +1,{d} @@", .{ count, count });
    const removed_last = std.mem.findLast(u8, text, "\n-x").?;
    const added_first = std.mem.find(u8, text, "\n+y").?;

    try std.testing.expect(!out.is_truncated());
    try std.testing.expect(std.mem.find(u8, text, header) != null);
    try std.testing.expectEqual(count, test_lines_marked(text, '-', "---"));
    try std.testing.expectEqual(count, test_lines_marked(text, '+', "+++"));
    try std.testing.expect(removed_last < added_first);
}

test "a text past the line table is refused" {
    const gpa = std.testing.allocator;
    const count = middle_line_count_max + 2;
    var before_bytes: [test_text_bytes_max]u8 = undefined;
    var after_bytes: [test_text_bytes_max]u8 = undefined;
    const texts = try test_texts_fill(&before_bytes, &after_bytes, count);
    const held: Texts = .{ .after = texts[1], .before = texts[0] };
    var diff = try Diff.init(gpa, 2);
    defer diff.deinit(gpa);

    var out = try test_memory(gpa, test_out_bytes_max);
    defer out.deinit(gpa);

    try std.testing.expectError(error.LinesExhausted, diff.write_unified(&out, "a", &held, .{}));
    try std.testing.expectError(error.LinesExhausted, diff.write_window(&out, &held, 1));
    try std.testing.expect(out.empty());
}
