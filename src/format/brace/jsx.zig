const std = @import("std");
const assert = std.debug.assert;
const Span = @import("../../stdx/bounded/span.zig");
const bind = @import("bind.zig");
const body = @import("body.zig");
const brace = @import("../brace.zig");
const call = @import("call.zig");
const core = @import("emitter.zig");
const emit = @import("emit.zig");
const ir = @import("../ir.zig");
const join = @import("join.zig");
const line = @import("line.zig");
const link = @import("link.zig");
const list = @import("list.zig");
const own = @import("own.zig");
const span = @import("span.zig");
const tern = @import("tern.zig");
const tmpl = @import("tmpl.zig");
const walk = @import("../walk.zig");
const Emitter = core.Emitter;

const Gap = enum {
    blank,
    line,
    none,
    space,
    start,
};

pub const Held = union(enum) {
    expression,
    none,
    tag: bool,
    word: bool,

    pub fn eql(held: Held, other: Held) bool {
        if (std.meta.activeTag(held) != std.meta.activeTag(other)) return false;

        const equal = std.meta.eql(held, other);

        if (equal) assert(std.meta.activeTag(held) == std.meta.activeTag(other));
        if (std.meta.activeTag(held) != std.meta.activeTag(other)) assert(!equal);

        return equal;
    }
};

const Stage = enum {
    children,
    closing,
    opening,
};

const Worded = enum {
    none,
    space,
    word,
};

pub const Tag = struct {
    angles: u32,
    close: u32,
    commented: bool,
    elemental: bool,
    filled: bool,
    first: bool,
    gap: Gap,
    grouped: bool,
    held: Held,
    holed: bool,
    inside: bool,
    led: bool,
    named: bool,
    open: u32,
    stage: Stage,
    tight: bool,
    wide: bool,
    written: u32,

    pub const empty: Tag = .{
        .angles = 0,
        .close = 0,
        .commented = false,
        .elemental = false,
        .filled = false,
        .first = true,
        .gap = .start,
        .grouped = false,
        .held = .none,
        .holed = false,
        .inside = false,
        .led = false,
        .named = false,
        .open = 0,
        .stage = .opening,
        .tight = false,
        .wide = false,
        .written = 0,
    };
};

const jsx_roles: u16 = brace.role_jsx_hole | brace.role_jsx_tag | brace.role_jsx_text;
const comment_scan_max: u32 = 64;
const callee_scan_max: u32 = 16;
const chain_scan_max: u32 = 4096;
const chain_link_max: u32 = 32;
const binary_operator_max: u32 = 64;
const parens_owed: u32 = 1;
const parens_written: u32 = 2;
const jsx_end_scan_max: u32 = 4096;
const jsx_whitespace: [4]u8 = .{ ' ', '\n', '\t', '\r' };
const jsx_operand_prefixes: [6][]const u8 = .{ "await", "!", "~", "typeof", "void", "delete" };

const jsx_parenthesized_prefixes: [8][]const u8 = .{
    "await", "...", "!", "~", "typeof", "void", "delete", "new",
};

const jsx_parenthesized_suffixes: [6][]const u8 = .{ "as", "satisfies", ".", "[", "!", "(" };
const jsx_cast_words: [2][]const u8 = .{ "as", "satisfies" };
const jsx_unary_words: [6][]const u8 = .{ "!", "-", "+", "~", "typeof", "void" };

pub fn jsxing(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.roles.len <= std.math.maxInt(u32));

    if (position >= emitter.roles.len) return false;
    return emitter.roles[position] & jsx_roles != 0;
}

pub fn inside(emitter: *const Emitter) bool {
    assert(emitter.jsxed <= core.jsx_depth_max);

    return emitter.jsxed > 0;
}

fn jsx_coded(emitter: *const Emitter) bool {
    assert(emitter.jsxed <= core.jsx_depth_max);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.jsxed == 0) return false;
    if (emitter.depth == 0) return false;

    const frame = emitter.nest[emitter.depth - 1];
    const tag = emitter.jsx[emitter.jsxed - 1];
    if (frame.open <= tag.open) return false;
    return !emit.roled(emitter, frame.open, brace.role_jsx_hole);
}

fn comment_beside(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (comment_lined(emitter, position)) return true;

    const previous = emitter.previous orelse return false;
    return comment_lined(emitter, previous);
}

fn comment_lined(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const token = emitter.tokens[position];
    if (token.kind != .comment) return false;
    return std.mem.startsWith(u8, token.text(emitter.source), "//");
}

pub fn outer(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (!inside(emitter)) return true;
    if (!emit.roled(emitter, position, brace.role_jsx)) return false;
    return !emit.roled(emitter, position, brace.role_jsx_child);
}

pub fn holed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    return emit.roled(emitter, position, brace.role_jsx_hole);
}

pub fn wrapped(emitter: *const Emitter, position: u32) ?struct { u32, core.Wrap } {
    assert(position < emitter.count);

    if (!emit.roled(emitter, position, brace.role_jsx_wrap)) return null;

    const close = span.jsx_body(emitter, position) orelse return null;

    assert(close >= position);

    return .{ close, .tagged };
}

pub fn opening(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);

    if (jsx_comment_led(emitter, position)) |led| {
        const first, const head = led;

        if (head == position) {
            if (first < position) return;
        }
    }

    try jsx_wrap_opens(emitter, position);
}

pub fn split(emitter: *const Emitter, position: u32, previous: u32) ?bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (jsx_comment_led(emitter, position) != null) return false;
    if (jsx_hole_edged(emitter, position, previous)) return false;

    const walked = inside(emitter) and
        !jsx_coded(emitter) and
        !comment_beside(emitter, position);

    if (!walked) {
        if (jsx_sequenced(emitter, position, previous)) return true;
    }

    if (walked) return jsx_hole_parted(emitter, position, previous);

    if (jsxing(emitter, position)) {
        if (jsx_comment_ends(emitter, previous)) return true;
        if (jsx_stated(emitter, previous)) return null;
        return false;
    }

    const text = emitter.tokens[position].text(emitter.source);

    const linked = walk.text_is(text, "?") or walk.text_is(text, ":") or
        word_listed(&jsx_parenthesized_suffixes, text);

    if (!linked) return null;
    if (!jsxing(emitter, previous)) return null;
    return false;
}

fn jsx_sequenced(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (!emitter.tokens[previous].is_punctuation(.comma)) return false;
    if (wrapped(emitter, position) == null) return false;
    return bind.sequence_broken(emitter, position, previous);
}

fn jsx_hole_edged(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (emitter.jsxed == 0) return false;
    if (!jsx_frame(emitter).holed) return false;

    if (holed(emitter, previous)) {
        if (walk.text_is(emitter.tokens[previous].text(emitter.source), "{")) return true;
    }

    if (!holed(emitter, position)) return false;
    return walk.text_is(emitter.tokens[position].text(emitter.source), "}");
}

fn jsx_hole_parted(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (emitter.jsxed == 0) return false;
    if (!jsx_frame(emitter).holed) return false;
    if (emitter.tokens[previous].kind != .comment) return false;
    return body.parts_at(emitter, previous, position);
}

fn jsx_comment_ends(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);
    assert(emitter.jsxed <= core.jsx_depth_max);

    if (!comment_lined(emitter, previous)) return false;
    if (emitter.jsxed == 0) return false;

    const frame = jsx_frame(emitter);
    return frame.stage != .opening or !frame.commented;
}

fn jsx_stated(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);
    assert(emitter.jsxed <= core.jsx_depth_max);

    if (inside(emitter)) return false;

    var code = previous;

    if (emitter.tokens[previous].kind == .comment) {
        code = jsx_coded_back(emitter, previous) orelse return true;
    }

    const before = emitter.tokens[code];
    if (before.kind == .block_end) return true;
    if (before.kind == .block_start) return true;
    return before.is_punctuation(.semicolon);
}

fn jsx_wrap_opens(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    const held_wrap = wrapped(emitter, position) orelse return;
    const close, const wrap = held_wrap;
    const hugged = jsx_hugged(emitter, close) or jsx_chain_hugged(emitter, position);

    if (hugged) try emitter.document.push(.hugs);
    if (emitter.wraps_owed == core.wrap_depth_max) return;

    const held = jsx_wrap_opens_held(emitter, position, wrap);
    const parenthesized = jsx_wrap_opens_parenthesized(held, emitter, position, close);
    const floor: u32 = if (parenthesized) parens_owed else 0;

    emitter.wrapped[emitter.wraps_owed] = .{
        .close = close,
        .wrap = held,
        .depth = emitter.depth,
        .floor = floor,
        .start = position,
    };

    emitter.wraps_armed[emitter.wraps_owed] = true;
    emitter.wraps_nested[emitter.wraps_owed] = core.nest_none;
    emitter.wraps_owed += 1;

    if (parenthesized) {
        try emitter.document.push(.group_open);

        return;
    }

    if (held == .tagging) {
        try emitter.document.push(.group_open);
        try emitter.document.push(.{ .text = .{ .source = .literal, .span = emitter.spacing } });
        try emitter.document.push(.indent);
        try emitter.document.push(.hard_line);

        return;
    }

    const spacing = if (emitter.line_start) emitter.opening else emitter.spacing;

    if (held != .linked) try emitter.document.push(.group_open);

    try emitter.document.push(.{ .if_broken = spacing });
    try line.opens_broken(emitter);
    try emitter.document.push(.soft_line);
}

