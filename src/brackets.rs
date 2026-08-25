use crate::bounded::{BoundedVec, count_of};
use crate::token::{self, Punctuation, Token, TokenKind};

pub const DEPTH_MAX: u32 = 256;
pub const NONE: u32 = u32::MAX;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Bracket {
    Brace,
    Paren,
    Square,
}

#[derive(Debug)]
pub struct Pairs {
    depths: BoundedVec<u32>,
    partners: BoundedVec<u32>,
}

#[derive(Clone, Copy, Debug)]
struct Open {
    kind: Bracket,
    position: u32,
}

impl Pairs {
    pub fn reserve(token_count_max: u32) -> Self {
        assert!(token_count_max > 0);

        assert!(!crate::allocation::is_frozen());

        Self {
            depths: BoundedVec::reserve(token_count_max),
            partners: BoundedVec::reserve(token_count_max),
        }
    }

    pub fn build(&mut self, source: &[u8], tokens: &[Token]) {
        assert!(u32::try_from(source.len()).is_ok());
        assert!(tokens.len() <= self.partners.capacity() as usize);

        self.reset_to(tokens.len());

        let mut stack = [Open {
            kind: Bracket::Paren,
            position: 0,
        }; DEPTH_MAX as usize];

        let mut depth = 0_u32;

        for (position, token) in tokens.iter().enumerate() {
            let index = count_of(position);

            let Some((kind, opens)) = classify(source, token) else {
                self.depths[position] = depth;

                continue;
            };

            if opens {
                self.depths[position] = depth;

                if depth < DEPTH_MAX {
                    stack[depth as usize] = Open {
                        kind,
                        position: index,
                    };
                }

                depth += 1;

                continue;
            }

            if depth == 0 {
                self.depths[position] = 0;

                continue;
            }

            depth -= 1;
            self.depths[position] = depth;

            if depth >= DEPTH_MAX {
                continue;
            }

            let open = stack[depth as usize];

            if open.kind != kind {
                continue;
            }

            self.partners[open.position as usize] = index;
            self.partners[position] = open.position;
        }

        assert_eq!(self.partners.count() as usize, tokens.len());
        assert_eq!(self.depths.count() as usize, tokens.len());
    }

    fn reset_to(&mut self, count: usize) {
        self.clear();

        while (self.partners.count() as usize) < count {
            self.depths.push_assert(self.depths.count());
            self.partners.push_assert(NONE);
        }

        for slot in self.depths.iter_mut() {
            *slot = 0;
        }
    }

    pub fn clear(&mut self) {
        self.depths.clear();
        self.partners.clear();

        assert_eq!(self.partners.count(), 0);
    }

    pub fn count(&self) -> u32 {
        self.partners.count()
    }

    pub fn depth_of(&self, token: u32) -> u32 {
        assert!(token < self.count());

        self.depths[token as usize]
    }

    pub fn partner_of(&self, token: u32) -> u32 {
        assert!(token < self.count());

        self.partners[token as usize]
    }

    pub fn open_of(&self, close: usize) -> Option<usize> {
        let partner = self.partner_of(count_of(close));

        if partner == NONE || partner as usize > close {
            return None;
        }

        Some(partner as usize)
    }
}

pub fn block_open(tokens: &[Token], close: usize) -> usize {
    let mut depth = 0_u32;

    for cursor in (0..=close).rev() {
        if tokens[cursor].kind == TokenKind::BlockEnd {
            depth += 1;
        }

        if tokens[cursor].kind == TokenKind::BlockStart {
            depth = depth.saturating_sub(1);

            if depth == 0 {
                return cursor;
            }
        }
    }

    close
}

pub fn angle_open(tokens: &[Token], close: usize) -> usize {
    let mut depth = 0_u32;

    for cursor in (0..=close).rev() {
        if tokens[cursor].is_punctuation(Punctuation::Greater) {
            depth += 1;
        }

        if tokens[cursor].is_punctuation(Punctuation::Less) {
            depth = depth.saturating_sub(1);

            if depth == 0 {
                return cursor;
            }
        }
    }

    close
}

