const std = @import("std");
const assert = std.debug.assert;
const Language = @import("../language.zig").Language;
const Token = @import("../token.zig");
const Tokens = @import("../tokens.zig");
const primitives = @import("../lex/primitives.zig");
const scan = @import("../../text/scan.zig");
const unicode = @import("../../text/unicode.zig");

const annotation_binders = [_][]const u8{
    "(",
    "accessor",
    "const",
    "declare",
    "let",
    "override",
    "private",
    "protected",
    "public",
    "readonly",
    "static",
    "var",
};

const assertion_methods = [_][]const u8{
    "deepEqual",
    "deepStrictEqual",
    "doesNotMatch",
    "doesNotReject",
    "doesNotThrow",
    "equal",
    "fail",
    "ifError",
    "match",
    "notDeepEqual",
    "notDeepStrictEqual",
    "notEqual",
    "notStrictEqual",
    "ok",
    "rejects",
    "strictEqual",
    "throws",
};

const assertion_prefixes = [_][]const u8{ "assert", "expect", "invariant" };

const contextual_words = [_][]const u8{
    "abstract",
    "async",
    "declare",
    "implements",
    "infer",
    "is",
    "keyof",
    "namespace",
    "of",
    "override",
    "readonly",
    "satisfies",
    "static",
    "type",
};

const escape_braced_bytes_max: u32 = 8;
const escape_hex_digits_max: u32 = 4;
const head_bytes_max: u32 = 512;
const head_words = [_][]const u8{ "catch", "for", "if", "while", "with" };

const words = std.StaticStringMap(Token.Kind).initComptime(.{
    .{ "async", Token.Kind{ .keyword = .other } },
    .{ "await", Token.Kind{ .keyword = .other } },
    .{ "break", Token.Kind{ .keyword = .@"break" } },
    .{ "case", Token.Kind{ .keyword = .match } },
    .{ "catch", Token.Kind{ .keyword = .except } },
    .{ "class", Token.Kind{ .keyword = .@"struct" } },
    .{ "const", Token.Kind{ .keyword = .constant } },
    .{ "continue", Token.Kind{ .keyword = .@"continue" } },
    .{ "debugger", Token.Kind{ .keyword = .other } },
    .{ "default", Token.Kind{ .keyword = .other } },
    .{ "delete", Token.Kind{ .keyword = .other } },
    .{ "do", Token.Kind{ .keyword = .loop } },
    .{ "else", Token.Kind{ .keyword = .branch_else } },
    .{ "export", Token.Kind{ .keyword = .import } },
    .{ "extends", Token.Kind{ .keyword = .other } },
    .{ "finally", Token.Kind{ .keyword = .other } },
    .{ "for", Token.Kind{ .keyword = .loop } },
    .{ "if", Token.Kind{ .keyword = .branch } },
    .{ "import", Token.Kind{ .keyword = .import } },
    .{ "in", Token.Kind{ .keyword = .other } },
    .{ "instanceof", Token.Kind{ .keyword = .other } },
    .{ "let", Token.Kind{ .keyword = .mutable } },
    .{ "new", Token.Kind{ .keyword = .other } },
    .{ "of", Token.Kind{ .keyword = .other } },
    .{ "return", Token.Kind{ .keyword = .@"return" } },
    .{ "static", Token.Kind{ .keyword = .other } },
    .{ "super", Token.Kind{ .keyword = .other } },
    .{ "switch", Token.Kind{ .keyword = .match } },
    .{ "this", Token.Kind{ .keyword = .other } },
    .{ "throw", Token.Kind{ .keyword = .other } },
    .{ "try", Token.Kind{ .keyword = .@"try" } },
    .{ "typeof", Token.Kind{ .keyword = .other } },
    .{ "var", Token.Kind{ .keyword = .mutable } },
    .{ "void", Token.Kind{ .keyword = .other } },
    .{ "while", Token.Kind{ .keyword = .loop } },
    .{ "with", Token.Kind{ .keyword = .other } },
    .{ "yield", Token.Kind{ .keyword = .other } },
});

const words_typescript = std.StaticStringMap(Token.Kind).initComptime(.{
    .{ "abstract", Token.Kind{ .keyword = .other } },
    .{ "declare", Token.Kind{ .keyword = .other } },
    .{ "enum", Token.Kind{ .keyword = .@"struct" } },
    .{ "implements", Token.Kind{ .keyword = .other } },
    .{ "infer", Token.Kind{ .keyword = .other } },
    .{ "interface", Token.Kind{ .keyword = .@"struct" } },
    .{ "is", Token.Kind{ .keyword = .other } },
    .{ "keyof", Token.Kind{ .keyword = .other } },
    .{ "namespace", Token.Kind{ .keyword = .other } },
    .{ "override", Token.Kind{ .keyword = .other } },
    .{ "readonly", Token.Kind{ .keyword = .other } },
    .{ "satisfies", Token.Kind{ .keyword = .other } },
    .{ "type", Token.Kind{ .keyword = .other } },
});

comptime {
    assert(escape_braced_bytes_max > 1);
    assert(escape_hex_digits_max > 0);

    for (words_typescript.keys()) |word| {
        assert(!words.has(word));
    }
}

const Dialect = @import("dialect.zig").Dialect;
const Kind = @import("kind.zig").Kind;
const jsx = @import("lex/jsx.zig");
const template = @import("lex/template.zig");

pub const Mode = enum {
    code,
    jsx_children,
    jsx_closing,
    jsx_expression,
    jsx_opening,
    substitution,
    template,
};

const Frame = struct {
    mode: Mode,
    depth: u32 = 0,
    values: u64 = 0,
};

const Scanned = struct {
    kind: Kind,
    end: u32,
    coarse: ?Token.Kind = null,
};

pub const Slash = struct {
    offset: u32,
    regex: bool,
};

pub const Lexer = struct {
    coarse_previous: Token.Kind,
    depth: u32,
    dialect: Dialect,
    offset: u32,
    previous: ?Kind,
    slashes: []const Slash,
    source: []const u8,
    stack: [frame_depth_max]Frame,
    tokens: *Tokens,
    value_closed: bool,

    pub fn run(lexer: *Lexer) error{Truncated}!void {
        assert(lexer.depth == 1);
        assert(lexer.offset <= lexer.source.len);

        for (0..step_max) |_| {
            if (lexer.offset >= lexer.source.len) return;

            assert(lexer.depth > 0);

            const before = lexer.offset;

            switch (lexer.stack[lexer.depth - 1].mode) {
                .code, .jsx_expression, .substitution => try lexer.code_step(),
                .jsx_children => try jsx.children_step(lexer),
                .jsx_closing => try jsx.tag_step(lexer, .jsx_closing),
                .jsx_opening => try jsx.tag_step(lexer, .jsx_opening),
                .template => try template.chars_step(lexer),
            }

            assert(lexer.offset > before);
        }

        return error.Truncated;
    }

    pub fn push(lexer: *Lexer, kind: Kind, end: u32) error{Truncated}!void {
        assert(kind.is_token());
        assert(end > lexer.offset);
        assert(end <= lexer.source.len);

        return lexer.push_coarse(kind, Kind.token_kind(kind), end);
    }

    fn push_coarse(lexer: *Lexer, kind: Kind, coarse: Token.Kind, end: u32) error{Truncated}!void {
        const offset = lexer.offset;

        assert(kind.is_token());
        assert(end > offset);

        try lexer.tokens.push(lexer.source, .{
            .offset = offset,
            .length = end - offset,
            .kind = coarse,
            .code = kind.to_u16(),
        });

        lexer.offset = end;

        if (kind == .comment) return;
        if (lexer.keeps_previous(kind)) return;

        lexer.previous = kind;
        lexer.coarse_previous = coarse;

        if (kind == .jsx_tag_end_self) lexer.coarse_previous = .{ .punctuation = .greater };
    }

    fn keeps_previous(lexer: *const Lexer, kind: Kind) bool {
        if (!lexer.dialect.typed()) return false;
        if (kind != .bang) return false;
        if (divides_word(lexer.previous)) return true;
        return divides(lexer.coarse_previous);
    }

    pub fn open(lexer: *Lexer, mode: Mode) error{Truncated}!void {
        if (lexer.depth >= frame_depth_max) return error.Truncated;

        lexer.stack[lexer.depth] = .{ .mode = mode };
        lexer.depth += 1;

        switch (mode) {
            .jsx_expression, .substitution => {
                lexer.previous = .brace_open;
                lexer.coarse_previous = .{ .punctuation = .bracket_open };
            },
            else => {},
        }

        assert(lexer.depth <= frame_depth_max);
    }

    pub fn close(lexer: *Lexer) void {
        assert(lexer.depth > 1);

        lexer.depth -= 1;

        assert(lexer.depth > 0);
    }

    pub fn room(lexer: *const Lexer) bool {
        assert(lexer.depth <= frame_depth_max);

        return lexer.depth < frame_depth_max;
    }

    pub fn top(lexer: *Lexer) *Frame {
        assert(lexer.depth > 0);

        return &lexer.stack[lexer.depth - 1];
    }

    fn code_step(lexer: *Lexer) error{Truncated}!void {
        const source = lexer.source;
        const offset = lexer.offset;

        assert(offset < source.len);

        const blank = scan.whitespace_end(source, offset);

        if (blank > offset) {
            lexer.offset = blank;

            return;
        }

        const frame = lexer.top();

        switch (source[offset]) {
            '{' => {
                brace_value_mark(frame, opens_a_value(lexer.previous));
                frame.depth += 1;

                return lexer.push(.brace_open, offset + 1);
            },
            '}' => return lexer.brace_close_step(frame),
            '`' => {
                try lexer.push(.template_start, offset + 1);

                return lexer.open(.template);
            },
            '<' => if (lexer.dialect.allows_jsx()) {
                if (lexer.jsx_opens(offset)) {
                    try lexer.push(.jsx_tag_start, offset + 1);

                    return lexer.open(.jsx_opening);
                }
            },
            else => {},
        }

        const scanned = lexer.scanned_of(source[offset]);

        assert(scanned.end > offset);
        assert(scanned.end <= source.len);

        if (is_word(scanned.kind)) return lexer.push_word(scanned);
        if (scanned.coarse) |coarse| return lexer.push_coarse(scanned.kind, coarse, scanned.end);
        return lexer.push(scanned.kind, scanned.end);
    }

    fn brace_close_step(lexer: *Lexer, frame: *Frame) error{Truncated}!void {
        const offset = lexer.offset;

        assert(lexer.source[offset] == '}');

        if (frame.depth > 0) {
            frame.depth -= 1;
            lexer.value_closed = brace_value_at(frame);

            return lexer.push(.brace_close, offset + 1);
        }

        lexer.value_closed = false;

        try lexer.push(.brace_close, offset + 1);

        if (frame.mode != .code) lexer.close();
    }

    fn jsx_opens(lexer: *const Lexer, offset: u32) bool {
        assert(lexer.source[offset] == '<');
        assert(lexer.dialect.allows_jsx());

        if (!lexer.room()) return false;

        if (lexer.previous) |previous| {
            if (previous == .brace_close) {
                if (lexer.value_closed) return false;
            }
        }

        return jsx.opens_at(lexer.previous, lexer.source, offset, lexer.dialect.typed());
    }

    fn push_word(lexer: *Lexer, scanned: Scanned) error{Truncated}!void {
        const offset = lexer.offset;

        assert(is_word(scanned.kind));
        assert(scanned.end > offset);

        const typed = lexer.dialect.typed();
        const previous = lexer.coarse_previous;

        const coarse = if (scanned.kind == .private_identifier)
            Token.Kind.identifier
        else
            word_coarse(lexer.source, offset, scanned.end, previous, typed);

        return lexer.push_coarse(scanned.kind, coarse, scanned.end);
    }

    fn greater_scanned(lexer: *const Lexer) Scanned {
        const source = lexer.source;
        const offset = lexer.offset;

        assert(offset < source.len);
        assert(source[offset] == '>');

        if (!lexer.dialect.typed()) return operator_scanned(source, offset, lexer.dialect.typed());

        const closers = greater_run(source, offset);
        const after = offset + closers;
        const single: Scanned = .{ .kind = .greater, .end = offset + 1 };
        const compound = operator_scanned(source, offset, lexer.dialect.typed());

        assert(closers > 0);

        if (std.mem.startsWith(u8, source[after..], "=>")) return single;
        if (scan.byte_at(source, after) != '=') return compound;
        if (scan.byte_at(source, after + 1) == '=') return compound;
        if (lexer.type_closed(closers)) return single;
        return compound;
    }

    fn type_closed(lexer: *const Lexer, closers: u32) bool {
        assert(closers > 0);

        const held = lexer.tokens.slice();
        var depth = closers;
        var index = held.len;

        for (0..type_scan_max) |_| {
            if (index == 0) return false;

            index -= 1;

            const kind = Kind.of_u16(held[index].code) orelse return false;

            switch (kind) {
                .greater => depth += 1,
                .less => {
                    depth -= 1;

                    if (depth == 0) return type_headed(lexer.source, held, index);
                },
                .semicolon => return false,
                else => {},
            }
        }

        return false;
    }

    fn slash_scanned(lexer: *const Lexer) Scanned {
        const source = lexer.source;
        const offset = lexer.offset;

        assert(offset < source.len);
        assert(source[offset] == '/');

        const next = scan.byte_at(source, offset + 1);
        if (next == '/') return .{ .kind = .comment, .end = line_end(source, offset) };
        if (next == '*') return .{ .kind = .comment, .end = comment_block_scan(source, offset) };

        const regex = lexer.slash_forced(offset) orelse lexer.slash_opens_regex(offset);
        const operator = operator_scanned(source, offset, lexer.dialect.typed());
        if (!regex) return operator;

        const end = regex_scan(source, offset) orelse return operator;

        assert(end > offset + 1);

        return .{ .kind = .regex, .end = end };
    }

    fn slash_forced(lexer: *const Lexer, offset: u32) ?bool {
        assert(offset < lexer.source.len);
        assert(lexer.slashes.len <= slash_count_max);

        for (lexer.slashes) |slash| {
            if (slash.offset == offset) return slash.regex;
        }

        return null;
    }

    fn slash_opens_regex(lexer: *const Lexer, offset: u32) bool {
        const source = lexer.source;

        assert(offset < source.len);
        assert(source[offset] == '/');

        if (offset > 0) {
            if (source[offset - 1] == '<') return false;
        }

        if (divides_word(lexer.previous)) return false;
        return !divides_at(source, offset, lexer.coarse_previous);
    }

    fn scanned_of(lexer: *const Lexer, byte: u8) Scanned {
        const source = lexer.source;
        const offset = lexer.offset;

        assert(offset < source.len);
        assert(source[offset] == byte);

        return switch (byte) {
            '0'...'9' => number_scanned(source, offset),
            'A'...'Z', 'a'...'z', '_', '$' => word_scanned(source, offset),
            '"', '\'' => string_scanned(source, offset, byte),
            '#' => hash_scanned(source, offset),
            '-', '<' => html_comment_scanned(source, offset, lexer.dialect.typed()),
            '.' => dot_scanned(source, offset),
            '/' => lexer.slash_scanned(),
            '>' => lexer.greater_scanned(),
            else => if (opens_a_word(source, offset))
                word_scanned(source, offset)
            else
                operator_scanned(source, offset, lexer.dialect.typed()),
        };
    }
};

