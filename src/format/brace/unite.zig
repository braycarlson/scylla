const std = @import("std");
const assert = std.debug.assert;
const bind = @import("bind.zig");
const body = @import("body.zig");
const brace = @import("../brace.zig");
const call = @import("call.zig");
const comment = @import("comment.zig");
const core = @import("emitter.zig");
const emit = @import("emit.zig");
const join = @import("join.zig");
const line = @import("line.zig");
const link = @import("link.zig");
const list = @import("list.zig");
const semi = @import("semi.zig");
const span = @import("span.zig");
const soles = @import("sole.zig");
const tern = @import("tern.zig");
const tmpl = @import("tmpl.zig");
const walk = @import("../walk.zig");
const wide = @import("wide.zig");
const wrap = @import("wrap.zig");
const Emitter = core.Emitter;
const Span = @import("../../stdx/bounded/span.zig");

const Part = enum {
    bar,
    lead,
};

const angle_return_max: u32 = 32;
const angle_return_words: []const []const u8 = &.{ "<", ",", "|", "&" };
const array_suffix_max: u32 = 64;
const bar_columns: u32 = 2;
const cast_heads: []const []const u8 = &.{ "as", "satisfies", "=>" };
const cast_plain_scan_max: u32 = 64;
const cast_words: []const []const u8 = &.{ "as", "satisfies" };
const constraint_breaks: []const []const u8 = &.{ "|", "&", "?", "=>", "extends" };
const decorator_max: u32 = 16;
const header_operand_depth: u32 = 8;

const intersect_stops: []const []const u8 = &.{
    "=>",
    "|",
    "||",
    "&&",
    "??",
    "?",
    "as",
    "satisfies",
    "is",
};

const union_default_max: u32 = 16;
pub const union_group_max: u32 = 8;
const union_list_scan_max: u32 = 256;
const union_scan_max: u32 = 1024;

fn closes_angles(text: []const u8) bool {
    if (text.len == 0) return false;

    for (text) |byte| {
        if (byte != '>') return false;
    }

    assert(text[0] == '>');

    return true;
}

fn spelled(emitter: *const Emitter, position: u32, text: []const u8) bool {
    assert(position < emitter.count);
    assert(text.len > 0);

    return walk.text_eql(emitter.tokens[position].text(emitter.source), text);
}

fn words_contain(words: []const []const u8, text: []const u8) bool {
    assert(words.len <= std.math.maxInt(u16));
    assert(text.len <= std.math.maxInt(u32));

    for (words) |word| {
        if (walk.text_eql(word, text)) return true;
    }

    return false;
}

fn angle_closes_at(emitter: *const Emitter, close: u32) bool {
    assert(emitter.angled <= core.angle_depth_max);
    assert(close < emitter.count);

    for (emitter.angles[0..emitter.angled]) |angle| {
        if (angle.close == close) return true;
    }

    return false;
}

pub fn cast_plain(emitter: *const Emitter, word: u32) bool {
    assert(word < emitter.count);

    var scan = word;

    for (0..cast_plain_scan_max) |_| {
        const held = emit.ahead_of(emitter, scan) orelse return true;
        const token = emitter.tokens[held];
        const text = token.text(emitter.source);

        const stops = token.is_punctuation(.semicolon) or token.is_punctuation(.comma) or
            walk.is_close(token.kind) or token.kind == .block_end;

        if (stops) return true;

        const opener = token.kind == .block_start or walk.text_is(text, "<");

        if (opener) {
            if (cast_plain_shut(emitter, held, text)) |shut| {
                if (cast_plain_skips(emitter, held, shut)) {
                    scan = shut;

                    continue;
                }
            }

            return false;
        }

        if (walk.is_open(token.kind)) return false;

        scan = held;
    }

    return false;
}

fn cast_plain_parted(emitter: *const Emitter, at: u32, shut: u32) bool {
    assert(at < emitter.count);
    assert(at < shut);

    const after = emit.ahead_of(emitter, at) orelse return false;
    if (after > shut) return false;
    return body.parts_at(emitter, at, after);
}

fn cast_plain_shut(emitter: *const Emitter, held: u32, text: []const u8) ?u32 {
    assert(held < emitter.count);
    assert(text.len <= std.math.maxInt(u32));

    if (walk.text_is(text, "<")) return join.angle_close(emitter, held);
    return join.closing_of(emitter, held);
}

fn cast_plain_skips(emitter: *const Emitter, held: u32, shut: u32) bool {
    assert(held <= shut);
    assert(shut < emitter.count);

    var at = held;

    while (at < shut) {
        if (cast_plain_parted(emitter, at, shut)) return false;
        if (spelled(emitter, at, "|")) return false;

        at += 1;
    }

    return true;
}

fn cast_group_bracketed(emitter: *const Emitter, last: u32) bool {
    assert(emitter.tokens[last].is_punctuation(.bracket_close));

    const open = emitter.brackets.open_of(last) orelse return false;
    var numbered = false;

    if (emit.ahead_of(emitter, open)) |inner| {
        const number = emitter.tokens[inner].kind == .number;
        const sole = emit.ahead_of(emitter, inner) == last;

        numbered = number and sole;
    }

    if (numbered) return false;
    if (emit.ahead_of(emitter, open) == last) return false;

    const before = emit.back_of(emitter, open) orelse return false;
    if (emitter.tokens[before].ends_a_value()) return true;
    return spelled(emitter, before, "?.");
}

pub fn cast_group_tail(emitter: *const Emitter, word: u32) bool {
    assert(word < emitter.count);

    const last = emit.back_of(emitter, word) orelse return false;
    const token = emitter.tokens[last];
    if (token.is_punctuation(.bracket_close)) return cast_group_bracketed(emitter, last);
    if (token.kind != .identifier) return false;

    const dot = emit.back_of(emitter, last) orelse return false;
    if (!emit.is_dot(emitter, dot)) return false;
    return link.member_grouped(emitter, dot);
}

pub fn cast_union_at(emitter: *const Emitter, word: u32) bool {
    assert(word < emitter.count);

    const text = emitter.tokens[word].text(emitter.source);
    const casts = walk.text_is(text, "as") or walk.text_is(text, "satisfies");
    if (!casts) return false;

    var head = emit.ahead_of(emitter, word) orelse return false;
    if (spelled(emitter, head, "|")) head = emit.ahead_of(emitter, head) orelse return false;

    const bars, _, const count, const stop =
        span.union_bars(emitter, head, true) orelse return false;

    if (count == 0) return false;
    if (union_casted(emitter, head, bars[0])) return false;
    return !span.union_hugs(emitter, head, &bars, count, stop);
}

pub fn chain_cast_stop(emitter: *const Emitter, head: u32, stop: u32) ?u32 {
    assert(head <= stop);
    assert(stop <= emitter.count);

    var depth: u32 = 0;
    var scan = head;

    while (scan < stop) {
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            if (cast_union_at(emitter, scan)) return scan;
        } else {}

        scan += 1;
    }

    return null;
}

fn returned_type(emitter: *const Emitter, arrow: u32) bool {
    assert(arrow < emitter.count);

    const close = emit.back_of(emitter, arrow) orelse return false;
    if (!emitter.tokens[close].is_punctuation(.paren_close)) return false;

    const open = emitter.brackets.open_of(close) orelse return false;
    const colon = emit.back_of(emitter, open) orelse return false;
    if (!emitter.tokens[colon].is_punctuation(.colon)) return false;

    const paren = emit.back_of(emitter, colon) orelse return false;

    assert(paren < emitter.count);

    return emitter.tokens[paren].is_punctuation(.paren_close);
}

fn union_group_list(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);

    if (join.angle_generic(emitter, open)) return open;
    if (!emitter.tokens[open].is_punctuation(.comma)) return null;
    return union_angle_list(emitter, open);
}

fn union_group_indented(emitter: *const Emitter, head: u32, casted: bool) ?struct { u32, bool } {
    assert(head < emitter.count);

    if (span.union_of(emitter, head) != null) return null;

    const bars, _, const count, const stop =
        span.union_bars(emitter, head, true) orelse return null;

    assert(count <= span.union_member_max);

    if (count == 0) return null;

    if (casted) {
        if (union_casted(emitter, head, bars[0])) return null;
    }

    if (span.union_hugs(emitter, head, &bars, count, stop)) return null;
    if (union_group_conditional(emitter, head, stop)) return null;
    return .{ stop, true };
}

pub fn union_bar_step(emitter: *const Emitter, open: u32, opens: u32) u32 {
    assert(open < emitter.count);
    assert(opens < emitter.count);

    const barred = spelled(emitter, opens, "|");
    const chained = emit.back_of(emitter, open) == opens;

    return @intFromBool(barred and !chained);
}

pub fn union_branch_end(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const text = emitter.tokens[position].text(emitter.source);
    if (walk.text_is(text, "?")) return !tern.optional(emitter, position);
    if (walk.text_is(text, ":")) return tern.ternary(emitter, position);
    return false;
}

fn union_group_conditional(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head <= stop);
    assert(stop < emitter.count);

    var depth: u32 = 0;
    var scan = head;

    while (scan <= stop) {
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            const text = emitter.tokens[scan].text(emitter.source);

            const branched = walk.text_is(text, "?") or
                walk.text_is(text, "extends") or
                walk.text_is(text, "=>");

            if (branched) return true;
        } else {}

        scan = emit.ahead_of(emitter, scan) orelse break;
    }

    return false;
}

pub fn angle_commas(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (!emit.roled(emitter, open, brace.role_type)) return true;

    const after = emit.ahead_of(emitter, close) orelse return false;
    if (!emitter.tokens[after].is_punctuation(.paren_open)) return false;

    const before = emit.back_of(emitter, open) orelse return true;
    const kind = emitter.tokens[before].kind;
    if (kind == .identifier) return false;
    if (walk.is_close(kind)) return false;
    return !spelled(emitter, before, ">");
}

pub fn angle_signed(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (emit.roled(emitter, open, brace.role_type)) return false;

    const close = join.angle_close(emitter, open) orelse return false;
    const paren = emit.ahead_of(emitter, close) orelse return false;
    if (!emitter.tokens[paren].is_punctuation(.paren_open)) return false;

    const prior = comment.back(emitter, open) orelse return false;
    const constructed = walk.text_is(emitter.tokens[prior].text(emitter.source), "new");
    const head = if (constructed) prior else open;
    const member = comment.back(emitter, head) orelse return false;
    const members = bind.enclosing_open(emitter, head) orelse return false;

    assert(member < head);

    if (!angle_member_body(emitter, members)) return false;
    if (member == members) return true;
    if (emitter.tokens[member].is_punctuation(.semicolon)) return true;
    if (emitter.tokens[member].is_punctuation(.comma)) return true;
    return body.parts_at(emitter, member, head);
}

fn angle_member_body(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (emitter.tokens[open].kind != .block_start) return false;
    if (span.type_framed(emitter, open)) return true;

    const word = body.declared_word(emitter, open) orelse return false;
    return walk.text_is(emitter.tokens[word].text(emitter.source), "interface");
}

pub fn angle_comments_comma(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.angled <= core.angle_depth_max);

    if (emitter.angled == 0) return;
    if (emitter.tokens[position].kind == .comment) return;

    const angle = &emitter.angles[emitter.angled - 1];
    if (!angle.commas) return;
    if (position >= angle.close) return;
    if (emitter.depth != angle.nest) return;

    const trailing = emit.ahead_of(emitter, position) orelse return;
    const trailing_text = emitter.tokens[trailing].text(emitter.source);
    const trailing_lined = std.mem.startsWith(u8, trailing_text, "//");

    if (emitter.tokens[trailing].kind != .comment) return;

    if (!trailing_lined) {
        if (!body.parts_at(emitter, position, trailing)) return;
    }

    if (angle_comments_end(emitter, trailing) != angle.close) return;

    angle.commas = false;

    if (emitter.tokens[position].is_punctuation(.comma)) return;

    try emitter.document.push(.{ .if_broken = emitter.comma });
}

fn angle_comments_end(emitter: *const Emitter, trailing: u32) ?u32 {
    assert(trailing < emitter.count);
    assert(emitter.tokens[trailing].kind == .comment);

    var scan = trailing;

    for (0..core.define_scan_max) |_| {
        const held = emit.ahead_of(emitter, scan) orelse return null;
        if (emitter.tokens[held].kind != .comment) return held;

        scan = held;
    }

    return null;
}

pub fn angle_returned(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    return angle_return_paren(emitter, open) != null;
}

pub fn angle_return_paren(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    var scan = open;

    for (0..angle_return_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return null;
        const token = emitter.tokens[held];
        const text = token.text(emitter.source);
        const marked = token.is_punctuation(.colon) or walk.text_is(text, "=>");
        if (marked) return angle_return_before(emitter, held);
        if (!angle_return_passes(emitter, held)) return null;

        scan = held;
    }

    return null;
}

fn angle_return_before(emitter: *const Emitter, held: u32) ?u32 {
    assert(held < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const before = emit.back_of(emitter, held) orelse return null;
    if (!emitter.tokens[before].is_punctuation(.paren_close)) return null;

    const paren = emitter.brackets.open_of(before) orelse return null;
    if (emit.ahead_of(emitter, paren) == before) return null;
    return before;
}

fn angle_return_passes(emitter: *const Emitter, held: u32) bool {
    assert(held < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const token = emitter.tokens[held];
    if (token.kind == .identifier) return true;
    if (token.kind == .keyword) return true;
    if (emit.is_dot(emitter, held)) return true;
    return words_contain(angle_return_words, token.text(emitter.source));
}

pub fn angle_comments(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (angle_comments_sole(emitter, open, close)) return false;

    const angles = emitter.brackets.angles_at(open + 1);
    var depth: u32 = 0;
    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        const token = emitter.tokens[scan];

        if (walk.is_open(token.kind)) {
            depth += 1;
        } else if (walk.is_close(token.kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (token.kind == .comment) {
                if (emitter.brackets.angles_at(scan) != angles) continue;
                if (std.mem.startsWith(u8, token.text(emitter.source), "//")) return true;

                const before = emit.back_of(emitter, scan) orelse continue;
                if (body.parts_at(emitter, before, scan)) return true;
            }
        } else {}
    }

    return false;
}

fn angle_comments_sole(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var named: u32 = 0;
    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        const token = emitter.tokens[scan];
        if (token.kind == .comment) continue;
        if (token.kind == .newline) continue;
        if (token.length == 0) continue;
        if (emit.is_dot(emitter, scan)) continue;

        const word = token.kind == .identifier or token.kind == .keyword;
        if (!word) return false;

        named += 1;
    }

    return named > 0;
}

pub fn annotation_closed(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.union_parts) return;
    if (!emitter.tokens[position].is_punctuation(.assign)) return;

    const level = annotation_level(emitter, position) orelse return;

    while (emitter.indent > level) {
        emitter.indent -= 1;

        try emitter.document.push(.dedent);
    }

    assert(emitter.indent <= level);

    const printed = emitter.depth == 0 or line.frame(emitter).kind == .block_start;

    if (printed) emitter.printed = @min(emitter.printed, level);
}

