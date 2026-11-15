const std = @import("std");
const assert = std.debug.assert;

const MedianFrame = struct {
    child: u32,
    eighth: u32,
    positions: [3]u32,
    results: [3]u32,
};

const Order = enum { less, less_or_equal };

const Part = struct {
    ancestor: bool,
    limit: u32,
    start: u32,
    stop: u32,
};

const Run = struct {
    length: u32,
    reversed: bool,
};

const Small = enum { fallback, general, network };
const heap_sift_depth_max: u32 = 64;
const insertion_count_max: u32 = 20;
const median_depth_max: u32 = 12;
const median_nested_count_min: u32 = 64;
const median_step_max: u32 = 1 << 19;
const network_merge_count_min: u32 = 18;
const partition_branchless_bytes_max: u32 = 96;
const quicksort_limit_max: u32 = 2 * 32;
const quicksort_part_count_max: u32 = quicksort_limit_max + 2;
const small_fallback_count_max: u32 = 16;
const small_general_count_max: u32 = 32;
const small_general_scratch_count: u32 = small_general_count_max + 16;
const small_network_count_max: u32 = 32;
const small_network_scratch_count: u32 = small_network_count_max;
const stack_array_bytes_max: u32 = 4096;
const swap_efficient_bytes_max: u32 = 8;

const network_9 = [_][2]u8{
    .{ 0, 3 },
    .{ 1, 7 },
    .{ 2, 5 },
    .{ 4, 8 },
    .{ 0, 7 },
    .{ 2, 4 },
    .{ 3, 8 },
    .{ 5, 6 },
    .{ 0, 2 },
    .{ 1, 3 },
    .{ 4, 5 },
    .{ 7, 8 },
    .{ 1, 4 },
    .{ 3, 6 },
    .{ 5, 7 },
    .{ 0, 1 },
    .{ 2, 4 },
    .{ 3, 5 },
    .{ 6, 8 },
    .{ 2, 3 },
    .{ 4, 5 },
    .{ 6, 7 },
    .{ 1, 2 },
    .{ 3, 4 },
    .{ 5, 6 },
};

const network_13 = [_][2]u8{
    .{ 0, 12 },
    .{ 1, 10 },
    .{ 2, 9 },
    .{ 3, 7 },
    .{ 5, 11 },
    .{ 6, 8 },
    .{ 1, 6 },
    .{ 2, 3 },
    .{ 4, 11 },
    .{ 7, 9 },
    .{ 8, 10 },
    .{ 0, 4 },
    .{ 1, 2 },
    .{ 3, 6 },
    .{ 7, 8 },
    .{ 9, 10 },
    .{ 11, 12 },
    .{ 4, 6 },
    .{ 5, 9 },
    .{ 8, 11 },
    .{ 10, 12 },
    .{ 0, 5 },
    .{ 3, 8 },
    .{ 4, 7 },
    .{ 6, 11 },
    .{ 9, 10 },
    .{ 0, 1 },
    .{ 2, 5 },
    .{ 6, 9 },
    .{ 7, 8 },
    .{ 10, 11 },
    .{ 1, 3 },
    .{ 2, 4 },
    .{ 5, 6 },
    .{ 9, 10 },
    .{ 1, 2 },
    .{ 3, 4 },
    .{ 5, 7 },
    .{ 6, 8 },
    .{ 2, 3 },
    .{ 4, 5 },
    .{ 6, 7 },
    .{ 8, 9 },
    .{ 3, 4 },
    .{ 5, 6 },
};

pub fn unstable(
    comptime T: type,
    items: []T,
    comptime Context: type,
    context: Context,
    comptime less: fn (Context, T, T) bool,
) void {
    const Sorter = SorterType(T, Context, less);
    const sorter: Sorter = .{ .context = context };

    assert(items.len <= std.math.maxInt(u32));

    sorter.sort(items);

    if (items.len < 2) return;

    for (items[1..], 0..) |item, index| assert(!less(sorter.context, item, items[index]));
}