const brace_value_depth_max: u32 = 64;
const frame_depth_max: u32 = 64;
pub const slash_count_max: u32 = 64;
const step_max: u32 = 1 << 22;
const type_scan_max: u32 = 256;

const keywords = std.StaticStringMap(Kind).initComptime(.{
    .{ "async", .async_keyword },
    .{ "await", .await_keyword },
    .{ "break", .break_keyword },
    .{ "case", .case_keyword },
    .{ "catch", .catch_keyword },
    .{ "class", .class_keyword },
    .{ "const", .const_keyword },
    .{ "continue", .continue_keyword },
    .{ "debugger", .debugger_keyword },
    .{ "default", .default_keyword },
    .{ "delete", .delete_keyword },
    .{ "do", .do_keyword },
    .{ "else", .else_keyword },
    .{ "export", .export_keyword },
    .{ "extends", .extends_keyword },
    .{ "false", .false_keyword },
    .{ "finally", .finally_keyword },
    .{ "for", .for_keyword },
    .{ "function", .function_keyword },
    .{ "if", .if_keyword },
    .{ "import", .import_keyword },
    .{ "in", .in_keyword },
    .{ "instanceof", .instanceof_keyword },
    .{ "let", .let_keyword },
    .{ "new", .new_keyword },
    .{ "null", .null_keyword },
    .{ "of", .of_keyword },
    .{ "return", .return_keyword },
    .{ "static", .static_keyword },
    .{ "super", .super_keyword },
    .{ "switch", .switch_keyword },
    .{ "this", .this_keyword },
    .{ "throw", .throw_keyword },
    .{ "true", .true_keyword },
    .{ "try", .try_keyword },
    .{ "typeof", .typeof_keyword },
    .{ "undefined", .undefined_keyword },
    .{ "var", .var_keyword },
    .{ "void", .void_keyword },
    .{ "while", .while_keyword },
    .{ "with", .with_keyword },
    .{ "yield", .yield_keyword },
});

const operators_three = std.StaticStringMap(Kind).initComptime(.{
    .{ "!==", .bang_equal_equal },
    .{ "&&=", .ampersand_ampersand_equal },
    .{ "**=", .star_star_equal },
    .{ "...", .dot_dot_dot },
    .{ "<<=", .less_less_equal },
    .{ "===", .equal_equal_equal },
    .{ ">>=", .greater_greater_equal },
    .{ "??=", .question_question_equal },
    .{ "||=", .bar_bar_equal },
});

const operators_two = std.StaticStringMap(Kind).initComptime(.{
    .{ "!=", .bang_equal },
    .{ "%=", .percent_equal },
    .{ "&&", .ampersand_ampersand },
    .{ "&=", .ampersand_equal },
    .{ "**", .star_star },
    .{ "*=", .star_equal },
    .{ "++", .plus_plus },
    .{ "+=", .plus_equal },
    .{ "--", .minus_minus },
    .{ "-=", .minus_equal },
    .{ "/=", .slash_equal },
    .{ "<<", .less_less },
    .{ "<=", .less_equal },
    .{ "==", .equal_equal },
    .{ "=>", .arrow },
    .{ ">=", .greater_equal },
    .{ "?.", .question_dot },
    .{ "??", .question_question },
    .{ "^=", .caret_equal },
    .{ "|=", .bar_equal },
    .{ "||", .bar_bar },
});

pub fn lex(source: []const u8, tokens: *Tokens, dialect: Dialect) error{Truncated}!void {
    assert(source.len <= std.math.maxInt(u32));

    return lex_slashed(source, tokens, dialect, &.{});
}

pub fn lex_slashed(
    source: []const u8,
    tokens: *Tokens,
    dialect: Dialect,
    slashes: []const Slash,
) error{Truncated}!void {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.count() == 0);
    assert(slashes.len <= slash_count_max);

    var lexer: Lexer = .{
        .coarse_previous = .newline,
        .depth = 1,
        .dialect = dialect,
        .offset = scan.mark_width(source),
        .previous = null,
        .slashes = slashes,
        .source = source,
        .stack = undefined,
        .tokens = tokens,
        .value_closed = false,
    };

    lexer.stack[0] = .{ .mode = .code };

    try lexer.run();

    assert(lexer.offset == source.len);
    assert(tokens.end_previous <= source.len);
}

fn brace_value_mark(frame: *Frame, value: bool) void {
    if (frame.depth >= brace_value_depth_max) return;

    const mask = @as(u64, 1) << @intCast(frame.depth);

    if (value) {
        frame.values |= mask;
    } else {
        frame.values &= ~mask;
    }

    assert((frame.values & mask != 0) == value);
}

fn brace_value_at(frame: *const Frame) bool {
    if (frame.depth >= brace_value_depth_max) return false;

    const mask = @as(u64, 1) << @intCast(frame.depth);
    const value = frame.values & mask != 0;

    if (value) assert(frame.values != 0);

    return value;
}

fn opens_a_value(previous: ?Kind) bool {
    if (previous == null) return false;

    const kind = previous.?;

    const result = switch (kind) {
        .ampersand, .ampersand_ampersand, .ampersand_ampersand_equal, .ampersand_equal => true,
        .await_keyword, .bang, .bang_equal, .bang_equal_equal, .bar, .bar_bar => true,
        .bar_bar_equal, .bar_equal, .bracket_open, .caret, .caret_equal, .colon => true,
        .comma, .delete_keyword, .dot_dot_dot, .equal, .equal_equal, .equal_equal_equal => true,
        .greater_equal, .greater_greater_equal, .greater_greater_greater_equal => true,
        .in_keyword => true,
        .instanceof_keyword, .less, .less_equal, .less_less, .less_less_equal => true,
        .minus, .minus_equal, .paren_open, .percent, .percent_equal, .plus, .plus_equal => true,
        .question, .question_question, .question_question_equal, .return_keyword => true,
        .slash, .slash_equal, .star, .star_equal, .star_star, .star_star_equal => true,
        .throw_keyword, .tilde, .typeof_keyword, .void_keyword, .yield_keyword => true,
        else => false,
    };

    if (result) assert(kind.is_token());
    if (result) assert(kind != .brace_close);

    return result;
}

fn is_word(kind: Kind) bool {
    if (!kind.is_token()) return false;

    const result = switch (kind) {
        .identifier, .private_identifier => true,
        else => keyword_of_kind(kind),
    };

    if (result) assert(kind.is_token());

    return result;
}

fn keyword_of_kind(kind: Kind) bool {
    if (!kind.is_token()) return false;

    return word_kinds[@backingInt(kind)];
}

const word_kinds: [@typeInfo(Kind).@"enum".field_names.len]bool = word_kinds_of();

fn word_kinds_of() [@typeInfo(Kind).@"enum".field_names.len]bool {
    const names = @typeInfo(Kind).@"enum".field_names;
    var held: [names.len]bool = @splat(false);

    @setEvalBranchQuota(100_000);

    for (names, 0..) |name, index| {
        held[index] = std.mem.endsWith(u8, name, "_keyword");
    }

    assert(held[@backingInt(Kind.if_keyword)]);
    assert(!held[@backingInt(Kind.identifier)]);

    return held;
}

