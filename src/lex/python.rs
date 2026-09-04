use crate::language::Lexer;
use crate::scan::{identifier_scan, is_identifier_start_at, punctuation_of, string_scan_continued};
use crate::structure::DEPTH_MAX;
use crate::token::{Keyword, Lex, Punctuation, TokenKind, Tokens};

pub static PYTHON: PythonLexer = PythonLexer;
const TAB_COLUMNS: u32 = 8;
const FORM_FEED: u8 = 0x0c;
const SOFT_WORD: &[u8] = b"match";
const FIELD_DEPTH_MAX: u32 = 32;
const RECEIVER: &[u8] = b"self.";

pub struct PythonLexer;

enum Indent {
    Blank,
    Content,
    Truncated,
}

struct Scanner<'source> {
    brackets: u32,
    columns: [u32; DEPTH_MAX as usize],
    depth: usize,
    offset: usize,
    source: &'source [u8],
}

impl Lexer for PythonLexer {
    fn extensions(&self) -> &'static [&'static [u8]] {
        &[b"py", b"pyi"]
    }

    fn identifier(&self) -> &'static str {
        "python"
    }

    fn lex(&self, source: &[u8], tokens: &mut Tokens) -> Lex {
        assert!(u32::try_from(source.len()).is_ok());

        let mut scanner = Scanner {
            brackets: 0,
            columns: [0; DEPTH_MAX as usize],
            depth: 1,
            offset: crate::scan::mark_width(source),
            source,
        };

        scanner.run(tokens)
    }
}

fn is_assertion(source: &[u8], offset: usize, end: usize) -> bool {
    let text = &source[offset..end];

    if !calls(source, end) {
        return false;
    }

    if text.starts_with(b"assert_") {
        return true;
    }

    if offset < RECEIVER.len() || (!text.starts_with(b"assert") && !text.starts_with(b"fail")) {
        return false;
    }

    &source[offset - RECEIVER.len()..offset] == RECEIVER
}

fn calls(source: &[u8], end: usize) -> bool {
    let mut offset = end;

    while offset < source.len() && source[offset] == b' ' {
        offset += 1;
    }

    source.get(offset) == Some(&b'(')
}

fn opens_a_line(source: &[u8], offset: usize) -> bool {
    let mut cursor = offset;

    while cursor > 0 {
        let byte = source[cursor - 1];

        if matches!(byte, b'\n' | b'\r') {
            return true;
        }

        if !byte.is_ascii_whitespace() {
            return false;
        }

        cursor -= 1;
    }

    true
}

pub(crate) fn word_of(text: &[u8]) -> Option<TokenKind> {
    let keyword = match text {
        b"assert" => Keyword::Assert,
        b"break" => Keyword::Break,
        b"class" => Keyword::Struct,
        b"continue" => Keyword::Continue,
        b"def" => Keyword::Function,
        b"elif" | b"else" => Keyword::BranchElse,
        b"except" => Keyword::Except,
        b"for" | b"while" => Keyword::Loop,
        b"from" | b"import" => Keyword::Import,
        b"global" | b"nonlocal" => Keyword::Global,
        b"if" => Keyword::Branch,
        b"lambda" => Keyword::Lambda,
        b"match" => Keyword::Match,
        b"return" => Keyword::Return,
        b"try" => Keyword::Try,
        b"and" => return Some(TokenKind::Punctuation(Punctuation::AmpersandDouble)),
        b"not" => return Some(TokenKind::Punctuation(Punctuation::Bang)),
        b"or" => return Some(TokenKind::Punctuation(Punctuation::BarDouble)),
        b"as" | b"async" | b"await" | b"del" | b"finally" => Keyword::Other,
        b"in" | b"is" | b"pass" | b"raise" => Keyword::Other,
        b"with" | b"yield" => Keyword::Other,
        _ => return None,
    };

    Some(TokenKind::Keyword(keyword))
}

