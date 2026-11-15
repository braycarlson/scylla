const std = @import("std");
const assert = std.debug.assert;
const Buffer = @import("../stdx/bounded/buffer.zig");
const Quoting = @import("../text/scan.zig").Quoting;
const Span = @import("../stdx/bounded/span.zig");
const Token = @import("../syntax/token.zig");
const is_close = @import("walk.zig").is_close;
const is_open = @import("walk.zig").is_open;
const nest_depth_max = @import("brace.zig").nest_depth_max;
const opened_by = @import("walk.zig").opened_by;
const string_is_terminated = @import("../text/scan.zig").string_is_terminated;
const substituting = @import("walk.zig").substituting;
const unicode = @import("../text/unicode.zig");

const Classed = struct {
    class: u8,
    text: []const u8,
};

const Power = struct {
    negative: bool,
    digits: []const u8,
};

const Renamed = struct {
    name: []const u8,
    alias: ?[]const u8,
};

const OperatorLevel = struct {
    operator: []const u8,
    level: u8,
};

const alias_first = true;
const key_number_max: u32 = 512;
const regex_flag_max: u32 = 8;
const operator_bitshift = [_][]const u8{ "<<", ">>", ">>>" };
const operator_bitwise = [_][]const u8{ "&", "<<", ">>", ">>>", "^", "|" };
const operator_equality = [_][]const u8{ "!=", "!==", "==", "===" };
const operator_logical = [_][]const u8{ "&&", "??", "||" };
const operator_product = [_][]const u8{ "%", "*", "/" };

const operator_levels = [_]OperatorLevel{
    .{ .operator = "!=", .level = 7 },
    .{ .operator = "!==", .level = 7 },
    .{ .operator = "%", .level = 11 },
    .{ .operator = "&", .level = 6 },
    .{ .operator = "&&", .level = 3 },
    .{ .operator = "*", .level = 11 },
    .{ .operator = "**", .level = 12 },
    .{ .operator = "+", .level = 10 },
    .{ .operator = "-", .level = 10 },
    .{ .operator = "/", .level = 11 },
    .{ .operator = "<", .level = 8 },
    .{ .operator = "<<", .level = 9 },
    .{ .operator = "<=", .level = 8 },
    .{ .operator = "==", .level = 7 },
    .{ .operator = "===", .level = 7 },
    .{ .operator = ">", .level = 8 },
    .{ .operator = ">=", .level = 8 },
    .{ .operator = ">>", .level = 9 },
    .{ .operator = ">>>", .level = 9 },
    .{ .operator = "^", .level = 5 },
    .{ .operator = "in", .level = 8 },
    .{ .operator = "instanceof", .level = 8 },
    .{ .operator = "|", .level = 4 },
    .{ .operator = "||", .level = 2 },
    .{ .operator = "??", .level = 1 },
};

comptime {
    assert(operator_levels.len == 25);
    assert(regex_flag_max <= std.math.maxInt(u8));
}

pub fn sorted(arena: []const u8, spans: []Span) void {
    assert(arena.len <= std.math.maxInt(u32));
    assert(spans.len < std.math.maxInt(u32));

    var index: usize = 1;

    while (index < spans.len) : (index += 1) {
        var scan = index;

        while (scan > 0) : (scan -= 1) {
            if (!precedes(arena, spans[scan], spans[scan - 1])) break;

            std.mem.swap(Span, &spans[scan], &spans[scan - 1]);
        }
    }

    if (spans.len > 1) assert(!precedes(arena, spans[1], spans[0]));
}

pub fn classed(text: []const u8) Classed {
    assert(text.len <= std.math.maxInt(u32));

    const owner = std.mem.eql(u8, text, "self") or std.mem.startsWith(u8, text, "self ");
    if (owner) return .{ .class = 0, .text = text };

    const held = if (std.mem.startsWith(u8, text, "r#")) text[2..] else text;

    assert(held.len <= text.len);
    assert(held.len + 2 >= text.len);

    return .{ .class = 1, .text = held };
}

