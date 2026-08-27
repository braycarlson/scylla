auto trait Bare {}

pub struct Wide<const WIDE: bool = false> {
    held: bool,
}

pub struct Counted<const COUNT: usize = 0> {
    held: bool,
}

pub const extern "C" fn abi() {}

pub fn nested() {
    const unsafe fn inner(value: usize) -> usize {
        value
    }
}

pub fn ranged(held: &[u32]) {
    for index in .. {}

    let counted = const || 1;
}

pub trait Aliased {
    type Value
    where
        Self: Sized;
}

impl Aliased for Thing {
    type Value = u32
    where
        Self: Sized;
}
