const std = @import("std");
const assert = std.debug.assert;
const bounded = @import("../stdx/bounded.zig");
const LineIndex = @import("../text/line_index.zig").LineIndex;
const scan = @import("../text/scan.zig");
const Buffer = bounded.Buffer;
const Span = bounded.Span;

pub const Cache = struct {
    issued: u64,
    slots: bounded.ArrayType(Cached),

    pub fn init(
        gpa: std.mem.Allocator,
        open_count_max: u32,
        token_count_max: u32,
        uri_bytes_max: u32,
    ) std.mem.Allocator.Error!Cache {
        assert(open_count_max > 0);
        assert(token_count_max > 0);
        assert(uri_bytes_max < std.math.maxInt(u32));

        var slots = try bounded.ArrayType(Cached).init(gpa, open_count_max);
        errdefer cache_slots_deinit(&slots, gpa);

        for (0..open_count_max) |_| {
            var data = try bounded.ArrayType(Encoded).init(gpa, token_count_max);
            errdefer data.deinit(gpa);

            const uri = try Buffer.init(gpa, uri_bytes_max);

            slots.push(.{ .data = data, .result_id = 0, .uri = uri });
        }

        assert(slots.full());

        return .{ .issued = 0, .slots = slots };
    }

    pub fn deinit(cache: *Cache, gpa: std.mem.Allocator) void {
        assert(cache.slots.full());

        cache_slots_deinit(&cache.slots, gpa);
        cache.* = undefined;
    }

    pub fn matching(cache: *const Cache, uri: []const u8, result_id: []const u8) ?[]const Encoded {
        assert(uri.len <= std.math.maxInt(u32));

        const at = cache.slot_of(uri) orelse return null;
        const held = &cache.slots.const_slice()[at];
        if (!spells(held.result_id, result_id)) return null;
        return held.data.const_slice();
    }

    pub fn remember(cache: *Cache, uri: []const u8, data: []const Encoded) u64 {
        assert(uri.len > 0);
        assert(data.len <= std.math.maxInt(u32));

        cache.issued += 1;

        const at = cache.slot_of(uri) orelse cache.slot_of("") orelse return cache.issued;
        const held = &cache.slots.slice()[at];

        held.result_id = cache.issued;

        held.uri.clear();
        held.data.clear();

        held.uri.push(uri) catch |err| switch (err) {
            error.Overflow => {
                held.uri.clear();

                return cache.issued;
            },
        };

        for (data) |token| {
            if (held.data.full()) break;

            held.data.push(token);
        }

        assert(held.data.count() <= data.len);

        return cache.issued;
    }

    pub fn remove(cache: *Cache, uri: []const u8) void {
        assert(uri.len > 0);

        const at = cache.slot_of(uri) orelse return;
        const held = &cache.slots.slice()[at];

        held.uri.clear();
        held.data.clear();

        assert(held.uri.empty());
    }

    fn slot_of(cache: *const Cache, uri: []const u8) ?u32 {
        assert(cache.slots.count() > 0);
        assert(uri.len <= std.math.maxInt(u32));

        for (cache.slots.const_slice(), 0..) |*held, index| {
            if (std.mem.eql(u8, held.uri.const_slice(), uri)) {
                assert(index < cache.slots.const_slice().len);

                return @intCast(index);
            }
        }

        return null;
    }
};

const Cached = struct {
    data: bounded.ArrayType(Encoded),
    result_id: u64,
    uri: Buffer,
};

pub const Edit = struct {
    delete_count: u32,
    inserted_end: u32,
    inserted_start: u32,
    start: u32,
};

pub const Encoded = struct {
    delta_line: u32,
    delta_start: u32,
    kind: u32,
    length: u32,
    modifiers: u32,
};

pub const Token = struct {
    kind: u32,
    modifiers: u32,
    span: Span,
};

pub const Error = error{Overflow};
pub const fields: u32 = 5;

fn cache_slots_deinit(slots: *bounded.ArrayType(Cached), gpa: std.mem.Allocator) void {
    for (slots.slice()) |*held| {
        held.data.deinit(gpa);
        held.uri.deinit(gpa);
    }

    slots.deinit(gpa);
}

pub fn dedup_by_span(out: *bounded.ArrayType(Token)) void {
    const tokens = out.slice();
    var write: usize = 0;
    var previous: ?Span = null;

    for (0..tokens.len) |index| {
        const token = tokens[index];
        const repeated = if (previous) |span| std.meta.eql(span, token.span) else false;

        if (repeated) {
            assert(write > 0);

            dedup_by_span_merge(&tokens[write - 1], token);

            continue;
        }

        previous = token.span;
        tokens[write] = token;
        write += 1;
    }

    assert(write <= tokens.len);

    out.truncate(@intCast(write));
}

