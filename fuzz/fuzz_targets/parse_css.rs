#![no_main]

use std::cell::RefCell;

use libfuzzer_sys::fuzz_target;
use scylla::fuzzing::format::FormatHarness;
use scylla::fuzzing::parse::{LIMITS_DEFAULT, ParseHarness};
use scylla::language::Language;
use scylla::lex::CSS;
use scylla::syntax::css::classify::classify;
use scylla::syntax::css::kind::CSSKind;
use scylla::syntax::css::parse;

thread_local! {
    static FORMAT: RefCell<FormatHarness> = RefCell::new(FormatHarness::reserve(Language::Css));

    static PARSE: RefCell<ParseHarness<CSSKind>> =
        RefCell::new(ParseHarness::reserve(&LIMITS_DEFAULT));
}

fuzz_target!(|data: &[u8]| {
    PARSE.with(|harness| harness.borrow_mut().check(&CSS, classify, parse::build, data));
    FORMAT.with(|harness| harness.borrow_mut().check(data));
});
