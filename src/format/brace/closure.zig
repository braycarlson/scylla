const std = @import("std");
const assert = std.debug.assert;
const body = @import("body.zig");
const core = @import("emitter.zig");
const emit = @import("emit.zig");
const walk = @import("../walk.zig");
const Emitter = core.Emitter;
const opener_words: []const []const u8 = &.{ "async", "move", "static" };

pub fn bar_aligns(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.bar_aligns) return;
    if (emitter.bar_aligned != null) return;

    const close = aligned_close(emitter, position) orelse return;

    assert(close > position);

    emitter.bar_aligned = close;

    try emitter.document.push(.align_column);
}

pub fn bar_dealigns(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const close = emitter.bar_aligned orelse return;
    if (close != position) return;

    emitter.bar_aligned = null;

    try emitter.document.push(.dealign);
}

pub fn barred(emitter: *const Emitter, comma: u32) bool {
    assert(comma < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.bar_aligns) return false;

    var scan = comma;

    for (0..emitter.count) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;
        const token = emitter.tokens[held];
        const kind = token.kind;
        const closed = walk.is_close(kind) or kind == .block_end;

        assert(held < scan);

        if (closed) {
            scan = emitter.brackets.open_of(held) orelse return false;

            continue;
        }

        if (walk.is_open(kind)) return false;
        if (kind == .block_start) return false;
        if (token.is_punctuation(.semicolon)) return false;
        if (walk.text_is(token.text(emitter.source), "=>")) return false;
        if (walk.text_is(token.text(emitter.source), "|")) return bar_opens(emitter, held);

        scan = held;
    }

    return false;
}

fn aligned_close(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!walk.text_is(emitter.tokens[open].text(emitter.source), "|")) return null;
    if (!bar_opens(emitter, open)) return null;

    var depth: u32 = 0;
    var parted = false;
    var scan = open + 1;

    while (scan < emitter.count) : (scan += 1) {
        const token = emitter.tokens[scan];
        const kind = token.kind;
        const opened = walk.is_open(kind) or kind == .block_start;
        const closed = walk.is_close(kind) or kind == .block_end;

        if (kind == .newline) continue;
        if (token.length == 0) continue;

        if (opened) {
            if (nested_parted(emitter, scan)) return null;

            depth += 1;
        } else if (closed) {
            if (depth == 0) return null;

            depth -= 1;
        } else if (depth == 0) {
            if (walk.text_is(token.text(emitter.source), "|")) return if (parted) scan else null;
            if (walk.text_is(token.text(emitter.source), "=>")) return null;
            if (token.is_punctuation(.semicolon)) return null;

            if (token.is_punctuation(.comma)) parted = parted or comma_parted(emitter, scan);
        } else {}
    }

    return null;
}

fn bar_opens(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    var before = emit.back_of(emitter, open) orelse return true;

    for (0..emitter.count) |_| {
        if (emitter.tokens[before].kind != .comment) break;

        before = emit.back_of(emitter, before) orelse return true;
    }

    const kind = emitter.tokens[before].kind;
    const text = emitter.tokens[before].text(emitter.source);

    inline for (opener_words) |word| {
        if (walk.text_is(text, word)) return true;
    }

    if (kind == .block_end) return false;
    if (kind == .comment) return false;
    return !walk.ends_operand(kind);
}

fn comma_parted(emitter: *const Emitter, comma: u32) bool {
    assert(comma < emitter.count);

    const ahead = emit.ahead_of(emitter, comma) orelse return false;
    return body.parts_at(emitter, comma, ahead);
}

fn nested_parted(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    const close = emitter.brackets.close_of(open) orelse return true;
    const from = emitter.tokens[open].end();
    const to = emitter.tokens[close].offset;

    return body.parted_by(emitter, from, to) > 0;
}
