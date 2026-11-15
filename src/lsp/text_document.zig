const std = @import("std");
const assert = std.debug.assert;
const bounded = @import("../stdx/bounded.zig");
const json = @import("json");
const LineIndex = @import("../text/line_index.zig").LineIndex;
const scan = @import("../text/scan.zig");
const ArrayType = bounded.ArrayType;
const Buffer = bounded.Buffer;
const Encoding = LineIndex.Encoding;
const Point = LineIndex.Point;
const Random = @import("../testing/random.zig");
const Range = LineIndex.Range;
const Span = bounded.Span;
const StaticAllocator = @import("../stdx/static_allocator.zig");
const log = @import("../stdx/log.zig");
const path = @import("../platform/path.zig");

pub const TextDocument = struct {
    encoding: Encoding,
    lines: LineIndex,
    place: ?TextPool.Place,
    pool: ?*TextPool,
    slot: u32,
    text: Buffer,
    uri_bytes: Buffer,
    version: i64,

    pub const Capacity = struct {
        line_count_max: u32,
        text_bytes_max: u32,
        uri_bytes_max: u32,
    };

    pub const CapacityError = error{ LinesExhausted, TextExhausted };
    pub const ChangeError = Error || RangeError;
    pub const Error = CapacityError || SyntaxError;
    pub const LoadError = Error || error{FileUnreadable};
    pub const Pool = TextPool;
    pub const RangeError = error{ RangeBackward, RangeOutside };
    pub const ReadError = Error || StreamError;
    pub const StreamError = error{ReadFailed};
    pub const SyntaxError = error{Utf8Invalid};
    pub const UriError = error{UriTooLong};

    pub fn init(gpa: std.mem.Allocator, capacity: Capacity) std.mem.Allocator.Error!TextDocument {
        assert(capacity.line_count_max > 0);
        assert(capacity.text_bytes_max > 0);
        assert(capacity.uri_bytes_max > 0);

        var lines = try LineIndex.init(gpa, capacity.line_count_max);
        errdefer lines.deinit(gpa);

        var text = try Buffer.init(gpa, capacity.text_bytes_max);
        errdefer text.deinit(gpa);

        const uri_bytes = try Buffer.init(gpa, capacity.uri_bytes_max);

        const document: TextDocument = .{
            .encoding = .utf16,
            .lines = lines,
            .place = null,
            .pool = null,
            .slot = 0,
            .text = text,
            .uri_bytes = uri_bytes,
            .version = 0,
        };

        assert(document.line_count() == 1);

        return document;
    }

    fn init_pooled(
        gpa: std.mem.Allocator,
        pool: *TextPool,
        uri_bytes_max: u32,
    ) std.mem.Allocator.Error!TextDocument {
        assert(uri_bytes_max > 0);
        assert(pool.class_count > 0);

        const uri_bytes = try Buffer.init(gpa, uri_bytes_max);

        return .{
            .encoding = .utf16,
            .lines = undefined,
            .place = null,
            .pool = pool,
            .slot = 0,
            .text = undefined,
            .uri_bytes = uri_bytes,
            .version = 0,
        };
    }

    pub fn deinit(document: *TextDocument, gpa: std.mem.Allocator) void {
        assert(document.uri_bytes.count() <= document.uri_bytes.capacity());

        if (document.pool == null) {
            assert(document.line_count() > 0);
            assert(document.text.count() <= document.text.capacity());

            document.lines.deinit(gpa);
            document.text.deinit(gpa);
        }

        document.uri_bytes.deinit(gpa);
        document.* = undefined;
    }

    pub fn apply(document: *TextDocument, range: ?Range, text: []const u8) ChangeError!void {
        assert(text.len <= std.math.maxInt(u32));
        if (range) |held| assert(held.start.line < std.math.maxInt(u32));

        const asked = range orelse return document.text_replace(text);
        const span = try document.span_checked(asked);

        assert(span.end() <= document.text_count());

        return document.splice(span, text);
    }

    pub fn apply_text(
        document: *TextDocument,
        range: ?Range,
        message: *const json.Document,
        text: json.Node,
    ) ChangeError!void {
        assert(@backingInt(text) < message.node_count);
        if (range) |held| assert(held.start.line < std.math.maxInt(u32));

        const asked = range orelse return document.text_set(message, text);
        const span = try document.span_checked(asked);

        assert(span.end() <= document.text_count());

        return document.splice_text(span, message, text);
    }

    fn encoding_get(document: *const TextDocument) Encoding {
        return document.encoding;
    }

    pub fn encoding_set(document: *TextDocument, encoding: Encoding) void {
        document.encoding = encoding;

        assert(document.encoding == encoding);
    }

    pub fn line(document: *const TextDocument, line_number: u32) []const u8 {
        assert(line_number < document.line_count());

        const start = document.lines.line_start(line_number);
        const end = document.lines.line_end(line_number, document.text.const_slice());

        assert(start <= end);
        assert(end <= document.text.count());

        return document.text.const_slice()[start..end];
    }

    pub fn line_count(document: *const TextDocument) u32 {
        const count = document.lines.count();

        assert(count > 0);

        return count;
    }

    pub fn line_end_offset(document: *const TextDocument, line_number: u32) u32 {
        assert(line_number < document.line_count());

        const end = document.lines.line_end(line_number, document.text.const_slice());

        assert(end <= document.text.count());

        return end;
    }

    pub fn line_start_offset(document: *const TextDocument, line_number: u32) u32 {
        assert(line_number < document.line_count());

        return document.lines.line_start(line_number);
    }

    pub fn load_path(document: *TextDocument, io: std.Io, held: []const u8) LoadError!void {
        assert(held.len > 0);

        var opened = path.open(io, held) catch {
            log.line("skipping a path that could not be opened", .{});

            return error.FileUnreadable;
        };

        defer opened.close(io);

        var buffer: [load_buffer_bytes]u8 = undefined;
        var reader = opened.reader(io, &buffer);

        return document.load_read(&reader.interface, "skipping a path that could not be read");
    }

    pub fn load_stdin(document: *TextDocument, io: std.Io) LoadError!void {
        var buffer: [load_buffer_bytes]u8 = undefined;
        var input = std.Io.File.stdin().readerStreaming(io, &buffer);

        return document.load_read(&input.interface, "standard input could not be read");
    }

    fn load_read(
        document: *TextDocument,
        reader: *std.Io.Reader,
        unreadable: []const u8,
    ) LoadError!void {
        assert(unreadable.len > 0);

        document.text_read(reader) catch |err| switch (err) {
            error.LinesExhausted, error.TextExhausted, error.Utf8Invalid => |rejection| {
                return rejection;
            },
            error.ReadFailed => {
                log.line("{s}", .{unreadable});

                return error.FileUnreadable;
            },
        };
    }

    pub fn lines_index(document: *const TextDocument) *const LineIndex {
        assert(document.lines.count() > 0);

        return &document.lines;
    }

    pub fn offset_in(document: *const TextDocument, position: Point, encoding: Encoding) ?u32 {
        const offset = document.lines.offset_of(document.text.const_slice(), position, encoding);

        if (offset) |held| assert(held <= document.text_count());

        return offset;
    }

    pub fn offset_of(document: *const TextDocument, position: Point) ?u32 {
        return document.offset_in(position, document.encoding);
    }

    pub fn point_in(document: *const TextDocument, offset: u32, encoding: Encoding) Point {
        assert(offset <= document.text_count());

        const position = document.lines.point_of(document.text.const_slice(), offset, encoding);

        assert(position.line < document.line_count());

        return position;
    }

    pub fn point_of(document: *const TextDocument, offset: u32) Point {
        assert(offset < std.math.maxInt(u32));

        return document.point_in(offset, document.encoding);
    }

    pub fn range_of(document: *const TextDocument, span: Span) Range {
        assert(span.length <= std.math.maxInt(u32) - span.offset);

        return document.lines.range_of(document.text.const_slice(), span, document.encoding);
    }

    pub fn reset(document: *TextDocument) void {
        document.text.clear();
        document.uri_bytes.clear();
        document.version = 0;

        document.lines.clear();

        assert(document.uri_bytes.empty());
        assert(document.line_count() == 1);
    }

    fn span_checked(document: *const TextDocument, range: Range) RangeError!Span {
        const first = document.offset_of(range.start) orelse return error.RangeOutside;
        const last = document.offset_of(range.end) orelse return error.RangeOutside;
        if (first > last) return error.RangeBackward;

        assert(last <= document.text_count());

        return Span.between(first, last);
    }

    pub fn span_in(document: *const TextDocument, range: Range, encoding: Encoding) Span {
        const span = document.lines.span_of(document.text.const_slice(), range, encoding);

        assert(span.end() <= document.text_count());

        return span;
    }

    pub fn span_of(document: *const TextDocument, range: Range) Span {
        return document.span_in(range, document.encoding);
    }

    pub fn splice(document: *TextDocument, replaced: Span, inserted: []const u8) Error!void {
        assert(replaced.length <= std.math.maxInt(u32) - replaced.offset);
        assert(inserted.len <= std.math.maxInt(u32));

        document.room_splice(replaced, inserted);

        return spliced(&document.lines, &document.text, replaced, inserted);
    }

    pub fn splice_text(
        document: *TextDocument,
        replaced: Span,
        message: *const json.Document,
        text: json.Node,
    ) Error!void {
        assert(replaced.length <= std.math.maxInt(u32) - replaced.offset);
        assert(@backingInt(text) < message.node_count);

        const inserted = message.text_of(text) orelse return error.Utf8Invalid;
        return document.splice(replaced, inserted);
    }

    pub fn text_bytes(document: *const TextDocument) []const u8 {
        return document.text.const_slice();
    }

    pub fn text_count(document: *const TextDocument) u32 {
        return document.text.count();
    }

    pub fn text_read(document: *TextDocument, source: *std.Io.Reader) ReadError!void {
        const target = document.read_target();

        target.clear();

        target.read_from(source) catch |err| {
            document.clear();

            return switch (err) {
                error.Overflow => error.TextExhausted,
                error.ReadFailed => error.ReadFailed,
            };
        };

        if (document.pool) |pool| return document.text_replace(pool.scratch.const_slice());

        if (!std.unicode.utf8ValidateSlice(document.text.const_slice())) {
            document.clear();

            return error.Utf8Invalid;
        }

        return document.index_rebuild();
    }

    pub fn text_replace(document: *TextDocument, bytes: []const u8) Error!void {
        document.clear();

        if (!std.unicode.utf8ValidateSlice(bytes)) return error.Utf8Invalid;

        document.room_fit(bytes.len, line_count_of(bytes));

        document.text.push(bytes) catch |err| switch (err) {
            error.Overflow => {
                document.clear();

                return error.TextExhausted;
            },
        };

        return document.index_rebuild();
    }

    pub fn text_set(
        document: *TextDocument,
        message: *const json.Document,
        text: json.Node,
    ) Error!void {
        assert(@backingInt(text) < message.node_count);

        const bytes = message.text_of(text) orelse {
            document.clear();

            return error.Utf8Invalid;
        };

        return document.text_replace(bytes);
    }

    pub fn uri(document: *const TextDocument) []const u8 {
        return document.uri_bytes.const_slice();
    }

    pub fn uri_set(document: *TextDocument, bytes: []const u8) UriError!void {
        assert(bytes.len <= std.math.maxInt(u32));

        document.uri_bytes.clear();

        document.uri_bytes.push(bytes) catch |err| switch (err) {
            error.Overflow => return error.UriTooLong,
        };

        assert(document.uri_bytes.count() == bytes.len);
    }

    pub fn version_get(document: *const TextDocument) i64 {
        return document.version;
    }

    pub fn version_set(document: *TextDocument, version: i64) void {
        assert(version < std.math.maxInt(u32));

        document.version = version;

        assert(document.version == version);
    }

    fn clear(document: *TextDocument) void {
        document.text.clear();
        document.lines.clear();

        assert(document.text_count() == 0);
        assert(document.line_count() == 1);
    }

    fn index_rebuild(document: *TextDocument) Error!void {
        document.lines.build(document.text.const_slice()) catch |err| switch (err) {
            error.Truncated => {
                document.clear();

                return error.LinesExhausted;
            },
        };

        document.lines.validate(document.text.count());

        assert(document.line_count() <= document.lines.capacity());
    }

    fn move_to(document: *TextDocument, place: TextPool.Place) void {
        assert(place.class != document.place.?.class);

        const pool = document.pool.?;
        const before = document.place.?;
        const text = pool.text_of(place);
        const starts = pool.lines_of(place);
        const length = document.text.count();
        const line_total = document.lines.count();

        assert(place.class != before.class);
        assert(length <= text.len);
        assert(line_total <= starts.len);

        @memcpy(text[0..length], document.text.const_slice());
        @memcpy(starts[0..line_total], document.lines.starts.const_slice());
        pool.release(before);
        document.place = place;
        document.text = .{ .allocated = false, .bytes = text, .length = length };

        document.lines = .{
            .starts = .{ .allocated = false, .buffer = starts, .item_count = line_total },
        };

        assert(document.text_count() == length);
        assert(document.line_count() == line_total);
    }

    fn place_release(document: *TextDocument) void {
        const pool = document.pool.?;
        const place = document.place.?;

        assert(document.text_count() == 0);
        assert(document.line_count() == 1);

        pool.release(place);
        document.place = null;
        document.text = undefined;
        document.lines = undefined;
    }

    fn place_set(document: *TextDocument, place: TextPool.Place) void {
        const pool = document.pool.?;

        assert(document.place == null);

        document.place = place;
        document.text = .{ .allocated = false, .bytes = pool.text_of(place), .length = 0 };

        document.lines = .{
            .starts = .{ .allocated = false, .buffer = pool.lines_of(place), .item_count = 0 },
        };

        document.lines.clear();

        assert(document.text_count() == 0);
        assert(document.line_count() == 1);
    }

    fn read_target(document: *TextDocument) *Buffer {
        if (document.pool) |pool| return &pool.scratch;
        return &document.text;
    }

    fn room_fit(document: *TextDocument, text_bytes_wanted: usize, line_count_wanted: usize) void {
        assert(text_bytes_wanted < std.math.maxInt(u32));

        const pool = document.pool orelse return;
        const place = document.place.?;

        assert(document.text_count() == 0);
        assert(line_count_wanted > 0);

        const below = pool.acquire(text_bytes_wanted, line_count_wanted, place.class) orelse {
            return document.room_make(text_bytes_wanted, line_count_wanted);
        };

        document.move_to(below);

        assert(document.place.?.class < place.class);
    }

    fn room_make(document: *TextDocument, text_bytes_wanted: usize, line_count_wanted: usize) void {
        assert(text_bytes_wanted < std.math.maxInt(u32));

        const pool = document.pool orelse return;
        const place = document.place.?;

        assert(line_count_wanted > 0);

        if (pool.classes[place.class].holds(text_bytes_wanted, line_count_wanted)) return;

        const above = pool.acquire(text_bytes_wanted, line_count_wanted, pool.class_count) orelse {
            return;
        };

        document.move_to(above);

        assert(document.place.?.class > place.class);
    }

    fn room_splice(document: *TextDocument, replaced: Span, inserted: []const u8) void {
        assert(inserted.len <= std.math.maxInt(u32));

        if (document.pool == null) return;

        assert(replaced.end() <= document.text_count());

        const removed = std.mem.count(u8, replaced.text(document.text_bytes()), "\n");
        const added = std.mem.count(u8, inserted, "\n");
        const length = @as(usize, document.text_count()) - replaced.length + inserted.len;

        assert(removed < document.line_count());

        document.room_make(length, document.line_count() - removed + added);
    }
};

