use crate::syntax::{Category, SyntaxError};
use crate::tree::Kind;

pub const KIND_COUNT: u16 = 293;
pub const NODE_FIRST: u16 = 115;

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
#[repr(u16)]
pub enum TypeScriptKind {
    Ampersand = 0,
    AmpersandAmpersand = 1,
    AmpersandAmpersandEqual = 2,
    AmpersandEqual = 3,
    Arrow = 4,
    AsyncKeyword = 5,
    At = 6,
    AwaitKeyword = 7,
    Bang = 8,
    BangEqual = 9,
    BangEqualEqual = 10,
    Bar = 11,
    BarBar = 12,
    BarBarEqual = 13,
    BarEqual = 14,
    BraceClose = 15,
    BraceOpen = 16,
    BracketClose = 17,
    BracketOpen = 18,
    BreakKeyword = 19,
    Caret = 20,
    CaretEqual = 21,
    CaseKeyword = 22,
    CatchKeyword = 23,
    ClassKeyword = 24,
    Colon = 25,
    Comma = 26,
    Comment = 27,
    ConstKeyword = 28,
    ContinueKeyword = 29,
    DebuggerKeyword = 30,
    DefaultKeyword = 31,
    DeleteKeyword = 32,
    DoKeyword = 33,
    Dot = 34,
    DotDotDot = 35,
    ElseKeyword = 36,
    Equal = 37,
    EqualEqual = 38,
    EqualEqualEqual = 39,
    ErrorToken = 40,
    ExportKeyword = 41,
    ExtendsKeyword = 42,
    FalseKeyword = 43,
    FinallyKeyword = 44,
    ForKeyword = 45,
    FunctionKeyword = 46,
    Greater = 47,
    GreaterEqual = 48,
    GreaterGreaterEqual = 49,
    GreaterGreaterGreaterEqual = 50,
    Identifier = 51,
    IfKeyword = 52,
    ImportKeyword = 53,
    InKeyword = 54,
    InstanceofKeyword = 55,
    JsxChars = 56,
    JsxEntity = 57,
    JsxTagEnd = 58,
    JsxTagEndSelf = 59,
    JsxTagStart = 60,
    JsxTagStartClose = 61,
    Less = 62,
    LessEqual = 63,
    LessLess = 64,
    LessLessEqual = 65,
    LetKeyword = 66,
    Minus = 67,
    MinusEqual = 68,
    MinusMinus = 69,
    NewKeyword = 70,
    NullKeyword = 71,
    Number = 72,
    OfKeyword = 73,
    ParenClose = 74,
    ParenOpen = 75,
    Percent = 76,
    PercentEqual = 77,
    Plus = 78,
    PlusEqual = 79,
    PlusPlus = 80,
    PrivateIdentifier = 81,
    Question = 82,
    QuestionDot = 83,
    QuestionQuestion = 84,
    QuestionQuestionEqual = 85,
    Regex = 86,
    ReturnKeyword = 87,
    Semicolon = 88,
    Slash = 89,
    SlashEqual = 90,
    Star = 91,
    StarEqual = 92,
    StarStar = 93,
    StarStarEqual = 94,
    StaticKeyword = 95,
    String = 96,
    SubstitutionStart = 97,
    SuperKeyword = 98,
    SwitchKeyword = 99,
    TemplateChars = 100,
    TemplateEnd = 101,
    TemplateStart = 102,
    ThisKeyword = 103,
    ThrowKeyword = 104,
    Tilde = 105,
    TrueKeyword = 106,
    TryKeyword = 107,
    TypeofKeyword = 108,
    UndefinedKeyword = 109,
    VarKeyword = 110,
    VoidKeyword = 111,
    WhileKeyword = 112,
    WithKeyword = 113,
    YieldKeyword = 114,
    AbstractClassDeclaration = 115,
    AbstractMethodSignature = 116,
    AccessibilityModifier = 117,
    AddingTypeAnnotation = 118,
    AmbientDeclaration = 119,
    Arguments = 120,
    Array = 121,
    ArrayPattern = 122,
    ArrayType = 123,
    ArrowFunction = 124,
    AsExpression = 125,
    Asserts = 126,
    AssertsAnnotation = 127,
    AssignmentExpression = 128,
    AssignmentPattern = 129,
    AugmentedAssignmentExpression = 130,
    AwaitExpression = 131,
    BinaryExpression = 132,
    BreakStatement = 133,
    CallExpression = 134,
    CallSignature = 135,
    CatchClause = 136,
    Class = 137,
    ClassBody = 138,
    ClassDeclaration = 139,
    ClassHeritage = 140,
    ClassStaticBlock = 141,
    ComputedPropertyName = 142,
    ConditionalType = 143,
    Constraint = 144,
    ConstructSignature = 145,
    ConstructorType = 146,
    ContinueStatement = 147,
    DebuggerStatement = 148,
    Decorator = 149,
    DefaultType = 150,
    DoStatement = 151,
    ElseClause = 152,
    EmptyStatement = 153,
    EnumAssignment = 154,
    EnumBody = 155,
    EnumDeclaration = 156,
    ErrorNode = 157,
    ExistentialType = 158,
    ExportClause = 159,
    ExportSpecifier = 160,
    ExportStatement = 161,
    ExpressionStatement = 162,
    ExtendsClause = 163,
    ExtendsTypeClause = 164,
    False = 165,
    FinallyClause = 166,
    FlowMaybeType = 167,
    ForInStatement = 168,
    ForStatement = 169,
    FormalParameters = 170,
    FunctionDeclaration = 171,
    FunctionExpression = 172,
    FunctionSignature = 173,
    FunctionType = 174,
    GeneratorFunction = 175,
    GeneratorFunctionDeclaration = 176,
    GenericType = 177,
    IdentifierNode = 178,
    IfStatement = 179,
    ImplementsClause = 180,
    ImportNode = 181,
    ImportAlias = 182,
    ImportAttribute = 183,
    ImportClause = 184,
    ImportRequireClause = 185,
    ImportSpecifier = 186,
    ImportStatement = 187,
    IndexSignature = 188,
    IndexTypeQuery = 189,
    InferType = 190,
    InstantiationExpression = 191,
    InterfaceBody = 192,
    InterfaceDeclaration = 193,
    InternalModule = 194,
    IntersectionType = 195,
    JsxAttribute = 196,
    JsxClosingElement = 197,
    JsxElement = 198,
    JsxExpression = 199,
    JsxNamespaceName = 200,
    JsxOpeningElement = 201,
    JsxSelfClosingElement = 202,
    JsxText = 203,
    LabeledStatement = 204,
    LexicalDeclaration = 205,
    LiteralType = 206,
    LookupType = 207,
    MappedTypeClause = 208,
    MemberExpression = 209,
    MetaProperty = 210,
    MethodDefinition = 211,
    MethodSignature = 212,
    Module = 213,
    NamedImports = 214,
    NamespaceExport = 215,
    NamespaceImport = 216,
    NestedIdentifier = 217,
    NestedTypeIdentifier = 218,
    NewExpression = 219,
    NonNullExpression = 220,
    Null = 221,
    NumberNode = 222,
    Object = 223,
    ObjectAssignmentPattern = 224,
    ObjectPattern = 225,
    ObjectType = 226,
    OmittingTypeAnnotation = 227,
    OptingTypeAnnotation = 228,
    OptionalChain = 229,
    OptionalParameter = 230,
    OptionalType = 231,
    OverrideModifier = 232,
    Pair = 233,
    PairPattern = 234,
    ParenthesizedExpression = 235,
    ParenthesizedType = 236,
    PredefinedType = 237,
    PrivatePropertyIdentifier = 238,
    Program = 239,
    PropertyIdentifier = 240,
    PropertySignature = 241,
    PublicFieldDefinition = 242,
    ReadonlyType = 243,
    RegexNode = 244,
    RequiredParameter = 245,
    RestPattern = 246,
    RestType = 247,
    ReturnStatement = 248,
    SatisfiesExpression = 249,
    SequenceExpression = 250,
    ShorthandPropertyIdentifier = 251,
    ShorthandPropertyIdentifierPattern = 252,
    SpreadElement = 253,
    StatementBlock = 254,
    StatementIdentifier = 255,
    StringNode = 256,
    SubscriptExpression = 257,
    Super = 258,
    SwitchBody = 259,
    SwitchCase = 260,
    SwitchDefault = 261,
    SwitchStatement = 262,
    TemplateLiteralType = 263,
    TemplateString = 264,
    TemplateSubstitution = 265,
    TemplateType = 266,
    TernaryExpression = 267,
    This = 268,
    ThisType = 269,
    ThrowStatement = 270,
    True = 271,
    TryStatement = 272,
    TupleType = 273,
    TypeAliasDeclaration = 274,
    TypeAnnotation = 275,
    TypeArguments = 276,
    TypeAssertion = 277,
    TypeIdentifier = 278,
    TypeParameter = 279,
    TypeParameters = 280,
    TypePredicate = 281,
    TypePredicateAnnotation = 282,
    TypeQuery = 283,
    UnaryExpression = 284,
    Undefined = 285,
    UnionType = 286,
    UpdateExpression = 287,
    VariableDeclaration = 288,
    VariableDeclarator = 289,
    WhileStatement = 290,
    WithStatement = 291,
    YieldExpression = 292,
}

