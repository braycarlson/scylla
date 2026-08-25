struct Holder {
    field: usize,
}

fn run() -> usize {
    let held = Holder { field: 1 };

    held.field
}

fn reach() -> usize {
    crate::run();
    super::run();
    std::mem::size_of::<usize>();

    missing()
}

fn stored(mut held: usize) -> usize {
    held = 2;

    held
}
