pub mod binding;
pub mod css;
pub mod front;
pub mod go;
pub mod javascript;
pub mod odin;
pub mod python;
pub mod rust;
pub mod typescript;
pub mod view;
pub mod zig;

use crate::bounded::{BoundedVec, Span};

pub use crate::tree::Structure;

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub enum Category {
    Assignment,
    Attribute,
    Block,
    Branch,
    Call,
    Condition,
    Declaration,
    Except,
    Expression,
    File,
    Function,
    Import,
    Lambda,
    Loop,
    Match,
    Name,
    Other,
    Parameter,
    Parameters,
    Return,
    Struct,
    Try,
    Type,
    Value,
}

pub const CATEGORY_COUNT: usize = 24;

static CATEGORIES: [Category; CATEGORY_COUNT] = [
    Category::Assignment,
    Category::Attribute,
    Category::Block,
    Category::Branch,
    Category::Call,
    Category::Condition,
    Category::Declaration,
    Category::Except,
    Category::Expression,
    Category::File,
    Category::Function,
    Category::Import,
    Category::Lambda,
    Category::Loop,
    Category::Match,
    Category::Name,
    Category::Other,
    Category::Parameter,
    Category::Parameters,
    Category::Return,
    Category::Struct,
    Category::Try,
    Category::Type,
    Category::Value,
];

impl Category {
    pub const fn all() -> &'static [Self] {
        &CATEGORIES
    }

    pub const fn index(self) -> usize {
        self as usize
    }

    pub const fn name(self) -> &'static str {
        match self {
            Self::Assignment => "Assignment",
            Self::Attribute => "Attribute",
            Self::Block => "Block",
            Self::Branch => "Branch",
            Self::Call => "Call",
            Self::Condition => "Condition",
            Self::Declaration => "Declaration",
            Self::Except => "Except",
            Self::Expression => "Expression",
            Self::File => "File",
            Self::Function => "Function",
            Self::Import => "Import",
            Self::Lambda => "Lambda",
            Self::Loop => "Loop",
            Self::Match => "Match",
            Self::Name => "Name",
            Self::Other => "Other",
            Self::Parameter => "Parameter",
            Self::Parameters => "Parameters",
            Self::Return => "Return",
            Self::Struct => "Struct",
            Self::Try => "Try",
            Self::Type => "Type",
            Self::Value => "Value",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FactKind {
    ExportAll,
    ExportDefault,
    ExportNamed,
    ImportDefault,
    ImportNamed,
    ImportNamespace,
    ImportSideEffect,
    ImportType,
    Reexport,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Fact {
    pub binding: u32,
    pub kind: FactKind,
    pub local: Span,
    pub remote: Span,
    pub specifier: Span,
}

#[derive(Debug)]
pub struct Facts {
    items: BoundedVec<Fact>,
}

pub fn name_hash(bytes: &[u8]) -> u32 {
    let mut held = 2_166_136_261_u32;

    for byte in bytes {
        held ^= u32::from(*byte);
        held = held.wrapping_mul(16_777_619);
    }

    held
}

impl FactKind {
    pub const fn exports(self) -> bool {
        matches!(
            self,
            Self::ExportAll | Self::ExportDefault | Self::ExportNamed | Self::Reexport
        )
    }

    pub const fn imports(self) -> bool {
        !self.exports()
    }

    pub const fn name(self) -> &'static str {
        match self {
            Self::ExportAll => "ExportAll",
            Self::ExportDefault => "ExportDefault",
            Self::ExportNamed => "ExportNamed",
            Self::ImportDefault => "ImportDefault",
            Self::ImportNamed => "ImportNamed",
            Self::ImportNamespace => "ImportNamespace",
            Self::ImportSideEffect => "ImportSideEffect",
            Self::ImportType => "ImportType",
            Self::Reexport => "Reexport",
        }
    }
}

impl Facts {
    pub fn reserve(fact_count_max: u32) -> Self {
        assert!(fact_count_max > 0);

        assert!(!crate::allocation::is_frozen());

        Self {
            items: BoundedVec::reserve(fact_count_max),
        }
    }

    pub fn as_slice(&self) -> &[Fact] {
        &self.items
    }

    pub fn clear(&mut self) {
        self.items.clear();

        assert_eq!(self.count(), 0);
    }

    pub fn count(&self) -> u32 {
        self.items.count()
    }

    pub fn is_full(&self) -> bool {
        self.items.is_full()
    }

    #[must_use]
    pub fn push(&mut self, fact: Fact) -> bool {
        self.items.push(fact)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SyntaxErrorKind {
    DepthExceeded,
    ExpectedColon,
    ExpectedEqual,
    ExpectedExpression,
    ExpectedIdentifier,
    ExpectedImport,
    ExpectedIn,
    ExpectedType,
    UnexpectedDedent,
    UnexpectedIndent,
    UnexpectedToken,
    UnmatchedBracket,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SyntaxError {
    pub kind: SyntaxErrorKind,
    pub span: Span,
}

impl SyntaxErrorKind {
    pub const fn message(self) -> &'static str {
        match self {
            Self::DepthExceeded => "Nesting too deep",
            Self::ExpectedColon => "Expected ':'",
            Self::ExpectedEqual => "Expected '='",
            Self::ExpectedExpression => "Expected an expression",
            Self::ExpectedIdentifier => "Expected an identifier",
            Self::ExpectedImport => "Expected 'import'",
            Self::ExpectedIn => "Expected 'in'",
            Self::ExpectedType => "Expected a type",
            Self::UnexpectedDedent => "Unindent does not match any outer indentation level",
            Self::UnexpectedIndent => "Unexpected indentation",
            Self::UnexpectedToken => "Unexpected token",
            Self::UnmatchedBracket => "Unmatched closing bracket",
        }
    }

    pub const fn name(self) -> &'static str {
        match self {
            Self::DepthExceeded => "DepthExceeded",
            Self::ExpectedColon => "ExpectedColon",
            Self::ExpectedEqual => "ExpectedEqual",
            Self::ExpectedExpression => "ExpectedExpression",
            Self::ExpectedIdentifier => "ExpectedIdentifier",
            Self::ExpectedImport => "ExpectedImport",
            Self::ExpectedIn => "ExpectedIn",
            Self::ExpectedType => "ExpectedType",
            Self::UnexpectedDedent => "UnexpectedDedent",
            Self::UnexpectedIndent => "UnexpectedIndent",
            Self::UnexpectedToken => "UnexpectedToken",
            Self::UnmatchedBracket => "UnmatchedBracket",
        }
    }
}
