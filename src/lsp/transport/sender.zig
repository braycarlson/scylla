const std = @import("std");
const assert = std.debug.assert;
const json = @import("json");
const log = @import("../../stdx/log.zig");
const framing = @import("framing.zig");
const rpc = @import("rpc.zig");
const Buffer = @import("../../stdx/bounded.zig").Buffer;
const Code = rpc.Code;
const Id = rpc.Id;
const StaticAllocator = @import("../../stdx/static_allocator.zig");

body: Buffer,
body_sink: Buffer.Writer,
opened: Opened,
out: *std.Io.Writer,
sorted: ?Sorted,
staged: []const u8,
writer: json.Writer,

const Sender = @This();

pub const Capacity = struct {
    body_bytes_max: u32,
};

pub const CapacityError = error{ DepthExceeded, MessageTooLarge };
pub const Error = CapacityError || ValueError || WriteError;

pub const Options = struct {
    members: Members = .source,

    pub const Members = union(enum) {
        source,
        sorted: Sorting,
    };

    pub const Sorting = struct {
        node_count_max: u32,
    };
};

pub const ValueError = json.Writer.ValueError;
pub const WriteError = error{WriteFailed};

pub const Stdout = struct {
    writer: std.Io.File.Writer,

    pub const buffer_bytes: u32 = 1 << 16;

    pub fn init(gpa: std.mem.Allocator, io: std.Io) std.mem.Allocator.Error!Stdout {
        const buffer = try gpa.alloc(u8, buffer_bytes);

        assert(buffer.len == buffer_bytes);

        return .{ .writer = std.Io.File.stdout().writerStreaming(io, buffer) };
    }

    pub fn deinit(stdout: *Stdout, gpa: std.mem.Allocator) void {
        assert(stdout.writer.interface.buffer.len == buffer_bytes);

        gpa.free(stdout.writer.interface.buffer);
        stdout.* = undefined;
    }

    pub fn failure_name(stdout: *const Stdout) []const u8 {
        const failure = stdout.writer.err orelse return "WriteFailed";
        const name = @errorName(failure);

        assert(name.len > 0);

        return name;
    }

    pub fn interface(stdout: *Stdout) *std.Io.Writer {
        assert(stdout.writer.interface.buffer.len == buffer_bytes);

        return &stdout.writer.interface;
    }
};

const Opened = union(enum) {
    idle,
    message,
    notification,
    request,
    response: Id,
};

const Sorted = struct {
    document: json.Document,
    nodes: []json.Node,
    output: Buffer,
    storage: json.Storage,
};

pub const body_bytes_min: u32 = 256;
const oversize_message = "the answer is larger than the transport buffer";

const writer_options: json.Writer.Options = .{
    .indent = 2,
    .layout = .compact,
    .non_finite = .refused,
    .notation = .ecmascript,
    .utf8 = .checked,
};

pub fn init(
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    bounds: Capacity,
    options: Options,
) std.mem.Allocator.Error!Sender {
    assert(bounds.body_bytes_max >= body_bytes_min);
    if (options.members == .sorted) assert(options.members.sorted.node_count_max > 0);

    var body = try Buffer.init(gpa, bounds.body_bytes_max);
    errdefer body.deinit(gpa);

    const sorted: ?Sorted = switch (options.members) {
        .source => null,
        .sorted => |sorting| try sorted_init(gpa, bounds, sorting),
    };

    assert(body.capacity() == bounds.body_bytes_max);

    return .{
        .body = body,
        .body_sink = undefined,
        .opened = .idle,
        .out = out,
        .sorted = sorted,
        .staged = &.{},
        .writer = undefined,
    };
}

