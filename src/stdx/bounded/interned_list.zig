const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("array.zig").ArrayType;
const Buffer = @import("buffer.zig");
const Probe = @import("table.zig").Probe;
const Span = @import("span.zig");
const TableType = @import("table.zig").TableType;
const hash_of = std.hash.Fnv1a_64.hash;

arena: Buffer,
index: Index,
spans: ArrayType(Span),

const InternedList = @This();
pub const CapacityError = error{Overflow};
pub const Error = CapacityError || InputError;
pub const Index = TableType(u32);
pub const InputError = error{Empty};

pub const Capacity = struct {
    byte_count_max: u32,
    entry_count_max: u32,
};

pub const Items = struct {
    list: *const InternedList,
    position: u32,
    remaining: u32,

    pub fn next(iterator: *Items) ?[]const u8 {
        assert(iterator.remaining <= iterator.list.count());
        assert(iterator.position <= iterator.list.count());

        if (iterator.remaining == 0) return null;
        if (iterator.position == iterator.list.count()) return null;

        const bytes = iterator.list.at(iterator.position);

        iterator.position += 1;
        iterator.remaining -= 1;

        assert(bytes.len > 0);

        return bytes;
    }
};

pub fn init(gpa: std.mem.Allocator, capacity: Capacity) std.mem.Allocator.Error!InternedList {
    assert(capacity.byte_count_max > 0);
    assert(capacity.entry_count_max > 0);

    var arena: Buffer = try .init(gpa, capacity.byte_count_max);
    errdefer arena.deinit(gpa);

    var index: Index = try .init(gpa, capacity.entry_count_max);
    errdefer index.deinit(gpa);

    const spans: ArrayType(Span) = try .init(gpa, capacity.entry_count_max);

    assert(spans.capacity() == capacity.entry_count_max);
    assert(arena.capacity() == capacity.byte_count_max);

    return .{ .arena = arena, .index = index, .spans = spans };
}

pub fn deinit(list: *InternedList, gpa: std.mem.Allocator) void {
    assert(list.spans.count() == list.index.count());

    list.spans.deinit(gpa);
    list.index.deinit(gpa);
    list.arena.deinit(gpa);
    list.* = undefined;
}

pub fn record(list: *InternedList, bytes: []const u8) Error!u32 {
    if (bytes.len == 0) return error.Empty;
    if (list.index_of(bytes)) |position| return position;
    if (list.spans.full()) return error.Overflow;

    const span = try list.arena.intern(bytes);
    const position = list.spans.count();
    const probe: Probe = .{ .arena = &list.arena, .bytes = bytes };

    list.index.insert(hash_of(bytes), span, position, probe) catch |err| switch (err) {
        error.Duplicate => unreachable,
        error.Overflow => unreachable,
    };

    list.spans.push(span);

    assert(list.spans.count() == position + 1);
    assert(list.index.count() == list.spans.count());

    return position;
}

pub fn at(list: *const InternedList, position: u32) []const u8 {
    assert(position < list.count());

    const bytes = list.arena.slice_of(list.spans.get(position));

    assert(bytes.len > 0);

    return bytes;
}

pub fn clear(list: *InternedList) void {
    assert(list.spans.count() == list.index.count());

    list.arena.clear();
    list.index.clear();
    list.spans.clear();

    assert(list.empty());
}

pub fn count(list: *const InternedList) u32 {
    assert(list.spans.count() == list.index.count());

    return list.spans.count();
}

pub fn empty(list: *const InternedList) bool {
    assert(list.spans.count() == list.index.count());

    return list.spans.empty();
}

pub fn full(list: *const InternedList) bool {
    assert(list.spans.count() == list.index.count());

    return list.spans.full();
}

pub fn index_of(list: *const InternedList, bytes: []const u8) ?u32 {
    if (bytes.len == 0) return null;

    const position = list.index.get(hash_of(bytes), Probe{ .arena = &list.arena, .bytes = bytes });

    if (position) |found| assert(found < list.count());

    return position;
}

pub fn items(list: *const InternedList) Items {
    assert(list.spans.count() == list.index.count());

    const iterator: Items = .{ .list = list, .position = 0, .remaining = list.count() };

    assert(iterator.remaining == list.spans.count());

    return iterator;
}

pub fn span_at(list: *const InternedList, position: u32) Span {
    assert(position < list.count());

    const span = list.spans.get(position);

    assert(list.span_held(span));

    return span;
}

pub fn span_held(list: *const InternedList, span: Span) bool {
    assert(span.length > 0);
    assert(list.arena.count() <= list.arena.capacity());

    return span.end() <= list.arena.count();
}

pub fn text_of(list: *const InternedList, span: Span) []const u8 {
    assert(span.length > 0);
    assert(list.span_held(span));

    return list.arena.slice_of(span);
}

test InternedList {
    const gpa = std.testing.allocator;
    var list: InternedList = try .init(gpa, .{ .byte_count_max = 64, .entry_count_max = 2 });
    defer list.deinit(gpa);

    try std.testing.expectEqual(0, try list.record("/src/main.zig"));
    try std.testing.expectEqual(1, try list.record("/src/build.zig"));
    try std.testing.expectEqual(0, try list.record("/src/main.zig"));
    try std.testing.expectEqualStrings("/src/build.zig", list.at(1));
    try std.testing.expectEqual(1, list.index_of("/src/build.zig"));
    try std.testing.expectError(error.Overflow, list.record("/src/other.zig"));
    try std.testing.expectError(error.Empty, list.record(""));

    var recorded = list.items();
    const recorded_next_first = recorded.next();
    const recorded_next_second = recorded.next();
    const recorded_next_third = recorded.next();

    try std.testing.expectEqualStrings("/src/main.zig", recorded_next_first.?);
    try std.testing.expectEqualStrings("/src/build.zig", recorded_next_second.?);
    try std.testing.expectEqual(null, recorded_next_third);
}

