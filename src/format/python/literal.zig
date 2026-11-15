const std = @import("std");
const assert = std.debug.assert;
const Buffer = @import("../../stdx/bounded/buffer.zig");
const QuotePreference = @import("../python.zig").QuotePreference;
const scan = @import("../../text/scan.zig");

pub const Edges = struct {
    head: u32,
    tail: u32,
};

const Prefix = struct {
    written: [2]u8,
    count: u32,
};

const QuoteEdges = struct {
    at: u32,
    close: u32,
    quote: []const u8,
};

const Requoted = struct {
    prefix: []const u8,
    body: []const u8,
    quote: []const u8,
};

const Requoting = struct {
    quote: []const u8,
    body: []const u8,
    rewrites: bool,
};

const double = "\"";
const single = "'";
pub const triple_double = "\"\"\"";
pub const triple_single = "'''";

const pragma_prefixes = [_][]const u8{
    "flake8:",
    "isort:",
    "nosec",
    "pylint:",
    "pyrefly:",
    "pyright:",
    "ruff:",
    "ty:",
    "type:",
};

pub fn body_edges(text: []const u8) ?Edges {
    assert(text.len <= std.math.maxInt(u32));

    const prefix = prefix_of(text);
    if (prefix == text.len) return null;

    const quote = text[prefix];
    const quoting = quote == '"' or quote == '\'';
    if (!quoting) return null;

    const run = [3]u8{ quote, quote, quote };
    const width: u32 = if (std.mem.startsWith(u8, text[prefix..], &run)) 3 else 1;
    const head = prefix + width;

    assert(text.len >= width);

    const tail: u32 = @intCast(text.len - width);
    if (tail < head) return null;
    if (std.mem.findNone(u8, text[tail..], run[0..1]) != null) return null;

    assert(head <= tail);

    return .{ .head = head, .tail = tail };
}

pub fn body_escaped(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    const edges = body_edges(text) orelse return false;

    assert(edges.head <= edges.tail);
    assert(edges.tail <= text.len);

    var escaping = false;

    for (text[edges.head..edges.tail]) |byte| {
        if (byte == '\n') {
            if (escaping) return true;
        }

        switch (byte) {
            ' ', '\t', 0x0c => {},
            else => escaping = byte == '\\',
        }
    }

    return false;
}

pub fn body_indent(body: []const u8) ?u32 {
    assert(body.len <= std.math.maxInt(u32));

    var common: ?u32 = null;
    var pieces = std.mem.splitScalar(u8, body, '\n');

    _ = pieces.first();

    for (0..body.len) |_| {
        const line = pieces.next() orelse break;
        const stripped = std.mem.trimStart(u8, line, scan.ascii_whitespace);
        if (stripped.len == 0) continue;

        const indent: u32 = @intCast(line.len - stripped.len);

        common = if (common) |held| @min(held, indent) else indent;
    }

    if (common) |held| assert(held < body.len);

    return common;
}

pub fn ending_of(body: []const u8, first: []const u8, common: ?u32) ?u8 {
    assert(body.len <= std.math.maxInt(u32));
    if (common) |held| assert(held < std.math.maxInt(u32));
    assert(first.len <= std.math.maxInt(u32));

    const indent = common orelse {
        if (first.len == 0) return null;

        assert(first.len > 0);

        return first[first.len - 1];
    };
    const newline = std.mem.findScalarLast(u8, body, '\n') orelse return null;
    const last = body[newline + 1 ..];
    const kept = if (indent <= last.len) last[indent..] else last[last.len..];
    const trimmed = std.mem.trimEnd(u8, kept, scan.ascii_whitespace);

    assert(trimmed.len <= last.len);

    if (trimmed.len == 0) return null;
    assert(trimmed[trimmed.len - 1] < std.math.maxInt(u8));

    return trimmed[trimmed.len - 1];
}

pub fn settled(text: []const u8, head: u32, last: ?u8, preference: QuotePreference) u8 {
    assert(head > 0);
    assert(head <= text.len);

    const written = text[head - 1];

    const wanted: u8 = switch (preference) {
        .double => '"',
        .preserve => return written,
        .single => '\'',
    };

    if (written == wanted) {
        assert(written < std.math.maxInt(u8));

        return written;
    }

    if (last == wanted) {
        assert(written < std.math.maxInt(u8));

        return written;
    }

    const run = [3]u8{ written, written, written };
    const triple = head >= 3 and std.mem.eql(u8, text[head - 3 .. head], &run);
    const width: u32 = if (triple) 3 else 1;

    assert(text.len >= width);

    const stop = text.len - width;

    if (head > stop) {
        assert(written < std.math.maxInt(u8));

        return written;
    }

    if (settled_clashes(text[head..stop], wanted, triple)) {
        assert(written < std.math.maxInt(u8));

        return written;
    }

    return wanted;
}

