const std = @import("std");
const assert = std.debug.assert;
const Element = @import("../ir.zig").Element;
const Emitter = @import("../python.zig").Emitter;
const Frame = @import("../python.zig").Frame;
const Kind = @import("../python.zig").Kind;
const QuotePreference = @import("../python.zig").QuotePreference;
const Span = @import("../../stdx/bounded/span.zig");
const bracket_depth_max = @import("../python.zig").bracket_depth_max;
const columns = @import("../walk.zig").columns;
const field_tuple = @import("field.zig").field_tuple;
const is_augmented = @import("../python.zig").is_augmented;
const is_close = @import("../python.zig").is_close;
const is_open = @import("../python.zig").is_open;
const other_quote = @import("literal.zig").other_quote;
const preferring = @import("literal.zig").preferring;
const prefix_of = @import("literal.zig").prefix_of;
const prefix_written = @import("literal.zig").prefix_written;
const refielded = @import("field.zig").refielded;
const triple_double = @import("literal.zig").triple_double;
const triple_single = @import("literal.zig").triple_single;
const none: u32 = std.math.maxInt(u32);

pub const Formatted = struct {
    close: u32,
    end: u32,
    quote: u8,
    spaced: bool,
    specced: bool,
    stop: u32,

    pub const idle: Formatted = .{
        .close = none,
        .end = none,
        .quote = 0,
        .spaced = false,
        .specced = false,
        .stop = none,
    };

    pub fn active(formatted: Formatted) bool {
        if (formatted.end == none) assert(formatted.close == none);

        return formatted.end != none;
    }
};

const Lone = enum { best, never, none };

pub fn wrapped(emitter: *Emitter, position: u32, kind: Kind) error{Overflow}!bool {
    assert(position < emitter.tokens.len);
    assert(emitter.wrap == null);
    assert(kind.is_token());

    switch (try lone(emitter, position, kind, emitter.wrap_end(position))) {
        .best => {
            try emitter.wrap_line(position);

            return true;
        },
        .never => return true,
        .none => return false,
    }
}

fn lone(emitter: *Emitter, position: u32, kind: Kind, end: u32) error{Overflow}!Lone {
    assert(kind.is_token());

    const assigns = kind == .equal or kind == .return_keyword or is_augmented(kind);

    assert(position < end);
    assert(end <= emitter.tokens.len);

    if (!assigns) return .none;
    if (emitter.depth > 0) return .none;

    const first = position + 1;
    if (first >= end) return .none;
    if (emitter.raw[first] != .f_string_start) return .none;

    const last = emitter.fstring_end(first) orelse return .none;

    assert(first < last);
    assert(emitter.raw[last] == .f_string_end);

    if (last + 1 != end) return .none;
    if (!multiline(emitter, first, last)) return .none;
    if (lined(emitter, first, last)) return .none;

    const offset = emitter.arena.count();
    defer emitter.arena.truncate(offset);

    if (!try refielded(emitter, first, last, 0)) return .none;

    const text = emitter.arena.const_slice()[offset..];
    const width = columns(text, 0, @intCast(text.len));
    const comment: u32 = if (emitter.rider(last)) |at| 2 + emitter.tokens[at].length else 0;
    const inner = (emitter.indent + 1) * emitter.indent_width;
    if (inner + width + comment > emitter.line_width) return .never;
    return .best;
}

pub fn preference(emitter: *const Emitter, bytes: []const u8) QuotePreference {
    assert(bytes.len > 0);

    const held = emitter.formatted;
    const rest = bytes[prefix_of(bytes)..];

    const tripled_string = std.mem.startsWith(u8, rest, triple_double) or
        std.mem.startsWith(u8, rest, triple_single);

    if (held.active()) assert(held.quote == '"' or held.quote == '\'');

    if (held.close == none) return emitter.quote;
    if (!tripled_string) return emitter.quote;
    return preferring(other_quote(held.quote));
}

pub fn lined(emitter: *const Emitter, position: u32, end: u32) bool {
    var formats: u32 = 0;

    assert(position < end);
    assert(emitter.raw[position] == .f_string_start);

    for (position..end + 1) |scan| {
        const kind = emitter.raw[scan];
        if (kind == .comment) return true;

        if (kind == .f_string_start) formats += 1;
        if (kind == .f_string_end) formats -|= 1;

        const literal = kind == .f_string_middle and formats == 1;
        const bytes = emitter.tokens[scan].text(emitter.source);

        if (literal) {
            if (std.mem.findScalar(u8, bytes, '\n') != null) return true;
        }
    }

    var scan = position + 1;

    for (position..end) |_| {
        if (scan >= end) return false;

        if (emitter.raw[scan] != .brace_open) {
            scan += 1;

            continue;
        }

        const close = field_close(emitter, scan, end) orelse return false;
        const stop = field_stop(emitter, scan, close);
        const offset = emitter.tokens[scan].offset;
        const bytes = emitter.source[offset..emitter.tokens[close].offset];
        const debugged = emitter.raw[stop] == .equal;

        if (debugged) {
            if (std.mem.findScalar(u8, bytes, '\n') != null) return true;
        }

        scan = close + 1;
    }

    return false;
}

