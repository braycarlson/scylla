use crate::syntax::{Category, SyntaxError};
use crate::tree::Kind;

pub const KIND_COUNT: u16 = 223;
pub const NODE_FIRST: u16 = 117;

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
#[repr(u16)]
pub enum JavaScriptKind {
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
    GreaterGreater = 49,
    GreaterGreaterEqual = 50,
    GreaterGreaterGreater = 51,
    GreaterGreaterGreaterEqual = 52,
    Identifier = 53,
    IfKeyword = 54,
    ImportKeyword = 55,
    InKeyword = 56,
    InstanceofKeyword = 57,
    JsxChars = 58,
    JsxEntity = 59,
    JsxTagEnd = 60,
    JsxTagEndSelf = 61,
    JsxTagStart = 62,
    JsxTagStartClose = 63,
    Less = 64,
    LessEqual = 65,
    LessLess = 66,
    LessLessEqual = 67,
    LetKeyword = 68,
    Minus = 69,
    MinusEqual = 70,
    MinusMinus = 71,
    NewKeyword = 72,
    NullKeyword = 73,
    Number = 74,
    OfKeyword = 75,
    ParenClose = 76,
    ParenOpen = 77,
    Percent = 78,
    PercentEqual = 79,
    Plus = 80,
    PlusEqual = 81,
    PlusPlus = 82,
    PrivateIdentifier = 83,
    Question = 84,
    QuestionDot = 85,
    QuestionQuestion = 86,
    QuestionQuestionEqual = 87,
    Regex = 88,
    ReturnKeyword = 89,
    Semicolon = 90,
    Slash = 91,
    SlashEqual = 92,
    Star = 93,
    StarEqual = 94,
    StarStar = 95,
    StarStarEqual = 96,
    StaticKeyword = 97,
    String = 98,
    SubstitutionStart = 99,
    SuperKeyword = 100,
    SwitchKeyword = 101,
    TemplateChars = 102,
    TemplateEnd = 103,
    TemplateStart = 104,
    ThisKeyword = 105,
    ThrowKeyword = 106,
    Tilde = 107,
    TrueKeyword = 108,
    TryKeyword = 109,
    TypeofKeyword = 110,
    UndefinedKeyword = 111,
    VarKeyword = 112,
    VoidKeyword = 113,
    WhileKeyword = 114,
    WithKeyword = 115,
    YieldKeyword = 116,
    Arguments = 117,
    Array = 118,
    ArrayPattern = 119,
    ArrowFunction = 120,
    AssignmentExpression = 121,
    AssignmentPattern = 122,
    AugmentedAssignmentExpression = 123,
    AwaitExpression = 124,
    BinaryExpression = 125,
    BreakStatement = 126,
    CallExpression = 127,
    CatchClause = 128,
    Class = 129,
    ClassBody = 130,
    ClassDeclaration = 131,
    ClassHeritage = 132,
    ClassStaticBlock = 133,
    ComputedPropertyName = 134,
    ContinueStatement = 135,
    DebuggerStatement = 136,
    Decorator = 137,
    DoStatement = 138,
    ElseClause = 139,
    EmptyStatement = 140,
    ErrorNode = 141,
    ExportClause = 142,
    ExportSpecifier = 143,
    ExportStatement = 144,
    ExpressionStatement = 145,
    False = 146,
    FieldDefinition = 147,
    FinallyClause = 148,
    ForInStatement = 149,
    ForStatement = 150,
    FormalParameters = 151,
    FunctionDeclaration = 152,
    FunctionExpression = 153,
    GeneratorFunction = 154,
    GeneratorFunctionDeclaration = 155,
    IdentifierNode = 156,
    IfStatement = 157,
    ImportNode = 158,
    ImportAttribute = 159,
    ImportClause = 160,
    ImportSpecifier = 161,
    ImportStatement = 162,
    JsxAttribute = 163,
    JsxClosingElement = 164,
    JsxElement = 165,
    JsxExpression = 166,
    JsxNamespaceName = 167,
    JsxOpeningElement = 168,
    JsxSelfClosingElement = 169,
    JsxText = 170,
    LabeledStatement = 171,
    LexicalDeclaration = 172,
    MemberExpression = 173,
    MetaProperty = 174,
    MethodDefinition = 175,
    NamedImports = 176,
    NamespaceExport = 177,
    NamespaceImport = 178,
    NewExpression = 179,
    Null = 180,
    NumberNode = 181,
    Object = 182,
    ObjectAssignmentPattern = 183,
    ObjectPattern = 184,
    OptionalChain = 185,
    Pair = 186,
    PairPattern = 187,
    ParenthesizedExpression = 188,
    PrivatePropertyIdentifier = 189,
    Program = 190,
    PropertyIdentifier = 191,
    RegexNode = 192,
    RestPattern = 193,
    ReturnStatement = 194,
    SequenceExpression = 195,
    ShorthandPropertyIdentifier = 196,
    ShorthandPropertyIdentifierPattern = 197,
    SpreadElement = 198,
    StatementBlock = 199,
    StatementIdentifier = 200,
    StringNode = 201,
    SubscriptExpression = 202,
    Super = 203,
    SwitchBody = 204,
    SwitchCase = 205,
    SwitchDefault = 206,
    SwitchStatement = 207,
    TemplateString = 208,
    TemplateSubstitution = 209,
    TernaryExpression = 210,
    This = 211,
    ThrowStatement = 212,
    True = 213,
    TryStatement = 214,
    UnaryExpression = 215,
    Undefined = 216,
    UpdateExpression = 217,
    VariableDeclaration = 218,
    VariableDeclarator = 219,
    WhileStatement = 220,
    WithStatement = 221,
    YieldExpression = 222,
}

