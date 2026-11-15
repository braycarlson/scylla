const std = @import("std");
const assert = std.debug.assert;
const Token = @import("../../syntax/token.zig");
const bind = @import("bind.zig");
const body = @import("body.zig");
const brace = @import("../brace.zig");
const call = @import("call.zig");
const classed = @import("../text.zig").classed;
const clause = @import("clause.zig");
const comment = @import("comment.zig");
const core = @import("emitter.zig");
const edge = @import("edge.zig");
const emit = @import("emit.zig");
const ir = @import("../ir.zig");
const join = @import("join.zig");
const lead = @import("lead.zig");
const line = @import("line.zig");
const link = @import("link.zig");
const own = @import("own.zig");
const sole = @import("sole.zig");
const span = @import("span.zig");
const split = @import("split.zig");
const tern = @import("tern.zig");
const tmpl = @import("tmpl.zig");
const unite = @import("unite.zig");
const versioned = @import("../text.zig").versioned;
const walk = @import("../walk.zig");
const wide = @import("wide.zig");
const wrap = @import("wrap.zig");
const Emitter = core.Emitter;

const Elements = struct {
    angles: u32,
    commas: u32,
    found: bool,
    templates: bool,
    previous: u32,
};

const ListItem = struct {
    from: u32,
    to: u32,
};

const ListLevel = struct {
    items: [core.list_item_max]ListItem,
    count: u32,
    index: u32,
    writer: ListWriter,
};

const ListWriter = struct {
    scan: u32,
    to: u32,
    offset: u32,
    tight: bool,
};

const TypeEnd = struct {
    angles: u32,
    depth: u32,
    end: u32,
    owed: u32,
    pending: u32,
};

const TypeEndStep = enum {
    advanced,
    ended,
    refused,
};

const arrow_comment_max: u32 = 8;
const attribute_depth_max: u32 = 4;
const cast_type_scan_max: u32 = 64;
const cast_joints: []const []const u8 = &.{ "|", "&", "." };
const cast_links: []const []const u8 = &.{ "|", "&", ".", "=>" };
const cast_type_words: []const []const u8 = &.{ "as", "satisfies", "extends" };
const operand_scan_max: u32 = 256;

const paren_values: []const []const u8 = &.{
    "!",
    "+",
    "-",
    "=",
    "delete",
    "return",
    "throw",
    "typeof",
    "void",
    "yield",
    "~",
};

const unary_word_list: []const []const u8 = &.{ "delete", "typeof", "void" };
const declared_words: []const []const u8 = &.{ "const", "let", "var" };
const define_scan_max: u32 = 512;
const mapped_modifier_max: u32 = 2;
const mapped_comment_max: u32 = 8;
const mapped_modifiers: []const []const u8 = &.{ "+", "-", "readonly" };
const mapped_words: []const []const u8 = &.{ "as", "in" };
const member_heads: []const []const u8 = &.{ "class", "interface" };
const member_scan_max: u32 = 4096;

const member_modifiers: []const []const u8 = &.{
    "*",
    "abstract",
    "async",
    "declare",
    "get",
    "override",
    "private",
    "protected",
    "public",
    "readonly",
    "set",
    "static",
};

const list_nest_max: u32 = 8;

const param_modifiers: []const []const u8 = &.{
    "override",
    "private",
    "protected",
    "public",
    "readonly",
};

const return_scan_max: u32 = 16;
const return_typed_scan_max: u32 = 64;
const signature_body_scan_max: u32 = 256;
const signature_head_scan_max: u32 = 256;
const type_return_scan_max: u32 = 256;

const signature_owed: []const []const u8 = &.{
    "abstract",
    "asserts",
    "extends",
    "in",
    "infer",
    "is",
    "keyof",
    "new",
    "readonly",
    "typeof",
};

const signature_heads: []const []const u8 = &.{
    "*",
    "abstract",
    "async",
    "declare",
    "export",
    "function",
    "get",
    "override",
    "private",
    "protected",
    "public",
    "set",
    "static",
};

pub fn membered(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const open = line.frame(emitter).open;
    const typed = emitter.typed or span.type_framed(emitter, open);
    if (!typed) return false;
    if (emitter.depth == 0) return false;
    if (!emitter.tokens[position].is_punctuation(.comma)) return false;
    if (line.frame(emitter).kind != .block_start) return false;
    if (angled(emitter, position)) return false;
    return !pattern_separated(emitter, open);
}

fn signature_typed(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const close = join.closing_of(emitter, open) orelse return false;
    const after = emit.ahead_of(emitter, close) orelse return false;

    assert(close > open);

    if (walk.text_is(emitter.tokens[after].text(emitter.source), "=>")) {
        const typed = emit.ahead_of(emitter, after) orelse return false;
        return emit.roled(emitter, typed, brace.role_type);
    }

    if (!emitter.tokens[after].is_punctuation(.colon)) return false;

    const held = emit.word_before(emitter, open) orelse return false;
    return line.word_is(emitter, held, emitter.policy.construct_words);
}

pub fn generator_paren(emitter: *const Emitter, star: u32) bool {
    assert(star < emitter.count);

    if (!walk.text_is(emitter.tokens[star].text(emitter.source), "*")) return false;

    const held = emit.back_of(emitter, star) orelse return false;

    assert(held < star);

    return walk.text_is(emitter.tokens[held].text(emitter.source), "function");
}

pub fn signature_paren(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;
    if (signature_typed(emitter, open)) return true;

    const before = comment.back(emitter, open) orelse return false;
    const text = emitter.tokens[before].text(emitter.source);

    assert(before < open);

    if (closes_angle(text)) {
        if (emitter.brackets.angles_at(before) > 0) {
            if (wrap.cast_open(emitter, before) == null) return true;
            return !wrap.cast_paren(emitter, open);
        }
    }

    const frame = line.frame(emitter);
    const membered_frame = emitter.depth > 0 and signature_interface(emitter, frame.open);
    const framed = emitter.depth > 0 and span.type_framed(emitter, frame.open);
    const typed = emitter.typed or framed or membered_frame;
    if (!typed) return false;

    const kind = emitter.tokens[before].kind;
    if (kind == .block_start) return true;
    if (kind.eql(.{ .punctuation = .semicolon })) return true;
    if (!kind.eql(.{ .punctuation = .comma })) return false;
    return !signature_tupled(emitter, open);
}

fn signature_tupled(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.tokens[open].is_punctuation(.paren_open));

    const tuple = bind.enclosing_open(emitter, open) orelse return false;
    if (!emitter.tokens[tuple].is_punctuation(.bracket_open)) return false;

    const close = join.closing_of(emitter, open) orelse return false;
    const after = emit.ahead_of(emitter, close) orelse return true;

    return !walk.text_is(emitter.tokens[after].text(emitter.source), "=>");
}

fn signature_interface(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.depth > 0);

    const word = body.declared_word(emitter, open) orelse return false;
    return walk.text_is(emitter.tokens[word].text(emitter.source), "interface");
}

pub fn pattern_rested(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.tokens[close].is_punctuation(.paren_close)) return false;

    if (emitter.brackets.open_of(close)) |open| {
        if (join.coded_before(emitter, open)) |held| {
            if (walk.text_is(emitter.tokens[held].text(emitter.source), "?")) return false;
        }
    }

    return bind.rested_run(emitter, close);
}

pub fn comments_only(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    const kind = emitter.tokens[open].kind;
    const opens = kind == .block_start or kind.eql(.{ .punctuation = .bracket_open });
    if (!opens) return false;
    return commented_alone(emitter, open, close);
}

pub fn commented_alone(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (close <= open + 1) return false;

    var commented = false;

    for (open + 1..close) |scan| {
        const token = emitter.tokens[scan];

        if (token.kind == .comment) {
            commented = true;

            continue;
        }

        if (token.kind == .newline) continue;
        if (token.length == 0) continue;
        return false;
    }

    return commented;
}

pub fn spread_commented(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        if (tmpl.template_body(emitter, scan)) |end| {
            assert(end >= scan);

            scan = end;

            continue;
        }

        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (spread_comment_at(emitter, open, scan)) return true;
        } else {}
    }

    return false;
}

fn spread_comment_at(emitter: *const Emitter, open: u32, scan: u32) bool {
    assert(open < scan);
    assert(scan < emitter.count);

    const token = emitter.tokens[scan];
    if (token.kind != .comment) return false;
    if (!std.mem.startsWith(u8, token.text(emitter.source), "//")) return false;

    const held = emit.word_before(emitter, scan) orelse return false;
    if (held <= open) return false;
    if (body.parts_at(emitter, held, scan)) return false;
    return !walk.text_is(emitter.tokens[held].text(emitter.source), "=>");
}

fn angled(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return false;
    return emitter.brackets.angles_at(position) > 0;
}

pub fn importing(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.list_groups) return null;
    if (emitter.tokens[position].kind != .block_start) return null;

    var led = false;

    if (emit.word_before(emitter, position)) |held| {
        led = line.word_is(emitter, held, emitter.policy.list_leads);
    }

    const worded = line.word_is(emitter, emitter.line_first, emitter.policy.list_words);
    const headed = worded or (emitter.policy.list_sorts and led);
    if (!headed) return null;
    if (!led) return null;

    if (emitter.depth > 0) {
        if (line.frame(emitter).kind != .block_start) return null;
    }

    const close = emit.closing(emitter, position) orelse return null;

    assert(close > position);

    if (!importing_names(emitter, position, close)) return null;
    if (!importing_fits(emitter, position, close)) return null;
    return close;
}

fn importing_names(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position < close);
    assert(close < emitter.count);

    var names: u32 = 0;

    for (position + 1..close) |index| {
        const scan: u32 = @intCast(index);
        const kind = emitter.tokens[scan].kind;
        const nested = kind == .block_start or kind == .block_end;
        const commented = emitter.policy.chain_simples and kind == .comment;

        if (commented) {
            if (comment_leads(emitter, scan, close)) return false;
            if (emit.ahead_of(emitter, scan) == close) return false;
        }

        const worded = kind == .identifier or kind == .keyword;
        const plain = worded or kind == .newline or kind.eql(.{ .punctuation = .comma });
        const tight = line.word_is(emitter, scan, emitter.policy.list_tight);
        const allowed = nested or commented or plain or tight;
        if (!allowed) return false;

        names += @intFromBool(worded);
    }

    return names > 0;
}

fn importing_fits(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position < close);
    assert(close < emitter.count);

    var item = position + 1;

    while (item < close) {
        const stop = parted_at(emitter, item, close);
        const held = emit.list_depth(emitter, item, stop);
        const deep = held > 2;

        assert(stop >= item);

        if (item < stop) {
            if (deep) return false;
        }

        item = stop + 1;
    }

    return true;
}

pub fn separated(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position < close);
    assert(close < emitter.count);

    for (position + 1..close) |index| {
        const scan: u32 = @intCast(index);
        if (!emitter.tokens[scan].is_punctuation(.comma)) continue;
        if (emit.ahead_of(emitter, scan) != close) return true;
    }

    return false;
}

pub fn pattern_broken(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (!emitter.policy.chain_simples) return false;
    if (emitter.tokens[open].kind != .block_start) return false;

    var assigned = false;

    if (emit.ahead_of(emitter, close)) |held| {
        assigned = walk.text_is(emitter.tokens[held].text(emitter.source), "=");
    }

    if (pattern_typing(emitter, open, close)) |typing| {
        return !pattern_whole_fits(emitter, typing[0], typing[1]);
    }

    if (pattern_named(emitter, open, close)) |end| return !pattern_line_fits(emitter, open, end);

    if (pattern_param(emitter, open, close)) |param| {
        const opens = span.line_opened(emitter, param[0]) orelse param[0];
        const level = (link.line_led(emitter, opens) orelse emitter.levels) + 1;
        const columns = span.printed_columns(emitter, open, param[1]);

        return level * emitter.options.indent_width + columns + 1 > emitter.options.line_width;
    }

    if (pattern_declared(emitter, open, close)) |equals| {
        return !pattern_left_fits(emitter, open, equals);
    }

    if (!assigned) return false;
    if (emit.roled(emitter, open, brace.role_type)) return false;
    if (!bind.pattern_complex(emitter, open, close, true)) return false;
    return !pattern_fits_to(emitter, open, close, true);
}

fn pattern_hugged(emitter: *const Emitter, open: u32, close: u32) ?u32 {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (!pattern_signed(emitter, open, close)) return null;

    const paren = emit.back_of(emitter, open) orelse return null;
    if (!pattern_paren(emitter, paren)) return null;

    const colon = emit.ahead_of(emitter, close) orelse return null;
    if (!emitter.tokens[colon].is_punctuation(.colon)) return null;

    const typed = emit.ahead_of(emitter, colon) orelse return null;
    if (emitter.tokens[typed].kind != .block_start) return null;

    const shut = join.closing_of(emitter, typed) orelse return null;
    const closed = join.closing_of(emitter, paren) orelse return null;
    const after = emit.ahead_of(emitter, shut);

    assert(shut > typed);

    if (after == closed) return typed;

    const held = after orelse return null;
    const last = default_hugged(emitter, held) orelse return null;
    if (emit.ahead_of(emitter, last) == closed) return typed;
    return null;
}

fn pattern_paren(emitter: *const Emitter, paren: u32) bool {
    assert(paren < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (signature_headed(emitter, paren)) return true;
    return arrow_assigned(emitter, paren);
}

fn default_hugged(emitter: *const Emitter, assign: u32) ?u32 {
    assert(assign < emitter.count);

    if (!emitter.tokens[assign].is_punctuation(.assign)) return null;

    const value = emit.ahead_of(emitter, assign) orelse return null;
    const token = emitter.tokens[value];

    assert(value > assign);

    if (token.kind == .identifier) return value;

    const bracketed = token.kind == .block_start or token.is_punctuation(.bracket_open);
    const shut = join.closing_of(emitter, value) orelse return null;

    if (!bracketed) return null;
    if (emit.ahead_of(emitter, value) != shut) return null;
    return shut;
}

fn arrow_assigned(emitter: *const Emitter, paren: u32) bool {
    assert(paren < emitter.count);

    if (!emitter.tokens[paren].is_punctuation(.paren_open)) return false;

    var before = emit.back_of(emitter, paren) orelse return false;

    if (walk.text_is(emitter.tokens[before].text(emitter.source), "async")) {
        before = emit.back_of(emitter, before) orelse return false;
    }

    assert(before < paren);

    const close = join.closing_of(emitter, paren) orelse return false;
    const arrow_typed = own.arrow_typed_ahead(emitter, close) != null;
    if (!arrow_typed) return false;
    return emitter.tokens[before].is_punctuation(.assign);
}

pub fn pattern_type_joined(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return false;

    const frame = line.frame(emitter);
    const typing = pattern_typing(emitter, frame.open, frame.close) orelse return false;
    const pattern, const typed = typing;

    assert(pattern <= emitter.count);

    if (typed != frame.open) return false;
    return pattern_whole_fits(emitter, pattern, typed);
}

pub fn pattern_typing(emitter: *const Emitter, position: u32, close: u32) ?struct { u32, u32 } {
    assert(position < emitter.count);
    assert(close < emitter.count);

    if (emitter.tokens[position].kind != .block_start) return null;
    if (pattern_hugged(emitter, position, close)) |typed| return .{ position, typed };

    const colon = emit.back_of(emitter, position) orelse return null;
    if (!emitter.tokens[colon].is_punctuation(.colon)) return null;

    const shut = emit.back_of(emitter, colon) orelse return null;
    if (emitter.tokens[shut].kind != .block_end) return null;

    const pattern = emitter.brackets.open_of(shut) orelse return null;

    assert(pattern < shut);

    if (pattern_hugged(emitter, pattern, shut) == position) return .{ pattern, position };
    return null;
}

fn pattern_whole_fits(emitter: *const Emitter, open: u32, typed: u32) bool {
    assert(open < emitter.count);
    assert(typed < emitter.count);

    const shut = join.closing_of(emitter, typed) orelse return false;
    const end = emit.ahead_of(emitter, shut) orelse return false;

    return pattern_line_fits(emitter, open, end);
}

fn pattern_line_fits(emitter: *const Emitter, open: u32, end: u32) bool {
    assert(open < emitter.count);
    assert(end < emitter.count);

    const led = join.line_lead(emitter, open);
    const from = if (led) |found| found[0] else emitter.line_first;
    const level = if (led) |found| found[1] else emitter.printed;

    if (from > open) return false;

    var tail = end;

    if (default_hugged(emitter, end)) |last| {
        tail = emit.ahead_of(emitter, last) orelse end;
    }

    for (0..define_scan_max) |_| {
        const held = emit.ahead_of(emitter, tail) orelse break;
        const token = emitter.tokens[held];
        const arrow = walk.text_is(token.text(emitter.source), "=>");
        const stops = token.kind == .block_start or token.is_punctuation(.semicolon) or arrow;

        if (stops) {
            tail = held;

            break;
        }

        tail = held;

        if (walk.is_open(token.kind)) tail = join.closing_of(emitter, held) orelse held;
    }

    const room = level * emitter.options.indent_width + span.printed_columns(emitter, from, tail);
    return room <= emitter.options.line_width;
}

pub fn pattern_shared(emitter: *const Emitter, open: u32, close: u32) ?struct { u32, bool } {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (emitter.tokens[open].kind != .block_start) return null;
    if (!pattern_signed(emitter, open, close)) return null;

    const paren = emit.back_of(emitter, open) orelse return null;
    if (pattern_paren(emitter, paren)) return null;

    const colon = emit.ahead_of(emitter, close) orelse return null;
    if (!emitter.tokens[colon].is_punctuation(.colon)) return null;

    const head = emit.ahead_of(emitter, colon) orelse return null;
    const shut = join.closing_of(emitter, paren) orelse return null;

    assert(head > colon);

    if (emitter.tokens[head].kind == .block_start) {
        const typed = join.closing_of(emitter, head) orelse return .{ shut, false };
        const after = emit.ahead_of(emitter, typed) orelse return .{ shut, false };
        const object = after == shut or emitter.tokens[after].is_punctuation(.assign);
        if (object) return .{ typed, true };
    }

    return .{ shut, false };
}

fn pattern_shared_type(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (emitter.tokens[open].kind != .block_start) return false;

    const colon = emit.back_of(emitter, open) orelse return false;
    if (!emitter.tokens[colon].is_punctuation(.colon)) return false;

    const shut = emit.back_of(emitter, colon) orelse return false;
    if (emitter.tokens[shut].kind != .block_end) return false;

    const pattern = emitter.brackets.open_of(shut) orelse return false;
    const shared = pattern_shared(emitter, pattern, shut) orelse return false;

    assert(pattern < shut);

    return shared[1];
}

pub fn pattern_shares(emitter: *Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.chain_owed <= core.wrap_depth_max);

    const shared = pattern_shared(emitter, emitter.closed.open, position) orelse return false;
    const end, const object = shared;

    if (object) {
        const colon = emit.ahead_of(emitter, position) orelse return false;
        const typed = emit.ahead_of(emitter, colon) orelse return false;

        emitter.shared = typed;

        return true;
    }

    if (emitter.chain_owed == core.wrap_depth_max) return false;

    emitter.chain_ends[emitter.chain_owed] = end;
    emitter.chain_owed += 1;

    return true;
}

pub fn pattern_named(emitter: *const Emitter, open: u32, close: u32) ?u32 {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (emitter.tokens[open].kind != .block_start) return null;
    if (!pattern_signed(emitter, open, close)) return null;

    const paren = emit.back_of(emitter, open) orelse return null;
    if (!pattern_paren(emitter, paren)) return null;

    const colon = emit.ahead_of(emitter, close) orelse return null;
    if (!emitter.tokens[colon].is_punctuation(.colon)) return null;

    const head = emit.ahead_of(emitter, colon) orelse return null;
    if (emitter.tokens[head].kind == .block_start) return null;

    const shut = join.closing_of(emitter, paren) orelse return null;
    var scan = head;

    while (scan < shut) {
        const kind = emitter.tokens[scan].kind;
        const assigned = kind.eql(.{ .punctuation = .assign });
        const level = emitter.brackets.angles_at(scan) == emitter.brackets.angles_at(paren);

        if (assigned) {
            if (level) return scan;
        }

        assert(scan < emitter.count);

        if (walk.is_open(kind)) {
            scan = (join.closing_of(emitter, scan) orelse return null) + 1;
        } else {
            scan += 1;
        }
    }

    return shut;
}

