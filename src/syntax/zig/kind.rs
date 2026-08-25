use crate::syntax::{Category, SyntaxError};
use crate::tree::Kind;

pub const KIND_COUNT: u16 = 228;
pub const NODE_FIRST: u16 = 117;

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
#[repr(u16)]
pub enum ZigKind {
    AddrspaceKeyword = 0,
    AlignKeyword = 1,
    AllowzeroKeyword = 2,
    Ampersand = 3,
    AmpersandEqual = 4,
    AndKeyword = 5,
    AnyframeKeyword = 6,
    AnytypeKeyword = 7,
    Arrow = 8,
    AsmKeyword = 9,
    Bang = 10,
    BangEqual = 11,
    BraceClose = 12,
    BraceOpen = 13,
    BracketClose = 14,
    BracketOpen = 15,
    BreakKeyword = 16,
    Builtin = 17,
    CallconvKeyword = 18,
    Caret = 19,
    CaretEqual = 20,
    CatchKeyword = 21,
    Character = 22,
    Colon = 23,
    Comma = 24,
    Comment = 25,
    ComptimeKeyword = 26,
    ConstKeyword = 27,
    ContinueKeyword = 28,
    DeferKeyword = 29,
    DocComment = 30,
    Dot = 31,
    DotAsterisk = 32,
    DotDot = 33,
    DotDotDot = 34,
    DotQuestion = 35,
    ElseKeyword = 36,
    EnumKeyword = 37,
    Equal = 38,
    EqualEqual = 39,
    ErrdeferKeyword = 40,
    ErrorKeyword = 41,
    ErrorToken = 42,
    ExportKeyword = 43,
    ExternKeyword = 44,
    FnKeyword = 45,
    ForKeyword = 46,
    Greater = 47,
    GreaterEqual = 48,
    GreaterGreater = 49,
    GreaterGreaterEqual = 50,
    Identifier = 51,
    IfKeyword = 52,
    InlineKeyword = 53,
    Less = 54,
    LessEqual = 55,
    LessLess = 56,
    LessLessEqual = 57,
    LessLessPipe = 58,
    LessLessPipeEqual = 59,
    LinksectionKeyword = 60,
    Minus = 61,
    MinusEqual = 62,
    MinusPercent = 63,
    MinusPercentEqual = 64,
    MinusPipe = 65,
    MinusPipeEqual = 66,
    NoaliasKeyword = 67,
    NoinlineKeyword = 68,
    NosuspendKeyword = 69,
    Number = 70,
    OpaqueKeyword = 71,
    OrKeyword = 72,
    OrelseKeyword = 73,
    PackedKeyword = 74,
    ParenClose = 75,
    ParenOpen = 76,
    Percent = 77,
    PercentEqual = 78,
    Pipe = 79,
    PipeEqual = 80,
    PipePipe = 81,
    Plus = 82,
    PlusEqual = 83,
    PlusPercent = 84,
    PlusPercentEqual = 85,
    PlusPipe = 86,
    PlusPipeEqual = 87,
    PlusPlus = 88,
    PubKeyword = 89,
    Question = 90,
    ResumeKeyword = 91,
    ReturnKeyword = 92,
    Semicolon = 93,
    Slash = 94,
    SlashEqual = 95,
    Star = 96,
    StarEqual = 97,
    StarPercent = 98,
    StarPercentEqual = 99,
    StarPipe = 100,
    StarPipeEqual = 101,
    StarStar = 102,
    StructKeyword = 103,
    SuspendKeyword = 104,
    SwitchKeyword = 105,
    TestKeyword = 106,
    Text = 107,
    TextLine = 108,
    ThreadlocalKeyword = 109,
    Tilde = 110,
    TryKeyword = 111,
    UnionKeyword = 112,
    UnreachableKeyword = 113,
    VarKeyword = 114,
    VolatileKeyword = 115,
    WhileKeyword = 116,
    Add = 117,
    AddSat = 118,
    AddWrap = 119,
    AddressOf = 120,
    AnyframeLiteral = 121,
    AnyframeType = 122,
    ArrayAccess = 123,
    ArrayCat = 124,
    ArrayInit = 125,
    ArrayInitDot = 126,
    ArrayMult = 127,
    ArrayType = 128,
    Asm = 129,
    AsmInput = 130,
    AsmOutput = 131,
    Assign = 132,
    AssignAdd = 133,
    AssignAddSat = 134,
    AssignAddWrap = 135,
    AssignBitAnd = 136,
    AssignBitOr = 137,
    AssignBitXor = 138,
    AssignDestructure = 139,
    AssignDiv = 140,
    AssignMod = 141,
    AssignMul = 142,
    AssignMulSat = 143,
    AssignMulWrap = 144,
    AssignShl = 145,
    AssignShlSat = 146,
    AssignShr = 147,
    AssignSub = 148,
    AssignSubSat = 149,
    AssignSubWrap = 150,
    BangEqualNode = 151,
    BitAnd = 152,
    BitNot = 153,
    BitOr = 154,
    BitXor = 155,
    Block = 156,
    BoolAnd = 157,
    BoolNot = 158,
    BoolOr = 159,
    Break = 160,
    BuiltinCall = 161,
    Call = 162,
    Catch = 163,
    CharLiteral = 164,
    Comptime = 165,
    ContainerDecl = 166,
    ContainerField = 167,
    Continue = 168,
    Defer = 169,
    Deref = 170,
    Div = 171,
    EnumLiteral = 172,
    EqualEqualNode = 173,
    Errdefer = 174,
    ErrorNode = 175,
    ErrorSetDecl = 176,
    ErrorUnion = 177,
    ErrorValue = 178,
    FieldAccess = 179,
    FnDecl = 180,
    FnProto = 181,
    For = 182,
    ForRange = 183,
    GreaterOrEqual = 184,
    GreaterThan = 185,
    GroupedExpression = 186,
    IdentifierNode = 187,
    If = 188,
    LessOrEqual = 189,
    LessThan = 190,
    MergeErrorSets = 191,
    Mod = 192,
    Mul = 193,
    MulSat = 194,
    MulWrap = 195,
    MultilineStringLiteral = 196,
    Negation = 197,
    NegationWrap = 198,
    Nosuspend = 199,
    NumberLiteral = 200,
    OptionalType = 201,
    Orelse = 202,
    PtrType = 203,
    Resume = 204,
    Return = 205,
    Root = 206,
    Shl = 207,
    ShlSat = 208,
    Shr = 209,
    Slice = 210,
    StringLiteral = 211,
    StructInit = 212,
    StructInitDot = 213,
    Sub = 214,
    SubSat = 215,
    SubWrap = 216,
    Suspend = 217,
    Switch = 218,
    SwitchCase = 219,
    SwitchRange = 220,
    TaggedUnion = 221,
    TestDecl = 222,
    Try = 223,
    UnreachableLiteral = 224,
    UnwrapOptional = 225,
    VarDecl = 226,
    While = 227,
}

