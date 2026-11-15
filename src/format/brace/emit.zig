const std = @import("std");
const assert = std.debug.assert;
const Span = @import("../../stdx/bounded/span.zig");
const assembly = @import("assembly.zig");
const bind = @import("bind.zig");
const body = @import("body.zig");
const brace = @import("../brace.zig");
const call = @import("call.zig");
const closure = @import("closure.zig");
const comment = @import("comment.zig");
const core = @import("emitter.zig");
const edge = @import("edge.zig");
const header = @import("header.zig");
const ignore = @import("ignore.zig");
const imports = @import("imports.zig");
const ir = @import("../ir.zig");
const join = @import("join.zig");
const jsx = @import("jsx.zig");
const key = @import("key.zig");
const lead = @import("lead.zig");
const level = @import("level.zig");
const line = @import("line.zig");
const link = @import("link.zig");
const list = @import("list.zig");
const own = @import("own.zig");
const reach = @import("../reach.zig");
const semi = @import("semi.zig");
const sole = @import("sole.zig");
const span = @import("span.zig");
const split = @import("split.zig");
const stream = @import("../stream.zig");
const tern = @import("tern.zig");
const text = @import("../text.zig");
const tmpl = @import("tmpl.zig");
const unite = @import("unite.zig");
const value = @import("value.zig");
const walk = @import("../walk.zig");
const wide = @import("wide.zig");
const wrap = @import("wrap.zig");
const Emitter = core.Emitter;
const list_margin: u32 = 2;
const whitespace_ascii: []const u8 = " \t\n\x0c\r";
const whitespace_line: []const u8 = " \t";

pub fn run(emitter: *Emitter) error{Overflow}!void {
    assert(emitter.count == emitter.tokens.len);
    assert(emitter.depth == 0);

    var wrote = false;

    for (0..emitter.count) |index| {
        const position: u32 = @intCast(index);

        if (try run_position(emitter, position, wrote)) wrote = true;
    }

    try unite.union_dealigns(emitter, emitter.count);
    try unite.union_groups_close(emitter, emitter.count);
    try unite.intersect_group_close(emitter, emitter.count);
    try sole.soled_close(emitter, emitter.count);
    try wrap.wrapped_close(emitter, emitter.count);
    try line.level(emitter, 0);

    if (!wrote) return;

    if (emitter.previous) |held| {
        if (std.mem.endsWith(u8, emitter.tokens[held].text(emitter.source), "\n")) return;
    }

    try emitter.document.push(.hard_line);

    if (comment.module_blank(emitter)) try emitter.document.push(.{ .blank_line = 1 });
}

fn run_position(emitter: *Emitter, position: u32, wrote: bool) error{Overflow}!bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const current = emitter.tokens[position];

    try closes_reached(emitter, position);

    if (position < emitter.resume_at) return false;
    if (current.kind == .newline) return false;
    if (current.length == 0) return false;

    if (wrote) {
        if (split.added(emitter, position)) try split.separated(emitter, position);
    }

    if (current.kind == .comment) try ends_value(emitter, position);

    const owed = comment_operated(emitter, position) or comment.suffixed(emitter, position);

    if (owed) {
        emitter.comment_owed = position;

        return false;
    }

    if (split.dropped(emitter, position)) {
        if (semi.empty_statement(emitter, position)) emitter.voided = current.end();

        return false;
    }

    try call.type_reached(emitter, position);
    try assembly.asm_aligns(emitter, position);

    if (wrote) {
        if (split.wanted(emitter, position)) try line.newline(emitter, position);
    }

    try comment.separates(emitter, position);
    try token(emitter, position);
    try assembly.asm_aligning(emitter, position);
    try closure.bar_aligns(emitter, position);

    return true;
}

fn closes_reached(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    try sole.soled_close(emitter, position);
    try wrap.wrapped_close(emitter, position);
    try unite.union_dealigns(emitter, position);
    try unite.union_groups_close(emitter, position);
    try unite.intersect_group_close(emitter, position);
    try unite.constraint_close(emitter, position);
    try closure.bar_dealigns(emitter, position);
}

fn token(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.tokens[position].length > 0);

    emitter.arrowed = false;
    emitter.starting = emitter.line_start;

    try call.type_reached(emitter, position);
    try tern.ternary_leads(emitter, position);
    try jsx.comments(emitter, position);

    const body_close = spanning_body(emitter, position);
    var template = tmpl.template_body(emitter, position);

    if (template != null) {
        if (tmpl.template_walked(emitter, position)) template = null;
    }

    if (jsx.jsxing(emitter, position)) return token_jsx(emitter, position);

    const frame_closing = spread_closing(emitter, position);
    const held = frame_closing or !valuing(emitter);

    if (!try unite.union_gap(emitter, position)) {
        try token_separated(emitter, position, body_close != null, template != null, held);
    }

    try unite.union_group_opens(emitter, position);
    try unite.intersect_group_opens(emitter, position);
    try unite.decorated_opens(emitter, position);

    if (body_close orelse template) |close| {
        return token_spanned(emitter, position, close, body_close != null);
    }

    if (list.importing(emitter, position)) |close| return grouped(emitter, position, close);

    try ends_value(emitter, position);

    if (frame_closing) try closes(emitter, position);

    try bind.sequence_group_closes(emitter, position);

    const rooted = tmpl.hole_level(emitter, position);

    try tmpl.hole_closed(emitter, position);
    try line.nested(emitter, position);

    if (rooted) |rooted_level| try token_seated(emitter, position, rooted_level);

    const comment_led = emitter.starting or emitter.commented;
    emitter.commented = comment_led and emitter.tokens[position].kind == .comment;
    emitter.suppress_space = suppresses(emitter, position);
    emitter.previous = position;

    try token_written(emitter, position);
    try token_bound(emitter, position);

    if (frame_closing) {
        try link.chain_closes(emitter, position, true);

        return comments_comma(emitter, position);
    }

    try token_spread(emitter, position);
    try comments_comma(emitter, position);
}

fn token_spanned(
    emitter: *Emitter,
    position: u32,
    close: u32,
    spans_body: bool,
) error{Overflow}!void {
    assert(position <= close);
    assert(close < emitter.count);

    try spanning(emitter, position, close, spans_body);

    if (!spans_body) try comments_comma(emitter, close);
}

fn token_separated(
    emitter: *Emitter,
    position: u32,
    spans_body: bool,
    spans_template: bool,
    held: bool,
) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.tokens[position].length > 0);

    if (emitter.line_start) {
        _ = try unite.decorated_closes(emitter, position);

        return lead.leads(emitter, position);
    }

    if (try unite.decorated_closes(emitter, position)) return;

    try preceded(emitter, position, spans_body, spans_template, held);
}

fn token_jsx(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(jsx.jsxing(emitter, position));

    try assigns_closed(emitter, position);
    try jsx.opening(emitter, position);

    if (emitter.line_start) {
        try lead.leads(emitter, position);
    } else if (jsx.outer(emitter, position)) {
        try preceded(emitter, position, false, false, true);
    } else {}

    emitter.suppress_space = false;

    try jsx.parens_opening(emitter, position);
    try jsx.jsxes(emitter, position);
}

fn token_seated(emitter: *Emitter, position: u32, rooted_level: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);
    assert(rooted_level < std.math.maxInt(u32));

    const hole_shut = tmpl.holed_close(emitter, position);
    const indents = tmpl.hole_indents(emitter, position, hole_shut);
    const seat = rooted_level + @intFromBool(indents);

    try line.level(emitter, rooted_level);

    tmpl.seats(emitter, position, seat);
}

fn token_spread(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    try bind.sequence_group_opens(emitter, position);

    if (list.spreads(emitter)) {
        const spread_frame = emitter.nest[emitter.depth - 1];

        if (spread_frame.open == position) {
            try marks(emitter, position);

            return opens(emitter, position);
        }
    }

    try link.chain_closes(emitter, position, false);
}

fn token_written(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.previous != null);

    try own.constructing(emitter, position);
    try link.chain_cast_levels(emitter, position);
    try unite.union_leads(emitter, position);
    try tern.ternary_opens(emitter, position);
    try jsx.chain_links(emitter, position);
    try link.member_opens(emitter, position);
    try jsx.chain_dots(emitter, position);
    try unite.hole_operand_opens(emitter, position);
    try join.angle_closed(emitter, position);

    if (!join.angle_ended(emitter)) try emitted(emitter, position);

    try unite.angle_comments_comma(emitter, position);
    try comment_owing(emitter, position);
    try value_angle_holds(emitter, position);
    try join.angle_opened(emitter, position);
    try tern.ternary_aligns(emitter, position);
    try jsx.chain_aligns(emitter, position);
    try unite.union_aligns(emitter, position);
    try own.hugs_body(emitter, position);
    try own.constructed(emitter, position);
    try hole_opened(emitter, position);
    try tmpl.hole_restored(emitter, position);
    try value.key_restored(emitter, position);
}

fn token_bound(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    try unite.annotation_closed(emitter, position);
    try binds(emitter, position);
    try assigns(emitter, position);
    try own.arrow_chains(emitter, position);
    try holds_value(emitter, position);
    try values(emitter, position);
    try wrap.wraps(emitter, position);
}

fn spread_closing(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!list.spreads(emitter)) return false;

    assert(emitter.depth > 0);

    return position == emitter.nest[emitter.depth - 1].close;
}

fn preceded(
    emitter: *Emitter,
    position: u32,
    spans_body: bool,
    spans_template: bool,
    held: bool,
) error{Overflow}!void {
    assert(position < emitter.count);
    assert(!emitter.line_start);

    const frame_closing = spread_closing(emitter, position);

    if (comment_trailing(emitter, position)) {
        try comment_armed(emitter, position);
        try emitter.document.push(.space);

        return;
    }

    if (bind.sequence_group_lined(emitter)) return emitter.document.push(.line);

    if (header_comment_standing(emitter, position)) {
        try emitter.document.push(.broken);

        return emitter.document.push(.line);
    }

    const spaced = preceded_spaced(emitter, position, spans_body, spans_template);
    const wrapped = comment.binary_wrapped(emitter);

    if (preceded_parted(emitter, position, frame_closing, wrapped, held)) {
        try ternary_leveled(emitter, position);

        var led = false;

        if (emitter.previous) |prior| led = own.operator_led_comment(emitter, prior);

        if (!frame_closing) {
            if (!led) {
                if (list.separating(emitter)) try inset(emitter);
            }
        }

        if (wrapped) {
            try comment.binary_arms(emitter);

            if (wrap.logical_tail(emitter, position)) return emitter.document.push(.space);
        }

        try parts(emitter, position);

        return value_lined(emitter);
    }

    if (emitter.previous) |prior| {
        if (join.angle_lined(emitter, prior)) return emitter.document.push(.line);
    }

    const open_spaced = spaced and !frame_closing;
    if (try preceded_heavy(emitter, position, open_spaced)) return;

    if (open_spaced) try emitter.document.push(.space);
}

