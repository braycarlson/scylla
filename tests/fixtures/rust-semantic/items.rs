const TOP: usize = SIZE;

static NAME: &str = "scylla";

struct Holder {
    field: usize,
}

struct Wrapper(usize);

enum Shade {
    Light,
    Dark(u8),
}

union Bits {
    one: u8,
}

trait Speak {
    const LOUD: bool;

    type Out;

    fn speak(&self) -> Self::Out;
}

impl Speak for Holder {
    const LOUD: bool = true;

    type Out = usize;

    fn speak(&self) -> Self::Out {
        self.field
    }
}

type Alias = Holder;

mod inner {
    pub const SIZE: usize = 4;

    pub fn size() -> usize {
        SIZE
    }
}

const SIZE: usize = 8;

fn build() -> Wrapper {
    Wrapper(TOP)
}
