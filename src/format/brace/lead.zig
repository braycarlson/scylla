const std = @import("std");
const assert = std.debug.assert;
const assembly = @import("assembly.zig");
const bind = @import("bind.zig");
const brace = @import("../brace.zig");
const call = @import("call.zig");
const clause = @import("clause.zig");
const comment = @import("comment.zig");
const core = @import("emitter.zig");
const emit = @import("emit.zig");
const header = @import("header.zig");
const heritage = @import("heritage.zig");
const items = @import("items.zig");
const join = @import("join.zig");
const level = @import("level.zig");
const line = @import("line.zig");
const link = @import("link.zig");
const list = @import("list.zig");
const own = @import("own.zig");
const span = @import("span.zig");
const split = @import("split.zig");
const tern = @import("tern.zig");
const unite = @import("unite.zig");
const walk = @import("../walk.zig");
const Emitter = core.Emitter;

const assign_words: []const []const u8 = &.{
    "%=",
    "&=",
    "*%=",
    "*=",
    "*|=",
    "+%=",
    "+=",
    "+|=",
    "-%=",
    "-=",
    "-|=",
    "/=",
    "<<=",
    "<<|=",
    "=",
    ">>=",
    "^=",
    "|=",
};

const bar_columns: u32 = 2;
const spread_item_max: u32 = 4096;

const Lead = struct {
    bodies: ?u32,
    branch: ?u32,
    ending: bool,
    held: bool,
    leading: u32,
    popped: ?u32,
    position: u32,
};

const catch_words: []const []const u8 = &.{"catch"};
const caught_scan_max: u32 = 4;

pub fn leads(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(emitter.assigns == 0);
    assert(position < emitter.count);

    const parted = span.member_parted(emitter, position);

    emit.declares_closed(emitter, position);

    emitter.line_before = emitter.line_first;
    emitter.line_first = position;

    const leading = if (emitter.tokens[position].kind == .comment)
        line.coding(emitter, position) orelse position
    else
        position;

    emitter.chained = line.chains(emitter, leading);

    const popped = line.popped(emitter, leading);
    const held = popped == null and line.continues(emitter, leading, true);

    const ending = emitter.policy.header_levels and
        line.word_is(emitter, leading, emitter.policy.level_words);

    const branch = if (ending) line.branch_level(emitter) else null;
    const bodied = held and branch == null;
    const bodies = if (bodied) line.header_level(emitter, leading) else null;
    const carries = popped == null and line.continues(emitter, leading, false);

    const lead: Lead = .{
        .bodies = bodies,
        .branch = branch,
        .ending = ending,
        .held = held,
        .leading = leading,
        .popped = popped,
        .position = position,
    };

    const wanted = leads_wanted(emitter, &lead);
    const based = leads_based(emitter, &lead, wanted);
    const stepped = based + owings(emitter, parted);
    const opens = carries and (bodies == null or leading != position);

    leads_settled(emitter, &lead, opens, stepped);

    try line.level(emitter, stepped + step_of(emitter, leading));

    const newest = (emitter.lined + core.line_level_max - 1) % core.line_level_max;

    assert(emitter.lines[newest].start <= position);

    emitter.printed = stepped;

    line.rings(emitter, position, stepped);
    emitter.line_start = false;
}

fn leads_wanted(emitter: *Emitter, lead: *const Lead) u32 {
    assert(lead.position < emitter.count);
    assert(lead.leading < emitter.count);

    const kept = else_comment(emitter, lead.position, lead.leading, lead.ending) or
        strung_on(emitter, lead.leading) or
        line.string_commented(emitter, lead.position) or
        unite.decorator_kept(emitter, lead.position);

    if (kept) return emitter.printed;
    if (operator_level(emitter)) |found| return found;
    if (seated(emitter, lead)) |found| return found;
    if (lead.held) return carrying(emitter, lead.bodies);
    return emitter.levels;
}

fn leads_based(emitter: *Emitter, lead: *const Lead, wanted: u32) u32 {
    assert(lead.position < emitter.count);
    assert(lead.leading < emitter.count);
    assert(wanted < std.math.maxInt(u32));

    const leading: ?u32 = if (lead.held) lead.leading else null;
    if (line.bound_level(emitter, lead.leading) != null) return wanted;

    const bound = if (emitter.policy.binding_words.len == 0)
        wanted
    else
        line.bounded(emitter, wanted, leading);

    if (operator_level(emitter) != null) return wanted;
    if (split.carries(emitter, lead.position)) return emitter.printed;
    return bound;
}

