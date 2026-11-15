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
    arrow,
    async_keyword,
    at,
    await_keyword,
    bang,
    bang_equal,
    bang_equal_equal,
    bar,
    bar_bar,
    bar_bar_equal,
    bar_equal,
    brace_close,
    brace_open,
    bracket_close,
    bracket_open,
    break_keyword,
    caret,
    caret_equal,
    case_keyword,
    catch_keyword,
    class_keyword,
    colon,
    comma,
    comment,
    const_keyword,
    continue_keyword,
    debugger_keyword,
    default_keyword,
    delete_keyword,
    do_keyword,
    dot,
    dot_dot_dot,
    else_keyword,
    equal,
    equal_equal,
    equal_equal_equal,
    error_token,
    export_keyword,
    extends_keyword,
    false_keyword,
    finally_keyword,
    for_keyword,
    function_keyword,
    greater,
    greater_equal,
    greater_greater,
    greater_greater_equal,
    greater_greater_greater,
    greater_greater_greater_equal,
    identifier,
    if_keyword,
    import_keyword,
    in_keyword,
    instanceof_keyword,
    jsx_chars,
    jsx_entity,
    jsx_tag_end,
    jsx_tag_end_self,
    jsx_tag_start,
    jsx_tag_start_close,
    less,
    less_equal,
    less_less,
    less_less_equal,
    let_keyword,
    minus,
    minus_equal,
    minus_minus,
    new_keyword,
    null_keyword,
    number,
    of_keyword,
    paren_close,
    paren_open,
    percent,
    percent_equal,
    plus,
    plus_equal,
    plus_plus,
    private_identifier,
    question,
    question_dot,
    question_question,
    question_question_equal,
    regex,
    return_keyword,
    semicolon,
    slash,
    slash_equal,
    star,
    star_equal,
    star_star,
    star_star_equal,
    static_keyword,
    string,
    substitution_start,
    super_keyword,
    switch_keyword,
    template_chars,
    template_end,
    template_start,
    this_keyword,
    throw_keyword,
    tilde,
    true_keyword,
    try_keyword,
    typeof_keyword,
    undefined_keyword,
    var_keyword,
    void_keyword,
    while_keyword,
    with_keyword,
    yield_keyword,
    abstract_class_declaration,
    abstract_method_signature,
    accessibility_modifier,
    adding_type_annotation,
    ambient_declaration,
    arguments,
    array,
    array_pattern,
    array_type,
    arrow_function,
    as_expression,
    asserts,
    asserts_annotation,
    assignment_expression,
    assignment_pattern,
    augmented_assignment_expression,
    await_expression,
    binary_expression,
    break_statement,
    call_expression,
    call_signature,
    catch_clause,
    class,
    class_body,
    class_declaration,
    class_heritage,
    class_static_block,
    computed_property_name,
    conditional_type,
    constraint,
    construct_signature,
    constructor_type,
    continue_statement,
    debugger_statement,
    decorator,
    default_type,
    do_statement,
    else_clause,
    empty_statement,
    enum_assignment,
    enum_body,
    enum_declaration,
    error_node,
    existential_type,
    export_clause,
    export_specifier,
    export_statement,
    expression_statement,
    extends_clause,
    extends_type_clause,
    false,
    field_definition,
    finally_clause,
    flow_maybe_type,
    for_in_statement,
    for_statement,
    formal_parameters,
    function_declaration,
    function_expression,
    function_signature,
    function_type,
    generator_function,
    generator_function_declaration,
    generic_type,
    identifier_node,
    if_statement,
    implements_clause,
    import_node,
    import_alias,
    import_attribute,
    import_clause,
    import_require_clause,
    import_specifier,
    import_statement,
    index_signature,
    index_type_query,
    infer_type,
    instantiation_expression,
    interface_body,
    interface_declaration,
    internal_module,
    intersection_type,
    jsx_attribute,
    jsx_closing_element,
    jsx_element,
    jsx_expression,
    jsx_namespace_name,
    jsx_opening_element,
    jsx_self_closing_element,
    jsx_text,
    labeled_statement,
    lexical_declaration,
    literal_type,
    lookup_type,
    mapped_type_clause,
    member_expression,
    meta_property,
    method_definition,
    method_signature,
    module,
    named_imports,
    namespace_export,
    namespace_import,
    nested_identifier,
    nested_type_identifier,
    new_expression,
    non_null_expression,
    null,
    number_node,
    object,
    object_assignment_pattern,
    object_pattern,
    object_type,
    omitting_type_annotation,
    opting_type_annotation,
    optional_chain,
    optional_parameter,
    optional_type,
    override_modifier,
    pair,
    pair_pattern,
    parenthesized_expression,
    parenthesized_type,
    predefined_type,
    private_property_identifier,
    program,
    property_identifier,
    property_signature,
    public_field_definition,
    readonly_type,
    regex_node,
    required_parameter,
    rest_pattern,
    rest_type,
    return_statement,
    satisfies_expression,
    sequence_expression,
    shorthand_property_identifier,
    shorthand_property_identifier_pattern,
    spread_element,
    statement_block,
    statement_identifier,
    string_node,
    subscript_expression,
    super,
    switch_body,
    switch_case,
    switch_default,
    switch_statement,
    template_literal_type,
    template_string,
    template_substitution,
    template_type,
    ternary_expression,
    this,
    this_type,
    throw_statement,
    true,
    try_statement,
    tuple_type,
    type_alias_declaration,
    type_annotation,
    type_arguments,
    type_assertion,
    type_identifier,
    type_parameter,
    type_parameters,
    type_predicate,
    type_predicate_annotation,
    type_query,
    unary_expression,
    undefined,
    union_type,
    update_expression,
    variable_declaration,
    variable_declarator,
    while_statement,
    with_statement,
    yield_expression,

    pub const Diagnostic = diagnostic.Diagnostic;

    pub fn category(kind: Kind) Category {
        const held = categories.get(kind);

        if (held == .file) assert(kind == .program);
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

        const held = token_kinds.get(kind);

        if (kind == .error_token) assert(held == .punctuation);
        if (kind == .identifier) assert(held == .identifier);
        if (kind == .brace_open) assert(held == .block_start);

        return held;
    }
};

