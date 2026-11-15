const std = @import("std");
const assert = std.debug.assert;

pub const Tag = enum(u8) {
    addrspace_keyword,
    align_keyword,
    allowzero_keyword,
    ampersand,
    ampersand_equal,
    and_keyword,
    anyframe_keyword,
    anytype_keyword,
    arrow,
    asm_keyword,
    bang,
    bang_equal,
    brace_close,
    brace_open,
    bracket_close,
    bracket_open,
    break_keyword,
    builtin,
    callconv_keyword,
    caret,
    caret_equal,
    catch_keyword,
    character,
    colon,
    comma,
    comptime_keyword,
    const_keyword,
    container_doc_comment,
    continue_keyword,
    defer_keyword,
    doc_comment,
    dot,
    dot_asterisk,
    dot_dot,
    dot_dot_dot,
    else_keyword,
    enum_keyword,
    eof,
    equal,
    equal_equal,
    errdefer_keyword,
    error_keyword,
    export_keyword,
    extern_keyword,
    fn_keyword,
    for_keyword,
    greater,
    greater_equal,
    greater_greater,
    greater_greater_equal,
    identifier,
    if_keyword,
    inline_keyword,
    invalid,
    invalid_dot_asterisks,
    less,
    less_equal,
    less_less,
    less_less_equal,
    less_less_pipe,
    less_less_pipe_equal,
    linksection_keyword,
    minus,
    minus_equal,
    minus_greater,
    minus_percent,
    minus_percent_equal,
    minus_pipe,
    minus_pipe_equal,
    noalias_keyword,
    noinline_keyword,
    nosuspend_keyword,
    number,
    opaque_keyword,
    or_keyword,
    orelse_keyword,
    packed_keyword,
    paren_close,
    paren_open,
    percent,
    percent_equal,
    pipe,
    pipe_equal,
    pipe_pipe,
    plus,
    plus_equal,
    plus_percent,
    plus_percent_equal,
    plus_pipe,
    plus_pipe_equal,
    plus_plus,
    pub_keyword,
    question,
    resume_keyword,
    return_keyword,
    semicolon,
    slash,
    slash_equal,
    star,
    star_equal,
    star_percent,
    star_percent_equal,
    star_pipe,
    star_pipe_equal,
    star_star,
    struct_keyword,
    suspend_keyword,
    switch_keyword,
    test_keyword,
    text,
    text_line,
    threadlocal_keyword,
    tilde,
    try_keyword,
    union_keyword,
    unreachable_keyword,
    var_keyword,
    volatile_keyword,
    while_keyword,

    pub fn is_assignment(tag: Tag) bool {
        return tag == .equal or tag.is_compound();
    }

    pub fn is_attribute_keyword(tag: Tag) bool {
        return switch (tag) {
            .align_keyword, .addrspace_keyword, .linksection_keyword, .callconv_keyword => true,
            else => false,
        };
    }

    pub fn is_compound(tag: Tag) bool {
        return switch (tag) {
            .star_equal,
            .slash_equal,
            .percent_equal,
            .plus_equal,
            .minus_equal,
            .less_less_equal,
            .less_less_pipe_equal,
            .greater_greater_equal,
            .ampersand_equal,
            .caret_equal,
            .pipe_equal,
            .star_percent_equal,
            .plus_percent_equal,
            .minus_percent_equal,
            .star_pipe_equal,
            .plus_pipe_equal,
            .minus_pipe_equal,
            => true,
            else => false,
        };
    }

    pub fn is_container_keyword(tag: Tag) bool {
        return switch (tag) {
            .struct_keyword, .union_keyword, .enum_keyword, .opaque_keyword => true,
            else => false,
        };
    }

    pub fn is_declaration_keyword(tag: Tag) bool {
        return tag == .const_keyword or tag == .var_keyword;
    }

    pub fn is_loop_keyword(tag: Tag) bool {
        return tag == .for_keyword or tag == .while_keyword;
    }

    pub fn is_pointer_modifier(tag: Tag) bool {
        return tag.modifier_bit_of() != null;
    }

    pub fn is_prefix(tag: Tag) bool {
        return switch (tag) {
            .bang, .minus, .tilde, .minus_percent, .ampersand, .try_keyword => true,
            else => false,
        };
    }

    pub fn modifier_bit_of(tag: Tag) ?u8 {
        return switch (tag) {
            .align_keyword => 1 << 0,
            .const_keyword => 1 << 1,
            .volatile_keyword => 1 << 2,
            .allowzero_keyword => 1 << 3,
            .addrspace_keyword => 1 << 4,
            else => null,
        };
    }

    pub fn width(tag: Tag) ?u32 {
        const text: []const u8 = switch (tag) {
            .ampersand => "&",
            .bang => "!",
            .caret => "^",
            .equal_equal => "==",
            .bang_equal => "!=",
            .less => "<",
            .greater => ">",
            .less_equal => "<=",
            .greater_equal => ">=",
            .pipe => "|",
            .orelse_keyword => "orelse",
            .catch_keyword => "catch",
            .less_less => "<<",
            .less_less_pipe => "<<|",
            .greater_greater => ">>",
            .plus => "+",
            .minus => "-",
            .plus_plus => "++",
            .plus_percent => "+%",
            .minus_percent => "-%",
            .plus_pipe => "+|",
            .minus_pipe => "-|",
            .pipe_pipe => "||",
            .star => "*",
            .slash => "/",
            .percent => "%",
            .star_star => "**",
            .star_percent => "*%",
            .star_pipe => "*|",
            .and_keyword => "and",
            .or_keyword => "or",
            else => return null,
        };

        assert(text.len > 0);
        assert(text.len <= operator_width_max);

        return @intCast(text.len);
    }
};

