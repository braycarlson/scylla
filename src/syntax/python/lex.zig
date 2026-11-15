const std = @import("std");
const assert = std.debug.assert;
const Kind = @import("kind.zig").Kind;
const Span = @import("../../stdx/bounded/span.zig");
const Token = @import("../token.zig");
const Tokens = @import("../tokens.zig");
const primitives = @import("../lex/primitives.zig");
const scan = @import("../../text/scan.zig");
const Lexed = @import("../testing/lexed.zig").Lexed;
const expect_kind = @import("../testing/lexed.zig").expect_kind;

const Scanner = struct {
    source: []const u8,
    tokens: *Tokens,
    offset: u32,
    brackets: u32,
    depth: u32,
    columns: [depth_max]u32,
    line_start: bool,

    fn run(scanner: *Scanner) error{Truncated}!void {
        assert(scanner.depth == 1);

        while (scanner.offset < scanner.source.len) {
            const before = scanner.offset;

            if (scanner.line_start) {
                assert(scanner.brackets == 0);

                switch (try scanner.indentation()) {
                    .blank => assert(scanner.offset > before),
                    .content => scanner.line_start = false,
                }

                continue;
            }

            try scanner.advance();

            assert(scanner.offset > before);
        }

        assert(scanner.offset == scanner.source.len);

        try scanner.dedent_all();
    }

    fn indentation(scanner: *Scanner) error{Truncated}!Indent {
        assert(scanner.line_start);
        assert(scanner.offset < scanner.source.len);

        const source = scanner.source;
        const start = scanner.offset;
        var column: u32 = 0;

        while (scanner.offset < source.len) : (scanner.offset += 1) {
            switch (source[scanner.offset]) {
                ' ' => column +|= 1,
                '\t' => column +|= tab_columns - column % tab_columns,
                form_feed => column = 0,
                else => break,
            }
        }

        if (scanner.offset == source.len) return .blank;

        if (source[scanner.offset] == '#') {
            const end = line_end(source, scanner.offset);

            try scanner.tokens.push(source, .{
                .offset = scanner.offset,
                .length = end - scanner.offset,
                .kind = .comment,
                .code = Kind.comment.to_u16(),
            });

            scanner.offset = line_skip(source, end);

            return .blank;
        }

        if (scan.line_break_width(source, scanner.offset) > 0) {
            scanner.offset = line_skip(source, scanner.offset);

            return .blank;
        }

        try scanner.levelled(start, column);

        return .content;
    }

    fn levelled(scanner: *Scanner, start: u32, column: u32) error{Truncated}!void {
        assert(scanner.depth >= 1);
        assert(scanner.depth <= depth_max);
        assert(start < std.math.maxInt(u32));

        if (column > scanner.columns[scanner.depth - 1]) {
            if (scanner.depth == depth_max) return;

            scanner.columns[scanner.depth] = column;
            scanner.depth += 1;

            try scanner.tokens.push(scanner.source, .{
                .offset = start,
                .length = 0,
                .kind = .block_start,
                .code = Kind.indent.to_u16(),
            });

            return;
        }

        while (scanner.depth > 1) {
            if (column >= scanner.columns[scanner.depth - 1]) break;

            scanner.depth -= 1;

            try scanner.tokens.push(scanner.source, .{
                .offset = start,
                .length = 0,
                .kind = .block_end,
                .code = Kind.dedent.to_u16(),
            });
        }

        const level = scanner.depth - 1;
        const landed = column == scanner.columns[level];

        if (level > 0) {
            if (column > scanner.columns[level]) scanner.columns[level] = column;
        }

        if (!landed) {
            assert(scanner.offset > start);

            try scanner.tokens.push(scanner.source, .{
                .offset = start,
                .length = scanner.offset - start,
                .kind = Kind.token_kind(.error_token),
                .code = Kind.error_token.to_u16(),
            });
        }

        assert(scanner.columns[0] == 0);
        if (level > 0) assert(scanner.columns[level] == column);
    }

    fn advance(scanner: *Scanner) error{Truncated}!void {
        assert(scanner.offset < scanner.source.len);
        assert(!scanner.line_start);

        const source = scanner.source;
        const offset = scanner.offset;
        const byte = source[offset];
        const terminator = scan.line_break_width(source, offset);

        if (terminator > 0) {
            if (scanner.brackets == 0) {
                try scanner.tokens.push(source, .{
                    .offset = offset,
                    .length = terminator,
                    .kind = .newline,
                    .code = Kind.newline.to_u16(),
                });

                scanner.line_start = true;
            }

            scanner.offset += terminator;

            return;
        }

        if (byte == '\\') {
            const joined = scan.line_break_width(source, offset + 1);

            if (joined > 0) {
                scanner.offset += 1 + joined;

                return;
            }
        }

        switch (byte) {
            ' ', '\t', form_feed => {
                scanner.offset += 1;

                return;
            },
            else => {},
        }

        const token = token_at(source, offset);

        assert(token.offset == offset);

        if (token.exact_kind(Kind) == .string_format) {
            try interpolate(source, token.span(), scanner.tokens);
        } else {
            try scanner.tokens.push(source, token);
        }

        scanner.offset = token.end();

        scanner.brackets_track(token.kind);
    }

    fn brackets_track(scanner: *Scanner, kind: Token.Kind) void {
        assert(scanner.brackets < scanner.offset);
        assert(kind != .newline);

        const punctuation = switch (kind) {
            .punctuation => |punctuation| punctuation,
            else => return,
        };

        switch (punctuation) {
            .bracket_open, .paren_open => scanner.brackets += 1,
            .bracket_close, .paren_close => scanner.brackets -|= 1,
            else => {},
        }

        assert(scanner.brackets <= scanner.offset);
    }

    fn dedent_all(scanner: *Scanner) error{Truncated}!void {
        assert(scanner.offset == scanner.source.len);
        assert(scanner.depth <= depth_max);

        while (scanner.depth > 1) {
            scanner.depth -= 1;

            try scanner.tokens.push(scanner.source, .{
                .offset = scanner.offset,
                .length = 0,
                .kind = .block_end,
                .code = Kind.dedent.to_u16(),
            });
        }

        assert(scanner.depth == 1);
    }
};

const Indent = enum {
    blank,
    content,
};

const Pair = struct {
    first: u8,
    second: u8,
    kind: Kind,
};

const Scanned = struct {
    kind: Kind,
    end: u32,
};

const depth_max: u32 = 64;
const field_depth_max: u32 = 32;
const field_nesting_max: u32 = 3;
const form_feed: u8 = 0x0c;
const operator_width_max: u32 = 3;
const prefix_length_max: u32 = 2;
const step_max: u32 = 1 << 20;
const tab_columns: u32 = 8;

const keywords = std.StaticStringMap(Kind).initComptime(.{
    .{ "False", .false_keyword },
    .{ "None", .none_keyword },
    .{ "True", .true_keyword },
    .{ "and", .and_keyword },
    .{ "as", .as_keyword },
    .{ "assert", .assert_keyword },
    .{ "async", .async_keyword },
    .{ "await", .await_keyword },
    .{ "break", .break_keyword },
    .{ "class", .class_keyword },
    .{ "continue", .continue_keyword },
    .{ "def", .def_keyword },
    .{ "del", .del_keyword },
    .{ "elif", .elif_keyword },
    .{ "else", .else_keyword },
    .{ "except", .except_keyword },
    .{ "finally", .finally_keyword },
    .{ "for", .for_keyword },
    .{ "from", .from_keyword },
    .{ "global", .global_keyword },
    .{ "if", .if_keyword },
    .{ "import", .import_keyword },
    .{ "in", .in_keyword },
    .{ "is", .is_keyword },
    .{ "lambda", .lambda_keyword },
    .{ "nonlocal", .nonlocal_keyword },
    .{ "not", .not_keyword },
    .{ "or", .or_keyword },
    .{ "pass", .pass_keyword },
    .{ "raise", .raise_keyword },
    .{ "return", .return_keyword },
    .{ "try", .try_keyword },
    .{ "while", .while_keyword },
    .{ "with", .with_keyword },
    .{ "yield", .yield_keyword },
});

const operators = std.StaticStringMap(Kind).initComptime(.{
    .{ "!", .bang },
    .{ "!=", .not_equal },
    .{ "%", .percent },
    .{ "%=", .percent_equal },
    .{ "&", .ampersand },
    .{ "&=", .ampersand_equal },
    .{ "(", .paren_open },
    .{ ")", .paren_close },
    .{ "*", .star },
    .{ "*=", .star_equal },
    .{ "**=", .star_star_equal },
    .{ "+", .plus },
    .{ "+=", .plus_equal },
    .{ ",", .comma },
    .{ "-", .minus },
    .{ "-=", .minus_equal },
    .{ "->", .arrow },
    .{ "/", .slash },
    .{ "/=", .slash_equal },
    .{ "//=", .slash_slash_equal },
    .{ ":", .colon },
    .{ ";", .semicolon },
    .{ "<", .less },
    .{ "<<=", .less_less_equal },
    .{ "<=", .less_equal },
    .{ "=", .equal },
    .{ "==", .equal_equal },
    .{ ">", .greater },
    .{ ">=", .greater_equal },
    .{ ">>=", .greater_greater_equal },
    .{ "@", .at },
    .{ "[", .bracket_open },
    .{ "]", .bracket_close },
    .{ "^", .caret },
    .{ "^=", .caret_equal },
    .{ "|", .bar },
    .{ "|=", .bar_equal },
    .{ "~", .tilde },
});

