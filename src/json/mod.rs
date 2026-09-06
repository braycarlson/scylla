pub mod read;
pub mod rpc;
pub mod write;

pub use read::{Cursor, Document, Node, Outcome};
pub use write::Writer;

pub const DEPTH_MAX: u32 = 64;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Kind {
    Array,
    False,
    Null,
    Number,
    Object,
    String,
    True,
}

impl Kind {
    pub const fn is_container(self) -> bool {
        matches!(self, Self::Array | Self::Object)
    }

    pub const fn name(self) -> &'static str {
        match self {
            Self::Array => "array",
            Self::False => "false",
            Self::Null => "null",
            Self::Number => "number",
            Self::Object => "object",
            Self::String => "string",
            Self::True => "true",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_kind_names_itself_and_knows_whether_it_holds_children() {
        assert_eq!(Kind::Array.name(), "array");
        assert_eq!(Kind::Null.name(), "null");
        assert!(Kind::Array.is_container());
        assert!(Kind::Object.is_container());
        assert!(!Kind::String.is_container());
    }
}
