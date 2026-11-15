const std = @import("std");
const assert = std.debug.assert;
const Token = @import("../../syntax/token.zig");
const bind = @import("bind.zig");
const body = @import("body.zig");
const brace = @import("../brace.zig");
const comment = @import("comment.zig");
const core = @import("emitter.zig");
const edge = @import("edge.zig");
const emit = @import("emit.zig");
const join = @import("join.zig");
const jsx = @import("jsx.zig");
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

const Composed = struct {
    calls: u32 = 0,
    found: bool = false,
    last: u32 = 0,
    newed: bool,
    owed_calls: u32 = 0,
    owed_found: bool = false,
};

const Piece = struct {
    from: u32,
    to: u32,
    depth: u32,
};

const Queue = struct {
    pieces: [simple_work_max]Piece,
    queued: u32,
};

const argument_count_max: u32 = 64;
const arrow_type_marks: [8][]const u8 = .{ ".", "<", ">", "[", "]", "|", "&", "," };
const arrow_type_max: u32 = 24;

const arrow_type_words: [12][]const u8 = .{
    "any",
    "bigint",
    "boolean",
    "never",
    "null",
    "number",
    "object",
    "string",
    "symbol",
    "undefined",
    "unknown",
    "void",
};

const callee_heads: [3][]const u8 = .{ "import", "super", "this" };
const callee_links: [4][]const u8 = .{ "!", ".", "?.", "this" };
const callee_scan_max: u32 = 32;
const cast_stops: [6][]const u8 = .{ "=>", "||", "&&", "??", "=", "," };
const cast_words: [2][]const u8 = .{ "as", "satisfies" };

const import_type_marks: [10][]const u8 = .{
    "&",
    "<",
    "as",
    "extends",
    "is",
    "keyof",
    "readonly",
    "satisfies",
    "typeof",
    "|",
};

const operand_narrow_max: u32 = 8;
const piece_prefixes: [6][]const u8 = .{ "!", "+", "++", "-", "--", "~" };
const piece_suffixes: [2][]const u8 = .{ "++", "--" };
const primary_keywords: [6][]const u8 = .{ "false", "null", "super", "this", "true", "undefined" };
const logical_level_max: u32 = 3;
const member_marks: [2][]const u8 = .{ ".", "?." };
const regex_pattern_max: u32 = 5;
const comment_trail_max: u32 = 16;
const return_scan_max: u32 = 128;

const short_operators: [25][]const u8 = .{
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
    "??",
    "^",
    "in",
    "instanceof",
    "|",
    "||",
};

const simple_step_max: u32 = 256;

const simple_types: [15][]const u8 = .{
    "any",
    "bigint",
    "boolean",
    "false",
    "never",
    "null",
    "number",
    "object",
    "string",
    "symbol",
    "this",
    "true",
    "undefined",
    "unknown",
    "void",
};

const simple_work_max: u32 = 64;
const test_argument_max: u32 = 3;

const test_modes: [7][]const u8 = .{
    "concurrent",
    "failing",
    "fails",
    "only",
    "sequential",
    "skip",
    "todo",
};

const test_name_max: u32 = 5;
const test_setups: [4][]const u8 = .{ "afterAll", "afterEach", "beforeAll", "beforeEach" };

const test_skips: [7][]const u8 = .{
    "fdescribe",
    "fit",
    "ftest",
    "skip",
    "xdescribe",
    "xit",
    "xtest",
};

const test_steps: [6][]const u8 = .{
    "concurrent",
    "only",
    "sequential",
    "shuffle",
    "skip",
    "todo",
};

const test_wrappers: [4][]const u8 = .{ "async", "fakeAsync", "inject", "waitForAsync" };
const type_head_max: u32 = 64;
const unary_marks: [4][]const u8 = .{ "!", "+", "-", "~" };

pub fn argument_end(emitter: *const Emitter, from: u32, close: u32) u32 {
    assert(from < emitter.count);
    assert(close < emitter.count);

    if (core.memo_found(emitter, .argument_end, from, close)) |answer| return answer;

    const held = argument_end_scanned(emitter, from, close);

    core.memo_store(emitter, .argument_end, from, close, held);

    return held;
}

fn argument_end_scanned(emitter: *const Emitter, from: u32, close: u32) u32 {
    assert(from <= emitter.count);
    assert(close <= emitter.count);

    var depth: u32 = 0;
    var scan = from;

    while (scan < close) {
        if (spanned_body(emitter, scan)) |end| {
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
            const separated = kind.eql(.{ .punctuation = .comma }) or
                kind.eql(.{ .punctuation = .semicolon });

            if (separated) {
                if (emitter.brackets.angles_at(scan) == 0) return scan;
            }
        } else {}

        scan += 1;
    }

    return close;
}

fn arguments_simple(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open <= close);
    assert(close < emitter.count);

    const from = argument_head(emitter, open, close) orelse return true;
    const to = emit.back_of(emitter, close) orelse return true;
    if (to < from) return true;

    var scan = from;

    while (scan <= to) : (scan += 1) {
        if (emitter.tokens[scan].kind == .comment) return false;
    }

    var queue: Queue = .{ .pieces = undefined, .queued = 0 };

    _ = simple_items(emitter, &queue, open, close, 0) orelse return false;

    assert(queue.queued <= simple_work_max);

    if (queue.queued == 0) return true;
    return simple_walked(emitter, &queue);
}

pub fn functioned(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from < emitter.count);
    assert(to <= emitter.count);

    var head = from;

    if (walk.text_is(emitter.tokens[head].text(emitter.source), "async")) {
        const after = emit.ahead_of(emitter, head) orelse return false;
        if (after >= to) return false;

        head = after;
    }

    if (walk.text_is(emitter.tokens[head].text(emitter.source), "<")) {
        head = functioned_generic(emitter, head, to);
    }

    const token = emitter.tokens[head];
    if (walk.text_is(token.text(emitter.source), "function")) return true;
    if (token.is_punctuation(.paren_open)) return arrow_parted(emitter, head, to);
    if (token.kind != .identifier) return false;

    const after = emit.ahead_of(emitter, head) orelse return false;
    if (after >= to) return false;
    return walk.text_is(emitter.tokens[after].text(emitter.source), "=>");
}

fn functioned_generic(emitter: *const Emitter, head: u32, to: u32) u32 {
    assert(head < emitter.count);
    assert(to <= emitter.count);

    if (join.angle_close(emitter, head)) |close| {
        if (emit.ahead_of(emitter, close)) |after| {
            if (after < to) return after;
        }
    }

    var scan = head + 1;

    while (scan < to) : (scan += 1) {
        if (emitter.brackets.angles_at(scan) == 0) break;
    }

    if (scan >= to) return head;
    if (scan <= head + 1) return head;
    assert(scan <= emitter.count);

    return scan;
}

fn arrow_parted(emitter: *const Emitter, open: u32, to: u32) bool {
    assert(open < emitter.count);
    assert(emitter.tokens[open].is_punctuation(.paren_open));

    const close = join.closing_of(emitter, open) orelse return false;
    if (close >= to) return false;

    var depth: u32 = 0;
    var scan = close + 1;

    while (scan < to) {
        if (spanned_body(emitter, scan)) |end| {
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
            if (walk.text_is(token.text(emitter.source), "=>")) return true;
        } else {}

        scan += 1;
    }

    return false;
}

pub fn spread_arrowed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const after = emit.ahead_of(emitter, position) orelse return false;
    const text = emitter.tokens[after].text(emitter.source);
    if (walk.text_is(text, "=>")) return !arrow_asserted(emitter, after);
    if (!emitter.tokens[after].is_punctuation(.colon)) return false;
    if (tern.ternary(emitter, after)) return false;

    var depth: u32 = 0;
    var scan = after;

    for (0..type_head_max) |_| {
        const held = emit.ahead_of(emitter, scan) orelse return false;
        const kind = emitter.tokens[held].kind;

        assert(held > scan);

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            if (depth == 0) return false;

            depth -= 1;
        } else if (depth == 0) {
            if (walk.text_is(emitter.tokens[held].text(emitter.source), "=>")) return true;
        } else {}

        scan = held;
    }

    return false;
}

fn arrow_asserted(emitter: *const Emitter, arrow: u32) bool {
    assert(arrow < emitter.count);
    assert(emitter.roles.len == emitter.count);

    const held = emit.ahead_of(emitter, arrow) orelse return false;
    if (!walk.text_is(emitter.tokens[held].text(emitter.source), "<")) return false;
    return emitter.roles[held] & (brace.role_jsx | brace.role_jsx_tag) == 0;
}

const hook_argument_max: u32 = 3;
const wrapped_words: [2][]const u8 = .{ "return", "throw" };

const ArrowSeat = struct {
    chained: bool,
    listed: bool,
    owned: bool,
    paren: bool,
    valued: bool,
};

fn hooked_args(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var heads: [hook_argument_max]struct { u32, u32 } = @splat(.{ 0, 0 });
    var count: u32 = 0;
    var start = argument_head(emitter, open, close);

    while (start) |from| {
        const to = argument_end(emitter, from, close);

        if (count == hook_argument_max) return false;

        heads[count] = .{ from, to };
        count += 1;
        start = argument_head(emitter, to, close);
    }

    const counted = count >= 2 and count <= 3;
    if (!counted) return false;

    const callback, const callback_end = heads[count - 2];
    const deps, const deps_end = heads[count - 1];

    return hooked_callback(emitter, callback, callback_end) and
        hooked_deps(emitter, deps, deps_end);
}

fn hooked_callback(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from < to);
    assert(to <= emitter.count);

    var head = from;

    if (walk.text_is(emitter.tokens[head].text(emitter.source), "async")) {
        const after = emit.ahead_of(emitter, head) orelse return false;
        if (after >= to) return false;

        head = after;
    }

    if (!emitter.tokens[head].is_punctuation(.paren_open)) return false;

    const close = join.closing_of(emitter, head) orelse return false;
    if (close >= to) return false;
    if (emit.ahead_of(emitter, head) != close) return false;

    const arrow = emit.ahead_of(emitter, close) orelse return false;
    if (arrow >= to) return false;
    if (!walk.text_is(emitter.tokens[arrow].text(emitter.source), "=>")) return false;

    const held = emit.ahead_of(emitter, arrow) orelse return false;
    return emitter.tokens[held].kind == .block_start;
}

fn hooked_deps(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from < to);
    assert(to <= emitter.count);

    if (!emitter.tokens[from].is_punctuation(.bracket_open)) return false;

    const close = join.closing_of(emitter, from) orelse return false;
    const after = emit.ahead_of(emitter, close) orelse return true;

    return after >= to;
}

fn composes(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var count: u32 = 0;
    var start = argument_head(emitter, open, close);

    while (start) |from| {
        const to = argument_end(emitter, from, close);

        count += 1;

        if (count > argument_count_max) return false;
        if (functioned(emitter, from, to)) return true;

        start = argument_head(emitter, to, close);
    }

    return false;
}

fn arrow_bodied(emitter: *const Emitter, position: u32) ?struct { u32, core.Wrap } {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const head = emit.ahead_of(emitter, position) orelse return null;
    const end = arrow_bodied_end(emitter, position, head) orelse return null;
    if (bodied_arrow(emitter, arrow_body_coded(emitter, head), end)) return null;

    const last = arrow_last(emitter, end) orelse return null;
    if (arrow_sequence(emitter, head, last)) return null;
    if (last < head) return null;
    return .{ last, .bodied };
}

fn arrow_last(emitter: *const Emitter, end: u32) ?u32 {
    assert(end <= emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var last = emit.word_before(emitter, end) orelse return null;

    for (0..emitter.count) |_| {
        if (emitter.tokens[last].kind != .comment) return last;

        const before = emit.word_before(emitter, last) orelse return last;
        if (!body.parts_at(emitter, before, last)) return last;

        last = before;
    }

    return last;
}

fn arrow_body_coded(emitter: *const Emitter, head: u32) u32 {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const text = emitter.tokens[head].text(emitter.source);

    if (emitter.tokens[head].kind != .comment) return head;
    if (!std.mem.startsWith(u8, text, "/*")) return head;
    if (std.mem.findScalar(u8, text, '\n') != null) return head;
    return line.coding(emitter, head) orelse head;
}

pub fn arrow_wrapped(emitter: *const Emitter, position: u32) ?struct { u32, core.Wrap } {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.arrow_bodies) return null;
    if (!walk.text_is(emitter.tokens[position].text(emitter.source), "=>")) return null;

    const typed = if (emit.ahead_of(emitter, position)) |held|
        emit.roled(emitter, held, brace.role_type) and !cast_bodied(emitter, held)
    else
        false;

    if (typed) return null;

    const sequenced = if (emit.ahead_of(emitter, position)) |held|
        list.arrow_sequenced(emitter, held)
    else
        false;

    if (sequenced) return null;
    if (jsx.arrow_bodied(emitter, position)) |last| return .{ last, .bodied };
    if (jsx.unframed(emitter)) return null;

    const chain_tail = own.chain_tailed(emitter, position, .bodied);
    const headed = emitter.arrowed or emitter.arrow_head == position or chain_tail;
    if (headed) return arrow_bodied(emitter, position);

    const chained = arrow_chained_head(emitter, position);

    if (chained) {
        const rooted = emitter.depth == 0 or emitter.arrowed;
        if (rooted) return arrow_bodied(emitter, position);
        if (arrow_bodied(emitter, position)) |held| return held;
    }

    if (arrow_branched(emitter, position)) |held| return held;
    if (arrow_stated(emitter, position)) return arrow_bodied(emitter, position);
    if (emitter.depth == 0) return null;
    if (return_arrowed(emitter, position)) return arrow_bodied(emitter, position);
    return arrow_wrapped_seated(emitter, position, chained);
}