static KINDS: [TypeScriptKind; KIND_COUNT as usize] = [
    TypeScriptKind::Ampersand,
    TypeScriptKind::AmpersandAmpersand,
    TypeScriptKind::AmpersandAmpersandEqual,
    TypeScriptKind::AmpersandEqual,
    TypeScriptKind::Arrow,
    TypeScriptKind::AsyncKeyword,
    TypeScriptKind::At,
    TypeScriptKind::AwaitKeyword,
    TypeScriptKind::Bang,
    TypeScriptKind::BangEqual,
    TypeScriptKind::BangEqualEqual,
    TypeScriptKind::Bar,
    TypeScriptKind::BarBar,
    TypeScriptKind::BarBarEqual,
    TypeScriptKind::BarEqual,
    TypeScriptKind::BraceClose,
    TypeScriptKind::BraceOpen,
    TypeScriptKind::BracketClose,
    TypeScriptKind::BracketOpen,
    TypeScriptKind::BreakKeyword,
    TypeScriptKind::Caret,
    TypeScriptKind::CaretEqual,
    TypeScriptKind::CaseKeyword,
    TypeScriptKind::CatchKeyword,
    TypeScriptKind::ClassKeyword,
    TypeScriptKind::Colon,
    TypeScriptKind::Comma,
    TypeScriptKind::Comment,
    TypeScriptKind::ConstKeyword,
    TypeScriptKind::ContinueKeyword,
    TypeScriptKind::DebuggerKeyword,
    TypeScriptKind::DefaultKeyword,
    TypeScriptKind::DeleteKeyword,
    TypeScriptKind::DoKeyword,
    TypeScriptKind::Dot,
    TypeScriptKind::DotDotDot,
    TypeScriptKind::ElseKeyword,
    TypeScriptKind::Equal,
    TypeScriptKind::EqualEqual,
    TypeScriptKind::EqualEqualEqual,
    TypeScriptKind::ErrorToken,
    TypeScriptKind::ExportKeyword,
    TypeScriptKind::ExtendsKeyword,
    TypeScriptKind::FalseKeyword,
    TypeScriptKind::FinallyKeyword,
    TypeScriptKind::ForKeyword,
    TypeScriptKind::FunctionKeyword,
    TypeScriptKind::Greater,
    TypeScriptKind::GreaterEqual,
    TypeScriptKind::GreaterGreaterEqual,
    TypeScriptKind::GreaterGreaterGreaterEqual,
    TypeScriptKind::Identifier,
    TypeScriptKind::IfKeyword,
    TypeScriptKind::ImportKeyword,
    TypeScriptKind::InKeyword,
    TypeScriptKind::InstanceofKeyword,
    TypeScriptKind::JsxChars,
    TypeScriptKind::JsxEntity,
    TypeScriptKind::JsxTagEnd,
    TypeScriptKind::JsxTagEndSelf,
    TypeScriptKind::JsxTagStart,
    TypeScriptKind::JsxTagStartClose,
    TypeScriptKind::Less,
    TypeScriptKind::LessEqual,
    TypeScriptKind::LessLess,
    TypeScriptKind::LessLessEqual,
    TypeScriptKind::LetKeyword,
    TypeScriptKind::Minus,
    TypeScriptKind::MinusEqual,
    TypeScriptKind::MinusMinus,
    TypeScriptKind::NewKeyword,
    TypeScriptKind::NullKeyword,
    TypeScriptKind::Number,
    TypeScriptKind::OfKeyword,
    TypeScriptKind::ParenClose,
    TypeScriptKind::ParenOpen,
    TypeScriptKind::Percent,
    TypeScriptKind::PercentEqual,
    TypeScriptKind::Plus,
    TypeScriptKind::PlusEqual,
    TypeScriptKind::PlusPlus,
    TypeScriptKind::PrivateIdentifier,
    TypeScriptKind::Question,
    TypeScriptKind::QuestionDot,
    TypeScriptKind::QuestionQuestion,
    TypeScriptKind::QuestionQuestionEqual,
    TypeScriptKind::Regex,
    TypeScriptKind::ReturnKeyword,
    TypeScriptKind::Semicolon,
    TypeScriptKind::Slash,
    TypeScriptKind::SlashEqual,
    TypeScriptKind::Star,
    TypeScriptKind::StarEqual,
    TypeScriptKind::StarStar,
    TypeScriptKind::StarStarEqual,
    TypeScriptKind::StaticKeyword,
    TypeScriptKind::String,
    TypeScriptKind::SubstitutionStart,
    TypeScriptKind::SuperKeyword,
    TypeScriptKind::SwitchKeyword,
    TypeScriptKind::TemplateChars,
    TypeScriptKind::TemplateEnd,
    TypeScriptKind::TemplateStart,
    TypeScriptKind::ThisKeyword,
    TypeScriptKind::ThrowKeyword,
    TypeScriptKind::Tilde,
    TypeScriptKind::TrueKeyword,
    TypeScriptKind::TryKeyword,
    TypeScriptKind::TypeofKeyword,
    TypeScriptKind::UndefinedKeyword,
    TypeScriptKind::VarKeyword,
    TypeScriptKind::VoidKeyword,
    TypeScriptKind::WhileKeyword,
    TypeScriptKind::WithKeyword,
    TypeScriptKind::YieldKeyword,
    TypeScriptKind::AbstractClassDeclaration,
    TypeScriptKind::AbstractMethodSignature,
    TypeScriptKind::AccessibilityModifier,
    TypeScriptKind::AddingTypeAnnotation,
    TypeScriptKind::AmbientDeclaration,
    TypeScriptKind::Arguments,
    TypeScriptKind::Array,
    TypeScriptKind::ArrayPattern,
    TypeScriptKind::ArrayType,
    TypeScriptKind::ArrowFunction,
    TypeScriptKind::AsExpression,
    TypeScriptKind::Asserts,
    TypeScriptKind::AssertsAnnotation,
    TypeScriptKind::AssignmentExpression,
    TypeScriptKind::AssignmentPattern,
    TypeScriptKind::AugmentedAssignmentExpression,
    TypeScriptKind::AwaitExpression,
    TypeScriptKind::BinaryExpression,
    TypeScriptKind::BreakStatement,
    TypeScriptKind::CallExpression,
    TypeScriptKind::CallSignature,
    TypeScriptKind::CatchClause,
    TypeScriptKind::Class,
    TypeScriptKind::ClassBody,
    TypeScriptKind::ClassDeclaration,
    TypeScriptKind::ClassHeritage,
    TypeScriptKind::ClassStaticBlock,
    TypeScriptKind::ComputedPropertyName,
    TypeScriptKind::ConditionalType,
    TypeScriptKind::Constraint,
    TypeScriptKind::ConstructSignature,
    TypeScriptKind::ConstructorType,
    TypeScriptKind::ContinueStatement,
    TypeScriptKind::DebuggerStatement,
    TypeScriptKind::Decorator,
    TypeScriptKind::DefaultType,
    TypeScriptKind::DoStatement,
    TypeScriptKind::ElseClause,
    TypeScriptKind::EmptyStatement,
    TypeScriptKind::EnumAssignment,
    TypeScriptKind::EnumBody,
    TypeScriptKind::EnumDeclaration,
    TypeScriptKind::ErrorNode,
    TypeScriptKind::ExistentialType,
    TypeScriptKind::ExportClause,
    TypeScriptKind::ExportSpecifier,
    TypeScriptKind::ExportStatement,
    TypeScriptKind::ExpressionStatement,
    TypeScriptKind::ExtendsClause,
    TypeScriptKind::ExtendsTypeClause,
    TypeScriptKind::False,
    TypeScriptKind::FinallyClause,
    TypeScriptKind::FlowMaybeType,
    TypeScriptKind::ForInStatement,
    TypeScriptKind::ForStatement,
    TypeScriptKind::FormalParameters,
    TypeScriptKind::FunctionDeclaration,
    TypeScriptKind::FunctionExpression,
    TypeScriptKind::FunctionSignature,
    TypeScriptKind::FunctionType,
    TypeScriptKind::GeneratorFunction,
    TypeScriptKind::GeneratorFunctionDeclaration,
    TypeScriptKind::GenericType,
    TypeScriptKind::IdentifierNode,
    TypeScriptKind::IfStatement,
    TypeScriptKind::ImplementsClause,
    TypeScriptKind::ImportNode,
    TypeScriptKind::ImportAlias,
    TypeScriptKind::ImportAttribute,
    TypeScriptKind::ImportClause,
    TypeScriptKind::ImportRequireClause,
    TypeScriptKind::ImportSpecifier,
    TypeScriptKind::ImportStatement,
    TypeScriptKind::IndexSignature,
    TypeScriptKind::IndexTypeQuery,
    TypeScriptKind::InferType,
    TypeScriptKind::InstantiationExpression,
    TypeScriptKind::InterfaceBody,
    TypeScriptKind::InterfaceDeclaration,
    TypeScriptKind::InternalModule,
    TypeScriptKind::IntersectionType,
    TypeScriptKind::JsxAttribute,
    TypeScriptKind::JsxClosingElement,
    TypeScriptKind::JsxElement,
    TypeScriptKind::JsxExpression,
    TypeScriptKind::JsxNamespaceName,
    TypeScriptKind::JsxOpeningElement,
    TypeScriptKind::JsxSelfClosingElement,
    TypeScriptKind::JsxText,
    TypeScriptKind::LabeledStatement,
    TypeScriptKind::LexicalDeclaration,
    TypeScriptKind::LiteralType,
    TypeScriptKind::LookupType,
    TypeScriptKind::MappedTypeClause,
    TypeScriptKind::MemberExpression,
    TypeScriptKind::MetaProperty,
    TypeScriptKind::MethodDefinition,
    TypeScriptKind::MethodSignature,
    TypeScriptKind::Module,
    TypeScriptKind::NamedImports,
    TypeScriptKind::NamespaceExport,
    TypeScriptKind::NamespaceImport,
    TypeScriptKind::NestedIdentifier,
    TypeScriptKind::NestedTypeIdentifier,
    TypeScriptKind::NewExpression,
    TypeScriptKind::NonNullExpression,
    TypeScriptKind::Null,
    TypeScriptKind::NumberNode,
    TypeScriptKind::Object,
    TypeScriptKind::ObjectAssignmentPattern,
    TypeScriptKind::ObjectPattern,
    TypeScriptKind::ObjectType,
    TypeScriptKind::OmittingTypeAnnotation,
    TypeScriptKind::OptingTypeAnnotation,
    TypeScriptKind::OptionalChain,
    TypeScriptKind::OptionalParameter,
    TypeScriptKind::OptionalType,
    TypeScriptKind::OverrideModifier,
    TypeScriptKind::Pair,
    TypeScriptKind::PairPattern,
    TypeScriptKind::ParenthesizedExpression,
    TypeScriptKind::ParenthesizedType,
    TypeScriptKind::PredefinedType,
    TypeScriptKind::PrivatePropertyIdentifier,
    TypeScriptKind::Program,
    TypeScriptKind::PropertyIdentifier,
    TypeScriptKind::PropertySignature,
    TypeScriptKind::PublicFieldDefinition,
    TypeScriptKind::ReadonlyType,
    TypeScriptKind::RegexNode,
    TypeScriptKind::RequiredParameter,
    TypeScriptKind::RestPattern,
    TypeScriptKind::RestType,
    TypeScriptKind::ReturnStatement,
    TypeScriptKind::SatisfiesExpression,
    TypeScriptKind::SequenceExpression,
    TypeScriptKind::ShorthandPropertyIdentifier,
    TypeScriptKind::ShorthandPropertyIdentifierPattern,
    TypeScriptKind::SpreadElement,
    TypeScriptKind::StatementBlock,
    TypeScriptKind::StatementIdentifier,
    TypeScriptKind::StringNode,
    TypeScriptKind::SubscriptExpression,
    TypeScriptKind::Super,
    TypeScriptKind::SwitchBody,
    TypeScriptKind::SwitchCase,
    TypeScriptKind::SwitchDefault,
    TypeScriptKind::SwitchStatement,
    TypeScriptKind::TemplateLiteralType,
    TypeScriptKind::TemplateString,
    TypeScriptKind::TemplateSubstitution,
    TypeScriptKind::TemplateType,
    TypeScriptKind::TernaryExpression,
    TypeScriptKind::This,
    TypeScriptKind::ThisType,
    TypeScriptKind::ThrowStatement,
    TypeScriptKind::True,
    TypeScriptKind::TryStatement,
    TypeScriptKind::TupleType,
    TypeScriptKind::TypeAliasDeclaration,
    TypeScriptKind::TypeAnnotation,
    TypeScriptKind::TypeArguments,
    TypeScriptKind::TypeAssertion,
    TypeScriptKind::TypeIdentifier,
    TypeScriptKind::TypeParameter,
    TypeScriptKind::TypeParameters,
    TypeScriptKind::TypePredicate,
    TypeScriptKind::TypePredicateAnnotation,
    TypeScriptKind::TypeQuery,
    TypeScriptKind::UnaryExpression,
    TypeScriptKind::Undefined,
    TypeScriptKind::UnionType,
    TypeScriptKind::UpdateExpression,
    TypeScriptKind::VariableDeclaration,
    TypeScriptKind::VariableDeclarator,
    TypeScriptKind::WhileStatement,
    TypeScriptKind::WithStatement,
    TypeScriptKind::YieldExpression,
];

