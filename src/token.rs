use crate::bounded::{BoundedVec, Span, count_of};
use crate::brackets::{self, Pairs};
use crate::tree::Positioned;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Keyword {
    Assert,
    Branch,
    BranchElse,
    Break,
    Constant,
    Continue,
    Declare,
    Except,
    Function,
    Global,
    Goto,
    Import,
    Lambda,
    Loop,
    LoopUnbounded,
    Match,
    Mutable,
    Other,
    Return,
    Struct,
    Try,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Punctuation {
    Ampersand,
    AmpersandDouble,
    Arrow,
    Assign,
    AssignDeclare,
    Bang,
    BarDouble,
    BracketClose,
    BracketOpen,
    Colon,
    Comma,
    Dot,
    Equal,
    Greater,
    GreaterEqual,
    Less,
    LessEqual,
    NotEqual,
    Other,
    ParenClose,
    ParenOpen,
    Semicolon,
    Slash,
    Star,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TokenKind {
    BlockEnd,
    BlockStart,
    Comment,
    Identifier,
    Keyword(Keyword),
    Newline,
    Number,
    Punctuation(Punctuation),
    String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Token {
    pub kind: TokenKind,
    pub length: u32,
    pub offset: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Lex {
    Complete,
    Truncated,
}

#[derive(Debug)]
pub struct Tokens {
    end_previous: u32,
    items: BoundedVec<Token>,
}

pub struct TokenIndex {
    comments: u32,
    positions: BoundedVec<u32>,
}

pub fn in_span<T>(tokens: &[T], span: Span) -> &[T]
where
    T: Positioned,
{
    let first = index_from(tokens, span.offset);

    let last = tokens
        .partition_point(|token| token.offset() < span.end())
        .max(first);

    assert!(first <= last);
    assert!(last <= tokens.len());

    &tokens[first..last]
}

pub fn index_at<T>(tokens: &[T], offset: u32) -> Option<usize>
where
    T: Positioned,
{
    let index = index_from(tokens, offset);

    tokens
        .get(index)
        .filter(|token| token.offset() == offset)
        .map(|_| index)
}

pub fn index_from<T>(tokens: &[T], offset: u32) -> usize
where
    T: Positioned,
{
    let index = tokens.partition_point(|token| {
        token.offset() < offset || (token.offset() == offset && token.end() == offset)
    });

    assert!(index <= tokens.len());

    index
}

pub fn index_touching<T>(tokens: &[T], offset: u32) -> Option<usize>
where
    T: Positioned,
{
    let after = tokens.partition_point(|token| token.offset() < offset);

    assert!(after <= tokens.len());

    if let Some(before) = after.checked_sub(1)
        && offset <= tokens[before].end()
    {
        return Some(before);
    }

    tokens
        .get(after)
        .filter(|token| token.offset() == offset)
        .map(|_| after)
}

pub fn significant_next(tokens: &[Token], from: u32, end: u32) -> u32 {
    assert!(end as usize <= tokens.len());

    let mut index = from;

    while index < end {
        if is_significant(tokens[index as usize].kind) {
            return index;
        }

        index += 1;
    }

    end
}

pub fn previous_significant(tokens: &[Token], before: u32) -> u32 {
    assert!(before as usize <= tokens.len());

    let mut index = before;

    while index > 0 {
        index -= 1;

        if is_significant(tokens[index as usize].kind) {
            return index;
        }
    }

    u32::MAX
}

pub const fn is_significant(kind: TokenKind) -> bool {
    !matches!(kind, TokenKind::Comment | TokenKind::Newline)
}

pub fn operator_limit_of(tokens: &[Token], position: usize, end: u32) -> u32 {
    assert!(position < tokens.len());

    let mut reach = end;
    let mut index = position + 1;

    while index < tokens.len() {
        let held = tokens[index];

        if held.offset != reach {
            break;
        }

        if !matches!(held.kind, TokenKind::Number | TokenKind::Punctuation(_)) {
            break;
        }

        reach = held.end();
        index += 1;
    }

    reach
}

pub fn previous_significant_in_line(tokens: &[Token], before: u32) -> u32 {
    assert!(before as usize <= tokens.len());

    let mut index = before;

    while index > 0 {
        index -= 1;

        let skipped = matches!(
            tokens[index as usize].kind,
            TokenKind::BlockEnd | TokenKind::BlockStart | TokenKind::Newline
        );

        if !skipped {
            return index;
        }
    }

    u32::MAX
}

pub fn span_of_range(tokens: &[Token], start: usize, end: usize) -> Span {
    assert!(start < end);
    assert!(end <= tokens.len());

    let opened = tokens[start].span();
    let closed = tokens[end - 1].span();

    assert!(closed.end() >= opened.offset);

    Span::between(opened.offset, closed.end())
}

pub fn text_of_range<'source>(
    source: &'source [u8],
    tokens: &[Token],
    first: usize,
    last: usize,
) -> &'source [u8] {
    assert!(first <= last);
    assert!(last < tokens.len());

    let start = tokens[first].offset as usize;
    let end = tokens[last].end() as usize;

    &source[start..end]
}

pub fn keyword_count(tokens: &[Token], keyword: Keyword) -> u32 {
    let mut count = 0;

    for token in tokens {
        if token.is_keyword(keyword) {
            count += 1;
        }
    }

    count
}

pub fn line_start_of_token(tokens: &[Token], source: &[u8], index: usize) -> usize {
    assert!(index < tokens.len());

    let mut first = index;

    while first > 0 {
        let previous = &tokens[first - 1];

        if matches!(
            previous.kind,
            TokenKind::Newline | TokenKind::BlockStart | TokenKind::BlockEnd
        ) {
            break;
        }

        let before = previous.span();
        let current = tokens[first].span();
        let gap = before.offset as usize + before.length as usize;

        if gap > current.offset as usize || current.offset as usize > source.len() {
            break;
        }

        if source[gap..current.offset as usize].contains(&b'\n') {
            break;
        }

        first -= 1;
    }

    assert!(first <= index);

    first
}

pub fn statement_end(tokens: &[Token], start: usize) -> usize {
    let mut offset = start;

    while offset < tokens.len() {
        let terminal = matches!(
            tokens[offset].kind,
            TokenKind::Newline | TokenKind::BlockStart | TokenKind::BlockEnd
        ) || tokens[offset].is_punctuation(Punctuation::Semicolon);

        if terminal {
            return offset;
        }

        offset += 1;
    }

    tokens.len()
}

pub fn opens_a_statement(tokens: &[Token], index: usize) -> bool {
    let mut offset = index;

    while offset > 0 {
        offset -= 1;

        let token = &tokens[offset];

        if matches!(token.kind, TokenKind::Comment) {
            continue;
        }

        return matches!(
            token.kind,
            TokenKind::BlockEnd | TokenKind::BlockStart | TokenKind::Newline
        ) || token.is_punctuation(Punctuation::Semicolon);
    }

    true
}

pub fn expression_start(tokens: &[Token], source: &[u8], index: usize) -> usize {
    let line = line_start_of_token(tokens, source, index);
    let mut first = line;

    for (offset, token) in tokens.iter().enumerate().take(index).skip(line) {
        let assigns = token.is_punctuation(Punctuation::Assign)
            || token.is_punctuation(Punctuation::AssignDeclare);

        if assigns {
            first = offset + 1;
        }
    }

    assert!(first >= line);
    assert!(first <= index);

    first
}

pub fn path_start(tokens: &[Token], start: usize) -> usize {
    let mut cursor = start;

    while cursor > 0 {
        let before = cursor - 1;

        if tokens[before].kind == TokenKind::Identifier {
            cursor = before;

            continue;
        }

        if tokens[before].is_punctuation(Punctuation::Greater) {
            let opened = brackets::angle_open(tokens, before);

            if opened < before {
                cursor = opened;

                continue;
            }
        }

        let qualified = before > 0
            && tokens[before].is_punctuation(Punctuation::Colon)
            && tokens[before - 1].is_punctuation(Punctuation::Colon);

        if !qualified {
            break;
        }

        cursor = before - 1;
    }

    cursor
}

pub fn value_start(tokens: &[Token], start: usize) -> usize {
    let cursor = path_start(tokens, start);

    let Some(before) = cursor.checked_sub(1) else {
        return cursor;
    };

    if matches!(tokens[before].kind, TokenKind::Number | TokenKind::String) {
        return before;
    }

    cursor
}

pub fn macro_name(tokens: &[Token], open: usize) -> usize {
    let Some(before) = open.checked_sub(1) else {
        return open;
    };

    if tokens[before].is_punctuation(Punctuation::Bang) {
        return before;
    }

    open
}

pub fn modifier_start(
    pairs: &Pairs,
    tokens: &[Token],
    source: &[u8],
    index: usize,
    modifier_count_max: usize,
) -> usize {
    assert!(index < tokens.len());

    let line = line_start_of_token(tokens, source, index);
    let mut first = index;
    let mut skipped = 0;

    while first > line && skipped < modifier_count_max {
        let mut before = first - 1;

        if tokens[before].is_punctuation(Punctuation::ParenClose) {
            let Some(open) = pairs.open_of(before) else {
                break;
            };

            if open == 0 {
                break;
            }

            before = open - 1;
        }

        if before < line || !tokens[before].is_keyword(Keyword::Other) {
            break;
        }

        first = before;
        skipped += 1;
    }

    assert!(first <= index);

    first
}

pub fn label_start(tokens: &[Token], source: &[u8], index: usize) -> usize {
    assert!(index < tokens.len());

    let Some(colon) = index.checked_sub(1) else {
        return index;
    };

    if !tokens[colon].is_punctuation(Punctuation::Colon) {
        return index;
    }

    let Some(name) = colon.checked_sub(1) else {
        return index;
    };

    if tokens[name].kind != TokenKind::Identifier {
        return index;
    }

    if name == line_start_of_token(tokens, source, name) {
        return index;
    }

    name
}

impl Keyword {
    pub const fn name(self) -> &'static str {
        match self {
            Self::Assert => "assert",
            Self::Branch => "branch",
            Self::BranchElse => "branch-else",
            Self::Break => "break",
            Self::Constant => "constant",
            Self::Continue => "continue",
            Self::Declare => "declare",
            Self::Except => "except",
            Self::Function => "function",
            Self::Global => "global",
            Self::Goto => "goto",
            Self::Import => "import",
            Self::Lambda => "lambda",
            Self::Loop => "loop",
            Self::LoopUnbounded => "loop-unbounded",
            Self::Match => "match",
            Self::Mutable => "mutable",
            Self::Other => "other",
            Self::Return => "return",
            Self::Struct => "struct",
            Self::Try => "try",
        }
    }
}

impl Punctuation {
    pub const fn name(self) -> &'static str {
        match self {
            Self::Ampersand => "ampersand",
            Self::AmpersandDouble => "ampersand-double",
            Self::Arrow => "arrow",
            Self::Assign => "assign",
            Self::AssignDeclare => "assign-declare",
            Self::Bang => "bang",
            Self::BarDouble => "bar-double",
            Self::BracketClose => "bracket-close",
            Self::BracketOpen => "bracket-open",
            Self::Colon => "colon",
            Self::Comma => "comma",
            Self::Dot => "dot",
            Self::Equal => "equal",
            Self::Greater => "greater",
            Self::GreaterEqual => "greater-equal",
            Self::Less => "less",
            Self::LessEqual => "less-equal",
            Self::NotEqual => "not-equal",
            Self::Other => "other",
            Self::ParenClose => "paren-close",
            Self::ParenOpen => "paren-open",
            Self::Semicolon => "semicolon",
            Self::Slash => "slash",
            Self::Star => "star",
        }
    }
}

