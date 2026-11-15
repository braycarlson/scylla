const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Buffer = @import("../../stdx/bounded/buffer.zig");

application_data: ?[]const u8,
configuration_home: ?[]const u8,
git_config_global: ?[]const u8 = null,
git_config_system: ?[]const u8 = null,
home: ?[]const u8,
override: ?[]const u8,

const Environment = @This();

pub const Os = enum {
    linux,
    macos,
    windows,

    pub const native: Os = switch (builtin.target.os.tag) {
        .windows => .windows,
        .macos => .macos,
        else => .linux,
    };
};

pub const Location = struct {
    directory_name: []const u8,
    file_name: []const u8,
    os: Os,
};

pub const CapacityError = error{Overflow};
pub const InputError = error{Unset};
pub const Error = CapacityError || InputError;

const Base = struct {
    directory: []const u8,
    home: bool,
};

const home_variable = if (builtin.target.os.tag == .windows) "USERPROFILE" else "HOME";

pub fn init(
    environment_map: *const std.process.Environ.Map,
    override_variable: []const u8,
) Environment {
    assert(override_variable.len <= std.math.maxInt(u32));

    const named = override_variable.len > 0;
    const override_value = if (named) environment_map.get(override_variable) else null;

    const environment: Environment = .{
        .application_data = environment_map.get("APPDATA"),
        .configuration_home = environment_map.get("XDG_CONFIG_HOME"),
        .git_config_global = environment_map.get("GIT_CONFIG_GLOBAL"),
        .git_config_system = environment_map.get("GIT_CONFIG_SYSTEM"),
        .home = environment_map.get(home_variable),
        .override = override_value,
    };

    if (override_variable.len == 0) assert(environment.override == null);

    return environment;
}

pub fn user_config_path(
    environment: *const Environment,
    out: *Buffer,
    location: Location,
) Error!void {
    assert(location.directory_name.len > 0);
    assert(location.file_name.len > 0);

    out.clear();

    const base = user_config_base(environment, location.os) orelse return error.Unset;
    const tail = if (base.home) user_config_tail(location.os) else "";
    const separator = if (location.os == .windows) "\\" else "/";

    const parts = [_][]const u8{
        base.directory,
        tail,
        separator,
        location.directory_name,
        separator,
        location.file_name,
    };

    for (parts) |part| {
        out.push(part) catch |err| switch (err) {
            error.Overflow => {
                out.clear();

                return error.Overflow;
            },
        };
    }

    assert(std.mem.endsWith(u8, out.const_slice(), location.file_name));
}

fn user_config_base(environment: *const Environment, os: Os) ?Base {
    if (os == .windows) {
        const directory = environment.application_data orelse return null;
        return .{ .directory = directory, .home = false };
    }

    if (environment.override) |directory| return .{ .directory = directory, .home = false };

    if (environment.configuration_home) |directory| {
        return .{ .directory = directory, .home = false };
    }

    const home_directory = environment.home orelse return null;

    assert(os != .windows);

    return .{ .directory = home_directory, .home = true };
}

fn user_config_tail(os: Os) []const u8 {
    assert(os != .windows);

    return switch (os) {
        .linux => "/.config",
        .macos => "/Library/Application Support",
        .windows => unreachable,
    };
}

fn tool_location(os: Os) Location {
    return .{ .directory_name = "tool", .file_name = "tool.toml", .os = os };
}

test Environment {
    var environment_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment_map.deinit();

    try environment_map.put("XDG_CONFIG_HOME", "/srv/config");

    const environment: Environment = .init(&environment_map, "TOOL_CONFIG");
    var out = try Buffer.init(std.testing.allocator, 256);
    defer out.deinit(std.testing.allocator);

    try environment.user_config_path(&out, .{
        .directory_name = "tool",
        .file_name = "tool.toml",
        .os = .linux,
    });

    try std.testing.expectEqualStrings("/srv/config/tool/tool.toml", out.const_slice());
}

test "a user config path follows each platform's base directory" {
    var environment_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment_map.deinit();

    try environment_map.put("APPDATA", "C:\\Users\\tester\\AppData\\Roaming");
    try environment_map.put(home_variable, "/home/tester");

    var out = try Buffer.init(std.testing.allocator, 256);
    defer out.deinit(std.testing.allocator);

    const plain: Environment = .init(&environment_map, "TOOL_CONFIG");
    const windows = tool_location(.windows);
    const linux = tool_location(.linux);
    const macos = tool_location(.macos);

    try plain.user_config_path(&out, windows);

    try std.testing.expectEqualStrings(
        "C:\\Users\\tester\\AppData\\Roaming\\tool\\tool.toml",
        out.const_slice(),
    );

    try plain.user_config_path(&out, linux);
    try std.testing.expectEqualStrings("/home/tester/.config/tool/tool.toml", out.const_slice());

    try plain.user_config_path(&out, macos);

    try std.testing.expectEqualStrings(
        "/home/tester/Library/Application Support/tool/tool.toml",
        out.const_slice(),
    );

    try environment_map.put("XDG_CONFIG_HOME", "/srv/config");

    const configured: Environment = .init(&environment_map, "TOOL_CONFIG");

    try configured.user_config_path(&out, linux);
    try std.testing.expectEqualStrings("/srv/config/tool/tool.toml", out.const_slice());

    try environment_map.put("TOOL_CONFIG", "/opt/override");

    const overridden: Environment = .init(&environment_map, "TOOL_CONFIG");

    try overridden.user_config_path(&out, linux);
    try std.testing.expectEqualStrings("/opt/override/tool/tool.toml", out.const_slice());
    try overridden.user_config_path(&out, windows);
    try std.testing.expect(std.mem.startsWith(u8, out.const_slice(), "C:\\Users\\tester"));
}

test "a user config path ends in the tool directory and file" {
    var environment_map = try std.testing.environ.createMap(std.testing.allocator);
    defer environment_map.deinit();

    const environment: Environment = .init(&environment_map, "");
    const suffix = if (Os.native == .windows) "\\tool\\tool.toml" else "/tool/tool.toml";
    const native = tool_location(Os.native);
    var out = try Buffer.init(std.testing.allocator, 256);
    defer out.deinit(std.testing.allocator);

    if (environment.user_config_path(&out, native)) |_| {
        try std.testing.expect(std.mem.endsWith(u8, out.const_slice(), suffix));
    } else |err| switch (err) {
        error.Overflow, error.Unset => try std.testing.expect(out.empty()),
    }

    var small = try Buffer.init(std.testing.allocator, 4);
    defer small.deinit(std.testing.allocator);

    if (environment.user_config_path(&small, native)) |_| {
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.Overflow, error.Unset => {},
    }

    try std.testing.expect(small.empty());
}

test "an unset home is refused and an override counts only when named" {
    var environment_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment_map.deinit();

    try environment_map.put("TOOL_CONFIG", "/opt/override");

    const unnamed: Environment = .init(&environment_map, "");
    const named: Environment = .init(&environment_map, "TOOL_CONFIG");
    const linux = tool_location(.linux);
    var out = try Buffer.init(std.testing.allocator, 256);
    defer out.deinit(std.testing.allocator);

    try std.testing.expect(unnamed.override == null);
    try std.testing.expectError(error.Unset, unnamed.user_config_path(&out, linux));
    try std.testing.expect(out.empty());
    try named.user_config_path(&out, linux);
    try std.testing.expectEqualStrings("/opt/override/tool/tool.toml", out.const_slice());
}
