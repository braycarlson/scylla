fn run(limit: usize) -> usize {
    let mut held = 0;

    'outer: loop {
        'inner: while held < limit {
            for item in 0..limit {
                if item > 2 {
                    break 'outer;
                }

                if item > 1 {
                    continue 'inner;
                }
            }

            held += 1;
        }

        break;
    }

    held
}
