const std = @import("std");
const assert = std.debug.assert;
const Token = @import("../../syntax/token.zig");
const assembly = @import("assembly.zig");
const bind = @import("bind.zig");
const body = @import("body.zig");
const brace = @import("../brace.zig");
const call = @import("call.zig");
const clause = @import("clause.zig");
const comment = @import("comment.zig");
const core = @import("emitter.zig");
const emit = @import("emit.zig");
const ir = @import("../ir.zig");
const items = @import("items.zig");
const join = @import("join.zig");
const jsx = @import("jsx.zig");
const key = @import("key.zig");
const levels = @import("level.zig");
const link = @import("link.zig");
const list = @import("list.zig");
const own = @import("own.zig");
const payload = @import("payload.zig");
const print = @import("../print.zig");
const sole = @import("sole.zig");
const span = @import("span.zig");
const split = @import("split.zig");
const tern = @import("tern.zig");
const tmpl = @import("tmpl.zig");
const unite = @import("unite.zig");
const walk = @import("../walk.zig");
const wide = @import("wide.zig");
const Emitter = core.Emitter;
const bound_heads: []const []const u8 = &.{ "enum", "fn", "struct", "trait", "type", "union" };
const bound_stops: []const []const u8 = &.{ "=", "where" };
const fallback_scan_max: u32 = 6;
const fallback_words: []const []const u8 = &.{ "catch", "orelse" };

const group_name_follows: []const []const u8 = &.{
    "!",
    ")",
    ",",
    ".",
    ":",
    ";",
    "=",
    "=>",
    "?",
    "?.",
    "]",
    "}",
};

const type_group_words: []const []const u8 = &.{ "asserts", "unique" };
const while_words: []const []const u8 = &.{"while"};

const Bounds = struct {
    claused: bool,
    colon: ?u32,
    depth: u32,
    start: u32,
};

pub fn newline(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    try comment.else_comments(emitter, position);

    const moved = emit.comment_opening(emitter, position) orelse
        comment.dotted(emitter, position);

    if (moved) |held| {
        emitter.comment_moved = .{ .open = position, .comment = held };

        try emitter.document.push(.space);
        try emitter.document.push(.{ .verbatim = emit.written(emitter, held) });
    }

    try assign_closed(emitter);

    const edged = emitter.policy.brace_parts and split.edges(emitter, position);
    const blank_lines = if (edged) 0 else newline_blanks(emitter, position);

    emitter.line_start = true;
    emitter.suppress_space = false;

    try emitter.document.push(.hard_line);
    try emitter.document.push(.{ .blank_line = blank_lines });
}

fn newline_blanks(emitter: *const Emitter, position: u32) u32 {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (headed(emitter)) return blanks(emitter, position);

    const blank_count = @min(blanks(emitter, position), emitter.policy.blank_max);
    return @max(blank_count, split.apart(emitter, position));
}

fn headed(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.head_blanks) return false;

    const prior = emitter.previous orelse return false;
    const token = emitter.tokens[prior];
    const text = token.text(emitter.source);

    if (token.kind != .comment) return false;
    return std.mem.startsWith(u8, text, "#!") or std.mem.startsWith(u8, text, "---");
}

fn blanks(emitter: *const Emitter, position: u32) u32 {
    assert(position < emitter.count);

    const prior = emitter.previous orelse return 0;

    assert(prior < emitter.count);

    if (emit.mark_of(emitter, position) & brace.mark_packed != 0) return 0;

    if (join.arm_closed(emitter)) {
        const held = emit.ahead_of(emitter, prior) orelse prior;
        const from = emitter.tokens[held].end();
        const returned = body.parted_by(emitter, from, emitter.tokens[position].offset) -| 1;

        assert(returned < std.math.maxInt(u32));

        return returned;
    }

    if (blanks_dropped(emitter, position, prior)) return 0;

    const held = emitter.tokens[prior].kind;
    const kind = emitter.tokens[position].kind;
    const opened = held == .block_start and !moduled(emitter, prior, core.module_words);
    const closed = kind == .block_end and !blanks_foreign(emitter, position);
    const bracket_opened = walk.is_open(held) and held != .block_start;
    const bracket_closed = walk.is_close(kind) and kind != .block_end;
    const edged = opened or closed or bracket_opened or bracket_closed;
    const commented = held == .comment or kind == .comment;
    const edge_dropped = emitter.policy.blank_edges and edged;
    const edge_kept = emitter.policy.edge_blanks and edged and !commented;

    if (edge_dropped) return 0;
    if (edge_kept) return 0;

    const from = emitter.tokens[prior].end();
    const to = emitter.tokens[position].offset;

    if (emitter.voided > from) {
        const before = body.parted_by(emitter, from, emitter.voided - 1) -| 1;
        const after = body.parted_by(emitter, emitter.voided, to) -| 1;

        return @max(before, after);
    }

    if (blanks_guarded(emitter, prior)) |guard| {
        const before = body.parted_by(emitter, guard, emitter.tokens[prior].offset) -| 1;
        const after = body.parted_by(emitter, from, to) -| 1;

        return @max(before, after);
    }

    const returned = body.parted_by(emitter, from, to) -| 1;

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn blanks_guarded(emitter: *const Emitter, prior: u32) ?u32 {
    assert(prior < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[prior].is_punctuation(.semicolon)) return null;

    const before = emit.back_of(emitter, prior) orelse return null;

    assert(before < prior);

    if (!body.parts_at(emitter, before, prior)) return null;
    return emitter.tokens[before].end();
}

fn blanks_dropped(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    if (join.listed_blank(emitter)) return true;
    if (wide.inner_blank(emitter, position, prior)) return true;
    if (comment.dangling_blank(emitter, position, prior)) return true;
    if (split.arms(emitter, prior)) return true;
    if (bind.declares_item(emitter, prior)) return true;
    if (comment.operator_blanked(emitter)) return true;
    return tern.ternary_blank(emitter, position);
}

fn blanks_foreign(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.tokens[position].kind == .block_end);

    const open = emit.opened(emitter, position) orelse return false;

    assert(open < position);

    return moduled(emitter, open, core.foreign_words);
}

fn moduled(emitter: *const Emitter, open: u32, words: []const []const u8) bool {
    assert(open < emitter.count);
    assert(words.len > 0);

    var scan = open;

    for (0..core.type_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;
        const token = emitter.tokens[held];
        const kind = token.kind;

        const stops = walk.is_close(kind) or kind == .block_start or
            token.is_punctuation(.semicolon);

        assert(held < scan);

        if (stops) return false;
        if (word_in(token.text(emitter.source), words)) return true;

        scan = held;
    }

    return false;
}

pub fn dedents(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const token = emitter.tokens[position];
    if (walk.is_close(token.kind)) return true;

    if (key.labels(emitter, position)) {
        if (!continues(emitter, position, false)) return true;
    }

    if (token.kind == .comment) return dedents_comment(emitter, position);
    return word_in(token.text(emitter.source), emitter.policy.dedent_words);
}

fn dedents_comment(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.tokens[position].kind == .comment);

    var scan = emit.ahead_of(emitter, position);
    var steps: u32 = 0;

    while (scan) |held| : (steps += 1) {
        assert(steps < emitter.count);
        assert(held > position);

        if (emitter.tokens[held].kind != .comment) break;

        scan = emit.ahead_of(emitter, held);
    }

    const ahead = scan orelse return false;
    const closes = emitter.policy.comment_dedents and emitter.tokens[ahead].kind == .block_end;
    const worded = word_in(emitter.tokens[ahead].text(emitter.source), emitter.policy.dedent_words);
    const dedenting = closes or worded;
    if (!dedenting) return false;
    return column_of(emitter, position) <= column_of(emitter, ahead);
}

pub fn column_of(emitter: *const Emitter, position: u32) u32 {
    assert(position < emitter.count);

    const offset = emitter.tokens[position].offset;
    var start = offset;

    while (start > 0) : (start -= 1) {
        if (emitter.source[start - 1] == '\n') break;
    }

    assert(start <= offset);
    assert(offset <= emitter.source.len);

    return offset - start;
}

fn pops(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const token = emitter.tokens[position];

    if (emit.roled(emitter, position, brace.role_span)) return false;
    if (walk.is_close(token.kind)) return false;

    if (token.is_punctuation(.colon)) {
        if (assembly.asm_framed(emitter)) return false;
    }

    if (emitter.continued) {
        if (!emitter.policy.span_levels) return false;
    }

    if (string_commented(emitter, position)) return false;

    const prior = string_prior(emitter) orelse return false;
    if (!emit.roled(emitter, prior, brace.role_span)) return false;

    const opened = span_start(emitter, prior);
    const before = emit.back_of(emitter, opened);

    assert(opened <= prior);

    const heads = if (before) |held| pops_heads(emitter, held) else false;

    if (!heads) {
        if (!emitter.policy.span_levels) return false;
    }

    const ahead = emit.ahead_of(emitter, position) orelse return true;
    return !walk.is_close(emitter.tokens[ahead].kind);
}

fn pops_heads(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const token = emitter.tokens[position];
    if (walk.is_open(token.kind)) return true;
    return token.is_punctuation(.comma);
}

