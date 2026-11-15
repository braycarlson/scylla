const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const bounded = @import("../../stdx/bounded.zig");
const path_platform = @import("platform.zig");
const stat_of = @import("stat.zig").stat_of;
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

pub const Rename = struct {
    source: []const u8,
    target: []const u8,
};

pub const SystemError = error{
    AccessDenied,
    FileNotFound,
    IsDirectory,
    NameTooLong,
    NotDirectory,
    PathNotFound,
    PermissionDenied,
    SymlinkLoop,
    Unexpected,
};

pub const Write = struct {
    content: []const u8,
    path: []const u8,
};

pub const ReadError = error{Overflow} || SystemError;
const native = path_platform.PathType(path_platform.platform_native);
const path_bytes_max = path_platform.path_bytes_max;

pub fn create(io: std.Io, bytes: []const u8) SystemError!std.Io.File {
    assert(bytes.len <= std.math.maxInt(u32));

    const held = native.path_of(bytes) orelse return error.NameTooLong;

    assert(held.len == bytes.len);
    assert(held.len <= path_bytes_max);

    return std.Io.Dir.cwd().createFile(io, held, .{}) catch |err| located(io, held, err);
}

pub fn create_directories(io: std.Io, bytes: []const u8) SystemError!void {
    assert(bytes.len <= std.math.maxInt(u32));

    const held = native.path_of(bytes) orelse return error.NameTooLong;

    assert(held.len == bytes.len);
    assert(held.len <= path_bytes_max);

    std.Io.Dir.cwd().createDirPath(io, held) catch |err| return system_error_of(err);
}

pub fn is_directory(io: std.Io, bytes: []const u8) bool {
    assert(bytes.len <= std.math.maxInt(u32));

    const held = native.path_of(bytes) orelse return false;

    assert(held.len == bytes.len);
    assert(held.len <= path_bytes_max);

    const held_stat = std.Io.Dir.cwd().statFile(io, held, .{}) catch return false;
    return held_stat.kind == .directory;
}

pub fn is_file(io: std.Io, bytes: []const u8) bool {
    assert(bytes.len <= std.math.maxInt(u32));

    const held = native.path_of(bytes) orelse return false;

    assert(held.len == bytes.len);
    assert(held.len <= path_bytes_max);

    const held_stat = std.Io.Dir.cwd().statFile(io, held, .{}) catch return false;
    return held_stat.kind == .file;
}

pub fn open(io: std.Io, bytes: []const u8) SystemError!std.Io.File {
    assert(bytes.len <= std.math.maxInt(u32));

    const held = native.path_of(bytes) orelse return error.NameTooLong;

    assert(held.len == bytes.len);
    assert(held.len <= path_bytes_max);

    return std.Io.Dir.cwd().openFile(io, held, .{}) catch |err| located(io, held, err);
}

pub fn read_into(io: std.Io, target: *bounded.Buffer, bytes: []const u8) ReadError!void {
    assert(target.empty());
    assert(bytes.len <= std.math.maxInt(u32));

    const held = native.path_of(bytes) orelse return error.NameTooLong;

    const body = std.Io.Dir.cwd().readFile(io, held, target.bytes) catch |err| {
        return located(io, held, err);
    };

    if (body.len == target.bytes.len) return error.Overflow;

    target.length = @intCast(body.len);

    assert(target.count() < target.capacity());
}

pub fn remove(io: std.Io, bytes: []const u8) SystemError!void {
    assert(bytes.len <= std.math.maxInt(u32));

    const held = native.path_of(bytes) orelse return error.NameTooLong;

    assert(held.len == bytes.len);
    assert(held.len <= path_bytes_max);

    std.Io.Dir.cwd().deleteFile(io, held) catch |err| return system_error_of(err);
}

pub fn remove_directory(io: std.Io, bytes: []const u8) SystemError!void {
    assert(bytes.len <= std.math.maxInt(u32));

    const held = native.path_of(bytes) orelse return error.NameTooLong;

    assert(held.len == bytes.len);
    assert(held.len <= path_bytes_max);

    std.Io.Dir.cwd().deleteDir(io, held) catch |err| return system_error_of(err);
}

pub fn remove_tree(io: std.Io, bytes: []const u8) SystemError!void {
    assert(bytes.len <= std.math.maxInt(u32));

    const held = native.path_of(bytes) orelse return error.NameTooLong;

    assert(held.len == bytes.len);
    assert(held.len <= path_bytes_max);

    if (stat_of(io, held) == null) return error.FileNotFound;

    std.Io.Dir.cwd().deleteTree(io, held) catch |err| return system_error_of(err);

    assert(stat_of(io, held) == null);
}

