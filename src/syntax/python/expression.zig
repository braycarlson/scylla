const std = @import("std");
const assert = std.debug.assert;
const Checkpoint = @import("../tree.zig").Checkpoint;
const Kind = @import("kind.zig").Kind;

pub const Variant = enum {
    bare,
    binary,
    brace,
    bracket,
    call,
    class_args,
    conditional,
    formatted,
    joined,
    keyword,
    lambda,
    mapping,
    paren,
    pattern_group,
    sequence,
    subscript,
    top,
    unary,
    yield,
};

pub const Frame = struct {
    bracket: ?Checkpoint,
    checkpoint: ?Checkpoint,
    clause: ?Checkpoint,
    closer: Kind,
    comprehension: bool,
    content: ?Checkpoint,
    dictionary: bool,
    element: ?Checkpoint,
    element_values: u32,
    elements: u32,
    keyed: bool,
    keywords: bool,
    kind: Kind,
    named: bool,
    no_in: bool,
    plain: bool,
    power: u8,
    signature: Signature,
    slice: bool,
    stage: u8,
    starred: bool,
    token: Kind,
    tuple: bool,
    unpacked: bool,
    unpacks: bool,
    values: u32,
    variant: Variant,
    walrus: bool,
    yields: bool,

    pub const empty: Frame = .{
        .bracket = null,
        .checkpoint = null,
        .clause = null,
        .closer = .error_token,
        .comprehension = false,
        .content = null,
        .dictionary = false,
        .element = null,
        .element_values = 0,
        .elements = 0,
        .keyed = false,
        .keywords = false,
        .kind = .error_node,
        .named = false,
        .no_in = false,
        .plain = false,
        .power = power_barrier,
        .signature = .empty,
        .slice = false,
        .stage = 0,
        .starred = false,
        .token = .error_token,
        .tuple = false,
        .unpacked = false,
        .unpacks = false,
        .values = 0,
        .variant = .top,
        .walrus = false,
        .yields = false,
    };

    pub fn is_group(frame: *const Frame) bool {
        assert(frame.kind.is_node());
        assert(frame.closer.is_token());

        return switch (frame.variant) {
            .bare,
            .brace,
            .bracket,
            .call,
            .class_args,
            .formatted,
            .joined,
            .lambda,
            .mapping,
            .paren,
            .pattern_group,
            .sequence,
            .subscript,
            .top,
            .yield,
            => true,
            .binary, .conditional, .keyword, .unary => false,
        };
    }

    pub fn is_pattern(frame: *const Frame) bool {
        assert(frame.kind.is_node());
        assert(frame.closer.is_token());

        return switch (frame.variant) {
            .class_args, .mapping, .pattern_group, .sequence => true,
            else => false,
        };
    }

    pub fn is_bracketed(frame: *const Frame) bool {
        assert(frame.kind.is_node());
        assert(frame.closer.is_token());

        return switch (frame.variant) {
            .bare, .brace, .bracket, .call, .paren, .subscript => true,
            else => false,
        };
    }
};

