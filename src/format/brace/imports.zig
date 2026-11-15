const std = @import("std");
const assert = std.debug.assert;
const call = @import("call.zig");
const core = @import("emitter.zig");
const emit = @import("emit.zig");
const join = @import("join.zig");
const requoted = @import("../text.zig").requoted;
const span = @import("span.zig");
const walk = @import("../walk.zig");
const Emitter = core.Emitter;
const import_trails_max: u32 = 64;

pub fn import_span(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    if (!emitter.policy.union_parts) return null;
    if (emitter.tokens[position].kind == .comment) return null;
    if (!walk.text_is(emitter.tokens[position].text(emitter.source), "import")) return null;

    const open = emit.ahead_of(emitter, position) orelse return null;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return null;
    if (!import_span_typed(emitter, position, open)) return null;

    const close = join.closing_of(emitter, open) orelse return null;
    const argument = emit.ahead_of(emitter, open) orelse return null;
    if (emitter.tokens[argument].kind != .string) return null;
    if (emit.ahead_of(emitter, argument) != close) return null;

    const last = import_span_trailed(emitter, close);
    if (import_span_spaced(emitter, position, last)) return null;
    return last;
}

fn import_span_typed(emitter: *const Emitter, position: u32, open: u32) bool {
    assert(position < emitter.count);
    assert(open < emitter.count);

    if (call.import_typed(emitter, position)) return true;
    if (emitter.brackets.angles_at(position) > 0) return true;

    const held = span.union_open(emitter, position) orelse return false;
    return span.union_typed(emitter, held);
}

fn import_span_trailed(emitter: *const Emitter, close: u32) u32 {
    assert(close < emitter.count);

    var last = close;

    for (0..import_trails_max) |_| {
        const next = emit.ahead_of(emitter, last) orelse break;
        const held = import_span_trailed_step(emitter, next) orelse break;

        last = held;
    }

    return last;
}

fn import_span_trailed_step(emitter: *const Emitter, next: u32) ?u32 {
    assert(next < emitter.count);

    if (emitter.tokens[next].is_punctuation(.dot)) {
        const name = emit.ahead_of(emitter, next) orelse return null;

        const named = switch (emitter.tokens[name].kind) {
            .identifier, .keyword => true,
            else => false,
        };

        if (!named) return null;
        return name;
    }

    if (!emitter.tokens[next].is_punctuation(.bracket_open)) return null;

    const end = join.closing_of(emitter, next) orelse return null;
    const inner = emit.ahead_of(emitter, next) orelse return null;
    const single = emit.ahead_of(emitter, inner) == end;
    if (!single) return null;
    return end;
}

fn import_span_spaced(emitter: *const Emitter, position: u32, last: u32) bool {
    assert(position <= last);
    assert(last < emitter.count);

    var held = position;

    while (held <= last) {
        if (import_span_spaced_at(emitter, position, held)) return true;

        held += 1;
    }

    return false;
}

fn import_span_spaced_at(emitter: *const Emitter, position: u32, held: u32) bool {
    assert(held < emitter.count);

    const token = emitter.tokens[held];
    if (token.kind == .comment) return true;
    if (token.kind == .newline) return true;
    if (held == position) return false;
    if (token.length == 0) return false;
    return emitter.tokens[held - 1].end() != token.offset;
}

pub fn import_spanned(emitter: *Emitter, position: u32, close: u32) error{Overflow}!void {
    assert(position <= close);
    assert(close < emitter.count);

    const offset = emitter.arena.count();

    import_spanned_write(emitter, position, close) catch |err| {
        emitter.arena.truncate(offset);

        return err;
    };

    assert(emitter.arena.count() >= offset);

    emitter.previous = close;
    emitter.resume_at = close + 1;
    emitter.suppress_space = false;

    try emitter.document.push(.{ .verbatim_arena = .{
        .length = emitter.arena.count() - offset,
        .offset = offset,
    } });
}

fn import_spanned_write(emitter: *Emitter, position: u32, close: u32) error{Overflow}!void {
    assert(position <= close);
    assert(close < emitter.count);

    var held = position;

    while (held <= close) {
        try import_spanned_token(emitter, held);

        held += 1;
    }
}

fn import_spanned_token(emitter: *Emitter, held: u32) error{Overflow}!void {
    assert(held < emitter.count);

    const token = emitter.tokens[held];
    if (token.length == 0) return;

    if (emit.requoting(emitter, held)) |found| {
        const spelling, const quote = found;

        try emitter.arena.push_byte(quote);
        try requoted(emitter.arena, spelling, quote);
        try emitter.arena.push_byte(quote);

        return;
    }

    try emitter.arena.push(token.text(emitter.source));
}
