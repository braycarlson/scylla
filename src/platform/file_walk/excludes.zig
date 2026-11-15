const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const path = @import("../path.zig");
const path_platform = @import("../path/platform.zig");
const Environment = @import("../config/environment.zig");
const expectEqualStrings = std.testing.expectEqualStrings;
const path_bytes_max = path_platform.path_bytes_max;

const Database = struct {
    passwd: []const u8,
    status: []const u8,
};

const ProfileDirectoryGet = *const fn (
    token: isize,
    directory: [*]u16,
    size: *u32,
) callconv(.winapi) i32;

const WindowsErrorGet = *const fn () callconv(.winapi) u32;
const WindowsErrorSet = *const fn (code: u32) callconv(.winapi) void;
const config_bytes_max: u32 = 1 << 16;
const database_system: Database = .{ .passwd = "/etc/passwd", .status = "/proc/self/status" };
const excludes_key = "excludesfile";
const process_token_current: isize = -4;
const system_config = "/etc/gitconfig";
const user_bytes_max: u32 = 32;

pub fn path_of(
    io: std.Io,
    environment: *const Environment,
    buffer: *[path_bytes_max]u8,
) ?[]const u8 {
    return path_in(io, environment, database_system, buffer);
}

fn path_in(
    io: std.Io,
    environment: *const Environment,
    database: Database,
    buffer: *[path_bytes_max]u8,
) ?[]const u8 {
    assert(database.passwd.len > 0);
    assert(database.status.len > 0);

    var home_buffer: [path_bytes_max]u8 = undefined;
    const home = home_of(io, environment, database, &home_buffer);
    var configuration_buffer: [path_bytes_max]u8 = undefined;
    const configuration = filled(environment.configuration_home) orelse
        if (home) |held| joined(&configuration_buffer, held, ".config") else null;

    var gitconfig_buffer: [path_bytes_max]u8 = undefined;
    var xdg_buffer: [path_bytes_max]u8 = undefined;
    const candidates = [_]?[]const u8{
        filled(environment.git_config_global),
        if (home) |held| joined(&gitconfig_buffer, held, ".gitconfig") else null,
        if (configuration) |held| joined(&xdg_buffer, held, "git/config") else null,
        filled(environment.git_config_system) orelse system_config,
    };

    var text: [config_bytes_max]u8 = undefined;

    for (candidates) |candidate| {
        const name = candidate orelse continue;
        const held = config_read(io, name, &text) orelse continue;
        const value = excludes_file_of(held) orelse continue;

        return tilde_expanded(buffer, value, home);
    }

    const directory = configuration orelse return null;

    return joined(buffer, directory, "git/ignore");
}

fn home_of(
    io: std.Io,
    environment: *const Environment,
    database: Database,
    buffer: *[path_bytes_max]u8,
) ?[]const u8 {
    assert(database.passwd.len > 0);
    assert(database.status.len > 0);

    if (filled(environment.home)) |held| return held;
    if (builtin.target.os.tag == .windows) return profile_home(buffer);

    return passwd_home(io, database, buffer);
}

fn profile_home(buffer: *[path_bytes_max]u8) ?[]const u8 {
    comptime assert(builtin.target.os.tag == .windows);

    const directory_get = @extern(ProfileDirectoryGet, .{
        .library_name = "userenv",
        .name = "GetUserProfileDirectoryW",
    });

    const error_get = @extern(WindowsErrorGet, .{
        .library_name = "kernel32",
        .name = "GetLastError",
    });

    const error_set = @extern(WindowsErrorSet, .{
        .library_name = "kernel32",
        .name = "SetLastError",
    });

    var wide: [path_bytes_max]u16 = undefined;
    var size: u32 = wide.len;

    error_set(0);

    const succeeded = directory_get(process_token_current, &wide, &size) != 0;
    const code = error_get();

    if (!succeeded) {
        if (code == 0) return buffer[0..0];

        return null;
    }

    if (size == 0) return null;
    if (size > wide.len) return null;

    return profile_copied(buffer, wide[0 .. size - 1], code);
}

fn profile_copied(buffer: *[path_bytes_max]u8, wide: []const u16, code: u32) ?[]const u8 {
    assert(wide.len < path_bytes_max);

    if (wide.len == 0) {
        if (code == 0) return buffer[0..0];

        return null;
    }

    if (std.unicode.calcWtf8Len(wide) > buffer.len) return null;

    const length = std.unicode.wtf16LeToWtf8(buffer, wide);

    assert(length >= wide.len);

    return buffer[0..length];
}

fn passwd_home(io: std.Io, database: Database, buffer: *[path_bytes_max]u8) ?[]const u8 {
    assert(database.passwd.len > 0);
    assert(database.status.len > 0);

    var text: [config_bytes_max]u8 = undefined;
    const status = config_read(io, database.status, &text) orelse return null;
    var user_buffer: [user_bytes_max]u8 = undefined;
    const user = copied_user(&user_buffer, user_of(status) orelse return null) orelse return null;
    const entries = config_read(io, database.passwd, &text) orelse return null;
    const home = directory_of_user(entries, user) orelse return null;

    assert(home.len < entries.len);

    return copied(buffer, home);
}