fn divides_word(previous: ?Kind) bool {
    if (previous == null) return false;

    const kind = previous.?;

    const result = switch (kind) {
        .async_keyword, .identifier, .let_keyword, .static_keyword => true,
        .super_keyword, .this_keyword => true,
        else => false,
    };

    if (result) assert(kind.is_token());

    return result;
}

fn divides(previous: Token.Kind) bool {
    assert(previous != .comment);

    return switch (previous) {
        .identifier, .number, .string => true,
        .punctuation => |punctuation| switch (punctuation) {
            .bracket_close, .paren_close => true,
            else => false,
        },
        else => false,
    };
}

fn word_scanned(source: []const u8, offset: u32) Scanned {
    assert(offset < source.len);

    const end = identifier_escaped_scan(source, offset);
    const text = source[offset..end];

    assert(end > offset);

    if (!escapes_named(text)) return .{ .kind = .error_token, .end = end, .coarse = .identifier };
    return .{ .kind = keywords.get(text) orelse .identifier, .end = end };
}

fn escapes_named(text: []const u8) bool {
    var offset: usize = 0;

    assert(text.len > 0);

    for (0..text.len + 1) |_| {
        const slash = std.mem.findScalarPos(u8, text, offset, '\\') orelse return true;
        const scalar = escape_scalar(text, slash) orelse return false;

        if (slash == 0) {
            if (!names_a_start(scalar.value)) return false;
        } else {
            if (!names_a_part(scalar.value)) return false;
        }

        assert(scalar.width > 0);

        offset = slash + scalar.width;
    }

    return true;
}

fn escape_scalar(text: []const u8, slash: usize) ?struct { value: u32, width: usize } {
    assert(slash < text.len);
    assert(text[slash] == '\\');

    if (slash + 2 > text.len) return null;
    if (text[slash + 1] != 'u') return null;

    const braced = slash + 2 < text.len and text[slash + 2] == '{';
    const from = if (braced) slash + 3 else slash + 2;

    const close = if (braced)
        std.mem.findScalarPos(u8, text, from, '}') orelse return null
    else
        from + 4;

    if (close > text.len) return null;
    if (close == from) return null;

    const value = std.fmt.parseInt(u32, text[from..close], 16) catch return null;
    const width = if (braced) close + 1 - slash else close - slash;

    return .{ .value = value, .width = width };
}

fn names_a_start(value: u32) bool {
    if (value == '$') return true;
    if (value == '_') return true;
    if (value < 0x80) return std.ascii.isAlphabetic(@intCast(value));
    if (value > 0x10ffff) return false;
    return unicode.is_id_start(@intCast(value));
}

fn names_a_part(value: u32) bool {
    if (value == 0x200c) return true;
    if (value == 0x200d) return true;
    if (names_a_start(value)) return true;
    if (value < 0x80) return std.ascii.isDigit(@intCast(value));
    if (value > 0x10ffff) return false;
    return unicode.is_id_continue(@intCast(value));
}

fn word_coarse(
    source: []const u8,
    offset: u32,
    end: u32,
    previous: Token.Kind,
    typed: bool,
) Token.Kind {
    assert(end <= source.len);
    assert(end > offset);
    assert(previous != .comment);

    const text = source[offset..end];

    if (is_assertion(source, text, end)) return .{ .keyword = .assert };
    if (previous.eql(.{ .punctuation = .dot })) return .identifier;
    if (names_a_binding(previous, text)) return .identifier;
    if (names_a_property(source, end, previous, text)) return .identifier;

    if (std.mem.eql(u8, text, "function")) {
        return .{ .keyword = function_keyword(source, end) };
    }

    return coarse_word_of(text, typed) orelse .identifier;
}

fn string_scanned(source: []const u8, offset: u32, quote: u8) Scanned {
    assert(offset < source.len);
    assert(source[offset] == quote);

    const end = primitives.string_scan_continued(source, offset, quote);
    const text = source[offset..end];

    if (string_closed(text, quote)) {
        if (template.escapes_valid(text, false)) return .{ .kind = .string, .end = end };
    }

    return .{ .kind = .error_token, .end = end, .coarse = .string };
}

fn string_closed(text: []const u8, quote: u8) bool {
    assert(text.len > 0);
    assert(text[0] == quote);

    if (text.len < 2) return false;
    if (text[text.len - 1] != quote) return false;

    var escapes: u32 = 0;
    var back = text.len - 1;

    while (back > 1) : (back -= 1) {
        if (text[back - 1] != '\\') break;

        escapes += 1;
    }

    return escapes % 2 == 0;
}

fn number_scanned(source: []const u8, offset: u32) Scanned {
    assert(offset < source.len);

    const end = primitives.number_scan_bounded(source, offset, .one_sided);

    assert(end > offset);

    if (number_valid(source[offset..end])) return .{ .kind = .number, .end = end };
    return .{ .kind = .error_token, .end = end, .coarse = .number };
}

fn number_valid(text: []const u8) bool {
    assert(text.len > 0);

    if (text.len >= 2) {
        if (text[0] == '0') {
            const radix: u8 = switch (std.ascii.toLower(text[1])) {
                'b' => 2,
                'o' => 8,
                'x' => 16,
                else => 0,
            };

            if (radix != 0) return radix_valid(text[2..], radix);
        }
    }

    const big = text[text.len - 1] == 'n';
    const mantissa = if (big) text[0 .. text.len - 1] else text;
    if (mantissa.len == 0) return false;

    const legacy = mantissa.len >= 2 and mantissa[0] == '0' and std.ascii.isDigit(mantissa[1]);
    if (legacy) return !big and legacy_valid(mantissa);

    if (mantissa.len >= 2) {
        if (mantissa[0] == '0') {
            if (mantissa[1] == '_') return false;
        }
    }

    return decimal_valid(mantissa, big);
}

fn radix_valid(text: []const u8, radix: u8) bool {
    assert(radix == 2 or radix == 8 or radix == 16);
    assert(text.len <= std.math.maxInt(u32));

    const big = text.len > 0 and text[text.len - 1] == 'n';
    const digits = if (big) text[0 .. text.len - 1] else text;
    const end = digits_scanned(digits, 0, radix) orelse return false;

    return end == digits.len;
}

fn legacy_valid(text: []const u8) bool {
    assert(text.len >= 2);
    assert(text[0] == '0');

    var at: usize = 0;

    while (at < text.len) : (at += 1) {
        if (!std.ascii.isDigit(text[at])) break;
    }

    if (at == text.len) return true;
    if (std.mem.findAny(u8, text[0..at], "89") == null) return false;
    return decimal_tail_valid(text, at, true, false);
}

fn decimal_valid(text: []const u8, big: bool) bool {
    assert(text.len > 0);

    if (text[0] == '.') return decimal_tail_valid(text, 0, false, big);

    const end = digits_scanned(text, 0, 10) orelse return false;
    return decimal_tail_valid(text, end, true, big);
}

fn decimal_tail_valid(text: []const u8, from: usize, integer: bool, big: bool) bool {
    assert(from <= text.len);

    var at = from;
    const dotted = at < text.len and text[at] == '.';

    if (dotted) {
        if (big) return false;

        at += 1;

        const fraction_follows = at < text.len and std.ascii.isDigit(text[at]);

        if (fraction_follows) {
            at = digits_scanned(text, at, 10) orelse return false;
        } else {
            if (!integer) return false;
        }
    }

    const exponent_follows = at < text.len and std.ascii.toLower(text[at]) == 'e';

    if (exponent_follows) {
        if (big) return false;

        at += 1;

        const signed = at < text.len and (text[at] == '+' or text[at] == '-');

        if (signed) at += 1;

        at = digits_scanned(text, at, 10) orelse return false;
    }

    return at == text.len;
}

fn digits_scanned(text: []const u8, from: usize, radix: u8) ?usize {
    assert(from <= text.len);
    assert(radix >= 2);
    assert(radix <= 16);

    if (from >= text.len) return null;
    if (!digit_of(text[from], radix)) return null;

    var at = from + 1;

    while (at < text.len) {
        if (digit_of(text[at], radix)) {
            at += 1;

            continue;
        }

        const separated = text[at] == '_' and at + 1 < text.len and digit_of(text[at + 1], radix);
        if (!separated) break;

        at += 2;
    }

    assert(at <= text.len);

    return at;
}

fn digit_of(byte: u8, radix: u8) bool {
    assert(radix >= 2);
    assert(radix <= 16);
    if (!std.ascii.isAlphanumeric(byte)) return false;

    const value = std.fmt.charToDigit(byte, radix) catch return false;
    return value < radix;
}

fn hash_scanned(source: []const u8, offset: u32) Scanned {
    assert(offset < source.len);
    assert(source[offset] == '#');

    const shebang = offset == 0 and scan.byte_at(source, 1) == '!';
    if (shebang) return .{ .kind = .comment, .end = line_end(source, offset) };

    if (is_identifier_start_dollar_at(source, offset + 1)) {
        return .{ .kind = .private_identifier, .end = identifier_escaped_scan(source, offset + 1) };
    }

    return .{ .kind = .error_token, .end = offset + 1 };
}

fn html_comment_scanned(source: []const u8, offset: u32, typed: bool) Scanned {
    assert(offset < source.len);
    assert(source[offset] == '-' or source[offset] == '<');

    const rest = source[offset..];
    const opens = std.mem.startsWith(u8, rest, "<!--");
    const closes = std.mem.startsWith(u8, rest, "-->") and opens_a_line(source, offset);
    const comment = opens or closes;
    if (comment) return .{ .kind = .comment, .end = line_end(source, offset) };
    return operator_scanned(source, offset, typed);
}

fn dot_scanned(source: []const u8, offset: u32) Scanned {
    assert(offset < source.len);
    assert(source[offset] == '.');

    if (std.mem.startsWith(u8, source[offset..], "...")) {
        return .{ .kind = .dot_dot_dot, .end = offset + 3 };
    }

    const next = scan.byte_at(source, offset + 1) orelse 0;
    if (std.ascii.isDigit(next)) return number_scanned(source, offset);
    return .{ .kind = .dot, .end = offset + 1 };
}

fn operator_scanned(source: []const u8, offset: u32, typed: bool) Scanned {
    assert(offset < source.len);

    if (std.mem.startsWith(u8, source[offset..], "<<!--")) {
        return .{ .kind = .less, .end = offset + 1 };
    }

    if (!typed) {
        if (shift_scanned(source, offset)) |scanned| return scanned;
    }

    if (typed) {
        if (std.mem.startsWith(u8, source[offset..], "<<")) {
            if (jsx.arrow_after_angles(source, offset + 1, true)) {
                return .{ .kind = .less, .end = offset + 1 };
            }
        }
    }

    if (offset + 4 <= source.len) {
        if (std.mem.eql(u8, source[offset..][0..4], ">>>=")) {
            return .{ .kind = .greater_greater_greater_equal, .end = offset + 4 };
        }
    }

    if (offset + 3 <= source.len) {
        if (operators_three.get(source[offset..][0..3])) |kind| {
            return .{ .kind = kind, .end = offset + 3 };
        }
    }

    if (operator_two(source, offset)) |kind| return .{ .kind = kind, .end = offset + 2 };

    const byte = source[offset];

    if (byte >= 0x80) {
        const width: u32 = if (unicode.decode(source, offset)) |scalar| scalar.width else 1;
        return .{ .kind = .error_token, .end = offset + width };
    }

    return .{ .kind = operator_one(byte), .end = offset + 1 };
}

