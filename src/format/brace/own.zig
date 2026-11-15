const std = @import("std");
const assert = std.debug.assert;
const Token = @import("../../syntax/token.zig");
const bind = @import("bind.zig");
const body = @import("body.zig");
const brace = @import("../brace.zig");
const call = @import("call.zig");
const commenting = @import("comment.zig");
const core = @import("emitter.zig");
const edge = @import("edge.zig");
const emit = @import("emit.zig");
const join = @import("join.zig");
const jsx = @import("jsx.zig");
const key = @import("key.zig");
const lead = @import("lead.zig");
const line = @import("line.zig");
const link = @import("link.zig");
const list = @import("list.zig");
const sole = @import("sole.zig");
const span = @import("span.zig");
const split = @import("split.zig");
const tern = @import("tern.zig");
const tmpl = @import("tmpl.zig");
const unite = @import("unite.zig");
const value = @import("value.zig");
const walk = @import("../walk.zig");
const wide = @import("wide.zig");
const wrap = @import("wrap.zig");
const Emitter = core.Emitter;
const arrow_chain_max: u32 = 8;

const assign_operators: [20][]const u8 = .{
    "!=",
    "!==",
    "%",
    "&&",
    "*",
    "+",
    "-",
    "/",
    "<",
    "<=",
    "==",
    "===",
    ">",
    ">=",
    "as",
    "in",
    "instanceof",
    "satisfies",
    "??",
    "||",
};

const alias_paren_max: u32 = 8;
const annotation_scan_max: u32 = 256;
const assign_chain_max: u32 = 32;
const assign_call_scan_max: u32 = 32;
const assign_chain_min: u32 = 3;
const assign_left_max: u32 = 32;

const assign_modifiers: [9][]const u8 = .{
    "abstract",
    "accessor",
    "declare",
    "override",
    "private",
    "protected",
    "public",
    "readonly",
    "static",
};

const assign_source_scan_max: u32 = 4096;
const assign_tag_max: u32 = 16;
const binary_operator_max: u32 = 64;
const cast_trail_max: u32 = 8;
const cast_words: [2][]const u8 = .{ "as", "satisfies" };
const compound_refused: [6][]const u8 = .{ "!=", "!==", "<=", "==", "===", ">=" };
const ending_marks: [8][]const u8 = .{ ".", "<", ">", "[", "]", "|", "&", "," };
const flat_unaries: [5][]const u8 = .{ "!", "delete", "typeof", "void", "~" };
const logical_level_max: u32 = 3;

const property_modifiers: [5][]const u8 = .{
    "private",
    "protected",
    "public",
    "readonly",
    "override",
};

const comment_run_max: u32 = 16;
const required_whole_refused: [4][]const u8 = .{ "as", "satisfies", "in", "instanceof" };
const statement_words: [5][]const u8 = .{ "const", "declare", "export", "let", "var" };

pub fn hugs_body(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (assign_hugs(emitter, position)) {
        emitter.assign_hug = false;

        return emitter.document.push(.hugs);
    }

    if (list.spreads(emitter)) {
        if (emitter.nest[emitter.depth - 1].open == position) return;
    }

    if (emitter.tokens[position].kind != .block_start) return;
    if (!hugging(emitter, position)) return;

    const headed = heading(emitter, position) or cast_hug_bodied(emitter, position);
    if (headed) return emitter.document.push(.heads);
    return emitter.document.push(.hugs);
}

fn heading(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.body_owns) return false;

    const outer = hug_frame(emitter) orelse return false;
    if (ending(emitter, emitter.nest[emitter.depth - 1].close, outer.close)) return false;
    if (!call.hugged_first(emitter, outer.open, outer.close, position)) return false;
    return functioned_first(emitter, outer.open);
}

fn functioned_first(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const opened = emit.ahead_of(emitter, open) orelse return false;
    const async_word = walk.text_is(emitter.tokens[opened].text(emitter.source), "async");

    const head = if (async_word)
        emit.ahead_of(emitter, opened) orelse opened
    else
        opened;

    return walk.text_is(emitter.tokens[head].text(emitter.source), "function");
}

fn assign_hugs(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.assign_hug) return false;
    if (emitter.depth == 0) return false;
    if (!assign_hugs_held(emitter, position)) return false;
    if (assign_hugs_indexed(emitter, position)) return false;
    if (assign_hugs_nested(emitter, position)) return false;
    if (list.bracket_slight(emitter, position)) return false;
    return assign_hugs_operated(emitter, position);
}

fn assign_hugs_held(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth > 0);

    const frame = emitter.nest[emitter.depth - 1];
    if (frame.open != position) return false;
    if (frame.spread == null) return false;

    for (0..emitter.assigns) |owed| {
        if (position < emitter.assigned[owed].close) return true;
    }

    return false;
}

fn assign_hugs_indexed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const kind = emitter.tokens[position].kind;
    if (!kind.eql(.{ .punctuation = .bracket_open })) return false;

    const before = emit.back_of(emitter, position) orelse return false;
    if (emitter.tokens[before].ends_a_value()) return true;
    if (!walk.text_is(emitter.tokens[before].text(emitter.source), "!")) return false;

    const object = emit.back_of(emitter, before) orelse return false;
    return emitter.tokens[object].ends_a_value();
}

fn assign_hugs_nested(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth < 2) return false;

    const outer = emitter.nest[emitter.depth - 2].open;

    for (0..emitter.assigns) |owed| {
        const slot = emitter.assigned[owed];
        if (slot.equals >= outer) continue;
        if (outer >= position) continue;
        if (position >= slot.close) continue;
        return true;
    }

    return false;
}

fn assign_hugs_operated(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.assigns <= core.assign_depth_max);

    for (0..emitter.assigns) |owed| {
        const slot = emitter.assigned[owed];
        if (!assign_operated(emitter, slot.equals, slot.close)) return true;
    }

    return false;
}

fn assign_operated(emitter: *const Emitter, equals: u32, close: u32) bool {
    assert(close < emitter.count);
    assert(equals < close);

    if (alias_commented_union(emitter, equals) != null) return true;

    var depth: u32 = 0;
    var scan = equals + 1;

    for (0..emitter.count) |_| {
        if (scan >= close) return false;

        const token = emitter.tokens[scan];
        const opened = walk.is_open(token.kind) or token.kind == .block_start;
        const closed = walk.is_close(token.kind) or token.kind == .block_end;

        if (opened) {
            depth += 1;
        } else if (closed) {
            depth -|= 1;
        } else if (depth == 0) {
            if (assign_operated_at(emitter, scan)) return true;
        } else {}

        scan += 1;
    }

    return false;
}

fn assign_operated_at(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[scan];
    const text = token.text(emitter.source);

    if (walk.text_is(text, "?")) {
        if (!tern.optional(emitter, scan)) return true;
    }

    if (token.is_punctuation(.colon)) return true;
    return word_listed(&assign_operators, text);
}

fn alias_commented_union(emitter: *const Emitter, equals: u32) ?u32 {
    assert(equals < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const head = alias_commented_union_head(emitter, equals) orelse return null;
    const end = call.valued_semicolon(emitter, head) orelse return null;
    var scan = head;

    for (0..emitter.count) |_| {
        if (scan >= end) return null;

        const kind = emitter.tokens[scan].kind;
        const opened = walk.is_open(kind) or kind == .block_start;

        if (opened) {
            const shut = join.closing_of(emitter, scan) orelse return null;

            scan = shut + 1;

            continue;
        }

        if (walk.text_is(emitter.tokens[scan].text(emitter.source), "|")) return end;

        scan += 1;
    }

    return null;
}

fn alias_commented_union_head(emitter: *const Emitter, equals: u32) ?u32 {
    assert(equals < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.ahead_of(emitter, equals) orelse return null;
    const token = emitter.tokens[held];
    if (token.kind != .comment) return null;
    if (!std.mem.startsWith(u8, token.text(emitter.source), "/*")) return null;

    const member = emit.ahead_of(emitter, held) orelse return null;

    if (body.parts_at(emitter, held, member)) {
        if (std.mem.findScalar(u8, token.text(emitter.source), '\n') == null) return null;
        if (walk.text_is(emitter.tokens[member].text(emitter.source), "|")) return null;
        if (body.parts_at(emitter, equals, held)) return null;
    }

    return held;
}

pub fn hugging(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth < 2) return false;

    const outer = hug_frame(emitter) orelse return false;
    const kind = emitter.tokens[position].kind;
    const braced = kind == .block_start or kind.eql(.{ .punctuation = .bracket_open });

    assert(outer.spread != null);

    if (!braced) return false;

    const close = join.closing_of(emitter, position);

    if (close) |held| {
        if (emit.ahead_of(emitter, position) == held) return false;
    } else if (emit.ahead_of(emitter, position) == null) {
        return false;
    } else {}

    if (list.bracket_lookup(emitter, position)) return false;
    if (emitter.brackets.angles_at(position) > 0) return false;
    if (hug_signed(emitter, outer.open, outer.close, position)) return false;

    const inner = emitter.nest[emitter.depth - 1];
    const ended = ending(emitter, inner.close, outer.close);
    if (!ended) return hugging_first(emitter, &outer, position);
    return hugging_ended(emitter, &outer, position);
}

fn hug_signed(emitter: *const Emitter, open: u32, close: u32, position: u32) bool {
    assert(open < position);
    assert(position < close);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;
    if (!hug_preceded(emitter, open, position)) return false;

    const after = emit.ahead_of(emitter, close) orelse return false;
    const bodied = emitter.tokens[after].kind == .block_start;
    const typed = emitter.tokens[after].is_punctuation(.colon);

    if (!bodied) {
        if (!typed) return false;
    }

    return list.signature_opens(emitter, open);
}

fn hug_preceded(emitter: *const Emitter, open: u32, position: u32) bool {
    assert(open < position);
    assert(position < emitter.count);

    var depth: u32 = 0;
    var scan = open + 1;

    while (scan < position) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const opened = walk.is_open(kind) or kind == .block_start;
        const closed = walk.is_close(kind) or kind == .block_end;

        if (opened) {
            depth += 1;
        } else if (closed) {
            depth -|= 1;
        } else if (depth == 0) {
            if (emitter.tokens[scan].is_punctuation(.comma)) return true;
        } else {}
    }

    return false;
}

fn hugging_ended(emitter: *const Emitter, outer: *const core.Frame, position: u32) bool {
    assert(position < emitter.count);
    assert(outer.open < position);

    const written = emit.word_before(emitter, position) orelse return false;
    const assertion = hugging_assertion(emitter, outer, written);
    const before = assertion orelse written;

    if (emitter.tokens[before].is_punctuation(.comma)) {
        return hugging_listed(emitter, outer.open, position, before, assertion != null);
    }

    const casted = cast_tailed(emitter, position);

    if (before == outer.open) {
        return !casted or list.calling(emitter, outer.open);
    }

    if (emitter.tokens[before].is_punctuation(.colon)) {
        if (span.type_framed(emitter, position)) {
            if (wide.element_count(emitter, outer.open, outer.close) == 1) {
                return !property_param(emitter, outer.open, position);
            }
        }

        if (tern.ternary_within(emitter, before, outer.open)) return false;
    }

    if (cast_braced(emitter, before)) return false;

    const head = call.argument_start(emitter, outer.open, position);

    if (body_refused(emitter, before)) return false;
    if (!emitter.policy.body_owns) return false;
    if (casted) return false;
    if (head >= position) return false;
    return hug_functioned(emitter, head, outer);
}

fn hug_functioned(emitter: *const Emitter, head: u32, outer: *const core.Frame) bool {
    assert(head < emitter.count);
    assert(outer.close < emitter.count);

    if (call.functioned(emitter, head, outer.close)) return true;
    return cast_functioned(emitter, head);
}

pub fn cast_functioned(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[head].is_punctuation(.paren_open)) return false;

    const shut = emitter.brackets.close_of(head) orelse return false;
    const word = emit.ahead_of(emitter, shut) orelse return false;
    if (!word_listed(&cast_words, emitter.tokens[word].text(emitter.source))) return false;

    const inner = emit.ahead_of(emitter, head) orelse return false;
    return call.functioned(emitter, inner, shut);
}

fn body_refused(emitter: *const Emitter, before: u32) bool {
    assert(before < emitter.count);
    assert(emitter.depth >= 2);

    const inner = emitter.nest[emitter.depth - 2];
    if (list.value_assigned(emitter, inner.open, inner.close)) return true;
    return span.wrapping_operator(emitter, before);
}