const Projection = struct {
    coarse: Token.Kind,
    kinds: []const Kind,
};

const Group = struct {
    category: Category,
    kinds: []const Kind,
};

pub const kind_count: u16 = 296;
const node_first: u16 = 117;
const categories: std.enums.EnumArray(Kind, Category) = categories_of();
const token_kinds: std.enums.EnumArray(Kind, Token.Kind) = token_kinds_of();

const groups = [_]Group{
    .{ .category = .assignment, .kinds = &.{
        .assignment_expression,
        .augmented_assignment_expression,
    } },
    .{ .category = .attribute, .kinds = &.{.decorator} },
    .{ .category = .block, .kinds = &.{
        .class_body,
        .class_static_block,
        .else_clause,
        .enum_body,
        .finally_clause,
        .interface_body,
        .internal_module,
        .module,
        .statement_block,
        .switch_body,
        .with_statement,
    } },
    .{ .category = .branch, .kinds = &.{
        .if_statement,
        .switch_case,
        .switch_default,
        .ternary_expression,
    } },
    .{ .category = .call, .kinds = &.{ .call_expression, .new_expression } },
    .{ .category = .declaration, .kinds = &.{
        .ambient_declaration,
        .enum_assignment,
        .field_definition,
        .index_signature,
        .lexical_declaration,
        .property_signature,
        .public_field_definition,
        .type_alias_declaration,
        .variable_declaration,
        .variable_declarator,
    } },
    .{ .category = .except, .kinds = &.{.catch_clause} },
    .{ .category = .expression, .kinds = &.{
        .arguments,
        .array,
        .array_pattern,
        .as_expression,
        .assignment_pattern,
        .await_expression,
        .binary_expression,
        .computed_property_name,
        .expression_statement,
        .instantiation_expression,
        .jsx_attribute,
        .jsx_closing_element,
        .jsx_element,
        .jsx_expression,
        .jsx_namespace_name,
        .jsx_opening_element,
        .jsx_self_closing_element,
        .jsx_text,
        .member_expression,
        .meta_property,
        .non_null_expression,
        .object,
        .object_assignment_pattern,
        .object_pattern,
        .optional_chain,
        .pair,
        .pair_pattern,
        .parenthesized_expression,
        .rest_pattern,
        .satisfies_expression,
        .sequence_expression,
        .spread_element,
        .subscript_expression,
        .super,
        .template_string,
        .template_substitution,
        .this,
        .throw_statement,
        .type_assertion,
        .unary_expression,
        .update_expression,
        .yield_expression,
    } },
    .{ .category = .file, .kinds = &.{.program} },
    .{ .category = .function, .kinds = &.{
        .abstract_method_signature,
        .call_signature,
        .construct_signature,
        .function_declaration,
        .function_expression,
        .function_signature,
        .generator_function,
        .generator_function_declaration,
        .method_definition,
        .method_signature,
    } },
    .{ .category = .import, .kinds = &.{
        .export_clause,
        .export_specifier,
        .export_statement,
        .import_alias,
        .import_attribute,
        .import_clause,
        .import_node,
        .import_require_clause,
        .import_specifier,
        .import_statement,
        .named_imports,
        .namespace_export,
        .namespace_import,
    } },
    .{ .category = .lambda, .kinds = &.{.arrow_function} },
    .{ .category = .loop, .kinds = &.{
        .do_statement,
        .for_in_statement,
        .for_statement,
        .while_statement,
    } },
    .{ .category = .match, .kinds = &.{.switch_statement} },
    .{ .category = .name, .kinds = &.{
        .identifier,
        .identifier_node,
        .nested_identifier,
        .private_identifier,
        .private_property_identifier,
        .property_identifier,
        .shorthand_property_identifier,
        .shorthand_property_identifier_pattern,
        .statement_identifier,
    } },
    .{ .category = .other, .kinds = &.{
        .ampersand,
        .ampersand_ampersand,
        .ampersand_ampersand_equal,
        .ampersand_equal,
        .arrow,
        .async_keyword,
        .at,
        .await_keyword,
        .bang,
        .bang_equal,
        .bang_equal_equal,
        .bar,
        .bar_bar,
        .bar_bar_equal,
        .bar_equal,
        .brace_close,
        .brace_open,
        .bracket_close,
        .bracket_open,
        .break_keyword,
        .caret,
        .caret_equal,
        .case_keyword,
        .catch_keyword,
        .class_keyword,
        .colon,
        .comma,
        .comment,
        .const_keyword,
        .continue_keyword,
        .debugger_keyword,
        .default_keyword,
        .delete_keyword,
        .do_keyword,
        .dot,
        .dot_dot_dot,
        .else_keyword,
        .equal,
        .equal_equal,
        .equal_equal_equal,
        .error_token,
        .export_keyword,
        .extends_keyword,
        .finally_keyword,
        .for_keyword,
        .function_keyword,
        .greater,
        .greater_equal,
        .greater_greater,
        .greater_greater_equal,
        .greater_greater_greater,
        .greater_greater_greater_equal,
        .if_keyword,
        .import_keyword,
        .in_keyword,
        .instanceof_keyword,
        .jsx_chars,
        .jsx_entity,
        .jsx_tag_end,
        .jsx_tag_end_self,
        .jsx_tag_start,
        .jsx_tag_start_close,
        .less,
        .less_equal,
        .less_less,
        .less_less_equal,
        .let_keyword,
        .minus,
        .minus_equal,
        .minus_minus,
        .new_keyword,
        .of_keyword,
        .paren_close,
        .paren_open,
        .percent,
        .percent_equal,
        .plus,
        .plus_equal,
        .plus_plus,
        .question,
        .question_dot,
        .question_question,
        .question_question_equal,
        .return_keyword,
        .semicolon,
        .slash,
        .slash_equal,
        .star,
        .star_equal,
        .star_star,
        .star_star_equal,
        .static_keyword,
        .substitution_start,
        .super_keyword,
        .switch_keyword,
        .template_chars,
        .template_end,
        .template_start,
        .this_keyword,
        .throw_keyword,
        .tilde,
        .try_keyword,
        .typeof_keyword,
        .var_keyword,
        .void_keyword,
        .while_keyword,
        .with_keyword,
        .yield_keyword,
        .accessibility_modifier,
        .break_statement,
        .continue_statement,
        .debugger_statement,
        .empty_statement,
        .error_node,
        .labeled_statement,
        .override_modifier,
    } },
    .{ .category = .parameter, .kinds = &.{
        .optional_parameter,
        .required_parameter,
        .type_parameter,
    } },
    .{ .category = .parameters, .kinds = &.{ .formal_parameters, .type_parameters } },
    .{ .category = .@"return", .kinds = &.{.return_statement} },
    .{ .category = .@"struct", .kinds = &.{
        .abstract_class_declaration,
        .class,
        .class_declaration,
        .class_heritage,
        .enum_declaration,
        .extends_clause,
        .extends_type_clause,
        .implements_clause,
        .interface_declaration,
    } },
    .{ .category = .@"try", .kinds = &.{.try_statement} },
    .{ .category = .type, .kinds = &.{
        .adding_type_annotation,
        .array_type,
        .asserts,
        .asserts_annotation,
        .conditional_type,
        .constraint,
        .constructor_type,
        .default_type,
        .existential_type,
        .flow_maybe_type,
        .function_type,
        .generic_type,
        .index_type_query,
        .infer_type,
        .intersection_type,
        .literal_type,
        .lookup_type,
        .mapped_type_clause,
        .nested_type_identifier,
        .object_type,
        .omitting_type_annotation,
        .opting_type_annotation,
        .optional_type,
        .parenthesized_type,
        .predefined_type,
        .readonly_type,
        .rest_type,
        .template_literal_type,
        .template_type,
        .this_type,
        .tuple_type,
        .type_annotation,
        .type_arguments,
        .type_identifier,
        .type_predicate,
        .type_predicate_annotation,
        .type_query,
        .union_type,
    } },
    .{ .category = .value, .kinds = &.{
        .false,
        .false_keyword,
        .null,
        .null_keyword,
        .number,
        .number_node,
        .regex,
        .regex_node,
        .string,
        .string_node,
        .true,
        .true_keyword,
        .undefined,
        .undefined_keyword,
    } },
};

