const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Buffer = @import("../stdx/bounded/buffer.zig");
const StaticAllocator = @import("../stdx/static_allocator.zig");

buffer: Buffer,
colored: bool,
failed: bool,
silent: bool,
target: Target,
truncated: bool,

const Terminal = @This();

pub const Color = enum {
    always,
    auto,
    never,

    pub fn of(name: []const u8) ?Color {
        assert(name.len <= std.math.maxInt(u32));

        const names = std.StaticStringMap(Color).initComptime(.{
            .{ "always", .always },
            .{ "auto", .auto },
            .{ "never", .never },
        });

        const found = names.get(name);

        if (found) |held| assert(std.mem.eql(u8, @tagName(held), name));

        return found;
    }

    pub fn resolved(color: Color, environment: *const Environment) bool {
        switch (color) {
            .always => return true,
            .never => return false,
            .auto => {},
        }

        assert(color == .auto);

        if (environment.force_color) |forced| return forced.len > 0;

        if (environment.no_color) |value| {
            if (value.len > 0) return false;
        }

        if (environment.term) |value| {
            if (std.mem.eql(u8, value, terminal_dumb)) return false;
        }

        return environment.terminal;
    }

    pub fn resolved_in(
        color: Color,
        io: std.Io,
        variables: *const std.process.Environ.Map,
    ) bool {
        const terminal = std.Io.File.stdout().isTty(io) catch false;

        const result = color.resolved(&.{
            .force_color = variables.get("FORCE_COLOR"),
            .no_color = variables.get("NO_COLOR"),
            .term = variables.get("TERM"),
            .terminal = terminal,
        });

        if (color == .always) assert(result);
        if (color == .never) assert(!result);

        return result;
    }

    pub const Environment = struct {
        force_color: ?[]const u8,
        no_color: ?[]const u8,
        term: ?[]const u8,
        terminal: bool,
    };
};

pub const Link = struct {
    text: []const u8,
    url: []const u8,
};

pub const Options = struct {
    buffer_bytes_max: u32,
    colored: bool = false,
    target: Target,
};

pub const Target = union(enum) {
    file: File,
    memory,
    stderr: std.Io,
    stdout: std.Io,

    pub const File = struct {
        handle: std.Io.File,
        io: std.Io,
    };
};

pub const Sink = struct {
    terminal: *Terminal,
    writer: std.Io.Writer,

    pub fn init(terminal: *Terminal, buffer: []u8) Sink {
        assert(buffer.len <= std.math.maxInt(u32));

        return .{
            .terminal = terminal,
            .writer = .{ .buffer = buffer, .vtable = &.{ .drain = drain } },
        };
    }

    fn drain(
        writer: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const sink: *Sink = @alignCast(@fieldParentPtr("writer", writer));

        assert(data.len > 0);
        assert(splat <= format_splat_max);

        sink.terminal.push(writer.buffered());
        writer.end = 0;

        var written: usize = 0;

        for (data[0 .. data.len - 1]) |bytes| {
            sink.terminal.push(bytes);
            written += bytes.len;
        }

        const pattern = data[data.len - 1];

        for (0..splat) |_| {
            sink.terminal.push(pattern);
            written += pattern.len;
        }

        return written;
    }
};

pub const blue = "\x1b[34m";
pub const bold = "\x1b[1m";
pub const cyan = "\x1b[36m";
pub const green = "\x1b[32m";
pub const red = "\x1b[31m";
pub const reset = "\x1b[0m";
pub const yellow = "\x1b[33m";
const format_chunk_bytes: u32 = 256;
const format_splat_max: u32 = 1 << 16;
const hyperlink_close = "\x1b]8;;\x1b\\";
const hyperlink_open = "\x1b]8;;";
const hyperlink_separator = "\x1b\\";
const terminal_dumb = "dumb";

pub fn init(gpa: std.mem.Allocator, options: *const Options) std.mem.Allocator.Error!Terminal {
    assert(options.buffer_bytes_max > 0);

    const buffer = try Buffer.init(gpa, options.buffer_bytes_max);

    assert(buffer.capacity() == options.buffer_bytes_max);

    return .{
        .buffer = buffer,
        .colored = options.colored,
        .failed = false,
        .silent = false,
        .target = options.target,
        .truncated = false,
    };
}

pub fn deinit(terminal: *Terminal, gpa: std.mem.Allocator) void {
    assert(terminal.buffer.capacity() > 0);

    terminal.buffer.deinit(gpa);
    terminal.* = undefined;
}

pub fn push(terminal: *Terminal, text: []const u8) void {
    assert(text.len <= std.math.maxInt(u32));

    defer if (terminal.silent) assert(terminal.buffer.empty());

    assert(terminal.buffer.capacity() > 0);

    if (terminal.failed) return;
    if (terminal.silent) return;

    terminal.buffer.push(text) catch |err| switch (err) {
        error.Overflow => terminal.push_spilled(text),
    };
}

fn push_spilled(terminal: *Terminal, text: []const u8) void {
    assert(!terminal.failed);
    assert(!terminal.silent);
    assert(text.len <= std.math.maxInt(u32));

    terminal.flush();

    if (terminal.failed) return;

    terminal.buffer.push(text) catch |err| switch (err) {
        error.Overflow => terminal.push_long(text),
    };
}

