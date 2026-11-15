const std = @import("std");
const assert = std.debug.assert;
const Category = @import("../category.zig").Category;
const Token = @import("../token.zig");
const diagnostic = @import("../diagnostic.zig");

pub const Kind = enum(u16) {
    ampersand,
    at,
    bang,
    bar_equal,
    brace_close,
    brace_open,
    bracket_close,
    bracket_open,
    caret,
    caret_equal,
    colon,
    colon_colon,
    comma,
    comment,
    dollar,
    dollar_equal,
    dot,
    equal,
    error_token,
    escape,
    float,
    greater,
    hash,
    identifier,
    less,
    minus,
    newline,
    number,
    paren_close,
    paren_open,
    percent,
    pipe,
    plus,
    question,
    semicolon,
    slash,
    star,
    star_equal,
    text,
    tilde,
    tilde_equal,
    unit,
    adjacent_sibling_selector,
    arguments,
    at_keyword,
    at_rule,
    attribute_name,
    attribute_selector,
    binary_expression,
    binary_query,
    block,
    call_expression,
    charset_statement,
    child_selector,
    class_name,
    class_selector,
    color_value,
    comment_node,
    declaration,
    descendant_selector,
    error_node,
    escape_sequence,
    feature_name,
    feature_query,
    float_value,
    from,
    function_name,
    grid_value,
    id_name,
    id_selector,
    identifier_node,
    import_statement,
    important,
    integer_value,
    javascript_comment,
    keyframe_block,
    keyframe_block_list,
    keyframes_name,
    keyframes_statement,
    keyword_query,
    media_statement,
    namespace_name,
    namespace_selector,
    namespace_statement,
    nesting_selector,
    parenthesized_query,
    parenthesized_value,
    plain_value,
    postcss_statement,
    property_name,
    pseudo_class_selector,
    pseudo_element_selector,
    rule_set,
    selector_query,
    selectors,
    sibling_selector,
    string_content,
    string_value,
    stylesheet,
    supports_statement,
    tag_name,
    to,
    unary_query,
    unit_node,
    universal_selector,

    pub const Diagnostic = diagnostic.Diagnostic;

    pub fn category(kind: Kind) Category {
        const held = categories.get(kind);

        if (held == .file) assert(kind == .stylesheet);
        if (kind == .error_node) assert(held == .other);
        if (kind.is_trivia()) assert(held == .other);

        return held;
    }

    pub fn token_kind(kind: Kind) Token.Kind {
        assert(kind.is_token());

        const held = projections.get(kind);

        if (kind == .brace_open) assert(held == .block_start);
        if (kind == .identifier) assert(held == .identifier);

        return held;
    }

    pub fn is_node(kind: Kind) bool {
        const result = kind.to_u16() >= node_first;

        if (result) assert(!kind.is_trivia());

        return result;
    }

    pub fn is_token(kind: Kind) bool {
        return kind.to_u16() < node_first;
    }

    fn is_trivia(kind: Kind) bool {
        const result = kind == .comment;

        if (result) assert(kind.is_token());

        return result;
    }

    pub fn name(kind: Kind) []const u8 {
        const held: []const u8 = @tagName(kind);

        assert(held.len > 0);
        assert(kind.to_u16() < kind_count);

        return held;
    }

    fn of_name(text: []const u8) ?Kind {
        assert(text.len > 0);

        return std.meta.stringToEnum(Kind, text);
    }

    pub fn of_u16(discriminant: u16) ?Kind {
        if (discriminant >= kind_count) return null;
        return @fromBackingInt(discriminant);
    }

    pub fn to_u16(kind: Kind) u16 {
        return @backingInt(kind);
    }
};

const Group = struct {
    category: Category,
    kinds: []const Kind,
};

const Projection = struct {
    kind: Token.Kind,
    kinds: []const Kind,
};

pub const kind_count: u16 = 105;
const node_first: u16 = 42;
const categories: std.enums.EnumArray(Kind, Category) = categories_of();
const projections: std.enums.EnumArray(Kind, Token.Kind) = projections_of();

