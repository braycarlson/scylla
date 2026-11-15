const std = @import("std");
const assert = std.debug.assert;
const bind = @import("bind.zig");
const body = @import("body.zig");
const brace = @import("../brace.zig");
const clause = @import("clause.zig");
const comment = @import("comment.zig");
const core = @import("emitter.zig");
const emit = @import("emit.zig");
const jsx = @import("jsx.zig");
const join = @import("join.zig");
const lead = @import("lead.zig");
const line = @import("line.zig");
const list = @import("list.zig");
const own = @import("own.zig");
const span = @import("span.zig");
const split = @import("split.zig");
const tmpl = @import("tmpl.zig");
const unite = @import("unite.zig");
const walk = @import("../walk.zig");
const Emitter = core.Emitter;

pub const ReturnColons = struct {
    entries: [return_colon_cache_count]ReturnColon,
    generation: u32,

    pub fn init(colons: *ReturnColons) void {
        colons.generation = 1;

        for (&colons.entries) |*entry| entry.generation = 0;

        assert(colons.generation > 0);
        assert(colons.entries[0].generation != colons.generation);
    }

    pub fn begin(colons: *ReturnColons) void {
        assert(colons.generation > 0);
        assert(colons.generation < std.math.maxInt(u32));

        colons.generation += 1;
    }
};

const ReturnColon = struct {
    colon: u32,
    answer: bool,
    generation: u32,
};

const binary_operators: []const []const u8 = &.{
    "!=",
    "!==",
    "%",
    "&",
    "&&",
    "*",
    "**",
    "+",
    "-",
    "/",
    "<",
    "<<",
    "<=",
    "==",
    "===",
    ">",
    ">=",
    ">>",
    ">>>",
    "^",
    "in",
    "instanceof",
    "|",
    "||",
    "??",
};

const return_colon_cache_count: u32 = 1 << 12;
const return_colon_max: u32 = 64;
const return_colon_stops: []const []const u8 = &.{ ",", ";", ":", "?", "=" };
const return_scan_max: u32 = 256;
const ternary_chain_max: u32 = 1 << 8;
const ternary_nest_max: u32 = 16;
const ternary_scan_max: u32 = 1 << 14;

pub fn ternaried(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.ternary_colon) return false;

    if (emitter.tokens[position].is_punctuation(.colon)) {
        if (ternary(emitter, position)) return true;
    }

    if (!emitter.tokens[previous].is_punctuation(.colon)) return false;
    return ternary(emitter, previous);
}

pub fn ternary(emitter: *const Emitter, colon: u32) bool {
    assert(colon < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const stop: u32 = if (emitter.depth == 0) 0 else line.frame(emitter).open;
    return ternary_within(emitter, colon, stop);
}

pub fn ternary_within(emitter: *const Emitter, colon: u32, stop: u32) bool {
    assert(colon < emitter.count);
    assert(stop < emitter.count);

    if (core.memo_found(emitter, .ternary_within, colon, stop)) |answer| return answer == 1;

    const found = ternary_question(emitter, colon, stop) != null;

    core.memo_store(emitter, .ternary_within, colon, stop, @intFromBool(found));

    return found;
}

pub fn ternary_question(emitter: *const Emitter, colon: u32, stop: u32) ?u32 {
    assert(colon < emitter.count);
    assert(stop < emitter.count);

    if (return_colon(emitter, colon)) return null;

    var depth: u32 = 0;
    var owed: u32 = 0;
    var scan = colon;

    while (scan > stop) {
        assert(scan <= colon);

        scan -= 1;

        const kind = emitter.tokens[scan].kind;

        if (walk.is_close(kind)) {
            const jumped = if (depth == 0) ternary_jumped(emitter, scan) else null;

            if (jumped) |open| {
                scan = open;

                continue;
            }

            depth += 1;

            continue;
        }

        if (walk.is_open(kind)) {
            depth -|= 1;

            continue;
        }

        if (depth > 0) continue;
        if (kind == .string) continue;

        const bytes = emitter.tokens[scan].text(emitter.source);
        if (walk.text_is(bytes, ";")) return null;

        const owing = walk.text_is(bytes, ":") and !return_colon(emitter, scan);

        if (owing) {
            owed += 1;

            continue;
        }

        const branching = walk.text_is(bytes, "?") and !optional(emitter, scan);

        if (branching) {
            if (owed == 0) return scan;

            owed -= 1;
        }
    }

    return null;
}

fn ternary_jumped(emitter: *const Emitter, close: u32) ?u32 {
    assert(close < emitter.count);
    assert(walk.is_close(emitter.tokens[close].kind));

    const open = emitter.brackets.open_of(close) orelse return null;

    assert(open < close);

    assert(open < close);

    if (walk.is_open(emitter.tokens[open].kind)) return open;
    if (bind.spans_open(emitter, open)) return open;
    return null;
}

pub fn ternary_blank(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.ternary_parts) return false;

    const text = emitter.tokens[position].text(emitter.source);
    if (walk.text_is(text, "?")) return !optional(emitter, position);
    if (walk.text_is(text, ":")) return ternary(emitter, position);
    return false;
}

pub fn optional(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const token = emitter.tokens[position];
    if (!walk.text_is(token.text(emitter.source), "?")) return true;
    if (token.kind == .string) return true;

    const held = emit.ahead_of(emitter, position) orelse return false;

    assert(held > position);

    const kind = emitter.tokens[held].kind;

    assert(held > position);

    const membered = optional_membered(emitter, held);
    const generic = optional_generic(emitter, position, held);
    const adjacent = token.end() == emitter.tokens[held].offset;

    const signed = kind.eql(.{ .punctuation = .paren_open }) and adjacent and
        (typed_frame(emitter) or membered);

    if (walk.is_close(kind)) return true;
    if (signed) return true;
    if (generic) return true;
    if (kind.eql(.{ .punctuation = .colon })) return true;
    if (kind.eql(.{ .punctuation = .comma })) return true;
    if (walk.text_is(emitter.tokens[held].text(emitter.source), "=")) return true;
    return kind.eql(.{ .punctuation = .semicolon });
}

fn optional_membered(emitter: *const Emitter, held: u32) bool {
    assert(held < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.policy.type_words.len == 0) return false;
    if (emitter.depth == 0) return false;
    if (line.frame(emitter).kind != .block_start) return false;

    const close = join.closing_of(emitter, held) orelse return false;

    assert(close > held);

    const after = emit.ahead_of(emitter, close) orelse return false;

    assert(after > close);
    const kind = emitter.tokens[after].kind;
    if (kind == .block_start) return true;
    if (kind.eql(.{ .punctuation = .colon })) return true;
    return kind.eql(.{ .punctuation = .semicolon });
}

fn optional_generic(emitter: *const Emitter, position: u32, held: u32) bool {
    assert(position < emitter.count);
    assert(held < emitter.count);
    assert(held > position);

    if (emitter.policy.type_words.len == 0) return false;
    if (!walk.text_is(emitter.tokens[held].text(emitter.source), "<")) return false;
    if (emitter.tokens[position].end() != emitter.tokens[held].offset) return false;
    if (emitter.depth == 0) return false;
    if (line.frame(emitter).kind != .block_start) return false;

    const angle = join.angle_close(emitter, held) orelse return false;
    const paren = emit.ahead_of(emitter, angle) orelse return false;

    assert(paren > angle);

    if (!emitter.tokens[paren].kind.eql(.{ .punctuation = .paren_open })) return false;

    const close = join.closing_of(emitter, paren) orelse return false;

    assert(close > paren);

    const after = emit.ahead_of(emitter, close) orelse return false;

    assert(after > close);
    const kind = emitter.tokens[after].kind;
    if (kind == .block_start) return true;
    if (kind.eql(.{ .punctuation = .colon })) return true;
    return kind.eql(.{ .punctuation = .semicolon });
}

pub fn comment_wrapped(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.wraps_owed == 0) return null;

    const previous = emit.back_of(emitter, position) orelse return null;

    assert(previous < position);

    if (emitter.tokens[previous].kind != .comment) return null;

    const wrapped = emitter.wrapped[emitter.wraps_owed - 1];
    const seated = emitter.depth <= wrapped.depth;

    const level = if (emit.is_dot(emitter, position))
        emitter.wraps_indent[emitter.wraps_owed - 1] + 1
    else
        emitter.printed;

    if (wrapped.wrap != .parens) return null;
    if (!seated) return null;
    if (position <= wrapped.start) return null;
    if (position > wrapped.close) return null;
    assert(level < std.math.maxInt(u32));

    return level;
}

fn ternary_nested_led(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    if (!emitter.policy.chain_simples) return null;

    const held, _ = ternary_linked_at(emitter, position) orelse return null;

    assert(held < emitter.count);

    if (emitter.wrapped[held].wrap != .nested) return null;
    return ternary_wanted(emitter, position);
}

pub fn ternary_forced_level(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    const previous = emitter.previous orelse return null;

    assert(previous < emitter.count);

    const forced = (!ternary_source_parted(emitter, previous, position) and
        ternary_forced(emitter, position)) or ternary_comment_forced(emitter, position);

    if (!forced) return ternary_nested_led(emitter, position);

    const head = ternary_test(emitter, position);
    const opens = span.line_opened(emitter, head) orelse head;
    const based = lead.leveled_at(emitter, opens) orelse emitter.printed;
    const question = ternary_forced_level_question(emitter, position);

    const bound = opens != head and
        (ternary_bound(emitter, head, question) or
            ternary_fluid_bound(emitter, head, question, opens, based));

    const lost = !bound and ternary_forced_level_lost(emitter, head, position);
    assert(based +| @as(u32, @intFromBool(bound)) +| @as(u32, @intFromBool(lost)) <= emitter.count);

    return based +| @as(u32, @intFromBool(bound)) +| @as(u32, @intFromBool(lost));
}