fn leads_settled(emitter: *Emitter, lead: *const Lead, opens: bool, stepped: u32) void {
    assert(lead.position < emitter.count);
    assert(emitter.branched <= core.branch_depth_max);
    assert(stepped < std.math.maxInt(u32));

    if (line.opens_a_clause(emitter, lead.position)) {
        emitter.claused_body = false;
        emitter.claused_depth = emitter.depth;
    }

    const settled = !lead.held and !lead.ending;

    if (settled) {
        while (emitter.branched > 0) {
            if (emitter.branches[emitter.branched - 1].depth < emitter.depth) break;

            emitter.branched -= 1;
        }
    }

    emitter.claused = line.clauses(emitter, lead.position);
    emitter.continued = opens;

    if (!opens) emitter.based = stepped;

    const declares = emitter.depth == 0 and
        line.word_is(emitter, lead.position, emitter.policy.declare_words);

    if (declares) emitter.declared = lead.position;

    if (emitter.depth == 0) {
        if (!opens) emitter.typed = emit.typing(emitter, lead.position);
    }
}

fn else_comment(emitter: *const Emitter, position: u32, leading: u32, ending: bool) bool {
    assert(position < emitter.count);
    assert(leading < emitter.count);

    if (ending) assert(emitter.policy.header_levels);
    if (!ending) return false;
    if (!emitter.policy.header_levels) return false;
    if (leading == position) return false;

    if (emit.ahead_of(emitter, leading)) |ahead| {
        if (walk.text_is(emitter.tokens[ahead].text(emitter.source), "=>")) return false;
    }

    const before = line.coded(emitter) orelse return false;
    const token = emitter.tokens[before];
    if (token.kind == .block_end) return false;
    if (token.kind == .block_start) return false;
    return !token.is_punctuation(.comma);
}

fn strung_on(emitter: *const Emitter, leading: u32) bool {
    assert(leading < emitter.count);

    if (!emitter.policy.header_levels) return false;
    if (!emit.roled(emitter, leading, brace.role_span)) return false;

    const held = line.coded(emitter) orelse return false;

    assert(held < emitter.count);

    return emit.roled(emitter, held, brace.role_span);
}

fn seated(emitter: *const Emitter, lead: *const Lead) ?u32 {
    assert(lead.position < emitter.count);
    assert(lead.leading < emitter.count);

    const leading = lead.leading;

    return assembly.asm_closed(emitter, leading) orelse
        own.callee_chain_level(emitter, leading) orelse
        line.header_block_level(emitter, leading) orelse
        join.arm_empty_level(emitter, leading) orelse
        join.welded_level(emitter, leading) orelse
        join.angle_comment_level(emitter, leading) orelse
        tern.comment_wrapped(emitter, leading) orelse
        comment.keyword_comment_level(emitter, leading) orelse
        comment.union_comment_level(emitter, lead.position) orelse
        unite.annotation_comment_level(emitter, leading) orelse
        unite.intersect_level(emitter, leading) orelse
        tern.ternary_forced_level(emitter, leading) orelse
        bind.declares_level(emitter, leading) orelse
        clause.else_level(emitter, leading) orelse
        tern.comment_branched(emitter, leading) orelse
        clause.value_level(emitter, leading) orelse
        span.arm_barred(emitter, leading) orelse
        lead.branch orelse
        line.clause_level(emitter, leading) orelse
        lead.popped orelse
        line.bound_level(emitter, leading) orelse
        span.operand_level(emitter, leading) orelse
        line.generic_level(emitter, leading) orelse
        line.barred(emitter, leading) orelse
        line.commented_level(emitter, leading) orelse
        link.chain_cast_close(emitter, leading) orelse
        seated_dedents(emitter, lead.position) orelse
        bind.sequence_level(emitter, leading) orelse
        span.header_bodied(emitter, leading) orelse
        span.binary_level(emitter, leading) orelse
        span.binary_carried(emitter, leading) orelse
        heritage.level_at(emitter, leading) orelse
        unite.union_level(emitter, leading) orelse
        tern.ternary_level(emitter, leading) orelse
        span.operand_level(emitter, leading) orelse
        own.assign_chain_level(emitter, leading) orelse
        span.assign_level(emitter, leading) orelse
        header.brace_level(emitter, leading) orelse
        span.chain_level(emitter, leading);
}

