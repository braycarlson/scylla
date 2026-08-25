use crate::syntax::{Category, SyntaxError};
use crate::tree::Kind;

pub const KIND_COUNT: u16 = 134;
pub const NODE_FIRST: u16 = 80;

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
#[repr(u16)]
pub enum GoKind {
    Ampersand = 0,
    AmpersandAmpersand = 1,
    AmpersandCaret = 2,
    AmpersandCaretEqual = 3,
    AmpersandEqual = 4,
    Arrow = 5,
    Bang = 6,
    BangEqual = 7,
    Bar = 8,
    BarBar = 9,
    BarEqual = 10,
    BraceClose = 11,
    BraceOpen = 12,
    BracketClose = 13,
    BracketOpen = 14,
    BreakKeyword = 15,
    Caret = 16,
    CaretEqual = 17,
    CaseKeyword = 18,
    ChanKeyword = 19,
    Colon = 20,
    ColonEqual = 21,
    Comma = 22,
    Comment = 23,
    ConstKeyword = 24,
    ContinueKeyword = 25,
    DefaultKeyword = 26,
    DeferKeyword = 27,
    Dot = 28,
    DotDotDot = 29,
    ElseKeyword = 30,
    Equal = 31,
    EqualEqual = 32,
    ErrorToken = 33,
    FallthroughKeyword = 34,
    ForKeyword = 35,
    FuncKeyword = 36,
    GoKeyword = 37,
    GotoKeyword = 38,
    Greater = 39,
    GreaterEqual = 40,
    GreaterGreater = 41,
    GreaterGreaterEqual = 42,
    Identifier = 43,
    IfKeyword = 44,
    ImportKeyword = 45,
    InterfaceKeyword = 46,
    Less = 47,
    LessEqual = 48,
    LessLess = 49,
    LessLessEqual = 50,
    MapKeyword = 51,
    Minus = 52,
    MinusEqual = 53,
    MinusMinus = 54,
    Newline = 55,
    Number = 56,
    PackageKeyword = 57,
    ParenClose = 58,
    ParenOpen = 59,
    Percent = 60,
    PercentEqual = 61,
    Plus = 62,
    PlusEqual = 63,
    PlusPlus = 64,
    RangeKeyword = 65,
    ReturnKeyword = 66,
    RuneLiteral = 67,
    SelectKeyword = 68,
    Semicolon = 69,
    Slash = 70,
    SlashEqual = 71,
    Star = 72,
    StarEqual = 73,
    StringLiteral = 74,
    StructKeyword = 75,
    SwitchKeyword = 76,
    Tilde = 77,
    TypeKeyword = 78,
    VarKeyword = 79,
    ArrayType = 80,
    AssignStmt = 81,
    BadDecl = 82,
    BadExpr = 83,
    BadStmt = 84,
    BasicLit = 85,
    BinaryExpr = 86,
    BlockStmt = 87,
    BranchStmt = 88,
    CallExpr = 89,
    CaseClause = 90,
    ChanType = 91,
    CommClause = 92,
    CompositeLit = 93,
    DeclStmt = 94,
    DeferStmt = 95,
    Ellipsis = 96,
    EmptyStmt = 97,
    ErrorNode = 98,
    ExprStmt = 99,
    Field = 100,
    FieldList = 101,
    File = 102,
    ForStmt = 103,
    FuncDecl = 104,
    FuncLit = 105,
    FuncType = 106,
    GenDecl = 107,
    GoStmt = 108,
    Ident = 109,
    IfStmt = 110,
    ImportSpec = 111,
    IncDecStmt = 112,
    IndexExpr = 113,
    IndexListExpr = 114,
    InterfaceType = 115,
    KeyValueExpr = 116,
    LabeledStmt = 117,
    MapType = 118,
    ParenExpr = 119,
    RangeStmt = 120,
    ReturnStmt = 121,
    SelectStmt = 122,
    SelectorExpr = 123,
    SendStmt = 124,
    SliceExpr = 125,
    StarExpr = 126,
    StructType = 127,
    SwitchStmt = 128,
    TypeAssertExpr = 129,
    TypeSpec = 130,
    TypeSwitchStmt = 131,
    UnaryExpr = 132,
    ValueSpec = 133,
}

