use crate::syntax::odin::kind::OdinKind;
use crate::tree::Checkpoint;

pub const EXPRESSION_DEPTH_MAX: u32 = 256;
pub const VALUE_COUNT_MAX: u32 = 512;
pub const POWER_BARRIER: u8 = 0;
pub const POWER_IN_LEFT: u8 = 13;
pub const POWER_IN_RIGHT: u8 = 12;
pub const POWER_BRANCH_LEFT: u8 = 10;
pub const POWER_BRANCH_RIGHT: u8 = 11;
pub const POWER_TERNARY_LEFT: u8 = 10;
pub const POWER_TERNARY_RIGHT: u8 = 11;
pub const POWER_OR_LEFT: u8 = 14;
pub const POWER_OR_RIGHT: u8 = 15;
pub const POWER_AND_LEFT: u8 = 16;
pub const POWER_AND_RIGHT: u8 = 17;
pub const POWER_COMPARE_LEFT: u8 = 18;
pub const POWER_COMPARE_RIGHT: u8 = 19;
pub const POWER_EQUALITY_LEFT: u8 = 20;
pub const POWER_EQUALITY_RIGHT: u8 = 21;
pub const POWER_BIT_OR_LEFT: u8 = 22;
pub const POWER_BIT_OR_RIGHT: u8 = 23;
pub const POWER_BIT_XOR_LEFT: u8 = 24;
pub const POWER_BIT_XOR_RIGHT: u8 = 25;
pub const POWER_BIT_AND_LEFT: u8 = 26;
pub const POWER_BIT_AND_RIGHT: u8 = 27;
pub const POWER_BIT_AND_NOT_LEFT: u8 = 28;
pub const POWER_BIT_AND_NOT_RIGHT: u8 = 29;
pub const POWER_SHIFT_LEFT: u8 = 30;
pub const POWER_SHIFT_RIGHT: u8 = 31;
pub const POWER_ADDITIVE_LEFT: u8 = 32;
pub const POWER_ADDITIVE_RIGHT: u8 = 33;
pub const POWER_MULTIPLICATIVE_LEFT: u8 = 34;
pub const POWER_MULTIPLICATIVE_RIGHT: u8 = 35;
pub const POWER_CAST: u8 = 36;
pub const POWER_PREFIX: u8 = 38;
pub const POWER_RANGE_LEFT: u8 = 42;
pub const POWER_RANGE_RIGHT: u8 = 43;