const groups = [_]Group{
    .{ .category = .attribute, .kinds = &.{ .at_rule, .attribute_name, .attribute_selector } },
    .{ .category = .block, .kinds = &.{
        .block,
        .keyframe_block,
        .keyframe_block_list,
        .keyframes_statement,
        .media_statement,
        .rule_set,
        .supports_statement,
    } },
    .{ .category = .call, .kinds = &.{.call_expression} },
    .{ .category = .condition, .kinds = &.{
        .binary_query,
        .feature_query,
        .keyword_query,
        .parenthesized_query,
        .selector_query,
        .unary_query,
    } },
    .{ .category = .declaration, .kinds = &.{.declaration} },
    .{ .category = .expression, .kinds = &.{
        .adjacent_sibling_selector,
        .arguments,
        .binary_expression,
        .child_selector,
        .class_selector,
        .descendant_selector,
        .id_selector,
        .important,
        .namespace_selector,
        .nesting_selector,
        .parenthesized_value,
        .pseudo_class_selector,
        .pseudo_element_selector,
        .selectors,
        .sibling_selector,
        .universal_selector,
    } },
    .{ .category = .file, .kinds = &.{.stylesheet} },
    .{ .category = .import, .kinds = &.{
        .charset_statement,
        .import_statement,
        .namespace_statement,
    } },
    .{ .category = .name, .kinds = &.{
        .class_name,
        .feature_name,
        .function_name,
        .id_name,
        .identifier,
        .identifier_node,
        .keyframes_name,
        .namespace_name,
        .property_name,
        .tag_name,
    } },
    .{ .category = .other, .kinds = &.{
        .ampersand,
        .at,
        .bang,
        .bar_equal,
        .brace_close,
        .brace_open,
        .bracket_close,
        .bracket_open,
        .caret,
        .caret_equal,
        .colon,
        .colon_colon,
        .comma,
        .comment,
        .dollar,
        .dollar_equal,
        .dot,
        .equal,
        .error_token,
        .escape,
        .greater,
        .hash,
        .less,
        .minus,
        .newline,
        .paren_close,
        .paren_open,
        .percent,
        .pipe,
        .plus,
        .question,
        .semicolon,
        .slash,
        .star,
        .star_equal,
        .tilde,
        .tilde_equal,
        .at_keyword,
        .comment_node,
        .error_node,
        .escape_sequence,
        .javascript_comment,
        .postcss_statement,
    } },
    .{ .category = .value, .kinds = &.{
        .color_value,
        .float,
        .float_value,
        .from,
        .grid_value,
        .integer_value,
        .number,
        .plain_value,
        .string_content,
        .string_value,
        .text,
        .to,
        .unit,
        .unit_node,
    } },
};

const token_groups = [_]Projection{
    .{ .kind = .block_end, .kinds = &.{.brace_close} },
    .{ .kind = .block_start, .kinds = &.{.brace_open} },
    .{ .kind = .comment, .kinds = &.{.comment} },
    .{ .kind = .identifier, .kinds = &.{ .at, .escape, .identifier } },
    .{ .kind = .newline, .kinds = &.{.newline} },
    .{ .kind = .number, .kinds = &.{ .float, .number, .unit } },
    .{ .kind = .string, .kinds = &.{.text} },
    .{ .kind = .{ .punctuation = .ampersand }, .kinds = &.{.ampersand} },
    .{ .kind = .{ .punctuation = .assign }, .kinds = &.{.equal} },
    .{ .kind = .{ .punctuation = .bang }, .kinds = &.{.bang} },
    .{ .kind = .{ .punctuation = .bracket_close }, .kinds = &.{.bracket_close} },
    .{ .kind = .{ .punctuation = .bracket_open }, .kinds = &.{.bracket_open} },
    .{ .kind = .{ .punctuation = .colon }, .kinds = &.{ .colon, .colon_colon } },
    .{ .kind = .{ .punctuation = .comma }, .kinds = &.{.comma} },
    .{ .kind = .{ .punctuation = .dot }, .kinds = &.{.dot} },
    .{ .kind = .{ .punctuation = .greater }, .kinds = &.{.greater} },
    .{ .kind = .{ .punctuation = .less }, .kinds = &.{.less} },
    .{ .kind = .{ .punctuation = .other }, .kinds = &.{
        .bar_equal,
        .caret,
        .caret_equal,
        .dollar,
        .dollar_equal,
        .error_token,
        .hash,
        .minus,
        .percent,
        .pipe,
        .plus,
        .question,
        .star_equal,
        .tilde,
        .tilde_equal,
    } },
    .{ .kind = .{ .punctuation = .paren_close }, .kinds = &.{.paren_close} },
    .{ .kind = .{ .punctuation = .paren_open }, .kinds = &.{.paren_open} },
    .{ .kind = .{ .punctuation = .semicolon }, .kinds = &.{.semicolon} },
    .{ .kind = .{ .punctuation = .slash }, .kinds = &.{.slash} },
    .{ .kind = .{ .punctuation = .star }, .kinds = &.{.star} },
};