pub fn string_commented(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (!emitter.policy.header_levels) return false;
    if (emitter.tokens[position].kind != .comment) return false;

    const prior = coded(emitter) orelse return false;
    return emit.roled(emitter, prior, brace.role_span);
}

fn string_prior(emitter: *const Emitter) ?u32 {
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.policy.header_levels) return coded(emitter);
    return emitter.previous;
}

fn string_valued(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (string_commented(emitter, position)) return false;

    const prior = string_prior(emitter) orelse return false;

    assert(prior < emitter.count);

    if (!emit.roled(emitter, prior, brace.role_span)) return false;
    if (emit.roled(emitter, position, brace.role_span)) return false;
    if (walk.is_close(emitter.tokens[position].kind)) return false;
    if (!emitter.policy.header_levels) return false;
    if (!items.item_inlined(emitter)) return false;

    const opened = span_start(emitter, prior);
    const before = emit.back_of(emitter, opened) orelse return false;
    if (!walk.text_is(emitter.tokens[before].text(emitter.source), "=")) return false;

    const ahead = emit.ahead_of(emitter, position) orelse return true;
    return !walk.is_close(emitter.tokens[ahead].kind);
}

pub fn popped(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (string_valued(emitter, position)) {
        assert(emitter.printed -| 1 < std.math.maxInt(u32));

        return emitter.printed -| 1;
    }

    if (!pops(emitter, position)) return null;

    if (!emitter.policy.span_levels) {
        assert(emitter.levels -| 1 < std.math.maxInt(u32));

        return emitter.levels -| 1;
    }

    const braced = emitter.depth > 0 and emitter.nest[emitter.depth - 1].kind == .block_start;
    const held = braced and emitter.printed <= emitter.levels;
    if (held) return null;
    assert(emitter.printed -| 1 < std.math.maxInt(u32));

    return emitter.printed -| 1;
}

fn span_start(emitter: *const Emitter, position: u32) u32 {
    assert(position < emitter.count);

    var scan = position;
    var steps: u32 = 0;

    while (emit.back_of(emitter, scan)) |held| : (steps += 1) {
        assert(steps < emitter.count);
        assert(held < scan);

        if (!emit.roled(emitter, held, brace.role_span)) break;

        scan = held;
    }

    assert(scan <= position);

    return scan;
}

fn binding(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    if (payload.closer(emitter, position)) return null;

    const run_end = punctuated_run(emitter, position);
    const token = emitter.tokens[position];

    assert(run_end >= position);

    const bytes = if (emitter.policy.binding_leads)
        emitter.source[token.offset..emitter.tokens[run_end].end()]
    else
        token.text(emitter.source);

    for (emitter.policy.binding_words, 0..) |tier, index| {
        if (word_in(bytes, tier)) {
            assert(index < emitter.policy.binding_words.len);

            return @intCast(index);
        }
    }

    return null;
}

pub fn bounded(emitter: *Emitter, wanted: u32, leading: ?u32) u32 {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(wanted < std.math.maxInt(u32));
    if (leading) |held| assert(held < emitter.count);

    if (bounds(emitter)) {
        bounded_reset(emitter, @intCast(emitter.policy.binding_words.len), wanted);

        return wanted;
    }

    const above = if (emitter.policy.binding_codes) coded(emitter) else emitter.previous;
    const found = if (emitter.policy.binding_leads) leading else above;
    const held = if (found) |position| binding(emitter, position) else null;

    if (held == null) {
        if (leading) |led| {
            if (led_tier(emitter, led)) |tier| return bounded_led(emitter, wanted, tier);
        }
    }

    const precedence = held orelse return bounded_unbound(emitter, wanted, leading);
    const fresh = emitter.bound == 0 or emitter.bound_depth != emitter.depth;

    if (fresh) {
        bounded_reset(emitter, precedence, wanted);

        return wanted;
    }

    while (emitter.bound > 1) {
        if (emitter.bindings[emitter.bound - 1].tier >= precedence) break;

        emitter.bound -= 1;
    }

    const tiered = emitter.bindings[emitter.bound - 1];

    if (tiered.tier <= precedence) {
        if (!emitter.policy.binding_leads) emitter.bindings[emitter.bound - 1].tier = precedence;

        return tiered.level;
    }

    if (emitter.bound < core.binding_depth_max) {
        emitter.bindings[emitter.bound] = .{ .tier = precedence, .level = tiered.level + 1 };
        emitter.bound += 1;
    }

    assert(emitter.bound <= core.binding_depth_max);

    return tiered.level + 1;
}

pub fn led_tier(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.header_levels) return null;

    const before = emit.back_of(emitter, position) orelse return null;
    if (emitter.tokens[before].kind != .comment) return null;

    const tier = binding(emitter, position) orelse return null;
    const held = split.coded_at(emitter, before) orelse return null;

    assert(held < position);

    if (emit.operand_at(emitter, held)) return tier;
    if (emitter.tokens[held].kind == .block_end) return tier;
    return null;
}

fn bounded_led(emitter: *Emitter, wanted: u32, tier: u32) u32 {
    assert(emitter.bound <= core.binding_depth_max);
    assert(tier < emitter.policy.binding_words.len);

    if (emitter.bound == 0) return wanted;
    if (emitter.bound_depth != emitter.depth) return wanted;

    while (emitter.bound > 0) {
        const tiered = emitter.bindings[emitter.bound - 1];
        if (tiered.tier > tier) return tiered.level;

        emitter.bound -= 1;
    }

    return emitter.levels;
}

fn bounded_unbound(emitter: *Emitter, wanted: u32, leading: ?u32) u32 {
    assert(emitter.bound <= core.binding_depth_max);

    if (leading) |found| assert(found < emitter.count);
    assert(wanted < std.math.maxInt(u32));

    const heads = if (leading) |found|
        word_is(emitter, found, emitter.policy.binding_bases)
    else
        false;

    if (heads) {
        bounded_reset(emitter, @intCast(emitter.policy.binding_words.len), wanted);

        return wanted;
    }

    if (leading) |found| {
        if (emit.is_dot(emitter, found)) return wanted;
    }

    emitter.bound = 0;

    return wanted;
}

fn bounded_reset(emitter: *Emitter, tier: u32, wanted: u32) void {
    assert(tier <= emitter.policy.binding_words.len);
    assert(emitter.depth <= brace.nest_depth_max);
    assert(wanted < std.math.maxInt(u32));

    emitter.bindings[0] = .{ .tier = tier, .level = wanted };
    emitter.bound = 1;
    emitter.bound_base = wanted;
    emitter.bound_depth = emitter.depth;
}

fn operand_led(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (!emitter.policy.operand_levels) return true;

    const held = coded(emitter) orelse return false;

    assert(held < emitter.count);

    if (emit.operand_at(emitter, held)) return true;
    return emitter.tokens[held].kind == .block_end;
}

fn continued_by(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const run_end = punctuated_run(emitter, position);
    const bytes = emitter.source[emitter.tokens[position].offset..emitter.tokens[run_end].end()];

    assert(run_end >= position);

    if (!word_in(bytes, emitter.policy.continue_words)) return false;

    const ahead = emit.ahead_of(emitter, run_end) orelse return false;
    return emitter.tokens[run_end].end() < emitter.tokens[ahead].offset;
}

fn punctuated_run(emitter: *const Emitter, position: u32) u32 {
    assert(position < emitter.count);

    var scan = position;

    while (scan + 1 < emitter.count) : (scan += 1) {
        const held = emitter.tokens[scan];
        const ahead = emitter.tokens[scan + 1];
        if (held.end() != ahead.offset) break;
        if (ahead.kind != .punctuation) break;
    }

    assert(scan >= position);
    assert(scan < emitter.count);

    return scan;
}

pub fn carries_on(emitter: *const Emitter) bool {
    assert(emitter.line_first <= emitter.count);

    var scan = emitter.line_first;

    while (scan > 0) {
        scan -= 1;

        const token = emitter.tokens[scan];
        if (token.length == 0) continue;
        if (token.kind == .comment) continue;
        if (token.kind == .newline) return false;
        if (walk.is_open(token.kind)) return false;
        return !is_separator(token.kind);
    }

    return false;
}

pub fn clause_level(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    if (!emitter.policy.header_levels) return null;
    if (!emitter.tokens[position].is_punctuation(.colon)) return null;
    if (assembly.asm_framed(emitter)) return null;

    const head = head_word(emitter, position, emitter.policy.header_words) orelse return null;

    assert(head < position);

    return level_at(emitter, head);
}

pub fn branch_level(emitter: *Emitter) ?u32 {
    assert(emitter.branched <= core.branch_depth_max);
    assert(emitter.depth <= brace.nest_depth_max);

    while (emitter.branched > 0) {
        if (emitter.branches[emitter.branched - 1].depth <= emitter.depth) break;

        emitter.branched -= 1;
    }

    while (emitter.branched > 0) {
        const word = emitter.branches[emitter.branched - 1].word;
        if (!word_is(emitter, word, emitter.policy.level_words)) break;

        emitter.branched -= 1;
    }

    if (emitter.branched == 0) return null;
    if (emitter.branches[emitter.branched - 1].depth != emitter.depth) return null;

    emitter.branched -= 1;

    assert(emitter.branched < core.branch_depth_max);

    return emitter.branches[emitter.branched].level;
}

