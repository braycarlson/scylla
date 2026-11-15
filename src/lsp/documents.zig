const std = @import("std");
const assert = std.debug.assert;
const bounded = @import("../stdx/bounded.zig");
const json = @import("json");
const LineIndex = @import("../text/line_index.zig").LineIndex;
const text_document = @import("text_document.zig");
const Encoding = LineIndex.Encoding;
const Random = @import("../testing/random.zig");
const Span = bounded.Span;
const StaticAllocator = @import("../stdx/static_allocator.zig");
const TextDocument = text_document.TextDocument;

pub const Documents = struct {
    document_count: u32,
    encoding: Encoding,
    generations: []u32,
    items: []TextDocument,
    pool: *TextDocument.Pool,
    slots: []?Handle,

    pub const Capacity = struct {
        document_count_max: u32,
        line_count_max: u32,
        pool_bytes_max: u32,
        text_bytes_max: u32,
        text_bytes_min: u32,
        uri_bytes_max: u32,
    };

    pub const CapacityError = error{ DocumentsExhausted, UriTooLong };
    pub const Error = CapacityError || SyntaxError;
    pub const SyntaxError = error{UriInvalid};

    pub const Handle = struct {
        generation: u32,
        slot: u32,
    };

    pub const Handles = struct {
        documents: *const Documents,
        index: u32,
        remaining: u32,

        pub fn next(iterator: *Handles) ?Handle {
            const slot_count: u32 = @intCast(iterator.documents.slots.len);

            assert(iterator.index <= slot_count);
            assert(iterator.remaining <= iterator.documents.document_count);

            if (iterator.remaining == 0) return null;

            for (iterator.documents.slots[iterator.index..]) |held| {
                iterator.index += 1;

                const handle = held orelse continue;

                iterator.remaining -= 1;

                return handle;
            }

            unreachable;
        }
    };

    pub fn init(
        gpa: std.mem.Allocator,
        capacity: *const Capacity,
    ) std.mem.Allocator.Error!Documents {
        assert(capacity.document_count_max > 0);
        assert(capacity.uri_bytes_max > 0);

        const pool_capacity: TextDocument.Pool.Capacity = .{
            .document_count_max = capacity.document_count_max,
            .line_count_max = capacity.line_count_max,
            .pool_bytes_max = capacity.pool_bytes_max,
            .text_bytes_max = capacity.text_bytes_max,
            .text_bytes_min = capacity.text_bytes_min,
        };

        const pool = try text_document.pool_init(gpa, &pool_capacity);
        errdefer text_document.pool_deinit(pool, gpa);

        const documents = try gpa.alloc(TextDocument, capacity.document_count_max);
        errdefer gpa.free(documents);

        var initialised: u32 = 0;
        errdefer for (documents[0..initialised]) |*document| document.deinit(gpa);

        for (documents, 0..) |*document, slot| {
            document.* = try text_document.pooled_init(gpa, pool, capacity.uri_bytes_max);
            document.slot = @intCast(slot);
            initialised += 1;
        }

        const generations = try gpa.alloc(u32, capacity.document_count_max);
        errdefer gpa.free(generations);

        const slots = try gpa.alloc(?Handle, capacity.document_count_max);

        @memset(generations, 0);
        @memset(slots, null);

        return .{
            .document_count = 0,
            .encoding = .utf16,
            .generations = generations,
            .items = documents,
            .pool = pool,
            .slots = slots,
        };
    }

    pub fn deinit(documents: *Documents, gpa: std.mem.Allocator) void {
        assert(documents.document_count <= documents.items.len);
        assert(documents.slots.len == documents.items.len);

        for (documents.items) |*document| document.deinit(gpa);

        gpa.free(documents.items);
        gpa.free(documents.generations);
        gpa.free(documents.slots);
        text_document.pool_deinit(documents.pool, gpa);
        documents.* = undefined;
    }

    pub fn close(documents: *Documents, handle: Handle) void {
        assert(handle.slot < documents.slots.len);

        const index = documents.index_of(handle);
        const document = &documents.items[index];

        text_document.pooled_close(document);
        documents.slots[index] = null;
        documents.document_count -= 1;

        assert(documents.slots[index] == null);
        assert(document.place == null);
        assert(documents.live_count() == documents.document_count);
    }

    pub fn count(documents: *const Documents) u32 {
        assert(documents.document_count <= documents.items.len);

        return documents.document_count;
    }

    pub fn find(documents: *const Documents, uri: []const u8) ?Handle {
        if (uri.len == 0) return null;

        for (documents.slots, documents.items) |held, *document| {
            const handle = held orelse continue;

            assert(document.slot == handle.slot);

            if (std.mem.eql(u8, document.uri(), uri)) return handle;
        }

        return null;
    }

    pub fn find_text(
        documents: *const Documents,
        message: *const json.Document,
        uri: json.Node,
    ) ?Handle {
        if (message.kind_of(uri) != .string) return null;

        for (documents.slots, documents.items) |held, *document| {
            const handle = held orelse continue;

            assert(document.slot == handle.slot);
            assert(document.uri().len > 0);

            if (message.text_is(uri, document.uri())) return handle;
        }

        return null;
    }

    pub fn get(documents: *const Documents, handle: Handle) *const TextDocument {
        assert(handle.slot < documents.slots.len);

        const index = documents.index_of(handle);
        return &documents.items[index];
    }

    pub fn get_mut(documents: *Documents, handle: Handle) *TextDocument {
        assert(handle.slot < documents.slots.len);

        const index = documents.index_of(handle);
        return &documents.items[index];
    }

    fn handle_at(documents: *const Documents, index: u32) ?Handle {
        assert(index < documents.slots.len);

        const held = documents.slots[index];

        if (held) |handle| assert(handle.slot == index);

        return held;
    }

    pub fn handles(documents: *const Documents) Handles {
        assert(documents.slots.len > 0);
        assert(documents.document_count <= documents.slots.len);

        return .{ .documents = documents, .index = 0, .remaining = documents.document_count };
    }

    pub fn index_of(documents: *const Documents, handle: Handle) u32 {
        assert(handle.slot < documents.slots.len);

        const held = documents.slots[handle.slot];

        assert(held != null);
        assert(documents.items[handle.slot].slot == handle.slot);
        assert(documents.items[handle.slot].place != null);

        if (held) |live| assert(live.generation == handle.generation);

        return handle.slot;
    }

    pub fn open(documents: *Documents, uri: []const u8) Error!Handle {
        if (uri.len == 0) return error.UriInvalid;
        if (documents.find(uri)) |handle| return handle;

        const slot = documents.slot_free() orelse return error.DocumentsExhausted;
        const document = &documents.items[slot];

        assert(documents.slots[slot] == null);
        assert(document.place == null);

        text_document.pooled_open(document, uri) catch |err| return switch (err) {
            error.PoolExhausted => error.DocumentsExhausted,
            error.UriTooLong => error.UriTooLong,
        };

        document.encoding_set(documents.encoding);
        documents.generations[slot] += 1;

        const handle: Handle = .{ .generation = documents.generations[slot], .slot = slot };

        documents.slots[slot] = handle;
        documents.document_count += 1;

        assert(documents.document_count <= documents.items.len);
        assert(documents.live_count() == documents.document_count);

        return handle;
    }

    pub fn open_text(
        documents: *Documents,
        message: *const json.Document,
        uri: json.Node,
    ) Error!Handle {
        assert(@backingInt(uri) < message.node_count);

        const text = message.text_of(uri) orelse return error.UriInvalid;
        return documents.open(text);
    }

    pub fn encoding_get(documents: *const Documents) Encoding {
        return documents.encoding;
    }

    pub fn encoding_set(documents: *Documents, encoding: Encoding) void {
        documents.encoding = encoding;

        assert(documents.encoding == encoding);
    }

    fn live_count(documents: *const Documents) u32 {
        var live: u32 = 0;

        for (documents.slots) |held| {
            if (held != null) live += 1;
        }

        assert(live <= documents.slots.len);

        return live;
    }

    fn slot_free(documents: *const Documents) ?u32 {
        for (documents.slots, 0..) |held, slot| {
            if (held == null) {
                assert(slot < documents.slots.len);

                return @intCast(slot);
            }
        }

        assert(documents.document_count == documents.slots.len);

        return null;
    }
};

