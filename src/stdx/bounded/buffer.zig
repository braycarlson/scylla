const std = @import("std");
const assert = std.debug.assert;
const Span = @import("span.zig");
const StaticAllocator = @import("../static_allocator.zig");

allocated: bool,
bytes: []u8,
length: u32,

const Buffer = @This();
pub const CapacityError = error{Overflow};
pub const Error = CapacityError || ReadError;
pub const ReadError = error{ReadFailed};

pub const Writer = struct {
    buffer: *Buffer,
    interface: std.Io.Writer,

    fn drain(
        interface: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const appended: *Writer = @alignCast(@fieldParentPtr("interface", interface));
        var written_count: usize = 0;

        assert(interface.end == 0);
        assert(data.len > 0);

        for (data[0 .. data.len - 1]) |bytes| written_count += try appended.part_push(bytes);

        const pattern = data[data.len - 1];
        if (pattern.len == 0) return written_count;

        for (0..splat) |_| written_count += try appended.part_push(pattern);

        return written_count;
    }

    fn part_push(appended: *Writer, bytes: []const u8) std.Io.Writer.Error!usize {
        assert(bytes.len <= std.math.maxInt(u32));

        const room = appended.buffer.capacity() - appended.buffer.count();
        const taken: usize = @min(room, bytes.len);

        appended.buffer.push(bytes[0..taken]) catch unreachable;

        if (taken < bytes.len) return error.WriteFailed;
        return taken;
    }
};

pub fn init(gpa: std.mem.Allocator, capacity_max: u32) std.mem.Allocator.Error!Buffer {
    assert(capacity_max > 0);

    const bytes = try StaticAllocator.reserve(u8, gpa, capacity_max);

    assert(bytes.len == capacity_max);

    return .{ .allocated = true, .bytes = bytes, .length = 0 };
}

pub fn init_storage(storage: []u8) Buffer {
    assert(storage.len > 0);
    assert(storage.len <= std.math.maxInt(u32));

    return .{ .allocated = false, .bytes = storage, .length = 0 };
}

pub fn deinit(buffer: *Buffer, gpa: std.mem.Allocator) void {
    assert(buffer.allocated);
    assert(buffer.length <= buffer.bytes.len);
    assert(buffer.bytes.len > 0);

    StaticAllocator.release(u8, gpa, buffer.bytes);
    buffer.* = undefined;
}

pub fn capacity(buffer: *const Buffer) u32 {
    assert(buffer.length <= buffer.bytes.len);
    assert(buffer.bytes.len > 0);

    return @intCast(buffer.bytes.len);
}

pub fn clear(buffer: *Buffer) void {
    assert(buffer.length <= buffer.bytes.len);

    buffer.length = 0;

    assert(buffer.empty());
}

pub fn const_slice(buffer: *const Buffer) []const u8 {
    assert(buffer.length <= buffer.bytes.len);
    assert(buffer.bytes.len > 0);

    return buffer.bytes[0..buffer.length];
}

pub fn count(buffer: *const Buffer) u32 {
    assert(buffer.length <= buffer.bytes.len);
    assert(buffer.bytes.len > 0);

    return buffer.length;
}

pub fn empty(buffer: *const Buffer) bool {
    assert(buffer.length <= buffer.bytes.len);
    assert(buffer.bytes.len > 0);

    return buffer.length == 0;
}

pub fn flatten(buffer: *Buffer, start: u32) u32 {
    assert(start <= buffer.length);

    const bytes = buffer.bytes[0..buffer.length];
    var write: u32 = start;
    var spaced = false;

    for (bytes[start..]) |byte| {
        const blank = std.mem.findScalar(u8, " \t\n\r", byte) != null;

        if (blank) {
            spaced = write > start;

            continue;
        }

        if (spaced) {
            bytes[write] = ' ';
            write += 1;
            spaced = false;
        }

        bytes[write] = byte;
        write += 1;
    }

    buffer.length = write;

    assert(buffer.length >= start);

    return write - start;
}

pub fn line_endings_unify(buffer: *Buffer, start: u32) u32 {
    assert(start <= buffer.length);

    const bytes = buffer.bytes[0..buffer.length];
    var write: u32 = start;

    for (bytes[start..], start..) |byte, position| {
        if (byte == '\r') {
            if (position + 1 < bytes.len) {
                if (bytes[position + 1] == '\n') continue;
            }
        }

        bytes[write] = byte;
        write += 1;
    }

    buffer.length = write;

    assert(buffer.length >= start);

    return write - start;
}