impl Positioned for Token {
    fn end(&self) -> u32 {
        Self::end(self)
    }

    fn offset(&self) -> u32 {
        self.offset
    }
}

impl Token {
    pub const fn end(&self) -> u32 {
        self.offset + self.length
    }

    pub fn is_keyword(&self, keyword: Keyword) -> bool {
        self.kind == TokenKind::Keyword(keyword)
    }

    pub fn is_punctuation(&self, punctuation: Punctuation) -> bool {
        self.kind == TokenKind::Punctuation(punctuation)
    }

    pub const fn span(&self) -> Span {
        Span {
            length: self.length,
            offset: self.offset,
        }
    }

    pub fn closes_a_group(&self) -> bool {
        self.is_punctuation(Punctuation::ParenClose)
            || self.is_punctuation(Punctuation::BracketClose)
    }

    pub fn opens_a_group(&self) -> bool {
        self.is_punctuation(Punctuation::ParenOpen) || self.is_punctuation(Punctuation::BracketOpen)
    }

    pub fn closes_a_group_or_block(&self) -> bool {
        self.kind == TokenKind::BlockEnd || self.closes_a_group()
    }

    pub fn opens_a_group_or_block(&self) -> bool {
        self.kind == TokenKind::BlockStart || self.opens_a_group()
    }