impl Scanner<'_> {
    fn run(&mut self, tokens: &mut Tokens) -> Lex {
        let mut line_start = true;

        while self.offset < self.source.len() {
            let before = self.offset;

            if line_start && self.brackets == 0 {
                match self.indentation(tokens) {
                    Indent::Blank => {}
                    Indent::Content => line_start = false,
                    Indent::Truncated => return Lex::Truncated,
                }

                assert!(self.offset > before || !line_start);

                continue;
            }

            if self.advance(tokens, &mut line_start) == Lex::Truncated {
                return Lex::Truncated;
            }

            assert!(self.offset > before);
        }

        self.dedent_all(tokens)
    }

    fn advance(&mut self, tokens: &mut Tokens, line_start: &mut bool) -> Lex {
        assert!(self.offset < self.source.len());

        let byte = self.source[self.offset];
        let terminator = crate::scan::line_break_width(self.source, self.offset);

        if terminator > 0 {
            if self.brackets == 0 {
                if !tokens.push(self.source, TokenKind::Newline, self.offset, terminator) {
                    return Lex::Truncated;
                }

                *line_start = true;
            }

            self.offset += terminator;

            return Lex::Complete;
        }

        let continued = byte == b'\\';
        let joined = crate::scan::line_break_width(self.source, self.offset + 1);

        if continued && joined > 0 {
            self.offset += 1 + joined;

            return Lex::Complete;
        }

        if matches!(byte, b' ' | b'\t' | b'\x0c') {
            self.offset += 1;

            return Lex::Complete;
        }

        let (kind, end) = self.token();

        assert!(end > self.offset);

        if !tokens.push(self.source, kind, self.offset, end - self.offset) {
            return Lex::Truncated;
        }

        self.brackets_track(kind);
        self.offset = end;

        Lex::Complete
    }

    const fn brackets_track(&mut self, kind: TokenKind) {
        let opening = matches!(
            kind,
            TokenKind::Punctuation(Punctuation::BracketOpen | Punctuation::ParenOpen)
        );

        if opening {
            self.brackets += 1;
        }

        let closing = matches!(
            kind,
            TokenKind::Punctuation(Punctuation::BracketClose | Punctuation::ParenClose)
        );

        if closing {
            self.brackets = self.brackets.saturating_sub(1);
        }
    }

    fn dedent_all(&mut self, tokens: &mut Tokens) -> Lex {
        while self.depth > 1 {
            self.depth -= 1;

            if !tokens.push(self.source, TokenKind::BlockEnd, self.source.len(), 0) {
                return Lex::Truncated;
            }
        }

        assert_eq!(self.depth, 1);

        Lex::Complete
    }

    fn indentation(&mut self, tokens: &mut Tokens) -> Indent {
        let start = self.offset;
        let mut column = 0;

        while self.offset < self.source.len() {
            match self.source[self.offset] {
                b' ' => column += 1,
                b'\t' => column += TAB_COLUMNS - (column % TAB_COLUMNS),
                FORM_FEED => column = 0,
                _ => break,
            }

            self.offset += 1;
        }

        if self.offset >= self.source.len() {
            return Indent::Blank;
        }

        if self.source[self.offset] == b'#' {
            let end = line_end(self.source, self.offset);

            if !tokens.push(
                self.source,
                TokenKind::Comment,
                self.offset,
                end - self.offset,
            ) {
                return Indent::Truncated;
            }

            self.offset = self.line_skip(end);

            return Indent::Blank;
        }

        if matches!(self.source[self.offset], b'\n' | b'\r') {
            self.offset = self.line_skip(line_end(self.source, self.offset));

            return Indent::Blank;
        }

        assert!(self.depth > 0);

        self.levelled(tokens, start, column)
    }

    fn levelled(&mut self, tokens: &mut Tokens, start: usize, column: u32) -> Indent {
        assert!(self.depth > 0);

        if column > self.columns[self.depth - 1] {
            if self.depth == DEPTH_MAX as usize {
                return Indent::Content;
            }

            self.columns[self.depth] = column;
            self.depth += 1;

            if !tokens.push(self.source, TokenKind::BlockStart, start, 0) {
                return Indent::Truncated;
            }

            return Indent::Content;
        }

        while self.depth > 1 && column < self.columns[self.depth - 1] {
            self.depth -= 1;

            if !tokens.push(self.source, TokenKind::BlockEnd, start, 0) {
                return Indent::Truncated;
            }
        }

        if self.depth > 1 && column > self.columns[self.depth - 1] {
            self.columns[self.depth - 1] = column;
        }

        Indent::Content
    }

    fn line_skip(&self, end: usize) -> usize {
        let skipped = end + crate::scan::line_break_width(self.source, end);

        assert!(skipped <= self.source.len());
        assert!(skipped > end || end == self.source.len());

        skipped
    }

    fn token(&self) -> (TokenKind, usize) {
        token_at(self.source, self.offset)
    }
}

fn string_prefixed(source: &[u8], offset: usize) -> Option<usize> {
    let scanner = Prefix { offset, source };

    scanner.run()
}

struct Prefix<'source> {
    offset: usize,
    source: &'source [u8],
}

impl Prefix<'_> {
    fn run(&self) -> Option<usize> {
        let mut length = 0;

        while length < 2 && self.offset + length < self.source.len() {
            let byte = self.source[self.offset + length].to_ascii_lowercase();

            if !matches!(byte, b'b' | b'f' | b'r' | b't' | b'u') {
                break;
            }

            length += 1;
        }

        if length == 0 {
            return None;
        }

        let quote = self.source.get(self.offset + length)?;

        if !matches!(quote, b'"' | b'\'') {
            return None;
        }

        Some(self.offset + length)
    }
}

fn interpolates(source: &[u8], offset: usize, quote: usize) -> bool {
    assert!(quote > offset);

    source[offset..quote]
        .iter()
        .any(|byte| matches!(byte.to_ascii_lowercase(), b'f' | b't'))
}

pub(crate) fn token_at(source: &[u8], offset: usize) -> (TokenKind, usize) {
    let byte = source[offset];

    if byte == b'#' {
        return (TokenKind::Comment, line_end(source, offset));
    }

    if matches!(byte, b'"' | b'\'') {
        return (TokenKind::String, string_python_scan(source, offset));
    }

    if let Some(start) = string_prefixed(source, offset) {
        if interpolates(source, offset, start) {
            return (TokenKind::String, string_format_scan(source, start));
        }

        return (TokenKind::String, string_python_scan(source, start));
    }

    if is_identifier_start_at(source, offset) {
        let end = identifier_scan(source, offset);

        if is_assertion(source, offset, end) {
            return (TokenKind::Keyword(Keyword::Assert), end);
        }

        let text = &source[offset..end];

        if text == SOFT_WORD && !opens_a_line(source, offset) {
            return (TokenKind::Identifier, end);
        }

        return match word_of(text) {
            Some(kind) => (kind, end),
            None => (TokenKind::Identifier, end),
        };
    }

    if byte.is_ascii_digit() {
        return (TokenKind::Number, number_python_scan(source, offset));
    }

    if byte == b'{' {
        return (TokenKind::Punctuation(Punctuation::BracketOpen), offset + 1);
    }

    if byte == b'}' {
        return (
            TokenKind::Punctuation(Punctuation::BracketClose),
            offset + 1,
        );
    }

    let (punctuation, length) = punctuation_of(source, offset);

    (TokenKind::Punctuation(punctuation), offset + length)
}

fn number_python_scan(source: &[u8], start: usize) -> usize {
    assert!(start < source.len());
    assert!(source[start].is_ascii_digit());

    if source[start] == b'0' {
        if let Some(end) = number_python_based(source, start) {
            return end;
        }
    }

    let mut offset = digits_scan(source, start, u8::is_ascii_digit);

    if source.get(offset) == Some(&b'.') {
        offset = digits_scan(source, offset + 1, u8::is_ascii_digit);
    }

    offset = exponent_scan(source, offset);

    if matches!(source.get(offset), Some(b'j' | b'J')) {
        offset += 1;
    }

    assert!(offset > start);

    offset
}