const pairs = [_]Pair{
    .{ .first = '*', .second = '*', .kind = .star_star },
    .{ .first = '/', .second = '/', .kind = .slash_slash },
    .{ .first = ':', .second = '=', .kind = .colon_equal },
    .{ .first = '<', .second = '<', .kind = .less_less },
    .{ .first = '@', .second = '=', .kind = .at_equal },
    .{ .first = '>', .second = '>', .kind = .greater_greater },
};

comptime {
    assert(depth_max >= 2);
    assert(tab_columns > 0);
}

pub fn lex(source: []const u8, tokens: *Tokens) error{Truncated}!void {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.count() == 0);

    var scanner: Scanner = .{
        .source = source,
        .tokens = tokens,
        .offset = scan.mark_width(source),
        .brackets = 0,
        .depth = 1,
        .columns = @splat(0),
        .line_start = true,
    };

    try scanner.run();

    assert(scanner.offset == source.len);
    assert(scanner.depth == 1);
}

fn token_at(source: []const u8, offset: u32) Token {
    assert(source.len <= std.math.maxInt(u32));
    assert(offset < source.len);

    const scanned = kind_at(source, offset);

    assert(scanned.end > offset);
    assert(scanned.end <= source.len);
    assert(scanned.kind.is_token());

    return .{
        .offset = offset,
        .length = scanned.end - offset,
        .kind = Kind.token_kind(scanned.kind),
        .code = scanned.kind.to_u16(),
    };
}

fn kind_at(source: []const u8, offset: u32) Scanned {
    assert(offset < source.len);

    return switch (source[offset]) {
        '#' => .{ .kind = .comment, .end = line_end(source, offset) },
        '"', '\'' => string_scanned(source, offset, offset),
        '0'...'9' => number_scanned(source, offset),
        '{' => .{ .kind = .brace_open, .end = offset + 1 },
        '}' => .{ .kind = .brace_close, .end = offset + 1 },
        '.' => dot_scanned(source, offset),
        else => if (primitives.is_identifier_start_at(source, offset))
            word_scanned(source, offset)
        else
            operator_scanned(source, offset),
    };
}

fn word_scanned(source: []const u8, offset: u32) Scanned {
    assert(primitives.is_identifier_start_at(source, offset));

    if (string_prefixed(source, offset)) |quote| return string_scanned(source, offset, quote);

    const end = primitives.identifier_scan(source, offset);

    assert(end > offset);

    return .{ .kind = keywords.get(source[offset..end]) orelse .identifier, .end = end };
}

fn string_scanned(source: []const u8, offset: u32, quote: u32) Scanned {
    assert(offset <= quote);
    assert(quote < source.len);
    assert(is_quote(source[quote]));

    const named = std.mem.findAny(u8, source[offset..quote], "Rr") == null;

    const end = if (interpolates(source, offset, quote))
        string_format_scan(source, quote, named)
    else
        string_python_scan(source, quote);

    assert(end > quote);

    return .{ .kind = string_of(source[offset..end]), .end = end };
}

fn string_of(bytes: []const u8) Kind {
    assert(bytes.len <= std.math.maxInt(u32));

    if (!scan.string_is_terminated(bytes, .escaped)) return .error_token;

    const prefix_end = std.mem.findAny(u8, bytes, "\"'") orelse bytes.len;
    const prefix = bytes[0..prefix_end];

    assert(prefix_end < bytes.len);

    for (prefix) |byte| {
        if (std.ascii.toLower(byte) == 'b') return .string_bytes;
    }

    for (prefix) |byte| {
        switch (std.ascii.toLower(byte)) {
            'f', 't' => return .string_format,
            else => {},
        }
    }

    return .string_plain;
}

fn number_scanned(source: []const u8, offset: u32) Scanned {
    assert(offset < source.len);
    assert(std.ascii.isDigit(source[offset]));

    const end = number_python_scan(source, offset);
    const kind = number_of(source[offset..end]);
    if (scan.byte_at(source, end) != '.') return .{ .kind = kind, .end = end };
    if (kind != .number_integer) return .{ .kind = kind, .end = end };

    const after = end + 1;
    const float: Scanned = .{ .kind = .number_float, .end = after };
    const byte = scan.byte_at(source, after) orelse return float;
    if (!std.ascii.isAlphabetic(byte)) return float;

    const stop = word_scanned(source, after).end;

    assert(stop > after);

    return switch (byte) {
        'j', 'J' => .{ .kind = .number_complex, .end = stop },
        'e', 'E' => .{ .kind = .number_float, .end = stop },
        else => float,
    };
}

fn number_of(bytes: []const u8) Kind {
    assert(bytes.len > 0);

    if (bytes.len >= 2) {
        const radix = bytes[0..2];
        const digited = std.mem.findNone(u8, bytes[2..], "_") != null;

        const based: ?Kind = if (std.ascii.eqlIgnoreCase(radix, "0x"))
            .number_hexadecimal
        else if (std.ascii.eqlIgnoreCase(radix, "0o"))
            .number_octal
        else if (std.ascii.eqlIgnoreCase(radix, "0b"))
            .number_binary
        else
            null;

        if (based) |kind| return if (digited) kind else .error_token;
    }

    if (bytes.len > 0) {
        if (std.ascii.toLower(bytes[bytes.len - 1]) == 'j') return .number_complex;
    }

    for (bytes) |byte| {
        if (byte == '.') return .number_float;
        if (std.ascii.toLower(byte) == 'e') return .number_float;
    }

    const zero_led = bytes.len > 0 and bytes[0] == '0';

    if (zero_led) {
        for (bytes) |byte| {
            const padding = byte == '0' or byte == '_';
            if (!padding) return .error_token;
        }
    }

    return .number_integer;
}

fn dot_scanned(source: []const u8, offset: u32) Scanned {
    assert(offset < source.len);
    assert(source[offset] == '.');

    const end = offset + 1;
    const dot: Scanned = .{ .kind = .dot, .end = end };
    const next = scan.byte_at(source, end) orelse return dot;

    if (next == '.') {
        if (scan.byte_at(source, end + 1) == '.') return .{ .kind = .ellipsis, .end = end + 2 };
    }

    if (!std.ascii.isDigit(next)) return dot;

    const digits = digits_scan(source, end, std.ascii.isDigit);
    const stop = imaginary_scan(source, exponent_scan(source, digits));

    assert(stop > end);

    return .{ .kind = number_of(source[offset..stop]), .end = stop };
}

fn operator_scanned(source: []const u8, offset: u32) Scanned {
    assert(offset < source.len);

    const operator = scan.punctuation_of(source, offset);
    const end = offset + operator.length;

    assert(operator.length > 0);
    assert(operator.length <= operator_width_max or source[offset] >= 0x80);

    if (operator.length == 1) {
        const next = scan.byte_at(source, end);

        for (pairs) |pair| {
            if (pair.first != source[offset]) continue;
            if (next != pair.second) continue;
            return .{ .kind = pair.kind, .end = end + 1 };
        }
    }

    const kind = operators.get(source[offset..end]) orelse .error_token;

    assert(kind.is_token());

    return .{ .kind = kind, .end = end };
}

fn string_prefixed(source: []const u8, offset: u32) ?u32 {
    assert(offset < source.len);

    const reach: u32 = @intCast(@min(source.len - offset, prefix_length_max));
    var length: u32 = 0;

    while (length < reach) : (length += 1) {
        if (!is_prefix_letter(source[offset + length])) break;
    }

    if (length == 0) return null;

    const quote = offset + length;

    assert(quote <= source.len);
    assert(length <= prefix_length_max);

    const byte = scan.byte_at(source, quote) orelse return null;
    if (!is_quote(byte)) return null;
    return quote;
}

fn is_prefix_letter(byte: u8) bool {
    if (!std.ascii.isAlphabetic(byte)) return false;

    return switch (std.ascii.toLower(byte)) {
        'b', 'f', 'r', 't', 'u' => true,
        else => false,
    };
}

fn interpolates(source: []const u8, offset: u32, quote: u32) bool {
    assert(offset <= quote);
    assert(quote - offset <= prefix_length_max);
    assert(source.len <= std.math.maxInt(u32));

    for (source[offset..quote]) |byte| {
        switch (std.ascii.toLower(byte)) {
            'f', 't' => return true,
            else => {},
        }
    }

    return false;
}

fn number_python_scan(source: []const u8, start: u32) u32 {
    assert(start < source.len);
    assert(std.ascii.isDigit(source[start]));

    if (source[start] == '0') {
        if (number_python_based(source, start)) |end| return end;
    }

    var offset = digits_scan(source, start, std.ascii.isDigit);

    if (scan.byte_at(source, offset) == '.') {
        offset = digits_scan(source, offset + 1, std.ascii.isDigit);
    }

    offset = imaginary_scan(source, exponent_scan(source, offset));

    assert(offset > start);
    assert(offset <= source.len);

    return offset;
}

fn number_python_based(source: []const u8, start: u32) ?u32 {
    assert(start < source.len);
    assert(source[start] == '0');

    const mark = scan.byte_at(source, start + 1) orelse return null;
    const prefixed = start + 2;
    const digits = if (scan.byte_at(source, prefixed) == '_') prefixed + 1 else prefixed;

    const end = switch (mark) {
        'b', 'B' => digits_scan(source, digits, is_binary_digit),
        'o', 'O' => digits_scan(source, digits, is_octal_digit),
        'x', 'X' => digits_scan(source, digits, std.ascii.isHex),
        else => return null,
    };

    assert(end >= digits);

    return end;
}

fn is_binary_digit(byte: u8) bool {
    return byte == '0' or byte == '1';
}

fn is_octal_digit(byte: u8) bool {
    return switch (byte) {
        '0'...'7' => true,
        else => false,
    };
}