fn header_comment_standing(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.tokens[position].kind != .comment) return false;
    if (!list.chains_a_header(emitter)) return false;

    const before = back_of(emitter, position) orelse return false;
    if (!body.parts_at(emitter, before, position)) return false;
    if (emitter.tokens[before].kind == .comment) return false;

    var last = position;

    for (0..emitter.count) |_| {
        const after = ahead_of(emitter, last) orelse return false;
        if (emitter.tokens[after].kind != .comment) return after == line.frame(emitter).close;

        last = after;
    }

    return false;
}

fn preceded_spaced(
    emitter: *const Emitter,
    position: u32,
    spans_body: bool,
    spans_template: bool,
) bool {
    assert(position < emitter.count);
    assert(!emitter.line_start);

    const current = emitter.tokens[position];
    const streamed = spans_body and macro_bracket(emitter, position);
    var tagged = false;
    var gapped = true;
    var defined = false;

    if (emitter.previous) |prior| {
        const held = emitter.tokens[prior];

        tagged = spans_template and walk.ends_operand(held.kind);
        gapped = held.end() < current.offset;
        defined = spans_body and held.kind == .identifier and defining(emitter, prior);
    }

    const macro_gapped = spans_body and !streamed and emitter.policy.macro_gaps;
    const body_spaced = spans_body and !streamed;

    if (macro_gapped) return gapped;
    if (defined) return gapped;
    if (body_spaced) return true;
    if (streamed) return false;
    if (tagged) return false;
    return split.spaced(emitter, position);
}

fn preceded_parted(
    emitter: *const Emitter,
    position: u32,
    frame_closing: bool,
    wrapped: bool,
    held: bool,
) bool {
    assert(position < emitter.count);

    if (wrapped) assert(emitter.policy.binary_lines);

    if (!frame_closing) {
        if (list.separating(emitter)) return true;
        if (wrapped) return true;
        if (tern.ternary_parted(emitter, position)) return true;
    }

    if (!held) return true;

    const prior = emitter.previous orelse return false;
    return valued_colon(emitter, prior);
}

fn preceded_heavy(emitter: *Emitter, position: u32, open_spaced: bool) error{Overflow}!bool {
    assert(position < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (open_spaced) {
        if (!wrap.logical_tail(emitter, position)) {
            if (sole.soled_heavy(emitter)) {
                try sole.soled_heavy_lined(emitter);

                return true;
            }
        }
    }

    if (try sole.spread_soled_opens(emitter, position, open_spaced)) return true;

    if (open_spaced) {
        if (!wrap.logical_tail(emitter, position)) {
            if (sole.heavy_lined(emitter)) {
                try sole.heavy_armed(emitter);
                try emitter.document.push(.line);

                return true;
            }
        }
    }

    return false;
}

pub fn comment_trailing(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const current = emitter.tokens[position];
    if (current.kind != .comment) return false;
    if (!std.mem.startsWith(u8, current.text(emitter.source), "//")) return false;

    const prior = emitter.previous orelse return false;
    return !body.parts_at(emitter, prior, position);
}

fn comment_armed(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.tokens[position].kind == .comment);

    const spelling = emitter.tokens[position].text(emitter.source);
    if (!std.mem.startsWith(u8, spelling, "//")) return;

    if (emitter.depth > 0) {
        if (level.holds_a_condition(emitter, line.frame(emitter).open)) return;
    }

    const operator = emitter.previous orelse return;
    if (!span.wrapping_operator(emitter, operator)) return;
    if (!comment.binary_wrapped(emitter)) return;

    try comment.binary_arms(emitter);
}

fn comment_operated(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.tokens[position].length > 0);

    if (!emitter.policy.chain_simples) return false;
    if (!emitter.policy.binary_lines) return false;

    const current = emitter.tokens[position];
    if (current.kind != .comment) return false;
    if (!std.mem.startsWith(u8, current.text(emitter.source), "//")) return false;
    if (jsx.jsxing(emitter, position)) return false;

    const held = join.coded_before(emitter, position) orelse return false;
    if (body.parts_at(emitter, held, position)) return false;
    if (!emitter.tokens[held].ends_a_value()) return false;

    const operator = ahead_of(emitter, position) orelse return false;
    if (jsx.jsxing(emitter, operator)) return false;
    if (!span.wrapping_spelled(emitter, operator)) return false;
    return body.parts_at(emitter, position, operator);
}

fn comment_owing(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.previous != null);

    const comment_at = emitter.comment_owed orelse return;

    if (!span.wrapping_spelled(emitter, position)) {
        if (!comment.suffix_owed(emitter, comment_at, position)) return;
    }

    emitter.comment_broke = position;
    emitter.comment_owed = null;

    try emitter.document.push(.space);
    try emitter.document.push(.{ .verbatim = written(emitter, comment_at) });
}

pub fn comment_ended(emitter: *const Emitter, prior: u32) bool {
    assert(prior < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emitter.tokens[prior];
    if (held.kind != .comment) return false;

    const spelling = held.text(emitter.source);
    if (!std.mem.startsWith(u8, spelling, "//")) return false;
    return !std.mem.endsWith(u8, spelling, "\n");
}

pub fn comment_opening(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const paren = emitter.tokens[position].is_punctuation(.paren_open);
    const bare = paren and !split.headed(emitter, position) and !list.calling(emitter, position);

    if (!emitter.policy.comment_opens) return null;
    if (!bare) return null;

    const prior = emitter.previous orelse return null;
    if (body.parts_at(emitter, prior, position)) return null;
    if (emitter.tokens[prior].kind == .comment) return null;

    const comment_at = ahead_of(emitter, position) orelse return null;
    const held = emitter.tokens[comment_at];
    if (held.kind != .comment) return null;
    if (!std.mem.startsWith(u8, held.text(emitter.source), "//")) return null;
    if (body.parts_at(emitter, position, comment_at)) return null;
    return comment_at;
}

pub fn breaks(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    if (comment.opened(emitter, position, prior)) return true;
    if (wide.forced(emitter, position, prior)) return true;
    if (bind.declare_broken(emitter, position, prior)) return true;
    if (span.header_broken(emitter, position, prior)) return true;
    if (split.body_broken(emitter, position, prior)) return true;
    if (span.spread_listed(emitter, position, prior)) return true;
    if (own.assign_runs(emitter, position, prior)) return true;
    if (join.assign_wrapped(emitter, position, prior)) return true;
    if (join.assign_headed(emitter, position, prior)) return true;
    if (join.assign_rooted(emitter, position, prior)) return true;
    if (span.chain_parts(emitter, position, prior)) return true;
    if (span.binary_broken(emitter, position, prior)) return true;
    if (span.binary_assigned(emitter, prior)) return true;
    if (header.brace_broken(emitter, position)) return true;
    if (join.attribute_broken(emitter, position)) return true;
    if (span.chain_orphaned(emitter, position)) return true;
    if (span.linked_operand(emitter, position, prior)) return true;
    return case_parted(emitter, position, prior);
}

pub fn case_held(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const open = case_held_open(emitter, position) orelse return false;
    var coded = back_of(emitter, open);
    var steps: u32 = 0;

    while (coded) |held| {
        assert(steps < emitter.count);
        steps += 1;

        if (emitter.tokens[held].kind != .comment) break;

        coded = back_of(emitter, held);
    }

    const before = coded orelse return false;
    const prior = emitter.tokens[before];

    if (prior.is_punctuation(.colon)) {
        if (!case_labeled(emitter, before)) return false;
        return !case_sole(emitter, open);
    }

    if (prior.is_punctuation(.semicolon)) return true;
    return prior.kind == .block_end;
}

fn case_held_open(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const kind = emitter.tokens[position].kind;
    if (kind == .block_start) return position;
    if (kind == .block_end) return emitter.brackets.open_of(position);
    return null;
}

fn case_labeled(emitter: *const Emitter, colon: u32) bool {
    assert(colon < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.depth == 0) return false;
    return bind.case_label(emitter, colon, line.frame(emitter).open);
}

fn case_parted(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    if (!emitter.policy.chain_simples) return false;
    if (emitter.tokens[position].kind != .block_start) return false;
    if (!case_labeled(emitter, prior)) return false;
    return !case_sole(emitter, position);
}

fn case_sole(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = emitter.brackets.close_of(open) orelse return true;

    for (0..core.case_sole_scan_max) |_| {
        const held = ahead_of(emitter, scan) orelse return true;
        const current = emitter.tokens[held];
        const spelling = current.text(emitter.source);
        const skipped = current.kind == .comment or walk.text_is(spelling, ";");

        if (skipped) {
            scan = held;

            continue;
        }

        if (current.kind == .block_end) return true;
        if (walk.text_is(spelling, "case")) return true;
        return walk.text_is(spelling, "default");
    }

    return true;
}

pub fn emitted(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.previous != null);

    if (ignore.suppressed_span(emitter, position)) |tail| {
        return ignore.suppressed_spanned(emitter, position, tail);
    }

    if (imports.import_span(emitter, position)) |close| {
        return imports.import_spanned(emitter, position, close);
    }

    if (tmpl.template_piece(emitter, position)) {
        return emitter.document.push(.{ .chunk = written(emitter, position) });
    }

    if (list.arrowed(emitter, position)) {
        try emitter.document.push(.{ .text = .{ .source = .literal, .span = emitter.opening } });
        try emitter.document.push(.{ .verbatim = written(emitter, position) });
        try emitter.document.push(.{ .text = .{ .source = .literal, .span = emitter.closing } });

        return;
    }

    if (list.membered(emitter, position)) {
        return emitter.document.push(.{
            .text = .{ .source = .literal, .span = emitter.semicolon },
        });
    }

    if (starring(emitter, position)) {
        return emitter.document.push(.{ .starred = written(emitter, position) });
    }

    const keyed = key.unquoting(emitter, position) orelse key.remodifying(emitter, position);
    if (keyed) |held| return emitter.document.push(.{ .verbatim = held });
    return emitted_rewritten(emitter, position);
}

fn emitted_rewritten(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.arena.count() <= emitter.arena.capacity());

    const offset = emitter.arena.count();
    const spelling = emitter.tokens[position].text(emitter.source);

    if (casting(emitter, position)) |wanted| {
        try emitter.arena.push(wanted);

        return emitted_arena(emitter, offset);
    }

    if (reflagging(emitter, position)) |split_at| {
        try text.reflagged(emitter.arena, spelling, split_at);

        return emitted_arena(emitter, offset);
    }

    if (renumbering(emitter, position)) {
        try text.renumbered(emitter.arena, spelling);

        return emitted_arena(emitter, offset);
    }

    const quoted, const quote = requoting(emitter, position) orelse {
        return emitter.document.push(.{ .verbatim = written(emitter, position) });
    };

    try emitter.arena.push_byte(quote);
    try text.requoted(emitter.arena, quoted, quote);
    try emitter.arena.push_byte(quote);

    return emitted_arena(emitter, offset);
}

