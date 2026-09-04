use core::sync::atomic::{AtomicU32, Ordering};
use std::thread::scope;

use scylla::pool::Pool;

const COUNT: u32 = 16;
const POOLS: u32 = 12;
const ROUNDS: u32 = 64;
const WORKERS: u32 = 8;

struct Tally {
    seen: Vec<AtomicU32>,
}

fn tally(count: u32) -> Tally {
    let mut seen = Vec::new();

    for _ in 0..count {
        seen.push(AtomicU32::new(0));
    }

    Tally { seen }
}

fn mark(task: &Tally, index: u32) {
    let Some(counter) = task.seen.get(index as usize) else {
        return;
    };

    counter.fetch_add(1, Ordering::Relaxed);
}

fn paired(pool: &Pool, round: u32) {
    let first = tally(COUNT);

    pool.run(&first, COUNT, mark);

    for (index, counter) in first.seen.iter().enumerate() {
        assert_eq!(
            counter.load(Ordering::Relaxed),
            1,
            "round {round} skipped index {index} of the first run"
        );
    }

    drop(first);

    let second = tally(COUNT);

    pool.run(&second, COUNT, mark);

    for (index, counter) in second.seen.iter().enumerate() {
        assert_eq!(
            counter.load(Ordering::Relaxed),
            1,
            "round {round} skipped index {index} of the second run"
        );
    }
}

#[test]
fn a_run_never_loses_an_index_to_a_worker_still_waking_from_the_run_before() {
    scope(|held| {
        for _ in 0..POOLS {
            held.spawn(|| {
                let pool = Pool::reserve(WORKERS);

                for round in 0..ROUNDS {
                    paired(&pool, round);
                }

                pool.stop();
            });
        }
    });
}