fn arrow_wrapped_seated(
    emitter: *const Emitter,
    position: u32,
    chained: bool,
) ?struct { u32, core.Wrap } {
    assert(position < emitter.count);
    assert(emitter.depth > 0);

    const frame = emitter.nest[emitter.depth - 1];

    const seat: ArrowSeat = .{
        .chained = chained,
        .listed = frame.kind.eql(.{ .punctuation = .bracket_open }) and list.spreads(emitter),
        .owned = frame.kind.eql(.{ .punctuation = .paren_open }) and list.spreads(emitter),
        .paren = frame.kind.eql(.{ .punctuation = .paren_open }),
        .valued = frame.kind == .block_start and !tern.typed_frame(emitter),
    };

    const unhugged = arrow_unhugged(emitter, frame, position);
    const spread_valued = if (seat.valued) list.spreads(emitter) else false;
    const admitted = seat.owned or seat.listed or spread_valued or unhugged;
    if (!admitted) return null;

    const head = emit.ahead_of(emitter, position) orelse return null;
    if (head >= frame.close) return null;

    const item = argument_start(emitter, frame.open, position);
    const valued_seat = valued_start(emitter, item, position, seat.valued);
    const branched = branched_start(emitter, valued_seat, position);
    const seated_at = branched orelse valued_seat;
    const start = defaulted_start(emitter, seated_at, position);

    const end = if (branched != null)
        branched_end(emitter, position, frame.close)
    else
        argument_end(emitter, head, frame.close);

    const body_head = line.coding(emitter, position) orelse head;
    const body_from = if (body_head < frame.close) body_head else head;
    const seated = seat.owned or seat.listed;
    const coded = if (seated) comments_passed(emitter, start, end) else start;

    if (bodied_arrow(emitter, body_from, end)) return null;
    if (!functioned(emitter, coded, end)) return null;

    if (start != seated_at) {
        if (!item_overflows(emitter, item, end)) return null;
    }

    return arrow_wrapped_tail(emitter, seat, frame, position, head, end, coded != start);
}

fn comments_passed(emitter: *const Emitter, start: u32, end: u32) u32 {
    assert(start < emitter.count);
    assert(end <= emitter.count);

    var held = start;

    while (held < end) {
        if (emitter.tokens[held].kind != .comment) break;

        const ahead = emit.ahead_of(emitter, held) orelse break;

        assert(ahead > held);

        held = ahead;
    }

    return held;
}

fn arrow_wrapped_tail(
    emitter: *const Emitter,
    seat: ArrowSeat,
    frame: core.Frame,
    position: u32,
    head: u32,
    end: u32,
    commented: bool,
) ?struct { u32, core.Wrap } {
    assert(head <= end);
    assert(end <= frame.close);
    assert(position < emitter.count);

    const ternary = ternary_bodied(emitter, head, end);
    const grouped = called_args(emitter, head, end) != null or ternary;
    const comma = emitter.tokens[end].is_punctuation(.comma);

    const seated = end == frame.close or emit.ahead_of(emitter, end) == frame.close or
        (seat.valued and comma) or ((seat.owned or seat.listed) and comma);

    const grouped_paren = seat.paren and !seat.owned and arrow_unhugged(emitter, frame, position);
    const ternary_seated = (seat.owned or seat.listed or seat.valued or grouped_paren) and seated;

    if (ternary) {
        if (!ternary_seated) return null;
    }

    const tail = end == frame.close or emit.ahead_of(emitter, end) == frame.close;
    const last = arrow_last(emitter, end) orelse return null;
    if (last < head) return null;

    const hugged = seat.owned and tail and grouped and !seat.chained and !commented;
    return .{ last, if (hugged) .hugged else .bodied };
}

fn tested_each(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const close = emit.back_of(emitter, open) orelse return false;
    if (!emitter.tokens[close].is_punctuation(.paren_close)) return false;

    const inner = emitter.brackets.open_of(close) orelse return false;
    const name = emit.word_before(emitter, inner) orelse return false;
    const text = emitter.tokens[name].text(emitter.source);
    const named = walk.text_is(text, "each") or walk.text_is(text, "for");
    if (!named) return false;

    const dot = emit.word_before(emitter, name) orelse return false;
    if (!emitter.tokens[dot].is_punctuation(.dot)) return false;
    return tested_callee(emitter, dot);
}

fn tested_head(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from <= to);
    assert(to < emitter.count);

    const end = tmpl.template_body(emitter, from) orelse from;

    if (end == from) {
        if (emitter.tokens[from].kind != .string) return false;
    }

    var after = emit.ahead_of(emitter, end);

    for (0..test_argument_max) |_| {
        const held = after orelse break;
        if (held >= to) break;
        if (emitter.tokens[held].kind != .comment) break;

        after = emit.ahead_of(emitter, held);
    }

    const held = after orelse return true;
    return held >= to;
}

fn tested_simple(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from <= to);
    assert(to < emitter.count);

    var head = from;

    if (walk.text_is(emitter.tokens[head].text(emitter.source), "async")) {
        head = argument_head(emitter, head, to) orelse return false;
    }

    if (walk.text_is(emitter.tokens[head].text(emitter.source), "function")) {
        const after = argument_head(emitter, head, to) orelse return false;

        head = after;

        if (emitter.tokens[after].kind == .identifier) {
            head = argument_head(emitter, after, to) orelse after;
        }
    }

    if (!emitter.tokens[head].is_punctuation(.paren_open)) return false;

    const close = join.closing_of(emitter, head) orelse return false;
    if (close >= to) return false;

    var scan = head + 1;

    while (scan < close) : (scan += 1) {
        if (emitter.tokens[scan].is_punctuation(.comma)) return false;
    }

    return tested_bodied(emitter, close, to);
}

fn tested_bodied(emitter: *const Emitter, close: u32, to: u32) bool {
    assert(close < to);
    assert(to < emitter.count);

    const after = argument_head(emitter, close, to) orelse return false;
    if (emitter.tokens[after].kind == .block_start) return true;
    if (!walk.text_is(emitter.tokens[after].text(emitter.source), "=>")) return false;

    const held = emit.ahead_of(emitter, after) orelse return false;
    return emitter.tokens[held].kind == .block_start;
}

fn tested_callee(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var names: [test_name_max]u32 = @splat(0);
    var count: u32 = 0;
    var scan = emit.word_before(emitter, open);

    for (0..emitter.count) |_| {
        const held = scan orelse break;
        const token = emitter.tokens[held];

        assert(held < open);

        if (token.kind == .identifier) {
            if (count == test_name_max) return false;

            names[count] = held;
            count += 1;
            scan = emit.word_before(emitter, held);

            if (scan) |before| {
                if (!emitter.tokens[before].is_punctuation(.dot)) scan = null;
            }

            continue;
        }

        if (!token.is_punctuation(.dot)) break;

        scan = emit.word_before(emitter, held);
    }

    if (count == 0) return false;
    return tested_named(emitter, names[0..count]);
}

fn tested_named(emitter: *const Emitter, names: []const u32) bool {
    assert(names.len > 0);
    assert(names.len <= test_name_max);

    const first = emitter.tokens[names[names.len - 1]].text(emitter.source);
    const second = tested_name(emitter, names, 2);
    const third = tested_name(emitter, names, 3);

    if (walk.text_is(first, "describe")) {
        const held = second orelse return names.len == 1;
        return tested_listed(&test_steps, held, third);
    }

    const tests = walk.text_is(first, "it") or walk.text_is(first, "test");

    if (tests) {
        const held = second orelse return true;
        if (walk.text_is(held, "step")) return third == null;
        return tested_listed(&test_modes, held, third);
    }

    if (walk.text_is(first, "Deno")) {
        const held = second orelse return false;
        if (!walk.text_is(held, "test")) return false;
        return third == null;
    }

    return word_listed(&test_skips, first);
}

fn tested_name(emitter: *const Emitter, names: []const u32, rank: u32) ?[]const u8 {
    assert(rank >= 2);
    assert(names.len <= test_name_max);

    if (names.len < rank) return null;
    return emitter.tokens[names[names.len - rank]].text(emitter.source);
}

fn tested_listed(words: []const []const u8, held: []const u8, third: ?[]const u8) bool {
    assert(words.len > 0);
    assert(held.len > 0);

    if (!word_listed(words, held)) return false;
    if (third) |unwrapped| assert(unwrapped.len <= std.math.maxInt(u32));

    const at = third orelse return true;
    return word_listed(words, at);
}

pub fn spanned_body(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (tmpl.template_body(emitter, position)) |end| return end;
    return span.jsx_body(emitter, position);
}

fn tested_args(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (!emitter.policy.test_joins) return false;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const each = tested_each(emitter, open);

    if (!each) {
        if (!list.calling(emitter, open)) return false;
        if (tested_wrapped(emitter, open, close)) return true;
        if (!tested_callee(emitter, open)) return false;
    }

    var heads: [test_argument_max]struct { u32, u32 } = @splat(.{ 0, 0 });
    var count: u32 = 0;
    var start = argument_head(emitter, open, close);

    while (start) |from| {
        const to = argument_end(emitter, from, close);

        if (count == test_argument_max) return false;

        heads[count] = .{ from, to };
        count += 1;
        start = argument_head(emitter, to, close);
    }

    assert(count <= test_argument_max);

    if (count < 2) return false;

    const title, const title_end = heads[0];
    const second, const second_end = heads[1];

    if (!each) {
        if (!tested_head(emitter, title, title_end)) return false;
    }

    const wrapped = tested_wrapper(emitter, second, second_end);

    if (!wrapped) {
        if (!functioned(emitter, second, second_end)) return false;
    }

    if (count == 2) return true;

    const third, const third_end = heads[2];
    if (emitter.tokens[third].kind != .number) return false;
    if (argument_head(emitter, third, third_end) != null) return false;
    if (wrapped) return true;
    return tested_simple(emitter, second, second_end);
}

fn tested_wrapped(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const from = argument_head(emitter, open, close) orelse return false;
    const to = argument_end(emitter, from, close);
    if (argument_head(emitter, to, close) != null) return false;

    const callee = emit.word_before(emitter, open) orelse return false;

    if (emit.back_of(emitter, callee)) |held| {
        if (emit.is_dot(emitter, held)) return false;
    }

    if (line.word_is(emitter, callee, &test_setups)) return tested_wrapper(emitter, from, to);
    if (!line.word_is(emitter, callee, &test_wrappers)) return false;
    if (!functioned(emitter, from, to)) return false;
    if (emitter.depth == 0) return false;
    return emitter.nest[emitter.depth - 1].joined;
}

fn tested_wrapper(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from < to);
    assert(to < emitter.count);

    if (!line.word_is(emitter, from, &test_wrappers)) return false;

    const open = emit.ahead_of(emitter, from) orelse return false;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const close = join.closing_of(emitter, open) orelse return false;
    return emit.word_before(emitter, to) == close;
}

pub fn tested_joined(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.test_joins) return false;
    if (emitter.depth == 0) return false;
    if (position == 0) return false;
    return emitter.nest[emitter.depth - 1].joined;
}

pub fn joined_args(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (tested_args(emitter, open, close)) return true;
    if (!emitter.policy.test_joins) return false;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;
    if (!list.calling(emitter, open)) return false;
    return hooked_args(emitter, open, close);
}

pub fn hugged_first(emitter: *const Emitter, open: u32, close: u32, position: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var heads: [2]struct { u32, u32 } = .{ .{ 0, 0 }, .{ 0, 0 } };
    var argued: u32 = 0;
    var start = argument_head(emitter, open, close);

    while (start) |from| {
        const to = argument_end(emitter, from, close);

        if (argued == 2) return false;

        heads[argued] = .{ from, to };
        argued += 1;
        start = argument_head(emitter, to, close);
    }

    if (argued != 2) return false;

    const lead_from, const lead_to = heads[0];
    const tail_from, const tail_to = heads[1];

    if (lead_from >= position) return false;
    if (position >= lead_to) return false;
    if (!functioned(emitter, lead_from, lead_to)) return false;
    if (!bodied_tail(emitter, lead_from, lead_to)) return false;
    if (!blocked_first(emitter, lead_from, lead_to)) return false;
    if (!body_ended(emitter, lead_to)) return false;
    if (!short_argument(emitter, tail_from, tail_to)) return false;
    return !groupable_argument(emitter, tail_from, tail_to);
}

fn argument_head(emitter: *const Emitter, scan: u32, close: u32) ?u32 {
    assert(scan < emitter.count);
    assert(close < emitter.count);

    const held = emit.ahead_of(emitter, scan) orelse return null;

    assert(held > scan);

    if (held >= close) return null;
    return held;
}

fn groupable_argument(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from < emitter.count);
    assert(to <= emitter.count);

    const kind = emitter.tokens[from].kind;
    const grouping = kind == .block_start or kind.eql(.{ .punctuation = .bracket_open });
    if (!grouping) return false;

    const close = join.closing_of(emitter, from) orelse return false;
    const after = emit.ahead_of(emitter, close);
    const whole = after == to;
    const cast = if (after) |held| cast_before(emitter, held, to) else false;

    if (!whole) {
        if (!cast) return false;
    }

    return emit.ahead_of(emitter, from) != close;
}