fn emitted_arena(emitter: *Emitter, offset: u32) error{Overflow}!void {
    assert(offset <= emitter.arena.count());
    assert(emitter.arena.count() <= emitter.arena.capacity());

    const pushed: Span = .{ .offset = offset, .length = emitter.arena.count() - offset };

    try emitter.document.push(.{ .verbatim_arena = pushed });
}

fn starring(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const current = emitter.tokens[position];
    const standing = list.spreads(emitter) and list.comment_standing(emitter, position);
    const started = emitter.starting or standing;
    if (!started) return false;
    if (current.kind != .comment) return false;

    const spelling = current.text(emitter.source);
    if (!word_leads(emitter.policy.lead_words, spelling)) return false;

    var rows = std.mem.splitScalar(u8, spelling, '\n');

    _ = rows.first();

    if (rows.peek() == null) return false;

    for (0..spelling.len) |_| {
        const row = rows.next() orelse break;
        const stripped = std.mem.trimStart(u8, row, whitespace_ascii);
        if (!std.mem.startsWith(u8, stripped, "*")) return false;
    }

    assert(rows.peek() == null);

    return true;
}

fn word_leads(words: []const []const u8, spelling: []const u8) bool {
    assert(words.len <= std.math.maxInt(u32));
    assert(spelling.len <= std.math.maxInt(u32));

    for (words) |word| {
        if (std.mem.startsWith(u8, spelling, word)) return true;
    }

    return false;
}

fn casting(emitter: *const Emitter, position: u32) ?[]const u8 {
    assert(position < emitter.count);
    comptime assert(core.order_run_max >= 2);

    if (emitter.policy.order_words.len == 0) return null;
    if (!casted(emitter, position)) return null;
    if (!casting_single(emitter, position)) return null;

    var head = position;

    for (0..core.order_run_max) |_| {
        head = cast_above(emitter, head) orelse break;
    }

    var ranks: [core.order_run_max]u32 = @splat(0);
    var filled: u32 = 0;
    var index: u32 = 0;
    var last = head;
    var scan: ?u32 = head;

    while (scan) |held| {
        if (filled == core.order_run_max) return null;

        if (held == position) index = filled;

        ranks[filled] = ranking(emitter, held) orelse return null;
        filled += 1;
        last = held;
        scan = cast_under(emitter, held);
    }

    if (filled < 2) return null;
    if (!casting_distinct(ranks[0..filled])) return null;
    if (casting_commented(emitter, head, last)) return null;

    casting_sorted(ranks[0..filled]);

    assert(index < filled);

    const wanted = emitter.policy.order_words[ranks[index]];
    if (walk.text_eql(wanted, emitter.tokens[position].text(emitter.source))) return null;
    return wanted;
}

fn casting_single(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const open = line.coding(emitter, position) orelse return false;
    const close = emitter.brackets.close_of(open) orelse return false;
    const comma = list.parted_at(emitter, open + 1, close);

    assert(comma <= close);

    if (comma == close) return line.coding(emitter, open) != close;
    return line.coding(emitter, comma) == close;
}

fn casting_distinct(ranks: []const u32) bool {
    assert(ranks.len >= 2);
    assert(ranks.len <= core.order_run_max);

    for (ranks, 0..) |rank, step| {
        for (ranks[0..step]) |held| {
            if (held == rank) return false;
        }
    }

    return true;
}

fn casting_commented(emitter: *const Emitter, head: u32, last: u32) bool {
    assert(head <= last);
    assert(last < emitter.count);

    const open = line.coding(emitter, last) orelse return false;
    const end = line.coding(emitter, open) orelse emitter.count;

    assert(emitter.tokens[open].is_punctuation(.paren_open));

    for (emitter.tokens[head..end]) |held| {
        if (held.kind == .comment) return true;
    }

    return false;
}

fn casting_sorted(ranks: []u32) void {
    assert(ranks.len >= 2);
    assert(ranks.len <= core.order_run_max);

    for (1..ranks.len) |step| {
        const rank = ranks[step];
        var place = step;

        while (place > 0) {
            if (ranks[place - 1] <= rank) break;

            ranks[place] = ranks[place - 1];
            place -= 1;
        }

        ranks[place] = rank;
    }
}

fn casted(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!line.word_is(emitter, position, emitter.policy.order_words)) return false;

    const held = line.coding(emitter, position) orelse return false;
    return emitter.tokens[held].is_punctuation(.paren_open);
}

fn ranking(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const spelling = emitter.tokens[position].text(emitter.source);

    for (emitter.policy.order_words, 0..) |held, index| {
        if (walk.text_eql(held, spelling)) {
            assert(index < emitter.policy.order_words.len);

            return @intCast(index);
        }
    }

    return null;
}

fn cast_above(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const open = join.coded_before(emitter, position) orelse return null;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return null;

    const held = join.coded_before(emitter, open) orelse return null;
    if (!casted(emitter, held)) return null;
    return held;
}

fn cast_under(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const open = line.coding(emitter, position) orelse return null;
    const held = line.coding(emitter, open) orelse return null;
    if (!casted(emitter, held)) return null;
    return held;
}

fn reflagging(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.regex_flags) return null;
    if (emitter.tokens[position].kind != .string) return null;
    return text.reflagging(emitter.tokens[position].text(emitter.source));
}

fn renumbering(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.number_forms) return false;
    if (emitter.tokens[position].kind != .number) return false;

    const held = std.mem.endsWith(u8, emitter.tokens[position].text(emitter.source), ".");
    var reached = false;

    if (ahead_of(emitter, position)) |after| {
        reached = walk.text_is(emitter.tokens[after].text(emitter.source), ".");
    }

    if (!held) return true;
    return !reached;
}

pub fn requoting(emitter: *const Emitter, position: u32) ?struct { []const u8, u8 } {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.string_quotes) return null;

    const current = emitter.tokens[position];
    if (current.kind != .string) return null;

    const spelling = current.text(emitter.source);
    const quoted = text.bodied(spelling) orelse return null;
    const wanted = text.preferred(quoted);
    if (wanted == spelling[0]) return null;
    return .{ quoted, wanted };
}

pub fn written(emitter: *const Emitter, position: u32) Span {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const current = emitter.tokens[position];
    const whole = current.span();
    if (current.kind != .comment) return whole;
    if (documenting(emitter, position)) return whole;

    const trimmed = std.mem.trimEnd(u8, current.text(emitter.source), whitespace_ascii);

    assert(trimmed.len <= whole.length);

    return .{ .offset = whole.offset, .length = @intCast(trimmed.len) };
}

fn documenting(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.tokens[position].kind == .comment);

    if (!emitter.policy.comment_tails) return false;

    const spelling = emitter.tokens[position].text(emitter.source);

    if (std.mem.startsWith(u8, spelling, "///")) {
        return !std.mem.startsWith(u8, spelling[3..], "/");
    }

    return std.mem.startsWith(u8, spelling, "//!");
}

fn spanning_body(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.tokens[position].length > 0);

    return join.macro_body(emitter, position) orelse
        giving(emitter, position) orelse
        skipping(emitter, position) orelse
        join.attribute_span(emitter, position);
}

fn giving(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.line_start) return null;
    if (std.sort.binarySearch(u32, emitter.gives, position, order_u32) == null) return null;

    const close = skipped_item(emitter, position -| 1) orelse return null;
    if (close < position) return null;
    assert(close <= emitter.count);

    return close;
}

fn order_u32(wanted: u32, held: u32) std.math.Order {
    assert(wanted < std.math.maxInt(u32));
    assert(held < std.math.maxInt(u32));

    return std.math.order(wanted, held);
}

fn skipping(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const words = emitter.policy.skip_words;
    if (words.len == 0) return null;
    if (!walk.text_is(emitter.tokens[position].text(emitter.source), "#")) return null;

    var scan = ahead_of(emitter, position) orelse return null;
    if (!emitter.tokens[scan].is_punctuation(.bracket_open)) return null;

    for (words) |word| {
        scan = ahead_of(emitter, scan) orelse return null;

        if (!walk.text_eql(emitter.tokens[scan].text(emitter.source), word)) return null;
    }

    scan = ahead_of(emitter, scan) orelse return null;

    if (!emitter.tokens[scan].is_punctuation(.bracket_close)) return null;
    return skipped_item(emitter, scan);
}

pub fn skipped_item(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var braces: u32 = 0;
    var brackets: u32 = 0;
    var scan = position + 1;

    while (scan < emitter.count) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;

        if (kind == .block_start) {
            braces += 1;

            continue;
        }

        if (kind == .block_end) {
            if (braces == 0) {
                assert(scan -| 1 <= emitter.count);

                return scan -| 1;
            }

            braces -= 1;

            const balanced = braces == 0 and brackets == 0;

            if (balanced) {
                if (!carried(emitter, scan)) return ended_item(emitter, scan);
            }

            continue;
        }

        if (walk.is_open(kind)) {
            brackets += 1;

            continue;
        }

        if (walk.is_close(kind)) {
            if (brackets == 0) return null;

            brackets -= 1;

            continue;
        }

        if (braces > 0) continue;
        if (brackets > 0) continue;

        if (kind.eql(.{ .punctuation = .semicolon })) {
            assert(scan <= emitter.count);

            return scan;
        }
    }

    return null;
}

fn carried(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.tokens[position].kind == .block_end);

    const after = ahead_of(emitter, position) orelse return false;
    const spelling = emitter.tokens[after].text(emitter.source);
    if (walk.text_is(spelling, "else")) return true;
    if (walk.text_is(spelling, ".")) return true;
    if (walk.text_is(spelling, "?")) return true;
    return word_in(emitter.policy.continue_words, spelling);
}

fn word_in(words: []const []const u8, spelling: []const u8) bool {
    assert(words.len <= std.math.maxInt(u32));
    assert(spelling.len <= std.math.maxInt(u32));

    for (words) |word| {
        if (walk.text_eql(word, spelling)) return true;
    }

    return false;
}

fn ended_item(emitter: *const Emitter, position: u32) u32 {
    assert(position < emitter.count);
    assert(emitter.tokens[position].kind == .block_end);

    const held = ahead_of(emitter, position) orelse return position;
    if (emitter.tokens[held].is_punctuation(.semicolon)) return held;
    return position;
}

fn spanning(
    emitter: *Emitter,
    position: u32,
    close: u32,
    spans_body: bool,
) error{Overflow}!void {
    assert(position < emitter.count);
    assert(close >= position);

    if (spans_body) {
        try join.spread(emitter, position, close);
    } else if (tmpl.template_body(emitter, position) == null) {
        try spanned(emitter, position, close);
    } else {
        try span.respanned(emitter, position, close, false);
    }

    try binds(emitter, position);
    try assigns(emitter, position);
    try wrap.wraps(emitter, position);
}

