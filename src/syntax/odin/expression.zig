const std = @import("std");
const assert = std.debug.assert;
const Checkpoint = @import("../tree.zig").Checkpoint;
const Kind = @import("kind.zig").Kind;

pub const Variant = enum {
    binary,
    call,
    index,
    init,
    paren,
    top,
    unary,
};

pub const Frame = struct {
    bracket: ?Checkpoint,
    checkpoint: ?Checkpoint,
    closer: Kind,
    content: ?Checkpoint,
    element_values: u32,
    elements: u32,
    kind: Kind,
    power: u8,
    stage: u8,
    values: u32,
    variant: Variant,

    pub const empty: Frame = .{
        .bracket = null,
        .checkpoint = null,
        .closer = .error_token,
        .content = null,
        .element_values = 0,
        .elements = 0,
        .kind = .error_node,
        .power = power_barrier,
        .stage = 0,
        .values = 0,
        .variant = .top,
    };

    pub fn is_bracketed(frame: *const Frame) bool {
        assert(frame.kind.is_node());

        return switch (frame.variant) {
            .call, .index, .init, .paren => true,
            .binary, .top, .unary => false,
        };
    }

    pub fn is_group(frame: *const Frame) bool {
        assert(frame.kind.is_node());

        return switch (frame.variant) {
            .call, .index, .init, .paren, .top => true,
            .binary, .unary => false,
        };
    }
};

pub const Infix = struct {
    node: Kind,
    left: u8,
    right: u8,
};

pub const depth_max: u32 = 256;
pub const value_count_max: u32 = 512;
pub const power_barrier: u8 = 0;
const power_branch_left: u8 = 10;
const power_branch_right: u8 = 11;
const power_ternary_left: u8 = 10;
const power_ternary_right: u8 = 11;
const power_range_left: u8 = 12;
const power_range_right: u8 = 13;
const power_in_left: u8 = 13;
const power_in_right: u8 = 12;
const power_or_left: u8 = 14;
const power_or_right: u8 = 15;
const power_and_left: u8 = 16;
const power_and_right: u8 = 17;
const power_compare_left: u8 = 18;
const power_compare_right: u8 = 19;
const power_equality_left: u8 = 20;
const power_equality_right: u8 = 21;
const power_additive_left: u8 = 32;
const power_additive_right: u8 = 33;
const power_multiplicative_left: u8 = 34;
const power_multiplicative_right: u8 = 35;
pub const power_prefix: u8 = 38;
pub const power_trailer: u8 = 42;

const multiplicative: Infix = .{
    .node = .binary_expression,
    .left = power_multiplicative_left,
    .right = power_multiplicative_right,
};

comptime {
    assert(power_barrier < power_branch_left);
    assert(power_branch_left < power_branch_right);
    assert(power_in_left > power_in_right);
    assert(power_multiplicative_right < power_prefix);
    assert(power_prefix < power_trailer);
}

pub fn infix_of(kind: Kind) ?Infix {
    if (!kind.is_token()) return null;

    const held: Infix = switch (kind) {
        .ampersand, .ampersand_tilde, .greater_greater, .less_less => multiplicative,
        .percent, .percent_percent, .slash, .star => multiplicative,
        .ampersand_ampersand => .{
            .node = .binary_expression,
            .left = power_and_left,
            .right = power_and_right,
        },
        .bar, .minus, .plus, .tilde => .{
            .node = .binary_expression,
            .left = power_additive_left,
            .right = power_additive_right,
        },
        .bar_bar, .or_else_keyword => .{
            .node = .binary_expression,
            .left = power_or_left,
            .right = power_or_right,
        },
        .bang_equal, .equal_equal, .tilde_equal => .{
            .node = .binary_expression,
            .left = power_equality_left,
            .right = power_equality_right,
        },
        .greater, .greater_equal, .less, .less_equal => .{
            .node = .binary_expression,
            .left = power_compare_left,
            .right = power_compare_right,
        },
        .dot_dot_equal, .dot_dot_less => .{
            .node = .range_expression,
            .left = power_range_left,
            .right = power_range_right,
        },
        .if_keyword, .when_keyword => .{
            .node = .ternary_expression,
            .left = power_branch_left,
            .right = power_branch_right,
        },
        .question => .{
            .node = .ternary_expression,
            .left = power_ternary_left,
            .right = power_ternary_right,
        },
        .in_keyword, .not_in_keyword => .{
            .node = .in_expression,
            .left = power_in_left,
            .right = power_in_right,
        },
        else => return null,
    };

    assert(kind.is_token());

    assert(held.node.is_node());

    return held;
}

