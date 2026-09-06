use crate::language::{Grammar, Lexer};
use crate::scan::{
    identifier_scan,
    is_identifier_start_at,
    line_scan_trimmed,
    number_scan,
    punctuation_of,
    string_scan,
    word_in,
};
use crate::token::{Keyword, Lex, Punctuation, TokenKind, Tokens};

pub static ZIG: ZigLexer = ZigLexer;

const CAST_WORDS: &[&[u8]] = &[
    b"@alignCast",
    b"@as",
    b"@bitCast",
    b"@enumFromInt",
    b"@floatFromInt",
    b"@intCast",
    b"@intFromEnum",
    b"@intFromFloat",
    b"@intFromPtr",
    b"@ptrCast",
    b"@ptrFromInt",
    b"@truncate",
];

const PRIMITIVE_TYPES: &[&[u8]] = &[
    b"anyerror",
    b"anyframe",
    b"anyopaque",
    b"bool",
    b"c_char",
    b"c_int",
    b"c_long",
    b"c_longdouble",
    b"c_longlong",
    b"c_short",
    b"c_uint",
    b"c_ulong",
    b"c_ulonglong",
    b"c_ushort",
    b"comptime_float",
    b"comptime_int",
    b"f128",
    b"f16",
    b"f32",
    b"f64",
    b"f80",
    b"i1*",
    b"i2*",
    b"i3*",
    b"i4*",
    b"i5*",
    b"i6*",
    b"i7*",
    b"i8*",
    b"i9*",
    b"isize",
    b"noreturn",
    b"type",
    b"u1*",
    b"u2*",
    b"u3*",
    b"u4*",
    b"u5*",
    b"u6*",
    b"u7*",
    b"u8*",
    b"u9*",
    b"usize",
    b"void",
];

static GRAMMAR: Grammar = Grammar {
    cast_words: CAST_WORDS,
    defer_word: b"defer",
    discard_prefix: b"_ = ",
    primitive_types: PRIMITIVE_TYPES,
    sized_type_names: &[b"isize", b"usize"],
    statements_end_with_semicolon: true,
    ..Grammar::DEFAULT
};

pub const EXPECTATIONS: &[&[u8]] = &[
    b"expect",
    b"expectApproxEqAbs",
    b"expectApproxEqRel",
    b"expectEqual",
    b"expectEqualDeep",
    b"expectEqualSentinel",
    b"expectEqualSlices",
    b"expectEqualStrings",
    b"expectError",
    b"expectFmt",
    b"expectStringEndsWith",
    b"expectStringStartsWith",
];

pub struct ZigLexer;

impl Lexer for ZigLexer {
    fn grammar(&self) -> &'static Grammar {
        &GRAMMAR
    }

    fn extensions(&self) -> &'static [&'static [u8]] {
        &[b"zig"]
    }

    fn identifier(&self) -> &'static str {
        "zig"
    }

    fn lex(&self, source: &[u8], tokens: &mut Tokens) -> Lex {
        assert!(u32::try_from(source.len()).is_ok());

        let mut offset = crate::scan::mark_width(source);

        while offset < source.len() {
            let blank = crate::scan::whitespace_scan(source, offset);

            if blank > offset {
                offset = blank;

                continue;
            }

            let (kind, end) = token_of(source, offset);

            assert!(end > offset);

            if !tokens.push(source, kind, offset, end - offset) {
                return Lex::Truncated;
            }

            offset = end;
        }

        Lex::Complete
    }
}

fn is_expectation(source: &[u8], offset: usize, text: &[u8]) -> bool {
    if offset == 0 || source[offset - 1] != b'.' {
        return false;
    }

    word_in(EXPECTATIONS, text)
}