fn binds(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);

    if (emitter.listed > 0) {
        if (emitter.binders[emitter.listed - 1].start == position) return;
    }

    if (emitter.listed == core.binder_depth_max) return;
    if (!bind.declares_list(emitter, position)) return;

    const stop = bind.declares_stop(emitter, position) orelse return;

    emitter.binders[emitter.listed] = .{
        .stop = stop,
        .depth = emitter.depth,
        .start = position,
        .valued = bind.declares_a_value(emitter, position),
    };

    emitter.listed += 1;
    emitter.levels += 1;
    emitter.printed += 1;
    emitter.indent += 1;

    const newest = (emitter.lined + core.line_level_max - 1) % core.line_level_max;

    emitter.bound_ring = emitter.lines[newest];
    emitter.lines[newest].level = emitter.printed;

    assert(emitter.listed <= core.binder_depth_max);

    try emitter.document.push(.indent);
}

pub fn declares_closed(emitter: *Emitter, position: u32) void {
    assert(position <= emitter.count);
    assert(emitter.listed <= core.binder_depth_max);

    while (emitter.listed > 0) {
        const held = emitter.binders[emitter.listed - 1];

        if (emitter.depth < held.depth) {
            emitter.listed -= 1;

            continue;
        }

        if (position < held.stop) return;

        emitter.listed -= 1;

        emitter.levels -|= 1;
    }
}

fn assigns(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.assigns <= core.assign_depth_max);

    try assigns_closed(emitter, position);

    if (own.assigning(emitter, position)) |held| {
        if (emitter.owed == core.assign_depth_max) return error.Overflow;
        if (emitter.assigns == core.assign_depth_max) return error.Overflow;

        emitter.assign_hug = true;
        emitter.assigned[emitter.assigns] = .{ .equals = position, .close = held[0] };
        emitter.assigns += 1;

        emitter.dedents[emitter.owed] = .{
            .dedent = held[1],
            .depth = emitter.depth,
            .equals = position,
        };

        emitter.owed += 1;

        const pushed = emitter.document.push(.group_open);

        emitter.assign_groups[emitter.assigns - 1] = emitter.document.group_serial();

        try pushed;
        try line.opens_broken(emitter);
    }

    try assigns_closed(emitter, position);
}

pub fn assigns_closed(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.assigns <= core.assign_depth_max);

    while (emitter.assigns > 0) {
        if (emitter.assigned[emitter.assigns - 1].close != position) break;

        emitter.assigns -= 1;
        emitter.assign_hug = emitter.assigns > 0;
        emitter.arrowed = walk.text_is(emitter.tokens[position].text(emitter.source), "=>");

        if (emitter.tokens[position].is_punctuation(.paren_open)) {
            assigns_arrowed(emitter, position);
        }

        try emitter.document.push(.group_close);
    }

    while (emitter.owed > 0) {
        if (emitter.dedents[emitter.owed - 1].dedent != position) break;

        emitter.owed -= 1;

        try line.closes_broken(emitter);
    }

    assert(emitter.owed <= core.assign_depth_max);
}

fn assigns_arrowed(emitter: *Emitter, position: u32) void {
    assert(position < emitter.count);
    assert(emitter.tokens[position].is_punctuation(.paren_open));

    const close = join.closing_of(emitter, position) orelse return;
    const arrow_at = own.arrow_typed_ahead(emitter, close) orelse return;

    emitter.arrow_head = arrow_at;
}

pub fn property_arrowed(emitter: *const Emitter, held: core.Frame, position: u32) bool {
    assert(position < emitter.count);
    assert(held.open < emitter.count);

    const head = element_head(emitter, held, position);
    const inset_width = (held.inset + 1) * emitter.options.indent_width;
    const columns = span.printed_columns(emitter, head, position);
    const keyed = inset_width + columns < emitter.options.line_width;
    if (!keyed) return false;

    const open = ahead_of(emitter, position) orelse return false;
    if (!span.spread_arrows(emitter, open)) return false;

    const close = join.closing_of(emitter, open) orelse return false;
    const after = ahead_of(emitter, close) orelse return false;

    return walk.text_is(emitter.tokens[after].text(emitter.source), "=>");
}

fn element_head(emitter: *const Emitter, held: core.Frame, position: u32) u32 {
    assert(position < emitter.count);
    assert(held.open < emitter.count);

    var depth: u32 = 0;
    var head = held.open + 1;
    var scan = held.open + 1;

    while (scan < position) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const deeper = walk.is_open(kind) or kind == .block_start;
        const shallower = walk.is_close(kind) or kind == .block_end;

        if (deeper) {
            depth += 1;
        } else if (shallower) {
            depth -|= 1;
        } else if (depth == 0) {
            if (emitter.tokens[scan].is_punctuation(.comma)) head = scan + 1;
        } else {}
    }

    assert(head > held.open);

    return head;
}

fn values(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const held = value.propertied(emitter, position) orelse return;

    assert(emitter.depth > 0);

    emitter.nest[emitter.depth - 1].valued = .{ .keyed = held[0], .shut = held[1], .end = held[2] };

    try emitter.document.push(.group_open);
    try line.opens_broken(emitter);
}

fn ends_value(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return;

    const held = emitter.nest[emitter.depth - 1].valued;
    if (held.end != position) return;

    emitter.nest[emitter.depth - 1].valued = core.Valued.empty;

    if (held.shut == position) try emitter.document.push(.group_close);

    try line.closes_broken(emitter);
}

fn value_angle_holds(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.previous != null);

    if (!walk.text_is(emitter.tokens[position].text(emitter.source), "<")) return;

    try holds_value(emitter, position);
}

fn holds_value(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const owed: u32 = if (walk.is_open(emitter.tokens[position].kind)) 2 else 1;
    if (emitter.depth < owed) return;

    const index = emitter.depth - owed;
    const frame = emitter.nest[index];
    if (frame.valued.shut != position) return;
    if (frame.valued.end == position) return;

    emitter.nest[index].valued.shut = 0;

    try emitter.document.push(.group_close);
}

fn valuing(emitter: *const Emitter) bool {
    assert(emitter.assigns <= core.assign_depth_max);
    assert(emitter.depth <= brace.nest_depth_max);

    const prior = emitter.previous orelse return false;

    for (emitter.assigned[0..emitter.assigns]) |held| {
        if (held.equals == prior) return true;
    }

    if (emitter.depth == 0) return false;

    const frame = emitter.nest[emitter.depth - 1];
    if (frame.valued.keyed != prior) return false;
    return frame.valued.end != 0;
}

fn hole_opened(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!walk.substituting(emitter.source, emitter.tokens[position])) return;

    const hole_shut = tmpl.holed_close(emitter, position);
    if (!tmpl.hole_indents(emitter, position, hole_shut)) return;

    const rooted = tmpl.hole_level(emitter, position);
    const held_level = rooted orelse tmpl.hole_held(emitter);

    try emitter.document.push(.group_open);
    try line.level(emitter, held_level + 1);
    try emitter.document.push(.soft_line);

    if (rooted == null) tmpl.seats(emitter, position, held_level + 1);
}

fn comments_comma(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.previous != null);

    if (!own.trailed_comma(emitter, position)) return;

    assert(emitter.depth > 0);

    const held = emitter.nest[emitter.depth - 1];
    const close = held.close;
    const trailing = ahead_of(emitter, position) orelse return;
    const trailing_text = emitter.tokens[trailing].text(emitter.source);
    const trailing_lined = std.mem.startsWith(u8, trailing_text, "//");
    const typed_open = emitter.typed and !list.pattern_separated(emitter, held.open);
    const typed_held = typed_open or span.typed_brace(emitter, close);
    const typed = typed_held or span.type_closed(emitter, close);
    const braced = emitter.tokens[close].kind == .block_end;
    const semicolon_ended = typed and braced;
    const spelling = if (semicolon_ended) emitter.semicolon else emitter.comma;

    try closes_reached(emitter, close);
    try emitter.document.push(.{ .text = .{ .source = .literal, .span = spelling } });

    if (!trailing_lined) try emitter.document.push(.broken);
}

fn suppresses(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.tokens[position].length > 0);

    const current = emitter.tokens[position];
    const frame = line.frame(emitter);

    if (roled(emitter, position, brace.role_tight)) return true;
    if (roled(emitter, position, brace.role_spaced)) return false;
    if (pointed(emitter, position)) return true;
    if (is_dot(emitter, position)) return suppresses_dot(emitter, position);

    if (walk.is_open(current.kind)) {
        if (current.kind != .block_start) return true;
        return !frame.inside;
    }

    if (current.is_punctuation(.bracket_close)) {
        if (!emitter.policy.bracket_types) return false;
        return !emitter.closed.index;
    }

    if (current.is_punctuation(.paren_close)) return emitter.closed.casts;
    if (ellipsis(emitter, position)) return true;
    if (line.word_is(emitter, position, emitter.policy.tight_words)) return true;

    if (line.word_is(emitter, position, emitter.policy.prefix_words)) {
        return adjacent(emitter, position);
    }

    if (arrow(emitter, position)) return suppresses_arrow(emitter, position);
    if (line.word_is(emitter, position, emitter.policy.source_words)) return false;

    if (current.is_punctuation(.colon)) {
        if (!emitter.policy.slice_colons) return false;
        return frame.kind.eql(.{ .punctuation = .bracket_open });
    }

    return suppresses_unary(emitter, position);
}

fn suppresses_dot(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(is_dot(emitter, position));

    if (ahead_of(emitter, position)) |held| {
        if (spaced_dot(emitter, held, position)) return false;
    }

    if (doubled(emitter, position)) return false;
    if (position == 0) return true;
    return !doubled(emitter, position - 1);
}

fn suppresses_unary(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(!roled(emitter, position, brace.role_tight));

    if (emitter.tokens[position].kind != .punctuation) return false;
    if (!line.word_is(emitter, position, emitter.policy.unary_words)) return false;

    const spaced = emitter.policy.chain_simples or prefix_tight(emitter, position);

    if (!spaced) {
        if (!adjacent(emitter, position)) return false;
    }

    if (emitter.starting) return true;
    if (roled(emitter, position, brace.role_start)) return true;

    const prior = emitter.previous orelse return true;
    return unary_seated(emitter, prior);
}

fn unary_seated(emitter: *const Emitter, held: u32) bool {
    assert(held < emitter.count);
    assert(emitter.tokens[held].length > 0);

    if (!walk.ends_operand(emitter.tokens[held].kind)) return true;
    if (types_at(emitter, held)) return true;
    return edge.statement_ended(emitter, held);
}

pub fn glue_exempt(emitter: *const Emitter, prior: u32, position: u32) bool {
    assert(prior < emitter.count);
    assert(position < emitter.count);

    if (prefix_tight(emitter, prior)) return true;
    if (!emitter.policy.unary_tight) return false;
    if (walk.is_open(emitter.tokens[prior].kind)) return true;
    if (walk.is_close(emitter.tokens[position].kind)) return true;
    if (roled(emitter, prior, brace.role_tight)) return true;
    return roled(emitter, position, brace.role_tight);
}