pub fn assignment_of(kind: Kind) ?Kind {
    if (!kind.is_token()) return null;

    const node: Kind = switch (kind) {
        .colon_equal, .equal => .assignment_statement,
        .ampersand_ampersand_equal,
        .ampersand_equal,
        .ampersand_tilde_equal,
        .bar_bar_equal,
        .bar_equal,
        .greater_greater_equal,
        .less_less_equal,
        .minus_equal,
        .percent_equal,
        .percent_percent_equal,
        .plus_equal,
        .slash_equal,
        .star_equal,
        => .update_statement,
        else => return null,
    };

    assert(kind.is_token());

    assert(node.category() == .assignment);

    return node;
}

pub fn is_prefix(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .ampersand, .ampersand_tilde, .bang, .minus, .plus, .tilde => true,
        else => false,
    };

    if (result) assert(assignment_of(kind) == null);

    return result;
}

pub fn literal_node(kind: Kind) ?Kind {
    assert(kind.is_token());

    const node: Kind = switch (kind) {
        .character => .character_node,
        .false_keyword, .true_keyword => .boolean,
        .float => .float_node,
        .nil_keyword => .nil,
        .number => .number_node,
        .text => .string,
        else => return null,
    };

    assert(node.category() == .value);

    return node;
}

pub fn is_universal(kind: Kind) bool {
    assert(kind.is_token());

    return switch (kind) {
        .false_keyword, .nil_keyword, .true_keyword => true,
        else => false,
    };
}

pub fn is_name(kind: Kind) bool {
    assert(kind.is_token());

    return switch (kind) {
        .context_keyword, .identifier, .typeid_keyword => true,
        else => false,
    };
}

pub fn opens_a_type(kind: Kind) bool {
    assert(kind.is_token());

    return switch (kind) {
        .bit_field_keyword,
        .bit_set_keyword,
        .bracket_open,
        .caret,
        .context_keyword,
        .directive,
        .distinct_keyword,
        .dollar,
        .dot_dot,
        .enum_keyword,
        .identifier,
        .map_keyword,
        .matrix_keyword,
        .paren_open,
        .proc_keyword,
        .struct_keyword,
        .typeid_keyword,
        .union_keyword,
        => true,
        else => false,
    };
}

test "an infix operator binds by its class and builds its node" {
    const plus = infix_of(.plus).?;
    const in = infix_of(.in_keyword).?;

    try std.testing.expectEqual(Kind.binary_expression, plus.node);
    try std.testing.expectEqual(power_additive_left, plus.left);
    try std.testing.expect(in.left > in.right);
    try std.testing.expectEqual(Kind.ternary_expression, infix_of(.when_keyword).?.node);
    try std.testing.expectEqual(Kind.range_expression, infix_of(.dot_dot_less).?.node);
    try std.testing.expectEqual(null, infix_of(.identifier));
}

test "assignments, prefixes and literals map tokens to nodes" {
    try std.testing.expectEqual(Kind.assignment_statement, assignment_of(.colon_equal).?);
    try std.testing.expectEqual(Kind.update_statement, assignment_of(.plus_equal).?);
    try std.testing.expectEqual(null, assignment_of(.equal_equal));
    try std.testing.expect(is_prefix(.ampersand_tilde));
    try std.testing.expect(!is_prefix(.caret));
    try std.testing.expectEqual(Kind.boolean, literal_node(.true_keyword).?);
    try std.testing.expectEqual(null, literal_node(.identifier));
    try std.testing.expect(opens_a_type(.dollar));
    try std.testing.expect(!Frame.empty.is_bracketed());
    try std.testing.expect(Frame.empty.is_group());
}