pub fn annotation_joined(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.tokens[previous].is_punctuation(.colon)) return false;
    if (!emit.roled(emitter, previous, brace.role_type)) return false;
    if (emitter.tokens[position].kind == .comment) return false;
    if (spelled(emitter, position, "|")) return false;
    return annotation_scan(emitter, position);
}

pub fn annotation_comment_broken(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (emitter.tokens[previous].kind != .comment) return false;
    if (!body.parts_at(emitter, previous, position)) return false;

    const colon = emit.back_of(emitter, previous) orelse return false;
    return annotation_comment_joined(emitter, previous, colon);
}

pub fn annotation_comment_joined(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.tokens[previous].is_punctuation(.colon)) return false;
    if (!emit.roled(emitter, previous, brace.role_type)) return false;
    if (emitter.tokens[position].kind != .comment) return false;
    if (emitter.depth == 0) return false;
    return line.frame(emitter).kind == .block_start;
}

pub fn annotation_comment_level(emitter: *const Emitter, leading: u32) ?u32 {
    assert(leading < emitter.count);

    if (spelled(emitter, leading, "|")) return null;

    const noted = emitter.previous orelse return null;
    const colon = emit.back_of(emitter, noted) orelse return null;

    if (!annotation_comment_broken(emitter, leading, noted)) return null;
    if (!body.parts_at(emitter, noted, leading)) return null;

    const opened = span.line_opened(emitter, colon) orelse return null;

    assert(opened < emitter.count);

    return line.level_at(emitter, opened);
}

fn annotation_scan(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.tokens[position].kind != .comment);

    var depth: u32 = 0;
    var scan = position;

    for (0..union_scan_max) |_| {
        const token = emitter.tokens[scan];
        const text = token.text(emitter.source);

        const opens = walk.is_open(token.kind) or token.kind == .block_start or
            walk.text_is(text, "<");

        const closes = walk.is_close(token.kind) or token.kind == .block_end;
        const angled = closes_angles(text);
        const plain = !opens and !closes and !angled;

        if (opens) {
            depth += 1;
        } else if (closes) {
            if (depth == 0) return true;

            depth -= 1;
        } else if (angled) {
            depth -|= std.math.cast(u32, text.len) orelse std.math.maxInt(u32);
        } else {}

        if (plain) {
            if (depth == 0) {
                if (walk.text_is(text, "|")) return false;
                if (annotation_stop(emitter, scan)) return true;
            }
        }

        scan = emit.ahead_of(emitter, scan) orelse return true;
    }

    return false;
}

fn annotation_stop(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const token = emitter.tokens[position];
    if (token.is_punctuation(.assign)) return true;
    if (token.is_punctuation(.comma)) return true;
    if (token.is_punctuation(.semicolon)) return true;
    return walk.text_is(token.text(emitter.source), "=>");
}

fn constraint_grouping(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);

    if (emitter.constraint_owed != null) return null;
    if (emitter.tokens[head].kind == .comment) return null;

    const extends = emit.back_of(emitter, head) orelse return null;
    if (!constraint_listed(emitter, extends)) return null;

    const angle = tern.angle_opening(emitter, extends) orelse return null;
    const close = join.angle_close(emitter, angle) orelse return null;
    if (!angle_closes_at(emitter, close)) return null;
    return constraint_grouping_scan(emitter, head, close);
}

fn constraint_grouping_scan(emitter: *const Emitter, head: u32, close: u32) ?u32 {
    assert(head < emitter.count);
    assert(close < emitter.count);

    const angles = emitter.brackets.angles_at(head);
    var last = head;
    var scan = head;

    for (0..union_scan_max) |_| {
        const token = emitter.tokens[scan];
        const text = token.text(emitter.source);
        const opens = walk.is_open(token.kind) or token.kind == .block_start;
        const nested = emitter.brackets.angles_at(scan) > angles;

        if (opens) {
            scan = join.closing_of(emitter, scan) orelse return null;
        } else if (nested) {} else {
            const ends = scan == close or angle_ends(emitter, scan, angles) or
                token.is_punctuation(.comma) or token.is_punctuation(.assign);

            if (ends) break;

            const broken = words_contain(constraint_breaks, text) or token.kind == .comment;
            if (broken) return null;
        }

        last = scan;
        scan = emit.ahead_of(emitter, scan) orelse return null;
    }

    return last;
}

pub fn constraint_close(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);

    const stop = emitter.constraint_owed orelse return;
    if (stop >= position) return;

    emitter.constraint_owed = null;

    try line.closes_broken(emitter);

    assert(emitter.constraint_owed == null);
}

fn constraint_listed(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (!spelled(emitter, open, "extends")) return false;

    const angle = tern.angle_opening(emitter, open) orelse return false;

    assert(angle < open);
    assert(emitter.brackets.angles_at(angle) < emitter.brackets.angles_at(open));

    return !emit.roled(emitter, angle, brace.role_type);
}

fn declare_grouping(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(emitter.listed <= core.binder_depth_max);

    if (emitter.listed == 0) return null;
    if (emitter.union_grouped == union_group_max) return null;

    const binder = emitter.binders[emitter.listed - 1];
    if (binder.valued) return null;
    if (binder.depth != emitter.depth) return null;
    if (emit.back_of(emitter, head) != binder.start) return null;

    const tail = emit.back_of(emitter, binder.stop) orelse return null;
    if (tail <= head) return null;
    return tail;
}

pub fn declare_group_comma(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);
    assert(emitter.union_grouped <= union_group_max);

    if (emitter.union_grouped == 0) return false;
    if (!emitter.tokens[previous].is_punctuation(.comma)) return false;

    const group = emitter.union_groups[emitter.union_grouped - 1];
    if (!group.declared) return false;
    if (previous <= group.head) return false;
    if (previous >= group.stop) return false;
    if (emitter.depth != group.depth) return false;
    return emitter.brackets.angles_at(previous) == group.angles;
}

fn declare_group_item(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.union_grouped <= union_group_max);

    if (emitter.union_grouped == 0) return false;

    const held = emit.back_of(emitter, position) orelse return false;
    return declare_group_comma(emitter, held);
}

fn decorated_end(emitter: *const Emitter, start: u32, close: u32) ?u32 {
    assert(start < emitter.count);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var tail = start;
    var scan = start;

    while (scan < close) {
        if (tmpl.template_body(emitter, scan)) |end| {
            tail = end;
            scan = end + 1;

            continue;
        }

        const token = emitter.tokens[scan];
        const opens = walk.is_open(token.kind) or token.kind == .block_start;
        const closes = walk.is_close(token.kind) or token.kind == .block_end;
        const visible = token.kind != .newline and token.kind != .comment and token.length > 0;

        if (depth == 0) {
            if (token.is_punctuation(.comma)) break;
        }

        if (opens) {
            depth += 1;
        } else if (closes) {
            if (depth == 0) return null;

            depth -= 1;
        } else {}

        if (visible) tail = scan;

        scan += 1;
    }

    return tail;
}

fn decorated_param(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(emitter.union_grouped <= union_group_max);

    if (!emitter.policy.decorators) return null;
    if (emitter.union_grouped == union_group_max) return null;
    if (emitter.depth == 0) return null;
    if (!spelled(emitter, head, "@")) return null;

    const frame = line.frame(emitter);
    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return null;

    const before = emit.back_of(emitter, head) orelse return null;

    if (before != frame.open) {
        if (!emitter.tokens[before].is_punctuation(.comma)) return null;
    }

    const start = decorators_end(emitter, head) orelse return null;
    return decorated_end(emitter, start, frame.close);
}

fn decorator_gap(emitter: *const Emitter, position: u32) ?bool {
    assert(position < emitter.count);
    assert(emitter.union_grouped <= union_group_max);

    if (emitter.union_grouped == 0) return null;

    const group = emitter.union_groups[emitter.union_grouped - 1];
    if (!group.declared) return null;
    if (!spelled(emitter, group.head, "@")) return null;
    if (position <= group.head) return null;
    if (position > group.stop) return null;
    if (emitter.depth != group.depth) return null;
    if (emitter.brackets.angles_at(position) != group.angles) return null;

    const start = decorators_end(emitter, group.head) orelse return null;

    if (position != start) {
        if (!spelled(emitter, position, "@")) return null;
    }

    if (position > start) return null;

    var expanded = false;
    var scan = emit.ahead_of(emitter, group.head) orelse return null;

    while (scan <= start) {
        const marked = scan == start or spelled(emitter, scan, "@");

        if (marked) {
            if (emit.back_of(emitter, scan)) |held| {
                if (body.parts_at(emitter, held, scan)) expanded = true;
            }
        }

        scan = emit.ahead_of(emitter, scan) orelse return null;
    }

    return expanded;
}

pub fn decorator_closes(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.decorators) return false;

    var scan = previous;

    if (emitter.tokens[scan].is_punctuation(.paren_close)) {
        const open = emitter.brackets.open_of(scan) orelse return false;

        scan = emit.back_of(emitter, open) orelse return false;

        if (spelled(emitter, scan, "@")) return true;
    }

    for (0..decorator_max) |_| {
        if (emitter.tokens[scan].kind != .identifier) return false;

        const before = emit.back_of(emitter, scan) orelse return false;
        if (spelled(emitter, before, "@")) return true;
        if (!emit.is_dot(emitter, before)) return false;

        scan = emit.back_of(emitter, before) orelse return false;
    }

    return false;
}

pub fn class_decorated(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (!emitter.policy.decorators) return false;

    const led = spelled(emitter, position, "@");
    const end = if (led) decorators_end(emitter, position) orelse return false else position;
    if (!class_worded(emitter, end)) return false;
    if (decorator_closes(emitter, previous)) return true;
    if (!led) return false;
    if (spelled(emitter, previous, "=")) return true;
    return spelled(emitter, previous, "export") or spelled(emitter, previous, "default");
}

pub fn decorated_word(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);

    if (!emitter.policy.decorators) return null;
    if (!spelled(emitter, head, "@")) return null;

    const word = decorators_end(emitter, head) orelse return null;

    assert(word > head);

    return word;
}

pub fn decorated_opens(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.decorators) return;
    if (emitter.decorated != null) return;
    if (!spelled(emitter, position, "@")) return;

    const member = decorated_member(emitter, position) orelse return;

    assert(member > position);

    emitter.decorated = member;

    try emitter.document.push(.group_open);
}

pub fn decorated_closes(emitter: *Emitter, position: u32) error{Overflow}!bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const member = emitter.decorated orelse return false;
    if (position < member) return decorated_separates(emitter, position);

    emitter.decorated = null;

    if (!emitter.line_start) try emitter.document.push(.line);

    try emitter.document.push(.group_close);

    return !emitter.line_start;
}

fn decorated_separates(emitter: *Emitter, position: u32) error{Overflow}!bool {
    assert(position < emitter.count);
    assert(emitter.decorated != null);

    if (emitter.line_start) return false;
    if (!spelled(emitter, position, "@")) return false;
    if (emitter.depth == 0) return false;
    if (line.frame(emitter).kind != .block_start) return false;

    try emitter.document.push(.line);

    return true;
}

fn decorated_member(emitter: *const Emitter, at: u32) ?u32 {
    assert(at < emitter.count);
    assert(spelled(emitter, at, "@"));

    if (emitter.depth == 0) return null;

    const frame = line.frame(emitter);
    if (frame.kind != .block_start) return null;
    if (!semi.classed_head(emitter, frame.open)) return null;

    const before = join.coded_before(emitter, at) orelse return null;
    const held = emitter.tokens[before];
    const ended = held.kind == .block_end or held.is_punctuation(.semicolon);
    const led = before == frame.open or ended;
    if (!led) return null;

    const member = decorators_end(emitter, at) orelse return null;
    if (member >= frame.close) return null;
    if (emitter.tokens[member].kind == .comment) return null;

    const from = emitter.tokens[at].offset;
    const parted = body.parted_by(emitter, from, emitter.tokens[member].offset);
    if (parted > 0) return null;
    return member;
}

pub fn decorator_kept(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (!emitter.policy.decorators) return false;

    const previous = emit.back_of(emitter, position) orelse return false;
    if (!decorator_closes(emitter, previous)) return false;
    return class_decorated(emitter, position, previous);
}

fn class_worded(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (spelled(emitter, position, "class")) return true;
    if (spelled(emitter, position, "export")) return true;
    if (!spelled(emitter, position, "abstract")) return false;

    const after = emit.ahead_of(emitter, position) orelse return false;
    return spelled(emitter, after, "class");
}

