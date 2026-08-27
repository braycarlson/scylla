#![no_main]

use std::cell::RefCell;

use libfuzzer_sys::fuzz_target;
use scylla::fuzzing::format::FormatHarness;
use scylla::fuzzing::parse::{LIMITS_DEFAULT, ParseHarness};
use scylla::language::Language;
use scylla::lex::ZIG;
use scylla::syntax::zig::classify::classify;
use scylla::syntax::zig::kind::ZigKind;
use scylla::syntax::zig::parse;

thread_local! {
    static FORMAT: RefCell<FormatHarness> = RefCell::new(FormatHarness::reserve(Language::Zig));

    static PARSE: RefCell<ParseHarness<ZigKind>> =
        RefCell::new(ParseHarness::reserve(&LIMITS_DEFAULT));
}

fuzz_target!(|data: &[u8]| {
    PARSE.with(|harness| harness.borrow_mut().check(&ZIG, classify, parse::build, data));
    FORMAT.with(|harness| harness.borrow_mut().check(data));
});