pub fn prefix_tight(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.unary_tight) return false;
    if (!roled(emitter, position, brace.role_start)) return false;
    if (!line.word_is(emitter, position, emitter.policy.unary_words)) return false;
    return !combining(emitter, position);
}

fn combining(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = ahead_of(emitter, position) orelse return false;

    assert(held > position);

    return combines_with(emitter, position, held);
}

fn combines_with(emitter: *const Emitter, previous: u32, position: u32) bool {
    assert(previous < position);
    assert(position < emitter.count);

    const held = emitter.tokens[previous];
    const spelling = emitter.tokens[position].text(emitter.source);
    const initial: u8 = if (spelling.len > 0) spelling[0] else 0;
    if (held.kind == .number) return initial == '.';

    const operator = held.text(emitter.source);
    if (walk.text_is(operator, "+")) return initial == '+';
    if (walk.text_is(operator, "-")) return initial == '-';
    if (walk.text_is(operator, "/")) return initial == '*';
    if (walk.text_is(operator, "<")) return initial == '-' or initial == '<';
    if (walk.text_is(operator, "&")) return initial == '&' or initial == '^';
    return false;
}

fn adjacent(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.tokens[position].length > 0);

    const held = ahead_of(emitter, position) orelse return true;
    return emitter.tokens[position].end() == emitter.tokens[held].offset;
}

pub fn mark_of(emitter: *const Emitter, position: u32) u8 {
    assert(emitter.marks.len <= std.math.maxInt(u32));
    assert(position < emitter.count);

    if (position < emitter.marks.len) return emitter.marks[position];
    return 0;
}

pub fn operand_of(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.operands.len <= emitter.count);

    if (position >= emitter.operands.len) return null;

    const held = emitter.operands[position];
    if (held == brace.operand_none) return null;

    const start = held & ~brace.operand_held;

    assert(start < position);

    return start;
}

pub fn operand_ended(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.operand_ends.len <= emitter.count);

    if (position >= emitter.operand_ends.len) return null;

    const held = emitter.operand_ends[position];
    if (held == brace.operand_none) return null;

    assert(held < position);

    return held;
}

pub fn operand_held(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(operand_of(emitter, position) != null);

    return emitter.operands[position] & brace.operand_held != 0;
}

pub fn signing(emitter: *const Emitter, previous: u32, position: u32) bool {
    assert(previous < position);
    assert(emitter.line_first <= previous);

    for (emitter.line_first..previous) |scan| {
        if (emitter.tokens[scan].kind == .block_start) return false;
    }

    if (!emitter.structured) return true;
    return roled(emitter, position, brace.role_start);
}

pub fn roled(emitter: *const Emitter, position: u32, role: u16) bool {
    assert(role != 0);
    assert(emitter.roles.len <= std.math.maxInt(u32));
    assert(position < emitter.count);

    if (position < emitter.roles.len) return emitter.roles[position] & role != 0;
    return false;
}

pub fn bodied(emitter: *const Emitter, position: u32) bool {
    assert(emitter.count == emitter.tokens.len);
    assert(emitter.roles.len <= std.math.maxInt(u32));
    assert(position < emitter.count);

    return roled(emitter, position, brace.role_block);
}

pub fn parts_role(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    if (emitter.tokens[position].kind == .comment) {
        if (!body.parts_at(emitter, prior, position)) return false;
    }

    if (roled(emitter, prior, brace.role_part)) return true;
    if (emitter.depth == 0) return false;

    const frame = emitter.nest[emitter.depth - 1];
    if (frame.close != position) return false;
    return roled(emitter, frame.open, brace.role_part);
}

pub fn hugged(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    if (bodied(emitter, position)) return false;

    const held = if (emitter.policy.hug_braces)
        line.inline_item(emitter, position)
    else
        emitter.tokens[prior].end() == emitter.tokens[position].offset;

    if (line.word_is(emitter, prior, emitter.policy.hug_words)) {
        if (held) return true;
    }

    if (opens_a_block(emitter, position)) return false;

    const spans = emitter.policy.brace_spans or line.inline_item(emitter, position);

    if (spans) {
        if (pathed(emitter, prior)) return true;
    }

    if (spans) {
        if (emitter.policy.brace_hugs) {
            if (operand_at(emitter, prior)) return true;
            if (split.closes_a_value(emitter, prior)) return true;
        }
    }

    if (!line.inline_item(emitter, position)) return false;
    return line.word_is(emitter, prior, emitter.policy.tight_words);
}

pub fn opens_a_block(emitter: *const Emitter, position: u32) bool {
    assert(emitter.count == emitter.tokens.len);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.structured) return false;
    assert(position < emitter.count);

    const held = ahead_of(emitter, position) orelse return false;
    if (emitter.tokens[held].kind != .keyword) return false;
    return !line.word_is(emitter, held, emitter.policy.operand_words);
}

pub fn ranges(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const current = emitter.tokens[position];
    if (!current.is_punctuation(.dot)) return false;
    if (current.length < 2) return false;

    const spelling = current.text(emitter.source);
    if (!std.mem.startsWith(u8, spelling, ".")) return false;

    for (spelling) |byte| {
        if (std.ascii.isDigit(byte)) return false;
    }

    return true;
}

pub fn spaced_dot(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    if (!is_dot(emitter, prior)) return false;
    if (emitter.tokens[position].kind == .string) return true;

    const held = emitter.tokens[prior];
    const current = emitter.tokens[position];
    if (held.end() >= current.offset) return false;
    if (current.offset >= emitter.source.len) return false;
    return std.ascii.isDigit(emitter.source[current.offset]);
}

pub fn is_dot(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const current = emitter.tokens[position];

    if (current.is_punctuation(.dot)) {
        if (current.length == 1) return true;
    }

    return walk.text_is(current.text(emitter.source), "?.");
}

pub fn operand_at(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (walk.ends_operand(emitter.tokens[position].kind)) return true;
    return line.word_is(emitter, position, emitter.policy.operand_words);
}

pub fn pathed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[position].is_punctuation(.colon)) return false;
    if (position == 0) return false;
    return doubled(emitter, position - 1);
}

pub fn doubled(emitter: *const Emitter, position: u32) bool {
    assert(position < std.math.maxInt(u32));
    assert(emitter.count == emitter.tokens.len);

    if (position + 1 >= emitter.count) return false;

    const held = emitter.tokens[position];
    const after = emitter.tokens[position + 1];
    if (held.end() != after.offset) return false;
    if (held.length != after.length) return false;
    return walk.text_eql(held.text(emitter.source), after.text(emitter.source));
}

pub fn prefixed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (position == 0) return false;

    const held = position - 1;
    if (!line.word_is(emitter, held, emitter.policy.prefix_words)) return false;
    return emitter.tokens[held].end() == emitter.tokens[position].offset;
}

pub fn pointed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (pointing(emitter, position)) return true;
    if (position == 0) return false;
    return pointing(emitter, position - 1);
}

fn pointing(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.policy.arrow_after.len == 0) return false;
    if (position == 0) return false;
    if (position + 1 >= emitter.count) return false;

    const held = emitter.tokens[position];
    const after = emitter.tokens[position + 1];

    if (held.length != 1) return false;
    if (after.length != 1) return false;
    if (held.end() != after.offset) return false;
    if (emitter.source[held.offset] != '-') return false;
    if (emitter.source[after.offset] != '>') return false;
    return line.word_is(emitter, position - 1, emitter.policy.arrow_after);
}

fn suppresses_arrow(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(arrow(emitter, position));

    if (emitter.previous) |held| {
        if (split.directs(emitter, held, position)) return false;
    }

    if (emitter.starting) return true;

    const held = emitter.previous orelse return true;

    assert(held < position);

    if (!walk.ends_operand(emitter.tokens[held].kind)) return true;
    if (!follows_a_hug_word(emitter, position)) return false;
    return adjacent(emitter, position);
}

fn follows_a_hug_word(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = ahead_of(emitter, position) orelse return false;

    assert(held > position);

    return line.word_is(emitter, held, emitter.policy.hug_words);
}

pub fn arrow(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const current = emitter.tokens[position];
    if (current.length != 2) return false;
    return walk.text_is(current.text(emitter.source), "<-");
}

pub fn ellipsis(emitter: *const Emitter, position: u32) bool {
    assert(position < std.math.maxInt(u32) - 2);
    assert(emitter.count == emitter.tokens.len);

    if (position + 2 >= emitter.count) return false;

    for (0..3) |offset| {
        const held = emitter.tokens[position + offset];
        if (held.length != 1) return false;
        if (emitter.source[held.offset] != '.') return false;
    }

    return true;
}

pub fn empties(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.bracket_types) return false;
    if (!emitter.tokens[position].is_punctuation(.bracket_open)) return false;

    const held = ahead_of(emitter, position) orelse return false;
    return emitter.tokens[held].is_punctuation(.bracket_close);
}

fn types_at(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.bracket_types) return false;
    if (!emitter.tokens[position].is_punctuation(.bracket_close)) return false;
    return !emitter.closed.index;
}

pub fn opened(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const kind = emitter.tokens[position].kind;
    if (walk.is_close(kind)) return emitter.brackets.open_of(position);
    if (kind == .identifier) return emitter.brackets.identifier_open_of(position);
    return reach.opened(emitter.source, emitter.tokens, position);
}

pub fn back_of(emitter: *const Emitter, position: u32) ?u32 {
    assert(position <= emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = position;

    while (scan > 0) {
        scan -= 1;

        const held = emitter.tokens[scan];

        if (held.kind != .newline) {
            if (held.length > 0) return scan;
        }
    }

    return null;
}

pub fn ahead_of(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < std.math.maxInt(u32));
    assert(emitter.count == emitter.tokens.len);

    var scan = position + 1;

    while (scan < emitter.count) : (scan += 1) {
        const held = emitter.tokens[scan];

        if (held.kind != .newline) {
            if (held.length > 0) {
                assert(scan <= emitter.count);

                return scan;
            }
        }
    }

    return null;
}

pub fn word_before(emitter: *const Emitter, position: u32) ?u32 {
    assert(position <= emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = position;

    while (scan > 0) {
        scan -= 1;

        const held = emitter.tokens[scan];

        if (held.kind != .newline) {
            if (held.length > 0) return scan;
        }
    }

    return null;
}

pub fn defined_brace(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.tokens[open].kind != .block_start) return false;

    const name = back_of(emitter, open) orelse return false;
    if (emitter.tokens[name].kind != .identifier) return false;
    return defining(emitter, dollared(emitter, name));
}