pub fn arguments_of(pairs: &Pairs, tokens: &[Token], start: usize) -> Option<(usize, usize)> {
    let mut open = start;

    while open < tokens.len() {
        if tokens[open].is_punctuation(Punctuation::ParenOpen) {
            break;
        }

        if matches!(
            tokens[open].kind,
            TokenKind::BlockStart | TokenKind::BlockEnd | TokenKind::Newline
        ) {
            return None;
        }

        open += 1;
    }

    if open >= tokens.len() {
        return None;
    }

    let close = pairs.partner_of(count_of(open));

    if close == NONE {
        return None;
    }

    Some((open, close as usize))
}

pub fn argument_end(pairs: &Pairs, tokens: &[Token], start: usize, end: usize) -> usize {
    let base = pairs.depth_of(count_of(start));
    let mut offset = start;

    while offset < end {
        let token = &tokens[offset];
        let nested = pairs.depth_of(count_of(offset));

        if nested <= base && token.is_punctuation(Punctuation::Comma) {
            return offset;
        }

        offset += 1;
    }

    end
}

pub fn argument_around(
    pairs: &Pairs,
    tokens: &[Token],
    open: usize,
    close: usize,
    index: usize,
) -> (usize, usize) {
    assert!(open <= index);
    assert!(index < close);

    let mut first = if tokens[open].is_punctuation(Punctuation::ParenOpen) {
        open + 1
    } else {
        open
    };

    while first < close {
        let last = argument_end(pairs, tokens, first, close);

        if index <= last {
            return (first, last.min(close));
        }

        first = last + 1;
    }

    (open, close)
}

pub fn receiver_start(pairs: &Pairs, tokens: &[Token], source: &[u8], start: usize) -> usize {
    let mut first = start;

    while first > 0 {
        if !tokens[first - 1].is_punctuation(Punctuation::Dot) {
            break;
        }

        let Some(mut cursor) = first.checked_sub(2) else {
            break;
        };

        while is_try(&tokens[cursor], source) {
            let Some(before) = cursor.checked_sub(1) else {
                return first;
            };

            cursor = before;
        }

        if !tokens[cursor].ends_a_value() {
            return first - 1;
        }

        cursor = if tokens[cursor].closes_a_group() {
            token::macro_name(tokens, pairs.open_of(cursor).unwrap_or(cursor))
        } else if tokens[cursor].kind == TokenKind::BlockEnd {
            token::macro_name(tokens, block_open(tokens, cursor))
        } else {
            cursor
        };

        cursor = token::value_start(tokens, cursor);

        if cursor >= first {
            break;
        }

        first = cursor;
    }

    assert!(first <= start);

    first
}

fn is_try(token: &Token, source: &[u8]) -> bool {
    token.length == 1 && source.get(token.offset as usize) == Some(&b'?')
}

pub fn classify(source: &[u8], token: &Token) -> Option<(Bracket, bool)> {
    match token.kind {
        TokenKind::Punctuation(Punctuation::ParenOpen) => Some((Bracket::Paren, true)),
        TokenKind::Punctuation(Punctuation::ParenClose) => Some((Bracket::Paren, false)),
        TokenKind::Punctuation(Punctuation::BracketOpen) => Some((Bracket::Square, true)),
        TokenKind::Punctuation(Punctuation::BracketClose) => Some((Bracket::Square, false)),
        TokenKind::BlockEnd
        | TokenKind::BlockStart
        | TokenKind::Punctuation(Punctuation::Other) => brace_of(source, token),
        TokenKind::Comment
        | TokenKind::Identifier
        | TokenKind::Keyword(_)
        | TokenKind::Newline
        | TokenKind::Number
        | TokenKind::Punctuation(_)
        | TokenKind::String => None,
    }
}

