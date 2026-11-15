const std = @import("std");
const assert = std.debug.assert;

const Range = struct {
    first: u32,
    last: u32,
};

const ideograph_prefix = "CJK UNIFIED IDEOGRAPH-";

const ideograph_ranges = [_]Range{
    .{ .first = 0x3400, .last = 0x4dbf },
    .{ .first = 0x4e00, .last = 0x9fff },
    .{ .first = 0x20000, .last = 0x2a6df },
    .{ .first = 0x2a700, .last = 0x2b739 },
    .{ .first = 0x2b740, .last = 0x2b81d },
    .{ .first = 0x2b820, .last = 0x2cea1 },
    .{ .first = 0x2ceb0, .last = 0x2ebe0 },
    .{ .first = 0x2ebf0, .last = 0x2ee5d },
    .{ .first = 0x30000, .last = 0x3134a },
    .{ .first = 0x31350, .last = 0x323af },
};

const leading_jamo = [_][]const u8{
    "G",
    "GG",
    "N",
    "D",
    "DD",
    "R",
    "M",
    "B",
    "BB",
    "S",
    "SS",
    "",
    "J",
    "JJ",
    "C",
    "K",
    "T",
    "P",
    "H",
};

const name_length_max: u32 = 128;
const names = @embedFile("names.txt");
const scalar_max: u32 = 0x10ffff;
const search_steps_max: u32 = 64;
const syllable_prefix = "HANGUL SYLLABLE ";
const tangut_prefix = "TANGUT IDEOGRAPH-";

const tangut_ranges = [_]Range{
    .{ .first = 0x17000, .last = 0x187f7 },
    .{ .first = 0x18d00, .last = 0x18d08 },
};

const trailing_jamo = [_][]const u8{
    "",
    "G",
    "GG",
    "GS",
    "N",
    "NJ",
    "NH",
    "D",
    "L",
    "LG",
    "LM",
    "LB",
    "LS",
    "LT",
    "LP",
    "LH",
    "M",
    "B",
    "BS",
    "S",
    "SS",
    "NG",
    "J",
    "C",
    "K",
    "T",
    "P",
    "H",
};

const vowel_jamo = [_][]const u8{
    "A",
    "AE",
    "YA",
    "YAE",
    "EO",
    "E",
    "YEO",
    "YE",
    "O",
    "WA",
    "WAE",
    "OE",
    "YO",
    "U",
    "WEO",
    "WE",
    "WI",
    "YU",
    "EU",
    "YI",
    "I",
};

comptime {
    assert(leading_jamo.len == 19);
    assert(vowel_jamo.len == 21);
    assert(trailing_jamo.len == 28);
    assert(names.len > 0);
    assert(names[names.len - 1] == '\n');
}

pub fn invalid(body: []const u8, unicode: bool) ?u32 {
    assert(body.len <= std.math.maxInt(u32));

    var offset: u32 = 0;

    while (offset < body.len) {
        if (body[offset] != '\\') {
            offset += 1;

            continue;
        }

        const width = escape_width(body, offset, unicode) orelse return offset;

        assert(width >= 1);

        offset += width;
    }

    assert(offset >= body.len);

    return null;
}

pub fn literal_invalid(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    const quote = std.mem.findAny(u8, text, "\"'") orelse return false;
    const prefix = text[0..quote];
    const raw = std.mem.findAny(u8, prefix, "Rr") != null;
    const bytes = std.mem.findAny(u8, prefix, "Bb") != null;
    const rest = text[quote..];
    const triple = std.mem.startsWith(u8, rest, "\"\"\"") or std.mem.startsWith(u8, rest, "'''");
    const width: usize = if (triple) 3 else 1;
    if (text.len < quote + 2 * width) return false;

    const body = text[quote + width .. text.len - width];

    if (bytes) {
        for (body) |byte| {
            if (byte >= 0x80) return true;
        }
    }

    if (raw) return false;
    return invalid(body, !bytes) != null;
}