fn dollared(emitter: *const Emitter, name: u32) u32 {
    assert(name < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const found = back_of(emitter, name) orelse return name;

    assert(found < name);

    if (!walk.text_is(emitter.tokens[found].text(emitter.source), "$")) return name;
    return found;
}

pub fn defined_branch(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.macro_bodies) return false;

    var index = emitter.depth;

    while (index > 0) {
        index -= 1;

        const frame = emitter.nest[index];
        if (frame.open < open) return defined_brace(emitter, frame.open);
    }

    return false;
}

pub fn branch_tailed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.tokens[position].kind != .block_end) return false;

    const open = emitter.brackets.open_of(position) orelse return false;
    if (!defined_brace(emitter, open)) return false;
    if (!ruled(emitter, open)) return false;
    if (!branch_fits(emitter, open, position)) return false;

    const held = back_of(emitter, position) orelse return false;
    return emitter.tokens[held].kind == .block_end;
}

fn branch_fits(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const indent = wide.indent_of(emitter, open) + 2 * emitter.options.indent_width;
    const room = emitter.options.line_width -| indent;
    const source_end: u32 = @intCast(emitter.source.len);
    const stop = @min(emitter.tokens[close].offset, source_end);
    var start = emitter.tokens[open].end();

    while (start < stop) {
        const found = std.mem.findScalar(u8, emitter.source[start..stop], '\n');
        const end: u32 = if (found) |at| start + @as(u32, @intCast(at)) else stop;
        const head = std.mem.trimStart(u8, emitter.source[start..end], whitespace_line);

        assert(end <= stop);

        if (!std.mem.startsWith(u8, head, "//")) {
            if (walk.columns(emitter.source, start, end) > room) return false;
        }

        start = end + 1;
    }

    return true;
}

fn ruled(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.tokens[open].kind == .block_start);

    const name = back_of(emitter, open) orelse return false;
    const bang = word_before(emitter, dollared(emitter, name)) orelse return false;

    return emitter.tokens[bang].is_punctuation(.bang);
}

pub fn jump_tailed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.macro_bodies) return false;
    if (emitter.tokens[position].kind != .block_end) return false;

    const open = emitter.brackets.open_of(position) orelse return false;
    if (!split.body_defined(emitter, open)) return false;
    if (defined_brace(emitter, open)) return false;
    if (defined_branch(emitter, open)) return false;

    var scan = position;

    for (0..core.define_scan_max) |_| {
        const held = back_of(emitter, scan) orelse return false;
        const jumped = emitter.tokens[held];

        if (held <= open) return false;
        if (jumped.is_punctuation(.semicolon)) return false;

        if (walk.is_close(jumped.kind)) {
            scan = emitter.brackets.open_of(held) orelse return false;

            continue;
        }

        if (line.word_is(emitter, held, core.jump_words)) return jump_led(emitter, held, open);

        scan = held;
    }

    return false;
}

fn jump_led(emitter: *const Emitter, held: u32, open: u32) bool {
    assert(open < held);
    assert(held < emitter.count);

    const before = back_of(emitter, held) orelse return false;
    if (before == open) return true;

    const kind = emitter.tokens[before].kind;
    if (kind == .block_end) return true;
    return kind.eql(.{ .punctuation = .semicolon });
}

pub fn defining(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const bang = word_before(emitter, position) orelse return false;

    if (emitter.policy.macro_defines) {
        if (walk.text_is(emitter.tokens[bang].text(emitter.source), "macro")) return true;
    }

    if (!emitter.tokens[bang].is_punctuation(.bang)) return false;

    const word = word_before(emitter, bang) orelse return false;
    return walk.text_is(emitter.tokens[word].text(emitter.source), "macro_rules");
}

fn opening_at(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const current = emitter.tokens[position];
    if (current.kind == .block_start) return true;
    return walk.substituting(emitter.source, current);
}

pub fn closing(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (opening_at(emitter, position)) return emitter.brackets.close_of(position);

    const block = emitter.brackets.block_after(position) orelse return null;
    if (emitter.tokens[block].kind == .block_end) return null;
    return emitter.brackets.close_of(block);
}

pub fn typing(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var held = position;

    while (held < emitter.count) {
        if (line.word_is(emitter, held, emitter.policy.type_words)) {
            if (ahead_of(emitter, held)) |name| {
                if (emitter.tokens[name].kind == .identifier) return true;
            }
        }

        if (!line.word_is(emitter, held, emitter.policy.type_leads)) return false;

        const after = ahead_of(emitter, held) orelse return false;

        assert(after > held);

        held = after;
    }

    return false;
}

pub fn valued_colon(emitter: *const Emitter, prior: u32) bool {
    assert(prior < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.chain_simples) return false;
    if (!emitter.policy.assign_groups) return false;
    if (emitter.depth == 0) return false;

    const frame = emitter.nest[emitter.depth - 1];
    if (frame.valued.keyed == 0) return false;
    return frame.valued.keyed == prior;
}

pub fn brace_joined(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    if (!emitter.policy.chain_simples) return false;
    if (emitter.tokens[position].kind != .block_start) return false;
    if (!emitter.tokens[prior].is_punctuation(.colon)) return false;
    if (!line.clauses(emitter, prior)) return false;
    return case_sole(emitter, position);
}

pub fn body_brace_joined(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    if (!emitter.policy.chain_simples) return false;
    if (emitter.tokens[position].kind != .block_start) return false;
    if (!brace_headed(emitter, prior)) return false;
    if (!body.bodied_brace(emitter, position)) return false;
    return !semi.classed_head(emitter, position);
}

fn brace_headed(emitter: *const Emitter, prior: u32) bool {
    assert(prior < emitter.count);
    assert(emitter.policy.chain_simples);

    const held = emitter.tokens[prior];

    switch (held.kind) {
        .identifier, .keyword => return true,
        .punctuation => |punctuation| {
            if (punctuation == .bracket_close) return true;
            if (punctuation == .paren_close) return true;
        },
        .block_end, .block_start, .comment, .newline, .number, .string => {},
    }

    const spelling = held.text(emitter.source);
    if (walk.text_is(spelling, "=>")) return true;
    return walk.text_is(spelling, ">");
}

pub fn wrap_headed(emitter: *const Emitter) bool {
    assert(emitter.wraps_owed <= core.wrap_depth_max);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.assign_lines) return false;
    if (emitter.wraps_owed == 0) return false;

    const prior = emitter.previous orelse return false;
    if (prior != emitter.wrapped[wrap.run_top(emitter)].start) return false;
    return !span.paren_run(emitter);
}

pub fn macro_bracket(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const kind = emitter.tokens[position].kind;
    if (kind == .block_start) return false;
    return walk.is_open(kind);
}

pub fn restreamed(emitter: *Emitter, position: u32, close: u32) error{Overflow}!void {
    assert(position <= close);
    assert(close < emitter.count);

    const from = emitter.tokens[position].offset;
    const bytes = emitter.source[from..emitter.tokens[close].end()];
    const tabbed = std.mem.findScalar(u8, bytes, '\t') != null;

    if (emitter.options.tabs) return spanned(emitter, position, close);
    if (!tabbed) return spanned(emitter, position, close);

    if (stream.spilled(emitter.tokens, emitter.source, position, close)) {
        return spanned(emitter, position, close);
    }

    emitter.previous = close;
    emitter.resume_at = close + 1;
    emitter.suppress_space = false;

    const offset = emitter.arena.count();

    stream.restreamed(emitter.arena, bytes, emitter.options.indent_width) catch |err| {
        emitter.arena.truncate(offset);

        return err;
    };

    assert(emitter.arena.count() >= offset);

    try emitter.document.push(.{ .verbatim_arena = .{
        .offset = offset,
        .length = emitter.arena.count() - offset,
    } });
}

pub fn spanned(emitter: *Emitter, position: u32, close: u32) error{Overflow}!void {
    assert(position <= close);
    assert(close < emitter.count);

    const from = emitter.tokens[position].offset;
    const to = emitter.tokens[close].end();

    emitter.previous = close;
    emitter.resume_at = close + 1;
    emitter.suppress_space = false;

    if (origined(emitter, position, close)) |held| {
        return emitter.document.push(.{ .verbatim_arena = held });
    }

    assert(from <= to);

    try emitter.document.push(.{ .verbatim = .{ .offset = from, .length = to - from } });
}

fn origined(emitter: *Emitter, position: u32, close: u32) ?Span {
    assert(position <= close);
    assert(close < emitter.count);

    if (close >= emitter.origins.len) return null;

    const from = emitter.origins[position];
    const held = emitter.origins[close];
    const to = std.math.add(u32, held, emitter.tokens[close].length) catch return null;

    if (from == std.math.maxInt(u32)) return null;
    if (held == std.math.maxInt(u32)) return null;
    if (to > emitter.origin.len) return null;
    if (to <= from) return null;

    const offset = emitter.arena.count();

    emitter.arena.push(emitter.origin[from..to]) catch {
        emitter.arena.truncate(offset);

        return null;
    };

    assert(emitter.arena.count() > offset);

    return .{ .offset = offset, .length = emitter.arena.count() - offset };
}

pub fn opened_type(spelled: []const u8, angles: *u32, brackets: *u32) void {
    assert(spelled.len <= std.math.maxInt(u32));
    assert(angles.* <= std.math.maxInt(u32));

    if (walk.text_is(spelled, "<")) {
        angles.* += 1;

        return;
    }

    if (list.closes_angle(spelled)) {
        angles.* -|= @intCast(spelled.len);

        return;
    }

    if (walk.text_is(spelled, "[")) {
        brackets.* += 1;

        return;
    }

    if (walk.text_is(spelled, "]")) brackets.* -|= 1;
}

fn ternary_leveled(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.chain_simples) return;
    if (!tern.ternary_parted(emitter, position)) return;

    const wanted = tern.ternary_wanted(emitter, position) orelse return;

    try line.level(emitter, wanted);

    if (emitter.printed <= wanted) return;
    if (!walk.text_is(emitter.tokens[position].text(emitter.source), "?")) return;
    if (emitter.line_first <= tern.ternary_test(emitter, position)) return;
    if (emitter.line_first >= position) return;

    emitter.printed = wanted;
}

fn parts(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    try comment.run_leveled(emitter);

    const blanked = emitter.policy.spread_blanks or header.params_framed(emitter);

    if (blanked) {
        if (parts_blanked(emitter, position)) {
            try emitter.document.push(.hard_line);
            try emitter.document.push(.{ .blank_line = 1 });

            return;
        }
    }

    const held = line.frame(emitter);
    const clausing = held.spread == .clauses;
    const claused = clausing and comment.header_clauses(emitter, held.open);
    var commented = false;

    if (emitter.previous) |prior| {
        const prior_token = emitter.tokens[prior];
        const slashed = std.mem.startsWith(u8, prior_token.text(emitter.source), "//");
        const lined = prior_token.kind == .comment and slashed;

        commented = lined or comment.leads_line(emitter, prior);
    }

    const chained = list.chains_a_header(emitter) and list.operating(emitter, position);
    const softened: ir.Element = if (chained and !claused) .soft_line else .line;
    const element: ir.Element = if (commented) .hard_line else softened;

    try sole.soled_open(emitter);
    try emitter.document.push(element);
}