fn settled_clashes(body: []const u8, wanted: u8, triple: bool) bool {
    assert(body.len <= std.math.maxInt(u32));
    assert(wanted == '"' or wanted == '\'');

    if (triple) {
        const tripled_wanted = std.mem.find(u8, body, &.{ wanted, wanted, wanted }) != null;
        const escaped_wanted = std.mem.find(u8, body, &.{ '\\', wanted }) != null;

        return tripled_wanted or escaped_wanted;
    }

    const held_wanted = std.mem.findScalar(u8, body, wanted) != null;
    const held_slash = std.mem.findScalar(u8, body, '\\') != null;

    return held_wanted or held_slash;
}

pub fn odd_slashes(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    const kept = std.mem.trimEnd(u8, text, "\\");
    const slashes = text.len - kept.len;

    assert(slashes <= text.len);
    if (slashes > 0) assert(text[text.len - 1] == '\\');

    return slashes % 2 == 1;
}

fn quoted(bytes: []const u8, wanted: u8) ?u32 {
    assert(bytes.len <= std.math.maxInt(u32));
    assert(wanted == '"' or wanted == '\'');

    const offset = std.mem.findAny(u8, bytes, "\"'") orelse return null;
    if (bytes[offset] == wanted) return null;

    assert(bytes[offset] == other_quote(wanted));

    return @intCast(offset);
}

pub fn requoted(bytes: []const u8, preference: QuotePreference) ?Requoted {
    if (preference == .preserve) return null;
    assert(bytes.len <= std.math.maxInt(u32));

    const wanted = preference.byte();
    const at = quoted(bytes, wanted) orelse return null;
    const prefix = bytes[0..at];
    const rest = bytes[at..];
    const tripled_single = std.mem.startsWith(u8, rest, triple_single);
    const tripled_double = std.mem.startsWith(u8, rest, triple_double);
    const triple = tripled_single or tripled_double;
    const quote = requoted_quote(wanted, triple);
    const width = quote.len;
    if (rest.len < width * 2) return null;

    const body = rest[width .. rest.len - width];
    if (requoted_clashes(body, rest[0], quote, triple)) return null;

    assert(prefix.len + body.len + width * 2 == bytes.len);

    return .{ .prefix = prefix, .body = body, .quote = quote };
}

fn requoted_quote(wanted: u8, triple: bool) []const u8 {
    assert(wanted == '"' or wanted == '\'');

    const quote: []const u8 = if (wanted == '"')
        (if (triple) triple_double else double)
    else
        (if (triple) triple_single else single);

    assert(quote[0] == wanted);

    return quote;
}

fn requoted_clashes(body: []const u8, held: u8, quote: []const u8, triple: bool) bool {
    assert(quote.len > 0);
    assert(held != quote[0]);
    assert(body.len <= std.math.maxInt(u32));

    const wanted = quote[0];

    if (triple) {
        const ends_wanted = std.mem.endsWith(u8, body, &.{wanted});
        const holds_quote = std.mem.find(u8, body, quote) != null;
        const escapes_wanted = std.mem.find(u8, body, &.{ '\\', wanted }) != null;

        return ends_wanted or holds_quote or escapes_wanted;
    }

    const holds_wanted = std.mem.findScalar(u8, body, wanted) != null;
    const escapes_held = std.mem.find(u8, body, &.{ '\\', held }) != null;

    return holds_wanted or escapes_held;
}

pub fn prefix_of(bytes: []const u8) u32 {
    assert(bytes.len <= std.math.maxInt(u32));

    var held: u32 = 0;

    for (bytes) |byte| {
        if (!std.ascii.isAlphabetic(byte)) break;

        held += 1;
    }

    assert(held <= bytes.len);
    if (held < bytes.len) assert(!std.ascii.isAlphabetic(bytes[held]));

    return held;
}

pub fn prefix_written(prefix: []const u8) Prefix {
    assert(prefix.len <= std.math.maxInt(u32));

    var held: Prefix = .{ .written = .{ 0, 0 }, .count = 0 };

    if (std.mem.findAny(u8, prefix, "Rr")) |at| {
        held.written[held.count] = prefix[at];
        held.count += 1;
    }

    if (std.mem.findAny(u8, prefix, "BFTbft")) |at| {
        held.written[held.count] = std.ascii.toLower(prefix[at]);
        held.count += 1;
    }

    assert(held.count <= held.written.len);
    assert(held.count <= prefix.len);

    return held;
}

fn escape_width(bytes: []const u8, offset: u32, unicode: bool) u32 {
    assert(offset < bytes.len);
    assert(bytes[offset] == '\\');

    const marker = scan.byte_at(bytes, offset + 1) orelse return 0;
    if (marker == 'N') return if (unicode) named_width(bytes, offset) else 0;

    const digits: u32 = switch (marker) {
        'U' => if (unicode) 8 else return 0,
        'u' => if (unicode) 4 else return 0,
        'x' => 2,
        else => return 0,
    };

    const end = offset +| 2 +| digits;
    if (end > bytes.len) return 0;

    for (bytes[offset + 2 .. end]) |byte| {
        if (!std.ascii.isHex(byte)) return 0;
    }

    assert(end - offset <= 10);

    return end - offset;
}

