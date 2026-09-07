use std::time::Instant;

#[derive(Clone, Copy, Debug)]
pub struct Clock {
    started: Instant,
}

impl Clock {
    pub fn nanoseconds(&self) -> u64 {
        let elapsed = self.started.elapsed().as_nanos();

        assert!(elapsed <= u128::from(u64::MAX));

        u64::try_from(elapsed).unwrap_or(u64::MAX)
    }

    pub fn start() -> Self {
        Self {
            started: Instant::now(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_clock_reads_forward_on_a_frozen_thread() {
        crate::allocation::frozen(|| {
            let clock = Clock::start();
            let first = clock.nanoseconds();
            let second = clock.nanoseconds();

            assert!(first <= second);
            assert!(second < u64::MAX);
        });
    }
}