fn jsx_wrap_opens_held(emitter: *const Emitter, position: u32, wrap: core.Wrap) core.Wrap {
    assert(position < emitter.count);
    assert(wrap == .tagged);

    if (jsx_expands(emitter)) return .tagging;
    if (jsx_chain_linked(emitter, position) != null) return .linked;
    return wrap;
}

fn jsx_wrap_opens_parenthesized(
    held: core.Wrap,
    emitter: *const Emitter,
    position: u32,
    close: u32,
) bool {
    assert(position < emitter.count);
    assert(close < emitter.count);

    if (held != .tagged) return false;
    return jsx_parenthesized(emitter, position, close);
}

pub fn parens_opening(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.wraps_owed == 0) return;

    const top = emitter.wraps_owed - 1;
    const owed = emitter.wrapped[top];
    if (owed.wrap != .tagged) return;
    if (owed.floor != parens_owed) return;
    if (owed.start != position) return;

    emitter.wrapped[top].floor = parens_written;

    try emitter.document.push(.{ .text = .{ .source = .literal, .span = emitter.opening } });
    try line.opens_broken(emitter);
    try emitter.document.push(.soft_line);
}

fn jsx_chain_linked(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.wraps_owed == 0) return null;

    const owed = emitter.wrapped[emitter.wraps_owed - 1];
    if (owed.wrap != .chained) return null;

    const before = join.coded_before(emitter, position) orelse return null;

    const colon, const end = jsx_chain_linked_end(
        emitter,
        before,
        owed.floor,
        owed.close,
    ) orelse return null;

    if (jsx_chain_linked_sole(emitter, position, end)) return null;
    if (jsx_chain_linked_nested(emitter, before, colon, position, end)) return null;
    return end;
}

fn jsx_chain_linked_end(
    emitter: *const Emitter,
    before: u32,
    head: u32,
    close: u32,
) ?struct { u32, u32 } {
    assert(before < emitter.count);
    assert(close < emitter.count);
    assert(head < emitter.count);

    var question = head;
    var colon = tern.ternary_branch(emitter, question) orelse return null;

    for (0..chain_link_max) |_| {
        if (before == question) break;
        if (before == colon) break;
        if (before < colon) break;

        question = jsx_chain_nested(emitter, colon, close) orelse return null;
        colon = tern.ternary_branch(emitter, question) orelse return null;
    }

    if (before == question) {
        const end = emit.back_of(emitter, colon) orelse return null;

        assert(end < colon);

        return .{ colon, end };
    }

    if (before == colon) return .{ colon, close };
    return null;
}

fn jsx_chain_linked_sole(emitter: *const Emitter, position: u32, end: u32) bool {
    assert(position < emitter.count);
    assert(end < emitter.count);

    if (position != end) return false;

    const text = emitter.tokens[position].text(emitter.source);
    return walk.text_is(text, "null") or walk.text_is(text, "undefined");
}

fn jsx_chain_linked_nested(
    emitter: *const Emitter,
    before: u32,
    colon: u32,
    position: u32,
    end: u32,
) bool {
    assert(end < emitter.count);

    if (before != colon) return false;
    assert(position < emitter.count);

    var scan = position;

    while (scan <= end) {
        assert(scan < emitter.count);

        if (jsx_chain_linked_branched(emitter, scan, end)) return true;

        scan += 1;
    }

    return false;
}

fn jsx_chain_linked_branched(emitter: *const Emitter, scan: u32, end: u32) bool {
    assert(scan < emitter.count);

    if (!walk.text_is(emitter.tokens[scan].text(emitter.source), "?")) return false;
    if (tern.optional(emitter, scan)) return false;

    const held = tern.ternary_branch(emitter, scan) orelse return false;
    if (held > end) return false;
    return emitter.brackets.open_of(scan) == null;
}

pub fn chain_aligns(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.wraps_owed == 0) return;

    if (emitter.jsx_aligned == position) {
        emitter.jsx_aligned = std.math.maxInt(u32);

        try emitter.document.push(.dealign);

        return;
    }

    if (!walk.text_is(emitter.tokens[position].text(emitter.source), ":")) return;

    const chain = jsx_chain_wrap(emitter, position) orelse return;

    try chain_aligns_linked(emitter, position, chain.floor, chain.close);
}

fn chain_aligns_linked(
    emitter: *Emitter,
    position: u32,
    question: u32,
    close: u32,
) error{Overflow}!void {
    assert(position < emitter.count);
    assert(close < emitter.count);
    assert(question < emitter.count);

    var colon: ?u32 = tern.ternary_branch(emitter, question);

    for (0..chain_link_max) |_| {
        const held = colon orelse return;
        if (held > position) return;

        const nested = jsx_chain_nested(emitter, held, close) orelse return;

        if (held == position) {
            emitter.jsx_aligned = nested;

            try emitter.document.push(.@"align");

            return;
        }

        colon = tern.ternary_branch(emitter, nested);
    }
}

fn jsx_chain_alternate(emitter: *const Emitter, head: u32, close: u32, question: u32) bool {
    assert(head < emitter.count);
    assert(close < emitter.count);

    var colon: ?u32 = tern.ternary_branch(emitter, head);

    for (0..chain_link_max) |_| {
        const held = colon orelse return false;
        const nested = jsx_chain_nested(emitter, held, close) orelse return false;
        if (nested == question) return true;

        colon = tern.ternary_branch(emitter, nested);
    }

    return false;
}

fn jsx_chain_nested(emitter: *const Emitter, colon: u32, close: u32) ?u32 {
    assert(colon < close);
    assert(close < emitter.count);

    var scan = colon + 1;

    while (scan <= close) {
        assert(scan < emitter.count);

        if (jsx_chain_nested_at(emitter, scan, colon)) |found| return found;

        scan += 1;
    }

    return null;
}

fn jsx_chain_nested_at(emitter: *const Emitter, scan: u32, colon: u32) ?u32 {
    assert(scan < emitter.count);

    if (!walk.text_is(emitter.tokens[scan].text(emitter.source), "?")) return null;
    if (tern.optional(emitter, scan)) return null;

    const head = tern.ternary_test(emitter, scan);
    var before = emit.back_of(emitter, head) orelse return null;

    if (emitter.tokens[before].is_punctuation(.paren_open)) {
        before = emit.back_of(emitter, before) orelse return null;
    }

    if (before != colon) return null;
    return scan;
}

fn jsx_chain_wrap(emitter: *const Emitter, position: u32) ?core.Wrapped {
    assert(position < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    var index = emitter.wraps_owed;

    while (index > 0) {
        index -= 1;

        const held = emitter.wrapped[index];
        if (held.wrap != .chained) continue;
        if (position <= held.close) return held;
    }

    return null;
}

pub fn chain_owned(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    const chain = jsx_chain_wrap(emitter, position) orelse return false;
    var question: ?u32 = chain.floor;

    for (0..chain_link_max) |_| {
        const held = question orelse return false;
        if (position == held) return true;
        if (previous == held) return true;

        const colon = tern.ternary_branch(emitter, held) orelse return false;
        if (position == colon) return true;
        if (previous == colon) return true;
        if (colon >= chain.close) return false;

        question = jsx_chain_nested(emitter, colon, chain.close);
    }

    return false;
}

pub fn chain_links(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emit.roled(emitter, position, brace.role_jsx)) return;
    if (emitter.wraps_owed == core.wrap_depth_max) return;

    var head = position;

    if (jsx_comment_led(emitter, position)) |led| {
        const lead, const comment_head = led;
        if (lead != position) return;

        head = comment_head;
    }

    if (emit.roled(emitter, head, brace.role_jsx)) return;

    const end = jsx_chain_linked(emitter, head) orelse return;

    emitter.wrapped[emitter.wraps_owed] = .{
        .close = end,
        .wrap = .linked,
        .depth = emitter.depth,
        .floor = 0,
        .start = position,
    };

    emitter.wraps_armed[emitter.wraps_owed] = true;
    emitter.wraps_nested[emitter.wraps_owed] = core.nest_none;
    emitter.wraps_owed += 1;

    try emitter.document.push(.{ .if_broken = emitter.opening });
    try line.opens_broken(emitter);
    try emitter.document.push(.soft_line);
}

fn jsx_expands(emitter: *const Emitter) bool {
    assert(emitter.jsxed <= core.jsx_depth_max);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return false;
    if (emitter.jsxed == 0) return false;
    if (!arrowed_previous(emitter)) return false;

    const frame = line.frame(emitter);
    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return false;
    return jsx_called(emitter, frame.open);
}

fn arrowed_previous(emitter: *const Emitter) bool {
    const previous = emitter.previous orelse return false;

    assert(previous < emitter.count);

    return walk.text_is(emitter.tokens[previous].text(emitter.source), "=>");
}

fn jsx_called(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    var scan = position;

    for (0..callee_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;

        assert(held < scan);

        const token = emitter.tokens[held];

        if (emit.roled(emitter, held, brace.role_jsx_hole)) {
            return walk.text_is(token.text(emitter.source), "{");
        }

        const worded = token.kind == .identifier or token.kind == .keyword;

        if (!worded) {
            if (!walk.text_is(token.text(emitter.source), ".")) return false;
        }

        scan = held;
    }

    return false;
}