const TextPool = struct {
    class_count: u32,
    classes: [class_count_max]Class,
    scratch: Buffer,

    pub const Capacity = struct {
        document_count_max: u32,
        line_count_max: u32,
        pool_bytes_max: u32,
        text_bytes_max: u32,
        text_bytes_min: u32,
    };

    pub const Class = struct {
        free: ArrayType(u32),
        line_count: u32,
        lines: []u32,
        slot_count: u32,
        text_bytes: u32,
        texts: []u8,

        fn init(
            gpa: std.mem.Allocator,
            capacity: *const Capacity,
            class_index: u32,
            class_count: u32,
        ) std.mem.Allocator.Error!Class {
            assert(class_index < class_count);

            const text_bytes = class_text_bytes(capacity, class_index);
            const line_count = class_line_count(capacity, text_bytes);
            const slot_count = class_slot_count(capacity, text_bytes, class_count);
            const texts = try StaticAllocator.reserve(u8, gpa, slot_count * text_bytes);
            errdefer StaticAllocator.release(u8, gpa, texts);

            const lines = try StaticAllocator.reserve(u32, gpa, slot_count * line_count);
            errdefer StaticAllocator.release(u32, gpa, lines);

            var free = try ArrayType(u32).init(gpa, slot_count);

            for (0..slot_count) |taken| free.push(slot_count - 1 - @as(u32, @intCast(taken)));

            assert(free.full());
            assert(free.get(slot_count - 1) == 0);

            return .{
                .free = free,
                .line_count = line_count,
                .lines = lines,
                .slot_count = slot_count,
                .text_bytes = text_bytes,
                .texts = texts,
            };
        }

        fn deinit(class: *Class, gpa: std.mem.Allocator) void {
            assert(class.free.count() <= class.slot_count);
            assert(class.texts.len == @as(usize, class.slot_count) * class.text_bytes);

            StaticAllocator.release(u8, gpa, class.texts);
            StaticAllocator.release(u32, gpa, class.lines);
            class.free.deinit(gpa);
            class.* = undefined;
        }

        fn holds(class: *const Class, text_bytes: usize, line_count: usize) bool {
            assert(class.text_bytes > 0);
            assert(class.line_count > 0);

            if (text_bytes > class.text_bytes) return false;
            return line_count <= class.line_count;
        }
    };

    pub const Place = struct {
        class: u32,
        slot: u32,
    };

    fn init(gpa: std.mem.Allocator, capacity: *const Capacity) std.mem.Allocator.Error!*TextPool {
        assert(capacity.text_bytes_min > 0);
        assert(capacity.text_bytes_min <= capacity.text_bytes_max);
        assert(capacity.line_count_max > 0);
        assert(capacity.line_count_max <= capacity.text_bytes_max);
        assert(capacity.pool_bytes_max >= capacity.text_bytes_max);

        const pool = try StaticAllocator.create(TextPool, gpa);
        errdefer StaticAllocator.destroy(TextPool, gpa, pool);

        pool.class_count = class_count_of(capacity);
        pool.scratch = try Buffer.init(gpa, capacity.text_bytes_max);
        errdefer pool.scratch.deinit(gpa);

        var initialised: u32 = 0;
        errdefer for (pool.classes[0..initialised]) |*class| class.deinit(gpa);

        for (pool.classes[0..pool.class_count], 0..) |*class, class_index| {
            class.* = try .init(gpa, capacity, @intCast(class_index), pool.class_count);
            initialised += 1;
        }

        assert(pool.classes[pool.class_count - 1].text_bytes == capacity.text_bytes_max);
        assert(pool.classes[pool.class_count - 1].line_count == capacity.line_count_max);

        return pool;
    }

    fn deinit(pool: *TextPool, gpa: std.mem.Allocator) void {
        assert(pool.class_count > 0);
        assert(pool.class_count <= class_count_max);

        for (pool.classes[0..pool.class_count]) |*class| class.deinit(gpa);

        pool.scratch.deinit(gpa);
        StaticAllocator.destroy(TextPool, gpa, pool);
    }

    fn acquire(pool: *TextPool, text_bytes: usize, line_count: usize, class_end: u32) ?Place {
        assert(class_end <= pool.class_count);
        assert(line_count > 0);
        assert(text_bytes < std.math.maxInt(u32));

        for (pool.classes[0..class_end], 0..) |*class, class_index| {
            if (!class.holds(text_bytes, line_count)) continue;

            const slot = class.free.pop() orelse continue;

            assert(slot < class.slot_count);

            return .{ .class = @intCast(class_index), .slot = slot };
        }

        return null;
    }

    fn lines_of(pool: *const TextPool, place: Place) []u32 {
        assert(place.class < pool.class_count);

        const class = &pool.classes[place.class];
        const start = @as(usize, place.slot) * class.line_count;

        assert(place.slot < class.slot_count);
        assert(start + class.line_count <= class.lines.len);

        return class.lines[start..][0..class.line_count];
    }

    fn release(pool: *TextPool, place: Place) void {
        assert(place.class < pool.class_count);

        const class = &pool.classes[place.class];

        assert(place.slot < class.slot_count);
        assert(!class.free.full());

        class.free.push(place.slot);
    }

    fn text_of(pool: *const TextPool, place: Place) []u8 {
        assert(place.class < pool.class_count);

        const class = &pool.classes[place.class];
        const start = @as(usize, place.slot) * class.text_bytes;

        assert(place.slot < class.slot_count);
        assert(start + class.text_bytes <= class.texts.len);

        return class.texts[start..][0..class.text_bytes];
    }
};