fn cast_braced(emitter: *const Emitter, before: u32) bool {
    assert(before < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    return word_listed(&cast_words, emitter.tokens[before].text(emitter.source));
}

pub fn wrapper_paren(emitter: *const Emitter, frame: *const core.Frame) bool {
    assert(frame.open < emitter.count);
    assert(frame.close < emitter.count);

    if (frame.close <= frame.open) return false;
    return wrapper_parens(emitter, frame.open, frame.close);
}

fn wrapper_called(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const last = emit.back_of(emitter, close) orelse return false;
    if (wrapper_called_at(emitter, last, open)) return true;

    var scan = last;

    for (0..core.define_scan_max) |_| {
        const token = emitter.tokens[scan];
        const text = token.text(emitter.source);

        if (word_listed(&cast_words, text)) {
            const before = emit.back_of(emitter, scan) orelse return false;
            return wrapper_called_at(emitter, before, open);
        }

        if (!wrapper_called_typed(token, text)) return false;

        const held = emit.back_of(emitter, scan) orelse return false;
        if (held <= open) return false;

        scan = held;
    }

    return false;
}

fn wrapper_called_at(emitter: *const Emitter, held: u32, open: u32) bool {
    assert(held < emitter.count);
    assert(open < emitter.count);

    if (!emitter.tokens[held].is_punctuation(.paren_close)) return false;

    const inner = emitter.brackets.open_of(held) orelse return false;
    if (inner <= open) return false;
    return list.calling(emitter, inner);
}

fn wrapper_called_typed(token: Token, text: []const u8) bool {
    assert(text.len == token.length);
    assert(token.kind != .newline);

    if (token.kind == .identifier) return true;
    if (token.kind == .keyword) return true;
    return word_listed(&ending_marks, text);
}

pub fn wrapper_parens(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const head = emit.ahead_of(emitter, open) orelse return false;
    if (head >= close) return false;
    if (wrapper_parens_bodied(emitter, open, close)) return true;
    if (wrapper_parens_arrow_object(emitter, open, close)) return true;
    if (wrapper_parens_called(emitter, open, close, head)) return true;

    const kind = emitter.tokens[head].kind;
    const framed = kind == .block_start or kind.eql(.{ .punctuation = .bracket_open });
    if (!framed) return false;
    return join.closing_of(emitter, head) == wrapper_tail(emitter, open, close);
}

fn wrapper_parens_bodied(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const last = emit.back_of(emitter, close) orelse return false;
    if (emitter.tokens[last].kind != .block_end) return false;

    const inner = emitter.brackets.open_of(last) orelse return false;
    return inner > open;
}

fn wrapper_parens_arrow_object(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const last = emit.back_of(emitter, close) orelse return false;
    if (!emitter.tokens[last].is_punctuation(.paren_close)) return false;

    const inner = emitter.brackets.open_of(last) orelse return false;
    if (inner <= open) return false;
    return wrapper_parens_arrowed(emitter, inner, last);
}

fn wrapper_parens_arrowed(emitter: *const Emitter, inner: u32, last: u32) bool {
    assert(inner < last);
    assert(last < emitter.count);

    const held = emit.back_of(emitter, inner) orelse return false;
    if (!walk.text_is(emitter.tokens[held].text(emitter.source), "=>")) return false;

    const curly = emit.ahead_of(emitter, inner) orelse return false;
    if (emitter.tokens[curly].kind != .block_start) return false;
    return join.closing_of(emitter, curly) == emit.back_of(emitter, last);
}

fn wrapper_parens_called(emitter: *const Emitter, open: u32, close: u32, head: u32) bool {
    assert(open < close);
    assert(head < emitter.count);

    if (head == close) return false;
    if (wrapper_parens_commented(emitter, open)) return false;
    return wrapper_called(emitter, open, close);
}

fn wrapper_parens_commented(emitter: *const Emitter, open: u32) bool {
    assert(open <= emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = open;

    for (0..open) |_| {
        scan -= 1;

        const token = emitter.tokens[scan];
        if (token.length == 0) continue;
        if (token.kind == .newline) continue;
        return token.kind == .comment;
    }

    return false;
}

fn wrapper_tail(emitter: *const Emitter, open: u32, close: u32) ?u32 {
    assert(open < close);
    assert(close < emitter.count);

    const last = emit.back_of(emitter, close) orelse return null;
    var scan = last;

    for (0..core.define_scan_max) |_| {
        const token = emitter.tokens[scan];
        const text = token.text(emitter.source);

        if (word_listed(&cast_words, text)) {
            const before = emit.back_of(emitter, scan) orelse return null;
            if (before <= open) return null;
            return before;
        }

        if (!wrapper_called_typed(token, text)) return last;

        const held = emit.back_of(emitter, scan) orelse return last;
        if (held <= open) return last;

        scan = held;
    }

    return last;
}

pub fn switch_framed(emitter: *const Emitter, word: u32) bool {
    assert(word < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const frame = switch_framed_find(emitter, word) orelse return false;
    if (frame.kind != .block_start) return false;
    return switch_framed_named(emitter, frame.open);
}

fn switch_framed_find(emitter: *const Emitter, word: u32) ?core.Frame {
    assert(word < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    emitter.statements.contextual = true;

    var held = emitter.depth;

    for (0..emitter.depth) |_| {
        held -= 1;

        const frame = emitter.nest[held];

        if (frame.open < word) {
            if (word < frame.close) return frame;
        }
    }

    return null;
}

fn switch_framed_named(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.back_of(emitter, open) orelse return false;
    if (!emitter.tokens[held].is_punctuation(.paren_close)) return false;

    const paren = emitter.brackets.open_of(held) orelse return false;
    const name = emit.back_of(emitter, paren) orelse return false;

    return walk.text_is(emitter.tokens[name].text(emitter.source), "switch");
}

fn hugging_assertion(emitter: *const Emitter, outer: *const core.Frame, written: u32) ?u32 {
    assert(written < emitter.count);
    assert(outer.open < emitter.count);

    if (!walk.text_is(emitter.tokens[written].text(emitter.source), ">")) return null;

    const held = list.opening(emitter, written, 1) orelse return null;

    assert(held < written);

    if (held == outer.open) return held;
    if (emitter.tokens[held].is_punctuation(.comma)) return held;
    return null;
}

fn hugging_listed(
    emitter: *const Emitter,
    open: u32,
    position: u32,
    before: u32,
    asserted: bool,
) bool {
    assert(open < before);
    assert(before < position);
    assert(emitter.tokens[before].is_punctuation(.comma));

    const kind = emitter.tokens[position].kind;
    var concise = false;

    if (emitter.policy.chain_simples) {
        if (kind.eql(.{ .punctuation = .bracket_open })) {
            if (join.closing_of(emitter, position)) |held| {
                concise = list.numeric(emitter, position, held);
            }
        }
    }

    if (concise) return false;
    if (asserted) return true;
    if (cast_tailed(emitter, position)) return !hugging_cast_alike(emitter, open, position, before);

    const preceded = key.preceding(emitter, before) orelse return true;
    return !preceded.eql(kind);
}

fn hugging_cast_alike(emitter: *const Emitter, open: u32, position: u32, before: u32) bool {
    assert(open < before);
    assert(before < position);

    const shut = join.closing_of(emitter, position) orelse return false;
    const word = emit.ahead_of(emitter, shut) orelse return false;
    const start = call.argument_start(emitter, open, before);
    if (start >= before) return false;

    const held = call.argument_cast(emitter, start, before) orelse return false;
    return walk.text_eql(held, emitter.tokens[word].text(emitter.source));
}

fn cast_tailed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const shut = join.closing_of(emitter, position) orelse return false;
    const held = emit.ahead_of(emitter, shut) orelse return false;

    assert(held > shut);

    const text = emitter.tokens[held].text(emitter.source);
    return walk.text_is(text, "as") or walk.text_is(text, "satisfies");
}

fn property_param(emitter: *const Emitter, open: u32, position: u32) bool {
    assert(open < position);
    assert(position < emitter.count);

    const start = call.argument_start(emitter, open, position);
    const text = emitter.tokens[start].text(emitter.source);

    for (property_modifiers) |modifier| {
        if (walk.text_eql(text, modifier)) return true;
    }

    return false;
}

fn hugging_first(emitter: *const Emitter, outer: *const core.Frame, position: u32) bool {
    assert(position < emitter.count);
    assert(outer.open < emitter.count);

    if (!emitter.policy.body_owns) return false;

    assert(emitter.depth >= 2);

    const frame = emitter.nest[emitter.depth - 2];
    if (params_frame(emitter, &frame, outer)) return false;
    return call.hugged_first(emitter, outer.open, outer.close, position);
}

fn params_frame(emitter: *const Emitter, frame: *const core.Frame, outer: *const core.Frame) bool {
    assert(frame.close < emitter.count);
    assert(outer.open < emitter.count);

    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return false;
    if (frame.open == outer.open) return false;

    const held = emit.ahead_of(emitter, frame.close) orelse return false;
    const token = emitter.tokens[held];
    if (token.kind == .block_start) return true;
    if (token.is_punctuation(.colon)) return true;
    return walk.text_is(token.text(emitter.source), "=>");
}

pub fn ending(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position < emitter.count);
    assert(close < emitter.count);

    const next = emit.ahead_of(emitter, position) orelse return false;
    const open = emitter.brackets.open_of(position);
    const bodied = if (open) |held| cast_hug_bodied(emitter, held) else false;
    const owned = bodied and emitter.policy.body_owns;
    const word = if (owned) paren_closed(emitter, next, close) else next;
    const cast = word_listed(&cast_words, emitter.tokens[word].text(emitter.source));
    const from = if (cast) emit.ahead_of(emitter, word) else next;

    return ending_scan(emitter, position, close, from, cast);
}

fn ending_scan(emitter: *const Emitter, position: u32, close: u32, from: ?u32, cast: bool) bool {
    assert(position < emitter.count);
    assert(close < emitter.count);
    if (from) |held| assert(held < emitter.count);

    var angles: u32 = 0;
    var brackets: u32 = 0;
    var scan = from;

    for (0..emitter.count) |_| {
        const held = scan orelse return false;
        if (held == close) return true;

        const token = emitter.tokens[held];

        if (emitter.policy.body_owns) {
            if (token.is_punctuation(.paren_close)) {
                scan = emit.ahead_of(emitter, held);

                continue;
            }
        }

        const text = token.text(emitter.source);
        const nested = angles > 0 or brackets > 0;

        if (!nested) {
            if (token.is_punctuation(.comma)) return emit.ahead_of(emitter, held) == close;
        }

        if (!cast) return false;

        const grouped = token.kind == .block_start or token.is_punctuation(.paren_open);

        if (grouped) {
            const shut = join.closing_of(emitter, held) orelse return false;

            scan = emit.ahead_of(emitter, shut);

            continue;
        }

        if (!ending_typed(token, text, nested)) return false;

        emit.opened_type(text, &angles, &brackets);
        scan = emit.ahead_of(emitter, held);
    }

    return false;
}

fn ending_typed(token: Token, text: []const u8, nested: bool) bool {
    assert(text.len == token.length);
    if (token.kind == .identifier) assert(text.len > 0);

    if (token.kind == .identifier) return true;
    if (token.kind == .keyword) return true;
    if (nested) return true;
    if (token.kind == .number) return true;
    if (token.kind == .string) return true;
    return word_listed(&ending_marks, text);
}

pub fn cast_hug_head(emitter: *const Emitter, curly: u32) ?u32 {
    assert(curly < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!cast_hug_bodied(emitter, curly)) return null;

    const before = emit.back_of(emitter, curly) orelse return null;

    const close = if (walk.text_is(emitter.tokens[before].text(emitter.source), "=>"))
        emit.back_of(emitter, before) orelse return null
    else
        before;

    if (!emitter.tokens[close].is_punctuation(.paren_close)) return null;

    const params = emitter.brackets.open_of(close) orelse return null;
    if (emit.ahead_of(emitter, params) == close) return null;
    return params;
}

fn cast_hug_bodied(emitter: *const Emitter, curly: u32) bool {
    assert(curly < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.back_of(emitter, curly) orelse return false;
    const arrowed = walk.text_is(emitter.tokens[held].text(emitter.source), "=>");
    const functioned = arrowed or emitter.tokens[held].is_punctuation(.paren_close);
    if (!functioned) return false;

    const shut = emitter.brackets.close_of(curly) orelse return false;
    const paren = emit.ahead_of(emitter, shut) orelse return false;
    if (!emitter.tokens[paren].is_punctuation(.paren_close)) return false;

    const open = emitter.brackets.open_of(paren) orelse return false;
    if (list.calling(emitter, open)) return false;

    const word = emit.ahead_of(emitter, paren) orelse return false;
    return word_listed(&cast_words, emitter.tokens[word].text(emitter.source));
}

pub fn bodied_value(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position < close);
    assert(close < emitter.count);

    return bodied_head(emitter, position, close) != null;
}

fn bodied_head(emitter: *const Emitter, position: u32, close: u32) ?u32 {
    assert(position < close);
    assert(close < emitter.count);

    if (!emitter.policy.body_owns) return null;

    var scan = position + 1;

    for (0..emitter.count) |_| {
        if (scan >= close) return null;

        const kind = emitter.tokens[scan].kind;

        if (kind.eql(.{ .punctuation = .paren_open })) {
            if (bodied_head_wrapped(emitter, scan)) {
                assert(scan <= emitter.count);

                return scan;
            }
        }

        if (kind == .block_start) {
            if (bodied_head_braced(emitter, scan)) {
                assert(scan <= emitter.count);

                return scan;
            }
        }

        scan += 1;
    }

    return null;
}

fn bodied_head_wrapped(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = join.closing_of(emitter, scan) orelse return false;
    return wrapper_parens(emitter, scan, held);
}

fn bodied_head_braced(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.ahead_of(emitter, scan) orelse return body.bodied_brace(emitter, scan);
    if (emitter.tokens[held].kind == .block_end) return false;
    return body.bodied_brace(emitter, scan);
}

fn paren_closed(emitter: *const Emitter, position: u32, close: u32) u32 {
    assert(position < emitter.count);
    assert(close < emitter.count);

    var scan = position;

    while (scan != close) {
        if (!emitter.tokens[scan].is_punctuation(.paren_close)) break;

        const held = emit.ahead_of(emitter, scan) orelse break;

        assert(held > scan);

        scan = held;
    }

    return scan;
}

fn hug_frame(emitter: *const Emitter) ?core.Frame {
    assert(emitter.depth > 0);
    assert(emitter.depth <= brace.nest_depth_max);

    var held = emitter.depth - 1;

    while (held > 0) {
        held -= 1;

        const frame = emitter.nest[held];

        assert(held < emitter.depth);

        if (!frame.kind.eql(.{ .punctuation = .paren_open })) return null;
        if (frame.spread != null) return frame;
        if (!emitter.policy.body_owns) return null;
    }

    return null;
}

pub fn comment_assigned(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.line_first <= emitter.count);

    const prior = emit.back_of(emitter, position) orelse return null;
    const token = emitter.tokens[prior];

    assert(prior < position);

    if (!emitter.policy.assign_groups) return null;
    if (token.kind != .comment) return null;

    const above = split.coded_at(emitter, prior) orelse return null;
    const arrowed = walk.text_is(emitter.tokens[above].text(emitter.source), "=>");
    const lined = std.mem.startsWith(u8, token.text(emitter.source), "//");

    if (!lined) {
        if (!arrowed) return null;
        if (!body.parts_at(emitter, prior, position)) return null;
    }

    if (!arrowed) {
        if (!emitter.tokens[above].is_punctuation(.assign)) return null;
    }

    const head = emit.ahead_of(emitter, above) orelse return null;
    if (emitter.line_first == head) return null;
    if (span.line_opened(emitter, head) == head) return null;
    return line.level_at(emitter, above);
}

fn value_cast(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = emit.ahead_of(emitter, close);

    for (0..cast_trail_max) |_| {
        const held = scan orelse break;

        if (emit.is_dot(emitter, held)) {
            const name = emit.ahead_of(emitter, held) orelse return false;

            scan = emit.ahead_of(emitter, name);

            continue;
        }

        if (walk.text_is(emitter.tokens[held].text(emitter.source), "!")) {
            scan = emit.ahead_of(emitter, held);

            continue;
        }

        if (emitter.tokens[held].is_punctuation(.bracket_open)) {
            const shut = join.closing_of(emitter, held) orelse return false;

            scan = emit.ahead_of(emitter, shut);

            continue;
        }

        break;
    }

    const next = scan orelse return false;
    return word_listed(&cast_words, emitter.tokens[next].text(emitter.source));
}

pub fn arrow_typed_ahead(emitter: *const Emitter, close: u32) ?u32 {
    assert(close < emitter.count);
    assert(walk.is_close(emitter.tokens[close].kind));

    const angles = emitter.brackets.angles_at(close);
    var depth: u32 = 0;
    var scan = close;

    for (0..core.define_scan_max) |_| {
        const held = emit.ahead_of(emitter, scan) orelse return null;
        const token = emitter.tokens[held];

        assert(held > scan);

        if (walk.is_open(token.kind)) {
            depth += 1;
        } else if (walk.is_close(token.kind)) {
            if (depth == 0) return null;

            depth -= 1;
        } else if (depth == 0) {
            if (walk.text_is(token.text(emitter.source), "=>")) return held;

            const listed = emitter.brackets.angles_at(held) > angles;
            const separated = token.is_punctuation(.comma) or token.is_punctuation(.semicolon);

            if (!listed) {
                if (separated) return null;
            }
        } else {}

        scan = held;
    }

    return null;
}

fn arrow_headed(emitter: *const Emitter, head: u32, arrow: u32) ?u32 {
    assert(head < arrow);
    assert(arrow < emitter.count);

    var open = head;

    if (walk.text_is(emitter.tokens[open].text(emitter.source), "async")) {
        open = emit.ahead_of(emitter, open) orelse return null;
    }

    if (walk.text_is(emitter.tokens[open].text(emitter.source), "<")) {
        open = arrow_headed_angled(emitter, open, arrow);
    }

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return null;

    const shut = join.closing_of(emitter, open) orelse return null;
    if (shut >= arrow) return null;
    return open;
}

fn arrow_headed_angled(emitter: *const Emitter, open: u32, arrow: u32) u32 {
    assert(open < arrow);
    assert(arrow < emitter.count);

    const closed = arrow_headed_closed(emitter, open, arrow);

    if (closed) |after| {
        if (after < arrow) return after;
    }

    var scan = open + 1;

    for (0..emitter.count) |_| {
        if (scan >= arrow) break;
        if (emitter.brackets.angles_at(scan) == 0) break;

        scan += 1;
    }

    assert(scan <= emitter.count);

    return scan;
}

fn arrow_headed_closed(emitter: *const Emitter, open: u32, arrow: u32) ?u32 {
    assert(open < arrow);
    assert(arrow < emitter.count);

    const close = join.angle_close(emitter, open) orelse return null;
    return emit.ahead_of(emitter, close);
}

pub fn valued_arrow(emitter: *const Emitter, position: u32, end: u32) ?u32 {
    assert(position < end);
    assert(end < emitter.count);

    if (!emitter.policy.arrow_bodies) return null;

    const head = emit.ahead_of(emitter, position) orelse return null;
    if (head >= end) return null;
    if (!call.functioned(emitter, head, end)) return null;

    const angles = emitter.brackets.angles_at(position);
    var depth: u32 = 0;
    var scan = head;

    for (0..emitter.count) |_| {
        if (scan >= end) return null;

        const token = emitter.tokens[scan];
        const opened = walk.is_open(token.kind) or token.kind == .block_start;
        const closed = walk.is_close(token.kind) or token.kind == .block_end;
        const level = depth == 0 and emitter.brackets.angles_at(scan) <= angles;

        if (opened) {
            depth += 1;
        } else if (closed) {
            depth -|= 1;
        } else if (level) {
            if (walk.text_is(token.text(emitter.source), "=>")) {
                return valued_arrow_at(emitter, head, scan, end);
            }
        } else {}

        scan += 1;
    }

    return null;
}

fn valued_arrow_at(emitter: *const Emitter, head: u32, scan: u32, end: u32) ?u32 {
    assert(head < scan);
    assert(scan < end);

    const body_start = emit.ahead_of(emitter, scan) orelse return null;
    if (body_start >= end) return null;
    if (call.bodied_arrow(emitter, body_start, end)) return null;
    return arrow_headed(emitter, head, scan) orelse scan;
}

pub fn trailed_comma(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (core.memo_found(emitter, .trailed_comma, position, 0)) |answer| return answer == 1;

    const held = trailed_comma_scanned(emitter, position);

    core.memo_store(emitter, .trailed_comma, position, 0, @intFromBool(held));

    return held;
}

fn trailed_comma_scanned(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.comma_adds) return false;
    if (emitter.depth == 0) return false;

    const frame = emitter.nest[emitter.depth - 1];
    if (split.headed(emitter, frame.open)) return false;
    if (list.paren_grouped(emitter, frame.open, frame.close)) return false;

    const comment = emit.ahead_of(emitter, position) orelse return false;
    const comment_text = emitter.tokens[comment].text(emitter.source);
    const comment_lined = std.mem.startsWith(u8, comment_text, "//");

    if (emitter.tokens[comment].kind != .comment) return false;

    if (!comment_lined) {
        if (!body.parts_at(emitter, position, comment)) return false;
    }

    const trail = comment_trail(emitter, comment);
    if (emit.ahead_of(emitter, trail) != frame.close) return false;
    if (!sole.listed(emitter, frame.close)) return false;

    if (!list.spreads(emitter)) {
        if (!body.parts_at(emitter, position, frame.close)) return false;
    }

    const kind = emitter.tokens[position].kind;
    if (kind.eql(.{ .punctuation = .comma })) return false;
    if (kind.eql(.{ .punctuation = .semicolon })) return false;
    if (kind == .comment) return trailed_comment(emitter, position);
    return !walk.is_open(kind);
}

fn trailed_comment(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.tokens[position].kind == .comment);

    var scan = position;

    for (0..comment_run_max) |_| {
        const token = emitter.tokens[scan];
        const before = emit.back_of(emitter, scan) orelse return false;

        if (!std.mem.startsWith(u8, token.text(emitter.source), "/*")) return false;
        if (body.parts_at(emitter, before, scan)) return false;

        if (emitter.tokens[before].kind != .comment) {
            const held = emitter.tokens[before].kind;
            if (held.eql(.{ .punctuation = .comma })) return false;
            if (held.eql(.{ .punctuation = .semicolon })) return false;
            return !walk.is_open(held);
        }

        scan = before;
    }

    return false;
}

fn comment_trail(emitter: *const Emitter, comment: u32) u32 {
    assert(comment < emitter.count);
    assert(emitter.tokens[comment].kind == .comment);

    var trail = comment;

    for (0..comment_run_max) |_| {
        const held = emit.ahead_of(emitter, trail) orelse break;
        if (emitter.tokens[held].kind != .comment) break;

        trail = held;
    }

    assert(trail >= comment);

    return trail;
}

const AssignRun = struct {
    equals_count: u32,
    equals_lead: u32,
    equals_trail: u32,
};

fn assign_chain(emitter: *const Emitter, prior: u32) ?u32 {
    assert(prior < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.assign_groups) return null;
    if (!emitter.tokens[prior].is_punctuation(.assign)) return null;

    const statement = line.statement_level(emitter);
    const seated = !statement and assign_chain_paren(emitter, false);
    const paren = seated or (!statement and assign_chain_paren(emitter, true));

    if (!statement) {
        if (!paren) return null;
    }

    const head = assign_chain_head(emitter, prior) orelse return null;
    const end = assign_chain_end(emitter, paren, head) orelse return null;
    if (prior > end) return null;

    if (paren) {
        const opened = emit.ahead_of(emitter, line.frame(emitter).open) orelse return null;
        if (opened != head) return null;
    }

    const run = assign_chain_scan(emitter, head, end);
    const paired = run.equals_count == 2 and paren and assign_chain_paired(emitter);

    const declared = run.equals_count >= 2 and paren and !assign_chain_paired(emitter) and
        assign_chain_whole(emitter, line.frame(emitter).close);

    const unseated = paren and !seated;

    const bodied = span.spread_breaks(emitter, head, end) or
        assign_chain_parted(emitter, head, end);

    const tail: u32 = @intFromBool(prior == run.equals_trail);
    const levels = 1 + tail;

    assert(levels <= 2);

    if (declared) {
        if (!bodied) return null;
        return levels;
    }

    if (!paired) {
        if (run.equals_count < assign_chain_min) return null;
        if (unseated) return null;
    }

    const seat = assign_chain_seat(emitter, paren, head) * emitter.options.indent_width;
    const edges = assign_chain_edges(emitter, paren, end);
    const room = seat + span.printed_columns(emitter, head, end) + edges;

    if (!bodied) {
        if (room <= emitter.options.line_width) return null;
    }

    if (!paired) return levels;

    const headed: u32 = @intFromBool(assign_chain_headed(emitter, head, &run, seat));
    const returned = headed + tail;

    assert(returned <= 2);

    return returned;
}

fn assign_chain_parted(emitter: *const Emitter, head: u32, end: u32) bool {
    assert(head <= end);
    assert(end <= emitter.count);

    for (head..end) |index| {
        const scan: u32 = @intCast(index);
        if (emitter.tokens[scan].kind != .block_start) continue;
        if (call.object_parted(emitter, scan)) return true;
    }

    return false;
}