fn cast_before(emitter: *const Emitter, held: u32, to: u32) bool {
    assert(held < emitter.count);
    assert(to <= emitter.count);

    if (held >= to) return false;
    return word_listed(&cast_words, emitter.tokens[held].text(emitter.source));
}

fn short_argument(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from < emitter.count);
    assert(to <= emitter.count);

    const stop = argument_last(emitter, from, to) orelse return false;
    const operator, const cast = short_split(emitter, from, stop) orelse return false;
    if (operator) |held| return short_operated(emitter, from, held, stop);
    if (cast) |held| return short_cast(emitter, from, held, stop);
    return short_plain(emitter, from, stop);
}

fn short_split(emitter: *const Emitter, from: u32, stop: u32) ?struct { ?u32, ?u32 } {
    assert(from <= stop);
    assert(stop < emitter.count);

    var depth: u32 = 0;
    var operator: ?u32 = null;
    var cast: ?u32 = null;
    var scan = from;

    while (scan <= stop) : (scan += 1) {
        const token = emitter.tokens[scan];
        const text = token.text(emitter.source);

        if (walk.text_is(text, "<")) {
            if (join.angle_close(emitter, scan)) |close| {
                assert(close > scan);

                scan = close;

                continue;
            }
        }

        if (walk.is_open(token.kind)) {
            depth += 1;
        } else if (walk.is_close(token.kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            const casts = scan > from and word_listed(&cast_words, text);
            const operates = !casts and short_operator(emitter, from, scan);
            const found = operator != null or cast != null;

            if (casts) {
                if (found) return null;

                cast = scan;
            } else if (operates) {
                if (found) return null;

                operator = scan;
            } else {}
        } else {}
    }

    return .{ operator, cast };
}

fn short_operator(emitter: *const Emitter, from: u32, scan: u32) bool {
    assert(from <= scan);
    assert(scan < emitter.count);

    if (!word_listed(&short_operators, emitter.tokens[scan].text(emitter.source))) return false;

    const held = emit.back_of(emitter, scan) orelse return false;
    if (held < from) return false;
    return walk.ends_operand(emitter.tokens[held].kind);
}

fn short_operated(emitter: *const Emitter, from: u32, operator: u32, stop: u32) bool {
    assert(from < operator);
    assert(operator <= stop);

    const before = emit.back_of(emitter, operator) orelse return false;
    if (!simple_range(emitter, from, before)) return false;

    const after = emit.ahead_of(emitter, operator) orelse return false;
    return simple_range(emitter, after, stop);
}

fn short_cast(emitter: *const Emitter, from: u32, word: u32, stop: u32) bool {
    assert(from < word);
    assert(word <= stop);

    const before = emit.back_of(emitter, word) orelse return false;
    if (!simple_range(emitter, from, before)) return false;

    const after = emit.ahead_of(emitter, word) orelse return false;
    return simple_type(emitter, after, stop);
}

fn short_plain(emitter: *const Emitter, from: u32, stop: u32) bool {
    assert(from <= stop);
    assert(stop < emitter.count);

    const token = emitter.tokens[from];
    const slashed = std.mem.startsWith(u8, token.text(emitter.source), "/");
    const regex = from == stop and token.kind == .string and slashed;
    if (regex) return true;

    if (called_open(emitter, from, stop)) |open| {
        const held = emit.ahead_of(emitter, open) orelse return true;
        if (held >= stop) return true;
        if (argument_end(emitter, held, stop) != stop) return false;
    }

    return simple_range(emitter, from, stop);
}

fn argument_last(emitter: *const Emitter, from: u32, to: u32) ?u32 {
    assert(from < emitter.count);
    assert(to <= emitter.count);

    var held = to;

    for (0..comment_trail_max) |_| {
        held = emit.back_of(emitter, held) orelse return null;

        if (held < from) return null;
        if (emitter.tokens[held].kind != .comment) return held;
    }

    return null;
}

fn called_open(emitter: *const Emitter, from: u32, stop: u32) ?u32 {
    assert(from <= stop);
    assert(stop < emitter.count);

    if (!emitter.tokens[stop].is_punctuation(.paren_close)) return null;

    const open = emitter.brackets.open_of(stop) orelse return null;
    if (open <= from) return null;

    const before = emit.back_of(emitter, open) orelse return null;
    if (before < from) return null;
    if (walk.text_is(emitter.tokens[from].text(emitter.source), "new")) return null;
    if (walk.ends_operand(emitter.tokens[before].kind)) return open;
    if (walk.text_is(emitter.tokens[before].text(emitter.source), ">")) return open;
    return null;
}

fn simple_range(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from < emitter.count);
    assert(to < emitter.count);

    if (from > to) return false;

    var scan = from;

    while (scan <= to) : (scan += 1) {
        if (emitter.tokens[scan].kind == .comment) return false;
    }

    var queue: Queue = .{ .pieces = undefined, .queued = 0 };
    if (!simple_queued(&queue, .{ .from = from, .to = to, .depth = 0 })) return false;
    return simple_walked(emitter, &queue);
}

fn simple_queued(queue: *Queue, piece: Piece) bool {
    assert(queue.queued <= simple_work_max);
    assert(piece.depth < 3);

    if (queue.queued == simple_work_max) return false;
    if (piece.from > piece.to) return false;

    queue.pieces[queue.queued] = piece;
    queue.queued += 1;

    return true;
}

fn simple_walked(emitter: *const Emitter, queue: *Queue) bool {
    assert(queue.queued > 0);
    assert(queue.queued <= simple_work_max);

    for (0..simple_step_max) |_| {
        if (queue.queued == 0) return true;

        queue.queued -= 1;

        const piece = queue.pieces[queue.queued];
        if (piece.depth >= 2) return false;
        if (!simple_piece(emitter, queue, piece)) return false;
    }

    return false;
}

fn simple_piece(emitter: *const Emitter, queue: *Queue, piece: Piece) bool {
    assert(piece.from <= piece.to);
    assert(piece.to < emitter.count);

    var start = piece.from;
    var stop = piece.to;

    while (start < stop) : (start += 1) {
        if (!word_listed(&piece_prefixes, emitter.tokens[start].text(emitter.source))) break;
    }

    while (stop > start) : (stop -= 1) {
        if (!word_listed(&piece_suffixes, emitter.tokens[stop].text(emitter.source))) break;
    }

    if (walk.text_is(emitter.tokens[start].text(emitter.source), "new")) start += 1;

    const position = simple_primary(emitter, queue, start, stop, piece.depth) orelse return false;
    return simple_postfix(emitter, queue, position, stop, piece.depth);
}

fn simple_primary(emitter: *const Emitter, queue: *Queue, start: u32, stop: u32, depth: u32) ?u32 {
    assert(start < emitter.count);
    assert(depth < 2);
    assert(stop <= emitter.count);

    const token = emitter.tokens[start];

    switch (token.kind) {
        .identifier, .number => {
            assert(start + 1 <= emitter.count);

            return start + 1;
        },
        .string => return simple_string(emitter, start, stop),
        .keyword => {
            if (!word_listed(&primary_keywords, token.text(emitter.source))) return null;
            assert(start + 1 <= emitter.count);

            return start + 1;
        },
        .block_start => {
            const close = simple_close(emitter, start, stop) orelse return null;
            if (!simple_members(emitter, queue, start, close, depth + 1)) return null;
            assert(close + 1 <= emitter.count);

            return close + 1;
        },
        .punctuation => |punctuation| switch (punctuation) {
            .bracket_open => {
                const close = simple_close(emitter, start, stop) orelse return null;

                _ = simple_items(emitter, queue, start, close, depth + 1) orelse return null;

                assert(close + 1 <= emitter.count);

                return close + 1;
            },
            .paren_open => {
                const close = simple_close(emitter, start, stop) orelse return null;
                if (close == start + 1) return null;

                const inner: Piece = .{ .from = start + 1, .to = close - 1, .depth = depth };
                if (!simple_queued(queue, inner)) return null;
                assert(close + 1 <= emitter.count);

                return close + 1;
            },
            else => return null,
        },
        .block_end, .comment, .newline => return null,
    }
}

fn simple_close(emitter: *const Emitter, start: u32, stop: u32) ?u32 {
    assert(start < emitter.count);
    assert(stop < emitter.count);

    const close = join.closing_of(emitter, start) orelse return null;
    if (close > stop) return null;
    return close;
}

fn simple_string(emitter: *const Emitter, start: u32, stop: u32) ?u32 {
    assert(start < emitter.count);
    assert(emitter.tokens[start].kind == .string);
    assert(stop <= emitter.count);

    if (walk.text_is(emitter.tokens[start].text(emitter.source), "`")) {
        return simple_template(emitter, start, stop);
    }

    if (regex_wide(emitter, start)) return null;
    assert(start + 1 <= emitter.count);

    return start + 1;
}

fn simple_template(emitter: *const Emitter, start: u32, stop: u32) ?u32 {
    assert(start < emitter.count);
    assert(emitter.tokens[start].kind == .string);

    const end = tmpl.template_body(emitter, start) orelse return null;
    if (end > stop) return null;

    var scan = start + 1;

    while (scan < end) : (scan += 1) {
        const held = emitter.tokens[scan];
        const worded = held.kind == .string or held.kind == .block_end or held.kind == .identifier;

        const plain = worded or emit.is_dot(emitter, scan) or
            walk.text_is(held.text(emitter.source), "this");

        if (!plain) return null;
    }

    assert(end + 1 <= emitter.count);

    return end + 1;
}

pub fn unary_at(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!word_listed(&unary_marks, emitter.tokens[position].text(emitter.source))) return false;

    const held = emit.back_of(emitter, position) orelse return true;

    assert(held < position);

    if (!walk.ends_operand(emitter.tokens[held].kind)) return true;
    return edge.statement_ended(emitter, held);
}

fn regex_wide(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.source.len <= std.math.maxInt(u32));

    const token = emitter.tokens[position];
    if (token.kind != .string) return false;

    const text = token.text(emitter.source);
    if (!std.mem.startsWith(u8, text, "/")) return false;

    const end = std.mem.findScalarLast(u8, text, '/') orelse return false;
    const end_offset = token.offset + @as(u32, @intCast(end));

    return walk.columns(emitter.source, token.offset + 1, end_offset) > regex_pattern_max;
}

fn simple_postfix(emitter: *const Emitter, queue: *Queue, from: u32, stop: u32, depth: u32) bool {
    assert(stop < emitter.count);
    assert(depth < 2);
    assert(from < emitter.count);

    var position = from;

    for (0..simple_step_max) |_| {
        if (position > stop) break;

        const text = emitter.tokens[position].text(emitter.source);

        if (emit.is_dot(emitter, position)) {
            position += 2;

            continue;
        }

        if (walk.text_is(text, "!")) {
            position += 1;

            continue;
        }

        if (walk.text_is(text, "<")) {
            const close = join.angle_close(emitter, position) orelse return false;

            assert(close > position);

            position = close + 1;

            continue;
        }

        const close = simple_close(emitter, position, stop) orelse return false;
        if (!simple_suffix(emitter, queue, position, close, depth)) return false;

        position = close + 1;
    }

    return position == stop + 1;
}

fn simple_suffix(
    emitter: *const Emitter,
    queue: *Queue,
    position: u32,
    close: u32,
    depth: u32,
) bool {
    assert(position < close);
    assert(close < emitter.count);
    assert(depth < std.math.maxInt(u32));

    const kind = emitter.tokens[position].kind;

    if (kind.eql(.{ .punctuation = .bracket_open })) {
        if (close == position + 1) return false;
        return simple_queued(queue, .{ .from = position + 1, .to = close - 1, .depth = depth });
    }

    if (!kind.eql(.{ .punctuation = .paren_open })) return false;

    const items = simple_items(emitter, queue, position, close, depth + 1) orelse return false;
    return items + depth <= 2;
}

fn simple_items(emitter: *const Emitter, queue: *Queue, open: u32, close: u32, depth: u32) ?u32 {
    assert(open < close);
    assert(close < emitter.count);
    assert(depth < std.math.maxInt(u32));

    var items: u32 = 0;
    var nesting: u32 = 0;
    var start = open + 1;
    var scan = open + 1;

    while (scan <= close) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const inside = scan < close;
        const opens = inside and walk.is_open(kind);
        const closes = inside and walk.is_close(kind);
        const separates = !inside or (nesting == 0 and kind.eql(.{ .punctuation = .comma }));

        if (opens) {
            nesting += 1;
        } else if (closes) {
            nesting -|= 1;
        } else if (separates) {
            if (scan > start) {
                const spread = walk.text_is(emitter.tokens[start].text(emitter.source), "...");
                if (spread) return null;

                if (!simple_queued(queue, .{ .from = start, .to = scan - 1, .depth = depth })) {
                    return null;
                }

                items += 1;
            }

            start = scan + 1;
        } else {}
    }

    return items;
}

