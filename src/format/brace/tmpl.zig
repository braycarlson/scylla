const std = @import("std");
const assert = std.debug.assert;
const bind = @import("bind.zig");
const body = @import("body.zig");
const brace = @import("../brace.zig");
const call = @import("call.zig");
const core = @import("emitter.zig");
const emit = @import("emit.zig");
const line = @import("line.zig");
const span = @import("span.zig");
const tern = @import("tern.zig");
const walk = @import("../walk.zig");
const Emitter = core.Emitter;

const hole_heads: []const []const u8 = &.{
    "!",
    "+",
    "-",
    "...",
    "async",
    "await",
    "class",
    "delete",
    "function",
    "new",
    "typeof",
    "void",
    "yield",
    "~",
};

const hole_links: []const []const u8 = &.{
    "!=",
    "!==",
    "%",
    "&",
    "&&",
    "*",
    "**",
    "+",
    "-",
    "/",
    "<",
    "<<",
    "<=",
    "==",
    "===",
    ">",
    ">=",
    ">>",
    ">>>",
    "^",
    "|",
    "||",
};

const template_scan_max: u32 = 1 << 16;

pub inline fn template_body(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    if (emitter.tokens[position].kind != .string) return null;
    return template_body_string(emitter, position);
}

fn template_body_string(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    const token = emitter.tokens[position];

    assert(token.kind == .string);

    if (!emitter.policy.template_spans) return null;
    if (!walk.text_is(token.text(emitter.source), "`")) return null;

    assert(token.length == 1);

    if (template_shut(emitter, position)) return null;

    const end = template_body_scan(emitter, position) orelse return null;

    assert(end > position);
    assert(end < emitter.count);

    return end;
}

fn template_body_scan(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    var depth: u32 = 0;
    var scan = position + 1;

    while (scan < emitter.count) {
        assert(depth <= scan - position);

        const held = emitter.tokens[scan];
        const opens = held.kind == .block_start or walk.substituting(emitter.source, held);
        const stringed = depth == 0 and held.kind == .string;

        if (opens) {
            depth += 1;
        } else if (held.kind == .block_end) {
            if (depth == 0) return null;

            depth -= 1;
        } else if (stringed) {
            if (walk.text_is(held.text(emitter.source), "`")) return scan;
        } else {}

        scan += 1;
    }

    return null;
}

pub fn template_closes(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (emitter.tokens[position].kind != .block_end) return false;

    const held = emitter.brackets.open_of(position) orelse return false;

    assert(held < position);

    return walk.substituting(emitter.source, emitter.tokens[held]);
}

fn template_chunk(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const token = emitter.tokens[position];

    if (position == 0) return false;
    if (token.kind != .string) return false;
    if (walk.substituting(emitter.source, token)) return false;
    if (walk.text_is(token.text(emitter.source), "`")) return false;

    const before = emitter.tokens[position - 1];

    assert(before.offset <= token.offset);

    if (before.end() != token.offset) return false;

    if (before.kind == .string) {
        if (walk.text_is(before.text(emitter.source), "`")) return true;
    }

    return template_closes(emitter, position - 1);
}

fn template_shut(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (position == 0) return false;

    const before = position - 1;

    assert(emitter.tokens[before].end() <= emitter.tokens[position].offset);

    if (emitter.tokens[before].end() != emitter.tokens[position].offset) return false;
    return template_chunk(emitter, before) or template_closes(emitter, before);
}

pub fn template_piece(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (walk.substituting(emitter.source, emitter.tokens[position])) return true;
    if (template_closes(emitter, position)) return true;
    return template_chunk(emitter, position);
}

pub fn template_glued(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (!emitter.policy.template_spans) return false;
    if (template_piece(emitter, position)) return true;
    if (template_piece(emitter, previous)) return true;

    const held = emitter.tokens[previous];

    const named = held.kind != .keyword or walk.text_is(held.text(emitter.source), "this") or
        walk.text_is(held.text(emitter.source), "super");

    if (!named) return false;
    if (emit.roled(emitter, position, brace.role_type)) return false;
    if (!template_walked(emitter, position)) return false;
    return held.ends_a_value();
}