fn assign_chain_head(emitter: *const Emitter, prior: u32) ?u32 {
    assert(prior < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var head = edge.statement_head(emitter, prior) orelse return null;

    for (0..emitter.count) |_| {
        if (head >= prior) break;
        if (emitter.tokens[head].kind != .comment) break;

        head = emit.ahead_of(emitter, head) orelse return null;
    }

    return head;
}

fn assign_chain_end(emitter: *const Emitter, paren: bool, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (paren) return line.frame(emitter).close;
    return span.statement_stop(emitter, head);
}

fn assign_chain_scan(emitter: *const Emitter, head: u32, end: u32) AssignRun {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var run: AssignRun = .{ .equals_count = 0, .equals_lead = 0, .equals_trail = 0 };
    var depth: u32 = 0;
    var scan = head;

    for (0..emitter.count) |_| {
        if (scan >= end) break;

        if (call.spanned_body(emitter, scan)) |held| {
            scan = held + 1;

            continue;
        }

        const kind = emitter.tokens[scan].kind;
        const opened = walk.is_open(kind) or kind == .block_start or bind.spans_open(emitter, scan);
        const closed = walk.is_close(kind) or kind == .block_end;

        if (opened) {
            depth += 1;
        } else if (closed) {
            depth -|= 1;
        } else if (depth == 0) {
            const equals = kind.eql(.{ .punctuation = .assign }) and
                emitter.brackets.angles_at(scan) == 0;

            if (equals) {
                if (run.equals_count == 0) run.equals_lead = scan;

                run.equals_count += 1;
                run.equals_trail = scan;
            }
        } else {}

        scan += 1;
    }

    assert(run.equals_lead <= run.equals_trail);

    return run;
}

fn assign_chain_headed(emitter: *const Emitter, head: u32, run: *const AssignRun, seat: u32) bool {
    assert(run.equals_lead <= run.equals_trail);
    assert(run.equals_trail < emitter.count);
    assert(head < emitter.count);
    assert(seat < std.math.maxInt(u32));

    const width = emitter.options.line_width;

    if (assign_chain_lined(emitter, head, run.equals_lead)) |start| {
        if (link.line_led(emitter, start)) |level| {
            const indented = level * emitter.options.indent_width;
            return indented + span.printed_columns(emitter, start, run.equals_trail) > width;
        }
    }

    return seat + 1 + span.printed_columns(emitter, head, run.equals_trail) > width;
}

fn assign_chain_lined(emitter: *const Emitter, head: u32, equals: u32) ?u32 {
    assert(head < emitter.count);
    assert(equals < emitter.count);

    const lined = line.at(emitter, equals) orelse return null;
    const start = lined.start - 1;
    if (start <= head) return null;
    assert(start <= emitter.count);

    return start;
}

fn assign_chain_paired(emitter: *const Emitter) bool {
    assert(emitter.depth > 0);
    assert(emitter.depth <= brace.nest_depth_max);

    const held = emit.back_of(emitter, line.frame(emitter).open) orelse return true;
    return !emitter.tokens[held].is_punctuation(.assign);
}

fn assign_chain_edges(emitter: *const Emitter, paren: bool, close: u32) u32 {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!paren) return 0;

    const held = emit.ahead_of(emitter, close) orelse return 1;
    const token = emitter.tokens[held];
    const separated = token.is_punctuation(.comma) or token.is_punctuation(.semicolon);
    const returned = 1 + @as(u32, @intFromBool(separated));

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn assign_chain_seat(emitter: *const Emitter, paren: bool, head: u32) u32 {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const base = assign_chain_base(emitter, paren, head);
    const led = if (link.line_led(emitter, head)) |held| @max(held, base) else base;
    const operand = paren and assign_chain_operand(emitter, head);
    const returned = led + @intFromBool(operand);

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn assign_chain_operand(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const open = line.frame(emitter).open;
    const held = emit.back_of(emitter, open) orelse return false;
    if (!span.wrapping_operator(emitter, held)) return false;

    const lined = line.at(emitter, head) orelse return true;
    return lined.start - 1 != open;
}

fn assign_chain_base(emitter: *const Emitter, paren: bool, head: u32) u32 {
    assert(head < emitter.count);
    assert(emitter.levels <= core.line_level_max);

    if (!paren) return emitter.levels;
    return lead.leveled_at(emitter, head) orelse emitter.levels;
}

fn assign_chain_paren(emitter: *const Emitter, operand: bool) bool {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.depth == 0) return false;

    const frame = line.frame(emitter);
    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return false;
    if (list.calling(emitter, frame.open)) return false;
    if (split.headed(emitter, frame.open)) return false;
    if (wide.defined(emitter, frame.open)) return false;
    if (param_defaulted(emitter)) return false;

    if (emit.back_of(emitter, frame.open)) |held| {
        const wrapped = !operand and span.wrapping_operator(emitter, held);
        if (wrapped) return false;
        if (emitter.tokens[held].kind == .identifier) return false;
    }

    const after = emit.ahead_of(emitter, frame.close) orelse return true;
    return !span.wrapping_operator(emitter, after);
}

pub fn assign_chain_level(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    const prior = line.coded(emitter) orelse return null;

    assert(prior < emitter.count);

    const paren = !line.statement_level(emitter);
    const steps = assign_chain(emitter, prior) orelse return null;
    const head = edge.statement_head(emitter, prior) orelse prior;
    const unpaired = paren and !assign_chain_paired(emitter);

    if (unpaired) {
        assert(steps > 0);

        const opened = emit.ahead_of(emitter, line.frame(emitter).open) orelse return null;
        const returned = assign_chain_base(emitter, true, opened) + steps - 1;

        assert(returned < std.math.maxInt(u32));

        return returned;
    }

    const returned = assign_chain_base(emitter, paren, head) + steps;

    assert(returned < std.math.maxInt(u32));

    return returned;
}

pub fn assign_chain_declared(emitter: *const Emitter, equals: u32) bool {
    assert(equals < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.assign_groups) return false;
    if (!emitter.tokens[equals].is_punctuation(.assign)) return false;

    const open = emit.ahead_of(emitter, equals) orelse return false;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const close = join.closing_of(emitter, open) orelse return false;
    const head = emit.ahead_of(emitter, open) orelse return false;
    if (head >= close) return false;
    if (!assign_chain_whole(emitter, close)) return false;
    if (assign_chain_listed(emitter, head, close)) return false;

    const run = assign_chain_scan(emitter, head, close);
    if (run.equals_count < 2) return false;
    if (span.spread_breaks(emitter, head, close)) return true;
    return assign_chain_parted(emitter, head, close);
}

fn assign_chain_whole(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const after = emit.ahead_of(emitter, close) orelse return true;
    const token = emitter.tokens[after];
    if (token.is_punctuation(.semicolon)) return true;
    if (token.is_punctuation(.comma)) return true;
    if (token.kind == .block_end) return true;
    return walk.is_close(token.kind);
}

fn assign_chain_listed(emitter: *const Emitter, head: u32, close: u32) bool {
    assert(head < close);
    assert(close < emitter.count);

    var depth: u32 = 0;

    for (head..close) |index| {
        const kind = emitter.tokens[index].kind;
        const opened = walk.is_open(kind) or kind == .block_start;
        const closed = walk.is_close(kind) or kind == .block_end;

        if (opened) {
            depth += 1;
        } else if (closed) {
            depth -|= 1;
        } else if (depth == 0) {
            if (emitter.tokens[index].is_punctuation(.comma)) return true;
        } else {}
    }

    return false;
}

pub fn assign_runs(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    if (emitter.tokens[position].kind == .comment) return false;

    const steps = assign_chain(emitter, prior) orelse return false;
    return steps > 0;
}

pub fn assign_body_joined(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    const token = emitter.tokens[prior];

    if (!emitter.policy.assign_groups) return false;
    if (!token.is_punctuation(.assign)) return false;
    if (!walk.text_is(token.text(emitter.source), "=")) return false;
    if (assign_runs(emitter, position, prior)) return false;
    if (assign_body_bodied(emitter, position)) return true;
    if (assign_call_joined(emitter, position, prior)) return true;
    return assign_chain_joined(emitter, position, prior);
}

fn assign_body_bodied(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const kind = emitter.tokens[position].kind;
    const opened = kind == .block_start or kind.eql(.{ .punctuation = .bracket_open });
    if (!opened) return false;

    const close = join.closing_of(emitter, position) orelse return false;
    return bodied_value(emitter, position, close);
}

fn assign_chain_joined(emitter: *const Emitter, head: u32, equals: u32) bool {
    assert(head < emitter.count);
    assert(equals < emitter.count);

    if (span.assign_breaks(emitter, equals)) return false;
    if (assigning(emitter, equals) != null) return false;

    const paren = emitter.tokens[head].is_punctuation(.paren_open);
    const grouped = paren and assign_chain_grouped(emitter, head);
    var scan = head;

    for (0..assign_call_scan_max) |_| {
        if (emit.is_dot(emitter, scan)) {
            if (span.chain_parts(emitter, scan, scan)) {
                return !chain_filled(emitter, if (grouped) head + 1 else scan);
            }
        }

        const token = emitter.tokens[scan];

        const walked = token.kind == .identifier or emit.is_dot(emitter, scan) or
            walk.text_is(token.text(emitter.source), "this");

        const opening = paren and scan == head;

        if (opening) {
            scan = join.closing_of(emitter, scan) orelse scan;
        } else {
            if (!walked) return false;
        }

        scan = emit.ahead_of(emitter, scan) orelse return false;
    }

    return false;
}

fn assign_chain_grouped(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.tokens[head].is_punctuation(.paren_open));

    const close = join.closing_of(emitter, head) orelse return false;
    return list.paren_grouped(emitter, head, close);
}

fn assign_call_joined(emitter: *const Emitter, head: u32, equals: u32) bool {
    assert(head < emitter.count);
    assert(equals < emitter.count);

    const open = assign_call_open(emitter, head) orelse return false;
    if (open == head) return false;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const close = join.closing_of(emitter, open) orelse return false;
    if (!assign_call_whole(emitter, close)) return false;

    const braced = assign_call_braced(emitter, open, close);
    const from = emitter.tokens[open].end();
    const parted = body.parted_by(emitter, from, emitter.tokens[close].offset) > 0;

    if (!braced) {
        if (!parted) return false;
    }

    if (assign_filled(emitter, equals, open)) return false;
    return assigning(emitter, equals) == null;
}

fn assign_call_open(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = head;

    for (0..assign_call_scan_max) |_| {
        const token = emitter.tokens[scan];
        if (token.is_punctuation(.paren_open)) break;

        const text = token.text(emitter.source);
        const dotted = walk.text_is(text, ".") or walk.text_is(text, "?.");
        const worded = walk.text_is(text, "this") or walk.text_is(text, "new");
        const walked = token.kind == .identifier or dotted or worded;
        if (!walked) return null;

        scan = emit.ahead_of(emitter, scan) orelse return null;
    }

    return scan;
}

fn assign_call_whole(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const after = emit.ahead_of(emitter, close) orelse return true;
    const kind = emitter.tokens[after].kind;
    if (kind.eql(.{ .punctuation = .semicolon })) return true;
    if (kind.eql(.{ .punctuation = .comma })) return true;
    if (walk.is_close(kind)) return true;
    return kind == .block_end;
}

fn assign_call_braced(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    for (open..close) |index| {
        if (emitter.tokens[index].kind == .block_start) return true;
    }

    return false;
}

fn import_equals(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const name = emit.back_of(emitter, position) orelse return false;
    const held = emit.back_of(emitter, name) orelse return false;

    return walk.text_is(emitter.tokens[held].text(emitter.source), "import");
}

const SourcedWalk = struct {
    scan: u32,
    opened: ?u32,
};

const SourcedStep = union(enum) {
    stepped,
    stopped,
    decided: bool,
};

pub fn assign_sourced(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    if (!emitter.policy.chain_simples) return false;
    if (!walk.text_is(emitter.tokens[prior].text(emitter.source), "=")) return false;
    if (emitter.tokens[position].kind == .comment) return false;

    var walked: SourcedWalk = .{ .scan = position, .opened = null };
    var stopped = false;

    for (0..assign_source_scan_max) |_| {
        if (walked.scan >= emitter.count) break;

        switch (assign_sourced_step(emitter, prior, &walked)) {
            .stepped => {},
            .stopped => {
                stopped = true;

                break;
            },
            .decided => |verdict| return verdict,
        }
    }

    if (walked.opened == null) {
        if (!stopped) return false;
        return assign_sourced_fits(emitter, prior, walked.scan);
    }

    if (chain_poorly(emitter, position, walked.scan)) return false;
    return assign_sourced_fits(emitter, prior, walked.opened.?);
}

fn assign_sourced_fits(emitter: *const Emitter, prior: u32, end: u32) bool {
    assert(prior < end);
    assert(end < emitter.count);

    const spread = span.spread_count(emitter) + span.wrap_levels(emitter);
    const level = @max(emitter.printed, emitter.levels) + spread;
    const width = span.printed_columns(emitter, left_start(emitter, prior, level), end);

    return level * emitter.options.indent_width + width <= emitter.options.line_width;
}

fn assign_sourced_step(emitter: *const Emitter, prior: u32, walked: *SourcedWalk) SourcedStep {
    assert(walked.scan < emitter.count);
    assert(prior < emitter.count);

    const scan = walked.scan;

    if (tmpl.spanned_unit(emitter, scan)) |stop| {
        walked.scan = stop + 1;

        return .stepped;
    }

    const token = emitter.tokens[scan];
    const text = token.text(emitter.source);

    if (walk.text_is(text, "<")) {
        if (join.angle_close(emitter, scan)) |shut| {
            walked.scan = shut + 1;

            return .stepped;
        }
    }

    const arrow = walk.text_is(text, "=>");

    if (arrow) {
        if (walked.opened == null) walked.opened = arrow_source_stop(emitter, scan);
    }

    const ended = token.kind == .block_end or token.is_punctuation(.semicolon);
    const stops = arrow or walk.is_close(token.kind) or ended;
    if (stops) return .stopped;

    if (walked.opened == null) {
        if (alias_test_joined(emitter, prior, scan)) |fits| return .{ .decided = fits };
    }

    if (token.is_punctuation(.comma)) {
        if (bind.declares_item(emitter, scan)) return .stopped;
    }

    const questioned = walk.text_is(text, "?") and !tern.optional(emitter, scan);

    const refused = span.binary_rank(emitter, scan) != null or questioned or
        token.is_punctuation(.comma);

    if (refused) return .{ .decided = false };

    const opened = walk.is_open(token.kind) or token.kind == .block_start;

    if (!opened) {
        walked.scan = scan + 1;

        return .stepped;
    }

    return assign_sourced_opened(emitter, walked);
}

fn assign_sourced_opened(emitter: *const Emitter, walked: *SourcedWalk) SourcedStep {
    assert(walked.scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const scan = walked.scan;
    const shut = join.closing_of(emitter, scan) orelse return .{ .decided = false };

    if (walked.opened == null) {
        if (paren_plain(emitter, scan, shut)) {
            walked.scan = scan + 1;

            return .stepped;
        }

        const after = emit.ahead_of(emitter, scan);
        const hollow = after != null and after.? == shut;

        if (!hollow) walked.opened = scan;
    }

    walked.scan = shut + 1;

    return .stepped;
}

fn left_start(emitter: *const Emitter, equals: u32, level: u32) u32 {
    assert(equals < emitter.count);
    assert(emitter.line_first < emitter.count);
    assert(level < std.math.maxInt(u32));

    const start = emitter.line_first;
    if (!emitter.tokens[start].is_punctuation(.paren_open)) return start;

    const held = join.closing_of(emitter, start) orelse return start;
    if (held >= equals) return start;

    const indented = level * emitter.options.indent_width;
    const columns = indented + span.printed_columns(emitter, start, equals);
    if (columns <= emitter.options.line_width) return start;
    return held;
}

fn arrow_source_stop(emitter: *const Emitter, arrow: u32) u32 {
    assert(arrow < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.ahead_of(emitter, arrow) orelse return arrow;
    if (emitter.tokens[held].kind != .block_start) return arrow;
    return held;
}

fn alias_test_joined(emitter: *const Emitter, equals: u32, question: u32) ?bool {
    assert(equals < emitter.count);
    assert(question < emitter.count);

    if (!walk.text_is(emitter.tokens[question].text(emitter.source), "?")) return null;
    if (tern.optional(emitter, question)) return null;
    if (!aliased(emitter, equals)) return null;
    if (alias_conditional(emitter, equals) != null) return null;
    return alias_test_fits(emitter, equals, question);
}

fn alias_test_fits(emitter: *const Emitter, equals: u32, question: u32) bool {
    assert(equals < emitter.count);
    assert(question < emitter.count);

    const held = emit.back_of(emitter, question) orelse return false;
    const spread = span.spread_count(emitter) + span.wrap_levels(emitter);
    const level = @max(emitter.printed, emitter.levels) + spread;
    const from = alias_parted(emitter, equals, emitter.line_first, level) orelse emitter.line_first;
    const indented = level * emitter.options.indent_width;

    return indented + span.printed_columns(emitter, from, held) <= emitter.options.line_width;
}

fn paren_plain(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;
    if (list.calling(emitter, open)) return false;
    if (list.paren_grouped(emitter, open, close)) return false;

    const held = emit.ahead_of(emitter, close) orelse return true;
    const token = emitter.tokens[held];
    if (token.is_punctuation(.colon)) return false;
    return !walk.text_is(token.text(emitter.source), "=>");
}

pub fn assigning(emitter: *const Emitter, position: u32) ?struct { u32, u32 } {
    assert(position < emitter.count);
    assert(emitter.assigns <= core.assign_depth_max);

    if (tmpl.holed(emitter)) return null;

    const close, const dedent = assigning_value(emitter, position) orelse return null;
    if (unite.intersect_crossed(emitter, position, close)) return null;

    const linked = assign_link(emitter, position) orelse return .{ close, dedent };
    if (linked >= close) return .{ close, dedent };

    const indented = emitter.printed * emitter.options.indent_width;
    const columns = indented + span.printed_columns(emitter, emitter.line_first, linked);
    const fits = columns <= emitter.options.line_width;

    return .{ linked, if (fits) linked else dedent };
}

fn assign_link(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const head = assign_link_head(emitter, position) orelse return null;
    var scan = head;

    for (0..assign_chain_max) |_| {
        const token = emitter.tokens[scan];
        const text = token.text(emitter.source);
        const equals = token.is_punctuation(.assign) and walk.text_is(text, "=");
        const subscripted = scan > head and token.is_punctuation(.bracket_open);

        if (equals) return if (scan > head) scan else null;

        if (subscripted) {
            const shut = join.closing_of(emitter, scan) orelse return null;

            scan = emit.ahead_of(emitter, shut) orelse return null;

            continue;
        }

        const walked = token.kind == .identifier or walk.text_is(text, "this") or
            emit.is_dot(emitter, scan);

        if (scan > head) {
            if (compound_assign(emitter, scan)) return scan;
        }

        if (!walked) return null;

        scan = emit.ahead_of(emitter, scan) orelse return null;
    }

    return null;
}

fn assign_link_head(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const head = emit.ahead_of(emitter, position) orelse return null;
    if (!emitter.tokens[head].is_punctuation(.paren_open)) return head;

    const close = join.closing_of(emitter, head) orelse return null;
    if (!assign_call_whole(emitter, close)) return null;
    return emit.ahead_of(emitter, head);
}

fn fluid_tailed(emitter: *const Emitter, inlined: bool, scan: u32) ?u32 {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!inlined) return null;
    if (jsx.wrapped(emitter, scan) == null) return null;
    return span.jsx_body(emitter, scan);
}

const AssignWalk = struct {
    position: u32,
    bound: ?u32,
    breaks: bool,
    inlined: bool,
    unslight: bool,
    close: ?u32,
    opened: bool,
    prior: ?u32,
    scan: u32,
};

const AssignStep = union(enum) {
    stepped,
    refused,
    found: struct { u32, u32 },
};

const AssignBracket = struct {
    filled: bool,
    indexed: bool,
    poorly: bool,
};

fn assigning_value(emitter: *const Emitter, position: u32) ?struct { u32, u32 } {
    assert(position < emitter.count);
    assert(emitter.assigns <= core.assign_depth_max);

    if (assign_refused(emitter, position)) return null;
    if (arrow_chain_at(emitter, position) != null) return null;
    if (param_defaulted(emitter)) return null;
    if (import_equals(emitter, position)) return null;
    if (assigning_refused(emitter, position)) return null;
    if (annotation_complex(emitter, position)) return null;
    if (alias_broken_value(emitter, position)) |end| return .{ end, end };
    if (assigning_jsx(emitter, position)) return null;

    const held = emitter.depth > 0 and line.frame(emitter).kind != .block_start;
    const bound = if (held) assign_bound(emitter, position) else null;

    if (held) {
        if (bound == null) return assigning_unbound(emitter, position);
    } else {
        if (!opened_above(emitter, position)) return null;

        if (!opened_statement(emitter, position)) {
            if (!bind.declares_valued(emitter, position)) return null;
        }
    }

    if (assign_arrow(emitter, position)) |arrowed| return .{ arrowed[0], arrowed[1] };

    if (assign_functioned(emitter, position)) |functioned| {
        return .{ functioned[0], functioned[1] };
    }

    if (assigning_ternary(emitter, position)) {
        const ternaried = tern.assign_ternaried(emitter, position) orelse return null;
        return .{ ternaried[0], ternaried[1] };
    }

    return assigning_walk(emitter, position, bound);
}

fn assigning_refused(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const text = emitter.tokens[position].text(emitter.source);
    const compound = compound_assign(emitter, position);

    if (!walk.text_is(text, "=")) {
        if (!compound) return true;
    }

    if (required_value(emitter, position)) return true;
    if (tmpl.template_piece(emitter, position)) return true;
    if (assign_templated(emitter, position)) return true;
    return alias_refused(emitter, position);
}

fn assigning_jsx(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const start = emit.ahead_of(emitter, position) orelse return false;
    const head = jsx.operand_head(emitter, start);

    return jsx.wrapped(emitter, head) != null;
}

fn assigning_unbound(emitter: *const Emitter, position: u32) ?struct { u32, u32 } {
    assert(position < emitter.count);
    assert(emitter.depth > 0);

    if (assign_poorly(emitter, position)) |end| return .{ end, end };

    const ternaried = ternary_assigned(emitter, position) orelse return null;
    return .{ ternaried[0], ternaried[1] };
}

fn assigning_ternary(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const start = emit.ahead_of(emitter, position) orelse return false;
    return tern.ternary_owns(emitter, start);
}

fn assigning_walk(emitter: *const Emitter, position: u32, bound: ?u32) ?struct { u32, u32 } {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);
    if (bound) |held| assert(held < emitter.count);

    const start = emit.ahead_of(emitter, position);
    const breaks = span.assign_breaks(emitter, position);
    const inlined = start != null and inline_valued(emitter, start.?);

    var walked: AssignWalk = .{
        .position = position,
        .bound = bound,
        .breaks = breaks,
        .inlined = inlined,
        .unslight = assign_unslight(emitter, position),
        .close = null,
        .opened = true,
        .prior = null,
        .scan = position + 1,
    };

    for (0..emitter.count) |_| {
        if (walked.scan >= emitter.count) break;

        switch (assigning_step(emitter, &walked)) {
            .stepped => {},
            .refused => return null,
            .found => |pair| return .{ pair[0], pair[1] },
        }
    }

    return null;
}

fn assigning_step(emitter: *const Emitter, walked: *AssignWalk) AssignStep {
    assert(walked.scan < emitter.count);
    assert(walked.scan > walked.position);

    const scan = walked.scan;
    const token = emitter.tokens[scan];
    const blank = token.kind == .newline or token.length == 0;

    if (blank) {
        walked.scan = scan + 1;

        return .stepped;
    }

    const broken = assigning_broken(emitter, walked.prior, scan);

    if (walked.bound) |bound| {
        if (bound == scan) {
            if (broken) return .refused;
            return .{ .found = .{ walked.close orelse scan, scan } };
        }
    }

    if (fluid_tailed(emitter, walked.inlined, scan)) |end| {
        if (walked.close == null) walked.close = scan;

        walked.prior = end;
        walked.scan = end + 1;

        return .stepped;
    }

    if (walk.is_close(token.kind)) return .refused;

    if (!broken) {
        if (token.is_punctuation(.comma)) {
            if (bind.declares_item(emitter, scan)) {
                return .{ .found = .{ walked.close orelse scan, scan } };
            }
        }

        if (token.is_punctuation(.semicolon)) {
            if (!assigning_alone(emitter, scan)) return .refused;
            return .{ .found = .{ walked.close orelse scan, scan } };
        }
    }

    return assigning_scan(emitter, walked, broken);
}

fn assigning_scan(emitter: *const Emitter, walked: *AssignWalk, broken: bool) AssignStep {
    assert(walked.scan < emitter.count);
    assert(walked.scan > walked.position);

    const scan = walked.scan;
    const unbound = walked.bound == null and walked.close == null;

    if (unbound) {
        if (!walked.breaks) {
            if (span.chain_parts(emitter, scan, scan)) return assigning_filled(emitter, scan);
        }
    }

    if (emitter.policy.chain_simples) {
        if (unbound) {
            if (assigning_fluid(emitter, walked.position, scan)) {
                walked.close = emit.back_of(emitter, scan);
            }
        }
    }

    if (assigning_stopped(emitter, scan, broken, walked.breaks)) return .refused;

    if (tmpl.template_body(emitter, scan) orelse span.jsx_body(emitter, scan)) |end| {
        if (body.parts_at(emitter, scan, end)) return .refused;
        if (assigning_arrow_tagged(emitter, scan)) return .refused;

        walked.prior = scan;
        walked.scan = end + 1;

        return .stepped;
    }

    if (walked.close == null) {
        if (cast_parenthesized(emitter, scan)) walked.close = scan;
    }

    return assigning_cast_step(emitter, walked);
}