const INFIX: [(OdinKind, OdinKind, u8, u8); 29] = [
    (
        OdinKind::Ampersand,
        OdinKind::BinaryExpression,
        POWER_BIT_AND_LEFT,
        POWER_BIT_AND_RIGHT,
    ),
    (
        OdinKind::AmpersandAmpersand,
        OdinKind::BinaryExpression,
        POWER_AND_LEFT,
        POWER_AND_RIGHT,
    ),
    (
        OdinKind::AmpersandTilde,
        OdinKind::BinaryExpression,
        POWER_BIT_AND_NOT_LEFT,
        POWER_BIT_AND_NOT_RIGHT,
    ),
    (
        OdinKind::Bar,
        OdinKind::BinaryExpression,
        POWER_BIT_OR_LEFT,
        POWER_BIT_OR_RIGHT,
    ),
    (
        OdinKind::BarBar,
        OdinKind::BinaryExpression,
        POWER_OR_LEFT,
        POWER_OR_RIGHT,
    ),
    (
        OdinKind::BangEqual,
        OdinKind::BinaryExpression,
        POWER_EQUALITY_LEFT,
        POWER_EQUALITY_RIGHT,
    ),
    (
        OdinKind::DotDotEqual,
        OdinKind::RangeExpression,
        POWER_RANGE_LEFT,
        POWER_RANGE_RIGHT,
    ),
    (
        OdinKind::DotDotLess,
        OdinKind::RangeExpression,
        POWER_RANGE_LEFT,
        POWER_RANGE_RIGHT,
    ),
    (
        OdinKind::EqualEqual,
        OdinKind::BinaryExpression,
        POWER_EQUALITY_LEFT,
        POWER_EQUALITY_RIGHT,
    ),
    (
        OdinKind::Greater,
        OdinKind::BinaryExpression,
        POWER_COMPARE_LEFT,
        POWER_COMPARE_RIGHT,
    ),
    (
        OdinKind::GreaterEqual,
        OdinKind::BinaryExpression,
        POWER_COMPARE_LEFT,
        POWER_COMPARE_RIGHT,
    ),
    (
        OdinKind::GreaterGreater,
        OdinKind::BinaryExpression,
        POWER_SHIFT_LEFT,
        POWER_SHIFT_RIGHT,
    ),
    (
        OdinKind::IfKeyword,
        OdinKind::TernaryExpression,
        POWER_BRANCH_LEFT,
        POWER_BRANCH_RIGHT,
    ),
    (
        OdinKind::InKeyword,
        OdinKind::InExpression,
        POWER_IN_LEFT,
        POWER_IN_RIGHT,
    ),
    (
        OdinKind::Less,
        OdinKind::BinaryExpression,
        POWER_COMPARE_LEFT,
        POWER_COMPARE_RIGHT,
    ),
    (
        OdinKind::LessEqual,
        OdinKind::BinaryExpression,
        POWER_COMPARE_LEFT,
        POWER_COMPARE_RIGHT,
    ),
    (
        OdinKind::LessLess,
        OdinKind::BinaryExpression,
        POWER_SHIFT_LEFT,
        POWER_SHIFT_RIGHT,
    ),
    (
        OdinKind::Minus,
        OdinKind::BinaryExpression,
        POWER_ADDITIVE_LEFT,
        POWER_ADDITIVE_RIGHT,
    ),
    (
        OdinKind::NotInKeyword,
        OdinKind::InExpression,
        POWER_IN_LEFT,
        POWER_IN_RIGHT,
    ),
    (
        OdinKind::OrElseKeyword,
        OdinKind::BinaryExpression,
        POWER_OR_LEFT,
        POWER_OR_RIGHT,
    ),
    (
        OdinKind::Percent,
        OdinKind::BinaryExpression,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
    (
        OdinKind::PercentPercent,
        OdinKind::BinaryExpression,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
    (
        OdinKind::Plus,
        OdinKind::BinaryExpression,
        POWER_ADDITIVE_LEFT,
        POWER_ADDITIVE_RIGHT,
    ),
    (
        OdinKind::Question,
        OdinKind::TernaryExpression,
        POWER_TERNARY_LEFT,
        POWER_TERNARY_RIGHT,
    ),
    (
        OdinKind::Slash,
        OdinKind::BinaryExpression,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
    (
        OdinKind::Star,
        OdinKind::BinaryExpression,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
    (
        OdinKind::Tilde,
        OdinKind::BinaryExpression,
        POWER_BIT_XOR_LEFT,
        POWER_BIT_XOR_RIGHT,
    ),
    (
        OdinKind::TildeEqual,
        OdinKind::BinaryExpression,
        POWER_EQUALITY_LEFT,
        POWER_EQUALITY_RIGHT,
    ),
    (
        OdinKind::WhenKeyword,
        OdinKind::TernaryExpression,
        POWER_BRANCH_LEFT,
        POWER_BRANCH_RIGHT,
    ),
];

const ASSIGNMENTS: [(OdinKind, OdinKind); 15] = [
    (OdinKind::AmpersandAmpersandEqual, OdinKind::UpdateStatement),
    (OdinKind::AmpersandEqual, OdinKind::UpdateStatement),
    (OdinKind::AmpersandTildeEqual, OdinKind::UpdateStatement),
    (OdinKind::BarBarEqual, OdinKind::UpdateStatement),
    (OdinKind::BarEqual, OdinKind::UpdateStatement),
    (OdinKind::ColonEqual, OdinKind::AssignmentStatement),
    (OdinKind::Equal, OdinKind::AssignmentStatement),
    (OdinKind::GreaterGreaterEqual, OdinKind::UpdateStatement),
    (OdinKind::LessLessEqual, OdinKind::UpdateStatement),
    (OdinKind::MinusEqual, OdinKind::UpdateStatement),
    (OdinKind::PercentEqual, OdinKind::UpdateStatement),
    (OdinKind::PercentPercentEqual, OdinKind::UpdateStatement),
    (OdinKind::PlusEqual, OdinKind::UpdateStatement),
    (OdinKind::SlashEqual, OdinKind::UpdateStatement),
    (OdinKind::StarEqual, OdinKind::UpdateStatement),
];

const PREFIXES: [OdinKind; 6] = [
    OdinKind::Ampersand,
    OdinKind::Bang,
    OdinKind::Minus,
    OdinKind::Plus,
    OdinKind::Tilde,
    OdinKind::AmpersandTilde,
];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Variant {
    Binary,
    Call,
    Index,
    Init,
    Paren,
    Top,
    Unary,
}

#[derive(Clone, Copy, Debug)]
pub struct Frame {
    pub bracket: Checkpoint,
    pub checkpoint: Checkpoint,
    pub closer: OdinKind,
    pub content: Checkpoint,
    pub element_values: u32,
    pub elements: u32,
    pub kind: OdinKind,
    pub power: u8,
    pub stage: u8,
    pub values: u32,
    pub variant: Variant,
}

impl Frame {
    pub const EMPTY: Self = Self {
        bracket: Checkpoint::NONE,
        checkpoint: Checkpoint::NONE,
        closer: OdinKind::ErrorToken,
        content: Checkpoint::NONE,
        element_values: 0,
        elements: 0,
        kind: OdinKind::ErrorNode,
        power: POWER_BARRIER,
        stage: 0,
        values: 0,
        variant: Variant::Top,
    };

    pub const fn is_group(&self) -> bool {
        matches!(
            self.variant,
            Variant::Call | Variant::Index | Variant::Init | Variant::Paren | Variant::Top
        )
    }

    pub const fn is_bracketed(&self) -> bool {
        matches!(
            self.variant,
            Variant::Call | Variant::Index | Variant::Init | Variant::Paren
        )
    }
}

pub fn infix_of(kind: OdinKind) -> Option<(OdinKind, u8, u8)> {
    INFIX
        .iter()
        .find(|row| row.0 == kind)
        .map(|row| (row.1, row.2, row.3))
}

pub fn assignment_of(kind: OdinKind) -> Option<OdinKind> {
    ASSIGNMENTS
        .iter()
        .find(|row| row.0 == kind)
        .map(|row| row.1)
}

pub fn is_prefix(kind: OdinKind) -> bool {
    PREFIXES.contains(&kind)
}

pub const fn literal_node(kind: OdinKind) -> Option<OdinKind> {
    match Some(kind) {
        Some(OdinKind::Character) => Some(OdinKind::CharacterNode),
        Some(OdinKind::FalseKeyword | OdinKind::TrueKeyword) => Some(OdinKind::Boolean),
        Some(OdinKind::Float) => Some(OdinKind::FloatNode),
        Some(OdinKind::NilKeyword) => Some(OdinKind::Nil),
        Some(OdinKind::Number) => Some(OdinKind::NumberNode),
        Some(OdinKind::Text) => Some(OdinKind::String),
        Some(_) | None => None,
    }
}

pub const fn is_name(kind: OdinKind) -> bool {
    matches!(
        kind,
        OdinKind::ContextKeyword | OdinKind::Identifier | OdinKind::TypeidKeyword
    )
}

pub const fn opens_a_type(kind: OdinKind) -> bool {
    matches!(
        kind,
        OdinKind::BitFieldKeyword
            | OdinKind::BitSetKeyword
            | OdinKind::BracketOpen
            | OdinKind::Caret
            | OdinKind::ContextKeyword
            | OdinKind::DistinctKeyword
            | OdinKind::Dollar
            | OdinKind::DotDot
            | OdinKind::EnumKeyword
            | OdinKind::Identifier
            | OdinKind::MapKeyword
            | OdinKind::MatrixKeyword
            | OdinKind::ParenOpen
            | OdinKind::ProcKeyword
            | OdinKind::StructKeyword
            | OdinKind::TypeidKeyword
            | OdinKind::UnionKeyword
    )
}
