const std = @import("std");
const assert = std.debug.assert;
const Emitter = @import("../python.zig").Emitter;
const Kind = @import("../python.zig").Kind;
const Span = @import("../../stdx/bounded/span.zig");
const bracket_depth_max = @import("../python.zig").bracket_depth_max;
const ends_operand = @import("../python.zig").ends_operand;
const is_close = @import("../python.zig").is_close;
const is_layout = @import("../python.zig").is_layout;
const is_open = @import("../python.zig").is_open;
const is_string_start = @import("../python.zig").is_string_start;
const is_unary = @import("../python.zig").is_unary;
const kind_parted = @import("../python.zig").kind_parted;
const prefix_of = @import("literal.zig").prefix_of;
const priority_comparator = @import("../python.zig").priority_comparator;
const priority_comprehension = @import("../python.zig").priority_comprehension;
const priority_dot = @import("../python.zig").priority_dot;
const triple_double = @import("literal.zig").triple_double;
const triple_single = @import("literal.zig").triple_single;

pub fn omits(emitter: *const Emitter, open_at: u32, close_at: u32, found: u8) bool {
    assert(open_at < close_at);
    assert(found <= priority_comprehension);

    const dotted = found == 0 or found == priority_dot;
    if (!dotted) return false;

    const first = operand_first(emitter, open_at + 1, close_at, true) orelse return false;

    const end = switch (emitter.raw[first]) {
        .f_string_start => emitter.format_end(first),
        .string_bytes, .string_plain => first,
        else => return false,
    };

    const offset = emitter.tokens[first].offset;
    const held: Span = .{ .offset = offset, .length = emitter.tokens[end].end() - offset };

    return std.mem.findScalar(u8, held.text(emitter.source), '\n') != null;
}

fn operand_first(emitter: *const Emitter, from: u32, close_at: u32, every: bool) ?u32 {
    assert(from <= close_at);
    assert(close_at <= emitter.tokens.len);

    var scan = from;

    for (from..close_at) |_| {
        const held = token_from(emitter, scan, close_at) orelse return null;
        const kind = emitter.raw[held];
        const unary = is_unary(kind) or kind == .await_keyword;
        const prefix = kind == .not_keyword or (every and unary);

        assert(held >= scan);

        if (!prefix) return held;

        scan = held + 1;
    }

    return null;
}

fn token_from(emitter: *const Emitter, from: u32, ceiling: u32) ?u32 {
    assert(from <= ceiling);
    assert(ceiling <= emitter.tokens.len);

    var scan = from;

    while (scan < ceiling) : (scan += 1) {
        const significant = !is_layout(emitter.raw[scan]) and emitter.tokens[scan].length > 0;
        if (significant) return scan;
    }

    return null;
}

pub fn spans(emitter: *const Emitter, open_at: u32, close_at: u32) bool {
    assert(open_at < close_at);
    assert(close_at <= emitter.tokens.len);

    return spans_from(emitter, open_at + 1, close_at);
}

pub fn spans_from(emitter: *const Emitter, from: u32, close_at: u32) bool {
    assert(from <= close_at);
    assert(close_at <= emitter.tokens.len);

    var depth: u32 = 0;
    var scan = from;

    while (scan < close_at) : (scan += 1) {
        const kind = emitter.raw[scan];
        const bytes = emitter.tokens[scan].text(emitter.source);

        if (depth == 0) {
            if (std.mem.findScalar(u8, bytes, '\n') != null) return true;
        }

        if (is_open(kind)) depth += 1;
        if (is_close(kind)) depth -= 1;
    }

    return false;
}

pub fn lambda_spans(emitter: *const Emitter, lambda_at: u32, close_at: u32) bool {
    assert(lambda_at < close_at);
    assert(emitter.raw[lambda_at] == .lambda_keyword);

    var depth: u32 = 0;
    var colon: ?u32 = null;

    for (lambda_at + 1..close_at) |scan| {
        const kind = emitter.raw[scan];

        if (is_open(kind)) depth += 1;
        if (is_close(kind)) depth -|= 1;

        if (depth == 0) {
            if (kind == .colon) {
                colon = @intCast(scan);

                break;
            }
        }
    }

    var open_at = colon orelse return false;
    var end = close_at;

    for (0..bracket_depth_max) |_| {
        const body = emitter.next_token(open_at, end) orelse return false;
        const last = emitter.prior_token(end, open_at) orelse return false;
        const enclosed = emitter.raw[body] == .paren_open and emitter.closed_at(body) == last;
        if (!enclosed) break;

        open_at = body;
        end = last;
    }

    return spans(emitter, open_at, end);
}

