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
const edge = @import("edge.zig");
const emit = @import("emit.zig");
const header = @import("header.zig");
const heritage = @import("heritage.zig");
const items = @import("items.zig");
const join = @import("join.zig");
const jsx = @import("jsx.zig");
const key = @import("key.zig");
const line = @import("line.zig");
const link = @import("link.zig");
const list = @import("list.zig");
const own = @import("own.zig");
const semi = @import("semi.zig");
const sole = @import("sole.zig");
const space = @import("space.zig");
const span = @import("span.zig");
const tern = @import("tern.zig");
const tmpl = @import("tmpl.zig");
const unite = @import("unite.zig");
const walk = @import("../walk.zig");
const wide = @import("wide.zig");
const wrap = @import("wrap.zig");
const Emitter = core.Emitter;

const ValueElement = struct {
    end: u32,
    start: u32,
};

const ValueItem = enum {
    comment,
    delimiter,
    element,
    joined,
};

const ValueTally = struct {
    count: u32,
    delimited: bool,
    group_count: u32,
    group_size: u32,
    group_size_max: u32,
    items: u32,
    lined: bool,
    size: u32,
};

const Valued = struct {
    colon: u32,
    lined: bool,
};

const align_words: []const []const u8 = &.{"align"};
const labeled_words: []const []const u8 = &.{ "for", "inline", "switch", "while" };

pub fn wanted(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const previous = emitter.previous orelse return false;

    assert(previous < position);

    if (jsx.split(emitter, position, previous)) |held| return held;
    if (items.item_split(emitter, position, previous)) |held| return held;
    if (split_holed(emitter, position, previous)) |held| return held;
    if (header_commented(emitter, position, previous)) return true;
    if (split_commented(emitter, position, previous)) |held| return held;
    if (split_casted(emitter, position, previous)) |held| return held;
    if (split_trailed(emitter, position, previous)) |held| return held;
    if (header.arrow_split(emitter, position, previous)) |held| return held;
    if (split_angled(emitter, position, previous)) |held| return held;
    if (own.assign_chain_declared(emitter, previous)) return true;
    if (split_broken(emitter, position, previous)) return true;
    if (split_parted(emitter, position, previous)) |held| return held;
    if (split_joined(emitter, position, previous)) return false;
    if (join.mixed_filled(emitter, position)) |held| return held;
    if (emit.parts_role(emitter, position, previous)) return true;
    if (span.owned_break(emitter, position)) return true;
    if (emptied(emitter, position, previous)) |held| return held;
    if (edge.bodied(emitter, position, previous)) return true;
    if (arm_broken(emitter, position, previous)) return true;

    if (emitter.policy.brace_parts) {
        if (parted(emitter, position, previous)) return true;

        const commented = emitter.tokens[position].kind == .comment or
            emitter.tokens[previous].kind == .comment;

        if (!commented) {
            const layout = value_kept(emitter, position) orelse return false;
            if (previous == layout.colon) return layout.lined;
        }
    }

    if (emit.breaks(emitter, position, previous)) return true;
    if (edge.follows_a_brace(emitter, position, previous)) return false;
    if (semicolon_joined(emitter, position, previous)) return false;
    if (comma_joined(emitter, position, previous)) return false;
    return split_sourced(emitter, position, previous);
}

fn header_commented(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (!emitter.policy.chain_simples) return false;
    if (!emitter.tokens[previous].is_punctuation(.paren_close)) return false;
    if (!std.mem.startsWith(u8, emitter.tokens[position].text(emitter.source), "//")) return false;

    const open = emitter.brackets.open_of(previous) orelse return false;
    if (!headed(emitter, open)) return false;

    const word = emit.word_before(emitter, open) orelse return false;
    const looped = line.word_is(emitter, word, &.{ "if", "while" });
    if (!looped) return false;

    const statement = emit.ahead_of(emitter, position) orelse return false;
    return emitter.tokens[statement].kind != .block_start;
}

fn split_holed(emitter: *const Emitter, position: u32, previous: u32) ?bool {
    assert(position < emitter.count);
    assert(previous < position);

    const templated = tmpl.holed(emitter) or tmpl.template_piece(emitter, position);

    if (templated) {
        if (tmpl.template_piece(emitter, position)) return false;
        return span.chain_broken(emitter, position);
    }

    if (walk.substituting(emitter.source, emitter.tokens[previous])) return false;

    if (unite.intersect_led(emitter, position)) {
        if (!emit.comment_ended(emitter, previous)) return false;
    }

    return null;
}

fn split_commented(emitter: *const Emitter, position: u32, previous: u32) ?bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (emitter.policy.chain_simples) {
        if (emit.is_dot(emitter, previous)) {
            if (emitter.tokens[position].kind != .comment) return false;
        }
    }

    const operand = span.comment_operand(emitter, position, previous) or
        comment.keyword_commented(emitter, position, previous);

    if (operand) return false;

    if (emitter.comment_moved) |moved| {
        if (moved.open == previous) return false;
    }

    const opening = emit.comment_opening(emitter, position) != null or
        comment.dotted(emitter, position) != null or
        unite.annotation_comment_broken(emitter, position, previous) or
        unite.union_angle_comment_broken(emitter, position, previous);

    if (opening) return true;
    return null;
}

fn split_casted(emitter: *const Emitter, position: u32, previous: u32) ?bool {
    assert(position < emitter.count);
    assert(previous < position);

    const token = emitter.tokens[position];
    const text_previous = emitter.tokens[previous].text(emitter.source);

    if (wrap.cast_paren_edge(emitter, position, previous)) return false;
    if (emitter.comment_broke == previous) return true;

    if (emitter.wraps_ended == position) {
        if (token.is_punctuation(.comma)) return false;
        if (token.is_punctuation(.semicolon)) return false;
        if (key.cast_ended_at(emitter, position)) return false;
    }

    if (walk.text_is(text_previous, ">")) {
        if (wrap.cast_open(emitter, previous) != null) return false;
    }

    if (token.is_punctuation(.paren_open)) {
        if (std.mem.endsWith(u8, text_previous, ">")) {
            const angles_previous = emitter.brackets.angles_at(previous);
            const angles_position = emitter.brackets.angles_at(position);
            if (angles_previous > angles_position) return false;
        }
    }

    return null;
}

fn split_trailed(emitter: *const Emitter, position: u32, previous: u32) ?bool {
    assert(position < emitter.count);
    assert(previous < position);

    const kind_previous = emitter.tokens[previous].kind;

    if (emit.comment_ended(emitter, previous)) {
        if (!list.spreads(emitter)) return true;
    }

    if (emit.comment_trailing(emitter, position)) {
        if (!walk.is_open(kind_previous)) return false;
    }

    if (comment.commented_tail(emitter, position)) return !list.spreads(emitter);

    const opened = kind_previous.eql(.{ .punctuation = .bracket_open }) or
        kind_previous.eql(.{ .punctuation = .paren_open });

    if (opened) {
        if (join.closing_of(emitter, previous) == position) return false;
    }

    return null;
}

fn split_angled(emitter: *const Emitter, position: u32, previous: u32) ?bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (unite.union_angle_framed(emitter, position)) {
        if (unite.union_broken(emitter, position)) return true;
    }

    if (join.angle_commented(emitter, position, previous)) return true;

    const owned = join.angle_spread(emitter, position) or
        unite.hole_operand_owned(emitter, position) or
        jsx.chain_owned(emitter, position, previous) or
        own.arrow_chain_joined(emitter, position) or
        unite.union_cast_joined(emitter, position) or
        unite.union_paren_joined(emitter, position) or
        unite.intersect_group_joined(emitter, position);

    if (owned) return false;
    return null;
}

fn split_broken(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (split_expanded(emitter, position, previous)) return true;
    if (span.chain_broken(emitter, position)) return true;
    if (wide.lambda_hung_parted(emitter, position, previous)) return true;
    if (span.member_parted(emitter, position)) return true;
    if (link.comment_linked(emitter, position, previous)) return true;
    if (span.binary_operand_parted(emitter, position, previous)) return true;
    if (wide.bar_parted(emitter, position, previous)) return true;
    if (wide.logic_parted(emitter, position, previous)) return true;

    if (!tern.ternary_source_parted(emitter, previous, position)) {
        if (tern.ternary_forced(emitter, position)) return true;
    }

    if (tern.ternary_comment_forced(emitter, position)) return true;
    if (unite.class_decorated(emitter, position, previous)) return true;

    const claused = clause.parted(emitter, position, previous) or
        comment.commented_clause(emitter, position, previous) or
        bind.declare_headed(emitter, position, previous) or
        unite.header_conditioned(emitter, previous) or
        unite.header_operand_parted(emitter, previous) or
        unite.intersect_broken(emitter, previous);

    if (claused) return true;

    const sequenced = clause.value_parted(emitter, position, previous) or
        bind.sequence_headed(emitter, position, previous) or
        bind.sequence_broken(emitter, position, previous);

    return sequenced;
}

fn split_expanded(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (emitter.depth == 0) return false;
    if (list.spreads(emitter)) return false;

    const frame = line.frame(emitter);
    if (emit.mark_of(emitter, frame.open) & brace.mark_expanded == 0) return false;
    return span.spread_listed(emitter, position, previous);
}

fn split_parted(emitter: *const Emitter, position: u32, previous: u32) ?bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (sole.spread_parted(emitter, position, previous)) |held| return held;

    if (tern.ternary_orphan(emitter, position)) {
        if (body.parts_at(emitter, previous, position)) return true;
    }

    if (list.spreads(emitter)) {
        if (span.union_framed(emitter)) {
            if (unite.union_broken(emitter, position)) return true;
            if (unite.union_comment_broken(emitter, position, previous)) return true;
        }

        if (heritage.broken(emitter, position)) return true;
    }

    return null;
}

fn split_joined(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);
    assert(emitter.assigns <= core.assign_depth_max);

    if (list.spreads(emitter)) return true;
    if (list.returns_held(emitter)) return true;

    for (emitter.assigned[0..emitter.assigns]) |held| {
        if (held.equals == previous) return true;
    }

    const joined = own.assign_body_joined(emitter, position, previous) or
        join.arm_opened(emitter, position, previous) or
        join.define_joined(emitter, position) or
        join.root_joined(emitter, position, previous) or
        join.macro_joined(emitter, position) or
        join.mixed_joined(emitter, position) or
        join.hug_joined(emitter, position) or
        bind.binder_joined(emitter, position, previous) or
        unite.union_member_joined(emitter, previous) or
        unite.union_group_bar(emitter, position) or
        join.operand_joined(emitter, position, previous) or
        span.binary_joined(emitter, position, previous) or
        join.chain_hugged(emitter, position) or
        span.chain_flatted(emitter, position) or
        own.template_joined(emitter, previous) or
        unite.intersect_joined(emitter, previous);

    if (joined) return true;

    if (emitter.policy.chain_simples) {
        if (emit.is_dot(emitter, position)) {
            if (link.member_grouped(emitter, position)) return true;
        }
    }

    return split_fitted(emitter, position, previous);
}

