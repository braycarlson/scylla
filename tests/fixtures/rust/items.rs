use std::collections::HashMap;
use std::fmt::{self, Debug, Display as Shown};
use std::io::*;
use crate::inner::nested::Held;

pub const LIMIT: usize = 8;
static NAMES: [&str; 2] = ["one", "two"];
pub static mut COUNT: u32 = 0;
type Pair = (u32, u32);
pub type Mapping<K> = HashMap<K, u32>;

pub mod inner {
    pub mod nested {
        pub struct Held;
    }

    pub(crate) fn hidden() {}
}

extern crate alloc;

unsafe extern "C" {
    pub fn external(one: u32) -> u32;
    pub static ERRNO: u32;
}

pub struct Unit;
pub struct Tuple(pub u32, String);

pub struct Named {
    pub one: u32,
    two: Vec<String>,
}

pub enum Choice {
    One,
    Two(u32),
    Three { held: bool },
    Four = 4,
}

pub union Bits {
    one: u32,
    two: f32,
}

pub trait Named2: Debug {
    type Output;

    const LIMIT: usize;

    fn name(&self) -> String;

    fn other(&self) -> u32 {
        0
    }
}

impl Named2 for Unit {
    type Output = u32;

    const LIMIT: usize = 1;

    fn name(&self) -> String {
        String::new()
    }
}

impl Unit {
    pub fn make() -> Self {
        Self
    }
}

unsafe extern "C" {
    type Opaque;

    fn printf(format: *const u8, ...);

    held!();
}

trait Held = Clone + Send;

pub trait Bounded<T> = Clone + Send where T: Copy;
