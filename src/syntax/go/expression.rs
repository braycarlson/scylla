use crate::syntax::go::kind::GoKind;
use crate::tree::Checkpoint;

pub const EXPRESSION_DEPTH_MAX: u32 = 256;
pub const VALUE_COUNT_MAX: u32 = 512;
pub const POWER_BARRIER: u8 = 0;
pub const POWER_OR_LEFT: u8 = 2;
pub const POWER_OR_RIGHT: u8 = 3;
pub const POWER_AND_LEFT: u8 = 4;
pub const POWER_AND_RIGHT: u8 = 5;
pub const POWER_COMPARE_LEFT: u8 = 6;
pub const POWER_COMPARE_RIGHT: u8 = 7;
pub const POWER_ADDITIVE_LEFT: u8 = 8;
pub const POWER_ADDITIVE_RIGHT: u8 = 9;
pub const POWER_MULTIPLICATIVE_LEFT: u8 = 10;
pub const POWER_MULTIPLICATIVE_RIGHT: u8 = 11;
pub const POWER_UNARY: u8 = 14;

const INFIX: [(GoKind, u8, u8); 19] = [
    (
        GoKind::Ampersand,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
    (GoKind::AmpersandAmpersand, POWER_AND_LEFT, POWER_AND_RIGHT),
    (
        GoKind::AmpersandCaret,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
    (GoKind::Bar, POWER_ADDITIVE_LEFT, POWER_ADDITIVE_RIGHT),
    (GoKind::BarBar, POWER_OR_LEFT, POWER_OR_RIGHT),
    (GoKind::BangEqual, POWER_COMPARE_LEFT, POWER_COMPARE_RIGHT),
    (GoKind::Caret, POWER_ADDITIVE_LEFT, POWER_ADDITIVE_RIGHT),
    (GoKind::EqualEqual, POWER_COMPARE_LEFT, POWER_COMPARE_RIGHT),
    (GoKind::Greater, POWER_COMPARE_LEFT, POWER_COMPARE_RIGHT),
    (
        GoKind::GreaterEqual,
        POWER_COMPARE_LEFT,
        POWER_COMPARE_RIGHT,
    ),
    (
        GoKind::GreaterGreater,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
    (GoKind::Less, POWER_COMPARE_LEFT, POWER_COMPARE_RIGHT),
    (GoKind::LessEqual, POWER_COMPARE_LEFT, POWER_COMPARE_RIGHT),
    (
        GoKind::LessLess,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
    (GoKind::Minus, POWER_ADDITIVE_LEFT, POWER_ADDITIVE_RIGHT),
    (
        GoKind::Percent,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
    (GoKind::Plus, POWER_ADDITIVE_LEFT, POWER_ADDITIVE_RIGHT),
    (
        GoKind::Slash,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
    (
        GoKind::Star,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
];

const ASSIGNMENTS: [GoKind; 13] = [
    GoKind::AmpersandCaretEqual,
    GoKind::AmpersandEqual,
    GoKind::BarEqual,
    GoKind::CaretEqual,
    GoKind::ColonEqual,
    GoKind::Equal,
    GoKind::GreaterGreaterEqual,
    GoKind::LessLessEqual,
    GoKind::MinusEqual,
    GoKind::PercentEqual,
    GoKind::PlusEqual,
    GoKind::SlashEqual,
    GoKind::StarEqual,
];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Variant {
    Binary,
    Call,
    Composite,
    Index,
    Paren,
    Top,
    Unary,
}

#[derive(Clone, Copy, Debug)]
pub struct Frame {
    pub bracket: Checkpoint,
    pub checkpoint: Checkpoint,
    pub closer: GoKind,
    pub content: Checkpoint,
    pub element_values: u32,
    pub elements: u32,
    pub kind: GoKind,
    pub power: u8,
    pub stage: u8,
    pub values: u32,
    pub variant: Variant,
}

impl Frame {
    pub const EMPTY: Self = Self {
        bracket: Checkpoint::NONE,
        checkpoint: Checkpoint::NONE,
        closer: GoKind::ErrorToken,
        content: Checkpoint::NONE,
        element_values: 0,
        elements: 0,
        kind: GoKind::ErrorNode,
        power: POWER_BARRIER,
        stage: 0,
        values: 0,
        variant: Variant::Top,
    };

    pub const fn is_group(&self) -> bool {
        matches!(
            self.variant,
            Variant::Call | Variant::Composite | Variant::Index | Variant::Paren | Variant::Top
        )
    }

    pub const fn is_bracketed(&self) -> bool {
        matches!(
            self.variant,
            Variant::Call | Variant::Composite | Variant::Index | Variant::Paren
        )
    }
}

pub const fn operands_of(variant: Variant) -> u32 {
    match variant {
        Variant::Binary => 2,
        Variant::Unary => 1,
        Variant::Call | Variant::Composite | Variant::Index | Variant::Paren | Variant::Top => 0,
    }
}

pub fn infix_of(kind: GoKind) -> Option<(u8, u8)> {
    INFIX
        .iter()
        .find(|row| row.0 == kind)
        .map(|row| (row.1, row.2))
}

pub fn assigns(kind: GoKind) -> bool {
    ASSIGNMENTS.contains(&kind)
}

pub const fn is_literal(kind: GoKind) -> bool {
    matches!(
        kind,
        GoKind::Number | GoKind::RuneLiteral | GoKind::StringLiteral
    )
}

pub const fn is_prefix(kind: GoKind) -> bool {
    matches!(
        kind,
        GoKind::Ampersand
            | GoKind::Bang
            | GoKind::Caret
            | GoKind::Minus
            | GoKind::Plus
            | GoKind::Tilde
    )
}

pub const fn opens_a_type(kind: GoKind) -> bool {
    matches!(
        kind,
        GoKind::Arrow
            | GoKind::BracketOpen
            | GoKind::ChanKeyword
            | GoKind::DotDotDot
            | GoKind::FuncKeyword
            | GoKind::Identifier
            | GoKind::InterfaceKeyword
            | GoKind::MapKeyword
            | GoKind::ParenOpen
            | GoKind::Star
            | GoKind::StructKeyword
            | GoKind::Tilde
    )
}
