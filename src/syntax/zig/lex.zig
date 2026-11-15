const std = @import("std");
const assert = std.debug.assert;
const Kind = @import("kind.zig").Kind;
const Lexeme = @import("check_tokenizer.zig").Lexeme;
const Token = @import("../token.zig");
const Tokenizer = @import("check_tokenizer.zig").Tokenizer;
const Tokens = @import("../tokens.zig");
const primitives = @import("../lex/primitives.zig");
const scan = @import("../../text/scan.zig");
const Lexed = @import("../testing/lexed.zig").Lexed;
const expect_kind = @import("../testing/lexed.zig").expect_kind;
const expect_texts = @import("../testing/lexed.zig").expect_texts;

const keywords = std.StaticStringMap(Kind).initComptime(.{
    .{ "addrspace", .addrspace_keyword },
    .{ "align", .align_keyword },
    .{ "allowzero", .allowzero_keyword },
    .{ "and", .and_keyword },
    .{ "anyframe", .anyframe_keyword },
    .{ "anytype", .anytype_keyword },
    .{ "asm", .asm_keyword },
    .{ "break", .break_keyword },
    .{ "callconv", .callconv_keyword },
    .{ "catch", .catch_keyword },
    .{ "comptime", .comptime_keyword },
    .{ "const", .const_keyword },
    .{ "continue", .continue_keyword },
    .{ "defer", .defer_keyword },
    .{ "else", .else_keyword },
    .{ "enum", .enum_keyword },
    .{ "errdefer", .errdefer_keyword },
    .{ "error", .error_keyword },
    .{ "export", .export_keyword },
    .{ "extern", .extern_keyword },
    .{ "fn", .fn_keyword },
    .{ "for", .for_keyword },
    .{ "if", .if_keyword },
    .{ "inline", .inline_keyword },
    .{ "linksection", .linksection_keyword },
    .{ "noalias", .noalias_keyword },
    .{ "noinline", .noinline_keyword },
    .{ "nosuspend", .nosuspend_keyword },
    .{ "opaque", .opaque_keyword },
    .{ "or", .or_keyword },
    .{ "orelse", .orelse_keyword },
    .{ "packed", .packed_keyword },
    .{ "pub", .pub_keyword },
    .{ "resume", .resume_keyword },
    .{ "return", .return_keyword },
    .{ "struct", .struct_keyword },
    .{ "suspend", .suspend_keyword },
    .{ "switch", .switch_keyword },
    .{ "test", .test_keyword },
    .{ "threadlocal", .threadlocal_keyword },
    .{ "try", .try_keyword },
    .{ "union", .union_keyword },
    .{ "unreachable", .unreachable_keyword },
    .{ "var", .var_keyword },
    .{ "volatile", .volatile_keyword },
    .{ "while", .while_keyword },
});

const operators = std.StaticStringMap(Kind).initComptime(.{
    .{ "<<|=", .less_less_pipe_equal },
    .{ "...", .dot_dot_dot },
    .{ "*%=", .star_percent_equal },
    .{ "*|=", .star_pipe_equal },
    .{ "+%=", .plus_percent_equal },
    .{ "+|=", .plus_pipe_equal },
    .{ "-%=", .minus_percent_equal },
    .{ "-|=", .minus_pipe_equal },
    .{ "<<=", .less_less_equal },
    .{ "<<|", .less_less_pipe },
    .{ ">>=", .greater_greater_equal },
    .{ "!=", .bang_equal },
    .{ "%=", .percent_equal },
    .{ "&=", .ampersand_equal },
    .{ "*%", .star_percent },
    .{ "**", .star_star },
    .{ "*=", .star_equal },
    .{ "*|", .star_pipe },
    .{ "+%", .plus_percent },
    .{ "++", .plus_plus },
    .{ "+=", .plus_equal },
    .{ "+|", .plus_pipe },
    .{ "-%", .minus_percent },
    .{ "-=", .minus_equal },
    .{ "-|", .minus_pipe },
    .{ ".*", .dot_asterisk },
    .{ "..", .dot_dot },
    .{ ".?", .dot_question },
    .{ "/=", .slash_equal },
    .{ "<<", .less_less },
    .{ "<=", .less_equal },
    .{ "==", .equal_equal },
    .{ "=>", .arrow },
    .{ ">=", .greater_equal },
    .{ ">>", .greater_greater },
    .{ "^=", .caret_equal },
    .{ "|=", .pipe_equal },
    .{ "||", .pipe_pipe },
    .{ "!", .bang },
    .{ "%", .percent },
    .{ "&", .ampersand },
    .{ "(", .paren_open },
    .{ ")", .paren_close },
    .{ "*", .star },
    .{ "+", .plus },
    .{ ",", .comma },
    .{ "-", .minus },
    .{ ".", .dot },
    .{ "/", .slash },
    .{ ":", .colon },
    .{ ";", .semicolon },
    .{ "<", .less },
    .{ "=", .equal },
    .{ ">", .greater },
    .{ "?", .question },
    .{ "[", .bracket_open },
    .{ "]", .bracket_close },
    .{ "^", .caret },
    .{ "|", .pipe },
    .{ "~", .tilde },
});

