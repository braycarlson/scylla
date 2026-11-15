const std = @import("std");
const assert = std.debug.assert;
const Emitter = @import("../python.zig").Emitter;
const Kind = @import("../python.zig").Kind;
const Targets = @import("../python.zig").Targets;
const blank_between = @import("blank.zig").between;
const bracket_depth_max = @import("../python.zig").bracket_depth_max;
const columns = @import("../walk.zig").columns;
const docstrings = @import("docstring.zig");
const elides_after = @import("../python.zig").elides_after;
const ends_line = @import("../python.zig").ends_line;
const is_augmented = @import("../python.zig").is_augmented;
const is_close = @import("../python.zig").is_close;
const is_layout = @import("../python.zig").is_layout;
const is_open = @import("../python.zig").is_open;
const is_string_start = @import("../python.zig").is_string_start;
const joined_head = @import("../python.zig").joined_head;
const joined_tail = @import("../python.zig").joined_tail;
const onset = @import("onset.zig");
const priority_dot = @import("../python.zig").priority_dot;
const quoted_body_length = @import("literal.zig").quoted_body_length;
const relettered_length = @import("literal.zig").relettered_length;
const spanned = @import("spanned.zig");

const Closing = struct {
    close_at: u32,
    first: u32,
    held: Kind,
    overlong: bool,
    plain: bool,
    position: u32,
};

const RunColumns = struct {
    columns: u32,
    last: u32,
};

const message_opening = ", (";

fn joined_columns(emitter: *const Emitter, position: u32, end: u32) u32 {
    assert(position < end);
    assert(end < emitter.raw.len);

    const marks = emitter.marks_of(position, end).?;
    const quote = emitter.join_quote(position, end, marks.format).?;
    var width: u32 = 2 + @as(u32, @intFromBool(marks.bytes)) + @intFromBool(marks.format);
    var scan = position;

    while (scan <= end) {
        const last = emitter.part_end(scan).?;
        const offset = emitter.tokens[scan].offset;
        const text_first = emitter.tokens[scan].text(emitter.source);
        const text_last = emitter.tokens[last].text(emitter.source);
        const opens = joined_head(emitter.raw[scan], text_first).?;
        const closes = joined_tail(emitter.raw[last], text_last);
        const spelled = columns(emitter.source, offset, emitter.tokens[last].end());

        width += spelled -| (opens + closes);

        if (emitter.raw[scan] != .f_string_start) {
            const body = text_first[opens .. text_first.len - closes];
            const length: u32 = @intCast(body.len);

            width = (width + quoted_body_length(body, quote, !marks.bytes)) -| length;
        }

        scan = last + 1;
    }

    assert(width < std.math.maxInt(u32));

    return width;
}

pub fn line_columns(emitter: *const Emitter, close_at: u32) u32 {
    assert(close_at < emitter.tokens.len);
    assert(emitter.raw[close_at] == .paren_close);

    const count: u32 = @intCast(emitter.tokens.len);
    var scan = emitter.line_first_at orelse return std.math.maxInt(u32);
    var depth: u32 = 0;
    var held: ?Kind = null;
    var width = emitter.indent * emitter.indent_width;

    while (scan < count) : (scan += 1) {
        const kind = emitter.raw[scan];
        const lexeme = emitter.tokens[scan];

        if (ends_line(kind)) break;

        if (kind == .comment) {
            width += columns(emitter.source, lexeme.offset, lexeme.end()) + 2;

            break;
        }

        const separated = scan > close_at and depth == 0 and kind == .comma;

        if (separated) {
            if (emitter.line_first == .assert_keyword) width += message_opening.len;

            break;
        }

        if (is_open(kind)) depth += 1;
        if (is_close(kind)) depth -|= 1;

        const skipped = emitter.drops(scan, null) or is_layout(kind) or lexeme.length == 0;
        if (skipped) continue;

        const bytes = lexeme.text(emitter.source);
        const headed = depth == 0 and kind == .colon;
        const blanking = if (held) |prior| blank_between(emitter, prior, scan) else false;
        const blank = blanking and !headed;

        if (is_string_start(kind)) {
            if (run_columns(emitter, scan)) |strung| {
                width += strung.columns + @intFromBool(blank);
                held = emitter.raw[strung.last];
                scan = strung.last;

                continue;
            }
        }

        if (std.mem.findScalar(u8, bytes, '\n')) |at| {
            if (emitter.tails_line(scan)) {
                width += @as(u32, @intCast(at)) + @intFromBool(blank);

                break;
            }
        }

        width += columns(emitter.source, lexeme.offset, lexeme.end()) + @intFromBool(blank);
        held = kind;
    }

    assert(width < std.math.maxInt(u32));

    return width -| 2;
}

