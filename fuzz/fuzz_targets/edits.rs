#![no_main]

use std::cell::RefCell;

use libfuzzer_sys::fuzz_target;
use scylla::fuzzing::edits::EditHarness;

thread_local! {
    static HARNESS: RefCell<EditHarness> = RefCell::new(EditHarness::reserve());
}

fuzz_target!(|data: &[u8]| {
    HARNESS.with(|harness| harness.borrow_mut().check(data));
});