fn named_width(bytes: []const u8, offset: u32) u32 {
    assert(offset + 1 < bytes.len);
    assert(bytes[offset + 1] == 'N');

    const open = offset + 2;
    if (scan.byte_at(bytes, open) != '{') return 0;

    var at = open + 1;

    while (at < bytes.len) : (at += 1) {
        const byte = bytes[at];

        if (byte == '}') {
            if (at - open < 3) return 0;
            assert(at + 1 - offset <= bytes.len);

            return at + 1 - offset;
        }

        const named = std.ascii.isAlphanumeric(byte) or byte == ' ' or byte == '-';
        if (!named) return 0;
    }

    return 0;
}

pub fn pragmatic(bytes: []const u8) bool {
    assert(bytes.len <= std.math.maxInt(u32));

    if (!std.mem.startsWith(u8, bytes, "#")) return false;

    const rest = std.mem.trimStart(u8, bytes[1..], " \t");

    assert(rest.len < bytes.len);

    if (std.ascii.startsWithIgnoreCase(rest, "noqa")) return true;

    for (pragma_prefixes) |prefix| {
        if (std.mem.startsWith(u8, rest, prefix)) return true;
    }

    return false;
}

pub fn other_quote(quote: u8) u8 {
    assert(quote == '"' or quote == '\'');

    const other: u8 = if (quote == '"') '\'' else '"';

    assert(other != quote);
    assert(other == '"' or other == '\'');

    return other;
}

pub fn preferring(quote: u8) QuotePreference {
    assert(quote != 0);

    const preference: QuotePreference = if (quote == '"') .double else .single;

    if (preference == .single) assert(quote != '"');

    return preference;
}

pub fn relettered(
    out: *Buffer,
    bytes: []const u8,
    preference: QuotePreference,
) error{Overflow}!void {
    assert(bytes.len <= std.math.maxInt(u32));

    const at = prefix_of(bytes);
    const marks = bytes[0..at];
    const prefix = prefix_written(marks);
    const raw = std.mem.findAny(u8, marks, "Rr") != null;
    const format = std.mem.findAny(u8, marks, "FTft") != null;
    const unicode = std.mem.findAny(u8, marks, "Bb") == null;
    const start = out.count();

    assert(prefix.count <= marks.len);
    if (raw) assert(prefix.count > 0);

    try out.push(prefix.written[0..prefix.count]);

    if (requoting(bytes[at..], raw, format, preference)) |parts| {
        try out.push(parts.quote);

        if (parts.rewrites) {
            try quoted_body(out, parts.body, parts.quote[0], unicode);
        } else {
            try escaped(out, parts.body, raw, unicode);
        }

        try out.push(parts.quote);
    } else {
        try escaped(out, bytes[at..], raw, unicode);
    }

    assert(out.count() - start == relettered_length(bytes, preference));
}

pub fn relettered_length(bytes: []const u8, preference: QuotePreference) u32 {
    assert(bytes.len <= std.math.maxInt(u32));

    const at = prefix_of(bytes);
    const marks = bytes[0..at];
    const prefix = prefix_written(marks);
    const raw = std.mem.findAny(u8, marks, "Rr") != null;
    const format = std.mem.findAny(u8, marks, "FTft") != null;
    const unicode = std.mem.findAny(u8, marks, "Bb") == null;
    const rest: u32 = @intCast(bytes.len - at);
    const parts = requoting(bytes[at..], raw, format, preference) orelse {
        assert(prefix.count + rest < std.math.maxInt(u32));

        return prefix.count + rest;
    };
    const quotes: u32 = @intCast(parts.quote.len * 2);

    const body: u32 = if (parts.rewrites)
        quoted_body_length(parts.body, parts.quote[0], unicode)
    else
        @intCast(parts.body.len);

    assert(prefix.count + quotes + body < std.math.maxInt(u32));

    return prefix.count + quotes + body;
}

pub fn unescaped(body: []const u8, quote: u8) bool {
    assert(body.len <= std.math.maxInt(u32));

    var held: usize = 0;

    for (0..body.len) |_| {
        if (held >= body.len) break;

        if (body[held] == '\\') {
            held += 2;

            continue;
        }

        if (body[held] == quote) return true;

        held += 1;
    }

    assert(held >= body.len);
    assert(held <= body.len + 1);

    return false;
}

pub fn escapes_of(body: []const u8, quote: u8) u32 {
    assert(body.len <= std.math.maxInt(u32));
    assert(quote == '"' or quote == '\'');

    const other = other_quote(quote);
    var count: u32 = 0;
    var held: usize = 0;

    for (0..body.len) |_| {
        if (held >= body.len) break;

        if (body[held] != '\\') {
            count += @intFromBool(body[held] == quote);
            held += 1;

            continue;
        }

        const next: ?u8 = if (held + 1 < body.len) body[held + 1] else null;

        count += @intFromBool(next != other);
        held += 2;
    }

    assert(held >= body.len);
    assert(count <= body.len);

    return count;
}