fn assigning_arrow_tagged(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (jsx.wrapped(emitter, scan) == null) return false;

    const before = emit.back_of(emitter, scan) orelse return false;

    assert(before < scan);

    return walk.text_is(emitter.tokens[before].text(emitter.source), "=>");
}

fn assigning_cast_step(emitter: *const Emitter, walked: *AssignWalk) AssignStep {
    assert(walked.scan < emitter.count);
    assert(walked.scan > walked.position);

    const scan = walked.scan;

    if (parenthesized(emitter, scan)) |closes| {
        walked.prior = closes;
        walked.scan = closes + 1;

        return .stepped;
    }

    if (walked.close == null) {
        if (assigning_cast(emitter, scan)) walked.close = scan;
    }

    const typed = walked.close != null;

    if (assign_angle_commented(emitter, scan)) return .refused;

    const angled = assign_angled(emitter, scan) orelse assign_cast_type(emitter, scan, typed);

    if (angled) |ends| {
        walked.prior = ends;
        walked.scan = ends + 1;

        return .stepped;
    }

    if (walk.is_open(emitter.tokens[scan].kind)) return assigning_bracket(emitter, walked);

    walked.prior = scan;
    walked.scan = scan + 1;

    return .stepped;
}

fn assigning_filled(emitter: *const Emitter, scan: u32) AssignStep {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!chain_filled(emitter, scan)) return .refused;

    const end = call.valued_semicolon(emitter, scan) orelse return .refused;
    return .{ .found = .{ scan, end } };
}

fn assigning_fluid(emitter: *const Emitter, position: u32, scan: u32) bool {
    assert(position < scan);
    assert(scan < emitter.count);

    if (!emit.is_dot(emitter, scan)) return false;
    if (!member_fluid_head(emitter, position)) return false;
    return link.member_grouped(emitter, scan);
}

fn assigning_broken(emitter: *const Emitter, prior: ?u32, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);
    if (prior) |held| assert(held < emitter.count);

    const held = prior orelse return false;
    if (!body.parts_at(emitter, held, scan)) return false;
    return !split.semicolon_joined(emitter, scan, held);
}

fn assigning_alone(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.tokens[scan].is_punctuation(.semicolon));

    const after = emit.ahead_of(emitter, scan) orelse return true;
    if (body.parts_at(emitter, scan, after)) return true;
    if (body.ends(emitter, after)) return true;
    if (!edge.inside_a_body(emitter)) return false;
    return body.parted_statement(emitter, scan);
}

fn assigning_stopped(emitter: *const Emitter, scan: u32, broken: bool, breaks: bool) bool {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[scan];
    const text = token.text(emitter.source);

    if (token.kind == .comment) {
        if (std.mem.startsWith(u8, text, "//")) return true;

        const after = emit.ahead_of(emitter, scan) orelse return true;
        if (body.parts_at(emitter, scan, after)) return true;
    }

    if (broken) {
        if (!value_dotted(emitter, scan)) return true;
    }

    if (std.mem.findScalar(u8, text, '\n') != null) return true;
    if (breaks) return false;
    return span.chain_parts(emitter, scan, scan);
}

fn assigning_cast(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (line.group_word(emitter, scan)) {
        if (cast_union(emitter, scan)) return true;
    }

    if (wrap.cast_wrapped(emitter, scan) != null) return true;
    if (wrap.cast_typed(emitter, scan)) return true;
    return wrap.cast_literal(emitter, scan);
}

fn assigning_bracket(emitter: *const Emitter, walked: *AssignWalk) AssignStep {
    assert(walked.scan < emitter.count);
    assert(walked.scan > walked.position);

    const scan = walked.scan;
    const lead_open = walked.opened;

    walked.opened = false;

    const classed = assign_classed(emitter, walked.position);
    const heads = classed != null and classed.? == scan;

    const bracket: AssignBracket = .{
        .filled = lead_open or heads,
        .indexed = assigning_indexed(emitter, scan),
        .poorly = !walked.unslight and list.bracket_poorly(emitter, scan),
    };

    const holds = list.assign_holds(emitter, scan, walked.breaks, walked.close != null);
    const closes = holds orelse return assigning_unheld(emitter, walked, &bracket);

    if (bodied_value(emitter, scan, closes)) {
        const filled = bracket.filled and assign_filled(emitter, walked.position, scan);
        if (!filled) return .refused;
    }

    const inlined = walked.close != null and assign_inlined(emitter, scan, walked.prior);
    const plain = !bracket.indexed and !bracket.poorly and !inlined;

    if (plain) {
        if (assigning_valued(emitter, walked, scan, closes)) walked.close = scan;
    }

    walked.prior = closes;
    walked.scan = closes + 1;

    return .stepped;
}

fn assigning_unheld(
    emitter: *const Emitter,
    walked: *AssignWalk,
    bracket: *const AssignBracket,
) AssignStep {
    assert(walked.scan < emitter.count);
    assert(walked.scan > walked.position);

    const scan = walked.scan;

    if (!emitter.policy.assign_lines) return .refused;

    const ends = join.closing_of(emitter, scan) orelse return .refused;
    const braced = assigning_braced(emitter, scan, ends);
    const from = emitter.tokens[scan].end();
    const parted = body.parted_by(emitter, from, emitter.tokens[ends].offset) > 0;
    const spread = braced or parted;

    if (spread) {
        const filled = bracket.filled and assign_filled(emitter, walked.position, scan);
        if (!filled) return .refused;
    }

    const after = emit.ahead_of(emitter, scan);
    const emptied = after != null and after.? == ends;
    const plain = walked.close == null and !bracket.indexed and !emptied and !bracket.poorly;

    if (plain) {
        if (assigning_valued(emitter, walked, scan, ends)) walked.close = scan;
    }

    walked.prior = ends;
    walked.scan = ends + 1;

    return .stepped;
}

fn assigning_valued(emitter: *const Emitter, walked: *const AssignWalk, scan: u32, end: u32) bool {
    assert(scan < end);
    assert(end < emitter.count);

    if (value_cast(emitter, end)) return true;
    if (value_newed(emitter, scan)) return true;
    if (walked.inlined) return true;
    if (walked.unslight) return true;
    return !list.slight(emitter, scan, end);
}

fn assigning_braced(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    for (open..close) |index| {
        const at: u32 = @intCast(index);
        if (emitter.tokens[at].kind != .block_start) continue;

        const after = emit.ahead_of(emitter, at) orelse return true;
        if (emitter.tokens[after].kind != .block_end) return true;
    }

    return false;
}

fn assigning_indexed(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[scan].is_punctuation(.bracket_open)) return false;

    const at = emit.back_of(emitter, scan) orelse return false;
    if (!emitter.tokens[at].ends_a_value()) return false;

    const close = join.closing_of(emitter, scan) orelse return false;
    if (!list.paren_operated(emitter, scan, close)) return false;
    if (!list.bracket_slight(emitter, scan)) return false;
    return !list.lookup_cast(emitter, scan);
}

fn assign_unslight(emitter: *const Emitter, equals: u32) bool {
    assert(equals < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const head = value.head_of(emitter, equals, emitter.count) orelse return false;
    const token = emitter.tokens[head];
    const named = token.kind == .identifier or walk.text_is(token.text(emitter.source), "this");
    if (!named) return false;

    const stop = link.chain_stop(emitter, head) orelse return false;
    if (!assign_unslight_whole(emitter, stop)) return false;
    return !span.member_slight(emitter, head, stop);
}

fn assign_unslight_whole(emitter: *const Emitter, stop: u32) bool {
    assert(stop < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const after = emit.ahead_of(emitter, stop) orelse return true;
    const kind = emitter.tokens[after].kind;
    if (kind == .block_end) return true;
    if (kind.eql(.{ .punctuation = .comma })) return true;
    if (kind.eql(.{ .punctuation = .semicolon })) return true;
    if (walk.is_close(kind)) return true;
    return body.parts_at(emitter, stop, after);
}

pub fn template_joined(emitter: *const Emitter, prior: u32) bool {
    assert(prior < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.template_spans) return false;

    const text = emitter.tokens[prior].text(emitter.source);
    if (walk.text_is(text, "=")) return assign_templated(emitter, prior);
    if (!walk.text_is(text, ":")) return false;
    if (emitter.depth == 0) return false;
    if (emitter.typed) return false;
    if (tern.ternary(emitter, prior)) return false;

    const held = line.frame(emitter);
    if (held.kind != .block_start) return false;

    const end = value.ended(emitter, prior, held.close) orelse return false;
    const bound = value.valued_bound(emitter, prior, end);
    if (!bind.lone_value(emitter, prior, bound)) return false;
    return !value.key_breaks(emitter, prior);
}

fn assign_templated(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.template_spans) return false;

    var scan = emit.ahead_of(emitter, position) orelse return false;

    for (0..assign_tag_max) |_| {
        const token = emitter.tokens[scan];

        if (token.kind != .identifier) {
            if (!emit.is_dot(emitter, scan)) break;
        }

        scan = emit.ahead_of(emitter, scan) orelse return false;
    }

    const close = tmpl.template_whole(emitter, scan) orelse return false;
    const after = emit.ahead_of(emitter, close);

    const ended = if (after) |held| blk: {
        const kind = emitter.tokens[held].kind;
        if (kind == .block_end) break :blk true;
        if (emitter.tokens[held].is_punctuation(.comma)) break :blk true;
        if (emitter.tokens[held].is_punctuation(.semicolon)) break :blk true;

        break :blk walk.is_close(kind);
    } else true;

    if (!ended) return false;
    return assign_left_rigid(emitter, position);
}

const LeftRigidStep = union(enum) {
    scan: u32,
    stop: bool,
};

fn assign_left_rigid(emitter: *const Emitter, equals: u32) bool {
    assert(equals < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = equals;

    for (0..assign_left_max) |_| {
        const before = emit.back_of(emitter, scan) orelse return true;

        switch (assign_left_rigid_step(emitter, before, scan)) {
            .stop => |result| return result,
            .scan => |next| scan = next,
        }
    }

    return false;
}

fn assign_left_rigid_step(emitter: *const Emitter, before: u32, scan: u32) LeftRigidStep {
    assert(before < emitter.count);
    assert(scan < emitter.count);

    const token = emitter.tokens[before];
    if (token.kind == .block_start) return .{ .stop = true };
    if (token.is_punctuation(.semicolon)) return .{ .stop = true };

    if (token.kind == .comment) {
        if (body.parts_at(emitter, before, scan)) return .{ .stop = true };
    } else {
        const worded = token.kind == .identifier or token.kind == .keyword;
        if (worded) return assign_left_rigid_worded(emitter, before);
        if (token.is_punctuation(.paren_close)) return assign_left_rigid_paren(emitter, before);

        if (token.is_punctuation(.bracket_close)) {
            return assign_left_rigid_bracket(emitter, before);
        }

        if (token.kind == .block_end) return .{ .stop = body.parts_at(emitter, before, scan) };
    }

    return assign_left_rigid_wild(emitter, before);
}

fn assign_left_rigid_worded(emitter: *const Emitter, before: u32) LeftRigidStep {
    assert(before < emitter.count);

    const text = emitter.tokens[before].text(emitter.source);
    if (word_listed(&assign_modifiers, text)) return .{ .stop = false };
    return .{ .scan = before };
}

fn assign_left_rigid_paren(emitter: *const Emitter, before: u32) LeftRigidStep {
    assert(before < emitter.count);

    const open = emitter.brackets.open_of(before) orelse return .{ .stop = false };
    const after = emit.ahead_of(emitter, open) orelse return .{ .stop = false };
    if (after != before) return .{ .stop = false };
    return .{ .scan = open };
}

fn assign_left_rigid_bracket(emitter: *const Emitter, before: u32) LeftRigidStep {
    assert(before < emitter.count);

    const open = emitter.brackets.open_of(before) orelse return .{ .stop = false };

    const literal = blk: {
        const inner = emit.ahead_of(emitter, open) orelse break :blk false;
        if (emitter.tokens[inner].kind != .number) break :blk false;

        const after = emit.ahead_of(emitter, inner) orelse break :blk false;

        break :blk after == before;
    };

    if (!literal) return .{ .stop = false };
    return .{ .scan = open };
}

fn assign_left_rigid_wild(emitter: *const Emitter, before: u32) LeftRigidStep {
    assert(before < emitter.count);

    const text = emitter.tokens[before].text(emitter.source);
    if (walk.text_is(text, ">")) return assign_left_rigid_angle(emitter, before);
    if (link.asserted_member(emitter, before)) return .{ .stop = false };

    const marked = emit.is_dot(emitter, before) or
        walk.text_is(text, "!") or
        walk.text_is(text, "?") or
        walk.text_is(text, ":");

    if (marked) return .{ .scan = before };
    return .{ .stop = false };
}

fn assign_left_rigid_angle(emitter: *const Emitter, before: u32) LeftRigidStep {
    assert(before < emitter.count);

    const name = emit.back_of(emitter, before) orelse return .{ .stop = false };
    if (emitter.tokens[name].kind != .identifier) return .{ .stop = false };

    const open = emit.back_of(emitter, name) orelse return .{ .stop = false };

    if (!walk.text_is(emitter.tokens[open].text(emitter.source), "<")) {
        return .{ .stop = false };
    }

    return .{ .scan = open };
}

pub fn constructing(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.constructed <= brace.nest_depth_max);

    emitter.glued = false;

    if (emitter.policy.construct_words.len == 0) return;
    if (!line.word_is(emitter, position, emitter.policy.declaration_words)) return;
    if (emitter.constructed == brace.nest_depth_max) return;

    const before = emit.word_previous(emitter, position) orelse return;
    if (!line.word_is(emitter, before, emitter.policy.construct_words)) return;

    const close = bodied_of(emitter, position) orelse return;

    assert(close > position);

    emitter.constructs[emitter.constructed] = close;
    emitter.constructed += 1;

    try emitter.document.push(.{ .text = .{ .source = .literal, .span = emitter.opening } });
}

pub fn constructed(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.constructed <= brace.nest_depth_max);

    if (emitter.constructed == 0) return;
    if (emitter.constructs[emitter.constructed - 1] != position) return;

    emitter.constructed -= 1;

    try emitter.document.push(.{ .text = .{ .source = .literal, .span = emitter.closing } });

    const after = emit.ahead_of(emitter, position);
    const called = if (after) |held| emitter.tokens[held].is_punctuation(.paren_open) else false;

    if (called) {
        emitter.glued = true;
        emitter.suppress_space = true;

        return;
    }

    try emitter.document.push(.{ .text = .{ .source = .literal, .span = emitter.opening } });
    try emitter.document.push(.{ .text = .{ .source = .literal, .span = emitter.closing } });
}

fn assign_refused(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.assigns <= core.assign_depth_max);

    if (assign_chain(emitter, position) != null) return true;
    if (!emitter.policy.assign_groups) return true;
    if (span.owned_assign(emitter, position)) return true;
    if (assign_wrap(emitter, position) != null) return true;
    if (emitter.brackets.angles_at(position) > 0) return true;
    if (assign_patterned(emitter, position)) return true;
    return enum_valued(emitter, position);
}

pub fn enum_valued(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.assign_groups) return false;
    if (emitter.depth == 0) return false;
    if (!emitter.tokens[position].is_punctuation(.assign)) return false;

    const held = line.frame(emitter);
    if (held.kind != .block_start) return false;

    const name = emit.back_of(emitter, held.open) orelse return false;
    const word = emit.back_of(emitter, name) orelse return false;

    return walk.text_is(emitter.tokens[word].text(emitter.source), "enum");
}

pub fn assign_operator(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.tokens[position].is_punctuation(.assign)) return true;
    return compound_assign(emitter, position);
}

pub fn compound_assign(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.tokens.len == emitter.count);

    const text = emitter.tokens[position].text(emitter.source);
    if (text.len <= 1) return false;
    if (!std.mem.endsWith(u8, text, "=")) return false;
    if (word_listed(&compound_refused, text)) return false;

    const held = emit.back_of(emitter, position) orelse return false;

    assert(held < position);

    if (emitter.tokens[held].ends_a_value()) return true;
    return line.nonnull_ended(emitter, held);
}

pub fn assign_wrap(emitter: *const Emitter, position: u32) ?struct { u32, core.Wrap } {
    assert(position < emitter.count);

    if (!emitter.policy.assign_lines) return null;
    if (emitter.assigns > 0) return null;

    const assigns = emitter.tokens[position].is_punctuation(.assign) or
        compound_assign(emitter, position);

    if (!assigns) return null;
    if (required_value(emitter, position)) return null;
    if (assign_chain(emitter, position) != null) return null;

    const whole = emitter.depth > 0 and assign_paren_whole(emitter, position);

    const claused = emitter.depth > 0 and !whole and
        commenting.header_clauses(emitter, line.frame(emitter).open);

    if (emitter.depth > 0) {
        const blocked = line.frame(emitter).kind == .block_start;
        const refused = !blocked and !whole and !claused;
        if (refused) return null;
    }

    const head = emit.ahead_of(emitter, position) orelse return null;

    const end = if (whole)
        line.frame(emitter).close
    else
        (call.valued_semicolon(emitter, head) orelse return null);

    const stop = emit.back_of(emitter, end) orelse return null;

    assert(position < head);

    if (stop <= head) return null;
    if (!valued_binary(emitter, head, stop)) return null;
    if (call.binary_inline_pair(emitter, head, stop)) return null;
    if (cast_valued(emitter, head, stop)) return null;
    if (call.binary_fluid(emitter, head, stop)) return .{ stop, .argued };
    return .{ stop, .valued };
}

pub fn value_wrap(emitter: *const Emitter, position: u32) ?struct { u32, core.Wrap } {
    assert(position < emitter.count);

    if (!emitter.policy.assign_lines) return null;

    const top = emitter.depth == 0;
    const before = emit.back_of(emitter, position) orelse return null;
    const kind = emitter.tokens[before].kind;
    const pushed = value_wrap_pushed(emitter, position);
    const outer = value_wrap_outer(emitter, pushed);
    const paired = value_wrap_paired(emitter, before, outer);
    const valued = kind.eql(.{ .punctuation = .assign }) or compound_assign(emitter, before);
    const returned = value_wrap_returned(emitter, position, before);
    const looked = value_wrap_looked(emitter, before);
    const listing: ?core.Frame = if (pushed) outer else line.frame(emitter);
    const leading = value_wrap_lead(emitter, position, before);

    const argued = !paired and !valued and
        (value_wrap_argued(emitter, listing, leading, looked) or
            value_wrap_arrayed(emitter, position, listing, leading));

    assert(before < position);

    if (argued) {
        if (emitter.tokens[position].kind == .comment) return null;
    }

    const seated = wrap_frame(emitter, position);
    const grouped = !paired and !valued and !argued and value_wrap_grouped(emitter, before, seated);

    const branched = !paired and !valued and !argued and !grouped and
        value_wrap_branched(emitter, leading, pushed, outer);

    const consequent = !paired and !valued and !argued and !grouped and !branched and
        walk.text_is(emitter.tokens[leading].text(emitter.source), "?") and
        !tern.optional(emitter, leading);

    if (returned) {
        const headed = value_headed(emitter, position) orelse return null;
        return .{ headed[0], .argued };
    }

    const bodied = !paired and !valued and !argued and
        walk.text_is(emitter.tokens[before].text(emitter.source), "=>") and
        value_wrap_headed_ternary(emitter, position);

    if (bodied) return value_headed(emitter, position);

    const standalone = !paired and !valued and !argued and !grouped and !pushed and
        test_stated(emitter, position, before);

    if (standalone) return value_headed(emitter, position);

    const passive = !paired and !valued and !argued and !grouped and !branched and !consequent;
    const topped = top and !branched and !valued;

    if (passive) return null;
    if (topped) return null;
    if (consequent) return tern.value_consequent(emitter, position);
    if (valued) return value_headed(emitter, position);
    if (branched) return value_branched(emitter, position);
    if (grouped) return value_wrap_group(emitter, position, seated orelse return null);
    return value_wrap_element(emitter, position, paired, argued, outer, listing);
}

fn value_wrap_pushed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.policy.assign_lines);

    if (!walk.is_open(emitter.tokens[position].kind)) return false;
    return line.frame(emitter).open == position;
}

fn value_wrap_outer(emitter: *const Emitter, pushed: bool) ?core.Frame {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.policy.assign_lines);

    if (!pushed) return line.frame(emitter);
    if (emitter.depth < 2) return null;
    return emitter.nest[emitter.depth - 2];
}

fn value_wrap_paired(emitter: *const Emitter, before: u32, outer: ?core.Frame) bool {
    assert(before < emitter.count);
    assert(emitter.policy.assign_lines);

    if (!emitter.tokens[before].is_punctuation(.colon)) return false;
    if (!emitter.policy.colon_continues) return false;
    if (outer) |held| assert(held.close == 0 or held.close > held.open);

    const frame = outer orelse return false;
    if (frame.kind != .block_start) return false;
    if (tern.ternary_within(emitter, before, frame.open)) return false;
    return valued_object_in(emitter, &frame);
}