pub fn branch_opened(emitter: *Emitter, opened_level: u32, held: u32) void {
    assert(emitter.branched <= core.branch_depth_max);
    assert(held < emitter.count);
    assert(opened_level < std.math.maxInt(u32));

    if (emitter.branched < core.branch_depth_max) {
        emitter.branches[emitter.branched] = .{
            .level = opened_level,
            .depth = emitter.depth,
            .word = held,
        };

        emitter.branched += 1;
    }
}

pub fn header_level(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.branched <= core.branch_depth_max);

    if (!emitter.policy.header_levels) return null;

    const prior = coded(emitter) orelse return null;

    if (emitter.branched > 0) {
        if (emitter.branches[emitter.branched - 1].word == prior) return null;
    }

    if (word_is(emitter, prior, emitter.policy.level_words)) return emitter.printed;
    if (!heads_a_body(emitter, position, prior)) return null;

    const head = head_word(emitter, position, emitter.policy.header_words) orelse return null;
    const seat = indent_at(emitter, prior) orelse level_at(emitter, head) orelse emitter.printed;
    const returned = seat + assembly.asm_stepped(emitter, head);

    assert(returned < std.math.maxInt(u32));

    return returned;
}

pub fn header_block_level(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    if (!emitter.policy.header_levels) return null;

    const braced = emitter.tokens[position].kind == .block_start;
    const blocked = braced or payload.block_labeled(emitter, position);
    if (!blocked) return null;

    const prior = join.coded_before(emitter, position) orelse return null;
    const closed = emitter.tokens[prior].is_punctuation(.paren_close);
    const prefixed = closed or walk.text_is(emitter.tokens[prior].text(emitter.source), "|");
    if (!prefixed) return null;

    const head = head_word(emitter, position, emitter.policy.header_words) orelse return null;
    return level_at(emitter, head);
}

pub fn indent_at(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.policy.header_levels);

    var target = position;

    for (0..core.line_level_max) |_| {
        const held = at(emitter, target) orelse return null;
        const start = held.start - 1;
        const earliest = indent_at_closed(emitter, start, target) orelse return held.level;

        assert(earliest < start);

        target = earliest;
    }

    return null;
}

fn indent_at_closed(emitter: *const Emitter, start: u32, target: u32) ?u32 {
    assert(start <= target);
    assert(target < emitter.count);

    var earliest: ?u32 = null;
    var scan = start;

    while (scan < target) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const closes = walk.is_close(kind) or kind == .block_end;
        const open = if (closes) emitter.brackets.open_of(scan) else null;
        const operand = emit.operand_ended(emitter, scan);

        if (open) |held| {
            if (held < start) earliest = @min(earliest orelse held, held);
        }

        if (operand) |held| {
            if (held < start) {
                const stringed = emit.roled(emitter, held, brace.role_span);

                if (!stringed) earliest = @min(earliest orelse held, held);
            }
        }
    }

    return earliest;
}

pub fn level_at(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.lined < core.line_level_max);

    const found = at(emitter, position) orelse return null;
    return found.level;
}

pub fn at(emitter: *const Emitter, position: u32) ?core.Line {
    assert(position < emitter.count);
    assert(emitter.lined < core.line_level_max);

    var index = emitter.lined;

    for (0..core.line_level_max) |_| {
        index = if (index == 0) core.line_level_max - 1 else index - 1;

        const held = emitter.lines[index];

        assert(held.start <= emitter.count);

        if (held.start == 0) return null;
        if (held.start - 1 <= position) return held;
    }

    return null;
}

fn heads_a_body(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    if (emitter.policy.header_words.len == 0) return false;
    if (emitter.tokens[position].kind == .block_start) return false;
    if (payload.block_labeled(emitter, position)) return false;

    if (word_is(emitter, prior, emitter.policy.source_words)) {
        if (word_is(emitter, emitter.line_before, emitter.policy.header_words)) return true;
        if (!emitter.policy.header_levels) return false;
        return payload.headed(emitter, prior);
    }

    if (!emitter.tokens[prior].is_punctuation(.paren_close)) return false;
    if (!emitter.closed.kind.eql(.{ .punctuation = .paren_open })) return false;

    if (emitter.closed.open > 0) {
        const word = emitter.closed.open - 1;
        if (word_is(emitter, word, emitter.policy.header_words)) return true;
        if (loop_awaited(emitter, word) != null) return true;
    }

    if (!emitter.policy.header_levels) return false;
    return heads_a_body_while(emitter, emitter.closed.open);
}

pub fn loop_awaited(emitter: *const Emitter, word: u32) ?u32 {
    assert(word < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!walk.text_is(emitter.tokens[word].text(emitter.source), "await")) return null;

    const head = emit.back_of(emitter, word) orelse return null;

    assert(head < word);

    if (!walk.text_is(emitter.tokens[head].text(emitter.source), "for")) return null;
    return head;
}

fn heads_a_body_while(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.policy.header_levels);

    const colon = emit.back_of(emitter, open) orelse return false;
    if (!emitter.tokens[colon].is_punctuation(.colon)) return false;

    const before = emit.back_of(emitter, colon) orelse return false;
    const opened = emitter.brackets.open_of(before) orelse return false;
    const word = emit.back_of(emitter, opened) orelse return false;

    return word_is(emitter, word, while_words);
}

fn nested_already(emitter: *const Emitter, prior: u32) bool {
    assert(prior < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    var depth = emitter.depth;

    while (depth > 0) : (depth -= 1) {
        const held = emitter.nest[depth - 1];
        if (!held.indents) continue;
        if (body.parts(emitter, held.open)) return false;
        if (held.parted) return false;

        const from = emitter.tokens[held.open].end();
        return body.parted_by(emitter, from, emitter.tokens[prior].end()) == 0;
    }

    return false;
}

fn bounds(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.clause_bases) return false;
    if (!emitter.claused) return false;

    const held = coded(emitter) orelse return false;

    assert(held < emitter.count);

    if (word_is(emitter, held, emitter.policy.clause_words)) return true;
    return emitter.tokens[held].is_punctuation(.comma);
}

fn clause_holds(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.claused_body) return false;
    if (emitter.depth > emitter.claused_depth) return true;

    if (emitter.policy.clause_ends) {
        if (coded(emitter)) |held| {
            if (emitter.tokens[held].is_punctuation(.semicolon)) return false;
        }
    }

    if (emitter.policy.chain_simples) {
        if (emit.case_held(emitter, position)) return true;
    }

    const kind = emitter.tokens[position].kind;
    if (walk.is_close(kind)) return false;
    if (kind == .block_start) return false;
    return !kind.eql(.{ .punctuation = .semicolon });
}

pub fn arming(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!word_is(emitter, position, emitter.policy.clause_words)) return false;
    if (keying(emitter)) return false;
    if (claused_member(emitter, position)) return false;
    if (!emitter.policy.chain_simples) return true;
    return own.switch_framed(emitter, position);
}

fn claused_member(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emit.ahead_of(emitter, position)) |held| {
        if (walk.text_is(emitter.tokens[held].text(emitter.source), "?")) return true;
    }

    if (emitter.depth == 0) return false;
    return span.type_framed(emitter, frame(emitter).open);
}

pub fn keying(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);

    const held = frame(emitter);

    if (emitter.depth == 0) assert(held.kind == .block_start);

    if (held.kind != .block_start) return false;
    return held.lists;
}

pub fn clauses(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (opens_a_clause(emitter, position)) return true;
    if (!emitter.claused) return false;
    return clause_holds(emitter, position);
}

pub fn opens_a_clause(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (arming(emitter, position)) return true;
    if (emitter.claused) return false;

    const held = coded(emitter) orelse return false;

    assert(held < emitter.count);

    if (!word_is(emitter, held, emitter.policy.clause_words)) return false;
    return !default_exported(emitter, held);
}

fn default_exported(emitter: *const Emitter, word: u32) bool {
    assert(word < emitter.count);

    if (!walk.text_is(emitter.tokens[word].text(emitter.source), "default")) return false;

    const before = emit.back_of(emitter, word) orelse return false;
    return walk.text_is(emitter.tokens[before].text(emitter.source), "export");
}

pub fn chains(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (!emitter.policy.brace_continues) return false;
    if (!link.chain_linked(emitter, position)) return false;

    if (emitter.policy.header_levels) {
        if (emit.roled(emitter, position, brace.role_start)) return false;
    }

    const prior = coded(emitter) orelse return false;
    const name = coding(emitter, position) orelse return false;

    assert(name > position);

    switch (emitter.tokens[name].kind) {
        .identifier, .keyword, .number => {},
        else => return false,
    }

    const held = emitter.tokens[prior].kind;
    if (walk.is_open(held)) return false;
    return !is_separator(held);
}