pub fn intern(buffer: *Buffer, bytes: []const u8) CapacityError!Span {
    assert(bytes.len > 0);

    if (bytes.len > buffer.bytes.len - buffer.length) return error.Overflow;

    const span: Span = .{ .offset = buffer.length, .length = @intCast(bytes.len) };

    @memcpy(buffer.bytes[span.offset..][0..bytes.len], bytes);
    buffer.length += span.length;

    assert(buffer.length <= buffer.bytes.len);
    assert(std.mem.eql(u8, buffer.slice_of(span), bytes));

    return span;
}

pub fn patch(buffer: *Buffer, offset: u32, bytes: []const u8) void {
    assert(offset <= buffer.length);
    assert(bytes.len <= buffer.length - offset);

    @memcpy(buffer.bytes[offset..][0..bytes.len], bytes);

    assert(buffer.length <= buffer.bytes.len);
}

pub fn print(buffer: *Buffer, comptime format: []const u8, arguments: anytype) CapacityError!void {
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");
    assert(buffer.length <= buffer.bytes.len);

    const start = buffer.length;

    buffer.print_pieces(format, arguments) catch |err| switch (err) {
        error.Overflow => {
            buffer.truncate(start);

            return error.Overflow;
        },
    };

    assert(buffer.length >= start);
}

pub fn print_pieces(
    buffer: *Buffer,
    comptime format: []const u8,
    arguments: anytype,
) CapacityError!void {
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    const start = buffer.length;

    var formatting: std.Io.Writer = .{
        .vtable = &.{ .drain = std.Io.Writer.failingDrain },
        .buffer = buffer.bytes[start..],
        .end = 0,
    };

    const outcome = formatting.print(format, arguments);

    buffer.length += @intCast(formatting.end);

    assert(buffer.length <= buffer.bytes.len);
    assert(buffer.length - start == formatting.end);

    outcome catch |err| switch (err) {
        error.WriteFailed => return error.Overflow,
    };
}

pub fn push(buffer: *Buffer, bytes: []const u8) CapacityError!void {
    if (bytes.len > buffer.bytes.len - buffer.length) return error.Overflow;

    const start = buffer.length;

    @memcpy(buffer.bytes[start..][0..bytes.len], bytes);
    buffer.length += @intCast(bytes.len);

    assert(buffer.length <= buffer.bytes.len);
    assert(buffer.length - start == bytes.len);
}

pub fn push_byte(buffer: *Buffer, byte: u8) CapacityError!void {
    if (buffer.length == buffer.bytes.len) return error.Overflow;

    buffer.bytes[buffer.length] = byte;
    buffer.length += 1;

    assert(buffer.length <= buffer.bytes.len);
}

pub fn append_from(buffer: *Buffer, reader: *std.Io.Reader) Error!void {
    const prior_length = buffer.length;

    try read_fill(reader, buffer.bytes, &buffer.length);

    assert(buffer.length >= prior_length);
    assert(buffer.length <= buffer.bytes.len);
}

pub fn read_from(buffer: *Buffer, reader: *std.Io.Reader) Error!void {
    buffer.length = 0;

    try read_fill(reader, buffer.bytes, &buffer.length);

    assert(buffer.length <= buffer.bytes.len);
}

fn read_exact_from(
    buffer: *Buffer,
    reader: *std.Io.Reader,
    length: u32,
) error{ EndOfStream, Overflow, ReadFailed }!void {
    assert(buffer.length <= buffer.bytes.len);

    if (length > buffer.bytes.len) return error.Overflow;

    buffer.length = 0;

    try reader.readSliceAll(buffer.bytes[0..length]);

    buffer.length = length;

    assert(buffer.count() == length);
}

fn read_into(reader: *std.Io.Reader, target: []u8) Error!u32 {
    assert(target.len <= std.math.maxInt(u32));

    var filled: u32 = 0;

    try read_fill(reader, target, &filled);

    assert(filled <= target.len);

    return filled;
}