pub fn holed(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return false;

    const frame = emitter.nest[emitter.depth - 1];

    assert(frame.open < emitter.count);

    return frame.holed;
}

pub fn hole_flat(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    const close = emitter.brackets.close_of(open) orelse return true;

    assert(close > open);

    const parted = body.parted_by(
        emitter,
        emitter.tokens[open].end(),
        emitter.tokens[close].offset,
    );

    const hardened = hole_hardened(emitter, open, close);

    if (parted != 0) return false;
    if (hardened) return false;
    return !hole_flat_expands(emitter, open, close);
}

fn hole_flat_expands(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var held = open + 1;

    while (held < close) {
        if (span.chain_expanded(emitter, held)) return true;
        if (call.composed_args(emitter, held)) return true;

        held += 1;
    }

    return false;
}

fn hole_parted(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    const close = emitter.brackets.close_of(open) orelse return false;

    assert(close > open);

    return body.parted_by(emitter, emitter.tokens[open].end(), emitter.tokens[close].offset) > 0;
}

fn hole_hardened(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open <= close);
    assert(close < emitter.count);

    var scan = open;

    while (scan < close) {
        const token = emitter.tokens[scan];

        switch (token.kind) {
            .comment => {
                if (!std.mem.startsWith(u8, token.text(emitter.source), "/*")) return true;
            },
            .block_start => {
                if (call.chain_hardened(emitter, scan, scan + 1)) return true;
            },
            else => {},
        }

        scan += 1;
    }

    return false;
}

pub fn template_walked(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (!emitter.policy.template_spans) return false;

    const token = emitter.tokens[position];
    if (token.kind != .string) return false;
    if (!walk.text_is(token.text(emitter.source), "`")) return false;

    assert(token.length == 1);

    if (template_shut(emitter, position)) return false;
    return template_held(emitter, position);
}

fn template_held(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    var depth: u32 = 0;
    var holed_hole = false;
    var hole = position;
    var scan = position + 1;

    while (scan < emitter.count) {
        assert(hole < scan);
        assert(depth <= scan - position);

        const held = emitter.tokens[scan];
        const commented = depth > 0 and hole_parted(emitter, hole);

        if (held.kind == .comment) {
            if (!commented) return false;
        }

        const opens = held.kind == .block_start or walk.substituting(emitter.source, held);
        const stringed = depth == 0 and held.kind == .string;

        if (opens) {
            if (depth == 0) hole = scan;

            holed_hole = holed_hole or depth == 0;
            depth += 1;
        } else if (held.kind == .block_end) {
            if (depth == 0) return false;

            depth -= 1;
        } else if (stringed) {
            if (walk.text_is(held.text(emitter.source), "`")) return holed_hole;
        } else {}

        scan += 1;
    }

    return false;
}

pub fn hole_level(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);

    if (!walk.substituting(emitter.source, emitter.tokens[open])) return null;

    const width = hole_indention(emitter, open) orelse return null;

    if (width == 0) {
        if (hole_opens(emitter, open)) return 0;
        return null;
    }

    assert(emitter.options.indent_width > 0);

    if (width % emitter.options.indent_width != 0) return null;
    return @divFloor(width, emitter.options.indent_width);
}

fn hole_opens(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (open == 0) return false;

    const before = open - 1;

    assert(emitter.tokens[before].end() <= emitter.tokens[open].offset);

    if (!template_chunk(emitter, before)) return false;
    return std.mem.endsWith(u8, emitter.tokens[before].text(emitter.source), "\n");
}

fn hole_indention(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);

    var scan = open;

    for (0..template_scan_max) |_| {
        if (scan == 0) return null;

        scan -= 1;

        const token = emitter.tokens[scan];
        const closes = token.kind == .block_end and template_closes(emitter, scan);

        if (closes) {
            scan = emitter.brackets.open_of(scan) orelse return null;

            continue;
        }

        const ticked = token.kind == .string and walk.text_is(token.text(emitter.source), "`");
        if (ticked) return null;
        if (!template_chunk(emitter, scan)) continue;

        const width = hole_indention_width(emitter, token.text(emitter.source)) orelse continue;
        return width;
    }

    return null;
}