fn spanned_run(emitter: *const Emitter, position: u32) ?bool {
    assert(position < emitter.count);

    if (split.valued_source(emitter, position)) return true;
    if (!emit.roled(emitter, position, brace.role_span)) return null;

    const above = coded(emitter);

    if (above) |held| {
        assert(held < emitter.count);

        if (emit.roled(emitter, held, brace.role_span)) {
            return emitter.continued or emitter.policy.header_levels;
        }
    }

    if (emitter.policy.header_levels) {
        if (above) |held| {
            const bytes = emitter.tokens[held].text(emitter.source);
            if (walk.text_is(bytes, "=>")) return false;
            if (walk.text_is(bytes, "return")) return false;
        }
    }

    if (emit.is_dot(emitter, emitter.line_before)) return false;
    return null;
}

pub fn continues(emitter: *const Emitter, position: u32, deep: bool) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emit.mark_of(emitter, position) & brace.mark_flush != 0) return false;
    if (spanned_run(emitter, position)) |held| return held;
    if (!emitter.policy.brace_continues) return false;
    if (arming(emitter, position)) return false;
    if (join.arm_closed(emitter)) return false;

    const kind = emitter.tokens[position].kind;

    if (emitter.policy.brace_dedents) {
        if (kind == .block_start) return false;
        if (unsafe_armed(emitter, position)) return false;
    }

    if (emitter.depth == 0) {
        if (word_is(emitter, position, emitter.policy.follow_heads)) return true;
    }

    const bodied = emitter.depth > emitter.claused_depth and frame(emitter).kind == .block_start;

    if (emitter.claused) {
        if (!bodied) {
            if (emitter.depth != emitter.claused_depth) return false;
            return clause_holds(emitter, position);
        }
    }

    const prior = coded(emitter) orelse return false;

    if (walk.is_close(kind)) return false;
    if (brace_carries(emitter, position, prior)) |decided| return decided;
    return continues_after(emitter, position, prior, deep);
}

fn continues_after(emitter: *const Emitter, position: u32, prior: u32, deep: bool) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    const held = emitter.tokens[prior].kind;
    const separated = is_separator(held);

    if (word_is(emitter, position, emitter.policy.level_words)) return false;
    if (alternates(emitter, position)) return false;

    if (unite.class_decorated(emitter, position, prior)) {
        if (!walk.text_is(emitter.tokens[prior].text(emitter.source), "=")) return false;
    }

    if (emitter.policy.attribute_ends) {
        if (attributed(emitter, prior)) return false;
    }

    if (chains(emitter, position)) return true;
    if (led_tier(emitter, position) != null) return true;

    if (continued_by(emitter, position)) {
        if (operand_led(emitter, position)) return true;
    }

    if (heads_a_body(emitter, position, prior)) return true;
    if (continues_parted(emitter, position, prior)) return true;

    if (deep) {
        if (nested_already(emitter, prior)) return false;
    }

    if (emitter.policy.index_continues) {
        if (continues_indexed(emitter, position, prior)) return true;
    }

    if (walk.is_open(held)) return false;
    if (walk.is_close(held)) return false;
    if (held == .comment) return false;

    if (held.eql(.{ .punctuation = .comma })) {
        if (generic_open(emitter, position)) return true;
        if (!emitter.policy.comma_continues) return false;
        return statement_level(emitter);
    }

    if (separated) return false;
    if (held.eql(.{ .punctuation = .colon })) return emitter.policy.colon_continues;
    if (word_is(emitter, prior, emitter.policy.postfix_words)) return false;
    if (word_is(emitter, prior, emitter.policy.end_words)) return false;
    return !emit.operand_at(emitter, prior);
}

fn continues_parted(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    const from = emitter.tokens[prior].end();
    if (body.parted_by(emitter, from, emitter.tokens[position].offset) != 0) return false;
    if (clause.parted(emitter, position, prior)) return true;
    return bind.declare_broken(emitter, position, prior);
}

fn continues_indexed(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    if (!emitter.tokens[position].is_punctuation(.bracket_open)) return false;

    const held = emitter.tokens[prior];
    const closed = held.is_punctuation(.bracket_close) or held.is_punctuation(.paren_close);
    const named = held.kind == .identifier or closed;
    const questioned = walk.text_is(held.text(emitter.source), "?");

    if (!named) {
        if (!questioned) return false;
    }

    return !attributed(emitter, prior);
}

pub fn commented_level(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (own.comment_assigned(emitter, position)) |held| return held;
    if (!emitter.policy.comment_levels) return null;

    const prior = emit.back_of(emitter, position) orelse return null;
    const token = emitter.tokens[prior];
    if (token.kind != .comment) return null;
    if (std.mem.startsWith(u8, token.text(emitter.source), "/*")) return null;

    const above = split.coded_at(emitter, prior) orelse return null;
    const arrowed = walk.text_is(emitter.tokens[above].text(emitter.source), "=>");
    if (arrowed) return level_at(emitter, above);

    if (fielded(emitter, above)) |named| {
        if (!split.broke(emitter, above, prior)) return level_at(emitter, named);
    }

    _ = binding(emitter, position) orelse return null;

    if (!levels.holds_a_condition(emitter, frame(emitter).open)) return null;
    if (split.broke(emitter, above, prior)) return null;
    return level_at(emitter, frame(emitter).open);
}

fn fielded(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    if (!emitter.tokens[position].is_punctuation(.assign)) return null;

    const name = emit.back_of(emitter, position) orelse return null;
    const dot = emit.back_of(emitter, name) orelse return null;

    assert(dot < name);

    if (!fields(emitter, dot)) return null;
    return dot;
}

pub fn barred(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    if (!emitter.policy.bar_levels) return null;

    const opened = barred_scan(emitter, position) orelse return null;

    assert(opened < position);

    if (!payload.bar(emitter, opened)) return null;

    if (walk.text_is(emitter.tokens[position].text(emitter.source), "|")) {
        return emitter.levels;
    }

    assert(emitter.levels + 1 < std.math.maxInt(u32));

    return emitter.levels + 1;
}

fn barred_scan(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    var bars: u32 = 0;
    var depth: u32 = 0;
    var opened = position;
    var scan = position;

    for (0..core.angle_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse break;
        const token = emitter.tokens[held];
        const semicolon = depth == 0 and token.is_punctuation(.semicolon);
        const stops = token.kind == .block_end or semicolon;
        const opens = walk.is_open(token.kind) or token.kind == .block_start;
        const barring = depth == 0 and walk.text_is(token.text(emitter.source), "|");

        if (stops) break;

        if (walk.is_close(token.kind)) {
            depth += 1;
        } else if (opens) {
            if (depth == 0) break;

            depth -= 1;
        } else if (barring) {
            bars += 1;
            opened = held;
        } else {}

        scan = held;
    }

    if (bars != 1) return null;

    assert(opened < position);

    return opened;
}

fn generic_open(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.generic_levels) return false;
    if (list.closes_angle(emitter.tokens[position].text(emitter.source))) return false;

    var angles: u32 = 0;
    var depth: u32 = 0;
    var scan = position;

    for (0..core.type_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;
        const kind = emitter.tokens[held].kind;
        const text = emitter.tokens[held].text(emitter.source);

        assert(held < scan);

        scan = held;

        if (walk.is_close(kind)) {
            depth += 1;

            continue;
        }

        if (walk.is_open(kind)) {
            if (depth == 0) return false;

            depth -= 1;

            continue;
        }

        if (depth > 0) continue;

        if (list.closes_angle(text)) {
            angles += @intCast(text.len);

            continue;
        }

        if (!angle_opening(text)) continue;

        const run: u32 = @intCast(text.len);
        if (run > angles) return angled_apart(emitter, held);

        angles -= run;
    }

    return false;
}

fn angle_opening(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    if (text.len == 0) return false;

    for (text) |byte| {
        if (byte != '<') return false;
    }

    assert(text[0] == '<');

    return true;
}

pub fn generic_level(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    const angles, const angle = generic_angles(emitter, position) orelse return null;
    const closes = closing_angles(emitter, position);
    const bound: u32 = @intFromBool(bounded_type(emitter, position));
    const shift = bound_shift(emitter, position);
    const base = generic_hugged(emitter, angle) orelse emitter.levels;

    assert(angles > 0);
    assert(closes <= emitter.count);

    return base + bound + shift + (angles -| closes);
}

fn generic_hugged(emitter: *const Emitter, angle: u32) ?u32 {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(angle < emitter.count);

    if (emitter.depth == 0) return null;

    const inner = emitter.nest[emitter.depth - 1];
    if (inner.kind == .block_start) return null;
    if (inner.open >= angle) return null;

    const opened = at(emitter, inner.open) orelse return null;
    const angled = at(emitter, angle) orelse return null;
    if (opened.start != angled.start) return null;
    return angled.level;
}

pub fn bound_level(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    if (!emitter.policy.clause_bases) return null;

    const found = bounds_of(emitter, position) orelse return null;
    const base = emitter.levels + if (found.claused) 1 else found.depth;

    if (found.start == position) {
        if (found.claused) return base;
        return null;
    }

    const colon = found.colon orelse return null;
    if (colon >= position) return null;
    if (emitter.brackets.angles_at(position) != found.depth) return null;
    if (!walk.text_is(emitter.tokens[position].text(emitter.source), "+")) return null;
    assert(base + 1 < std.math.maxInt(u32));

    return base + 1;
}

