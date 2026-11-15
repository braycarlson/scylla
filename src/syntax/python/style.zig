const std = @import("std");
const assert = std.debug.assert;
const Kind = @import("kind.zig").Kind;
const LineEnding = @import("../../text/line_ending.zig").LineEnding;
const Span = @import("../../stdx/bounded/span.zig");
const Token = @import("../token.zig");
const Tokens = @import("../tokens.zig");
const lex = @import("../lex.zig").lex;
const literal = @import("literal.zig");
const scan = @import("../../text/scan.zig");

pub const QuoteStyle = enum {
    double,
    single,

    pub fn byte(style: QuoteStyle) u8 {
        const result: u8 = switch (style) {
            .double => '"',
            .single => '\'',
        };

        assert(std.mem.findScalar(u8, "\"'", result) != null);
        if (style == .double) assert(result == '"');

        return result;
    }
};

pub const Style = struct {
    indent: Span,
    indent_tabs: bool,
    indent_width: u32,
    line_ending: LineEnding,
    quote: QuoteStyle,
};

const indent_width_default: u32 = 4;

pub fn detect(source: []const u8, tokens: []const Token) Style {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    const indent = indent_of(source, tokens);

    const style: Style = .{
        .indent = indent,
        .indent_tabs = scan.byte_at(source, indent.offset) == '\t',
        .indent_width = if (indent.length > 0) indent.length else indent_width_default,
        .line_ending = .of_source(source),
        .quote = quote_of(source, tokens),
    };

    assert(style.indent_width > 0);
    if (style.indent.length == 0) assert(style.indent_width == indent_width_default);

    return style;
}

fn indent_of(source: []const u8, tokens: []const Token) Span {
    assert(tokens.len <= std.math.maxInt(u32));

    const token = for (tokens) |held| {
        if (held.kind == .block_start) break held;
    } else return .empty;

    assert(token.offset <= source.len);

    const start = scan.line_start_of(source, token.offset);
    const blanks = std.mem.findNone(u8, source[start..], "\t ") orelse source.len - start;
    const indent: Span = .{ .offset = start, .length = @intCast(blanks) };

    assert(indent.end() <= source.len);

    return indent;
}

fn quote_of(source: []const u8, tokens: []const Token) QuoteStyle {
    assert(tokens.len <= std.math.maxInt(u32));

    const token = for (tokens) |held| {
        if (held.kind == .string) break held;
    } else return .double;

    assert(token.end() <= source.len);

    const text = token.text(source);

    if (token.exact_kind(Kind) == .f_string_start) {
        const quote = std.mem.findAny(u8, text, "\"'") orelse return .double;
        if (text[quote] == '\'') return .single;
        return .double;
    }

    const shape = literal.shape_of(text, token.offset) orelse return .double;

    assert(shape.content.end() <= token.end());

    if (shape.quote.byte == '\'') return .single;
    return .double;
}

fn detected(source: []const u8) !Style {
    const gpa = std.testing.allocator;

    assert(source.len > 0);

    var tokens: Tokens = try .init(gpa, 1 << 8);
    defer tokens.deinit(gpa);

    try lex(.of(.python), source, &tokens);

    assert(tokens.count() > 0);

    return detect(source, tokens.slice());
}

test "a source without a block keeps the default indent" {
    const style = try detected("held = \"text\"\n");

    try std.testing.expectEqual(Span.empty, style.indent);
    try std.testing.expect(!style.indent_tabs);
    try std.testing.expectEqual(indent_width_default, style.indent_width);
    try std.testing.expectEqual(LineEnding.line_feed, style.line_ending);
    try std.testing.expectEqual(QuoteStyle.double, style.quote);
}

test "the first block sets the indent the source uses" {
    const style = try detected("if held:\n  other = 'text'\n");

    try std.testing.expectEqual(@as(u32, 9), style.indent.offset);
    try std.testing.expectEqual(@as(u32, 2), style.indent_width);
    try std.testing.expect(!style.indent_tabs);
    try std.testing.expectEqual(QuoteStyle.single, style.quote);
    try std.testing.expectEqual(@as(u8, '\''), style.quote.byte());
}

test "a tab indented source with carriage returns reads both" {
    const style = try detected("if held:\r\n\tother = 1\r\n");

    try std.testing.expect(style.indent_tabs);
    try std.testing.expectEqual(@as(u32, 1), style.indent_width);
    try std.testing.expectEqual(LineEnding.carriage_return_line_feed, style.line_ending);
    try std.testing.expectEqual(QuoteStyle.double, style.quote);
    try std.testing.expectEqual(@as(u8, '"'), style.quote.byte());
}

test "a tab ahead of an unindented comment still reads as a tab indent" {
    const style = try detected("\t# remark\n");

    try std.testing.expectEqual(Span.empty, style.indent);
    try std.testing.expect(style.indent_tabs);
    try std.testing.expectEqual(indent_width_default, style.indent_width);
}
