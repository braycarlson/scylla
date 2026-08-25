use crate::syntax::{Category, SyntaxError};
use crate::tree::Kind;

pub const KIND_COUNT: u16 = 248;
pub const NODE_FIRST: u16 = 102;

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
#[repr(u16)]
pub enum RustKind {
    Ampersand = 0,
    AmpersandEqual = 1,
    Apostrophe = 2,
    AsKeyword = 3,
    AsyncKeyword = 4,
    At = 5,
    AwaitKeyword = 6,
    Bang = 7,
    BangEqual = 8,
    BraceClose = 9,
    BraceOpen = 10,
    BracketClose = 11,
    BracketOpen = 12,
    BreakKeyword = 13,
    ByteLiteral = 14,
    ByteStringLiteral = 15,
    CStringLiteral = 16,
    Caret = 17,
    CaretEqual = 18,
    CharLiteral = 19,
    Colon = 20,
    ColonColon = 21,
    Comma = 22,
    Comment = 23,
    ConstKeyword = 24,
    ContinueKeyword = 25,
    CrateKeyword = 26,
    DocComment = 27,
    Dollar = 28,
    Dot = 29,
    DotDot = 30,
    DotDotDot = 31,
    DotDotEqual = 32,
    DynKeyword = 33,
    ElseKeyword = 34,
    EnumKeyword = 35,
    Equal = 36,
    EqualEqual = 37,
    ErrorToken = 38,
    ExternKeyword = 39,
    FalseKeyword = 40,
    FatArrow = 41,
    FnKeyword = 42,
    ForKeyword = 43,
    Greater = 44,
    GreaterEqual = 45,
    GreaterGreaterEqual = 46,
    Identifier = 47,
    IfKeyword = 48,
    ImplKeyword = 49,
    InKeyword = 50,
    Less = 51,
    LessEqual = 52,
    LessLessEqual = 53,
    LetKeyword = 54,
    LoopKeyword = 55,
    MacroKeyword = 56,
    MatchKeyword = 57,
    Minus = 58,
    MinusEqual = 59,
    ModKeyword = 60,
    MoveKeyword = 61,
    MutKeyword = 62,
    Number = 63,
    Or = 64,
    OrEqual = 65,
    OrOr = 66,
    ParenClose = 67,
    ParenOpen = 68,
    Percent = 69,
    PercentEqual = 70,
    Plus = 71,
    PlusEqual = 72,
    Pound = 73,
    PubKeyword = 74,
    Question = 75,
    RArrow = 76,
    RefKeyword = 77,
    ReturnKeyword = 78,
    SelfLower = 79,
    SelfUpper = 80,
    Semicolon = 81,
    Slash = 82,
    SlashEqual = 83,
    Star = 84,
    StarEqual = 85,
    StaticKeyword = 86,
    StringLiteral = 87,
    StructKeyword = 88,
    SuperKeyword = 89,
    Tilde = 90,
    TraitKeyword = 91,
    TrueKeyword = 92,
    TryKeyword = 93,
    TypeKeyword = 94,
    Underscore = 95,
    UnionKeyword = 96,
    UnsafeKeyword = 97,
    UseKeyword = 98,
    WhereKeyword = 99,
    WhileKeyword = 100,
    YieldKeyword = 101,
    Abi = 102,
    Arm = 103,
    AssocConst = 104,
    AssocType = 105,
    Attribute = 106,
    BareFnArg = 107,
    BareVariadic = 108,
    Block = 109,
    BoundLifetimes = 110,
    ConstParam = 111,
    Constraint = 112,
    ErrorNode = 113,
    ExprArray = 114,
    ExprAssign = 115,
    ExprAsync = 116,
    ExprAwait = 117,
    ExprBinary = 118,
    ExprBlock = 119,
    ExprBreak = 120,
    ExprCall = 121,
    ExprCast = 122,
    ExprClosure = 123,
    ExprConst = 124,
    ExprContinue = 125,
    ExprField = 126,
    ExprForLoop = 127,
    ExprGroup = 128,
    ExprIf = 129,
    ExprIndex = 130,
    ExprInfer = 131,
    ExprLet = 132,
    ExprLit = 133,
    ExprLoop = 134,
    ExprMacro = 135,
    ExprMatch = 136,
    ExprMethodCall = 137,
    ExprParen = 138,
    ExprPath = 139,
    ExprRange = 140,
    ExprRawAddr = 141,
    ExprReference = 142,
    ExprRepeat = 143,
    ExprReturn = 144,
    ExprStruct = 145,
    ExprTry = 146,
    ExprTryBlock = 147,
    ExprTuple = 148,
    ExprUnary = 149,
    ExprUnsafe = 150,
    ExprWhile = 151,
    ExprYield = 152,
    Field = 153,
    FieldPat = 154,
    FieldValue = 155,
    FieldsNamed = 156,
    FieldsUnnamed = 157,
    File = 158,
    ForeignItemFn = 159,
    ForeignItemMacro = 160,
    ForeignItemStatic = 161,
    ForeignItemType = 162,
    Generics = 163,
    Ident = 164,
    ImplItemConst = 165,
    ImplItemFn = 166,
    ImplItemMacro = 167,
    ImplItemType = 168,
    Index = 169,
    ItemConst = 170,
    ItemEnum = 171,
    ItemExternCrate = 172,
    ItemFn = 173,
    ItemForeignMod = 174,
    ItemImpl = 175,
    ItemMacro = 176,
    ItemMod = 177,
    ItemStatic = 178,
    ItemStruct = 179,
    ItemTrait = 180,
    ItemTraitAlias = 181,
    ItemType = 182,
    ItemUnion = 183,
    ItemUse = 184,
    Label = 185,
    Lifetime = 186,
    LifetimeParam = 187,
    LitBool = 188,
    LitByte = 189,
    LitByteStr = 190,
    LitCStr = 191,
    LitChar = 192,
    LitFloat = 193,
    LitInt = 194,
    LitStr = 195,
    Local = 196,
    Macro = 197,
    MetaList = 198,
    MetaNameValue = 199,
    PatIdent = 200,
    PatOr = 201,
    PatParen = 202,
    PatReference = 203,
    PatRest = 204,
    PatSlice = 205,
    PatStruct = 206,
    PatTuple = 207,
    PatTupleStruct = 208,
    PatType = 209,
    PatWild = 210,
    Path = 211,
    PathSegment = 212,
    PreciseCapture = 213,
    PredicateLifetime = 214,
    PredicateType = 215,
    Receiver = 216,
    Signature = 217,
    StmtMacro = 218,
    TraitBound = 219,
    TraitItemConst = 220,
    TraitItemFn = 221,
    TraitItemMacro = 222,
    TraitItemType = 223,
    TypeArray = 224,
    TypeBareFn = 225,
    TypeGroup = 226,
    TypeImplTrait = 227,
    TypeInfer = 228,
    TypeMacro = 229,
    TypeNever = 230,
    TypeParam = 231,
    TypeParen = 232,
    TypePath = 233,
    TypePtr = 234,
    TypeReference = 235,
    TypeSlice = 236,
    TypeTraitObject = 237,
    TypeTuple = 238,
    UseGlob = 239,
    UseGroup = 240,
    UseName = 241,
    UsePath = 242,
    UseRename = 243,
    Variadic = 244,
    Variant = 245,
    VisRestricted = 246,
    WhereClause = 247,
}

