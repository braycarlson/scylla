const std = @import("std");
const assert = std.debug.assert;
const Kind = @import("kind.zig").Kind;
const Parser = @import("parse.zig").Parser;
const expression = @import("expression.zig");
const ends_an_iteration_target = expression.ends_an_iteration_target;
const is_closer = expression.is_closer;
const is_layout = expression.is_layout;
const is_name = expression.is_name;
const is_opener = expression.is_opener;
const is_property_name = expression.is_property_name;
const is_statement_word = expression.is_statement_word;
const scan_step_max = @import("parse.zig").scan_step_max;

pub const ArrowStart = enum {
    definite,
    never,
    possible,
};

pub fn arrow_start(parser: *Parser, from: u32) ArrowStart {
    assert(from < parser.count());
    assert(parser.raw[from] == .paren_open);

    const name = parser.significant(from + 1);
    const kind = parser.kind_at(name) orelse return .never;

    switch (kind) {
        .dot_dot_dot, .paren_close => return .definite,
        .brace_open, .bracket_open => return .possible,
        else => {},
    }

    if (!is_name(kind)) {
        if (kind != .this_keyword) return .never;
    }

    const mark = parser.significant(name + 1);
    const follow = parser.kind_at(mark) orelse return .never;

    if (follow == .question) {
        const marked = parser.kind_at(parser.significant(mark + 1)) orelse return .never;

        return switch (marked) {
            .colon, .comma, .equal, .paren_close => .definite,
            else => .never,
        };
    }

    return switch (follow) {
        .colon => .definite,
        .comma, .equal, .paren_close => .possible,
        else => .never,
    };
}

pub fn arrow_after_type(parser: *Parser, from: u32) ?u32 {
    assert(from <= parser.count());
    assert(parser.position <= parser.count());

    var angles: u32 = 0;
    var depth: u32 = 0;
    var position = from;

    for (0..scan_step_max) |_| {
        const kind = parser.kind_at(position) orelse return null;

        position += 1;

        if (is_opener(kind)) depth += 1;

        if (is_closer(kind)) {
            if (depth == 0) return null;

            depth -= 1;
        }

        if (depth != 0) continue;

        if (kind == .less) angles += 1;

        if (kind == .greater) {
            if (angles > 0) angles -= 1;
        }

        if (angles != 0) continue;

        if (kind == .arrow) {
            assert(position - 1 <= parser.tokens.len);

            return position - 1;
        }

        if (kind == .comma) return null;
        if (kind == .equal) return null;
        if (kind == .semicolon) return null;
        if (is_statement_word(kind)) return null;
    }

    return null;
}

pub fn colon_after_body(parser: *Parser, arrow: u32) bool {
    assert(arrow < parser.count());
    assert(parser.raw[arrow] == .arrow);

    const body = parser.significant(arrow + 1);
    const opening = parser.kind_at(body) orelse return false;

    if (opening == .brace_open) {
        return parser.kind_at(parser.significant(parser.balanced_end(body))) == .colon;
    }

    var depth: u32 = 0;
    var questions: u32 = 0;
    var position = body;

    for (0..scan_step_max) |_| {
        const kind = parser.kind_at(position) orelse return false;

        position += 1;

        if (is_opener(kind)) depth += 1;

        if (is_closer(kind)) {
            if (depth == 0) return false;

            depth -= 1;
        }

        if (depth != 0) continue;
        if (kind == .comma) return false;
        if (kind == .semicolon) return false;
        if (is_statement_word(kind)) return false;

        if (kind == .question) questions += 1;

        if (kind == .colon) {
            if (questions == 0) return true;

            questions -= 1;
        }
    }

    return false;
}

pub fn function_type_ahead(parser: *Parser, from: u32) bool {
    assert(from < parser.count());
    assert(parser.raw[from] == .paren_open);

    var position = parser.significant(from + 1);
    const kind = parser.kind_at(position) orelse return false;
    if (kind == .paren_close) return true;
    if (kind == .dot_dot_dot) return true;

    const named = is_name(kind) or kind == .this_keyword;

    if (named) {
        position = parser.significant(position + 1);
    } else {
        const destructured = kind == .brace_open or kind == .bracket_open;

        if (destructured) {
            position = parser.significant(parser.balanced_end(position));
        } else {
            return false;
        }
    }

    const follow = parser.kind_at(position) orelse return false;

    return switch (follow) {
        .colon, .comma, .equal, .question => true,
        .paren_close => parser.kind_at(parser.significant(position + 1)) == .arrow,
        else => false,
    };
}

pub fn iterates(parser: *Parser) bool {
    assert(parser.at(.for_keyword));
    assert(parser.position <= parser.count());

    var position = parser.ahead_position(1);
    var depth: u32 = 0;
    var before: Kind = .paren_open;
    var previous: Kind = .paren_open;

    if (parser.kind_at(position) == .await_keyword) position = parser.significant(position + 1);
    if (declares_using_of(parser, parser.significant(position + 1))) return false;

    for (0..scan_step_max) |_| {
        const kind = parser.kind_at(position) orelse return false;

        if (is_opener(kind)) depth += 1;

        if (is_closer(kind)) {
            if (depth <= 1) return false;

            depth -= 1;
        }

        if (depth == 1) {
            if (kind == .in_keyword) {
                if (!is_member_dot(previous)) return true;
            }

            if (kind == .of_keyword) {
                if (iterates_of(parser, before, previous, position)) return true;
            }

            if (kind == .semicolon) return false;
        }

        if (!is_layout(kind)) {
            before = previous;
            previous = kind;
        }

        position += 1;
    }

    return false;
}