pub fn signature_wide(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;
    if (constructor_parted(emitter, open)) return true;
    if (signature_typed(emitter, open)) return signature_type_wide(emitter, open);
    if (!signature_headed(emitter, open)) return false;

    const close = join.closing_of(emitter, open) orelse return false;
    if (emit.ahead_of(emitter, open) == close) return false;

    const colon = emit.ahead_of(emitter, close) orelse return false;
    if (!emitter.tokens[colon].is_punctuation(.colon)) return false;
    if (tern.ternary(emitter, colon)) return false;

    const head = emit.ahead_of(emitter, colon) orelse return false;
    if (signature_wide_held(emitter, open, close, head)) return false;
    if (return_comment_breaks(emitter, open, close, colon)) return true;

    const end = signature_body(emitter, head) orelse return false;

    if (signature_grouped(emitter, open, close)) return false;
    if (signature_return_parted(emitter, head, end)) return true;
    return signature_wide_over(emitter, open, end);
}

fn signature_return_parted(emitter: *const Emitter, head: u32, end: u32) bool {
    assert(head <= end);
    assert(end < emitter.count);

    for (head..end) |index| {
        const scan: u32 = @intCast(index);
        if (emitter.tokens[scan].kind != .block_start) continue;
        if (call.object_parted(emitter, scan)) return true;
    }

    return false;
}

fn signature_wide_held(emitter: *const Emitter, open: u32, close: u32, head: u32) bool {
    assert(open < close);
    assert(close < head);

    if (signature_count(emitter, open, close) != 1) return false;
    if (sole_braced(emitter, close)) return true;
    if (sole_patterned(emitter, open)) return true;
    if (!signature_generics_plain(emitter, open)) return false;
    if (emitter.tokens[head].kind != .block_start) return false;

    const shut = join.closing_of(emitter, head) orelse return false;
    const after = emit.ahead_of(emitter, shut) orelse return false;
    if (emitter.tokens[after].kind == .block_start) return true;
    return emitter.tokens[after].is_punctuation(.semicolon);
}

fn signature_wide_over(emitter: *const Emitter, open: u32, end: u32) bool {
    assert(open < end);
    assert(end < emitter.count);

    const signed = signature_head(emitter, open);
    const unnamed = walk.text_is(emitter.tokens[signed].text(emitter.source), "<");
    const broken = if (unnamed) null else signature_angled(emitter, signed, open);
    const start = broken orelse signed;
    const bodied: u32 = @intFromBool(emitter.tokens[end].kind == .block_start);
    const tail = bodied + 1;
    const width = signature_columns(emitter, start, end) + tail;
    const room = emitter.options.line_width;

    if (signed != emitter.line_first) {
        if (!signature_worded(emitter, signed)) {
            const outer = member_open(emitter, open) orelse return false;
            const shut = join.closing_of(emitter, outer) orelse return false;
            const stop = if (end < shut) end else shut;
            const trailing = if (end < shut) tail else 0;

            return signature_columns(emitter, open, stop) + trailing > room;
        }
    }

    return emitter.printed * emitter.options.indent_width + width > room;
}

pub fn arrow_signature_wide(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const close = join.closing_of(emitter, open) orelse return false;
    if (emit.ahead_of(emitter, open) == close) return false;

    const colon = emit.ahead_of(emitter, close) orelse return false;
    const typed = emitter.tokens[colon].is_punctuation(.colon);
    const bare = walk.text_is(emitter.tokens[colon].text(emitter.source), "=>");

    if (!typed) {
        if (!bare) return false;
    }

    if (typed) {
        if (tern.ternary(emitter, colon)) return false;
    }

    if (signature_count(emitter, open, close) == 1) {
        if (sole_braced(emitter, close)) return false;
        if (sole_patterned(emitter, open)) return false;
    }

    const arrow = if (typed) arrow_signature_end(emitter, close) orelse return false else colon;
    const held = line.frame(emitter);

    if (emitter.depth > 0) {
        if (held.kind.eql(.{ .punctuation = .paren_open })) {
            if (calling(emitter, held.open)) return false;
        }
    }

    if (arrow_types_forced(emitter, open)) return true;

    if (open != emitter.line_first) {
        if (arrow_signature_head(emitter, open) != emitter.line_first) return false;
    }

    if (!typed) return false;
    if (arrow_return_expanded(emitter, colon, arrow)) return true;

    var bodied = false;

    if (emit.ahead_of(emitter, arrow)) |after| bodied = emitter.tokens[after].kind == .block_start;

    const braces: u32 = 2 * @as(u32, @intFromBool(bodied));
    const width = span.printed_columns(emitter, emitter.line_first, arrow) + braces;

    return emitter.printed * emitter.options.indent_width + width > emitter.options.line_width;
}

fn arrow_types_forced(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.tokens[open].is_punctuation(.paren_open));

    const shut = emit.back_of(emitter, open) orelse return false;
    const angle = signature_angle_open(emitter, shut) orelse return false;

    assert(angle < shut);

    for (angle + 1..shut) |index| {
        const scan: u32 = @intCast(index);
        const token = emitter.tokens[scan];

        if (token.kind == .comment) {
            if (std.mem.startsWith(u8, token.text(emitter.source), "//")) return true;

            continue;
        }

        if (token.kind != .block_start) continue;

        const brace_close = join.closing_of(emitter, scan) orelse continue;

        assert(brace_close > scan);

        if (emit.ahead_of(emitter, scan) == brace_close) continue;
        if (call.object_parted(emitter, scan)) return true;
    }

    return false;
}

fn arrow_return_expanded(emitter: *const Emitter, colon: u32, arrow: u32) bool {
    assert(colon < arrow);
    assert(arrow < emitter.count);

    for (colon + 1..arrow) |index| {
        const scan: u32 = @intCast(index);
        if (emitter.tokens[scan].kind != .block_start) continue;

        const shut = join.closing_of(emitter, scan) orelse continue;

        assert(shut > scan);

        if (emit.ahead_of(emitter, scan) == shut) continue;
        if (call.object_parted(emitter, scan)) return true;
    }

    return false;
}

fn arrow_signature_head(emitter: *const Emitter, open: u32) u32 {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var start = open;

    if (emit.back_of(emitter, open)) |close| {
        if (signature_angle_open(emitter, close)) |found| start = found;
    }

    for (0..type_return_scan_max) |_| {
        const held = emit.back_of(emitter, start) orelse return start;
        const token = emitter.tokens[held];
        const text = token.text(emitter.source);
        const named = token.kind == .identifier or token.kind == .keyword;
        const punctuated = token.is_punctuation(.assign) or token.is_punctuation(.colon);
        const angle = walk.text_is(text, "<") or walk.text_is(text, ">");
        const marked = walk.text_is(text, "?") or walk.text_is(text, "!");
        const angled_held = emitter.brackets.angles_at(held) > 0;

        const worded = named or punctuated or angle or marked or angled_held or
            emit.is_dot(emitter, held);

        assert(held < start);

        if (!worded) return start;

        start = held;
    }

    return start;
}

pub fn signature_angle_open(emitter: *const Emitter, close: u32) ?u32 {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var depth: u32 = 0;
    var scan = close;

    for (0..type_return_scan_max) |_| {
        const token = emitter.tokens[scan];
        const text = token.text(emitter.source);

        if (closes_angle(text)) {
            depth += @intCast(text.len);
        } else if (walk.text_is(text, "<")) {
            if (depth == 0) return null;

            depth -= 1;

            if (depth == 0) return scan;
        } else {
            if (depth == 0) return null;
            if (walk.is_close(token.kind)) scan = emitter.brackets.open_of(scan) orelse return null;
        }

        scan = emit.back_of(emitter, scan) orelse return null;
    }

    return null;
}

fn arrow_signature_end(emitter: *const Emitter, close: u32) ?u32 {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const angles = emitter.brackets.angles_at(close);
    var depth: u32 = 0;
    var scan = emit.ahead_of(emitter, close) orelse return null;

    for (0..type_return_scan_max) |_| {
        const token = emitter.tokens[scan];
        const level = emitter.brackets.angles_at(scan) == angles;

        if (walk.is_open(token.kind)) {
            depth += 1;
        } else if (walk.is_close(token.kind)) {
            if (depth == 0) return null;

            depth -= 1;
        } else if (depth == 0) {
            if (level) {
                if (walk.text_is(token.text(emitter.source), "=>")) return scan;
                if (arrow_signature_stops(token)) return null;
            }
        } else {}

        scan = emit.ahead_of(emitter, scan) orelse return null;
    }

    return null;
}

fn arrow_signature_stops(token: Token) bool {
    assert(token.length > 0);

    if (token.is_punctuation(.assign)) return true;
    if (token.is_punctuation(.comma)) return true;
    return token.is_punctuation(.semicolon);
}

fn type_params_hugged(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const arrow = emit.ahead_of(emitter, close) orelse return false;
    if (!walk.text_is(emitter.tokens[arrow].text(emitter.source), "=>")) return false;

    const head = emit.ahead_of(emitter, arrow) orelse return false;
    if (!emit.roled(emitter, head, brace.role_type)) return false;
    if (signature_count(emitter, open, close) != 1) return false;
    return param_hugs(emitter, open, close);
}

pub fn type_params_reach(emitter: *const Emitter, open: u32) ?struct { u32, bool } {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return null;

    const close = join.closing_of(emitter, open) orelse return null;
    if (emit.ahead_of(emitter, open) == close) return null;

    const arrow = emit.ahead_of(emitter, close) orelse return null;
    if (!walk.text_is(emitter.tokens[arrow].text(emitter.source), "=>")) return null;

    const head = emit.ahead_of(emitter, arrow) orelse return null;
    if (!emit.roled(emitter, head, brace.role_type)) return null;

    const end = signature_type_end(emitter, head) orelse return null;
    const single = signature_count(emitter, open, close) == 1;

    if (single) {
        if (param_hugs(emitter, open, close)) return null;
    }

    if (emit.back_of(emitter, open)) |newed| {
        if (walk.text_is(emitter.tokens[newed].text(emitter.source), "new")) {
            return .{ end, type_params_newed(emitter, open, newed) };
        }
    }

    const objected = emitter.tokens[head].kind == .block_start and
        join.closing_of(emitter, head) == end;

    const breaks = type_params_breaks(emitter, open, head, end);
    const shaped = objected or breaks;

    if (single) {
        if (signature_generics_plain(emitter, open)) {
            if (shaped) return null;
        }
    }

    return .{ end, false };
}

fn type_params_newed(emitter: *const Emitter, open: u32, newed: u32) bool {
    assert(newed < open);
    assert(open < emitter.count);

    const before = emit.back_of(emitter, newed) orelse newed;
    const cast = listed_word(cast_words, emitter.tokens[before].text(emitter.source));
    var this = false;

    if (emitter.tokens[before].is_punctuation(.colon)) {
        if (emit.back_of(emitter, before)) |held| {
            this = walk.text_is(emitter.tokens[held].text(emitter.source), "this");
        }
    }

    if (emitter.depth <= 1) return false;

    const outer = emitter.nest[emitter.depth - 2];
    if (!outer.kind.eql(.{ .punctuation = .paren_open })) return false;
    if (outer.open >= open) return false;
    if (this) return true;
    if (!cast) return false;
    return calling(emitter, outer.open);
}

fn type_params_breaks(emitter: *const Emitter, open: u32, head: u32, end: u32) bool {
    assert(open < head);
    assert(head <= end);

    if (emit.ahead_of(emitter, open)) |inner| {
        if (body.parts_at(emitter, open, inner)) return false;
    }

    for (head..end) |index| {
        const scan: u32 = @intCast(index);
        if (emitter.tokens[scan].kind != .block_start) continue;
        if (call.object_parted(emitter, scan)) return true;
    }

    return false;
}

fn param_commented(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from < emitter.count);
    assert(to < emitter.count);

    var depth: u32 = 0;
    var scan = from;

    while (scan <= to) {
        if (tmpl.template_body(emitter, scan)) |end| {
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
            if (kind == .comment) return true;
        } else {}

        scan += 1;
    }

    return false;
}

fn signature_type_end(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const bound = @min(head +| type_return_scan_max, emitter.count);

    var state: TypeEnd = .{
        .angles = emitter.brackets.angles_at(head),
        .depth = 0,
        .end = head,
        .owed = 0,
        .pending = 0,
    };

    var scan = head;

    while (scan < bound) : (scan += 1) {
        const step = signature_type_end_step(emitter, &state, head, scan);
        if (step == .refused) return null;
        if (step == .ended) break;
    }

    assert(state.end >= head);
    assert(state.end < emitter.count);

    return state.end;
}

fn signature_type_end_step(
    emitter: *const Emitter,
    state: *TypeEnd,
    head: u32,
    scan: u32,
) TypeEndStep {
    assert(head <= scan);
    assert(scan < emitter.count);

    const angles = emitter.brackets.angles_at(scan);
    if (angles < state.angles) return .ended;

    const token = emitter.tokens[scan];

    if (state.depth == 0) {
        if (signature_type_end_bodied(emitter, state, head, scan)) return .ended;
    }

    const leveled = state.depth == 0 and angles == state.angles;

    if (leveled) {
        const extends = walk.text_is(token.text(emitter.source), "extends");

        if (extends) {
            if (!infer_constrained(emitter, scan)) state.owed += 1;
        }
    }

    const branched = signature_type_end_branch(emitter, state, leveled, scan);
    if (branched != .advanced) return branched;

    if (walk.is_open(token.kind)) {
        state.depth += 1;
    } else if (walk.is_close(token.kind)) {
        if (state.depth == 0) return .ended;

        state.depth -= 1;
    } else if (state.depth == 0) {
        if (angles == state.angles) {
            if (signature_type_end_stops(token)) return .ended;
        }
    } else {}

    if (token.length > 0) {
        if (token.kind != .newline) state.end = scan;
    }

    return .advanced;
}

fn signature_type_end_bodied(
    emitter: *const Emitter,
    state: *const TypeEnd,
    head: u32,
    scan: u32,
) bool {
    assert(state.depth == 0);
    assert(state.end < emitter.count);

    if (emitter.tokens[scan].kind != .block_start) return false;
    if (scan <= head) return false;
    return emitter.tokens[state.end].ends_a_value();
}

fn signature_type_end_branch(
    emitter: *const Emitter,
    state: *TypeEnd,
    leveled: bool,
    scan: u32,
) TypeEndStep {
    assert(scan < emitter.count);

    if (leveled) assert(state.depth == 0);
    if (state.depth != 0) return .advanced;

    const token = emitter.tokens[scan];

    if (walk.text_is(token.text(emitter.source), "?")) {
        if (!tern.optional(emitter, scan)) {
            if (!leveled) return .refused;
            if (state.owed == 0) return .refused;

            state.owed -= 1;
            state.pending += 1;
        }
    }

    if (!token.is_punctuation(.colon)) return .advanced;
    if (!emit.roled(emitter, scan, brace.role_spaced)) return .advanced;
    if (!leveled) return .ended;
    if (state.pending == 0) return .ended;

    state.pending -= 1;

    return .advanced;
}

fn signature_type_end_stops(token: Token) bool {
    if (token.is_punctuation(.assign)) return true;
    if (token.is_punctuation(.comma)) return true;
    return token.is_punctuation(.semicolon);
}

pub fn comment_skipped(emitter: *const Emitter, start: u32) u32 {
    assert(start < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var held = start;

    for (0..comment_skip_max) |_| {
        if (emitter.tokens[held].kind != .comment) break;

        const ahead = emit.ahead_of(emitter, held) orelse break;
        if (!body.parts_at(emitter, held, ahead)) break;

        assert(ahead > held);

        held = ahead;
    }

    assert(held >= start);

    return held;
}

const comment_skip_max: u32 = 256;

fn return_comment_breaks(emitter: *const Emitter, open: u32, close: u32, colon: u32) bool {
    assert(open < close);
    assert(close < colon);

    if (!return_commented(emitter, colon)) return false;
    if (signature_count(emitter, open, close) != 1) return true;
    return !signature_generics_plain(emitter, open);
}

fn return_commented(emitter: *const Emitter, colon: u32) bool {
    assert(colon < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var depth: u32 = 0;
    var scan = colon;

    for (0..signature_body_scan_max) |_| {
        const held = emit.ahead_of(emitter, scan) orelse return false;
        const token = emitter.tokens[held];
        const commented = std.mem.startsWith(u8, token.text(emitter.source), "//");

        assert(held > scan);

        if (token.kind == .comment) {
            if (commented) return true;
        }

        if (depth == 0) {
            if (token.kind == .block_start) {
                if (body.bodied_brace(emitter, held)) return false;
            }
        }

        if (walk.is_open(token.kind)) {
            depth += 1;
        } else if (walk.is_close(token.kind)) {
            if (depth == 0) return false;

            depth -= 1;
        } else if (depth == 0) {
            if (token.is_punctuation(.comma)) return false;
            if (token.is_punctuation(.semicolon)) return false;
        } else {}

        scan = held;
    }

    return false;
}

fn constructor_parted(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.tokens[open].is_punctuation(.paren_open));

    var newed = false;

    if (emit.back_of(emitter, open)) |held| {
        newed = walk.text_is(emitter.tokens[held].text(emitter.source), "new");
    }

    const close = join.closing_of(emitter, open) orelse return false;
    var arrow_after = false;

    if (emit.ahead_of(emitter, close)) |held| {
        arrow_after = walk.text_is(emitter.tokens[held].text(emitter.source), "=>");
    }

    if (!newed) return false;
    if (emit.ahead_of(emitter, open) == close) return false;
    if (!arrow_after) return false;
    if (!signature_typed(emitter, open)) return false;
    if (constructor_member(emitter, open)) return true;
    if (constructor_commented(emitter, open)) return true;

    if (emitter.brackets.angles_at(open) == 0) {
        const held = line.frame(emitter);

        if (!spreads(emitter)) return false;
        if (!held.kind.eql(.{ .punctuation = .paren_open })) return false;
        return calling(emitter, held.open);
    }

    const head = join.angle_head(emitter, open) orelse return false;
    const stop = join.angle_close(emitter, head) orelse return false;
    const after = emit.ahead_of(emitter, stop) orelse return false;
    if (!emitter.tokens[after].is_punctuation(.paren_open)) return false;

    const led = join.line_lead(emitter, head) orelse .{ emitter.line_first, emitter.printed };
    if (led[0] > head) return false;

    const columns = span.printed_columns(emitter, led[0], stop);
    return led[1] * emitter.options.indent_width + columns > emitter.options.line_width;
}

fn constructor_member(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const word = emit.back_of(emitter, open) orelse return false;
    const paren = emit.back_of(emitter, word) orelse return false;
    if (!emitter.tokens[paren].is_punctuation(.paren_open)) return false;

    const joint = emit.back_of(emitter, paren) orelse return false;
    const text = emitter.tokens[joint].text(emitter.source);
    const joined = walk.text_is(text, "&") or walk.text_is(text, "|");
    if (!joined) return false;
    if (emitter.line_first == paren) return true;
    return emitter.line_first == joint;
}

fn constructor_commented(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.tokens[open].is_punctuation(.paren_open));

    const newed = emit.back_of(emitter, open) orelse return false;
    const colon = emit.back_of(emitter, newed) orelse return false;
    if (!emitter.tokens[colon].is_punctuation(.colon)) return false;

    var name = constructor_commented_name(emitter, colon) orelse return false;

    for (0..member_modifiers.len) |_| {
        const held = emit.back_of(emitter, name) orelse break;
        if (!listed_word(member_modifiers, emitter.tokens[held].text(emitter.source))) break;

        assert(held < name);

        name = held;
    }

    const commented_at = emit.back_of(emitter, name) orelse return false;
    if (emitter.tokens[commented_at].kind != .comment) return false;
    if (!body.parts_at(emitter, commented_at, name)) return false;

    const held = emit.back_of(emitter, commented_at) orelse return false;

    if (emitter.tokens[held].kind != .block_start) {
        if (!body.parts_at(emitter, held, commented_at)) return false;
    }

    const member = bind.enclosing_open(emitter, name) orelse return false;
    return member_brace(emitter, member);
}

fn member_brace(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (emitter.tokens[open].kind != .block_start) return false;
    if (span.type_framed(emitter, open)) return true;

    const head = edge.statement_head(emitter, open) orelse return false;

    assert(head <= open);

    return member_headed(emitter, head, open);
}

fn constructor_commented_name(emitter: *const Emitter, colon: u32) ?u32 {
    assert(colon < emitter.count);
    assert(emitter.tokens[colon].is_punctuation(.colon));

    var first = emit.back_of(emitter, colon) orelse return null;
    const text = emitter.tokens[first].text(emitter.source);
    const marked = walk.text_is(text, "?") or walk.text_is(text, "!");
    if (marked) first = emit.back_of(emitter, first) orelse return null;

    const token = emitter.tokens[first];
    if (token.is_punctuation(.bracket_close)) return emitter.brackets.open_of(first);

    return switch (token.kind) {
        .identifier, .keyword, .number, .string => first,
        .block_end, .block_start, .comment, .newline, .punctuation => null,
    };
}