fn jsx_hugged(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);

    if (emitter.depth == 0) return false;

    const enclosing = line.frame(emitter);
    if (!enclosing.kind.eql(.{ .punctuation = .paren_open })) return false;
    if (!arrowed_previous(emitter)) return false;
    return own.ending(emitter, close, enclosing.close);
}

pub fn run_wrap(emitter: *const Emitter, position: u32) ?struct { u32, core.Wrap } {
    assert(position < emitter.count);

    if (emitter.jsxed == 0) return null;
    if (!emitter.policy.binary_lines) return null;

    const open = jsx_hole_before(emitter, position) orelse return null;
    const valued = !emit.roled(emitter, open, brace.role_jsx_child);

    if (valued) {
        if (!run_wrap_valued(emitter, open)) return null;
    }

    const close = join.closing_of(emitter, open) orelse return null;

    assert(close > open);

    const stop = run_wrap_stop(emitter, close, position) orelse return null;

    if (call.ternary_bodied(emitter, position, close)) {
        return run_wrap_paired(emitter, position, close);
    }

    var ranks: [binary_operator_max]struct { u32, u32 } = @splat(.{ 0, 0 });
    const count = span.operand_ranked(emitter, position, stop, &ranks) orelse return null;

    if (count == 1) {
        const operator, _ = ranks[0];
        if (jsx_run_tail(emitter, operator, stop)) return null;
    }

    if (valued) return .{ stop, .paired };
    return .{ stop, .argued };
}

fn jsx_hole_before(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    const held = emit.back_of(emitter, position) orelse return null;

    assert(held < position);

    if (!emit.roled(emitter, held, brace.role_jsx_hole)) return null;
    if (!walk.text_is(emitter.tokens[held].text(emitter.source), "{")) return null;
    return held;
}

fn run_wrap_valued(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    const held = emit.back_of(emitter, open) orelse return false;

    assert(held < open);

    return walk.text_is(emitter.tokens[held].text(emitter.source), "=");
}

fn run_wrap_stop(emitter: *const Emitter, close: u32, position: u32) ?u32 {
    assert(close < emitter.count);

    const stop = emit.word_before(emitter, close) orelse return null;
    if (stop <= position) return null;
    return stop;
}

fn run_wrap_paired(emitter: *const Emitter, position: u32, close: u32) ?struct { u32, core.Wrap } {
    assert(position < emitter.count);
    assert(close < emitter.count);

    const question = jsx_question(emitter, position, close) orelse return null;
    const test_position = run_wrap_stop(emitter, question, position) orelse return null;
    var ranks: [binary_operator_max]struct { u32, u32 } = @splat(.{ 0, 0 });
    if (span.operand_ranked(emitter, position, test_position, &ranks) == null) return null;
    return .{ test_position, .paired };
}

fn jsx_question(emitter: *const Emitter, from: u32, close: u32) ?u32 {
    assert(from <= close);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var scan = from;

    while (scan < close) {
        assert(scan < emitter.count);

        if (tmpl.template_body(emitter, scan) orelse span.jsx_body(emitter, scan)) |end| {
            scan = end + 1;

            continue;
        }

        const token = emitter.tokens[scan];
        const opens = walk.is_open(token.kind) or token.kind == .block_start;
        const closes = walk.is_close(token.kind) or token.kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            if (jsx_question_marked(emitter, scan)) return scan;
        } else {}

        scan += 1;
    }

    return null;
}

fn jsx_question_marked(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);

    const text = emitter.tokens[scan].text(emitter.source);
    if (!walk.text_is(text, "?")) return false;
    return !tern.optional(emitter, scan);
}

fn jsx_run_tail(emitter: *const Emitter, operator: u32, stop: u32) bool {
    assert(operator < emitter.count);
    assert(stop < emitter.count);

    var head = emit.ahead_of(emitter, operator) orelse return false;
    const parenthesized = emitter.tokens[head].is_punctuation(.paren_open);

    if (parenthesized) {
        if (join.closing_of(emitter, head)) |held| {
            if (held == stop) head = emit.ahead_of(emitter, head) orelse return false;
        }
    }

    if (!emit.roled(emitter, head, brace.role_jsx)) return false;
    if (!walk.text_is(emitter.tokens[head].text(emitter.source), "<")) return false;

    const end = span.jsx_body(emitter, head) orelse return false;
    if (end == stop) return true;

    const after = emit.ahead_of(emitter, end) orelse return false;

    assert(after > end);

    return after == stop;
}

fn jsx_chain_hugged(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.wraps_owed == 0) return false;

    const argued = jsx_chain_hugged_argued(emitter) orelse return false;
    const hugged_holed = jsx_chain_hugged_holed(emitter, argued.start);
    const operator = emit.back_of(emitter, position) orelse return false;

    assert(operator < position);

    if (!hugged_holed) return false;
    if (operator <= argued.start) return false;
    return jsx_run_tail(emitter, operator, argued.close);
}

fn jsx_chain_hugged_argued(emitter: *const Emitter) ?core.Wrapped {
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    var index = emitter.wraps_owed;

    while (index > 0) {
        index -= 1;

        const held = emitter.wrapped[index];
        if (held.wrap == .argued) return held;
    }

    return null;
}

fn jsx_chain_hugged_holed(emitter: *const Emitter, start: u32) bool {
    assert(start < emitter.count);

    const open = emit.back_of(emitter, start) orelse return false;

    assert(open < start);

    if (!emit.roled(emitter, open, brace.role_jsx_hole)) return false;
    return emit.roled(emitter, open, brace.role_jsx_child);
}

fn jsx_chain_held(emitter: *const Emitter, position: u32) ?struct { u32, u32 } {
    assert(position < emitter.count);

    if (emitter.jsxed == 0) return null;
    if (!link.chain_linked(emitter, position)) return null;

    const head = link.chain_start(emitter, position) orelse return null;
    const stop = link.chain_stop(emitter, head) orelse return null;
    const open = jsx_chain_held_open(emitter, head) orelse return null;
    const after_close = join.closing_of(emitter, open) orelse return null;

    assert(after_close > open);

    const after_stop = emit.ahead_of(emitter, stop) orelse return null;

    assert(after_stop > stop);

    if (after_close != after_stop) return null;
    if (link.chain_commented(emitter, head, stop)) return null;
    return .{ head, stop };
}

fn jsx_chain_held_open(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);

    const open = emit.back_of(emitter, head) orelse return null;

    assert(open < head);

    if (!emit.roled(emitter, open, brace.role_jsx_hole)) return null;
    if (!walk.text_is(emitter.tokens[open].text(emitter.source), "{")) return null;
    return open;
}

pub fn chain_split(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (!link.chain_linked(emitter, position)) return false;
    return jsx_chain_held(emitter, position) == null;
}

pub fn chain_dots(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (!emitter.policy.chain_groups) return;

    const held = jsx_chain_held(emitter, position) orelse return;
    const head, const stop = held;
    var links: [chain_link_max]u32 = @splat(0);
    const count = link.chain_groups(emitter, head, stop, &links);
    const merges = span.chain_merges(emitter, head, &links, count);
    const cutoff: u32 = if (merges) 3 else 2;
    const from: u32 = if (merges) 1 else 0;

    if (count < cutoff) return;
    if (span.chain_calls(emitter, head, stop) < 2) return;

    const at = chain_dots_at(links[from..count], position) orelse return;
    const chain_expanded = span.chain_expanded(emitter, position);
    const line_element: ir.Element = if (chain_expanded) .hard_line else .soft_line;
    const first = links[from];

    if (at > 0) {
        if (!chain_dots_grouped(emitter, first)) return;

        try emitter.document.push(line_element);

        return;
    }

    if (emitter.wraps_owed == core.wrap_depth_max) return;

    emitter.wrapped[emitter.wraps_owed] = .{
        .close = stop,
        .wrap = .membered,
        .depth = emitter.depth,
        .floor = 0,
        .start = position,
    };

    emitter.wraps_armed[emitter.wraps_owed] = true;
    emitter.wraps_nested[emitter.wraps_owed] = core.nest_none;
    emitter.wraps_indent[emitter.wraps_owed] = emitter.indent;
    emitter.wraps_owed += 1;

    try emitter.document.push(.group_open);
    try line.opens_broken(emitter);
    try emitter.document.push(line_element);
}

fn chain_dots_at(links: []const u32, position: u32) ?u32 {
    assert(links.len <= chain_link_max);

    for (links, 0..) |held, index| {
        if (held == position) {
            assert(index < links.len);

            return @intCast(index);
        }
    }

    return null;
}

