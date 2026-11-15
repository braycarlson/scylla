const std = @import("std");
const assert = std.debug.assert;
const Category = @import("../category.zig").Category;
const Token = @import("../token.zig");
const diagnostic = @import("../diagnostic.zig");

pub const Kind = enum(u16) {
    ampersand,
    ampersand_ampersand,
    ampersand_caret,
    ampersand_caret_equal,
    ampersand_equal,
    arrow,
    bang,
    bang_equal,
    bar,
    bar_bar,
    bar_equal,
    brace_close,
    brace_open,
    bracket_close,
    bracket_open,
    break_keyword,
    caret,
    caret_equal,
    case_keyword,
    chan_keyword,
    colon,
    colon_equal,
    comma,
    comment,
    const_keyword,
    continue_keyword,
    default_keyword,
    defer_keyword,
    dot,
    dot_dot_dot,
    else_keyword,
    equal,
    equal_equal,
    error_token,
    fallthrough_keyword,
    for_keyword,
    func_keyword,
    go_keyword,
    goto_keyword,
    greater,
    greater_equal,
    greater_greater,
    greater_greater_equal,
    identifier,
    if_keyword,
    import_keyword,
    interface_keyword,
    less,
    less_equal,
    less_less,
    less_less_equal,
    map_keyword,
    minus,
    minus_equal,
    minus_minus,
    newline,
    number,
    package_keyword,
    paren_close,
    paren_open,
    percent,
    percent_equal,
    plus,
    plus_equal,
    plus_plus,
    range_keyword,
    return_keyword,
    rune_literal,
    select_keyword,
    semicolon,
    slash,
    slash_equal,
    star,
    star_equal,
    string_literal,
    struct_keyword,
    switch_keyword,
    tilde,
    type_keyword,
    var_keyword,
    array_type,
    assign_stmt,
    bad_decl,
    bad_expr,
    bad_stmt,
    basic_lit,
    binary_expr,
    block_stmt,
    branch_stmt,
    call_expr,
    case_clause,
    chan_type,
    comm_clause,
    composite_lit,
    decl_stmt,
    defer_stmt,
    ellipsis,
    empty_stmt,
    error_node,
    expr_stmt,
    field,
    field_list,
    file,
    for_stmt,
    func_decl,
    func_lit,
    func_type,
    gen_decl,
    go_stmt,
    ident,
    if_stmt,
    import_spec,
    inc_dec_stmt,
    index_expr,
    index_list_expr,
    interface_type,
    key_value_expr,
    labeled_stmt,
    map_type,
    paren_expr,
    range_stmt,
    return_stmt,
    select_stmt,
    selector_expr,
    send_stmt,
    slice_expr,
    star_expr,
    struct_type,
    switch_stmt,
    type_assert_expr,
    type_spec,
    type_switch_stmt,
    unary_expr,
    value_spec,

    pub const Diagnostic = diagnostic.Diagnostic;

    pub fn category(kind: Kind) Category {
        const held = categories.get(kind);

        if (held == .file) assert(kind == .file);
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
        const result = kind.to_u16() < node_first;

        if (result) assert(kind != .error_node);

        return result;
    }

    pub fn is_trivia(kind: Kind) bool {
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
        const result: u16 = @backingInt(kind);

        assert(result < kind_count);

        return result;
    }

    pub fn token_kind(kind: Kind) Token.Kind {
        assert(kind.is_token());

        const result = token_kinds.get(kind);

        if (kind.is_trivia()) assert(result == .comment);
        if (result == .newline) assert(kind == .newline);

        return result;
    }
};

const Group = struct {
    category: Category,
    kinds: []const Kind,
};

const Projection = struct {
    coarse: Token.Kind,
    kinds: []const Kind,
};

pub const kind_count: u16 = 134;
const node_first: u16 = 80;
const categories: std.enums.EnumArray(Kind, Category) = categories_of();
const token_kinds: std.enums.EnumArray(Kind, Token.Kind) = token_kinds_of();