fn ternary_forced_level_question(emitter: *const Emitter, position: u32) u32 {
    assert(position < emitter.count);

    const held, _ = ternary_linked_at(emitter, position) orelse return position;

    assert(held < emitter.wraps_owed);

    return emitter.wrapped[held].floor;
}

fn ternary_forced_level_lost(emitter: *const Emitter, head: u32, position: u32) bool {
    assert(head < emitter.count);
    assert(position < emitter.count);

    const held, const link = ternary_linked_at(emitter, position) orelse return false;

    assert(held < emitter.wraps_owed);

    const at_line = line.at(emitter, head) orelse return false;
    if (at_line.start -| 1 >= emitter.wrapped[held].floor) return false;

    const severed = link > 0 and emitter.wraps_severed[held];
    if (severed) return true;

    for (0..held) |at| {
        if (!emitter.wraps_severed[at]) continue;
        if (!body_since(emitter, emitter.wrapped[at].depth)) return true;
    }

    return false;
}

fn body_since(emitter: *const Emitter, depth: u32) bool {
    assert(depth <= emitter.depth);
    assert(emitter.depth <= brace.nest_depth_max);

    for (depth..emitter.depth) |held| {
        if (emitter.nest[held].bodied) return true;
    }

    return false;
}

fn ternary_fluid_bound(
    emitter: *const Emitter,
    head: u32,
    question: u32,
    opens: u32,
    based: u32,
) bool {
    assert(head < emitter.count);
    assert(question < emitter.count);

    if (!ternary_fluid_assigned(emitter, head)) return false;
    assert(based < std.math.maxInt(u32));

    const typed = typed_ahead(emitter, head, question);
    const last = ternary_fluid_last(emitter, head, question, typed);
    if (last < opens) return false;

    const equals = emit.back_of(emitter, head) orelse return false;
    const start = own.alias_parted(emitter, equals, opens, based) orelse opens;
    const width = based * emitter.options.indent_width + span.printed_columns(emitter, start, last);

    return width > emitter.options.line_width;
}

fn ternary_fluid_assigned(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);

    const held = emit.back_of(emitter, head) orelse return false;

    assert(held < head);

    assert(held < head);

    const assigns = emitter.tokens[held].is_punctuation(.assign) or
        own.compound_assign(emitter, held);

    if (!assigns) return false;
    return !own.alias_refused(emitter, held);
}

fn ternary_fluid_last(emitter: *const Emitter, head: u32, question: u32, typed: bool) u32 {
    assert(head < emitter.count);
    assert(question <= emitter.count);

    var last = head;
    var scan = head;

    while (scan < question) {
        assert(scan < emitter.count);

        const kind = emitter.tokens[scan].kind;

        if (kind != .comment) last = scan;

        const opened = (walk.is_open(kind) or kind == .block_start) and
            join.closing_of(emitter, scan) != emit.ahead_of(emitter, scan);

        const anded = typed and walk.text_is(emitter.tokens[scan].text(emitter.source), "&");

        if (opened) break;
        if (anded) break;

        scan += 1;
    }

    return last;
}

fn ternary_bound(emitter: *const Emitter, head: u32, question: u32) bool {
    assert(head < emitter.count);
    assert(question <= emitter.count);

    const before = emit.back_of(emitter, head) orelse return false;

    assert(before < head);

    const bound = emitter.tokens[before].is_punctuation(.assign) or
        own.compound_assign(emitter, before);

    if (!bound) return false;
    if (typed_ahead(emitter, head, question)) return own.alias_conditional(emitter, before) != null;
    return ternary_bound_operated(emitter, head, question);
}

fn ternary_bound_operated(emitter: *const Emitter, head: u32, question: u32) bool {
    assert(head < emitter.count);
    assert(question <= emitter.count);

    var depth: u32 = 0;
    var scan = head;

    while (scan < question) {
        assert(scan < emitter.count);

        const kind = emitter.tokens[scan].kind;
        const opening = walk.is_open(kind) or kind == .block_start;
        const closing = walk.is_close(kind) or kind == .block_end;
        const operated = depth == 0 and binary_operator(emitter.tokens[scan].text(emitter.source));

        if (opening) {
            depth += 1;
        } else if (closing) {
            depth -|= 1;
        } else if (operated) {
            if (emit.back_of(emitter, scan)) |before| {
                if (walk.ends_operand(emitter.tokens[before].kind)) return true;
            }
        } else {}

        scan += 1;
    }

    return false;
}

fn binary_operator(text: []const u8) bool {
    assert(text.len > 0);

    for (binary_operators) |candidate| {
        if (walk.text_eql(candidate, text)) return true;
    }

    return false;
}

pub fn ternary_level(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    if (!emitter.policy.ternary_levels) return null;

    const text = emitter.tokens[position].text(emitter.source);

    const branched = if (walk.text_is(text, "?"))
        !optional(emitter, position)
    else
        walk.text_is(text, ":") and ternary(emitter, position);

    if (!branched) return null;
    return ternary_branch_level(emitter, position);
}

pub fn branch_run_columns(emitter: *const Emitter, seat: ?u32) u32 {
    assert(emitter.wraps_owed <= core.wrap_depth_max);
    if (seat) |held| assert(held < emitter.count);

    const seated = seat != null and list.argued_seat(emitter, seat.?);
    if (!seated) return 0;

    const room = emitter.options.line_width -| emitter.printed * emitter.options.indent_width;
    var stepped: u32 = 0;

    for (0..emitter.wraps_owed) |held| {
        const wrapped = emitter.wrapped[held];
        if (wrapped.wrap != .ternary) continue;
        if (!emitter.wraps_assigned[held]) continue;
        if (wrapped.start <= emitter.line_first) continue;
        if (emitter.wraps_width[held] <= room) continue;
        if (!ternary_bound(emitter, wrapped.start, wrapped.floor)) continue;

        stepped += 1;
    }

    const returned = stepped * emitter.options.indent_width + lead.ternary_align_columns(emitter);

    assert(returned < std.math.maxInt(u32));

    return returned;
}

pub fn branch_chain_level(emitter: *const Emitter, seat: u32) u32 {
    assert(seat < emitter.count);

    const level = ternary_level(emitter, seat) orelse emitter.printed;
    const returned = level +| lead.spread_levels(emitter) +| lead.chain_levels(emitter);

    assert(returned < std.math.maxInt(u32));

    return returned;
}

pub fn ternary_branch_level(emitter: *const Emitter, position: u32) u32 {
    assert(position < emitter.count);

    const head = ternary_test(emitter, position);
    const opens = span.line_opened(emitter, head) orelse head;
    const based = ternary_branch_level_based(emitter, head, opens);
    const bodied: u32 = @intFromBool(ternary_bodied_line(emitter, opens, head));
    const returned = based +| 1 +| bodied;

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn ternary_branch_level_based(emitter: *const Emitter, head: u32, opens: u32) u32 {
    assert(head < emitter.count);
    assert(opens <= head);

    if (ternary_branch_level_annotated(emitter, head, opens)) |level| return level;
    if (span.element_level(emitter, head)) |level| return level;
    if (span.element_level(emitter, opens)) |level| return level;
    if (line.level_at(emitter, opens)) |level| return level;
    return emitter.levels;
}

fn ternary_branch_level_annotated(emitter: *const Emitter, head: u32, opens: u32) ?u32 {
    assert(head < emitter.count);

    const assign = emit.back_of(emitter, head) orelse return null;

    assert(assign < head);

    if (assign <= opens) return null;
    return unite.annotation_level(emitter, assign);
}

fn ternary_bodied_line(emitter: *const Emitter, opens: u32, head: u32) bool {
    assert(opens <= head);
    assert(head < emitter.count);

    if (emitter.line_first <= head) return false;
    if (ternary_branch_led(emitter, head)) return false;

    for (0..emitter.wraps_owed) |held| {
        const wrapped = emitter.wrapped[held];
        if (wrapped.wrap != .bodied) continue;
        if (head > wrapped.close) continue;
        if (wrapped.start < opens) continue;
        if (wrapped.start >= head) continue;
        if (emit.ahead_of(emitter, wrapped.start) != head) continue;
        return true;
    }

    return false;
}

fn ternary_branch_led(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);

    const question = ternary_ahead(emitter, head) orelse return false;
    var first = emitter.line_first;
    var index = emitter.lined;

    for (0..core.line_level_max) |_| {
        index = if (index == 0) core.line_level_max - 1 else index - 1;

        const start = emitter.lines[index].start;
        if (start == 0) break;
        if (start - 1 <= head) break;

        first = start - 1;
    }

    return first > question;
}

fn ternary_stale(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (emitter.depth == 0) return false;

    const open = line.frame(emitter).open;
    const head = ternary_test(emitter, position);
    if (head <= open) return false;

    const opened = span.line_opened(emitter, head) orelse return true;
    const branched = ternary_stale_branched(emitter, head);

    if (opened < open) return true;
    return branched != null and opened < branched.?;
}

fn ternary_stale_branched(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);

    const colon = emit.back_of(emitter, head) orelse return null;

    assert(colon < head);

    if (!emitter.tokens[colon].is_punctuation(.colon)) return null;
    if (!ternary(emitter, colon)) return null;
    return colon;
}