fn chain_dots_grouped(emitter: *const Emitter, first: u32) bool {
    assert(first < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    var index: u32 = 0;

    while (index < emitter.wraps_owed) {
        const held = emitter.wrapped[index];

        index += 1;

        if (held.wrap != .membered) continue;
        if (held.start == first) return true;
    }

    return false;
}

fn jsx_coded_after(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    var scan = emit.ahead_of(emitter, position) orelse return null;

    for (0..comment_scan_max) |_| {
        if (emitter.tokens[scan].kind != .comment) return scan;

        const held = emit.ahead_of(emitter, scan) orelse return null;

        assert(held > scan);

        assert(held > scan);

        scan = held;
    }

    return null;
}

fn jsx_comment_led(emitter: *const Emitter, position: u32) ?struct { u32, u32 } {
    assert(position < emitter.count);

    const head = jsx_comment_head(emitter, position) orelse return null;
    var lead = emit.back_of(emitter, head) orelse return null;

    for (0..comment_scan_max) |_| {
        const before = emit.back_of(emitter, lead) orelse return null;

        assert(before < lead);

        if (emitter.tokens[before].kind != .comment) break;

        lead = before;
    }

    const code = emit.back_of(emitter, lead) orelse return null;

    assert(code < lead);

    const comment = emitter.tokens[lead];
    const code_end = emitter.tokens[code].end();
    const branched = jsx_comment_branched(emitter, code);
    const spaced = code_end <= comment.offset;
    const joined = spaced and jsx_comment_joined(emitter, code_end, comment.offset);
    const trailing = !branched and joined;

    if (comment.kind != .comment) return null;
    if (trailing) return null;
    if (position < lead) return null;
    if (!jsx_comment_wrapped(emitter, head)) return null;

    assert(lead < head);

    return .{ lead, head };
}

fn jsx_comment_joined(emitter: *const Emitter, code_end: u32, offset: u32) bool {
    assert(code_end <= offset);
    assert(offset <= emitter.source.len);

    return std.mem.findScalar(u8, emitter.source[code_end..offset], '\n') == null;
}

fn jsx_comment_head(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    if (emitter.tokens[position].kind == .comment) return jsx_coded_after(emitter, position);

    const before = emit.back_of(emitter, position) orelse return null;

    assert(before < position);

    assert(before < position);

    if (emitter.tokens[before].kind != .comment) return null;
    return position;
}

fn jsx_comment_branched(emitter: *const Emitter, code: u32) bool {
    assert(code < emitter.count);

    const text = emitter.tokens[code].text(emitter.source);
    if (walk.text_is(text, "?")) return !tern.optional(emitter, code);
    if (walk.text_is(text, ":")) return tern.ternary(emitter, code);
    return false;
}

fn jsx_comment_wrapped(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);

    if (emitter.jsx_commented == head) return true;
    if (wrapped(emitter, head) != null) return true;
    if (emit.roled(emitter, head, brace.role_jsx)) return false;
    return jsx_chain_linked(emitter, head) != null;
}

pub fn comments(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);

    const led = jsx_comment_led(emitter, position) orelse return;
    const first, const head = led;

    if (position == first) {
        emitter.jsx_commented = head;

        if (!emit.roled(emitter, head, brace.role_jsx)) return;

        try jsx_wrap_opens(emitter, head);

        return;
    }

    try jsx_comment_breaks(emitter, position);
}

fn jsx_comment_breaks(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);

    const led = jsx_comment_led(emitter, position) orelse return;
    const first, _ = led;
    if (position == first) return;

    const before = emit.back_of(emitter, position) orelse return;

    assert(before < position);

    if (!jsx_comment_breaks_lined(emitter, before, position)) return;

    try emitter.document.push(.hard_line);
}

fn jsx_comment_breaks_lined(emitter: *const Emitter, before: u32, position: u32) bool {
    assert(before < position);

    const comment = emitter.tokens[before];
    const start = emitter.tokens[position].offset;

    if (std.mem.startsWith(u8, comment.text(emitter.source), "//")) return true;
    if (comment.end() > start) return false;
    return std.mem.findScalar(u8, emitter.source[comment.end()..start], '\n') != null;
}

pub fn chained(emitter: *const Emitter, question: u32, close: u32) bool {
    assert(question < emitter.count);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var scan = question;

    for (0..chain_scan_max) |_| {
        if (scan > close) return false;
        if (scan >= emitter.count) return false;

        const token = emitter.tokens[scan];
        const text = token.text(emitter.source);
        const opens = walk.is_open(token.kind) or token.kind == .block_start;
        const closes = walk.is_close(token.kind) or token.kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            if (chained_branched(emitter, scan, text)) return true;
        } else {}

        scan += 1;
    }

    return false;
}

fn chained_branched(emitter: *const Emitter, scan: u32, text: []const u8) bool {
    assert(scan < emitter.count);
    assert(text.len <= std.math.maxInt(u32));

    const branched = walk.text_is(text, "?") or walk.text_is(text, ":");
    if (!branched) return false;

    const found = jsx_coded_after(emitter, scan) orelse return false;
    return emit.roled(emitter, found, brace.role_jsx);
}

pub fn jsxes(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);

    const text = emitter.tokens[position].text(emitter.source);

    if (emit.roled(emitter, position, brace.role_jsx_text)) {
        try jsx_text(emitter, position);

        return;
    }

    if (emit.roled(emitter, position, brace.role_jsx_hole)) {
        try jsx_hole(emitter, position, text);

        return;
    }

    if (walk.text_is(text, "<")) {
        if (emit.roled(emitter, position, brace.role_jsx)) {
            try jsx_opens(emitter, position);

            return;
        }
    }

    if (walk.text_is(text, "</")) {
        try jsx_ends_token(emitter, position);

        return;
    }

    const closed = walk.text_is(text, ">") or walk.text_is(text, "/>");

    if (closed) {
        try jsx_closes(emitter, position, text);

        return;
    }

    try jsx_word(emitter, position);
}

fn jsx_frame(emitter: *const Emitter) Tag {
    assert(emitter.jsxed > 0);
    assert(emitter.jsxed <= core.jsx_depth_max);

    return emitter.jsx[emitter.jsxed - 1];
}

fn jsx_frame_mut(emitter: *Emitter) *Tag {
    assert(emitter.jsxed > 0);
    assert(emitter.jsxed <= core.jsx_depth_max);

    return &emitter.jsx[emitter.jsxed - 1];
}

fn jsx_opens(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.jsxed <= core.jsx_depth_max);

    if (emitter.jsxed == core.jsx_depth_max) return error.Overflow;

    if (emitter.jsxed > 0) {
        if (emit.roled(emitter, position, brace.role_jsx_child)) {
            const held: Held = .{ .tag = jsx_self_closing(emitter, position) };

            try jsx_separates(emitter, position, held);
        }
    }

    const tight = emit.roled(emitter, position, brace.role_jsx_tight);
    const elemental = !jsx_self_closing(emitter, position);
    var tag = Tag.empty;

    tag.close = span.jsx_body(emitter, position) orelse position;
    tag.elemental = elemental;
    tag.open = position;
    tag.tight = tight;
    tag.wide = emit.roled(emitter, position, brace.role_jsx_wide);

    emitter.jsx[emitter.jsxed] = tag;
    emitter.jsxed += 1;
    emitter.previous = position;

    if (elemental) try emitter.document.push(.group_open);
    if (!tight) try emitter.document.push(.group_open);

    try emit.emitted(emitter, position);
}

fn jsx_word(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);

    if (emitter.jsxed == 0) {
        emitter.previous = position;

        try emit.emitted(emitter, position);

        return;
    }

    if (walk.text_is(emitter.tokens[position].text(emitter.source), "<")) {
        jsx_frame_mut(emitter).angles += 1;
    }

    const frame = jsx_frame(emitter);
    const named = frame.stage == .opening and frame.named;

    if (!named) {
        try jsx_named(emitter, position);

        return;
    }

    if (emitter.tokens[position].kind == .comment) {
        try jsx_comment(emitter, position);

        return;
    }

    if (jsx_attributes(emitter, position)) try jsx_attribute(emitter);

    emitter.previous = position;

    try emit.emitted(emitter, position);
}

fn jsx_named(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);

    const identifier = emitter.tokens[position].kind == .identifier;
    const opening_stage = jsx_frame(emitter).stage == .opening;

    if (opening_stage) {
        const carried = jsx_named_carried(emitter, position);

        if (identifier) {
            if (!carried) jsx_frame_mut(emitter).named = true;
        }

        if (emitter.previous) |held| {
            if (comment_lined(emitter, held)) {
                try emitter.document.push(.hard_line);
            } else if (emitter.tokens[held].kind == .comment) {
                try emitter.document.push(.space);
            } else {}
        }
    }

    emitter.previous = position;

    try emit.emitted(emitter, position);

    if (opening_stage) {
        if (comment_lined(emitter, position)) jsx_frame_mut(emitter).commented = true;
    }
}

fn jsx_named_carried(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const next = emit.ahead_of(emitter, position) orelse return false;

    assert(next > position);

    const text = emitter.tokens[next].text(emitter.source);
    return walk.text_is(text, ".") or walk.text_is(text, ":");
}

fn jsx_attributes(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (jsx_frame(emitter).angles > 0) return false;

    const token = emitter.tokens[position];
    const held = token.kind == .identifier or walk.text_is(token.text(emitter.source), "{");
    if (!held) return false;

    const previous = jsx_coded_back(emitter, position) orelse return false;
    const text = emitter.tokens[previous].text(emitter.source);

    return !jsx_linking_word(text);
}

fn jsx_coded_back(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    var scan = emit.back_of(emitter, position) orelse return null;

    for (0..comment_scan_max) |_| {
        if (emitter.tokens[scan].kind != .comment) return scan;

        const held = emit.back_of(emitter, scan) orelse return null;

        assert(held < scan);

        scan = held;
    }

    return null;
}

fn jsx_linking_word(text: []const u8) bool {
    if (walk.text_is(text, "=")) return true;
    if (walk.text_is(text, ".")) return true;
    if (walk.text_is(text, ":")) return true;
    return walk.text_is(text, "<");
}

