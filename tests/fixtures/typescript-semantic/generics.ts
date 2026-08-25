function identity<Held>(one: Held): Held {
    return one;
}

class Box<Inner> {
    held: Inner;
}

type Pair<Left, Right> = [Left, Right];

const escaped: Held = 1;