fn simple_members(emitter: *const Emitter, queue: *Queue, open: u32, close: u32, depth: u32) bool {
    assert(open < close);
    assert(close < emitter.count);
    assert(depth < std.math.maxInt(u32));

    var nesting: u32 = 0;
    var start = open + 1;
    var scan = open + 1;

    while (scan <= close) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const inside = scan < close;
        const opens = inside and walk.is_open(kind);
        const closes = inside and walk.is_close(kind);
        const separates = !inside or (nesting == 0 and kind.eql(.{ .punctuation = .comma }));

        if (opens) {
            nesting += 1;
        } else if (closes) {
            nesting -|= 1;
        } else if (separates) {
            if (scan > start) {
                if (!simple_member(emitter, queue, start, scan, depth)) return false;
            }

            start = scan + 1;
        } else {}
    }

    return true;
}

fn simple_member(emitter: *const Emitter, queue: *Queue, start: u32, scan: u32, depth: u32) bool {
    assert(start < scan);
    assert(scan < emitter.count);
    assert(depth < std.math.maxInt(u32));

    const key = emitter.tokens[start].kind;
    const keyed = key == .identifier or key == .keyword or key == .number or key == .string;
    if (!keyed) return false;
    if (scan == start + 1) return true;

    const colon = start + 1;
    if (!emitter.tokens[colon].is_punctuation(.colon)) return false;
    if (colon + 1 > scan - 1) return false;
    return simple_queued(queue, .{ .from = colon + 1, .to = scan - 1, .depth = depth });
}

fn simple_type(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from < emitter.count);
    assert(to < emitter.count);

    var stop = to;
    var arrays: u32 = 0;

    while (arrays < 2) : (arrays += 1) {
        if (stop <= from) break;
        if (!emitter.tokens[stop].is_punctuation(.bracket_close)) break;

        const before = emit.back_of(emitter, stop);
        if (!held_same(emitter.brackets.open_of(stop), before)) break;

        const outer = if (before) |held| emit.back_of(emitter, held) else null;

        stop = outer orelse from;
    }

    var start = from;

    if (arrays > 0) {
        if (walk.text_is(emitter.tokens[stop].text(emitter.source), ">")) {
            if (simple_type_angle(emitter, from, stop)) |open| {
                start = open + 1;
                stop = emit.back_of(emitter, stop) orelse start;
            }
        }
    }

    const head = emitter.tokens[start];

    if (start == stop) {
        if (word_listed(&simple_types, head.text(emitter.source))) return true;
        if (head.kind == .number) return true;
        if (head.kind == .string) return true;
    }

    var scan = start;

    while (scan <= stop) : (scan += 1) {
        if (!simple_typed(emitter, start, scan)) return false;
    }

    return true;
}

fn simple_type_angle(emitter: *const Emitter, from: u32, stop: u32) ?u32 {
    assert(from <= stop);
    assert(stop < emitter.count);

    var scan = from;

    while (scan < stop) : (scan += 1) {
        if (walk.text_is(emitter.tokens[scan].text(emitter.source), "<")) break;
    }

    if (scan >= stop) return null;
    if (join.angle_close(emitter, scan) != stop) return null;
    if (argument_end(emitter, scan + 1, stop) != stop) return null;
    return scan;
}

fn simple_typed(emitter: *const Emitter, start: u32, scan: u32) bool {
    assert(start <= scan);
    assert(scan < emitter.count);

    const kind = emitter.tokens[scan].kind;
    if (kind == .identifier) return true;
    if (kind == .newline) return true;
    if (emit.is_dot(emitter, scan)) return true;
    if (scan <= start) return false;
    return emit.is_dot(emitter, scan - 1);
}

fn held_same(left: ?u32, right: ?u32) bool {
    if (left) |held| assert(held < std.math.maxInt(u32));
    if (right) |held| assert(held < std.math.maxInt(u32));

    if (left) |held| return right == held;
    return right == null;
}

fn body_ended(emitter: *const Emitter, end: u32) bool {
    assert(end <= emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.back_of(emitter, end) orelse return false;
    return emitter.tokens[held].kind == .block_end;
}

fn blocked_first(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from < emitter.count);
    assert(to <= emitter.count);

    var depth: u32 = 0;
    var scan = from;

    while (scan < to) : (scan += 1) {
        const token = emitter.tokens[scan];
        const text = token.text(emitter.source);

        if (depth == 0) {
            if (walk.text_is(text, "function")) return true;
        }

        if (walk.is_open(token.kind)) {
            depth += 1;
        } else if (walk.is_close(token.kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (walk.text_is(text, "=>")) return arrow_braced(emitter, scan, to);
        } else {}
    }

    return false;
}

fn arrow_braced(emitter: *const Emitter, arrow: u32, to: u32) bool {
    assert(arrow < to);
    assert(to <= emitter.count);

    const held = emit.ahead_of(emitter, arrow) orelse return false;
    if (held >= to) return false;
    return emitter.tokens[held].kind == .block_start;
}

fn bodied_tail(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from < emitter.count);
    assert(to <= emitter.count);

    var scan = from;

    while (scan < to) : (scan += 1) {
        if (emitter.tokens[scan].kind == .block_start) return true;
    }

    return false;
}

pub fn arrow_body_joined(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    if (!emitter.policy.chain_simples) return false;
    if (!walk.text_is(emitter.tokens[prior].text(emitter.source), "=>")) return false;

    const close = arrow_body_close(emitter, position) orelse return false;
    const after = emit.ahead_of(emitter, close) orelse return true;
    const kind = emitter.tokens[after].kind;
    if (walk.is_close(kind)) return true;
    if (kind.eql(.{ .punctuation = .comma })) return true;
    return kind.eql(.{ .punctuation = .semicolon });
}

fn arrow_body_close(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.policy.chain_simples);

    const kind = emitter.tokens[position].kind;
    if (kind.eql(.{ .punctuation = .bracket_open })) return join.closing_of(emitter, position);
    if (!kind.eql(.{ .punctuation = .paren_open })) return null;

    const inner = emit.ahead_of(emitter, position) orelse return null;
    if (emitter.tokens[inner].kind != .block_start) return null;

    const close = join.closing_of(emitter, position) orelse return null;
    const end = join.closing_of(emitter, inner) orelse return null;
    const after = emit.ahead_of(emitter, end) orelse return null;
    if (after != close) return null;
    return close;
}

pub fn curried_joined(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    if (!emitter.policy.chain_simples) return false;
    if (!emitter.tokens[position].is_punctuation(.paren_open)) return false;
    if (!emitter.tokens[prior].is_punctuation(.paren_close)) return false;

    const open = emitter.brackets.open_of(prior) orelse return false;
    return !split.headed(emitter, open);
}

pub fn type_reached(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position <= emitter.count);
    assert(emitter.type_ended <= core.type_end_max);

    while (emitter.type_ended > 0) {
        if (emitter.type_ends[emitter.type_ended - 1] >= position) break;

        emitter.type_ended -= 1;

        try emitter.document.push(.reached);
    }
}

pub fn class_newed(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.tokens[close].kind != .block_end) return false;

    var scan = emitter.brackets.open_of(close) orelse return false;

    for (0..callee_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;
        const token = emitter.tokens[held];

        assert(held < scan);

        if (walk.text_is(token.text(emitter.source), "class")) {
            const word = emit.back_of(emitter, held) orelse return false;
            return walk.text_is(emitter.tokens[word].text(emitter.source), "new");
        }

        if (walk.is_close(token.kind)) {
            scan = emitter.brackets.open_of(held) orelse return false;
        } else {
            scan = held;
        }
    }

    return false;
}

pub fn import_typed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.roles.len == emitter.count);

    if (emit.roled(emitter, position, brace.role_type)) return true;
    if (emitter.typed) return true;
    if (tern.typed_frame(emitter)) return true;

    const held = emit.back_of(emitter, position) orelse return false;
    const word = emitter.tokens[held].text(emitter.source);
    if (walk.text_is(word, ":")) return emit.roled(emitter, held, brace.role_type);
    return word_listed(&import_type_marks, word);
}

pub fn arguments_alike(emitter: *const Emitter, before: u32, tail: u32, close: u32) bool {
    assert(before < tail);
    assert(tail < close);

    const before_cast = argument_cast(emitter, before, tail);
    const tail_cast = argument_cast(emitter, tail, close);
    const uncast = before_cast == null and tail_cast == null;

    if (uncast) {
        return emitter.tokens[before].kind.eql(emitter.tokens[tail].kind);
    }

    const held_before = before_cast orelse return false;
    const held_tail = tail_cast orelse return false;

    return walk.text_eql(held_before, held_tail);
}

pub fn argument_cast(emitter: *const Emitter, from: u32, to: u32) ?[]const u8 {
    assert(from < to);
    assert(to <= emitter.count);

    var depth: u32 = 0;
    var scan = from;

    while (scan < to) : (scan += 1) {
        const token = emitter.tokens[scan];
        const text = token.text(emitter.source);
        const opens = walk.is_open(token.kind) or token.kind == .block_start;
        const closes = walk.is_close(token.kind) or token.kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            if (word_listed(&cast_words, text)) return text;
            if (argument_cast_stops(emitter, scan)) return null;
        } else {}
    }

    return null;
}

fn argument_cast_stops(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);

    const text = emitter.tokens[scan].text(emitter.source);
    if (word_listed(&cast_stops, text)) return true;
    if (walk.text_is(text, "?")) return !tern.optional(emitter, scan);
    return false;
}

fn word_listed(words: []const []const u8, word: []const u8) bool {
    assert(words.len > 0);
    assert(word.len <= std.math.maxInt(u32));

    for (words) |listed| {
        if (walk.text_eql(listed, word)) return true;
    }

    return false;
}

pub fn argument_start(emitter: *const Emitter, open: u32, position: u32) u32 {
    assert(open < position);
    assert(position <= emitter.count);

    var depth: u32 = 0;
    var scan = open + 1;
    var start = open + 1;

    while (scan < position) {
        if (spanned_body(emitter, scan)) |end| {
            if (end < position) {
                assert(end >= scan);

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
            if (kind.eql(.{ .punctuation = .comma })) {
                if (emitter.brackets.angles_at(scan) == 0) start = scan + 1;
            }
        } else {}

        scan += 1;
    }

    assert(start <= position);

    const ahead = emit.ahead_of(emitter, start -| 1) orelse start;
    return list.comment_skipped(emitter, ahead);
}

pub fn assign_angle_head(emitter: *const Emitter, open: u32, from: u32, level: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.tokens[open].is_punctuation(.paren_open));
    assert(level < std.math.maxInt(u32));

    var scan = emit.back_of(emitter, open) orelse return null;

    for (0..callee_scan_max) |_| {
        if (emitter.tokens[scan].is_punctuation(.assign)) break;

        const named = emitter.tokens[scan].kind == .identifier or emit.is_dot(emitter, scan);
        if (!named) return null;

        scan = emit.back_of(emitter, scan) orelse return null;
    }

    if (!emitter.tokens[scan].is_punctuation(.assign)) return null;

    const shut = emit.back_of(emitter, scan) orelse return null;
    if (!walk.text_is(emitter.tokens[shut].text(emitter.source), ">")) return null;

    const angle = list.signature_angle_open(emitter, shut) orelse return null;
    if (angle < from) return null;

    const width = level * emitter.options.indent_width + span.printed_columns(emitter, from, open);
    if (width <= emitter.options.line_width) return null;
    return shut;
}

pub fn object_parted(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.ahead_of(emitter, open) orelse return false;
    return body.parts_at(emitter, open, held);
}

fn callee_dotted(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = emit.back_of(emitter, open) orelse return null;

    if (wide.angle_count(emitter, scan, '>') != null) {
        const head = callee_dotted_angles(emitter, scan) orelse return null;

        scan = emit.back_of(emitter, head) orelse return null;
    }

    for (0..callee_scan_max) |_| {
        const token = emitter.tokens[scan];

        const worded = token.kind == .identifier or
            walk.text_is(token.text(emitter.source), "this");

        if (!worded) return null;

        const before = emit.back_of(emitter, scan) orelse return scan;
        const text = emitter.tokens[before].text(emitter.source);
        if (walk.text_is(text, "?.")) return null;
        if (walk.text_is(text, "new")) return null;
        if (!walk.text_is(text, ".")) return scan;

        scan = emit.back_of(emitter, before) orelse return null;
    }

    return null;
}

fn callee_dotted_angles(emitter: *const Emitter, close: u32) ?u32 {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var angles = wide.angle_count(emitter, close, '>') orelse return null;
    var scan = close;

    for (0..callee_scan_max) |_| {
        scan = emit.back_of(emitter, scan) orelse return null;

        if (wide.angle_count(emitter, scan, '>')) |found| {
            angles += found;
        } else if (wide.angle_count(emitter, scan, '<')) |found| {
            angles -|= found;

            if (angles == 0) break;
        } else {}
    }

    if (angles > 0) return null;
    return scan;
}

pub fn bodied_arrow(emitter: *const Emitter, head: u32, end: u32) bool {
    assert(head < emitter.count);
    assert(end <= emitter.count);

    if (template_bodied(emitter, head, end)) return true;

    const token = emitter.tokens[head];
    const braced = token.kind == .block_start or token.is_punctuation(.bracket_open);

    if (braced) {
        const close = join.closing_of(emitter, head) orelse return true;
        const held = line.coding(emitter, close) orelse return true;

        return held >= end;
    }

    if (walk.text_is(token.text(emitter.source), "<")) return !cast_bodied(emitter, head);
    if (token.is_punctuation(.paren_open)) return bodied_arrow_paren(emitter, head, end);
    if (arrow_functioned(emitter, head)) return false;
    if (async_headed(emitter, head)) return true;
    return functioned(emitter, head, emitter.count);
}