fn decorators_end(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(spelled(emitter, head, "@"));

    var scan = head;

    for (0..decorator_max) |_| {
        if (!spelled(emitter, scan, "@")) return scan;

        var name = emit.ahead_of(emitter, scan) orelse return null;

        if (emitter.tokens[name].is_punctuation(.paren_open)) {
            const shut = join.closing_of(emitter, name) orelse return null;

            scan = emit.ahead_of(emitter, shut) orelse return null;

            continue;
        }

        for (0..decorator_max) |_| {
            const dot = emit.ahead_of(emitter, name) orelse break;
            if (!emit.is_dot(emitter, dot)) break;

            name = emit.ahead_of(emitter, dot) orelse return null;
        }

        const after = emit.ahead_of(emitter, name) orelse return null;

        if (emitter.tokens[after].is_punctuation(.paren_open)) {
            const close = join.closing_of(emitter, after) orelse return null;

            scan = emit.ahead_of(emitter, close) orelse return null;
        } else {
            scan = after;
        }
    }

    return null;
}

pub fn header_conditioned(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.chain_simples) return false;
    if (!emitter.policy.header_parens) return false;
    if (emitter.depth == 0) return false;

    const frame = line.frame(emitter);
    return condition_parted(emitter, &frame, previous);
}

fn else_head(emitter: *const Emitter, head: u32) u32 {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const word = emit.word_before(emitter, head) orelse return head;
    if (!line.word_is(emitter, word, &.{"else"})) return head;

    const held = emit.word_before(emitter, word) orelse return word;
    if (emitter.tokens[held].kind != .block_end) return word;
    return held;
}

fn condition_parted(emitter: *const Emitter, frame: *const core.Frame, previous: u32) bool {
    assert(previous < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!span.wrapping_operator(emitter, previous)) return false;
    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return false;
    if (!condition_tested(emitter, frame.open)) return false;

    const logical = condition_spelled(emitter, previous, &.{ "&&", "||", "??" });
    const rank = condition_rank(emitter, frame.open, frame.close);
    if (!ranks_equal(rank, span.binary_rank(emitter, previous))) return false;
    if (wrap.rebalanced_within(emitter, previous)) return false;

    if (!logical) {
        if (!condition_ungrouped(emitter, frame, previous)) return false;
    }

    const head = line.head_word(emitter, frame.open, emitter.policy.header_words) orelse
        return false;

    const close = join.closing_of(emitter, frame.open) orelse return false;
    const end = condition_end(emitter, close);
    const start = else_head(emitter, head);
    const width = join.header_width(emitter, start, end) orelse return false;

    return frame.seated * emitter.options.indent_width + width > emitter.options.line_width;
}

fn condition_end(emitter: *const Emitter, close: u32) u32 {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.ahead_of(emitter, close) orelse return close;
    if (emitter.tokens[held].kind != .block_start) return close;
    return held;
}

fn condition_tested(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.word_before(emitter, open) orelse return false;
    return condition_spelled(emitter, held, &.{ "if", "while" });
}

fn condition_spelled(emitter: *const Emitter, position: u32, words: []const []const u8) bool {
    assert(position < emitter.count);
    assert(words.len > 0);

    const text = emitter.tokens[position].text(emitter.source);

    for (words) |word| {
        if (walk.text_eql(text, word)) return true;
    }

    return false;
}

fn ranks_equal(rank: ?u32, other: ?u32) bool {
    if (rank) |held| assert(held < std.math.maxInt(u32));
    if (other) |held| assert(held < std.math.maxInt(u32));

    const held = rank orelse return other == null;
    return other == held;
}

pub fn header_operand_parted(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.chain_simples) return false;
    if (!emitter.policy.header_parens) return false;
    if (emitter.depth < 2) return false;
    if (!span.wrapping_operator(emitter, previous)) return false;

    const index = emitter.depth - 1;
    const frame = &emitter.nest[index];
    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return false;

    const rank = condition_rank(emitter, frame.open, frame.close);
    if (!ranks_equal(rank, span.binary_rank(emitter, previous))) return false;
    if (bind.sequence_spread(emitter, frame.open)) return false;

    const header = header_operand_head(emitter, index) orelse return false;
    if (!condition_framed(emitter, &emitter.nest[header])) return false;
    return header_operand_steps(emitter, header, index);
}

fn header_operand_head(emitter: *const Emitter, index: u32) ?u32 {
    assert(index < emitter.depth);
    assert(emitter.depth <= brace.nest_depth_max);

    var header = index;

    for (0..header_operand_depth) |_| {
        if (header == 0) return null;

        const outer = &emitter.nest[header - 1];
        if (!operand_framed(emitter, &emitter.nest[header], outer)) return null;

        header -= 1;

        if (condition_framed(emitter, &emitter.nest[header])) break;
        if (!emitter.nest[header].kind.eql(.{ .punctuation = .paren_open })) return null;
    }

    assert(header < index);

    return header;
}

fn header_operand_steps(emitter: *const Emitter, header: u32, index: u32) bool {
    assert(header < index);
    assert(index < emitter.depth);

    const header_close = emitter.nest[header].close;
    var level = emitter.nest[header].seated;
    var offset: u32 = 0;
    var step = header + 1;

    while (step <= index) : (step += 1) {
        const paren = &emitter.nest[step];
        const outer = &emitter.nest[step - 1];
        const stacked = step > header + 1 and emit.back_of(emitter, paren.open) == outer.open;

        if (stacked) {
            offset += 1;
        } else {
            level += 1;
            offset = 0;
        }

        if (!header_operand_wide(emitter, paren, level, offset, header_close)) return false;
    }

    return true;
}

fn condition_framed(emitter: *const Emitter, frame: *const core.Frame) bool {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.count == emitter.tokens.len);

    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return false;
    return condition_tested(emitter, frame.open);
}

fn operand_framed(
    emitter: *const Emitter,
    frame: *const core.Frame,
    outer: *const core.Frame,
) bool {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.count == emitter.tokens.len);

    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return false;

    const left = emit.back_of(emitter, frame.open) orelse return false;
    const right = emit.ahead_of(emitter, frame.close) orelse return false;

    if (!operand_edged(emitter, outer, left)) return false;
    if (!operand_edged(emitter, outer, right)) return false;

    const flanked = operand_running(emitter, outer, left) or operand_running(emitter, outer, right);
    if (!flanked) return false;
    return !operand_branched(emitter, frame);
}

fn operand_edged(emitter: *const Emitter, outer: *const core.Frame, held: u32) bool {
    assert(held < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (held == outer.open) return true;
    if (held == outer.close) return true;
    return operand_running(emitter, outer, held);
}

fn operand_running(emitter: *const Emitter, outer: *const core.Frame, held: u32) bool {
    assert(held < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const header = condition_framed(emitter, outer);
    const rank = condition_rank(emitter, outer.open, outer.close);

    if (header) return condition_parted(emitter, outer, held);
    if (!span.wrapping_operator(emitter, held)) return false;
    if (!ranks_equal(span.binary_rank(emitter, held), rank)) return false;
    return bind.enclosing_open(emitter, held) == outer.open;
}

fn operand_branched(emitter: *const Emitter, frame: *const core.Frame) bool {
    assert(frame.open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = frame.open + 1;

    while (scan < frame.close) : (scan += 1) {
        const question = walk.text_is(emitter.tokens[scan].text(emitter.source), "?");
        if (!question) continue;
        if (tern.optional(emitter, scan)) continue;
        if (bind.enclosing_open(emitter, scan) == frame.open) return true;
    }

    return false;
}

fn header_operand_wide(
    emitter: *const Emitter,
    frame: *const core.Frame,
    level: u32,
    offset: u32,
    header: u32,
) bool {
    assert(frame.open < emitter.count);
    assert(header < emitter.count);
    assert(level < std.math.maxInt(u32));
    assert(offset < std.math.maxInt(u32));

    var trail: u32 = 0;
    var scan = frame.close;

    for (0..header_operand_depth) |_| {
        const held = emit.ahead_of(emitter, scan) orelse break;

        if (emitter.tokens[held].is_punctuation(.paren_close)) {
            if (held != header) {
                trail += 1;
                scan = held;

                continue;
            }
        }

        if (span.wrapping_operator(emitter, held)) {
            trail += emitter.tokens[held].length + 1;
        }

        break;
    }

    const width = span.printed_columns(emitter, frame.open, frame.close) + trail + offset;
    return level * emitter.options.indent_width + width > emitter.options.line_width;
}

fn condition_ungrouped(emitter: *const Emitter, frame: *const core.Frame, operator: u32) bool {
    assert(operator < emitter.count);
    assert(frame.open < emitter.count);

    const rank = span.binary_rank(emitter, operator) orelse return false;
    const from = ungrouped_from(emitter, frame, operator, rank);
    const to = ungrouped_to(emitter, frame, operator, rank);
    const left = ungrouped_left(emitter, from, operator);
    const right = ungrouped_right(emitter, to, operator);

    return left or right;
}

fn ungrouped_from(emitter: *const Emitter, frame: *const core.Frame, operator: u32, rank: u32) u32 {
    assert(operator < emitter.count);
    assert(frame.open < emitter.count);
    assert(rank < std.math.maxInt(u32));

    var from = operator;
    var depth: u32 = 0;

    while (emit.back_of(emitter, from)) |held| {
        if (held <= frame.open) break;

        assert(held < from);

        const kind = emitter.tokens[held].kind;

        if (walk.is_close(kind)) {
            depth += 1;
        } else if (walk.is_open(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (ungrouped_floored(emitter, operator, rank, held)) break;
        } else {}

        from = held;
    }

    return from;
}

fn ungrouped_to(emitter: *const Emitter, frame: *const core.Frame, operator: u32, rank: u32) u32 {
    assert(operator < emitter.count);
    assert(frame.open < emitter.count);
    assert(rank < std.math.maxInt(u32));

    var to = operator;
    var depth: u32 = 0;

    while (emit.ahead_of(emitter, to)) |held| {
        if (held >= frame.close) break;

        assert(held > to);

        const kind = emitter.tokens[held].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (ungrouped_floored(emitter, operator, rank, held)) break;
        } else {}

        to = held;
    }

    return to;
}

fn ungrouped_floored(emitter: *const Emitter, operator: u32, rank: u32, held: u32) bool {
    assert(operator < emitter.count);
    assert(held < emitter.count);

    if (held == operator) return false;
    return span.binary_rank(emitter, held) == rank;
}

fn ungrouped_left(emitter: *const Emitter, from: u32, operator: u32) bool {
    assert(from <= operator);
    assert(operator < emitter.count);

    if (from >= operator) return false;

    const tail = emit.back_of(emitter, operator) orelse return false;
    if (tail < from) return false;
    return soles.binary_familied(emitter, from, tail, false);
}

fn ungrouped_right(emitter: *const Emitter, to: u32, operator: u32) bool {
    assert(operator <= to);
    assert(to < emitter.count);

    if (to <= operator) return false;

    const head = emit.ahead_of(emitter, operator) orelse return false;
    if (head > to) return false;
    return soles.binary_familied(emitter, head, to, false);
}

fn condition_rank(emitter: *const Emitter, open: u32, close: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var held: ?u32 = null;
    var scan = open + 1;

    while (scan < close) {
        if (call.spanned_body(emitter, scan)) |end| {
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
            if (condition_branched(emitter, scan)) return null;

            if (span.binary_rank(emitter, scan)) |rank| {
                held = if (held) |found| @min(found, rank) else rank;
            }
        } else {}

        scan += 1;
    }

    return held;
}

fn condition_branched(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!walk.text_is(emitter.tokens[position].text(emitter.source), "?")) return false;
    return !tern.optional(emitter, position);
}

pub fn hole_operand_opens(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.jsxed == 0) return;

    if (hole_operand_closing(emitter, position)) |closing| {
        const open, const rank = closing;

        if (hole_stepped(emitter, open, position, rank)) try line.closes_broken(emitter);

        try emitter.document.push(.group_close);

        return;
    }

    const open = bind.enclosing_open(emitter, position) orelse return;

    _, const rank = hole_operand(emitter, open) orelse return;
    const before = emit.back_of(emitter, position) orelse return;

    if (before == open) {
        try emitter.document.push(.group_open);

        return;
    }

    if (!hole_operator(emitter, open, before, rank)) return;

    if (!hole_stepped(emitter, open, before, rank)) try line.opens_broken(emitter);

    try emitter.document.push(.soft_line);
}

pub fn hole_operand_owned(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.jsxed == 0) return false;
    if (emitter.depth == 0) return false;

    const frame = line.frame(emitter);
    if (hole_operand(emitter, frame.open) == null) return false;
    return position <= frame.close;
}

fn hole_operand_closing(emitter: *const Emitter, position: u32) ?struct { u32, u32 } {
    assert(position < emitter.count);
    assert(emitter.jsxed > 0);

    const open = emitter.brackets.open_of(position) orelse return null;

    _, const rank = hole_operand(emitter, open) orelse return null;

    return .{ open, rank };
}

fn hole_stepped(emitter: *const Emitter, open: u32, to: u32, rank: u32) bool {
    assert(open < to);
    assert(to < emitter.count);
    assert(rank < std.math.maxInt(u32));

    var scan = open + 1;

    while (scan < to) : (scan += 1) {
        if (hole_operator(emitter, open, scan, rank)) return true;
    }

    return false;
}

fn hole_operator(emitter: *const Emitter, open: u32, scan: u32, rank: u32) bool {
    assert(open < scan);
    assert(scan < emitter.count);

    if (span.binary_rank(emitter, scan) != rank) return false;
    return bind.enclosing_open(emitter, scan) == open;
}

fn intersect_assigned(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.assigns <= core.assign_depth_max);

    for (emitter.assigned[0..emitter.assigns]) |held| {
        if (position < held.close) return true;
    }

    return false;
}

pub fn intersect_broken(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const open = intersect_open(emitter, previous) orelse return false;
    return intersect_broken_wide(emitter, open, previous);
}

pub fn intersect_joined(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const open = intersect_open(emitter, previous) orelse return false;
    return !intersect_broken_wide(emitter, open, previous);
}

