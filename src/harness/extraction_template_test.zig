const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Binding = extraction.Binding;
const Member = extraction.Member;
const Object = extraction.Object;
const Brackets = @import("../syntax/brackets.zig").Brackets;
const Range = extraction.Range;
const Span = @import("../stdx/bounded/span.zig");
const Tokens = @import("../syntax/tokens.zig");
const extraction = @import("../testing/extraction.zig");
const javascript = @import("../outline/javascript.zig");
const lex = @import("../syntax/lex.zig").lex;
const markup = @import("../syntax/markup.zig");
const markup_testing = @import("../syntax/testing/markup.zig");
const mask = @import("../text/mask.zig");

const Markup = struct {
    document: markup.Document,

    fn init(held: *Markup) !void {
        const gpa = std.testing.allocator;

        held.document = try .init(gpa, .{
            .diagnostic_count_max = diagnostic_count_max,
            .node_count_max = node_count_max,
            .tag_count_max = tag_count_max,
            .token_count_max = markup_token_count_max,
        });

        assert(held.document.node_count() == 0);
    }

    fn deinit(held: *Markup) void {
        const gpa = std.testing.allocator;

        assert(held.document.tokens().len <= markup_token_count_max);

        held.document.deinit(gpa);
        held.* = undefined;
    }
};

const Prepared = struct {
    outline: javascript.Outline,
    pairs: Brackets,
    text: []const u8,
    tokens: Tokens,

    fn init(
        prepared: *Prepared,
        arena: std.mem.Allocator,
        source: []const u8,
        region: *const Region,
    ) !void {
        assert(source.len <= std.math.maxInt(u32));

        const gpa = std.testing.allocator;
        const buffer = try arena.alloc(u8, region.span.length + 1);
        const written = mask.write(source, region.span, region.holes, buffer);

        assert(written <= buffer.len);

        prepared.text = buffer[0..written];
        prepared.tokens = try .init(gpa, token_count_max);
        errdefer prepared.tokens.deinit(gpa);

        try lex(.of(.javascript), prepared.text, &prepared.tokens);

        prepared.pairs = try .init(gpa, token_count_max);
        errdefer prepared.pairs.deinit(gpa);

        try prepared.pairs.build(prepared.text, prepared.tokens.slice());

        try prepared.outline.init(gpa, .{
            .row_count_max = row_count_max,
            .segment_count_max = segment_count_max,
            .token_count_max = token_count_max,
        });

        const tokens = prepared.tokens.slice();

        javascript.build(prepared.text, tokens, &prepared.pairs, &prepared.outline);
    }

    fn deinit(prepared: *Prepared) void {
        const gpa = std.testing.allocator;

        assert(prepared.tokens.count() <= token_count_max);

        prepared.outline.deinit(gpa);
        prepared.pairs.deinit(gpa);
        prepared.tokens.deinit(gpa);
        prepared.* = undefined;
    }
};

const Region = struct {
    holes: []const Span,
    is_data: bool,
    span: Span,
};

const attribute_count_max: u32 = 1 << 10;
const diagnostic_count_max: u32 = 1 << 10;
const hole_count_max: u32 = 1 << 10;
const markup_token_count_max: u32 = 1 << 18;
const node_count_max: u32 = 1 << 17;
const region_bytes_max: u32 = 1 << 20;
const row_count_max: u32 = 1 << 12;
const segment_count_max: u32 = 1 << 13;
const tag_count_max: u32 = 1 << 12;
const token_count_max: u32 = 1 << 16;
const ascii_whitespace = " \t\n\r\x0c";
const data_attribute = "x-data";
const init_member = "init";
const script_element = "script";
const type_attribute = "type";

const javascript_types = [_][]const u8{
    "application/javascript",
    "module",
    "text/babel",
    "text/ecmascript",
    "text/javascript",
};

fn objects_of(arena: std.mem.Allocator, held: *Markup, source: []const u8) ![]const Object {
    assert(source.len <= std.math.maxInt(u32));

    var found: std.ArrayList(Object) = .empty;
    const regions = try regions_of(arena, held, source);

    for (regions) |*region| {
        if (!region.is_data) continue;

        var prepared: Prepared = undefined;

        try prepared.init(arena, source, region);
        defer prepared.deinit();

        const objects = prepared.outline.objects.const_slice();
        if (objects.len == 0) continue;

        const object = objects[0];
        const base = region.span.offset;

        if (!members_supported(&prepared, object)) continue;

        const members = try members_of(arena, &prepared, object, base);
        const tokens = prepared.tokens.slice();

        try found.append(arena, .{
            .members = members,
            .range = .{
                base + tokens[object.brace_open].offset,
                base + tokens[object.brace_close].end(),
            },
        });
    }

    std.mem.sort(Object, found.items, {}, object_less_than);

    return found.items;
}