fn push_long(terminal: *Terminal, text: []const u8) void {
    assert(!terminal.failed);
    assert(!terminal.silent);
    assert(text.len <= std.math.maxInt(u32));

    switch (terminal.target) {
        .file => |file| terminal.write_all(file.handle, file.io, text),
        .memory => terminal.truncated = true,
        .stderr => |held| terminal.write_all(std.Io.File.stderr(), held, text),
        .stdout => |held| terminal.write_all(std.Io.File.stdout(), held, text),
    }
}

pub fn flush(terminal: *Terminal) void {
    defer if (terminal.target != .memory) assert(terminal.buffer.empty());

    if (terminal.buffer.empty()) return;

    if (terminal.failed) {
        terminal.buffer.clear();

        return;
    }

    const held = terminal.buffer.const_slice();

    switch (terminal.target) {
        .file => |file| terminal.write_all(file.handle, file.io, held),
        .memory => return,
        .stderr => |target_io| terminal.write_all(std.Io.File.stderr(), target_io, held),
        .stdout => |target_io| terminal.write_all(std.Io.File.stdout(), target_io, held),
    }

    terminal.buffer.clear();

    assert(terminal.buffer.empty());
}

fn write_all(terminal: *Terminal, file: std.Io.File, target_io: std.Io, bytes: []const u8) void {
    assert(!terminal.failed);
    if (builtin.target.os.tag != .windows) assert(file.handle >= 0);
    assert(terminal.target != .memory);
    assert(bytes.len <= std.math.maxInt(u32));

    file.writeStreamingAll(target_io, bytes) catch {
        terminal.failed = true;
    };
}

pub fn push_format(terminal: *Terminal, comptime format: []const u8, arguments: anytype) void {
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    var chunk: [format_chunk_bytes]u8 = undefined;
    var sink: Sink = .init(terminal, &chunk);

    sink.writer.print(format, arguments) catch unreachable;
    sink.writer.flush() catch unreachable;

    assert(sink.writer.end == 0);
}

pub fn push_line(terminal: *Terminal, comptime format: []const u8, arguments: anytype) void {
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    defer if (terminal.silent) assert(terminal.buffer.empty());

    comptime assert(format.len > 0);

    terminal.push_format(format, arguments);
    terminal.push("\n");
}

pub fn hyperlink(terminal: *Terminal, link: *const Link) void {
    assert(link.url.len > 0);
    assert(terminal.buffer.capacity() > 0);

    if (!terminal.colored) {
        terminal.push(link.text);

        return;
    }

    terminal.push(hyperlink_open);
    terminal.push(link.url);
    terminal.push(hyperlink_separator);
    terminal.push(link.text);
    terminal.push(hyperlink_close);
}

pub fn painted(terminal: *Terminal, text: []const u8, codes: []const []const u8) void {
    assert(codes.len > 0);
    assert(text.len <= std.math.maxInt(u32));

    if (!terminal.colored) {
        terminal.push(text);

        return;
    }

    for (codes) |code| {
        assert(code.len > 0);

        terminal.push(code);
    }

    terminal.push(text);
    terminal.push(reset);
}

pub fn clear(terminal: *Terminal) void {
    terminal.buffer.clear();
    terminal.truncated = false;

    assert(terminal.buffer.empty());
}

pub fn silence(terminal: *Terminal) void {
    terminal.buffer.clear();
    terminal.silent = true;

    assert(terminal.is_silent());
    assert(terminal.empty());
}

pub fn capacity(terminal: *const Terminal) u32 {
    const held = terminal.buffer.capacity();

    assert(held > 0);
    assert(terminal.buffer.count() <= held);

    return held;
}

pub fn contents(terminal: *const Terminal) []const u8 {
    const result = terminal.buffer.const_slice();

    assert(result.len <= terminal.buffer.capacity());

    if (terminal.silent) assert(result.len == 0);

    return result;
}

pub fn empty(terminal: *const Terminal) bool {
    const result = terminal.buffer.empty();

    if (terminal.silent) assert(result);

    return result;
}

pub fn io_of(terminal: *const Terminal) std.Io {
    assert(terminal.target != .memory);
    assert(terminal.buffer.capacity() > 0);

    return switch (terminal.target) {
        .file => |file| file.io,
        .memory => unreachable,
        .stderr, .stdout => |held| held,
    };
}

pub fn is_colored(terminal: *const Terminal) bool {
    assert(terminal.buffer.capacity() > 0);

    return terminal.colored;
}

pub fn is_failed(terminal: *const Terminal) bool {
    assert(terminal.buffer.capacity() > 0);
    if (terminal.failed) assert(terminal.target != .memory);

    return terminal.failed;
}

pub fn is_silent(terminal: *const Terminal) bool {
    if (terminal.silent) assert(terminal.buffer.empty());

    return terminal.silent;
}

pub fn is_truncated(terminal: *const Terminal) bool {
    assert(terminal.buffer.capacity() > 0);
    if (terminal.truncated) assert(terminal.target == .memory);

    return terminal.truncated;
}

