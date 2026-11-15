const std = @import("std");
const assert = std.debug.assert;
const Category = @import("../category.zig").Category;
const Token = @import("../token.zig");
const diagnostic = @import("../diagnostic.zig");

pub const Kind = enum(u16) {
    ampersand,
    ampersand_ampersand,
    ampersand_ampersand_equal,
    ampersand_equal,
    ampersand_tilde,
    ampersand_tilde_equal,
    arrow,
    asm_keyword,
    at,
    auto_cast_keyword,
    bang,
    bang_equal,
    bar,
    bar_bar,
    bar_bar_equal,
    bar_equal,
    bit_field_keyword,
    bit_set_keyword,
    brace_close,
    brace_open,
    bracket_close,
    bracket_open,
    break_keyword,
    caret,
    case_keyword,
    cast_keyword,
    character,
    colon,
    colon_colon,
    colon_equal,
    comma,
    comment,
    comment_block,
    comment_tag,
    context_keyword,
    continue_keyword,
    defer_keyword,
    directive,
    distinct_keyword,
    do_keyword,
    dollar,
    dot,
    dot_dot,
    dot_dot_dot,
    dot_dot_equal,
    dot_dot_less,
    dynamic_keyword,
    else_keyword,
    enum_keyword,
    equal,
    equal_equal,
    error_token,
    fallthrough_keyword,
    false_keyword,
    fat_arrow,
    float,
    for_keyword,
    foreign_keyword,
    greater,
    greater_equal,
    greater_greater,
    greater_greater_equal,
    identifier,
    if_keyword,
    import_keyword,
    in_keyword,
    less,
    less_equal,
    less_less,
    less_less_equal,
    map_keyword,
    matrix_keyword,
    minus,
    minus_equal,
    minus_minus_minus,
    newline,
    nil_keyword,
    not_in_keyword,
    number,
    or_break_keyword,
    or_continue_keyword,
    or_else_keyword,
    or_return_keyword,
    package_keyword,
    paren_close,
    paren_open,
    percent,
    percent_equal,
    percent_percent,
    percent_percent_equal,
    plus,
    plus_equal,
    proc_keyword,
    question,
    return_keyword,
    semicolon,
    slash,
    slash_equal,
    star,
    star_equal,
    struct_keyword,
    switch_keyword,
    text,
    tilde,
    tilde_equal,
    transmute_keyword,
    true_keyword,
    typeid_keyword,
    union_keyword,
    using_keyword,
    when_keyword,
    where_keyword,
    address,
    array_type,
    assignment_statement,
    attribute,
    attributes,
    binary_expression,
    bit_field_declaration,
    bit_field_type,
    bit_set,
    bit_set_type,
    block,
    block_comment,
    boolean,
    break_statement,
    build_tag,
    call_expression,
    calling_convention,
    cast_expression,
    character_node,
    comment_node,
    conditional_type,
    const_declaration,
    const_type_declaration,
    constant_type,
    continue_statement,
    default_parameter,
    default_type,
    defer_statement,
    distinct_type,
    else_clause,
    else_if_clause,
    else_when_clause,
    empty_type,
    enum_declaration,
    enum_type,
    error_node,
    escape_sequence,
    fallthrough_statement,
    field,
    field_identifier,
    field_type,
    float_node,
    for_statement,
    foreign_block,
    identifier_node,
    if_statement,
    import_declaration,
    in_expression,
    index_expression,
    label_statement,
    map,
    map_type,
    matrix,
    matrix_type,
    member_expression,
    named_type,
    nil,
    number_node,
    or_break_expression,
    or_continue_expression,
    or_return_expression,
    overloaded_procedure_declaration,
    package_declaration,
    parameter,
    parameters,
    parenthesized_expression,
    pointer_type,
    polymorphic_parameters,
    polymorphic_type,
    procedure,
    procedure_declaration,
    procedure_type,
    range_expression,
    return_statement,
    selector_call_expression,
    slice_expression,
    source_file,
    specialized_type,
    string,
    string_content,
    @"struct",
    struct_declaration,
    struct_field,
    struct_member,
    struct_type,
    switch_case,
    switch_statement,
    tag,
    tagged_block,
    ternary_expression,
    tuple_type,
    type,
    unary_expression,
    uninitialized,
    union_declaration,
    union_type,
    update_statement,
    using_statement,
    var_declaration,
    variable_declaration,
    variadic_expression,
    variadic_type,
    when_statement,
    where_clause,

    pub const Diagnostic = diagnostic.Diagnostic;

    pub fn category(kind: Kind) Category {
        const held = categories.get(kind);

        if (held == .file) assert(kind == .source_file);
        if (kind == .error_node) assert(held == .other);
        if (kind.is_trivia()) assert(held == .other);

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

    pub fn is_trivia(kind: Kind) bool {
        const result = switch (kind) {
            .comment, .comment_block, .comment_tag => true,
            else => false,
        };

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

    pub fn token_kind(kind: Kind) Token.Kind {
        assert(kind.is_token());

        const held = coarse.get(kind);

        if (kind.is_trivia()) assert(held == .comment);
        if (held == .newline) assert(kind == .newline);

        return held;
    }

    pub fn to_u16(kind: Kind) u16 {
        return @backingInt(kind);
    }
};

const Group = struct {
    category: Category,
    kinds: []const Kind,
};

pub const kind_count: u16 = 216;
const node_first: u16 = 112;
const categories: std.enums.EnumArray(Kind, Category) = categories_of();

const CoarseGroup = struct {
    coarse: Token.Kind,
    kinds: []const Kind,
};

const coarse_groups = [_]CoarseGroup{
    .{
        .coarse = .{ .punctuation = .ampersand },
        .kinds = &.{
            .ampersand,
            .ampersand_tilde,
            .ampersand_tilde_equal,
        },
    },
    .{
        .coarse = .{ .punctuation = .ampersand_double },
        .kinds = &.{
            .ampersand_ampersand,
            .ampersand_ampersand_equal,
        },
    },
    .{
        .coarse = .{ .punctuation = .other },
        .kinds = &.{
            .ampersand_equal,
            .at,
            .bar,
            .bar_equal,
            .caret,
            .dollar,
            .error_token,
            .fat_arrow,
            .greater_greater_equal,
            .less_less_equal,
            .minus,
            .minus_equal,
            .minus_minus_minus,
            .percent,
            .percent_equal,
            .percent_percent,
            .percent_percent_equal,
            .plus,
            .plus_equal,
            .question,
            .slash_equal,
            .star_equal,
            .tilde,
            .tilde_equal,
        },
    },
    .{ .coarse = .{ .punctuation = .arrow }, .kinds = &.{.arrow} },
    .{
        .coarse = .{ .keyword = .other },
        .kinds = &.{
            .asm_keyword,
            .auto_cast_keyword,
            .case_keyword,
            .cast_keyword,
            .context_keyword,
            .defer_keyword,
            .distinct_keyword,
            .do_keyword,
            .dynamic_keyword,
            .fallthrough_keyword,
            .foreign_keyword,
            .in_keyword,
            .map_keyword,
            .matrix_keyword,
            .not_in_keyword,
            .or_break_keyword,
            .or_continue_keyword,
            .or_else_keyword,
            .or_return_keyword,
            .package_keyword,
            .transmute_keyword,
            .typeid_keyword,
            .using_keyword,
            .where_keyword,
        },
    },
    .{ .coarse = .{ .punctuation = .bang }, .kinds = &.{.bang} },
    .{ .coarse = .{ .punctuation = .not_equal }, .kinds = &.{.bang_equal} },
    .{ .coarse = .{ .punctuation = .bar_double }, .kinds = &.{ .bar_bar, .bar_bar_equal } },
    .{
        .coarse = .{ .keyword = .@"struct" },
        .kinds = &.{
            .bit_field_keyword,
            .bit_set_keyword,
            .enum_keyword,
            .struct_keyword,
            .union_keyword,
        },
    },
    .{ .coarse = .block_end, .kinds = &.{.brace_close} },
    .{ .coarse = .block_start, .kinds = &.{.brace_open} },
    .{ .coarse = .{ .punctuation = .bracket_close }, .kinds = &.{.bracket_close} },
    .{ .coarse = .{ .punctuation = .bracket_open }, .kinds = &.{.bracket_open} },
    .{ .coarse = .{ .keyword = .@"break" }, .kinds = &.{.break_keyword} },
    .{ .coarse = .string, .kinds = &.{ .character, .text } },
    .{ .coarse = .{ .punctuation = .colon }, .kinds = &.{.colon} },
    .{ .coarse = .{ .punctuation = .assign_declare }, .kinds = &.{ .colon_colon, .colon_equal } },
    .{ .coarse = .{ .punctuation = .comma }, .kinds = &.{.comma} },
    .{ .coarse = .comment, .kinds = &.{ .comment, .comment_block, .comment_tag } },
    .{ .coarse = .{ .keyword = .@"continue" }, .kinds = &.{.continue_keyword} },
    .{
        .coarse = .identifier,
        .kinds = &.{
            .directive,
            .false_keyword,
            .identifier,
            .nil_keyword,
            .true_keyword,
        },
    },
    .{
        .coarse = .{ .punctuation = .dot },
        .kinds = &.{
            .dot,
            .dot_dot,
            .dot_dot_dot,
            .dot_dot_equal,
            .dot_dot_less,
        },
    },
    .{ .coarse = .{ .keyword = .branch_else }, .kinds = &.{.else_keyword} },
    .{ .coarse = .{ .punctuation = .assign }, .kinds = &.{.equal} },
    .{ .coarse = .{ .punctuation = .equal }, .kinds = &.{.equal_equal} },
    .{ .coarse = .number, .kinds = &.{ .float, .number } },
    .{ .coarse = .{ .keyword = .loop }, .kinds = &.{.for_keyword} },
    .{ .coarse = .{ .punctuation = .greater }, .kinds = &.{ .greater, .greater_greater } },
    .{ .coarse = .{ .punctuation = .greater_equal }, .kinds = &.{.greater_equal} },
    .{ .coarse = .{ .keyword = .branch }, .kinds = &.{ .if_keyword, .when_keyword } },
    .{ .coarse = .{ .keyword = .import }, .kinds = &.{.import_keyword} },
    .{ .coarse = .{ .punctuation = .less }, .kinds = &.{ .less, .less_less } },
    .{ .coarse = .{ .punctuation = .less_equal }, .kinds = &.{.less_equal} },
    .{ .coarse = .newline, .kinds = &.{.newline} },
    .{ .coarse = .{ .punctuation = .paren_close }, .kinds = &.{.paren_close} },
    .{ .coarse = .{ .punctuation = .paren_open }, .kinds = &.{.paren_open} },
    .{ .coarse = .{ .keyword = .function }, .kinds = &.{.proc_keyword} },
    .{ .coarse = .{ .keyword = .@"return" }, .kinds = &.{.return_keyword} },
    .{ .coarse = .{ .punctuation = .semicolon }, .kinds = &.{.semicolon} },
    .{ .coarse = .{ .punctuation = .slash }, .kinds = &.{.slash} },
    .{ .coarse = .{ .punctuation = .star }, .kinds = &.{.star} },
    .{ .coarse = .{ .keyword = .match }, .kinds = &.{.switch_keyword} },
};

const coarse: std.enums.EnumArray(Kind, Token.Kind) = coarse_of();

fn coarse_of() std.enums.EnumArray(Kind, Token.Kind) {
    var held: std.enums.EnumArray(Kind, Token.Kind) = .initUndefined();
    var assigned: [node_first]bool = @splat(false);

    @setEvalBranchQuota(100_000);

    for (coarse_groups) |group| {
        assert(group.kinds.len > 0);

        for (group.kinds) |kind| {
            assert(kind.is_token());
            assert(!assigned[@backingInt(kind)]);

            assigned[@backingInt(kind)] = true;
            held.set(kind, group.coarse);
        }
    }

    for (assigned) |named_kind| assert(named_kind);

    assert(held.get(.newline) == .newline);
    assert(held.get(.brace_open) == .block_start);

    return held;
}

const groups = [_]Group{
    .{ .category = .assignment, .kinds = &.{ .assignment_statement, .update_statement } },
    .{ .category = .attribute, .kinds = &.{ .attribute, .attributes, .build_tag, .tag } },
    .{ .category = .block, .kinds = &.{ .block, .else_clause, .foreign_block, .tagged_block } },
    .{ .category = .branch, .kinds = &.{
        .else_if_clause,
        .else_when_clause,
        .if_statement,
        .switch_case,
        .ternary_expression,
        .when_statement,
    } },
    .{ .category = .call, .kinds = &.{ .call_expression, .selector_call_expression } },
    .{ .category = .declaration, .kinds = &.{
        .const_declaration,
        .const_type_declaration,
        .field,
        .struct_field,
        .struct_member,
        .var_declaration,
        .variable_declaration,
    } },
    .{ .category = .expression, .kinds = &.{
        .address,
        .binary_expression,
        .cast_expression,
        .defer_statement,
        .in_expression,
        .index_expression,
        .member_expression,
        .or_break_expression,
        .or_continue_expression,
        .or_return_expression,
        .parenthesized_expression,
        .range_expression,
        .slice_expression,
        .unary_expression,
        .using_statement,
        .variadic_expression,
    } },
    .{ .category = .file, .kinds = &.{.source_file} },
    .{ .category = .function, .kinds = &.{
        .overloaded_procedure_declaration,
        .procedure_declaration,
    } },
    .{ .category = .import, .kinds = &.{ .import_declaration, .package_declaration } },
    .{ .category = .lambda, .kinds = &.{.procedure} },
    .{ .category = .loop, .kinds = &.{.for_statement} },
    .{ .category = .match, .kinds = &.{.switch_statement} },
    .{ .category = .name, .kinds = &.{ .field_identifier, .identifier, .identifier_node } },
    .{ .category = .other, .kinds = &.{
        .ampersand,
        .ampersand_ampersand,
        .ampersand_ampersand_equal,
        .ampersand_equal,
        .ampersand_tilde,
        .ampersand_tilde_equal,
        .arrow,
        .asm_keyword,
        .at,
        .auto_cast_keyword,
        .bang,
        .bang_equal,
        .bar,
        .bar_bar,
        .bar_bar_equal,
        .bar_equal,
        .bit_field_keyword,
        .bit_set_keyword,
        .brace_close,
        .brace_open,
        .bracket_close,
        .bracket_open,
        .break_keyword,
        .caret,
        .case_keyword,
        .cast_keyword,
        .colon,
        .colon_colon,
        .colon_equal,
        .comma,
        .comment,
        .comment_block,
        .comment_tag,
        .context_keyword,
        .continue_keyword,
        .defer_keyword,
        .directive,
        .distinct_keyword,
        .do_keyword,
        .dollar,
        .dot,
        .dot_dot,
        .dot_dot_dot,
        .dot_dot_equal,
        .dot_dot_less,
        .dynamic_keyword,
        .else_keyword,
        .enum_keyword,
        .equal,
        .equal_equal,
        .error_token,
        .fallthrough_keyword,
        .fat_arrow,
        .for_keyword,
        .foreign_keyword,
        .greater,
        .greater_equal,
        .greater_greater,
        .greater_greater_equal,
        .if_keyword,
        .import_keyword,
        .in_keyword,
        .less,
        .less_equal,
        .less_less,
        .less_less_equal,
        .map_keyword,
        .matrix_keyword,
        .minus,
        .minus_equal,
        .minus_minus_minus,
        .newline,
        .not_in_keyword,
        .or_break_keyword,
        .or_continue_keyword,
        .or_else_keyword,
        .or_return_keyword,
        .package_keyword,
        .paren_close,
        .paren_open,
        .percent,
        .percent_equal,
        .percent_percent,
        .percent_percent_equal,
        .plus,
        .plus_equal,
        .proc_keyword,
        .question,
        .return_keyword,
        .semicolon,
        .slash,
        .slash_equal,
        .star,
        .star_equal,
        .struct_keyword,
        .switch_keyword,
        .text,
        .tilde,
        .tilde_equal,
        .transmute_keyword,
        .typeid_keyword,
        .union_keyword,
        .using_keyword,
        .when_keyword,
        .where_keyword,
        .block_comment,
        .break_statement,
        .comment_node,
        .continue_statement,
        .error_node,
        .escape_sequence,
        .fallthrough_statement,
        .label_statement,
    } },
    .{ .category = .parameter, .kinds = &.{ .default_parameter, .parameter } },
    .{ .category = .parameters, .kinds = &.{ .parameters, .polymorphic_parameters } },
    .{ .category = .@"return", .kinds = &.{.return_statement} },
    .{ .category = .@"struct", .kinds = &.{
        .bit_field_declaration,
        .bit_field_type,
        .bit_set,
        .bit_set_type,
        .enum_declaration,
        .enum_type,
        .@"struct",
        .struct_declaration,
        .struct_type,
        .union_declaration,
        .union_type,
    } },
    .{ .category = .type, .kinds = &.{
        .array_type,
        .calling_convention,
        .conditional_type,
        .constant_type,
        .default_type,
        .distinct_type,
        .empty_type,
        .field_type,
        .map,
        .map_type,
        .matrix,
        .matrix_type,
        .named_type,
        .pointer_type,
        .polymorphic_type,
        .procedure_type,
        .specialized_type,
        .tuple_type,
        .type,
        .variadic_type,
        .where_clause,
    } },
    .{ .category = .value, .kinds = &.{
        .boolean,
        .character,
        .character_node,
        .false_keyword,
        .float,
        .float_node,
        .nil,
        .nil_keyword,
        .number,
        .number_node,
        .string,
        .string_content,
        .true_keyword,
        .uninitialized,
    } },
};

comptime {
    assert(@typeInfo(Kind).@"enum".field_names.len == kind_count);
    assert(@backingInt(Kind.where_keyword) + 1 == node_first);
    assert(@backingInt(Kind.address) == node_first);
    assert(@backingInt(Kind.where_clause) + 1 == kind_count);
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

    assert(held.get(.source_file) == .file);

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

test "the token range and the node range do not meet" {
    for (std.enums.values(Kind)) |kind| {
        try std.testing.expect(kind.is_node() != kind.is_token());
    }

    try std.testing.expect(Kind.of_u16(node_first - 1).?.is_token());
    try std.testing.expect(Kind.of_u16(node_first).?.is_node());
}

test "a kind names itself by its tag and sits in its category" {
    try std.testing.expectEqualStrings("character_node", Kind.character_node.name());
    try std.testing.expectEqual(Kind.character_node, Kind.of_name("character_node").?);
    try std.testing.expectEqual(Category.other, Kind.error_node.category());
    try std.testing.expectEqual(Category.value, Kind.number_node.category());
    try std.testing.expectEqual(Category.name, Kind.identifier.category());
}