fn sorted_init(
    gpa: std.mem.Allocator,
    bounds: Capacity,
    sorting: Options.Sorting,
) std.mem.Allocator.Error!Sorted {
    assert(sorting.node_count_max > 0);
    assert(bounds.body_bytes_max >= body_bytes_min);

    var storage: json.Storage = try .init(gpa, .{
        .node_count_max = sorting.node_count_max,
        .text_bytes_max = bounds.body_bytes_max,
    });

    errdefer storage.deinit(gpa);

    const nodes = try StaticAllocator.reserve(json.Node, gpa, sorting.node_count_max);
    errdefer gpa.free(nodes);

    const output = try Buffer.init(gpa, bounds.body_bytes_max);

    assert(nodes.len == sorting.node_count_max);
    assert(output.capacity() == bounds.body_bytes_max);

    return .{ .document = undefined, .nodes = nodes, .output = output, .storage = storage };
}

pub fn delivered(sender: *Sender, written: json.Writer.Error!void) WriteError!void {
    assert(sender.opened != .idle);
    if (written) |_| {} else |err| assert(@intFromError(err) != 0);

    const outcome = if (written) sender.finish() else |err| sender.failed(err);

    outcome catch |err| return sender.dropped(err);

    assert(sender.opened == .idle);
}

pub fn dropped(sender: *const Sender, err: Error) WriteError!void {
    assert(sender.body.capacity() >= body_bytes_min);
    assert(@intFromError(err) != 0);

    switch (err) {
        error.DepthExceeded, error.MessageTooLarge => {
            log.line("dropping an outbound message past {d} bytes", .{sender.capacity()});
        },
        error.EnumerationUnrecognized, error.FloatNonFinite, error.RawMalformed => |value| {
            log.line("dropping an outbound message: {s}", .{json.message(value)});
        },
        error.WriteFailed => return error.WriteFailed,
    }
}

pub fn deinit(sender: *Sender, gpa: std.mem.Allocator) void {
    assert(sender.body.capacity() >= body_bytes_min);

    if (sender.sorted) |*sorted| {
        sorted.output.deinit(gpa);
        gpa.free(sorted.nodes);
        sorted.storage.deinit(gpa);
    }

    sender.body.deinit(gpa);
    sender.* = undefined;
}

pub fn abandon(sender: *Sender) void {
    assert(sender.opened != .idle);

    sender.opened = .idle;
}

pub fn capacity(sender: *const Sender) u32 {
    const result = sender.body.capacity();

    assert(result >= body_bytes_min);

    return result;
}

pub fn failed(sender: *Sender, err: json.Writer.Error) Error!void {
    const opened = sender.opened;

    assert(opened != .idle);

    sender.opened = .idle;

    return switch (opened) {
        .idle => unreachable,
        .message, .notification, .request => refused_of(err),
        .response => |*id| sender.refusal_send(id, err),
    };
}

pub fn finish(sender: *Sender) Error!void {
    const opened = sender.opened;

    assert(opened != .idle);
    assert(sender.body.count() <= sender.body.capacity());

    if (opened != .message) {
        sender.writer.object_end() catch |err| return sender.failed(err);
    }

    sender.writer.finish();
    sender.opened = .idle;
    sender.staged = sender.body.const_slice();

    if (opened != .message) {
        if (sender.sorted) |*sorted| {
            sender.staged = sorted_write(sorted, sender.staged) catch |err| switch (opened) {
                .response => |*id| return sender.refusal_send(id, err),
                .idle, .message => unreachable,
                .notification, .request => return refused_of(err),
            };
        }
    }

    assert(sender.staged.len > 0);

    return framing.framed(sender.out, sender.staged);
}

pub fn reframe(sender: *Sender) WriteError!void {
    assert(sender.opened == .idle);
    assert(sender.staged.len > 0);

    return framing.framed(sender.out, sender.staged);
}

pub fn retarget(sender: *Sender, out: *std.Io.Writer) *std.Io.Writer {
    assert(sender.opened == .idle);

    const previous = sender.out;

    sender.out = out;

    return previous;
}

pub fn target(sender: *const Sender) *std.Io.Writer {
    return sender.out;
}

pub fn message_open(sender: *Sender) *json.Writer {
    assert(sender.body.capacity() >= body_bytes_min);

    return sender.open(.message);
}

pub fn notify_open(sender: *Sender, method: []const u8) Error!*json.Writer {
    assert(method.len > 0);

    const writer = sender.open(.notification);

    notification_head(writer, method) catch |err| {
        sender.opened = .idle;

        return refused_of(err);
    };

    return writer;
}