pub fn rename(io: std.Io, moved: Rename) SystemError!void {
    assert(moved.source.len <= std.math.maxInt(u32));

    const source = native.path_of(moved.source) orelse return error.NameTooLong;
    const target = native.path_of(moved.target) orelse return error.NameTooLong;
    const cwd = std.Io.Dir.cwd();

    assert(source.len <= path_bytes_max);
    assert(target.len <= path_bytes_max);

    std.Io.Dir.rename(cwd, source, cwd, target, io) catch |err| return system_error_of(err);
}

pub fn error_text(err: SystemError, platform: path_platform.Platform) ?[]const u8 {
    const held: ?[]const u8 = switch (platform) {
        .posix => posix_text(err),
        .windows => windows_text(err),
    };

    if (held) |text| assert(text.len > 0);

    switch (err) {
        error.Unexpected => assert(held == null),
        else => assert(held != null),
    }

    return held;
}

fn posix_text(err: SystemError) ?[]const u8 {
    return switch (err) {
        error.AccessDenied => "Permission denied (os error 13)",
        error.FileNotFound => "No such file or directory (os error 2)",
        error.IsDirectory => "Is a directory (os error 21)",
        error.NameTooLong => "File name too long (os error 36)",
        error.NotDirectory => "Not a directory (os error 20)",
        error.PathNotFound => "No such file or directory (os error 2)",
        error.PermissionDenied => "Operation not permitted (os error 1)",
        error.SymlinkLoop => "Too many levels of symbolic links (os error 40)",
        error.Unexpected => null,
    };
}

fn windows_text(err: SystemError) ?[]const u8 {
    return switch (err) {
        error.AccessDenied, error.IsDirectory, error.PermissionDenied => access_denied_windows,
        error.FileNotFound => "The system cannot find the file specified. (os error 2)",
        error.NameTooLong => "The filename or extension is too long. (os error 206)",
        error.NotDirectory, error.PathNotFound => path_missing_windows,
        error.SymlinkLoop => symlink_windows,
        error.Unexpected => null,
    };
}

pub fn system_error_of(err: anyerror) SystemError {
    return switch (err) {
        error.AccessDenied => error.AccessDenied,
        error.FileNotFound => error.FileNotFound,
        error.IsDir, error.IsDirectory => error.IsDirectory,
        error.NameTooLong => error.NameTooLong,
        error.NotDir, error.NotDirectory => error.NotDirectory,
        error.PathNotFound => error.PathNotFound,
        error.PermissionDenied => error.PermissionDenied,
        error.SymLinkLoop, error.SymlinkLoop => error.SymlinkLoop,
        else => error.Unexpected,
    };
}

pub fn write(io: std.Io, written: Write) SystemError!void {
    assert(written.path.len <= path_bytes_max);

    const file = try create(io, written.path);
    defer file.close(io);

    file.writeStreamingAll(io, written.content) catch |err| return system_error_of(err);
}

fn located(io: std.Io, held: []const u8, err: anyerror) SystemError {
    assert(held.len <= path_bytes_max);

    const classified = system_error_of(err);

    switch (classified) {
        error.FileNotFound => {},
        error.AccessDenied,
        error.IsDirectory,
        error.NameTooLong,
        error.NotDirectory,
        error.PathNotFound,
        error.PermissionDenied,
        error.SymlinkLoop,
        error.Unexpected,
        => return classified,
    }

    if (builtin.target.os.tag != .windows) return classified;

    const parent = std.Io.Dir.path.dirname(held) orelse return classified;
    if (is_directory(io, parent)) return classified;
    return error.PathNotFound;
}

fn is_project_root(io: std.Io, bytes: []const u8, markers: []const []const u8) bool {
    assert(bytes.len <= std.math.maxInt(u32));
    assert(markers.len <= std.math.maxInt(u32));

    var scratch: [path_bytes_max]u8 = undefined;

    for (markers) |marker| {
        assert(marker.len > 0);

        const parts: path_platform.Join = .{ .base = bytes, .relative = marker };

        const length = native.join(&scratch, parts) catch |err| switch (err) {
            error.Overflow => continue,
        };

        if (stat_of(io, scratch[0..length]) != null) return true;
    }

    return false;
}

const access_denied_windows = "Access is denied. (os error 5)";
const path_missing_windows = "The system cannot find the path specified. (os error 3)";
const symlink_windows = "The name of the file cannot be resolved by the system. (os error 1921)";

const missing_parent_error: SystemError = if (builtin.target.os.tag == .windows)
    error.PathNotFound
else
    error.FileNotFound;

const Held = struct {
    bytes: [path_bytes_max]u8,
    length: u32,

    fn slice(held: *const Held) []const u8 {
        return held.bytes[0..held.length];
    }
};

