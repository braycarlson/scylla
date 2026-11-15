const std = @import("std");
const assert = std.debug.assert;
const Checkpoint = @import("../tree.zig").Checkpoint;
const Kind = @import("kind.zig").Kind;

pub const Variant = enum {
    argument,
    array,
    arrow,
    binary,
    object,
    pair,
    paren,
    subscript,
    substitution,
    template,
    ternary,
    top,
    unary,

    pub fn group_kind(variant: Variant) Kind {
        const result: Kind = switch (variant) {
            .array => .array,
            .object => .object,
            .paren => .parenthesized_expression,
            .subscript => .subscript_expression,
            .substitution => .template_substitution,
            .argument, .arrow, .binary, .pair, .template, .ternary, .top, .unary => .error_node,
        };

        assert(result.is_node());

        return result;
    }
};

pub const Frame = struct {
    bracket: ?Checkpoint,
    checkpoint: ?Checkpoint,
    closer: Kind,
    content: ?Checkpoint,
    element: ?Checkpoint,
    element_values: u32,
    elements: u32,
    kind: Kind,
    power: u8,
    spreads: bool,
    stage: u8,
    values: u32,
    variant: Variant,
    awaits: bool,

    pub const empty: Frame = .{
        .awaits = false,
        .bracket = null,
        .checkpoint = null,
        .closer = .error_token,
        .content = null,
        .element = null,
        .element_values = 0,
        .elements = 0,
        .kind = .error_node,
        .power = power_barrier,
        .spreads = false,
        .stage = 0,
        .values = 0,
        .variant = .top,
    };

    pub fn is_bracketed(frame: *const Frame) bool {
        assert(frame.kind.is_node());

        return switch (frame.variant) {
            .argument, .array, .object, .paren, .subscript, .substitution => true,
            .arrow, .binary, .pair, .template, .ternary, .top, .unary => false,
        };
    }

    pub fn is_group(frame: *const Frame) bool {
        assert(frame.kind.is_node());

        return switch (frame.variant) {
            .argument, .array, .object, .paren, .subscript, .substitution => true,
            .template, .top => true,
            .arrow, .binary, .pair, .ternary, .unary => false,
        };
    }
};

pub const Binding = struct {
    kind: Kind,
    left: u8,
    right: u8,
};

pub const depth_max: u32 = 256;
pub const value_count_max: u32 = 512;
pub const power_barrier: u8 = 0;
pub const power_spread: u8 = 2;
pub const power_yield: u8 = 4;
pub const power_arrow: u8 = 6;
const power_assign_left: u8 = 9;
pub const power_assign_right: u8 = 8;
pub const power_ternary_left: u8 = 11;
const power_nullish_left: u8 = 12;
const power_nullish_right: u8 = 13;
const power_or_left: u8 = 14;
const power_or_right: u8 = 15;
const power_and_left: u8 = 16;
const power_and_right: u8 = 17;
const power_bar_left: u8 = 18;
const power_bar_right: u8 = 19;
const power_caret_left: u8 = 20;
const power_caret_right: u8 = 21;
const power_ampersand_left: u8 = 22;
const power_ampersand_right: u8 = 23;
const power_equality_left: u8 = 24;
const power_equality_right: u8 = 25;
pub const power_relational_left: u8 = 26;
const power_relational_right: u8 = 27;
pub const power_shift_left: u8 = 28;
pub const power_shift_right: u8 = 29;
const power_additive_left: u8 = 30;
const power_additive_right: u8 = 31;
const power_multiplicative_left: u8 = 32;
const power_multiplicative_right: u8 = 33;
const power_power_left: u8 = 35;
const power_power_right: u8 = 34;
pub const power_unary: u8 = 36;
const additive = binding_of(.binary_expression, power_additive_left, power_additive_right);
const ampersand = binding_of(.binary_expression, power_ampersand_left, power_ampersand_right);
const assign = binding_of(.assignment_expression, power_assign_left, power_assign_right);

const augmented = binding_of(
    .augmented_assignment_expression,
    power_assign_left,
    power_assign_right,
);

const bar = binding_of(.binary_expression, power_bar_left, power_bar_right);
const boolean_and = binding_of(.binary_expression, power_and_left, power_and_right);
const boolean_or = binding_of(.binary_expression, power_or_left, power_or_right);
const caret = binding_of(.binary_expression, power_caret_left, power_caret_right);
const equality = binding_of(.binary_expression, power_equality_left, power_equality_right);
const exponent = binding_of(.binary_expression, power_power_left, power_power_right);

const multiplicative = binding_of(
    .binary_expression,
    power_multiplicative_left,
    power_multiplicative_right,
);

