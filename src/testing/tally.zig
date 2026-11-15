const std = @import("std");
const assert = std.debug.assert;
const environment = @import("environment.zig");
const line_bytes_max = 4096;
const tally_variable = "SCYLLA_TALLY";

pub fn agree(suite: []const u8, test_name: []const u8, name: []const u8) !void {
    assert(name.len <= std.math.maxInt(u32));

    const io = std.testing.io;

    assert(suite.len > 0);
    assert(test_name.len > 0);

    var path_bytes: [environment.value_bytes_max]u8 = undefined;
    const path = environment.get(tally_variable, &path_bytes) orelse return;
    var buffer: [line_bytes_max]u8 = undefined;
    const line = try std.mem.print(&buffer, "{s}/{s}\t{s}\n", .{ suite, test_name, name });

    assert(line.len > suite.len + test_name.len);

    const flags: std.Io.Dir.CreateFileOptions = .{ .truncate = false, .lock = .exclusive };
    const file = try std.Io.Dir.cwd().createFile(io, path, flags);
    defer file.close(io);

    const end = try file.length(io);

    try file.writePositionalAll(io, line, end);
}
