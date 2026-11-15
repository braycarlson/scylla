const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const Span = @import("../../stdx/bounded/span.zig");
const Token = @import("token.zig").Token;
const Tokens = @import("tokens.zig").Tokens;
const lexer = @import("lex.zig");
const source_length = @import("token.zig").source_length;

const Island = enum {
    script,
    style,
};

const Plain = struct {
    pub fn is_script(plain: *const Plain, name: []const u8) bool {
        assert(@sizeOf(@TypeOf(plain.*)) == 0);
        assert(name.len > 0);

        return false;
    }
};

pub const CapacityError = error{Overflow};

pub fn spans(out: *ArrayType(Span), source: []const u8, tokens: []const Token) CapacityError!void {
    assert(source.len <= std.math.maxInt(u32));
    assert(out.capacity() > 0);
    assert(tokens.len <= std.math.maxInt(u32));

    return spans_with(Plain, out, &.{}, source, tokens);
}

pub fn spans_with(
    comptime Attributes: type,
    out: *ArrayType(Span),
    attributes: *const Attributes,
    source: []const u8,
    tokens: []const Token,
) CapacityError!void {
    comptime attributes_check(Attributes);

    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    const count: u32 = @intCast(tokens.len);
    var index: u32 = 0;

    for (0..tokens.len) |_| {
        if (index >= count) break;

        const held = tokens[index];

        const next = switch (held.kind) {
            .attribute_name => if (attributes.is_script(held.text(source)))
                try attribute(source, tokens, index, out)
            else
                index + 1,
            .comment_open => try template_comment(source, tokens, index, out),
            .html_comment_open => try html_comment(source, tokens, index, out),
            .script_text => try island(source, tokens, index, .script, out),
            .style_text => try island(source, tokens, index, .style, out),
            else => index + 1,
        };

        assert(next > index);

        index = next;
    }

    assert(index >= count);
}

fn attribute(
    source: []const u8,
    tokens: []const Token,
    name: u32,
    out: *ArrayType(Span),
) CapacityError!u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(name < tokens.len);
    assert(tokens[name].kind == .attribute_name);

    const count: u32 = @intCast(tokens.len);
    const after_name = name + 1;

    assert(after_name <= count);

    var index = whitespace_skipped(tokens, after_name);

    assert(index <= count);

    if (index >= count) return after_name;
    if (tokens[index].kind != .equals) return after_name;

    index = whitespace_skipped(tokens, index + 1);

    if (index >= count) return index;

    const value = tokens[index];

    if (value.kind == .attribute_text) {
        try island_comments(source, value.offset, value.end(), .script, out);

        const after_value = index + 1;

        assert(after_value <= count);

        return after_value;
    }

    if (value.kind != .quote) return index;

    const start = value.end();
    var end = start;

    index += 1;

    for (index..count) |position| {
        if (tokens[position].kind == .quote) break;

        end = tokens[position].end();
        index += 1;
    }

    assert(start <= end);

    try island_comments(source, start, end, .script, out);

    assert(index <= count);

    return index;
}

fn whitespace_skipped(tokens: []const Token, from: u32) u32 {
    assert(tokens.len <= std.math.maxInt(u32));
    assert(from > 0);

    const count: u32 = @intCast(tokens.len);
    var index = from;

    for (from..count) |position| {
        if (tokens[position].kind != .whitespace) break;

        index += 1;
    }

    assert(index >= from);

    return index;
}

fn html_comment(
    source: []const u8,
    tokens: []const Token,
    open: u32,
    out: *ArrayType(Span),
) CapacityError!u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens[open].kind == .html_comment_open);

    const count: u32 = @intCast(tokens.len);
    const start = tokens[open].offset;

    assert(open < count);

    for (open + 1..count) |position| {
        const held = tokens[position];

        if (held.kind == .html_comment_close) {
            try span_pushed(out, Span.between(start, held.end()));

            assert(position + 1 <= count);

            return @intCast(position + 1);
        }
    }

    try span_pushed(out, Span.between(start, source_length(source)));

    return count;
}