const nullish = binding_of(.binary_expression, power_nullish_left, power_nullish_right);

const relational = binding_of(
    .binary_expression,
    power_relational_left,
    power_relational_right,
);

const shift = binding_of(.binary_expression, power_shift_left, power_shift_right);

comptime {
    assert(power_barrier < power_spread);
    assert(power_assign_right < power_assign_left);
    assert(power_power_right < power_power_left);
    assert(power_multiplicative_right < power_unary);
    assert(value_count_max > depth_max);
}

fn binding_of(kind: Kind, left: u8, right: u8) Binding {
    assert(kind.is_node());
    assert(left > power_barrier);
    assert(right > power_barrier);

    return .{ .kind = kind, .left = left, .right = right };
}

pub fn closer_of(opener: Kind) Kind {
    assert(opener.is_token());

    const result: Kind = switch (opener) {
        .brace_open => .brace_close,
        .bracket_open => .bracket_close,
        else => .paren_close,
    };

    assert(result.is_token());

    return result;
}

pub fn infix_of(kind: Kind) ?Binding {
    assert(kind.is_token());

    const binding: Binding = switch (kind) {
        .ampersand => ampersand,
        .ampersand_ampersand => boolean_and,
        .bang_equal, .bang_equal_equal, .equal_equal, .equal_equal_equal => equality,
        .bar => bar,
        .bar_bar => boolean_or,
        .caret => caret,
        .equal => assign,
        .greater, .greater_equal, .in_keyword, .instanceof_keyword => relational,
        .less, .less_equal => relational,
        .greater_greater, .greater_greater_greater, .less_less => shift,
        .minus, .plus => additive,
        .percent, .slash, .star => multiplicative,
        .question_question => nullish,
        .star_star => exponent,
        .ampersand_ampersand_equal, .ampersand_equal, .bar_bar_equal, .bar_equal => augmented,
        .caret_equal, .greater_greater_equal, .greater_greater_greater_equal => augmented,
        .less_less_equal, .minus_equal, .percent_equal, .plus_equal => augmented,
        .question_question_equal, .slash_equal, .star_equal, .star_star_equal => augmented,
        else => return null,
    };

    assert(binding.kind.is_node());
    assert(binding.left > power_barrier);

    return binding;
}

pub fn is_prefix(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .bang, .delete_keyword, .minus, .plus, .tilde, .typeof_keyword, .void_keyword => true,
        else => false,
    };

    if (result) assert(kind.is_token());
    if (result) assert(!is_name(kind));

    return result;
}

pub fn is_literal(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .false_keyword, .null_keyword, .number, .regex, .string, .super_keyword => true,
        .this_keyword, .true_keyword, .undefined_keyword => true,
        else => false,
    };

    if (result) assert(kind.is_token());
    if (result) assert(!is_prefix(kind));

    return result;
}

pub fn literal_kind(kind: Kind) Kind {
    assert(kind.is_token());

    const result: Kind = switch (kind) {
        .false_keyword => .false,
        .null_keyword => .null,
        .number => .number_node,
        .regex => .regex_node,
        .super_keyword => .super,
        .this_keyword => .this,
        .true_keyword => .true,
        .undefined_keyword => .undefined,
        else => .string_node,
    };

    assert(result.is_node());

    return result;
}

pub fn is_name(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .async_keyword, .await_keyword, .identifier, .let_keyword, .of_keyword => true,
        .static_keyword, .undefined_keyword, .yield_keyword => true,
        else => false,
    };

    if (result) assert(kind.is_token());

    return result;
}

pub fn is_property_name(kind: Kind) bool {
    assert(kind.is_token());

    const result = is_name(kind) or is_word(kind);

    if (result) assert(kind.is_token());

    return result;
}

fn is_word(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .break_keyword, .case_keyword, .catch_keyword, .class_keyword, .const_keyword => true,
        .continue_keyword, .debugger_keyword, .default_keyword, .delete_keyword => true,
        .do_keyword, .else_keyword, .export_keyword, .extends_keyword, .false_keyword => true,
        .finally_keyword, .for_keyword, .function_keyword, .if_keyword, .import_keyword => true,
        .in_keyword, .instanceof_keyword, .new_keyword, .null_keyword, .return_keyword => true,
        .super_keyword, .switch_keyword, .this_keyword, .throw_keyword, .true_keyword => true,
        .try_keyword, .typeof_keyword, .var_keyword, .void_keyword, .while_keyword => true,
        .with_keyword => true,
        else => false,
    };

    if (result) assert(!is_name(kind));

    return result;
}

pub fn is_layout(kind: Kind) bool {
    assert(kind.is_token());

    const result = kind == .comment;

    if (result) assert(kind.is_trivia());

    return result;
}

