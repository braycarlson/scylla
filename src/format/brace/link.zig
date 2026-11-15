const std = @import("std");
const assert = std.debug.assert;
const Token = @import("../../syntax/token.zig");
const bind = @import("bind.zig");
const body = @import("body.zig");
const brace = @import("../brace.zig");
const call = @import("call.zig");
const core = @import("emitter.zig");
const edge = @import("edge.zig");
const emit = @import("emit.zig");
const join = @import("join.zig");
const jsx = @import("jsx.zig");
const lead = @import("lead.zig");
const line = @import("line.zig");
const list = @import("list.zig");
const own = @import("own.zig");
const scanning = @import("../../text/scan.zig");
const span = @import("span.zig");
const split = @import("split.zig");
const tern = @import("tern.zig");
const tmpl = @import("tmpl.zig");
const walk = @import("../walk.zig");
const wide = @import("wide.zig");
const Emitter = core.Emitter;
const argument_head_max: u32 = 8;
const argument_scan_max: u32 = 64;
const await_operands: []const []const u8 = &.{ "!", "this", "super", "new" };
const await_operators: []const []const u8 = &.{ "...", "typeof", "void", "delete" };
const await_scan_max: u32 = 4096;
const await_tails: []const []const u8 = &.{ "!", "as", "satisfies", "instanceof", "in" };
const cast_words: []const []const u8 = &.{ "as", "satisfies" };
const chain_link_max: u32 = 32;
const chain_scan_max: u32 = 512;
const left_scan_max: u32 = 64;
const member_lookup_max: u32 = 8;
const member_trail_max: u32 = 16;
const prefix_head_max: u32 = 8;
const for_words: []const []const u8 = &.{ "for", "await" };
const header_unary_words: []const []const u8 = &.{ "!", "-", "+", "~" };
const iterating_words: []const []const u8 = &.{ "of", "in" };

const chain_stops: []const []const u8 = &.{
    "await",
    "case",
    "delete",
    "in",
    "instanceof",
    "new",
    "return",
    "throw",
    "typeof",
    "void",
};

const prefix_led_words: []const []const u8 = &.{
    "!",
    "+",
    "-",
    "~",
    "await",
    "delete",
    "typeof",
    "void",
};

const typed_words: []const []const u8 = &.{
    "as",
    "extends",
    "implements",
    "infer",
    "is",
    "keyof",
    "satisfies",
};

const MemberTrailStep = union(enum) {
    closed,
    dotted,
    looked_up: u32,
    passed,
    stopped,
};

fn member_trail(emitter: *const Emitter, head: u32, stop: u32) ?u32 {
    assert(head <= stop);
    assert(stop < emitter.count);

    var first: ?u32 = null;
    var scan = stop;

    for (0..member_trail_max) |_| {
        if (scan <= head) return member_trail_ended(emitter, first, head, stop);

        switch (member_trail_step(emitter, scan)) {
            .closed => return member_trail_closed(emitter, first, scan, head),
            .dotted => first = scan,
            .looked_up => |open| {
                scan = open;

                if (emit.back_of(emitter, open)) |held| {
                    const held_text = emitter.tokens[held].text(emitter.source);

                    if (walk.text_is(held_text, "?.")) scan = held;
                }
            },
            .passed => {},
            .stopped => return null,
        }

        scan = emit.back_of(emitter, scan) orelse return null;
    }

    return null;
}