const operator_width_max: u32 = 4;

pub fn lex(source: []const u8, tokens: *Tokens) error{Truncated}!void {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.count() == 0);

    var offset = scan.mark_width(source);

    while (offset < source.len) {
        const blank = blank_scan(source, offset);

        if (blank > offset) {
            offset = blank;

            continue;
        }

        const token = token_of(source, offset);

        assert(token.offset == offset);
        assert(token.length > 0);

        try tokens.push(source, token);
        offset = token.end();
    }

    assert(offset == source.len);
}

fn blank_scan(source: []const u8, start: u32) u32 {
    assert(start <= source.len);

    var offset = start;

    while (offset < source.len) : (offset += 1) {
        switch (source[offset]) {
            ' ', '\n', '\t', '\r' => {},
            else => break,
        }
    }

    assert(offset >= start);
    assert(offset <= source.len);

    return offset;
}

fn word_of(text: []const u8) Kind {
    assert(text.len > 0);

    return keywords.get(text) orelse .identifier;
}

fn token_of(source: []const u8, offset: u32) Token {
    assert(offset < source.len);

    const byte = source[offset];
    const next = scan.byte_at(source, offset + 1) orelse 0;

    const scanned: Scanned = switch (byte) {
        '/' => if (next == '/') comment_of(source, offset) else operator_of(source, offset),
        '\\' => if (next == '\\') text_line_of(source, offset) else literal_of(source, offset),
        '"', '\'', '@' => literal_of(source, offset),
        '{' => .{ .kind = .brace_open, .end = offset + 1 },
        '}' => .{ .kind = .brace_close, .end = offset + 1 },
        '0'...'9' => .{ .kind = .number, .end = number_end(source, offset) },
        else => if (is_identifier_start_at(source, offset))
            word_scanned(source, offset)
        else
            operator_of(source, offset),
    };

    assert(scanned.end > offset);
    assert(scanned.end <= source.len);
    assert(scanned.kind.is_token());

    return .{
        .offset = offset,
        .length = scanned.end - offset,
        .kind = scanned.kind.token_kind(),
        .code = scanned.kind.to_u16(),
    };
}

const Scanned = struct {
    kind: Kind,
    end: u32,
};

const Read = struct {
    end: u32,
    lexeme: Lexeme,
};

fn read_of(source: []const u8, start: u32) Read {
    assert(start < source.len);

    var tokenizer: Tokenizer = .{ .index = start, .source = source };
    const lexeme = tokenizer.next();

    assert(lexeme.start >= start);
    assert(tokenizer.index >= lexeme.start);
    assert(tokenizer.index <= source.len);

    return .{ .end = tokenizer.index, .lexeme = lexeme };
}

fn literal_of(source: []const u8, start: u32) Scanned {
    assert(start < source.len);

    const read = read_of(source, start);

    assert(read.lexeme.start == start);
    assert(read.end > start);

    const kind: Kind = switch (read.lexeme.tag) {
        .builtin => .builtin,
        .character => .character,
        .identifier => .identifier,
        .invalid => .error_token,
        .text => .text,
        .text_line => .text_line,
        else => unreachable,
    };

    return .{ .kind = kind, .end = read.end };
}

fn text_line_of(source: []const u8, start: u32) Scanned {
    assert(start + 1 < source.len);
    assert(source[start] == '\\');
    assert(source[start + 1] == '\\');

    const end = line_body_end(source, start, scan.line_end(source, start));
    if (is_clean(source[start..end])) return .{ .kind = .text_line, .end = end };
    return literal_of(source, start);
}

fn line_body_end(source: []const u8, start: u32, line_end: u32) u32 {
    assert(start < line_end);
    assert(line_end <= source.len);

    const paired = line_end < source.len and source[line_end - 1] == '\r';

    if (paired) assert(source[line_end] == '\n');

    return if (paired) line_end - 1 else line_end;
}

fn is_clean(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    for (text) |byte| {
        if (byte < 0x20) return false;
        if (byte == 0x7f) return false;
    }

    return true;
}