pub fn ends_a_nullable(kind: Kind) bool {
    assert(kind.is_token());

    return switch (kind) {
        .ampersand, .bar, .brace_close, .bracket_close, .comma, .equal => true,
        .greater, .paren_close, .semicolon => true,
        else => false,
    };
}

pub fn is_opener(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .brace_open, .bracket_open, .paren_open, .substitution_start => true,
        else => false,
    };

    if (result) assert(kind.is_token());

    return result;
}

pub fn is_closer(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .brace_close, .bracket_close, .paren_close => true,
        else => false,
    };

    if (result) assert(!is_opener(kind));

    return result;
}

pub fn is_closer_of_list(kind: Kind) bool {
    assert(kind.is_token());

    const result = is_closer(kind) or kind == .greater;

    if (result) assert(kind.is_token());

    return result;
}

pub fn opener_of(closer: Kind) Kind {
    assert(is_closer_of_list(closer));

    const result: Kind = switch (closer) {
        .brace_close => .brace_open,
        .bracket_close => .bracket_open,
        .greater => .less,
        else => .paren_open,
    };

    assert(result.is_token());

    return result;
}

pub fn opens_an_expression(kind: Kind) bool {
    assert(kind.is_token());

    if (is_literal(kind)) return true;
    if (is_name(kind)) return true;
    if (is_prefix(kind)) return true;
    if (is_opener(kind)) return true;

    return switch (kind) {
        .at, .await_keyword, .class_keyword, .dot_dot_dot, .function_keyword => true,
        .import_keyword, .jsx_tag_start, .less, .minus_minus, .new_keyword => true,
        .plus_plus, .private_identifier, .slash, .template_start, .yield_keyword => true,
        else => false,
    };
}

pub fn is_type_token(kind: Kind) bool {
    assert(kind.is_token());

    const result = is_name(kind) or switch (kind) {
        .ampersand, .bar, .colon, .comma, .comment, .dot, .dot_dot_dot => true,
        .extends_keyword, .false_keyword, .identifier, .import_keyword, .minus => true,
        .new_keyword, .null_keyword, .number, .question, .star, .string => true,
        .template_chars, .template_end, .template_start, .this_keyword, .true_keyword => true,
        .typeof_keyword, .undefined_keyword, .void_keyword => true,
        else => false,
    };

    if (result) assert(kind.is_token());

    return result;
}

pub fn is_statement_word(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .break_keyword, .case_keyword, .catch_keyword, .const_keyword => true,
        .continue_keyword, .debugger_keyword, .default_keyword, .do_keyword => true,
        .else_keyword, .export_keyword, .finally_keyword, .for_keyword, .if_keyword => true,
        .return_keyword, .switch_keyword, .throw_keyword, .try_keyword, .var_keyword => true,
        .while_keyword, .with_keyword => true,
        else => false,
    };

    if (result) assert(!opens_an_expression(kind));

    return result;
}

pub fn is_literal_type(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .false_keyword, .null_keyword, .number, .string, .true_keyword => true,
        .undefined_keyword => true,
        else => false,
    };

    if (result) assert(is_literal(kind));

    return result;
}

pub fn ends_an_iteration_target(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .brace_close, .bracket_close, .paren_close => true,
        .await_keyword, .const_keyword, .delete_keyword, .in_keyword => false,
        .instanceof_keyword, .let_keyword, .new_keyword, .typeof_keyword => false,
        .var_keyword, .void_keyword, .yield_keyword => false,
        else => is_property_name(kind),
    };

    if (result) assert(kind.is_token());

    return result;
}

pub fn iterates_over(kind: ?Kind) bool {
    if (kind) |held| assert(held.is_token());

    const held = kind orelse return false;
    return held == .in_keyword or held == .of_keyword;
}

pub fn reaches(kind: ?Kind) bool {
    if (kind) |held| assert(held.is_token());

    const held = kind orelse return false;
    const result = held == .bracket_open or held == .dot or held == .question_dot;

    if (result) assert(held.is_token());

    return result;
}

pub fn declares(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .const_keyword, .let_keyword, .var_keyword => true,
        else => false,
    };

    if (result) assert(kind.is_token());

    return result;
}

pub fn opens_a_key(kind: Kind) bool {
    assert(kind.is_token());

    const result = is_property_name(kind) or switch (kind) {
        .bracket_open, .number, .private_identifier, .string => true,
        else => false,
    };

    if (result) assert(kind.is_token());

    return result;
}

pub fn ends_a_modifier(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .bang, .brace_close, .colon, .comma, .equal, .less, .paren_open, .semicolon => true,
        else => false,
    };

    if (result) assert(kind.is_token());

    return result;
}