pub const Lexeme = struct {
    start: u32,
    tag: Tag,
};

pub const Tokenizer = struct {
    index: u32,
    source: []const u8,

    pub fn init(source: []const u8) Tokenizer {
        assert(source.len < std.math.maxInt(u32));

        const marked = std.mem.startsWith(u8, source, byte_order_mark);
        const index: u32 = if (marked) byte_order_mark.len else 0;

        assert(index <= source.len);

        return .{ .index = index, .source = source };
    }

    pub fn next(tokenizer: *Tokenizer) Lexeme {
        var lexeme: Lexeme = .{ .start = tokenizer.index, .tag = .invalid };
        var state: State = .start;
        const remaining: u64 = tokenizer.source.len - tokenizer.index;
        const steps = remaining * step_count_per_byte + step_slack;

        for (0..steps) |_| {
            switch (tokenizer.step(state, &lexeme)) {
                .state => |held| state = held,
                .done => {
                    assert(lexeme.start <= tokenizer.index);
                    assert(tokenizer.index <= tokenizer.source.len);

                    return lexeme;
                },
            }
        }

        unreachable;
    }

    fn step(tokenizer: *Tokenizer, state: State, lexeme: *Lexeme) Step {
        assert(tokenizer.index <= tokenizer.source.len);
        assert(lexeme.start <= tokenizer.index);

        return switch (state) {
            .start => tokenizer.lex_start(lexeme),
            .newline_expected => tokenizer.lex_newline_expected(lexeme),
            .invalid => tokenizer.lex_invalid(lexeme),
            .at => tokenizer.lex_at(lexeme),
            .word => tokenizer.lex_word(lexeme),
            .builtin => tokenizer.lex_builtin(),
            .backslash => tokenizer.lex_backslash(lexeme),
            .text => tokenizer.lex_text(lexeme),
            .text_escape => tokenizer.lex_text_escape(lexeme),
            .character => tokenizer.lex_character(lexeme),
            .character_escape => tokenizer.lex_character_escape(lexeme),
            .text_line => tokenizer.lex_text_line(),
            .comment_start => tokenizer.lex_comment_start(lexeme),
            .doc_start => tokenizer.lex_doc_start(lexeme),
            .comment => tokenizer.lex_comment(lexeme),
            .doc => tokenizer.lex_doc(),
            .integer => tokenizer.lex_integer(),
            .integer_exponent => tokenizer.lex_exponent(.integer),
            .integer_dot => tokenizer.lex_integer_dot(),
            .float => tokenizer.lex_float(),
            .float_exponent => tokenizer.lex_exponent(.float),
            else => tokenizer.lex_operator(state, lexeme),
        };
    }

    fn byte(tokenizer: *const Tokenizer) u8 {
        return tokenizer.byte_at(tokenizer.index);
    }

    fn byte_at(tokenizer: *const Tokenizer, index: u32) u8 {
        assert(index < std.math.maxInt(u32));

        if (index >= tokenizer.source.len) return 0;

        return tokenizer.source[index];
    }

    fn ended(tokenizer: *const Tokenizer) bool {
        assert(tokenizer.index <= tokenizer.source.len);

        return tokenizer.index == tokenizer.source.len;
    }

    fn finish(tokenizer: *Tokenizer, lexeme: *Lexeme, tag: Tag) Step {
        assert(tokenizer.index < tokenizer.source.len);

        tokenizer.index += 1;
        lexeme.tag = tag;

        return .done;
    }

    fn eof(tokenizer: *Tokenizer, lexeme: *Lexeme) Step {
        assert(tokenizer.ended());

        lexeme.start = tokenizer.index;
        lexeme.tag = .eof;

        return .done;
    }

    fn skip(tokenizer: *Tokenizer, lexeme: *Lexeme) Step {
        assert(tokenizer.index < tokenizer.source.len);

        tokenizer.index += 1;
        lexeme.start = tokenizer.index;

        return .{ .state = .start };
    }

    fn lex_start(tokenizer: *Tokenizer, lexeme: *Lexeme) Step {
        assert(lexeme.start == tokenizer.index);

        const held = tokenizer.byte();
        if (single_of(held)) |tag| return tokenizer.finish(lexeme, tag);

        return switch (held) {
            0 => if (tokenizer.ended()) tokenizer.eof(lexeme) else .{ .state = .invalid },
            ' ', '\n', '\t', '\r' => tokenizer.skip(lexeme),
            '"' => tokenizer.begin(lexeme, .text, .text),
            '\'' => tokenizer.begin(lexeme, .character, .character),
            'a'...'z', 'A'...'Z', '_' => tokenizer.begin(lexeme, .identifier, .word),
            '\\' => tokenizer.begin(lexeme, .text_line, .backslash),
            '0'...'9' => tokenizer.number_begin(lexeme),
            else => .{ .state = operator_state_of(held) orelse .invalid },
        };
    }

    fn begin(tokenizer: *const Tokenizer, lexeme: *Lexeme, tag: Tag, state: State) Step {
        assert(tokenizer.index < tokenizer.source.len);
        assert(state != .start);

        lexeme.tag = tag;

        return .{ .state = state };
    }

    fn number_begin(tokenizer: *Tokenizer, lexeme: *Lexeme) Step {
        assert(tokenizer.index < tokenizer.source.len);
        assert(std.ascii.isDigit(tokenizer.byte()));

        lexeme.tag = .number;
        tokenizer.index += 1;

        return .{ .state = .integer };
    }

    fn lex_newline_expected(tokenizer: *Tokenizer, lexeme: *Lexeme) Step {
        assert(tokenizer.index < tokenizer.source.len);

        tokenizer.index += 1;

        return switch (tokenizer.byte()) {
            0 => tokenizer.terminal(lexeme),
            '\n' => tokenizer.skip(lexeme),
            else => .{ .state = .invalid },
        };
    }

    fn lex_invalid(tokenizer: *Tokenizer, lexeme: *Lexeme) Step {
        assert(tokenizer.index < tokenizer.source.len);

        tokenizer.index += 1;

        return switch (tokenizer.byte()) {
            0 => tokenizer.terminal(lexeme),
            '\n' => tokenizer.stop(lexeme, .invalid),
            else => .{ .state = .invalid },
        };
    }

    fn terminal(tokenizer: *const Tokenizer, lexeme: *Lexeme) Step {
        assert(tokenizer.index <= tokenizer.source.len);
        assert(tokenizer.byte() == 0);

        if (tokenizer.ended()) return tokenizer.stop(lexeme, .invalid);
        return .{ .state = .invalid };
    }

    fn stop(tokenizer: *const Tokenizer, lexeme: *Lexeme, tag: Tag) Step {
        assert(tokenizer.index <= tokenizer.source.len);
        assert(lexeme.start <= tokenizer.index);

        lexeme.tag = tag;

        return .done;
    }

    fn lex_at(tokenizer: *Tokenizer, lexeme: *Lexeme) Step {
        assert(tokenizer.index < tokenizer.source.len);

        tokenizer.index += 1;

        return switch (tokenizer.byte()) {
            0, '\n' => tokenizer.stop(lexeme, .invalid),
            '"' => tokenizer.begin(lexeme, .identifier, .text),
            'a'...'z', 'A'...'Z', '_' => tokenizer.begin(lexeme, .builtin, .builtin),
            else => .{ .state = .invalid },
        };
    }

    fn lex_word(tokenizer: *Tokenizer, lexeme: *Lexeme) Step {
        assert(tokenizer.index < tokenizer.source.len);
        assert(lexeme.tag == .identifier);

        tokenizer.index += 1;

        switch (tokenizer.byte()) {
            'a'...'z', 'A'...'Z', '_', '0'...'9' => return .{ .state = .word },
            else => {},
        }

        const word = tokenizer.source[lexeme.start..tokenizer.index];

        if (keywords.get(word)) |tag| lexeme.tag = tag;

        return .done;
    }

    fn lex_builtin(tokenizer: *Tokenizer) Step {
        assert(tokenizer.index < tokenizer.source.len);

        tokenizer.index += 1;

        return switch (tokenizer.byte()) {
            'a'...'z', 'A'...'Z', '_', '0'...'9' => .{ .state = .builtin },
            else => .done,
        };
    }

    fn lex_backslash(tokenizer: *Tokenizer, lexeme: *Lexeme) Step {
        assert(tokenizer.index < tokenizer.source.len);
        assert(lexeme.tag == .text_line);

        tokenizer.index += 1;

        return switch (tokenizer.byte()) {
            0, '\n' => tokenizer.stop(lexeme, .invalid),
            '\\' => .{ .state = .text_line },
            else => .{ .state = .invalid },
        };
    }

    fn lex_text(tokenizer: *Tokenizer, lexeme: *Lexeme) Step {
        assert(tokenizer.index < tokenizer.source.len);

        tokenizer.index += 1;

        return switch (tokenizer.byte()) {
            0 => tokenizer.terminal(lexeme),
            '\n' => tokenizer.stop(lexeme, .invalid),
            '\\' => .{ .state = .text_escape },
            '"' => tokenizer.close(),
            0x01...0x09, 0x0b...0x1f, 0x7f => .{ .state = .invalid },
            else => .{ .state = .text },
        };
    }

    fn close(tokenizer: *Tokenizer) Step {
        assert(tokenizer.index < tokenizer.source.len);

        tokenizer.index += 1;

        return .done;
    }

    fn lex_text_escape(tokenizer: *Tokenizer, lexeme: *Lexeme) Step {
        assert(tokenizer.index < tokenizer.source.len);

        tokenizer.index += 1;

        return switch (tokenizer.byte()) {
            0, '\n' => tokenizer.stop(lexeme, .invalid),
            0x01...0x09, 0x0b...0x1f, 0x7f => .{ .state = .invalid },
            else => .{ .state = .text },
        };
    }

    fn lex_character(tokenizer: *Tokenizer, lexeme: *Lexeme) Step {
        assert(tokenizer.index < tokenizer.source.len);

        tokenizer.index += 1;

        return switch (tokenizer.byte()) {
            0 => tokenizer.terminal(lexeme),
            '\n' => tokenizer.stop(lexeme, .invalid),
            '\\' => .{ .state = .character_escape },
            '\'' => tokenizer.close(),
            0x01...0x09, 0x0b...0x1f, 0x7f => .{ .state = .invalid },
            else => .{ .state = .character },
        };
    }

    fn lex_character_escape(tokenizer: *Tokenizer, lexeme: *Lexeme) Step {
        assert(tokenizer.index < tokenizer.source.len);

        tokenizer.index += 1;

        return switch (tokenizer.byte()) {
            0 => tokenizer.terminal(lexeme),
            '\n' => tokenizer.stop(lexeme, .invalid),
            0x01...0x09, 0x0b...0x1f, 0x7f => .{ .state = .invalid },
            else => .{ .state = .character },
        };
    }

    fn lex_text_line(tokenizer: *Tokenizer) Step {
        assert(tokenizer.index < tokenizer.source.len);

        tokenizer.index += 1;

        return switch (tokenizer.byte()) {
            0 => if (tokenizer.ended()) .done else .{ .state = .invalid },
            '\n' => .done,
            '\r' => tokenizer.carriage(),
            0x01...0x09, 0x0b...0x0c, 0x0e...0x1f, 0x7f => .{ .state = .invalid },
            else => .{ .state = .text_line },
        };
    }

    fn carriage(tokenizer: *const Tokenizer) Step {
        assert(tokenizer.index < tokenizer.source.len);
        assert(tokenizer.byte() == '\r');

        if (tokenizer.byte_at(tokenizer.index + 1) == '\n') return .done;
        return .{ .state = .invalid };
    }

    fn lex_comment_start(tokenizer: *Tokenizer, lexeme: *Lexeme) Step {
        assert(tokenizer.index < tokenizer.source.len);

        tokenizer.index += 1;

        return switch (tokenizer.byte()) {
            0 => if (tokenizer.ended()) tokenizer.eof(lexeme) else .{ .state = .invalid },
            '!' => tokenizer.begin(lexeme, .container_doc_comment, .doc),
            '\n' => tokenizer.skip(lexeme),
            '/' => .{ .state = .doc_start },
            '\r' => .{ .state = .newline_expected },
            0x01...0x09, 0x0b...0x0c, 0x0e...0x1f, 0x7f => .{ .state = .invalid },
            else => .{ .state = .comment },
        };
    }

    fn lex_doc_start(tokenizer: *Tokenizer, lexeme: *Lexeme) Step {
        assert(tokenizer.index < tokenizer.source.len);

        tokenizer.index += 1;

        return switch (tokenizer.byte()) {
            0, '\n' => tokenizer.stop(lexeme, .doc_comment),
            '\r' => tokenizer.doc_carriage(lexeme),
            '/' => .{ .state = .comment },
            0x01...0x09, 0x0b...0x0c, 0x0e...0x1f, 0x7f => .{ .state = .invalid },
            else => tokenizer.begin(lexeme, .doc_comment, .doc),
        };
    }

    fn doc_carriage(tokenizer: *const Tokenizer, lexeme: *Lexeme) Step {
        assert(tokenizer.index < tokenizer.source.len);
        assert(tokenizer.byte() == '\r');

        const paired = tokenizer.byte_at(tokenizer.index + 1) == '\n';
        if (paired) return tokenizer.stop(lexeme, .doc_comment);
        return .{ .state = .invalid };
    }

    fn lex_comment(tokenizer: *Tokenizer, lexeme: *Lexeme) Step {
        assert(tokenizer.index < tokenizer.source.len);

        tokenizer.index += 1;

        return switch (tokenizer.byte()) {
            0 => if (tokenizer.ended()) tokenizer.eof(lexeme) else .{ .state = .invalid },
            '\n' => tokenizer.skip(lexeme),
            '\r' => .{ .state = .newline_expected },
            0x01...0x09, 0x0b...0x0c, 0x0e...0x1f, 0x7f => .{ .state = .invalid },
            else => .{ .state = .comment },
        };
    }

    fn lex_doc(tokenizer: *Tokenizer) Step {
        assert(tokenizer.index < tokenizer.source.len);

        tokenizer.index += 1;

        return switch (tokenizer.byte()) {
            0, '\n' => .done,
            '\r' => tokenizer.carriage(),
            0x01...0x09, 0x0b...0x0c, 0x0e...0x1f, 0x7f => .{ .state = .invalid },
            else => .{ .state = .doc },
        };
    }

    fn lex_integer(tokenizer: *Tokenizer) Step {
        assert(tokenizer.index <= tokenizer.source.len);
        assert(tokenizer.index > 0);

        const held = tokenizer.byte();
        if (held == '.') return .{ .state = .integer_dot };

        if (is_digit_part(held)) {
            tokenizer.index += 1;

            return .{ .state = .integer };
        }

        if (is_exponent(held)) return .{ .state = .integer_exponent };
        return .done;
    }

    fn lex_exponent(tokenizer: *Tokenizer, fallback: State) Step {
        assert(tokenizer.index < tokenizer.source.len);
        assert(is_exponent(tokenizer.byte()));

        tokenizer.index += 1;

        switch (tokenizer.byte()) {
            '-', '+' => {
                tokenizer.index += 1;

                return .{ .state = .float };
            },
            else => return .{ .state = fallback },
        }
    }

    fn lex_integer_dot(tokenizer: *Tokenizer) Step {
        assert(tokenizer.index < tokenizer.source.len);
        assert(tokenizer.byte() == '.');

        tokenizer.index += 1;

        const held = tokenizer.byte();

        if (is_digit_part(held)) {
            tokenizer.index += 1;

            return .{ .state = .float };
        }

        if (is_exponent(held)) return .{ .state = .float_exponent };

        tokenizer.index -= 1;

        return .done;
    }

    fn lex_float(tokenizer: *Tokenizer) Step {
        assert(tokenizer.index <= tokenizer.source.len);
        assert(tokenizer.index > 0);

        const held = tokenizer.byte();

        if (is_digit_part(held)) {
            tokenizer.index += 1;

            return .{ .state = .float };
        }

        if (is_exponent(held)) return .{ .state = .float_exponent };
        return .done;
    }

    fn lex_operator(tokenizer: *Tokenizer, state: State, lexeme: *Lexeme) Step {
        assert(tokenizer.index < tokenizer.source.len);
        assert(state != .start);

        tokenizer.index += 1;

        const held = tokenizer.byte();

        for (operator_rules) |rule| {
            if (rule.state != state) continue;
            if (rule.byte != held) continue;
            if (rule.then) |then| return .{ .state = then };
            return tokenizer.finish(lexeme, rule.tag);
        }

        if (state == .dot_asterisk) {
            if (held == '*') return tokenizer.stop(lexeme, .invalid_dot_asterisks);
        }

        return tokenizer.stop(lexeme, fallback_of(state));
    }
};