fn seated_dedents(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.line_first == position);

    if (!line.dedents(emitter, position)) return null;
    if (flat_closed(emitter, position)) return emitter.levels;
    assert(emitter.levels -| 1 < std.math.maxInt(u32));

    return emitter.levels -| 1;
}

fn flat_closed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return false;

    const frame = emitter.nest[emitter.depth - 1];
    if (frame.close != position) return false;
    if (frame.indents) return false;
    if (!items.item_flat_at(emitter, frame.open)) return false;
    if (emitter.depth == 1) return true;

    const outer = emitter.nest[emitter.depth - 2];
    if (!emitter.tokens[outer.open].is_punctuation(.paren_open)) return true;
    if (!items.item_lined_at(emitter, outer.open)) return false;

    var after = emit.ahead_of(emitter, position) orelse return false;

    if (emitter.tokens[after].is_punctuation(.comma)) {
        after = emit.ahead_of(emitter, after) orelse return false;
    }

    return after == outer.close;
}

fn carrying(emitter: *Emitter, bodies: ?u32) u32 {
    assert(emitter.line_first < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);
    if (bodies) |held| assert(held < emitter.count);

    if (bodies) |found| {
        line.branch_opened(emitter, found, line.coded(emitter) orelse 0);

        assert(found + 1 <= emitter.count);

        return found + 1;
    }

    if (emitter.chained) {
        if (emitter.policy.link_levels) return link.linked(emitter);
        if (link.dotted(emitter)) |found| return found;
        if (link.sibling(emitter)) |found| return found;
    }

    if (clause.within(emitter)) {
        if (clause.started(emitter)) return clause.base(emitter);
        const returned = @min(clause.base(emitter), emitter.printed) + 1;

        assert(returned < std.math.maxInt(u32));

        return returned;
    }

    if (emitter.continued) {
        if (emitter.policy.nested_levels) {
            const returned = @max(emitter.levels, emitter.based + 1);

            assert(returned < std.math.maxInt(u32));

            return returned;
        }

        return emitter.printed;
    }

    if (emitter.policy.header_levels) {
        if (line.led_tier(emitter, emitter.line_first) != null) {
            if (!pending(emitter)) return emitter.printed;
        }

        assert(emitter.printed + 1 < std.math.maxInt(u32));

        return emitter.printed + 1;
    }

    const returned = @min(@min(emitter.levels, emitter.printed), emitter.indent) + 1;

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn pending(emitter: *const Emitter) bool {
    assert(emitter.line_before < emitter.line_first);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth > 0) {
        const frame = emitter.nest[emitter.depth - 1];
        const opened = frame.open >= emitter.line_before;
        const paren = emitter.tokens[frame.open].is_punctuation(.paren_open);
        const paren_opened = opened and paren;

        if (paren_opened) {
            if (!level.holds_a_condition(emitter, frame.open)) return true;
        }
    }

    var depth: u32 = 0;
    var scan = emitter.line_before;

    while (scan < emitter.line_first) : (scan += 1) {
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
        if (!line.word_is(emitter, scan, assign_words)) continue;
        return !pending_field(emitter, scan);
    }

    return false;
}

fn pending_field(emitter: *const Emitter, assign: u32) bool {
    assert(assign < emitter.count);
    assert(emitter.line_before < assign);

    if (!emit.is_dot(emitter, emitter.line_before)) return false;

    const name = emit.ahead_of(emitter, emitter.line_before) orelse return false;
    return emit.ahead_of(emitter, name) == assign;
}

fn operator_level(emitter: *const Emitter) ?u32 {
    assert(emitter.line_first < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.header_levels) return null;

    if (caught(emitter)) |word| {
        const returned = caught_level(emitter, word) + 1;

        assert(returned < std.math.maxInt(u32));

        return returned;
    }

    if (operated(emitter)) |operator| return operated_level(emitter, operator);
    return null;
}

fn caught(emitter: *const Emitter) ?u32 {
    assert(emitter.line_first < emitter.count);
    assert(emitter.policy.header_levels);

    const previous = line.coded(emitter) orelse return null;
    if (line.word_is(emitter, previous, catch_words)) return previous;
    if (!walk.text_is(emitter.tokens[previous].text(emitter.source), "|")) return null;

    var scan = previous;

    for (0..caught_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return null;

        assert(held < scan);

        if (walk.text_is(emitter.tokens[held].text(emitter.source), "|")) {
            const word = emit.back_of(emitter, held) orelse return null;
            if (line.word_is(emitter, word, catch_words)) return word;
            return null;
        }

        scan = held;
    }

    return null;
}