fn read_fill(reader: *std.Io.Reader, target: []u8, filled: *u32) Error!void {
    assert(target.len <= std.math.maxInt(u32));
    assert(filled.* <= target.len);

    const step_count_max = 2 * target.len + 2;

    for (0..step_count_max) |_| {
        if (filled.* == target.len) {
            var probe: [1]u8 = undefined;
            const extra = try reader.readSliceShort(&probe);
            if (extra > 0) return error.Overflow;
            return;
        }

        var data: [1][]u8 = .{target[filled.*..]};

        const length = reader.readVec(&data) catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => return error.ReadFailed,
        };

        assert(length <= target.len - filled.*);

        filled.* += @intCast(length);
    }

    return error.Overflow;
}

pub fn slice_of(buffer: *const Buffer, span: Span) []const u8 {
    assert(buffer.length <= buffer.bytes.len);
    assert(span.end() <= buffer.length);

    return buffer.bytes[span.offset..span.end()];
}

pub fn splice(buffer: *Buffer, removed: Span, inserted: []const u8) CapacityError!void {
    assert(removed.end() <= buffer.length);
    assert(inserted.len <= std.math.maxInt(u32));

    const length = @as(usize, buffer.length) - removed.length + inserted.len;
    if (length > buffer.bytes.len) return error.Overflow;

    const tail = buffer.bytes[removed.end()..buffer.length];
    const target = removed.offset + inserted.len;

    @memmove(buffer.bytes[target..][0..tail.len], tail);

    @memcpy(buffer.bytes[removed.offset..][0..inserted.len], inserted);
    buffer.length = @intCast(length);

    assert(buffer.length <= buffer.bytes.len);
}

pub fn truncate(buffer: *Buffer, length: u32) void {
    assert(length <= buffer.length);

    buffer.length = length;

    assert(buffer.count() == length);
}

pub fn writer(buffer: *Buffer) Writer {
    assert(buffer.length <= buffer.bytes.len);

    return .{
        .buffer = buffer,
        .interface = .{
            .buffer = &.{},
            .end = 0,
            .vtable = &.{ .drain = Writer.drain },
        },
    };
}

pub fn written(target: []u8, parts: []const []const u8) CapacityError!u32 {
    assert(target.len <= std.math.maxInt(u32));
    assert(parts.len <= std.math.maxInt(u32));

    var length: usize = 0;

    for (parts) |part| {
        if (part.len > target.len - length) return error.Overflow;

        @memcpy(target[length..][0..part.len], part);
        length += part.len;
    }

    assert(length <= target.len);

    return @intCast(length);
}

const Chunked = struct {
    bytes: []const u8,
    offset: usize,
    step: usize,
    widths: []const usize,
    interface: std.Io.Reader,

    fn init(bytes: []const u8, widths: []const usize) Chunked {
        assert(bytes.len > 0);
        assert(widths.len > 0);

        return .{
            .bytes = bytes,
            .offset = 0,
            .step = 0,
            .widths = widths,
            .interface = .{
                .vtable = &.{ .stream = chunked_stream },
                .buffer = &.{},
                .seek = 0,
                .end = 0,
            },
        };
    }
};

const Failure = enum { broken_pipe, interrupted };

const Failing = struct {
    bytes: []const u8,
    failure: Failure,
    limit: usize,
    offset: usize,
    raised: ?Failure,
    interface: std.Io.Reader,

    fn init(bytes: []const u8, failure: Failure, limit: usize) Failing {
        assert(limit <= bytes.len);

        return .{
            .bytes = bytes,
            .failure = failure,
            .limit = limit,
            .offset = 0,
            .raised = null,
            .interface = .{
                .vtable = &.{ .stream = failing_stream },
                .buffer = &.{},
                .seek = 0,
                .end = 0,
            },
        };
    }
};

fn chunked_stream(
    reader: *std.Io.Reader,
    out: *std.Io.Writer,
    limit: std.Io.Limit,
) std.Io.Reader.StreamError!usize {
    const chunked: *Chunked = @alignCast(@fieldParentPtr("interface", reader));

    assert(chunked.offset <= chunked.bytes.len);
    assert(limit.toInt() != 0);

    const remaining = chunked.bytes.len - chunked.offset;
    if (remaining == 0) return error.EndOfStream;

    const width = limit.minInt(@min(chunked.widths[chunked.step % chunked.widths.len], remaining));

    chunked.step += 1;

    try out.writeAll(chunked.bytes[chunked.offset..][0..width]);
    chunked.offset += width;

    assert(chunked.offset <= chunked.bytes.len);

    return width;
}