pub fn ternary_wanted(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    var at = position;

    for (0..ternary_nest_max) |_| {
        const branched = ternary_wanted_branched(emitter, at) orelse break;
        if (ternary_level(emitter, branched) == null) break;

        at = branched;
    }

    const level = ternary_level(emitter, at) orelse return null;
    const stale = ternary_stale(emitter, at);

    if (stale) {
        const returned = @min(level -| 1, emitter.indent);

        assert(returned < std.math.maxInt(u32));

        return returned;
    }

    assert(level -| 1 < std.math.maxInt(u32));

    return level -| 1;
}

fn ternary_wanted_branched(emitter: *const Emitter, at: u32) ?u32 {
    assert(at < emitter.count);

    const colon = emit.back_of(emitter, ternary_test(emitter, at)) orelse return null;
    if (!emitter.tokens[colon].is_punctuation(.colon)) return null;
    if (!ternary(emitter, colon)) return null;
    if (!ternary_stale(emitter, at)) return null;
    return colon;
}

pub fn ternary_test(emitter: *const Emitter, position: u32) u32 {
    assert(position < emitter.count);

    var head = position;

    var owed: u32 = @intFromBool(
        walk.text_is(emitter.tokens[position].text(emitter.source), ":"),
    );

    for (0..ternary_scan_max) |_| {
        const before = emit.back_of(emitter, head) orelse break;
        if (clause.header_closed(emitter, before)) break;

        const kind = emitter.tokens[before].kind;
        const text = emitter.tokens[before].text(emitter.source);
        const closing = walk.is_close(kind) or kind == .block_end;

        if (closing) {
            head = emitter.brackets.open_of(before) orelse break;

            continue;
        }

        const angled = owed == 0 and list.closes_angle(text);

        if (angled) {
            if (angle_opening(emitter, before)) |open| {
                head = open;

                continue;
            }
        }

        const questioned = walk.text_is(text, "?") and !optional(emitter, before);

        if (questioned) {
            if (owed == 0) break;

            owed -= 1;
            head = before;

            continue;
        }

        const colon_ternary = walk.text_is(text, ":") and ternary(emitter, before);

        if (colon_ternary) {
            if (owed == 0) break;

            owed += 1;
            head = before;

            continue;
        }

        if (kind == .comment) {
            head = before;

            continue;
        }

        if (ternary_test_stops(emitter, head, before)) break;

        head = before;
    }

    return head;
}

fn ternary_test_stops(emitter: *const Emitter, head: u32, before: u32) bool {
    assert(before < emitter.count);
    assert(head < emitter.count);

    const kind = emitter.tokens[before].kind;
    const text = emitter.tokens[before].text(emitter.source);

    if (walk.is_open(kind)) return true;
    if (kind == .block_start) return true;
    if (kind.eql(.{ .punctuation = .assign })) return true;
    if (kind.eql(.{ .punctuation = .comma })) return true;
    if (kind.eql(.{ .punctuation = .semicolon })) return true;
    if (walk.text_is(text, "return")) return true;
    if (walk.text_is(text, "throw")) return true;
    if (walk.text_is(text, "case")) return true;
    if (test_worded(emitter, before)) return true;
    if (walk.substituting(emitter.source, emitter.tokens[before])) return true;

    const armed = walk.text_is(text, ":") and split.armed(emitter, before);
    const arrowed = walk.text_is(text, "=>") and !emit.roled(emitter, head, brace.role_type);

    if (armed) return true;
    if (arrowed) return true;
    return own.compound_assign(emitter, before);
}

fn test_worded(emitter: *const Emitter, word: u32) bool {
    assert(word < emitter.count);

    if (!line.word_is(emitter, word, &.{ "do", "else" })) return false;

    const before = emit.back_of(emitter, word) orelse return true;

    assert(before < word);

    return !emit.is_dot(emitter, before);
}

pub fn typed_frame(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.policy.type_words.len == 0) return false;

    var depth = emitter.depth;

    while (depth > 0) {
        const frame = emitter.nest[depth - 1];
        if (emit.typing(emitter, span.union_head(emitter, frame.open))) return true;

        depth -= 1;
    }

    return false;
}

pub fn ternary_guarded(emitter: *Emitter, wrap: core.Wrap) error{Overflow}!void {
    assert(emitter.wraps_owed < core.wrap_depth_max);
    assert(emitter.wrapped[emitter.wraps_owed].wrap == wrap);

    if (wrap != .guarded) return;

    const guard = emitter.guards[emitter.wraps_owed];

    if (emitter.document.group_depth != guard.depth) {
        emitter.document.withdraw(guard.index);

        return;
    }

    try emitter.document.push(.{ .if_flat = emitter.closing });
}

pub fn ternary_opens(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.wraps_owed == core.wrap_depth_max) return;
    if (tmpl.holed(emitter)) return;
    if (tmpl.template_piece(emitter, position)) return;

    const found = ternary_headed(emitter, position) orelse return;
    const close = found[0];
    const question = found[1];
    const chained = brace.jsx_spans_off and jsx.chained(emitter, question, close);

    if (chained) {
        return jsx.chain_opens(emitter, position, question, close);
    }

    const guarded = ternary_bodied_at(emitter, position);
    const nested = !guarded and ternary_nested(emitter, position);
    const wrap: core.Wrap = if (guarded) .guarded else if (nested) .nested else .ternary;

    try ternary_opens_tracked(emitter, position, close, question, wrap);

    if (nested) {
        try emitter.document.push(.{ .if_flat = emitter.opening });

        return;
    }

    if (guarded) try emitter.document.push(.{ .if_flat = emitter.opening });
    if (!ternary_paren_tested(emitter, position)) try emitter.document.push(.group_open);
}

fn ternary_opens_tracked(
    emitter: *Emitter,
    position: u32,
    close: u32,
    question: u32,
    wrap: core.Wrap,
) error{Overflow}!void {
    assert(emitter.wraps_owed < core.wrap_depth_max);
    assert(position < emitter.count);
    assert(close < emitter.count);
    assert(question < emitter.count);
    assert(wrap == .guarded or wrap == .nested or wrap == .ternary);

    const before = emit.back_of(emitter, position);

    const assigned = emitter.assigns > 0 and
        before == emitter.assigned[emitter.assigns - 1].equals;

    emitter.guards[emitter.wraps_owed] = .{
        .index = emitter.document.count(),
        .depth = emitter.document.group_depth,
    };

    emitter.wraps_assigned[emitter.wraps_owed] = assigned;
    emitter.wraps_severed[emitter.wraps_owed] = false;

    emitter.wrapped[emitter.wraps_owed] = .{
        .close = close,
        .wrap = wrap,
        .depth = emitter.depth,
        .floor = question,
        .start = position,
    };

    emitter.wraps_armed[emitter.wraps_owed] = true;
    emitter.wraps_nested[emitter.wraps_owed] = core.nest_none;

    emitter.wraps_width[emitter.wraps_owed] = if (wrap == .ternary)
        span.printed_columns(emitter, position, close)
    else
        0;

    emitter.wraps_owed += 1;
}

pub fn ternary_source_parted(emitter: *const Emitter, previous: u32, position: u32) bool {
    assert(previous < emitter.count);
    assert(position < emitter.count);

    if (!body.parts_at(emitter, previous, position)) return false;
    return !ternary_severed(emitter, position);
}

pub fn ternary_severs(emitter: *Emitter, dedents: bool) bool {
    assert(emitter.wraps_owed <= core.wrap_depth_max);
    assert(emitter.depth <= brace.nest_depth_max);

    var severs = false;

    for (0..emitter.wraps_owed) |at| {
        const wrap = emitter.wrapped[at].wrap;
        const kinded = wrap == .guarded or wrap == .ternary;

        if (!emitter.wraps_assigned[at]) continue;

        if (kinded) {
            emitter.wraps_severed[at] = emitter.wraps_severed[at] or dedents;
            severs = true;
        }
    }

    if (severs) assert(emitter.wraps_owed > 0);

    return severs;
}

pub fn owing_test(emitter: *const Emitter) bool {
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    const previous = line.coded(emitter) orelse return false;

    assert(previous < emitter.count);

    if (!span.wrapping_operator(emitter, previous)) return false;

    var at = emitter.wraps_owed;

    while (at > 0) {
        at -= 1;

        const wrapped = emitter.wrapped[at];
        const kinded = wrapped.wrap == .guarded or wrapped.wrap == .ternary;

        const owed = kinded and emitter.wraps_assigned[at] and emitter.wraps_severed[at] and
            wrapped.start <= previous and previous < wrapped.floor;

        if (owed) return true;
    }

    return false;
}

fn ternary_severed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    const held, _ = ternary_linked_at(emitter, position) orelse return false;
    return emitter.wraps_severed[held];
}

pub fn ternary_paren_tested(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);

    const open = emit.back_of(emitter, head) orelse return false;

    assert(open < head);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const close = join.closing_of(emitter, open) orelse return false;

    assert(close > open);

    if (!list.paren_grouped(emitter, open, close)) return false;
    return list.paren_tested(emitter, open, close);
}

fn ternary_bodied_at(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);

    const before = emit.back_of(emitter, head) orelse return false;

    assert(before < head);

    return walk.text_is(emitter.tokens[before].text(emitter.source), "=>");
}

fn ternary_nested(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);

    const before = join.coded_before(emitter, head) orelse return false;
    if (!walk.text_is(emitter.tokens[before].text(emitter.source), "?")) return false;
    if (optional(emitter, before)) return false;
    return ternary_parted(emitter, before);
}

