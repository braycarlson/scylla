const std = @import("std");
const assert = std.debug.assert;
const body = @import("body.zig");
const brace = @import("../brace.zig");
const call = @import("call.zig");
const clause = @import("clause.zig");
const comment = @import("comment.zig");
const core = @import("emitter.zig");
const edge = @import("edge.zig");
const emit = @import("emit.zig");
const join = @import("join.zig");
const key = @import("key.zig");
const lead = @import("lead.zig");
const line = @import("line.zig");
const link = @import("link.zig");
const list = @import("list.zig");
const own = @import("own.zig");
const span = @import("span.zig");
const split = @import("split.zig");
const tern = @import("tern.zig");
const tmpl = @import("tmpl.zig");
const unite = @import("unite.zig");
const walk = @import("../walk.zig");
const wide = @import("wide.zig");
const wrap = @import("wrap.zig");
const Emitter = core.Emitter;
const Bound = union(enum) { verdict: bool, chained: u32 };
const Seat = struct { u32, u32, bool };
const argued_braces: [4][]const u8 = .{ "<", ",", "|", "&" };
const binder_lead_max: u32 = 4;
const bound_chain_max: u32 = brace.nest_depth_max + 2;
const branch_align_columns: u32 = 2;
const case_scan_max: u32 = 32;
const case_stops: [3][]const u8 = .{ ";", ":", "?" };
const case_words: [2][]const u8 = .{ "case", "default" };
const cast_halts: [3][]const u8 = .{ "=>", "?", ":" };
const cast_words: [2][]const u8 = .{ "as", "satisfies" };
const iterate_words: [2][]const u8 = .{ "in", "of" };
const jump_values: [2][]const u8 = .{ "return", "throw" };
const lone_literals: [3][]const u8 = .{ "class", "false", "true" };
const pattern_binders: [3][]const u8 = .{ "const", "let", "var" };
const return_type_max: u32 = 64;
const sequence_branch_max: u32 = 4;

const sequence_heads: [11][]const u8 = .{
    "(",
    ",",
    ":",
    ";",
    "=",
    "=>",
    "?",
    "??",
    "&&",
    "[",
    "||",
};

const sequence_keywords: [4][]const u8 = .{ "case", "do", "return", "throw" };
const signature_marks: [8][]const u8 = .{ ".", "|", "&", "<", ">", "?", "[", "]" };

pub fn signature_bodied(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.chain_simples) return false;

    var angles: u32 = 0;
    var scan = open;

    for (0..return_type_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;
        const kind = emitter.tokens[held].kind;
        const text = emitter.tokens[held].text(emitter.source);
        const closed = kind == .block_end or kind.eql(.{ .punctuation = .bracket_close });

        assert(held < scan);

        if (closed) {
            const found = emitter.brackets.open_of(held) orelse return false;

            if (kind == .block_end) {
                if (!signature_braced(emitter, found)) return false;
            }

            scan = found;

            continue;
        }

        if (kind.eql(.{ .punctuation = .colon })) {
            if (scan == open) return false;
            return signature_colon(emitter, held);
        }

        if (!signature_piece(emitter, held)) return false;

        if (list.closes_angle(text)) angles += @intCast(text.len);

        if (walk.text_is(text, "<")) {
            if (angles == 0) return false;

            angles -= 1;
        }

        scan = held;
    }

    return false;
}

fn signature_braced(emitter: *const Emitter, found: u32) bool {
    assert(found < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const before = emit.back_of(emitter, found) orelse return false;
    const token = emitter.tokens[before];

    assert(before < found);

    if (token.is_punctuation(.colon)) return true;
    return word_listed(&argued_braces, token.text(emitter.source));
}

fn signature_colon(emitter: *const Emitter, colon: u32) bool {
    assert(colon < emitter.count);
    assert(emitter.tokens[colon].is_punctuation(.colon));

    var stop: u32 = 0;
    var at = emitter.depth;

    while (at > 0) {
        at -= 1;

        const opened = emitter.nest[at].open;

        if (opened < colon) {
            stop = opened;

            break;
        }
    }

    if (tern.ternary_within(emitter, colon, stop)) return false;

    const found = emit.back_of(emitter, colon) orelse return false;
    return emitter.tokens[found].is_punctuation(.paren_close);
}

fn signature_piece(emitter: *const Emitter, held: u32) bool {
    assert(held < emitter.count);

    const token = emitter.tokens[held];

    assert(token.kind != .newline);

    if (token.kind == .identifier) return true;
    if (token.kind == .keyword) return true;
    return word_listed(&signature_marks, token.text(emitter.source));
}

pub fn case_block(emitter: *const Emitter, colon: u32) bool {
    assert(colon < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth < 2) return false;
    return case_label(emitter, colon, emitter.nest[emitter.depth - 2].open);
}

pub fn case_label(emitter: *const Emitter, colon: u32, block: u32) bool {
    assert(colon < emitter.count);
    assert(block < emitter.count);

    if (!emitter.tokens[colon].is_punctuation(.colon)) return false;
    if (!case_switched(emitter, block)) return false;

    var scan = colon;

    for (0..case_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;
        const token = emitter.tokens[held];
        const text = token.text(emitter.source);

        assert(held < scan);

        if (walk.is_close(token.kind)) {
            scan = emitter.brackets.open_of(held) orelse return false;

            continue;
        }

        if (word_listed(&case_words, text)) return true;
        if (walk.is_open(token.kind)) return false;
        if (word_listed(&case_stops, text)) return false;

        scan = held;
    }

    return false;
}

fn case_switched(emitter: *const Emitter, block: u32) bool {
    assert(block < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const held = emit.back_of(emitter, block) orelse return false;
    if (!emitter.tokens[held].is_punctuation(.paren_close)) return false;

    const open = emitter.brackets.open_of(held) orelse return false;
    const word = emit.back_of(emitter, open) orelse return false;

    return walk.text_is(emitter.tokens[word].text(emitter.source), "switch");
}

pub fn declare_broken(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    if (emitter.tokens[position].kind == .comment) {
        if (!declare_led(emitter, position)) return false;
    }

    return declares_item(emitter, prior);
}

fn declare_led(emitter: *const Emitter, comment_at: u32) bool {
    assert(comment_at < emitter.count);
    assert(emitter.tokens[comment_at].kind == .comment);

    const text = emitter.tokens[comment_at].text(emitter.source);
    if (std.mem.startsWith(u8, text, "//")) return false;

    const held = emit.ahead_of(emitter, comment_at) orelse return false;
    return !body.parts_at(emitter, comment_at, held);
}

pub fn declares_item(emitter: *const Emitter, prior: u32) bool {
    assert(prior < emitter.count);
    assert(emitter.listed <= core.binder_depth_max);

    if (!emitter.policy.declare_lines) return false;
    if (!emitter.tokens[prior].is_punctuation(.comma)) return false;
    if (!line.statement_level(emitter)) return false;
    if (emitter.brackets.angles_at(prior) > 0) return false;
    if (declares_within(emitter, prior)) return opens_a_declarator(emitter, prior);

    const found = edge.statement_head(emitter, prior) orelse return false;
    const head = if (emitter.tokens[found].kind == .comment) line.coding(emitter, found) else found;
    const coded = head orelse return false;
    const binder = binder_of(emitter, coded) orelse return false;

    assert(binder >= coded);

    if (!opens_a_declarator(emitter, prior)) return false;
    return declares_a_value(emitter, binder);
}

pub fn declares_level(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.listed <= core.binder_depth_max);

    const prior = line.coded(emitter) orelse return null;

    assert(prior < emitter.count);

    if (declares_header_step(emitter, prior)) |level| return level;
    if (declares_item(emitter, prior)) return declares_base(emitter);
    if (emitter.listed == 0) return null;

    const binder = emitter.binders[emitter.listed - 1];
    if (binder.depth != emitter.depth) return null;
    if (prior < binder.start) return null;
    if (prior >= binder.stop) return null;
    if (prior == binder.start) return declares_base(emitter);
    if (!emitter.tokens[prior].is_punctuation(.comma)) return null;
    if (!opens_a_declarator(emitter, prior)) return null;
    return declares_base(emitter);
}

fn declares_header_step(emitter: *const Emitter, prior: u32) ?u32 {
    assert(prior < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!declares_headed(emitter)) return null;
    if (!emitter.tokens[prior].is_punctuation(.comma)) return null;
    if (!opens_a_declarator(emitter, prior)) return null;

    assert(emitter.depth > 0);

    const spread = emitter.broken > 0 and line.frame(emitter).spread != null;
    const returned = emitter.levels -| @intFromBool(spread);

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn declares_base(emitter: *const Emitter) u32 {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.listed <= core.binder_depth_max);

    return clause.base(emitter);
}

pub fn declares_list(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.declare_lines) return false;
    if (!line.word_is(emitter, position, emitter.policy.binder_words)) return false;
    if (emitter.brackets.angles_at(position) > 0) return false;

    if (!line.statement_level(emitter)) {
        if (!declares_headed(emitter)) return false;
    }

    if (emit.ahead_of(emitter, position)) |held| {
        if (walk.text_is(emitter.tokens[held].text(emitter.source), "enum")) return false;
    }

    const stop = declares_stop(emitter, position) orelse return false;

    assert(stop > position);

    return declares_next(emitter, position, stop) != null;
}