const test_edit_count: u32 = 4_000;
const test_line_count_max: u32 = 8;
const test_text_bytes_max: u32 = 1 << 12;
const test_uri_bytes_max: u32 = 64;

const test_capacity: Documents.Capacity = .{
    .document_count_max = 2,
    .line_count_max = test_line_count_max,
    .pool_bytes_max = 2 * test_text_bytes_max,
    .text_bytes_max = test_text_bytes_max,
    .text_bytes_min = test_text_bytes_max,
    .uri_bytes_max = test_uri_bytes_max,
};

const test_pooled_capacity: Documents.Capacity = .{
    .document_count_max = 8,
    .line_count_max = 64,
    .pool_bytes_max = 4_096,
    .text_bytes_max = 512,
    .text_bytes_min = 64,
    .uri_bytes_max = test_uri_bytes_max,
};

const TestReader = json.DocumentType(.{ .node_count_max = 4, .text_bytes_max = 128 });

fn parsed(reader: *TestReader, source: []const u8) !json.Node {
    assert(source.len <= std.math.maxInt(u32));

    try reader.parse(source);

    return reader.root();
}

test Documents {
    var documents: Documents = try .init(std.testing.allocator, &.{
        .document_count_max = 2,
        .line_count_max = 8,
        .pool_bytes_max = 1 << 10,
        .text_bytes_max = 256,
        .text_bytes_min = 64,
        .uri_bytes_max = 32,
    });

    defer documents.deinit(std.testing.allocator);

    const handle = try documents.open("file:///a.zig");

    try documents.get_mut(handle).text_replace("const a = 1;\n");
    try std.testing.expectEqual(handle, documents.find("file:///a.zig"));
    try std.testing.expectEqualStrings("const a = 1;\n", documents.get(handle).text_bytes());

    documents.close(handle);

    try std.testing.expectEqual(null, documents.find("file:///a.zig"));
}