pub fn ranked(byte: u8) u8 {
    const result: u8 = switch (byte) {
        ' ' => 0,
        ',' => 1,
        ':' => 2,
        '_' => 3,
        '*' => 123,
        '{' => 124,
        else => byte,
    };

    if (byte == '*') assert(result > 'z');
    if (byte == '_') assert(result < '0');

    return result;
}

fn precedes(arena: []const u8, left: Span, right: Span) bool {
    assert(left.end() <= arena.len);
    assert(right.end() <= arena.len);

    const first = classed(left.text(arena));
    const second = classed(right.text(arena));
    if (first.class != second.class) return first.class < second.class;
    if (!alias_first) return versioned(first.text, second.text);

    const one = renamed(first.text);
    const two = renamed(second.text);
    if (!std.mem.eql(u8, one.name, two.name)) return versioned(one.name, two.name);

    const from = one.alias orelse return false;
    const to = two.alias orelse return true;

    return versioned(from, to);
}

pub fn versioned(left: []const u8, right: []const u8) bool {
    assert(left.len < std.math.maxInt(u32));
    assert(right.len < std.math.maxInt(u32));

    var held: u32 = 0;
    var other: u32 = 0;

    while (held < left.len) {
        if (other == right.len) break;

        const numeric = std.ascii.isDigit(left[held]) and std.ascii.isDigit(right[other]);

        if (numeric) {
            const first = digits(left, held);
            const second = digits(right, other);
            if (first - held != second - other) return first - held < second - other;

            const order = std.mem.order(u8, left[held..first], right[other..second]);
            if (order != .eq) return order == .lt;

            held = first;
            other = second;

            continue;
        }

        if (ranked(left[held]) != ranked(right[other])) {
            return ranked(left[held]) < ranked(right[other]);
        }

        held += 1;
        other += 1;
    }

    return left.len - held < right.len - other;
}

fn digits(text: []const u8, from: u32) u32 {
    assert(from <= text.len);
    assert(text.len < std.math.maxInt(u32));

    var held = from;

    while (held < text.len) : (held += 1) {
        if (!std.ascii.isDigit(text[held])) break;
    }

    assert(held >= from);

    return held;
}

pub fn closed(source: []const u8, tokens: []const Token, nests: bool, raw: bool) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    for (tokens) |token| {
        const text = token.text(source);

        const held = switch (token.kind) {
            .comment => comment_closed(text, nests),
            .string => string_closed(text, raw),
            .block_end,
            .block_start,
            .identifier,
            .keyword,
            .newline,
            .number,
            .punctuation,
            => true,
        };

        if (!held) return false;
    }

    return true;
}

fn comment_closed(text: []const u8, nests: bool) bool {
    assert(text.len < std.math.maxInt(u32));

    if (!std.mem.startsWith(u8, text, "/*")) return true;
    if (!nests) return text.len >= 4 and std.mem.endsWith(u8, text, "*/");

    var depth: u32 = 0;
    var offset: u32 = 0;

    while (offset + 1 < text.len) {
        const opening = text[offset] == '/' and text[offset + 1] == '*';

        if (opening) {
            depth += 1;
            offset += 2;

            continue;
        }

        const closing = text[offset] == '*' and text[offset + 1] == '/';

        if (closing) {
            assert(depth > 0);

            depth -= 1;
            offset += 2;

            if (depth == 0) return offset == text.len;

            continue;
        }

        offset += 1;
    }

    return false;
}

fn string_closed(text: []const u8, raw: bool) bool {
    assert(text.len < std.math.maxInt(u32));

    var prefix: u32 = 0;

    while (prefix < text.len) : (prefix += 1) {
        if (!std.ascii.isAlphabetic(text[prefix])) break;
    }

    if (prefix == text.len) return true;

    const quote = text[prefix];
    const quoted = quote == '"' or quote == '\'' or quote == '`';
    if (!quoted) return true;
    if (std.mem.eql(u8, text, "`")) return true;

    assert(prefix < text.len);

    const quoting: Quoting = if (raw) .raw else .escaped;
    return string_is_terminated(text, quoting);
}