pub fn ternary_headed(emitter: *const Emitter, position: u32) ?struct { u32, u32 } {
    assert(position < emitter.count);

    if (!emitter.policy.ternary_parts) return null;

    const question = ternary_ahead(emitter, position) orelse return null;
    if (ternary_head(emitter, question) != position) return null;
    if (typing_ahead(emitter, position, question)) return null;

    const colon = ternary_branch(emitter, question) orelse return null;
    const close = ternary_end(emitter, colon) orelse return null;

    if (ternary_chained(emitter, question)) return null;

    const depth = ternary_headed_depth(emitter, position);

    if (sequenced(emitter, position, close)) return null;
    if (!ternary_seated_below(emitter, depth)) return null;
    return .{ close, question };
}

fn ternary_headed_depth(emitter: *const Emitter, position: u32) u32 {
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return emitter.depth;
    if (line.frame(emitter).open != position) return emitter.depth;
    assert(emitter.depth - 1 < std.math.maxInt(u32));

    return emitter.depth - 1;
}

fn ternary_answered(emitter: *const Emitter, colon: u32, stop: u32) bool {
    assert(colon < emitter.count);
    assert(stop < emitter.count);

    return ternary_within(emitter, colon, stop);
}

fn ternary_comment_ends(emitter: *const Emitter, scan: u32, held: bool, owed: u32) bool {
    assert(scan < emitter.count);

    if (!held) return false;
    if (owed > 0) return false;
    return !ternary_comment_ends_tested(emitter, scan);
}

fn ternary_comment_ends_tested(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);

    const next = line.coding(emitter, scan) orelse return false;

    assert(next < emitter.count);

    if (!walk.text_is(emitter.tokens[next].text(emitter.source), "?")) return false;
    return !optional(emitter, next);
}

fn ternary_frame_stop(emitter: *const Emitter, colon: u32) u32 {
    assert(colon < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    var depth = emitter.depth;

    while (depth > 0) {
        if (emitter.nest[depth - 1].close >= colon) break;

        depth -= 1;
    }

    if (depth == 0) return 0;
    assert(emitter.nest[depth - 1].open < std.math.maxInt(u32));

    return emitter.nest[depth - 1].open;
}

fn ternary_end(emitter: *const Emitter, colon: u32) ?u32 {
    assert(colon < emitter.count);

    var held: ?u32 = null;
    var owed: u32 = 0;
    var scan = colon + 1;
    const stop = ternary_frame_stop(emitter, colon);
    const typed = ternary_end_typed(emitter, colon);

    while (scan < emitter.count) {
        switch (ternary_end_unit(emitter, colon, scan)) {
            .absent => {},
            .jump => |end| {
                held = end;
                scan = end + 1;

                continue;
            },
            .unpaired => return null,
        }

        if (typed) {
            if (ternary_end_typed_held(emitter, scan, held, owed)) return held;
        }

        const token = emitter.tokens[scan];
        const opening = walk.is_open(token.kind) or token.kind == .block_start;

        if (opening) {
            const end = join.closing_of(emitter, scan) orelse return null;

            held = end;
            scan = end + 1;

            continue;
        }

        if (ternary_end_closed(emitter, colon, scan)) return held;

        if (token.kind == .comment) {
            if (ternary_comment_ends(emitter, scan, held != null, owed)) return held;

            scan += 1;

            continue;
        }

        const text = token.text(emitter.source);
        const answered = ternary_answered(emitter, scan, stop);
        const questioned = walk.text_is(text, "?") and !optional(emitter, scan);
        const answering = token.is_punctuation(.colon) and answered;

        if (questioned) {
            owed += 1;
            held = null;
        } else if (answering) {
            if (owed == 0) return held;

            owed -= 1;
            held = null;
        } else {
            held = scan;
        }

        scan += 1;
    }

    return held;
}

const Unit = union(enum) {
    absent,
    jump: u32,
    unpaired,
};

fn ternary_end_unit(emitter: *const Emitter, colon: u32, scan: u32) Unit {
    assert(colon < scan);
    assert(scan < emitter.count);

    if (tmpl.spanned_unit(emitter, scan)) |end| return .{ .jump = end };

    const kind = emitter.tokens[scan].kind;
    if (walk.is_close(kind)) return .absent;
    if (!angle_nested(emitter, scan, colon)) return .absent;
    if (!walk.is_open(kind)) return .{ .jump = scan };

    const end = join.closing_of(emitter, scan) orelse return .unpaired;

    assert(end > scan);

    return .{ .jump = end };
}

fn ternary_end_typed_held(emitter: *const Emitter, scan: u32, held: ?u32, owed: u32) bool {
    assert(scan < emitter.count);

    if (held) |end| assert(end < scan);

    if (held == null) return false;
    if (owed > 0) return false;
    return ternary_end_typed_stop(emitter, scan);
}

fn ternary_end_closed(emitter: *const Emitter, colon: u32, scan: u32) bool {
    assert(colon < scan);
    assert(scan < emitter.count);

    const kind = emitter.tokens[scan].kind;
    const text = emitter.tokens[scan].text(emitter.source);

    if (walk.is_close(kind)) return true;
    if (kind == .block_end) return true;
    if (walk.text_is(text, ";")) return true;
    if (walk.text_is(text, ",")) return true;
    return ternary_list_closed(emitter, colon, scan);
}

fn ternary_end_typed(emitter: *const Emitter, colon: u32) bool {
    assert(colon < emitter.count);

    const head = emit.ahead_of(emitter, colon) orelse return false;

    assert(head > colon);

    return emit.roled(emitter, head, brace.role_type);
}

fn ternary_end_typed_stop(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);

    const token = emitter.tokens[scan];
    if (token.kind == .block_start) return !emit.roled(emitter, scan, brace.role_type);

    const text = token.text(emitter.source);
    if (!walk.text_is(text, "=>")) return false;
    return !type_arrowed(emitter, scan);
}

fn ternary_list_closed(emitter: *const Emitter, colon: u32, position: u32) bool {
    assert(colon < emitter.count);
    assert(position < emitter.count);

    const text = emitter.tokens[position].text(emitter.source);
    if (text.len == 0) return false;
    if (text[0] != '>') return false;
    if (emitter.brackets.angles_at(colon) == 0) return false;

    const next = emit.ahead_of(emitter, position) orelse return true;

    assert(next > position);

    return emitter.brackets.angles_at(next) < emitter.brackets.angles_at(colon);
}

pub fn ternary_orphan(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (!emitter.policy.ternary_parts) return false;
    if (!list.spreads(emitter)) return false;

    const text = emitter.tokens[position].text(emitter.source);

    if (walk.text_is(text, "?")) {
        if (optional(emitter, position)) return false;
    } else if (walk.text_is(text, ":")) {
        if (!ternary(emitter, position)) return false;
    } else {
        return false;
    }

    return !ternary_seated(emitter);
}

fn ternary_seated(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);

    return ternary_seated_below(emitter, emitter.depth);
}

fn ternary_seated_below(emitter: *const Emitter, below: u32) bool {
    assert(below <= emitter.depth);
    assert(emitter.depth <= brace.nest_depth_max);

    var depth = below;

    while (depth > 0) {
        assert(depth <= below);

        const frame = emitter.nest[depth - 1];
        if (frame.kind == .block_start) return true;
        if (!ternary_seated_frame(emitter, frame)) return false;

        depth -= 1;
    }

    return true;
}

fn ternary_seated_frame(emitter: *const Emitter, frame: core.Frame) bool {
    assert(frame.open < emitter.count);

    if (frame.spread != null) return true;
    if (ternary_seated_grouped(emitter, frame)) return true;
    return computed_key(emitter, frame.open, frame.close);
}

fn ternary_seated_grouped(emitter: *const Emitter, frame: core.Frame) bool {
    assert(frame.open < emitter.count);

    if (!emitter.policy.chain_simples) return false;
    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return false;
    if (list.calling(emitter, frame.open)) return false;
    if (!split.headed(emitter, frame.open)) return true;
    return ternary_seated_looped(emitter, frame.open);
}

fn ternary_seated_looped(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    const before = emit.word_before(emitter, open) orelse return false;
    return line.word_is(emitter, before, &.{"for"});
}

fn computed_key(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (!emitter.tokens[open].is_punctuation(.bracket_open)) return false;

    const before = computed_key_before(emitter, open) orelse return false;
    const kind = emitter.tokens[before].kind;
    const listed = kind == .block_start or kind.eql(.{ .punctuation = .comma });
    if (!listed) return false;

    const suffixed = list.key_suffixed(emitter, close) orelse return false;
    return emitter.tokens[suffixed].is_punctuation(.colon);
}

fn computed_key_before(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);

    const held = emit.back_of(emitter, open) orelse return null;

    assert(held < open);

    if (!walk.text_is(emitter.tokens[held].text(emitter.source), "readonly")) return held;
    return computed_key_signed(emitter, held) orelse emit.back_of(emitter, held) orelse held;
}

fn computed_key_signed(emitter: *const Emitter, held: u32) ?u32 {
    assert(held < emitter.count);

    const sign = emit.back_of(emitter, held) orelse return null;

    assert(sign < held);
    const text = emitter.tokens[sign].text(emitter.source);
    const signed = walk.text_is(text, "-") or walk.text_is(text, "+");
    if (!signed) return null;
    return emit.back_of(emitter, sign);
}

