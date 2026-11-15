const std = @import("std");
const assert = std.debug.assert;
const brace = @import("../brace.zig");
const core = @import("emitter.zig");
const emit = @import("emit.zig");
const line = @import("line.zig");
const walk = @import("../walk.zig");
const Emitter = core.Emitter;

fn asm_paren(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.policy.asm_operands);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const held = emit.back_of(emitter, open) orelse return false;
    const text = emitter.tokens[held].text(emitter.source);

    assert(held < open);

    if (walk.text_is(text, "asm")) return true;
    return walk.text_is(text, "volatile");
}

pub fn asm_sectioned(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.asm_operands) return false;

    const open = asm_sectioned_open(emitter) orelse return false;
    const close = emitter.brackets.close_of(open) orelse return false;

    assert(open < close);

    var sectioned = false;
    var operands = false;
    var scan = open + 1;

    while (scan < close) {
        const kind = emitter.tokens[scan].kind;
        const colon = kind.eql(.{ .punctuation = .colon });

        sectioned = sectioned or (scan < position and colon);
        operands = operands or kind.eql(.{ .punctuation = .bracket_open });

        const stepped = asm_sectioned_step(emitter, scan, close);

        assert(stepped > scan);
        assert(stepped <= emitter.count);

        scan = stepped;
    }

    return sectioned and operands;
}

fn asm_sectioned_open(emitter: *const Emitter) ?u32 {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.policy.asm_operands);

    var index = emitter.depth;

    while (index > 0) {
        index -= 1;

        const open = emitter.nest[index].open;
        if (asm_paren(emitter, open)) return open;
    }

    return null;
}

fn asm_sectioned_step(emitter: *const Emitter, scan: u32, close: u32) u32 {
    assert(scan < close);
    assert(close < emitter.count);

    if (!walk.is_open(emitter.tokens[scan].kind)) {
        assert(scan + 1 <= emitter.count);

        return scan + 1;
    }

    const held = emitter.brackets.close_of(scan) orelse return close;

    assert(held > scan);

    return held + 1;
}

pub fn asm_closed(emitter: *const Emitter, leading: u32) ?u32 {
    assert(leading < emitter.count);

    const given = emitter.asm_given orelse return null;

    assert(given < emitter.count);

    if (given != leading) return null;
    return emitter.levels;
}

fn asm_closing(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    var depth = emitter.depth;
    var scan = position;

    while (depth > 0) {
        const frame = emitter.nest[depth - 1];
        if (frame.close != scan) return null;

        if (frame.aligned) {
            assert(depth - 1 < std.math.maxInt(u32));

            return depth - 1;
        }

        if (frame.indents) return null;

        depth -= 1;
        scan = emit.ahead_of(emitter, scan) orelse return null;
    }

    return null;
}

pub fn asm_colons_tight(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (!emitter.tokens[position].is_punctuation(.colon)) return false;
    if (!emitter.tokens[previous].is_punctuation(.colon)) return false;
    return asm_framed(emitter);
}

pub fn asm_framed(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.asm_operands) return false;
    if (emitter.depth == 0) return false;

    const open = line.frame(emitter).open;

    assert(open < emitter.count);

    return asm_paren(emitter, open);
}

pub fn asm_templated(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth <= 1) return false;

    const open = emitter.nest[emitter.depth - 2].open;

    assert(open < emitter.count);

    return asm_opens(emitter, open);
}

pub fn asm_stepped(emitter: *const Emitter, head: u32) u32 {
    assert(head < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const open = line.frame(emitter).open;

    if (!asm_framed(emitter)) return 0;
    if (head <= open) return 0;

    const open_start = asm_stepped_start(emitter, open);
    const head_start = asm_stepped_start(emitter, head);
    if (open_start != head_start) return 0;
    return 1;
}

fn asm_stepped_start(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    const held = line.at(emitter, position) orelse return null;

    assert(held.start > 0);

    return held.start;
}

pub fn asm_opens(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.line_first <= emitter.count);

    if (!emitter.policy.asm_operands) return false;
    if (open < emitter.line_first) return false;
    return asm_paren(emitter, open);
}

pub fn asm_enclosed(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.asm_operands) return false;

    var index = emitter.depth;

    while (index > 0) {
        index -= 1;

        if (asm_paren(emitter, emitter.nest[index].open)) return true;
    }

    return false;
}

pub fn asm_aligns(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const token = emitter.tokens[position];

    if (asm_closing(emitter, position)) |index| {
        assert(index < emitter.depth);

        emitter.nest[index].aligned = false;
        emitter.asm_given = position;

        try emitter.document.push(.dealign);
    }

    const open = emitter.asm_aligned orelse return;
    const framed = emitter.depth > 0 and line.frame(emitter).open == open;
    const sectioned = framed and token.is_punctuation(.colon);
    const ends = sectioned or emitter.brackets.close_of(open) == position;
    if (!ends) return;

    emitter.asm_aligned = null;

    try emitter.document.push(.dealign);
}

pub fn asm_aligning(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const frame = line.frame(emitter);
    const reopened = emitter.depth > 0 and frame.aligned and frame.open == position;
    if (reopened) return emitter.document.push(.@"align");
    if (emitter.asm_aligned != null) return;
    if (!emitter.tokens[position].is_punctuation(.colon)) return;
    if (!asm_framed(emitter)) return;

    const operand = emit.ahead_of(emitter, position) orelse return;
    if (!emitter.tokens[operand].is_punctuation(.bracket_open)) return;

    assert(emitter.depth > 0);

    emitter.asm_aligned = line.frame(emitter).open;

    try emitter.document.push(.@"align");
}

pub fn asm_spaced(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    const held = emitter.tokens[previous].kind;
    const kind = emitter.tokens[position].kind;
    if (kind == .string) return held.eql(.{ .punctuation = .bracket_close });
    if (kind.eql(.{ .punctuation = .paren_open })) return asm_spaced_paren(emitter, previous);
    if (kind.eql(.{ .punctuation = .colon })) return held == .string;
    return asm_spaced_colons(emitter, previous);
}

fn asm_spaced_paren(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);

    if (emitter.tokens[previous].kind != .string) return false;

    const before = emit.back_of(emitter, previous) orelse return false;

    assert(before < previous);

    return emitter.tokens[before].is_punctuation(.bracket_close);
}

fn asm_spaced_colons(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);

    if (!emitter.tokens[previous].is_punctuation(.colon)) return false;

    const second = emit.back_of(emitter, previous) orelse return false;
    if (!emitter.tokens[second].is_punctuation(.colon)) return false;

    const third = emit.back_of(emitter, second) orelse return false;

    assert(third < second);

    return emitter.tokens[third].is_punctuation(.colon);
}