fn copied_user(buffer: *[user_bytes_max]u8, user: []const u8) ?[]const u8 {
    if (user.len > buffer.len) return null;

    @memcpy(buffer[0..user.len], user);

    assert(user.len > 0);

    return buffer[0..user.len];
}

fn user_of(status: []const u8) ?[]const u8 {
    assert(status.len < config_bytes_max);

    var lines = std.mem.splitScalar(u8, status, '\n');

    for (0..status.len + 1) |_| {
        const line = lines.next() orelse return null;

        if (!std.mem.startsWith(u8, line, "Uid:")) continue;

        var fields = std.mem.tokenizeAny(u8, line["Uid:".len..], " \t");
        const real = fields.next() orelse return null;

        assert(real.len > 0);

        return real;
    }

    unreachable;
}

fn directory_of_user(entries: []const u8, user: []const u8) ?[]const u8 {
    assert(entries.len < config_bytes_max);
    assert(user.len > 0);

    var lines = std.mem.splitScalar(u8, entries, '\n');

    for (0..entries.len + 1) |_| {
        const line = lines.next() orelse return null;
        var fields = std.mem.splitScalar(u8, line, ':');
        var held: [7][]const u8 = @splat("");
        var field_count: u32 = 0;

        for (&held) |*field| {
            field.* = fields.next() orelse break;
            field_count += 1;
        }

        if (field_count < 6) continue;
        if (!std.mem.eql(u8, held[2], user)) continue;

        return held[5];
    }

    unreachable;
}

fn filled(value: ?[]const u8) ?[]const u8 {
    if (value) |held| assert(held.len <= std.math.maxInt(u32));

    const held = value orelse return null;

    if (held.len == 0) return null;

    return held;
}

fn tilde_expanded(buffer: *[path_bytes_max]u8, value: []const u8, home: ?[]const u8) ?[]const u8 {
    assert(value.len > 0);
    if (home) |held| assert(held.len <= path_bytes_max);

    const held = home orelse return copied(buffer, value);
    var length: usize = 0;

    for (value) |byte| {
        const piece: []const u8 = if (byte == '~') held else &.{byte};

        if (length + piece.len > buffer.len) return null;

        @memcpy(buffer[length..][0..piece.len], piece);
        length += piece.len;
    }

    assert(length >= value.len - std.mem.countScalar(u8, value, '~'));

    return buffer[0..length];
}

fn excludes_file_of(text: []const u8) ?[]const u8 {
    assert(text.len < config_bytes_max);

    var lines = std.mem.splitScalar(u8, text, '\n');

    for (0..text.len + 1) |_| {
        const line = lines.next() orelse return null;
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (trimmed.len <= excludes_key.len) continue;
        if (!std.ascii.eqlIgnoreCase(trimmed[0..excludes_key.len], excludes_key)) continue;

        const rest = std.mem.trimStart(u8, trimmed[excludes_key.len..], " \t");

        if (rest.len == 0) continue;
        if (rest[0] != '=') continue;

        const value = unquoted(std.mem.trim(u8, rest[1..], " \t"));

        if (value.len == 0) continue;
        if (std.mem.findAny(u8, value, " \t") != null) continue;

        return value;
    }

    unreachable;
}

fn unquoted(text: []const u8) []const u8 {
    assert(text.len < config_bytes_max);

    const opened = if (std.mem.startsWith(u8, text, "\"")) text[1..] else text;
    const closed = if (std.mem.endsWith(u8, opened, "\"")) opened[0 .. opened.len - 1] else opened;
    const trimmed = std.mem.trim(u8, closed, " \t");

    assert(trimmed.len <= text.len);

    return trimmed;
}

fn config_read(io: std.Io, name: []const u8, text: *[config_bytes_max]u8) ?[]const u8 {
    assert(name.len > 0);

    const file = path.open(io, name) catch return null;
    defer file.close(io);

    var reader = file.reader(io, &.{});
    const length = reader.interface.readSliceShort(text) catch return null;

    if (length == text.len) return null;

    return text[0..length];
}

fn joined(buffer: *[path_bytes_max]u8, base: []const u8, relative: []const u8) ?[]const u8 {
    assert(base.len <= path_bytes_max);
    assert(relative.len > 0);

    const parts: path.Join = .{ .base = base, .relative = relative };
    const length = path.join(buffer, parts) catch return null;

    assert(length >= relative.len);

    return buffer[0..length];
}

fn copied(buffer: *[path_bytes_max]u8, text: []const u8) ?[]const u8 {
    if (text.len > buffer.len) return null;

    @memcpy(buffer[0..text.len], text);

    return buffer[0..text.len];
}

const database_none: Database = .{ .passwd = "absent-passwd", .status = "absent-status" };

fn environment_test(home: ?[]const u8) Environment {
    if (home) |held| assert(held.len <= path_bytes_max);

    return .{
        .application_data = null,
        .configuration_home = null,
        .home = home,
        .override = null,
    };
}