pub const PooledError = error{
    PoolExhausted,
    UriTooLong,
};

pub const class_count_max: u32 = 16;
pub const load_buffer_bytes: u32 = 1 << 12;

pub fn pool_init(
    gpa: std.mem.Allocator,
    capacity: *const TextPool.Capacity,
) std.mem.Allocator.Error!*TextPool {
    return TextPool.init(gpa, capacity);
}

pub fn pool_deinit(pool: *TextPool, gpa: std.mem.Allocator) void {
    pool.deinit(gpa);
}

pub fn pooled_init(
    gpa: std.mem.Allocator,
    pool: *TextPool,
    uri_bytes_max: u32,
) std.mem.Allocator.Error!TextDocument {
    assert(uri_bytes_max < std.math.maxInt(u32));

    return TextDocument.init_pooled(gpa, pool, uri_bytes_max);
}

pub fn pooled_open(document: *TextDocument, uri: []const u8) PooledError!void {
    const pool = document.pool.?;

    assert(uri.len > 0);
    assert(document.place == null);

    document.uri_set(uri) catch |err| switch (err) {
        error.UriTooLong => {
            document.uri_bytes.clear();

            return err;
        },
    };

    const place = pool.acquire(0, 1, pool.class_count) orelse {
        document.uri_bytes.clear();

        return error.PoolExhausted;
    };

    document.place_set(place);
}

