use crate::syntax::python::kind::PythonKind;
use crate::tree::Checkpoint;

pub const EXPRESSION_DEPTH_MAX: u32 = 256;
pub const VALUE_COUNT_MAX: u32 = 512;
pub const POWER_BARRIER: u8 = 0;
pub const POWER_STARRED: u8 = 1;
pub const POWER_WALRUS_LEFT: u8 = 4;
pub const POWER_WALRUS_RIGHT: u8 = 3;
pub const POWER_CONDITIONAL_LEFT: u8 = 6;
pub const POWER_CONDITIONAL_RIGHT: u8 = 5;
pub const POWER_OR_LEFT: u8 = 8;
pub const POWER_OR_RIGHT: u8 = 9;
pub const POWER_AND_LEFT: u8 = 10;
pub const POWER_AND_RIGHT: u8 = 11;
pub const POWER_NOT: u8 = 12;
pub const POWER_COMPARE_LEFT: u8 = 14;
pub const POWER_COMPARE_RIGHT: u8 = 15;
pub const POWER_BAR_LEFT: u8 = 16;
pub const POWER_BAR_RIGHT: u8 = 17;
pub const POWER_CARET_LEFT: u8 = 18;
pub const POWER_CARET_RIGHT: u8 = 19;
pub const POWER_AMPERSAND_LEFT: u8 = 20;
pub const POWER_AMPERSAND_RIGHT: u8 = 21;
pub const POWER_SHIFT_LEFT: u8 = 22;
pub const POWER_SHIFT_RIGHT: u8 = 23;
pub const POWER_ADDITIVE_LEFT: u8 = 24;
pub const POWER_ADDITIVE_RIGHT: u8 = 25;
pub const POWER_MULTIPLICATIVE_LEFT: u8 = 26;
pub const POWER_MULTIPLICATIVE_RIGHT: u8 = 27;
pub const POWER_SIGN: u8 = 28;
pub const POWER_POWER_LEFT: u8 = 32;
pub const POWER_POWER_RIGHT: u8 = 29;
pub const POWER_AWAIT: u8 = 34;