fn greater_run(source: []const u8, offset: u32) u32 {
    assert(offset < source.len);
    assert(source[offset] == '>');

    var run: u32 = 0;

    for (source[offset..]) |byte| {
        if (byte != '>') break;

        run += 1;
    }

    assert(run > 0);

    return run;
}

fn type_headed(source: []const u8, held: []const Token, open: usize) bool {
    assert(open < held.len);
    assert(source.len <= std.math.maxInt(u32));

    const name = coded_before(held, open) orelse return false;
    const lead = coded_before(held, name) orelse return false;
    const lead_text = held[lead].text(source);

    if (held[name].kind != .identifier) return false;
    if (std.mem.eql(u8, lead_text, "type")) return true;
    if (!std.mem.eql(u8, lead_text, ":")) return false;

    const marked = coded_before(held, lead) orelse return false;
    const optional = std.mem.eql(u8, held[marked].text(source), "?");
    const bound = if (optional) coded_before(held, marked) orelse return false else marked;
    const binder = coded_before(held, bound) orelse return false;
    const binder_text = held[binder].text(source);

    if (held[bound].kind != .identifier) return false;
    if (std.mem.eql(u8, binder_text, ",")) return paren_enclosed(held, binder);

    for (annotation_binders) |word| {
        if (std.mem.eql(u8, binder_text, word)) return true;
    }

    return false;
}

fn paren_enclosed(held: []const Token, from: usize) bool {
    assert(from < held.len);

    var depth: u32 = 0;
    var at = from;

    for (0..held.len) |_| {
        if (at == 0) return false;

        at -= 1;

        const kind = Kind.of_u16(held[at].code) orelse return false;

        switch (kind) {
            .brace_close, .bracket_close, .paren_close => depth += 1,
            .brace_open, .bracket_open => {
                if (depth == 0) return false;

                depth -= 1;
            },
            .paren_open => {
                if (depth == 0) return true;

                depth -= 1;
            },
            else => {},
        }
    }

    return false;
}

fn coded_before(held: []const Token, index: usize) ?usize {
    assert(index < held.len);

    var at = index;

    for (0..held.len) |_| {
        if (at == 0) return null;

        at -= 1;

        if (held[at].kind != .comment) return at;
    }

    return null;
}

fn shift_scanned(source: []const u8, offset: u32) ?Scanned {
    assert(offset < source.len);

    const rest = source[offset..];

    if (std.mem.startsWith(u8, rest, ">>>")) {
        if (scan.byte_at(source, offset + 3) == '=') return null;
        return .{ .kind = .greater_greater_greater, .end = offset + 3 };
    }

    if (std.mem.startsWith(u8, rest, ">>")) {
        if (scan.byte_at(source, offset + 2) == '=') return null;
        return .{ .kind = .greater_greater, .end = offset + 2 };
    }

    return null;
}

fn operator_two(source: []const u8, offset: u32) ?Kind {
    assert(offset <= source.len);

    if (offset + 2 > source.len) return null;

    const kind = operators_two.get(source[offset..][0..2]) orelse return null;

    if (kind == .question_dot) {
        const after = offset + 2;

        if (after < source.len) {
            if (std.ascii.isDigit(source[after])) return null;
        }
    }

    assert(kind.is_token());

    return kind;
}

fn operator_one(byte: u8) Kind {
    assert(!std.ascii.isAlphanumeric(byte));

    const result: Kind = switch (byte) {
        '!' => .bang,
        '%' => .percent,
        '&' => .ampersand,
        '(' => .paren_open,
        ')' => .paren_close,
        '*' => .star,
        '+' => .plus,
        ',' => .comma,
        '-' => .minus,
        '.' => .dot,
        '/' => .slash,
        ':' => .colon,
        ';' => .semicolon,
        '<' => .less,
        '=' => .equal,
        '>' => .greater,
        '?' => .question,
        '@' => .at,
        '[' => .bracket_open,
        ']' => .bracket_close,
        '^' => .caret,
        '|' => .bar,
        '~' => .tilde,
        else => .error_token,
    };

    assert(result.is_token());

    return result;
}

fn coarse_word_of(text: []const u8, typed: bool) ?Token.Kind {
    assert(text.len > 0);

    const typed_word = if (typed) words_typescript.get(text) else null;
    const kind = typed_word orelse words.get(text) orelse return null;

    assert(kind == .keyword);

    return kind;
}

fn opens_a_word(source: []const u8, offset: u32) bool {
    assert(offset < source.len);

    if (is_identifier_start_dollar_at(source, offset)) return true;
    return opens_an_escape(source, offset);
}

fn is_identifier_start_dollar_at(source: []const u8, offset: u32) bool {
    assert(offset <= source.len);

    if (scan.byte_at(source, offset) == '$') return true;

    const start = primitives.is_identifier_start;
    return primitives.is_identifier_start_with(source, offset, start, unicode.is_id_start);
}

fn opens_an_escape(source: []const u8, offset: u32) bool {
    assert(offset < source.len);

    if (source[offset] != '\\') return false;
    return scan.byte_at(source, offset + 1) == 'u';
}

fn identifier_escaped_scan(source: []const u8, start: u32) u32 {
    assert(start < source.len);
    assert(is_identifier_start_dollar_at(source, start) or opens_an_escape(source, start));

    var offset = start;

    while (offset < source.len) {
        const byte = source[offset];

        if (byte == '\\') {
            if (!opens_an_escape(source, offset)) break;

            offset = escape_end(source, offset);

            continue;
        }

        if (byte < 0x80) {
            if (!scan.is_javascript_identifier_part(byte)) break;

            offset += 1;

            continue;
        }

        const scalar = unicode.decode(source, offset) orelse break;
        if (!unicode.is_id_continue(scalar.value)) break;

        offset += scalar.width;
    }

    assert(offset > start);
    assert(offset <= source.len);

    return offset;
}

fn escape_end(source: []const u8, offset: u32) u32 {
    assert(opens_an_escape(source, offset));

    const digits = offset + 2;
    if (scan.byte_at(source, digits) == '{') return escape_braced_end(source, digits);

    const ceiling: u32 = @intCast(@min(source.len, digits + escape_hex_digits_max));
    var end = digits;

    while (end < ceiling) : (end += 1) {
        if (!std.ascii.isHex(source[end])) break;
    }

    assert(end >= digits);
    assert(end <= source.len);

    return end;
}

fn escape_braced_end(source: []const u8, open: u32) u32 {
    assert(open < source.len);
    assert(source[open] == '{');

    const ceiling: u32 = @intCast(@min(source.len, open + escape_braced_bytes_max));
    var close = open;

    while (close < ceiling) : (close += 1) {
        if (source[close] == '}') break;
    }

    assert(close > open);
    assert(close <= source.len);

    if (close == source.len) return close;
    assert(close + 1 <= source.len);

    return close + 1;
}

fn is_assertion(source: []const u8, text: []const u8, end: u32) bool {
    assert(text.len > 0);
    assert(end <= source.len);

    if (!names_an_assertion(text)) return false;

    var offset = end;

    while (offset < source.len) : (offset += 1) {
        if (source[offset] != ' ') break;
    }

    const after = scan.byte_at(source, offset);
    if (after == '(') return true;
    if (after != '.') return false;
    if (!std.mem.eql(u8, text, "assert")) return false;

    const method = offset + 1;
    var stop = method;

    while (stop < source.len) : (stop += 1) {
        if (!scan.is_identifier_part(source[stop])) break;
    }

    if (!scan.word_in(&assertion_methods, source[method..stop])) return false;
    return scan.byte_at(source, stop) == '(';
}

fn names_an_assertion(text: []const u8) bool {
    assert(text.len > 0);

    for (assertion_prefixes) |prefix| {
        assert(prefix.len > 0);

        if (!std.mem.startsWith(u8, text, prefix)) continue;
        if (text.len == prefix.len) return true;
        if (!std.ascii.isLower(text[prefix.len])) return true;
    }

    return false;
}

fn names_a_binding(previous: Token.Kind, text: []const u8) bool {
    assert(text.len > 0);
    assert(previous != .comment);

    const declares = switch (previous) {
        .keyword => |keyword| keyword == .constant or keyword == .mutable,
        else => false,
    };

    if (!declares) return false;
    return scan.word_in(&contextual_words, text);
}

fn names_a_property(source: []const u8, end: u32, previous: Token.Kind, text: []const u8) bool {
    assert(end <= source.len);
    assert(text.len > 0);
    assert(previous != .comment);

    switch (previous) {
        .block_end, .block_start => {},
        .punctuation => |punctuation| switch (punctuation) {
            .comma, .semicolon => {},
            else => return false,
        },
        else => return false,
    }

    const cursor = space_skip_forward(source, end);
    const colon = if (scan.byte_at(source, cursor) == '?') cursor + 1 else cursor;
    if (scan.byte_at(source, colon) != ':') return false;
    return !std.mem.eql(u8, text, "default");
}

fn space_skip_forward(source: []const u8, start: u32) u32 {
    assert(start <= source.len);

    var cursor = start;

    while (cursor < source.len) : (cursor += 1) {
        const byte = source[cursor];
        const blank = byte == ' ' or byte == '\t';
        if (!blank) break;
    }

    assert(cursor >= start);
    assert(cursor <= source.len);

    return cursor;
}

fn function_keyword(source: []const u8, end: u32) Token.Keyword {
    assert(end <= source.len);

    var offset = ascii_whitespace_skip(source, end);

    if (scan.byte_at(source, offset) == '*') offset = ascii_whitespace_skip(source, offset + 1);

    assert(offset >= end);

    if (is_identifier_start_dollar_at(source, offset)) return .function;
    return .lambda;
}

fn ascii_whitespace_skip(source: []const u8, start: u32) u32 {
    assert(start <= source.len);

    var end = start;

    while (end < source.len) : (end += 1) {
        if (!scan.is_ascii_whitespace(source[end])) break;
    }

    assert(end >= start);
    assert(end <= source.len);

    return end;
}

fn opens_a_line(source: []const u8, start: u32) bool {
    assert(start <= source.len);

    const mark = scan.mark_width(source);
    var cursor = start;

    while (cursor > mark) {
        const byte = source[cursor - 1];
        if (byte == '\n') return true;
        if (byte == '\r') return true;

        if (byte < 0x80) {
            if (!scan.is_ascii_whitespace(byte)) return false;

            cursor -= 1;

            continue;
        }

        const scalar = unicode.decode_before(source, cursor) orelse return false;
        if (unicode.is_line_terminator(scalar.value)) return true;
        if (!unicode.is_whitespace(scalar.value)) return false;

        cursor -= scalar.width;
    }

    return true;
}

fn line_end(source: []const u8, start: u32) u32 {
    assert(start <= source.len);

    var offset = start;

    while (offset < source.len) : (offset += 1) {
        if (source[offset] == '\n') break;
        if (terminates_a_line(source, offset)) break;
    }

    var held = offset;

    while (held > start) : (held -= 1) {
        if (source[held - 1] != '\r') break;
    }

    assert(held >= start);
    assert(held <= offset);

    return held;
}

fn terminates_a_line(source: []const u8, offset: u32) bool {
    assert(offset < source.len);

    if (source[offset] < 0x80) return false;

    const scalar = unicode.decode(source, offset) orelse return false;
    return unicode.is_line_terminator(scalar.value);
}