test "a pool finds opened documents by uri and reuses closed slots" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var held = try Documents.init(static_allocator.allocator(), &test_capacity);
    defer held.deinit(static_allocator.allocator());

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    const first = try held.open("file:///a.rs");

    try std.testing.expectEqual(first, try held.open("file:///a.rs"));
    _ = try held.open("file:///b.rs");

    try std.testing.expectEqual(2, held.count());
    try std.testing.expectError(error.DocumentsExhausted, held.open("file:///c.rs"));
    try std.testing.expectEqual(first, held.find("file:///a.rs"));
    try std.testing.expectEqual(null, held.find("file:///c.rs"));
    try std.testing.expectEqualStrings("file:///a.rs", held.get(first).uri());

    const second = held.find("file:///b.rs") orelse return error.TestUnexpectedResult;
    const index = held.index_of(first);

    try std.testing.expect(index < 2);
    try std.testing.expect(index != held.index_of(second));
    try std.testing.expectEqual(first, held.handle_at(index));
    try std.testing.expectEqual(second, held.handle_at(held.index_of(second)));

    held.get_mut(first).version_set(4);

    try std.testing.expectEqual(4, held.get(first).version_get());

    held.close(first);

    try std.testing.expectEqual(1, held.count());
    try std.testing.expectEqual(null, held.find("file:///a.rs"));
    try std.testing.expectEqual(null, held.handle_at(index));
    try std.testing.expect(held.find("file:///b.rs") != null);

    const reused = try held.open("file:///c.rs");

    try std.testing.expectEqualStrings("file:///c.rs", held.get(reused).uri());
    try std.testing.expectEqual(0, held.get(reused).version_get());
    try std.testing.expectEqual(reused, held.find("file:///c.rs"));
    try std.testing.expectEqual(index, held.index_of(reused));
    try std.testing.expectEqual(reused, held.handle_at(index));
    try std.testing.expect(!std.meta.eql(reused, first));

    var iterator = held.handles();
    var handle_count: u32 = 0;

    for (0..test_capacity.document_count_max + 1) |_| {
        _ = iterator.next() orelse break;

        handle_count += 1;
    }

    try std.testing.expectEqual(2, handle_count);
    try std.testing.expectEqual(0, iterator.remaining);
}