fn SorterType(
    comptime T: type,
    comptime Context: type,
    comptime less: fn (Context, T, T) bool,
) type {
    comptime assert(@sizeOf(T) > 0);
    comptime assert(@sizeOf(T) <= partition_branchless_bytes_max);

    return struct {
        context: Context,

        const Sorter = @This();
        const small: Small = small_of(T);

        const small_count_max: u32 = switch (small) {
            .fallback => small_fallback_count_max,
            .general => small_general_count_max,
            .network => small_network_count_max,
        };

        fn sort(sorter: *const Sorter, items: []T) void {
            assert(items.len <= std.math.maxInt(u32));

            if (items.len < 2) return;

            if (items.len <= insertion_count_max) {
                sorter.insertion(items, 1);

                return;
            }

            const run = sorter.run_of(items);

            if (run.length == items.len) {
                if (run.reversed) std.mem.reverse(T, items);

                return;
            }

            const limit: u32 = 2 * @as(u32, std.math.log2_int(usize, items.len | 1));

            assert(limit <= quicksort_limit_max);

            sorter.quicksort(items, limit);
        }

        fn run_of(sorter: *const Sorter, items: []const T) Run {
            assert(items.len >= 2);

            const reversed = less(sorter.context, items[1], items[0]);
            var length: u32 = 2;

            for (items[2..], 2..) |item, position| {
                const descends = less(sorter.context, item, items[position - 1]);
                if (descends != reversed) break;

                length += 1;
            }

            assert(length <= items.len);

            return .{ .length = length, .reversed = reversed };
        }

        fn quicksort(sorter: *const Sorter, items: []T, limit: u32) void {
            var parts: [quicksort_part_count_max]Part = undefined;
            var part_count: u32 = 1;

            assert(limit <= quicksort_limit_max);
            assert(items.len > insertion_count_max);

            parts[0] = .{
                .ancestor = false,
                .limit = limit,
                .start = 0,
                .stop = @intCast(items.len),
            };

            for (0..2 * items.len + 1) |_| {
                if (part_count == 0) break;

                part_count -= 1;

                const part = parts[part_count];
                var children: [2]Part = undefined;
                const child_count = sorter.quicksort_step(items, &part, &children);

                assert(part_count + child_count <= quicksort_part_count_max);

                for (children[0..child_count]) |child| {
                    parts[part_count] = child;
                    part_count += 1;
                }
            }

            assert(part_count == 0);
        }

        fn quicksort_step(
            sorter: *const Sorter,
            items: []T,
            part: *const Part,
            children: *[2]Part,
        ) u32 {
            assert(part.start <= part.stop);
            if (part.ancestor) assert(part.start > 0);
            assert(items.len <= std.math.maxInt(u32));

            const held = items[part.start..part.stop];

            if (held.len <= small_count_max) {
                sorter.small_sort(held);

                return 0;
            }

            if (part.limit == 0) {
                sorter.heapsort(held);

                return 0;
            }

            const limit = part.limit - 1;
            const pivot = sorter.pivot_of(held);

            if (part.ancestor) {
                if (!less(sorter.context, items[part.start - 1], held[pivot])) {
                    const equal_count = sorter.partition(held, pivot, .less_or_equal);

                    children[0] = .{
                        .ancestor = false,
                        .limit = limit,
                        .start = part.start + equal_count + 1,
                        .stop = part.stop,
                    };

                    return 1;
                }
            }

            const less_count = sorter.partition(held, pivot, .less);

            children[0] = .{
                .ancestor = true,
                .limit = limit,
                .start = part.start + less_count + 1,
                .stop = part.stop,
            };

            children[1] = .{
                .ancestor = part.ancestor,
                .limit = limit,
                .start = part.start,
                .stop = part.start + less_count,
            };

            return 2;
        }

        fn partition(sorter: *const Sorter, items: []T, pivot: u32, comptime order: Order) u32 {
            assert(pivot < items.len);
            assert(items.len > small_count_max);

            std.mem.swap(T, &items[0], &items[pivot]);

            const held = items[0];
            const rest = items[1..];
            const gap_item = rest[0];
            var gap: usize = 0;
            var count: usize = 0;

            for (1..rest.len) |right| {
                const moved = rest[right];
                const below = sorter.ordered(moved, held, order);

                rest[gap] = rest[count];
                rest[count] = moved;
                gap = right;
                count += @intFromBool(below);
            }

            const below = sorter.ordered(gap_item, held, order);

            rest[gap] = rest[count];
            rest[count] = gap_item;
            count += @intFromBool(below);

            assert(count < items.len);

            std.mem.swap(T, &items[0], &items[count]);

            assert(count <= items.len);

            return @intCast(count);
        }

        fn ordered(sorter: *const Sorter, item: T, pivot: T, comptime order: Order) bool {
            assert(!less(sorter.context, item, item));
            assert(!less(sorter.context, pivot, pivot));

            const result = switch (order) {
                .less => less(sorter.context, item, pivot),
                .less_or_equal => !less(sorter.context, pivot, item),
            };

            if (order == .less) assert(!result or !less(sorter.context, pivot, item));

            return result;
        }

        fn pivot_of(sorter: *const Sorter, items: []const T) u32 {
            assert(items.len >= 8);

            const eighth: u32 = @intCast(items.len / 8);
            const positions: [3]u32 = .{ 0, eighth * 4, eighth * 7 };

            assert(positions[2] < items.len);

            if (items.len < median_nested_count_min) return sorter.median_of(items, positions);
            return sorter.median_nested_of(items, positions, eighth);
        }

        fn median_of(sorter: *const Sorter, items: []const T, positions: [3]u32) u32 {
            assert(positions[0] < items.len);
            assert(positions[1] < items.len);
            assert(positions[2] < items.len);

            const a = positions[0];
            const b = positions[1];
            const c = positions[2];

            assert(a < items.len);
            assert(b < items.len);
            assert(c < items.len);

            const x = less(sorter.context, items[a], items[b]);
            const y = less(sorter.context, items[a], items[c]);
            if (x != y) return a;

            const z = less(sorter.context, items[b], items[c]);
            return if (z != x) c else b;
        }

        fn median_nested_of(
            sorter: *const Sorter,
            items: []const T,
            positions: [3]u32,
            eighth: u32,
        ) u32 {
            assert(positions[0] < items.len);
            assert(positions[1] < items.len);
            assert(positions[2] < items.len);

            var frames: [median_depth_max]MedianFrame = undefined;
            var depth: u32 = 1;

            assert(eighth * 8 <= items.len);
            assert(eighth >= 8);

            frames[0] = .{
                .child = 0,
                .eighth = eighth,
                .positions = positions,
                .results = undefined,
            };

            for (0..median_step_max) |_| {
                const frame = &frames[depth - 1];
                const nested = frame.eighth >= 8;

                if (nested) {
                    if (frame.child < 3) {
                        const base = frame.positions[frame.child];
                        const inner = frame.eighth / 8;

                        assert(depth < median_depth_max);

                        frames[depth] = .{
                            .child = 0,
                            .eighth = inner,
                            .positions = .{ base, base + inner * 4, base + inner * 7 },
                            .results = undefined,
                        };

                        depth += 1;

                        continue;
                    }
                }

                const candidates = if (nested) frame.results else frame.positions;
                const median = sorter.median_of(items, candidates);

                depth -= 1;

                if (depth == 0) return median;

                const parent = &frames[depth - 1];

                assert(parent.child < 3);

                parent.results[parent.child] = median;
                parent.child += 1;
            }

            unreachable;
        }

        fn heapsort(sorter: *const Sorter, items: []T) void {
            assert(items.len > small_count_max);

            const total = items.len + items.len / 2;
            var index = total;

            for (0..total) |_| {
                index -= 1;

                var node: usize = 0;

                if (index < items.len) {
                    std.mem.swap(T, &items[0], &items[index]);
                } else {
                    node = index - items.len;
                }

                sorter.sift_down(items[0..@min(index, items.len)], node);
            }

            assert(index == 0);
        }

        fn sift_down(sorter: *const Sorter, items: []T, from: usize) void {
            assert(from <= items.len);

            var node = from;

            assert(items.len <= std.math.maxInt(u32));

            for (0..heap_sift_depth_max) |_| {
                var child = 2 * node + 1;
                if (child >= items.len) return;

                if (child + 1 < items.len) {
                    child += @intFromBool(less(sorter.context, items[child], items[child + 1]));
                }

                if (!less(sorter.context, items[node], items[child])) return;

                std.mem.swap(T, &items[node], &items[child]);
                node = child;
            }

            unreachable;
        }

        fn small_sort(sorter: *const Sorter, items: []T) void {
            assert(items.len <= small_count_max);

            if (items.len < 2) return;

            switch (small) {
                .general, .fallback => sorter.insertion(items, 1),
                .network => sorter.network(items),
            }

            assert(!less(sorter.context, items[1], items[0]));
        }

        fn network(sorter: *const Sorter, items: []T) void {
            assert(items.len >= 2);
            assert(items.len <= small_network_scratch_count);

            if (items.len < network_merge_count_min) {
                sorter.network_region(items);

                return;
            }

            const half = items.len / 2;
            var scratch: [small_network_scratch_count]T = undefined;
            const merged = scratch[0..items.len];

            sorter.network_region(items[0..half]);
            sorter.network_region(items[half..]);
            sorter.merge_bidirectional(items, merged);

            @memcpy(items, merged);
        }

        fn network_region(sorter: *const Sorter, region: []T) void {
            assert(region.len >= 1);
            assert(region.len < network_merge_count_min);

            if (region.len < 9) {
                sorter.insertion(region, 1);
            } else if (region.len < 13) {
                sorter.network_apply(region, &network_9);
                sorter.insertion(region, 9);
            } else {
                sorter.network_apply(region, &network_13);
                sorter.insertion(region, 13);
            }
        }

        fn network_apply(sorter: *const Sorter, region: []T, pairs: []const [2]u8) void {
            assert(pairs.len > 0);
            assert(region.len >= 9);

            for (pairs) |pair| {
                const a = pair[0];
                const b = pair[1];

                assert(a < b);
                assert(b < region.len);

                const swapped = less(sorter.context, region[b], region[a]);

                if (swapped) std.mem.swap(T, &region[a], &region[b]);
            }
        }

        fn insertion(sorter: *const Sorter, items: []T, offset: u32) void {
            assert(offset > 0);
            assert(offset <= items.len);

            for (offset..items.len) |tail| sorter.insert_tail(items[0 .. tail + 1]);
        }

        fn insert_tail(sorter: *const Sorter, items: []T) void {
            assert(items.len >= 2);

            const tail = items.len - 1;
            const held = items[tail];
            var gap = tail;

            if (!less(sorter.context, held, items[tail - 1])) return;

            for (0..tail) |_| {
                items[gap] = items[gap - 1];
                gap -= 1;

                if (gap == 0) break;
                if (!less(sorter.context, held, items[gap - 1])) break;
            }

            items[gap] = held;

            assert(gap < tail);
        }

        fn merge_bidirectional(sorter: *const Sorter, items: []const T, merged: []T) void {
            assert(merged.len == items.len);

            const half = items.len / 2;
            var left: usize = 0;
            var right: usize = half;
            var front: usize = 0;
            var left_end: usize = half;
            var right_end: usize = items.len;
            var back: usize = items.len;

            assert(half > 0);

            for (0..half) |_| {
                const take_left = !less(sorter.context, items[right], items[left]);

                merged[front] = if (take_left) items[left] else items[right];
                left += @intFromBool(take_left);
                right += @intFromBool(!take_left);
                front += 1;

                const take_right = !less(sorter.context, items[right_end - 1], items[left_end - 1]);

                merged[back - 1] = if (take_right) items[right_end - 1] else items[left_end - 1];
                right_end -= @intFromBool(take_right);
                left_end -= @intFromBool(!take_right);
                back -= 1;
            }

            if (items.len % 2 == 1) {
                const left_open = left < left_end;

                merged[front] = if (left_open) items[left] else items[right];
                left += @intFromBool(left_open);
                right += @intFromBool(!left_open);
            }

            assert(left == left_end);
            assert(right == right_end);
        }
    };
}