fn operated(emitter: *const Emitter) ?u32 {
    assert(emitter.line_first < emitter.count);
    assert(emitter.policy.header_levels);

    const previous = line.coded(emitter) orelse return null;
    const commented = emitter.tokens[emitter.line_first].kind == .comment;
    const coded = if (commented) line.coding(emitter, emitter.line_first) else null;
    const leading = coded orelse emitter.line_first;

    if (emit.operand_of(emitter, previous) == null) return null;
    if (line.word_is(emitter, previous, catch_words)) return null;
    if (emit.roled(emitter, leading, brace.role_span)) return null;
    return previous;
}

fn operated_level(emitter: *const Emitter, operator: u32) u32 {
    assert(operator < emitter.count);
    assert(emitter.policy.header_levels);

    const operand = emit.operand_of(emitter, operator).?;
    const held = line.indent_at(emitter, operand) orelse return emitter.printed;

    assert(operand < operator);

    if (emit.operand_held(emitter, operator)) return held;
    assert(held + 1 <= emitter.count);

    return held + 1;
}

fn caught_level(emitter: *const Emitter, word: u32) u32 {
    assert(word < emitter.count);
    assert(emitter.policy.header_levels);

    const operand = emit.operand_of(emitter, word) orelse return emitter.printed;

    assert(operand < word);

    return line.indent_at(emitter, operand) orelse emitter.printed;
}

fn owings(emitter: *Emitter, parted: bool) u32 {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    const held = emitter.owing;
    const owns = emitter.owns;

    emitter.owing = 0;
    emitter.owns = 0;

    if (parted) return 0;
    if (emitter.chained) return owns;

    const ungrouped = !owing_operand(emitter) or owing_grouped(emitter);

    if (ungrouped) {
        if (tern.owing_test(emitter)) return held;
        return 0;
    }

    const frame = line.frame(emitter);
    if (level.holds_a_condition(emitter, frame.open)) return 0;

    const owns_more = held > owns and frame.kind == .block_start;
    if (owns_more) return owns;
    return held;
}

fn owing_operand(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (!emitter.policy.chain_simples) return false;
    if (!list.spreads(emitter)) return false;

    const held = line.coded(emitter) orelse return false;
    return span.wrapping_operator(emitter, held);
}

fn step_of(emitter: *const Emitter, leading: u32) u32 {
    assert(leading < emitter.count);
    assert(emitter.line_first <= leading);

    return emit.mark_of(emitter, leading) & brace.mark_steps;
}

pub fn leveled_at(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    const found = line.at(emitter, position) orelse return null;

    assert(found.start > 0);
    assert(found.start - 1 <= position);

    return found.level;
}

pub fn spread(emitter: *const Emitter, position: u32) ?struct { u32, u32 } {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.chain_simples) return null;
    if (emitter.depth == 0) return null;

    var spread_level = emitter.printed;
    var open: ?u32 = null;

    for (0..emitter.depth) |index| {
        const frame = emitter.nest[index];
        if (frame.spread == null) continue;
        if (frame.open < emitter.line_first) continue;

        open = frame.open;

        if (frame.hugged > 0) {
            if (hug_whole(emitter, frame.hugged, frame.close)) continue;
        }

        spread_level += 1;
    }

    const held = open orelse return null;
    return .{ spread_item_start(emitter, held, position), spread_level };
}

pub fn hug_whole(emitter: *const Emitter, head: u32, close: u32) bool {
    assert(head < emitter.count);
    assert(close < emitter.count);

    if (call.functioned(emitter, head, close)) return true;

    const end = join.closing_of(emitter, head) orelse return false;
    const after = emit.ahead_of(emitter, end) orelse return false;
    if (after == close) return true;
    if (!emitter.tokens[after].is_punctuation(.comma)) return false;
    return emit.ahead_of(emitter, after) == close;
}

pub fn spread_item(emitter: *const Emitter, position: u32) ?struct { u32, u32 } {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.chain_simples) return null;
    if (emitter.depth == 0) return null;

    const frame = emitter.nest[emitter.depth - 1];
    if (frame.spread == null) return null;
    if (frame.open >= emitter.line_first) return null;

    const item = spread_item_start(emitter, frame.open, position);
    if (item < emitter.line_first) return null;
    return .{ item, emitter.printed + 1 };
}

