#[path = "common/corpus.rs"]
mod corpus;
#[path = "common/floor.rs"]
mod floor;

use std::fs;
use std::path::PathBuf;

use scylla::bounded::{BoundedVec, Buffer, Span};
use scylla::format::brace::renumbered;
use scylla::format::print::Options;
use scylla::format::typescript::{Formatter, Input, Outcome};
use scylla::language::Lexer as _;
use scylla::lex::TYPESCRIPT;
use scylla::syntax::typescript::classify::classify;
use scylla::syntax::typescript::dialect::Dialect;
use scylla::syntax::typescript::kind::TypeScriptKind;
use scylla::syntax::typescript::parse;
use scylla::token::{Token, TokenKind, Tokens};
use scylla::tree::{Events, Tree};

const ELEMENT_COUNT_MAX: u32 = 1 << 18;
const ERROR_COUNT_MAX: u32 = 1 << 12;
const EVENT_COUNT_MAX: u32 = 1 << 20;
const NODE_COUNT_MAX: u32 = 1 << 18;
const NUMBER_BYTES_MAX: u32 = 1 << 8;
const OUT_BYTES_MAX: u32 = 1 << 22;
const TOKEN_COUNT_MAX: u32 = 1 << 18;

struct Held {
    dialect: Dialect,
    events: Events<TypeScriptKind>,
    formatter: Formatter,
    lexed: Tokens,
    raw: BoundedVec<TypeScriptKind>,
    tokens: Tokens,
    tree: Tree<TypeScriptKind>,
}

impl Held {
    fn reserve() -> Self {
        Self {
            dialect: Dialect::Ts,
            events: Events::reserve(EVENT_COUNT_MAX),
            formatter: Formatter::reserve(ELEMENT_COUNT_MAX, OUT_BYTES_MAX),
            lexed: Tokens::reserve(TOKEN_COUNT_MAX),
            raw: BoundedVec::reserve(TOKEN_COUNT_MAX),
            tokens: Tokens::reserve(TOKEN_COUNT_MAX),
            tree: Tree::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX),
        }
    }

    fn format(&mut self, source: &[u8], out: &mut Buffer) -> Outcome {
        self.lexed.clear();
        self.raw.clear();
        self.tokens.clear();

        TYPESCRIPT.lex(source, &mut self.lexed);

        if !classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw,
            self.dialect,
        ) {
            return Outcome::Overflow;
        }

        let outcome = parse::build(
            source,
            self.tokens.as_slice(),
            &self.raw,
            &mut self.events,
            &mut self.tree,
            self.dialect,
        );

        let input = Input {
            options: Options::DEFAULT,
            outcome,
            raw: &self.raw,
            source,
            tokens: self.tokens.as_slice(),
            tree: &self.tree,
        };

        self.formatter.format(&input, out)
    }

    fn range(&mut self, source: &[u8], lines: (u32, u32), out: &mut Buffer) -> Option<Span> {
        self.lexed.clear();
        self.raw.clear();
        self.tokens.clear();

        TYPESCRIPT.lex(source, &mut self.lexed);

        if !classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw,
            self.dialect,
        ) {
            return None;
        }

        let outcome = parse::build(
            source,
            self.tokens.as_slice(),
            &self.raw,
            &mut self.events,
            &mut self.tree,
            self.dialect,
        );

        let input = Input {
            options: Options::DEFAULT,
            outcome,
            raw: &self.raw,
            source,
            tokens: self.tokens.as_slice(),
            tree: &self.tree,
        };

        self.formatter.range(&input, lines, out)
    }

    fn words(&mut self, source: &[u8]) -> Vec<String> {
        self.lexed.clear();
        TYPESCRIPT.lex(source, &mut self.lexed);

        let held = self
            .lexed
            .as_slice()
            .iter()
            .filter(|token| {
                !matches!(
                    token.kind,
                    TokenKind::BlockEnd | TokenKind::BlockStart | TokenKind::Newline
                ) && token.length > 0
            })
            .copied()
            .collect::<Vec<Token>>();

        let mut written = Vec::with_capacity(held.len());

        for (index, token) in held.iter().enumerate() {
            if token.kind == TokenKind::Number {
                let mut form = Buffer::reserve(NUMBER_BYTES_MAX);

                assert!(renumbered(&mut form, token.text(source)));
                written.push(String::from_utf8_lossy(form.as_bytes()).into_owned());

                continue;
            }

            if token.kind != TokenKind::String {
                written.push(String::from_utf8_lossy(token.text(source)).into_owned());

                continue;
            }

            let next = held.get(index + 1).map(|after| after.text(source));

            let keyed = next == Some(b":".as_slice())
                || next == Some(b"?".as_slice())
                    && held.get(index + 2).map(|after| after.text(source)) == Some(b":".as_slice());

            match named_key(token.text(source)).filter(|_| keyed) {
                Some(body) => written.push(String::from_utf8_lossy(body).into_owned()),
                None => written.push("<string>".to_owned()),
            }
        }

        written
    }

    fn kinds(&mut self, source: &[u8]) -> Vec<TypeScriptKind> {
        self.lexed.clear();
        self.raw.clear();
        self.tokens.clear();

        TYPESCRIPT.lex(source, &mut self.lexed);

        assert!(classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw,
            self.dialect
        ));

        let mut held = Vec::with_capacity(self.raw.len());

        for (index, kind) in self.raw.iter().copied().enumerate() {
            if matches!(kind.name(), "Dedent" | "Indent" | "Newline") {
                continue;
            }

            held.push((kind, self.tokens.as_slice()[index]));
        }

        keyed(source, &held)
    }

    fn comments(&mut self, source: &[u8]) -> Vec<Vec<u8>> {
        self.lexed.clear();
        self.raw.clear();
        self.tokens.clear();

        TYPESCRIPT.lex(source, &mut self.lexed);

        assert!(classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw,
            self.dialect
        ));

        self.raw
            .iter()
            .enumerate()
            .filter(|(_, kind)| **kind == TypeScriptKind::Comment)
            .map(|(index, _)| {
                source[self.tokens.as_slice()[index].span().range()]
                    .trim_ascii_end()
                    .to_vec()
            })
            .collect()
    }
}

fn fixtures() -> Vec<(String, Vec<u8>)> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/typescript");
    let mut found = Vec::new();

    for entry in fs::read_dir(&root).expect("the fixture directory is readable") {
        let path = entry.expect("the entry is readable").path();

        let held = path
            .extension()
            .and_then(|extension| extension.to_str())
            .and_then(Dialect::of_extension);

        if held.is_none() {
            continue;
        }

        let name = path
            .file_name()
            .expect("the fixture has a name")
            .to_string_lossy()
            .into_owned();

        let source = fs::read(&path).expect("the fixture is readable");

        found.push((name, source));
    }

    found.sort_by(|left, right| left.0.cmp(&right.0));

    assert!(found.len() > 4);

    found
}

#[test]
fn formatting_formatted_output_changes_nothing() {
    let mut first = Buffer::reserve(OUT_BYTES_MAX);
    let mut held = Held::reserve();
    let mut second = Buffer::reserve(OUT_BYTES_MAX);

    for (name, source) in fixtures() {
        held.dialect = dialect_of(&name);

        if held.format(&source, &mut first) != Outcome::Complete {
            continue;
        }

        let once = first.as_bytes().to_vec();

        assert_eq!(held.format(&once, &mut second), Outcome::Complete, "{name}");

        assert_eq!(
            String::from_utf8_lossy(second.as_bytes()),
            String::from_utf8_lossy(&once),
            "{name} is not idempotent"
        );
    }
}

fn leaned(kind: TypeScriptKind, depth: u32) -> u32 {
    match kind {
        TypeScriptKind::ParenOpen => depth + 1,
        TypeScriptKind::ParenClose => depth.saturating_sub(1),
        _ => depth,
    }
}

fn wrapped(kinds: &[TypeScriptKind]) -> Vec<TypeScriptKind> {
    let pairs = partners(
        kinds,
        &TypeScriptKind::ParenOpen,
        &TypeScriptKind::ParenClose,
    );
    let mut found: Vec<TypeScriptKind> = Vec::with_capacity(kinds.len());
    let mut skips: Vec<usize> = Vec::new();
    let mut index = 0;

    while index < kinds.len() {
        let wraps = matches!(
            kinds[index],
            TypeScriptKind::ReturnKeyword | TypeScriptKind::ThrowKeyword
        ) && kinds.get(index + 1) == Some(&TypeScriptKind::ParenOpen)
            && pairs[index + 1] > index + 1
            && kinds.get(pairs[index + 1] + 1).is_none_or(|held| {
                matches!(
                    *held,
                    TypeScriptKind::Semicolon | TypeScriptKind::BraceClose
                )
            });

        if wraps {
            found.push(kinds[index]);
            skips.push(pairs[index + 1]);
            index += 2;

            continue;
        }

        if skips.last() == Some(&index) {
            skips.pop();
            index += 1;

            continue;
        }

        found.push(kinds[index]);
        index += 1;
    }

    found
}

