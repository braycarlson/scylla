use crate::syntax::{Category, SyntaxError};
use crate::tree::Kind;

pub const KIND_COUNT: u16 = 183;
pub const NODE_FIRST: u16 = 101;

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
#[repr(u16)]
pub enum PythonKind {
    Ampersand = 0,
    AmpersandEqual = 1,
    AndKeyword = 2,
    Arrow = 3,
    AsKeyword = 4,
    AssertKeyword = 5,
    AsyncKeyword = 6,
    At = 7,
    AtEqual = 8,
    AwaitKeyword = 9,
    Bang = 10,
    Bar = 11,
    BarEqual = 12,
    BraceClose = 13,
    BraceOpen = 14,
    BracketClose = 15,
    BracketOpen = 16,
    BreakKeyword = 17,
    Caret = 18,
    CaretEqual = 19,
    ClassKeyword = 20,
    Colon = 21,
    ColonEqual = 22,
    Comma = 23,
    Comment = 24,
    ContinueKeyword = 25,
    Dedent = 26,
    DefKeyword = 27,
    DelKeyword = 28,
    Dot = 29,
    ElifKeyword = 30,
    Ellipsis = 31,
    ElseKeyword = 32,
    Equal = 33,
    EqualEqual = 34,
    ErrorToken = 35,
    ExceptKeyword = 36,
    FStringEnd = 37,
    FStringMiddle = 38,
    FStringStart = 39,
    FalseKeyword = 40,
    FinallyKeyword = 41,
    ForKeyword = 42,
    FromKeyword = 43,
    GlobalKeyword = 44,
    Greater = 45,
    GreaterEqual = 46,
    GreaterGreater = 47,
    GreaterGreaterEqual = 48,
    Identifier = 49,
    IfKeyword = 50,
    ImportKeyword = 51,
    InKeyword = 52,
    Indent = 53,
    IsKeyword = 54,
    LambdaKeyword = 55,
    Less = 56,
    LessEqual = 57,
    LessLess = 58,
    LessLessEqual = 59,
    Minus = 60,
    MinusEqual = 61,
    Newline = 62,
    NoneKeyword = 63,
    NonlocalKeyword = 64,
    NotEqual = 65,
    NotKeyword = 66,
    NumberBinary = 67,
    NumberComplex = 68,
    NumberFloat = 69,
    NumberHexadecimal = 70,
    NumberInteger = 71,
    NumberOctal = 72,
    OrKeyword = 73,
    ParenClose = 74,
    ParenOpen = 75,
    PassKeyword = 76,
    Percent = 77,
    PercentEqual = 78,
    Plus = 79,
    PlusEqual = 80,
    RaiseKeyword = 81,
    ReturnKeyword = 82,
    Semicolon = 83,
    Slash = 84,
    SlashEqual = 85,
    SlashSlash = 86,
    SlashSlashEqual = 87,
    Star = 88,
    StarEqual = 89,
    StarStar = 90,
    StarStarEqual = 91,
    StringBytes = 92,
    StringFormat = 93,
    StringPlain = 94,
    Tilde = 95,
    TrueKeyword = 96,
    TryKeyword = 97,
    WhileKeyword = 98,
    WithKeyword = 99,
    YieldKeyword = 100,
    Alias = 101,
    AnnAssign = 102,
    Arg = 103,
    Arguments = 104,
    Assert = 105,
    Assign = 106,
    AsyncFor = 107,
    AsyncFunctionDef = 108,
    AsyncWith = 109,
    Attribute = 110,
    AugAssign = 111,
    Await = 112,
    BinOp = 113,
    Block = 114,
    BoolOp = 115,
    Break = 116,
    Call = 117,
    ClassDef = 118,
    Compare = 119,
    Comprehension = 120,
    Constant = 121,
    Continue = 122,
    Decorator = 123,
    Delete = 124,
    Dict = 125,
    DictComp = 126,
    ElseClause = 127,
    ErrorNode = 128,
    ExceptHandler = 129,
    Expr = 130,
    FinallyClause = 131,
    For = 132,
    FormattedValue = 133,
    FunctionDef = 134,
    GeneratorExp = 135,
    Global = 136,
    If = 137,
    IfExp = 138,
    Import = 139,
    ImportFrom = 140,
    JoinedStr = 141,
    Keyword = 142,
    Lambda = 143,
    List = 144,
    ListComp = 145,
    Match = 146,
    MatchAs = 147,
    MatchCase = 148,
    MatchClass = 149,
    MatchMapping = 150,
    MatchOr = 151,
    MatchSequence = 152,
    MatchSingleton = 153,
    MatchStar = 154,
    MatchValue = 155,
    Module = 156,
    Name = 157,
    NamedExpr = 158,
    Nonlocal = 159,
    ParamSpec = 160,
    Parenthesized = 161,
    Pass = 162,
    Raise = 163,
    Return = 164,
    Set = 165,
    SetComp = 166,
    Slice = 167,
    Starred = 168,
    Subscript = 169,
    Try = 170,
    TryStar = 171,
    Tuple = 172,
    TypeAlias = 173,
    TypeParams = 174,
    TypeVar = 175,
    TypeVarTuple = 176,
    UnaryOp = 177,
    While = 178,
    With = 179,
    WithItem = 180,
    Yield = 181,
    YieldFrom = 182,
}

