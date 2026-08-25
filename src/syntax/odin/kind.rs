use crate::syntax::{Category, SyntaxError};
use crate::tree::Kind;

pub const KIND_COUNT: u16 = 216;
pub const NODE_FIRST: u16 = 112;

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
#[repr(u16)]
pub enum OdinKind {
    Ampersand = 0,
    AmpersandAmpersand = 1,
    AmpersandAmpersandEqual = 2,
    AmpersandEqual = 3,
    AmpersandTilde = 4,
    AmpersandTildeEqual = 5,
    Arrow = 6,
    AsmKeyword = 7,
    At = 8,
    AutoCastKeyword = 9,
    Bang = 10,
    BangEqual = 11,
    Bar = 12,
    BarBar = 13,
    BarBarEqual = 14,
    BarEqual = 15,
    BitFieldKeyword = 16,
    BitSetKeyword = 17,
    BraceClose = 18,
    BraceOpen = 19,
    BracketClose = 20,
    BracketOpen = 21,
    BreakKeyword = 22,
    Caret = 23,
    CaseKeyword = 24,
    CastKeyword = 25,
    Character = 26,
    Colon = 27,
    ColonColon = 28,
    ColonEqual = 29,
    Comma = 30,
    Comment = 31,
    CommentBlock = 32,
    CommentTag = 33,
    ContextKeyword = 34,
    ContinueKeyword = 35,
    DeferKeyword = 36,
    Directive = 37,
    DistinctKeyword = 38,
    DoKeyword = 39,
    Dollar = 40,
    Dot = 41,
    DotDot = 42,
    DotDotDot = 43,
    DotDotEqual = 44,
    DotDotLess = 45,
    DynamicKeyword = 46,
    ElseKeyword = 47,
    EnumKeyword = 48,
    Equal = 49,
    EqualEqual = 50,
    ErrorToken = 51,
    FallthroughKeyword = 52,
    FalseKeyword = 53,
    FatArrow = 54,
    Float = 55,
    ForKeyword = 56,
    ForeignKeyword = 57,
    Greater = 58,
    GreaterEqual = 59,
    GreaterGreater = 60,
    GreaterGreaterEqual = 61,
    Identifier = 62,
    IfKeyword = 63,
    ImportKeyword = 64,
    InKeyword = 65,
    Less = 66,
    LessEqual = 67,
    LessLess = 68,
    LessLessEqual = 69,
    MapKeyword = 70,
    MatrixKeyword = 71,
    Minus = 72,
    MinusEqual = 73,
    MinusMinusMinus = 74,
    Newline = 75,
    NilKeyword = 76,
    NotInKeyword = 77,
    Number = 78,
    OrBreakKeyword = 79,
    OrContinueKeyword = 80,
    OrElseKeyword = 81,
    OrReturnKeyword = 82,
    PackageKeyword = 83,
    ParenClose = 84,
    ParenOpen = 85,
    Percent = 86,
    PercentEqual = 87,
    PercentPercent = 88,
    PercentPercentEqual = 89,
    Plus = 90,
    PlusEqual = 91,
    ProcKeyword = 92,
    Question = 93,
    ReturnKeyword = 94,
    Semicolon = 95,
    Slash = 96,
    SlashEqual = 97,
    Star = 98,
    StarEqual = 99,
    StructKeyword = 100,
    SwitchKeyword = 101,
    Text = 102,
    Tilde = 103,
    TildeEqual = 104,
    TransmuteKeyword = 105,
    TrueKeyword = 106,
    TypeidKeyword = 107,
    UnionKeyword = 108,
    UsingKeyword = 109,
    WhenKeyword = 110,
    WhereKeyword = 111,
    Address = 112,
    ArrayType = 113,
    AssignmentStatement = 114,
    Attribute = 115,
    Attributes = 116,
    BinaryExpression = 117,
    BitFieldDeclaration = 118,
    BitFieldType = 119,
    BitSet = 120,
    BitSetType = 121,
    Block = 122,
    BlockComment = 123,
    Boolean = 124,
    BreakStatement = 125,
    BuildTag = 126,
    CallExpression = 127,
    CallingConvention = 128,
    CastExpression = 129,
    CharacterNode = 130,
    CommentNode = 131,
    ConditionalType = 132,
    ConstDeclaration = 133,
    ConstTypeDeclaration = 134,
    ConstantType = 135,
    ContinueStatement = 136,
    DefaultParameter = 137,
    DefaultType = 138,
    DeferStatement = 139,
    DistinctType = 140,
    ElseClause = 141,
    ElseIfClause = 142,
    ElseWhenClause = 143,
    EmptyType = 144,
    EnumDeclaration = 145,
    EnumType = 146,
    ErrorNode = 147,
    EscapeSequence = 148,
    FallthroughStatement = 149,
    Field = 150,
    FieldIdentifier = 151,
    FieldType = 152,
    FloatNode = 153,
    ForStatement = 154,
    ForeignBlock = 155,
    IdentifierNode = 156,
    IfStatement = 157,
    ImportDeclaration = 158,
    InExpression = 159,
    IndexExpression = 160,
    LabelStatement = 161,
    Map = 162,
    MapType = 163,
    Matrix = 164,
    MatrixType = 165,
    MemberExpression = 166,
    NamedType = 167,
    Nil = 168,
    NumberNode = 169,
    OrBreakExpression = 170,
    OrContinueExpression = 171,
    OrReturnExpression = 172,
    OverloadedProcedureDeclaration = 173,
    PackageDeclaration = 174,
    Parameter = 175,
    Parameters = 176,
    ParenthesizedExpression = 177,
    PointerType = 178,
    PolymorphicParameters = 179,
    PolymorphicType = 180,
    Procedure = 181,
    ProcedureDeclaration = 182,
    ProcedureType = 183,
    RangeExpression = 184,
    ReturnStatement = 185,
    SelectorCallExpression = 186,
    SliceExpression = 187,
    SourceFile = 188,
    SpecializedType = 189,
    String = 190,
    StringContent = 191,
    Struct = 192,
    StructDeclaration = 193,
    StructField = 194,
    StructMember = 195,
    StructType = 196,
    SwitchCase = 197,
    SwitchStatement = 198,
    Tag = 199,
    TaggedBlock = 200,
    TernaryExpression = 201,
    TupleType = 202,
    Type = 203,
    UnaryExpression = 204,
    Uninitialized = 205,
    UnionDeclaration = 206,
    UnionType = 207,
    UpdateStatement = 208,
    UsingStatement = 209,
    VarDeclaration = 210,
    VariableDeclaration = 211,
    VariadicExpression = 212,
    VariadicType = 213,
    WhenStatement = 214,
    WhereClause = 215,
}