fn comment_block_scan(source: []const u8, start: u32) u32 {
    assert(start + 1 < source.len);
    assert(source[start] == '/');
    assert(source[start + 1] == '*');

    const close = std.mem.findPos(u8, source, start + 2, "*/") orelse {
        assert(source.len <= std.math.maxInt(u32));

        return @intCast(source.len);
    };

    assert(close >= start + 2);

    return @intCast(close + 2);
}

fn divides_at(source: []const u8, start: u32, previous: Token.Kind) bool {
    assert(start < source.len);
    assert(source[start] == '/');

    if (follows_increment(source, start)) return true;
    assert(previous != .comment);

    if (!previous.eql(.{ .punctuation = .paren_close })) return divides(previous);
    return !heads_a_statement(source, start);
}

fn follows_increment(source: []const u8, start: u32) bool {
    assert(start <= source.len);

    const cursor = space_skip_back(source, start);

    assert(cursor <= start);

    if (cursor < 2) return false;

    const pair = source[cursor - 2 .. cursor];
    return std.mem.eql(u8, pair, "++") or std.mem.eql(u8, pair, "--");
}

fn heads_a_statement(source: []const u8, start: u32) bool {
    assert(start <= source.len);

    const close = space_skip_back(source, start);
    if (close == 0) return false;
    if (source[close - 1] != ')') return false;

    const floor = close -| head_bytes_max;
    var depth: u32 = 0;
    var offset = close;

    while (offset > floor) {
        offset -= 1;

        switch (source[offset]) {
            ')' => depth += 1,
            '(' => {
                assert(depth > 0);

                depth -= 1;

                if (depth == 0) return word_before(source, space_skip_back(source, offset));
            },
            else => {},
        }
    }

    return false;
}

fn space_skip_back(source: []const u8, start: u32) u32 {
    assert(start <= source.len);

    var cursor = start;

    while (cursor > 0) {
        const byte = source[cursor - 1];
        const blank = byte == ' ' or byte == '\t';

        if (blank) {
            cursor -= 1;

            continue;
        }

        if (!std.mem.endsWith(u8, source[0..cursor], scan.byte_order_mark)) break;

        cursor -= scan.byte_order_mark.len;
    }

    assert(cursor <= start);

    return cursor;
}

fn word_before(source: []const u8, end: u32) bool {
    assert(end <= source.len);

    const start = word_start_before(source, end);

    assert(start <= end);

    if (start == end) return false;
    return scan.word_in(&head_words, source[start..end]);
}

fn word_start_before(source: []const u8, end: u32) u32 {
    assert(end <= source.len);

    var start = end;

    while (start > 0) : (start -= 1) {
        if (!scan.is_javascript_identifier_part(source[start - 1])) break;
    }

    assert(start <= end);

    return start;
}

fn regex_scan(source: []const u8, start: u32) ?u32 {
    assert(start < source.len);
    assert(source[start] == '/');

    var class = false;
    var offset = start + 1;

    while (offset < source.len) {
        if (terminates_a_line(source, offset)) return null;

        switch (source[offset]) {
            '\n', '\r' => return null,
            '\\' => {
                if (offset + 1 == source.len) return null;
                if (source[offset + 1] == '\n') return null;
                if (source[offset + 1] == '\r') return null;
                if (terminates_a_line(source, offset + 1)) return null;

                offset += 2;

                continue;
            },
            '[' => class = true,
            ']' => class = false,
            '/' => if (!class) {
                assert(offset + 1 <= source.len);

                return flags_scan(source, offset + 1);
            },
            else => {},
        }

        offset += 1;
    }

    return null;
}

fn flags_scan(source: []const u8, start: u32) u32 {
    assert(start > 0);
    assert(start <= source.len);
    assert(source[start - 1] == '/');

    if (start == source.len) return start;
    if (!scan.is_identifier_part(source[start])) return start;
    if (scan.whitespace_width(source, start) > 0) return start;

    const part = scan.is_identifier_part;
    return primitives.identifier_scan_with(source, start, part, unicode.is_id_continue);
}

const Case = struct {
    word: []const u8,
    source: []const u8,
    kind: Token.Kind,
};

const Shape = struct {
    source: []const u8,
    text: []const u8,
};

const Lexed = struct {
    source: []const u8,
    tokens: Tokens,

    fn init(language: Language, source: []const u8) !Lexed {
        assert(source.len <= std.math.maxInt(u32));
        assert(language == .javascript or language == .typescript);

        var tokens: Tokens = try .init(std.testing.allocator, lexed_token_count_max);
        errdefer tokens.deinit(std.testing.allocator);

        const dialect: Dialect = if (language == .javascript) .javascript else .typescript;

        try lex(source, &tokens, dialect);

        return .{ .source = source, .tokens = tokens };
    }

    fn deinit(lexed: *Lexed) void {
        lexed.tokens.deinit(std.testing.allocator);
        lexed.* = undefined;
    }

    fn count_of(lexed: *const Lexed, kind: Token.Kind) u32 {
        var count: u32 = 0;

        for (lexed.tokens.slice()) |held| {
            if (held.kind.eql(kind)) count += 1;
        }

        return count;
    }

    fn expect_kind_at(lexed: *const Lexed, index: u32, kind: Token.Kind) !void {
        try std.testing.expect(index < lexed.tokens.count());
        try std.testing.expectEqual(kind, lexed.token(index).kind);
    }

    fn find(lexed: *const Lexed, word: []const u8) ?Token {
        assert(word.len <= std.math.maxInt(u32));

        for (lexed.tokens.slice()) |held| {
            if (std.mem.eql(u8, held.text(lexed.source), word)) return held;
        }

        return null;
    }

    fn token(lexed: *const Lexed, index: u32) Token {
        assert(index < lexed.tokens.count());

        return lexed.tokens.slice()[index];
    }
};

const lexed_token_count_max = 4_096;

fn expect_kind(language: Language, source: []const u8, word: []const u8, kind: Token.Kind) !void {
    assert(word.len > 0);
    assert(source.len <= std.math.maxInt(u32));
    assert(language == .javascript or language == .typescript);

    var lexed: Lexed = try .init(language, source);
    defer lexed.deinit();

    const found = lexed.find(word) orelse {
        std.debug.print("{s} is not lexed as a token of its own\n", .{word});

        return error.TestUnexpectedResult;
    };

    try std.testing.expectEqual(kind, found.kind);
}

fn expect_texts(
    language: Language,
    source: []const u8,
    kind: Token.Kind,
    expected: []const []const u8,
) !void {
    assert(source.len <= std.math.maxInt(u32));
    assert(expected.len <= std.math.maxInt(u32));
    assert(language == .javascript or language == .typescript);

    var lexed: Lexed = try .init(language, source);
    defer lexed.deinit();

    var matched: u32 = 0;

    for (lexed.tokens.slice()) |held| {
        if (!held.kind.eql(kind)) continue;

        try std.testing.expect(matched < expected.len);
        try std.testing.expectEqualStrings(expected[matched], held.text(source));

        matched += 1;
    }

    try std.testing.expectEqual(expected.len, matched);
}

fn expect_spelled(language: Language, source: []const u8, expected: []const []const u8) !void {
    assert(source.len <= std.math.maxInt(u32));
    assert(language == .javascript or language == .typescript);

    var lexed: Lexed = try .init(language, source);
    defer lexed.deinit();

    const held = lexed.tokens.slice();

    assert(expected.len > 0);

    try std.testing.expectEqual(expected.len, held.len);

    for (held, expected) |token, text| {
        try std.testing.expectEqualStrings(text, token.text(source));
    }
}

fn expect_contains(
    language: Language,
    source: []const u8,
    kind: Token.Kind,
    text: []const u8,
) !void {
    assert(source.len <= std.math.maxInt(u32));
    assert(text.len <= std.math.maxInt(u32));
    assert(language == .javascript or language == .typescript);

    var lexed: Lexed = try .init(language, source);
    defer lexed.deinit();

    for (lexed.tokens.slice()) |token| {
        if (!token.kind.eql(kind)) continue;
        if (std.mem.eql(u8, token.text(source), text)) return;
    }

    std.debug.print("{s} carries no {s} {s}\n", .{ source, kind.name(), text });

    return error.TestUnexpectedResult;
}

fn expect_count(language: Language, source: []const u8, kind: Token.Kind, count: u32) !void {
    assert(source.len <= std.math.maxInt(u32));
    assert(language == .javascript or language == .typescript);

    var lexed: Lexed = try .init(language, source);
    defer lexed.deinit();

    try std.testing.expectEqual(count, lexed.count_of(kind));
}

fn expect_first(
    language: Language,
    source: []const u8,
    kind: Token.Kind,
    text: []const u8,
) !void {
    assert(source.len <= std.math.maxInt(u32));
    assert(text.len <= std.math.maxInt(u32));
    assert(language == .javascript or language == .typescript);

    var lexed: Lexed = try .init(language, source);
    defer lexed.deinit();

    for (lexed.tokens.slice()) |token| {
        if (!token.kind.eql(kind)) continue;

        try std.testing.expectEqualStrings(text, token.text(source));

        return;
    }

    std.debug.print("{s} carries no {s} token\n", .{ source, kind.name() });

    return error.TestUnexpectedResult;
}

fn expect_leading(language: Language, source: []const u8, kind: Token.Kind) !void {
    assert(source.len <= std.math.maxInt(u32));
    assert(language == .javascript or language == .typescript);

    var lexed: Lexed = try .init(language, source);
    defer lexed.deinit();

    try lexed.expect_kind_at(0, kind);
}

test "an escape opens only on a backslash and a u" {
    try std.testing.expect(opens_an_escape("\\u0041", 0));
    try std.testing.expect(!opens_an_escape("\\n", 0));
    try std.testing.expect(!opens_an_escape("u0041", 0));
    try std.testing.expect(!opens_an_escape("\\", 0));
    try std.testing.expect(opens_an_escape("a\\u0041", 1));
}

test "an escape ends where its form says" {
    try std.testing.expectEqual(6, escape_end("\\u0041x", 0));
    try std.testing.expectEqual(6, escape_end("\\u0041", 0));
    try std.testing.expectEqual(4, escape_end("\\u00", 0));
    try std.testing.expectEqual(2, escape_end("\\uZZZZ", 0));
    try std.testing.expectEqual(6, escape_end("\\u00412", 0));
    try std.testing.expectEqual(6, escape_end("\\u{41}x", 0));
    try std.testing.expectEqual(9, escape_end("\\u{1F600}", 0));
    try std.testing.expectEqual(5, escape_end("\\u{41", 0));
    try std.testing.expectEqual(7, escape_end("a\\u0041", 1));
}

test "a braced escape stops at the cap rather than scanning the file" {
    try std.testing.expectEqual(11, escape_end("\\u{0000000000}", 0));
    try std.testing.expectEqual(10, escape_end("\\u{000000}", 0));
    try std.testing.expectEqual(11, escape_end("\\u{00000000", 0));
}

