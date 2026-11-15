const std = @import("std");
const assert = std.debug.assert;
const Lexer = @import("../lex.zig").Lexer;

pub fn chars_step(lexer: *Lexer) error{Truncated}!void {
    const source = lexer.source;
    const offset = lexer.offset;

    assert(lexer.top().mode == .template);
    assert(offset < source.len);

    if (source[offset] == '`') {
        try lexer.push(.template_end, offset + 1);
        lexer.close();

        return;
    }

    if (opens_a_substitution(source, offset)) {
        try lexer.push(.substitution_start, offset + 2);

        return lexer.open(.substitution);
    }

    const end = literal_end(source, offset);

    assert(end > offset);

    try lexer.push(.template_chars, end);
}

pub fn escapes_valid(text: []const u8, templated: bool) bool {
    var offset: usize = 0;

    assert(text.len <= std.math.maxInt(u32));

    for (0..text.len + 1) |_| {
        const slash = std.mem.findScalarPos(u8, text, offset, '\\') orelse return true;
        const after = slash + 1;
        if (after >= text.len) return true;

        const width = escape_width(text, after, templated) orelse return false;

        assert(width > 0);

        offset = after + width;
    }

    return true;
}

fn escape_width(text: []const u8, from: usize, templated: bool) ?usize {
    assert(from < text.len);
    assert(text[from - 1] == '\\');

    switch (text[from]) {
        'x' => {
            assert(from + 1 <= text.len);

            return if (hex_count(text, from + 1, 2) == 2) 3 else null;
        },
        'u' => return unicode_width(text, from),
        '0' => {
            const next = if (from + 1 < text.len) text[from + 1] else 0;

            if (templated) {
                if (std.ascii.isDigit(next)) return null;
            }

            return 1;
        },
        '1'...'9' => return if (templated) null else 1,
        else => return 1,
    }
}

fn unicode_width(text: []const u8, from: usize) ?usize {
    assert(from < text.len);
    assert(text[from] == 'u');

    if (from + 1 >= text.len) return null;

    if (text[from + 1] != '{') {
        assert(from + 1 < text.len);

        return if (hex_count(text, from + 1, 4) == 4) 5 else null;
    }

    const digits = hex_count(text, from + 2, text.len);
    const close = from + 2 + digits;

    if (digits == 0) return null;
    if (close >= text.len) return null;
    if (text[close] != '}') return null;

    const value = std.fmt.parseInt(u32, text[from + 2 .. close], 16) catch return null;
    if (value > 0x10ffff) return null;
    assert(close + 1 - from <= text.len);

    return close + 1 - from;
}

fn hex_count(text: []const u8, from: usize, limit: usize) usize {
    assert(text.len <= std.math.maxInt(u32));
    assert(from < std.math.maxInt(u32));

    var count: usize = 0;

    assert(limit > 0);

    while (count < limit) : (count += 1) {
        if (from + count >= text.len) break;
        if (!std.ascii.isHex(text[from + count])) break;
    }

    assert(count <= limit);

    return count;
}

fn opens_a_substitution(source: []const u8, offset: u32) bool {
    assert(offset < source.len);

    if (source[offset] != '$') return false;
    if (offset + 1 >= source.len) return false;
    return source[offset + 1] == '{';
}

fn literal_end(source: []const u8, from: u32) u32 {
    assert(source[from] != '`');

    const limit: u32 = @intCast(source.len);
    var offset = from;

    assert(from < limit);

    while (offset < limit) {
        const byte = source[offset];

        if (byte == '\\') {
            offset = @min(offset + 2, limit);

            continue;
        }

        if (byte == '`') break;
        if (opens_a_substitution(source, offset)) break;

        offset += 1;
    }

    assert(offset > from);
    assert(offset <= limit);

    return offset;
}
