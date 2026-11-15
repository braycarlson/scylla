const std = @import("std");
const assert = std.debug.assert;
const Emitter = @import("../python.zig").Emitter;
const Kind = @import("../python.zig").Kind;
const blank_lines = @import("../python.zig").blank_lines;
const blanked = @import("../python.zig").blanked;
const ends_line = @import("../python.zig").ends_line;
const ends_operand = @import("../python.zig").ends_operand;
const is_close = @import("../python.zig").is_close;
const is_layout = @import("../python.zig").is_layout;
const is_open = @import("../python.zig").is_open;
const power = @import("power.zig");
const slice = @import("slice.zig");

pub fn between(emitter: *const Emitter, prior: Kind, position: u32) bool {
    assert(position < emitter.raw.len);
    assert(prior.is_token());

    const kind = emitter.raw[position];
    if (!blanked(prior, kind)) return false;

    const prior_at = significant_before(emitter, position) orelse return true;
    if (emitter.raw[prior_at] != prior) return true;
    if (prefixes(emitter, prior_at)) return false;
    if (kind == .colon) return sliced(emitter, position) orelse false;
    if (prior == .colon) return sliced(emitter, prior_at) orelse true;
    if (kind == .equal) return !unspaced_equal(emitter, position);
    if (prior == .equal) return !unspaced_equal(emitter, prior_at);
    if (kind == .star_star) return !power.hugs(emitter, position);
    if (prior == .star_star) return !power.hugs(emitter, prior_at);
    return true;
}

fn prefixes(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.raw.len);
    assert(emitter.raw.len == emitter.tokens.len);

    const unary = switch (emitter.raw[position]) {
        .minus, .plus, .star, .star_star, .tilde => true,
        else => false,
    };

    if (!unary) return false;

    const before = significant_before(emitter, position) orelse return true;
    return !ends_operand(emitter.raw[before]);
}

fn unspaced_equal(emitter: *const Emitter, equal_at: u32) bool {
    assert(equal_at < emitter.raw.len);
    assert(emitter.raw[equal_at] == .equal);

    var depth: u32 = 0;
    var annotated = false;
    var bounded = false;
    var scan = equal_at;

    while (scan > 0) {
        scan -= 1;

        const kind = emitter.raw[scan];

        if (is_close(kind)) {
            depth += 1;

            continue;
        }

        if (is_open(kind)) {
            if (depth > 0) {
                depth -= 1;

                continue;
            }

            if (kind != .paren_open) return false;

            const before = significant_before(emitter, scan) orelse return false;
            if (!ends_operand(emitter.raw[before])) return false;
            return !annotated;
        }

        if (depth > 0) continue;
        if (ends_line(kind)) return false;
        if (kind == .lambda_keyword) return true;

        if (kind == .comma) bounded = true;

        if (kind == .colon) {
            if (!bounded) annotated = true;
        }
    }

    return false;
}

fn sliced(emitter: *const Emitter, colon: u32) ?bool {
    assert(colon < emitter.raw.len);
    assert(emitter.raw[colon] == .colon);

    var depth: u32 = 0;
    var scan = colon;

    while (scan > 0) {
        scan -= 1;

        const kind = emitter.raw[scan];
        if (is_layout(kind)) return null;

        if (is_close(kind)) depth += 1;

        if (is_open(kind)) {
            if (depth > 0) {
                depth -= 1;

                continue;
            }

            if (kind != .bracket_open) return null;
            return slice.colon(emitter, colon);
        }
    }

    return null;
}

fn significant_before(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.raw.len);
    assert(emitter.raw.len == emitter.tokens.len);

    var scan = position;

    while (scan > 0) {
        scan -= 1;

        const kind = emitter.raw[scan];
        const skipped = is_layout(kind) or kind == .comment or emitter.tokens[scan].length == 0;
        if (!skipped) return scan;
    }

    return null;
}

pub fn heads_a_definition(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.raw.len);
    assert(emitter.raw.len == emitter.tokens.len);

    if (emitter.raw[position] != .comment) return false;
    if (follows_a_comment(emitter, position)) return false;
    if (comments_alone(emitter, position)) return false;
    if (!emitter.heads_line(position)) return false;

    const count: u32 = @intCast(emitter.tokens.len);
    const column = emitter.line_indent(emitter.tokens[position].offset);
    var end_previous = emitter.tokens[position].end();
    var scan = position + 1;

    while (scan < count) : (scan += 1) {
        const kind = emitter.raw[scan];
        const held = emitter.tokens[scan];
        const skipped = is_layout(kind) or held.length == 0;
        if (skipped) continue;
        if (blank_lines(emitter.source, end_previous, held.offset) > 1) return false;

        if (kind != .comment) {
            const aligned = emitter.line_indent(held.offset) == column;
            return emitter.opens_definition(scan) and aligned;
        }

        end_previous = held.end();
    }

    return false;
}

fn comments_alone(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.raw.len);
    assert(emitter.raw.len == emitter.tokens.len);

    var found = false;
    var scan = position;

    while (scan > 0) {
        scan -= 1;

        const kind = emitter.raw[scan];
        const skipped = is_layout(kind) or emitter.tokens[scan].length == 0;
        if (skipped) continue;
        if (kind != .comment) return false;

        found = true;
    }

    return found;
}

pub fn overloads(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.raw.len);
    assert(emitter.raw.len == emitter.tokens.len);

    if (!emitter.stubbed_function) return false;

    const count: u32 = @intCast(emitter.tokens.len);
    var depth: u32 = 0;
    var scan = position;

    while (scan < count) : (scan += 1) {
        const kind = emitter.raw[scan];

        if (is_open(kind)) depth += 1;
        if (is_close(kind)) depth -|= 1;
        if (depth > 0) continue;
        if (kind == .def_keyword) return true;
        if (kind == .class_keyword) return false;
        if (kind == .colon) return false;
    }

    return false;
}

pub fn follows_a_comment(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.tokens.len);
    assert(emitter.raw.len == emitter.tokens.len);

    const start = emitter.tokens[position].offset;
    var scan = position;

    while (scan > 0) {
        scan -= 1;

        const kind = emitter.raw[scan];
        const held = emitter.tokens[scan];
        const skipped = is_layout(kind) or held.length == 0;
        if (skipped) continue;
        if (kind != .comment) return false;
        if (blank_lines(emitter.source, held.end(), start) > 1) return false;

        const aligned = emitter.line_indent(held.offset) == emitter.line_indent(start);
        const decorated = emitter.line_opener(scan) == .at;
        const leads = aligned or decorated or suite_before(emitter, scan);

        return emitter.heads_line(scan) and leads;
    }

    return false;
}

fn suite_before(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.tokens.len);
    assert(emitter.raw[position] == .comment);

    var scan = position;

    while (scan > 0) {
        scan -= 1;

        const kind = emitter.raw[scan];
        const skipped = is_layout(kind) or kind == .comment or emitter.tokens[scan].length == 0;
        if (skipped) continue;
        return kind == .colon;
    }

    return false;
}

pub fn resumes(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.tokens.len);
    assert(emitter.raw.len == emitter.tokens.len);

    var scan = position;

    while (scan > 0) {
        scan -= 1;

        const kind = emitter.raw[scan];
        const skipped = is_layout(kind) or emitter.tokens[scan].length == 0;
        if (skipped) continue;
        if (kind != .comment) return false;
        if (emitter.until != scan + 1) return false;
        return emitter.pragma_at(scan) == .format_on;
    }

    return false;
}