fn bodied_arrow_paren(emitter: *const Emitter, head: u32, end: u32) bool {
    assert(head < emitter.count);
    assert(emitter.tokens[head].is_punctuation(.paren_open));

    const close = join.closing_of(emitter, head) orelse return true;
    if (arrowed_ahead(emitter, close)) return true;

    if (emit.ahead_of(emitter, close)) |held| {
        if (held < end) return false;
    }

    const held = emit.ahead_of(emitter, head) orelse return false;
    const kind = emitter.tokens[held].kind;
    const braced = kind == .block_start or kind.eql(.{ .punctuation = .bracket_open });
    if (!braced) return false;

    const found = join.closing_of(emitter, held) orelse return false;
    return emit.ahead_of(emitter, found) == close;
}

fn cast_bodied(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.roles.len == emitter.count);

    if (!walk.text_is(emitter.tokens[open].text(emitter.source), "<")) return false;
    if (emitter.roles[open] & (brace.role_jsx | brace.role_jsx_tag) != 0) return false;

    const close = join.angle_close(emitter, open) orelse return false;
    const after = emit.ahead_of(emitter, close) orelse return false;
    if (emit.roled(emitter, after, brace.role_type)) return false;
    if (!emitter.tokens[after].is_punctuation(.paren_open)) return true;

    const shut = join.closing_of(emitter, after) orelse return true;
    return !arrowed_ahead(emitter, shut);
}

fn async_headed(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!walk.text_is(emitter.tokens[head].text(emitter.source), "async")) return false;

    const held = emit.ahead_of(emitter, head) orelse return false;
    const token = emitter.tokens[held];
    if (token.kind == .identifier) return arrowed_ahead(emitter, held);

    if (token.is_punctuation(.paren_open)) {
        const close = join.closing_of(emitter, held) orelse return false;
        if (arrowed_ahead(emitter, close)) return true;
        return own.arrow_typed_ahead(emitter, close) != null;
    }

    const text = token.text(emitter.source);
    if (walk.text_is(text, "function")) return true;
    return walk.text_is(text, "<");
}

fn template_bodied(emitter: *const Emitter, head: u32, end: u32) bool {
    assert(head < emitter.count);
    assert(end <= emitter.count);

    var tick = head;

    while (tick < end) : (tick += 1) {
        const worded = emitter.tokens[tick].kind == .identifier or emit.is_dot(emitter, tick);
        if (!worded) break;
    }

    const tight = tick == head or emitter.tokens[tick].offset == emitter.tokens[tick - 1].end();
    if (!tight) return false;
    if (!std.mem.startsWith(u8, emitter.tokens[tick].text(emitter.source), "`")) return false;

    const arrow = emit.back_of(emitter, head) orelse return false;
    if (body.parts_at(emitter, arrow, head)) return false;

    const close = tmpl.template_whole(emitter, tick) orelse return false;

    assert(close >= tick);

    if (emit.ahead_of(emitter, close)) |held| {
        if (held < end) return false;
    }

    return tmpl.template_lined(emitter, tick, close);
}

fn arrow_functioned(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const text = emitter.tokens[head].text(emitter.source);
    if (walk.text_is(text, "function")) return true;
    if (!walk.text_is(text, "async")) return false;

    const held = emit.ahead_of(emitter, head) orelse return false;
    return walk.text_is(emitter.tokens[held].text(emitter.source), "function");
}

fn arrowed_ahead(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.ahead_of(emitter, close) orelse return false;
    return walk.text_is(emitter.tokens[held].text(emitter.source), "=>");
}

fn called_args(emitter: *const Emitter, from: u32, to: u32) ?struct { u32, u32 } {
    assert(from < emitter.count);
    assert(to <= emitter.count);

    var head = from;

    while (emitter.tokens[head].kind == .comment) {
        const held = emit.ahead_of(emitter, head) orelse return null;

        assert(held > head);

        if (held >= to) return null;

        head = held;
    }

    if (walk.text_is(emitter.tokens[head].text(emitter.source), "new")) {
        head = emit.ahead_of(emitter, head) orelse return null;
    }

    const last = emit.word_before(emitter, to) orelse return null;
    if (!emitter.tokens[last].is_punctuation(.paren_close)) return null;

    const open = emitter.brackets.open_of(last) orelse return null;

    if (head != from) {
        if (constructor_list(emitter, open)) return null;
    }

    const called = list.calling(emitter, open) or called_bang(emitter, open);

    if (open <= head) return null;
    if (!called) return null;
    if (!called_head(emitter, head, open)) return null;
    if (called_import(emitter, head, open)) return null;
    return .{ open, last };
}

fn called_import(emitter: *const Emitter, head: u32, open: u32) bool {
    assert(head < open);
    assert(open < emitter.count);

    if (!walk.text_is(emitter.tokens[head].text(emitter.source), "import")) return false;
    return emit.ahead_of(emitter, head) == open;
}

fn called_bang(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.word_before(emitter, open) orelse return false;
    if (!walk.text_is(emitter.tokens[held].text(emitter.source), "!")) return false;

    const name = emit.word_before(emitter, held) orelse return false;
    return wide.named(emitter, name);
}

fn constructor_list(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = open;

    for (0..callee_scan_max) |_| {
        const held = emit.word_before(emitter, scan) orelse return false;
        const token = emitter.tokens[held];
        const text = token.text(emitter.source);
        if (walk.text_is(text, "new")) return true;

        if (token.is_punctuation(.paren_close)) {
            const inner = emitter.brackets.open_of(held) orelse return false;
            const word = emit.word_before(emitter, inner) orelse return false;

            return walk.text_is(emitter.tokens[word].text(emitter.source), "new");
        }

        if (angle_closing(text)) {
            scan = list.opening(emitter, held, @intCast(text.len)) orelse return false;

            continue;
        }

        const linked = token.kind == .identifier or word_listed(&member_marks, text);
        if (!linked) return false;

        scan = held;
    }

    return false;
}

fn called_head(emitter: *const Emitter, from: u32, open: u32) bool {
    assert(from < emitter.count);
    assert(open < emitter.count);

    const head = emitter.tokens[from];
    const opened = walk.is_open(head.kind) or head.kind == .string;

    if (!opened) {
        if (head.kind != .identifier) {
            if (!word_listed(&callee_heads, head.text(emitter.source))) return false;
        }
    }

    return called_head_scan(emitter, called_head_start(emitter, from, opened), open);
}

fn called_head_start(emitter: *const Emitter, from: u32, opened: bool) u32 {
    assert(from < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (tmpl.template_body(emitter, from)) |end| {
        assert(end + 1 < std.math.maxInt(u32));

        return end + 1;
    }

    if (emitter.tokens[from].kind == .string) {
        assert(from + 1 <= emitter.count);

        return from + 1;
    }

    if (!opened) {
        assert(from + 1 <= emitter.count);

        return from + 1;
    }

    const close = join.closing_of(emitter, from) orelse from;
    assert(close + 1 <= emitter.count);

    return close + 1;
}

fn called_head_scan(emitter: *const Emitter, from: u32, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);
    assert(from < emitter.count);

    var angles: u32 = 0;
    var depth: u32 = 0;
    var scan = from;

    while (scan < open) {
        if (spanned_body(emitter, scan)) |end| {
            assert(end >= scan);

            scan = end + 1;

            continue;
        }

        const token = emitter.tokens[scan];
        const text = token.text(emitter.source);

        if (walk.is_open(token.kind)) {
            depth += 1;
        } else if (walk.is_close(token.kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (walk.text_is(text, "<")) {
                angles += 1;
            } else if (angle_closing(text)) {
                if (angles < text.len) return false;

                angles -= @intCast(text.len);
            } else if (angles == 0) {
                if (!called_linked(token, text)) return false;
            } else {}
        } else {}

        scan += 1;
    }

    return angles == 0;
}

fn called_linked(token: Token, text: []const u8) bool {
    assert(text.len == token.length);
    if (token.kind == .identifier) assert(text.len > 0);

    if (token.kind == .identifier) return true;
    if (token.kind == .newline) return true;
    if (token.length == 0) return true;
    return word_listed(&callee_links, text);
}

fn angle_closing(text: []const u8) bool {
    if (text.len == 0) return false;

    for (text) |byte| {
        if (byte != '>') return false;
    }

    assert(text[0] == '>');

    return true;
}

pub fn ternary_bodied(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from <= to);
    assert(to <= emitter.count);

    var depth: u32 = 0;
    var scan = from;

    while (scan < to) {
        if (spanned_body(emitter, scan)) |end| {
            assert(end >= scan);

            scan = end + 1;

            continue;
        }

        const token = emitter.tokens[scan];
        const opens = walk.is_open(token.kind) or bind.spans_open(emitter, scan);

        if (opens) {
            depth += 1;
        } else if (walk.is_close(token.kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (walk.text_is(token.text(emitter.source), "?")) {
                if (!tern.optional(emitter, scan)) return true;
            }
        } else {}

        scan += 1;
    }

    return false;
}

pub fn tested_params(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;
    if (!tested_joined(emitter, open)) return false;

    const close = join.closing_of(emitter, open) orelse return false;
    const after = emit.ahead_of(emitter, close) orelse return false;
    if (emitter.tokens[after].kind == .block_start) return true;

    const text = emitter.tokens[after].text(emitter.source);
    if (walk.text_is(text, "=>")) return true;
    return walk.text_is(text, ":");
}

pub fn composed_args(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.compose_parts) return false;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const close = join.closing_of(emitter, open) orelse return false;

    if (!list.calling(emitter, open)) return false;
    if (hooked_args(emitter, open, close)) return false;

    var composed = false;
    var count: u32 = 0;
    var functions: u32 = 0;
    var start = argument_head(emitter, open, close);

    while (start) |from| {
        const to = argument_end(emitter, from, close);

        count += 1;

        if (count > argument_count_max) return false;

        if (functioned(emitter, from, to)) {
            functions += 1;
        } else if (called_args(emitter, from, to)) |pair| {
            composed = composed or composes(emitter, pair[0], pair[1]);
        } else {}

        start = argument_head(emitter, to, close);
    }

    return count > 1 and (functions > 1 or composed);
}

pub fn curried_args(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;
    if (!list.calling(emitter, open)) return false;

    const close = join.closing_of(emitter, open) orelse return false;
    const next = emit.ahead_of(emitter, close) orelse return false;
    if (!emitter.tokens[next].is_punctuation(.paren_open)) return false;

    const end = join.closing_of(emitter, next) orelse return false;

    if (wide.element_count(emitter, open, close) < 2) return false;
    if (span.spread_hugging(emitter, open, close) != null) return false;
    return chain_hardened(emitter, next, end);
}

fn curried_wide(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;
    if (!list.calling(emitter, open)) return false;
    if (callee_dotted(emitter, open) == null) return false;

    const close = join.closing_of(emitter, open) orelse return false;
    const next = emit.ahead_of(emitter, close) orelse return false;
    if (!emitter.tokens[next].is_punctuation(.paren_open)) return false;

    const end = join.closing_of(emitter, next) orelse return false;
    if (emit.ahead_of(emitter, next) == end) return false;

    if (wide.element_count(emitter, open, close) <= wide.element_count(emitter, next, end)) {
        return false;
    }

    if (grouped_last(emitter, open, close)) return false;
    if (hugged_first(emitter, open, close, open + 1)) return false;

    const held = emit.ahead_of(emitter, end) orelse return true;
    if (emit.is_dot(emitter, held)) return false;
    if (emitter.tokens[held].opens_a_group()) return false;
    return !walk.text_is(emitter.tokens[held].text(emitter.source), "!");
}

fn grouped_last(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const range = grouped_last_range(emitter, open, close) orelse return false;
    const from = range[0];
    const to = range[1];
    const kind = emitter.tokens[from].kind;
    const braced = kind == .block_start or kind.eql(.{ .punctuation = .bracket_open });
    if (braced) return !held_same(join.closing_of(emitter, from), emit.ahead_of(emitter, from));
    if (!functioned(emitter, from, to)) return false;
    if (arrow_functioned(emitter, from)) return true;

    const arrow = grouped_last_arrow(emitter, from, to);
    const head = emit.ahead_of(emitter, arrow) orelse return false;
    if (head >= to) return false;
    if (bodied_arrow(emitter, head, to)) return true;
    if (called_args(emitter, head, to) != null) return true;
    return ternary_bodied(emitter, head, to);
}

fn grouped_last_range(emitter: *const Emitter, open: u32, close: u32) ?struct { u32, u32 } {
    assert(open < close);
    assert(close < emitter.count);

    var last: ?struct { u32, u32 } = null;
    var start = emit.ahead_of(emitter, open);

    for (0..argument_count_max) |_| {
        const from = start orelse break;
        if (from >= close) break;

        const to = argument_end(emitter, from, close);

        last = .{ from, to };
        start = emit.ahead_of(emitter, to);
    }

    return last;
}