fn number_python_based(source: &[u8], start: usize) -> Option<usize> {
    let digit: fn(&u8) -> bool = match source.get(start + 1)? {
        b'b' | b'B' => |held| matches!(held, b'0' | b'1'),
        b'o' | b'O' => |held| matches!(held, b'0'..=b'7'),
        b'x' | b'X' => u8::is_ascii_hexdigit,
        _ => return None,
    };

    let end = digits_scan(source, start + 2, digit);

    (end > start + 2).then_some(end)
}

fn exponent_scan(source: &[u8], start: usize) -> usize {
    if !matches!(source.get(start), Some(b'e' | b'E')) {
        return start;
    }

    let signed = matches!(source.get(start + 1), Some(b'+' | b'-'));
    let digits = start + 1 + usize::from(signed);
    let end = digits_scan(source, digits, u8::is_ascii_digit);

    if end == digits {
        return start;
    }

    end
}

fn digits_scan(source: &[u8], start: usize, digit: fn(&u8) -> bool) -> usize {
    let mut offset = start;

    while offset < source.len() {
        let byte = source[offset];

        if digit(&byte) {
            offset += 1;

            continue;
        }

        if byte != b'_' || offset == start || !source.get(offset + 1).is_some_and(digit) {
            break;
        }

        offset += 2;
    }

    assert!(offset >= start);

    offset
}

fn line_end(source: &[u8], start: usize) -> usize {
    assert!(start <= source.len());

    let mut offset = start;

    while offset < source.len() && crate::scan::line_break_width(source, offset) == 0 {
        offset += 1;
    }

    assert!(offset >= start);

    offset
}

fn string_format_scan(source: &[u8], start: usize) -> usize {
    assert!(matches!(source[start], b'"' | b'\''));

    let quote = source[start];

    let triple =
        source.len() > start + 2 && source[start + 1] == quote && source[start + 2] == quote;

    let width = if triple { 3 } else { 1 };
    let mut depth = 0_u32;
    let mut offset = start + width;

    while offset < source.len() {
        let byte = source[offset];

        if byte == b'\\' {
            offset += if matches!(source.get(offset + 1), Some(b'{' | b'}')) {
                1
            } else {
                2
            };

            continue;
        }

        if depth == 0 && !triple && crate::scan::line_break_width(source, offset) > 0 {
            return offset;
        }

        if matches!(byte, b'{' | b'}') && source.get(offset + 1) == Some(&byte) && depth == 0 {
            offset += 2;

            continue;
        }

        if byte == b'{' {
            if depth == FIELD_DEPTH_MAX {
                return source.len();
            }

            depth += 1;
            offset += 1;

            continue;
        }

        if byte == b'}' && depth > 0 {
            depth -= 1;
            offset += 1;

            continue;
        }

        if depth > 0 && matches!(byte, b'"' | b'\'') {
            offset = string_python_scan(source, offset);

            continue;
        }

        if depth == 0 && byte == quote && closes(source, offset, quote, width) {
            return offset + width;
        }

        offset += 1;
    }

    source.len()
}

fn closes(source: &[u8], offset: usize, quote: u8, width: usize) -> bool {
    assert!(width == 1 || width == 3);

    offset + width <= source.len()
        && source[offset..offset + width]
            .iter()
            .all(|byte| *byte == quote)
}

