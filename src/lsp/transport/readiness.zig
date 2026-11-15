const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const windows = std.os.windows;

pub const Readiness = enum {
    data,
    end,
    idle,

    pub fn poll(file: std.Io.File) Readiness {
        if (builtin.target.os.tag != .windows) assert(file.handle >= 0);

        return switch (builtin.target.os.tag) {
            .windows => poll_windows(file.handle),
            else => poll_posix(file.handle),
        };
    }

    fn poll_posix(handle: std.posix.fd_t) Readiness {
        var polled = [1]std.posix.pollfd{.{
            .fd = handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};

        const ready_count = std.posix.poll(&polled, 0) catch return .idle;

        assert(ready_count <= polled.len);

        if (ready_count == 0) return .idle;

        const events = polled[0].revents;

        assert(events != 0);

        if (events & std.posix.POLL.IN != 0) return .data;
        if (events & std.posix.POLL.HUP != 0) return .end;
        return .data;
    }

    fn poll_windows(handle: windows.HANDLE) Readiness {
        assert(handle != windows.INVALID_HANDLE_VALUE);

        switch (GetFileType(handle)) {
            file_type_disk => return .data,
            file_type_pipe => {},
            else => return .idle,
        }

        var available: windows.DWORD = 0;
        const peeked = PeekNamedPipe(handle, null, 0, null, &available, null).toBool();

        if (!peeked) {
            assert(available == 0);

            return switch (windows.GetLastError()) {
                .BROKEN_PIPE => .end,
                else => .idle,
            };
        }

        return if (available > 0) .data else .idle;
    }
};

const file_type_disk: windows.DWORD = 1;
const file_type_pipe: windows.DWORD = 3;

extern "kernel32" fn GetFileType(file: windows.HANDLE) callconv(.winapi) windows.DWORD;

extern "kernel32" fn PeekNamedPipe(
    pipe: windows.HANDLE,
    buffer: ?*anyopaque,
    buffer_size: windows.DWORD,
    read_bytes: ?*windows.DWORD,
    available_bytes: ?*windows.DWORD,
    left_bytes: ?*windows.DWORD,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn CreatePipe(
    read_pipe: *windows.HANDLE,
    write_pipe: *windows.HANDLE,
    attributes: ?*anyopaque,
    size: windows.DWORD,
) callconv(.winapi) windows.BOOL;

const blocking: std.Io.File.Flags = .{ .nonblocking = false };

const TestPipe = struct {
    reading: std.Io.File,
    writing: ?std.Io.File,

    fn open() !TestPipe {
        if (builtin.target.os.tag == .windows) {
            var reading: windows.HANDLE = undefined;
            var writing: windows.HANDLE = undefined;
            if (!CreatePipe(&reading, &writing, null, 0).toBool()) return error.PipeRefused;

            const reading_file: std.Io.File = .{ .handle = reading, .flags = blocking };
            const writing_file: std.Io.File = .{ .handle = writing, .flags = blocking };

            return .{ .reading = reading_file, .writing = writing_file };
        }

        const handles = try std.Io.Threaded.pipe2(.{});

        return .{
            .reading = .{ .handle = handles[0], .flags = blocking },
            .writing = .{ .handle = handles[1], .flags = blocking },
        };
    }

    fn close_writing(pipe: *TestPipe) void {
        const writing = pipe.writing orelse unreachable;

        writing.close(std.testing.io);
        pipe.writing = null;
    }

    fn close(pipe: *TestPipe) void {
        if (pipe.writing) |writing| writing.close(std.testing.io);

        pipe.reading.close(std.testing.io);
        pipe.* = undefined;
    }
};

test "a pipe reads idle until written, then data, then ended once drained and closed" {
    var pipe: TestPipe = try .open();
    defer pipe.close();

    try std.testing.expectEqual(Readiness.idle, Readiness.poll(pipe.reading));

    try pipe.writing.?.writeStreamingAll(std.testing.io, "a");

    try std.testing.expectEqual(Readiness.data, Readiness.poll(pipe.reading));

    pipe.close_writing();

    try std.testing.expectEqual(Readiness.data, Readiness.poll(pipe.reading));

    var byte: [1]u8 = undefined;
    const read_count = try pipe.reading.readStreaming(std.testing.io, &.{&byte});

    try std.testing.expectEqual(1, read_count);
    try std.testing.expectEqual(Readiness.end, Readiness.poll(pipe.reading));
}