fn dedup_by_span_merge(kept: *Token, token: Token) void {
    assert(std.meta.eql(kept.span, token.span));

    if (kept.modifiers != 0) return;
    if (token.modifiers == 0) return;

    kept.* = token;
}

pub fn edit_of(before: []const Encoded, after: []const Encoded) ?Edit {
    assert(before.len <= std.math.maxInt(u32));
    assert(after.len <= std.math.maxInt(u32));

    const shortest = @min(before.len, after.len);
    var head: usize = 0;

    while (head < shortest) : (head += 1) {
        if (!std.meta.eql(before[head], after[head])) break;
    }

    var tail: usize = 0;

    while (tail < shortest - head) : (tail += 1) {
        if (!std.meta.eql(before[before.len - tail - 1], after[after.len - tail - 1])) break;
    }

    const deleted = before.len - head - tail;
    const inserted_end = after.len - tail;

    if (deleted == 0) {
        if (inserted_end <= head) return null;
    }

    assert(head <= inserted_end);

    return .{
        .delete_count = @as(u32, @intCast(deleted)) * fields,
        .inserted_end = @intCast(inserted_end),
        .inserted_start = @intCast(head),
        .start = @as(u32, @intCast(head)) * fields,
    };
}

pub fn encode(
    tokens: []const Token,
    index: *const LineIndex,
    source: []const u8,
    encoding: LineIndex.Encoding,
    out: *bounded.ArrayType(Encoded),
) Error!void {
    assert(tokens.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));

    out.clear();

    var previous: LineIndex.Point = .{ .line = 0, .character = 0 };
    var overflowed = false;

    for (tokens) |token| {
        const start = index.point_clamped(source, token.span.offset, encoding);
        const end = index.point_clamped(source, token.span.end(), encoding);
        if (end.line != start.line) continue;

        assert(start.line >= previous.line);

        const delta_line = start.line - previous.line;

        const delta_start = if (delta_line == 0)
            start.character -| previous.character
        else
            start.character;

        if (out.full()) {
            overflowed = true;
        } else {
            out.push(.{
                .delta_line = delta_line,
                .delta_start = delta_start,
                .kind = token.kind,
                .length = end.character -| start.character,
                .modifiers = token.modifiers,
            });
        }

        previous = start;
    }

    if (overflowed) return error.Overflow;
}

pub fn normalised(out: *bounded.ArrayType(Token), scratch: *bounded.ArrayType(Token)) Error!void {
    assert(scratch.capacity() > 0);

    retain_non_empty(out);
    std.mem.sortUnstable(Token, out.slice(), {}, less_by_start_then_end);
    dedup_by_span(out);

    return resolve_overlaps(out, scratch);
}

pub fn resolve_overlaps(
    out: *bounded.ArrayType(Token),
    scratch: *bounded.ArrayType(Token),
) Error!void {
    scratch.clear();
    std.mem.sortUnstable(Token, out.slice(), {}, less_by_start_then_widest);

    var overflowed = false;
    const tokens = out.const_slice();

    for (tokens, 0..) |token, at| {
        var cut = token.span.offset;

        for (tokens[at + 1 ..]) |inner| {
            if (inner.span.offset >= token.span.end()) break;
            if (inner.span.end() > token.span.end()) continue;

            if (cut < inner.span.offset) {
                push_cut(scratch, token, cut, inner.span.offset) catch {
                    overflowed = true;
                };
            }

            cut = @max(cut, inner.span.end());
        }

        if (cut < token.span.end()) {
            push_cut(scratch, token, cut, token.span.end()) catch {
                overflowed = true;
            };
        }
    }

    std.mem.sortUnstable(Token, scratch.slice(), {}, less_by_start_then_end);
    out.clear();

    for (scratch.const_slice()) |token| {
        if (out.full()) {
            overflowed = true;
        } else {
            out.push(token);
        }
    }

    if (overflowed) return error.Overflow;
}

pub fn retain_non_empty(out: *bounded.ArrayType(Token)) void {
    const tokens = out.slice();
    var write: usize = 0;

    for (0..tokens.len) |index| {
        const token = tokens[index];
        if (token.span.length == 0) continue;

        tokens[write] = token;
        write += 1;
    }

    assert(write <= tokens.len);

    out.truncate(@intCast(write));
}

fn less_by_start_then_end(context: void, left: Token, right: Token) bool {
    _ = context;
    assert(left.span.length <= std.math.maxInt(u32) - left.span.offset);
    assert(right.span.length <= std.math.maxInt(u32) - right.span.offset);

    if (left.span.offset != right.span.offset) return left.span.offset < right.span.offset;
    return left.span.end() < right.span.end();
}

