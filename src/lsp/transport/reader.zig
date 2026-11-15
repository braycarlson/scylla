const std = @import("std");
const assert = std.debug.assert;
const Random = @import("../../testing/random.zig");
const StaticAllocator = @import("../../stdx/static_allocator.zig");
const framing = @import("framing.zig");

content_length: u32,
line: []u8,
line_length: u32,
request: []u8,
request_length: u32,

const Reader = @This();
pub const CapacityError = error{TooLarge};
pub const Error = CapacityError || StreamError || SyntaxError;
pub const StreamError = error{ Closed, ReadFailed };
pub const SyntaxError = error{Malformed};

const Line = enum {
    closed,
    failed,
    read,
    too_long,
};

pub fn init(gpa: std.mem.Allocator, request_bytes_max: u32) std.mem.Allocator.Error!Reader {
    assert(request_bytes_max > 0);

    const line = try gpa.alloc(u8, framing.header_bytes_max);
    errdefer gpa.free(line);

    const request = try gpa.alloc(u8, request_bytes_max);

    assert(line.len == framing.header_bytes_max);
    assert(request.len == request_bytes_max);

    return .{
        .content_length = 0,
        .line = line,
        .line_length = 0,
        .request = request,
        .request_length = 0,
    };
}

pub fn deinit(reader: *Reader, gpa: std.mem.Allocator) void {
    assert(reader.line_length <= reader.line.len);
    assert(reader.request_length <= reader.request.len);

    gpa.free(reader.request);
    gpa.free(reader.line);
    reader.* = undefined;
}

pub fn body(reader: *const Reader) []const u8 {
    assert(reader.request_length <= reader.request.len);

    return reader.request[0..reader.request_length];
}

pub fn capacity(reader: *const Reader) u32 {
    assert(reader.request.len > 0);

    return @intCast(reader.request.len);
}

pub fn declared_length(reader: *const Reader) u32 {
    assert(reader.request_length <= reader.content_length);
    assert(reader.request_length <= reader.request.len);

    return reader.content_length;
}

pub fn read(reader: *Reader, source: *std.Io.Reader) Error![]const u8 {
    assert(reader.request.len > 0);

    var length: ?u32 = null;
    var ended = false;

    reader.content_length = 0;
    reader.request_length = 0;

    for (1..framing.header_count_max + 1) |header| {
        switch (reader.read_line(source)) {
            .closed => return if (header == 1) error.Closed else error.Malformed,
            .too_long => return error.Malformed,
            .failed => return error.ReadFailed,
            .read => {},
        }

        if (reader.line_length == 0) {
            ended = true;

            break;
        }

        const line = reader.line[0..reader.line_length];
        const named = framing.content_length_of(line) orelse continue;

        if (length) |held| {
            if (held != named) return error.Malformed;
        }

        length = named;
    }

    if (!ended) return error.Malformed;

    const bytes = length orelse return error.Malformed;

    if (bytes > reader.request.len) {
        reader.content_length = bytes;

        source.discardAll(bytes) catch return error.ReadFailed;

        return error.TooLarge;
    }

    return reader.read_body(source, bytes);
}

