const std = @import("std");
const assert = std.debug.assert;
const Category = @import("../category.zig").Category;
const Token = @import("../token.zig");
const diagnostic = @import("../diagnostic.zig");

pub const Kind = enum(u16) {
    ampersand,
    ampersand_equal,
    and_keyword,
    arrow,
    as_keyword,
    assert_keyword,
    async_keyword,
    at,
    at_equal,
    await_keyword,
    bang,
    bar,
    bar_equal,
    brace_close,
    brace_open,
    bracket_close,
    bracket_open,
    break_keyword,
    caret,
    caret_equal,
    class_keyword,
    colon,
    colon_equal,
    comma,
    comment,
    continue_keyword,
    dedent,
    def_keyword,
    del_keyword,
    dot,
    elif_keyword,
    ellipsis,
    else_keyword,
    equal,
    equal_equal,
    error_token,
    except_keyword,
    f_string_end,
    f_string_middle,
    f_string_start,
    false_keyword,
    finally_keyword,
    for_keyword,
    from_keyword,
    global_keyword,
    greater,
    greater_equal,
    greater_greater,
    greater_greater_equal,
    identifier,
    if_keyword,
    import_keyword,
    in_keyword,
    indent,
    is_keyword,
    lambda_keyword,
    less,
    less_equal,
    less_less,
    less_less_equal,
    minus,
    minus_equal,
    newline,
    none_keyword,
    nonlocal_keyword,
    not_equal,
    not_keyword,
    number_binary,
    number_complex,
    number_float,
    number_hexadecimal,
    number_integer,
    number_octal,
    or_keyword,
    paren_close,
    paren_open,
    pass_keyword,
    percent,
    percent_equal,
    plus,
    plus_equal,
    raise_keyword,
    return_keyword,
    semicolon,
    slash,
    slash_equal,
    slash_slash,
    slash_slash_equal,
    star,
    star_equal,
    star_star,
    star_star_equal,
    string_bytes,
    string_format,
    string_plain,
    tilde,
    true_keyword,
    try_keyword,
    while_keyword,
    with_keyword,
    yield_keyword,
    alias,
    ann_assign,
    arg,
    arguments,
    assert,
    assign,
    async_for,
    async_function_def,
    async_with,
    attribute,
    aug_assign,
    await,
    bin_op,
    block,
    bool_op,
    @"break",
    call,
    class_def,
    compare,
    comprehension,
    constant,
    @"continue",
    decorator,
    delete,
    dict,
    dict_comp,
    else_clause,
    error_node,
    except_handler,
    expr,
    finally_clause,
    @"for",
    formatted_value,
    function_def,
    generator_exp,
    global,
    @"if",
    if_exp,
    import,
    import_from,
    joined_str,
    keyword,
    lambda,
    list,
    list_comp,
    match,
    match_as,
    match_case,
    match_class,
    match_mapping,
    match_or,
    match_sequence,
    match_singleton,
    match_star,
    match_value,
    module,
    name_node,
    named_expr,
    nonlocal,
    param_spec,
    parenthesized,
    pass,
    raise,
    @"return",
    set,
    set_comp,
    slice,
    starred,
    subscript,
    @"try",
    try_star,
    tuple,
    type_alias,
    type_params,
    type_var,
    type_var_tuple,
    unary_op,
    @"while",
    with,
    with_item,
    yield,
    yield_from,

    pub const Diagnostic = diagnostic.Diagnostic;

    pub fn category(kind: Kind) Category {
        const held = categories.get(kind);

        if (held == .file) assert(kind == .module);
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

    pub fn token_kind(kind: Kind) Token.Kind {
        assert(kind.is_token());

        const held = token_kinds.get(kind);

        if (kind == .error_token) assert(held == .punctuation);
        if (kind == .identifier) assert(held == .identifier);

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

const Projection = struct {
    coarse: Token.Kind,
    kinds: []const Kind,
};

pub const kind_count: u16 = 183;
const node_first: u16 = 101;
const categories: std.enums.EnumArray(Kind, Category) = categories_of();
const token_kinds: std.enums.EnumArray(Kind, Token.Kind) = token_kinds_of();

const groups = [_]Group{
    .{ .category = .assignment, .kinds = &.{.aug_assign} },
    .{ .category = .attribute, .kinds = &.{.decorator} },
    .{ .category = .block, .kinds = &.{
        .async_with,
        .block,
        .else_clause,
        .finally_clause,
        .with,
    } },
    .{ .category = .branch, .kinds = &.{ .@"if", .if_exp, .match_case } },
    .{ .category = .call, .kinds = &.{.call} },
    .{ .category = .declaration, .kinds = &.{
        .ann_assign,
        .assign,
        .global,
        .named_expr,
        .nonlocal,
        .type_alias,
    } },
    .{ .category = .except, .kinds = &.{.except_handler} },
    .{ .category = .expression, .kinds = &.{
        .assert,
        .attribute,
        .await,
        .bin_op,
        .bool_op,
        .compare,
        .comprehension,
        .delete,
        .dict,
        .dict_comp,
        .expr,
        .formatted_value,
        .generator_exp,
        .joined_str,
        .keyword,
        .list,
        .list_comp,
        .match_as,
        .match_class,
        .match_mapping,
        .match_or,
        .match_sequence,
        .match_singleton,
        .match_star,
        .match_value,
        .parenthesized,
        .raise,
        .set,
        .set_comp,
        .slice,
        .starred,
        .subscript,
        .tuple,
        .unary_op,
        .with_item,
        .yield,
        .yield_from,
    } },
    .{ .category = .file, .kinds = &.{.module} },
    .{ .category = .function, .kinds = &.{ .async_function_def, .function_def } },
    .{ .category = .import, .kinds = &.{ .alias, .import, .import_from } },
    .{ .category = .lambda, .kinds = &.{.lambda} },
    .{ .category = .loop, .kinds = &.{ .async_for, .@"for", .@"while" } },
    .{ .category = .match, .kinds = &.{.match} },
    .{ .category = .name, .kinds = &.{ .identifier, .name_node } },
    .{ .category = .other, .kinds = &.{
        .ampersand,
        .ampersand_equal,
        .and_keyword,
        .arrow,
        .as_keyword,
        .assert_keyword,
        .async_keyword,
        .at,
        .at_equal,
        .await_keyword,
        .bang,
        .bar,
        .bar_equal,
        .brace_close,
        .brace_open,
        .bracket_close,
        .bracket_open,
        .break_keyword,
        .caret,
        .caret_equal,
        .class_keyword,
        .colon,
        .colon_equal,
        .comma,
        .comment,
        .continue_keyword,
        .dedent,
        .def_keyword,
        .del_keyword,
        .dot,
        .elif_keyword,
        .else_keyword,
        .equal,
        .equal_equal,
        .error_token,
        .except_keyword,
        .f_string_end,
        .f_string_middle,
        .f_string_start,
        .finally_keyword,
        .for_keyword,
        .from_keyword,
        .global_keyword,
        .greater,
        .greater_equal,
        .greater_greater,
        .greater_greater_equal,
        .if_keyword,
        .import_keyword,
        .in_keyword,
        .indent,
        .is_keyword,
        .lambda_keyword,
        .less,
        .less_equal,
        .less_less,
        .less_less_equal,
        .minus,
        .minus_equal,
        .newline,
        .nonlocal_keyword,
        .not_equal,
        .not_keyword,
        .or_keyword,
        .paren_close,
        .paren_open,
        .pass_keyword,
        .percent,
        .percent_equal,
        .plus,
        .plus_equal,
        .raise_keyword,
        .return_keyword,
        .semicolon,
        .slash,
        .slash_equal,
        .slash_slash,
        .slash_slash_equal,
        .star,
        .star_equal,
        .star_star,
        .star_star_equal,
        .tilde,
        .try_keyword,
        .while_keyword,
        .with_keyword,
        .yield_keyword,
        .@"break",
        .@"continue",
        .error_node,
        .pass,
    } },
    .{ .category = .parameter, .kinds = &.{ .arg, .param_spec, .type_var, .type_var_tuple } },
    .{ .category = .parameters, .kinds = &.{ .arguments, .type_params } },
    .{ .category = .@"return", .kinds = &.{.@"return"} },
    .{ .category = .@"struct", .kinds = &.{.class_def} },
    .{ .category = .@"try", .kinds = &.{ .@"try", .try_star } },
    .{ .category = .value, .kinds = &.{
        .constant,
        .ellipsis,
        .false_keyword,
        .none_keyword,
        .number_binary,
        .number_complex,
        .number_float,
        .number_hexadecimal,
        .number_integer,
        .number_octal,
        .string_bytes,
        .string_format,
        .string_plain,
        .true_keyword,
    } },
};

comptime {
    assert(@typeInfo(Kind).@"enum".field_names.len == kind_count);
    assert(@backingInt(Kind.yield_keyword) + 1 == node_first);
    assert(@backingInt(Kind.alias) == node_first);
    assert(@backingInt(Kind.yield_from) + 1 == kind_count);
}

const projections = [_]Projection{
    .{ .coarse = .block_end, .kinds = &.{.dedent} },
    .{ .coarse = .block_start, .kinds = &.{.indent} },
    .{ .coarse = .comment, .kinds = &.{.comment} },
    .{
        .coarse = .identifier,
        .kinds = &.{
            .false_keyword,
            .identifier,
            .none_keyword,
            .true_keyword,
        },
    },
    .{ .coarse = .newline, .kinds = &.{.newline} },
    .{
        .coarse = .number,
        .kinds = &.{
            .number_binary,
            .number_complex,
            .number_float,
            .number_hexadecimal,
            .number_integer,
            .number_octal,
        },
    },
    .{
        .coarse = .string,
        .kinds = &.{
            .f_string_end,
            .f_string_middle,
            .f_string_start,
            .string_bytes,
            .string_format,
            .string_plain,
        },
    },
    .{ .coarse = .{ .keyword = .@"break" }, .kinds = &.{.break_keyword} },
    .{ .coarse = .{ .keyword = .@"continue" }, .kinds = &.{.continue_keyword} },
    .{ .coarse = .{ .keyword = .@"return" }, .kinds = &.{.return_keyword} },
    .{ .coarse = .{ .keyword = .@"struct" }, .kinds = &.{.class_keyword} },
    .{ .coarse = .{ .keyword = .@"try" }, .kinds = &.{.try_keyword} },
    .{ .coarse = .{ .keyword = .assert }, .kinds = &.{.assert_keyword} },
    .{ .coarse = .{ .keyword = .branch }, .kinds = &.{.if_keyword} },
    .{ .coarse = .{ .keyword = .branch_else }, .kinds = &.{ .elif_keyword, .else_keyword } },
    .{ .coarse = .{ .keyword = .except }, .kinds = &.{.except_keyword} },
    .{ .coarse = .{ .keyword = .function }, .kinds = &.{.def_keyword} },
    .{ .coarse = .{ .keyword = .global }, .kinds = &.{ .global_keyword, .nonlocal_keyword } },
    .{ .coarse = .{ .keyword = .import }, .kinds = &.{ .from_keyword, .import_keyword } },
    .{ .coarse = .{ .keyword = .lambda }, .kinds = &.{.lambda_keyword} },
    .{ .coarse = .{ .keyword = .loop }, .kinds = &.{ .for_keyword, .while_keyword } },
    .{
        .coarse = .{ .keyword = .other },
        .kinds = &.{
            .as_keyword,
            .async_keyword,
            .await_keyword,
            .del_keyword,
            .finally_keyword,
            .in_keyword,
            .is_keyword,
            .pass_keyword,
            .raise_keyword,
            .with_keyword,
            .yield_keyword,
        },
    },
    .{ .coarse = .{ .punctuation = .ampersand }, .kinds = &.{.ampersand} },
    .{ .coarse = .{ .punctuation = .ampersand_double }, .kinds = &.{.and_keyword} },
    .{ .coarse = .{ .punctuation = .arrow }, .kinds = &.{.arrow} },
    .{ .coarse = .{ .punctuation = .assign }, .kinds = &.{.equal} },
    .{ .coarse = .{ .punctuation = .bang }, .kinds = &.{ .bang, .not_keyword } },
    .{ .coarse = .{ .punctuation = .bar_double }, .kinds = &.{.or_keyword} },
    .{ .coarse = .{ .punctuation = .bracket_close }, .kinds = &.{ .brace_close, .bracket_close } },
    .{ .coarse = .{ .punctuation = .bracket_open }, .kinds = &.{ .brace_open, .bracket_open } },
    .{ .coarse = .{ .punctuation = .colon }, .kinds = &.{ .colon, .colon_equal } },
    .{ .coarse = .{ .punctuation = .comma }, .kinds = &.{.comma} },
    .{ .coarse = .{ .punctuation = .dot }, .kinds = &.{ .dot, .ellipsis } },
    .{ .coarse = .{ .punctuation = .equal }, .kinds = &.{.equal_equal} },
    .{ .coarse = .{ .punctuation = .greater }, .kinds = &.{ .greater, .greater_greater } },
    .{ .coarse = .{ .punctuation = .greater_equal }, .kinds = &.{.greater_equal} },
    .{ .coarse = .{ .punctuation = .less }, .kinds = &.{ .less, .less_less } },
    .{ .coarse = .{ .punctuation = .less_equal }, .kinds = &.{.less_equal} },
    .{ .coarse = .{ .punctuation = .not_equal }, .kinds = &.{.not_equal} },
    .{
        .coarse = .{ .punctuation = .other },
        .kinds = &.{
            .ampersand_equal,
            .at,
            .at_equal,
            .bar,
            .bar_equal,
            .caret,
            .caret_equal,
            .error_token,
            .greater_greater_equal,
            .less_less_equal,
            .minus,
            .minus_equal,
            .percent,
            .percent_equal,
            .plus,
            .plus_equal,
            .slash_equal,
            .slash_slash_equal,
            .star_equal,
            .star_star_equal,
            .tilde,
        },
    },
    .{ .coarse = .{ .punctuation = .paren_close }, .kinds = &.{.paren_close} },
    .{ .coarse = .{ .punctuation = .paren_open }, .kinds = &.{.paren_open} },
    .{ .coarse = .{ .punctuation = .semicolon }, .kinds = &.{.semicolon} },
    .{ .coarse = .{ .punctuation = .slash }, .kinds = &.{ .slash, .slash_slash } },
    .{ .coarse = .{ .punctuation = .star }, .kinds = &.{ .star, .star_star } },
};

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

    assert(held.get(.indent) == .block_start);

    return held;
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

    assert(held.get(.module) == .file);

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

    try std.testing.expect(Kind.identifier.is_token());
    try std.testing.expect(Kind.f_string_start.is_token());
    try std.testing.expect(Kind.module.is_node());
    try std.testing.expect(Kind.joined_str.is_node());
    try std.testing.expect(Kind.of_u16(node_first - 1).?.is_token());
    try std.testing.expect(Kind.of_u16(node_first).?.is_node());
}