pub fn multiline(emitter: *const Emitter, position: u32, end: u32) bool {
    assert(position < end);
    assert(emitter.raw[position] == .f_string_start);

    if (!tripled(emitter, position)) return false;

    var scan = position + 1;

    for (position..end) |_| {
        if (scan >= end) return false;

        if (emitter.raw[scan] != .brace_open) {
            scan += 1;

            continue;
        }

        const close = field_close(emitter, scan, end) orelse return false;
        const offset = emitter.tokens[scan].offset;

        if (field_tuple(emitter, scan) != null) return false;

        const bytes = emitter.source[offset..emitter.tokens[close].end()];
        if (std.mem.findScalar(u8, bytes, '\n') != null) return true;

        assert(close > scan);

        scan = close + 1;
    }

    return false;
}

fn tripled(emitter: *const Emitter, position: u32) bool {
    assert(emitter.raw[position] == .f_string_start);

    const token = emitter.tokens[position];
    const spelling = emitter.source[token.offset..token.end()];
    const rest = spelling[prefix_of(spelling)..];

    assert(rest.len > 0);

    return std.mem.eql(u8, rest, triple_double) or std.mem.eql(u8, rest, triple_single);
}

fn field_close(emitter: *const Emitter, open: u32, end: u32) ?u32 {
    var depth: u32 = 0;

    assert(open < end);
    assert(emitter.raw[open] == .brace_open);

    for (open..end) |scan| {
        const kind = emitter.raw[scan];

        if (is_open(kind)) depth += 1;

        if (is_close(kind)) {
            if (depth == 0) return null;

            depth -= 1;

            if (depth == 0) {
                assert(scan < end);

                return @intCast(scan);
            }
        }
    }

    return null;
}

fn field_stop(emitter: *const Emitter, open: u32, close: u32) u32 {
    var depth: u32 = 0;

    assert(open < close);
    assert(emitter.raw[close] == .brace_close);

    for (open + 1..close) |scan| {
        const kind = emitter.raw[scan];

        if (depth == 0) {
            switch (kind) {
                .bang, .colon, .equal => {
                    assert(scan < emitter.raw.len);

                    return @intCast(scan);
                },
                else => {},
            }
        }

        if (is_open(kind)) depth += 1;
        if (is_close(kind)) depth -|= 1;
    }

    return close;
}

pub fn opens(emitter: *Emitter, position: u32, end: u32) error{Overflow}!void {
    assert(position < emitter.tokens.len);
    assert(end < emitter.tokens.len);

    const token = emitter.tokens[position];
    const spelling = emitter.source[token.offset..token.end()];
    const at = prefix_of(spelling);
    const prefix = prefix_written(spelling[0..at]);
    const offset = emitter.arena.count();

    assert(!emitter.formatted.active());
    assert(emitter.raw[end] == .f_string_end);

    try emitter.arena.push(prefix.written[0..prefix.count]);
    try emitter.arena.push(spelling[at..]);

    const written: Span = .{ .offset = offset, .length = emitter.arena.count() - offset };

    try emitter.document.push(.{ .text = .{ .source = .arena, .span = written } });

    emitter.formatted = .idle;
    emitter.formatted.end = end;
    emitter.formatted.quote = spelling[at];
    emitter.at_previous = position;
    emitter.previous = .f_string_start;
    emitter.suppress_space = false;

    assert(emitter.formatted.active());
}

pub fn piece(emitter: *Emitter, position: u32, kind: Kind) error{Overflow}!bool {
    assert(kind.is_token());

    const held = emitter.formatted;

    assert(held.active());
    assert(position <= held.end);

    if (position == held.end) {
        try headed(emitter, position, kind);
        try spelled(emitter, position);

        emitter.at_previous = position;
        emitter.formatted = .idle;
        emitter.previous = .f_string_end;
        emitter.suppress_space = false;

        return true;
    }

    if (held.close == none) {
        try headed(emitter, position, kind);

        if (kind == .brace_open) {
            try field_opens(emitter, position);
        } else {
            assert(kind == .f_string_middle);

            try spelled(emitter, position);

            emitter.previous = .f_string_middle;
        }

        return true;
    }

    if (position == held.close) {
        try headed(emitter, position, kind);
        try field_closes(emitter, position, true);

        return true;
    }

    if (position != held.stop) return false;

    try headed(emitter, position, kind);

    if (try specified(emitter, position, held.close)) {
        try field_closes(emitter, held.close, false);

        emitter.until = held.close + 1;
    } else {
        emitter.until = held.close;
    }

    return true;
}