pub fn ready(buffered: []const u8) bool {
    assert(buffered.len <= std.math.maxInt(u32));

    var length: ?u32 = null;
    var offset: usize = 0;

    for (0..framing.header_count_max) |_| {
        const rest = buffered[offset..];
        const window = rest[0..@min(rest.len, framing.header_bytes_max + 1)];

        const newline = std.mem.findScalar(u8, window, '\n') orelse {
            return rest.len > framing.header_bytes_max;
        };

        var line = rest[0..newline];

        offset += newline + 1;

        assert(offset <= buffered.len);

        if (line.len > 0) {
            if (line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        }

        if (line.len == 0) {
            const bytes = length orelse return true;

            return buffered.len - offset >= bytes;
        }

        const named = framing.content_length_of(line) orelse continue;

        if (length) |held| {
            if (held != named) return true;
        }

        length = named;
    }

    return true;
}

fn read_body(reader: *Reader, source: *std.Io.Reader, bytes: u32) Error![]const u8 {
    assert(reader.request_length == 0);
    assert(reader.content_length == 0);
    assert(bytes <= reader.request.len);

    reader.content_length = bytes;

    source.readSliceAll(reader.request[0..bytes]) catch return error.ReadFailed;
    reader.request_length = bytes;

    assert(reader.request_length <= reader.request.len);

    return reader.body();
}

fn read_line(reader: *Reader, source: *std.Io.Reader) Line {
    assert(reader.line.len == framing.header_bytes_max);

    reader.line_length = 0;

    for (0..framing.header_bytes_max + 1) |_| {
        const byte = source.takeByte() catch |err| switch (err) {
            error.EndOfStream => return if (reader.line_length == 0) .closed else .failed,
            error.ReadFailed => return .failed,
        };

        if (byte == '\n') {
            if (reader.line_length > 0) {
                if (reader.line[reader.line_length - 1] == '\r') reader.line_length -= 1;
            }

            return .read;
        }

        if (reader.line_length == reader.line.len) return .too_long;

        reader.line[reader.line_length] = byte;
        reader.line_length += 1;
    }

    return .too_long;
}

const request_bytes_max_test: u32 = 1 << 12;

fn framed_all(buffer: []u8, bodies: []const []const u8) []const u8 {
    assert(buffer.len <= std.math.maxInt(u32));
    assert(bodies.len <= std.math.maxInt(u32));

    var writer: std.Io.Writer = .fixed(buffer);

    for (bodies) |message| framing.framed(&writer, message) catch unreachable;

    return writer.buffered();
}

fn expect_message(held: *Reader, source: *std.Io.Reader, expected: []const u8) !void {
    try std.testing.expectEqualStrings(expected, try held.read(source));
    try std.testing.expectEqualStrings(expected, held.body());
}

test Reader {
    var reader: Reader = try .init(std.testing.allocator, 64);
    defer reader.deinit(std.testing.allocator);

    var source: std.Io.Reader = .fixed("Content-Length: 8\r\n\r\n{\"id\":1}");

    try std.testing.expectEqualStrings("{\"id\":1}", try reader.read(&source));
    try std.testing.expectError(error.Closed, reader.read(&source));
}

test "one message reads back byte for byte" {
    const message = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}";
    var buffer: [256]u8 = undefined;
    var source: std.Io.Reader = .fixed(framed_all(&buffer, &.{message}));
    var held = try Reader.init(std.testing.allocator, request_bytes_max_test);
    defer held.deinit(std.testing.allocator);

    try expect_message(&held, &source, message);
}

test "one message after another reads in order" {
    const messages = [_][]const u8{ "{\"id\":1}", "{\"id\":2}", "{\"id\":3}" };
    var buffer: [256]u8 = undefined;
    var source: std.Io.Reader = .fixed(framed_all(&buffer, &messages));
    var held = try Reader.init(std.testing.allocator, request_bytes_max_test);
    defer held.deinit(std.testing.allocator);

    for (messages) |message| try expect_message(&held, &source, message);

    try std.testing.expectError(error.Closed, held.read(&source));
}

test "a header the reader does not need is read past" {
    const source_text = "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n" ++
        "Content-Length: 8\r\n\r\n{\"id\":1}";

    var source: std.Io.Reader = .fixed(source_text);
    var held = try Reader.init(std.testing.allocator, request_bytes_max_test);
    defer held.deinit(std.testing.allocator);

    try expect_message(&held, &source, "{\"id\":1}");
}

test "a header name matches whatever case it is written in" {
    var source: std.Io.Reader = .fixed("content-length: 8\r\n\r\n{\"id\":1}");
    var held = try Reader.init(std.testing.allocator, request_bytes_max_test);
    defer held.deinit(std.testing.allocator);

    try expect_message(&held, &source, "{\"id\":1}");
}