static KINDS: [PythonKind; KIND_COUNT as usize] = [
    PythonKind::Ampersand,
    PythonKind::AmpersandEqual,
    PythonKind::AndKeyword,
    PythonKind::Arrow,
    PythonKind::AsKeyword,
    PythonKind::AssertKeyword,
    PythonKind::AsyncKeyword,
    PythonKind::At,
    PythonKind::AtEqual,
    PythonKind::AwaitKeyword,
    PythonKind::Bang,
    PythonKind::Bar,
    PythonKind::BarEqual,
    PythonKind::BraceClose,
    PythonKind::BraceOpen,
    PythonKind::BracketClose,
    PythonKind::BracketOpen,
    PythonKind::BreakKeyword,
    PythonKind::Caret,
    PythonKind::CaretEqual,
    PythonKind::ClassKeyword,
    PythonKind::Colon,
    PythonKind::ColonEqual,
    PythonKind::Comma,
    PythonKind::Comment,
    PythonKind::ContinueKeyword,
    PythonKind::Dedent,
    PythonKind::DefKeyword,
    PythonKind::DelKeyword,
    PythonKind::Dot,
    PythonKind::ElifKeyword,
    PythonKind::Ellipsis,
    PythonKind::ElseKeyword,
    PythonKind::Equal,
    PythonKind::EqualEqual,
    PythonKind::ErrorToken,
    PythonKind::ExceptKeyword,
    PythonKind::FStringEnd,
    PythonKind::FStringMiddle,
    PythonKind::FStringStart,
    PythonKind::FalseKeyword,
    PythonKind::FinallyKeyword,
    PythonKind::ForKeyword,
    PythonKind::FromKeyword,
    PythonKind::GlobalKeyword,
    PythonKind::Greater,
    PythonKind::GreaterEqual,
    PythonKind::GreaterGreater,
    PythonKind::GreaterGreaterEqual,
    PythonKind::Identifier,
    PythonKind::IfKeyword,
    PythonKind::ImportKeyword,
    PythonKind::InKeyword,
    PythonKind::Indent,
    PythonKind::IsKeyword,
    PythonKind::LambdaKeyword,
    PythonKind::Less,
    PythonKind::LessEqual,
    PythonKind::LessLess,
    PythonKind::LessLessEqual,
    PythonKind::Minus,
    PythonKind::MinusEqual,
    PythonKind::Newline,
    PythonKind::NoneKeyword,
    PythonKind::NonlocalKeyword,
    PythonKind::NotEqual,
    PythonKind::NotKeyword,
    PythonKind::NumberBinary,
    PythonKind::NumberComplex,
    PythonKind::NumberFloat,
    PythonKind::NumberHexadecimal,
    PythonKind::NumberInteger,
    PythonKind::NumberOctal,
    PythonKind::OrKeyword,
    PythonKind::ParenClose,
    PythonKind::ParenOpen,
    PythonKind::PassKeyword,
    PythonKind::Percent,
    PythonKind::PercentEqual,
    PythonKind::Plus,
    PythonKind::PlusEqual,
    PythonKind::RaiseKeyword,
    PythonKind::ReturnKeyword,
    PythonKind::Semicolon,
    PythonKind::Slash,
    PythonKind::SlashEqual,
    PythonKind::SlashSlash,
    PythonKind::SlashSlashEqual,
    PythonKind::Star,
    PythonKind::StarEqual,
    PythonKind::StarStar,
    PythonKind::StarStarEqual,
    PythonKind::StringBytes,
    PythonKind::StringFormat,
    PythonKind::StringPlain,
    PythonKind::Tilde,
    PythonKind::TrueKeyword,
    PythonKind::TryKeyword,
    PythonKind::WhileKeyword,
    PythonKind::WithKeyword,
    PythonKind::YieldKeyword,
    PythonKind::Alias,
    PythonKind::AnnAssign,
    PythonKind::Arg,
    PythonKind::Arguments,
    PythonKind::Assert,
    PythonKind::Assign,
    PythonKind::AsyncFor,
    PythonKind::AsyncFunctionDef,
    PythonKind::AsyncWith,
    PythonKind::Attribute,
    PythonKind::AugAssign,
    PythonKind::Await,
    PythonKind::BinOp,
    PythonKind::Block,
    PythonKind::BoolOp,
    PythonKind::Break,
    PythonKind::Call,
    PythonKind::ClassDef,
    PythonKind::Compare,
    PythonKind::Comprehension,
    PythonKind::Constant,
    PythonKind::Continue,
    PythonKind::Decorator,
    PythonKind::Delete,
    PythonKind::Dict,
    PythonKind::DictComp,
    PythonKind::ElseClause,
    PythonKind::ErrorNode,
    PythonKind::ExceptHandler,
    PythonKind::Expr,
    PythonKind::FinallyClause,
    PythonKind::For,
    PythonKind::FormattedValue,
    PythonKind::FunctionDef,
    PythonKind::GeneratorExp,
    PythonKind::Global,
    PythonKind::If,
    PythonKind::IfExp,
    PythonKind::Import,
    PythonKind::ImportFrom,
    PythonKind::JoinedStr,
    PythonKind::Keyword,
    PythonKind::Lambda,
    PythonKind::List,
    PythonKind::ListComp,
    PythonKind::Match,
    PythonKind::MatchAs,
    PythonKind::MatchCase,
    PythonKind::MatchClass,
    PythonKind::MatchMapping,
    PythonKind::MatchOr,
    PythonKind::MatchSequence,
    PythonKind::MatchSingleton,
    PythonKind::MatchStar,
    PythonKind::MatchValue,
    PythonKind::Module,
    PythonKind::Name,
    PythonKind::NamedExpr,
    PythonKind::Nonlocal,
    PythonKind::ParamSpec,
    PythonKind::Parenthesized,
    PythonKind::Pass,
    PythonKind::Raise,
    PythonKind::Return,
    PythonKind::Set,
    PythonKind::SetComp,
    PythonKind::Slice,
    PythonKind::Starred,
    PythonKind::Subscript,
    PythonKind::Try,
    PythonKind::TryStar,
    PythonKind::Tuple,
    PythonKind::TypeAlias,
    PythonKind::TypeParams,
    PythonKind::TypeVar,
    PythonKind::TypeVarTuple,
    PythonKind::UnaryOp,
    PythonKind::While,
    PythonKind::With,
    PythonKind::WithItem,
    PythonKind::Yield,
    PythonKind::YieldFrom,
];

