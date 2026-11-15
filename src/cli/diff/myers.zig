const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const Span = @import("../../stdx/bounded/span.zig");
const StaticAllocator = @import("../../stdx/static_allocator.zig");
const Step = @import("../diff.zig").Step;
const Terminal = @import("../terminal.zig");
const texts_module = @import("texts.zig");
const Texts = texts_module.Texts;
const lines_exact_of = texts_module.lines_exact_of;
const no_newline_note = texts_module.no_newline_note;

after: ArrayType(Span),
backward: []u32,
before: ArrayType(Span),
forward: []u32,
grouped: ArrayType(Op),
groups: ArrayType(Group),
merged: ArrayType(Op),
ops: ArrayType(Op),
stack: ArrayType(Task),
table: []u8,
texts: Texts,

const Myers = @This();
pub const CapacityError = error{LinesExhausted};

pub const Options = struct {
    context_line_count: u32 = context_line_count_default,
};

pub const Tag = enum { delete, equal, insert, replace };

pub const Op = struct {
    index_new: u32,
    index_old: u32,
    length_new: u32,
    length_old: u32,
    tag: Tag,

    fn end_old(op: Op) u32 {
        if (op.tag == .insert) assert(op.length_old == 0);
        if (op.tag == .equal) assert(op.length_old == op.length_new);

        return op.index_old + op.length_old;
    }

    fn end_new(op: Op) u32 {
        if (op.tag == .delete) assert(op.length_new == 0);
        if (op.tag == .equal) assert(op.length_old == op.length_new);

        return op.index_new + op.length_new;
    }

    fn is_empty(op: Op) bool {
        if (op.tag == .equal) assert(op.length_old == op.length_new);
        if (op.tag == .delete) assert(op.length_new == 0);

        if (op.length_old > 0) return false;
        return op.length_new == 0;
    }

    fn lengths_grow(op: *Op, amount: u32) void {
        switch (op.tag) {
            .delete => op.length_old += amount,
            .insert => op.length_new += amount,
            .equal, .replace => {
                op.length_old += amount;
                op.length_new += amount;
            },
        }

        if (op.tag == .equal) assert(op.length_old == op.length_new);
        if (op.tag == .insert) assert(op.length_old == 0);
    }

    fn lengths_shrink(op: *Op, amount: u32) void {
        switch (op.tag) {
            .delete => op.length_old -= amount,
            .insert => op.length_new -= amount,
            .equal, .replace => {
                op.length_old -= amount;
                op.length_new -= amount;
            },
        }

        if (op.tag == .equal) assert(op.length_old == op.length_new);
        if (op.tag == .delete) assert(op.length_new == 0);
    }

    fn shift_left(op: *Op, amount: u32) void {
        assert(amount <= op.index_old);
        assert(amount <= op.index_new);

        op.index_old -= amount;
        op.index_new -= amount;
    }

    fn shift_right(op: *Op, amount: u32) void {
        assert(op.index_old <= std.math.maxInt(u32) - amount);
        assert(op.index_new <= std.math.maxInt(u32) - amount);

        op.index_old += amount;
        op.index_new += amount;
    }
};

pub const Group = struct {
    end: u32,
    first: u32,
};

pub const Ranges = struct {
    end_new: u32,
    end_old: u32,
    start_new: u32,
    start_old: u32,
};

pub const Task = union(enum) {
    conquer: Ranges,
    equal: Op,
};

const Snake = struct {
    new: u32,
    old: u32,
};

const Side = enum { after, before };

const Anchor = struct {
    common: u32,
    skip_new: u32,
    skip_old: u32,
};

const anchor_common_min: u32 = 96;
const anchor_skip_max: u32 = 4;
const small_side_large_min: u32 = 512;
const small_side_max: u32 = 64;
const small_side_work_max: u64 = 64_000_000;
const stack_depth_max: u32 = 1 << 10;
const context_line_count_default: u32 = 3;

pub fn init(gpa: std.mem.Allocator, line_count_max: u32) std.mem.Allocator.Error!Myers {
    assert(line_count_max > 0);

    var myers: Myers = undefined;
    const op_count_max = line_count_max * 4 + 16;

    myers.after = try .init(gpa, line_count_max);
    errdefer myers.after.deinit(gpa);

    myers.before = try .init(gpa, line_count_max);
    errdefer myers.before.deinit(gpa);

    myers.forward = try gpa.alloc(u32, line_count_max * 2 + 4);
    errdefer gpa.free(myers.forward);

    myers.backward = try gpa.alloc(u32, line_count_max * 2 + 4);
    errdefer gpa.free(myers.backward);

    myers.table = try gpa.alloc(u8, (small_side_max + 1) * (line_count_max + 1));
    errdefer gpa.free(myers.table);

    myers.ops = try .init(gpa, op_count_max);
    errdefer myers.ops.deinit(gpa);

    myers.merged = try .init(gpa, op_count_max);
    errdefer myers.merged.deinit(gpa);

    myers.grouped = try .init(gpa, op_count_max * 2);
    errdefer myers.grouped.deinit(gpa);

    myers.groups = try .init(gpa, op_count_max);
    errdefer myers.groups.deinit(gpa);

    myers.stack = try .init(gpa, stack_depth_max);
    myers.texts = .{ .after = "", .before = "" };

    assert(myers.forward.len == myers.backward.len);

    return myers;
}

pub fn deinit(myers: *Myers, gpa: std.mem.Allocator) void {
    assert(myers.forward.len == myers.backward.len);
    assert(myers.merged.count() <= myers.merged.capacity());

    myers.stack.deinit(gpa);
    myers.groups.deinit(gpa);
    myers.grouped.deinit(gpa);
    myers.merged.deinit(gpa);
    myers.ops.deinit(gpa);
    gpa.free(myers.table);
    gpa.free(myers.backward);
    gpa.free(myers.forward);
    myers.before.deinit(gpa);
    myers.after.deinit(gpa);
    myers.* = undefined;
}

