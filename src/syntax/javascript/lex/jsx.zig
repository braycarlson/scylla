const std = @import("std");
const assert = std.debug.assert;
const Kind = @import("../kind.zig").Kind;
const Lexer = @import("../lex.zig").Lexer;
const Mode = @import("../lex.zig").Mode;

const Text = struct {
    end: u32,
    kept: bool,
};

const angle_step_max: u32 = 1 << 14;
const entity_length_max: u32 = 33;

pub fn tag_step(lexer: *Lexer, mode: Mode) error{Truncated}!void {
    assert(mode == .jsx_opening or mode == .jsx_closing);
    assert(lexer.top().mode == mode);

    const source = lexer.source;

    blanks(lexer);

    if (lexer.offset >= source.len) return;

    const offset = lexer.offset;
    const byte = source[offset];

    if (byte == '/') {
        if (byte_at(source, offset + 1) == '>') {
            try lexer.push(.jsx_tag_end_self, offset + 2);
            lexer.close();

            return;
        }
    }

    if (try comment(lexer)) return;

    if (byte == '<') {
        if (lexer.previous == .equal) {
            if (lexer.room()) {
                try lexer.push(.jsx_tag_start, offset + 1);

                return lexer.open(.jsx_opening);
            }
        }
    }

    if (try tag_angle(lexer, byte)) return;

    if (byte == '>') {
        try lexer.push(.jsx_tag_end, offset + 1);
        lexer.close();

        if (mode == .jsx_closing) return;
        if (!lexer.room()) return;
        return lexer.open(.jsx_children);
    }

    if (byte == '{') {
        if (lexer.room()) {
            try lexer.push(.brace_open, offset + 1);

            return lexer.open(.jsx_expression);
        }
    }

    return tag_atom(lexer, byte);
}

fn tag_angle(lexer: *Lexer, byte: u8) error{Truncated}!bool {
    const frame = lexer.top();
    const end = lexer.offset + 1;

    assert(lexer.offset < lexer.source.len);
    assert(byte == lexer.source[lexer.offset]);

    if (byte == '<') {
        frame.depth += 1;

        try lexer.push(.less, end);

        return true;
    }

    if (byte != '>') return false;
    if (frame.depth == 0) return false;

    frame.depth -= 1;

    try lexer.push(.greater, end);

    return true;
}

fn tag_atom(lexer: *Lexer, byte: u8) error{Truncated}!void {
    assert(lexer.offset < lexer.source.len);
    assert(byte == lexer.source[lexer.offset]);

    const source = lexer.source;
    const offset = lexer.offset;
    const quoted = byte == '"' or byte == '\'';

    assert(offset < source.len);

    if (quoted) return lexer.push(.string, string_end(source, offset));
    if (is_name_start(byte)) return lexer.push(.identifier, name_end(source, offset));

    const kind: Kind = switch (byte) {
        ',' => .comma,
        '.' => .dot,
        ':' => .colon,
        '=' => .equal,
        else => .error_token,
    };

    try lexer.push(kind, offset + 1);

    if (kind == .error_token) lexer.close();
}

pub fn children_step(lexer: *Lexer) error{Truncated}!void {
    const source = lexer.source;
    const offset = lexer.offset;

    assert(lexer.top().mode == .jsx_children);
    assert(offset < source.len);

    const byte = source[offset];

    if (byte == '<') {
        if (lexer.room()) return children_tag(lexer);
    }

    if (byte == '{') {
        if (lexer.room()) {
            try lexer.push(.brace_open, offset + 1);

            return lexer.open(.jsx_expression);
        }
    }

    if (byte == '&') {
        if (entity_end(source, offset)) |end| return lexer.push(.jsx_entity, end);
    }

    return children_text(lexer);
}

fn children_tag(lexer: *Lexer) error{Truncated}!void {
    const source = lexer.source;
    const offset = lexer.offset;

    assert(lexer.room());
    assert(source[offset] == '<');

    if (byte_at(source, offset + 1) == '/') {
        try lexer.push(.jsx_tag_start_close, offset + 2);
        lexer.close();

        return lexer.open(.jsx_closing);
    }

    try lexer.push(.jsx_tag_start, offset + 1);

    return lexer.open(.jsx_opening);
}

