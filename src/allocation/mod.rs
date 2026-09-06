mod global;
mod pool;

use core::cell::Cell;
use core::mem::ManuallyDrop;
use core::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use crate::log_line;

pub use global::GuardAllocator;

pub const SELFTEST_BYTES: usize = 64;

static ALLOCATION_COUNT: AtomicU64 = AtomicU64::new(0);
static FROZEN: AtomicBool = AtomicBool::new(false);
static HEAP_BYTES_ALLOCATED: AtomicU64 = AtomicU64::new(0);
static HEAP_BYTES_RELEASED: AtomicU64 = AtomicU64::new(0);
static STOOD_DOWN: AtomicBool = AtomicBool::new(false);

thread_local! {
    static FROZEN_THREAD: Cell<bool> = const { Cell::new(false) };
    static REPORTING: Cell<bool> = const { Cell::new(false) };
}

#[cfg(test)]
thread_local! {
    static REPORT_ALLOCATES: Cell<bool> = const { Cell::new(false) };
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Selftest {
    Allocate,
    Deallocate,
    Panic,
    Reallocate,
}

#[derive(Clone, Copy, Debug)]
pub struct Report {
    pub allocation_count: u64,
    pub heap_bytes_allocated: u64,
    pub heap_bytes_live: u64,
}

pub fn freeze() {
    let frozen_already = FROZEN.swap(true, Ordering::SeqCst);

    assert!(!frozen_already);
    assert!(is_frozen());
}

pub fn is_frozen() -> bool {
    FROZEN.load(Ordering::Relaxed)
}

pub fn report() -> Report {
    let heap_bytes_live = heap_bytes_live();
    let heap_bytes_allocated = HEAP_BYTES_ALLOCATED.load(Ordering::Relaxed);

    assert!(heap_bytes_allocated >= heap_bytes_live);

    Report {
        allocation_count: ALLOCATION_COUNT.load(Ordering::Relaxed),
        heap_bytes_allocated,
        heap_bytes_live,
    }
}

pub fn stand_down() {
    STOOD_DOWN.store(true, Ordering::SeqCst);

    assert!(exempt());
}

pub fn selftest_reserve() -> ManuallyDrop<Vec<u8>> {
    assert!(!is_frozen());

    let buffer = vec![0_u8; SELFTEST_BYTES];

    assert_eq!(buffer.len(), SELFTEST_BYTES);
    assert_eq!(buffer.capacity(), SELFTEST_BYTES);

    ManuallyDrop::new(buffer)
}

pub fn selftest_run(case: Selftest, buffer: &mut ManuallyDrop<Vec<u8>>) {
    assert!(is_frozen());
    assert_eq!(buffer.len(), SELFTEST_BYTES);

    match case {
        Selftest::Allocate => {
            let reserved = ManuallyDrop::new(Vec::<u8>::with_capacity(SELFTEST_BYTES));

            core::hint::black_box(&reserved);
        }
        Selftest::Deallocate => unsafe { ManuallyDrop::drop(buffer) },
        Selftest::Panic => panic!("selftest panic after freeze"),
        Selftest::Reallocate => buffer.reserve(1),
    }
}

fn account_allocated(bytes: usize) {
    ALLOCATION_COUNT.fetch_add(1, Ordering::Relaxed);
    HEAP_BYTES_ALLOCATED.fetch_add(bytes as u64, Ordering::Relaxed);
}

fn account_released(bytes: usize) {
    HEAP_BYTES_RELEASED.fetch_add(bytes as u64, Ordering::Relaxed);
}

fn exempt() -> bool {
    STOOD_DOWN.load(Ordering::Relaxed) || std::thread::panicking()
}

fn guard(operation: &'static str, bytes: usize) {
    if !is_frozen_here() || exempt() {
        return;
    }

    let Some(_report) = ReportScope::enter() else {
        return;
    };

    violation_report(operation, bytes);
    thread_disarm();

    panic!("{operation} of {bytes} bytes after freeze");
}

fn thread_disarm() {
    let _ = FROZEN_THREAD.try_with(|frozen| frozen.set(false));
}

fn heap_bytes_live() -> u64 {
    let released = HEAP_BYTES_RELEASED.load(Ordering::Relaxed);
    let allocated = HEAP_BYTES_ALLOCATED.load(Ordering::Relaxed);

    assert!(allocated >= released);

    allocated - released
}

pub fn is_frozen_here() -> bool {
    is_frozen() || FROZEN_THREAD.try_with(Cell::get).unwrap_or(false)
}

fn violation_report(operation: &str, bytes: usize) {
    #[cfg(test)]
    report_probe();

    log_line!("allocation guard tripped: {operation} of {bytes} bytes after freeze");
}

#[cfg(test)]
fn report_arm(armed: bool) {
    REPORT_ALLOCATES.with(|allocates| allocates.set(armed));
}

#[cfg(test)]
fn report_probe() {
    let allocates = REPORT_ALLOCATES.try_with(Cell::get).unwrap_or(false);

    if allocates {
        drop(core::hint::black_box(Vec::<u8>::with_capacity(48)));
    }
}

struct ReportScope;

impl ReportScope {
    fn enter() -> Option<Self> {
        let entered = REPORTING
            .try_with(|reporting| {
                if reporting.get() {
                    return false;
                }

                reporting.set(true);

                true
            })
            .unwrap_or(false);

        if !entered {
            return None;
        }

        Some(Self)
    }
}

impl Drop for ReportScope {
    fn drop(&mut self) {
        let _ = REPORTING.try_with(|reporting| reporting.set(false));
    }
}

pub struct FreezeScope;

impl Drop for FreezeScope {
    fn drop(&mut self) {
        FROZEN_THREAD.with(|frozen| frozen.set(false));
    }
}

pub fn frozen<T>(run: impl FnOnce() -> T) -> T {
    let scope = freeze_scope();
    let value = run();

    drop(scope);

    value
}

pub fn freeze_scope() -> FreezeScope {
    assert!(!is_frozen_here());

    FROZEN_THREAD.with(|frozen| frozen.set(true));

    assert!(is_frozen_here());

    FreezeScope
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[cfg_attr(
        optimized,
        ignore = "an optimized build cannot catch a panic raised inside the allocator"
    )]
    #[cfg_attr(
        miri,
        ignore = "miri reads the guard panic inside GlobalAlloc as unwinding past a nounwind frame"
    )]
    fn allocation_after_scoped_freeze_panics() {
        let outcome = std::panic::catch_unwind(|| {
            let _scope = freeze_scope();

            drop(core::hint::black_box(Vec::<u8>::with_capacity(32)));
        });

        assert!(outcome.is_err());
        assert!(!is_frozen_here());
    }

    #[test]
    #[cfg_attr(
        optimized,
        ignore = "an optimized build cannot catch a panic raised inside the allocator"
    )]
    #[cfg_attr(
        miri,
        ignore = "miri reads the guard panic inside GlobalAlloc as unwinding past a nounwind frame"
    )]
    fn deallocation_after_scoped_freeze_panics() {
        let buffer = vec![0_u8; 32];

        let outcome = std::panic::catch_unwind(move || {
            let _scope = freeze_scope();

            drop(buffer);
        });

        assert!(outcome.is_err());
        assert!(!is_frozen_here());
    }

    #[test]
    #[cfg_attr(
        optimized,
        ignore = "an optimized build cannot catch a panic raised inside the allocator"
    )]
    #[cfg_attr(
        miri,
        ignore = "miri reads the guard panic inside GlobalAlloc as unwinding past a nounwind frame"
    )]
    fn a_report_that_allocates_does_not_re_enter_the_guard() {
        report_arm(true);

        let outcome = std::panic::catch_unwind(|| {
            let _scope = freeze_scope();

            drop(core::hint::black_box(Vec::<u8>::with_capacity(32)));
        });

        report_arm(false);

        assert!(outcome.is_err());
        assert!(!is_frozen_here());
    }

    #[test]
    fn allocation_outside_scoped_freeze_is_permitted() {
        {
            let _scope = freeze_scope();

            assert!(is_frozen_here());
        }

        let buffer = core::hint::black_box(Vec::<u8>::with_capacity(32));

        assert_eq!(buffer.capacity(), 32);
        assert!(!is_frozen_here());
    }

    #[test]
    fn report_scope_is_reentrant_safe() {
        let outer = ReportScope::enter();
        let inner = ReportScope::enter();

        assert!(outer.is_some());
        assert!(inner.is_none());

        drop(inner);

        assert!(ReportScope::enter().is_none());

        drop(outer);

        assert!(ReportScope::enter().is_some());
    }

    #[test]
    fn report_stays_coherent() {
        let report = report();

        assert!(report.heap_bytes_allocated >= report.heap_bytes_live);
        assert!(report.allocation_count > 0);
    }
}