fn exponent_scan(source: []const u8, start: u32) u32 {
    assert(start <= source.len);

    const mark = scan.byte_at(source, start) orelse return start;
    if (std.ascii.toLower(mark) != 'e') return start;

    const sign = scan.byte_at(source, start + 1);
    const signed = sign == '+' or sign == '-';
    const digits = start + 1 + @intFromBool(signed);
    const end = digits_scan(source, digits, std.ascii.isDigit);

    assert(end >= digits);

    if (end == digits) return start;
    return end;
}

fn imaginary_scan(source: []const u8, start: u32) u32 {
    assert(start > 0);
    assert(start <= source.len);

    const byte = scan.byte_at(source, start) orelse return start;
    if (std.ascii.toLower(byte) != 'j') return start;
    assert(start + 1 <= source.len);

    return start + 1;
}

fn digits_scan(source: []const u8, start: u32, comptime is_digit: fn (u8) bool) u32 {
    assert(start <= source.len);

    var offset = start;

    while (offset < source.len) {
        if (is_digit(source[offset])) {
            offset += 1;

            continue;
        }

        if (source[offset] != '_') break;
        if (offset == start) break;

        const next = scan.byte_at(source, offset + 1) orelse break;
        if (!is_digit(next)) break;

        offset += 2;
    }

    assert(offset >= start);
    assert(offset <= source.len);

    return offset;
}

fn string_format_scan(source: []const u8, start: u32, named: bool) u32 {
    assert(start < source.len);
    assert(is_quote(source[start]));

    const width: u32 = if (is_triple(source, start)) 3 else 1;

    var extent: Extent = .{
        .depth = 0,
        .offset = start + width,
        .source = source,
        .stack = @splat(.empty),
    };

    const opened = extent.open(.{
        .brackets = 0,
        .escaped = false,
        .mode = .body,
        .named = named,
        .quote = source[start],
        .width = width,
    });

    assert(opened);

    for (0..source.len) |_| {
        if (extent.offset >= source.len) break;

        const ended = switch (extent.top().mode) {
            .body, .spec => extent.step_text(),
            .expression => extent.step_expression(),
            .field => unreachable,
        };

        if (ended) |end| return end;
    }

    assert(extent.offset == source.len);

    return extent.offset;
}

const Reach = struct {
    brackets: u32,
    escaped: bool,
    mode: Mode,
    named: bool,
    quote: u8,
    width: u32,

    const empty: Reach = .{
        .brackets = 0,
        .escaped = false,
        .mode = .body,
        .named = false,
        .quote = '"',
        .width = 1,
    };
};

const Extent = struct {
    depth: u32,
    offset: u32,
    source: []const u8,
    stack: [field_depth_max]Reach,

    fn close(extent: *Extent) void {
        assert(extent.depth > 0);
        assert(extent.depth <= field_depth_max);

        extent.depth -= 1;
    }

    fn close_field(extent: *Extent) void {
        assert(extent.depth > 0);
        assert(extent.top().mode != .body);

        extent.close();

        if (extent.depth == 0) return;

        if (extent.top().mode == .spec) extent.top().escaped = true;
    }

    fn close_literal(extent: *Extent) void {
        assert(extent.depth > 0);

        for (0..field_depth_max) |_| {
            const mode = extent.top().mode;

            extent.close();

            if (mode == .body) return;
        }

        unreachable;
    }

    fn open(extent: *Extent, reach: Reach) bool {
        assert(extent.depth <= field_depth_max);
        assert(reach.width == 1 or reach.width == 3);

        if (extent.depth >= field_depth_max) return false;

        extent.stack[extent.depth] = reach;
        extent.depth += 1;

        return true;
    }

    fn step_expression(extent: *Extent) ?u32 {
        const source = extent.source;
        const offset = extent.offset;
        const reach = extent.top();
        const byte = source[offset];

        assert(reach.mode == .expression);
        assert(reach.brackets <= offset);

        if (primitives.is_identifier_start_at(source, offset)) return extent.step_word();

        extent.offset = switch (byte) {
            '#' => line_end(source, offset),
            '\\' => offset + escape_width(source, offset),
            '"', '\'' => string_python_scan(source, offset),
            else => offset + 1,
        };

        switch (byte) {
            '(', '[', '{' => reach.brackets += 1,
            ')', ']' => reach.brackets -|= 1,
            '}' => if (reach.brackets > 0) {
                reach.brackets -= 1;
            } else {
                extent.close_field();
            },
            ':' => if (reach.brackets == 0) {
                reach.mode = .spec;
            },
            else => {},
        }

        assert(extent.offset > offset);

        return null;
    }

    fn step_text(extent: *Extent) ?u32 {
        const source = extent.source;
        const offset = extent.offset;
        const reach = extent.top().*;
        const byte = source[offset];

        assert(reach.mode == .body or reach.mode == .spec);

        if (byte == '\\') {
            const name_end = if (reach.named) named_escape_end(source, offset) else null;

            extent.offset = name_end orelse offset + escape_width(source, offset);

            return null;
        }

        if (reach.width == 1) {
            if (scan.line_break_width(source, offset) > 0) return offset;
        }

        if (closes(source, offset, reach.quote, reach.width)) {
            extent.offset = offset + reach.width;

            extent.close_literal();

            return if (extent.depth == 0) extent.offset else null;
        }

        const doubled = switch (reach.mode) {
            .body => is_doubled_brace(source, offset),
            .spec => reach.escaped and byte == '{' and is_doubled_brace(source, offset),
            .expression, .field => unreachable,
        };

        if (doubled) {
            extent.offset = offset + 2;

            return null;
        }

        extent.offset = offset + 1;

        switch (byte) {
            '{' => {
                const opened = extent.open(.{
                    .brackets = 0,
                    .escaped = false,
                    .mode = .expression,
                    .named = reach.named,
                    .quote = reach.quote,
                    .width = reach.width,
                });

                if (!opened) {
                    assert(source.len <= std.math.maxInt(u32));

                    return @intCast(source.len);
                }
            },
            '}' => if (reach.mode == .spec) extent.close_field(),
            else => {},
        }

        return null;
    }

    fn step_word(extent: *Extent) ?u32 {
        const source = extent.source;
        const offset = extent.offset;

        const quote = string_prefixed(source, offset) orelse {
            extent.offset = primitives.identifier_scan(source, offset);

            assert(extent.offset > offset);

            return null;
        };

        if (!interpolates(source, offset, quote)) {
            extent.offset = string_python_scan(source, quote);

            return null;
        }

        const width: u32 = if (is_triple(source, quote)) 3 else 1;

        const opened = extent.open(.{
            .brackets = 0,
            .escaped = false,
            .mode = .body,
            .named = std.mem.findAny(u8, source[offset..quote], "Rr") == null,
            .quote = source[quote],
            .width = width,
        });

        if (!opened) {
            assert(source.len <= std.math.maxInt(u32));

            return @intCast(source.len);
        }

        extent.offset = quote + width;

        return null;
    }

    fn top(extent: *Extent) *Reach {
        assert(extent.depth > 0);
        assert(extent.depth <= field_depth_max);

        return &extent.stack[extent.depth - 1];
    }
};

fn named_escape_end(source: []const u8, offset: u32) ?u32 {
    assert(offset < source.len);
    assert(source[offset] == '\\');

    if (scan.byte_at(source, offset + 1) != 'N') return null;
    if (scan.byte_at(source, offset + 2) != '{') return null;

    const close = std.mem.findScalarPos(u8, source, offset + 3, '}') orelse return null;
    const name = source[offset + 3 .. close];
    if (std.mem.findAny(u8, name, "\"'\n\r\\{") != null) return null;

    assert(close > offset + 2);

    return @intCast(close + 1);
}

fn escape_width(source: []const u8, offset: u32) u32 {
    assert(offset < source.len);
    assert(source[offset] == '\\');

    const escaped = scan.byte_at(source, offset + 1) orelse return 1;

    return switch (escaped) {
        '{', '}' => 1,
        else => 2,
    };
}

fn is_doubled_brace(source: []const u8, offset: u32) bool {
    assert(offset < source.len);

    const byte = source[offset];

    return switch (byte) {
        '{', '}' => scan.byte_at(source, offset + 1) == byte,
        else => false,
    };
}

fn string_python_scan(source: []const u8, start: u32) u32 {
    assert(start < source.len);
    assert(is_quote(source[start]));

    const quote = source[start];
    if (!is_triple(source, start)) return primitives.string_scan_continued(source, start, quote);

    var offset = start + 3;

    while (source.len - offset >= 3) {
        if (source[offset] == '\\') {
            offset += 2;

            continue;
        }

        if (closes(source, offset, quote, 3)) {
            assert(offset + 3 <= source.len);

            return offset + 3;
        }

        offset += 1;
    }

    assert(offset <= source.len);

    return @intCast(source.len);
}

fn is_triple(source: []const u8, start: u32) bool {
    assert(start < source.len);
    assert(is_quote(source[start]));

    return closes(source, start, source[start], 3);
}

fn closes(source: []const u8, offset: u32, quote: u8, width: u32) bool {
    assert(offset <= source.len);
    assert(width == 1 or width == 3);

    if (source.len - offset < width) return false;
    assert(quote == '"' or quote == '\'');

    return std.mem.allEqual(u8, source[offset..][0..width], quote);
}

fn is_quote(byte: u8) bool {
    return byte == '"' or byte == '\'';
}

fn line_end(source: []const u8, start: u32) u32 {
    assert(start <= source.len);

    const end: u32 = @intCast(std.mem.findAnyPos(u8, source, start, "\n\r") orelse source.len);

    assert(end >= start);
    assert(end <= source.len);

    return end;
}

