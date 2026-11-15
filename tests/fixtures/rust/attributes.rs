#![allow(dead_code)]

/// A documented struct.
///
/// With more lines.
#[derive(Debug, Clone, PartialEq)]
#[repr(C)]
pub struct Documented {
    /// A documented field.
    #[allow(dead_code)]
    pub held: u32,
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_test_runs() {
        assert_eq!(1, 1);
    }
}

#[inline]
#[must_use]
pub fn annotated() -> u32 {
    1
}

pub enum Marked {
    /// A documented variant.
    #[non_exhaustive]
    One,
}

#[doc = "A documented struct."]
pub struct Documented;