fn split_fitted(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    const shaped = bind.pattern_joined(emitter, position) or
        join.sole_joined(emitter, position) or
        join.fields_joined(emitter, position) or
        join.attribute_joined(emitter, position) or
        join.arm_emptied(emitter, position, previous) or
        join.signature_joined(emitter, position, previous) or
        join.item_joined(emitter, position) or
        span.owned_join(emitter, position) or
        span.operand_snuggled(emitter, position, previous);

    if (shaped) return true;

    if (emit.wrap_headed(emitter)) {
        const chained = emit.is_dot(emitter, position) and emit.breaks(emitter, position, previous);
        if (!chained) return true;
    }

    const fitted = comment.return_joined(emitter, position, previous) or
        emit.brace_joined(emitter, position, previous) or
        emit.body_brace_joined(emitter, position, previous) or
        call.arrow_body_joined(emitter, position, previous) or
        span.header_fitted(emitter, position, previous) or
        own.value_joined(emitter, position, previous) or
        comment.binary_wrapped(emitter) or
        comment.binary_leads(emitter, position) or
        tern.ternary_parted(emitter, position) or
        tern.ternary_parted(emitter, previous) or
        call.tested_joined(emitter, position) or
        derive_added(emitter, position) or
        list.pattern_type_joined(emitter) or
        unite.declare_group_comma(emitter, previous) or
        list.loop_closed(emitter, position);

    return fitted;
}

fn split_sourced(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    const from = emitter.tokens[previous].end();
    const to = emitter.tokens[position].offset;
    if (body.parted_by(emitter, from, to) == 0) return false;

    const joined = own.assign_sourced(emitter, position, previous) or
        join.assign_joined(emitter, position, previous) or
        join.cast_joined(emitter, position, previous) or
        join.flat_joined(emitter, position) or
        join.paren_joined(emitter, position, previous) or
        join.header_joined(emitter, position, previous) or
        clause.seated_joined(emitter) or
        wrap.binary_stated_joined(emitter, position, previous) or
        header.brace_joined(emitter, position) or
        join.branch_joined(emitter, position, previous) or
        join.chain_flat(emitter, position, previous) or
        link.chain_grouped(emitter, position, previous) or
        link.chain_singled(emitter, position) or
        return_colon_joined(emitter, position, previous) or
        body.return_type_joined(emitter, position, previous) or
        wide.else_joined(emitter, position) or
        join.angle_joined(emitter, position) or
        list.mapped_joined(emitter, position, previous) or
        span.operator_leads(emitter, position) or
        join.assign_led(emitter, position) or
        call.curried_joined(emitter, position, previous) or
        sole.soled_joined(emitter, previous) or
        wide.lambda_hung_joined(emitter, position, previous) or
        unite.annotation_joined(emitter, position, previous) or
        bind.sequence_paren_joined(emitter, position, previous) or
        unite.annotation_comment_joined(emitter, position, previous) or
        items.item_glued_at(emitter, position) or
        heavy_sourced(emitter, position);

    return !joined;
}

fn heavy_sourced(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.wraps_owed == 0) return false;
    if (emitter.wrapped[emitter.wraps_owed - 1].wrap != .argued) return false;
    if (wrap.logical_tail(emitter, position)) return false;
    if (sole.soled_heavy(emitter)) return true;
    return sole.heavy_lined(emitter);
}

pub fn body_broken(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (body_commented(emitter, position, previous)) return false;
    if (emitter.tokens[previous].kind == .block_start) return body_clauses(emitter, previous);

    if (emitter.tokens[position].kind == .block_end) {
        const open = emit.opened(emitter, position) orelse return false;
        return body_clauses(emitter, open);
    }

    if (!emitter.tokens[previous].is_punctuation(.semicolon)) return false;
    if (emitter.depth == 0) return false;

    const frame = emitter.nest[emitter.depth - 1];
    if (frame.kind != .block_start) return false;
    return body_clauses(emitter, frame.open);
}

pub fn body_clauses(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.brace_bodies) return false;
    if (emit.welded_body(emitter, open)) return false;
    if (body_defining(emitter, open)) return false;
    if (braced_clauses(emitter, open)) return true;
    if (body_headed(emitter, open)) return true;
    if (control_bodied(emitter, open)) return true;
    return join.block_budgeted(emitter, open);
}

fn body_headed(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.tokens[open].kind != .block_start) return false;

    if (emit.back_of(emitter, open)) |held| {
        if (line.word_is(emitter, held, core.body_values)) return false;
    }

    if (!body_worded(emitter, open)) return false;

    const close = join.closing_of(emitter, open) orelse return false;

    assert(close > open);

    return emit.ahead_of(emitter, open) != close;
}

fn control_bodied(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.policy.brace_bodies);

    if (emitter.tokens[open].kind != .block_start) return false;

    const close = join.closing_of(emitter, open) orelse return false;
    const word = emit.back_of(emitter, open) orelse return false;
    const lead = emit.ahead_of(emitter, open) orelse return false;
    if (lead == close) return false;

    if (line.word_is(emitter, word, &.{"else"})) {
        const shut = emit.back_of(emitter, word) orelse return false;
        if (emitter.tokens[shut].kind != .block_end) return false;

        const branch = emit.opened(emitter, shut) orelse return false;
        return !join.branch_flat(emitter, branch);
    }

    if (line.word_is(emitter, word, &.{"=>"})) return line.word_is(emitter, lead, &.{"if"});
    if (line.word_is(emitter, word, core.body_values)) return false;
    if (!control_ended(emitter, word)) return false;

    const head = join.header_head(emitter, word) orelse return false;
    if (!control_owned(emitter, head, open)) return false;

    if (emit.ahead_of(emitter, close)) |after| {
        if (emitter.tokens[after].kind == .block_start) return false;
        if (line.word_is(emitter, after, &.{ ".", "=", "?", "in" })) return false;
        if (line.word_is(emitter, after, emitter.policy.continue_words)) return false;
    }

    if (line.word_is(emitter, head, &.{ "for", "while" })) return true;
    if (!line.word_is(emitter, head, &.{"if"})) return false;
    return !join.branch_flat(emitter, open);
}

fn control_ended(emitter: *const Emitter, word: u32) bool {
    assert(word < emitter.count);

    const kind = emitter.tokens[word].kind;

    return switch (kind) {
        .identifier, .keyword, .number, .string => true,
        .block_end => true,
        .punctuation => |punctuation| switch (punctuation) {
            .bracket_close, .paren_close => true,
            else => walk.text_is(emitter.tokens[word].text(emitter.source), "?"),
        },
        .block_start, .comment, .newline => false,
    };
}

fn control_owned(emitter: *const Emitter, head: u32, open: u32) bool {
    assert(head < open);
    assert(open < emitter.count);

    var depth: u32 = 0;
    var scan = head + 1;

    while (scan < open) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;

        if (depth == 0) {
            if (line.word_is(emitter, scan, &.{"=>"})) return false;
        }

        if (walk.is_open(kind)) depth += 1;
        if (!walk.is_close(kind)) continue;

        depth -|= 1;

        if (depth > 0) continue;
        if (kind != .block_end) continue;

        const after = coded_after(emitter, scan) orelse return false;
        if (control_stated(emitter, after)) return false;
    }

    return depth == 0;
}

fn coded_after(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    var scan = position + 1;

    while (scan < emitter.count) : (scan += 1) {
        const token = emitter.tokens[scan];
        if (token.length == 0) continue;
        if (token.kind == .newline) continue;
        if (token.kind == .comment) continue;
        assert(scan <= emitter.count);

        return scan;
    }

    return null;
}

fn control_stated(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const kind = emitter.tokens[position].kind;
    const worded = kind == .identifier or kind == .keyword;

    if (line.word_is(emitter, position, &.{ "as", "in" })) return false;
    return worded or line.word_is(emitter, position, &.{ "#", "$" });
}

fn scrutinee_block(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.tokens[close].kind == .block_end);

    const open = emit.opened(emitter, close) orelse return false;
    const word = emit.back_of(emitter, open) orelse return false;

    return line.word_is(emitter, word, &.{"match"});
}

fn body_worded(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.tokens[open].kind == .block_start);

    var depth: u32 = 0;
    var scan = open;

    for (0..core.type_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;
        const kind = emitter.tokens[held].kind;

        assert(held < scan);

        if (walk.is_close(kind)) {
            if (depth == 0) {
                const bodied = kind == .block_end and !scrutinee_block(emitter, held);
                if (bodied) return false;
            }

            depth += 1;
        } else if (walk.is_open(kind)) {
            if (depth == 0) return false;

            depth -= 1;
        } else if (depth == 0) {
            if (line.word_is(emitter, held, core.body_words)) return true;
            if (line.word_is(emitter, held, core.body_stops)) return false;
        } else {}

        scan = held;
    }

    return false;
}

fn body_commented(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (emitter.tokens[position].kind != .comment) return false;
    return !body.parts_at(emitter, previous, position);
}

fn arm_broken(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (arms(emitter, previous)) {
        if (arm_commented(emitter, position, previous)) return false;
        if (emitter.tokens[position].kind != .block_start) return true;
    }

    if (emitter.tokens[previous].kind == .block_end) {
        if (emit.ahead_of(emitter, previous)) |comma| {
            if (comma < position) {
                if (join.arm_dropped(emitter, comma)) return true;
            }
        }
    }

    if (!emitter.policy.body_parts) return false;
    if (!line.arming(emitter, position)) return false;

    const kind = emitter.tokens[previous].kind;
    if (kind == .block_end) return true;
    return kind.eql(.{ .punctuation = .semicolon });
}

fn arm_commented(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    var last = position;

    if (!emitter.policy.chain_simples) return false;
    if (body.parts_at(emitter, previous, position)) return false;

    for (0..emitter.count) |_| {
        const token = emitter.tokens[last];
        if (token.kind != .comment) return false;
        if (!std.mem.startsWith(u8, token.text(emitter.source), "/*")) return false;

        const after = emit.ahead_of(emitter, last) orelse return true;
        if (body.parts_at(emitter, last, after)) return true;
        if (emitter.tokens[after].kind == .block_end) return true;

        last = after;
    }

    return false;
}