fn element_columns(emitter: *const Emitter, open_at: u32, close_at: u32) u32 {
    assert(open_at < close_at);
    assert(emitter.depth > 0);

    const first = element_first(emitter, open_at);
    const indent = (emitter.indent + emitter.depth) * emitter.indent_width;
    const after = emitter.next_kind(close_at);
    const trailed: u32 = @intFromBool(after == .comma);
    const returned = (indent + emitter.measured(first, close_at) + trailed) -| 2;

    assert(returned < std.math.maxInt(u32));

    return returned;
}

pub fn element_first(emitter: *const Emitter, position: u32) u32 {
    assert(position < emitter.raw.len);
    assert(emitter.raw.len == emitter.tokens.len);

    var depth: u32 = 0;
    var scan = position;
    var from: u32 = emitter.line_first_at orelse 0;

    while (scan > from) {
        scan -= 1;

        const kind = emitter.raw[scan];

        if (is_close(kind)) depth += 1;

        if (is_open(kind)) {
            if (depth == 0) {
                from = scan + 1;

                break;
            }

            depth -= 1;
        }
    }

    var lambdas: u32 = 0;
    var start = from;

    depth = 0;
    scan = from;

    while (scan < position) : (scan += 1) {
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

    assert(start <= position);

    return start;
}

fn part_columns(emitter: *const Emitter, position: u32) u32 {
    assert(position < emitter.raw.len);
    assert(is_string_start(emitter.raw[position]));

    const last = emitter.part_end(position).?;
    const offset = emitter.tokens[position].offset;
    const end = emitter.tokens[last].end();
    const spelled = columns(emitter.source, offset, end);
    if (emitter.raw[position] == .f_string_start) return spelled;

    const bytes = emitter.source[offset..end];
    const length: u32 = @intCast(bytes.len);
    const returned = (spelled + relettered_length(bytes, emitter.quote)) -| length;

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn run_columns(emitter: *const Emitter, position: u32) ?RunColumns {
    assert(position < emitter.raw.len);
    assert(is_string_start(emitter.raw[position]));

    const end = emitter.concat_end(position) orelse emitter.part_end(position).?;
    var pieces: u32 = 0;
    var widths: u32 = 0;
    var scan = position;

    while (scan <= end) {
        if (emitter.raw[scan] == .newline) {
            scan += 1;

            continue;
        }

        const last = emitter.part_end(scan).?;
        const offset = emitter.tokens[scan].offset;
        const spelling = emitter.source[offset..emitter.tokens[last].end()];
        if (std.mem.findScalar(u8, spelling, '\n') != null) return null;

        widths += part_columns(emitter, scan);
        pieces += 1;
        scan = last + 1;
    }

    assert(pieces > 0);

    if (pieces > 1) {
        if (emitter.joins(position)) {
            return .{ .columns = joined_columns(emitter, position, end), .last = end };
        }
    }

    return .{ .columns = widths + pieces - 1, .last = end };
}

pub fn doubled(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.tokens.len);
    assert(emitter.raw[position] == .paren_open);

    const held = emitter.frame();

    if (emitter.depth == 0) return null;
    if (emitter.previous != .paren_open) return null;
    if (held.call) return null;
    if (held.kind != .paren_open) return null;

    const close_at = elided_close(emitter, position) orelse return null;
    const after = emitter.next_token(close_at, @intCast(emitter.tokens.len)) orelse return null;
    if (emitter.raw[after] != .paren_close) return null;
    if (grouped(emitter, position, close_at)) return null;
    return close_at;
}

pub fn undoubled(emitter: *const Emitter, position: u32, call: bool) u32 {
    assert(position < emitter.tokens.len);
    assert(is_open(emitter.raw[position]));

    const count: u32 = @intCast(emitter.tokens.len);
    var inner = position;
    if (call) return inner;
    if (emitter.raw[position] != .paren_open) return inner;

    for (0..bracket_depth_max) |_| {
        const next = emitter.next_token(inner, count) orelse break;
        if (emitter.raw[next] != .paren_open) break;

        const close_at = elided_close(emitter, next) orelse break;
        const after = emitter.next_token(close_at, count) orelse break;
        if (emitter.raw[after] != .paren_close) break;
        if (grouped(emitter, next, close_at)) break;

        inner = next;
    }

    assert(inner >= position);
    assert(emitter.raw[inner] == emitter.raw[position]);

    return inner;
}

fn grouped(emitter: *const Emitter, open_at: u32, close_at: u32) bool {
    assert(open_at < close_at);
    assert(close_at < emitter.tokens.len);

    if (emitter.next_token(open_at, close_at) == null) return true;

    var depth: u32 = 0;
    var scan = open_at + 1;

    while (scan < close_at) : (scan += 1) {
        const kind = emitter.raw[scan];

        if (is_open(kind)) depth += 1;
        if (is_close(kind)) depth -= 1;

        const separated = kind == .comma or kind == .for_keyword;

        if (depth == 0) {
            if (separated) return true;
        }
    }

    assert(scan == close_at);

    return false;
}

pub fn elidable(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.tokens.len);
    if (emitter.depth > 0) assert(emitter.previous == .colon);

    if (docstrings.parens(emitter, position)) |close_at| return close_at;

    const held = emitter.previous orelse return null;
    const classed = held == .identifier and emitter.line_first == .class_keyword;

    if (classed) {
        if (emitter.at_previous == emitter.line_first_at.? + 1) {
            const class_close = elided_close(emitter, position) orelse return null;
            if (class_close == position + 1) return class_close;
            return null;
        }
    }

    const bodied = held == .colon and emitter.lambdas(emitter.at_previous.?);

    const patterned = held == .identifier and emitter.soft_keyword() and
        onset.soft_header(emitter, emitter.at_previous.?);

    const colon_at = emitter.at_previous.?;

    const annotated = held == .colon and !bodied and emitter.raw[colon_at] == .colon and
        onset.annotation_colon(emitter, colon_at);

    if (!patterned) {
        if (!annotated) {
            if (!elidable_after(emitter, held, bodied)) return null;
        }
    }

    if (held == .if_keyword) {
        if (emitter.line_first != .if_keyword) return null;
    }

    const close_at = elided_close(emitter, position) orelse return null;
    if (!elidable_ended(emitter, held, close_at, bodied)) return null;

    if (held == .await_keyword) {
        if (!emitter.primary_between(position + 1, close_at)) return null;
    }

    return elidable_close(emitter, position, close_at, held);
}

