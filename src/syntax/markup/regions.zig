const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const Span = @import("../../stdx/bounded/span.zig");
const Structure = @import("../tree.zig").Structure;
const Token = @import("token.zig").Token;
const Tokens = @import("tokens.zig").Tokens;
const Tree = @import("tree.zig").Tree;
const View = @import("view.zig").View;
const lexer = @import("lex.zig");
const scan = @import("../../text/scan.zig");
const tree_module = @import("tree.zig");
const Element = View.Element;

pub fn RegionType(comptime Tag: type) type {
    return struct {
        hole_count: u32,
        hole_first: u32,
        kind: RegionKindType(Tag),
        node: u32,
        span: Span,

        const Region = @This();

        pub fn holes(region: *const Region, table: []const Span) []const Span {
            assert(region.hole_count <= std.math.maxInt(u32) - region.hole_first);
            assert(table.len <= std.math.maxInt(u32));

            const start: usize = region.hole_first;
            const end: usize = start + region.hole_count;
            if (end > table.len) return &.{};

            const held = table[start..end];

            assert(held.len == region.hole_count);

            return held;
        }

        pub fn text(region: *const Region, source: []const u8) []const u8 {
            assert(source.len <= std.math.maxInt(u32));
            assert(region.span.length <= std.math.maxInt(u32) - region.span.offset);

            if (region.span.end() > source.len) return &.{};
            return region.span.text(source);
        }
    };
}

pub fn RegionKindType(comptime Tag: type) type {
    return union(enum) {
        attribute: Tag,
        script_text,
        style_attribute,
        style_text,
    };
}

pub const Input = struct {
    source: []const u8,
    tokens: []const Token,
    tree: *const Tree,
};

const javascript_script_types = [_][]const u8{
    "application/ecmascript",
    "application/javascript",
    "module",
    "text/ecmascript",
    "text/javascript",
};

pub const CapacityError = error{Overflow};

pub fn collect(
    comptime Tagger: type,
    out: *ArrayType(RegionType(Tagger.Tag)),
    holes: *ArrayType(Span),
    tagger: *const Tagger,
    input: *const Input,
) CapacityError!void {
    comptime tagger_check(Tagger);

    const Tag = Tagger.Tag;

    assert(out.capacity() > 0);
    assert(holes.capacity() > 0);

    out.clear();
    holes.clear();

    const sink: SinkType(Tag) = .{ .holes = holes, .out = out };
    var room = true;

    for (0..input.tree.count()) |position| {
        const index: u32 = @intCast(position);
        const view: View = .init(input.tree, input.tokens, @fromBackingInt(index));

        const fit: CapacityError!void = switch (view.kind()) {
            .attribute => attribute_region(Tagger, tagger, view, input, sink),
            .element => element_region(Tag, view, input.source, sink),
            else => {},
        };

        fit catch |err| switch (err) {
            error.Overflow => room = false,
        };
    }

    std.mem.sort(RegionType(Tag), out.slice(), {}, RegionOrderType(Tag).less_than);

    assert(out.count() <= input.tree.count());

    if (!room) return error.Overflow;
}

fn tagger_check(comptime Tagger: type) void {
    if (!@hasDecl(Tagger, "Tag")) {
        @compileError("collect needs " ++ @typeName(Tagger) ++ " to declare pub const Tag");
    }

    if (!@hasDecl(Tagger, "tag_of")) {
        @compileError("collect needs " ++ @typeName(Tagger) ++
            " to declare pub fn tag_of(*const " ++ @typeName(Tagger) ++ ", []const u8) ?Tag");
    }
}

fn SinkType(comptime Tag: type) type {
    return struct {
        holes: *ArrayType(Span),
        out: *ArrayType(RegionType(Tag)),
    };
}

