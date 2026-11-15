const std = @import("std");
const assert = std.debug.assert;
const bounded = @import("../stdx/bounded.zig");
const ArrayType = bounded.ArrayType;
const Span = bounded.Span;
pub const choice_depth_max: u32 = 32;
const choice_variant_max: u32 = 8;
pub const group_depth_max: u32 = 256;
pub const indent_depth_max: u32 = 256;
pub const fill_softs: u32 = 1 << 31;

pub const Source = enum(u8) {
    arena,
    document,
    literal,
};

pub const Text = struct {
    source: Source,
    span: Span,
};

pub const Element = union(enum) {
    @"align",
    align_column,
    blank_line: u32,
    broken,
    choice: u32,
    choice_close,
    chunk: Span,
    dealign,
    dedent,
    dedent_broken,
    filled: u32,
    group_close,
    group_open,
    hard_line,
    heads,
    hugged,
    hugging: Span,
    hugs,
    if_broken: Span,
    if_flat: Span,
    indent,
    indent_broken,
    joined: Span,
    line,
    pragma,
    reach,
    reach_arrow,
    reach_new,
    reach_type,
    reached,
    soft_line,
    space,
    starred: Span,
    text: Text,
    variant,
    verbatim: Span,
    verbatim_arena: Span,
    void,
    wide,

    pub fn eql(element: Element, other: Element) bool {
        if (std.meta.activeTag(element) != std.meta.activeTag(other)) return false;

        return std.meta.eql(element, other);
    }
};

