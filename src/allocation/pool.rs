use core::alloc::{GlobalAlloc as _, Layout};
use core::cell::Cell;
use core::num::NonZero;
use core::ptr::{NonNull, null_mut};
use core::sync::atomic::{AtomicPtr, Ordering};
use std::alloc::System;
use std::sync::Once;

const POOL_ALIGN_MAX: usize = 64;
const POOL_BYTES: usize = 1 << 31;
const POOL_CHUNK_BYTES: usize = 1 << 18;
const POOL_CLAIM_ATTEMPT_MAX: u32 = 1_024;

static POOL_BASE: AtomicPtr<u8> = AtomicPtr::new(null_mut());
static POOL_INIT: Once = Once::new();
static POOL_NEXT: AtomicPtr<u8> = AtomicPtr::new(null_mut());

thread_local! {
    static POOL_CHUNK_END: Cell<usize> = const { Cell::new(0) };
    static POOL_CHUNK_NEXT: Cell<Option<NonNull<u8>>> = const { Cell::new(None) };
}

pub(super) fn claim(layout: Layout) -> Option<NonNull<u8>> {
    if layout.align() > POOL_ALIGN_MAX {
        return None;
    }

    if layout.size() > POOL_CHUNK_BYTES {
        return reserve(layout.size(), layout.align());
    }

    let claimed = POOL_CHUNK_NEXT.try_with(|chunk_next| {
        let held = POOL_CHUNK_END.try_with(|chunk_end| chunk_claim(layout, chunk_next, chunk_end));

        held.unwrap_or(None)
    });

    match claimed {
        Ok(held) => held,
        Err(_) => reserve(layout.size(), layout.align()),
    }
}

pub(super) fn holds(held: NonNull<u8>) -> bool {
    let Some(base) = NonNull::new(POOL_BASE.load(Ordering::Acquire)) else {
        return false;
    };

    let start = base.addr().get();
    let address = held.addr().get();

    address >= start && address < start.saturating_add(POOL_BYTES)
}

fn base() -> Option<NonNull<u8>> {
    if cfg!(not(target_pointer_width = "64")) || cfg!(miri) {
        return None;
    }

    POOL_INIT.call_once(|| {
        let Ok(layout) = Layout::from_size_align(POOL_BYTES, POOL_ALIGN_MAX) else {
            return;
        };

        let pointer = unsafe { System.alloc(layout) };

        if pointer.is_null() {
            return;
        }

        POOL_NEXT.store(pointer, Ordering::Release);
        POOL_BASE.store(pointer, Ordering::Release);
    });

    NonNull::new(POOL_BASE.load(Ordering::Acquire))
}

fn chunk_claim(
    layout: Layout,
    chunk_next: &Cell<Option<NonNull<u8>>>,
    chunk_end: &Cell<usize>,
) -> Option<NonNull<u8>> {
    let mask = layout.align().saturating_sub(1);

    if let Some(cursor) = chunk_next.get() {
        let aligned = cursor.addr().get().saturating_add(mask) & !mask;
        let after = aligned.saturating_add(layout.size());

        if after <= chunk_end.get() {
            chunk_next.set(shifted(cursor, after));

            return shifted(cursor, aligned);
        }
    }

    let fresh = reserve(POOL_CHUNK_BYTES, POOL_ALIGN_MAX)?;
    let start = fresh.addr().get();

    chunk_next.set(shifted(fresh, start.saturating_add(layout.size())));
    chunk_end.set(start.saturating_add(POOL_CHUNK_BYTES));

    Some(fresh)
}

fn shifted(held: NonNull<u8>, address: usize) -> Option<NonNull<u8>> {
    Some(held.with_addr(NonZero::new(address)?))
}

fn reserve(bytes: usize, align: usize) -> Option<NonNull<u8>> {
    let base = base()?;
    let end = base.addr().get().saturating_add(POOL_BYTES);
    let mut next = POOL_NEXT.load(Ordering::Relaxed);

    for _ in 0..POOL_CLAIM_ATTEMPT_MAX {
        let mask = align.saturating_sub(1);
        let aligned = next.addr().saturating_add(mask) & !mask;
        let claimed = aligned.saturating_add(bytes);

        if claimed > end {
            return None;
        }

        let taken = next.with_addr(claimed);

        match POOL_NEXT.compare_exchange_weak(next, taken, Ordering::AcqRel, Ordering::Relaxed) {
            Ok(_) => return NonNull::new(next.with_addr(aligned)),
            Err(seen) => next = seen,
        }
    }

    None
}
