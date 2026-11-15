const std = @import("std");
const assert = std.debug.assert;
const bind = @import("bind.zig");
const body = @import("body.zig");
const brace = @import("../brace.zig");
const core = @import("emitter.zig");
const emit = @import("emit.zig");
const join = @import("join.zig");
const jsx = @import("jsx.zig");
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
const wrap = @import("wrap.zig");
const Emitter = core.Emitter;
const head_words: [8][]const u8 = .{ "!", "-", "+", "~", "await", "typeof", "void", "delete" };

fn word_listed(words: []const []const u8, word: []const u8) bool {
    assert(words.len > 0);
    assert(word.len <= std.math.maxInt(u32));

    for (words) |listed| {
        if (walk.text_eql(listed, word)) return true;
    }

    return false;
}

fn property_returned(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.back_of(emitter, position) orelse return false;
    return emitter.tokens[held].is_punctuation(.paren_close);
}

pub fn propertied(emitter: *const Emitter, position: u32) ?struct { u32, u32, u32 } {
    assert(position < emitter.count);

    if (!emitter.policy.assign_groups) return null;
    if (!list.spreads(emitter)) return null;

    assert(emitter.depth > 0);

    const frame = emitter.nest[emitter.depth - 1];
    if (frame.kind != .block_start) return null;
    if (frame.valued.end != 0) return null;
    if (!emitter.tokens[position].is_punctuation(.colon)) return null;
    if (emitter.typed) return null;
    if (frame.membered) return null;
    if (span.type_framed(emitter, frame.open)) return null;
    if (tern.ternary(emitter, position)) return null;

    if (comment_led(emitter, position)) {
        const end = value_end(emitter, position, frame.close) orelse return null;
        const bound = valued_bound(emitter, position, end);

        return .{ position, value_shut(emitter, bound), end };
    }

    if (bind.slight_key(emitter, position)) {
        if (!bind.paired_binary(emitter, position)) {
            if (!bind.paired_sequence(emitter, position)) return null;
        }
    }

    if (propertied_tagged(emitter, position)) return null;
    if (property_returned(emitter, position)) return null;
    if (emit.property_arrowed(emitter, frame, position)) return null;

    const end = value_end(emitter, position, frame.close) orelse return null;
    const bound = valued_bound(emitter, position, end);

    return propertied_bound(emitter, position, bound, end);
}

fn propertied_tagged(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.policy.assign_groups);

    const start = emit.ahead_of(emitter, position) orelse return false;
    const head = jsx.operand_head(emitter, start);

    return jsx.wrapped(emitter, head) != null;
}

fn propertied_bound(
    emitter: *const Emitter,
    position: u32,
    bound: u32,
    end: u32,
) ?struct { u32, u32, u32 } {
    assert(position < emitter.count);
    assert(emitter.policy.assign_groups);
    assert(bound <= emitter.count);
    assert(end <= emitter.count);

    if (property_flat(emitter, position, bound)) |fluid| {
        if (!fluid) return null;
        return .{ position, position, end };
    }

    if (propertied_dot(emitter, position, bound)) |dot| {
        return chain_property(emitter, position, dot);
    }

    if (link.member_held(emitter, position, bound)) {
        return .{ position, value_shut(emitter, bound), end };
    }

    const close = property_bracket(emitter, position, bound);

    if (own.valued_arrow(emitter, position, bound)) |arrow| return .{ position, arrow, end };
    if (bind.paired_fluid(emitter, position)) return .{ position, position, end };

    if (bind.paired_binary(emitter, position)) {
        return .{ position, value_shut(emitter, bound), end };
    }

    return .{ position, close orelse value_shut(emitter, bound), end };
}

fn propertied_dot(emitter: *const Emitter, position: u32, bound: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.policy.assign_groups);

    const head = emit.ahead_of(emitter, position) orelse return null;
    if (head >= bound) return null;
    if (!chain_whole(emitter, head, bound)) return null;
    return span.chain_valued(emitter, head);
}