fn held_joined(base: []const u8, relative: []const u8) !Held {
    assert(base.len <= std.math.maxInt(u32));
    assert(relative.len <= std.math.maxInt(u32));

    var held: Held = .{ .bytes = undefined, .length = 0 };

    held.length = try native.join(&held.bytes, .{ .base = base, .relative = relative });

    return held;
}

fn root_scratch(buffer: []u8, tmp: *const std.testing.TmpDir) ![]const u8 {
    assert(buffer.len <= std.math.maxInt(u32));

    return std.mem.print(buffer, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
}

test open {
    const io = std.testing.io;
    const file = try open(io, "build.zig");
    defer file.close(io);

    var buffer: [16]u8 = undefined;
    var reader = file.reader(io, &.{});
    const length = try reader.interface.readSliceShort(&buffer);

    try expect(length > 0);
    try std.testing.expectError(error.FileNotFound, open(io, "src/missing.zig"));
}

test "the filesystem entry points round trip" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [path_bytes_max]u8 = undefined;
    const root = try root_scratch(&root_buffer, &tmp);
    const source = try held_joined(root, "one.rs");
    const target = try held_joined(root, "two.rs");

    try std.testing.expectError(error.FileNotFound, open(io, source.slice()));
    try expect(stat_of(io, source.slice()) == null);
    try expect(is_directory(io, root));
    try expect(!is_file(io, root));

    const created = try create(io, source.slice());

    try created.writeStreamingAll(io, "fn helper() {}\n");
    created.close(io);

    var body_buffer: [64]u8 = undefined;
    const body = try std.Io.Dir.cwd().readFile(io, source.slice(), &body_buffer);

    try expectEqualStrings("fn helper() {}\n", body);

    const facts = stat_of(io, source.slice()) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(15, facts.size);
    try expect(facts.seconds > 1_600_000_000);
    try expect(is_file(io, source.slice()));
    try rename(io, .{ .source = source.slice(), .target = target.slice() });
    try std.testing.expectError(error.FileNotFound, open(io, source.slice()));

    const opened = try open(io, target.slice());

    opened.close(io);
    try remove(io, target.slice());
    try std.testing.expectError(error.FileNotFound, open(io, target.slice()));

    const removed_again = remove(io, target.slice());

    try std.testing.expectError(error.FileNotFound, removed_again);
    try remove_directory(io, root);
    try expect(!is_directory(io, root));
}

test "a path past the short windows limit round trips" {
    const io = std.testing.io;
    const segment_bytes = 32;
    const name: [segment_bytes - 1]u8 = @splat('a');
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [path_bytes_max]u8 = undefined;
    var held = try held_joined(try root_scratch(&root_buffer, &tmp), "");

    for (0..path_bytes_max) |_| {
        if (held.length + segment_bytes + 4 >= 320) break;

        held = try held_joined(held.slice(), &name);
    }

    try create_directories(io, held.slice());

    const file_path = try held_joined(held.slice(), "one.rs");

    try expect(file_path.length > 260);

    const created = try create(io, file_path.slice());

    try created.writeStreamingAll(io, "fn helper() {}\n");
    created.close(io);

    const facts = stat_of(io, file_path.slice()) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(15, facts.size);

    const opened = try open(io, file_path.slice());

    opened.close(io);
    try remove(io, file_path.slice());
}

test "a path that does not fit is refused rather than truncated" {
    const io = std.testing.io;
    const overlong: [path_bytes_max + 1]u8 = @splat('a');

    try expect(native.path_of(&overlong) == null);
    try std.testing.expectError(error.NameTooLong, open(io, &overlong));
    try std.testing.expectError(error.NameTooLong, create(io, &overlong));
    try expect(stat_of(io, &overlong) == null);

    const removed = remove(io, &overlong);

    try std.testing.expectError(error.NameTooLong, removed);
    try expect(!is_file(io, &overlong));
}

test "a written file reads back and a project root is told by its markers" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [path_bytes_max]u8 = undefined;
    const bytes = try held_joined(try root_scratch(&root_buffer, &tmp), "root");
    const nested = try held_joined(bytes.slice(), "nested/deeper");
    const file = try held_joined(nested.slice(), "held.txt");
    const missing = try held_joined(bytes.slice(), "missing/held.txt");

    try create_directories(io, nested.slice());
    try expect(is_directory(io, nested.slice()));
    try write(io, .{ .content = "held", .path = file.slice() });

    var body_buffer: [16]u8 = undefined;
    const body = try std.Io.Dir.cwd().readFile(io, file.slice(), &body_buffer);

    try expectEqualStrings("held", body);

    const written = write(io, .{ .content = "held", .path = missing.slice() });

    try std.testing.expectError(missing_parent_error, written);
    try expect(is_project_root(io, nested.slice(), &.{"held.txt"}));
    try expect(is_project_root(io, bytes.slice(), &.{ "nested", "held.txt" }));
    try expect(!is_project_root(io, bytes.slice(), &.{"held.txt"}));
    try expect(!is_project_root(io, bytes.slice(), &.{}));
}

