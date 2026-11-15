fn plain() {}

fn arguments(one: u32, two: &str, three: &mut [u8]) {}

fn returning() -> u32 {
    1
}

pub const fn constant() -> u32 {
    1
}

pub async unsafe fn awaited() {}

pub extern "C" fn external() {}

fn generic<T, U: Clone, const N: usize>(one: T, two: U) -> [T; N]
where
    T: Copy,
    U: Into<T>,
{
    todo!()
}

fn lifetimes<'a, 'b: 'a>(one: &'a str, two: &'b str) -> &'a str {
    one
}

fn patterns((one, two): (u32, u32), Held { held }: Held, [a, b]: [u32; 2]) {}

fn returns_impl() -> impl Iterator<Item = u32> {
    todo!()
}

fn takes_fn(held: fn(u32) -> u32, other: &dyn Fn(u32) -> u32) {}

struct Held {
    held: u32,
}

impl Held {
    fn receiver(self) {}

    fn borrowed(&self) {}

    fn mutable(&mut self) {}

    fn lifetime<'a>(&'a self) -> &'a u32 {
        &self.held
    }
}

fn outlives<'a, 'b>(held: &'a u8)
where
    'a: 'b,
{
}