fn signature_spread_seat(
    emitter: *const Emitter,
    frame: core.Frame,
    open: u32,
) ?struct { u32, u32 } {
    assert(frame.open < open);
    assert(open < emitter.count);

    if (frame.spread == null) return null;
    if (emitter.brackets.angles_at(open) > 0) return null;

    const start = if (frame.kind == .block_start)
        unite.union_member_start(emitter, frame.open, open)
    else
        call.argument_start(emitter, frame.open, open);

    var held = start;

    while (held < open) : (held += 1) {
        if (walk.is_open(emitter.tokens[held].kind)) return null;
    }

    const opens = span.line_opened(emitter, frame.open) orelse frame.open;
    const level = (link.line_led(emitter, opens) orelse emitter.levels) + 1;

    assert(level > 0);

    return .{ start, level };
}

fn signature_type_wide(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const close = join.closing_of(emitter, open) orelse return false;
    if (emit.ahead_of(emitter, open) == close) return false;

    const arrow = emit.ahead_of(emitter, close) orelse return false;
    const head = emit.ahead_of(emitter, arrow) orelse return false;
    const single = signature_count(emitter, open, close) == 1;
    const objected = signature_objected(emitter, head);
    var hugged = false;

    if (emit.back_of(emitter, close)) |held| hugged = emitter.tokens[held].kind == .block_end;

    const start, const level = signature_type_wide_seat(emitter, open) orelse return false;

    if (single) {
        if (objected) return false;
        if (hugged) return false;
    }

    const end = signature_type_end(emitter, head) orelse return false;

    if (single) {
        if (signature_type_wide_breaks(emitter, head, end)) return false;
    }

    const columns = signature_type_columns(emitter, start, end);
    return level * emitter.options.indent_width + columns > signature_room(emitter);
}

fn signature_type_wide_seat(emitter: *const Emitter, open: u32) ?struct { u32, u32 } {
    assert(open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    var outer: ?core.Frame = null;
    var index = emitter.depth;

    while (index > 0) {
        index -= 1;

        if (emitter.nest[index].open < open) {
            outer = emitter.nest[index];

            break;
        }
    }

    if (signature_type_wide_led(emitter, open, outer)) {
        const from = emitter.line_first;
        const start = call.assign_angle_head(emitter, open, from, emitter.printed) orelse from;

        return .{ start, emitter.printed };
    }

    const frame = outer orelse return null;
    return signature_spread_seat(emitter, frame, open);
}

fn signature_type_wide_led(emitter: *const Emitter, open: u32, outer: ?core.Frame) bool {
    assert(open < emitter.count);
    assert(emitter.line_first <= emitter.count);

    if (emitter.line_first > open) return false;
    if (emitter.brackets.angles_at(open) != 0) return false;
    if (outer) |held| assert(held.close == 0 or held.close > held.open);

    var held = emitter.line_first;

    while (held < open) : (held += 1) {
        const token = emitter.tokens[held];
        if (walk.is_open(token.kind)) return false;
        if (emitter.brackets.angles_at(held) != 0) continue;
        if (walk.text_is(token.text(emitter.source), "extends")) return false;
    }

    const frame = outer orelse return true;
    if (frame.kind != .block_start) return false;
    return emitter.line_first > frame.open;
}

fn signature_type_wide_breaks(emitter: *const Emitter, head: u32, end: u32) bool {
    assert(head <= end);
    assert(end < emitter.count);

    var held = head;

    while (held < end) : (held += 1) {
        if (emitter.tokens[held].kind != .block_start) continue;

        const after = emit.ahead_of(emitter, held) orelse continue;
        if (body.parts_at(emitter, held, after)) return true;
    }

    return false;
}

pub fn signature_grouped(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (signature_count(emitter, open, close) != 1) return false;
    if (!signature_generics_plain(emitter, open)) return false;

    if (emit.ahead_of(emitter, open)) |first| {
        if (body.parts_at(emitter, open, first)) return false;
    }

    const colon = emit.ahead_of(emitter, close) orelse return false;
    if (!emitter.tokens[colon].is_punctuation(.colon)) return false;

    const head = emit.ahead_of(emitter, colon) orelse return false;
    const end = signature_body(emitter, head) orelse return false;

    for (head..end) |index| {
        const scan: u32 = @intCast(index);
        if (emitter.tokens[scan].kind != .block_start) continue;
        if (call.object_parted(emitter, scan)) return true;
    }

    return false;
}

fn signature_generics_plain(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const angle = emit.back_of(emitter, open) orelse return true;
    if (!walk.text_is(emitter.tokens[angle].text(emitter.source), ">")) return true;

    const name = opening(emitter, angle, 1) orelse return false;
    const first = emit.ahead_of(emitter, name) orelse return false;

    for (first..angle) |index| {
        const scan: u32 = @intCast(index);
        const text = emitter.tokens[scan].text(emitter.source);
        const listed = walk.text_is(text, ",") or walk.text_is(text, "=");
        const bounded = walk.text_is(text, "extends") or walk.text_is(text, "<");

        if (scan == first) continue;
        if (listed) return false;
        if (bounded) return false;
    }

    return true;
}

pub fn sole_return_forced(emitter: *const Emitter, brace_open: u32) bool {
    assert(brace_open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.tokens[brace_open].kind != .block_start) return false;

    const paren = sole_brace_paren(emitter, brace_open) orelse return false;
    const close = join.closing_of(emitter, paren) orelse return false;
    if (signature_count(emitter, paren, close) != 1) return false;

    const colon = emit.ahead_of(emitter, close) orelse return false;
    if (!emitter.tokens[colon].is_punctuation(.colon)) return false;
    if (tern.ternary(emitter, colon)) return false;

    const head = emit.ahead_of(emitter, colon) orelse return false;
    const arrow = arrow_signature_end(emitter, close);
    const end = arrow orelse sole_member_end(emitter, paren, head) orelse return false;
    if (end <= colon) return false;
    return arrow_return_expanded(emitter, colon, end);
}

fn sole_brace_paren(emitter: *const Emitter, brace_open: u32) ?u32 {
    assert(brace_open < emitter.count);
    assert(emitter.tokens[brace_open].kind == .block_start);

    const before = emit.back_of(emitter, brace_open) orelse return null;
    if (emitter.tokens[before].is_punctuation(.paren_open)) return before;
    if (!emitter.tokens[before].is_punctuation(.colon)) return null;

    var name = emit.back_of(emitter, before) orelse return null;

    if (walk.text_is(emitter.tokens[name].text(emitter.source), "?")) {
        name = emit.back_of(emitter, name) orelse return null;
    }

    if (emitter.tokens[name].kind != .identifier) return null;

    const paren = emit.back_of(emitter, name) orelse return null;
    if (!emitter.tokens[paren].is_punctuation(.paren_open)) return null;
    return paren;
}

fn sole_member_end(emitter: *const Emitter, paren: u32, head: u32) ?u32 {
    assert(paren < head);
    assert(head < emitter.count);

    if (!signature_member_lined(emitter, paren)) {
        const before = join.coded_before(emitter, paren) orelse return null;
        if (!signature_called(emitter, before)) return null;
    }

    return signature_body(emitter, head);
}

fn sole_patterned(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.ahead_of(emitter, open) orelse return false;
    const token = emitter.tokens[held];
    if (token.kind == .block_start) return true;
    return token.is_punctuation(.bracket_open);
}

fn sole_braced(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var last = emit.back_of(emitter, close) orelse return false;

    if (emitter.tokens[last].is_punctuation(.comma)) {
        last = emit.back_of(emitter, last) orelse return false;
    }

    return emitter.tokens[last].kind == .block_end;
}

fn signature_angled(emitter: *const Emitter, start: u32, open: u32) ?u32 {
    assert(start <= open);
    assert(open < emitter.count);

    const close = emit.back_of(emitter, open) orelse return null;
    if (!walk.text_is(emitter.tokens[close].text(emitter.source), ">")) return null;
    if (join.angle_head(emitter, close) == null) return null;

    const columns = signature_columns(emitter, start, open);
    const width = emitter.printed * emitter.options.indent_width + columns + 1;
    if (width > emitter.options.line_width) return close;
    return null;
}

fn signature_worded(emitter: *const Emitter, signed: u32) bool {
    assert(signed < emitter.count);
    assert(emitter.line_first < emitter.count);

    if (emitter.line_first >= signed) return false;

    for (emitter.line_first..signed) |index| {
        const token = emitter.tokens[index];

        const worded = token.kind == .newline or token.kind == .keyword or
            token.kind == .identifier;

        if (token.length == 0) continue;
        if (!worded) return false;
    }

    return true;
}

pub fn return_type_wide(emitter: *const Emitter, block: u32) bool {
    assert(block < emitter.count);

    if (emitter.tokens[block].kind != .block_start) return false;

    const colon = emit.back_of(emitter, block) orelse return false;
    if (!emitter.tokens[colon].is_punctuation(.colon)) return false;
    if (tern.ternary(emitter, colon)) return false;

    const close = emit.back_of(emitter, colon) orelse return false;
    if (!emitter.tokens[close].is_punctuation(.paren_close)) return false;

    const open = emitter.brackets.open_of(close) orelse return false;
    if (!signature_headed(emitter, open)) return false;
    if (signature_count(emitter, open, close) != 1) return false;

    const shut = join.closing_of(emitter, block) orelse return false;
    const after = emit.ahead_of(emitter, shut) orelse return false;
    const ending = emitter.tokens[after];

    if (ending.kind != .block_start) {
        if (!ending.is_punctuation(.semicolon)) return false;
    }

    const start = signature_head(emitter, open);
    if (start != emitter.line_first) return false;

    const end = signature_body(emitter, block) orelse return false;
    const level = emitter.printed * emitter.options.indent_width;
    const tail = @as(u32, @intFromBool(emitter.tokens[end].kind == .block_start)) + 1;
    const room = level + signature_columns(emitter, start, end) + tail;
    if (room <= emitter.options.line_width) return false;
    return level + wide.flat_columns(emitter, start, block) < emitter.options.line_width;
}

fn signature_columns(emitter: *const Emitter, start: u32, end: u32) u32 {
    assert(start <= end);
    assert(end < emitter.count);

    const held = emit.back_of(emitter, end) orelse return 0;
    if (held < start) return 0;
    return span.printed_columns(emitter, start, held);
}

fn signature_head(emitter: *const Emitter, open: u32) u32 {
    assert(open < emitter.count);
    assert(emitter.tokens[open].is_punctuation(.paren_open));

    var start = open;
    var angles: u32 = 0;

    for (0..signature_head_scan_max) |_| {
        const held = emit.back_of(emitter, start) orelse return start;
        const token = emitter.tokens[held];
        const text = token.text(emitter.source);

        assert(held < start);

        if (!signature_head_worded(token, text, angles)) return start;

        if (walk.text_is(text, ">")) angles += 1;
        if (walk.text_is(text, "<")) angles -|= 1;

        start = held;
    }

    return start;
}

fn signature_head_worded(token: Token, text: []const u8, angles: u32) bool {
    assert(text.len == token.length);
    assert(angles < signature_head_scan_max);

    switch (token.kind) {
        .identifier, .keyword, .string => return true,
        else => {},
    }

    if (angles > 0) return true;
    if (walk.text_is(text, "<")) return true;
    return walk.text_is(text, ">");
}

fn signature_body(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var angles: u32 = 0;
    var previous: ?u32 = null;
    var scan = head;

    for (0..signature_body_scan_max) |_| {
        const token = emitter.tokens[scan];
        const text = token.text(emitter.source);
        const listed = angles == 0 and token.is_punctuation(.comma);

        if (token.is_punctuation(.semicolon)) return scan;
        if (token.kind == .block_end) return scan;
        if (listed) return scan;
        if (walk.text_is(text, "=>")) return null;
        if (walk.text_is(text, "=")) return null;

        if (walk.text_is(text, "<")) angles += 1;
        if (walk.text_is(text, ">")) angles -|= 1;

        if (token.kind == .block_start) {
            if (previous) |held| {
                if (signature_body_ended(emitter, held)) return scan;
            }

            scan = join.closing_of(emitter, scan) orelse return null;
        } else if (walk.is_open(token.kind)) {
            scan = join.closing_of(emitter, scan) orelse return null;
        } else {}

        previous = scan;
        scan = emit.ahead_of(emitter, scan) orelse return null;
    }

    return null;
}

fn signature_body_ended(emitter: *const Emitter, held: u32) bool {
    assert(held < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const before = emitter.tokens[held];
    const text = before.text(emitter.source);
    if (walk.text_is(text, ">")) return true;

    const ended = switch (before.kind) {
        .block_end, .identifier, .keyword, .number, .string => true,
        .punctuation => |punctuation| punctuation == .bracket_close or
            punctuation == .paren_close,
        else => false,
    };

    if (!ended) return false;
    return !listed_word(signature_owed, text);
}

fn signature_count(emitter: *const Emitter, open: u32, close: u32) u32 {
    assert(open < close);
    assert(close < emitter.count);

    var count: u32 = 1;
    var depth: u32 = 0;
    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (signature_comma(emitter, scan, close)) count += 1;
        } else {}
    }

    assert(count >= 1);

    return count;
}

fn signature_comma(emitter: *const Emitter, scan: u32, close: u32) bool {
    assert(scan < close);
    assert(close < emitter.count);

    if (!emitter.tokens[scan].is_punctuation(.comma)) return false;
    if (emitter.brackets.angles_at(scan) != 0) return false;
    return emit.ahead_of(emitter, scan) != close;
}

fn signature_headed(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (signature_member_lined(emitter, open)) return true;

    var name = emit.back_of(emitter, open) orelse return false;

    if (walk.text_is(emitter.tokens[name].text(emitter.source), ">")) {
        if (join.angle_head(emitter, name)) |lt| {
            if (join.coded_before(emitter, lt)) |held| name = held;
        }
    }

    const kind = emitter.tokens[name].kind;
    const text = emitter.tokens[name].text(emitter.source);
    const worded = kind == .identifier or kind == .keyword or kind == .string;

    if (!worded) {
        if (!walk.text_is(text, ">")) return signature_called(emitter, name);
    }

    if (walk.text_is(text, "function")) return true;

    const before = join.coded_before(emitter, name) orelse return true;
    const token = emitter.tokens[before];

    assert(before < name);

    if (token.kind == .block_end) return true;
    if (token.kind == .block_start) return true;
    if (token.is_punctuation(.semicolon)) return true;
    return listed_word(signature_heads, token.text(emitter.source));
}

fn signature_member_lined(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return false;

    const shut = emit.back_of(emitter, open) orelse return false;
    const head = signature_angle_open(emitter, shut) orelse open;
    const before = join.coded_before(emitter, head) orelse return false;

    assert(before < head);

    if (!body.parts_at(emitter, before, head)) return false;

    var index = emitter.depth;

    while (index > 0) {
        index -= 1;

        const frame = emitter.nest[index];
        if (frame.open >= open) continue;

        if (frame.close != 0) {
            if (frame.close < open) return false;
        }

        return signature_called_brace(emitter, frame.open);
    }

    return false;
}

fn signature_called(emitter: *const Emitter, before: u32) bool {
    assert(before < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.tokens[before].kind == .block_start) return signature_called_brace(emitter, before);
    if (!emitter.tokens[before].is_punctuation(.semicolon)) return false;
    if (emitter.depth == 0) return false;
    return signature_called_brace(emitter, line.frame(emitter).open);
}

fn signature_called_brace(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.tokens[open].kind != .block_start) return false;
    if (span.typed_open(emitter, open)) return true;

    const word = body.declared_word(emitter, open) orelse return false;
    return walk.text_is(emitter.tokens[word].text(emitter.source), "interface");
}

pub fn pattern_separated(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.tokens[open].kind != .block_start) return false;

    const close = join.closing_of(emitter, open) orelse return false;

    assert(close > open);

    if (import_attributed(emitter, open)) return true;
    return bind.pattern_shaped(emitter, open, close);
}

fn import_attributed(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.tokens[open].kind == .block_start);

    var held = open;

    for (0..attribute_depth_max) |_| {
        const outer = bind.enclosing_open(emitter, held) orelse return false;
        const token = emitter.tokens[outer];

        if (token.is_punctuation(.paren_open)) {
            const callee = emit.back_of(emitter, outer) orelse return false;
            return walk.text_is(emitter.tokens[callee].text(emitter.source), "import");
        }

        if (token.kind != .block_start) return false;

        held = outer;
    }

    return false;
}

pub fn unparted(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (pattern_unparted(emitter, open, close)) return true;
    if (return_unparted(emitter, open)) return true;
    if (mapped_key(emitter, open)) return true;
    return cast_branch_paren(emitter, open, close);
}

pub fn return_unparted(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;
    return return_typed(emitter, open);
}

pub fn pattern_unparted(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (!pattern_parens(emitter, open, close)) return false;

    const head = emit.ahead_of(emitter, open) orelse return false;
    const shut = join.closing_of(emitter, head) orelse return false;

    assert(shut > head);

    return pattern_signed(emitter, head, shut);
}

fn pattern_parens(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const head = emit.ahead_of(emitter, open) orelse return false;
    if (head >= close) return false;
    if (param_commented(emitter, head, close)) return false;
    if (pattern_arrayed(emitter, open, close)) return true;
    if (emitter.tokens[head].kind != .block_start) return false;
    if (pattern_count(emitter, open, close) != 1) return false;

    const shut = join.closing_of(emitter, head) orelse return false;

    if (emit.mark_of(emitter, head) & brace.mark_expanded != 0) {
        return pattern_signed(emitter, head, shut);
    }

    return bind.pattern_shaped(emitter, head, shut);
}

fn pattern_arrayed(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;
    if (split.headed(emitter, open)) return false;

    const head = emit.ahead_of(emitter, open) orelse return false;
    if (head >= close) return false;
    if (!emitter.tokens[head].is_punctuation(.bracket_open)) return false;
    if (wide.element_count(emitter, open, close) != 1) return false;

    const held = emit.ahead_of(emitter, close) orelse return false;
    const token = emitter.tokens[held];
    if (token.kind == .block_start) return true;

    if (token.is_punctuation(.colon)) {
        if (!tern.ternary(emitter, held)) return true;
    }

    return walk.text_is(token.text(emitter.source), "=>");
}

fn pattern_count(emitter: *const Emitter, open: u32, close: u32) u32 {
    assert(open < close);
    assert(close < emitter.count);

    return signature_count(emitter, open, close);
}

pub fn pattern_signed(emitter: *const Emitter, head: u32, shut: u32) bool {
    assert(head < emitter.count);
    assert(shut < emitter.count);

    const open = emit.back_of(emitter, head) orelse return false;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const close = join.closing_of(emitter, open) orelse return false;

    assert(close > open);

    if (pattern_count(emitter, open, close) != 1) return false;
    if (pattern_initialized(emitter, shut, close)) return false;

    const held = emit.ahead_of(emitter, close) orelse return false;
    const token = emitter.tokens[held];
    if (token.kind == .block_start) return true;
    if (token.is_punctuation(.colon)) return true;
    return walk.text_is(token.text(emitter.source), "=>");
}

fn pattern_initialized(emitter: *const Emitter, shut: u32, close: u32) bool {
    assert(shut < emitter.count);
    assert(close < emitter.count);

    var scan = shut + 1;

    while (scan < close) : (scan += 1) {
        if (!emitter.tokens[scan].is_punctuation(.assign)) continue;

        const last = default_hugged(emitter, scan) orelse return true;
        return emit.ahead_of(emitter, last) != close;
    }

    return false;
}

pub fn cast_branch_paren(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;
    if (calling(emitter, open)) return false;
    if (split.headed(emitter, open)) return false;
    if (!cast_branched(emitter, open)) return false;

    var cast = false;
    var depth: u32 = 0;
    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        const token = emitter.tokens[scan];

        if (walk.is_open(token.kind)) {
            depth += 1;
        } else if (walk.is_close(token.kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            const text = token.text(emitter.source);

            if (listed_word(cast_words, text)) {
                cast = true;
            } else if (cast) {} else {
                if (cast_stopped(emitter, scan)) return false;
            }
        } else {}
    }

    return cast;
}

const cast_words: []const []const u8 = &.{ "as", "satisfies" };
const cast_stops: []const []const u8 = &.{ "?", "=>", ",", "=" };

fn cast_branched(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    const held = emit.back_of(emitter, open) orelse return false;
    const text = emitter.tokens[held].text(emitter.source);

    assert(held < open);

    if (walk.text_is(text, "?")) return !tern.optional(emitter, held);
    if (!walk.text_is(text, ":")) return false;
    return tern.ternary_within(emitter, held, bind.enclosing_open(emitter, held) orelse 0);
}

fn cast_stopped(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);

    const token = emitter.tokens[scan];

    if (span.wrapping_operator(emitter, scan)) return true;
    if (listed_word(cast_stops, token.text(emitter.source))) return true;
    return token.is_punctuation(.assign);
}