pub fn named(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name.len > name_length_max) return false;

    var buffer: [name_length_max]u8 = undefined;
    const upper = std.ascii.upperString(&buffer, name);

    assert(upper.len == name.len);

    if (syllable(upper)) return true;
    if (ideograph(upper, ideograph_prefix, &ideograph_ranges)) return true;
    if (ideograph(upper, tangut_prefix, &tangut_ranges)) return true;
    return listed(upper);
}

fn escape_width(body: []const u8, offset: u32, unicode: bool) ?u32 {
    assert(offset < body.len);
    assert(body[offset] == '\\');

    if (offset + 1 >= body.len) return 1;

    assert(offset + 1 < body.len);

    return switch (body[offset + 1]) {
        'x' => hexadecimal_width(body, offset, 2),
        'u' => if (unicode) hexadecimal_width(body, offset, 4) else 2,
        'U' => if (unicode) hexadecimal_width(body, offset, 8) else 2,
        'N' => if (unicode) named_width(body, offset) else 2,
        else => 2,
    };
}

fn hexadecimal_width(body: []const u8, offset: u32, digits: u32) ?u32 {
    assert(offset + 1 < body.len);
    assert(digits == 2 or digits == 4 or digits == 8);

    const start = offset + 2;
    if (body.len - start < digits) return null;

    var value: u32 = 0;

    for (body[start..][0..digits]) |byte| {
        const digit = std.fmt.charToDigit(byte, 16) catch return null;

        value = value * 16 + digit;
    }

    if (value > scalar_max) return null;
    assert(2 + digits < std.math.maxInt(u32));

    return 2 + digits;
}

fn named_width(body: []const u8, offset: u32) ?u32 {
    assert(offset + 1 < body.len);
    assert(body[offset + 1] == 'N');

    const open = offset + 2;
    if (open >= body.len) return null;
    if (body[open] != '{') return null;

    const close = std.mem.findScalarPos(u8, body, open + 1, '}') orelse return null;
    if (!named(body[open + 1 .. close])) return null;

    assert(close > open + 1);

    return @intCast(close + 1 - offset);
}

fn syllable(name: []const u8) bool {
    assert(name.len <= name_length_max);

    if (!std.mem.startsWith(u8, name, syllable_prefix)) return false;

    const rest = name[syllable_prefix.len..];
    const leading = jamo_longest(rest, &leading_jamo) orelse return false;
    const vowel = jamo_longest(rest[leading..], &vowel_jamo) orelse return false;
    const trailing = jamo_longest(rest[leading + vowel ..], &trailing_jamo) orelse return false;

    return leading + vowel + trailing == rest.len;
}

fn jamo_longest(text: []const u8, table: []const []const u8) ?u32 {
    assert(table.len > 0);
    assert(table.len <= trailing_jamo.len);
    assert(text.len <= std.math.maxInt(u32));

    var found: ?u32 = null;

    for (table) |entry| {
        if (!std.mem.startsWith(u8, text, entry)) continue;

        const length: u32 = @intCast(entry.len);
        const longer = found == null or length > found.?;

        if (longer) found = length;
    }

    if (found) |length| assert(length <= text.len);

    return found;
}

fn ideograph(name: []const u8, prefix: []const u8, ranges: []const Range) bool {
    assert(prefix.len > 0);
    assert(ranges.len > 0);

    if (!std.mem.startsWith(u8, name, prefix)) return false;

    const digits = name[prefix.len..];
    if (digits.len < 4) return false;
    if (digits.len > 5) return false;

    var value: u32 = 0;

    for (digits) |byte| {
        const digit = std.fmt.charToDigit(byte, 16) catch return false;

        value = value * 16 + digit;
    }

    const canonical: usize = if (value < 0x10000) 4 else 5;
    if (digits.len != canonical) return false;

    for (ranges) |range| {
        if (range.first <= value) {
            if (value <= range.last) return true;
        }
    }

    return false;
}