test "a recorded entry reads back by index and by bytes" {
    var list: InternedList = try .init(std.testing.allocator, .{
        .byte_count_max = 64,
        .entry_count_max = 4,
    });

    defer list.deinit(std.testing.allocator);

    try std.testing.expectEqual(0, try list.record("/tmp/main.rs"));
    try std.testing.expectEqual(1, try list.record("/tmp/other.py"));
    try std.testing.expectEqual(2, list.count());
    try std.testing.expectEqualStrings("/tmp/main.rs", list.at(0));
    try std.testing.expectEqualStrings("/tmp/other.py", list.at(1));
    try std.testing.expectEqual(1, list.index_of("/tmp/other.py"));
    try std.testing.expectEqual(null, list.index_of("/tmp/missing"));

    const expected = [_][]const u8{ "/tmp/main.rs", "/tmp/other.py" };
    var recorded = list.items();

    for (expected) |entry| {
        const found = recorded.next().?;

        try std.testing.expectEqualStrings(entry, found);
    }

    const past = recorded.next();

    try std.testing.expectEqual(null, past);
    try std.testing.expectEqual(0, recorded.remaining);
}

test "a span handed out reads the same bytes as its index" {
    var list: InternedList = try .init(std.testing.allocator, .{
        .byte_count_max = 64,
        .entry_count_max = 4,
    });

    defer list.deinit(std.testing.allocator);

    try std.testing.expectEqual(0, try list.record("first"));
    try std.testing.expectEqual(1, try list.record("second"));

    const span = list.span_at(1);

    try std.testing.expectEqual(Span{ .offset = 5, .length = 6 }, span);
    try std.testing.expectEqualStrings("second", list.text_of(span));
    try std.testing.expectEqualStrings(list.at(0), list.text_of(list.span_at(0)));
    try std.testing.expectEqualStrings("rstse", list.text_of(.{ .offset = 2, .length = 5 }));
}

test "a span past the arena is refused" {
    var list: InternedList = try .init(std.testing.allocator, .{
        .byte_count_max = 64,
        .entry_count_max = 4,
    });

    defer list.deinit(std.testing.allocator);

    try std.testing.expectEqual(0, try list.record("abc"));
    try std.testing.expect(!list.span_held(.{ .offset = 1, .length = 3 }));
}

test "a repeated entry keeps its first index" {
    var list: InternedList = try .init(std.testing.allocator, .{
        .byte_count_max = 64,
        .entry_count_max = 4,
    });

    defer list.deinit(std.testing.allocator);

    try std.testing.expectEqual(0, try list.record("a"));
    try std.testing.expectEqual(1, try list.record("b"));
    try std.testing.expectEqual(0, try list.record("a"));
    try std.testing.expectEqual(2, list.count());
}

test "an empty entry is refused" {
    var list: InternedList = try .init(std.testing.allocator, .{
        .byte_count_max = 64,
        .entry_count_max = 4,
    });

    defer list.deinit(std.testing.allocator);

    try std.testing.expectError(error.Empty, list.record(""));
    try std.testing.expectEqual(null, list.index_of(""));
    try std.testing.expect(list.empty());
}

test "a full list refuses a new entry and still finds an old one" {
    var list: InternedList = try .init(std.testing.allocator, .{
        .byte_count_max = 64,
        .entry_count_max = 2,
    });

    defer list.deinit(std.testing.allocator);

    try std.testing.expectEqual(0, try list.record("a"));
    try std.testing.expectEqual(1, try list.record("b"));
    try std.testing.expect(list.full());
    try std.testing.expectError(error.Overflow, list.record("c"));
    try std.testing.expectEqual(1, try list.record("b"));
}

test "a list with no room for the bytes refuses the entry" {
    var list: InternedList = try .init(std.testing.allocator, .{
        .byte_count_max = 4,
        .entry_count_max = 4,
    });

    defer list.deinit(std.testing.allocator);

    try std.testing.expectEqual(0, try list.record("abc"));
    try std.testing.expectError(error.Overflow, list.record("de"));
    try std.testing.expectEqual(1, try list.record("d"));
    try std.testing.expectEqual(2, list.count());
}

test "a cleared list forgets every entry" {
    var list: InternedList = try .init(std.testing.allocator, .{
        .byte_count_max = 64,
        .entry_count_max = 4,
    });

    defer list.deinit(std.testing.allocator);

    try std.testing.expectEqual(0, try list.record("a"));

    list.clear();

    try std.testing.expect(list.empty());
    try std.testing.expectEqual(null, list.index_of("a"));
    try std.testing.expectEqual(0, try list.record("b"));
}

test "an iterator stops at the count it started with" {
    var list: InternedList = try .init(std.testing.allocator, .{
        .byte_count_max = 64,
        .entry_count_max = 4,
    });

    defer list.deinit(std.testing.allocator);

    try std.testing.expectEqual(0, try list.record("a"));

    var recorded = list.items();

    try std.testing.expectEqual(1, try list.record("b"));

    const recorded_next_first = recorded.next();
    const recorded_next_second = recorded.next();

    try std.testing.expectEqualStrings("a", recorded_next_first.?);
    try std.testing.expectEqual(null, recorded_next_second);
    try std.testing.expectEqual(2, list.count());
}