fn line_skip(source: []const u8, end: u32) u32 {
    assert(end <= source.len);

    const skipped = end + scan.line_break_width(source, end);

    assert(skipped <= source.len);
    if (end < source.len) assert(skipped > end);

    return skipped;
}

const Mode = enum {
    body,
    expression,
    field,
    spec,
};

const Frame = struct {
    end: u32,
    mode: Mode,
    named: bool,
    quote: u8,
    stage: u8,
    width: u32,

    const empty: Frame = .{
        .end = 0,
        .mode = .body,
        .named = false,
        .quote = '"',
        .stage = 0,
        .width = 1,
    };
};

const Interpolation = struct {
    depth: u32,
    limit: u32,
    offset: u32,
    source: []const u8,
    stack: [field_depth_max]Frame,
    tokens: *Tokens,

    fn push(scanner: *Interpolation, kind: Kind, offset: u32, end: u32) error{Truncated}!void {
        assert(kind.is_token());
        assert(scanner.limit <= scanner.source.len);
        assert(offset < std.math.maxInt(u32));
        assert(end < std.math.maxInt(u32));

        const start = @max(offset, scanner.tokens.end_previous);
        const stop = @min(end, scanner.limit);
        if (stop <= start) return;

        try scanner.tokens.push(scanner.source, .{
            .offset = start,
            .length = stop - start,
            .kind = Kind.token_kind(kind),
            .code = kind.to_u16(),
        });
    }

    fn open(scanner: *Interpolation, frame: Frame) error{Truncated}!void {
        assert(scanner.depth <= field_depth_max);
        assert(frame.width == 1 or frame.width == 3);

        if (scanner.depth >= field_depth_max) return error.Truncated;

        scanner.stack[scanner.depth] = frame;
        scanner.depth += 1;
    }

    fn top(scanner: *const Interpolation) Frame {
        assert(scanner.depth > 0);
        assert(scanner.depth <= field_depth_max);

        return scanner.stack[scanner.depth - 1];
    }

    fn close(scanner: *Interpolation) void {
        assert(scanner.depth > 0);
        assert(scanner.depth <= field_depth_max);

        scanner.depth -= 1;
    }

    fn fields_open(scanner: *const Interpolation) u32 {
        assert(scanner.depth <= field_depth_max);

        var count: u32 = 0;

        for (0..scanner.depth) |above| {
            const frame = scanner.stack[scanner.depth - 1 - above];
            if (frame.mode == .body) break;

            if (frame.mode == .field) count += 1;
        }

        assert(count <= scanner.depth);

        return count;
    }

    fn close_literal(scanner: *Interpolation) void {
        assert(scanner.depth > 0);

        for (0..field_depth_max) |_| {
            const mode = scanner.top().mode;

            scanner.close();

            if (mode == .body) return;
        }

        unreachable;
    }

    fn open_string(scanner: *Interpolation) error{Truncated}!void {
        assert(scanner.offset <= scanner.limit);
        assert(scanner.limit <= scanner.source.len);

        const start = scanner.offset;
        const source = scanner.source;
        var quote = start;

        while (quote < scanner.limit) : (quote += 1) {
            if (is_quote(source[quote])) break;
        }

        if (quote >= scanner.limit) {
            const end = scanner.limit;

            scanner.offset = end;

            return scanner.push(.string_format, start, end);
        }

        const held = source[quote];
        const tripled = quote + 3 <= scanner.limit and closes(source, quote, held, 3);
        const width: u32 = if (tripled) 3 else 1;

        try scanner.push(.f_string_start, start, quote + width);

        scanner.offset = quote + width;

        var frame: Frame = .empty;

        frame.named = std.mem.findAny(u8, source[start..quote], "Rr") == null;
        frame.quote = held;
        frame.width = width;

        try scanner.open(frame);
    }

    fn step_text(scanner: *Interpolation, frame: Frame) error{Truncated}!void {
        assert(scanner.depth > 0);
        assert(frame.mode == .body or frame.mode == .spec);

        const end = text_end(scanner.source, scanner.offset, scanner.limit, .{
            .escaped = frame.mode == .spec and frame.stage == 1,
            .named = frame.named,
            .quote = frame.quote,
            .spec = frame.mode == .spec,
            .width = frame.width,
        });

        try scanner.push(.f_string_middle, scanner.offset, end);

        scanner.offset = end;

        if (scanner.offset >= scanner.limit) return scanner.close();

        const byte = scanner.source[scanner.offset];

        if (byte == frame.quote) {
            const closing = @min(scanner.offset + frame.width, scanner.limit);
            const kind: Kind = if (frame.mode == .body) .f_string_end else .error_token;

            try scanner.push(kind, scanner.offset, closing);

            scanner.offset = closing;

            return scanner.close_literal();
        }

        if (byte == '}') {
            if (frame.mode == .spec) return scanner.close();
        }

        if (byte != '{') {
            const stop = scanner.offset + 1;
            const kind: Kind = if (byte == '}') .error_token else .f_string_middle;

            try scanner.push(kind, scanner.offset, stop);

            scanner.offset = stop;

            return;
        }

        try scanner.field_open();
    }

    fn field_open(scanner: *Interpolation) error{Truncated}!void {
        assert(scanner.offset < scanner.limit);
        assert(scanner.source[scanner.offset] == '{');

        const nested = scanner.fields_open() < field_nesting_max;
        const kind: Kind = if (nested) .brace_open else .error_token;

        try scanner.push(kind, scanner.offset, scanner.offset + 1);

        scanner.offset += 1;

        const stop = expression_end(scanner.source, scanner.offset, scanner.limit);
        var field: Frame = .empty;
        var expression: Frame = .empty;

        field.mode = .field;
        field.named = scanner.stack[scanner.depth - 1].named;
        field.quote = scanner.stack[scanner.depth - 1].quote;
        field.width = scanner.stack[scanner.depth - 1].width;
        expression.end = stop;
        expression.mode = .expression;

        try scanner.open(field);
        try scanner.open(expression);
    }

    fn step_expression(scanner: *Interpolation, frame: Frame) error{Truncated}!void {
        assert(frame.mode == .expression);
        assert(frame.end <= scanner.limit);

        const source = scanner.source;

        while (scanner.offset < frame.end) : (scanner.offset += 1) {
            if (!is_blank(source[scanner.offset])) break;
        }

        if (scanner.offset >= frame.end) return scanner.close();

        const token = token_at(source, scanner.offset);
        const end = @max(@min(token.end(), frame.end), scanner.offset + 1);

        if (token.kind == .string) {
            if (is_format(source[scanner.offset..end])) return scanner.open_string();
        }

        try scanner.push(token.exact_kind(Kind).?, scanner.offset, end);

        scanner.offset = end;
    }

    fn step_field(scanner: *Interpolation, frame: Frame) error{Truncated}!void {
        assert(frame.mode == .field);
        assert(scanner.depth > 0);

        const source = scanner.source;

        while (scanner.offset < scanner.limit) : (scanner.offset += 1) {
            if (!is_blank(source[scanner.offset])) break;
        }

        if (scanner.offset >= scanner.limit) return scanner.close();

        const byte = source[scanner.offset];

        if (byte == '}') {
            try scanner.push(.brace_close, scanner.offset, scanner.offset + 1);

            scanner.offset += 1;

            scanner.close();

            if (scanner.depth == 0) return;

            if (scanner.top().mode == .spec) scanner.stack[scanner.depth - 1].stage = 1;

            return;
        }

        if (frame.stage == 0) {
            switch (byte) {
                '=' => {
                    try scanner.push(.equal, scanner.offset, scanner.offset + 1);

                    scanner.offset += 1;

                    return;
                },
                '!' => return scanner.step_conversion(),
                '#' => return scanner.step_comment(),
                ':' => return scanner.spec_open(),
                else => {},
            }
        }

        const end = scanner.offset + 1;

        try scanner.push(.error_token, scanner.offset, end);

        scanner.offset = end;
    }

    fn spec_open(scanner: *Interpolation) error{Truncated}!void {
        assert(scanner.depth > 0);
        assert(scanner.source[scanner.offset] == ':');

        try scanner.push(.colon, scanner.offset, scanner.offset + 1);

        scanner.offset += 1;

        scanner.stack[scanner.depth - 1].stage = 1;

        var spec: Frame = .empty;

        spec.mode = .spec;
        spec.named = scanner.stack[scanner.depth - 1].named;
        spec.quote = scanner.stack[scanner.depth - 1].quote;
        spec.width = scanner.stack[scanner.depth - 1].width;

        try scanner.open(spec);
    }

    fn step_comment(scanner: *Interpolation) error{Truncated}!void {
        assert(scanner.offset < scanner.limit);
        assert(scanner.source[scanner.offset] == '#');

        const end = @min(line_end(scanner.source, scanner.offset), scanner.limit);

        assert(end > scanner.offset);

        try scanner.push(.comment, scanner.offset, end);

        scanner.offset = end;
    }

    fn step_conversion(scanner: *Interpolation) error{Truncated}!void {
        assert(scanner.offset < scanner.limit);
        assert(scanner.source[scanner.offset] == '!');

        try scanner.push(.bang, scanner.offset, scanner.offset + 1);

        scanner.offset += 1;

        const start = scanner.offset;

        while (scanner.offset < scanner.limit) : (scanner.offset += 1) {
            if (!std.ascii.isAlphabetic(scanner.source[scanner.offset])) break;
        }

        try scanner.push(.identifier, start, scanner.offset);
    }

    fn run(scanner: *Interpolation) error{Truncated}!void {
        assert(scanner.depth == 0);
        assert(scanner.offset <= scanner.limit);

        try scanner.open_string();

        for (0..step_max) |_| {
            if (scanner.depth == 0) break;

            const frame = scanner.top();
            const offset_before = scanner.offset;
            const depth_before = scanner.depth;

            switch (frame.mode) {
                .body, .spec => try scanner.step_text(frame),
                .expression => try scanner.step_expression(frame),
                .field => try scanner.step_field(frame),
            }

            if (scanner.offset != offset_before) continue;
            if (scanner.depth != depth_before) continue;

            const end = @min(scanner.offset + 1, scanner.limit);
            if (end <= scanner.offset) break;

            try scanner.push(.error_token, scanner.offset, end);

            scanner.offset = end;
        }

        if (scanner.offset >= scanner.limit) return;

        try scanner.push(.f_string_middle, scanner.offset, scanner.limit);

        scanner.offset = scanner.limit;
    }
};