static KINDS: [OdinKind; KIND_COUNT as usize] = [
    OdinKind::Ampersand,
    OdinKind::AmpersandAmpersand,
    OdinKind::AmpersandAmpersandEqual,
    OdinKind::AmpersandEqual,
    OdinKind::AmpersandTilde,
    OdinKind::AmpersandTildeEqual,
    OdinKind::Arrow,
    OdinKind::AsmKeyword,
    OdinKind::At,
    OdinKind::AutoCastKeyword,
    OdinKind::Bang,
    OdinKind::BangEqual,
    OdinKind::Bar,
    OdinKind::BarBar,
    OdinKind::BarBarEqual,
    OdinKind::BarEqual,
    OdinKind::BitFieldKeyword,
    OdinKind::BitSetKeyword,
    OdinKind::BraceClose,
    OdinKind::BraceOpen,
    OdinKind::BracketClose,
    OdinKind::BracketOpen,
    OdinKind::BreakKeyword,
    OdinKind::Caret,
    OdinKind::CaseKeyword,
    OdinKind::CastKeyword,
    OdinKind::Character,
    OdinKind::Colon,
    OdinKind::ColonColon,
    OdinKind::ColonEqual,
    OdinKind::Comma,
    OdinKind::Comment,
    OdinKind::CommentBlock,
    OdinKind::CommentTag,
    OdinKind::ContextKeyword,
    OdinKind::ContinueKeyword,
    OdinKind::DeferKeyword,
    OdinKind::Directive,
    OdinKind::DistinctKeyword,
    OdinKind::DoKeyword,
    OdinKind::Dollar,
    OdinKind::Dot,
    OdinKind::DotDot,
    OdinKind::DotDotDot,
    OdinKind::DotDotEqual,
    OdinKind::DotDotLess,
    OdinKind::DynamicKeyword,
    OdinKind::ElseKeyword,
    OdinKind::EnumKeyword,
    OdinKind::Equal,
    OdinKind::EqualEqual,
    OdinKind::ErrorToken,
    OdinKind::FallthroughKeyword,
    OdinKind::FalseKeyword,
    OdinKind::FatArrow,
    OdinKind::Float,
    OdinKind::ForKeyword,
    OdinKind::ForeignKeyword,
    OdinKind::Greater,
    OdinKind::GreaterEqual,
    OdinKind::GreaterGreater,
    OdinKind::GreaterGreaterEqual,
    OdinKind::Identifier,
    OdinKind::IfKeyword,
    OdinKind::ImportKeyword,
    OdinKind::InKeyword,
    OdinKind::Less,
    OdinKind::LessEqual,
    OdinKind::LessLess,
    OdinKind::LessLessEqual,
    OdinKind::MapKeyword,
    OdinKind::MatrixKeyword,
    OdinKind::Minus,
    OdinKind::MinusEqual,
    OdinKind::MinusMinusMinus,
    OdinKind::Newline,
    OdinKind::NilKeyword,
    OdinKind::NotInKeyword,
    OdinKind::Number,
    OdinKind::OrBreakKeyword,
    OdinKind::OrContinueKeyword,
    OdinKind::OrElseKeyword,
    OdinKind::OrReturnKeyword,
    OdinKind::PackageKeyword,
    OdinKind::ParenClose,
    OdinKind::ParenOpen,
    OdinKind::Percent,
    OdinKind::PercentEqual,
    OdinKind::PercentPercent,
    OdinKind::PercentPercentEqual,
    OdinKind::Plus,
    OdinKind::PlusEqual,
    OdinKind::ProcKeyword,
    OdinKind::Question,
    OdinKind::ReturnKeyword,
    OdinKind::Semicolon,
    OdinKind::Slash,
    OdinKind::SlashEqual,
    OdinKind::Star,
    OdinKind::StarEqual,
    OdinKind::StructKeyword,
    OdinKind::SwitchKeyword,
    OdinKind::Text,
    OdinKind::Tilde,
    OdinKind::TildeEqual,
    OdinKind::TransmuteKeyword,
    OdinKind::TrueKeyword,
    OdinKind::TypeidKeyword,
    OdinKind::UnionKeyword,
    OdinKind::UsingKeyword,
    OdinKind::WhenKeyword,
    OdinKind::WhereKeyword,
    OdinKind::Address,
    OdinKind::ArrayType,
    OdinKind::AssignmentStatement,
    OdinKind::Attribute,
    OdinKind::Attributes,
    OdinKind::BinaryExpression,
    OdinKind::BitFieldDeclaration,
    OdinKind::BitFieldType,
    OdinKind::BitSet,
    OdinKind::BitSetType,
    OdinKind::Block,
    OdinKind::BlockComment,
    OdinKind::Boolean,
    OdinKind::BreakStatement,
    OdinKind::BuildTag,
    OdinKind::CallExpression,
    OdinKind::CallingConvention,
    OdinKind::CastExpression,
    OdinKind::CharacterNode,
    OdinKind::CommentNode,
    OdinKind::ConditionalType,
    OdinKind::ConstDeclaration,
    OdinKind::ConstTypeDeclaration,
    OdinKind::ConstantType,
    OdinKind::ContinueStatement,
    OdinKind::DefaultParameter,
    OdinKind::DefaultType,
    OdinKind::DeferStatement,
    OdinKind::DistinctType,
    OdinKind::ElseClause,
    OdinKind::ElseIfClause,
    OdinKind::ElseWhenClause,
    OdinKind::EmptyType,
    OdinKind::EnumDeclaration,
    OdinKind::EnumType,
    OdinKind::ErrorNode,
    OdinKind::EscapeSequence,
    OdinKind::FallthroughStatement,
    OdinKind::Field,
    OdinKind::FieldIdentifier,
    OdinKind::FieldType,
    OdinKind::FloatNode,
    OdinKind::ForStatement,
    OdinKind::ForeignBlock,
    OdinKind::IdentifierNode,
    OdinKind::IfStatement,
    OdinKind::ImportDeclaration,
    OdinKind::InExpression,
    OdinKind::IndexExpression,
    OdinKind::LabelStatement,
    OdinKind::Map,
    OdinKind::MapType,
    OdinKind::Matrix,
    OdinKind::MatrixType,
    OdinKind::MemberExpression,
    OdinKind::NamedType,
    OdinKind::Nil,
    OdinKind::NumberNode,
    OdinKind::OrBreakExpression,
    OdinKind::OrContinueExpression,
    OdinKind::OrReturnExpression,
    OdinKind::OverloadedProcedureDeclaration,
    OdinKind::PackageDeclaration,
    OdinKind::Parameter,
    OdinKind::Parameters,
    OdinKind::ParenthesizedExpression,
    OdinKind::PointerType,
    OdinKind::PolymorphicParameters,
    OdinKind::PolymorphicType,
    OdinKind::Procedure,
    OdinKind::ProcedureDeclaration,
    OdinKind::ProcedureType,
    OdinKind::RangeExpression,
    OdinKind::ReturnStatement,
    OdinKind::SelectorCallExpression,
    OdinKind::SliceExpression,
    OdinKind::SourceFile,
    OdinKind::SpecializedType,
    OdinKind::String,
    OdinKind::StringContent,
    OdinKind::Struct,
    OdinKind::StructDeclaration,
    OdinKind::StructField,
    OdinKind::StructMember,
    OdinKind::StructType,
    OdinKind::SwitchCase,
    OdinKind::SwitchStatement,
    OdinKind::Tag,
    OdinKind::TaggedBlock,
    OdinKind::TernaryExpression,
    OdinKind::TupleType,
    OdinKind::Type,
    OdinKind::UnaryExpression,
    OdinKind::Uninitialized,
    OdinKind::UnionDeclaration,
    OdinKind::UnionType,
    OdinKind::UpdateStatement,
    OdinKind::UsingStatement,
    OdinKind::VarDeclaration,
    OdinKind::VariableDeclaration,
    OdinKind::VariadicExpression,
    OdinKind::VariadicType,
    OdinKind::WhenStatement,
    OdinKind::WhereClause,
];