fn less_by_start_then_widest(context: void, left: Token, right: Token) bool {
    _ = context;
    assert(left.span.length <= std.math.maxInt(u32) - left.span.offset);
    assert(right.span.length <= std.math.maxInt(u32) - right.span.offset);

    if (left.span.offset != right.span.offset) return left.span.offset < right.span.offset;
    return left.span.end() > right.span.end();
}

fn push_cut(out: *bounded.ArrayType(Token), token: Token, start: u32, end: u32) Error!void {
    assert(start < end);

    if (out.full()) return error.Overflow;
    assert(token.span.length <= std.math.maxInt(u32) - token.span.offset);

    out.push(.{
        .kind = token.kind,
        .modifiers = token.modifiers,
        .span = Span.between(start, end),
    });
}

pub fn spells(issued: u64, quoted: []const u8) bool {
    assert(quoted.len <= std.math.maxInt(u32));

    var held: [scan.decimal_bytes_max]u8 = undefined;
    const width = scan.decimal_write(&held, issued);

    assert(width > 0);
    assert(width <= scan.decimal_bytes_max);

    return std.mem.eql(u8, held[0..width], quoted);
}

const test_open_count_max: u32 = 2;
const test_token_count_max: u32 = 64;
const test_uri_bytes_max: u32 = 256;

fn test_encoded(line: u32, start: u32) Encoded {
    assert(line < std.math.maxInt(u32));
    assert(start < std.math.maxInt(u32));

    return .{ .delta_line = line, .delta_start = start, .kind = 0, .length = 1, .modifiers = 0 };
}

fn test_token(start: u32, end: u32, kind: u32, modifiers: u32) Token {
    assert(start < std.math.maxInt(u32));
    assert(end < std.math.maxInt(u32));
    assert(kind < std.math.maxInt(u32));
    assert(modifiers < std.math.maxInt(u32));

    return .{ .kind = kind, .modifiers = modifiers, .span = Span.between(start, end) };
}

test "a remembered set reads back under the id it was issued" {
    const gpa = std.testing.allocator;
    var held = try Cache.init(gpa, test_open_count_max, test_token_count_max, test_uri_bytes_max);
    defer held.deinit(gpa);

    const data = [_]Encoded{ test_encoded(0, 0), test_encoded(1, 0) };

    try std.testing.expectEqual(@as(u64, 1), held.remember("file:///one.html", &data));

    const quoted = held.matching("file:///one.html", "1") orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualSlices(Encoded, &data, quoted);

    _ = held.remember("file:///one.html", &.{test_encoded(0, 1)});

    try std.testing.expect(held.matching("file:///one.html", "1") == null);
    try std.testing.expect(held.matching("file:///one.html", "2") != null);

    held.remove("file:///one.html");

    try std.testing.expect(held.matching("file:///one.html", "2") == null);
}

test "a full cache still issues ids but remembers nothing new" {
    const gpa = std.testing.allocator;
    var held = try Cache.init(gpa, test_open_count_max, test_token_count_max, test_uri_bytes_max);
    defer held.deinit(gpa);

    try std.testing.expectEqual(@as(u64, 1), held.remember("file:///a", &.{test_encoded(0, 0)}));
    try std.testing.expectEqual(@as(u64, 2), held.remember("file:///b", &.{test_encoded(0, 0)}));
    try std.testing.expectEqual(@as(u64, 3), held.remember("file:///c", &.{test_encoded(0, 0)}));
    try std.testing.expect(held.matching("file:///c", "3") == null);
    try std.testing.expect(held.matching("file:///a", "1") != null);

    held.remove("file:///a");

    try std.testing.expectEqual(@as(u64, 4), held.remember("file:///c", &.{test_encoded(0, 0)}));
    try std.testing.expect(held.matching("file:///c", "4") != null);
}

test "a set wider than the slot keeps what fit" {
    const gpa = std.testing.allocator;
    const data = [_]Encoded{ test_encoded(0, 0), test_encoded(1, 0), test_encoded(2, 0) };
    var held = try Cache.init(gpa, 1, 2, test_uri_bytes_max);
    defer held.deinit(gpa);

    _ = held.remember("file:///a", &data);

    const kept = held.matching("file:///a", "1") orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualSlices(Encoded, data[0..2], kept);

    var narrow = try Cache.init(gpa, 1, 2, 4);
    defer narrow.deinit(gpa);

    try std.testing.expectEqual(@as(u64, 1), narrow.remember("file:///long", &data));
    try std.testing.expect(narrow.matching("file:///long", "1") == null);
}