fn members_of(
    arena: std.mem.Allocator,
    prepared: *const Prepared,
    object: javascript.ObjectLiteral,
    base: u32,
) ![]const Member {
    assert(members_supported(prepared, object));
    assert(base < std.math.maxInt(u32));

    const tokens = prepared.tokens.slice();
    const members = prepared.outline.members_of(object);
    const found = try arena.alloc(Member, members.len);

    for (members, found) |*member, *slot| {
        const name = unquoted(prepared.text, member.name);
        const is_function = member.is_method or holds_function(prepared, member);
        const kind = member_kind(name, is_function);

        assert(member.token_start < member.token_end);

        slot.* = .{
            .has_await = is_function and member.has_await,
            .is_async = is_function and member.is_async,
            .kind = kind,
            .name = name,
            .range = .{
                base + tokens[member.token_start].offset,
                base + tokens[member.token_end - 1].end(),
            },
        };
    }

    return found;
}

fn members_supported(prepared: *const Prepared, object: javascript.ObjectLiteral) bool {
    assert(object.brace_open < object.brace_close);

    for (prepared.outline.members_of(object)) |member| {
        if (member.is_spread) return false;
        if (span_empty(member.name)) return false;

        const has_colon = !member.is_shorthand and !member.is_method;

        if (has_colon) {
            if (member.value_token_start >= member.value_token_end) return false;
        }
    }

    return true;
}

fn member_kind(name: []const u8, is_function: bool) []const u8 {
    assert(name.len > 0);

    if (std.mem.eql(u8, name, init_member)) return "Init";
    if (is_function) return "Method";
    return "Property";
}

fn holds_function(prepared: *const Prepared, member: *const javascript.Member) bool {
    assert(member.token_start < member.token_end);

    for (prepared.outline.scopes.const_slice()) |scope| {
        if (scope.kind != .function) continue;
        if (scope.token_start != member.value_token_start) continue;
        if (scope.token_end <= member.value_token_end) return true;
    }

    return false;
}

fn bindings_of(arena: std.mem.Allocator, held: *Markup, source: []const u8) ![]const Binding {
    assert(source.len <= std.math.maxInt(u32));

    var found: std.ArrayList(Binding) = .empty;
    const regions = try regions_of(arena, held, source);

    for (regions) |*region| {
        var prepared: Prepared = undefined;

        try prepared.init(arena, source, region);
        defer prepared.deinit();

        const base = region.span.offset;

        for (prepared.outline.declarations.const_slice()) |*declaration| {
            const name = declaration.name;

            try found.append(arena, .{
                .initializer = try chain_of(arena, &prepared, declaration),
                .kind = binding_kind(declaration.kind),
                .name = name.text(prepared.text),
                .name_range = .{ base + name.offset, base + name.end() },
                .scope_range = scope_range(&prepared, declaration, region),
            });
        }
    }

    std.mem.sort(Binding, found.items, {}, binding_less_than);

    return found.items;
}

fn scope_range(
    prepared: *const Prepared,
    declaration: *const javascript.Declaration,
    region: *const Region,
) Range {
    const tokens = prepared.tokens.slice();
    const base = region.span.offset;

    if (declaration.scope_token_start == 0) {
        if (declaration.scope_token_end >= tokens.len) {
            if (tokens.len > 0) return .{ base + tokens[0].offset, region.span.end() };
        }
    }

    assert(declaration.scope_token_start < declaration.scope_token_end);

    const first = tokens[declaration.scope_token_start].offset;
    const last = tokens[declaration.scope_token_end - 1].end();

    return .{ base + first, base + last };
}