const groups = [_]Group{
    .{ .category = .assignment, .kinds = &.{ .assign_stmt, .inc_dec_stmt } },
    .{ .category = .block, .kinds = &.{ .block_stmt, .case_clause, .comm_clause } },
    .{ .category = .branch, .kinds = &.{.if_stmt} },
    .{ .category = .call, .kinds = &.{.call_expr} },
    .{ .category = .declaration, .kinds = &.{ .decl_stmt, .field, .gen_decl, .value_spec } },
    .{ .category = .expression, .kinds = &.{
        .bad_expr,
        .binary_expr,
        .composite_lit,
        .defer_stmt,
        .ellipsis,
        .expr_stmt,
        .go_stmt,
        .index_expr,
        .index_list_expr,
        .key_value_expr,
        .paren_expr,
        .selector_expr,
        .send_stmt,
        .slice_expr,
        .star_expr,
        .type_assert_expr,
        .unary_expr,
    } },
    .{ .category = .file, .kinds = &.{.file} },
    .{ .category = .function, .kinds = &.{.func_decl} },
    .{ .category = .import, .kinds = &.{.import_spec} },
    .{ .category = .lambda, .kinds = &.{.func_lit} },
    .{ .category = .loop, .kinds = &.{ .for_stmt, .range_stmt } },
    .{ .category = .match, .kinds = &.{ .select_stmt, .switch_stmt, .type_switch_stmt } },
    .{ .category = .name, .kinds = &.{ .ident, .identifier } },
    .{ .category = .other, .kinds = &.{
        .ampersand,
        .ampersand_ampersand,
        .ampersand_caret,
        .ampersand_caret_equal,
        .ampersand_equal,
        .arrow,
        .bang,
        .bang_equal,
        .bar,
        .bar_bar,
        .bar_equal,
        .brace_close,
        .brace_open,
        .bracket_close,
        .bracket_open,
        .break_keyword,
        .caret,
        .caret_equal,
        .case_keyword,
        .chan_keyword,
        .colon,
        .colon_equal,
        .comma,
        .comment,
        .const_keyword,
        .continue_keyword,
        .default_keyword,
        .defer_keyword,
        .dot,
        .dot_dot_dot,
        .else_keyword,
        .equal,
        .equal_equal,
        .error_token,
        .fallthrough_keyword,
        .for_keyword,
        .func_keyword,
        .go_keyword,
        .goto_keyword,
        .greater,
        .greater_equal,
        .greater_greater,
        .greater_greater_equal,
        .if_keyword,
        .import_keyword,
        .interface_keyword,
        .less,
        .less_equal,
        .less_less,
        .less_less_equal,
        .map_keyword,
        .minus,
        .minus_equal,
        .minus_minus,
        .newline,
        .package_keyword,
        .paren_close,
        .paren_open,
        .percent,
        .percent_equal,
        .plus,
        .plus_equal,
        .plus_plus,
        .range_keyword,
        .return_keyword,
        .select_keyword,
        .semicolon,
        .slash,
        .slash_equal,
        .star,
        .star_equal,
        .struct_keyword,
        .switch_keyword,
        .tilde,
        .type_keyword,
        .var_keyword,
        .bad_decl,
        .bad_stmt,
        .branch_stmt,
        .empty_stmt,
        .error_node,
        .labeled_stmt,
    } },
    .{ .category = .parameters, .kinds = &.{ .field_list, .func_type } },
    .{ .category = .@"return", .kinds = &.{.return_stmt} },
    .{ .category = .@"struct", .kinds = &.{ .interface_type, .struct_type, .type_spec } },
    .{ .category = .type, .kinds = &.{ .array_type, .chan_type, .map_type } },
    .{ .category = .value, .kinds = &.{ .basic_lit, .number, .rune_literal, .string_literal } },
};