test "a blank run forward stops at the first byte that is not a space" {
    try std.testing.expectEqual(3, space_skip_forward("   x", 0));
    try std.testing.expectEqual(3, space_skip_forward("\t \tx", 0));
    try std.testing.expectEqual(0, space_skip_forward("x  ", 0));
    try std.testing.expectEqual(3, space_skip_forward("   ", 0));
    try std.testing.expectEqual(0, space_skip_forward("", 0));
    try std.testing.expectEqual(3, space_skip_forward("a  b", 1));
    try std.testing.expectEqual(1, space_skip_forward(" \n ", 0));
}

test "an increment is read only where two bytes stand for it" {
    try std.testing.expect(follows_increment("a++", 3));
    try std.testing.expect(follows_increment("a-- ", 4));
    try std.testing.expect(!follows_increment("++", 1));
    try std.testing.expect(!follows_increment("a+", 2));
    try std.testing.expect(!follows_increment("", 0));
    try std.testing.expect(!follows_increment("a+-", 3));
    try std.testing.expect(follows_increment("++", 2));
    try std.testing.expect(follows_increment("--", 2));
}

test "a head word is the one directly before the parentheses" {
    try std.testing.expect(word_before("if", 2));
    try std.testing.expect(word_before("while", 5));
    try std.testing.expect(word_before("catch", 5));
    try std.testing.expect(!word_before("", 0));
    try std.testing.expect(!word_before("if(", 3));
    try std.testing.expect(!word_before("xif", 3));
    try std.testing.expect(!word_before("function", 8));
    try std.testing.expect(word_before("} if", 4));
}

test "a statement head needs its own word before its own parentheses" {
    try std.testing.expect(heads_a_statement("if (a) ", 7));
    try std.testing.expect(heads_a_statement("while (a(b)) ", 13));
    try std.testing.expect(!heads_a_statement("foo(a) ", 7));
    try std.testing.expect(!heads_a_statement("", 0));
    try std.testing.expect(!heads_a_statement("if a ", 5));
    try std.testing.expect(!heads_a_statement("(a) ", 4));
    try std.testing.expect(!heads_a_statement(") ", 2));
    try std.testing.expect(!heads_a_statement("a) ", 3));
}

test "a slash behind a tag and a comment close are read as themselves" {
    try expect_count(.javascript, "const a = <b></b>;\n", .string, 0);
    try expect_leading(.javascript, "<!-- a -->\nconst b = 1;\n", .comment);
    try expect_leading(.javascript, "--> a\n", .comment);
    try expect_count(.javascript, "const a = b - c;\n", .comment, 0);
    try expect_count(.javascript, "const a = b --> c;\n", .comment, 0);
}

test "a tag after a block's closing brace opens an element" {
    try std.testing.expectEqual(1, try tags_opened("if (a) {}\n<div />;\n"));
    try std.testing.expectEqual(2, try tags_opened("function f() {}\n<div>text</div>;\n"));
    try std.testing.expectEqual(0, try tags_opened("if (a) {}\nb < c;\n"));
    try std.testing.expectEqual(0, try tags_opened("const d = e < f;\n"));
}

fn tags_opened(source: []const u8) !u32 {
    assert(source.len <= std.math.maxInt(u32));

    var lexed: Lexed = try .init(.javascript, source);
    defer lexed.deinit();

    const tokens = lexed.tokens.slice();
    var count: u32 = 0;

    for (tokens) |token| {
        const kind = token.exact_kind(Kind).?;
        const opens = kind == .jsx_tag_start or kind == .jsx_tag_start_close;

        if (opens) count += 1;
    }

    assert(count <= tokens.len);

    return count;
}

test "a tag after an object's closing brace is a comparison" {
    try std.testing.expectEqual(0, try tags_opened("f({ a: 1 }\n<div\n);\n"));
    try std.testing.expectEqual(0, try tags_opened("const g = {} < h;\n"));
    try std.testing.expectEqual(1, try tags_opened("const i = [{}, <div />];\n"));
    try std.testing.expectEqual(1, try tags_opened("const j = () => {}\n<div />;\n"));
    try std.testing.expectEqual(1, try tags_opened("class K extends L<{}> {}\n<div />;\n"));
}

test "a template closes past its nested frames" {
    try std.testing.expectEqual(3, try template_closes_at("`a`x"));
    try std.testing.expectEqual(8, try template_closes_at("`a${b}c`x"));
    try std.testing.expectEqual(10, try template_closes_at("`a${`b`}c`x"));
    try std.testing.expectEqual(13, try template_closes_at("`a${{b: 1}}c`x"));
    try std.testing.expectEqual(10, try template_closes_at("`a${\"`\"}c`x"));
    try std.testing.expectEqual(10, try template_closes_at("`a${'`'}c`x"));
    try std.testing.expectEqual(6, try template_closes_at("`a\\`b`x"));
    try std.testing.expectEqual(2, try template_closes_at("`a"));
}

fn template_closes_at(source: []const u8) !u32 {
    assert(source.len <= std.math.maxInt(u32));

    var lexed: Lexed = try .init(.javascript, source);
    defer lexed.deinit();

    var depth: u32 = 0;

    for (lexed.tokens.slice()) |token| {
        const kind = token.exact_kind(Kind).?;

        if (kind == .template_start) depth += 1;
        if (kind != .template_end) continue;

        assert(depth > 0);

        depth -= 1;

        if (depth == 0) return token.end();
    }

    return lexed.tokens.end_previous;
}

test "a line is open only when nothing but blanks stands before it" {
    try std.testing.expect(opens_a_line("", 0));
    try std.testing.expect(opens_a_line("  x", 2));
    try std.testing.expect(opens_a_line("a\n  x", 4));
    try std.testing.expect(opens_a_line("\nx", 1));
    try std.testing.expect(!opens_a_line("a x", 2));
    try std.testing.expect(!opens_a_line("ax", 2));
}

const keyword_cases = [_]Case{
    .{
        .word = "async",
        .source = "async function run() {}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "await",
        .source = "async function run() {\n    await ready();\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "break",
        .source = "function run() {\n    while (true) {\n        break;\n    }\n}\n",
        .kind = .{ .keyword = .@"break" },
    },
    .{
        .word = "case",
        .source = "function run(value) {\n    switch (value) {\n    case 1:\n        break;\n" ++
            "    }\n}\n",
        .kind = .{ .keyword = .match },
    },
    .{
        .word = "catch",
        .source = "function run() {\n    try {\n    } catch (failure) {\n    }\n}\n",
        .kind = .{ .keyword = .except },
    },
    .{
        .word = "class",
        .source = "class Store {}\n",
        .kind = .{ .keyword = .@"struct" },
    },
    .{
        .word = "const",
        .source = "const value = 1;\n",
        .kind = .{ .keyword = .constant },
    },
    .{
        .word = "continue",
        .source = "function run() {\n    while (true) {\n        continue;\n    }\n}\n",
        .kind = .{ .keyword = .@"continue" },
    },
    .{
        .word = "debugger",
        .source = "function run() {\n    debugger;\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "default",
        .source = "export default run;\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "delete",
        .source = "function run(store) {\n    delete store.value;\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "do",
        .source = "function run() {\n    do {\n    } while (false);\n}\n",
        .kind = .{ .keyword = .loop },
    },
    .{
        .word = "else",
        .source = "function run(value) {\n    if (value) {\n    } else {\n    }\n}\n",
        .kind = .{ .keyword = .branch_else },
    },
    .{
        .word = "export",
        .source = "export const value = 1;\n",
        .kind = .{ .keyword = .import },
    },
    .{
        .word = "extends",
        .source = "class Store extends Base {}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "finally",
        .source = "function run() {\n    try {\n    } finally {\n    }\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "for",
        .source = "function run() {\n    for (;;) {\n    }\n}\n",
        .kind = .{ .keyword = .loop },
    },
    .{
        .word = "function",
        .source = "function run() {}\n",
        .kind = .{ .keyword = .function },
    },
    .{
        .word = "if",
        .source = "function run(value) {\n    if (value) {\n    }\n}\n",
        .kind = .{ .keyword = .branch },
    },
    .{
        .word = "import",
        .source = "import store from \"./store.js\";\n",
        .kind = .{ .keyword = .import },
    },
    .{
        .word = "in",
        .source = "function run(store) {\n    for (const key in store) {\n    }\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "instanceof",
        .source = "function run(value) {\n    return value instanceof Store;\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "let",
        .source = "function run() {\n    let value = 1;\n}\n",
        .kind = .{ .keyword = .mutable },
    },
    .{
        .word = "new",
        .source = "function run() {\n    return new Store();\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "of",
        .source = "function run(values) {\n    for (const value of values) {\n    }\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "return",
        .source = "function run() {\n    return 1;\n}\n",
        .kind = .{ .keyword = .@"return" },
    },
    .{
        .word = "static",
        .source = "class Store {\n    static value = 1;\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "super",
        .source = "class Store extends Base {\n    constructor() {\n        super();\n    }\n" ++
            "}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "switch",
        .source = "function run(value) {\n    switch (value) {\n    }\n}\n",
        .kind = .{ .keyword = .match },
    },
    .{
        .word = "this",
        .source = "class Store {\n    read() {\n        return this.value;\n    }\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "throw",
        .source = "function run() {\n    throw new Error(\"no\");\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "try",
        .source = "function run() {\n    try {\n    } catch (failure) {\n    }\n}\n",
        .kind = .{ .keyword = .@"try" },
    },
    .{
        .word = "typeof",
        .source = "function run(value) {\n    return typeof value;\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "var",
        .source = "function run() {\n    var value = 1;\n}\n",
        .kind = .{ .keyword = .mutable },
    },
    .{
        .word = "void",
        .source = "function run() {\n    void 0;\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "while",
        .source = "function run() {\n    while (false) {\n    }\n}\n",
        .kind = .{ .keyword = .loop },
    },
    .{
        .word = "with",
        .source = "function run(store) {\n    with (store) {\n    }\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "yield",
        .source = "function* run() {\n    yield 1;\n}\n",
        .kind = .{ .keyword = .other },
    },
};

const typed_keyword_cases = [_]Case{
    .{
        .word = "abstract",
        .source = "abstract class Store {}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "declare",
        .source = "declare const value: number;\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "enum",
        .source = "enum Colour {\n    Red,\n}\n",
        .kind = .{ .keyword = .@"struct" },
    },
    .{
        .word = "implements",
        .source = "class Store implements Reader {}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "infer",
        .source = "type Held<T> = T extends Box<infer U> ? U : never;\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "interface",
        .source = "interface Reader {\n    read(): number;\n}\n",
        .kind = .{ .keyword = .@"struct" },
    },
    .{
        .word = "is",
        .source = "function isStore(value: unknown): value is Store {\n    return true;\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "keyof",
        .source = "type Keys = keyof Store;\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "namespace",
        .source = "namespace store {\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "override",
        .source = "class Store extends Base {\n    override read(): number {\n" ++
            "        return 1;\n    }\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "readonly",
        .source = "interface Reader {\n    readonly value: number;\n}\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "satisfies",
        .source = "const value = 1 satisfies number;\n",
        .kind = .{ .keyword = .other },
    },
    .{
        .word = "type",
        .source = "type Value = number;\n",
        .kind = .{ .keyword = .other },
    },
};

test "every typescript keyword keeps its kind in tsx" {
    const gpa = std.testing.allocator;

    for (typed_keyword_cases) |case| {
        var tokens: Tokens = try .init(gpa, 1 << 10);
        defer tokens.deinit(gpa);

        try lex(case.source, &tokens, .tsx);

        const found = for (tokens.slice()) |token| {
            if (std.mem.eql(u8, token.text(case.source), case.word)) break token;
        } else return error.TestUnexpectedResult;

        try std.testing.expectEqual(case.kind, found.kind);
    }
}