pub fn spans_deep(emitter: *const Emitter, open_at: u32, close_at: u32) bool {
    assert(open_at < close_at);
    assert(close_at <= emitter.tokens.len);

    for (open_at + 1..close_at) |scan| {
        const bytes = emitter.tokens[scan].text(emitter.source);
        if (std.mem.findScalar(u8, bytes, '\n') != null) return true;
    }

    return false;
}

pub fn spans_head(emitter: *const Emitter, from: u32, close_at: u32, found: u8) bool {
    assert(from <= close_at);
    assert(close_at <= emitter.tokens.len);

    if (found > priority_comparator) return false;

    const first = operand_first(emitter, from, close_at, false) orelse return false;
    if (!is_string_start(emitter.raw[first])) return false;

    const end = multiline_end(emitter, first) orelse return false;
    const operator = emitter.next_token(end, close_at) orelse return false;
    if (kind_parted(emitter.raw[operator], emitter.raw[end]) != found) return false;

    var right = emitter.next_token(operator, close_at) orelse return false;
    const negated = emitter.raw[operator] == .is_keyword and emitter.raw[right] == .not_keyword;
    const contained = emitter.raw[operator] == .not_keyword;
    const worded = negated or contained;
    if (worded) right = emitter.next_token(right, close_at) orelse return false;

    const stop = if (found == priority_comparator)
        comparator_end(emitter, right, close_at)
    else
        close_at;

    return operand_parenthesized(emitter, right, stop);
}

fn multiline_end(emitter: *const Emitter, first: u32) ?u32 {
    assert(first < emitter.tokens.len);
    assert(is_string_start(emitter.raw[first]));

    const bytes = emitter.tokens[first].text(emitter.source);
    const quotes = bytes[prefix_of(bytes)..];

    const tripled = std.mem.startsWith(u8, quotes, triple_double) or
        std.mem.startsWith(u8, quotes, triple_single);

    if (!tripled) return null;

    if (emitter.raw[first] != .f_string_start) {
        if (std.mem.findScalar(u8, bytes, '\n') == null) return null;
        return first;
    }

    const end = emitter.format_end(first);
    var depth: u32 = 0;

    for (first..end + 1) |scan| {
        const kind = emitter.raw[scan];

        if (kind == .f_string_start) depth += 1;
        if (kind == .f_string_end) depth -|= 1;

        const literal = depth == 1 and kind == .f_string_middle;
        const text_held = emitter.tokens[scan].text(emitter.source);

        if (literal) {
            if (std.mem.findScalar(u8, text_held, '\n') != null) return end;
        }
    }

    return null;
}

fn comparator_end(emitter: *const Emitter, from: u32, close_at: u32) u32 {
    assert(from < close_at);
    assert(close_at <= emitter.tokens.len);

    var depth: u32 = 0;
    var previous: ?Kind = null;
    var scan = from;

    while (scan < close_at) : (scan += 1) {
        const kind = emitter.raw[scan];
        if (is_layout(kind)) continue;

        const compares = depth == 0 and kind_parted(kind, previous) == priority_comparator;
        if (compares) return scan;

        if (is_open(kind)) depth += 1;
        if (is_close(kind)) depth -|= 1;

        previous = kind;
    }

    return close_at;
}

fn operand_parenthesized(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from < to);
    assert(to <= emitter.tokens.len);

    var depth: u32 = 0;
    var last: ?Kind = null;
    var scan = from;

    while (scan < to) : (scan += 1) {
        const kind = emitter.raw[scan];
        const skipped = is_layout(kind) or emitter.tokens[scan].length == 0;
        if (skipped) continue;

        const bracket = is_open(kind) or is_close(kind);
        const literal = kind == .f_string_start or kind == .f_string_middle;
        const trailer = bracket or literal or kind == .dot or ends_operand(kind);

        if (depth == 0) {
            if (!trailer) return false;
        }

        if (is_open(kind)) depth += 1;
        if (is_close(kind)) depth -|= 1;

        last = kind;
    }

    const held = last orelse return false;
    return is_close(held);
}