fn parts_blanked(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (span.wrapped_run(emitter, position)) return false;
    if (comment.part_blanked(emitter)) return false;
    if (list.tuple_blanked(emitter)) return false;
    if (tern.ternary_blank(emitter, position)) return false;

    if (emitter.depth > 0) {
        if (split.specifier_open(emitter, line.frame(emitter).open)) return false;
    }

    const held = emitter.previous orelse return false;
    if (!list.blanked(emitter, held, position)) return false;
    return !comment.dangling_part(emitter, position, held);
}

fn value_lined(emitter: *Emitter) error{Overflow}!void {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.depth == 0) return;

    const prior = emitter.previous orelse return;
    if (!valued_colon(emitter, prior)) return;

    const index = emitter.depth - 1;
    if (emitter.nest[index].valued.shut != emitter.nest[index].valued.keyed) return;

    emitter.nest[index].valued.shut = 0;

    try emitter.document.push(.group_close);
}

fn marks(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.depth > 0);

    if (!own.hugging(emitter, position)) return;

    var casted_open = false;

    if (back_of(emitter, position)) |held| {
        if (wrap.cast_open(emitter, held)) |open| casted_open = join.cast_hugged(emitter, open);
    }

    const element: ir.Element = if (casted_open) .heads else .hugged;

    try emitter.document.push(element);
}

fn opens(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.depth > 0);
    assert(emitter.nest[emitter.depth - 1].open == position);

    const spread = emitter.nest[emitter.depth - 1].spread;
    const kind = emitter.tokens[position].kind;
    const filled = spread == .fill;

    emitter.nest[emitter.depth - 1].grouped = emitter.document.count();

    const shared = emitter.shared == position;
    var sharing = shared;

    if (join.closing_of(emitter, position)) |close| {
        if (list.pattern_shared(emitter, position, close) != null) sharing = true;
    }

    if (shared) emitter.shared = std.math.maxInt(u32);

    const parted = opens_parted(emitter, position, spread, sharing);
    const edged_line: ir.Element = if (parted) .hard_line else list.edged(kind);
    const sequenced = spread != null and list.arrow_sequenced(emitter, position);

    if (!shared) try emitter.document.push(.group_open);
    if (filled) try emitter.document.push(.{ .filled = emitter.policy.fill_reserve });

    if (!filled) {
        if (!shared) try call.reach_marks(emitter, position);
    }

    try line.opens_broken(emitter);
    try emitter.document.push(edged_line);

    if (sequenced) try emitter.document.push(.group_open);
}

fn opens_parted(emitter: *const Emitter, position: u32, spread: ?core.Spread, sharing: bool) bool {
    assert(position < emitter.count);
    assert(emitter.depth > 0);

    const kind = emitter.tokens[position].kind;
    const closed = join.closing_of(emitter, position);

    if (!sharing) {
        if (kind == .block_start) {
            if (opens_block_parted(emitter, position, closed)) return true;
        }
    }

    if (parted_params(emitter, position)) return true;
    if (list.sole_return_forced(emitter, position)) return true;
    if (list.signature_wide(emitter, position)) return true;
    if (list.arrow_signature_wide(emitter, position)) return true;

    if (closed) |close| {
        if (span.union_returned(emitter, position, close)) return true;
    }

    if (parted_generics(emitter, position)) return true;

    if (kind == .block_start) {
        if (body.declared(emitter, position)) return true;
    }

    if (call.composed_args(emitter, position)) return true;
    if (call.curried_args(emitter, position)) return true;

    const close = closed orelse return false;
    if (call.arrow_typed_wide(emitter, position, close)) return true;
    if (call.arrow_generics_wide(emitter, position)) return true;
    if (span.spread_matrix(emitter, position, close)) return true;
    if (mark_of(emitter, position) & brace.mark_expanded != 0) return true;
    if (list.pattern_broken(emitter, position, close)) return true;
    if (spread == null) return false;
    if (list.spread_commented(emitter, position, close)) return true;
    return list.comments_only(emitter, position, close);
}

fn opens_block_parted(emitter: *const Emitter, position: u32, closed: ?u32) bool {
    assert(position < emitter.count);
    assert(emitter.tokens[position].kind == .block_start);
    if (closed) |held| assert(held < emitter.count);

    if (closed) |close| {
        if (list.pattern_typing(emitter, position, close) != null) return false;
        if (list.pattern_named(emitter, position, close) != null) return false;
        if (bind.pattern_assigned(emitter, position, close)) return false;
    }

    if (list.param_type_unparted(emitter, position)) return false;
    if (list.mapped_expanded(emitter, position)) return true;

    const held = ahead_of(emitter, position) orelse return false;
    return body.parts_at(emitter, position, held);
}

fn parted_generics(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.generic_parts) return false;
    if (!line.define_parted(emitter, position)) return false;

    const angle = back_of(emitter, position) orelse return false;
    if (!walk.text_is(emitter.tokens[angle].text(emitter.source), ">")) return false;

    const held = back_of(emitter, angle) orelse return false;
    return body.parts_at(emitter, held, angle);
}

fn parted_params(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.policy.parameter_words.len == 0) return false;
    if (!emitter.tokens[position].is_punctuation(.paren_open)) return false;

    const close = join.closing_of(emitter, position) orelse return false;
    var angles: u32 = 0;
    var commas: u32 = 0;
    var depth: u32 = 0;
    var held = false;

    assert(close > position);

    for (position + 1..close) |index| {
        const scan: u32 = @intCast(index);
        const current = emitter.tokens[scan];
        var bracketed: u32 = 0;

        opened_type(current.text(emitter.source), &angles, &bracketed);

        if (walk.is_open(current.kind)) {
            depth += 1;
        } else if (walk.is_close(current.kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (angles == 0) {
                const shut = if (ahead_of(emitter, scan)) |ahead| ahead == close else false;
                const parting = current.is_punctuation(.comma) and !shut;

                commas += @intFromBool(parting);

                if (span.property_head(emitter, scan)) held = true;
            }
        } else {}
    }

    return held and commas > 0;
}

fn closes(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.depth > 0);

    try own.arrow_chain_overdue(emitter, position);
    try inset(emitter);

    const held = emitter.nest[emitter.depth - 1];
    const typed = closes_typed(emitter, held, position);
    const braced = emitter.tokens[position].kind == .block_end;
    const semicolon_ended = typed and braced;
    const separator = if (semicolon_ended) emitter.semicolon else emitter.comma;
    const edged_line = list.edged(held.kind);
    const chained = held.spread == .chain or held.spread == .clauses;

    if (chained) {
        var spaced = false;

        if (emitter.previous) |prior| {
            if (emitter.tokens[prior].is_punctuation(.semicolon)) {
                spaced = comment.header_clauses(emitter, held.open);
            }
        }

        try line.closes_broken(emitter);

        const element: ir.Element = if (spaced) .line else edged_line;
        return emitter.document.push(element);
    }

    if (list.arrow_sequenced(emitter, held.open)) try emitter.document.push(.group_close);

    if (!closes_trailed(emitter, held, position)) {
        try emitter.document.push(.{ .if_broken = separator });
    }

    if (own.trailed_standing(emitter, position)) try emitter.document.push(.broken);

    try line.closes_broken(emitter);
    try emitter.document.push(edged_line);
}

fn closes_typed(emitter: *const Emitter, held: core.Frame, position: u32) bool {
    assert(held.open < position);
    assert(position < emitter.count);

    if (emitter.typed) {
        if (!list.pattern_separated(emitter, held.open)) return true;
    }

    if (span.typed_brace(emitter, position)) return true;
    return span.type_closed(emitter, position);
}

fn closes_trailed(emitter: *const Emitter, held: core.Frame, position: u32) bool {
    assert(held.open < position);
    assert(position < emitter.count);

    if (span.spread_rest(emitter, position)) return true;
    if (list.pattern_rested(emitter, position)) return true;
    if (own.trailed_already(emitter, position)) return true;
    if (list.paren_grouped(emitter, held.open, position)) return true;

    if (emitter.tokens[held.open].is_punctuation(.paren_open)) {
        if (sole.cast_commented(emitter, held.open)) return true;
    }

    if (!list.cast_tupled(emitter, held.open)) {
        if (list.bracket_grouped(emitter, held.open, position)) return true;
        if (list.bracket_lookup(emitter, held.open)) return true;
    }

    if (call.imported(emitter, held.open)) return true;
    if (call.required_alias(emitter, held.open)) return true;
    if (list.mapped_key(emitter, held.open)) return true;
    if (list.commented_alone(emitter, held.open, position)) return true;

    const prior = back_of(emitter, position) orelse return false;
    return list.hole_comma(emitter, prior);
}

fn soled(emitter: *Emitter, position: u32, close: u32, hug: bool) error{Overflow}!void {
    assert(position < close);
    assert(close < emitter.count);

    try emitter.document.push(.{ .verbatim = written(emitter, position) });

    if (!hug) try emitter.document.push(.space);

    try listing(emitter, position, close, false);

    emitter.closed = core.Frame.empty;
    emitter.closed.close = close;
    emitter.closed.open = position;
    emitter.previous = close;
    emitter.resume_at = close + 1;
    emitter.suppress_space = false;

    if (!hug) try emitter.document.push(.space);

    try emitter.document.push(.{ .verbatim = written(emitter, close) });
}

fn grouped(emitter: *Emitter, position: u32, close: u32) error{Overflow}!void {
    assert(position < close);
    assert(close < emitter.count);

    const hug = emitter.policy.list_hugs;
    const sole_list = !list.separated(emitter, position, close);
    const wide_list = sole_list and wide.import(emitter, position);

    if (sole_list) {
        if (!wide_list) return soled(emitter, position, close, hug);
    }

    const broken = wide_list or wide.used(emitter, position) or
        nested_list(emitter, position, close) or
        exported_expanded(emitter, position, close);

    const hugged_line: ir.Element = if (hug) .soft_line else .line;
    const edged_line: ir.Element = if (broken) .hard_line else hugged_line;
    const filled = emitter.policy.list_fills;

    try emitter.document.push(.{ .verbatim = written(emitter, position) });
    try emitter.document.push(.group_open);
    try emitter.document.push(.indent);
    try emitter.document.push(edged_line);

    if (filled) {
        try emitter.document.push(.group_open);
        try emitter.document.push(.{ .filled = emitter.policy.fill_reserve });
    }

    try listing(emitter, position, close, filled);

    emitter.closed = core.Frame.empty;
    emitter.closed.close = close;
    emitter.closed.open = position;
    emitter.previous = close;
    emitter.resume_at = close + 1;
    emitter.suppress_space = false;

    if (filled) try emitter.document.push(.group_close);

    try emitter.document.push(.{ .if_broken = emitter.comma });
    try emitter.document.push(.dedent);
    try emitter.document.push(edged_line);
    try emitter.document.push(.{ .verbatim = written(emitter, close) });
    try emitter.document.push(.group_close);
}

