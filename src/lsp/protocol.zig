const std = @import("std");
const assert = std.debug.assert;
const bounded = @import("../stdx/bounded.zig");
const json = @import("json");
const LineIndex = @import("../text/line_index.zig").LineIndex;
const scan = @import("../text/scan.zig");
const Document = json.Document;
const Encoding = LineIndex.Encoding;
const Node = json.Node;
const Point = LineIndex.Point;
const Range = LineIndex.Range;
const Span = bounded.Span;

const Replacement = struct {
    after: Span,
    before: Span,
};

pub const change_count_max: u32 = 1 << 16;

pub fn encoding_negotiate(document: *const Document, params: Node) Encoding {
    assert(@backingInt(params) < document.node_count);

    const capabilities = document.member(params, "capabilities") orelse return .utf16;
    const general = document.member(capabilities, "general") orelse return .utf16;
    const list = document.member(general, "positionEncodings") orelse return .utf16;
    if (document.kind_of(list) != .array) return .utf16;

    var best: ?Encoding = null;
    var names = document.items(list);

    for (0..change_count_max) |_| {
        const name = names.next() orelse break;
        const offered = encoding_of(document, name) orelse continue;

        if (best) |held| {
            if (@backingInt(offered) <= @backingInt(held)) continue;
        }

        best = offered;
    }

    return best orelse .utf16;
}

pub fn kind_covers(document: *const Document, requested: Node, kind: []const u8) bool {
    assert(kind.len > 0);
    assert(@backingInt(requested) < document.node_count);

    var prefix = kind;

    for (0..kind.len + 1) |_| {
        if (prefix.len == 0) return false;
        if (document.text_is(requested, prefix)) return true;

        const index = std.mem.findScalarLast(u8, prefix, '.') orelse return false;

        assert(index < prefix.len);

        prefix = prefix[0..index];
    }

    unreachable;
}

pub fn position_of(document: *const Document, params: Node) ?Point {
    assert(@backingInt(params) < document.node_count);

    return position_read(document, document.member(params, "position") orelse return null);
}

pub fn position_read(document: *const Document, held: Node) ?Point {
    assert(@backingInt(held) < document.node_count);

    const character_node = document.member(held, "character") orelse return null;
    const line_node = document.member(held, "line") orelse return null;
    const character = document.integer_of(character_node) orelse return null;
    const line = document.integer_of(line_node) orelse return null;

    return .{
        .character = std.math.cast(u32, character) orelse return null,
        .line = std.math.cast(u32, line) orelse return null,
    };
}

fn position_write(writer: *json.Writer, position: Point) json.Writer.Error!void {
    assert(position.line < std.math.maxInt(u32));

    try writer.object_begin();
    try writer.key("line");
    try writer.integer(position.line);
    try writer.key("character");
    try writer.integer(position.character);
    try writer.object_end();
}

pub fn range_read(document: *const Document, held: Node) ?Range {
    assert(@backingInt(held) < document.node_count);

    const start_node = document.member(held, "start") orelse return null;
    const end_node = document.member(held, "end") orelse return null;
    const start = position_read(document, start_node) orelse return null;
    const end = position_read(document, end_node) orelse return null;

    return .{ .end = end, .start = start };
}

pub fn range_write(writer: *json.Writer, range: Range) json.Writer.Error!void {
    assert(range.start.line <= range.end.line);

    try writer.object_begin();
    try writer.key("start");
    try position_write(writer, range.start);
    try writer.key("end");
    try position_write(writer, range.end);
    try writer.object_end();
}

fn replacement_span(before: []const u8, after: []const u8) ?Replacement {
    if (std.mem.eql(u8, before, after)) return null;

    const shortest = @min(before.len, after.len);
    var head: usize = 0;

    while (head < shortest) : (head += 1) {
        if (before[head] != after[head]) break;
    }

    while (head > 0) : (head -= 1) {
        if (boundaries_hold(before, head, after, head)) break;
    }

    var tail: usize = 0;

    while (tail < shortest - head) : (tail += 1) {
        if (before[before.len - tail - 1] != after[after.len - tail - 1]) break;
    }

    var stop = before.len - tail;
    var cut = after.len - tail;

    while (stop < before.len) {
        if (boundaries_hold(before, stop, after, cut)) break;

        stop += 1;
        cut += 1;
    }

    assert(head <= stop);
    assert(head <= cut);

    return .{
        .after = Span.between(@intCast(head), @intCast(cut)),
        .before = Span.between(@intCast(head), @intCast(stop)),
    };
}

