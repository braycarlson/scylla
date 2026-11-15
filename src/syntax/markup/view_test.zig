const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const Document = @import("document.zig").Document;
const Kind = @import("kind.zig").Kind;
const Span = @import("../../stdx/bounded/span.zig");
const View = @import("view.zig").View;
const Vocabulary = @import("vocabulary.zig").Vocabulary;

const Built = struct {
    document: Document,
    source: []const u8,

    fn init(built: *Built, gpa: std.mem.Allocator, source: []const u8) !void {
        assert(source.len <= std.math.maxInt(u32));

        built.source = source;
        built.document = try .init(gpa, capacity);
        errdefer built.document.deinit(gpa);

        try built.document.parse(source, &Vocabulary.empty);

        assert(built.document.node_count() > 0);
    }

    fn deinit(built: *Built, gpa: std.mem.Allocator) void {
        built.document.deinit(gpa);
        built.* = undefined;
    }

    fn first(built: *const Built, kind: Kind) !View {
        assert(kind.is_node());

        for (0..built.document.node_count()) |position| {
            const held = built.document.at(@intCast(position));
            if (held.kind() == kind) return held;
        }

        std.debug.print("the source carries no {s}\n", .{kind.name()});

        return error.TestUnexpectedResult;
    }

    fn span_text(built: *const Built, span: Span) []const u8 {
        assert(span.length <= std.math.maxInt(u32) - span.offset);

        return span.text(built.source);
    }

    fn token_text(built: *const Built, index: u32) []const u8 {
        assert(index < std.math.maxInt(u32));

        return built.document.tokens()[index].text(built.source);
    }

    fn expect_texts(built: *const Built, iterator: anytype, expected: []const []const u8) !void {
        comptime assert(@hasDecl(@TypeOf(iterator.*), "next"));
        assert(expected.len > 0);

        var index: usize = 0;

        while (iterator.next()) |token| {
            try std.testing.expect(index < expected.len);
            try std.testing.expectEqualStrings(expected[index], built.token_text(token));

            index += 1;
        }

        try std.testing.expectEqual(expected.len, index);
    }
};

const capacity: Document.Capacity = .{
    .diagnostic_count_max = 1 << 10,
    .node_count_max = 1 << 12,
    .tag_count_max = 1 << 6,
    .token_count_max = 1 << 14,
};

test "an element names itself and lists its attributes" {
    const gpa = std.testing.allocator;
    var built: Built = undefined;

    try built.init(gpa, "<DIV id=\"one\" class='two' hidden>body</div>");
    defer built.deinit(gpa);

    const element = (try built.first(.element)).as_element() orelse return error.NotElement;
    const name = element.name(built.source) orelse return error.NoName;

    try std.testing.expect(std.ascii.eqlIgnoreCase(name, "div"));
    try std.testing.expect(!std.ascii.eqlIgnoreCase(name, "span"));

    const expected = [_][]const u8{ "id", "class", "hidden" };
    var attributes = element.attributes();
    var index: usize = 0;

    while (attributes.next()) |attribute| {
        const token = attribute.name_token() orelse continue;

        try std.testing.expect(index < expected.len);
        try std.testing.expectEqualStrings(expected[index], built.token_text(token));

        index += 1;
    }

    try std.testing.expectEqual(expected.len, index);
}

test "an attribute value reports its template holes" {
    const gpa = std.testing.allocator;
    var built: Built = undefined;

    try built.init(gpa, "<div class=\"a {{ name }} b {% if x %} c\">");
    defer built.deinit(gpa);

    const element = (try built.first(.element)).as_element() orelse return error.NotElement;
    var attributes = element.attributes();
    const attribute = attributes.next() orelse return error.NoAttribute;
    const value = attribute.value() orelse return error.NoValue;
    var holes: ArrayType(Span) = try .init(gpa, 8);
    defer holes.deinit(gpa);

    try value.template_holes(&holes);
    try std.testing.expectEqual(2, holes.count());
    try std.testing.expectEqualStrings("{{ name }}", built.span_text(holes.get(0)));
    try std.testing.expectEqualStrings("{% if x %}", built.span_text(holes.get(1)));

    var text = value.text_tokens();

    try built.expect_texts(&text, &.{ "a ", " b ", " c" });
}

test "a template variable separates its expression from its filters" {
    const gpa = std.testing.allocator;
    var built: Built = undefined;

    try built.init(gpa, "{{ user.profile.name|title|default:\"none\" }}");
    defer built.deinit(gpa);

    const found = try built.first(.template_variable);
    const variable = found.as_template_variable() orelse return error.NotVariable;
    var expression = variable.expression_tokens();

    try built.expect_texts(&expression, &.{ "user", ".", "profile", ".", "name" });

    var filters = variable.filter_names();

    try built.expect_texts(&filters, &.{ "title", "default" });
}

test "a variable without filters carries its whole expression" {
    const gpa = std.testing.allocator;
    var built: Built = undefined;

    try built.init(gpa, "{{ value }}");
    defer built.deinit(gpa);

    const found = try built.first(.template_variable);
    const variable = found.as_template_variable() orelse return error.NotVariable;
    var expression = variable.expression_tokens();

    try built.expect_texts(&expression, &.{"value"});

    var filters = variable.filter_names();
    const filter = filters.next();

    try std.testing.expect(filter == null);
}

test "a script element reports its raw text" {
    const gpa = std.testing.allocator;
    var built: Built = undefined;

    try built.init(gpa, "<script>var a = 1;</script>");
    defer built.deinit(gpa);

    const element = (try built.first(.element)).as_element() orelse return error.NotElement;
    var raw = element.raw_text_tokens();

    try built.expect_texts(&raw, &.{"var a = 1;"});
}

test "a style element reports its raw text" {
    const gpa = std.testing.allocator;
    var built: Built = undefined;

    try built.init(gpa, "<style>a { b: c }</style>");
    defer built.deinit(gpa);

    const element = (try built.first(.element)).as_element() orelse return error.NotElement;
    var raw = element.raw_text_tokens();

    try built.expect_texts(&raw, &.{"a { b: c }"});
}

test "a direct token walk skips the tokens a child node owns" {
    const gpa = std.testing.allocator;
    var built: Built = undefined;

    try built.init(gpa, "<div class=\"{{ name }}\">");
    defer built.deinit(gpa);

    const element = (try built.first(.element)).as_element() orelse return error.NotElement;
    const open = element.open_tag() orelse return error.NoOpenTag;
    var direct = open.direct_tokens();

    try built.expect_texts(&direct, &.{ "<", "div", " ", ">" });
}

test "an unquoted string argument keeps its span" {
    const gpa = std.testing.allocator;
    var built: Built = undefined;

    try built.init(gpa, "{% url name %}");
    defer built.deinit(gpa);

    const tag = (try built.first(.template_tag)).as_template_tag() orelse return error.NotTag;
    var strings: ArrayType(Span) = try .init(gpa, 8);
    defer strings.deinit(gpa);

    try tag.string_arguments(built.source, &strings);
    try std.testing.expectEqual(0, strings.count());

    var arguments = tag.argument_tokens();

    try built.expect_texts(&arguments, &.{"name"});
}
