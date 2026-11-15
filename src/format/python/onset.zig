const std = @import("std");
const assert = std.debug.assert;
const Emitter = @import("../python.zig").Emitter;
const Kind = @import("../python.zig").Kind;
const Splits = @import("../python.zig").Splits;
const bracket_depth_max = @import("../python.zig").bracket_depth_max;
const columns = @import("../walk.zig").columns;
const ends_operand = @import("../python.zig").ends_operand;
const is_close = @import("../python.zig").is_close;
const is_layout = @import("../python.zig").is_layout;
const is_open = @import("../python.zig").is_open;
const is_string_start = @import("../python.zig").is_string_start;
const kind_parted = @import("../python.zig").kind_parted;
const wrap_end_stops = @import("../python.zig").wrap_end_stops;
const opens_suite = @import("../python.zig").opens_suite;
const power = @import("power.zig");
const pragmatic = @import("literal.zig").pragmatic;
const priority_dot = @import("../python.zig").priority_dot;
const priority_logic = @import("../python.zig").priority_logic;
const spanned = @import("spanned.zig");
const Breaking = enum { listed, single };
const enclosing_columns: u32 = "()".len;
const paren_columns: u32 = "(".len;
const comment_gap_columns: u32 = "  ".len;
const returns_opening = ") -> ";
const target_closing_columns: u32 = ") in ".len;

pub fn wrap_arithmetic(emitter: *Emitter, position: u32, end: u32) error{Overflow}!void {
    assert(position < end);
    assert(emitter.wrap == null);

    if (!arithmetic(emitter, position, end)) return;

    const contents = emitter.contents_from(position, end) orelse return;
    if (!contents.held) return;

    if (contents.commented) {
        if (!emitter.holds_from(position, end)) return;
    }

    if (omits_arithmetic(emitter, position, emitter.bound_from(position, end))) return;
    return emitter.wrapping(position, null, end, false, false, true);
}

fn omits_arithmetic(emitter: *const Emitter, from: u32, bound: u32) bool {
    assert(from < bound);
    assert(bound <= emitter.tokens.len);

    const split = emitter.splits_from(from, bound);
    if (split.count > 1) return false;

    if (spanned.spans_from(emitter, from, bound)) {
        return spanned.spans_head(emitter, from, bound, split.found);
    }

    if (is_open(emitter.raw[from])) {
        if (emitter.filled(from, bound)) return true;
    }

    return emitter.omits_tail(from, bound, null);
}

fn arithmetic(emitter: *const Emitter, position: u32, end: u32) bool {
    assert(position < end);
    assert(end <= emitter.tokens.len);

    if (emitter.raw[position] == .not_keyword) return false;

    var depth: u32 = 0;
    var found: u8 = 0;
    var top: ?Kind = null;
    var previous: ?Kind = null;
    var splits: Splits = .new();
    var scan = position;

    while (scan < end) : (scan += 1) {
        const kind = emitter.raw[scan];
        const skipped = is_layout(kind) or kind == .comment;
        if (skipped) continue;

        if (depth == 0) {
            if (kind == .lambda_keyword) return false;

            const priority = splits.step(kind, previous);
            const literal = is_string_start(kind);

            if (!literal) {
                if (priority > found) {
                    found = priority;
                    top = kind;
                }
            }
        }

        if (is_open(kind)) depth += 1;
        if (is_close(kind)) depth -|= 1;

        previous = kind;
    }

    const held = top orelse return false;

    return switch (held) {
        .bar, .caret, .greater_greater, .less_less, .minus, .plus => true,
        else => false,
    };
}

pub fn wrap_target(emitter: *Emitter, position: u32, end: u32) error{Overflow}!void {
    assert(position < end);
    assert(emitter.raw[position] == .for_keyword);

    if (emitter.wrap != null) return;
    if (emitter.raw[end] != .in_keyword) return;

    const first = emitter.next_token(position, end) orelse return;
    const last = emitter.prior_token(end, position) orelse return;
    const enclosed = emitter.raw[first] == .paren_open and emitter.closed_at(first) == last;
    if (enclosed) return;

    const breaking = target_breaking(emitter, first, last, end, 0) orelse return;

    switch (breaking) {
        .listed => return emitter.wrapping(position + 1, .for_keyword, end, true, true, false),
        .single => {
            try emitter.wrapping(position + 1, .for_keyword, end, false, true, false);
            try emitter.document.push(.broken);
        },
    }
}

pub fn target_kept(emitter: *const Emitter, open_at: u32, close_at: u32) bool {
    assert(open_at < close_at);
    assert(emitter.raw[open_at] == .paren_open);

    const count: u32 = @intCast(emitter.tokens.len);
    const end = emitter.next_token(close_at, count) orelse return true;
    if (emitter.raw[end] != .in_keyword) return true;

    const first = emitter.next_token(open_at, close_at) orelse return true;
    const last = emitter.prior_token(close_at, open_at) orelse return true;

    return target_breaking(emitter, first, last, end, enclosing_columns) != null;
}

