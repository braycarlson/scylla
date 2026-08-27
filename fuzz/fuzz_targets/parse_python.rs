#![no_main]

use std::cell::RefCell;

use libfuzzer_sys::fuzz_target;
use scylla::fuzzing::format::FormatHarness;
use scylla::fuzzing::parse::{LIMITS_DEFAULT, ParseHarness};
use scylla::language::Language;
use scylla::lex::PYTHON;
use scylla::syntax::python::classify::classify;
use scylla::syntax::python::kind::PythonKind;
use scylla::syntax::python::parse;

thread_local! {
    static FORMAT: RefCell<FormatHarness> = RefCell::new(FormatHarness::reserve(Language::Python));

    static PARSE: RefCell<ParseHarness<PythonKind>> =
        RefCell::new(ParseHarness::reserve(&LIMITS_DEFAULT));
}

fuzz_target!(|data: &[u8]| {
    PARSE.with(|harness| harness.borrow_mut().check(&PYTHON, classify, parse::build, data));
    FORMAT.with(|harness| harness.borrow_mut().check(data));
});