fn bound_shift(emitter: *const Emitter, position: u32) u32 {
    assert(position < emitter.count);

    if (!emitter.policy.clause_bases) return 0;

    const found = bounds_of(emitter, position) orelse return 0;
    const colon = found.colon orelse return 0;
    if (colon >= position) return 0;
    if (emitter.brackets.angles_at(position) <= found.depth) return 0;

    const claused: u32 = @intFromBool(found.claused);
    const returned = claused + @intFromBool(bounds_forced(emitter, found, colon));

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn bounds_of(emitter: *const Emitter, position: u32) ?Bounds {
    assert(position < emitter.count);

    const kind = emitter.tokens[position].kind;
    if (kind == .block_start) return null;
    if (kind == .block_end) return null;
    if (emitter.tokens[position].is_punctuation(.semicolon)) return null;

    const head = bounds_head(emitter, position) orelse return null;
    const claused = word_is(emitter, head, emitter.policy.clause_words);
    const depth = emitter.brackets.angles_at(head) + @intFromBool(!claused);

    var found: Bounds = .{
        .claused = claused,
        .colon = null,
        .depth = depth,
        .start = emit.ahead_of(emitter, head) orelse return null,
    };

    var scan = found.start;

    for (0..core.angle_scan_max) |_| {
        if (scan >= position) return found;

        const token = emitter.tokens[scan];

        if (walk.is_open(token.kind)) {
            scan = (join.closing_of(emitter, scan) orelse return null) + 1;

            continue;
        }

        if (emitter.brackets.angles_at(scan) == depth) {
            if (token.is_punctuation(.comma)) {
                found.start = emit.ahead_of(emitter, scan) orelse return null;
                found.colon = null;
            } else if (found.colon == null) {
                if (walk.text_is(token.text(emitter.source), ":")) found.colon = scan;
            } else {}
        }

        scan += 1;
    }

    return null;
}

fn bounds_head(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    var closes: u32 = 0;
    var scan = position;

    for (0..core.angle_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return null;
        const token = emitter.tokens[held];
        const text = token.text(emitter.source);

        assert(held < scan);

        if (token.kind == .block_start) return null;
        if (token.kind == .block_end) return null;
        if (token.is_punctuation(.semicolon)) return null;

        if (walk.is_close(token.kind)) {
            scan = emitter.brackets.open_of(held) orelse return null;

            continue;
        }

        if (walk.is_open(token.kind)) return null;
        if (word_is(emitter, held, emitter.policy.clause_words)) return held;

        scan = held;

        if (list.closes_angle(text)) {
            closes += @intCast(text.len);

            continue;
        }

        if (!angle_opening(text)) continue;

        const run: u32 = @intCast(text.len);

        if (run <= closes) {
            closes -= run;

            continue;
        }

        closes = 0;

        if (bound_params(emitter, held)) return held;
    }

    return null;
}

fn bound_params(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (!walk.text_is(emitter.tokens[open].text(emitter.source), "<")) return false;

    const name = emit.back_of(emitter, open) orelse return false;
    if (walk.text_is(emitter.tokens[name].text(emitter.source), "impl")) return true;
    if (emitter.tokens[name].kind != .identifier) return false;

    const word = emit.back_of(emitter, name) orelse return false;
    return word_is(emitter, word, bound_heads);
}

fn bounds_forced(emitter: *const Emitter, found: Bounds, colon: u32) bool {
    assert(colon < emitter.count);
    assert(found.colon.? == colon);

    var commas: u32 = 0;
    var paths: u32 = 0;
    var scan = colon + 1;

    for (0..core.define_scan_max) |_| {
        if (scan >= emitter.count) break;

        const token = emitter.tokens[scan];
        const text = token.text(emitter.source);
        const depth = emitter.brackets.angles_at(scan);

        if (token.kind == .block_start) break;
        if (token.kind == .block_end) break;

        if (walk.is_open(token.kind)) {
            scan = (join.closing_of(emitter, scan) orelse break) + 1;

            continue;
        }

        if (walk.is_close(token.kind)) break;
        if (token.is_punctuation(.semicolon)) break;
        if (depth < found.depth) break;

        if (depth == found.depth) {
            if (token.is_punctuation(.comma)) break;
            if (word_in(text, bound_stops)) break;
            if (list.closes_angle(text)) break;
            if (walk.text_is(text, "+")) return true;

            if (walk.text_is(text, "::")) paths += 1;
        } else if (depth == found.depth + 1) {
            if (token.is_punctuation(.comma)) {
                const next = emit.ahead_of(emitter, scan) orelse break;
                const trailing = list.closes_angle(emitter.tokens[next].text(emitter.source));

                commas += @intFromBool(!trailing);
            }
        } else {}

        scan += 1;
    }

    return paths > 0 or commas > 0;
}

fn bounded_type(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var colon = false;
    var depth: u32 = 0;
    var scan = position;

    for (0..core.type_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;
        const kind = emitter.tokens[held].kind;
        const text = emitter.tokens[held].text(emitter.source);

        assert(held < scan);

        scan = held;

        if (walk.is_close(kind)) {
            depth += 1;

            continue;
        }

        if (walk.is_open(kind)) {
            if (depth == 0) return false;

            depth -= 1;

            continue;
        }

        if (depth > 0) continue;
        if (kind.eql(.{ .punctuation = .semicolon })) return false;
        if (walk.text_is(text, "type")) return colon;
        if (!walk.text_is(text, ":")) continue;
        if (emit.doubled(emitter, held)) continue;
        if (emit.pathed(emitter, held)) continue;

        colon = true;
    }

    return false;
}

fn closing_angles(emitter: *const Emitter, position: u32) u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const text = emitter.tokens[position].text(emitter.source);
    if (!list.closes_angle(text)) return 0;
    assert(text.len <= std.math.maxInt(u32));

    return @intCast(text.len);
}

fn generic_angles(emitter: *const Emitter, position: u32) ?struct { u32, u32 } {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.generic_nests) return null;

    var angles: u32 = 0;
    var depth: u32 = 0;
    var open: u32 = 0;
    var angle = position;
    var scan = position;
    var stopped = false;

    for (0..core.angle_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse {
            stopped = true;

            break;
        };

        const kind = emitter.tokens[held].kind;
        const stops = kind == .block_end or kind.eql(.{ .punctuation = .semicolon });

        assert(held < scan);

        if (depth == 0) {
            if (stops) {
                stopped = true;

                break;
            }
        }

        scan = held;

        if (walk.is_close(kind)) {
            depth += 1;

            continue;
        }

        if (walk.is_open(kind)) {
            if (depth == 0) {
                stopped = true;

                break;
            }

            depth -= 1;

            continue;
        }

        if (depth > 0) continue;

        const before = open;

        if (!generic_angles_run(emitter, held, &angles, &open)) return null;

        if (open > before) angle = held;
    }

    if (!stopped) return null;
    if (open == 0) return null;
    return .{ open, angle };
}

fn generic_angles_run(emitter: *const Emitter, held: u32, angles: *u32, open: *u32) bool {
    assert(held < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const text = emitter.tokens[held].text(emitter.source);

    if (list.closes_angle(text)) {
        angles.* += @intCast(text.len);

        return true;
    }

    if (!angle_opening(text)) return true;

    const run: u32 = @intCast(text.len);

    if (run <= angles.*) {
        angles.* -= run;

        return true;
    }

    if (open.* == 0) {
        if (!angled_apart(emitter, held)) return false;
    }

    open.* += run - angles.*;
    angles.* = 0;

    return true;
}

fn angled_apart(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.ahead_of(emitter, open) orelse return false;

    assert(held > open);

    return body.parts_at(emitter, open, held);
}

pub fn ranged(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    var scan = open + 1;

    while (scan < close) {
        const held = emitter.tokens[scan];

        scan += 1;

        if (std.mem.startsWith(u8, held.text(emitter.source), "..")) return true;
        if (!emit.is_dot(emitter, scan - 1)) continue;
        if (scan >= close) continue;
        if (!emit.is_dot(emitter, scan)) continue;
        if (held.end() == emitter.tokens[scan].offset) return true;
    }

    return false;
}

fn alternates(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.policy.pattern_words.len == 0) return false;
    if (!walk.text_is(emitter.tokens[position].text(emitter.source), "|")) return false;

    var level_index = emitter.depth;

    while (level_index > 0) {
        level_index -= 1;

        const held = emitter.nest[level_index];

        assert(held.open < emitter.count);

        if (held.kind == .block_start) return patterned(emitter, held.open);
        if (!emitter.policy.pattern_frames) return false;
    }

    return false;
}

fn patterned(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    return worded_head(emitter, open, emitter.policy.pattern_words);
}

fn brace_carries(emitter: *const Emitter, position: u32, prior: u32) ?bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    const opens = emitter.tokens[position].kind == .block_start;

    const blocks = if (emitter.structured)
        emit.bodied(emitter, position)
    else
        body.bodied_brace(emitter, position);

    const carried = emitter.policy.header_braces and opens and blocks;

    if (carried) {
        if (!brace_fallback(emitter, prior)) return false;
    }

    if (!emitter.policy.arm_guards) return null;

    if (walk.text_is(emitter.tokens[prior].text(emitter.source), "=>")) {
        if (opens) return false;
        if (frame(emitter).kind != .block_start) return false;
    }

    if (guards_an_arm(emitter, position)) return true;
    return null;
}