fn failing_stream(
    reader: *std.Io.Reader,
    out: *std.Io.Writer,
    limit: std.Io.Limit,
) std.Io.Reader.StreamError!usize {
    const failing: *Failing = @alignCast(@fieldParentPtr("interface", reader));

    assert(failing.offset <= failing.limit);
    assert(failing.limit <= failing.bytes.len);

    if (failing.offset == failing.limit) {
        if (failing.raised == null) {
            failing.raised = failing.failure;

            return error.ReadFailed;
        }
    }

    const width = limit.minInt(failing.limit - failing.offset);
    if (width == 0) return error.EndOfStream;

    try out.writeAll(failing.bytes[failing.offset..][0..width]);
    failing.offset += width;

    assert(failing.offset <= failing.limit);

    return width;
}

test Buffer {
    const gpa = std.testing.allocator;
    var buffer: Buffer = try .init(gpa, 16);
    defer buffer.deinit(gpa);

    try buffer.push("linter");
    try buffer.print(" {d} lints", .{3});
    try std.testing.expectEqualStrings("linter 3 lints", buffer.const_slice());
    try std.testing.expectError(error.Overflow, buffer.push("past the end"));
    try std.testing.expectEqualStrings("linter 3 lints", buffer.const_slice());

    var storage: [4]u8 = undefined;
    var lent: Buffer = .init_storage(&storage);

    try lent.push("tool");
    try std.testing.expectError(error.Overflow, lent.push_byte('s'));
    try std.testing.expectEqualStrings("tool", lent.const_slice());
}

test writer {
    var storage: [64]u8 = undefined;
    var buffer: Buffer = .init_storage(&storage);
    var appending = buffer.writer();

    try buffer.push("count ");
    try appending.interface.print("{d} of {s}", .{ 7, "eight" });
    try appending.interface.splatByteAll('.', 3);

    var reference_storage: [64]u8 = undefined;
    var reference: Buffer = .init_storage(&reference_storage);

    try reference.print("count {d} of {s}...", .{ 7, "eight" });
    try std.testing.expectEqualStrings(reference.const_slice(), buffer.const_slice());
}

test "a writer fills the buffer as a fixed writer fills its slice" {
    var storage: [8]u8 = undefined;
    var buffer: Buffer = .init_storage(&storage);
    var appending = buffer.writer();
    var reference_storage: [8]u8 = undefined;
    var reference: std.Io.Writer = .fixed(&reference_storage);

    try appending.interface.writeAll("abcdef");
    try reference.writeAll("abcdef");

    const appending_written = appending.interface.writeAll("ghi");
    const reference_written = reference.writeAll("ghi");

    try std.testing.expectError(error.WriteFailed, appending_written);
    try std.testing.expectError(error.WriteFailed, reference_written);
    try std.testing.expectEqualStrings(reference.buffered(), buffer.const_slice());
    try std.testing.expectError(error.WriteFailed, appending.interface.splatByteAll('x', 3));
    try std.testing.expectEqualStrings("abcdefgh", buffer.const_slice());
}

test "a push appends to the contents" {
    var buffer = try Buffer.init(std.testing.allocator, 16);
    defer buffer.deinit(std.testing.allocator);

    try buffer.push("linter");
    try std.testing.expectEqual(@as(u32, 6), buffer.count());
    try buffer.push(" lints");
    try std.testing.expectEqualStrings("linter lints", buffer.const_slice());

    buffer.clear();

    try std.testing.expect(buffer.empty());
}

test "a truncation keeps the prefix" {
    var buffer = try Buffer.init(std.testing.allocator, 16);
    defer buffer.deinit(std.testing.allocator);

    try buffer.push("linter lints");

    buffer.truncate(6);

    try std.testing.expectEqualStrings("linter", buffer.const_slice());
    try buffer.push("s");
    try std.testing.expectEqualStrings("linters", buffer.const_slice());
}

test "a push past capacity is refused" {
    var buffer = try Buffer.init(std.testing.allocator, 4);
    defer buffer.deinit(std.testing.allocator);

    try std.testing.expectError(error.Overflow, buffer.push("linter"));
    try std.testing.expect(buffer.empty());
}