fn opened(words: &[String]) -> Vec<String> {
    let open = "(".to_owned();
    let close = ")".to_owned();
    let pairs = partners(words, &open, &close);
    let mut found: Vec<String> = Vec::with_capacity(words.len());
    let mut skips: Vec<usize> = Vec::new();
    let mut index = 0;

    while index < words.len() {
        let wraps = matches!(words[index].as_str(), "return" | "throw")
            && words.get(index + 1) == Some(&open)
            && pairs[index + 1] > index + 1
            && words
                .get(pairs[index + 1] + 1)
                .is_none_or(|held| matches!(held.as_str(), ";" | "}"));

        if wraps {
            found.push(words[index].clone());
            skips.push(pairs[index + 1]);
            index += 2;

            continue;
        }

        if skips.last() == Some(&index) {
            skips.pop();
            index += 1;

            continue;
        }

        found.push(words[index].clone());
        index += 1;
    }

    found
}

fn window<K>(held: &[K], at: usize) -> String
where
    K: core::fmt::Debug,
{
    let from = at.saturating_sub(10);
    let to = held.len().min(at + 10);

    held[from..to]
        .iter()
        .map(|kind| format!("{kind:?}"))
        .collect::<Vec<String>>()
        .join(" ")
}

fn partners<T>(held: &[T], open: &T, close: &T) -> Vec<usize>
where
    T: PartialEq,
{
    let mut found: Vec<usize> = (0..held.len()).collect();
    let mut stack: Vec<usize> = Vec::new();

    for (at, item) in held.iter().enumerate() {
        if item == open {
            stack.push(at);

            continue;
        }

        if item != close {
            continue;
        }

        if let Some(from) = stack.pop() {
            found[from] = at;
            found[at] = from;
        }
    }

    found
}

fn weights<T>(held: &[T], bare: &[&T]) -> Vec<u32>
where
    T: PartialEq,
{
    let mut found = Vec::with_capacity(held.len() + 1);
    let mut count = 0;

    found.push(0);

    for item in held {
        if !bare.contains(&item) {
            count += 1;
        }

        found.push(count);
    }

    found
}

fn inside(pairs: &[usize], held: &[u32], at: usize) -> u32 {
    let stop = pairs[at];

    if stop <= at {
        return 0;
    }

    held[stop] - held[at + 1]
}

fn terminated(source: &[TypeScriptKind], printed: &[TypeScriptKind]) -> bool {
    divergence(source, printed).is_none()
}

fn divergence(source: &[TypeScriptKind], printed: &[TypeScriptKind]) -> Option<(usize, usize)> {
    let bare = [
        &TypeScriptKind::ParenOpen,
        &TypeScriptKind::ParenClose,
        &TypeScriptKind::Semicolon,
    ];
    let carried = partners(
        source,
        &TypeScriptKind::ParenOpen,
        &TypeScriptKind::ParenClose,
    );
    let written = partners(
        printed,
        &TypeScriptKind::ParenOpen,
        &TypeScriptKind::ParenClose,
    );
    let spans = weights(source, &bare);
    let widths = weights(printed, &bare);
    let mut depth = 0;
    let mut dropped: Vec<u32> = Vec::new();
    let mut held = 0;

    for (at, kind) in printed.iter().enumerate() {
        while let Some(item) = source.get(held) {
            let paired = *kind == TypeScriptKind::ParenOpen
                && inside(&carried, &spans, held) == inside(&written, &widths, at);

            let closes = *item == TypeScriptKind::ParenClose
                && dropped.last().is_some_and(|from| from + 1 == depth);

            let opens =
                *item == TypeScriptKind::ParenOpen && *kind != TypeScriptKind::Semicolon && !paired;

            if !closes && !opens {
                break;
            }

            if closes {
                dropped.pop();
            } else {
                dropped.push(depth);
            }

            depth = leaned(*item, depth);
            held += 1;
        }

        if source.get(held) == Some(kind) {
            depth = leaned(*kind, depth);
            held += 1;

            continue;
        }

        if *kind == TypeScriptKind::Semicolon {
            continue;
        }

        return Some((held, at));
    }

    while source.get(held) == Some(&TypeScriptKind::ParenClose) && !dropped.is_empty() {
        dropped.pop();
        held += 1;
    }

    (held != source.len()).then_some((held, printed.len()))
}

fn leant(word: &str, depth: u32) -> u32 {
    match word {
        "(" => depth + 1,
        ")" => depth.saturating_sub(1),
        _ => depth,
    }
}

fn ended(source: &[String], printed: &[String]) -> bool {
    let close = ")".to_owned();
    let open = "(".to_owned();
    let semicolon = ";".to_owned();
    let bare = [&open, &close, &semicolon];
    let carried = partners(source, &open, &close);
    let written = partners(printed, &open, &close);
    let spans = weights(source, &bare);
    let widths = weights(printed, &bare);
    let mut depth = 0;
    let mut dropped: Vec<u32> = Vec::new();
    let mut held = 0;

    for (at, word) in printed.iter().enumerate() {
        while let Some(item) = source.get(held) {
            let paired =
                *word == open && inside(&carried, &spans, held) == inside(&written, &widths, at);

            let closes = *item == close && dropped.last().is_some_and(|from| from + 1 == depth);
            let opens = *item == open && *word != semicolon && !paired;

            if !closes && !opens {
                break;
            }

            if closes {
                dropped.pop();
            } else {
                dropped.push(depth);
            }

            depth = leant(item.as_str(), depth);
            held += 1;
        }

        if source.get(held) == Some(word) {
            depth = leant(word.as_str(), depth);
            held += 1;

            continue;
        }

        if *word == semicolon {
            continue;
        }

        return false;
    }

    while source.get(held) == Some(&close) && !dropped.is_empty() {
        dropped.pop();
        held += 1;
    }

    held == source.len()
}

fn unioned(kinds: &[TypeScriptKind]) -> Vec<TypeScriptKind> {
    kinds
        .iter()
        .enumerate()
        .filter(|(index, held)| {
            **held != TypeScriptKind::Bar
                || !matches!(
                    index.checked_sub(1).and_then(|before| kinds.get(before)),
                    Some(TypeScriptKind::Colon | TypeScriptKind::Equal)
                )
        })
        .map(|(_, held)| *held)
        .collect()
}

fn listed(kinds: &[TypeScriptKind]) -> Vec<TypeScriptKind> {
    kinds
        .iter()
        .enumerate()
        .filter(|(index, held)| {
            !matches!(**held, TypeScriptKind::Comma | TypeScriptKind::Semicolon)
                || !closing(kinds, index + 1)
        })
        .map(|(_, held)| match held {
            TypeScriptKind::Comma => TypeScriptKind::Semicolon,
            _ => *held,
        })
        .collect()
}

fn closing(kinds: &[TypeScriptKind], from: usize) -> bool {
    let mut at = from;

    while kinds.get(at) == Some(&TypeScriptKind::Comment) {
        at += 1;
    }

    matches!(
        kinds.get(at),
        Some(
            TypeScriptKind::BraceClose | TypeScriptKind::BracketClose | TypeScriptKind::ParenClose
        )
    )
}

fn separated(words: &[String]) -> Vec<String> {
    words
        .iter()
        .enumerate()
        .filter(|(index, held)| !matches!(held.as_str(), "," | ";") || !closes(words, index + 1))
        .map(|(_, held)| match held.as_str() {
            "," => ";".to_owned(),
            _ => held.clone(),
        })
        .collect()
}

fn closes(words: &[String], from: usize) -> bool {
    let mut at = from;

    while words
        .get(at)
        .is_some_and(|word| word.starts_with("//") || word.starts_with("/*"))
    {
        at += 1;
    }

    matches!(words.get(at).map(String::as_str), Some(")" | "]" | "}"))
}

fn constructed(kinds: &[TypeScriptKind]) -> Vec<TypeScriptKind> {
    let mut depth = 0_usize;
    let mut held: Vec<TypeScriptKind> = Vec::with_capacity(kinds.len());
    let mut skips: Vec<usize> = Vec::new();

    for (index, kind) in kinds.iter().enumerate() {
        if *kind == TypeScriptKind::ParenOpen {
            let opens = index > 0
                && kinds[index - 1] == TypeScriptKind::NewKeyword
                && kinds.get(index + 1) == Some(&TypeScriptKind::ClassKeyword);

            depth += 1;

            if opens {
                skips.push(depth);

                continue;
            }
        } else if *kind == TypeScriptKind::ParenClose {
            let closes = skips.last() == Some(&depth);

            depth -= 1;

            if closes {
                skips.pop();

                continue;
            }
        }

        held.push(*kind);
    }

    let mut found: Vec<TypeScriptKind> = Vec::with_capacity(held.len());
    let mut scan = 0;

    while scan < held.len() {
        let called = held[scan] == TypeScriptKind::BraceClose
            && held.get(scan + 1) == Some(&TypeScriptKind::ParenOpen)
            && held.get(scan + 2) == Some(&TypeScriptKind::ParenClose);

        found.push(held[scan]);
        scan += 1 + if called { 2 } else { 0 };
    }

    found
}