fn listed(name: []const u8) bool {
    assert(name.len > 0);
    assert(name.len <= name_length_max);

    var low: usize = 0;
    var high: usize = names.len;

    for (0..search_steps_max) |_| {
        if (low >= high) return false;

        const middle = line_start(low, low + (high - low) / 2);
        const end = std.mem.findScalarPos(u8, names, middle, '\n').?;

        assert(middle < high);

        switch (std.mem.order(u8, name, names[middle..end])) {
            .eq => return true,
            .lt => high = middle,
            .gt => low = end + 1,
        }
    }

    unreachable;
}

fn line_start(floor: usize, offset: usize) usize {
    assert(floor <= offset);
    assert(offset < names.len);

    var scan = offset;

    while (scan > floor) : (scan -= 1) {
        if (names[scan - 1] == '\n') return scan;
    }

    return floor;
}

test "an escape that decodes is valid and one that does not is reported where it starts" {
    try std.testing.expectEqual(null, invalid("a\\x41\\u00e9\\U0001F600\\N{EM DASH}", true));
    try std.testing.expectEqual(null, invalid("\\n\\777\\q\\{", true));
    try std.testing.expectEqual(@as(?u32, 1), invalid("a\\x4", true));
    try std.testing.expectEqual(@as(?u32, 0), invalid("\\x4g", true));
    try std.testing.expectEqual(@as(?u32, 0), invalid("\\u12", true));
    try std.testing.expectEqual(@as(?u32, 0), invalid("\\U00110000", true));
    try std.testing.expectEqual(@as(?u32, 0), invalid("\\N", true));
    try std.testing.expectEqual(@as(?u32, 0), invalid("\\N{}", true));
    try std.testing.expectEqual(@as(?u32, 0), invalid("\\N{EM DASH", true));
    try std.testing.expectEqual(@as(?u32, 2), invalid("ab\\N{NO SUCH NAME}", true));
}

test "a bytes literal decodes only its hexadecimal escapes" {
    try std.testing.expectEqual(null, invalid("\\u12\\U1\\N{NO SUCH NAME}", false));
    try std.testing.expectEqual(@as(?u32, 0), invalid("\\x4", false));
    try std.testing.expectEqual(null, invalid("\\xff", false));
}

test "a character name is found in every family the decoder knows" {
    try std.testing.expect(named("LATIN SMALL LETTER A"));
    try std.testing.expect(named("latin small letter a"));
    try std.testing.expect(named("ABACUS"));
    try std.testing.expect(named("BEL"));
    try std.testing.expect(named("cjk unified ideograph-4e00"));
    try std.testing.expect(named("CJK UNIFIED IDEOGRAPH-2EE5D"));
    try std.testing.expect(named("TANGUT IDEOGRAPH-18D08"));
    try std.testing.expect(named("HANGUL SYLLABLE GA"));
    try std.testing.expect(named("HANGUL SYLLABLE A"));
    try std.testing.expect(named("HANGUL SYLLABLE GGAG"));
    try std.testing.expect(!named("LATIN  SMALL LETTER A"));
    try std.testing.expect(!named("CJK UNIFIED IDEOGRAPH-04E00"));
    try std.testing.expect(!named("CJK UNIFIED IDEOGRAPH-A000"));
    try std.testing.expect(!named("TANGUT IDEOGRAPH-18D09"));
    try std.testing.expect(!named("HANGUL SYLLABLE X"));
    try std.testing.expect(!named("HANGUL SYLLABLE "));
    try std.testing.expect(!named("LATIN CAPITAL LETTER A WITH MACRON AND GRAVE"));
    try std.testing.expect(!named("ZZZZ"));
    try std.testing.expect(!named("AAAA"));
}

test "every listed name is found and its neighbours bound the search" {
    var start: usize = 0;
    var count: u32 = 0;

    while (start < names.len) {
        const end = std.mem.findScalarPos(u8, names, start, '\n').?;
        const name = names[start..end];

        try std.testing.expect(named(name));

        if (start > 0) {
            const previous = names[line_start(0, start - 1) .. start - 1];

            try std.testing.expectEqual(std.math.Order.lt, std.mem.order(u8, previous, name));
        }

        count += 1;
        start = end + 1;
    }

    try std.testing.expect(count > 30_000);
}