fn elidable_after(emitter: *const Emitter, held: Kind, bodied: bool) bool {
    assert(held.is_token());
    if (bodied) assert(held == .colon);

    if (elides_after(held)) return true;
    if (bodied) return true;

    switch (held) {
        .comma => return emitter.line_first == .assert_keyword,
        .except_keyword, .for_keyword => return true,
        .import_keyword => return emitter.line_first == .from_keyword,
        .in_keyword => {
            const iterated = emitter.line_first == .async_keyword or
                emitter.line_first == .for_keyword;

            return iterated;
        },
        .star => {
            const at = emitter.at_previous.?;
            return at > 0 and emitter.raw[at - 1] == .except_keyword;
        },
        else => return false,
    }
}

fn elidable_ended(emitter: *const Emitter, held: Kind, close_at: u32, bodied: bool) bool {
    assert(close_at < emitter.tokens.len);
    assert(emitter.raw[close_at] == .paren_close);
    assert(held.is_token());

    const after = emitter.next_token(close_at, @intCast(emitter.tokens.len));

    if (after) |at| {
        const elisions = emitter.elided[0..emitter.elisions];
        if (std.mem.findScalar(u32, elisions, at) != null) return true;
    }

    const next = emitter.next_kind(close_at) orelse return true;

    switch (next) {
        .as_keyword, .colon, .comment, .newline, .semicolon => return true,
        .comma => {
            if (emitter.line_first == .assert_keyword) return true;
            return bodied;
        },
        .equal => return held == .equal or held == .colon,
        .if_keyword => return held == .identifier,
        .in_keyword => return held == .for_keyword,
        else => return bodied and is_close(next),
    }
}

