#![no_main]

use std::cell::RefCell;

use libfuzzer_sys::fuzz_target;
use scylla::fuzzing::format::FormatHarness;
use scylla::fuzzing::parse::{LIMITS_DEFAULT, ParseHarness};
use scylla::language::Language;
use scylla::lex::ODIN;
use scylla::syntax::odin::classify::classify;
use scylla::syntax::odin::kind::OdinKind;
use scylla::syntax::odin::parse;

thread_local! {
    static FORMAT: RefCell<FormatHarness> = RefCell::new(FormatHarness::reserve(Language::Odin));

    static PARSE: RefCell<ParseHarness<OdinKind>> =
        RefCell::new(ParseHarness::reserve(&LIMITS_DEFAULT));
}

fuzz_target!(|data: &[u8]| {
    PARSE.with(|harness| harness.borrow_mut().check(&ODIN, classify, parse::build, data));
    FORMAT.with(|harness| harness.borrow_mut().check(data));
});