pub fn request_open(sender: *Sender, id: i64, method: []const u8) Error!*json.Writer {
    assert(method.len > 0);
    assert(id < std.math.maxInt(u32));

    const writer = sender.open(.request);

    request_head(writer, id, method) catch |err| {
        sender.opened = .idle;

        return refused_of(err);
    };

    return writer;
}

pub fn respond_open(sender: *Sender, id: *const Id) Error!*json.Writer {
    assert(id.is_request());

    const writer = sender.open(.message);

    response_head(writer, id) catch |err| {
        sender.opened = .idle;

        return refused_of(err);
    };

    sender.opened = .{ .response = id.* };

    return writer;
}

pub fn respond_error(sender: *Sender, id: *const Id, code: Code, message: []const u8) Error!void {
    assert(message.len > 0);
    assert(@backingInt(code) < 0);

    refusal_write(sender.open(.message), id, code, message) catch |err| {
        sender.opened = .idle;

        if (!id.is_request()) return refused_of(err);
        return sender.refusal_send(id, err);
    };

    return sender.finish();
}

pub fn respond_null(sender: *Sender, id: *const Id) Error!void {
    assert(id.is_request());

    null_response_write(sender.open(.message), id) catch |err| return sender.failed(err);

    return sender.finish();
}

fn open(sender: *Sender, opened: Opened) *json.Writer {
    assert(sender.opened == .idle);
    assert(opened != .idle);

    sender.body.clear();
    sender.body_sink = sender.body.writer();
    sender.writer = .init(&sender.body_sink.interface, writer_options);
    sender.opened = opened;

    return &sender.writer;
}

fn refusal_send(sender: *Sender, id: *const Id, cause: json.Writer.Error) Error!void {
    assert(sender.opened == .idle);
    assert(id.is_request());

    log.line(
        "an answer failed with {t} in the {d} byte transport buffer; it takes an error instead",
        .{ cause, sender.body.capacity() },
    );

    refusal_write(sender.open(.message), id, .internal, message_of(cause)) catch |err| {
        sender.opened = .idle;

        return refused_of(err);
    };

    return sender.finish();
}

fn message_of(err: json.Writer.Error) []const u8 {
    return switch (err) {
        error.DepthExceeded, error.WriteFailed => oversize_message,
        error.EnumerationUnrecognized,
        error.FloatNonFinite,
        error.RawMalformed,
        => json.message(err),
    };
}

fn refused_of(err: json.Writer.Error) Error {
    return switch (err) {
        error.DepthExceeded => error.DepthExceeded,
        error.EnumerationUnrecognized => error.EnumerationUnrecognized,
        error.FloatNonFinite => error.FloatNonFinite,
        error.RawMalformed => error.RawMalformed,
        error.WriteFailed => error.MessageTooLarge,
    };
}

fn sorted_write(sorted: *Sorted, body: []const u8) json.Writer.Error![]const u8 {
    assert(body.len > 0);
    assert(body.len <= sorted.output.capacity());

    sorted.document.parse(sorted.storage, body) catch |err| return switch (err) {
        error.DepthExceeded => error.DepthExceeded,
        error.NodesExhausted => error.WriteFailed,
        error.Malformed, error.TextExhausted => unreachable,
    };

    const document = &sorted.document;
    const root = document.root();
    var entries = document.entries(root);

    sorted.output.clear();

    var sink = sorted.output.writer();
    var writer: json.Writer = .init(&sink.interface, writer_options);

    assert(document.kind_of(root) == .object);

    try writer.object_begin();

    for (0..document.count_of(root)) |_| {
        const entry = entries.next() orelse unreachable;
        const sorting = payload_is(document, entry.key);

        try writer.key(document.text_of(entry.key).?);

        if (sorting) {
            try document.node_write_sorted(sorted.nodes, &writer, entry.value);
        } else {
            try document.node_write(&writer, entry.value);
        }
    }

    try writer.object_end();

    writer.finish();

    assert(entries.remaining == 0);
    assert(sorted.output.count() <= body.len);

    return sorted.output.const_slice();
}