fn member_trail_step(emitter: *const Emitter, scan: u32) MemberTrailStep {
    assert(scan < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const token = emitter.tokens[scan];

    if (emit.is_dot(emitter, scan)) return .dotted;
    if (token.is_punctuation(.paren_close)) return .closed;
    if (member_trail_lookup(emitter, scan, token)) |open| return .{ .looked_up = open };

    const stopped = !chain_start_worded(token.kind) and
        !walk.text_is(token.text(emitter.source), "!");

    if (stopped) return .stopped;
    return .passed;
}

fn member_trail_lookup(emitter: *const Emitter, scan: u32, token: Token) ?u32 {
    assert(scan < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!token.is_punctuation(.bracket_close)) return null;
    return member_lookup(emitter, scan);
}

fn member_trail_ended(emitter: *const Emitter, first: ?u32, head: u32, stop: u32) ?u32 {
    assert(head <= stop);
    assert(stop < emitter.count);
    if (first) |held| assert(held < emitter.count);

    const dot = first orelse return null;
    const bare = member_bare(emitter, dot, stop) and emit.back_of(emitter, dot) == head;

    const named = emitter.tokens[head].kind == .identifier or
        walk.text_is(emitter.tokens[head].text(emitter.source), "this");

    if (bare) {
        if (named) return null;
    }

    if (!member_alone(emitter, head, stop)) return null;
    return dot;
}

fn member_trail_closed(emitter: *const Emitter, first: ?u32, scan: u32, head: u32) ?u32 {
    assert(scan < emitter.count);
    assert(head <= scan);
    if (first) |held| assert(held < emitter.count);

    const open = emitter.brackets.open_of(scan) orelse return null;
    const dot = first orelse return null;
    const uncalled = !list.calling(emitter, open);

    if (uncalled) {
        if (open != head) return null;
    }

    return dot;
}

fn member_bare(emitter: *const Emitter, dot: u32, stop: u32) bool {
    assert(dot <= stop);
    assert(stop < emitter.count);

    const name = emit.ahead_of(emitter, dot) orelse return false;
    if (name == stop) return true;

    const bang = emit.ahead_of(emitter, name) orelse return false;
    if (!walk.text_is(emitter.tokens[bang].text(emitter.source), "!")) return false;

    var at = name;

    while (at <= stop) : (at += 1) {
        if (emit.is_dot(emitter, at)) return false;
    }

    return true;
}

fn member_lookup(emitter: *const Emitter, close: u32) ?u32 {
    assert(close < emitter.count);

    const open = emitter.brackets.open_of(close) orelse return null;
    const before = emit.back_of(emitter, open) orelse return null;
    const token = emitter.tokens[before];

    assert(open < close);

    if (emit.is_dot(emitter, before)) return before;
    if (token.ends_a_value()) return open;
    if (walk.text_is(token.text(emitter.source), "!")) return open;
    return null;
}

pub fn member_trimmed(emitter: *const Emitter, casted: ?u32, stop: u32) u32 {
    assert(stop < emitter.count);
    assert(emitter.count <= emitter.tokens.len);
    if (casted) |held| assert(held < emitter.count);

    if (casted != null) return lookup_trimmed(emitter, stop);
    return stop;
}

fn lookup_trimmed(emitter: *const Emitter, stop: u32) u32 {
    assert(stop < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    var held = stop;

    for (0..member_lookup_max) |_| {
        if (!emitter.tokens[held].is_punctuation(.bracket_close)) break;

        const open = emitter.brackets.open_of(held) orelse break;
        if (!lookup_trimmed_numbered(emitter, open, held)) break;

        const before = emit.back_of(emitter, open) orelse break;
        if (!emitter.tokens[before].ends_a_value()) break;

        held = before;
    }

    return held;
}

fn lookup_trimmed_numbered(emitter: *const Emitter, open: u32, held: u32) bool {
    assert(open < held);
    assert(held < emitter.count);

    const inner = emit.ahead_of(emitter, open) orelse return false;
    if (emitter.tokens[inner].kind != .number) return false;
    return emit.ahead_of(emitter, inner) == held;
}

pub fn member_lefted(emitter: *const Emitter, equals: ?u32, stop: u32, dot: u32) bool {
    assert(dot <= stop);
    assert(stop < emitter.count);
    if (equals) |held| assert(held < emitter.count);

    if (emit.ahead_of(emitter, stop)) |held| {
        const assigned = emitter.tokens[held].is_punctuation(.assign) or
            own.compound_assign(emitter, held);

        if (assigned) return !member_lefted_bang(emitter, dot, stop);
    }

    const assign = equals orelse return false;
    if (declarator_left(emitter, assign)) return false;

    const left = emit.back_of(emitter, assign) orelse return true;
    if (emitter.tokens[left].kind != .identifier) return true;

    const held = emit.back_of(emitter, left) orelse return false;
    const kind = emitter.tokens[held].kind;

    if (emit.is_dot(emitter, held)) return true;
    if (!walk.is_close(kind)) return false;
    if (edge.header_closed(emitter, held, left)) return false;
    return kind != .block_end;
}

fn member_lefted_bang(emitter: *const Emitter, dot: u32, stop: u32) bool {
    assert(dot < stop);
    assert(stop < emitter.count);

    var at = dot + 1;

    while (at <= stop) : (at += 1) {
        if (!walk.text_is(emitter.tokens[at].text(emitter.source), "!")) continue;

        const held = emit.back_of(emitter, at) orelse continue;
        if (emitter.tokens[held].kind == .identifier) return true;
    }

    return false;
}

fn declarator_left(emitter: *const Emitter, assign: u32) bool {
    assert(assign < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    var depth: u32 = 0;
    var scan = assign;

    for (0..left_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;
        const token = emitter.tokens[held];

        if (walk.is_close(token.kind)) {
            depth += 1;
        } else if (walk.is_open(token.kind)) {
            if (depth == 0) return false;

            depth -= 1;
        } else if (depth == 0) {
            if (declarator_word(token.text(emitter.source))) return true;
            if (token.is_punctuation(.comma)) return bind.declares_valued(emitter, assign);
            if (token.is_punctuation(.semicolon)) return false;
            if (token.is_punctuation(.assign)) return false;
        } else {}

        scan = held;
    }

    return false;
}

fn declarator_word(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    if (walk.text_is(text, "const")) return true;
    if (walk.text_is(text, "let")) return true;
    return walk.text_is(text, "var");
}

pub fn member_opens(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.wraps_owed == core.wrap_depth_max) return;
    if (!emit.is_dot(emitter, position)) return;
    if (!emitter.policy.chain_simples) return;
    if (!member_grouped(emitter, position)) return;

    const close = emit.ahead_of(emitter, position) orelse return;

    if (member_chain_led(emitter, position)) {
        try emitter.document.push(.dedent);

        emitter.indent -= 1;
    }

    emitter.wrapped[emitter.wraps_owed] = .{
        .close = close,
        .wrap = .membered,
        .depth = emitter.depth,
        .floor = 0,
        .start = position,
    };

    emitter.wraps_armed[emitter.wraps_owed] = true;
    emitter.wraps_nested[emitter.wraps_owed] = core.nest_none;
    emitter.wraps_indent[emitter.wraps_owed] = emitter.indent;
    emitter.wraps_owed += 1;

    try emitter.document.push(.group_open);
    try line.opens_broken(emitter);
    try emitter.document.push(.soft_line);
}

pub fn linked(emitter: *const Emitter) u32 {
    assert(emitter.line_before < emitter.count);
    assert(emitter.line_first < emitter.count);

    const held = emitter.tokens[emitter.line_before].kind;

    if (link_level(emitter)) |level| return level;
    if (dotted(emitter)) |level| return level;
    if (link_angled(emitter)) |level| return level;

    if (walk.is_close(held)) {
        if (line_closed(emitter)) {
            const tupled: u32 = @intFromBool(tuple_rooted(emitter));

            if (emitter.closed.close == emitter.line_before) {
                assert(emitter.closed.inset + tupled < std.math.maxInt(u32));

                return emitter.closed.inset + tupled;
            }

            assert(emitter.printed + tupled < std.math.maxInt(u32));

            return emitter.printed + tupled;
        }
    }

    if (angle_called(emitter)) return emitter.printed;
    if (held == .comment) return emitter.printed;
    if (emit.is_dot(emitter, emitter.line_before)) return emitter.printed;

    if (emitter.policy.link_spans) {
        if (line_spans(emitter)) return emitter.printed;
    }

    assert(emitter.printed + 1 < std.math.maxInt(u32));

    return emitter.printed + 1;
}

fn tuple_rooted(emitter: *const Emitter) bool {
    assert(emitter.line_first < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    var close = emit.back_of(emitter, emitter.line_first) orelse return false;

    for (0..core.define_scan_max) |_| {
        const commented = emitter.tokens[close].kind == .comment;

        if (!commented) {
            if (!walk.text_is(emitter.tokens[close].text(emitter.source), "?")) break;
        }

        close = emit.back_of(emitter, close) orelse return false;
    }

    if (!emitter.tokens[close].is_punctuation(.paren_close)) return false;

    const open = emitter.brackets.open_of(close) orelse return false;
    if (!wide.tuple_open(emitter, open)) return false;
    return wide.tuple_commas(emitter, open, close) > 0;
}

fn angle_called(emitter: *const Emitter) bool {
    assert(emitter.line_before <= emitter.line_first);
    assert(emitter.line_first < emitter.count);

    const before = emitter.line_before;
    if (!walk.text_is(emitter.tokens[before].text(emitter.source), ">")) return false;
    if (join.angle_head(emitter, before) == null) return false;

    var scan = emit.back_of(emitter, emitter.line_first) orelse return false;

    for (0..core.define_scan_max) |_| {
        if (scan <= before) return false;
        if (!walk.text_is(emitter.tokens[scan].text(emitter.source), "?")) break;

        scan = emit.back_of(emitter, scan) orelse return false;
    }

    if (!emitter.tokens[scan].is_punctuation(.paren_close)) return false;

    const open = emitter.brackets.open_of(scan) orelse return false;
    return open > before;
}

fn line_closed(emitter: *const Emitter) bool {
    assert(emitter.line_first < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = emitter.line_before;

    while (scan < emitter.line_first) : (scan += 1) {
        const token = emitter.tokens[scan];
        if (token.length == 0) continue;
        if (token.kind == .newline) continue;
        if (token.kind == .comment) continue;

        for (token.text(emitter.source)) |byte| {
            if (std.mem.findScalar(u8, core.line_closers, byte) == null) return false;
        }
    }

    return true;
}

fn line_spans(emitter: *const Emitter) bool {
    assert(emitter.line_first < emitter.count);
    assert(emitter.options.indent_width > 0);

    const found = line_spanned(emitter) orelse return false;

    assert(found < emitter.line_first);

    if (emitter.tokens[found].kind != .string) return true;
    return line_last(emitter, found) <= emitter.options.indent_width;
}

fn line_spanned(emitter: *const Emitter) ?u32 {
    assert(emitter.line_first < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var found: ?u32 = null;
    var scan = emitter.line_before;

    while (scan < emitter.line_first) : (scan += 1) {
        const text = emitter.tokens[scan].text(emitter.source);

        if (std.mem.findScalar(u8, text, '\n') != null) found = scan;
        if (opaque_spanned(emitter, scan)) found = scan;
    }

    return found;
}

fn opaque_spanned(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (!wide.opaqued(emitter, position)) return false;

    const close = join.closing_of(emitter, position) orelse return false;
    const from = emitter.tokens[position].offset;
    const to = emitter.tokens[close].end();

    return std.mem.findScalar(u8, emitter.source[from..to], '\n') != null;
}

fn line_last(emitter: *const Emitter, position: u32) u32 {
    assert(position < emitter.count);
    assert(emitter.source.len <= std.math.maxInt(u32));

    const token = emitter.tokens[position];
    const end = token.end();
    var from = token.offset;
    var scan = token.offset;

    while (scan < end) : (scan += 1) {
        if (emitter.source[scan] == '\n') from = scan + 1;
    }

    var to = end;

    while (from < to) : (from += 1) {
        if (!scanning.is_ascii_whitespace(emitter.source[from])) break;
    }

    while (to > from) : (to -= 1) {
        if (!scanning.is_ascii_whitespace(emitter.source[to - 1])) break;
    }

    assert(from <= to);

    return walk.columns(emitter.source, from, to);
}

fn line_brackets(emitter: *const Emitter) struct { u32, u32 } {
    assert(emitter.line_first < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var closes: u32 = 0;
    var opens: u32 = 0;
    var scan = emitter.line_before;

    while (scan < emitter.line_first) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            opens += 1;
        } else if (walk.is_close(kind)) {
            closes += 1;
        } else {}
    }

    return .{ opens, closes };
}

fn link_angled(emitter: *const Emitter) ?u32 {
    assert(emitter.line_before < emitter.count);
    assert(emitter.line_first < emitter.count);

    if (!emitter.policy.link_nests) return null;
    if (!walk.text_is(emitter.tokens[emitter.line_before].text(emitter.source), ">")) return null;

    const opens, const closes = line_brackets(emitter);
    if (closes <= opens) return null;
    if (emitter.closed.open >= emitter.line_before) return null;
    return line.level_at(emitter, emitter.closed.open);
}

fn link_level(emitter: *const Emitter) ?u32 {
    assert(emitter.line_before < emitter.count);
    assert(emitter.line_first < emitter.count);

    if (!emitter.policy.link_nests) return null;
    if (!emit.is_dot(emitter, emitter.line_before)) return null;

    const opens, const closes = line_brackets(emitter);

    if (opens > closes) {
        assert(emitter.printed + 1 < std.math.maxInt(u32));

        return emitter.printed + 1;
    }

    if (closes > opens) return line.level_at(emitter, emitter.closed.open);
    return null;
}

pub fn comment_linked(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (emitter.tokens[position].kind != .comment) return false;
    if (!body.parts_at(emitter, previous, position)) return false;

    const held = line.coding(emitter, position) orelse return false;
    if (!emit.is_dot(emitter, held)) return false;
    if (span.chain_broken(emitter, held)) return true;
    if (span.member_parted(emitter, held)) return true;
    if (!list.spreads(emitter)) return false;
    return span.chain_parts(emitter, held, position);
}

fn prefix_led(emitter: *const Emitter, first: u32, head: u32) bool {
    assert(first <= head);
    assert(head < emitter.count);

    if (head - first > prefix_head_max) return false;

    var held = first;

    while (held < head) : (held += 1) {
        if (!worded(prefix_led_words, emitter.tokens[held].text(emitter.source))) return false;
    }

    return true;
}

pub fn dotted(emitter: *const Emitter) ?u32 {
    assert(emitter.line_first < emitter.count);
    assert(emitter.lined < core.line_level_max);

    if (!emitter.policy.chain_groups) return null;
    if (!link_led(emitter, emitter.line_first)) return null;

    const head = wide.chain_head(emitter, emitter.line_first);
    var index = emitter.lined;

    for (0..core.line_level_max) |_| {
        index = if (index == 0) core.line_level_max - 1 else index - 1;

        const held = emitter.lines[index];
        if (held.start == 0) return null;

        const first = held.start - 1;
        if (first >= emitter.line_first) continue;
        if (first < head) return dotted_short(emitter, first, head, held.level);

        if (link_led(emitter, first)) {
            if (wide.chain_head(emitter, first) == head) return @min(held.level, emitter.printed);
        }

        if (first == head) {
            const returned = if (head == emitter.line_before) held.level + 1 else null;

            if (returned) |mark| assert(mark < std.math.maxInt(u32));

            return returned;
        }
    }

    return null;
}

pub fn sibling(emitter: *const Emitter) ?u32 {
    assert(emitter.line_first < emitter.count);
    assert(emitter.lined < core.line_level_max);

    if (!emitter.policy.header_levels) return null;
    if (!link_led(emitter, emitter.line_first)) return null;

    const head = wide.chain_head(emitter, emitter.line_first);
    var index = emitter.lined;

    for (0..core.line_level_max) |_| {
        index = if (index == 0) core.line_level_max - 1 else index - 1;

        const held = emitter.lines[index];
        if (held.start == 0) return null;

        const first = held.start - 1;
        if (first >= emitter.line_first) continue;
        if (first < head) return null;
        if (!link_led(emitter, first)) continue;
        if (wide.chain_head(emitter, first) == head) return held.level;
    }

    return null;
}

fn link_led(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (emit.is_dot(emitter, position)) return true;
    if (!emitter.policy.chain_simples) return false;
    return lookup_link(emitter, position);
}

fn dotted_short(emitter: *const Emitter, first: u32, head: u32, level: u32) ?u32 {
    assert(first < head);
    assert(head < emitter.count);
    assert(level < std.math.maxInt(u32));

    if (prefix_led(emitter, first, head)) {
        if (first == emitter.line_before) {
            assert(level + 1 < std.math.maxInt(u32));

            return level + 1;
        }

        return null;
    }

    const headed = dotted_headed(emitter, first, head);

    if (!headed) {
        if (span.element_level(emitter, head)) |found| {
            assert(found + 1 < std.math.maxInt(u32));

            return found + 1;
        }

        if (link_declared(emitter, first, head)) {
            assert(level + 1 < std.math.maxInt(u32));

            return level + 1;
        }

        if (link_sequenced(emitter, first)) {
            assert(level + 1 < std.math.maxInt(u32));

            return level + 1;
        }
    }

    if (headed) {
        assert(level + 1 < std.math.maxInt(u32));

        return level + 1;
    }

    return null;
}

fn dotted_headed(emitter: *const Emitter, first: u32, head: u32) bool {
    assert(first < head);
    assert(head < emitter.count);

    if (head >= emitter.line_first) return false;
    if (emit.is_dot(emitter, head)) return false;
    if (emitter.depth == 0) return false;

    const open = line.frame(emitter).open;
    if (open < first) return false;
    if (open >= head) return false;
    return link_nested(emitter, first, open);
}

fn link_declared(emitter: *const Emitter, first: u32, head: u32) bool {
    assert(first <= head);
    assert(head < emitter.count);

    if (emitter.listed == 0) return false;
    if (first != emitter.line_before) return false;

    const binder = emitter.binders[emitter.listed - 1];
    if (binder.depth != emitter.depth) return false;
    if (binder.start >= first) return false;
    if (head >= binder.stop) return false;
    if (!link_declared_valued(emitter, head)) return false;

    const comma = emit.back_of(emitter, first) orelse return false;
    return bind.opens_a_declarator(emitter, comma);
}

fn link_declared_valued(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const held = emit.back_of(emitter, head) orelse return false;
    return emitter.tokens[held].is_punctuation(.assign);
}

fn link_sequenced(emitter: *const Emitter, first: u32) bool {
    assert(first < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (first != emitter.line_before) return false;
    if (!emitter.policy.sequence_lines) return false;

    const held = emit.back_of(emitter, first) orelse return false;
    if (!emitter.tokens[held].is_punctuation(.comma)) return false;
    if (bind.sequence_wrapped(emitter)) return true;
    if (line.statement_level(emitter)) return true;
    return bind.sequence_grouped(emitter);
}

fn link_nested(emitter: *const Emitter, first: u32, open: u32) bool {
    assert(first <= open);
    assert(open < emitter.count);

    var depth: u32 = 0;
    var scan = first;

    while (scan < open) {
        if (tmpl.template_body(emitter, scan)) |stop| {
            if (stop >= open) {
                scan += 1;
            } else {
                scan = stop + 1;
            }

            continue;
        }

        if (!link_nested_step(emitter, scan, &depth)) return false;

        scan += 1;
    }

    return true;
}

fn link_nested_step(emitter: *const Emitter, scan: u32, depth: *u32) bool {
    assert(scan < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const kind = emitter.tokens[scan].kind;
    const opens = link_nested_opens(emitter, scan, kind);
    const closes = walk.is_close(kind) or kind == .block_end;

    if (opens) {
        depth.* += 1;

        return true;
    }

    if (closes) {
        if (depth.* == 0) return false;

        depth.* -= 1;

        return true;
    }

    const commas = depth.* == 0 and kind.eql(.{ .punctuation = .comma });
    if (commas) return false;
    return true;
}

fn link_nested_opens(emitter: *const Emitter, scan: u32, kind: Token.Kind) bool {
    assert(scan < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (walk.is_open(kind)) return true;
    if (kind == .block_start) return true;
    return walk.substituting(emitter.source, emitter.tokens[scan]);
}

pub fn chain_cast_levels(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const level = chain_cast_level(emitter, position) orelse return;

    assert(level < emitter.indent);

    try line.level(emitter, level);
}

pub fn chain_cast_close(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    if (!emitter.tokens[position].is_punctuation(.paren_close)) return null;

    const open = emitter.brackets.open_of(position) orelse return null;
    const before = emit.back_of(emitter, open) orelse return null;
    const head = chain_cast_head(emitter, before) orelse return null;

    assert(open < position);
    assert(head < before);

    return line.level_at(emitter, head);
}

fn chain_cast_level(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    const head = chain_cast_head(emitter, position) orelse return null;
    const level = line.level_at(emitter, head) orelse return null;

    assert(head < position);

    if (level < emitter.indent) return level;
    return null;
}

pub fn chain_cast_head(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    var cast = position;
    var steps: u32 = 0;

    while (steps < emitter.count) : (steps += 1) {
        assert(cast <= position);

        if (!worded(cast_words, emitter.tokens[cast].text(emitter.source))) return null;

        const first = span.line_opened(emitter, cast) orelse return null;
        if (!emit.is_dot(emitter, first)) return null;
        if (bracketed_since(emitter, first, cast)) return null;

        const previous = emit.back_of(emitter, cast) orelse return null;

        if (chain_cast_again(emitter, first, previous)) |again| {
            assert(again < cast);

            cast = again;

            continue;
        }

        if (!chain_cast_linked(emitter, first, previous)) return null;

        const head = chain_start(emitter, first) orelse return null;
        if (head < first) return head;
        return null;
    }

    return null;
}

fn chain_cast_again(emitter: *const Emitter, first: u32, previous: u32) ?u32 {
    assert(first < emitter.count);
    assert(previous < emitter.count);

    const held = emit.back_of(emitter, previous) orelse return null;
    const casted = worded(cast_words, emitter.tokens[held].text(emitter.source));
    const previous_dot = emitter.tokens[previous].is_punctuation(.dot);

    if (!casted) return null;
    if (previous_dot) return null;
    if (held < first) return null;
    return held;
}

fn chain_cast_linked(emitter: *const Emitter, first: u32, previous: u32) bool {
    assert(first < emitter.count);
    assert(previous < emitter.count);

    const kind = emitter.tokens[previous].kind;

    if (walk.is_close(kind)) {
        const open = emitter.brackets.open_of(previous) orelse return false;

        assert(open < previous);

        return open >= first;
    }

    if (kind != .identifier) return false;

    const dot = emit.back_of(emitter, previous) orelse return false;
    if (dot < first) return false;
    return emit.is_dot(emitter, dot);
}

fn bracketed_since(emitter: *const Emitter, from: u32, position: u32) bool {
    assert(from <= position);
    assert(position < emitter.count);

    var scan = position;

    for (0..chain_scan_max) |_| {
        const before = emit.back_of(emitter, scan) orelse return false;
        if (before < from) return false;

        const kind = emitter.tokens[before].kind;

        if (walk.is_close(kind)) {
            scan = emitter.brackets.open_of(before) orelse return false;

            continue;
        }

        if (walk.is_open(kind)) return true;

        assert(before < scan);

        scan = before;
    }

    return false;
}

pub fn chain_brace_lonely(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.chain_simples) return false;

    var called = false;
    var count: u32 = 0;
    var scan = position;

    for (0..chain_scan_max) |_| {
        const after = emit.ahead_of(emitter, scan) orelse break;
        const kind = emitter.tokens[after].kind;

        assert(after > scan);

        if (walk.is_open(kind)) {
            const close = join.closing_of(emitter, after) orelse break;
            const calling = kind.eql(.{ .punctuation = .paren_open }) and !called;

            if (calling) {
                called = true;
                count += 1;
            }

            scan = close;

            continue;
        }

        const worded_after = kind == .identifier or kind == .keyword;
        const named = worded_after and emit.is_dot(emitter, scan);

        if (!named) {
            if (!emit.is_dot(emitter, after)) break;
        }

        called = called and !emit.is_dot(emitter, after);
        scan = after;
    }

    return count < 2;
}

pub fn chain_start(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    var head = position;
    var scan = position;

    if (chain_typed(emitter, position)) return null;

    for (0..chain_scan_max) |_| {
        assert(head <= position);

        const before = emit.back_of(emitter, scan) orelse return chain_start_found(head, position);
        const kind = emitter.tokens[before].kind;
        const closed = walk.is_close(kind);
        const ended = emitter.policy.chain_simples and kind == .block_end;
        const worded_scan = chain_start_worded(emitter.tokens[scan].kind);
        const bodied = emitter.policy.chain_simples and closed and worded_scan;

        if (ended) return chain_start_found(head, position);
        if (bodied) return chain_start_found(head, position);

        if (closed) {
            if (edge.header_closed(emitter, before, scan)) return chain_start_found(head, position);

            scan = emitter.brackets.open_of(before) orelse return null;
            head = scan;

            continue;
        }

        if (chain_start_angle(emitter, before)) |open| {
            scan = open;
            head = open;

            continue;
        }

        const carried = chain_start_carried(emitter, before, scan, head);

        if (kind == .comment) {
            scan = before;

            continue;
        }

        if (!carried) return chain_start_found(head, position);

        scan = before;
        head = before;
    }

    return null;
}

fn chain_start_found(head: u32, position: u32) ?u32 {
    assert(head <= position);
    assert(position < std.math.maxInt(u32));

    if (head < position) return head;
    return null;
}

fn chain_start_worded(kind: Token.Kind) bool {
    if (kind == .comment) return false;

    const result = kind == .identifier or kind == .keyword;

    if (result) assert(kind != .comment);
    if (kind == .punctuation) assert(!result);

    return result;
}

fn chain_start_angle(emitter: *const Emitter, before: u32) ?u32 {
    assert(before < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const text = emitter.tokens[before].text(emitter.source);

    if (!emitter.policy.chain_simples) return null;
    if (text.len == 0) return null;

    for (text) |byte| {
        if (byte != '>') return null;
    }

    return join.angle_head(emitter, before);
}

fn chain_start_carried(emitter: *const Emitter, before: u32, scan: u32, head: u32) bool {
    assert(before < scan);
    assert(head <= emitter.count);

    const kind = emitter.tokens[before].kind;
    const text = emitter.tokens[before].text(emitter.source);

    if (chain_start_worded(kind)) {
        const stopped = worded(chain_stops, text);
        const membered = chain_start_member(emitter, before);
        const free = !stopped or membered;

        if (free) {
            if (chain_attached(emitter, before, head)) return true;
        }
    }

    if (walk.text_is(text, "!")) {
        if (!unary_not(emitter, before)) return true;
    }

    if (emit.is_dot(emitter, before)) return true;
    if (kind != .string) return false;
    if (head != scan) return false;
    return emit.is_dot(emitter, scan);
}

fn chain_start_member(emitter: *const Emitter, before: u32) bool {
    assert(before < emitter.count);

    const held = emit.back_of(emitter, before) orelse return false;

    assert(held < before);

    return emit.is_dot(emitter, held);
}

fn chain_typed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (emitter.policy.type_words.len == 0) return false;
    if (emitter.typed) return true;

    var scan = position;

    for (0..chain_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;
        const token = emitter.tokens[held];

        assert(held < scan);

        if (worded(cast_words, token.text(emitter.source))) return true;

        if (token.kind != .identifier) {
            if (!emit.is_dot(emitter, held)) return false;
        }

        scan = held;
    }

    return false;
}

fn chain_attached(emitter: *const Emitter, word: u32, head: u32) bool {
    assert(word < emitter.count);
    assert(head < emitter.count);

    const token = emitter.tokens[head];
    const typed = worded(typed_words, emitter.tokens[word].text(emitter.source));
    if (typed) return true;
    if (emit.is_dot(emitter, head)) return true;
    if (walk.text_is(token.text(emitter.source), "!")) return true;

    const joined = emitter.tokens[word].end() == token.offset;
    if (!joined) return false;
    if (walk.is_open(token.kind)) return true;
    if (token.kind == .string) return true;
    return walk.text_is(token.text(emitter.source), "<");
}

fn unary_not(emitter: *const Emitter, bang: u32) bool {
    assert(bang < emitter.count);

    const held = emit.back_of(emitter, bang) orelse return true;
    const token = emitter.tokens[held];

    assert(held < bang);

    if (!token.ends_a_value()) return true;
    return token.end() < emitter.tokens[bang].offset;
}

pub fn angle_membered(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (join.angle_head(emitter, close)) |open| {
        if (emit.back_of(emitter, open)) |name| {
            if (emit.back_of(emitter, name)) |held| {
                if (emit.is_dot(emitter, held)) return true;
            }
        }
    }

    const open = emit.ahead_of(emitter, close) orelse return false;

    assert(open > close);

    return list.signature_opens(emitter, open);
}

pub fn chain_grouped(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.chain_simples) return false;
    if (!emit.is_dot(emitter, position)) return false;
    if (!chain_called(emitter, position)) return false;

    var name = previous;

    for (0..chain_scan_max) |_| {
        if (emitter.tokens[name].kind != .identifier) return false;

        const dot = emit.back_of(emitter, name) orelse return false;
        if (!emit.is_dot(emitter, dot)) return false;

        const before = emit.back_of(emitter, dot) orelse return false;

        if (emitter.tokens[before].is_punctuation(.paren_close)) {
            return chain_grouped_called(emitter, before);
        }

        name = before;
    }

    return false;
}

fn chain_grouped_called(emitter: *const Emitter, before: u32) bool {
    assert(before < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const open = emitter.brackets.open_of(before) orelse return false;
    if (!list.calling(emitter, open)) return false;

    const callee = emit.back_of(emitter, open) orelse return false;
    if (emitter.tokens[callee].kind != .identifier) return false;

    const held = emit.back_of(emitter, callee) orelse return false;
    return emit.is_dot(emitter, held);
}

pub fn chain_singled(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!emitter.policy.chain_simples) return false;
    if (!emit.is_dot(emitter, position)) return false;

    const head = chain_start(emitter, position) orelse return false;
    const stop = chain_stop(emitter, head) orelse return false;
    if (position > chain_last(emitter, head, stop)) return false;
    if (chain_commented(emitter, head, stop)) return false;

    var links: [chain_link_max]u32 = @splat(0);
    const count = chain_groups(emitter, head, stop, &links);
    const merged = span.chain_merges(emitter, head, &links, count);
    const cutoff: u32 = if (merged) 3 else 2;

    if (count == 0) return false;
    return count < cutoff;
}

pub fn hugs_open(emitter: *const Emitter, position: u32) u32 {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    var count: u32 = 0;

    for (emitter.nest[0..emitter.depth]) |frame| {
        if (frame.spread == null) continue;
        if (frame.hugged == 0) continue;
        if (frame.hugged > position) continue;

        count += 1;
    }

    assert(count <= emitter.depth);

    return count;
}

pub fn chain_closes(emitter: *Emitter, position: u32, closing: bool) error{Overflow}!void {
    assert(position < emitter.count);

    if (closing) {
        const owed = emitter.chain_owed < core.wrap_depth_max;

        if (await_chain_end(emitter, emitter.closed.open, position)) |end| {
            if (owed) {
                emitter.chain_ends[emitter.chain_owed] = end;
                emitter.chain_owed += 1;

                return;
            }
        }

        if (!list.pattern_shares(emitter, position)) try emitter.document.push(.group_close);
    }

    while (emitter.chain_owed > 0) {
        if (emitter.chain_ends[emitter.chain_owed - 1] != position) break;

        emitter.chain_owed -= 1;

        try emitter.document.push(.group_close);
    }

    assert(emitter.chain_owed <= core.wrap_depth_max);
}

fn await_chain_end(emitter: *const Emitter, open: u32, close: u32) ?u32 {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return null;
    if (list.calling(emitter, open)) return null;

    const word = emit.ahead_of(emitter, open) orelse return null;
    if (!walk.text_is(emitter.tokens[word].text(emitter.source), "await")) return null;
    if (await_operand_end(emitter, word) != close) return null;

    const end = await_group_end(emitter, close) orelse return null;
    const held = await_enclosing(emitter, open) orelse return null;

    assert(end > close);

    if (!await_parenthesized(emitter, held)) return null;
    return end;
}

fn await_operand_end(emitter: *const Emitter, word: u32) ?u32 {
    assert(word < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = emit.ahead_of(emitter, word) orelse return null;

    for (0..await_scan_max) |_| {
        const token = emitter.tokens[scan];
        const opens = walk.is_open(token.kind) or walk.substituting(emitter.source, token);

        if (opens) {
            scan = join.closing_of(emitter, scan) orelse return null;
        } else {
            if (!await_linked(emitter, scan)) return scan;
        }

        scan = emit.ahead_of(emitter, scan) orelse return null;
    }

    return null;
}

fn await_linked(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[position];

    switch (token.kind) {
        .comment, .identifier, .number, .string => return true,
        .block_end, .block_start, .keyword, .newline, .punctuation => {},
    }

    if (emit.is_dot(emitter, position)) return true;
    return worded(await_operands, token.text(emitter.source));
}

fn await_group_end(emitter: *const Emitter, close: u32) ?u32 {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var named = false;
    var scan = close;

    for (0..chain_link_max) |_| {
        const dot = emit.ahead_of(emitter, scan) orelse return null;
        if (!emit.is_dot(emitter, dot)) break;

        const name = emit.ahead_of(emitter, dot) orelse return null;
        const kind = emitter.tokens[name].kind;
        const worded_name = kind == .identifier or kind == .keyword;
        if (!worded_name) return null;

        named = true;
        scan = name;
    }

    const open = emit.ahead_of(emitter, scan) orelse return null;

    if (!named) return null;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return null;

    const end = emitter.brackets.close_of(open) orelse return null;
    const held = emit.ahead_of(emitter, end) orelse return end;
    const token = emitter.tokens[held];

    if (emit.is_dot(emitter, held)) return null;
    if (token.kind == .string) return null;
    if (walk.text_is(token.text(emitter.source), "!")) return null;
    if (token.opens_a_group()) return null;
    return end;
}

fn await_enclosing(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var covered = true;
    var scan = open;

    for (0..await_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return null;
        const token = emitter.tokens[held];

        assert(held < scan);

        if (walk.is_close(token.kind)) {
            scan = emitter.brackets.open_of(held) orelse return null;

            continue;
        }

        const opens = walk.is_open(token.kind) or walk.substituting(emitter.source, token);

        if (opens) {
            if (token.kind == .block_start) {
                if (emit.bodied(emitter, held)) return null;
            }

            covered = true;
            scan = held;

            continue;
        }

        const text = token.text(emitter.source);

        if (walk.text_is(text, "await")) {
            if (covered) return held;
        }

        if (walk.text_is(text, ";")) return null;

        covered = covered and await_linked(emitter, held);
        scan = held;
    }

    return null;
}

fn await_parenthesized(emitter: *const Emitter, word: u32) bool {
    assert(word < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var after = await_operand_end(emitter, word) orelse return false;
    var before = emit.back_of(emitter, word);

    for (0..await_scan_max) |_| {
        const open = before orelse break;
        if (!await_parenthesized_open(emitter, open, after)) break;

        const ahead = emit.ahead_of(emitter, after) orelse return false;

        before = emit.back_of(emitter, open);
        after = ahead;
    }

    if (before) |held| {
        if (await_parenthesized_operated(emitter, held)) return true;
    }

    return await_parenthesized_after(emitter, after);
}

fn await_parenthesized_open(emitter: *const Emitter, open: u32, after: u32) bool {
    assert(open < emitter.count);
    assert(after < emitter.count);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;
    if (list.calling(emitter, open)) return false;
    if (split.headed(emitter, open)) return false;
    return emitter.brackets.close_of(open) == after;
}

fn await_parenthesized_operated(emitter: *const Emitter, held: u32) bool {
    assert(held < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (call.unary_at(emitter, held)) return true;
    if (span.wrapping_operator(emitter, held)) return true;
    return worded(await_operators, emitter.tokens[held].text(emitter.source));
}

fn await_parenthesized_after(emitter: *const Emitter, after: u32) bool {
    assert(after < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[after];
    const text = token.text(emitter.source);

    if (emit.is_dot(emitter, after)) return true;
    if (span.wrapping_operator(emitter, after)) return true;
    if (token.kind == .string) return true;
    if (token.opens_a_group()) return true;
    if (worded(await_tails, text)) return true;
    if (!walk.text_is(text, "?")) return false;
    return !tern.optional(emitter, after);
}

pub fn chain_linked(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (emit.is_dot(emitter, position)) return true;
    return lookup_link(emitter, position);
}

fn lookup_link(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (!emitter.tokens[open].is_punctuation(.bracket_open)) return false;

    const close = emitter.brackets.close_of(open) orelse return false;
    const called = lookup_called(emitter, open);
    const numeric = lookup_numeric(emitter, open, close);

    assert(close > open);

    if (!called) return false;
    if (numeric) return false;
    return emit.ahead_of(emitter, open) != close;
}

fn lookup_head(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (!emitter.policy.chain_simples) return false;
    return lookup_link(emitter, open);
}

fn lookup_called(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    const held = emit.back_of(emitter, open) orelse return false;

    assert(held < open);

    if (!emitter.tokens[held].is_punctuation(.paren_close)) return false;

    const paren = emitter.brackets.open_of(held) orelse return false;
    return list.calling(emitter, paren);
}

fn lookup_numeric(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const held = emit.ahead_of(emitter, open) orelse return false;
    if (emitter.tokens[held].kind != .number) return false;
    return emit.ahead_of(emitter, held) == close;
}

fn worded(words: []const []const u8, text: []const u8) bool {
    assert(words.len > 0);
    assert(text.len <= std.math.maxInt(u32));

    for (words) |word| {
        if (walk.text_eql(word, text)) return true;
    }

    return false;
}

pub fn line_led(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.lined < core.line_level_max);

    var index = emitter.lined;

    for (0..core.line_level_max) |_| {
        index = if (index == 0) core.line_level_max - 1 else index - 1;

        const held = emitter.lines[index];
        if (held.start == 0) return null;

        if (held.start - 1 <= position) {
            assert(held.level + emitter.leds[index] < std.math.maxInt(u32));

            return held.level + emitter.leds[index];
        }
    }

    return null;
}

pub fn chain_headline(emitter: *const Emitter, head: u32, end: u32) u32 {
    assert(head < emitter.count);
    assert(end <= emitter.count);

    if (!emitter.policy.chain_simples) return end;

    var depth: u32 = 0;
    var scan = head;

    while (scan < end) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;

        if (chain_headline_at(emitter, head, scan, end, depth)) |found| return found;

        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else {}
    }

    return end;
}

fn chain_headline_at(emitter: *const Emitter, head: u32, scan: u32, end: u32, depth: u32) ?u32 {
    assert(head <= scan);
    assert(scan < end);

    if (depth == 0) {
        if (chain_headline_lookup(emitter, head, scan, end)) return scan;
        if (chain_headline_cast(emitter, scan)) return scan;
    }

    if (chain_headline_braced(emitter, scan)) {
        if (chain_headline_list(emitter, head, scan)) |open| return open;
        if (chain_headline_enclosed(emitter, head, scan)) |open| return open;
        return call.chain_hugged_head(emitter, scan) orelse scan;
    }

    if (chain_headline_commented(emitter, scan)) {
        return chain_headline_list(emitter, head, scan) orelse
            chain_headline_enclosed(emitter, head, scan) orelse scan;
    }

    if (chain_headline_composed(emitter, head, scan, end)) {
        return chain_headline_list(emitter, head, scan) orelse scan;
    }

    if (chain_template_list(emitter, head, scan, end)) |open| return open;
    if (chain_headline_argued(emitter, head, scan, end)) return scan;

    const arrow = walk.text_is(emitter.tokens[scan].text(emitter.source), "=>");

    if (arrow) {
        if (arrow_body_hardened(emitter, scan, end)) {
            return chain_headline_list(emitter, head, scan) orelse
                chain_headline_enclosed(emitter, head, scan) orelse scan;
        }
    }

    return null;
}

fn chain_headline_ends(emitter: *const Emitter, close: u32, end: u32) bool {
    assert(close < emitter.count);
    assert(end <= emitter.count);

    if (close == end) return true;
    return emit.ahead_of(emitter, close) == end;
}

fn chain_headline_lookup(emitter: *const Emitter, head: u32, scan: u32, end: u32) bool {
    assert(head <= scan);
    assert(scan < end);

    if (scan <= head) return false;
    if (!emitter.tokens[scan].is_punctuation(.bracket_open)) return false;

    const close = join.closing_of(emitter, scan) orelse return false;
    if (!chain_headline_ends(emitter, close, end)) return false;
    return list.bracket_grouped(emitter, scan, close);
}

fn chain_headline_cast(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);

    if (emitter.tokens[scan].kind != .block_start) return false;

    const before = emit.back_of(emitter, scan) orelse return false;

    assert(before < scan);

    if (!worded(cast_words, emitter.tokens[before].text(emitter.source))) return false;

    const after = emit.ahead_of(emitter, scan) orelse return false;
    return emitter.tokens[after].kind != .block_end;
}

fn chain_headline_braced(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);

    if (emitter.tokens[scan].kind != .block_start) return false;

    const objected = body.bodied_brace(emitter, scan) or chain_headline_object(emitter, scan);
    if (!objected) return false;

    const held = emit.ahead_of(emitter, scan) orelse return false;

    assert(held > scan);

    return emitter.tokens[held].kind != .block_end;
}

fn chain_headline_object(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.tokens[scan].kind == .block_start);

    if (!call.object_parted(emitter, scan)) return false;
    return !sole_param_type(emitter, scan);
}

fn chain_headline_commented(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);

    if (!emitter.tokens[scan].is_punctuation(.bracket_open)) return false;

    const close = join.closing_of(emitter, scan) orelse return false;

    assert(close > scan);

    for (scan..close) |at| {
        const token = emitter.tokens[at];
        if (token.kind != .comment) continue;
        if (std.mem.startsWith(u8, token.text(emitter.source), "//")) return true;
    }

    return false;
}

fn chain_headline_composed(emitter: *const Emitter, head: u32, scan: u32, end: u32) bool {
    assert(head <= scan);
    assert(scan < end);

    if (!walk.is_open(emitter.tokens[scan].kind)) return false;
    if (scan <= head) return false;

    const close = join.closing_of(emitter, scan) orelse return false;
    if (close > end) return false;
    return call.composed_args(emitter, scan);
}

fn chain_headline_argued(emitter: *const Emitter, head: u32, scan: u32, end: u32) bool {
    assert(head <= scan);
    assert(scan < end);

    if (!emitter.tokens[scan].is_punctuation(.paren_open)) return false;
    if (scan <= head) return false;

    const close = join.closing_of(emitter, scan) orelse return false;
    if (!chain_headline_ends(emitter, close, end)) return false;
    return args_chained(emitter, scan, close);
}

fn chain_template_list(emitter: *const Emitter, head: u32, scan: u32, end: u32) ?u32 {
    assert(head <= scan);
    assert(scan < end);

    if (scan <= head) return null;

    const stop = tmpl.template_body(emitter, scan) orelse return null;
    if (stop > end) return null;

    const from = emitter.tokens[scan].offset;
    const to = emitter.tokens[stop].end();
    if (body.parted_by(emitter, from, to) == 0) return null;

    const open = chain_headline_list(emitter, head, scan) orelse return null;
    const close = join.closing_of(emitter, open) orelse return null;
    if (!chain_headline_ends(emitter, close, end)) return null;
    return open;
}

fn args_chained(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var start = args_chained_start(emitter, open, close);

    for (0..argument_scan_max) |_| {
        const from = start orelse return false;
        const to = call.argument_end(emitter, from, close);
        if (args_chained_at(emitter, from, to)) return true;

        start = args_chained_start(emitter, to, close);
    }

    return false;
}

fn args_chained_start(emitter: *const Emitter, position: u32, close: u32) ?u32 {
    assert(position <= close);
    assert(close < emitter.count);

    const held = emit.ahead_of(emitter, position) orelse return null;
    if (held < close) return held;
    return null;
}

fn args_chained_at(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from < emitter.count);
    assert(to < emitter.count);

    var head = from;

    if (walk.text_is(emitter.tokens[from].text(emitter.source), "...")) {
        const held = emit.ahead_of(emitter, from) orelse return false;
        if (held > to) return false;

        head = held;
    }

    const token = emitter.tokens[head];
    const named = token.kind == .identifier or walk.text_is(token.text(emitter.source), "this");
    if (!named) return false;

    const stop = chain_stop(emitter, head) orelse return false;
    if (stop > to) return false;
    return call.chain_composed(emitter, head, stop);
}

fn arrow_body_hardened(emitter: *const Emitter, arrow: u32, end: u32) bool {
    assert(arrow < emitter.count);
    assert(end <= emitter.count);

    var start = emit.ahead_of(emitter, arrow) orelse return false;
    if (start >= end) return false;

    while (arrow_body_parenthesized(emitter, start)) {
        const inner = emit.ahead_of(emitter, start) orelse return false;

        assert(inner > start);
        start = inner;
    }

    if (walk.text_is(emitter.tokens[start].text(emitter.source), "async")) {
        if (emit.ahead_of(emitter, start)) |held| start = held;
    }

    if (arrow_body_opened(emitter, start)) return false;
    return arrow_body_scan(emitter, start, end);
}

fn arrow_body_parenthesized(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!emitter.tokens[position].is_punctuation(.paren_open)) return false;
    return !chain_signature_at(emitter, position);
}

fn arrow_body_opened(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const token = emitter.tokens[position];
    if (token.kind == .block_start) return true;
    if (token.is_punctuation(.bracket_open)) return true;
    if (tmpl.spanned_unit(emitter, position) != null) return true;
    if (chain_signature_at(emitter, position)) return true;
    if (walk.text_is(token.text(emitter.source), "<")) return true;

    const held = emit.ahead_of(emitter, position) orelse return false;

    assert(held > position);

    return walk.text_is(emitter.tokens[held].text(emitter.source), "=>");
}

fn arrow_body_scan(emitter: *const Emitter, start: u32, end: u32) bool {
    assert(start < emitter.count);
    assert(end <= emitter.count);

    var depth: u32 = 0;
    var scan = start;

    while (scan < end) {
        if (tmpl.spanned_unit(emitter, scan)) |stop| {
            assert(stop >= scan);
            scan = stop + 1;

            continue;
        }

        const token = emitter.tokens[scan];

        if (arrow_body_braced(emitter, scan)) return true;

        const opens = walk.is_open(token.kind) or token.kind == .block_start;
        const closes = walk.is_close(token.kind) or token.kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            if (depth == 0) return false;

            depth -= 1;
        } else if (depth == 0) {
            if (token.is_punctuation(.comma)) return false;
        } else {}

        scan += 1;
    }

    return false;
}