fn island(
    source: []const u8,
    tokens: []const Token,
    first: u32,
    kind: Island,
    out: *ArrayType(Span),
) CapacityError!u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));
    assert(first < tokens.len);

    const count: u32 = @intCast(tokens.len);
    const wanted = tokens[first].kind;
    const start = tokens[first].offset;
    var index = first;
    var end = start;

    assert(first < count);

    for (first..count) |position| {
        if (tokens[position].kind != wanted) break;

        end = tokens[position].end();
        index += 1;
    }

    assert(index > first);

    try island_comments(source, start, end, kind, out);

    return index;
}

fn island_comments(
    source: []const u8,
    start: u32,
    end: u32,
    kind: Island,
    out: *ArrayType(Span),
) CapacityError!void {
    assert(start <= end);
    assert(end <= source.len);

    var at = start;

    for (start..end) |_| {
        if (at >= end) break;

        const byte = source[at];

        switch (byte) {
            '"', '\'', '`' => {
                at = string_end(source, at, end, byte);

                continue;
            },
            else => {},
        }

        const comment_possible = byte == '/' and at + 1 < end;

        if (!comment_possible) {
            at += 1;

            continue;
        }

        at = try slash_comment(source, at, end, kind, out);
    }

    assert(at >= end);
}

fn slash_comment(
    source: []const u8,
    at: u32,
    end: u32,
    kind: Island,
    out: *ArrayType(Span),
) CapacityError!u32 {
    assert(source[at] == '/');
    assert(at + 1 < end);

    const next = source[at + 1];

    if (next == '*') {
        const stop = block_end(source, at + 2, end);

        try span_pushed(out, Span.between(at, stop));

        assert(stop <= end);

        return stop;
    }

    if (next == '/') {
        if (kind == .script) {
            const stop = line_end(source, at, end);

            try span_pushed(out, Span.between(at, stop));

            assert(stop <= end);

            return stop;
        }
    }

    assert(at + 1 <= end);

    return at + 1;
}

fn block_end(source: []const u8, from: u32, end: u32) u32 {
    assert(from <= end);
    assert(end <= source.len);

    const found = std.mem.findPos(u8, source[0..end], from, "*/") orelse return end;

    assert(found + 2 <= end);

    return @intCast(found + 2);
}

fn line_end(source: []const u8, from: u32, end: u32) u32 {
    assert(from < end);
    assert(end <= source.len);

    const found = std.mem.findScalarPos(u8, source[0..end], from, '\n') orelse return end;
    assert(found < end);

    return @intCast(found);
}

fn string_end(source: []const u8, from: u32, end: u32, quote: u8) u32 {
    assert(from < end);
    assert(source[from] == quote);

    var at = from + 1;

    for (from..end) |_| {
        if (at >= end) break;

        const byte = source[at];

        at += 1;

        if (byte == '\\') {
            at += 1;

            continue;
        }

        if (byte == quote) {
            assert(at < end);

            return at;
        }

        if (byte == '\n') {
            if (quote != '`') {
                assert(source[at] == '\n');

                return at;
            }
        }
    }

    return @min(at, end);
}

fn template_comment(
    source: []const u8,
    tokens: []const Token,
    open: u32,
    out: *ArrayType(Span),
) CapacityError!u32 {
    assert(tokens[open].kind == .comment_open);

    const count: u32 = @intCast(tokens.len);
    const start = tokens[open].offset;
    var end = tokens[open].end();
    var index = open + 1;

    for (open + 1..count) |position| {
        const held = tokens[position];

        if (held.kind != .comment_close) {
            if (held.kind != .comment_text) break;
        }

        end = held.end();
        index += 1;
    }

    assert(end <= source.len);

    try span_pushed(out, Span.between(start, end));

    assert(start <= end);

    return index;
}

fn span_pushed(out: *ArrayType(Span), span: Span) CapacityError!void {
    assert(out.capacity() > 0);

    if (out.full()) return error.Overflow;
    assert(span.length <= std.math.maxInt(u32) - span.offset);

    out.push(span);

    assert(out.count() > 0);
}

fn attributes_check(comptime Attributes: type) void {
    if (!@hasDecl(Attributes, "is_script")) {
        @compileError("spans_with needs " ++ @typeName(Attributes) ++
            " to declare pub fn is_script(*const " ++ @typeName(Attributes) ++
            ", []const u8) bool");
    }
}