fn intersect_open(emitter: *const Emitter, previous: u32) ?u32 {
    assert(previous < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.union_parts) return null;
    if (!spelled(emitter, previous, "&")) return null;
    if (emitter.brackets.angles_at(previous) > 0) return null;

    const open = span.union_open(emitter, previous) orelse return null;
    if (!span.union_typed(emitter, open)) return null;

    if (emitter.depth > 0) {
        const frame = line.frame(emitter);

        if (frame.kind == .block_start) {
            const flat = !frame.bodied and !frame.parted;
            if (flat) return null;
        }
    }

    if (intersect_broken_stale(emitter, open)) return null;
    if (intersect_broken_objected(emitter, previous)) return null;
    return open;
}

fn intersect_broken_stale(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (spelled(emitter, open, "?")) {
        if (!tern.optional(emitter, open)) return true;
    }

    if (emitter.tokens[open].is_punctuation(.colon)) {
        if (tern.ternary(emitter, open)) return true;
    }

    if (line.word_is(emitter, open, emitter.policy.cast_words)) return true;
    if (span.predicate_is(emitter, open)) return true;

    const held = emit.back_of(emitter, open) orelse return false;
    return emitter.tokens[held].is_punctuation(.paren_close);
}

fn intersect_broken_objected(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);
    assert(spelled(emitter, previous, "&"));

    if (emit.ahead_of(emitter, previous)) |held| {
        if (emitter.tokens[held].kind == .block_start) return true;
    }

    const held = emit.back_of(emitter, previous) orelse return false;
    return emitter.tokens[held].kind == .block_end;
}

fn intersect_broken_wide(emitter: *const Emitter, open: u32, previous: u32) bool {
    assert(open < emitter.count);
    assert(previous < emitter.count);

    const stop, const forced = intersect_stop(emitter, open) orelse return false;

    if (forced) return true;

    var trailing: u32 = 0;

    if (emit.ahead_of(emitter, stop)) |after| {
        const token = emitter.tokens[after];

        if (token.is_punctuation(.comma)) trailing = 1;
        if (token.is_punctuation(.semicolon)) trailing = 1;
        if (token.is_punctuation(.assign)) trailing = 2;
    }

    const from, const level = intersect_seat(emitter, open, previous);
    const width = span.printed_columns(emitter, from, stop) + trailing;

    assert(trailing <= 2);

    return level * emitter.options.indent_width + width > emitter.options.line_width;
}

pub fn intersect_chained(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return null;
    if (!emit.roled(emitter, open, brace.role_type)) return null;

    const ampersand = emit.back_of(emitter, open) orelse return null;
    if (!spelled(emitter, ampersand, "&")) return null;

    const held = emit.back_of(emitter, ampersand) orelse return null;
    if (emitter.tokens[held].kind != .block_end) return null;

    const curly = emitter.brackets.open_of(held) orelse return null;
    const before = emit.back_of(emitter, curly) orelse return null;
    if (!spelled(emitter, before, "&")) return null;

    assert(curly < open);

    return line.level_at(emitter, curly);
}

fn intersect_gap(emitter: *Emitter, position: u32) error{Overflow}!bool {
    assert(position < emitter.count);

    const ampersand = intersect_group_member(emitter, position) orelse return false;

    assert(ampersand <= position);
    assert(emitter.intersect_group != null);

    if (ampersand == position) return false;
    if (emitter.tokens[position].kind == .block_start) return false;

    if (emit.back_of(emitter, ampersand)) |held| {
        if (emitter.tokens[held].kind == .block_end) return false;
    }

    const group = emitter.intersect_group orelse return false;
    if (!group.lined) return false;

    if (!group.indented) {
        var updated = group;

        updated.indented = true;
        emitter.intersect_group = updated;

        try line.opens_broken(emitter);
    }

    try emitter.document.push(.line);

    return true;
}

pub fn intersect_group_close(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position <= emitter.count);

    const group = emitter.intersect_group orelse return;
    if (group.stop >= position) return;

    emitter.intersect_group = null;

    if (group.indented) try line.closes_broken(emitter);
    if (group.lined) try emitter.document.push(.group_close);

    assert(emitter.intersect_group == null);
}

pub fn intersect_group_joined(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const member = intersect_group_member(emitter, position);

    if (member) |held| assert(held <= position);

    return member != null;
}

fn intersect_group_member(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    const group = emitter.intersect_group orelse return null;
    if (position > group.stop) return null;
    if (emitter.depth != group.depth) return null;
    if (emitter.brackets.angles_at(position) != group.angles) return null;
    if (spelled(emitter, position, "&")) return position;

    const held = emit.back_of(emitter, position) orelse return null;
    if (!spelled(emitter, held, "&")) return null;
    return held;
}

pub fn intersect_group_opens(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);

    const stop, const lined = intersect_grouping(emitter, position) orelse return;

    emitter.intersect_group = .{
        .stop = stop,
        .depth = emitter.depth,
        .angles = emitter.brackets.angles_at(position),
        .indented = false,
        .lined = lined,
    };

    if (!lined) return;

    if (emitter.assign_hug) {
        if (intersect_assigned(emitter, position)) {
            emitter.assign_hug = false;

            try emitter.document.push(.heads);
        }
    }

    try emitter.document.push(.group_open);
}

fn intersect_grouping(emitter: *const Emitter, head: u32) ?struct { u32, bool } {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.union_parts) return null;
    if (emitter.intersect_group != null) return null;
    if (emitter.tokens[head].kind == .comment) return null;

    const open = emit.back_of(emitter, head) orelse return null;
    const stale = intersect_grouping_stale(emitter, open);
    const argued = intersect_argued(emitter, open);

    if (!stale) {
        if (!argued) return null;
    }

    const typed = span.union_typed(emitter, open) or constraint_listed(emitter, open) or argued;
    if (!typed) return null;
    return intersect_grouping_scan(emitter, head);
}

fn intersect_grouping_stale(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (spelled(emitter, open, "as")) return true;
    if (spelled(emitter, open, "satisfies")) return true;
    if (span.predicate_is(emitter, open)) return true;
    if (constraint_listed(emitter, open)) return true;
    if (!emitter.tokens[open].is_punctuation(.colon)) return false;

    const held = emit.back_of(emitter, open) orelse return false;
    return emitter.tokens[held].is_punctuation(.paren_close);
}

fn intersect_grouping_scan(emitter: *const Emitter, head: u32) ?struct { u32, bool } {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const angles = emitter.brackets.angles_at(head);
    var depth: u32 = 0;
    var found = false;
    var ending = head;
    var lined = false;
    var scan = head;

    for (0..union_scan_max) |_| {
        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            if (intersect_grouping_braced(emitter, head, scan, depth)) break;

            depth += 1;
        } else if (walk.is_close(kind)) {
            if (depth == 0) break;

            depth -= 1;
        } else if (depth == 0) {
            if (angle_ends(emitter, scan, angles)) break;

            if (emitter.brackets.angles_at(scan) == angles) {
                if (intersect_grouping_ends(emitter, scan, angles)) break;

                found = found or spelled(emitter, scan, "&");
                lined = lined or intersect_grouping_lined(emitter, scan);
            }
        } else {}

        ending = scan;
        scan = emit.ahead_of(emitter, scan) orelse break;
    }

    if (!found) return null;
    if (ending <= head) return null;
    if (spelled(emitter, ending, "&")) return null;
    return .{ ending, lined };
}

fn intersect_grouping_braced(emitter: *const Emitter, head: u32, scan: u32, depth: u32) bool {
    assert(head <= scan);
    assert(scan < emitter.count);

    if (emitter.tokens[scan].kind != .block_start) return false;
    if (depth > 0) return false;
    if (scan == head) return false;
    return !ampersand_before(emitter, scan);
}

fn intersect_grouping_ends(emitter: *const Emitter, scan: u32, angles: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.brackets.angles_at(scan) == angles);

    const token = emitter.tokens[scan];
    if (token.is_punctuation(.comma)) return true;
    if (token.is_punctuation(.semicolon)) return true;
    if (token.is_punctuation(.assign)) return true;
    if (token.is_punctuation(.colon)) return true;
    if (token.kind == .comment) return true;
    if (words_contain(intersect_stops, token.text(emitter.source))) return true;
    return emitter.brackets.angles_at(scan) < angles;
}

fn intersect_grouping_lined(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!spelled(emitter, scan, "&")) return false;

    const before = emit.back_of(emitter, scan) orelse return false;
    if (emitter.tokens[before].kind == .block_end) return false;

    const after = emit.ahead_of(emitter, scan) orelse return false;
    return emitter.tokens[after].kind != .block_start;
}

fn intersect_argued(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.angled <= core.angle_depth_max);

    const listed = union_group_list(emitter, open) orelse return false;
    const close = join.angle_close(emitter, listed) orelse return false;

    for (emitter.angles[0..emitter.angled]) |held| {
        if (held.close == close) return true;
    }

    return false;
}

pub fn intersect_led(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.union_parts) return false;
    if (!spelled(emitter, position, "&")) return false;

    const open = span.union_open(emitter, position) orelse return false;
    return span.union_typed(emitter, open);
}

pub fn intersect_level(emitter: *const Emitter, leading: u32) ?u32 {
    assert(leading < emitter.count);

    if (emitter.tokens[leading].kind == .block_start) return null;

    const ampersand = join.coded_before(emitter, leading) orelse return null;
    if (!intersect_led(emitter, ampersand)) return null;
    if (emitter.brackets.angles_at(ampersand) > 0) return null;

    if (emit.back_of(emitter, ampersand)) |held| {
        if (emitter.tokens[held].kind == .block_end) return null;
    }

    const open = span.union_open(emitter, ampersand) orelse return null;
    const head = line.coding(emitter, open) orelse return null;
    const found = line.at(emitter, head) orelse return null;
    const commented = comment_before(emitter, head);

    assert(found.start > 0);

    if (found.start - 1 != head) return null;
    if (!commented) return null;
    assert(found.level + 1 < std.math.maxInt(u32));

    return found.level + 1;
}

fn comment_before(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.back_of(emitter, position) orelse return false;
    return emitter.tokens[held].kind == .comment;
}

fn setter_annotated(emitter: *const Emitter, colon: u32) bool {
    assert(colon < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var name = emit.back_of(emitter, colon) orelse return false;
    if (spelled(emitter, name, "?")) name = emit.back_of(emitter, name) orelse return false;
    if (emitter.tokens[name].kind != .identifier) return false;

    const open = emit.back_of(emitter, name) orelse return false;
    return list.setter_params(emitter, open);
}

pub fn union_aligns(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.union_stopped <= core.union_align_max);

    const part = union_parted(emitter, position) orelse return;
    if (part != .bar) return;

    try union_opens(emitter, position);
}

fn union_opens(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.union_stopped <= core.union_align_max);

    if (emitter.union_stopped == core.union_align_max) return;

    const held = span.union_of(emitter, position) orelse return;

    emitter.union_stops[emitter.union_stopped] = held.stop;
    emitter.union_stopped += 1;

    try emitter.document.push(.@"align");
}

pub fn union_brace_fits(emitter: *const Emitter, held: *const span.Union) bool {
    assert(held.open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return false;

    const frame = span.union_frame(emitter, held.open);
    if (frame.kind != .block_start) return false;
    if (frame.bodied) return false;
    if (frame.parted) return false;
    if (frame.open > held.open) return false;
    if (frame.close < held.head) return false;

    const found = line.at(emitter, frame.open) orelse return false;
    var trailing: u32 = 0;

    if (emit.ahead_of(emitter, frame.close)) |after| {
        const token = emitter.tokens[after];

        if (token.is_punctuation(.comma)) trailing = 1;
        if (token.is_punctuation(.semicolon)) trailing = 1;
    }

    assert(found.start > 0);

    const width = span.printed_columns(emitter, found.start - 1, frame.close) + trailing;
    return found.level * emitter.options.indent_width + width <= emitter.options.line_width;
}

fn union_angle_led(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = span.union_of(emitter, position) orelse return false;
    if (!union_listed(emitter, held.open)) return false;
    return held.head == position;
}

pub fn union_angle_framed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const held = span.union_of(emitter, position) orelse return false;
    if (!union_listed(emitter, held.open)) return false;

    for (held.bars[0..held.count]) |bar| {
        if (bar == position) return true;
    }

    return false;
}

pub fn union_angle_item(emitter: *const Emitter, comma: u32) bool {
    assert(comma < emitter.count);

    if (emitter.depth == 0) {
        if (emitter.typed) return false;
    }

    if (!emitter.tokens[comma].is_punctuation(.comma)) return false;
    return union_angle_list(emitter, comma) != null;
}

fn union_angle_list(emitter: *const Emitter, comma: u32) ?u32 {
    assert(comma < emitter.count);

    const angles = emitter.brackets.angles_at(comma);
    if (angles == 0) return null;

    const depth = angles - 1;
    var scan = comma;

    for (0..union_list_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return null;
        const kind = emitter.tokens[held].kind;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (closes) {
            scan = emitter.brackets.open_of(held) orelse return null;

            continue;
        }

        const opened = walk.is_open(kind) or kind == .block_start;
        if (opened) return null;

        const angled = emitter.brackets.angles_at(held) == depth and spelled(emitter, held, "<");

        if (angled) {
            if (join.angle_generic(emitter, held)) return held;
            return null;
        }

        scan = held;
    }

    return null;
}

pub fn union_angled(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (!spelled(emitter, open, "<")) return false;
    if (!join.angle_generic(emitter, open)) return false;

    const close = join.angle_close(emitter, open) orelse return false;
    if (union_angled_broken(emitter, open, close)) return false;
    if (union_angled_braced(emitter, open, close)) return true;
    return !union_angle_returned(emitter, open);
}

fn union_angled_braced(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);

    var depth: u32 = 0;
    var scan = open + 1;
    var braced = false;

    while (scan < close) {
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            if (depth == 0) {
                if (kind == .block_start) braced = true;
            }

            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else {}

        scan += 1;
    }

    return braced;
}

fn union_angled_breaks(emitter: *const Emitter, scan: u32, angles: u32) bool {
    assert(scan < emitter.count);

    if (emitter.tokens[scan].is_punctuation(.comma)) {
        if (emitter.brackets.angles_at(scan) == angles) return true;
    }

    const text = emitter.tokens[scan].text(emitter.source);
    return walk.text_is(text, "extends") or walk.text_is(text, "=");
}