fn jsx_comment(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);

    const lined = comment_lined(emitter, position);

    if (jsx_comment_valued(emitter, position)) {
        try jsx_comment_value(emitter, position, lined);
    } else {
        if (jsx_comment_own(emitter, position)) {
            try jsx_attribute(emitter);
        } else {
            try emitter.document.push(.space);
        }

        emitter.previous = position;

        try emit.emitted(emitter, position);
    }

    jsx_frame_mut(emitter).commented = lined;
}

fn jsx_comment_valued(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.tokens[position].kind == .comment);

    const code = jsx_coded_back(emitter, position) orelse return false;
    return walk.text_is(emitter.tokens[code].text(emitter.source), "=");
}

fn jsx_comment_value(emitter: *Emitter, position: u32, lined: bool) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.tokens[position].kind == .comment);

    emitter.previous = position;

    try emit.emitted(emitter, position);

    const next = emit.ahead_of(emitter, position) orelse return;
    const parted = lined or body.parts_at(emitter, position, next);
    const separator: ir.Element = if (parted) .hard_line else .space;

    try emitter.document.push(separator);
}

fn jsx_comment_own(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const previous = emitter.previous orelse return true;
    return body.parts_at(emitter, previous, position);
}

fn jsx_attribute(emitter: *Emitter) error{Overflow}!void {
    assert(emitter.jsxed > 0);

    const frame = jsx_frame(emitter);
    const edge: ir.Element = if (frame.commented) .hard_line else .line;

    if (frame.tight) assert(!frame.commented);

    jsx_frame_mut(emitter).written += 1;
    jsx_frame_mut(emitter).commented = false;

    if (frame.tight) {
        try emitter.document.push(.space);

        return;
    }

    if (frame.written == 0) {
        jsx_frame_mut(emitter).grouped = true;

        try line.opens_broken(emitter);
        try emitter.document.push(edge);

        return;
    }

    try emitter.document.push(edge);
}

fn jsx_closes(emitter: *Emitter, position: u32, text: []const u8) error{Overflow}!void {
    assert(position < emitter.count);
    assert(text.len <= std.math.maxInt(u32));

    if (emitter.jsxed == 0) {
        emitter.previous = position;

        try emit.emitted(emitter, position);

        return;
    }

    const frame = jsx_frame(emitter);

    if (frame.angles > 0) {
        jsx_frame_mut(emitter).angles -= 1;
        emitter.previous = position;

        try emit.emitted(emitter, position);

        return;
    }

    if (frame.stage == .closing) {
        emitter.previous = position;

        try emit.emitted(emitter, position);

        emitter.jsxed -= 1;

        return;
    }

    try jsx_tagged(emitter, frame, text);

    emitter.previous = position;

    try emit.emitted(emitter, position);

    if (walk.text_is(text, "/>")) {
        emitter.jsxed -= 1;

        return;
    }

    jsx_frame_mut(emitter).stage = .children;

    try jsx_children(emitter, position);
}

fn jsx_tagged(emitter: *Emitter, frame: Tag, text: []const u8) error{Overflow}!void {
    assert(text.len <= std.math.maxInt(u32));
    assert(frame.open <= frame.close);

    if (frame.tight) {
        assert(!frame.commented);

        if (walk.text_is(text, "/>")) try emitter.document.push(.space);

        return;
    }

    if (frame.grouped) {
        const edge: ir.Element = jsx_tagged_edge(frame, text);

        try line.closes_broken(emitter);
        try emitter.document.push(edge);
    } else if (frame.commented) {
        try emitter.document.push(.hard_line);
    } else {
        if (walk.text_is(text, "/>")) try emitter.document.push(.space);
    }

    try emitter.document.push(.group_close);
}

fn jsx_tagged_edge(frame: Tag, text: []const u8) ir.Element {
    assert(text.len <= std.math.maxInt(u32));
    assert(frame.open <= frame.close);

    if (frame.commented) return .hard_line;
    if (walk.text_is(text, "/>")) return .line;
    return .soft_line;
}

fn jsx_children(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);

    const frame = jsx_frame(emitter);
    if (jsx_empty(emitter, position, frame.close)) return;
    if (jsx_templated(emitter, position)) return;

    jsx_frame_mut(emitter).inside = true;
    jsx_frame_mut(emitter).first = true;
    jsx_frame_mut(emitter).gap = .none;

    const texted = jsx_worded(emitter, position, frame.close);
    var led = false;

    if (texted) {
        if (!frame.wide) led = jsx_led(emitter, position);
    }

    jsx_frame_mut(emitter).filled = texted;
    jsx_frame_mut(emitter).led = led;

    try jsx_children_opened(emitter, frame);

    if (led) {
        try jsx_spacing(emitter);
        try emitter.document.push(.soft_line);
    }

    if (!texted) return;

    try emitter.document.push(.group_open);
    try emitter.document.push(.{ .filled = ir.fill_softs });
}

fn jsx_children_opened(emitter: *Emitter, frame: Tag) error{Overflow}!void {
    assert(frame.open <= frame.close);

    if (!frame.elemental) try emitter.document.push(.group_open);

    if (frame.wide) {
        try emitter.document.push(.indent);
        try emitter.document.push(.hard_line);

        return;
    }

    try line.opens_broken(emitter);
    try emitter.document.push(.soft_line);
}

fn jsx_templated(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const open = jsx_templated_open(emitter, position) orelse return false;
    const shut = join.closing_of(emitter, open) orelse return false;

    assert(shut > open);

    if (!jsx_templated_closed(emitter, shut)) return false;

    var head = open + 1;

    while (head < shut) {
        assert(head < emitter.count);

        if (!jsx_templated_worded(emitter, head)) break;

        head += 1;
    }

    if (head >= shut) return false;

    const last = tmpl.template_whole(emitter, head) orelse return false;
    const after = emit.ahead_of(emitter, last) orelse return false;

    assert(after > last);

    return after == shut;
}

fn jsx_templated_open(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    const open = emit.ahead_of(emitter, position) orelse return null;

    assert(open > position);

    if (!emit.roled(emitter, open, brace.role_jsx_hole)) return null;
    if (emitter.tokens[open].offset != emitter.tokens[position].end()) return null;
    return open;
}

fn jsx_templated_closed(emitter: *const Emitter, shut: u32) bool {
    assert(shut < emitter.count);

    const end = emit.ahead_of(emitter, shut) orelse return false;

    assert(end > shut);

    if (!walk.text_is(emitter.tokens[end].text(emitter.source), "</")) return false;
    return emitter.tokens[end].offset == emitter.tokens[shut].end();
}

fn jsx_templated_worded(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);

    if (emitter.tokens[head].kind == .identifier) return true;

    const text = emitter.tokens[head].text(emitter.source);
    return walk.text_is(text, ".") or walk.text_is(text, "");
}

fn jsx_led(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const first = emit.ahead_of(emitter, position) orelse return false;

    assert(first > position);

    const from = emitter.tokens[position].end();
    const blanks = jsx_led_blanks(emitter, from);

    if (blanks > 0) {
        if (!jsx_led_lined(emitter, from + blanks)) {
            return !walk.text_is(emitter.tokens[first].text(emitter.source), "</");
        }
    }

    if (!emit.roled(emitter, first, brace.role_jsx_hole)) return false;
    if (!emit.roled(emitter, first, brace.role_jsx_child)) return false;

    const held = emit.ahead_of(emitter, first) orelse return false;

    assert(held > first);

    const text = emitter.tokens[held].text(emitter.source);
    const spaced = walk.text_is(text, "\" \"") or walk.text_is(text, "' '");
    if (!spaced) return false;

    const close = emit.ahead_of(emitter, held) orelse return false;

    assert(close > held);

    return emitter.tokens[close].kind == .block_end;
}

fn jsx_led_blanks(emitter: *const Emitter, from: u32) u32 {
    assert(from <= emitter.source.len);

    var count: u32 = 0;

    while (from + count < emitter.source.len) {
        const byte = emitter.source[from + count];
        const indented = byte == ' ' or byte == '\t';
        if (!indented) break;

        count += 1;
    }

    return count;
}

fn jsx_led_lined(emitter: *const Emitter, at: u32) bool {
    assert(at <= emitter.source.len);

    if (at >= emitter.source.len) return true;

    const byte = emitter.source[at];
    return byte == '\n' or byte == '\r';
}

fn jsx_empty(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position < close);
    assert(close < emitter.count);

    var scan = position + 1;

    while (scan < close) {
        const held = scan;

        scan += 1;

        if (jsx_empty_at(emitter, held, position)) |result| return result;
    }

    return true;
}

fn jsx_empty_at(emitter: *const Emitter, held: u32, position: u32) ?bool {
    assert(held < emitter.count);
    assert(position < emitter.count);

    const token = emitter.tokens[held];
    if (token.kind == .newline) return null;
    if (token.length == 0) return null;

    if (!emit.roled(emitter, held, brace.role_jsx_text)) {
        const text = token.text(emitter.source);
        if (!walk.text_is(text, "</")) return false;

        const from = emitter.tokens[position].end();
        const gap_text = emitter.source[from..token.offset];

        return gap_text.len == 0 or std.mem.findScalar(u8, gap_text, '\n') != null;
    }

    const text = token.text(emitter.source);

    for (text) |byte| {
        if (!jsx_space(byte)) return false;
    }

    if (std.mem.findScalar(u8, text, '\n') == null) return false;
    return null;
}