fn called(kinds: &[TypeScriptKind]) -> Vec<TypeScriptKind> {
    let mut depth = 0_u32;
    let mut held = Vec::with_capacity(kinds.len());
    let mut owed: Vec<u32> = Vec::new();

    for (index, kind) in kinds.iter().enumerate() {
        if *kind == TypeScriptKind::ParenOpen {
            depth += 1;

            let next = kinds.get(index + 1);

            let functions = next == Some(&TypeScriptKind::FunctionKeyword)
                || next == Some(&TypeScriptKind::AsyncKeyword)
                    && kinds.get(index + 2) == Some(&TypeScriptKind::FunctionKeyword);

            if functions {
                owed.push(depth);

                continue;
            }
        }

        if *kind == TypeScriptKind::ParenClose {
            let dropped = owed.last() == Some(&depth);

            depth = depth.saturating_sub(1);

            if dropped {
                owed.pop();

                continue;
            }
        }

        held.push(*kind);
    }

    held
}

fn parenthesised(kinds: &[TypeScriptKind]) -> Vec<TypeScriptKind> {
    let mut held = Vec::with_capacity(kinds.len());
    let mut index = 0;

    while index < kinds.len() {
        let lone = kinds[index] == TypeScriptKind::ParenOpen
            && kinds.get(index + 1) == Some(&TypeScriptKind::Identifier)
            && kinds.get(index + 2) == Some(&TypeScriptKind::ParenClose)
            && kinds.get(index + 3) == Some(&TypeScriptKind::Arrow);

        if lone {
            held.push(TypeScriptKind::Identifier);
            index += 3;

            continue;
        }

        held.push(kinds[index]);
        index += 1;
    }

    held
}

fn bracketed(words: &[String]) -> Vec<String> {
    let mut held = Vec::with_capacity(words.len());
    let mut index = 0;

    while index < words.len() {
        let lone = words[index] == "("
            && words.get(index + 2).map(String::as_str) == Some(")")
            && words.get(index + 3).map(String::as_str) == Some("=>");

        if lone {
            held.push(words[index + 1].clone());
            index += 3;

            continue;
        }

        held.push(words[index].clone());
        index += 1;
    }

    held
}

fn trimmed(comments: &[Vec<u8>]) -> String {
    comments
        .iter()
        .map(|held| {
            String::from_utf8_lossy(held)
                .lines()
                .map(str::trim)
                .collect::<Vec<&str>>()
                .join("\n")
        })
        .collect::<Vec<String>>()
        .concat()
}

fn bare_key(text: &[u8]) -> Option<&[u8]> {
    named_key(text).or_else(|| bare_name(text))
}

fn bare_name(text: &[u8]) -> Option<&[u8]> {
    let first = *text.first()?;

    if !first.is_ascii_alphabetic() && first != b'_' && first != b'$' {
        return None;
    }

    text.iter()
        .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'_' || *byte == b'$')
        .then_some(text)
}

fn named_key(text: &[u8]) -> Option<&[u8]> {
    let quote = *text.first()?;

    if quote != b'"' && quote != b'\'' || text.len() < 2 || *text.last()? != quote {
        return None;
    }

    let body = &text[1..text.len() - 1];
    let first = *body.first()?;

    if !first.is_ascii_alphabetic() && first != b'_' && first != b'$' {
        return None;
    }

    body.iter()
        .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'_' || *byte == b'$')
        .then_some(body)
}

fn colons(held: &[(TypeScriptKind, Token)]) -> Vec<bool> {
    let mut found = vec![false; held.len()];
    let mut owed: Vec<u32> = vec![0];

    for (at, (kind, _)) in held.iter().enumerate() {
        match *kind {
            TypeScriptKind::BraceOpen | TypeScriptKind::BracketOpen | TypeScriptKind::ParenOpen => {
                owed.push(0);
            }
            TypeScriptKind::BraceClose
            | TypeScriptKind::BracketClose
            | TypeScriptKind::ParenClose => {
                if owed.len() > 1 {
                    owed.pop();
                }
            }
            TypeScriptKind::Comma | TypeScriptKind::Semicolon => {
                if let Some(frame) = owed.last_mut() {
                    *frame = 0;
                }
            }
            TypeScriptKind::CaseKeyword => {
                let labelled =
                    held.get(at + 1).map(|(carried, _)| *carried) != Some(TypeScriptKind::Colon);

                if let Some(frame) = owed.last_mut().filter(|_| labelled) {
                    *frame += 1;
                }
            }
            TypeScriptKind::Question => {
                let optional =
                    held.get(at + 1).map(|(carried, _)| *carried) == Some(TypeScriptKind::Colon);

                if let Some(frame) = owed.last_mut().filter(|_| !optional) {
                    *frame += 1;
                }
            }
            TypeScriptKind::Colon => {
                if let Some(frame) = owed.last_mut().filter(|frame| **frame > 0) {
                    *frame -= 1;
                    found[at] = true;
                }
            }
            _ => (),
        }
    }

    found
}

fn keyed(source: &[u8], held: &[(TypeScriptKind, Token)]) -> Vec<TypeScriptKind> {
    let asked = colons(held);

    held.iter()
        .enumerate()
        .map(|(index, (kind, token))| {
            let next = held.get(index + 1).map(|(carried, _)| *carried);

            let at = if next == Some(TypeScriptKind::Colon) {
                index + 1
            } else if next == Some(TypeScriptKind::Question)
                && held.get(index + 2).map(|(carried, _)| *carried) == Some(TypeScriptKind::Colon)
            {
                index + 2
            } else {
                return *kind;
            };

            if asked[at] || bare_key(token.text(source)).is_none() {
                return *kind;
            }

            TypeScriptKind::Identifier
        })
        .collect()
}

#[test]
fn formatting_keeps_every_token_it_was_given() {
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    for (name, source) in fixtures() {
        held.dialect = dialect_of(&name);

        if held.format(&source, &mut out) != Outcome::Complete {
            continue;
        }

        let formatted = out.as_bytes().to_vec();
        let before = wrapped(&called(&parenthesised(&listed(&held.kinds(&source)))));
        let after = wrapped(&called(&parenthesised(&listed(&held.kinds(&formatted)))));

        assert!(terminated(&before, &after), "{name} lost or gained a token");
    }
}

#[test]
fn formatting_keeps_every_comment_it_was_given() {
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    for (name, source) in fixtures() {
        held.dialect = dialect_of(&name);

        if held.format(&source, &mut out) != Outcome::Complete {
            continue;
        }

        let formatted = out.as_bytes().to_vec();

        assert_eq!(
            trimmed(&held.comments(&source)),
            trimmed(&held.comments(&formatted)),
            "{name} lost a comment"
        );
    }
}

#[test]
fn a_dump_writes_the_formatted_fixtures() {
    let Ok(root) = std::env::var("SCYLLA_FORMAT_DUMP") else {
        return;
    };

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    for (name, source) in fixtures() {
        held.dialect = dialect_of(&name);

        if held.format(&source, &mut out) != Outcome::Complete {
            continue;
        }

        fs::write(PathBuf::from(&root).join(name), out.as_bytes())
            .expect("the dump directory is writable");
    }
}

#[path = "common/oracle.rs"]
mod oracle;

const EVERY_CATEGORY: [&str; 4] = [
    "biome-jsx-layout",
    "biome-line-breaking",
    "biome-literal-normalisation",
    "biome-template-literals",
];

#[test]
fn every_tsx_fixture_is_formatted_or_refused_by_its_own_row() {
    let carried = oracle::residue_of("residue-format-typescript.json", &EVERY_CATEGORY);
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);
    let mut walked = 0;

    for (name, source) in fixtures() {
        held.dialect = dialect_of(&name);

        if !held.dialect.is_tsx() {
            continue;
        }

        walked += 1;

        let outcome = held.format(&source, &mut out);

        if outcome == Outcome::Complete {
            continue;
        }

        assert_eq!(outcome, Outcome::Refusal, "{name}");

        assert!(
            carried.contains(&name),
            "{name} is refused and no residue row names it"
        );
    }

    assert_eq!(walked, 6, "the tsx fixtures are not walked");
}