fn headed(emitter: *Emitter, position: u32, kind: Kind) error{Overflow}!void {
    const own_line = emitter.pending_break or emitter.previous == null;

    assert(emitter.raw[position] == kind);
    assert(emitter.formatted.active());

    try emitter.heading(position, kind, own_line);

    emitter.starting = own_line;
}

fn spelled(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.tokens.len);

    const span = emitter.tokens[position].span();

    assert(span.end() <= emitter.source.len);
    assert(emitter.formatted.active());

    emitter.at_previous = position;

    if (span.length == 0) return;

    try emitter.document.push(element_of(emitter, span));
}

fn specified(emitter: *Emitter, position: u32, close: u32) error{Overflow}!bool {
    assert(position < close);

    const offset = emitter.tokens[position].offset;
    const spelled_end = emitter.tokens[close - 1].end();
    const ended = emitter.source[spelled_end - 1] == '\n';
    const end = if (ended) emitter.tokens[close].end() else spelled_end;
    const span: Span = .{ .offset = offset, .length = end - offset };

    assert(span.length > 0);

    try emitter.document.push(element_of(emitter, span));

    emitter.at_previous = position;
    emitter.previous = .f_string_middle;

    return ended;
}

fn field_opens(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.tokens.len);

    const end = emitter.formatted.end;
    const close = field_close(emitter, position, end) orelse return error.Overflow;
    const stop = field_stop(emitter, position, close);

    assert(position < close);
    assert(stop <= close);

    if (emitter.raw[stop] == .equal) return field_verbatim(emitter, position, close);

    if (std.mem.findScalar(Kind, emitter.raw[stop..close], .comment) != null) {
        return field_verbatim(emitter, position, close);
    }

    if (emitter.depth == bracket_depth_max) return error.Overflow;

    const leading = emitter.raw[position + 1] == .brace_open;
    const riding = emitter.rider(position);
    const spacing: Element = if (riding != null) .hard_line else if (leading) .line else .soft_line;
    var frame: Frame = .new();

    frame.kind = .paren_open;
    frame.priority = emitter.priority_between(position + 1, stop);

    emitter.frames[emitter.depth] = frame;
    emitter.depth += 1;
    emitter.formatted.close = close;
    emitter.formatted.spaced = leading and stop == close;
    emitter.formatted.specced = specced(emitter, stop, close);
    emitter.formatted.stop = stop;

    try emitter.document.push(.group_open);
    try emitter.text(position, false);

    if (riding) |comment_at| try emitter.rides(comment_at);

    try emitter.document.push(.indent);
    try emitter.document.push(spacing);
    try emitter.document.push(.group_open);
    try emitter.starts_element(position, .brace_open, frame.priority);
}

fn field_verbatim(emitter: *Emitter, position: u32, close: u32) error{Overflow}!void {
    assert(position < close);

    const offset = emitter.tokens[position].offset;
    const span: Span = .{ .offset = offset, .length = emitter.tokens[close].end() - offset };

    assert(emitter.raw[close] == .brace_close);

    try emitter.document.push(element_of(emitter, span));

    emitter.at_previous = close;
    emitter.previous = .brace_close;
    emitter.until = close + 1;
}

fn field_closes(emitter: *Emitter, position: u32, braced: bool) error{Overflow}!void {
    const held = emitter.formatted;

    assert(position == held.close);
    assert(emitter.depth > 0);

    try emitter.ends_element(0);

    const frame = emitter.frame();
    const started = emitter.starting;
    const closes = !frame.sole and !frame.hollow and !frame.commented;
    const spacing: Element = if (held.spaced) .line else .soft_line;

    emitter.depth -= 1;

    if (closes) try emitter.document.push(.group_close);

    try emitter.document.push(.dedent);

    if (!started) {
        if (!held.specced) try emitter.document.push(spacing);
    }

    if (braced) {
        try emitter.text(position, false);
    } else {
        emitter.at_previous = position;
        emitter.previous = .brace_close;
    }

    try emitter.document.push(.group_close);

    emitter.formatted.close = none;
    emitter.formatted.spaced = false;
    emitter.formatted.specced = false;
    emitter.formatted.stop = none;
}

fn specced(emitter: *const Emitter, stop: u32, close: u32) bool {
    var depth: u32 = 0;

    assert(stop <= close);
    assert(emitter.raw[close] == .brace_close);

    for (stop..close) |scan| {
        const kind = emitter.raw[scan];

        if (depth == 0) {
            if (kind == .colon) return true;
        }

        if (is_open(kind)) depth += 1;
        if (is_close(kind)) depth -|= 1;
    }

    return false;
}

fn element_of(emitter: *const Emitter, span: Span) Element {
    assert(span.end() <= emitter.source.len);

    const bytes = span.text(emitter.source);

    assert(span.length > 0);

    if (std.mem.findScalar(u8, bytes, '\n') != null) return .{ .verbatim = span };
    return .{ .text = .{ .source = .document, .span = span } };
}