test "a lone newline terminates a header too" {
    var source: std.Io.Reader = .fixed("Content-Length: 8\n\n{\"id\":1}");
    var held = try Reader.init(std.testing.allocator, request_bytes_max_test);
    defer held.deinit(std.testing.allocator);

    try expect_message(&held, &source, "{\"id\":1}");
}

test "an empty body is a message of no bytes" {
    var buffer: [64]u8 = undefined;
    var source: std.Io.Reader = .fixed(framed_all(&buffer, &.{""}));
    var held = try Reader.init(std.testing.allocator, request_bytes_max_test);
    defer held.deinit(std.testing.allocator);

    try expect_message(&held, &source, "");
}

test "a stream that ends between messages is a clean close" {
    var buffer: [64]u8 = undefined;
    var source: std.Io.Reader = .fixed(framed_all(&buffer, &.{"{\"id\":1}"}));
    var held = try Reader.init(std.testing.allocator, request_bytes_max_test);
    defer held.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("{\"id\":1}", try held.read(&source));
    try std.testing.expectError(error.Closed, held.read(&source));
    try std.testing.expectError(error.Closed, held.read(&source));
}

test "a message with no length is malformed" {
    var source: std.Io.Reader = .fixed("Content-Type: text/plain\r\n\r\n");
    var held = try Reader.init(std.testing.allocator, request_bytes_max_test);
    defer held.deinit(std.testing.allocator);

    try std.testing.expectError(error.Malformed, held.read(&source));
}

test "a length that is not a number is malformed" {
    var source: std.Io.Reader = .fixed("Content-Length: many\r\n\r\n");
    var held = try Reader.init(std.testing.allocator, request_bytes_max_test);
    defer held.deinit(std.testing.allocator);

    try std.testing.expectError(error.Malformed, held.read(&source));
}

test "a header longer than the line buffer is malformed" {
    const source_text = "Content-Length: " ++ @as([1_024]u8, @splat('0')) ++ "1\r\n\r\n";
    var source: std.Io.Reader = .fixed(source_text);
    var held = try Reader.init(std.testing.allocator, request_bytes_max_test);
    defer held.deinit(std.testing.allocator);

    try std.testing.expectError(error.Malformed, held.read(&source));
}

test "a stream that ends inside a header is malformed" {
    var source: std.Io.Reader = .fixed("Content-Length: 8\r\n");
    var held = try Reader.init(std.testing.allocator, request_bytes_max_test);
    defer held.deinit(std.testing.allocator);

    try std.testing.expectError(error.Malformed, held.read(&source));
}

test "two lengths that disagree are malformed" {
    var source: std.Io.Reader = .fixed("Content-Length: 2\r\nContent-Length: 3\r\n\r\n{}x");
    var held = try Reader.init(std.testing.allocator, request_bytes_max_test);
    defer held.deinit(std.testing.allocator);

    try std.testing.expectError(error.Malformed, held.read(&source));
}

test "a repeated length that agrees is read" {
    var source: std.Io.Reader = .fixed("Content-Length: 2\r\nContent-Length: 2\r\n\r\n{}");
    var held = try Reader.init(std.testing.allocator, request_bytes_max_test);
    defer held.deinit(std.testing.allocator);

    try expect_message(&held, &source, "{}");
}

test "a body larger than the buffer is read past so the next one still lands" {
    const long: [4_096]u8 = @splat('x');
    var buffer: [4_096 + 256]u8 = undefined;
    var source: std.Io.Reader = .fixed(framed_all(&buffer, &.{ &long, "{\"id\":2}" }));
    var held = try Reader.init(std.testing.allocator, 64);
    defer held.deinit(std.testing.allocator);

    try std.testing.expectError(error.TooLarge, held.read(&source));
    try std.testing.expectEqual(4_096, held.declared_length());
    try std.testing.expectEqualStrings("", held.body());
    try expect_message(&held, &source, "{\"id\":2}");
    try std.testing.expectEqual(8, held.declared_length());
}

