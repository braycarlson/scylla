const std = @import("std");
const assert = std.debug.assert;
const Buffer = @import("buffer.zig");
const Random = @import("../../testing/random.zig");
const Span = @import("span.zig");
const StaticAllocator = @import("../static_allocator.zig");
const hash_of = std.hash.Fnv1a_64.hash;

pub fn TableType(comptime Value: type) type {
    return struct {
        entries: []Entry,
        present: []u64,
        entry_count: u32,
        entry_count_max: u32,

        pub const Entry = struct {
            hash: u64,
            key: Span,
            value: Value,
        };

        pub const Row = struct {
            key: Span,
            value: Value,
        };

        pub const Iterator = struct {
            table: *const Table,
            index: u32,
            remaining: u32,

            pub fn next(iterator: *Iterator) ?Row {
                const table = iterator.table;

                assert(iterator.index <= table.entries.len);
                assert(iterator.remaining <= table.count());

                if (iterator.remaining == 0) return null;

                for (iterator.index..table.entries.len) |index| {
                    if (!table.is_present(index)) continue;

                    const entry = table.entries[index];

                    iterator.index = @intCast(index + 1);
                    iterator.remaining -= 1;

                    assert(iterator.index <= table.entries.len);

                    return .{ .key = entry.key, .value = entry.value };
                }

                iterator.index = @intCast(table.entries.len);

                return null;
            }
        };

        const Table = @This();
        pub const CapacityError = error{Overflow};
        pub const Error = CapacityError || InputError;
        pub const InputError = error{Duplicate};

        pub fn init(gpa: std.mem.Allocator, entry_count_max: u32) std.mem.Allocator.Error!Table {
            assert(entry_count_max > 0);
            assert(entry_count_max <= std.math.maxInt(u32) / 2);

            const slot_count = std.math.ceilPowerOfTwoAssert(u32, entry_count_max * 2);
            const word_count = @divCeil(slot_count, 64);
            const entries = try gpa.alloc(Entry, slot_count);
            errdefer gpa.free(entries);

            const present = try gpa.alloc(u64, word_count);

            @memset(present, 0);

            assert(entries.len >= entry_count_max * 2);
            assert(std.math.isPowerOfTwo(entries.len));

            return .{
                .entries = entries,
                .present = present,
                .entry_count = 0,
                .entry_count_max = entry_count_max,
            };
        }

        pub fn deinit(table: *Table, gpa: std.mem.Allocator) void {
            assert(table.entry_count <= table.entry_count_max);
            assert(std.math.isPowerOfTwo(table.entries.len));

            gpa.free(table.present);
            gpa.free(table.entries);
            table.* = undefined;
        }

        pub fn get(table: *const Table, hash: u64, probe: Probe) ?Value {
            assert(hash == hash_of(probe.bytes));
            assert(table.entry_count <= table.entry_count_max);
            assert(table.entry_count < table.entries.len);
            assert(std.math.isPowerOfTwo(table.entries.len));

            const mask: u64 = table.entries.len - 1;
            var index: usize = @intCast(hash & mask);

            for (0..table.entries.len) |_| {
                if (!table.is_present(index)) return null;

                const entry = table.entries[index];

                if (entry.hash == hash) {
                    if (probe.equal(entry.key)) return entry.value;
                }

                index = table.index_next(index);
            }

            unreachable;
        }

        pub fn insert(table: *Table, hash: u64, key: Span, value: Value, probe: Probe) Error!void {
            assert(hash == hash_of(probe.bytes));
            assert(key.length == probe.bytes.len);
            assert(key.length > 0);
            assert(table.entry_count < table.entries.len);
            assert(std.math.isPowerOfTwo(table.entries.len));

            if (table.entry_count == table.entry_count_max) return error.Overflow;

            const mask: u64 = table.entries.len - 1;
            var index: usize = @intCast(hash & mask);

            for (0..table.entries.len) |_| {
                if (!table.is_present(index)) {
                    table.entries[index] = .{ .hash = hash, .key = key, .value = value };

                    table.mark_present(index);
                    table.entry_count += 1;

                    assert(table.entry_count <= table.entry_count_max);

                    return;
                }

                const entry = table.entries[index];

                if (entry.hash == hash) {
                    if (probe.equal(entry.key)) return error.Duplicate;
                }

                index = table.index_next(index);
            }

            unreachable;
        }

        pub fn clear(table: *Table) void {
            assert(table.entry_count <= table.entry_count_max);

            @memset(table.present, 0);
            table.entry_count = 0;

            assert(table.empty());
        }

        pub fn count(table: *const Table) u32 {
            assert(table.entry_count <= table.entry_count_max);
            assert(table.entry_count_max * 2 <= table.entries.len);

            return table.entry_count;
        }

        pub fn empty(table: *const Table) bool {
            assert(table.entry_count <= table.entry_count_max);
            assert(table.entry_count_max * 2 <= table.entries.len);

            return table.entry_count == 0;
        }

        pub fn iterate(table: *const Table) Iterator {
            assert(table.entry_count <= table.entry_count_max);
            assert(table.entries.len > 0);

            return .{ .table = table, .index = 0, .remaining = table.entry_count };
        }

        fn index_next(table: *const Table, index: usize) usize {
            assert(index < table.entries.len);
            assert(std.math.isPowerOfTwo(table.entries.len));

            const successor = (index + 1) & (table.entries.len - 1);

            assert(successor < table.entries.len);

            return successor;
        }

        fn is_present(table: *const Table, index: usize) bool {
            assert(index < table.entries.len);
            assert(index / 64 < table.present.len);

            const bit: u6 = @intCast(index % 64);
            return (table.present[index / 64] >> bit) & 1 == 1;
        }

        fn mark_present(table: *Table, index: usize) void {
            assert(index < table.entries.len);
            assert(!table.is_present(index));

            const bit: u6 = @intCast(index % 64);

            table.present[index / 64] |= @as(u64, 1) << bit;

            assert(table.is_present(index));
        }
    };
}