pub fn after_at(myers: *const Myers, line_index: u32) []const u8 {
    assert(line_index < myers.after.count());

    const line = myers.after.get(line_index);

    assert(line.end() <= myers.texts.after.len);

    return line.text(myers.texts.after);
}

pub fn before_at(myers: *const Myers, line_index: u32) []const u8 {
    assert(line_index < myers.before.count());

    const line = myers.before.get(line_index);

    assert(line.end() <= myers.texts.before.len);

    return line.text(myers.texts.before);
}

pub fn merged_slice(myers: *const Myers) []const Op {
    assert(myers.merged.count() <= myers.merged.capacity());
    assert(myers.merged.count() <= myers.ops.count());

    return myers.merged.const_slice();
}

pub fn write_unified(
    myers: *Myers,
    out: *Terminal,
    path: []const u8,
    texts: *const Texts,
    options: Options,
) CapacityError!void {
    assert(options.context_line_count > 0);
    assert(path.len <= std.math.maxInt(u32));

    try myers.align_lines(texts);
    myers.groups_build(options.context_line_count);

    if (myers.groups.empty()) return;

    out.push_line("--- {s}\n+++ {s}", .{ path, path });

    for (myers.groups.const_slice()) |group| {
        myers.hunk_write(out, group);
    }

    assert(myers.groups.count() > 0);
}

pub fn align_lines(myers: *Myers, texts: *const Texts) CapacityError!void {
    myers.after.clear();
    myers.before.clear();
    myers.ops.clear();
    myers.merged.clear();
    myers.texts = texts.*;

    try lines_exact_of(texts.before, &myers.before);
    try lines_exact_of(texts.after, &myers.after);

    const count_old = myers.before.count();
    const count_new = myers.after.count();
    const offset = distance_max(count_old, count_new);

    assert(offset * 2 <= myers.forward.len);

    @memset(myers.forward[0 .. offset * 2], 0);
    @memset(myers.backward[0 .. offset * 2], 0);

    myers.conquer_all(.{
        .end_new = count_new,
        .end_old = count_old,
        .start_new = 0,
        .start_old = 0,
    }, offset);

    myers.compact();
    myers.replace_merge();

    assert(myers.merged.count() <= myers.ops.count());
}

fn distance_max(count_old: u32, count_new: u32) u32 {
    assert(count_old < std.math.maxInt(u32));
    assert(count_new < std.math.maxInt(u32));

    const held = @divFloor(count_old + count_new + 1, 2) + 1;

    assert(held > 0);
    assert(held <= count_old + count_new + 1);

    return held;
}

fn conquer_all(myers: *Myers, whole: Ranges, offset: u32) void {
    assert(whole.start_old == 0);
    assert(whole.start_new == 0);
    assert(offset < std.math.maxInt(u32));

    myers.stack.clear();
    myers.stack.push(.{ .conquer = whole });

    const step_max = (whole.end_old + whole.end_new) * 4 + 16;

    for (0..step_max) |_| {
        const task = myers.stack.pop() orelse break;

        switch (task) {
            .equal => |op| myers.emit(op),
            .conquer => |ranges| myers.conquer(ranges, offset),
        }
    } else unreachable;

    assert(myers.stack.empty());
}

fn conquer(myers: *Myers, whole: Ranges, offset: u32) void {
    assert(whole.start_old <= whole.end_old);
    assert(whole.start_new <= whole.end_new);
    assert(offset < std.math.maxInt(u32));

    var ranges = whole;
    const prefix = myers.prefix_length(ranges);

    if (prefix > 0) myers.emit(op_equal(ranges.start_old, ranges.start_new, prefix));

    ranges.start_old += prefix;
    ranges.start_new += prefix;

    const suffix = myers.suffix_length(ranges);

    ranges.end_old -= suffix;
    ranges.end_new -= suffix;

    const tail: Op = .{
        .index_new = ranges.end_new,
        .index_old = ranges.end_old,
        .length_new = suffix,
        .length_old = suffix,
        .tag = .equal,
    };

    myers.anchors_peel(&ranges);

    if (myers.middle_emit(ranges, offset, tail)) return;

    if (suffix > 0) myers.emit(tail);
}

fn middle_emit(myers: *Myers, ranges: Ranges, offset: u32, tail: Op) bool {
    assert(ranges.start_old <= ranges.end_old);
    assert(offset < std.math.maxInt(u32));
    assert(tail.tag == .equal);
    assert(tail.length_old == tail.length_new);

    const length_old = ranges.end_old - ranges.start_old;
    const length_new = ranges.end_new - ranges.start_new;

    assert(ranges.start_new <= ranges.end_new);

    if (length_new == 0) {
        if (length_old > 0) myers.emit(op_delete(ranges.start_old, length_old, ranges.start_new));

        return false;
    }

    if (length_old == 0) {
        myers.emit(op_insert(ranges.start_old, ranges.start_new, length_new));

        return false;
    }

    if (small_exact_fits(length_old, length_new)) {
        myers.small_exact(ranges);

        return false;
    }

    const snake = myers.middle_snake(ranges, offset) orelse {
        myers.emit(op_delete(ranges.start_old, length_old, ranges.start_new));
        myers.emit(op_insert(ranges.start_old, ranges.start_new, length_new));

        return false;
    };

    if (tail.length_old > 0) myers.stack.push(.{ .equal = tail });

    myers.stack.push(.{ .conquer = .{
        .end_new = ranges.end_new,
        .end_old = ranges.end_old,
        .start_new = snake.new,
        .start_old = snake.old,
    } });

    myers.stack.push(.{ .conquer = .{
        .end_new = snake.new,
        .end_old = snake.old,
        .start_new = ranges.start_new,
        .start_old = ranges.start_old,
    } });

    return true;
}