static KINDS: [ZigKind; KIND_COUNT as usize] = [
    ZigKind::AddrspaceKeyword,
    ZigKind::AlignKeyword,
    ZigKind::AllowzeroKeyword,
    ZigKind::Ampersand,
    ZigKind::AmpersandEqual,
    ZigKind::AndKeyword,
    ZigKind::AnyframeKeyword,
    ZigKind::AnytypeKeyword,
    ZigKind::Arrow,
    ZigKind::AsmKeyword,
    ZigKind::Bang,
    ZigKind::BangEqual,
    ZigKind::BraceClose,
    ZigKind::BraceOpen,
    ZigKind::BracketClose,
    ZigKind::BracketOpen,
    ZigKind::BreakKeyword,
    ZigKind::Builtin,
    ZigKind::CallconvKeyword,
    ZigKind::Caret,
    ZigKind::CaretEqual,
    ZigKind::CatchKeyword,
    ZigKind::Character,
    ZigKind::Colon,
    ZigKind::Comma,
    ZigKind::Comment,
    ZigKind::ComptimeKeyword,
    ZigKind::ConstKeyword,
    ZigKind::ContinueKeyword,
    ZigKind::DeferKeyword,
    ZigKind::DocComment,
    ZigKind::Dot,
    ZigKind::DotAsterisk,
    ZigKind::DotDot,
    ZigKind::DotDotDot,
    ZigKind::DotQuestion,
    ZigKind::ElseKeyword,
    ZigKind::EnumKeyword,
    ZigKind::Equal,
    ZigKind::EqualEqual,
    ZigKind::ErrdeferKeyword,
    ZigKind::ErrorKeyword,
    ZigKind::ErrorToken,
    ZigKind::ExportKeyword,
    ZigKind::ExternKeyword,
    ZigKind::FnKeyword,
    ZigKind::ForKeyword,
    ZigKind::Greater,
    ZigKind::GreaterEqual,
    ZigKind::GreaterGreater,
    ZigKind::GreaterGreaterEqual,
    ZigKind::Identifier,
    ZigKind::IfKeyword,
    ZigKind::InlineKeyword,
    ZigKind::Less,
    ZigKind::LessEqual,
    ZigKind::LessLess,
    ZigKind::LessLessEqual,
    ZigKind::LessLessPipe,
    ZigKind::LessLessPipeEqual,
    ZigKind::LinksectionKeyword,
    ZigKind::Minus,
    ZigKind::MinusEqual,
    ZigKind::MinusPercent,
    ZigKind::MinusPercentEqual,
    ZigKind::MinusPipe,
    ZigKind::MinusPipeEqual,
    ZigKind::NoaliasKeyword,
    ZigKind::NoinlineKeyword,
    ZigKind::NosuspendKeyword,
    ZigKind::Number,
    ZigKind::OpaqueKeyword,
    ZigKind::OrKeyword,
    ZigKind::OrelseKeyword,
    ZigKind::PackedKeyword,
    ZigKind::ParenClose,
    ZigKind::ParenOpen,
    ZigKind::Percent,
    ZigKind::PercentEqual,
    ZigKind::Pipe,
    ZigKind::PipeEqual,
    ZigKind::PipePipe,
    ZigKind::Plus,
    ZigKind::PlusEqual,
    ZigKind::PlusPercent,
    ZigKind::PlusPercentEqual,
    ZigKind::PlusPipe,
    ZigKind::PlusPipeEqual,
    ZigKind::PlusPlus,
    ZigKind::PubKeyword,
    ZigKind::Question,
    ZigKind::ResumeKeyword,
    ZigKind::ReturnKeyword,
    ZigKind::Semicolon,
    ZigKind::Slash,
    ZigKind::SlashEqual,
    ZigKind::Star,
    ZigKind::StarEqual,
    ZigKind::StarPercent,
    ZigKind::StarPercentEqual,
    ZigKind::StarPipe,
    ZigKind::StarPipeEqual,
    ZigKind::StarStar,
    ZigKind::StructKeyword,
    ZigKind::SuspendKeyword,
    ZigKind::SwitchKeyword,
    ZigKind::TestKeyword,
    ZigKind::Text,
    ZigKind::TextLine,
    ZigKind::ThreadlocalKeyword,
    ZigKind::Tilde,
    ZigKind::TryKeyword,
    ZigKind::UnionKeyword,
    ZigKind::UnreachableKeyword,
    ZigKind::VarKeyword,
    ZigKind::VolatileKeyword,
    ZigKind::WhileKeyword,
    ZigKind::Add,
    ZigKind::AddSat,
    ZigKind::AddWrap,
    ZigKind::AddressOf,
    ZigKind::AnyframeLiteral,
    ZigKind::AnyframeType,
    ZigKind::ArrayAccess,
    ZigKind::ArrayCat,
    ZigKind::ArrayInit,
    ZigKind::ArrayInitDot,
    ZigKind::ArrayMult,
    ZigKind::ArrayType,
    ZigKind::Asm,
    ZigKind::AsmInput,
    ZigKind::AsmOutput,
    ZigKind::Assign,
    ZigKind::AssignAdd,
    ZigKind::AssignAddSat,
    ZigKind::AssignAddWrap,
    ZigKind::AssignBitAnd,
    ZigKind::AssignBitOr,
    ZigKind::AssignBitXor,
    ZigKind::AssignDestructure,
    ZigKind::AssignDiv,
    ZigKind::AssignMod,
    ZigKind::AssignMul,
    ZigKind::AssignMulSat,
    ZigKind::AssignMulWrap,
    ZigKind::AssignShl,
    ZigKind::AssignShlSat,
    ZigKind::AssignShr,
    ZigKind::AssignSub,
    ZigKind::AssignSubSat,
    ZigKind::AssignSubWrap,
    ZigKind::BangEqualNode,
    ZigKind::BitAnd,
    ZigKind::BitNot,
    ZigKind::BitOr,
    ZigKind::BitXor,
    ZigKind::Block,
    ZigKind::BoolAnd,
    ZigKind::BoolNot,
    ZigKind::BoolOr,
    ZigKind::Break,
    ZigKind::BuiltinCall,
    ZigKind::Call,
    ZigKind::Catch,
    ZigKind::CharLiteral,
    ZigKind::Comptime,
    ZigKind::ContainerDecl,
    ZigKind::ContainerField,
    ZigKind::Continue,
    ZigKind::Defer,
    ZigKind::Deref,
    ZigKind::Div,
    ZigKind::EnumLiteral,
    ZigKind::EqualEqualNode,
    ZigKind::Errdefer,
    ZigKind::ErrorNode,
    ZigKind::ErrorSetDecl,
    ZigKind::ErrorUnion,
    ZigKind::ErrorValue,
    ZigKind::FieldAccess,
    ZigKind::FnDecl,
    ZigKind::FnProto,
    ZigKind::For,
    ZigKind::ForRange,
    ZigKind::GreaterOrEqual,
    ZigKind::GreaterThan,
    ZigKind::GroupedExpression,
    ZigKind::IdentifierNode,
    ZigKind::If,
    ZigKind::LessOrEqual,
    ZigKind::LessThan,
    ZigKind::MergeErrorSets,
    ZigKind::Mod,
    ZigKind::Mul,
    ZigKind::MulSat,
    ZigKind::MulWrap,
    ZigKind::MultilineStringLiteral,
    ZigKind::Negation,
    ZigKind::NegationWrap,
    ZigKind::Nosuspend,
    ZigKind::NumberLiteral,
    ZigKind::OptionalType,
    ZigKind::Orelse,
    ZigKind::PtrType,
    ZigKind::Resume,
    ZigKind::Return,
    ZigKind::Root,
    ZigKind::Shl,
    ZigKind::ShlSat,
    ZigKind::Shr,
    ZigKind::Slice,
    ZigKind::StringLiteral,
    ZigKind::StructInit,
    ZigKind::StructInitDot,
    ZigKind::Sub,
    ZigKind::SubSat,
    ZigKind::SubWrap,
    ZigKind::Suspend,
    ZigKind::Switch,
    ZigKind::SwitchCase,
    ZigKind::SwitchRange,
    ZigKind::TaggedUnion,
    ZigKind::TestDecl,
    ZigKind::Try,
    ZigKind::UnreachableLiteral,
    ZigKind::UnwrapOptional,
    ZigKind::VarDecl,
    ZigKind::While,
];

