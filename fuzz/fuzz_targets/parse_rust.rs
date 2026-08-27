#![no_main]

use std::cell::RefCell;

use libfuzzer_sys::fuzz_target;
use scylla::fuzzing::format::FormatHarness;
use scylla::fuzzing::parse::{LIMITS_DEFAULT, ParseHarness};
use scylla::language::Language;
use scylla::lex::RUST;
use scylla::syntax::rust::classify::classify;
use scylla::syntax::rust::kind::RustKind;
use scylla::syntax::rust::parse;

thread_local! {
    static FORMAT: RefCell<FormatHarness> = RefCell::new(FormatHarness::reserve(Language::Rust));

    static PARSE: RefCell<ParseHarness<RustKind>> =
        RefCell::new(ParseHarness::reserve(&LIMITS_DEFAULT));
}

fuzz_target!(|data: &[u8]| {
    PARSE.with(|harness| harness.borrow_mut().check(&RUST, classify, parse::build, data));
    FORMAT.with(|harness| harness.borrow_mut().check(data));
});