fn interpolate(source: []const u8, span: Span, tokens: *Tokens) error{Truncated}!void {
    assert(span.end() <= source.len);
    assert(span.length > 0);

    var scanner: Interpolation = .{
        .depth = 0,
        .limit = span.end(),
        .offset = span.offset,
        .source = source,
        .stack = @splat(.empty),
        .tokens = tokens,
    };

    try scanner.run();

    assert(scanner.offset == scanner.limit);
}

fn is_format(bytes: []const u8) bool {
    assert(bytes.len <= std.math.maxInt(u32));

    const quote = std.mem.findAny(u8, bytes, "\"'") orelse bytes.len;

    assert(quote <= bytes.len);

    for (bytes[0..quote]) |byte| {
        switch (std.ascii.toLower(byte)) {
            'f', 't' => return true,
            else => {},
        }
    }

    return false;
}

fn is_blank(byte: u8) bool {
    const blank = switch (byte) {
        '\t', '\n', 0x0b, 0x0c, '\r', ' ' => true,
        else => false,
    };

    if (blank) assert(byte <= ' ');

    return blank;
}

fn expression_end(source: []const u8, from: u32, limit: u32) u32 {
    assert(from <= limit);
    assert(limit <= source.len);

    var offset = from;
    var depth: u32 = 0;

    for (0..step_max) |_| {
        while (offset < limit) : (offset += 1) {
            if (!is_blank(source[offset])) break;
        }

        if (offset >= limit) return limit;

        const end = @max(@min(token_at(source, offset).end(), limit), offset + 1);
        const text = source[offset..end];

        if (depth == 0) {
            if (text[0] == ':') return offset;

            if (text.len == 1) {
                switch (text[0]) {
                    '}', '!', '=' => return offset,
                    else => {},
                }
            }
        }

        if (text.len == 1) {
            switch (text[0]) {
                '(', '[', '{' => depth += 1,
                ')', ']', '}' => depth -|= 1,
                else => {},
            }
        }

        offset = end;
    }

    return limit;
}

const TextEnd = struct {
    escaped: bool,
    named: bool,
    quote: u8,
    spec: bool,
    width: u32,
};

fn text_end(source: []const u8, from: u32, limit: u32, options: TextEnd) u32 {
    assert(from <= source.len);
    assert(limit <= source.len);
    assert(is_quote(options.quote));

    const quote = options.quote;
    const width = options.width;
    var offset = from;

    while (offset < limit) {
        const byte = source[offset];
        const next = scan.byte_at(source, offset + 1);

        switch (byte) {
            '\\' => {
                const name_end = if (options.named) named_escape_end(source, offset) else null;
                const braced = next == '{' or next == '}';
                const backslash_width: u32 = if (braced) 1 else 2;

                offset = if (name_end) |end| @min(end, limit) else offset + backslash_width;

                continue;
            },
            '{', '}' => {
                const escaped = options.escaped and byte == '{';

                if (options.spec) {
                    if (!escaped) return offset;
                }

                if (next != byte) return offset;

                offset += 2;

                continue;
            },
            else => {},
        }

        if (byte == quote) {
            if (closes(source, offset, quote, width)) return offset;
        }

        offset += 1;
    }

    return @max(@min(offset, limit), from);
}

test "a format string ends at its own quote and not an interior one" {
    try std.testing.expectEqual(7, string_format_scan("\"a{b}c\"x", 0, true));
    try std.testing.expectEqual(14, string_format_scan("\"a{b!r:>{w}}c\"", 0, true));
    try std.testing.expectEqual(7, string_format_scan("\"{'x'}\"y", 0, true));
    try std.testing.expectEqual(7, string_format_scan("\"{{a}}\"", 0, true));
    try std.testing.expectEqual(6, string_format_scan("\"a\\\"b\"", 0, true));
    try std.testing.expectEqual(2, string_format_scan("\"a\nb", 0, true));
    try std.testing.expectEqual(9, string_format_scan("\"\"\"a\nb\"\"\"c", 0, true));
    try std.testing.expectEqual(2, string_format_scan("\"a", 0, true));
    try std.testing.expectEqual(2, string_format_scan("''", 0, true));
}

test "the scan steps by two and not by double" {
    try std.testing.expectEqual(2, string_format_scan("''x'", 0, true));
    try std.testing.expectEqual(8, string_format_scan("\"abc\\\"d\"XY", 0, true));
    try std.testing.expectEqual(8, string_format_scan("\"a{{b}}\"XY", 0, true));
}

const Case = struct {
    word: []const u8,
    source: []const u8,
    kind: Token.Kind,
};

const keyword_cases = [_]Case{
    .{
        .word = "False",
        .source = "value = False\n",
        .kind = .identifier,
    },
    .{
        .word = "None",
        .source = "value = None\n",
        .kind = .identifier,
    },
    .{
        .word = "True",
        .source = "value = True\n",
        .kind = .identifier,
    },
    .{
        .word = "and",
        .source = "value = first and second\n",
        .kind = .{ .punctuation = .ampersand_double },
    },
    .{
        .word = "as",
        .source = "import os as system\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "assert",
        .source = "def f(value):\n    assert value\n",
        .kind = .{ .keyword = .assert },
    },
    .{
        .word = "async",
        .source = "async def f():\n    pass\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "await",
        .source = "async def f(task):\n    await task\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "break",
        .source = "for index in range(4):\n    break\n",
        .kind = .{ .keyword = .@"break" },
    },
    .{
        .word = "class",
        .source = "class Store:\n    pass\n",
        .kind = .{ .keyword = .@"struct" },
    },
    .{
        .word = "continue",
        .source = "for index in range(4):\n    continue\n",
        .kind = .{ .keyword = .@"continue" },
    },
    .{
        .word = "def",
        .source = "def f():\n    pass\n",
        .kind = .{ .keyword = .function },
    },
    .{
        .word = "del",
        .source = "def f(values):\n    del values[0]\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "elif",
        .source = "if first:\n    pass\nelif second:\n    pass\n",
        .kind = .{ .keyword = .branch_else },
    },
    .{
        .word = "else",
        .source = "if first:\n    pass\nelse:\n    pass\n",
        .kind = .{ .keyword = .branch_else },
    },
    .{
        .word = "except",
        .source = "try:\n    pass\nexcept OSError:\n    pass\n",
        .kind = .{ .keyword = .except },
    },
    .{
        .word = "finally",
        .source = "try:\n    pass\nfinally:\n    pass\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "for",
        .source = "for index in range(4):\n    pass\n",
        .kind = .{ .keyword = .loop },
    },
    .{
        .word = "from",
        .source = "from os import path\n",
        .kind = .{ .keyword = .import },
    },
    .{
        .word = "global",
        .source = "def f():\n    global count\n",
        .kind = .{ .keyword = .global },
    },
    .{
        .word = "if",
        .source = "if first:\n    pass\n",
        .kind = .{ .keyword = .branch },
    },
    .{
        .word = "import",
        .source = "import os\n",
        .kind = .{ .keyword = .import },
    },
    .{
        .word = "in",
        .source = "for index in range(4):\n    pass\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "is",
        .source = "value = first is second\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "lambda",
        .source = "increment = lambda value: value + 1\n",
        .kind = .{ .keyword = .lambda },
    },
    .{
        .word = "nonlocal",
        .source = "def outer():\n    count = 0\n\n    def inner():\n        nonlocal count\n",
        .kind = .{ .keyword = .global },
    },
    .{
        .word = "not",
        .source = "value = not first\n",
        .kind = .{ .punctuation = .bang },
    },
    .{
        .word = "or",
        .source = "value = first or second\n",
        .kind = .{ .punctuation = .bar_double },
    },
    .{
        .word = "pass",
        .source = "def f():\n    pass\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "raise",
        .source = "def f():\n    raise OSError\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "return",
        .source = "def f():\n    return 0\n",
        .kind = .{ .keyword = .@"return" },
    },
    .{
        .word = "try",
        .source = "try:\n    pass\nexcept OSError:\n    pass\n",
        .kind = .{ .keyword = .@"try" },
    },
    .{
        .word = "while",
        .source = "while first:\n    pass\n",
        .kind = .{ .keyword = .loop },
    },
    .{
        .word = "with",
        .source = "with open(path) as handle:\n    pass\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "yield",
        .source = "def f():\n    yield 0\n",
        .kind = .{ .keyword = .other },
    },
};

const soft_keyword_cases = [_]Case{
    .{
        .word = "_",
        .source = "match value:\n    case _:\n        pass\n",
        .kind = .identifier,
    },
    .{
        .word = "case",
        .source = "match value:\n    case 1:\n        pass\n",
        .kind = .identifier,
    },
    .{
        .word = "match",
        .source = "match value:\n    case 1:\n        pass\n",
        .kind = .identifier,
    },
    .{
        .word = "type",
        .source = "type Count = int\n",
        .kind = .identifier,
    },
};