fn number_end(source: []const u8, start: u32) u32 {
    assert(start < source.len);
    assert(std.ascii.isDigit(source[start]));

    var index = start + 1;
    var floating = false;

    for (start..source.len) |_| {
        const byte = scan.byte_at(source, index) orelse break;

        if (is_number_part(byte)) {
            index += 1;
        } else if (is_exponent_mark(byte)) {
            index += 1;

            if (is_sign(scan.byte_at(source, index) orelse 0)) {
                index += 1;
                floating = true;
            }
        } else {
            if (byte != '.') break;
            if (floating) break;

            const next = scan.byte_at(source, index + 1) orelse break;

            if (is_number_part(next)) {
                index += 2;
            } else if (is_exponent_mark(next)) {
                index += 1;
            } else {
                break;
            }

            floating = true;
        }
    }

    assert(index > start);
    assert(index <= source.len);

    return index;
}

fn is_number_part(byte: u8) bool {
    return switch (byte) {
        '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => true,
        else => false,
    };
}

fn is_exponent_mark(byte: u8) bool {
    return switch (byte) {
        'e', 'E', 'p', 'P' => true,
        else => false,
    };
}

fn is_sign(byte: u8) bool {
    return byte == '-' or byte == '+';
}

fn comment_of(source: []const u8, start: u32) Scanned {
    assert(start + 1 < source.len);
    assert(source[start] == '/');
    assert(source[start + 1] == '/');

    const line_end = scan.line_end(source, start);
    const end = line_body_end(source, start, line_end);
    const text = source[start..end];

    assert(end > start + 1);

    if (is_clean(text)) return .{ .kind = comment_kind_of(text), .end = end };

    const bound = if (line_end < source.len) line_end + 1 else line_end;
    const read = read_of(source[0..bound], start);

    assert(read.lexeme.start == start);

    const kind: Kind = switch (read.lexeme.tag) {
        .container_doc_comment, .doc_comment => .doc_comment,
        .invalid => .error_token,
        else => unreachable,
    };

    assert(read.end > start + 1);

    return .{ .kind = kind, .end = read.end };
}

fn comment_kind_of(text: []const u8) Kind {
    assert(std.mem.startsWith(u8, text, "//"));

    if (std.mem.startsWith(u8, text, "//!")) return .doc_comment;
    if (!std.mem.startsWith(u8, text, "///")) return .comment;
    if (std.mem.startsWith(u8, text, "////")) return .comment;
    return .doc_comment;
}

fn identifier_scan(source: []const u8, start: u32) u32 {
    assert(is_identifier_start_at(source, start));

    return primitives.identifier_scan_with(
        source,
        start,
        scan.is_identifier_part,
        primitives.never_part,
    );
}

fn is_identifier_start_at(source: []const u8, offset: u32) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(offset < std.math.maxInt(u32));

    const start = primitives.is_identifier_start;
    return primitives.is_identifier_start_with(source, offset, start, primitives.never_part);
}

fn operator_of(source: []const u8, offset: u32) Scanned {
    assert(offset < source.len);

    const dereferenced_twice = std.mem.startsWith(u8, source[offset..], ".**");
    if (dereferenced_twice) return .{ .kind = .error_token, .end = offset + 2 };

    var width: u32 = operator_width_max;

    while (width > 0) : (width -= 1) {
        if (offset + width > source.len) continue;

        if (operators.get(source[offset..][0..width])) |kind| {
            return .{ .kind = kind, .end = offset + width };
        }
    }

    const stray = scan.punctuation_of(source, offset);

    assert(stray.punctuation == .other);
    assert(stray.length > 0);

    return .{ .kind = .error_token, .end = offset + stray.length };
}

fn word_scanned(source: []const u8, offset: u32) Scanned {
    assert(source.len <= std.math.maxInt(u32));
    assert(offset <= source.len);

    const end = identifier_scan(source, offset);

    assert(end > offset);

    return .{ .kind = word_of(source[offset..end]), .end = end };
}

test "a character literal ends where the zig tokenizer ends it" {
    const source = "fn f() void {\n    const r = 'a';\n    const q = '\\'';\n" ++
        "    const w = '\\u{1F600}';\n}\n";

    try expect_texts(.zig, source, .string, &.{ "'a'", "'\\''", "'\\u{1F600}'" });
}