fn brace_fallback(emitter: *const Emitter, prior: u32) bool {
    assert(prior < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.header_levels) return false;

    var held = prior;

    if (walk.text_is(emitter.tokens[prior].text(emitter.source), "|")) {
        var scan = prior;

        for (0..fallback_scan_max) |_| {
            scan = emit.back_of(emitter, scan) orelse return false;

            if (walk.text_is(emitter.tokens[scan].text(emitter.source), "|")) break;
        } else return false;

        held = emit.back_of(emitter, scan) orelse return false;
    }

    return word_is(emitter, held, fallback_words);
}

fn guards_an_arm(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!walk.text_is(emitter.tokens[position].text(emitter.source), "if")) return false;

    const held = frame(emitter);
    if (held.kind != .block_start) return false;
    if (emitter.policy.pattern_words.len == 0) return false;
    if (!patterned(emitter, held.open)) return false;

    var depth: u32 = 0;
    var scan = position + 1;

    while (scan < held.close) {
        const token = emitter.tokens[scan];

        scan += 1;

        if (walk.is_open(token.kind)) {
            depth += 1;

            continue;
        }

        if (walk.is_close(token.kind)) {
            depth -|= 1;

            continue;
        }

        if (depth > 0) continue;
        if (walk.text_is(token.text(emitter.source), "=>")) return true;
        if (token.is_punctuation(.comma)) return false;
    }

    return false;
}

pub fn worded_head(emitter: *const Emitter, open: u32, words: []const []const u8) bool {
    assert(open < emitter.count);
    assert(words.len <= std.math.maxInt(u32));

    const head = head_word(emitter, open, words);

    if (head) |held| assert(held < open);

    return head != null;
}

pub fn head_word(emitter: *const Emitter, open: u32, words: []const []const u8) ?u32 {
    assert(open < emitter.count);
    assert(words.len <= std.math.maxInt(u32));

    var budget = core.type_scan_max;
    var depth: u32 = 0;
    var scan = open;

    while (budget > 0) {
        budget -= 1;

        const held = emit.back_of(emitter, scan) orelse return null;
        const kind = emitter.tokens[held].kind;
        const closes = walk.is_close(kind) or kind == .block_end;
        const opens = walk.is_open(kind) or kind == .block_start;

        assert(held < scan);

        if (closes) {
            const blocked = emitter.policy.head_blocks and depth == 0 and kind == .block_end;

            if (blocked) {
                if (!wide.joins_a_value(emitter, held)) return null;
            }

            if (span.union_skipped(emitter, held)) |inner| {
                const steps = emitter.brackets.stepped(inner, held);
                if (steps > budget) return null;

                budget -= steps;
                scan = inner;

                continue;
            }

            depth += 1;
        } else if (opens) {
            if (depth == 0) return null;

            depth -= 1;
        } else if (depth == 0) {
            if (word_is(emitter, held, words)) {
                if (list.member_worded(emitter, held)) return null;
                return held;
            }

            if (emitter.tokens[held].is_punctuation(.semicolon)) return null;
            if (word_is(emitter, held, emitter.policy.head_stops)) return null;
        } else {}

        scan = held;
    }

    return null;
}

fn signature_end(emitter: *const Emitter, close: u32) ?u32 {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var depth: u32 = 0;
    var scan = close;

    for (0..core.define_scan_max) |_| {
        const held = emit.ahead_of(emitter, scan) orelse return null;
        const kind = emitter.tokens[held].kind;

        const stops = kind == .block_start or kind.eql(.{ .punctuation = .semicolon }) or
            word_is(emitter, held, emitter.policy.clause_words);

        assert(held > scan);

        scan = held;

        if (depth == 0) {
            if (stops) return held;
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

pub fn define_settled(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const end = signature_end(emitter, close) orelse return false;
    var depth: u32 = 1;
    var scan = open;

    assert(end > close);

    for (0..core.define_scan_max) |_| {
        const ahead = emit.ahead_of(emitter, scan) orelse return false;
        const comma = emitter.tokens[scan].is_punctuation(.comma);
        const bordered = scan == open or ahead == close or comma;
        const edged = depth == 1 and bordered;

        const claused = ahead >= end and emitter.tokens[scan].kind != .comment and
            word_is(emitter, ahead, emitter.policy.clause_words);

        if (!edged) {
            if (!claused) {
                if (body.parts_at(emitter, scan, ahead)) return false;
            }
        }

        if (ahead >= end) return true;

        const kind = emitter.tokens[ahead].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else {}

        scan = ahead;
    }

    return false;
}

pub fn define_parted(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (!emitter.policy.define_widths) return false;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    var scan = open;

    for (0..core.define_head_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;
        const kind = emitter.tokens[held].kind;
        const bracketed = walk.is_open(kind) or walk.is_close(kind);

        const stops = bracketed or kind == .block_start or kind == .block_end or
            emitter.tokens[held].is_punctuation(.semicolon);

        assert(held < scan);

        if (stops) return false;
        if (word_is(emitter, held, emitter.policy.define_words)) return scan != open;

        scan = held;
    }

    return false;
}

fn unsafe_armed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!walk.text_is(emitter.tokens[position].text(emitter.source), "unsafe")) return false;

    const ahead = emit.ahead_of(emitter, position) orelse return false;
    if (emitter.tokens[ahead].kind != .block_start) return false;

    const held = join.coded_before(emitter, position) orelse return false;

    assert(held < position);

    return walk.text_is(emitter.tokens[held].text(emitter.source), "=>");
}

pub fn coded(emitter: *const Emitter) ?u32 {
    var held = emitter.previous orelse return null;
    var steps: u32 = 0;

    assert(held < emitter.count);

    while (emitter.tokens[held].kind == .comment) : (steps += 1) {
        assert(steps < emitter.count);

        held = emit.back_of(emitter, held) orelse return null;
    }

    assert(emitter.tokens[held].kind != .comment);

    return held;
}

pub fn coding(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    var held = emit.ahead_of(emitter, position) orelse return null;
    var steps: u32 = 0;

    while (emitter.tokens[held].kind == .comment) : (steps += 1) {
        assert(steps < emitter.count);

        held = emit.ahead_of(emitter, held) orelse return null;
    }

    assert(held > position);

    return held;
}

pub fn statement_level(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return true;

    const held = emitter.nest[emitter.depth - 1];

    assert(held.open < emitter.count);

    if (held.kind != .block_start) return false;
    if (emit.bodied(emitter, held.open)) return true;
    if (bind.signature_bodied(emitter, held.open)) return true;
    if (emitter.structured) return false;

    const prior = emit.back_of(emitter, held.open) orelse return true;
    const kind = emitter.tokens[prior].kind;
    if (kind.eql(.{ .punctuation = .paren_close })) return true;
    if (kind == .block_end) return true;
    if (word_is(emitter, prior, emitter.policy.body_words)) return true;
    if (emit.mark_of(emitter, prior) & brace.mark_label != 0) return true;
    return bind.case_block(emitter, prior);
}

pub fn opens_broken(emitter: *Emitter) error{Overflow}!void {
    assert(emitter.broken_low <= emitter.broken);
    assert(emitter.broken < std.math.maxInt(u32));

    if (emitter.broken < core.broken_serial_max) {
        emitter.broken_serials[emitter.broken] = emitter.document.group_serial();
    }

    emitter.broken += 1;

    try emitter.document.push(.indent_broken);
}

pub fn closes_broken(emitter: *Emitter) error{Overflow}!void {
    emitter.broken -|= 1;
    emitter.broken_low = @min(emitter.broken_low, emitter.broken);

    assert(emitter.broken_low <= emitter.broken);

    try emitter.document.push(.dedent_broken);
}

pub fn rings(emitter: *Emitter, position: u32, stepped: u32) void {
    assert(position < emitter.count);
    assert(stepped < std.math.maxInt(u32));

    emitter.broken_line = emitter.broken;
    emitter.broken_low = emitter.broken;
    emitter.broken_led = broken_forced(emitter);

    const led = shadow_led(emitter, stepped);

    emitter.leds[emitter.lined] = led orelse
        emitter.broken_led -| link.hugs_open(emitter, position);

    emitter.lines[emitter.lined] = .{ .start = position + 1, .level = stepped };
    emitter.lined = (emitter.lined + 1) % core.line_level_max;

    assert(emitter.lined < core.line_level_max);
}

fn shadow_led(emitter: *Emitter, stepped: u32) ?u32 {
    assert(stepped < std.math.maxInt(u32));

    const elements = emitter.document.elements_slice();
    const element_count: u32 = @intCast(elements.len);
    const floor = element_count -| core.shadow_back_max;
    const hard = shadow_hard(elements, floor) orelse return null;

    assert(hard < element_count);

    var stop = element_count;

    for (hard + 1..element_count) |index| {
        if (!print.steps_blind(elements[index])) {
            stop = @intCast(index);

            break;
        }
    }

    const arena = emitter.arena.const_slice();

    emitter.shadow.advance(
        emitter.document,
        emitter.source,
        arena,
        emitter.options,
        stop,
    ) catch return null;

    const from = @min(emitter.shadow.index(), element_count);
    var indent_level: i64 = emitter.shadow.indent();

    for (emitter.document.elements_slice()[from..element_count]) |element| {
        switch (element) {
            .indent => indent_level += 1,
            .dedent => indent_level -= 1,
            else => {},
        }
    }

    const led = indent_level - stepped;

    assert(from <= element_count);

    return std.math.cast(u32, @max(led, 0));
}

fn shadow_hard(elements: []const ir.Element, floor: u32) ?u32 {
    assert(floor <= elements.len);
    assert(elements.len <= std.math.maxInt(u32));

    var index: u32 = @intCast(elements.len);

    while (index > floor) {
        index -= 1;

        if (elements[index] == .hard_line) {
            assert(index < std.math.maxInt(u32));

            return index;
        }
    }

    return null;
}

fn broken_forced(emitter: *const Emitter) u32 {
    assert(emitter.broken_low <= emitter.broken);

    const held = @min(emitter.broken, core.broken_serial_max);
    var forced: u32 = 0;

    for (emitter.broken_serials[0..held]) |serial| {
        const found = serial orelse continue;

        if (emitter.document.group_open(found)) forced += 1;
    }

    assert(forced <= held);

    return forced;
}

pub fn level(emitter: *Emitter, wanted: u32) error{Overflow}!void {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.indent < std.math.maxInt(u32));
    assert(wanted < std.math.maxInt(u32));

    while (emitter.indent > wanted) {
        try emitter.document.push(.dedent);

        emitter.indent -= 1;
    }

    while (emitter.indent < wanted) {
        try emitter.document.push(.indent);

        emitter.indent += 1;
    }

    assert(emitter.indent == wanted);
}