pub fn balanced(source: []const u8, tokens: []const Token) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    var depth: u32 = 0;
    var stack: [nest_depth_max]Token.Kind = @splat(.block_start);

    for (tokens) |token| {
        const opening = is_open(token.kind) or substituting(source, token);

        if (opening) {
            if (depth == nest_depth_max) return false;

            stack[depth] = if (is_open(token.kind)) token.kind else .block_start;
            depth += 1;

            continue;
        }

        if (!is_close(token.kind)) continue;
        if (depth == 0) return false;
        if (!stack[depth - 1].eql(opened_by(token.kind))) return false;

        depth -= 1;
    }

    assert(depth <= nest_depth_max);

    return depth == 0;
}

pub fn spaced(out: *Buffer, count: u32) error{Overflow}!void {
    assert(count < std.math.maxInt(u32));

    const length = out.count();

    for (0..count) |_| {
        try out.push_byte(' ');
    }

    assert(out.count() == length + count);
    assert(out.count() <= out.capacity());
}

fn tabbed(out: *Buffer, count: u32) error{Overflow}!void {
    assert(count < std.math.maxInt(u32));

    const length = out.count();

    for (0..count) |_| {
        try out.push_byte('\t');
    }

    assert(out.count() == length + count);
    assert(out.count() <= out.capacity());
}

pub fn reflagged(out: *Buffer, text: []const u8, split: u32) error{Overflow}!void {
    assert(split > 0);
    assert(split <= text.len);

    var flags: [regex_flag_max]u8 = @splat(0);
    const held = text.len - split;

    assert(held <= regex_flag_max);

    @memcpy(flags[0..held], text[split..]);
    std.sort.insertion(u8, flags[0..held], {}, std.sort.asc(u8));

    try out.push(text[0..split]);
    try out.push(flags[0..held]);
}

pub fn reflagging(text: []const u8) ?u32 {
    assert(text.len < std.math.maxInt(u32));

    if (text.len == 0) return null;
    if (text[0] != '/') return null;

    var bracketed = false;
    var escaped = false;
    var index: u32 = 1;

    while (index < text.len) {
        const byte = text[index];

        index += 1;

        if (escaped) {
            escaped = false;

            continue;
        }

        switch (byte) {
            '\\' => escaped = true,
            '[' => bracketed = true,
            ']' => bracketed = false,
            '/' => {
                if (bracketed) continue;
                return reflagging_flags(text, index);
            },
            else => {},
        }
    }

    return null;
}

fn reflagging_flags(text: []const u8, index: u32) ?u32 {
    assert(index > 1);
    assert(index <= text.len);

    const flags = text[index..];
    if (flags.len > regex_flag_max) return null;
    if (std.sort.isSorted(u8, flags, {}, std.sort.asc(u8))) return null;
    return index;
}

pub fn renumbered(out: *Buffer, text: []const u8) error{Overflow}!void {
    assert(text.len < std.math.maxInt(u32));

    const split = exponent_at(text);
    const power = powered(text[split..]);

    assert(split <= text.len);

    const dotted = text.len > 0 and text[0] == '.';

    if (dotted) try out.push("0");

    try lowered(out, trimmed(text[0..split]));

    const held = power orelse return;

    try out.push("e");

    if (held.negative) try out.push("-");

    try lowered(out, held.digits);
}

fn lowered(out: *Buffer, text: []const u8) error{Overflow}!void {
    assert(text.len <= std.math.maxInt(u32));

    const length = out.count();

    for (text) |byte| {
        try out.push_byte(std.ascii.toLower(byte));
    }

    assert(out.count() == length + text.len);
    assert(out.count() <= out.capacity());
}