test "a stray apostrophe closes at the next one or is invalid to the end of its line" {
    const paired = "fn f() void {\n    const s = 'don't;\n}\n";
    const invalid: Token.Kind = .{ .punctuation = .other };

    try expect_texts(.zig, paired, .string, &.{"'don'"});
    try expect_texts(.zig, "fn f() void {\n    const s = 'a\n}\n", invalid, &.{"'a"});
    try expect_texts(.zig, "fn f() void {\n    const s = 'a", invalid, &.{"'a"});
}

const Case = struct {
    word: []const u8,
    source: []const u8,
    kind: Token.Kind,
};

const keyword_cases = [_]Case{
    .{
        .word = "addrspace",
        .source = "extern fn f() addrspace(.generic) void;\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "align",
        .source = "const Store = struct {\n    value: u32 align(4),\n};\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "allowzero",
        .source = "fn f(value: *allowzero u32) void {}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "and",
        .source = "fn f(a: bool, b: bool) bool {\n    return a and b;\n}\n",
        .kind = .{ .punctuation = .ampersand_double },
    },
    .{
        .word = "anyframe",
        .source = "fn f(handle: anyframe) void {}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "anytype",
        .source = "fn f(value: anytype) void {}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "asm",
        .source = "fn f() void {\n    asm volatile (\"nop\");\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "async",
        .source = "fn f(task: fn () void) void {\n    _ = async task();\n}\n",
        .kind = .identifier,
    },
    .{
        .word = "await",
        .source = "fn f(handle: anyframe) void {\n    await handle;\n}\n",
        .kind = .identifier,
    },
    .{
        .word = "break",
        .source = "fn f() void {\n    while (true) {\n        break;\n    }\n}\n",
        .kind = .{ .keyword = .@"break" },
    },
    .{
        .word = "callconv",
        .source = "fn f() callconv(.C) void {}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "catch",
        .source = "fn f() void {\n    read() catch {};\n}\n",
        .kind = .{ .keyword = .except },
    },
    .{
        .word = "comptime",
        .source = "fn f(comptime T: type) void {}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "const",
        .source = "const limit = 4;\n",
        .kind = .{ .keyword = .constant },
    },
    .{
        .word = "continue",
        .source = "fn f() void {\n    while (true) {\n        continue;\n    }\n}\n",
        .kind = .{ .keyword = .@"continue" },
    },
    .{
        .word = "defer",
        .source = "fn f(handle: Handle) void {\n    defer handle.close();\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "else",
        .source = "fn f(flag: bool) void {\n    if (flag) {\n    } else {\n    }\n}\n",
        .kind = .{ .keyword = .branch_else },
    },
    .{
        .word = "enum",
        .source = "const Kind = enum {\n    null,\n};\n",
        .kind = .{ .keyword = .@"struct" },
    },
    .{
        .word = "errdefer",
        .source = "fn f(handle: Handle) void {\n    errdefer handle.close();\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "error",
        .source = "const Failure = error{Bad};\n",
        .kind = .{ .keyword = .@"struct" },
    },
    .{
        .word = "export",
        .source = "export fn f() void {}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "extern",
        .source = "extern fn f() void;\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "fn",
        .source = "fn f() void {}\n",
        .kind = .{ .keyword = .function },
    },
    .{
        .word = "for",
        .source = "fn f(values: []const u32) void {\n    for (values) |value| {\n" ++
            "        _ = value;\n    }\n}\n",
        .kind = .{ .keyword = .loop },
    },
    .{
        .word = "if",
        .source = "fn f(flag: bool) void {\n    if (flag) {\n    }\n}\n",
        .kind = .{ .keyword = .branch },
    },
    .{
        .word = "inline",
        .source = "fn f(values: []const u32) void {\n    inline for (values) |value| {\n" ++
            "        _ = value;\n    }\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "linksection",
        .source = "export fn f() linksection(\".text\") void {}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "noalias",
        .source = "fn f(noalias value: *u32) void {}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "noinline",
        .source = "noinline fn f() void {}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "nosuspend",
        .source = "fn f(handle: anyframe) void {\n    nosuspend await handle;\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "opaque",
        .source = "const Handle = opaque {};\n",
        .kind = .{ .keyword = .@"struct" },
    },
    .{
        .word = "or",
        .source = "fn f(a: bool, b: bool) bool {\n    return a or b;\n}\n",
        .kind = .{ .punctuation = .bar_double },
    },
    .{
        .word = "orelse",
        .source = "fn f(value: ?u32) u32 {\n    return value orelse 0;\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "packed",
        .source = "const Store = packed struct {\n    value: u32,\n};\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "pub",
        .source = "pub fn f() void {}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "resume",
        .source = "fn f(handle: anyframe) void {\n    resume handle;\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "return",
        .source = "fn f() u32 {\n    return 0;\n}\n",
        .kind = .{ .keyword = .@"return" },
    },
    .{
        .word = "struct",
        .source = "const Store = struct {\n    value: u32,\n};\n",
        .kind = .{ .keyword = .@"struct" },
    },
    .{
        .word = "suspend",
        .source = "fn f() void {\n    suspend {}\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "switch",
        .source = "fn f(value: u32) void {\n    switch (value) {\n        else => {},\n    }\n" ++
            "}\n",
        .kind = .{ .keyword = .match },
    },
    .{
        .word = "test",
        .source = "test \"a claim holds\" {}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "threadlocal",
        .source = "threadlocal var count: u32 = 0;\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "try",
        .source = "fn f() !void {\n    try read();\n}\n",
        .kind = .{ .keyword = .@"try" },
    },
    .{
        .word = "union",
        .source = "const Value = union {\n    count: u32,\n};\n",
        .kind = .{ .keyword = .@"struct" },
    },
    .{
        .word = "unreachable",
        .source = "fn f() void {\n    unreachable;\n}\n",
        .kind = .{ .keyword = .assert },
    },
    .{
        .word = "usingnamespace",
        .source = "pub usingnamespace @import(\"std\");\n",
        .kind = .identifier,
    },
    .{
        .word = "var",
        .source = "var count: u32 = 0;\n",
        .kind = .{ .keyword = .mutable },
    },
    .{
        .word = "volatile",
        .source = "fn f(value: *volatile u32) void {}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "while",
        .source = "fn f(flag: bool) void {\n    while (flag) {\n    }\n}\n",
        .kind = .{ .keyword = .loop },
    },
};