test "two sets that differ name one run" {
    const same = [_]Encoded{ test_encoded(0, 0), test_encoded(1, 0) };

    try std.testing.expectEqual(@as(?Edit, null), edit_of(&same, &same));

    const before = [_]Encoded{ test_encoded(0, 0), test_encoded(1, 0), test_encoded(2, 0) };
    const after = [_]Encoded{ test_encoded(0, 0), test_encoded(1, 5), test_encoded(2, 0) };

    try std.testing.expectEqual(
        @as(?Edit, .{ .delete_count = 5, .inserted_end = 2, .inserted_start = 1, .start = 5 }),
        edit_of(&before, &after),
    );

    try std.testing.expectEqual(
        @as(?Edit, .{ .delete_count = 0, .inserted_end = 2, .inserted_start = 1, .start = 5 }),
        edit_of(before[0..1], before[0..2]),
    );

    try std.testing.expectEqual(
        @as(?Edit, .{ .delete_count = 5, .inserted_end = 1, .inserted_start = 1, .start = 5 }),
        edit_of(before[0..2], before[0..1]),
    );
}

test "an id spells itself in decimal" {
    try std.testing.expect(spells(1, "1"));
    try std.testing.expect(spells(0, "0"));
    try std.testing.expect(spells(1_234, "1234"));
    try std.testing.expect(!spells(12, "1"));
    try std.testing.expect(!spells(1, "01"));
}

test "tokens encode as deltas and skip multi line spans" {
    const gpa = std.testing.allocator;
    const source = "ab cd\nef\n";
    var index = try LineIndex.init(gpa, 8);
    defer index.deinit(gpa);

    var out = try bounded.ArrayType(Encoded).init(gpa, 8);
    defer out.deinit(gpa);

    try index.build(source);

    const tokens = [_]Token{
        test_token(0, 2, 1, 0),
        test_token(3, 5, 2, 1),
        test_token(4, 7, 3, 0),
        test_token(6, 8, 4, 0),
    };

    try encode(&tokens, &index, source, .utf16, &out);

    const expected = [_]Encoded{
        .{ .delta_line = 0, .delta_start = 0, .kind = 1, .length = 2, .modifiers = 0 },
        .{ .delta_line = 0, .delta_start = 3, .kind = 2, .length = 2, .modifiers = 1 },
        .{ .delta_line = 1, .delta_start = 0, .kind = 4, .length = 2, .modifiers = 0 },
    };

    try std.testing.expectEqualSlices(Encoded, &expected, out.const_slice());

    var narrow = try bounded.ArrayType(Encoded).init(gpa, 1);
    defer narrow.deinit(gpa);

    try std.testing.expectError(error.Overflow, encode(&tokens, &index, source, .utf16, &narrow));
    try std.testing.expectEqual(@as(u32, 1), narrow.count());
}

test "a normalised table is sorted deduplicated and cut around inner spans" {
    const gpa = std.testing.allocator;
    var out = try bounded.ArrayType(Token).init(gpa, 16);
    defer out.deinit(gpa);

    var scratch = try bounded.ArrayType(Token).init(gpa, 16);
    defer scratch.deinit(gpa);

    out.push(test_token(0, 10, 1, 0));
    out.push(test_token(2, 4, 2, 0));
    out.push(test_token(6, 6, 9, 0));
    out.push(test_token(2, 4, 2, 1));
    out.push(test_token(8, 12, 3, 0));

    try normalised(&out, &scratch);

    const expected = [_][3]u32{ .{ 0, 2, 1 }, .{ 2, 4, 2 }, .{ 4, 10, 1 }, .{ 8, 12, 3 } };

    try std.testing.expectEqual(expected.len, out.count());

    for (expected, out.const_slice()) |want, token| {
        const held = [3]u32{ token.span.offset, token.span.end(), token.kind };

        try std.testing.expectEqual(want, held);
    }

    try std.testing.expectEqual(@as(u32, 1), out.get(1).modifiers);
}

test "a table that outgrows its scratch reports the loss" {
    const gpa = std.testing.allocator;
    var out = try bounded.ArrayType(Token).init(gpa, 4);
    defer out.deinit(gpa);

    var scratch = try bounded.ArrayType(Token).init(gpa, 2);
    defer scratch.deinit(gpa);

    out.push(test_token(0, 10, 1, 0));
    out.push(test_token(2, 4, 2, 0));
    out.push(test_token(6, 8, 3, 0));

    try std.testing.expectError(error.Overflow, normalised(&out, &scratch));
    try std.testing.expectEqual(@as(u32, 2), out.count());
}