pub fn pooled_close(document: *TextDocument) void {
    assert(document.pool != null);
    assert(document.place != null);

    document.reset();
    document.place_release();

    assert(document.place == null);
}

fn class_count_of(capacity: *const TextPool.Capacity) u32 {
    assert(capacity.text_bytes_min <= capacity.text_bytes_max);
    assert(@as(u64, capacity.text_bytes_min) << (class_count_max - 1) >= capacity.text_bytes_max);

    for (0..class_count_max) |class_index| {
        const text_bytes = class_text_bytes(capacity, @intCast(class_index));

        if (text_bytes == capacity.text_bytes_max) {
            assert(class_index + 1 < std.math.maxInt(u32));

            return @intCast(class_index + 1);
        }
    }

    unreachable;
}

fn class_line_count(capacity: *const TextPool.Capacity, text_bytes: u32) u32 {
    assert(text_bytes > 0);
    assert(text_bytes <= capacity.text_bytes_max);

    const scaled = @as(u64, capacity.line_count_max) * text_bytes / capacity.text_bytes_max;
    const count: u32 = @intCast(@max(scaled, 1));

    assert(count <= capacity.line_count_max);

    return count;
}

fn class_slot_count(capacity: *const TextPool.Capacity, text_bytes: u32, class_count: u32) u32 {
    assert(text_bytes > 0);
    assert(class_count > 0);

    const share = capacity.pool_bytes_max / class_count / text_bytes;
    return std.math.clamp(share, 1, capacity.document_count_max);
}