fn union_angled_broken(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);

    const angles = emitter.brackets.angles_at(open) + 1;
    var depth: u32 = 0;
    var scan = open + 1;

    while (scan < close) {
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            if (union_angled_breaks(emitter, scan, angles)) return true;
        } else {}

        scan += 1;
    }

    return false;
}

fn union_angle_returned(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    var scan = open;

    for (0..union_list_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;
        const token = emitter.tokens[held];
        const chained = token.kind == .identifier or emit.is_dot(emitter, held);

        if (chained) {
            scan = held;

            continue;
        }

        if (spelled(emitter, held, "=>")) return true;
        if (!token.is_punctuation(.colon)) return false;

        const before = emit.back_of(emitter, held) orelse return false;
        return emitter.tokens[before].is_punctuation(.paren_close);
    }

    return false;
}

pub fn union_arrow_head(emitter: *const Emitter, scan: u32, head: u32) bool {
    assert(head < emitter.count);

    if (scan != head) return false;

    const held = emit.back_of(emitter, head) orelse return false;
    return union_arrow_type(emitter, held);
}

pub fn union_arrow_type(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (!spelled(emitter, position, "=>")) return false;

    const after = emit.ahead_of(emitter, position) orelse return false;
    if (!emit.roled(emitter, after, brace.role_type)) return false;

    const close = emit.back_of(emitter, position) orelse return false;
    if (!emitter.tokens[close].is_punctuation(.paren_close)) return false;

    const open = emitter.brackets.open_of(close) orelse return false;
    return emit.ahead_of(emitter, open) == close;
}

pub fn union_defaulted(emitter: *const Emitter, open: u32, equals: u32) ?u32 {
    assert(open < emitter.count);
    assert(equals < emitter.count);

    if (emitter.depth == 0) return null;
    if (!span.union_frame(emitter, open).kind.eql(.{ .punctuation = .paren_open })) return null;

    var last = equals;

    for (0..union_default_max) |_| {
        const next = emit.ahead_of(emitter, last) orelse return null;
        const kind = emitter.tokens[next].kind;
        const token = emitter.tokens[next];

        const ended = kind == .block_end or token.is_punctuation(.comma) or
            token.is_punctuation(.paren_close) or token.is_punctuation(.semicolon);

        if (ended) {
            const separated = token.is_punctuation(.comma) or token.is_punctuation(.semicolon);
            const columns = span.printed_columns(emitter, equals, last);
            const returned = 1 + columns + @intFromBool(separated);

            assert(returned < std.math.maxInt(u32));

            return returned;
        }

        const opened = walk.is_open(kind) or kind == .block_start;
        if (opened) return union_defaulted_head(emitter, next, equals);

        last = next;
    }

    return null;
}

fn union_defaulted_head(emitter: *const Emitter, next: u32, equals: u32) ?u32 {
    assert(next < emitter.count);
    assert(equals < emitter.count);

    if (emitter.tokens[next].is_punctuation(.paren_open)) {
        if (!list.calling(emitter, next)) return null;
    }

    const returned = 1 + span.printed_columns(emitter, equals, next);

    assert(returned < std.math.maxInt(u32));

    return returned;
}

pub fn union_listed(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (union_angled(emitter, open)) return true;
    return union_angle_item(emitter, open);
}

pub fn union_binder(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);

    const held = emit.back_of(emitter, open) orelse return null;
    const questioned = spelled(emitter, held, "?") and tern.optional(emitter, held);
    if (questioned) return emit.back_of(emitter, held);
    return held;
}

pub fn union_arrowed(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (emitter.depth == 0) return false;
    if (core.memo_found(emitter, .union_arrowed, open, 0)) |answer| return answer == 1;

    const frame = span.union_frame(emitter, open);

    const arrowed = !span.type_framed(emitter, frame.open) and frame.open < open and
        union_arrowed_scan(emitter, frame.open, open);

    core.memo_store(emitter, .union_arrowed, open, 0, @intFromBool(arrowed));

    return arrowed;
}

fn union_arrowed_scan(emitter: *const Emitter, start: u32, open: u32) bool {
    assert(start < open);

    var depth: u32 = 0;
    var scan = union_member_start(emitter, start, open);

    while (scan < open) {
        if (call.spanned_body(emitter, scan)) |end| {
            if (end < open) {
                scan = end + 1;

                continue;
            }
        }

        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            if (spelled(emitter, scan, "=>")) return true;
        } else {}

        scan += 1;
    }

    return false;
}

pub fn union_casted(emitter: *const Emitter, head: u32, bar: u32) bool {
    assert(head <= bar);
    assert(bar <= emitter.count);

    var depth: u32 = 0;
    var scan = head;

    while (scan < bar) {
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            if (line.group_word(emitter, scan)) return true;
        } else {}

        scan += 1;
    }

    return false;
}

pub fn union_fits(
    emitter: *const Emitter,
    open: u32,
    head: u32,
    bars: *const [span.union_member_max]u32,
    count: u32,
    stop: u32,
) bool {
    assert(head <= stop);
    assert(count <= span.union_member_max);
    assert(open < emitter.count);

    const held: span.Union = .{
        .bars = bars.*,
        .count = count,
        .head = head,
        .lead = null,
        .open = open,
        .stop = stop,
    };

    _, const seat = span.union_seat(emitter, &held);
    const level = seat + 1;
    const used = level * emitter.options.indent_width + bar_columns;
    const room = emitter.options.line_width -| used;

    return union_fits_scan(emitter, held, room);
}

fn union_fits_scan(emitter: *const Emitter, held: span.Union, room: u32) bool {
    assert(held.count <= span.union_member_max);
    assert(room < std.math.maxInt(u32));

    var from = held.head;
    var index: u32 = 0;

    while (index <= held.count) {
        const to = union_fits_to(emitter, held, index) orelse return false;
        if (from > to) return false;
        if (!union_fits_width(emitter, from, to, room)) return false;

        const next = union_fits_step(emitter, to) orelse break;

        from = next;
        index += 1;
    }

    return true;
}

fn union_fits_to(emitter: *const Emitter, held: span.Union, index: u32) ?u32 {
    assert(index <= held.count);

    if (index == held.count) return held.stop;
    return comment.back(emitter, held.bars[index]);
}

fn union_fits_width(emitter: *const Emitter, from: u32, to: u32, room: u32) bool {
    assert(from <= to);

    if (union_fits_braced(emitter, from, to)) return true;
    if (union_fits_enclosed(emitter, from, to)) return true;
    if (union_objected(emitter, from, to)) return true;
    return span.printed_columns(emitter, from, to) + span.union_columns(emitter, from, to) <= room;
}

fn union_fits_braced(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from <= to);

    if (emitter.tokens[from].kind != .block_start) return false;
    if (emitter.tokens[to].kind == .block_end) return true;
    return emitter.tokens[to].is_punctuation(.bracket_close);
}

fn union_fits_enclosed(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from <= to);

    var scan = from;

    while (scan <= to) {
        if (emitter.tokens[scan].kind == .block_start) return true;

        scan += 1;
    }

    return false;
}

fn union_fits_step(emitter: *const Emitter, to: u32) ?u32 {
    assert(to < emitter.count);

    const bar = line.coding(emitter, to) orelse return null;
    return line.coding(emitter, bar);
}

fn union_objected(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from <= to);

    if (!emitter.tokens[from].is_punctuation(.paren_open)) return false;
    if (join.closing_of(emitter, from) != to) return false;

    var scan = from;

    while (scan < to) {
        if (emitter.tokens[scan].kind == .block_start) return true;

        scan += 1;
    }

    return false;
}

fn union_barred(emitter: *const Emitter, position: u32, stop: u32) bool {
    assert(position < emitter.count);

    if (!spelled(emitter, position, "|")) return false;

    const part = union_parted(emitter, position) orelse return false;
    if (part != .bar) return false;

    const held = span.union_of(emitter, position) orelse return false;
    return held.stop == stop;
}

pub fn union_broken(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const part = union_parted(emitter, position);

    if (part != null) assert(emitter.policy.union_parts);

    return part != null;
}

pub fn union_comment_broken(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (emitter.tokens[position].kind != .comment) return false;
    if (!body.parts_at(emitter, previous, position)) return false;

    const bar = line.coding(emitter, position) orelse return false;

    assert(bar > position);

    if (!union_broken(emitter, bar)) return false;

    const held = span.union_of(emitter, bar) orelse return false;

    for (held.bars[0..held.count]) |found| {
        if (found == bar) return true;
    }

    return false;
}

pub fn union_angle_comment_broken(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (emitter.tokens[position].kind != .comment) return false;

    const bar = line.coding(emitter, position) orelse return false;
    const held = span.union_of(emitter, bar) orelse return false;

    assert(bar > position);

    if (!union_listed(emitter, held.open)) return false;
    if (!union_comment_broken(emitter, position, previous)) return false;
    return held.head < position;
}

pub fn union_cast_headed(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.union_grouped <= union_group_max);

    var open = emit.back_of(emitter, head) orelse return false;
    if (spelled(emitter, open, "|")) open = emit.back_of(emitter, open) orelse return false;

    const opening = emitter.tokens[open].text(emitter.source);
    const colon = walk.text_is(opening, ":");

    const seated = words_contain(cast_heads, opening) or
        (colon and setter_annotated(emitter, open)) or
        (colon and tern.return_colon(emitter, open));

    if (!seated) return false;

    const held = union_grouping(emitter, head) orelse return false;
    return held[1];
}

pub fn union_cast_joined(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (union_cast_headed(emitter, position)) return true;
    if (!union_group_bar(emitter, position)) return false;

    assert(emitter.union_grouped > 0);

    return union_cast_headed(emitter, emitter.union_groups[emitter.union_grouped - 1].head);
}

pub fn union_dealigns(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position <= emitter.count);

    while (emitter.union_stopped > 0) {
        const stop = emitter.union_stops[emitter.union_stopped - 1];
        const barred = union_dealign_barred(emitter, position, stop);

        if (position <= stop) {
            if (!barred) break;
        }

        emitter.union_stopped -= 1;

        try emitter.document.push(.dealign);

        if (barred) break;
    }

    assert(emitter.union_stopped <= core.union_align_max);
}

fn union_dealign_barred(emitter: *const Emitter, position: u32, stop: u32) bool {
    assert(position <= emitter.count);
    assert(stop < emitter.count);

    if (position > stop) return false;
    if (union_barred(emitter, position, stop)) return true;
    if (emitter.tokens[position].kind != .comment) return false;

    const held = line.coding(emitter, position) orelse return false;
    return union_barred(emitter, held, stop);
}

pub fn union_dropped(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = span.union_of(emitter, position) orelse {
        if (union_leading(emitter, position)) return true;
        return union_group_lead(emitter, position);
    };

    if (held.lead != position) return false;
    return !span.union_wide(emitter, &held);
}

pub fn union_gap(emitter: *Emitter, position: u32) error{Overflow}!bool {
    assert(position < emitter.count);

    if (emitter.line_start) return false;
    if (try intersect_gap(emitter, position)) return true;

    const grouped = union_group_bar(emitter, position) or union_group_comment(emitter, position);

    if (grouped) {
        try emitter.document.push(.dealign);
        try emitter.document.push(.line);

        return true;
    }

    if (declare_group_item(emitter, position)) {
        try emitter.document.push(.line);

        return true;
    }

    if (decorator_gap(emitter, position)) |expanded| {
        if (expanded) try emitter.document.push(.broken);

        try emitter.document.push(.line);

        return true;
    }

    if (union_paren_grouping(emitter, position)) |stop| {
        try union_group_parenthesized(emitter, position, stop);

        return true;
    }

    if (constraint_grouping(emitter, position)) |stop| {
        emitter.constraint_owed = stop;

        try emitter.document.push(.group_open);
        try line.opens_broken(emitter);
        try emitter.document.push(.line);
        try emitter.document.push(.group_close);

        return true;
    }

    const stop, const indented = union_grouping(emitter, position) orelse return false;

    if (!indented) return false;

    try union_group_opened(emitter, position, stop, true);

    return true;
}

pub fn union_group_bar(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.union_grouped <= union_group_max);

    if (emitter.union_grouped == 0) return false;
    if (!spelled(emitter, position, "|")) return false;

    const group = emitter.union_groups[emitter.union_grouped - 1];
    if (group.declared) return false;
    if (position <= group.head) return false;
    if (position > group.stop) return false;
    if (emitter.depth != group.depth) return false;
    return emitter.brackets.angles_at(position) == group.angles;
}

pub fn union_group_holds(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.union_grouped <= union_group_max);

    if (emitter.union_grouped == 0) return false;

    const group = emitter.union_groups[emitter.union_grouped - 1];
    if (group.declared) return false;
    if (position <= group.head) return false;
    if (position > group.stop) return false;
    if (emitter.depth != group.depth) return false;
    return emitter.brackets.angles_at(position) == group.angles;
}

fn union_group_comment(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.union_grouped <= union_group_max);

    if (emitter.tokens[position].kind != .comment) return false;

    const previous = emit.back_of(emitter, position) orelse return false;
    const bar = line.coding(emitter, position) orelse return false;

    assert(previous < position);
    assert(bar > position);

    if (!body.parts_at(emitter, previous, position)) return false;
    return union_group_bar(emitter, bar);
}

fn union_group_commented_members(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head <= stop);
    assert(stop < emitter.count);

    const angles = emitter.brackets.angles_at(head);
    var depth: u32 = 0;
    var scan = head;

    while (scan < stop) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (kind == .comment) {
                if (union_member_comment(emitter, scan, stop, angles)) return true;
            }
        } else {}
    }

    return false;
}

fn union_member_comment(emitter: *const Emitter, comment_at: u32, stop: u32, angles: u32) bool {
    assert(comment_at < stop);
    assert(emitter.tokens[comment_at].kind == .comment);

    const previous = emit.back_of(emitter, comment_at) orelse return false;
    const bar = line.coding(emitter, comment_at) orelse return false;
    if (bar > stop) return false;
    if (!spelled(emitter, bar, "|")) return false;
    if (emitter.brackets.angles_at(bar) != angles) return false;
    return body.parts_at(emitter, previous, comment_at);
}

