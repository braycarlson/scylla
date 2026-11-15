const std = @import("std");
const assert = std.debug.assert;
const Span = @import("../../stdx/bounded/span.zig");
const Token = @import("../../syntax/token.zig");
const bodied = @import("../text.zig").bodied;
const body = @import("body.zig");
const brace = @import("../brace.zig");
const commenting = @import("comment.zig");
const core = @import("emitter.zig");
const emit = @import("emit.zig");
const line = @import("line.zig");
const named_key = @import("../text.zig").named_key;
const numbered_key = @import("../text.zig").numbered_key;
const semi = @import("semi.zig");
const tern = @import("tern.zig");
const walk = @import("../walk.zig");
const wrap = @import("wrap.zig");
const Emitter = core.Emitter;

const modifier_order: [9][]const u8 = .{
    "private",
    "protected",
    "public",
    "declare",
    "static",
    "abstract",
    "override",
    "readonly",
    "accessor",
};

const key_modifier_max: u32 = 4;

const key_modifiers: [9][]const u8 = .{
    "abstract",
    "accessor",
    "declare",
    "override",
    "private",
    "protected",
    "public",
    "readonly",
    "static",
};

pub fn remodifying(emitter: *const Emitter, position: u32) ?Span {
    assert(position < emitter.count);

    if (emitter.policy.type_words.len == 0) return null;
    if (remodifying_rank(emitter, position) == null) return null;

    var run: [modifier_order.len]u32 = @splat(0);
    const start = remodifying_start(emitter, position);
    const run_count = remodifying_run(emitter, start, &run) orelse return null;

    assert(run_count > 0);
    assert(run_count <= run.len);

    const named = remodifying_named(emitter, run[run_count - 1]);

    if (run_count < 2) return null;
    if (!named) return null;

    const slot = remodifying_slot(run[0..run_count], position) orelse return null;
    var sorted = run;

    std.sort.insertion(u32, sorted[0..run_count], emitter, remodifying_less);

    if (sorted[slot] == position) return null;

    const chosen = emitter.tokens[sorted[slot]];
    return .{ .offset = chosen.offset, .length = chosen.length };
}

fn remodifying_rank(emitter: *const Emitter, at: u32) ?u32 {
    assert(at < emitter.count);

    const text = emitter.tokens[at].text(emitter.source);

    for (modifier_order, 0..) |word, index| {
        if (walk.text_eql(word, text)) {
            assert(index < modifier_order.len);

            return @intCast(index);
        }
    }

    return null;
}

fn remodifying_key(emitter: *const Emitter, at: u32) u32 {
    assert(at < emitter.count);

    const rank = remodifying_rank(emitter, at) orelse return 0;

    assert(rank < modifier_order.len);

    return rank + 1;
}

fn remodifying_less(emitter: *const Emitter, left: u32, right: u32) bool {
    assert(left < emitter.count);
    assert(right < emitter.count);

    return remodifying_key(emitter, left) < remodifying_key(emitter, right);
}

fn remodifying_start(emitter: *const Emitter, position: u32) u32 {
    assert(position < emitter.count);

    var start = position;

    for (0..modifier_order.len) |_| {
        const held = emit.back_of(emitter, start) orelse break;
        if (remodifying_rank(emitter, held) == null) break;

        assert(held < start);

        start = held;
    }

    return start;
}

fn remodifying_run(emitter: *const Emitter, start: u32, run: *[modifier_order.len]u32) ?u32 {
    assert(start < emitter.count);

    var filled: u32 = 0;
    var scan = start;

    while (filled < run.len) {
        if (emitter.tokens[scan].kind == .comment) return null;

        run[filled] = scan;
        filled += 1;

        const held = emit.ahead_of(emitter, scan) orelse return filled;
        if (remodifying_rank(emitter, held) == null) return filled;

        assert(held > scan);

        scan = held;
    }

    return null;
}

fn remodifying_named(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);

    const held = emit.ahead_of(emitter, scan) orelse return false;
    const kind = emitter.tokens[held].kind;

    assert(held > scan);

    if (kind == .identifier) return true;
    if (kind == .keyword) return true;
    if (kind == .string) return true;
    return kind.eql(.{ .punctuation = .bracket_open });
}

fn remodifying_slot(run: []const u32, position: u32) ?u32 {
    assert(run.len > 0);
    assert(run.len <= modifier_order.len);

    for (run, 0..) |held, index| {
        if (held == position) {
            assert(index < run.len);

            return @intCast(index);
        }
    }

    return null;
}

pub fn unquoting(emitter: *const Emitter, position: u32) ?Span {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.key_quotes) return null;

    const token = emitter.tokens[position];
    if (token.kind != .string) return null;

    const spelling = token.text(emitter.source);
    const held = bodied(spelling) orelse return null;
    if (!unquoting_named(emitter, held)) return null;
    if (unquoting_excluded(emitter, held)) return null;
    if (!unquoting_opens(emitter, position)) return null;
    if (!keyed(emitter, position)) return null;

    assert(token.length >= 2);

    return .{ .length = token.length - 2, .offset = token.offset + 1 };
}