fn payload_is(document: *const json.Document, key: json.Node) bool {
    assert(@backingInt(key) < document.node_count);

    const result = document.text_is(key, "params") or document.text_is(key, "result");

    if (result) assert(document.kind_of(key) == .string);

    return result;
}

fn notification_head(writer: *json.Writer, method: []const u8) json.Writer.Error!void {
    assert(method.len > 0);

    try writer.object_begin();
    try writer.key("jsonrpc");
    try writer.string(rpc.version);
    try writer.key("method");
    try writer.string(method);
    try writer.key("params");
}

fn request_head(writer: *json.Writer, id: i64, method: []const u8) json.Writer.Error!void {
    assert(method.len > 0);
    assert(id < std.math.maxInt(u32));

    try writer.object_begin();
    try writer.key("jsonrpc");
    try writer.string(rpc.version);
    try writer.key("id");
    try writer.integer(id);
    try writer.key("method");
    try writer.string(method);
    try writer.key("params");
}

fn response_head(writer: *json.Writer, id: *const Id) json.Writer.Error!void {
    assert(id.is_request());

    try writer.object_begin();
    try writer.key("jsonrpc");
    try writer.string(rpc.version);
    try writer.key("id");
    try id.write(writer);
    try writer.key("result");
}

fn envelope_close(writer: *json.Writer) json.Writer.Error!void {
    try writer.object_end();
}

fn refusal_write(
    writer: *json.Writer,
    id: *const Id,
    code: Code,
    message: []const u8,
) json.Writer.Error!void {
    assert(message.len > 0);
    assert(@backingInt(code) < 0);

    try writer.object_begin();
    try writer.key("jsonrpc");
    try writer.string(rpc.version);
    try writer.key("id");
    try id.write(writer);
    try writer.key("error");
    try writer.object_begin();
    try writer.key("code");
    try writer.integer(@backingInt(code));
    try writer.key("message");
    try writer.string(message);
    try writer.object_end();
    try writer.object_end();
}

fn null_response_write(writer: *json.Writer, id: *const Id) json.Writer.Error!void {
    assert(id.is_request());

    try response_head(writer, id);
    try writer.null_value();
    try envelope_close(writer);
}

const body_bytes_max_test: u32 = 1 << 10;

fn body_of(framed: []const u8) []const u8 {
    assert(framed.len <= std.math.maxInt(u32));

    const at = std.mem.find(u8, framed, "\r\n\r\n").?;
    return framed[at + 4 ..];
}

fn test_object_write(writer: *json.Writer) json.Writer.Error!void {
    try writer.object_begin();
    try writer.key("uri");
    try writer.string("a");
    try writer.key("range");
    try writer.object_begin();
    try writer.key("start");
    try writer.integer(1);
    try writer.key("end");
    try writer.integer(2);
    try writer.object_end();
    try writer.object_end();
}

const TestFrozen = struct {
    buffer: [1 << 10]u8,
    out: std.Io.Writer,
    sender: Sender,
    static_allocator: StaticAllocator,

    fn init(frozen: *TestFrozen, body_bytes_max: u32) !void {
        assert(body_bytes_max < std.math.maxInt(u32));

        return frozen.init_options(body_bytes_max, .{});
    }

    fn init_options(frozen: *TestFrozen, body_bytes_max: u32, options: Options) !void {
        assert(body_bytes_max < std.math.maxInt(u32));
        if (options.members == .sorted) assert(options.members.sorted.node_count_max > 0);

        frozen.out = .fixed(&frozen.buffer);
        frozen.static_allocator = .init(std.testing.allocator);

        const gpa = frozen.static_allocator.allocator();
        const bounds: Capacity = .{ .body_bytes_max = body_bytes_max };

        frozen.sender = try .init(gpa, &frozen.out, bounds, options);

        frozen.static_allocator.transition_from_init_to_static();
    }

    fn deinit(frozen: *TestFrozen) void {
        frozen.static_allocator.transition_from_static_to_deinit();
        frozen.sender.deinit(frozen.static_allocator.allocator());
        frozen.static_allocator.deinit();
    }

    fn rewind(frozen: *TestFrozen) void {
        frozen.out = .fixed(&frozen.buffer);
    }
};

