#![expect(
    clippy::panic,
    reason = "a poisoned pool cannot be recovered from, only reported"
)]
#![expect(
    clippy::transmutes_expressible_as_ptr_casts,
    reason = "the `as` cast clippy suggests instead is disallowed in every crate that runs after \
              the freeze"
)]

use core::mem::transmute;
use core::ptr::{NonNull, null_mut};
use core::sync::atomic::{AtomicBool, AtomicPtr, AtomicU32, AtomicU64, Ordering};
use core::time::Duration;
use std::sync::{Condvar, Mutex};
use std::thread::{JoinHandle, spawn};

pub const WORKER_COUNT_MAX: u32 = 64;
const CLAIM_GENERATION_SHIFT: u32 = 32;
const CLAIM_INDEX_MASK: u64 = 0xFFFF_FFFF;
const DRAIN_WAIT_MICROS: u64 = 100;

type Trampoline = fn(NonNull<()>, u32, u32);

struct Shared {
    claim: AtomicU64,
    count: AtomicU32,
    done: AtomicU32,
    generation: AtomicU64,
    lock: Mutex<()>,
    ready: Condvar,
    retired: Condvar,
    started: AtomicU32,
    stopping: AtomicBool,
    task: AtomicPtr<()>,
    trampoline: AtomicPtr<()>,
}

struct Job<'task, T> {
    body: fn(&T, u32),
    task: &'task T,
}

struct StatefulJob<'task, T, S> {
    body: fn(&T, &mut S, u32),
    state_count: u32,
    states: NonNull<S>,
    task: &'task T,
}

pub struct Pool {
    shared: &'static Shared,
    workers: Vec<JoinHandle<()>>,
}

impl<T> Job<'_, T>
where
    T: Sync,
{
    fn run(&self, index: u32) {
        (self.body)(self.task, index);
    }
}

impl<T, S> StatefulJob<'_, T, S>
where
    T: Sync,
    S: Send,
{
    fn run(&self, worker: u32, index: u32) {
        assert!(worker < self.state_count, "every runner owns a state slot");

        let Ok(slot) = usize::try_from(worker) else {
            panic!("a worker index fits in a usize")
        };

        let mut held = unsafe { self.states.add(slot) };
        let state = unsafe { held.as_mut() };

        (self.body)(self.task, state, index);
    }
}

impl Pool {
    fn await_start(&self, worker_count: u32) {
        assert!(worker_count > 0, "a pool spawns at least one worker");

        let Ok(taken) = self.shared.lock.lock() else {
            panic!("a worker panicked before it reached its loop")
        };

        let Ok((mut held, _out)) = self.shared.retired.wait_timeout(taken, Duration::ZERO) else {
            panic!("a worker panicked before it reached its loop")
        };

        while self.shared.started.load(Ordering::Acquire) < worker_count {
            let Ok(waited) = self.shared.retired.wait(held) else {
                panic!("a worker panicked before it reached its loop")
            };

            held = waited;
        }

        drop(held);

        assert_eq!(self.shared.started.load(Ordering::Acquire), worker_count);
    }

    fn drain_until(&self, count: u32, drain: &mut impl FnMut() -> bool) {
        loop {
            if drain() {
                return;
            }

            let Ok(held) = self.shared.lock.lock() else {
                panic!("a worker panicked and poisoned the pool")
            };

            if self.shared.done.load(Ordering::Acquire) < count {
                let Ok((_waited, _out)) = self
                    .shared
                    .retired
                    .wait_timeout(held, Duration::from_micros(DRAIN_WAIT_MICROS))
                else {
                    panic!("a worker panicked and poisoned the pool")
                };
            }
        }
    }

    fn launch(&self, erased: NonNull<()>, carried: Trampoline, count: u32) {
        let generation = self.publish(erased, carried, count);

        claim_and_run(self.shared, generation, count, self.count());

        self.retire(count);
    }

    fn publish(&self, erased: NonNull<()>, carried: Trampoline, count: u32) -> u64 {
        let erased_body: *mut () = unsafe { transmute::<Trampoline, *mut ()>(carried) };

        self.shared.task.store(erased.as_ptr(), Ordering::Release);
        self.shared.trampoline.store(erased_body, Ordering::Release);
        self.shared.count.store(count, Ordering::Release);
        self.shared.done.store(0, Ordering::Release);

        let Ok(started) = self.shared.lock.lock() else {
            panic!("a worker panicked and poisoned the pool")
        };

        let generation = self
            .shared
            .generation
            .fetch_add(1, Ordering::AcqRel)
            .wrapping_add(1);

        self.shared
            .claim
            .store(tagged(generation), Ordering::Release);

        drop(started);

        self.shared.ready.notify_all();

        generation
    }

