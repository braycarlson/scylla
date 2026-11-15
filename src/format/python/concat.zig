const std = @import("std");
const assert = std.debug.assert;
const Emitter = @import("../python.zig").Emitter;
const Kind = @import("../python.zig").Kind;
const is_augmented = @import("../python.zig").is_augmented;
const is_close = @import("../python.zig").is_close;
const is_layout = @import("../python.zig").is_layout;
const is_open = @import("../python.zig").is_open;
const is_string_start = @import("../python.zig").is_string_start;

fn code_after(emitter: *const Emitter, position: u32) ?Kind {
    assert(position < emitter.raw.len);
    assert(emitter.raw.len == emitter.tokens.len);

    const count: u32 = @intCast(emitter.raw.len);
    var scan = position + 1;

    while (scan < count) : (scan += 1) {
        const kind = emitter.raw[scan];
        if (is_layout(kind)) continue;
        if (kind == .comment) continue;
        return kind;
    }

    return null;
}

pub fn commented(emitter: *const Emitter, position: u32, end: u32) bool {
    assert(position < end);
    assert(end < emitter.raw.len);

    const count: u32 = @intCast(emitter.raw.len);
    var crossed = false;
    var scan = end + 1;

    while (scan < count) : (scan += 1) {
        const kind = emitter.raw[scan];

        if (kind == .comment) {
            crossed = true;

            continue;
        }

        if (kind == .newline) continue;

        if (crossed) {
            if (is_string_start(kind)) return true;
        }

        break;
    }

    crossed = false;
    scan = position;

    while (scan > 0) {
        scan -= 1;

        const kind = emitter.raw[scan];

        if (kind == .comment) {
            crossed = true;

            continue;
        }

        if (kind == .newline) continue;

        const ended = kind == .f_string_end or kind == .string_bytes or kind == .string_plain;
        return crossed and ended;
    }

    return false;
}

fn statement_level(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.raw.len);
    assert(emitter.raw.len == emitter.tokens.len);

    var depth: u32 = 0;
    var scan = position;

    while (scan > 0) {
        scan -= 1;

        const kind = emitter.raw[scan];

        if (is_close(kind)) depth += 1;

        if (is_open(kind)) {
            if (depth == 0) return false;

            depth -= 1;
        }

        if (depth == 0) {
            if (kind == .newline) return true;
        }
    }

    return depth == 0;
}

pub fn trailed(emitter: *const Emitter, position: u32, end: u32) bool {
    assert(position < end);
    assert(end < emitter.raw.len);

    if (end + 1 == emitter.raw.len) return false;
    if (emitter.raw[end + 1] != .comment) return false;
    if (code_after(emitter, end + 1) != .paren_close) return false;

    const trailing = emitter.source[emitter.tokens[end].end()..emitter.tokens[end + 1].offset];
    if (std.mem.findScalar(u8, trailing, '\n') != null) return false;

    var before: ?u32 = null;
    var last = position;
    var scan = position;

    while (scan <= end) {
        if (emitter.raw[scan] == .newline) {
            scan += 1;

            continue;
        }

        const closed = emitter.part_end(scan).?;

        if (closed < end) before = closed;

        last = scan;
        scan = closed + 1;
    }

    const prior = before orelse return false;
    const spacing = emitter.source[emitter.tokens[prior].end()..emitter.tokens[last].offset];
    if (std.mem.findScalar(u8, spacing, '\n') == null) return false;

    const paren = emitter.prior_token(position, 0) orelse return false;
    if (emitter.raw[paren] != .paren_open) return false;

    const head = emitter.prior_token(paren, 0) orelse return false;
    const kind = emitter.raw[head];
    const assigning = kind == .equal or kind == .return_keyword or is_augmented(kind);
    if (!assigning) return false;
    return statement_level(emitter, head);
}