pub fn setter_params(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const name = emit.back_of(emitter, open) orelse return false;
    const kind = emitter.tokens[name].kind;
    const named = kind == .identifier or kind == .string or kind == .number or kind == .keyword;

    assert(name < open);

    if (!named) return false;

    const held = emit.back_of(emitter, name) orelse return false;
    if (!walk.text_is(emitter.tokens[held].text(emitter.source), "set")) return false;

    const before = emit.back_of(emitter, held) orelse return true;
    return !emit.is_dot(emitter, before);
}

pub fn spreading(emitter: *const Emitter, position: u32, close: u32) ?core.Spread {
    assert(position < emitter.count);
    assert(close < emitter.count);

    if (tmpl.holed(emitter)) return null;
    if (walk.substituting(emitter.source, emitter.tokens[position])) return null;
    if (cast_branch_paren(emitter, position, close)) return null;
    if (paren_type_led(emitter, position)) return null;
    if (pattern_typing(emitter, position, close) != null) return .members;
    if (pattern_argued(emitter, position, close)) return .members;
    if (pattern_named(emitter, position, close) != null) return .members;
    if (pattern_shared(emitter, position, close) != null) return .members;
    if (pattern_shared_type(emitter, position)) return .members;
    return spread_decided(emitter, position, close);
}

fn pattern_argued(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position < close);
    assert(close < emitter.count);

    if (emitter.tokens[position].kind != .block_start) return false;

    const angle = emit.back_of(emitter, position) orelse return false;
    const name = emit.back_of(emitter, angle) orelse return false;
    const colon = emit.back_of(emitter, name) orelse return false;
    const shut = emit.back_of(emitter, colon) orelse return false;
    const after = emit.ahead_of(emitter, close) orelse return false;

    if (!walk.text_is(emitter.tokens[angle].text(emitter.source), "<")) return false;
    if (emitter.tokens[name].kind != .identifier) return false;
    if (!emitter.tokens[colon].is_punctuation(.colon)) return false;
    if (emitter.tokens[shut].kind != .block_end) return false;
    if (!walk.text_is(emitter.tokens[after].text(emitter.source), ">")) return false;

    const pattern = emitter.brackets.open_of(shut) orelse return false;
    if (!pattern_signed(emitter, pattern, shut)) return false;

    const paren = emit.back_of(emitter, pattern) orelse return false;
    if (!pattern_paren(emitter, paren)) return false;
    return emit.ahead_of(emitter, after) == join.closing_of(emitter, paren);
}

pub fn paren_type_led(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[position].is_punctuation(.paren_open)) return false;
    if (!emit.roled(emitter, position, brace.role_type)) return false;

    const held = emit.ahead_of(emitter, position) orelse return false;
    const text = emitter.tokens[held].text(emitter.source);

    return walk.text_is(text, "|") or walk.text_is(text, "&");
}

fn spread_decided(emitter: *const Emitter, position: u32, close: u32) ?core.Spread {
    assert(position < close);
    assert(close < emitter.count);

    const listed = emitter.policy.width_lists and sole.listed(emitter, close);

    const grouped = paren_grouped(emitter, position, close) or
        bracket_grouped(emitter, position, close);

    var defined = false;

    if (line.define_parted(emitter, position)) {
        defined = line.define_settled(emitter, position, close);
    }

    const decided = listed or grouped or defined;
    if (!decided) return null;
    if (spread_refused(emitter, position, close)) return null;
    if (wide.returned_parted(emitter, close)) return null;
    if (!spread_framed(emitter, position, close)) return null;
    if (!guarded(emitter, position, close)) return null;
    if (!settled(emitter, position, close)) return null;
    if (!elements(emitter, position, close)) return null;

    if (split.headed(emitter, position)) {
        if (claused_header(emitter, position, close)) return .clauses;
        if (headed_loop(emitter, position)) return null;
        return .chain;
    }

    if (emitter.tokens[position].is_punctuation(.bracket_open)) {
        if (numeric(emitter, position, close)) return .fill;
    }

    return .members;
}

fn spread_framed(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position < close);
    assert(emitter.depth <= brace.nest_depth_max);

    var inside = false;

    for (0..emitter.depth) |index| {
        const held = emitter.nest[index];

        if (held.spread != null) {
            inside = true;

            continue;
        }

        if (headed_loop(emitter, held.open)) continue;

        const owned = spread_owned(emitter, held, position, close);

        if (inside) {
            if (!owned) {
                if (!emitter.policy.spread_owns) return false;
            }
        }

        if (owned) continue;
        if (!spread_settled(emitter, @intCast(index), position)) return false;
    }

    return true;
}

fn spread_owned(emitter: *const Emitter, held: core.Frame, position: u32, close: u32) bool {
    assert(held.open < position);
    assert(position < close);

    if (emitter.policy.body_owns) {
        if (held.bodied) return true;
        if (own.wrapper_paren(emitter, &held)) return true;
    }

    if (walk.substituting(emitter.source, emitter.tokens[held.open])) return true;
    if (held.joined) return true;
    if (run_owned(emitter, held, position, close)) return true;
    if (type_parenthesized(emitter, held)) return true;
    if (setter_params(emitter, held.open)) return true;
    if (pattern_arrayed(emitter, held.open, held.close)) return true;
    return emit.ahead_of(emitter, held.open) == held.close;
}

fn spread_settled(emitter: *const Emitter, index: u32, position: u32) bool {
    assert(index < emitter.depth);
    assert(position < emitter.count);

    for (index..emitter.depth) |at| {
        if (emitter.nest[at].parted) return true;
    }

    if (emitter.policy.spread_owns) return true;

    if (emitter.policy.spread_values) {
        if (span.wrapped_around(emitter, position)) return true;
    }

    const open = emitter.nest[index].open;
    if (body.parts_at(emitter, open, position)) return true;
    return body.parting(emitter, open, position);
}

fn spread_refused(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position < close);
    assert(close < emitter.count);

    if (type_params_hugged(emitter, position, close)) return true;
    if (pattern_parens(emitter, position, close)) return true;
    if (call.tested_params(emitter, position)) return true;
    if (call.joined_args(emitter, position, close)) return true;

    if (bind.sequence_spread(emitter, position)) {
        if (!arrow_sequenced(emitter, position)) return true;
    }

    if (bind.pattern_brace(emitter, position, close)) return true;
    if (required_args(emitter, position)) return true;
    if (return_typed(emitter, position)) return true;
    return setter_params(emitter, position);
}

fn run_owned(emitter: *const Emitter, held: core.Frame, position: u32, close: u32) bool {
    assert(held.open < position);
    assert(position < close);

    if (!run_paren(emitter, held.open)) return false;
    return operand_wide(emitter, held, position, close);
}

fn operand_wide(emitter: *const Emitter, frame: core.Frame, position: u32, close: u32) bool {
    assert(frame.open < position);
    assert(position < close);

    const from, const led = operand_wide_from(emitter, frame, position);
    const to, const trailed = operand_wide_to(emitter, frame, close);
    const lifted = @max(emitter.printed, emitter.levels);
    const seated = lifted + span.spread_count(emitter) + span.wrap_levels(emitter);
    var start = @min(emitter.line_first, from);
    var level = emitter.printed;

    if (led) {
        start = from;
        level = seated + 1;
    } else if (trailed) {
        start = frame.open;
        level = lifted;

        if (paren_branch(emitter, frame)) |branch| {
            start = branch;
            level = tern.ternary_branch_level(emitter, branch) + span.spread_count(emitter);
        }
    } else {}

    const columns = span.printed_columns(emitter, start, to);
    return level * emitter.options.indent_width + columns > emitter.options.line_width;
}

fn operand_wide_from(
    emitter: *const Emitter,
    frame: core.Frame,
    position: u32,
) struct { u32, bool } {
    assert(frame.open < position);
    assert(position < emitter.count);

    var from = position;

    for (0..operand_scan_max) |_| {
        const before = emit.back_of(emitter, from) orelse break;
        if (before <= frame.open) break;
        if (span.wrapping_operator(emitter, before)) return .{ from, true };

        from = before;

        if (walk.is_close(emitter.tokens[before].kind)) {
            from = emitter.brackets.open_of(before) orelse before;
        }
    }

    return .{ from, false };
}

fn operand_wide_to(emitter: *const Emitter, frame: core.Frame, close: u32) struct { u32, bool } {
    assert(close < emitter.count);
    assert(frame.open < close);

    var to = close;

    for (0..operand_scan_max) |_| {
        const after = emit.ahead_of(emitter, to) orelse break;
        if (after >= frame.close) break;

        to = after;

        if (walk.is_open(emitter.tokens[after].kind)) {
            to = join.closing_of(emitter, after) orelse after;
        }

        if (span.wrapping_operator(emitter, after)) return .{ to, true };
    }

    return .{ to, false };
}

fn paren_branch(emitter: *const Emitter, frame: core.Frame) ?u32 {
    assert(frame.open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.ternary_levels) return null;

    const branch = emit.back_of(emitter, frame.open) orelse return null;
    const text = emitter.tokens[branch].text(emitter.source);

    if (walk.text_is(text, "?")) {
        if (tern.optional(emitter, branch)) return null;
        return branch;
    }

    const at = paren_branch_frame(emitter, frame.open) orelse return null;
    const stop = if (at == 0) 0 else emitter.nest[at - 1].open;

    if (!walk.text_is(text, ":")) return null;
    if (!tern.ternary_within(emitter, branch, stop)) return null;
    return branch;
}

fn paren_branch_frame(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    var at: u32 = 0;

    while (at < emitter.depth) : (at += 1) {
        if (emitter.nest[at].open == open) return at;
    }

    return null;
}

fn type_parenthesized(emitter: *const Emitter, held: core.Frame) bool {
    assert(held.open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!held.kind.eql(.{ .punctuation = .paren_open })) return false;
    if (!emit.roled(emitter, held.open, brace.role_type)) return false;
    return !signature_typed(emitter, held.open);
}

fn run_paren(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.chain_simples) return false;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;
    if (calling(emitter, open)) return false;
    if (split.headed(emitter, open)) return false;
    return !signature_paren(emitter, open);
}

fn required_args(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.chain_simples) return false;

    const word = emit.word_before(emitter, open) orelse return false;
    if (!walk.text_is(emitter.tokens[word].text(emitter.source), "require")) return false;

    if (emit.back_of(emitter, word)) |before| {
        if (emit.is_dot(emitter, before)) return false;
    }

    const close = join.closing_of(emitter, open) orelse return false;

    if (emit.ahead_of(emitter, close)) |after| {
        if (emitter.tokens[after].kind == .block_start) return false;
    }

    var commas: u32 = 0;
    var depth: u32 = 0;
    var words: u32 = 0;
    var sole_string = false;
    var trailing = false;

    for (open + 1..close) |scan| {
        const token = emitter.tokens[scan];

        if (walk.is_open(token.kind)) {
            if (depth == 0) trailing = false;

            depth += 1;

            continue;
        }

        if (walk.is_close(token.kind)) {
            depth -|= 1;

            continue;
        }

        if (depth > 0) continue;

        if (token.is_punctuation(.comma)) {
            commas += 1;
            trailing = true;

            continue;
        }

        if (token.kind == .newline) continue;
        if (token.length == 0) continue;

        sole_string = words == 0 and token.kind == .string;
        words += 1;
        trailing = false;
    }

    assert(commas >= @intFromBool(trailing));

    if (commas - @intFromBool(trailing) > 0) return true;
    if (words != 1) return false;
    return sole_string;
}

fn return_typed(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const found = return_head(emitter, open) orelse return false;
    const colon, const whole = found;
    const paren = emit.back_of(emitter, colon) orelse return false;
    if (!emitter.tokens[paren].is_punctuation(.paren_close)) return false;
    if (return_trailed(emitter, open)) return false;
    return return_grouped(emitter, open, paren, whole);
}

fn return_trailed(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.tokens[open].kind != .block_start) return false;

    const close = join.closing_of(emitter, open) orelse return false;
    const last = emit.back_of(emitter, close) orelse return false;
    const token = emitter.tokens[last];

    if (last <= open) return false;
    return token.is_punctuation(.semicolon) or token.is_punctuation(.comma);
}

fn return_head(emitter: *const Emitter, open: u32) ?struct { u32, bool } {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = open;
    var whole = return_last(emitter, open);

    for (0..return_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return null;
        const kind = emitter.tokens[held].kind;
        const arrow = walk.text_is(emitter.tokens[held].text(emitter.source), "=>");
        const member = return_member(emitter, held);

        if (arrow) {
            if (!emit.roled(emitter, held, brace.role_type)) {
                if (!member) return null;
            }
        }

        if (member) {
            whole = false;
            scan = emitter.brackets.open_of(held) orelse held;

            continue;
        }

        if (kind.eql(.{ .punctuation = .colon })) {
            if (tern.ternary(emitter, held)) return null;
            return .{ held, whole };
        }

        if (return_stops(kind)) return null;

        whole = false;

        if (walk.is_close(kind)) {
            scan = emitter.brackets.open_of(held) orelse return null;

            continue;
        }

        if (walk.is_open(kind)) return null;

        scan = held;
    }

    return null;
}

fn return_stops(kind: Token.Kind) bool {
    if (kind == .comment) return true;

    const stops = switch (kind) {
        .block_end, .block_start, .comment => true,
        .punctuation => |punctuation| punctuation == .assign or punctuation == .comma or
            punctuation == .semicolon,
        .identifier, .keyword, .newline, .number, .string => false,
    };

    if (stops) assert(kind != .identifier);

    return stops;
}

fn return_member(emitter: *const Emitter, held: u32) bool {
    assert(held < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[held];

    if (walk.text_is(token.text(emitter.source), "=>")) {
        const after = emit.ahead_of(emitter, held) orelse return false;
        return emit.roled(emitter, after, brace.role_type);
    }

    if (token.kind != .block_end) return false;

    const open = emitter.brackets.open_of(held) orelse return false;
    return emit.roled(emitter, open, brace.role_type);
}

fn return_last(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const close = join.closing_of(emitter, open) orelse return true;
    const after = emit.ahead_of(emitter, close) orelse return true;
    const token = emitter.tokens[after];
    if (token.kind == .block_start) return true;
    if (token.is_punctuation(.paren_close)) return true;
    if (token.is_punctuation(.semicolon)) return true;
    if (token.is_punctuation(.comma)) return true;
    return walk.text_is(token.text(emitter.source), "=>");
}

fn return_grouped(emitter: *const Emitter, open: u32, paren: u32, whole: bool) bool {
    assert(open < emitter.count);
    assert(paren < open);

    const sole_whole = whole and emitter.tokens[open].kind == .block_start;
    const head = emitter.brackets.open_of(paren) orelse return false;
    if (emit.ahead_of(emitter, head) == paren) return false;

    if (sole_whole) {
        if (wide.element_count(emitter, head, paren) == 1) return false;
    }

    return return_fits(emitter, paren, open);
}

fn return_fits(emitter: *const Emitter, paren: u32, open: u32) bool {
    assert(paren < open);
    assert(open < emitter.count);

    var close = join.closing_of(emitter, open) orelse return true;

    if (return_fit_typed(emitter, close)) |typed_end| close = typed_end;

    for (0..return_scan_max) |_| {
        const after = emit.ahead_of(emitter, close) orelse break;
        if (!closes_angle(emitter.tokens[after].text(emitter.source))) break;

        close = after;
    }

    const end = return_fit_end(emitter, close);
    const width = span.printed_columns(emitter, paren, end);
    const level = return_fit_level(emitter, paren);
    const spreads_held = lead.spread_levels(emitter) + lead.chain_levels(emitter);
    const lost: u32 = @intFromBool(hug_lost(emitter, paren, end));
    const indent = (level + spreads_held + lost) * emitter.options.indent_width;

    return indent + width <= emitter.options.line_width;
}

fn return_fit_typed(emitter: *const Emitter, close: u32) ?u32 {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const arrow = emit.ahead_of(emitter, close) orelse return null;
    if (!walk.text_is(emitter.tokens[arrow].text(emitter.source), "=>")) return null;

    const head = emit.ahead_of(emitter, arrow) orelse return null;
    if (!emit.roled(emitter, head, brace.role_type)) return null;
    return signature_type_end(emitter, head);
}

fn return_fit_end(emitter: *const Emitter, close: u32) u32 {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const after = emit.ahead_of(emitter, close) orelse return close;
    const token = emitter.tokens[after];
    if (token.kind == .block_start) return after;
    if (token.is_punctuation(.semicolon)) return after;
    if (!walk.text_is(token.text(emitter.source), "=>")) return close;

    const bodied = emit.ahead_of(emitter, after) orelse return after;
    if (emitter.tokens[bodied].kind == .block_start) return bodied;
    return after;
}

fn return_fit_level(emitter: *const Emitter, paren: u32) u32 {
    assert(paren < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const head = emitter.brackets.open_of(paren) orelse return emitter.printed;
    const start = signature_head(emitter, head);
    var led: ?u32 = null;

    if (lead.spread(emitter, start)) |found| {
        led = found[1];
    } else {
        led = link.line_led(emitter, start);
    }

    const found = led orelse return emitter.printed;
    return @max(found, emitter.printed);
}

fn hug_lost(emitter: *const Emitter, paren: u32, end: u32) bool {
    assert(paren < emitter.count);
    assert(end < emitter.count);

    if (emitter.depth == 0) return false;

    const held = line.frame(emitter);
    const level = emitter.printed + lead.spread_levels(emitter) + lead.chain_levels(emitter);

    if (held.spread == null) return false;
    if (held.hugged == 0) return false;
    if (emitter.brackets.open_of(paren) != held.hugged) return false;
    if (held.open < emitter.line_first) return false;

    const width = span.printed_columns(emitter, emitter.line_first, end);
    return level * emitter.options.indent_width + width > emitter.options.line_width;
}

fn guarded(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position < close);
    assert(close < emitter.count);

    const kind = emitter.tokens[position].kind;
    if (kind.eql(.{ .punctuation = .paren_open })) return guarded_paren(emitter, position, close);
    if (!kind.eql(.{ .punctuation = .bracket_open })) return true;
    if (bracket_grouped(emitter, position, close)) return true;
    return guarded_bracket(emitter, position, close);
}

fn guarded_paren(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position < close);
    assert(emitter.tokens[position].is_punctuation(.paren_open));

    if (clause.seated(emitter, position)) return false;

    var closed = false;

    if (emitter.policy.chain_simples) {
        if (emit.word_before(emitter, position)) |held| {
            const shut = emitter.tokens[held];

            closed = shut.is_punctuation(.bracket_close) or shut.is_punctuation(.paren_close);
        }
    }

    if (calling(emitter, position)) return true;
    if (closed) return true;

    if (emit.word_before(emitter, position)) |held| {
        if (call.class_newed(emitter, held)) return true;
        if (sole.quoted_method(emitter, held)) return true;
    }

    if (emit.back_of(emitter, position)) |star| {
        if (generator_paren(emitter, star)) return true;
    }

    if (signature_paren(emitter, position)) return true;
    if (split.headed(emitter, position)) return true;
    if (line.define_parted(emitter, position)) return true;
    if (span.spread_arrows(emitter, position)) return true;
    return paren_grouped(emitter, position, close);
}

fn guarded_bracket(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position < close);
    assert(emitter.tokens[position].is_punctuation(.bracket_open));

    var patterned = false;
    var declared = false;

    if (emit.back_of(emitter, position)) |held| {
        if (join.closing_of(emitter, held)) |shut| patterned = pattern_arrayed(emitter, held, shut);

        declared = line.word_is(emitter, held, declared_words);
    }

    var keyed = false;

    if (key_suffixed(emitter, close)) |held| {
        const token = emitter.tokens[held];

        keyed = token.is_punctuation(.colon) or token.is_punctuation(.paren_open);
    }

    const branched = bind.branched_list(emitter, position);
    const listed_key = keyed and !branched and !patterned and !declared;
    var typed = true;

    if (emit.word_before(emitter, position)) |held| {
        const angle = walk.text_is(emitter.tokens[held].text(emitter.source), ">");

        typed = !angle or wrap.cast_open(emitter, held) != null;
    }

    if (listed_key) return false;
    return typed;
}

pub fn key_suffixed(emitter: *const Emitter, close: u32) ?u32 {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.ahead_of(emitter, close) orelse return null;
    const text = emitter.tokens[held].text(emitter.source);
    var mark: ?u32 = null;

    if (walk.text_is(text, "?")) {
        mark = held;
    } else {
        const signed = walk.text_is(text, "-") or walk.text_is(text, "+");

        if (signed) {
            if (emit.ahead_of(emitter, held)) |after| {
                if (walk.text_is(emitter.tokens[after].text(emitter.source), "?")) mark = after;
            }
        }
    }

    const found = mark orelse return held;
    const after = emit.ahead_of(emitter, found) orelse return null;
    if (!emitter.tokens[after].is_punctuation(.colon)) return null;
    return after;
}

fn claused_header(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position < close);
    assert(close < emitter.count);

    var depth: u32 = 0;

    for (position + 1..close) |scan| {
        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (kind.eql(.{ .punctuation = .semicolon })) return true;
        } else {}
    }

    return false;
}