fn assign_closed(emitter: *Emitter) error{Overflow}!void {
    assert(emitter.assigns <= core.assign_depth_max);
    assert(emitter.owed <= core.assign_depth_max);

    const dedenting = if (emitter.owed > 0)
        emitter.depth <= emitter.dedents[emitter.owed - 1].depth
    else
        false;

    if (emitter.assigns > 0) {
        if (tern.ternary_severs(emitter, dedenting)) try emitter.document.push(.broken);
    }

    while (emitter.assigns > 0) {
        emitter.assigns -= 1;

        const serial = emitter.assign_groups[emitter.assigns].?;
        const inner = emitter.document.groups_inside(serial);
        const equals = emitter.assigned[emitter.assigns].equals;
        const angled = inner == 1 and dedent_angled(emitter, equals);
        const deferred = inner > 1 or angled;

        if (deferred) {
            try emitter.document.defer_close(serial);
        } else {
            try emitter.document.push(.group_close);
        }
    }

    const held = emitter.owed;

    while (emitter.owed > 0) {
        const dedent = emitter.dedents[emitter.owed - 1];
        if (emitter.depth > dedent.depth) break;
        if (dedent_wrapped(emitter, dedent.equals, dedent.depth)) break;
        if (dedent_angled(emitter, dedent.equals)) break;

        emitter.owed -= 1;

        try closes_broken(emitter);
    }

    emitter.owing = held;
    emitter.owns = held - emitter.owed;
}

fn dedent_wrapped(emitter: *const Emitter, equals: u32, depth: u32) bool {
    assert(equals < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    for (emitter.wrapped[0..emitter.wraps_owed]) |held| {
        if (held.depth != depth) continue;
        if (held.wrap != .bodied) continue;
        if (held.start > equals) return true;
    }

    return false;
}

fn dedent_angled(emitter: *const Emitter, equals: u32) bool {
    assert(equals < emitter.count);
    assert(emitter.angled <= core.angle_depth_max);

    if (emitter.angled == 0) return false;

    const angle = emitter.angles[emitter.angled - 1];

    assert(angle.depth > 0);

    return emitter.brackets.angles_at(equals) < angle.depth;
}

fn parting_bracket(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (emit.mark_of(emitter, open) & brace.mark_expanded != 0) return true;
    if (list.mapped_expanded(emitter, open)) return true;

    if (span.spread_source(emitter, open, close)) {
        if (!clause.seated(emitter, open)) return true;
    }

    if (span.spread_forced(emitter, open, close)) return true;
    if (wide.block(emitter, open)) return true;
    if (bind.pattern_wide(emitter, open, close)) return true;
    if (list.pattern_broken(emitter, open, close)) return true;
    if (list.return_type_wide(emitter, open)) return true;
    return split.body_clauses(emitter, open);
}

pub fn nested(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const token = emitter.tokens[position];

    const kind: Token.Kind = if (walk.substituting(emitter.source, token))
        .block_start
    else
        token.kind;

    if (walk.is_open(kind)) return nested_open(emitter, position, kind);
    if (!walk.is_close(kind)) return;
    if (emitter.depth == 0) return;
    if (!emitter.nest[emitter.depth - 1].kind.eql(walk.opened_by(kind))) return;

    emitter.depth -= 1;
    emitter.closed = emitter.nest[emitter.depth];
    emitter.levels = emitter.closed.held;

    clause_restored(emitter);
}

fn nested_open(emitter: *Emitter, position: u32, kind: Token.Kind) error{Overflow}!void {
    assert(walk.is_open(kind));

    if (emitter.depth == brace.nest_depth_max) return error.Overflow;
    assert(position < emitter.count);

    const clause_bound = clause.bounded(emitter, position, kind);
    const closes = join.closing_of(emitter, position);

    emitter.claused_body = emitter.claused_body or clause_bound;

    const parted = if (closes) |held| nested_parted(emitter, position, held) else false;
    const raised = levels.raised(emitter, position, parted);
    const aligned = raised and assembly.asm_sectioned(emitter, position);
    const indents = raised and !aligned;

    emitter.nest[emitter.depth] = nested_frame(emitter, position, kind, closes);
    emitter.nest[emitter.depth].aligned = aligned;
    emitter.nest[emitter.depth].indents = indents;
    emitter.nest[emitter.depth].parted = parted;
    emitter.depth += 1;

    if (tmpl.hole_level(emitter, position)) |held| {
        emitter.levels = held;

        return;
    }

    if (indents) {
        emitter.levels = levels.sibling(emitter, position, kind) orelse
            levels.nested(emitter, position, clause_bound);
    }

    emitter.nest[emitter.depth - 1].level = emitter.levels;

    assert(emitter.depth <= brace.nest_depth_max);
}

fn nested_parted(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position < close);
    assert(close < emitter.count);

    if (!parting_bracket(emitter, position, close)) return false;
    return !list.unparted(emitter, position, close);
}

fn nested_frame(
    emitter: *const Emitter,
    position: u32,
    kind: Token.Kind,
    closes: ?u32,
) core.Frame {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);
    if (closes) |held| assert(held < emitter.count);
    assert(walk.is_open(kind));

    const spread = if (closes) |held| list.spreading(emitter, position, held) else null;

    const lists = if (closes) |held|
        emitter.policy.width_lists and sole.listed(emitter, held)
    else
        false;

    const casts = if (emitter.previous) |held|
        word_is(emitter, held, emitter.policy.cast_words)
    else
        false;

    const hugged = if (closes) |held| span.spread_hugging(emitter, position, held) else null;
    const inside_held = kind == .block_start and inside(emitter, position);
    const joined = if (closes) |held| call.joined_args(emitter, position, held) else false;
    const substituted = walk.substituting(emitter.source, emitter.tokens[position]);
    const holed = tmpl.holed(emitter) or (substituted and tmpl.hole_flat(emitter, position));
    const returned = spread == null and list.return_unparted(emitter, position);

    return .{
        .aligned = false,
        .bodied = body.bodied_brace(emitter, position),
        .casts = casts,
        .claused = .{
            .held = emitter.claused,
            .depth = emitter.claused_depth,
            .bodied = emitter.claused_body,
        },
        .close = closes orelse 0,
        .grouped = null,
        .held = emitter.levels,
        .holed = holed,
        .hugged = hugged orelse 0,
        .indents = false,
        .index = indexes(emitter, position),
        .inset = emitter.indent,
        .inside = inside_held,
        .joined = joined,
        .kind = kind,
        .level = emitter.levels,
        .lists = lists,
        .membered = span.typed_open(emitter, position),
        .open = position,
        .parted = false,
        .returned = returned,
        .seated = emitter.printed,
        .sequenced = null,
        .spread = spread,
        .valued = core.Valued.empty,
    };
}

fn clause_restored(emitter: *Emitter) void {
    assert(emitter.depth < brace.nest_depth_max);

    const saved = emitter.closed.claused;

    emitter.claused = saved.held;
    emitter.claused_depth = saved.depth;
    emitter.claused_body = saved.bodied;
}