fn grouped_last_arrow(emitter: *const Emitter, from: u32, to: u32) u32 {
    assert(from <= to);
    assert(to <= emitter.count);

    var depth: u32 = 0;
    var scan = from;

    while (scan < to) : (scan += 1) {
        const token = emitter.tokens[scan];

        if (walk.is_open(token.kind)) {
            depth += 1;
        } else if (walk.is_close(token.kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (walk.text_is(token.text(emitter.source), "=>")) break;
        } else {}
    }

    return scan;
}

pub fn chain_hardened(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from <= to);
    assert(to <= emitter.count);

    var scan = from;

    while (scan < to) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        if (kind == .comment) return true;

        if (kind == .block_start) {
            if (chain_hardened_brace(emitter, scan)) return true;
        }
    }

    return false;
}

fn chain_hardened_brace(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.tokens[open].kind == .block_start);

    const held = emit.ahead_of(emitter, open) orelse return false;
    if (emitter.tokens[held].kind == .block_end) return false;
    if (body.bodied_brace(emitter, open)) return true;
    return object_parted(emitter, open);
}

pub fn arrow_typed_wide(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;
    if (!list.calling(emitter, open)) return false;
    if (!arrow_typed(emitter, open, close)) return false;

    const start, const level = arrow_typed_seat(emitter, open);
    const width = span.printed_columns(emitter, start, close);
    const indent = level * emitter.options.indent_width;
    const overflows = indent + width > emitter.options.line_width;

    if (overflows) {
        if (arrow_body_head(emitter, open)) |head| {
            const nested = (level + 1) * emitter.options.indent_width;
            const columns = span.printed_columns(emitter, head, close);

            return nested + columns > emitter.options.line_width;
        }
    }

    return overflows;
}

pub fn arrow_generics_wide(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const angle = emit.back_of(emitter, open) orelse return false;
    if (!walk.text_is(emitter.tokens[angle].text(emitter.source), ">")) return false;

    const close = join.closing_of(emitter, open) orelse return false;
    if (emit.ahead_of(emitter, open) == close) return false;
    if (!spread_arrowed(emitter, close)) return false;

    const before = list.opening(emitter, angle, 1) orelse return false;
    const generics = emit.ahead_of(emitter, before) orelse return false;

    if (emitter.tokens[before].kind == .identifier) return false;
    if (emit.roled(emitter, generics, brace.role_type)) return false;

    const start, const level = arrow_typed_seat(emitter, open);
    const width = span.printed_columns(emitter, start, open);

    return level * emitter.options.indent_width + width > emitter.options.line_width;
}

fn arrow_typed_seat(emitter: *const Emitter, open: u32) struct { u32, u32 } {
    assert(open < emitter.count);
    assert(emitter.depth > 0);

    if (emitter.depth >= 2) {
        if (lead.spread_item_seat_in(emitter, emitter.depth - 2, open)) |seat| return seat;
    }

    var level = emitter.printed;
    var spread_open: ?u32 = null;

    for (emitter.nest[0 .. emitter.depth - 1]) |frame| {
        if (frame.spread == null) continue;
        if (frame.open < emitter.line_first) continue;

        spread_open = frame.open;

        if (frame.hugged > 0) {
            if (lead.hug_whole(emitter, frame.hugged, frame.close)) continue;
        }

        level += 1;
    }

    const held = spread_open orelse return .{ emitter.line_first, emitter.printed };

    assert(held < open);

    return .{ argument_start(emitter, held, open), level };
}

fn arrow_body_head(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    var held = emitter.wraps_owed;

    while (held > 0) {
        held -= 1;

        const wrapped = emitter.wrapped[held];
        const bodied = wrapped.wrap == .bodied or wrapped.wrap == .hugged;
        if (!bodied) continue;
        if (wrapped.start < emitter.line_first) continue;
        if (wrapped.start >= position) continue;
        if (!walk.text_is(emitter.tokens[wrapped.start].text(emitter.source), "=>")) continue;
        return emit.ahead_of(emitter, wrapped.start);
    }

    return null;
}

fn arrow_typed(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var scan = arrow_typed_last(emitter, open, close);

    while (scan < close) {
        if (spanned_body(emitter, scan)) |end| {
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
            const arrowed = walk.text_is(token.text(emitter.source), "=>") and
                arrow_referenced(emitter, scan);

            if (arrowed) {
                const held = emit.ahead_of(emitter, scan) orelse return false;
                return emitter.tokens[held].kind != .block_start;
            }
        } else {}

        scan += 1;
    }

    return false;
}

fn arrow_typed_last(emitter: *const Emitter, open: u32, close: u32) u32 {
    assert(open < emitter.count);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var last = open + 1;
    var scan = open + 1;

    while (scan < close) {
        if (spanned_body(emitter, scan)) |end| {
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
            const comma = kind.eql(.{ .punctuation = .comma });

            if (comma) {
                if (emit.ahead_of(emitter, scan) != close) last = scan + 1;
            }
        } else {}

        scan += 1;
    }

    assert(last <= emitter.count);

    return last;
}

fn arrow_referenced(emitter: *const Emitter, arrow: u32) bool {
    assert(arrow < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = arrow;

    for (0..arrow_type_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;
        const token = emitter.tokens[held];

        assert(held < scan);

        if (token.is_punctuation(.colon)) return arrow_referenced_colon(emitter, held, arrow);

        const worded = token.kind == .identifier or token.kind == .keyword;

        if (!worded) {
            if (!word_listed(&arrow_type_marks, token.text(emitter.source))) return false;
        }

        scan = held;
    }

    return false;
}

fn arrow_referenced_colon(emitter: *const Emitter, colon: u32, arrow: u32) bool {
    assert(colon < arrow);
    assert(arrow < emitter.count);

    var at = colon;

    while (at < arrow) : (at += 1) {
        const text = emitter.tokens[at].text(emitter.source);
        if (walk.text_is(text, "is")) return false;
        if (walk.text_is(text, "asserts")) return false;
    }

    const found = emit.ahead_of(emitter, colon) orelse return false;
    if (emitter.tokens[found].kind != .identifier) return false;
    return !word_listed(&arrow_type_words, emitter.tokens[found].text(emitter.source));
}

pub fn imported(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const held = emit.back_of(emitter, open) orelse return false;

    assert(held < open);

    if (!walk.text_is(emitter.tokens[held].text(emitter.source), "import")) return false;

    if (emit.back_of(emitter, held)) |before| {
        if (emit.is_dot(emitter, before)) return false;
    }

    if (imported_method(emitter, open)) return false;
    return !import_typed(emitter, held);
}

pub fn required_alias(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const callee = emit.back_of(emitter, open) orelse return false;
    if (!walk.text_is(emitter.tokens[callee].text(emitter.source), "require")) return false;

    const equals = emit.back_of(emitter, callee) orelse return false;
    if (!walk.text_is(emitter.tokens[equals].text(emitter.source), "=")) return false;

    const name = emit.back_of(emitter, equals) orelse return false;
    var head = emit.back_of(emitter, name) orelse return false;

    if (walk.text_is(emitter.tokens[head].text(emitter.source), "type")) {
        head = emit.back_of(emitter, head) orelse return false;
    }

    return walk.text_is(emitter.tokens[head].text(emitter.source), "import");
}

fn imported_method(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.tokens[open].is_punctuation(.paren_open));

    const close = emitter.brackets.close_of(open) orelse return false;
    const after = emit.ahead_of(emitter, close) orelse return false;
    const token = emitter.tokens[after];

    assert(after > close);

    if (token.kind == .block_start) return true;
    if (!token.is_punctuation(.colon)) return false;
    return !tern.ternary(emitter, after);
}

pub fn reach_marks(emitter: *Emitter, open: u32) error{Overflow}!void {
    assert(open < emitter.count);
    assert(emitter.type_ended <= core.type_end_max);

    const reached = curried_wide(emitter, open) or union_typed_params(emitter, open);

    if (reached) {
        try emitter.document.push(.reach);

        return;
    }

    if (list.type_params_reach(emitter, open)) |reach| {
        try type_reaches(emitter, reach[0], reach[1]);

        return;
    }

    if (arrow_params_reach(emitter, open)) try emitter.document.push(.reach_arrow);
}

fn type_reaches(emitter: *Emitter, end: u32, newed: bool) error{Overflow}!void {
    assert(end < emitter.count);
    assert(emitter.type_ended <= core.type_end_max);

    if (emitter.type_ended == core.type_end_max) return;

    emitter.type_ends[emitter.type_ended] = end;
    emitter.type_ended += 1;

    if (newed) {
        try emitter.document.push(.reach_new);

        return;
    }

    try emitter.document.push(.reach_type);
}

fn arrow_params_reach(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const close = join.closing_of(emitter, open) orelse return false;
    if (emit.ahead_of(emitter, open) == close) return false;
    if (params_braced(emitter, open, close)) return false;

    const after = emit.ahead_of(emitter, close) orelse return false;

    if (walk.text_is(emitter.tokens[after].text(emitter.source), "=>")) {
        if (emit.roled(emitter, after, brace.role_type)) return false;
        return arrow_parted(emitter, open, after + 1);
    }

    if (!emitter.tokens[after].is_punctuation(.colon)) return false;
    if (tern.ternary(emitter, after)) return false;

    if (emit.back_of(emitter, open)) |held| {
        if (walk.text_is(emitter.tokens[held].text(emitter.source), "case")) return false;
    }

    return arrow_params_returned(emitter, after);
}

fn arrow_params_returned(emitter: *const Emitter, colon: u32) bool {
    assert(colon < emitter.count);
    assert(emitter.tokens[colon].is_punctuation(.colon));

    const angles = emitter.brackets.angles_at(colon);
    var depth: u32 = 0;
    var scan = colon;

    for (0..return_scan_max) |_| {
        const held = emit.ahead_of(emitter, scan) orelse return false;
        const token = emitter.tokens[held];

        if (walk.is_open(token.kind)) {
            depth += 1;
        } else if (walk.is_close(token.kind)) {
            if (depth == 0) return false;

            depth -= 1;
        } else if (depth == 0) {
            if (emitter.brackets.angles_at(held) <= angles) {
                if (walk.text_is(token.text(emitter.source), "=>")) return true;
                if (token.is_punctuation(.assign)) return false;
                if (token.is_punctuation(.comma)) return false;
                if (token.is_punctuation(.semicolon)) return false;
            }
        } else {}

        scan = held;
    }

    return false;
}

fn params_braced(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (wide.element_count(emitter, open, close) != 1) return false;

    const last = emit.back_of(emitter, close) orelse return false;
    const kind = emitter.tokens[last].kind;
    if (kind == .block_end) return true;
    return kind.eql(.{ .punctuation = .bracket_close });
}

fn union_typed_params(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const close = join.closing_of(emitter, open) orelse return false;
    const arrow = emit.ahead_of(emitter, close) orelse return false;
    if (!walk.text_is(emitter.tokens[arrow].text(emitter.source), "=>")) return false;
    if (params_braced(emitter, open, close)) return false;

    var head = emit.ahead_of(emitter, arrow) orelse return false;

    if (walk.text_is(emitter.tokens[head].text(emitter.source), "|")) {
        head = emit.ahead_of(emitter, head) orelse return false;
    }

    if (!emit.roled(emitter, head, brace.role_type)) return false;
    return unite.union_grouping(emitter, head) != null;
}

pub fn chain_hugged_head(emitter: *const Emitter, curly: u32) ?u32 {
    assert(curly < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (own.cast_hug_head(emitter, curly)) |params| return params;

    const close = emit.back_of(emitter, curly) orelse return null;
    if (!emitter.tokens[close].is_punctuation(.paren_close)) return null;

    const params = emitter.brackets.open_of(close) orelse return null;
    const inner = emit.ahead_of(emitter, params) orelse return null;
    if (inner == close) return null;

    const word = emit.back_of(emitter, params) orelse return null;
    var head = word;

    if (!walk.text_is(emitter.tokens[word].text(emitter.source), "function")) {
        const held = emit.back_of(emitter, word) orelse return null;
        if (!walk.text_is(emitter.tokens[held].text(emitter.source), "function")) return null;

        head = held;
    }

    const open = emit.back_of(emitter, head) orelse return null;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return null;

    const end = join.closing_of(emitter, open) orelse return null;
    if (!hugged_first(emitter, open, end, curly)) return null;
    return params;
}

pub fn logical_operator(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!span.wrapping_operator(emitter, position)) return false;
    return binary_level(emitter.tokens[position].text(emitter.source)) <= logical_level_max;
}

pub fn binary_floor_count(emitter: *const Emitter, head: u32, close: u32, floor: u32) u32 {
    assert(head <= emitter.count);
    assert(close <= emitter.count);
    assert(floor < std.math.maxInt(u32));

    var count: u32 = 0;
    var depth: u32 = 0;
    var scan = head;

    while (scan < close) {
        if (spanned_body(emitter, scan)) |end| {
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
            if (binary_floored(emitter, scan, floor)) count += 1;
        } else {}

        scan += 1;
    }

    assert(count <= close);

    return count;
}

pub fn binary_inline_pair(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head <= emitter.count);
    assert(stop < emitter.count);

    const floor = binary_floor(emitter, head, stop);
    if (floor > logical_level_max) return false;
    if (!span.binary_inlined(emitter, stop)) return false;
    return binary_floor_count(emitter, head, stop, floor) <= 1;
}

pub fn valued_semicolon(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var depth: u32 = 0;
    var scan = head;

    while (scan < emitter.count) {
        if (spanned_body(emitter, scan)) |end| {
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
            const comma = kind.eql(.{ .punctuation = .comma }) and
                (bind.declares_item(emitter, scan) or bind.declares_headed_item(emitter, scan));

            const stops = kind.eql(.{ .punctuation = .semicolon }) or comma;
            if (stops) return scan;
        } else {}

        scan += 1;
    }

    return null;
}