fn declares_headed(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return false;

    const frame = emitter.nest[emitter.depth - 1];

    assert(frame.open < emitter.count);

    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return false;
    return split.headed(emitter, frame.open);
}

pub fn declares_stop(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var depth: u32 = 0;
    var scan = position + 1;

    while (scan < emitter.count) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const opened = walk.is_open(kind) or spans_open(emitter, scan);

        if (opened) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            if (depth == 0) {
                assert(scan <= emitter.count);

                return scan;
            }

            depth -= 1;
        } else if (depth == 0) {
            if (kind.eql(.{ .punctuation = .semicolon })) {
                assert(scan <= emitter.count);

                return scan;
            }
        } else {}
    }

    return null;
}

fn declares_next(emitter: *const Emitter, position: u32, stop: u32) ?u32 {
    assert(position < stop);
    assert(stop <= emitter.count);

    var depth: u32 = 0;
    var scan = position + 1;

    while (scan < stop) {
        if (depth == 0) {
            if (declares_class_end(emitter, scan)) |close| {
                scan = close + 1;

                continue;
            }
        }

        const kind = emitter.tokens[scan].kind;
        const opened = walk.is_open(kind) or spans_open(emitter, scan);

        if (opened) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (declares_comma_opens(emitter, position, scan)) {
                assert(scan <= emitter.count);

                return scan;
            }
        } else {}

        scan += 1;
    }

    return null;
}

fn declares_class_end(emitter: *const Emitter, scan: u32) ?u32 {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!walk.text_is(emitter.tokens[scan].text(emitter.source), "class")) return null;

    const open = emitter.brackets.block_after(scan) orelse return null;
    const close = join.closing_of(emitter, open) orelse return null;

    assert(close > scan);

    return close;
}

fn declares_comma_opens(emitter: *const Emitter, position: u32, scan: u32) bool {
    assert(position < scan);
    assert(scan < emitter.count);

    if (!emitter.tokens[scan].is_punctuation(.comma)) return false;
    if (emitter.brackets.angles_at(scan) > emitter.brackets.angles_at(position)) return false;
    return opens_a_declarator(emitter, scan);
}

fn declares_within(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.listed <= core.binder_depth_max);

    if (emitter.listed == 0) return false;

    const binder = emitter.binders[emitter.listed - 1];
    if (!binder.valued) return false;
    if (binder.depth != emitter.depth) return false;
    if (position <= binder.start) return false;
    return position < binder.stop;
}

pub fn declare_headed(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    if (!emitter.policy.declare_lines) return false;
    if (emitter.tokens[position].kind == .comment) return false;
    if (!emitter.tokens[prior].is_punctuation(.comma)) return false;
    if (emitter.depth == 0) return false;

    const frame = line.frame(emitter);
    if (!comment.header_clauses(emitter, frame.open)) return false;
    if (!opens_a_declarator(emitter, prior)) return false;

    const head = edge.statement_head(emitter, prior) orelse return false;
    if (binder_of(emitter, head) == null) return false;

    const stop = clause_stop(emitter, prior, frame.close);
    const based = link.line_led(emitter, head) orelse span.printer_level(emitter);
    const room = based * emitter.options.indent_width + span.printed_columns(emitter, head, stop);
    if (room > emitter.options.line_width) return true;
    return span.spread_breaks(emitter, head, stop);
}

pub fn clause_stop(emitter: *const Emitter, position: u32, close: u32) u32 {
    assert(position < emitter.count);
    assert(close <= emitter.count);

    var depth: u32 = 0;
    var scan = position;

    while (scan < close) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const opened = walk.is_open(kind) or spans_open(emitter, scan);

        if (opened) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (kind.eql(.{ .punctuation = .semicolon })) return scan;
        } else {}
    }

    return close;
}

pub fn binder_joined(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    if (!emitter.policy.declare_lines) return false;
    if (emitter.tokens[position].kind == .comment) return false;
    if (!line.word_is(emitter, prior, emitter.policy.binder_words)) return false;
    return line.statement_level(emitter);
}

fn sequence_callee(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!sequence_spread(emitter, open)) return false;

    const valued = sequence_valued(emitter, open);
    const close = join.closing_of(emitter, open);
    const after = if (close) |held| emit.ahead_of(emitter, held) else null;
    const called = if (after) |held| emitter.tokens[held].is_punctuation(.paren_open) else false;

    return valued and called;
}

fn sequence_valued(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const held = emit.back_of(emitter, open) orelse return false;
    if (emitter.tokens[held].is_punctuation(.assign)) return true;
    return line.word_is(emitter, held, &jump_values);
}

pub fn sequence_group_opens(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return;
    if (line.frame(emitter).open != position) return;
    if (!sequence_callee(emitter, position)) return;

    try emitter.document.push(.group_open);

    emitter.nest[emitter.depth - 1].sequenced = emitter.document.group_serial();
}

pub fn sequence_group_closes(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position <= emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const frame = line.frame(emitter);

    if (emitter.depth == 0) return;
    if (frame.close != position) return;

    const serial = frame.sequenced orelse return;
    if (emitter.document.group_serial() == serial) return emitter.document.push(.group_close);
    if (!emitter.document.group_open(serial)) return;

    try emitter.document.defer_close(serial);
}

pub fn sequence_group_lined(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return false;
    if (line.frame(emitter).sequenced == null) return false;

    const held = emitter.previous orelse return false;

    assert(held < emitter.count);

    return emitter.tokens[held].is_punctuation(.comma);
}

pub fn sequence_broken(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    if (emitter.tokens[position].kind == .comment) return false;

    if (emitter.depth > 0) {
        if (line.frame(emitter).sequenced != null) return false;
    }

    if (sequence_ranged(emitter, prior)) return true;

    const head, _ = sequence_comma(emitter, prior) orelse return false;
    return sequence_parted(emitter, head, prior);
}

fn sequence_ranged(emitter: *const Emitter, prior: u32) bool {
    assert(prior < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.sequence_lines) return false;
    if (!emitter.tokens[prior].is_punctuation(.comma)) return false;
    if (emitter.brackets.angles_at(prior) != 0) return false;

    if (!line.statement_level(emitter)) {
        if (!sequence_grouped(emitter)) return false;
    }

    return edge.statement_head(emitter, prior) == null;
}