fn sequenced(emitter: *const Emitter, head: u32, close: u32) bool {
    assert(head < emitter.count);
    assert(close < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const depth = sequenced_depth(emitter, head);
    if (depth == 0) return false;

    const frame = emitter.nest[depth - 1];
    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return false;
    if (list.calling(emitter, frame.open)) return false;

    _ = comment.header_clauses(emitter, frame.open);

    return false;
}

fn sequenced_depth(emitter: *const Emitter, head: u32) u32 {
    assert(head < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return emitter.depth;
    if (line.frame(emitter).open != head) return emitter.depth;
    assert(emitter.depth - 1 < std.math.maxInt(u32));

    return emitter.depth - 1;
}

fn test_objected(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (!emitter.policy.chain_simples) return false;
    if (body.bodied_brace(emitter, open)) return false;

    const before = emit.back_of(emitter, open) orelse return false;

    assert(before < open);

    return span.wrapping_operator(emitter, before);
}

pub fn ternary_head(emitter: *const Emitter, question: u32) ?u32 {
    assert(question < emitter.count);

    var head = question;
    var scan = question;

    for (0..ternary_scan_max) |_| {
        assert(scan <= question);

        const before = emit.back_of(emitter, scan) orelse break;
        const token = emitter.tokens[before];
        const text = token.text(emitter.source);

        if (ternary_head_commented(emitter, question, scan, before)) {
            scan = before;

            continue;
        }

        switch (ternary_head_unit(emitter, question, before)) {
            .absent => {},
            .jump => |open| {
                assert(open <= before);

                head = open;
                scan = open;

                continue;
            },
            .unpaired => return null,
        }

        const objected = ternary_head_objected(emitter, before);
        if (ternary_head_stops(emitter, before, question, objected)) break;

        const closed = walk.is_close(token.kind) or objected;

        if (closed) {
            head = emitter.brackets.open_of(before) orelse return null;
            scan = head;

            continue;
        }

        const cast = walk.text_is(text, "as") or walk.text_is(text, "satisfies");

        if (cast) {
            if (typed_ahead(emitter, before, question)) break;
        }

        if (ternary_head_ended(emitter, before, question)) {
            const arrow = ternary_head_arrow(emitter, before) orelse break;

            head = arrow;
            scan = arrow;

            continue;
        }

        head = before;
        scan = before;
    }

    return if (head == question) null else head;
}

fn ternary_head_unit(emitter: *const Emitter, question: u32, before: u32) Unit {
    assert(before < question);
    assert(question < emitter.count);

    const token = emitter.tokens[before];
    const angled = !walk.is_open(token.kind) and angle_nested(emitter, before, question);
    const closed = walk.is_close(token.kind);

    if (angled) {
        if (!closed) return .{ .jump = before };

        const open = emitter.brackets.open_of(before) orelse return .unpaired;
        return .{ .jump = open };
    }

    const templated = token.kind == .block_end and tmpl.template_closes(emitter, before);
    if (!templated) return .absent;

    const open = emitter.brackets.open_of(before) orelse return .unpaired;
    return .{ .jump = open };
}

fn ternary_head_arrow(emitter: *const Emitter, before: u32) ?u32 {
    assert(before < emitter.count);

    const text = emitter.tokens[before].text(emitter.source);
    const marked = walk.text_is(text, "?") or walk.text_is(text, ":");
    if (!marked) return null;

    const arrow = return_arrow(emitter, before) orelse return null;

    assert(arrow < emitter.count);

    return arrow;
}

fn ternary_head_commented(emitter: *const Emitter, question: u32, scan: u32, before: u32) bool {
    assert(before < emitter.count);
    assert(scan <= question);

    const token = emitter.tokens[before];
    if (token.kind != .comment) return false;

    const text = token.text(emitter.source);

    const block = std.mem.startsWith(u8, text, "/*") and
        std.mem.findScalar(u8, text, '\n') == null;

    const trailed = scan == question and std.mem.startsWith(u8, text, "//");

    if (block) return true;
    if (trailed) return true;

    const back = comment.back(emitter, before) orelse return false;
    return span.wrapping_operator(emitter, back);
}

fn ternary_head_objected(emitter: *const Emitter, before: u32) bool {
    assert(before < emitter.count);

    if (emitter.tokens[before].kind != .block_end) return false;

    const open = emitter.brackets.open_of(before) orelse return false;

    assert(open < before);

    return test_objected(emitter, open);
}

fn ternary_head_stops(emitter: *const Emitter, before: u32, question: u32, objected: bool) bool {
    assert(before < emitter.count);
    assert(before < question);

    const token = emitter.tokens[before];
    const kind = token.kind;
    if (walk.is_open(kind)) return true;
    if (kind == .block_start) return true;

    const bare_end = kind == .block_end and !objected and !ternary_head_typed(emitter, before);
    if (bare_end) return true;
    if (kind == .comment) return true;
    if (walk.substituting(emitter.source, token)) return true;
    if (ternary_head_listed(emitter, before, question)) return true;
    return clause.header_closed(emitter, before);
}

fn ternary_head_typed(emitter: *const Emitter, before: u32) bool {
    assert(before < emitter.count);

    if (emitter.tokens[before].kind != .block_end) return false;

    const open = emitter.brackets.open_of(before) orelse return false;
    if (body.bodied_brace(emitter, open)) return false;
    return ternary_head_extended(emitter, open, before);
}

fn ternary_head_extended(emitter: *const Emitter, open: u32, before: u32) bool {
    assert(open < emitter.count);
    assert(before < emitter.count);

    if (emit.back_of(emitter, open)) |held| {
        if (line.word_is(emitter, held, &.{"extends"})) return true;
    }

    const after = emit.ahead_of(emitter, before) orelse return false;

    assert(after > before);

    return line.word_is(emitter, after, &.{"extends"});
}

fn ternary_head_listed(emitter: *const Emitter, before: u32, question: u32) bool {
    assert(before < emitter.count);
    assert(question < emitter.count);

    if (!walk.text_is(emitter.tokens[before].text(emitter.source), "<")) return false;
    return emitter.brackets.angles_at(before) < emitter.brackets.angles_at(question);
}

fn ternary_head_ended(emitter: *const Emitter, before: u32, question: u32) bool {
    assert(before < emitter.count);
    assert(question < emitter.count);

    const token = emitter.tokens[before];
    const kind = token.kind;
    if (kind.eql(.{ .punctuation = .assign })) return true;
    if (kind.eql(.{ .punctuation = .comma })) return true;
    if (kind.eql(.{ .punctuation = .semicolon })) return true;
    if (kind == .string) return false;
    return ternary_head_worded(emitter, before, question);
}

fn ternary_head_worded(emitter: *const Emitter, before: u32, question: u32) bool {
    assert(before < emitter.count);
    assert(question < emitter.count);

    const text = emitter.tokens[before].text(emitter.source);
    const assigned = std.mem.endsWith(u8, text, "=") and !ternary_head_compared(text);
    if (assigned) return true;
    if (walk.text_is(text, "=>")) return ternary_head_arrowed(emitter, before, question);
    if (walk.text_is(text, "return")) return true;
    if (walk.text_is(text, "throw")) return true;
    if (walk.text_is(text, "case")) return true;
    if (walk.text_is(text, "?")) return true;
    if (walk.text_is(text, ":")) return true;
    return test_worded(emitter, before);
}

fn ternary_head_compared(text: []const u8) bool {
    assert(text.len > 0);

    if (walk.text_is(text, "==")) return true;
    if (walk.text_is(text, "===")) return true;
    if (walk.text_is(text, "!=")) return true;
    if (walk.text_is(text, "!==")) return true;
    if (walk.text_is(text, ">=")) return true;
    return walk.text_is(text, "<=");
}

fn ternary_head_arrowed(emitter: *const Emitter, before: u32, question: u32) bool {
    assert(before < emitter.count);
    assert(question < emitter.count);

    if (return_conditional(emitter, before)) |end| {
        if (end > question) return true;
    }

    return !type_arrowed(emitter, before);
}

pub fn ternary_ahead(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    var scan = position;

    while (scan < emitter.count) {
        if (scan - position >= ternary_scan_max) break;

        const token = emitter.tokens[scan];

        if (tmpl.spanned_unit(emitter, scan)) |end| {
            scan = end + 1;

            continue;
        }

        const angled = !walk.is_close(token.kind) and angle_nested(emitter, scan, position);

        if (angled) {
            const after = if (walk.is_open(token.kind))
                join.closing_of(emitter, scan) orelse return null
            else
                scan;

            scan = after + 1;

            continue;
        }

        const objected = token.kind == .block_start and test_objected(emitter, scan);

        const bodied = token.kind == .block_start and
            !ternary_ahead_extended(emitter, scan) and
            !objected;

        if (bodied) {
            return null;
        }

        const opened = walk.is_open(token.kind) or objected;

        if (opened) {
            scan = (join.closing_of(emitter, scan) orelse return null) + 1;

            continue;
        }

        if (walk.is_close(token.kind)) return null;
        if (token.kind == .block_end) return null;
        if (ternary_ahead_stops(emitter, scan, position)) return null;

        if (return_conditional(emitter, scan)) |end| {
            scan = end + 1;

            continue;
        }

        const text = token.text(emitter.source);
        const questioned = walk.text_is(text, "?") and !optional(emitter, scan);
        if (questioned) return scan;

        scan += 1;
    }

    return null;
}

fn ternary_ahead_extended(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);

    if (body.bodied_brace(emitter, scan)) return false;

    if (emit.back_of(emitter, scan)) |held| {
        if (line.word_is(emitter, held, &.{"extends"})) return true;
    }

    const close = join.closing_of(emitter, scan) orelse return false;

    assert(close > scan);

    const after = emit.ahead_of(emitter, close) orelse return false;

    assert(after > close);

    return line.word_is(emitter, after, &.{"extends"});
}

fn ternary_ahead_stops(emitter: *const Emitter, scan: u32, position: u32) bool {
    assert(scan < emitter.count);
    assert(position < emitter.count);

    const token = emitter.tokens[scan];
    const text = token.text(emitter.source);
    if (walk.text_is(text, ";")) return true;
    if (walk.text_is(text, ",")) return true;
    if (token.kind != .comment) return false;
    if (ternary_ahead_inline(emitter, scan, text)) return false;
    return !ternary_ahead_operand(emitter, scan, position);
}

fn ternary_ahead_inline(emitter: *const Emitter, scan: u32, text: []const u8) bool {
    assert(scan < emitter.count);
    assert(text.len <= std.math.maxInt(u32));

    const block = std.mem.startsWith(u8, text, "/*") and
        std.mem.findScalar(u8, text, '\n') == null;

    if (block) {
        return true;
    }

    if (!std.mem.startsWith(u8, text, "//")) return false;

    const after = emit.ahead_of(emitter, scan) orelse return false;

    assert(after > scan);

    if (!walk.text_is(emitter.tokens[after].text(emitter.source), "?")) return false;
    return !optional(emitter, after);
}

fn ternary_ahead_operand(emitter: *const Emitter, scan: u32, position: u32) bool {
    assert(scan < emitter.count);

    const held = comment.back(emitter, scan) orelse return false;
    if (held < position) return false;
    return span.wrapping_operator(emitter, held);
}

pub fn ternary_leads(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    const held, const link = ternary_linked_at(emitter, position) orelse return;

    if (walk.text_is(emitter.tokens[position].text(emitter.source), "?")) {
        if (link > 0) {
            emitter.wraps_aligned[held] -= 1;

            try emitter.document.push(.dealign);
        }

        const nested = link == 0 and emitter.wrapped[held].wrap == .nested;

        if (nested) {
            try emitter.document.push(.dealign);
        }

        if (link == 0) try line.opens_broken(emitter);

        return;
    }

    emitter.wraps_aligned[held] -= 1;

    try emitter.document.push(.dealign);
}

pub fn ternary_aligns(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.test_aligned) |owed| {
        if (emitter.tokens[position].kind != .comment) {
            assert(owed < core.wrap_depth_max);

            emitter.test_aligned = null;
            emitter.wraps_aligned[owed] += 1;

            try emitter.document.push(.@"align");
        }
    }

    const held, _ = ternary_linked_at(emitter, position) orelse return;

    emitter.wraps_aligned[held] += 1;

    try emitter.document.push(.@"align");

    if (!ternary_tested(emitter, held, position)) return;

    const next = emit.ahead_of(emitter, position);
    const commented = next != null and emitter.tokens[next.?].kind == .comment;

    if (commented) {
        emitter.test_aligned = held;

        return;
    }

    emitter.wraps_aligned[held] += 1;

    try emitter.document.push(.@"align");
}