const punctuation_cases = [_]Case{
    .{
        .word = "!=",
        .source = "value = first != second\n",
        .kind = .{ .punctuation = .not_equal },
    },
    .{
        .word = "(",
        .source = "def f():\n    pass\n",
        .kind = .{ .punctuation = .paren_open },
    },
    .{
        .word = ")",
        .source = "def f():\n    pass\n",
        .kind = .{ .punctuation = .paren_close },
    },
    .{
        .word = "*",
        .source = "value = first * second\n",
        .kind = .{ .punctuation = .star },
    },
    .{
        .word = "+",
        .source = "value = first + second\n",
        .kind = .{ .punctuation = .other },
    },
    .{
        .word = ",",
        .source = "def f(first, second):\n    pass\n",
        .kind = .{ .punctuation = .comma },
    },
    .{
        .word = "-",
        .source = "value = first - second\n",
        .kind = .{ .punctuation = .other },
    },
    .{
        .word = "->",
        .source = "def f() -> int:\n    return 0\n",
        .kind = .{ .punctuation = .arrow },
    },
    .{
        .word = ".",
        .source = "value = os.path\n",
        .kind = .{ .punctuation = .dot },
    },
    .{
        .word = "/",
        .source = "value = first / second\n",
        .kind = .{ .punctuation = .slash },
    },
    .{
        .word = ":",
        .source = "def f():\n    pass\n",
        .kind = .{ .punctuation = .colon },
    },
    .{
        .word = ";",
        .source = "value = 1; count = 2\n",
        .kind = .{ .punctuation = .semicolon },
    },
    .{
        .word = "<",
        .source = "value = first < second\n",
        .kind = .{ .punctuation = .less },
    },
    .{
        .word = "<=",
        .source = "value = first <= second\n",
        .kind = .{ .punctuation = .less_equal },
    },
    .{
        .word = "=",
        .source = "value = 1\n",
        .kind = .{ .punctuation = .assign },
    },
    .{
        .word = "==",
        .source = "value = first == second\n",
        .kind = .{ .punctuation = .equal },
    },
    .{
        .word = ">",
        .source = "value = first > second\n",
        .kind = .{ .punctuation = .greater },
    },
    .{
        .word = ">=",
        .source = "value = first >= second\n",
        .kind = .{ .punctuation = .greater_equal },
    },
    .{
        .word = "@",
        .source = "@decorator\ndef f():\n    pass\n",
        .kind = .{ .punctuation = .other },
    },
    .{
        .word = "[",
        .source = "value = values[0]\n",
        .kind = .{ .punctuation = .bracket_open },
    },
    .{
        .word = "]",
        .source = "value = values[0]\n",
        .kind = .{ .punctuation = .bracket_close },
    },
    .{
        .word = "^",
        .source = "value = first ^ second\n",
        .kind = .{ .punctuation = .other },
    },
    .{
        .word = "{",
        .source = "value = {}\n",
        .kind = .{ .punctuation = .bracket_open },
    },
    .{
        .word = "|",
        .source = "value = first | second\n",
        .kind = .{ .punctuation = .other },
    },
    .{
        .word = "}",
        .source = "value = {}\n",
        .kind = .{ .punctuation = .bracket_close },
    },
    .{
        .word = "~",
        .source = "value = ~first\n",
        .kind = .{ .punctuation = .other },
    },
};

test "every keyword of the specification lexes to its kind" {
    try std.testing.expectEqual(35, keyword_cases.len);

    for (keyword_cases) |case| {
        try expect_kind(.python, case.source, case.word, case.kind);
    }
}

test "every soft keyword of the specification lexes to its kind" {
    try std.testing.expectEqual(4, soft_keyword_cases.len);

    for (soft_keyword_cases) |case| {
        try expect_kind(.python, case.source, case.word, case.kind);
    }
}

test "a number ends where the python grammar ends it" {
    const cases = [_]struct { []const u8, u32 }{
        .{ "1", 1 },
        .{ "0", 1 },
        .{ "1_000_000", 9 },
        .{ "1_", 1 },
        .{ "1.5", 3 },
        .{ "1.", 2 },
        .{ "1..real", 2 },
        .{ "1.e5", 4 },
        .{ "1e5", 3 },
        .{ "1e+9", 4 },
        .{ "1e-9", 4 },
        .{ "1e", 1 },
        .{ "1e+", 1 },
        .{ "1j", 2 },
        .{ "1.5j", 4 },
        .{ "0x1f", 4 },
        .{ "0XCAFE", 6 },
        .{ "0b1010", 6 },
        .{ "0o777", 5 },
        .{ "0x", 2 },
        .{ "0b2", 2 },
        .{ "0or", 2 },
        .{ "0b_", 3 },
        .{ "1if", 1 },
        .{ "1and", 1 },
        .{ "1syntax_error", 1 },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case[1], number_python_scan(case[0], 0));
    }
}

test "a base prefix without a digit is an error token" {
    const sources = [_][]const u8{ "x = 0or 1\n", "x = 0x\n", "x = 0b_\n" };

    for (sources) |source| {
        var lexed = try Lexed.init(.python, source);
        defer lexed.deinit();

        try std.testing.expectEqual(Kind.error_token, lexed.token(2).exact_kind(Kind).?);
    }
}

test "a word behind a number lexes as its own token" {
    var lexed = try Lexed.init(.python, "1syntax_error\n");
    defer lexed.deinit();

    try std.testing.expectEqualStrings("1", lexed.text_at(0));
    try std.testing.expectEqualStrings("syntax_error", lexed.text_at(1));
}

test "a two character operator lexes as one token" {
    const cases = [_]struct { []const u8, []const u8, Kind }{
        .{ "value = first ** second\n", "**", .star_star },
        .{ "value = first // second\n", "//", .slash_slash },
        .{ "if (value := read()) > 0:\n    pass\n", ":=", .colon_equal },
        .{ "value = first << second\n", "<<", .less_less },
        .{ "value = first >> second\n", ">>", .greater_greater },
        .{ "value @= second\n", "@=", .at_equal },
        .{ "value = ...\n", "...", .ellipsis },
        .{ "value **= second\n", "**=", .star_star_equal },
    };

    for (cases) |case| {
        var lexed = try Lexed.init(.python, case[0]);
        defer lexed.deinit();

        const index = word_index(&lexed, case[1]).?;

        try std.testing.expectEqual(case[2], lexed.token(index).exact_kind(Kind).?);
    }
}

test "every token carries the code of its kind" {
    const source = "def f(value: int = 1) -> int:\n    return value // 2  # half\n";
    var lexed = try Lexed.init(.python, source);
    defer lexed.deinit();

    for (lexed.tokens.slice()) |token| {
        const kind = token.exact_kind(Kind).?;

        try std.testing.expect(kind.is_token());
        try std.testing.expectEqual(Kind.token_kind(kind), token.kind);
    }

    try std.testing.expectEqual(Kind.def_keyword, lexed.token(0).exact_kind(Kind).?);
    try std.testing.expectEqual(Kind.indent, lexed.token(13).exact_kind(Kind).?);
}

test "a number lexes to the kind of its shape" {
    const cases = [_]struct { []const u8, []const u8, Kind }{
        .{ "value = 12\n", "12", .number_integer },
        .{ "value = 1.\n", "1.", .number_float },
        .{ "value = .5\n", ".5", .number_float },
        .{ "value = 1.5e3\n", "1.5e3", .number_float },
        .{ "value = 0x1F\n", "0x1F", .number_hexadecimal },
        .{ "value = 0o17\n", "0o17", .number_octal },
        .{ "value = 0b11\n", "0b11", .number_binary },
        .{ "value = 0x_1F\n", "0x_1F", .number_hexadecimal },
        .{ "value = 0o_1_7\n", "0o_1_7", .number_octal },
        .{ "value = 0b_1\n", "0b_1", .number_binary },
        .{ "value = 0_0\n", "0_0", .number_integer },
        .{ "value = 01\n", "01", .error_token },
        .{ "value = 01.5\n", "01.5", .number_float },
        .{ "value = 2j\n", "2j", .number_complex },
    };

    for (cases) |case| {
        var lexed = try Lexed.init(.python, case[0]);
        defer lexed.deinit();

        const index = word_index(&lexed, case[1]).?;

        try std.testing.expectEqual(case[2], lexed.token(index).exact_kind(Kind).?);
    }
}

test "a format string lexes into its pieces" {
    const source = "f'a{b!r:>{w}}c'";
    var lexed = try Lexed.init(.python, source);
    defer lexed.deinit();

    const expected = [_]Kind{
        .f_string_start,
        .f_string_middle,
        .brace_open,
        .identifier,
        .bang,
        .identifier,
        .colon,
        .f_string_middle,
        .brace_open,
        .identifier,
        .brace_close,
        .brace_close,
        .f_string_middle,
        .f_string_end,
    };

    try std.testing.expectEqual(expected.len, lexed.tokens.count());

    for (expected, lexed.tokens.slice()) |kind, token| {
        try std.testing.expectEqual(kind, token.exact_kind(Kind).?);
        try std.testing.expectEqual(Kind.token_kind(kind), token.kind);
    }

    try std.testing.expectEqual(source.len, lexed.tokens.end_previous);
}

test "a nested format string lexes inside its field" {
    const source = "f\"{f'{x}'}\"\n";
    var lexed = try Lexed.init(.python, source);
    defer lexed.deinit();

    const expected = [_]Kind{
        .f_string_start,
        .brace_open,
        .f_string_start,
        .brace_open,
        .identifier,
        .brace_close,
        .f_string_end,
        .brace_close,
        .f_string_end,
        .newline,
    };

    try std.testing.expectEqual(expected.len, lexed.tokens.count());

    for (expected, lexed.tokens.slice()) |kind, token| {
        try std.testing.expectEqual(kind, token.exact_kind(Kind).?);
    }
}