fn arrow_bodied_end(emitter: *const Emitter, position: u32, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(position < emitter.count);

    if (valued_semicolon(emitter, head)) |end| return end;

    assert(emitter.depth > 0);

    const close = emitter.nest[emitter.depth - 1].close;

    if (own.grouping_close(emitter, close)) {
        if (close > head) {
            assert(close <= emitter.count);

            return close;
        }
    }

    if (emitter.arrow_chain.tail == position) {
        if (emitter.arrow_chain.end != std.math.maxInt(u32)) return emitter.arrow_chain.end;
    }

    return null;
}

fn arrow_stated(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const before = emit.back_of(emitter, position) orelse return false;
    const kind = emitter.tokens[before].kind;
    var head: u32 = undefined;

    if (kind.eql(.{ .punctuation = .paren_close })) {
        head = emitter.brackets.open_of(before) orelse return false;
    } else if (kind == .identifier) {
        head = before;
    } else {
        return false;
    }

    if (emit.back_of(emitter, head)) |held| {
        if (walk.text_is(emitter.tokens[held].text(emitter.source), ">")) {
            head = tern.angle_opening(emitter, held) orelse return false;
        }
    }

    if (emit.back_of(emitter, head)) |held| {
        if (walk.text_is(emitter.tokens[held].text(emitter.source), "async")) head = held;
    }

    const bodied = emitter.depth == 0 or emitter.nest[emitter.depth - 1].bodied;
    if (!bodied) return false;

    const seat = emit.back_of(emitter, head) orelse return true;
    const seat_kind = emitter.tokens[seat].kind;
    if (seat_kind == .block_start) return true;
    if (seat_kind == .block_end) return true;
    return seat_kind.eql(.{ .punctuation = .semicolon });
}

fn return_arrowed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!line.word_is(emitter, emitter.line_first, &wrapped_words)) return false;
    if (list.spreads(emitter)) return false;
    if (branched_start(emitter, emitter.line_first, position) != null) return false;

    if (emitter.depth > 0) {
        if (emitter.nest[emitter.depth - 1].open > emitter.line_first) return false;
    }

    return true;
}

fn arrow_unhugged(emitter: *const Emitter, frame: core.Frame, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);
    assert(frame.close == 0 or frame.close > frame.open);

    const paren = frame.kind.eql(.{ .punctuation = .paren_open });

    if (paren) {
        if (tested_joined(emitter, position)) return true;
    }

    const listed = frame.kind.eql(.{ .punctuation = .bracket_open }) and list.spreads(emitter);
    if (listed) return true;
    if (!paren) return false;
    if (frame.spread != null) return false;
    if (list.calling(emitter, frame.open)) return false;
    if (split.headed(emitter, frame.open)) return false;
    return !list.signature_paren(emitter, frame.open);
}

fn arrow_branched(emitter: *const Emitter, position: u32) ?struct { u32, core.Wrap } {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const before = emit.back_of(emitter, position) orelse return null;

    const open = if (emitter.tokens[before].is_punctuation(.paren_close))
        emitter.brackets.open_of(before) orelse return null
    else
        before;

    const seat = arrow_branched_seat(emitter, open) orelse return null;
    if (!branch_opens(emitter, seat)) return null;

    const head = emit.ahead_of(emitter, position) orelse return null;
    const end = arrow_branched_end(emitter, head) orelse return null;
    if (bodied_arrow(emitter, head, end)) return null;

    const last = arrow_last(emitter, end) orelse return null;
    if (last < head) return null;
    return .{ last, .bodied };
}

fn arrow_branched_seat(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.back_of(emitter, open) orelse return null;

    if (walk.text_is(emitter.tokens[held].text(emitter.source), "async")) {
        return emit.back_of(emitter, held) orelse held;
    }

    return held;
}

fn arrow_branched_end(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var depth: u32 = 0;
    var scan = head;

    while (scan < emitter.count) {
        if (spanned_body(emitter, scan)) |stop| {
            assert(stop >= scan);

            scan = stop + 1;

            continue;
        }

        const token = emitter.tokens[scan];

        if (walk.is_open(token.kind)) {
            depth += 1;
        } else if (walk.is_close(token.kind)) {
            if (depth == 0) return scan;

            depth -= 1;
        } else if (depth == 0) {
            if (token.is_punctuation(.comma)) return scan;
            if (token.is_punctuation(.semicolon)) return scan;

            const text = token.text(emitter.source);

            if (walk.text_is(text, "?")) {
                if (!tern.optional(emitter, scan)) return scan;
            }

            if (walk.text_is(text, ":")) {
                if (tern.ternary(emitter, scan)) return scan;
            }
        } else {}

        scan += 1;
    }

    return null;
}

fn arrow_chained_head(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.back_of(emitter, position) orelse return false;

    const open = if (emitter.tokens[held].is_punctuation(.paren_close))
        emitter.brackets.open_of(held) orelse return false
    else
        held;

    const before = emit.back_of(emitter, open) orelse return false;
    return walk.text_is(emitter.tokens[before].text(emitter.source), "=>");
}

fn branched_start(emitter: *const Emitter, start: u32, position: u32) ?u32 {
    assert(start <= position);
    assert(position <= emitter.count);

    var depth: u32 = 0;
    var held: ?u32 = null;
    var scan = start;

    while (scan < position) {
        if (spanned_body(emitter, scan)) |stop| {
            assert(stop >= scan);

            scan = stop + 1;

            continue;
        }

        const token = emitter.tokens[scan];

        if (walk.is_open(token.kind)) {
            depth += 1;
        } else if (walk.is_close(token.kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (branch_opens(emitter, scan)) held = emit.ahead_of(emitter, scan);
        } else {}

        scan += 1;
    }

    const found = held orelse return null;
    if (found >= position) return null;
    return found;
}

fn branched_end(emitter: *const Emitter, position: u32, close: u32) u32 {
    assert(position <= close);
    assert(close <= emitter.count);

    var depth: u32 = 0;
    var scan = position;

    while (scan < close) {
        if (spanned_body(emitter, scan)) |stop| {
            assert(stop >= scan);

            scan = stop + 1;

            continue;
        }

        const token = emitter.tokens[scan];

        if (walk.is_open(token.kind)) {
            depth += 1;
        } else if (walk.is_close(token.kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            const colon = walk.text_is(token.text(emitter.source), ":") and
                tern.ternary(emitter, scan) and scan > position;

            const separates = token.is_punctuation(.comma) or token.is_punctuation(.semicolon);
            const ended = colon or separates;
            if (ended) return scan;
        } else {}

        scan += 1;
    }

    return close;
}

fn branch_opens(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const text = emitter.tokens[position].text(emitter.source);
    if (walk.text_is(text, "?")) return !tern.optional(emitter, position);
    if (walk.text_is(text, ":")) return tern.ternary(emitter, position);
    return false;
}

fn arrow_sequence(emitter: *const Emitter, head: u32, last: u32) bool {
    assert(head < emitter.count);
    assert(last < emitter.count);

    if (!emitter.tokens[head].is_punctuation(.paren_open)) return false;
    if (join.closing_of(emitter, head) != last) return false;

    var depth: u32 = 0;
    var scan = head + 1;

    while (scan < last) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or bind.spans_open(emitter, scan);

        if (opens) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (kind.eql(.{ .punctuation = .comma })) return true;
        } else {}
    }

    return false;
}

fn item_overflows(emitter: *const Emitter, item: u32, end: u32) bool {
    assert(item < emitter.count);
    assert(end <= emitter.count);

    const level = emitter.printed + 1;
    const width = span.printed_columns(emitter, item, end) + 1;

    return level * emitter.options.indent_width + width > emitter.options.line_width;
}

fn defaulted_start(emitter: *const Emitter, start: u32, position: u32) u32 {
    assert(start <= position);
    assert(position <= emitter.count);

    var depth: u32 = 0;
    var scan = start;

    while (scan < position) : (scan += 1) {
        const token = emitter.tokens[scan];

        if (walk.is_open(token.kind)) {
            depth += 1;
        } else if (walk.is_close(token.kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            const assigns = walk.text_is(token.text(emitter.source), "=") and
                emitter.brackets.angles_at(scan) == 0;

            if (assigns) return emit.ahead_of(emitter, scan) orelse start;
        } else {}
    }

    return start;
}

fn valued_start(emitter: *const Emitter, start: u32, position: u32, valued: bool) u32 {
    assert(start <= position);
    assert(position <= emitter.count);

    if (!valued) return start;

    var depth: u32 = 0;
    var scan = start;

    while (scan < position) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (kind.eql(.{ .punctuation = .colon })) {
                return emit.ahead_of(emitter, scan) orelse start;
            }
        } else {}
    }

    return start;
}

pub fn binary_floor(emitter: *const Emitter, head: u32, close: u32) u32 {
    assert(head <= emitter.count);
    assert(close <= emitter.count);

    var depth: u32 = 0;
    var floor = binary_level_max;
    var scan = head;

    while (scan < close) {
        if (spanned_body(emitter, scan)) |end| {
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
            if (wrapping_listed(emitter, scan)) {
                floor = 0;
            } else if (span.wrapping_operator(emitter, scan)) {
                floor = @min(floor, binary_level(emitter.tokens[scan].text(emitter.source)));
            } else {}
        } else {}

        scan += 1;
    }

    assert(floor <= binary_level_max);

    return floor;
}

fn binary_first(emitter: *const Emitter, head: u32, close: u32) ?u32 {
    assert(head <= emitter.count);
    assert(close <= emitter.count);

    const floor = binary_floor(emitter, head, close);
    var depth: u32 = 0;
    var scan = head;

    while (scan < close) {
        if (spanned_body(emitter, scan)) |end| {
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
            if (binary_floored(emitter, scan, floor)) return scan;
        } else {}

        scan += 1;
    }

    return null;
}

pub fn binary_heavy(emitter: *const Emitter, head: u32, close: u32, levels: u32) bool {
    assert(head <= emitter.count);
    assert(close <= emitter.count);
    assert(levels < std.math.maxInt(u32));

    const first = binary_first(emitter, head, close) orelse return false;
    if (binary_parted_head(emitter, head, first)) return false;

    var bracketed = false;
    var scan = head;

    while (scan < first) : (scan += 1) {
        if (walk.is_open(emitter.tokens[scan].kind)) {
            bracketed = true;

            break;
        }
    }

    if (!bracketed) return false;

    const indented = levels * emitter.options.indent_width;
    const width = indented + span.printed_columns(emitter, head, first);

    return width > emitter.options.line_width;
}

fn binary_parted_head(emitter: *const Emitter, head: u32, first: u32) bool {
    assert(head <= first);
    assert(first < emitter.count);

    if (!emitter.tokens[head].is_punctuation(.paren_open)) return false;

    const close = join.closing_of(emitter, head) orelse return false;
    if (close >= first) return false;
    return list.paren_operated(emitter, head, close);
}

pub const binary_level_max: u32 = 12;

const binary_levels: [24]struct { []const u8, u32 } = .{
    .{ "??", 1 },
    .{ "||", 2 },
    .{ "&&", 3 },
    .{ "|", 4 },
    .{ "^", 5 },
    .{ "&", 6 },
    .{ "==", 7 },
    .{ "===", 7 },
    .{ "!=", 7 },
    .{ "!==", 7 },
    .{ "<", 8 },
    .{ ">", 8 },
    .{ "<=", 8 },
    .{ ">=", 8 },
    .{ "in", 8 },
    .{ "instanceof", 8 },
    .{ "<<", 9 },
    .{ ">>", 9 },
    .{ ">>>", 9 },
    .{ "+", 10 },
    .{ "-", 10 },
    .{ "*", 11 },
    .{ "/", 11 },
    .{ "%", 11 },
};

const binary_operator_max: u32 = 64;

pub fn binary_level(text: []const u8) u32 {
    assert(binary_levels.len > 0);
    assert(text.len <= std.math.maxInt(u32));

    for (binary_levels) |entry| {
        const word, const level = entry;

        assert(level < binary_level_max);

        if (walk.text_eql(word, text)) return level;
    }

    return binary_level_max;
}

pub fn binary_fluid(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head <= emitter.count);
    assert(stop < emitter.count);

    const floor = binary_floor(emitter, head, stop);
    if (floor > logical_level_max) return false;
    if (!span.binary_inlined(emitter, stop)) return false;
    return binary_floor_count(emitter, head, stop, floor) > 1;
}

pub fn binary_operand(emitter: *const Emitter, previous: u32) ?struct { u32, u32 } {
    assert(previous < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.wraps_owed == 0) return null;

    const held = emitter.wrapped[wrap.run_top(emitter)];
    const floor = operand_floor(emitter, previous, held.floor, held.start);
    const head, const stop = span.binary_run(emitter, previous) orelse return null;
    var depth: u32 = 0;
    var from = head;
    var scan = head;
    var to = @min(stop, held.close);

    while (scan <= to) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (binary_floored(emitter, scan, floor)) {
                if (scan >= previous) {
                    to = scan -| 1;

                    break;
                }

                from = scan + 1;
            }
        } else {}
    }

    return operand_narrowed(emitter, previous, from, to);
}

