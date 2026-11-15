const std = @import("std");
const assert = std.debug.assert;
const json = @import("json");
const LineIndex = @import("../text/line_index.zig").LineIndex;
const protocol = @import("protocol.zig");
const Document = json.Document;
const Node = json.Node;
const Point = LineIndex.Point;
const Range = LineIndex.Range;

pub const Changes = struct {
    count: u32,
    document: *const Document,
    items: json.Items,
    remaining: u32,

    pub const Change = struct {
        range: ?Range,
        text: Node,
    };

    pub const SyntaxError = error{Malformed};

    pub fn init(document: *const Document, params: Node) SyntaxError!Changes {
        assert(@backingInt(params) < document.node_count);

        const list = document.member(params, "contentChanges") orelse {
            if (document.kind_of(params) != .object) return error.Malformed;

            return .{
                .count = 0,
                .document = document,
                .items = document.items(params),
                .remaining = 0,
            };
        };

        if (document.kind_of(list) != .array) return error.Malformed;

        const count = try count_checked(document, list);

        assert(count <= protocol.change_count_max);

        return .{
            .count = count,
            .document = document,
            .items = document.items(list),
            .remaining = count,
        };
    }

    pub fn next(changes: *Changes) ?Change {
        assert(changes.remaining <= changes.count);
        assert(changes.remaining <= changes.items.remaining);

        if (changes.remaining == 0) return null;

        const held = changes.items.next() orelse unreachable;
        const change = change_read(changes.document, held) orelse unreachable;

        changes.remaining -= 1;

        return change;
    }
};

fn count_checked(document: *const Document, list: Node) Changes.SyntaxError!u32 {
    assert(@backingInt(list) < document.node_count);

    var checked = document.items(list);
    var count: u32 = 0;

    for (0..protocol.change_count_max) |_| {
        const held = checked.next() orelse break;

        _ = change_read(document, held) orelse return error.Malformed;

        count += 1;
    } else return error.Malformed;

    assert(count <= document.node_count);

    return count;
}

fn change_read(document: *const Document, held: Node) ?Changes.Change {
    if (document.kind_of(held) != .object) return null;

    const text = document.member(held, "text") orelse return null;
    if (document.kind_of(text) != .string) return null;

    const range: ?Range = if (document.member(held, "range")) |inner|
        protocol.range_read(document, inner) orelse return null
    else
        null;

    return .{ .range = range, .text = text };
}

const test_did_change =
    \\{"textDocument":{"uri":"file:///a.rs","version":3},
++
    \\"contentChanges":[{"text":"fn main() {}"}]}
;

const test_incremental =
    \\{"textDocument":{"uri":"file:///a.rs","version":3},"contentChanges":[{"range":
++
    \\{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"text":"x"}]}
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

test Changes {
    var document: json.DocumentType(.{ .node_count_max = 32, .text_bytes_max = 64 }) = undefined;

    try document.parse("{\"contentChanges\":[{\"text\":\"fn main() {}\"}]}");

    var changes = try Changes.init(&document.base, document.root());
    const change = changes.next() orelse return error.TestUnexpectedResult;

    try std.testing.expect(document.text_is(change.text, "fn main() {}"));
    try std.testing.expectEqual(null, change.range);

    const changes_next = changes.next();

    try std.testing.expectEqual(null, changes_next);
}

test "a change carries its text and its range" {
    var document: TestDocument = undefined;
    var full = try Changes.init(&document.base, try test_root(&document, test_did_change));

    try std.testing.expectEqual(1, full.remaining);

    const whole = full.next() orelse return error.TestUnexpectedResult;

    try std.testing.expect(whole.range == null);
    try std.testing.expect(document.text_is(whole.text, "fn main() {}"));

    const full_next = full.next();

    try std.testing.expectEqual(null, full_next);

    const incremental_params = try test_root(&document, test_incremental);
    var incremental = try Changes.init(&document.base, incremental_params);
    const ranged = incremental.next() orelse return error.TestUnexpectedResult;
    const range: Range = .{ .end = test_at(0, 1), .start = test_at(0, 0) };

    try std.testing.expectEqual(@as(?Range, range), ranged.range);
    try std.testing.expect(document.text_is(ranged.text, "x"));

    const incremental_next = incremental.next();

    try std.testing.expectEqual(null, incremental_next);
    try std.testing.expectEqual(0, incremental.remaining);
}

test "a malformed change list is refused" {
    var document: TestDocument = undefined;
    const scalar = try test_root(&document, "{\"contentChanges\":7}");

    try std.testing.expectError(error.Malformed, Changes.init(&document.base, scalar));

    const missing_text = try test_root(&document, "{\"contentChanges\":[{\"range\":{}}]}");

    try std.testing.expectError(error.Malformed, Changes.init(&document.base, missing_text));

    const bad_range = try test_root(
        &document,
        "{\"contentChanges\":[{\"range\":{\"start\":{}},\"text\":\"x\"}]}",
    );

    try std.testing.expectError(error.Malformed, Changes.init(&document.base, bad_range));

    const late = try test_root(
        &document,
        "{\"contentChanges\":[{\"text\":\"a\"},{\"text\":7}]}",
    );

    try std.testing.expectError(error.Malformed, Changes.init(&document.base, late));

    const absent = try test_root(&document, "{\"textDocument\":{}}");
    var none = try Changes.init(&document.base, absent);

    try std.testing.expectEqual(0, none.remaining);

    const none_next = none.next();

    try std.testing.expectEqual(null, none_next);

    const array = try test_root(&document, "[]");

    try std.testing.expectError(error.Malformed, Changes.init(&document.base, array));
}