test "a nested format string cut by its parent's end stays inside the parent" {
    const source = "f\"{#\"\"\"\nf\"\"\"}\"\"\"";
    var lexed = try Lexed.init(.python, source);
    defer lexed.deinit();

    const tokens = lexed.tokens.slice();

    try std.testing.expect(tokens.len > 0);

    for (tokens) |token| {
        try std.testing.expect(token.end() <= source.len);
    }
}

test "an unterminated format string is one error token" {
    var lexed = try Lexed.init(.python, "value = f\"{a}\n");
    defer lexed.deinit();

    try std.testing.expectEqual(Kind.error_token, lexed.token(2).exact_kind(Kind).?);
}

fn word_index(lexed: *const Lexed, word: []const u8) ?u32 {
    assert(word.len > 0);

    for (lexed.tokens.slice(), 0..) |held, index| {
        if (std.mem.eql(u8, held.text(lexed.source), word)) {
            assert(index < lexed.tokens.slice().len);

            return @intCast(index);
        }
    }

    return null;
}

test "a backslash joins the next line" {
    var lexed = try Lexed.init(.python, "value = 1 + \\\n    2\n");
    defer lexed.deinit();

    try std.testing.expectEqual(1, lexed.count_of(.newline));
}

test "a backslash before anything else is punctuation" {
    var plain = try Lexed.init(.python, "value = 1\n");
    defer plain.deinit();

    var joined = try Lexed.init(.python, "value = 1 + \\\n    2\n");
    defer joined.deinit();

    try std.testing.expect(joined.tokens.count() > plain.tokens.count());
}

test "a windows continuation joins its line" {
    const windows = "def f():\r\n    value = 1 + \\\r\n        2\r\n    return value\r\n";
    const unix = "def f():\n    value = 1 + \\\n        2\n    return value\n";

    try std.testing.expectEqual(try structure_of(unix), try structure_of(windows));
}

const Structure = struct {
    block_start_count: u32,
    block_end_count: u32,
    newline_count: u32,
};

fn structure_of(source: []const u8) !Structure {
    assert(source.len <= std.math.maxInt(u32));

    var lexed = try Lexed.init(.python, source);
    defer lexed.deinit();

    const structure: Structure = .{
        .block_start_count = lexed.count_of(.block_start),
        .block_end_count = lexed.count_of(.block_end),
        .newline_count = lexed.count_of(.newline),
    };

    assert(structure.block_start_count <= lexed.tokens.count());
    assert(structure.block_end_count <= lexed.tokens.count());

    return structure;
}

test "a lone carriage return ends its line" {
    const returned = "def f():\r    return 1\r";
    const unix = "def f():\n    return 1\n";

    try std.testing.expectEqual(try structure_of(unix), try structure_of(returned));
}

test "a form feed does not dedent the block it sits in" {
    const source = "class Store:\n    def read(self):\n        return 1\n\x0c\n    " ++
        "def write(self):\n        return 2\n";

    const plain = "class Store:\n    def read(self):\n        return 1\n\n    " ++
        "def write(self):\n        return 2\n";

    try std.testing.expectEqual(try structure_of(plain), try structure_of(source));
}

test "a backslash carries a single quoted string over the newline" {
    var lexed = try Lexed.init(.python, "plain = 'a\\\nb'\nafter = 1\n");
    defer lexed.deinit();

    try lexed.expect_kind_at(2, .string);
    try std.testing.expectEqualStrings("'a\\\nb'", lexed.text_at(2));
}

test "an unterminated string still stops at its line" {
    var lexed = try Lexed.init(.python, "plain = 'a\nafter = 1\n");
    defer lexed.deinit();

    try std.testing.expectEqualStrings("'a", lexed.text_at(2));
}

test "a replacement field may carry the quote around it" {
    const source = "value = f\"{palette[\"#fff\"]}\"\nother = 1\n";
    var lexed = try Lexed.init(.python, source);
    defer lexed.deinit();

    try lexed.expect_kind_at(2, .string);
    try std.testing.expectEqualStrings("f\"", lexed.text_at(2));
    try std.testing.expectEqualStrings("\"#fff\"", lexed.text_at(6));
    try std.testing.expectEqual(2, (try structure_of(source)).newline_count);
}

test "a template literal carries its own prefix" {
    var lexed = try Lexed.init(.python, "value = t\"{name}\"\n");
    defer lexed.deinit();

    try lexed.expect_kind_at(2, .string);
    try std.testing.expectEqualStrings("t\"", lexed.text_at(2));
    try std.testing.expectEqual(Kind.f_string_start, lexed.token(2).exact_kind(Kind).?);
    try std.testing.expectEqualStrings("name", lexed.text_at(4));
}

test "a doubled brace is not a replacement field" {
    var lexed = try Lexed.init(.python, "value = f\"{{literal}}\"\n");
    defer lexed.deinit();

    try std.testing.expectEqualStrings("{{literal}}", lexed.text_at(3));
    try std.testing.expectEqual(Kind.f_string_middle, lexed.token(3).exact_kind(Kind).?);
}

test "a colon in a replacement field opens its spec even before an equal sign" {
    const source = "f'{a:=5}'";
    var lexed = try Lexed.init(.python, source);
    defer lexed.deinit();

    const expected = [_]Kind{
        .f_string_start,
        .brace_open,
        .identifier,
        .colon,
        .f_string_middle,
        .brace_close,
        .f_string_end,
    };

    try std.testing.expectEqual(expected.len, lexed.tokens.count());

    for (expected, lexed.tokens.slice()) |kind, token| {
        try std.testing.expectEqual(kind, token.exact_kind(Kind).?);
    }
}

test "a named escape in format text opens no replacement field" {
    const cases = [_]struct { []const u8, []const Kind }{
        .{ "f'\\N{EM DASH}'", &.{ .f_string_start, .f_string_middle, .f_string_end } },
        .{ "f'{a}\\N{EM DASH}'", &.{
            .f_string_start,
            .brace_open,
            .identifier,
            .brace_close,
            .f_string_middle,
            .f_string_end,
        } },
        .{ "rf'\\N{a}'", &.{
            .f_string_start,
            .f_string_middle,
            .brace_open,
            .identifier,
            .brace_close,
            .f_string_end,
        } },
    };

    for (cases) |case| {
        var lexed = try Lexed.init(.python, case[0]);
        defer lexed.deinit();

        try std.testing.expectEqual(case[1].len, lexed.tokens.count());

        for (case[1], lexed.tokens.slice()) |kind, token| {
            try std.testing.expectEqual(kind, token.exact_kind(Kind).?);
        }
    }
}

test "a lone closing brace in format text is an error token" {
    const cases = [_]struct { []const u8, Kind }{
        .{ "value = f\"a}b\"\n", .error_token },
        .{ "value = f\"{a}\"\n", .brace_close },
    };

    for (cases) |case| {
        var lexed = try Lexed.init(.python, case[0]);
        defer lexed.deinit();

        const index = word_index(&lexed, "}").?;

        try std.testing.expectEqual(case[1], lexed.token(index).exact_kind(Kind).?);
    }
}

test "a match statement keyword lexes as a name" {
    const dotted = "found = re.match(pattern, text)\n";
    const statement = "match command:\n    case 1:\n        pass\n";

    try expect_kind(.python, dotted, "match", .identifier);
    try expect_kind(.python, statement, "match", .identifier);
}

test "a bare assert equal name is not a receiver assertion" {
    var lexed = try Lexed.init(.python, "assertEqual = 1\n");
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .identifier);
}

test "a comment at the source end closes the line" {
    var lexed = try Lexed.init(.python, "value = 1\n# a trailing comment");
    defer lexed.deinit();

    const last = lexed.tokens.last().?;

    try std.testing.expectEqual(Token.Kind.comment, last.kind);
    try std.testing.expectEqual(10, last.offset);
    try std.testing.expectEqual(20, last.length);
}

test "a trailing indent without a newline is blank" {
    var lexed = try Lexed.init(.python, "def read():\n    return 0\n   ");
    defer lexed.deinit();

    try std.testing.expect(lexed.tokens.count() > 0);
}

test "a two quote run at the source end is an empty string" {
    var lexed = try Lexed.init(.python, "text = \"\"");
    defer lexed.deinit();

    try std.testing.expectEqual(2, token_of_kind(&lexed, .string).?.length);
}

fn token_of_kind(lexed: *const Lexed, kind: Token.Kind) ?Token {
    assert(lexed.source.len > 0);

    for (lexed.tokens.slice()) |held| {
        if (held.kind.eql(kind)) return held;
    }

    return null;
}

test "a triple quote at the source end opens an unclosed string" {
    var lexed = try Lexed.init(.python, "text = \"\"\"");
    defer lexed.deinit();

    const string = lexed.token(2);

    try std.testing.expectEqual(7, string.offset);
    try std.testing.expectEqual(3, string.length);
    try std.testing.expectEqual(Kind.error_token, string.exact_kind(Kind).?);
}

test "a dedent between two levels takes the column it landed on" {
    const source = "if a:\n    if b:\n        x = 1\n      y = 2\n      z = 3\n";
    const structure = try structure_of(source);

    try std.testing.expectEqual(2, structure.block_start_count);
    try std.testing.expectEqual(2, structure.block_end_count);
}

test "a dedent between two levels reads the level it landed in not a deeper one" {
    const source = "if a:\n    if b:\n        if c:\n            x = 1\n      y = 2\n" ++
        "      z = 3\n";

    try std.testing.expectEqual(3, (try structure_of(source)).block_start_count);
}

