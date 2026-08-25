use crate::syntax::typescript::kind::TypeScriptKind;
use crate::tree::Checkpoint;

pub const EXPRESSION_DEPTH_MAX: u32 = 256;
pub const VALUE_COUNT_MAX: u32 = 512;
pub const POWER_BARRIER: u8 = 0;
pub const POWER_SPREAD: u8 = 2;
pub const POWER_YIELD: u8 = 4;
pub const POWER_ARROW: u8 = 6;
pub const POWER_ASSIGN_LEFT: u8 = 9;
pub const POWER_ASSIGN_RIGHT: u8 = 8;
pub const POWER_TERNARY_LEFT: u8 = 11;
pub const POWER_TERNARY_RIGHT: u8 = 10;
pub const POWER_NULLISH_LEFT: u8 = 12;
pub const POWER_NULLISH_RIGHT: u8 = 13;
pub const POWER_OR_LEFT: u8 = 14;
pub const POWER_OR_RIGHT: u8 = 15;
pub const POWER_AND_LEFT: u8 = 16;
pub const POWER_AND_RIGHT: u8 = 17;
pub const POWER_BAR_LEFT: u8 = 18;
pub const POWER_BAR_RIGHT: u8 = 19;
pub const POWER_CARET_LEFT: u8 = 20;
pub const POWER_CARET_RIGHT: u8 = 21;
pub const POWER_AMPERSAND_LEFT: u8 = 22;
pub const POWER_AMPERSAND_RIGHT: u8 = 23;
pub const POWER_EQUALITY_LEFT: u8 = 24;
pub const POWER_EQUALITY_RIGHT: u8 = 25;
pub const POWER_RELATIONAL_LEFT: u8 = 26;
pub const POWER_RELATIONAL_RIGHT: u8 = 27;
pub const POWER_SHIFT_LEFT: u8 = 28;
pub const POWER_SHIFT_RIGHT: u8 = 29;
pub const POWER_ADDITIVE_LEFT: u8 = 30;
pub const POWER_ADDITIVE_RIGHT: u8 = 31;
pub const POWER_MULTIPLICATIVE_LEFT: u8 = 32;
pub const POWER_MULTIPLICATIVE_RIGHT: u8 = 33;
pub const POWER_POWER_LEFT: u8 = 35;
pub const POWER_POWER_RIGHT: u8 = 34;
pub const POWER_UNARY: u8 = 36;

const LITERALS: [(TypeScriptKind, TypeScriptKind); 8] = [
    (TypeScriptKind::FalseKeyword, TypeScriptKind::False),
    (TypeScriptKind::NullKeyword, TypeScriptKind::Null),
    (TypeScriptKind::Number, TypeScriptKind::NumberNode),
    (TypeScriptKind::Regex, TypeScriptKind::RegexNode),
    (TypeScriptKind::SuperKeyword, TypeScriptKind::Super),
    (TypeScriptKind::ThisKeyword, TypeScriptKind::This),
    (TypeScriptKind::TrueKeyword, TypeScriptKind::True),
    (TypeScriptKind::UndefinedKeyword, TypeScriptKind::Undefined),
];