fn operand_narrowed(
    emitter: *const Emitter,
    previous: u32,
    head: u32,
    stop: u32,
) ?struct { u32, u32 } {
    assert(previous < emitter.count);
    assert(stop < emitter.count);
    assert(head < emitter.count);

    const owned = binary_level(emitter.tokens[previous].text(emitter.source));
    var from = head;
    var to = stop;

    for (0..operand_narrow_max) |_| {
        if (from >= to) return null;

        var ranks: [binary_operator_max]struct { u32, u32 } = @splat(.{ 0, 0 });
        const count = span.operand_ranked(emitter, from, to, &ranks) orelse break;
        var loosest = owned;

        for (ranks[0..count], 0..) |entry, index| {
            loosest = if (index == 0) entry[1] else @min(loosest, entry[1]);
        }

        if (loosest >= owned) break;

        for (ranks[0..count]) |entry| {
            const at, const rank = entry;

            if (rank != loosest) continue;

            if (at < previous) {
                from = at + 1;
            } else if (at > previous) {
                to = at -| 1;

                break;
            } else {}
        }
    }

    if (from >= to) return null;
    return .{ from, to };
}

fn wrap_framed(emitter: *const Emitter, seated: u32) bool {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(seated <= brace.nest_depth_max);

    var at = seated;

    while (at < emitter.depth) : (at += 1) {
        const frame = emitter.nest[at];
        if (!frame.kind.eql(.{ .punctuation = .paren_open })) return true;
        if (list.calling(emitter, frame.open)) return true;
    }

    return false;
}

pub fn operand_inset(emitter: *const Emitter, previous: u32) u32 {
    assert(previous < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.wraps_owed == 0) return 0;

    const start = emitter.wrapped[wrap.run_top(emitter)].start;
    const unset = std.math.maxInt(u32);
    if (operand_floor(emitter, previous, unset, start) == unset) return 0;

    const from, _ = binary_operand(emitter, previous) orelse return 0;
    const open, _ = operand_paren(emitter, from) orelse return 0;

    return @intFromBool(emit.back_of(emitter, from) != open);
}

fn operand_paren(emitter: *const Emitter, head: u32) ?struct { u32, u32 } {
    assert(head < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.wraps_owed == 0) return null;

    const start = emitter.wrapped[wrap.run_top(emitter)].start;
    const open = bind.enclosing_open(emitter, head) orelse return null;
    if (open <= start) return null;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return null;

    const close = join.closing_of(emitter, open) orelse return null;
    var flanked = false;

    if (emit.back_of(emitter, open)) |held| flanked = span.wrapping_operator(emitter, held);

    if (!flanked) {
        if (emit.ahead_of(emitter, close)) |held| flanked = span.wrapping_operator(emitter, held);
    }

    if (!flanked) return null;
    return .{ open, close };
}

pub fn header_item(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const before = emit.back_of(emitter, head) orelse return false;
    if (!emitter.tokens[before].is_punctuation(.comma)) return false;

    const open = bind.enclosing_open(emitter, head) orelse return false;
    return comment.header_clauses(emitter, open);
}

fn operand_floor(emitter: *const Emitter, previous: u32, wrapped: u32, start: u32) u32 {
    assert(previous < emitter.count);
    assert(emitter.count == emitter.tokens.len);
    if (wrapped != std.math.maxInt(u32)) assert(wrapped <= binary_level_max);

    const open = bind.enclosing_open(emitter, previous) orelse return wrapped;
    if (open <= start) return wrapped;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return wrapped;

    const close = join.closing_of(emitter, open) orelse return wrapped;
    const owned = binary_level(emitter.tokens[previous].text(emitter.source));
    var floor: ?u32 = null;
    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        if (!span.wrapping_operator(emitter, scan)) continue;
        if (bind.enclosing_open(emitter, scan) != open) continue;

        const rank = binary_level(emitter.tokens[scan].text(emitter.source));

        floor = if (floor) |held| @min(held, rank) else rank;
    }

    const held = floor orelse return wrapped;
    if (held >= owned) return wrapped;
    return held;
}

pub fn operand_trail(emitter: *const Emitter, head: u32, stop: u32) u32 {
    assert(head < emitter.count);
    assert(stop < emitter.count);

    if (!binary_operated(emitter, head, stop)) return 0;

    const floor = emitter.wrapped[wrap.run_top(emitter)].floor;
    const after = emit.ahead_of(emitter, stop);

    if (operand_paren(emitter, head)) |paren| {
        _, const close = paren;

        if (after == close) {
            const past = emit.ahead_of(emitter, close) orelse return 1;
            if (!span.wrapping_operator(emitter, past)) return 1;
            assert(1 + emitter.tokens[past].length + 1 < std.math.maxInt(u32));

            return 1 + emitter.tokens[past].length + 1;
        }

        const held = after orelse return 0;
        if (!span.wrapping_operator(emitter, held)) return 0;
        assert(emitter.tokens[held].length + 1 < std.math.maxInt(u32));

        return emitter.tokens[held].length + 1;
    }

    const held = after orelse return 0;
    if (!binary_floored(emitter, held, floor)) return 0;
    assert(emitter.tokens[held].length + 1 < std.math.maxInt(u32));

    return emitter.tokens[held].length + 1;
}

pub fn operand_seat(emitter: *const Emitter, head: u32, stop: u32) ?struct { u32, u32 } {
    assert(head < emitter.count);
    assert(stop < emitter.count);

    if (!binary_operated(emitter, head, stop)) return null;

    const top = wrap.run_top(emitter);
    var found: ?u32 = null;
    var scan = head;

    while (scan < stop) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const coded = kind != .comment and kind != .newline;

        if (coded) {
            found = scan;

            break;
        }
    }

    const coded = found orelse return null;

    if (emitter.wrapped[top].wrap == .paired) return null;

    const start = emitter.wrapped[top].start;
    const indent = emitter.wraps_indent[top];
    var base = indent;

    if (line.at(emitter, start)) |held| {
        if (held.start - 1 == start) {
            if (link.line_led(emitter, start)) |led| base = @max(led, indent);
        }
    }

    const level = base + 1 + @intFromBool(header_item(emitter, coded));

    if (operand_paren(emitter, coded)) |paren| {
        const open, _ = paren;
        if (emit.back_of(emitter, coded) == open) return .{ open, level };
        return .{ coded, level + 1 };
    }

    return .{ coded, level };
}

pub fn binary_operated(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head < emitter.count);
    assert(stop < emitter.count);

    if (emitter.wraps_owed == 0) return false;

    const held = emitter.wrapped[wrap.run_top(emitter)];

    const kinded = switch (held.wrap) {
        .argued, .bodied, .paired, .parens, .valued => true,
        else => false,
    };

    if (!kinded) return false;
    if (held.floor == binary_level_max) return false;
    if (head <= held.start) return false;
    if (stop > held.close) return false;
    if (wrap_framed(emitter, held.depth)) return false;

    var depth: u32 = 0;
    var scan = head;

    while (scan <= stop) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (binary_floored(emitter, scan, held.floor)) return false;
        } else {}
    }

    return true;
}

pub fn arrow_returns(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.ahead_of(emitter, close) orelse return false;
    if (!emitter.tokens[held].is_punctuation(.colon)) return false;
    return !tern.ternary(emitter, held);
}

pub fn chain_composed(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head < emitter.count);
    assert(stop < emitter.count);

    if (!emitter.policy.compose_parts) return false;

    var composed: Composed = .{ .newed = chain_constructed(emitter, head) };
    var scan = head;

    while (scan <= stop) {
        if (spanned_body(emitter, scan)) |end| {
            assert(end >= scan);

            scan = end + 1;

            continue;
        }

        if (walk.is_open(emitter.tokens[scan].kind)) {
            const close = join.closing_of(emitter, scan) orelse stop;

            assert(close >= scan);

            chain_composed_open(emitter, &composed, scan, close);
            scan = close + 1;

            continue;
        }

        scan += 1;
    }

    var breaks = false;

    if (composed.last > 0) {
        breaks = chain_hardened(emitter, head, composed.last);

        if (!breaks) breaks = composed_range(emitter, head, composed.last);
    }

    if (composed.calls > 2) {
        if (composed.found) return true;
    }

    if (breaks) return true;
    return chain_functioned(emitter, head, stop);
}

fn chain_composed_open(emitter: *const Emitter, composed: *Composed, open: u32, close: u32) void {
    assert(open <= close);
    assert(close < emitter.count);

    const paren = emitter.tokens[open].is_punctuation(.paren_open);
    const linked = paren and list.chain_calling(emitter, open);
    var taken = false;

    if (linked) {
        taken = !composed.newed;
        composed.newed = false;
    }

    if (taken) {
        composed.calls += 1 + composed.owed_calls;
        composed.owed_calls = 0;

        if (!composed.found) {
            const owed = composed.owed_found;

            composed.owed_found = false;

            if (owed) {
                composed.found = true;
            } else if (emitter.policy.chain_simples) {
                composed.found = !arguments_simple(emitter, open, close);
            } else {
                composed.found = composes(emitter, open, close);
            }
        }

        composed.last = open;

        return;
    }

    if (!emitter.policy.chain_simples) return;
    if (!paren) return;
    if (linked) return;
    if (!list.calling(emitter, open)) return;

    composed.owed_calls += 1;

    if (!composed.owed_found) composed.owed_found = !arguments_simple(emitter, open, close);
}

fn chain_functioned(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head < emitter.count);
    assert(stop < emitter.count);

    if (!emitter.policy.chain_simples) return false;

    var found = false;
    var last: ?struct { u32, u32 } = null;
    var newed = chain_constructed(emitter, head);
    var scan = head;

    while (scan <= stop) {
        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            const close = join.closing_of(emitter, scan) orelse stop;
            var linked = false;

            if (kind.eql(.{ .punctuation = .paren_open })) {
                if (list.chain_calling(emitter, scan)) {
                    linked = !newed;
                    newed = false;
                }
            }

            if (linked) {
                if (!found) found = chain_argued(emitter, last);

                last = .{ scan, close };
            }

            scan = close + 1;

            continue;
        }

        scan += 1;
    }

    const open, const close = last orelse return false;

    if (!found) return false;
    if (chain_hardened(emitter, open, close)) return true;
    return composed_range(emitter, open, close);
}

fn chain_argued(emitter: *const Emitter, last: ?struct { u32, u32 }) bool {
    assert(emitter.count == emitter.tokens.len);
    if (last) |pair| assert(pair[0] <= pair[1]);

    const open, const close = last orelse return false;

    assert(open <= close);

    return argued_body(emitter, open, close);
}

fn composed_range(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from <= to);
    assert(to < emitter.count);

    var scan = from;

    while (scan < to) : (scan += 1) {
        if (composed_args(emitter, scan)) return true;
    }

    return false;
}

fn chain_constructed(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.back_of(emitter, head) orelse return false;
    return walk.text_is(emitter.tokens[held].text(emitter.source), "new");
}

fn argued_body(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open <= close);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            const text = emitter.tokens[scan].text(emitter.source);
            const bodied = walk.text_is(text, "=>") or walk.text_is(text, "function");
            if (bodied) return true;
        } else {}
    }

    return false;
}

pub fn binary_floored(emitter: *const Emitter, position: u32, floor: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (wrapping_listed(emitter, position)) return floor == 0;
    if (!span.wrapping_operator(emitter, position)) return false;
    return binary_level(emitter.tokens[position].text(emitter.source)) == floor;
}

pub fn operand_looser(emitter: *const Emitter, operator: u32, stop: u32) ?u32 {
    assert(operator < emitter.count);
    assert(stop <= emitter.count);

    const owned = binary_level(emitter.tokens[operator].text(emitter.source));
    var scan = emit.ahead_of(emitter, operator) orelse return null;

    while (scan < stop) {
        if (walk.is_open(emitter.tokens[scan].kind)) {
            const close = join.closing_of(emitter, scan) orelse return null;

            scan = emit.ahead_of(emitter, close) orelse return null;

            continue;
        }

        if (span.wrapping_operator(emitter, scan)) {
            if (binary_level(emitter.tokens[scan].text(emitter.source)) < owned) return scan;
        }

        scan = emit.ahead_of(emitter, scan) orelse return null;
    }

    return null;
}

fn wrapping_listed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.return_parens) return false;
    if (!emitter.tokens[position].is_punctuation(.comma)) return false;
    return emitter.brackets.angles_at(position) == 0;
}

pub fn binary_subrun_step(emitter: *const Emitter, previous: u32, head: u32, stop: u32) u32 {
    assert(previous < emitter.count);
    assert(stop < emitter.count);
    assert(head < emitter.count);

    var ranks: [binary_operator_max]struct { u32, u32 } = @splat(.{ 0, 0 });
    const count = span.binary_ranked(emitter, head, stop, &ranks) orelse return 0;
    var owned: ?u32 = null;

    for (ranks[0..count]) |entry| {
        if (entry[0] == previous) {
            owned = entry[1];

            break;
        }
    }

    const rank = owned orelse return 0;
    var least = rank;
    var headed = true;

    for (ranks[0..count], 0..) |entry, index| {
        least = if (index == 0) entry[1] else @min(least, entry[1]);

        if (entry[0] < previous) {
            if (entry[1] < rank) headed = false;
        }
    }

    const stepped = rank > least and headed;
    return @intFromBool(stepped);
}
