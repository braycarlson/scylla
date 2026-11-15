const std = @import("std");
const assert = std.debug.assert;
const Transport = @import("reader.zig");
const framing = @import("framing.zig");
const log = @import("../../stdx/log.zig");

shared: *Shared,
thread: std.Thread,

const Relay = @This();

pub const Reader = struct {
    interface: std.Io.Reader,
    relay: *Relay,

    fn stream(
        io_reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        assert(limit != .nothing);

        const adapter: *Reader = @alignCast(@fieldParentPtr("interface", io_reader));
        const target = limit.slice(try writer.writableSliceGreedy(1));

        assert(target.len > 0);

        const read_count = try adapter.relay.read(target);
        if (read_count == 0) return error.EndOfStream;

        assert(read_count <= target.len);

        writer.advance(read_count);

        return read_count;
    }
};

const Cancelled = struct {
    held: [cancel_id_count_max]i64,
    id_count: u32,
    next: u32,

    const empty: Cancelled = .{ .held = @splat(0), .id_count = 0, .next = 0 };

    fn push(table: *Cancelled, id: i64) void {
        assert(table.id_count <= cancel_id_count_max);
        assert(table.next < cancel_id_count_max);
        assert(id < std.math.maxInt(u32));

        const known = table.held[0..table.id_count];
        if (std.mem.findScalar(i64, known, id) != null) return;

        table.held[table.next] = id;
        table.next = wrapped(table.next + 1, cancel_id_count_max);
        table.id_count = @min(table.id_count + 1, cancel_id_count_max);

        assert(table.id_count > 0);
    }

    fn take(table: *Cancelled, id: i64) bool {
        assert(table.id_count <= cancel_id_count_max);
        assert(id < std.math.maxInt(u32));

        const known = table.held[0..table.id_count];
        const at = std.mem.findScalar(i64, known, id) orelse return false;
        const kept = table.id_count - 1;

        std.mem.swap(i64, &table.held[at], &table.held[kept]);
        table.id_count = kept;
        table.next = kept;

        assert(table.next < cancel_id_count_max);

        return true;
    }
};

const Ring = struct {
    bytes: []u8,
    closed: bool,
    faulted: bool,
    head: u32,
    used: u32,

    fn pop(ring: *Ring, out: []u8) u32 {
        assert(out.len <= std.math.maxInt(u32));

        const ring_capacity: u32 = @intCast(ring.bytes.len);
        const wanted: u32 = @intCast(@min(out.len, ring.used));
        const front = @min(wanted, ring_capacity - ring.head);
        const back = wanted - front;

        assert(ring.used <= ring_capacity);

        @memcpy(out[0..front], ring.bytes[ring.head..][0..front]);
        @memcpy(out[front..wanted], ring.bytes[0..back]);
        ring.head = wrapped(ring.head + wanted, ring_capacity);
        ring.used -= wanted;

        assert(ring.head < ring_capacity);

        return wanted;
    }

    fn push(ring: *Ring, bytes: []const u8) u32 {
        assert(bytes.len <= std.math.maxInt(u32));

        const ring_capacity: u32 = @intCast(ring.bytes.len);
        const wanted: u32 = @intCast(@min(bytes.len, ring_capacity - ring.used));
        const tail = wrapped(ring.head + ring.used, ring_capacity);
        const front = @min(wanted, ring_capacity - tail);
        const back = wanted - front;

        assert(ring.used <= ring_capacity);

        @memcpy(ring.bytes[tail..][0..front], bytes[0..front]);
        @memcpy(ring.bytes[0..back], bytes[front..wanted]);
        ring.used += wanted;

        assert(ring.used <= ring_capacity);

        return wanted;
    }
};

const Shared = struct {
    cancelled: Cancelled,
    cancelled_mutex: std.Io.Mutex,
    drained: std.Io.Condition,
    filled: std.Io.Condition,
    io: std.Io,
    ring: Ring,
    ring_mutex: std.Io.Mutex,
    source: *std.Io.Reader,
    transport: Transport,

    fn close(shared: *Shared, faulted: bool) void {
        shared.ring_mutex.lockUncancelable(shared.io);
        defer shared.ring_mutex.unlock(shared.io);

        shared.ring.closed = true;
        shared.ring.faulted = shared.ring.faulted or faulted;

        shared.filled.broadcast(shared.io);
        shared.drained.broadcast(shared.io);

        assert(shared.ring.closed);
    }

    fn feed(shared: *Shared, bytes: []const u8) error{Closed}!void {
        assert(bytes.len <= std.math.maxInt(u32));

        var left = bytes;

        for (0..bytes.len + 1) |_| {
            if (left.len == 0) return;

            left = left[try shared.feed_some(left)..];
        } else unreachable;
    }

    fn feed_some(shared: *Shared, bytes: []const u8) error{Closed}!u32 {
        assert(bytes.len > 0);

        shared.ring_mutex.lockUncancelable(shared.io);
        defer shared.ring_mutex.unlock(shared.io);

        for (0..wait_count_max) |_| {
            if (shared.ring.closed) return error.Closed;

            const written = shared.ring.push(bytes);

            if (written > 0) {
                shared.filled.signal(shared.io);

                return written;
            }

            shared.drained.waitUncancelable(shared.io, &shared.ring_mutex);
        } else unreachable;
    }
};

