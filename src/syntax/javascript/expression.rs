use crate::syntax::javascript::kind::JavaScriptKind;
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
pub const POWER_TERNARY_RIGHT: u8 = 7;
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

const LITERALS: [(JavaScriptKind, JavaScriptKind); 8] = [
    (JavaScriptKind::FalseKeyword, JavaScriptKind::False),
    (JavaScriptKind::NullKeyword, JavaScriptKind::Null),
    (JavaScriptKind::Number, JavaScriptKind::NumberNode),
    (JavaScriptKind::Regex, JavaScriptKind::RegexNode),
    (JavaScriptKind::SuperKeyword, JavaScriptKind::Super),
    (JavaScriptKind::ThisKeyword, JavaScriptKind::This),
    (JavaScriptKind::TrueKeyword, JavaScriptKind::True),
    (JavaScriptKind::UndefinedKeyword, JavaScriptKind::Undefined),
];

const INFIX: [(JavaScriptKind, JavaScriptKind, u8, u8); 41] = [
    (
        JavaScriptKind::Ampersand,
        JavaScriptKind::BinaryExpression,
        POWER_AMPERSAND_LEFT,
        POWER_AMPERSAND_RIGHT,
    ),
    (
        JavaScriptKind::AmpersandAmpersand,
        JavaScriptKind::BinaryExpression,
        POWER_AND_LEFT,
        POWER_AND_RIGHT,
    ),
    (
        JavaScriptKind::AmpersandAmpersandEqual,
        JavaScriptKind::AugmentedAssignmentExpression,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        JavaScriptKind::AmpersandEqual,
        JavaScriptKind::AugmentedAssignmentExpression,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        JavaScriptKind::BangEqual,
        JavaScriptKind::BinaryExpression,
        POWER_EQUALITY_LEFT,
        POWER_EQUALITY_RIGHT,
    ),
    (
        JavaScriptKind::BangEqualEqual,
        JavaScriptKind::BinaryExpression,
        POWER_EQUALITY_LEFT,
        POWER_EQUALITY_RIGHT,
    ),
    (
        JavaScriptKind::Bar,
        JavaScriptKind::BinaryExpression,
        POWER_BAR_LEFT,
        POWER_BAR_RIGHT,
    ),
    (
        JavaScriptKind::BarBar,
        JavaScriptKind::BinaryExpression,
        POWER_OR_LEFT,
        POWER_OR_RIGHT,
    ),
    (
        JavaScriptKind::BarBarEqual,
        JavaScriptKind::AugmentedAssignmentExpression,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        JavaScriptKind::BarEqual,
        JavaScriptKind::AugmentedAssignmentExpression,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        JavaScriptKind::Caret,
        JavaScriptKind::BinaryExpression,
        POWER_CARET_LEFT,
        POWER_CARET_RIGHT,
    ),
    (
        JavaScriptKind::CaretEqual,
        JavaScriptKind::AugmentedAssignmentExpression,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        JavaScriptKind::Equal,
        JavaScriptKind::AssignmentExpression,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        JavaScriptKind::EqualEqual,
        JavaScriptKind::BinaryExpression,
        POWER_EQUALITY_LEFT,
        POWER_EQUALITY_RIGHT,
    ),
    (
        JavaScriptKind::EqualEqualEqual,
        JavaScriptKind::BinaryExpression,
        POWER_EQUALITY_LEFT,
        POWER_EQUALITY_RIGHT,
    ),
    (
        JavaScriptKind::Greater,
        JavaScriptKind::BinaryExpression,
        POWER_RELATIONAL_LEFT,
        POWER_RELATIONAL_RIGHT,
    ),
    (
        JavaScriptKind::GreaterEqual,
        JavaScriptKind::BinaryExpression,
        POWER_RELATIONAL_LEFT,
        POWER_RELATIONAL_RIGHT,
    ),
    (
        JavaScriptKind::GreaterGreater,
        JavaScriptKind::BinaryExpression,
        POWER_SHIFT_LEFT,
        POWER_SHIFT_RIGHT,
    ),
    (
        JavaScriptKind::GreaterGreaterEqual,
        JavaScriptKind::AugmentedAssignmentExpression,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        JavaScriptKind::GreaterGreaterGreater,
        JavaScriptKind::BinaryExpression,
        POWER_SHIFT_LEFT,
        POWER_SHIFT_RIGHT,
    ),
    (
        JavaScriptKind::GreaterGreaterGreaterEqual,
        JavaScriptKind::AugmentedAssignmentExpression,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        JavaScriptKind::InKeyword,
        JavaScriptKind::BinaryExpression,
        POWER_RELATIONAL_LEFT,
        POWER_RELATIONAL_RIGHT,
    ),
    (
        JavaScriptKind::InstanceofKeyword,
        JavaScriptKind::BinaryExpression,
        POWER_RELATIONAL_LEFT,
        POWER_RELATIONAL_RIGHT,
    ),
    (
        JavaScriptKind::Less,
        JavaScriptKind::BinaryExpression,
        POWER_RELATIONAL_LEFT,
        POWER_RELATIONAL_RIGHT,
    ),
    (
        JavaScriptKind::LessEqual,
        JavaScriptKind::BinaryExpression,
        POWER_RELATIONAL_LEFT,
        POWER_RELATIONAL_RIGHT,
    ),
    (
        JavaScriptKind::LessLess,
        JavaScriptKind::BinaryExpression,
        POWER_SHIFT_LEFT,
        POWER_SHIFT_RIGHT,
    ),
    (
        JavaScriptKind::LessLessEqual,
        JavaScriptKind::AugmentedAssignmentExpression,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        JavaScriptKind::Minus,
        JavaScriptKind::BinaryExpression,
        POWER_ADDITIVE_LEFT,
        POWER_ADDITIVE_RIGHT,
    ),
    (
        JavaScriptKind::MinusEqual,
        JavaScriptKind::AugmentedAssignmentExpression,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        JavaScriptKind::Percent,
        JavaScriptKind::BinaryExpression,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
    (
        JavaScriptKind::PercentEqual,
        JavaScriptKind::AugmentedAssignmentExpression,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        JavaScriptKind::Plus,
        JavaScriptKind::BinaryExpression,
        POWER_ADDITIVE_LEFT,
        POWER_ADDITIVE_RIGHT,
    ),
    (
        JavaScriptKind::PlusEqual,
        JavaScriptKind::AugmentedAssignmentExpression,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        JavaScriptKind::QuestionQuestion,
        JavaScriptKind::BinaryExpression,
        POWER_NULLISH_LEFT,
        POWER_NULLISH_RIGHT,
    ),
    (
        JavaScriptKind::QuestionQuestionEqual,
        JavaScriptKind::AugmentedAssignmentExpression,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        JavaScriptKind::Slash,
        JavaScriptKind::BinaryExpression,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
    (
        JavaScriptKind::SlashEqual,
        JavaScriptKind::AugmentedAssignmentExpression,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        JavaScriptKind::Star,
        JavaScriptKind::BinaryExpression,
        POWER_MULTIPLICATIVE_LEFT,
        POWER_MULTIPLICATIVE_RIGHT,
    ),
    (
        JavaScriptKind::StarEqual,
        JavaScriptKind::AugmentedAssignmentExpression,
        POWER_ASSIGN_LEFT,
        POWER_ASSIGN_RIGHT,
    ),
    (
        JavaScriptKind::StarStar,
        JavaScriptKind::BinaryExpression,
        POWER_POWER_LEFT,
        POWER_POWER_RIGHT,
    ),
    (
        JavaScriptKind::StarStarEqual,
        JavaScriptKind::AugmentedAssignmentExpression,
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
    pub closer: JavaScriptKind,
    pub content: Checkpoint,
    pub element: Checkpoint,
    pub element_values: u32,
    pub elements: u32,
    pub kind: JavaScriptKind,
    pub power: u8,
    pub stage: u8,
    pub values: u32,
    pub variant: Variant,
}

impl Frame {
    pub const EMPTY: Self = Self {
        bracket: Checkpoint::NONE,
        checkpoint: Checkpoint::NONE,
        closer: JavaScriptKind::ErrorToken,
        content: Checkpoint::NONE,
        element: Checkpoint::NONE,
        element_values: 0,
        elements: 0,
        kind: JavaScriptKind::ErrorNode,
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

pub const fn closer_of(opener: JavaScriptKind) -> JavaScriptKind {
    if matches!(opener, JavaScriptKind::BraceOpen) {
        return JavaScriptKind::BraceClose;
    }

    if matches!(opener, JavaScriptKind::BracketOpen) {
        return JavaScriptKind::BracketClose;
    }

    JavaScriptKind::ParenClose
}

pub fn infix_of(kind: JavaScriptKind) -> Option<(JavaScriptKind, u8, u8)> {
    INFIX
        .iter()
        .find(|row| row.0 == kind)
        .map(|row| (row.1, row.2, row.3))
}

pub const fn is_prefix(kind: JavaScriptKind) -> bool {
    matches!(
        kind,
        JavaScriptKind::Bang
            | JavaScriptKind::DeleteKeyword
            | JavaScriptKind::Minus
            | JavaScriptKind::Plus
            | JavaScriptKind::Tilde
            | JavaScriptKind::TypeofKeyword
            | JavaScriptKind::VoidKeyword
    )
}

pub const fn is_literal(kind: JavaScriptKind) -> bool {
    matches!(
        kind,
        JavaScriptKind::FalseKeyword
            | JavaScriptKind::NullKeyword
            | JavaScriptKind::Number
            | JavaScriptKind::Regex
            | JavaScriptKind::String
            | JavaScriptKind::SuperKeyword
            | JavaScriptKind::ThisKeyword
            | JavaScriptKind::TrueKeyword
            | JavaScriptKind::UndefinedKeyword
    )
}

pub fn literal_kind(kind: JavaScriptKind) -> JavaScriptKind {
    LITERALS
        .iter()
        .find(|row| row.0 == kind)
        .map_or(JavaScriptKind::StringNode, |row| row.1)
}

pub const fn is_name(kind: JavaScriptKind) -> bool {
    matches!(
        kind,
        JavaScriptKind::AsyncKeyword
            | JavaScriptKind::AwaitKeyword
            | JavaScriptKind::Identifier
            | JavaScriptKind::LetKeyword
            | JavaScriptKind::OfKeyword
            | JavaScriptKind::StaticKeyword
            | JavaScriptKind::UndefinedKeyword
            | JavaScriptKind::YieldKeyword
    )
}

pub const fn is_property_name(kind: JavaScriptKind) -> bool {
    is_name(kind) || is_word(kind)
}

pub const fn is_word(kind: JavaScriptKind) -> bool {
    matches!(
        kind,
        JavaScriptKind::BreakKeyword
            | JavaScriptKind::CaseKeyword
            | JavaScriptKind::CatchKeyword
            | JavaScriptKind::ClassKeyword
            | JavaScriptKind::ConstKeyword
            | JavaScriptKind::ContinueKeyword
            | JavaScriptKind::DebuggerKeyword
            | JavaScriptKind::DefaultKeyword
            | JavaScriptKind::DeleteKeyword
            | JavaScriptKind::DoKeyword
            | JavaScriptKind::ElseKeyword
            | JavaScriptKind::ExportKeyword
            | JavaScriptKind::ExtendsKeyword
            | JavaScriptKind::FalseKeyword
            | JavaScriptKind::FinallyKeyword
            | JavaScriptKind::ForKeyword
            | JavaScriptKind::FunctionKeyword
            | JavaScriptKind::IfKeyword
            | JavaScriptKind::ImportKeyword
            | JavaScriptKind::InKeyword
            | JavaScriptKind::InstanceofKeyword
            | JavaScriptKind::NewKeyword
            | JavaScriptKind::NullKeyword
            | JavaScriptKind::ReturnKeyword
            | JavaScriptKind::SuperKeyword
            | JavaScriptKind::SwitchKeyword
            | JavaScriptKind::ThisKeyword
            | JavaScriptKind::ThrowKeyword
            | JavaScriptKind::TrueKeyword
            | JavaScriptKind::TryKeyword
            | JavaScriptKind::TypeofKeyword
            | JavaScriptKind::VarKeyword
            | JavaScriptKind::VoidKeyword
            | JavaScriptKind::WhileKeyword
            | JavaScriptKind::WithKeyword
    )
}