test "a splice replaces a range and keeps the tail" {
    var buffer = try Buffer.init(std.testing.allocator, 16);
    defer buffer.deinit(std.testing.allocator);

    try buffer.push("linter lints");
    try buffer.splice(.between(0, 6), "tool");
    try std.testing.expectEqualStrings("tool lints", buffer.const_slice());
    try buffer.splice(.{ .offset = 5, .length = 0 }, "that ");
    try std.testing.expectEqualStrings("tool that lints", buffer.const_slice());
    try std.testing.expectError(error.Overflow, buffer.splice(.empty, "a long prefix"));
    try std.testing.expectEqualStrings("tool that lints", buffer.const_slice());
}

test "flattening collapses every blank run" {
    var buffer = try Buffer.init(std.testing.allocator, 64);
    defer buffer.deinit(std.testing.allocator);

    try buffer.push("head: one\n    two\t\tthree  ");
    try std.testing.expectEqual(@as(u32, 19), buffer.flatten(0));
    try std.testing.expectEqualStrings("head: one two three", buffer.const_slice());
}

test "flattening leaves the prefix alone" {
    var buffer = try Buffer.init(std.testing.allocator, 64);
    defer buffer.deinit(std.testing.allocator);

    try buffer.push("kept  ");

    const start = buffer.count();

    try buffer.push("one\ntwo");

    _ = buffer.flatten(start);

    try std.testing.expectEqualStrings("kept  one two", buffer.const_slice());
}

test "unified line endings drop the carriage return before each line feed" {
    const cases = [_][]const u8{
        "one\r\ntwo\r\n",
        "one\ntwo",
        "lone\rreturn\r",
        "\r\r\n\r\n\n",
        "",
    };

    var buffer = try Buffer.init(std.testing.allocator, 64);
    defer buffer.deinit(std.testing.allocator);

    var expected: [64]u8 = undefined;

    for (cases) |case| {
        buffer.clear();

        try buffer.push("kept\r\n");

        const start = buffer.count();

        try buffer.push(case);

        const length = buffer.line_endings_unify(start);
        const replaced = std.mem.replace(u8, case, "\r\n", "\n", &expected);
        const reference = expected[0 .. case.len - replaced];

        try std.testing.expectEqual(@as(u32, @intCast(reference.len)), length);
        try std.testing.expectEqualStrings("kept\r\n", buffer.const_slice()[0..start]);
        try std.testing.expectEqualStrings(reference, buffer.const_slice()[start..]);
    }
}

test "a read fills the requested length" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var buffer: Buffer = try .init(static_allocator.allocator(), 16);
    defer buffer.deinit(static_allocator.allocator());

    var source: std.Io.Reader = .fixed("linter lints");
    var scope = static_allocator.freeze_scope();
    defer scope.leave();

    try buffer.read_exact_from(&source, 6);
    try std.testing.expectEqualStrings("linter", buffer.const_slice());
}

test "a read past capacity is refused" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var buffer: Buffer = try .init(static_allocator.allocator(), 4);
    defer buffer.deinit(static_allocator.allocator());

    var source: std.Io.Reader = .fixed("linter");
    var scope = static_allocator.freeze_scope();
    defer scope.leave();

    try std.testing.expectError(error.Overflow, buffer.read_exact_from(&source, 6));
    try std.testing.expect(buffer.empty());
}

test "a reader that answers one byte at a time still fills the buffer" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var buffer: Buffer = try .init(static_allocator.allocator(), 32);
    defer buffer.deinit(static_allocator.allocator());

    var source: Chunked = .init("linter lints", &.{1});
    var scope = static_allocator.freeze_scope();
    defer scope.leave();

    try buffer.read_from(&source.interface);
    try std.testing.expectEqualStrings("linter lints", buffer.const_slice());
}

test "an appending read keeps what the buffer held and refuses a reader past capacity" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var buffer: Buffer = try .init(static_allocator.allocator(), 12);
    defer buffer.deinit(static_allocator.allocator());

    var first: Chunked = .init("linter", &.{ 2, 1 });
    var second: std.Io.Reader = .fixed(" lints");
    var third: std.Io.Reader = .fixed("!");
    var scope = static_allocator.freeze_scope();
    defer scope.leave();

    try buffer.append_from(&first.interface);
    try buffer.append_from(&second);
    try std.testing.expectEqualStrings("linter lints", buffer.const_slice());
    try std.testing.expectError(error.Overflow, buffer.append_from(&third));
    try std.testing.expectEqual(@as(u32, 12), buffer.count());
}