fn anchors_peel(myers: *Myers, ranges: *Ranges) void {
    const step_max = ranges.end_old - ranges.start_old + 1;

    for (0..step_max) |_| {
        if (ranges.start_old >= ranges.end_old) break;
        if (ranges.start_new >= ranges.end_new) break;
        if (!myers.anchor_emit(ranges)) break;
    }

    assert(ranges.start_old <= ranges.end_old);
    assert(ranges.start_new <= ranges.end_new);
}

fn anchor_emit(myers: *Myers, ranges: *Ranges) bool {
    const best = myers.anchor_best(ranges.*) orelse return false;

    assert(best.common >= anchor_common_min);
    assert(best.skip_old == 0 or best.skip_new == 0);

    if (best.skip_new > 0) {
        myers.emit(op_insert(ranges.start_old, ranges.start_new, best.skip_new));
    }

    if (best.skip_old > 0) {
        myers.emit(op_delete(ranges.start_old, best.skip_old, ranges.start_new));
    }

    const at_old = ranges.start_old + best.skip_old;
    const at_new = ranges.start_new + best.skip_new;

    myers.emit(op_equal(at_old, at_new, best.common));

    ranges.start_old = at_old + best.common;
    ranges.start_new = at_new + best.common;

    return true;
}

fn anchor_best(myers: *const Myers, ranges: Ranges) ?Anchor {
    assert(ranges.start_old <= ranges.end_old);
    assert(ranges.start_new <= ranges.end_new);

    const length_old = ranges.end_old - ranges.start_old;
    const length_new = ranges.end_new - ranges.start_new;

    if (length_old <= anchor_common_min) return null;
    if (length_new <= anchor_common_min) return null;
    if (@max(length_old, length_new) < @min(length_old, length_new) *| 2) return null;

    const prefer_insert = length_new > length_old;
    const side_length = if (prefer_insert) length_new else length_old;
    const skip_max = @min(side_length - 1, anchor_skip_max);
    var best: ?Anchor = null;

    assert(length_old != length_new);

    for (1..skip_max + 1) |skip_index| {
        const skip: u32 = @intCast(skip_index);
        const skip_old: u32 = if (prefer_insert) 0 else skip;
        const skip_new: u32 = if (prefer_insert) skip else 0;
        const at_old = ranges.start_old + skip_old;
        const at_new = ranges.start_new + skip_new;

        assert(at_old < ranges.end_old);
        assert(at_new < ranges.end_new);

        if (!myers.line_equal(at_old, at_new)) continue;

        const common = myers.prefix_length(.{
            .end_new = ranges.end_new,
            .end_old = ranges.end_old,
            .start_new = at_new,
            .start_old = at_old,
        });

        if (common < anchor_common_min) continue;

        const candidate: Anchor = .{
            .common = common,
            .skip_new = skip_new,
            .skip_old = skip_old,
        };

        if (common >= anchor_common_min * 8) return candidate;

        if (best) |held| {
            if (anchor_better(candidate, held)) best = candidate;
        } else {
            best = candidate;
        }
    }

    return best;
}

fn anchor_better(candidate: Anchor, held: Anchor) bool {
    assert(candidate.common >= anchor_common_min);
    assert(held.common >= anchor_common_min);

    if (candidate.common != held.common) return candidate.common > held.common;

    const candidate_span = @max(candidate.skip_old, candidate.skip_new);
    const held_span = @max(held.skip_old, held.skip_new);
    if (candidate_span != held_span) return candidate_span < held_span;
    if (candidate.skip_old != held.skip_old) return candidate.skip_old > held.skip_old;
    return candidate.skip_new > held.skip_new;
}

fn small_exact_fits(length_old: u32, length_new: u32) bool {
    assert(length_old < std.math.maxInt(u32));
    assert(length_new < std.math.maxInt(u32));

    const small = @min(length_old, length_new);
    const large = @max(length_old, length_new);
    const work = @as(u64, length_old) * length_new;

    assert(small <= large);

    if (small == 0) return false;
    if (small > small_side_max) return false;
    if (large < small_side_large_min) return false;
    return work <= small_side_work_max;
}

fn small_exact(myers: *Myers, ranges: Ranges) void {
    assert(ranges.start_old <= ranges.end_old);
    assert(ranges.start_new <= ranges.end_new);

    const length_old = ranges.end_old - ranges.start_old;
    const length_new = ranges.end_new - ranges.start_new;
    const rows_old = length_old <= length_new;
    const rows = if (rows_old) length_old else length_new;
    const columns = if (rows_old) length_new else length_old;
    const width = columns + 1;

    assert((rows + 1) * width <= myers.table.len);
    assert(rows <= small_side_max);

    const table = myers.table[0 .. (rows + 1) * width];

    @memset(table, 0);

    for (0..rows) |row_reversed| {
        const row: u32 = rows - 1 - @as(u32, @intCast(row_reversed));

        for (0..columns) |column_reversed| {
            const column: u32 = columns - 1 - @as(u32, @intCast(column_reversed));
            const same = myers.small_same(ranges, rows_old, row, column);

            table[row * width + column] = if (same)
                table[(row + 1) * width + column + 1] + 1
            else
                @max(table[(row + 1) * width + column], table[row * width + column + 1]);
        }
    }

    myers.small_walk(ranges, rows_old, rows, columns);
}