const TestWriter = struct {
    bytes: [256]u8,
    sink: std.Io.Writer,
    writer: json.Writer,

    fn init(fixture: *TestWriter, out_bytes_max: u32) void {
        assert(out_bytes_max <= fixture.bytes.len);

        fixture.sink = .fixed(fixture.bytes[0..out_bytes_max]);
        fixture.writer = .init(&fixture.sink, writer_options);
    }

    fn written(fixture: *TestWriter) []const u8 {
        fixture.writer.finish();

        return fixture.sink.buffered();
    }
};

test Sender {
    var buffer: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var sender: Sender = try .init(std.testing.allocator, &out, .{ .body_bytes_max = 256 }, .{});
    defer sender.deinit(std.testing.allocator);

    const writer = try sender.notify_open("exit");

    writer.null_value() catch |err| return sender.failed(err);

    try sender.finish();

    try std.testing.expectEqualStrings(
        "Content-Length: 47\r\n\r\n{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}",
        out.buffered(),
    );
}

test "a response is framed with its length" {
    var frozen: TestFrozen = undefined;

    try frozen.init(body_bytes_max_test);
    defer frozen.deinit();

    try frozen.sender.respond_null(&.{ .number = 3 });

    const body = body_of(frozen.out.buffered());
    var header: [64]u8 = undefined;
    const expected = try std.mem.print(&header, "Content-Length: {d}\r\n\r\n", .{body.len});

    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":null}", body);
    try std.testing.expect(std.mem.startsWith(u8, frozen.out.buffered(), expected));
}

test "every envelope kind writes through the sender" {
    var frozen: TestFrozen = undefined;

    try frozen.init(body_bytes_max_test);
    defer frozen.deinit();

    try (try frozen.sender.notify_open("exit")).null_value();
    try frozen.sender.finish();

    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}",
        body_of(frozen.out.buffered()),
    );

    frozen.rewind();

    try (try frozen.sender.request_open(4, "workspace/configuration")).null_value();
    try frozen.sender.finish();

    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"workspace/configuration\",\"params\":null}",
        body_of(frozen.out.buffered()),
    );

    frozen.rewind();

    try frozen.sender.respond_error(&.{ .number = 2 }, .method_not_found, "no");

    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32601,\"message\":\"no\"}}",
        body_of(frozen.out.buffered()),
    );

    frozen.rewind();

    try (try frozen.sender.respond_open(&.{ .string = "seven" })).raw("[1]");
    try frozen.sender.finish();

    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":\"seven\",\"result\":[1]}",
        body_of(frozen.out.buffered()),
    );

    frozen.rewind();

    const writer = frozen.sender.message_open();

    try writer.object_begin();
    try writer.key("jsonrpc");
    try writer.string(rpc.version);
    try writer.key("id");
    try writer.integer(9);
    try writer.key("method");
    try writer.string("workspace/diagnostic/refresh");
    try writer.object_end();
    try frozen.sender.finish();

    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"workspace/diagnostic/refresh\"}",
        body_of(frozen.out.buffered()),
    );
}

test "a body that does not fit is not sent" {
    var frozen: TestFrozen = undefined;

    try frozen.init(body_bytes_min);
    defer frozen.deinit();

    const text: [body_bytes_min]u8 = @splat('x');
    const writer = try frozen.sender.notify_open("window/logMessage");
    const written = writer.string(&text);

    try std.testing.expectError(error.WriteFailed, written);
    try std.testing.expectError(error.MessageTooLarge, frozen.sender.failed(error.WriteFailed));
    try std.testing.expectEqual(@as(usize, 0), frozen.out.buffered().len);
    try std.testing.expectEqual(body_bytes_min, frozen.sender.capacity());

    try (try frozen.sender.notify_open("exit")).null_value();
    try frozen.sender.finish();

    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}",
        body_of(frozen.out.buffered()),
    );
}