static NAMES: [&str; KIND_COUNT as usize] = [
    "Ampersand",
    "AmpersandAmpersand",
    "AmpersandAmpersandEqual",
    "AmpersandEqual",
    "Arrow",
    "AsyncKeyword",
    "At",
    "AwaitKeyword",
    "Bang",
    "BangEqual",
    "BangEqualEqual",
    "Bar",
    "BarBar",
    "BarBarEqual",
    "BarEqual",
    "BraceClose",
    "BraceOpen",
    "BracketClose",
    "BracketOpen",
    "BreakKeyword",
    "Caret",
    "CaretEqual",
    "CaseKeyword",
    "CatchKeyword",
    "ClassKeyword",
    "Colon",
    "Comma",
    "Comment",
    "ConstKeyword",
    "ContinueKeyword",
    "DebuggerKeyword",
    "DefaultKeyword",
    "DeleteKeyword",
    "DoKeyword",
    "Dot",
    "DotDotDot",
    "ElseKeyword",
    "Equal",
    "EqualEqual",
    "EqualEqualEqual",
    "ErrorToken",
    "ExportKeyword",
    "ExtendsKeyword",
    "FalseKeyword",
    "FinallyKeyword",
    "ForKeyword",
    "FunctionKeyword",
    "Greater",
    "GreaterEqual",
    "GreaterGreaterEqual",
    "GreaterGreaterGreaterEqual",
    "Identifier",
    "IfKeyword",
    "ImportKeyword",
    "InKeyword",
    "InstanceofKeyword",
    "JsxChars",
    "JsxEntity",
    "JsxTagEnd",
    "JsxTagEndSelf",
    "JsxTagStart",
    "JsxTagStartClose",
    "Less",
    "LessEqual",
    "LessLess",
    "LessLessEqual",
    "LetKeyword",
    "Minus",
    "MinusEqual",
    "MinusMinus",
    "NewKeyword",
    "NullKeyword",
    "Number",
    "OfKeyword",
    "ParenClose",
    "ParenOpen",
    "Percent",
    "PercentEqual",
    "Plus",
    "PlusEqual",
    "PlusPlus",
    "PrivateIdentifier",
    "Question",
    "QuestionDot",
    "QuestionQuestion",
    "QuestionQuestionEqual",
    "Regex",
    "ReturnKeyword",
    "Semicolon",
    "Slash",
    "SlashEqual",
    "Star",
    "StarEqual",
    "StarStar",
    "StarStarEqual",
    "StaticKeyword",
    "String",
    "SubstitutionStart",
    "SuperKeyword",
    "SwitchKeyword",
    "TemplateChars",
    "TemplateEnd",
    "TemplateStart",
    "ThisKeyword",
    "ThrowKeyword",
    "Tilde",
    "TrueKeyword",
    "TryKeyword",
    "TypeofKeyword",
    "UndefinedKeyword",
    "VarKeyword",
    "VoidKeyword",
    "WhileKeyword",
    "WithKeyword",
    "YieldKeyword",
    "abstract_class_declaration",
    "abstract_method_signature",
    "accessibility_modifier",
    "adding_type_annotation",
    "ambient_declaration",
    "arguments",
    "array",
    "array_pattern",
    "array_type",
    "arrow_function",
    "as_expression",
    "asserts",
    "asserts_annotation",
    "assignment_expression",
    "assignment_pattern",
    "augmented_assignment_expression",
    "await_expression",
    "binary_expression",
    "break_statement",
    "call_expression",
    "call_signature",
    "catch_clause",
    "class",
    "class_body",
    "class_declaration",
    "class_heritage",
    "class_static_block",
    "computed_property_name",
    "conditional_type",
    "constraint",
    "construct_signature",
    "constructor_type",
    "continue_statement",
    "debugger_statement",
    "decorator",
    "default_type",
    "do_statement",
    "else_clause",
    "empty_statement",
    "enum_assignment",
    "enum_body",
    "enum_declaration",
    "error_node",
    "existential_type",
    "export_clause",
    "export_specifier",
    "export_statement",
    "expression_statement",
    "extends_clause",
    "extends_type_clause",
    "false",
    "finally_clause",
    "flow_maybe_type",
    "for_in_statement",
    "for_statement",
    "formal_parameters",
    "function_declaration",
    "function_expression",
    "function_signature",
    "function_type",
    "generator_function",
    "generator_function_declaration",
    "generic_type",
    "identifier",
    "if_statement",
    "implements_clause",
    "import",
    "import_alias",
    "import_attribute",
    "import_clause",
    "import_require_clause",
    "import_specifier",
    "import_statement",
    "index_signature",
    "index_type_query",
    "infer_type",
    "instantiation_expression",
    "interface_body",
    "interface_declaration",
    "internal_module",
    "intersection_type",
    "jsx_attribute",
    "jsx_closing_element",
    "jsx_element",
    "jsx_expression",
    "jsx_namespace_name",
    "jsx_opening_element",
    "jsx_self_closing_element",
    "jsx_text",
    "labeled_statement",
    "lexical_declaration",
    "literal_type",
    "lookup_type",
    "mapped_type_clause",
    "member_expression",
    "meta_property",
    "method_definition",
    "method_signature",
    "module",
    "named_imports",
    "namespace_export",
    "namespace_import",
    "nested_identifier",
    "nested_type_identifier",
    "new_expression",
    "non_null_expression",
    "null",
    "number",
    "object",
    "object_assignment_pattern",
    "object_pattern",
    "object_type",
    "omitting_type_annotation",
    "opting_type_annotation",
    "optional_chain",
    "optional_parameter",
    "optional_type",
    "override_modifier",
    "pair",
    "pair_pattern",
    "parenthesized_expression",
    "parenthesized_type",
    "predefined_type",
    "private_property_identifier",
    "program",
    "property_identifier",
    "property_signature",
    "public_field_definition",
    "readonly_type",
    "regex",
    "required_parameter",
    "rest_pattern",
    "rest_type",
    "return_statement",
    "satisfies_expression",
    "sequence_expression",
    "shorthand_property_identifier",
    "shorthand_property_identifier_pattern",
    "spread_element",
    "statement_block",
    "statement_identifier",
    "string",
    "subscript_expression",
    "super",
    "switch_body",
    "switch_case",
    "switch_default",
    "switch_statement",
    "template_literal_type",
    "template_string",
    "template_substitution",
    "template_type",
    "ternary_expression",
    "this",
    "this_type",
    "throw_statement",
    "true",
    "try_statement",
    "tuple_type",
    "type_alias_declaration",
    "type_annotation",
    "type_arguments",
    "type_assertion",
    "type_identifier",
    "type_parameter",
    "type_parameters",
    "type_predicate",
    "type_predicate_annotation",
    "type_query",
    "unary_expression",
    "undefined",
    "union_type",
    "update_expression",
    "variable_declaration",
    "variable_declarator",
    "while_statement",
    "with_statement",
    "yield_expression",
];

