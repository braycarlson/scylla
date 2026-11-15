const std = @import("std");
const assert = std.debug.assert;
const Emitter = @import("../python.zig").Emitter;
const Kind = @import("../python.zig").Kind;
const ends_operand = @import("../python.zig").ends_operand;
const is_close = @import("../python.zig").is_close;
const is_layout = @import("../python.zig").is_layout;
const is_open = @import("../python.zig").is_open;

const Bound = struct {
    first: u32,
    end: u32,
};

pub fn element_complex(emitter: *const Emitter, from: u32) bool {
    assert(from <= emitter.raw.len);
    assert(emitter.raw.len == emitter.tokens.len);

    const count: u32 = @intCast(emitter.raw.len);
    var depth: u32 = 0;
    var lambdas: u32 = 0;
    var sliced = false;
    var complex = false;
    var start = from;
    var scan = from;

    while (scan < count) : (scan += 1) {
        const kind = emitter.raw[scan];

        if (is_open(kind)) depth += 1;

        if (is_close(kind)) {
            if (depth == 0) break;

            depth -= 1;
        }

        if (depth > 0) continue;

        if (kind == .comma) {
            if (lambdas == 0) break;

            continue;
        }

        if (kind == .lambda_keyword) lambdas += 1;
        if (kind != .colon) continue;

        if (lambdas > 0) {
            lambdas -= 1;

            continue;
        }

        sliced = true;
        complex = complex or !simple(emitter, .{ .first = start, .end = scan });
        start = scan + 1;
    }

    if (!sliced) return false;
    return complex or !simple(emitter, .{ .first = start, .end = scan });
}

pub fn colon(emitter: *const Emitter, colon_at: u32) ?bool {
    assert(colon_at < emitter.raw.len);
    assert(emitter.raw[colon_at] == .colon);

    const open = enclosing(emitter, colon_at);
    if (emitter.raw[open] != .bracket_open) return null;
    if (open == 0) return null;

    const before = significant_before(emitter, open, 0);
    if (!ends_operand(emitter.raw[before])) return null;
    if (lambda_colon(emitter, colon_at)) return null;

    var depth: u32 = 0;
    var lambdas: u32 = 0;
    var start = open + 1;
    var scan = open + 1;

    while (scan < colon_at) : (scan += 1) {
        const kind = emitter.raw[scan];

        if (is_open(kind)) depth += 1;
        if (is_close(kind)) depth -|= 1;
        if (depth > 0) continue;

        if (kind == .lambda_keyword) lambdas += 1;
        if (kind == .colon) lambdas -|= 1;

        if (kind == .comma) {
            if (lambdas == 0) start = scan + 1;
        }
    }

    assert(start <= colon_at);

    return element_complex(emitter, start);
}

pub fn lambda_colon(emitter: *const Emitter, colon_at: u32) bool {
    assert(colon_at < emitter.raw.len);
    assert(emitter.raw[colon_at] == .colon);

    var depth: u32 = 0;
    var lambdas: u32 = 0;
    var scan = enclosing(emitter, colon_at) + 1;

    while (scan < colon_at) : (scan += 1) {
        const kind = emitter.raw[scan];

        if (is_open(kind)) depth += 1;
        if (is_close(kind)) depth -|= 1;
        if (depth > 0) continue;

        if (kind == .lambda_keyword) lambdas += 1;
        if (kind == .colon) lambdas -|= 1;
    }

    assert(scan == colon_at);

    return lambdas > 0;
}

fn enclosing(emitter: *const Emitter, colon_at: u32) u32 {
    assert(colon_at < emitter.raw.len);
    assert(emitter.raw[colon_at] == .colon);

    var depth: u32 = 0;
    var scan = colon_at;

    while (scan > 0) {
        scan -= 1;

        const kind = emitter.raw[scan];

        if (is_close(kind)) depth += 1;

        if (is_open(kind)) {
            if (depth == 0) return scan;

            depth -= 1;
        }
    }

    return 0;
}

fn simple(emitter: *const Emitter, bound: Bound) bool {
    assert(bound.first <= bound.end);
    assert(bound.end <= emitter.raw.len);

    var first = significant_from(emitter, bound.first, bound.end) orelse return true;
    var last = significant_before(emitter, bound.end, first);

    for (0..emitter.raw.len) |_| {
        const kind = emitter.raw[first];
        const unary = kind == .minus or kind == .plus or kind == .tilde;

        if (unary) {
            first = significant_from(emitter, first + 1, last + 1) orelse return false;

            continue;
        }

        if (kind != .paren_open) break;
        if (emitter.raw[last] != .paren_close) return false;
        if (closing(emitter, first) != last) return false;

        first = significant_from(emitter, first + 1, last) orelse return false;
        last = significant_before(emitter, last, first);
    }

    return atom(emitter, first, last);
}

fn atom(emitter: *const Emitter, first: u32, last: u32) bool {
    assert(first <= last);
    assert(last < emitter.raw.len);

    if (first == last) {
        return switch (emitter.raw[first]) {
            .ellipsis,
            .false_keyword,
            .identifier,
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

    var scan = first;

    while (scan <= last) : (scan += 1) {
        const kind = emitter.raw[scan];
        const skipped = is_layout(kind) or kind == .comment;
        const stringed = kind == .string_plain or kind == .string_bytes;

        if (!skipped) {
            if (!stringed) return false;
        }
    }

    return true;
}

fn closing(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.raw.len);
    assert(is_open(emitter.raw[open]));

    const count: u32 = @intCast(emitter.raw.len);
    var depth: u32 = 0;
    var scan = open;

    while (scan < count) : (scan += 1) {
        const kind = emitter.raw[scan];

        if (is_open(kind)) depth += 1;

        if (is_close(kind)) {
            depth -= 1;

            if (depth == 0) return scan;
        }
    }

    return null;
}

fn significant_from(emitter: *const Emitter, from: u32, end: u32) ?u32 {
    assert(from <= end + 1);
    assert(end <= emitter.raw.len);

    var scan = from;

    while (scan < end) : (scan += 1) {
        const kind = emitter.raw[scan];
        const skipped = is_layout(kind) or kind == .comment or emitter.tokens[scan].length == 0;
        if (!skipped) return scan;
    }

    return null;
}

fn significant_before(emitter: *const Emitter, end: u32, floor: u32) u32 {
    assert(floor < end);
    assert(end <= emitter.raw.len);

    var scan = end;

    while (scan > floor) {
        scan -= 1;

        const kind = emitter.raw[scan];
        const skipped = is_layout(kind) or kind == .comment or emitter.tokens[scan].length == 0;
        if (!skipped) return scan;
    }

    return floor;
}