pub const Document = struct {
    choice_depth: u32,
    deferred: [group_depth_max]u32,
    deferred_count: u32,
    elements: ArrayType(Element),
    group_depth: u32,
    group_serials: [group_depth_max]u32,
    groups_opened: u32,
    indent_depth: u32,
    literals: ArrayType([]const u8),
    suffixed: bool,

    pub fn init(
        gpa: std.mem.Allocator,
        element_count_max: u32,
        literal_count_max: u32,
    ) std.mem.Allocator.Error!Document {
        assert(element_count_max > 0);
        assert(literal_count_max > 0);

        var elements = try ArrayType(Element).init(gpa, element_count_max);
        errdefer elements.deinit(gpa);

        const literals = try ArrayType([]const u8).init(gpa, literal_count_max);

        return .{
            .choice_depth = 0,
            .deferred = @splat(0),
            .deferred_count = 0,
            .elements = elements,
            .group_depth = 0,
            .group_serials = @splat(0),
            .groups_opened = 0,
            .indent_depth = 0,
            .literals = literals,
            .suffixed = false,
        };
    }

    pub fn deinit(document: *Document, gpa: std.mem.Allocator) void {
        assert(document.group_depth <= group_depth_max);
        assert(document.indent_depth <= indent_depth_max);

        document.elements.deinit(gpa);
        document.literals.deinit(gpa);
        document.* = undefined;
    }

    pub fn balanced(document: *const Document) bool {
        assert(document.group_depth <= group_depth_max);
        assert(document.indent_depth <= indent_depth_max);

        if (document.choice_depth != 0) return false;
        if (document.deferred_count != 0) return false;
        if (document.group_depth != 0) return false;
        return document.indent_depth == 0;
    }

    pub fn clear(document: *Document) void {
        document.choice_depth = 0;

        document.elements.clear();
        document.group_depth = 0;
        document.groups_opened = 0;
        document.deferred_count = 0;
        document.indent_depth = 0;
        document.suffixed = false;

        assert(document.count() == 0);
        assert(document.balanced());
    }

    pub fn close(document: *const Document) void {
        assert(document.choice_depth == 0);
        assert(document.deferred_count == 0);
        assert(document.group_depth == 0);
        assert(document.indent_depth == 0);
    }

    pub fn closes(document: *const Document, element: Element) bool {
        assert(document.group_depth <= group_depth_max);
        assert(document.indent_depth <= indent_depth_max);
        if (element == .text) return true;

        return switch (element) {
            .choice_close, .variant => document.choice_depth > 0,
            .dedent => document.indent_depth > 0,
            .group_close => document.group_depth > 0,
            else => true,
        };
    }

    pub fn count(document: *const Document) u32 {
        assert(document.group_depth <= group_depth_max);
        assert(document.indent_depth <= indent_depth_max);

        return document.elements.count();
    }

    pub fn defer_close(document: *Document, serial: u32) error{Overflow}!void {
        assert(document.group_open(serial));

        if (document.deferred_count == group_depth_max) return error.Overflow;

        document.deferred[document.deferred_count] = serial;
        document.deferred_count += 1;

        assert(document.deferred_count <= group_depth_max);
    }

    pub fn elements_slice(document: *const Document) []const Element {
        assert(document.group_depth <= group_depth_max);
        assert(document.indent_depth <= indent_depth_max);

        return document.elements.const_slice();
    }

    pub fn group_open(document: *const Document, serial: u32) bool {
        assert(document.group_depth <= group_depth_max);
        assert(serial < std.math.maxInt(u32));

        const serials = document.group_serials[0..document.group_depth];
        const found = std.sort.binarySearch(u32, serials, serial, order_u32);

        if (found) |at| assert(serials[at] == serial);

        return found != null;
    }

    pub fn group_serial(document: *const Document) ?u32 {
        assert(document.group_depth <= group_depth_max);
        assert(document.groups_opened >= document.group_depth);

        if (document.group_depth == 0) return null;
        const returned = document.group_serials[document.group_depth - 1];

        assert(returned < std.math.maxInt(u32));

        return returned;
    }

    pub fn groups_inside(document: *const Document, serial: u32) u32 {
        assert(document.group_depth <= group_depth_max);
        assert(serial < std.math.maxInt(u32));

        const depth = document.group_depth;
        const serials = document.group_serials[0..depth];
        const at = std.sort.binarySearch(u32, serials, serial, order_u32) orelse return 0;

        assert(at < depth);

        return depth - @as(u32, @intCast(at)) - 1;
    }

    pub fn literal(document: *Document, bytes: []const u8) u32 {
        assert(bytes.len > 0);
        assert(bytes.len <= std.math.maxInt(u32));

        const index = document.literals.count();

        document.literals.push(bytes);

        assert(index < document.literals.count());

        return index;
    }

    pub fn literal_of(document: *const Document, index: u32) []const u8 {
        assert(index < document.literals.count());

        const bytes = document.literals.get(index);

        assert(bytes.len > 0);

        return bytes;
    }

    pub fn literal_span(document: *const Document, index: u32) Span {
        assert(index < document.literals.count());

        const length: u32 = @intCast(document.literal_of(index).len);
        return .{ .offset = index, .length = length };
    }

    pub fn push(document: *Document, element: Element) error{Overflow}!void {
        assert(document.closes(element));

        if (!document.admits(element)) return error.Overflow;
        if (document.elements.full()) return error.Overflow;

        document.elements.push(element);
        document.counted(element);

        if (element == .group_close) {
            if (document.deferred_count > 0) try document.deferred_closed();
        }

        assert(document.group_depth <= group_depth_max);
        assert(document.indent_depth <= indent_depth_max);
    }

    pub fn set_suffixed(document: *Document, held: bool) void {
        assert(document.group_depth <= group_depth_max);

        document.suffixed = held;

        assert(document.suffixed == held);
    }

    pub fn withdraw(document: *Document, index: u32) void {
        assert(index < document.elements.count());

        document.elements.slice()[index] = .void;

        assert(document.elements.get(index) == .void);
    }

    fn admits(document: *const Document, element: Element) bool {
        assert(document.choice_depth <= choice_depth_max);
        if (element == .void) return true;

        switch (element) {
            .choice => |variant_count| {
                assert(variant_count > 1);
                assert(variant_count <= choice_variant_max);

                return document.choice_depth < choice_depth_max;
            },
            .group_open => return document.group_depth < group_depth_max,
            .indent => return document.indent_depth < indent_depth_max,
            .text => |text| {
                if (text.source == .literal) {
                    assert(text.span.offset < document.literals.count());
                    assert(text.span.length == document.literal_of(text.span.offset).len);
                }

                return true;
            },
            else => return true,
        }
    }

    fn counted(document: *Document, element: Element) void {
        assert(document.closes(element));

        switch (element) {
            .choice => document.choice_depth += 1,
            .choice_close => document.choice_depth -= 1,
            .dedent => document.indent_depth -= 1,
            .group_close => document.group_depth -= 1,
            .group_open => {
                document.group_serials[document.group_depth] = document.groups_opened;
                document.groups_opened += 1;
                document.group_depth += 1;
            },
            .indent => document.indent_depth += 1,
            else => {},
        }

        assert(document.choice_depth <= choice_depth_max);
        assert(document.group_depth <= group_depth_max);
    }

    fn deferred_closed(document: *Document) error{Overflow}!void {
        assert(document.deferred_count > 0);
        assert(document.deferred_count <= group_depth_max);

        for (0..group_depth_max) |_| {
            const serial = document.group_serial() orelse return;
            const deferred_count = document.deferred_count;
            const held = document.deferred[0..deferred_count];
            const at = std.mem.findScalar(u32, held, serial) orelse return;
            const kept = held[at + 1 .. deferred_count];

            @memmove(held[at .. deferred_count - 1], kept);
            document.deferred_count -= 1;

            if (document.elements.full()) return error.Overflow;

            document.elements.push(.group_close);
            document.counted(.group_close);
        }
    }
};