fn iterates_of(parser: *Parser, before: Kind, previous: Kind, position: u32) bool {
    assert(parser.kind_at(position) == .of_keyword);
    assert(position < parser.count());
    assert(before.is_token());
    assert(previous.is_token());

    if (is_member_dot(before)) return is_property_name(previous);
    if (is_member_dot(previous)) return false;

    const ends = switch (previous) {
        .await_keyword => !parser.context_here().awaits,
        .yield_keyword => !parser.context_here().yields,
        else => ends_an_iteration_target(previous),
    };

    if (!ends) return false;
    if (previous != .async_keyword) return true;
    return parser.kind_at(parser.significant(position + 1)) != .arrow;
}

fn is_member_dot(kind: Kind) bool {
    assert(kind.is_token());

    return switch (kind) {
        .dot, .question_dot => true,
        else => false,
    };
}

fn declares_using_of(parser: *Parser, head: u32) bool {
    assert(head <= parser.count() + 2);
    assert(parser.position <= parser.count());

    if (head >= parser.count()) return false;

    var position = head;

    if (parser.kind_at(position) == .await_keyword) position = parser.significant(position + 1);

    if (!parser.word_at(position, "using")) return false;

    const name = parser.significant(position + 1);
    if (parser.kind_at(name) != .of_keyword) return false;

    const after = parser.kind_at(parser.significant(name + 1)) orelse return false;
    return after == .equal or after == .colon;
}

pub fn heritage_generic_ahead(parser: *Parser) bool {
    assert(parser.position <= parser.count());
    assert(parser.significant_next <= parser.count());

    if (!is_property_name(parser.current() orelse .error_token)) return false;

    var position = parser.significant(parser.position);

    for (0..parser.steps()) |_| {
        const after = parser.significant(position + 1);
        if (parser.kind_at(after) != .dot) break;

        const next = parser.significant(after + 1);
        if (!is_property_name(parser.kind_at(next) orelse .error_token)) break;

        position = next;
    }

    return parser.kind_at(parser.significant(position + 1)) == .less;
}

pub fn segments_ahead(parser: *Parser) u32 {
    assert(parser.position <= parser.count());
    assert(parser.raw.len == parser.tokens.len);

    var position = parser.significant(parser.position);
    var segments: u32 = 1;

    for (0..parser.steps()) |_| {
        const after = parser.significant(position + 1);
        if (parser.kind_at(after) != .dot) break;

        const next = parser.significant(after + 1);
        if (!is_property_name(parser.kind_at(next) orelse .error_token)) break;

        position = next;
        segments += 1;
    }

    return segments;
}

pub fn labelled_ahead(parser: *Parser) bool {
    assert(parser.position <= parser.count());
    assert(parser.significant_next <= parser.count());

    var position = parser.significant(parser.position);

    if (parser.kind_at(position) == .dot_dot_dot) position = parser.significant(position + 1);

    if (!is_name(parser.kind_at(position) orelse .error_token)) return false;

    var after = parser.significant(position + 1);

    if (parser.kind_at(after) == .question) after = parser.significant(after + 1);

    return parser.kind_at(after) == .colon;
}

pub fn mapped_modifier_ahead(parser: *Parser) bool {
    assert(parser.position <= parser.count());
    assert(parser.significant_next <= parser.count());

    const signed = parser.at(.minus) or parser.at(.plus);
    if (!signed) return false;
    if (!parser.word_at(parser.ahead_position(1), "readonly")) return false;
    return parser.ahead(2) == .bracket_open;
}

pub fn readonly_index_ahead(parser: *Parser) bool {
    assert(parser.position <= parser.count());
    assert(parser.significant_next <= parser.count());

    if (!parser.word("readonly")) return false;
    if (parser.ahead(1) != .bracket_open) return false;
    if (!is_name(parser.kind_at(parser.ahead_position(2)) orelse .error_token)) return false;

    const kind = parser.kind_at(parser.ahead_position(3)) orelse return false;
    return kind == .colon or kind == .in_keyword;
}

pub fn index_signature_ahead(parser: *Parser) bool {
    assert(parser.at(.bracket_open));
    assert(parser.position <= parser.count());

    const position = parser.ahead_position(1);
    if (!is_name(parser.kind_at(position) orelse .error_token)) return false;

    const kind = parser.kind_at(parser.significant(position + 1)) orelse return false;
    return kind == .colon or kind == .in_keyword;
}

pub fn index_parameter_ahead(parser: *Parser) bool {
    assert(parser.position <= parser.count());
    assert(parser.significant_next <= parser.count());

    if (!parser.at(.comma)) return false;
    if (!is_name(parser.ahead(1) orelse .error_token)) return false;
    return parser.ahead(2) == .colon;
}

pub fn index_signature_at(parser: *Parser, bracket: u32) bool {
    assert(bracket < parser.count());
    assert(parser.raw[bracket] == .bracket_open);

    const position = parser.significant(bracket + 1);
    if (!is_name(parser.kind_at(position) orelse .error_token)) return false;
    return parser.kind_at(parser.significant(position + 1)) == .colon;
}

pub fn mapped_ahead(parser: *Parser) bool {
    assert(parser.position <= parser.count());
    assert(parser.significant_next <= parser.count());

    const position = parser.significant(parser.position);
    if (!is_name(parser.kind_at(position) orelse .error_token)) return false;
    return parser.kind_at(parser.significant(position + 1)) == .in_keyword;
}
