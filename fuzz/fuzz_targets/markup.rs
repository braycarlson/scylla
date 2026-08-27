#![no_main]

use std::cell::RefCell;

use libfuzzer_sys::fuzz_target;
use scylla::fuzzing::markup::{LIMITS_DEFAULT, MarkupHarness};

thread_local! {
    static HARNESS: RefCell<MarkupHarness> = RefCell::new(MarkupHarness::reserve(&LIMITS_DEFAULT));
}

fuzz_target!(|data: &[u8]| {
    HARNESS.with(|harness| harness.borrow_mut().check(data));
});