fn comments_inside(emitter: *const Emitter, first: u32, close_at: u32) bool {
    assert(first < close_at);
    assert(close_at < emitter.tokens.len);

    for (first..close_at) |position| {
        if (emitter.raw[position] == .comment) return true;
    }

    return false;
}

fn elidable_close(emitter: *const Emitter, position: u32, close_at: u32, held: Kind) ?u32 {
    assert(position < close_at);
    assert(close_at < emitter.tokens.len);
    assert(held.is_token());

    const first = emitter.next_token(position, close_at) orelse return null;
    const assigning = held == .equal or held == .return_keyword or is_augmented(held);

    if (assigning) {
        if (onset.unwraps_comment(emitter, position, close_at)) return close_at;
    }

    const lambdaed = emitter.raw[first] == .lambda_keyword;
    const fitted = assigning and lambdaed;
    const multilined = !fitted and spanned.spans_deep(emitter, position, close_at);

    const spread = if (emitter.depth > 0)
        element_columns(emitter, position, close_at)
    else
        line_columns(emitter, close_at);

    const noted = comments_inside(emitter, first, close_at);
    const overlong = spread > emitter.line_width or multilined or noted;

    const wrapped_message = held == .comma and emitter.wrap != null and
        emitter.messages(position);

    const lambda_loose = lambdaed and !assigning and !wrapped_message;

    if (lambda_loose) {
        if (spanned.lambda_spans(emitter, first, close_at)) return null;
    }

    if (fitted) {
        if (lambda_commented(emitter, first, close_at)) return close_at;
    }

    const closing: Closing = .{
        .close_at = close_at,
        .first = first,
        .held = held,
        .overlong = overlong,
        .plain = !wrapped_message and !fitted,
        .position = position,
    };

    if (kept(emitter, &closing)) return null;
    return elided_tail(emitter, position, close_at, held);
}

fn lambda_commented(emitter: *const Emitter, first: u32, close_at: u32) bool {
    assert(first < close_at);
    assert(emitter.raw[first] == .lambda_keyword);

    var bodied = false;
    var depth: u32 = 0;
    var pending: u32 = 1;
    var commented = false;
    var scan = first + 1;

    while (scan < close_at) : (scan += 1) {
        const kind = emitter.raw[scan];

        if (is_open(kind)) depth += 1;
        if (is_close(kind)) depth -|= 1;
        if (depth > 0) continue;

        switch (kind) {
            .lambda_keyword => pending += 1,
            .colon => {
                if (pending == 0) return false;

                pending -= 1;
                bodied = pending == 0;
            },
            .comma, .for_keyword, .async_keyword => {
                if (bodied) return false;
            },
            .comment => {
                if (!bodied) return false;
                if (!onset.comment_inside(emitter, scan, .lambda_keyword)) return false;

                commented = true;
            },
            else => {},
        }
    }

    return commented;
}

fn kept(emitter: *const Emitter, closing: *const Closing) bool {
    assert(closing.position < closing.close_at);
    assert(closing.first < closing.close_at);

    const position = closing.position;
    const close_at = closing.close_at;
    const held = closing.held;
    const returned = held == .arrow and onset.returns_bare(emitter, emitter.at_previous.?);

    if (held == .arrow) {
        if (!returned) {
            const last = emitter.prior_token(close_at, position) orelse return false;
            const operated = onset.returns_operated(emitter, closing.first, close_at);

            if (!operated) {
                if (last < closing.first) return false;
                if (!onset.returns_fitted(emitter, closing.first, last, close_at + 1)) return false;
            }

            return onset.returns_overlong(emitter, position, close_at);
        }
    }

    if (held == .with_keyword) {
        if (closing.overlong) {
            if (emitter.listed_line(position + 1, close_at)) return true;
        }
    }

    if (held == .for_keyword) return onset.target_kept(emitter, position, close_at);

    if (returned) {
        const inner = emitter.prior_token(close_at, position) orelse return true;

        if (!closing.overlong) return false;
        if (onset.returns_operated(emitter, closing.first, close_at)) return true;
        return !onset.returns_split(emitter, position, inner, position);
    }

    if (!closing.overlong) return false;
    if (!closing.plain) return false;

    if (held == .equal) {
        if (targeted(emitter, closing)) return false;
    }

    if (held == .with_keyword) {
        if (onset.with_target(emitter, position, close_at, position)) |omitted| return !omitted;
    }

    const assigning = held == .equal or held == .return_keyword or is_augmented(held);

    if (assigning) {
        if (!rides(emitter, position, close_at)) return false;
    }

    const expands = held == .identifier and onset.cased(emitter) and
        onset.pattern_expands(emitter, position + 1, close_at);

    const bodied = held == .colon and emitter.lambdas(emitter.at_previous.?);

    const omitted = if (bodied)
        emitter.omits_body(position, close_at, position)
    else
        !expands and emitter.omits(position, close_at, position);

    return !omitted;
}