fn settled_stop(emitter: *const Emitter, position: u32, close: u32) u32 {
    assert(position < close);
    assert(close < emitter.count);

    var called = calling(emitter, position);

    if (!called) {
        if (emit.back_of(emitter, position)) |held| {
            called = emitter.tokens[held].is_punctuation(.paren_close);
        }
    }

    if (!emitter.policy.body_settles) return close;
    if (!called) return close;

    var depth: u32 = 0;
    var last = position + 1;

    for (position + 1..close) |scan| {
        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (kind.eql(.{ .punctuation = .comma })) last = @intCast(scan + 1);
        } else {}
    }

    var brace_at = last;

    while (brace_at < close) : (brace_at += 1) {
        if (body.bodied_brace(emitter, brace_at)) break;
    }

    if (brace_at == close) return close;

    const columns = span.printed_columns(emitter, emitter.line_first, brace_at);
    const width = emitter.printed * emitter.options.indent_width + columns;

    if (width > emitter.options.line_width) {
        assert(last <= emitter.count);

        return last;
    }

    return close;
}

fn settled(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position < close);
    assert(close < emitter.count);

    const stop = settled_stop(emitter, position, close);
    var depth: u32 = 0;
    var opens: [brace.nest_depth_max]u32 = undefined;
    var scan = position + 1;

    while (scan < stop) {
        const unit = tmpl.templated_unit(emitter, scan) orelse span.jsx_body(emitter, scan);

        if (unit) |held| {
            scan = held + 1;

            continue;
        }

        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            if (depth == brace.nest_depth_max) return false;

            if (settled_body(emitter, scan)) |shut| {
                if (shut < stop) {
                    scan = shut + 1;

                    continue;
                }
            }

            opens[depth] = scan;
            depth += 1;
            scan += 1;

            continue;
        }

        if (walk.is_close(kind)) {
            if (depth == 0) return false;

            depth -= 1;

            if (!settled_close(emitter, opens[depth], scan)) return false;
        }

        scan += 1;
    }

    if (depth == 0) return true;
    return stop < close;
}

fn settled_close(emitter: *const Emitter, open: u32, scan: u32) bool {
    assert(open < scan);
    assert(scan < emitter.count);

    const empty = emit.ahead_of(emitter, open) == scan;
    const bare = emitter.tokens[open].kind != .block_start;
    const unfilled = if (split.emptied(emitter, scan, open)) |held| !held else false;
    const emptied = empty and (bare or unfilled);
    const bodied = emitter.policy.body_parts and !empty and body.bodied_brace(emitter, open);

    const parted = body.parts_at(emitter, open, scan) and !emptied and
        !template_only(emitter, open, scan);

    const broken = bodied or parted;
    if (!broken) return true;
    if (settled_held(emitter, open, scan, bodied)) return true;
    if (ownable(emitter, open, scan)) return true;
    return run_paren(emitter, open);
}

fn settled_held(emitter: *const Emitter, open: u32, scan: u32, bodied: bool) bool {
    assert(open < scan);
    assert(scan < emitter.count);

    if (!emitter.policy.body_owns) return false;

    const valued = bodied or own.bodied_value(emitter, open, scan);
    if (!valued) return false;
    if (!body.declared(emitter, open)) return true;
    return body.class_valued(emitter, open);
}

fn settled_body(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.body_owns) return null;
    if (!emitter.policy.body_parts) return null;

    const close = join.closing_of(emitter, open) orelse return null;
    if (emit.ahead_of(emitter, open) == close) return null;
    if (!body.bodied_brace(emitter, open)) return null;

    if (body.declared(emitter, open)) {
        if (!body.class_valued(emitter, open)) return null;
    }

    return close;
}

fn template_only(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (!calling(emitter, open)) return false;

    const first = emit.ahead_of(emitter, open) orelse return false;
    if (body.parts_at(emitter, open, first)) return false;

    const end = tmpl.template_whole(emitter, first) orelse return false;
    return emit.ahead_of(emitter, end) == close;
}

fn ownable(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (emitter.policy.body_owns) {
        if (span.wrapped_paren(emitter, open)) return true;
        if (own.wrapper_parens(emitter, open, close)) return true;
    }

    if (ownable_ternary(emitter, open, close)) return true;
    if (own.value_owned(emitter, open, close)) return true;
    if (bracket_lookup(emitter, open)) return true;
    if (mapped_key(emitter, open)) return true;
    if (value_assigned(emitter, open, close)) return true;
    if (!sole.listed(emitter, close)) return false;
    if (!guarded(emitter, open, close)) return false;
    return elements(emitter, open, close);
}

pub fn mapped_key(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[open].is_punctuation(.bracket_open)) return false;

    var name = emit.ahead_of(emitter, open) orelse return false;

    for (0..mapped_comment_max) |_| {
        if (emitter.tokens[name].kind != .comment) break;

        name = emit.ahead_of(emitter, name) orelse return false;
    }

    if (emitter.tokens[name].kind != .identifier) return false;

    const word = emit.ahead_of(emitter, name) orelse return false;

    assert(word > name);

    if (!walk.text_is(emitter.tokens[word].text(emitter.source), "in")) return false;

    const brace_open = mapped_brace(emitter, open) orelse return false;
    return emit.roled(emitter, brace_open, brace.role_type);
}

fn mapped_brace(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.tokens[open].is_punctuation(.bracket_open));

    var scan = open;

    for (0..mapped_modifier_max + 1) |_| {
        const held = emit.back_of(emitter, scan) orelse return null;
        if (emitter.tokens[held].kind == .block_start) return held;
        if (!line.word_is(emitter, held, mapped_modifiers)) return null;

        scan = held;
    }

    return null;
}

pub fn mapped_closed(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[close].is_punctuation(.bracket_close)) return false;

    const open = emitter.brackets.open_of(close) orelse return false;

    assert(open < close);

    return mapped_key(emitter, open);
}

pub fn mapped_expanded(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.tokens[open].kind != .block_start) return false;
    if (!emit.roled(emitter, open, brace.role_type)) return false;

    var scan = open;

    for (0..mapped_modifier_max + 1) |_| {
        const held = emit.ahead_of(emitter, scan) orelse return false;

        assert(held > scan);

        if (emitter.tokens[held].is_punctuation(.bracket_open)) {
            if (!mapped_key(emitter, held)) return false;

            const name = emit.ahead_of(emitter, held) orelse return false;
            return body.parts_at(emitter, open, name);
        }

        if (!line.word_is(emitter, held, mapped_modifiers)) return false;

        scan = held;
    }

    return false;
}

pub fn mapped_joined(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(previous < position);
    assert(position < emitter.count);

    const opened = emitter.tokens[previous].is_punctuation(.bracket_open);
    const closed = emitter.tokens[position].is_punctuation(.bracket_close);

    if (opened) return mapped_key(emitter, previous);
    if (closed) return mapped_closed(emitter, position);

    const frame = line.frame(emitter);
    if (!frame.kind.eql(.{ .punctuation = .bracket_open })) return false;
    if (!mapped_key(emitter, frame.open)) return false;
    if (line.word_is(emitter, position, mapped_words)) return true;
    return line.word_is(emitter, previous, mapped_words);
}

fn ownable_ternary(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (!emitter.policy.chain_simples) return false;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const held = emit.ahead_of(emitter, open) orelse return false;
    if (held >= close) return false;
    return tern.ternary_owns(emitter, held);
}

pub fn value_assigned(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;
    if (calling(emitter, open)) return false;
    if (split.headed(emitter, open)) return false;

    var depth: u32 = 0;

    for (open + 1..close) |index| {
        const scan: u32 = @intCast(index);
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or bind.spans_open(emitter, scan);

        if (opens) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (kind.eql(.{ .punctuation = .assign })) return true;
        } else {}
    }

    return false;
}

pub fn elements(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position < close);
    assert(close < emitter.count);

    const edged_open = emitter.policy.blank_edges and walk.is_open(emitter.tokens[position].kind);

    var state: Elements = .{
        .angles = 0,
        .commas = 0,
        .found = false,
        .templates = false,
        .previous = position,
    };

    var scan = position + 1;

    while (scan < close) {
        const token = emitter.tokens[scan];
        const blank = token.kind == .newline or token.length == 0;

        if (blank) {
            scan += 1;

            continue;
        }

        if (own.parenthesized(emitter, scan)) |held| {
            state.previous = held;
            state.found = true;
            scan = held + 1;

            continue;
        }

        if (tmpl.templated_unit(emitter, scan)) |held| {
            if (!edged_open) {
                if (elements_blanked(emitter, state.previous, scan)) return false;
            }

            state.templates = state.templates or tmpl.template_lined(emitter, scan, held);
            state.previous = held;
            scan = held + 1;
            state.found = true;

            continue;
        }

        if (walk.is_open(token.kind)) {
            const held = join.closing_of(emitter, scan) orelse return false;
            if (held >= close) return false;

            if (!edged_open) {
                if (elements_blanked(emitter, state.previous, scan)) return false;
            }

            state.found = true;
            state.previous = held;
            scan = held + 1;

            continue;
        }

        if (!elements_token(emitter, position, close, edged_open, scan, &state)) return false;

        scan += 1;
    }

    return elements_done(emitter, position, close, edged_open, &state);
}

fn elements_done(
    emitter: *const Emitter,
    position: u32,
    close: u32,
    edged_open: bool,
    state: *const Elements,
) bool {
    assert(position < close);
    assert(close < emitter.count);
    assert(state.previous < close);

    if (!state.found) return false;

    if (!edged_open) {
        if (elements_blanked(emitter, state.previous, close)) return false;
    }

    const trailing: u32 = @intFromBool(emitter.tokens[state.previous].is_punctuation(.comma));
    if (state.commas > trailing) return true;
    if (!state.templates) return true;
    if (!emitter.policy.chain_simples) return false;
    return !template_sole(emitter, position, close);
}

fn template_sole(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (template_only(emitter, open, close)) return true;

    const head = emit.ahead_of(emitter, open) orelse return false;
    if (head >= close) return false;
    if (!calling(emitter, open)) return false;
    if (body.parts_at(emitter, open, head)) return false;

    var scan = head;

    for (0..template_tag_scan_max) |_| {
        const token = emitter.tokens[scan];

        if (token.kind != .identifier) {
            if (!emit.is_dot(emitter, scan)) break;
        }

        const held = emit.ahead_of(emitter, scan) orelse return false;
        if (held >= close) return false;

        scan = held;
    }

    if (scan <= head) return false;

    const token = emitter.tokens[scan];
    if (token.offset != emitter.tokens[scan - 1].end()) return false;

    const text = token.text(emitter.source);
    if (text.len == 0) return false;
    if (text[0] != '`') return false;

    const end = tmpl.template_whole(emitter, scan) orelse return false;
    return emit.ahead_of(emitter, end) == close;
}

fn elements_token(
    emitter: *const Emitter,
    position: u32,
    close: u32,
    edged_open: bool,
    scan: u32,
    state: *Elements,
) bool {
    assert(position < scan);
    assert(scan < close);

    const token = emitter.tokens[scan];
    if (walk.is_close(token.kind)) return false;

    if (token.kind == .comment) {
        if (!elements_comment(emitter, scan, state.previous, close)) return false;
    }

    if (!edged_open) {
        if (elements_blanked(emitter, state.previous, scan)) return false;
    }

    if (!elemental(emitter, scan, position, state.previous)) return false;

    if (emitter.policy.angle_types) {
        var brackets: u32 = 0;

        emit.opened_type(token.text(emitter.source), &state.angles, &brackets);
    }

    const comma_parts = state.angles == 0 and token.is_punctuation(.comma);
    const ticked = token.kind == .string and walk.text_is(token.text(emitter.source), "`");

    state.commas += @intFromBool(comma_parts);
    state.found = true;
    state.previous = scan;
    state.templates = state.templates or (!emitter.policy.template_units and ticked);

    return true;
}

fn elements_blanked(emitter: *const Emitter, previous: u32, position: u32) bool {
    assert(previous < position);
    assert(position < emitter.count);

    if (emitter.policy.spread_blanks) return false;
    return blanked(emitter, previous, position);
}

fn elements_comment(emitter: *const Emitter, scan: u32, previous: u32, close: u32) bool {
    assert(scan < close);
    assert(emitter.tokens[scan].kind == .comment);

    if (inline_comment(emitter, scan, close)) return true;
    if (trailing_comment(emitter, scan, previous, close)) return true;
    return standing_comment(emitter, scan, previous, close);
}

fn elemental(emitter: *const Emitter, scan: u32, position: u32, previous: u32) bool {
    assert(position < scan);
    assert(previous < scan);

    const token = emitter.tokens[scan];

    const semicolon = token.is_punctuation(.semicolon) and !emitter.typed and
        !span.typed_open(emitter, position) and !split.headed(emitter, position);

    const prefixed = emitter.policy.prefix_words.len > 0 and
        listed_word(emitter.policy.prefix_words, "...");

    const ranged = walk.text_is(token.text(emitter.source), "...") and !prefixed;

    if (semicolon) return false;
    if (ranged) return false;

    const prior_comma = emitter.tokens[previous].is_punctuation(.comma);
    const elided = token.is_punctuation(.comma) and (previous == position or prior_comma);
    const holed = emitter.tokens[position].is_punctuation(.bracket_open);

    if (!elided) return true;
    return holed;
}

pub fn tuple_blanked(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.depth == 0) return false;

    const frame = line.frame(emitter);
    if (!frame.kind.eql(.{ .punctuation = .bracket_open })) return false;
    return emit.roled(emitter, frame.open, brace.role_type);
}

pub fn blanked(emitter: *const Emitter, previous: u32, position: u32) bool {
    assert(previous <= position);
    assert(position < emitter.count);

    const from = emitter.tokens[previous].end();
    return body.parted_by(emitter, from, emitter.tokens[position].offset) > 1;
}

fn standing_comment(emitter: *const Emitter, position: u32, previous: u32, close: u32) bool {
    assert(position < close);
    assert(close < emitter.count);

    const token = emitter.tokens[position];
    const text = token.text(emitter.source);
    var lined = std.mem.startsWith(u8, text, "//");

    if (!lined) {
        if (std.mem.startsWith(u8, text, "/*")) {
            const open = emitter.brackets.open_of(close);
            const headed = if (open) |found| split.headed(emitter, found) else false;

            lined = !headed;
        }
    }

    if (token.kind != .comment) return false;
    if (!lined) return false;
    if (!body.parts_at(emitter, previous, position)) return false;

    const held = emit.ahead_of(emitter, position) orelse return false;

    if (held != close) {
        if (!body.parts_at(emitter, position, held)) return false;
    }

    for (position + 1..close) |scan| {
        const after = emitter.tokens[scan];
        const coded = after.kind != .comment and after.kind != .newline;

        if (coded) {
            if (after.length > 0) return true;
        }
    }

    return std.mem.startsWith(u8, text, "//");
}

fn trailing_comment(emitter: *const Emitter, position: u32, previous: u32, close: u32) bool {
    assert(position < close);
    assert(close < emitter.count);

    const token = emitter.tokens[position];
    const text = token.text(emitter.source);
    const blocked = std.mem.startsWith(u8, text, "/*");
    const multiline = std.mem.findScalar(u8, text, '\n') != null;
    const spanning = blocked and multiline and emit.ahead_of(emitter, position) == close;

    if (token.kind != .comment) return false;

    if (!std.mem.startsWith(u8, text, "//")) {
        if (!spanning) return false;
    }

    if (previous == position) return false;
    if (body.parts_at(emitter, previous, position)) return false;

    const held = emit.ahead_of(emitter, position) orelse return false;
    if (held == close) return true;
    return body.parts_at(emitter, position, held);
}

fn inline_comment(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position < emitter.count);
    assert(close < emitter.count);

    const token = emitter.tokens[position];
    if (token.kind != .comment) return false;
    if (!emitter.policy.inline_comments) return false;

    const text = token.text(emitter.source);
    if (!std.mem.startsWith(u8, text, "/*")) return false;
    if (std.mem.findScalar(u8, text, '\n') != null) return false;

    const held = emit.ahead_of(emitter, position) orelse return false;
    if (held == close) return true;
    if (!body.parts_at(emitter, position, held)) return true;
    if (span.operator_leads(emitter, held)) return true;
    return branch_leads(emitter, held, close);
}

fn branch_leads(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position < emitter.count);
    assert(close < emitter.count);

    const text = emitter.tokens[position].text(emitter.source);
    if (walk.text_is(text, "?")) return !tern.optional(emitter, position);
    if (!walk.text_is(text, ":")) return false;

    const open = emitter.brackets.open_of(close) orelse return false;
    return tern.ternary_within(emitter, position, open);
}

pub fn param_type_unparted(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.tokens[open].kind != .block_start) return false;

    const shut = join.closing_of(emitter, open) orelse return false;
    const after = emit.ahead_of(emitter, shut) orelse return false;
    const ended = emitter.tokens[after];

    const whole = ended.is_punctuation(.paren_close) or ended.is_punctuation(.comma) or
        ended.is_punctuation(.assign);

    if (!whole) return false;

    const colon = emit.back_of(emitter, open) orelse return false;
    if (!emitter.tokens[colon].is_punctuation(.colon)) return false;

    var name = emit.back_of(emitter, colon) orelse return false;

    if (walk.text_is(emitter.tokens[name].text(emitter.source), "?")) {
        name = emit.back_of(emitter, name) orelse return false;
    }

    if (emitter.tokens[name].kind != .identifier) return false;

    var before = emit.back_of(emitter, name);

    for (0..param_modifiers.len) |_| {
        const held = before orelse break;
        if (!line.word_is(emitter, held, param_modifiers)) break;

        before = emit.back_of(emitter, held);
    }

    const paren = before orelse return false;
    if (!emitter.tokens[paren].is_punctuation(.paren_open)) return false;

    const closed = join.closing_of(emitter, paren) orelse return false;
    return wide.element_count(emitter, paren, closed) == 1;
}

pub fn paren_grouped(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (core.memo_found(emitter, .paren_grouped, open, close)) |answer| return answer == 1;

    const held = paren_grouped_scanned(emitter, open, close);

    core.memo_store(emitter, .paren_grouped, open, close, @intFromBool(held));

    return held;
}

fn paren_grouped_scanned(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (!emitter.policy.chain_simples) return false;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;
    if (calling(emitter, open)) return false;
    if (split.headed(emitter, open)) return false;
    if (arrow_sequenced(emitter, open)) return true;
    if (paren_grouped_commented(emitter, open, close)) return true;

    const unary = paren_grouped_unary(emitter, open);
    const after = line.coding(emitter, close);
    const member_led = paren_grouped_membered(emitter, open, close, after);

    if (paren_cast_valued(emitter, open, close)) return true;
    if (unary_commented(emitter, open, close)) return true;

    if (paren_grouped_owned(emitter, open)) {
        if (paren_operated(emitter, open, close)) return true;
    }

    if (paren_tested(emitter, open, close)) return true;

    if (!unary) {
        if (!member_led) return false;
    }

    if (member_led) {
        if (paren_conditional(emitter, open, close)) {
            if (!paren_valued(emitter, open)) return false;
        }
    }

    const member: ?u32 = if (member_led) after else null;
    if (paren_bare(emitter, open, close, unary, member)) return false;
    if (paren_operated(emitter, open, close)) return true;
    if (!member_led) return false;
    return paren_headed(emitter, open, close);
}

fn paren_grouped_commented(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const held = emit.back_of(emitter, open) orelse return false;
    if (emitter.tokens[held].kind != .comment) return false;
    if (body.parts_at(emitter, held, open)) return false;

    if (!sole.cast_commented(emitter, open)) {
        if (paren_arrowed(emitter, open, close)) return false;
    }

    return !own.wrapper_parens(emitter, open, close);
}

fn paren_arrowed(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or bind.spans_open(emitter, scan);

        if (opens) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            const text = emitter.tokens[scan].text(emitter.source);
            if (walk.text_is(text, "=>")) return true;
            if (walk.text_is(text, "?")) return tern.optional(emitter, scan);
            if (emitter.tokens[scan].is_punctuation(.comma)) return false;
        } else {}
    }

    return false;
}

fn paren_grouped_unary(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.tokens[open].is_punctuation(.paren_open));

    const held = emit.back_of(emitter, open) orelse return false;
    const text = emitter.tokens[held].text(emitter.source);
    if (walk.text_is(text, "!")) return true;
    if (walk.text_is(text, "~")) return true;
    if (call.unary_at(emitter, held)) return true;
    return unary_worded(emitter, held);
}

fn paren_grouped_membered(emitter: *const Emitter, open: u32, close: u32, after: ?u32) bool {
    assert(open < close);
    assert(close < emitter.count);
    if (after) |held| assert(held < emitter.count);

    const held = after orelse return false;
    if (emit.is_dot(emitter, held)) return true;

    const token = emitter.tokens[held];
    if (token.is_punctuation(.bracket_open)) return true;
    if (token.is_punctuation(.paren_open)) return true;
    if (!walk.text_is(token.text(emitter.source), "!")) return false;
    return paren_conditional(emitter, open, close);
}