fn jsx_worded(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position < close);
    assert(close < emitter.count);

    var childed = false;
    var spaced = false;
    var previous = position;
    var scan = position + 1;

    while (scan < close) {
        const held = scan;
        if (walk.text_is(emitter.tokens[held].text(emitter.source), "</")) break;

        if (jsx_worded_spaced(emitter, previous, held)) spaced = true;

        if (span.jsx_body(emitter, held)) |end| {
            childed = true;
            previous = end;
            scan = end + 1;

            continue;
        }

        if (emitter.tokens[held].kind == .block_start) {
            const end = join.closing_of(emitter, held) orelse close;

            if (jsx_worded_hole(emitter, held, end)) {
                spaced = true;
            } else {
                childed = true;
            }

            previous = end;
            scan = end + 1;

            continue;
        }

        previous = held;
        scan += 1;

        switch (jsx_worded_texted(emitter, held)) {
            .word => return true,
            .space => spaced = true,
            .none => {},
        }
    }

    if (scan < close) {
        if (jsx_worded_spaced(emitter, previous, scan)) spaced = true;
    }

    return spaced and childed;
}

fn jsx_worded_spaced(emitter: *const Emitter, previous: u32, position: u32) bool {
    assert(previous < position);
    assert(position < emitter.count);

    const from = emitter.tokens[previous].end();
    const to = emitter.tokens[position].offset;
    if (from >= to) return false;
    return jsx_worded_text(emitter.source[from..to]) == .space;
}

fn jsx_worded_hole(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close <= emitter.count);

    if (close != open + 2) return false;

    const text = emitter.tokens[open + 1].text(emitter.source);
    return walk.text_is(text, "\" \"") or walk.text_is(text, "' '");
}

fn jsx_worded_texted(emitter: *const Emitter, held: u32) Worded {
    assert(held < emitter.count);

    if (!emit.roled(emitter, held, brace.role_jsx_text)) return .none;
    if (emitter.tokens[held].length == 0) return .none;
    return jsx_worded_text(emitter.tokens[held].text(emitter.source));
}

fn jsx_worded_text(text: []const u8) Worded {
    var lined = false;

    assert(text.len > 0);
    assert(text.len <= std.math.maxInt(u32));

    for (text) |byte| {
        if (!jsx_space(byte)) return .word;

        if (byte == '\n') lined = true;
    }

    return if (lined) .none else .space;
}

fn jsx_ends_token(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);

    if (emitter.jsxed == 0) {
        emitter.previous = position;

        try emit.emitted(emitter, position);

        return;
    }

    const frame = jsx_frame(emitter);

    jsx_frame_mut(emitter).stage = .closing;

    const trailed = frame.inside and frame.filled and !frame.wide;

    if (frame.gap == .space) {
        if (!trailed) try jsx_edge_space(emitter, frame.wide, false);
    }

    if (frame.inside) {
        try jsx_ends_inside(emitter, frame, trailed);
    } else if (frame.elemental) {
        try emitter.document.push(.group_close);
    } else {}

    emitter.previous = position;

    try emit.emitted(emitter, position);
}

fn jsx_ends_inside(emitter: *Emitter, frame: Tag, trailed: bool) error{Overflow}!void {
    assert(frame.open <= frame.close);

    if (frame.filled) try emitter.document.push(.group_close);

    if (trailed) {
        if (frame.gap == .space) try jsx_spacing(emitter);
    }

    if (frame.wide) {
        try emitter.document.push(.dedent);
        try emitter.document.push(.hard_line);
    } else {
        try line.closes_broken(emitter);
        try emitter.document.push(.soft_line);
    }

    try emitter.document.push(.group_close);
}

fn jsx_hole(emitter: *Emitter, position: u32, text: []const u8) error{Overflow}!void {
    assert(position < emitter.count);
    assert(text.len <= std.math.maxInt(u32));

    if (walk.text_is(text, "}")) {
        try jsx_hole_closed(emitter, position);

        return;
    }

    if (emit.roled(emitter, position, brace.role_jsx_child)) {
        if (jsx_spacer(emitter, position)) |close| {
            emitter.previous = close;
            emitter.resume_at = close + 1;

            jsx_frame_mut(emitter).gap = .space;

            return;
        }

        try jsx_separates(emitter, position, .expression);
    } else if (emitter.jsxed > 0) {
        if (jsx_frame(emitter).stage == .opening) {
            if (jsx_attributes(emitter, position)) try jsx_attribute(emitter);
        }
    } else {}

    emitter.previous = position;

    if (!jsx_blocked(emitter, position)) {
        try emit.emitted(emitter, position);

        return;
    }

    jsx_frame_mut(emitter).holed = true;

    try emitter.document.push(.group_open);
    try emit.emitted(emitter, position);
    try line.opens_broken(emitter);
    try emitter.document.push(.soft_line);
}

fn jsx_hole_closed(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);

    const grouped = emitter.jsxed > 0 and jsx_frame(emitter).holed;

    if (grouped) {
        const lined = if (emitter.previous) |held| comment_lined(emitter, held) else false;
        const edge: ir.Element = if (lined) .hard_line else .soft_line;

        jsx_frame_mut(emitter).holed = false;

        try line.closes_broken(emitter);
        try emitter.document.push(edge);
    }

    emitter.previous = position;

    try emit.emitted(emitter, position);

    if (grouped) try emitter.document.push(.group_close);
}

fn jsx_blocked(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (emitter.jsxed == 0) return false;

    const close = join.closing_of(emitter, open) orelse return false;

    assert(close > open);

    if (close <= open + 1) return false;
    if (jsx_hole_commented(emitter, open, close)) return true;
    if (jsx_frame(emitter).filled) return false;

    if (!emit.roled(emitter, open, brace.role_jsx_child)) {
        if (jsx_operated(emitter, open, close)) return true;
    }

    if (jsx_unary(emitter, open, close)) return true;

    var scan = open + 1;

    while (scan < close) {
        assert(scan < emitter.count);

        if (!jsx_blocked_held(emitter, scan)) return false;

        scan += 1;
    }

    return true;
}

fn jsx_hole_commented(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const first = emit.ahead_of(emitter, open) orelse return false;
    const last = emit.back_of(emitter, close) orelse return false;

    if (first >= close) return false;

    assert(last > open);

    var coded = false;
    var lined = false;

    for (emitter.tokens[first .. last + 1], first..) |token, scan| {
        if (token.kind == .newline) continue;
        if (token.length == 0) continue;

        if (token.kind != .comment) {
            coded = true;
        } else if (comment_lined(emitter, @intCast(scan))) {
            lined = true;
        } else {}
    }

    if (!coded) return lined;
    if (emitter.tokens[first].kind == .comment) return true;
    return emitter.tokens[last].kind == .comment;
}

fn jsx_blocked_held(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);

    const token = emitter.tokens[scan];
    if (token.kind == .identifier) return true;
    if (token.kind == .keyword) return true;
    if (token.kind == .number) return true;
    if (token.kind == .newline) return true;

    if (token.kind == .string) {
        const text = token.text(emitter.source);
        if (text.len == 0) return false;
        return text[0] == '"' or text[0] == '\'';
    }

    if (token.length == 0) return true;

    const text = token.text(emitter.source);
    return walk.text_is(text, ".") or walk.text_is(text, "?.");
}

fn jsx_unary(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const first = emit.ahead_of(emitter, open) orelse return false;

    assert(first > open);

    const text = emitter.tokens[first].text(emitter.source);

    if (emit.roled(emitter, first, brace.role_jsx)) {
        if (walk.text_is(text, "<")) return jsx_unary_tagged(emitter, first, close);
    }

    if (!word_listed(&jsx_unary_words, text)) return false;
    return !jsx_operated(emitter, open, close);
}

fn jsx_unary_tagged(emitter: *const Emitter, first: u32, close: u32) bool {
    assert(first < emitter.count);

    const end = span.jsx_body(emitter, first) orelse return false;
    const after = emit.ahead_of(emitter, end) orelse return false;

    assert(after > end);

    return after == close;
}

fn jsx_operated(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var operated = false;
    var scan = open + 1;

    while (scan < close) {
        assert(scan < emitter.count);

        if (tmpl.template_body(emitter, scan) orelse span.jsx_body(emitter, scan)) |end| {
            scan = end + 1;

            continue;
        }

        const token = emitter.tokens[scan];
        const opens = walk.is_open(token.kind) or token.kind == .block_start;
        const closes = walk.is_close(token.kind) or token.kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            if (jsx_operated_closed(emitter, scan)) return operated;

            if (jsx_operated_marked(emitter, scan)) operated = true;
        } else {}

        scan += 1;
    }

    return operated;
}

fn jsx_operated_closed(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);

    const text = emitter.tokens[scan].text(emitter.source);
    if (walk.text_is(text, "=>")) return true;
    if (walk.text_is(text, "function")) return true;
    return walk.text_is(text, "async");
}

fn jsx_operated_marked(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);

    if (span.binary_rank(emitter, scan) != null) return true;

    const text = emitter.tokens[scan].text(emitter.source);
    if (word_listed(&jsx_cast_words, text)) return true;
    if (!walk.text_is(text, "?")) return false;
    return !tern.optional(emitter, scan);
}