test "an abandoned message sends nothing and frees the sender" {
    var frozen: TestFrozen = undefined;

    try frozen.init(body_bytes_max_test);
    defer frozen.deinit();

    const writer = try frozen.sender.respond_open(&.{ .number = 2 });

    try writer.array_begin();
    frozen.sender.abandon();

    try std.testing.expectEqual(@as(usize, 0), frozen.out.buffered().len);
    try frozen.sender.respond_null(&.{ .number = 3 });

    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":null}",
        body_of(frozen.out.buffered()),
    );
}

test "an answer that does not fit becomes an internal error" {
    var frozen: TestFrozen = undefined;

    try frozen.init(body_bytes_min);
    defer frozen.deinit();

    const text: [body_bytes_min]u8 = @splat('x');
    const writer = try frozen.sender.respond_open(&.{ .number = 1 });

    writer.string(&text) catch |err| try frozen.sender.failed(err);

    const expected = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32603,\"message\":\"" ++
        oversize_message ++ "\"}}";

    try std.testing.expectEqualStrings(expected, body_of(frozen.out.buffered()));
}

test "a refusal that does not fit becomes an internal error" {
    var frozen: TestFrozen = undefined;

    try frozen.init(body_bytes_min);
    defer frozen.deinit();

    const text: [body_bytes_min]u8 = @splat('x');

    try frozen.sender.respond_error(&.{ .number = 1 }, .invalid_params, &text);

    const expected = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32603,\"message\":\"" ++
        oversize_message ++ "\"}}";

    try std.testing.expectEqualStrings(expected, body_of(frozen.out.buffered()));

    try std.testing.expectError(error.MessageTooLarge, frozen.sender.respond_error(
        &.{ .absent = {} },
        .parse,
        &text,
    ));
}

test "an answer whose id alone outgrows the buffer is refused instead of crashing" {
    var frozen: TestFrozen = undefined;

    try frozen.init(body_bytes_min);
    defer frozen.deinit();

    const long: [body_bytes_min]u8 = @splat('i');

    try std.testing.expectError(error.MessageTooLarge, frozen.sender.respond_open(&.{
        .string = &long,
    }));

    try std.testing.expectError(error.MessageTooLarge, frozen.sender.respond_null(&.{
        .string = &long,
    }));

    try std.testing.expectError(error.MessageTooLarge, frozen.sender.respond_error(
        &.{ .string = &long },
        .invalid_params,
        "no",
    ));

    try std.testing.expectEqual(@as(usize, 0), frozen.out.buffered().len);
}

test "a retargeted sender frames into the new writer and gives the old one back" {
    var frozen: TestFrozen = undefined;

    try frozen.init(body_bytes_max_test);
    defer frozen.deinit();

    var buffer: [1 << 10]u8 = undefined;
    var held: std.Io.Writer = .fixed(&buffer);
    const previous = frozen.sender.retarget(&held);

    try std.testing.expectEqual(&frozen.out, previous);
    try std.testing.expectEqual(&held, frozen.sender.target());

    try frozen.sender.respond_null(&.{ .number = 3 });

    try std.testing.expectEqual(@as(usize, 0), frozen.out.buffered().len);

    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":null}",
        body_of(held.buffered()),
    );

    try std.testing.expectEqual(&held, frozen.sender.retarget(previous));
}

test "a message whose write failed is framed again whole" {
    var frozen: TestFrozen = undefined;

    try frozen.init(body_bytes_max_test);
    defer frozen.deinit();

    var buffer: [8]u8 = undefined;
    var cramped: std.Io.Writer = .fixed(&buffer);
    const previous = frozen.sender.retarget(&cramped);

    try std.testing.expectError(error.WriteFailed, frozen.sender.respond_null(&.{ .number = 3 }));

    _ = frozen.sender.retarget(previous);

    try frozen.sender.reframe();

    try std.testing.expectEqualStrings(
        "Content-Length: 38\r\n\r\n{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":null}",
        frozen.out.buffered(),
    );
}