test "the handle walk yields each open document once in slot order" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var held = try Documents.init(static_allocator.allocator(), &test_pooled_capacity);
    defer held.deinit(static_allocator.allocator());

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    const uris = [_][]const u8{ "file:///0", "file:///1", "file:///2", "file:///3" };
    var opened: [uris.len]Documents.Handle = undefined;

    for (uris, &opened) |uri, *handle| handle.* = try held.open(uri);

    held.close(opened[1]);

    var iterator = held.handles();

    try std.testing.expectEqual(3, iterator.remaining);

    const iterator_next_first = iterator.next();
    const iterator_next_second = iterator.next();
    const iterator_next_third = iterator.next();
    const iterator_next_fourth = iterator.next();

    try std.testing.expectEqual(opened[0], iterator_next_first);
    try std.testing.expectEqual(opened[2], iterator_next_second);
    try std.testing.expectEqual(opened[3], iterator_next_third);
    try std.testing.expectEqual(null, iterator_next_fourth);
    try std.testing.expectEqual(0, iterator.remaining);
}

test "a pool opens by json text and hands its encoding down" {
    const long = "\"file:///" ++ @as([test_uri_bytes_max]u8, @splat('x')) ++ "\"";
    const longer = "file:///" ++ @as([test_uri_bytes_max]u8, @splat('x'));
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var held = try Documents.init(static_allocator.allocator(), &test_capacity);
    defer held.deinit(static_allocator.allocator());

    var reader: TestReader = undefined;

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    held.encoding_set(.utf8);

    try std.testing.expectEqual(Encoding.utf8, held.encoding_get());

    const handle = try held.open_text(&reader.base, try parsed(&reader, "\"file:///a.rs\""));

    try std.testing.expectEqual(Encoding.utf8, held.get(handle).encoding);

    const same = try parsed(&reader, "\"file:///a.rs\"");

    try std.testing.expectEqual(handle, held.find_text(&reader.base, same));

    const other = try parsed(&reader, "\"file:///b.rs\"");

    try std.testing.expectEqual(null, held.find_text(&reader.base, other));

    const empty = try parsed(&reader, "\"\"");

    try std.testing.expectError(error.UriInvalid, held.open_text(&reader.base, empty));

    const number = try parsed(&reader, "7");

    try std.testing.expectError(error.UriInvalid, held.open_text(&reader.base, number));

    const oversized = try parsed(&reader, long);

    try std.testing.expectError(error.UriTooLong, held.open_text(&reader.base, oversized));
    try std.testing.expectError(error.UriTooLong, held.open(longer));
    try std.testing.expectError(error.UriInvalid, held.open(""));
    try std.testing.expectEqual(1, held.count());
}

fn test_opened(documents: *Documents, uri: []const u8) !Documents.Handle {
    assert(uri.len <= std.math.maxInt(u32));

    return documents.open(uri);
}