fn ternary_tested(emitter: *const Emitter, held: u32, position: u32) bool {
    assert(held < emitter.wraps_owed);
    assert(position < emitter.count);

    if (!walk.text_is(emitter.tokens[position].text(emitter.source), ":")) return false;

    const close = emitter.wrapped[held].close;
    return ternary_next(emitter, position, close) != null;
}

pub fn comment_branched(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    const previous = emit.back_of(emitter, position) orelse return null;

    assert(previous < position);

    assert(previous < position);

    if (emitter.tokens[previous].kind != .comment) return null;

    const above = split.coded_at(emitter, previous) orelse return null;
    if (!ternary_parted(emitter, above)) return null;

    const level = line.level_at(emitter, above) orelse return null;

    if (!comment_branched_stepped(emitter, above, previous)) {
        assert(level +| emitter.owns < std.math.maxInt(u32));

        return level +| emitter.owns;
    }

    return emitter.indent;
}

fn comment_branched_stepped(emitter: *const Emitter, above: u32, previous: u32) bool {
    assert(above < emitter.count);
    assert(previous < emitter.count);

    const before = emit.back_of(emitter, above);
    const opened = before != null and body.parts_at(emitter, before.?, above);
    if (opened) return false;
    return !body.parts_at(emitter, above, previous);
}

pub fn ternary_forced(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    const held, const link = ternary_linked_at(emitter, position) orelse return false;

    if (link > 1) return false;

    const wrapped = emitter.wrapped[held];
    const branched = wrapped.wrap == .guarded or wrapped.wrap == .ternary;
    if (!branched) return false;
    if (emitter.wraps_severed[held]) return true;
    return ternary_braced(emitter, wrapped.floor, wrapped.close);
}

pub fn ternary_comment_forced(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    const held, _ = ternary_linked_at(emitter, position) orelse return false;
    const wrapped = emitter.wrapped[held];
    const branched = wrapped.wrap == .guarded or wrapped.wrap == .ternary;
    if (!branched) return false;
    return ternary_commented(emitter, wrapped.start, wrapped.close);
}

fn ternary_commented(emitter: *const Emitter, start: u32, close: u32) bool {
    assert(start <= close);
    assert(close <= emitter.count);

    var depth: u32 = 0;

    for (start..close) |scan| {
        const token = emitter.tokens[scan];
        const opening = walk.is_open(token.kind) or token.kind == .block_start;
        const closing = walk.is_close(token.kind) or token.kind == .block_end;

        if (opening) {
            depth += 1;
        } else if (closing) {
            depth -|= 1;
        } else {}

        const commented = depth == 0 and token.kind == .comment and
            std.mem.startsWith(u8, token.text(emitter.source), "//");

        if (commented) return true;
    }

    return false;
}

fn ternary_braced(emitter: *const Emitter, question: u32, close: u32) bool {
    assert(question <= close);
    assert(close <= emitter.count);

    var braced = false;
    var scan = question;

    while (scan < close) {
        assert(scan < emitter.count);

        const token = emitter.tokens[scan];
        if (walk.text_is(token.text(emitter.source), "=>")) return false;

        const braced_body = token.kind == .block_start and body.bodied_brace(emitter, scan);

        if (braced_body) {
            const after = emit.ahead_of(emitter, scan);
            const unclosed = after != null and emitter.tokens[after.?].kind != .block_end;

            if (unclosed) braced = true;
        }

        scan += 1;
    }

    return braced;
}

pub fn ternary_parted(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    return ternary_linked_at(emitter, position) != null;
}