const punctuation_cases = [_]Case{
    .{
        .word = "!",
        .source = "fn f() !void {\n    try read();\n}\n",
        .kind = .{ .punctuation = .bang },
    },
    .{
        .word = "!=",
        .source = "fn f(a: u32, b: u32) bool {\n    return a != b;\n}\n",
        .kind = .{ .punctuation = .not_equal },
    },
    .{
        .word = "&",
        .source = "fn f(a: u32, b: u32) u32 {\n    return a & b;\n}\n",
        .kind = .{ .punctuation = .ampersand },
    },
    .{
        .word = "(",
        .source = "fn f() void {}\n",
        .kind = .{ .punctuation = .paren_open },
    },
    .{
        .word = ")",
        .source = "fn f() void {}\n",
        .kind = .{ .punctuation = .paren_close },
    },
    .{
        .word = "*",
        .source = "fn f(a: u32, b: u32) u32 {\n    return a * b;\n}\n",
        .kind = .{ .punctuation = .star },
    },
    .{
        .word = "+",
        .source = "fn f(a: u32, b: u32) u32 {\n    return a + b;\n}\n",
        .kind = .{ .punctuation = .other },
    },
    .{
        .word = ",",
        .source = "fn f(a: u32, b: u32) void {}\n",
        .kind = .{ .punctuation = .comma },
    },
    .{
        .word = "-",
        .source = "fn f(a: u32, b: u32) u32 {\n    return a - b;\n}\n",
        .kind = .{ .punctuation = .other },
    },
    .{
        .word = ".",
        .source = "fn f(store: Store) u32 {\n    return store.value;\n}\n",
        .kind = .{ .punctuation = .dot },
    },
    .{
        .word = "/",
        .source = "fn f(a: u32, b: u32) u32 {\n    return a / b;\n}\n",
        .kind = .{ .punctuation = .slash },
    },
    .{
        .word = ":",
        .source = "fn f(value: u32) void {}\n",
        .kind = .{ .punctuation = .colon },
    },
    .{
        .word = ";",
        .source = "fn f() void {\n    const value = 1;\n    _ = value;\n}\n",
        .kind = .{ .punctuation = .semicolon },
    },
    .{
        .word = "<",
        .source = "fn f(a: u32, b: u32) bool {\n    return a < b;\n}\n",
        .kind = .{ .punctuation = .less },
    },
    .{
        .word = "<=",
        .source = "fn f(a: u32, b: u32) bool {\n    return a <= b;\n}\n",
        .kind = .{ .punctuation = .less_equal },
    },
    .{
        .word = "=",
        .source = "fn f() void {\n    const value = 1;\n    _ = value;\n}\n",
        .kind = .{ .punctuation = .assign },
    },
    .{
        .word = "==",
        .source = "fn f(a: u32, b: u32) bool {\n    return a == b;\n}\n",
        .kind = .{ .punctuation = .equal },
    },
    .{
        .word = ">",
        .source = "fn f(a: u32, b: u32) bool {\n    return a > b;\n}\n",
        .kind = .{ .punctuation = .greater },
    },
    .{
        .word = ">=",
        .source = "fn f(a: u32, b: u32) bool {\n    return a >= b;\n}\n",
        .kind = .{ .punctuation = .greater_equal },
    },
    .{
        .word = "?",
        .source = "fn f(value: ?u32) void {}\n",
        .kind = .{ .punctuation = .other },
    },
    .{
        .word = "[",
        .source = "fn f(values: []const u32) void {}\n",
        .kind = .{ .punctuation = .bracket_open },
    },
    .{
        .word = "]",
        .source = "fn f(values: []const u32) void {}\n",
        .kind = .{ .punctuation = .bracket_close },
    },
    .{
        .word = "^",
        .source = "fn f(a: u32, b: u32) u32 {\n    return a ^ b;\n}\n",
        .kind = .{ .punctuation = .other },
    },
    .{
        .word = "{",
        .source = "fn f() void {}\n",
        .kind = .block_start,
    },
    .{
        .word = "|",
        .source = "fn f(values: []const u32) void {\n    for (values) |value| {\n" ++
            "        _ = value;\n    }\n}\n",
        .kind = .{ .punctuation = .other },
    },
    .{
        .word = "}",
        .source = "fn f() void {}\n",
        .kind = .block_end,
    },
};