fn small_walk(myers: *Myers, ranges: Ranges, rows_old: bool, rows: u32, columns: u32) void {
    assert(rows <= small_side_max);
    assert((rows + 1) * (columns + 1) <= myers.table.len);
    assert(ranges.start_old <= ranges.end_old);
    assert(ranges.start_new <= ranges.end_new);

    const width = columns + 1;
    var row: u32 = 0;
    var column: u32 = 0;

    for (0..rows + columns + 1) |_| {
        if (row >= rows) break;
        if (column >= columns) break;

        if (myers.small_match(ranges, rows_old, row, column, width)) {
            const row_start = row;
            const column_start = column;

            for (0..rows) |_| {
                if (row >= rows) break;
                if (column >= columns) break;
                if (!myers.small_match(ranges, rows_old, row, column, width)) break;

                row += 1;
                column += 1;
            }

            const length = row - row_start;

            myers.small_emit(ranges, rows_old, .equal, row_start, column_start, length);
        } else if (myers.small_down(row, column, width)) {
            const row_start = row;

            for (0..rows) |_| {
                if (row >= rows) break;
                if (myers.small_match(ranges, rows_old, row, column, width)) break;
                if (!myers.small_down(row, column, width)) break;

                row += 1;
            }

            myers.small_emit(ranges, rows_old, .delete, row_start, column, row - row_start);
        } else {
            const column_start = column;

            for (0..columns) |_| {
                if (column >= columns) break;
                if (myers.small_match(ranges, rows_old, row, column, width)) break;
                if (myers.small_down(row, column, width)) break;

                column += 1;
            }

            const length = column - column_start;

            myers.small_emit(ranges, rows_old, .insert, row, column_start, length);
        }
    }

    if (row < rows) myers.small_emit(ranges, rows_old, .delete, row, column, rows - row);

    if (column < columns) {
        myers.small_emit(ranges, rows_old, .insert, row, column, columns - column);
    }
}

fn small_down(myers: *const Myers, row: u32, column: u32, width: u32) bool {
    assert(column < width);
    assert(row < std.math.maxInt(u32));

    const down = myers.table[(row + 1) * width + column];
    const right = myers.table[row * width + column + 1];

    assert(down <= small_side_max);

    return down >= right;
}

fn small_match(
    myers: *const Myers,
    ranges: Ranges,
    rows_old: bool,
    row: u32,
    column: u32,
    width: u32,
) bool {
    assert(column < width);
    assert(row <= small_side_max);

    if (!myers.small_same(ranges, rows_old, row, column)) return false;

    const here = myers.table[row * width + column];
    const diagonal = myers.table[(row + 1) * width + column + 1];

    return here == diagonal + 1;
}

fn small_same(myers: *const Myers, ranges: Ranges, rows_old: bool, row: u32, column: u32) bool {
    assert(row < std.math.maxInt(u32));
    assert(column < std.math.maxInt(u32));
    assert(ranges.start_old <= ranges.end_old);
    assert(ranges.start_new <= ranges.end_new);

    const at_old = ranges.start_old + if (rows_old) row else column;
    const at_new = ranges.start_new + if (rows_old) column else row;

    assert(at_old < ranges.end_old);
    assert(at_new < ranges.end_new);

    return myers.line_equal(at_old, at_new);
}

fn small_emit(
    myers: *Myers,
    ranges: Ranges,
    rows_old: bool,
    step: Step,
    row: u32,
    column: u32,
    length: u32,
) void {
    assert(length > 0);
    assert(row < std.math.maxInt(u32));
    assert(column < std.math.maxInt(u32));
    assert(ranges.start_old <= ranges.end_old);
    assert(ranges.start_new <= ranges.end_new);
    if (step == .equal) assert(myers.small_same(ranges, rows_old, row, column));

    const at_old = ranges.start_old + if (rows_old) row else column;
    const at_new = ranges.start_new + if (rows_old) column else row;
    const deletes = (step == .delete) == rows_old;

    switch (step) {
        .equal => myers.emit(op_equal(at_old, at_new, length)),
        .delete, .insert => if (deletes)
            myers.emit(op_delete(at_old, length, at_new))
        else
            myers.emit(op_insert(at_old, at_new, length)),
    }

    assert(myers.ops.count() > 0);
}

fn middle_snake(myers: *Myers, ranges: Ranges, offset: u32) ?Snake {
    assert(offset < std.math.maxInt(u32));
    assert(ranges.start_old <= ranges.end_old);
    assert(ranges.start_new <= ranges.end_new);

    const n: i64 = ranges.end_old - ranges.start_old;
    const m: i64 = ranges.end_new - ranges.start_new;
    const delta = n - m;
    const odd = @mod(delta, 2) == 1;
    const d_max: i64 = distance_max(@intCast(n), @intCast(m));

    assert(n > 0);
    assert(m > 0);

    v_set(myers.forward, offset, 1, 0);
    v_set(myers.backward, offset, 1, 0);

    var d: i64 = 0;

    while (d < d_max) : (d += 1) {
        if (myers.snake_forward(ranges, offset, d, odd)) |snake| return snake;
        if (myers.snake_backward(ranges, offset, d, odd)) |snake| return snake;
    }

    return null;
}