static NAMES: [&str; KIND_COUNT as usize] = [
    "Ampersand",
    "AmpersandEqual",
    "AndKeyword",
    "Arrow",
    "AsKeyword",
    "AssertKeyword",
    "AsyncKeyword",
    "At",
    "AtEqual",
    "AwaitKeyword",
    "Bang",
    "Bar",
    "BarEqual",
    "BraceClose",
    "BraceOpen",
    "BracketClose",
    "BracketOpen",
    "BreakKeyword",
    "Caret",
    "CaretEqual",
    "ClassKeyword",
    "Colon",
    "ColonEqual",
    "Comma",
    "Comment",
    "ContinueKeyword",
    "Dedent",
    "DefKeyword",
    "DelKeyword",
    "Dot",
    "ElifKeyword",
    "Ellipsis",
    "ElseKeyword",
    "Equal",
    "EqualEqual",
    "ErrorToken",
    "ExceptKeyword",
    "FStringEnd",
    "FStringMiddle",
    "FStringStart",
    "FalseKeyword",
    "FinallyKeyword",
    "ForKeyword",
    "FromKeyword",
    "GlobalKeyword",
    "Greater",
    "GreaterEqual",
    "GreaterGreater",
    "GreaterGreaterEqual",
    "Identifier",
    "IfKeyword",
    "ImportKeyword",
    "InKeyword",
    "Indent",
    "IsKeyword",
    "LambdaKeyword",
    "Less",
    "LessEqual",
    "LessLess",
    "LessLessEqual",
    "Minus",
    "MinusEqual",
    "Newline",
    "NoneKeyword",
    "NonlocalKeyword",
    "NotEqual",
    "NotKeyword",
    "NumberBinary",
    "NumberComplex",
    "NumberFloat",
    "NumberHexadecimal",
    "NumberInteger",
    "NumberOctal",
    "OrKeyword",
    "ParenClose",
    "ParenOpen",
    "PassKeyword",
    "Percent",
    "PercentEqual",
    "Plus",
    "PlusEqual",
    "RaiseKeyword",
    "ReturnKeyword",
    "Semicolon",
    "Slash",
    "SlashEqual",
    "SlashSlash",
    "SlashSlashEqual",
    "Star",
    "StarEqual",
    "StarStar",
    "StarStarEqual",
    "StringBytes",
    "StringFormat",
    "StringPlain",
    "Tilde",
    "TrueKeyword",
    "TryKeyword",
    "WhileKeyword",
    "WithKeyword",
    "YieldKeyword",
    "Alias",
    "AnnAssign",
    "Arg",
    "Arguments",
    "Assert",
    "Assign",
    "AsyncFor",
    "AsyncFunctionDef",
    "AsyncWith",
    "Attribute",
    "AugAssign",
    "Await",
    "BinOp",
    "Block",
    "BoolOp",
    "Break",
    "Call",
    "ClassDef",
    "Compare",
    "Comprehension",
    "Constant",
    "Continue",
    "Decorator",
    "Delete",
    "Dict",
    "DictComp",
    "ElseClause",
    "ErrorNode",
    "ExceptHandler",
    "Expr",
    "FinallyClause",
    "For",
    "FormattedValue",
    "FunctionDef",
    "GeneratorExp",
    "Global",
    "If",
    "IfExp",
    "Import",
    "ImportFrom",
    "JoinedStr",
    "Keyword",
    "Lambda",
    "List",
    "ListComp",
    "Match",
    "MatchAs",
    "MatchCase",
    "MatchClass",
    "MatchMapping",
    "MatchOr",
    "MatchSequence",
    "MatchSingleton",
    "MatchStar",
    "MatchValue",
    "Module",
    "Name",
    "NamedExpr",
    "Nonlocal",
    "ParamSpec",
    "Parenthesized",
    "Pass",
    "Raise",
    "Return",
    "Set",
    "SetComp",
    "Slice",
    "Starred",
    "Subscript",
    "Try",
    "TryStar",
    "Tuple",
    "TypeAlias",
    "TypeParams",
    "TypeVar",
    "TypeVarTuple",
    "UnaryOp",
    "While",
    "With",
    "WithItem",
    "Yield",
    "YieldFrom",
];