    fn retire(&self, count: u32) {
        let Ok(mut held) = self.shared.lock.lock() else {
            panic!("a worker panicked and poisoned the pool")
        };

        while self.shared.done.load(Ordering::Acquire) < count {
            let Ok(waited) = self.shared.retired.wait(held) else {
                panic!("a worker panicked and poisoned the pool")
            };

            held = waited;
        }

        drop(held);

        self.shared.count.store(0, Ordering::Release);
        self.shared.task.store(null_mut(), Ordering::Release);
    }

    fn states_of<S>(&self, states: &mut [S]) -> (NonNull<S>, u32) {
        let Ok(state_count) = u32::try_from(states.len()) else {
            panic!("a state count fits in a u32")
        };

        assert!(
            state_count == self.count().saturating_add(1),
            "one state per spawned worker, plus one for the caller"
        );

        let Some(base) = NonNull::new(states.as_mut_ptr()) else {
            panic!("a state table hands back a non-null base")
        };

        (base, state_count)
    }

    #[inline]
    #[must_use]
    pub fn count(&self) -> u32 {
        u32::try_from(self.workers.len()).unwrap_or(u32::MAX)
    }

    #[inline]
    #[must_use]
    pub fn reserve(worker_count: u32) -> Self {
        assert!(worker_count > 0, "a pool spawns at least one worker");
        assert!(
            worker_count <= WORKER_COUNT_MAX,
            "a pool is bounded at WORKER_COUNT_MAX workers"
        );

        let shared: &'static Shared = Box::leak(Box::new(Shared {
            claim: AtomicU64::new(0),
            count: AtomicU32::new(0),
            done: AtomicU32::new(0),
            generation: AtomicU64::new(0),
            lock: Mutex::new(()),
            ready: Condvar::new(),
            retired: Condvar::new(),
            started: AtomicU32::new(0),
            stopping: AtomicBool::new(false),
            task: AtomicPtr::new(null_mut()),
            trampoline: AtomicPtr::new(null_mut()),
        }));

        let Ok(capacity) = usize::try_from(worker_count) else {
            panic!("a worker count fits in a usize")
        };

        let mut workers = Vec::with_capacity(capacity);

        for index in 0_u32..worker_count {
            workers.push(spawn(move || serve(shared, index)));
        }

        assert!(workers.len() == capacity, "every worker was spawned");

        let pool = Self { shared, workers };

        pool.await_start(worker_count);

        pool
    }

    #[inline]
    pub fn run<T>(&self, task: &T, count: u32, body: fn(&T, u32))
    where
        T: Sync,
    {
        if count == 0 {
            return;
        }

        let job = Job { body, task };
        let erased: NonNull<()> = NonNull::from(&job).cast::<()>();

        self.launch(erased, trampoline::<T>, count);
    }

    #[inline]
    pub fn run_reporting<T>(
        &self,
        task: &T,
        count: u32,
        body: fn(&T, u32),
        mut drain: impl FnMut() -> bool,
    ) where
        T: Sync,
    {
        if count == 0 {
            let _drained = drain();

            return;
        }

        let job = Job { body, task };
        let erased: NonNull<()> = NonNull::from(&job).cast::<()>();
        let _generation = self.publish(erased, trampoline::<T>, count);

        self.drain_until(count, &mut drain);
        self.retire(count);
    }

    #[inline]
    pub fn run_with<T, S>(&self, task: &T, states: &mut [S], count: u32, body: fn(&T, &mut S, u32))
    where
        T: Sync,
        S: Send,
    {
        let (state_base, state_count) = self.states_of(states);

        if count == 0 {
            return;
        }

        let job = StatefulJob {
            body,
            state_count,
            states: state_base,
            task,
        };
        let erased: NonNull<()> = NonNull::from(&job).cast::<()>();

        self.launch(erased, stateful_trampoline::<T, S>, count);
    }

    #[inline]
    pub fn run_with_reporting<T, S>(
        &self,
        task: &T,
        states: &mut [S],
        count: u32,
        body: fn(&T, &mut S, u32),
        mut drain: impl FnMut() -> bool,
    ) where
        T: Sync,
        S: Send,
    {
        let (state_base, state_count) = self.states_of(states);

        if count == 0 {
            let _drained = drain();

            return;
        }

        let job = StatefulJob {
            body,
            state_count,
            states: state_base,
            task,
        };
        let erased: NonNull<()> = NonNull::from(&job).cast::<()>();
        let _generation = self.publish(erased, stateful_trampoline::<T, S>, count);

        self.drain_until(count, &mut drain);
        self.retire(count);
    }

    #[inline]
    pub fn stop(mut self) {
        let Ok(held) = self.shared.lock.lock() else {
            panic!("a worker panicked and poisoned the pool")
        };

        self.shared.stopping.store(true, Ordering::Release);
        self.shared.generation.fetch_add(1, Ordering::AcqRel);

        drop(held);

        self.shared.ready.notify_all();

        while let Some(worker) = self.workers.pop() {
            let joined = worker.join();

            assert!(joined.is_ok(), "a worker left its loop without panicking");
        }
    }
}