pub fn sequence_level(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const prior = line.coded(emitter) orelse return null;

    assert(prior < emitter.count);

    if (sequence_headed(emitter, position, prior)) {
        const keyed = emit.valued_colon(emitter, prior);
        const returned = emitter.printed + @intFromBool(!keyed);

        assert(returned < std.math.maxInt(u32));

        return returned;
    }

    if (sequence_ranged(emitter, prior)) return sequence_ranged_level(emitter);

    const head, const indented = sequence_comma(emitter, prior) orelse return null;
    if (sequence_owed(emitter, head)) |open| return sequence_owed_level(emitter, open);

    const level = lead.leveled_at(emitter, head) orelse return null;
    const step = indented and !sequence_wrapped(emitter);
    const returned = level + @intFromBool(step);

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn sequence_ranged_level(emitter: *const Emitter) u32 {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (!line.statement_level(emitter)) {
        if (sequence_grouped(emitter)) return line.frame(emitter).seated;
    }

    if (sequence_wrapped(emitter)) {
        const top = wrap.run_top(emitter);
        const start = emitter.wrapped[top].start;

        return lead.leveled_at(emitter, start) orelse emitter.wraps_indent[top];
    }

    if (line.statement_level(emitter)) {
        if (!clause.within(emitter)) {
            assert(emitter.levels + 1 < std.math.maxInt(u32));

            return emitter.levels + 1;
        }
    }

    return emitter.printed;
}

pub fn sequence_headed(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    if (!emitter.policy.sequence_lines) return false;

    const keyed = emit.valued_colon(emitter, prior);

    if (!emitter.tokens[prior].is_punctuation(.assign)) {
        if (!keyed) return false;
    }

    if (!sequence_paren(emitter, position)) return false;
    if (!sequence_spread(emitter, position)) return false;
    if (sequence_callee(emitter, position)) return false;

    const close = join.closing_of(emitter, position) orelse return false;
    const stop = sequence_tail(emitter, close);

    const level = if (keyed)
        sequence_keyed_level(emitter)
    else
        emitter.printed + lead.spread_levels(emitter) + 1;

    if (span.spread_breaks(emitter, position, close)) return true;

    const columns = span.printed_columns(emitter, position, stop);
    return level * emitter.options.indent_width + columns > emitter.options.line_width;
}

fn sequence_keyed_level(emitter: *const Emitter) u32 {
    assert(emitter.depth > 0);
    assert(emitter.depth <= brace.nest_depth_max);

    const level = lead.leveled_at(emitter, line.frame(emitter).open) orelse emitter.printed;
    assert(level + 2 < std.math.maxInt(u32));

    return level + 2;
}

pub fn spans_open(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.source.len <= std.math.maxInt(u32));

    return walk.substituting(emitter.source, emitter.tokens[position]);
}

fn sequence_comma(emitter: *const Emitter, prior: u32) ?struct { u32, bool } {
    assert(prior < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.sequence_lines) return null;
    if (!emitter.tokens[prior].is_punctuation(.comma)) return null;
    if (emitter.brackets.angles_at(prior) != 0) return null;

    const indented = line.statement_level(emitter);

    if (!indented) {
        if (!sequence_grouped(emitter)) return null;
    }

    const found = edge.statement_head(emitter, prior) orelse return null;
    const commented = emitter.tokens[found].kind == .comment;
    const found_coded = if (commented) line.coding(emitter, found) else found;
    const coded = found_coded orelse return null;
    const worded = clause.body_worded_at(emitter, coded);
    const head_coded = if (worded) line.coding(emitter, coded) else coded;
    const head = head_coded orelse return null;
    if (binder_of(emitter, head) != null) return null;
    if (line.word_is(emitter, head, emitter.policy.sequence_stops)) return null;

    if (unite.decorated_word(emitter, head)) |word| {
        if (line.word_is(emitter, word, emitter.policy.sequence_stops)) return null;
    }

    return .{ head, indented };
}

pub fn sequence_paren_joined(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    if (emitter.tokens[prior].is_punctuation(.paren_open)) return sequence_spread(emitter, prior);
    if (!emitter.tokens[position].is_punctuation(.paren_close)) return false;

    const open = emitter.brackets.open_of(position) orelse return false;

    assert(open < position);

    return sequence_spread(emitter, open);
}

fn sequence_arrowed(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const after = emit.ahead_of(emitter, close) orelse return false;
    const text = emitter.tokens[after].text(emitter.source);
    if (walk.text_is(text, "=>")) return true;
    if (!walk.text_is(text, ":")) return false;

    var depth: u32 = 0;

    for (after + 1..after + 1 + core.define_scan_max) |index| {
        const scan: u32 = @intCast(index);
        if (scan >= emitter.count) return false;

        const kind = emitter.tokens[scan].kind;
        const opened = walk.is_open(kind) or spans_open(emitter, scan);

        if (opened) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            if (depth == 0) return false;

            depth -= 1;
        } else if (depth == 0) {
            if (sequence_arrow_text(emitter, scan)) |arrowed| return arrowed;
        } else {}
    }

    return false;
}

fn sequence_arrow_text(emitter: *const Emitter, scan: u32) ?bool {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emitter.tokens[scan].text(emitter.source);
    if (walk.text_is(held, "=>")) return true;
    if (walk.text_is(held, ";")) return false;
    if (walk.text_is(held, ",")) return false;
    return null;
}

pub fn sequence_spread(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.sequence_lines) return false;
    if (!sequence_paren(emitter, open)) return false;

    const close = join.closing_of(emitter, open) orelse return false;
    var depth: u32 = 0;
    var scan = open + 1;

    assert(close > open);

    while (scan < close) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const opened = walk.is_open(kind) or spans_open(emitter, scan);

        if (opened) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (sequence_comma_flat(emitter, scan)) return true;
        } else {}
    }

    return false;
}

fn sequence_parted(emitter: *const Emitter, head: u32, comma: u32) bool {
    assert(head < emitter.count);
    assert(comma < emitter.count);

    const stop = sequence_end(emitter, comma) orelse return true;
    if (sequence_header_parted(emitter, head, stop)) |parted| return parted;
    if (sequence_branch_parted(emitter, head, stop)) |parted| return parted;
    if (sequence_iterated_parted(emitter, head, stop)) |parted| return parted;
    if (sequence_arrowed_parted(emitter, head, stop)) |parted| return parted;

    const from, const level, const led = sequence_seat(emitter, head);
    const end = sequence_tail_logical(emitter, head, sequence_tail(emitter, stop));
    if (sequence_returned(emitter, head, end, level)) |parted| return parted;
    if (span.spread_breaks(emitter, from, end)) return true;

    const spreads = if (led) 0 else lead.spread_levels(emitter);

    const room = (level + spreads) * emitter.options.indent_width +
        sequence_branch_aligns(emitter, head) +
        span.printed_columns(emitter, from, end);

    return room > emitter.options.line_width;
}

fn sequence_arrowed_parted(emitter: *const Emitter, head: u32, stop: u32) ?bool {
    assert(head < emitter.count);
    assert(stop < emitter.count);

    const level = sequence_arrowed_level(emitter, head) orelse return null;
    const ended = emit.back_of(emitter, stop) orelse stop;
    const columns = span.printed_columns(emitter, head, ended);
    if (level * emitter.options.indent_width + columns > emitter.options.line_width) return true;
    return span.spread_breaks(emitter, head, stop);
}

fn sequence_returned(emitter: *const Emitter, head: u32, end: u32, level: u32) ?bool {
    assert(head < emitter.count);
    assert(end < emitter.count);

    if (!sequence_wrapped(emitter)) return null;
    if (!word_listed(&jump_values, emitter.tokens[head].text(emitter.source))) return null;
    assert(level < std.math.maxInt(u32));

    const opening = emit.ahead_of(emitter, head) orelse return null;
    const closing = emit.back_of(emitter, end) orelse return null;
    if (opening > closing) return null;

    const columns = span.printed_columns(emitter, opening, closing);
    return (level + 1) * emitter.options.indent_width + columns > emitter.options.line_width;
}

fn sequence_header_parted(emitter: *const Emitter, head: u32, stop: u32) ?bool {
    assert(head < emitter.count);
    assert(stop < emitter.count);

    const open = emit.back_of(emitter, head) orelse return null;
    const outer = emit.back_of(emitter, open) orelse return null;
    if (!sequence_header_whole(emitter, open, outer, stop)) return null;
    if (span.spread_breaks(emitter, head, stop)) return true;

    const close = emit.ahead_of(emitter, stop) orelse return null;
    const seat = line.at(emitter, outer) orelse return null;
    const level = link.line_led(emitter, outer) orelse return null;
    const width = emitter.options.line_width;
    const indent = emitter.options.indent_width;
    const aligns = clause.header_aligns(emitter);
    const whole = span.printed_columns(emitter, seat.start - 1, close);
    if (level * indent + aligns + whole <= width) return false;
    return (level + 1) * indent + aligns + span.printed_columns(emitter, open, stop) > width;
}