fn value_wrap_returned(emitter: *const Emitter, position: u32, before: u32) bool {
    assert(before < position);
    assert(position < emitter.count);

    const text = emitter.tokens[before].text(emitter.source);
    const jumps = walk.text_is(text, "return") or walk.text_is(text, "throw");
    if (!jumps) return false;
    return value_wrap_headed_ternary(emitter, position);
}

fn value_wrap_headed_ternary(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.policy.assign_lines);

    const question = tern.ternary_ahead(emitter, position) orelse return false;
    return tern.ternary_head(emitter, question) == position;
}

fn value_wrap_looked(emitter: *const Emitter, before: u32) bool {
    assert(before < emitter.count);
    assert(emitter.policy.assign_lines);

    if (!emitter.tokens[before].is_punctuation(.bracket_open)) return false;
    if (line.frame(emitter).open != before) return false;
    return list.bracket_lookup(emitter, before);
}

fn value_wrap_lead(emitter: *const Emitter, position: u32, before: u32) u32 {
    assert(before < position);
    assert(position < emitter.count);

    if (emitter.tokens[before].kind != .comment) return before;
    return commenting.back(emitter, position) orelse before;
}

fn value_wrap_argued(
    emitter: *const Emitter,
    listing: ?core.Frame,
    leading: u32,
    looked: bool,
) bool {
    assert(emitter.policy.assign_lines);
    assert(emitter.depth <= brace.nest_depth_max);
    assert(leading < emitter.count);
    if (listing) |held| assert(held.close == 0 or held.close > held.open);

    const frame = listing orelse return false;
    if (frame.spread == null) return false;

    const led = emitter.tokens[leading].kind;

    const separated = led.eql(.{ .punctuation = .comma }) or
        led.eql(.{ .punctuation = .paren_open });

    const listed = frame.kind.eql(.{ .punctuation = .paren_open });
    const called = separated and listed and list.calling(emitter, frame.open);

    if (!called) {
        if (!looked) return false;
    }

    return !argued_commented(emitter, &frame);
}

fn value_wrap_arrayed(
    emitter: *const Emitter,
    position: u32,
    listing: ?core.Frame,
    leading: u32,
) bool {
    assert(position < emitter.count);
    assert(emitter.policy.assign_lines);
    assert(leading < position);
    if (listing) |held| assert(held.close == 0 or held.close > held.open);

    const frame = listing orelse return false;
    if (frame.spread == null) return false;
    if (!frame.kind.eql(.{ .punctuation = .bracket_open })) return false;

    const led = emitter.tokens[leading].kind;

    const separated = led.eql(.{ .punctuation = .comma }) or
        led.eql(.{ .punctuation = .bracket_open });

    if (!separated) return false;

    if (emit.back_of(emitter, frame.open)) |before| {
        if (walk.ends_operand(emitter.tokens[before].kind)) return false;
    }

    const end = valued_element_in(emitter, position, frame.close) orelse return false;
    if (end <= position) return false;
    if (argued_commented(emitter, &frame)) return false;
    if (span.spread_breaks(emitter, position, end)) return true;

    for (position..end) |index| {
        const scan: u32 = @intCast(index);
        if (emitter.tokens[scan].kind != .block_start) continue;
        if (call.object_parted(emitter, scan)) return true;
    }

    return false;
}

fn value_wrap_grouped(emitter: *const Emitter, before: u32, seated: ?core.Frame) bool {
    assert(before < emitter.count);
    assert(emitter.policy.assign_lines);

    if (!emitter.policy.spread_values) return false;
    if (!emitter.tokens[before].is_punctuation(.paren_open)) return false;
    if (seated) |held| assert(held.close == 0 or held.close > held.open);

    const held = seated orelse return false;
    if (!held.kind.eql(.{ .punctuation = .paren_open })) return false;
    if (held.open != before) return false;
    if (list.calling(emitter, before)) return false;
    if (split.headed(emitter, before)) return false;
    if (unite.hole_operand(emitter, before) != null) return false;
    if (lambda_paren(emitter, before)) return false;

    const ahead = emit.back_of(emitter, before) orelse return true;
    const text = emitter.tokens[ahead].text(emitter.source);
    const jumps = walk.text_is(text, "return") or walk.text_is(text, "throw");
    if (!jumps) return true;
    return !value_returned(emitter, before);
}

fn value_wrap_branched(
    emitter: *const Emitter,
    coloned: u32,
    pushed: bool,
    outer: ?core.Frame,
) bool {
    assert(coloned < emitter.count);
    assert(emitter.policy.assign_lines);

    if (!emitter.tokens[coloned].is_punctuation(.colon)) return false;
    if (outer) |held| assert(held.close == 0 or held.close > held.open);

    if (pushed) {
        const open = if (outer) |frame| frame.open else 0;
        return tern.ternary_within(emitter, coloned, open);
    }

    return tern.ternary(emitter, coloned);
}

fn value_wrap_group(
    emitter: *const Emitter,
    position: u32,
    held: core.Frame,
) ?struct { u32, core.Wrap } {
    assert(position < emitter.count);
    assert(held.open < held.close);

    const operand = value_wrap_operand(emitter, held.close);

    if (operand) {
        if (tern.ternary_ahead(emitter, position)) |question| {
            const headed = question < held.close and
                tern.ternary_head(emitter, question) == position;

            if (headed) return value_headed(emitter, position);
        }
    }

    return value_grouped(emitter, position, held.close, held.spread != null);
}

fn value_wrap_operand(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.policy.assign_lines);

    const after = emit.ahead_of(emitter, close) orelse return true;
    const token = emitter.tokens[after];
    if (walk.is_open(token.kind)) return false;
    if (emit.is_dot(emitter, after)) return false;
    return !walk.text_is(token.text(emitter.source), "`");
}

fn value_wrap_close(
    emitter: *const Emitter,
    paired: bool,
    argued: bool,
    outer: ?core.Frame,
    listing: ?core.Frame,
) u32 {
    assert(paired or argued);
    assert(emitter.policy.assign_lines);
    if (outer) |held| assert(held.close == 0 or held.close > held.open);
    if (listing) |held| assert(held.close == 0 or held.close > held.open);

    if (paired) {
        if (outer) |frame| return frame.close;
    }

    if (argued) {
        if (listing) |frame| return frame.close;
    }

    return line.frame(emitter).close;
}

fn value_wrap_element(
    emitter: *const Emitter,
    position: u32,
    paired: bool,
    argued: bool,
    outer: ?core.Frame,
    listing: ?core.Frame,
) ?struct { u32, core.Wrap } {
    assert(position < emitter.count);
    assert(paired or argued);
    if (outer) |held| assert(held.close == 0 or held.close > held.open);
    if (listing) |held| assert(held.close == 0 or held.close > held.open);

    const close = value_wrap_close(emitter, paired, argued, outer, listing);
    const end = valued_element_in(emitter, position, close) orelse return null;
    const stop = emit.back_of(emitter, end) orelse return null;
    if (stop <= position) return null;

    if (valued_question(emitter, position, stop)) |question| {
        const held = emit.back_of(emitter, question) orelse return null;
        if (held <= position) return null;
        if (!valued_binary(emitter, position, held)) return null;
        return .{ held, .paired };
    }

    if (!valued_binary(emitter, position, stop)) return null;
    if (call.binary_inline_pair(emitter, position, stop)) return null;
    if (argued) return .{ stop, .argued };
    if (call.binary_fluid(emitter, position, stop)) return .{ stop, .argued };
    return .{ stop, .paired };
}

fn lambda_paren(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const close = join.closing_of(emitter, open) orelse return false;
    const after = emit.ahead_of(emitter, close) orelse return false;
    const text = emitter.tokens[after].text(emitter.source);

    assert(after > close);

    if (walk.text_is(text, "=>")) return true;
    if (!walk.text_is(text, ":")) return false;
    if (tern.ternary(emitter, after)) return false;
    return arrow_typed_ahead(emitter, close) != null;
}

fn branch_parenthesized(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const held = emit.back_of(emitter, open) orelse return false;

    if (!branch_parenthesized_whole(emitter, open)) return false;

    const stop = branch_parenthesized_stop(emitter, open);
    const question = branch_parenthesized_question(emitter, held, stop) orelse return false;
    const tested = tern.ternary_head(emitter, question) orelse return false;
    const seat = emit.back_of(emitter, tested) orelse return true;
    const token = emitter.tokens[seat];
    const word = token.text(emitter.source);
    if (walk.text_is(word, "return")) return false;
    if (walk.text_is(word, "throw")) return false;
    if (token.is_punctuation(.comma)) return false;
    if (!token.is_punctuation(.paren_open)) return true;
    return !list.calling(emitter, seat);
}

fn branch_parenthesized_whole(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const close = join.closing_of(emitter, open) orelse return true;
    const after = emit.ahead_of(emitter, close) orelse return true;
    const token = emitter.tokens[after];

    assert(after > close);

    if (walk.is_close(token.kind)) return true;
    if (token.kind == .block_end) return true;
    if (token.is_punctuation(.colon)) return true;
    if (token.is_punctuation(.comma)) return true;
    return token.is_punctuation(.semicolon);
}

fn branch_parenthesized_stop(emitter: *const Emitter, open: u32) u32 {
    assert(open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    for (0..emitter.depth) |offset| {
        const at = emitter.depth - 1 - @as(u32, @intCast(offset));
        if (emitter.nest[at].open != open) continue;
        if (at == 0) return 0;
        assert(emitter.nest[at - 1].open < std.math.maxInt(u32));

        return emitter.nest[at - 1].open;
    }

    return 0;
}

fn branch_parenthesized_question(emitter: *const Emitter, held: u32, stop: u32) ?u32 {
    assert(held < emitter.count);
    assert(stop < emitter.count);

    const text = emitter.tokens[held].text(emitter.source);

    if (walk.text_is(text, "?")) {
        if (tern.optional(emitter, held)) return null;
        return held;
    }

    if (!walk.text_is(text, ":")) return null;
    return tern.ternary_question(emitter, held, stop);
}

fn value_returned(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const close = join.closing_of(emitter, open) orelse return true;
    const held = emit.ahead_of(emitter, close) orelse return true;

    assert(held > close);

    return emitter.tokens[held].is_punctuation(.semicolon);
}

fn wrap_frame(emitter: *const Emitter, position: u32) ?core.Frame {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const opened: u32 = @intFromBool(walk.is_open(emitter.tokens[position].kind));
    if (emitter.depth < 1 + opened) return null;
    return emitter.nest[emitter.depth - 1 - opened];
}

fn test_stated(emitter: *const Emitter, position: u32, before: u32) bool {
    assert(position < emitter.count);
    assert(before < emitter.count);

    const placed = if (edge.inside_a_body(emitter))
        test_stated_body(emitter, before)
    else
        test_stated_frame(emitter, before);

    if (!placed) return false;

    const question = tern.ternary_ahead(emitter, position) orelse return false;
    const head = tern.ternary_head(emitter, question) orelse return false;

    return head == position;
}

fn test_stated_body(emitter: *const Emitter, before: u32) bool {
    assert(before < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[before];
    if (token.kind == .block_start) return true;
    if (token.kind == .block_end) return true;
    if (token.is_punctuation(.comma)) return true;
    return token.is_punctuation(.semicolon);
}

fn test_stated_frame(emitter: *const Emitter, before: u32) bool {
    assert(before < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (bind.sequence_grouped(emitter)) {
        if (test_stated_sequence(emitter, before)) return true;
    }

    if (emitter.depth == 0) return false;
    if (before != line.frame(emitter).open) return false;
    return split.headed(emitter, before);
}

fn test_stated_sequence(emitter: *const Emitter, before: u32) bool {
    assert(before < emitter.count);
    assert(emitter.depth > 0);

    if (emitter.tokens[before].is_punctuation(.comma)) return true;
    return before == line.frame(emitter).open;
}

fn value_headed(emitter: *const Emitter, position: u32) ?struct { u32, core.Wrap } {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const end = value_branch(emitter, position) orelse return null;
    const held = emit.back_of(emitter, end) orelse return null;
    const found = tern.value_tested(emitter, position, held) orelse return null;

    assert(held < end);

    if (found[0] >= held) return null;
    return found;
}

fn value_branched(emitter: *const Emitter, position: u32) ?struct { u32, core.Wrap } {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const end = value_branch(emitter, position) orelse return null;
    const tail = emit.back_of(emitter, end) orelse return null;
    const found = tern.value_tested(emitter, position, tail) orelse return null;
    const colon = commenting.back(emitter, position) orelse return null;

    assert(tail < end);

    const enclosing = bind.enclosing_open(emitter, colon) orelse 0;
    const question = tern.ternary_question(emitter, colon, enclosing) orelse return found;

    return tern.branch_wrap(emitter, question, tail, found);
}

pub fn value_branch(emitter: *const Emitter, position: u32) ?u32 {
    assert(position <= emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var depth: u32 = 0;
    var owed: u32 = 0;
    var scan = position;

    while (scan < emitter.count) {
        if (tmpl.spanned_unit(emitter, scan)) |end| {
            assert(end >= scan);

            scan = end + 1;

            continue;
        }

        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            if (depth == 0) return scan;

            depth -= 1;
        } else if (depth == 0) {
            if (emitter.tokens[scan].is_punctuation(.comma)) return scan;
            if (emitter.tokens[scan].is_punctuation(.semicolon)) return scan;

            owed = value_branch_owed(emitter, scan, owed) orelse return scan;
        } else {}

        scan += 1;
    }

    return null;
}

fn value_branch_owed(emitter: *const Emitter, scan: u32, owed: u32) ?u32 {
    assert(scan < emitter.count);
    assert(owed <= emitter.count);

    const token = emitter.tokens[scan];

    if (walk.text_is(token.text(emitter.source), "?")) {
        if (tern.optional(emitter, scan)) return owed;
        assert(owed + 1 < std.math.maxInt(u32));

        return owed + 1;
    }

    if (!token.is_punctuation(.colon)) return owed;
    if (!tern.ternary(emitter, scan)) return owed;
    if (owed == 0) return null;
    assert(owed - 1 < std.math.maxInt(u32));

    return owed - 1;
}

fn argued_commented(emitter: *const Emitter, frame: *const core.Frame) bool {
    assert(frame.open <= frame.close);
    assert(frame.close < emitter.count);

    for (frame.open..frame.close) |index| {
        const scan: u32 = @intCast(index);
        if (emitter.tokens[scan].kind != .comment) continue;
        if (operator_trailed(emitter, scan)) continue;
        if (comment_inline(emitter, scan)) continue;
        if (operator_led_comment(emitter, scan)) continue;
        if (argument_led_comment(emitter, scan, frame)) continue;
        return true;
    }

    return false;
}

fn comment_inline(emitter: *const Emitter, comment: u32) bool {
    assert(comment < emitter.count);
    assert(emitter.tokens[comment].kind == .comment);

    const text = emitter.tokens[comment].text(emitter.source);
    if (!std.mem.startsWith(u8, text, "/*")) return false;
    if (std.mem.findScalar(u8, text, '\n') != null) return false;

    const before = emit.back_of(emitter, comment) orelse return false;
    if (body.parts_at(emitter, before, comment)) return false;

    const after = emit.ahead_of(emitter, comment) orelse return false;
    return !body.parts_at(emitter, comment, after);
}

fn operator_trailed(emitter: *const Emitter, comment: u32) bool {
    assert(comment < emitter.count);
    assert(emitter.tokens[comment].kind == .comment);

    const led = if (line.coding(emitter, comment)) |ahead|
        span.wrapping_operator(emitter, ahead)
    else
        false;

    if (led) return false;
    if (!std.mem.startsWith(u8, emitter.tokens[comment].text(emitter.source), "//")) return false;

    const held = emit.back_of(emitter, comment) orelse return false;
    const kind = emitter.tokens[held].kind;

    assert(held < comment);

    if (kind == .comment) return false;
    if (walk.is_open(kind)) return false;
    return !body.parts_at(emitter, held, comment);
}

pub fn value_joined(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    if (!emitter.policy.assign_lines) return false;

    const assigned = emitter.tokens[prior].is_punctuation(.assign) or
        compound_assign(emitter, prior);

    if (!assigned) return false;
    if (emitter.line_first > prior) return false;

    if (emitter.tokens[position].kind == .comment) {
        if (body.parts_at(emitter, prior, position)) return false;
    }

    const tail = value_lead(emitter, position) orelse return false;
    const width = span.printed_columns(emitter, emitter.line_first, tail);

    assert(tail >= position);

    return emitter.printed * emitter.options.indent_width + width <= emitter.options.line_width;
}

fn value_lead(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const end = call.valued_semicolon(emitter, position) orelse return null;
    const stop = emit.back_of(emitter, end) orelse return null;
    const question = valued_question(emitter, position, stop) orelse return null;
    const tail = emit.back_of(emitter, question) orelse return null;
    if (tail < position) return null;
    if (valued_binary(emitter, position, tail)) return null;

    for (position..question) |index| {
        const scan: u32 = @intCast(index);
        if (!walk.is_open(emitter.tokens[scan].kind)) continue;
        if (value_lead_empty(emitter, scan)) continue;
        assert(scan <= emitter.count);

        return scan;
    }

    return tail;
}

fn value_lead_empty(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(walk.is_open(emitter.tokens[open].kind));

    const after = emit.ahead_of(emitter, open);
    const close = join.closing_of(emitter, open);
    const held = after orelse return close == null;
    const shut = close orelse return false;

    return held == shut;
}

fn valued_question(emitter: *const Emitter, head: u32, stop: u32) ?u32 {
    assert(stop < emitter.count);
    assert(emitter.count == emitter.tokens.len);
    assert(head < emitter.count);

    var depth: u32 = 0;
    var scan = head;

    while (scan <= stop) {
        if (valued_spanned(emitter, scan)) |end| {
            assert(end >= scan);

            scan = end + 1;

            continue;
        }

        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (valued_questioned(emitter, scan)) return scan;
        } else {}

        scan += 1;
    }

    return null;
}

fn valued_questioned(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!walk.text_is(emitter.tokens[scan].text(emitter.source), "?")) return false;
    return !tern.optional(emitter, scan);
}

fn valued_spanned(emitter: *const Emitter, scan: u32) ?u32 {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (call.spanned_body(emitter, scan)) |end| return end;
    return tmpl.spanned_unit(emitter, scan);
}

fn valued_object_in(emitter: *const Emitter, frame: *const core.Frame) bool {
    assert(frame.open < emitter.count);
    assert(frame.open <= frame.close);

    if (frame.kind != .block_start) return false;

    const before = emit.word_before(emitter, frame.open) orelse return false;

    assert(before < frame.open);

    return wide.objected(emitter, before, emitter.tokens[before]);
}

fn valued_element_in(emitter: *const Emitter, head: u32, close: u32) ?u32 {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);
    assert(head < emitter.count);

    var depth: u32 = 0;
    var scan = head;

    while (scan < close) {
        if (tmpl.spanned_unit(emitter, scan)) |end| {
            assert(end >= scan);

            scan = end + 1;

            continue;
        }

        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            if (depth == 0) return null;

            depth -= 1;
        } else if (depth == 0) {
            if (emitter.tokens[scan].is_punctuation(.comma)) return scan;
        } else {}

        scan += 1;
    }

    if (close > head) return close;
    return null;
}

fn arrow_chain_at(emitter: *const Emitter, position: u32) ?struct { u32, u32, u32, bool } {
    assert(position < emitter.count);

    if (!emitter.policy.chain_simples) return null;
    if (emitter.arrow_chain.end != std.math.maxInt(u32)) return null;
    if (!walk.text_is(emitter.tokens[position].text(emitter.source), "=")) return null;
    if (emitter.typed) return null;
    if (emit.roled(emitter, position, brace.role_type)) return null;
    if (list.spreads(emitter)) return null;

    if (emitter.depth > 0) {
        if (line.frame(emitter).kind != .block_start) return null;
    }

    const walked = arrow_chain_walk(emitter, position) orelse return null;
    const arrow = walked[0];
    const end = call.valued_semicolon(emitter, walked[2]) orelse return null;

    assert(position < arrow);

    if (!emitter.tokens[end].is_punctuation(.semicolon)) return null;
    if (arrow_chain_commented(emitter, position, arrow)) return null;
    return .{ arrow, walked[1], end, walked[3] };
}

fn arrow_chain_walk(emitter: *const Emitter, position: u32) ?struct { u32, u32, u32, bool } {
    assert(position < emitter.count);
    assert(emitter.policy.chain_simples);

    var arrows: u32 = 0;
    var expand = false;
    var start = emit.ahead_of(emitter, position) orelse return null;
    var tail: ?struct { u32, u32 } = null;

    for (0..arrow_chain_max) |_| {
        const signature = chain_signature(emitter, start) orelse break;
        const arrow = signature[0];

        arrows += 1;
        expand = expand or signature[1];
        tail = .{ arrow, emit.back_of(emitter, arrow) orelse return null };
        start = emit.ahead_of(emitter, arrow) orelse return null;
    }

    assert(arrows <= arrow_chain_max);

    if (arrows <= 1) return null;

    const held = tail orelse return null;
    return .{ held[0], held[1], start, expand };
}