fn announce(shared: &'static Shared) {
    let Ok(taken) = shared.lock.lock() else {
        return;
    };

    let Ok((held, _out)) = shared.ready.wait_timeout(taken, Duration::ZERO) else {
        return;
    };

    let seen = shared.started.fetch_add(1, Ordering::AcqRel);

    assert!(
        seen < WORKER_COUNT_MAX,
        "a pool announces at most its workers"
    );

    drop(held);

    shared.retired.notify_all();
}

fn claim_and_run(shared: &'static Shared, generation: u64, count: u32, worker: u32) {
    for _ in 0..count.saturating_add(1) {
        let index = claimed(shared, generation, count);

        if index >= count {
            return;
        }

        let erased_body = shared.trampoline.load(Ordering::Acquire);
        let Some(task) = NonNull::new(shared.task.load(Ordering::Acquire)) else {
            return;
        };

        if erased_body.is_null() {
            return;
        }

        let carried: Trampoline = unsafe { transmute::<*mut (), Trampoline>(erased_body) };

        carried(task, worker, index);

        let finished = shared.done.fetch_add(1, Ordering::AcqRel);

        if finished.saturating_add(1) < count {
            continue;
        }

        let Ok(held) = shared.lock.lock() else {
            return;
        };

        drop(held);

        shared.retired.notify_all();
    }
}

fn claimed(shared: &'static Shared, generation: u64, count: u32) -> u32 {
    let mut state = shared.claim.load(Ordering::Acquire);

    for _ in 0..count.saturating_add(2) {
        if state & !CLAIM_INDEX_MASK != tagged(generation) {
            return count;
        }

        let index = u32::try_from(state & CLAIM_INDEX_MASK).unwrap_or(u32::MAX);

        if index >= count {
            return count;
        }

        let taken = shared.claim.compare_exchange(
            state,
            state.wrapping_add(1),
            Ordering::AcqRel,
            Ordering::Acquire,
        );

        match taken {
            Ok(_) => return index,
            Err(seen) => state = seen,
        }
    }

    panic!("a strong exchange fails only when the claim word moved, and it moves at most once an index")
}

fn serve(shared: &'static Shared, worker: u32) {
    let mut seen = 0_u64;

    announce(shared);

    loop {
        let Ok(mut held) = shared.lock.lock() else {
            return;
        };

        while shared.generation.load(Ordering::Acquire) == seen
            && !shared.stopping.load(Ordering::Acquire)
        {
            let Ok(waited) = shared.ready.wait(held) else {
                return;
            };

            held = waited;
        }

        seen = shared.generation.load(Ordering::Acquire);

        drop(held);

        if shared.stopping.load(Ordering::Acquire) {
            return;
        }

        let count = shared.count.load(Ordering::Acquire);

        claim_and_run(shared, seen, count, worker);
    }
}

const fn tagged(generation: u64) -> u64 {
    (generation & CLAIM_INDEX_MASK) << CLAIM_GENERATION_SHIFT
}

fn stateful_trampoline<T, S>(task: NonNull<()>, worker: u32, index: u32)
where
    T: Sync,
    S: Send,
{
    let held: &StatefulJob<'_, T, S> = unsafe { task.cast::<StatefulJob<'_, T, S>>().as_ref() };

    held.run(worker, index);
}

fn trampoline<T>(task: NonNull<()>, _worker: u32, index: u32)
where
    T: Sync,
{
    let held: &Job<'_, T> = unsafe { task.cast::<Job<'_, T>>().as_ref() };

    held.run(index);
}