fn sequence_header_whole(emitter: *const Emitter, open: u32, outer: u32, stop: u32) bool {
    assert(outer < open);
    assert(open < emitter.count);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;
    if (!emitter.tokens[outer].is_punctuation(.paren_open)) return false;
    if (!split.headed(emitter, outer)) return false;

    const shut = join.closing_of(emitter, open) orelse return false;
    if (shut != stop) return false;

    const close = join.closing_of(emitter, outer);
    const after = emit.ahead_of(emitter, stop) orelse return close == null;

    return close == after;
}

fn sequence_branch_parted(emitter: *const Emitter, head: u32, stop: u32) ?bool {
    assert(head < emitter.count);
    assert(stop < emitter.count);

    if (emitter.wraps_owed == 0) return null;

    const open = sequence_paren_before(emitter, head) orelse return null;
    const operator = emit.back_of(emitter, open) orelse return null;
    if (!span.wrapping_operator(emitter, operator)) return null;

    const held = &emitter.wrapped[wrap.run_top(emitter)];
    if (!sequence_branch_owned(emitter, held, open, operator, stop)) return null;

    const mark = emit.back_of(emitter, held.start) orelse return null;
    if (!sequence_branch_marked(emitter, mark)) return null;

    const width = emitter.options.line_width;
    const based = sequence_branch_columns(emitter, mark, held.start) orelse return null;
    const end = sequence_tail(emitter, held.close);
    const spread = span.spread_breaks(emitter, held.start, held.close);
    const broken = spread or based + span.printed_columns(emitter, held.start, end) > width;
    if (!broken) return false;
    if (span.spread_breaks(emitter, head, stop)) return true;
    return based + span.printed_columns(emitter, open, sequence_tail(emitter, stop)) > width;
}

fn sequence_branch_owned(
    emitter: *const Emitter,
    held: *const core.Wrapped,
    open: u32,
    operator: u32,
    stop: u32,
) bool {
    assert(open < emitter.count);
    assert(operator < open);

    if (held.wrap != .paired) return false;
    if (operator <= held.start) return false;
    if (operator >= held.close) return false;

    const shut = join.closing_of(emitter, open) orelse return false;
    if (shut != stop) return false;
    return call.binary_level(emitter.tokens[operator].text(emitter.source)) == held.floor;
}

fn sequence_branch_marked(emitter: *const Emitter, mark: u32) bool {
    assert(mark < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const text = emitter.tokens[mark].text(emitter.source);
    if (walk.text_is(text, "?")) return true;
    return walk.text_is(text, ":");
}

fn sequence_branch_columns(emitter: *const Emitter, mark: u32, start: u32) ?u32 {
    assert(mark < emitter.count);
    assert(start < emitter.count);

    const indent = emitter.options.indent_width;

    if (line.at(emitter, start)) |seat| {
        if (seat.start - 1 == mark) {
            const level = link.line_led(emitter, start) orelse return null;
            const returned = level * indent + branch_align_columns;

            assert(returned < std.math.maxInt(u32));

            return returned;
        }
    }

    const head = sequence_branch_head(emitter, mark) orelse return null;
    const level = link.line_led(emitter, head) orelse return null;
    const returned = (level + 1) * indent + lead.ternary_align_columns(emitter);

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn sequence_branch_head(emitter: *const Emitter, mark: u32) ?u32 {
    assert(mark < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    var index = emitter.wraps_owed;

    while (index > 0) {
        index -= 1;

        const held = emitter.wrapped[index];

        const kinded = switch (held.wrap) {
            .guarded, .nested, .ternary => true,
            else => false,
        };

        if (!kinded) continue;
        if (held.start >= mark) continue;
        if (mark < held.close) return held.start;
    }

    return null;
}

fn sequence_operand(emitter: *const Emitter, head: u32) ?struct { u32, u32 } {
    assert(head < emitter.count);
    assert(emitter.options.indent_width > 0);

    const open, const columns = sequence_operand_seat(emitter, head) orelse return null;
    return .{ open, @divFloor(columns, emitter.options.indent_width) };
}

fn sequence_operand_aligns(emitter: *const Emitter, head: u32) u32 {
    assert(head < emitter.count);
    assert(emitter.options.indent_width > 0);

    _, const columns = sequence_operand_seat(emitter, head) orelse return 0;

    return @mod(columns, emitter.options.indent_width);
}

fn sequence_operand_seat(emitter: *const Emitter, head: u32) ?struct { u32, u32 } {
    assert(head < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.wraps_owed == 0) return null;

    const open = sequence_paren_before(emitter, head) orelse return null;
    const operator = emit.back_of(emitter, open) orelse return null;
    if (!span.wrapping_operator(emitter, operator)) return null;

    const held = &emitter.wrapped[wrap.run_top(emitter)];
    if (held.wrap != .argued) return null;
    if (operator <= held.start) return null;
    if (operator >= held.close) return null;
    if (call.binary_level(emitter.tokens[operator].text(emitter.source)) != held.floor) return null;

    const columns = run_columns(emitter, held.start) orelse return null;
    const end = sequence_tail(emitter, held.close);
    const spread = span.spread_breaks(emitter, held.start, held.close);
    const width = emitter.options.line_width;
    const broken = spread or columns + span.printed_columns(emitter, held.start, end) > width;
    if (!broken) return null;
    return .{ open, columns + emitter.options.indent_width };
}

fn sequence_paren_before(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const open = emit.back_of(emitter, head) orelse return null;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return null;
    return open;
}

fn run_columns(emitter: *const Emitter, start: u32) ?u32 {
    assert(start < emitter.count);
    assert(emitter.options.indent_width > 0);

    if (sequence_branch(emitter, start)) |branch| {
        const mark = branch[0];

        if (line.at(emitter, start)) |seat| {
            if (seat.start - 1 <= mark) return sequence_branch_columns(emitter, mark, start);
        }
    }

    const level = link.line_led(emitter, start) orelse return null;
    assert(level * emitter.options.indent_width < std.math.maxInt(u32));

    return level * emitter.options.indent_width;
}

pub fn pattern_wide(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (!pattern_shaped(emitter, open, close)) return false;
    return !list.pattern_fits(emitter, open, close);
}

pub fn pattern_assigned(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (!pattern_shaped(emitter, open, close)) return false;

    const equals = emit.ahead_of(emitter, close) orelse return false;
    return walk.text_is(emitter.tokens[equals].text(emitter.source), "=");
}

pub fn pattern_shaped(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (!emitter.policy.chain_simples) return false;
    if (emitter.tokens[open].kind != .block_start) return false;
    if (emit.roled(emitter, open, brace.role_type)) return false;
    if (list.pattern_nested(emitter, open, close)) return false;

    if (pattern_complex(emitter, open, close, false)) {
        if (!list.pattern_signed(emitter, open, close)) return false;
    }

    if (emit.ahead_of(emitter, close)) |held| {
        if (walk.text_is(emitter.tokens[held].text(emitter.source), "=")) return true;
    }

    const before = emit.back_of(emitter, open) orelse return false;
    if (word_listed(&pattern_binders, emitter.tokens[before].text(emitter.source))) return true;

    const paren = pattern_paren(emitter, open, before) orelse return false;
    if (!emitter.tokens[paren].is_punctuation(.paren_open)) return false;

    const shut = join.closing_of(emitter, paren) orelse return false;
    const held = emit.ahead_of(emitter, shut) orelse return false;

    return pattern_shaped_tail(emitter, held);
}

fn pattern_paren(emitter: *const Emitter, open: u32, before: u32) ?u32 {
    assert(before < open);
    assert(open < emitter.count);

    const token = emitter.tokens[before];
    if (token.is_punctuation(.paren_open)) return before;
    if (!token.is_punctuation(.comma)) return null;
    return enclosing_open(emitter, open);
}

fn pattern_shaped_tail(emitter: *const Emitter, held: u32) bool {
    assert(held < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[held];
    if (token.kind == .block_start) return true;
    if (pattern_returned(emitter, held)) return true;
    return walk.text_is(token.text(emitter.source), "=>");
}

fn pattern_returned(emitter: *const Emitter, held: u32) bool {
    assert(held < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.policy.type_words.len == 0) return false;
    if (!emitter.tokens[held].is_punctuation(.colon)) return false;
    return !emit.roled(emitter, held, brace.role_spaced);
}

pub fn pattern_joined(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.chain_simples) return false;
    if (emitter.depth == 0) return false;

    const framed = emitter.nest[emitter.depth - 1];
    if (pattern_joined_paren(emitter, framed, position)) return true;
    if (framed.kind != .block_start) return false;
    if (framed.open < emitter.line_first) return false;

    const close = join.closing_of(emitter, framed.open) orelse return false;
    if (position > close) return false;
    return pattern_brace(emitter, framed.open, close);
}

fn pattern_joined_paren(emitter: *const Emitter, framed: core.Frame, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth > 0);

    if (!framed.kind.eql(.{ .punctuation = .paren_open })) return false;

    const edged = ahead_is(emitter, framed.open, position) or position == framed.close;
    if (!edged) return false;
    return list.pattern_unparted(emitter, framed.open, framed.close);
}

pub fn hole_open(emitter: *const Emitter, close: u32) ?u32 {
    assert(close < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.tokens[close].kind != .block_end) return null;

    const open = emitter.brackets.open_of(close) orelse return null;

    assert(open < close);

    if (!spans_open(emitter, open)) return null;
    return open;
}

pub fn enclosing_open(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    if (core.memo_found(emitter, .enclosing_open, position, 0)) |answer| {
        return if (answer == core.memo_none) null else answer;
    }

    const held = enclosing_open_scanned(emitter, position);

    core.memo_store(emitter, .enclosing_open, position, 0, held orelse core.memo_none);

    return held;
}

fn enclosing_open_scanned(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    var depth: u32 = 0;
    var scan = position;

    for (0..core.define_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return null;
        const kind = emitter.tokens[held].kind;

        assert(held < scan);

        if (hole_open(emitter, held)) |open| {
            scan = open;

            continue;
        }

        if (walk.is_close(kind)) {
            if (depth == 0) {
                if (emitter.brackets.open_of(held)) |open| {
                    scan = open;

                    continue;
                }
            }

            depth += 1;
        } else if (walk.is_open(kind)) {
            if (depth == 0) return held;

            depth -= 1;
        } else {}

        scan = held;
    }

    if (depth > 0) return null;
    return enclosing_framed(emitter, position);
}

fn enclosing_framed(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    var index = emitter.depth;

    while (index > 0) {
        index -= 1;

        const frame = emitter.nest[index];
        if (frame.open >= position) continue;
        if (frame.close <= position) return null;
        return frame.open;
    }

    return null;
}

fn word_listed(words: []const []const u8, word: []const u8) bool {
    assert(words.len > 0);
    assert(word.len <= std.math.maxInt(u32));

    for (words) |listed| {
        if (walk.text_eql(listed, word)) return true;
    }

    return false;
}

pub fn branched_list(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.rest_binds) return false;

    const before = join.coded_before(emitter, open) orelse return false;
    return walk.text_is(emitter.tokens[before].text(emitter.source), "?");
}

pub fn pattern_brace(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (!pattern_shaped(emitter, open, close)) return false;
    if (pattern_commented(emitter, open, close)) return false;
    return list.pattern_fits(emitter, open, close);
}

fn pattern_commented(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    for (open + 1..close) |index| {
        const scan: u32 = @intCast(index);
        const token = emitter.tokens[scan];
        if (token.kind != .comment) continue;
        if (std.mem.startsWith(u8, token.text(emitter.source), "//")) return true;

        const before = emit.back_of(emitter, scan) orelse continue;
        if (body.parts_at(emitter, before, scan)) return true;
    }

    return false;
}

pub fn rested_run(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const open = emitter.brackets.open_of(close) orelse return false;
    var depth: u32 = 0;
    var held = open;
    var scan = open;

    assert(open < close);

    while (scan < close) {
        const ahead = emit.ahead_of(emitter, scan) orelse break;

        assert(ahead > scan);

        if (ahead >= close) break;

        scan = ahead;

        if (tmpl.templated_unit(emitter, scan)) |end| {
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
            if (kind.eql(.{ .punctuation = .comma })) held = scan;
        } else {}
    }

    var found = emit.ahead_of(emitter, held) orelse return false;

    while (emitter.tokens[found].kind == .comment) {
        found = emit.ahead_of(emitter, found) orelse return false;
    }

    if (!std.mem.startsWith(u8, emitter.tokens[found].text(emitter.source), "..")) return false;
    if (!emitter.policy.rest_binds) return true;
    return bound_pattern(emitter, close);
}

pub fn operand_lined(emitter: *const Emitter) ?struct { u32, u32 } {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.line_first <= emitter.count);

    if (emitter.depth == 0) return null;

    const head = emit.ahead_of(emitter, line.frame(emitter).open) orelse return null;
    const open, const columns = sequence_operand_seat(emitter, head) orelse return null;
    if (open <= emitter.line_first) return null;
    return .{ open, columns };
}

