const std = @import("std");
const assert = std.debug.assert;
const json = @import("json");
const Document = json.Document;
const Kind = json.Document.Kind;
const Node = json.Node;
const StaticAllocator = @import("../../stdx/static_allocator.zig");

pub const Code = enum(i64) {
    internal = -32603,
    invalid_params = -32602,
    invalid_request = -32600,
    method_not_found = -32601,
    parse = -32700,
    request_cancelled = -32800,
    server_not_initialized = -32002,
    _,
};

pub const Id = union(enum) {
    absent,
    number: i64,
    string: []const u8,

    pub fn of(document: *const Document, root: Node) ?Id {
        assert(@backingInt(root) < document.node_count);

        const held = document.member(root, "id") orelse return .absent;

        return switch (document.kind_of(held)) {
            .null_value => .absent,
            .number => if (document.integer_of(held)) |value| .{ .number = value } else null,
            .string => .{ .string = document.text_of(held).? },
            .array, .boolean, .object => null,
        };
    }

    pub fn equals(id: *const Id, value: i64) bool {
        if (id.* == .absent) return false;

        return switch (id.*) {
            .absent, .string => false,
            .number => |found| found == value,
        };
    }

    pub fn is_request(id: *const Id) bool {
        if (id.* == .absent) return false;

        const result = id.* != .absent;

        if (!result) assert(!id.equals(0));

        return result;
    }

    pub fn write(id: *const Id, writer: *json.Writer) std.Io.Writer.Error!void {
        switch (id.*) {
            .absent => try writer.null_value(),
            .number => |value| try writer.integer(value),
            .string => |text| try writer.string(text),
        }
    }
};

pub const Envelope = struct {
    id: Id,
    method: ?Node,
    params: ?Node,
    result: ?Node,

    pub fn of(document: *const Document, root: Node) ?Envelope {
        if (document.kind_of(root) != .object) return null;

        const method = document.member(root, "method");

        if (method) |held| {
            if (document.kind_of(held) != .string) return null;
        }

        const id = Id.of(document, root) orelse return null;

        return .{
            .id = id,
            .method = method,
            .params = document.member(root, "params"),
            .result = document.member(root, "result"),
        };
    }

    fn is_request(envelope: *const Envelope) bool {
        if (envelope.method == null) return false;
        return envelope.id.is_request();
    }

    fn is_response(envelope: *const Envelope) bool {
        const result = envelope.method == null;

        if (result) assert(!envelope.is_request());

        return result;
    }
};

pub const Refusal = enum {
    method_not_found,
    not_initialized,
    oversized,
    shutting_down,
    unparsable,

    pub fn code(refusal: Refusal) Code {
        const result: Code = switch (refusal) {
            .method_not_found => .method_not_found,
            .not_initialized => .server_not_initialized,
            .oversized => .invalid_request,
            .shutting_down => .invalid_request,
            .unparsable => .parse,
        };

        assert(@backingInt(result) < 0);

        return result;
    }

    pub fn text(refusal: Refusal) []const u8 {
        const result: []const u8 = switch (refusal) {
            .method_not_found => "the method is not served",
            .not_initialized => "the server has not been initialized",
            .oversized => "the message is larger than the transport buffer",
            .shutting_down => "the request is not valid in this state",
            .unparsable => "the message is not a valid JSON-RPC object",
        };

        assert(std.mem.startsWith(u8, result, "the "));

        return result;
    }
};

pub const version = "2.0";
const test_capacity: json.Capacity = .{ .node_count_max = 64, .text_bytes_max = 256 };

const TestFrozen = struct {
    document: Document,
    static_allocator: StaticAllocator,
    storage: json.Storage,

    fn init(frozen: *TestFrozen) !void {
        frozen.static_allocator = .init(std.testing.allocator);
        frozen.storage = try .init(frozen.static_allocator.allocator(), test_capacity);

        frozen.static_allocator.transition_from_init_to_static();
    }

    fn deinit(frozen: *TestFrozen) void {
        frozen.static_allocator.transition_from_static_to_deinit();
        frozen.storage.deinit(frozen.static_allocator.allocator());
        frozen.static_allocator.deinit();
    }

    fn parsed(frozen: *TestFrozen, message: []const u8) ?Envelope {
        assert(message.len <= std.math.maxInt(u32));

        frozen.document.parse(frozen.storage, message) catch return null;

        return Envelope.of(&frozen.document, frozen.document.root());
    }
};

test Envelope {
    var fixed: json.DocumentType(.{ .node_count_max = 16, .text_bytes_max = 64 }) = undefined;

    try fixed.parse("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"shutdown\"}");

    const root = fixed.root();
    const envelope = Envelope.of(&fixed.base, root) orelse return error.TestUnexpectedResult;

    try std.testing.expect(envelope.id.equals(7));
    try std.testing.expect(fixed.text_is(envelope.method.?, "shutdown"));
    try std.testing.expect(envelope.params == null);
}

