const std = @import("std");
const assert = std.debug.assert;
const Category = @import("../category.zig").Category;
const Token = @import("../token.zig");
const diagnostic = @import("../diagnostic.zig");

pub const Kind = enum(u16) {
    ampersand,
    ampersand_equal,
    apostrophe,
    as_keyword,
    async_keyword,
    at,
    await_keyword,
    bang,
    bang_equal,
    brace_close,
    brace_open,
    bracket_close,
    bracket_open,
    break_keyword,
    byte_literal,
    byte_string_literal,
    c_string_literal,
    caret,
    caret_equal,
    char_literal,
    colon,
    colon_colon,
    comma,
    comment,
    const_keyword,
    continue_keyword,
    crate_keyword,
    doc_comment,
    dollar,
    dot,
    dot_dot,
    dot_dot_dot,
    dot_dot_equal,
    dyn_keyword,
    else_keyword,
    enum_keyword,
    equal,
    equal_equal,
    error_token,
    extern_keyword,
    false_keyword,
    fat_arrow,
    fn_keyword,
    for_keyword,
    greater,
    greater_equal,
    greater_greater_equal,
    identifier,
    if_keyword,
    impl_keyword,
    in_keyword,
    less,
    less_equal,
    less_less_equal,
    let_keyword,
    loop_keyword,
    macro_keyword,
    match_keyword,
    minus,
    minus_equal,
    mod_keyword,
    move_keyword,
    mut_keyword,
    number,
    @"or",
    or_equal,
    or_or,
    paren_close,
    paren_open,
    percent,
    percent_equal,
    plus,
    plus_equal,
    pound,
    pub_keyword,
    question,
    r_arrow,
    ref_keyword,
    return_keyword,
    self_lower,
    self_upper,
    semicolon,
    slash,
    slash_equal,
    star,
    star_equal,
    static_keyword,
    string_literal,
    struct_keyword,
    super_keyword,
    tilde,
    trait_keyword,
    true_keyword,
    try_keyword,
    type_keyword,
    underscore,
    union_keyword,
    unsafe_keyword,
    use_keyword,
    where_keyword,
    while_keyword,
    yield_keyword,
    abi,
    arm,
    assoc_const,
    assoc_type,
    attribute,
    bare_fn_arg,
    bare_variadic,
    block,
    bound_lifetimes,
    const_param,
    constraint,
    error_node,
    expr_array,
    expr_assign,
    expr_async,
    expr_await,
    expr_binary,
    expr_block,
    expr_break,
    expr_call,
    expr_cast,
    expr_closure,
    expr_const,
    expr_continue,
    expr_field,
    expr_for_loop,
    expr_group,
    expr_if,
    expr_index,
    expr_infer,
    expr_let,
    expr_lit,
    expr_loop,
    expr_macro,
    expr_match,
    expr_method_call,
    expr_paren,
    expr_path,
    expr_range,
    expr_raw_addr,
    expr_reference,
    expr_repeat,
    expr_return,
    expr_struct,
    expr_try,
    expr_try_block,
    expr_tuple,
    expr_unary,
    expr_unsafe,
    expr_while,
    expr_yield,
    field,
    field_pat,
    field_value,
    fields_named,
    fields_unnamed,
    file,
    foreign_item_fn,
    foreign_item_macro,
    foreign_item_static,
    foreign_item_type,
    generics,
    ident,
    impl_item_const,
    impl_item_fn,
    impl_item_macro,
    impl_item_type,
    index,
    item_const,
    item_enum,
    item_extern_crate,
    item_fn,
    item_foreign_mod,
    item_impl,
    item_macro,
    item_mod,
    item_static,
    item_struct,
    item_trait,
    item_trait_alias,
    item_type,
    item_union,
    item_use,
    label,
    lifetime,
    lifetime_param,
    lit_bool,
    lit_byte,
    lit_byte_str,
    lit_c_str,
    lit_char,
    lit_float,
    lit_int,
    lit_str,
    local,
    macro,
    meta_list,
    meta_name_value,
    pat_ident,
    pat_or,
    pat_paren,
    pat_reference,
    pat_rest,
    pat_slice,
    pat_struct,
    pat_tuple,
    pat_tuple_struct,
    pat_type,
    pat_wild,
    path,
    path_segment,
    precise_capture,
    predicate_lifetime,
    predicate_type,
    receiver,
    signature,
    stmt_macro,
    trait_bound,
    trait_item_const,
    trait_item_fn,
    trait_item_macro,
    trait_item_type,
    type_array,
    type_bare_fn,
    type_group,
    type_impl_trait,
    type_infer,
    type_macro,
    type_never,
    type_param,
    type_paren,
    type_path,
    type_ptr,
    type_reference,
    type_slice,
    type_trait_object,
    type_tuple,
    use_glob,
    use_group,
    use_name,
    use_path,
    use_rename,
    variadic,
    variant,
    vis_restricted,
    where_clause,

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
        return kind.to_u16() < node_first;
    }

    pub fn is_type(kind: Kind) bool {
        const result = switch (kind) {
            .type_array,
            .type_bare_fn,
            .type_group,
            .type_impl_trait,
            .type_infer,
            .type_macro,
            .type_never,
            .type_param,
            .type_paren,
            .type_path,
            .type_ptr,
            .type_reference,
            .type_slice,
            .type_trait_object,
            .type_tuple,
            => true,
            else => false,
        };

        if (result) assert(kind.is_node());

        return result;
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

        const kind: Kind = @fromBackingInt(discriminant);

        assert(kind.to_u16() == discriminant);

        return kind;
    }

    pub fn token_kind(kind: Kind) Token.Kind {
        assert(kind.is_token());

        const held = coarse.get(kind);

        if (kind == .identifier) assert(held == .identifier);
        if (kind == .number) assert(held == .number);

        return held;
    }

    pub fn to_u16(kind: Kind) u16 {
        const discriminant: u16 = @backingInt(kind);

        assert(discriminant < kind_count);

        return discriminant;
    }
};