fn class_text_bytes(capacity: *const TextPool.Capacity, class_index: u32) u32 {
    assert(class_index < class_count_max);
    assert(capacity.text_bytes_min > 0);

    const doubled = @as(u64, capacity.text_bytes_min) << @intCast(class_index);
    const returned: u32 = @intCast(@min(doubled, capacity.text_bytes_max));

    assert(returned >= capacity.text_bytes_min);
    assert(returned <= capacity.text_bytes_max);

    return returned;
}

fn line_count_of(bytes: []const u8) usize {
    assert(bytes.len <= std.math.maxInt(u32));

    const count = std.mem.count(u8, bytes, "\n") + 1;

    assert(count <= bytes.len + 1);

    return count;
}

fn spliced(
    lines: *LineIndex,
    text: *Buffer,
    replaced: Span,
    inserted: []const u8,
) TextDocument.Error!void {
    assert(replaced.length <= std.math.maxInt(u32) - replaced.offset);

    const start = replaced.offset;
    const end = replaced.end();

    assert(end <= text.count());

    if (!scan.is_char_boundary(text.const_slice(), start)) return error.Utf8Invalid;
    if (!scan.is_char_boundary(text.const_slice(), end)) return error.Utf8Invalid;
    if (!std.unicode.utf8ValidateSlice(inserted)) return error.Utf8Invalid;

    const length = @as(usize, text.count()) - replaced.length + inserted.len;
    if (length > text.capacity()) return error.TextExhausted;

    const plan = lines.splice_plan(replaced, inserted) orelse {
        text.clear();
        lines.clear();

        return error.LinesExhausted;
    };

    text.splice(replaced, inserted) catch unreachable;
    lines.splice_apply(replaced, inserted, &plan);
    lines.validate(text.count());

    assert(text.count() == length);
}