fn children_text(lexer: *Lexer) error{Truncated}!void {
    const source = lexer.source;
    const offset = lexer.offset;
    const text = text_end(source, offset);

    assert(offset < source.len);

    if (text.end == offset) {
        const kind: Kind = if (source[offset] == '<') .jsx_chars else .error_token;
        return lexer.push(kind, offset + 1);
    }

    if (!text.kept) {
        lexer.offset = text.end;

        return;
    }

    return lexer.push(.jsx_chars, text.end);
}

fn blanks(lexer: *Lexer) void {
    const source = lexer.source;

    while (lexer.offset < source.len) : (lexer.offset += 1) {
        if (!is_blank(source[lexer.offset])) break;
    }

    assert(lexer.offset <= source.len);
}

fn comment(lexer: *Lexer) error{Truncated}!bool {
    const source = lexer.source;
    const offset = lexer.offset;

    assert(offset < source.len);

    if (source[offset] != '/') return false;
    if (offset + 1 >= source.len) return false;

    const next = source[offset + 1];

    if (next == '/') {
        try lexer.push(.comment, line_end(source, offset));

        return true;
    }

    if (next != '*') return false;

    try lexer.push(.comment, block_end(source, offset));

    return true;
}

pub fn opens_at(previous: ?Kind, source: []const u8, offset: u32, typed: bool) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(offset <= source.len);

    if (byte_at(source, offset) != '<') return false;
    if (previous) |held| assert(held != .comment);

    const name = trivia_end(source, offset + 1);
    const next = byte_at(source, name) orelse return false;

    if (next != '>') {
        if (!is_name_start(next)) return false;
    }

    if (previous) |kind| {
        if (holds_a_value(kind)) return false;
    }

    if (next == '>') return true;
    return !generic_arrow_at(source, offset, name, typed);
}

fn trivia_end(source: []const u8, from: u32) u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(from < std.math.maxInt(u32));

    const limit: u32 = @intCast(source.len);
    var offset = from;

    assert(from <= limit);

    for (0..angle_step_max) |_| {
        if (offset >= limit) return limit;

        if (is_blank(source[offset])) {
            offset += 1;

            continue;
        }

        if (source[offset] != '/') return offset;

        const next = byte_at(source, offset + 1) orelse return offset;

        if (next == '/') {
            offset = line_end(source, offset);
        } else if (next == '*') {
            offset = block_end(source, offset);
        } else {
            return offset;
        }
    }

    return offset;
}

fn byte_at(source: []const u8, offset: u32) ?u8 {
    assert(source.len <= std.math.maxInt(u32));

    if (offset >= source.len) return null;
    return source[offset];
}

fn is_blank(byte: u8) bool {
    if (byte > ' ') return false;

    const result = switch (byte) {
        '\t', '\n', 0x0b, 0x0c, '\r', ' ' => true,
        else => false,
    };

    if (result) assert(!std.ascii.isAlphanumeric(byte));

    return result;
}

fn is_name_start(byte: u8) bool {
    if (!std.ascii.isAscii(byte)) return false;

    const result = std.ascii.isAlphabetic(byte) or byte == '$' or byte == '_';

    if (result) assert(!std.ascii.isDigit(byte));
    if (result) assert(is_name_byte(byte));

    return result;
}

fn is_name_byte(byte: u8) bool {
    if (!std.ascii.isAscii(byte)) return false;

    const result = std.ascii.isAlphanumeric(byte) or byte == '$' or byte == '-' or byte == '_';

    if (result) assert(!is_blank(byte));

    return result;
}

fn holds_a_value(kind: Kind) bool {
    if (!kind.is_token()) return false;

    const result = switch (kind) {
        .bracket_close, .false_keyword, .identifier, .jsx_tag_end => true,
        .jsx_tag_end_self, .minus_minus, .null_keyword, .number, .paren_close => true,
        .plus_plus, .private_identifier, .regex, .string, .super_keyword => true,
        .template_chars, .template_end, .this_keyword, .true_keyword => true,
        .undefined_keyword => true,
        else => false,
    };

    if (result) assert(kind.is_token());
    if (result) assert(kind != .comment);

    return result;
}

