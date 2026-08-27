#![no_main]

use std::cell::RefCell;

use libfuzzer_sys::fuzz_target;
use scylla::bounded::BoundedVec;
use scylla::fuzzing::format::FormatHarness;
use scylla::fuzzing::parse::{LIMITS_DEFAULT, ParseHarness};
use scylla::language::Language;
use scylla::lex::TYPESCRIPT;
use scylla::syntax::Structure;
use scylla::syntax::typescript::classify::classify;
use scylla::syntax::typescript::dialect::Dialect;
use scylla::syntax::typescript::kind::TypeScriptKind;
use scylla::syntax::typescript::parse;
use scylla::token::{Token, Tokens};
use scylla::tree::{Events, Tree};

thread_local! {
    static FORMAT: RefCell<FormatHarness> = RefCell::new(FormatHarness::reserve(Language::Tsx));

    static PARSE: RefCell<ParseHarness<TypeScriptKind>> =
        RefCell::new(ParseHarness::reserve(&LIMITS_DEFAULT));
}

fn build(
    source: &[u8],
    tokens: &[Token],
    raw: &[TypeScriptKind],
    events: &mut Events<TypeScriptKind>,
    tree: &mut Tree<TypeScriptKind>,
) -> Structure {
    parse::build(source, tokens, raw, events, tree, Dialect::Tsx)
}

fn classify_tsx(
    source: &[u8],
    tokens: &[Token],
    out: &mut Tokens,
    raw: &mut BoundedVec<TypeScriptKind>,
) -> bool {
    classify(source, tokens, out, raw, Dialect::Tsx)
}

fuzz_target!(|data: &[u8]| {
    PARSE.with(|harness| harness.borrow_mut().check(&TYPESCRIPT, classify_tsx, build, data));
    FORMAT.with(|harness| harness.borrow_mut().check(data));
});