fn target_breaking(
    emitter: *const Emitter,
    first: u32,
    last: u32,
    end: u32,
    dropped: u32,
) ?Breaking {
    assert(first <= last);
    assert(last < end);

    const at = emitter.line_first_at orelse return null;
    const flat = emitter.indent * emitter.indent_width;
    const iterable = iterable_columns(emitter, end) orelse return null;
    const tail = flat + iterable + 1;
    if (!target_overflows(emitter, at, first, end, tail, dropped)) return null;
    if (emitter.listed_line(first, last + 1)) return .listed;

    const target = flat + emitter.indent_width + emitter.measured(first, last);
    const closing = flat + target_closing_columns + iterable;

    if (target > emitter.line_width) return null;
    if (closing > emitter.line_width) return null;
    return .single;
}

fn target_overflows(
    emitter: *const Emitter,
    at: u32,
    first: u32,
    end: u32,
    tail: u32,
    dropped: u32,
) bool {
    assert(at <= first);
    assert(first < end);
    assert(dropped < std.math.maxInt(u32));
    assert(tail > 0);

    const flat = emitter.indent * emitter.indent_width;
    const lead = dropped / 2;
    var leading = lead;
    var start = at;
    var scan = first;

    for (0..bracket_depth_max) |_| {
        const opening = opening_of(emitter, scan, end) orelse break;
        if (flat + (emitter.measured(start, opening) -| leading) > emitter.line_width) return true;

        const close = emitter.closed_at(opening) orelse return false;

        assert(close < end);

        leading = 0;
        start = close;
        scan = close + 1;
    }

    const trailing = leading + dropped - lead;
    return (emitter.measured(start, end) -| trailing) + tail > emitter.line_width;
}