const Coarse = struct {
    coarse: Token.Kind,
    kinds: []const Kind,
};

const Group = struct {
    category: Category,
    kinds: []const Kind,
};

pub const kind_count: u16 = 248;
const node_first: u16 = 102;
const categories: std.enums.EnumArray(Kind, Category) = categories_of();
const coarse: std.enums.EnumArray(Kind, Token.Kind) = coarse_of();

const coarses = [_]Coarse{
    .{ .coarse = .block_end, .kinds = &.{.brace_close} },
    .{ .coarse = .block_start, .kinds = &.{.brace_open} },
    .{ .coarse = .comment, .kinds = &.{ .comment, .doc_comment } },
    .{ .coarse = .identifier, .kinds = &.{
        .apostrophe,
        .false_keyword,
        .identifier,
        .macro_keyword,
        .self_upper,
        .true_keyword,
        .try_keyword,
        .underscore,
        .union_keyword,
        .yield_keyword,
    } },
    .{ .coarse = .number, .kinds = &.{.number} },
    .{ .coarse = .string, .kinds = &.{
        .byte_literal,
        .byte_string_literal,
        .c_string_literal,
        .char_literal,
        .string_literal,
    } },
    .{ .coarse = .{ .keyword = .branch }, .kinds = &.{.if_keyword} },
    .{ .coarse = .{ .keyword = .branch_else }, .kinds = &.{.else_keyword} },
    .{ .coarse = .{ .keyword = .@"break" }, .kinds = &.{.break_keyword} },
    .{ .coarse = .{ .keyword = .constant }, .kinds = &.{ .const_keyword, .static_keyword } },
    .{ .coarse = .{ .keyword = .@"continue" }, .kinds = &.{.continue_keyword} },
    .{ .coarse = .{ .keyword = .declare }, .kinds = &.{.let_keyword} },
    .{ .coarse = .{ .keyword = .function }, .kinds = &.{.fn_keyword} },
    .{ .coarse = .{ .keyword = .import }, .kinds = &.{.use_keyword} },
    .{ .coarse = .{ .keyword = .loop }, .kinds = &.{ .for_keyword, .while_keyword } },
    .{ .coarse = .{ .keyword = .loop_unbounded }, .kinds = &.{.loop_keyword} },
    .{ .coarse = .{ .keyword = .match }, .kinds = &.{.match_keyword} },
    .{ .coarse = .{ .keyword = .mutable }, .kinds = &.{.mut_keyword} },
    .{ .coarse = .{ .keyword = .other }, .kinds = &.{
        .as_keyword,
        .async_keyword,
        .await_keyword,
        .crate_keyword,
        .dyn_keyword,
        .extern_keyword,
        .in_keyword,
        .mod_keyword,
        .move_keyword,
        .pub_keyword,
        .ref_keyword,
        .self_lower,
        .super_keyword,
        .type_keyword,
        .unsafe_keyword,
        .where_keyword,
    } },
    .{ .coarse = .{ .keyword = .@"return" }, .kinds = &.{.return_keyword} },
    .{ .coarse = .{ .keyword = .@"struct" }, .kinds = &.{
        .enum_keyword,
        .impl_keyword,
        .struct_keyword,
        .trait_keyword,
    } },
    .{ .coarse = .{ .punctuation = .ampersand }, .kinds = &.{.ampersand} },
    .{ .coarse = .{ .punctuation = .arrow }, .kinds = &.{.r_arrow} },
    .{ .coarse = .{ .punctuation = .assign }, .kinds = &.{.equal} },
    .{ .coarse = .{ .punctuation = .bang }, .kinds = &.{.bang} },
    .{ .coarse = .{ .punctuation = .bar_double }, .kinds = &.{.or_or} },
    .{ .coarse = .{ .punctuation = .bracket_close }, .kinds = &.{.bracket_close} },
    .{ .coarse = .{ .punctuation = .bracket_open }, .kinds = &.{.bracket_open} },
    .{ .coarse = .{ .punctuation = .colon }, .kinds = &.{ .colon, .colon_colon } },
    .{ .coarse = .{ .punctuation = .comma }, .kinds = &.{.comma} },
    .{ .coarse = .{ .punctuation = .dot }, .kinds = &.{
        .dot,
        .dot_dot,
        .dot_dot_dot,
        .dot_dot_equal,
    } },
    .{ .coarse = .{ .punctuation = .equal }, .kinds = &.{.equal_equal} },
    .{ .coarse = .{ .punctuation = .greater }, .kinds = &.{.greater} },
    .{ .coarse = .{ .punctuation = .greater_equal }, .kinds = &.{.greater_equal} },
    .{ .coarse = .{ .punctuation = .less }, .kinds = &.{.less} },
    .{ .coarse = .{ .punctuation = .less_equal }, .kinds = &.{.less_equal} },
    .{ .coarse = .{ .punctuation = .not_equal }, .kinds = &.{.bang_equal} },
    .{ .coarse = .{ .punctuation = .other }, .kinds = &.{
        .ampersand_equal,
        .at,
        .caret,
        .caret_equal,
        .dollar,
        .error_token,
        .fat_arrow,
        .greater_greater_equal,
        .less_less_equal,
        .minus,
        .minus_equal,
        .@"or",
        .or_equal,
        .percent,
        .percent_equal,
        .plus,
        .plus_equal,
        .pound,
        .question,
        .slash_equal,
        .star_equal,
        .tilde,
    } },
    .{ .coarse = .{ .punctuation = .paren_close }, .kinds = &.{.paren_close} },
    .{ .coarse = .{ .punctuation = .paren_open }, .kinds = &.{.paren_open} },
    .{ .coarse = .{ .punctuation = .semicolon }, .kinds = &.{.semicolon} },
    .{ .coarse = .{ .punctuation = .slash }, .kinds = &.{.slash} },
    .{ .coarse = .{ .punctuation = .star }, .kinds = &.{.star} },
};