fn union_group_declared(emitter: *Emitter, position: u32, stop: u32) error{Overflow}!void {
    assert(position < stop);
    assert(emitter.union_grouped < union_group_max);

    emitter.union_groups[emitter.union_grouped] = .{
        .stop = stop,
        .depth = emitter.depth,
        .angles = emitter.brackets.angles_at(position),
        .indented = false,
        .head = position,
        .declared = true,
    };

    emitter.union_grouped += 1;

    try emitter.document.push(.group_open);
}

fn union_group_lead(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (!spelled(emitter, position, "|")) return false;

    const head = line.coding(emitter, position) orelse return false;

    assert(head > position);

    if (union_grouping(emitter, head) != null) return true;
    if (union_paren_grouping(emitter, head) != null) return true;
    return union_tuple_grouping(emitter, head) != null;
}

pub fn union_group_opens(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.union_grouped <= union_group_max);

    if (emitter.union_grouped > 0) {
        if (emitter.union_groups[emitter.union_grouped - 1].head == position) return;
    }

    if (emit.back_of(emitter, position)) |held| {
        if (union_group_bar(emitter, held)) try emitter.document.push(.@"align");
    }

    if (declare_grouping(emitter, position)) |stop| {
        return union_group_declared(emitter, position, stop);
    }

    if (union_tuple_grouping(emitter, position)) |stop| {
        return union_group_tupled(emitter, position, stop);
    }

    if (decorated_param(emitter, position)) |stop| {
        return union_group_declared(emitter, position, stop);
    }

    const head = union_group_commented(emitter, position) orelse position;

    if (head != position) {
        if (emitter.union_grouped > 0) {
            if (emitter.union_groups[emitter.union_grouped - 1].head == head) return;
        }
    }

    const stop, const indented = union_grouping(emitter, head) orelse return;

    if (indented) return;
    return union_group_opened(emitter, head, stop, false);
}

fn union_group_commented(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.tokens[position].kind != .comment) return null;

    const before = emit.back_of(emitter, position) orelse return null;
    if (!spelled(emitter, before, "|")) return null;

    const head = line.coding(emitter, position) orelse return null;

    assert(head > position);

    return head;
}

pub fn union_grouping(emitter: *const Emitter, head: u32) ?struct { u32, bool } {
    assert(head < emitter.count);
    assert(emitter.union_grouped <= union_group_max);

    if (!emitter.policy.union_parts) return null;
    if (emitter.union_grouped == union_group_max) return null;
    if (spelled(emitter, head, "|")) return null;
    if (emitter.tokens[head].kind == .comment) return null;

    const before = join.coded_before(emitter, head) orelse return null;
    var open = before;
    if (spelled(emitter, before, "|")) open = join.coded_before(emitter, before) orelse return null;

    const opening = emitter.tokens[open].text(emitter.source);
    const cast_worded = words_contain(cast_words, opening) and !line.word_named(emitter, open);
    const casted = cast_worded or union_grouping_returns(emitter, head, opening, open);
    if (casted) return union_group_indented(emitter, head, true);

    if (union_grouping_seated(emitter, head, opening, open)) {
        return union_group_indented(emitter, head, false);
    }

    return union_grouping_listed(emitter, head, opening, open);
}

fn union_grouping_returns(emitter: *const Emitter, head: u32, opening: []const u8, open: u32) bool {
    assert(open < head);

    if (!walk.text_is(opening, "=>")) return false;
    if (!emit.roled(emitter, head, brace.role_type)) return false;
    return !returned_type(emitter, open);
}

fn union_grouping_seated(emitter: *const Emitter, head: u32, opening: []const u8, open: u32) bool {
    assert(open < head);
    assert(opening.len <= std.math.maxInt(u32));

    const branched = emit.roled(emitter, head, brace.role_type) and
        union_grouping_branched(emitter, opening, open);

    if (branched) return true;
    if (union_grouping_returned(emitter, opening, open)) return true;
    return walk.text_is(opening, ":") and setter_annotated(emitter, open);
}

fn union_grouping_branched(emitter: *const Emitter, opening: []const u8, open: u32) bool {
    assert(open < emitter.count);
    assert(opening.len <= std.math.maxInt(u32));

    if (walk.text_is(opening, "?")) return !tern.optional(emitter, open);
    if (walk.text_is(opening, ":")) return tern.ternary(emitter, open);
    return false;
}

fn union_grouping_returned(emitter: *const Emitter, opening: []const u8, open: u32) bool {
    assert(open < emitter.count);

    if (span.predicate_colon_of(emitter, open)) |colon| return tern.return_colon(emitter, colon);
    if (!walk.text_is(opening, ":")) return false;
    if (!tern.return_colon(emitter, open)) return false;
    return !span.predicate_colon(emitter, open);
}

fn union_grouping_listed(
    emitter: *const Emitter,
    head: u32,
    opening: []const u8,
    open: u32,
) ?struct { u32, bool } {
    assert(open < head);
    assert(opening.len <= std.math.maxInt(u32));

    const found: struct { u32, bool } = listed: {
        if (walk.text_is(opening, "extends")) {
            break :listed union_grouping_extended(emitter, open) orelse return null;
        }

        break :listed .{ union_group_list(emitter, open) orelse return null, false };
    };

    const angled, const indented = found;
    const close = join.angle_close(emitter, angled) orelse return null;
    if (!angle_closes_at(emitter, close)) return null;
    if (span.union_of(emitter, head) != null) return null;

    const bars, const members, const count, const stop =
        span.union_bars(emitter, head, false) orelse return null;

    if (span.union_hugs(emitter, head, &bars, count, stop)) return null;

    const braced = members and !join.angle_generic(emitter, angled);
    if (braced) return null;
    if (union_group_conditional(emitter, head, stop)) return null;
    return .{ stop, indented };
}

fn union_grouping_extended(emitter: *const Emitter, open: u32) ?struct { u32, bool } {
    assert(open < emitter.count);

    const name = emit.back_of(emitter, open) orelse return null;
    if (emitter.tokens[name].kind != .identifier) return null;

    const before = emit.back_of(emitter, name) orelse return null;
    const angled = union_group_list(emitter, before) orelse return null;

    return .{ angled, true };
}

pub fn union_groups_close(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position <= emitter.count);
    assert(emitter.union_grouped <= union_group_max);

    while (emitter.union_grouped > 0) {
        const group = emitter.union_groups[emitter.union_grouped - 1];
        if (group.stop >= position) break;

        emitter.union_grouped -= 1;

        const parenthesized = group.indented and
            union_paren_grouping(emitter, group.head) == group.stop;

        const tupled = group.indented and !parenthesized and
            union_tuple_grouping(emitter, group.head) == group.stop;

        const softened = parenthesized or tupled;

        if (!group.declared) try emitter.document.push(.dealign);
        if (group.indented) try line.closes_broken(emitter);
        if (softened) try emitter.document.push(.soft_line);
        if (tupled) try emitter.document.push(.{ .if_broken = emitter.closing });

        try emitter.document.push(.group_close);
    }
}

pub fn union_joined(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = span.union_of(emitter, position) orelse return false;
    const leads = position == held.head or held.lead == position;

    if (leads) {
        if (union_joined_commented(emitter, position)) return false;
    } else {
        if (!bars_contain(emitter, &held, position)) return false;
    }

    return !span.union_wide(emitter, &held);
}

fn union_joined_commented(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const commented = emit.back_of(emitter, position) orelse return false;
    const token = emitter.tokens[commented];
    if (token.kind != .comment) return false;
    if (!std.mem.startsWith(u8, token.text(emitter.source), "/*")) return false;
    if (!body.parts_at(emitter, commented, position)) return false;

    const before = emit.back_of(emitter, commented) orelse return false;
    return body.parts_at(emitter, before, commented);
}

pub fn union_leads(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.union_stopped <= core.union_align_max);

    const led = emitter.starting or union_angle_led(emitter, position);
    if (!led) return;

    const part = union_parted(emitter, position) orelse return;
    if (part != .lead) return;

    const offset = emitter.arena.count();

    try emitter.arena.push(core.bar_lead);

    const pushed: Span = .{ .offset = offset, .length = emitter.arena.count() - offset };

    assert(pushed.length == core.bar_lead.len);

    try emitter.document.push(.{ .text = .{ .source = .arena, .span = pushed } });
    try union_opens(emitter, position);
}

fn union_leading(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.union_parts) return false;
    if (!spelled(emitter, position, "|")) return false;

    const open = span.union_open(emitter, position) orelse return false;
    if (line.coding(emitter, open) != position) return false;
    if (!span.union_typed(emitter, open)) return false;

    const head = line.coding(emitter, position) orelse return false;

    assert(head > position);

    return span.union_bars(emitter, head, false) == null;
}

fn union_level_opens(emitter: *const Emitter, held: *const span.Union) u32 {
    assert(held.open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const listed = union_level_listed(emitter, held);
    const open = if (listed) span.union_frame(emitter, held.open).open else held.open;
    var cast = held.open;

    if (emitter.tokens[held.open].is_punctuation(.paren_open)) {
        cast = emit.back_of(emitter, held.open) orelse held.open;
    }

    if (link.chain_cast_head(emitter, cast)) |head| {
        return span.line_opened(emitter, head) orelse head;
    }

    if (union_return_paren(emitter, held.open)) |paren| {
        return span.line_opened(emitter, paren) orelse paren;
    }

    return span.line_opened(emitter, open) orelse open;
}

fn union_level_listed(emitter: *const Emitter, held: *const span.Union) bool {
    assert(held.open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return false;

    const frame = span.union_frame(emitter, held.open);
    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return false;
    if (frame.spread == null) return false;
    if (frame.open >= held.open) return false;
    return !union_listed(emitter, held.open);
}

pub fn union_return_paren(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const anchor = span.union_anchor(emitter, open);

    assert(anchor < emitter.count);

    if (!emitter.tokens[anchor].is_punctuation(.colon)) return null;

    const close = emit.back_of(emitter, anchor) orelse return null;
    if (!emitter.tokens[close].is_punctuation(.paren_close)) return null;

    const paren = emitter.brackets.open_of(close) orelse return null;
    const opens = span.line_opened(emitter, open) orelse return null;
    if (opens <= paren) return null;
    return paren;
}

pub fn union_level(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.union_parts) return null;

    _ = union_parted(emitter, position) orelse return null;

    const held = span.union_of(emitter, position) orelse return null;
    const opens = union_level_opens(emitter, &held);
    const level = union_member_level(emitter, &held, opens);
    if (union_listed(emitter, held.open)) return level;

    if (intersect_chained(emitter, held.open)) |chained| {
        assert(chained + 2 < std.math.maxInt(u32));

        return chained + 2;
    }

    assert(level + 1 < std.math.maxInt(u32));

    return level + 1;
}

pub fn union_item_level(emitter: *const Emitter, frame: core.Frame, opens: u32) ?u32 {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(frame.open < emitter.count);

    var index: ?u32 = null;

    for (0..emitter.depth) |at| {
        if (emitter.nest[at].open == frame.open) {
            index = @intCast(at);

            break;
        }
    }

    const found = index orelse return null;
    if (found == 0) return null;

    const outer = emitter.nest[found - 1];

    const itemed = outer.kind.eql(.{ .punctuation = .paren_open }) and
        outer.spread != null and
        outer.hugged == 0;

    if (!itemed) return null;
    if (list.param_hugs(emitter, outer.open, outer.close)) return null;
    if (opens >= call.argument_start(emitter, outer.open, frame.open)) return null;
    assert(frame.held + 1 < std.math.maxInt(u32));

    return frame.held + 1;
}

fn union_member_level(emitter: *const Emitter, held: *const span.Union, opens: u32) u32 {
    assert(held.open < emitter.count);
    assert(opens < emitter.count);

    const ringed = line.level_at(emitter, opens) orelse emitter.levels;
    if (emitter.depth == 0) return ringed;

    const frame = span.union_frame(emitter, held.open);

    if (!union_member_listed(&frame)) {
        if (frame.kind != .block_start) return ringed;
        if (frame.spread == null) return ringed;
        if (!span.union_membered(emitter, &frame)) return ringed;
    }

    if (frame.open >= held.open) return ringed;
    if (opens >= union_member_start(emitter, frame.open, held.open)) return ringed;
    return frame.inset;
}

fn union_member_listed(frame: *const core.Frame) bool {
    assert(frame.kind != .block_end);
    assert(frame.kind != .newline);

    const opened = frame.kind.eql(.{ .punctuation = .paren_open }) or
        frame.kind.eql(.{ .punctuation = .bracket_open });

    if (!opened) return false;
    if (frame.spread == null) return false;
    return frame.hugged == 0;
}

pub fn union_return_breaks(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(spelled(emitter, open, "<"));

    if (join.angle_return_wide(emitter, open)) return true;
    return union_return_expanded(emitter, open);
}

fn union_return_expanded(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const close = join.angle_close(emitter, open) orelse return false;
    const coded = emit.ahead_of(emitter, open) orelse return false;
    const barred = spelled(emitter, coded, "|");
    const led = if (barred) emit.ahead_of(emitter, coded) else coded;
    const head = led orelse return false;
    if (head >= close) return false;

    const found = span.union_bars(emitter, head, false) orelse return false;
    const bars, _, const count, const stop = found;

    assert(count > 0);

    if (stop >= close) return false;
    if (span.union_hugs(emitter, head, &bars, count, stop)) return false;
    return union_brace_expanded(emitter, head, stop);
}

pub fn angle_return_expanded(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(spelled(emitter, open, "<"));

    const close = join.angle_close(emitter, open) orelse return false;
    const head = emit.ahead_of(emitter, open) orelse return false;
    if (head >= close) return false;
    if (join.angle_hugged(emitter, head, close)) return false;
    return union_brace_expanded(emitter, head, close);
}

pub fn union_brace_expanded(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head < emitter.count);
    assert(stop < emitter.count);

    return union_expanded_scan(emitter, head, stop, false);
}