pub const Signature = struct {
    bare: bool,
    closed: bool,
    defaulted: bool,
    keyword: bool,
    named: bool,
    slashed: bool,

    pub const empty: Signature = .{
        .bare = false,
        .closed = false,
        .defaulted = false,
        .keyword = false,
        .named = false,
        .slashed = false,
    };

    pub fn admits(signature: *Signature, lead: Kind, named: bool, defaulted: bool) bool {
        assert(lead.is_token());

        if (signature.closed) return false;

        switch (lead) {
            .slash => {
                const valid = !named and !signature.slashed and !signature.keyword and
                    signature.named;

                signature.slashed = true;

                return valid;
            },
            .star => {
                const valid = !signature.keyword and !defaulted;

                signature.bare = !named;
                signature.keyword = true;

                return valid;
            },
            .star_star => {
                const valid = named and !defaulted and !signature.bare;

                signature.closed = true;

                return valid;
            },
            else => {
                const ordered = signature.keyword or defaulted or !signature.defaulted;

                if (!signature.keyword) {
                    if (defaulted) signature.defaulted = true;
                }

                signature.bare = false;
                signature.named = true;

                return named and ordered;
            },
        }
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
pub const power_starred: u8 = 1;
pub const power_walrus_left: u8 = 4;
const power_walrus_right: u8 = 3;
pub const power_conditional_left: u8 = 6;
pub const power_conditional_right: u8 = 5;
const power_or_left: u8 = 8;
const power_or_right: u8 = 9;
const power_and_left: u8 = 10;
const power_and_right: u8 = 11;
pub const power_not: u8 = 12;
pub const power_compare_left: u8 = 14;
pub const power_compare_right: u8 = 15;
pub const power_bar_left: u8 = 16;
pub const power_bar_right: u8 = 17;
const power_caret_left: u8 = 18;
const power_caret_right: u8 = 19;
const power_ampersand_left: u8 = 20;
const power_ampersand_right: u8 = 21;
const power_shift_left: u8 = 22;
const power_shift_right: u8 = 23;
const power_additive_left: u8 = 24;
const power_additive_right: u8 = 25;
const power_multiplicative_left: u8 = 26;
const power_multiplicative_right: u8 = 27;
pub const power_sign: u8 = 28;
const power_power_left: u8 = 32;
const power_power_right: u8 = 29;
pub const power_await: u8 = 34;

const ampersand: Infix = .{
    .node = .bin_op,
    .left = power_ampersand_left,
    .right = power_ampersand_right,
};

const additive: Infix = .{
    .node = .bin_op,
    .left = power_additive_left,
    .right = power_additive_right,
};

const bar: Infix = .{ .node = .bin_op, .left = power_bar_left, .right = power_bar_right };
const boolean_and: Infix = .{ .node = .bool_op, .left = power_and_left, .right = power_and_right };
const boolean_or: Infix = .{ .node = .bool_op, .left = power_or_left, .right = power_or_right };
const caret: Infix = .{ .node = .bin_op, .left = power_caret_left, .right = power_caret_right };

const compare: Infix = .{
    .node = .compare,
    .left = power_compare_left,
    .right = power_compare_right,
};

const multiplicative: Infix = .{
    .node = .bin_op,
    .left = power_multiplicative_left,
    .right = power_multiplicative_right,
};

const power: Infix = .{ .node = .bin_op, .left = power_power_left, .right = power_power_right };
const shift: Infix = .{ .node = .bin_op, .left = power_shift_left, .right = power_shift_right };

const walrus: Infix = .{
    .node = .named_expr,
    .left = power_walrus_left,
    .right = power_walrus_right,
};

comptime {
    assert(power_barrier < power_starred);
    assert(power_walrus_right < power_walrus_left);
    assert(power_conditional_right < power_conditional_left);
    assert(power_power_right < power_power_left);
    assert(power_await > power_power_left);
}

pub fn closer_of(opener: Kind) Kind {
    assert(opener.is_token());

    const closer: Kind = switch (opener) {
        .brace_open => .brace_close,
        .bracket_open => .bracket_close,
        else => .paren_close,
    };

    assert(closer.is_token());

    return closer;
}

pub fn infix_of(kind: Kind) ?Infix {
    assert(kind.is_token());

    const infix: Infix = switch (kind) {
        .ampersand => ampersand,
        .and_keyword => boolean_and,
        .at, .percent, .slash, .slash_slash, .star => multiplicative,
        .bar => bar,
        .caret => caret,
        .colon_equal => walrus,
        .equal_equal,
        .greater,
        .greater_equal,
        .in_keyword,
        .is_keyword,
        .less,
        .less_equal,
        .not_equal,
        => compare,
        .greater_greater, .less_less => shift,
        .minus, .plus => additive,
        .or_keyword => boolean_or,
        .star_star => power,
        else => return null,
    };

    assert(infix.node.is_node());
    assert(infix.left != infix.right);

    return infix;
}

pub fn is_literal(kind: Kind) bool {
    assert(kind.is_token());

    return switch (kind) {
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
        .string_plain,
        .true_keyword,
        => true,
        else => false,
    };
}

pub fn is_string(kind: Kind) bool {
    assert(kind.is_token());

    return switch (kind) {
        .string_bytes, .string_plain => true,
        else => false,
    };
}

pub fn is_contributor(kind: Kind) bool {
    assert(kind.is_token());

    return switch (kind) {
        .f_string_middle, .string_bytes, .string_plain => true,
        else => false,
    };
}

pub fn is_piece(kind: Kind) bool {
    assert(kind.is_token());

    return switch (kind) {
        .f_string_end, .f_string_middle, .f_string_start => true,
        else => is_string(kind),
    };
}

test "an infix operator binds by its class and builds its node" {
    try std.testing.expectEqual(Kind.bin_op, infix_of(.plus).?.node);
    try std.testing.expectEqual(power_additive_left, infix_of(.minus).?.left);
    try std.testing.expectEqual(Kind.compare, infix_of(.is_keyword).?.node);
    try std.testing.expectEqual(Kind.bool_op, infix_of(.or_keyword).?.node);
    try std.testing.expectEqual(Kind.named_expr, infix_of(.colon_equal).?.node);
    try std.testing.expectEqual(power_power_right, infix_of(.star_star).?.right);
    try std.testing.expectEqual(null, infix_of(.comma));
}

test "a literal, a string and a piece are told apart" {
    try std.testing.expect(is_literal(.ellipsis));
    try std.testing.expect(!is_literal(.string_format));
    try std.testing.expect(is_string(.string_bytes));
    try std.testing.expect(is_contributor(.f_string_middle));
    try std.testing.expect(is_piece(.f_string_start));
    try std.testing.expect(is_piece(.string_plain));
    try std.testing.expect(!is_piece(.identifier));
    try std.testing.expectEqual(Kind.brace_close, closer_of(.brace_open));
    try std.testing.expectEqual(Kind.paren_close, closer_of(.paren_open));
}