pub fn ternary_linked_at(emitter: *const Emitter, position: u32) ?struct { u32, u32 } {
    assert(position < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (!emitter.policy.ternary_parts) return null;
    if (emitter.wraps_owed == 0) return null;

    const text = emitter.tokens[position].text(emitter.source);
    const marked = walk.text_is(text, "?") or walk.text_is(text, ":");
    if (!marked) return null;

    var held = emitter.wraps_owed;

    while (held > 0) {
        held -= 1;

        const wrapped = emitter.wrapped[held];

        const branched = wrapped.wrap == .guarded or
            wrapped.wrap == .nested or
            wrapped.wrap == .ternary;

        if (!branched) {
            continue;
        }

        if (position > wrapped.close) continue;

        const index = ternary_link(emitter, wrapped.floor, wrapped.close, position) orelse continue;
        return .{ held, index };
    }

    return null;
}

fn ternary_link(emitter: *const Emitter, question: u32, close: u32, position: u32) ?u32 {
    assert(question <= close);
    assert(close <= emitter.count);

    var scan = question;
    var index: u32 = 0;

    while (index < ternary_chain_max) {
        if (scan == position) return index;

        const colon = ternary_branch(emitter, scan) orelse return null;
        if (colon == position) return index;

        scan = ternary_next(emitter, colon, close) orelse return null;
        index += 1;
    }

    return null;
}

fn ternary_next(emitter: *const Emitter, colon: u32, close: u32) ?u32 {
    assert(colon < emitter.count);
    assert(close <= emitter.count);

    var scan = colon + 1;

    while (scan <= close) {
        if (scan >= emitter.count) break;

        if (tmpl.spanned_unit(emitter, scan)) |end| {
            scan = end + 1;

            continue;
        }

        const kind = emitter.tokens[scan].kind;
        const opening = walk.is_open(kind) or kind == .block_start;

        if (opening) {
            scan = (join.closing_of(emitter, scan) orelse return null) + 1;

            continue;
        }

        if (walk.is_close(kind)) return null;
        if (kind == .block_end) return null;

        const branched = walk.text_is(emitter.tokens[scan].text(emitter.source), "?") and
            !optional(emitter, scan) and ternary_branch(emitter, scan) != null;

        if (branched) {
            assert(scan <= emitter.count);

            return scan;
        }

        scan += 1;
    }

    return null;
}

pub fn value_consequent(emitter: *const Emitter, position: u32) ?struct { u32, core.Wrap } {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const question = comment.back(emitter, position) orelse return null;
    const colon = ternary_branch(emitter, question) orelse return null;
    const end = emit.back_of(emitter, colon) orelse return null;

    assert(end < colon);

    const found = value_tested(emitter, position, end) orelse return null;

    assert(question < position);

    return branch_wrap(emitter, question, end, found);
}

pub fn ternary_branch(emitter: *const Emitter, question: u32) ?u32 {
    assert(question < emitter.count);

    var owed: u32 = 0;
    var scan = question + 1;

    while (scan < emitter.count) {
        if (tmpl.spanned_unit(emitter, scan)) |end| {
            scan = end + 1;

            continue;
        }

        const token = emitter.tokens[scan];
        const opening = walk.is_open(token.kind) or token.kind == .block_start;

        if (opening) {
            scan = (join.closing_of(emitter, scan) orelse return null) + 1;

            continue;
        }

        if (walk.is_close(token.kind)) return null;
        if (token.kind == .block_end) return null;

        const text = token.text(emitter.source);
        if (walk.text_is(text, ";")) return null;

        const questioned = walk.text_is(text, "?") and !optional(emitter, scan);
        const answering = token.is_punctuation(.colon) and !return_colon(emitter, scan);

        if (questioned) {
            owed += 1;
        } else if (answering) {
            if (owed == 0) {
                assert(scan <= emitter.count);

                return scan;
            }

            owed -= 1;
        } else {}

        scan += 1;
    }

    return null;
}

pub fn return_colon(emitter: *const Emitter, colon: u32) bool {
    assert(colon < emitter.count);
    assert(emitter.return_colons.generation > 0);

    const colons = emitter.return_colons;
    const entry = &colons.entries[colon & (return_colon_cache_count - 1)];

    if (entry.generation == colons.generation) {
        if (entry.colon == colon) return entry.answer;
    }

    const answer = return_colon_scanned(emitter, colon);

    entry.* = .{ .colon = colon, .answer = answer, .generation = colons.generation };

    return answer;
}

fn return_colon_scanned(emitter: *const Emitter, colon: u32) bool {
    assert(colon < emitter.count);

    const before = emit.back_of(emitter, colon) orelse return false;

    assert(before < colon);

    if (!emitter.tokens[before].is_punctuation(.paren_close)) return false;

    const after = emit.ahead_of(emitter, colon) orelse return false;

    assert(after > colon);

    if (!emit.roled(emitter, after, brace.role_type)) return false;

    var depth: u32 = 0;
    var scan = colon;

    for (0..return_colon_max) |_| {
        const held = emit.ahead_of(emitter, scan) orelse return false;
        const token = emitter.tokens[held];
        const text = token.text(emitter.source);

        assert(held > scan);

        const opens = walk.is_open(token.kind) or token.kind == .block_start or
            walk.text_is(text, "<");

        const closes = walk.is_close(token.kind) or token.kind == .block_end or
            walk.text_is(text, ">");

        if (opens) {
            depth += 1;
        } else if (closes) {
            if (depth == 0) return false;

            depth -= 1;
        } else if (depth == 0) {
            if (walk.text_is(text, "=>")) return true;
            if (return_colon_stopped(text)) return false;
        } else {}

        scan = held;
    }

    return false;
}

fn return_colon_stopped(text: []const u8) bool {
    assert(text.len > 0);

    for (return_colon_stops) |stop| {
        if (walk.text_eql(stop, text)) return true;
    }

    return false;
}

fn angle_nested(emitter: *const Emitter, position: u32, base: u32) bool {
    assert(position < emitter.count);
    assert(base < emitter.count);

    const held = if (walk.is_close(emitter.tokens[position].kind))
        emitter.brackets.open_of(position) orelse position
    else
        position;

    return emitter.brackets.angles_at(held) > emitter.brackets.angles_at(base);
}

fn ternary_chained(emitter: *const Emitter, question: u32) bool {
    assert(question < emitter.count);

    const head = ternary_head(emitter, question) orelse return true;
    var before = emit.back_of(emitter, head);

    while (before) |held| {
        if (emitter.tokens[held].kind != .comment) break;

        before = emit.back_of(emitter, held);
    }

    const held = before orelse return false;
    const text = emitter.tokens[held].text(emitter.source);
    if (!walk.text_is(text, ":")) return false;
    return ternary_before(emitter, held);
}

fn ternary_before(emitter: *const Emitter, colon: u32) bool {
    assert(colon < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    var depth = emitter.depth;

    while (depth > 0) {
        if (emitter.nest[depth - 1].open < colon) break;

        depth -= 1;
    }

    const stop = if (depth == 0) 0 else emitter.nest[depth - 1].open;
    return ternary_within(emitter, colon, stop);
}

fn typed_ahead(emitter: *const Emitter, from: u32, question: u32) bool {
    assert(from < emitter.count);
    assert(question <= emitter.count);

    if (from >= question) return false;

    for (from..question) |held_usize| {
        if (line.word_is(emitter, @intCast(held_usize), &.{"extends"})) return true;
    }

    return false;
}

fn typing_ahead(emitter: *const Emitter, head: u32, question: u32) bool {
    assert(head <= question);
    assert(question < emitter.count);

    if (!typing_ahead_extends(emitter, head, question)) return false;
    if (typing_ahead_seated(emitter, head, question)) return false;
    return !angle_argued(emitter, head);
}

fn typing_ahead_extends(emitter: *const Emitter, head: u32, question: u32) bool {
    assert(head <= question);

    for (head..question) |held_usize| {
        const held: u32 = @intCast(held_usize);
        if (!line.word_is(emitter, held, &.{"extends"})) continue;

        const before = emit.back_of(emitter, held) orelse return true;
        if (!emit.is_dot(emitter, before)) return true;
    }

    return false;
}

fn typing_ahead_seated(emitter: *const Emitter, head: u32, question: u32) bool {
    assert(question < emitter.count);

    if (!emit.roled(emitter, question, brace.role_spaced)) return false;
    if (emitter.brackets.angles_at(question) != 0) return false;
    assert(head < emitter.count);

    return type_seated(emitter, head);
}

fn angle_argued(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);

    if (!join.angle_spread(emitter, head)) return false;

    const before = join.coded_before(emitter, head) orelse return false;
    const text = emitter.tokens[before].text(emitter.source);

    return walk.text_is(text, "<") or walk.text_is(text, ",");
}

fn type_seated(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);

    const before = join.coded_before(emitter, head) orelse return false;
    const text = emitter.tokens[before].text(emitter.source);
    if (walk.text_is(text, "=")) return true;

    const spaced = emit.roled(emitter, before, brace.role_spaced);
    const spaced_mark = spaced and (walk.text_is(text, "?") or walk.text_is(text, ":"));
    if (spaced_mark) return true;
    if (type_seated_annotated(text, spaced)) return true;
    return type_seated_tested(emitter, before, text);
}

fn type_seated_annotated(text: []const u8, spaced: bool) bool {
    assert(text.len <= std.math.maxInt(u32));

    const colon_tight = walk.text_is(text, ":") and !spaced;
    if (colon_tight) return true;
    if (walk.text_is(text, "as")) return true;
    return walk.text_is(text, "satisfies");
}

fn type_seated_tested(emitter: *const Emitter, before: u32, text: []const u8) bool {
    assert(before < emitter.count);

    if (!walk.text_is(text, "(")) return false;

    const close = join.closing_of(emitter, before) orelse return false;

    assert(close > before);

    if (list.paren_tested(emitter, before, close)) return true;
    if (!emit.roled(emitter, before, brace.role_type)) return false;
    return list.paren_conditional(emitter, before, close);
}

fn type_arrow_head(emitter: *const Emitter, arrow: u32) ?u32 {
    assert(arrow < emitter.count);

    const close = emit.back_of(emitter, arrow) orelse return null;
    if (!emitter.tokens[close].is_punctuation(.paren_close)) return null;

    const open = emitter.brackets.open_of(close) orelse return null;
    const before = emit.back_of(emitter, open) orelse return open;
    if (!walk.text_is(emitter.tokens[before].text(emitter.source), ">")) return open;
    return angle_opening(emitter, before);
}

fn type_arrowed(emitter: *const Emitter, arrow: u32) bool {
    assert(arrow < emitter.count);

    const head = type_arrow_head(emitter, arrow) orelse return false;
    if (emit.roled(emitter, head, brace.role_type)) return true;

    const before = emit.back_of(emitter, head) orelse return false;
    if (!line.word_is(emitter, before, &.{"new"})) return false;
    return emit.roled(emitter, before, brace.role_type);
}

fn return_conditional(emitter: *const Emitter, arrow: u32) ?u32 {
    assert(arrow < emitter.count);

    if (!walk.text_is(emitter.tokens[arrow].text(emitter.source), "=>")) return null;
    if (!type_arrowed(emitter, arrow)) return null;

    const head = type_arrow_head(emitter, arrow) orelse return null;
    const before = emit.back_of(emitter, head) orelse return null;
    if (!line.word_is(emitter, before, &.{"extends"})) return null;
    return return_conditional_scanned(emitter, arrow, head);
}

fn return_conditional_scanned(emitter: *const Emitter, arrow: u32, head: u32) ?u32 {
    assert(arrow < emitter.count);
    assert(head < emitter.count);

    const angles = emitter.brackets.angles_at(arrow);
    var answered = false;
    var extended: u32 = 0;
    var questioned: u32 = 0;
    var last = arrow;
    var scan = emit.ahead_of(emitter, arrow) orelse return null;

    for (0..ternary_scan_max) |_| {
        const token = emitter.tokens[scan];
        const text = token.text(emitter.source);
        const opening = walk.is_open(token.kind) or token.kind == .block_start;

        const ended = walk.is_close(token.kind) or token.kind == .block_end or
            emitter.brackets.angles_at(scan) < angles or
            walk.text_is(text, ";") or walk.text_is(text, ",") or walk.text_is(text, "=");

        if (opening) {
            scan = join.closing_of(emitter, scan) orelse break;
        } else if (ended) {
            break;
        } else if (emitter.brackets.angles_at(scan) == angles) {
            const question_open = walk.text_is(text, "?") and !optional(emitter, scan);

            if (walk.text_is(text, "extends")) {
                extended += 1;
            } else if (question_open) {
                if (extended == 0) break;

                extended -= 1;
                questioned += 1;
            } else if (walk.text_is(text, ":")) {
                if (questioned == 0) break;

                questioned -= 1;
                answered = true;
            } else {}
        } else {}

        if (token.kind != .comment) last = scan;

        scan = emit.ahead_of(emitter, scan) orelse break;
    }

    if (!answered) return null;
    if (extended != 0) return null;
    if (questioned != 0) return null;
    return last;
}

