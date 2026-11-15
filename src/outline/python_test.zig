const std = @import("std");
const assert = std.debug.assert;
const Front = @import("../syntax/front.zig").Front;
const FrontCapacity = @import("../syntax/front.zig").Front.Capacity;
const FrontOptions = @import("../syntax/front.zig").Front.Options;
const Brackets = @import("../syntax/brackets.zig").Brackets;
const Scratch = @import("../syntax/front.zig").Front.Scratch;
const Span = @import("../stdx/bounded/span.zig");
const Token = @import("../syntax/token.zig");
const python = @import("python.zig");

const Built = struct {
    front: Front,
    outline: python.Outline,
    pairs: Brackets,
    scratch: Scratch,
    source: []const u8,
    tokens: []const Token,

    fn init(built: *Built, source: []const u8) !void {
        assert(source.len <= std.math.maxInt(u32));

        const gpa = std.testing.allocator;

        built.source = source;

        try built.scratch.init(gpa, &front_capacity, .initOne(.python));
        errdefer built.scratch.deinit(gpa);

        try built.front.init(gpa, &front_capacity, .python);
        errdefer built.front.deinit(gpa);

        try built.front.parse(&built.scratch, .of(.python), source, &front_options);

        const root = switch (built.front.root().?) {
            .python => |held| held,
            else => unreachable,
        };

        built.tokens = root.tokens;
        built.pairs = try .init(gpa, token_count_max);
        errdefer built.pairs.deinit(gpa);

        try built.pairs.build(source, built.tokens);

        try built.outline.init(gpa, .{
            .row_count_max = row_count_max,
            .segment_count_max = segment_count_max,
        });

        python.build(source, &built.pairs, root, &built.outline);

        assert(built.pairs.count() == built.tokens.len);
        assert(built.outline.definitions.count() <= built.tokens.len);
    }

    fn deinit(built: *Built) void {
        const gpa = std.testing.allocator;

        assert(built.outline.definitions.count() <= row_count_max);
        assert(built.tokens.len <= token_count_max);

        built.outline.deinit(gpa);
        built.pairs.deinit(gpa);
        built.front.deinit(gpa);
        built.scratch.deinit(gpa);
    }

    fn arguments_of(built: *const Built, call: python.Call) []const python.Argument {
        const arguments = built.outline.arguments.const_slice();

        assert(call.argument_first <= arguments.len);
        assert(call.argument_count <= arguments.len - call.argument_first);

        return arguments[call.argument_first..][0..call.argument_count];
    }

    fn callee(built: *const Built, call: python.Call, buffer: []u8) []const u8 {
        assert(buffer.len > 0);
        assert(call.paren_open < call.paren_close);

        const segments = built.outline.segments_of(
            call.callee_segment_first,
            call.callee_segment_count,
        );

        return built.join(segments, buffer);
    }

    fn call_named(built: *const Built, name: []const u8) ?python.Call {
        assert(name.len > 0);
        assert(name.len < name_bytes_max);

        var buffer: [name_bytes_max]u8 = undefined;

        for (built.outline.calls.const_slice()) |call| {
            if (std.mem.eql(u8, built.callee(call, &buffer), name)) return call;
        }

        return null;
    }

    fn join(built: *const Built, segments: []const Span, buffer: []u8) []const u8 {
        assert(buffer.len > 0);
        assert(segments.len <= std.math.maxInt(u32));

        var length: usize = 0;

        for (segments, 0..) |segment, index| {
            if (index > 0) {
                buffer[length] = '.';
                length += 1;
            }

            const segment_text = built.text(segment);

            @memcpy(buffer[length..][0..segment_text.len], segment_text);
            length += segment_text.len;
        }

        assert(length <= buffer.len);

        return buffer[0..length];
    }

    fn name_of(built: *const Built, definition: ?u32) []const u8 {
        assert(definition.? < built.outline.definitions.count());

        const index = definition.?;

        assert(index < built.outline.definitions.count());

        const name = built.outline.definitions.get(index).name;

        assert(name < built.tokens.len);

        return built.tokens[name].text(built.source);
    }

    fn text(built: *const Built, span: Span) []const u8 {
        assert(span.end() <= built.source.len);
        assert(built.tokens.len > 0);

        return span.text(built.source);
    }

    fn value_text(built: *const Built, start: u32, end: u32, buffer: []u8) []const u8 {
        assert(start <= end);
        assert(end <= built.tokens.len);
        assert(buffer.len <= std.math.maxInt(u32));

        var length: usize = 0;

        for (built.tokens[start..end]) |token| {
            switch (token.kind) {
                .comment, .newline => continue,
                else => {},
            }

            const held = token.text(built.source);

            @memcpy(buffer[length..][0..held.len], held);
            length += held.len;
        }

        assert(length <= buffer.len);

        return buffer[0..length];
    }

    fn segments_text(built: *const Built, first: u32, count: u32, buffer: []u8) []const u8 {
        assert(buffer.len > 0);
        assert(first <= built.outline.segments.count());

        return built.join(built.outline.segments_of(first, count), buffer);
    }
};