const INFIX: [(TypeScriptKind, TypeScriptKind, u8, u8); 39] = [
    (
        TypeScriptKind::Ampersand,
        TypeScriptKind::BinaryExpression,
        POWER_AMPERSAND_LEFT,
        POWER_AMPERSAND_RIGHT,
    ),
    (
        TypeScriptKind::AmpersandAmpersand,
        TypeScriptKind::BinaryExpression,
        POWER_AND_LEFT,
        POWER_AND_RIGHT,
    ),
    (
        TypeScriptKind::AmpersandAmpersandEqual,
        TypeScriptKind::AugmentedAssignmentExpression,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        TypeScriptKind::AmpersandEqual,
        TypeScriptKind::AugmentedAssignmentExpression,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        TypeScriptKind::BangEqual,
        TypeScriptKind::BinaryExpression,
        POWER_EQUALITY_LEFT,
        POWER_EQUALITY_RIGHT,
    ),
    (
        TypeScriptKind::BangEqualEqual,
        TypeScriptKind::BinaryExpression,
        POWER_EQUALITY_LEFT,
        POWER_EQUALITY_RIGHT,
    ),
    (
        TypeScriptKind::Bar,
        TypeScriptKind::BinaryExpression,
        POWER_BAR_LEFT,
        POWER_BAR_RIGHT,
    ),
    (
        TypeScriptKind::BarBar,
        TypeScriptKind::BinaryExpression,
        POWER_OR_LEFT,
        POWER_OR_RIGHT,
    ),
    (
        TypeScriptKind::BarBarEqual,
        TypeScriptKind::AugmentedAssignmentExpression,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        TypeScriptKind::BarEqual,
        TypeScriptKind::AugmentedAssignmentExpression,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        TypeScriptKind::Caret,
        TypeScriptKind::BinaryExpression,
        POWER_CARET_LEFT,
        POWER_CARET_RIGHT,
    ),
    (
        TypeScriptKind::CaretEqual,
        TypeScriptKind::AugmentedAssignmentExpression,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        TypeScriptKind::Equal,
        TypeScriptKind::AssignmentExpression,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        TypeScriptKind::EqualEqual,
        TypeScriptKind::BinaryExpression,
        POWER_EQUALITY_LEFT,
        POWER_EQUALITY_RIGHT,
    ),
    (
        TypeScriptKind::EqualEqualEqual,
        TypeScriptKind::BinaryExpression,
        POWER_EQUALITY_LEFT,
        POWER_EQUALITY_RIGHT,
    ),
    (
        TypeScriptKind::Greater,
        TypeScriptKind::BinaryExpression,
        POWER_RELATIONAL_LEFT,
        POWER_RELATIONAL_RIGHT,
    ),
    (
        TypeScriptKind::GreaterEqual,
        TypeScriptKind::BinaryExpression,
        POWER_RELATIONAL_LEFT,
        POWER_RELATIONAL_RIGHT,
    ),
    (
        TypeScriptKind::GreaterGreaterEqual,
        TypeScriptKind::AugmentedAssignmentExpression,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        TypeScriptKind::GreaterGreaterGreaterEqual,
        TypeScriptKind::AugmentedAssignmentExpression,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        TypeScriptKind::InKeyword,
        TypeScriptKind::BinaryExpression,
        POWER_RELATIONAL_LEFT,
        POWER_RELATIONAL_RIGHT,
    ),
    (
        TypeScriptKind::InstanceofKeyword,
        TypeScriptKind::BinaryExpression,
        POWER_RELATIONAL_LEFT,
        POWER_RELATIONAL_RIGHT,
    ),
    (
        TypeScriptKind::Less,
        TypeScriptKind::BinaryExpression,
        POWER_RELATIONAL_LEFT,
        POWER_RELATIONAL_RIGHT,
    ),
    (
        TypeScriptKind::LessEqual,
        TypeScriptKind::BinaryExpression,
        POWER_RELATIONAL_LEFT,
        POWER_RELATIONAL_RIGHT,
    ),
    (
        TypeScriptKind::LessLess,
        TypeScriptKind::BinaryExpression,
        POWER_SHIFT_LEFT,
        POWER_SHIFT_RIGHT,
    ),
    (
        TypeScriptKind::LessLessEqual,
        TypeScriptKind::AugmentedAssignmentExpression,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        TypeScriptKind::Minus,
        TypeScriptKind::BinaryExpression,
        POWER_ADDITIVE_LEFT,
        POWER_ADDITIVE_RIGHT,
    ),
    (
        TypeScriptKind::MinusEqual,
        TypeScriptKind::AugmentedAssignmentExpression,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        TypeScriptKind::Percent,
        TypeScriptKind::BinaryExpression,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
    (
        TypeScriptKind::PercentEqual,
        TypeScriptKind::AugmentedAssignmentExpression,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        TypeScriptKind::Plus,
        TypeScriptKind::BinaryExpression,
        POWER_ADDITIVE_LEFT,
        POWER_ADDITIVE_RIGHT,
    ),
    (
        TypeScriptKind::PlusEqual,
        TypeScriptKind::AugmentedAssignmentExpression,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        TypeScriptKind::QuestionQuestion,
        TypeScriptKind::BinaryExpression,
        POWER_NULLISH_LEFT,
        POWER_NULLISH_RIGHT,
    ),
    (
        TypeScriptKind::QuestionQuestionEqual,
        TypeScriptKind::AugmentedAssignmentExpression,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        TypeScriptKind::Slash,
        TypeScriptKind::BinaryExpression,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
    (
        TypeScriptKind::SlashEqual,
        TypeScriptKind::AugmentedAssignmentExpression,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        TypeScriptKind::Star,
        TypeScriptKind::BinaryExpression,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
    (
        TypeScriptKind::StarEqual,
        TypeScriptKind::AugmentedAssignmentExpression,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        TypeScriptKind::StarStar,
        TypeScriptKind::BinaryExpression,
        POWER_POWER_LEFT,
        POWER_POWER_RIGHT,
    ),
    (
        TypeScriptKind::StarStarEqual,
        TypeScriptKind::AugmentedAssignmentExpression,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Variant {
    Argument,
    Array,
    Arrow,
    Binary,
    Object,
    Pair,
    Paren,
    Subscript,
    Substitution,
    Template,
    Ternary,
    Top,
    Unary,
}

#[derive(Clone, Copy, Debug)]
pub struct Frame {
    pub bracket: Checkpoint,
    pub checkpoint: Checkpoint,
    pub closer: TypeScriptKind,
    pub content: Checkpoint,
    pub element: Checkpoint,
    pub element_values: u32,
    pub elements: u32,
    pub kind: TypeScriptKind,
    pub power: u8,
    pub stage: u8,
    pub values: u32,
    pub variant: Variant,
}

impl Frame {
    pub const EMPTY: Self = Self {
        bracket: Checkpoint::NONE,
        checkpoint: Checkpoint::NONE,
        closer: TypeScriptKind::ErrorToken,
        content: Checkpoint::NONE,
        element: Checkpoint::NONE,
        element_values: 0,
        elements: 0,
        kind: TypeScriptKind::ErrorNode,
        power: POWER_BARRIER,
        stage: 0,
        values: 0,
        variant: Variant::Top,
    };

    pub const fn is_group(&self) -> bool {
        matches!(
            self.variant,
            Variant::Argument
                | Variant::Array
                | Variant::Object
                | Variant::Paren
                | Variant::Subscript
                | Variant::Substitution
                | Variant::Template
                | Variant::Top
        )
    }

    pub const fn is_bracketed(&self) -> bool {
        matches!(
            self.variant,
            Variant::Argument
                | Variant::Array
                | Variant::Object
                | Variant::Paren
                | Variant::Subscript
                | Variant::Substitution
        )
    }
}

pub const fn closer_of(opener: TypeScriptKind) -> TypeScriptKind {
    if matches!(opener, TypeScriptKind::BraceOpen) {
        return TypeScriptKind::BraceClose;
    }

    if matches!(opener, TypeScriptKind::BracketOpen) {
        return TypeScriptKind::BracketClose;
    }

    TypeScriptKind::ParenClose
}

pub fn infix_of(kind: TypeScriptKind) -> Option<(TypeScriptKind, u8, u8)> {
    INFIX
        .iter()
        .find(|row| row.0 == kind)
        .map(|row| (row.1, row.2, row.3))
}

pub const fn is_prefix(kind: TypeScriptKind) -> bool {
    matches!(
        kind,
        TypeScriptKind::Bang
            | TypeScriptKind::DeleteKeyword
            | TypeScriptKind::Minus
            | TypeScriptKind::Plus
            | TypeScriptKind::Tilde
            | TypeScriptKind::TypeofKeyword
            | TypeScriptKind::VoidKeyword
    )
}

pub const fn is_literal(kind: TypeScriptKind) -> bool {
    matches!(
        kind,
        TypeScriptKind::FalseKeyword
            | TypeScriptKind::NullKeyword
            | TypeScriptKind::Number
            | TypeScriptKind::Regex
            | TypeScriptKind::String
            | TypeScriptKind::SuperKeyword
            | TypeScriptKind::ThisKeyword
            | TypeScriptKind::TrueKeyword
            | TypeScriptKind::UndefinedKeyword
    )
}

pub fn literal_kind(kind: TypeScriptKind) -> TypeScriptKind {
    LITERALS
        .iter()
        .find(|row| row.0 == kind)
        .map_or(TypeScriptKind::StringNode, |row| row.1)
}

pub const fn is_name(kind: TypeScriptKind) -> bool {
    matches!(
        kind,
        TypeScriptKind::AsyncKeyword
            | TypeScriptKind::AwaitKeyword
            | TypeScriptKind::Identifier
            | TypeScriptKind::LetKeyword
            | TypeScriptKind::OfKeyword
            | TypeScriptKind::StaticKeyword
            | TypeScriptKind::UndefinedKeyword
            | TypeScriptKind::YieldKeyword
    )
}

pub const fn is_property_name(kind: TypeScriptKind) -> bool {
    is_name(kind) || is_word(kind)
}

pub const fn is_word(kind: TypeScriptKind) -> bool {
    matches!(
        kind,
        TypeScriptKind::BreakKeyword
            | TypeScriptKind::CaseKeyword
            | TypeScriptKind::CatchKeyword
            | TypeScriptKind::ClassKeyword
            | TypeScriptKind::ConstKeyword
            | TypeScriptKind::ContinueKeyword
            | TypeScriptKind::DebuggerKeyword
            | TypeScriptKind::DefaultKeyword
            | TypeScriptKind::DeleteKeyword
            | TypeScriptKind::DoKeyword
            | TypeScriptKind::ElseKeyword
            | TypeScriptKind::ExportKeyword
            | TypeScriptKind::ExtendsKeyword
            | TypeScriptKind::FalseKeyword
            | TypeScriptKind::FinallyKeyword
            | TypeScriptKind::ForKeyword
            | TypeScriptKind::FunctionKeyword
            | TypeScriptKind::IfKeyword
            | TypeScriptKind::ImportKeyword
            | TypeScriptKind::InKeyword
            | TypeScriptKind::InstanceofKeyword
            | TypeScriptKind::NewKeyword
            | TypeScriptKind::NullKeyword
            | TypeScriptKind::ReturnKeyword
            | TypeScriptKind::SuperKeyword
            | TypeScriptKind::SwitchKeyword
            | TypeScriptKind::ThisKeyword
            | TypeScriptKind::ThrowKeyword
            | TypeScriptKind::TrueKeyword
            | TypeScriptKind::TryKeyword
            | TypeScriptKind::TypeofKeyword
            | TypeScriptKind::VarKeyword
            | TypeScriptKind::VoidKeyword
            | TypeScriptKind::WhileKeyword
            | TypeScriptKind::WithKeyword
    )
}