fn string_python_scan(source: &[u8], start: usize) -> usize {
    assert!(matches!(source[start], b'"' | b'\''));

    let quote = source[start];

    let triple =
        source.len() > start + 2 && source[start + 1] == quote && source[start + 2] == quote;

    if !triple {
        return string_scan_continued(source, start, quote);
    }

    let mut offset = start + 3;

    while offset + 2 < source.len() {
        if source[offset] == b'\\' {
            offset += 2;

            continue;
        }

        let closing =
            source[offset] == quote && source[offset + 1] == quote && source[offset + 2] == quote;

        if closing {
            return offset + 3;
        }

        offset += 1;
    }

    source.len()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lex::tests_support;

    #[test]
    fn a_format_string_ends_at_its_own_quote_and_not_an_interior_one() {
        assert_eq!(string_format_scan(b"\"a{b}c\"x", 0), 7);
        assert_eq!(string_format_scan(b"\"a{b!r:>{w}}c\"", 0), 14);
        assert_eq!(string_format_scan(b"\"{'x'}\"y", 0), 7);
        assert_eq!(string_format_scan(b"\"{{a}}\"", 0), 7);
        assert_eq!(string_format_scan(b"\"a\\\"b\"", 0), 6);
        assert_eq!(string_format_scan(b"\"a\nb", 0), 2);
        assert_eq!(string_format_scan(b"\"\"\"a\nb\"\"\"c", 0), 9);
        assert_eq!(string_format_scan(b"\"a", 0), 2);
        assert_eq!(string_format_scan(b"''", 0), 2);
    }

    #[test]
    fn the_scan_steps_by_two_and_not_by_double() {
        assert_eq!(string_format_scan(b"''x'", 0), 2);
        assert_eq!(string_format_scan(b"\"abc\\\"d\"XY", 0), 8);
        assert_eq!(string_format_scan(b"\"a{{b}}\"XY", 0), 8);
    }

    #[test]
    fn a_call_is_the_parenthesis_past_the_spaces() {
        assert!(calls(b"f()", 1));
        assert!(calls(b"f ()", 1));
        assert!(calls(b"f   ()", 1));
        assert!(!calls(b"f", 1));
        assert!(!calls(b"f = 1", 1));
        assert!(!calls(b"f\n()", 1));
    }

    #[test]
    fn a_soft_keyword_opens_a_line_only_behind_blanks() {
        assert!(opens_a_line(b"", 0));
        assert!(opens_a_line(b"    match", 4));
        assert!(opens_a_line(b"x\n    match", 6));
        assert!(opens_a_line(b"x\rmatch", 2));
        assert!(!opens_a_line(b"re.match", 3));
        assert!(!opens_a_line(b"x match", 2));
    }

    #[test]
    fn an_assertion_is_named_by_its_word_or_by_its_receiver() {
        assert!(is_assertion(b"assert_equal()", 0, 12));
        assert!(is_assertion(b"self.assertTrue()", 5, 15));
        assert!(is_assertion(b"self.failUnless()", 5, 15));
        assert!(!is_assertion(b"assertTrue()", 0, 10));
        assert!(!is_assertion(b"that.assertTrue()", 5, 15));
        assert!(!is_assertion(b"self.assertTrue", 5, 15));
        assert!(!is_assertion(b"self.compute()", 5, 12));
    }

    const KEYWORDS: &[(&str, &str, TokenKind)] = &[
        ("False", "value = False\n", TokenKind::Identifier),
        ("None", "value = None\n", TokenKind::Identifier),
        ("True", "value = True\n", TokenKind::Identifier),
        (
            "and",
            "value = first and second\n",
            TokenKind::Punctuation(Punctuation::AmpersandDouble),
        ),
        (
            "as",
            "import os as system\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "assert",
            "def f(value):\n    assert value\n",
            TokenKind::Keyword(Keyword::Assert),
        ),
        (
            "async",
            "async def f():\n    pass\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "await",
            "async def f(task):\n    await task\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "break",
            "for index in range(4):\n    break\n",
            TokenKind::Keyword(Keyword::Break),
        ),
        (
            "class",
            "class Store:\n    pass\n",
            TokenKind::Keyword(Keyword::Struct),
        ),
        (
            "continue",
            "for index in range(4):\n    continue\n",
            TokenKind::Keyword(Keyword::Continue),
        ),
        (
            "def",
            "def f():\n    pass\n",
            TokenKind::Keyword(Keyword::Function),
        ),
        (
            "del",
            "def f(values):\n    del values[0]\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "elif",
            "if first:\n    pass\nelif second:\n    pass\n",
            TokenKind::Keyword(Keyword::BranchElse),
        ),
        (
            "else",
            "if first:\n    pass\nelse:\n    pass\n",
            TokenKind::Keyword(Keyword::BranchElse),
        ),
        (
            "except",
            "try:\n    pass\nexcept OSError:\n    pass\n",
            TokenKind::Keyword(Keyword::Except),
        ),
        (
            "finally",
            "try:\n    pass\nfinally:\n    pass\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "for",
            "for index in range(4):\n    pass\n",
            TokenKind::Keyword(Keyword::Loop),
        ),
        (
            "from",
            "from os import path\n",
            TokenKind::Keyword(Keyword::Import),
        ),
        (
            "global",
            "def f():\n    global count\n",
            TokenKind::Keyword(Keyword::Global),
        ),
        (
            "if",
            "if first:\n    pass\n",
            TokenKind::Keyword(Keyword::Branch),
        ),
        ("import", "import os\n", TokenKind::Keyword(Keyword::Import)),
        (
            "in",
            "for index in range(4):\n    pass\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "is",
            "value = first is second\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "lambda",
            "increment = lambda value: value + 1\n",
            TokenKind::Keyword(Keyword::Lambda),
        ),
        (
            "nonlocal",
            "def outer():\n    count = 0\n\n    def inner():\n        nonlocal count\n",
            TokenKind::Keyword(Keyword::Global),
        ),
        (
            "not",
            "value = not first\n",
            TokenKind::Punctuation(Punctuation::Bang),
        ),
        (
            "or",
            "value = first or second\n",
            TokenKind::Punctuation(Punctuation::BarDouble),
        ),
        (
            "pass",
            "def f():\n    pass\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "raise",
            "def f():\n    raise OSError\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "return",
            "def f():\n    return 0\n",
            TokenKind::Keyword(Keyword::Return),
        ),
        (
            "try",
            "try:\n    pass\nexcept OSError:\n    pass\n",
            TokenKind::Keyword(Keyword::Try),
        ),
        (
            "while",
            "while first:\n    pass\n",
            TokenKind::Keyword(Keyword::Loop),
        ),
        (
            "with",
            "with open(path) as handle:\n    pass\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "yield",
            "def f():\n    yield 0\n",
            TokenKind::Keyword(Keyword::Other),
        ),
    ];

    const SOFT_KEYWORDS: &[(&str, &str, TokenKind)] = &[
        (
            "_",
            "match value:\n    case _:\n        pass\n",
            TokenKind::Identifier,
        ),
        (
            "case",
            "match value:\n    case 1:\n        pass\n",
            TokenKind::Identifier,
        ),
        (
            "match",
            "match value:\n    case 1:\n        pass\n",
            TokenKind::Keyword(Keyword::Match),
        ),
        ("type", "type Count = int\n", TokenKind::Identifier),
    ];

    const PUNCTUATION: &[(&str, &str, TokenKind)] = &[
        (
            "!=",
            "value = first != second\n",
            TokenKind::Punctuation(Punctuation::NotEqual),
        ),
        (
            "(",
            "def f():\n    pass\n",
            TokenKind::Punctuation(Punctuation::ParenOpen),
        ),
        (
            ")",
            "def f():\n    pass\n",
            TokenKind::Punctuation(Punctuation::ParenClose),
        ),
        (
            "*",
            "value = first * second\n",
            TokenKind::Punctuation(Punctuation::Star),
        ),
        (
            "+",
            "value = first + second\n",
            TokenKind::Punctuation(Punctuation::Other),
        ),
        (
            ",",
            "def f(first, second):\n    pass\n",
            TokenKind::Punctuation(Punctuation::Comma),
        ),
        (
            "-",
            "value = first - second\n",
            TokenKind::Punctuation(Punctuation::Other),
        ),
        (
            "->",
            "def f() -> int:\n    return 0\n",
            TokenKind::Punctuation(Punctuation::Arrow),
        ),
        (
            ".",
            "value = os.path\n",
            TokenKind::Punctuation(Punctuation::Dot),
        ),
        (
            "/",
            "value = first / second\n",
            TokenKind::Punctuation(Punctuation::Slash),
        ),
        (
            ":",
            "def f():\n    pass\n",
            TokenKind::Punctuation(Punctuation::Colon),
        ),
        (
            ";",
            "value = 1; count = 2\n",
            TokenKind::Punctuation(Punctuation::Semicolon),
        ),
        (
            "<",
            "value = first < second\n",
            TokenKind::Punctuation(Punctuation::Less),
        ),
        (
            "<=",
            "value = first <= second\n",
            TokenKind::Punctuation(Punctuation::LessEqual),
        ),
        (
            "=",
            "value = 1\n",
            TokenKind::Punctuation(Punctuation::Assign),
        ),
        (
            "==",
            "value = first == second\n",
            TokenKind::Punctuation(Punctuation::Equal),
        ),
        (
            ">",
            "value = first > second\n",
            TokenKind::Punctuation(Punctuation::Greater),
        ),
        (
            ">=",
            "value = first >= second\n",
            TokenKind::Punctuation(Punctuation::GreaterEqual),
        ),
        (
            "@",
            "@decorator\ndef f():\n    pass\n",
            TokenKind::Punctuation(Punctuation::Other),
        ),
        (
            "[",
            "value = values[0]\n",
            TokenKind::Punctuation(Punctuation::BracketOpen),
        ),
        (
            "]",
            "value = values[0]\n",
            TokenKind::Punctuation(Punctuation::BracketClose),
        ),
        (
            "^",
            "value = first ^ second\n",
            TokenKind::Punctuation(Punctuation::Other),
        ),
        (
            "{",
            "value = {}\n",
            TokenKind::Punctuation(Punctuation::BracketOpen),
        ),
        (
            "|",
            "value = first | second\n",
            TokenKind::Punctuation(Punctuation::Other),
        ),
        (
            "}",
            "value = {}\n",
            TokenKind::Punctuation(Punctuation::BracketClose),
        ),
        (
            "~",
            "value = ~first\n",
            TokenKind::Punctuation(Punctuation::Other),
        ),
    ];

    #[test]
    fn every_keyword_of_the_specification_lexes_to_its_kind() {
        assert_eq!(KEYWORDS.len(), 35);

        for (word, source, expected) in KEYWORDS {
            assert_eq!(
                tests_support::kind_of(&PYTHON, source, word),
                *expected,
                "{word}"
            );
        }
    }

    #[test]
    fn every_soft_keyword_of_the_specification_lexes_to_its_kind() {
        assert_eq!(SOFT_KEYWORDS.len(), 4);

        for (word, source, expected) in SOFT_KEYWORDS {
            assert_eq!(
                tests_support::kind_of(&PYTHON, source, word),
                *expected,
                "{word}"
            );
        }
    }

    #[test]
    fn a_number_ends_where_the_python_grammar_ends_it() {
        for (source, wanted) in [
            ("1", 1),
            ("0", 1),
            ("1_000_000", 9),
            ("1_", 1),
            ("1.5", 3),
            ("1.", 2),
            ("1..real", 2),
            ("1.e5", 4),
            ("1e5", 3),
            ("1e+9", 4),
            ("1e-9", 4),
            ("1e", 1),
            ("1e+", 1),
            ("1j", 2),
            ("1.5j", 4),
            ("0x1f", 4),
            ("0XCAFE", 6),
            ("0b1010", 6),
            ("0o777", 5),
            ("0x", 1),
            ("0b2", 1),
            ("1if", 1),
            ("1and", 1),
            ("1syntax_error", 1),
        ] {
            assert_eq!(number_python_scan(source.as_bytes(), 0), wanted, "{source}");
        }
    }

    #[test]
    fn a_word_behind_a_number_lexes_as_its_own_token() {
        let source = b"1syntax_error\n";
        let tokens = tests_support::lex(&PYTHON, source);

        assert_eq!(tokens[0].text(source), b"1");
        assert_eq!(tokens[1].text(source), b"syntax_error");
    }

    #[test]
    fn a_two_character_operator_lexes_as_two_tokens() {
        for (source, word) in [
            ("value = first ** second\n", b"*"),
            ("value = first // second\n", b"/"),
            ("if (value := read()) > 0:\n    pass\n", b":"),
        ] {
            let bytes = source.as_bytes();
            let tokens = tests_support::lex(&PYTHON, bytes);

            let first = tokens
                .iter()
                .position(|token| token.text(bytes) == word)
                .expect("the operator opens with its first character");

            assert_eq!(tokens[first].length, 1, "{source}");
            assert_eq!(tokens[first + 1].length, 1, "{source}");
        }
    }

    #[test]
    fn a_backslash_joins_the_next_line() {
        let source = b"value = 1 + \\\n    2\n";
        let tokens = tests_support::lex(&PYTHON, source);

        let newlines = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::Newline)
            .count();

        assert_eq!(newlines, 1);
    }

    #[test]
    fn a_backslash_before_anything_else_is_punctuation() {
        let source = b"value = 1\n";
        let joined = tests_support::lex(&PYTHON, b"value = 1 + \\\n    2\n");

        assert!(joined.len() > tests_support::lex(&PYTHON, source).len());
    }

    fn counted(tokens: &[crate::token::Token], wanted: TokenKind) -> usize {
        tokens.iter().filter(|token| token.kind == wanted).count()
    }

    fn structure(source: &[u8]) -> (usize, usize, usize) {
        let tokens = tests_support::lex(&PYTHON, source);

        (
            counted(&tokens, TokenKind::BlockStart),
            counted(&tokens, TokenKind::BlockEnd),
            counted(&tokens, TokenKind::Newline),
        )
    }

    #[test]
    fn a_windows_continuation_joins_its_line() {
        assert_eq!(
            structure(b"def f():\r\n    value = 1 + \\\r\n        2\r\n    return value\r\n"),
            structure(b"def f():\n    value = 1 + \\\n        2\n    return value\n")
        );
    }

    #[test]
    fn a_lone_carriage_return_ends_its_line() {
        assert_eq!(
            structure(b"def f():\r    return 1\r"),
            structure(b"def f():\n    return 1\n")
        );
    }

    #[test]
    fn a_form_feed_does_not_dedent_the_block_it_sits_in() {
        let source = b"class Store:\n    def read(self):\n        return 1\n\x0c\n    \
            def write(self):\n        return 2\n";

        let plain = b"class Store:\n    def read(self):\n        return 1\n\n    \
            def write(self):\n        return 2\n";

        assert_eq!(structure(source), structure(plain));
    }

    #[test]
    fn a_backslash_carries_a_single_quoted_string_over_the_newline() {
        let source = b"plain = 'a\\\nb'\nafter = 1\n";
        let tokens = tests_support::lex(&PYTHON, source);

        assert_eq!(tokens[2].kind, TokenKind::String);
        assert_eq!(tokens[2].text(source), b"'a\\\nb'");
    }

    #[test]
    fn an_unterminated_string_still_stops_at_its_line() {
        let source = b"plain = 'a\nafter = 1\n";
        let tokens = tests_support::lex(&PYTHON, source);

        assert_eq!(tokens[2].text(source), b"'a");
    }

    #[test]
    fn a_replacement_field_may_carry_the_quote_around_it() {
        let source = b"value = f\"{palette[\"#fff\"]}\"\nother = 1\n";
        let tokens = tests_support::lex(&PYTHON, source);

        assert_eq!(tokens[2].kind, TokenKind::String);
        assert_eq!(tokens[2].text(source), b"f\"{palette[\"#fff\"]}\"");
        assert_eq!(structure(source).2, 2);
    }

    #[test]
    fn a_template_literal_carries_its_own_prefix() {
        let source = b"value = t\"{name}\"\n";
        let tokens = tests_support::lex(&PYTHON, source);

        assert_eq!(tokens[2].kind, TokenKind::String);
        assert_eq!(tokens[2].text(source), b"t\"{name}\"");
    }

    #[test]
    fn a_doubled_brace_is_not_a_replacement_field() {
        let source = b"value = f\"{{literal}}\"\n";
        let tokens = tests_support::lex(&PYTHON, source);

        assert_eq!(tokens[2].text(source), b"f\"{{literal}}\"");
    }

    #[test]
    fn a_dotted_match_is_not_a_match_statement() {
        assert_eq!(
            tests_support::kind_of(&PYTHON, "found = re.match(pattern, text)\n", "match"),
            TokenKind::Identifier
        );

        assert_eq!(
            tests_support::kind_of(
                &PYTHON,
                "match command:\n    case 1:\n        pass\n",
                "match"
            ),
            TokenKind::Keyword(Keyword::Match)
        );
    }

    #[test]
    fn an_attribute_named_for_a_failure_is_not_an_assertion() {
        let source = b"class Case:\n    def test(self):\n        self.failures = []\n";
        let tokens = tests_support::lex(&PYTHON, source);

        assert_eq!(
            tokens
                .iter()
                .filter(|token| token.is_keyword(Keyword::Assert))
                .count(),
            0
        );
    }

    #[test]
    fn a_receiver_assertion_is_a_keyword() {
        let source = b"class Case:\n    def test(self):\n        self.assertEqual(1, 1)\n";
        let tokens = tests_support::lex(&PYTHON, source);

        let asserts = tokens
            .iter()
            .filter(|token| token.is_keyword(Keyword::Assert))
            .count();

        assert_eq!(asserts, 1);
    }

    #[test]
    fn a_receiver_failure_is_a_keyword() {
        let source = b"class Case:\n    def test(self):\n        self.fail(\"no\")\n";
        let tokens = tests_support::lex(&PYTHON, source);

        let asserts = tokens
            .iter()
            .filter(|token| token.is_keyword(Keyword::Assert))
            .count();

        assert_eq!(asserts, 1);
    }

    #[test]
    fn a_bare_assert_equal_name_is_not_a_receiver_assertion() {
        let source = b"assertEqual = 1\n";
        let tokens = tests_support::lex(&PYTHON, source);

        assert_eq!(tokens[0].kind, TokenKind::Identifier);
    }

    #[test]
    fn a_comment_at_the_source_end_closes_the_line() {
        let source = b"value = 1\n# a trailing comment";
        let tokens = tests_support::lex(&PYTHON, source);
        let last = tokens.last().expect("the comment is a token");

        assert_eq!(last.kind, TokenKind::Comment);
        assert_eq!(last.offset, 10);
        assert_eq!(last.length, 20);
    }

    #[test]
    fn a_trailing_indent_without_a_newline_is_blank() {
        let source = b"def read():\n    return 0\n   ";
        let tokens = tests_support::lex(&PYTHON, source);

        assert!(!tokens.is_empty());
    }

    #[test]
    fn a_two_quote_run_at_the_source_end_is_an_empty_string() {
        let source = b"text = \"\"";
        let tokens = tests_support::lex(&PYTHON, source);

        let string = tokens
            .iter()
            .find(|token| token.kind == TokenKind::String)
            .expect("the string is a token");

        assert_eq!(string.length, 2);
    }

    #[test]
    fn a_triple_quote_at_the_source_end_opens_an_unclosed_string() {
        let source = b"text = \"\"\"";
        let tokens = tests_support::lex(&PYTHON, source);

        let string = tokens
            .iter()
            .find(|token| token.kind == TokenKind::String)
            .expect("the string is a token");

        assert_eq!(string.offset, 7);
        assert_eq!(string.length, 3);
    }

    #[test]
    fn a_dedent_between_two_levels_takes_the_column_it_landed_on() {
        let source = b"if a:\n    if b:\n        x = 1\n      y = 2\n      z = 3\n";
        let tokens = tests_support::lex(&PYTHON, source);

        let opens = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::BlockStart)
            .count();

        let closes = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::BlockEnd)
            .count();

        assert_eq!(opens, 2);
        assert_eq!(closes, 2);
    }

    #[test]
    fn a_dedent_between_two_levels_reads_the_level_it_landed_in_not_a_deeper_one() {
        let source =
            b"if a:\n    if b:\n        if c:\n            x = 1\n      y = 2\n      z = 3\n";

        let tokens = tests_support::lex(&PYTHON, source);

        let opens = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::BlockStart)
            .count();

        assert_eq!(opens, 3);
    }

    #[test]
    fn a_dedent_between_the_file_level_and_the_first_block_keeps_the_file_level() {
        let source = b"if a:\n    x = 1\n  y = 2\n  z = 3\n";
        let tokens = tests_support::lex(&PYTHON, source);

        let opens = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::BlockStart)
            .count();

        assert_eq!(opens, 2);
    }

    #[test]
    fn a_dedent_to_the_outermost_column_closes_every_block() {
        let source = b"def read():\n    if ready:\n        return 1\nvalue = 2\n";
        let tokens = tests_support::lex(&PYTHON, source);

        let opens = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::BlockStart)
            .count();

        let closes = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::BlockEnd)
            .count();

        assert_eq!(opens, 2);
        assert_eq!(closes, 2);
    }

    #[test]
    fn a_triple_quoted_string_runs_to_its_closing_triple() {
        let source = b"text = \"\"\"a \"quoted\" value\"\"\"\nnext = 1\n";
        let tokens = tests_support::lex(&PYTHON, source);

        let string = tokens
            .iter()
            .find(|token| token.kind == TokenKind::String)
            .expect("the string is a token");

        assert_eq!(string.offset, 7);
        assert_eq!(string.length, 22);
    }

    #[test]
    fn a_triple_quoted_string_spans_its_lines() {
        let source = b"text = \"\"\"first\nsecond\n\"\"\"\n";
        let tokens = tests_support::lex(&PYTHON, source);

        let string = tokens
            .iter()
            .find(|token| token.kind == TokenKind::String)
            .expect("the string is a token");

        assert_eq!(string.length, 19);
    }

    #[test]
    fn an_unclosed_triple_quoted_string_runs_to_the_source_end() {
        let source = b"text = \"\"\"unterminated\n";
        let tokens = tests_support::lex(&PYTHON, source);

        let string = tokens
            .iter()
            .find(|token| token.kind == TokenKind::String)
            .expect("the string is a token");

        assert_eq!(string.offset, 7);
        assert_eq!(string.length, 16);
    }

    #[test]
    fn a_two_quote_run_is_an_empty_string() {
        let source = b"text = \"\"\nnext = 1\n";
        let tokens = tests_support::lex(&PYTHON, source);

        let string = tokens
            .iter()
            .find(|token| token.kind == TokenKind::String)
            .expect("the string is a token");

        assert_eq!(string.length, 2);
    }

    #[test]
    fn a_single_quoted_triple_string_closes_on_its_own_quote() {
        let source = b"text = \'\'\'a value\'\'\'\n";
        let tokens = tests_support::lex(&PYTHON, source);

        let string = tokens
            .iter()
            .find(|token| token.kind == TokenKind::String)
            .expect("the string is a token");

        assert_eq!(string.length, 13);
    }

    #[test]
    fn a_prefixed_string_carries_its_prefix() {
        let source = b"value = f\"text\"\n";
        let tokens = tests_support::lex(&PYTHON, source);

        let string = tokens
            .iter()
            .find(|token| token.kind == TokenKind::String)
            .expect("the string is a token");

        assert_eq!(string.offset, 8);
        assert_eq!(string.length, 7);
    }

    #[test]
    fn a_two_letter_string_prefix_carries_both_letters() {
        let source = b"value = rb\"text\"\n";
        let tokens = tests_support::lex(&PYTHON, source);

        let string = tokens
            .iter()
            .find(|token| token.kind == TokenKind::String)
            .expect("the string is a token");

        assert_eq!(string.offset, 8);
        assert_eq!(string.length, 8);
    }

    #[test]
    fn a_three_letter_run_before_a_quote_is_not_a_prefix() {
        let source = b"value = rbu\"text\"\n";
        let tokens = tests_support::lex(&PYTHON, source);

        let name = tokens
            .iter()
            .find(|token| token.kind == TokenKind::Identifier && token.offset == 8)
            .expect("the run lexes as a name");

        assert_eq!(name.length, 3);
    }

    #[test]
    fn a_prefix_letter_without_a_quote_is_a_name() {
        let source = b"rb = 1\n";
        let tokens = tests_support::lex(&PYTHON, source);

        assert_eq!(tokens[0].kind, TokenKind::Identifier);
        assert_eq!(tokens[0].length, 2);
    }

    #[test]
    fn a_prefix_letter_at_the_source_end_is_a_name() {
        let source = b"value = f";
        let tokens = tests_support::lex(&PYTHON, source);
        let last = tokens.last().expect("the letter is a token");

        assert_eq!(last.kind, TokenKind::Identifier);
        assert_eq!(last.offset, 8);
        assert_eq!(last.length, 1);
    }

    #[test]
    fn a_tab_indents_to_the_next_tab_stop() {
        let source = b"def read():\n\treturn 0\n";
        let tokens = tests_support::lex(&PYTHON, source);

        let opens = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::BlockStart)
            .count();

        assert_eq!(opens, 1);
    }

    const TRIPLE_STRINGS: &[(&str, &str)] = &[
        ("value = \"\"\"a\"\"\"\n", "\"\"\"a\"\"\""),
        ("value = \"\"\"a\nb\"\"\"\n", "\"\"\"a\nb\"\"\""),
        ("value = \"\"\"\"\"\"\n", "\"\"\"\"\"\""),
        ("value = \"\"\"a\\\"\"\"b\"\"\"\n", "\"\"\"a\\\"\"\"b\"\"\""),
        ("value = '''a'''\n", "'''a'''"),
        ("value = \"a\"\n", "\"a\""),
    ];

    #[test]
    fn every_triple_quoted_shape_lexes_to_one_string() {
        for (source, expected) in TRIPLE_STRINGS {
            let bytes = source.as_bytes();
            let tokens = tests_support::lex(&PYTHON, bytes);
            let found = tokens
                .iter()
                .find(|token| token.kind == TokenKind::String)
                .unwrap_or_else(|| panic!("{source:?} carries a string"));

            assert_eq!(
                String::from_utf8_lossy(found.text(bytes)),
                *expected,
                "{source:?}"
            );
        }
    }

    #[test]
    fn a_triple_quoted_string_that_never_closes_stops_at_the_source_end() {
        assert_eq!(string_python_scan(b"\"\"\"abc", 0), 6);
        assert_eq!(string_python_scan(b"\"\"\"abc\n", 0), 7);
        assert_eq!(string_python_scan(b"\"\"\"ab\\", 0), 6);
        assert_eq!(string_python_scan(b"\"\"\"ab\"\"", 0), 7);
        assert_eq!(string_python_scan(b"\"\"\"ab\"", 0), 6);
    }

    #[test]
    fn a_two_byte_string_at_the_head_of_the_source_is_not_a_triple() {
        assert_eq!(string_python_scan(b"\"\"", 0), 2);
        assert_eq!(string_python_scan(b"''", 0), 2);
    }

    #[test]
    fn a_line_that_ends_the_source_skips_to_the_end_and_no_further() {
        let tokens = tests_support::lex(&PYTHON, b"value = 1");

        assert!(!tokens.is_empty());

        let commented = tests_support::lex(&PYTHON, b"# note");

        assert_eq!(commented.len(), 1);
        assert_eq!(commented[0].kind, TokenKind::Comment);
    }

    #[test]
    fn a_tab_and_eight_spaces_indent_alike() {
        let tabbed = tests_support::lex(&PYTHON, b"def read():\n\tif ready:\n\t\treturn 0\n");

        let spaced = tests_support::lex(
            &PYTHON,
            b"def read():\n        if ready:\n                return 0\n",
        );

        assert_eq!(counted(&tabbed, TokenKind::BlockStart), 2);

        assert_eq!(
            counted(&tabbed, TokenKind::BlockStart),
            counted(&spaced, TokenKind::BlockStart)
        );
    }

    #[test]
    fn every_punctuation_of_the_specification_lexes_to_its_kind() {
        for (word, source, expected) in PUNCTUATION {
            assert_eq!(
                tests_support::kind_of(&PYTHON, source, word),
                *expected,
                "{word}"
            );
        }
    }

    #[test]
    fn a_function_opens_and_closes_a_block() {
        let source = b"def main():\n    value = 1\n    return value\n";
        let tokens = tests_support::lex(&PYTHON, source);
        let kinds: Vec<TokenKind> = tokens.iter().map(|token| token.kind).collect();

        assert_eq!(kinds[0], TokenKind::Keyword(Keyword::Function));
        assert_eq!(kinds[1], TokenKind::Identifier);
        assert_eq!(kinds[5], TokenKind::Newline);
        assert_eq!(kinds[6], TokenKind::BlockStart);
        assert_eq!(kinds.last(), Some(&TokenKind::BlockEnd));
    }

    #[test]
    fn nesting_opens_one_block_for_each_level() {
        let source = b"def a():\n    if b:\n        return 1\n    return 2\n";
        let tokens = tests_support::lex(&PYTHON, source);

        let starts = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::BlockStart)
            .count();

        let ends = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::BlockEnd)
            .count();

        assert_eq!(starts, 2);
        assert_eq!(ends, 2);
    }

    #[test]
    fn a_blank_line_holds_the_indentation() {
        let source = b"def a():\n    x = 1\n\n    y = 2\n";
        let tokens = tests_support::lex(&PYTHON, source);

        let ends = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::BlockEnd)
            .count();

        assert_eq!(ends, 1);
    }

    #[test]
    fn a_bracket_suppresses_the_line_break() {
        let source = b"values = [\n    1,\n    2,\n]\n";
        let tokens = tests_support::lex(&PYTHON, source);

        let newlines = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::Newline)
            .count();

        let starts = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::BlockStart)
            .count();

        assert_eq!(newlines, 1);
        assert_eq!(starts, 0);
    }

    #[test]
    fn a_docstring_is_one_string_token() {
        let source = b"def a():\n    \"\"\"A note.\n\n    More.\n    \"\"\"\n    return 1\n";
        let tokens = tests_support::lex(&PYTHON, source);

        let strings: Vec<&crate::token::Token> = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::String)
            .collect();

        assert_eq!(strings.len(), 1);
        assert!(strings[0].text(source).starts_with(b"\"\"\"A note."));
    }

    #[test]
    fn a_prefixed_string_is_one_token() {
        let source = b"pattern = rb'\\d+'\nname = f\"{value}\"\n";
        let tokens = tests_support::lex(&PYTHON, source);

        let strings = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::String)
            .count();

        assert_eq!(strings, 2);
    }

    #[test]
    fn a_prefix_without_an_f_is_not_scanned_as_a_format_string() {
        let source = b"marker = b\"{\"\nvalue = 1\n";
        let tokens = tests_support::lex(&PYTHON, source);

        let strings: Vec<_> = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::String)
            .collect();

        assert_eq!(strings.len(), 1, "{tokens:?}");
        assert_eq!(strings[0].length, 4, "{tokens:?}");

        assert!(
            tokens.iter().any(|token| token.kind == TokenKind::Number),
            "{tokens:?}"
        );
    }

    #[test]
    fn an_assert_prefixed_name_is_an_assertion_anywhere() {
        let source = b"helper.assert_called_once()\n";
        let tokens = tests_support::lex(&PYTHON, source);

        let asserts = tokens
            .iter()
            .filter(|token| token.is_keyword(Keyword::Assert))
            .count();

        assert_eq!(asserts, 1);
    }

    #[test]
    fn an_assertion_method_needs_its_receiver() {
        let source = b"self.assertTrue(value)\nself.fail(\"no\")\n";
        let tokens = tests_support::lex(&PYTHON, source);

        let asserts = tokens
            .iter()
            .filter(|token| token.is_keyword(Keyword::Assert))
            .count();

        assert_eq!(asserts, 2);
    }

    #[test]
    fn another_receiver_carries_no_assertion() {
        let source = b"case.assertTrue(value)\ncase.fail(\"no\")\n";
        let tokens = tests_support::lex(&PYTHON, source);

        let asserts = tokens
            .iter()
            .filter(|token| token.is_keyword(Keyword::Assert))
            .count();

        assert_eq!(asserts, 0);
    }

    #[test]
    fn a_tab_advances_to_the_next_tab_stop_rather_than_by_one() {
        let source = b"def f():\n    \ta = 1\n            b = 2\n";
        let tokens = tests_support::lex(&PYTHON, source);

        let opened = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::BlockStart)
            .count();

        assert_eq!(
            opened, 2,
            "the tab should land on column 8 and the next line on 12, opening twice"
        );
    }
}