pub const cancel_id_count_max: u32 = 256;
const dropped_message = "a {d} byte inbound message outgrew the transport buffer and is dropped";
const message_count_max: u64 = 1 << 48;
const wait_count_max: u64 = 1 << 48;

pub fn init(
    gpa: std.mem.Allocator,
    io: std.Io,
    source: *std.Io.Reader,
    request_bytes_max: u32,
    ring_bytes: u32,
    comptime inspect: fn ([]const u8) ?i64,
) (error{OutOfMemory} || std.Thread.SpawnError)!Relay {
    assert(ring_bytes > 0);
    assert(request_bytes_max > 0);

    const shared = try gpa.create(Shared);
    errdefer gpa.destroy(shared);

    const bytes = try gpa.alloc(u8, ring_bytes);
    errdefer gpa.free(bytes);

    var transport = try Transport.init(gpa, request_bytes_max);
    errdefer transport.deinit(gpa);

    @memset(bytes, 0);

    shared.* = .{
        .cancelled = .empty,
        .cancelled_mutex = .init,
        .drained = .init,
        .filled = .init,
        .io = io,
        .ring = .{ .bytes = bytes, .closed = false, .faulted = false, .head = 0, .used = 0 },
        .ring_mutex = .init,
        .source = source,
        .transport = transport,
    };

    const thread = try std.Thread.spawn(.{}, FeederType(inspect).serve, .{shared});
    return .{ .shared = shared, .thread = thread };
}

pub fn deinit(relay: *Relay, gpa: std.mem.Allocator) void {
    assert(relay.shared.ring.bytes.len > 0);

    relay.shared.close(false);
    relay.thread.join();
    relay.shared.transport.deinit(gpa);
    gpa.free(relay.shared.ring.bytes);
    gpa.destroy(relay.shared);
    relay.* = undefined;
}

pub fn cancelled(relay: *Relay, id: i64) bool {
    assert(id < std.math.maxInt(u32));

    const shared = relay.shared;

    shared.cancelled_mutex.lockUncancelable(shared.io);
    defer shared.cancelled_mutex.unlock(shared.io);

    assert(shared.cancelled.id_count <= cancel_id_count_max);

    return shared.cancelled.take(id);
}

pub fn reader(relay: *Relay, buffer: []u8) Reader {
    assert(buffer.len > 0);
    assert(relay.shared.ring.bytes.len > 0);

    return .{
        .interface = .{
            .vtable = &.{ .stream = Reader.stream },
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        },
        .relay = relay,
    };
}

pub fn read(relay: *Relay, out: []u8) error{ReadFailed}!u32 {
    assert(out.len <= std.math.maxInt(u32));

    const shared = relay.shared;

    if (out.len == 0) return 0;

    shared.ring_mutex.lockUncancelable(shared.io);
    defer shared.ring_mutex.unlock(shared.io);

    for (0..wait_count_max) |_| {
        if (shared.ring.used > 0) break;
        if (shared.ring.faulted) return error.ReadFailed;
        if (shared.ring.closed) return 0;

        shared.filled.waitUncancelable(shared.io, &shared.ring_mutex);
    } else unreachable;

    const read_count = shared.ring.pop(out);

    assert(read_count > 0);

    shared.drained.signal(shared.io);

    return read_count;
}

fn FeederType(comptime inspect: fn ([]const u8) ?i64) type {
    return struct {
        fn serve(shared: *Shared) void {
            for (0..message_count_max) |_| {
                const body = shared.transport.read(shared.source) catch |err| switch (err) {
                    error.TooLarge => {
                        const bytes = shared.transport.declared_length();

                        log.line(dropped_message, .{bytes});

                        continue;
                    },
                    error.Malformed => {
                        shared.feed("\r\n") catch |failure| switch (failure) {
                            error.Closed => {},
                        };

                        shared.close(false);

                        return;
                    },
                    error.ReadFailed => return shared.close(true),
                    error.Closed => return shared.close(false),
                };

                if (!serve_message(shared, body)) return;
            } else unreachable;
        }

        fn serve_message(shared: *Shared, body: []const u8) bool {
            assert(body.len <= shared.transport.capacity());

            if (inspect(body)) |id| {
                shared.cancelled_mutex.lockUncancelable(shared.io);
                defer shared.cancelled_mutex.unlock(shared.io);

                shared.cancelled.push(id);
            }

            var header: [framing.header_bytes_max]u8 = undefined;
            const header_length = framing.header_write(&header, body.len);

            shared.feed(header[0..header_length]) catch return false;
            shared.feed(body) catch return false;

            return true;
        }
    };
}

fn wrapped(at: u32, ring_capacity: u32) u32 {
    assert(ring_capacity > 0);
    assert(at < ring_capacity * 2);

    if (at >= ring_capacity) {
        assert(at - ring_capacity < std.math.maxInt(u32));

        return at - ring_capacity;
    }

    return at;
}