pub fn union_expanded(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head < emitter.count);
    assert(stop < emitter.count);

    return union_expanded_scan(emitter, head, stop, true);
}

fn union_expanded_scan(emitter: *const Emitter, head: u32, stop: u32, comments: bool) bool {
    assert(head < emitter.count);
    assert(stop < emitter.count);

    var depth: u32 = 0;
    var scan = head;

    while (scan <= stop) {
        const kind = emitter.tokens[scan].kind;

        if (kind != .block_start) {
            if (comments) {
                if (union_expanded_commented(emitter, scan, depth)) return true;
            }

            if (walk.is_open(kind)) {
                depth += 1;
            } else if (walk.is_close(kind)) {
                depth -|= 1;
            } else {}

            scan += 1;

            continue;
        }

        if (depth > 0) {
            scan += 1;

            continue;
        }

        const close = join.closing_of(emitter, scan) orelse return false;

        assert(close > scan);

        if (union_expanded_parted(emitter, scan, close)) return true;

        scan = close + 1;
    }

    return false;
}

pub fn union_commented(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head < emitter.count);
    assert(stop < emitter.count);

    var depth: u32 = 0;
    var scan = head;

    while (scan <= stop) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;

        if (union_expanded_commented(emitter, scan, depth)) {
            const held = emit.ahead_of(emitter, scan) orelse return false;
            if (held <= stop) return true;
        }

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else {}
    }

    return false;
}

fn union_expanded_commented(emitter: *const Emitter, scan: u32, depth: u32) bool {
    assert(scan < emitter.count);
    assert(depth <= emitter.count);

    if (depth > 0) return false;
    if (emitter.tokens[scan].kind != .comment) return false;

    const held = emit.ahead_of(emitter, scan) orelse return false;
    return body.parts_at(emitter, scan, held);
}

fn union_expanded_parted(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const held = emit.ahead_of(emitter, open) orelse return false;
    if (held >= close) return false;
    return body.parts_at(emitter, open, held);
}

pub fn union_member_joined(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);
    assert(emitter.union_grouped <= union_group_max);

    if (!spelled(emitter, previous, "|")) return false;

    if (union_parted(emitter, previous)) |part| {
        if (part == .bar) return true;
    }

    return union_group_bar(emitter, previous);
}

pub fn union_paren_grouping(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(emitter.union_grouped <= union_group_max);

    if (!emitter.policy.union_parts) return null;
    if (emitter.union_grouped == union_group_max) return null;
    if (spelled(emitter, head, "|")) return null;
    if (emitter.tokens[head].kind == .comment) return null;

    const before = emit.back_of(emitter, head) orelse return null;
    var open = before;
    if (spelled(emitter, before, "|")) open = emit.back_of(emitter, before) orelse return null;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return null;
    if (!emit.roled(emitter, open, brace.role_type)) return null;

    const close = join.closing_of(emitter, open) orelse return null;
    if (return_paren_whole(emitter, open, close)) return null;

    const bars, const braced, const count, const stop =
        span.union_bars(emitter, head, false) orelse return null;

    if (count == 0) return null;

    const intersected = union_paren_intersected(emitter, open, close);
    const weak = braced and !intersected;
    if (weak) return null;
    return union_paren_grouping_tail(emitter, head, open, close, &bars, count, stop);
}

fn union_paren_grouping_tail(
    emitter: *const Emitter,
    head: u32,
    open: u32,
    close: u32,
    bars: *const [span.union_member_max]u32,
    count: u32,
    stop: u32,
) ?u32 {
    assert(open < close);
    assert(count > 0);

    if (emit.ahead_of(emitter, stop) != close) return null;
    if (union_group_conditional(emitter, head, stop)) return null;
    if (span.union_hugs(emitter, head, bars, count, stop)) return null;
    if (!union_paren_needed(emitter, open, close)) return null;
    return stop;
}

fn union_paren_intersected(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var anded: ?u32 = null;

    if (emit.back_of(emitter, open)) |held| {
        if (spelled(emitter, held, "&")) anded = held;
    }

    var chained = false;

    if (anded) |ampersand| {
        if (emit.back_of(emitter, ampersand)) |held| {
            chained = emitter.tokens[held].kind == .block_end;
        }
    }

    if (chained) return false;
    if (anded != null) return true;

    const after = emit.ahead_of(emitter, close) orelse return false;
    return spelled(emitter, after, "&");
}

fn union_paren_needed(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);

    if (emit.ahead_of(emitter, close)) |held| {
        const text = emitter.tokens[held].text(emitter.source);
        const reached = walk.text_is(text, "[") or walk.text_is(text, "&");
        if (reached) return true;
    }

    if (emit.back_of(emitter, open)) |held| {
        if (spelled(emitter, held, "&")) return true;
    }

    return tuple_element(emitter, open, close);
}

fn return_paren_whole(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const colon = emit.back_of(emitter, open) orelse return false;
    if (!emitter.tokens[colon].is_punctuation(.colon)) return false;

    const end = emit.back_of(emitter, colon) orelse return false;
    if (!emitter.tokens[end].is_punctuation(.paren_close)) return false;

    const start = emitter.brackets.open_of(end) orelse return false;
    if (emit.ahead_of(emitter, start) == end) return false;

    var after = emit.ahead_of(emitter, close);

    for (0..array_suffix_max) |_| {
        const held = after orelse break;
        if (!emitter.tokens[held].is_punctuation(.bracket_open)) break;

        const shut = join.closing_of(emitter, held) orelse break;

        after = emit.ahead_of(emitter, shut);
    }

    const held = after orelse return false;
    const kind = emitter.tokens[held].kind;
    const ended = kind == .block_start or kind.eql(.{ .punctuation = .semicolon });
    if (ended) return true;
    return spelled(emitter, held, "=>");
}

fn tuple_element(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const before = emit.back_of(emitter, open) orelse return false;
    var enclosing: ?u32 = null;

    if (emitter.tokens[before].is_punctuation(.bracket_open)) enclosing = before;

    if (emitter.tokens[before].is_punctuation(.comma)) {
        enclosing = bind.enclosing_open(emitter, before);
    }

    const tuple = enclosing orelse return false;
    if (!emitter.tokens[tuple].is_punctuation(.bracket_open)) return false;
    if (!emit.roled(emitter, tuple, brace.role_type)) return false;

    const end = join.closing_of(emitter, tuple) orelse return false;
    if (tuple_count(emitter, tuple, end) <= 1) return false;

    const after = emit.ahead_of(emitter, close) orelse return false;
    return after == end or emitter.tokens[after].is_punctuation(.comma);
}

fn tuple_count(emitter: *const Emitter, open: u32, close: u32) u32 {
    var elements: u32 = 1;
    var depth: u32 = 0;
    var angles: u32 = 0;

    assert(open < close);
    assert(close < emitter.count);

    for (open + 1..close) |scan| {
        const token = emitter.tokens[scan];
        const text = token.text(emitter.source);
        const opens = walk.is_open(token.kind) or token.kind == .block_start;
        const closes = walk.is_close(token.kind) or token.kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else {
            if (walk.text_is(text, "<")) {
                angles += 1;
            } else if (angle_run(text)) {
                angles -|= @intCast(text.len);
            } else {}

            const separates = depth == 0 and angles == 0 and token.is_punctuation(.comma);

            if (separates) {
                if (emit.ahead_of(emitter, @intCast(scan)) != close) elements += 1;
            }
        }
    }

    assert(elements >= 1);

    return elements;
}

fn angle_run(text: []const u8) bool {
    if (text.len == 0) return false;

    for (text) |byte| {
        if (byte != '>') return false;
    }

    return true;
}

pub fn union_paren_joined(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.union_grouped <= union_group_max);

    if (spelled(emitter, position, ")")) {
        const open = emitter.brackets.open_of(position) orelse return false;
        return union_parenthesized(emitter, open);
    }

    if (spelled(emitter, position, "|")) {
        if (union_group_lead(emitter, position)) return true;
        if (!union_group_bar(emitter, position)) return false;

        const group = emitter.union_groups[emitter.union_grouped - 1];
        if (!group.indented) return false;
        if (union_paren_grouping(emitter, group.head) == group.stop) return true;
        return union_tuple_grouping(emitter, group.head) == group.stop;
    }

    if (union_paren_grouping(emitter, position) != null) return true;
    return union_tuple_grouping(emitter, position) != null;
}

pub fn union_parenthesized(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    var head = line.coding(emitter, open) orelse return false;
    if (spelled(emitter, head, "|")) head = line.coding(emitter, head) orelse return false;

    assert(head > open);

    return union_paren_grouping(emitter, head) != null;
}

pub fn union_parted(emitter: *const Emitter, position: u32) ?Part {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = span.union_of(emitter, position) orelse return null;
    const leads = position == (held.lead orelse held.head);

    if (!leads) {
        if (!bars_contain(emitter, &held, position)) return null;
    }

    if (!span.union_wide(emitter, &held)) return null;

    if (leads) {
        if (held.lead == null) return .lead;
    }

    return .bar;
}

fn union_tuple_grouping(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(emitter.union_grouped <= union_group_max);

    if (!emitter.policy.union_parts) return null;
    if (emitter.union_grouped == union_group_max) return null;

    if (core.memo_found(emitter, .union_tuple_grouping, head, 0)) |answer| {
        return if (answer == core.memo_none) null else answer;
    }

    const stop = union_tuple_stop(emitter, head);

    core.memo_store(emitter, .union_tuple_grouping, head, 0, stop orelse core.memo_none);

    return stop;
}

fn union_tuple_stop(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(emitter.policy.union_parts);

    if (spelled(emitter, head, "|")) return null;
    if (emitter.tokens[head].kind == .comment) return null;
    if (!emit.roled(emitter, head, brace.role_type)) return null;

    var first = head;

    if (emit.back_of(emitter, head)) |held| {
        if (spelled(emitter, held, "|")) first = held;
    }

    const bars, const braced, const count, const stop =
        span.union_bars(emitter, head, false) orelse return null;

    if (count == 0) return null;
    if (braced) return null;
    if (!tuple_element(emitter, first, stop)) return null;
    if (union_group_conditional(emitter, head, stop)) return null;
    if (span.union_hugs(emitter, head, &bars, count, stop)) return null;
    return stop;
}

pub fn annotation_level(emitter: *const Emitter, assign: u32) ?u32 {
    assert(assign < emitter.count);
    assert(emitter.line_first < emitter.count);

    const head = emitter.line_first;
    const led = spelled(emitter, head, "|") or ampersand_before(emitter, head);
    if (!led) return null;

    const open = span.union_open(emitter, head) orelse return null;
    if (!emitter.tokens[open].is_punctuation(.colon)) return null;
    if (span.union_open(emitter, assign) != open) return null;
    if (!span.union_typed(emitter, open)) return null;

    const opens = span.line_opened(emitter, open) orelse return null;

    assert(opens < emitter.count);

    return line.level_at(emitter, opens);
}

fn ampersand_before(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.back_of(emitter, position) orelse return false;
    return spelled(emitter, held, "&");
}

fn union_group_tupled(emitter: *Emitter, position: u32, stop: u32) error{Overflow}!void {
    assert(emitter.union_grouped < union_group_max);
    assert(position <= stop);

    emitter.union_groups[emitter.union_grouped] = .{
        .stop = stop,
        .depth = emitter.depth,
        .angles = emitter.brackets.angles_at(position),
        .indented = true,
        .head = position,
        .declared = false,
    };

    emitter.union_grouped += 1;

    try emitter.document.push(.group_open);
    try emitter.document.push(.{ .if_broken = emitter.opening });
    try line.opens_broken(emitter);
    try emitter.document.push(.soft_line);
    try emitter.document.push(.{ .if_broken = emitter.bar });
    try emitter.document.push(.@"align");
}

fn union_group_parenthesized(emitter: *Emitter, position: u32, stop: u32) error{Overflow}!void {
    assert(emitter.union_grouped < union_group_max);
    assert(position <= stop);

    emitter.union_groups[emitter.union_grouped] = .{
        .stop = stop,
        .depth = emitter.depth,
        .angles = emitter.brackets.angles_at(position),
        .indented = true,
        .head = position,
        .declared = false,
    };

    emitter.union_grouped += 1;

    try emitter.document.push(.group_open);
    try line.opens_broken(emitter);
    try emitter.document.push(.soft_line);
    try emitter.document.push(.{ .if_broken = emitter.bar });
    try emitter.document.push(.@"align");
}

fn union_group_opened(
    emitter: *Emitter,
    position: u32,
    stop: u32,
    indented: bool,
) error{Overflow}!void {
    assert(emitter.union_grouped < union_group_max);
    assert(position <= stop);

    emitter.union_groups[emitter.union_grouped] = .{
        .stop = stop,
        .depth = emitter.depth,
        .angles = emitter.brackets.angles_at(position),
        .indented = indented,
        .head = position,
        .declared = false,
    };

    emitter.union_grouped += 1;

    try emitter.document.push(.group_open);

    if (union_group_commented_members(emitter, position, stop)) {
        try emitter.document.push(.broken);
    }

    if (indented) {
        try line.opens_broken(emitter);
        try emitter.document.push(.line);
    }

    try emitter.document.push(.{ .if_broken = emitter.bar });
    try emitter.document.push(.@"align");
}

pub fn union_tupled(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (!union_tuple_typed(emitter, open)) return false;

    const frame = span.union_frame(emitter, open);
    return frame.spread != null;
}

pub fn union_tuple_typed(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (emitter.depth == 0) return false;
    if (!emitter.tokens[open].is_punctuation(.colon)) return false;

    const frame = span.union_frame(emitter, open);
    if (!frame.kind.eql(.{ .punctuation = .bracket_open })) return false;
    return emit.roled(emitter, frame.open, brace.role_type);
}