fn hole_indention_width(emitter: *const Emitter, text: []const u8) ?u32 {
    assert(emitter.options.indent_width > 0);
    assert(text.len <= std.math.maxInt(u32));

    const at = std.mem.findScalarLast(u8, text, '\n') orelse return null;
    var width: u32 = 0;

    for (text[at + 1 ..]) |byte| {
        if (byte == '\t') {
            width += emitter.options.indent_width - width % emitter.options.indent_width;
        } else if (byte == ' ') {
            width += 1;
        } else {
            break;
        }
    }

    return width;
}

pub fn hole_indents(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (hole_flat(emitter, open)) return false;

    const head = emit.ahead_of(emitter, open) orelse return false;
    if (head >= close) return false;

    const tail = emit.back_of(emitter, close) orelse return false;
    if (tail < head) return false;

    const linked = hole_indents_scan(emitter, head, tail) orelse return false;
    if (linked) return true;
    return hole_indents_tail(emitter, head, tail);
}

fn hole_indents_scan(emitter: *const Emitter, head: u32, tail: u32) ?bool {
    assert(head <= tail);
    assert(tail < emitter.count);

    var depth: u32 = 0;
    var linked = false;
    var scan = head;

    while (scan <= tail) {
        const token = emitter.tokens[scan];
        const kind = token.kind;
        const opens = walk.is_open(kind) or kind == .block_start or bind.spans_open(emitter, scan);
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            const text = token.text(emitter.source);
            if (walk.text_is(text, "=>")) return null;
            if (walk.text_is(text, "=")) return null;

            if (hole_indents_linked(emitter, scan, text)) linked = true;
        } else {}

        scan += 1;
    }

    return linked;
}

fn hole_indents_linked(emitter: *const Emitter, scan: u32, text: []const u8) bool {
    assert(scan < emitter.count);

    if (walk.text_is(text, ",")) return true;
    if (walk.text_is(text, "as")) return true;
    if (walk.text_is(text, "in")) return true;
    if (walk.text_is(text, "instanceof")) return true;
    if (walk.text_is(text, "satisfies")) return true;

    if (walk.text_is(text, "?")) {
        if (!tern.optional(emitter, scan)) return true;
    }

    if (!words_contain(hole_links, text)) return false;

    const before = emit.back_of(emitter, scan) orelse return false;
    return walk.ends_operand(emitter.tokens[before].kind);
}

fn hole_indents_tail(emitter: *const Emitter, head: u32, tail: u32) bool {
    assert(head <= tail);
    assert(tail < emitter.count);

    const token = emitter.tokens[head];
    if (walk.is_open(token.kind)) return false;
    if (token.kind == .block_start) return false;
    if (bind.spans_open(emitter, head)) return false;
    if (words_contain(hole_heads, token.text(emitter.source))) return false;

    const kind = emitter.tokens[tail].kind;
    if (kind == .identifier) return true;
    if (kind == .keyword) return true;
    return kind.eql(.{ .punctuation = .bracket_close });
}

pub fn hole_held(emitter: *const Emitter) u32 {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.lined < core.line_level_max);

    return emitter.printed;
}

pub fn holed_close(emitter: *const Emitter, position: u32) u32 {
    assert(position < emitter.count);

    const close = emitter.brackets.close_of(position) orelse return position;

    assert(close > position);

    return close;
}

pub fn seats(emitter: *Emitter, position: u32, level: u32) void {
    assert(position < emitter.count);
    assert(emitter.lined < core.line_level_max);
    assert(level < std.math.maxInt(u32));

    emitter.printed = level;
    emitter.leds[emitter.lined] = 0;
    emitter.lines[emitter.lined] = .{ .start = position + 1, .level = level };
    emitter.lined = (emitter.lined + 1) % core.line_level_max;
}

