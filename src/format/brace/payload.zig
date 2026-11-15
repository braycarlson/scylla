const std = @import("std");
const assert = std.debug.assert;
const core = @import("emitter.zig");
const emit = @import("emit.zig");
const line = @import("line.zig");
const split = @import("split.zig");
const walk = @import("../walk.zig");
const Emitter = core.Emitter;
const payload_heads: []const []const u8 = &.{ "catch", "else", "=>" };
const payload_scan_max: u32 = 6;

pub fn block_labeled(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (!emitter.policy.header_levels) return false;
    if (emitter.tokens[position].kind != .identifier) return false;

    const colon = emit.ahead_of(emitter, position) orelse return false;
    if (!emitter.tokens[colon].is_punctuation(.colon)) return false;

    const open = emit.ahead_of(emitter, colon) orelse return false;

    assert(open > colon);

    return emitter.tokens[open].kind == .block_start;
}

pub fn closed_head_level(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    if (!emitter.policy.header_levels) return null;

    var scan = position;

    for (0..core.type_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return null;

        assert(held < scan);

        if (held < emitter.line_first) return null;

        if (emitter.tokens[held].is_punctuation(.paren_close)) {
            if (emitter.brackets.open_of(held)) |open| {
                const before = emit.back_of(emitter, open);

                const continued = if (before) |colon|
                    emitter.tokens[colon].is_punctuation(.colon)
                else
                    false;

                if (continued) {
                    scan = before.?;

                    continue;
                }

                if (open < emitter.line_first) return line.level_at(emitter, open);

                scan = open;

                continue;
            }
        }

        scan = held;
    }

    return null;
}

pub fn bar(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    const before = emit.back_of(emitter, open) orelse return false;
    if (!emitter.tokens[before].is_punctuation(.paren_close)) return false;

    const paren = emitter.brackets.open_of(before) orelse return false;
    const word = emit.back_of(emitter, paren) orelse return false;
    if (!line.word_is(emitter, word, emitter.policy.header_words)) return false;

    const held = emit.ahead_of(emitter, open) orelse return false;

    assert(held > open);

    if (!split.broke(emitter, open, held)) return false;
    if (emitter.tokens[held].kind == .identifier) return true;
    return walk.text_is(emitter.tokens[held].text(emitter.source), "*");
}

pub fn closer(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (!line.word_is(emitter, position, emitter.policy.source_words)) return false;

    var scan = position;

    for (0..payload_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;
        const token = emitter.tokens[held];

        assert(held < scan);

        if (line.word_is(emitter, held, emitter.policy.source_words)) {
            return closer_head(emitter, held);
        }

        const starred = walk.text_is(token.text(emitter.source), "*");
        const listed = token.kind == .identifier or token.is_punctuation(.comma) or starred;
        if (!listed) return false;

        scan = held;
    }

    return false;
}

fn closer_head(emitter: *const Emitter, held: u32) bool {
    assert(held < emitter.count);

    const before = emit.back_of(emitter, held) orelse return false;

    assert(before < held);

    if (emitter.tokens[before].is_punctuation(.paren_close)) return true;
    return line.word_is(emitter, before, payload_heads);
}

pub fn headed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (!closer(emitter, position)) return false;

    var scan = position;

    for (0..payload_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;

        assert(held < scan);

        if (line.word_is(emitter, held, emitter.policy.source_words)) {
            return headed_word(emitter, held);
        }

        scan = held;
    }

    return false;
}

fn headed_word(emitter: *const Emitter, held: u32) bool {
    assert(held < emitter.count);

    const close = emit.back_of(emitter, held) orelse return false;
    const open = emitter.brackets.open_of(close) orelse return false;
    const word = emit.back_of(emitter, open) orelse return false;

    assert(word < open);

    return line.word_is(emitter, word, emitter.policy.header_words);
}