test "a pooled document moves up a class as it grows and its neighbours stay put" {
    const grown: [100]u8 = @splat('x');
    const huge: [600]u8 = @splat('y');
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var held = try Documents.init(static_allocator.allocator(), &test_pooled_capacity);
    defer held.deinit(static_allocator.allocator());

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    const first = try test_opened(&held, "file:///a.html");
    const second = try test_opened(&held, "file:///b.html");

    try held.get_mut(first).text_replace("one\ntwo\n");
    try held.get_mut(second).text_replace("<p></p>\n");

    const neighbour = held.get(second).text_bytes().ptr;

    try std.testing.expectEqual(0, held.get(first).place.?.class);
    try held.get_mut(first).splice(Span.between(4, 4), &grown);
    try std.testing.expectEqual(1, held.get(first).place.?.class);
    try std.testing.expectEqualStrings("one\n" ++ grown ++ "two\n", held.get(first).text_bytes());
    try std.testing.expectEqual(3, held.get(first).line_count());
    try std.testing.expectEqual(neighbour, held.get(second).text_bytes().ptr);
    try std.testing.expectEqualStrings("<p></p>\n", held.get(second).text_bytes());

    try std.testing.expectError(
        error.TextExhausted,
        held.get_mut(first).splice(Span.between(0, 0), &huge),
    );

    try std.testing.expectEqual(108, held.get(first).text_count());

    try held.get_mut(first).text_replace("small");

    try std.testing.expectEqual(0, held.get(first).place.?.class);
    try std.testing.expectEqualStrings("small", held.get(first).text_bytes());
    try std.testing.expectEqual(neighbour, held.get(second).text_bytes().ptr);
}

test "a pooled document with many short lines takes a class that holds its lines" {
    const breaks: [40]u8 = @splat('\n');
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var held = try Documents.init(static_allocator.allocator(), &test_pooled_capacity);
    defer held.deinit(static_allocator.allocator());

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    const handle = try test_opened(&held, "file:///lines.html");

    try held.get_mut(handle).text_replace(&breaks);
    try std.testing.expectEqual(3, held.get(handle).place.?.class);
    try std.testing.expectEqual(41, held.get(handle).line_count());

    const flood: [70]u8 = @splat('\n');

    try std.testing.expectError(error.LinesExhausted, held.get_mut(handle).text_replace(&flood));
    try std.testing.expectEqual(1, held.get(handle).line_count());
}

test "a pool holds more documents than its largest class has slots" {
    const large: [500]u8 = @splat('z');
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var held = try Documents.init(static_allocator.allocator(), &test_pooled_capacity);
    defer held.deinit(static_allocator.allocator());

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    const uris = [_][]const u8{
        "file:///0.html",
        "file:///1.html",
        "file:///2.html",
        "file:///3.html",
        "file:///4.html",
        "file:///5.html",
        "file:///6.html",
        "file:///7.html",
    };

    var handles: [uris.len]Documents.Handle = undefined;

    for (uris, &handles) |uri, *handle| {
        handle.* = try test_opened(&held, uri);

        try held.get_mut(handle.*).text_replace(uri);
    }

    try std.testing.expectEqual(8, held.count());
    try std.testing.expectError(error.DocumentsExhausted, held.open("file:///8.html"));

    try held.get_mut(handles[0]).text_replace(&large);
    try held.get_mut(handles[1]).text_replace(&large);
    try std.testing.expectError(error.TextExhausted, held.get_mut(handles[2]).text_replace(&large));
    try std.testing.expectEqual(0, held.get(handles[2]).text_count());

    held.close(handles[0]);

    try held.get_mut(handles[2]).text_replace(&large);

    for (uris[3..], handles[3..]) |uri, handle| {
        try std.testing.expectEqualStrings(uri, held.get(handle).text_bytes());
    }
}