static KINDS: [JavaScriptKind; KIND_COUNT as usize] = [
    JavaScriptKind::Ampersand,
    JavaScriptKind::AmpersandAmpersand,
    JavaScriptKind::AmpersandAmpersandEqual,
    JavaScriptKind::AmpersandEqual,
    JavaScriptKind::Arrow,
    JavaScriptKind::AsyncKeyword,
    JavaScriptKind::At,
    JavaScriptKind::AwaitKeyword,
    JavaScriptKind::Bang,
    JavaScriptKind::BangEqual,
    JavaScriptKind::BangEqualEqual,
    JavaScriptKind::Bar,
    JavaScriptKind::BarBar,
    JavaScriptKind::BarBarEqual,
    JavaScriptKind::BarEqual,
    JavaScriptKind::BraceClose,
    JavaScriptKind::BraceOpen,
    JavaScriptKind::BracketClose,
    JavaScriptKind::BracketOpen,
    JavaScriptKind::BreakKeyword,
    JavaScriptKind::Caret,
    JavaScriptKind::CaretEqual,
    JavaScriptKind::CaseKeyword,
    JavaScriptKind::CatchKeyword,
    JavaScriptKind::ClassKeyword,
    JavaScriptKind::Colon,
    JavaScriptKind::Comma,
    JavaScriptKind::Comment,
    JavaScriptKind::ConstKeyword,
    JavaScriptKind::ContinueKeyword,
    JavaScriptKind::DebuggerKeyword,
    JavaScriptKind::DefaultKeyword,
    JavaScriptKind::DeleteKeyword,
    JavaScriptKind::DoKeyword,
    JavaScriptKind::Dot,
    JavaScriptKind::DotDotDot,
    JavaScriptKind::ElseKeyword,
    JavaScriptKind::Equal,
    JavaScriptKind::EqualEqual,
    JavaScriptKind::EqualEqualEqual,
    JavaScriptKind::ErrorToken,
    JavaScriptKind::ExportKeyword,
    JavaScriptKind::ExtendsKeyword,
    JavaScriptKind::FalseKeyword,
    JavaScriptKind::FinallyKeyword,
    JavaScriptKind::ForKeyword,
    JavaScriptKind::FunctionKeyword,
    JavaScriptKind::Greater,
    JavaScriptKind::GreaterEqual,
    JavaScriptKind::GreaterGreater,
    JavaScriptKind::GreaterGreaterEqual,
    JavaScriptKind::GreaterGreaterGreater,
    JavaScriptKind::GreaterGreaterGreaterEqual,
    JavaScriptKind::Identifier,
    JavaScriptKind::IfKeyword,
    JavaScriptKind::ImportKeyword,
    JavaScriptKind::InKeyword,
    JavaScriptKind::InstanceofKeyword,
    JavaScriptKind::JsxChars,
    JavaScriptKind::JsxEntity,
    JavaScriptKind::JsxTagEnd,
    JavaScriptKind::JsxTagEndSelf,
    JavaScriptKind::JsxTagStart,
    JavaScriptKind::JsxTagStartClose,
    JavaScriptKind::Less,
    JavaScriptKind::LessEqual,
    JavaScriptKind::LessLess,
    JavaScriptKind::LessLessEqual,
    JavaScriptKind::LetKeyword,
    JavaScriptKind::Minus,
    JavaScriptKind::MinusEqual,
    JavaScriptKind::MinusMinus,
    JavaScriptKind::NewKeyword,
    JavaScriptKind::NullKeyword,
    JavaScriptKind::Number,
    JavaScriptKind::OfKeyword,
    JavaScriptKind::ParenClose,
    JavaScriptKind::ParenOpen,
    JavaScriptKind::Percent,
    JavaScriptKind::PercentEqual,
    JavaScriptKind::Plus,
    JavaScriptKind::PlusEqual,
    JavaScriptKind::PlusPlus,
    JavaScriptKind::PrivateIdentifier,
    JavaScriptKind::Question,
    JavaScriptKind::QuestionDot,
    JavaScriptKind::QuestionQuestion,
    JavaScriptKind::QuestionQuestionEqual,
    JavaScriptKind::Regex,
    JavaScriptKind::ReturnKeyword,
    JavaScriptKind::Semicolon,
    JavaScriptKind::Slash,
    JavaScriptKind::SlashEqual,
    JavaScriptKind::Star,
    JavaScriptKind::StarEqual,
    JavaScriptKind::StarStar,
    JavaScriptKind::StarStarEqual,
    JavaScriptKind::StaticKeyword,
    JavaScriptKind::String,
    JavaScriptKind::SubstitutionStart,
    JavaScriptKind::SuperKeyword,
    JavaScriptKind::SwitchKeyword,
    JavaScriptKind::TemplateChars,
    JavaScriptKind::TemplateEnd,
    JavaScriptKind::TemplateStart,
    JavaScriptKind::ThisKeyword,
    JavaScriptKind::ThrowKeyword,
    JavaScriptKind::Tilde,
    JavaScriptKind::TrueKeyword,
    JavaScriptKind::TryKeyword,
    JavaScriptKind::TypeofKeyword,
    JavaScriptKind::UndefinedKeyword,
    JavaScriptKind::VarKeyword,
    JavaScriptKind::VoidKeyword,
    JavaScriptKind::WhileKeyword,
    JavaScriptKind::WithKeyword,
    JavaScriptKind::YieldKeyword,
    JavaScriptKind::Arguments,
    JavaScriptKind::Array,
    JavaScriptKind::ArrayPattern,
    JavaScriptKind::ArrowFunction,
    JavaScriptKind::AssignmentExpression,
    JavaScriptKind::AssignmentPattern,
    JavaScriptKind::AugmentedAssignmentExpression,
    JavaScriptKind::AwaitExpression,
    JavaScriptKind::BinaryExpression,
    JavaScriptKind::BreakStatement,
    JavaScriptKind::CallExpression,
    JavaScriptKind::CatchClause,
    JavaScriptKind::Class,
    JavaScriptKind::ClassBody,
    JavaScriptKind::ClassDeclaration,
    JavaScriptKind::ClassHeritage,
    JavaScriptKind::ClassStaticBlock,
    JavaScriptKind::ComputedPropertyName,
    JavaScriptKind::ContinueStatement,
    JavaScriptKind::DebuggerStatement,
    JavaScriptKind::Decorator,
    JavaScriptKind::DoStatement,
    JavaScriptKind::ElseClause,
    JavaScriptKind::EmptyStatement,
    JavaScriptKind::ErrorNode,
    JavaScriptKind::ExportClause,
    JavaScriptKind::ExportSpecifier,
    JavaScriptKind::ExportStatement,
    JavaScriptKind::ExpressionStatement,
    JavaScriptKind::False,
    JavaScriptKind::FieldDefinition,
    JavaScriptKind::FinallyClause,
    JavaScriptKind::ForInStatement,
    JavaScriptKind::ForStatement,
    JavaScriptKind::FormalParameters,
    JavaScriptKind::FunctionDeclaration,
    JavaScriptKind::FunctionExpression,
    JavaScriptKind::GeneratorFunction,
    JavaScriptKind::GeneratorFunctionDeclaration,
    JavaScriptKind::IdentifierNode,
    JavaScriptKind::IfStatement,
    JavaScriptKind::ImportNode,
    JavaScriptKind::ImportAttribute,
    JavaScriptKind::ImportClause,
    JavaScriptKind::ImportSpecifier,
    JavaScriptKind::ImportStatement,
    JavaScriptKind::JsxAttribute,
    JavaScriptKind::JsxClosingElement,
    JavaScriptKind::JsxElement,
    JavaScriptKind::JsxExpression,
    JavaScriptKind::JsxNamespaceName,
    JavaScriptKind::JsxOpeningElement,
    JavaScriptKind::JsxSelfClosingElement,
    JavaScriptKind::JsxText,
    JavaScriptKind::LabeledStatement,
    JavaScriptKind::LexicalDeclaration,
    JavaScriptKind::MemberExpression,
    JavaScriptKind::MetaProperty,
    JavaScriptKind::MethodDefinition,
    JavaScriptKind::NamedImports,
    JavaScriptKind::NamespaceExport,
    JavaScriptKind::NamespaceImport,
    JavaScriptKind::NewExpression,
    JavaScriptKind::Null,
    JavaScriptKind::NumberNode,
    JavaScriptKind::Object,
    JavaScriptKind::ObjectAssignmentPattern,
    JavaScriptKind::ObjectPattern,
    JavaScriptKind::OptionalChain,
    JavaScriptKind::Pair,
    JavaScriptKind::PairPattern,
    JavaScriptKind::ParenthesizedExpression,
    JavaScriptKind::PrivatePropertyIdentifier,
    JavaScriptKind::Program,
    JavaScriptKind::PropertyIdentifier,
    JavaScriptKind::RegexNode,
    JavaScriptKind::RestPattern,
    JavaScriptKind::ReturnStatement,
    JavaScriptKind::SequenceExpression,
    JavaScriptKind::ShorthandPropertyIdentifier,
    JavaScriptKind::ShorthandPropertyIdentifierPattern,
    JavaScriptKind::SpreadElement,
    JavaScriptKind::StatementBlock,
    JavaScriptKind::StatementIdentifier,
    JavaScriptKind::StringNode,
    JavaScriptKind::SubscriptExpression,
    JavaScriptKind::Super,
    JavaScriptKind::SwitchBody,
    JavaScriptKind::SwitchCase,
    JavaScriptKind::SwitchDefault,
    JavaScriptKind::SwitchStatement,
    JavaScriptKind::TemplateString,
    JavaScriptKind::TemplateSubstitution,
    JavaScriptKind::TernaryExpression,
    JavaScriptKind::This,
    JavaScriptKind::ThrowStatement,
    JavaScriptKind::True,
    JavaScriptKind::TryStatement,
    JavaScriptKind::UnaryExpression,
    JavaScriptKind::Undefined,
    JavaScriptKind::UpdateExpression,
    JavaScriptKind::VariableDeclaration,
    JavaScriptKind::VariableDeclarator,
    JavaScriptKind::WhileStatement,
    JavaScriptKind::WithStatement,
    JavaScriptKind::YieldExpression,
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
    "GreaterGreater",
    "GreaterGreaterEqual",
    "GreaterGreaterGreater",
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
    "arguments",
    "array",
    "array_pattern",
    "arrow_function",
    "assignment_expression",
    "assignment_pattern",
    "augmented_assignment_expression",
    "await_expression",
    "binary_expression",
    "break_statement",
    "call_expression",
    "catch_clause",
    "class",
    "class_body",
    "class_declaration",
    "class_heritage",
    "class_static_block",
    "computed_property_name",
    "continue_statement",
    "debugger_statement",
    "decorator",
    "do_statement",
    "else_clause",
    "empty_statement",
    "error_node",
    "export_clause",
    "export_specifier",
    "export_statement",
    "expression_statement",
    "false",
    "field_definition",
    "finally_clause",
    "for_in_statement",
    "for_statement",
    "formal_parameters",
    "function_declaration",
    "function_expression",
    "generator_function",
    "generator_function_declaration",
    "identifier",
    "if_statement",
    "import",
    "import_attribute",
    "import_clause",
    "import_specifier",
    "import_statement",
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
    "member_expression",
    "meta_property",
    "method_definition",
    "named_imports",
    "namespace_export",
    "namespace_import",
    "new_expression",
    "null",
    "number",
    "object",
    "object_assignment_pattern",
    "object_pattern",
    "optional_chain",
    "pair",
    "pair_pattern",
    "parenthesized_expression",
    "private_property_identifier",
    "program",
    "property_identifier",
    "regex",
    "rest_pattern",
    "return_statement",
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
    "template_string",
    "template_substitution",
    "ternary_expression",
    "this",
    "throw_statement",
    "true",
    "try_statement",
    "unary_expression",
    "undefined",
    "update_expression",
    "variable_declaration",
    "variable_declarator",
    "while_statement",
    "with_statement",
    "yield_expression",
];