fn exponent_at(text: []const u8) u32 {
    assert(text.len < std.math.maxInt(u32));

    const zeroed = text.len >= 2 and text[0] == '0';
    const based = zeroed and !std.ascii.isDigit(text[1]) and text[1] != '.';

    if (based) {
        assert(text.len <= std.math.maxInt(u32));

        return @intCast(text.len);
    }

    const result: u32 = @intCast(std.mem.findAny(u8, text, "eE") orelse text.len);

    assert(result <= text.len);

    return result;
}

fn powered(text: []const u8) ?Power {
    if (text.len == 0) return null;

    const signed = text.len > 1 and (text[1] == '+' or text[1] == '-');
    const exponent = text[1 + @as(u32, @intFromBool(signed)) ..];
    const zeros = std.mem.findNone(u8, exponent, "0") orelse exponent.len;
    if (zeros == exponent.len) return null;

    assert(zeros < exponent.len);
    assert(exponent[zeros] != '0');

    return .{ .negative = text.len > 1 and text[1] == '-', .digits = exponent[zeros..] };
}

fn trimmed(mantissa: []const u8) []const u8 {
    assert(mantissa.len <= std.math.maxInt(u32));

    const dot = std.mem.findScalar(u8, mantissa, '.') orelse return mantissa;
    const fraction = mantissa[dot + 1 ..];

    for (fraction) |byte| {
        if (!std.ascii.isDigit(byte)) return mantissa;
    }

    var held = fraction.len;

    while (held > 1) : (held -= 1) {
        if (fraction[held - 1] != '0') break;
    }

    assert(held <= fraction.len);

    if (held == 0) return mantissa[0..dot];

    assert(dot + 1 + held <= mantissa.len);

    return mantissa[0 .. dot + 1 + held];
}

pub fn named_key(body: []const u8) bool {
    if (body.len == 0) return false;
    if (body.len >= std.math.maxInt(u32)) return false;

    var offset: u32 = 0;

    while (offset < body.len) {
        const byte = body[offset];
        const first = offset == 0;

        if (byte < 0x80) {
            const part = std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '$';
            const named = if (first) part and !std.ascii.isDigit(byte) else part;
            if (!named) return false;

            offset += 1;

            continue;
        }

        const scalar = unicode.decode(body, offset) orelse return false;

        const named = if (first)
            unicode.is_xid_start(scalar.value)
        else
            unicode.is_xid_continue(scalar.value);

        if (!named) return false;

        offset += scalar.width;
    }

    assert(offset == body.len);
    assert(!std.ascii.isDigit(body[0]));

    return true;
}

pub fn numbered_key(body: []const u8) bool {
    var buffer: [key_number_max]u8 = undefined;

    if (body.len == 0) return false;
    if (body.len > key_number_max) return false;
    if (!std.ascii.isDigit(body[0])) return false;

    const value = std.fmt.parseFloat(f64, body) catch return false;
    if (!std.math.isFinite(value)) return false;

    const printed = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch return false;

    assert(printed.len > 0);
    assert(std.ascii.isDigit(printed[0]));

    return std.mem.eql(u8, printed, body);
}

pub fn bodied(text: []const u8) ?[]const u8 {
    if (text.len == 0) return null;

    const quote = text[0];
    const quoted = quote == '"' or quote == '\'';
    if (!quoted) return null;
    if (text.len < 2) return null;
    if (text[text.len - 1] != quote) return null;

    const body = text[1 .. text.len - 1];

    assert(body.len + 2 == text.len);

    return body;
}

pub fn preferred(body: []const u8) u8 {
    assert(body.len < std.math.maxInt(u32));

    var doubles: u32 = 0;
    var singles: u32 = 0;
    var held: u32 = 0;

    while (held < body.len) : (held += 1) {
        held += @intFromBool(body[held] == '\\');

        if (held == body.len) break;

        if (body[held] == '"') doubles += 1;
        if (body[held] == '\'') singles += 1;
    }

    assert(doubles + singles <= body.len);

    return if (doubles > singles) '\'' else '"';
}