fn RegionOrderType(comptime Tag: type) type {
    return struct {
        fn less_than(context: void, left: RegionType(Tag), right: RegionType(Tag)) bool {
            assert(@TypeOf(context) == void);
            assert(left.span.length <= std.math.maxInt(u32) - left.span.offset);
            assert(right.span.length <= std.math.maxInt(u32) - right.span.offset);

            if (left.span.offset != right.span.offset) return left.span.offset < right.span.offset;
            return left.span.end() < right.span.end();
        }
    };
}

fn attribute_region(
    comptime Tagger: type,
    tagger: *const Tagger,
    view: View,
    input: *const Input,
    sink: SinkType(Tagger.Tag),
) CapacityError!void {
    assert(view.kind() == .attribute);
    assert(sink.holes.capacity() > 0);

    const attribute = view.as_attribute() orelse return;
    const token = attribute.name_token() orelse return;
    const name = view.token_at(token).text(input.source);
    const value = attribute.value() orelse return;

    const kind: RegionKindType(Tagger.Tag) = if (std.ascii.eqlIgnoreCase(name, "style"))
        .style_attribute
    else
        .{ .attribute = tagger.tag_of(name) orelse return };

    const span = value.inner_span();
    if (span.length == 0) return;

    const hole_first = sink.holes.count();
    var room = true;

    value.template_holes(sink.holes) catch |err| switch (err) {
        error.Overflow => room = false,
    };

    assert(sink.holes.count() >= hole_first);

    try region_push(Tagger.Tag, sink.out, .{
        .hole_count = sink.holes.count() - hole_first,
        .hole_first = hole_first,
        .kind = kind,
        .node = value.view.index,
        .span = span,
    });

    if (!room) return error.Overflow;
}

fn element_region(
    comptime Tag: type,
    view: View,
    source: []const u8,
    sink: SinkType(Tag),
) CapacityError!void {
    assert(view.kind() == .element);
    assert(sink.holes.capacity() > 0);
    assert(source.len <= std.math.maxInt(u32));

    const element = view.as_element() orelse return;
    const name = element.name(source) orelse return;

    const kind: RegionKindType(Tag) = kind: {
        if (std.ascii.eqlIgnoreCase(name, "script")) {
            if (!is_javascript(element, source)) return;

            break :kind .script_text;
        }

        if (std.ascii.eqlIgnoreCase(name, "style")) break :kind .style_text;
        return;
    };

    const span = content_span(view) orelse return;
    const hole_first = sink.holes.count();
    var room = true;

    content_holes(view, sink.holes) catch |err| switch (err) {
        error.Overflow => room = false,
    };

    assert(sink.holes.count() >= hole_first);

    try region_push(Tag, sink.out, .{
        .hole_count = sink.holes.count() - hole_first,
        .hole_first = hole_first,
        .kind = kind,
        .node = view.index,
        .span = span,
    });

    if (!room) return error.Overflow;
}

fn region_push(
    comptime Tag: type,
    out: *ArrayType(RegionType(Tag)),
    region: RegionType(Tag),
) CapacityError!void {
    assert(region.span.length > 0);
    assert(out.count() <= out.capacity());

    if (out.full()) return error.Overflow;

    out.push(region);

    assert(out.count() > 0);
}

fn content_holes(view: View, holes: *ArrayType(Span)) CapacityError!void {
    assert(view.kind() == .element);
    assert(holes.capacity() > 0);

    var room = true;
    var children = view.children();

    for (0..view.tree.count()) |_| {
        const child = children.next() orelse break;

        switch (child.kind()) {
            .template_comment, .template_tag, .template_variable => {},
            else => continue,
        }

        if (holes.full()) {
            room = false;
        } else {
            holes.push(child.span());
        }
    }

    if (!room) return error.Overflow;
}