fn unquoting_named(emitter: *const Emitter, held: []const u8) bool {
    if (named_key(held)) return true;
    if (!emitter.policy.key_numbers) return false;
    return numbered_key(held);
}

fn unquoting_excluded(emitter: *const Emitter, held: []const u8) bool {
    assert(held.len <= std.math.maxInt(u32));

    for (emitter.policy.key_words) |word| {
        if (walk.text_eql(word, held)) return true;
    }

    return false;
}

fn unquoting_opens(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    var lead = commenting.back(emitter, position);

    for (0..key_modifier_max) |_| {
        const held = lead orelse break;
        if (!unquoting_modifier(emitter, held)) break;

        lead = commenting.back(emitter, held);
    }

    const held = lead orelse return false;
    return unquoting_boundary(emitter, held);
}

fn unquoting_modifier(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const spelling = emitter.tokens[position].text(emitter.source);

    for (key_modifiers) |word| {
        if (walk.text_eql(word, spelling)) return true;
    }

    return false;
}

fn unquoting_boundary(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    return switch (emitter.tokens[position].kind) {
        .block_end, .block_start => true,
        .punctuation => |punctuation| switch (punctuation) {
            .comma, .semicolon => true,
            else => false,
        },
        else => false,
    };
}

fn keyed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const next = emit.ahead_of(emitter, position) orelse return false;
    const kind = emitter.tokens[next].kind;
    if (kind.eql(.{ .punctuation = .colon })) return true;
    if (kind.eql(.{ .punctuation = .assign })) return true;
    if (!walk.text_is(emitter.tokens[next].text(emitter.source), "?")) return false;

    const after = emit.ahead_of(emitter, next) orelse return false;
    return emitter.tokens[after].kind.eql(.{ .punctuation = .colon });
}

pub fn labels(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (!emitter.policy.label_lines) return false;
    if (emitter.tokens[position].kind != .identifier) return false;
    if (line.keying(emitter)) return false;
    if (tern.typed_frame(emitter)) return false;

    const colon = emit.ahead_of(emitter, position) orelse return false;

    assert(colon > position);

    if (emitter.tokens[colon].kind == .comment) return labels_commented(emitter, colon);
    if (!emitter.tokens[colon].is_punctuation(.colon)) return false;
    if (emit.roled(emitter, colon, brace.role_part)) return true;
    if (labels_classed(emitter)) return false;

    const after = labels_coded(emitter, colon) orelse return true;
    const from = emitter.tokens[colon].end();

    return body.parted_by(emitter, from, emitter.tokens[after].offset) > 0;
}

fn labels_commented(emitter: *const Emitter, comment: u32) bool {
    assert(comment < emitter.count);
    assert(emitter.tokens[comment].kind == .comment);

    const held = labels_coded(emitter, comment) orelse return false;
    if (!emitter.tokens[held].is_punctuation(.colon)) return false;
    return emit.roled(emitter, held, brace.role_part);
}

fn labels_coded(emitter: *const Emitter, from: u32) ?u32 {
    assert(from < emitter.count);

    var scan = emit.ahead_of(emitter, from) orelse return null;

    while (emitter.tokens[scan].kind == .comment) {
        const held = emit.ahead_of(emitter, scan) orelse return null;

        assert(held > scan);
        assert(held < emitter.count);

        scan = held;
    }

    return scan;
}

fn labels_classed(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return false;

    const frame = line.frame(emitter);
    if (frame.kind != .block_start) return false;
    return semi.classed_head(emitter, frame.open);
}

pub fn cast_ended_at(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (!emitter.tokens[position].is_punctuation(.paren_close)) return false;

    assert(emitter.wraps_owed < core.wrap_depth_max);

    const wrapped = emitter.wrapped[emitter.wraps_owed];
    if (wrapped.wrap != .parens) return false;
    if (wrapped.close >= position) return false;
    if (!walk.text_is(emitter.tokens[wrapped.start].text(emitter.source), ">")) return false;
    return wrap.cast_wrapped(emitter, wrapped.start) == wrapped.close;
}

pub fn preceding(emitter: *const Emitter, position: u32) ?Token.Kind {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.word_before(emitter, position) orelse return null;
    if (!walk.is_close(emitter.tokens[held].kind)) return null;

    const open = emit.opened(emitter, held) orelse return null;

    assert(open < held);

    if (emitter.tokens[open].is_punctuation(.bracket_open)) {
        if (emit.back_of(emitter, open)) |before| {
            if (emitter.tokens[before].ends_a_value()) return null;
        }
    }

    if (body.bodied_brace(emitter, open)) return null;

    if (emit.back_of(emitter, open)) |before| {
        const kind = emitter.tokens[before].kind;
        const comma = kind.eql(.{ .punctuation = .comma });
        const paren = kind.eql(.{ .punctuation = .paren_open });

        if (!comma) {
            if (!paren) return null;
        }
    }

    return emitter.tokens[open].kind;
}
