use core::mem::{ManuallyDrop, MaybeUninit};
use core::ptr::NonNull;
use std::thread::{Builder, available_parallelism, scope};

use crate::allocation;
use crate::bounded::count_of;

pub const RESERVE_STACK_BYTES: usize = 1 << 26;
const COUNT_PER_THREAD: u32 = 64;
const COUNT_SERIAL_MAX: u32 = 256;
const STACK_DEFAULT: usize = 0;
const THREAD_COUNT_MAX: u32 = 12;

struct Strided<T> {
    base: NonNull<MaybeUninit<T>>,
    count: u32,
}

unsafe impl<T: Send> Sync for Strided<T> {}

pub fn striped<T, F>(count: u32, build: F) -> Vec<T>
where
    T: Send,
    F: Fn(u32) -> T + Sync,
{
    built(STACK_DEFAULT, count, &build)
}

pub fn striped_into<T, F, S>(stack_bytes: usize, count: u32, build: F, mut take: S)
where
    T: Send,
    F: Fn(u32) -> T + Sync,
    S: FnMut(T),
{
    for value in built(stack_bytes, count, &build) {
        take(value);
    }
}

fn built<T, F>(stack_bytes: usize, count: u32, build: &F) -> Vec<T>
where
    T: Send,
    F: Fn(u32) -> T + Sync,
{
    assert!(!allocation::is_frozen());

    let deep = stack_bytes != STACK_DEFAULT;

    let threads = if deep {
        reserve_thread_count_of(count)
    } else {
        thread_count_of(count)
    };

    if threads <= 1 && !deep {
        return stripe_of(count, 1, 0, build);
    }

    let mut values: Vec<MaybeUninit<T>> = Vec::with_capacity(count as usize);

    unsafe {
        values.set_len(count as usize);
    }

    let Some(base) = NonNull::new(values.as_mut_ptr()) else {
        panic!("a reserved vector hands back a non-null base")
    };

    let target = Strided { base, count };

    scope(|runners| {
        let mut handles = Vec::with_capacity(threads as usize);

        for thread in 0..threads {
            let held = &target;
            let builder = build;

            let work = move || {
                let mut index = thread;

                while index < count {
                    assert!(index < held.count);

                    let slot = unsafe { held.base.add(index as usize) };

                    unsafe {
                        slot.write(MaybeUninit::new(builder(index)));
                    }

                    index = index.saturating_add(threads);
                }
            };

            if stack_bytes == STACK_DEFAULT {
                handles.push(runners.spawn(work));

                continue;
            }

            let Ok(handle) = Builder::new()
                .stack_size(stack_bytes)
                .spawn_scoped(runners, work)
            else {
                panic!("a striped reservation thread spawns")
            };

            handles.push(handle);
        }

        for handle in handles {
            let Ok(()) = handle.join() else {
                panic!("a builder thread panicked")
            };
        }
    });

    let mut hold = ManuallyDrop::new(values);
    let filled =
        unsafe { Vec::from_raw_parts(hold.as_mut_ptr().cast::<T>(), hold.len(), hold.capacity()) };

    assert_eq!(count_of(filled.len()), count);

    filled
}

fn stripe_of<T, F>(count: u32, threads: u32, thread: u32, build: &F) -> Vec<T>
where
    F: Fn(u32) -> T,
{
    assert!(threads > 0);
    assert!(thread < threads);

    let length = count.saturating_sub(thread).div_ceil(threads.max(1));
    let mut values = Vec::with_capacity(length as usize);
    let mut index = thread;

    while index < count {
        values.push(build(index));

        index = index.saturating_add(threads);
    }

    assert_eq!(count_of(values.len()), length);

    values
}

fn reserve_thread_count_of(count: u32) -> u32 {
    let available =
        available_parallelism().map_or(1, |held| u32::try_from(held.get()).unwrap_or(1));

    count.min(available.clamp(1, THREAD_COUNT_MAX)).max(1)
}

fn thread_count_of(count: u32) -> u32 {
    if count <= COUNT_SERIAL_MAX {
        return 1;
    }

    let available =
        available_parallelism().map_or(1, |held| u32::try_from(held.get()).unwrap_or(1));
    let wanted = count.div_ceil(COUNT_PER_THREAD).max(2);

    available.clamp(1, THREAD_COUNT_MAX).min(wanted)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_empty_count_builds_nothing() {
        let values = striped(0, |index| index);

        assert!(values.is_empty());
    }

    #[test]
    fn a_small_count_stays_serial_and_ordered() {
        let values = striped(COUNT_SERIAL_MAX, |index| index);

        assert_eq!(count_of(values.len()), COUNT_SERIAL_MAX);
        assert!(
            values
                .iter()
                .enumerate()
                .all(|(at, held)| count_of(at) == *held)
        );
    }

    #[test]
    fn a_sink_takes_every_value_a_deep_stack_built() {
        let count = COUNT_SERIAL_MAX * 4 + 1;
        let mut seen = Vec::new();

        striped_into(
            RESERVE_STACK_BYTES,
            count,
            |index| (index, index * 2),
            |pair| seen.push(pair),
        );

        assert_eq!(count_of(seen.len()), count);

        assert!(
            seen.iter()
                .enumerate()
                .all(|(at, held)| *held == (count_of(at), count_of(at) * 2))
        );
    }

    #[test]
    fn a_large_count_stripes_and_weaves_in_order() {
        let count = COUNT_SERIAL_MAX * 8 + 3;
        let values = striped(count, |index| u64::from(index) * 3);

        assert_eq!(count_of(values.len()), count);

        assert!(
            values
                .iter()
                .enumerate()
                .all(|(at, held)| u64::from(count_of(at)) * 3 == *held)
        );
    }
}