fn paren_grouped_owned(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.tokens[open].is_punctuation(.paren_open));

    const held = emit.back_of(emitter, open) orelse return false;
    if (!emitter.tokens[held].is_punctuation(.paren_open)) return false;

    const shut = emitter.brackets.close_of(held) orelse return false;
    return unary_commented(emitter, held, shut);
}

fn unary_worded(emitter: *const Emitter, word: u32) bool {
    assert(word < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!line.word_is(emitter, word, unary_word_list)) return false;

    const held = emit.back_of(emitter, word) orelse return true;
    return !emit.is_dot(emitter, held);
}

fn paren_bare(emitter: *const Emitter, open: u32, close: u32, unary: bool, member: ?u32) bool {
    assert(open < close);
    assert(close < emitter.count);
    if (member) |held| assert(held < emitter.count);

    if (member) |held| {
        if (paren_assigned(emitter, open, close)) return true;
        if (unary) return false;
        if (!emitter.tokens[held].is_punctuation(.bracket_open)) return false;
        if (!paren_operated(emitter, open, close)) return false;
        return !paren_headed(emitter, open, close);
    }

    if (!unary) return false;
    if (paren_conditional(emitter, open, close)) return true;
    return paren_assigned(emitter, open, close);
}

fn unary_commented(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const held = emit.back_of(emitter, open) orelse return false;

    if (!call.unary_at(emitter, held)) {
        if (!listed_word(unary_word_list, emitter.tokens[held].text(emitter.source))) return false;
    }

    if (emit.ahead_of(emitter, open)) |inner| {
        if (emitter.tokens[inner].kind == .comment) return true;
    }

    const tail = emit.back_of(emitter, close) orelse return false;
    return emitter.tokens[tail].kind == .comment;
}

fn paren_valued(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const before = emit.back_of(emitter, open) orelse return false;
    var seat = before;

    if (line.word_is(emitter, before, &.{"new"})) {
        seat = emit.back_of(emitter, before) orelse before;
    }

    if (!listed_word(paren_values, emitter.tokens[seat].text(emitter.source))) return false;

    const stop = link.chain_stop(emitter, open) orelse return true;
    const held = emit.ahead_of(emitter, stop) orelse return true;
    const token = emitter.tokens[held];
    if (walk.is_close(token.kind)) return true;
    if (token.is_punctuation(.comma)) return true;
    return token.is_punctuation(.semicolon);
}

fn paren_cast_valued(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const word = emit.ahead_of(emitter, close) orelse return false;
    if (!listed_word(cast_words, emitter.tokens[word].text(emitter.source))) return false;

    const before = emit.back_of(emitter, open) orelse return false;
    if (!listed_word(paren_values, emitter.tokens[before].text(emitter.source))) return false;
    if (!paren_conditional(emitter, open, close)) return false;
    return cast_type_whole(emitter, word);
}

fn cast_type_whole(emitter: *const Emitter, word: u32) bool {
    assert(word < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = word;

    for (0..cast_type_scan_max) |_| {
        const held = emit.ahead_of(emitter, scan) orelse return true;
        const token = emitter.tokens[held];
        if (walk.is_close(token.kind)) return true;
        if (token.is_punctuation(.comma)) return true;
        if (token.is_punctuation(.semicolon)) return true;

        if (scan != word) {
            if (cast_type_parted(emitter, scan, held)) return true;
        }

        scan = cast_type_step(emitter, held) orelse return false;
    }

    return false;
}

fn cast_type_parted(emitter: *const Emitter, scan: u32, held: u32) bool {
    assert(scan < held);
    assert(held < emitter.count);

    if (!body.parts_at(emitter, scan, held)) return false;
    return !listed_word(cast_joints, emitter.tokens[held].text(emitter.source));
}

fn cast_type_step(emitter: *const Emitter, held: u32) ?u32 {
    assert(held < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[held];
    const text = token.text(emitter.source);
    if (walk.text_is(text, "<")) return join.angle_close(emitter, held) orelse held;
    if (walk.is_open(token.kind)) return join.closing_of(emitter, held);
    if (listed_word(cast_links, text)) return held;

    const worded = switch (token.kind) {
        .identifier, .keyword, .number, .string => true,
        .block_end, .block_start, .comment, .newline, .punctuation => false,
    };

    if (!worded) return null;
    if (listed_word(cast_type_words, text)) return null;
    return held;
}

fn paren_assigned(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or bind.spans_open(emitter, scan);

        if (opens) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else {}

        if (depth != 0) continue;
        if (kind.eql(.{ .punctuation = .assign })) return true;
        if (own.compound_assign(emitter, scan)) return true;
    }

    return false;
}

pub fn ternary_closed(emitter: *const Emitter, position: u32) bool {
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.chain_simples) return false;
    if (position >= emitter.count) return false;
    if (!emitter.tokens[position].is_punctuation(.paren_close)) return false;

    const open = emitter.brackets.open_of(position) orelse return false;

    assert(open < position);

    if (calling(emitter, open)) return false;
    if (split.headed(emitter, open)) return false;

    const held = emit.ahead_of(emitter, position) orelse return false;
    if (!emit.is_dot(emitter, held)) return false;
    if (member_targeted(emitter, position)) return false;
    if (!paren_conditional(emitter, open, position)) return false;
    return !paren_valued(emitter, open);
}

fn member_targeted(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const dot = emit.ahead_of(emitter, close) orelse return false;
    const name = emit.ahead_of(emitter, dot) orelse return false;
    const after = emit.ahead_of(emitter, name) orelse return false;
    const token = emitter.tokens[after];
    if (token.is_punctuation(.assign)) return true;
    if (own.compound_assign(emitter, after)) return true;

    const text = token.text(emitter.source);
    return walk.text_is(text, "++") or walk.text_is(text, "--");
}

fn paren_headed(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var scan = open + 1;

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
            depth -|= 1;
        } else if (depth == 0) {
            const text = emitter.tokens[scan].text(emitter.source);
            if (walk.text_is(text, "=>")) return false;
            if (paren_headed_word(text)) return true;
        } else {}

        scan += 1;
    }

    return false;
}

fn paren_headed_word(text: []const u8) bool {
    if (walk.text_is(text, "as")) return true;
    if (walk.text_is(text, "await")) return true;
    return walk.text_is(text, "?");
}

pub fn bracket_grouped(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (!emitter.policy.chain_simples) return false;
    if (!emitter.tokens[open].is_punctuation(.bracket_open)) return false;

    const head = emit.ahead_of(emitter, open) orelse return false;
    if (head == close) return false;

    if (emitter.tokens[head].kind == .number) {
        if (emit.ahead_of(emitter, head) == close) return false;
    }

    if (cast_tupled(emitter, open)) return true;
    if (bracket_grouped_typed(emitter, open)) return false;

    var assigned = false;

    if (emit.ahead_of(emitter, close)) |held| {
        assigned = emitter.tokens[held].is_punctuation(.assign);
    }

    if (bracket_valued(emitter, open)) {
        if (!assigned) {
            const slighted = bracket_slight(emitter, open);

            if (slighted) {
                if (!bracket_owed(emitter, open)) return false;
            }
        }
    }

    return bracket_lookup(emitter, open);
}

fn bracket_grouped_typed(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.typed) return true;
    if (tern.typed_frame(emitter)) return true;
    if (cast_lookup(emitter, open)) return true;
    if (!bracket_lookup(emitter, open)) return false;

    if (emit.word_before(emitter, open)) |word| {
        if (listed_word(cast_words, emitter.tokens[word].text(emitter.source))) return false;
    }

    const held = emit.ahead_of(emitter, open) orelse return false;
    return emit.roled(emitter, held, brace.role_type);
}

pub fn bracket_lookup(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (!emitter.tokens[open].is_punctuation(.bracket_open)) return false;

    const held = emit.word_before(emitter, open) orelse return false;
    const token = emitter.tokens[held];

    assert(held < open);

    if (walk.text_is(token.text(emitter.source), "?.")) return true;
    if (walk.substituting(emitter.source, token)) return false;

    const other = token.is_keyword(.other);
    const worded = !other or line.word_is(emitter, held, emitter.policy.operand_words);
    const braced = token.kind != .block_end or bracket_braced(emitter, held);
    const valued = token.ends_a_value() or line.nonnull_ended(emitter, held);

    return valued and worded and braced;
}

fn bracket_braced(emitter: *const Emitter, held: u32) bool {
    assert(held < emitter.count);
    assert(emitter.tokens[held].kind == .block_end);

    const found = emitter.brackets.open_of(held) orelse return false;
    return !body.bodied_brace(emitter, found);
}

pub fn loop_closed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (!emitter.tokens[position].is_punctuation(.paren_close)) return false;

    const open = emitter.brackets.open_of(position) orelse return false;

    assert(open < position);

    return headed_loop(emitter, open);
}

pub fn headed_loop(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.chain_simples) return false;
    if (!split.headed(emitter, open)) return false;

    const word = emit.word_before(emitter, open) orelse return false;
    const held = line.loop_awaited(emitter, word) orelse word;
    if (!walk.text_is(emitter.tokens[held].text(emitter.source), "for")) return false;

    const close = join.closing_of(emitter, open) orelse return false;
    return !claused_header(emitter, open, close);
}

pub fn numeric(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position < close);
    assert(close <= emitter.count);

    var scan = position + 1;

    while (scan < close) : (scan += 1) {
        const token = emitter.tokens[scan];
        const text = token.text(emitter.source);
        const numbered = token.kind == .number and !std.mem.endsWith(u8, text, "n");
        const signed = listed_word(numeric_words, text);
        const held = token.kind == .newline or token.length == 0 or numbered or signed;
        if (!held) return false;
    }

    return true;
}

const numeric_words: []const []const u8 = &.{ ",", "-", "+" };

pub fn member_worded(emitter: *const Emitter, word: u32) bool {
    assert(word < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const answer = edge.statement_evaluated(emitter, edge.statement_member_frame(emitter, word));
    return answer.verdict;
}

pub fn member_worded_step(
    emitter: *const Emitter,
    frame: *edge.Member,
    answer: ?edge.StatementAnswer,
) edge.StatementStep {
    assert(frame.word < emitter.count);
    assert(frame.open <= frame.word);
    if (answer) |held| assert(held != .head or held.head == null or held.head.? < emitter.count);

    const returned = answer orelse return member_worded_start(emitter, frame);
    const head = returned.head orelse return .{ .done = .{ .verdict = false } };

    assert(frame.open < frame.word);
    assert(head <= frame.open);

    return .{ .done = .{ .verdict = member_headed(emitter, head, frame.open) } };
}

fn member_worded_start(emitter: *const Emitter, frame: *edge.Member) edge.StatementStep {
    assert(frame.word < emitter.count);
    assert(frame.open == frame.word);

    const missed: edge.StatementStep = .{ .done = .{ .verdict = false } };

    if (emit.back_of(emitter, frame.word)) |held| {
        if (emit.is_dot(emitter, held)) return .{ .done = .{ .verdict = true } };
    }

    if (member_listed(emitter, frame.word)) return .{ .done = .{ .verdict = true } };

    const open = member_keyword(emitter, frame.word) orelse return missed;

    assert(open < frame.word);

    if (emitter.tokens[open].kind != .block_start) return missed;
    if (span.type_framed(emitter, open)) return .{ .done = .{ .verdict = true } };

    frame.open = open;

    return .{ .call = edge.statement_scan_frame(emitter, open, true) };
}

fn member_listed(emitter: *const Emitter, word: u32) bool {
    assert(word < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const open = emit.ahead_of(emitter, word) orelse return false;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const close = join.closing_of(emitter, open) orelse return false;
    const body_open = emit.ahead_of(emitter, close) orelse return false;
    if (emitter.tokens[body_open].kind != .block_start) return false;

    const before = join.coded_before(emitter, word) orelse return false;
    if (emitter.tokens[before].is_punctuation(.comma)) return true;
    if (emitter.tokens[before].kind != .block_start) return false;

    const seat = join.coded_before(emitter, before) orelse return false;
    const seat_token = emitter.tokens[seat];
    if (seat_token.is_punctuation(.assign)) return true;
    if (seat_token.is_punctuation(.paren_open)) return true;
    if (seat_token.is_punctuation(.bracket_open)) return true;
    if (seat_token.is_punctuation(.comma)) return true;
    return seat_token.is_keyword(.@"return");
}

fn member_keyword(emitter: *const Emitter, word: u32) ?u32 {
    assert(word < emitter.count);

    const after = emit.ahead_of(emitter, word) orelse return null;
    const text = emitter.tokens[after].text(emitter.source);
    const angle_marked = walk.text_is(text, "<") or walk.text_is(text, "?");
    const parametered = emitter.tokens[after].is_punctuation(.paren_open) or angle_marked;
    if (!parametered) return null;

    const before = join.coded_before(emitter, word) orelse return null;
    const kind = emitter.tokens[before].kind;

    const headed = kind == .block_start or kind == .block_end or
        kind.eql(.{ .punctuation = .semicolon }) or
        listed_word(member_modifiers, emitter.tokens[before].text(emitter.source));

    assert(before < word);

    if (!headed) return null;

    const open = member_open(emitter, word) orelse return null;

    assert(open < word);

    return open;
}

fn member_headed(emitter: *const Emitter, head: u32, open: u32) bool {
    assert(head <= open);
    assert(open < emitter.count);

    for (head..open) |scan| {
        if (line.word_is(emitter, @intCast(scan), member_heads)) return true;
    }

    return false;
}

fn member_open(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    var scan = position;

    for (0..member_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return null;
        const kind = emitter.tokens[held].kind;

        assert(held < scan);

        if (walk.is_close(kind)) {
            scan = emitter.brackets.open_of(held) orelse return null;

            continue;
        }

        if (walk.is_open(kind)) return held;

        scan = held;
    }

    return null;
}

pub fn calling(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (core.memo_found(emitter, .calling, position, 0)) |answer| return answer == 1;

    const held = calling_scanned(emitter, position);

    core.memo_store(emitter, .calling, position, 0, @intFromBool(held));

    return held;
}

fn calling_scanned(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    var held = emit.word_before(emitter, position) orelse return false;
    if (walk.text_is(emitter.tokens[held].text(emitter.source), "?.")) return true;

    if (walk.text_is(emitter.tokens[held].text(emitter.source), "?")) {
        if (tern.optional(emitter, held)) {
            held = emit.word_before(emitter, held) orelse return false;
        }
    }

    if (walk.text_is(emitter.tokens[held].text(emitter.source), "!")) {
        if (emitter.policy.type_words.len > 0) {
            if (calling_nonnull(emitter, held)) |name| held = name;
        }
    }

    assert(held < position);

    const text = emitter.tokens[held].text(emitter.source);

    if (emitter.tokens[held].is_punctuation(.bracket_close)) {
        if (emitter.brackets.open_of(held)) |open| {
            if (bracket_lookup(emitter, open)) return true;
        }
    }

    if (emitter.policy.angle_calls) {
        if (closes_angle(text)) {
            const name = opening(emitter, held, @intCast(text.len)) orelse return false;

            if (emitter.tokens[name].is_punctuation(.bracket_close)) {
                const bracket = emitter.brackets.open_of(name) orelse return false;
                return bracket_lookup(emitter, bracket);
            }

            return wide.named(emitter, name);
        }
    }

    if (walk.text_is(text, "import")) {
        if (call.import_typed(emitter, held)) return false;
    }

    return calling_named(emitter, held, position);
}

fn calling_nonnull(emitter: *const Emitter, held: u32) ?u32 {
    assert(held < emitter.count);
    assert(emitter.policy.type_words.len > 0);

    const name = emit.word_before(emitter, held) orelse return null;
    const kind = emitter.tokens[name].kind;

    const closed = kind.eql(.{ .punctuation = .paren_close }) or
        kind.eql(.{ .punctuation = .bracket_close });

    if (emitter.tokens[name].end() != emitter.tokens[held].offset) return null;
    if (wide.named(emitter, name)) return name;
    if (closed) return name;
    return null;
}

fn calling_named(emitter: *const Emitter, held: u32, position: u32) bool {
    assert(held < emitter.count);
    assert(position < emitter.count);

    if (core.memo_found(emitter, .calling_named, held, position)) |answer| return answer == 1;

    const named = calling_named_scanned(emitter, held, position);

    core.memo_store(emitter, .calling_named, held, position, @intFromBool(named));

    return named;
}

fn calling_named_scanned(emitter: *const Emitter, held: u32, position: u32) bool {
    assert(held < position);
    assert(position < emitter.count);

    if (wide.named(emitter, held)) return true;
    if (line.word_is(emitter, held, emitter.policy.callee_words)) return true;
    if (span.marked_callee(emitter, held)) return true;
    return paren_callee(emitter, held, position);
}

fn paren_callee(emitter: *const Emitter, held: u32, position: u32) bool {
    assert(held < position);
    assert(position < emitter.count);

    if (!emitter.policy.chain_simples) return false;
    if (!emitter.tokens[held].is_punctuation(.paren_close)) return false;
    if (emitter.tokens[held].end() != emitter.tokens[position].offset) return false;

    const open = emitter.brackets.open_of(held) orelse return false;
    return !split.headed(emitter, open);
}

pub fn arrowed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (!emitter.policy.arrow_parens) return false;
    if (emitter.tokens[position].kind != .identifier) return false;

    const next = emit.ahead_of(emitter, position) orelse return false;
    if (!walk.text_is(emitter.tokens[next].text(emitter.source), "=>")) return false;
    if (emit.roled(emitter, position, brace.role_type)) return false;

    const before = emit.word_before(emitter, position) orelse return true;
    const text = emitter.tokens[before].text(emitter.source);

    assert(before < position);

    if (listed_word(arrow_stops, text)) return false;
    if (!walk.text_is(text, ":")) return true;
    if (tern.ternary(emitter, before)) return true;
    return arrowed_key(emitter, before);
}

const arrow_stops: []const []const u8 = &.{
    "|",
    "&",
    ".",
    ">",
    "]",
    ")",
    "is",
    "asserts",
    "typeof",
};

const arrow_openers: []const []const u8 = &.{ "{", ",", ";" };

fn arrowed_key(emitter: *const Emitter, colon: u32) bool {
    assert(colon < emitter.count);

    var key = emit.word_before(emitter, colon) orelse return false;
    const kind = emitter.tokens[key].kind;

    if (kind.eql(.{ .punctuation = .bracket_close })) {
        key = emitter.brackets.open_of(key) orelse return false;
    } else {
        const named = kind == .identifier or kind == .number or kind == .string;
        if (!named) return false;
    }

    var opener = emit.word_before(emitter, key);

    for (0..arrow_comment_max) |_| {
        const at = opener orelse break;
        if (emitter.tokens[at].kind != .comment) break;

        opener = emit.word_before(emitter, at);
    }

    const at = opener orelse return false;

    assert(at < colon);

    return listed_word(arrow_openers, emitter.tokens[at].text(emitter.source));
}

pub fn spreads(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return false;
    return emitter.nest[emitter.depth - 1].spread != null;
}

pub fn returns_held(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return false;

    const frame = emitter.nest[emitter.depth - 1];

    if (frame.returned) assert(frame.spread == null);

    return frame.returned;
}

pub fn chains_a_header(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return false;

    const spread = line.frame(emitter).spread orelse return false;

    assert(emitter.depth > 0);

    return spread == .chain or spread == .clauses;
}

pub fn operating(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const held = emitter.tokens[position];
    const clausing = line.frame(emitter).spread == .clauses;

    const parted = if (clausing)
        held.is_punctuation(.semicolon)
    else
        line.word_is(emitter, position, emitter.policy.operator_words);

    if (!parted) return false;
    if (angled(emitter, position)) return false;
    return !nested_at(emitter, position);
}

fn nested_at(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    var depth: u32 = 0;
    var scan = line.frame(emitter).open + 1;

    while (scan < position) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else {}
    }

    return depth > 0;
}

pub fn separating(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);

    const held = emitter.previous orelse return false;

    assert(held < emitter.count);

    if (!spreads(emitter)) return false;
    if (emit.comment_ended(emitter, held)) return true;
    if (comment_standing(emitter, held)) return true;

    if (own.trailed_comma(emitter, held)) {
        if (emit.ahead_of(emitter, held)) |comment_at| {
            if (body.parts_at(emitter, held, comment_at)) return true;
        }
    }

    if (chains_a_header(emitter)) {
        if (!operating(emitter, held)) return false;

        const first = emit.back_of(emitter, held) orelse return true;
        return !emit.comment_ended(emitter, first);
    }

    const kind = emitter.tokens[held].kind;

    const separator = kind.eql(.{ .punctuation = .comma }) or
        kind.eql(.{ .punctuation = .semicolon });

    if (!separator) return false;
    return !angled(emitter, held);
}

