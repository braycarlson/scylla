const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../../stdx/bounded/array.zig").ArrayType;
const Fixture = @import("fixture.zig");
const Kind = @import("../../../syntax/python/kind.zig").Kind;
const TreeType = @import("../../../syntax/tree.zig").TreeType;
const View = @import("../../../syntax/python/ast.zig").View;
const literal = @import("../../../syntax/python/literal.zig");
const walk_from = @import("../../../syntax/tree.zig").walk_from;
const Buffer = ArrayType(u8);
const Tree = TreeType(Kind);

pub fn equal(source: []const u8, left: View, right: View, scratch: *Buffer) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(left.span().end() <= source.len);
    assert(right.span().end() <= source.len);

    var ours = walk_from(Tree, left.tree, left.index());
    var theirs = walk_from(Tree, right.tree, right.index());
    const node_count = @max(left.tree.count(), right.tree.count());
    const step_count_max = node_count *| 2 +| 2;

    assert(node_count > 0);

    for (0..step_count_max + 1) |_| {
        const one = ours.next() orelse return theirs.next() == null;
        const two = theirs.next() orelse return false;

        switch (one) {
            .enter => |entered| {
                const other = switch (two) {
                    .enter => |node| node,
                    .leave => return false,
                };

                if (!equal_nodes(source, left.at(entered), right.at(other), scratch)) return false;
            },
            .leave => switch (two) {
                .enter => return false,
                .leave => {},
            },
        }
    }

    return false;
}

fn equal_nodes(source: []const u8, left: View, right: View, scratch: *Buffer) bool {
    assert(left.index() < left.tree.count());
    assert(right.index() < right.tree.count());

    if (left.kind() != right.kind()) return false;
    assert(source.len <= std.math.maxInt(u32));

    if (left.kind() == .constant) return equal_constants(source, left, right, scratch);
    return equal_positions(source, left, right);
}

fn equal_positions(source: []const u8, left: View, right: View) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(left.span().end() <= source.len);
    assert(right.span().end() <= source.len);

    var ours = left.positions();
    var theirs = right.positions();
    const step_count_max = @max(token_count_of(left), token_count_of(right));

    assert(step_count_max <= left.tokens.len);

    for (0..step_count_max + 1) |_| {
        const one = ours.next() orelse return theirs.next() == null;
        const two = theirs.next() orelse return false;
        if (!equal_tokens(source, left, one, right, two)) return false;
    }

    return false;
}

fn equal_constants(source: []const u8, left: View, right: View, scratch: *Buffer) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(left.span().end() <= source.len);
    assert(right.span().end() <= source.len);

    const ours = left.as_constant() orelse return false;
    const theirs = right.as_constant() orelse return false;
    const class = ours.literal_class();

    assert(left.kind() == .constant);

    assert(right.kind() == .constant);

    if (class != theirs.literal_class()) return false;
    if (class == .number) return equal_numbers(source, left, right);

    switch (class) {
        .bytes, .text => {
            if (equal_strings(source, left, right, scratch)) |found| return found;
        },
        else => {},
    }

    return equal_positions(source, left, right);
}

fn equal_numbers(source: []const u8, left: View, right: View) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(left.span().end() <= source.len);
    assert(right.span().end() <= source.len);

    var ours_positions = left.positions();
    var theirs_positions = right.positions();
    const one = ours_positions.next() orelse return false;
    const two = theirs_positions.next() orelse return false;
    const ours = left.token_at(one).text(source);
    const theirs = right.token_at(two).text(source);

    assert(ours.len > 0);
    assert(theirs.len > 0);

    switch (literal.number_of(ours)) {
        .integer => |held| switch (literal.number_of(theirs)) {
            .integer => |other| return held == other,
            else => {},
        },
        else => {},
    }

    if (left.token_kind(one) != right.token_kind(two)) return false;
    return std.mem.eql(u8, ours, theirs);
}

fn equal_strings(source: []const u8, left: View, right: View, scratch: *Buffer) ?bool {
    scratch.clear();

    if (!pieces_decode(source, left, scratch)) return null;

    const middle = scratch.count();

    if (!pieces_decode(source, right, scratch)) return null;

    const held = scratch.const_slice();

    assert(middle <= held.len);

    return std.mem.eql(u8, held[0..middle], held[middle..]);
}