fn boundaries_hold(before: []const u8, before_at: usize, after: []const u8, after_at: usize) bool {
    if (!scan.is_char_boundary(before, @intCast(before_at))) return false;
    assert(after.len <= std.math.maxInt(u32));
    assert(after_at < std.math.maxInt(u32));

    return scan.is_char_boundary(after, @intCast(after_at));
}

pub fn text_document_integer(document: *const Document, params: Node, key: []const u8) ?i64 {
    assert(key.len <= std.math.maxInt(u32));
    assert(@backingInt(params) < document.node_count);

    const text_document = document.member(params, "textDocument") orelse return null;
    const held = document.member(text_document, key) orelse return null;

    return document.integer_of(held);
}

pub fn text_document_string(document: *const Document, params: Node, key: []const u8) ?Node {
    assert(key.len <= std.math.maxInt(u32));
    assert(@backingInt(params) < document.node_count);

    const text_document = document.member(params, "textDocument") orelse return null;
    const held = document.member(text_document, key) orelse return null;
    if (document.kind_of(held) != .string) return null;
    return held;
}

fn uri_of(document: *const Document, params: Node) ?Node {
    assert(@backingInt(params) < document.node_count);

    return text_document_string(document, params, "uri");
}

fn encoding_of(document: *const Document, name: Node) ?Encoding {
    assert(@backingInt(name) < document.node_count);

    for (std.enums.values(Encoding)) |encoding| {
        if (document.text_is(name, encoding.name())) return encoding;
    }

    return null;
}

const test_did_open =
    \\{"textDocument":{"uri":"file:///a.rs","languageId":"rust",
++
    \\"version":1,"text":"fn main() {}"}}
;

const test_hover =
    \\{"textDocument":{"uri":"file:///a.rs"},"position":{"line":4,"character":11}}
;

const test_initialize =
    \\{"rootUri":"file:///root","rootPath":"/root","workspaceFolders":[{"uri":
++
    \\"file:///one%20two"},{"name":"x"},{"uri":"file:///three"}],"capabilities":
++
    \\{"general":{"positionEncodings":["utf-16",7,"utf-8"]}}}
;

const TestDocument = json.DocumentType(.{ .node_count_max = 64, .text_bytes_max = 256 });

fn test_root(document: *TestDocument, message: []const u8) !Node {
    assert(message.len <= std.math.maxInt(u32));

    try document.parse(message);

    return document.root();
}

fn test_at(line: u32, character: u32) Point {
    assert(line < std.math.maxInt(u32));
    assert(character < std.math.maxInt(u32));

    return .{ .character = character, .line = line };
}

fn test_member(document: *const Document, object: Node, key: []const u8) !Node {
    assert(key.len <= std.math.maxInt(u32));
    assert(@backingInt(object) < document.node_count);

    return document.member(object, key) orelse error.TestUnexpectedResult;
}

fn test_string(document: *const Document, params: Node, key: []const u8) !Node {
    assert(key.len <= std.math.maxInt(u32));
    assert(@backingInt(params) < document.node_count);

    return text_document_string(document, params, key) orelse error.TestUnexpectedResult;
}

test "an open carries its uri and text" {
    var document: TestDocument = undefined;
    const params = try test_root(&document, test_did_open);
    const uri_node = try test_string(&document.base, params, "uri");
    const text = try test_string(&document.base, params, "text");
    const text_document = try test_member(&document.base, params, "textDocument");
    const version = try test_member(&document.base, text_document, "version");
    const uri_read = uri_of(&document.base, params).?;
    const version_read = text_document_integer(&document.base, params, "version");

    try std.testing.expect(document.text_is(uri_node, "file:///a.rs"));
    try std.testing.expect(document.text_is(text, "fn main() {}"));
    try std.testing.expect(document.text_is(uri_read, "file:///a.rs"));
    try std.testing.expectEqual(@as(?i64, 1), version_read);
    try std.testing.expectEqual(@as(?u64, 1), document.unsigned_of(version));
    try std.testing.expect(document.member(params, "missing") == null);
}

