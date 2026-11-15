fn run(one: usize, two: usize) -> usize {
    let held = one;
    let held = held + two;
    let (left, right) = (held, one);

    {
        let left = right;

        return left;
    }
}

fn shadow() -> usize {
    let held = 1;
    let held = held;

    held
}

fn guarded(value: Option<usize>) -> usize {
    let Some(found) = value else {
        return 0;
    };

    if let Some(inner) = value {
        return inner + found;
    }

    match value {
        Some(one) => one,
        None => 0,
    }
}

fn walked(items: &[usize]) -> usize {
    let mut total = 0;

    for item in items {
        total += item;
    }

    total
}

fn closed(one: usize) -> usize {
    let held = move |two: usize| one + two;

    held(1)
}