test "every keyword of the specification lexes to its kind" {
    try std.testing.expectEqual(49, keyword_cases.len);

    for (keyword_cases) |case| {
        try expect_kind(.zig, case.source, case.word, case.kind);
    }
}

test "every punctuation of the specification lexes to its kind" {
    for (punctuation_cases) |case| {
        try expect_kind(.zig, case.source, case.word, case.kind);
    }
}

test "an else before an equals at the source end is a branch" {
    var lexed = try Lexed.init(.zig, "else =");
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .{ .keyword = .branch_else });
}

test "an else before a greater than is a branch" {
    var lexed = try Lexed.init(.zig, "else > 1");
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .{ .keyword = .branch_else });
}

test "an else branch is a branch" {
    const source = "fn f(ready: bool) u32 {\n    if (ready) {\n        return 1;\n    " ++
        "} else {\n        return 0;\n    }\n}\n";

    try expect_kind(.zig, source, "else", .{ .keyword = .branch_else });
}

test "an else before a lone equals is a branch" {
    const source = "fn f(ready: bool, value: *u32) void {\n" ++
        "    if (ready) {} else value.* = 1;\n}\n";

    try expect_kind(.zig, source, "else", .{ .keyword = .branch_else });
}

test "an else at the source end is a branch" {
    var lexed = try Lexed.init(.zig, "else");
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .{ .keyword = .branch_else });
}

test "a multiline string line is a string" {
    var lexed = try Lexed.init(.zig, "const text =\n    \\\\a line\n    \\\\another\n;\n");
    defer lexed.deinit();

    try std.testing.expectEqual(2, lexed.count_of(.string));
}

test "a lone backslash is punctuation" {
    var lexed = try Lexed.init(.zig, "const value = \\;");
    defer lexed.deinit();

    try std.testing.expectEqual(0, lexed.count_of(.string));
}

test "a builtin carries its name and stops" {
    var lexed = try Lexed.init(.zig, "const value = @intCast(other);\n");
    defer lexed.deinit();

    const builtin = lexed.find("@intCast").?;

    try std.testing.expectEqual(Token.Kind.identifier, builtin.kind);
    try std.testing.expectEqual(Kind.builtin, builtin.exact_kind(Kind).?);
    try std.testing.expectEqual(14, builtin.offset);
    try std.testing.expectEqual(8, builtin.length);
}

test "an import builtin is a builtin" {
    const source = "const std = @import(\"std\");\n";

    try expect_kind(.zig, source, "@import", .identifier);
    try expect_code(source, "@import", .builtin);
}

test "a quoted builtin name lexes as one identifier" {
    var lexed = try Lexed.init(.zig, "const value = @\"a name\";\n");
    defer lexed.deinit();

    const quoted = lexed.at_offset(14).?;

    try std.testing.expectEqual(Token.Kind.identifier, quoted.kind);
    try std.testing.expectEqual(9, quoted.length);
}

test "a bare at sign is an invalid token" {
    var lexed = try Lexed.init(.zig, "@");
    defer lexed.deinit();

    try std.testing.expectEqual(1, lexed.tokens.count());
    try lexed.expect_kind_at(0, .{ .punctuation = .other });
    try std.testing.expectEqual(1, lexed.token(0).length);
    try expect_code("@", "@", .error_token);
}