test "a hover carries its position" {
    var document: TestDocument = undefined;
    const params = try test_root(&document, test_hover);
    const position = position_of(&document.base, params);

    try std.testing.expectEqual(@as(?Point, test_at(4, 11)), position);
    try std.testing.expect(text_document_string(&document.base, params, "text") == null);
    try std.testing.expect(text_document_integer(&document.base, params, "version") == null);

    const negative = try test_root(&document, "{\"position\":{\"line\":-1,\"character\":0}}");

    try std.testing.expect(position_of(&document.base, negative) == null);
}

test "a range writes the way it is read" {
    var document: TestDocument = undefined;
    var bytes: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&bytes);
    var writer: json.Writer = .init(&sink, .{});
    const range: Range = .{ .end = test_at(2, 3), .start = test_at(1, 0) };

    try range_write(&writer, range);

    writer.finish();

    try std.testing.expectEqualStrings(
        "{\"start\":{\"line\":1,\"character\":0},\"end\":{\"line\":2,\"character\":3}}",
        sink.buffered(),
    );

    const held = try test_root(&document, sink.buffered());

    try std.testing.expectEqual(@as(?Range, range), range_read(&document.base, held));

    const partial = try test_root(&document, "{\"start\":{}}");

    try std.testing.expect(range_read(&document.base, partial) == null);
}

test "the best offered encoding wins" {
    var document: TestDocument = undefined;

    try std.testing.expectEqual(
        Encoding.utf8,
        encoding_negotiate(&document.base, try test_root(&document, test_initialize)),
    );

    const sixteen = try test_root(
        &document,
        "{\"capabilities\":{\"general\":{\"positionEncodings\":[\"utf-16\",\"utf-32\"]}}}",
    );

    try std.testing.expectEqual(Encoding.utf32, encoding_negotiate(&document.base, sixteen));

    const absent = try test_root(&document, "{\"capabilities\":{}}");

    try std.testing.expectEqual(Encoding.utf16, encoding_negotiate(&document.base, absent));

    const scalar = try test_root(
        &document,
        "{\"capabilities\":{\"general\":{\"positionEncodings\":\"utf-8\"}}}",
    );

    try std.testing.expectEqual(Encoding.utf16, encoding_negotiate(&document.base, scalar));

    const escaped = try test_root(
        &document,
        "{\"capabilities\":{\"general\":{\"positionEncodings\":[\"utf\\u002d8\"]}}}",
    );

    try std.testing.expectEqual(Encoding.utf8, encoding_negotiate(&document.base, escaped));
}

test "a kind covers its dotted prefixes" {
    var document: TestDocument = undefined;
    const quickfix = try test_root(&document, "\"quickfix\"");

    try std.testing.expect(kind_covers(&document.base, quickfix, "quickfix"));
    try std.testing.expect(!kind_covers(&document.base, quickfix, "source.fixAll"));

    const source = try test_root(&document, "\"source\"");

    try std.testing.expect(kind_covers(&document.base, source, "source.fixAll.tool"));

    const fix_all = try test_root(&document, "\"source.fixAll\"");

    try std.testing.expect(kind_covers(&document.base, fix_all, "source.fixAll.tool"));
    try std.testing.expect(!kind_covers(&document.base, fix_all, "source.organizeImports"));
}

test "a replacement is the smallest span on character boundaries" {
    try std.testing.expectEqual(@as(?Replacement, null), replacement_span("abc", "abc"));

    try std.testing.expectEqual(
        @as(?Replacement, .{ .after = Span.between(2, 4), .before = Span.between(2, 4) }),
        replacement_span("abcdef", "abXYef"),
    );

    try std.testing.expectEqual(
        @as(?Replacement, .{ .after = Span.between(3, 5), .before = Span.between(3, 3) }),
        replacement_span("abc", "abcde"),
    );

    try std.testing.expectEqual(
        @as(?Replacement, .{ .after = Span.between(3, 3), .before = Span.between(3, 5) }),
        replacement_span("abcde", "abc"),
    );

    try std.testing.expectEqual(
        @as(?Replacement, .{ .after = Span.between(1, 3), .before = Span.between(1, 3) }),
        replacement_span("a\u{00e9}b", "a\u{00e8}b"),
    );
}