pub fn valued_source(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.options.indent_width > 0);

    return value_kept(emitter, position) != null;
}

fn value_kept(emitter: *const Emitter, position: u32) ?Valued {
    assert(position < emitter.count);
    assert(emitter.options.line_width > 0);

    const valueless = emitter.policy.source_values.len == 0;

    if (valueless) {
        if (emitter.policy.value_cap == 0) return null;
    }

    const head = edge.statement_head(emitter, position) orelse return null;
    if (head == position) return null;

    assert(head < position);

    const colon = emit.ahead_of(emitter, head) orelse return null;
    if (!emitter.tokens[colon].is_punctuation(.colon)) return null;

    const tally = value_tally(emitter, colon);

    if (line.word_is(emitter, head, emitter.policy.source_values)) {
        return .{ .colon = colon, .lined = tally.lined };
    }

    if (!value_one_per_line(emitter, head, &tally)) return null;
    return .{ .colon = colon, .lined = true };
}

fn value_one_per_line(emitter: *const Emitter, head: u32, tally: *const ValueTally) bool {
    assert(head < emitter.count);
    assert(tally.group_count > 0);

    if (emitter.policy.value_cap == 0) return false;

    const custom = std.mem.startsWith(u8, emitter.tokens[head].text(emitter.source), "--");
    const grouped = tally.group_count >= 2 and tally.group_size_max >= 2;

    if (grouped) {
        if (!custom) return false;
    }

    if (!tally.delimited) return false;
    if (tally.count <= emitter.policy.value_cap) return false;
    return tally.size >= emitter.options.line_width;
}

fn value_tally(emitter: *const Emitter, colon: u32) ValueTally {
    assert(colon < emitter.count);
    assert(emitter.tokens[colon].is_punctuation(.colon));

    var tally: ValueTally = .{
        .count = 0,
        .delimited = false,
        .group_count = 1,
        .group_size = 0,
        .group_size_max = 0,
        .items = 0,
        .lined = false,
        .size = 0,
    };

    var depth: u32 = 0;
    var element: ?ValueElement = null;
    var last = emitter.tokens[colon].end();
    var scan = colon;

    for (0..core.define_scan_max) |_| {
        const held = emit.ahead_of(emitter, scan) orelse break;
        const token = emitter.tokens[held];

        assert(held > scan);

        scan = held;

        if (depth == 0) {
            if (value_stops(emitter, token)) break;

            const item = value_item(emitter, token, element, last);

            if (item != .joined) element = value_closed(&tally, element);

            switch (item) {
                .comment => continue,
                .delimiter => value_delimited(emitter, &tally, token, last),
                .element => {
                    value_led(emitter, &tally, token, last);

                    element = .{ .end = token.end(), .start = token.offset };
                },
                .joined => {},
            }
        }

        if (walk.is_open(token.kind)) depth += 1;
        if (walk.is_close(token.kind)) depth -|= 1;
        if (token.kind != .comment) last = token.end();
        if (element) |*open| open.end = last;
    }

    _ = value_closed(&tally, element);

    tally.group_size_max = @max(tally.group_size_max, tally.group_size);

    assert(tally.count <= tally.size);

    return tally;
}

fn value_stops(emitter: *const Emitter, token: Token) bool {
    assert(token.length > 0);
    assert(token.end() <= emitter.source.len);

    if (token.kind == .block_end) return true;

    const bytes = token.text(emitter.source);
    return walk.text_is(bytes, ";") or walk.text_is(bytes, "!");
}

fn value_item(emitter: *const Emitter, token: Token, element: ?ValueElement, last: u32) ValueItem {
    assert(token.length > 0);
    assert(last <= token.offset);
    if (element) |held| assert(held.start <= held.end);

    if (token.kind == .comment) return .comment;

    const bytes = token.text(emitter.source);
    const delimits = walk.text_is(bytes, ",") or walk.text_is(bytes, "/");
    if (delimits) return .delimiter;

    const open = element orelse return .element;

    assert(open.start < token.offset);

    return if (token.offset == last) .joined else .element;
}

fn value_closed(tally: *ValueTally, element: ?ValueElement) ?ValueElement {
    if (element) |held| assert(held.start <= held.end);

    const closed = element orelse return null;

    assert(closed.start < closed.end);
    assert(tally.count <= tally.size);

    const length = closed.end - closed.start;

    tally.group_size += 1;

    if (length > 1) {
        tally.count += 1;
        tally.size += length;
    }

    return null;
}

fn value_delimited(emitter: *const Emitter, tally: *ValueTally, token: Token, last: u32) void {
    assert(token.length == 1);
    assert(last <= token.offset);

    value_led(emitter, tally, token, last);

    tally.delimited = true;

    if (!walk.text_is(token.text(emitter.source), ",")) {
        tally.group_size += 1;

        return;
    }

    tally.group_size_max = @max(tally.group_size_max, tally.group_size);
    tally.group_size = 0;
    tally.group_count += 1;
}

fn value_led(emitter: *const Emitter, tally: *ValueTally, token: Token, last: u32) void {
    assert(last <= token.offset);
    assert(token.length > 0);

    if (tally.items > 0) {
        if (body.parted_by(emitter, last, token.offset) > 0) tally.lined = true;
    }

    tally.items += 1;
}

pub fn welded(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (core.memo_found(emitter, .welded, position, previous)) |answer| return answer == 1;

    const held = welded_scanned(emitter, position, previous);

    core.memo_store(emitter, .welded, position, previous, @intFromBool(held));

    return held;
}

fn welded_scanned(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    const held = emitter.tokens[previous].kind;
    const kind = emitter.tokens[position].kind;
    const brace_spaced = emitter.policy.brace_spaces;
    const block_opened = brace_spaced and held == .block_start;
    const block_closed = brace_spaced and kind == .block_end;
    const opened = walk.is_open(held) and !block_opened;
    const closed = walk.is_close(kind) and !block_closed;

    if (opened) return true;
    if (closed) return true;
    if (emit.is_dot(emitter, position)) return true;
    if (emit.is_dot(emitter, previous)) return true;
    if (tmpl.template_glued(emitter, position, previous)) return true;
    if (kind.eql(.{ .punctuation = .comma })) return true;
    return kind.eql(.{ .punctuation = .semicolon });
}

pub fn semicolon_joined(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.tokens[position].is_punctuation(.semicolon)) return false;

    const token = emitter.tokens[previous];
    const bytes = token.text(emitter.source);

    if (token.is_punctuation(.semicolon)) return false;
    if (std.mem.startsWith(u8, bytes, "//")) return false;
    if (std.mem.startsWith(u8, bytes, "\\\\")) return false;
    return std.mem.findScalar(u8, bytes, '\n') == null;
}

fn comma_joined(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (!emitter.policy.comma_joins) return false;
    if (!emitter.tokens[position].is_punctuation(.comma)) return false;

    const token = emitter.tokens[previous];
    if (token.kind == .comment) return false;
    return !std.mem.startsWith(u8, token.text(emitter.source), "\\\\");
}

pub fn broke(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from < emitter.count);
    assert(to < emitter.count);

    const end = emitter.tokens[from].end();
    const offset = emitter.tokens[to].offset;

    return body.parted_by(emitter, end, offset) > 0;
}

pub fn fields_level(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.policy.field_width == 0) return false;

    const word = emit.back_of(emitter, open) orelse return false;
    if (!line.word_is(emitter, word, emitter.policy.brace_words)) return false;
    if (fields_wide(emitter, open)) return true;

    const close = emit.closing(emitter, open) orelse return false;
    return body.parts_at(emitter, open, close);
}

fn derive_added(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (core.memo_found(emitter, .derive_added, position, 0)) |answer| return answer == 1;

    const held = join.derive_added(emitter, position);

    core.memo_store(emitter, .derive_added, position, 0, @intFromBool(held));

    return held;
}

pub fn fields_wide(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (core.memo_found(emitter, .fields_wide, open, 0)) |answer| return answer == 1;

    const held = fields_wide_scanned(emitter, open);

    core.memo_store(emitter, .fields_wide, open, 0, @intFromBool(held));

    return held;
}

fn fields_wide_scanned(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const range = fields_head(emitter, open) orelse return false;
    return wide.fields_judged(emitter, range);
}

pub fn fields_head(emitter: *const Emitter, open: u32) ?wide.FieldRange {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.policy.field_width == 0) return null;

    const word = emit.back_of(emitter, open) orelse return null;
    if (!line.word_is(emitter, word, emitter.policy.brace_words)) return null;

    const close = emit.closing(emitter, open) orelse return null;
    const first = emit.ahead_of(emitter, open) orelse return null;
    if (first == close) return null;

    const from = emitter.tokens[open].end();
    const to = emitter.tokens[close].offset;
    if (body.parted_by(emitter, from, to) > 0) return null;

    const last = emit.back_of(emitter, close) orelse first;

    assert(first > open);
    assert(close > open);

    return .{ .first = first, .last = last };
}

fn return_colon_joined(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (!emitter.policy.chain_simples) return false;
    if (!emitter.tokens[position].is_punctuation(.colon)) return false;
    if (!emitter.tokens[previous].is_punctuation(.paren_close)) return false;
    if (tern.ternary(emitter, position)) return false;
    return !arms(emitter, position);
}

pub fn arms(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.body_parts) return false;
    if (!emitter.tokens[position].is_punctuation(.colon)) return false;
    return armed(emitter, position);
}

pub fn armed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    var depth: u32 = 0;
    var scan = position;

    while (scan > 0) {
        scan -= 1;

        assert(scan < position);
        assert(depth <= position);

        const token = emitter.tokens[scan];

        if (walk.is_close(token.kind)) {
            const open = if (depth == 0) emitter.brackets.open_of(scan) else null;

            if (open) |held| {
                scan = held;

                continue;
            }

            depth += 1;

            continue;
        }

        const opening = walk.is_open(token.kind) or walk.substituting(emitter.source, token);

        if (opening) {
            if (depth == 0) return false;

            depth -= 1;

            continue;
        }

        if (depth > 0) continue;
        if (token.kind == .comment) continue;

        const word = emit.word_before(emitter, scan);
        const reached = if (word) |held| emit.is_dot(emitter, held) else false;
        const clause_armed = !reached and line.word_is(emitter, scan, emitter.policy.clause_words);

        if (clause_armed) {
            if (emitter.policy.chain_simples) {
                if (!own.switch_framed(emitter, scan)) return false;
            }

            return armed_clause(emitter, scan);
        }

        if (armed_stopped(emitter, token)) return false;
    }

    return false;
}

