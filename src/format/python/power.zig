const std = @import("std");
const assert = std.debug.assert;
const Emitter = @import("../python.zig").Emitter;
const Kind = @import("../python.zig").Kind;
const bracket_depth_max = @import("../python.zig").bracket_depth_max;
const ends_operand = @import("../python.zig").ends_operand;
const is_layout = @import("../python.zig").is_layout;
const is_number = @import("../python.zig").is_number;
const is_open = @import("../python.zig").is_open;
const is_unary = @import("../python.zig").is_unary;

pub const Powers = struct {
    count: u32,
    ends: [bracket_depth_max]u32,

    pub const empty: Powers = .{
        .count = 0,
        .ends = @splat(0),
    };

    pub fn push(powers: *Powers, end: u32) error{Overflow}!void {
        assert(powers.count <= bracket_depth_max);
        if (powers.count > 0) assert(end <= powers.ends[powers.count - 1]);

        if (powers.count == bracket_depth_max) return error.Overflow;

        powers.ends[powers.count] = end;
        powers.count += 1;
    }

    pub fn closes(powers: *Powers, position: u32) bool {
        assert(powers.count <= bracket_depth_max);

        if (!powers.ends_at(position)) return false;

        powers.count -= 1;

        return true;
    }

    pub fn ends_at(powers: *const Powers, position: u32) bool {
        assert(powers.count <= bracket_depth_max);

        if (powers.count == 0) return false;
        return powers.ends[powers.count - 1] == position;
    }
};

fn extends_negated(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .ampersand,
        .at,
        .bar,
        .caret,
        .equal_equal,
        .greater,
        .greater_equal,
        .greater_greater,
        .in_keyword,
        .is_keyword,
        .less,
        .less_equal,
        .less_less,
        .minus,
        .not_equal,
        .not_keyword,
        .percent,
        .plus,
        .slash,
        .slash_slash,
        .star,
        => true,
        else => false,
    };

    if (result) assert(kind.is_token());
    if (result) assert(!ends_operand(kind));

    return result;
}

pub fn hugs(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.tokens.len);
    assert(emitter.raw[position] == .star_star);

    if (!simple_operand(emitter, position, false)) return false;
    return simple_operand(emitter, position, true);
}

fn simple_operand(emitter: *const Emitter, position: u32, exponent: bool) bool {
    assert(position < emitter.tokens.len);
    assert(emitter.tokens.len < std.math.maxInt(u32));

    const count: u32 = @intCast(emitter.tokens.len);
    var scan = position;
    var signed_operand = false;

    for (0..count) |_| {
        const held = if (exponent) scan + 1 else scan -% 1;
        if (held >= count) return false;

        scan = held;

        const kind = emitter.raw[scan];
        if (is_layout(kind)) return false;
        if (kind == .comment) continue;

        const sign = kind == .minus or kind == .plus or kind == .tilde;

        if (exponent) {
            if (sign) {
                signed_operand = true;

                continue;
            }
        }

        const constant = kind == .false_keyword or kind == .none_keyword or
            kind == .true_keyword;

        const simple = kind == .identifier or is_number(kind) or constant;
        if (!simple) return false;
        return simple_lookup(emitter, scan, exponent, signed_operand);
    }

    unreachable;
}

fn simple_lookup(
    emitter: *const Emitter,
    position: u32,
    exponent: bool,
    signed_operand: bool,
) bool {
    assert(position < emitter.tokens.len);
    assert(emitter.tokens.len < std.math.maxInt(u32));
    if (signed_operand) assert(exponent);

    const count: u32 = @intCast(emitter.tokens.len);
    var scan = position;

    for (0..count) |_| {
        const held = if (exponent) scan + 1 else scan -% 1;
        if (held >= count) return true;

        scan = held;

        const kind = emitter.raw[scan];
        if (is_layout(kind)) return true;
        if (kind == .comment) continue;

        const opened = kind == .bracket_open or kind == .paren_open;
        const closed = kind == .bracket_close or kind == .paren_close;

        if (exponent) {
            if (opened) return false;

            if (signed_operand) {
                if (kind == .star_star) return false;
            }
        } else {
            if (closed) return false;
            if (kind == .await_keyword) return false;
        }

        const chained = kind == .dot or kind == .identifier;
        if (!chained) return true;
    }

    unreachable;
}

pub fn powered(emitter: *const Emitter, position: u32, previous: ?Kind) ?u32 {
    assert(position < emitter.tokens.len);
    assert(emitter.tokens.len == emitter.raw.len);
    if (previous) |held| assert(held.is_token());

    const kind = emitter.raw[position];
    if (!is_unary(kind)) return null;

    if (previous) |held| {
        if (ends_operand(held)) return null;

        if (kind == .not_keyword) {
            if (held == .is_keyword) return null;
        }
    }

    const operand = significant_after(emitter, position) orelse return null;
    if (is_unary(emitter.raw[operand])) return null;

    const end = power_end(emitter, operand) orelse return null;
    if (kind != .not_keyword) return end;

    const after = significant_after(emitter, end) orelse return end;
    if (extends_negated(emitter.raw[after])) return null;
    return end;
}

