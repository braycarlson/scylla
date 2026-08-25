struct Held<'a, T, const N: usize> {
    reference: &'a str,
    mutable: &'a mut T,
    pointer: *const u8,
    mutable_pointer: *mut u8,
    slice: &'a [u8],
    array: [u8; N],
    tuple: (u32, u8),
    unit: (),
    parenthesized: (u32),
    path: std::collections::HashMap<u32, T>,
    generic: Vec<Vec<Option<T>>>,
    associated: <T as Iterator>::Item,
    function: fn(u32, u8) -> u32,
    unsafe_function: unsafe extern "C" fn(u32) -> u32,
    boxed: Box<dyn Iterator<Item = u32> + Send + 'a>,
    implemented: T,
    inferred: Vec<_>,
    higher: Box<dyn for<'b> Fn(&'b str)>,
}

fn never() -> ! {
    panic!()
}

fn bounded<T: Clone + Send + ?Sized>(held: &T) {}

type Pointer = extern "C" fn(...);

fn constrained<T: Iterator<Item: Clone>>(held: T) {}

fn counted<T: Held<LIMIT = 3>>() {}

fn captured<T>(held: T) -> impl Iterator<Item = T> + use<T> {
    core::iter::once(held)
}

fn borrowed<'a, T>(held: &'a T) -> impl Iterator<Item = &'a T> + use<'a, T> {
    core::iter::once(held)
}