static NAMES: [&str; KIND_COUNT as usize] = [
    "AddrspaceKeyword",
    "AlignKeyword",
    "AllowzeroKeyword",
    "Ampersand",
    "AmpersandEqual",
    "AndKeyword",
    "AnyframeKeyword",
    "AnytypeKeyword",
    "Arrow",
    "AsmKeyword",
    "Bang",
    "BangEqual",
    "BraceClose",
    "BraceOpen",
    "BracketClose",
    "BracketOpen",
    "BreakKeyword",
    "Builtin",
    "CallconvKeyword",
    "Caret",
    "CaretEqual",
    "CatchKeyword",
    "Character",
    "Colon",
    "Comma",
    "Comment",
    "ComptimeKeyword",
    "ConstKeyword",
    "ContinueKeyword",
    "DeferKeyword",
    "DocComment",
    "Dot",
    "DotAsterisk",
    "DotDot",
    "DotDotDot",
    "DotQuestion",
    "ElseKeyword",
    "EnumKeyword",
    "Equal",
    "EqualEqual",
    "ErrdeferKeyword",
    "ErrorKeyword",
    "ErrorToken",
    "ExportKeyword",
    "ExternKeyword",
    "FnKeyword",
    "ForKeyword",
    "Greater",
    "GreaterEqual",
    "GreaterGreater",
    "GreaterGreaterEqual",
    "Identifier",
    "IfKeyword",
    "InlineKeyword",
    "Less",
    "LessEqual",
    "LessLess",
    "LessLessEqual",
    "LessLessPipe",
    "LessLessPipeEqual",
    "LinksectionKeyword",
    "Minus",
    "MinusEqual",
    "MinusPercent",
    "MinusPercentEqual",
    "MinusPipe",
    "MinusPipeEqual",
    "NoaliasKeyword",
    "NoinlineKeyword",
    "NosuspendKeyword",
    "Number",
    "OpaqueKeyword",
    "OrKeyword",
    "OrelseKeyword",
    "PackedKeyword",
    "ParenClose",
    "ParenOpen",
    "Percent",
    "PercentEqual",
    "Pipe",
    "PipeEqual",
    "PipePipe",
    "Plus",
    "PlusEqual",
    "PlusPercent",
    "PlusPercentEqual",
    "PlusPipe",
    "PlusPipeEqual",
    "PlusPlus",
    "PubKeyword",
    "Question",
    "ResumeKeyword",
    "ReturnKeyword",
    "Semicolon",
    "Slash",
    "SlashEqual",
    "Star",
    "StarEqual",
    "StarPercent",
    "StarPercentEqual",
    "StarPipe",
    "StarPipeEqual",
    "StarStar",
    "StructKeyword",
    "SuspendKeyword",
    "SwitchKeyword",
    "TestKeyword",
    "Text",
    "TextLine",
    "ThreadlocalKeyword",
    "Tilde",
    "TryKeyword",
    "UnionKeyword",
    "UnreachableKeyword",
    "VarKeyword",
    "VolatileKeyword",
    "WhileKeyword",
    "add",
    "add_sat",
    "add_wrap",
    "address_of",
    "anyframe_literal",
    "anyframe_type",
    "array_access",
    "array_cat",
    "array_init",
    "array_init_dot",
    "array_mult",
    "array_type",
    "asm",
    "asm_input",
    "asm_output",
    "assign",
    "assign_add",
    "assign_add_sat",
    "assign_add_wrap",
    "assign_bit_and",
    "assign_bit_or",
    "assign_bit_xor",
    "assign_destructure",
    "assign_div",
    "assign_mod",
    "assign_mul",
    "assign_mul_sat",
    "assign_mul_wrap",
    "assign_shl",
    "assign_shl_sat",
    "assign_shr",
    "assign_sub",
    "assign_sub_sat",
    "assign_sub_wrap",
    "bang_equal",
    "bit_and",
    "bit_not",
    "bit_or",
    "bit_xor",
    "block",
    "bool_and",
    "bool_not",
    "bool_or",
    "break",
    "builtin_call",
    "call",
    "catch",
    "char_literal",
    "comptime",
    "container_decl",
    "container_field",
    "continue",
    "defer",
    "deref",
    "div",
    "enum_literal",
    "equal_equal",
    "errdefer",
    "error_node",
    "error_set_decl",
    "error_union",
    "error_value",
    "field_access",
    "fn_decl",
    "fn_proto",
    "for",
    "for_range",
    "greater_or_equal",
    "greater_than",
    "grouped_expression",
    "identifier",
    "if",
    "less_or_equal",
    "less_than",
    "merge_error_sets",
    "mod",
    "mul",
    "mul_sat",
    "mul_wrap",
    "multiline_string_literal",
    "negation",
    "negation_wrap",
    "nosuspend",
    "number_literal",
    "optional_type",
    "orelse",
    "ptr_type",
    "resume",
    "return",
    "root",
    "shl",
    "shl_sat",
    "shr",
    "slice",
    "string_literal",
    "struct_init",
    "struct_init_dot",
    "sub",
    "sub_sat",
    "sub_wrap",
    "suspend",
    "switch",
    "switch_case",
    "switch_range",
    "tagged_union",
    "test_decl",
    "try",
    "unreachable_literal",
    "unwrap_optional",
    "var_decl",
    "while",
];

