const std = @import("std");
const assert = std.debug.assert;
const brace = @import("../brace.zig");
const core = @import("emitter.zig");
const emit = @import("emit.zig");
const join = @import("join.zig");
const lead = @import("lead.zig");
const line = @import("line.zig");
const link = @import("link.zig");
const span = @import("span.zig");
const walk = @import("../walk.zig");
const Emitter = core.Emitter;

const Heritage = struct {
    extends: ?u32,
    head: u32,
    implements: ?u32,
    interface: bool,
    keyword: u32,
    open: u32,
};

const heritage_scan_max: u32 = 256;

fn heritage_of(emitter: *const Emitter, position: u32) ?Heritage {
    assert(position < emitter.count);

    const token = emitter.tokens[position];
    const text = token.text(emitter.source);
    const opens = token.kind == .block_start;
    const listed = heritage_of_listed(emitter, position);
    const named = walk.text_is(text, "extends") or walk.text_is(text, "implements");
    const qualifies = opens or listed or named;
    if (!qualifies) return null;

    var scan = if (opens) emit.back_of(emitter, position) orelse return null else position;

    assert(scan < emitter.count);

    var depth: u32 = 0;
    var word: ?struct { u32, bool } = null;

    for (0..heritage_scan_max) |_| {
        const kind = emitter.tokens[scan].kind;
        const closes = brace.is_close(kind) or kind == .block_end;
        const opened = brace.is_open(kind) or kind == .block_start;

        if (closes) {
            depth += 1;
        } else if (opened) {
            if (depth == 0) return null;

            depth -= 1;
        } else if (depth == 0) {
            const held = emitter.tokens[scan].text(emitter.source);
            const classy = walk.text_is(held, "class");
            const interfaced = walk.text_is(held, "interface");
            const worded = classy or interfaced;

            if (worded) {
                word = .{ scan, interfaced };

                break;
            }

            if (emitter.tokens[scan].is_punctuation(.semicolon)) return null;
        } else {}

        scan = emit.back_of(emitter, scan) orelse return null;
    }

    const keyword, const interface = word orelse return null;
    const held = heritage_clauses(emitter, keyword, interface) orelse return null;
    const extends_matched = if (held.extends) |found| found == position else false;
    const implements_matched = if (held.implements) |found| found == position else false;

    const matched = position == held.open or extends_matched or implements_matched or
        heritage_led(emitter, &held, position) or heritage_item(emitter, &held, position);

    if (!matched) return null;
    return held;
}

fn heritage_of_listed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (emitter.tokens[position].kind != .identifier) return false;

    const held = emit.back_of(emitter, position) orelse return false;

    assert(held < emitter.count);

    const comma = emitter.tokens[held].is_punctuation(.comma);
    const text = emitter.tokens[held].text(emitter.source);
    const keyword = walk.text_is(text, "implements") or walk.text_is(text, "extends");

    return comma or keyword;
}

fn heritage_item(emitter: *const Emitter, held: *const Heritage, position: u32) bool {
    assert(position < emitter.count);
    assert(held.open < emitter.count);

    const clause = if (held.interface) held.extends else held.implements;
    const start = clause orelse return false;
    if (position <= start) return false;
    if (position >= held.open) return false;

    var depth: u32 = 0;
    var nested: u32 = 0;
    var scan = start;

    for (0..heritage_scan_max) |_| {
        const ahead = emit.ahead_of(emitter, scan) orelse break;
        if (ahead >= position) break;

        const kind = emitter.tokens[ahead].kind;
        const text = emitter.tokens[ahead].text(emitter.source);
        const opens = brace.is_open(kind) or kind == .block_start;
        const closes = brace.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth = depth -| 1;
        } else if (depth == 0) {
            if (walk.text_is(text, "<")) nested += 1;
            if (walk.text_is(text, ">")) nested = nested -| 1;
        } else {}

        scan = ahead;
    }

    if (depth > 0) return false;
    if (nested > 0) return false;
    if (scan == start) return !held.interface;
    return emitter.tokens[scan].is_punctuation(.comma);
}