test "an at sign at the source end is an invalid token" {
    var lexed = try Lexed.init(.zig, "const value = @");
    defer lexed.deinit();

    const last = lexed.tokens.last().?;

    try std.testing.expect(last.kind.eql(.{ .punctuation = .other }));
    try std.testing.expectEqual(Kind.error_token, last.exact_kind(Kind).?);
    try std.testing.expectEqual(14, last.offset);
    try std.testing.expectEqual(1, last.length);
}

test "a function lexes to its parts" {
    var lexed = try Lexed.init(.zig, "pub fn main() void {\n    const value = 1;\n}\n");
    defer lexed.deinit();

    try lexed.expect_kind_at(1, .{ .keyword = .function });
    try std.testing.expectEqualStrings("main", lexed.text_at(2));
    try lexed.expect_kind_at(6, .block_start);
    try lexed.expect_kind_at(7, .{ .keyword = .constant });
}

test "a builtin import is a builtin and its argument a string" {
    var lexed = try Lexed.init(.zig, "const std = @import(\"std\");");
    defer lexed.deinit();

    try lexed.expect_kind_at(3, .identifier);
    try lexed.expect_kind_at(5, .string);
    try std.testing.expectEqual(Kind.builtin, lexed.token(3).exact_kind(Kind).?);
    try std.testing.expectEqual(Kind.text, lexed.token(5).exact_kind(Kind).?);
}

test "a multiline string covers its line" {
    var lexed = try Lexed.init(.zig, "const text =\n    \\\\one line\n    \\\\two line\n;");
    defer lexed.deinit();

    try lexed.expect_kind_at(3, .string);
    try std.testing.expectEqualStrings("\\\\one line", lexed.text_at(3));
    try lexed.expect_kind_at(4, .string);
}

test "a trailing backslash does not swallow the next line" {
    var lexed = try Lexed.init(.zig, "const s = \"a\\\nfn later() void {}\n");
    defer lexed.deinit();

    try std.testing.expectEqual(Token.Kind.identifier, lexed.find("later").?.kind);
    try std.testing.expectEqualStrings("\"a\\", lexed.text_at(3));
    try std.testing.expectEqual(1, lexed.count_of(.block_start));
}

test "a hexadecimal float is one number" {
    var lexed = try Lexed.init(.zig, "const value = 0x1.fffffep+127;\n");
    defer lexed.deinit();

    try lexed.expect_kind_at(3, .number);
    try std.testing.expectEqualStrings("0x1.fffffep+127", lexed.text_at(3));
}

test "a number runs the way the zig tokenizer runs it" {
    const cases = [_][2][]const u8{
        .{ "const a = 0.fffffep+127;\n", "0.fffffep+127" },
        .{ "const a = 1.import(x);\n", "1.import" },
        .{ "const a = 0x1e+5;\n", "0x1e+5" },
        .{ "const a = 12p-3;\n", "12p-3" },
        .{ "const a = 1e5.5;\n", "1e5.5" },
        .{ "const a = 1..2;\n", "1" },
    };

    for (cases) |case| {
        var lexed = try Lexed.init(.zig, case[0]);
        defer lexed.deinit();

        try lexed.expect_kind_at(3, .number);
        try std.testing.expectEqualStrings(case[1], lexed.text_at(3));
    }
}

test "a comment on a windows line stops before the carriage return" {
    var lexed = try Lexed.init(.zig, "// note\r\nconst value = 1;\r\n");
    defer lexed.deinit();

    try lexed.expect_kind_at(0, .comment);
    try std.testing.expectEqualStrings("// note", lexed.text_at(0));
}

test "an error set merge is not a boolean or" {
    const merge = "const Either = error{A} || error{B};\n";

    try expect_kind(.zig, merge, "||", .{ .punctuation = .other });
    try expect_kind(.zig, "const both = a or b;\n", "or", .{ .punctuation = .bar_double });
}

test "a character is a string" {
    var lexed = try Lexed.init(.zig, "const byte = 'a';");
    defer lexed.deinit();

    try lexed.expect_kind_at(3, .string);
    try std.testing.expectEqualStrings("'a'", lexed.text_at(3));
}

fn expect_code(source: []const u8, word: []const u8, kind: Kind) !void {
    assert(kind.is_token());
    assert(source.len <= std.math.maxInt(u32));
    assert(word.len <= std.math.maxInt(u32));

    var lexed = try Lexed.init(.zig, source);
    defer lexed.deinit();

    const found = lexed.find(word) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(kind, found.exact_kind(Kind).?);
    try std.testing.expectEqual(kind.token_kind(), found.kind);
}