pub fn subscript_parenthesized(emitter: *const Emitter, open_at: u32, close_at: u32) bool {
    assert(open_at < close_at);
    assert(emitter.raw[open_at] == .paren_open);

    var opening = open_at;
    var closing = close_at;

    for (0..emitter.tokens.len) |_| {
        const first = significant_after(emitter, opening) orelse return false;
        if (first >= closing) return false;
        if (emitter.raw[first] == .await_keyword) return false;

        const end = primary_end(emitter, first) orelse return false;
        if (significant_after(emitter, end) != closing) return false;

        const atom = atom_end(emitter, first) orelse return false;
        if (atom != end) return emitter.raw[end] == .bracket_close;
        if (emitter.raw[first] != .paren_open) return false;

        opening = first;
        closing = end;
    }

    return false;
}

fn power_end(emitter: *const Emitter, start: u32) ?u32 {
    assert(start < emitter.tokens.len);
    assert(emitter.tokens.len == emitter.raw.len);

    var end = primary_end(emitter, start) orelse return null;
    var exponents: u32 = 0;

    for (0..emitter.tokens.len) |_| {
        const operator = significant_after(emitter, end) orelse break;
        if (emitter.raw[operator] != .star_star) break;

        const factor = factor_start(emitter, operator) orelse return null;

        end = primary_end(emitter, factor) orelse return null;
        exponents += 1;
    }

    if (exponents == 0) return null;

    assert(end > start);

    return end;
}

fn factor_start(emitter: *const Emitter, operator: u32) ?u32 {
    assert(operator < emitter.tokens.len);
    assert(emitter.raw[operator] == .star_star);

    var scan = significant_after(emitter, operator) orelse return null;

    for (0..emitter.tokens.len) |_| {
        const kind = emitter.raw[scan];
        const sign = kind == .minus or kind == .plus or kind == .tilde;
        if (!sign) return scan;

        scan = significant_after(emitter, scan) orelse return null;
    }

    unreachable;
}

fn primary_end(emitter: *const Emitter, start: u32) ?u32 {
    assert(start < emitter.tokens.len);
    assert(emitter.tokens.len == emitter.raw.len);

    const awaited = emitter.raw[start] == .await_keyword;
    const atom = if (awaited) significant_after(emitter, start) orelse return null else start;
    var end = atom_end(emitter, atom) orelse return null;

    for (0..emitter.tokens.len) |_| {
        const next = significant_after(emitter, end) orelse return end;
        const kind = emitter.raw[next];

        if (kind == .dot) {
            const name = significant_after(emitter, next) orelse return null;
            if (emitter.raw[name] != .identifier) return null;

            end = name;

            continue;
        }

        const trailed = kind == .bracket_open or kind == .paren_open;
        if (!trailed) return end;

        end = emitter.closed_at(next) orelse return null;
    }

    unreachable;
}

fn atom_end(emitter: *const Emitter, start: u32) ?u32 {
    assert(start < emitter.tokens.len);
    assert(emitter.tokens.len == emitter.raw.len);

    const kind = emitter.raw[start];
    if (is_open(kind)) return emitter.closed_at(start);

    const constant = kind == .ellipsis or kind == .false_keyword or kind == .identifier or
        kind == .none_keyword or kind == .true_keyword or is_number(kind);

    if (constant) return start;

    var end = string_end(emitter, start) orelse return null;

    for (0..emitter.tokens.len) |_| {
        const next = significant_after(emitter, end) orelse return end;

        end = string_end(emitter, next) orelse return end;
    }

    unreachable;
}

fn string_end(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.tokens.len);
    assert(emitter.tokens.len == emitter.raw.len);

    return switch (emitter.raw[position]) {
        .f_string_start => emitter.fstring_end(position),
        .string_bytes, .string_format, .string_plain => position,
        else => null,
    };
}

fn significant_after(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.tokens.len);
    assert(emitter.tokens.len == emitter.raw.len);

    const count: u32 = @intCast(emitter.tokens.len);
    var scan = position + 1;

    while (scan < count) : (scan += 1) {
        const kind = emitter.raw[scan];
        if (kind == .newline) return null;

        const skipped = is_layout(kind) or kind == .comment or emitter.tokens[scan].length == 0;

        if (!skipped) {
            assert(scan <= emitter.tokens.len);

            return scan;
        }
    }

    return null;
}