fn snake_forward(myers: *Myers, ranges: Ranges, offset: u32, d: i64, odd: bool) ?Snake {
    assert(ranges.start_old < ranges.end_old);
    assert(offset < std.math.maxInt(u32));
    assert(d >= 0);

    const n: i64 = ranges.end_old - ranges.start_old;
    const m: i64 = ranges.end_new - ranges.start_new;
    const delta = n - m;
    var k = d;

    assert(ranges.start_new < ranges.end_new);

    while (k >= -d) : (k -= 2) {
        const plus = k == -d or (k != d and
            v_get(myers.forward, offset, k - 1) < v_get(myers.forward, offset, k + 1));

        var x: i64 = if (plus)
            v_get(myers.forward, offset, k + 1)
        else
            v_get(myers.forward, offset, k - 1) + 1;

        const y = x - k;
        const x_start = x;
        const y_start = y;

        if (inside(x, y, n, m)) x += myers.prefix_length(.{
            .end_new = ranges.end_new,
            .end_old = ranges.end_old,
            .start_new = ranges.start_new + @as(u32, @intCast(y)),
            .start_old = ranges.start_old + @as(u32, @intCast(x)),
        });

        v_set(myers.forward, offset, k, @intCast(x));

        if (!odd) continue;
        if (@abs(k - delta) > d - 1) continue;

        const ahead = v_get(myers.forward, offset, k);
        const reverse = ahead + v_get(myers.backward, offset, delta - k);
        if (reverse < n) continue;
        return snake_of(ranges, x_start, y_start);
    }

    return null;
}

fn snake_backward(myers: *Myers, ranges: Ranges, offset: u32, d: i64, odd: bool) ?Snake {
    assert(ranges.start_old < ranges.end_old);
    assert(offset < std.math.maxInt(u32));
    assert(d >= 0);

    const n: i64 = ranges.end_old - ranges.start_old;
    const m: i64 = ranges.end_new - ranges.start_new;
    const delta = n - m;
    var k = d;

    assert(ranges.start_new < ranges.end_new);

    while (k >= -d) : (k -= 2) {
        const plus = k == -d or (k != d and
            v_get(myers.backward, offset, k - 1) < v_get(myers.backward, offset, k + 1));

        var x: i64 = if (plus)
            v_get(myers.backward, offset, k + 1)
        else
            v_get(myers.backward, offset, k - 1) + 1;

        var y = x - k;

        if (inside(x, y, n, m)) {
            const advance = myers.suffix_length(.{
                .end_new = ranges.start_new + @as(u32, @intCast(m - y)),
                .end_old = ranges.start_old + @as(u32, @intCast(n - x)),
                .start_new = ranges.start_new,
                .start_old = ranges.start_old,
            });

            x += advance;
            y += advance;
        }

        v_set(myers.backward, offset, k, @intCast(x));

        if (odd) continue;
        if (@abs(k - delta) > d) continue;

        const behind = v_get(myers.backward, offset, k);
        const forward = behind + v_get(myers.forward, offset, delta - k);
        if (forward < n) continue;
        return snake_of(ranges, n - x, m - y);
    }

    return null;
}

fn inside(x: i64, y: i64, n: i64, m: i64) bool {
    assert(n > 0);
    assert(m > 0);

    if (x >= n) return false;
    if (y < 0) return false;
    return y < m;
}

fn snake_of(ranges: Ranges, x: i64, y: i64) Snake {
    assert(x >= 0);
    assert(y >= 0);
    assert(ranges.start_old <= ranges.end_old);
    assert(ranges.start_new <= ranges.end_new);

    const old = ranges.start_old + @as(u32, @intCast(x));
    const new = ranges.start_new + @as(u32, @intCast(y));

    assert(old <= ranges.end_old);
    assert(new <= ranges.end_new);

    return .{ .new = new, .old = old };
}

fn v_get(v: []const u32, offset: u32, k: i64) i64 {
    assert(offset < std.math.maxInt(u32));
    assert(k < std.math.maxInt(u32));

    const index = k + offset;

    assert(index >= 0);
    assert(index < v.len);

    return v[@intCast(index)];
}

fn v_set(v: []u32, offset: u32, k: i64, value: u32) void {
    assert(offset < std.math.maxInt(u32));
    assert(k < std.math.maxInt(u32));
    assert(value < std.math.maxInt(u32));

    const index = k + offset;

    assert(index >= 0);
    assert(index < v.len);

    v[@intCast(index)] = value;
}

fn prefix_length(myers: *const Myers, ranges: Ranges) u32 {
    assert(ranges.start_old <= ranges.end_old);

    const length_old = ranges.end_old - ranges.start_old;
    const length_max = @min(length_old, ranges.end_new - ranges.start_new);
    var count: u32 = 0;

    for (0..length_max) |_| {
        if (!myers.line_equal(ranges.start_old + count, ranges.start_new + count)) break;

        count += 1;
    }

    assert(count <= length_max);

    return count;
}

fn suffix_length(myers: *const Myers, ranges: Ranges) u32 {
    assert(ranges.start_new <= ranges.end_new);

    const length_old = ranges.end_old - ranges.start_old;
    const length_max = @min(length_old, ranges.end_new - ranges.start_new);
    var count: u32 = 0;

    for (0..length_max) |_| {
        if (!myers.line_equal(ranges.end_old - count - 1, ranges.end_new - count - 1)) break;

        count += 1;
    }

    assert(count <= length_max);

    return count;
}

fn line_equal(myers: *const Myers, old: u32, new: u32) bool {
    assert(old < myers.before.count());
    assert(new < myers.after.count());

    const left = myers.before.get(old).text(myers.texts.before);
    const right = myers.after.get(new).text(myers.texts.after);

    return std.mem.eql(u8, left, right);
}

fn emit(myers: *Myers, op: Op) void {
    assert(!op.is_empty());
    assert(!myers.ops.full());

    myers.ops.push(op);
}