fn heritage_led(emitter: *const Emitter, held: *const Heritage, position: u32) bool {
    assert(position < emitter.count);
    assert(held.open < emitter.count);

    const before = emit.back_of(emitter, position) orelse return false;
    const extends = held.extends orelse return false;

    return extends == before;
}

fn heritage_clauses(emitter: *const Emitter, keyword: u32, interface: bool) ?Heritage {
    assert(keyword < emitter.count);

    var scan = keyword;
    var nested: u32 = 0;
    var depth: u32 = 0;
    var extends: ?u32 = null;
    var implements: ?u32 = null;

    for (0..heritage_scan_max) |_| {
        scan = emit.ahead_of(emitter, scan) orelse return null;

        assert(scan < emitter.count);

        const kind = emitter.tokens[scan].kind;
        const angled = nested > 0;
        const opens = brace.is_open(kind) or kind == .block_start;
        const closes = brace.is_close(kind) or kind == .block_end;

        if (opens) {
            const heads = depth == 0 and kind == .block_start and !angled;

            if (heads) {
                return .{
                    .extends = extends,
                    .head = heritage_head(emitter, keyword),
                    .implements = implements,
                    .interface = interface,
                    .keyword = keyword,
                    .open = scan,
                };
            }

            depth += 1;
        } else if (closes) {
            if (depth == 0) return null;

            depth -= 1;
        } else if (depth == 0) {
            const text = emitter.tokens[scan].text(emitter.source);

            if (walk.text_is(text, "<")) {
                nested += 1;

                continue;
            }

            if (walk.text_is(text, ">")) {
                nested = nested -| 1;

                continue;
            }

            if (angled) continue;

            if (walk.text_is(text, "extends")) {
                extends = scan;
            } else if (walk.text_is(text, "implements")) {
                implements = scan;
            } else if (emitter.tokens[scan].is_punctuation(.semicolon)) {
                return null;
            } else {}
        } else {}
    }

    return null;
}

fn heritage_split(emitter: *const Emitter, position: u32) ?bool {
    assert(position < emitter.count);

    if (!emitter.policy.heritage_parts) return null;

    const held = heritage_of(emitter, position) orelse return null;

    assert(held.open < emitter.count);

    const grouped = if (held.interface) held.extends != null else held.implements != null;
    if (!grouped) return false;
    if (heritage_led(emitter, &held, position)) return false;

    if (position == held.open) {
        const close = emit.closing(emitter, held.open);
        const filled = if (close) |found| emit.ahead_of(emitter, held.open) != found else false;
        const splits = !held.interface and filled and heritage_wide(emitter, &held);

        return splits;
    }

    if (!held.interface) {
        if (heritage_item(emitter, &held, position)) return heritage_listed(emitter, &held);
    }

    if (heritage_angled(emitter, &held, position)) return false;
    return heritage_wide(emitter, &held);
}

fn heritage_angled(emitter: *const Emitter, held: *const Heritage, position: u32) bool {
    assert(position < emitter.count);
    assert(held.head < emitter.count);

    const clause = heritage_angled_clause(held);
    const matched = if (clause) |found| found == position else false;
    if (!matched) return false;

    const name = emit.ahead_of(emitter, held.keyword) orelse return false;
    const open = emit.ahead_of(emitter, name) orelse return false;
    if (!walk.text_is(emitter.tokens[open].text(emitter.source), "<")) return false;

    const close = join.angle_close(emitter, open) orelse return false;
    const ahead = emit.ahead_of(emitter, close) orelse return false;
    if (ahead != position) return false;

    const level = line.level_at(emitter, held.head) orelse emitter.levels;
    const width = span.printed_columns(emitter, held.head, close);

    return level * emitter.options.indent_width + width > emitter.options.line_width;
}

fn heritage_angled_clause(held: *const Heritage) ?u32 {
    if (held.interface) return held.extends;
    if (held.extends == null) return held.implements;
    return null;
}

pub fn broken(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const split = heritage_split(emitter, position) orelse return false;
    return split;
}