const Bracketing = struct {
    casted: ?u32,
    membered: bool,
    newed: bool,
    simple: bool,
    unslight: bool,
};

const BracketStep = union(enum) {
    found: u32,
    missed,
    scan: u32,
};

fn property_bracket(emitter: *const Emitter, position: u32, bound: u32) ?u32 {
    assert(position < emitter.count);
    assert(bound <= emitter.count);

    const head = emit.ahead_of(emitter, position);

    const bracketing: Bracketing = .{
        .casted = bind.value_cast_word(emitter, position, bound),
        .membered = property_bracket_membered(emitter, head, bound),
        .newed = property_bracket_newed(emitter, head),
        .simple = property_bracket_simple(emitter, position, bound),
        .unslight = property_bracket_unslight(emitter, position, bound),
    };

    var scan = position + 1;

    while (scan < bound) {
        assert(scan < emitter.count);

        switch (property_bracket_step(emitter, position, scan, &bracketing)) {
            .found => |held| return held,
            .missed => return null,
            .scan => |held| {
                assert(held > scan);

                scan = held;
            },
        }
    }

    return null;
}

fn property_bracket_membered(emitter: *const Emitter, head: ?u32, bound: u32) bool {
    assert(bound <= emitter.count);
    assert(emitter.policy.assign_groups);
    if (head) |held| assert(held < emitter.count);

    const start = head orelse return false;
    if (start >= bound) return false;
    return link.member_call_chain(emitter, start);
}

fn property_bracket_newed(emitter: *const Emitter, head: ?u32) bool {
    assert(emitter.policy.assign_groups);
    assert(emitter.count == emitter.tokens.len);
    if (head) |held| assert(held < emitter.count);

    const start = head orelse return false;
    return walk.text_is(emitter.tokens[start].text(emitter.source), "new");
}

fn property_bracket_simple(emitter: *const Emitter, position: u32, bound: u32) bool {
    assert(position < emitter.count);
    assert(bound <= emitter.count);

    const head = head_of(emitter, position, bound) orelse return false;
    if (emitter.tokens[head].kind == .identifier) return true;
    return walk.text_is(emitter.tokens[head].text(emitter.source), "this");
}

fn property_bracket_unslight(emitter: *const Emitter, position: u32, bound: u32) bool {
    assert(position < emitter.count);
    assert(bound <= emitter.count);

    const head = head_of(emitter, position, bound) orelse return false;

    const named = emitter.tokens[head].kind == .identifier or
        walk.text_is(emitter.tokens[head].text(emitter.source), "this");

    if (!named) return false;
    if (!chain_whole(emitter, head, bound)) return false;

    const stop = link.chain_stop(emitter, head) orelse return false;
    if (stop >= bound) return false;
    return !span.member_slight(emitter, head, stop);
}

fn property_bracket_step(
    emitter: *const Emitter,
    position: u32,
    scan: u32,
    bracketing: *const Bracketing,
) BracketStep {
    assert(position < scan);
    assert(scan < emitter.count);

    const token = emitter.tokens[scan];
    if (token.kind == .newline) return .{ .scan = scan + 1 };
    if (token.length == 0) return .{ .scan = scan + 1 };
    if (bind.lined_tag(emitter, position, scan)) |tag| return .{ .found = tag };
    if (property_bracket_body(emitter, scan)) |held| return .{ .scan = held + 1 };

    if (bracketing.casted) |word| {
        if (scan < word) {
            if (property_bracket_member(emitter, scan)) {
                const held = emit.back_of(emitter, scan) orelse return .missed;
                return .{ .found = held };
            }
        } else {
            if (bind.cast_stops(emitter, word, scan)) return .{ .found = scan };
            if (!walk.is_open(token.kind)) return .{ .scan = scan + 1 };

            const held = join.closing_of(emitter, scan) orelse return .{ .scan = scan + 1 };
            return .{ .scan = held + 1 };
        }
    }

    if (property_bracket_angled(emitter, scan, bracketing.unslight)) |step| return step;
    if (property_bracket_cast(emitter, scan)) |step| return step;
    if (property_bracket_class(emitter, scan)) return .{ .found = scan };
    if (walk.is_open(token.kind)) return property_bracket_open(emitter, scan, bracketing);
    return .{ .scan = scan + 1 };
}