fn angle_ends(emitter: *const Emitter, position: u32, angles: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);
    assert(angles < std.math.maxInt(u32));

    const text = emitter.tokens[position].text(emitter.source);
    if (!closes_angles(text)) return false;

    const closes: u32 = @intCast(text.len);
    return emitter.brackets.angles_at(position) < angles + closes;
}

fn intersect_stop(emitter: *const Emitter, open: u32) ?struct { u32, bool } {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const angles = emitter.brackets.angles_at(open);
    var depth: u32 = 0;
    var forced = false;
    var found = false;
    var ending = open;
    var scan = emit.ahead_of(emitter, open) orelse return null;

    for (0..union_scan_max) |_| {
        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            if (kind == .block_start) forced = forced or call.object_parted(emitter, scan);

            depth += 1;
        } else if (walk.is_close(kind)) {
            if (depth == 0) break;

            depth -= 1;
        } else if (depth == 0) {
            if (emitter.brackets.angles_at(scan) == angles) {
                if (intersect_stop_at(emitter, scan)) break;

                found = found or spelled(emitter, scan, "&");
            }
        } else {}

        ending = scan;
        scan = emit.ahead_of(emitter, scan) orelse break;
    }

    if (emitter.tokens[ending].kind == .comment) {
        const text = emitter.tokens[ending].text(emitter.source);

        if (std.mem.startsWith(u8, text, "//")) {
            ending = join.coded_before(emitter, ending) orelse ending;
        }
    }

    if (!found) return null;
    if (ending <= open) return null;
    return .{ ending, forced };
}

fn intersect_stop_at(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[scan];
    if (token.is_punctuation(.comma)) return true;
    if (token.is_punctuation(.semicolon)) return true;
    if (token.is_punctuation(.assign)) return true;
    if (spelled(emitter, scan, "=>")) return true;
    if (spelled(emitter, scan, "|")) return true;
    return intersect_conditioned(emitter, scan);
}

fn intersect_conditioned(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (spelled(emitter, position, "?")) return !tern.optional(emitter, position);
    if (spelled(emitter, position, ":")) return tern.ternary(emitter, position);
    return false;
}

fn intersect_seat(emitter: *const Emitter, open: u32, position: u32) struct { u32, u32 } {
    assert(open < emitter.count);
    assert(position < emitter.count);

    var seat = open;

    if (emit.ahead_of(emitter, open)) |held| {
        if (emitter.tokens[held].kind == .comment) seat = line.coding(emitter, open) orelse open;
    }

    if (emitter.depth == 0) {
        const from, const level = intersect_seat_lined(emitter, seat);
        const close = intersect_seat_angled(emitter, open, from, level) orelse from;

        return .{ close, level };
    }

    const frame = line.frame(emitter);

    if (intersect_seat_member(emitter, &frame, position)) |head| {
        return .{ head, intersect_seat_level(emitter, frame.open) };
    }

    const parenthesized = frame.kind.eql(.{ .punctuation = .paren_open });
    if (!parenthesized) return intersect_seat_lined(emitter, seat);
    if (frame.spread == null) return intersect_seat_lined(emitter, seat);

    const level = intersect_seat_level(emitter, frame.open);
    return .{ call.argument_start(emitter, frame.open, position), level };
}

fn intersect_seat_lined(emitter: *const Emitter, seat: u32) struct { u32, u32 } {
    assert(seat < emitter.count);
    assert(emitter.line_first < emitter.count);

    const found = line.at(emitter, seat) orelse {
        return .{ emitter.line_first, emitter.printed };
    };

    assert(found.start > 0);

    return .{ found.start - 1, found.level };
}

fn intersect_seat_angled(emitter: *const Emitter, open: u32, from: u32, level: u32) ?u32 {
    assert(open < emitter.count);
    assert(level <= core.line_level_max);

    if (from > open) return null;
    if (!emitter.tokens[open].is_punctuation(.assign)) return null;

    const close = emit.back_of(emitter, open) orelse return null;
    if (!spelled(emitter, close, ">")) return null;

    const angle = tern.angle_opening(emitter, close) orelse return null;
    if (angle < from) return null;

    const ampersand = intersect_first(emitter, open) orelse return null;
    const width = span.printed_columns(emitter, from, ampersand);

    assert(close < ampersand);

    if (level * emitter.options.indent_width + width <= emitter.options.line_width) return null;
    return close;
}

fn intersect_first(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const angles = emitter.brackets.angles_at(open);
    var scan = open;

    for (0..union_scan_max) |_| {
        scan = emit.ahead_of(emitter, scan) orelse return null;

        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            scan = emitter.brackets.close_of(scan) orelse return null;

            continue;
        }

        if (walk.is_close(kind)) return null;
        if (emitter.brackets.angles_at(scan) != angles) continue;
        if (spelled(emitter, scan, "&")) return scan;
        if (intersect_stop_at(emitter, scan)) return null;
    }

    return null;
}

fn intersect_seat_member(emitter: *const Emitter, frame: *const core.Frame, position: u32) ?u32 {
    assert(frame.open < emitter.count);
    assert(position < emitter.count);

    if (frame.kind != .block_start) return null;
    if (frame.spread != core.Spread.members) return null;

    const head = member_head(emitter, frame.open, position);
    if (emitter.line_first >= head) return null;
    return head;
}

fn intersect_seat_level(emitter: *const Emitter, open: u32) u32 {
    assert(open < emitter.count);
    assert(emitter.levels <= core.line_level_max);

    const opens = span.line_opened(emitter, open) orelse open;
    const level = line.level_at(emitter, opens) orelse emitter.levels;

    assert(level + 1 < std.math.maxInt(u32));

    return level + 1;
}

fn member_head(emitter: *const Emitter, open: u32, position: u32) u32 {
    assert(open < position);
    assert(position <= emitter.count);

    var depth: u32 = 0;
    var head = open + 1;
    var scan = open + 1;

    while (scan < position) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            const separated = kind.eql(.{ .punctuation = .comma }) or
                kind.eql(.{ .punctuation = .semicolon });

            if (separated) head = scan + 1;
        } else {}
    }

    assert(head <= position);

    return line.coding(emitter, head -| 1) orelse head;
}

pub fn union_member_start(emitter: *const Emitter, open: u32, position: u32) u32 {
    assert(open < emitter.count);
    assert(position <= emitter.count);

    var depth: u32 = 0;
    var scan = open + 1;
    var start = open + 1;

    while (scan < position) {
        if (call.spanned_body(emitter, scan)) |end| {
            if (end < position) {
                assert(end >= scan);

                scan = end + 1;

                continue;
            }
        }

        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (union_member_separated(emitter, scan)) start = scan + 1;
        } else {}

        scan += 1;
    }

    const head = emit.ahead_of(emitter, start -| 1) orelse start;
    return list.comment_skipped(emitter, head);
}

fn union_member_separated(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[scan];
    const separated = token.is_punctuation(.comma) or token.is_punctuation(.semicolon);
    if (!separated) return false;
    return emitter.brackets.angles_at(scan) == 0;
}

pub fn intersect_angled(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const name = emit.back_of(emitter, open) orelse return false;
    if (emitter.tokens[name].kind != .identifier) return false;

    const ampersand = emit.back_of(emitter, name) orelse return false;
    if (!spelled(emitter, ampersand, "&")) return false;

    const held = emit.back_of(emitter, ampersand) orelse return false;
    if (emitter.tokens[held].kind != .block_end) return false;

    const curly = emitter.brackets.open_of(held) orelse return false;
    const before = emit.back_of(emitter, curly) orelse return false;

    assert(curly < held);

    return spelled(emitter, before, "&");
}

pub fn union_paren_stop(emitter: *const Emitter, held: *const span.Union) u32 {
    assert(held.open < emitter.count);
    assert(held.count <= span.union_member_max);

    if (!span.union_paren(emitter, held.open)) return held.stop;

    const close = join.closing_of(emitter, held.open) orelse return held.stop;
    const bracket = emit.ahead_of(emitter, close) orelse return close;

    assert(close > held.open);

    if (!emitter.tokens[bracket].is_punctuation(.bracket_open)) return close;
    return join.closing_of(emitter, bracket) orelse close;
}

pub fn paren_intersect_end(emitter: *const Emitter, close: u32) ?u32 {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[close].is_punctuation(.paren_close)) return null;

    const ampersand = emit.ahead_of(emitter, close) orelse return null;
    if (!line.word_is(emitter, ampersand, &.{"&"})) return null;

    const found = emit.ahead_of(emitter, ampersand) orelse return null;

    assert(found > close);

    if (emitter.tokens[found].kind != .block_start) return null;
    return found;
}

pub fn intersect_crossed(emitter: *const Emitter, equals: u32, close: u32) bool {
    assert(equals < emitter.count);
    assert(close <= emitter.count);

    var depth: u32 = 0;
    var scan = equals;

    for (0..union_scan_max) |_| {
        const held = emit.ahead_of(emitter, scan) orelse return false;
        if (held >= close) return false;

        const kind = emitter.tokens[held].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            if (depth == 0) return false;

            depth -= 1;
        } else if (depth == 0) {
            const casted = spelled(emitter, held, "as") or spelled(emitter, held, "satisfies");
            if (casted) return intersect_crossed_grouped(emitter, held, close);
        } else {}

        scan = held;
    }

    return false;
}

fn intersect_crossed_grouped(emitter: *const Emitter, cast: u32, close: u32) bool {
    assert(cast < close);
    assert(close <= emitter.count);

    const head = emit.ahead_of(emitter, cast) orelse return false;
    const stop, const lined = intersect_grouping(emitter, head) orelse return false;

    if (!lined) return false;
    return stop >= close;
}

pub fn operand_membered(emitter: *const Emitter, from: u32, operator: u32) ?u32 {
    assert(from < emitter.count);
    assert(operator < emitter.count);

    const end = emit.back_of(emitter, operator) orelse return null;
    if (end <= from) return null;

    const dot = emit.back_of(emitter, end) orelse return null;
    if (dot <= from) return null;
    if (!emit.is_dot(emitter, dot)) return null;

    const object = emit.back_of(emitter, dot) orelse return null;

    if (emitter.tokens[end].kind != .identifier) return null;
    if (object == from) return null;

    var scan = from;

    while (scan < end) : (scan += 1) {
        if (!membered_plain(emitter, scan)) return null;
    }

    return dot;
}

fn membered_plain(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[scan];
    if (token.kind == .identifier) return true;
    if (token.kind == .newline) return true;
    if (token.length == 0) return true;
    if (walk.text_is(token.text(emitter.source), "this")) return true;
    return emit.is_dot(emitter, scan);
}

pub fn arrow_param_argued(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var before = emit.back_of(emitter, open) orelse return false;

    if (spelled(emitter, before, "async")) {
        before = emit.back_of(emitter, before) orelse return false;
    }

    const kind = emitter.tokens[before].kind;
    var listed: ?u32 = null;

    if (kind.eql(.{ .punctuation = .paren_open })) {
        listed = before;
    } else if (kind.eql(.{ .punctuation = .comma })) {
        listed = bind.enclosing_open(emitter, before);
    } else {}

    const held = listed orelse return false;
    return list.calling(emitter, held);
}

pub fn arrow_valued(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var before = emit.back_of(emitter, open) orelse return false;

    if (spelled(emitter, before, "async")) {
        before = emit.back_of(emitter, before) orelse return false;
    }

    const token = emitter.tokens[before];

    if (token.is_punctuation(.assign)) {
        if (spelled(emitter, before, "=")) return true;
    }

    if (!token.is_punctuation(.colon)) return false;
    if (tern.ternary(emitter, before)) return false;
    return !emit.roled(emitter, open, brace.role_type);
}

fn bars_contain(emitter: *const Emitter, held: *const span.Union, position: u32) bool {
    assert(held.count <= span.union_member_max);
    assert(position < emitter.count);

    for (held.bars[0..held.count]) |bar| {
        if (bar == position) return true;
    }

    return false;
}

pub fn union_enclosed(
    emitter: *const Emitter,
    held: *const span.Union,
    seat: struct { u32, u32 },
    tail: struct { u32, u32, u32 },
) ?bool {
    assert(held.open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const opens, const level = seat;
    const stop, const extra, const lead = tail;
    const anchor = union_anchor(emitter, held.open) orelse return null;
    const paren = emit.back_of(emitter, anchor) orelse return null;
    if (!emitter.tokens[paren].is_punctuation(.paren_close)) return null;

    const open = emitter.brackets.open_of(paren) orelse return null;
    if (open >= opens) return null;
    if (emit.ahead_of(emitter, open) == paren) return null;

    const seated = line.level_at(emitter, open) orelse level;
    const printed = span.printed_columns(emitter, paren, stop);
    const width = printed + span.union_columns(emitter, paren, stop) + extra;

    return width - lead > emitter.options.line_width -| seated * emitter.options.indent_width;
}

fn union_anchor(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!span.predicate_returned(emitter, open)) return open;
    return span.predicate_colon_of(emitter, open);
}

pub fn hole_operand(emitter: *const Emitter, open: u32) ?struct { u32, u32 } {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.jsxed == 0) return null;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return null;

    const before = emit.back_of(emitter, open) orelse return null;
    if (!emit.roled(emitter, before, brace.role_jsx_hole)) return null;

    const close = join.closing_of(emitter, open) orelse return null;
    const rank = condition_rank(emitter, open, close) orelse return null;
    const tailed = hole_tailed(emitter, close);
    const plain = hole_plain(emitter, open, close);

    if (!tailed) return null;
    if (!plain) return null;
    return .{ close, rank };
}

fn hole_tailed(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const operator = emit.ahead_of(emitter, close) orelse return false;
    if (!span.wrapping_operator(emitter, operator)) return false;

    const held = emit.ahead_of(emitter, operator) orelse return false;
    return emit.roled(emitter, held, brace.role_jsx);
}

fn hole_plain(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        const token = emitter.tokens[scan];
        if (token.kind == .comment) return false;

        const question = walk.text_is(token.text(emitter.source), "?");

        if (question) {
            if (!tern.optional(emitter, scan)) return false;
        }
    }

    return true;
}