pub fn quoted_body(
    out: *Buffer,
    body: []const u8,
    quote: u8,
    unicode: bool,
) error{Overflow}!void {
    assert(body.len <= std.math.maxInt(u32));
    assert(quote == '"' or quote == '\'');

    const other = other_quote(quote);
    const start = out.count();
    var held: usize = 0;

    for (0..body.len) |_| {
        if (held >= body.len) break;

        if (body[held] != '\\') {
            if (body[held] == quote) try out.push("\\");

            try out.push(body[held .. held + 1]);
            held += 1;

            continue;
        }

        const width = escape_width(body, @intCast(held), unicode);

        if (width > 0) {
            try escape_normalized(out, body[held..][0..width]);
            held += width;

            continue;
        }

        if (held + 1 == body.len) {
            try out.push("\\");
            held += 1;

            break;
        }

        if (body[held + 1] == other) {
            try out.push(body[held + 1 .. held + 2]);
        } else {
            try out.push(body[held .. held + 2]);
        }

        held += 2;
    }

    assert(held == body.len);
    assert(out.count() - start == quoted_body_length(body, quote, unicode));
}

pub fn quoted_body_length(body: []const u8, quote: u8, unicode: bool) u32 {
    assert(body.len <= std.math.maxInt(u32));
    assert(quote == '"' or quote == '\'');

    const other = other_quote(quote);
    var held: usize = 0;
    var length: u32 = 0;

    for (0..body.len) |_| {
        if (held >= body.len) break;

        if (body[held] != '\\') {
            length += 1 + @as(u32, @intFromBool(body[held] == quote));
            held += 1;

            continue;
        }

        const width = escape_width(body, @intCast(held), unicode);

        if (width > 0) {
            length += width;
            held += width;

            continue;
        }

        if (held + 1 == body.len) {
            length += 1;
            held += 1;

            break;
        }

        length += if (body[held + 1] == other) 1 else 2;
        held += 2;
    }

    assert(held == body.len);

    return length;
}

fn escape_normalized(out: *Buffer, escape: []const u8) error{Overflow}!void {
    assert(escape.len > 2);
    assert(escape[0] == '\\');

    const named = escape[1] == 'N';

    try out.push(escape[0..2]);

    for (escape[2..]) |byte| {
        try out.push_byte(if (named) std.ascii.toUpper(byte) else std.ascii.toLower(byte));
    }
}

fn requoting(
    rest: []const u8,
    raw: bool,
    format: bool,
    preference: QuotePreference,
) ?Requoting {
    if (preference == .preserve) return null;

    const wanted = preference.byte();

    if (rest.len < 2) return null;
    if (std.mem.startsWith(u8, rest, triple_double)) return tripled(rest, wanted, format);
    if (std.mem.startsWith(u8, rest, triple_single)) return tripled(rest, wanted, format);

    const opening = rest[0];
    const quoting = opening == '"' or opening == '\'';
    if (!quoting) return null;

    const body = rest[1 .. rest.len - 1];
    if (raw) return requoting_raw(opening, body, wanted);

    const held = escapes_of(body, wanted);
    const alone = escapes_of(body, other_quote(wanted));
    const quote = requoting_quote(opening, wanted, held, alone);
    const clashes = format and quote != opening and std.mem.findScalar(u8, body, quote) != null;
    if (clashes) return null;

    const written: []const u8 = if (quote == '"') double else single;

    assert(written[0] == quote);

    return .{ .quote = written, .body = body, .rewrites = true };
}

fn requoting_raw(opening: u8, body: []const u8, wanted: u8) ?Requoting {
    assert(opening == '"' or opening == '\'');
    assert(wanted == '"' or wanted == '\'');

    if (opening == wanted) return null;
    if (unescaped(body, wanted)) return null;

    const written: []const u8 = if (wanted == '"') double else single;
    return .{ .quote = written, .body = body, .rewrites = false };
}

fn requoting_quote(opening: u8, wanted: u8, held: u32, alone: u32) u8 {
    assert(opening == '"' or opening == '\'');
    assert(wanted == '"' or wanted == '\'');

    const other = other_quote(wanted);

    if (opening == wanted) {
        if (alone < held) return other;
        return wanted;
    }

    if (held <= alone) return wanted;
    return other;
}

fn fielded_quote(body: []const u8, wanted: u8) bool {
    assert(body.len <= std.math.maxInt(u32));

    var depth: u32 = 0;
    var held: usize = 0;
    var quotes: u32 = 0;

    for (0..body.len) |_| {
        if (held >= body.len) break;

        const byte = body[held];

        if (depth > 0) {
            depth -= @intFromBool(byte == '}');
            depth += @intFromBool(byte == '{');
            held += 1;

            continue;
        }

        const doubled = byte == '{' and held + 1 < body.len and body[held + 1] == '{';
        const skips = byte == '\\' or doubled;

        if (skips) {
            held += 2;
            quotes = 0;

            continue;
        }

        if (byte == '{') {
            if (quotes > 0) return true;

            depth = 1;
            held += 1;

            continue;
        }

        quotes = if (byte == wanted) quotes + 1 else 0;
        held += 1;
    }

    assert(held >= body.len);
    assert(quotes <= body.len);

    return false;
}