test "a reader that answers in irregular chunks still fills the buffer" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var buffer: Buffer = try .init(static_allocator.allocator(), 32);
    defer buffer.deinit(static_allocator.allocator());

    var source: Chunked = .init("linter lints tigerstyle", &.{ 3, 1, 7, 2 });
    var scope = static_allocator.freeze_scope();
    defer scope.leave();

    try buffer.read_from(&source.interface);
    try std.testing.expectEqualStrings("linter lints tigerstyle", buffer.const_slice());
}

test "an interrupted read is reported rather than retried" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var buffer: Buffer = try .init(static_allocator.allocator(), 32);
    defer buffer.deinit(static_allocator.allocator());

    var source: Failing = .init("linter lints", .interrupted, 6);
    var scope = static_allocator.freeze_scope();
    defer scope.leave();

    try std.testing.expectError(error.ReadFailed, buffer.read_from(&source.interface));
    try std.testing.expectEqual(@as(?Failure, .interrupted), source.raised);
    try std.testing.expectEqualStrings("linter", buffer.const_slice());
}

test "an error partway through reaches the caller with no invented bytes" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var buffer: Buffer = try .init(static_allocator.allocator(), 32);
    defer buffer.deinit(static_allocator.allocator());

    var source: Failing = .init("linter lints", .broken_pipe, 4);
    var scope = static_allocator.freeze_scope();
    defer scope.leave();

    try std.testing.expectError(error.ReadFailed, buffer.read_from(&source.interface));
    try std.testing.expectEqual(@as(?Failure, .broken_pipe), source.raised);
    try std.testing.expectEqualStrings("lint", buffer.const_slice());
}

test "a stream longer than the buffer is refused" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var buffer: Buffer = try .init(static_allocator.allocator(), 8);
    defer buffer.deinit(static_allocator.allocator());

    var source: Chunked = .init("linter lints tigerstyle", &.{5});
    var scope = static_allocator.freeze_scope();
    defer scope.leave();

    try std.testing.expectError(error.Overflow, buffer.read_from(&source.interface));
    try std.testing.expectEqual(8, buffer.count());
}

test "a stream that exactly fills the buffer is complete" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var buffer: Buffer = try .init(static_allocator.allocator(), 12);
    defer buffer.deinit(static_allocator.allocator());

    var source: Chunked = .init("linter lints", &.{5});
    var scope = static_allocator.freeze_scope();
    defer scope.leave();

    try buffer.read_from(&source.interface);
    try std.testing.expectEqualStrings("linter lints", buffer.const_slice());
}

test "a read into a slice fills what fits and reports the rest" {
    var target: [4]u8 = @splat(0);
    var two: std.Io.Reader = .fixed("ab");
    var four: std.Io.Reader = .fixed("abcd");
    var five: std.Io.Reader = .fixed("abcde");
    var none: std.Io.Reader = .fixed("");
    var none_empty: std.Io.Reader = .fixed("");
    var one_empty: std.Io.Reader = .fixed("a");

    try std.testing.expectEqual(2, try read_into(&two, &target));
    try std.testing.expectEqualStrings("ab", target[0..2]);
    try std.testing.expectEqual(4, try read_into(&four, &target));
    try std.testing.expectEqualStrings("abcd", &target);
    try std.testing.expectError(error.Overflow, read_into(&five, &target));
    try std.testing.expectEqual(0, try read_into(&none, &target));
    try std.testing.expectEqual(0, try read_into(&none_empty, &.{}));
    try std.testing.expectError(error.Overflow, read_into(&one_empty, &.{}));
}

test "writing stops at capacity" {
    var buffer: Buffer = try .init(std.testing.allocator, 8);
    defer buffer.deinit(std.testing.allocator);

    try buffer.push("linter");
    try std.testing.expectEqual(6, buffer.count());
    try std.testing.expectError(error.Overflow, buffer.push("xyz"));
    try std.testing.expectEqualStrings("linter", buffer.const_slice());
}