fn entity_end(source: []const u8, from: u32) ?u32 {
    assert(from < source.len);
    assert(source[from] == '&');

    const limit: u32 = @intCast(source.len);
    const stop = @min(limit, from + entity_length_max);
    var offset = from + 1;

    if (byte_at(source, offset) == '#') {
        offset += 1;

        const hexadecimal = byte_at(source, offset) == 'x' or byte_at(source, offset) == 'X';

        if (hexadecimal) offset += 1;

        const start = offset;

        while (offset < stop) : (offset += 1) {
            const byte = source[offset];
            const held = if (hexadecimal) std.ascii.isHex(byte) else std.ascii.isDigit(byte);
            if (!held) break;
        }

        const width = offset -| start;
        const room: u32 = if (hexadecimal) 6 else 5;

        if (width == 0) return null;
        if (width > room) return null;
        if (byte_at(source, offset) != ';') return null;
        assert(source[offset] == ';');

        return offset + 1;
    }

    const start = offset;

    while (offset < stop) : (offset += 1) {
        if (!std.ascii.isAlphabetic(source[offset])) break;
    }

    const width = offset - start;
    if (width == 0) return null;
    if (width > 30) return null;
    if (byte_at(source, offset) != ';') return null;
    assert(source[offset] == ';');

    return offset + 1;
}

fn text_end(source: []const u8, from: u32) Text {
    assert(source.len <= std.math.maxInt(u32));
    assert(from < std.math.maxInt(u32));

    const limit: u32 = @intCast(source.len);
    var offset = from;
    var at_newline = false;
    var saw_text = false;

    assert(from <= limit);

    while (offset < limit) : (offset += 1) {
        const byte = source[offset];
        if (byte == '<') break;
        if (byte == '{') break;
        if (byte == '>') break;
        if (byte == '}') break;

        if (byte == '&') {
            if (entity_end(source, offset) != null) break;
        }

        if (byte == '\n') {
            at_newline = true;
        } else {
            at_newline = at_newline and is_blank(byte);

            if (!at_newline) saw_text = true;
        }
    }

    assert(offset <= limit);

    return .{ .end = offset, .kept = saw_text };
}

fn line_end(source: []const u8, from: u32) u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(from < std.math.maxInt(u32));

    const limit: u32 = @intCast(source.len);
    var offset = from + 2;

    assert(from + 1 < limit);

    while (offset < limit) : (offset += 1) {
        if (source[offset] == '\n') break;
    }

    assert(offset <= limit);

    return offset;
}

fn block_end(source: []const u8, from: u32) u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(from < std.math.maxInt(u32));

    const limit: u32 = @intCast(source.len);
    var offset = from + 2;

    assert(from + 1 < limit);

    while (offset < limit) : (offset += 1) {
        if (source[offset] == '*') {
            if (byte_at(source, offset + 1) == '/') {
                assert(source[offset + 1] == '/');

                return @min(offset + 2, limit);
            }
        }
    }

    return limit;
}

fn name_end(source: []const u8, from: u32) u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(from < std.math.maxInt(u32));

    const limit: u32 = @intCast(source.len);
    var offset = from + 1;

    assert(from < limit);

    while (offset < limit) : (offset += 1) {
        if (!is_name_byte(source[offset])) break;
    }

    assert(offset <= limit);

    return offset;
}

fn generic_arrow_at(source: []const u8, angle: u32, from: u32, typed: bool) bool {
    assert(from < source.len);
    assert(source[angle] == '<');
    assert(is_name_start(source[from]));

    var name = from;

    if (word_at(source, name, "const")) {
        name = trivia_end(source, name_end(source, name));

        const held = byte_at(source, name) orelse return false;
        if (!is_name_start(held)) return false;
    }

    const third = trivia_end(source, name_end(source, name));
    const byte = byte_at(source, third) orelse return false;
    if (byte == ',') return true;
    if (byte == '=') return true;
    if (!word_at(source, third, "extends")) return arrow_after_angles(source, angle, typed);

    const fourth = trivia_end(source, name_end(source, third));
    const after = byte_at(source, fourth) orelse return false;

    return after != '=' and after != '>' and after != '/';
}