pub fn joined(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const split = heritage_split(emitter, position) orelse return false;
    return !split;
}

pub fn bodied(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (!emitter.policy.heritage_parts) return false;
    if (emitter.tokens[position].kind != .block_start) return false;

    const held = heritage_of(emitter, position) orelse return false;

    assert(held.open < emitter.count);

    const grouped = if (held.interface) held.extends != null else held.implements != null;
    const opened = held.open == position;
    if (!opened) return false;
    if (!grouped) return false;
    return heritage_wide(emitter, &held);
}

pub fn level_at(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    if (!emitter.policy.heritage_parts) return null;

    const held = heritage_of(emitter, position) orelse return null;

    assert(held.head < emitter.count);

    const missing_extends = held.interface and held.extends == null;
    const missing_implements = !held.interface and held.implements == null;

    if (missing_extends) return null;
    if (missing_implements) return null;

    const level = line.level_at(emitter, held.head) orelse emitter.levels;
    if (position == held.open) return level;

    if (heritage_item(emitter, &held, position)) {
        assert(level + 2 < std.math.maxInt(u32));

        return level + 2;
    }

    assert(level + 1 < std.math.maxInt(u32));

    return level + 1;
}

pub fn both(emitter: *const Emitter, keyword: u32) bool {
    assert(keyword < emitter.count);

    const held = heritage_clauses(emitter, keyword, false) orelse return false;

    assert(held.keyword == keyword);

    return held.extends != null and held.implements != null;
}

fn heritage_head(emitter: *const Emitter, keyword: u32) u32 {
    assert(keyword < emitter.count);

    if (span.line_opened(emitter, keyword)) |head| return head;

    var head = keyword;

    for (0..heritage_scan_max) |_| {
        const before = emit.back_of(emitter, head) orelse break;
        const kind = emitter.tokens[before].kind;
        const closes_colon = kind.eql(.{ .punctuation = .colon });
        const closes_comma = kind.eql(.{ .punctuation = .comma });
        const closes_semicolon = kind.eql(.{ .punctuation = .semicolon });

        const stops = brace.is_open(kind) or brace.is_close(kind) or kind == .comment or
            closes_colon or closes_comma or closes_semicolon;

        if (stops) break;

        head = before;
    }

    assert(head <= keyword);

    return head;
}

fn heritage_wrapped(emitter: *const Emitter, held: *const Heritage) u32 {
    assert(held.keyword < emitter.count);

    if (!line.word_is(emitter, held.keyword, emitter.policy.declaration_words)) return 0;

    const word = emit.back_of(emitter, held.keyword) orelse return 0;

    assert(word < emitter.count);

    return @intFromBool(line.word_is(emitter, word, emitter.policy.construct_words));
}

fn heritage_listed(emitter: *const Emitter, held: *const Heritage) bool {
    assert(held.open < emitter.count);
    assert(emitter.options.indent_width > 0);

    if (held.interface) return false;

    const start = held.implements orelse return false;

    assert(start < held.open);

    const end = emit.back_of(emitter, held.open) orelse return false;
    const level = (line.level_at(emitter, held.head) orelse emitter.levels) + 1;
    const width = level * emitter.options.indent_width + span.printed_columns(emitter, start, end);

    return width > emitter.options.line_width;
}

fn heritage_wide(emitter: *const Emitter, held: *const Heritage) bool {
    assert(held.open < emitter.count);
    assert(held.head < emitter.count);
    assert(emitter.options.indent_width > 0);

    const base = if (lead.spread(emitter, held.keyword)) |found|
        found
    else blk: {
        const level = link.line_led(emitter, held.head) orelse emitter.levels;

        break :blk .{ held.head, level };
    };

    const from, const level = base;
    const close = emit.closing(emitter, held.open);
    const emptied = if (close) |found| emit.ahead_of(emitter, held.open) == found else false;

    const width = span.printed_columns(emitter, from, held.open) + heritage_wrapped(emitter, held) +
        @intFromBool(emptied);

    return level * emitter.options.indent_width + width > emitter.options.line_width;
}