fn sequence_arrowed_level(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const open = sequence_paren_before(emitter, head) orelse return null;
    if (!list.arrow_sequenced(emitter, open)) return null;

    const close = join.closing_of(emitter, open) orelse return null;
    const end = sequence_tail(emitter, close);
    const seat = line.at(emitter, open) orelse return null;
    const level = link.line_led(emitter, open) orelse return null;
    const columns = span.printed_columns(emitter, seat.start - 1, end);
    const spread = span.spread_breaks(emitter, open, close);
    const width = emitter.options.line_width;
    const broken = spread or level * emitter.options.indent_width + columns > width;
    if (!broken) return null;
    assert(level + 1 < std.math.maxInt(u32));

    return level + 1;
}

fn sequence_tail_logical(emitter: *const Emitter, head: u32, end: u32) u32 {
    assert(head <= end);
    assert(end < emitter.count);

    if (!sequence_logical(emitter, head)) return end;

    const close = emit.ahead_of(emitter, end) orelse return end;
    if (!emitter.tokens[close].is_punctuation(.paren_close)) return end;

    const after = emit.ahead_of(emitter, close) orelse return close;
    const token = emitter.tokens[after];
    if (token.is_punctuation(.comma)) return after;
    if (token.is_punctuation(.semicolon)) return after;
    return close;
}