fn chain_of(
    arena: std.mem.Allocator,
    prepared: *const Prepared,
    declaration: *const javascript.Declaration,
) ![]const []const u8 {
    const tokens = prepared.tokens.slice();
    const start = declaration.value_token_start;
    const end = declaration.value_token_end;
    if (start >= end) return &.{};

    var segments: std.ArrayList([]const u8) = .empty;
    var index = start;

    for (0..end - start) |_| {
        if (index >= end) break;

        const token = tokens[index];
        if (token.kind != .identifier) return &.{};

        try segments.append(arena, token.text(prepared.text));

        const dot = index + 1;
        if (dot >= end) return segments.items;

        if (tokens[dot].is_punctuation(.dot)) {
            index = dot + 1;

            continue;
        }

        if (tokens[dot].is_punctuation(.paren_open)) {
            const partner = prepared.pairs.partner_of(dot) orelse return &.{};
            if (partner == end - 1) return segments.items;
        }

        return &.{};
    }

    return segments.items;
}

fn binding_kind(kind: javascript.DeclarationKind) []const u8 {
    return switch (kind) {
        .catch_parameter => "CatchParameter",
        .class => "Class",
        .@"const" => "Const",
        .function => "Function",
        .let => "Let",
        .parameter => "Parameter",
        .@"var" => "Var",
    };
}

fn regions_of(arena: std.mem.Allocator, held: *Markup, source: []const u8) ![]const Region {
    assert(source.len <= region_bytes_max);

    var found: std.ArrayList(Region) = .empty;

    held.document.parse(source, &markup_testing.vocabulary) catch |err| switch (err) {
        error.TokensExhausted => return err,
        error.BlockDepthExceeded => {},
        error.DepthExceeded => {},
        error.DiagnosticsExhausted => {},
        error.IntermediatesExhausted => {},
        error.NodesExhausted => {},
        error.TagsExhausted => {},
    };

    for (0..held.document.node_count()) |index| {
        const view = held.document.at(@intCast(index));

        switch (view.kind()) {
            .attribute => try push_attribute(arena, source, view, &found),
            .element => try push_element(arena, source, view, &found),
            else => {},
        }
    }

    std.mem.sort(Region, found.items, {}, region_less_than);

    return found.items;
}

fn push_attribute(
    arena: std.mem.Allocator,
    source: []const u8,
    view: markup.View,
    found: *std.ArrayList(Region),
) !void {
    assert(source.len <= std.math.maxInt(u32));
    assert(view.span().end() <= source.len);

    const attribute = view.as_attribute() orelse return;
    const name = attribute.name_token() orelse return;
    if (!std.ascii.eqlIgnoreCase(view.token_at(name).text(source), data_attribute)) return;

    const value = attribute.value() orelse return;
    const span = value.inner_span();
    if (span.length == 0) return;

    var holes: ArrayType(Span) = try .init(arena, hole_count_max);

    try value.template_holes(&holes);

    assert(holes.count() <= hole_count_max);

    try found.append(arena, .{ .holes = holes.const_slice(), .is_data = true, .span = span });
}

fn push_element(
    arena: std.mem.Allocator,
    source: []const u8,
    view: markup.View,
    found: *std.ArrayList(Region),
) !void {
    assert(source.len <= std.math.maxInt(u32));
    assert(view.span().end() <= source.len);

    const element = view.as_element() orelse return;
    const name = element.name(source) orelse return;
    if (!std.ascii.eqlIgnoreCase(name, script_element)) return;
    if (!is_javascript(source, element)) return;

    var first: ?u32 = null;
    var last: ?u32 = null;
    var holes: std.ArrayList(Span) = .empty;
    var direct = view.direct_tokens();

    for (0..markup_token_count_max) |_| {
        const token = direct.next() orelse break;
        const span = view.token_at(token).span();

        if (first == null) first = span.offset;

        last = span.end();
    }

    var children = view.children();

    for (0..node_count_max) |_| {
        const child = children.next() orelse break;

        switch (child.kind()) {
            .open_tag, .close_tag => continue,
            else => {},
        }

        const span = child.span();

        first = @min(first orelse span.offset, span.offset);
        last = @max(last orelse span.end(), span.end());

        switch (child.kind()) {
            .template_comment, .template_tag, .template_variable => try holes.append(arena, span),
            else => {},
        }
    }

    const start = first orelse return;
    const stop = last orelse return;

    assert(start <= stop);

    try found.append(arena, .{
        .holes = holes.items,
        .is_data = false,
        .span = .{ .length = stop - start, .offset = start },
    });
}

