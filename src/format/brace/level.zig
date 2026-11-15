const std = @import("std");
const assert = std.debug.assert;
const Token = @import("../../syntax/token.zig");
const assembly = @import("assembly.zig");
const body = @import("body.zig");
const brace = @import("../brace.zig");
const core = @import("emitter.zig");
const emit = @import("emit.zig");
const heritage = @import("heritage.zig");
const items = @import("items.zig");
const join = @import("join.zig");
const line = @import("line.zig");
const list = @import("list.zig");
const payload = @import("payload.zig");
const span = @import("span.zig");
const split = @import("split.zig");
const tern = @import("tern.zig");
const unite = @import("unite.zig");
const walk = @import("../walk.zig");
const wide = @import("wide.zig");
const Emitter = core.Emitter;
const chain_postfix_max: u32 = 8;
const inline_words: []const []const u8 = &.{"inline"};
const loop_words: []const []const u8 = &.{ "for", "inline", "while" };

pub fn raised(emitter: *const Emitter, position: u32, parted: bool) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.brace_levels) return true;
    if (items.item_flat_at(emitter, position)) return false;
    if (emitter.depth == 0) return true;

    if (emitter.policy.header_levels) {
        if (!assembly.asm_enclosed(emitter)) {
            if (items.item_lined_at(emitter, position)) return true;
        }
    }

    if (split.fields_level(emitter, position)) return true;
    if (wide.literal(emitter, position)) return true;
    if (wide.branched(emitter, position)) return true;

    if (wide.listed(emitter, position)) |listed| {
        if (listed == position) return true;
    }

    const outer = emitter.nest[emitter.depth - 1];

    assert(outer.open < emitter.count);

    if (items.item_flat_at(emitter, outer.open)) return true;
    if (wide.hugged(emitter, outer.open)) return true;
    if (assembly.asm_opens(emitter, outer.open)) return true;

    const opened = emitter.line_first > outer.open;

    const flat = !outer.parted and !opened and !body.parts_at(emitter, outer.open, position) and
        !body.parting(emitter, outer.open, position);

    if (flat) return false;
    if (holds_a_condition(emitter, outer.open)) return true;

    if (opened) {
        const led = branch_led(emitter) or equals_led(emitter);
        if (led) return true;
    }

    if (emitter.policy.raise_hugged) return true;
    if (branch_bodied(emitter, emitter.depth)) return true;

    const hugged = !outer.parted and hugs(emitter, outer.open) and line.carries_on(emitter) and
        !parted and !hugs(emitter, position);

    return !hugged;
}

fn branch_bodied(emitter: *const Emitter, depth: u32) bool {
    assert(emitter.branched <= core.branch_depth_max);
    assert(depth <= emitter.depth);

    if (!emitter.policy.header_levels) return false;
    if (emitter.branched == 0) return false;

    const branch = emitter.branches[emitter.branched - 1];
    if (branch.depth != depth) return false;

    const before = emit.back_of(emitter, emitter.line_first) orelse return false;
    const prior = split.coded_at(emitter, before) orelse return false;

    return branch.word == prior;
}

fn branch_led(emitter: *const Emitter) bool {
    assert(emitter.line_first < emitter.count);
    assert(emitter.depth > 0);

    if (!emitter.policy.chain_simples) return false;

    const text = emitter.tokens[emitter.line_first].text(emitter.source);
    if (walk.text_is(text, "?")) return !tern.optional(emitter, emitter.line_first);
    if (walk.text_is(text, ":")) return tern.ternary(emitter, emitter.line_first);
    return false;
}

fn equals_led(emitter: *const Emitter) bool {
    assert(emitter.line_first < emitter.count);
    assert(emitter.depth > 0);

    if (!emitter.policy.chain_simples) return false;

    const held = emit.back_of(emitter, emitter.line_first) orelse return false;
    return emitter.tokens[held].is_punctuation(.assign);
}

pub fn holds_a_condition(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const held = emit.back_of(emitter, open) orelse return false;

    assert(held < open);

    return line.word_is(emitter, held, emitter.policy.header_words);
}

fn hugs(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (body.parts(emitter, open)) return false;

    const held = emit.ahead_of(emitter, open) orelse return false;

    assert(held > open);

    if (emitter.tokens[held].kind == .comment) return false;
    return body.parted_by(emitter, emitter.tokens[open].end(), emitter.tokens[held].offset) == 0;
}

pub fn sibling(emitter: *const Emitter, position: u32, kind: Token.Kind) ?u32 {
    assert(position < emitter.count);
    assert(emitter.depth > 0);

    if (!emitter.policy.sibling_levels) return null;

    const comma = emit.back_of(emitter, position) orelse return null;
    if (!emitter.tokens[comma].is_punctuation(.comma)) return null;

    const close = emit.back_of(emitter, comma) orelse return null;
    const closed = emitter.closed;
    if (closed.close != close) return null;
    if (!closed.kind.eql(kind)) return null;
    if (close < emitter.line_first) return null;
    return closed.level;
}