fn armed_clause(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.policy.clause_words.len > 0);

    const word = emit.word_before(emitter, scan) orelse return true;
    const before = coded_at(emitter, word) orelse return true;
    const kind = emitter.tokens[before].kind;
    if (kind == .block_end) return true;
    if (kind.eql(.{ .punctuation = .colon })) return true;
    if (kind.eql(.{ .punctuation = .semicolon })) return true;
    if (kind != .block_start) return false;

    const held = emit.word_before(emitter, before) orelse return false;
    return emitter.tokens[held].is_punctuation(.paren_close);
}

fn armed_stopped(emitter: *const Emitter, token: Token) bool {
    assert(!walk.is_open(token.kind));
    assert(!walk.is_close(token.kind));

    const bytes = token.text(emitter.source);

    if (token.kind == .keyword) {
        if (!word_listed(&core.arm_operands, bytes)) return true;
    }

    if (token.is_punctuation(.colon)) return true;
    if (token.is_punctuation(.comma)) return true;
    if (token.is_punctuation(.semicolon)) return true;
    return walk.text_is(bytes, "?");
}

pub fn separated(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.comma.length == 1);
    assert(emitter.semicolon.length == 1);

    const open = emitter.brackets.open_of(position);
    const patterned = if (open) |held| list.pattern_separated(emitter, held) else false;

    const typed = (emitter.typed and !patterned) or
        span.typed_brace(emitter, position) or
        span.type_closed(emitter, position) or
        emit.branch_tailed(emitter, position) or
        emit.jump_tailed(emitter, position);

    const terminated = typed and emitter.tokens[position].kind == .block_end;
    const held = if (terminated) emitter.semicolon else emitter.comma;

    try emitter.document.push(.{ .text = .{ .source = .literal, .span = held } });
}

fn fields_separator(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.policy.field_width == 0) return false;
    if (emitter.depth == 0) return false;
    if (!emitter.tokens[position].is_punctuation(.semicolon)) return false;

    const frame = line.frame(emitter);
    if (frame.kind != .block_start) return false;

    const word = emit.back_of(emitter, frame.open) orelse return false;
    if (!line.word_is(emitter, word, emitter.policy.brace_words)) return false;
    if (fields_wide(emitter, frame.open)) return true;
    return emit.ahead_of(emitter, position) == emit.closing(emitter, frame.open);
}

pub fn dropped(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (jsx.jsxing(emitter, position)) return false;
    if (semi.empty_statement(emitter, position)) return true;

    if (emitter.comment_after) |last| {
        if (position <= last) {
            if (emitter.tokens[position].kind == .comment) return true;
        }
    }

    if (emitter.comment_moved) |moved| {
        if (moved.comment == position) return true;
    }

    if (join.derive_dropped(emitter, position)) return true;
    if (span.wrap_dropped(emitter, position)) return true;

    const listed = join.arm_dropped(emitter, position) or
        join.angle_dropped(emitter, position) or
        join.angle_comma_dropped(emitter, position) or
        fields_separator(emitter, position) or
        join.flattened(emitter, position) or
        unite.union_dropped(emitter, position) or
        comment.else_commented(emitter, position);

    if (listed) return true;
    return dropped_separator(emitter, position);
}

fn dropped_separator(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const token = emitter.tokens[position];
    const separator = token.is_punctuation(.comma) or token.is_punctuation(.semicolon);
    if (!separator) return false;

    const after = emit.ahead_of(emitter, position) orelse return false;
    if (!walk.is_close(emitter.tokens[after].kind)) return false;
    if (tmpl.holed(emitter)) return true;

    if (list.spreads(emitter)) {
        if (dropped_spread(emitter, position, after)) return true;
    }

    if (wide.macro_tailed(emitter, after)) return false;

    const joined = dropped_joined(emitter, position, after);
    const dropping = emitter.policy.comma_drops or joined;
    if (!dropping) return false;
    if (!token.is_punctuation(.comma)) return false;

    const before = emit.word_before(emitter, position) orelse return false;
    const kind = emitter.tokens[before].kind;
    if (walk.is_open(kind)) return false;
    if (kind.eql(.{ .punctuation = .comma })) return false;
    if (joined) return true;
    return !body.parts_at(emitter, position, after);
}

fn dropped_spread(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position < close);
    assert(emitter.depth > 0);

    if (list.chains_a_header(emitter)) return false;

    const soled = soled_tuple(emitter, close) and !body.parts_at(emitter, position, close);
    if (soled) return false;
    if (close != emitter.nest[emitter.depth - 1].close) return false;
    return !list.hole_comma(emitter, position);
}

fn dropped_joined(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position < close);
    assert(close < emitter.count);

    if (!body.parts_at(emitter, position, close)) return false;

    const joined = join.flat_joined(emitter, close) or
        join.hug_joined(emitter, close) or
        bind.pattern_joined(emitter, close) or
        join.sole_joined(emitter, close) or
        join.fields_joined(emitter, close) or
        call.tested_joined(emitter, position);

    if (!joined) return false;
    return !soled_tuple(emitter, close);
}

fn soled_tuple(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(walk.is_close(emitter.tokens[close].kind));

    if (emitter.policy.comma_drops) return false;
    if (!emitter.tokens[close].is_punctuation(.paren_close)) return false;

    const open = emit.opened(emitter, close) orelse return false;
    if (list.calling(emitter, open)) return false;
    return wide.element_count(emitter, open, close) < 2;
}

fn clausing(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const before = emit.word_before(emitter, position) orelse return true;
    if (line.word_is(emitter, before, emitter.policy.empty_words)) return true;
    if (empty_followed(emitter, position)) return true;
    if (edge.block_stated(emitter, before)) return true;
    if (!emitter.tokens[before].is_punctuation(.paren_close)) return false;

    const open = emit.opened(emitter, before) orelse return false;
    const word = clausing_word(emitter, open) orelse return false;
    if (!line.word_is(emitter, word, emitter.policy.empty_words)) return false;
    if (list.member_worded(emitter, word)) return false;
    return !clauses_at(emitter, open, before);
}

fn clausing_word(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const held = emit.word_before(emitter, open) orelse return null;

    if (walk.text_is(emitter.tokens[held].text(emitter.source), "await")) {
        return emit.word_before(emitter, held);
    }

    return held;
}

fn empty_followed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (emitter.policy.empty_follows.len == 0) return false;

    const close = join.closing_of(emitter, position) orelse return false;
    const held = line.coding(emitter, close) orelse return false;

    return line.word_is(emitter, held, emitter.policy.empty_follows);
}

fn clauses_at(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        if (emitter.tokens[scan].is_punctuation(.semicolon)) return true;
    }

    return false;
}

fn accessor_word(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!line.word_is(emitter, previous, &core.accessor_words)) return false;

    const held = emit.back_of(emitter, previous) orelse return true;
    return !emit.is_dot(emitter, held);
}

pub fn emptied(emitter: *const Emitter, position: u32, previous: u32) ?bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (emitter.tokens[position].kind != .block_end) return null;
    if (emitter.tokens[previous].kind != .block_start) return null;
    if (emitter.policy.empty_joins) return empty_opened(emitter, position, previous);
    if (emitter.policy.empty_words.len == 0) return null;
    return clausing(emitter, previous);
}

fn empty_opened(emitter: *const Emitter, close: u32, open: u32) ?bool {
    assert(open < close);
    assert(close < emitter.count);

    const lined = join.header_width(emitter, emitter.line_first, open) orelse return null;
    const current = line.at(emitter, emitter.line_first);
    const level = if (current) |held| held.level else emitter.printed;
    const under = level * emitter.options.indent_width;
    if (under + lined + 1 > emitter.options.line_width) return null;

    if (emit.ahead_of(emitter, close)) |after| {
        if (walk.text_is(emitter.tokens[after].text(emitter.source), "else")) return true;
    }

    const before = emit.back_of(emitter, open) orelse return false;
    if (walk.text_is(emitter.tokens[before].text(emitter.source), "else")) return true;
    if (emitter.line_first != open) return false;
    return join.header_head(emitter, before) == null;
}

fn comma_parted(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    const token = emitter.tokens[position];
    const closing = token.is_punctuation(.bracket_close) or token.is_punctuation(.paren_close);
    if (!closing) return false;

    const open = emitter.brackets.open_of(position) orelse return false;

    if (!emitter.policy.comma_parts) return false;
    if (wide.element_count(emitter, open, position) <= 1) return false;
    if (!sole.listed(emitter, position)) return false;
    if (wide.attribute_head(emitter) != null) return false;
    if (!body.parts_at(emitter, previous, position)) return false;
    return wanted(emitter, position);
}

pub fn added(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (jsx.jsxing(emitter, position)) return false;
    if (tmpl.holed(emitter)) return false;
    if (added_hole(emitter)) return false;
    if (derive_added(emitter, position)) return true;
    if (items.item_comma(emitter, position)) return true;
    if (emit.branch_tailed(emitter, position)) return true;
    if (emit.jump_tailed(emitter, position)) return true;
    if (list.spreads(emitter)) return false;
    if (list.returns_held(emitter)) return false;

    const token = emitter.tokens[position];
    const closing = token.kind == .block_end or token.closes_a_group();
    if (!closing) return false;
    if (list.paren_type_led(emitter, line.frame(emitter).open)) return false;
    if (call.required_alias(emitter, line.frame(emitter).open)) return false;
    if (list.mapped_key(emitter, line.frame(emitter).open)) return false;

    if (emitter.policy.arm_guards) {
        if (join.arm_commas(emitter, position)) return true;
        if (join.arm_tailed(emitter, position)) return true;
    }

    const previous = emitter.previous orelse return false;

    const listed = emitter.policy.comma_adds or
        wide.calls(emitter, position, previous) or
        wide.literals(emitter, position, previous) or
        comma_parted(emitter, position, previous);

    if (!listed) return false;
    return added_parted(emitter, position, previous);
}

fn added_hole(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return false;

    const open = line.frame(emitter).open;

    assert(open < emitter.count);

    return walk.substituting(emitter.source, emitter.tokens[open]);
}