fn iterable_columns(emitter: *const Emitter, in_at: u32) ?u32 {
    assert(in_at < emitter.tokens.len);
    assert(emitter.raw[in_at] == .in_keyword);

    const colon = header_colon(emitter, in_at) orelse return null;
    const from = emitter.next_token(in_at, colon) orelse return null;
    const split = emitter.splits_from(from, colon);
    if (split.found > priority_dot) return paren_columns;
    if (opening_of(emitter, from, colon)) |opening| return emitter.measured(from, opening);
    const returned = emitter.measured(from, colon) + comment_columns(emitter, colon);

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn comment_columns(emitter: *const Emitter, colon: u32) u32 {
    assert(colon < emitter.tokens.len);
    assert(emitter.raw[colon] == .colon);

    const comment = colon + 1;
    if (comment == emitter.tokens.len) return 0;
    if (emitter.raw[comment] != .comment) return 0;

    const lexeme = emitter.tokens[comment];
    if (pragmatic(lexeme.text(emitter.source))) return 0;
    const returned = comment_gap_columns + columns(emitter.source, lexeme.offset, lexeme.end());

    assert(returned < std.math.maxInt(u32));

    return returned;
}

pub fn rider_columns(emitter: *const Emitter, opening: u32) u32 {
    assert(opening < emitter.tokens.len);
    assert(is_open(emitter.raw[opening]));

    const comment = emitter.rider(opening) orelse return 0;
    const lexeme = emitter.tokens[comment];
    if (pragmatic(lexeme.text(emitter.source))) return 0;
    const returned = comment_gap_columns + columns(emitter.source, lexeme.offset, lexeme.end());

    assert(returned < std.math.maxInt(u32));

    return returned;
}

pub fn iterable_wraps(emitter: *const Emitter, in_at: u32) bool {
    assert(in_at < emitter.tokens.len);
    assert(emitter.raw[in_at] == .in_keyword);

    const for_at = loop_keyword(emitter) orelse return false;
    if (emitter.wrap_end(for_at) != in_at) return false;

    const colon = header_colon(emitter, in_at) orelse return false;
    const from = emitter.next_token(in_at, colon) orelse return false;
    const last = emitter.prior_token(colon, in_at) orelse return false;
    const prefix = iterable_prefix(emitter, for_at, in_at) orelse return false;
    const line = prefix + emitter.measured(from, colon) + comment_columns(emitter, colon);
    if (line <= emitter.line_width) return false;

    if (opening_of(emitter, from, colon)) |opening| {
        if (prefix + emitter.measured(from, opening) <= emitter.line_width) return false;
    }

    const flat = emitter.indent * emitter.indent_width;
    return flat + emitter.indent_width + emitter.measured(from, last) <= emitter.line_width;
}

fn loop_keyword(emitter: *const Emitter) ?u32 {
    const at = emitter.line_first_at orelse return null;
    const count: u32 = @intCast(emitter.tokens.len);
    const keyword = if (emitter.raw[at] == .async_keyword) emitter.next_token(at, count) else at;
    const for_at = keyword orelse return null;
    if (emitter.raw[for_at] != .for_keyword) return null;
    return for_at;
}

fn iterable_prefix(emitter: *const Emitter, for_at: u32, in_at: u32) ?u32 {
    assert(for_at < in_at);
    assert(emitter.raw[in_at] == .in_keyword);

    const at = emitter.line_first_at orelse return null;
    const flat = emitter.indent * emitter.indent_width;
    const closing = flat + target_closing_columns;
    const first = emitter.next_token(for_at, in_at) orelse return null;
    const last = emitter.prior_token(in_at, for_at) orelse return null;
    const enclosed = emitter.raw[first] == .paren_open and emitter.closed_at(first) == last;

    if (enclosed) {
        if (target_kept(emitter, first, last)) {
            assert(closing < std.math.maxInt(u32));

            return closing;
        }
    } else {
        if (emitter.tupled_line(for_at + 1, in_at)) {
            assert(closing < std.math.maxInt(u32));

            return closing;
        }

        if (target_breaking(emitter, first, last, in_at, 0) != null) {
            assert(closing < std.math.maxInt(u32));

            return closing;
        }
    }

    const inner = if (enclosed) first + 1 else first;
    var start = at;
    var scan = inner;

    for (0..bracket_depth_max) |_| {
        const opening = opening_of(emitter, scan, in_at) orelse break;
        const close = emitter.closed_at(opening) orelse return null;

        assert(close < in_at);

        start = close;
        scan = close + 1;
    }

    const unmoved = enclosed and start == at;
    const dropped: u32 = if (unmoved) enclosing_columns else 0;
    const returned = flat + (emitter.measured(start, in_at) -| dropped) + 1;

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn opening_of(emitter: *const Emitter, from: u32, end: u32) ?u32 {
    assert(from <= end);
    assert(end < emitter.tokens.len);

    var scan = from;

    while (scan < end) : (scan += 1) {
        const kind = emitter.raw[scan];

        if (kind == .f_string_start) {
            scan = emitter.format_end(scan);

            continue;
        }

        if (!is_open(kind)) continue;

        const inner = emitter.next_token(scan, end) orelse return null;
        if (!is_close(emitter.raw[inner])) return scan;
    }

    return null;
}

fn header_colon(emitter: *const Emitter, in_at: u32) ?u32 {
    assert(in_at < emitter.tokens.len);
    assert(emitter.raw[in_at] == .in_keyword);

    const count: u32 = @intCast(emitter.tokens.len);
    var depth: u32 = 0;
    var scan = in_at + 1;

    while (scan < count) : (scan += 1) {
        const kind = emitter.raw[scan];
        if (kind == .comment) return null;
        if (kind == .newline) return null;

        if (is_open(kind)) depth += 1;
        if (is_close(kind)) depth -|= 1;

        if (depth == 0) {
            if (kind == .colon) {
                assert(scan <= emitter.tokens.len);

                return scan;
            }
        }
    }

    return null;
}

pub fn unwraps_comment(emitter: *const Emitter, open_at: u32, close_at: u32) bool {
    assert(open_at < close_at);
    assert(close_at < emitter.tokens.len);

    const comment = emitter.prior_token(close_at, open_at) orelse return false;
    if (emitter.raw[comment] != .comment) return false;

    const first = emitter.next_token(open_at, comment) orelse return false;
    const last = emitter.prior_token(comment, open_at) orelse return false;
    const gap = emitter.source[emitter.tokens[last].end()..emitter.tokens[comment].offset];
    if (std.mem.findScalar(u8, gap, '\n') != null) return false;

    for (first..comment) |scan| {
        if (emitter.raw[scan] == .comment) return false;
    }

    const at = emitter.line_first_at orelse return false;
    const lexeme = emitter.tokens[comment];
    const pragma = pragmatic(lexeme.text(emitter.source));
    const commented = comment_gap_columns + columns(emitter.source, lexeme.offset, lexeme.end());
    const tail = if (pragma) 0 else commented;
    const head = emitter.indent * emitter.indent_width + emitter.measured(at, open_at - 1);
    const body = emitter.measured(first, last) + tail;
    const nested = (emitter.indent + 1) * emitter.indent_width + body;
    const flat = head + 1 + body;
    const fits = flat <= emitter.line_width;
    const kind = emitter.raw[first];
    if (is_open(kind)) return fits and emitter.closed_at(first) == last;

    if (!fits) {
        if (nested <= emitter.line_width) return false;
    }

    if (first == last) return atomic(kind);
    if (!is_string_start(kind)) return false;

    var scan = first;

    for (first..comment) |_| {
        if (scan > last) break;

        const held = emitter.raw[scan];

        if (!is_layout(held)) {
            if (!is_string_start(held)) return false;

            if (held == .f_string_start) scan = emitter.format_end(scan);
        }

        scan += 1;
    }

    if (scan != last + 1) return false;
    if (emitter.part_end(first) == last) return true;
    return emitter.joins(first);
}

fn atomic(kind: Kind) bool {
    assert(kind.is_token());

    return switch (kind) {
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

pub fn lambda_enclosed(emitter: *const Emitter, position: u32, kind: Kind) bool {
    assert(position < emitter.tokens.len);
    assert(emitter.raw[position] == kind);

    const count: u32 = @intCast(emitter.tokens.len);
    const open_at = emitter.next_token(position, count) orelse return false;
    if (emitter.raw[open_at] != .paren_open) return false;

    const close_at = emitter.closed_at(open_at) orelse return false;
    const end = emitter.wrap_end(position);
    if (emitter.prior_token(end, position) != close_at) return false;
    return lambda_header(emitter, open_at, .paren_open) == emitter.prior_token(close_at, open_at);
}

pub fn lambda_header(emitter: *const Emitter, position: u32, kind: Kind) ?u32 {
    assert(position < emitter.tokens.len);
    assert(emitter.raw[position] == kind);

    switch (kind) {
        .assert_keyword,
        .comma,
        .elif_keyword,
        .if_keyword,
        .in_keyword,
        .paren_open,
        .while_keyword,
        => {},
        else => return null,
    }

    if (kind != .paren_open) {
        if (emitter.depth > 0) return null;
    }

    const count: u32 = @intCast(emitter.tokens.len);
    const lambda_at = emitter.next_token(position, count) orelse return null;
    if (emitter.raw[lambda_at] != .lambda_keyword) return null;

    var depth: u32 = 0;
    var colon = lambda_at + 1;

    while (colon < count) : (colon += 1) {
        const held = emitter.raw[colon];
        if (held == .newline) return null;

        if (depth == 0) {
            if (held == .colon) break;
        }

        if (is_open(held)) depth += 1;
        if (is_close(held)) depth -|= 1;
    }

    if (colon == count) return null;

    const end = if (kind == .paren_open)
        emitter.closed_at(position) orelse return null
    else
        emitter.wrap_end_from(colon + 1, kind);

    if (end <= colon + 1) return null;

    const spans = spanned.lambda_spans(emitter, lambda_at, end);

    if (!spans) {
        if (kind == .paren_open) return null;
        if (!header_overflows(emitter, end)) return null;
    }

    return emitter.prior_token(end, lambda_at);
}

fn header_overflows(emitter: *const Emitter, end: u32) bool {
    assert(end <= emitter.tokens.len);
    assert(emitter.tokens.len == emitter.raw.len);

    const at = emitter.line_first_at orelse return false;

    if (end == emitter.tokens.len) return false;

    const flat = emitter.indent * emitter.indent_width;
    const comment = if (emitter.raw[end] == .colon) comment_columns(emitter, end) else 0;

    return flat + emitter.measured(at, end) + comment > emitter.line_width;
}

pub fn continues(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.tokens.len);
    assert(emitter.tokens.len == emitter.raw.len);

    const kind = emitter.raw[position];
    const named = kind == .global_keyword or kind == .nonlocal_keyword;
    if (!named) return false;
    if (emitter.line_first_at != position) return false;

    const count: u32 = @intCast(emitter.tokens.len);
    const keyword = emitter.tokens[position];

    var width = emitter.indent * emitter.indent_width +
        columns(emitter.source, keyword.offset, keyword.end());

    for (position + 1..count) |scan| {
        const lexeme = emitter.tokens[scan];

        switch (emitter.raw[scan]) {
            .identifier => width += 1 + columns(emitter.source, lexeme.offset, lexeme.end()),
            .comma => width += 1,
            .comment => return false,
            else => break,
        }
    }

    return width > emitter.line_width;
}

pub fn wrap_pattern(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.tokens.len);
    assert(emitter.raw[position] == .identifier);

    if (emitter.wrap != null) return;
    if (emitter.depth > 0) return;
    if (emitter.line_first_at != position) return;

    const bytes = emitter.tokens[position].text(emitter.source);

    if (std.mem.eql(u8, bytes, "match")) {
        if (!soft_header(emitter, position)) return;
        return wrap_subject(emitter, position);
    }

    if (!std.mem.eql(u8, bytes, "case")) return;

    const end = pattern_end(emitter, position) orelse return;
    if (end == position + 1) return;

    if (emitter.listed_line(position + 1, end)) {
        if (!emitter.wraps_wide(end)) return;
        return emitter.wrapping(position + 1, null, end, true, true, false);
    }

    const contents = emitter.contents_from(position + 1, end) orelse return;
    if (!contents.held) return;
    if (contents.commented) return;
    if (!emitter.wrap_rides(end)) return;

    if (!pattern_expands(emitter, position + 1, end)) {
        if (emitter.omits(position, emitter.bound_from(position + 1, end), null)) return;
    }

    return emitter.wrapping(position + 1, null, end, false, false, false);
}

pub fn cased(emitter: *const Emitter) bool {
    assert(emitter.tokens.len == emitter.raw.len);

    if (emitter.line_first != .identifier) return false;

    const at = emitter.line_first_at orelse return false;
    const bytes = emitter.tokens[at].text(emitter.source);

    return std.mem.eql(u8, bytes, "case");
}

pub fn pattern_expands(emitter: *const Emitter, from: u32, end: u32) bool {
    assert(from <= end);
    assert(end <= emitter.tokens.len);

    if (!pattern_alternates(emitter, from, end)) return false;
    return !pattern_omittable(emitter, from, end);
}

fn pattern_alternates(emitter: *const Emitter, from: u32, end: u32) bool {
    assert(from <= end);
    assert(end <= emitter.tokens.len);

    var depth: u32 = 0;

    for (from..end) |scan| {
        const kind = emitter.raw[scan];

        if (depth == 0) {
            if (kind == .bar) return true;
            if (kind == .as_keyword) return true;
        }

        if (is_open(kind)) depth += 1;
        if (is_close(kind)) depth -|= 1;
    }

    return false;
}

fn pattern_omittable(emitter: *const Emitter, from: u32, end: u32) bool {
    assert(from <= end);
    assert(end <= emitter.tokens.len);

    var bars: u32 = 0;
    var bracketed = false;
    var depth: u32 = 0;
    var end_first: ?u32 = null;
    var end_last = end;
    var start_last = from;

    for (from..end) |index| {
        const scan: u32 = @intCast(index);
        const kind = emitter.raw[scan];

        if (depth == 0) {
            const parted = kind == .bar or kind == .as_keyword;

            if (is_open(kind)) bracketed = true;

            if (parted) {
                if (end_first == null) end_first = scan;
            }

            if (kind == .bar) {
                bars += 1;
                start_last = scan + 1;
            }

            if (kind == .as_keyword) end_last = scan;
        }

        if (is_open(kind)) depth += 1;
        if (is_close(kind)) depth -|= 1;
    }

    if (!bracketed) return false;
    if (bars > 1) return false;

    const first = pattern_bracketed(emitter, from, end_first orelse end);
    return first or pattern_bracketed(emitter, start_last, end_last);
}

fn pattern_bracketed(emitter: *const Emitter, from: u32, end: u32) bool {
    assert(from <= end);
    assert(end <= emitter.tokens.len);

    var last = end;

    while (last > from) {
        last -= 1;

        if (!is_layout(emitter.raw[last])) break;
    } else return false;

    if (!is_close(emitter.raw[last])) return false;

    const open_at = emitter.opened_at(last) orelse return false;
    return open_at + 1 < last;
}

fn wrap_subject(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.tokens.len);
    assert(emitter.raw[position] == .identifier);

    const end = emitter.wrap_end(position);
    if (end == position + 1) return;

    const tuple = emitter.tupled_line(position + 1, end);

    if (!tuple) {
        if (!emitter.wraps(position, false)) return;
    }

    const sole = emitter.listed_line(position + 1, end);
    return emitter.wrapping(position + 1, .return_keyword, end, sole, tuple, false);
}

fn pattern_end(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.tokens.len);
    assert(emitter.raw[position] == .identifier);

    const count: u32 = @intCast(emitter.tokens.len);
    var depth: u32 = 0;
    var scan = position + 1;

    while (scan < count) : (scan += 1) {
        const kind = emitter.raw[scan];
        if (kind == .newline) return null;

        if (is_open(kind)) depth += 1;
        if (is_close(kind)) depth -|= 1;

        const ends = kind == .colon or kind == .if_keyword;

        if (depth == 0) {
            if (ends) {
                assert(scan <= emitter.tokens.len);

                return scan;
            }
        }
    }

    return null;
}

