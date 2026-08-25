use crate::syntax::zig::kind::ZigKind;
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
pub const POWER_BITWISE_LEFT: u8 = 8;
pub const POWER_BITWISE_RIGHT: u8 = 9;
pub const POWER_SHIFT_LEFT: u8 = 10;
pub const POWER_SHIFT_RIGHT: u8 = 11;
pub const POWER_ADDITIVE_LEFT: u8 = 12;
pub const POWER_ADDITIVE_RIGHT: u8 = 13;
pub const POWER_MULTIPLICATIVE_LEFT: u8 = 14;
pub const POWER_MULTIPLICATIVE_RIGHT: u8 = 15;
pub const POWER_PREFIX: u8 = 18;
pub const POWER_ERROR_UNION_LEFT: u8 = 21;
pub const POWER_ERROR_UNION_RIGHT: u8 = 20;

const INFIX: [(ZigKind, ZigKind, u8, u8); 31] = [
    (
        ZigKind::Ampersand,
        ZigKind::BitAnd,
        POWER_BITWISE_LEFT,
        POWER_BITWISE_RIGHT,
    ),
    (
        ZigKind::AndKeyword,
        ZigKind::BoolAnd,
        POWER_AND_LEFT,
        POWER_AND_RIGHT,
    ),
    (
        ZigKind::Bang,
        ZigKind::ErrorUnion,
        POWER_ERROR_UNION_LEFT,
        POWER_ERROR_UNION_RIGHT,
    ),
    (
        ZigKind::BangEqual,
        ZigKind::BangEqualNode,
        POWER_COMPARE_LEFT,
        POWER_COMPARE_RIGHT,
    ),
    (
        ZigKind::Caret,
        ZigKind::BitXor,
        POWER_BITWISE_LEFT,
        POWER_BITWISE_RIGHT,
    ),
    (
        ZigKind::CatchKeyword,
        ZigKind::Catch,
        POWER_BITWISE_LEFT,
        POWER_BITWISE_RIGHT,
    ),
    (
        ZigKind::EqualEqual,
        ZigKind::EqualEqualNode,
        POWER_COMPARE_LEFT,
        POWER_COMPARE_RIGHT,
    ),
    (
        ZigKind::Greater,
        ZigKind::GreaterThan,
        POWER_COMPARE_LEFT,
        POWER_COMPARE_RIGHT,
    ),
    (
        ZigKind::GreaterEqual,
        ZigKind::GreaterOrEqual,
        POWER_COMPARE_LEFT,
        POWER_COMPARE_RIGHT,
    ),
    (
        ZigKind::GreaterGreater,
        ZigKind::Shr,
        POWER_SHIFT_LEFT,
        POWER_SHIFT_RIGHT,
    ),
    (
        ZigKind::Less,
        ZigKind::LessThan,
        POWER_COMPARE_LEFT,
        POWER_COMPARE_RIGHT,
    ),
    (
        ZigKind::LessEqual,
        ZigKind::LessOrEqual,
        POWER_COMPARE_LEFT,
        POWER_COMPARE_RIGHT,
    ),
    (
        ZigKind::LessLess,
        ZigKind::Shl,
        POWER_SHIFT_LEFT,
        POWER_SHIFT_RIGHT,
    ),
    (
        ZigKind::LessLessPipe,
        ZigKind::ShlSat,
        POWER_SHIFT_LEFT,
        POWER_SHIFT_RIGHT,
    ),
    (
        ZigKind::Minus,
        ZigKind::Sub,
        POWER_ADDITIVE_LEFT,
        POWER_ADDITIVE_RIGHT,
    ),
    (
        ZigKind::MinusPercent,
        ZigKind::SubWrap,
        POWER_ADDITIVE_LEFT,
        POWER_ADDITIVE_RIGHT,
    ),
    (
        ZigKind::MinusPipe,
        ZigKind::SubSat,
        POWER_ADDITIVE_LEFT,
        POWER_ADDITIVE_RIGHT,
    ),
    (
        ZigKind::OrKeyword,
        ZigKind::BoolOr,
        POWER_OR_LEFT,
        POWER_OR_RIGHT,
    ),
    (
        ZigKind::OrelseKeyword,
        ZigKind::Orelse,
        POWER_BITWISE_LEFT,
        POWER_BITWISE_RIGHT,
    ),
    (
        ZigKind::Percent,
        ZigKind::Mod,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
    (
        ZigKind::Pipe,
        ZigKind::BitOr,
        POWER_BITWISE_LEFT,
        POWER_BITWISE_RIGHT,
    ),
    (
        ZigKind::PipePipe,
        ZigKind::MergeErrorSets,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
    (
        ZigKind::Plus,
        ZigKind::Add,
        POWER_ADDITIVE_LEFT,
        POWER_ADDITIVE_RIGHT,
    ),
    (
        ZigKind::PlusPercent,
        ZigKind::AddWrap,
        POWER_ADDITIVE_LEFT,
        POWER_ADDITIVE_RIGHT,
    ),
    (
        ZigKind::PlusPipe,
        ZigKind::AddSat,
        POWER_ADDITIVE_LEFT,
        POWER_ADDITIVE_RIGHT,
    ),
    (
        ZigKind::PlusPlus,
        ZigKind::ArrayCat,
        POWER_ADDITIVE_LEFT,
        POWER_ADDITIVE_RIGHT,
    ),
    (
        ZigKind::Slash,
        ZigKind::Div,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
    (
        ZigKind::Star,
        ZigKind::Mul,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
    (
        ZigKind::StarPercent,
        ZigKind::MulWrap,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
    (
        ZigKind::StarPipe,
        ZigKind::MulSat,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
    (
        ZigKind::StarStar,
        ZigKind::ArrayMult,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
];

const ASSIGNMENTS: [(ZigKind, ZigKind); 18] = [
    (ZigKind::AmpersandEqual, ZigKind::AssignBitAnd),
    (ZigKind::CaretEqual, ZigKind::AssignBitXor),
    (ZigKind::Equal, ZigKind::Assign),
    (ZigKind::GreaterGreaterEqual, ZigKind::AssignShr),
    (ZigKind::LessLessEqual, ZigKind::AssignShl),
    (ZigKind::LessLessPipeEqual, ZigKind::AssignShlSat),
    (ZigKind::MinusEqual, ZigKind::AssignSub),
    (ZigKind::MinusPercentEqual, ZigKind::AssignSubWrap),
    (ZigKind::MinusPipeEqual, ZigKind::AssignSubSat),
    (ZigKind::PercentEqual, ZigKind::AssignMod),
    (ZigKind::PipeEqual, ZigKind::AssignBitOr),
    (ZigKind::PlusEqual, ZigKind::AssignAdd),
    (ZigKind::PlusPercentEqual, ZigKind::AssignAddWrap),
    (ZigKind::PlusPipeEqual, ZigKind::AssignAddSat),
    (ZigKind::SlashEqual, ZigKind::AssignDiv),
    (ZigKind::StarEqual, ZigKind::AssignMul),
    (ZigKind::StarPercentEqual, ZigKind::AssignMulWrap),
    (ZigKind::StarPipeEqual, ZigKind::AssignMulSat),
];

const PREFIXES: [(ZigKind, ZigKind); 6] = [
    (ZigKind::Ampersand, ZigKind::AddressOf),
    (ZigKind::Bang, ZigKind::BoolNot),
    (ZigKind::Minus, ZigKind::Negation),
    (ZigKind::MinusPercent, ZigKind::NegationWrap),
    (ZigKind::Tilde, ZigKind::BitNot),
    (ZigKind::TryKeyword, ZigKind::Try),
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
    pub closer: ZigKind,
    pub content: Checkpoint,
    pub element_values: u32,
    pub elements: u32,
    pub kind: ZigKind,
    pub power: u8,
    pub stage: u8,
    pub values: u32,
    pub variant: Variant,
}

impl Frame {
    pub const EMPTY: Self = Self {
        bracket: Checkpoint::NONE,
        checkpoint: Checkpoint::NONE,
        closer: ZigKind::ErrorToken,
        content: Checkpoint::NONE,
        element_values: 0,
        elements: 0,
        kind: ZigKind::ErrorNode,
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

pub fn infix_of(kind: ZigKind) -> Option<(ZigKind, u8, u8)> {
    INFIX
        .iter()
        .find(|row| row.0 == kind)
        .map(|row| (row.1, row.2, row.3))
}

pub fn assignment_of(kind: ZigKind) -> Option<ZigKind> {
    ASSIGNMENTS
        .iter()
        .find(|row| row.0 == kind)
        .map(|row| row.1)
}

pub fn prefix_of(kind: ZigKind) -> Option<ZigKind> {
    PREFIXES.iter().find(|row| row.0 == kind).map(|row| row.1)
}

pub const fn is_literal(kind: ZigKind) -> bool {
    matches!(
        kind,
        ZigKind::Character | ZigKind::Number | ZigKind::Text | ZigKind::TextLine
    )
}

pub const fn literal_node(kind: ZigKind) -> ZigKind {
    match Some(kind) {
        Some(ZigKind::Character) => ZigKind::CharLiteral,
        Some(ZigKind::Number) => ZigKind::NumberLiteral,
        Some(ZigKind::TextLine) => ZigKind::MultilineStringLiteral,
        Some(_) | None => ZigKind::StringLiteral,
    }
}

pub const fn opens_a_type(kind: ZigKind) -> bool {
    matches!(
        kind,
        ZigKind::AnyframeKeyword
            | ZigKind::BracketOpen
            | ZigKind::Builtin
            | ZigKind::EnumKeyword
            | ZigKind::ErrorKeyword
            | ZigKind::ExternKeyword
            | ZigKind::FnKeyword
            | ZigKind::Identifier
            | ZigKind::OpaqueKeyword
            | ZigKind::PackedKeyword
            | ZigKind::ParenOpen
            | ZigKind::Question
            | ZigKind::Star
            | ZigKind::StarStar
            | ZigKind::StructKeyword
            | ZigKind::UnionKeyword
    )
}
