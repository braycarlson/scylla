#[path = "common/golden.rs"]
mod common;

use scylla::bounded::Random;
use scylla::markup::{self, MarkupKind, Tokens};
use scylla::token::Lex;

const TOKEN_COUNT_MAX: u32 = 1 << 18;

#[test]
fn every_fixture_lexes_to_the_token_stream_the_oracle_recorded() {
    let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);
    let fixtures = common::fixtures();

    for fixture in &fixtures {
        let outcome = markup::lex(&fixture.source, &mut tokens);

        assert_eq!(outcome, Lex::Complete, "{}", fixture.name);

        let lexed = tokens.as_slice();
        let recorded = &fixture.golden.tokens;

        assert_eq!(
            lexed.len(),
            recorded.len(),
            "{}: the token counts differ",
            fixture.name
        );

        for (index, (token, row)) in lexed.iter().zip(recorded.iter()).enumerate() {
            assert_eq!(
                token.kind,
                MarkupKind::of_name(&row.0).expect("the oracle names a kind the library carries"),
                "{}: token {index} differs in kind",
                fixture.name
            );

            assert_eq!(
                token.offset,
                row.1,
                "{}: token {index} differs in offset",
                fixture.name
            );

            assert_eq!(
                token.end(),
                row.2,
                "{}: token {index} differs in end",
                fixture.name
            );
        }
    }
}

#[test]
fn the_token_spans_reproduce_every_fixture_byte_for_byte() {
    let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);

    for fixture in &common::fixtures() {
        markup::lex(&fixture.source, &mut tokens);
        lossless(&fixture.source, &tokens, &fixture.name);
    }
}

#[test]
fn the_token_spans_reproduce_byte_soup_byte_for_byte() {
    let mut random = Random::new(0x2545_F491_4F6C_DD1D);
    let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);
    let alphabet = b"<>/=\"'{}%#|:,. \n\t-!abcdivscriptylendverbatim";

    for case in 0..512 {
        let length = random.below(256) as usize;
        let mut source = Vec::with_capacity(length);

        for _ in 0..length {
            let index = random.below(u32::try_from(alphabet.len()).expect("the alphabet is small"))
                as usize;

            source.push(alphabet[index]);
        }

        markup::lex(&source, &mut tokens);
        lossless(&source, &tokens, &format!("soup {case}"));

        let first: Vec<_> = tokens.as_slice().to_vec();

        markup::lex(&source, &mut tokens);

        assert_eq!(
            first,
            tokens.as_slice(),
            "soup {case}: the lex is not stable"
        );
    }
}

#[test]
fn a_starved_budget_truncates_and_still_covers_every_byte() {
    let source = common::fixtures()
        .into_iter()
        .max_by_key(|fixture| fixture.source.len())
        .expect("the corpus is not empty")
        .source;

    let mut starved = Tokens::reserve(4);
    let mut generous = Tokens::reserve(TOKEN_COUNT_MAX);

    assert_eq!(markup::lex(&source, &mut starved), Lex::Truncated);
    assert_eq!(markup::lex(&source, &mut generous), Lex::Complete);

    lossless(&source, &starved, "the starved lex");
    lossless(&source, &generous, "the generous lex");

    assert!(starved.count() <= 4);
    assert!(generous.count() > starved.count());
}

#[test]
fn an_empty_source_is_complete_under_any_budget() {
    let mut tokens = Tokens::reserve(1);

    assert_eq!(markup::lex(b"", &mut tokens), Lex::Complete);
    assert_eq!(tokens.count(), 0);
}

#[test]
fn every_awkward_source_holds_the_lossless_property() {
    const SOURCES: &[&[u8]] = &[
        b"",
        b"\n",
        b"<",
        b">",
        b"{",
        b"{{",
        b"{%",
        b"{#",
        b"{{ name",
        b"{% block",
        b"{# note",
        b"<div class=\"open",
        b"<!--",
        b"<!-- {{ name }}",
        b"<!DOCTYPE html>",
        b"</div>",
        b"</>",
        b"<script>var a = 1;",
        b"<style>a { b: c }",
        b"{% verbatim %}{{ literal }}",
        b"{% verbatim %}{{ literal }}{% endverbatim %}",
        b"<div a=b c='d' e=\"f\"/>",
        b"\xef\xbb\xbf<div>",
        b"\xff\xfe not utf eight at all",
        b"<p>a<p>b<p>c",
        b"<div {{ attribute }}>",
    ];

    let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);

    for source in SOURCES {
        assert_eq!(markup::lex(source, &mut tokens), Lex::Complete);
        lossless(source, &tokens, "an awkward source");
    }
}

fn lossless(source: &[u8], tokens: &Tokens, name: &str) {
    let mut end_previous = 0;

    for (index, token) in tokens.as_slice().iter().enumerate() {
        assert_eq!(
            token.offset,
            end_previous,
            "{name}: token {index} leaves a gap or overlaps"
        );

        assert!(token.length > 0, "{name}: token {index} covers no byte");

        end_previous = token.end();
    }

    assert_eq!(
        end_previous as usize,
        source.len(),
        "{name}: the stream stops short of the source end"
    );
}