const groups = [_]Group{
    .{ .category = .assignment, .kinds = &.{.expr_assign} },
    .{ .category = .attribute, .kinds = &.{ .attribute, .meta_list, .meta_name_value } },
    .{ .category = .block, .kinds = &.{
        .block,
        .expr_async,
        .expr_block,
        .expr_const,
        .expr_unsafe,
        .fields_named,
        .fields_unnamed,
        .item_foreign_mod,
        .item_mod,
    } },
    .{ .category = .branch, .kinds = &.{ .arm, .expr_if } },
    .{ .category = .call, .kinds = &.{
        .expr_call,
        .expr_macro,
        .expr_method_call,
        .foreign_item_macro,
        .impl_item_macro,
        .item_macro,
        .macro,
        .stmt_macro,
        .trait_item_macro,
    } },
    .{ .category = .condition, .kinds = &.{.expr_let} },
    .{ .category = .declaration, .kinds = &.{
        .assoc_const,
        .assoc_type,
        .field,
        .foreign_item_static,
        .foreign_item_type,
        .impl_item_const,
        .impl_item_type,
        .item_const,
        .item_static,
        .item_type,
        .local,
        .pat_type,
        .trait_item_const,
        .trait_item_type,
        .variant,
    } },
    .{ .category = .expression, .kinds = &.{
        .expr_array,
        .expr_await,
        .expr_binary,
        .expr_break,
        .expr_cast,
        .expr_continue,
        .expr_field,
        .expr_group,
        .expr_index,
        .expr_infer,
        .expr_paren,
        .expr_range,
        .expr_raw_addr,
        .expr_reference,
        .expr_repeat,
        .expr_struct,
        .expr_tuple,
        .expr_unary,
        .expr_yield,
        .field_pat,
        .field_value,
        .pat_or,
        .pat_paren,
        .pat_reference,
        .pat_rest,
        .pat_slice,
        .pat_struct,
        .pat_tuple,
        .pat_tuple_struct,
        .pat_wild,
        .precise_capture,
    } },
    .{ .category = .file, .kinds = &.{.file} },
    .{ .category = .function, .kinds = &.{
        .foreign_item_fn,
        .impl_item_fn,
        .item_fn,
        .trait_item_fn,
    } },
    .{ .category = .import, .kinds = &.{
        .item_extern_crate,
        .item_use,
        .use_glob,
        .use_group,
        .use_name,
        .use_path,
        .use_rename,
    } },
    .{ .category = .lambda, .kinds = &.{.expr_closure} },
    .{ .category = .loop, .kinds = &.{ .expr_for_loop, .expr_loop, .expr_while } },
    .{ .category = .match, .kinds = &.{.expr_match} },
    .{ .category = .name, .kinds = &.{
        .expr_path,
        .ident,
        .identifier,
        .label,
        .lifetime,
        .pat_ident,
        .path,
        .path_segment,
        .self_lower,
        .self_upper,
    } },
    .{ .category = .other, .kinds = &.{
        .ampersand,
        .ampersand_equal,
        .apostrophe,
        .as_keyword,
        .async_keyword,
        .at,
        .await_keyword,
        .bang,
        .bang_equal,
        .brace_close,
        .brace_open,
        .bracket_close,
        .bracket_open,
        .break_keyword,
        .caret,
        .caret_equal,
        .colon,
        .colon_colon,
        .comma,
        .comment,
        .const_keyword,
        .continue_keyword,
        .crate_keyword,
        .doc_comment,
        .dollar,
        .dot,
        .dot_dot,
        .dot_dot_dot,
        .dot_dot_equal,
        .dyn_keyword,
        .else_keyword,
        .enum_keyword,
        .equal,
        .equal_equal,
        .error_token,
        .extern_keyword,
        .fat_arrow,
        .fn_keyword,
        .for_keyword,
        .greater,
        .greater_equal,
        .greater_greater_equal,
        .if_keyword,
        .impl_keyword,
        .in_keyword,
        .less,
        .less_equal,
        .less_less_equal,
        .let_keyword,
        .loop_keyword,
        .macro_keyword,
        .match_keyword,
        .minus,
        .minus_equal,
        .mod_keyword,
        .move_keyword,
        .mut_keyword,
        .@"or",
        .or_equal,
        .or_or,
        .paren_close,
        .paren_open,
        .percent,
        .percent_equal,
        .plus,
        .plus_equal,
        .pound,
        .pub_keyword,
        .question,
        .r_arrow,
        .ref_keyword,
        .return_keyword,
        .semicolon,
        .slash,
        .slash_equal,
        .star,
        .star_equal,
        .static_keyword,
        .struct_keyword,
        .super_keyword,
        .tilde,
        .trait_keyword,
        .try_keyword,
        .type_keyword,
        .underscore,
        .union_keyword,
        .unsafe_keyword,
        .use_keyword,
        .where_keyword,
        .while_keyword,
        .yield_keyword,
        .abi,
        .error_node,
        .vis_restricted,
    } },
    .{ .category = .parameter, .kinds = &.{
        .bare_fn_arg,
        .bare_variadic,
        .const_param,
        .lifetime_param,
        .receiver,
        .type_param,
        .variadic,
    } },
    .{ .category = .parameters, .kinds = &.{ .generics, .signature } },
    .{ .category = .@"return", .kinds = &.{.expr_return} },
    .{ .category = .@"struct", .kinds = &.{
        .item_enum,
        .item_impl,
        .item_struct,
        .item_trait,
        .item_trait_alias,
        .item_union,
    } },
    .{ .category = .@"try", .kinds = &.{ .expr_try, .expr_try_block } },
    .{ .category = .type, .kinds = &.{
        .bound_lifetimes,
        .constraint,
        .predicate_lifetime,
        .predicate_type,
        .trait_bound,
        .type_array,
        .type_bare_fn,
        .type_group,
        .type_impl_trait,
        .type_infer,
        .type_macro,
        .type_never,
        .type_paren,
        .type_path,
        .type_ptr,
        .type_reference,
        .type_slice,
        .type_trait_object,
        .type_tuple,
        .where_clause,
    } },
    .{ .category = .value, .kinds = &.{
        .byte_literal,
        .byte_string_literal,
        .c_string_literal,
        .char_literal,
        .expr_lit,
        .false_keyword,
        .index,
        .lit_bool,
        .lit_byte,
        .lit_byte_str,
        .lit_c_str,
        .lit_char,
        .lit_float,
        .lit_int,
        .lit_str,
        .number,
        .string_literal,
        .true_keyword,
    } },
};

comptime {
    assert(@typeInfo(Kind).@"enum".field_names.len == kind_count);
    assert(@backingInt(Kind.yield_keyword) + 1 == node_first);
    assert(@backingInt(Kind.abi) == node_first);
    assert(@backingInt(Kind.where_clause) + 1 == kind_count);
}

fn coarse_of() std.enums.EnumArray(Kind, Token.Kind) {
    var held: std.enums.EnumArray(Kind, Token.Kind) = .initUndefined();
    var assigned: [node_first]bool = @splat(false);

    @setEvalBranchQuota(100_000);

    for (coarses) |group| {
        assert(group.kinds.len > 0);

        for (group.kinds) |kind| {
            assert(kind.is_token());
            assert(!assigned[@backingInt(kind)]);

            assigned[@backingInt(kind)] = true;
            held.set(kind, group.coarse);
        }
    }

    for (assigned) |named_kind| assert(named_kind);

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

    assert(held.get(.file) == .file);

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