pub fn arrow_after_angles(source: []const u8, from: u32, typed: bool) bool {
    assert(from < source.len);
    assert(source[from] == '<');

    const angles = angles_end(source, from) orelse return false;
    const open = trivia_end(source, angles);
    if (byte_at(source, open) != '(') return false;

    const close = parens_end(source, open) orelse return false;
    const after = trivia_end(source, close);
    const byte = byte_at(source, after) orelse return false;
    if (byte == ':') return typed;
    if (byte != '=') return false;
    return byte_at(source, after + 1) == '>';
}

fn angles_end(source: []const u8, from: u32) ?u32 {
    assert(source[from] == '<');

    const limit: u32 = @intCast(source.len);
    var depth: u32 = 0;
    var offset = from;

    assert(from < limit);

    for (0..angle_step_max) |_| {
        if (offset >= limit) return null;

        const byte = source[offset];
        if (byte == ';') return null;
        if (byte == '}') return null;

        if (byte == '{') {
            offset = braces_end(source, offset);

            continue;
        }

        if (is_quote(byte)) {
            offset = string_end(source, offset);

            continue;
        }

        if (byte == '<') depth += 1;

        if (byte == '>') {
            assert(depth > 0);

            depth -= 1;

            if (depth == 0) {
                assert(source[offset] == '>');

                return offset + 1;
            }
        }

        offset += 1;
    }

    return null;
}

fn braces_end(source: []const u8, from: u32) u32 {
    assert(source[from] == '{');

    const limit: u32 = @intCast(source.len);
    var depth: u32 = 0;
    var offset = from;

    assert(from < limit);

    for (0..angle_step_max) |_| {
        if (offset >= limit) return limit;

        const byte = source[offset];

        if (is_quote(byte)) {
            offset = string_end(source, offset);

            continue;
        }

        if (byte == '{') depth += 1;

        if (byte == '}') {
            assert(depth > 0);

            depth -= 1;

            if (depth == 0) {
                assert(source[offset] == '}');

                return offset + 1;
            }
        }

        offset += 1;
    }

    return limit;
}

fn parens_end(source: []const u8, from: u32) ?u32 {
    assert(source[from] == '(');

    const limit: u32 = @intCast(source.len);
    var depth: u32 = 0;
    var offset = from;

    assert(from < limit);

    for (0..angle_step_max) |_| {
        if (offset >= limit) return null;

        const byte = source[offset];

        if (is_quote(byte)) {
            offset = string_end(source, offset);

            continue;
        }

        if (byte == '(') depth += 1;

        if (byte == ')') {
            assert(depth > 0);

            depth -= 1;

            if (depth == 0) {
                assert(source[offset] == ')');

                return offset + 1;
            }
        }

        offset += 1;
    }

    return null;
}

fn is_quote(byte: u8) bool {
    if (byte > '`') return false;

    const result = byte == '"' or byte == '\'' or byte == '`';

    if (result) assert(!is_name_byte(byte));

    return result;
}

fn word_at(source: []const u8, from: u32, word: []const u8) bool {
    assert(from <= source.len);
    assert(word.len > 0);

    if (from >= source.len) return false;
    if (!is_name_start(source[from])) return false;
    return std.mem.eql(u8, source[from..name_end(source, from)], word);
}

fn string_end(source: []const u8, from: u32) u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(from < source.len);

    const limit: u32 = @intCast(source.len);
    const quote = source[from];
    var offset = from + 1;

    assert(from < limit);

    while (offset < limit) : (offset += 1) {
        if (source[offset] == quote) {
            assert(offset + 1 <= limit);

            return offset + 1;
        }
    }

    return limit;
}