test "every token carries the exact kind it projects from" {
    const source = "pub fn main() !void {\n    const value: u32 = 1 <<| 2;\n" ++
        "    return value.*;\n}\n";

    try expect_code(source, "pub", .pub_keyword);
    try expect_code(source, "fn", .fn_keyword);
    try expect_code(source, "main", .identifier);
    try expect_code(source, "!", .bang);
    try expect_code(source, "{", .brace_open);
    try expect_code(source, "<<|", .less_less_pipe);
    try expect_code(source, "1", .number);
    try expect_code(source, ".*", .dot_asterisk);
    try expect_code(source, "}", .brace_close);
}

test "an operator joins greedily up to four bytes" {
    try expect_code("a <<|= b;\n", "<<|=", .less_less_pipe_equal);
    try expect_code("a ... b;\n", "...", .dot_dot_dot);
    try expect_code("a == b;\n", "==", .equal_equal);
    try expect_code("a = b;\n", "=", .equal);
    try expect_code("const Either = error{A} || error{B};\n", "||", .pipe_pipe);
}

test "an else prong projects to the same branch keyword as an else branch" {
    const source = "fn f(value: u32) u32 {\n    return switch (value) {\n        else => 0,\n" ++
        "    };\n}\n";

    try expect_kind(.zig, source, "else", .{ .keyword = .branch_else });
    try expect_code(source, "else", .else_keyword);
}

test "a doc comment is told from a comment" {
    try expect_code("/// doc\nconst a = 1;\n", "/// doc", .doc_comment);
    try expect_code("//! doc\nconst a = 1;\n", "//! doc", .doc_comment);
    try expect_code("// note\nconst a = 1;\n", "// note", .comment);
    try expect_code("//// note\nconst a = 1;\n", "//// note", .comment);
}

test "a stray byte is an error token of its width" {
    var lexed = try Lexed.init(.zig, "const a = #;\n");
    defer lexed.deinit();

    const stray = lexed.find("#").?;

    try std.testing.expectEqual(Kind.error_token, stray.exact_kind(Kind).?);
    try lexed.expect_kind_at(3, .{ .punctuation = .other });

    var wide = try Lexed.init(.zig, "const a = \u{00e9};\n");
    defer wide.deinit();

    try std.testing.expectEqual(Kind.error_token, wide.token(3).exact_kind(Kind).?);
    try std.testing.expectEqual(2, wide.token(3).length);
}

test "an invalid token starts where the zig tokenizer starts it" {
    const cases = [_][2][]const u8{
        .{ "const a = @\"name;\nconst b = 1;\n", "@\"name;" },
        .{ "const a = @(b);\n", "@(b);" },
        .{ "const a = b\x0bc;\n", "\x0b" },
        .{ "const a = \"b\x01c\";\n", "\"b\x01c\";" },
        .{ "const a = 'b;\nconst c = 1;\n", "'b;" },
        .{ "const a = b.**c;\n", ".*" },
        .{ "// a\x01b\nconst a = 1;\n", "// a\x01b" },
        .{ "// a\rb\nconst a = 1;\n", "// a\rb" },
        .{ "/// a\x7fb\nconst a = 1;\n", "/// a\x7fb" },
        .{ "/// a\x00b\nconst a = 1;\n", "\x00" },
        .{ "const a =\n    \\\\b\x01c\n;\n", "\\\\b\x01c" },
        .{ "const a =\n    \\\\b\tc\n;\n", "\\\\b\tc" },
        .{ "const a = 1; // b\tc\n", "// b\tc" },
        .{ "// a\r\r\nconst a = 1;\n", "// a\r\r" },
        .{ "const a = 1;\n/// b\r", "/// b\r" },
    };

    for (cases) |case| {
        var lexed = try Lexed.init(.zig, case[0]);
        defer lexed.deinit();

        const tokens = lexed.tokens.slice();

        const first = for (tokens) |token| {
            if (token.exact_kind(Kind).? == .error_token) break token;
        } else null;

        try std.testing.expect(first != null);
        try std.testing.expectEqualStrings(case[1], first.?.text(case[0]));
    }
}

test "a doc comment stops at a zero byte the way the zig tokenizer stops it" {
    var lexed = try Lexed.init(.zig, "/// a\x00b\nconst a = 1;\n");
    defer lexed.deinit();

    try std.testing.expectEqualStrings("/// a", lexed.text_at(0));
    try std.testing.expectEqual(Kind.doc_comment, lexed.token(0).exact_kind(Kind).?);
}