impl Kind for ZigKind {
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

impl ZigKind {
    #[expect(
        clippy::too_many_lines,
        reason = "the projection names every kind, so its length is the grammar's and a shorter \
                  form would be a table the compiler cannot check"
    )]
    pub const fn category(self) -> Category {
        match self {
            Self::Assign
            | Self::AssignAdd
            | Self::AssignAddSat
            | Self::AssignAddWrap
            | Self::AssignBitAnd
            | Self::AssignBitOr
            | Self::AssignBitXor
            | Self::AssignDestructure
            | Self::AssignDiv
            | Self::AssignMod
            | Self::AssignMul
            | Self::AssignMulSat
            | Self::AssignMulWrap
            | Self::AssignShl
            | Self::AssignShlSat
            | Self::AssignShr
            | Self::AssignSub
            | Self::AssignSubSat
            | Self::AssignSubWrap => Category::Assignment,
            Self::Block | Self::Comptime | Self::Nosuspend | Self::Suspend => Category::Block,
            Self::If | Self::SwitchCase => Category::Branch,
            Self::BuiltinCall | Self::Call => Category::Call,
            Self::ContainerField | Self::VarDecl => Category::Declaration,
            Self::Catch | Self::Errdefer => Category::Except,
            Self::Add
            | Self::AddSat
            | Self::AddWrap
            | Self::AddressOf
            | Self::ArrayAccess
            | Self::ArrayCat
            | Self::ArrayInit
            | Self::ArrayInitDot
            | Self::ArrayMult
            | Self::Asm
            | Self::AsmInput
            | Self::AsmOutput
            | Self::BangEqualNode
            | Self::BitAnd
            | Self::BitNot
            | Self::BitOr
            | Self::BitXor
            | Self::BoolAnd
            | Self::BoolNot
            | Self::BoolOr
            | Self::Defer
            | Self::Deref
            | Self::Div
            | Self::EqualEqualNode
            | Self::ErrorValue
            | Self::FieldAccess
            | Self::ForRange
            | Self::GreaterOrEqual
            | Self::GreaterThan
            | Self::GroupedExpression
            | Self::LessOrEqual
            | Self::LessThan
            | Self::MergeErrorSets
            | Self::Mod
            | Self::Mul
            | Self::MulSat
            | Self::MulWrap
            | Self::Negation
            | Self::NegationWrap
            | Self::Orelse
            | Self::Resume
            | Self::Shl
            | Self::ShlSat
            | Self::Shr
            | Self::Slice
            | Self::StructInit
            | Self::StructInitDot
            | Self::Sub
            | Self::SubSat
            | Self::SubWrap
            | Self::SwitchRange
            | Self::UnwrapOptional => Category::Expression,
            Self::Root => Category::File,
            Self::FnDecl | Self::TestDecl => Category::Function,
            Self::FnProto => Category::Parameters,
            Self::For | Self::While => Category::Loop,
            Self::Switch => Category::Match,
            Self::Identifier | Self::IdentifierNode => Category::Name,
            Self::Return => Category::Return,
            Self::ContainerDecl | Self::ErrorSetDecl | Self::TaggedUnion => Category::Struct,
            Self::Try => Category::Try,
            Self::AnyframeType
            | Self::ArrayType
            | Self::ErrorUnion
            | Self::OptionalType
            | Self::PtrType => Category::Type,
            Self::AnyframeLiteral
            | Self::CharLiteral
            | Self::Character
            | Self::EnumLiteral
            | Self::MultilineStringLiteral
            | Self::Number
            | Self::NumberLiteral
            | Self::StringLiteral
            | Self::Text
            | Self::TextLine
            | Self::UnreachableLiteral => Category::Value,
            Self::AddrspaceKeyword
            | Self::AlignKeyword
            | Self::AllowzeroKeyword
            | Self::Ampersand
            | Self::AmpersandEqual
            | Self::AndKeyword
            | Self::AnyframeKeyword
            | Self::AnytypeKeyword
            | Self::Arrow
            | Self::AsmKeyword
            | Self::Bang
            | Self::BangEqual
            | Self::BraceClose
            | Self::BraceOpen
            | Self::BracketClose
            | Self::BracketOpen
            | Self::Break
            | Self::BreakKeyword
            | Self::Builtin
            | Self::CallconvKeyword
            | Self::Caret
            | Self::CaretEqual
            | Self::CatchKeyword
            | Self::Colon
            | Self::Comma
            | Self::Comment
            | Self::ComptimeKeyword
            | Self::ConstKeyword
            | Self::Continue
            | Self::ContinueKeyword
            | Self::DeferKeyword
            | Self::DocComment
            | Self::Dot
            | Self::DotAsterisk
            | Self::DotDot
            | Self::DotDotDot
            | Self::DotQuestion
            | Self::ElseKeyword
            | Self::EnumKeyword
            | Self::Equal
            | Self::EqualEqual
            | Self::ErrdeferKeyword
            | Self::ErrorKeyword
            | Self::ErrorNode
            | Self::ErrorToken
            | Self::ExportKeyword
            | Self::ExternKeyword
            | Self::FnKeyword
            | Self::ForKeyword
            | Self::Greater
            | Self::GreaterEqual
            | Self::GreaterGreater
            | Self::GreaterGreaterEqual
            | Self::IfKeyword
            | Self::InlineKeyword
            | Self::Less
            | Self::LessEqual
            | Self::LessLess
            | Self::LessLessEqual
            | Self::LessLessPipe
            | Self::LessLessPipeEqual
            | Self::LinksectionKeyword
            | Self::Minus
            | Self::MinusEqual
            | Self::MinusPercent
            | Self::MinusPercentEqual
            | Self::MinusPipe
            | Self::MinusPipeEqual
            | Self::NoaliasKeyword
            | Self::NoinlineKeyword
            | Self::NosuspendKeyword
            | Self::OpaqueKeyword
            | Self::OrKeyword
            | Self::OrelseKeyword
            | Self::PackedKeyword
            | Self::ParenClose
            | Self::ParenOpen
            | Self::Percent
            | Self::PercentEqual
            | Self::Pipe
            | Self::PipeEqual
            | Self::PipePipe
            | Self::Plus
            | Self::PlusEqual
            | Self::PlusPercent
            | Self::PlusPercentEqual
            | Self::PlusPipe
            | Self::PlusPipeEqual
            | Self::PlusPlus
            | Self::PubKeyword
            | Self::Question
            | Self::ResumeKeyword
            | Self::ReturnKeyword
            | Self::Semicolon
            | Self::Slash
            | Self::SlashEqual
            | Self::Star
            | Self::StarEqual
            | Self::StarPercent
            | Self::StarPercentEqual
            | Self::StarPipe
            | Self::StarPipeEqual
            | Self::StarStar
            | Self::StructKeyword
            | Self::SuspendKeyword
            | Self::SwitchKeyword
            | Self::TestKeyword
            | Self::ThreadlocalKeyword
            | Self::Tilde
            | Self::TryKeyword
            | Self::UnionKeyword
            | Self::UnreachableKeyword
            | Self::VarKeyword
            | Self::VolatileKeyword
            | Self::WhileKeyword => Category::Other,
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
            assert_eq!(ZigKind::of_u16(kind.to_u16()), Some(*kind));
            assert_eq!(ZigKind::of_name(kind.name()), Some(*kind));
        }

        assert_eq!(KINDS.len(), KIND_COUNT as usize);
        assert_eq!(NAMES.len(), KIND_COUNT as usize);
        assert!(ZigKind::of_u16(KIND_COUNT).is_none());
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