const test_bytes_max: u32 = 32;

fn test_memory(gpa: std.mem.Allocator, buffer_bytes_max: u32, colored: bool) !Terminal {
    assert(buffer_bytes_max < std.math.maxInt(u32));

    return Terminal.init(gpa, &.{
        .buffer_bytes_max = buffer_bytes_max,
        .colored = colored,
        .target = .memory,
    });
}

fn test_resolved(
    color: Color,
    force_color: ?[]const u8,
    no_color: ?[]const u8,
    term: ?[]const u8,
    terminal: bool,
) bool {
    if (force_color) |held| assert(held.len <= std.math.maxInt(u32));
    if (no_color) |held| assert(held.len <= std.math.maxInt(u32));
    if (term) |held| assert(held.len <= std.math.maxInt(u32));

    return color.resolved(&.{
        .force_color = force_color,
        .no_color = no_color,
        .term = term,
        .terminal = terminal,
    });
}

test Terminal {
    const gpa = std.testing.allocator;
    var out: Terminal = try .init(gpa, &.{ .buffer_bytes_max = 64, .target = .memory });
    defer out.deinit(gpa);

    out.push("checked ");
    out.push_line("{d} files", .{3});
    out.painted("clean", &.{ bold, green });

    try std.testing.expectEqualStrings("checked 3 files\nclean", out.contents());
    try std.testing.expectEqual(@as(u32, 64), out.capacity());
    try std.testing.expect(!out.is_truncated());
}

test "a memory terminal keeps what fits and marks the spill" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    const gpa = static_allocator.allocator();
    var out = try test_memory(gpa, test_bytes_max, false);
    defer out.deinit(gpa);

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    out.push("0123456789abcdef");
    out.push("0123456789abcdef");

    try std.testing.expect(!out.is_truncated());

    out.push("x");

    try std.testing.expect(out.is_truncated());
}

test "a failed write latches and the rest is dropped" {
    const test_io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    const created = try temporary.dir.createFile(test_io, "unwritable", .{});

    created.close(test_io);

    const full = try temporary.dir.openFile(test_io, "unwritable", .{ .mode = .read_only });
    defer full.close(test_io);

    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    const gpa = static_allocator.allocator();

    var out = try Terminal.init(gpa, &.{
        .buffer_bytes_max = test_bytes_max,
        .target = .{ .file = .{ .handle = full, .io = test_io } },
    });

    defer out.deinit(gpa);

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    out.push("0123456789abcdef0123456789abcdef");

    try std.testing.expect(!out.is_failed());

    out.push("x");

    try std.testing.expect(out.is_failed());
    try std.testing.expect(out.empty());

    out.push("y");
    out.flush();

    try std.testing.expect(out.empty());
    try std.testing.expect(out.io_of().vtable == test_io.vtable);
}

test "a silenced terminal drops every push" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    const gpa = static_allocator.allocator();
    var out = try test_memory(gpa, test_bytes_max, false);
    defer out.deinit(gpa);

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    out.push("kept");
    out.silence();
    out.push("dropped");

    try std.testing.expect(out.empty());
    try std.testing.expect(out.is_silent());
}

test "paint is only written when the terminal is colored" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    const gpa = static_allocator.allocator();
    var plain = try test_memory(gpa, test_bytes_max, false);
    defer plain.deinit(gpa);

    var colored = try test_memory(gpa, test_bytes_max, true);
    defer colored.deinit(gpa);

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    plain.painted("x", &.{ bold, red });
    colored.painted("x", &.{ bold, red });

    try std.testing.expectEqualStrings("x", plain.contents());
    try std.testing.expectEqualStrings(bold ++ red ++ "x" ++ reset, colored.contents());
}

test "a hyperlink wraps its text in the osc 8 sequence" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    const gpa = static_allocator.allocator();
    var out = try test_memory(gpa, 64, true);
    defer out.deinit(gpa);

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    out.hyperlink(&.{ .text = "t", .url = "u" });

    try std.testing.expectEqualStrings("\x1b]8;;u\x1b\\t\x1b]8;;\x1b\\", out.contents());
}

test "the color switch is resolved in order" {
    const blank: []const u8 = "";
    const set: []const u8 = "1";
    const dumb: []const u8 = "dumb";

    try std.testing.expect(test_resolved(.always, null, set, null, false));
    try std.testing.expect(!test_resolved(.never, set, null, null, true));
    try std.testing.expect(test_resolved(.auto, set, set, null, false));
    try std.testing.expect(!test_resolved(.auto, blank, null, null, true));
    try std.testing.expect(!test_resolved(.auto, null, set, null, true));
    try std.testing.expect(test_resolved(.auto, null, blank, null, true));
    try std.testing.expect(!test_resolved(.auto, null, null, dumb, true));
    try std.testing.expect(test_resolved(.auto, null, null, null, true));
    try std.testing.expect(!test_resolved(.auto, null, null, null, false));
    try std.testing.expectEqual(@as(?Color, .always), Color.of("always"));
    try std.testing.expectEqual(@as(?Color, null), Color.of("sometimes"));
}