impl Kind for PythonKind {
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

impl PythonKind {
    #[expect(
        clippy::too_many_lines,
        reason = "the projection names every kind, so its length is the grammar's and a shorter \
                  form would be a table the compiler cannot check"
    )]
    pub const fn category(self) -> Category {
        match self {
            Self::AugAssign => Category::Assignment,
            Self::Decorator => Category::Attribute,
            Self::AsyncWith | Self::Block | Self::ElseClause | Self::FinallyClause | Self::With => {
                Category::Block
            }
            Self::If | Self::IfExp | Self::MatchCase => Category::Branch,
            Self::Call => Category::Call,
            Self::AnnAssign
            | Self::Assign
            | Self::Global
            | Self::NamedExpr
            | Self::Nonlocal
            | Self::TypeAlias => Category::Declaration,
            Self::ExceptHandler => Category::Except,
            Self::Assert
            | Self::Attribute
            | Self::Await
            | Self::BinOp
            | Self::BoolOp
            | Self::Compare
            | Self::Comprehension
            | Self::Delete
            | Self::Dict
            | Self::DictComp
            | Self::Expr
            | Self::FormattedValue
            | Self::GeneratorExp
            | Self::JoinedStr
            | Self::Keyword
            | Self::List
            | Self::ListComp
            | Self::MatchAs
            | Self::MatchClass
            | Self::MatchMapping
            | Self::MatchOr
            | Self::MatchSequence
            | Self::MatchSingleton
            | Self::MatchStar
            | Self::MatchValue
            | Self::Parenthesized
            | Self::Raise
            | Self::Set
            | Self::SetComp
            | Self::Slice
            | Self::Starred
            | Self::Subscript
            | Self::Tuple
            | Self::UnaryOp
            | Self::WithItem
            | Self::Yield
            | Self::YieldFrom => Category::Expression,
            Self::Module => Category::File,
            Self::AsyncFunctionDef | Self::FunctionDef => Category::Function,
            Self::Alias | Self::Import | Self::ImportFrom => Category::Import,
            Self::Lambda => Category::Lambda,
            Self::AsyncFor | Self::For | Self::While => Category::Loop,
            Self::Match => Category::Match,
            Self::Identifier | Self::Name => Category::Name,
            Self::Arg | Self::ParamSpec | Self::TypeVar | Self::TypeVarTuple => Category::Parameter,
            Self::Arguments | Self::TypeParams => Category::Parameters,
            Self::Return => Category::Return,
            Self::ClassDef => Category::Struct,
            Self::Try | Self::TryStar => Category::Try,
            Self::Constant
            | Self::Ellipsis
            | Self::FalseKeyword
            | Self::NoneKeyword
            | Self::NumberBinary
            | Self::NumberComplex
            | Self::NumberFloat
            | Self::NumberHexadecimal
            | Self::NumberInteger
            | Self::NumberOctal
            | Self::StringBytes
            | Self::StringFormat
            | Self::StringPlain
            | Self::TrueKeyword => Category::Value,
            Self::Ampersand
            | Self::AmpersandEqual
            | Self::AndKeyword
            | Self::Arrow
            | Self::AsKeyword
            | Self::AssertKeyword
            | Self::AsyncKeyword
            | Self::At
            | Self::AtEqual
            | Self::AwaitKeyword
            | Self::Bang
            | Self::Bar
            | Self::BarEqual
            | Self::BraceClose
            | Self::BraceOpen
            | Self::BracketClose
            | Self::BracketOpen
            | Self::Break
            | Self::BreakKeyword
            | Self::Caret
            | Self::CaretEqual
            | Self::ClassKeyword
            | Self::Colon
            | Self::ColonEqual
            | Self::Comma
            | Self::Comment
            | Self::Continue
            | Self::ContinueKeyword
            | Self::Dedent
            | Self::DefKeyword
            | Self::DelKeyword
            | Self::Dot
            | Self::ElifKeyword
            | Self::ElseKeyword
            | Self::Equal
            | Self::EqualEqual
            | Self::ErrorNode
            | Self::ErrorToken
            | Self::ExceptKeyword
            | Self::FStringEnd
            | Self::FStringMiddle
            | Self::FStringStart
            | Self::FinallyKeyword
            | Self::ForKeyword
            | Self::FromKeyword
            | Self::GlobalKeyword
            | Self::Greater
            | Self::GreaterEqual
            | Self::GreaterGreater
            | Self::GreaterGreaterEqual
            | Self::IfKeyword
            | Self::ImportKeyword
            | Self::InKeyword
            | Self::Indent
            | Self::IsKeyword
            | Self::LambdaKeyword
            | Self::Less
            | Self::LessEqual
            | Self::LessLess
            | Self::LessLessEqual
            | Self::Minus
            | Self::MinusEqual
            | Self::Newline
            | Self::NonlocalKeyword
            | Self::NotEqual
            | Self::NotKeyword
            | Self::OrKeyword
            | Self::ParenClose
            | Self::ParenOpen
            | Self::Pass
            | Self::PassKeyword
            | Self::Percent
            | Self::PercentEqual
            | Self::Plus
            | Self::PlusEqual
            | Self::RaiseKeyword
            | Self::ReturnKeyword
            | Self::Semicolon
            | Self::Slash
            | Self::SlashEqual
            | Self::SlashSlash
            | Self::SlashSlashEqual
            | Self::Star
            | Self::StarEqual
            | Self::StarStar
            | Self::StarStarEqual
            | Self::Tilde
            | Self::TryKeyword
            | Self::WhileKeyword
            | Self::WithKeyword
            | Self::YieldKeyword => Category::Other,
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
            assert_eq!(PythonKind::of_u16(kind.to_u16()), Some(*kind));
            assert_eq!(PythonKind::of_name(kind.name()), Some(*kind));
        }

        assert_eq!(KINDS.len(), KIND_COUNT as usize);
        assert_eq!(NAMES.len(), KIND_COUNT as usize);
        assert!(PythonKind::of_u16(KIND_COUNT).is_none());
    }

    #[test]
    fn the_token_range_and_the_node_range_do_not_meet() {
        for kind in &KINDS {
            assert_ne!(kind.is_node(), kind.is_token(), "{}", kind.name());
        }

        assert!(PythonKind::Identifier.is_token());
        assert!(PythonKind::FStringStart.is_token());
        assert!(PythonKind::Module.is_node());
        assert!(PythonKind::JoinedStr.is_node());
        assert!(KINDS[NODE_FIRST as usize - 1].is_token());
        assert!(KINDS[NODE_FIRST as usize].is_node());
    }
}
