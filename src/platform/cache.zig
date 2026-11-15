const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const bounded = @import("../stdx/bounded.zig");
const log = @import("../stdx/log.zig");
const path = @import("path.zig");
const scan = @import("../text/scan.zig");
const system = @import("path/system.zig");
const path_platform = @import("path/platform.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;
const Span = bounded.Span;
const Cache = @This();

entries: bounded.ArrayType(Entry),
index: []u32,
key: u64,
magic: [magic_bytes]u8,
paths: bounded.Buffer,
scratch: bounded.Buffer,
target: bounded.Buffer,
temporary: bounded.Buffer,

pub const Capacity = struct {
    entry_count_max: u32,
    file_bytes_max: u32,
    path_bytes_max: u32,
};

pub const CapacityError = error{
    EntriesExhausted,
    PathTooLong,
    TextExhausted,
};

pub const Error = CapacityError || path.SystemError;

const Entry = struct {
    mode: u32,
    nanoseconds: i64,
    path: Span,
    seconds: i64,
    seen: u64,
    size: u64,

    fn stamp(entry: *const Entry) path.Stat {
        return .{
            .mode = entry.mode,
            .nanoseconds = entry.nanoseconds,
            .seconds = entry.seconds,
            .size = entry.size,
        };
    }
};

const eviction_seconds: u64 = 30 * 24 * 60 * 60;
pub const magic_bytes: u32 = 8;
const version: u32 = 2;
const checksum_offset: u32 = 24;
const clean_name = "/1/clean.bin";
const entry_count_offset: u32 = 12;
const header_bytes: u32 = 32;
const stamp_bytes: u32 = 36;
const tag_bytes_max: u32 = 512;
const tag_name = "CACHEDIR.TAG";
const tag_signature = "Signature: 8a477f597d28d172789f06886806bc55\n";

const tag_format = tag_signature ++
    "# This file is a cache directory tag created by {s}.\n" ++
    "# For information about cache directory tags see https://bford.info/cachedir/\n";

comptime {
    assert(entry_count_offset + 4 <= header_bytes);
    assert(magic_bytes + 4 == entry_count_offset);
    assert(entry_count_offset + 4 + 8 == checksum_offset);
    assert(checksum_offset + 8 == header_bytes);
}

pub fn init(
    gpa: std.mem.Allocator,
    capacity: Capacity,
    magic: []const u8,
) std.mem.Allocator.Error!Cache {
    assert(capacity.file_bytes_max >= header_bytes);
    assert(capacity.entry_count_max > 0);
    assert(capacity.entry_count_max <= std.math.maxInt(u32) / 4);
    assert(capacity.path_bytes_max <= std.math.maxInt(u16));
    assert(magic.len > 0);
    assert(magic.len < magic_bytes);

    var held: [magic_bytes]u8 = @splat(0);

    @memcpy(held[0..magic.len], magic);

    var entries = try bounded.ArrayType(Entry).init(gpa, capacity.entry_count_max);
    errdefer entries.deinit(gpa);

    const slot_count = std.math.ceilPowerOfTwoAssert(u32, capacity.entry_count_max * 2);
    const index = try gpa.alloc(u32, slot_count);
    errdefer gpa.free(index);

    @memset(index, 0);

    return init_buffers(gpa, capacity, entries, index, held);
}

fn init_buffers(
    gpa: std.mem.Allocator,
    capacity: Capacity,
    entries: bounded.ArrayType(Entry),
    index: []u32,
    magic: [magic_bytes]u8,
) std.mem.Allocator.Error!Cache {
    assert(magic[0] != 0);
    assert(magic[magic_bytes - 1] == 0);
    assert(std.math.isPowerOfTwo(index.len));
    assert(index.len >= entries.capacity() * 2);

    var paths = try bounded.Buffer.init(gpa, capacity.file_bytes_max);
    errdefer paths.deinit(gpa);

    var scratch = try bounded.Buffer.init(gpa, capacity.file_bytes_max);
    errdefer scratch.deinit(gpa);

    var target = try bounded.Buffer.init(gpa, capacity.path_bytes_max);
    errdefer target.deinit(gpa);

    const temporary = try bounded.Buffer.init(gpa, capacity.path_bytes_max);

    return .{
        .entries = entries,
        .index = index,
        .key = 0,
        .magic = magic,
        .paths = paths,
        .scratch = scratch,
        .target = target,
        .temporary = temporary,
    };
}

pub fn deinit(cache: *Cache, gpa: std.mem.Allocator) void {
    cache.temporary.deinit(gpa);
    cache.target.deinit(gpa);
    cache.scratch.deinit(gpa);
    cache.paths.deinit(gpa);
    gpa.free(cache.index);
    cache.entries.deinit(gpa);
    cache.* = undefined;
}

fn count(cache: *const Cache) u32 {
    const entry_count = cache.entries.count();

    assert(entry_count <= cache.entries.capacity());

    return entry_count;
}

pub fn is_clean(cache: *const Cache, held: []const u8, stamp: path.Stat) bool {
    assert(held.len <= std.math.maxInt(u32));
    assert(stamp.nanoseconds >= 0);
    assert(stamp.nanoseconds < std.time.ns_per_s);

    const position = cache.find(held) orelse return false;

    assert(position < cache.entries.count());

    return std.meta.eql(cache.entries.get(position).stamp(), stamp);
}

pub fn open(
    cache: *Cache,
    io: std.Io,
    directory: []const u8,
    key: u64,
    creator: []const u8,
) Error!void {
    assert(directory.len > 0);
    assert(creator.len > 0);

    cache.key = key;

    cache.paths_build(directory) catch |err| switch (err) {
        error.Overflow => {
            log.line("the cache path does not fit; the cache is off", .{});

            return error.PathTooLong;
        },
    };

    directories_create(io, directory) catch |err| {
        log.line("the cache directory could not be created; the cache is off", .{});

        return err;
    };

    tag_write(io, directory, creator);
    cache.load(io);
    assert(cache.key == key);
}

pub fn persist(cache: *Cache, io: std.Io) path.SystemError!void {
    cache.encode(io);
    try cache.flush(io);
}

pub fn record(cache: *Cache, io: std.Io, held: []const u8, stamp: path.Stat) CapacityError!void {
    assert(held.len > 0);
    assert(stamp.nanoseconds >= 0);
    assert(stamp.nanoseconds < std.time.ns_per_s);

    const seen = now_seconds(io);

    if (cache.find(held)) |position| {
        const entry = &cache.entries.slice()[position];

        entry.mode = stamp.mode;
        entry.nanoseconds = stamp.nanoseconds;
        entry.seconds = stamp.seconds;
        entry.seen = seen;
        entry.size = stamp.size;

        return;
    }

    try cache.insert(held, .{
        .mode = stamp.mode,
        .nanoseconds = stamp.nanoseconds,
        .path = Span.empty,
        .seconds = stamp.seconds,
        .seen = seen,
        .size = stamp.size,
    });
}

fn clear(cache: *Cache) void {
    cache.entries.clear();
    cache.paths.clear();
    @memset(cache.index, 0);
    assert(cache.entries.empty());
    assert(cache.paths.empty());
}

fn checksum_patch(cache: *Cache) void {
    assert(cache.scratch.count() >= header_bytes);

    var bytes: [8]u8 = undefined;

    std.mem.writeInt(u64, &bytes, body_checksum(cache.scratch.const_slice()), .little);
    cache.scratch.patch(checksum_offset, &bytes);
}

fn count_patch(cache: *Cache, written: u32) void {
    assert(cache.scratch.count() >= header_bytes);
    assert(written < std.math.maxInt(u32));

    var bytes: [4]u8 = undefined;

    std.mem.writeInt(u32, &bytes, written, .little);
    cache.scratch.patch(entry_count_offset, &bytes);
}

fn encode(cache: *Cache, io: std.Io) void {
    const cutoff = now_seconds(io) -| eviction_seconds;
    var written: u32 = 0;

    cache.scratch.clear();
    cache.header_write();

    for (cache.entries.const_slice()) |*entry| {
        if (entry.seen < cutoff) continue;

        cache.record_write(entry) catch |err| switch (err) {
            error.Overflow => {
                log.line("the cache did not fit its buffer; it is written short", .{});

                break;
            },
        };

        written += 1;
    }

    assert(written <= cache.entries.count());

    cache.count_patch(written);
    cache.checksum_patch();
}

fn find(cache: *const Cache, held: []const u8) ?u32 {
    if (held.len == 0) return null;

    const mask = cache.index.len - 1;
    var slot: usize = @intCast(std.hash.Fnv1a_64.hash(held) & mask);

    for (0..cache.index.len) |_| {
        const occupant = cache.index[slot];
        if (occupant == 0) return null;

        const position = occupant - 1;
        const entry = cache.entries.get(position);

        if (std.mem.eql(u8, entry.path.text(cache.paths.const_slice()), held)) {
            assert(position < std.math.maxInt(u32));

            return position;
        }

        slot = (slot + 1) & mask;
    }

    unreachable;
}

fn flush(cache: *const Cache, io: std.Io) path.SystemError!void {
    assert(cache.temporary.count() > 0);
    assert(cache.target.count() > 0);

    const temporary = cache.temporary.const_slice();
    const written: path.Write = .{ .content = cache.scratch.const_slice(), .path = temporary };

    path.write(io, written) catch |err| {
        discard(io, temporary);
        log.line("the cache could not be written", .{});

        return err;
    };

    path.rename(io, .{ .source = temporary, .target = cache.target.const_slice() }) catch |err| {
        discard(io, temporary);
        log.line("the cache could not be replaced", .{});

        return err;
    };
}

fn header_write(cache: *Cache) void {
    assert(cache.scratch.empty());

    var version_bytes: [4]u8 = undefined;
    var key_bytes: [8]u8 = undefined;

    std.mem.writeInt(u32, &version_bytes, version, .little);
    std.mem.writeInt(u64, &key_bytes, cache.key, .little);
    cache.scratch.push(&cache.magic) catch unreachable;
    cache.scratch.push(&version_bytes) catch unreachable;
    cache.scratch.push(&.{ 0, 0, 0, 0 }) catch unreachable;
    cache.scratch.push(&key_bytes) catch unreachable;
    cache.scratch.push(&.{ 0, 0, 0, 0, 0, 0, 0, 0 }) catch unreachable;
    assert(cache.scratch.count() == header_bytes);
}

fn insert(
    cache: *Cache,
    held: []const u8,
    entry: Entry,
) error{ EntriesExhausted, TextExhausted }!void {
    assert(held.len > 0);
    assert(cache.find(held) == null);

    if (cache.entries.full()) return error.EntriesExhausted;

    const offset = cache.paths.count();

    cache.paths.push(held) catch |err| switch (err) {
        error.Overflow => return error.TextExhausted,
    };

    const position = cache.entries.count();
    var placed = entry;

    placed.path = .{ .offset = offset, .length = @intCast(held.len) };

    cache.entries.push(placed);
    cache.index_place(held, position);
    assert(cache.find(held) == position);
}

fn index_place(cache: *Cache, held: []const u8, position: u32) void {
    assert(held.len > 0);
    assert(position < cache.entries.count());

    const mask = cache.index.len - 1;
    var slot: usize = @intCast(std.hash.Fnv1a_64.hash(held) & mask);

    for (0..cache.index.len) |_| {
        if (cache.index[slot] == 0) {
            cache.index[slot] = position + 1;

            return;
        }

        slot = (slot + 1) & mask;
    }

    unreachable;
}

fn load(cache: *Cache, io: std.Io) void {
    cache.clear();
    cache.scratch.clear();

    system.read_into(io, &cache.scratch, cache.target.const_slice()) catch |err| switch (err) {
        error.Overflow => return discard(io, cache.target.const_slice()),
        else => return,
    };

    cache.parse() catch |err| switch (err) {
        error.Malformed => {
            cache.clear();
            discard(io, cache.target.const_slice());
        },
    };
}

fn parse(cache: *Cache) error{Malformed}!void {
    const bytes = cache.scratch.const_slice();
    if (bytes.len < header_bytes) return error.Malformed;
    if (!std.mem.eql(u8, bytes[0..magic_bytes], &cache.magic)) return error.Malformed;
    if (read_u32_le(bytes, 8) != version) return error.Malformed;
    if (read_u64_le(bytes, 16) != cache.key) return error.Malformed;
    if (read_u64_le(bytes, checksum_offset) != body_checksum(bytes)) return error.Malformed;

    const entry_count_read = read_u32_le(bytes, entry_count_offset);
    const entry_count = entry_count_read orelse return error.Malformed;
    var offset: u32 = header_bytes;

    for (0..entry_count) |_| {
        offset = try cache.parse_entry(bytes, offset);
    }

    assert(cache.entries.count() == entry_count);
}

fn parse_entry(cache: *Cache, bytes: []const u8, offset: u32) error{Malformed}!u32 {
    assert(offset <= bytes.len);

    const length = read_u16_le(bytes, offset) orelse return error.Malformed;
    const path_start = offset + 2;
    const path_end = path_start + length;
    if (path_end + stamp_bytes > bytes.len) return error.Malformed;

    const held = bytes[path_start..path_end];
    const entry = entry_read(bytes, path_end) orelse return error.Malformed;

    if (held.len == 0) return error.Malformed;
    if (cache.find(held) != null) return error.Malformed;

    cache.insert(held, entry) catch |err| switch (err) {
        error.EntriesExhausted, error.TextExhausted => return error.Malformed,
    };

    assert(path_end + stamp_bytes <= bytes.len);

    return path_end + stamp_bytes;
}

fn paths_build(cache: *Cache, directory: []const u8) error{Overflow}!void {
    assert(directory.len > 0);

    cache.target.clear();
    cache.temporary.clear();

    var digits: [scan.decimal_bytes_max]u8 = undefined;
    const length = scan.decimal_write(&digits, process_id());

    try cache.target.push(directory);
    try cache.target.push(clean_name);
    try cache.temporary.push(directory);
    try cache.temporary.push(clean_name);
    try cache.temporary.push(".tmp");
    try cache.temporary.push(digits[0..length]);
    assert(cache.temporary.count() > cache.target.count());
}

fn record_write(cache: *Cache, entry: *const Entry) error{Overflow}!void {
    const held = entry.path.text(cache.paths.const_slice());
    const width = std.math.cast(u16, held.len) orelse return error.Overflow;
    var frame: [2]u8 = undefined;
    var stamp: [stamp_bytes]u8 = undefined;

    std.mem.writeInt(u16, &frame, width, .little);
    std.mem.writeInt(i64, stamp[0..8], entry.seconds, .little);
    std.mem.writeInt(i64, stamp[8..16], entry.nanoseconds, .little);
    std.mem.writeInt(u64, stamp[16..24], entry.seen, .little);
    std.mem.writeInt(u32, stamp[24..28], entry.mode, .little);
    std.mem.writeInt(u64, stamp[28..36], entry.size, .little);

    const echoed = entry_read(&stamp, 0).?;

    assert(std.meta.eql(echoed.stamp(), entry.stamp()));
    assert(echoed.seen == entry.seen);

    if (frame.len + held.len + stamp.len > cache.scratch.capacity() - cache.scratch.count()) {
        return error.Overflow;
    }

    try cache.scratch.push(&frame);
    try cache.scratch.push(held);
    try cache.scratch.push(&stamp);
}

fn body_checksum(bytes: []const u8) u64 {
    assert(bytes.len >= header_bytes);

    return std.hash.Fnv1a_64.hash(bytes[header_bytes..]);
}

fn now_seconds(io: std.Io) u64 {
    const now = std.Io.Clock.real.now(io);
    const seconds = @divFloor(now.nanoseconds, std.time.ns_per_s);
    if (seconds < 0) return 0;
    return std.math.cast(u64, seconds) orelse std.math.maxInt(u64);
}

fn directories_create(
    io: std.Io,
    directory: []const u8,
) (error{PathTooLong} || path.SystemError)!void {
    assert(directory.len > 0);

    var buffer: [path_platform.path_bytes_max]u8 = undefined;

    const length = path.join(&buffer, .{ .base = directory, .relative = "1" }) catch |err| {
        return switch (err) {
            error.Overflow => error.PathTooLong,
        };
    };

    assert(length > directory.len);

    try path.create_directories(io, buffer[0..length]);
}

fn discard(io: std.Io, held: []const u8) void {
    assert(held.len > 0);

    path.remove(io, held) catch return;
}

fn entry_read(bytes: []const u8, offset: u32) ?Entry {
    assert(offset <= bytes.len);

    const seconds = read_u64_le(bytes, offset) orelse return null;
    const nanoseconds = read_u64_le(bytes, offset + 8) orelse return null;

    return .{
        .mode = read_u32_le(bytes, offset + 24) orelse return null,
        .nanoseconds = @bitCast(nanoseconds),
        .path = Span.empty,
        .seconds = @bitCast(seconds),
        .seen = read_u64_le(bytes, offset + 16) orelse return null,
        .size = read_u64_le(bytes, offset + 28) orelse return null,
    };
}

fn process_id() u64 {
    const id: u64 = switch (builtin.target.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        .linux => @intCast(std.os.linux.getpid()),
        else => @intCast(std.c.getpid()),
    };

    assert(id > 0);

    return id;
}

fn tag_write(io: std.Io, directory: []const u8, creator: []const u8) void {
    assert(directory.len > 0);
    assert(creator.len > 0);

    var buffer: [path_platform.path_bytes_max]u8 = undefined;
    const parts: path.Join = .{ .base = directory, .relative = tag_name };
    const length = path.join(&buffer, parts) catch return;
    const target = buffer[0..length];
    if (path.stat_of(io, target) != null) return;

    var body_buffer: [tag_bytes_max]u8 = undefined;

    const body = std.mem.print(&body_buffer, tag_format, .{creator}) catch {
        log.line("the cache tag creator does not fit; no tag is written", .{});

        return;
    };

    path.write(io, .{ .content = body, .path = target }) catch {
        log.line("the cache tag could not be written", .{});
    };
}

fn read_u16_le(bytes: []const u8, offset: u32) ?u16 {
    assert(bytes.len <= std.math.maxInt(u32));
    assert(offset < std.math.maxInt(u32));

    const value = read_le(u16, bytes, offset);

    if (value != null) assert(offset + 2 <= bytes.len);

    return value;
}

fn read_u32_le(bytes: []const u8, offset: u32) ?u32 {
    assert(bytes.len <= std.math.maxInt(u32));
    assert(offset < std.math.maxInt(u32));

    const value = read_le(u32, bytes, offset);

    if (value != null) assert(offset + 4 <= bytes.len);

    return value;
}

fn read_u64_le(bytes: []const u8, offset: u32) ?u64 {
    assert(bytes.len <= std.math.maxInt(u32));
    assert(offset < std.math.maxInt(u32));

    const value = read_le(u64, bytes, offset);

    if (value != null) assert(offset + 8 <= bytes.len);

    return value;
}

fn read_le(comptime T: type, bytes: []const u8, offset: u32) ?T {
    comptime assert(@typeInfo(T).int.signedness == .unsigned);

    const width = @sizeOf(T);

    if (offset > bytes.len) return null;
    if (bytes.len - offset < width) return null;

    assert(offset + width <= bytes.len);

    return std.mem.readInt(T, bytes[offset..][0..width], .little);
}

const capacity_test: Capacity = .{
    .entry_count_max = 64,
    .file_bytes_max = 1 << 16,
    .path_bytes_max = 256,
};

const magic_test = "TESTSC";

const stamp_test: path.Stat = .{
    .mode = 0o644,
    .nanoseconds = 123_456_789,
    .seconds = 1_700_000_000,
    .size = 4_096,
};

fn stamp_sized(size: u64) path.Stat {
    var stamp = stamp_test;

    stamp.size = size;

    return stamp;
}

fn reserved(key: u64) !Cache {
    var cache = try Cache.init(std.testing.allocator, capacity_test, magic_test);

    cache.key = key;

    return cache;
}

fn written_test(key: u64) !Cache {
    const io = std.testing.io;
    var cache = try reserved(key);
    errdefer cache.deinit(std.testing.allocator);

    try cache.record(io, "src/one.rs", stamp_test);
    try cache.record(io, "src/two.rs", stamp_sized(8_192));
    cache.encode(io);

    return cache;
}

fn parsed(bytes: []const u8, key: u64) !Cache {
    assert(bytes.len <= std.math.maxInt(u32));

    var cache = try reserved(key);
    errdefer cache.deinit(std.testing.allocator);

    try cache.scratch.push(bytes);
    try cache.parse();

    return cache;
}

fn expect_refused(bytes: []const u8, key: u64) !void {
    try expectError(error.Malformed, parsed(bytes, key));
}

fn directory_test(buffer: []u8, tmp: *const std.testing.TmpDir) ![]const u8 {
    assert(buffer.len <= std.math.maxInt(u32));

    return std.mem.print(buffer, ".zig-cache/tmp/{s}/cache", .{&tmp.sub_path});
}

test Cache {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var directory_buffer: [path_platform.path_bytes_max]u8 = undefined;
    const directory = try directory_test(&directory_buffer, &tmp);

    const capacity: Capacity = .{
        .entry_count_max = 16,
        .file_bytes_max = 1 << 12,
        .path_bytes_max = 256,
    };

    var cache: Cache = try .init(gpa, capacity, "DEMO");
    defer cache.deinit(gpa);

    try cache.open(io, directory, 1, "scylla");
    try cache.record(io, "src/main.rs", stamp_test);
    try expect(cache.is_clean("src/main.rs", stamp_test));
    try expect(!cache.is_clean("src/main.rs", stamp_sized(1)));
    try cache.persist(io);
}

test "a written cache reads its entries back" {
    var written = try written_test(7);
    defer written.deinit(std.testing.allocator);

    var read = try parsed(written.scratch.const_slice(), 7);
    defer read.deinit(std.testing.allocator);

    var later = stamp_test;

    later.seconds += 1;

    try expectEqual(2, read.count());
    try expect(read.is_clean("src/one.rs", stamp_test));
    try expect(read.is_clean("src/two.rs", stamp_sized(8_192)));
    try expect(!read.is_clean("src/three.rs", stamp_test));
    try expect(!read.is_clean("src/one.rs", later));
}

test "the header carries the magic the version the count and the key" {
    var written = try written_test(7);
    defer written.deinit(std.testing.allocator);

    const bytes = written.scratch.const_slice();

    try expectEqualStrings(magic_test, bytes[0..magic_test.len]);
    try expectEqual(0, bytes[magic_test.len]);
    try expectEqual(version, read_u32_le(bytes, 8));
    try expectEqual(2, read_u32_le(bytes, 12));
    try expectEqual(7, read_u64_le(bytes, 16));
}

test "an entry older than the eviction window is not written" {
    const io = std.testing.io;
    var cache = try reserved(7);
    defer cache.deinit(std.testing.allocator);

    try cache.record(io, "src/fresh.rs", stamp_test);
    try cache.record(io, "src/stale.rs", stamp_test);
    cache.entries.slice()[1].seen = now_seconds(io) -| (eviction_seconds + 1);
    cache.encode(io);

    try expectEqual(1, read_u32_le(cache.scratch.const_slice(), 12));

    var read = try parsed(cache.scratch.const_slice(), 7);
    defer read.deinit(std.testing.allocator);

    try expectEqual(1, read.count());
    try expect(read.is_clean("src/fresh.rs", stamp_test));
    try expect(!read.is_clean("src/stale.rs", stamp_test));
}

test "a key a magic or a version that moved refuses the whole file" {
    var written = try written_test(7);
    defer written.deinit(std.testing.allocator);

    const bytes = written.scratch.const_slice();

    try expect_refused(bytes, 8);

    const foreign = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(foreign);

    foreign[0] = 'X';

    try expect_refused(foreign, 7);

    const versioned = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(versioned);

    std.mem.writeInt(u32, versioned[8..12], version + 1, .little);

    try expect_refused(versioned, 7);
}

test "a frame cut anywhere is refused" {
    var written = try written_test(7);
    defer written.deinit(std.testing.allocator);

    const bytes = written.scratch.const_slice();

    for (0..bytes.len) |length| {
        try expect_refused(bytes[0..length], 7);
    }

    var read = try parsed(bytes, 7);

    read.deinit(std.testing.allocator);
}

test "a count that disagrees with the frames is read by the count" {
    var written = try written_test(7);
    defer written.deinit(std.testing.allocator);

    const bytes = written.scratch.const_slice();
    const overlong = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(overlong);

    std.mem.writeInt(u16, overlong[header_bytes..][0..2], @intCast(bytes.len), .little);

    try expect_refused(overlong, 7);

    const more = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(more);

    std.mem.writeInt(u32, more[12..16], 3, .little);

    try expect_refused(more, 7);

    const fewer = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(fewer);

    std.mem.writeInt(u32, fewer[12..16], 1, .little);

    var read = try parsed(fewer, 7);
    defer read.deinit(std.testing.allocator);

    try expectEqual(1, read.count());
    try expect(read.is_clean("src/one.rs", stamp_test));
}

test "a byte flipped inside an entry refuses the whole file" {
    var written = try written_test(7);
    defer written.deinit(std.testing.allocator);

    const bytes = written.scratch.const_slice();

    for (header_bytes..bytes.len) |offset| {
        const flipped = try std.testing.allocator.dupe(u8, bytes);
        defer std.testing.allocator.free(flipped);

        flipped[offset] ^= 0x01;

        try expect_refused(flipped, 7);
    }
}

test "recording a path twice moves the entry rather than adding one" {
    const io = std.testing.io;
    var cache = try reserved(7);
    defer cache.deinit(std.testing.allocator);

    try cache.record(io, "src/one.rs", stamp_test);
    try cache.record(io, "src/one.rs", stamp_sized(1));

    try expectEqual(1, cache.count());
    try expect(cache.is_clean("src/one.rs", stamp_sized(1)));
}

test "a full cache names the table it ran out of" {
    const io = std.testing.io;

    const capacity: Capacity = .{
        .entry_count_max = 1,
        .file_bytes_max = header_bytes,
        .path_bytes_max = 256,
    };

    var cache = try Cache.init(std.testing.allocator, capacity, magic_test);
    defer cache.deinit(std.testing.allocator);

    const outgrown = cache.record(io, "src/a-path-longer-than-the-text-table.rs", stamp_test);

    try expectError(error.TextExhausted, outgrown);
    try cache.record(io, "a.rs", stamp_test);
    try expectError(error.EntriesExhausted, cache.record(io, "b.rs", stamp_test));
}

test "an opened cache persists and reopens from disk with its tag" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var directory_buffer: [path_platform.path_bytes_max]u8 = undefined;
    const directory = try directory_test(&directory_buffer, &tmp);
    var cache = try reserved(7);
    defer cache.deinit(std.testing.allocator);

    try cache.open(io, directory, 9, "scylla");
    try expectEqual(0, cache.count());
    try cache.record(io, "src/one.rs", stamp_test);
    try cache.persist(io);

    var tag_buffer: [tag_bytes_max]u8 = undefined;
    const tag = try tmp.dir.readFile(io, "cache/CACHEDIR.TAG", &tag_buffer);

    try expect(std.mem.startsWith(u8, tag, tag_signature));
    try expect(std.mem.find(u8, tag, "created by scylla.\n") != null);

    var reopened = try reserved(0);
    defer reopened.deinit(std.testing.allocator);

    try reopened.open(io, directory, 9, "another");
    try expectEqual(1, reopened.count());
    try expect(reopened.is_clean("src/one.rs", stamp_test));

    var rekeyed = try reserved(0);
    defer rekeyed.deinit(std.testing.allocator);

    try rekeyed.open(io, directory, 10, "scylla");
    try expectEqual(0, rekeyed.count());
}

test "a cache directory too long for its path buffer is refused" {
    const io = std.testing.io;
    const overlong: [256]u8 = @splat('a');
    var cache = try reserved(7);
    defer cache.deinit(std.testing.allocator);

    try expectError(error.PathTooLong, cache.open(io, &overlong, 9, "scylla"));
}

test "a little endian read refuses a short slice" {
    const bytes = [_]u8{ 1, 0, 0, 0, 0, 0, 0, 0 };

    try std.testing.expectEqual(1, read_u16_le(&bytes, 0));
    try std.testing.expectEqual(1, read_u32_le(&bytes, 0));
    try std.testing.expectEqual(1, read_u64_le(&bytes, 0));
    try std.testing.expectEqual(null, read_u16_le(&bytes, 7));
    try std.testing.expectEqual(null, read_u32_le(&bytes, 5));
    try std.testing.expectEqual(null, read_u64_le(&bytes, 1));
}