fn jsx_spacer(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    if (emitter.jsxed == 0) return null;
    if (jsx_frame(emitter).stage != .children) return null;

    const held = emit.ahead_of(emitter, position) orelse return null;

    assert(held > position);

    const close = emit.ahead_of(emitter, held) orelse return null;

    assert(close > held);

    if (emitter.tokens[close].kind != .block_end) return null;

    const text = emitter.tokens[held].text(emitter.source);
    const spaced = walk.text_is(text, "\" \"") or walk.text_is(text, "' '");
    if (!spaced) return null;
    return close;
}

fn jsx_text(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);

    const text = emitter.tokens[position].text(emitter.source);
    const text_len: u32 = @intCast(text.len);
    const carried = jsx_text_carried(emitter, position);
    var written = !emit.roled(emitter, position, brace.role_jsx_child);
    var scan: u32 = 0;

    while (scan < text_len) {
        const white = jsx_space(text[scan]);
        var stop = scan;

        while (stop < text_len) {
            if (jsx_space(text[stop]) != white) break;

            stop += 1;
        }

        const chunk = text[scan..stop];

        if (white) {
            try jsx_text_blank(emitter, chunk, written, stop == text_len, carried);
        } else {
            try jsx_text_worded(emitter, position, chunk, scan, stop, text_len, written);

            written = true;
        }

        scan = stop;
    }

    emitter.previous = position;
}

fn jsx_text_carried(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const held = emit.ahead_of(emitter, position) orelse return false;

    assert(held > position);

    if (!emit.roled(emitter, held, brace.role_jsx_text)) return false;
    return !emit.roled(emitter, held, brace.role_jsx_child);
}

fn jsx_text_blank(
    emitter: *Emitter,
    chunk: []const u8,
    written: bool,
    ending: bool,
    carried: bool,
) error{Overflow}!void {
    assert(chunk.len <= std.math.maxInt(u32));

    const held = gap(chunk);

    if (written) {
        if (ending) {
            if (!carried) {
                jsx_held_gap(emitter, held);

                return;
            }
        }

        try emitter.document.push(.line);

        return;
    }

    if (emitter.jsxed == 0) return;

    const capped = held == .blank and !ending;
    const result: Gap = if (capped) .line else held;

    jsx_held_gap(emitter, result);
}

fn jsx_text_worded(
    emitter: *Emitter,
    position: u32,
    chunk: []const u8,
    scan: u32,
    stop: u32,
    text_len: u32,
    written: bool,
) error{Overflow}!void {
    assert(position < emitter.count);
    assert(scan < stop);
    assert(stop <= text_len);
    assert(chunk.len == stop - scan);

    const single = jsx_text_single(emitter, position, scan, stop, text_len);
    const held: Held = .{ .word = single };

    if (written) {
        jsx_frame_or(emitter, held);
    } else {
        try jsx_separates(emitter, position, held);
    }

    const offset = emitter.tokens[position].offset;
    const literal = Span.between(offset + scan, offset + stop);
    const commented = std.mem.startsWith(u8, chunk, "//");
    const word: ir.Element = if (commented) .{ .chunk = literal } else .{ .verbatim = literal };

    try emitter.document.push(word);

    if (emitter.jsxed > 0) jsx_frame_mut(emitter).gap = .none;
}

fn jsx_text_single(
    emitter: *const Emitter,
    position: u32,
    scan: u32,
    stop: u32,
    text_len: u32,
) bool {
    assert(position < emitter.count);
    assert(scan <= stop);

    const chunk = emitter.tokens[position].text(emitter.source)[scan..stop];
    if (lettered(chunk) != 1) return false;

    if (stop == text_len) {
        if (jsx_glued(emitter, position, true)) return false;
    }

    if (scan == 0) {
        if (jsx_glued(emitter, position, false)) return false;
    }

    return true;
}

fn jsx_glued(emitter: *const Emitter, position: u32, after: bool) bool {
    assert(position < emitter.count);

    const found = jsx_glued_found(emitter, position, after) orelse return false;
    if (!emit.roled(emitter, found, brace.role_jsx_text)) return false;

    const text = emitter.tokens[found].text(emitter.source);

    const byte: u8 = if (after)
        (if (text.len > 0) text[0] else return false)
    else
        (if (text.len > 0) text[text.len - 1] else return false);

    return !jsx_space(byte);
}

fn jsx_glued_found(emitter: *const Emitter, position: u32, after: bool) ?u32 {
    assert(position < emitter.count);

    const token = emitter.tokens[position];

    if (after) {
        const held = emit.ahead_of(emitter, position) orelse return null;

        assert(held > position);

        if (emitter.tokens[held].offset != token.end()) return null;
        return held;
    }

    const held = emit.back_of(emitter, position) orelse return null;

    assert(held < position);

    if (emitter.tokens[held].end() != token.offset) return null;
    return held;
}

fn jsx_separates(emitter: *Emitter, position: u32, next: Held) error{Overflow}!void {
    assert(position < emitter.count);
    assert(next != .none);

    if (emitter.jsxed == 0) return;

    const frame = jsx_frame(emitter);
    if (!frame.inside) return;
    if (frame.stage != .children) return;

    jsx_frame_mut(emitter).held = next;
    jsx_frame_mut(emitter).first = false;
    jsx_frame_mut(emitter).gap = .none;

    if (frame.first) {
        if (frame.gap != .space) return;
        if (frame.led) return;

        try jsx_edge_space(emitter, frame.wide, true);

        return;
    }

    const held_gap = jsx_gap(emitter, position, frame.gap);

    if (held_gap == .space) {
        try jsx_spaced(emitter);

        return;
    }

    if (held_gap == .blank) {
        const element: ir.Element = if (frame.filled) .hard_line else .{ .blank_line = 1 };

        try emitter.document.push(element);

        return;
    }

    if (held_gap == .line) {
        const element: ir.Element = if (jsx_lined(frame.held, next)) .soft_line else .hard_line;

        try emitter.document.push(element);

        return;
    }

    try jsx_separates_soft(emitter, frame.held, next);
}

fn jsx_separates_soft(emitter: *Emitter, held: Held, next: Held) error{Overflow}!void {
    assert(held != .none);
    assert(next != .none);

    const soft = jsx_soft(held, next);
    const both_plain = held.eql(.{ .word = false }) and next.eql(.{ .word = false });
    const separated = soft or both_plain;

    if (separated) {
        const element: ir.Element = if (paired(held, next)) .line else .soft_line;

        try emitter.document.push(element);

        return;
    }

    try emitter.document.push(.hard_line);
}

fn jsx_self_closing(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const close = span.jsx_body(emitter, position) orelse position;
    return walk.text_is(emitter.tokens[close].text(emitter.source), "/>");
}

fn jsx_gap(emitter: *const Emitter, position: u32, held: Gap) Gap {
    assert(position < emitter.count);

    const previous = emitter.previous orelse return held;
    const from = emitter.tokens[previous].end();
    const to = emitter.tokens[position].offset;
    if (from >= to) return held;
    if (held == .space) return held;
    return stronger(held, gap(emitter.source[from..to]));
}

fn jsx_held_gap(emitter: *Emitter, held: Gap) void {
    if (emitter.jsxed == 0) return;
    if (jsx_frame(emitter).gap == .space) return;

    jsx_frame_mut(emitter).gap = held;
}

fn jsx_frame_or(emitter: *Emitter, held: Held) void {
    if (emitter.jsxed == 0) return;

    jsx_frame_mut(emitter).held = held;
}

fn jsx_spaced(emitter: *Emitter) error{Overflow}!void {
    try jsx_spacing(emitter);
    try emitter.document.push(.soft_line);
}

fn jsx_edge_space(emitter: *Emitter, wide: bool, leading: bool) error{Overflow}!void {
    if (!wide) {
        try jsx_spacing(emitter);

        if (leading) try emitter.document.push(.soft_line);

        return;
    }

    try emitter.document.push(.{ .text = .{ .source = .literal, .span = emitter.hole } });

    if (leading) try emitter.document.push(.hard_line);
}

fn jsx_spacing(emitter: *Emitter) error{Overflow}!void {
    try emitter.document.push(.{ .if_broken = emitter.hole });
    try emitter.document.push(.{ .if_flat = emitter.spaced });
}

fn word_listed(words: []const []const u8, word: []const u8) bool {
    assert(words.len > 0);
    assert(word.len <= std.math.maxInt(u32));

    for (words) |listed| {
        if (walk.text_eql(listed, word)) return true;
    }

    return false;
}

fn jsx_space(byte: u8) bool {
    if (byte > ' ') return false;

    return std.mem.findScalar(u8, &jsx_whitespace, byte) != null;
}

fn stronger(held: Gap, found: Gap) Gap {
    if (ranked(found) > ranked(held)) return found;
    return held;
}

fn ranked(held: Gap) u32 {
    return switch (held) {
        .start => 0,
        .none => 1,
        .space => 2,
        .line => 3,
        .blank => 4,
    };
}

fn paired(before: Held, after: Held) bool {
    if (std.meta.activeTag(before) != .word) return false;
    if (std.meta.activeTag(after) != .word) return false;
    return true;
}