fn tripled(rest: []const u8, wanted: u8, format: bool) ?Requoting {
    assert(wanted == '"' or wanted == '\'');

    const quote: []const u8 = if (wanted == '"') triple_double else triple_single;
    if (std.mem.startsWith(u8, rest, quote)) return null;
    if (rest.len < 6) return null;

    const body = rest[3 .. rest.len - 3];
    if (std.mem.endsWith(u8, body, &.{wanted})) return null;
    if (std.mem.find(u8, body, quote) != null) return null;

    if (format) {
        if (fielded_quote(body, wanted)) return null;
    }

    assert(body.len + 6 == rest.len);

    return .{ .quote = quote, .body = body, .rewrites = false };
}

fn escaped(out: *Buffer, bytes: []const u8, raw: bool, unicode: bool) error{Overflow}!void {
    assert(bytes.len <= std.math.maxInt(u32));

    if (raw) return out.push(bytes);

    var held: usize = 0;

    for (0..bytes.len) |_| {
        if (held >= bytes.len) break;

        if (bytes[held] != '\\') {
            try out.push(bytes[held .. held + 1]);
            held += 1;

            continue;
        }

        const width = escape_width(bytes, @intCast(held), unicode);

        if (width == 0) {
            const step = @min(2, bytes.len - held);

            try out.push(bytes[held .. held + step]);
            held += step;

            continue;
        }

        try escape_normalized(out, bytes[held..][0..width]);
        held += width;
    }

    assert(held == bytes.len);
}

fn mantissa(out: *Buffer, bytes: []const u8) error{Overflow}!void {
    assert(bytes.len <= std.math.maxInt(u32));

    const at = std.mem.findScalar(u8, bytes, '.') orelse return out.push(bytes);
    const before = bytes[0..at];
    const after = bytes[at..];
    const leading: []const u8 = if (before.len == 0) "0" else before;
    const trailing: []const u8 = if (after.len == 1) "0" else after[1..];

    assert(after[0] == '.');
    assert(leading.len > 0);

    try out.push(leading);
    try out.push(".");
    try out.push(trailing);
}

pub fn numbered(out: *Buffer, bytes: []const u8) error{Overflow}!void {
    assert(bytes.len <= std.math.maxInt(u32));

    const based = bytes.len > 2 and bytes[0] == '0' and std.ascii.isAlphabetic(bytes[1]);
    if (based) return numbered_based(out, bytes);

    const last: ?u8 = if (bytes.len == 0) null else bytes[bytes.len - 1];
    const complex = last == 'J' or last == 'j';
    const body = if (complex) bytes[0 .. bytes.len - 1] else bytes;
    const suffix: []const u8 = if (complex) "j" else "";

    assert(body.len + suffix.len == bytes.len);

    const at = std.mem.findAny(u8, body, "Ee") orelse {
        try mantissa(out, body);

        return out.push(suffix);
    };

    const held = body[at + 1 ..];
    const exponent = if (std.mem.startsWith(u8, held, "+")) held[1..] else held;

    try mantissa(out, body[0..at]);
    try out.push("e");
    try out.push(exponent);
    try out.push(suffix);
}

fn numbered_based(out: *Buffer, bytes: []const u8) error{Overflow}!void {
    assert(bytes.len > 2);
    assert(bytes[0] == '0');

    const marker = bytes[1];
    const upper = marker == 'X' or marker == 'x';

    try out.push(&.{ '0', std.ascii.toLower(marker) });

    for (bytes[2..]) |byte| {
        try out.push_byte(if (upper) std.ascii.toUpper(byte) else byte);
    }
}

pub fn quote_edges(bytes: []const u8, offset: u32, preference: QuotePreference) ?QuoteEdges {
    assert(bytes.len <= std.math.maxInt(u32));
    assert(offset < std.math.maxInt(u32));
    if (preference == .preserve) return null;

    const parts = requoted(bytes, preference) orelse return null;
    const at = offset + @as(u32, @intCast(parts.prefix.len));
    const close = at + @as(u32, @intCast(parts.quote.len + parts.body.len));

    assert(close > at);
    assert(close - at < bytes.len);

    return .{ .at = at, .close = close, .quote = parts.quote };
}

test "a body edge sits past the prefix and inside the quotes" {
    try std.testing.expectEqual(@as(?Edges, .{ .head = 5, .tail = 6 }), body_edges("rb'''x'''"));
    try std.testing.expectEqual(@as(?Edges, .{ .head = 1, .tail = 2 }), body_edges("'x'"));
    try std.testing.expectEqual(@as(?Edges, .{ .head = 1, .tail = 1 }), body_edges("''"));
    try std.testing.expectEqual(@as(?Edges, null), body_edges("abc"));
    try std.testing.expectEqual(@as(?Edges, null), body_edges("'x\""));
}

