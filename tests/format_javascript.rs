#[path = "common/corpus.rs"]
mod corpus;
#[path = "common/floor.rs"]
mod floor;

use std::fs;
use std::path::PathBuf;

use scylla::bounded::{BoundedVec, Buffer, Span};
use scylla::format::brace::renumbered;
use scylla::format::javascript::{Formatter, Input, Outcome};
use scylla::format::print::Options;
use scylla::language::Lexer as _;
use scylla::lex::JAVASCRIPT;
use scylla::syntax::javascript::classify::classify;
use scylla::syntax::javascript::kind::JavaScriptKind;
use scylla::syntax::javascript::parse;
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
    events: Events<JavaScriptKind>,
    formatter: Formatter,
    lexed: Tokens,
    raw: BoundedVec<JavaScriptKind>,
    tokens: Tokens,
    tree: Tree<JavaScriptKind>,
}

impl Held {
    fn reserve() -> Self {
        Self {
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

        JAVASCRIPT.lex(source, &mut self.lexed);

        if !classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw,
        ) {
            return Outcome::Overflow;
        }

        let outcome = parse::build(
            source,
            self.tokens.as_slice(),
            &self.raw,
            &mut self.events,
            &mut self.tree,
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

        JAVASCRIPT.lex(source, &mut self.lexed);

        if !classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw,
        ) {
            return None;
        }

        let outcome = parse::build(
            source,
            self.tokens.as_slice(),
            &self.raw,
            &mut self.events,
            &mut self.tree,
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
        JAVASCRIPT.lex(source, &mut self.lexed);

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

    fn kinds(&mut self, source: &[u8]) -> Vec<JavaScriptKind> {
        self.lexed.clear();
        self.raw.clear();
        self.tokens.clear();

        JAVASCRIPT.lex(source, &mut self.lexed);

        assert!(classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw
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

        JAVASCRIPT.lex(source, &mut self.lexed);

        assert!(classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw
        ));

        self.raw
            .iter()
            .enumerate()
            .filter(|(_, kind)| **kind == JavaScriptKind::Comment)
            .map(|(index, _)| {
                source[self.tokens.as_slice()[index].span().range()]
                    .trim_ascii_end()
                    .to_vec()
            })
            .collect()
    }
}

fn fixtures() -> Vec<(String, Vec<u8>)> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/javascript");
    let mut found = Vec::new();

    for entry in fs::read_dir(&root).expect("the fixture directory is readable") {
        let path = entry.expect("the entry is readable").path();

        if path.extension().is_none_or(|extension| extension != "js") {
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

fn leaned(kind: JavaScriptKind, depth: u32) -> u32 {
    match kind {
        JavaScriptKind::ParenOpen => depth + 1,
        JavaScriptKind::ParenClose => depth.saturating_sub(1),
        _ => depth,
    }
}

fn wrapped(kinds: &[JavaScriptKind]) -> Vec<JavaScriptKind> {
    let pairs = partners(
        kinds,
        &JavaScriptKind::ParenOpen,
        &JavaScriptKind::ParenClose,
    );
    let mut found: Vec<JavaScriptKind> = Vec::with_capacity(kinds.len());
    let mut skips: Vec<usize> = Vec::new();
    let mut index = 0;

    while index < kinds.len() {
        let wraps = matches!(
            kinds[index],
            JavaScriptKind::ReturnKeyword | JavaScriptKind::ThrowKeyword
        ) && kinds.get(index + 1) == Some(&JavaScriptKind::ParenOpen)
            && pairs[index + 1] > index + 1
            && kinds.get(pairs[index + 1] + 1).is_none_or(|held| {
                matches!(
                    *held,
                    JavaScriptKind::Semicolon | JavaScriptKind::BraceClose
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

fn terminated(source: &[JavaScriptKind], printed: &[JavaScriptKind]) -> bool {
    divergence(source, printed).is_none()
}

fn divergence(source: &[JavaScriptKind], printed: &[JavaScriptKind]) -> Option<(usize, usize)> {
    let bare = [
        &JavaScriptKind::ParenOpen,
        &JavaScriptKind::ParenClose,
        &JavaScriptKind::Semicolon,
    ];
    let carried = partners(
        source,
        &JavaScriptKind::ParenOpen,
        &JavaScriptKind::ParenClose,
    );
    let written = partners(
        printed,
        &JavaScriptKind::ParenOpen,
        &JavaScriptKind::ParenClose,
    );
    let spans = weights(source, &bare);
    let widths = weights(printed, &bare);
    let mut depth = 0;
    let mut dropped: Vec<u32> = Vec::new();
    let mut held = 0;

    for (at, kind) in printed.iter().enumerate() {
        while let Some(item) = source.get(held) {
            let paired = *kind == JavaScriptKind::ParenOpen
                && inside(&carried, &spans, held) == inside(&written, &widths, at);

            let closes = *item == JavaScriptKind::ParenClose
                && dropped.last().is_some_and(|from| from + 1 == depth);

            let opens =
                *item == JavaScriptKind::ParenOpen && *kind != JavaScriptKind::Semicolon && !paired;

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

        if *kind == JavaScriptKind::Semicolon {
            continue;
        }

        return Some((held, at));
    }

    while source.get(held) == Some(&JavaScriptKind::ParenClose) && !dropped.is_empty() {
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

fn listed(kinds: &[JavaScriptKind]) -> Vec<JavaScriptKind> {
    kinds
        .iter()
        .enumerate()
        .filter(|(index, held)| **held != JavaScriptKind::Comma || !closing(kinds, index + 1))
        .map(|(_, held)| *held)
        .collect()
}

fn closing(kinds: &[JavaScriptKind], from: usize) -> bool {
    let mut at = from;

    while kinds.get(at) == Some(&JavaScriptKind::Comment) {
        at += 1;
    }

    matches!(
        kinds.get(at),
        Some(
            JavaScriptKind::BraceClose | JavaScriptKind::BracketClose | JavaScriptKind::ParenClose
        )
    )
}

fn separated(words: &[String]) -> Vec<String> {
    words
        .iter()
        .enumerate()
        .filter(|(index, held)| held.as_str() != "," || !closes(words, index + 1))
        .map(|(_, held)| held.clone())
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

fn called(kinds: &[JavaScriptKind]) -> Vec<JavaScriptKind> {
    let mut depth = 0_u32;
    let mut held = Vec::with_capacity(kinds.len());
    let mut owed: Vec<u32> = Vec::new();

    for (index, kind) in kinds.iter().enumerate() {
        if *kind == JavaScriptKind::ParenOpen {
            depth += 1;

            let next = kinds.get(index + 1);

            let functions = next == Some(&JavaScriptKind::FunctionKeyword)
                || next == Some(&JavaScriptKind::AsyncKeyword)
                    && kinds.get(index + 2) == Some(&JavaScriptKind::FunctionKeyword);

            if functions {
                owed.push(depth);

                continue;
            }
        }

        if *kind == JavaScriptKind::ParenClose {
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

fn parenthesised(kinds: &[JavaScriptKind]) -> Vec<JavaScriptKind> {
    let mut held = Vec::with_capacity(kinds.len());
    let mut index = 0;

    while index < kinds.len() {
        let lone = kinds[index] == JavaScriptKind::ParenOpen
            && kinds.get(index + 1) == Some(&JavaScriptKind::Identifier)
            && kinds.get(index + 2) == Some(&JavaScriptKind::ParenClose)
            && kinds.get(index + 3) == Some(&JavaScriptKind::Arrow);

        if lone {
            held.push(JavaScriptKind::Identifier);
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

fn colons(held: &[(JavaScriptKind, Token)]) -> Vec<bool> {
    let mut found = vec![false; held.len()];
    let mut owed: Vec<u32> = vec![0];

    for (at, (kind, _)) in held.iter().enumerate() {
        match *kind {
            JavaScriptKind::BraceOpen | JavaScriptKind::BracketOpen | JavaScriptKind::ParenOpen => {
                owed.push(0);
            }
            JavaScriptKind::BraceClose
            | JavaScriptKind::BracketClose
            | JavaScriptKind::ParenClose => {
                if owed.len() > 1 {
                    owed.pop();
                }
            }
            JavaScriptKind::Comma | JavaScriptKind::Semicolon => {
                if let Some(frame) = owed.last_mut() {
                    *frame = 0;
                }
            }
            JavaScriptKind::CaseKeyword => {
                let labelled =
                    held.get(at + 1).map(|(carried, _)| *carried) != Some(JavaScriptKind::Colon);

                if let Some(frame) = owed.last_mut().filter(|_| labelled) {
                    *frame += 1;
                }
            }
            JavaScriptKind::Question => {
                let optional =
                    held.get(at + 1).map(|(carried, _)| *carried) == Some(JavaScriptKind::Colon);

                if let Some(frame) = owed.last_mut().filter(|_| !optional) {
                    *frame += 1;
                }
            }
            JavaScriptKind::Colon => {
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

fn keyed(source: &[u8], held: &[(JavaScriptKind, Token)]) -> Vec<JavaScriptKind> {
    let asked = colons(held);

    held.iter()
        .enumerate()
        .map(|(index, (kind, token))| {
            let next = held.get(index + 1).map(|(carried, _)| *carried);

            let at = if next == Some(JavaScriptKind::Colon) {
                index + 1
            } else if next == Some(JavaScriptKind::Question)
                && held.get(index + 2).map(|(carried, _)| *carried) == Some(JavaScriptKind::Colon)
            {
                index + 2
            } else {
                return *kind;
            };

            if asked[at] || bare_key(token.text(source)).is_none() {
                return *kind;
            }

            JavaScriptKind::Identifier
        })
        .collect()
}

#[test]
fn formatting_keeps_every_token_it_was_given() {
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    for (name, source) in fixtures() {
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
fn every_jsx_fixture_is_formatted_or_refused_by_its_own_row() {
    let carried = oracle::residue_of("residue-format-javascript.json", &EVERY_CATEGORY);
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);
    let mut walked = 0;

    for (name, source) in fixtures() {
        if !name.starts_with("jsx_") {
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

    assert_eq!(walked, 7, "the jsx fixtures are not walked");
}

#[test]
fn the_formatted_output_matches_the_oracle_modulo_residue() {
    let carried = oracle::residue_of("residue-format-javascript.json", &EVERY_CATEGORY);
    let root =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-biome-javascript");
    let mut compared = 0;
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    for (name, source) in fixtures() {
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
        compared >= floor::FIXTURE_FORMAT_JAVASCRIPT,
        "the JavaScript fixtures lost a formatting: {compared} compared, floor {}",
        floor::FIXTURE_FORMAT_JAVASCRIPT
    );
}

#[test]
fn every_residue_row_names_a_fixture_that_diverges() {
    let carried = oracle::residue_of("residue-format-javascript.json", &EVERY_CATEGORY);
    let root =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-biome-javascript");
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    for name in &carried {
        let source = fs::read(
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("tests/fixtures/javascript")
                .join(name),
        )
        .expect("the residue row names a fixture");

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
fn a_source_that_never_closes_a_string_or_a_comment_is_refused() {
    const SOURCES: [&[u8]; 4] = [b"' ", b"\":\\\\", b"/* ", b"const a = \"open\n"];

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    for source in SOURCES {
        assert_eq!(
            held.format(source, &mut out),
            Outcome::Refusal,
            "{:?}",
            String::from_utf8_lossy(source)
        );
    }
}

#[test]
fn an_operator_does_not_reach_into_the_comment_behind_it() {
    let source: &[u8] = b"tyy<<!--y[";
    let mut held = Held::reserve();
    let mut first = Buffer::reserve(OUT_BYTES_MAX);
    let mut second = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(source, &mut first), Outcome::Complete);

    let once = first.as_bytes().to_vec();

    assert_eq!(held.comments(source), held.comments(&once));
    assert_eq!(held.format(&once, &mut second), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(second.as_bytes()),
        String::from_utf8_lossy(&once)
    );
}

#[test]
fn a_slash_kept_tight_to_a_shift_stays_out_of_a_regular_expression() {
    const SOURCES: [&[u8]; 2] = [b"<</<!--/ ", b"<</<!--/\x0c"];

    let mut held = Held::reserve();
    let mut first = Buffer::reserve(OUT_BYTES_MAX);
    let mut second = Buffer::reserve(OUT_BYTES_MAX);

    for source in SOURCES {
        assert_eq!(
            held.format(source, &mut first),
            Outcome::Complete,
            "{}",
            String::from_utf8_lossy(source)
        );

        let once = first.as_bytes().to_vec();

        assert!(
            String::from_utf8_lossy(&once).starts_with("<</"),
            "{}",
            String::from_utf8_lossy(&once)
        );

        assert_eq!(held.format(&once, &mut second), Outcome::Complete);
        assert_eq!(second.as_bytes(), once);
    }
}

#[test]
fn a_spaced_shift_keeps_its_spaces() {
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(b"a = b << c;\n", &mut out), Outcome::Complete);
    assert_eq!(String::from_utf8_lossy(out.as_bytes()), "a = b << c;\n");
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
    let source: &[u8] = b"function f() {\nlet x=1;\nreturn x;\n}\n";
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

            if path.extension().is_none_or(|extension| extension != "js") {
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
            let before = wrapped(&called(&parenthesised(&listed(&held.kinds(&source)))));
            let after = wrapped(&called(&parenthesised(&listed(&held.kinds(&once)))));

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
fn a_statement_the_source_left_without_one_gains_the_separator_the_reference_writes() {
    const SOURCE: &[u8] = b"import fs from \"node:fs\"\nconst a = 1\nlet b = class {}\nexport class D {}\nexport default class E {}\nexport function f() {}\nexport { a }\nclass C {\n    field = 1\n    method() {}\n}\nfunction j() {\n    return 1\n}\ndo {\n    j()\n} while (a)\nthrow new Error(\"e\")\n";
    const WANTED: &[u8] = b"import fs from \"node:fs\";\nconst a = 1;\nlet b = class {};\nexport class D {}\nexport default class E {}\nexport function f() {}\nexport { a };\nclass C {\n    field = 1;\n    method() {}\n}\nfunction j() {\n    return 1;\n}\ndo {\n    j();\n} while (a);\nthrow new Error(\"e\");\n";

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
    const SOURCE: &[u8] = b"const held = {\n    first: 1, second: 2,\n    third: 3,\n};\n";
    const WANTED: &[u8] = b"const held = {\n    first: 1,\n    second: 2,\n    third: 3,\n};\n";

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
fn a_binaryish_value_an_object_operand_of_a_logical_run_is_a_list_the_layout_owns() {
    const SOURCE: &[u8] = b"const a = info ?? { folder: undefined, repository: undefined, repositoryProps: undefined };\n";
    const WANTED: &str = "const a = info ?? {\n    folder: undefined,\n    repository: \
                          undefined,\n    repositoryProps: undefined,\n};\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(String::from_utf8_lossy(out.as_bytes()), WANTED);
}