fn is_javascript(source: []const u8, element: markup.View.Element) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(element.view.index < element.view.tree.count());

    var attributes = element.attributes();

    for (0..attribute_count_max) |_| {
        const attribute = attributes.next() orelse break;
        const name = attribute.name_token() orelse continue;
        const text = element.view.token_at(name).text(source);
        if (!std.ascii.eqlIgnoreCase(text, type_attribute)) continue;

        const value = attribute.value() orelse return false;
        const held = std.mem.trim(u8, value.inner_span().text(source), ascii_whitespace);

        for (javascript_types) |known| {
            if (std.ascii.eqlIgnoreCase(held, known)) return true;
        }

        return false;
    }

    return true;
}

fn unquoted(source: []const u8, span: Span) []const u8 {
    assert(source.len <= std.math.maxInt(u32));
    assert(span.end() <= source.len);

    const text = span.text(source);
    if (text.len == 0) return text;

    const quote = text[0];

    if (quote != '"') {
        if (quote != '\'') return text;
    }

    if (text.len < 2) return text;
    if (text[text.len - 1] != quote) return text;
    return text[1 .. text.len - 1];
}

fn span_empty(span: Span) bool {
    if (span.offset != 0) return false;
    return span.length == 0;
}

fn range_less_than(left: Range, right: Range) bool {
    assert(left[0] <= left[1]);
    assert(right[0] <= right[1]);

    if (left[0] != right[0]) return left[0] < right[0];
    return left[1] < right[1];
}

fn binding_less_than(context: void, left: Binding, right: Binding) bool {
    assert(@TypeOf(context) == void);
    assert(left.name.len > 0);
    assert(right.name.len > 0);

    return range_less_than(left.name_range, right.name_range);
}

fn object_less_than(context: void, left: Object, right: Object) bool {
    assert(@TypeOf(context) == void);
    assert(left.range[0] <= left.range[1]);
    assert(right.range[0] <= right.range[1]);

    return range_less_than(left.range, right.range);
}

fn region_less_than(context: void, left: Region, right: Region) bool {
    assert(@TypeOf(context) == void);
    assert(left.span.length <= std.math.maxInt(u32) - left.span.offset);
    assert(right.span.length <= std.math.maxInt(u32) - right.span.offset);

    const left_range: Range = .{ left.span.offset, left.span.end() };
    const right_range: Range = .{ right.span.offset, right.span.end() };

    return range_less_than(left_range, right_range);
}

test "every x data object the oracle recorded comes back member for member" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const allocator = arena.allocator();
    const residue = try markup_testing.residue_read(allocator, "residue-extraction.json");
    var cases = try extraction.extractions(gpa, .html);
    defer cases.deinit(gpa);

    var held: Markup = undefined;

    try held.init();
    defer held.deinit();

    var compared: u32 = 0;
    var skipped: u32 = 0;

    for (cases.items) |*case| {
        if (extraction.residue_contains(residue.items, case.name)) {
            skipped += 1;

            continue;
        }

        const found = try objects_of(allocator, &held, case.source);
        const recorded = case.extraction.objects;

        std.testing.expectEqual(recorded.len, found.len) catch |err| {
            std.debug.print("{s}: the object counts differ\n", .{case.name});

            return err;
        };

        for (found, recorded, 0..) |built, expected, index| {
            std.testing.expectEqualDeep(expected, built) catch |err| {
                std.debug.print("{s}: object {d} differs\n", .{ case.name, index });

                return err;
            };

            compared += 1;
        }
    }

    try std.testing.expectEqual(1, skipped);
    try std.testing.expectEqual(25, compared);
}

test "every binding the oracle recorded comes back field for field" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const allocator = arena.allocator();
    const residue = try markup_testing.residue_read(allocator, "residue-extraction.json");
    var cases = try extraction.extractions(gpa, .html);
    defer cases.deinit(gpa);

    var held: Markup = undefined;

    try held.init();
    defer held.deinit();

    var compared: u32 = 0;

    for (cases.items) |*case| {
        if (extraction.residue_contains(residue.items, case.name)) continue;

        const found = try bindings_of(allocator, &held, case.source);
        const recorded = case.extraction.bindings;

        std.testing.expectEqual(recorded.len, found.len) catch |err| {
            std.debug.print("{s}: the binding counts differ\n", .{case.name});

            return err;
        };

        for (found, recorded, 0..) |built, expected, index| {
            std.testing.expectEqualDeep(expected, built) catch |err| {
                std.debug.print("{s}: binding {d} differs\n", .{ case.name, index });

                return err;
            };

            compared += 1;
        }
    }

    try std.testing.expectEqual(13, compared);
}