fn return_arrow(emitter: *const Emitter, link: u32) ?u32 {
    assert(link < emitter.count);

    if (emitter.policy.type_words.len == 0) return null;

    var scan = link;

    for (0..return_scan_max) |_| {
        const before = emit.back_of(emitter, scan) orelse return null;

        assert(before < scan);

        const token = emitter.tokens[before];
        const closing = walk.is_close(token.kind) or token.kind == .block_end;

        if (closing) {
            scan = emitter.brackets.open_of(before) orelse return null;

            continue;
        }

        if (walk.is_open(token.kind)) return null;
        if (token.kind == .block_start) return null;

        const text = token.text(emitter.source);
        if (walk.text_is(text, ";")) return null;
        if (walk.text_is(text, "=")) return null;
        if (walk.text_is(text, ",")) return null;

        if (return_conditional(emitter, before)) |end| {
            if (end > link) return before;
        }

        scan = before;
    }

    return null;
}

pub fn angle_opening(emitter: *const Emitter, close: u32) ?u32 {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const depth = emitter.brackets.angles_at(close);
    if (depth == 0) return null;

    var scan = close;

    for (0..ternary_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return null;

        assert(held < scan);

        if (walk.is_close(emitter.tokens[held].kind)) {
            scan = emitter.brackets.open_of(held) orelse return null;

            continue;
        }

        if (emitter.brackets.angles_at(held) < depth) {
            if (!walk.text_is(emitter.tokens[held].text(emitter.source), "<")) return null;
            return held;
        }

        scan = held;
    }

    return null;
}

pub fn ternary_owns(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    return ternary_headed(emitter, position) != null;
}

pub fn assign_ternaried(emitter: *const Emitter, position: u32) ?struct { u32, u32 } {
    assert(position < emitter.count);

    const head = emit.ahead_of(emitter, position) orelse return null;
    const close, const question = ternary_headed(emitter, head) orelse return null;
    const end = emit.ahead_of(emitter, close) orelse return null;
    const token = emitter.tokens[end];

    const ended = token.is_punctuation(.semicolon) or token.is_punctuation(.comma) or
        token.is_punctuation(.paren_close);

    assert(position < head);
    assert(close < end);

    if (!ended) return null;

    const typed = emit.roled(emitter, head, brace.role_type);
    const unbinary = typed or !ternary_binary(emitter, head, question);

    if (unbinary) {
        if (!ternary_filled(emitter, head, question)) return null;
    }

    return .{ end, end };
}

fn ternary_filled(emitter: *const Emitter, head: u32, question: u32) bool {
    assert(head <= question);
    assert(question < emitter.count);

    const tail = ternary_headline(emitter, head, question) orelse return false;
    if (emitter.line_first >= tail) return false;

    const level = @max(emitter.printed, emitter.levels) + span.spread_count(emitter) +
        span.wrap_levels(emitter);

    const lined = ternary_filled_lined(emitter, head, level);

    const from, const based = bind.operand_lined(emitter) orelse
        .{ lined, level * emitter.options.indent_width };

    return based + span.printed_columns(emitter, from, tail) > emitter.options.line_width;
}

fn ternary_filled_lined(emitter: *const Emitter, head: u32, level: u32) u32 {
    assert(head < emitter.count);
    assert(emitter.line_first <= emitter.count);
    assert(level < std.math.maxInt(u32));

    const equals = emit.back_of(emitter, head) orelse return emitter.line_first;

    assert(equals < head);

    return own.alias_parted(emitter, equals, emitter.line_first, level) orelse emitter.line_first;
}

fn ternary_headline(emitter: *const Emitter, head: u32, question: u32) ?u32 {
    assert(head <= question);
    assert(question < emitter.count);

    for (head..question) |index| {
        const scan: u32 = @intCast(index);

        if (walk.is_open(emitter.tokens[scan].kind)) {
            const empty = emit.ahead_of(emitter, scan) == join.closing_of(emitter, scan);

            if (!empty) {
                assert(scan <= emitter.count);

                return scan;
            }
        }
    }

    const tail = emit.back_of(emitter, question) orelse return null;
    const token = emitter.tokens[tail];

    assert(tail < question);

    if (token.kind == .comment) {
        const commented = std.mem.startsWith(u8, token.text(emitter.source), "//");
        if (commented) return emit.back_of(emitter, tail);
    }

    return tail;
}

pub fn branch_run_seat(emitter: *const Emitter, previous: u32) ?u32 {
    assert(previous < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.indent >= emitter.printed) return null;
    if (!binary_branched(emitter, previous)) return null;
    if (!span.binary_headless(emitter, previous)) return null;

    assert(emitter.indent < emitter.printed);

    return emitter.indent;
}

pub fn binary_branched(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const head, const stop = span.binary_run(emitter, previous) orelse return false;
    const before = emit.back_of(emitter, head) orelse return false;

    assert(before < head);

    const question = binary_branched_question(emitter, head, stop, before) orelse return false;
    return ternary_indents(emitter, question);
}

fn binary_branched_question(emitter: *const Emitter, head: u32, stop: u32, before: u32) ?u32 {
    assert(before < head);
    assert(stop < emitter.count);

    const token = emitter.tokens[before];
    const questioned = walk.text_is(token.text(emitter.source), "?");

    if (questioned) {
        if (!optional(emitter, before)) {
            const colon = ternary_branch(emitter, before) orelse return null;
            if (emit.back_of(emitter, colon) != stop) return null;
            return before;
        }
    }

    if (!token.is_punctuation(.colon)) return null;

    const end = own.value_branch(emitter, head) orelse return null;
    if (emit.back_of(emitter, end) != stop) return null;
    return ternary_question(emitter, before, bind.enclosing_open(emitter, before) orelse 0);
}

pub fn branch_wrap(
    emitter: *const Emitter,
    question: u32,
    end: u32,
    found: struct { u32, core.Wrap },
) struct { u32, core.Wrap } {
    assert(question < emitter.count);
    assert(end < emitter.count);
    assert(found[0] <= end);

    const stop = found[0];
    if (stop != end) return found;
    if (!ternary_indents(emitter, question)) return found;

    assert(stop == end);

    return .{ stop, .argued };
}

pub fn value_tested(emitter: *const Emitter, position: u32, end: u32) ?struct { u32, core.Wrap } {
    assert(position < emitter.count);
    assert(end < emitter.count);

    const tested = value_tested_stop(emitter, position, end);
    const stop = tested orelse end;
    if (stop <= position) return null;
    if (!own.valued_binary(emitter, position, stop)) return null;

    assert(stop > position);

    return .{ stop, .paired };
}

fn value_tested_stop(emitter: *const Emitter, position: u32, end: u32) ?u32 {
    assert(position < emitter.count);
    assert(end < emitter.count);

    const question = ternary_ahead(emitter, position) orelse return null;
    if (question > end) return null;
    if (ternary_head(emitter, question) != position) return null;
    return emit.back_of(emitter, question);
}

pub fn ternary_indents(emitter: *const Emitter, question: u32) bool {
    assert(question < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const head = ternary_head(emitter, question) orelse return false;
    const seat = emit.back_of(emitter, head) orelse return false;
    const token = emitter.tokens[seat];
    const text = token.text(emitter.source);

    assert(seat < head);

    if (walk.text_is(text, "return")) return !ternary_sequenced(emitter, question);
    if (walk.text_is(text, "throw")) return !ternary_sequenced(emitter, question);

    const open = if (token.is_punctuation(.comma)) bind.enclosing_open(emitter, seat) else seat;
    const held = open orelse return false;
    if (!emitter.tokens[held].is_punctuation(.paren_open)) return false;
    return list.calling(emitter, held);
}

fn ternary_sequenced(emitter: *const Emitter, question: u32) bool {
    assert(question < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const colon = ternary_branch(emitter, question) orelse return false;
    const close = ternary_end(emitter, colon) orelse return false;
    const held = emit.ahead_of(emitter, close) orelse return false;

    assert(held > close);

    return emitter.tokens[held].is_punctuation(.comma);
}

pub fn ternary_binary(emitter: *const Emitter, head: u32, question: u32) bool {
    assert(head <= question);
    assert(question < emitter.count);

    const whole = ternary_binary_whole(emitter, head, question);
    var scan = if (whole) head + 1 else head;
    const until = if (whole) join.closing_of(emitter, head) orelse question else question;

    while (scan < until) {
        assert(scan < emitter.count);

        const token = emitter.tokens[scan];

        if (tmpl.spanned_unit(emitter, scan)) |end| {
            assert(end >= scan);

            scan = end + 1;

            continue;
        }

        const opens = walk.is_open(token.kind) or token.kind == .block_start;

        if (opens) {
            const end = join.closing_of(emitter, scan) orelse return false;

            assert(end > scan);

            scan = end + 1;

            continue;
        }

        const text = token.text(emitter.source);
        const angled = angle_text(text) and !emit.roled(emitter, scan, brace.role_spaced);

        if (binary_operator(text)) {
            if (!angled) return true;
        }

        scan += 1;
    }

    return false;
}

fn ternary_binary_whole(emitter: *const Emitter, head: u32, question: u32) bool {
    assert(head <= question);
    assert(question < emitter.count);

    if (!emitter.tokens[head].is_punctuation(.paren_open)) return false;

    const close = join.closing_of(emitter, head) orelse return false;

    assert(close > head);

    return emit.ahead_of(emitter, close) == question;
}

fn angle_text(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    for (text) |byte| {
        switch (byte) {
            '<', '>' => {},
            else => return false,
        }
    }

    return true;
}