pub fn annotates_return(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.tokens.len);
    assert(emitter.depth <= bracket_depth_max);

    const floor = emitter.line_first_at orelse return false;
    var depth: u32 = 0;
    var scan = position;

    while (scan > floor) {
        scan -= 1;

        const kind = emitter.raw[scan];

        if (is_close(kind)) depth += 1;
        if (is_open(kind)) depth -|= 1;

        if (depth == 0) {
            if (kind == .arrow) return true;
        }
    }

    return false;
}

pub fn guards(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.tokens.len);
    assert(emitter.depth <= bracket_depth_max);

    if (emitter.depth > 0) return false;
    if (emitter.raw[position] != .if_keyword) return false;
    return cased(emitter);
}

pub fn names_walrus(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.tokens.len);
    assert(emitter.tokens.len == emitter.raw.len);

    if (emitter.walrus) return false;
    if (emitter.raw[position] != .identifier) return false;

    if (emitter.depth == 0) {
        if (emitter.wrap == null) return false;
    }

    const count: u32 = @intCast(emitter.tokens.len);
    const after = emitter.next_token(position, count) orelse return false;

    return emitter.raw[after] == .colon_equal;
}

pub fn returns_bare(emitter: *const Emitter, arrow_at: u32) bool {
    assert(arrow_at < emitter.tokens.len);
    assert(emitter.raw[arrow_at] == .arrow);

    const closing = emitter.prior_token(arrow_at, 0) orelse return false;
    if (emitter.raw[closing] != .paren_close) return false;

    const opening = emitter.prior_token(closing, 0) orelse return false;
    return emitter.raw[opening] == .paren_open;
}

