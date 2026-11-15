const std = @import("std");
const path_platform = @import("path/platform.zig");
const stat = @import("path/stat.zig");
const system = @import("path/system.zig");
const native = path_platform.PathType(path_platform.platform_native);
pub const CapacityError = path_platform.CapacityError;
pub const Component = native.Component;
pub const Components = native.Components;
pub const Join = path_platform.Join;
pub const Platform = path_platform.Platform;
pub const Push = path_platform.Push;
pub const Rename = system.Rename;
pub const Segments = native.Segments;
pub const Stat = stat.Stat;
pub const SystemError = system.SystemError;
pub const Under = path_platform.Under;
pub const Write = system.Write;
pub const components_joined = native.components_joined;
pub const contains = native.contains;
pub const create = system.create;
pub const create_directories = system.create_directories;
pub const directory_of = native.directory_of;
pub const error_text = system.error_text;
pub const file_name = native.file_name;
pub const is_absolute = native.is_absolute;
pub const is_directory = system.is_directory;
pub const is_file = system.is_file;
pub const is_separator = native.is_separator;
pub const join = native.join;
pub const normalised_into = native.normalised_into;
pub const open = system.open;
pub const order = native.order;
pub const path_of = native.path_of;
pub const platform_native = path_platform.platform_native;
pub const popped = native.popped;
pub const pushed = native.pushed;
pub const relative_into = native.relative_into;
pub const remove = system.remove;
pub const remove_directory = system.remove_directory;
pub const remove_tree = system.remove_tree;
pub const rename = system.rename;
pub const segments = native.segments;
pub const separator = path_platform.separator;
pub const stat_of = stat.stat_of;
pub const system_error_of = system.system_error_of;
pub const trimmed = native.trimmed;
pub const write = system.write;

test join {
    var buffer: [path_platform.path_bytes_max]u8 = undefined;
    const length = try join(&buffer, .{ .base = "/project/src", .relative = "../build.zig" });
    const outgrown: Join = .{ .base = "/project", .relative = "build.zig" };

    try std.testing.expectEqualStrings("/project/build.zig", buffer[0..length]);
    try std.testing.expectError(error.Overflow, join(buffer[0..4], outgrown));
}

test directory_of {
    try std.testing.expectEqualStrings("/project/src", directory_of("/project/src/main.rs"));
    try std.testing.expectEqualStrings("/", directory_of("/main.rs"));
    try std.testing.expectEqualStrings(".", directory_of("main.rs"));
}

test file_name {
    try std.testing.expectEqualStrings("main.rs", file_name("/project/src/main.rs"));
    try std.testing.expectEqualStrings("src", file_name("project/src/"));
    try std.testing.expectEqualStrings("", file_name("/"));
}

test order {
    try std.testing.expectEqual(std.math.Order.lt, order("./a/x.html", "./a-b/x.html"));
    try std.testing.expectEqual(std.math.Order.lt, order("./a", "./a/b"));
    try std.testing.expectEqual(std.math.Order.gt, order("./b", "./a/b"));
    try std.testing.expectEqual(std.math.Order.eq, order("a//b", "a/b"));
    try std.testing.expectEqual(std.math.Order.eq, order("a/./b", "a/b"));
    try std.testing.expectEqual(std.math.Order.lt, order("./a", "a"));
    try std.testing.expectEqual(std.math.Order.lt, order("/a", "./a"));
    try std.testing.expectEqual(std.math.Order.lt, order("../a", "a"));
    try std.testing.expectEqual(std.math.Order.eq, order("", ""));
    try std.testing.expectEqual(std.math.Order.lt, order("", "a"));
}

test Components {
    var components: Components = .of("./a/../b");
    const current = components.next().?;
    const first = components.next().?;
    const parent = components.next().?;
    const second = components.next().?;
    const ended = components.next();

    try std.testing.expectEqual(Component.Kind.current, current.kind);
    try std.testing.expectEqualStrings("a", first.text);
    try std.testing.expectEqual(Component.Kind.parent, parent.kind);
    try std.testing.expectEqualStrings("b", second.text);
    try std.testing.expectEqual(null, ended);
}