static KINDS: [GoKind; KIND_COUNT as usize] = [
    GoKind::Ampersand,
    GoKind::AmpersandAmpersand,
    GoKind::AmpersandCaret,
    GoKind::AmpersandCaretEqual,
    GoKind::AmpersandEqual,
    GoKind::Arrow,
    GoKind::Bang,
    GoKind::BangEqual,
    GoKind::Bar,
    GoKind::BarBar,
    GoKind::BarEqual,
    GoKind::BraceClose,
    GoKind::BraceOpen,
    GoKind::BracketClose,
    GoKind::BracketOpen,
    GoKind::BreakKeyword,
    GoKind::Caret,
    GoKind::CaretEqual,
    GoKind::CaseKeyword,
    GoKind::ChanKeyword,
    GoKind::Colon,
    GoKind::ColonEqual,
    GoKind::Comma,
    GoKind::Comment,
    GoKind::ConstKeyword,
    GoKind::ContinueKeyword,
    GoKind::DefaultKeyword,
    GoKind::DeferKeyword,
    GoKind::Dot,
    GoKind::DotDotDot,
    GoKind::ElseKeyword,
    GoKind::Equal,
    GoKind::EqualEqual,
    GoKind::ErrorToken,
    GoKind::FallthroughKeyword,
    GoKind::ForKeyword,
    GoKind::FuncKeyword,
    GoKind::GoKeyword,
    GoKind::GotoKeyword,
    GoKind::Greater,
    GoKind::GreaterEqual,
    GoKind::GreaterGreater,
    GoKind::GreaterGreaterEqual,
    GoKind::Identifier,
    GoKind::IfKeyword,
    GoKind::ImportKeyword,
    GoKind::InterfaceKeyword,
    GoKind::Less,
    GoKind::LessEqual,
    GoKind::LessLess,
    GoKind::LessLessEqual,
    GoKind::MapKeyword,
    GoKind::Minus,
    GoKind::MinusEqual,
    GoKind::MinusMinus,
    GoKind::Newline,
    GoKind::Number,
    GoKind::PackageKeyword,
    GoKind::ParenClose,
    GoKind::ParenOpen,
    GoKind::Percent,
    GoKind::PercentEqual,
    GoKind::Plus,
    GoKind::PlusEqual,
    GoKind::PlusPlus,
    GoKind::RangeKeyword,
    GoKind::ReturnKeyword,
    GoKind::RuneLiteral,
    GoKind::SelectKeyword,
    GoKind::Semicolon,
    GoKind::Slash,
    GoKind::SlashEqual,
    GoKind::Star,
    GoKind::StarEqual,
    GoKind::StringLiteral,
    GoKind::StructKeyword,
    GoKind::SwitchKeyword,
    GoKind::Tilde,
    GoKind::TypeKeyword,
    GoKind::VarKeyword,
    GoKind::ArrayType,
    GoKind::AssignStmt,
    GoKind::BadDecl,
    GoKind::BadExpr,
    GoKind::BadStmt,
    GoKind::BasicLit,
    GoKind::BinaryExpr,
    GoKind::BlockStmt,
    GoKind::BranchStmt,
    GoKind::CallExpr,
    GoKind::CaseClause,
    GoKind::ChanType,
    GoKind::CommClause,
    GoKind::CompositeLit,
    GoKind::DeclStmt,
    GoKind::DeferStmt,
    GoKind::Ellipsis,
    GoKind::EmptyStmt,
    GoKind::ErrorNode,
    GoKind::ExprStmt,
    GoKind::Field,
    GoKind::FieldList,
    GoKind::File,
    GoKind::ForStmt,
    GoKind::FuncDecl,
    GoKind::FuncLit,
    GoKind::FuncType,
    GoKind::GenDecl,
    GoKind::GoStmt,
    GoKind::Ident,
    GoKind::IfStmt,
    GoKind::ImportSpec,
    GoKind::IncDecStmt,
    GoKind::IndexExpr,
    GoKind::IndexListExpr,
    GoKind::InterfaceType,
    GoKind::KeyValueExpr,
    GoKind::LabeledStmt,
    GoKind::MapType,
    GoKind::ParenExpr,
    GoKind::RangeStmt,
    GoKind::ReturnStmt,
    GoKind::SelectStmt,
    GoKind::SelectorExpr,
    GoKind::SendStmt,
    GoKind::SliceExpr,
    GoKind::StarExpr,
    GoKind::StructType,
    GoKind::SwitchStmt,
    GoKind::TypeAssertExpr,
    GoKind::TypeSpec,
    GoKind::TypeSwitchStmt,
    GoKind::UnaryExpr,
    GoKind::ValueSpec,
];