test "a system error names the error a file operation failed with" {
    try std.testing.expectEqual(error.AccessDenied, system_error_of(error.AccessDenied));
    try std.testing.expectEqual(error.FileNotFound, system_error_of(error.FileNotFound));
    try std.testing.expectEqual(error.IsDirectory, system_error_of(error.IsDir));
    try std.testing.expectEqual(error.Unexpected, system_error_of(error.Unexpected));

    const opened = open(std.testing.io, "a/path/that/is/not/there.toml");

    try std.testing.expectError(missing_parent_error, opened);
}

test "a system error classifies its own members to themselves" {
    const members = [_]SystemError{
        error.AccessDenied,
        error.FileNotFound,
        error.IsDirectory,
        error.NameTooLong,
        error.NotDirectory,
        error.PathNotFound,
        error.PermissionDenied,
        error.SymlinkLoop,
        error.Unexpected,
    };

    for (members) |member| {
        try std.testing.expectEqual(member, system_error_of(member));
        try std.testing.expectEqual(member, system_error_of(system_error_of(member)));
    }

    try std.testing.expectEqual(error.NotDirectory, system_error_of(error.NotDir));
    try std.testing.expectEqual(error.SymlinkLoop, system_error_of(error.SymLinkLoop));
    try std.testing.expectEqual(error.Unexpected, system_error_of(error.NoSpaceLeft));
}

test "a missing file is not found and a missing directory above it names the path on windows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [path_bytes_max]u8 = undefined;
    const root = try root_scratch(&root_buffer, &tmp);
    const absent = try held_joined(root, "absent.toml");
    const nested = try held_joined(root, "gone/absent.toml");

    try std.testing.expectError(error.FileNotFound, open(std.testing.io, absent.slice()));

    const written = write(std.testing.io, .{ .content = "x", .path = nested.slice() });

    try std.testing.expectError(missing_parent_error, written);
}

test "a file read into a buffer that cannot hold it is refused" {
    var small = try bounded.Buffer.init(std.testing.allocator, 8);
    defer small.deinit(std.testing.allocator);

    try std.testing.expectError(error.Overflow, read_into(std.testing.io, &small, "build.zig"));
    try expect(small.empty());

    const missing = read_into(std.testing.io, &small, "/nonexistent/scylla");

    try std.testing.expectError(missing_parent_error, missing);
}

test "a system error reads as the io error rust prints on each platform" {
    const denied = "Permission denied (os error 13)";
    const missing = "No such file or directory (os error 2)";

    try expectEqualStrings(denied, error_text(error.AccessDenied, .posix).?);
    try expectEqualStrings(missing, error_text(error.FileNotFound, .posix).?);
    try expectEqualStrings(missing, error_text(error.PathNotFound, .posix).?);
    try expectEqualStrings("Is a directory (os error 21)", error_text(error.IsDirectory, .posix).?);
    try expectEqualStrings(access_denied_windows, error_text(error.AccessDenied, .windows).?);
    try expectEqualStrings(path_missing_windows, error_text(error.PathNotFound, .windows).?);
    try expect(error_text(error.Unexpected, .posix) == null);
    try expect(error_text(error.Unexpected, .windows) == null);

    const failure = if (open(std.testing.io, "a/path/that/is/not/there.toml")) |file| {
        file.close(std.testing.io);

        return error.TestUnexpectedResult;
    } else |err| err;

    try expect(error_text(failure, path_platform.platform_native) != null);
}

test "a removed tree takes its files and directories and a missing root is not found" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [path_bytes_max]u8 = undefined;
    const root = try held_joined(try root_scratch(&root_buffer, &tmp), "tree");
    const nested = try held_joined(root.slice(), "a/b");
    const file = try held_joined(nested.slice(), "held.txt");

    try create_directories(io, nested.slice());
    try write(io, .{ .content = "held", .path = file.slice() });
    try remove_tree(io, root.slice());
    try expect(!is_directory(io, root.slice()));
    try expect(stat_of(io, file.slice()) == null);
    try std.testing.expectError(error.FileNotFound, remove_tree(io, root.slice()));

    const overlong: [path_bytes_max + 1]u8 = @splat('a');

    try std.testing.expectError(error.NameTooLong, remove_tree(io, &overlong));
}