fn added_parted(emitter: *const Emitter, position: u32, written: u32) bool {
    assert(position < emitter.count);
    assert(written < position);

    const previous = comment_trailed(emitter, written) orelse return false;
    const held = emitter.tokens[previous].kind;
    const kind = emitter.tokens[position].kind;

    assert(previous <= written);

    if (walk.is_open(held)) return false;
    if (held.eql(.{ .punctuation = .comma })) return false;

    if (kind == .block_end) {
        if (held.eql(.{ .punctuation = .semicolon })) return false;
    }

    if (span.spread_rest(emitter, position)) return false;

    const typed = emitter.typed or span.type_closed(emitter, position);
    const membered = typed and kind == .block_end;

    const parting = body.parts_at(emitter, previous, position) or
        wide.forced(emitter, position, previous) or
        span.spread_listed(emitter, position, previous) or
        (membered and edge.bodied(emitter, position, previous));

    if (!parting) return false;

    const listed = sole.listed(emitter, position) or
        membered or
        wide.literals(emitter, position, previous);

    if (!listed) return false;
    if (sole.comma_denied(emitter, position)) return false;
    if (rested(emitter, position)) return false;
    if (join.hug_joined(emitter, position)) return false;
    if (call.tested_joined(emitter, previous)) return false;
    if (bind.pattern_joined(emitter, position)) return false;
    if (wide.sole_horizontal(emitter, position)) return false;
    return !wide.invoked(emitter);
}

fn comment_trailed(emitter: *const Emitter, previous: u32) ?u32 {
    assert(previous < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = previous;

    for (0..emitter.count) |_| {
        const token = emitter.tokens[scan];
        if (token.kind != .comment) return scan;

        const text = token.text(emitter.source);
        if (!std.mem.startsWith(u8, text, "/*")) return null;
        if (std.mem.findScalar(u8, text, '\n') != null) return null;

        const before = emit.back_of(emitter, scan) orelse return null;
        if (body.parts_at(emitter, before, scan)) return null;

        scan = before;
    }

    return null;
}

fn rested(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    return bind.rested_run(emitter, position);
}

pub fn specifier_open(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.chain_simples) return false;
    if (emitter.tokens[open].kind != .block_start) return false;

    const word = emit.word_before(emitter, open) orelse return false;
    const bytes = emitter.tokens[word].text(emitter.source);
    if (walk.text_is(bytes, "export")) return true;
    if (walk.text_is(bytes, "import")) return true;
    if (!walk.text_is(bytes, "type")) return false;

    const held = emit.word_before(emitter, word) orelse return false;
    const before = emitter.tokens[held].text(emitter.source);
    if (walk.text_is(before, "export")) return true;
    return walk.text_is(before, "import");
}

pub fn headed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (core.memo_found(emitter, .headed, position, 0)) |answer| return answer == 1;

    const held = headed_scanned(emitter, position);

    core.memo_store(emitter, .headed, position, 0, @intFromBool(held));

    return held;
}

fn headed_scanned(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const answer = edge.statement_evaluated(emitter, .{ .headed = .{ .position = position } });
    return answer.verdict;
}

pub fn headed_step(
    emitter: *const Emitter,
    frame: *edge.Headed,
    answer: ?edge.StatementAnswer,
) edge.StatementStep {
    assert(frame.position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);
    if (answer) |held| assert(held == .verdict);

    if (answer) |member| return .{ .done = .{ .verdict = !member.verdict } };

    const missed: edge.StatementStep = .{ .done = .{ .verdict = false } };
    if (!emitter.policy.header_parens) return missed;

    const word = emit.word_before(emitter, frame.position) orelse return missed;
    const held = line.loop_awaited(emitter, word) orelse word;
    if (!line.word_is(emitter, held, emitter.policy.header_words)) return missed;
    return .{ .call = edge.statement_member_frame(emitter, held) };
}

pub fn carries(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.comment_carries) return false;
    if (emitter.tokens[position].kind != .comment) return false;
    if (!emitter.continued) return false;

    const below = line.coding(emitter, position) orelse return true;

    assert(below > position);

    if (emitter.tokens[below].kind == .block_end) return false;
    return line.column_of(emitter, position) > line.column_of(emitter, below);
}

pub fn apart(emitter: *const Emitter, position: u32) u32 {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.policy.declare_words.len == 0) return 0;
    if (emitter.depth > 0) return 0;
    if (carries(emitter, position)) return 0;

    const word = declaring(emitter, position) orelse return 0;

    assert(word >= position);

    if (word == position) {
        if (documented(emitter, position)) return 0;
    }

    const held = emitter.tokens[word].text(emitter.source);

    const changed = if (emitter.declared) |before|
        !walk.text_eql(emitter.tokens[before].text(emitter.source), held)
    else
        true;

    if (changed) return 1;
    if (word == position) return 0;
    return @intFromBool(documented(emitter, word));
}

fn declaring(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.policy.declare_words.len > 0);

    if (line.word_is(emitter, position, emitter.policy.declare_words)) return position;
    if (emitter.tokens[position].kind != .comment) return null;
    if (documented(emitter, position)) return null;

    var scan = position;

    while (emitter.tokens[scan].kind == .comment) {
        const held = emit.ahead_of(emitter, scan) orelse return null;

        assert(held > scan);

        scan = held;
    }

    if (!line.word_is(emitter, scan, emitter.policy.declare_words)) return null;
    return scan;
}

fn documented(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const before = emit.word_before(emitter, position) orelse return false;

    assert(before < position);

    if (emitter.tokens[before].kind != .comment) return false;

    const from = emitter.tokens[before].end();
    const to = emitter.tokens[position].offset;

    return body.parted_by(emitter, from, to) <= 1;
}

pub fn spaced(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.previous) |held| {
        if (emptied(emitter, position, held) == false) return false;
        if (optional_marked(emitter, position, held)) return false;
    }

    const decision = decided(emitter, position);

    const exempt = if (emitter.previous) |held|
        emit.glue_exempt(emitter, held, position)
    else
        false;

    const joinable = !decision and !emitter.glued and !exempt;

    if (joinable) {
        if (joins(emitter, position)) return true;
    }

    return decision;
}

fn optional_marked(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(previous < position);
    assert(position < emitter.count);

    if (!walk.text_is(emitter.tokens[position].text(emitter.source), "?")) return false;

    const held = emitter.tokens[previous];

    const named = switch (held.kind) {
        .identifier, .keyword, .number, .string => true,
        else => held.is_punctuation(.bracket_close),
    };

    if (!named) return false;
    return tern.optional(emitter, position);
}

fn joins(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const previous = emitter.previous orelse return false;

    assert(previous < position);

    if (emit.roled(emitter, previous, brace.role_jsx_hole)) return false;
    if (emit.roled(emitter, position, brace.role_jsx_hole)) return false;
    if (tmpl.template_closes(emitter, position)) return false;

    const held = emitter.tokens[previous];
    const token = emitter.tokens[position];

    if (emitter.policy.chain_simples) {
        if (token.is_punctuation(.colon)) return false;
    }

    if (emitter.policy.align_colons) {
        if (aligned_colon(emitter, position, previous)) return false;
    }

    if (emitter.policy.asm_operands) {
        if (assembly.asm_colons_tight(emitter, position, previous)) return false;
    }

    if (token.is_punctuation(.comma)) return false;
    if (token.is_punctuation(.semicolon)) return false;
    if (emptied_pair(emitter, position, previous)) return false;
    if (joins_tight(emitter, position, previous)) return false;
    if (join.angle_tight(emitter, position, previous)) return false;
    if (angle_parenthesized(emitter, position, previous)) return false;

    if (emitter.policy.chain_simples) {
        if (token.closes_a_group()) return false;
        if (held.opens_a_group()) return false;
    }

    if (joins_hugged(emitter, position, previous)) return false;

    if (token.is_punctuation(.bracket_open)) {
        if (jsx.jsxing(emitter, previous)) return false;
    }

    const broken = welded(emitter, position, previous) and
        join.joins_a_break(emitter, position, previous);

    if (broken) return false;
    if (join.arm_emptied(emitter, position, previous)) return false;
    if (join.joined_dot(emitter, position, previous)) return false;

    if (emitter.policy.chain_simples) {
        if (emit.is_dot(emitter, position)) return false;
    }

    if (join.called_gap(emitter, position, previous)) return false;

    if (walk.is_open(token.kind)) {
        if (walk.text_is(held.text(emitter.source), "...")) return false;
    }

    if (wide.lambda_hung_joined(emitter, position, previous)) return false;
    if (bang_called(emitter, position, previous)) return false;
    if (!walk.punctuated(held.kind)) return false;
    if (!walk.punctuated(token.kind)) return false;
    return held.end() < token.offset;
}

fn bang_called(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    const token = emitter.tokens[position];
    const opening = token.is_punctuation(.paren_open) or token.is_punctuation(.bracket_open);
    if (!opening) return false;
    if (previous == 0) return false;
    return bang_glued(emitter, previous, previous - 1);
}

fn joins_tight(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    const tight = emitter.policy.tight_words;
    if (line.word_is(emitter, previous, tight)) return true;
    if (!walk.text_is(emitter.tokens[previous].text(emitter.source), "!")) return false;
    if (!emitter.tokens[position].is_punctuation(.bracket_open)) return false;

    const held = emit.back_of(emitter, previous) orelse return false;
    return line.word_is(emitter, held, tight);
}

fn emptied_pair(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    const held = emitter.tokens[previous];
    const opened = held.is_punctuation(.paren_open) or held.is_punctuation(.bracket_open);
    if (!opened) return false;
    return emitter.brackets.close_of(previous) == position;
}

fn joins_hugged(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    const held = emitter.tokens[previous].kind;
    const kind = emitter.tokens[position].kind;
    const edged = walk.is_close(kind) or walk.is_open(held);

    const settled = emitter.policy.brace_parts or list.spreads(emitter) or
        call.tested_joined(emitter, position);

    if (settled) {
        if (edged) return true;
    }

    if (emitter.policy.sole_hugs) {
        if (edged) return true;
    }

    if (!emitter.policy.close_hugs) return false;

    const shut = held == .block_end or held.eql(.{ .punctuation = .bracket_close });
    if (!shut) return false;
    if (walk.is_close(kind)) return true;
    if (!walk.is_open(kind)) return false;
    return !emit.bodied(emitter, position);
}

fn angle_parenthesized(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (!emitter.tokens[position].is_punctuation(.paren_open)) return false;

    const bytes = emitter.tokens[previous].text(emitter.source);
    if (!std.mem.endsWith(u8, bytes, ">")) return false;

    const angles_previous = emitter.brackets.angles_at(previous);
    const angles_position = emitter.brackets.angles_at(position);
    if (angles_previous <= angles_position) return false;
    if (emit.roled(emitter, previous, brace.role_spaced)) return false;
    return !impl_listed(emitter, previous);
}