fn arrow_chain_commented(emitter: *const Emitter, position: u32, arrow: u32) bool {
    assert(position < arrow);
    assert(arrow < emitter.count);

    for (position..arrow) |scan| {
        if (emitter.tokens[scan].kind == .comment) return true;
    }

    return false;
}

fn arrow_property_chain_at(
    emitter: *const Emitter,
    position: u32,
) ?struct { u32, u32, u32, bool } {
    assert(position < emitter.count);

    if (!emitter.policy.chain_simples) return null;
    if (emitter.arrow_chain.end != std.math.maxInt(u32)) return null;
    if (!emitter.tokens[position].is_punctuation(.colon)) return null;
    if (emitter.depth == 0) return null;
    if (emit.roled(emitter, position, brace.role_type)) return null;
    if (tern.ternary(emitter, position)) return null;

    const frame = line.frame(emitter);
    if (frame.kind != .block_start) return null;
    if (frame.bodied) return null;
    if (frame.spread == null) return null;

    const named = emit.back_of(emitter, position) orelse return null;
    if (!arrow_property_keyed(emitter, named, frame.open)) return null;

    const walked = arrow_chain_walk(emitter, position) orelse return null;

    assert(position < walked[0]);

    if (arrow_chain_commented(emitter, position, walked[0])) return null;
    return arrow_property_chain_end(emitter, walked, frame.close);
}

fn arrow_property_keyed(emitter: *const Emitter, named: u32, open: u32) bool {
    assert(named < emitter.count);
    assert(open < emitter.count);

    switch (emitter.tokens[named].kind) {
        .identifier, .string, .keyword => {},
        else => return false,
    }

    const held = emit.back_of(emitter, named) orelse return false;
    if (held == open) return true;
    return emitter.tokens[held].is_punctuation(.comma);
}

fn arrow_property_chain_end(
    emitter: *const Emitter,
    walked: struct { u32, u32, u32, bool },
    close: u32,
) ?struct { u32, u32, u32, bool } {
    assert(walked[0] < walked[2]);
    assert(walked[2] < emitter.count);
    assert(close < emitter.count);

    const start = walked[2];
    var depth: u32 = 0;
    var scan = start;

    while (scan < close) {
        assert(scan < emitter.count);

        const token = emitter.tokens[scan];
        const opens = walk.is_open(token.kind) or walk.substituting(emitter.source, token);
        const closes = walk.is_close(token.kind);

        if (opens) {
            depth += 1;
        } else if (closes) {
            if (depth == 0) return null;

            depth -= 1;
        } else if (depth == 0) {
            if (token.is_punctuation(.comma)) break;
        } else {}

        scan += 1;
    }

    const last = emit.back_of(emitter, scan) orelse return null;
    if (last < start) return null;
    if (scan == close) return null;
    if (emitter.tokens[last].kind == .comment) return null;

    const blocked = emitter.tokens[start].kind == .block_start and
        join.closing_of(emitter, start) == last;

    const end = if (blocked) last else scan;
    return .{ walked[0], walked[1], end, walked[3] };
}

pub fn callee_chain_level(emitter: *const Emitter, leading: u32) ?u32 {
    assert(leading < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.chain_simples) return null;
    if (emitter.depth == 0) return null;

    const arrow = emit.back_of(emitter, leading) orelse return null;
    if (!walk.text_is(emitter.tokens[arrow].text(emitter.source), "=>")) return null;
    if (chain_signature(emitter, leading) == null) return null;

    const head = callee_chain_head(emitter) orelse return null;
    if (head >= leading) return null;
    return lead.leveled_at(emitter, head);
}

fn callee_chain_head(emitter: *const Emitter) ?u32 {
    assert(emitter.depth > 0);
    assert(emitter.depth <= brace.nest_depth_max);

    const frame = line.frame(emitter);
    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return null;

    const called = emit.ahead_of(emitter, frame.close) orelse return null;
    if (!emitter.tokens[called].is_punctuation(.paren_open)) return null;

    const head = emit.ahead_of(emitter, frame.open) orelse return null;
    if (chain_signature(emitter, head) == null) return null;
    return head;
}

pub fn callee_chain_tail(emitter: *const Emitter, arrow: u32) bool {
    assert(arrow < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.chain_simples) return false;
    if (emitter.depth == 0) return false;

    const frame = line.frame(emitter);
    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return false;
    if (emitter.line_first <= frame.open) return false;

    const called = emit.ahead_of(emitter, frame.close) orelse return false;
    if (!emitter.tokens[called].is_punctuation(.paren_open)) return false;

    const body_head = emit.ahead_of(emitter, arrow) orelse return false;

    switch (emitter.tokens[body_head].kind) {
        .block_start => return false,
        .punctuation => |held| switch (held) {
            .bracket_open, .paren_open => return false,
            else => {},
        },
        else => {},
    }

    if (emitter.roles[body_head] & brace.role_jsx != 0) return false;

    var start = emit.ahead_of(emitter, frame.open) orelse return false;
    var arrows: u32 = 0;
    var tail: u32 = 0;

    for (0..arrow_chain_max) |_| {
        const signature = chain_signature(emitter, start) orelse break;

        arrows += 1;
        tail = signature[0];
        start = emit.ahead_of(emitter, tail) orelse return false;
    }

    return arrows >= 2 and tail == arrow;
}

fn chain_signature(emitter: *const Emitter, start: u32) ?struct { u32, bool } {
    assert(start < emitter.count);
    assert(emitter.policy.chain_simples);

    var head = start;
    var broken = false;

    if (walk.text_is(emitter.tokens[head].text(emitter.source), "async")) {
        head = emit.ahead_of(emitter, head) orelse return null;
    }

    if (walk.text_is(emitter.tokens[head].text(emitter.source), "<")) {
        const shut = join.angle_close(emitter, head) orelse return null;

        head = emit.ahead_of(emitter, shut) orelse return null;
        broken = true;
    }

    if (emitter.tokens[head].kind == .identifier) {
        const arrow = emit.ahead_of(emitter, head) orelse return null;
        if (!walk.text_is(emitter.tokens[arrow].text(emitter.source), "=>")) return null;
        return .{ arrow, broken };
    }

    if (!emitter.tokens[head].is_punctuation(.paren_open)) return null;

    const close = join.closing_of(emitter, head) orelse return null;
    const after = emit.ahead_of(emitter, close) orelse return null;
    const simple = params_simple(emitter, head, close);

    if (walk.text_is(emitter.tokens[after].text(emitter.source), "=>")) {
        return .{ after, broken or !simple };
    }

    if (!emitter.tokens[after].is_punctuation(.colon)) return null;
    return chain_signature_typed(emitter, head, after, broken or !simple);
}

fn chain_signature_typed(
    emitter: *const Emitter,
    head: u32,
    after: u32,
    broken: bool,
) ?struct { u32, bool } {
    assert(head < after);
    assert(after < emitter.count);

    const close = join.closing_of(emitter, head) orelse return null;
    const angles = emitter.brackets.angles_at(after);
    const params = emit.ahead_of(emitter, head) != close;
    var depth: u32 = 0;
    var scan = after;

    for (0..core.define_scan_max) |_| {
        scan = emit.ahead_of(emitter, scan) orelse return null;

        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            if (depth == 0) return null;

            depth -= 1;
        } else if (depth == 0) {
            const arrow = walk.text_is(emitter.tokens[scan].text(emitter.source), "=>") and
                !chain_signature_typed_arrow(emitter, scan);

            if (arrow) return .{ scan, broken or params };
            if (chain_signature_stops(emitter, scan, angles)) return null;
        } else {}
    }

    return null;
}

fn chain_signature_typed_arrow(emitter: *const Emitter, arrow: u32) bool {
    assert(arrow < emitter.count);
    assert(emitter.policy.chain_simples);

    const after = emit.ahead_of(emitter, arrow) orelse return false;
    return emit.roled(emitter, after, brace.role_type);
}

fn chain_signature_stops(emitter: *const Emitter, scan: u32, angles: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.policy.chain_simples);

    if (emitter.brackets.angles_at(scan) > angles) return false;
    if (emitter.tokens[scan].is_punctuation(.comma)) return true;
    return emitter.tokens[scan].is_punctuation(.semicolon);
}

fn params_simple(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var leading = true;

    for (open + 1..close) |index| {
        const token = emitter.tokens[index];
        const text = token.text(emitter.source);

        if (token.kind == .newline) continue;
        if (token.length == 0) continue;

        const guarded = leading and depth == 0;

        if (guarded) {
            if (token.kind != .identifier) return false;
            if (walk.text_is(text, "this")) return false;
        }

        leading = false;

        if (walk.is_open(token.kind)) {
            depth += 1;
        } else if (walk.is_close(token.kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (token.is_punctuation(.comma)) {
                leading = true;
            } else if (walk.text_is(text, "=")) {
                return false;
            } else {}
        } else {}
    }

    return true;
}

pub fn arrow_chains(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const chain = emitter.arrow_chain;
    if (chain.end == std.math.maxInt(u32)) return arrow_chain_opened(emitter, position);

    assert(emitter.policy.chain_simples);

    if (position == chain.close) {
        try emitter.document.push(.group_close);
        try emitter.document.push(.group_close);

        return;
    }

    if (position == chain.end) {
        emitter.arrow_chain = core.ArrowChain.empty;

        try line.closes_broken(emitter);
        try emitter.document.push(.group_close);

        return;
    }

    if (position >= chain.tail) return;
    if (emitter.depth != chain.depth) return;
    if (!walk.text_is(emitter.tokens[position].text(emitter.source), "=>")) return;

    if (chain.expand) {
        try emitter.document.push(.hard_line);
    } else {
        try emitter.document.push(.line);
    }
}

fn arrow_chain_opened(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.arrow_chain.end == std.math.maxInt(u32));

    const found = arrow_chain_at(emitter, position) orelse
        arrow_property_chain_at(emitter, position) orelse return;

    assert(emitter.policy.chain_simples);
    assert(position < found[0]);

    emitter.arrow_chain = .{
        .tail = found[0],
        .close = found[1],
        .end = found[2],
        .depth = emitter.depth,
        .expand = found[3],
    };

    try emitter.document.push(.group_open);
    try emitter.document.push(.group_open);
    try line.opens_broken(emitter);
    try emitter.document.push(.line);
    try emitter.document.push(.group_open);
}

pub fn arrow_chain_overdue(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const end = emitter.arrow_chain.end;
    if (end == std.math.maxInt(u32)) return;
    if (end >= position) return;

    emitter.arrow_chain = core.ArrowChain.empty;

    try line.closes_broken(emitter);
    try emitter.document.push(.group_close);
}

pub fn property_chain_closed(emitter: *Emitter, start: u32, form: core.Wrap) error{Overflow}!void {
    assert(start < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.wrapped[emitter.wraps_owed].wrap == form);

    const end = emitter.arrow_chain.end;

    if (!chain_tailed(emitter, start, form)) return;
    if (end == std.math.maxInt(u32)) return;
    if (!emitter.tokens[end].is_punctuation(.comma)) return;

    emitter.arrow_chain = core.ArrowChain.empty;

    try line.closes_broken(emitter);
    try emitter.document.push(.group_close);
}

pub fn arrow_chain_joined(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const chain = emitter.arrow_chain;
    if (chain.end == std.math.maxInt(u32)) return false;
    if (position > chain.tail) return false;
    return emitter.depth == chain.depth;
}

fn word_listed(words: []const []const u8, word: []const u8) bool {
    assert(words.len > 0);
    assert(word.len > 0);

    for (words) |listed| {
        if (walk.text_eql(listed, word)) return true;
    }

    return false;
}

pub fn operator_led_comment(emitter: *const Emitter, comment: u32) bool {
    assert(comment < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!line_comment(emitter, comment)) return false;

    const before = comment_run_end(emitter, comment, false) orelse return false;
    const after = comment_run_end(emitter, comment, true);

    if (!span.wrapping_operator(emitter, before)) return false;

    const held = after orelse return false;
    return emitter.tokens[held].kind != .comment;
}

fn argument_led_comment(emitter: *const Emitter, comment: u32, frame: *const core.Frame) bool {
    assert(comment < emitter.count);
    assert(frame.open <= comment);

    if (!line_comment(emitter, comment)) return false;

    const before = comment_run_end(emitter, comment, false) orelse return false;
    if (before != frame.open) return false;

    const after = comment_run_end(emitter, comment, true) orelse return false;
    return after < frame.close;
}

pub fn line_comment(emitter: *const Emitter, comment: u32) bool {
    assert(comment < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[comment];
    if (token.kind != .comment) return false;
    return std.mem.startsWith(u8, token.text(emitter.source), "//");
}

fn comment_run_end(emitter: *const Emitter, comment: u32, forward: bool) ?u32 {
    assert(comment < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = if (forward) emit.ahead_of(emitter, comment) else emit.back_of(emitter, comment);

    for (0..comment_run_max) |_| {
        const held = scan orelse break;
        if (!line_comment(emitter, held)) break;

        scan = if (forward) emit.ahead_of(emitter, held) else emit.back_of(emitter, held);
    }

    return scan;
}

fn operator_trailed_comment(emitter: *const Emitter, comment: u32) bool {
    assert(comment < emitter.count);
    assert(emitter.tokens[comment].kind == .comment);

    if (!std.mem.startsWith(u8, emitter.tokens[comment].text(emitter.source), "/*")) return false;

    const before = emit.back_of(emitter, comment) orelse return false;
    if (emitter.tokens[before].kind == .comment) return false;
    if (body.parts_at(emitter, before, comment)) return false;

    const after = emit.ahead_of(emitter, comment) orelse return false;
    if (!span.wrapping_operator(emitter, after)) return false;
    return !body.parts_at(emitter, comment, after);
}

fn cast_led_comment(emitter: *const Emitter, comment: u32) bool {
    assert(comment < emitter.count);
    assert(emitter.tokens[comment].kind == .comment);

    const after = emit.ahead_of(emitter, comment) orelse return false;
    if (!emitter.tokens[after].is_punctuation(.paren_open)) return false;
    if (body.parts_at(emitter, comment, after)) return false;
    return sole.cast_commented(emitter, after);
}

fn value_grouped(
    emitter: *const Emitter,
    position: u32,
    close: u32,
    spread: bool,
) ?struct { u32, core.Wrap } {
    assert(position < emitter.count);
    assert(close < emitter.count);

    const stop = emit.back_of(emitter, close) orelse return null;
    if (stop <= position) return null;
    if (!valued_binary(emitter, position, stop)) return null;

    for (position..stop + 1) |index| {
        const scan: u32 = @intCast(index);
        if (emitter.tokens[scan].kind != .comment) continue;
        if (operator_led_comment(emitter, scan)) continue;
        if (operator_trailed_comment(emitter, scan)) continue;
        if (cast_led_comment(emitter, scan)) continue;
        return null;
    }

    const branched = if (emit.back_of(emitter, position)) |open|
        branch_parenthesized(emitter, open)
    else
        false;

    const tested = value_grouped_tested(emitter, position, close);

    if (spread) return .{ stop, .paired };
    if (branched) return .{ stop, .paired };
    if (tested) return .{ stop, .paired };
    return .{ stop, .argued };
}

fn value_grouped_tested(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position < close);
    assert(close < emitter.count);

    const question = emit.ahead_of(emitter, close) orelse return false;
    if (!walk.text_is(emitter.tokens[question].text(emitter.source), "?")) return false;
    if (tern.optional(emitter, question)) return false;

    const head = tern.ternary_head(emitter, question);
    const before = emit.back_of(emitter, position);

    if (head) |held| {
        const seat = before orelse return false;
        if (held != seat) return false;
    } else {
        if (before != null) return false;
    }

    return !tern.ternary_indents(emitter, question);
}

pub fn grouped_flat(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.spread_values) return false;
    if (emitter.depth == 0) return false;

    const frame = line.frame(emitter);
    if (frame.spread == null) return false;
    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return false;
    if (emit.back_of(emitter, position) != frame.open) return false;
    if (list.calling(emitter, frame.open)) return false;
    if (split.headed(emitter, frame.open)) return false;

    const unary = grouped_flat_unary(emitter, frame.open);

    const membered = if (emit.ahead_of(emitter, frame.close)) |held|
        grouped_flat_membered(emitter, held)
    else
        false;

    if (!unary) {
        if (!membered) return false;
    }

    const stop = emit.back_of(emitter, frame.close) orelse return false;
    return !run_soled(emitter, position, stop);
}

fn grouped_flat_unary(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.back_of(emitter, open) orelse return false;
    const text = emitter.tokens[held].text(emitter.source);
    if (word_listed(&flat_unaries, text)) return true;

    const signed = walk.text_is(text, "-") or walk.text_is(text, "+");
    if (!signed) return false;

    const before = emit.back_of(emitter, held) orelse return true;
    return !emitter.tokens[before].ends_a_value();
}

fn grouped_flat_membered(emitter: *const Emitter, held: u32) bool {
    assert(held < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emit.is_dot(emitter, held)) return true;
    if (emitter.tokens[held].is_punctuation(.bracket_open)) return true;
    return emitter.tokens[held].is_punctuation(.paren_open);
}

fn run_soled(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head < emitter.count);
    assert(stop < emitter.count);

    if (head > stop) return false;

    var ranks: [binary_operator_max]struct { u32, u32 } = @splat(.{ 0, 0 });
    const ranked = span.operand_ranked(emitter, head, stop, &ranks) orelse return false;

    assert(ranked <= binary_operator_max);

    if (ranked == 0) return false;

    var floor: u32 = std.math.maxInt(u32);

    for (ranks[0..ranked]) |rank| floor = @min(floor, rank[1]);

    var floored: u32 = 0;
    var operator: u32 = 0;

    for (ranks[0..ranked]) |rank| {
        if (rank[1] != floor) continue;

        if (floored == 0) operator = rank[0];

        floored += 1;
    }

    if (floored != 1) return false;

    const logical = floor <= logical_level_max;

    for (ranks[0..ranked]) |rank| {
        if (rank[0] == operator) continue;
        if ((rank[1] <= logical_level_max) == logical) return false;
    }

    if (wrap.operand_side_run(emitter, head, operator, logical)) return false;
    return !wrap.operand_side_run(emitter, operator, stop + 1, logical);
}

pub fn value_owned(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (!emitter.policy.spread_values) return false;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;
    if (list.calling(emitter, open)) return false;
    if (split.headed(emitter, open)) return false;

    const given = if (emit.back_of(emitter, open)) |before|
        !value_owned_jumped(emitter, before)
    else
        true;

    const leading = emit.ahead_of(emitter, open) orelse return false;
    if (leading >= close) return false;

    const stop = emit.back_of(emitter, close) orelse return false;

    if (!given) return false;
    if (stop <= leading) return false;
    return valued_binary(emitter, leading, stop);
}

fn value_owned_jumped(emitter: *const Emitter, before: u32) bool {
    assert(before < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const text = emitter.tokens[before].text(emitter.source);
    if (walk.text_is(text, "return")) return true;
    return walk.text_is(text, "throw");
}

pub fn parenthesized(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.arrow_parens) return null;
    if (!emitter.tokens[position].is_punctuation(.paren_open)) return null;
    if (unite.arrow_valued(emitter, position)) return null;

    const held = emit.ahead_of(emitter, position) orelse return null;
    if (emitter.tokens[held].kind != .identifier) return null;

    var close = emit.ahead_of(emitter, held) orelse return null;

    if (emitter.tokens[close].is_punctuation(.comma)) {
        close = emit.ahead_of(emitter, close) orelse return null;
    }

    if (!emitter.tokens[close].is_punctuation(.paren_close)) return null;

    const arrow = emit.ahead_of(emitter, close) orelse return null;

    assert(arrow > close);

    if (!walk.text_is(emitter.tokens[arrow].text(emitter.source), "=>")) return null;
    return close;
}

pub fn trailed_already(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const comment_at = emit.word_before(emitter, close) orelse return false;
    if (emitter.tokens[comment_at].kind != .comment) return false;

    const held = commenting.back(emitter, comment_at) orelse return false;
    const head = comment_head(emitter, comment_at);
    if (body.parts_at(emitter, held, head)) return true;
    if (trailed_comma(emitter, held)) return true;
    if (emitter.tokens[held].is_punctuation(.comma)) return true;
    if (emitter.tokens[held].is_punctuation(.semicolon)) return true;

    for (head..comment_at) |index| {
        const scan: u32 = @intCast(index);
        if (emitter.tokens[scan].kind != .comment) continue;
        if (trailed_comma(emitter, scan)) return true;
    }

    return false;
}

pub fn trailed_standing(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const comment_at = emit.word_before(emitter, close) orelse return false;
    if (emitter.tokens[comment_at].kind != .comment) return false;

    const held = commenting.back(emitter, comment_at) orelse return false;
    return body.parts_at(emitter, held, comment_head(emitter, comment_at));
}

fn comment_head(emitter: *const Emitter, comment_at: u32) u32 {
    assert(comment_at < emitter.count);
    assert(emitter.tokens[comment_at].kind == .comment);

    var head = comment_at;

    while (emit.word_before(emitter, head)) |above| {
        assert(above < head);

        if (emitter.tokens[above].kind != .comment) break;

        head = above;
    }

    assert(emitter.tokens[head].kind == .comment);

    return head;
}