fn compact(myers: *Myers) void {
    const step_max = myers.ops.count() * 4 + 16;

    inline for (.{ Tag.delete, Tag.insert }) |moving| {
        var pointer: u32 = 0;

        for (0..step_max) |_| {
            if (pointer >= myers.ops.count()) break;

            if (myers.ops.get(pointer).tag == moving) {
                pointer = myers.shift_up(pointer);
                pointer = myers.shift_down(pointer);
            }

            pointer += 1;
        }
    }

    myers.cursors_normalize();

    assert(myers.ops.count() <= myers.ops.capacity());
}

fn shift_up(myers: *Myers, start: u32) u32 {
    assert(start < std.math.maxInt(u32));

    var pointer = start;
    const step_max = myers.after.count() + myers.before.count() + myers.ops.count() + 16;

    assert(pointer < myers.ops.count());

    for (0..step_max) |_| {
        if (pointer == 0) break;

        const this = myers.ops.get(pointer);
        const previous = myers.ops.get(pointer - 1);

        switch (previous.tag) {
            .equal => if (!myers.shift_up_over_equal(&pointer, this, previous)) break,
            .delete, .insert => if (this.tag == previous.tag) {
                myers.ops.slice()[pointer - 1].lengths_grow(this.length_old + this.length_new);
                myers.op_remove(pointer);
                pointer -= 1;
            } else {
                myers.ops_swap(pointer - 1);
                pointer -= 1;
            },
            .replace => unreachable,
        }
    }

    assert(pointer < myers.ops.count());

    return pointer;
}

fn shift_up_over_equal(myers: *Myers, pointer: *u32, this: Op, previous: Op) bool {
    assert(previous.tag == .equal);
    assert(pointer.* > 0);
    assert(std.meta.eql(myers.ops.get(pointer.*), this));

    if (this.tag == .delete) {
        if (pointer.* < 2) return false;
        if (myers.ops.get(pointer.* - 2).tag != .delete) return false;
    }

    const shift = if (this.tag == .insert)
        myers.suffix_length(.{
            .end_new = this.end_new(),
            .end_old = previous.end_old(),
            .start_new = this.index_new,
            .start_old = previous.index_old,
        })
    else
        myers.suffix_length(.{
            .end_new = previous.end_new(),
            .end_old = this.end_old(),
            .start_new = previous.index_new,
            .start_old = this.index_old,
        });

    if (shift > 0) {
        const next = pointer.* + 1;
        const equal_after = next < myers.ops.count() and myers.ops.get(next).tag == .equal;

        if (equal_after) {
            myers.ops.slice()[next].shift_left(shift);
            myers.ops.slice()[next].lengths_grow(shift);
        } else {
            const end_old = if (this.tag == .insert) previous.end_old() else this.end_old();
            const end_new = if (this.tag == .insert) this.end_new() else previous.end_new();

            myers.op_insert_at(next, op_equal(end_old - shift, end_new - shift, shift));
        }

        myers.ops.slice()[pointer.*].shift_left(shift);
        myers.ops.slice()[pointer.* - 1].lengths_shrink(shift);
    }

    if (myers.ops.get(pointer.* - 1).is_empty()) {
        myers.op_remove(pointer.* - 1);
        pointer.* -= 1;

        return true;
    }

    return shift > 0;
}

fn shift_down(myers: *Myers, start: u32) u32 {
    assert(start < std.math.maxInt(u32));

    var pointer = start;
    const step_max = myers.after.count() + myers.before.count() + myers.ops.count() + 16;

    assert(pointer < myers.ops.count());

    for (0..step_max) |_| {
        if (pointer + 1 >= myers.ops.count()) break;

        const this = myers.ops.get(pointer);
        const next = myers.ops.get(pointer + 1);

        switch (next.tag) {
            .equal => if (!myers.shift_down_over_equal(&pointer, this, next)) break,
            .delete, .insert => if (this.tag == next.tag) {
                myers.ops.slice()[pointer].lengths_grow(next.length_old + next.length_new);
                myers.op_remove(pointer + 1);
            } else {
                myers.ops_swap(pointer);
                pointer += 1;
            },
            .replace => unreachable,
        }
    }

    assert(pointer < myers.ops.count());

    return pointer;
}

fn shift_down_over_equal(myers: *Myers, pointer: *u32, this: Op, next: Op) bool {
    assert(next.tag == .equal);
    assert(pointer.* + 1 < myers.ops.count());
    assert(std.meta.eql(myers.ops.get(pointer.*), this));

    if (this.tag == .delete) {
        if (pointer.* + 2 >= myers.ops.count()) return false;
        if (myers.ops.get(pointer.* + 2).tag != .delete) return false;
    }

    const shift = if (this.tag == .insert)
        myers.prefix_length(.{
            .end_new = this.end_new(),
            .end_old = next.end_old(),
            .start_new = this.index_new,
            .start_old = next.index_old,
        })
    else
        myers.prefix_length(.{
            .end_new = next.end_new(),
            .end_old = this.end_old(),
            .start_new = next.index_new,
            .start_old = this.index_old,
        });

    if (shift > 0) {
        const equal_before = pointer.* > 0 and myers.ops.get(pointer.* - 1).tag == .equal;

        if (equal_before) {
            myers.ops.slice()[pointer.* - 1].lengths_grow(shift);
        } else {
            const start_old = if (this.tag == .insert) next.index_old else this.index_old;

            myers.op_insert_at(pointer.*, op_equal(start_old, this.index_new, shift));
            pointer.* += 1;
        }

        myers.ops.slice()[pointer.*].shift_right(shift);
        myers.ops.slice()[pointer.* + 1].shift_right(shift);
        myers.ops.slice()[pointer.* + 1].lengths_shrink(shift);
    }

    if (myers.ops.get(pointer.* + 1).is_empty()) {
        myers.op_remove(pointer.* + 1);

        return true;
    }

    return shift > 0;
}