fn arrow_body_braced(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);

    if (emitter.tokens[scan].kind != .block_start) return false;

    const objected = body.bodied_brace(emitter, scan) or call.object_parted(emitter, scan);
    if (!objected) return false;

    const held = emit.ahead_of(emitter, scan) orelse return false;

    assert(held > scan);

    return emitter.tokens[held].kind != .block_end;
}

fn chain_signature_at(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const close = join.closing_of(emitter, open) orelse return false;
    const held = emit.ahead_of(emitter, close) orelse return false;

    return walk.text_is(emitter.tokens[held].text(emitter.source), "=>");
}

fn chain_hugging(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var heads: [argument_head_max]u32 = @splat(0);
    const found = span.spread_heads(emitter, open, close, &heads);
    if (found == 0) return false;

    assert(found <= argument_head_max);

    if (found == 2) {
        if (call.hugged_first(emitter, open, close, heads[0] + 1)) return true;
    }

    const tail = heads[found - 1];
    if (span.spread_hugged(emitter, tail, close)) return true;
    return own.cast_functioned(emitter, tail);
}

fn sole_param_type(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    const colon = emit.back_of(emitter, open) orelse return false;
    if (!emitter.tokens[colon].is_punctuation(.colon)) return false;

    const before = emit.back_of(emitter, colon) orelse return false;
    var name = before;

    if (walk.text_is(emitter.tokens[before].text(emitter.source), "?")) {
        name = emit.back_of(emitter, before) orelse return false;
    }

    const closed = emitter.tokens[name].kind == .block_end or
        emitter.tokens[name].is_punctuation(.bracket_close);

    if (closed) name = emitter.brackets.open_of(name) orelse return false;

    assert(name < open);

    const paren = emit.back_of(emitter, name) orelse return false;
    if (!emitter.tokens[paren].is_punctuation(.paren_open)) return false;

    const close = join.closing_of(emitter, paren) orelse return false;
    return wide.element_count(emitter, paren, close) == 1;
}