pub fn returns_split(emitter: *const Emitter, open_at: u32, last: u32, dropped: ?u32) bool {
    assert(open_at < last);
    assert(last < emitter.tokens.len);

    if (!is_close(emitter.raw[last])) return false;
    if (dropped) |held| assert(held < emitter.tokens.len);

    const opening = emitter.opened_at(last) orelse return false;
    if (emitter.prior_token(last, open_at) == opening) return false;
    return emitter.omits_width(open_at, opening, dropped, 0);
}

pub fn returns_wrap(emitter: *const Emitter, arrow_at: u32, bound: u32) bool {
    assert(arrow_at < bound);
    assert(emitter.raw[arrow_at] == .arrow);

    const first = emitter.next_token(arrow_at, bound) orelse return false;
    const last = emitter.prior_token(bound, arrow_at) orelse return false;
    const enclosed = emitter.raw[first] == .paren_open and emitter.closed_at(first) == last;
    if (enclosed) return false;
    if (returns_operated(emitter, first, last + 1)) return true;
    if (returns_bare(emitter, arrow_at)) return !returns_split(emitter, arrow_at, last, null);
    return returns_fitted(emitter, first, last, last + 1);
}

pub fn returns_fitted(emitter: *const Emitter, first: u32, last: u32, rest: u32) bool {
    assert(first <= last);
    assert(last < rest);

    for (first..last + 1) |position| {
        const kind = emitter.raw[position];
        if (is_open(kind)) return false;
        if (kind == .f_string_start) return false;
    }

    const flat = emitter.indent * emitter.indent_width;
    const inner = flat + emitter.indent_width + emitter.measured(first, last);
    const closing = flat + paren_columns + line_rest(emitter, rest);

    return inner <= emitter.line_width and closing <= emitter.line_width;
}