static NAMES: [&str; KIND_COUNT as usize] = [
    "Ampersand",
    "AmpersandAmpersand",
    "AmpersandCaret",
    "AmpersandCaretEqual",
    "AmpersandEqual",
    "Arrow",
    "Bang",
    "BangEqual",
    "Bar",
    "BarBar",
    "BarEqual",
    "BraceClose",
    "BraceOpen",
    "BracketClose",
    "BracketOpen",
    "BreakKeyword",
    "Caret",
    "CaretEqual",
    "CaseKeyword",
    "ChanKeyword",
    "Colon",
    "ColonEqual",
    "Comma",
    "Comment",
    "ConstKeyword",
    "ContinueKeyword",
    "DefaultKeyword",
    "DeferKeyword",
    "Dot",
    "DotDotDot",
    "ElseKeyword",
    "Equal",
    "EqualEqual",
    "ErrorToken",
    "FallthroughKeyword",
    "ForKeyword",
    "FuncKeyword",
    "GoKeyword",
    "GotoKeyword",
    "Greater",
    "GreaterEqual",
    "GreaterGreater",
    "GreaterGreaterEqual",
    "Identifier",
    "IfKeyword",
    "ImportKeyword",
    "InterfaceKeyword",
    "Less",
    "LessEqual",
    "LessLess",
    "LessLessEqual",
    "MapKeyword",
    "Minus",
    "MinusEqual",
    "MinusMinus",
    "Newline",
    "Number",
    "PackageKeyword",
    "ParenClose",
    "ParenOpen",
    "Percent",
    "PercentEqual",
    "Plus",
    "PlusEqual",
    "PlusPlus",
    "RangeKeyword",
    "ReturnKeyword",
    "RuneLiteral",
    "SelectKeyword",
    "Semicolon",
    "Slash",
    "SlashEqual",
    "Star",
    "StarEqual",
    "StringLiteral",
    "StructKeyword",
    "SwitchKeyword",
    "Tilde",
    "TypeKeyword",
    "VarKeyword",
    "ArrayType",
    "AssignStmt",
    "BadDecl",
    "BadExpr",
    "BadStmt",
    "BasicLit",
    "BinaryExpr",
    "BlockStmt",
    "BranchStmt",
    "CallExpr",
    "CaseClause",
    "ChanType",
    "CommClause",
    "CompositeLit",
    "DeclStmt",
    "DeferStmt",
    "Ellipsis",
    "EmptyStmt",
    "ErrorNode",
    "ExprStmt",
    "Field",
    "FieldList",
    "File",
    "ForStmt",
    "FuncDecl",
    "FuncLit",
    "FuncType",
    "GenDecl",
    "GoStmt",
    "Ident",
    "IfStmt",
    "ImportSpec",
    "IncDecStmt",
    "IndexExpr",
    "IndexListExpr",
    "InterfaceType",
    "KeyValueExpr",
    "LabeledStmt",
    "MapType",
    "ParenExpr",
    "RangeStmt",
    "ReturnStmt",
    "SelectStmt",
    "SelectorExpr",
    "SendStmt",
    "SliceExpr",
    "StarExpr",
    "StructType",
    "SwitchStmt",
    "TypeAssertExpr",
    "TypeSpec",
    "TypeSwitchStmt",
    "UnaryExpr",
    "ValueSpec",
];

impl Kind for GoKind {
    type Error = SyntaxError;
    const ERROR: Self = Self::ErrorNode;

    fn category(self) -> Category {
        Self::category(self)
    }

    fn is_node(self) -> bool {
        Self::is_node(self)
    }

    fn is_token(self) -> bool {
        Self::is_token(self)
    }
}