pub const Probe = struct {
    arena: *const Buffer,
    bytes: []const u8,

    pub fn equal(probe: Probe, key: Span) bool {
        assert(key.length > 0);
        assert(probe.bytes.len > 0);

        return std.mem.eql(u8, probe.arena.slice_of(key), probe.bytes);
    }
};

const Interned = struct {
    hash: u64,
    key: Span,
};

fn interned(arena: *Buffer, name: []const u8) Buffer.CapacityError!Interned {
    assert(name.len > 0);

    const key = try arena.intern(name);

    assert(key.length == name.len);

    return .{ .hash = hash_of(name), .key = key };
}

test "lookup finds a key read out of a file" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var arena: Buffer = try .init(static_allocator.allocator(), 256);
    defer arena.deinit(static_allocator.allocator());

    var table: TableType(u32) = try .init(static_allocator.allocator(), 4);
    defer table.deinit(static_allocator.allocator());

    const base = try interned(&arena, "base.html");
    const row = try interned(&arena, "partials/row.html");

    try table.insert(base.hash, base.key, 7, Probe{ .arena = &arena, .bytes = "base.html" });

    try table.insert(
        row.hash,
        row.key,
        9,
        Probe{ .arena = &arena, .bytes = "partials/row.html" },
    );

    var scope = static_allocator.freeze_scope();
    defer scope.leave();

    try std.testing.expectEqual(7, table.get(base.hash, Probe{
        .arena = &arena,
        .bytes = "base.html",
    }));

    try std.testing.expectEqual(9, table.get(row.hash, Probe{
        .arena = &arena,
        .bytes = "partials/row.html",
    }));

    try std.testing.expectEqual(null, table.get(hash_of("missing.html"), Probe{
        .arena = &arena,
        .bytes = "missing.html",
    }));

    try std.testing.expectEqual(2, table.count());
}