pub fn returns_operated(emitter: *const Emitter, first: u32, end: u32) bool {
    assert(first < end);
    assert(end <= emitter.tokens.len);

    const split = emitter.splits_from(first, end);
    if (split.found <= priority_dot) return false;
    if (split.count > 1) return true;

    const last = emitter.prior_token(end, first) orelse first;
    if (operand_parenthesized(emitter, last)) return false;
    return !parenthesized_first(emitter, first, end);
}

pub fn parenthesized_first(emitter: *const Emitter, first: u32, end: u32) bool {
    assert(first < end);
    assert(end <= emitter.tokens.len);

    const kind = emitter.raw[first];
    if (!is_open(kind)) return false;
    if (!emitter.filled(first, end)) return false;
    if (kind != .paren_open) return true;

    const closing = emitter.closed_at(first) orelse return false;
    return !power.subscript_parenthesized(emitter, first, closing);
}

pub fn left_first(emitter: *const Emitter, equal_at: u32, close_at: u32) bool {
    assert(equal_at < close_at);
    assert(close_at <= emitter.tokens.len);

    var prefixes: u32 = 0;
    var atom: ?Kind = null;
    var dotted = false;

    for (equal_at + 1..close_at) |position| {
        const kind = emitter.raw[position];
        const skipped = is_layout(kind) or kind == .comment or emitter.tokens[position].length == 0;
        if (skipped) continue;
        if (kind == .paren_open) continue;
        if (kind == .paren_close) continue;

        if (atom == null) {
            const prefix = kind == .minus or kind == .plus or kind == .tilde or
                kind == .not_keyword or kind == .await_keyword;

            if (prefix) {
                prefixes += 1;

                continue;
            }

            const ellipsis = kind == .ellipsis and prefixes == 0;

            if (!atomic(kind)) {
                if (!ellipsis) return false;
            }

            atom = kind;

            continue;
        }

        const linking = kind == .dot and !dotted and atom.? == .identifier;

        if (linking) {
            dotted = true;

            continue;
        }

        if (kind != .identifier) return false;
        if (!dotted) return false;

        dotted = false;
    }

    const held = atom orelse return false;

    if (dotted) return false;
    if (prefixes == 0) return held == .ellipsis;
    return true;
}

pub fn returns_overlong(emitter: *const Emitter, open_at: u32, close_at: u32) bool {
    assert(open_at < close_at);
    assert(close_at < emitter.tokens.len);

    const flat = emitter.indent * emitter.indent_width;
    const inner = if (open_at + 1 < close_at) emitter.measured(open_at + 1, close_at - 1) else 0;
    const width = flat + returns_opening.len + inner + line_rest(emitter, close_at + 1);

    return width > emitter.line_width;
}

fn line_rest(emitter: *const Emitter, from: u32) u32 {
    assert(from <= emitter.tokens.len);
    assert(emitter.raw.len == emitter.tokens.len);

    const count: u32 = @intCast(emitter.tokens.len);
    var width: u32 = 0;
    var scan = from;

    while (scan < count) : (scan += 1) {
        const kind = emitter.raw[scan];
        const lexeme = emitter.tokens[scan];

        if (kind == .newline) break;
        if (is_layout(kind)) continue;
        if (lexeme.length == 0) continue;

        const bytes = lexeme.text(emitter.source);
        const spelled = columns(emitter.source, lexeme.offset, lexeme.end());

        if (kind == .comment) {
            if (!pragmatic(bytes)) width += comment_gap_columns + spelled;

            break;
        }

        const spaced: u32 = @intFromBool(kind != .colon);

        width += spelled + spaced;
    }

    return width;
}

fn operand_parenthesized(emitter: *const Emitter, last: u32) bool {
    assert(last < emitter.tokens.len);
    assert(emitter.raw.len == emitter.tokens.len);

    const kind = emitter.raw[last];
    if (!is_close(kind)) return false;

    const opening = emitter.opened_at(last) orelse return false;

    const called = if (emitter.prior_token(opening, 0)) |before|
        ends_operand(emitter.raw[before])
    else
        false;

    if (kind == .bracket_close) return !called;
    if (kind != .paren_close) return true;
    if (called) return true;
    return !power.subscript_parenthesized(emitter, opening, last);
}

pub fn soft_headed(emitter: *const Emitter) bool {
    assert(emitter.tokens.len == emitter.raw.len);

    const at = emitter.at_previous orelse return false;
    const first = emitter.line_first_at orelse return false;
    if (first >= at) return false;
    if (!soft_header(emitter, first)) return false;

    for (first + 1..at) |scan| {
        const kind = emitter.raw[scan];
        if (is_layout(kind)) continue;
        if (kind != .paren_open) return false;
    }

    return true;
}

pub fn annotation_colon(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.tokens.len);
    assert(emitter.raw[position] == .colon);

    if (emitter.depth > 0) return false;
    if (emitter.lambdas(position)) return false;

    const at_first = emitter.line_first_at orelse return false;
    const first = emitter.raw[at_first];

    if (at_first >= position) return false;
    if (opens_suite(first)) return false;
    if (first == .lambda_keyword) return false;

    if (at_first + 1 != position) {
        if (soft_header(emitter, at_first)) return false;
    }

    return true;
}