comptime {
    assert(@typeInfo(Kind).@"enum".field_names.len == kind_count);
    assert(@backingInt(Kind.yield_keyword) + 1 == node_first);
    assert(@backingInt(Kind.abstract_class_declaration) == node_first);
    assert(@backingInt(Kind.yield_expression) + 1 == kind_count);
}

const projections = [_]Projection{
    .{ .coarse = .block_end, .kinds = &.{.brace_close} },
    .{ .coarse = .block_start, .kinds = &.{.brace_open} },
    .{ .coarse = .comment, .kinds = &.{.comment} },
    .{ .coarse = .identifier, .kinds = &.{
        .false_keyword,
        .identifier,
        .null_keyword,
        .private_identifier,
        .true_keyword,
        .undefined_keyword,
    } },
    .{ .coarse = .number, .kinds = &.{.number} },
    .{ .coarse = .string, .kinds = &.{
        .jsx_chars,
        .jsx_entity,
        .regex,
        .string,
        .substitution_start,
        .template_chars,
        .template_end,
        .template_start,
    } },
    .{ .coarse = .{ .keyword = .@"break" }, .kinds = &.{.break_keyword} },
    .{ .coarse = .{ .keyword = .@"continue" }, .kinds = &.{.continue_keyword} },
    .{ .coarse = .{ .keyword = .@"return" }, .kinds = &.{.return_keyword} },
    .{ .coarse = .{ .keyword = .@"struct" }, .kinds = &.{.class_keyword} },
    .{ .coarse = .{ .keyword = .@"try" }, .kinds = &.{.try_keyword} },
    .{ .coarse = .{ .keyword = .branch }, .kinds = &.{.if_keyword} },
    .{ .coarse = .{ .keyword = .branch_else }, .kinds = &.{.else_keyword} },
    .{ .coarse = .{ .keyword = .constant }, .kinds = &.{.const_keyword} },
    .{ .coarse = .{ .keyword = .except }, .kinds = &.{.catch_keyword} },
    .{ .coarse = .{ .keyword = .function }, .kinds = &.{.function_keyword} },
    .{ .coarse = .{ .keyword = .import }, .kinds = &.{ .export_keyword, .import_keyword } },
    .{ .coarse = .{ .keyword = .loop }, .kinds = &.{ .do_keyword, .for_keyword, .while_keyword } },
    .{ .coarse = .{ .keyword = .match }, .kinds = &.{ .case_keyword, .switch_keyword } },
    .{ .coarse = .{ .keyword = .mutable }, .kinds = &.{ .let_keyword, .var_keyword } },
    .{ .coarse = .{ .keyword = .other }, .kinds = &.{
        .async_keyword,
        .await_keyword,
        .debugger_keyword,
        .default_keyword,
        .delete_keyword,
        .extends_keyword,
        .finally_keyword,
        .in_keyword,
        .instanceof_keyword,
        .new_keyword,
        .of_keyword,
        .static_keyword,
        .super_keyword,
        .this_keyword,
        .throw_keyword,
        .typeof_keyword,
        .void_keyword,
        .with_keyword,
        .yield_keyword,
    } },
    .{ .coarse = .{ .punctuation = .ampersand }, .kinds = &.{.ampersand} },
    .{ .coarse = .{ .punctuation = .ampersand_double }, .kinds = &.{
        .ampersand_ampersand,
        .ampersand_ampersand_equal,
    } },
    .{ .coarse = .{ .punctuation = .bang }, .kinds = &.{.bang} },
    .{ .coarse = .{ .punctuation = .bar_double }, .kinds = &.{ .bar_bar, .bar_bar_equal } },
    .{ .coarse = .{ .punctuation = .bracket_close }, .kinds = &.{.bracket_close} },
    .{ .coarse = .{ .punctuation = .bracket_open }, .kinds = &.{.bracket_open} },
    .{ .coarse = .{ .punctuation = .colon }, .kinds = &.{.colon} },
    .{ .coarse = .{ .punctuation = .comma }, .kinds = &.{.comma} },
    .{ .coarse = .{ .punctuation = .dot }, .kinds = &.{.dot} },
    .{ .coarse = .{ .punctuation = .assign }, .kinds = &.{.equal} },
    .{ .coarse = .{ .punctuation = .equal }, .kinds = &.{ .equal_equal, .equal_equal_equal } },
    .{ .coarse = .{ .punctuation = .greater }, .kinds = &.{
        .greater,
        .greater_greater,
        .greater_greater_greater,
        .greater_greater_greater_equal,
        .jsx_tag_end,
    } },
    .{ .coarse = .{ .punctuation = .greater_equal }, .kinds = &.{.greater_equal} },
    .{ .coarse = .{ .punctuation = .less }, .kinds = &.{
        .jsx_tag_start,
        .jsx_tag_start_close,
        .less,
        .less_less,
    } },
    .{ .coarse = .{ .punctuation = .less_equal }, .kinds = &.{.less_equal} },
    .{ .coarse = .{ .punctuation = .not_equal }, .kinds = &.{ .bang_equal, .bang_equal_equal } },
    .{ .coarse = .{ .punctuation = .other }, .kinds = &.{
        .ampersand_equal,
        .arrow,
        .at,
        .bar,
        .bar_equal,
        .caret,
        .caret_equal,
        .dot_dot_dot,
        .error_token,
        .greater_greater_equal,
        .jsx_tag_end_self,
        .less_less_equal,
        .minus,
        .minus_equal,
        .minus_minus,
        .percent,
        .percent_equal,
        .plus,
        .plus_equal,
        .plus_plus,
        .question,
        .question_dot,
        .question_question,
        .question_question_equal,
        .slash_equal,
        .star_equal,
        .star_star_equal,
        .tilde,
    } },
    .{ .coarse = .{ .punctuation = .paren_close }, .kinds = &.{.paren_close} },
    .{ .coarse = .{ .punctuation = .paren_open }, .kinds = &.{.paren_open} },
    .{ .coarse = .{ .punctuation = .semicolon }, .kinds = &.{.semicolon} },
    .{ .coarse = .{ .punctuation = .slash }, .kinds = &.{.slash} },
    .{ .coarse = .{ .punctuation = .star }, .kinds = &.{ .star, .star_star } },
};

fn token_kinds_of() std.enums.EnumArray(Kind, Token.Kind) {
    var held: std.enums.EnumArray(Kind, Token.Kind) = .initUndefined();
    var assigned: [kind_count]bool = @splat(false);

    @setEvalBranchQuota(200_000);

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

    assert(held.get(.template_start) == .string);

    return held;
}

fn categories_of() std.enums.EnumArray(Kind, Category) {
    var held: std.enums.EnumArray(Kind, Category) = .initUndefined();
    var assigned: [kind_count]bool = @splat(false);

    @setEvalBranchQuota(200_000);

    for (groups) |group| {
        assert(group.kinds.len > 0);

        for (group.kinds) |kind| {
            assert(!assigned[@backingInt(kind)]);

            assigned[@backingInt(kind)] = true;
            held.set(kind, group.category);
        }
    }

    for (assigned) |named_kind| assert(named_kind);

    assert(held.get(.program) == .file);

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