test "a failed write reaches the caller" {
    var frozen: TestFrozen = undefined;

    try frozen.init(body_bytes_max_test);
    defer frozen.deinit();

    frozen.out = .failing;

    try std.testing.expectError(error.WriteFailed, frozen.sender.respond_null(&.{ .number = 1 }));
    try (try frozen.sender.respond_open(&.{ .number = 1 })).null_value();
    try std.testing.expectError(error.WriteFailed, frozen.sender.finish());
}

test "a sorted sender sorts the payload and keeps the envelope in order" {
    var frozen: TestFrozen = undefined;

    try frozen.init_options(body_bytes_max_test, .{
        .members = .{ .sorted = .{ .node_count_max = 32 } },
    });

    defer frozen.deinit();

    try test_object_write(try frozen.sender.notify_open("window/logMessage"));
    try frozen.sender.finish();

    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"window/logMessage\",\"params\":" ++
            "{\"range\":{\"end\":2,\"start\":1},\"uri\":\"a\"}}",
        body_of(frozen.out.buffered()),
    );

    frozen.rewind();

    try test_object_write(try frozen.sender.request_open(5, "client/registerCapability"));
    try frozen.sender.finish();

    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"client/registerCapability\"," ++
            "\"params\":{\"range\":{\"end\":2,\"start\":1},\"uri\":\"a\"}}",
        body_of(frozen.out.buffered()),
    );

    frozen.rewind();

    try test_object_write(try frozen.sender.respond_open(&.{ .number = 6 }));
    try frozen.sender.finish();

    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"result\":" ++
            "{\"range\":{\"end\":2,\"start\":1},\"uri\":\"a\"}}",
        body_of(frozen.out.buffered()),
    );

    frozen.rewind();

    try frozen.sender.respond_error(&.{ .number = 7 }, .parse, "bad");

    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32700,\"message\":\"bad\"}}",
        body_of(frozen.out.buffered()),
    );
}

test "a sorted sender whose payload outgrows its node bound answers with an error" {
    var frozen: TestFrozen = undefined;

    try frozen.init_options(body_bytes_max_test, .{
        .members = .{ .sorted = .{ .node_count_max = 8 } },
    });

    defer frozen.deinit();

    try test_object_write(try frozen.sender.respond_open(&.{ .number = 6 }));
    try frozen.sender.finish();

    const expected = "{\"jsonrpc\":\"2.0\",\"id\":6,\"error\":{\"code\":-32603,\"message\":\"" ++
        oversize_message ++ "\"}}";

    try std.testing.expectEqualStrings(expected, body_of(frozen.out.buffered()));

    frozen.rewind();

    try test_object_write(try frozen.sender.notify_open("window/logMessage"));
    try std.testing.expectError(error.MessageTooLarge, frozen.sender.finish());
    try std.testing.expectEqual(@as(usize, 0), frozen.out.buffered().len);
}

test "a default sender writes the payload in the order it was given" {
    var frozen: TestFrozen = undefined;

    try frozen.init(body_bytes_max_test);
    defer frozen.deinit();

    try test_object_write(try frozen.sender.respond_open(&.{ .number = 6 }));
    try frozen.sender.finish();

    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"result\":" ++
            "{\"uri\":\"a\",\"range\":{\"start\":1,\"end\":2}}}",
        body_of(frozen.out.buffered()),
    );
}

test "a response names the id it answers" {
    var fixture: TestWriter = undefined;

    fixture.init(256);

    try null_response_write(&fixture.writer, &.{ .number = 3 });

    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":null}",
        fixture.written(),
    );

    fixture.init(256);

    try response_head(&fixture.writer, &.{ .string = "seven" });
    try fixture.writer.integer(1);
    try envelope_close(&fixture.writer);

    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":\"seven\",\"result\":1}",
        fixture.written(),
    );
}