    pub fn ends_a_value(&self) -> bool {
        matches!(
            self.kind,
            TokenKind::BlockEnd
                | TokenKind::Identifier
                | TokenKind::Keyword(Keyword::Other)
                | TokenKind::Number
                | TokenKind::String
        ) || self.closes_a_group()
    }

    pub fn text<'source>(&self, source: &'source [u8]) -> &'source [u8] {
        let end = self.offset as usize + self.length as usize;

        assert!(end <= source.len());

        &source[self.offset as usize..end]
    }
}

impl TokenIndex {
    pub fn reserve(token_count_max: u32) -> Self {
        assert!(token_count_max > 0);

        assert!(!crate::allocation::is_frozen());

        Self {
            comments: 0,
            positions: BoundedVec::reserve(token_count_max),
        }
    }

    pub fn build(&mut self, tokens: &[Token]) {
        self.positions.clear();

        for (position, token) in tokens.iter().enumerate() {
            if token.kind == TokenKind::Comment {
                self.positions.push_assert(count_of(position));
            }
        }

        self.comments = self.positions.count();

        for (position, token) in tokens.iter().enumerate() {
            if token.kind == TokenKind::Identifier {
                self.positions.push_assert(count_of(position));
            }
        }

        assert!(self.comments <= self.positions.count());
    }