test "a body the stream never finishes is a failure" {
    var source: std.Io.Reader = .fixed("Content-Length: 32\r\n\r\nshort");
    var held = try Reader.init(std.testing.allocator, request_bytes_max_test);
    defer held.deinit(std.testing.allocator);

    try std.testing.expectError(error.ReadFailed, held.read(&source));
}

test "a written message reads back through the same reader" {
    const message = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"ok\":true}}";
    var held = try Reader.init(std.testing.allocator, request_bytes_max_test);
    defer held.deinit(std.testing.allocator);

    var buffer: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var header: [64]u8 = undefined;
    const expected = try std.mem.print(&header, "Content-Length: {d}\r\n\r\n", .{message.len});

    try framing.framed(&out, message);
    try std.testing.expect(std.mem.startsWith(u8, out.buffered(), expected));

    var source: std.Io.Reader = .fixed(out.buffered());

    try expect_message(&held, &source, message);
}

test "a round trip allocates nothing" {
    const message = "{\"id\":1,\"method\":\"textDocument/didChange\"}";
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var held = try Reader.init(static_allocator.allocator(), request_bytes_max_test);
    var buffer: [1 << 12]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);

    try framing.framed(&out, message);

    var source: std.Io.Reader = .fixed(out.buffered());

    static_allocator.transition_from_init_to_static();

    const outcome = held.read(&source);
    const matched = if (outcome) |received| std.mem.eql(u8, received, message) else |_| false;

    static_allocator.transition_from_static_to_deinit();
    held.deinit(static_allocator.allocator());

    _ = try outcome;

    try std.testing.expect(matched);
}

fn test_message_random(random: *Random, writer: *std.Io.Writer) std.Io.Writer.Error!usize {
    const body_length = random.below(48);
    const spellings = [_][]const u8{ "Content-Length", "content-length", "CONTENT-LENGTH" };
    const extra = "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n";
    const start = writer.end;

    if (random.below(2) == 0) try writer.writeAll(extra);

    try writer.print("{s}: {d}\r\n", .{ spellings[random.below(spellings.len)], body_length });

    if (random.below(2) == 0) try writer.writeAll(extra);

    try writer.writeAll("\r\n");

    for (0..body_length) |_| try writer.writeByte(@intCast('a' + random.below(26)));

    assert(writer.end > start);

    return writer.end;
}

test "a buffer is ready exactly when it holds the whole first message" {
    var random: Random = .init(0x2545_F491_4F6C_DD1D);
    var stream: [1 << 10]u8 = undefined;
    var held = try Reader.init(std.testing.allocator, 1 << 8);
    defer held.deinit(std.testing.allocator);

    for (0..1 << 8) |_| {
        var writer: std.Io.Writer = .fixed(&stream);
        const boundary = try test_message_random(&random, &writer);

        _ = try test_message_random(&random, &writer);

        const written = writer.buffered();
        var source: std.Io.Reader = .fixed(written);

        _ = try held.read(&source);

        try std.testing.expectEqual(boundary, source.seek);

        for (0..written.len + 1) |cut| {
            try std.testing.expectEqual(cut >= boundary, ready(written[0..cut]));
        }
    }
}

test "a buffer whose first message cannot finish is ready to fail" {
    const long: [framing.header_bytes_max + 1]u8 = @splat('x');

    try std.testing.expect(!ready("Content-Length: 3\r\n"));
    try std.testing.expect(!ready("Content-Length: 3\r\n\r\n{}"));
    try std.testing.expect(ready("Content-Length: 3\r\n\r\n{}}"));
    try std.testing.expect(ready("Content-Length: 2\n\n{}"));
    try std.testing.expect(ready("Content-Type: x\r\n\r\n"));
    try std.testing.expect(ready("Content-Length: 3x\r\n\r\n"));
    try std.testing.expect(ready("Content-Length: 2\r\nContent-Length: 3\r\n"));
    try std.testing.expect(ready(&long));
    try std.testing.expect(!ready(long[0 .. long.len - 1]));
}