fn exported_expanded(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const word = word_before(emitter, open) orelse return false;
    var head = word;

    if (walk.text_is(emitter.tokens[word].text(emitter.source), "type")) {
        head = word_before(emitter, word) orelse return false;
    }

    if (!walk.text_is(emitter.tokens[head].text(emitter.source), "export")) return false;

    const after = ahead_of(emitter, close) orelse return false;
    if (!walk.text_is(emitter.tokens[after].text(emitter.source), "from")) return false;

    const first = ahead_of(emitter, open) orelse return false;
    return body.parts_at(emitter, open, first);
}

fn listing(emitter: *Emitter, position: u32, close: u32, filled: bool) error{Overflow}!void {
    assert(position < close);
    assert(close < emitter.count);

    const nested = nested_list(emitter, position, close);
    var count: u32 = 0;
    var held: [core.list_item_max]Span = @splat(.{ .offset = 0, .length = 0 });
    var scan = position + 1;

    while (scan < close) {
        const stop = list.parted_at(emitter, scan, close);

        assert(stop >= scan);

        if (scan < stop) {
            if (count == core.list_item_max) return ordered(emitter, position, close);

            const offset = emitter.arena.count();

            try list.written_into(emitter, scan, stop);

            held[count] = .{ .offset = offset, .length = emitter.arena.count() - offset };
            count += 1;
        }

        scan = stop + 1;
    }

    if (emitter.policy.list_sorts) text.sorted(emitter.arena.const_slice(), held[0..count]);

    for (0..count) |index| {
        if (index > 0) {
            const pathed_pair = item_pathed(emitter, held[index]) or
                item_pathed(emitter, held[index - 1]);

            const broken = filled and nested and pathed_pair;

            try separates_at(emitter, broken);
        }

        try listed_item(emitter, held[index], nested);
    }
}

fn listed_item(emitter: *Emitter, held: Span, nested: bool) error{Overflow}!void {
    assert(held.offset <= emitter.arena.count());
    assert(held.length <= emitter.arena.count() - held.offset);

    const brace_at = if (nested) item_braced(emitter, held, 1) else null;
    const curly = brace_at orelse return emitter.document.push(.{ .verbatim_arena = held });

    try listed_open(emitter, held, curly);
    try listed_inner(emitter, held.offset + curly + 1, held.offset + held.length - 1);
    try listed_shut(emitter, held);
}

fn listed_leaf(emitter: *Emitter, held: Span) error{Overflow}!void {
    assert(held.offset <= emitter.arena.count());
    assert(held.length <= emitter.arena.count() - held.offset);

    const curly = item_braced(emitter, held, 2) orelse
        return emitter.document.push(.{ .verbatim_arena = held });

    try listed_open(emitter, held, curly);
    try listed_flat(emitter, held.offset + curly + 1, held.offset + held.length - 1);
    try listed_shut(emitter, held);
}

fn listed_open(emitter: *Emitter, held: Span, curly: u32) error{Overflow}!void {
    assert(curly + 1 < held.length);

    const head: Span = .{ .offset = held.offset, .length = curly + 1 };

    try emitter.document.push(.{ .verbatim_arena = head });
    try emitter.document.push(.group_open);
    try emitter.document.push(.indent);
    try emitter.document.push(.hard_line);

    if (emitter.policy.list_fills) {
        try emitter.document.push(.group_open);
        try emitter.document.push(.{ .filled = emitter.policy.fill_reserve });
    }
}

fn listed_shut(emitter: *Emitter, held: Span) error{Overflow}!void {
    assert(held.length > 0);

    const end: Span = .{ .offset = held.offset + held.length - 1, .length = 1 };

    if (emitter.policy.list_fills) try emitter.document.push(.group_close);

    try emitter.document.push(.{ .if_broken = emitter.comma });
    try emitter.document.push(.dedent);
    try emitter.document.push(.hard_line);
    try emitter.document.push(.{ .verbatim_arena = end });
    try emitter.document.push(.group_close);
}

fn listed_inner(emitter: *Emitter, from: u32, to: u32) error{Overflow}!void {
    assert(from < to);
    assert(to <= emitter.arena.count());

    const bytes = emitter.arena.const_slice();
    const nested = std.mem.findScalar(u8, bytes[from..to], '{') != null;
    const filled = emitter.policy.list_fills and nested;
    var prior: ?Span = null;
    var depth: u32 = 0;
    var start = from;
    var index = from;

    while (index <= to) : (index += 1) {
        const ends = index == to;
        const byte = if (ends) ',' else bytes[index];

        if (byte == '{') depth += 1;
        if (byte == '}') depth -|= 1;
        if (byte != ',') continue;
        if (depth > 0) continue;

        const item: Span = .{ .offset = start, .length = index - start };

        if (prior) |before| {
            const pathed_pair = item_pathed(emitter, before) or item_pathed(emitter, item);

            try separates_at(emitter, filled and pathed_pair);
        }

        try listed_leaf(emitter, item);

        prior = item;
        start = index + 1;

        while (start < to) : (start += 1) {
            if (bytes[start] != ' ') break;
        }
    }

    assert(prior != null);
}

fn listed_flat(emitter: *Emitter, from: u32, to: u32) error{Overflow}!void {
    assert(from < to);
    assert(to <= emitter.arena.count());

    const bytes = emitter.arena.const_slice();
    var start = from;
    var index = from;

    while (index <= to) : (index += 1) {
        const ends = index == to;
        const byte = if (ends) ',' else bytes[index];
        if (byte != ',') continue;

        const item: Span = .{ .offset = start, .length = index - start };

        if (start > from) try separates_at(emitter, false);

        try emitter.document.push(.{ .verbatim_arena = item });

        start = index + 1;

        while (start < to) : (start += 1) {
            if (bytes[start] != ' ') break;
        }
    }
}

fn item_braced(emitter: *const Emitter, held: Span, nesting: u32) ?u32 {
    assert(held.offset <= emitter.arena.count());
    assert(held.length <= emitter.arena.count() - held.offset);
    assert(nesting < std.math.maxInt(u32));

    const bytes = emitter.arena.const_slice()[held.offset..][0..held.length];

    if (emitter.policy.list_width == 0) return null;
    if (bytes.len < 4) return null;
    if (bytes[bytes.len - 1] != '}') return null;

    const curly = std.mem.findScalar(u8, bytes, '{') orelse return null;
    if (curly == 0) return null;
    if (curly + 2 >= bytes.len) return null;

    const seat = (emitter.printed + nesting) * emitter.options.indent_width;
    const columns = walk.columns(bytes, 0, @intCast(bytes.len));
    const inner = bytes[curly + 1 .. bytes.len - 1];
    const deep = std.mem.findScalar(u8, inner, '{') != null;

    if (!deep) {
        if (seat + columns + 1 + list_margin <= emitter.options.line_width) return null;
    }

    assert(curly < std.math.maxInt(u32));

    return @intCast(curly);
}

pub fn list_depth(emitter: *const Emitter, from: u32, to: u32) u32 {
    assert(from <= to);
    assert(to <= emitter.count);

    var depth: u32 = 0;
    var deepest: u32 = 0;

    for (from..to) |scan| {
        const kind = emitter.tokens[scan].kind;

        switch (kind) {
            .block_start => {
                depth += 1;
                deepest = @max(deepest, depth);
            },
            .block_end => depth -|= 1,
            else => {},
        }
    }

    return deepest;
}

fn nested_list(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position < close);
    assert(close < emitter.count);

    if (!emitter.policy.list_sorts) return false;

    for (position + 1..close) |scan| {
        if (emitter.tokens[scan].kind == .block_start) return true;
    }

    return false;
}

fn item_pathed(emitter: *const Emitter, held: Span) bool {
    assert(held.offset <= emitter.arena.count());
    assert(held.length <= emitter.arena.count() - held.offset);

    const bytes = emitter.arena.const_slice()[held.offset..][0..held.length];
    return std.mem.find(u8, bytes, "::") != null;
}

fn ordered(emitter: *Emitter, position: u32, close: u32) error{Overflow}!void {
    assert(position < close);
    assert(close < emitter.count);

    var first = true;
    var scan = position + 1;

    while (scan < close) {
        const stop = list.parted_at(emitter, scan, close);

        assert(stop >= scan);

        if (scan < stop) {
            if (!first) try separates_at(emitter, false);

            try specified(emitter, scan, stop);

            first = false;
        }

        scan = stop + 1;
    }
}

fn specified(emitter: *Emitter, from: u32, to: u32) error{Overflow}!void {
    assert(from < to);
    assert(to <= emitter.count);

    const offset = emitter.arena.count();

    try list.written_into(emitter, from, to);

    assert(emitter.arena.count() >= offset);

    try emitter.document.push(.{ .verbatim_arena = .{
        .offset = offset,
        .length = emitter.arena.count() - offset,
    } });
}

fn separates_at(emitter: *Emitter, broken: bool) error{Overflow}!void {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.indent <= std.math.maxInt(u32));

    try emitter.document.push(.{ .text = .{ .source = .literal, .span = emitter.comma } });
    try inset(emitter);

    if (!broken) return emitter.document.push(.line);

    try emitter.document.push(.group_close);
    try emitter.document.push(.line);
    try emitter.document.push(.group_open);
    try emitter.document.push(.{ .filled = emitter.policy.fill_reserve });
}

fn inset(emitter: *Emitter) error{Overflow}!void {
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.chain_simples) return;
    if (emitter.depth == 0) return;

    const wanted = emitter.nest[emitter.depth - 1].inset;

    assert(emitter.policy.chain_simples);

    try line.level(emitter, wanted);
}

pub fn defined_body(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.macro_bodies) return null;
    if (emitter.tokens[open].kind != .block_start) return null;
    if (!defined_branch(emitter, open)) return null;

    const before = back_of(emitter, open) orelse return null;
    if (!walk.text_is(emitter.tokens[before].text(emitter.source), "=>")) return null;

    const close = join.closing_of(emitter, open) orelse return null;
    const first = ahead_of(emitter, open) orelse return null;
    if (first >= close) return null;
    if (emitter.tokens[first].kind == .block_start) return null;
    return open;
}

pub fn welded_body(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.macro_bodies) return false;
    if (emitter.tokens[open].kind != .block_start) return false;

    const before = back_of(emitter, open) orelse return false;
    if (!walk.text_is(emitter.tokens[before].text(emitter.source), "=>")) return false;
    if (!defined_branch(emitter, open)) return false;

    const first = ahead_of(emitter, open) orelse return false;
    return emitter.tokens[first].kind == .block_start;
}

pub fn word_previous(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    return back_of(emitter, position);
}