fn chain_headline_list(emitter: *const Emitter, head: u32, curly: u32) ?u32 {
    assert(head < emitter.count);
    assert(curly < emitter.count);

    var scan = head;

    while (scan < curly) : (scan += 1) {
        if (chain_headline_listed(emitter, scan, curly)) return scan;
    }

    return null;
}

fn chain_headline_listed(emitter: *const Emitter, scan: u32, curly: u32) bool {
    assert(scan < curly);
    assert(curly < emitter.count);

    if (!emitter.tokens[scan].is_punctuation(.paren_open)) return false;
    if (!list.calling(emitter, scan)) return false;

    const close = join.closing_of(emitter, scan) orelse return false;
    if (close <= curly) return false;

    const held = emit.ahead_of(emitter, scan) orelse return false;
    if (held == close) return false;
    return !chain_hugging(emitter, scan, close);
}

fn chain_headline_enclosed(emitter: *const Emitter, head: u32, curly: u32) ?u32 {
    assert(head < emitter.count);
    assert(curly < emitter.count);

    var scan = head;

    while (scan < curly) : (scan += 1) {
        if (!chain_headline_literal(emitter, scan)) continue;

        const close = join.closing_of(emitter, scan) orelse continue;
        if (close > curly) return scan;
    }

    return null;
}