fn property_bracket_body(emitter: *const Emitter, scan: u32) ?u32 {
    assert(scan < emitter.count);
    assert(emitter.policy.assign_groups);

    if (tmpl.template_body(emitter, scan)) |held| return held;
    if (span.jsx_body(emitter, scan)) |held| return held;
    return own.parenthesized(emitter, scan);
}

fn property_bracket_member(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.policy.assign_groups);

    if (!emit.is_dot(emitter, scan)) return false;
    return link.member_grouped(emitter, scan);
}

fn property_bracket_angled(emitter: *const Emitter, scan: u32, unslight: bool) ?BracketStep {
    assert(scan < emitter.count);
    assert(emitter.policy.assign_groups);

    if (!join.angle_generic(emitter, scan)) return null;

    const ends = join.angle_close(emitter, scan) orelse return null;

    if (emit.ahead_of(emitter, scan)) |head| {
        if (head < ends) {
            if (join.angle_complex(emitter, head, ends)) return .{ .found = scan };

            if (unslight) {
                if (!join.angle_hugged(emitter, head, ends)) return .{ .found = scan };
            }
        }
    }

    return .{ .scan = ends + 1 };
}

fn property_bracket_cast(emitter: *const Emitter, scan: u32) ?BracketStep {
    assert(scan < emitter.count);
    assert(emitter.policy.assign_groups);

    if (!walk.text_is(emitter.tokens[scan].text(emitter.source), "<")) return null;

    const ends = join.angle_close(emitter, scan) orelse return null;
    if (wrap.cast_open(emitter, ends) != scan) return null;
    if (wrap.cast_literal(emitter, scan)) return .{ .found = scan };
    if (wrap.cast_wrapped(emitter, ends) != null) return .{ .found = ends };
    return .{ .scan = ends + 1 };
}

fn property_bracket_class(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.policy.assign_groups);

    if (!line.word_is(emitter, scan, emitter.policy.declaration_words)) return false;

    const held = emit.word_previous(emitter, scan) orelse return false;
    return line.word_is(emitter, held, emitter.policy.construct_words);
}

fn property_bracket_open(
    emitter: *const Emitter,
    scan: u32,
    bracketing: *const Bracketing,
) BracketStep {
    assert(scan < emitter.count);
    assert(walk.is_open(emitter.tokens[scan].kind));

    const held = join.closing_of(emitter, scan) orelse return .missed;

    if (unite.arrow_valued(emitter, scan)) return .{ .found = scan };

    const emptied = property_bracket_emptied(emitter, scan, held);

    const passed = if (bracketing.casted != null)
        emptied or bind.numeric_lookup(emitter, scan, held)
    else
        property_bracket_passed(emitter, scan, held, bracketing, emptied);

    if (!passed) return .{ .found = scan };
    return .{ .scan = held + 1 };
}

fn property_bracket_emptied(emitter: *const Emitter, scan: u32, held: u32) bool {
    assert(scan < held);
    assert(held < emitter.count);

    if (!list.calling(emitter, scan)) return false;
    if (emit.ahead_of(emitter, scan) != held) return false;

    const after = emit.ahead_of(emitter, held) orelse return true;
    return !emit.is_dot(emitter, after);
}