fn small_of(comptime T: type) Small {
    const size = @sizeOf(T);

    comptime assert(size > 0);

    if (size <= swap_efficient_bytes_max) {
        if (size * small_network_scratch_count <= stack_array_bytes_max) return .network;
    }

    if (size * small_general_scratch_count <= stack_array_bytes_max) return .general;
    return .fallback;
}

const Keys = struct {
    ends: []const u32,
    starts: []const u32,
};

const Wide = struct {
    length: u32,
    offset: u32,
    source: u32,
    target: u32,
};

const Pin = struct {
    hash: u64,
    length: u32,
};

test "the unstable sort orders tied indexes as the rust unstable sort does" {
    const pins = [_]Pin{
        .{ .hash = 0x97014ad93de6fb9d, .length = 20 },
        .{ .hash = 0x83533504ffb2bc3d, .length = 32 },
        .{ .hash = 0xc04063a7316a7927, .length = 40 },
        .{ .hash = 0x92eaab24a8c30f0f, .length = 100 },
        .{ .hash = 0x29b70843cb15b719, .length = 1000 },
    };

    var starts: [1000]u32 = undefined;
    var ends: [1000]u32 = undefined;
    var indexes: [1000]u32 = undefined;
    var state: u64 = 0x9E37_79B9_7F4A_7C15;
    const keys: Keys = .{ .ends = &ends, .starts = &starts };

    for (pins) |pin| {
        const held = indexes[0..pin.length];

        keys_random_fill(starts[0..pin.length], ends[0..pin.length], held, &state);
        unstable(u32, held, Keys, keys, key_precedes);

        try std.testing.expectEqual(pin.hash, indexes_hash(held));
    }

    const heap = indexes[0..100];
    const Sorter = SorterType(u32, Keys, key_precedes);
    const sorter: Sorter = .{ .context = keys };

    keys_random_fill(starts[0..100], ends[0..100], heap, &state);
    sorter.heapsort(heap);

    try std.testing.expectEqual(0x21948e9fec9d8201, indexes_hash(heap));
    try std.testing.expectEqual(Small.network, Sorter.small);
}