impl Kind for JavaScriptKind {
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

impl JavaScriptKind {
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
            | Self::FinallyClause
            | Self::StatementBlock
            | Self::SwitchBody
            | Self::WithStatement => Category::Block,
            Self::IfStatement
            | Self::SwitchCase
            | Self::SwitchDefault
            | Self::TernaryExpression => Category::Branch,
            Self::CallExpression | Self::NewExpression => Category::Call,
            Self::FieldDefinition
            | Self::LexicalDeclaration
            | Self::VariableDeclaration
            | Self::VariableDeclarator => Category::Declaration,
            Self::CatchClause => Category::Except,
            Self::Arguments
            | Self::Array
            | Self::ArrayPattern
            | Self::AssignmentPattern
            | Self::AwaitExpression
            | Self::BinaryExpression
            | Self::ComputedPropertyName
            | Self::ExpressionStatement
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
            | Self::Object
            | Self::ObjectAssignmentPattern
            | Self::ObjectPattern
            | Self::OptionalChain
            | Self::Pair
            | Self::PairPattern
            | Self::ParenthesizedExpression
            | Self::RestPattern
            | Self::SequenceExpression
            | Self::SpreadElement
            | Self::SubscriptExpression
            | Self::Super
            | Self::TemplateString
            | Self::TemplateSubstitution
            | Self::This
            | Self::ThrowStatement
            | Self::UnaryExpression
            | Self::UpdateExpression
            | Self::YieldExpression => Category::Expression,
            Self::Program => Category::File,
            Self::FunctionDeclaration
            | Self::FunctionExpression
            | Self::GeneratorFunction
            | Self::GeneratorFunctionDeclaration
            | Self::MethodDefinition => Category::Function,
            Self::ExportClause
            | Self::ExportSpecifier
            | Self::ExportStatement
            | Self::ImportAttribute
            | Self::ImportClause
            | Self::ImportNode
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
            | Self::PrivateIdentifier
            | Self::PrivatePropertyIdentifier
            | Self::PropertyIdentifier
            | Self::ShorthandPropertyIdentifier
            | Self::ShorthandPropertyIdentifierPattern
            | Self::StatementIdentifier => Category::Name,
            Self::FormalParameters => Category::Parameters,
            Self::ReturnStatement => Category::Return,
            Self::Class | Self::ClassDeclaration | Self::ClassHeritage => Category::Struct,
            Self::TryStatement => Category::Try,
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
            Self::Ampersand
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
            | Self::GreaterGreater
            | Self::GreaterGreaterEqual
            | Self::GreaterGreaterGreater
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
            assert_eq!(JavaScriptKind::of_u16(kind.to_u16()), Some(*kind));
            assert_eq!(JavaScriptKind::of_name(kind.name()), Some(*kind));
        }

        assert_eq!(KINDS.len(), KIND_COUNT as usize);
        assert_eq!(NAMES.len(), KIND_COUNT as usize);
        assert!(JavaScriptKind::of_u16(KIND_COUNT).is_none());
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
