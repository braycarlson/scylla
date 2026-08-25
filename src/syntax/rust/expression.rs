use crate::syntax::rust::kind::RustKind;
use crate::tree::Checkpoint;

pub const EXPRESSION_DEPTH_MAX: u32 = 256;
pub const VALUE_COUNT_MAX: u32 = 512;
pub const POWER_BARRIER: u8 = 0;
pub const POWER_ASSIGN_LEFT: u8 = 5;
pub const POWER_ASSIGN_RIGHT: u8 = 4;
pub const POWER_RANGE_LEFT: u8 = 6;
pub const POWER_RANGE_RIGHT: u8 = 7;
pub const POWER_OR_LEFT: u8 = 8;
pub const POWER_OR_RIGHT: u8 = 9;
pub const POWER_AND_LEFT: u8 = 10;
pub const POWER_AND_RIGHT: u8 = 11;
pub const POWER_COMPARE_LEFT: u8 = 12;
pub const POWER_COMPARE_RIGHT: u8 = 13;
pub const POWER_BAR_LEFT: u8 = 14;
pub const POWER_BAR_RIGHT: u8 = 15;
pub const POWER_CARET_LEFT: u8 = 16;
pub const POWER_CARET_RIGHT: u8 = 17;
pub const POWER_AMPERSAND_LEFT: u8 = 18;
pub const POWER_AMPERSAND_RIGHT: u8 = 19;
pub const POWER_SHIFT_LEFT: u8 = 20;
pub const POWER_SHIFT_RIGHT: u8 = 21;
pub const POWER_ADDITIVE_LEFT: u8 = 22;
pub const POWER_ADDITIVE_RIGHT: u8 = 23;
pub const POWER_MULTIPLICATIVE_LEFT: u8 = 24;
pub const POWER_MULTIPLICATIVE_RIGHT: u8 = 25;
pub const POWER_CAST: u8 = 26;
pub const POWER_UNARY: u8 = 28;

const INFIX: [(RustKind, RustKind, u8, u8); 20] = [
    (
        RustKind::Ampersand,
        RustKind::ExprBinary,
        POWER_AMPERSAND_LEFT,
        POWER_AMPERSAND_RIGHT,
    ),
    (
        RustKind::AmpersandEqual,
        RustKind::ExprBinary,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        RustKind::BangEqual,
        RustKind::ExprBinary,
        POWER_COMPARE_LEFT,
        POWER_COMPARE_RIGHT,
    ),
    (
        RustKind::Caret,
        RustKind::ExprBinary,
        POWER_CARET_LEFT,
        POWER_CARET_RIGHT,
    ),
    (
        RustKind::CaretEqual,
        RustKind::ExprBinary,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        RustKind::Equal,
        RustKind::ExprAssign,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        RustKind::EqualEqual,
        RustKind::ExprBinary,
        POWER_COMPARE_LEFT,
        POWER_COMPARE_RIGHT,
    ),
    (
        RustKind::Minus,
        RustKind::ExprBinary,
        POWER_ADDITIVE_LEFT,
        POWER_ADDITIVE_RIGHT,
    ),
    (
        RustKind::MinusEqual,
        RustKind::ExprBinary,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        RustKind::Or,
        RustKind::ExprBinary,
        POWER_BAR_LEFT,
        POWER_BAR_RIGHT,
    ),
    (
        RustKind::OrEqual,
        RustKind::ExprBinary,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        RustKind::OrOr,
        RustKind::ExprBinary,
        POWER_OR_LEFT,
        POWER_OR_RIGHT,
    ),
    (
        RustKind::Percent,
        RustKind::ExprBinary,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
    (
        RustKind::PercentEqual,
        RustKind::ExprBinary,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        RustKind::Plus,
        RustKind::ExprBinary,
        POWER_ADDITIVE_LEFT,
        POWER_ADDITIVE_RIGHT,
    ),
    (
        RustKind::PlusEqual,
        RustKind::ExprBinary,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        RustKind::Slash,
        RustKind::ExprBinary,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
    (
        RustKind::SlashEqual,
        RustKind::ExprBinary,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        RustKind::Star,
        RustKind::ExprBinary,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
    (
        RustKind::StarEqual,
        RustKind::ExprBinary,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
];

const LITERALS: [(RustKind, RustKind); 8] = [
    (RustKind::ByteLiteral, RustKind::LitByte),
    (RustKind::ByteStringLiteral, RustKind::LitByteStr),
    (RustKind::CStringLiteral, RustKind::LitCStr),
    (RustKind::CharLiteral, RustKind::LitChar),
    (RustKind::FalseKeyword, RustKind::LitBool),
    (RustKind::Number, RustKind::LitInt),
    (RustKind::StringLiteral, RustKind::LitStr),
    (RustKind::TrueKeyword, RustKind::LitBool),
];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Variant {
    Array,
    Binary,
    Call,
    Group,
    Paren,
    Struct,
    Subscript,
    Top,
    Unary,
}

#[derive(Clone, Copy, Debug)]
pub struct Frame {
    pub bracket: Checkpoint,
    pub checkpoint: Checkpoint,
    pub closer: RustKind,
    pub content: Checkpoint,
    pub element_values: u32,
    pub elements: u32,
    pub kind: RustKind,
    pub power: u8,
    pub stage: u8,
    pub values: u32,
    pub variant: Variant,
}

impl Frame {
    pub const EMPTY: Self = Self {
        bracket: Checkpoint::NONE,
        checkpoint: Checkpoint::NONE,
        closer: RustKind::ErrorToken,
        content: Checkpoint::NONE,
        element_values: 0,
        elements: 0,
        kind: RustKind::ErrorNode,
        power: POWER_BARRIER,
        stage: 0,
        values: 0,
        variant: Variant::Top,
    };

    pub const fn is_group(&self) -> bool {
        matches!(
            self.variant,
            Variant::Array
                | Variant::Call
                | Variant::Group
                | Variant::Paren
                | Variant::Struct
                | Variant::Subscript
                | Variant::Top
        )
    }

    pub const fn is_bracketed(&self) -> bool {
        matches!(
            self.variant,
            Variant::Array | Variant::Call | Variant::Paren | Variant::Struct | Variant::Subscript
        )
    }
}

pub fn infix_of(kind: RustKind) -> Option<(RustKind, u8, u8)> {
    INFIX
        .iter()
        .find(|row| row.0 == kind)
        .map(|row| (row.1, row.2, row.3))
}

pub fn literal_kind(kind: RustKind) -> Option<RustKind> {
    LITERALS.iter().find(|row| row.0 == kind).map(|row| row.1)
}

pub const fn is_literal(kind: RustKind) -> bool {
    matches!(
        kind,
        RustKind::ByteLiteral
            | RustKind::ByteStringLiteral
            | RustKind::CStringLiteral
            | RustKind::CharLiteral
            | RustKind::FalseKeyword
            | RustKind::Number
            | RustKind::StringLiteral
            | RustKind::TrueKeyword
    )
}

pub const fn opens_a_path(kind: RustKind) -> bool {
    matches!(
        kind,
        RustKind::ColonColon
            | RustKind::CrateKeyword
            | RustKind::Identifier
            | RustKind::MacroKeyword
            | RustKind::SelfLower
            | RustKind::SelfUpper
            | RustKind::SuperKeyword
            | RustKind::TryKeyword
            | RustKind::UnionKeyword
    )
}