fn pieces_decode(source: []const u8, view: View, scratch: *Buffer) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(view.kind() == .constant);

    const token_count = token_count_of(view);
    var positions = view.positions();

    for (0..token_count + 1) |seen| {
        const position = positions.next() orelse return true;

        if (seen == token_count) return false;

        const kind = view.token_kind(position);
        if (kind == .string_format) return false;

        switch (kind) {
            .string_bytes, .string_plain => {},
            else => continue,
        }

        const outcome = literal.decode(view.token_at(position).text(source), scratch);
        if (outcome != .complete) return false;
    }

    unreachable;
}

fn equal_tokens(source: []const u8, left: View, one: u32, right: View, two: u32) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(one < left.tokens.len);

    const kind = left.token_kind(one);

    assert(two < right.tokens.len);

    if (kind != right.token_kind(two)) return false;
    if (!carries_text(kind)) return true;
    return std.mem.eql(u8, left.token_at(one).text(source), right.token_at(two).text(source));
}

fn token_count_of(view: View) u32 {
    assert(view.index() < view.node_count());

    const node = view.tree.at(view.index());

    assert(node.token_start <= node.token_end);

    return node.token_end - node.token_start;
}

fn carries_text(kind: Kind) bool {
    if (!kind.is_token()) return false;

    return switch (kind) {
        .identifier,
        .number_binary,
        .number_complex,
        .number_float,
        .number_hexadecimal,
        .number_integer,
        .number_octal,
        .string_bytes,
        .string_format,
        .string_plain,
        => true,
        else => false,
    };
}

fn compared(source: []const u8) !bool {
    assert(source.len <= std.math.maxInt(u32));

    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;

    try fixture.init(gpa);
    defer fixture.deinit();

    var scratch: Buffer = try .init(gpa, 1 << 10);
    defer scratch.deinit(gpa);

    try fixture.build(source);

    const node = fixture.first(.compare).?;
    var children = fixture.view(node).children();
    const left = children.next().?;
    const right = children.next().?;

    return equal(fixture.source, left, right, &scratch);
}

test "one expression written twice reads as equal" {
    try std.testing.expect(try compared("held = value.first == value.first\n"));
    try std.testing.expect(try compared("held = read(1, 2) == read(1, 2)\n"));
    try std.testing.expect(try compared("held = \"text\" == \"text\"\n"));
}

test "a different name reads as unequal" {
    try std.testing.expect(!try compared("held = value.first == value.second\n"));
    try std.testing.expect(!try compared("held = read(1, 2) == read(1, 3)\n"));
    try std.testing.expect(!try compared("held = \"text\" == \"other\"\n"));
}

test "a different shape reads as unequal" {
    try std.testing.expect(!try compared("held = value == value.first\n"));
    try std.testing.expect(!try compared("held = read(1) == read(1, 2)\n"));
}

test "a constant compares by value rather than by bytes" {
    try std.testing.expect(try compared("held = 'a' == \"a\"\n"));
    try std.testing.expect(try compared("held = 0x10 == 16\n"));
    try std.testing.expect(try compared("held = 1_000 == 1000\n"));
    try std.testing.expect(try compared("held = \"\\x41\" == \"A\"\n"));
    try std.testing.expect(try compared("held = \"a\" \"b\" == \"ab\"\n"));
    try std.testing.expect(!try compared("held = b\"a\" == \"a\"\n"));
    try std.testing.expect(!try compared("held = 0x10 == 17\n"));
    try std.testing.expect(!try compared("held = 1 == 1.0\n"));
}

test "a long implicit concatenation reads as equal to itself" {
    const run = "\"a\" \"a\" \"a\" \"a\" \"a\" \"a\" \"a\" \"a\"";

    try std.testing.expect(try compared("held = " ++ run ++ " == " ++ run ++ "\n"));
}

test "a span that differs changes nothing" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;

    try fixture.init(gpa);
    defer fixture.deinit();

    var scratch: Buffer = try .init(gpa, 1 << 10);
    defer scratch.deinit(gpa);

    try fixture.build("held = value\nother = value\n");

    const first = fixture.view(fixture.nth(.name_node, 1).?);
    const second = fixture.view(fixture.nth(.name_node, 3).?);

    try std.testing.expectEqualStrings("value", first.text(fixture.source));
    try std.testing.expectEqualStrings("value", second.text(fixture.source));
    try std.testing.expect(first.index() != second.index());
    try std.testing.expect(equal(fixture.source, first, second, &scratch));
}