fn property_bracket_passed(
    emitter: *const Emitter,
    scan: u32,
    held: u32,
    bracketing: *const Bracketing,
    emptied: bool,
) bool {
    assert(scan < held);
    assert(bracketing.casted == null);

    const plain = !bracketing.membered and !bracketing.newed and !bracketing.unslight;
    const plain_simple = plain and bracketing.simple;

    if (plain_simple) {
        if (list.slight(emitter, scan, held)) return true;
    }

    if (emptied) return true;
    if (bracketing.unslight) return false;
    return list.bracket_poorly(emitter, scan);
}

pub fn chain_key_parted(emitter: *const Emitter, head: u32, from: u32, level: u32) ?u32 {
    assert(head < emitter.count);
    assert(from <= head);

    if (emitter.depth == 0) return null;
    assert(level < std.math.maxInt(u32));

    const colon = emit.back_of(emitter, head) orelse return null;
    const valued = emitter.nest[emitter.depth - 1].valued;
    if (valued.keyed != colon) return null;
    if (valued.shut <= head) return null;
    if (!bind.paired_binary(emitter, colon)) return null;

    const last = emit.back_of(emitter, valued.shut) orelse return null;

    const width = level * emitter.options.indent_width +
        span.printed_columns(emitter, from, last) + 1;

    if (width > emitter.options.line_width) {
        assert(level + 1 < std.math.maxInt(u32));

        return level + 1;
    }

    return null;
}

fn chain_property(emitter: *const Emitter, position: u32, dot: u32) ?struct { u32, u32, u32 } {
    assert(position < dot);
    assert(dot < emitter.count);

    const word = emit.word_before(emitter, dot) orelse return null;
    const held = split.coded_at(emitter, word) orelse return null;

    assert(held <= word);

    const lookup = if (emitter.brackets.open_of(held)) |open|
        list.bracket_lookup(emitter, open)
    else
        false;

    const called = emitter.tokens[held].is_punctuation(.paren_close) or
        (emitter.tokens[held].is_punctuation(.bracket_close) and lookup);

    const shut = if (called) emitter.brackets.open_of(held) orelse held else held;
    const headed = own.literal_headed(emitter, position, dot) orelse shut;

    return .{ position, headed, dot };
}

fn property_flat(emitter: *const Emitter, position: u32, bound: u32) ?bool {
    assert(position < bound);
    assert(bound <= emitter.count);

    if (bind.lone_value(emitter, position, bound)) {
        if (!key_breaks(emitter, position)) return false;
    }

    if (own.valued_flat(emitter, position, bound)) return true;
    return null;
}

pub fn key_restored(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.tokens[position].is_punctuation(.bracket_close)) return;
    if (emitter.closed.open >= position) return;
    if (emitter.indent <= emitter.closed.inset) return;

    const held = emit.ahead_of(emitter, position) orelse return;

    assert(held > position);

    if (!emitter.tokens[held].is_punctuation(.colon)) return;

    try line.level(emitter, emitter.closed.inset);
}

pub fn key_breaks(emitter: *const Emitter, colon: u32) bool {
    assert(colon < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const close = emit.back_of(emitter, colon) orelse return false;
    if (!emitter.tokens[close].is_punctuation(.bracket_close)) return false;

    const open = emitter.brackets.open_of(close) orelse return false;
    var depth: u32 = 0;
    var dotted: ?u32 = null;
    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;

        if (brace.is_open(kind)) {
            depth += 1;
        } else if (brace.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (emit.is_dot(emitter, scan)) dotted = scan;
        } else {}
    }

    const dot = dotted orelse return false;
    const first = emit.ahead_of(emitter, open) orelse return true;
    if (emit.ahead_of(emitter, first) != dot) return true;
    return emitter.tokens[first].kind != .identifier;
}