fn jsx_lined(before: Held, after: Held) bool {
    assert(before != .none);
    assert(after != .none);

    switch (before) {
        .word => |single| {
            if (!single) return false;
            return !after.eql(.{ .tag = true });
        },
        else => {},
    }

    switch (after) {
        .word => |single| return single,
        else => return false,
    }
}

fn jsx_soft(before: Held, after: Held) bool {
    assert(before != .none);
    assert(after != .none);

    const before_word = std.meta.activeTag(before) == .word;
    const after_word = std.meta.activeTag(after) == .word;
    const both_word = before_word and after_word;
    if (both_word) return true;

    if (before_word) {
        if (after.eql(.{ .tag = true })) return before.word;
        return true;
    }

    if (after_word) {
        if (before.eql(.{ .tag = true })) return after.word;
        return true;
    }

    return false;
}

fn lettered(word: []const u8) u32 {
    assert(word.len <= std.math.maxInt(u32));

    var count: u32 = 0;

    for (word) |byte| {
        if (byte & 0xC0 != 0x80) count += 1;
    }

    return count;
}

fn gap(chunk: []const u8) Gap {
    assert(chunk.len <= std.math.maxInt(u32));

    var lines: u32 = 0;

    for (chunk) |byte| {
        if (byte == '\n') lines += 1;
    }

    if (lines > 1) return .blank;
    if (lines == 1) return .line;
    return .space;
}

pub fn chain_opens(
    emitter: *Emitter,
    position: u32,
    question: u32,
    close: u32,
) error{Overflow}!void {
    assert(position <= close);
    assert(emitter.wraps_owed <= core.wrap_depth_max);
    assert(question < emitter.count);

    if (chain_opens_nested(emitter, position, question)) return;
    if (emitter.wraps_owed == core.wrap_depth_max) return;

    emitter.wrapped[emitter.wraps_owed] = .{
        .close = close,
        .wrap = .chained,
        .depth = emitter.depth,
        .floor = question,
        .start = position,
    };

    emitter.wraps_armed[emitter.wraps_owed] = false;
    emitter.wraps_nested[emitter.wraps_owed] = core.nest_none;
    emitter.wraps_owed += 1;

    try emitter.document.push(.group_open);
}

fn chain_opens_nested(emitter: *const Emitter, position: u32, question: u32) bool {
    assert(emitter.wraps_owed <= core.wrap_depth_max);
    assert(question < emitter.count);

    var index: u32 = 0;

    while (index < emitter.wraps_owed) {
        const held = emitter.wrapped[index];

        index += 1;

        if (held.wrap != .chained) continue;
        if (position > held.close) continue;
        if (jsx_chain_alternate(emitter, held.floor, held.close, question)) return true;
    }

    return false;
}

pub fn unframed(emitter: *const Emitter) bool {
    assert(emitter.jsxed <= core.jsx_depth_max);

    if (emitter.jsxed == 0) return false;
    if (emitter.depth == 0) return true;
    return line.frame(emitter).open < jsx_frame(emitter).open;
}

pub fn arrow_bodied(emitter: *const Emitter, arrow: u32) ?u32 {
    assert(arrow < emitter.count);

    if (!walk.text_is(emitter.tokens[arrow].text(emitter.source), "=>")) return null;

    const before = emit.back_of(emitter, arrow) orelse return null;

    assert(before < arrow);

    var first = arrow_bodied_first(emitter, before) orelse return null;

    if (emit.back_of(emitter, first)) |held| {
        if (walk.text_is(emitter.tokens[held].text(emitter.source), "async")) first = held;
    }

    const open = jsx_hole_before(emitter, first) orelse return null;
    const close = join.closing_of(emitter, open) orelse return null;

    assert(close > open);

    const head = emit.ahead_of(emitter, arrow) orelse return null;

    assert(head > arrow);

    if (head >= close) return null;
    if (call.bodied_arrow(emitter, head, close)) return null;
    if (call.ternary_bodied(emitter, head, close)) return null;

    const last = emit.word_before(emitter, close) orelse return null;
    if (last < head) return null;
    return last;
}

fn arrow_bodied_first(emitter: *const Emitter, before: u32) ?u32 {
    assert(before < emitter.count);

    const token = emitter.tokens[before];
    if (token.is_punctuation(.paren_close)) return emitter.brackets.open_of(before);
    if (token.kind == .identifier) return before;
    return null;
}

pub fn operand_head(emitter: *const Emitter, start: u32) u32 {
    assert(start < emitter.count);

    var head = start;

    for (0..comment_scan_max) |_| {
        const text = emitter.tokens[head].text(emitter.source);
        if (!word_listed(&jsx_operand_prefixes, text)) break;

        const next = emit.ahead_of(emitter, head) orelse break;

        assert(next > head);

        head = next;
    }

    assert(head >= start);

    return head;
}

pub fn parens_closing(emitter: *Emitter, wrap: core.Wrap, floor: u32) error{Overflow}!void {
    assert(emitter.wrapped[emitter.wraps_owed].wrap == wrap);

    if (wrap == .tagged) {
        if (floor == parens_written) {
            try emitter.document.push(.{
                .text = .{ .source = .literal, .span = emitter.closing },
            });

            return;
        }
    }

    try emitter.document.push(.{ .if_broken = emitter.closing });
}

fn jsx_parenthesized(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position <= close);
    assert(close < emitter.count);

    if (jsx_parenthesized_prefixed(emitter, position)) return true;
    if (jsx_parenthesized_suffixed(emitter, close)) return true;
    return jsx_parenthesized_sequenced(emitter, position, close);
}

fn jsx_parenthesized_prefixed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const before = emit.back_of(emitter, position) orelse return false;

    assert(before < position);

    return word_listed(&jsx_parenthesized_prefixes, emitter.tokens[before].text(emitter.source));
}

fn jsx_parenthesized_suffixed(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);

    const after = emit.ahead_of(emitter, close) orelse return false;

    assert(after > close);

    return word_listed(&jsx_parenthesized_suffixes, emitter.tokens[after].text(emitter.source));
}

fn jsx_parenthesized_sequenced(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position <= close);

    const before = emit.back_of(emitter, position);
    const after = emit.ahead_of(emitter, close);

    const comma = jsx_parenthesized_commaed(emitter, before) or
        jsx_parenthesized_commaed(emitter, after);

    if (!comma) return false;
    if (emitter.depth == 0) return false;

    const enclosing = line.frame(emitter);
    if (!enclosing.kind.eql(.{ .punctuation = .paren_open })) return false;
    return !list.calling(emitter, enclosing.open);
}

fn jsx_parenthesized_commaed(emitter: *const Emitter, held: ?u32) bool {
    if (held) |unwrapped| assert(unwrapped < emitter.count);

    const position = held orelse return false;

    assert(position < emitter.count);

    return emitter.tokens[position].is_punctuation(.comma);
}

pub fn ended(emitter: *const Emitter, stop: u32) bool {
    assert(stop < emitter.count);

    if (emitter.tokens[stop].is_punctuation(.paren_close)) {
        const head = ended_parenthesized(emitter, stop) orelse return false;
        return ended_tagged(emitter, head, stop);
    }

    const head = ended_framed(emitter, stop) orelse return ended_at(emitter, stop);
    return ended_tagged(emitter, head, stop);
}

fn ended_parenthesized(emitter: *const Emitter, stop: u32) ?u32 {
    assert(stop < emitter.count);

    const open = emitter.brackets.open_of(stop) orelse return null;

    assert(open < stop);

    return emit.ahead_of(emitter, open);
}

fn ended_framed(emitter: *const Emitter, stop: u32) ?u32 {
    assert(emitter.jsxed <= core.jsx_depth_max);

    var index: u32 = 0;

    while (index < emitter.jsxed) {
        const tag = emitter.jsx[index];
        if (tag.close == stop) return tag.open;

        index += 1;
    }

    return null;
}

fn ended_tagged(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head < emitter.count);
    assert(stop < emitter.count);

    if (!emit.roled(emitter, head, brace.role_jsx)) return false;

    const end = span.jsx_body(emitter, head) orelse return false;
    if (end == stop) return true;

    const after = emit.ahead_of(emitter, end) orelse return false;

    assert(after > end);

    return after == stop;
}

fn ended_at(emitter: *const Emitter, stop: u32) bool {
    assert(stop < emitter.count);

    if (!emit.roled(emitter, stop, brace.role_jsx_tag)) return false;

    const text = emitter.tokens[stop].text(emitter.source);
    const tagged = walk.text_is(text, ">") or walk.text_is(text, "/>");
    if (!tagged) return false;

    var scan = stop;

    for (0..jsx_end_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;

        assert(held < scan);

        if (ended_at_opened(emitter, held, stop)) return true;

        scan = held;
    }

    return false;
}

fn ended_at_opened(emitter: *const Emitter, held: u32, stop: u32) bool {
    assert(held < emitter.count);

    if (!emit.roled(emitter, held, brace.role_jsx)) return false;
    if (!walk.text_is(emitter.tokens[held].text(emitter.source), "<")) return false;

    const end = span.jsx_body(emitter, held) orelse return false;
    return end == stop;
}

pub fn element_end(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!walk.text_is(emitter.tokens[position].text(emitter.source), "<")) return null;

    const close = span.jsx_body(emitter, position) orelse return null;
    const text = emitter.source[emitter.tokens[position].offset..emitter.tokens[close].end()];
    if (std.mem.findScalar(u8, text, '\n') != null) return null;
    return close;
}