test "a pooled edit sequence matches documents that own their text" {
    const run: [40]u8 = @splat('x');
    const words = [_][]const u8{ "", "a", "\n", "ab\nc", "\n\n\n\n", "\u{00e9}", &run };
    const uris = [_][]const u8{ "file:///a", "file:///b", "file:///c", "file:///d" };

    const capacity: Documents.Capacity = .{
        .document_count_max = uris.len,
        .line_count_max = 64,
        .pool_bytes_max = 8 * uris.len * 512,
        .text_bytes_max = 512,
        .text_bytes_min = 32,
        .uri_bytes_max = test_uri_bytes_max,
    };

    const mirror_capacity: TextDocument.Capacity = .{
        .line_count_max = 64,
        .text_bytes_max = 512,
        .uri_bytes_max = test_uri_bytes_max,
    };

    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var held = try Documents.init(static_allocator.allocator(), &capacity);
    defer held.deinit(static_allocator.allocator());

    var mirrors: [uris.len]TextDocument = undefined;
    var mirrored: u32 = 0;
    defer for (mirrors[0..mirrored]) |*mirror| mirror.deinit(static_allocator.allocator());

    for (&mirrors) |*mirror| {
        mirror.* = try .init(static_allocator.allocator(), mirror_capacity);
        mirrored += 1;
    }

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    var random: Random = .init(0x9E37_79B9_7F4A_7C15);
    var moves: u32 = 0;

    for (0..test_edit_count) |_| {
        const pick = random.below(uris.len);
        const before = test_places(&held, &uris);

        test_step(&held, &random, &mirrors[pick], uris[pick], &words) catch |err| switch (err) {
            error.TestUnexpectedResult => return err,
        };

        const after = test_places(&held, &uris);

        for (before, after, 0..) |was, now, index| {
            if (index == pick) {
                if (test_moved(was, now)) moves += 1;
            } else {
                try std.testing.expectEqual(was, now);
            }
        }

        try test_mirrored(&held, &uris, &mirrors);
    }

    try std.testing.expect(moves > 100);
}

fn test_mirrored(
    held: *const Documents,
    uris: []const []const u8,
    mirrors: []const TextDocument,
) !void {
    assert(uris.len == mirrors.len);

    for (uris, mirrors) |uri, *mirror| {
        const handle = held.find(uri) orelse continue;
        const document = held.get(handle);

        try std.testing.expectEqualStrings(mirror.text_bytes(), document.text_bytes());

        try std.testing.expectEqualSlices(
            u32,
            mirror.lines.starts.const_slice(),
            document.lines.starts.const_slice(),
        );
    }
}

fn test_moved(was: ?usize, now: ?usize) bool {
    if (was) |held| assert(held != 0);
    if (now) |held| assert(held != 0);

    const before = was orelse return false;
    const after = now orelse return false;

    return before != after;
}

fn test_places(documents: *const Documents, uris: []const []const u8) [4]?usize {
    var places: [4]?usize = @splat(null);

    assert(uris.len == places.len);

    for (uris, &places) |uri, *place| {
        const handle = documents.find(uri) orelse continue;

        place.* = @intFromPtr(documents.get(handle).text.bytes.ptr);
    }

    return places;
}

fn test_step(
    documents: *Documents,
    random: *Random,
    mirror: *TextDocument,
    uri: []const u8,
    words: []const []const u8,
) error{TestUnexpectedResult}!void {
    assert(uri.len <= std.math.maxInt(u32));
    assert(words.len <= std.math.maxInt(u32));

    const handle = documents.find(uri) orelse {
        const opened = documents.open(uri) catch return error.TestUnexpectedResult;

        mirror.text_replace("") catch return error.TestUnexpectedResult;

        return test_compare(
            documents.get_mut(opened).text_replace(""),
            mirror.text_replace(""),
        );
    };

    const document = documents.get_mut(handle);
    const count = document.text_count();
    const start = random.below(count + 1);
    const end = start + random.below(count + 1 - start);
    const word = words[random.below(@intCast(words.len))];

    switch (random.below(8)) {
        0 => {
            documents.close(handle);
            mirror.text_replace("") catch return error.TestUnexpectedResult;
        },
        1 => try test_compare(document.text_replace(word), mirror.text_replace(word)),
        else => try test_compare(
            document.splice(Span.between(start, end), word),
            mirror.splice(Span.between(start, end), word),
        ),
    }
}

fn test_compare(
    pooled: TextDocument.Error!void,
    owned: TextDocument.Error!void,
) error{TestUnexpectedResult}!void {
    if (test_outcome(pooled) != test_outcome(owned)) return error.TestUnexpectedResult;
}

fn test_outcome(result: TextDocument.Error!void) u8 {
    result catch |err| return switch (err) {
        error.LinesExhausted => 1,
        error.TextExhausted => 2,
        error.Utf8Invalid => 3,
    };

    return 0;
}