test "the global excludes file comes from the git config the ignore crate reads" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var home_buffer: [path_bytes_max]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(io, &home_buffer)];
    var environment = environment_test(home);
    var buffer: [path_bytes_max]u8 = undefined;
    var expected: [path_bytes_max]u8 = undefined;
    const fallback = path_in(io, &environment, database_none, &buffer).?;

    try expectEqualStrings(joined(&expected, home, ".config/git/ignore").?, fallback);

    try tmp.dir.writeFile(io, .{
        .sub_path = ".gitconfig",
        .data = "[core]\n\tExcludesFile = \"~/.gitignore_global\"\n",
    });

    const configured = path_in(io, &environment, database_none, &buffer).?;

    try expectEqualStrings(joined(&expected, home, ".gitignore_global").?, configured);

    try tmp.dir.writeFile(io, .{
        .sub_path = ".gitconfig",
        .data = "[core]\n\texcludesfile = /shared~/ignore\n",
    });

    const tilded = path_in(io, &environment, database_none, &buffer).?;
    var spelled: [path_bytes_max]u8 = undefined;
    const tilde_expected = try std.mem.print(&spelled, "/shared{s}/ignore", .{home});

    try expectEqualStrings(tilde_expected, tilded);

    environment.home = "";
    environment.configuration_home = home;

    const configured_only = path_in(io, &environment, database_none, &buffer).?;

    try expectEqualStrings(joined(&expected, home, "git/ignore").?, configured_only);

    environment.home = null;
    environment.configuration_home = null;

    const none = path_in(io, &environment, database_none, &buffer);

    if (builtin.target.os.tag != .windows) {
        try std.testing.expectEqual(null, none);

        return;
    }

    const gpa = std.testing.allocator;
    const profile = try std.testing.environ.getAlloc(gpa, "USERPROFILE");
    defer gpa.free(profile);

    try expectEqualStrings(joined(&expected, profile, ".config/git/ignore").?, none.?);
}

test "a git config named by the environment ranks above the home and system configs" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var home_buffer: [path_bytes_max]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(io, &home_buffer)];
    var global_buffer: [path_bytes_max]u8 = undefined;
    const global = joined(&global_buffer, home, "global.gitconfig").?;
    var system_buffer: [path_bytes_max]u8 = undefined;
    const system = joined(&system_buffer, home, "system.gitconfig").?;
    var environment = environment_test(home);

    environment.git_config_global = global;
    environment.git_config_system = system;

    var buffer: [path_bytes_max]u8 = undefined;

    const excluded = [_][2][]const u8{
        .{ ".gitconfig", "[core]\nexcludesfile = /home\n" },
        .{ "global.gitconfig", "[core]\nexcludesfile = /global\n" },
        .{ "system.gitconfig", "[core]\nexcludesfile = /system\n" },
    };

    for (excluded) |file| try tmp.dir.writeFile(io, .{ .sub_path = file[0], .data = file[1] });

    try expectEqualStrings("/global", path_of(io, &environment, &buffer).?);

    try tmp.dir.writeFile(io, .{ .sub_path = "global.gitconfig", .data = "[user]\nname = x\n" });

    try expectEqualStrings("/home", path_of(io, &environment, &buffer).?);

    try tmp.dir.deleteFile(io, ".gitconfig");

    try expectEqualStrings("/system", path_of(io, &environment, &buffer).?);
}

test "a home missing from the environment is the user profile on windows" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const environment = environment_test(null);
    var buffer: [path_bytes_max]u8 = undefined;
    const home = home_of(io, &environment, database_none, &buffer);

    if (builtin.target.os.tag != .windows) {
        try std.testing.expectEqual(null, home);

        return;
    }

    const profile = try std.testing.environ.getAlloc(gpa, "USERPROFILE");
    defer gpa.free(profile);

    try std.testing.expect(profile.len > 0);
    try expectEqualStrings(profile, home.?);
}

test "a home missing from the environment is read from the user database" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "status",
        .data = "Name:\tscylla\nUid:\t1000\t1000\t1000\t1000\nGid:\t1000\n",
    });

    try tmp.dir.writeFile(io, .{
        .sub_path = "passwd",
        .data = "root:x:0:0:root:/root:/bin/bash\nwho:x:10000:1:who:/wrong:/bin/sh\n" ++
            "user:x:1000:1000:User,,,:/home/user:/bin/zsh\n",
    });

    var root_buffer: [path_bytes_max]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var passwd_buffer: [path_bytes_max]u8 = undefined;
    var status_buffer: [path_bytes_max]u8 = undefined;

    const database: Database = .{
        .passwd = joined(&passwd_buffer, root, "passwd").?,
        .status = joined(&status_buffer, root, "status").?,
    };

    var buffer: [path_bytes_max]u8 = undefined;

    try expectEqualStrings("/home/user", passwd_home(io, database, &buffer).?);

    try tmp.dir.writeFile(io, .{ .sub_path = "passwd", .data = "user:x:1000:1000:::/bin/sh\n" });

    try expectEqualStrings("", passwd_home(io, database, &buffer).?);

    try tmp.dir.writeFile(io, .{ .sub_path = "status", .data = "Name:\tscylla\n" });

    try std.testing.expectEqual(null, passwd_home(io, database, &buffer));
}