const test_line_count_max: u32 = 8;
const test_text_bytes_max: u32 = 1 << 12;
const test_uri_bytes_max: u32 = 64;
const test_edit_count: u32 = 4_000;

const test_capacity: TextDocument.Capacity = .{
    .line_count_max = test_line_count_max,
    .text_bytes_max = test_text_bytes_max,
    .uri_bytes_max = test_uri_bytes_max,
};

const TestReader = json.DocumentType(.{ .node_count_max = 4, .text_bytes_max = 64 });

fn test_failing_stream(
    _: *std.Io.Reader,
    _: *std.Io.Writer,
    _: std.Io.Limit,
) std.Io.Reader.StreamError!usize {
    return error.ReadFailed;
}

fn test_document(gpa: std.mem.Allocator) error{OutOfMemory}!TextDocument {
    return TextDocument.init(gpa, test_capacity);
}

fn at(line: u32, character: u32) Point {
    assert(line < std.math.maxInt(u32));
    assert(character < std.math.maxInt(u32));

    return .{ .line = line, .character = character };
}

fn parsed(reader: *TestReader, source: []const u8) !json.Node {
    assert(source.len <= std.math.maxInt(u32));

    try reader.parse(source);

    return reader.root();
}

test TextDocument {
    var document: TextDocument = try .init(std.testing.allocator, .{
        .line_count_max = 8,
        .text_bytes_max = 64,
        .uri_bytes_max = 32,
    });

    defer document.deinit(std.testing.allocator);

    try document.text_replace("one\ntwo\n");
    try document.splice(Span.between(4, 7), "six");

    try std.testing.expectEqualStrings("one\nsix\n", document.text_bytes());
    try std.testing.expectEqual(3, document.line_count());
    try std.testing.expectEqual(1, document.lines_index().line_of(5));
    try std.testing.expectEqual(at(1, 1), document.point_of(5));
    try std.testing.expectError(error.Utf8Invalid, document.text_replace("\xff"));
}

