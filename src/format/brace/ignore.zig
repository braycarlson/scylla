const std = @import("std");
const assert = std.debug.assert;
const body = @import("body.zig");
const call = @import("call.zig");
const core = @import("emitter.zig");
const emit = @import("emit.zig");
const walk = @import("../walk.zig");
const Emitter = core.Emitter;
const comment_blanks: []const u8 = " \t\n\x0c\r";
const suppression: []const u8 = "biome-ignore format";

pub fn suppressed_span(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    if (emitter.tokens[position].kind == .comment) return null;
    if (!suppressed(emitter, position)) return null;

    const tail = suppressed_span_end(emitter, position) orelse return null;

    assert(tail >= position);
    assert(tail < emitter.count);

    return tail;
}

fn suppressed_span_end(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    var depth: u32 = 0;
    var valued = false;
    var scan = position;

    while (scan < emitter.count) {
        if (call.spanned_body(emitter, scan)) |stop| {
            assert(stop >= scan);

            scan = stop + 1;

            continue;
        }

        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            if (depth == 0) return null;

            depth -= 1;

            if (suppressed_span_closed(emitter, scan, depth, valued)) return scan;
        } else if (depth == 0) {
            if (kind.eql(.{ .punctuation = .semicolon })) return scan;

            if (kind.eql(.{ .punctuation = .assign })) valued = true;
        } else {}

        scan += 1;
    }

    return null;
}

fn suppressed_span_closed(emitter: *const Emitter, scan: u32, depth: u32, valued: bool) bool {
    assert(scan < emitter.count);

    const parted = suppressed_span_parted(emitter, scan);

    if (depth != 0) return false;
    if (emitter.tokens[scan].kind != .block_end) return false;
    if (!parted) return false;
    return !valued;
}

fn suppressed_span_parted(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);

    const after = emit.ahead_of(emitter, scan) orelse return true;

    assert(after > scan);

    return body.parts_at(emitter, scan, after);
}

fn suppressed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (position == 0) return false;

    var held = position - 1;

    while (suppressed_blank(emitter, held)) {
        if (held == 0) return false;

        held -= 1;
    }

    const token = emitter.tokens[held];

    assert(held < position);

    if (token.kind != .comment) return false;
    if (!body.parts_at(emitter, held, position)) return false;

    const comment = suppressed_comment(token.text(emitter.source));
    return std.mem.startsWith(u8, comment, suppression);
}

fn suppressed_blank(emitter: *const Emitter, held: u32) bool {
    assert(held < emitter.count);

    const token = emitter.tokens[held];
    if (token.kind == .newline) return true;
    return token.length == 0;
}

fn suppressed_comment(text: []const u8) []const u8 {
    assert(text.len <= std.math.maxInt(u32));

    const lined = std.mem.startsWith(u8, text, "//");
    const blocked = std.mem.startsWith(u8, text, "/*");
    const opened = lined or blocked;
    const stripped = if (opened) text[2..] else text;

    assert(stripped.len <= text.len);

    return std.mem.trimStart(u8, stripped, comment_blanks);
}

pub fn suppressed_spanned(emitter: *Emitter, position: u32, tail: u32) error{Overflow}!void {
    assert(position <= tail);
    assert(tail < emitter.count);

    const offset = emitter.tokens[position].offset;
    const end = emitter.tokens[tail].end();

    assert(end >= offset);

    emitter.previous = tail;
    emitter.resume_at = tail + 1;
    emitter.suppress_space = false;

    try emitter.document.push(.{ .verbatim = .{ .offset = offset, .length = end - offset } });
}