fn brace_of(source: &[u8], token: &Token) -> Option<(Bracket, bool)> {
    if token.length != 1 {
        return None;
    }

    let byte = source.get(token.offset as usize).copied()?;

    match byte {
        b'{' => Some((Bracket::Brace, true)),
        b'}' => Some((Bracket::Brace, false)),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::language::Lexer;
    use crate::lex::{PYTHON, RUST};
    use crate::token::Tokens;

    fn built(lexer: &dyn Lexer, source: &[u8]) -> (Vec<Token>, Pairs) {
        let mut tokens = Tokens::reserve(4_096);
        let mut pairs = Pairs::reserve(4_096);

        lexer.lex(source, &mut tokens);
        pairs.build(source, tokens.as_slice());

        (tokens.as_slice().to_vec(), pairs)
    }

    fn text_at(source: &[u8], token: &Token) -> String {
        String::from_utf8_lossy(token.text(source)).into_owned()
    }

    #[test]
    fn a_partner_is_mutual_and_kind_matched() {
        let source = b"fn f(a: [u8; 4]) -> Vec<u8> { let x = g(h([1, 2])); }\n";
        let (tokens, pairs) = built(&RUST, source);
        let mut matched = 0;

        for (position, token) in tokens.iter().enumerate() {
            let index = count_of(position);
            let partner = pairs.partner_of(index);

            if partner == NONE {
                continue;
            }

            assert_eq!(pairs.partner_of(partner), index);

            assert_eq!(
                classify(source, token).map(|found| found.0),
                classify(source, &tokens[partner as usize]).map(|found| found.0)
            );

            matched += 1;
        }

        assert_eq!(matched, 12);
    }

    #[test]
    fn a_partner_names_the_matching_byte() {
        let source = b"g(h([1, 2]))\n";
        let (tokens, pairs) = built(&PYTHON, source);

        let opener = tokens
            .iter()
            .position(|token| text_at(source, token) == "(")
            .map(count_of)
            .expect("the source opens a paren");

        let partner = pairs.partner_of(opener);

        assert_ne!(partner, NONE);
        assert_eq!(text_at(source, &tokens[partner as usize]), ")");
        assert!(partner > opener);
    }

    #[test]
    fn an_unmatched_bracket_has_no_partner() {
        let source = b"f((a)\n";
        let (tokens, pairs) = built(&PYTHON, source);

        let first = tokens
            .iter()
            .position(|token| text_at(source, token) == "(")
            .map(count_of)
            .expect("the source opens a paren");

        assert_eq!(pairs.partner_of(first), NONE);
    }

    #[test]
    fn a_closer_without_an_opener_has_no_partner() {
        let source = b"a)b\n";
        let (_, pairs) = built(&PYTHON, source);

        for index in 0..pairs.count() {
            assert_eq!(pairs.partner_of(index), NONE);
        }
    }

    #[test]
    fn a_crossed_pair_matches_neither() {
        let source = b"f([a)]\n";
        let (tokens, pairs) = built(&PYTHON, source);

        for (position, token) in tokens.iter().enumerate() {
            if classify(source, token).is_none() {
                continue;
            }

            assert_eq!(pairs.partner_of(count_of(position)), NONE);
        }
    }

    #[test]
    fn a_depth_counts_the_brackets_enclosing_a_token() {
        let source = b"f(a, g(b), [c])\n";
        let (tokens, pairs) = built(&PYTHON, source);
        let mut depths = Vec::new();

        for (position, token) in tokens.iter().enumerate() {
            depths.push((text_at(source, token), pairs.depth_of(count_of(position))));
        }

        let commas: Vec<u32> = depths
            .iter()
            .filter(|(text, _)| text == ",")
            .map(|(_, depth)| *depth)
            .collect();

        assert_eq!(commas, [1, 1]);
    }

    #[test]
    fn a_brace_pairs_through_the_other_punctuation_kind() {
        let source = b"fn f() { if a { b(); } }\n";
        let (tokens, pairs) = built(&RUST, source);

        let opener = tokens
            .iter()
            .position(|token| text_at(source, token) == "{")
            .map(count_of)
            .expect("the source opens a brace");

        let partner = pairs.partner_of(opener);

        assert_ne!(partner, NONE);
        assert_eq!(text_at(source, &tokens[partner as usize]), "}");
    }

    #[test]
    fn nesting_past_the_bound_degrades_rather_than_panicking() {
        let mut source = Vec::new();

        for depth in 0..(DEPTH_MAX + 8) * 2 {
            let byte = if depth < DEPTH_MAX + 8 { b'(' } else { b')' };

            source.push(byte);
        }

        source.push(b'\n');

        let (tokens, pairs) = built(&PYTHON, &source);

        assert_eq!(pairs.count() as usize, tokens.len());

        for index in 0..pairs.count() {
            let partner = pairs.partner_of(index);

            if partner == NONE {
                continue;
            }

            assert_eq!(pairs.partner_of(partner), index);
        }
    }

    #[test]
    fn every_pair_is_properly_nested_on_byte_soup() {
        let mut random = crate::bounded::Random::new(0x9E37_79B9_7F4A_7C15);
        let alphabet = b"()[]{}abc,.;\n ";

        for _ in 0..256 {
            let length = random.below(128) as usize;
            let mut source = Vec::with_capacity(length);

            for _ in 0..length {
                let index = random.below(14) as usize;

                source.push(alphabet[index]);
            }

            let (tokens, pairs) = built(&PYTHON, &source);

            for (position, token) in tokens.iter().enumerate() {
                let index = count_of(position);
                let partner = pairs.partner_of(index);

                if partner == NONE {
                    continue;
                }

                assert_eq!(pairs.partner_of(partner), index);

                assert_eq!(
                    classify(&source, token).map(|found| found.0),
                    classify(&source, &tokens[partner as usize]).map(|found| found.0)
                );

                assert_eq!(
                    classify(&source, token).map(|found| found.1),
                    classify(&source, &tokens[partner as usize]).map(|found| !found.1)
                );
            }
        }
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

    fn last_of(tokens: &[Token], punctuation: Punctuation) -> usize {
        tokens
            .iter()
            .enumerate()
            .filter(|(_, token)| token.is_punctuation(punctuation))
            .map(|(index, _)| index)
            .next_back()
            .expect("the source carries one")
    }

    #[test]
    fn a_generic_argument_list_opens_at_its_own_angle() {
        const SOURCE: &[u8] = b"fn held(value: Map<Key<u32>, Value>) {\n}\n";

        let (tokens, _pairs) = built(&RUST, SOURCE);
        let close = last_of(&tokens, Punctuation::Greater);
        let open = angle_open(&tokens, close);

        assert!(tokens[open].is_punctuation(Punctuation::Less), "{open}");
        assert_eq!(open, token_at(SOURCE, &tokens, b"<", 1));
    }

    #[test]
    fn an_unopened_angle_returns_where_it_started() {
        const SOURCE: &[u8] = b"fn held(value: u32) {\n    let _ = 1 > 0;\n}\n";

        let (tokens, _pairs) = built(&RUST, SOURCE);
        let close = token_at(SOURCE, &tokens, b">", 1);

        assert_eq!(angle_open(&tokens, close), close);
    }

    #[test]
    fn an_argument_walk_finds_the_one_the_index_sits_in() {
        const SOURCE: &[u8] = b"fn held() {\n    call(first, second(inner, deep), third);\n}\n";

        let (tokens, pairs) = built(&RUST, SOURCE);
        let open = token_at(SOURCE, &tokens, b"(", 2);
        let close = last_of(&tokens, Punctuation::ParenClose);
        let deep = token_at(SOURCE, &tokens, b"deep", 1);
        let (first, last) = argument_around(&pairs, &tokens, open, close, deep);

        assert_eq!(tokens[first].text(SOURCE), b"second");
        assert_eq!(tokens[last].text(SOURCE), b",");
    }

    #[test]
    fn the_first_argument_is_the_one_after_the_parenthesis() {
        const SOURCE: &[u8] = b"fn held() {\n    call(first, second);\n}\n";

        let (tokens, pairs) = built(&RUST, SOURCE);
        let open = token_at(SOURCE, &tokens, b"(", 2);
        let close = last_of(&tokens, Punctuation::ParenClose);
        let held = token_at(SOURCE, &tokens, b"first", 1);
        let (first, _last) = argument_around(&pairs, &tokens, open, close, held);

        assert_eq!(tokens[first].text(SOURCE), b"first");
    }

    #[test]
    fn an_argument_ends_at_the_comma_of_its_own_depth() {
        const SOURCE: &[u8] = b"fn held() {\n    call(first(a, b), second);\n}\n";

        let (tokens, pairs) = built(&RUST, SOURCE);
        let start = token_at(SOURCE, &tokens, b"first", 1);
        let close = last_of(&tokens, Punctuation::ParenClose);
        let end = argument_end(&pairs, &tokens, start, close);

        assert!(tokens[end].is_punctuation(Punctuation::Comma));
        assert_eq!(tokens[end + 1].text(SOURCE), b"second");
    }

    #[test]
    fn an_argument_with_no_comma_ends_where_the_walk_does() {
        const SOURCE: &[u8] = b"fn held() {\n    call(only);\n}\n";

        let (tokens, pairs) = built(&RUST, SOURCE);
        let start = token_at(SOURCE, &tokens, b"only", 1);

        assert_eq!(argument_end(&pairs, &tokens, start, start + 1), start + 1);
    }
}