static KINDS: [RustKind; KIND_COUNT as usize] = [
    RustKind::Ampersand,
    RustKind::AmpersandEqual,
    RustKind::Apostrophe,
    RustKind::AsKeyword,
    RustKind::AsyncKeyword,
    RustKind::At,
    RustKind::AwaitKeyword,
    RustKind::Bang,
    RustKind::BangEqual,
    RustKind::BraceClose,
    RustKind::BraceOpen,
    RustKind::BracketClose,
    RustKind::BracketOpen,
    RustKind::BreakKeyword,
    RustKind::ByteLiteral,
    RustKind::ByteStringLiteral,
    RustKind::CStringLiteral,
    RustKind::Caret,
    RustKind::CaretEqual,
    RustKind::CharLiteral,
    RustKind::Colon,
    RustKind::ColonColon,
    RustKind::Comma,
    RustKind::Comment,
    RustKind::ConstKeyword,
    RustKind::ContinueKeyword,
    RustKind::CrateKeyword,
    RustKind::DocComment,
    RustKind::Dollar,
    RustKind::Dot,
    RustKind::DotDot,
    RustKind::DotDotDot,
    RustKind::DotDotEqual,
    RustKind::DynKeyword,
    RustKind::ElseKeyword,
    RustKind::EnumKeyword,
    RustKind::Equal,
    RustKind::EqualEqual,
    RustKind::ErrorToken,
    RustKind::ExternKeyword,
    RustKind::FalseKeyword,
    RustKind::FatArrow,
    RustKind::FnKeyword,
    RustKind::ForKeyword,
    RustKind::Greater,
    RustKind::GreaterEqual,
    RustKind::GreaterGreaterEqual,
    RustKind::Identifier,
    RustKind::IfKeyword,
    RustKind::ImplKeyword,
    RustKind::InKeyword,
    RustKind::Less,
    RustKind::LessEqual,
    RustKind::LessLessEqual,
    RustKind::LetKeyword,
    RustKind::LoopKeyword,
    RustKind::MacroKeyword,
    RustKind::MatchKeyword,
    RustKind::Minus,
    RustKind::MinusEqual,
    RustKind::ModKeyword,
    RustKind::MoveKeyword,
    RustKind::MutKeyword,
    RustKind::Number,
    RustKind::Or,
    RustKind::OrEqual,
    RustKind::OrOr,
    RustKind::ParenClose,
    RustKind::ParenOpen,
    RustKind::Percent,
    RustKind::PercentEqual,
    RustKind::Plus,
    RustKind::PlusEqual,
    RustKind::Pound,
    RustKind::PubKeyword,
    RustKind::Question,
    RustKind::RArrow,
    RustKind::RefKeyword,
    RustKind::ReturnKeyword,
    RustKind::SelfLower,
    RustKind::SelfUpper,
    RustKind::Semicolon,
    RustKind::Slash,
    RustKind::SlashEqual,
    RustKind::Star,
    RustKind::StarEqual,
    RustKind::StaticKeyword,
    RustKind::StringLiteral,
    RustKind::StructKeyword,
    RustKind::SuperKeyword,
    RustKind::Tilde,
    RustKind::TraitKeyword,
    RustKind::TrueKeyword,
    RustKind::TryKeyword,
    RustKind::TypeKeyword,
    RustKind::Underscore,
    RustKind::UnionKeyword,
    RustKind::UnsafeKeyword,
    RustKind::UseKeyword,
    RustKind::WhereKeyword,
    RustKind::WhileKeyword,
    RustKind::YieldKeyword,
    RustKind::Abi,
    RustKind::Arm,
    RustKind::AssocConst,
    RustKind::AssocType,
    RustKind::Attribute,
    RustKind::BareFnArg,
    RustKind::BareVariadic,
    RustKind::Block,
    RustKind::BoundLifetimes,
    RustKind::ConstParam,
    RustKind::Constraint,
    RustKind::ErrorNode,
    RustKind::ExprArray,
    RustKind::ExprAssign,
    RustKind::ExprAsync,
    RustKind::ExprAwait,
    RustKind::ExprBinary,
    RustKind::ExprBlock,
    RustKind::ExprBreak,
    RustKind::ExprCall,
    RustKind::ExprCast,
    RustKind::ExprClosure,
    RustKind::ExprConst,
    RustKind::ExprContinue,
    RustKind::ExprField,
    RustKind::ExprForLoop,
    RustKind::ExprGroup,
    RustKind::ExprIf,
    RustKind::ExprIndex,
    RustKind::ExprInfer,
    RustKind::ExprLet,
    RustKind::ExprLit,
    RustKind::ExprLoop,
    RustKind::ExprMacro,
    RustKind::ExprMatch,
    RustKind::ExprMethodCall,
    RustKind::ExprParen,
    RustKind::ExprPath,
    RustKind::ExprRange,
    RustKind::ExprRawAddr,
    RustKind::ExprReference,
    RustKind::ExprRepeat,
    RustKind::ExprReturn,
    RustKind::ExprStruct,
    RustKind::ExprTry,
    RustKind::ExprTryBlock,
    RustKind::ExprTuple,
    RustKind::ExprUnary,
    RustKind::ExprUnsafe,
    RustKind::ExprWhile,
    RustKind::ExprYield,
    RustKind::Field,
    RustKind::FieldPat,
    RustKind::FieldValue,
    RustKind::FieldsNamed,
    RustKind::FieldsUnnamed,
    RustKind::File,
    RustKind::ForeignItemFn,
    RustKind::ForeignItemMacro,
    RustKind::ForeignItemStatic,
    RustKind::ForeignItemType,
    RustKind::Generics,
    RustKind::Ident,
    RustKind::ImplItemConst,
    RustKind::ImplItemFn,
    RustKind::ImplItemMacro,
    RustKind::ImplItemType,
    RustKind::Index,
    RustKind::ItemConst,
    RustKind::ItemEnum,
    RustKind::ItemExternCrate,
    RustKind::ItemFn,
    RustKind::ItemForeignMod,
    RustKind::ItemImpl,
    RustKind::ItemMacro,
    RustKind::ItemMod,
    RustKind::ItemStatic,
    RustKind::ItemStruct,
    RustKind::ItemTrait,
    RustKind::ItemTraitAlias,
    RustKind::ItemType,
    RustKind::ItemUnion,
    RustKind::ItemUse,
    RustKind::Label,
    RustKind::Lifetime,
    RustKind::LifetimeParam,
    RustKind::LitBool,
    RustKind::LitByte,
    RustKind::LitByteStr,
    RustKind::LitCStr,
    RustKind::LitChar,
    RustKind::LitFloat,
    RustKind::LitInt,
    RustKind::LitStr,
    RustKind::Local,
    RustKind::Macro,
    RustKind::MetaList,
    RustKind::MetaNameValue,
    RustKind::PatIdent,
    RustKind::PatOr,
    RustKind::PatParen,
    RustKind::PatReference,
    RustKind::PatRest,
    RustKind::PatSlice,
    RustKind::PatStruct,
    RustKind::PatTuple,
    RustKind::PatTupleStruct,
    RustKind::PatType,
    RustKind::PatWild,
    RustKind::Path,
    RustKind::PathSegment,
    RustKind::PreciseCapture,
    RustKind::PredicateLifetime,
    RustKind::PredicateType,
    RustKind::Receiver,
    RustKind::Signature,
    RustKind::StmtMacro,
    RustKind::TraitBound,
    RustKind::TraitItemConst,
    RustKind::TraitItemFn,
    RustKind::TraitItemMacro,
    RustKind::TraitItemType,
    RustKind::TypeArray,
    RustKind::TypeBareFn,
    RustKind::TypeGroup,
    RustKind::TypeImplTrait,
    RustKind::TypeInfer,
    RustKind::TypeMacro,
    RustKind::TypeNever,
    RustKind::TypeParam,
    RustKind::TypeParen,
    RustKind::TypePath,
    RustKind::TypePtr,
    RustKind::TypeReference,
    RustKind::TypeSlice,
    RustKind::TypeTraitObject,
    RustKind::TypeTuple,
    RustKind::UseGlob,
    RustKind::UseGroup,
    RustKind::UseName,
    RustKind::UsePath,
    RustKind::UseRename,
    RustKind::Variadic,
    RustKind::Variant,
    RustKind::VisRestricted,
    RustKind::WhereClause,
];