#[test]
fn the_formatted_output_matches_the_oracle_modulo_residue() {
    let carried = oracle::residue_of("residue-format-typescript.json", &EVERY_CATEGORY);
    let root =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-biome-typescript");
    let mut compared = 0;
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    for (name, source) in fixtures() {
        held.dialect = dialect_of(&name);

        if carried.contains(&name) {
            continue;
        }

        assert_eq!(
            held.format(&source, &mut out),
            Outcome::Complete,
            "{name} is refused and no residue row names it"
        );

        let golden = fs::read(root.join(&name)).expect("the golden is dumped");

        assert_eq!(
            String::from_utf8_lossy(out.as_bytes()),
            String::from_utf8_lossy(&golden),
            "{name} diverges from biome and no residue row names it"
        );

        compared += 1;
    }

    assert!(
        compared >= floor::FIXTURE_FORMAT_TYPESCRIPT,
        "the TypeScript fixtures lost a formatting: {compared} compared, floor {}",
        floor::FIXTURE_FORMAT_TYPESCRIPT
    );
}

#[test]
fn every_residue_row_names_a_fixture_that_diverges() {
    let carried = oracle::residue_of("residue-format-typescript.json", &EVERY_CATEGORY);
    let root =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-biome-typescript");
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    for name in &carried {
        let source = fs::read(
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("tests/fixtures/typescript")
                .join(name),
        )
        .expect("the residue row names a fixture");

        held.dialect = dialect_of(name);

        if held.format(&source, &mut out) != Outcome::Complete {
            continue;
        }

        let golden = fs::read(root.join(name)).expect("the golden is dumped");

        assert_ne!(
            out.as_bytes(),
            golden.as_slice(),
            "{name} matches biome and needs no residue row"
        );
    }
}

#[test]
fn a_file_that_does_not_parse_is_refused() {
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(b"function f( {\n", &mut out), Outcome::Refusal);
    assert!(out.is_empty());
}

#[test]
fn a_property_key_drops_the_quotes_it_does_not_need() {
    let cases: [(&[u8], &str); 8] = [
        (b"const o = { \"a\": 1 };\n", "const o = { a: 1 };\n"),
        (
            b"const o = { \"a-b\": 1 };\n",
            "const o = { \"a-b\": 1 };\n",
        ),
        (b"const o = { \"0\": 1 };\n", "const o = { \"0\": 1 };\n"),
        (
            b"const o = { \"new\": 1 };\n",
            "const o = { \"new\": 1 };\n",
        ),
        (
            b"const o = { \"default\": 1 };\n",
            "const o = { default: 1 };\n",
        ),
        (b"const o = { \"$_a9\": 1 };\n", "const o = { $_a9: 1 };\n"),
        (
            b"type T = { \"a\"?: string };\n",
            "type T = { a?: string };\n",
        ),
        (
            b"const o = held ? \"a\" : \"b\";\n",
            "const o = held ? \"a\" : \"b\";\n",
        ),
    ];

    let mut held = Held::reserve();

    for (source, wanted) in cases {
        let mut out = Buffer::reserve(OUT_BYTES_MAX);

        assert_eq!(held.format(source, &mut out), Outcome::Complete);
        assert_eq!(String::from_utf8_lossy(out.as_bytes()), wanted);
    }
}

#[test]
fn a_number_takes_the_form_biome_writes() {
    let cases: [(&[u8], &str); 12] = [
        (b"a = 0.90;\n", "a = 0.9;\n"),
        (b"a = 1.0;\n", "a = 1.0;\n"),
        (b"a = 1.00;\n", "a = 1.0;\n"),
        (b"a = .5;\n", "a = 0.5;\n"),
        (b"a = 5.;\n", "a = 5;\n"),
        (b"a = 0XABCDEF;\n", "a = 0xabcdef;\n"),
        (b"a = 1E+05;\n", "a = 1e5;\n"),
        (b"a = 1e-5;\n", "a = 1e-5;\n"),
        (b"a = 0.1e0;\n", "a = 0.1;\n"),
        (b"a = 1_000_000;\n", "a = 1_000_000;\n"),
        (b"a = 0XFFn;\n", "a = 0xffn;\n"),
        (b"a = 1..toString();\n", "a = 1..toString();\n"),
    ];

    let mut held = Held::reserve();

    for (source, wanted) in cases {
        let mut out = Buffer::reserve(OUT_BYTES_MAX);

        assert_eq!(held.format(source, &mut out), Outcome::Complete);
        assert_eq!(String::from_utf8_lossy(out.as_bytes()), wanted);
    }
}

#[test]
fn a_call_hugs_the_bracket_its_last_argument_opens() {
    let hugged: &[u8] = b"vscode.Uri.from({ scheme: \"copilotcli\", path: \"/untitled-temp-steering-resource-held\" });\n";

    let wanted = "vscode.Uri.from({\n    scheme: \"copilotcli\",\n    path: \
                  \"/untitled-temp-steering-resource-held\",\n});\n";

    let parted: &[u8] = b"assert.deepStrictEqual({ status: resultOfTheRun.status }, { status: expectedRun.status });\n";

    let owed = "assert.deepStrictEqual(\n    { status: resultOfTheRun.status },\n    { status: \
                expectedRun.status },\n);\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(hugged, &mut out), Outcome::Complete);
    assert_eq!(String::from_utf8_lossy(out.as_bytes()), wanted);

    assert_eq!(held.format(parted, &mut out), Outcome::Complete);
    assert_eq!(String::from_utf8_lossy(out.as_bytes()), owed);
}

#[test]
fn a_property_writes_its_value_under_a_key_wide_enough_to_pay_for_it() {
    let broken: &[u8] = b"const o = {\n    layerbreaker: \"Bad layering. You are not allowed to access this from over here, allowed\",\n};\n";

    let wanted = "const o = {\n    layerbreaker:\n        \"Bad layering. You are not allowed to \
                  access this from over here, allowed\",\n};\n";

    let slight: &[u8] = b"const o = {\n    amdX: \"Bad layering. You are not allowed to access this from over here, allowed thing\",\n};\n";
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(broken, &mut out), Outcome::Complete);
    assert_eq!(String::from_utf8_lossy(out.as_bytes()), wanted);

    assert_eq!(held.format(slight, &mut out), Outcome::Complete);

    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(slight)
    );
}

#[test]
fn a_body_parts_from_the_brace_that_holds_it() {
    let cases: [(&[u8], &str); 9] = [
        (b"if (x) { y(); }\n", "if (x) {\n    y();\n}\n"),
        (b"class C { m() {} }\n", "class C {\n    m() {}\n}\n"),
        (b"const o = { a: 1 };\n", "const o = { a: 1 };\n"),
        (
            b"type F = (a: string) => { b: 1 };\n",
            "type F = (a: string) => { b: 1 };\n",
        ),
        (
            b"type U = \"a\" | { t: { x: 1 } };\n",
            "type U = \"a\" | { t: { x: 1 } };\n",
        ),
        (
            b"function f(): T { return 1; }\n",
            "function f(): T {\n    return 1;\n}\n",
        ),
        (
            b"interface I { a: string; b: number }\n",
            "interface I {\n    a: string;\n    b: number;\n}\n",
        ),
        (b"enum E { A, B }\n", "enum E {\n    A,\n    B,\n}\n"),
        (
            b"function g() { a(); b(); }\n",
            "function g() {\n    a();\n    b();\n}\n",
        ),
    ];

    let mut held = Held::reserve();

    for (source, wanted) in cases {
        let mut out = Buffer::reserve(OUT_BYTES_MAX);

        assert_eq!(held.format(source, &mut out), Outcome::Complete);
        assert_eq!(String::from_utf8_lossy(out.as_bytes()), wanted);
    }
}

#[test]
fn a_clause_parts_from_the_statement_it_qualifies() {
    let source: &[u8] =
        b"function f() {\n\tswitch (v) { case \"a\": run(); case \"b\": { g(); } default: h(); }\n}\n";

    let wanted =
        "function f() {\n    switch (v) {\n        case \"a\":\n            run();\n        case \
         \"b\": {\n            g();\n        }\n        default:\n            h();\n    }\n}\n";

    let keyed: &[u8] = b"const o = { default: { id: \"\" }, case: 1 };\n";
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(source, &mut out), Outcome::Complete);
    assert_eq!(String::from_utf8_lossy(out.as_bytes()), wanted);

    assert_eq!(held.format(keyed, &mut out), Outcome::Complete);

    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(keyed)
    );
}

#[test]
fn a_signature_parts_where_its_parameters_declare_properties() {
    let parted: &[u8] = b"class A {\n    constructor(public a: any, public b: any) {}\n}\n";

    let wanted =
        "class A {\n    constructor(\n        public a: any,\n        public b: any,\n    ) \
         {}\n}\n";

    let lone: &[u8] = b"class B {\n    constructor(private readonly x: T) {}\n}\n";
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(parted, &mut out), Outcome::Complete);
    assert_eq!(String::from_utf8_lossy(out.as_bytes()), wanted);

    assert_eq!(held.format(lone, &mut out), Outcome::Complete);

    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(lone)
    );
}