pub fn requoted(out: *Buffer, body: []const u8, quote: u8) error{Overflow}!void {
    assert(body.len < std.math.maxInt(u32));

    const former: u8 = if (quote == '"') '\'' else '"';
    var held: u32 = 0;

    while (held < body.len) {
        if (body[held] != '\\') {
            if (body[held] == quote) try out.push("\\");

            try out.push_byte(body[held]);

            held += 1;

            continue;
        }

        if (held + 1 == body.len) return out.push("\\");

        const next = body[held + 1];

        if (next == former) {
            try out.push_byte(next);
        } else {
            try out.push(&.{ '\\', next });
        }

        held += 2;
    }

    assert(held == body.len);
}

pub fn nested(above: []const u8, held: []const u8, right: bool) bool {
    assert(above.len <= std.math.maxInt(u32));
    assert(held.len <= std.math.maxInt(u32));

    const logical = listed(&operator_logical, above) and listed(&operator_logical, held);
    if (logical) return std.mem.eql(u8, above, held);

    const over = levelled(above) orelse return false;
    const under = levelled(held) orelse return false;
    if (over > under) return false;
    if (over == under) return !right and flattens(above, held);

    const additive = std.mem.eql(u8, above, "+") or std.mem.eql(u8, above, "-");
    const modulo_additive = std.mem.eql(u8, held, "%") and additive;
    if (modulo_additive) return false;

    assert(over < under);

    return !listed(&operator_bitwise, above);
}

fn renamed(text: []const u8) Renamed {
    assert(text.len <= std.math.maxInt(u32));

    const at = std.mem.find(u8, text, " as ") orelse return .{ .name = text, .alias = null };

    assert(at + 4 <= text.len);
    assert(at < text.len);

    return .{ .name = text[0..at], .alias = text[at + 4 ..] };
}

fn levelled(text: []const u8) ?u8 {
    assert(text.len <= std.math.maxInt(u32));

    for (operator_levels) |entry| {
        if (std.mem.eql(u8, entry.operator, text)) {
            assert(entry.level > 0);
            assert(entry.level <= 12);

            return entry.level;
        }
    }

    return null;
}

fn flattens(above: []const u8, held: []const u8) bool {
    assert(levelled(above) != null);
    assert(std.meta.eql(levelled(above), levelled(held)));

    if (std.mem.eql(u8, above, "**")) return false;

    const equality = listed(&operator_equality, above) and listed(&operator_equality, held);
    if (equality) return false;

    const modulo_held = std.mem.eql(u8, held, "%") and listed(&operator_product, above);
    const modulo_above = std.mem.eql(u8, above, "%") and listed(&operator_product, held);
    const moduloed = modulo_held or modulo_above;
    if (moduloed) return false;

    const product = listed(&operator_product, above) and listed(&operator_product, held);

    if (product) {
        if (!std.mem.eql(u8, above, held)) return false;
    }

    return !(listed(&operator_bitshift, above) and listed(&operator_bitshift, held));
}

fn listed(operators: []const []const u8, text: []const u8) bool {
    assert(operators.len > 0);
    assert(text.len <= std.math.maxInt(u32));

    for (operators) |operator| {
        assert(operator.len > 0);

        if (std.mem.eql(u8, operator, text)) return true;
    }

    return false;
}

test "sorted spans put self first and an alias before its bare name" {
    const words = [_][]const u8{
        "zeta",
        "item10",
        "alpha",
        "self",
        "r#gamma",
        "alpha as beta",
        "item9",
    };

    const order = [_][]const u8{
        "self",
        "alpha as beta",
        "alpha",
        "r#gamma",
        "item9",
        "item10",
        "zeta",
    };

    var arena: [64]u8 = undefined;
    var spans: [words.len]Span = undefined;
    var length: u32 = 0;

    for (words, 0..) |word, index| {
        @memcpy(arena[length..][0..word.len], word);
        spans[index] = .{ .offset = length, .length = @intCast(word.len) };
        length += @intCast(word.len);
    }

    sorted(arena[0..length], &spans);

    for (order, spans) |word, span| {
        try std.testing.expectEqualStrings(word, span.text(arena[0..length]));
    }
}