fn chain_headline_literal(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const token = emitter.tokens[scan];

    if (token.kind == .block_start) {
        if (!body.bodied_brace(emitter, scan)) return true;
    }

    return token.is_punctuation(.bracket_open);
}

pub fn chain_rest(emitter: *const Emitter, headline: u32, stop: u32) u32 {
    assert(headline <= emitter.count);
    assert(stop < emitter.count);

    return chain_loop_tail(emitter, headline, stop) + chain_paren_tail(emitter, headline, stop);
}

fn chain_paren_tail(emitter: *const Emitter, headline: u32, stop: u32) u32 {
    assert(headline <= emitter.count);
    assert(stop < emitter.count);

    if (headline < stop) return 0;

    var found: u32 = 0;
    var scan = stop;

    for (0..chain_link_max) |_| {
        const close = chain_paren_tail_close(emitter, scan) orelse break;
        if (!chain_paren_tail_grouped(emitter, close)) break;

        found += 1;
        scan = close;
    }

    assert(found <= chain_link_max);

    const separated = found > 0 and chain_paren_tail_separated(emitter, scan);
    assert(found + @intFromBool(separated) <= emitter.count);

    return found + @intFromBool(separated);
}

fn chain_paren_tail_close(emitter: *const Emitter, scan: u32) ?u32 {
    assert(scan < emitter.count);

    const held = emit.ahead_of(emitter, scan) orelse return null;

    assert(held > scan);

    if (emitter.tokens[held].is_punctuation(.paren_close)) return held;
    return null;
}

fn chain_paren_tail_grouped(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.tokens[close].is_punctuation(.paren_close));

    const open = emitter.brackets.open_of(close) orelse return false;
    if (list.calling(emitter, open)) return false;
    return !split.headed(emitter, open);
}

fn chain_paren_tail_separated(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const held = emit.ahead_of(emitter, scan) orelse return false;
    const token = emitter.tokens[held];
    if (token.is_punctuation(.comma)) return true;
    return token.is_punctuation(.semicolon);
}

fn chain_loop_tail(emitter: *const Emitter, headline: u32, stop: u32) u32 {
    assert(headline <= emitter.count);
    assert(stop < emitter.count);

    if (headline < stop) return 0;

    const close = chain_paren_tail_close(emitter, stop) orelse return 0;
    const open = emitter.brackets.open_of(close) orelse return 0;

    assert(open < close);

    if (!chain_loop_tail_looped(emitter, open)) return 0;
    if (!chain_loop_tail_iterated(emitter, open, stop)) return 0;

    const after = emit.ahead_of(emitter, close);
    const block = if (after) |held| emitter.tokens[held].kind == .block_start else false;
    const returned = 1 + 2 * @as(u32, @intFromBool(block));

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn chain_loop_tail_looped(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    const held = emit.back_of(emitter, open) orelse return false;
    const held_text = emitter.tokens[held].text(emitter.source);
    if (walk.text_is(held_text, "for")) return true;
    if (!walk.text_is(held_text, "await")) return false;

    const word = emit.back_of(emitter, held) orelse return false;

    assert(word < held);

    return walk.text_is(emitter.tokens[word].text(emitter.source), "for");
}

fn chain_loop_tail_iterated(emitter: *const Emitter, open: u32, stop: u32) bool {
    assert(open <= stop);
    assert(stop < emitter.count);

    var iterated = false;
    var scan = open + 1;

    while (scan < stop) {
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;

        if (opens) {
            const held = join.closing_of(emitter, scan) orelse return false;

            assert(held > scan);
            scan = held + 1;

            continue;
        }

        if (worded(iterating_words, emitter.tokens[scan].text(emitter.source))) iterated = true;

        scan += 1;
    }

    return iterated;
}

pub fn chain_ternary(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.wraps_owed <= emitter.wrapped.len);

    for (emitter.wrapped[0..emitter.wraps_owed]) |*held| {
        if (chain_ternary_wrapped(emitter, held, head)) return true;
    }

    return false;
}

fn chain_ternary_wrapped(emitter: *const Emitter, held: *const core.Wrapped, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.depth <= emitter.nest.len);

    switch (held.wrap) {
        .guarded, .nested, .ternary => {},
        else => return false,
    }

    if (head <= held.start) return false;
    if (head > held.close) return false;
    return held.depth == emitter.depth;
}

pub fn chain_owned(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.assigns <= emitter.assigned.len);

    if (emitter.owed == 0) return false;

    const held = emit.back_of(emitter, chain_seated_at(emitter, head)) orelse return false;
    const held_text = emitter.tokens[held].text(emitter.source);
    if (walk.text_is(held_text, "=>")) return true;
    if (!walk.text_is(held_text, "=")) return false;

    for (emitter.assigned[0..emitter.assigns]) |assigned| {
        if (assigned.equals == held) return true;
    }

    return false;
}