test "formatting reports overflow" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var buffer: Buffer = try .init(static_allocator.allocator(), 16);
    defer buffer.deinit(static_allocator.allocator());

    var scope = static_allocator.freeze_scope();
    defer scope.leave();

    var first: u32 = 4_096;
    var second: u32 = 8_192;

    std.mem.doNotOptimizeAway(&first);
    std.mem.doNotOptimizeAway(&second);

    const printed = buffer.print_pieces("{d} of {d} bytes", .{ first, second });

    try std.testing.expectError(error.Overflow, printed);
    try std.testing.expectEqual(12, buffer.count());
}

test "clearing restores the whole capacity" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var buffer: Buffer = try .init(static_allocator.allocator(), 16);
    defer buffer.deinit(static_allocator.allocator());

    var scope = static_allocator.freeze_scope();
    defer scope.leave();

    for (0..64) |_| {
        buffer.clear();

        try std.testing.expect(buffer.empty());
        try buffer.push("0123456789abcdef");
        try std.testing.expectEqual(buffer.capacity(), buffer.count());
    }
}

test "truncation keeps the prefix" {
    var buffer: Buffer = try .init(std.testing.allocator, 32);
    defer buffer.deinit(std.testing.allocator);

    try buffer.push("linter lints");

    buffer.truncate(6);

    try std.testing.expectEqualStrings("linter", buffer.const_slice());
}

test "an interned name reads back" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var buffer: Buffer = try .init(static_allocator.allocator(), 64);
    defer buffer.deinit(static_allocator.allocator());

    const first = try buffer.intern("base.html");
    const second = try buffer.intern("partials/row.html");
    var scope = static_allocator.freeze_scope();
    defer scope.leave();

    try std.testing.expectEqualStrings("base.html", buffer.slice_of(first));
    try std.testing.expectEqualStrings("partials/row.html", buffer.slice_of(second));
    try std.testing.expectEqual(26, buffer.count());
}

test "the same name twice takes two spans" {
    var buffer: Buffer = try .init(std.testing.allocator, 64);
    defer buffer.deinit(std.testing.allocator);

    const first = try buffer.intern("base.html");
    const second = try buffer.intern("base.html");

    try std.testing.expect(first.offset != second.offset);
    try std.testing.expectEqualStrings(buffer.slice_of(first), buffer.slice_of(second));
}

test "intern refuses past the reserved bytes" {
    var buffer: Buffer = try .init(std.testing.allocator, 8);
    defer buffer.deinit(std.testing.allocator);

    _ = try buffer.intern("abcdefgh");

    try std.testing.expectError(error.Overflow, buffer.intern("i"));
    try std.testing.expectEqual(8, buffer.count());
}

test "a cleared buffer interns again without allocating" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var buffer: Buffer = try .init(static_allocator.allocator(), 16);
    defer buffer.deinit(static_allocator.allocator());

    _ = try buffer.intern("first");

    var scope = static_allocator.freeze_scope();
    defer scope.leave();

    buffer.clear();

    try std.testing.expect(buffer.empty());

    const span = try buffer.intern("second");

    try std.testing.expectEqual(0, span.offset);
    try std.testing.expectEqualStrings("second", buffer.slice_of(span));
}

test "written parts land end to end or not at all" {
    var target: [8]u8 = @splat(0);

    try std.testing.expectEqual(4, try written(&target, &.{ "ab", "", "cd" }));
    try std.testing.expectEqualStrings("abcd", target[0..4]);
    try std.testing.expectEqual(0, try written(&target, &.{}));
    try std.testing.expectEqual(8, try written(&target, &.{"12345678"}));
    try std.testing.expectError(error.Overflow, written(&target, &.{ "12345678", "9" }));
    try std.testing.expectError(error.Overflow, written(&.{}, &.{"a"}));
    try std.testing.expectEqual(0, try written(&.{}, &.{""}));
}

test "a lent buffer reads from a reader and splices in place" {
    var storage: [16]u8 = undefined;
    var buffer: Buffer = .init_storage(&storage);
    var source: std.Io.Reader = .fixed("linter lints");

    try buffer.read_from(&source);
    try buffer.splice(.between(0, 6), "tool");
    try std.testing.expectEqualStrings("tool lints", buffer.const_slice());
    try std.testing.expectEqual(16, buffer.capacity());
    try std.testing.expect(!buffer.allocated);
}