pub fn hole_restored(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);

    if (!template_closes(emitter, position)) return;

    assert(emitter.tokens[position].kind == .block_end);

    if (hole_level(emitter, emitter.closed.open) == null) {
        if (hole_indents(emitter, emitter.closed.open, position)) {
            seats(emitter, position, emitter.closed.seated);
        }

        return;
    }

    seats(emitter, position, emitter.closed.seated);

    try line.level(emitter, emitter.closed.inset);
}

pub fn hole_closed(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);

    if (!template_closes(emitter, position)) return;

    assert(emitter.tokens[position].kind == .block_end);

    const open = emitter.brackets.open_of(position) orelse return;

    assert(open < position);

    if (!hole_indents(emitter, open, position)) return;

    const level = hole_level(emitter, open) orelse hole_closed_level(emitter);

    try line.level(emitter, level);
    try emitter.document.push(.soft_line);
    try emitter.document.push(.group_close);
}

fn hole_closed_level(emitter: *const Emitter) u32 {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.lined < core.line_level_max);

    if (emitter.depth > 0) return line.frame(emitter).seated;
    return hole_held(emitter);
}

fn words_contain(words: []const []const u8, text: []const u8) bool {
    assert(words.len > 0);
    assert(text.len <= std.math.maxInt(u32));

    for (words) |word| {
        assert(word.len > 0);

        if (walk.text_eql(word, text)) return true;
    }

    return false;
}

pub fn template_whole(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    const token = emitter.tokens[position];
    const text = token.text(emitter.source);
    const backtick = token.kind == .string and token.length > 1 and text[0] == '`';

    if (emitter.policy.template_spans) {
        if (backtick) return position;
    }

    const end = template_body(emitter, position) orelse return null;

    assert(end > position);

    return end;
}

pub fn templated_unit(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.template_units) return null;
    return template_body(emitter, position);
}

pub fn spanned_unit(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    if (template_body(emitter, position)) |found| {
        assert(found > position);

        return found;
    }

    return span.jsx_body(emitter, position);
}

pub fn template_lined(emitter: *const Emitter, open: u32, end: u32) bool {
    assert(open <= end);
    assert(end < emitter.count);

    var depth: u32 = 0;
    var scan = open;

    while (scan <= end) {
        assert(depth <= scan - open);

        const token = emitter.tokens[scan];
        const closes = depth > 0 and template_closes(emitter, scan);
        const stringed = depth == 0 and token.kind == .string;

        if (walk.substituting(emitter.source, token)) {
            depth += 1;
        } else if (closes) {
            depth -= 1;
        } else if (stringed) {
            if (std.mem.findScalar(u8, token.text(emitter.source), '\n') != null) return true;
        } else {}

        scan += 1;
    }

    return false;
}

pub fn template_columns(emitter: *const Emitter, open: u32, close: u32) u32 {
    assert(open < close);
    assert(close < emitter.count);

    const source = emitter.source;
    const tokens = emitter.tokens;
    var width = walk.columns(source, tokens[open].offset, tokens[close].end());

    for (open + 1..close) |scan| {
        const token = tokens[scan];
        const opened = walk.substituting(source, token);
        const emptied = walk.substituting(source, tokens[scan - 1]);
        const shut = template_closes(emitter, @intCast(scan)) and !emptied;

        if (opened) width -= walk.columns(source, token.end(), tokens[scan + 1].offset);
        if (shut) width -= walk.columns(source, tokens[scan - 1].end(), token.offset);
        if (hole_spaced(emitter, @intCast(scan))) width += 1;
    }

    return width;
}

fn hole_spaced(emitter: *const Emitter, position: u32) bool {
    assert(position > 0);
    assert(position < emitter.count);

    const previous = position - 1;
    const token = emitter.tokens[position];
    const held = emitter.tokens[previous];
    const coded = token.length > 0 and token.kind != .newline;
    const held_coded = held.length > 0 and held.kind != .newline;

    if (!coded) return false;
    if (!held_coded) return false;
    if (held.end() != token.offset) return false;
    if (template_piece(emitter, position)) return false;
    if (template_piece(emitter, previous)) return false;
    return span.printed_blank(emitter, previous, position);
}