pub fn member_casted(emitter: *const Emitter, head: u32, stop: u32) ?u32 {
    assert(head <= stop);
    assert(stop < emitter.count);

    var depth: u32 = 0;
    var scan = head;

    while (scan <= stop) {
        if (tmpl.spanned_unit(emitter, scan)) |end| {
            scan = end + 1;

            continue;
        }

        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (member_casted_grouped(emitter, scan, head, depth)) {
            return emit.back_of(emitter, scan);
        } else {}

        scan += 1;
    }

    return null;
}

fn member_casted_grouped(emitter: *const Emitter, scan: u32, head: u32, depth: u32) bool {
    assert(head <= scan);
    assert(scan < emitter.count);

    if (depth != 0) return false;
    if (scan == head) return false;
    if (!line.group_word(emitter, scan)) return false;

    const held = emit.back_of(emitter, scan) orelse return true;
    return !emit.is_dot(emitter, held);
}

pub fn member_cast_end(emitter: *const Emitter, word: u32, chain_end: u32) u32 {
    assert(word < emitter.count);
    assert(chain_end < emitter.count);

    var bracket: ?u32 = null;
    var scan = word;

    for (0..chain_scan_max) |_| {
        const held = emit.ahead_of(emitter, scan) orelse break;
        const token = emitter.tokens[held];
        const text = token.text(emitter.source);
        if (walk.text_is(text, "|")) return word;
        if (walk.text_is(text, "&")) return word;

        if (walk.text_is(text, "<")) {
            if (bracket == null) bracket = held;

            scan = join.angle_close(emitter, held) orelse held;

            continue;
        }

        const opens = walk.is_open(token.kind) or token.kind == .block_start;

        if (opens) {
            if (bracket == null) bracket = held;

            scan = join.closing_of(emitter, held) orelse held;

            continue;
        }

        if (member_cast_end_stop(token, text)) break;

        scan = held;
    }

    return bracket orelse chain_end;
}

fn member_cast_end_stop(token: Token, text: []const u8) bool {
    if (walk.is_close(token.kind)) return true;
    if (token.kind == .block_end) return true;
    if (token.is_punctuation(.comma)) return true;
    if (token.is_punctuation(.semicolon)) return true;
    assert(text.len <= std.math.maxInt(u32));

    return walk.text_is(text, "=>");
}

pub fn member_call_chain(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!emitter.policy.chain_simples) return false;

    const stop = chain_stop(emitter, head) orelse return false;
    var links: [chain_link_max]u32 = @splat(0);
    const count = chain_groups(emitter, head, stop, &links);
    const merges = span.chain_merges(emitter, head, &links, count);

    return count > 1 + @as(u32, @intFromBool(merges));
}

pub fn chain_groups(
    emitter: *const Emitter,
    head: u32,
    stop: u32,
    links: *[chain_link_max]u32,
) u32 {
    assert(head <= stop);
    assert(stop < emitter.count);

    const last = chain_last(emitter, head, stop);
    const newed = chain_newed(emitter, head, stop);
    var called = newed != null;
    var count: u32 = 0;
    var headed = false;
    var scan = newed orelse head;

    while (scan <= stop) {
        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            const linking = chain_groups_linked(called, headed, scan, last) and
                lookup_link(emitter, scan);

            const leading = !headed and called and scan < last and lookup_head(emitter, scan);
            const chains = linking or leading;

            if (chains) {
                if (count == chain_link_max) return 0;

                links[count] = scan;
                called = false;
                count += 1;
                headed = true;
            }

            called = called or kind.eql(.{ .punctuation = .paren_open });
            scan = (join.closing_of(emitter, scan) orelse stop) + 1;

            continue;
        }

        const opens = chain_groups_opens(emitter, scan, last, called, headed);

        if (opens) {
            if (count == chain_link_max) return 0;

            links[count] = scan;
            called = false;
            count += 1;
            headed = true;
        }

        scan += 1;
    }

    return count;
}

fn chain_groups_linked(called: bool, headed: bool, scan: u32, last: u32) bool {
    if (!headed) return false;
    if (!called) return false;
    return scan < last;
}

fn chain_groups_opens(
    emitter: *const Emitter,
    scan: u32,
    last: u32,
    called: bool,
    headed: bool,
) bool {
    assert(scan < emitter.count);

    if (!emit.is_dot(emitter, scan)) return false;
    if (scan >= last) return false;
    if (optional_call(emitter, scan)) return false;
    if (numeric_linked(emitter, scan)) return false;
    if (headed) return called;
    if (chain_called(emitter, scan)) return true;
    return chain_asserted(emitter, scan);
}

fn chain_newed(emitter: *const Emitter, head: u32, stop: u32) ?u32 {
    assert(head <= stop);
    assert(stop < emitter.count);

    const back = emit.back_of(emitter, head) orelse return null;
    if (!walk.text_is(emitter.tokens[back].text(emitter.source), "new")) return null;

    var scan = head;

    while (scan <= stop) {
        const kind = emitter.tokens[scan].kind;

        if (kind.eql(.{ .punctuation = .paren_open })) {
            const close = join.closing_of(emitter, scan) orelse return null;
            assert(close + 1 <= emitter.count);

            return close + 1;
        }

        if (walk.is_open(kind)) {
            scan = (join.closing_of(emitter, scan) orelse return null) + 1;
        } else {
            scan += 1;
        }
    }

    return null;
}

fn chain_last(emitter: *const Emitter, head: u32, stop: u32) u32 {
    assert(head <= stop);
    assert(stop < emitter.count);

    var last = head;
    var scan = head;

    while (scan <= stop) {
        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            if (chain_last_called(emitter, kind, scan)) last = scan;

            scan = (join.closing_of(emitter, scan) orelse stop) + 1;

            continue;
        }

        scan += 1;
    }

    return last;
}

fn chain_last_called(emitter: *const Emitter, kind: Token.Kind, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!kind.eql(.{ .punctuation = .paren_open })) return false;

    const held = emit.back_of(emitter, scan) orelse return false;
    const token = emitter.tokens[held];
    if (token.ends_a_value()) return true;
    if (walk.text_is(token.text(emitter.source), "!")) return true;
    if (walk.text_is(token.text(emitter.source), ">")) return true;
    return optional_call(emitter, held);
}

pub fn chain_trailed(emitter: *const Emitter, head: u32, stop: u32) ?u32 {
    assert(head <= stop);
    assert(stop < emitter.count);

    const first = member_trail(emitter, head, stop) orelse return null;
    if (!member_grouped(emitter, first)) return null;
    return emit.back_of(emitter, first);
}

pub fn slight_looped(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const held = emit.back_of(emitter, head) orelse return false;
    return iterating(emitter, held);
}