fn impl_listed(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const open = tern.angle_opening(emitter, close) orelse return false;

    assert(open < close);

    const held = emit.back_of(emitter, open) orelse return false;
    return walk.text_is(emitter.tokens[held].text(emitter.source), "impl");
}

fn asserted(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    const bang_position = walk.text_is(emitter.tokens[position].text(emitter.source), "!");
    const bang_previous = walk.text_is(emitter.tokens[previous].text(emitter.source), "!");

    if (!bang_position) {
        if (!bang_previous) return false;
    }

    const bang = if (bang_position) position else previous;
    const before = emit.back_of(emitter, bang) orelse return false;
    if (emitter.tokens[before].kind != .identifier) return false;

    const after = emit.ahead_of(emitter, bang) orelse return false;
    return emitter.tokens[after].is_punctuation(.colon);
}

fn roled_pair(emitter: *const Emitter, position: u32, previous: u32) ?bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (emit.roled(emitter, position, brace.role_tight)) return false;
    if (emit.roled(emitter, previous, brace.role_tight)) return false;

    const spaced_position = emit.roled(emitter, position, brace.role_spaced);
    const spaced_previous = emit.roled(emitter, previous, brace.role_spaced);
    const spaced_either = spaced_position or spaced_previous;
    const spaced_both = spaced_position and spaced_previous;

    if (!spaced_either) return null;

    if (spaced_both) {
        if (emitter.tokens[previous].end() == emitter.tokens[position].offset) return false;
    }

    return true;
}

fn marked(emitter: *const Emitter, position: u32, previous: u32) ?bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (tern.ternaried(emitter, position, previous)) return true;
    if (labelled(emitter, position, previous)) return true;

    if (previous > 0) {
        if (labelled(emitter, previous, previous - 1)) return false;
    }

    if (previous > 1) {
        if (labelled(emitter, previous - 1, previous - 2)) {
            const kind = emitter.tokens[position].kind;
            const shut = walk.is_close(kind) and kind != .block_end;
            if (shut) return false;
            if (kind.eql(.{ .punctuation = .comma })) return false;
            if (kind.eql(.{ .punctuation = .semicolon })) return false;
            return !kind.eql(.{ .punctuation = .colon });
        }
    }

    return null;
}

fn bang_glued(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    const held = emitter.tokens[position];
    if (!walk.text_is(held.text(emitter.source), "!")) return false;
    if (emitter.tokens[previous].end() != held.offset) return false;
    return emit.operand_at(emitter, previous);
}

fn dotted(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    const held = emitter.tokens[previous];

    if (held.kind == .number) {
        if (number_indexed(emitter, previous)) return false;
        return held.end() < emitter.tokens[position].offset;
    }

    if (held.kind == .block_end) return false;

    if (emitter.policy.hug_lasts) {
        if (held.kind == .keyword) return false;
    }

    if (previous > 0) {
        if (bang_glued(emitter, previous, previous - 1)) return false;
    }

    if (emit.operand_at(emitter, previous)) return false;
    if (closes_a_value(emitter, previous)) return false;
    if (emit.is_dot(emitter, previous)) return false;
    return !line.word_is(emitter, previous, emitter.policy.hug_words);
}

pub fn number_indexed(emitter: *const Emitter, number: u32) bool {
    assert(number < emitter.count);
    assert(emitter.tokens[number].kind == .number);

    if (emitter.policy.call_width == 0) return false;

    const dot = emit.back_of(emitter, number) orelse return false;
    if (!emit.is_dot(emitter, dot)) return false;

    for (emitter.tokens[number].text(emitter.source)) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }

    return true;
}

fn opens_inside(
    emitter: *const Emitter,
    kind: Token.Kind,
    held: Token.Kind,
    frame: *const core.Frame,
) bool {
    assert(walk.is_open(held));
    if (frame.inside) assert(frame.kind == .block_start);

    if (emitter.policy.brace_pairs) {
        if (kind == .block_start) return false;
    }

    if (held != .block_start) return false;
    if (!frame.inside) return false;
    return kind != .block_end;
}

fn commented_brace(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (!emitter.policy.brace_comments) return false;
    if (!line.frame(emitter).inside) return false;

    const kind = emitter.tokens[position].kind;
    const held = emitter.tokens[previous].kind;

    if (kind == .block_end) {
        if (comment.blocked(emitter, previous)) return true;
    }

    if (held != .block_start) return false;
    return comment.blocked(emitter, position);
}

fn kept(emitter: *const Emitter, position: u32, previous: u32) ?bool {
    assert(position < emitter.count);
    assert(previous < position);

    const kind = emitter.tokens[position].kind;

    if (commented_brace(emitter, position, previous)) return true;

    if (emitter.policy.sentinel_colons) {
        if (kind.eql(.{ .punctuation = .colon })) {
            const frame = line.frame(emitter);

            const ranging = frame.kind.eql(.{ .punctuation = .bracket_open }) and
                line.ranged(emitter, frame.open, position) and
                !label_colon(emitter, position, previous);

            if (ranging) return true;
        }
    }

    if (emitter.policy.lifetime_tight) {
        const lifetime = walk.text_is(emitter.tokens[position].text(emitter.source), "'") and
            walk.text_is(emitter.tokens[previous].text(emitter.source), "&");

        if (lifetime) return false;
    }

    const blocked = comment.blocked(emitter, position) or comment.blocked(emitter, previous);

    if (blocked) {
        if (emitter.policy.comment_spaces) {
            return comment.commented_space(emitter, position, previous);
        }

        if (walk.is_close(kind)) return false;
        return emitter.tokens[previous].end() < emitter.tokens[position].offset;
    }

    return kept_tight(emitter, position, previous);
}

fn kept_tight(emitter: *const Emitter, position: u32, previous: u32) ?bool {
    assert(position < emitter.count);
    assert(previous < position);

    const token = emitter.tokens[position];
    const held = emitter.tokens[previous];
    const gap = held.end() < token.offset;

    if (line.word_is(emitter, position, emitter.policy.tight_words)) {
        if (held.kind == .keyword) return gap;
    }

    if (walk.is_open(held.kind)) {
        if (token.kind == .comment) return true;
    }

    if (previous > 0) {
        const before = emitter.tokens[previous - 1];

        const hashed = walk.text_is(held.text(emitter.source), "#") and
            before.kind == .identifier and before.end() == held.offset;

        if (hashed) return gap;
    }

    if (token.kind == .string) {
        if (line.word_is(emitter, previous, emitter.policy.tight_words)) return gap;
    }

    return null;
}

fn decided(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const previous = emitter.previous orelse return false;

    assert(previous < position);

    if (jsx.holed(emitter, previous)) return false;
    if (jsx.holed(emitter, position)) return false;
    if (emit.roled(emitter, previous, brace.role_jsx_hole)) return false;
    if (emit.roled(emitter, position, brace.role_jsx_hole)) return false;
    if (items.item_spaced_at(emitter, position)) return true;
    if (bang_glued(emitter, position, previous)) return false;

    if (emitter.policy.hole_spaces) {
        const commas = emitter.tokens[position].is_punctuation(.comma) and
            emitter.tokens[previous].is_punctuation(.comma);

        if (commas) return true;
    }

    if (emit.is_dot(emitter, position)) {
        if (emit.roled(emitter, previous, brace.role_jsx_tag)) return false;
    }

    if (emitter.tokens[position].is_punctuation(.bracket_open)) {
        if (jsx.jsxing(emitter, previous)) return false;
    }

    if (clause.header_bodied_gap(emitter, position, previous)) return true;
    if (decided_early(emitter, position, previous)) |held| return held;
    if (asserted(emitter, position, previous)) return false;
    if (angle_parenthesized(emitter, position, previous)) return false;
    if (walk.text_is(emitter.tokens[previous].text(emitter.source), "...")) return false;
    if (emitter.suppress_space) return false;
    if (emit.pointed(emitter, position)) return false;
    if (roled_pair(emitter, position, previous)) |held| return held;
    return decided_kind(emitter, position, previous);
}

fn decided_kind(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    const held = emitter.tokens[previous].kind;
    const kind = emitter.tokens[position].kind;
    const frame = line.frame(emitter);
    if (walk.is_open(held)) return opens_inside(emitter, kind, held, &frame);
    if (bang_called(emitter, position, previous)) return false;

    const membered = line.word_is(emitter, position, emitter.policy.postfix_words) or
        line.word_is(emitter, position, emitter.policy.member_words) or
        line.word_is(emitter, previous, emitter.policy.member_words);

    if (membered) return false;
    if (space.worded(emitter, position, previous)) |found| return found;
    if (marked(emitter, position, previous)) |found| return found;
    if (emit.is_dot(emitter, position)) return dotted(emitter, position, previous);
    if (decided_semicolon(emitter, position, previous, &frame)) |found| return found;

    const listed = kind.eql(.{ .punctuation = .comma }) or
        kind.eql(.{ .punctuation = .semicolon }) or
        kind.eql(.{ .punctuation = .colon });

    if (listed) return false;

    if (emit.is_dot(emitter, previous)) {
        if (!emit.spaced_dot(emitter, position, previous)) return false;
    }

    if (braced(emitter, position, previous, &frame)) |found| return found;

    const opening = kind.eql(.{ .punctuation = .bracket_open }) or
        kind.eql(.{ .punctuation = .paren_open });

    if (opening) {
        if (line.word_is(emitter, previous, emitter.policy.gap_words)) return true;
        return bracketed(emitter, position, previous);
    }

    if (emitter.policy.chain_simples) {
        if (walk.is_close(kind)) {
            if (kind != .block_end) return false;
        }
    }

    if (emit.arrow(emitter, position)) {
        if (directs(emitter, previous, position)) return false;
    }

    return true;
}

pub fn directs(emitter: *const Emitter, previous: u32, position: u32) bool {
    assert(previous < position);
    assert(position < emitter.count);

    if (!line.word_is(emitter, previous, emitter.policy.hug_words)) return false;
    return !emit.prefix_tight(emitter, position);
}

fn angle_assigned(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (!emitter.policy.chain_simples) return false;
    if (!walk.text_is(emitter.tokens[previous].text(emitter.source), ">")) return false;
    return walk.text_is(emitter.tokens[position].text(emitter.source), "=");
}