const body_cancel = "{\"jsonrpc\":\"2.0\",\"method\":\"$/cancelRequest\",\"params\":{\"id\":1}}";
const body_hover_one = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"textDocument/hover\"}";
const request_bytes_max_test: u32 = 1 << 12;
const body_hover_two = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\"}";

fn framed_all(buffer: []u8, bodies: []const []const u8) []const u8 {
    assert(buffer.len <= std.math.maxInt(u32));
    assert(bodies.len <= std.math.maxInt(u32));

    var writer: std.Io.Writer = .fixed(buffer);

    for (bodies) |message| framing.framed(&writer, message) catch unreachable;

    return writer.buffered();
}

fn inspect_test(body: []const u8) ?i64 {
    assert(body.len <= std.math.maxInt(u32));

    if (std.mem.find(u8, body, body_cancel) != null) return 1;
    return null;
}

fn relayed(relay: *Relay, out: []u8) []const u8 {
    assert(out.len <= std.math.maxInt(u32));

    var filled: usize = 0;

    for (0..out.len + 1) |_| {
        const read_count = relay.read(out[filled..]) catch 0;
        if (read_count == 0) break;

        filled += read_count;
    }

    return out[0..filled];
}

test "a cancel read ahead marks its request before the session reaches it" {
    var buffer: [1 << 10]u8 = undefined;
    const source_bytes = framed_all(&buffer, &.{ body_hover_one, body_cancel, body_hover_two });
    var source: std.Io.Reader = .fixed(source_bytes);

    var relay = try Relay.init(
        std.testing.allocator,
        std.testing.io,
        &source,
        request_bytes_max_test,
        1 << 12,
        inspect_test,
    );

    defer relay.deinit(std.testing.allocator);

    var out: [1 << 10]u8 = undefined;
    const relayed_bytes = relayed(&relay, out[0 .. source_bytes.len + 1]);

    try std.testing.expectEqualStrings(source_bytes, relayed_bytes);
    try std.testing.expect(relay.cancelled(1));
    try std.testing.expect(!relay.cancelled(1));
    try std.testing.expect(!relay.cancelled(2));
}

test "a ring smaller than one message still streams it through" {
    var buffer: [1 << 10]u8 = undefined;
    const source_bytes = framed_all(&buffer, &.{ body_hover_one, body_hover_two });
    var source: std.Io.Reader = .fixed(source_bytes);

    var relay = try Relay.init(
        std.testing.allocator,
        std.testing.io,
        &source,
        request_bytes_max_test,
        16,
        inspect_test,
    );

    defer relay.deinit(std.testing.allocator);

    var out: [1 << 10]u8 = undefined;
    const relayed_bytes = relayed(&relay, out[0 .. source_bytes.len + 1]);

    try std.testing.expectEqualStrings(source_bytes, relayed_bytes);
}

test "a closed source closes the relay" {
    var source: std.Io.Reader = .fixed("");

    var relay = try Relay.init(
        std.testing.allocator,
        std.testing.io,
        &source,
        request_bytes_max_test,
        1 << 12,
        inspect_test,
    );

    defer relay.deinit(std.testing.allocator);

    var out: [1]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 0), relayed(&relay, &out).len);
}

test "a malformed frame reaches the session as malformed" {
    var source: std.Io.Reader = .fixed("nonsense\r\n\r\n");

    var relay = try Relay.init(
        std.testing.allocator,
        std.testing.io,
        &source,
        request_bytes_max_test,
        1 << 12,
        inspect_test,
    );

    defer relay.deinit(std.testing.allocator);

    var transport = try Transport.init(std.testing.allocator, request_bytes_max_test);
    defer transport.deinit(std.testing.allocator);

    var buffer: [64]u8 = undefined;
    var session = relay.reader(&buffer);

    try std.testing.expectError(error.Malformed, transport.read(&session.interface));
    try std.testing.expectError(error.Closed, transport.read(&session.interface));
}

test "a cancel table remembers each id once and spends it on take" {
    var cancelled_table: Cancelled = .empty;

    cancelled_table.push(7);
    cancelled_table.push(7);
    cancelled_table.push(9);

    try std.testing.expectEqual(@as(u32, 2), cancelled_table.id_count);
    try std.testing.expect(cancelled_table.take(7));
    try std.testing.expect(!cancelled_table.take(7));
    try std.testing.expect(cancelled_table.take(9));
    try std.testing.expectEqual(@as(u32, 0), cancelled_table.id_count);
}

test "a full cancel table overwrites its oldest entry" {
    var cancelled_table: Cancelled = .empty;

    for (0..cancel_id_count_max + 1) |id| cancelled_table.push(@intCast(id));

    try std.testing.expectEqual(cancel_id_count_max, cancelled_table.id_count);
    try std.testing.expect(!cancelled_table.take(0));
    try std.testing.expect(cancelled_table.take(cancel_id_count_max));
}