test "a request carries a number id and a method" {
    var frozen: TestFrozen = undefined;

    try frozen.init();
    defer frozen.deinit();

    const message = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"shutdown\"}";
    const envelope = frozen.parsed(message).?;

    try std.testing.expectEqual(Id{ .number = 7 }, envelope.id);
    try std.testing.expect(envelope.id.equals(7));
    try std.testing.expect(!envelope.id.equals(8));
    try std.testing.expect(envelope.is_request());
    try std.testing.expect(!envelope.is_response());
    try std.testing.expect(frozen.document.text_is(envelope.method.?, "shutdown"));
    try std.testing.expect(envelope.params == null);
    try std.testing.expect(envelope.result == null);
}

test "a request carries a text id" {
    var frozen: TestFrozen = undefined;

    try frozen.init();
    defer frozen.deinit();

    const message = "{\"jsonrpc\":\"2.0\",\"id\":\"a-7\",\"method\":\"shutdown\",\"params\":{}}";
    const envelope = frozen.parsed(message).?;

    try std.testing.expect(envelope.id == .string);
    try std.testing.expectEqualStrings("a-7", envelope.id.string);
    try std.testing.expect(envelope.is_request());
    try std.testing.expect(envelope.params != null);
}

test "an escaped method reads as its decoded name" {
    var frozen: TestFrozen = undefined;

    try frozen.init();
    defer frozen.deinit();

    const message = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument\\/didOpen\"}";
    const envelope = frozen.parsed(message).?;

    try std.testing.expect(frozen.document.text_is(envelope.method.?, "textDocument/didOpen"));
}

test "a notification carries no id" {
    var frozen: TestFrozen = undefined;

    try frozen.init();
    defer frozen.deinit();

    const envelope = frozen.parsed("{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}").?;

    try std.testing.expectEqual(Id.absent, envelope.id);
    try std.testing.expect(!envelope.is_request());
    try std.testing.expect(!envelope.is_response());

    const message = "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"exit\"}";
    const nulled = frozen.parsed(message).?;

    try std.testing.expectEqual(Id.absent, nulled.id);
}

test "a response carries a result and no method" {
    var frozen: TestFrozen = undefined;

    try frozen.init();
    defer frozen.deinit();

    const message = "{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":[1]}";
    const envelope = frozen.parsed(message).?;

    try std.testing.expect(envelope.is_response());
    try std.testing.expect(!envelope.is_request());
    try std.testing.expect(envelope.id.is_request());
    try std.testing.expectEqual(Kind.array, frozen.document.kind_of(envelope.result.?));
}

test "a malformed envelope is refused" {
    var frozen: TestFrozen = undefined;

    try frozen.init();
    defer frozen.deinit();

    const unclosed = "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"";

    try std.testing.expect(frozen.parsed(unclosed) == null);
    try std.testing.expect(frozen.parsed("{\"jsonrpc\":\"2.0\"} {}") == null);
    try std.testing.expect(frozen.parsed("[1, 2]") == null);
    try std.testing.expect(frozen.parsed("{\"id\":1,\"method\":7}") == null);
    try std.testing.expect(frozen.parsed("{\"id\":[1],\"method\":\"exit\"}") == null);
    try std.testing.expect(frozen.parsed("{\"id\":true,\"method\":\"exit\"}") == null);
}

test "a code carries the number the protocol assigns it" {
    try std.testing.expectEqual(-32603, @backingInt(Code.internal));
    try std.testing.expectEqual(-32602, @backingInt(Code.invalid_params));
    try std.testing.expectEqual(-32600, @backingInt(Code.invalid_request));
    try std.testing.expectEqual(-32601, @backingInt(Code.method_not_found));
    try std.testing.expectEqual(-32700, @backingInt(Code.parse));
    try std.testing.expectEqual(-32800, @backingInt(Code.request_cancelled));
    try std.testing.expectEqual(-32002, @backingInt(Code.server_not_initialized));
}

test "an id writes back as it was read" {
    var frozen: TestFrozen = undefined;

    try frozen.init();
    defer frozen.deinit();

    var bytes: [64]u8 = undefined;

    const cases = [_][2][]const u8{
        .{ "{\"id\":7,\"method\":\"m\"}", "7" },
        .{ "{\"id\":\"a\\\"b\",\"method\":\"m\"}", "\"a\\\"b\"" },
        .{ "{\"method\":\"m\"}", "null" },
    };

    for (cases) |case| {
        const envelope = frozen.parsed(case[0]).?;
        var sink: std.Io.Writer = .fixed(&bytes);
        var writer: json.Writer = .init(&sink, .{});

        try envelope.id.write(&writer);

        writer.finish();

        try std.testing.expectEqualStrings(case[1], sink.buffered());
    }
}

test "every refusal carries a negative code and a reason" {
    for (std.enums.values(Refusal)) |refusal| {
        try std.testing.expect(@backingInt(refusal.code()) < 0);
        try std.testing.expect(refusal.text().len > 0);
    }

    try std.testing.expectEqual(Code.parse, Refusal.unparsable.code());
    try std.testing.expectEqual(Code.server_not_initialized, Refusal.not_initialized.code());
}