#[test]
fn a_member_spelled_as_a_word_of_the_language_still_names_a_call() {
    let source: &[u8] = b"const carried = Registry.as<IConfigurationRegistry>(ConfigurationExtensions.Configuration);\n";

    let wanted = "const carried = Registry.as<IConfigurationRegistry>(\n    \
                  ConfigurationExtensions.Configuration,\n);\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(source, &mut out), Outcome::Complete);
    assert_eq!(String::from_utf8_lossy(out.as_bytes()), wanted);
}

#[test]
fn a_type_writes_its_members_where_the_source_put_them() {
    let source: &[u8] = b"interface I {\n    comment: \"Optional details about how the action was run, e.g which keybinding\";\n}\n";
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(source, &mut out), Outcome::Complete);

    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(source)
    );
}

#[test]
fn a_header_parts_at_the_operators_its_condition_holds() {
    let chained: &[u8] = b"function f() {\n    if (typeof carriedGlobal !== \"undefined\" && typeof carriedGlobal.process !== \"undefined\") {\n        a();\n    }\n}\n";

    let wanted =
        "function f() {\n    if (\n        typeof carriedGlobal !== \"undefined\" &&\n        \
         typeof carriedGlobal.process !== \"undefined\"\n    ) {\n        a();\n    }\n}\n";

    let claused: &[u8] = b"function f() {\n    for (let i = idPath.length - 1; !ct.isCancellationRequested && i >= expandToLevel;) {\n        g();\n    }\n}\n";

    let owed = "function f() {\n    for (\n        let i = idPath.length - 1;\n        \
                !ct.isCancellationRequested && i >= expandToLevel;\n    ) {\n        g();\n    \
                }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(chained, &mut out), Outcome::Complete);
    assert_eq!(String::from_utf8_lossy(out.as_bytes()), wanted);

    assert_eq!(held.format(claused, &mut out), Outcome::Complete);
    assert_eq!(String::from_utf8_lossy(out.as_bytes()), owed);
}

#[test]
fn a_nested_ternary_keeps_the_blanks_around_the_colon_that_closes_the_outer_one() {
    let source: &[u8] = b"const f = q ? y ? 2 : 3 : 4;\nconst g = q ? 1 : y ? 2 : 3;\n";
    let wanted = "const f = q ? y ? 2 : 3 : 4;\nconst g = q ? 1 : y ? 2 : 3;\n";
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(source, &mut out), Outcome::Complete);
    assert_eq!(String::from_utf8_lossy(out.as_bytes()), wanted);
}

#[test]
fn a_string_takes_the_quote_biome_prefers() {
    let cases: [(&[u8], &str); 8] = [
        (b"a = 'x';\n", "a = \"x\";\n"),
        (b"a = \"x\";\n", "a = \"x\";\n"),
        (b"a = 'it\\'s';\n", "a = \"it's\";\n"),
        (b"a = 'say \"hi\"';\n", "a = 'say \"hi\"';\n"),
        (b"a = 'both \" and \\'';\n", "a = \"both \\\" and '\";\n"),
        (b"a = \"\\\"\";\n", "a = '\"';\n"),
        (b"a = \"\\'\";\n", "a = \"\\'\";\n"),
        (b"a = '\\n\\t';\n", "a = \"\\n\\t\";\n"),
    ];

    let mut held = Held::reserve();

    for (source, wanted) in cases {
        let mut out = Buffer::reserve(OUT_BYTES_MAX);

        assert_eq!(held.format(source, &mut out), Outcome::Complete);
        assert_eq!(String::from_utf8_lossy(out.as_bytes()), wanted);
    }
}

#[test]
fn a_range_reads_back_the_lines_it_names() {
    let source: &[u8] = b"function f(): void {\nlet x=1;\n}\n";
    let mut held = Held::reserve();
    let mut whole = Buffer::reserve(OUT_BYTES_MAX);
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(source, &mut whole), Outcome::Complete);

    let formatted = whole.as_bytes().to_vec();

    let span = held
        .range(source, (1, 2), &mut out)
        .expect("the range is formatted");

    assert_eq!(out.as_bytes(), formatted);
    assert_eq!(&out.as_bytes()[span.range()], lines_of(&formatted, 1, 2));
}

#[test]
fn the_three_relations_hold_over_the_corpus() {
    let Some(root) = corpus::root() else {
        return;
    };

    let mut first = Buffer::reserve(OUT_BYTES_MAX);
    let mut held = Held::reserve();
    let mut pending = vec![root];
    let mut second = Buffer::reserve(OUT_BYTES_MAX);
    let mut seen = 0;
    let stride = corpus::stride();

    while let Some(directory) = pending.pop() {
        let Ok(entries) = fs::read_dir(&directory) else {
            continue;
        };

        for entry in entries {
            let path = entry.expect("the entry is readable").path();

            if path.is_dir() {
                pending.push(path);

                continue;
            }

            if path.extension().is_none_or(|extension| extension != "ts") {
                continue;
            }

            seen += 1;

            if seen % stride != 0 {
                continue;
            }

            let Ok(source) = fs::read(&path) else {
                continue;
            };

            if held.format(&source, &mut first) != Outcome::Complete {
                continue;
            }

            let once = first.as_bytes().to_vec();
            let before = wrapped(&constructed(&called(&parenthesised(&listed(&unioned(
                &held.kinds(&source),
            ))))));
            let after = wrapped(&constructed(&called(&parenthesised(&listed(&unioned(
                &held.kinds(&once),
            ))))));

            if let Some((carried, at)) = divergence(&before, &after) {
                panic!(
                    "{} lost a token\n  source  {carried} of {} {}\n  printed {at} of {} {}",
                    path.display(),
                    before.len(),
                    window(&before, carried),
                    after.len(),
                    window(&after, at)
                );
            }

            assert_eq!(
                trimmed(&held.comments(&source)),
                trimmed(&held.comments(&once)),
                "{} lost a comment",
                path.display()
            );

            assert_eq!(
                held.format(&once, &mut second),
                Outcome::Complete,
                "{}",
                path.display()
            );

            assert_eq!(
                String::from_utf8_lossy(second.as_bytes()),
                String::from_utf8_lossy(&once),
                "{} is not idempotent",
                path.display()
            );
        }
    }
}

fn lines_of(bytes: &[u8], first: u32, last: u32) -> &[u8] {
    let mut line = 0;
    let mut start = 0;
    let mut end = bytes.len();

    for (offset, byte) in bytes.iter().enumerate() {
        if *byte != b'\n' {
            continue;
        }

        line += 1;

        if line == first {
            start = offset + 1;
        }

        if line == last + 1 {
            end = offset + 1;

            break;
        }
    }

    &bytes[start..end]
}

fn dialect_of(name: &str) -> Dialect {
    let extension = name.rsplit('.').next().unwrap_or("ts");

    Dialect::of_extension(extension).expect("the fixture is TypeScript")
}

#[test]
fn formatting_keeps_every_word_it_was_given() {
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    for (name, source) in fixtures() {
        if held.format(&source, &mut out) != Outcome::Complete {
            continue;
        }

        let formatted = out.as_bytes().to_vec();
        let before = opened(&bracketed(&separated(&held.words(&source))));
        let after = opened(&bracketed(&separated(&held.words(&formatted))));

        assert!(
            ended(&before, &after),
            "{name} split, joined, lost, or gained a word"
        );
    }
}