test "a backslash ahead of a line break marks the body escaped" {
    try std.testing.expect(body_escaped("'''a\\\nb'''"));
    try std.testing.expect(body_escaped("'''a\\ \nb'''"));
    try std.testing.expect(!body_escaped("'''a\nb'''"));
    try std.testing.expect(!body_escaped("abc"));
}

test "a body indent is the narrowest indent past the first line" {
    try std.testing.expectEqual(@as(?u32, 2), body_indent("first\n    a\n  b\n"));
    try std.testing.expectEqual(@as(?u32, null), body_indent("only"));
    try std.testing.expectEqual(@as(?u32, null), body_indent("first\n   \n"));
}

test "an ending reads the last line past the common indent" {
    try std.testing.expectEqual(@as(?u8, '.'), ending_of("x\n  y \n  z.", "x", 2));
    try std.testing.expectEqual(@as(?u8, 't'), ending_of("body", "first", null));
    try std.testing.expectEqual(@as(?u8, null), ending_of("no newline", "f", 0));
    try std.testing.expectEqual(@as(?u8, null), ending_of("x", "", null));
}

test "a settled quote keeps the written one when the wanted one clashes" {
    try std.testing.expectEqual(@as(u8, '\''), settled("'it\"s'", 1, null, .double));
    try std.testing.expectEqual(@as(u8, '"'), settled("'its'", 1, null, .double));
    try std.testing.expectEqual(@as(u8, '\''), settled("'its'", 1, '"', .double));
    try std.testing.expectEqual(@as(u8, '\''), settled("'its'", 1, null, .preserve));
    try std.testing.expectEqual(@as(u8, '"'), settled("'''a''b'''", 3, null, .double));
    try std.testing.expectEqual(@as(u8, '\''), settled("'''a\"\"\"b'''", 3, null, .double));
    try std.testing.expectEqual(@as(u8, '\''), settled("\"it\"", 1, null, .single));
    try std.testing.expectEqual(@as(u8, '\''), settled("'a\\b'", 1, null, .double));
}

test "an odd run of trailing backslashes escapes what follows" {
    try std.testing.expect(odd_slashes("a\\"));
    try std.testing.expect(!odd_slashes("a\\\\"));
    try std.testing.expect(!odd_slashes(""));
}

test "a requote swaps the quote unless the body clashes with it" {
    const expect = std.testing.expectEqualDeep;

    try expect(@as(?Requoted, .{ .prefix = "", .body = "abc", .quote = double }), requoted(
        "'abc'",
        .double,
    ));

    try expect(@as(?Requoted, .{ .prefix = "b", .body = "abc", .quote = double }), requoted(
        "b'abc'",
        .double,
    ));

    try expect(@as(?Requoted, .{ .prefix = "", .body = "abc", .quote = triple_double }), requoted(
        "'''abc'''",
        .double,
    ));

    try expect(@as(?Requoted, .{ .prefix = "", .body = "abc", .quote = single }), requoted(
        "\"abc\"",
        .single,
    ));

    try expect(@as(?Requoted, null), requoted("'a\"c'", .double));
    try expect(@as(?Requoted, null), requoted("\"abc\"", .double));
    try expect(@as(?Requoted, null), requoted("'abc'", .preserve));
    try expect(@as(?Requoted, null), requoted("'''ab\"'''", .double));
    try expect(@as(?Requoted, null), requoted("'a\\'b'", .double));
    try expect(@as(?Requoted, null), requoted("x", .double));
    try expect(@as(?Requoted, null), requoted("'", .double));
}

test "quote edges cover the requoted quote and body" {
    const expect = std.testing.expectEqualDeep;

    try expect(@as(?QuoteEdges, .{ .at = 11, .close = 15, .quote = double }), quote_edges(
        "b'abc'",
        10,
        .double,
    ));

    try expect(@as(?QuoteEdges, .{ .at = 4, .close = 10, .quote = triple_double }), quote_edges(
        "'''abc'''",
        4,
        .double,
    ));

    try expect(@as(?QuoteEdges, null), quote_edges("\"abc\"", 0, .double));
}

test "a prefix keeps its raw letter and lowers its kind letter" {
    const raw_bytes = prefix_written("Rb");
    const swapped = prefix_written("BR");
    const plain = prefix_written("u");
    const format = prefix_written("F");

    try std.testing.expectEqual(@as(u32, 2), prefix_of("Rb'x'"));
    try std.testing.expectEqual(@as(u32, 0), prefix_of("'x'"));
    try std.testing.expectEqualStrings("Rb", raw_bytes.written[0..raw_bytes.count]);
    try std.testing.expectEqualStrings("Rb", swapped.written[0..swapped.count]);
    try std.testing.expectEqual(@as(u32, 0), plain.count);
    try std.testing.expectEqualStrings("f", format.written[0..format.count]);
}