fn decided_early(emitter: *const Emitter, position: u32, previous: u32) ?bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (tmpl.template_glued(emitter, position, previous)) return false;

    if (emitter.policy.align_colons) {
        if (aligned_colon(emitter, position, previous)) return false;
    }

    if (emit.back_of(emitter, position)) |held| {
        if (held != previous) {
            if (join.angle_comma_dropped(emitter, held)) return false;
        }
    }

    if (comment.generator_star(emitter, previous)) return false;
    if (angle_assigned(emitter, position, previous)) return true;

    if (emitter.tokens[previous].is_punctuation(.semicolon)) {
        const frame = line.frame(emitter);

        if (frame.kind.eql(.{ .punctuation = .paren_open })) {
            if (comment.header_clauses(emitter, frame.open)) return true;
        }
    }

    if (comment.star_word(emitter, position)) return false;
    if (comment.star_word(emitter, previous)) return true;
    if (comment.module_star(emitter, position, previous)) return true;

    if (emitter.policy.asm_operands) {
        if (assembly.asm_spaced(emitter, position, previous)) return true;
        if (assembly.asm_colons_tight(emitter, position, previous)) return false;
    }

    if (sourced(emitter, position, previous)) |found| return found;
    return kept(emitter, position, previous);
}

fn decided_semicolon(
    emitter: *const Emitter,
    position: u32,
    previous: u32,
    frame: *const core.Frame,
) ?bool {
    assert(position < emitter.count);
    assert(previous < position);

    const held = emitter.tokens[previous].kind;

    if (!emitter.tokens[position].is_punctuation(.semicolon)) return null;

    if (held == .keyword) {
        if (emitter.policy.empty_semis) return false;
        return emitter.tokens[previous].end() < emitter.tokens[position].offset;
    }

    if (!held.eql(.{ .punctuation = .semicolon })) return null;

    const parenthesized = frame.kind.eql(.{ .punctuation = .paren_open });

    if (parenthesized) {
        if (comment.header_clauses(emitter, frame.open)) return true;
    }

    return !parenthesized;
}

fn sourced(emitter: *const Emitter, position: u32, previous: u32) ?bool {
    assert(position < emitter.count);
    assert(previous < position);

    const token = emitter.tokens[position];
    const held = emitter.tokens[previous];

    if (emitter.policy.brace_leads) {
        if (token.kind == .block_start) return true;
    }

    if (space.paired(emitter, position, previous)) |found| return found;

    if (emitter.policy.units) {
        const unit = !token.is_punctuation(.bang) and
            !line.word_is(emitter, position, emitter.policy.spaced_words) and
            held.kind == .number and
            held.end() == token.offset;

        if (unit) return false;
    }

    if (emitter.policy.comment_leads) {
        if (columned(emitter, position, previous)) return false;
    }

    if (token.kind == .comment) {
        if (walk.text_is(held.text(emitter.source), ">")) {
            if (wrap.cast_open(emitter, previous) != null) return false;
        }

        if (emitter.policy.chain_simples) {
            if (walk.text_is(held.text(emitter.source), "...")) return false;
        }
    }

    if (token.is_punctuation(.bracket_open)) {
        if (comment_indexed(emitter, previous)) return false;
    }

    if (sourced_bracket(emitter, position, previous)) return false;
    if (sourced_gap(emitter, position, previous)) |found| return found;
    if (sourced_angle(emitter, position, previous)) return false;
    if (!emitter.policy.source_gaps) return null;
    return sourced_spaced(emitter, position, previous);
}

fn columned(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(previous < position);
    assert(emitter.policy.comment_leads);

    const token = emitter.tokens[position];
    if (token.kind != .comment) return false;
    if (!std.mem.startsWith(u8, token.text(emitter.source), "/*")) return false;
    if (broke(emitter, previous, position)) return false;

    const held = line.frame(emitter);
    if (!held.kind.eql(.{ .punctuation = .paren_open })) return false;

    const word = emit.back_of(emitter, held.open) orelse return false;
    if (!line.word_is(emitter, word, emitter.policy.declare_words)) return false;

    const ahead = emit.ahead_of(emitter, position) orelse return false;

    assert(ahead > position);

    if (emitter.tokens[ahead].is_punctuation(.assign)) return false;
    if (broke(emitter, position, ahead)) return false;
    return named_run(emitter, previous);
}

fn named_run(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.line_first < emitter.count);

    var scan = position;

    while (scan > emitter.line_first) {
        const kind = emitter.tokens[scan].kind;
        const named = kind == .identifier or kind.eql(.{ .punctuation = .comma });
        if (!named) return false;

        const held = emit.back_of(emitter, scan) orelse return false;

        assert(held < scan);

        scan = held;
    }

    return emitter.tokens[scan].kind == .identifier;
}

fn sourced_spaced(emitter: *const Emitter, position: u32, previous: u32) ?bool {
    assert(previous < position);
    assert(emitter.policy.source_gaps);

    const kind = emitter.tokens[position].kind;
    if (kind == .comment) return true;

    if (emitter.tokens[previous].kind == .comment) {
        if (walk.is_close(kind)) return false;
        if (kind.eql(.{ .punctuation = .comma })) return false;
        return !kind.eql(.{ .punctuation = .semicolon });
    }

    return gapped(emitter, position, previous);
}

fn gapped(emitter: *const Emitter, position: u32, previous: u32) ?bool {
    assert(previous < position);
    assert(emitter.policy.source_gaps);

    const held = emitter.tokens[previous].kind;
    const kind = emitter.tokens[position].kind;
    if (kind == .block_start) return null;
    if (kind == .block_end) return null;
    if (held == .block_start) return null;
    if (held == .block_end) return null;
    if (walk.is_open(held)) return false;
    if (walk.is_close(kind)) return false;
    if (verbatim(emitter)) return emitter.tokens[previous].end() < emitter.tokens[position].offset;
    if (kind.eql(.{ .punctuation = .bang })) return true;
    if (held.eql(.{ .punctuation = .bang })) return false;

    const worded = line.word_is(emitter, position, emitter.policy.spaced_words) or
        line.word_is(emitter, previous, emitter.policy.spaced_words);

    if (worded) {
        if (!verbatim(emitter)) return true;
    }

    return gapped_punctuated(emitter, position, previous);
}

fn gapped_punctuated(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(previous < position);
    assert(emitter.policy.source_gaps);

    const held = emitter.tokens[previous].kind;
    const kind = emitter.tokens[position].kind;
    const gap = emitter.tokens[previous].end() < emitter.tokens[position].offset;

    if (kind.eql(.{ .punctuation = .colon })) {
        if (declares(emitter, position)) return false;
        return gap;
    }

    if (held.eql(.{ .punctuation = .colon })) {
        if (declares(emitter, previous)) return true;
        if (queries(emitter, previous)) return true;
        return gap;
    }

    if (kind.eql(.{ .punctuation = .comma })) return false;
    if (kind.eql(.{ .punctuation = .semicolon })) return false;
    if (held.eql(.{ .punctuation = .comma })) return true;
    if (held.eql(.{ .punctuation = .semicolon })) return true;
    return gap;
}

fn verbatim(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.policy.verbatim_words.len == 0) return false;

    for (emitter.nest[0..emitter.depth]) |held| {
        assert(held.open < emitter.count);

        if (!held.kind.eql(.{ .punctuation = .paren_open })) continue;

        const word = emit.back_of(emitter, held.open) orelse continue;
        if (line.word_is(emitter, word, emitter.policy.verbatim_words)) return true;
    }

    return false;
}

fn queries(emitter: *const Emitter, colon: u32) bool {
    assert(colon < emitter.count);
    assert(emitter.tokens[colon].is_punctuation(.colon));

    if (emitter.depth == 0) return false;

    const open = line.frame(emitter).open;

    if (!line.frame(emitter).kind.eql(.{ .punctuation = .paren_open })) return false;

    assert(open < colon);

    if (emit.word_before(emitter, open)) |before| {
        const named = emitter.tokens[before].kind == .identifier;

        if (named) {
            if (emitter.tokens[before].end() >= emitter.tokens[open].offset) return false;
        }
    }

    return at_rule(emitter, colon);
}

fn valued(emitter: *const Emitter, colon: u32) bool {
    assert(colon < emitter.count);
    assert(emitter.tokens[colon].is_punctuation(.colon));

    var depth: u32 = 0;
    var scan = colon + 1;

    while (scan < emitter.count) : (scan += 1) {
        switch (emitter.tokens[scan].kind) {
            .punctuation => |punctuation| switch (punctuation) {
                .bracket_open, .paren_open => depth += 1,
                .bracket_close, .paren_close => {
                    if (depth == 0) return false;

                    depth -= 1;
                },
                .semicolon => if (depth == 0) return true,
                else => {},
            },
            .block_start => if (depth == 0) return false,
            .block_end => if (depth == 0) return true,
            else => {},
        }
    }

    return false;
}

fn declares(emitter: *const Emitter, colon: u32) bool {
    assert(colon < emitter.count);
    assert(emitter.tokens[colon].is_punctuation(.colon));

    if (emitter.depth == 0) return false;
    if (colon < 2) return false;
    if (!valued(emitter, colon)) return false;
    if (emitter.tokens[colon - 1].kind != .identifier) return false;

    var scan = colon - 1;

    while (scan > 0) : (scan -= 1) {
        if (!line.word_is(emitter, scan - 1, emitter.policy.prefix_words)) break;
    }

    const word = emit.word_before(emitter, scan) orelse return false;
    const before = coded_at(emitter, word) orelse return false;
    const kind = emitter.tokens[before].kind;

    assert(before < colon);

    if (kind == .block_end) return true;
    if (kind == .block_start) return true;
    return kind.eql(.{ .punctuation = .semicolon });
}

fn parted(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(previous < position);
    assert(emitter.policy.brace_parts);

    const token = emitter.tokens[position].kind;
    const before = emitter.tokens[previous].kind;

    if (token == .block_end) return true;
    if (before == .block_start) return true;

    if (token == .comment) {
        const from = emitter.tokens[previous].end();
        const to = emitter.tokens[position].offset;
        if (body.parted_by(emitter, from, to) == 0) return false;
    }

    if (before == .comment) {
        if (token.eql(.{ .punctuation = .semicolon })) return false;
        return !emitter.commented;
    }

    if (before == .block_end) return true;
    if (before.eql(.{ .punctuation = .semicolon })) return !verbatim(emitter);
    if (!before.eql(.{ .punctuation = .comma })) return false;
    return selects(emitter, previous);
}

pub fn edges(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.policy.brace_parts);

    if (emitter.tokens[position].kind == .block_end) return true;

    const held = emitter.previous orelse return false;

    assert(held < position);

    return emitter.tokens[held].kind == .block_start;
}