fn targeted(emitter: *const Emitter, closing: *const Closing) bool {
    assert(closing.position < closing.close_at);
    assert(closing.first < closing.close_at);

    if (emitter.next_kind(closing.close_at) != .equal) return false;

    const last = emitter.prior_token(closing.close_at, closing.position) orelse return false;
    var scan = closing.first;

    while (scan <= last) : (scan += 1) {
        const kind = emitter.raw[scan];

        if (kind != .identifier) {
            if (kind != .dot) return false;
        }
    }

    const floor = emitter.line_first_at orelse return false;
    const final = final_equal(emitter, closing.close_at) orelse return false;
    const width = emitter.indent * emitter.indent_width + emitter.measured(floor, final);

    return width <= emitter.line_width;
}

fn final_equal(emitter: *const Emitter, close_at: u32) ?u32 {
    assert(close_at < emitter.tokens.len);
    assert(emitter.raw.len == emitter.tokens.len);

    const count: u32 = @intCast(emitter.tokens.len);
    var depth: u32 = 0;
    var found: ?u32 = null;
    var scan = close_at + 1;

    while (scan < count) : (scan += 1) {
        const kind = emitter.raw[scan];
        if (ends_line(kind)) break;
        if (kind == .comment) break;

        if (is_open(kind)) depth += 1;
        if (is_close(kind)) depth -|= 1;

        if (depth == 0) {
            if (kind == .equal) found = scan;
        }
    }

    return found;
}

fn rides(emitter: *const Emitter, position: u32, close_at: u32) bool {
    assert(position < close_at);
    assert(close_at < emitter.tokens.len);

    const end = close_at + 1;
    const commented = end < emitter.tokens.len and emitter.raw[end] == .comment;
    if (!commented) return true;
    if (emitter.splits_from(position + 1, close_at).found > priority_dot) return true;
    return emitter.wrap_rides(end);
}

fn elided_tail(emitter: *const Emitter, position: u32, close_at: u32, held: Kind) ?u32 {
    assert(position < close_at);
    assert(close_at < emitter.tokens.len);
    assert(held.is_token());

    const imported = held == .import_keyword and emitter.line_first == .from_keyword;
    const listing = imported or held == .for_keyword or held == .with_keyword;

    if (listing) {
        if (emitter.prior_token(close_at, position)) |last| {
            if (emitter.raw[last] == .comma) return null;
        }
    }

    const headed = held == .elif_keyword or held == .if_keyword or held == .while_keyword;
    const iterated = held == .for_keyword;
    const targets: Targets = if (iterated) .iterated else if (listing) .listed else .none;
    if (!emitter.elided_body(position, close_at, targets, headed)) return null;
    return close_at;
}

fn elided_close(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.tokens.len);
    assert(is_open(emitter.raw[position]));

    const count: u32 = @intCast(emitter.tokens.len);
    var depth: u32 = 0;
    var scan = position;

    while (scan < count) : (scan += 1) {
        const kind = emitter.raw[scan];

        if (is_open(kind)) depth += 1;

        if (is_close(kind)) {
            depth -= 1;

            if (depth == 0) {
                if (kind == .paren_close) return scan;
                return null;
            }
        }
    }

    return null;
}