test "versions compare digit runs by length before value" {
    try std.testing.expect(versioned("v2", "v10"));
    try std.testing.expect(!versioned("v10", "v2"));
    try std.testing.expect(versioned("a_b", "ab"));
    try std.testing.expect(versioned("ab", "abc"));
    try std.testing.expect(!versioned("abc", "abc"));
    try std.testing.expect(versioned("a 1", "a,1"));
    try std.testing.expectEqual(@as(u32, 4), digits("ab12c", 2));
}

test "a renumbered literal lowers its letters and trims its zeros" {
    const cases = [_][2][]const u8{
        .{ "1.50E+05", "1.5e5" },
        .{ ".5", "0.5" },
        .{ "0XFF", "0xff" },
        .{ "1e-007", "1e-7" },
        .{ "2E0", "2" },
        .{ "1.0", "1.0" },
        .{ "1.", "1" },
        .{ "1.2a0", "1.2a0" },
    };

    var out: Buffer = try .init(std.testing.allocator, 32);
    defer out.deinit(std.testing.allocator);

    for (cases) |case| {
        out.clear();

        try renumbered(&out, case[0]);
        try std.testing.expectEqualStrings(case[1], out.const_slice());
    }

    var small: Buffer = try .init(std.testing.allocator, 2);
    defer small.deinit(std.testing.allocator);

    try std.testing.expectError(error.Overflow, renumbered(&small, "1.5e5"));
}

test "a requoted body escapes the new quote and drops needless escapes" {
    var out: Buffer = try .init(std.testing.allocator, 32);
    defer out.deinit(std.testing.allocator);

    try requoted(&out, "say \"hi\" \\'x\\'", '"');
    try std.testing.expectEqualStrings("say \\\"hi\\\" 'x'", out.const_slice());

    out.clear();

    try requoted(&out, "a\"b\\'c", '\'');
    try std.testing.expectEqualStrings("a\"b\\'c", out.const_slice());

    out.clear();

    try requoted(&out, "ab\\", '"');
    try std.testing.expectEqualStrings("ab\\", out.const_slice());
    try std.testing.expectEqual(@as(u8, '\''), preferred("a\"b"));
    try std.testing.expectEqual(@as(u8, '"'), preferred("it's"));
    try std.testing.expectEqual(@as(u8, '\''), preferred("\\\""));
}

test "regex flags out of order are sorted" {
    try std.testing.expectEqual(@as(?u32, null), reflagging("/a/gi"));
    try std.testing.expectEqual(@as(?u32, 3), reflagging("/a/ig"));
    try std.testing.expectEqual(@as(?u32, 5), reflagging("/[/]/ig"));
    try std.testing.expectEqual(@as(?u32, null), reflagging("/a/zyxwvutsr"));
    try std.testing.expectEqual(@as(?u32, null), reflagging("a/b"));
    try std.testing.expectEqual(@as(?u32, null), reflagging("/\\/"));

    var out: Buffer = try .init(std.testing.allocator, 16);
    defer out.deinit(std.testing.allocator);

    try reflagged(&out, "/a/ig", 3);
    try std.testing.expectEqualStrings("/a/gi", out.const_slice());
}

test "comments and strings close where their language says" {
    try std.testing.expect(comment_closed("/* a /* b */ c */", true));
    try std.testing.expect(!comment_closed("/* a /* b */", true));
    try std.testing.expect(comment_closed("/**/", false));
    try std.testing.expect(!comment_closed("/*/", false));
    try std.testing.expect(comment_closed("// x", false));
    try std.testing.expect(string_closed("'abc'", false));
    try std.testing.expect(!string_closed("'abc", false));
    try std.testing.expect(string_closed("`", false));
    try std.testing.expect(string_closed("abc", false));

    var lexed = try Lexed.init(.javascript, "a /* b */ 'c'");
    defer lexed.deinit();

    try std.testing.expect(closed(lexed.source, lexed.tokens.slice(), false, false));
}