comptime {
    assert(@typeInfo(Kind).@"enum".field_names.len == kind_count);
    assert(@backingInt(Kind.unit) + 1 == node_first);
    assert(@backingInt(Kind.adjacent_sibling_selector) == node_first);
    assert(@backingInt(Kind.universal_selector) + 1 == kind_count);
}

fn categories_of() std.enums.EnumArray(Kind, Category) {
    var held: std.enums.EnumArray(Kind, Category) = .initUndefined();
    var assigned: [kind_count]bool = @splat(false);

    @setEvalBranchQuota(100_000);

    for (groups) |group| {
        assert(group.kinds.len > 0);

        for (group.kinds) |kind| {
            assert(!assigned[@backingInt(kind)]);

            assigned[@backingInt(kind)] = true;
            held.set(kind, group.category);
        }
    }

    for (assigned) |named_kind| assert(named_kind);

    assert(held.get(.stylesheet) == .file);

    return held;
}

fn projections_of() std.enums.EnumArray(Kind, Token.Kind) {
    var held: std.enums.EnumArray(Kind, Token.Kind) = .initUndefined();
    var assigned: [node_first]bool = @splat(false);

    @setEvalBranchQuota(100_000);

    for (token_groups) |group| {
        assert(group.kinds.len > 0);

        for (group.kinds) |kind| {
            assert(kind.is_token());
            assert(!assigned[@backingInt(kind)]);

            assigned[@backingInt(kind)] = true;
            held.set(kind, group.kind);
        }
    }

    for (assigned) |named_kind| assert(named_kind);

    assert(held.get(.brace_open) == .block_start);

    return held;
}

test "each kind sits at its own discriminant" {
    for (std.enums.values(Kind), 0..) |kind, index| {
        try std.testing.expectEqual(index, kind.to_u16());
        try std.testing.expectEqual(kind, Kind.of_u16(kind.to_u16()).?);
        try std.testing.expectEqual(kind, Kind.of_name(kind.name()).?);
    }

    try std.testing.expectEqual(kind_count, std.enums.values(Kind).len);
    try std.testing.expectEqual(null, Kind.of_u16(kind_count));
}

test "every token kind projects to the coarse kind its lexer assigned" {
    try std.testing.expectEqual(Token.Kind.identifier, Kind.at.token_kind());
    try std.testing.expectEqual(Token.Kind.number, Kind.unit.token_kind());
    try std.testing.expectEqual(Token.Kind{ .punctuation = .colon }, Kind.colon_colon.token_kind());
    try std.testing.expectEqual(Token.Kind{ .punctuation = .other }, Kind.tilde_equal.token_kind());
    try std.testing.expectEqual(Token.Kind.block_end, Kind.brace_close.token_kind());
}

test "the token range and the node range do not meet" {
    for (std.enums.values(Kind)) |kind| {
        try std.testing.expect(kind.is_node() != kind.is_token());
    }

    try std.testing.expect(Kind.of_u16(node_first - 1).?.is_token());
    try std.testing.expect(Kind.of_u16(node_first).?.is_node());
}