test "a document indexes its lines and maps positions" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var held = try test_document(static_allocator.allocator());
    defer held.deinit(static_allocator.allocator());

    var reader: TestReader = undefined;

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    try held.text_set(&reader.base, try parsed(&reader, "\"one\\ntwo\\nthree\""));
    try std.testing.expectEqual(3, held.line_count());
    try std.testing.expectEqual(13, held.text_count());
    try std.testing.expectEqualStrings("two\n", held.line(1));
    try std.testing.expectEqualStrings("three", held.line(2));
    try std.testing.expectEqual(8, held.line_start_offset(2));
    try std.testing.expectEqual(8, held.line_end_offset(1));
    try std.testing.expectEqual(13, held.line_end_offset(2));
    try std.testing.expectEqual(at(2, 1), held.point_of(9));
    try std.testing.expectEqual(9, held.offset_of(at(2, 1)));
    try std.testing.expectEqual(null, held.offset_of(at(9, 0)));
    try std.testing.expectEqual(at(1, 3), held.range_of(Span.between(4, 7)).end);
    try std.testing.expectEqual(at(2, 5), held.range_of(Span.between(4, 99)).end);

    try std.testing.expectEqual(
        Span.between(4, 7),
        held.span_of(held.range_of(Span.between(4, 7))),
    );

    try std.testing.expectEqual(
        Span.between(4, 7),
        held.span_in(.{ .end = at(1, 3), .start = at(1, 0) }, .utf32),
    );

    try std.testing.expectEqual(3, held.lines_index().count());
}

test "a position counts units in the negotiated encoding" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var held = try test_document(static_allocator.allocator());
    defer held.deinit(static_allocator.allocator());

    var reader: TestReader = undefined;

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    try held.text_set(&reader.base, try parsed(&reader, "\"let value = \u{1F600}x;\""));

    const offset = held.text_count() - 2;

    try std.testing.expectEqual(at(0, 14), held.point_of(offset));
    try std.testing.expectEqual(offset, held.offset_of(at(0, 14)));

    held.encoding_set(.utf8);

    try std.testing.expectEqual(Encoding.utf8, held.encoding_get());
    try std.testing.expectEqual(at(0, 16), held.point_of(offset));
    try std.testing.expectEqual(offset, held.offset_in(at(0, 14), .utf16));
    try std.testing.expectEqual(at(0, 13), held.point_in(offset, .utf32));

    try std.testing.expectEqual(
        Span.between(offset, offset + 1),
        held.span_in(.{ .end = at(0, 15), .start = at(0, 14) }, .utf16),
    );
}

test "a splice replaces the bytes it names" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var held = try test_document(static_allocator.allocator());
    defer held.deinit(static_allocator.allocator());

    var reader: TestReader = undefined;

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    try held.text_replace("one\ntwo\n");

    const range: Range = .{ .end = at(1, 3), .start = at(1, 0) };

    try held.apply(range, "six");
    try std.testing.expectEqualStrings("one\nsix\n", held.text_bytes());

    const inserted = try parsed(&reader, "\"a\\nb\"");

    try held.splice_text(Span.between(0, 3), &reader.base, inserted);
    try std.testing.expectEqualStrings("a\nb\nsix\n", held.text_bytes());
    try std.testing.expectEqual(4, held.line_count());
    try held.apply(null, "three");
    try std.testing.expectEqualStrings("three", held.text_bytes());
    try std.testing.expectEqual(1, held.line_count());
}

test "a change outside or behind the document is refused" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var held = try test_document(static_allocator.allocator());
    defer held.deinit(static_allocator.allocator());

    var reader: TestReader = undefined;

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    try held.text_replace("one\ntwo\n");

    const outside: Range = .{ .end = at(9, 0), .start = at(0, 0) };
    const backward: Range = .{ .end = at(0, 1), .start = at(1, 1) };

    try std.testing.expectError(error.RangeOutside, held.apply(outside, "x"));
    try std.testing.expectError(error.RangeBackward, held.apply(backward, "x"));
    try std.testing.expectEqualStrings("one\ntwo\n", held.text_bytes());

    const inserted = try parsed(&reader, "\"six\"");
    const second: Range = .{ .end = at(1, 3), .start = at(1, 0) };
    const refused = held.apply_text(outside, &reader.base, inserted);

    try std.testing.expectError(error.RangeOutside, refused);
    try held.apply_text(second, &reader.base, inserted);
    try std.testing.expectEqualStrings("one\nsix\n", held.text_bytes());
    try held.apply_text(null, &reader.base, inserted);
    try std.testing.expectEqualStrings("six", held.text_bytes());
}

