use core::alloc::{GlobalAlloc, Layout};
use core::ptr::{NonNull, copy_nonoverlapping, null_mut};
use std::alloc::System;

use super::pool;
use super::{account_allocated, account_released, guard};

pub struct GuardAllocator;

unsafe impl GlobalAlloc for GuardAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        guard("allocation", layout.size());
        account_allocated(layout.size());

        match pool::claim(layout) {
            Some(pooled) => pooled.as_ptr(),
            None => unsafe { System.alloc(layout) },
        }
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        guard("allocation", layout.size());
        account_allocated(layout.size());

        unsafe { System.alloc_zeroed(layout) }
    }

    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        guard("deallocation", layout.size());
        account_released(layout.size());

        if pooled(pointer) {
            return;
        }

        unsafe { System.dealloc(pointer, layout) }
    }

    unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, bytes_new: usize) -> *mut u8 {
        guard("reallocation", layout.size());
        account_released(layout.size());
        account_allocated(bytes_new);

        if !pooled(pointer) {
            return unsafe { System.realloc(pointer, layout, bytes_new) };
        }

        let Ok(wanted) = Layout::from_size_align(bytes_new, layout.align()) else {
            return null_mut();
        };

        let target = match pool::claim(wanted) {
            Some(held) => held.as_ptr(),
            None => unsafe { System.alloc(wanted) },
        };

        if target.is_null() {
            return null_mut();
        }

        let copied = layout.size().min(bytes_new);

        unsafe {
            copy_nonoverlapping(pointer, target, copied);
        }

        target
    }
}

fn pooled(pointer: *mut u8) -> bool {
    NonNull::new(pointer).is_some_and(pool::holds)
}