test "an escape width counts the hexadecimal digits it carries" {
    try std.testing.expectEqual(@as(u32, 4), escape_width("\\x41", 0, true));
    try std.testing.expectEqual(@as(u32, 6), escape_width("\\u00e9", 0, true));
    try std.testing.expectEqual(@as(u32, 10), escape_width("\\U0001F600", 0, true));
    try std.testing.expectEqual(@as(u32, 0), escape_width("\\x4", 0, true));
    try std.testing.expectEqual(@as(u32, 0), escape_width("\\xZZ", 0, true));
    try std.testing.expectEqual(@as(u32, 0), escape_width("\\n", 0, true));
    try std.testing.expectEqual(@as(u32, 4), escape_width("\\x41", 0, false));
    try std.testing.expectEqual(@as(u32, 0), escape_width("\\u00e9", 0, false));
    try std.testing.expectEqual(@as(u32, 0), escape_width("\\U0001F600", 0, false));
}

test "a named escape spans its braces and only outside bytes" {
    try std.testing.expectEqual(@as(u32, 8), escape_width("\\N{DASH}", 0, true));
    try std.testing.expectEqual(@as(u32, 25), escape_width("\\N{greek small letter pi}", 0, true));
    try std.testing.expectEqual(@as(u32, 0), escape_width("\\N{DASH}", 0, false));
    try std.testing.expectEqual(@as(u32, 0), escape_width("\\N{A}", 0, true));
    try std.testing.expectEqual(@as(u32, 0), escape_width("\\N{DA_SH}", 0, true));
    try std.testing.expectEqual(@as(u32, 0), escape_width("\\N{DASH", 0, true));
    try std.testing.expectEqual(@as(u32, 0), escape_width("\\NDASH", 0, true));
}

test "a pragmatic comment names a tool the formatter leaves alone" {
    try std.testing.expect(pragmatic("# noqa"));
    try std.testing.expect(pragmatic("#NOQA: E501"));
    try std.testing.expect(pragmatic("#  type: ignore"));
    try std.testing.expect(pragmatic("# pylint: disable"));
    try std.testing.expect(pragmatic("# nosec B602, B607"));
    try std.testing.expect(pragmatic("# nosecurity"));
    try std.testing.expect(pragmatic("# pyrefly: ignore"));
    try std.testing.expect(pragmatic("# ty: ignore[unresolved-import]"));
    try std.testing.expect(!pragmatic("# fmt: off"));
    try std.testing.expect(!pragmatic("# NOSEC"));
    try std.testing.expect(!pragmatic("# Type: int"));
    try std.testing.expect(!pragmatic("# mypy: ignore"));
    try std.testing.expect(!pragmatic("# tyx: ignore"));
    try std.testing.expect(!pragmatic("noqa"));
}

test "the quote helpers agree on every preference" {
    try std.testing.expectEqual(@as(u8, '\''), other_quote('"'));
    try std.testing.expectEqual(@as(u8, '"'), other_quote('\''));
    try std.testing.expectEqual(QuotePreference.double, preferring('"'));
    try std.testing.expectEqual(QuotePreference.single, preferring('\''));
    try std.testing.expectEqual(@as(u8, '"'), QuotePreference.double.byte());
    try std.testing.expectEqual(@as(u8, 0), QuotePreference.preserve.byte());
    try std.testing.expectEqual(@as(u8, '\''), QuotePreference.single.byte());
}

test "a relettered string lowers its kind letter and swaps its quote" {
    var out: Buffer = try .init(std.testing.allocator, 64);
    defer out.deinit(std.testing.allocator);

    const cases = [_]struct { []const u8, QuotePreference, []const u8 }{
        .{ "Rb'x'", .double, "Rb\"x\"" },
        .{ "F'a\\'b'", .double, "f\"a'b\"" },
        .{ "U'x'", .preserve, "'x'" },
        .{ "'''x'''", .double, "\"\"\"x\"\"\"" },
        .{ "'say \"hi\"'", .double, "'say \"hi\"'" },
    };

    for (cases) |case| {
        out.clear();

        try relettered(&out, case[0], case[1]);
        try std.testing.expectEqualStrings(case[2], out.const_slice());
    }
}

test "an escape count skips the escapes of the other quote" {
    try std.testing.expect(!unescaped("a\\\"b", '"'));
    try std.testing.expect(unescaped("a\"b", '"'));
    try std.testing.expectEqual(@as(u32, 2), escapes_of("a\"b\\'c\\\"", '"'));
}

test "a quoted body escapes the new quote and drops the old escape" {
    var out: Buffer = try .init(std.testing.allocator, 64);
    defer out.deinit(std.testing.allocator);

    const cases = [_]struct { []const u8, []const u8 }{
        .{ "say \"hi\"", "say \\\"hi\\\"" },
        .{ "a\\'b", "a'b" },
        .{ "\\xAB", "\\xab" },
        .{ "ab\\", "ab\\" },
        .{ "\\n", "\\n" },
    };

    for (cases) |case| {
        out.clear();

        try quoted_body(&out, case[0], '"', true);
        try std.testing.expectEqualStrings(case[1], out.const_slice());
    }
}

