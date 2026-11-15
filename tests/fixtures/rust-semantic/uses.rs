use std::collections::HashMap;
use std::io::{Read as Load, Write};
use std::fmt::*;
pub use std::mem::swap;
use crate::inner::Held;
use self::inner::Kept;

extern crate serde;

mod inner {
    pub struct Held;

    pub struct Kept;
}

fn run(map: HashMap, sink: Write, held: Held) -> Load {
    swap(map, sink);

    Kept
}

fn maybe() -> usize {
    unknown()
}