fn content_span(view: View) ?Span {
    assert(view.kind() == .element);

    var start: ?u32 = null;
    var end: ?u32 = null;
    var children = view.children();

    for (0..view.tree.count()) |_| {
        const child = children.next() orelse break;

        switch (child.kind()) {
            .open_tag, .close_tag => continue,
            else => widen(&start, &end, child.span()),
        }
    }

    var direct = view.direct_tokens();

    for (0..view.tokens.len) |_| {
        const position = direct.next() orelse break;

        widen(&start, &end, view.token_at(position).span());
    }

    const held_start = start orelse return null;
    const held_end = end orelse return null;

    assert(held_start <= held_end);

    return .between(held_start, held_end);
}

fn widen(start: *?u32, end: *?u32, span: Span) void {
    assert(span.length <= std.math.maxInt(u32) - span.offset);
    if (start.* == null) assert(end.* == null);

    start.* = if (start.*) |held| @min(held, span.offset) else span.offset;
    end.* = if (end.*) |held| @max(held, span.end()) else span.end();

    assert(start.*.? <= end.*.?);
}

fn is_javascript(element: Element, source: []const u8) bool {
    assert(element.view.kind() == .element);
    assert(source.len <= std.math.maxInt(u32));

    var attributes = element.attributes();

    for (0..element.view.tree.count()) |_| {
        const attribute = attributes.next() orelse break;
        const token = attribute.name_token() orelse continue;
        const name = attribute.view.token_at(token).text(source);
        if (!std.ascii.eqlIgnoreCase(name, "type")) continue;

        const value = attribute.value() orelse return true;
        var text = value.text_tokens();
        const text_token = text.next() orelse return true;

        if (text.next() != null) return true;

        const spelled = value.view.token_at(text_token).text(source);
        const held = std.mem.trim(u8, spelled, scan.ascii_whitespace);

        for (javascript_script_types) |known| {
            if (std.ascii.eqlIgnoreCase(known, held)) return true;
        }

        return false;
    }

    return true;
}

const TestTag = enum {
    data,
    on,
};

const TestKind = RegionKindType(TestTag);

const Found = struct {
    holes: ArrayType(Span),
    regions: ArrayType(RegionType(TestTag)),
    tokens: Tokens,
    tree: Tree,

    fn init(found: *Found, gpa: std.mem.Allocator, source: []const u8) !void {
        assert(source.len <= std.math.maxInt(u32));

        found.tokens = try .init(gpa, 1 << 12);
        errdefer found.tokens.deinit(gpa);

        found.tree = try .init(gpa, 1 << 12, 1 << 6);
        errdefer found.tree.deinit(gpa);

        found.holes = try .init(gpa, 1 << 8);
        errdefer found.holes.deinit(gpa);

        found.regions = try .init(gpa, 1 << 6);
        errdefer found.regions.deinit(gpa);

        try lexer.lex(source, &found.tokens);

        const structure = tree_module.build(source, found.tokens.slice(), &found.tree);

        try std.testing.expectEqual(Structure.complete, structure);

        const input: Input = .{
            .source = source,
            .tokens = found.tokens.slice(),
            .tree = &found.tree,
        };

        try collect(TestTagger, &found.regions, &found.holes, &.{}, &input);
    }

    fn deinit(found: *Found, gpa: std.mem.Allocator) void {
        found.regions.deinit(gpa);
        found.holes.deinit(gpa);
        found.tree.deinit(gpa);
        found.tokens.deinit(gpa);
        found.* = undefined;
    }

    fn holes_of(found: *const Found, index: u32) usize {
        assert(index < std.math.maxInt(u32));

        const region = found.regions.get(index);
        return region.holes(found.holes.const_slice()).len;
    }

    fn text_of(found: *const Found, index: u32, source: []const u8) []const u8 {
        assert(index < std.math.maxInt(u32));
        assert(source.len <= std.math.maxInt(u32));

        const region = found.regions.get(index);
        return region.text(source);
    }
};

const TestTagger = struct {
    pub const Tag = TestTag;

    pub fn tag_of(tagger: *const TestTagger, name: []const u8) ?TestTag {
        assert(@sizeOf(@TypeOf(tagger.*)) == 0);
        assert(name.len > 0);

        if (std.mem.eql(u8, name, "x-data")) return .data;
        if (std.mem.startsWith(u8, name, "@")) return .on;
        if (std.mem.startsWith(u8, name, "x-on:")) return .on;
        return null;
    }
};