static NAMES: [&str; KIND_COUNT as usize] = [
    "Ampersand",
    "AmpersandEqual",
    "Apostrophe",
    "AsKeyword",
    "AsyncKeyword",
    "At",
    "AwaitKeyword",
    "Bang",
    "BangEqual",
    "BraceClose",
    "BraceOpen",
    "BracketClose",
    "BracketOpen",
    "BreakKeyword",
    "ByteLiteral",
    "ByteStringLiteral",
    "CStringLiteral",
    "Caret",
    "CaretEqual",
    "CharLiteral",
    "Colon",
    "ColonColon",
    "Comma",
    "Comment",
    "ConstKeyword",
    "ContinueKeyword",
    "CrateKeyword",
    "DocComment",
    "Dollar",
    "Dot",
    "DotDot",
    "DotDotDot",
    "DotDotEqual",
    "DynKeyword",
    "ElseKeyword",
    "EnumKeyword",
    "Equal",
    "EqualEqual",
    "ErrorToken",
    "ExternKeyword",
    "FalseKeyword",
    "FatArrow",
    "FnKeyword",
    "ForKeyword",
    "Greater",
    "GreaterEqual",
    "GreaterGreaterEqual",
    "Identifier",
    "IfKeyword",
    "ImplKeyword",
    "InKeyword",
    "Less",
    "LessEqual",
    "LessLessEqual",
    "LetKeyword",
    "LoopKeyword",
    "MacroKeyword",
    "MatchKeyword",
    "Minus",
    "MinusEqual",
    "ModKeyword",
    "MoveKeyword",
    "MutKeyword",
    "Number",
    "Or",
    "OrEqual",
    "OrOr",
    "ParenClose",
    "ParenOpen",
    "Percent",
    "PercentEqual",
    "Plus",
    "PlusEqual",
    "Pound",
    "PubKeyword",
    "Question",
    "RArrow",
    "RefKeyword",
    "ReturnKeyword",
    "SelfLower",
    "SelfUpper",
    "Semicolon",
    "Slash",
    "SlashEqual",
    "Star",
    "StarEqual",
    "StaticKeyword",
    "StringLiteral",
    "StructKeyword",
    "SuperKeyword",
    "Tilde",
    "TraitKeyword",
    "TrueKeyword",
    "TryKeyword",
    "TypeKeyword",
    "Underscore",
    "UnionKeyword",
    "UnsafeKeyword",
    "UseKeyword",
    "WhereKeyword",
    "WhileKeyword",
    "YieldKeyword",
    "Abi",
    "Arm",
    "AssocConst",
    "AssocType",
    "Attribute",
    "BareFnArg",
    "BareVariadic",
    "Block",
    "BoundLifetimes",
    "ConstParam",
    "Constraint",
    "ErrorNode",
    "ExprArray",
    "ExprAssign",
    "ExprAsync",
    "ExprAwait",
    "ExprBinary",
    "ExprBlock",
    "ExprBreak",
    "ExprCall",
    "ExprCast",
    "ExprClosure",
    "ExprConst",
    "ExprContinue",
    "ExprField",
    "ExprForLoop",
    "ExprGroup",
    "ExprIf",
    "ExprIndex",
    "ExprInfer",
    "ExprLet",
    "ExprLit",
    "ExprLoop",
    "ExprMacro",
    "ExprMatch",
    "ExprMethodCall",
    "ExprParen",
    "ExprPath",
    "ExprRange",
    "ExprRawAddr",
    "ExprReference",
    "ExprRepeat",
    "ExprReturn",
    "ExprStruct",
    "ExprTry",
    "ExprTryBlock",
    "ExprTuple",
    "ExprUnary",
    "ExprUnsafe",
    "ExprWhile",
    "ExprYield",
    "Field",
    "FieldPat",
    "FieldValue",
    "FieldsNamed",
    "FieldsUnnamed",
    "File",
    "ForeignItemFn",
    "ForeignItemMacro",
    "ForeignItemStatic",
    "ForeignItemType",
    "Generics",
    "Ident",
    "ImplItemConst",
    "ImplItemFn",
    "ImplItemMacro",
    "ImplItemType",
    "Index",
    "ItemConst",
    "ItemEnum",
    "ItemExternCrate",
    "ItemFn",
    "ItemForeignMod",
    "ItemImpl",
    "ItemMacro",
    "ItemMod",
    "ItemStatic",
    "ItemStruct",
    "ItemTrait",
    "ItemTraitAlias",
    "ItemType",
    "ItemUnion",
    "ItemUse",
    "Label",
    "Lifetime",
    "LifetimeParam",
    "LitBool",
    "LitByte",
    "LitByteStr",
    "LitCStr",
    "LitChar",
    "LitFloat",
    "LitInt",
    "LitStr",
    "Local",
    "Macro",
    "MetaList",
    "MetaNameValue",
    "PatIdent",
    "PatOr",
    "PatParen",
    "PatReference",
    "PatRest",
    "PatSlice",
    "PatStruct",
    "PatTuple",
    "PatTupleStruct",
    "PatType",
    "PatWild",
    "Path",
    "PathSegment",
    "PreciseCapture",
    "PredicateLifetime",
    "PredicateType",
    "Receiver",
    "Signature",
    "StmtMacro",
    "TraitBound",
    "TraitItemConst",
    "TraitItemFn",
    "TraitItemMacro",
    "TraitItemType",
    "TypeArray",
    "TypeBareFn",
    "TypeGroup",
    "TypeImplTrait",
    "TypeInfer",
    "TypeMacro",
    "TypeNever",
    "TypeParam",
    "TypeParen",
    "TypePath",
    "TypePtr",
    "TypeReference",
    "TypeSlice",
    "TypeTraitObject",
    "TypeTuple",
    "UseGlob",
    "UseGroup",
    "UseName",
    "UsePath",
    "UseRename",
    "Variadic",
    "Variant",
    "VisRestricted",
    "WhereClause",
];