fn selects(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.tokens[position].is_punctuation(.comma));

    var depth: u32 = 0;
    var scan = position + 1;

    while (scan < emitter.count) : (scan += 1) {
        switch (emitter.tokens[scan].kind) {
            .punctuation => |punctuation| switch (punctuation) {
                .bracket_open, .paren_open => depth += 1,
                .bracket_close, .paren_close => {
                    if (depth == 0) return false;

                    depth -= 1;
                },
                .semicolon => if (depth == 0) return false,
                else => {},
            },
            .block_start => if (depth == 0) return !at_rule(emitter, position),
            .block_end => if (depth == 0) return false,
            else => {},
        }
    }

    return false;
}

fn at_rule(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = position;

    while (scan > 0) : (scan -= 1) {
        const kind = emitter.tokens[scan - 1].kind;
        if (kind == .block_end) break;
        if (kind == .block_start) break;
        if (kind.eql(.{ .punctuation = .semicolon })) break;
    }

    assert(scan <= position);

    while (scan < position) : (scan += 1) {
        const token = emitter.tokens[scan];
        if (token.kind == .newline) continue;
        if (token.length == 0) continue;
        return line.word_is(emitter, scan, &.{"@"});
    }

    return false;
}

fn sourced_bracket(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    const token = emitter.tokens[position];
    const held = emitter.tokens[previous];

    if (!emitter.policy.chain_simples) return false;
    if (held.kind != .comment) return false;
    if (!std.mem.startsWith(u8, held.text(emitter.source), "/*")) return false;
    if (!token.is_punctuation(.bracket_open)) return false;
    if (held.end() != token.offset) return false;

    const before = emit.back_of(emitter, previous) orelse return false;
    if (!walk.ends_operand(emitter.tokens[before].kind)) return false;
    return !body.parts_at(emitter, before, previous);
}

fn sourced_gap(emitter: *const Emitter, position: u32, previous: u32) ?bool {
    assert(position < emitter.count);
    assert(previous < position);

    const held = emitter.tokens[previous];

    if (!emitter.policy.comment_gaps) return null;
    if (held.kind != .comment) return null;
    if (!std.mem.startsWith(u8, held.text(emitter.source), "/*")) return null;

    const before = emit.back_of(emitter, previous);
    const opened = if (before) |found| walk.is_open(emitter.tokens[found].kind) else false;
    const kind = emitter.tokens[position].kind;
    if (kind.eql(.{ .punctuation = .comma })) return false;
    if (kind.eql(.{ .punctuation = .semicolon })) return false;

    const bodied = kind == .block_end and emit.bodied(emitter, line.frame(emitter).open);

    if (!walk.is_close(kind)) return true;
    if (opened) return true;
    return bodied;
}

fn sourced_angle(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    const token = emitter.tokens[position];
    const held = emitter.tokens[previous];

    if (token.kind == .comment) {
        if (walk.text_is(held.text(emitter.source), "<")) {
            if (emitter.brackets.angles_at(position) > 0) return true;
        }
    }

    if (held.kind != .comment) return false;
    if (!walk.text_is(token.text(emitter.source), ">")) return false;
    return emitter.brackets.angles_at(previous) > 0;
}

fn braced(emitter: *const Emitter, position: u32, previous: u32, frame: *const core.Frame) ?bool {
    assert(position < emitter.count);
    assert(previous < position);

    const held = emitter.tokens[previous].kind;
    const kind = emitter.tokens[position].kind;

    if (kind == .block_end) {
        if (!frame.inside) return false;
        return held != .block_start;
    }

    if (walk.is_close(kind)) return false;
    if (kind == .block_start) return !emit.hugged(emitter, position, previous);
    return null;
}

pub fn closes_a_value(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.closed.open < emitter.count);

    if (!emitter.structured) return false;
    if (emitter.tokens[position].kind != .block_end) return false;
    if (emitter.closed.kind != .block_start) return false;
    return !emit.bodied(emitter, emitter.closed.open);
}

fn aligned_colon(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    const frame = line.frame(emitter);
    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return false;

    const word = emit.back_of(emitter, frame.open) orelse return false;
    if (!line.word_is(emitter, word, align_words)) return false;

    if (emitter.tokens[position].is_punctuation(.colon)) {
        return !label_colon(emitter, position, previous);
    }

    if (!emitter.tokens[previous].is_punctuation(.colon)) return false;

    const before = emit.back_of(emitter, previous) orelse return true;
    return !label_colon(emitter, previous, before);
}

fn label_colon(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (emitter.tokens[previous].kind != .identifier) return false;

    const after = emit.ahead_of(emitter, position) orelse return false;

    assert(after > position);

    if (emitter.tokens[after].kind == .block_start) return true;
    return line.word_is(emitter, after, labeled_words);
}

fn labelled(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (!emitter.tokens[position].is_punctuation(.colon)) return false;
    return line.word_is(emitter, previous, emitter.policy.label_words);
}

pub fn coded_at(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    var held = position;

    while (emitter.tokens[held].kind == .comment) {
        const found = emit.word_before(emitter, held) orelse return null;

        assert(found < held);

        held = found;
    }

    assert(held <= position);
    assert(emitter.tokens[held].kind != .comment);

    return held;
}

fn bracketed(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (line.word_is(emitter, previous, emitter.policy.signature_words)) {
        if (emit.roled(emitter, previous, brace.role_lambda)) return false;

        if (previous == emitter.line_first) {
            if (emitter.depth == 0) return true;
        }
    }

    if (emitter.policy.bracket_types) {
        const opening = emitter.tokens[position].opens_a_group() and
            emit.roled(emitter, position, brace.role_start);

        if (opening) {
            if (emit.operand_at(emitter, previous)) return true;
            if (line.word_is(emitter, previous, emitter.policy.hug_words)) return true;
        }
    }

    if (emit.empties(emitter, position)) {
        if (!line.word_is(emitter, previous, emitter.policy.hug_words)) return true;
    }

    const held = emitter.tokens[previous];

    if (line.word_is(emitter, previous, emitter.policy.hug_words)) return false;
    if (std.mem.startsWith(u8, held.text(emitter.source), "@")) return false;

    if (emitter.tokens[position].is_punctuation(.bracket_open)) {
        if (unite.decorator_closes(emitter, previous)) return true;
    }

    if (emit.prefixed(emitter, previous)) return held.end() < emitter.tokens[position].offset;
    return bracketed_keyword(emitter, position, previous);
}

fn comment_indexed(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.comment_opens) return false;

    const held = emitter.tokens[previous];
    if (held.kind != .comment) return false;
    if (!std.mem.startsWith(u8, held.text(emitter.source), "/*")) return false;

    const before = emit.back_of(emitter, previous) orelse return false;
    if (emitter.tokens[before].kind == .comment) return false;
    if (body.parts_at(emitter, before, previous)) return false;
    return emit.operand_at(emitter, before);
}

fn bracketed_keyword(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    const held = emitter.tokens[previous].kind;

    const hugs = !emitter.policy.keyword_gaps or
        line.word_is(emitter, previous, emitter.policy.signature_words);

    if (held == .keyword) {
        if (hugs) {
            if (emitter.tokens[previous].end() == emitter.tokens[position].offset) return false;
        }
    }

    if (held == .block_end) return false;

    if (held.eql(.{ .punctuation = .paren_close })) {
        const signed = line.word_is(emitter, emitter.line_first, emitter.policy.signature_words);

        if (signed) {
            if (emit.signing(emitter, previous, position)) return true;
        }
    }

    if (emitter.policy.convention_strings) {
        const convention = held == .string and emitter.tokens[position].is_punctuation(.paren_open);
        if (convention) return true;
    }

    if (emitter.policy.hug_lasts) {
        if (bracketed_accessor(emitter, position, previous)) return true;
    }

    if (modifier_bracketed(emitter, position, previous)) return true;
    if (headed_close(emitter, previous)) return true;
    if (emit.operand_at(emitter, previous)) return false;
    return !space.void_arrayed(emitter, position, previous);
}

fn bracketed_accessor(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(previous < position);
    assert(emitter.policy.hug_lasts);

    if (!accessor_word(emitter, previous)) return false;
    if (!emitter.tokens[position].is_punctuation(.bracket_open)) return false;

    const close = join.closing_of(emitter, position) orelse return false;
    const after = emit.ahead_of(emitter, close) orelse return false;

    return emitter.tokens[after].is_punctuation(.paren_open);
}

fn modifier_bracketed(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(previous < position);
    assert(position < emitter.count);

    if (!emitter.tokens[position].is_punctuation(.bracket_open)) return false;

    const bytes = emitter.tokens[previous].text(emitter.source);
    if (!word_listed(&core.access_words, bytes)) return false;
    if (!word_listed(emitter.policy.parameter_words, bytes)) return false;

    const before = emit.back_of(emitter, previous) orelse return true;
    if (emit.is_dot(emitter, before)) return false;
    return !line.word_is(emitter, before, emitter.policy.member_words);
}

fn headed_close(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.tokens[previous].is_punctuation(.paren_close)) return false;

    const open = emitter.brackets.open_of(previous) orelse return false;
    return headed(emitter, open);
}

fn word_listed(words: []const []const u8, bytes: []const u8) bool {
    assert(words.len <= std.math.maxInt(u32));
    assert(bytes.len <= std.math.maxInt(u32));

    for (words) |word| {
        if (walk.text_eql(word, bytes)) return true;
    }

    return false;
}

pub fn body_defined(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    for (emitter.nest[0..emitter.depth]) |frame| {
        if (frame.open <= open) {
            if (body_defining(emitter, frame.open)) return true;
        }
    }

    return body_defining(emitter, open);
}

fn body_defining(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emit.defined_brace(emitter, open)) return true;

    const close = emit.back_of(emitter, open) orelse return false;
    if (!emitter.tokens[close].is_punctuation(.paren_close)) return false;

    const found = emit.opened(emitter, close) orelse return false;
    const name = emit.back_of(emitter, found) orelse return false;

    assert(name < found);

    return emit.defining(emitter, name);
}

fn braced_clauses(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const close = join.closing_of(emitter, open) orelse return false;

    assert(close < emitter.count);

    var depth: u32 = 0;
    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const opening = walk.is_open(kind) and kind != .block_start;
        const closing = walk.is_close(kind) and kind != .block_end;

        if (opening) {
            depth += 1;
        } else if (closing) {
            depth -|= 1;
        } else if (depth == 0) {
            if (kind.eql(.{ .punctuation = .semicolon })) return true;
        } else {}
    }

    return false;
}