pub fn comment_standing(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[position];
    if (token.kind != .comment) return false;
    if (!std.mem.startsWith(u8, token.text(emitter.source), "/*")) return false;

    const before = emit.back_of(emitter, position) orelse return false;
    if (!body.parts_at(emitter, before, position)) return false;

    const after = emit.ahead_of(emitter, position) orelse return false;
    return body.parts_at(emitter, position, after);
}

pub fn signature_level(emitter: *const Emitter, block: u32) ?u32 {
    assert(block < emitter.count);

    const closed = emitter.closed;
    var open: u32 = 0;
    var close: u32 = 0;

    if (closed.kind.eql(.{ .punctuation = .paren_open })) {
        if (closed.spread == null) {
            if (closed.hugged == 0) return null;
        }

        if (closed.close == 0) return null;
        if (closed.close >= block) return null;

        for (closed.close + 1..block) |scan| {
            const kind = emitter.tokens[scan].kind;
            if (walk.is_open(kind)) return null;
            if (walk.is_close(kind)) return null;
        }

        open = closed.open;
        close = closed.close;
    } else {
        const found = signature_braced(emitter, block) orelse
            signature_walked(emitter, block) orelse return null;

        open, close = found;
    }

    if (emitter.line_first <= open) return null;
    if (emitter.line_first >= close) return null;

    const level = line.level_at(emitter, open) orelse return null;
    if (level < emitter.printed) return level;
    return null;
}

fn signature_braced(emitter: *const Emitter, block: u32) ?struct { u32, u32 } {
    assert(block < emitter.count);

    const closed = emitter.closed;
    if (closed.kind != .block_start) return null;
    if (closed.close == 0) return null;
    if (emit.ahead_of(emitter, closed.close) != block) return null;

    const colon = emit.back_of(emitter, closed.open) orelse return null;
    if (!emitter.tokens[colon].is_punctuation(.colon)) return null;

    const paren = emit.back_of(emitter, colon) orelse return null;
    if (!emitter.tokens[paren].is_punctuation(.paren_close)) return null;

    const open = emitter.brackets.open_of(paren) orelse return null;

    assert(open < paren);

    return .{ open, paren };
}

pub fn signature_walked(emitter: *const Emitter, block: u32) ?struct { u32, u32 } {
    assert(block < emitter.count);

    var angles: u32 = 0;
    var scan = block;

    for (0..return_typed_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return null;
        const kind = emitter.tokens[held].kind;
        const text = emitter.tokens[held].text(emitter.source);

        assert(held < scan);

        if (closes_angle(text)) {
            angles += @intCast(text.len);
            scan = held;

            continue;
        }

        if (walk.text_is(text, "<")) {
            if (angles == 0) return null;

            angles -= 1;
            scan = held;

            continue;
        }

        const comma = kind.eql(.{ .punctuation = .comma });

        if (angles > 0) {
            if (comma) {
                scan = held;

                continue;
            }
        }

        if (kind.eql(.{ .punctuation = .colon })) {
            if (angles == 0) return signature_walked_colon(emitter, held);
        }

        if (walk.is_close(kind)) {
            const open = emitter.brackets.open_of(held) orelse return null;
            if (!signature_spelled(emitter, held, open)) return null;

            scan = open;

            continue;
        }

        if (signature_walk_stops(emitter, held)) return null;

        scan = held;
    }

    return null;
}

fn signature_walked_colon(emitter: *const Emitter, colon: u32) ?struct { u32, u32 } {
    assert(colon < emitter.count);

    const paren = emit.back_of(emitter, colon) orelse return null;
    if (!emitter.tokens[paren].is_punctuation(.paren_close)) return null;

    const open = emitter.brackets.open_of(paren) orelse return null;

    assert(open < paren);

    return .{ open, paren };
}

fn signature_spelled(emitter: *const Emitter, held: u32, open: u32) bool {
    assert(open < held);
    assert(held < emitter.count);

    const kind = emitter.tokens[held].kind;
    if (kind == .block_end) return emit.roled(emitter, open, brace.role_type);
    if (!kind.eql(.{ .punctuation = .paren_close })) return true;

    const before = emit.back_of(emitter, open) orelse return true;
    const named = emitter.tokens[before].kind;

    return named != .identifier and named != .keyword;
}

fn signature_walk_stops(emitter: *const Emitter, held: u32) bool {
    assert(held < emitter.count);

    const kind = emitter.tokens[held].kind;
    if (walk.is_open(kind)) return true;
    if (kind.eql(.{ .punctuation = .assign })) return true;
    if (kind.eql(.{ .punctuation = .comma })) return true;
    if (kind.eql(.{ .punctuation = .semicolon })) return true;
    return walk.text_is(emitter.tokens[held].text(emitter.source), "=>");
}

pub fn closes_angle(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    if (text.len == 0) return false;

    for (text) |byte| {
        if (byte != '>') return false;
    }

    assert(text[0] == '>');

    return true;
}

fn listed_word(words: []const []const u8, text: []const u8) bool {
    assert(words.len > 0);
    assert(text.len <= std.math.maxInt(u32));

    for (words) |word| {
        if (walk.text_eql(word, text)) return true;
    }

    return false;
}

pub fn opening(emitter: *const Emitter, position: u32, depth: u32) ?u32 {
    assert(position < emitter.count);
    assert(depth > 0);

    var held = position;
    var owed = depth;

    for (0..core.angle_scan_max) |_| {
        held = emit.word_before(emitter, held) orelse return null;

        const typed = emitter.policy.type_words.len > 0;
        const jumps = typed and owed > 0 and emitter.tokens[held].kind == .block_end;

        if (jumps) {
            if (emitter.brackets.open_of(held)) |open| {
                held = open;

                continue;
            }
        }

        const text = emitter.tokens[held].text(emitter.source);
        if (opening_stops(emitter, held, text)) return null;

        if (walk.text_is(text, "<")) {
            owed -= 1;

            if (owed == 0) return emit.word_before(emitter, held);
        } else if (opening_closes(text)) {
            owed += @intCast(text.len);
        } else {}
    }

    return null;
}

fn opening_stops(emitter: *const Emitter, held: u32, text: []const u8) bool {
    assert(held < emitter.count);
    assert(text.len == emitter.tokens[held].length);

    const stops: []const []const u8 = &.{ ";", "{", "}", "&&", "||", "?" };

    const stopped = for (stops) |stop| {
        if (walk.text_eql(text, stop)) break true;
    } else false;

    if (!stopped) return false;

    const marked = walk.text_is(text, "?") and tern.optional(emitter, held);
    return !marked;
}

fn opening_closes(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    if (text.len == 0) return false;

    for (text) |byte| {
        if (byte != '>') return false;
    }

    assert(text[0] == '>');

    return true;
}

pub fn signature_opens(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    return signature_headed(emitter, open);
}

pub fn arrow_sequenced(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const before = emit.back_of(emitter, open) orelse return false;
    if (!walk.text_is(emitter.tokens[before].text(emitter.source), "=>")) return false;
    if (!bind.sequence_spread(emitter, open)) return false;

    const close = join.closing_of(emitter, open) orelse return true;
    const after = emit.ahead_of(emitter, close) orelse return true;
    const kind = emitter.tokens[after].kind;

    if (emit.is_dot(emitter, after)) return false;
    if (walk.is_open(kind)) return false;
    if (kind == .string) return false;
    if (walk.text_is(emitter.tokens[after].text(emitter.source), "?")) return false;
    return !span.wrapping_operator(emitter, after);
}

pub fn cast_tupled(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emit.roled(emitter, open, brace.role_type)) return false;

    const held = emit.word_before(emitter, open) orelse return false;
    return listed_word(cast_words, emitter.tokens[held].text(emitter.source));
}

pub fn hole_comma(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[position].is_punctuation(.comma)) return false;

    const held = emit.word_before(emitter, position) orelse return false;
    const kind = emitter.tokens[held].kind;
    if (kind.eql(.{ .punctuation = .bracket_open })) return true;
    return kind.eql(.{ .punctuation = .comma });
}

pub fn edged(kind: Token.Kind) ir.Element {
    assert(walk.is_open(kind) or kind == .block_start);

    if (kind == .block_start) return .line;

    assert(kind != .block_start);

    return .soft_line;
}

pub fn parted_at(emitter: *const Emitter, from: u32, close: u32) u32 {
    assert(from <= close);
    assert(close <= emitter.count);

    var depth: u32 = 0;
    var scan = from;

    while (scan < close) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;

            continue;
        }

        if (walk.is_close(kind)) {
            depth -|= 1;

            continue;
        }

        if (depth > 0) continue;
        if (kind.eql(.{ .punctuation = .comma })) return scan;
    }

    return close;
}

pub fn written_into(emitter: *Emitter, from: u32, to: u32) error{Overflow}!void {
    assert(from <= to);
    assert(to <= emitter.count);

    var levels: [list_nest_max]ListLevel = undefined;
    var depth: u32 = 1;
    const steps_max = 4 * (to - from) + 4;
    var steps: u32 = 0;

    levels[0].count = 0;
    levels[0].index = 0;
    levels[0].writer = .{ .scan = from, .to = to, .offset = emitter.arena.count(), .tight = false };

    while (depth > 0) : (steps += 1) {
        assert(steps <= steps_max);
        assert(depth <= list_nest_max);

        const level = &levels[depth - 1];

        if (level.writer.scan < level.writer.to) {
            const scan = level.writer.scan;

            if (emitter.tokens[scan].kind != .block_start) {
                try written_token(emitter, &level.writer);

                continue;
            }

            const close = emit.closing(emitter, scan) orelse return error.Overflow;
            if (close >= level.writer.to) return error.Overflow;
            if (depth == list_nest_max) return error.Overflow;

            level.writer.scan = close + 1;
            level.writer.tight = false;

            try nested_into(emitter, &levels[depth], scan, close);

            depth += 1;

            continue;
        }

        if (depth == 1) return;

        level.index += 1;

        if (level.index < level.count) {
            try emitter.arena.push(", ");

            level.writer = list_writer(emitter, level.items[level.index]);

            continue;
        }

        try emitter.arena.push("}");

        depth -= 1;
    }
}

fn written_token(emitter: *Emitter, writer: *ListWriter) error{Overflow}!void {
    assert(writer.scan < writer.to);
    assert(writer.to <= emitter.count);

    const scan = writer.scan;
    const token = emitter.tokens[scan];

    assert(token.kind != .block_start);

    writer.scan += 1;

    if (token.length == 0) return;
    if (token.kind == .newline) return;

    const text = token.text(emitter.source);
    const held = line.word_is(emitter, scan, emitter.policy.list_tight);
    const shut = walk.text_is(text, "}") or walk.text_is(text, ")");
    const welded = shut or walk.text_is(text, "]") or walk.text_is(text, ",");
    const parted = !writer.tight and !held and !welded;

    const opened = walk.text_is(text, "{") or walk.text_is(text, "(") or
        walk.text_is(text, "[");

    writer.tight = held or opened;

    if (parted) {
        if (emitter.arena.count() > writer.offset) try emitter.arena.push(" ");
    }

    try emitter.arena.push(text);
}

fn nested_into(emitter: *Emitter, level: *ListLevel, open: u32, close: u32) error{Overflow}!void {
    assert(open < close);
    assert(close < emitter.count);

    var count: u32 = 0;
    var scan = open + 1;

    while (scan < close) {
        const stop = parted_at(emitter, scan, close);

        assert(stop >= scan);

        if (scan < stop) {
            if (count == core.list_item_max) return error.Overflow;

            level.items[count] = .{ .from = scan, .to = stop };
            count += 1;
        }

        scan = stop + 1;
    }

    nested_sorted(emitter, level.items[0..count]);

    try emitter.arena.push("{");

    level.count = count;
    level.index = 0;
    level.writer = .{ .scan = 0, .to = 0, .offset = emitter.arena.count(), .tight = false };

    if (count > 0) level.writer = list_writer(emitter, level.items[0]);
}

fn nested_sorted(emitter: *const Emitter, items: []ListItem) void {
    assert(items.len <= core.list_item_max);
    assert(emitter.count == emitter.tokens.len);

    var index: usize = 1;

    while (index < items.len) : (index += 1) {
        var back = index;

        while (back > 0) : (back -= 1) {
            if (!item_precedes(emitter, items[back], items[back - 1])) break;

            std.mem.swap(ListItem, &items[back], &items[back - 1]);
        }
    }
}

fn list_writer(emitter: *const Emitter, item: ListItem) ListWriter {
    assert(item.from < item.to);
    assert(item.to <= emitter.count);

    return .{ .scan = item.from, .to = item.to, .offset = emitter.arena.count(), .tight = false };
}

fn item_precedes(emitter: *const Emitter, left: ListItem, right: ListItem) bool {
    assert(left.from < left.to);
    assert(right.from < right.to);

    const first = classed(spelling(emitter, left));
    const second = classed(spelling(emitter, right));
    if (first.class != second.class) return first.class < second.class;
    return versioned(first.text, second.text);
}

fn spelling(emitter: *const Emitter, item: ListItem) []const u8 {
    assert(item.from < item.to);
    assert(item.to <= emitter.count);

    const from = emitter.tokens[item.from].offset;
    const source_end: u32 = @intCast(emitter.source.len);
    const to = @min(emitter.tokens[item.to - 1].end(), source_end);
    if (from >= to) return "";
    return emitter.source[from..to];
}

fn signature_room(emitter: *const Emitter) u32 {
    const room = emitter.options.line_width;

    assert(room > 0);

    return room;
}

fn comment_leads(emitter: *const Emitter, mark: u32, close: u32) bool {
    assert(mark < close);
    assert(close < emitter.count);

    const text = emitter.tokens[mark].text(emitter.source);

    const commented = std.mem.startsWith(u8, text, "//") or
        comment.leads_line(emitter, mark);

    if (!commented) return false;

    const held = emit.ahead_of(emitter, mark) orelse return false;
    if (held >= close) return false;

    const wordy = switch (emitter.tokens[held].kind) {
        .identifier, .keyword => true,
        else => false,
    };

    return wordy;
}

fn pattern_declared(emitter: *const Emitter, open: u32, close: u32) ?u32 {
    assert(open < close);
    assert(close < emitter.count);

    const keyword = emit.back_of(emitter, open) orelse return null;
    const text = emitter.tokens[keyword].text(emitter.source);
    if (!listed_word(declared_words, text)) return null;

    const after = emit.ahead_of(emitter, close) orelse return null;
    if (!emitter.tokens[after].is_punctuation(.colon)) return null;

    const angles = emitter.brackets.angles_at(after);
    var scan = emit.ahead_of(emitter, after) orelse return null;

    for (0..define_scan_max) |_| {
        assert(scan < emitter.count);

        const token = emitter.tokens[scan];
        const opens = walk.is_open(token.kind) or token.kind == .block_start;

        if (opens) {
            const shut = join.closing_of(emitter, scan) orelse return null;

            scan = emit.ahead_of(emitter, shut) orelse return null;

            continue;
        }

        const nested = emitter.brackets.angles_at(scan) > angles;

        if (!nested) {
            if (token.is_punctuation(.assign)) {
                const equals = walk.text_is(token.text(emitter.source), "=");
                if (!equals) return null;
                return scan;
            }

            const stops = token.is_punctuation(.comma) or token.is_punctuation(.semicolon);
            const closes = walk.is_close(token.kind) or token.kind == .block_end;
            const halts = stops or closes;
            if (halts) return null;
        }

        scan = emit.ahead_of(emitter, scan) orelse return null;
    }

    return null;
}

fn pattern_left_fits(emitter: *const Emitter, open: u32, equals: u32) bool {
    assert(open <= equals);
    assert(equals < emitter.count);

    const led = join.line_lead(emitter, open);
    const from = if (led) |found| found[0] else emitter.line_first;
    const level = if (led) |found| found[1] else emitter.printed;

    if (from > open) return false;

    const width = span.printed_columns(emitter, from, equals) +
        span.braced_columns(emitter, from, equals);

    const room = level * emitter.options.indent_width + width;
    return room <= emitter.options.line_width;
}

fn pattern_param_signed(emitter: *const Emitter, shut: u32) bool {
    assert(shut < emitter.count);

    const held = emit.ahead_of(emitter, shut) orelse return false;
    const token = emitter.tokens[held];
    const arrow = walk.text_is(token.text(emitter.source), "=>");

    return token.kind == .block_start or token.is_punctuation(.colon) or arrow;
}

fn pattern_param_typed(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);

    const held = emit.ahead_of(emitter, close) orelse return false;
    return emitter.tokens[held].is_punctuation(.colon);
}

fn pattern_param(emitter: *const Emitter, open: u32, close: u32) ?struct { u32, u32 } {
    assert(open < close);
    assert(close < emitter.count);

    const before = emit.back_of(emitter, open) orelse return null;
    const before_token = emitter.tokens[before];
    var paren: u32 = undefined;

    if (before_token.is_punctuation(.paren_open)) {
        paren = before;
    } else if (before_token.is_punctuation(.comma)) {
        paren = bind.enclosing_open(emitter, open) orelse return null;
    } else {
        return null;
    }

    const shut = join.closing_of(emitter, paren) orelse return null;
    const signed = pattern_param_signed(emitter, shut);
    const typed = pattern_param_typed(emitter, close);

    if (!emitter.tokens[paren].is_punctuation(.paren_open)) return null;
    if (!signed) return null;
    if (!typed) return null;
    if (wide.element_count(emitter, paren, shut) < 2) return null;

    var depth: u32 = 0;
    var end = close;
    var scan = close + 1;

    while (scan < shut) {
        assert(scan < emitter.count);

        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;
        const stops = depth == 0 and emitter.tokens[scan].is_punctuation(.comma);

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth = depth -| 1;
        } else if (stops) {
            break;
        } else {}

        if (emitter.tokens[scan].length != 0) end = scan;

        scan += 1;
    }

    assert(scan <= shut);

    return .{ paren, end };
}

fn pattern_end_hugged(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);

    const held = emit.ahead_of(emitter, close) orelse return false;
    const token = emitter.tokens[held];
    const arrow = walk.text_is(token.text(emitter.source), "=>");
    const tailed = token.kind == .block_start or token.is_punctuation(.colon);

    return arrow or tailed;
}

fn pattern_end(emitter: *const Emitter, close: u32, objects: bool) u32 {
    assert(close < emitter.count);

    var depth: u32 = 0;
    var scan = close;

    for (0..define_scan_max) |_| {
        const next = emit.ahead_of(emitter, scan) orelse return scan;

        assert(next < emitter.count);

        const kind = emitter.tokens[next].kind;

        const objected = objects and kind == .block_start and
            !body.bodied_brace(emitter, next) and
            !call.object_parted(emitter, next) and
            !emit.roled(emitter, next, brace.role_type);

        if (objected) {
            depth += 1;
            scan = next;

            continue;
        }

        if (kind == .block_start) {
            const emptied = depth == 0 and
                join.closing_of(emitter, next) == emit.ahead_of(emitter, next);

            if (!emptied) return next;

            scan = join.closing_of(emitter, next) orelse return next;

            continue;
        }

        const opens = walk.is_open(kind);
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            if (depth == 0) {
                const hugged = emitter.tokens[next].is_punctuation(.paren_close) and
                    pattern_end_hugged(emitter, next);

                if (!hugged) return scan;

                scan = next;

                continue;
            }

            depth -= 1;
        } else {
            const comma = emitter.tokens[next].is_punctuation(.comma);
            const semicolon = emitter.tokens[next].is_punctuation(.semicolon);
            const stops = depth == 0 and (comma or semicolon);
            if (stops) return next;
        }

        scan = next;
    }

    return scan;
}

fn pattern_fits_to(emitter: *const Emitter, open: u32, close: u32, objects: bool) bool {
    assert(open <= close);
    assert(close < emitter.count);

    const led = join.line_lead(emitter, open);
    const from = if (led) |found| found[0] else emitter.line_first;
    const level = if (led) |found| found[1] else emitter.printed;

    if (from > open) return false;

    const end = pattern_end(emitter, close, objects);

    const width = span.printed_columns(emitter, from, end) +
        span.braced_columns(emitter, from, end);

    const room = level * emitter.options.indent_width + width;
    return room <= emitter.options.line_width;
}

pub fn pattern_fits(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (pattern_declared(emitter, open, close)) |equals| {
        return pattern_left_fits(emitter, open, equals);
    }

    return pattern_fits_to(emitter, open, close, false);
}

fn pattern_nested_defaulted(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);

    if (emit.back_of(emitter, scan)) |held| {
        if (walk.text_is(emitter.tokens[held].text(emitter.source), "=")) return true;
    }

    const shut = join.closing_of(emitter, scan) orelse return false;
    const after = emit.ahead_of(emitter, shut) orelse return false;

    return walk.text_is(emitter.tokens[after].text(emitter.source), "=");
}