pub fn bodied_of(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var angles: u32 = 0;
    var depth: u32 = 0;

    for (position + 1..emitter.count) |index| {
        const scan: u32 = @intCast(index);
        const token = emitter.tokens[scan];
        const text = token.text(emitter.source);
        const settled = depth == 0 and angles == 0;

        if (token.kind == .block_start) {
            if (settled) return emit.closing(emitter, scan);
        }

        if (depth == 0) {
            if (walk.text_is(text, "<")) {
                angles += 1;
            } else if (angles > 0) {
                if (all_greater(text)) angles -|= @intCast(text.len);
            } else {}
        }

        if (walk.is_open(token.kind)) {
            depth += 1;
        } else if (walk.is_close(token.kind)) {
            if (depth == 0) return null;

            depth -= 1;
        } else if (token.is_punctuation(.semicolon)) {
            if (settled) return null;
        } else {}
    }

    return null;
}

pub fn alias_refused(emitter: *const Emitter, equals: u32) bool {
    assert(equals < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!aliased(emitter, equals)) return false;
    if (!alias_complex_params(emitter, equals)) return false;
    return alias_broken_value(emitter, equals) == null;
}

pub fn alias_conditional(emitter: *const Emitter, equals: u32) ?u32 {
    assert(equals < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const head = emit.ahead_of(emitter, equals) orelse return null;
    const end = call.valued_semicolon(emitter, head) orelse return null;
    const angles = emitter.brackets.angles_at(head);

    assert(end < emitter.count);

    var depth: u32 = 0;
    var extended: ?u32 = null;
    var scan = head;

    while (scan < end) : (scan += 1) {
        const token = emitter.tokens[scan];
        const text = token.text(emitter.source);
        const argued = emitter.brackets.angles_at(scan) > angles;
        const opened = walk.is_open(token.kind) or token.kind == .block_start;
        const closed = walk.is_close(token.kind) or token.kind == .block_end;
        const nested = depth > 0 or argued;

        if (opened) {
            depth += 1;
        } else if (closed) {
            depth -|= 1;
        } else if (nested) {} else {
            const questioned = walk.text_is(text, "?") and !tern.optional(emitter, scan);

            if (walk.text_is(text, "extends")) extended = extended orelse scan;
            if (questioned) return alias_conditional_end(emitter, head, extended, scan, end);
        }
    }

    return null;
}

fn alias_conditional_end(
    emitter: *const Emitter,
    head: u32,
    extended: ?u32,
    question: u32,
    end: u32,
) ?u32 {
    assert(head <= question);
    assert(question < end);
    if (extended) |held| assert(held < emitter.count);

    const extends = extended orelse return null;

    assert(extends < question);

    if (extends <= head) return null;

    const after = emit.ahead_of(emitter, extends) orelse return null;

    const generic = alias_generic(emitter, head, extends) or
        alias_generic(emitter, after, question);

    if (!generic) return null;
    return end;
}

fn alias_generic(emitter: *const Emitter, start: u32, stop: u32) bool {
    assert(start <= stop);
    assert(stop < emitter.count);

    var from = start;
    var to = stop;

    for (0..alias_paren_max) |_| {
        if (from >= to) return false;
        if (!emitter.tokens[from].is_punctuation(.paren_open)) break;

        const close = join.closing_of(emitter, from) orelse return false;
        const after = emit.ahead_of(emitter, close) orelse return false;
        if (after != to) break;

        from = emit.ahead_of(emitter, from) orelse return false;
        to = close;
    }

    if (from >= to) return false;
    if (walk.text_is(emitter.tokens[from].text(emitter.source), "<")) return true;
    return join.generic_reference(emitter, from, to);
}

pub fn alias_parted(emitter: *const Emitter, equals: u32, opens: u32, level: u32) ?u32 {
    assert(equals < emitter.count);
    assert(opens < emitter.count);

    if (!walk.text_is(emitter.tokens[equals].text(emitter.source), "=")) return null;
    assert(level < std.math.maxInt(u32));

    const close = emit.back_of(emitter, equals) orelse return null;
    if (!walk.text_is(emitter.tokens[close].text(emitter.source), ">")) return null;

    const open = join.angle_head(emitter, close) orelse return null;
    const name = emit.back_of(emitter, open) orelse return null;
    const word = emit.word_before(emitter, name) orelse return null;
    if (!line.word_is(emitter, word, &.{"type"})) return null;

    const indented = level * emitter.options.indent_width;
    const columns = indented + span.printed_columns(emitter, opens, equals);
    if (columns > emitter.options.line_width) return close;
    if (alias_complex_params(emitter, equals)) return close;
    return null;
}

fn annotation_complex(emitter: *const Emitter, equals: u32) bool {
    assert(equals < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const colon = annotation_colon(emitter, equals) orelse return false;

    assert(colon < equals);

    if (!annotation_declared(emitter, colon)) return false;

    var head = emit.ahead_of(emitter, colon);

    for (0..emitter.count) |_| {
        const at = head orelse break;
        const dotted = emitter.tokens[at].kind == .identifier or emit.is_dot(emitter, at);
        if (!dotted) break;

        head = emit.ahead_of(emitter, at);
    }

    const open = head orelse return false;
    if (!walk.text_is(emitter.tokens[open].text(emitter.source), "<")) return false;
    return annotation_arguments_complex(emitter, open, equals);
}

fn annotation_declared(emitter: *const Emitter, colon: u32) bool {
    assert(colon < emitter.count);
    assert(emitter.tokens[colon].is_punctuation(.colon));

    const name = emit.back_of(emitter, colon) orelse return false;
    if (emitter.tokens[name].kind != .identifier) return false;

    const word = emit.back_of(emitter, name) orelse return false;
    const text = emitter.tokens[word].text(emitter.source);
    if (walk.text_is(text, "const")) return true;
    if (walk.text_is(text, "let")) return true;
    return walk.text_is(text, "var");
}

fn annotation_colon(emitter: *const Emitter, equals: u32) ?u32 {
    assert(equals < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = equals;
    var angles: u32 = 0;

    for (0..annotation_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return null;
        const token = emitter.tokens[held];
        const text = token.text(emitter.source);

        if (all_greater(text)) {
            angles += @intCast(text.len);
        } else if (walk.text_is(text, "<")) {
            angles -|= 1;
        } else if (angles == 0) {
            const stopped = token.is_punctuation(.semicolon) or token.is_punctuation(.comma) or
                token.kind == .block_start or token.kind == .block_end;

            if (token.is_punctuation(.colon)) return held;
            if (stopped) return null;
        } else {}

        scan = held;
    }

    return null;
}

fn annotation_arguments_complex(emitter: *const Emitter, open: u32, equals: u32) bool {
    assert(open < equals);
    assert(equals < emitter.count);

    var held: AnnotationScan = .{
        .argument = .fresh,
        .arguments = 1,
        .brackets = 0,
        .complex = false,
        .depth = 1,
        .start = emit.ahead_of(emitter, open),
    };

    var scan = open;

    for (0..annotation_scan_max) |_| {
        const at = emit.ahead_of(emitter, scan) orelse return false;
        if (at >= equals) return false;

        const token = emitter.tokens[at];
        const text = token.text(emitter.source);
        const opened = walk.is_open(token.kind) or token.kind == .block_start;
        const closed = walk.is_close(token.kind) or token.kind == .block_end;
        const level = held.depth == 1 and held.brackets == 0;
        const level_named = level and held.argument == .named;

        if (level_named) {
            const separated = token.is_punctuation(.comma) or all_greater(text);

            if (!separated) held.argument = .mixed;
        }

        if (opened) {
            held.brackets += 1;
        } else if (closed) {
            held.brackets -|= 1;
        } else if (held.brackets == 0) {
            if (annotation_arguments_step(emitter, &held, at, equals)) |complex| return complex;
        } else {}

        scan = at;
    }

    return false;
}

fn annotation_arguments_step(
    emitter: *const Emitter,
    held: *AnnotationScan,
    at: u32,
    equals: u32,
) ?bool {
    assert(at < equals);
    assert(held.brackets == 0);

    const token = emitter.tokens[at];
    const text = token.text(emitter.source);

    if (walk.text_is(text, "<")) {
        const started = held.depth == 1 and held.start != null;

        if (started) {
            if (annotation_named(emitter, held.start.?, at)) held.argument = .opening;
        }

        held.depth += 1;
    } else if (all_greater(text)) {
        const shut: u32 = @intCast(text.len);
        const after = emit.ahead_of(emitter, at);
        const named = held.argument == .named or held.argument == .opening;

        if (shut >= held.depth) {
            const ended = after != null and after.? == equals;
            return held.arguments >= 2 and (held.complex or named) and ended;
        }

        held.depth -= shut;

        if (held.depth == 1) {
            if (held.argument == .opening) held.argument = .named;
        }
    } else if (held.depth == 1) {
        if (token.is_punctuation(.comma)) {
            held.complex = held.complex or held.argument == .named;
            held.arguments += 1;
            held.argument = .fresh;
            held.start = emit.ahead_of(emitter, at);
        }

        if (walk.text_is(text, "extends")) held.complex = true;
    } else {}

    return null;
}

fn annotation_named(emitter: *const Emitter, start: u32, angle: u32) bool {
    assert(start <= angle);
    assert(angle < emitter.count);

    if (emitter.tokens[start].kind != .identifier) return false;

    for (start..angle) |index| {
        const held: u32 = @intCast(index);
        const kind = emitter.tokens[held].kind;
        const named = kind == .identifier or kind == .newline or emit.is_dot(emitter, held);
        if (!named) return false;
    }

    return true;
}

fn alias_complex_params(emitter: *const Emitter, equals: u32) bool {
    assert(equals < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const close = emit.back_of(emitter, equals) orelse return false;
    if (!walk.text_is(emitter.tokens[close].text(emitter.source), ">")) return false;

    const open = join.angle_head(emitter, close) orelse return false;

    assert(open < close);

    var commas: u32 = 0;
    var complex = false;
    var depth: u32 = 0;

    for (open + 1..close) |index| {
        const token = emitter.tokens[index];
        const text = token.text(emitter.source);
        const angled = walk.text_is(text, "<");
        const opened = walk.is_open(token.kind) or token.kind == .block_start or angled;
        const closed = walk.is_close(token.kind) or token.kind == .block_end;
        const shut: u32 = if (closed) 1 else if (all_greater(text)) @intCast(text.len) else 0;

        if (opened) {
            depth += 1;
        } else if (shut > 0) {
            depth -|= shut;
        } else if (depth == 0) {
            const extended = walk.text_is(text, "extends") or walk.text_is(text, "=");

            if (token.is_punctuation(.comma)) commas += 1;
            if (extended) complex = true;
        } else {}
    }

    return commas > 0 and complex;
}

fn alias_broken_value(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!aliased(emitter, position)) return null;
    return alias_conditional(emitter, position) orelse alias_commented_union(emitter, position);
}

pub fn literal_headed(emitter: *const Emitter, position: u32, dot: u32) ?u32 {
    assert(position < emitter.count);
    assert(dot < emitter.count);

    const head = emit.ahead_of(emitter, position) orelse return null;
    const token = emitter.tokens[head];
    const literal = token.kind == .block_start or token.is_punctuation(.bracket_open);
    if (!literal) return null;

    const close = join.closing_of(emitter, head) orelse return null;
    const after = emit.ahead_of(emitter, close) orelse return null;

    assert(after > close);

    if (after != dot) return null;
    return head;
}

pub fn valued_flat(emitter: *const Emitter, colon: u32, end: u32) bool {
    assert(colon < emitter.count);
    assert(end < emitter.count);

    const head = emit.ahead_of(emitter, colon) orelse return false;
    const stop = emit.back_of(emitter, end) orelse return false;
    const question = valued_question(emitter, head, stop) orelse return false;

    assert(question <= stop);

    return !tern.ternary_binary(emitter, head, question);
}

pub fn chain_tailed(emitter: *const Emitter, position: u32, form: core.Wrap) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (form != .bodied) return false;
    if (emitter.arrow_chain.end == std.math.maxInt(u32)) return false;
    return emitter.arrow_chain.tail == position;
}

fn assign_inlined(emitter: *const Emitter, open: u32, previous: ?u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.binary_parts) return false;
    if (previous) |held| assert(held < emitter.count);

    const kind = emitter.tokens[open].kind;
    const braced = kind == .block_start or kind.eql(.{ .punctuation = .bracket_open });
    if (!braced) return false;

    const operator = previous orelse return false;
    return call.logical_operator(emitter, operator);
}

fn assign_classed(emitter: *const Emitter, equals: u32) ?u32 {
    assert(equals < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const word = emit.ahead_of(emitter, equals) orelse return null;
    if (!walk.text_is(emitter.tokens[word].text(emitter.source), "new")) return null;

    var scan = emit.ahead_of(emitter, word) orelse return null;

    if (emitter.tokens[scan].is_punctuation(.paren_open)) {
        scan = emit.ahead_of(emitter, scan) orelse return null;
    }

    if (!walk.text_is(emitter.tokens[scan].text(emitter.source), "class")) return null;

    assert(scan < emitter.count);

    var depth: u32 = 0;

    while (scan < emitter.count) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;

        if (kind == .block_start) {
            if (depth == 0) return scan;
        }

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            if (depth == 0) return null;

            depth -= 1;
        } else {}
    }

    return null;
}

fn value_newed(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    var scan = value_angled(emitter, open) orelse open;

    for (0..core.define_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;
        const token = emitter.tokens[held];
        const text = token.text(emitter.source);
        if (walk.text_is(text, "new")) return true;

        if (value_newed_chained(emitter, token, held)) |next| {
            scan = next;

            continue;
        }

        const worded = token.kind == .identifier;
        const pathed = walk.text_is(text, ".") or walk.text_is(text, "?.");

        if (!worded) {
            if (!pathed) return false;
        }

        scan = held;
    }

    return false;
}

fn value_newed_chained(emitter: *const Emitter, token: Token, held: u32) ?u32 {
    assert(held < emitter.count);

    if (!token.is_punctuation(.paren_close)) return null;

    const inner = emitter.brackets.open_of(held) orelse return null;
    if (!list.calling(emitter, inner)) return null;
    return value_angled(emitter, inner) orelse inner;
}

fn value_angled(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const close = emit.back_of(emitter, open) orelse return null;
    const text = emitter.tokens[close].text(emitter.source);
    if (!all_greater(text)) return null;

    const outer = emitter.brackets.angles_at(open);
    var held = close;

    for (0..core.define_scan_max) |_| {
        const before = emit.back_of(emitter, held) orelse return null;

        held = blk: {
            if (walk.is_close(emitter.tokens[before].kind)) {
                break :blk emitter.brackets.open_of(before) orelse return null;
            }

            break :blk before;
        };

        if (emitter.brackets.angles_at(held) == outer) {
            if (walk.text_is(emitter.tokens[held].text(emitter.source), "<")) return held;
        }
    }

    return null;
}

fn all_greater(text: []const u8) bool {
    if (text.len == 0) return false;

    for (text) |byte| {
        if (byte != '>') return false;
    }

    return true;
}

fn value_dotted(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emit.is_dot(emitter, position)) return false;

    const held = emit.back_of(emitter, position) orelse return false;
    const kind = emitter.tokens[held].kind;
    if (kind.eql(.{ .punctuation = .bracket_close })) return true;
    return !walk.is_close(kind);
}

fn chain_filled(emitter: *const Emitter, dot: u32) bool {
    assert(dot < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const last = emit.back_of(emitter, dot) orelse return false;
    const width = span.printed_columns(emitter, emitter.line_first, last);

    const level = @max(emitter.printed, emitter.levels) + span.spread_count(emitter) +
        span.wrap_levels(emitter);

    return level * emitter.options.indent_width + width > emitter.options.line_width;
}

fn param_brace(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return null;

    const close = join.closing_of(emitter, open) orelse return null;
    if (!list.param_hugs(emitter, open, close)) return null;
    if (arrow_typed_ahead(emitter, close) == null) return null;

    assert(open < close);

    var at = open + 1;

    while (at < close) : (at += 1) {
        const kind = emitter.tokens[at].kind;

        if (kind == .block_start) {
            assert(at <= emitter.count);

            return at;
        }

        if (kind.eql(.{ .punctuation = .bracket_open })) {
            assert(at <= emitter.count);

            return at;
        }
    }

    return null;
}

fn assign_filled(emitter: *const Emitter, equals: u32, bracket: u32) bool {
    assert(equals < emitter.count);
    assert(bracket < emitter.count);

    const open = assign_classed(emitter, equals) orelse bracket;
    const reach = param_brace(emitter, open) orelse open;
    const after = emit.ahead_of(emitter, equals);
    const headed = if (after) |held| held > open else true;
    if (headed) return false;

    const classed_new = assign_filled_parenthesized(emitter, equals, open);

    const width = span.printed_columns(emitter, emitter.line_first, reach) +
        @as(u32, @intFromBool(classed_new));

    const held = @max(emitter.printed, emitter.levels) + span.spread_count(emitter) +
        span.wrap_levels(emitter);

    const level = @max(held, link.led_level(emitter));
    return level * emitter.options.indent_width + width > emitter.options.line_width;
}

fn assign_filled_parenthesized(emitter: *const Emitter, equals: u32, open: u32) bool {
    assert(equals < emitter.count);
    assert(open < emitter.count);

    const classed = assign_classed(emitter, equals) orelse return false;
    if (classed != open) return false;

    const word = emit.ahead_of(emitter, equals) orelse return false;
    const held = emit.ahead_of(emitter, word) orelse return false;

    return walk.text_is(emitter.tokens[held].text(emitter.source), "class");
}

fn assign_functioned(emitter: *const Emitter, position: u32) ?struct { u32, u32 } {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.assign_lines) return null;

    const last = assign_chained(emitter, position) orelse position;
    const head = emit.ahead_of(emitter, last) orelse return null;
    const async_word = walk.text_is(emitter.tokens[head].text(emitter.source), "async");
    const word = if (async_word) emit.ahead_of(emitter, head) orelse return null else head;
    if (!walk.text_is(emitter.tokens[word].text(emitter.source), "function")) return null;

    var named = emit.ahead_of(emitter, word) orelse return null;

    if (walk.text_is(emitter.tokens[named].text(emitter.source), "*")) {
        named = emit.ahead_of(emitter, named) orelse return null;
    }

    var open = if (emitter.tokens[named].kind == .identifier)
        emit.ahead_of(emitter, named) orelse return null
    else
        named;

    if (walk.text_is(emitter.tokens[open].text(emitter.source), "<")) {
        const ends = join.angle_close(emitter, open) orelse return null;

        open = emit.ahead_of(emitter, ends) orelse return null;
    }

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return null;

    const brace_at = join.signature_brace(emitter, open) orelse return null;
    if (emitter.tokens[brace_at].kind != .block_start) return null;
    return assign_functioned_tail(emitter, word, open, brace_at);
}

fn assign_functioned_tail(
    emitter: *const Emitter,
    word: u32,
    open: u32,
    brace_at: u32,
) ?struct { u32, u32 } {
    assert(word < emitter.count);
    assert(open < emitter.count);
    assert(brace_at < emitter.count);

    const shut = join.closing_of(emitter, brace_at) orelse return null;
    const stop = emit.ahead_of(emitter, shut) orelse return null;
    const membered = emit.is_dot(emitter, stop);

    const level = @max(emitter.printed, emitter.levels) + span.spread_count(emitter) +
        span.wrap_levels(emitter);

    const broken = @max(level, link.led_level(emitter)) * emitter.options.indent_width +
        span.printed_columns(emitter, emitter.line_first, open) > emitter.options.line_width;

    const dedent = if (broken) shut else word;
    const semicolon = emitter.tokens[stop].is_punctuation(.semicolon);

    if (!membered) {
        if (!semicolon) return null;
    }

    return .{ word, dedent };
}

fn assign_angled(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!walk.text_is(emitter.tokens[open].text(emitter.source), "<")) return null;
    if (!join.angle_generic(emitter, open)) return null;

    const ends = join.angle_close(emitter, open) orelse return null;
    const head = emit.ahead_of(emitter, open) orelse return null;
    if (head >= ends) return null;
    if (join.angle_hugged(emitter, head, ends)) return null;
    return ends;
}

fn assign_angle_commented(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const ends = assign_angled(emitter, open) orelse return false;
    return unite.angle_comments(emitter, open, ends);
}

fn assign_cast_type(emitter: *const Emitter, brace_at: u32, closed: bool) ?u32 {
    assert(brace_at < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!closed) return null;

    const cast = blk: {
        const word = emit.back_of(emitter, brace_at) orelse break :blk false;
        const text = emitter.tokens[word].text(emitter.source);

        break :blk walk.text_is(text, "as") or walk.text_is(text, "satisfies");
    };

    if (!cast) return null;
    if (emitter.tokens[brace_at].kind != .block_start) return null;
    return join.closing_of(emitter, brace_at);
}

