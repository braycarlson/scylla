const std = @import("std");
const assert = std.debug.assert;
const brace = @import("../brace.zig");
const core = @import("emitter.zig");
const emit = @import("emit.zig");
const join = @import("join.zig");
const lead = @import("lead.zig");
const line = @import("line.zig");
const walk = @import("../walk.zig");
const Emitter = core.Emitter;
const brace_extends: []const u8 = "()]}?>";
const brace_gap_width: u32 = 2;

pub fn arrow_split(emitter: *const Emitter, position: u32, previous: u32) ?bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (emitter.policy.define_words.len == 0) return null;
    if (!walk.text_is(emitter.tokens[position].text(emitter.source), "->")) return null;
    if (!emitter.tokens[previous].is_punctuation(.paren_close)) return null;

    const open = emitter.brackets.open_of(previous) orelse return null;
    const head = join.body_signature(emitter, previous) orelse return null;
    const end = arrow_end(emitter, position) orelse return null;

    assert(head < open);
    assert(end >= position);

    if (end == position) return null;
    if (head < emitter.line_first) return null;
    if (!arrow_params(emitter, head, open)) return null;

    const lined = join.header_width(emitter, emitter.line_first, previous) orelse return null;
    const arrowed = join.header_width(emitter, position, end) orelse return null;
    const under = emitter.printed * emitter.options.indent_width;
    const width = emitter.options.line_width;

    if (emit.ahead_of(emitter, open) == previous) {
        const first = arrow_first(emitter, position, end, under + arrowed) orelse return null;
        return under + lined + first > width;
    }

    const after = emit.ahead_of(emitter, end) orelse return null;
    const claused = walk.text_is(emitter.tokens[after].text(emitter.source), "where");
    const braced: u32 = if (claused) 0 else 2;
    if (under + lined + arrowed + braced + 1 > width) return null;
    return false;
}

pub fn arrow_params(emitter: *const Emitter, head: u32, open: u32) bool {
    assert(head < open);
    assert(open < emitter.count);

    const name = emit.ahead_of(emitter, head) orelse return false;
    const after = emit.ahead_of(emitter, name) orelse return false;

    if (emitter.tokens[name].kind != .identifier) return false;
    if (after == open) return true;
    if (!walk.text_is(emitter.tokens[after].text(emitter.source), "<")) return false;

    const close = join.angle_close(emitter, after) orelse return false;
    return emit.ahead_of(emitter, close) == open;
}

pub fn params_framed(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.list_blanks) return false;
    if (emitter.depth == 0) return false;

    const frame = emitter.nest[emitter.depth - 1];
    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return false;
    return params_blanked(emitter, frame.open);
}

pub fn params_blanked(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (emitter.policy.define_words.len == 0) return false;

    const head = join.body_signature(emitter, open) orelse return false;
    if (head >= open) return false;
    return arrow_params(emitter, head, open);
}

fn arrow_first(emitter: *const Emitter, arrow: u32, end: u32, seated: u32) ?u32 {
    assert(arrow < end);
    assert(end < emitter.count);

    const flat = join.header_width(emitter, arrow, end) orelse return null;
    var lined = seated <= emitter.options.line_width;
    var first: ?u32 = null;
    var scan = arrow;

    for (0..join.define_scan_max) |_| {
        const next = emit.ahead_of(emitter, scan) orelse return null;
        const token = emitter.tokens[next];
        const opened = walk.is_open(token.kind) or walk.text_is(token.text(emitter.source), "<");

        if (next > end) break;

        if (opened) {
            if (first == null) first = join.header_width(emitter, arrow, next) orelse return null;
        }

        if (token.is_punctuation(.paren_open)) {
            if (arrow_wide(emitter, next)) lined = false;
        }

        scan = next;
    } else return null;

    if (lined) return flat;
    return first orelse flat;
}

fn arrow_wide(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const close = emitter.brackets.close_of(open) orelse return false;
    const first = emit.ahead_of(emitter, open) orelse return false;
    const last = emit.back_of(emitter, close) orelse return false;
    if (first > last) return false;

    const inner = join.header_width(emitter, first, last) orelse return false;
    return inner > emitter.policy.call_width;
}