pub fn pattern_nested(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var scan = open + 1;

    while (scan < close) {
        assert(scan < emitter.count);

        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            const defaulted = pattern_nested_defaulted(emitter, scan);
            const bracketed = kind == .block_start or kind.eql(.{ .punctuation = .bracket_open });
            const found = depth == 0 and !defaulted and bracketed;
            if (found) return true;

            depth += 1;
        } else if (closes) {
            depth = depth -| 1;
        } else {}

        scan += 1;
    }

    return false;
}

fn signature_objected(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);

    if (emitter.tokens[head].kind != .block_start) return false;

    const shut = join.closing_of(emitter, head) orelse return true;
    const after = emit.ahead_of(emitter, shut) orelse return true;
    const text = emitter.tokens[after].text(emitter.source);
    const unioned = walk.text_is(text, "|") or walk.text_is(text, "&");

    return !unioned;
}

fn signature_type_columns_separated(emitter: *const Emitter, end: u32) bool {
    assert(end < emitter.count);

    const after = emit.ahead_of(emitter, end) orelse return false;
    const token = emitter.tokens[after];

    return token.is_punctuation(.comma) or token.is_punctuation(.semicolon);
}

fn signature_type_columns(emitter: *const Emitter, start: u32, end: u32) u32 {
    assert(start <= end);
    assert(end < emitter.count);

    const separator = signature_type_columns_separated(emitter, end);
    const tail: u32 = if (separator) 1 else 0;
    const returned = span.printed_columns(emitter, start, end) + tail;

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn infer_constrained(emitter: *const Emitter, extends: u32) bool {
    assert(extends < emitter.count);

    const held = emit.back_of(emitter, extends) orelse return false;
    if (emitter.tokens[held].kind != .identifier) return false;

    const name = emit.back_of(emitter, held) orelse return false;
    return walk.text_is(emitter.tokens[name].text(emitter.source), "infer");
}

pub fn argued_seat(emitter: *const Emitter, seat: u32) bool {
    assert(seat < emitter.count);

    const token = emitter.tokens[seat];
    const comma_or_paren = token.is_punctuation(.comma) or token.is_punctuation(.paren_open);
    if (comma_or_paren) return true;
    if (token.is_punctuation(.bracket_open)) return true;

    const equals = walk.text_is(token.text(emitter.source), "=");
    if (!equals) return false;
    return own.param_defaulted(emitter);
}

pub fn paren_tested(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const held = emit.ahead_of(emitter, close) orelse return false;
    const text = emitter.tokens[held].text(emitter.source);
    var tested = walk.text_is(text, "extends");

    if (!tested) {
        if (walk.text_is(text, "?")) tested = !tern.optional(emitter, held);
    }

    if (!tested) return false;
    return paren_conditional(emitter, open, close);
}

pub fn paren_conditional(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or bind.spans_open(emitter, scan);

        if (opens) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            const text = emitter.tokens[scan].text(emitter.source);
            if (walk.text_is(text, "?")) return !tern.optional(emitter, scan);
            if (walk.text_is(text, "=>")) return false;
            if (kind.eql(.{ .punctuation = .assign })) return false;
            if (own.compound_assign(emitter, scan)) return false;
        } else {}
    }

    return false;
}

pub fn paren_operated(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var found = false;
    var scan = open + 1;

    while (scan < close) {
        if (tmpl.spanned_unit(emitter, scan)) |end| {
            assert(end >= scan);

            scan = end + 1;

            continue;
        }

        const token = emitter.tokens[scan];

        if (walk.is_open(token.kind)) {
            depth += 1;
        } else if (walk.is_close(token.kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (paren_operated_stops(emitter, token)) return false;

            if (!found) found = span.wrapping_operator(emitter, scan);
        } else {}

        scan += 1;
    }

    return found;
}

fn paren_operated_stops(emitter: *const Emitter, token: Token) bool {
    assert(emitter.count == emitter.tokens.len);

    if (token.is_punctuation(.comma)) return true;
    if (token.is_punctuation(.semicolon)) return true;
    return walk.text_is(token.text(emitter.source), "=>");
}

fn holding(emitter: *const Emitter, position: u32, held: bool) ?u32 {
    assert(position < emitter.count);

    const close = join.closing_of(emitter, position) orelse return null;

    if (held) return null;
    if (spreading(emitter, position, close) == null) return null;

    assert(close < emitter.count);

    return close;
}

pub fn assign_holds(emitter: *const Emitter, open: u32, breaks: bool, counted: bool) ?u32 {
    assert(open < emitter.count);

    const close = join.closing_of(emitter, open) orelse return null;

    if (breaks) {
        const next = emit.ahead_of(emitter, open);
        if (next == close) return close;
    }

    const held = counted and !breaks;
    return holding(emitter, open, held);
}

fn chain_calling_blocked(emitter: *const Emitter, held: u32, position: u32) bool {
    assert(held < position);

    if (paren_callee(emitter, held, position)) return true;

    const text = emitter.tokens[held].text(emitter.source);
    const optional_call = walk.text_is(text, "?.");
    if (!optional_call) return false;

    const callee = emit.word_before(emitter, held) orelse return false;
    return emitter.tokens[callee].is_punctuation(.paren_close);
}

pub fn chain_calling(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (!calling(emitter, position)) return false;

    const held = emit.word_before(emitter, position) orelse return true;
    return !chain_calling_blocked(emitter, held, position);
}

pub fn param_hugs(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const inner = emit.ahead_of(emitter, open) orelse return false;
    if (inner >= close) return false;

    const tail = param_hugs_last(emitter, close) orelse return false;
    if (param_commented(emitter, inner, tail)) return false;

    const token = emitter.tokens[inner];
    const braced = token.kind == .block_start or token.is_punctuation(.bracket_open);
    if (braced) return param_hugs_pattern(emitter, open, inner, tail);

    const receiver = walk.text_is(token.text(emitter.source), "this");

    if (token.kind != .identifier) {
        if (!receiver) return false;
    }

    var colon = emit.ahead_of(emitter, inner) orelse return false;

    if (walk.text_is(emitter.tokens[colon].text(emitter.source), "?")) {
        colon = emit.ahead_of(emitter, colon) orelse return false;
    }

    if (!emitter.tokens[colon].is_punctuation(.colon)) return false;

    const head = emit.ahead_of(emitter, colon) orelse return false;
    if (emitter.tokens[head].kind != .block_start) return false;
    return join.closing_of(emitter, head) == tail;
}

fn param_hugs_last(emitter: *const Emitter, close: u32) ?u32 {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.back_of(emitter, close) orelse return null;
    if (!emitter.tokens[held].is_punctuation(.comma)) return held;
    return emit.back_of(emitter, held);
}

fn param_hugs_pattern(emitter: *const Emitter, open: u32, inner: u32, tail: u32) bool {
    assert(open < inner);
    assert(inner < emitter.count);
    assert(tail < emitter.count);

    const shut = join.closing_of(emitter, inner) orelse return false;
    const assign = param_hugs_default(emitter, open, shut, tail) orelse return true;
    const value = emit.ahead_of(emitter, assign) orelse return false;

    assert(value > assign);

    var emptied = false;

    if (emit.ahead_of(emitter, value)) |held| {
        if (held == tail) emptied = join.closing_of(emitter, value) == held;
    }

    if (value == tail) {
        if (emitter.tokens[value].kind == .identifier) return true;
    }

    return emptied;
}

fn param_hugs_default(emitter: *const Emitter, open: u32, shut: u32, tail: u32) ?u32 {
    assert(open < shut);
    assert(shut < emitter.count);
    assert(tail < emitter.count);

    const angles = emitter.brackets.angles_at(open);
    var scan = shut + 1;

    while (scan < tail) : (scan += 1) {
        if (!emitter.tokens[scan].is_punctuation(.assign)) continue;

        if (emitter.brackets.angles_at(scan) == angles) {
            assert(scan <= emitter.count);

            return scan;
        }
    }

    return null;
}

const bracket_value_max: u32 = 8;
const cast_lookup_max: u32 = 16;
const chain_head_max: u32 = 64;
const template_tag_scan_max: u32 = 16;
const slight_words: []const []const u8 = &.{ "false", "null", "this", "true", "undefined" };

fn bracket_valued(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const head = chain_headed(emitter, open) orelse return true;
    var scan = head;

    for (0..bracket_value_max) |_| {
        const before = emit.back_of(emitter, scan) orelse return false;
        const token = emitter.tokens[before];
        const ended = lookup_cast(emitter, open) or lookup_operand(emitter, open);
        if (walk.text_is(token.text(emitter.source), "=")) return !ended;

        if (token.is_punctuation(.colon)) {
            if (!tern.ternary(emitter, before)) return !ended;
        }

        const closed = walk.is_close(token.kind) or token.kind == .block_end;

        if (closed) {
            scan = emitter.brackets.open_of(before) orelse return false;

            continue;
        }

        if (!bracket_value_stepped(emitter, before)) return false;

        assert(before < scan);

        scan = before;
    }

    return false;
}

fn bracket_value_stepped(emitter: *const Emitter, before: u32) bool {
    assert(before < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[before];

    if (emit.is_dot(emitter, before)) return true;
    if (token.kind == .identifier) return true;
    if (line.word_is(emitter, before, emitter.policy.cast_words)) return true;
    if (line.word_is(emitter, before, emitter.policy.operand_words)) return true;
    return walk.text_is(token.text(emitter.source), "!");
}

pub fn bracket_slight(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const head = chain_headed(emitter, open) orelse return false;
    const token = emitter.tokens[head];
    const operand = line.word_is(emitter, head, emitter.policy.operand_words);
    const imported = walk.text_is(token.text(emitter.source), "import");
    const simple = token.kind == .identifier or (operand and !imported);
    if (!simple) return false;

    var scan = head;

    while (scan < emitter.count) {
        const linked = emit.ahead_of(emitter, scan) orelse return true;
        const kind = emitter.tokens[linked].kind;

        if (!walk.is_open(kind)) {
            const asserted = walk.text_is(emitter.tokens[linked].text(emitter.source), "!");
            const stepped = emit.is_dot(emitter, linked) or kind == .identifier or asserted;
            if (!stepped) return true;

            scan = linked;

            continue;
        }

        const closes = join.closing_of(emitter, linked) orelse return false;

        if (emitter.tokens[linked].is_punctuation(.paren_open)) {
            const empty = emit.ahead_of(emitter, linked) == closes;

            if (!empty) {
                if (!slight(emitter, linked, closes)) return false;
            }
        }

        assert(closes > scan);

        scan = closes;
    }

    return true;
}

fn chain_headed(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = open;

    for (0..chain_head_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return null;
        const kind = emitter.tokens[held].kind;

        if (walk.is_close(kind)) {
            scan = emitter.brackets.open_of(held) orelse return null;

            continue;
        }

        if (emit.is_dot(emitter, held)) {
            scan = held;

            continue;
        }

        if (walk.text_is(emitter.tokens[held].text(emitter.source), "!")) {
            if (emit.back_of(emitter, held)) |object| {
                if (emitter.tokens[object].ends_a_value()) {
                    scan = held;

                    continue;
                }
            }
        }

        const operand = line.word_is(emitter, held, emitter.policy.operand_words);
        const worded = kind == .identifier or operand;
        if (!worded) return null;

        if (emit.back_of(emitter, held)) |found| {
            if (emit.is_dot(emitter, found)) {
                scan = held;

                continue;
            }
        }

        assert(held < open);

        return held;
    }

    return null;
}

pub fn assign_held(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    var element = false;

    if (emitter.depth > 0) {
        if (lead.owing_grouped(emitter)) element = span.binary_argued_run(emitter, previous, false);
    }

    if (!assign_owed(emitter)) return false;
    if (tern.binary_branched(emitter, previous)) return false;
    return !element;
}

pub fn assign_owed(emitter: *const Emitter) bool {
    assert(emitter.assigns <= core.assign_depth_max);

    return emitter.assigns > 0 or emitter.owed > 0;
}

pub fn hugged_params_wide(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const open = emit.ahead_of(emitter, close) orelse return false;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const shut = join.closing_of(emitter, open) orelse return false;
    if (signature_count(emitter, open, shut) != 1) return false;
    if (!param_hugs(emitter, open, shut)) return false;

    const bracket = hugged_params_bracket(emitter, open, shut) orelse return false;
    const columns = span.printed_columns(emitter, emitter.line_first, bracket);

    return emitter.printed * emitter.options.indent_width + columns > emitter.options.line_width;
}

fn hugged_params_bracket(emitter: *const Emitter, open: u32, shut: u32) ?u32 {
    assert(open < shut);
    assert(shut < emitter.count);

    var scan = open + 1;

    while (scan < shut) : (scan += 1) {
        const token = emitter.tokens[scan];

        if (token.kind == .block_start) {
            assert(scan <= emitter.count);

            return scan;
        }

        if (token.is_punctuation(.bracket_open)) {
            assert(scan <= emitter.count);

            return scan;
        }
    }

    return null;
}

pub fn slight_worded(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position < close);
    assert(close < emitter.count);

    if (slight(emitter, position, close)) return true;

    const held = emit.ahead_of(emitter, position) orelse return false;
    if (emit.ahead_of(emitter, held) != close) return false;
    return listed_word(slight_words, emitter.tokens[held].text(emitter.source));
}

pub fn lookup_cast(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const after = lookup_after(emitter, open) orelse return false;
    return listed_word(cast_words, emitter.tokens[after].text(emitter.source));
}

fn lookup_operand(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const after = lookup_after(emitter, open) orelse return false;
    if (span.wrapping_operator(emitter, after)) return true;
    if (!walk.text_is(emitter.tokens[after].text(emitter.source), "?")) return false;
    return !tern.optional(emitter, after);
}

fn lookup_after(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = join.closing_of(emitter, open) orelse return null;

    for (0..chain_head_max) |_| {
        const after = emit.ahead_of(emitter, scan) orelse return null;
        const token = emitter.tokens[after];
        const opened = token.is_punctuation(.bracket_open) or token.is_punctuation(.paren_open);

        if (opened) {
            scan = join.closing_of(emitter, after) orelse return null;

            continue;
        }

        if (!lookup_linked(emitter, after)) return after;

        assert(after > scan);

        scan = after;
    }

    return null;
}

fn lookup_linked(emitter: *const Emitter, after: u32) bool {
    assert(after < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[after];

    if (emit.is_dot(emitter, after)) return true;
    if (walk.text_is(token.text(emitter.source), "!")) return true;
    if (token.kind == .comment) return true;

    const worded = token.kind == .identifier or token.kind == .keyword;
    if (!worded) return false;

    const held = emit.back_of(emitter, after) orelse return false;
    return emit.is_dot(emitter, held);
}

fn lookup_paired(emitter: *const Emitter, open: u32) ?bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const head = chain_headed(emitter, open) orelse return null;
    const colon = emit.back_of(emitter, head) orelse return null;
    if (!emitter.tokens[colon].is_punctuation(.colon)) return null;
    if (tern.ternary(emitter, colon)) return null;

    const ended = lookup_paired_stop(emitter, head) orelse return null;
    const level = bracket_owed_level(emitter);
    const columns = span.printed_columns(emitter, head, ended[0]);

    return level * emitter.options.indent_width + columns + ended[1] > emitter.options.line_width;
}

fn lookup_paired_stop(emitter: *const Emitter, head: u32) ?struct { u32, u32 } {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var depth: u32 = 0;
    var scan = head;

    while (scan < emitter.count) : (scan += 1) {
        const token = emitter.tokens[scan];

        if (walk.is_open(token.kind)) {
            depth += 1;
        } else if (walk.is_close(token.kind)) {
            if (depth == 0) {
                const stop = emit.back_of(emitter, scan) orelse return null;
                return .{ stop, 1 };
            }

            depth -= 1;
        } else if (depth == 0) {
            const ended = token.is_punctuation(.comma) or token.is_punctuation(.semicolon);
            if (ended) return .{ scan, 0 };
        } else {}
    }

    return null;
}

fn bracket_owed_level(emitter: *const Emitter) u32 {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.assigns <= core.assign_depth_max);

    const spread_levels = span.spread_count(emitter);
    const wraps = span.wrap_levels(emitter);
    const returned = @max(emitter.printed, emitter.levels) + spread_levels + wraps + 1;

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn cast_lookup(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = open;

    for (0..cast_lookup_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;
        const text = emitter.tokens[held].text(emitter.source);
        if (listed_word(cast_words, text)) return scan != open;

        if (emitter.tokens[held].kind != .identifier) {
            if (!walk.text_is(text, ".")) return false;
        }

        assert(held < scan);

        scan = held;
    }

    return false;
}

fn bracket_owed(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.assigns <= core.assign_depth_max);

    if (!bracket_poorly(emitter, open)) return false;
    if (lookup_paired(emitter, open)) |paired| return paired;

    var owed: ?u32 = null;
    var held = emitter.assigns;

    while (held > 0) {
        held -= 1;

        if (emitter.assigned[held].equals < open) {
            owed = held;

            break;
        }
    }

    const found = owed orelse return false;
    const head = emit.ahead_of(emitter, emitter.assigned[found].equals) orelse return false;
    const stop = span.statement_stop(emitter, head) orelse return false;
    if (stop <= open) return false;

    const level = bracket_owed_level(emitter);
    const columns = span.printed_columns(emitter, head, stop);

    return level * emitter.options.indent_width + columns > emitter.options.line_width;
}

pub fn bracket_poorly(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[open].is_punctuation(.bracket_open)) return false;
    if (!bracket_slight(emitter, open)) return false;
    if (lookup_cast(emitter, open)) return false;

    if (emit.ahead_of(emitter, open)) |inner| {
        if (walk.is_open(emitter.tokens[inner].kind)) return false;
    }

    const head = chain_headed(emitter, open) orelse return false;
    if (span.member_typed(emitter, head, open)) return false;

    const held = emit.word_before(emitter, head) orelse return true;
    return !listed_word(cast_words, emitter.tokens[held].text(emitter.source));
}

pub fn slight(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position < close);
    assert(close < emitter.count);

    if (emitter.policy.assign_values) {
        if (emitter.tokens[position].kind == .block_start) {
            if (body.parts_at(emitter, position, close)) return false;
        }
    }

    if (slight_signed(emitter, position, close)) return true;
    if (slight_template(emitter, position, close)) return true;

    var found: ?u32 = null;
    var scan = position + 1;

    while (scan < close) : (scan += 1) {
        const token = emitter.tokens[scan];
        const carried = token.is_punctuation(.comma) and emit.ahead_of(emitter, scan) == close;
        const counted = token.kind != .newline and token.length > 0;

        if (counted) {
            if (!carried) {
                if (found != null) return false;

                found = scan;
            }
        }
    }

    const held = found orelse return false;
    const kind = emitter.tokens[held].kind;
    const valued = kind == .identifier or kind == .number or kind == .string;
    if (!valued) return false;
    return emitter.tokens[held].length <= emitter.options.line_width / 4;
}

fn slight_signed(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position < close);
    assert(close < emitter.count);

    const sign = emit.ahead_of(emitter, position) orelse return false;
    if (sign >= close) return false;

    const text = emitter.tokens[sign].text(emitter.source);
    const signed = walk.text_is(text, "-") or walk.text_is(text, "+");
    if (!signed) return false;

    const number = emit.ahead_of(emitter, sign) orelse return false;
    if (emitter.tokens[number].kind != .number) return false;

    const held = emit.ahead_of(emitter, number) orelse return false;
    return slight_closed(emitter, held, close);
}

fn slight_closed(emitter: *const Emitter, held: u32, close: u32) bool {
    assert(held < emitter.count);
    assert(close < emitter.count);

    if (held == close) return true;
    if (!emitter.tokens[held].is_punctuation(.comma)) return false;
    return emit.ahead_of(emitter, held) == close;
}

fn slight_template(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position < close);
    assert(close < emitter.count);

    const open = emit.ahead_of(emitter, position) orelse return false;
    if (!slight_tick(emitter, open)) return false;

    var end = emit.ahead_of(emitter, open) orelse return false;

    if (!slight_tick(emitter, end)) {
        const chunk = emitter.tokens[end];
        const lined = std.mem.findScalar(u8, chunk.text(emitter.source), '\n') != null;
        const fits = chunk.length <= emitter.options.line_width / 4;
        const short = chunk.kind == .string and fits and !lined;
        const held = emit.ahead_of(emitter, end) orelse return false;

        if (!short) return false;
        if (!slight_tick(emitter, held)) return false;

        end = held;
    }

    const after = emit.ahead_of(emitter, end) orelse return false;
    return slight_closed(emitter, after, close);
}

fn slight_tick(emitter: *const Emitter, held: u32) bool {
    assert(held < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.tokens[held].kind != .string) return false;
    return walk.text_is(emitter.tokens[held].text(emitter.source), "`");
}
