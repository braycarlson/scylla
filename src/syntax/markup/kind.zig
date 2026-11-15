const std = @import("std");
const assert = std.debug.assert;
const Category = @import("../category.zig").Category;
const camel_of = @import("../category.zig").camel_of;
const diagnostic = @import("diagnostic.zig");

pub const Kind = enum(u16) {
    angle_close = 0,
    angle_open = 1,
    angle_open_slash = 2,
    attribute_name = 3,
    attribute_text = 4,
    attribute_value = 5,
    attribute = 6,
    close_tag = 7,
    colon = 8,
    comma = 9,
    comment_close = 10,
    comment_open = 11,
    comment_text = 12,
    doctype = 13,
    doctype_text = 14,
    document = 15,
    dot = 16,
    element = 17,
    element_name = 18,
    equals = 19,
    error_node = 20,
    error_token = 21,
    filter = 22,
    filter_chain = 23,
    html_comment = 24,
    html_comment_close = 25,
    html_comment_open = 26,
    identifier = 27,
    number = 28,
    open_tag = 29,
    pipe = 30,
    quote = 31,
    script_text = 32,
    slash = 33,
    slash_angle_close = 34,
    string = 35,
    style_text = 36,
    tag_close = 37,
    tag_name = 38,
    tag_open = 39,
    template_comment = 40,
    template_tag = 41,
    template_variable = 42,
    text = 43,
    variable_close = 44,
    variable_open = 45,
    verbatim_text = 46,
    whitespace = 47,

    pub const Diagnostic = diagnostic.Diagnostic;
    pub const count: u16 = 48;

    pub fn category(kind: Kind) Category {
        const held: Category = switch (kind) {
            .attribute, .attribute_name, .attribute_text, .attribute_value => .attribute,
            .close_tag, .element, .open_tag, .tag_close, .tag_open => .block,
            .filter, .filter_chain => .call,
            .document => .file,
            .element_name, .identifier, .tag_name => .name,
            .number, .string, .template_variable, .text, .verbatim_text => .value,
            .angle_close,
            .angle_open,
            .angle_open_slash,
            .colon,
            .comma,
            .comment_close,
            .comment_open,
            .comment_text,
            .doctype,
            .doctype_text,
            .dot,
            .equals,
            .error_node,
            .error_token,
            .html_comment,
            .html_comment_close,
            .html_comment_open,
            .pipe,
            .quote,
            .script_text,
            .slash,
            .slash_angle_close,
            .style_text,
            .template_comment,
            .template_tag,
            .variable_close,
            .variable_open,
            .whitespace,
            => .other,
        };

        if (held == .file) assert(kind == .document);
        if (kind.is_trivia()) assert(held == .other);

        return held;
    }

    pub fn is_node(kind: Kind) bool {
        const result = switch (kind) {
            .attribute_value,
            .attribute,
            .close_tag,
            .doctype,
            .document,
            .element,
            .error_node,
            .filter,
            .filter_chain,
            .html_comment,
            .open_tag,
            .template_comment,
            .template_tag,
            .template_variable,
            => true,
            else => false,
        };

        if (result) assert(!kind.is_trivia());

        return result;
    }

    pub fn is_token(kind: Kind) bool {
        assert(kind.to_u16() < count);

        return !kind.is_node();
    }

    pub fn is_trivia(kind: Kind) bool {
        assert(kind.to_u16() < count);

        return kind == .whitespace;
    }

    pub fn name(kind: Kind) []const u8 {
        const held: []const u8 = @tagName(kind);

        assert(held.len > 0);
        assert(kind.to_u16() < count);

        return held;
    }

    fn of_name(text: []const u8) ?Kind {
        assert(text.len > 0);

        return std.meta.stringToEnum(Kind, text);
    }

    pub fn of_u16(discriminant: u16) ?Kind {
        assert(@typeInfo(Kind).@"enum".field_names.len == count);

        if (discriminant >= count) return null;
        return @fromBackingInt(discriminant);
    }

    pub fn title(kind: Kind) []const u8 {
        @setEvalBranchQuota(count * 1_000);

        const held: []const u8 = switch (kind) {
            .html_comment => "HTMLComment",
            .html_comment_close => "HTMLCommentClose",
            .html_comment_open => "HTMLCommentOpen",
            inline else => |tag| comptime camel_of(@tagName(tag)),
        };

        assert(held.len > 0);
        assert(std.ascii.isUpper(held[0]));

        return held;
    }

    pub fn to_u16(kind: Kind) u16 {
        return @backingInt(kind);
    }
};

comptime {
    assert(std.enums.values(Kind).len == Kind.count);
    assert(@typeInfo(Kind).@"enum".field_names.len == Kind.count);
}

test Kind {
    try std.testing.expect(Kind.element.is_node());
    try std.testing.expect(Kind.element_name.is_token());
    try std.testing.expectEqualStrings("element_name", Kind.element_name.name());
    try std.testing.expectEqualStrings("ElementName", Kind.element_name.title());
    try std.testing.expectEqualStrings("HTMLComment", Kind.html_comment.title());
    try std.testing.expectEqual(Kind.count, std.enums.values(Kind).len);
}

test "each kind sits at its own discriminant" {
    const kinds = std.enums.values(Kind);

    for (kinds, 0..) |kind, index| {
        try std.testing.expectEqual(index, kind.to_u16());
        try std.testing.expectEqual(kind, Kind.of_u16(kind.to_u16()).?);
        try std.testing.expectEqual(kind, Kind.of_name(kind.name()).?);
    }

    try std.testing.expectEqual(Kind.count, kinds.len);
    try std.testing.expect(Kind.of_u16(Kind.count) == null);
}

test "a node kind is never a token kind" {
    for (std.enums.values(Kind)) |kind| {
        try std.testing.expect(kind.is_node() != kind.is_token());
    }

    try std.testing.expect(Kind.document.is_node());
    try std.testing.expect(Kind.text.is_token());
    try std.testing.expect(Kind.whitespace.is_trivia());
    try std.testing.expect(!Kind.text.is_trivia());
}
