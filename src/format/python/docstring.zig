const std = @import("std");
const assert = std.debug.assert;
const Emitter = @import("../python.zig").Emitter;
const Run = @import("../python.zig").Run;
const ends_line = @import("../python.zig").ends_line;
const is_layout = @import("../python.zig").is_layout;

pub fn documents(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.tokens.len);
    assert(emitter.tokens.len == emitter.raw.len);

    if (docstring_open(emitter, position) != null) return true;
    if (!emitter.starting) return false;
    return documents_between(emitter, position, position);
}

pub fn extent(emitter: *const Emitter, position: u32) Run {
    assert(position < emitter.tokens.len);
    assert(emitter.tokens.len == emitter.raw.len);

    const bare: Run = .{ .first = position, .last = position };
    const open_at = docstring_open(emitter, position) orelse return bare;
    const close_at = parens(emitter, open_at).?;

    return nested_parens(emitter, open_at, close_at);
}

fn docstring_open(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.tokens.len);
    assert(emitter.tokens.len == emitter.raw.len);

    var back = position;

    while (back > 0) {
        back -= 1;

        const kind = emitter.raw[back];
        if (is_layout(kind)) continue;
        if (kind == .comment) continue;
        if (kind != .paren_open) return null;

        const close_at = parens(emitter, back) orelse return null;

        assert(close_at > position);

        if (emitter.next_token(position, close_at + 1) != close_at) return null;
        return back;
    }

    return null;
}

pub fn parens(emitter: *const Emitter, open_at: u32) ?u32 {
    assert(open_at < emitter.tokens.len);
    assert(emitter.raw[open_at] == .paren_open);

    const count: u32 = @intCast(emitter.tokens.len);
    var depth: u32 = 1;
    var scan = emitter.next_token(open_at, count) orelse return null;

    for (0..count) |_| {
        const kind = emitter.raw[scan];

        if (kind != .comment) {
            if (kind != .paren_open) break;
        }

        if (kind == .paren_open) depth += 1;

        scan = emitter.next_token(scan, count) orelse return null;
    }

    if (emitter.raw[scan] != .string_plain) return null;

    for (0..count) |_| {
        if (emitter.raw[scan] != .string_plain) break;

        scan = emitter.next_token(scan, count) orelse return null;
    }

    for (1..depth) |_| {
        if (emitter.raw[scan] != .paren_close) return null;

        scan = emitter.next_token(scan, count) orelse return null;
    }

    const close_at = scan;
    if (emitter.raw[close_at] != .paren_close) return null;

    const nested = nested_parens(emitter, open_at, close_at);
    if (!documents_between(emitter, nested.first, nested.last)) return null;
    return close_at;
}

fn nested_parens(emitter: *const Emitter, open_at: u32, close_at: u32) Run {
    assert(open_at < close_at);
    assert(close_at < emitter.tokens.len);

    const count: u32 = @intCast(emitter.tokens.len);
    var span: Run = .{ .first = open_at, .last = close_at };

    for (0..count) |_| {
        var back = span.first;

        while (back > 0) {
            back -= 1;

            const kind = emitter.raw[back];

            if (!is_layout(kind)) {
                if (kind != .comment) break;
            }
        }

        const after = emitter.next_token(span.last, count) orelse break;

        if (back == span.first) break;
        if (emitter.raw[back] != .paren_open) break;
        if (emitter.raw[after] != .paren_close) break;

        span = .{ .first = back, .last = after };
    }

    return span;
}

fn documents_between(emitter: *const Emitter, first: u32, last: u32) bool {
    assert(first <= last);
    assert(last < emitter.tokens.len);

    const count: u32 = @intCast(emitter.tokens.len);
    var scan = last + 1;

    while (scan < count) : (scan += 1) {
        const kind = emitter.raw[scan];
        if (kind == .comment) continue;
        if (ends_line(kind)) break;
        if (!is_layout(kind)) return false;

        break;
    }

    var back = first;

    while (back > 0) {
        back -= 1;

        const kind = emitter.raw[back];
        const skipped = is_layout(kind) or kind == .comment;
        if (skipped) continue;
        return kind == .colon and defines(emitter, back);
    }

    return true;
}

pub fn classes_above(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.tokens.len);
    assert(emitter.tokens.len == emitter.raw.len);

    var back = position;

    while (back > 0) {
        back -= 1;

        const kind = emitter.raw[back];
        const skipped = is_layout(kind) or kind == .comment;
        if (skipped) continue;
        return kind == .colon and opens_class(emitter, back);
    }

    return false;
}

fn opens_class(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.tokens.len);
    assert(emitter.raw[position] == .colon);

    return emitter.raw[emitter.line_opener_at(position + 1)] == .class_keyword;
}

fn defines(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.tokens.len);
    assert(emitter.raw[position] == .colon);

    return emitter.opens_definition(emitter.line_opener_at(position + 1));
}