fn sequence_tail(emitter: *const Emitter, stop: u32) u32 {
    assert(stop < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.ahead_of(emitter, stop) orelse return stop;
    const token = emitter.tokens[held];
    if (token.is_punctuation(.comma)) return held;
    if (token.is_punctuation(.semicolon)) return held;
    return stop;
}

fn sequence_seat(emitter: *const Emitter, head: u32) Seat {
    assert(head < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (sequence_seated(emitter, head)) |seat| return seat;

    if (sequence_led(emitter, head)) {
        if (link.line_led(emitter, head)) |level| return .{ head, level, true };
    }

    const level = lead.leveled_at(emitter, head) orelse emitter.printed;

    if (sequence_logical(emitter, head)) {
        const open = emit.back_of(emitter, head) orelse head;
        return .{ open, level + sequence_logical_step(emitter, open), false };
    }

    return .{ head, level, false };
}

fn sequence_logical_step(emitter: *const Emitter, open: u32) u32 {
    assert(open < emitter.count);
    assert(emitter.tokens[open].is_punctuation(.paren_open));

    const found = line.at(emitter, open) orelse return 1;

    assert(found.start > 0);

    return @intFromBool(found.start - 1 < open);
}

fn sequence_logical(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const open = emit.back_of(emitter, head) orelse return false;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const operator = emit.back_of(emitter, open) orelse return false;
    if (!span.wrapping_operator(emitter, operator)) return false;

    const run_head, _ = span.binary_run(emitter, operator) orelse return false;

    assert(run_head < operator);

    return span.binary_stated(emitter, run_head);
}

fn sequence_led(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const start, _ = join.line_lead(emitter, head) orelse return false;
    return start == head;
}

pub fn declares_valued(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.listed <= core.binder_depth_max);

    const comma = declares_comma(emitter, position) orelse return false;

    assert(comma < position);

    return declares_item(emitter, comma);
}

fn declares_comma(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var depth: u32 = 0;
    var scan = position;

    while (scan > 0) {
        scan -= 1;

        const kind = emitter.tokens[scan].kind;

        if (walk.is_close(kind)) {
            depth += 1;

            continue;
        }

        const opened = walk.is_open(kind) or spans_open(emitter, scan);

        if (opened) {
            if (depth == 0) return null;

            depth -= 1;

            continue;
        }

        if (depth > 0) continue;
        if (declares_comma_at(emitter, position, scan)) return scan;
        if (kind.eql(.{ .punctuation = .semicolon })) return null;
    }

    return null;
}

fn declares_comma_at(emitter: *const Emitter, position: u32, scan: u32) bool {
    assert(scan < position);
    assert(position < emitter.count);

    if (!emitter.tokens[scan].is_punctuation(.comma)) return false;
    return emitter.brackets.angles_at(scan) <= emitter.brackets.angles_at(position);
}

pub fn opens_a_declarator(emitter: *const Emitter, comma: u32) bool {
    assert(comma < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (heritage_comma(emitter, comma)) return false;

    const name = line.coding(emitter, comma) orelse return false;
    const kind = emitter.tokens[name].kind;

    if (kind != .identifier) {
        if (!walk.is_open(kind)) return false;
    }

    const held = declarator_after(emitter, name) orelse return true;
    const token = emitter.tokens[held];
    if (token.is_punctuation(.assign)) return true;
    if (token.is_punctuation(.colon)) return true;
    if (token.is_punctuation(.comma)) return true;
    return token.is_punctuation(.semicolon);
}

fn declarator_after(emitter: *const Emitter, name: u32) ?u32 {
    assert(name < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.tokens[name].kind == .identifier) return emit.ahead_of(emitter, name);

    assert(walk.is_open(emitter.tokens[name].kind));

    const close = join.closing_of(emitter, name) orelse return null;

    assert(close > name);

    return emit.ahead_of(emitter, close);
}

fn heritage_comma(emitter: *const Emitter, comma: u32) bool {
    assert(comma < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = comma;

    for (0..core.define_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;
        const token = emitter.tokens[held];

        assert(held < scan);

        if (walk.is_close(token.kind)) {
            scan = emitter.brackets.open_of(held) orelse return false;

            continue;
        }

        if (walk.is_open(token.kind)) return false;
        if (token.is_punctuation(.semicolon)) return false;
        if (token.is_punctuation(.assign)) return false;
        if (walk.text_is(token.text(emitter.source), "implements")) return true;

        scan = held;
    }

    return false;
}

pub fn sequence_grouped(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.depth == 0) return false;
    return sequence_paren(emitter, emitter.nest[emitter.depth - 1].open);
}

fn sequence_paren(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (core.memo_found(emitter, .sequence_paren, open, 0)) |answer| return answer == 1;

    const held = sequence_paren_scanned(emitter, open);

    core.memo_store(emitter, .sequence_paren, open, 0, @intFromBool(held));

    return held;
}

fn sequence_paren_scanned(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;
    if (sequence_signed(emitter, open)) return false;

    if (join.closing_of(emitter, open)) |close| {
        if (sequence_arrowed(emitter, close)) return false;
    }

    const before = emit.back_of(emitter, open) orelse return true;
    const text = emitter.tokens[before].text(emitter.source);
    if (walk.text_is(text, "?")) return !tern.optional(emitter, before);
    if (word_listed(&sequence_heads, text)) return true;
    if (word_listed(&sequence_keywords, text)) return !sequence_named(emitter, before, open);
    return sequence_iterated(emitter, open);
}

fn sequence_named(emitter: *const Emitter, word: u32, open: u32) bool {
    assert(word < open);
    assert(open < emitter.count);

    if (list.member_worded(emitter, word)) return true;

    const close = join.closing_of(emitter, open) orelse return false;
    const after = emit.ahead_of(emitter, close) orelse return false;

    return emitter.tokens[after].kind == .block_start;
}

fn sequence_signed(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (core.memo_found(emitter, .sequence_signed, open, 0)) |answer| return answer == 1;

    const held = sequence_signed_scanned(emitter, open);

    core.memo_store(emitter, .sequence_signed, open, 0, @intFromBool(held));

    return held;
}

fn sequence_signed_scanned(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.tokens[open].is_punctuation(.paren_open));

    const close = join.closing_of(emitter, open) orelse return false;
    const held = emit.ahead_of(emitter, close) orelse return false;

    assert(held > close);

    if (!emitter.tokens[held].is_punctuation(.colon)) return false;

    const stop = enclosing_open(emitter, open) orelse 0;
    return !tern.ternary_within(emitter, held, stop);
}

fn sequence_iterated(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const held = emit.back_of(emitter, open) orelse return false;
    if (!line.word_is(emitter, held, &iterate_words)) return false;

    const outer = enclosing_open(emitter, open) orelse return false;
    if (!list.headed_loop(emitter, outer)) return false;

    const close = join.closing_of(emitter, outer) orelse return false;
    const shut = join.closing_of(emitter, open) orelse return false;
    const after = emit.ahead_of(emitter, shut) orelse return false;

    return after == close;
}

fn sequence_iterated_parted(emitter: *const Emitter, head: u32, stop: u32) ?bool {
    assert(head < emitter.count);
    assert(stop < emitter.count);

    const open = emit.back_of(emitter, head) orelse return null;
    const shut = join.closing_of(emitter, open) orelse return null;
    if (shut != stop) return null;
    if (!sequence_iterated(emitter, open)) return null;
    if (span.spread_breaks(emitter, head, stop)) return true;

    const outer = enclosing_open(emitter, open) orelse return null;
    const close = join.closing_of(emitter, outer) orelse return null;
    const seat = line.at(emitter, outer) orelse return null;
    const level = link.line_led(emitter, outer) orelse return null;
    const columns = span.printed_columns(emitter, seat.start - 1, close);

    return level * emitter.options.indent_width + columns > emitter.options.line_width;
}

pub fn sequence_wrapped(emitter: *const Emitter) bool {
    assert(emitter.wraps_owed <= core.wrap_depth_max);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.wraps_owed == 0) return false;

    const held = emitter.wrapped[wrap.run_top(emitter)];
    if (held.wrap != .parens) return false;
    return held.depth == emitter.depth;
}

pub fn numeric_lookup(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[open].is_punctuation(.bracket_open)) return false;
    assert(close < emitter.count);

    const held = emit.ahead_of(emitter, open) orelse return false;
    if (emitter.tokens[held].kind != .number) return false;
    return ahead_is(emitter, held, close);
}

pub fn slight_key(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const found = emit.word_before(emitter, position) orelse return false;
    const questioned = walk.text_is(emitter.tokens[found].text(emitter.source), "?");
    const word = if (questioned) emit.word_before(emitter, found) else found;
    const held = word orelse return false;
    const width: u32 = @intFromBool(questioned);
    const token = emitter.tokens[held];

    switch (token.kind) {
        .identifier, .keyword, .number, .string => {},
        else => return false,
    }

    const quoted: u32 = @as(u32, @intFromBool(key.unquoting(emitter, held) != null)) * 2;
    return width + token.length - quoted < emitter.options.indent_width + 3;
}

fn trails(emitter: *const Emitter, position: u32, end: u32) bool {
    assert(position < emitter.count);
    assert(end <= emitter.count);

    var ahead = emit.ahead_of(emitter, position) orelse return true;

    if (emitter.tokens[ahead].kind == .comment) {
        ahead = emit.ahead_of(emitter, ahead) orelse return true;
    }

    if (ahead >= end) return true;

    const token = emitter.tokens[ahead];
    const separated = token.is_punctuation(.comma) or token.is_punctuation(.semicolon);
    if (!separated) return false;

    const after = emit.ahead_of(emitter, ahead) orelse return true;
    return after >= end;
}

fn ahead_is(emitter: *const Emitter, position: u32, target: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const ahead = emit.ahead_of(emitter, position) orelse return false;
    return ahead == target;
}

pub fn lone_value(emitter: *const Emitter, position: u32, end: u32) bool {
    assert(position < emitter.count);
    assert(end <= emitter.count);

    const held = lone_head(emitter, position) orelse return false;
    if (held >= end) return false;

    const token = emitter.tokens[held];
    const tagged = lone_value_tagged(emitter, held);
    const whole = tmpl.template_whole(emitter, held);
    const close = whole orelse tagged orelse own.bodied_of(emitter, held);
    const alone = trails(emitter, close orelse held, end);
    const text = token.text(emitter.source);
    const literal = word_listed(&lone_literals, text);

    if (!alone) return false;
    if (literal) return true;
    if (tagged != null) return true;
    if (token.kind == .number) return true;
    if (token.kind != .string) return false;
    return std.mem.startsWith(u8, text, "`");
}

