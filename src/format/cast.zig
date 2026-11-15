const std = @import("std");
const assert = std.debug.assert;
const Token = @import("../syntax/token.zig");
const ascii_whitespace = @import("../text/scan.zig").ascii_whitespace;

pub fn commented(text: []const u8) bool {
    if (!std.mem.startsWith(u8, text, "/**")) return false;

    const inner = text[3..];
    const body = if (std.mem.endsWith(u8, inner, "*/")) inner[0 .. inner.len - 2] else inner;
    var words = std.mem.splitAny(u8, body, ascii_whitespace);

    assert(body.len <= inner.len);
    assert(text.len >= 3);

    for (0..body.len + 1) |_| {
        const word = words.next() orelse return false;
        if (word_casts(word)) return true;
    }

    return false;
}

fn word_casts(word: []const u8) bool {
    assert(word.len <= std.math.maxInt(u32));

    const prefix: []const u8 = if (std.mem.startsWith(u8, word, "@type")) "@type" else "@satisfies";
    if (!std.mem.startsWith(u8, word, prefix)) return false;

    const rest = word[prefix.len..];

    assert(rest.len < word.len);
    assert(prefix[0] == '@');

    return rest.len == 0 or rest[0] == '{';
}

pub fn opened(source: []const u8, tokens: []const Token, start: u32) u32 {
    assert(start < tokens.len);
    assert(tokens[start].end() <= source.len);

    if (!tokens[start].is_punctuation(.paren_open)) return start;

    var scan = start;

    for (0..start) |_| {
        scan -= 1;

        const token = tokens[scan];
        if (token.kind == .newline) continue;
        if (token.length == 0) continue;
        if (token.kind != .comment) return start;
        if (commented(token.text(source))) return scan;
        return start;
    }

    return start;
}

pub fn leads(source: []const u8, tokens: []const Token, open: u32) bool {
    assert(open < tokens.len);

    var scan = open;

    assert(tokens[open].end() <= source.len);

    for (0..open) |_| {
        scan -= 1;

        const token = tokens[scan];

        if (token.kind == .comment) {
            if (commented(token.text(source))) return true;

            continue;
        }

        if (token.kind == .newline) continue;
        if (token.length == 0) continue;
        return false;
    }

    return false;
}