test "every keyword of the specification lexes to its kind" {
    for (keyword_cases) |case| {
        try expect_kind(.javascript, case.source, case.word, case.kind);
    }
}

test "every typed keyword of the specification lexes to its kind" {
    for (typed_keyword_cases) |case| {
        try expect_kind(.typescript, case.source, case.word, case.kind);
    }
}

test "a typed keyword is an identifier in javascript" {
    for (typed_keyword_cases) |case| {
        if (std.mem.eql(u8, case.word, "enum")) continue;
        if (std.mem.eql(u8, case.word, "interface")) continue;

        try expect_kind(.javascript, case.source, case.word, .identifier);
    }
}

const template_shapes = [_]Shape{
    .{ .source = "const value = `plain`;\n", .text = "`plain`" },
    .{ .source = "const value = `a${b}c`;\n", .text = "`a${b}c`" },
    .{ .source = "const value = `a${`inner`}c`;\n", .text = "`a${`inner`}c`" },
    .{ .source = "const value = `a${ { b: 1 } }c`;\n", .text = "`a${ { b: 1 } }c`" },
    .{ .source = "const value = `a\\`b`;\n", .text = "`a\\`b`" },
    .{ .source = "const value = `line\nbreak`;\n", .text = "`line\nbreak`" },
    .{ .source = "const value = `${a}${b}`;\n", .text = "`${a}${b}`" },
    .{ .source = "const value = `a$b`;\n", .text = "`a$b`" },
    .{ .source = "const value = `a{b}c`;\n", .text = "`a{b}c`" },
    .{ .source = "const value = `a}b`;\n", .text = "`a}b`" },
    .{ .source = "const value = `${`${a}`}`;\n", .text = "`${`${a}`}`" },
    .{ .source = "const value = `${ { a: 1 } }`;\n", .text = "`${ { a: 1 } }`" },
};

test "every template shape closes where its text ends" {
    for (template_shapes) |shape| {
        const start = std.mem.find(u8, shape.source, shape.text).?;
        const end: u32 = @intCast(start + shape.text.len);

        try std.testing.expectEqual(end, try template_closes_at(shape.source));
        try expect_leading_string(.javascript, shape.source, @intCast(start));
    }
}

fn expect_leading_string(language: Language, source: []const u8, offset: u32) !void {
    assert(source.len <= std.math.maxInt(u32));
    assert(language == .javascript or language == .typescript);

    var lexed: Lexed = try .init(language, source);
    defer lexed.deinit();

    for (lexed.tokens.slice()) |token| {
        if (token.offset != offset) continue;

        try std.testing.expectEqual(Token.Kind.string, token.kind);

        return;
    }

    return error.TestUnexpectedResult;
}

test "an unterminated template runs to the end" {
    const source = "const value = `open;\n";

    try std.testing.expectEqual(source.len, try template_closes_at(source));
}

const regex_shapes = [_]Shape{
    .{ .source = "const found = /ab+c/;\n", .text = "/ab+c/" },
    .{ .source = "const found = /ab+c/gi;\n", .text = "/ab+c/gi" },
    .{ .source = "const found = /a\\/b/;\n", .text = "/a\\/b/" },
    .{ .source = "const found = /[/]/;\n", .text = "/[/]/" },
    .{ .source = "const found = /[a-z]+/u;\n", .text = "/[a-z]+/u" },
    .{ .source = "const found = value.replace(/a/, \"b\");\n", .text = "/a/" },
};

test "every regular expression shape lexes to one string" {
    for (regex_shapes) |shape| {
        try expect_first(.javascript, shape.source, .string, shape.text);
    }
}

test "a regular expression escape cannot reach past the end of its line" {
    const sources = [_][]const u8{
        "const found = /a\\\nb/;\n",
        "const found = /a\\\rb/;\n",
        "const found = /a\\\u{2028}b/;\n",
        "const found = /a\\\u{2029}b/;\n",
        "const found = /a\\",
    };

    for (sources) |source| {
        try expect_count(.javascript, source, .string, 0);
        try expect_kind(.javascript, source, "/", .{ .punctuation = .slash });
    }

    try expect_first(.javascript, "const found = /a\\\u{00e9}b/;\n", .string, "/a\\\u{00e9}b/");
}

test "a division is not a regular expression" {
    const source = "const share = total / count;\n";

    try expect_count(.javascript, source, .string, 0);
    try expect_kind(.javascript, source, "/", .{ .punctuation = .slash });
}

test "a second division on the line is still a division" {
    try expect_count(.javascript, "const share = total / count / 2;\n", .string, 0);
}

test "a slash that never closes is a division" {
    const source = "const found = /open;\n";

    try expect_kind(.javascript, source, "/", .{ .punctuation = .slash });
}

test "a slash that opens the source is a regular expression that never closes" {
    for ([_][]const u8{ "/", "/\n", "/a" }) |source| {
        try expect_leading(.javascript, source, .{ .punctuation = .slash });
    }
}

test "a slash at the end of the source is a division" {
    try expect_kind(.javascript, "const found = /", "/", .{ .punctuation = .slash });
}

test "a forced slash lexes as the parser decided and leaves every other slash alone" {
    const source = "x = await /x/ 2; y = a\n/b/g.exec(s);\n";
    const reference = "x = awaiz /x/ 2; y = (\n/b/g.exec(s);\n";
    const respelled = [_]u32{ 4, 21 };

    const slashes = [_]Slash{
        .{ .offset = 10, .regex = false },
        .{ .offset = 23, .regex = true },
    };

    var guessed: Lexed = try .init(.javascript, source);
    defer guessed.deinit();

    try std.testing.expectEqualStrings("/x/", guessed.find("/x/").?.text(source));
    try std.testing.expect(guessed.find("/b/g") == null);

    var forced: Tokens = try .init(std.testing.allocator, lexed_token_count_max);
    defer forced.deinit(std.testing.allocator);

    var expected: Tokens = try .init(std.testing.allocator, lexed_token_count_max);
    defer expected.deinit(std.testing.allocator);

    try lex_slashed(source, &forced, .javascript, &slashes);
    try lex(reference, &expected, .javascript);
    try std.testing.expectEqual(expected.count(), forced.count());

    for (forced.slice(), expected.slice()) |held, wanted| {
        try std.testing.expectEqual(wanted.offset, held.offset);
        try std.testing.expectEqual(wanted.length, held.length);

        if (std.mem.findScalar(u32, &respelled, held.offset) != null) continue;

        try std.testing.expectEqual(wanted.kind, held.kind);
    }
}

const comment_shapes = [_]Shape{
    .{ .source = "/* note */\nconst value = 1;\n", .text = "/* note */" },
    .{ .source = "/**/\nconst value = 1;\n", .text = "/**/" },
    .{ .source = "/* a\n   b */\nconst value = 1;\n", .text = "/* a\n   b */" },
    .{ .source = "/* a * b */\nconst value = 1;\n", .text = "/* a * b */" },
    .{ .source = "// note\nconst value = 1;\n", .text = "// note" },
    .{ .source = "const value = 1; /* note */\n", .text = "/* note */" },
    .{ .source = "const value = 1; /* a */ const other = 2;\n", .text = "/* a */" },
};

test "every comment shape lexes to one comment" {
    for (comment_shapes) |shape| {
        try expect_first(.javascript, shape.source, .comment, shape.text);
    }
}

test "an unterminated block comment runs to the end" {
    for ([_][]const u8{ "/* open\n", "/* open*", "/* open", "/*", "/*/" }) |source| {
        try expect_first(.javascript, source, .comment, source);
    }
}

test "an unterminated string runs to the end of the line" {
    const double = "const value = \"open\nconst other = 1;\n";
    const single = "const value = 'open\nconst other = 1;\n";

    try expect_first(.javascript, double, .string, "\"open");
    try expect_first(.javascript, single, .string, "'open");
}

test "an unterminated string at the end of the source stops there" {
    try expect_first(.javascript, "const value = \"open", .string, "\"open");
}

const function_cases = [_]Case{
    .{
        .word = "function",
        .source = "function run() {}\n",
        .kind = .{ .keyword = .function },
    },
    .{
        .word = "function",
        .source = "const run = function () {};\n",
        .kind = .{ .keyword = .lambda },
    },
    .{
        .word = "function",
        .source = "function* run() {}\n",
        .kind = .{ .keyword = .function },
    },
    .{
        .word = "function",
        .source = "const run = function* () {};\n",
        .kind = .{ .keyword = .lambda },
    },
    .{
        .word = "function",
        .source = "function  run() {}\n",
        .kind = .{ .keyword = .function },
    },
    .{
        .word = "function",
        .source = "function *run() {}\n",
        .kind = .{ .keyword = .function },
    },
    .{
        .word = "function",
        .source = "const run = function*() {};\n",
        .kind = .{ .keyword = .lambda },
    },
};

test "a named function is a function and an anonymous one is a lambda" {
    for (function_cases) |case| {
        try expect_kind(.javascript, case.source, case.word, case.kind);
    }
}

test "the function word at the end of the source is a lambda" {
    const sources = [_][]const u8{
        "const run = function",
        "const run = function ",
        "const run = function*",
        "const run = function* ",
    };

    for (sources) |source| {
        try expect_kind(.javascript, source, "function", .{ .keyword = .lambda });
    }
}

const assertion_cases = [_]Case{
    .{
        .word = "assert",
        .source = "function f(v) {\n    assert(v);\n}\n",
        .kind = .{ .keyword = .assert },
    },
    .{
        .word = "assert",
        .source = "function f(v) {\n    assert (v);\n}\n",
        .kind = .{ .keyword = .assert },
    },
    .{
        .word = "assertEqual",
        .source = "function f(v) {\n    assertEqual(v, 1);\n}\n",
        .kind = .{ .keyword = .assert },
    },
    .{
        .word = "expect",
        .source = "function f(v) {\n    expect(v).toBe(1);\n}\n",
        .kind = .{ .keyword = .assert },
    },
    .{
        .word = "invariant",
        .source = "function f(v) {\n    invariant(v);\n}\n",
        .kind = .{ .keyword = .assert },
    },
    .{
        .word = "assert",
        .source = "function f(v) {\n    const assert = v;\n}\n",
        .kind = .identifier,
    },
    .{
        .word = "assured",
        .source = "function f(v) {\n    assured(v);\n}\n",
        .kind = .identifier,
    },
    .{
        .word = "expect",
        .source = "function f(v) {\n    expect\n        .anything();\n}\n",
        .kind = .identifier,
    },
};

test "an assertion word needs a call to be a keyword" {
    for (assertion_cases) |case| {
        try expect_kind(.javascript, case.source, case.word, case.kind);
    }
}

test "an assertion word at the end of the source is an identifier" {
    try expect_kind(.javascript, "assert", "assert", .identifier);
}

test "a backslash carries a string over the newline" {
    try expect_first(.javascript, "const plain = 'a\\\nb';\n", .string, "'a\\\nb'");
    try expect_first(.javascript, "const plain = 'a\nconst other = 1;\n", .string, "'a");
}