fn lone_head(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var prior = position;
    var held = emit.ahead_of(emitter, position) orelse return null;

    for (0..emitter.count) |_| {
        const token = emitter.tokens[held];
        if (token.kind != .comment) return held;
        if (!std.mem.startsWith(u8, token.text(emitter.source), "/*")) return null;
        if (body.parts_at(emitter, prior, held)) return null;

        prior = held;
        held = emit.ahead_of(emitter, held) orelse return null;

        if (body.parts_at(emitter, prior, held)) return null;
    }

    return null;
}

fn lone_value_tagged(emitter: *const Emitter, held: u32) ?u32 {
    assert(held < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.tokens[held].kind != .identifier) return null;

    const after = emit.ahead_of(emitter, held) orelse return null;

    assert(after > held);

    return tmpl.template_whole(emitter, after);
}

pub fn paired_binary(emitter: *const Emitter, colon: u32) bool {
    assert(colon < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const head = emit.ahead_of(emitter, colon) orelse return false;

    assert(head > colon);

    return own.value_wrap(emitter, head) != null;
}

pub fn paired_sequence(emitter: *const Emitter, colon: u32) bool {
    assert(colon < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const head = emit.ahead_of(emitter, colon) orelse return false;

    assert(head > colon);

    return sequence_spread(emitter, head);
}

pub fn paired_fluid(emitter: *const Emitter, colon: u32) bool {
    assert(colon < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const head = emit.ahead_of(emitter, colon) orelse return false;
    const wrapped = own.value_wrap(emitter, head) orelse return false;
    if (wrapped[1] != .argued) return false;
    return call.binary_fluid(emitter, head, wrapped[0]);
}

pub fn value_cast_word(emitter: *const Emitter, position: u32, bound: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);
    assert(bound <= emitter.count);

    var depth: u32 = 0;
    var scan = position + 1;

    while (scan < bound) {
        if (tmpl.template_body(emitter, scan)) |end| {
            assert(end >= scan);

            scan = end + 1;

            continue;
        }

        const kind = emitter.tokens[scan].kind;
        const opened = walk.is_open(kind) or kind == .block_start;
        const closed = walk.is_close(kind) or kind == .block_end;

        if (opened) {
            depth += 1;
        } else if (closed) {
            depth -|= 1;
        } else if (depth == 0) {
            if (emitter.brackets.angles_at(scan) == 0) {
                const text = emitter.tokens[scan].text(emitter.source);
                if (word_listed(&cast_words, text)) return scan;
                if (value_cast_halts(emitter, scan)) return null;
            }
        } else {}

        scan += 1;
    }

    return null;
}

fn value_cast_halts(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const text = emitter.tokens[scan].text(emitter.source);

    if (word_listed(&cast_halts, text)) {
        if (!tern.optional(emitter, scan)) return true;
    }

    return span.wrapping_operator(emitter, scan);
}

pub fn cast_stops(emitter: *const Emitter, word: u32, scan: u32) bool {
    assert(word < emitter.count);
    assert(scan < emitter.count);

    if (scan == word) {
        if (unite.cast_union_at(emitter, word)) return true;
    }

    if (cast_angled(emitter, scan)) return true;
    return cast_signed(emitter, scan);
}

pub fn lined_tag(emitter: *const Emitter, position: u32, scan: u32) ?u32 {
    assert(position < emitter.count);
    assert(scan < emitter.count);

    const end = tmpl.template_whole(emitter, scan) orelse return null;
    if (!tmpl.template_lined(emitter, scan, end)) return null;

    const held = emit.back_of(emitter, scan) orelse return null;

    assert(held < scan);

    if (held <= position) return null;
    if (emitter.tokens[held].kind != .identifier) return null;
    return held;
}

fn cast_angled(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!walk.text_is(emitter.tokens[open].text(emitter.source), "<")) return false;

    const ends = join.angle_close(emitter, open) orelse return false;
    const head = emit.ahead_of(emitter, open) orelse return false;
    if (head >= ends) return false;
    return !join.angle_hugged(emitter, head, ends);
}

fn cast_signed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[position];
    if (token.is_punctuation(.paren_open)) return cast_signed_paren(emitter, position);
    if (!walk.text_is(token.text(emitter.source), "=>")) return false;

    var head = emit.ahead_of(emitter, position) orelse return false;

    if (walk.text_is(emitter.tokens[head].text(emitter.source), "|")) {
        head = emit.ahead_of(emitter, head) orelse return false;
    }

    if (span.union_of(emitter, head) != null) return true;
    return unite.union_cast_headed(emitter, head);
}

fn cast_signed_paren(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.tokens[position].is_punctuation(.paren_open));

    const closing = join.closing_of(emitter, position);
    const ahead = emit.ahead_of(emitter, position);
    if (closing == null) return ahead != null;
    if (ahead == null) return true;
    return closing.? != ahead.?;
}

pub fn declares_headed_item(emitter: *const Emitter, comma: u32) bool {
    assert(comma < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.declare_lines) return false;
    if (!declares_headed(emitter)) return false;
    if (!comment.header_clauses(emitter, line.frame(emitter).open)) return false;
    if (!opens_a_declarator(emitter, comma)) return false;

    const head = edge.statement_head(emitter, comma) orelse return false;
    return binder_of(emitter, head) != null;
}

pub fn declares_later(emitter: *const Emitter, name: u32) bool {
    assert(name < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const comma = emit.back_of(emitter, name) orelse return false;

    assert(comma < name);

    if (!emitter.tokens[comma].is_punctuation(.comma)) return false;

    const declared = declares_comma(emitter, name) orelse return false;
    if (declared != comma) return false;
    if (!emitter.policy.declare_lines) return false;
    if (!line.statement_level(emitter)) return false;

    const found = edge.statement_head(emitter, comma) orelse return false;
    const head = if (emitter.tokens[found].kind == .comment) line.coding(emitter, found) else found;
    const coded = head orelse return false;
    if (binder_of(emitter, coded) == null) return false;
    return opens_a_declarator(emitter, comma);
}

pub fn sequence_wrapped_item(emitter: *const Emitter, prior: u32) bool {
    assert(prior < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.sequence_lines) return false;
    if (!sequence_wrapped(emitter)) return false;

    const close = emitter.wrapped[wrap.run_top(emitter)].close;
    const head = edge.statement_head(emitter, prior) orelse prior;
    const stop = @min(close, emitter.count -| 1);
    var depth: u32 = 0;
    var scan = head;

    while (scan <= stop) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const opened = walk.is_open(kind) or spans_open(emitter, scan);

        if (opened) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (sequence_comma_flat(emitter, scan)) return true;
        } else {}
    }

    return false;
}

fn sequence_comma_flat(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[scan].is_punctuation(.comma)) return false;
    return emitter.brackets.angles_at(scan) == 0;
}

pub fn bound_pattern(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    var held = close;
    var steps: u32 = 0;

    while (steps < bound_chain_max) : (steps += 1) {
        switch (bound_pattern_step(emitter, held)) {
            .verdict => |verdict| return verdict,
            .chained => |chained| {
                assert(chained > held);

                held = chained;
            },
        }
    }

    unreachable;
}

fn bound_pattern_step(emitter: *const Emitter, close: u32) Bound {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const after = emit.ahead_of(emitter, close) orelse return .{ .verdict = false };
    const token = emitter.tokens[after];
    const text = token.text(emitter.source);

    if (token.kind == .block_start) return .{ .verdict = true };
    if (token.is_punctuation(.assign)) return .{ .verdict = true };
    if (token.is_punctuation(.colon)) return .{ .verdict = true };
    if (walk.text_is(text, "=>")) return .{ .verdict = true };
    if (word_listed(&iterate_words, text)) return .{ .verdict = true };
    if (emitter.tokens[close].is_punctuation(.paren_close)) return .{ .verdict = false };

    const listed = token.is_punctuation(.comma) or token.is_punctuation(.paren_close);
    if (!listed) return .{ .verdict = false };

    const closed = bound_pattern_closed(emitter, after) orelse return .{ .verdict = false };
    return .{ .chained = closed };
}

fn bound_pattern_closed(emitter: *const Emitter, after: u32) ?u32 {
    assert(after < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.tokens[after].is_punctuation(.paren_close)) {
        if (param_closed(emitter, after)) return after;
    }

    return frame_close(emitter, after);
}