#[test]
fn a_class_a_construction_reaches_takes_parentheses_and_a_call() {
    const SOURCE: &[u8] =
        b"const a = new class X {}();\nconst b = new class extends Base<{}> {}(1, 2);\nconst c = new Foo();\n";

    const WANTED: &[u8] =
        b"const a = new (class X {})();\nconst b = new (class extends Base<{}> {})(1, 2);\nconst c = new Foo();\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_signature_holding_one_parameter_property_keeps_the_line_it_stands_on() {
    const SOURCE: &[u8] = b"class Lazy<T> {\n    constructor(\n        private readonly executor: () => T,\n    ) {}\n}\nclass Other {\n    constructor(\n        private readonly first: () => T,\n        private readonly second: () => T,\n    ) {}\n}\n";
    const WANTED: &[u8] = b"class Lazy<T> {\n    constructor(private readonly executor: () => T) {}\n}\nclass Other {\n    constructor(\n        private readonly first: () => T,\n        private readonly second: () => T,\n    ) {}\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_word_the_reference_writes_against_a_brace_keeps_the_line_that_brace_ends() {
    const SOURCE: &[u8] = b"function f() {\n    if (a) {\n        b();\n    }\n    else {\n        c();\n    }\n    try {\n        d();\n    }\n    catch (e) {\n        g();\n    }\n    finally {\n        h();\n    }\n    do {\n        i();\n    }\n    while (j);\n    if (k) {\n        l();\n    }\n    while (m) {\n        n();\n    }\n}\n";
    const WANTED: &[u8] = b"function f() {\n    if (a) {\n        b();\n    } else {\n        c();\n    }\n    try {\n        d();\n    } catch (e) {\n        g();\n    } finally {\n        h();\n    }\n    do {\n        i();\n    } while (j);\n    if (k) {\n        l();\n    }\n    while (m) {\n        n();\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn an_import_list_of_one_specifier_stands_on_the_line_it_opens() {
    const SOURCE: &[u8] = b"import {\n    sole\n} from \"./held\";\nimport {\n    aVeryLongSpecifierNameThatRunsOn\n} from \"./some/rather/long/module/path/that/runs/past/the/width\";\n";
    const WANTED: &[u8] = b"import { sole } from \"./held\";\nimport { aVeryLongSpecifierNameThatRunsOn } from \"./some/rather/long/module/path/that/runs/past/the/width\";\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_statement_the_source_left_without_one_gains_the_separator_the_reference_writes() {
    const SOURCE: &[u8] = b"import fs from \"node:fs\"\nconst a = 1\nlet b = class {}\nexport const c = 2\nexport class D {}\nexport default class E {}\nexport function f() {}\nexport { a }\nexport * from \"x\"\ntype T = { q: string }\ndeclare const g: number\ndeclare global {\n    const h: number\n}\nnamespace N {\n    const i = 1\n}\nenum Q {\n    A,\n}\nthrow new Error(\"e\")\n";
    const WANTED: &[u8] = b"import fs from \"node:fs\";\nconst a = 1;\nlet b = class {};\nexport const c = 2;\nexport class D {}\nexport default class E {}\nexport function f() {}\nexport { a };\nexport * from \"x\";\ntype T = { q: string };\ndeclare const g: number;\ndeclare global {\n    const h: number;\n}\nnamespace N {\n    const i = 1;\n}\nenum Q {\n    A,\n}\nthrow new Error(\"e\");\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_type_member_takes_its_separator_from_the_brace_that_holds_it() {
    const SOURCE: &[u8] = b"interface I {\n    name: string\n    go(): void\n    readonly z: number\n}\nclass C {\n    field = 1\n    accessor acc = 2\n    method() {}\n}\ntype T = { q: string }\n";
    const WANTED: &[u8] = b"interface I {\n    name: string;\n    go(): void;\n    readonly z: number;\n}\nclass C {\n    field = 1;\n    accessor acc = 2;\n    method() {}\n}\ntype T = { q: string };\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_parenthesis_pair_the_reference_re_prints_without_is_dropped() {
    const SOURCE: &[u8] = b"const a = (b + c);\nf((d));\nconst e = [(g)];\nh = (i);\nconst j = { k: (l) };\nconst m = ((n));\nthrow (new Error(\"x\"));\nconst o = p ? (q) : (r);\n";
    const WANTED: &[u8] = b"const a = b + c;\nf(d);\nconst e = [g];\nh = i;\nconst j = { k: l };\nconst m = n;\nthrow new Error(\"x\");\nconst o = p ? q : r;\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_parenthesis_pair_the_reference_writes_back_is_kept() {
    const SOURCE: &[u8] = b"const a = (b, c);\nconst d = (e = 1);\nconst g = () => ({ h: 1 });\nconst i = j ? (k ? 1 : 2) : 3;\nconst l = (m + n) * o;\nconst p = [...(q ?? [])];\nconst r = (s) => (t ? 1 : 2);\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_statement_ending_on_a_dropped_parenthesis_still_takes_its_separator() {
    const SOURCE: &[u8] = b"const a = b ? c : (d || e)\n";
    const WANTED: &[u8] = b"const a = b ? c : d || e;\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_bracket_the_source_parted_at_one_separator_parts_at_every_one() {
    const SOURCE: &[u8] =
        b"export type Held = {\n    first: string, second: number,\n    third: boolean,\n};\n";

    const WANTED: &[u8] =
        b"export type Held = {\n    first: string;\n    second: number;\n    third: boolean;\n};\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_bracket_the_source_wrote_whole_keeps_the_line_it_stands_on() {
    const SOURCE: &[u8] = b"const a = { first: 1, second: 2 };\nconst b = [\n    \"x\", // a remark\n    \"y\",\n];\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_type_written_inside_an_angle_list_is_not_a_body_the_layout_parts() {
    const SOURCE: &[u8] = b"export class Held extends Base<PropsAreLongEnoughToRunPast, { first: string; second: Held }[]> {\n    a = 1;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_list_holding_a_rest_element_is_one_the_layout_owns() {
    const SOURCE: &[u8] = b"class C {\n    setTimeout(callback: (...args: any[]) => void, ms: number, ...args: any[]): Disposable {\n        return d;\n    }\n}\n";
    const WANTED: &[u8] = b"class C {\n    setTimeout(\n        callback: (...args: any[]) => void,\n        ms: number,\n        ...args: any[]\n    ): Disposable {\n        return d;\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn an_argument_list_whose_argument_breaks_parts_unless_the_last_one_hugs_the_bracket() {
    const SOURCE: &[u8] = b"disposables.add(input.onWillDispose(() => {\n    assert(true);\n}));\ndisposables.add(() => {\n    assert(true);\n});\nsetTimeout(() => {\n    assert(true);\n}, duration);\nuseEffect(() => {\n    assert(true);\n}, [first, second]);\n";
    const WANTED: &[u8] = b"disposables.add(\n    input.onWillDispose(() => {\n        assert(true);\n    }),\n);\ndisposables.add(() => {\n    assert(true);\n});\nsetTimeout(() => {\n    assert(true);\n}, duration);\nuseEffect(() => {\n    assert(true);\n}, [first, second]);\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn an_argument_the_bracket_hugs_may_carry_a_return_type_or_an_object_type() {
    const SOURCE: &[u8] = b"const value = new Lazy<string>((): string => {\n    return value.value;\n});\nconst set = preserve.reduce<Record<string, boolean>>((set, key) => {\n    set[key] = true;\n    return set;\n}, {});\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn an_array_of_lists_of_the_same_kind_parts_at_any_width() {
    const SOURCE: &[u8] = b"const rows = [[\"name\", name], [\"country\", location]];\nconst objs = [{ a: 1, b: 2 }, { a: 3, b: 4 }];\nconst one = [[\"name\", name]];\nconst mixed = [[\"a\", 1], { b: 2 }];\nconst thin = [[\"a\"], [\"b\"]];\n";
    const WANTED: &[u8] = b"const rows = [\n    [\"name\", name],\n    [\"country\", location],\n];\nconst objs = [\n    { a: 1, b: 2 },\n    { a: 3, b: 4 },\n];\nconst one = [[\"name\", name]];\nconst mixed = [[\"a\", 1], { b: 2 }];\nconst thin = [[\"a\"], [\"b\"]];\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn an_arrow_parameter_list_of_more_than_one_is_one_the_layout_owns() {
    const SOURCE: &[u8] = b"const checkImport = (node: ESTree.LiteralNode, held: ESTree.NodeHeld, more: numbers) => {\n    return 1;\n};\n";
    const WANTED: &[u8] = b"const checkImport = (\n    node: ESTree.LiteralNode,\n    held: ESTree.NodeHeld,\n    more: numbers,\n) => {\n    return 1;\n};\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_return_whose_binaryish_argument_breaks_takes_parentheses_around_it() {
    const SOURCE: &[u8] = b"function f() {\n    return this.lineEndOffsetByLineIndex[lineNumber - 1] - this.lineStartOffsetByLine[n];\n}\nfunction g() {\n    return this.lineCount === other.lineCount;\n}\nfunction h() {\n    return alpha === bravo ? charlieValueIsLong : deltaValueIsAlsoRatherLongHere + 1;\n}\n";
    const WANTED: &[u8] = b"function f() {\n    return (\n        this.lineEndOffsetByLineIndex[lineNumber - 1] - this.lineStartOffsetByLine[n]\n    );\n}\nfunction g() {\n    return this.lineCount === other.lineCount;\n}\nfunction h() {\n    return alpha === bravo ? charlieValueIsLong : deltaValueIsAlsoRatherLongHere + 1;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn an_assignment_whose_value_is_binaryish_breaks_after_the_operator() {
    const SOURCE: &[u8] = b"const headersValuesHeld = typeof mimetype === \"string\" ? { \"Content-Type\": mimetype } : {};\n";
    const WANTED: &[u8] = b"const headersValuesHeld =\n    typeof mimetype === \"string\" ? { \"Content-Type\": mimetype } : {};\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_member_chain_of_more_than_two_groups_that_does_not_fit_parts_at_every_group() {
    const SOURCE: &[u8] = b"function f() {\n    const invalidFormatStartsWithHeldLonger = z.string().startsWith(\"abcd\").safeParse(\"invalidy\");\n    const short = a.b().c();\n    const twoGroups = someObject.property.getMatchingKernel(notebookTextModel).selected;\n}\n";
    const WANTED: &[u8] = b"function f() {\n    const invalidFormatStartsWithHeldLonger = z\n        .string()\n        .startsWith(\"abcd\")\n        .safeParse(\"invalidy\");\n    const short = a.b().c();\n    const twoGroups = someObject.property.getMatchingKernel(notebookTextModel).selected;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn an_accessor_takes_a_blank_before_the_computed_name_it_reads() {
    const SOURCE: &[u8] = b"class C {\n    get [Symbol.toStringTag](): string {\n        return \"C\";\n    }\n    set [Symbol.iterator](v: string) {}\n}\nfunction f(preserve: string[]) {\n    const set: Record<string, boolean> = {};\n    set[preserve[0]] = true;\n    return set;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_word_of_the_language_used_as_a_value_hugs_the_dot_past_it() {
    const SOURCE: &[u8] = b"declare const type: string;\nconst held = type.split(\"/\");\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_type_literal_is_a_list_whose_members_a_semicolon_separates() {
    const SOURCE: &[u8] = b"class C {\n    private held: { name: string; kind: string; location: Location; containerName: string };\n}\nconst object = { first: 1, second: 2 };\n";
    const WANTED: &[u8] = b"class C {\n    private held: {\n        name: string;\n        kind: string;\n        location: Location;\n        containerName: string;\n    };\n}\nconst object = { first: 1, second: 2 };\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_binaryish_run_past_the_width_parts_after_every_operator_of_its_own_rank() {
    const SOURCE: &[u8] = b"const isSupported = someLongConditionName && anotherLongConditionName && aThirdConditionHere;\nfunction f() {\n    const value = alpha.beta.gamma + delta.epsilon.zeta + eta.theta.iota + kappa.lambda.mu;\n    const short = a + b;\n}\n";
    const WANTED: &[u8] = b"const isSupported =\n    someLongConditionName && anotherLongConditionName && aThirdConditionHere;\nfunction f() {\n    const value =\n        alpha.beta.gamma + delta.epsilon.zeta + eta.theta.iota + kappa.lambda.mu;\n    const short = a + b;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_binaryish_run_parts_at_its_loosest_rank_and_holds_the_operators_under_it() {
    const SOURCE: &[u8] = b"xxx.yyy = aaaaaaaaaaaaaaaaaaaaaa + bbbbbbbbbbbbbbbbbbbb * cccccccccccccccccccc + ddddddddddddd;\n";
    const WANTED: &[u8] = b"xxx.yyy =\n    aaaaaaaaaaaaaaaaaaaaaa +\n    bbbbbbbbbbbbbbbbbbbb * cccccccccccccccccccc +\n    ddddddddddddd;\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_binaryish_run_past_a_return_parts_inside_the_parentheses_the_layout_adds() {
    const SOURCE: &[u8] = b"class A {\n    isCancellationRequested(): boolean {\n        return this.currentRequestId !== undefined && !!this.shouldCancel && this.shouldCancel();\n    }\n}\n";
    const WANTED: &[u8] = b"class A {\n    isCancellationRequested(): boolean {\n        return (\n            this.currentRequestId !== undefined &&\n            !!this.shouldCancel &&\n            this.shouldCancel()\n        );\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );

    out.clear();

    assert_eq!(held.format(WANTED, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_run_of_one_operator_holds_where_the_operand_behind_it_is_the_one_that_parts() {
    const SOURCE: &[u8] = b"class A {\n    f(): void {\n        const controller: TerminalChatController | undefined =\n            terminalService.activeInstance?.getContribution(TerminalChatController.ID) ?? undefined;\n    }\n}\n";
    const WANTED: &[u8] = b"class A {\n    f(): void {\n        const controller: TerminalChatController | undefined =\n            terminalService.activeInstance?.getContribution(\n                TerminalChatController.ID,\n            ) ?? undefined;\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_parameter_list_parts_for_a_property_modifier_and_not_for_a_readonly_type() {
    const SOURCE: &[u8] = b"export function findMaxIdx<T>(\n    array: readonly T[],\n    comparator: Comparator<T>,\n): number {\n    return 1;\n}\nclass C {\n    constructor(private readonly held: Held, other: Other) {}\n}\n";
    const WANTED: &[u8] = b"export function findMaxIdx<T>(array: readonly T[], comparator: Comparator<T>): number {\n    return 1;\n}\nclass C {\n    constructor(\n        private readonly held: Held,\n        other: Other,\n    ) {}\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_template_body_is_one_element_to_a_list_whatever_its_substitutions_lex_as() {
    const SOURCE: &[u8] = b"const nodePath = path.join(root, \".build\", \"node\", `v${version}`, `${platform}-${arch}`, node);\n";
    const WANTED: &[u8] = b"const nodePath = path.join(\n    root,\n    \".build\",\n    \"node\",\n    `v${version}`,\n    `${platform}-${arch}`,\n    node,\n);\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );

    out.clear();

    assert_eq!(held.format(WANTED, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_rest_parameter_takes_no_separator_and_a_spread_argument_takes_one() {
    const SOURCE: &[u8] = b"function held(firstParameterNameHere: number, ...restOfTheParametersHere: string[]) {}\nelement.append(...renderTheLabelWithIconsHere(theLabelToRender), ...otherRenderedThings);\n";
    const WANTED: &[u8] = b"function held(firstParameterNameHere: number, ...restOfTheParametersHere: string[]) {}\nelement.append(\n    ...renderTheLabelWithIconsHere(theLabelToRender),\n    ...otherRenderedThings,\n);\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn an_assertion_call_names_a_call_and_the_layout_owns_the_arguments_it_opens() {
    const SOURCE: &[u8] = b"function expectNodeLike(node: StatementNodeHere, spec: StatementNodeSpec, prefix = \"\") {}\n";
    const WANTED: &[u8] = b"function expectNodeLike(\n    node: StatementNodeHere,\n    spec: StatementNodeSpec,\n    prefix = \"\",\n) {}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_sole_arrow_parameter_the_layout_owns_unless_the_parameter_is_one_it_hugs() {
    const SOURCE: &[u8] = b"const checkImport = (node: ESTree.Literal & { parent?: ESTree.Node & { kind?: string } }) => {};\nconst hugged = ({ alpha, beta, gamma, delta, epsilon, zeta, eta, theta, iota }: Held) => {};\nconst isTenative = (p: unknown): p is (TentativeBoundary & { inner: Held }) =>\n    p instanceof TentativeBoundary;\n";
    const WANTED: &[u8] = b"const checkImport = (\n    node: ESTree.Literal & { parent?: ESTree.Node & { kind?: string } },\n) => {};\nconst hugged = ({ alpha, beta, gamma, delta, epsilon, zeta, eta, theta, iota }: Held) => {};\nconst isTenative = (p: unknown): p is (TentativeBoundary & { inner: Held }) =>\n    p instanceof TentativeBoundary;\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_call_whose_callee_is_a_word_of_the_language_is_a_call() {
    const SOURCE: &[u8] = b"class A extends B {\n    constructor() {\n        super(PolicyType.Boolean, name, category, minimumVersion, description, moduleName);\n    }\n}\n";
    const WANTED: &[u8] = b"class A extends B {\n    constructor() {\n        super(\n            PolicyType.Boolean,\n            name,\n            category,\n            minimumVersion,\n            description,\n            moduleName,\n        );\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_header_whose_heritage_clauses_do_not_fit_parts_before_each_of_them() {
    const SOURCE: &[u8] = b"export class CompletionsObservableWorkspace extends VSCodeWorkspace implements ICompletionsObservableWorkspace {\n    x = 1;\n}\nexport interface UnsupportedProtocolVersionErrorDataEx extends UnsupportedProtocolVersionErrorData {\n    z: number;\n}\nexport class ValueWithChangeEventFromObservable<T> implements IValueWithChangeEvent<T> {\n    y = 2;\n}\nclass Small implements Tiny {\n    a = 1;\n}\n";
    const WANTED: &[u8] = b"export class CompletionsObservableWorkspace\n    extends VSCodeWorkspace\n    implements ICompletionsObservableWorkspace\n{\n    x = 1;\n}\nexport interface UnsupportedProtocolVersionErrorDataEx\n    extends UnsupportedProtocolVersionErrorData {\n    z: number;\n}\nexport class ValueWithChangeEventFromObservable<T> implements IValueWithChangeEvent<T> {\n    y = 2;\n}\nclass Small implements Tiny {\n    a = 1;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_class_a_new_reaches_measures_the_parenthesis_the_printing_adds() {
    const SOURCE: &[u8] = b"suite(\"g\", () => {\n\ttest(\"x\", () => {\n\t\tconst deserializer = new class implements IViewDeserializer<ISerializableView> {\n\t\t\tfromJSON(): number {\n\t\t\t\treturn 1;\n\t\t\t}\n\t\t};\n\t});\n});\n";
    const WANTED: &[u8] = b"suite(\"g\", () => {\n    test(\"x\", () => {\n        const deserializer = new (class\n            implements IViewDeserializer<ISerializableView>\n        {\n            fromJSON(): number {\n                return 1;\n            }\n        })();\n    });\n});\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_union_type_that_does_not_fit_parts_before_every_bar_it_spells() {
    const SOURCE: &[u8] = b"export type SemanticTokensProviderStyling = DocumentSemanticTokensProvider | DocumentRangeSemanticTokensProvider;\nexport type Small = A | B;\nexport type Maybe = SomeVeryLongReferenceTypeNameThatWouldNotFitOnOneLineAtAll | null;\nexport interface Held {\n    readonly input: TabInputText | TabInputTextDiff | TabInputCustom | TabInputWebview | TabInputNotebook;\n    readonly small: A | B;\n}\n";
    const WANTED: &[u8] = b"export type SemanticTokensProviderStyling =\n    | DocumentSemanticTokensProvider\n    | DocumentRangeSemanticTokensProvider;\nexport type Small = A | B;\nexport type Maybe = SomeVeryLongReferenceTypeNameThatWouldNotFitOnOneLineAtAll | null;\nexport interface Held {\n    readonly input:\n        | TabInputText\n        | TabInputTextDiff\n        | TabInputCustom\n        | TabInputWebview\n        | TabInputNotebook;\n    readonly small: A | B;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_member_of_a_type_body_is_no_label_however_the_source_parted_it() {
    const SOURCE: &[u8] = b"export interface Alpha {\n    source:\n        | \"aaa\"\n        | \"bbb\";\n    other?: string;\n}\n";

    const WANTED: &[u8] =
        b"export interface Alpha {\n    source: \"aaa\" | \"bbb\";\n    other?: string;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn an_assignment_whose_value_is_a_template_never_breaks_past_its_operator() {
    const SOURCE: &[u8] = b"function f(fn: string) {\n    const query = `CallExpression[callee.property.name='${fn}'], CallExpression[callee.name='${fn}']`;\n    const heldValue = someCallThatIsQuiteLongIndeed(alpha, beta) + anotherCallHere(gamma);\n}\n";
    const WANTED: &[u8] = b"function f(fn: string) {\n    const query = `CallExpression[callee.property.name='${fn}'], CallExpression[callee.name='${fn}']`;\n    const heldValue =\n        someCallThatIsQuiteLongIndeed(alpha, beta) + anotherCallHere(gamma);\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn an_optional_members_parameter_list_is_one_the_layout_owns() {
    const SOURCE: &[u8] = b"export interface IHeld {\n    notifyQuestionCarouselAnswer?(toolCallId: string, question: IQuestion, response: UserInputResponse): Promise<void>;\n}\n";
    const WANTED: &[u8] = b"export interface IHeld {\n    notifyQuestionCarouselAnswer?(\n        toolCallId: string,\n        question: IQuestion,\n        response: UserInputResponse,\n    ): Promise<void>;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_ternarys_branches_stand_one_level_in_from_the_line_its_test_opens_on() {
    const SOURCE: &[u8] = b"function f() {\n\tif (match) {\n\t\tconst directives = this.client.apiVersion.gte(API.v390)\n\t\t\t? tsDirectives390\n\t\t\t: tsDirectives;\n\t\treturn directives;\n\t}\n}\nconst held = alpha\n\t? beta\n\t: gamma\n\t\t? delta\n\t\t: epsilon;\n";
    const WANTED: &[u8] = b"function f() {\n    if (match) {\n        const directives = this.client.apiVersion.gte(API.v390)\n            ? tsDirectives390\n            : tsDirectives;\n        return directives;\n    }\n}\nconst held = alpha\n    ? beta\n    : gamma\n        ? delta\n        : epsilon;\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn an_object_type_in_a_type_argument_list_is_one_the_layout_parts() {
    const SOURCE: &[u8] = b"export interface IHeld {\n    readonly onDidChangeFullScreen: Event<{ window: IAuxiliaryWindow; fullscreen: boolean }>;\n    readonly small: Event<{ a: A }>;\n    held(selector: string, xoffset?: number): Promise<{ x: number; y: number }>;\n}\n";
    const WANTED: &[u8] = b"export interface IHeld {\n    readonly onDidChangeFullScreen: Event<{\n        window: IAuxiliaryWindow;\n        fullscreen: boolean;\n    }>;\n    readonly small: Event<{ a: A }>;\n    held(selector: string, xoffset?: number): Promise<{ x: number; y: number }>;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_union_of_objects_that_each_fit_parts_before_every_bar() {
    const SOURCE: &[u8] = b"export type Account = { type: \"apiKey\" } | { type: \"chatgpt\"; email: string | null } | { type: \"amazonBedrock\"; region: string };\n";
    const WANTED: &[u8] = b"export type Account =\n    | { type: \"apiKey\" }\n    | { type: \"chatgpt\"; email: string | null }\n    | { type: \"amazonBedrock\"; region: string };\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_union_that_fits_is_written_flat_and_drops_the_bar_the_source_spelled() {
    const SOURCE: &[u8] = b"export namespace Held {\n    export type ElicitRequestParams =\n        | ElicitRequestFormParams\n        | ElicitRequestURLParams;\n}\n";
    const WANTED: &[u8] = b"export namespace Held {\n    export type ElicitRequestParams = ElicitRequestFormParams | ElicitRequestURLParams;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_calls_arguments_that_compose_functions_part_at_every_comma() {
    const SOURCE: &[u8] = b"f(a.map((t) => t), b);\nf(a, (b) => b);\nf(new Foo(() => {}), b);\nf(a.b.c(x.map((t) => t)), y);\nf(a.map((t) => t));\ncheck(\"held\", !out.some((u) => u.name === \"good\"));\nuseEffect(() => {\n    doThing();\n}, [a, b]);\n";
    const WANTED: &[u8] = b"f(\n    a.map((t) => t),\n    b,\n);\nf(a, (b) => b);\nf(new Foo(() => {}), b);\nf(a.b.c(x.map((t) => t)), y);\nf(a.map((t) => t));\ncheck(\"held\", !out.some((u) => u.name === \"good\"));\nuseEffect(() => {\n    doThing();\n}, [a, b]);\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn an_arrow_body_that_is_a_call_stands_on_a_line_of_its_own_when_it_does_not_fit() {
    const SOURCE: &[u8] = b"const matched = targets.some((pattern) => minimatch(relativeFilenameHere, patternLonger));\nconst held = targets.some(alpha, (pattern) => minimatch(relative, pattern));\nconst wide = targets.some((pattern) => key.startsWith(\"bs\") && !key.startsWith(\"bsConfig\"));\nexport function f<T>(g: () => Promise<T>): void {}\n";
    const WANTED: &[u8] = b"const matched = targets.some((pattern) =>\n    minimatch(relativeFilenameHere, patternLonger),\n);\nconst held = targets.some(alpha, (pattern) => minimatch(relative, pattern));\nconst wide = targets.some(\n    (pattern) => key.startsWith(\"bs\") && !key.startsWith(\"bsConfig\"),\n);\nexport function f<T>(g: () => Promise<T>): void {}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_call_taking_a_function_body_is_one_the_layout_owns() {
    const SOURCE: &[u8] = b"suite(\"x\", () => {\n    test(\"a name that is quite long indeed and pushes the line over the width\", () => {\n        assert.strictEqual(graph.lookup(normalize(path.join(tmpDir, \"a.js\"))), undefined);\n    });\n});\n";
    const WANTED: &[u8] = b"suite(\"x\", () => {\n    test(\"a name that is quite long indeed and pushes the line over the width\", () => {\n        assert.strictEqual(\n            graph.lookup(normalize(path.join(tmpDir, \"a.js\"))),\n            undefined,\n        );\n    });\n});\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_first_argument_that_is_a_function_hugs_the_short_one_behind_it() {
    const SOURCE: &[u8] = b"function d() {\n    timeout = setTimeout(\n        () => {\n            timeout = undefined;\n            fn();\n        },\n        duration,\n    );\n    const set = preserve.reduce(\n        (set, key) => {\n            set[key] = true;\n            return set;\n        },\n        {},\n    );\n}\n";
    const WANTED: &[u8] = b"function d() {\n    timeout = setTimeout(() => {\n        timeout = undefined;\n        fn();\n    }, duration);\n    const set = preserve.reduce((set, key) => {\n        set[key] = true;\n        return set;\n    }, {});\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_test_calls_arguments_are_written_on_the_line_the_call_opens() {
    const SOURCE: &[u8] = b"suite(\"x\", () => {\n    test(\n        \"diffGeneratedTrees reports content, missing, and extra files (README ignored)\",\n        () => {\n            const commit = 1;\n        },\n    );\n    notATest(\n        \"this is not a test call and it is quite long indeed yes it is truly\",\n        () => {\n            doThing();\n        },\n    );\n});\n";
    const WANTED: &[u8] = b"suite(\"x\", () => {\n    test(\"diffGeneratedTrees reports content, missing, and extra files (README ignored)\", () => {\n        const commit = 1;\n    });\n    notATest(\n        \"this is not a test call and it is quite long indeed yes it is truly\",\n        () => {\n            doThing();\n        },\n    );\n});\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}