test "a substitution holding an object does not close its template" {
    const call = "const t = `${f({ a: 1 }, `b`)}`;\n";
    const map = "const t = `${items.map((i) => { return i; })}`;\n";

    try std.testing.expectEqual(call.len - 2, try template_closes_at(call));
    try std.testing.expectEqual(map.len - 2, try template_closes_at(map));
}

test "a quote inside a substitution does not leak" {
    const source = "const t = `${x[\"a\"]}` + 1;\n";

    try std.testing.expectEqual(source.len - 6, try template_closes_at(source));
    try expect_contains(.javascript, source, .number, "1");
}

test "an increment leaves the slash after it a division" {
    try expect_count(.javascript, "const share = sent++ / total * 100 / 2;\n", .string, 0);
}

test "a regular expression after a statement head is not a division" {
    const source = "function f(ok, s) { if (ok) /['\"]/.test(s); }\n";

    try expect_first(.javascript, source, .string, "/['\"]/");
}

test "a call result divided is still a division" {
    try expect_count(.javascript, "const half = size(a) / 2;\n", .string, 0);
}

test "a member name is not a keyword" {
    try expect_kind(.javascript, "cache.delete(key);\n", "delete", .identifier);
    try expect_kind(.javascript, "task.catch(onFailure);\n", "catch", .identifier);
}

test "a contextual keyword bound to a name is a name" {
    const enum_kind: Token.Kind = .{ .keyword = .@"struct" };

    try expect_kind(.typescript, "const type = \"click\";\n", "type", .identifier);

    try expect_kind(.typescript, "type Handler = () => void;\n", "type", .{
        .keyword = .other,
    });

    try expect_kind(.typescript, "const enum Mode {}\n", "enum", enum_kind);
}

test "a closing angle stands alone before the equals sign of a type it closes" {
    const alias = [_][]const u8{ "type", "X", "<", "T", ">", "=", "T", ";" };
    const annotated = [_][]const u8{ "let", "x", ":", "A", "<", "B", ">", "=", "y", ";" };
    const optional = [_][]const u8{ "(", "a", "?", ":", "B", "<", "C", ">", "=", "d", ")" };
    const arrowed = [_][]const u8{ "(", ")", ":", "A", "<", "B", ">", "=>", "c" };
    const labeled = [_][]const u8{ "x", ":", "A", "<", "B", "<", "C", ">>=", "d" };
    const nested = [_][]const u8{ "let", "x", ":", "A", "<", "B", "<", "C", ">", ">", "=", "d" };
    const compared = [_][]const u8{ "let", "a", "=", "b", ">=", "c", ";" };
    const branched = [_][]const u8{ "v", "=", "c", "?", "a", ":", "B", "<", "C", ">=", "d", ";" };
    const untyped = [_][]const u8{ "a", "<", "b", ">=", "c" };

    try expect_spelled(.typescript, "type X<T>=T;", &alias);
    try expect_spelled(.typescript, "let x: A<B>=y;", &annotated);
    try expect_spelled(.typescript, "(a?: B<C>=d)", &optional);
    try expect_spelled(.typescript, "(): A<B>=>c", &arrowed);
    try expect_spelled(.typescript, "x: A<B<C>>=d", &labeled);
    try expect_spelled(.typescript, "let x: A<B<C>>=d", &nested);
    try expect_spelled(.typescript, "let a = b>=c;", &compared);
    try expect_spelled(.typescript, "v = c ? a : B<C>=d;", &branched);
    try expect_spelled(.javascript, "a<b>=c", &untyped);
}

test "an assertion prefix does not swallow a longer word" {
    const assertion: Token.Kind = .{ .keyword = .assert };

    try expect_kind(.javascript, "expectations(rows);\n", "expectations", .identifier);
    try expect_kind(.javascript, "expectThat(rows);\n", "expectThat", assertion);
    try expect_kind(.javascript, "assert_eq(a, b);\n", "assert_eq", assertion);
}

const key_cases = [_]Case{
    .{
        .word = "continue",
        .source = "const options = { continue: false };\n",
        .kind = .identifier,
    },
    .{
        .word = "continue",
        .source = "const options = { code: 1, continue: false };\n",
        .kind = .identifier,
    },
    .{
        .word = "if",
        .source = "interface Options {\n    if?: string;\n}\n",
        .kind = .identifier,
    },
    .{
        .word = "case",
        .source = "const options = { case: \"sensitive\" };\n",
        .kind = .identifier,
    },
};

test "a reserved word is a key where a key belongs" {
    for (key_cases) |case| {
        try expect_kind(.typescript, case.source, case.word, case.kind);
    }
}

test "a switch keeps its clause words" {
    const source = "function f(v) {\n    switch (v) {\n    case 1:\n        break;\n" ++
        "    default:\n        break;\n    }\n}\n";

    try expect_kind(.javascript, source, "case", .{ .keyword = .match });
    try expect_kind(.javascript, source, "default", .{ .keyword = .other });
}

test "a spread is one token rather than three dots" {
    const source = "const all = [...new Set(paths)];\n";

    try expect_kind(.javascript, source, "new", .{ .keyword = .other });
    try expect_first(.javascript, "const all = [...rest];\n", .{ .punctuation = .other }, "...");
}

test "an html like comment is a comment" {
    const opening = "<!-- a comment\nconst value = 1;\n";
    const closing = "--> a comment\nconst value = 1;\n";

    try expect_first(.javascript, opening, .comment, "<!-- a comment");
    try expect_first(.javascript, closing, .comment, "--> a comment");
}

test "a byte order mark is whitespace to the scans that walk back over it" {
    const marked = "\u{feff}--> a comment\nconst value = 1;\n";

    try expect_first(.javascript, marked, .comment, "--> a comment");
    try expect_count(.javascript, "--\xef\xbb\xbf/a/", .string, 0);
    try expect_count(.javascript, "--/a/", .string, 0);
}

test "a line comment carries no carriage return of the break that ends it" {
    try expect_first(.javascript, "// note\r\r\n", .comment, "// note");
    try expect_first(.javascript, "<!--\r\r\n", .comment, "<!--");
    try expect_first(.javascript, "// note\r\n", .comment, "// note");
    try expect_first(.javascript, "// note\n", .comment, "// note");
}

test "a private field lexes as one identifier" {
    const source = "class Store {\n    #value = 1;\n}\n";

    try expect_kind(.javascript, source, "#value", .identifier);
}

test "a one sided dot float is one number" {
    try expect_first(.javascript, "const half = .5;\n", .number, ".5");
    try expect_first(.javascript, "const one = 1.;\n", .number, "1.");
}

test "a hexadecimal literal keeps its subtraction" {
    try expect_first(.javascript, "const left = 0xCAFE-1;\n", .number, "0xCAFE");
}

test "a shebang is a comment only at the head of the file" {
    const source = "#!/usr/bin/env node\n";

    try expect_first(.javascript, source, .comment, "#!/usr/bin/env node");
}

test "a typescript bang is transparent to the division that follows" {
    try expect_count(.typescript, "const share = total! / count / 2;\n", .string, 0);
}

test "a javascript bang is not transparent to the division that follows" {
    const source = "const share = total! / count / 2;\n";

    try expect_first(.javascript, source, .string, "/ count /");
}

test "a comment between a value and a slash keeps the division" {
    try expect_count(.javascript, "const share = total /* note */ / count / 2;\n", .string, 0);
}

test "a slash after a keyword opens a regular expression" {
    try expect_first(.javascript, "function run() {\n    return /a/;\n}\n", .string, "/a/");
}

test "a typescript bang is transparent to the regular expression scan" {
    const source = "const found = value!.replace(/a/, \"b\");\n";

    try expect_first(.typescript, source, .string, "/a/");
}

test "a substitution reads through a block comment holding a brace" {
    const source = "`${ /* ` } */ x }`X";

    try std.testing.expectEqual(source.len - 1, try template_closes_at(source));
}

test "a substitution reads through a line comment holding a brace" {
    const source = "`${ a // ` }\n }`X";

    try std.testing.expectEqual(source.len - 1, try template_closes_at(source));
}

test "a substitution reads through a string holding a brace" {
    const source = "`${ \"}\" }`X";

    try std.testing.expectEqual(source.len - 1, try template_closes_at(source));
}

test "a substitution reads through a regex holding a brace" {
    const source = "`${ /[}`]/.test(a) }`X";

    try std.testing.expectEqual(source.len - 1, try template_closes_at(source));
}

test "a division inside a substitution is not read as a regex" {
    const source = "`${ a / b }` c";

    try std.testing.expectEqual(source.len - 2, try template_closes_at(source));
    try expect_contains(.javascript, source, .{ .punctuation = .slash }, "/");
    try expect_count(.javascript, "`${ return /x/ }`", .string, 4);
}

test "a template ends where the scan says it does" {
    const source = "`${ /* ` } */ x }` after";

    try std.testing.expectEqual(18, try template_closes_at(source));
    try expect_contains(.javascript, source, .identifier, "after");
}

test "a regex ahead of a wide space carries no flags" {
    inline for (.{ "\u{feff}", "\u{00a0}", "\u{2028}" }) |space| {
        const source = "const a = /x/" ++ space ++ ";";

        try expect_texts(.javascript, source, .string, &.{"/x/"});
    }
}

test "a jsx expression container opens a block" {
    const source = "const view = <div title={name}>Hello {name} world</div>;";
    var lexed: Lexed = try .init(.typescript, source);
    defer lexed.deinit();

    try std.testing.expectEqual(4, lexed.count_of(.block_start) + lexed.count_of(.block_end));
}

test "a dollar sign belongs to the identifier it touches" {
    for ([_][]const u8{ "$x", "x$", "$", "$$" }) |source| {
        for ([_]Language{ .javascript, .typescript }) |language| {
            try expect_texts(language, source, .identifier, &.{source});
        }
    }
}

test "a dollar sign carries through a declaration and a call" {
    for ([_]Language{ .javascript, .typescript }) |language| {
        try expect_texts(language, "const $x = $(1)", .identifier, &.{ "$x", "$" });
    }
}

test "a dollar sign joins a private name and a member" {
    const source = "class C { #$a; b() { return this.$c; } }";

    for ([_]Language{ .javascript, .typescript }) |language| {
        try expect_contains(language, source, .identifier, "#$a");
        try expect_contains(language, source, .identifier, "$c");
    }
}

test "an identifier opens and continues with the id properties javascript names" {
    const sources = [_][]const u8{
        "\u{309b}a",
        "a\u{037a}",
        "\u{0e33}",
        "\u{323b0}\u{33479}",
        "a\u{00b7}\u{30fb}",
        "\\u{309b}",
        "a\\u{37a}",
    };

    for (sources) |source| {
        for ([_]Language{ .javascript, .typescript }) |language| {
            try expect_texts(language, source, .identifier, &.{source});
        }
    }

    try expect_count(.javascript, "\u{2e2f}", .identifier, 0);
    try expect_texts(.javascript, "a\u{2e2f}", .identifier, &.{"a"});
}

test "a line separator is whitespace rather than an identifier byte" {
    inline for (.{ "\u{2028}", "\u{2029}", "\u{3000}", "\u{202f}", "\u{feff}" }) |separator| {
        var lexed: Lexed = try .init(.javascript, "const" ++ separator ++ "value = 1\n");
        defer lexed.deinit();

        try lexed.expect_kind_at(0, .{ .keyword = .constant });
    }
}
