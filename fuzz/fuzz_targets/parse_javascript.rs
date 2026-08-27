#![no_main]

use std::cell::RefCell;

use libfuzzer_sys::fuzz_target;
use scylla::fuzzing::format::FormatHarness;
use scylla::fuzzing::parse::{LIMITS_DEFAULT, ParseHarness};
use scylla::language::Language;
use scylla::lex::JAVASCRIPT;
use scylla::syntax::javascript::classify::classify;
use scylla::syntax::javascript::kind::JavaScriptKind;
use scylla::syntax::javascript::parse;

thread_local! {
    static FORMAT: RefCell<FormatHarness> = RefCell::new(FormatHarness::reserve(Language::JavaScript));

    static PARSE: RefCell<ParseHarness<JavaScriptKind>> =
        RefCell::new(ParseHarness::reserve(&LIMITS_DEFAULT));
}

fuzz_target!(|data: &[u8]| {
    PARSE.with(|harness| harness.borrow_mut().check(&JAVASCRIPT, classify, parse::build, data));
    FORMAT.with(|harness| harness.borrow_mut().check(data));
});