static NAMES: [&str; KIND_COUNT as usize] = [
    "Ampersand",
    "AmpersandAmpersand",
    "AmpersandAmpersandEqual",
    "AmpersandEqual",
    "AmpersandTilde",
    "AmpersandTildeEqual",
    "Arrow",
    "AsmKeyword",
    "At",
    "AutoCastKeyword",
    "Bang",
    "BangEqual",
    "Bar",
    "BarBar",
    "BarBarEqual",
    "BarEqual",
    "BitFieldKeyword",
    "BitSetKeyword",
    "BraceClose",
    "BraceOpen",
    "BracketClose",
    "BracketOpen",
    "BreakKeyword",
    "Caret",
    "CaseKeyword",
    "CastKeyword",
    "Character",
    "Colon",
    "ColonColon",
    "ColonEqual",
    "Comma",
    "Comment",
    "CommentBlock",
    "CommentTag",
    "ContextKeyword",
    "ContinueKeyword",
    "DeferKeyword",
    "Directive",
    "DistinctKeyword",
    "DoKeyword",
    "Dollar",
    "Dot",
    "DotDot",
    "DotDotDot",
    "DotDotEqual",
    "DotDotLess",
    "DynamicKeyword",
    "ElseKeyword",
    "EnumKeyword",
    "Equal",
    "EqualEqual",
    "ErrorToken",
    "FallthroughKeyword",
    "FalseKeyword",
    "FatArrow",
    "Float",
    "ForKeyword",
    "ForeignKeyword",
    "Greater",
    "GreaterEqual",
    "GreaterGreater",
    "GreaterGreaterEqual",
    "Identifier",
    "IfKeyword",
    "ImportKeyword",
    "InKeyword",
    "Less",
    "LessEqual",
    "LessLess",
    "LessLessEqual",
    "MapKeyword",
    "MatrixKeyword",
    "Minus",
    "MinusEqual",
    "MinusMinusMinus",
    "Newline",
    "NilKeyword",
    "NotInKeyword",
    "Number",
    "OrBreakKeyword",
    "OrContinueKeyword",
    "OrElseKeyword",
    "OrReturnKeyword",
    "PackageKeyword",
    "ParenClose",
    "ParenOpen",
    "Percent",
    "PercentEqual",
    "PercentPercent",
    "PercentPercentEqual",
    "Plus",
    "PlusEqual",
    "ProcKeyword",
    "Question",
    "ReturnKeyword",
    "Semicolon",
    "Slash",
    "SlashEqual",
    "Star",
    "StarEqual",
    "StructKeyword",
    "SwitchKeyword",
    "Text",
    "Tilde",
    "TildeEqual",
    "TransmuteKeyword",
    "TrueKeyword",
    "TypeidKeyword",
    "UnionKeyword",
    "UsingKeyword",
    "WhenKeyword",
    "WhereKeyword",
    "address",
    "array_type",
    "assignment_statement",
    "attribute",
    "attributes",
    "binary_expression",
    "bit_field_declaration",
    "bit_field_type",
    "bit_set",
    "bit_set_type",
    "block",
    "block_comment",
    "boolean",
    "break_statement",
    "build_tag",
    "call_expression",
    "calling_convention",
    "cast_expression",
    "character",
    "comment",
    "conditional_type",
    "const_declaration",
    "const_type_declaration",
    "constant_type",
    "continue_statement",
    "default_parameter",
    "default_type",
    "defer_statement",
    "distinct_type",
    "else_clause",
    "else_if_clause",
    "else_when_clause",
    "empty_type",
    "enum_declaration",
    "enum_type",
    "error_node",
    "escape_sequence",
    "fallthrough_statement",
    "field",
    "field_identifier",
    "field_type",
    "float",
    "for_statement",
    "foreign_block",
    "identifier",
    "if_statement",
    "import_declaration",
    "in_expression",
    "index_expression",
    "label_statement",
    "map",
    "map_type",
    "matrix",
    "matrix_type",
    "member_expression",
    "named_type",
    "nil",
    "number",
    "or_break_expression",
    "or_continue_expression",
    "or_return_expression",
    "overloaded_procedure_declaration",
    "package_declaration",
    "parameter",
    "parameters",
    "parenthesized_expression",
    "pointer_type",
    "polymorphic_parameters",
    "polymorphic_type",
    "procedure",
    "procedure_declaration",
    "procedure_type",
    "range_expression",
    "return_statement",
    "selector_call_expression",
    "slice_expression",
    "source_file",
    "specialized_type",
    "string",
    "string_content",
    "struct",
    "struct_declaration",
    "struct_field",
    "struct_member",
    "struct_type",
    "switch_case",
    "switch_statement",
    "tag",
    "tagged_block",
    "ternary_expression",
    "tuple_type",
    "type",
    "unary_expression",
    "uninitialized",
    "union_declaration",
    "union_type",
    "update_statement",
    "using_statement",
    "var_declaration",
    "variable_declaration",
    "variadic_expression",
    "variadic_type",
    "when_statement",
    "where_clause",
];