fn frame_close(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    var depth = emitter.depth;

    while (depth > 0) : (depth -= 1) {
        const frame = emitter.nest[depth - 1];
        if (frame.close > position) return frame.close;
    }

    return null;
}

fn param_closed(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.brackets.open_of(close)) |open| {
        if (split.headed(emitter, open)) return false;
    }

    const held = emit.ahead_of(emitter, close) orelse return false;

    assert(held > close);

    if (!emitter.tokens[held].is_punctuation(.colon)) return true;

    const enclosing = enclosing_open(emitter, held) orelse 0;
    return !tern.ternary_within(emitter, held, enclosing);
}

pub fn pattern_complex(emitter: *const Emitter, open: u32, close: u32, defaults: bool) bool {
    assert(open < close);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var named = false;
    var properties: u32 = 1;
    var scan = open + 1;

    if (ahead_is(emitter, open, close)) return false;

    while (scan < close) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const opened = walk.is_open(kind) or kind == .block_start;
        const closed = walk.is_close(kind) or kind == .block_end;

        if (opened) {
            depth += 1;
        } else if (closed) {
            depth -|= 1;
        } else if (depth == 0) {
            if (emitter.tokens[scan].is_punctuation(.comma)) {
                properties += @intFromBool(!ahead_is(emitter, scan, close));
            } else if (pattern_named(emitter, scan, defaults)) {
                named = true;
            } else {}
        } else {}
    }

    if (!named) return false;
    return properties > 2;
}

fn pattern_named(emitter: *const Emitter, scan: u32, defaults: bool) bool {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[scan];
    if (token.is_punctuation(.colon)) return true;
    if (!defaults) return false;
    return walk.text_is(token.text(emitter.source), "=");
}

pub fn comment_stripped(emitter: *const Emitter, head: u32, stop: u32) u32 {
    assert(emitter.count == emitter.tokens.len);
    assert(emitter.depth <= brace.nest_depth_max);
    assert(head < emitter.count);
    assert(stop <= emitter.count);

    var end = stop;

    while (end > head) {
        const token = emitter.tokens[end];
        if (token.kind != .comment) break;
        if (!std.mem.startsWith(u8, token.text(emitter.source), "//")) break;

        const before = emit.back_of(emitter, end) orelse break;

        assert(before < end);

        if (before < head) break;

        end = before;
    }

    assert(end <= stop);

    return end;
}

pub fn sequence_seated_run(emitter: *const Emitter, open: u32, head: u32) bool {
    assert(open < emitter.count);
    assert(head < emitter.count);

    const before = emit.back_of(emitter, head) orelse return false;
    if (before != open) return false;
    if (!sequence_spread(emitter, open)) return false;
    if (list.arrow_sequenced(emitter, open)) return false;

    const held = emit.back_of(emitter, open) orelse return true;
    return !line.word_is(emitter, held, &jump_values);
}

pub fn sequence_seated(emitter: *const Emitter, head: u32) ?Seat {
    assert(head < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (sequence_owed(emitter, head)) |open| {
        return .{ open, sequence_owed_level(emitter, open), false };
    }

    if (sequence_operand(emitter, head)) |operand| return .{ operand[0], operand[1], true };
    if (sequence_arrowed_level(emitter, head)) |level| return .{ head, level, true };

    const before, const level = sequence_branch(emitter, head) orelse return null;
    if (sequence_branch_led(emitter, before)) |led| return .{ before, led, true };
    return .{ before, level, false };
}

fn sequence_branch_led(emitter: *const Emitter, mark: u32) ?u32 {
    assert(mark < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (line.at(emitter, mark)) |seat| {
        if (seat.start - 1 == mark) return link.line_led(emitter, mark);
    }

    const head = tern.ternary_test(emitter, mark);
    const seat = line.at(emitter, head) orelse return null;
    var nested: u32 = 0;

    for (0..emitter.wraps_owed) |index| {
        if (sequence_branch_nests(emitter, @intCast(index), seat.start, mark)) nested += 1;
    }

    const level = link.line_led(emitter, head) orelse return null;
    const returned = level + @max(nested, 1);

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn sequence_branch_nests(emitter: *const Emitter, index: u32, start: u32, mark: u32) bool {
    assert(index < emitter.wraps_owed);
    assert(mark < emitter.count);
    assert(start < emitter.count);

    const held = &emitter.wrapped[index];

    const kinded = switch (held.wrap) {
        .guarded, .nested, .ternary, .parens => true,
        else => false,
    };

    if (!kinded) return false;
    if (held.start + 1 < start) return false;
    if (held.start > mark) return false;
    return mark <= held.close;
}

fn sequence_branch_aligns(emitter: *const Emitter, head: u32) u32 {
    assert(head < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (sequence_owed(emitter, head) != null) return 0;
    if (sequence_arrowed_level(emitter, head) != null) return 0;
    if (sequence_operand(emitter, head) != null) return sequence_operand_aligns(emitter, head);

    const outside = lead.ternary_align_columns(emitter);
    const mark, _ = sequence_branch(emitter, head) orelse return outside;

    return lead.ternary_align_outside(emitter, mark);
}

fn sequence_branch(emitter: *const Emitter, head: u32) ?struct { u32, u32 } {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = head;

    for (0..sequence_branch_max) |_| {
        const before = emit.back_of(emitter, scan) orelse return null;

        assert(before < scan);

        if (sequence_branch_mark(emitter, before)) return .{ before, emitter.printed + 1 };
        if (!emitter.tokens[before].is_punctuation(.paren_open)) return null;

        scan = before;
    }

    return null;
}

fn sequence_branch_mark(emitter: *const Emitter, before: u32) bool {
    assert(before < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const text = emitter.tokens[before].text(emitter.source);
    if (walk.text_is(text, "?")) return !tern.optional(emitter, before);
    if (!walk.text_is(text, ":")) return false;
    if (split.armed(emitter, before)) return false;
    return !body.returned(emitter, before);
}

fn sequence_owed_level(emitter: *const Emitter, open: u32) u32 {
    assert(open < emitter.count);
    assert(emitter.owed > 0);

    return lead.leveled_at(emitter, open) orelse emitter.printed + emitter.owed;
}

fn sequence_owed(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.owed == 0) return null;

    const open = sequence_paren_before(emitter, head) orelse return null;
    const held = emit.back_of(emitter, open) orelse return null;
    if (!emitter.tokens[held].is_punctuation(.assign)) return null;
    return open;
}

fn sequence_end(emitter: *const Emitter, comma: u32) ?u32 {
    assert(comma < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var depth: u32 = 0;

    for (comma..comma + core.define_scan_max) |index| {
        const scan: u32 = @intCast(index);
        if (scan >= emitter.count) return null;

        const kind = emitter.tokens[scan].kind;
        const opened = walk.is_open(kind) or spans_open(emitter, scan);

        if (opened) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            if (depth == 0) {
                assert(scan <= emitter.count);

                return scan;
            }

            depth -= 1;
        } else if (depth == 0) {
            if (kind.eql(.{ .punctuation = .semicolon })) {
                assert(scan <= emitter.count);

                return scan;
            }
        } else {}
    }

    return null;
}

fn binder_of(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    for (head..head + binder_lead_max) |index| {
        const scan: u32 = @intCast(index);
        if (scan >= emitter.count) return null;

        if (line.word_is(emitter, scan, emitter.policy.binder_words)) {
            assert(scan <= emitter.count);

            return scan;
        }

        if (emitter.tokens[scan].kind != .keyword) return null;
    }

    return null;
}

pub fn declares_a_value(emitter: *const Emitter, binder: u32) bool {
    assert(binder < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var depth: u32 = 0;

    for (binder + 1..binder + 1 + core.define_scan_max) |index| {
        const scan: u32 = @intCast(index);
        if (scan >= emitter.count) return false;

        const kind = emitter.tokens[scan].kind;
        const opened = spans_open(emitter, scan) or walk.is_open(kind);

        if (opened) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            if (depth == 0) return false;

            depth -= 1;
        } else if (depth == 0) {
            if (kind.eql(.{ .punctuation = .semicolon })) return false;
            if (kind.eql(.{ .punctuation = .assign })) return true;
        } else {}
    }

    return false;
}