pub fn with_target(emitter: *const Emitter, position: u32, end: u32, dropped: ?u32) ?bool {
    assert(position < end);
    assert(end <= emitter.tokens.len);
    if (dropped) |held| assert(held < emitter.tokens.len);

    var as_at: ?u32 = null;
    var bracketed = false;
    var depth: u32 = 0;
    var scan = position + 1;

    while (scan < end) : (scan += 1) {
        const kind = emitter.raw[scan];

        if (is_open(kind)) {
            if (as_at == null) bracketed = true;

            depth += 1;
        }

        if (is_close(kind)) depth -|= 1;
        if (depth > 0) continue;
        if (kind == .comma) return null;

        if (kind == .as_keyword) as_at = scan;
    }

    const held = as_at orelse return null;
    if (held == position + 1) return null;
    if (!bracketed) return false;

    const last = emitter.prior_token(held, position) orelse return false;
    if (!is_close(emitter.raw[last])) return false;

    const opener = emitter.opened_at(last) orelse return false;
    const floor = emitter.line_first_at orelse return false;
    const paren: u32 = @intFromBool(dropped != null);
    const head = emitter.indent * emitter.indent_width + emitter.measured(floor, opener) - paren;

    return head <= emitter.line_width or shortcuts(emitter, position, opener, dropped);
}

pub fn owned_target(emitter: *const Emitter, open_at: u32) bool {
    assert(open_at < emitter.tokens.len);
    assert(emitter.depth <= bracket_depth_max);

    if (emitter.depth > 0) return false;

    const floor = emitter.line_first_at orelse return false;
    var equal_at = open_at;

    if (emitter.raw[open_at] == .paren_open) {
        equal_at = emitter.prior_token(open_at, floor) orelse return false;
    }

    if (emitter.raw[equal_at] != .equal) return false;
    if (annotates(emitter, equal_at)) return false;

    const last = emitter.prior_token(equal_at, floor) orelse return false;
    if (emitter.raw[last] != .bracket_close) return false;

    const opening = emitter.opened_at(last) orelse return false;
    var depth: u32 = 0;
    var scan = floor;

    while (scan < opening) : (scan += 1) {
        const kind = emitter.raw[scan];

        if (is_open(kind)) depth += 1;
        if (is_close(kind)) depth -|= 1;
        if (depth > 0) continue;
        if (is_open(kind)) continue;

        const primary = kind == .dot or kind == .identifier or is_close(kind);
        if (!primary) return false;
    }

    return strung_once(emitter, equal_at);
}

fn strung_once(emitter: *const Emitter, equal_at: u32) bool {
    assert(equal_at < emitter.tokens.len);
    assert(emitter.raw[equal_at] == .equal);

    const count: u32 = @intCast(emitter.tokens.len);
    var strings: u32 = 0;
    var scan = equal_at + 1;

    while (scan < count) : (scan += 1) {
        const kind = emitter.raw[scan];
        if (kind == .newline) break;
        if (kind == .semicolon) break;
        if (kind == .equal) return false;

        if (kind == .f_string_start) scan = emitter.format_end(scan);
        if (is_string_start(kind)) strings += 1;
    }

    return strings <= 1;
}

pub fn annotates(emitter: *const Emitter, equal_at: u32) bool {
    assert(equal_at < emitter.tokens.len);
    assert(emitter.raw[equal_at] == .equal);

    const floor = emitter.line_first_at orelse return false;
    var depth: u32 = 0;
    var scan = equal_at;

    while (scan > floor) {
        scan -= 1;

        const kind = emitter.raw[scan];

        if (is_close(kind)) depth += 1;
        if (is_open(kind)) depth -|= 1;
        if (depth > 0) continue;
        if (kind == .colon) return annotation_colon(emitter, scan);
    }

    return false;
}

pub fn annotated_wrap(emitter: *const Emitter, position: u32, kind: Kind) ?u32 {
    assert(position < emitter.tokens.len);
    assert(emitter.raw[position] == kind);

    if (kind != .colon) return null;
    if (!annotation_colon(emitter, position)) return null;

    const equal_at = annotation_end(emitter, position) orelse return null;
    if (equal_at == position + 1) return null;
    if (emitter.splits_from(position + 1, equal_at).found <= priority_dot) return null;
    if (emitter.omits(position, equal_at, null)) return null;
    return equal_at;
}

fn annotation_end(emitter: *const Emitter, colon: u32) ?u32 {
    assert(colon < emitter.tokens.len);
    assert(emitter.raw[colon] == .colon);

    const count: u32 = @intCast(emitter.tokens.len);
    var depth: u32 = 0;
    var scan = colon + 1;

    while (scan < count) : (scan += 1) {
        const kind = emitter.raw[scan];
        if (kind == .newline) return null;
        if (kind == .semicolon) return null;
        if (kind == .comment) return null;

        if (is_open(kind)) depth += 1;
        if (is_close(kind)) depth -|= 1;
        if (depth > 0) continue;

        if (kind == .equal) {
            assert(scan <= emitter.tokens.len);

            return scan;
        }
    }

    return null;
}

pub fn annotation_only(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.tokens.len);
    assert(emitter.raw[position] == .colon);

    if (!annotation_colon(emitter, position)) return false;

    const count: u32 = @intCast(emitter.tokens.len);
    var depth: u32 = 0;
    var scan = position + 1;

    while (scan < count) : (scan += 1) {
        const kind = emitter.raw[scan];
        if (kind == .newline) return true;
        if (kind == .semicolon) return true;

        if (is_open(kind)) depth += 1;
        if (is_close(kind)) depth -|= 1;
        if (depth > 0) continue;
        if (kind == .equal) return false;
    }

    return true;
}

