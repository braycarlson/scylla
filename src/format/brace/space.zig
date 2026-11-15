const std = @import("std");
const assert = std.debug.assert;
const Token = @import("../../syntax/token.zig");
const body = @import("body.zig");
const brace = @import("../brace.zig");
const core = @import("emitter.zig");
const emit = @import("emit.zig");
const join = @import("join.zig");
const line = @import("line.zig");
const walk = @import("../walk.zig");
const wrap = @import("wrap.zig");
const Emitter = core.Emitter;

const member_modifiers: []const []const u8 = &.{
    "abstract",
    "declare",
    "override",
    "private",
    "protected",
    "public",
    "readonly",
    "static",
};

pub fn paired(emitter: *const Emitter, position: u32, previous: u32) ?bool {
    assert(position < emitter.count);
    assert(previous < position);

    const gap = emitter.tokens[previous].end() < emitter.tokens[position].offset;
    if (emit.ellipsis(emitter, position)) return !emitter.starting and gap;

    const ranged = emit.ranges(emitter, previous) or emit.ranges(emitter, position);
    if (ranged) return paired_range(emitter, position, previous, gap);
    if (previous == 0) return null;
    if (!emit.doubled(emitter, previous - 1)) return null;
    if (!emit.is_dot(emitter, previous)) return null;
    return gap;
}

fn paired_range(emitter: *const Emitter, position: u32, previous: u32, gap: bool) bool {
    assert(position < emitter.count);
    assert(previous < position);

    const held = emitter.tokens[previous].kind;
    const kind = emitter.tokens[position].kind;
    const opening = walk.is_open(held) and paired_dotted(emitter, position);
    const closing = walk.is_close(kind) and paired_dotted(emitter, previous);

    if (opening) return false;
    if (closing) return false;
    return gap;
}

fn paired_dotted(emitter: *const Emitter, at: u32) bool {
    assert(at < emitter.count);

    const text = emitter.tokens[at].text(emitter.source);

    for (text) |byte| {
        if (byte != '.') return false;
    }

    assert(text.len == emitter.tokens[at].length);

    return true;
}

fn fields_closed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (emitter.tokens[position].kind != .block_end) return false;

    const frame = line.frame(emitter);
    if (!frame.inside) return false;
    if (emitter.policy.chain_simples) return true;

    const held = emit.back_of(emitter, frame.open) orelse return false;

    assert(held < frame.open);

    return line.word_is(emitter, held, emitter.policy.brace_words);
}

pub fn void_arrayed(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (!emit.roled(emitter, previous, brace.role_type)) return false;
    if (!walk.text_is(emitter.tokens[previous].text(emitter.source), "void")) return false;
    return emitter.tokens[position].is_punctuation(.bracket_open);
}

fn group_worded(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);

    if (!line.group_word(emitter, previous)) return false;

    const at = emit.back_of(emitter, previous) orelse return false;
    const token = emitter.tokens[at];
    const text = token.text(emitter.source);

    assert(at < previous);

    const operand = walk.ends_operand(token.kind) and !words_contain(member_modifiers, text);
    if (operand) return true;

    if (token.kind == .block_end) {
        if (!body.parts_at(emitter, at, previous)) return true;
    }

    if (!walk.text_is(text, "!")) return false;

    const before = emit.back_of(emitter, at) orelse return false;
    return walk.ends_operand(emitter.tokens[before].kind);
}

pub fn worded(emitter: *const Emitter, position: u32, previous: u32) ?bool {
    assert(position < emitter.count);
    assert(previous < position);

    const held = emitter.tokens[previous].kind;
    const gap = emitter.tokens[previous].end() < emitter.tokens[position].offset;
    const tight_words = emitter.policy.tight_words;
    const source_words = emitter.policy.source_words;

    if (line.word_is(emitter, position, tight_words)) return false;
    if (line.word_is(emitter, previous, tight_words)) return false;

    const fused = emit.doubled(emitter, previous) and previous + 1 == position;

    if (fused) {
        if (!fields_closed(emitter, position)) return false;
    }

    if (previous > 0) {
        const colon = held.eql(.{ .punctuation = .colon });

        if (emit.doubled(emitter, previous - 1)) {
            if (colon) return false;
        }
    }

    if (line.word_is(emitter, position, source_words)) return gap;
    if (line.word_is(emitter, previous, source_words)) return gap;
    return worded_tight(emitter, position, previous, gap);
}

fn worded_tight(emitter: *const Emitter, position: u32, previous: u32, gap: bool) ?bool {
    assert(position < emitter.count);
    assert(previous < position);

    const held = emitter.tokens[previous].kind;
    const kind = emitter.tokens[position].kind;
    const held_text = emitter.tokens[previous].text(emitter.source);
    const text = emitter.tokens[position].text(emitter.source);
    const blocked = worded_block(held) or worded_block(kind);
    const braced = emitter.policy.brace_parts and blocked;
    const grouped = group_worded(emitter, previous);
    const paren = kind.eql(.{ .punctuation = .paren_open });
    const bracketed = paren or kind.eql(.{ .punctuation = .bracket_open });

    if (grouped) {
        if (bracketed) return true;
    }

    if (join.angle_tight(emitter, position, previous)) return false;

    if (walk.text_is(held_text, ">")) {
        if (wrap.cast_open(emitter, previous) != null) return false;
        if (kind == .block_start) return null;
    }

    const listed = held.eql(.{ .punctuation = .colon }) or held.eql(.{ .punctuation = .comma });
    const assigned = held.eql(.{ .punctuation = .assign });
    const parted = listed or assigned or walk.text_is(held_text, "return");
    const angled = walk.text_is(text, "<") or walk.text_is(text, ">");
    const sourced = worded_sourced(emitter, position, previous);
    const chained = emitter.policy.chain_simples and parted and !angled;

    if (!sourced) return null;
    if (gap) return null;
    if (braced) return null;
    if (chained) return null;
    return false;
}

fn worded_block(kind: Token.Kind) bool {
    if (kind == .comment) return false;

    if (kind == .block_end) {
        assert(walk.is_close(kind));

        return true;
    }

    const result = kind == .block_start;

    if (result) assert(walk.is_open(kind));

    return result;
}

fn worded_sourced(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    const words = emitter.policy.tight_from_source;
    if (line.word_is(emitter, position, words)) return true;
    return line.word_is(emitter, previous, words);
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