const name_bytes_max = 256;
const node_count_max = 1 << 12;
const row_count_max = 1 << 12;
const segment_count_max = 1 << 13;
const token_count_max = 1 << 14;

const front_capacity: FrontCapacity = .{
    .diagnostic_count_max = 1 << 6,
    .event_count_max = 1 << 15,
    .node_count_max = node_count_max,
    .semantic = .{
        .binding_count_max = 1 << 10,
        .fact_count_max = 1 << 6,
        .reference_count_max = 1 << 10,
        .scope_count_max = 1 << 6,
    },
    .tag_count_max = 1 << 6,
    .token_count_max = token_count_max,
};

const front_options: FrontOptions = .{
    .globals = &.{},
    .python_version = .py310,
    .vocabulary = .empty,
};

fn text_less(context: void, left: []const u8, right: []const u8) bool {
    _ = context;

    assert(left.len > 0);
    assert(right.len > 0);

    return std.mem.order(u8, left, right) == .lt;
}

test "a call records its callee and its arguments" {
    var built: Built = undefined;

    try built.init("register(name=\"widget\", template=\"a.html\", takes_context=True)\n");
    defer built.deinit();

    var buffer: [name_bytes_max]u8 = undefined;
    const calls = built.outline.calls.const_slice();

    try std.testing.expectEqual(1, calls.len);
    try std.testing.expectEqualStrings("register", built.callee(calls[0], &buffer));

    const arguments = built.arguments_of(calls[0]);

    try std.testing.expectEqual(3, arguments.len);

    for ([_][]const u8{ "name", "template", "takes_context" }, arguments) |name, argument| {
        try std.testing.expectEqualStrings(name, built.text(argument.name));
    }

    try std.testing.expect(arguments[0].summary == .literal);
    try std.testing.expectEqualStrings("widget", built.text(arguments[0].summary.literal.content));
    try std.testing.expect(arguments[2].summary == .literal);
}

test "a positional argument carries an empty name" {
    var built: Built = undefined;

    try built.init("path(\"admin/\", admin.site.urls, name=\"admin\")\n");
    defer built.deinit();

    var buffer: [name_bytes_max]u8 = undefined;
    const arguments = built.arguments_of(built.outline.calls.get(0));

    try std.testing.expectEqual(3, arguments.len);
    try std.testing.expectEqual(Span.empty, arguments[0].name);
    try std.testing.expectEqual(Span.empty, arguments[1].name);
    try std.testing.expectEqualStrings("name", built.text(arguments[2].name));
    try std.testing.expect(arguments[2].summary == .literal);
    try std.testing.expectEqualStrings("admin", built.text(arguments[2].summary.literal.content));
    try std.testing.expect(arguments[1].summary == .dotted_name);

    const dotted = arguments[1].summary.dotted_name;
    const joined = built.segments_text(dotted.segment_first, dotted.segment_count, &buffer);

    try std.testing.expectEqualStrings("admin.site.urls", joined);
}

test "a dotted callee records every segment" {
    var built: Built = undefined;

    try built.init("value = django.db.models.CharField(max_length=10)\n");
    defer built.deinit();

    var buffer: [name_bytes_max]u8 = undefined;
    const calls = built.outline.calls.const_slice();

    try std.testing.expectEqual(1, calls.len);
    const callee = built.callee(calls[0], &buffer);

    try std.testing.expectEqualStrings("django.db.models.CharField", callee);
}

