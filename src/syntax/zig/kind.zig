const std = @import("std");
const assert = std.debug.assert;
const Category = @import("../category.zig").Category;
const Token = @import("../token.zig");
const diagnostic = @import("../diagnostic.zig");

pub const Kind = enum(u16) {
    addrspace_keyword,
    align_keyword,
    allowzero_keyword,
    ampersand,
    ampersand_equal,
    and_keyword,
    anyframe_keyword,
    anytype_keyword,
    arrow,
    asm_keyword,
    bang,
    bang_equal,
    brace_close,
    brace_open,
    bracket_close,
    bracket_open,
    break_keyword,
    builtin,
    callconv_keyword,
    caret,
    caret_equal,
    catch_keyword,
    character,
    colon,
    comma,
    comment,
    comptime_keyword,
    const_keyword,
    continue_keyword,
    defer_keyword,
    doc_comment,
    dot,
    dot_asterisk,
    dot_dot,
    dot_dot_dot,
    dot_question,
    else_keyword,
    enum_keyword,
    equal,
    equal_equal,
    errdefer_keyword,
    error_keyword,
    error_token,
    export_keyword,
    extern_keyword,
    fn_keyword,
    for_keyword,
    greater,
    greater_equal,
    greater_greater,
    greater_greater_equal,
    identifier,
    if_keyword,
    inline_keyword,
    less,
    less_equal,
    less_less,
    less_less_equal,
    less_less_pipe,
    less_less_pipe_equal,
    linksection_keyword,
    minus,
    minus_equal,
    minus_percent,
    minus_percent_equal,
    minus_pipe,
    minus_pipe_equal,
    noalias_keyword,
    noinline_keyword,
    nosuspend_keyword,
    number,
    opaque_keyword,
    or_keyword,
    orelse_keyword,
    packed_keyword,
    paren_close,
    paren_open,
    percent,
    percent_equal,
    pipe,
    pipe_equal,
    pipe_pipe,
    plus,
    plus_equal,
    plus_percent,
    plus_percent_equal,
    plus_pipe,
    plus_pipe_equal,
    plus_plus,
    pub_keyword,
    question,
    resume_keyword,
    return_keyword,
    semicolon,
    slash,
    slash_equal,
    star,
    star_equal,
    star_percent,
    star_percent_equal,
    star_pipe,
    star_pipe_equal,
    star_star,
    struct_keyword,
    suspend_keyword,
    switch_keyword,
    test_keyword,
    text,
    text_line,
    threadlocal_keyword,
    tilde,
    try_keyword,
    union_keyword,
    unreachable_keyword,
    var_keyword,
    volatile_keyword,
    while_keyword,
    add,
    add_sat,
    add_wrap,
    address_of,
    anyframe_literal,
    anyframe_type,
    array_access,
    array_cat,
    array_init,
    array_init_dot,
    array_mult,
    array_type,
    @"asm",
    asm_input,
    asm_output,
    assign,
    assign_add,
    assign_add_sat,
    assign_add_wrap,
    assign_bit_and,
    assign_bit_or,
    assign_bit_xor,
    assign_destructure,
    assign_div,
    assign_mod,
    assign_mul,
    assign_mul_sat,
    assign_mul_wrap,
    assign_shl,
    assign_shl_sat,
    assign_shr,
    assign_sub,
    assign_sub_sat,
    assign_sub_wrap,
    bang_equal_node,
    bit_and,
    bit_not,
    bit_or,
    bit_xor,
    block,
    bool_and,
    bool_not,
    bool_or,
    @"break",
    builtin_call,
    call,
    @"catch",
    char_literal,
    @"comptime",
    container_decl,
    container_field,
    @"continue",
    @"defer",
    deref,
    div,
    enum_literal,
    equal_equal_node,
    @"errdefer",
    error_node,
    error_set_decl,
    error_union,
    error_value,
    field_access,
    fn_decl,
    fn_proto,
    @"for",
    for_range,
    greater_or_equal,
    greater_than,
    grouped_expression,
    identifier_node,
    @"if",
    less_or_equal,
    less_than,
    merge_error_sets,
    mod,
    mul,
    mul_sat,
    mul_wrap,
    multiline_string_literal,
    negation,
    negation_wrap,
    @"nosuspend",
    number_literal,
    optional_type,
    @"orelse",
    ptr_type,
    @"resume",
    @"return",
    root,
    shl,
    shl_sat,
    shr,
    slice,
    string_literal,
    struct_init,
    struct_init_dot,
    sub,
    sub_sat,
    sub_wrap,
    @"suspend",
    @"switch",
    switch_case,
    switch_range,
    tagged_union,
    test_decl,
    @"try",
    unreachable_literal,
    unwrap_optional,
    var_decl,
    @"while",

    pub const Diagnostic = diagnostic.Diagnostic;

    pub fn category(kind: Kind) Category {
        const held = categories.get(kind);

        if (held == .file) assert(kind == .root);
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

    pub fn to_u16(kind: Kind) u16 {
        return @backingInt(kind);
    }

    pub fn token_kind(kind: Kind) Token.Kind {
        @setEvalBranchQuota(8_192);
        assert(kind.is_token());

        return switch (kind) {
            .builtin, .identifier => .identifier,
            .number => .number,
            .character, .text, .text_line => .string,
            .comment, .doc_comment => .comment,
            .brace_open => .block_start,
            .brace_close => .block_end,
            .error_token => .{ .punctuation = .other },
            inline else => |tag| if (comptime is_keyword(tag))
                keyword_kind(tag)
            else
                operator_kind(tag),
        };
    }
};

fn is_keyword(comptime kind: Kind) bool {
    return std.mem.endsWith(u8, @tagName(kind), "_keyword");
}

fn keyword_kind(kind: Kind) Token.Kind {
    assert(kind.is_token());

    return switch (kind) {
        .addrspace_keyword,
        .align_keyword,
        .allowzero_keyword,
        .anyframe_keyword,
        .anytype_keyword,
        .asm_keyword,
        .callconv_keyword,
        .comptime_keyword,
        .defer_keyword,
        .errdefer_keyword,
        .export_keyword,
        .extern_keyword,
        .inline_keyword,
        .linksection_keyword,
        .noalias_keyword,
        .noinline_keyword,
        .nosuspend_keyword,
        .orelse_keyword,
        .packed_keyword,
        .pub_keyword,
        .resume_keyword,
        .suspend_keyword,
        .test_keyword,
        .threadlocal_keyword,
        .volatile_keyword,
        => .{ .keyword = .other },
        .and_keyword => .{ .punctuation = .ampersand_double },
        .or_keyword => .{ .punctuation = .bar_double },
        .break_keyword => .{ .keyword = .@"break" },
        .catch_keyword => .{ .keyword = .except },
        .const_keyword => .{ .keyword = .constant },
        .continue_keyword => .{ .keyword = .@"continue" },
        .else_keyword => .{ .keyword = .branch_else },
        .enum_keyword, .error_keyword, .opaque_keyword, .struct_keyword, .union_keyword => .{
            .keyword = .@"struct",
        },
        .fn_keyword => .{ .keyword = .function },
        .for_keyword, .while_keyword => .{ .keyword = .loop },
        .if_keyword => .{ .keyword = .branch },
        .return_keyword => .{ .keyword = .@"return" },
        .switch_keyword => .{ .keyword = .match },
        .try_keyword => .{ .keyword = .@"try" },
        .unreachable_keyword => .{ .keyword = .assert },
        .var_keyword => .{ .keyword = .mutable },
        inline else => |other| {
            comptime assert(!is_keyword(other));

            unreachable;
        },
    };
}

fn operator_kind(kind: Kind) Token.Kind {
    assert(kind.is_token());

    return switch (kind) {
        .ampersand => .{ .punctuation = .ampersand },
        .bang => .{ .punctuation = .bang },
        .bang_equal => .{ .punctuation = .not_equal },
        .bracket_close => .{ .punctuation = .bracket_close },
        .bracket_open => .{ .punctuation = .bracket_open },
        .colon => .{ .punctuation = .colon },
        .comma => .{ .punctuation = .comma },
        .dot => .{ .punctuation = .dot },
        .equal => .{ .punctuation = .assign },
        .equal_equal => .{ .punctuation = .equal },
        .greater => .{ .punctuation = .greater },
        .greater_equal => .{ .punctuation = .greater_equal },
        .less => .{ .punctuation = .less },
        .less_equal => .{ .punctuation = .less_equal },
        .paren_close => .{ .punctuation = .paren_close },
        .paren_open => .{ .punctuation = .paren_open },
        .semicolon => .{ .punctuation = .semicolon },
        .slash => .{ .punctuation = .slash },
        .star => .{ .punctuation = .star },
        .dot_asterisk, .dot_dot, .dot_dot_dot, .dot_question => .{ .punctuation = .dot },
        .greater_greater => .{ .punctuation = .greater },
        .less_less, .less_less_pipe, .less_less_pipe_equal => .{ .punctuation = .less },
        .star_percent, .star_pipe, .star_star => .{ .punctuation = .star },
        .ampersand_equal,
        .arrow,
        .caret,
        .caret_equal,
        .greater_greater_equal,
        .less_less_equal,
        .minus,
        .minus_equal,
        .minus_percent,
        .minus_percent_equal,
        .minus_pipe,
        .minus_pipe_equal,
        .percent,
        .percent_equal,
        .pipe,
        .pipe_equal,
        .pipe_pipe,
        .plus,
        .plus_equal,
        .plus_percent,
        .plus_percent_equal,
        .plus_pipe,
        .plus_pipe_equal,
        .plus_plus,
        .question,
        .slash_equal,
        .star_equal,
        .star_percent_equal,
        .star_pipe_equal,
        .tilde,
        => .{ .punctuation = .other },
        .brace_close, .brace_open, .builtin, .character, .comment, .doc_comment => unreachable,
        .error_token, .identifier, .number, .text, .text_line => unreachable,
        inline else => |other| {
            comptime assert(@backingInt(other) >= node_first or is_keyword(other));

            unreachable;
        },
    };
}

const Group = struct {
    category: Category,
    kinds: []const Kind,
};

pub const kind_count: u16 = 228;
const node_first: u16 = 117;
const categories: std.enums.EnumArray(Kind, Category) = categories_of();

const groups = [_]Group{
    .{ .category = .assignment, .kinds = &.{
        .assign,
        .assign_add,
        .assign_add_sat,
        .assign_add_wrap,
        .assign_bit_and,
        .assign_bit_or,
        .assign_bit_xor,
        .assign_destructure,
        .assign_div,
        .assign_mod,
        .assign_mul,
        .assign_mul_sat,
        .assign_mul_wrap,
        .assign_shl,
        .assign_shl_sat,
        .assign_shr,
        .assign_sub,
        .assign_sub_sat,
        .assign_sub_wrap,
    } },
    .{ .category = .block, .kinds = &.{ .block, .@"comptime", .@"nosuspend", .@"suspend" } },
    .{ .category = .branch, .kinds = &.{ .@"if", .switch_case } },
    .{ .category = .call, .kinds = &.{ .builtin_call, .call } },
    .{ .category = .declaration, .kinds = &.{ .container_field, .var_decl } },
    .{ .category = .except, .kinds = &.{ .@"catch", .@"errdefer" } },
    .{ .category = .expression, .kinds = &.{
        .add,
        .add_sat,
        .add_wrap,
        .address_of,
        .array_access,
        .array_cat,
        .array_init,
        .array_init_dot,
        .array_mult,
        .@"asm",
        .asm_input,
        .asm_output,
        .bang_equal_node,
        .bit_and,
        .bit_not,
        .bit_or,
        .bit_xor,
        .bool_and,
        .bool_not,
        .bool_or,
        .@"defer",
        .deref,
        .div,
        .equal_equal_node,
        .error_value,
        .field_access,
        .for_range,
        .greater_or_equal,
        .greater_than,
        .grouped_expression,
        .less_or_equal,
        .less_than,
        .merge_error_sets,
        .mod,
        .mul,
        .mul_sat,
        .mul_wrap,
        .negation,
        .negation_wrap,
        .@"orelse",
        .@"resume",
        .shl,
        .shl_sat,
        .shr,
        .slice,
        .struct_init,
        .struct_init_dot,
        .sub,
        .sub_sat,
        .sub_wrap,
        .switch_range,
        .unwrap_optional,
    } },
    .{ .category = .file, .kinds = &.{.root} },
    .{ .category = .function, .kinds = &.{ .fn_decl, .test_decl } },
    .{ .category = .other, .kinds = &.{
        .addrspace_keyword,
        .align_keyword,
        .allowzero_keyword,
        .ampersand,
        .ampersand_equal,
        .and_keyword,
        .anyframe_keyword,
        .anytype_keyword,
        .arrow,
        .asm_keyword,
        .bang,
        .bang_equal,
        .brace_close,
        .brace_open,
        .bracket_close,
        .bracket_open,
        .break_keyword,
        .builtin,
        .callconv_keyword,
        .caret,
        .caret_equal,
        .catch_keyword,
        .colon,
        .comma,
        .comment,
        .comptime_keyword,
        .const_keyword,
        .continue_keyword,
        .defer_keyword,
        .doc_comment,
        .dot,
        .dot_asterisk,
        .dot_dot,
        .dot_dot_dot,
        .dot_question,
        .else_keyword,
        .enum_keyword,
        .equal,
        .equal_equal,
        .errdefer_keyword,
        .error_keyword,
        .error_token,
        .export_keyword,
        .extern_keyword,
        .fn_keyword,
        .for_keyword,
        .greater,
        .greater_equal,
        .greater_greater,
        .greater_greater_equal,
        .if_keyword,
        .inline_keyword,
        .less,
        .less_equal,
        .less_less,
        .less_less_equal,
        .less_less_pipe,
        .less_less_pipe_equal,
        .linksection_keyword,
        .minus,
        .minus_equal,
        .minus_percent,
        .minus_percent_equal,
        .minus_pipe,
        .minus_pipe_equal,
        .noalias_keyword,
        .noinline_keyword,
        .nosuspend_keyword,
        .opaque_keyword,
        .or_keyword,
        .orelse_keyword,
        .packed_keyword,
        .paren_close,
        .paren_open,
        .percent,
        .percent_equal,
        .pipe,
        .pipe_equal,
        .pipe_pipe,
        .plus,
        .plus_equal,
        .plus_percent,
        .plus_percent_equal,
        .plus_pipe,
        .plus_pipe_equal,
        .plus_plus,
        .pub_keyword,
        .question,
        .resume_keyword,
        .return_keyword,
        .semicolon,
        .slash,
        .slash_equal,
        .star,
        .star_equal,
        .star_percent,
        .star_percent_equal,
        .star_pipe,
        .star_pipe_equal,
        .star_star,
        .struct_keyword,
        .suspend_keyword,
        .switch_keyword,
        .test_keyword,
        .threadlocal_keyword,
        .tilde,
        .try_keyword,
        .union_keyword,
        .unreachable_keyword,
        .var_keyword,
        .volatile_keyword,
        .while_keyword,
        .@"break",
        .@"continue",
        .error_node,
    } },
    .{ .category = .parameters, .kinds = &.{.fn_proto} },
    .{ .category = .loop, .kinds = &.{ .@"for", .@"while" } },
    .{ .category = .match, .kinds = &.{.@"switch"} },
    .{ .category = .name, .kinds = &.{ .identifier, .identifier_node } },
    .{ .category = .@"return", .kinds = &.{.@"return"} },
    .{ .category = .@"struct", .kinds = &.{ .container_decl, .error_set_decl, .tagged_union } },
    .{ .category = .@"try", .kinds = &.{.@"try"} },
    .{ .category = .type, .kinds = &.{
        .anyframe_type,
        .array_type,
        .error_union,
        .optional_type,
        .ptr_type,
    } },
    .{ .category = .value, .kinds = &.{
        .anyframe_literal,
        .char_literal,
        .character,
        .enum_literal,
        .multiline_string_literal,
        .number,
        .number_literal,
        .string_literal,
        .text,
        .text_line,
        .unreachable_literal,
    } },
};

comptime {
    assert(@typeInfo(Kind).@"enum".field_names.len == kind_count);
    assert(@backingInt(Kind.while_keyword) + 1 == node_first);
    assert(@backingInt(Kind.add) == node_first);
    assert(@backingInt(Kind.@"while") + 1 == kind_count);
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

    assert(held.get(.root) == .file);

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
    try std.testing.expectEqualStrings("bang_equal_node", Kind.bang_equal_node.name());
    try std.testing.expectEqual(Kind.bang_equal_node, Kind.of_name("bang_equal_node").?);
    try std.testing.expectEqual(Category.other, Kind.error_node.category());
    try std.testing.expectEqual(Category.value, Kind.text_line.category());
    try std.testing.expectEqual(Category.name, Kind.identifier.category());
}