fn iterating(emitter: *const Emitter, word: u32) bool {
    assert(word < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const text = emitter.tokens[word].text(emitter.source);
    if (!worded(iterating_words, text)) return false;
    if (emitter.depth == 0) return false;

    const frame = line.frame(emitter);
    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return false;

    const held = emit.back_of(emitter, frame.open) orelse return false;
    return worded(for_words, emitter.tokens[held].text(emitter.source));
}

fn numeric_linked(emitter: *const Emitter, dot: u32) bool {
    assert(dot < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!walk.text_is(emitter.tokens[dot].text(emitter.source), "?.")) return false;

    const open = emit.ahead_of(emitter, dot) orelse return false;
    if (!emitter.tokens[open].is_punctuation(.bracket_open)) return false;

    const close = join.closing_of(emitter, open) orelse return false;
    return bind.numeric_lookup(emitter, open, close);
}

fn optional_call(emitter: *const Emitter, dot: u32) bool {
    assert(dot < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!walk.text_is(emitter.tokens[dot].text(emitter.source), "?.")) return false;

    const held = emit.ahead_of(emitter, dot) orelse return false;
    return emitter.tokens[held].is_punctuation(.paren_open);
}

fn chain_asserted(emitter: *const Emitter, dot: u32) bool {
    assert(dot < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const name = emit.ahead_of(emitter, dot) orelse return false;
    const bang = emit.ahead_of(emitter, name) orelse return false;
    if (!walk.text_is(emitter.tokens[bang].text(emitter.source), "!")) return false;
    if (emitter.tokens[name].end() != emitter.tokens[bang].offset) return false;

    const held = emit.ahead_of(emitter, bang) orelse return false;
    return emit.is_dot(emitter, held);
}

pub fn chain_commented(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head <= stop);
    assert(stop < emitter.count);

    var scan = head;

    while (scan <= stop) {
        const kind = emitter.tokens[scan].kind;
        if (kind == .comment) return true;

        if (walk.is_open(kind)) {
            scan = (join.closing_of(emitter, scan) orelse stop) + 1;
        } else {
            scan += 1;
        }
    }

    return false;
}

fn chain_called(emitter: *const Emitter, dot: u32) bool {
    assert(dot < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const name = emit.ahead_of(emitter, dot) orelse return false;
    const held = chain_call_open(emitter, name) orelse return false;

    return emitter.tokens[held].is_punctuation(.paren_open);
}

fn chain_call_open(emitter: *const Emitter, name: u32) ?u32 {
    assert(name < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const after = emit.ahead_of(emitter, name) orelse return null;
    var angles = wide.angle_count(emitter, after, '<') orelse return after;
    var scan = after;

    for (0..chain_scan_max) |_| {
        scan = emit.ahead_of(emitter, scan) orelse return null;

        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;

        if (opens) {
            scan = join.closing_of(emitter, scan) orelse return null;

            continue;
        }

        const closes = walk.is_close(kind) or kind == .block_end;
        if (closes) return null;

        if (wide.angle_count(emitter, scan, '<')) |run| {
            angles += run;

            continue;
        }

        const run = wide.angle_count(emitter, scan, '>') orelse continue;
        if (run >= angles) return emit.ahead_of(emitter, scan);

        angles -= run;
    }

    return null;
}

pub fn seated_frames(emitter: *const Emitter) u32 {
    assert(emitter.depth <= brace.nest_depth_max);

    const argued = arrow_argued(emitter);
    var count: u32 = 0;
    var held: u32 = 0;

    while (held < emitter.depth) : (held += 1) {
        const frame = emitter.nest[held];
        if (frame.spread == null) continue;
        if (frame.open < emitter.line_first) continue;
        if (seated_frames_hugged(emitter, frame)) continue;

        const last = argued and held + 1 == emitter.depth;

        count += @intFromBool(!last);
    }

    return count;
}

fn seated_frames_hugged(emitter: *const Emitter, frame: core.Frame) bool {
    if (frame.hugged == 0) return false;
    return lead.hug_whole(emitter, frame.hugged, frame.close);
}

pub fn arrow_argued(emitter: *const Emitter) bool {
    assert(emitter.wraps_owed <= core.wrap_depth_max);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.wraps_owed == 0) return false;
    if (emitter.depth == 0) return false;

    const close = emitter.wrapped[emitter.wraps_owed - 1].close;
    const frame = line.frame(emitter);
    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return false;

    const after = emit.ahead_of(emitter, close) orelse return false;
    if (after == frame.close) return true;
    if (!emitter.tokens[after].is_punctuation(.comma)) return false;
    return emit.ahead_of(emitter, after) == frame.close;
}

pub fn member_grouped(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (tmpl.holed(emitter)) return false;
    if (tmpl.template_piece(emitter, position)) return false;
    if (member_grouped_opened(emitter, position)) return false;

    const head = chain_start(emitter, position) orelse return false;
    const found = chain_stop(emitter, head) orelse return false;
    const stop = member_cast(emitter, head, found) orelse found;
    const first = member_trail(emitter, head, stop) orelse return false;
    const named = member_named(emitter, head);
    const casted = stop != found;
    const lefted = !casted and member_lefted(emitter, named, stop, position);

    if (position < first) return false;
    if (span.member_newed(emitter, head, position)) return false;
    if (lefted) return false;
    if (span.member_typed(emitter, head, position)) return false;
    if (!member_grouped_ended(emitter, named, first, stop)) return true;
    if (member_grouped_renewed(emitter, head, first, stop)) return true;
    return member_grouped_linked(emitter, head, first, stop);
}

fn member_grouped_opened(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const held = emit.ahead_of(emitter, position) orelse return false;
    return walk.is_open(emitter.tokens[held].kind);
}

fn member_grouped_ended(emitter: *const Emitter, named: ?u32, first: u32, stop: u32) bool {
    assert(first < emitter.count);
    assert(stop < emitter.count);

    if (named == null) return false;
    if (!member_grouped_closed(emitter, stop)) return false;
    return emit.ahead_of(emitter, first) == stop;
}

fn member_grouped_closed(emitter: *const Emitter, stop: u32) bool {
    assert(stop < emitter.count);

    const held = emit.ahead_of(emitter, stop) orelse return true;
    const kind = emitter.tokens[held].kind;
    if (kind.eql(.{ .punctuation = .comma })) return true;
    return kind.eql(.{ .punctuation = .semicolon });
}

fn member_grouped_renewed(emitter: *const Emitter, head: u32, first: u32, stop: u32) bool {
    assert(head <= stop);
    assert(stop < emitter.count);
    assert(first < emitter.count);

    const past = chain_newed(emitter, head, stop) orelse return false;

    assert(past > 0);

    return emit.back_of(emitter, first) == past - 1;
}

fn member_grouped_linked(emitter: *const Emitter, head: u32, first: u32, stop: u32) bool {
    assert(head <= stop);
    assert(stop < emitter.count);
    assert(first < emitter.count);

    const argued = member_grouped_argued(emitter, first);
    var links: [chain_link_max]u32 = @splat(0);
    const count = chain_groups(emitter, head, stop, &links);
    const merges = span.chain_merges(emitter, head, &links, count);

    if (argued) return false;
    return count < 2 + @as(u32, @intFromBool(merges));
}

fn member_grouped_argued(emitter: *const Emitter, first: u32) bool {
    assert(first < emitter.count);

    const held = member_grouped_bang(emitter, first) orelse return false;
    const open = emitter.brackets.open_of(held) orelse return false;
    if (!list.calling(emitter, open)) return false;
    return emit.ahead_of(emitter, open) != join.closing_of(emitter, open);
}

fn member_grouped_bang(emitter: *const Emitter, first: u32) ?u32 {
    assert(first < emitter.count);

    const held = emit.back_of(emitter, first) orelse return null;

    if (walk.text_is(emitter.tokens[held].text(emitter.source), "!")) {
        return emit.back_of(emitter, held);
    }

    return held;
}

pub fn member_named(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const back = emit.back_of(emitter, head) orelse return null;
    const newed = walk.text_is(emitter.tokens[back].text(emitter.source), "new");
    const held = if (newed) emit.back_of(emitter, back) orelse return null else back;
    if (emitter.tokens[held].is_punctuation(.assign)) return held;
    if (own.compound_assign(emitter, held)) return held;
    return null;
}

pub fn led_level(emitter: *const Emitter) u32 {
    assert(emitter.line_first < emitter.count);

    return line_led(emitter, emitter.line_first) orelse emitter.printed;
}

pub fn asserted_member(emitter: *const Emitter, bang: u32) bool {
    assert(bang < emitter.count);

    if (!walk.text_is(emitter.tokens[bang].text(emitter.source), "!")) return false;

    const name = emit.back_of(emitter, bang) orelse return false;
    if (emitter.tokens[name].kind != .identifier) return false;

    const dot = emit.back_of(emitter, name) orelse return false;
    if (!emit.is_dot(emitter, dot)) return false;
    return member_grouped(emitter, dot);
}

pub fn member_cast(emitter: *const Emitter, head: u32, stop: u32) ?u32 {
    assert(head <= stop);
    assert(stop < emitter.count);

    var depth: u32 = 0;
    var scan = head;

    while (scan <= stop) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (member_cast_word(emitter, scan, head, depth)) {
            return member_cast_plain(emitter, scan, stop);
        } else {}
    }

    return null;
}

fn member_cast_word(emitter: *const Emitter, scan: u32, head: u32, depth: u32) bool {
    assert(head <= scan);
    assert(scan < emitter.count);

    if (depth != 0) return false;
    if (scan == head) return false;
    if (!cast_text(emitter.tokens[scan].text(emitter.source))) return false;

    const held = emit.back_of(emitter, scan) orelse return true;
    return !emit.is_dot(emitter, held);
}

fn cast_text(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    if (walk.text_is(text, "as")) return true;
    return walk.text_is(text, "satisfies");
}

fn member_cast_plain(emitter: *const Emitter, scan: u32, stop: u32) ?u32 {
    assert(scan <= stop);
    assert(stop < emitter.count);

    if (!member_cast_braced(emitter, scan, stop)) {
        var at = scan;

        while (at <= stop) : (at += 1) {
            const token = emitter.tokens[at];
            if (token.kind == .block_start) return null;
            if (token.is_punctuation(.paren_open)) return null;

            const text = token.text(emitter.source);
            if (walk.text_is(text, "|")) return null;
            if (walk.text_is(text, "&")) return null;
            if (walk.text_is(text, "=>")) return null;
        }
    }

    return emit.back_of(emitter, scan);
}

fn member_cast_braced(emitter: *const Emitter, scan: u32, stop: u32) bool {
    assert(scan <= stop);
    assert(stop < emitter.count);

    const open = emit.ahead_of(emitter, scan) orelse return false;
    if (emitter.tokens[open].kind != .block_start) return false;
    return join.closing_of(emitter, open) == stop;
}

fn member_alone(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head <= stop);
    assert(stop < emitter.count);

    if (member_alone_unspread(emitter)) return false;
    if (emit.roled(emitter, head, brace.role_type)) return false;
    if (jsx.inside(emitter)) return false;

    var at = head;

    while (at <= stop) : (at += 1) {
        const text = emitter.tokens[at].text(emitter.source);
        if (walk.text_is(text, "as")) return false;
        if (walk.text_is(text, "satisfies")) return false;
    }

    return true;
}

fn member_alone_unspread(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return false;

    const frame = line.frame(emitter);
    if (!member_alone_listed(emitter, frame)) return false;
    return frame.spread == null;
}

fn member_alone_listed(emitter: *const Emitter, frame: core.Frame) bool {
    assert(frame.close == 0 or frame.close > frame.open);

    if (frame.kind == .block_start) return !frame.bodied;

    if (frame.kind.eql(.{ .punctuation = .paren_open })) {
        if (list.headed_loop(emitter, frame.open)) return false;
        if (list.calling(emitter, frame.open)) return true;
        if (split.headed(emitter, frame.open)) return true;
        return list.signature_paren(emitter, frame.open);
    }

    return walk.is_open(frame.kind);
}

pub fn chain_stop(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);

    const opened = walk.is_open(emitter.tokens[head].kind);
    var scan: u32 = head;
    if (opened) scan = join.closing_of(emitter, head) orelse return null;

    var stop = scan;

    for (0..chain_scan_max) |_| {
        const after = emit.ahead_of(emitter, scan) orelse break;
        const kind = emitter.tokens[after].kind;

        if (walk.is_open(kind)) {
            const close = join.closing_of(emitter, after) orelse return null;

            scan = close;
            stop = close;

            continue;
        }

        if (kind == .comment) {
            scan = after;

            continue;
        }

        if (!chain_stop_carried(emitter, after, scan, kind)) break;

        if (walk.text_is(emitter.tokens[after].text(emitter.source), "<")) {
            if (!emitter.policy.chain_simples) return null;

            const close = join.angle_close(emitter, after) orelse return null;

            scan = close;
            stop = close;

            continue;
        }

        scan = after;
        stop = after;
    }

    if (stop > head) return stop;
    return null;
}

fn chain_stop_carried(emitter: *const Emitter, after: u32, scan: u32, kind: Token.Kind) bool {
    assert(after < emitter.count);
    assert(scan < emitter.count);
    assert(kind != .comment);

    const text = emitter.tokens[after].text(emitter.source);

    if (chain_start_worded(kind)) {
        const stopped = worded(chain_stops, text);
        const membered = emit.is_dot(emitter, scan);

        if (!stopped) return true;
        if (membered) return true;
    }

    if (walk.text_is(text, "!")) return true;
    if (emit.is_dot(emitter, after)) return true;
    return walk.text_is(text, "<");
}

pub fn member_held(emitter: *const Emitter, colon: u32, bound: u32) bool {
    assert(colon < emitter.count);
    assert(bound <= emitter.count);

    const head = emit.ahead_of(emitter, colon) orelse return false;
    if (head >= bound) return false;

    const stop = chain_stop(emitter, head) orelse return false;
    if (!member_held_whole(emitter, stop, bound)) return false;
    if (!span.member_slight(emitter, head, stop)) return false;

    const first = member_trail(emitter, head, stop) orelse return false;
    return member_grouped(emitter, first);
}

fn member_held_whole(emitter: *const Emitter, stop: u32, bound: u32) bool {
    assert(stop < emitter.count);

    const after = emit.ahead_of(emitter, stop) orelse return true;
    if (after >= bound) return true;
    return emitter.tokens[after].is_punctuation(.comma);
}

fn member_chain_led(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.line_first < emitter.count);

    const first = emitter.line_first;

    if (emitter.indent == 0) return false;
    if (emitter.printed != emitter.indent) return false;
    if (!emit.is_dot(emitter, first)) return false;

    const head = chain_start(emitter, position) orelse return false;
    if (head >= first) return false;
    if (first >= position) return false;
    return chain_start(emitter, first) == head;
}

pub fn header_fits(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head < emitter.count);
    assert(stop <= emitter.count);

    if (emitter.depth == 0) return false;
    if (header_grouped_fits(emitter, head, stop)) return true;

    const frame = line.frame(emitter);
    const whole = header_fits_whole(emitter, frame, head, stop);
    const found = line.at(emitter, frame.open) orelse return false;

    if (!whole) return false;

    const level = line_led(emitter, frame.open) orelse return false;
    const end = header_fits_end(emitter, frame.close);
    const from = found.start - 1;

    const width = level * emitter.options.indent_width + span.printed_columns(emitter, from, end) +
        span.chain_widened(emitter, from, end);

    return width <= emitter.options.line_width;
}

fn header_fits_whole(emitter: *const Emitter, frame: core.Frame, head: u32, stop: u32) bool {
    assert(frame.open < emitter.count);
    assert(head < emitter.count);

    if (!split.headed(emitter, frame.open)) return false;
    if (emit.ahead_of(emitter, frame.open) != head) return false;
    return emit.back_of(emitter, frame.close) == stop;
}

fn header_fits_end(emitter: *const Emitter, close: u32) u32 {
    assert(close < emitter.count);

    const held = emit.ahead_of(emitter, close) orelse return close;

    assert(held > close);

    if (emitter.tokens[held].kind == .block_start) return held;
    return close;
}

fn header_grouped_fits(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head < emitter.count);
    assert(emitter.depth <= emitter.nest.len);

    if (emitter.depth < 2) return false;
    assert(stop <= emitter.count);

    const inner = line.frame(emitter);
    const outer = emitter.nest[emitter.depth - 2];
    const filled = header_grouped_filled(emitter, inner, outer, head, stop);
    const first = emit.ahead_of(emitter, outer.open) orelse return false;

    if (!filled) return false;

    const unary = header_grouped_unary(emitter, first, inner.open);
    const level = line_led(emitter, outer.open) orelse return false;

    if (!unary) return false;

    const width = (level + 1) * emitter.options.indent_width +
        span.printed_columns(emitter, first, inner.close);

    return width <= emitter.options.line_width;
}