fn order_u32(key: u32, item: u32) std.math.Order {
    assert(key < std.math.maxInt(u32));
    assert(item < std.math.maxInt(u32));

    return std.math.order(key, item);
}

const comma = ",";

fn span_of(offset: u32, length: u32) Span {
    assert(offset < std.math.maxInt(u32));
    assert(length < std.math.maxInt(u32));

    return .{ .offset = offset, .length = length };
}

fn reserved() !Document {
    return Document.init(std.testing.allocator, 16, 4);
}

test "a built document reads back what went in" {
    var document = try reserved();
    defer document.deinit(std.testing.allocator);

    const comma_index = document.literal(comma);

    try std.testing.expectEqual(@as(u32, 0), comma_index);
    try document.push(.group_open);
    try document.push(.indent);
    try document.push(.{ .text = .{ .source = .document, .span = span_of(0, 3) } });

    const comma_span = document.literal_span(comma_index);

    try document.push(.{ .text = .{ .source = .literal, .span = comma_span } });
    try document.push(.soft_line);
    try document.push(.{ .verbatim = span_of(4, 9) });
    try document.push(.{ .blank_line = 2 });
    try document.push(.{ .if_broken = document.literal_span(comma_index) });
    try document.push(.dedent);
    try document.push(.group_close);

    document.close();

    const elements = document.elements_slice();
    const literal_text: Element = .{ .text = .{ .source = .literal, .span = span_of(0, 1) } };

    try std.testing.expectEqual(@as(u32, 10), document.count());
    try std.testing.expect(elements[0].eql(.group_open));
    try std.testing.expect(elements[3].eql(literal_text));
    try std.testing.expect(elements[6].eql(.{ .blank_line = 2 }));
    try std.testing.expectEqualStrings(comma, document.literal_of(comma_index));
}

test "a cleared document forgets every element" {
    var document = try reserved();
    defer document.deinit(std.testing.allocator);

    try document.push(.group_open);

    document.clear();

    try std.testing.expectEqual(@as(u32, 0), document.count());
    try std.testing.expectEqual(@as(usize, 0), document.elements_slice().len);
    try document.push(.space);

    document.close();
}

test "an overflowing push leaves the arena as it was" {
    var document = try Document.init(std.testing.allocator, 2, 2);
    defer document.deinit(std.testing.allocator);

    try document.push(.space);
    try document.push(.space);
    try std.testing.expectError(error.Overflow, document.push(.group_open));
    try std.testing.expectEqual(@as(u32, 2), document.count());
    try std.testing.expect(document.elements_slice()[0].eql(.space));
    try std.testing.expect(document.elements_slice()[1].eql(.space));

    document.close();
}

test "an unopened group close fires the balance assertion" {
    var document = try reserved();
    defer document.deinit(std.testing.allocator);

    try std.testing.expect(!document.closes(.group_close));
}

test "an unopened dedent fires the balance assertion" {
    var document = try reserved();
    defer document.deinit(std.testing.allocator);

    try std.testing.expect(!document.closes(.dedent));
}

test "an unclosed group fires the balance assertion" {
    var document = try reserved();
    defer document.deinit(std.testing.allocator);

    try document.push(.group_open);
    try std.testing.expect(!document.balanced());
    try document.push(.group_close);
}

test "an unclosed indent fires the balance assertion" {
    var document = try reserved();
    defer document.deinit(std.testing.allocator);

    try document.push(.indent);
    try std.testing.expect(!document.balanced());
    try document.push(.dedent);
}

test "a nested group run holds its bound" {
    var document = try Document.init(std.testing.allocator, 1 << 10, 2);
    defer document.deinit(std.testing.allocator);

    for (0..group_depth_max) |_| try document.push(.group_open);
    for (0..group_depth_max) |_| try document.push(.group_close);

    document.close();

    try std.testing.expectEqual(group_depth_max * 2, document.count());
}

test "an indent deeper than the bound reports the overflow" {
    var document = try Document.init(std.testing.allocator, 1 << 10, 2);
    defer document.deinit(std.testing.allocator);

    for (0..indent_depth_max) |_| try document.push(.indent);

    try std.testing.expectError(error.Overflow, document.push(.indent));

    for (0..indent_depth_max) |_| try document.push(.dedent);

    document.close();
}

test "a group deeper than the bound reports the overflow" {
    var document = try Document.init(std.testing.allocator, 1 << 10, 2);
    defer document.deinit(std.testing.allocator);

    for (0..group_depth_max) |_| try document.push(.group_open);

    try std.testing.expectError(error.Overflow, document.push(.group_open));

    for (0..group_depth_max) |_| try document.push(.group_close);

    document.close();
}