const INFIX: [(PythonKind, PythonKind, u8, u8); 24] = [
    (
        PythonKind::Ampersand,
        PythonKind::BinOp,
        POWER_AMPERSAND_LEFT,
        POWER_AMPERSAND_RIGHT,
    ),
    (
        PythonKind::AndKeyword,
        PythonKind::BoolOp,
        POWER_AND_LEFT,
        POWER_AND_RIGHT,
    ),
    (
        PythonKind::At,
        PythonKind::BinOp,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
    (
        PythonKind::Bar,
        PythonKind::BinOp,
        POWER_BAR_LEFT,
        POWER_BAR_RIGHT,
    ),
    (
        PythonKind::Caret,
        PythonKind::BinOp,
        POWER_CARET_LEFT,
        POWER_CARET_RIGHT,
    ),
    (
        PythonKind::ColonEqual,
        PythonKind::NamedExpr,
        POWER_WALRUS_LEFT,
        POWER_WALRUS_RIGHT,
    ),
    (
        PythonKind::EqualEqual,
        PythonKind::Compare,
        POWER_COMPARE_LEFT,
        POWER_COMPARE_RIGHT,
    ),
    (
        PythonKind::Greater,
        PythonKind::Compare,
        POWER_COMPARE_LEFT,
        POWER_COMPARE_RIGHT,
    ),
    (
        PythonKind::GreaterEqual,
        PythonKind::Compare,
        POWER_COMPARE_LEFT,
        POWER_COMPARE_RIGHT,
    ),
    (
        PythonKind::GreaterGreater,
        PythonKind::BinOp,
        POWER_SHIFT_LEFT,
        POWER_SHIFT_RIGHT,
    ),
    (
        PythonKind::InKeyword,
        PythonKind::Compare,
        POWER_COMPARE_LEFT,
        POWER_COMPARE_RIGHT,
    ),
    (
        PythonKind::IsKeyword,
        PythonKind::Compare,
        POWER_COMPARE_LEFT,
        POWER_COMPARE_RIGHT,
    ),
    (
        PythonKind::Less,
        PythonKind::Compare,
        POWER_COMPARE_LEFT,
        POWER_COMPARE_RIGHT,
    ),
    (
        PythonKind::LessEqual,
        PythonKind::Compare,
        POWER_COMPARE_LEFT,
        POWER_COMPARE_RIGHT,
    ),
    (
        PythonKind::LessLess,
        PythonKind::BinOp,
        POWER_SHIFT_LEFT,
        POWER_SHIFT_RIGHT,
    ),
    (
        PythonKind::Minus,
        PythonKind::BinOp,
        POWER_ADDITIVE_LEFT,
        POWER_ADDITIVE_RIGHT,
    ),
    (
        PythonKind::NotEqual,
        PythonKind::Compare,
        POWER_COMPARE_LEFT,
        POWER_COMPARE_RIGHT,
    ),
    (
        PythonKind::OrKeyword,
        PythonKind::BoolOp,
        POWER_OR_LEFT,
        POWER_OR_RIGHT,
    ),
    (
        PythonKind::Percent,
        PythonKind::BinOp,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
    (
        PythonKind::Plus,
        PythonKind::BinOp,
        POWER_ADDITIVE_LEFT,
        POWER_ADDITIVE_RIGHT,
    ),
    (
        PythonKind::Slash,
        PythonKind::BinOp,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
    (
        PythonKind::SlashSlash,
        PythonKind::BinOp,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
    (
        PythonKind::Star,
        PythonKind::BinOp,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
    (
        PythonKind::StarStar,
        PythonKind::BinOp,
        POWER_POWER_LEFT,
        POWER_POWER_RIGHT,
    ),
];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Variant {
    Bare,
    Binary,
    Brace,
    Bracket,
    Call,
    ClassArgs,
    Conditional,
    Formatted,
    Joined,
    Keyword,
    Lambda,
    Mapping,
    Paren,
    PatternGroup,
    Sequence,
    Subscript,
    Top,
    Unary,
    Yield,
}

#[derive(Clone, Copy, Debug)]
pub struct Frame {
    pub bracket: Checkpoint,
    pub checkpoint: Checkpoint,
    pub clause: Checkpoint,
    pub closer: PythonKind,
    pub comprehension: bool,
    pub content: Checkpoint,
    pub dictionary: bool,
    pub element: Checkpoint,
    pub element_values: u32,
    pub elements: u32,
    pub kind: PythonKind,
    pub no_in: bool,
    pub power: u8,
    pub slice: bool,
    pub stage: u8,
    pub token: PythonKind,
    pub tuple: bool,
    pub values: u32,
    pub variant: Variant,
}

impl Frame {
    pub const EMPTY: Self = Self {
        bracket: Checkpoint::NONE,
        checkpoint: Checkpoint::NONE,
        clause: Checkpoint::NONE,
        closer: PythonKind::ErrorToken,
        comprehension: false,
        content: Checkpoint::NONE,
        dictionary: false,
        element: Checkpoint::NONE,
        element_values: 0,
        elements: 0,
        kind: PythonKind::ErrorNode,
        no_in: false,
        power: POWER_BARRIER,
        slice: false,
        stage: 0,
        token: PythonKind::ErrorToken,
        tuple: false,
        values: 0,
        variant: Variant::Top,
    };

    pub const fn is_group(&self) -> bool {
        matches!(
            self.variant,
            Variant::Bare
                | Variant::Brace
                | Variant::Bracket
                | Variant::Call
                | Variant::ClassArgs
                | Variant::Formatted
                | Variant::Joined
                | Variant::Lambda
                | Variant::Mapping
                | Variant::Paren
                | Variant::PatternGroup
                | Variant::Sequence
                | Variant::Subscript
                | Variant::Top
                | Variant::Yield
        )
    }

    pub const fn is_pattern(&self) -> bool {
        matches!(
            self.variant,
            Variant::ClassArgs | Variant::Mapping | Variant::PatternGroup | Variant::Sequence
        )
    }

    pub const fn is_bracketed(&self) -> bool {
        matches!(
            self.variant,
            Variant::Bare
                | Variant::Brace
                | Variant::Bracket
                | Variant::Call
                | Variant::Paren
                | Variant::Subscript
        )
    }
}

pub const fn closer_of(opener: PythonKind) -> PythonKind {
    if matches!(opener, PythonKind::BraceOpen) {
        return PythonKind::BraceClose;
    }

    if matches!(opener, PythonKind::BracketOpen) {
        return PythonKind::BracketClose;
    }

    PythonKind::ParenClose
}

pub fn infix_of(kind: PythonKind) -> Option<(PythonKind, u8, u8)> {
    INFIX
        .iter()
        .find(|row| row.0 == kind)
        .map(|row| (row.1, row.2, row.3))
}

pub const fn is_literal(kind: PythonKind) -> bool {
    matches!(
        kind,
        PythonKind::Ellipsis
            | PythonKind::FalseKeyword
            | PythonKind::NoneKeyword
            | PythonKind::NumberBinary
            | PythonKind::NumberComplex
            | PythonKind::NumberFloat
            | PythonKind::NumberHexadecimal
            | PythonKind::NumberInteger
            | PythonKind::NumberOctal
            | PythonKind::StringBytes
            | PythonKind::StringPlain
            | PythonKind::TrueKeyword
    )
}

pub const fn is_string(kind: PythonKind) -> bool {
    matches!(kind, PythonKind::StringBytes | PythonKind::StringPlain)
}

pub const fn is_contributor(kind: PythonKind) -> bool {
    matches!(
        kind,
        PythonKind::FStringMiddle | PythonKind::StringBytes | PythonKind::StringPlain
    )
}

pub const fn is_piece(kind: PythonKind) -> bool {
    matches!(
        kind,
        PythonKind::FStringEnd | PythonKind::FStringMiddle | PythonKind::FStringStart
    ) || is_string(kind)
}