impl Kind for OdinKind {
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

impl OdinKind {
    #[expect(
        clippy::too_many_lines,
        reason = "the projection names every kind, so its length is the grammar's and a shorter \
                  form would be a table the compiler cannot check"
    )]
    pub const fn category(self) -> Category {
        match self {
            Self::AssignmentStatement | Self::UpdateStatement => Category::Assignment,
            Self::Attribute | Self::Attributes | Self::BuildTag | Self::Tag => Category::Attribute,
            Self::Block | Self::ElseClause | Self::ForeignBlock | Self::TaggedBlock => {
                Category::Block
            }
            Self::ElseIfClause
            | Self::ElseWhenClause
            | Self::IfStatement
            | Self::SwitchCase
            | Self::TernaryExpression
            | Self::WhenStatement => Category::Branch,
            Self::CallExpression | Self::SelectorCallExpression => Category::Call,
            Self::ConstDeclaration
            | Self::ConstTypeDeclaration
            | Self::Field
            | Self::StructField
            | Self::StructMember
            | Self::VarDeclaration
            | Self::VariableDeclaration => Category::Declaration,
            Self::Address
            | Self::BinaryExpression
            | Self::CastExpression
            | Self::DeferStatement
            | Self::InExpression
            | Self::IndexExpression
            | Self::MemberExpression
            | Self::OrBreakExpression
            | Self::OrContinueExpression
            | Self::OrReturnExpression
            | Self::ParenthesizedExpression
            | Self::RangeExpression
            | Self::SliceExpression
            | Self::UnaryExpression
            | Self::UsingStatement
            | Self::VariadicExpression => Category::Expression,
            Self::SourceFile => Category::File,
            Self::OverloadedProcedureDeclaration | Self::ProcedureDeclaration => Category::Function,
            Self::ImportDeclaration | Self::PackageDeclaration => Category::Import,
            Self::Procedure => Category::Lambda,
            Self::ForStatement => Category::Loop,
            Self::SwitchStatement => Category::Match,
            Self::FieldIdentifier | Self::Identifier | Self::IdentifierNode => Category::Name,
            Self::DefaultParameter | Self::Parameter => Category::Parameter,
            Self::Parameters | Self::PolymorphicParameters => Category::Parameters,
            Self::ReturnStatement => Category::Return,
            Self::BitFieldDeclaration
            | Self::BitFieldType
            | Self::BitSet
            | Self::BitSetType
            | Self::EnumDeclaration
            | Self::EnumType
            | Self::Struct
            | Self::StructDeclaration
            | Self::StructType
            | Self::UnionDeclaration
            | Self::UnionType => Category::Struct,
            Self::ArrayType
            | Self::CallingConvention
            | Self::ConditionalType
            | Self::ConstantType
            | Self::DefaultType
            | Self::DistinctType
            | Self::EmptyType
            | Self::FieldType
            | Self::Map
            | Self::MapType
            | Self::Matrix
            | Self::MatrixType
            | Self::NamedType
            | Self::PointerType
            | Self::PolymorphicType
            | Self::ProcedureType
            | Self::SpecializedType
            | Self::TupleType
            | Self::Type
            | Self::VariadicType
            | Self::WhereClause => Category::Type,
            Self::Boolean
            | Self::Character
            | Self::CharacterNode
            | Self::FalseKeyword
            | Self::Float
            | Self::FloatNode
            | Self::Nil
            | Self::NilKeyword
            | Self::Number
            | Self::NumberNode
            | Self::String
            | Self::StringContent
            | Self::TrueKeyword
            | Self::Uninitialized => Category::Value,
            Self::Ampersand
            | Self::AmpersandAmpersand
            | Self::AmpersandAmpersandEqual
            | Self::AmpersandEqual
            | Self::AmpersandTilde
            | Self::AmpersandTildeEqual
            | Self::Arrow
            | Self::AsmKeyword
            | Self::At
            | Self::AutoCastKeyword
            | Self::Bang
            | Self::BangEqual
            | Self::Bar
            | Self::BarBar
            | Self::BarBarEqual
            | Self::BarEqual
            | Self::BitFieldKeyword
            | Self::BitSetKeyword
            | Self::BlockComment
            | Self::BraceClose
            | Self::BraceOpen
            | Self::BracketClose
            | Self::BracketOpen
            | Self::BreakKeyword
            | Self::BreakStatement
            | Self::Caret
            | Self::CaseKeyword
            | Self::CastKeyword
            | Self::Colon
            | Self::ColonColon
            | Self::ColonEqual
            | Self::Comma
            | Self::Comment
            | Self::CommentBlock
            | Self::CommentNode
            | Self::CommentTag
            | Self::ContextKeyword
            | Self::ContinueKeyword
            | Self::ContinueStatement
            | Self::DeferKeyword
            | Self::Directive
            | Self::DistinctKeyword
            | Self::DoKeyword
            | Self::Dollar
            | Self::Dot
            | Self::DotDot
            | Self::DotDotDot
            | Self::DotDotEqual
            | Self::DotDotLess
            | Self::DynamicKeyword
            | Self::ElseKeyword
            | Self::EnumKeyword
            | Self::Equal
            | Self::EqualEqual
            | Self::ErrorNode
            | Self::ErrorToken
            | Self::EscapeSequence
            | Self::FallthroughKeyword
            | Self::FallthroughStatement
            | Self::FatArrow
            | Self::ForKeyword
            | Self::ForeignKeyword
            | Self::Greater
            | Self::GreaterEqual
            | Self::GreaterGreater
            | Self::GreaterGreaterEqual
            | Self::IfKeyword
            | Self::ImportKeyword
            | Self::InKeyword
            | Self::LabelStatement
            | Self::Less
            | Self::LessEqual
            | Self::LessLess
            | Self::LessLessEqual
            | Self::MapKeyword
            | Self::MatrixKeyword
            | Self::Minus
            | Self::MinusEqual
            | Self::MinusMinusMinus
            | Self::Newline
            | Self::NotInKeyword
            | Self::OrBreakKeyword
            | Self::OrContinueKeyword
            | Self::OrElseKeyword
            | Self::OrReturnKeyword
            | Self::PackageKeyword
            | Self::ParenClose
            | Self::ParenOpen
            | Self::Percent
            | Self::PercentEqual
            | Self::PercentPercent
            | Self::PercentPercentEqual
            | Self::Plus
            | Self::PlusEqual
            | Self::ProcKeyword
            | Self::Question
            | Self::ReturnKeyword
            | Self::Semicolon
            | Self::Slash
            | Self::SlashEqual
            | Self::Star
            | Self::StarEqual
            | Self::StructKeyword
            | Self::SwitchKeyword
            | Self::Text
            | Self::Tilde
            | Self::TildeEqual
            | Self::TransmuteKeyword
            | Self::TypeidKeyword
            | Self::UnionKeyword
            | Self::UsingKeyword
            | Self::WhenKeyword
            | Self::WhereKeyword => Category::Other,
        }
    }

    pub const fn is_node(self) -> bool {
        self.to_u16() >= NODE_FIRST
    }

    pub const fn is_token(self) -> bool {
        self.to_u16() < NODE_FIRST
    }

    pub const fn is_trivia(self) -> bool {
        matches!(self, Self::Comment | Self::CommentBlock | Self::CommentTag)
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
            assert_eq!(OdinKind::of_u16(kind.to_u16()), Some(*kind));
            assert_eq!(OdinKind::of_name(kind.name()), Some(*kind));
        }

        assert_eq!(KINDS.len(), KIND_COUNT as usize);
        assert_eq!(NAMES.len(), KIND_COUNT as usize);
        assert!(OdinKind::of_u16(KIND_COUNT).is_none());
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