pub fn soft_header(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.tokens.len);
    assert(emitter.tokens.len == emitter.raw.len);

    if (emitter.raw[position] != .identifier) return false;
    if (emitter.line_first_at != position) return false;

    const bytes = emitter.tokens[position].text(emitter.source);
    const soft = std.mem.eql(u8, bytes, "case") or std.mem.eql(u8, bytes, "match");
    if (!soft) return false;

    const end = emitter.wrap_end_from(position + 1, null);
    return end < emitter.tokens.len and emitter.raw[end] == .colon;
}

pub fn shortcuts(emitter: *const Emitter, open_at: u32, opening: u32, dropped: ?u32) bool {
    assert(open_at < emitter.tokens.len);
    assert(opening < emitter.tokens.len);
    if (dropped) |held| assert(held < emitter.tokens.len);

    var seen = false;
    var scan = open_at + 1;

    while (scan < opening) : (scan += 1) {
        const kind = emitter.raw[scan];

        if (kind == .f_string_start) {
            scan = emitter.format_end(scan);

            continue;
        }

        if (!is_open(kind)) continue;
        if (emitter.drops(scan, dropped)) continue;
        if (emitter.tokens[scan].length == 0) continue;

        const next = emitter.next_token(scan, opening) orelse opening;
        if (!is_close(emitter.raw[next])) return true;

        seen = true;
    }

    return seen and uniform(emitter, open_at + 1, opening);
}

pub fn single_target(emitter: *const Emitter, for_at: u32) ?u32 {
    assert(for_at < emitter.tokens.len);
    assert(emitter.raw[for_at] == .for_keyword);

    const count: u32 = @intCast(emitter.tokens.len);
    var separator_at: ?u32 = null;
    var depth: u32 = 0;
    var last = for_at;
    var scan = for_at + 1;

    while (scan < count) : (scan += 1) {
        const kind = emitter.raw[scan];
        if (is_layout(kind)) return null;
        if (kind == .comment) return null;

        if (depth == 0) {
            if (kind == .in_keyword) break;
            if (is_close(kind)) return null;
        }

        if (is_open(kind)) depth += 1;
        if (is_close(kind)) depth -= 1;

        if (depth == 0) {
            if (kind == .comma) {
                if (separator_at != null) return null;

                separator_at = scan;
            }
        }

        last = scan;
    }

    if (scan == count) return null;

    const held = separator_at orelse return null;
    return if (last == held) held else null;
}

fn uniform(emitter: *const Emitter, from: u32, end: u32) bool {
    assert(from <= end);
    assert(end <= emitter.tokens.len);

    var depth: u32 = 0;
    var level: u8 = 0;
    var held: Splits = .new();
    var previous: ?Kind = null;

    for (from..end) |scan| {
        const kind = emitter.raw[scan];
        if (is_layout(kind)) continue;
        if (kind == .comment) continue;

        if (is_close(kind)) depth -|= 1;

        if (depth == 0) {
            const priority = held.step(kind, previous);
            const split = priority > priority_dot;

            if (split) {
                const mixed = level > 0 and priority != level;
                if (mixed) return false;

                level = priority;
            }
        }

        depth += @intFromBool(is_open(kind));
        previous = kind;
    }

    return level != priority_logic;
}

pub fn ridden(emitter: *const Emitter, position: u32) u8 {
    assert(position < emitter.tokens.len);
    assert(emitter.raw[position] == .comment);

    const next = emitter.part_after(position) orelse return 0;
    if (emitter.raw[next] != .not_keyword) return emitter.interruption(next);

    const operand = emitter.part_before(next) orelse return 0;
    return kind_parted(.not_keyword, emitter.raw[operand]);
}

pub fn comment_inside(emitter: *const Emitter, comment: u32, head: ?Kind) bool {
    assert(comment < emitter.tokens.len);
    assert(emitter.tokens.len == emitter.raw.len);

    if (head != .lambda_keyword) return false;
    if (emitter.raw[comment] != .comment) return false;

    const prior = emitter.prior_token(comment, 0) orelse return false;
    if (emitter.raw[prior] == .colon) return false;

    const count: u32 = @intCast(emitter.tokens.len);
    var scan = comment + 1;

    while (scan < count) : (scan += 1) {
        const kind = emitter.raw[scan];
        if (kind == .comment) continue;
        if (is_layout(kind)) return false;

        const forward = kind == .async_keyword and emitter.next_kind(scan) == .for_keyword;
        const clause = kind == .for_keyword or forward;

        return !wrap_end_stops(head, kind, clause, 2);
    }

    return false;
}

pub fn comments_body(emitter: *const Emitter, colon: u32, end: u32) bool {
    assert(colon < end);
    assert(end <= emitter.tokens.len);

    var depth: u32 = 0;
    var scan = colon + 1;

    while (scan < end) : (scan += 1) {
        const kind = emitter.raw[scan];

        if (is_open(kind)) depth += 1;
        if (is_close(kind)) depth -|= 1;
        if (depth > 0) continue;
        if (kind != .comment) continue;
        if (comment_inside(emitter, scan, .lambda_keyword)) return true;
    }

    return false;
}
