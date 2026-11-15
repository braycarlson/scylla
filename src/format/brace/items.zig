const std = @import("std");
const assert = std.debug.assert;
const brace = @import("../brace.zig");
const core = @import("emitter.zig");
const emit = @import("emit.zig");
const join = @import("join.zig");
const line = @import("line.zig");
const Emitter = core.Emitter;
pub const item_lines: u8 = 1;
pub const item_inline: u8 = 2;
pub const item_edges: u8 = 3;
pub const item_break: u8 = 4;
pub const item_join: u8 = 5;
pub const item_glued: u8 = 8;
pub const item_commas: u8 = 16;
pub const item_spaced: u8 = 32;
pub const item_flat: u8 = 64;
const item_code: u8 = 7;

pub fn item_comma(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.lists.len == 0) return false;
    if (emitter.depth == 0) return false;

    const frame = line.frame(emitter);
    const code = item_code_at(emitter, frame.open) orelse 0;
    const layout = code & item_code;
    const lined = layout == item_lines or layout == item_edges;

    if (frame.close != position) return false;
    if (code & item_commas == 0) return false;
    if (!lined) return false;

    const held = emitter.previous orelse return false;
    const kind = emitter.tokens[held].kind;

    assert(held < position);

    if (held == frame.open) return false;
    if (kind == .comment) return false;
    if (kind.eql(.{ .punctuation = .comma })) return false;
    return !kind.eql(.{ .punctuation = .semicolon });
}

pub fn item_inlined(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return false;

    const open = line.frame(emitter).open;

    assert(open < emitter.count);

    const code = item_code_at(emitter, open) orelse return false;
    return code & item_code == item_inline;
}

pub fn item_spaced_at(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const code = item_code_at(emitter, position) orelse 0;
    return code & item_spaced != 0;
}

pub fn item_flat_at(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const code = item_code_at(emitter, position) orelse 0;
    return code & item_flat != 0;
}

pub fn item_lined_at(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const code = item_code_at(emitter, position) orelse 0;
    const layout = code & item_code;

    return layout == item_lines or layout == item_edges;
}

pub fn item_glued_at(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const code = item_code_at(emitter, position) orelse 0;
    if (code & item_glued == 0) return false;

    const held = emitter.previous orelse return false;

    assert(held < position);

    return emitter.tokens[held].kind != .comment;
}

pub fn item_split(emitter: *const Emitter, position: u32, previous: u32) ?bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (emitter.lists.len == 0) return null;
    if (emit.roled(emitter, position, brace.role_span)) return true;
    if (emit.roled(emitter, previous, brace.role_span)) return true;

    const token = emitter.tokens[position].kind;
    const held = emitter.tokens[previous].kind;

    if (token == .comment) return null;
    if (held == .comment) return null;

    if (item_code_at(emitter, previous)) |code| {
        if (code & item_code == item_break) return true;
        if (code & item_code == item_join) return false;
    }

    if (join.arm_closed(emitter)) {
        if (item_split_ended(emitter, previous)) return true;
    }

    if (emitter.depth == 0) return null;
    return item_split_framed(emitter, position, previous);
}

fn item_split_ended(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);

    const ended = emit.ahead_of(emitter, previous) orelse return false;
    const code = item_code_at(emitter, ended) orelse return false;

    assert(ended > previous);

    return code & item_code == item_break;
}

fn item_split_framed(emitter: *const Emitter, position: u32, previous: u32) ?bool {
    assert(emitter.depth > 0);
    assert(previous < position);

    const frame = line.frame(emitter);
    const code = item_code_at(emitter, frame.open) orelse return null;
    const layout = code & item_code;
    if (layout == 0) return null;

    const edge = previous == frame.open or position == frame.close;
    const comma = emitter.tokens[previous].is_punctuation(.comma);
    const parted = edge or comma;

    if (layout == item_lines) {
        if (parted) return true;
    }

    if (layout == item_inline) {
        if (parted) return false;
    }

    if (layout == item_edges) {
        if (edge) return true;
    }

    return null;
}

fn item_code_at(emitter: *const Emitter, position: u32) ?u8 {
    assert(position < emitter.count);
    assert(emitter.lists.len <= std.math.maxInt(u32));

    if (position >= emitter.lists.len) return null;
    return emitter.lists[position];
}