fn arrow_end(emitter: *const Emitter, arrow: u32) ?u32 {
    assert(arrow < emitter.count);

    var depth: u32 = 0;
    var last = arrow;
    var scan = arrow;

    for (0..join.define_scan_max) |_| {
        const next = emit.ahead_of(emitter, scan) orelse return null;
        const token = emitter.tokens[next];
        if (token.kind == .comment) return null;

        if (depth == 0) {
            if (token.kind == .block_start) return last;
            if (token.is_punctuation(.semicolon)) return last;
            if (walk.text_is(token.text(emitter.source), "where")) return last;
        }

        if (walk.is_open(token.kind)) {
            depth += 1;
        } else if (walk.is_close(token.kind)) {
            if (depth == 0) return null;

            depth -= 1;
        } else {}

        last = next;
        scan = next;
    }

    return null;
}

pub fn brace_broken(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.line_first < emitter.count);

    if (brace_parted(emitter, position, emitter.line_first) != null) return true;
    return brace_overflowed(emitter, position, emitter.line_first, emitter.printed);
}

pub fn brace_joined(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.line_first < emitter.count);

    if (!emitter.policy.header_joins) return false;
    if (emitter.tokens[position].kind != .block_start) return false;

    const previous = line.coded(emitter) orelse return false;
    const head = join.header_head(emitter, previous) orelse return false;
    if (join.header_brace(emitter, head) != position) return false;
    if (head >= emitter.line_first) return false;
    if (!brace_extended(emitter, emitter.line_first, previous)) return false;
    if (walk.text_is(emitter.tokens[head].text(emitter.source), "match")) return true;

    const level = lead.leveled_at(emitter, head) orelse return false;
    return emitter.printed <= level;
}

fn brace_extended(emitter: *const Emitter, leading: u32, previous: u32) bool {
    assert(leading < emitter.count);
    assert(previous < emitter.count);

    var scan = leading;

    for (0..join.define_scan_max) |_| {
        const text = emitter.tokens[scan].text(emitter.source);

        for (text) |byte| {
            if (std.mem.findScalar(u8, brace_extends, byte) == null) return false;
        }

        if (scan >= previous) return true;

        scan = emit.ahead_of(emitter, scan) orelse return true;
    }

    return false;
}

pub fn brace_level(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.line_before < emitter.count);

    if (brace_parted(emitter, position, emitter.line_before)) |head| {
        assert(head < emitter.line_before);

        return lead.leveled_at(emitter, head);
    }

    const level = lead.leveled_at(emitter, emitter.line_before) orelse return null;
    if (!brace_overflowed(emitter, position, emitter.line_before, level)) return null;
    return level;
}

fn brace_overflowed(emitter: *const Emitter, position: u32, leading: u32, level: u32) bool {
    assert(position < emitter.count);
    assert(leading < emitter.count);

    if (!emitter.policy.header_joins) return false;
    if (emitter.tokens[position].kind != .block_start) return false;
    assert(level < std.math.maxInt(u32));

    const previous = line.coded(emitter) orelse return false;
    const head = join.header_head(emitter, previous) orelse return false;
    if (join.header_brace(emitter, head) != position) return false;
    if (head < leading) return false;
    if (std.mem.endsWith(u8, emitter.tokens[previous].text(emitter.source), "\"#")) return false;

    const header = join.header_width(emitter, leading, previous) orelse return false;
    const under = level * emitter.options.indent_width;
    const width = emitter.options.line_width;

    assert(previous < position);

    return under + header <= width and under + header + brace_gap_width > width;
}

fn brace_parted(emitter: *const Emitter, position: u32, leading: u32) ?u32 {
    assert(position < emitter.count);
    assert(leading < emitter.count);

    if (!emitter.policy.header_joins) return null;
    if (emitter.tokens[position].kind != .block_start) return null;

    const previous = line.coded(emitter) orelse return null;
    const head = join.header_head(emitter, previous) orelse return null;
    if (join.header_brace(emitter, head) != position) return null;
    if (brace_extended(emitter, leading, previous)) return null;
    if (head >= leading) return null;
    return head;
}