test "a nested call is recorded alongside the outer one" {
    var built: Built = undefined;

    try built.init("outer(inner(1), other.thing(2))\n");
    defer built.deinit();

    var buffers: [3][name_bytes_max]u8 = undefined;
    var callees: [3][]const u8 = undefined;
    const calls = built.outline.calls.const_slice();

    try std.testing.expectEqual(3, calls.len);

    for (calls, &callees, &buffers) |call, *callee, *buffer| {
        callee.* = built.callee(call, buffer);
    }

    std.sort.insertion([]const u8, &callees, {}, text_less);

    for ([_][]const u8{ "inner", "other.thing", "outer" }, callees) |expected, callee| {
        try std.testing.expectEqualStrings(expected, callee);
    }
}

test "a call names the definition that encloses it" {
    var built: Built = undefined;

    try built.init("class Widget:\n    def render(self):\n        return build(self)\n");
    defer built.deinit();

    const call = built.call_named("build") orelse return error.TestUnexpectedResult;

    try std.testing.expect(call.scope != null);
    try std.testing.expectEqualStrings("render", built.name_of(call.scope));
}

test "an assignment records its target and its value" {
    var built: Built = undefined;

    try built.init(
        "class Widget:\n    name = models.CharField(max_length=10)\n    label = \"plain\"\n",
    );

    defer built.deinit();

    const assignments = built.outline.assignments.const_slice();

    try std.testing.expectEqual(2, assignments.len);

    for ([_][]const u8{ "name", "label" }, assignments) |target, assignment| {
        try std.testing.expectEqualStrings(target, built.text(assignment.target));
    }

    for (assignments) |assignment| {
        try std.testing.expect(assignment.target_is_simple);
        try std.testing.expect(assignment.scope != null);
        try std.testing.expectEqualStrings("Widget", built.name_of(assignment.scope));
    }
}

test "an annotated assignment records its target its annotation and its value" {
    var built: Built = undefined;

    try built.init("count: int = 5\n");
    defer built.deinit();

    var buffer: [name_bytes_max]u8 = undefined;
    const assignment = built.outline.assignments.get(0);
    const start = assignment.value_token_start;
    const end = assignment.value_token_end;

    try std.testing.expectEqual(1, built.outline.assignments.count());
    try std.testing.expectEqualStrings("count", built.text(assignment.target));
    try std.testing.expectEqualStrings("int", built.text(assignment.annotation));
    try std.testing.expect(assignment.target_is_simple);
    try std.testing.expectEqualStrings("5", built.value_text(start, end, &buffer));
}

test "a bare annotation declares a name and binds nothing" {
    var built: Built = undefined;

    try built.init("class Row:\n    name: str\n    count: int = 0\n");
    defer built.deinit();

    const assignments = built.outline.assignments.const_slice();

    try std.testing.expectEqual(2, assignments.len);

    for ([_][]const u8{ "name", "count" }, assignments) |target, assignment| {
        try std.testing.expectEqualStrings(target, built.text(assignment.target));
    }

    const bare = assignments[0];
    const bound = assignments[1];

    try std.testing.expectEqualStrings("str", built.text(bare.annotation));
    try std.testing.expectEqual(bare.value_token_start, bare.value_token_end);
    try std.testing.expect(bound.value_token_start < bound.value_token_end);
}

test "an annotation carrying an equals does not swallow the assignment" {
    var built: Built = undefined;

    try built.init("field: Annotated[int, Field(default=1)] = 2\n");
    defer built.deinit();

    var buffer: [name_bytes_max]u8 = undefined;
    const assignment = built.outline.assignments.get(0);
    const start = assignment.value_token_start;
    const end = assignment.value_token_end;
    const annotation = built.text(assignment.annotation);

    try std.testing.expectEqualStrings("field", built.text(assignment.target));
    try std.testing.expectEqualStrings("Annotated[int, Field(default=1)]", annotation);
    try std.testing.expectEqualStrings("2", built.value_text(start, end, &buffer));
}