fn indexes(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (emitter.starting) return false;
    if (emit.empties(emitter, position)) return false;
    if (emit.roled(emitter, position, brace.role_start)) return false;

    const prior = emitter.previous orelse return false;
    const held = emitter.tokens[prior].kind;

    assert(prior < emitter.count);

    if (held.eql(.{ .punctuation = .bracket_close })) return emitter.closed.index;
    if (walk.ends_operand(held)) return true;
    if (unwrap_ended(emitter, prior)) return true;
    return nonnull_ended(emitter, prior);
}

pub fn nonnull_ended(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (!emitter.policy.chain_simples) return false;
    if (position == 0) return false;
    if (!walk.text_is(emitter.tokens[position].text(emitter.source), "!")) return false;

    const before = emitter.tokens[position - 1];

    assert(before.end() <= emitter.tokens[position].end());

    if (before.end() != emitter.tokens[position].offset) return false;
    if (walk.ends_operand(before.kind)) return true;
    return before.kind == .block_end;
}

fn unwrap_ended(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (!emitter.policy.header_levels) return false;
    return word_is(emitter, position, wide.unwrap_marks);
}

pub fn frame(emitter: *const Emitter) core.Frame {
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return core.Frame.empty;

    assert(emitter.nest[emitter.depth - 1].open < emitter.count);

    return emitter.nest[emitter.depth - 1];
}

pub fn group_word(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!word_is(emitter, position, emitter.policy.group_words)) return false;
    if (word_named(emitter, position)) return false;
    if (emit.roled(emitter, position, brace.role_type)) return true;
    return !word_is(emitter, position, type_group_words);
}

pub fn word_named(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = emit.ahead_of(emitter, position) orelse return true;

    while (emitter.tokens[scan].kind == .comment) {
        scan = emit.ahead_of(emitter, scan) orelse return true;
    }

    assert(scan > position);

    if (emitter.tokens[scan].is_punctuation(.paren_open)) {
        return !emit.roled(emitter, scan, brace.role_type);
    }

    return word_is(emitter, scan, group_name_follows);
}

pub fn word_is(emitter: *const Emitter, position: u32, words: []const []const u8) bool {
    assert(position < emitter.count);
    assert(words.len <= std.math.maxInt(u32));

    const bytes = emitter.tokens[position].text(emitter.source);

    assert(bytes.len == emitter.tokens[position].length);

    return word_in(bytes, words);
}

fn word_in(bytes: []const u8, words: []const []const u8) bool {
    assert(bytes.len <= std.math.maxInt(u32));
    assert(words.len <= std.math.maxInt(u32));

    for (words) |word| {
        if (word.len != bytes.len) continue;
        if (walk.text_eql(bytes, word)) return true;
    }

    return false;
}

fn is_separator(kind: Token.Kind) bool {
    if (kind == .comment) return false;

    const result = switch (kind) {
        .punctuation => |punctuation| punctuation == .comma or punctuation == .semicolon,
        else => false,
    };

    if (result) assert(walk.punctuated(kind));
    if (result) assert(!walk.is_open(kind));

    return result;
}

fn inside(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.previous) |held| {
        if (jsx.holed(emitter, held)) {
            if (!emitter.policy.brace_spaces) return false;
            return inline_item(emitter, position);
        }
    }

    if (counted(emitter, position)) |held| return held;

    if (emit.bodied(emitter, position)) {
        if (inline_item(emitter, position)) return true;
    }

    if (hugs_a_word(emitter)) return true;

    if (inline_item(emitter, position)) {
        if (emit.opens_a_block(emitter, position)) return true;

        if (emitter.policy.brace_spaces) {
            const hug_worded = if (emitter.previous) |held|
                word_is(emitter, held, emitter.policy.hug_words)
            else
                false;

            if (!hug_worded) return true;
        }
    }

    if (!emitter.policy.brace_counts) return false;
    return opens_with(emitter, position);
}

fn opens_with(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const ahead = emit.ahead_of(emitter, position) orelse return false;

    assert(ahead > position);

    if (emitter.tokens[ahead].kind == .block_end) return false;

    const from = emitter.tokens[position].end();
    if (body.parted_by(emitter, from, emitter.tokens[ahead].offset) != 0) return false;
    return !hugs_sole(emitter, position);
}

fn hugs_sole(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(walk.is_open(emitter.tokens[position].kind));

    var depth: u32 = 0;
    var elements: u32 = 0;
    var head: ?u32 = null;
    var fresh = true;
    var tail = position;
    var scan = position;

    while (scan < emitter.count) {
        const token = emitter.tokens[scan];

        scan += 1;

        if (token.kind == .newline) continue;
        if (token.length == 0) continue;

        const depth_before = depth;

        if (walk.is_open(token.kind)) depth += 1;

        if (walk.is_close(token.kind)) {
            assert(depth > 0);

            depth -= 1;

            if (depth == 0) break;
        }

        tail = scan - 1;

        if (depth_before != 1) continue;

        if (token.is_punctuation(.comma)) {
            fresh = true;
        } else if (fresh) {
            elements += 1;
            fresh = false;

            if (head == null) head = scan - 1;
        } else {}
    }

    if (elements != 1) return false;
    return hugs_sole_held(emitter, position, head, tail);
}

fn hugs_sole_held(emitter: *const Emitter, position: u32, head: ?u32, tail: u32) bool {
    assert(position < emitter.count);
    assert(tail < emitter.count);
    if (head) |held| assert(held < emitter.count);

    if (emit.ahead_of(emitter, position)) |held| {
        if (opens_a_literal(emitter, held)) return true;
    }

    if (!emitter.policy.sole_hugs) return false;

    const held = head orelse return false;
    if (fields(emitter, held)) return false;
    if (emit.roled(emitter, held, brace.role_span)) return false;
    if (emitter.tokens[tail].kind == .comment) return false;
    return !emitter.tokens[tail].is_punctuation(.comma);
}

fn opens_a_literal(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const kind = emitter.tokens[position].kind;
    if (kind == .block_start) return true;
    if (!emit.is_dot(emitter, position)) return false;

    const ahead = emit.ahead_of(emitter, position) orelse return false;

    assert(ahead > position);

    return emitter.tokens[ahead].kind == .block_start;
}

fn counted(emitter: *const Emitter, position: u32) ?bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.brace_counts) return null;
    if (hugs_a_word(emitter)) return null;
    if (emit.bodied(emitter, position)) return null;

    const prior = emitter.previous orelse return null;
    if (jsx.holed(emitter, prior)) return null;
    if (!inline_item(emitter, position)) return null;

    if (!emit.hugged(emitter, position, prior)) {
        if (!emit.is_dot(emitter, prior)) return null;
    }

    const elements, const head = counted_elements(emitter, position) orelse return null;
    if (elements == 0) return false;

    if (head) |held| {
        if (fields(emitter, held)) return true;
    }

    return elements > 1;
}

fn counted_elements(emitter: *const Emitter, position: u32) ?struct { u32, ?u32 } {
    assert(position < emitter.count);
    assert(walk.is_open(emitter.tokens[position].kind));

    var depth: u32 = 0;
    var elements: u32 = 0;
    var head: ?u32 = null;
    var fresh = true;
    var scan = position;

    while (scan < emitter.count) : (scan += 1) {
        const token = emitter.tokens[scan];
        if (token.kind == .newline) continue;
        if (token.length == 0) continue;

        const depth_before = depth;

        if (walk.is_open(token.kind)) depth += 1;

        if (walk.is_close(token.kind)) {
            assert(depth > 0);

            depth -= 1;

            if (depth == 0) break;
        }

        if (depth_before != 1) continue;
        if (token.is_punctuation(.semicolon)) return null;

        if (token.is_punctuation(.comma)) {
            fresh = true;
        } else if (fresh) {
            elements += 1;
            fresh = false;

            if (head == null) head = scan;
        } else {}
    }

    if (head) |held| assert(held > position);

    return .{ elements, head };
}

fn fields(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (!emit.is_dot(emitter, position)) return false;

    const name = emit.ahead_of(emitter, position) orelse return false;

    assert(name > position);

    if (emitter.tokens[name].kind != .identifier) return false;

    const ahead = emit.ahead_of(emitter, name) orelse return false;
    return walk.text_is(emitter.tokens[ahead].text(emitter.source), "=");
}

fn hugs_a_word(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);

    const held = emitter.previous orelse return false;

    assert(held < emitter.count);

    if (word_is(emitter, held, emitter.policy.brace_words)) return true;
    if (!emitter.tokens[held].is_punctuation(.paren_close)) return false;
    if (emitter.closed.open == 0) return false;
    return word_is(emitter, emitter.closed.open - 1, emitter.policy.brace_words);
}

pub fn inline_item(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const close = join.closing_of(emitter, position) orelse return false;

    assert(close > position);

    if (split.fields_wide(emitter, position)) return false;

    const laid = emitter.policy.inline_layout or !body.parts_at(emitter, position, close) or
        join.branch_inline(emitter, position) or join.literal_joined(emitter, position);

    if (!laid) return false;
    return !body.parting(emitter, position, close);
}

pub fn attributed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[position].is_punctuation(.bracket_close)) return false;

    const open = emit.opened(emitter, position) orelse return false;
    const held = emit.word_before(emitter, open) orelse return false;

    assert(held < open);

    return walk.text_is(emitter.tokens[held].text(emitter.source), "#");
}