test "the unstable sort orders tied wide items as the rust unstable sort does" {
    const pins = [_]Pin{
        .{ .hash = 0xbb0e0d72c4b8a2ed, .length = 20 },
        .{ .hash = 0xe51d7914242b24d3, .length = 40 },
        .{ .hash = 0x5755893342d92bb5, .length = 100 },
        .{ .hash = 0xa055101b4d79e74f, .length = 1000 },
    };

    var items: [1000]Wide = undefined;
    var state: u64 = 0x9E37_79B9_7F4A_7C15;

    for (pins) |pin| {
        const held = items[0..pin.length];

        wide_random_fill(held, &state);
        unstable(Wide, held, void, {}, wide_less);

        try std.testing.expectEqual(pin.hash, wide_hash(held));
    }

    const heap = items[0..100];
    const Sorter = SorterType(Wide, void, wide_less);
    const sorter: Sorter = .{ .context = {} };

    wide_random_fill(heap, &state);
    sorter.heapsort(heap);

    try std.testing.expectEqual(0xe362f16bce3bdf99, wide_hash(heap));
    try std.testing.expectEqual(Small.general, Sorter.small);
}

fn indexes_hash(indexes: []const u32) u64 {
    assert(indexes.len <= std.math.maxInt(u32));

    var hash: u64 = 1469598103934665603;

    for (indexes) |index| hash = (hash ^ index) *% 1099511628211;

    return hash;
}