const Found = struct {
    out: ArrayType(Span),
    tokens: Tokens,

    fn init(found: *Found, gpa: std.mem.Allocator, source: []const u8, out_count: u32) !void {
        assert(source.len <= std.math.maxInt(u32));
        assert(out_count < std.math.maxInt(u32));

        found.tokens = try .init(gpa, 1 << 10);
        errdefer found.tokens.deinit(gpa);

        found.out = try .init(gpa, out_count);
        errdefer found.out.deinit(gpa);

        try lexer.lex(source, &found.tokens);
    }

    fn deinit(found: *Found, gpa: std.mem.Allocator) void {
        found.out.deinit(gpa);
        found.tokens.deinit(gpa);
    }

    fn expect_held(found: *const Found, source: []const u8, expected: []const []const u8) !void {
        assert(source.len <= std.math.maxInt(u32));

        const held = found.out.const_slice();

        try std.testing.expectEqual(expected.len, held.len);

        for (held, expected) |span, text| {
            try std.testing.expectEqualStrings(text, span.text(source));
        }
    }
};

fn expect_found(source: []const u8, expected: []const []const u8) !void {
    assert(source.len <= std.math.maxInt(u32));
    assert(expected.len <= std.math.maxInt(u32));

    const gpa = std.testing.allocator;
    var found: Found = undefined;

    try found.init(gpa, source, 1 << 6);
    defer found.deinit(gpa);

    try spans(&found.out, source, found.tokens.slice());
    try found.expect_held(source, expected);
}

const Alpine = struct {
    prefix: []const u8,

    pub fn is_script(alpine: *const Alpine, name: []const u8) bool {
        assert(alpine.prefix.len > 0);
        assert(name.len > 0);

        return std.mem.startsWith(u8, name, alpine.prefix);
    }
};

test "an html comment spans its delimiters" {
    try expect_found(
        "<p>a</p><!-- noqa: X -->\n<!-- open",
        &.{ "<!-- noqa: X -->", "<!-- open" },
    );
}

test "a template comment spans its delimiters" {
    try expect_found("{# one #}<p>{# two", &.{ "{# one #}", "{# two" });
}

test "a script island yields its line and block comments" {
    try expect_found(
        "<script>\nlet a = 'no // here'; // line\n/* block */ let b = `x//y`;\n</script>",
        &.{ "// line", "/* block */" },
    );
}

test "a script comment crosses a split token" {
    try expect_found("<script>// a < b\n</script>", &.{"// a < b"});
}

test "a style island yields only block comments" {
    try expect_found(
        "<style>/* one */ a { b: url(//x) } /* two",
        &.{ "/* one */", "/* two" },
    );
}

test "a script attribute value yields its comments and other attributes do not" {
    const gpa = std.testing.allocator;

    const source = "<div class=\"a // b\" x-data=\"{ open: '// {{ v }}', // note\n" ++
        " toggle() { /* flip */ this.open = !this.open } }\" x-on:click = 'go() // fire'" ++
        " title=\"/* c */\"></div>";

    var found: Found = undefined;

    try found.init(gpa, source, 1 << 6);
    defer found.deinit(gpa);

    try spans_with(Alpine, &found.out, &.{ .prefix = "x-" }, source, found.tokens.slice());
    try found.expect_held(source, &.{ "// note", "/* flip */", "// fire" });

    found.out.clear();

    try spans(&found.out, source, found.tokens.slice());
    try std.testing.expectEqual(0, found.out.count());
}

test "a full table reports the overflow" {
    const gpa = std.testing.allocator;
    const source = "{# a #}{# b #}";
    var tokens: Tokens = try .init(gpa, 1 << 6);
    defer tokens.deinit(gpa);

    var out: ArrayType(Span) = try .init(gpa, 1);
    defer out.deinit(gpa);

    try lexer.lex(source, &tokens);
    try std.testing.expectError(error.Overflow, spans(&out, source, tokens.slice()));
    try std.testing.expectEqual(1, out.count());
}