pub fn spread_item_seat(emitter: *const Emitter, position: u32) ?struct { u32, u32 } {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (emitter.depth == 0) return null;
    return spread_item_seat_in(emitter, emitter.depth - 1, position);
}

pub fn spread_item_seat_in(
    emitter: *const Emitter,
    index: u32,
    position: u32,
) ?struct { u32, u32 } {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.chain_simples) return null;
    if (index >= emitter.depth) return null;

    const frame = emitter.nest[index];
    if (frame.spread == null) return null;
    if (frame.open >= emitter.line_first) return null;

    const item = spread_item_start(emitter, frame.open, position);
    if (item < emitter.line_first) return null;

    const found = line.at(emitter, frame.open) orelse return null;
    const led = link.line_led(emitter, frame.open) orelse return null;
    const seat_level = spread_item_seat_level(emitter, found.start, led);

    return .{ item, seat_level };
}

fn spread_item_seat_level(emitter: *const Emitter, start: u32, led: u32) u32 {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(start > 0);
    assert(led < std.math.maxInt(u32));

    var seat_level = led;

    for (0..emitter.depth) |held| {
        const outer = emitter.nest[held];
        if (outer.spread == null) continue;
        if (outer.open < start - 1) continue;

        if (outer.hugged > 0) {
            if (hug_whole(emitter, outer.hugged, outer.close)) continue;
        }

        seat_level += 1;
    }

    return seat_level;
}

pub fn item_led(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return null;

    var at = position;
    var steps: u32 = 0;
    var index = emitter.depth;

    while (index > 0) {
        index -= 1;

        const frame = emitter.nest[index];
        if (!item_led_eligible(emitter, frame, at)) continue;

        const found = line.at(emitter, at) orelse return null;
        if (spread_item_start(emitter, frame.open, at) < found.start) break;

        steps += 1;
        at = frame.open;
    }

    if (steps == 0) return null;

    const led = link.line_led(emitter, at) orelse return null;
    assert(led + steps < std.math.maxInt(u32));

    return led + steps;
}

fn item_led_eligible(emitter: *const Emitter, frame: core.Frame, at: u32) bool {
    assert(at < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (frame.spread == null) return false;
    if (frame.open >= at) return false;

    if (frame.hugged > 0) {
        if (hug_whole(emitter, frame.hugged, frame.close)) return false;
    }

    return true;
}

fn spread_item_start(emitter: *const Emitter, open: u32, position: u32) u32 {
    assert(open < emitter.count);
    assert(position < emitter.count);

    var depth: u32 = 0;
    var scan = position;

    for (0..spread_item_max) |_| {
        const back = emit.back_of(emitter, scan) orelse break;
        if (back <= open) break;

        if (bind.hole_open(emitter, back)) |hole| {
            scan = hole;

            continue;
        }

        if (spread_item_coded_comma(emitter, back, depth)) return spread_item_coded(emitter, scan);

        depth = spread_item_depth(emitter, back, depth);
        scan = back;
    }

    return spread_item_coded(emitter, scan);
}

fn spread_item_depth(emitter: *const Emitter, position: u32, depth: u32) u32 {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);
    assert(depth < std.math.maxInt(u32));

    const kind = emitter.tokens[position].kind;

    if (walk.is_close(kind)) {
        assert(depth + 1 < std.math.maxInt(u32));

        return depth + 1;
    }

    if (kind == .block_end) {
        assert(depth + 1 < std.math.maxInt(u32));

        return depth + 1;
    }

    if (walk.is_open(kind)) {
        assert(depth -| 1 < std.math.maxInt(u32));

        return depth -| 1;
    }

    if (kind == .block_start) {
        assert(depth -| 1 < std.math.maxInt(u32));

        return depth -| 1;
    }

    return depth;
}

fn spread_item_coded_comma(emitter: *const Emitter, position: u32, depth: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (depth != 0) return false;
    return emitter.tokens[position].kind.eql(.{ .punctuation = .comma });
}

fn spread_item_coded(emitter: *const Emitter, scan: u32) u32 {
    assert(scan < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (emitter.tokens[scan].kind != .comment) return scan;
    return line.coding(emitter, scan) orelse scan;
}

pub fn wide_wraps(emitter: *const Emitter) u32 {
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.wraps_owed < 2) return 0;

    const room = emitter.options.line_width -| (emitter.printed * emitter.options.indent_width);
    var count: u32 = 0;
    var held: u32 = 0;

    while (held < emitter.wraps_owed - 1) {
        if (wide_wraps_counted(emitter, held, room)) count += 1;

        held += 1;
    }

    return count;
}

