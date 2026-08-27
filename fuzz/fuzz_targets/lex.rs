#![no_main]

use std::cell::RefCell;

use libfuzzer_sys::fuzz_target;
use scylla::fuzzing::LexHarness;

const TOKEN_COUNT_MAX: u32 = 1 << 16;

thread_local! {
    static HARNESS: RefCell<LexHarness> = RefCell::new(LexHarness::reserve(TOKEN_COUNT_MAX));
}

fuzz_target!(|data: &[u8]| {
    let Some((selector, source)) = data.split_first() else {
        return;
    };

    HARNESS.with(|harness| harness.borrow_mut().check(usize::from(*selector), source));
});