test "a dedent between the file level and the first block keeps the file level" {
    const source = "if a:\n    x = 1\n  y = 2\n  z = 3\n";

    try std.testing.expectEqual(2, (try structure_of(source)).block_start_count);
}

test "a dedent to the outermost column closes every block" {
    const source = "def read():\n    if ready:\n        return 1\nvalue = 2\n";
    const structure = try structure_of(source);

    try std.testing.expectEqual(2, structure.block_start_count);
    try std.testing.expectEqual(2, structure.block_end_count);
}

test "a triple quoted string runs to its closing triple" {
    const source = "text = \"\"\"a \"quoted\" value\"\"\"\nnext = 1\n";
    var lexed = try Lexed.init(.python, source);
    defer lexed.deinit();

    const string = token_of_kind(&lexed, .string).?;

    try std.testing.expectEqual(7, string.offset);
    try std.testing.expectEqual(22, string.length);
}

test "a triple quoted string spans its lines" {
    var lexed = try Lexed.init(.python, "text = \"\"\"first\nsecond\n\"\"\"\n");
    defer lexed.deinit();

    try std.testing.expectEqual(19, token_of_kind(&lexed, .string).?.length);
}

test "an unclosed triple quoted string runs to the source end" {
    var lexed = try Lexed.init(.python, "text = \"\"\"unterminated\n");
    defer lexed.deinit();

    const string = lexed.token(2);

    try std.testing.expectEqual(7, string.offset);
    try std.testing.expectEqual(16, string.length);
    try std.testing.expectEqual(Kind.error_token, string.exact_kind(Kind).?);
}

test "a two quote run is an empty string" {
    var lexed = try Lexed.init(.python, "text = \"\"\nnext = 1\n");
    defer lexed.deinit();

    try std.testing.expectEqual(2, token_of_kind(&lexed, .string).?.length);
}

test "a single quoted triple string closes on its own quote" {
    var lexed = try Lexed.init(.python, "text = '''a value'''\n");
    defer lexed.deinit();

    try std.testing.expectEqual(13, token_of_kind(&lexed, .string).?.length);
}

test "a prefixed string carries its prefix" {
    var lexed = try Lexed.init(.python, "value = r\"text\"\n");
    defer lexed.deinit();

    const string = token_of_kind(&lexed, .string).?;

    try std.testing.expectEqual(8, string.offset);
    try std.testing.expectEqual(7, string.length);
    try std.testing.expectEqual(Kind.string_plain, string.exact_kind(Kind).?);
}

test "a two letter string prefix carries both letters" {
    var lexed = try Lexed.init(.python, "value = rb\"text\"\n");
    defer lexed.deinit();

    const string = token_of_kind(&lexed, .string).?;

    try std.testing.expectEqual(8, string.offset);
    try std.testing.expectEqual(8, string.length);
}

test "a three letter run before a quote is not a prefix" {
    var lexed = try Lexed.init(.python, "value = rbu\"text\"\n");
    defer lexed.deinit();

    const name = lexed.at_offset(8).?;

    try std.testing.expectEqual(Token.Kind.identifier, name.kind);
    try std.testing.expectEqual(3, name.length);
}

test "a prefix letter without a quote is a name" {
    var lexed = try Lexed.init(.python, "rb = 1\n");
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .identifier);
    try std.testing.expectEqual(2, lexed.token(0).length);
}

test "a prefix letter at the source end is a name" {
    var lexed = try Lexed.init(.python, "value = f");
    defer lexed.deinit();

    const last = lexed.tokens.last().?;

    try std.testing.expectEqual(Token.Kind.identifier, last.kind);
    try std.testing.expectEqual(8, last.offset);
    try std.testing.expectEqual(1, last.length);
}

test "a tab indents to the next tab stop" {
    const source = "def read():\n\treturn 0\n";

    try std.testing.expectEqual(1, (try structure_of(source)).block_start_count);
}

const triple_strings = [_]struct { []const u8, []const u8 }{
    .{ "value = \"\"\"a\"\"\"\n", "\"\"\"a\"\"\"" },
    .{ "value = \"\"\"a\nb\"\"\"\n", "\"\"\"a\nb\"\"\"" },
    .{ "value = \"\"\"\"\"\"\n", "\"\"\"\"\"\"" },
    .{ "value = \"\"\"a\\\"\"\"b\"\"\"\n", "\"\"\"a\\\"\"\"b\"\"\"" },
    .{ "value = '''a'''\n", "'''a'''" },
    .{ "value = \"a\"\n", "\"a\"" },
};

test "every triple quoted shape lexes to one string" {
    for (triple_strings) |case| {
        var lexed = try Lexed.init(.python, case[0]);
        defer lexed.deinit();

        const found = token_of_kind(&lexed, .string).?;

        try std.testing.expectEqualStrings(case[1], found.text(case[0]));
    }
}

test "a triple quoted string that never closes stops at the source end" {
    try std.testing.expectEqual(6, string_python_scan("\"\"\"abc", 0));
    try std.testing.expectEqual(7, string_python_scan("\"\"\"abc\n", 0));
    try std.testing.expectEqual(6, string_python_scan("\"\"\"ab\\", 0));
    try std.testing.expectEqual(7, string_python_scan("\"\"\"ab\"\"", 0));
    try std.testing.expectEqual(6, string_python_scan("\"\"\"ab\"", 0));
}

test "a two byte string at the head of the source is not a triple" {
    try std.testing.expectEqual(2, string_python_scan("\"\"", 0));
    try std.testing.expectEqual(2, string_python_scan("''", 0));
}

test "a line that ends the source skips to the end and no further" {
    var lexed = try Lexed.init(.python, "value = 1");
    defer lexed.deinit();

    try std.testing.expect(lexed.tokens.count() > 0);

    var commented = try Lexed.init(.python, "# note");
    defer commented.deinit();

    try std.testing.expectEqual(1, commented.tokens.count());
    try commented.expect_kind_at(0, .comment);
}

test "a tab and eight spaces indent alike" {
    const tabbed = try structure_of("def read():\n\tif ready:\n\t\treturn 0\n");
    const spaced = try structure_of("def read():\n        if ready:\n                return 0\n");

    try std.testing.expectEqual(2, tabbed.block_start_count);
    try std.testing.expectEqual(tabbed.block_start_count, spaced.block_start_count);
}

test "every punctuation of the specification lexes to its kind" {
    for (punctuation_cases) |case| {
        try expect_kind(.python, case.source, case.word, case.kind);
    }
}

test "a function opens and closes a block" {
    var lexed = try Lexed.init(.python, "def main():\n    value = 1\n    return value\n");
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .{ .keyword = .function });
    try lexed.expect_kind_at(1, .identifier);
    try lexed.expect_kind_at(5, .newline);
    try lexed.expect_kind_at(6, .block_start);
    try std.testing.expectEqual(Token.Kind.block_end, lexed.tokens.last().?.kind);
}

test "nesting opens one block for each level" {
    const source = "def a():\n    if b:\n        return 1\n    return 2\n";
    const structure = try structure_of(source);

    try std.testing.expectEqual(2, structure.block_start_count);
    try std.testing.expectEqual(2, structure.block_end_count);
}

test "a blank line holds the indentation" {
    const source = "def a():\n    x = 1\n\n    y = 2\n";

    try std.testing.expectEqual(1, (try structure_of(source)).block_end_count);
}

test "a bracket suppresses the line break" {
    const structure = try structure_of("values = [\n    1,\n    2,\n]\n");

    try std.testing.expectEqual(1, structure.newline_count);
    try std.testing.expectEqual(0, structure.block_start_count);
}

test "a docstring is one string token" {
    const source = "def a():\n    \"\"\"A note.\n\n    More.\n    \"\"\"\n    return 1\n";
    var lexed = try Lexed.init(.python, source);
    defer lexed.deinit();

    const string = token_of_kind(&lexed, .string).?;

    try std.testing.expectEqual(1, lexed.count_of(.string));
    try std.testing.expect(std.mem.startsWith(u8, string.text(source), "\"\"\"A note."));
}

test "a prefixed string is one token and a format string is not" {
    var lexed = try Lexed.init(.python, "pattern = rb'\\d+'\nname = f\"{value}\"\n");
    defer lexed.deinit();

    try std.testing.expectEqual(3, lexed.count_of(.string));
    try std.testing.expectEqual(Kind.string_bytes, lexed.token(2).exact_kind(Kind).?);
}

test "a prefix without an f is not scanned as a format string" {
    var lexed = try Lexed.init(.python, "marker = b\"{\"\nvalue = 1\n");
    defer lexed.deinit();

    try std.testing.expectEqual(1, lexed.count_of(.string));
    try std.testing.expectEqual(4, token_of_kind(&lexed, .string).?.length);
    try std.testing.expect(lexed.count_of(.number) > 0);
}

test "a tab advances to the next tab stop rather than by one" {
    const source = "def f():\n    \ta = 1\n            b = 2\n";

    try std.testing.expectEqual(2, (try structure_of(source)).block_start_count);
}

test "nesting past the indent bound stops opening blocks" {
    const nesting = depth_max + 8;
    const source = comptime nested_of(nesting);
    var lexed = try Lexed.init(.python, source);
    defer lexed.deinit();

    const opened = lexed.count_of(.block_start);

    try std.testing.expect(opened < depth_max);
    try std.testing.expect(opened > 8);
}

fn nested_of(comptime nesting: u32) []const u8 {
    assert(nesting < std.math.maxInt(u32));

    comptime {
        assert(nesting > depth_max);

        var source: []const u8 = "";

        for (0..nesting) |depth| {
            source = source ++ @as([depth * 2]u8, @splat(' ')) ++ "if x:\n";
        }

        return source ++ @as([nesting * 2]u8, @splat(' ')) ++ "pass\n";
    }
}