fn wide_wraps_counted(emitter: *const Emitter, held: u32, room: u32) bool {
    assert(held < emitter.wraps_owed);

    const wrapped = emitter.wrapped[held];
    if (wrapped.start < emitter.line_first) return false;

    const wide = switch (wrapped.wrap) {
        .bodied, .hugged, .parens => true,
        else => false,
    };

    if (!wide) return false;
    return emitter.wraps_width[held] > room;
}

pub fn led_owed(emitter: *const Emitter) u32 {
    assert(emitter.broken_low <= emitter.broken);

    return emitter.shadow.owed_broken(emitter.broken_low);
}

pub fn chain_levels(emitter: *const Emitter) u32 {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.line_first <= emitter.count);

    var levels_held: u32 = 0;

    for (0..emitter.depth) |index| {
        const held = emitter.nest[index];
        const hugged_line = held.hugged > 0 and held.hugged <= emitter.line_first;
        const spread_paren = held.spread != null and held.kind.eql(.{ .punctuation = .paren_open });
        const parted = spread_paren and held.open < emitter.line_first and !hugged_line;

        levels_held += @intFromBool(parted);
    }

    return levels_held;
}

pub fn spread_levels(emitter: *const Emitter) u32 {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.line_first <= emitter.count);

    var levels_held: u32 = 0;

    for (0..emitter.depth) |index| {
        const held = emitter.nest[index];
        const bracketed = held.kind.eql(.{ .punctuation = .bracket_open });
        const braced = held.kind == .block_start or bracketed;
        const spreads = held.spread != null and held.open < emitter.line_first and braced;

        levels_held += @intFromBool(spreads);
    }

    return levels_held;
}

pub fn ternary_align_columns(emitter: *const Emitter) u32 {
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    const room = emitter.options.line_width -| (emitter.printed * emitter.options.indent_width);
    var columns: u32 = 0;
    var held: u32 = 0;

    while (held < emitter.wraps_owed) {
        if (ternary_align_columns_counted(emitter, held, room)) {
            columns += emitter.wraps_aligned[held] * bar_columns;
        }

        held += 1;
    }

    return columns;
}

fn ternary_align_columns_counted(emitter: *const Emitter, held: u32, room: u32) bool {
    assert(held < emitter.wraps_owed);

    const wrapped = emitter.wrapped[held];
    if (wrapped.wrap != .ternary) return false;
    if (ternary_align_columns_led(emitter, wrapped.floor)) return true;
    return emitter.wraps_width[held] > room;
}

fn ternary_align_columns_led(emitter: *const Emitter, question: u32) bool {
    assert(question < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const found = line.at(emitter, question) orelse return false;
    return found.start - 1 == question;
}

pub fn ternary_align_outside(emitter: *const Emitter, mark: u32) u32 {
    assert(mark < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const linked = tern.ternary_linked_at(emitter, mark);
    var own_columns: u32 = 0;
    var chained: u32 = 0;

    if (linked) |found| {
        const held, const link_steps = found;

        own_columns = emitter.wraps_aligned[held] * bar_columns;

        if (link_steps > 0) chained = bar_columns;
    }

    const returned = (ternary_align_columns(emitter) -| own_columns) + chained;

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn item_shadowed(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!list.spreads(emitter)) return null;

    const frame = line.frame(emitter);
    if (frame.grouped == null) return null;
    if (frame.open >= emitter.line_first) return null;
    if (span.element_level(emitter, head) == null) return null;
    return emitter.shadow.inset_after(frame.grouped.?);
}

pub fn run_shadowed(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const shadowed_level = item_shadowed(emitter, head) orelse return null;
    const returned = shadowed_level + @intFromBool(call.header_item(emitter, head));

    assert(returned < std.math.maxInt(u32));

    return returned;
}

pub fn owing_grouped(emitter: *const Emitter) bool {
    assert(emitter.wraps_owed <= core.wrap_depth_max);
    assert(emitter.depth <= brace.nest_depth_max);

    for (0..emitter.wraps_owed) |index| {
        if (emitter.wrapped[index].wrap != .paired) return true;
    }

    assert(emitter.depth > 0);

    const frame = emitter.nest[emitter.depth - 1];
    return list.paren_grouped(emitter, frame.open, frame.close);
}
