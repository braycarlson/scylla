const std = @import("std");
const assert = std.debug.assert;
const Checkpoint = @import("../tree.zig").Checkpoint;
const Kind = @import("kind.zig").Kind;

pub const Variant = enum {
    array,
    binary,
    call,
    group,
    paren,
    @"struct",
    subscript,
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

    pub fn is_group(frame: *const Frame) bool {
        const result = switch (frame.variant) {
            .array, .call, .group, .paren, .@"struct", .subscript, .top => true,
            .binary, .unary => false,
        };

        if (frame.is_bracketed()) assert(result);
        if (result) assert(frame.power == power_barrier);

        return result;
    }

    pub fn is_bracketed(frame: *const Frame) bool {
        const result = switch (frame.variant) {
            .array, .call, .paren, .@"struct", .subscript => true,
            .binary, .group, .top, .unary => false,
        };

        if (result) assert(frame.closer != .error_token);

        return result;
    }
};

const Infix = struct {
    node: Kind,
    left: u8,
    right: u8,
};

pub const depth_max: u32 = 256;
pub const value_count_max: u32 = 512;
pub const power_barrier: u8 = 0;
pub const power_assign_left: u8 = 5;
pub const power_assign_right: u8 = 4;
pub const power_range_left: u8 = 6;
pub const power_range_right: u8 = 7;
const power_or_left: u8 = 8;
const power_or_right: u8 = 9;
pub const power_and_left: u8 = 10;
pub const power_and_right: u8 = 11;
pub const power_compare_left: u8 = 12;
const power_compare_right: u8 = 13;
const power_bar_left: u8 = 14;
const power_bar_right: u8 = 15;
const power_caret_left: u8 = 16;
const power_caret_right: u8 = 17;
const power_ampersand_left: u8 = 18;
const power_ampersand_right: u8 = 19;
pub const power_shift_left: u8 = 20;
pub const power_shift_right: u8 = 21;
const power_additive_left: u8 = 22;
const power_additive_right: u8 = 23;
const power_multiplicative_left: u8 = 24;
const power_multiplicative_right: u8 = 25;
pub const power_cast: u8 = 26;
pub const power_unary: u8 = 28;

comptime {
    assert(power_assign_right < power_assign_left);
    assert(power_range_left < power_range_right);
    assert(power_cast < power_unary);
    assert(value_count_max > depth_max);
}

pub fn infix_of(kind: Kind) ?Infix {
    assert(kind.is_token());

    const assign: Infix = .{
        .node = .expr_binary,
        .left = power_assign_left,
        .right = power_assign_right,
    };

    const infix: ?Infix = switch (kind) {
        .ampersand => binary_of(power_ampersand_left, power_ampersand_right),
        .bang_equal, .equal_equal => binary_of(power_compare_left, power_compare_right),
        .caret => binary_of(power_caret_left, power_caret_right),
        .@"or" => binary_of(power_bar_left, power_bar_right),
        .or_or => binary_of(power_or_left, power_or_right),
        .minus, .plus => binary_of(power_additive_left, power_additive_right),
        .percent, .slash, .star => binary_of(power_multiplicative_left, power_multiplicative_right),
        .equal => .{ .node = .expr_assign, .left = power_assign_left, .right = power_assign_right },
        .ampersand_equal,
        .caret_equal,
        .minus_equal,
        .or_equal,
        .percent_equal,
        .plus_equal,
        .slash_equal,
        .star_equal,
        => assign,
        else => null,
    };

    if (infix) |held| assert(held.left > power_barrier);

    return infix;
}

fn binary_of(left: u8, right: u8) Infix {
    assert(left > power_barrier);
    assert(right == left + 1);

    return .{ .node = .expr_binary, .left = left, .right = right };
}

pub fn literal_kind(kind: Kind) ?Kind {
    assert(kind.is_token());

    const literal: ?Kind = switch (kind) {
        .byte_literal => .lit_byte,
        .byte_string_literal => .lit_byte_str,
        .c_string_literal => .lit_c_str,
        .char_literal => .lit_char,
        .false_keyword, .true_keyword => .lit_bool,
        .number => .lit_int,
        .string_literal => .lit_str,
        else => null,
    };

    if (literal) |held| assert(held.is_node());

    return literal;
}

pub fn is_literal(kind: Kind) bool {
    assert(kind.is_token());

    return literal_kind(kind) != null;
}

pub fn opens_a_path(kind: Kind) bool {
    assert(kind.is_token());

    return switch (kind) {
        .colon_colon,
        .crate_keyword,
        .identifier,
        .macro_keyword,
        .self_lower,
        .self_upper,
        .super_keyword,
        .try_keyword,
        .union_keyword,
        => true,
        else => false,
    };
}