impl Kind for RustKind {
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

impl RustKind {
    #[expect(
        clippy::too_many_lines,
        reason = "the projection names every kind, so its length is the grammar's and a shorter \
                  form would be a table the compiler cannot check"
    )]
    pub const fn category(self) -> Category {
        match self {
            Self::ExprAssign => Category::Assignment,
            Self::Attribute | Self::MetaList | Self::MetaNameValue => Category::Attribute,
            Self::Block
            | Self::ExprAsync
            | Self::ExprBlock
            | Self::ExprConst
            | Self::ExprUnsafe
            | Self::FieldsNamed
            | Self::FieldsUnnamed
            | Self::ItemForeignMod
            | Self::ItemMod => Category::Block,
            Self::Arm | Self::ExprIf => Category::Branch,
            Self::ExprCall
            | Self::ExprMacro
            | Self::ExprMethodCall
            | Self::ForeignItemMacro
            | Self::ImplItemMacro
            | Self::ItemMacro
            | Self::Macro
            | Self::StmtMacro
            | Self::TraitItemMacro => Category::Call,
            Self::ExprLet => Category::Condition,
            Self::AssocConst
            | Self::AssocType
            | Self::Field
            | Self::ForeignItemStatic
            | Self::ForeignItemType
            | Self::ImplItemConst
            | Self::ImplItemType
            | Self::ItemConst
            | Self::ItemStatic
            | Self::ItemType
            | Self::Local
            | Self::PatType
            | Self::TraitItemConst
            | Self::TraitItemType
            | Self::Variant => Category::Declaration,
            Self::ExprArray
            | Self::ExprAwait
            | Self::ExprBinary
            | Self::ExprBreak
            | Self::ExprCast
            | Self::ExprContinue
            | Self::ExprField
            | Self::ExprGroup
            | Self::ExprIndex
            | Self::ExprInfer
            | Self::ExprParen
            | Self::ExprRange
            | Self::ExprRawAddr
            | Self::ExprReference
            | Self::ExprRepeat
            | Self::ExprStruct
            | Self::ExprTuple
            | Self::ExprUnary
            | Self::ExprYield
            | Self::FieldPat
            | Self::FieldValue
            | Self::PatOr
            | Self::PatParen
            | Self::PatReference
            | Self::PatRest
            | Self::PatSlice
            | Self::PatStruct
            | Self::PatTuple
            | Self::PatTupleStruct
            | Self::PatWild
            | Self::PreciseCapture => Category::Expression,
            Self::File => Category::File,
            Self::ForeignItemFn | Self::ImplItemFn | Self::ItemFn | Self::TraitItemFn => {
                Category::Function
            }
            Self::ItemExternCrate
            | Self::ItemUse
            | Self::UseGlob
            | Self::UseGroup
            | Self::UseName
            | Self::UsePath
            | Self::UseRename => Category::Import,
            Self::ExprClosure => Category::Lambda,
            Self::ExprForLoop | Self::ExprLoop | Self::ExprWhile => Category::Loop,
            Self::ExprMatch => Category::Match,
            Self::ExprPath
            | Self::Ident
            | Self::Identifier
            | Self::Label
            | Self::Lifetime
            | Self::PatIdent
            | Self::Path
            | Self::PathSegment
            | Self::SelfLower
            | Self::SelfUpper => Category::Name,
            Self::BareFnArg
            | Self::BareVariadic
            | Self::ConstParam
            | Self::LifetimeParam
            | Self::Receiver
            | Self::TypeParam
            | Self::Variadic => Category::Parameter,
            Self::Generics | Self::Signature => Category::Parameters,
            Self::ExprReturn => Category::Return,
            Self::ItemEnum
            | Self::ItemImpl
            | Self::ItemStruct
            | Self::ItemTrait
            | Self::ItemTraitAlias
            | Self::ItemUnion => Category::Struct,
            Self::ExprTry | Self::ExprTryBlock => Category::Try,
            Self::BoundLifetimes
            | Self::Constraint
            | Self::PredicateLifetime
            | Self::PredicateType
            | Self::TraitBound
            | Self::TypeArray
            | Self::TypeBareFn
            | Self::TypeGroup
            | Self::TypeImplTrait
            | Self::TypeInfer
            | Self::TypeMacro
            | Self::TypeNever
            | Self::TypeParen
            | Self::TypePath
            | Self::TypePtr
            | Self::TypeReference
            | Self::TypeSlice
            | Self::TypeTraitObject
            | Self::TypeTuple
            | Self::WhereClause => Category::Type,
            Self::ByteLiteral
            | Self::ByteStringLiteral
            | Self::CStringLiteral
            | Self::CharLiteral
            | Self::ExprLit
            | Self::FalseKeyword
            | Self::Index
            | Self::LitBool
            | Self::LitByte
            | Self::LitByteStr
            | Self::LitCStr
            | Self::LitChar
            | Self::LitFloat
            | Self::LitInt
            | Self::LitStr
            | Self::Number
            | Self::StringLiteral
            | Self::TrueKeyword => Category::Value,
            Self::Abi
            | Self::Ampersand
            | Self::AmpersandEqual
            | Self::Apostrophe
            | Self::AsKeyword
            | Self::AsyncKeyword
            | Self::At
            | Self::AwaitKeyword
            | Self::Bang
            | Self::BangEqual
            | Self::BraceClose
            | Self::BraceOpen
            | Self::BracketClose
            | Self::BracketOpen
            | Self::BreakKeyword
            | Self::Caret
            | Self::CaretEqual
            | Self::Colon
            | Self::ColonColon
            | Self::Comma
            | Self::Comment
            | Self::ConstKeyword
            | Self::ContinueKeyword
            | Self::CrateKeyword
            | Self::DocComment
            | Self::Dollar
            | Self::Dot
            | Self::DotDot
            | Self::DotDotDot
            | Self::DotDotEqual
            | Self::DynKeyword
            | Self::ElseKeyword
            | Self::EnumKeyword
            | Self::Equal
            | Self::EqualEqual
            | Self::ErrorNode
            | Self::ErrorToken
            | Self::ExternKeyword
            | Self::FatArrow
            | Self::FnKeyword
            | Self::ForKeyword
            | Self::Greater
            | Self::GreaterEqual
            | Self::GreaterGreaterEqual
            | Self::IfKeyword
            | Self::ImplKeyword
            | Self::InKeyword
            | Self::Less
            | Self::LessEqual
            | Self::LessLessEqual
            | Self::LetKeyword
            | Self::LoopKeyword
            | Self::MacroKeyword
            | Self::MatchKeyword
            | Self::Minus
            | Self::MinusEqual
            | Self::ModKeyword
            | Self::MoveKeyword
            | Self::MutKeyword
            | Self::Or
            | Self::OrEqual
            | Self::OrOr
            | Self::ParenClose
            | Self::ParenOpen
            | Self::Percent
            | Self::PercentEqual
            | Self::Plus
            | Self::PlusEqual
            | Self::Pound
            | Self::PubKeyword
            | Self::Question
            | Self::RArrow
            | Self::RefKeyword
            | Self::ReturnKeyword
            | Self::Semicolon
            | Self::Slash
            | Self::SlashEqual
            | Self::Star
            | Self::StarEqual
            | Self::StaticKeyword
            | Self::StructKeyword
            | Self::SuperKeyword
            | Self::Tilde
            | Self::TraitKeyword
            | Self::TryKeyword
            | Self::TypeKeyword
            | Self::Underscore
            | Self::UnionKeyword
            | Self::UnsafeKeyword
            | Self::UseKeyword
            | Self::VisRestricted
            | Self::WhereKeyword
            | Self::WhileKeyword
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
            assert_eq!(RustKind::of_u16(kind.to_u16()), Some(*kind));
            assert_eq!(RustKind::of_name(kind.name()), Some(*kind));
        }

        assert_eq!(KINDS.len(), KIND_COUNT as usize);
        assert_eq!(NAMES.len(), KIND_COUNT as usize);
        assert!(RustKind::of_u16(KIND_COUNT).is_none());
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
