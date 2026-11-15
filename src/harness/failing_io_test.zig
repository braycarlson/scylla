const std = @import("std");
const Cache = @import("../platform/cache.zig");
const FileWalk = @import("../platform/file_walk.zig");
const Terminal = @import("../cli/terminal.zig");
const path = @import("../platform/path.zig");

test "the tooling degrades under an io where every operation fails" {
    const gpa = std.testing.allocator;
    const io = std.Io.failing;

    var walk = try FileWalk.init(gpa, .{
        .arena_bytes_max = 1 << 12,
        .depth_max = 8,
        .entry_count_max = 64,
        .pending_max = 64,
    });

    defer walk.deinit(gpa);

    const outcome = walk.run(io, "src", &.{ .excludes = null, .ignores = null, .skipped = &.{} });

    try std.testing.expectError(error.Unopenable, outcome);
    try std.testing.expectEqual(0, walk.count());
    try std.testing.expect(path.stat_of(io, "src/scylla.zig") == null);

    var cache = try Cache.init(gpa, .{
        .entry_count_max = 16,
        .file_bytes_max = 1 << 12,
        .path_bytes_max = 256,
    }, "failing");

    defer cache.deinit(gpa);

    try std.testing.expectError(error.Unexpected, cache.open(io, "failing-cache", 7, "failing"));
    try std.testing.expectError(error.Unexpected, cache.persist(io));
    try std.testing.expectEqual(0, cache.entries.count());

    var terminal = try Terminal.init(gpa, &.{
        .buffer_bytes_max = 64,
        .colored = false,
        .target = .{ .stdout = io },
    });

    defer terminal.deinit(gpa);

    terminal.push("held\n");
    terminal.flush();

    try std.testing.expect(terminal.failed);
}