const projections = [_]Projection{
    .{
        .coarse = .{ .punctuation = .ampersand },
        .kinds = &.{
            .ampersand,
            .ampersand_caret,
            .ampersand_caret_equal,
        },
    },
    .{ .coarse = .{ .punctuation = .ampersand_double }, .kinds = &.{.ampersand_ampersand} },
    .{ .coarse = .{ .punctuation = .less }, .kinds = &.{ .arrow, .less } },
    .{ .coarse = .{ .punctuation = .bang }, .kinds = &.{.bang} },
    .{ .coarse = .{ .punctuation = .not_equal }, .kinds = &.{.bang_equal} },
    .{ .coarse = .{ .punctuation = .bar_double }, .kinds = &.{.bar_bar} },
    .{ .coarse = .block_end, .kinds = &.{.brace_close} },
    .{ .coarse = .block_start, .kinds = &.{.brace_open} },
    .{ .coarse = .{ .punctuation = .bracket_close }, .kinds = &.{.bracket_close} },
    .{ .coarse = .{ .punctuation = .bracket_open }, .kinds = &.{.bracket_open} },
    .{ .coarse = .{ .keyword = .@"break" }, .kinds = &.{.break_keyword} },
    .{ .coarse = .{ .punctuation = .colon }, .kinds = &.{.colon} },
    .{ .coarse = .{ .punctuation = .assign_declare }, .kinds = &.{.colon_equal} },
    .{ .coarse = .{ .punctuation = .comma }, .kinds = &.{.comma} },
    .{ .coarse = .comment, .kinds = &.{.comment} },
    .{ .coarse = .{ .keyword = .constant }, .kinds = &.{.const_keyword} },
    .{ .coarse = .{ .keyword = .@"continue" }, .kinds = &.{.continue_keyword} },
    .{ .coarse = .{ .punctuation = .dot }, .kinds = &.{ .dot, .dot_dot_dot } },
    .{ .coarse = .{ .keyword = .branch_else }, .kinds = &.{.else_keyword} },
    .{ .coarse = .{ .punctuation = .assign }, .kinds = &.{.equal} },
    .{ .coarse = .{ .punctuation = .equal }, .kinds = &.{.equal_equal} },
    .{ .coarse = .{ .keyword = .loop }, .kinds = &.{.for_keyword} },
    .{ .coarse = .{ .keyword = .function }, .kinds = &.{.func_keyword} },
    .{ .coarse = .{ .keyword = .goto }, .kinds = &.{.goto_keyword} },
    .{ .coarse = .{ .punctuation = .greater }, .kinds = &.{ .greater, .greater_greater } },
    .{ .coarse = .{ .punctuation = .greater_equal }, .kinds = &.{.greater_equal} },
    .{ .coarse = .identifier, .kinds = &.{.identifier} },
    .{ .coarse = .{ .keyword = .branch }, .kinds = &.{.if_keyword} },
    .{ .coarse = .{ .keyword = .import }, .kinds = &.{.import_keyword} },
    .{ .coarse = .{ .punctuation = .less_equal }, .kinds = &.{.less_equal} },
    .{ .coarse = .newline, .kinds = &.{.newline} },
    .{ .coarse = .number, .kinds = &.{.number} },
    .{ .coarse = .{ .punctuation = .paren_close }, .kinds = &.{.paren_close} },
    .{ .coarse = .{ .punctuation = .paren_open }, .kinds = &.{.paren_open} },
    .{ .coarse = .{ .keyword = .@"return" }, .kinds = &.{.return_keyword} },
    .{ .coarse = .string, .kinds = &.{ .rune_literal, .string_literal } },
    .{ .coarse = .{ .keyword = .match }, .kinds = &.{ .select_keyword, .switch_keyword } },
    .{ .coarse = .{ .punctuation = .semicolon }, .kinds = &.{.semicolon} },
    .{ .coarse = .{ .punctuation = .slash }, .kinds = &.{.slash} },
    .{ .coarse = .{ .punctuation = .star }, .kinds = &.{.star} },
    .{ .coarse = .{ .keyword = .@"struct" }, .kinds = &.{ .struct_keyword, .type_keyword } },
    .{ .coarse = .{ .keyword = .mutable }, .kinds = &.{.var_keyword} },
    .{
        .coarse = .{ .keyword = .other },
        .kinds = &.{
            .case_keyword,
            .chan_keyword,
            .default_keyword,
            .defer_keyword,
            .fallthrough_keyword,
            .go_keyword,
            .interface_keyword,
            .map_keyword,
            .package_keyword,
            .range_keyword,
        },
    },
    .{
        .coarse = .{ .punctuation = .other },
        .kinds = &.{
            .ampersand_equal,
            .bar,
            .bar_equal,
            .caret,
            .caret_equal,
            .error_token,
            .greater_greater_equal,
            .less_less,
            .less_less_equal,
            .minus,
            .minus_equal,
            .minus_minus,
            .percent,
            .percent_equal,
            .plus,
            .plus_equal,
            .plus_plus,
            .slash_equal,
            .star_equal,
            .tilde,
        },
    },
};

comptime {
    assert(@typeInfo(Kind).@"enum".field_names.len == kind_count);
    assert(@backingInt(Kind.var_keyword) + 1 == node_first);
    assert(@backingInt(Kind.array_type) == node_first);
    assert(@backingInt(Kind.value_spec) + 1 == kind_count);
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

    assert(held.get(.file) == .file);

    return held;
}

fn token_kinds_of() std.enums.EnumArray(Kind, Token.Kind) {
    var held: std.enums.EnumArray(Kind, Token.Kind) = .initUndefined();
    var assigned: [kind_count]bool = @splat(false);

    @setEvalBranchQuota(100_000);

    for (projections) |projection| {
        assert(projection.kinds.len > 0);

        for (projection.kinds) |kind| {
            assert(kind.is_token());
            assert(!assigned[@backingInt(kind)]);

            assigned[@backingInt(kind)] = true;
            held.set(kind, projection.coarse);
        }
    }

    for (assigned, 0..) |named_kind, index| assert(named_kind == (index < node_first));

    assert(held.get(.comment) == .comment);

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