test "brackets balance only when every close meets its open" {
    var lexed = try Lexed.init(.javascript, "f(a[b]{c})");
    defer lexed.deinit();

    try std.testing.expect(balanced(lexed.source, lexed.tokens.slice()));

    var unbalanced = try Lexed.init(.javascript, "f(a]");
    defer unbalanced.deinit();

    try std.testing.expect(!balanced(unbalanced.source, unbalanced.tokens.slice()));
}

test "keys and bodies keep their quoting rules" {
    try std.testing.expect(named_key("$a_1"));
    try std.testing.expect(!named_key("1a"));
    try std.testing.expect(!named_key(""));
    try std.testing.expect(named_key("char\u{f1}"));
    try std.testing.expect(named_key("\u{3c0}"));
    try std.testing.expect(named_key("\u{2160}"));
    try std.testing.expect(named_key("a\u{200d}b"));
    try std.testing.expect(!named_key("\\u0041"));
    try std.testing.expect(!named_key("a-b"));
    try std.testing.expect(numbered_key("0"));
    try std.testing.expect(!numbered_key("01"));
    try std.testing.expect(numbered_key("123"));
    try std.testing.expect(numbered_key("1.23"));
    try std.testing.expect(numbered_key("0.0000001"));
    try std.testing.expect(numbered_key("1234567890123456"));
    try std.testing.expect(!numbered_key("12345678901234567"));
    try std.testing.expect(!numbered_key("9007199254740993"));
    try std.testing.expect(!numbered_key("1e3"));
    try std.testing.expect(!numbered_key("1.0"));
    try std.testing.expect(!numbered_key(".5"));
    try std.testing.expect(!numbered_key("1_000"));
    try std.testing.expect(!numbered_key("0x10"));
    try std.testing.expect(!numbered_key("1e400"));
    try std.testing.expect(!numbered_key("5e1_000"));
    try std.testing.expectEqualStrings("ab", bodied("'ab'").?);
    try std.testing.expectEqual(@as(?[]const u8, null), bodied("'ab\""));
    try std.testing.expectEqual(@as(?[]const u8, null), bodied("'"));
    try std.testing.expectEqual(@as(?[]const u8, null), bodied("ab"));
    try std.testing.expectEqual(@as(u8, 0), classed("self").class);
    try std.testing.expectEqualStrings("gamma", classed("r#gamma").text);
    try std.testing.expectEqual(@as(u8, 124), ranked('{'));
}

test "nested operators keep the parentheses that change meaning" {
    try std.testing.expect(!nested("&&", "||", false));
    try std.testing.expect(nested("||", "||", false));
    try std.testing.expect(nested("+", "*", false));
    try std.testing.expect(!nested("*", "+", false));
    try std.testing.expect(nested("+", "+", false));
    try std.testing.expect(!nested("+", "+", true));
    try std.testing.expect(!nested("*", "%", false));
    try std.testing.expect(!nested("+", "%", false));
    try std.testing.expect(!nested("|", "&", false));
    try std.testing.expect(!nested("??", "x", false));
    try std.testing.expect(!nested("**", "**", false));
    try std.testing.expect(!nested("==", "!=", false));
    try std.testing.expect(!nested("<<", ">>", false));
}

test "spaces and tabs fill up to their count" {
    var out: Buffer = try .init(std.testing.allocator, 4);
    defer out.deinit(std.testing.allocator);

    try spaced(&out, 2);
    try tabbed(&out, 1);
    try std.testing.expectEqualStrings("  \t", out.const_slice());
    try std.testing.expectError(error.Overflow, spaced(&out, 2));
    try lowered(&out, "");
    try std.testing.expectEqual(@as(u32, 4), out.count());
}

const Lexed = @import("../syntax/testing/lexed.zig").Lexed;
