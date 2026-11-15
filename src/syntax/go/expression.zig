const std = @import("std");
const assert = std.debug.assert;
const Checkpoint = @import("../tree.zig").Checkpoint;
const Kind = @import("kind.zig").Kind;

pub const Variant = enum {
    binary,
    call,
    composite,
    index,
    paren,
    top,
    unary,
};

pub const Frame = struct {
    checkpoint: ?Checkpoint,
    closer: Kind,
    elements: u32,
    kind: Kind,
    power: u8,
    stage: u8,
    values: u32,
    variant: Variant,

    pub const empty: Frame = .{
        .checkpoint = null,
        .closer = .error_token,
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
            .call, .composite, .index, .paren => true,
            .binary, .top, .unary => false,
        };
    }

    pub fn is_group(frame: *const Frame) bool {
        assert(frame.kind.is_node());

        return switch (frame.variant) {
            .call, .composite, .index, .paren, .top => true,
            .binary, .unary => false,
        };
    }
};

pub const Binding = struct {
    left: u8,
    right: u8,
};

pub const depth_max: u32 = 256;
pub const value_count_max: u32 = 512;
pub const power_barrier: u8 = 0;
const power_or_left: u8 = 2;
const power_or_right: u8 = 3;
const power_and_left: u8 = 4;
const power_and_right: u8 = 5;
const power_compare_left: u8 = 6;
const power_compare_right: u8 = 7;
const power_additive_left: u8 = 8;
const power_additive_right: u8 = 9;
const power_multiplicative_left: u8 = 10;
const power_multiplicative_right: u8 = 11;
pub const power_unary: u8 = 14;
const additive: Binding = .{ .left = power_additive_left, .right = power_additive_right };
const boolean_and: Binding = .{ .left = power_and_left, .right = power_and_right };
const boolean_or: Binding = .{ .left = power_or_left, .right = power_or_right };
const compare: Binding = .{ .left = power_compare_left, .right = power_compare_right };

const multiplicative: Binding = .{
    .left = power_multiplicative_left,
    .right = power_multiplicative_right,
};

comptime {
    assert(power_barrier < power_or_left);
    assert(power_or_right < power_and_left);
    assert(power_and_right < power_compare_left);
    assert(power_multiplicative_right < power_unary);
}

pub fn operands_of(variant: Variant) u32 {
    const result: u32 = switch (variant) {
        .binary => 2,
        .unary => 1,
        .call, .composite, .index, .paren, .top => 0,
    };

    assert(result <= 2);
    if (result == 0) assert(variant != .binary);

    return result;
}

pub fn infix_of(kind: Kind) ?Binding {
    if (!kind.is_token()) return null;

    const binding: Binding = switch (kind) {
        .ampersand => multiplicative,
        .ampersand_ampersand => boolean_and,
        .ampersand_caret => multiplicative,
        .bar => additive,
        .bar_bar => boolean_or,
        .bang_equal => compare,
        .caret => additive,
        .equal_equal => compare,
        .greater => compare,
        .greater_equal => compare,
        .greater_greater => multiplicative,
        .less => compare,
        .less_equal => compare,
        .less_less => multiplicative,
        .minus => additive,
        .percent => multiplicative,
        .plus => additive,
        .slash => multiplicative,
        .star => multiplicative,
        else => return null,
    };

    assert(kind.is_token());

    assert(binding.left < binding.right);
    assert(binding.left > power_barrier);

    return binding;
}

pub fn assigns(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .ampersand_caret_equal,
        .ampersand_equal,
        .bar_equal,
        .caret_equal,
        .colon_equal,
        .equal,
        .greater_greater_equal,
        .less_less_equal,
        .minus_equal,
        .percent_equal,
        .plus_equal,
        .slash_equal,
        .star_equal,
        => true,
        else => false,
    };

    if (result) assert(infix_of(kind) == null);

    return result;
}

pub fn is_literal(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .number, .rune_literal, .string_literal => true,
        else => false,
    };

    if (result) assert(!assigns(kind));

    return result;
}

pub fn opens_a_type(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .arrow,
        .bracket_open,
        .chan_keyword,
        .dot_dot_dot,
        .func_keyword,
        .identifier,
        .interface_keyword,
        .map_keyword,
        .paren_open,
        .star,
        .struct_keyword,
        .tilde,
        => true,
        else => false,
    };

    if (result) assert(!is_literal(kind));

    return result;
}
