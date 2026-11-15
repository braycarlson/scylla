const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const windows = builtin.target.os.tag == .windows;
pub const value_bytes_max = 4096;
const key_bytes_max = 64;

pub fn get(key: []const u8, bytes: []u8) ?[]const u8 {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);
    assert(std.mem.findScalar(u8, key, '=') == null);
    assert(bytes.len > 0);

    return if (windows) copied_windows(key, bytes) else copied_posix(key, bytes);
}

pub fn lasting(key: []const u8) ?[]const u8 {
    assert(key.len > 0);
    assert(key.len <= key_bytes_max);
    assert(std.mem.findScalar(u8, key, '=') == null);

    if (!windows) return std.testing.environ.getPosix(key);

    return std.testing.environ.getAlloc(std.heap.smp_allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        error.InvalidWtf8, error.OutOfMemory => std.debug.panic("{s} could not be read", .{key}),
    };
}

fn copied_posix(key: []const u8, bytes: []u8) ?[]const u8 {
    assert(!windows);
    assert(key.len > 0);
    assert(bytes.len <= std.math.maxInt(u32));

    const value = std.testing.environ.getPosix(key) orelse return null;

    if (value.len > bytes.len) {
        std.debug.panic("the value of {s} is longer than {d} bytes", .{ key, bytes.len });
    }

    @memcpy(bytes[0..value.len], value);

    return bytes[0..value.len];
}

fn copied_windows(key: []const u8, bytes: []u8) ?[]const u8 {
    assert(windows);
    assert(std.unicode.wtf8ValidateSlice(key));
    assert(bytes.len <= std.math.maxInt(u32));

    var key_units: [key_bytes_max + 1]u16 = undefined;
    const key_count = std.unicode.wtf8ToWtf16Le(key_units[0..key_bytes_max], key) catch unreachable;

    key_units[key_count] = 0;

    const value = std.testing.environ.getWindows(key_units[0..key_count :0]) orelse return null;

    if (std.unicode.calcWtf8Len(value) > bytes.len) {
        std.debug.panic("the value of {s} is longer than {d} bytes", .{ key, bytes.len });
    }

    const length = std.unicode.wtf16LeToWtf8(bytes, value);
    return bytes[0..length];
}

fn fetchable(key: []const u8, value: []const u8) bool {
    if (!std.process.Environ.Map.validateKeyForFetch(key)) return false;
    if (!std.unicode.wtf8ValidateSlice(key)) return false;
    if (std.mem.findScalar(u8, key, '=') != null) return false;
    if (key.len > key_bytes_max) return false;
    assert(value.len <= std.math.maxInt(u32));

    return value.len <= value_bytes_max;
}

test "an environment read finds each variable the process carries and misses one it does not" {
    var held = try std.testing.environ.createMap(std.testing.allocator);
    defer held.deinit();

    var bytes: [value_bytes_max]u8 = undefined;
    var compared: u32 = 0;

    for (held.keys()) |key| {
        const value = held.get(key).?;
        if (!fetchable(key, value)) continue;

        try std.testing.expectEqualStrings(value, get(key, &bytes).?);

        compared += 1;
    }

    try std.testing.expect(compared > 0);
    try std.testing.expect(get("SCYLLA_A_VARIABLE_NO_PROCESS_CARRIES", &bytes) == null);
}

test "a lasting read stays intact through the reads that follow it" {
    const gpa = std.testing.allocator;
    var held = try std.testing.environ.createMap(gpa);
    defer held.deinit();

    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(gpa);

    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(gpa);

    for (held.keys()) |key| {
        if (!fetchable(key, held.get(key).?)) continue;

        try keys.append(gpa, key);
        try values.append(gpa, lasting(key).?);
    }

    try std.testing.expect(keys.items.len > 0);
    try std.testing.expect(lasting("SCYLLA_A_VARIABLE_NO_PROCESS_CARRIES") == null);

    for (keys.items, values.items) |key, value| {
        try std.testing.expectEqualStrings(held.get(key).?, value);
    }
}