test "a requoting picks the quote that needs the fewer escapes" {
    const held = "a\"\\'\\'";

    const found = [_]struct { []const u8, bool, Requoting }{
        .{ "'it'", false, .{ .quote = double, .body = "it", .rewrites = true } },
        .{ "'say \"hi\"'", false, .{ .quote = single, .body = "say \"hi\"", .rewrites = true } },
        .{ "\"a\"", false, .{ .quote = double, .body = "a", .rewrites = true } },
        .{ "'" ++ held ++ "'", false, .{ .quote = double, .body = held, .rewrites = true } },
        .{ "'''x'''", false, .{ .quote = triple_double, .body = "x", .rewrites = false } },
        .{ "'x'", true, .{ .quote = double, .body = "x", .rewrites = false } },
    };

    for (found) |case| {
        const result = requoting(case[0], case[1], false, .double);

        try std.testing.expectEqualDeep(@as(?Requoting, case[2]), result);
    }

    try std.testing.expectEqual(@as(?Requoting, null), requoting("\"a\"", true, false, .double));
    try std.testing.expectEqual(@as(?Requoting, null), requoting("'x\"'", true, false, .double));
    try std.testing.expectEqual(@as(?Requoting, null), requoting("x", false, false, .double));
    try std.testing.expectEqual(@as(?Requoting, null), requoting("'x'", false, false, .preserve));

    const clashing = requoting("'" ++ held ++ "'", false, true, .double);

    try std.testing.expectEqual(@as(?Requoting, null), clashing);
}

test "a field quote counts the quotes ahead of a replacement field" {
    try std.testing.expect(fielded_quote("a\"{x}", '"'));
    try std.testing.expect(!fielded_quote("a{x}\"", '"'));
    try std.testing.expect(!fielded_quote("\"{{x}}", '"'));
}

test "a tripled string takes the wanted triple quote" {
    const fielded = "'''a\"{x}'''";
    const plain = tripled("'''abc'''", '"', false);
    const loose = tripled(fielded, '"', false);

    try std.testing.expectEqualDeep(@as(?Requoting, .{
        .quote = triple_double,
        .body = "abc",
        .rewrites = false,
    }), plain);

    try std.testing.expectEqualDeep(@as(?Requoting, .{
        .quote = triple_double,
        .body = "a\"{x}",
        .rewrites = false,
    }), loose);

    try std.testing.expectEqual(@as(?Requoting, null), tripled("\"\"\"abc\"\"\"", '"', false));
    try std.testing.expectEqual(@as(?Requoting, null), tripled("'''ab\"'''", '"', false));
    try std.testing.expectEqual(@as(?Requoting, null), tripled(fielded, '"', true));
}

test "an escape keeps its backslash and lowers its digits" {
    var out: Buffer = try .init(std.testing.allocator, 64);
    defer out.deinit(std.testing.allocator);

    try escaped(&out, "a\\XB\\xAB\\", false, true);
    try std.testing.expectEqualStrings("a\\XB\\xab\\", out.const_slice());

    out.clear();

    try escaped(&out, "\\xAB", true, true);
    try std.testing.expectEqualStrings("\\xAB", out.const_slice());

    out.clear();
    try escaped(&out, "\\N{em dash}\\uABCD", false, true);
    try std.testing.expectEqualStrings("\\N{EM DASH}\\uabcd", out.const_slice());

    out.clear();
    try escaped(&out, "\\N{em dash}\\uABCD\\xAB", false, false);
    try std.testing.expectEqualStrings("\\N{em dash}\\uABCD\\xab", out.const_slice());
}

test "a number writes the zero on each side of a bare point and lowers its marks" {
    var out: Buffer = try .init(std.testing.allocator, 64);
    defer out.deinit(std.testing.allocator);

    const cases = [_]struct { []const u8, []const u8 }{
        .{ "0XABcd", "0xABCD" },
        .{ "0o17", "0o17" },
        .{ "0B101", "0b101" },
        .{ "1E+5", "1e5" },
        .{ "1.5J", "1.5j" },
        .{ ".5e-3j", "0.5e-3j" },
        .{ "10", "10" },
        .{ "0e5", "0e5" },
    };

    for (cases) |case| {
        out.clear();

        try numbered(&out, case[0]);
        try std.testing.expectEqualStrings(case[1], out.const_slice());
    }

    const mantissas = [_]struct { []const u8, []const u8 }{
        .{ ".5", "0.5" },
        .{ "5.", "5.0" },
        .{ "5", "5" },
        .{ "1.25", "1.25" },
    };

    for (mantissas) |case| {
        out.clear();

        try mantissa(&out, case[0]);
        try std.testing.expectEqualStrings(case[1], out.const_slice());
    }
}

test "a writer past its buffer reports the overflow" {
    const gpa = std.testing.allocator;
    var narrow: Buffer = try .init(gpa, 2);
    defer narrow.deinit(gpa);

    var short: Buffer = try .init(gpa, 3);
    defer short.deinit(gpa);

    try std.testing.expectError(error.Overflow, numbered(&narrow, "12345"));

    narrow.clear();

    try std.testing.expectError(error.Overflow, quoted_body(&narrow, "a\\'b", '"', true));
    try std.testing.expectError(error.Overflow, relettered(&short, "Rb'x'", .double));
}