test "insert refuses a duplicate key" {
    var arena: Buffer = try .init(std.testing.allocator, 64);
    defer arena.deinit(std.testing.allocator);

    var table: TableType(u32) = try .init(std.testing.allocator, 4);
    defer table.deinit(std.testing.allocator);

    const base = try interned(&arena, "base.html");
    const probe: Probe = .{ .arena = &arena, .bytes = "base.html" };

    try table.insert(base.hash, base.key, 1, probe);

    const second = try arena.intern("base.html");
    const inserted = table.insert(base.hash, second, 2, probe);

    try std.testing.expectError(error.Duplicate, inserted);
    try std.testing.expectEqual(1, table.get(base.hash, probe));
    try std.testing.expectEqual(1, table.count());
}

test "insert refuses past the reserved count" {
    var arena: Buffer = try .init(std.testing.allocator, 64);
    defer arena.deinit(std.testing.allocator);

    var table: TableType(u32) = try .init(std.testing.allocator, 2);
    defer table.deinit(std.testing.allocator);

    for ([_][]const u8{ "one", "two" }) |name| {
        const stored = try interned(&arena, name);

        try table.insert(stored.hash, stored.key, 0, Probe{ .arena = &arena, .bytes = name });
    }

    const three = try interned(&arena, "three");

    const inserted = table.insert(three.hash, three.key, 0, Probe{
        .arena = &arena,
        .bytes = "three",
    });

    try std.testing.expectError(error.Overflow, inserted);
    try std.testing.expectEqual(2, table.count());
}

test "two keys sharing a hash resolve by probing" {
    const names = [_][]const u8{
        "alpha",
        "beta",
        "gamma",
        "delta",
        "epsilon",
        "zeta",
        "eta",
        "theta",
    };

    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var arena: Buffer = try .init(static_allocator.allocator(), 256);
    defer arena.deinit(static_allocator.allocator());

    var table: TableType(u32) = try .init(static_allocator.allocator(), 8);
    defer table.deinit(static_allocator.allocator());

    for (names, 0..) |name, value| {
        const stored = try interned(&arena, name);

        try table.insert(stored.hash, stored.key, @intCast(value), Probe{
            .arena = &arena,
            .bytes = name,
        });
    }

    var random: Random = .init(0x9E37_79B9_7F4A_7C15);
    var scope = static_allocator.freeze_scope();
    defer scope.leave();

    for (0..1_024) |_| {
        const index = random.below(names.len);
        const name = names[index];

        try std.testing.expectEqual(index, table.get(hash_of(name), Probe{
            .arena = &arena,
            .bytes = name,
        }));
    }
}

test "clear empties the table without allocating" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var arena: Buffer = try .init(static_allocator.allocator(), 64);
    defer arena.deinit(static_allocator.allocator());

    var table: TableType(u32) = try .init(static_allocator.allocator(), 4);
    defer table.deinit(static_allocator.allocator());

    const base = try interned(&arena, "base.html");
    const probe: Probe = .{ .arena = &arena, .bytes = "base.html" };

    try table.insert(base.hash, base.key, 1, probe);

    var scope = static_allocator.freeze_scope();
    defer scope.leave();

    table.clear();

    try std.testing.expect(table.empty());
    try std.testing.expectEqual(null, table.get(base.hash, probe));
}

test "iter yields every row" {
    var arena: Buffer = try .init(std.testing.allocator, 64);
    defer arena.deinit(std.testing.allocator);

    var table: TableType(u32) = try .init(std.testing.allocator, 4);
    defer table.deinit(std.testing.allocator);

    for ([_][]const u8{ "one", "two" }, 0..) |name, value| {
        const stored = try interned(&arena, name);

        try table.insert(stored.hash, stored.key, @intCast(value), Probe{
            .arena = &arena,
            .bytes = name,
        });
    }

    var values: [2]u32 = undefined;
    var value_count: u32 = 0;
    var iterator = table.iterate();

    for (0..table.entries.len) |_| {
        const row = iterator.next() orelse break;

        values[value_count] = row.value;
        value_count += 1;
    }

    std.mem.sort(u32, &values, {}, std.sort.asc(u32));

    try std.testing.expectEqual(2, value_count);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, &values);
    try std.testing.expectEqual(0, iterator.remaining);

    const iterator_next = iterator.next();

    try std.testing.expectEqual(null, iterator_next);
}