fn ops_swap(myers: *Myers, left: u32) void {
    assert(left < myers.ops.count());

    const ops = myers.ops.slice();
    const right = left + 1;
    const start_old = ops[left].index_old;
    const end_old = ops[right].end_old();
    const start_new = ops[left].index_new;
    const end_new = ops[right].end_new();

    assert(ops[left].tag != ops[right].tag);
    assert(ops[left].tag != .equal);

    std.mem.swap(Op, &ops[left], &ops[right]);

    if (ops[left].tag == .insert) {
        ops[left].index_old = start_old;
    } else {
        ops[left].index_new = start_new;
    }

    if (ops[right].tag == .insert) {
        ops[right].index_old = end_old;
    } else {
        ops[right].index_new = end_new;
    }
}

fn cursors_normalize(myers: *Myers) void {
    const ops = myers.ops.slice();
    if (ops.len == 0) return;

    var cursor_old = ops[0].index_old;
    var cursor_new = ops[0].index_new;

    for (ops) |*op| {
        switch (op.tag) {
            .equal, .replace => {
                cursor_old = op.end_old();
                cursor_new = op.end_new();
            },
            .delete => {
                op.index_new = cursor_new;
                cursor_old = op.end_old();
            },
            .insert => {
                op.index_old = cursor_old;
                cursor_new = op.end_new();
            },
        }
    }

    assert(cursor_old <= myers.before.count());
    assert(cursor_new <= myers.after.count());
}

fn op_insert_at(myers: *Myers, index: u32, op: Op) void {
    assert(index <= myers.ops.count());
    assert(!myers.ops.full());

    myers.ops.shift_tail(.{ .from = index, .to = index + 1 });
    myers.ops.slice()[index] = op;
}

fn op_remove(myers: *Myers, index: u32) void {
    assert(index < myers.ops.count());

    const count = myers.ops.count();

    myers.ops.shift_tail(.{ .from = index + 1, .to = index });

    assert(myers.ops.count() + 1 == count);
}

fn replace_merge(myers: *Myers) void {
    var pending_equal: ?Op = null;
    var pending_delete: ?Op = null;
    var pending_insert: ?Op = null;

    myers.merged.clear();

    for (myers.ops.const_slice()) |op| {
        switch (op.tag) {
            .equal => {
                myers.changes_flush(&pending_delete, &pending_insert);
                pending_equal = op_merged(pending_equal, op);
            },
            .delete => {
                myers.equal_flush(&pending_equal);
                pending_delete = op_merged(pending_delete, op);
            },
            .insert => {
                myers.equal_flush(&pending_equal);
                pending_insert = op_merged(pending_insert, op);
            },
            .replace => unreachable,
        }
    }

    myers.equal_flush(&pending_equal);
    myers.changes_flush(&pending_delete, &pending_insert);

    assert(myers.merged.count() <= myers.ops.count());
}

fn op_merged(pending: ?Op, op: Op) Op {
    assert(op.tag != .replace);
    if (pending) |merging| assert(merging.tag == op.tag);

    var held = pending orelse return op;

    assert(held.tag == op.tag);

    held.length_old += op.length_old;
    held.length_new += op.length_new;

    return held;
}

fn equal_flush(myers: *Myers, pending_equal: *?Op) void {
    const held = pending_equal.* orelse return;

    assert(held.tag == .equal);
    assert(!myers.merged.full());

    myers.merged.push(held);
    pending_equal.* = null;
}

fn changes_flush(myers: *Myers, pending_delete: *?Op, pending_insert: *?Op) void {
    defer pending_delete.* = null;
    defer pending_insert.* = null;

    if (pending_insert.*) |held| assert(held.tag == .insert);

    const deleted = pending_delete.* orelse {
        if (pending_insert.*) |inserted| myers.merged.push(inserted);

        return;
    };

    assert(deleted.tag == .delete);

    const inserted = pending_insert.* orelse return myers.merged.push(deleted);

    myers.merged.push(.{
        .index_new = inserted.index_new,
        .index_old = deleted.index_old,
        .length_new = inserted.length_new,
        .length_old = deleted.length_old,
        .tag = .replace,
    });
}

fn groups_build(myers: *Myers, context_lines: u32) void {
    assert(context_lines < std.math.maxInt(u32));

    myers.grouped.clear();
    myers.groups.clear();

    const ops = myers.merged.const_slice();
    if (ops.len == 0) return;

    var group_first: u32 = 0;

    for (ops, 0..) |held, index| {
        var op = held;

        if (op.tag == .equal) {
            if (index == 0) {
                const shift = op.length_old -| context_lines;

                op.shift_right(shift);
                op.lengths_shrink(shift);
            }

            if (index + 1 == ops.len) op.lengths_shrink(op.length_old -| context_lines);

            if (op.length_old > context_lines * 2) {
                var head = op;
                var rest = op;

                head.lengths_shrink(op.length_old - context_lines);
                rest.shift_right(op.length_old - context_lines);
                rest.lengths_shrink(op.length_old - context_lines);

                myers.grouped.push(head);
                myers.group_close(group_first);
                group_first = myers.grouped.count();

                myers.grouped.push(rest);

                continue;
            }
        }

        myers.grouped.push(op);
    }

    myers.group_close(group_first);

    assert(myers.groups.count() <= myers.grouped.count());
    assert(myers.grouped.count() >= ops.len);
}

fn group_close(myers: *Myers, first: u32) void {
    const end = myers.grouped.count();

    assert(first <= end);

    if (end == first) return;

    const lone = end - first == 1;

    if (lone) {
        if (myers.grouped.get(first).tag == .equal) return;
    }

    assert(!myers.groups.full());

    myers.groups.push(.{ .end = end, .first = first });
}