    pub fn comments(&self) -> &[u32] {
        &self.positions[..self.comments as usize]
    }

    pub fn identifiers(&self) -> &[u32] {
        &self.positions[self.comments as usize..]
    }
}

impl TokenKind {
    pub const fn name(self) -> &'static str {
        match self {
            Self::BlockEnd => "block-end",
            Self::BlockStart => "block-start",
            Self::Comment => "comment",
            Self::Identifier => "identifier",
            Self::Keyword(_) => "keyword",
            Self::Newline => "newline",
            Self::Number => "number",
            Self::Punctuation(_) => "punctuation",
            Self::String => "string",
        }
    }
}

impl Tokens {
    pub fn reserve(token_count_max: u32) -> Self {
        assert!(token_count_max > 0);

        assert!(!crate::allocation::is_frozen());

        Self {
            end_previous: 0,
            items: BoundedVec::reserve(token_count_max),
        }
    }

    pub fn as_slice(&self) -> &[Token] {
        &self.items
    }

    pub fn clear(&mut self) {
        self.items.clear();
        self.end_previous = 0;

        assert_eq!(self.items.count(), 0);
    }

    #[expect(
        clippy::cast_possible_truncation,
        reason = "the source length fits a u32, which each lexer's entry asserts"
    )]
    #[must_use]
    pub fn push(&mut self, source: &[u8], kind: TokenKind, offset: usize, length: usize) -> bool {
        assert!(
            length > 0
                || matches!(
                    kind,
                    TokenKind::BlockEnd | TokenKind::BlockStart | TokenKind::Newline
                )
        );

        assert!(offset + length <= source.len());
        assert!(offset >= self.end_previous as usize);
        debug_assert!(u32::try_from(source.len()).is_ok());

        let end = (offset + length) as u32;

        if !self.items.push(Token {
            kind,
            length: length as u32,
            offset: offset as u32,
        }) {
            return false;
        }

        self.end_previous = end;

        true
    }

    pub(crate) const fn end_previous(&self) -> u32 {
        self.end_previous
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::language::Lexer;
    use crate::lex::{GO, RUST};

    fn built(lexer: &dyn Lexer, source: &[u8]) -> (Vec<Token>, Pairs) {
        let mut tokens = Tokens::reserve(4_096);
        let mut pairs = Pairs::reserve(4_096);

        lexer.lex(source, &mut tokens);
        pairs.build(source, tokens.as_slice());

        (tokens.as_slice().to_vec(), pairs)
    }

    fn token_at(source: &[u8], tokens: &[Token], word: &[u8], count: usize) -> usize {
        let mut seen = 0;

        for (index, token) in tokens.iter().enumerate() {
            if token.text(source) != word {
                continue;
            }

            seen += 1;

            if seen == count {
                return index;
            }
        }

        panic!("the source carries {count} of that word");
    }

    #[test]
    fn a_qualified_path_starts_at_its_root() {
        const SOURCE: &[u8] = b"fn held() {\n    let value = one::two::three(4);\n}\n";

        let (tokens, _pairs) = built(&RUST, SOURCE);
        let leaf = token_at(SOURCE, &tokens, b"three", 1);
        let root = token_at(SOURCE, &tokens, b"one", 1);

        assert_eq!(path_start(&tokens, leaf), root);
    }

    #[test]
    fn a_generic_path_starts_before_its_arguments() {
        const SOURCE: &[u8] = b"fn held() {\n    let value = Vec::<u32>::new();\n}\n";

        let (tokens, _pairs) = built(&RUST, SOURCE);
        let leaf = token_at(SOURCE, &tokens, b"new", 1);
        let root = token_at(SOURCE, &tokens, b"Vec", 1);

        assert_eq!(path_start(&tokens, leaf), root);
    }

    #[test]
    fn an_expression_starts_after_the_assignment_on_its_line() {
        const SOURCE: &[u8] = b"fn held() {\n    let value = first + second;\n}\n";

        let (tokens, _pairs) = built(&RUST, SOURCE);
        let second = token_at(SOURCE, &tokens, b"second", 1);
        let first = token_at(SOURCE, &tokens, b"first", 1);

        assert_eq!(expression_start(&tokens, SOURCE, second), first);
    }

    #[test]
    fn an_expression_with_no_assignment_starts_at_its_line() {
        const SOURCE: &[u8] = b"fn held() {\n    call(first, second);\n}\n";

        let (tokens, _pairs) = built(&RUST, SOURCE);
        let second = token_at(SOURCE, &tokens, b"second", 1);
        let call = token_at(SOURCE, &tokens, b"call", 1);

        assert_eq!(expression_start(&tokens, SOURCE, second), call);
    }

    #[test]
    fn a_modifier_run_opens_where_the_first_word_does() {
        const SOURCE: &[u8] = b"package main\n\nfunc run() {\n\tgo defer call()\n}\n";

        let (tokens, pairs) = built(&GO, SOURCE);
        let call = token_at(SOURCE, &tokens, b"call", 1);
        let first = token_at(SOURCE, &tokens, b"go", 1);

        assert_eq!(modifier_start(&pairs, &tokens, SOURCE, call, 4), first);
    }

    #[test]
    fn a_name_with_no_modifier_opens_at_itself() {
        const SOURCE: &[u8] = b"package main\n\nfunc run() {\n\tcall()\n}\n";

        let (tokens, pairs) = built(&GO, SOURCE);
        let call = token_at(SOURCE, &tokens, b"call", 1);

        assert_eq!(modifier_start(&pairs, &tokens, SOURCE, call, 4), call);
    }

    fn spaced(offsets: &[(u32, u32)]) -> Vec<Token> {
        offsets
            .iter()
            .map(|(offset, length)| Token {
                kind: TokenKind::Identifier,
                length: *length,
                offset: *offset,
            })
            .collect()
    }

    #[test]
    fn an_index_at_an_offset_names_the_token_that_opens_there() {
        let tokens = spaced(&[(0, 2), (3, 0), (3, 4), (8, 1)]);

        assert_eq!(index_at(&tokens, 0), Some(0));
        assert_eq!(index_at(&tokens, 3), Some(2));
        assert_eq!(index_at(&tokens, 8), Some(3));
        assert_eq!(index_at(&tokens, 1), None);
        assert_eq!(index_at(&tokens, 9), None);
        assert_eq!(index_at(&tokens, 2), None);
        assert_eq!(index_at::<Token>(&[], 0), None);
    }

    #[test]
    fn an_index_from_an_offset_is_the_first_token_not_ending_before_it() {
        let tokens = spaced(&[(0, 2), (3, 0), (3, 4), (8, 1)]);

        assert_eq!(index_from(&tokens, 0), 0);
        assert_eq!(index_from(&tokens, 1), 1);
        assert_eq!(index_from(&tokens, 3), 2);
        assert_eq!(index_from(&tokens, 9), 4);
        assert_eq!(index_from::<Token>(&[], 5), 0);
    }

    #[test]
    fn a_touching_index_prefers_the_token_the_offset_ends_or_lands_in() {
        let tokens = spaced(&[(0, 2), (3, 4), (8, 1)]);

        assert_eq!(index_touching(&tokens, 0), Some(0));
        assert_eq!(index_touching(&tokens, 1), Some(0));
        assert_eq!(index_touching(&tokens, 2), Some(0));
        assert_eq!(index_touching(&tokens, 3), Some(1));
        assert_eq!(index_touching(&tokens, 7), Some(1));
        assert_eq!(index_touching(&tokens, 8), Some(2));
        assert_eq!(index_touching(&tokens, 10), None);
        assert_eq!(index_touching::<Token>(&[], 0), None);
    }

    #[test]
    fn the_tokens_in_a_span_are_those_opening_inside_it() {
        let tokens = spaced(&[(0, 2), (3, 4), (8, 1), (10, 2)]);

        assert_eq!(in_span(&tokens, Span::between(3, 9)).len(), 2);
        assert_eq!(in_span(&tokens, Span::between(3, 8)).len(), 1);
        assert_eq!(in_span(&tokens, Span::between(0, 12)).len(), 4);
        assert_eq!(in_span(&tokens, Span::between(1, 3)).len(), 0);
        assert_eq!(in_span(&tokens, Span::between(12, 12)).len(), 0);
        assert_eq!(in_span::<Token>(&[], Span::between(0, 4)).len(), 0);
    }

    #[test]
    fn every_kind_keyword_and_punctuation_has_a_kebab_name() {
        assert_eq!(TokenKind::BlockStart.name(), "block-start");
        assert_eq!(TokenKind::Keyword(Keyword::Assert).name(), "keyword");
        assert_eq!(Keyword::LoopUnbounded.name(), "loop-unbounded");
        assert_eq!(Punctuation::AssignDeclare.name(), "assign-declare");
        assert_eq!(Punctuation::Star.name(), "star");
    }
}