fn comment_led(emitter: *const Emitter, colon: u32) bool {
    assert(colon < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const comment = emit.ahead_of(emitter, colon) orelse return false;
    if (emitter.tokens[comment].kind != .comment) return false;
    if (!body.parts_at(emitter, colon, comment)) return false;

    const held = emit.ahead_of(emitter, comment) orelse return false;
    return body.parts_at(emitter, comment, held);
}

fn chain_whole(emitter: *const Emitter, head: u32, bound: u32) bool {
    assert(head < bound);
    assert(bound <= emitter.count);

    const stop = link.chain_stop(emitter, head) orelse return true;
    const next = emit.ahead_of(emitter, stop) orelse return true;
    if (next >= bound) return true;

    const kind = emitter.tokens[next].kind;
    if (kind == .comment) return true;
    if (kind.eql(.{ .punctuation = .comma })) return true;
    return kind.eql(.{ .punctuation = .semicolon });
}

fn value_shut(emitter: *const Emitter, bound: u32) u32 {
    assert(bound < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const last = emit.word_before(emitter, bound) orelse return bound;

    const standing = emitter.tokens[bound].kind == .comment and
        std.mem.startsWith(u8, emitter.tokens[bound].text(emitter.source), "//") and
        body.parts_at(emitter, last, bound);

    if (standing) return last;
    return bound;
}

pub fn head_of(emitter: *const Emitter, position: u32, bound: u32) ?u32 {
    assert(position < bound);
    assert(bound <= emitter.count);

    var head = emit.ahead_of(emitter, position) orelse return null;

    while (head < bound) {
        if (!word_listed(&head_words, emitter.tokens[head].text(emitter.source))) break;

        head = emit.ahead_of(emitter, head) orelse return null;
    }

    if (head >= bound) return null;
    return head;
}

pub fn valued_bound(emitter: *const Emitter, position: u32, end: u32) u32 {
    assert(position < end);
    assert(end <= emitter.count);

    var bound = end;

    while (bound > position + 1) {
        const above = emit.word_before(emitter, bound) orelse break;
        if (emitter.tokens[above].kind != .comment) break;

        bound = above;
    }

    return bound;
}

fn value_end(emitter: *const Emitter, position: u32, close: u32) ?u32 {
    assert(position < close);
    assert(close <= emitter.count);

    const end = ended(emitter, position, close) orelse return null;
    if (end != close) return end;
    return value_end_commented(emitter, position, close);
}

fn value_end_commented(emitter: *const Emitter, position: u32, close: u32) u32 {
    assert(position < close);
    assert(close <= emitter.count);

    if (close == emitter.count) return close;

    var last = emit.back_of(emitter, close) orelse return close;

    for (0..close) |_| {
        if (emitter.tokens[last].kind != .comment) break;

        last = emit.back_of(emitter, last) orelse return close;
    }

    const first = emit.ahead_of(emitter, last) orelse return close;

    if (last <= position) return close;
    if (first == close) return close;
    if (!body.parts_at(emitter, last, first)) return close;

    assert(emitter.tokens[first].kind == .comment);
    assert(first < close);

    return first;
}

pub fn ended(emitter: *const Emitter, position: u32, close: u32) ?u32 {
    assert(position < close);
    assert(close <= emitter.count);

    var depth: u32 = 0;
    var scan = position + 1;

    while (scan < close) : (scan += 1) {
        const token = emitter.tokens[scan];
        const kind = token.kind;
        const opens = brace.is_open(kind) or brace.substituting(emitter.source, token);

        if (opens) {
            depth += 1;
        } else if (brace.is_close(kind)) {
            if (depth == 0) return null;

            depth -= 1;
        } else if (depth == 0) {
            const separated = kind.eql(.{ .punctuation = .comma }) or
                kind.eql(.{ .punctuation = .semicolon });

            if (separated) {
                if (emitter.brackets.angles_at(scan) <= emitter.brackets.angles_at(position)) {
                    const after = emit.ahead_of(emitter, scan);
                    return if (after == close) close else scan;
                }
            }
        } else {}
    }

    if (scan == close) return close;
    return null;
}