test "an unannotated assignment carries no annotation" {
    var built: Built = undefined;

    try built.init("name = \"plain\"\n");
    defer built.deinit();

    try std.testing.expectEqual(Span.empty, built.outline.assignments.get(0).annotation);
}

test "a dotted assignment target is not simple" {
    var built: Built = undefined;

    try built.init("self.value = 1\n");
    defer built.deinit();

    const assignment = built.outline.assignments.get(0);

    try std.testing.expectEqualStrings("self.value", built.text(assignment.target));
    try std.testing.expect(!assignment.target_is_simple);
}

test "an assignment inside brackets is not split by its newlines" {
    var built: Built = undefined;

    try built.init("choices = [\n    (\"a\", \"A\"),\n    (\"b\", \"B\"),\n]\n");
    defer built.deinit();

    const assignments = built.outline.assignments.const_slice();

    try std.testing.expectEqual(1, assignments.len);
    try std.testing.expectEqualStrings("choices", built.text(assignments[0].target));
}

test "a decorator records its segments and the definition below it" {
    var built: Built = undefined;

    try built.init("@register.filter(name=\"pretty\")\ndef pretty(value):\n    return value\n");
    defer built.deinit();

    var buffer: [name_bytes_max]u8 = undefined;

    try std.testing.expectEqual(1, built.outline.decorators.count());

    const decorator = built.outline.decorators.get(0);
    const first = decorator.segment_first;
    const joined = built.segments_text(first, decorator.segment_count, &buffer);

    try std.testing.expectEqualStrings("register.filter", joined);
    try std.testing.expect(decorator.call != null);
    try std.testing.expect(decorator.definition != null);
    try std.testing.expectEqualStrings("pretty", built.name_of(decorator.definition));
}

test "a bare decorator records no call" {
    var built: Built = undefined;

    try built.init("@property\ndef value(self):\n    return 1\n");
    defer built.deinit();

    var buffer: [name_bytes_max]u8 = undefined;
    const decorator = built.outline.decorators.get(0);
    const first = decorator.segment_first;

    try std.testing.expectEqual(null, decorator.call);

    const joined = built.segments_text(first, decorator.segment_count, &buffer);

    try std.testing.expectEqualStrings("property", joined);
}

test "a class records each of its bases" {
    var built: Built = undefined;

    try built.init("class Widget(models.Model, Mixin):\n    pass\n");
    defer built.deinit();

    var buffer: [name_bytes_max]u8 = undefined;
    const bases = built.outline.bases.const_slice();

    try std.testing.expectEqual(2, bases.len);

    for ([_][]const u8{ "models.Model", "Mixin" }, bases) |expected, base| {
        try std.testing.expect(base.summary == .dotted_name);

        const dotted = base.summary.dotted_name;
        const joined = built.segments_text(dotted.segment_first, dotted.segment_count, &buffer);

        try std.testing.expectEqualStrings(expected, joined);
    }

    for (bases) |base| {
        try std.testing.expectEqualStrings("Widget", built.name_of(base.class_definition));
    }
}

test "a class without bases records none" {
    var built: Built = undefined;

    try built.init("class Widget:\n    pass\n");
    defer built.deinit();

    try std.testing.expect(built.outline.bases.empty());
}

test "a second build over the same outline replaces the first" {
    var first: Built = undefined;

    try first.init("a(1)\n");
    defer first.deinit();

    var second: Built = undefined;

    try second.init("a(1)\nb(2)\n");
    defer second.deinit();

    try std.testing.expectEqual(1, first.outline.calls.count());
    try std.testing.expectEqual(2, second.outline.calls.count());
}

test "a body on the header line still names its scope" {
    var built: Built = undefined;

    try built.init("class Row:\n    def name(self): return render(self)\n");
    defer built.deinit();

    const call = built.call_named("render") orelse return error.TestUnexpectedResult;

    try std.testing.expect(call.scope != null);
    try std.testing.expectEqualStrings("name", built.name_of(call.scope));
}

test "an empty source records nothing" {
    var built: Built = undefined;

    try built.init("");
    defer built.deinit();

    try std.testing.expect(built.outline.calls.empty());
    try std.testing.expect(built.outline.assignments.empty());
    try std.testing.expect(built.outline.bases.empty());
    try std.testing.expect(built.outline.decorators.empty());
}