const State = enum {
    ampersand,
    at,
    backslash,
    bang,
    builtin,
    caret,
    character,
    character_escape,
    comment,
    comment_start,
    doc,
    doc_start,
    dot,
    dot_asterisk,
    dot_dot,
    equal,
    float,
    float_exponent,
    greater,
    greater_greater,
    integer,
    integer_dot,
    integer_exponent,
    invalid,
    less,
    less_less,
    less_less_pipe,
    minus,
    minus_percent,
    minus_pipe,
    newline_expected,
    percent,
    pipe,
    plus,
    plus_percent,
    plus_pipe,
    slash,
    star,
    star_percent,
    star_pipe,
    start,
    text,
    text_escape,
    text_line,
    word,
};

const Step = union(enum) {
    done,
    state: State,
};

const OperatorRule = struct {
    byte: u8,
    state: State,
    tag: Tag = .invalid,
    then: ?State = null,
};

const byte_order_mark = "\xEF\xBB\xBF";
const operator_width_max: u32 = 6;
const step_count_per_byte: u32 = 2;
const step_slack: u32 = 4;

const keywords = std.StaticStringMap(Tag).initComptime(.{
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

const operator_rules = [_]OperatorRule{
    .{ .state = .ampersand, .byte = '=', .tag = .ampersand_equal },
    .{ .state = .bang, .byte = '=', .tag = .bang_equal },
    .{ .state = .caret, .byte = '=', .tag = .caret_equal },
    .{ .state = .dot, .byte = '.', .then = .dot_dot },
    .{ .state = .dot, .byte = '*', .then = .dot_asterisk },
    .{ .state = .dot_dot, .byte = '.', .tag = .dot_dot_dot },
    .{ .state = .equal, .byte = '=', .tag = .equal_equal },
    .{ .state = .equal, .byte = '>', .tag = .arrow },
    .{ .state = .greater, .byte = '>', .then = .greater_greater },
    .{ .state = .greater, .byte = '=', .tag = .greater_equal },
    .{ .state = .greater_greater, .byte = '=', .tag = .greater_greater_equal },
    .{ .state = .less, .byte = '<', .then = .less_less },
    .{ .state = .less, .byte = '=', .tag = .less_equal },
    .{ .state = .less_less, .byte = '=', .tag = .less_less_equal },
    .{ .state = .less_less, .byte = '|', .then = .less_less_pipe },
    .{ .state = .less_less_pipe, .byte = '=', .tag = .less_less_pipe_equal },
    .{ .state = .minus, .byte = '>', .tag = .minus_greater },
    .{ .state = .minus, .byte = '=', .tag = .minus_equal },
    .{ .state = .minus, .byte = '%', .then = .minus_percent },
    .{ .state = .minus, .byte = '|', .then = .minus_pipe },
    .{ .state = .minus_percent, .byte = '=', .tag = .minus_percent_equal },
    .{ .state = .minus_pipe, .byte = '=', .tag = .minus_pipe_equal },
    .{ .state = .percent, .byte = '=', .tag = .percent_equal },
    .{ .state = .pipe, .byte = '=', .tag = .pipe_equal },
    .{ .state = .pipe, .byte = '|', .tag = .pipe_pipe },
    .{ .state = .plus, .byte = '=', .tag = .plus_equal },
    .{ .state = .plus, .byte = '+', .tag = .plus_plus },
    .{ .state = .plus, .byte = '%', .then = .plus_percent },
    .{ .state = .plus, .byte = '|', .then = .plus_pipe },
    .{ .state = .plus_percent, .byte = '=', .tag = .plus_percent_equal },
    .{ .state = .plus_pipe, .byte = '=', .tag = .plus_pipe_equal },
    .{ .state = .slash, .byte = '/', .then = .comment_start },
    .{ .state = .slash, .byte = '=', .tag = .slash_equal },
    .{ .state = .star, .byte = '=', .tag = .star_equal },
    .{ .state = .star, .byte = '*', .tag = .star_star },
    .{ .state = .star, .byte = '%', .then = .star_percent },
    .{ .state = .star, .byte = '|', .then = .star_pipe },
    .{ .state = .star_percent, .byte = '=', .tag = .star_percent_equal },
    .{ .state = .star_pipe, .byte = '=', .tag = .star_pipe_equal },
};

comptime {
    assert(step_count_per_byte >= 2);
    assert(operator_rules.len < 64);
}

fn single_of(byte: u8) ?Tag {
    return switch (byte) {
        '(' => .paren_open,
        ')' => .paren_close,
        '[' => .bracket_open,
        ']' => .bracket_close,
        ';' => .semicolon,
        ',' => .comma,
        '?' => .question,
        ':' => .colon,
        '{' => .brace_open,
        '}' => .brace_close,
        '~' => .tilde,
        else => null,
    };
}

fn operator_state_of(byte: u8) ?State {
    return switch (byte) {
        '@' => .at,
        '=' => .equal,
        '!' => .bang,
        '|' => .pipe,
        '%' => .percent,
        '*' => .star,
        '+' => .plus,
        '<' => .less,
        '>' => .greater,
        '^' => .caret,
        '.' => .dot,
        '-' => .minus,
        '/' => .slash,
        '&' => .ampersand,
        else => null,
    };
}

fn fallback_of(state: State) Tag {
    return switch (state) {
        .ampersand => .ampersand,
        .bang => .bang,
        .caret => .caret,
        .dot => .dot,
        .dot_asterisk => .dot_asterisk,
        .dot_dot => .dot_dot,
        .equal => .equal,
        .greater => .greater,
        .greater_greater => .greater_greater,
        .less => .less,
        .less_less => .less_less,
        .less_less_pipe => .less_less_pipe,
        .minus => .minus,
        .minus_percent => .minus_percent,
        .minus_pipe => .minus_pipe,
        .percent => .percent,
        .pipe => .pipe,
        .plus => .plus,
        .plus_percent => .plus_percent,
        .plus_pipe => .plus_pipe,
        .slash => .slash,
        .star => .star,
        .star_percent => .star_percent,
        .star_pipe => .star_pipe,
        else => unreachable,
    };
}

fn is_digit_part(byte: u8) bool {
    return switch (byte) {
        '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => true,
        else => false,
    };
}

fn is_exponent(byte: u8) bool {
    return switch (byte) {
        'e', 'E', 'p', 'P' => true,
        else => false,
    };
}

fn expect_tags(source: []const u8, expected: []const Tag) !void {
    assert(source.len <= std.math.maxInt(u32));
    assert(expected.len <= std.math.maxInt(u32));

    var tokenizer: Tokenizer = .init(source);

    for (expected) |tag| {
        const lexeme = tokenizer.next();

        try std.testing.expectEqual(tag, lexeme.tag);
    }

    const ended = tokenizer.next();

    try std.testing.expectEqual(Tag.eof, ended.tag);
}

test "an arrow, a dereference run and a doubled star lex as zig lexes them" {
    try expect_tags("a->b", &.{ .identifier, .minus_greater, .identifier });
    try expect_tags("x.** 2", &.{ .identifier, .invalid_dot_asterisks, .star, .number });
    try expect_tags("x.?", &.{ .identifier, .dot, .question });
    try expect_tags("a ** b", &.{ .identifier, .star_star, .identifier });
}

test "comments lex the way the zig tokenizer reads them" {
    try expect_tags("//! top\n/// item\n//// plain\n// plain\nx", &.{
        .container_doc_comment,
        .doc_comment,
        .identifier,
    });

    try expect_tags("///\nx", &.{ .doc_comment, .identifier });
}

test "an unterminated literal and a stray byte lex as invalid" {
    try expect_tags("\"open\nx", &.{ .invalid, .identifier });
    try expect_tags("$ x\ny", &.{ .invalid, .identifier });
    try expect_tags("@\n", &.{.invalid});
    try expect_tags("\xEF\xBB\xBFx", &.{.identifier});
}

test "a number keeps its exponent and leaves a range alone" {
    try expect_tags("0x1p-3", &.{.number});
    try expect_tags("1..2", &.{ .number, .dot_dot, .number });
    try expect_tags("1.5e+3", &.{.number});
}