test "a refusal carries its code and its sentence" {
    var fixture: TestWriter = undefined;

    fixture.init(256);

    try refusal_write(&fixture.writer, &.{ .number = 2 }, .method_not_found, "no such method");

    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32601,\"message\":\"no such method\"}}",
        fixture.written(),
    );

    fixture.init(256);

    try refusal_write(&fixture.writer, &.{ .absent = {} }, .internal, oversize_message);

    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":" ++
            "\"the answer is larger than the transport buffer\"}}",
        fixture.written(),
    );
}

test "a notification and a request name their method" {
    var fixture: TestWriter = undefined;

    fixture.init(256);

    try notification_head(&fixture.writer, "window/logMessage");
    try fixture.writer.object_begin();
    try fixture.writer.key("type");
    try fixture.writer.integer(3);
    try fixture.writer.key("message");
    try fixture.writer.string("hello");
    try fixture.writer.object_end();
    try envelope_close(&fixture.writer);

    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"window/logMessage\",\"params\":" ++
            "{\"type\":3,\"message\":\"hello\"}}",
        fixture.written(),
    );

    fixture.init(256);

    try request_head(&fixture.writer, 9, "client/registerCapability");
    try fixture.writer.null_value();
    try envelope_close(&fixture.writer);

    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"client/registerCapability\",\"params\":null}",
        fixture.written(),
    );
}

fn test_overflowing_write(writer: *json.Writer) json.Writer.Error!void {
    try response_head(writer, &.{ .number = 1 });
    try writer.string("far longer than sixteen bytes");
    try envelope_close(writer);
}

test "an envelope that outgrows its buffer is refused whole" {
    var fixture: TestWriter = undefined;

    fixture.init(16);

    try std.testing.expectError(error.WriteFailed, test_overflowing_write(&fixture.writer));
}

test "a string id is answered as serde_json spells its value" {
    var document: json.DocumentType(.{ .node_count_max = 64, .text_bytes_max = 64 }) = undefined;
    var fixture: TestWriter = undefined;

    const cases = [_][2][]const u8{
        .{ "{\"id\":\"\\u0041b\",\"method\":\"m\"}", "\"Ab\"" },
        .{ "{\"id\":\"\\/x\",\"method\":\"m\"}", "\"/x\"" },
        .{ "{\"id\":\"\\u00e9\",\"method\":\"m\"}", "\"\xc3\xa9\"" },
        .{ "{\"id\":\"\\u001F\\u000a\",\"method\":\"m\"}", "\"\\u001f\\n\"" },
        .{ "{\"id\":\"\\ud83d\\ude00\",\"method\":\"m\"}", "\"\xf0\x9f\x98\x80\"" },
        .{ "{\"id\":\"a\\\"b\",\"method\":\"m\"}", "\"a\\\"b\"" },
        .{ "{\"id\":\"\",\"method\":\"m\"}", "\"\"" },
    };

    for (cases) |case| {
        try document.parse(case[0]);

        const root = document.root();

        const envelope = rpc.Envelope.of(&document.base, root) orelse {
            return error.TestUnexpectedResult;
        };

        var expected: [128]u8 = undefined;

        const answer = try std.mem.print(
            &expected,
            "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":null}}",
            .{case[1]},
        );

        fixture.init(256);

        try null_response_write(&fixture.writer, &envelope.id);
        try std.testing.expectEqualStrings(answer, fixture.written());
    }

    const lone = document.parse("{\"id\":\"a\\ud800\",\"method\":\"m\"}");

    try std.testing.expectError(error.Malformed, lone);
}

test "a delivered message is framed and a dropped one only logs" {
    var frozen: TestFrozen = undefined;

    try frozen.init(body_bytes_max_test);
    defer frozen.deinit();

    const writer = try frozen.sender.notify_open("exit");

    try frozen.sender.delivered(writer.null_value());
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}",
        body_of(frozen.out.buffered()),
    );

    frozen.rewind();

    const flood: [body_bytes_max_test]u8 = @splat('x');
    const again = try frozen.sender.notify_open("exit");

    try frozen.sender.delivered(again.string(&flood));
    try std.testing.expectEqual(0, frozen.out.buffered().len);
    try std.testing.expectError(error.WriteFailed, frozen.sender.dropped(error.WriteFailed));
}