test "a path that cannot be opened is unreadable" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var held = try test_document(static_allocator.allocator());
    defer held.deinit(static_allocator.allocator());

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    const io = std.testing.io;

    try std.testing.expectError(error.FileUnreadable, held.load_path(io, "missing/scylla.txt"));
    try std.testing.expectEqual(0, held.text_count());
}

test "a splice the document cannot take is rejected" {
    const flood: [test_text_bytes_max]u8 = @splat('x');
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var held = try test_document(static_allocator.allocator());
    defer held.deinit(static_allocator.allocator());

    var reader: TestReader = undefined;

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    try held.text_set(&reader.base, try parsed(&reader, "\"\u{1F600}\""));
    try std.testing.expectError(error.Utf8Invalid, held.splice(Span.between(1, 2), "x"));
    try std.testing.expectError(error.Utf8Invalid, held.splice(Span.between(0, 4), "\xff"));
    try std.testing.expectError(error.TextExhausted, held.splice(Span.between(0, 0), &flood));
    try std.testing.expectEqual(4, held.text_count());

    try std.testing.expectError(
        error.LinesExhausted,
        held.splice(Span.between(0, 0), "\n\n\n\n\n\n\n\n\n"),
    );

    try std.testing.expectEqual(0, held.text_count());
    try std.testing.expectEqual(1, held.line_count());
}

test "a text past the limits is rejected whole" {
    const large = "\"" ++ @as([8_192]u8, @splat('x')) ++ "\"";
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var held = try test_document(static_allocator.allocator());
    defer held.deinit(static_allocator.allocator());

    var reader: TestReader = undefined;

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    const large_text = try parsed(&reader, large);

    try std.testing.expectError(error.TextExhausted, held.text_set(&reader.base, large_text));
    try std.testing.expectEqual(0, held.text_count());

    const breaks = try parsed(&reader, "\"\\n\\n\\n\\n\\n\\n\\n\\n\\n\"");

    try std.testing.expectError(error.LinesExhausted, held.text_set(&reader.base, breaks));
    try std.testing.expectEqual(1, held.line_count());
    try std.testing.expectError(error.Utf8Invalid, held.text_replace("\xff"));
    try std.testing.expectError(error.Malformed, reader.parse("\"\\udc00\""));
    try std.testing.expectEqual(0, held.text_count());
}

test "a read that fails partway leaves no half read document" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var held = try test_document(static_allocator.allocator());
    defer held.deinit(static_allocator.allocator());

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    var partial = "alpha\nbeta\ngamma\n".*;

    var source: std.Io.Reader = .{
        .vtable = &.{ .stream = test_failing_stream },
        .buffer = partial[0..8],
        .seek = 0,
        .end = 8,
    };

    try held.text_replace("one\ntwo\n");
    try std.testing.expectError(error.ReadFailed, held.text_read(&source));
    try std.testing.expectEqualStrings("", held.text_bytes());
    try std.testing.expectEqual(1, held.line_count());

    var whole: std.Io.Reader = .fixed("alpha\nbeta\n");

    try held.text_read(&whole);
    try std.testing.expectEqualStrings("alpha\nbeta\n", held.text_bytes());

    var invalid: std.Io.Reader = .fixed("\xff\xfe");

    try std.testing.expectError(error.Utf8Invalid, held.text_read(&invalid));
}

test "a random edit sequence matches a full rebuild" {
    const words = [_][]const u8{ "", "a", "\n", "ab\nc", "\n\n", "\u{00e9}" };

    const capacity: TextDocument.Capacity = .{
        .line_count_max = 256,
        .text_bytes_max = 1 << 10,
        .uri_bytes_max = test_uri_bytes_max,
    };

    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var held = try TextDocument.init(static_allocator.allocator(), capacity);
    defer held.deinit(static_allocator.allocator());

    var mirror = try TextDocument.init(static_allocator.allocator(), capacity);
    defer mirror.deinit(static_allocator.allocator());

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    var random: Random = .init(0x2545_F491_4F6C_DD1D);
    var edits: u32 = 0;

    try held.text_replace("one\ntwo\nthree\n");

    for (0..test_edit_count) |_| {
        const count = held.text_count();
        const start = random.below(count + 1);
        const end = start + random.below(count + 1 - start);
        const word = words[random.below(words.len)];

        held.splice(Span.between(start, end), word) catch continue;

        edits += 1;

        try mirror.text_replace(held.text_bytes());
        try std.testing.expectEqualStrings(held.text_bytes(), mirror.text_bytes());

        try std.testing.expectEqualSlices(
            u32,
            held.lines_index().starts.const_slice(),
            mirror.lines_index().starts.const_slice(),
        );
    }

    try std.testing.expect(edits > 1_000);
}