pub(crate) fn word_of(text: &[u8]) -> Option<TokenKind> {
    let keyword = match text {
        b"assert" | b"unreachable" => Keyword::Assert,
        b"break" => Keyword::Break,
        b"catch" => Keyword::Except,
        b"const" => Keyword::Constant,
        b"continue" => Keyword::Continue,
        b"else" => Keyword::BranchElse,
        b"enum" | b"error" | b"opaque" | b"struct" | b"union" => Keyword::Struct,
        b"fn" => Keyword::Function,
        b"for" | b"while" => Keyword::Loop,
        b"if" => Keyword::Branch,
        b"return" => Keyword::Return,
        b"switch" => Keyword::Match,
        b"try" => Keyword::Try,
        b"var" => Keyword::Mutable,
        b"and" => return Some(TokenKind::Punctuation(Punctuation::AmpersandDouble)),
        b"or" => return Some(TokenKind::Punctuation(Punctuation::BarDouble)),
        b"addrspace" | b"align" | b"allowzero" | b"anytype" | b"asm" => Keyword::Other,
        b"callconv" | b"comptime" | b"defer" | b"errdefer" => Keyword::Other,
        b"export" | b"extern" | b"inline" | b"linksection" | b"noalias" => Keyword::Other,
        b"noinline" | b"nosuspend" | b"orelse" | b"packed" => Keyword::Other,
        b"pub" | b"resume" | b"suspend" | b"test" | b"threadlocal" => Keyword::Other,
        b"volatile" => Keyword::Other,
        _ => return None,
    };

    Some(TokenKind::Keyword(keyword))
}

fn opens_a_prong(source: &[u8], end: usize) -> bool {
    let mut offset = end;

    while offset < source.len() && source[offset].is_ascii_whitespace() {
        offset += 1;
    }

    source.get(offset) == Some(&b'=') && source.get(offset + 1) == Some(&b'>')
}

fn builtin_scan(source: &[u8], start: usize) -> (TokenKind, usize) {
    assert_eq!(source[start], b'@');

    if start + 1 < source.len() && source[start + 1] == b'"' {
        return (TokenKind::Identifier, string_scan(source, start + 1, b'"'));
    }

    if is_identifier_start_at(source, start + 1) {
        let end = identifier_scan(source, start + 1);

        if &source[start + 1..end] == b"import" {
            return (TokenKind::Keyword(Keyword::Import), end);
        }

        return (TokenKind::Identifier, end);
    }

    (TokenKind::Punctuation(Punctuation::Other), start + 1)
}

