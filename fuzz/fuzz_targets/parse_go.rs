#![no_main]

use std::cell::RefCell;

use libfuzzer_sys::fuzz_target;
use scylla::fuzzing::format::FormatHarness;
use scylla::fuzzing::parse::{LIMITS_DEFAULT, ParseHarness};
use scylla::language::Language;
use scylla::lex::GO;
use scylla::syntax::go::classify::classify;
use scylla::syntax::go::kind::GoKind;
use scylla::syntax::go::parse;

thread_local! {
    static FORMAT: RefCell<FormatHarness> = RefCell::new(FormatHarness::reserve(Language::Go));

    static PARSE: RefCell<ParseHarness<GoKind>> =
        RefCell::new(ParseHarness::reserve(&LIMITS_DEFAULT));
}

fuzz_target!(|data: &[u8]| {
    PARSE.with(|harness| harness.borrow_mut().check(&GO, classify, parse::build, data));
    FORMAT.with(|harness| harness.borrow_mut().check(data));
});