fn key_precedes(keys: Keys, left: u32, right: u32) bool {
    assert(left < keys.starts.len);
    assert(right < keys.starts.len);
    assert(keys.ends.len == keys.starts.len);

    const left_start = keys.starts[left];
    const right_start = keys.starts[right];
    if (left_start != right_start) return left_start < right_start;
    return keys.ends[left] > keys.ends[right];
}

fn keys_random_fill(starts: []u32, ends: []u32, indexes: []u32, state: *u64) void {
    assert(starts.len <= std.math.maxInt(u32));
    assert(ends.len <= std.math.maxInt(u32));
    assert(indexes.len <= std.math.maxInt(u32));

    for (starts, ends, indexes, 0..) |*start, *end, *index, position| {
        start.* = @intCast(xorshift_next(state) % 3);
        end.* = start.* + @as(u32, @intCast(xorshift_next(state) % 3));
        index.* = @intCast(position);
    }
}

fn wide_hash(items: []const Wide) u64 {
    assert(items.len <= std.math.maxInt(u32));

    var hash: u64 = 1469598103934665603;

    for (items) |item| hash = (hash ^ item.length) *% 1099511628211;

    return hash;
}

fn wide_less(context: void, left: Wide, right: Wide) bool {
    _ = context;

    if (left.source != right.source) return left.source < right.source;
    if (left.offset != right.offset) return left.offset < right.offset;
    return left.target < right.target;
}

fn wide_random_fill(items: []Wide, state: *u64) void {
    assert(items.len <= std.math.maxInt(u32));

    for (items, 0..) |*item, index| {
        const offset: u32 = @intCast(xorshift_next(state) % 3);
        const target: u32 = @intCast(xorshift_next(state) % 3);

        item.* = .{
            .length = @intCast(index),
            .offset = offset,
            .source = @intCast(index % 2),
            .target = target,
        };
    }
}

fn xorshift_next(state: *u64) u64 {
    state.* ^= state.* << 13;
    state.* ^= state.* >> 7;
    state.* ^= state.* << 17;

    return state.*;
}
