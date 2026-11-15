struct Holder<T> {
    field: T,
}

struct Other<T> {
    field: T,
}

impl<T> Holder<T> {
    fn new(field: T) -> Self {
        Holder { field }
    }
}

trait Speak<'a, T> {
    fn speak(&'a self, held: T) -> T;
}

fn work<'a, T: Speak<'a, usize>, const N: usize>(one: T, two: &'a str) -> usize {
    let held = N;

    one.speak(held);

    two.len()
}

type Pair<'a, T> = (&'a T, T);
