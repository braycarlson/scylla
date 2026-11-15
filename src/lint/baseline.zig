const std = @import("std");
const assert = std.debug.assert;
const bounded = @import("../stdx/bounded.zig");
const path = @import("../platform/path.zig");
const scan = @import("../text/scan.zig");
const system = @import("../platform/path/system.zig");
const path_platform = @import("../platform/path/platform.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const Baseline = @This();

entries: bounded.ArrayType(u64),
source: bounded.Buffer,

pub const Capacity = struct {
    entry_count_max: u32,
    file_bytes_max: u32,
};

pub const CapacityError = error{
    EntriesExhausted,
    TextExhausted,
};

pub const Error = CapacityError || path.SystemError;

pub const Finding = struct {
    code: []const u8,
    line: []const u8,
    path: []const u8,
};

const hash_prime: u64 = 0x0000_0100_0000_01b3;
const search_step_max: u32 = 64;

pub fn init(gpa: std.mem.Allocator, capacity: Capacity) std.mem.Allocator.Error!Baseline {
    assert(capacity.entry_count_max > 0);
    assert(capacity.file_bytes_max > 0);

    var entries = try bounded.ArrayType(u64).init(gpa, capacity.entry_count_max);
    errdefer entries.deinit(gpa);

    const source = try bounded.Buffer.init(gpa, capacity.file_bytes_max);
    return .{ .entries = entries, .source = source };
}

pub fn deinit(baseline: *Baseline, gpa: std.mem.Allocator) void {
    baseline.source.deinit(gpa);
    baseline.entries.deinit(gpa);
    baseline.* = undefined;
}

pub fn count(baseline: *const Baseline) u32 {
    const entry_count = baseline.entries.count();

    assert(entry_count <= baseline.entries.capacity());

    return entry_count;
}

pub fn covers(baseline: *const Baseline, key: u64) bool {
    const keys = baseline.entries.const_slice();

    assert(std.sort.isSorted(u64, keys, {}, std.sort.asc(u64)));

    const at = partition_point(keys, key);

    assert(at <= keys.len);

    if (at == keys.len) return false;
    return keys[at] == key;
}

pub fn key_at(baseline: *const Baseline, index: u32) u64 {
    assert(index < baseline.count());

    return baseline.entries.get(index);
}

pub fn key_of(finding: Finding) u64 {
    assert(finding.code.len <= std.math.maxInt(u32));

    var value = std.hash.Fnv1a_64.hash(finding.path);

    value ^= std.hash.Fnv1a_64.hash(finding.code);
    value *%= hash_prime;
    value ^= std.hash.Fnv1a_64.hash(std.mem.trim(u8, finding.line, scan.ascii_whitespace));

    assert(value *% hash_prime < std.math.maxInt(u64));

    return value *% hash_prime;
}

pub fn load(baseline: *Baseline, io: std.Io, held: []const u8) Error!void {
    assert(held.len <= std.math.maxInt(u32));

    baseline.entries.clear();
    baseline.source.clear();

    system.read_into(io, &baseline.source, held) catch |err| switch (err) {
        error.Overflow => return error.TextExhausted,
        else => |failure| return failure,
    };

    var lines = std.mem.splitScalar(u8, baseline.source.const_slice(), '\n');
    var line_count: u32 = 0;

    while (lines.next()) |line| {
        line_count += 1;

        assert(line_count <= baseline.source.count() + 1);

        const text = std.mem.trim(u8, line, scan.ascii_whitespace);
        if (text.len == 0) continue;

        const key = scan.decimal_read(text) orelse continue;

        if (baseline.entries.full()) {
            baseline.entries.clear();

            return error.EntriesExhausted;
        }

        baseline.entries.push(key);
    }

    std.sort.pdq(u64, baseline.entries.slice(), {}, std.sort.asc(u64));
    assert(std.sort.isSorted(u64, baseline.entries.const_slice(), {}, std.sort.asc(u64)));
}

pub fn record(baseline: *Baseline, key: u64) CapacityError!void {
    if (baseline.entries.full()) return error.EntriesExhausted;

    const at = partition_point(baseline.entries.const_slice(), key);

    baseline.entries.shift_tail(.{ .from = at, .to = at + 1 });
    baseline.entries.slice()[at] = key;
    assert(std.sort.isSorted(u64, baseline.entries.const_slice(), {}, std.sort.asc(u64)));
}

fn write(io: std.Io, held: []const u8, lines: []const u8) path.SystemError!void {
    assert(held.len > 0);
    assert(lines.len <= std.math.maxInt(u32));

    try path.write(io, .{ .content = lines, .path = held });
}

fn partition_point(keys: []const u64, key: u64) u32 {
    assert(keys.len <= std.math.maxInt(u32));

    var low: u32 = 0;
    var high: u32 = @intCast(keys.len);

    for (0..search_step_max) |_| {
        if (low >= high) break;

        const middle = low + (high - low) / 2;

        if (keys[middle] < key) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }

    assert(low == high);
    assert(low <= keys.len);

    return low;
}

const capacity_test: Capacity = .{ .entry_count_max = 8, .file_bytes_max = 1 << 10 };

fn file_test(buffer: []u8, tmp: *const std.testing.TmpDir) ![]const u8 {
    assert(buffer.len <= std.math.maxInt(u32));

    return std.mem.print(buffer, ".zig-cache/tmp/{s}/baseline", .{&tmp.sub_path});
}

test Baseline {
    const gpa = std.testing.allocator;
    var baseline: Baseline = try .init(gpa, .{ .entry_count_max = 8, .file_bytes_max = 1 << 10 });
    defer baseline.deinit(gpa);

    const key = Baseline.key_of(.{ .code = "TS001", .line = "let value = 1;", .path = "a.rs" });

    try baseline.record(key);
    try expect(baseline.covers(key));
    try expectEqual(1, baseline.count());
    try expectEqual(key, baseline.key_at(0));
}

test "a baseline key ignores leading and trailing space and separates paths and codes" {
    const spaced: Finding = .{ .code = "TS001", .line = "    let value = 1;  ", .path = "a.rs" };
    const plain: Finding = .{ .code = "TS001", .line = "let value = 1;", .path = "a.rs" };
    const elsewhere: Finding = .{ .code = "TS001", .line = "let value = 1;", .path = "b.rs" };
    const recoded: Finding = .{ .code = "TS002", .line = "let value = 1;", .path = "a.rs" };

    try expectEqual(key_of(plain), key_of(spaced));
    try expect(key_of(plain) != key_of(elsewhere));
    try expect(key_of(plain) != key_of(recoded));
}

test "a baseline records sorted and loads what it wrote" {
    const io = std.testing.io;
    var baseline = try Baseline.init(std.testing.allocator, capacity_test);
    defer baseline.deinit(std.testing.allocator);

    try baseline.record(7);
    try baseline.record(3);
    try baseline.record(5);
    try expect(baseline.covers(3));
    try expect(baseline.covers(5));
    try expect(!baseline.covers(4));
    try expectEqual(3, baseline.count());
    try expectEqual(3, baseline.key_at(0));
    try expectEqual(7, baseline.key_at(2));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file_buffer: [path_platform.path_bytes_max]u8 = undefined;
    const file = try file_test(&file_buffer, &tmp);

    try write(io, file, "7\n\n3\nnot a key\n5\n");

    var loaded = try Baseline.init(std.testing.allocator, capacity_test);
    defer loaded.deinit(std.testing.allocator);

    try loaded.load(io, file);
    try expectEqual(3, loaded.count());
    try expect(loaded.covers(7));
    try expectError(error.FileNotFound, loaded.load(io, "src/missing-baseline"));
}

test "a baseline that holds more keys than its table refuses the file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file_buffer: [path_platform.path_bytes_max]u8 = undefined;
    const file = try file_test(&file_buffer, &tmp);

    try write(io, file, "1\n2\n3\n");

    var baseline = try Baseline.init(std.testing.allocator, .{
        .entry_count_max = 2,
        .file_bytes_max = 1 << 10,
    });

    defer baseline.deinit(std.testing.allocator);

    try expectError(error.EntriesExhausted, baseline.load(io, file));
    try expectEqual(0, baseline.count());
    try expect(!baseline.covers(1));

    var narrow = try Baseline.init(std.testing.allocator, .{
        .entry_count_max = 8,
        .file_bytes_max = 4,
    });

    defer narrow.deinit(std.testing.allocator);

    try expectError(error.TextExhausted, narrow.load(io, file));
    try expectEqual(0, narrow.count());
}