pub fn nested(emitter: *const Emitter, position: u32, bounded: bool) u32 {
    assert(position < emitter.count);
    assert(emitter.line_first < emitter.count);

    if (span.union_bodied(emitter, position)) |found| return level_deeper(found, 1);
    if (assembly.asm_templated(emitter)) return level_deeper(emitter.printed, 2);

    const first = line_head(emitter);

    const heads = line.word_is(emitter, first, emitter.policy.header_words) or
        line.word_is(emitter, first, emitter.policy.block_words);

    const headed = emitter.policy.header_words.len == 0 or nested_headed(emitter, position);

    const statement = !body.class_valued(emitter, position) and
        (bounded or heritage.bodied(emitter, position) or
            (emit.bodied(emitter, position) and emitter.printed > emitter.levels and !heads and
                headed));

    const lined = emitter.policy.header_lines;
    const carried = if (lined) nested_carried(emitter, position) else null;

    if (statement) return level_deeper(emitter.levels, 1);
    if (chain_ended(emitter, position)) return emitter.printed;
    if (unite.intersect_chained(emitter, position)) |found| return level_deeper(found, 2);
    if (carried) |found| return level_deeper(found, 1);

    if (emitter.policy.header_levels) {
        if (!assembly.asm_enclosed(emitter)) {
            if (line.indent_at(emitter, position)) |found| return level_deeper(found, 1);
        }
    }

    if (payload.closed_head_level(emitter, position)) |found| return level_deeper(found, 1);
    if (span.opened_level(emitter, position)) |found| return level_deeper(found, 1);
    if (list.signature_level(emitter, position)) |found| return level_deeper(found, 1);
    if (angle_reopened_level(emitter, position)) |found| return level_deeper(found, 1);

    return level_deeper(emitter.printed, 1);
}

fn level_deeper(level: u32, steps: u32) u32 {
    assert(steps > 0);
    assert(steps <= 2);
    assert(level < std.math.maxInt(u32) - steps);

    const deeper = level + steps;

    assert(deeper > level);

    return deeper;
}

fn angle_reopened_level(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.line_first < emitter.count);

    if (emitter.tokens[position].kind != .block_start) return null;

    const arrow = emit.back_of(emitter, position) orelse return null;
    if (!walk.text_is(emitter.tokens[arrow].text(emitter.source), "=>")) return null;

    const shut = emit.back_of(emitter, arrow) orelse return null;
    if (!emitter.tokens[shut].is_punctuation(.paren_close)) return null;

    const open = emitter.brackets.open_of(shut) orelse return null;
    var assign = emit.back_of(emitter, open) orelse return null;

    if (walk.text_is(emitter.tokens[assign].text(emitter.source), "async")) {
        assign = emit.back_of(emitter, assign) orelse return null;
    }

    if (!emitter.tokens[assign].is_punctuation(.assign)) return null;

    const close = emit.back_of(emitter, assign) orelse return null;
    if (!walk.text_is(emitter.tokens[close].text(emitter.source), ">")) return null;

    const angle = list.signature_angle_open(emitter, close) orelse return null;
    if (emitter.line_first <= angle) return null;
    if (emitter.line_first >= close) return null;
    return line.level_at(emitter, angle);
}

fn chain_ended(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.header_levels) return false;
    if (!emitter.chained) return false;
    if (emitter.printed == 0) return false;
    if (emitter.depth == 0) return false;
    if (branch_bodied(emitter, emitter.depth - 1)) return false;

    var outer = position;
    var index = emitter.depth;

    while (index > 0) {
        index -= 1;

        const open = emitter.nest[index].open;
        if (open < emitter.line_first) break;

        outer = open;
    }

    assert(outer <= position);

    const close = join.closing_of(emitter, outer) orelse return false;
    var after = emit.ahead_of(emitter, close) orelse return true;

    for (0..chain_postfix_max) |_| {
        const token = emitter.tokens[after];
        if (!token.is_punctuation(.dot)) return true;
        if (token.length == 1) break;

        after = emit.ahead_of(emitter, after) orelse return true;
    } else return true;

    assert(emit.is_dot(emitter, after));

    const name = emit.ahead_of(emitter, after) orelse return true;
    return emitter.tokens[name].kind != .identifier;
}

fn line_head(emitter: *const Emitter) u32 {
    assert(emitter.line_first < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var held = emitter.line_first;
    if (!emitter.policy.header_levels) return held;

    if (emitter.tokens[held].kind == .identifier) {
        const colon = emit.ahead_of(emitter, held) orelse return held;

        if (emitter.tokens[colon].is_punctuation(.colon)) {
            const after = emit.ahead_of(emitter, colon) orelse return held;

            if (line.word_is(emitter, after, loop_words)) held = after;
        }
    }

    if (line.word_is(emitter, held, inline_words)) {
        held = emit.ahead_of(emitter, held) orelse return held;
    }

    assert(held >= emitter.line_first);

    return held;
}

fn nested_carried(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.policy.header_lines);

    const head = span.header_lined(emitter, position) orelse return null;

    assert(head < position);

    if (!header_braced(emitter, head, position)) return null;

    const level = line.level_at(emitter, head) orelse return null;
    if (level < emitter.printed) return level;
    return null;
}

fn nested_headed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.policy.header_words.len > 0);

    const head = line.head_word(emitter, position, emitter.policy.header_words) orelse return false;
    return header_braced(emitter, head, position);
}

fn header_braced(emitter: *const Emitter, head: u32, position: u32) bool {
    assert(head < emitter.count);
    assert(position < emitter.count);

    if (!emitter.policy.chain_simples) return true;

    const open = emit.ahead_of(emitter, head) orelse return false;
    const close = join.closing_of(emitter, open) orelse return false;
    const before = emit.back_of(emitter, position) orelse return false;

    return before == close;
}