fn header_grouped_filled(
    emitter: *const Emitter,
    inner: core.Frame,
    outer: core.Frame,
    head: u32,
    stop: u32,
) bool {
    assert(inner.open < emitter.count);
    assert(outer.open < inner.open);

    if (!inner.kind.eql(.{ .punctuation = .paren_open })) return false;
    if (inner.parted) return false;
    if (list.calling(emitter, inner.open)) return false;
    if (emit.ahead_of(emitter, inner.open) != head) return false;
    if (emit.back_of(emitter, inner.close) != stop) return false;
    if (!split.headed(emitter, outer.open)) return false;
    return emit.back_of(emitter, outer.close) == inner.close;
}

fn header_grouped_unary(emitter: *const Emitter, first: u32, open: u32) bool {
    assert(first < emitter.count);
    assert(open < emitter.count);

    var held = first;

    while (held < open) : (held += 1) {
        const text = emitter.tokens[held].text(emitter.source);
        if (!worded(header_unary_words, text)) return false;
    }

    return true;
}

pub fn led_argued(emitter: *const Emitter, seat: ?u32) ?u32 {
    assert(emitter.depth <= emitter.nest.len);
    if (seat) |held| assert(held < emitter.count);

    if (emitter.depth == 0) return null;

    const frame = line.frame(emitter);
    if (!led_argued_frame(emitter, frame, seat)) return null;

    const found = line.at(emitter, frame.open) orelse return null;
    if (!link_nested(emitter, found.start - 1, frame.open)) return null;

    const level = line_led(emitter, frame.open) orelse return null;
    assert(level + 1 < std.math.maxInt(u32));

    return level + 1;
}

fn led_argued_frame(emitter: *const Emitter, frame: core.Frame, seat: ?u32) bool {
    assert(frame.open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return false;
    if (frame.hugged != 0) return false;
    if (!list.calling(emitter, frame.open)) return false;
    if (seat) |held| assert(held < emitter.count);

    const held = seat orelse return false;
    if (held == frame.open) return true;
    return emitter.tokens[held].is_punctuation(.comma);
}

pub fn chain_suffixed(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head < emitter.count);
    assert(stop <= emitter.count);

    var scan = head;

    while (scan < stop) {
        assert(scan < emitter.count);

        const token = emitter.tokens[scan];
        const grouped = walk.is_open(token.kind) or token.kind == .block_start;

        if (grouped) {
            const close = join.closing_of(emitter, scan) orelse return false;

            assert(close > scan);
            scan = close + 1;

            continue;
        }

        if (chain_suffixed_trailing(emitter, scan)) return true;

        scan += 1;
    }

    return false;
}

fn chain_suffixed_trailing(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);

    const token = emitter.tokens[scan];
    if (token.kind != .comment) return false;
    if (!std.mem.startsWith(u8, token.text(emitter.source), "/*")) return false;

    const held = emit.back_of(emitter, scan) orelse return false;

    assert(held < scan);

    if (body.parts_at(emitter, held, scan)) return false;

    const coded = line.coding(emitter, scan) orelse return false;
    return emit.is_dot(emitter, coded);
}

pub fn chain_seated_at(emitter: *const Emitter, head: u32) u32 {
    assert(head < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const held = emit.back_of(emitter, head) orelse return head;

    assert(held < head);

    if (walk.text_is(emitter.tokens[held].text(emitter.source), "new")) return held;
    return head;
}

pub fn chain_branch_head(emitter: *const Emitter, head: u32) u32 {
    assert(head < emitter.count);

    const seated = chain_seated_at(emitter, head);

    assert(seated <= head);

    const held = emit.back_of(emitter, seated) orelse return seated;
    if (walk.text_is(emitter.tokens[held].text(emitter.source), "await")) return held;
    return seated;
}

pub fn chain_seat(emitter: *const Emitter, head: u32, from: u32, level: u32) struct { u32, u32 } {
    assert(head < emitter.count);
    assert(from < emitter.count);
    assert(level < std.math.maxInt(u32));

    const found = span.member_seated(emitter, head, from, level) orelse return .{ from, level };
    return .{ found[0], found[1] };
}

pub fn member_overflows(
    emitter: *const Emitter,
    head: u32,
    dot: u32,
    stop: u32,
    direct: bool,
) bool {
    assert(head < emitter.count);
    assert(dot < emitter.count);
    assert(stop < emitter.count);

    const seat = member_overflows_lead(emitter, head);
    var from = seat[0];
    var level = seat[1];

    if (from > head) return false;

    if (from == emitter.line_first) level = @max(level, led_level(emitter));

    const end = member_end(emitter, head, stop);

    if (span.member_seated(emitter, head, from, level)) |seated| {
        from = seated[0];
        level = seated[1];
    }

    const room = emitter.options.line_width;
    const widened = span.chain_widened(emitter, head, stop);
    const object = emit.back_of(emitter, dot) orelse return false;

    if (direct) return member_width(emitter, level, from, end) + widened > room;

    if (member_width(emitter, level, from, object) + widened <= room) {
        if (member_width(emitter, level, from, end) + widened <= room) return false;

        if (member_hugged(emitter, head, object)) |closed| {
            return member_width(emitter, level, closed, end) + widened > room;
        }

        return true;
    }

    if (member_closed(emitter, head, object)) |closed| {
        return member_width(emitter, level, closed, end) + widened > room;
    }

    return member_width(emitter, level + 1, head, end) + widened > room;
}

fn member_overflows_lead(emitter: *const Emitter, head: u32) struct { u32, u32 } {
    assert(head < emitter.count);
    assert(emitter.line_first < emitter.count);

    if (span.binary_seated(emitter, head)) {
        return .{ chain_seated_at(emitter, head), emitter.printed + 1 };
    }

    if (lead.spread(emitter, head)) |found| return .{ found[0], found[1] };
    if (member_key_seat(emitter, head)) |found| return .{ found[0], found[1] };
    if (lead.spread_item(emitter, head)) |found| return .{ found[0], found[1] };
    if (join.line_lead(emitter, head)) |found| return .{ found[0], found[1] };
    return .{ emitter.line_first, emitter.printed };
}

fn member_width(emitter: *const Emitter, level: u32, from: u32, to: u32) u32 {
    assert(from < emitter.count);
    assert(to < emitter.count);
    assert(level < std.math.maxInt(u32));

    return level * emitter.options.indent_width + span.printed_columns(emitter, from, to);
}

fn member_end(emitter: *const Emitter, head: u32, stop: u32) u32 {
    assert(head < emitter.count);
    assert(stop < emitter.count);

    if (emit.ahead_of(emitter, stop)) |held| {
        const token = emitter.tokens[held];
        if (token.is_punctuation(.comma)) return held;
        if (token.is_punctuation(.semicolon)) return held;
    }

    return member_keyed(emitter, head, stop) orelse stop;
}

pub fn member_early(emitter: *const Emitter, head: u32, trimmed: u32, dot: u32) bool {
    assert(head < emitter.count);
    assert(dot < emitter.count);
    assert(trimmed < std.math.maxInt(u32));

    var scan = head;

    while (scan < trimmed) {
        const held = emit.ahead_of(emitter, scan) orelse return false;

        assert(held > scan);

        const token = emitter.tokens[held];

        const plain = token.kind == .identifier or emit.is_dot(emitter, held) or
            walk.text_is(token.text(emitter.source), "!");

        if (!plain) return false;

        scan = held;
    }

    const name = emit.ahead_of(emitter, dot) orelse return false;
    return emitter.tokens[name].kind == .identifier;
}

pub fn member_early_led(emitter: *const Emitter, head: u32, dot: u32) bool {
    assert(head < emitter.count);
    assert(dot < emitter.count);

    if (emitter.line_first <= head) return false;
    if (emitter.line_first >= dot) return false;
    return emit.is_dot(emitter, emitter.line_first);
}

pub fn member_early_overflows(emitter: *const Emitter, head: u32, dot: u32, direct: bool) bool {
    assert(head < emitter.count);
    assert(dot < emitter.count);

    const name = emit.ahead_of(emitter, dot) orelse return false;
    if (member_early_led(emitter, head, dot)) return member_led_overflows(emitter, head, name);
    return member_overflows(emitter, head, dot, name, direct);
}

pub fn member_led_overflows(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head < emitter.count);
    assert(stop < emitter.count);

    const end = member_end(emitter, head, stop);

    const width = emitter.printed * emitter.options.indent_width +
        span.printed_columns(emitter, emitter.line_first, end);

    return width > emitter.options.line_width;
}

pub fn member_keyed(emitter: *const Emitter, head: u32, stop: u32) ?u32 {
    assert(head < emitter.count);
    assert(stop < emitter.count);

    const open = emit.back_of(emitter, head) orelse return null;
    if (!emitter.tokens[open].is_punctuation(.bracket_open)) return null;

    const close = emit.ahead_of(emitter, stop) orelse return null;
    if (emitter.brackets.close_of(open) != close) return null;

    const held = emit.ahead_of(emitter, close) orelse return null;
    if (emitter.tokens[held].is_punctuation(.colon)) return held;
    return null;
}

fn member_key_seat(emitter: *const Emitter, head: u32) ?struct { u32, u32 } {
    assert(head < emitter.count);
    assert(emitter.depth <= emitter.nest.len);

    if (emitter.depth < 2) return null;

    const stop = chain_stop(emitter, head) orelse return null;

    _ = member_keyed(emitter, head, stop) orelse return null;

    const open = emit.back_of(emitter, head) orelse return null;
    const found = lead.spread_item_seat_in(emitter, emitter.depth - 2, open) orelse return null;

    return .{ found[0], found[1] };
}

fn member_hugged(emitter: *const Emitter, head: u32, object: u32) ?u32 {
    assert(head < emitter.count);
    assert(object < emitter.count);

    const closed = member_closed(emitter, head, object) orelse return null;
    const open = emitter.brackets.open_of(closed) orelse return null;

    _ = span.spread_hugging(emitter, open, closed) orelse return null;

    return closed;
}

fn member_closed(emitter: *const Emitter, head: u32, object: u32) ?u32 {
    assert(head < emitter.count);
    assert(object < emitter.count);

    var closed: ?u32 = null;
    var scan = head;

    while (scan <= object) : (scan += 1) {
        if (!walk.is_close(emitter.tokens[scan].kind)) continue;

        const open = emitter.brackets.open_of(scan) orelse continue;
        if (open < head) continue;
        if (open + 1 == scan) continue;

        closed = scan;
    }

    return closed;
}

pub fn chain_listed_last(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head < emitter.count);
    assert(emitter.depth <= emitter.nest.len);
    assert(stop <= emitter.count);

    var depth = emitter.depth;

    while (depth > 0) : (depth -= 1) {
        const frame = &emitter.nest[depth - 1];

        if (frame.open < head) {
            const listed = chain_listed_last_listed(frame);
            const after = chain_listed_last_after(emitter, stop);

            if (!listed) return false;
            return after == frame.close;
        }
    }

    return false;
}

fn chain_listed_last_listed(frame: *const core.Frame) bool {
    const spread = frame.spread orelse return false;
    if (spread != .members) return false;
    if (frame.kind.eql(.{ .punctuation = .paren_open })) return true;
    if (frame.kind.eql(.{ .punctuation = .bracket_open })) return true;
    return frame.kind == .block_start;
}

fn chain_listed_last_after(emitter: *const Emitter, stop: u32) ?u32 {
    assert(stop < emitter.count);

    const held = emit.ahead_of(emitter, stop) orelse return null;

    assert(held > stop);

    if (emitter.tokens[held].is_punctuation(.comma)) {
        return emit.ahead_of(emitter, held) orelse held;
    }

    return held;
}

pub fn member_last(emitter: *const Emitter, head: u32, stop: u32) u32 {
    assert(head < emitter.count);
    assert(stop < emitter.count);

    var depth: u32 = 0;
    var found = head;
    var scan = head;

    while (scan <= stop) {
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
            if (emit.is_dot(emitter, scan)) found = scan;
        } else {}

        scan += 1;
    }

    assert(found <= stop);

    return found;
}
