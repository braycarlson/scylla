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
    checkpoint: ?Checkpoint,
    closer: Kind,
    kind: Kind,
    power: u8,
    stage: u8,
    values: u32,
    variant: Variant,

    pub const empty: Frame = .{
        .checkpoint = null,
        .closer = .error_token,
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

const Infix = struct {
    node: Kind,
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
const power_bitwise_left: u8 = 8;
const power_bitwise_right: u8 = 9;
const power_shift_left: u8 = 10;
const power_shift_right: u8 = 11;
const power_additive_left: u8 = 12;
const power_additive_right: u8 = 13;
const power_multiplicative_left: u8 = 14;
const power_multiplicative_right: u8 = 15;
pub const power_prefix: u8 = 18;
const power_error_union_left: u8 = 21;
const power_error_union_right: u8 = 20;

const Binding = struct {
    left: u8,
    right: u8,
};

const additive: Binding = .{ .left = power_additive_left, .right = power_additive_right };
const bitwise: Binding = .{ .left = power_bitwise_left, .right = power_bitwise_right };
const boolean_and: Binding = .{ .left = power_and_left, .right = power_and_right };
const boolean_or: Binding = .{ .left = power_or_left, .right = power_or_right };
const compare: Binding = .{ .left = power_compare_left, .right = power_compare_right };

const error_union: Binding = .{
    .left = power_error_union_left,
    .right = power_error_union_right,
};

const multiplicative: Binding = .{
    .left = power_multiplicative_left,
    .right = power_multiplicative_right,
};

const shift: Binding = .{ .left = power_shift_left, .right = power_shift_right };

comptime {
    assert(power_barrier < power_or_left);
    assert(power_multiplicative_right < power_prefix);
    assert(power_prefix < power_error_union_right);
    assert(power_error_union_right < power_error_union_left);
}

pub fn infix_of(kind: Kind) ?Infix {
    assert(kind.is_token());

    const node: Kind, const binding: Binding = switch (kind) {
        .ampersand => .{ .bit_and, bitwise },
        .and_keyword => .{ .bool_and, boolean_and },
        .bang => .{ .error_union, error_union },
        .bang_equal => .{ .bang_equal_node, compare },
        .caret => .{ .bit_xor, bitwise },
        .catch_keyword => .{ .@"catch", bitwise },
        .equal_equal => .{ .equal_equal_node, compare },
        .greater => .{ .greater_than, compare },
        .greater_equal => .{ .greater_or_equal, compare },
        .greater_greater => .{ .shr, shift },
        .less => .{ .less_than, compare },
        .less_equal => .{ .less_or_equal, compare },
        .less_less => .{ .shl, shift },
        .less_less_pipe => .{ .shl_sat, shift },
        .minus => .{ .sub, additive },
        .minus_percent => .{ .sub_wrap, additive },
        .minus_pipe => .{ .sub_sat, additive },
        .or_keyword => .{ .bool_or, boolean_or },
        .orelse_keyword => .{ .@"orelse", bitwise },
        .percent => .{ .mod, multiplicative },
        .pipe => .{ .bit_or, bitwise },
        .pipe_pipe => .{ .merge_error_sets, multiplicative },
        .plus => .{ .add, additive },
        .plus_percent => .{ .add_wrap, additive },
        .plus_pipe => .{ .add_sat, additive },
        .plus_plus => .{ .array_cat, additive },
        .slash => .{ .div, multiplicative },
        .star => .{ .mul, multiplicative },
        .star_percent => .{ .mul_wrap, multiplicative },
        .star_pipe => .{ .mul_sat, multiplicative },
        .star_star => .{ .array_mult, multiplicative },
        else => return null,
    };

    assert(node.is_node());
    assert(binding.left != binding.right);
    assert(binding.left > power_barrier);

    return .{ .node = node, .left = binding.left, .right = binding.right };
}

pub fn assignment_of(kind: Kind) ?Kind {
    if (!kind.is_token()) return null;

    const node: Kind = switch (kind) {
        .ampersand_equal => .assign_bit_and,
        .caret_equal => .assign_bit_xor,
        .equal => .assign,
        .greater_greater_equal => .assign_shr,
        .less_less_equal => .assign_shl,
        .less_less_pipe_equal => .assign_shl_sat,
        .minus_equal => .assign_sub,
        .minus_percent_equal => .assign_sub_wrap,
        .minus_pipe_equal => .assign_sub_sat,
        .percent_equal => .assign_mod,
        .pipe_equal => .assign_bit_or,
        .plus_equal => .assign_add,
        .plus_percent_equal => .assign_add_wrap,
        .plus_pipe_equal => .assign_add_sat,
        .slash_equal => .assign_div,
        .star_equal => .assign_mul,
        .star_percent_equal => .assign_mul_wrap,
        .star_pipe_equal => .assign_mul_sat,
        else => return null,
    };

    assert(kind.is_token());

    assert(node.category() == .assignment);

    return node;
}

pub fn prefix_of(kind: Kind) ?Kind {
    if (!kind.is_token()) return null;

    const node: Kind = switch (kind) {
        .ampersand => .address_of,
        .bang => .bool_not,
        .minus => .negation,
        .minus_percent => .negation_wrap,
        .tilde => .bit_not,
        .try_keyword => .@"try",
        else => return null,
    };

    assert(kind.is_token());

    assert(node.is_node());

    return node;
}

fn is_literal(kind: Kind) bool {
    assert(kind.is_token());

    return switch (kind) {
        .character, .number, .text, .text_line => true,
        else => false,
    };
}

pub fn literal_node(kind: Kind) Kind {
    assert(is_literal(kind));

    return switch (kind) {
        .character => .char_literal,
        .number => .number_literal,
        .text_line => .multiline_string_literal,
        else => .string_literal,
    };
}

fn opens_a_type(kind: Kind) bool {
    assert(kind.is_token());

    return switch (kind) {
        .anyframe_keyword,
        .bracket_open,
        .builtin,
        .enum_keyword,
        .error_keyword,
        .extern_keyword,
        .fn_keyword,
        .identifier,
        .opaque_keyword,
        .packed_keyword,
        .paren_open,
        .question,
        .star,
        .star_star,
        .struct_keyword,
        .union_keyword,
        => true,
        else => false,
    };
}

test "an infix operator binds by its class and builds its node" {
    const plus = infix_of(.plus).?;
    const bang = infix_of(.bang).?;

    try std.testing.expectEqual(Kind.add, plus.node);
    try std.testing.expectEqual(power_additive_left, plus.left);
    try std.testing.expect(bang.left > bang.right);
    try std.testing.expectEqual(Kind.@"catch", infix_of(.catch_keyword).?.node);
    try std.testing.expectEqual(null, infix_of(.identifier));
}

test "assignments and prefixes map tokens to nodes" {
    try std.testing.expectEqual(Kind.assign, assignment_of(.equal).?);
    try std.testing.expectEqual(null, assignment_of(.equal_equal));
    try std.testing.expectEqual(Kind.address_of, prefix_of(.ampersand).?);
    try std.testing.expectEqual(null, prefix_of(.plus));
    try std.testing.expectEqual(Kind.multiline_string_literal, literal_node(.text_line));
    try std.testing.expect(is_literal(.character));
    try std.testing.expect(opens_a_type(.question));
    try std.testing.expect(!Frame.empty.is_bracketed());
    try std.testing.expect(Frame.empty.is_group());
}