fn token_of(source: &[u8], offset: usize) -> (TokenKind, usize) {
    let byte = source[offset];
    let next = source.get(offset + 1).copied();

    if byte == b'/' && next == Some(b'/') {
        return (TokenKind::Comment, line_scan_trimmed(source, offset));
    }

    if byte == b'\\' && next == Some(b'\\') {
        return (TokenKind::String, line_scan_trimmed(source, offset));
    }

    if byte == b'{' {
        return (TokenKind::BlockStart, offset + 1);
    }

    if byte == b'}' {
        return (TokenKind::BlockEnd, offset + 1);
    }

    if byte == b'"' {
        return (TokenKind::String, string_scan(source, offset, b'"'));
    }

    if byte == b'\'' {
        return (TokenKind::String, string_scan(source, offset, b'\''));
    }

    if byte == b'@' {
        return builtin_scan(source, offset);
    }

    if is_identifier_start_at(source, offset) {
        let end = identifier_scan(source, offset);
        let text = &source[offset..end];

        if text == b"else" && opens_a_prong(source, end) {
            return (TokenKind::Keyword(Keyword::Other), end);
        }

        if is_expectation(source, offset, text) {
            return (TokenKind::Keyword(Keyword::Assert), end);
        }

        return match word_of(text) {
            Some(kind) => (kind, end),
            None => (TokenKind::Identifier, end),
        };
    }

    if byte.is_ascii_digit() {
        return (TokenKind::Number, number_scan(source, offset));
    }

    if byte == b'|' && source.get(offset + 1) == Some(&b'|') {
        return (TokenKind::Punctuation(Punctuation::Other), offset + 2);
    }

    let (punctuation, length) = punctuation_of(source, offset);

    (TokenKind::Punctuation(punctuation), offset + length)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lex::tests_support;

    fn strings_of(source: &[u8]) -> Vec<Vec<u8>> {
        let tokens = tests_support::lex(&ZIG, source);

        tokens
            .iter()
            .filter(|token| token.kind == TokenKind::String)
            .map(|token| token.text(source).to_vec())
            .collect()
    }

    #[test]
    fn a_character_literal_ends_where_the_zig_tokenizer_ends_it() {
        let source = b"fn f() void {\n    const r = 'a';\n    const q = '\\'';\n    \
            const w = '\\u{1F600}';\n}\n";

        assert_eq!(
            strings_of(source),
            vec![b"'a'".to_vec(), b"'\\''".to_vec(), b"'\\u{1F600}'".to_vec()]
        );
    }

    #[test]
    fn a_stray_apostrophe_closes_at_the_next_one_and_stops_at_the_line() {
        let paired = b"fn f() void {\n    const s = 'don't;\n}\n";

        assert_eq!(strings_of(paired), vec![b"'don'".to_vec()]);

        let alone = b"fn f() void {\n    const s = 'a\n}\n";

        assert_eq!(strings_of(alone), vec![b"'a".to_vec()]);

        let ended = b"fn f() void {\n    const s = 'a";

        assert_eq!(strings_of(ended), vec![b"'a".to_vec()]);
    }

    const KEYWORDS: &[(&str, &str, TokenKind)] =
        &[
            (
                "addrspace",
                "extern fn f() addrspace(.generic) void;\n",
                TokenKind::Keyword(Keyword::Other),
            ),
            (
                "align",
                "const Store = struct {\n    value: u32 align(4),\n};\n",
                TokenKind::Keyword(Keyword::Other),
            ),
            (
                "allowzero",
                "fn f(value: *allowzero u32) void {}\n",
                TokenKind::Keyword(Keyword::Other),
            ),
            (
                "and",
                "fn f(a: bool, b: bool) bool {\n    return a and b;\n}\n",
                TokenKind::Punctuation(Punctuation::AmpersandDouble),
            ),
            (
                "anyframe",
                "fn f(handle: anyframe) void {}\n",
                TokenKind::Identifier,
            ),
            (
                "anytype",
                "fn f(value: anytype) void {}\n",
                TokenKind::Keyword(Keyword::Other),
            ),
            (
                "asm",
                "fn f() void {\n    asm volatile (\"nop\");\n}\n",
                TokenKind::Keyword(Keyword::Other),
            ),
            (
                "async",
                "fn f(task: fn () void) void {\n    _ = async task();\n}\n",
                TokenKind::Identifier,
            ),
            (
                "await",
                "fn f(handle: anyframe) void {\n    await handle;\n}\n",
                TokenKind::Identifier,
            ),
            (
                "break",
                "fn f() void {\n    while (true) {\n        break;\n    }\n}\n",
                TokenKind::Keyword(Keyword::Break),
            ),
            (
                "callconv",
                "fn f() callconv(.C) void {}\n",
                TokenKind::Keyword(Keyword::Other),
            ),
            (
                "catch",
                "fn f() void {\n    read() catch {};\n}\n",
                TokenKind::Keyword(Keyword::Except),
            ),
            (
                "comptime",
                "fn f(comptime T: type) void {}\n",
                TokenKind::Keyword(Keyword::Other),
            ),
            (
                "const",
                "const limit = 4;\n",
                TokenKind::Keyword(Keyword::Constant),
            ),
            (
                "continue",
                "fn f() void {\n    while (true) {\n        continue;\n    }\n}\n",
                TokenKind::Keyword(Keyword::Continue),
            ),
            (
                "defer",
                "fn f(handle: Handle) void {\n    defer handle.close();\n}\n",
                TokenKind::Keyword(Keyword::Other),
            ),
            (
                "else",
                "fn f(flag: bool) void {\n    if (flag) {\n    } else {\n    }\n}\n",
                TokenKind::Keyword(Keyword::BranchElse),
            ),
            (
                "enum",
                "const Kind = enum {\n    null,\n};\n",
                TokenKind::Keyword(Keyword::Struct),
            ),
            (
                "errdefer",
                "fn f(handle: Handle) void {\n    errdefer handle.close();\n}\n",
                TokenKind::Keyword(Keyword::Other),
            ),
            (
                "error",
                "const Failure = error{Bad};\n",
                TokenKind::Keyword(Keyword::Struct),
            ),
            (
                "export",
                "export fn f() void {}\n",
                TokenKind::Keyword(Keyword::Other),
            ),
            (
                "extern",
                "extern fn f() void;\n",
                TokenKind::Keyword(Keyword::Other),
            ),
            (
                "fn",
                "fn f() void {}\n",
                TokenKind::Keyword(Keyword::Function),
            ),
            (
                "for",
                "fn f(values: []const u32) void {\n    for (values) |value| {\n        _ = \
                 value;\n    }\n}\n",
                TokenKind::Keyword(Keyword::Loop),
            ),
            (
                "if",
                "fn f(flag: bool) void {\n    if (flag) {\n    }\n}\n",
                TokenKind::Keyword(Keyword::Branch),
            ),
            (
                "inline",
                "fn f(values: []const u32) void {\n    inline for (values) |value| {\n        _ = \
                 value;\n    }\n}\n",
                TokenKind::Keyword(Keyword::Other),
            ),
            (
                "linksection",
                "export fn f() linksection(\".text\") void {}\n",
                TokenKind::Keyword(Keyword::Other),
            ),
            (
                "noalias",
                "fn f(noalias value: *u32) void {}\n",
                TokenKind::Keyword(Keyword::Other),
            ),
            (
                "noinline",
                "noinline fn f() void {}\n",
                TokenKind::Keyword(Keyword::Other),
            ),
            (
                "nosuspend",
                "fn f(handle: anyframe) void {\n    nosuspend await handle;\n}\n",
                TokenKind::Keyword(Keyword::Other),
            ),
            (
                "opaque",
                "const Handle = opaque {};\n",
                TokenKind::Keyword(Keyword::Struct),
            ),
            (
                "or",
                "fn f(a: bool, b: bool) bool {\n    return a or b;\n}\n",
                TokenKind::Punctuation(Punctuation::BarDouble),
            ),
            (
                "orelse",
                "fn f(value: ?u32) u32 {\n    return value orelse 0;\n}\n",
                TokenKind::Keyword(Keyword::Other),
            ),
            (
                "packed",
                "const Store = packed struct {\n    value: u32,\n};\n",
                TokenKind::Keyword(Keyword::Other),
            ),
            (
                "pub",
                "pub fn f() void {}\n",
                TokenKind::Keyword(Keyword::Other),
            ),
            (
                "resume",
                "fn f(handle: anyframe) void {\n    resume handle;\n}\n",
                TokenKind::Keyword(Keyword::Other),
            ),
            (
                "return",
                "fn f() u32 {\n    return 0;\n}\n",
                TokenKind::Keyword(Keyword::Return),
            ),
            (
                "struct",
                "const Store = struct {\n    value: u32,\n};\n",
                TokenKind::Keyword(Keyword::Struct),
            ),
            (
                "suspend",
                "fn f() void {\n    suspend {}\n}\n",
                TokenKind::Keyword(Keyword::Other),
            ),
            (
                "switch",
                "fn f(value: u32) void {\n    switch (value) {\n        else => {},\n    }\n}\n",
                TokenKind::Keyword(Keyword::Match),
            ),
            (
                "test",
                "test \"a claim holds\" {}\n",
                TokenKind::Keyword(Keyword::Other),
            ),
            (
                "threadlocal",
                "threadlocal var count: u32 = 0;\n",
                TokenKind::Keyword(Keyword::Other),
            ),
            (
                "try",
                "fn f() !void {\n    try read();\n}\n",
                TokenKind::Keyword(Keyword::Try),
            ),
            (
                "union",
                "const Value = union {\n    count: u32,\n};\n",
                TokenKind::Keyword(Keyword::Struct),
            ),
            (
                "unreachable",
                "fn f() void {\n    unreachable;\n}\n",
                TokenKind::Keyword(Keyword::Assert),
            ),
            (
                "usingnamespace",
                "pub usingnamespace @import(\"std\");\n",
                TokenKind::Identifier,
            ),
            (
                "var",
                "var count: u32 = 0;\n",
                TokenKind::Keyword(Keyword::Mutable),
            ),
            (
                "volatile",
                "fn f(value: *volatile u32) void {}\n",
                TokenKind::Keyword(Keyword::Other),
            ),
            (
                "while",
                "fn f(flag: bool) void {\n    while (flag) {\n    }\n}\n",
                TokenKind::Keyword(Keyword::Loop),
            ),
        ];

    const PUNCTUATION: &[(&str, &str, TokenKind)] =
        &[
            (
                "!",
                "fn f() !void {\n    try read();\n}\n",
                TokenKind::Punctuation(Punctuation::Bang),
            ),
            (
                "!=",
                "fn f(a: u32, b: u32) bool {\n    return a != b;\n}\n",
                TokenKind::Punctuation(Punctuation::NotEqual),
            ),
            (
                "&",
                "fn f(a: u32, b: u32) u32 {\n    return a & b;\n}\n",
                TokenKind::Punctuation(Punctuation::Ampersand),
            ),
            (
                "(",
                "fn f() void {}\n",
                TokenKind::Punctuation(Punctuation::ParenOpen),
            ),
            (
                ")",
                "fn f() void {}\n",
                TokenKind::Punctuation(Punctuation::ParenClose),
            ),
            (
                "*",
                "fn f(a: u32, b: u32) u32 {\n    return a * b;\n}\n",
                TokenKind::Punctuation(Punctuation::Star),
            ),
            (
                "+",
                "fn f(a: u32, b: u32) u32 {\n    return a + b;\n}\n",
                TokenKind::Punctuation(Punctuation::Other),
            ),
            (
                ",",
                "fn f(a: u32, b: u32) void {}\n",
                TokenKind::Punctuation(Punctuation::Comma),
            ),
            (
                "-",
                "fn f(a: u32, b: u32) u32 {\n    return a - b;\n}\n",
                TokenKind::Punctuation(Punctuation::Other),
            ),
            (
                ".",
                "fn f(store: Store) u32 {\n    return store.value;\n}\n",
                TokenKind::Punctuation(Punctuation::Dot),
            ),
            (
                "/",
                "fn f(a: u32, b: u32) u32 {\n    return a / b;\n}\n",
                TokenKind::Punctuation(Punctuation::Slash),
            ),
            (
                ":",
                "fn f(value: u32) void {}\n",
                TokenKind::Punctuation(Punctuation::Colon),
            ),
            (
                ";",
                "fn f() void {\n    const value = 1;\n    _ = value;\n}\n",
                TokenKind::Punctuation(Punctuation::Semicolon),
            ),
            (
                "<",
                "fn f(a: u32, b: u32) bool {\n    return a < b;\n}\n",
                TokenKind::Punctuation(Punctuation::Less),
            ),
            (
                "<=",
                "fn f(a: u32, b: u32) bool {\n    return a <= b;\n}\n",
                TokenKind::Punctuation(Punctuation::LessEqual),
            ),
            (
                "=",
                "fn f() void {\n    const value = 1;\n    _ = value;\n}\n",
                TokenKind::Punctuation(Punctuation::Assign),
            ),
            (
                "==",
                "fn f(a: u32, b: u32) bool {\n    return a == b;\n}\n",
                TokenKind::Punctuation(Punctuation::Equal),
            ),
            (
                ">",
                "fn f(a: u32, b: u32) bool {\n    return a > b;\n}\n",
                TokenKind::Punctuation(Punctuation::Greater),
            ),
            (
                ">=",
                "fn f(a: u32, b: u32) bool {\n    return a >= b;\n}\n",
                TokenKind::Punctuation(Punctuation::GreaterEqual),
            ),
            (
                "?",
                "fn f(value: ?u32) void {}\n",
                TokenKind::Punctuation(Punctuation::Other),
            ),
            (
                "[",
                "fn f(values: []const u32) void {}\n",
                TokenKind::Punctuation(Punctuation::BracketOpen),
            ),
            (
                "]",
                "fn f(values: []const u32) void {}\n",
                TokenKind::Punctuation(Punctuation::BracketClose),
            ),
            (
                "^",
                "fn f(a: u32, b: u32) u32 {\n    return a ^ b;\n}\n",
                TokenKind::Punctuation(Punctuation::Other),
            ),
            ("{", "fn f() void {}\n", TokenKind::BlockStart),
            (
                "|",
                "fn f(values: []const u32) void {\n    for (values) |value| {\n        _ = \
                 value;\n    }\n}\n",
                TokenKind::Punctuation(Punctuation::Other),
            ),
            ("}", "fn f() void {}\n", TokenKind::BlockEnd),
        ];

    #[test]
    fn every_keyword_of_the_specification_lexes_to_its_kind() {
        assert_eq!(KEYWORDS.len(), 49);

        for (word, source, expected) in KEYWORDS {
            assert_eq!(
                tests_support::kind_of(&ZIG, source, word),
                *expected,
                "{word}"
            );
        }
    }

    #[test]
    fn every_punctuation_of_the_specification_lexes_to_its_kind() {
        for (word, source, expected) in PUNCTUATION {
            assert_eq!(
                tests_support::kind_of(&ZIG, source, word),
                *expected,
                "{word}"
            );
        }
    }

    #[test]
    fn an_else_before_an_equals_at_the_source_end_is_a_branch() {
        let source = b"else =";
        let tokens = tests_support::lex(&ZIG, source);

        assert_eq!(tokens[0].kind, TokenKind::Keyword(Keyword::BranchElse));
    }

    #[test]
    fn an_else_before_a_greater_than_is_a_branch() {
        let source = b"else > 1";
        let tokens = tests_support::lex(&ZIG, source);

        assert_eq!(tokens[0].kind, TokenKind::Keyword(Keyword::BranchElse));
    }

    #[test]
    fn an_else_prong_is_not_a_branch() {
        let source =
            b"fn f(value: u32) u32 {\n    return switch (value) {\n        else => 0,\n    };\n}\n";

        let tokens = tests_support::lex(&ZIG, source);

        let word = tokens
            .iter()
            .find(|token| token.text(source) == b"else")
            .expect("the word is a token");

        assert_eq!(word.kind, TokenKind::Keyword(Keyword::Other));
    }

    #[test]
    fn an_else_branch_is_a_branch() {
        let source = b"fn f(ready: bool) u32 {\n    if (ready) {\n        return 1;\n    \
            } else {\n        return 0;\n    }\n}\n";

        let tokens = tests_support::lex(&ZIG, source);

        let word = tokens
            .iter()
            .find(|token| token.text(source) == b"else")
            .expect("the word is a token");

        assert_eq!(word.kind, TokenKind::Keyword(Keyword::BranchElse));
    }

    #[test]
    fn an_else_before_a_lone_equals_is_a_branch() {
        let source =
            b"fn f(ready: bool, value: *u32) void {\n    if (ready) {} else value.* = 1;\n}\n";

        let tokens = tests_support::lex(&ZIG, source);

        let word = tokens
            .iter()
            .find(|token| token.text(source) == b"else")
            .expect("the word is a token");

        assert_eq!(word.kind, TokenKind::Keyword(Keyword::BranchElse));
    }

    #[test]
    fn an_else_at_the_source_end_is_a_branch() {
        let source = b"else";
        let tokens = tests_support::lex(&ZIG, source);

        assert_eq!(tokens[0].kind, TokenKind::Keyword(Keyword::BranchElse));
    }

    #[test]
    fn a_multiline_string_line_is_a_string() {
        let source = b"const text =\n    \\\\a line\n    \\\\another\n;\n";
        let tokens = tests_support::lex(&ZIG, source);

        let strings = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::String)
            .count();

        assert_eq!(strings, 2);
    }

    #[test]
    fn a_lone_backslash_is_punctuation() {
        let source: &[u8] = br"const value = \;";
        let tokens = tests_support::lex(&ZIG, source);

        let strings = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::String)
            .count();

        assert_eq!(strings, 0);
    }

    #[test]
    fn a_builtin_carries_its_name_and_stops() {
        let source = b"const value = @intCast(other);\n";
        let tokens = tests_support::lex(&ZIG, source);

        let builtin = tokens
            .iter()
            .find(|token| token.text(source) == b"@intCast")
            .expect("the builtin is a token of its own");

        assert_eq!(builtin.kind, TokenKind::Identifier);
        assert_eq!(builtin.offset, 14);
        assert_eq!(builtin.length, 8);
    }

    #[test]
    fn an_import_builtin_is_an_import_keyword() {
        let source = b"const std = @import(\"std\");\n";
        let tokens = tests_support::lex(&ZIG, source);

        let import = tokens
            .iter()
            .find(|token| token.text(source) == b"@import")
            .expect("the import builtin is a token of its own");

        assert_eq!(import.kind, TokenKind::Keyword(Keyword::Import));
    }

    #[test]
    fn a_quoted_builtin_name_lexes_as_one_identifier() {
        let source = b"const value = @\"a name\";\n";
        let tokens = tests_support::lex(&ZIG, source);

        let quoted = tokens
            .iter()
            .find(|token| token.offset == 14)
            .expect("the quoted name starts at the at sign");

        assert_eq!(quoted.kind, TokenKind::Identifier);
        assert_eq!(quoted.length, 9);
    }

    #[test]
    fn a_bare_at_sign_is_punctuation() {
        let source = b"@";
        let tokens = tests_support::lex(&ZIG, source);

        assert_eq!(tokens.len(), 1);
        assert_eq!(tokens[0].kind, TokenKind::Punctuation(Punctuation::Other));
        assert_eq!(tokens[0].length, 1);
    }

    #[test]
    fn an_at_sign_at_the_source_end_is_punctuation() {
        let source = b"const value = @";
        let tokens = tests_support::lex(&ZIG, source);
        let last = tokens.last().expect("the at sign is a token");

        assert_eq!(last.kind, TokenKind::Punctuation(Punctuation::Other));
        assert_eq!(last.offset, 14);
        assert_eq!(last.length, 1);
    }

    #[test]
    fn a_function_lexes_to_its_parts() {
        let source = b"pub fn main() void {\n    const value = 1;\n}\n";
        let tokens = tests_support::lex(&ZIG, source);

        assert_eq!(tokens[1].kind, TokenKind::Keyword(Keyword::Function));
        assert_eq!(tokens[2].text(source), b"main");
        assert_eq!(tokens[6].kind, TokenKind::BlockStart);
        assert_eq!(tokens[7].kind, TokenKind::Keyword(Keyword::Constant));
    }

    #[test]
    fn a_builtin_import_is_a_keyword() {
        let source = b"const std = @import(\"std\");";
        let tokens = tests_support::lex(&ZIG, source);

        assert_eq!(tokens[3].kind, TokenKind::Keyword(Keyword::Import));
        assert_eq!(tokens[5].kind, TokenKind::String);
    }

    #[test]
    fn a_multiline_string_covers_its_line() {
        let source = b"const text =\n    \\\\one line\n    \\\\two line\n;";
        let tokens = tests_support::lex(&ZIG, source);

        assert_eq!(tokens[3].kind, TokenKind::String);
        assert_eq!(tokens[3].text(source), b"\\\\one line");
        assert_eq!(tokens[4].kind, TokenKind::String);
    }

    #[test]
    fn an_expectation_after_a_dot_is_an_assertion() {
        for name in EXPECTATIONS {
            let mut source = b"try std.testing.".to_vec();

            source.extend_from_slice(name);
            source.extend_from_slice(b"(value);");

            let tokens = tests_support::lex(&ZIG, &source);
            let asserts = tokens
                .iter()
                .filter(|token| token.kind == TokenKind::Keyword(Keyword::Assert))
                .count();

            assert_eq!(asserts, 1, "{}", String::from_utf8_lossy(name));
        }
    }

    #[test]
    fn an_expectation_without_a_dot_is_an_identifier() {
        let source = b"const value = expectEqual(1, 2);";
        let tokens = tests_support::lex(&ZIG, source);

        let asserts = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::Keyword(Keyword::Assert))
            .count();

        assert_eq!(asserts, 0);
    }

    #[test]
    fn every_expectation_starts_with_expect() {
        for name in EXPECTATIONS {
            assert!(
                name.starts_with(b"expect"),
                "{}",
                String::from_utf8_lossy(name)
            );
        }
    }

    #[test]
    fn a_trailing_backslash_does_not_swallow_the_next_line() {
        let source = b"const s = \"a\\\nfn later() void {}\n";
        let tokens = tests_support::lex(&ZIG, source);

        let later = tokens
            .iter()
            .find(|token| token.text(source) == b"later")
            .expect("the function survives the literal");

        assert_eq!(later.kind, TokenKind::Identifier);
        assert_eq!(tokens[3].text(source), b"\"a\\");

        assert_eq!(
            tokens
                .iter()
                .filter(|token| token.kind == TokenKind::BlockStart)
                .count(),
            1
        );
    }

    #[test]
    fn a_hexadecimal_float_is_one_number() {
        let source = b"const value = 0x1.fffffep+127;\n";
        let tokens = tests_support::lex(&ZIG, source);

        assert_eq!(tokens[3].kind, TokenKind::Number);
        assert_eq!(tokens[3].text(source), b"0x1.fffffep+127");
    }

    #[test]
    fn a_comment_on_a_windows_line_stops_before_the_carriage_return() {
        let source = b"// note\r\nconst value = 1;\r\n";
        let tokens = tests_support::lex(&ZIG, source);

        assert_eq!(tokens[0].kind, TokenKind::Comment);
        assert_eq!(tokens[0].text(source), b"// note");
    }

    #[test]
    fn an_error_set_merge_is_not_a_boolean_or() {
        let source = b"const Either = error{A} || error{B};\n";
        let tokens = tests_support::lex(&ZIG, source);

        let merge = tokens
            .iter()
            .find(|token| token.text(source) == b"||")
            .expect("the merge is a token");

        assert_eq!(merge.kind, TokenKind::Punctuation(Punctuation::Other));

        assert_eq!(
            tests_support::kind_of(&ZIG, "const both = a or b;\n", "or"),
            TokenKind::Punctuation(Punctuation::BarDouble)
        );
    }

    #[test]
    fn a_character_is_a_string() {
        let source = b"const byte = 'a';";
        let tokens = tests_support::lex(&ZIG, source);

        assert_eq!(tokens[3].kind, TokenKind::String);
        assert_eq!(tokens[3].text(source), b"'a'");
    }
}