test "a tagged attribute value is a region" {
    const gpa = std.testing.allocator;
    const source = "<div x-data=\"{ open: false }\"></div>";
    var held: Found = undefined;

    try held.init(gpa, source);
    defer held.deinit(gpa);

    try std.testing.expectEqual(1, held.regions.count());
    try std.testing.expectEqual(TestKind{ .attribute = .data }, held.regions.get(0).kind);
    try std.testing.expectEqualStrings("{ open: false }", held.text_of(0, source));
}

test "the quotes stay outside the region" {
    const gpa = std.testing.allocator;
    const source = "<button @click=\"save()\"></button>";
    var held: Found = undefined;

    try held.init(gpa, source);
    defer held.deinit(gpa);

    try std.testing.expectEqual(TestKind{ .attribute = .on }, held.regions.get(0).kind);
    try std.testing.expectEqualStrings("save()", held.text_of(0, source));
}

test "a template hole inside a value is recorded" {
    const gpa = std.testing.allocator;
    var held: Found = undefined;

    try held.init(gpa, "<div x-data=\"{ n: {{ count }} }\"></div>");
    defer held.deinit(gpa);

    try std.testing.expectEqual(1, held.regions.count());
    try std.testing.expectEqual(1, held.holes_of(0));
}

test "a script body carries its holes" {
    const gpa = std.testing.allocator;
    const source = "<script>const n = {{ count }};</script>";
    var held: Found = undefined;

    try held.init(gpa, source);
    defer held.deinit(gpa);

    try std.testing.expectEqual(1, held.regions.count());
    try std.testing.expectEqual(TestKind.script_text, held.regions.get(0).kind);
    try std.testing.expectEqualStrings("const n = {{ count }};", held.text_of(0, source));
    try std.testing.expectEqual(1, held.holes_of(0));
}

test "a script that carries data is skipped" {
    const gpa = std.testing.allocator;
    var held: Found = undefined;

    try held.init(gpa, "<script type=\"application/json\">{\"a\": 1}</script>");
    defer held.deinit(gpa);

    try std.testing.expect(held.regions.empty());
}

test "a module script is kept" {
    const gpa = std.testing.allocator;
    var held: Found = undefined;

    try held.init(gpa, "<script type=\"module\">export const a = 1;</script>");
    defer held.deinit(gpa);

    try std.testing.expectEqual(1, held.regions.count());
}

test "a style element precedes a style attribute" {
    const gpa = std.testing.allocator;
    var held: Found = undefined;

    try held.init(gpa, "<style>.a { color: red; }</style><div style=\"color: red\"></div>");
    defer held.deinit(gpa);

    try std.testing.expectEqual(2, held.regions.count());
    try std.testing.expectEqual(TestKind.style_text, held.regions.get(0).kind);
    try std.testing.expectEqual(TestKind.style_attribute, held.regions.get(1).kind);
}

test "a plain attribute is not a region" {
    const gpa = std.testing.allocator;
    var held: Found = undefined;

    try held.init(gpa, "<a href=\"/x\" class=\"btn\">go</a>");
    defer held.deinit(gpa);

    try std.testing.expect(held.regions.empty());
}

test "an attribute the caller declines is not a region" {
    const gpa = std.testing.allocator;
    var held: Found = undefined;

    try held.init(gpa, "<div x-ref=\"rowHost\" x-transition:enter=\"fade-in\"></div>");
    defer held.deinit(gpa);

    try std.testing.expect(held.regions.empty());
}

test "an empty value is not a region" {
    const gpa = std.testing.allocator;
    var held: Found = undefined;

    try held.init(gpa, "<div x-data=\"\"></div>");
    defer held.deinit(gpa);

    try std.testing.expect(held.regions.empty());
}