impl GoKind {
    #[expect(
        clippy::too_many_lines,
        reason = "the projection names every kind, so its length is the grammar's and a shorter \
                  form would be a table the compiler cannot check"
    )]
    pub const fn category(self) -> Category {
        match self {
            Self::AssignStmt | Self::IncDecStmt => Category::Assignment,
            Self::BlockStmt | Self::CaseClause | Self::CommClause => Category::Block,
            Self::IfStmt => Category::Branch,
            Self::CallExpr => Category::Call,
            Self::DeclStmt | Self::Field | Self::GenDecl | Self::ValueSpec => Category::Declaration,
            Self::BadExpr
            | Self::BinaryExpr
            | Self::CompositeLit
            | Self::DeferStmt
            | Self::Ellipsis
            | Self::ExprStmt
            | Self::GoStmt
            | Self::IndexExpr
            | Self::IndexListExpr
            | Self::KeyValueExpr
            | Self::ParenExpr
            | Self::SelectorExpr
            | Self::SendStmt
            | Self::SliceExpr
            | Self::StarExpr
            | Self::TypeAssertExpr
            | Self::UnaryExpr => Category::Expression,
            Self::File => Category::File,
            Self::FuncDecl => Category::Function,
            Self::ImportSpec => Category::Import,
            Self::FuncLit => Category::Lambda,
            Self::ForStmt | Self::RangeStmt => Category::Loop,
            Self::SelectStmt | Self::SwitchStmt | Self::TypeSwitchStmt => Category::Match,
            Self::Ident | Self::Identifier => Category::Name,
            Self::FieldList | Self::FuncType => Category::Parameters,
            Self::ReturnStmt => Category::Return,
            Self::InterfaceType | Self::StructType | Self::TypeSpec => Category::Struct,
            Self::ArrayType | Self::ChanType | Self::MapType => Category::Type,
            Self::BasicLit | Self::Number | Self::RuneLiteral | Self::StringLiteral => {
                Category::Value
            }
            Self::Ampersand
            | Self::AmpersandAmpersand
            | Self::AmpersandCaret
            | Self::AmpersandCaretEqual
            | Self::AmpersandEqual
            | Self::Arrow
            | Self::BadDecl
            | Self::BadStmt
            | Self::Bang
            | Self::BangEqual
            | Self::Bar
            | Self::BarBar
            | Self::BarEqual
            | Self::BraceClose
            | Self::BraceOpen
            | Self::BracketClose
            | Self::BracketOpen
            | Self::BranchStmt
            | Self::BreakKeyword
            | Self::Caret
            | Self::CaretEqual
            | Self::CaseKeyword
            | Self::ChanKeyword
            | Self::Colon
            | Self::ColonEqual
            | Self::Comma
            | Self::Comment
            | Self::ConstKeyword
            | Self::ContinueKeyword
            | Self::DefaultKeyword
            | Self::DeferKeyword
            | Self::Dot
            | Self::DotDotDot
            | Self::ElseKeyword
            | Self::EmptyStmt
            | Self::Equal
            | Self::EqualEqual
            | Self::ErrorNode
            | Self::ErrorToken
            | Self::FallthroughKeyword
            | Self::ForKeyword
            | Self::FuncKeyword
            | Self::GoKeyword
            | Self::GotoKeyword
            | Self::Greater
            | Self::GreaterEqual
            | Self::GreaterGreater
            | Self::GreaterGreaterEqual
            | Self::IfKeyword
            | Self::ImportKeyword
            | Self::InterfaceKeyword
            | Self::LabeledStmt
            | Self::Less
            | Self::LessEqual
            | Self::LessLess
            | Self::LessLessEqual
            | Self::MapKeyword
            | Self::Minus
            | Self::MinusEqual
            | Self::MinusMinus
            | Self::Newline
            | Self::PackageKeyword
            | Self::ParenClose
            | Self::ParenOpen
            | Self::Percent
            | Self::PercentEqual
            | Self::Plus
            | Self::PlusEqual
            | Self::PlusPlus
            | Self::RangeKeyword
            | Self::ReturnKeyword
            | Self::SelectKeyword
            | Self::Semicolon
            | Self::Slash
            | Self::SlashEqual
            | Self::Star
            | Self::StarEqual
            | Self::StructKeyword
            | Self::SwitchKeyword
            | Self::Tilde
            | Self::TypeKeyword
            | Self::VarKeyword => Category::Other,
        }
    }

    pub const fn is_node(self) -> bool {
        self.to_u16() >= NODE_FIRST
    }

    pub const fn is_token(self) -> bool {
        self.to_u16() < NODE_FIRST
    }

    pub const fn is_trivia(self) -> bool {
        matches!(self, Self::Comment)
    }

    pub fn name(self) -> &'static str {
        NAMES[self.to_u16() as usize]
    }

    pub const fn to_u16(self) -> u16 {
        self as u16
    }

    pub fn of_name(name: &str) -> Option<Self> {
        NAMES
            .iter()
            .position(|held| *held == name)
            .map(|index| KINDS[index])
    }

    pub fn of_u16(discriminant: u16) -> Option<Self> {
        KINDS.get(discriminant as usize).copied()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_kind_sits_at_its_own_discriminant() {
        for (index, kind) in KINDS.iter().enumerate() {
            assert_eq!(kind.to_u16() as usize, index, "{}", kind.name());
            assert_eq!(GoKind::of_u16(kind.to_u16()), Some(*kind));
            assert_eq!(GoKind::of_name(kind.name()), Some(*kind));
        }

        assert_eq!(KINDS.len(), KIND_COUNT as usize);
        assert_eq!(NAMES.len(), KIND_COUNT as usize);
        assert!(GoKind::of_u16(KIND_COUNT).is_none());
    }

    #[test]
    fn the_token_range_and_the_node_range_do_not_meet() {
        for kind in &KINDS {
            assert_ne!(kind.is_node(), kind.is_token(), "{}", kind.name());
        }

        assert!(KINDS[NODE_FIRST as usize - 1].is_token());
        assert!(KINDS[NODE_FIRST as usize].is_node());
    }
}