impl Kind for TypeScriptKind {
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

impl TypeScriptKind {
    #[expect(
        clippy::too_many_lines,
        reason = "the projection names every kind, so its length is the grammar's and a shorter \
                  form would be a table the compiler cannot check"
    )]
    pub const fn category(self) -> Category {
        match self {
            Self::AssignmentExpression | Self::AugmentedAssignmentExpression => {
                Category::Assignment
            }
            Self::Decorator => Category::Attribute,
            Self::ClassBody
            | Self::ClassStaticBlock
            | Self::ElseClause
            | Self::EnumBody
            | Self::FinallyClause
            | Self::InterfaceBody
            | Self::InternalModule
            | Self::Module
            | Self::StatementBlock
            | Self::SwitchBody
            | Self::WithStatement => Category::Block,
            Self::IfStatement
            | Self::SwitchCase
            | Self::SwitchDefault
            | Self::TernaryExpression => Category::Branch,
            Self::CallExpression | Self::NewExpression => Category::Call,
            Self::AmbientDeclaration
            | Self::EnumAssignment
            | Self::IndexSignature
            | Self::LexicalDeclaration
            | Self::PropertySignature
            | Self::PublicFieldDefinition
            | Self::TypeAliasDeclaration
            | Self::VariableDeclaration
            | Self::VariableDeclarator => Category::Declaration,
            Self::CatchClause => Category::Except,
            Self::Arguments
            | Self::Array
            | Self::ArrayPattern
            | Self::AsExpression
            | Self::AssignmentPattern
            | Self::AwaitExpression
            | Self::BinaryExpression
            | Self::ComputedPropertyName
            | Self::ExpressionStatement
            | Self::InstantiationExpression
            | Self::JsxAttribute
            | Self::JsxClosingElement
            | Self::JsxElement
            | Self::JsxExpression
            | Self::JsxNamespaceName
            | Self::JsxOpeningElement
            | Self::JsxSelfClosingElement
            | Self::JsxText
            | Self::MemberExpression
            | Self::MetaProperty
            | Self::NonNullExpression
            | Self::Object
            | Self::ObjectAssignmentPattern
            | Self::ObjectPattern
            | Self::OptionalChain
            | Self::Pair
            | Self::PairPattern
            | Self::ParenthesizedExpression
            | Self::RestPattern
            | Self::SatisfiesExpression
            | Self::SequenceExpression
            | Self::SpreadElement
            | Self::SubscriptExpression
            | Self::Super
            | Self::TemplateString
            | Self::TemplateSubstitution
            | Self::This
            | Self::ThrowStatement
            | Self::TypeAssertion
            | Self::UnaryExpression
            | Self::UpdateExpression
            | Self::YieldExpression => Category::Expression,
            Self::Program => Category::File,
            Self::AbstractMethodSignature
            | Self::CallSignature
            | Self::ConstructSignature
            | Self::FunctionDeclaration
            | Self::FunctionExpression
            | Self::FunctionSignature
            | Self::GeneratorFunction
            | Self::GeneratorFunctionDeclaration
            | Self::MethodDefinition
            | Self::MethodSignature => Category::Function,
            Self::ExportClause
            | Self::ExportSpecifier
            | Self::ExportStatement
            | Self::ImportAlias
            | Self::ImportAttribute
            | Self::ImportClause
            | Self::ImportNode
            | Self::ImportRequireClause
            | Self::ImportSpecifier
            | Self::ImportStatement
            | Self::NamedImports
            | Self::NamespaceExport
            | Self::NamespaceImport => Category::Import,
            Self::ArrowFunction => Category::Lambda,
            Self::DoStatement
            | Self::ForInStatement
            | Self::ForStatement
            | Self::WhileStatement => Category::Loop,
            Self::SwitchStatement => Category::Match,
            Self::Identifier
            | Self::IdentifierNode
            | Self::NestedIdentifier
            | Self::PrivateIdentifier
            | Self::PrivatePropertyIdentifier
            | Self::PropertyIdentifier
            | Self::ShorthandPropertyIdentifier
            | Self::ShorthandPropertyIdentifierPattern
            | Self::StatementIdentifier => Category::Name,
            Self::OptionalParameter | Self::RequiredParameter | Self::TypeParameter => {
                Category::Parameter
            }
            Self::FormalParameters | Self::TypeParameters => Category::Parameters,
            Self::ReturnStatement => Category::Return,
            Self::AbstractClassDeclaration
            | Self::Class
            | Self::ClassDeclaration
            | Self::ClassHeritage
            | Self::EnumDeclaration
            | Self::ExtendsClause
            | Self::ExtendsTypeClause
            | Self::ImplementsClause
            | Self::InterfaceDeclaration => Category::Struct,
            Self::TryStatement => Category::Try,
            Self::AddingTypeAnnotation
            | Self::ArrayType
            | Self::Asserts
            | Self::AssertsAnnotation
            | Self::ConditionalType
            | Self::Constraint
            | Self::ConstructorType
            | Self::DefaultType
            | Self::ExistentialType
            | Self::FlowMaybeType
            | Self::FunctionType
            | Self::GenericType
            | Self::IndexTypeQuery
            | Self::InferType
            | Self::IntersectionType
            | Self::LiteralType
            | Self::LookupType
            | Self::MappedTypeClause
            | Self::NestedTypeIdentifier
            | Self::ObjectType
            | Self::OmittingTypeAnnotation
            | Self::OptingTypeAnnotation
            | Self::OptionalType
            | Self::ParenthesizedType
            | Self::PredefinedType
            | Self::ReadonlyType
            | Self::RestType
            | Self::TemplateLiteralType
            | Self::TemplateType
            | Self::ThisType
            | Self::TupleType
            | Self::TypeAnnotation
            | Self::TypeArguments
            | Self::TypeIdentifier
            | Self::TypePredicate
            | Self::TypePredicateAnnotation
            | Self::TypeQuery
            | Self::UnionType => Category::Type,
            Self::False
            | Self::FalseKeyword
            | Self::Null
            | Self::NullKeyword
            | Self::Number
            | Self::NumberNode
            | Self::Regex
            | Self::RegexNode
            | Self::String
            | Self::StringNode
            | Self::True
            | Self::TrueKeyword
            | Self::Undefined
            | Self::UndefinedKeyword => Category::Value,
            Self::AccessibilityModifier
            | Self::Ampersand
            | Self::AmpersandAmpersand
            | Self::AmpersandAmpersandEqual
            | Self::AmpersandEqual
            | Self::Arrow
            | Self::AsyncKeyword
            | Self::At
            | Self::AwaitKeyword
            | Self::Bang
            | Self::BangEqual
            | Self::BangEqualEqual
            | Self::Bar
            | Self::BarBar
            | Self::BarBarEqual
            | Self::BarEqual
            | Self::BraceClose
            | Self::BraceOpen
            | Self::BracketClose
            | Self::BracketOpen
            | Self::BreakKeyword
            | Self::BreakStatement
            | Self::Caret
            | Self::CaretEqual
            | Self::CaseKeyword
            | Self::CatchKeyword
            | Self::ClassKeyword
            | Self::Colon
            | Self::Comma
            | Self::Comment
            | Self::ConstKeyword
            | Self::ContinueKeyword
            | Self::ContinueStatement
            | Self::DebuggerKeyword
            | Self::DebuggerStatement
            | Self::DefaultKeyword
            | Self::DeleteKeyword
            | Self::DoKeyword
            | Self::Dot
            | Self::DotDotDot
            | Self::ElseKeyword
            | Self::EmptyStatement
            | Self::Equal
            | Self::EqualEqual
            | Self::EqualEqualEqual
            | Self::ErrorNode
            | Self::ErrorToken
            | Self::ExportKeyword
            | Self::ExtendsKeyword
            | Self::FinallyKeyword
            | Self::ForKeyword
            | Self::FunctionKeyword
            | Self::Greater
            | Self::GreaterEqual
            | Self::GreaterGreaterEqual
            | Self::GreaterGreaterGreaterEqual
            | Self::IfKeyword
            | Self::ImportKeyword
            | Self::InKeyword
            | Self::InstanceofKeyword
            | Self::JsxChars
            | Self::JsxEntity
            | Self::JsxTagEnd
            | Self::JsxTagEndSelf
            | Self::JsxTagStart
            | Self::JsxTagStartClose
            | Self::LabeledStatement
            | Self::Less
            | Self::LessEqual
            | Self::LessLess
            | Self::LessLessEqual
            | Self::LetKeyword
            | Self::Minus
            | Self::MinusEqual
            | Self::MinusMinus
            | Self::NewKeyword
            | Self::OfKeyword
            | Self::OverrideModifier
            | Self::ParenClose
            | Self::ParenOpen
            | Self::Percent
            | Self::PercentEqual
            | Self::Plus
            | Self::PlusEqual
            | Self::PlusPlus
            | Self::Question
            | Self::QuestionDot
            | Self::QuestionQuestion
            | Self::QuestionQuestionEqual
            | Self::ReturnKeyword
            | Self::Semicolon
            | Self::Slash
            | Self::SlashEqual
            | Self::Star
            | Self::StarEqual
            | Self::StarStar
            | Self::StarStarEqual
            | Self::StaticKeyword
            | Self::SubstitutionStart
            | Self::SuperKeyword
            | Self::SwitchKeyword
            | Self::TemplateChars
            | Self::TemplateEnd
            | Self::TemplateStart
            | Self::ThisKeyword
            | Self::ThrowKeyword
            | Self::Tilde
            | Self::TryKeyword
            | Self::TypeofKeyword
            | Self::VarKeyword
            | Self::VoidKeyword
            | Self::WhileKeyword
            | Self::WithKeyword
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
            assert_eq!(TypeScriptKind::of_u16(kind.to_u16()), Some(*kind));
            assert_eq!(TypeScriptKind::of_name(kind.name()), Some(*kind));
        }

        assert_eq!(KINDS.len(), KIND_COUNT as usize);
        assert_eq!(NAMES.len(), KIND_COUNT as usize);
        assert!(TypeScriptKind::of_u16(KIND_COUNT).is_none());
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