fn assign_chained(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var held: ?u32 = null;
    var scan = emit.ahead_of(emitter, position) orelse return null;

    for (0..assign_chain_max) |_| {
        const token = emitter.tokens[scan];

        const assign = token.is_punctuation(.assign) and
            walk.text_is(token.text(emitter.source), "=");

        if (assign) {
            held = scan;
            scan = emit.ahead_of(emitter, scan) orelse return null;

            continue;
        }

        if (token.kind != .identifier) {
            if (!emit.is_dot(emitter, scan)) break;
        }

        scan = emit.ahead_of(emitter, scan) orelse return null;
    }

    return held;
}

fn assign_arrow(emitter: *const Emitter, position: u32) ?struct { u32, u32 } {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.assign_lines) return null;
    if (emitter.typed) return null;
    if (tern.typed_frame(emitter)) return null;
    if (aliased(emitter, position)) return null;

    var depth: u32 = 0;
    var scan = position + 1;

    while (scan < emitter.count) {
        const spanned = tmpl.template_body(emitter, scan) orelse span.jsx_body(emitter, scan);

        if (spanned) |end| {
            scan = end + 1;

            continue;
        }

        const kind = emitter.tokens[scan].kind;
        const opening = walk.is_open(kind) or kind == .block_start;
        const shut = walk.is_close(kind) or kind == .block_end;

        if (opening) {
            depth += 1;

            scan += 1;

            continue;
        }

        if (shut) {
            if (depth == 0) return assign_arrow_closed(emitter, position, scan);

            depth -= 1;

            scan += 1;

            continue;
        }

        if (depth == 0) {
            if (emitter.tokens[scan].is_punctuation(.semicolon)) {
                const arrow = valued_arrow(emitter, position, scan) orelse return null;
                return .{ arrow, scan };
            }
        }

        scan += 1;
    }

    return null;
}

fn assign_arrow_closed(emitter: *const Emitter, position: u32, scan: u32) ?struct { u32, u32 } {
    assert(position < emitter.count);
    assert(scan < emitter.count);

    if (!grouping_close(emitter, scan)) return null;

    const arrow = valued_arrow(emitter, position, scan) orelse return null;
    return .{ arrow, scan };
}

pub fn grouping_close(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return false;

    const held = line.frame(emitter);
    if (held.close != close) return false;
    if (!held.kind.eql(.{ .punctuation = .paren_open })) return false;
    if (list.calling(emitter, held.open)) return false;
    return !split.headed(emitter, held.open);
}

fn aliased(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.typed) return true;
    if (emitter.depth == 0) return false;
    if (line.frame(emitter).kind != .block_start) return false;
    return emit.typing(emitter, span.union_head(emitter, position));
}

fn required_value(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.chain_simples) return false;

    const head = emit.ahead_of(emitter, position) orelse return false;
    if (!walk.text_is(emitter.tokens[head].text(emitter.source), "require")) return false;

    const open = emit.ahead_of(emitter, head) orelse return false;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;
    return required_whole(emitter, open);
}

fn required_whole(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const close = join.closing_of(emitter, open) orelse return false;
    const next = emit.ahead_of(emitter, close) orelse return true;
    const token = emitter.tokens[next];
    if (token.kind == .block_end) return true;
    if (token.is_punctuation(.semicolon)) return true;
    if (token.is_punctuation(.comma)) return true;
    if (walk.is_close(token.kind)) return true;
    if (!body.parts_at(emitter, close, next)) return false;

    const worded = token.kind == .identifier or token.kind == .keyword;
    if (!worded) return false;
    return !word_listed(&required_whole_refused, token.text(emitter.source));
}

fn ternary_assigned(emitter: *const Emitter, position: u32) ?struct { u32, u32 } {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const start = emit.ahead_of(emitter, position) orelse return null;
    if (!tern.ternary_owns(emitter, start)) return null;
    return tern.assign_ternaried(emitter, position);
}

fn member_fluid_head(emitter: *const Emitter, equals: u32) bool {
    assert(equals < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const head = emit.ahead_of(emitter, equals) orelse return false;
    if (walk.text_is(emitter.tokens[head].text(emitter.source), "new")) return true;
    if (member_fluid_head_cast(emitter, head)) return true;
    return inline_valued(emitter, head);
}

fn member_fluid_head_cast(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const stop = link.chain_stop(emitter, head) orelse return false;
    return link.member_cast(emitter, head, stop) != null;
}

fn inline_valued(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const end = call.valued_semicolon(emitter, head) orelse return false;
    const stop = emit.back_of(emitter, end) orelse return false;
    if (stop <= head) return false;
    if (!valued_binary(emitter, head, stop)) return false;
    if (call.binary_floor(emitter, head, stop) > logical_level_max) return false;
    return span.binary_inlined(emitter, stop);
}

fn assign_paren_whole(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.chain_simples) return false;

    const frame = line.frame(emitter);
    if (!assign_paren_whole_frame(emitter, &frame)) return false;

    const head = emit.ahead_of(emitter, position) orelse return false;

    if (!assign_paren_whole_led(emitter, &frame, position)) return false;
    return assign_paren_whole_valued(emitter, &frame, head);
}

fn assign_paren_whole_frame(emitter: *const Emitter, frame: *const core.Frame) bool {
    assert(frame.open < emitter.count);
    assert(frame.close < emitter.count);

    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return false;
    if (wide.defined(emitter, frame.open)) return false;
    if (split.headed(emitter, frame.open)) return false;
    return !list.calling(emitter, frame.open);
}

fn assign_paren_whole_led(emitter: *const Emitter, frame: *const core.Frame, position: u32) bool {
    assert(frame.open < emitter.count);
    assert(position < emitter.count);

    const last = emit.back_of(emitter, position);
    const expected = if (last) |held| assign_left_head(emitter, frame.open, held) else null;

    return emit.ahead_of(emitter, frame.open) == expected;
}

fn assign_paren_whole_valued(emitter: *const Emitter, frame: *const core.Frame, head: u32) bool {
    assert(head < emitter.count);
    assert(frame.close < emitter.count);

    const end = valued_element(emitter, head) orelse return false;
    if (end == frame.close) return true;
    return emit.ahead_of(emitter, end) == frame.close;
}

fn assign_poorly(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.chain_simples) return null;

    const frame = line.frame(emitter);
    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return null;

    const head = emit.ahead_of(emitter, position) orelse return null;
    const end = valued_element(emitter, head) orelse return null;

    if (!assign_poorly_operand(emitter, &frame)) {
        if (!assign_poorly_wrapped(emitter, &frame, position, end)) return null;
    }

    if (!chain_poorly(emitter, head, end)) return null;
    return end;
}

fn assign_poorly_operand(emitter: *const Emitter, frame: *const core.Frame) bool {
    assert(frame.open < emitter.count);
    assert(frame.close < emitter.count);

    if (emit.back_of(emitter, frame.open)) |held| {
        if (span.wrapping_operator(emitter, held)) return true;
    }

    if (emit.ahead_of(emitter, frame.close)) |held| {
        return span.wrapping_operator(emitter, held);
    }

    return false;
}

fn assign_poorly_wrapped(
    emitter: *const Emitter,
    frame: *const core.Frame,
    position: u32,
    end: u32,
) bool {
    assert(frame.open < emitter.count);
    assert(position < emitter.count);
    assert(end <= emitter.count);

    const last = emit.back_of(emitter, position);
    const expected = if (last) |held| assign_left_head(emitter, frame.open, held) else null;
    if (emit.ahead_of(emitter, frame.open) != expected) return false;

    if (end != frame.close) {
        if (emit.ahead_of(emitter, end) != frame.close) return false;
    }

    if (wide.defined(emitter, frame.open)) return false;
    if (split.headed(emitter, frame.open)) return false;
    return !list.calling(emitter, frame.open);
}

fn assign_left_head(emitter: *const Emitter, open: u32, last: u32) ?u32 {
    assert(open < last);
    assert(last < emitter.count);

    var scan = last;

    for (0..assign_chain_max) |_| {
        const token = emitter.tokens[scan];

        if (walk.is_close(token.kind)) {
            scan = emitter.brackets.open_of(scan) orelse return null;
        } else {
            if (!assign_left_head_word(emitter, token, scan)) return null;
        }

        const before = emit.back_of(emitter, scan) orelse return null;
        if (before == open) return scan;

        scan = before;
    }

    return null;
}

fn assign_left_head_word(emitter: *const Emitter, token: Token, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (token.kind == .identifier) return true;
    if (walk.text_is(token.text(emitter.source), "this")) return true;
    return emit.is_dot(emitter, scan);
}

fn chain_poorly(emitter: *const Emitter, head: u32, end: u32) bool {
    assert(head < end);
    assert(end < emitter.count);

    return chain_poorly_at(emitter, head, end) != null;
}

const AnnotationArgument = enum { fresh, opening, named, mixed };

const AnnotationScan = struct {
    argument: AnnotationArgument,
    arguments: u32,
    brackets: u32,
    complex: bool,
    depth: u32,
    start: ?u32,
};

const ChainPoorlyStep = struct { scan: u32, chained: bool };

fn chain_poorly_at(emitter: *const Emitter, head: u32, end: u32) ?u32 {
    assert(head < end);
    assert(end < emitter.count);

    const text = emitter.tokens[head].text(emitter.source);

    if (emitter.tokens[head].kind != .identifier) {
        if (!walk.text_is(text, "this")) return null;
    }

    const threshold = emitter.options.line_width / 4;
    var chained = false;
    var scan = head;

    for (0..emitter.count) |_| {
        if (scan >= end) break;

        const step = chain_poorly_step(emitter, scan, end, threshold) orelse return null;

        if (step.chained) chained = true;

        scan = step.scan;
    }

    if (!chained) return null;
    if (span.chain_valued(emitter, head) != null) return null;
    return end;
}

fn chain_poorly_step(
    emitter: *const Emitter,
    scan: u32,
    end: u32,
    threshold: u32,
) ?ChainPoorlyStep {
    assert(scan < end);
    assert(end < emitter.count);
    assert(threshold < std.math.maxInt(u32));

    const token = emitter.tokens[scan];
    const kind = token.kind;

    if (kind.eql(.{ .punctuation = .paren_open })) {
        return chain_poorly_parenthesized(emitter, scan, end, threshold);
    }

    if (kind.eql(.{ .punctuation = .bracket_open })) {
        const close = join.closing_of(emitter, scan) orelse return null;
        if (close >= end) return null;
        return .{ .scan = close + 1, .chained = true };
    }

    const text = token.text(emitter.source);

    if (emit.is_dot(emitter, scan)) return .{ .scan = scan + 1, .chained = true };
    if (walk.text_is(text, "!")) return .{ .scan = scan + 1, .chained = false };

    if (walk.text_is(text, "<")) {
        return chain_poorly_angled(emitter, scan, end);
    }

    if (kind != .identifier) {
        if (kind != .keyword) return null;
    }

    return .{ .scan = scan + 1, .chained = false };
}

fn chain_poorly_parenthesized(
    emitter: *const Emitter,
    scan: u32,
    end: u32,
    threshold: u32,
) ?ChainPoorlyStep {
    assert(scan < end);
    assert(end < emitter.count);
    assert(threshold < std.math.maxInt(u32));

    const close = join.closing_of(emitter, scan) orelse return null;
    if (close >= end) return null;

    const first = emit.ahead_of(emitter, scan) orelse return null;

    if (first != close) {
        if (chain_poorly_wide(emitter, scan, close, first, threshold)) return null;
    }

    return .{ .scan = close + 1, .chained = true };
}

fn chain_poorly_wide(
    emitter: *const Emitter,
    scan: u32,
    close: u32,
    first: u32,
    threshold: u32,
) bool {
    assert(scan < close);
    assert(first <= close);

    if (wide.element_count(emitter, scan, close) > 1) return true;
    return span.printed_columns(emitter, first, close - 1) > threshold;
}

fn chain_poorly_angled(emitter: *const Emitter, scan: u32, end: u32) ?ChainPoorlyStep {
    assert(scan < end);
    assert(end < emitter.count);

    const close = join.angle_close(emitter, scan) orelse return null;
    if (close >= end) return null;
    if (!type_arguments_simple(emitter, scan, close)) return null;
    return .{ .scan = close + 1, .chained = false };
}

fn type_arguments_simple(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const after = emit.ahead_of(emitter, close) orelse return false;
    const called = emitter.tokens[after].is_punctuation(.paren_open);
    const head = emit.ahead_of(emitter, open) orelse return false;
    if (head >= close) return false;
    if (!called) return false;
    if (emitter.tokens[head].kind == .block_start) return false;

    var depth: u32 = 0;

    for (head..close) |index| {
        const token = emitter.tokens[index];
        const spelled_text = token.text(emitter.source);
        const opening = walk.is_open(token.kind) or walk.text_is(spelled_text, "<");
        const closing = walk.is_close(token.kind) or walk.text_is(spelled_text, ">");

        if (opening) {
            depth += 1;
        } else if (closing) {
            depth -|= 1;
        } else if (depth == 0) {
            const separated = walk.text_is(spelled_text, "|") or
                walk.text_is(spelled_text, "&") or token.is_punctuation(.comma);

            if (separated) return false;
        } else {}
    }

    assert(depth <= close - head);

    return true;
}

fn cast_valued(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head < emitter.count);
    assert(stop < emitter.count);

    var depth: u32 = 0;
    var scan = head;

    while (scan <= stop) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const opened = walk.is_open(kind) or kind == .block_start;
        const closed = walk.is_close(kind) or kind == .block_end;

        if (opened) {
            depth += 1;
        } else if (closed) {
            depth -|= 1;
        } else if (depth == 0) {
            if (line.group_word(emitter, scan)) {
                if (cast_union(emitter, scan)) return true;
            }
        } else {}
    }

    return false;
}

fn cast_union(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var depth: u32 = 0;
    var scan = position;

    for (0..core.define_scan_max) |_| {
        scan = emit.ahead_of(emitter, scan) orelse return false;

        const token = emitter.tokens[scan];
        const opened = walk.is_open(token.kind) or token.kind == .block_start;
        const closed = walk.is_close(token.kind) or token.kind == .block_end;

        if (opened) {
            depth += 1;
        } else if (closed) {
            if (depth == 0) return false;

            depth -= 1;
        } else if (depth == 0) {
            const separated = token.is_punctuation(.comma) or token.is_punctuation(.semicolon);

            if (walk.text_is(token.text(emitter.source), "|")) return true;
            if (separated) return false;
        } else {}
    }

    return false;
}

fn assign_patterned(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const close = emit.back_of(emitter, position) orelse return false;
    if (emitter.tokens[close].kind != .block_end) return false;

    const open = emitter.brackets.open_of(close) orelse return false;
    return bind.pattern_complex(emitter, open, close, true);
}

fn assign_bound(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const found = assign_bound_at(emitter, position) orelse return null;
    if (bind.lone_value(emitter, position, found)) return null;
    return found;
}

fn assign_bound_at(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const frame = line.frame(emitter);
    if (assign_paren_whole(emitter, position)) return frame.close;
    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return null;
    if (wide.defined(emitter, frame.open)) return null;
    if (split.headed(emitter, frame.open)) return null;
    if (assign_bound_parameters(emitter, frame.close)) return null;
    if (assign_bound_operand(emitter, &frame)) return null;

    const head = emit.ahead_of(emitter, position) orelse return null;
    const end = valued_element(emitter, head) orelse return null;
    if (end <= head) return null;
    if (assign_bound_bracketed(emitter, head, end)) return null;
    return end;
}

fn assign_bound_parameters(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.ahead_of(emitter, close) orelse return false;
    const text = emitter.tokens[held].text(emitter.source);
    if (walk.text_is(text, "{")) return true;
    if (walk.text_is(text, ":")) return true;
    return walk.text_is(text, "=>");
}

fn assign_bound_operand(emitter: *const Emitter, frame: *const core.Frame) bool {
    assert(frame.open < emitter.count);
    assert(frame.close < emitter.count);

    if (emit.back_of(emitter, frame.open)) |held| {
        if (span.wrapping_operator(emitter, held)) return true;
    }

    const held = emit.ahead_of(emitter, frame.close) orelse return false;
    return span.wrapping_operator(emitter, held);
}

fn assign_bound_bracketed(emitter: *const Emitter, head: u32, end: u32) bool {
    assert(head < end);
    assert(end < emitter.count);

    for (head..end) |index| {
        const scan: u32 = @intCast(index);
        const token = emitter.tokens[scan];
        const text = token.text(emitter.source);
        const angled = walk.text_is(text, "<");
        const shut = walk.text_is(text, ">");
        const angle = angled or shut;

        if (angled) {
            if (assign_bound_hugged(emitter, scan)) continue;
        }

        if (angle) {
            if (!shut) return true;
            if (!assign_bound_shut(emitter, scan)) return true;

            continue;
        }

        const opened = walk.is_open(token.kind) or token.kind == .block_start;
        if (!opened) continue;
        if (join.closing_of(emitter, scan) != emit.ahead_of(emitter, scan)) return true;
    }

    return false;
}

fn assign_bound_hugged(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!join.angle_generic(emitter, open)) return false;

    const close = join.angle_close(emitter, open) orelse return false;
    const held = emit.ahead_of(emitter, open) orelse return false;
    if (held >= close) return false;
    return join.angle_hugged(emitter, held, close);
}

fn assign_bound_shut(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const open = join.angle_head(emitter, close) orelse return false;
    const held = emit.ahead_of(emitter, open) orelse return false;
    if (held >= close) return false;
    return join.angle_hugged(emitter, held, close);
}

fn cast_parenthesized(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const held = emit.ahead_of(emitter, open) orelse return false;
    if (!walk.text_is(emitter.tokens[held].text(emitter.source), "<")) return false;

    const close = join.angle_close(emitter, held) orelse return false;
    return wrap.cast_wrapped(emitter, close) != null;
}

fn valued_element(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    return valued_element_in(emitter, head, line.frame(emitter).close);
}

pub fn valued_binary(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head < emitter.count);
    assert(stop < emitter.count);

    const base = emitter.brackets.angles_at(head);
    var depth: u32 = 0;
    var found = false;
    var scan = head;

    while (scan <= stop) {
        if (valued_spanned(emitter, scan)) |end| {
            assert(end >= scan);

            scan = end + 1;

            continue;
        }

        const kind = emitter.tokens[scan].kind;
        const level = depth == 0 and emitter.brackets.angles_at(scan) <= base;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (level) {
            if (valued_binary_refused(emitter, scan)) return false;

            if (span.wrapping_operator(emitter, scan)) found = true;
        } else {}

        scan += 1;
    }

    return found;
}

fn valued_binary_refused(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const text = emitter.tokens[scan].text(emitter.source);

    if (walk.text_is(text, "?")) {
        if (!tern.optional(emitter, scan)) return true;
    }

    if (walk.text_is(text, "=>")) return true;
    if (walk.text_is(text, ",")) return true;
    return walk.text_is(text, "=");
}

pub fn param_defaulted(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.depth == 0) return false;

    const frame = line.frame(emitter);
    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return false;
    if (frame.close <= frame.open) return false;
    if (split.headed(emitter, frame.open)) return false;

    const stop = if (emitter.depth > 1) emitter.nest[emitter.depth - 2].open else 0;
    const after = emit.ahead_of(emitter, frame.close) orelse return false;
    const token = emitter.tokens[after];
    if (walk.text_is(token.text(emitter.source), "=>")) return true;
    if (token.kind == .block_start) return true;
    if (!token.is_punctuation(.colon)) return false;
    return !tern.ternary_within(emitter, after, stop);
}

fn opened_statement(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var depth: u32 = 0;

    for (0..position) |offset| {
        const scan = position - 1 - @as(u32, @intCast(offset));
        const token = emitter.tokens[scan];

        if (depth == 0) {
            if (opened_statement_ended(emitter, scan)) return true;
        }

        if (walk.is_close(token.kind)) {
            depth += 1;

            continue;
        }

        const opening = walk.is_open(token.kind) or walk.substituting(emitter.source, token);

        if (opening) {
            if (depth == 0) return true;

            depth -= 1;

            continue;
        }

        if (depth > 0) continue;
        if (emitter.brackets.angles_at(scan) > 0) continue;
        if (token.is_punctuation(.comma)) return false;
        if (token.kind == .block_end) return true;
        if (token.kind == .comment) return true;
        if (token.is_punctuation(.semicolon)) return true;
    }

    return true;
}

fn opened_statement_ended(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.tokens[scan].kind != .block_end) return false;

    const held = emit.ahead_of(emitter, scan) orelse return false;
    return line.word_is(emitter, held, &statement_words);
}

fn opened_above(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    for (emitter.nest[0..emitter.depth]) |frame| {
        if (body.parts_at(emitter, frame.open, position)) continue;
        if (body.parting(emitter, frame.open, position)) continue;
        return false;
    }

    return true;
}

pub fn tail_called(emitter: *const Emitter, value_at: u32, close: u32) bool {
    assert(value_at < emitter.count);
    assert(close < emitter.count);

    const tail = emit.back_of(emitter, close) orelse return false;
    if (!emitter.tokens[tail].is_punctuation(.paren_close)) return false;

    const open = emitter.brackets.open_of(tail) orelse return false;

    assert(open < tail);

    if (!list.calling(emitter, open)) return false;
    return chain_poorly_at(emitter, value_at, close) == null;
}