fn hunk_write(myers: *const Myers, out: *Terminal, group: Group) void {
    assert(group.first < group.end);

    const ops = myers.grouped.const_slice()[group.first..group.end];
    const first = ops[0];
    const last = ops[ops.len - 1];

    assert(ops.len > 0);

    out.push("@@ -");
    range_write(out, first.index_old, last.end_old());
    out.push(" +");
    range_write(out, first.index_new, last.end_new());
    out.push(" @@\n");

    for (ops) |op| {
        switch (op.tag) {
            .equal => myers.lines_write(out, " ", .before, op.index_old, op.length_old),
            .delete => myers.lines_write(out, "-", .before, op.index_old, op.length_old),
            .insert => myers.lines_write(out, "+", .after, op.index_new, op.length_new),
            .replace => {
                myers.lines_write(out, "-", .before, op.index_old, op.length_old);
                myers.lines_write(out, "+", .after, op.index_new, op.length_new);
            },
        }
    }
}

fn range_write(out: *Terminal, start: u32, end: u32) void {
    assert(start <= end);
    assert(out.capacity() > 0);

    const length = end - start;
    if (length == 1) return out.push_format("{d}", .{start + 1});

    const shown = if (length == 0) start else start + 1;

    out.push_format("{d},{d}", .{ shown, length });
}

fn lines_write(
    myers: *const Myers,
    out: *Terminal,
    marker: []const u8,
    side: Side,
    first: u32,
    count: u32,
) void {
    const text = if (side == .after) myers.texts.after else myers.texts.before;
    const lines = if (side == .after) &myers.after else &myers.before;

    assert(marker.len == 1);
    assert(first + count <= lines.count());

    for (first..first + count) |index| {
        const held = lines.get(@intCast(index)).text(text);
        const last = held[held.len - 1];
        const terminated = last == '\n' or last == '\r';

        out.push(marker);
        out.push(held);

        if (!terminated) {
            out.push("\n");
            out.push(no_newline_note);
        }
    }

    assert(lines.count() <= lines.capacity());
}

fn op_equal(index_old: u32, index_new: u32, length: u32) Op {
    assert(length > 0);
    assert(index_old <= std.math.maxInt(u32) - length);
    assert(index_new < std.math.maxInt(u32));

    return .{
        .index_new = index_new,
        .index_old = index_old,
        .length_new = length,
        .length_old = length,
        .tag = .equal,
    };
}

fn op_delete(index_old: u32, length: u32, index_new: u32) Op {
    assert(length > 0);
    assert(index_old <= std.math.maxInt(u32) - length);
    assert(index_new < std.math.maxInt(u32));

    return .{
        .index_new = index_new,
        .index_old = index_old,
        .length_new = 0,
        .length_old = length,
        .tag = .delete,
    };
}

fn op_insert(index_old: u32, index_new: u32, length: u32) Op {
    assert(length > 0);
    assert(index_new <= std.math.maxInt(u32) - length);
    assert(index_old < std.math.maxInt(u32));

    return .{
        .index_new = index_new,
        .index_old = index_old,
        .length_new = length,
        .length_old = 0,
        .tag = .insert,
    };
}

const test_out_bytes_max: u32 = 1 << 12;

fn test_unified(before: []const u8, after: []const u8, expected: []const u8) !void {
    assert(before.len <= std.math.maxInt(u32));
    assert(after.len <= std.math.maxInt(u32));

    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    const gpa = static_allocator.allocator();
    var myers = try Myers.init(gpa, 1 << 6);
    defer myers.deinit(gpa);

    var out = try Terminal.init(gpa, &.{
        .buffer_bytes_max = test_out_bytes_max,
        .target = .memory,
    });

    defer out.deinit(gpa);

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    try myers.write_unified(&out, "a.txt", &.{ .after = after, .before = before }, .{});

    try std.testing.expectEqualStrings(expected, out.contents());
}

test Myers {
    const gpa = std.testing.allocator;
    var myers: Myers = try .init(gpa, 16);
    defer myers.deinit(gpa);

    try myers.align_lines(&.{ .after = "a\nB\nc\n", .before = "a\nb\nc\n" });

    const ops = myers.merged_slice();

    try std.testing.expectEqual(@as(usize, 3), ops.len);
    try std.testing.expectEqual(Tag.replace, ops[1].tag);
    try std.testing.expectEqualStrings("b\n", myers.before_at(ops[1].index_old));
    try std.testing.expectEqualStrings("B\n", myers.after_at(ops[1].index_new));
}

test "a myers diff notes the missing final newline" {
    try test_unified(
        "a",
        "a\n",
        "--- a.txt\n+++ a.txt\n@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+a\n",
    );

    try test_unified("a\nb\n", "a\nb\n", "");
}

test "a myers diff groups far changes into two hunks" {
    try test_unified(
        "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n",
        "A\nb\nc\nd\ne\nf\ng\nh\ni\nJ\n",
        "--- a.txt\n+++ a.txt\n@@ -1,4 +1,4 @@\n-a\n+A\n b\n c\n d\n" ++
            "@@ -7,4 +7,4 @@\n g\n h\n i\n-j\n+J\n",
    );
}

test "a myers diff refuses a text past its line table" {
    const gpa = std.testing.allocator;
    var myers: Myers = try .init(gpa, 2);
    defer myers.deinit(gpa);

    const refused = myers.align_lines(&.{ .after = "a\n", .before = "a\nb\nc\n" });

    try std.testing.expectError(error.LinesExhausted, refused);
}
