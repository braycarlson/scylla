use crate::syntax::{Category, SyntaxError};
use crate::tree::Kind;

pub const KIND_COUNT: u16 = 105;
pub const NODE_FIRST: u16 = 42;

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
#[repr(u16)]
pub enum CSSKind {
    Ampersand = 0,
    At = 1,
    Bang = 2,
    BarEqual = 3,
    BraceClose = 4,
    BraceOpen = 5,
    BracketClose = 6,
    BracketOpen = 7,
    Caret = 8,
    CaretEqual = 9,
    Colon = 10,
    ColonColon = 11,
    Comma = 12,
    Comment = 13,
    Dollar = 14,
    DollarEqual = 15,
    Dot = 16,
    Equal = 17,
    ErrorToken = 18,
    Escape = 19,
    Float = 20,
    Greater = 21,
    Hash = 22,
    Identifier = 23,
    Less = 24,
    Minus = 25,
    Newline = 26,
    Number = 27,
    ParenClose = 28,
    ParenOpen = 29,
    Percent = 30,
    Pipe = 31,
    Plus = 32,
    Question = 33,
    Semicolon = 34,
    Slash = 35,
    Star = 36,
    StarEqual = 37,
    Text = 38,
    Tilde = 39,
    TildeEqual = 40,
    Unit = 41,
    AdjacentSiblingSelector = 42,
    Arguments = 43,
    AtKeyword = 44,
    AtRule = 45,
    AttributeName = 46,
    AttributeSelector = 47,
    BinaryExpression = 48,
    BinaryQuery = 49,
    Block = 50,
    CallExpression = 51,
    CharsetStatement = 52,
    ChildSelector = 53,
    ClassName = 54,
    ClassSelector = 55,
    ColorValue = 56,
    CommentNode = 57,
    Declaration = 58,
    DescendantSelector = 59,
    ErrorNode = 60,
    EscapeSequence = 61,
    FeatureName = 62,
    FeatureQuery = 63,
    FloatValue = 64,
    From = 65,
    FunctionName = 66,
    GridValue = 67,
    IdName = 68,
    IdSelector = 69,
    IdentifierNode = 70,
    ImportStatement = 71,
    Important = 72,
    IntegerValue = 73,
    JavaScriptComment = 74,
    KeyframeBlock = 75,
    KeyframeBlockList = 76,
    KeyframesName = 77,
    KeyframesStatement = 78,
    KeywordQuery = 79,
    MediaStatement = 80,
    NamespaceName = 81,
    NamespaceSelector = 82,
    NamespaceStatement = 83,
    NestingSelector = 84,
    ParenthesizedQuery = 85,
    ParenthesizedValue = 86,
    PlainValue = 87,
    PostcssStatement = 88,
    PropertyName = 89,
    PseudoClassSelector = 90,
    PseudoElementSelector = 91,
    RuleSet = 92,
    SelectorQuery = 93,
    Selectors = 94,
    SiblingSelector = 95,
    StringContent = 96,
    StringValue = 97,
    Stylesheet = 98,
    SupportsStatement = 99,
    TagName = 100,
    To = 101,
    UnaryQuery = 102,
    UnitNode = 103,
    UniversalSelector = 104,
}

static KINDS: [CSSKind; KIND_COUNT as usize] = [
    CSSKind::Ampersand,
    CSSKind::At,
    CSSKind::Bang,
    CSSKind::BarEqual,
    CSSKind::BraceClose,
    CSSKind::BraceOpen,
    CSSKind::BracketClose,
    CSSKind::BracketOpen,
    CSSKind::Caret,
    CSSKind::CaretEqual,
    CSSKind::Colon,
    CSSKind::ColonColon,
    CSSKind::Comma,
    CSSKind::Comment,
    CSSKind::Dollar,
    CSSKind::DollarEqual,
    CSSKind::Dot,
    CSSKind::Equal,
    CSSKind::ErrorToken,
    CSSKind::Escape,
    CSSKind::Float,
    CSSKind::Greater,
    CSSKind::Hash,
    CSSKind::Identifier,
    CSSKind::Less,
    CSSKind::Minus,
    CSSKind::Newline,
    CSSKind::Number,
    CSSKind::ParenClose,
    CSSKind::ParenOpen,
    CSSKind::Percent,
    CSSKind::Pipe,
    CSSKind::Plus,
    CSSKind::Question,
    CSSKind::Semicolon,
    CSSKind::Slash,
    CSSKind::Star,
    CSSKind::StarEqual,
    CSSKind::Text,
    CSSKind::Tilde,
    CSSKind::TildeEqual,
    CSSKind::Unit,
    CSSKind::AdjacentSiblingSelector,
    CSSKind::Arguments,
    CSSKind::AtKeyword,
    CSSKind::AtRule,
    CSSKind::AttributeName,
    CSSKind::AttributeSelector,
    CSSKind::BinaryExpression,
    CSSKind::BinaryQuery,
    CSSKind::Block,
    CSSKind::CallExpression,
    CSSKind::CharsetStatement,
    CSSKind::ChildSelector,
    CSSKind::ClassName,
    CSSKind::ClassSelector,
    CSSKind::ColorValue,
    CSSKind::CommentNode,
    CSSKind::Declaration,
    CSSKind::DescendantSelector,
    CSSKind::ErrorNode,
    CSSKind::EscapeSequence,
    CSSKind::FeatureName,
    CSSKind::FeatureQuery,
    CSSKind::FloatValue,
    CSSKind::From,
    CSSKind::FunctionName,
    CSSKind::GridValue,
    CSSKind::IdName,
    CSSKind::IdSelector,
    CSSKind::IdentifierNode,
    CSSKind::ImportStatement,
    CSSKind::Important,
    CSSKind::IntegerValue,
    CSSKind::JavaScriptComment,
    CSSKind::KeyframeBlock,
    CSSKind::KeyframeBlockList,
    CSSKind::KeyframesName,
    CSSKind::KeyframesStatement,
    CSSKind::KeywordQuery,
    CSSKind::MediaStatement,
    CSSKind::NamespaceName,
    CSSKind::NamespaceSelector,
    CSSKind::NamespaceStatement,
    CSSKind::NestingSelector,
    CSSKind::ParenthesizedQuery,
    CSSKind::ParenthesizedValue,
    CSSKind::PlainValue,
    CSSKind::PostcssStatement,
    CSSKind::PropertyName,
    CSSKind::PseudoClassSelector,
    CSSKind::PseudoElementSelector,
    CSSKind::RuleSet,
    CSSKind::SelectorQuery,
    CSSKind::Selectors,
    CSSKind::SiblingSelector,
    CSSKind::StringContent,
    CSSKind::StringValue,
    CSSKind::Stylesheet,
    CSSKind::SupportsStatement,
    CSSKind::TagName,
    CSSKind::To,
    CSSKind::UnaryQuery,
    CSSKind::UnitNode,
    CSSKind::UniversalSelector,
];

static NAMES: [&str; KIND_COUNT as usize] = [
    "Ampersand",
    "At",
    "Bang",
    "BarEqual",
    "BraceClose",
    "BraceOpen",
    "BracketClose",
    "BracketOpen",
    "Caret",
    "CaretEqual",
    "Colon",
    "ColonColon",
    "Comma",
    "Comment",
    "Dollar",
    "DollarEqual",
    "Dot",
    "Equal",
    "ErrorToken",
    "Escape",
    "Float",
    "Greater",
    "Hash",
    "Identifier",
    "Less",
    "Minus",
    "Newline",
    "Number",
    "ParenClose",
    "ParenOpen",
    "Percent",
    "Pipe",
    "Plus",
    "Question",
    "Semicolon",
    "Slash",
    "Star",
    "StarEqual",
    "Text",
    "Tilde",
    "TildeEqual",
    "Unit",
    "adjacent_sibling_selector",
    "arguments",
    "at_keyword",
    "at_rule",
    "attribute_name",
    "attribute_selector",
    "binary_expression",
    "binary_query",
    "block",
    "call_expression",
    "charset_statement",
    "child_selector",
    "class_name",
    "class_selector",
    "color_value",
    "comment",
    "declaration",
    "descendant_selector",
    "error_node",
    "escape_sequence",
    "feature_name",
    "feature_query",
    "float_value",
    "from",
    "function_name",
    "grid_value",
    "id_name",
    "id_selector",
    "identifier",
    "import_statement",
    "important",
    "integer_value",
    "js_comment",
    "keyframe_block",
    "keyframe_block_list",
    "keyframes_name",
    "keyframes_statement",
    "keyword_query",
    "media_statement",
    "namespace_name",
    "namespace_selector",
    "namespace_statement",
    "nesting_selector",
    "parenthesized_query",
    "parenthesized_value",
    "plain_value",
    "postcss_statement",
    "property_name",
    "pseudo_class_selector",
    "pseudo_element_selector",
    "rule_set",
    "selector_query",
    "selectors",
    "sibling_selector",
    "string_content",
    "string_value",
    "stylesheet",
    "supports_statement",
    "tag_name",
    "to",
    "unary_query",
    "unit",
    "universal_selector",
];

impl Kind for CSSKind {
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

impl CSSKind {
    #[expect(
        clippy::too_many_lines,
        reason = "the projection names every kind, so its length is the grammar's and a shorter \
                  form would be a table the compiler cannot check"
    )]
    pub const fn category(self) -> Category {
        match self {
            Self::AtRule | Self::AttributeName | Self::AttributeSelector => Category::Attribute,
            Self::Block
            | Self::KeyframeBlock
            | Self::KeyframeBlockList
            | Self::KeyframesStatement
            | Self::MediaStatement
            | Self::RuleSet
            | Self::SupportsStatement => Category::Block,
            Self::CallExpression => Category::Call,
            Self::BinaryQuery
            | Self::FeatureQuery
            | Self::KeywordQuery
            | Self::ParenthesizedQuery
            | Self::SelectorQuery
            | Self::UnaryQuery => Category::Condition,
            Self::Declaration => Category::Declaration,
            Self::AdjacentSiblingSelector
            | Self::Arguments
            | Self::BinaryExpression
            | Self::ChildSelector
            | Self::ClassSelector
            | Self::DescendantSelector
            | Self::IdSelector
            | Self::Important
            | Self::NamespaceSelector
            | Self::NestingSelector
            | Self::ParenthesizedValue
            | Self::PseudoClassSelector
            | Self::PseudoElementSelector
            | Self::Selectors
            | Self::SiblingSelector
            | Self::UniversalSelector => Category::Expression,
            Self::Stylesheet => Category::File,
            Self::CharsetStatement | Self::ImportStatement | Self::NamespaceStatement => {
                Category::Import
            }
            Self::ClassName
            | Self::FeatureName
            | Self::FunctionName
            | Self::IdName
            | Self::Identifier
            | Self::IdentifierNode
            | Self::KeyframesName
            | Self::NamespaceName
            | Self::PropertyName
            | Self::TagName => Category::Name,
            Self::ColorValue
            | Self::Float
            | Self::FloatValue
            | Self::From
            | Self::GridValue
            | Self::IntegerValue
            | Self::Number
            | Self::PlainValue
            | Self::StringContent
            | Self::StringValue
            | Self::Text
            | Self::To
            | Self::Unit
            | Self::UnitNode => Category::Value,
            Self::Ampersand
            | Self::At
            | Self::AtKeyword
            | Self::Bang
            | Self::BarEqual
            | Self::BraceClose
            | Self::BraceOpen
            | Self::BracketClose
            | Self::BracketOpen
            | Self::Caret
            | Self::CaretEqual
            | Self::Colon
            | Self::ColonColon
            | Self::Comma
            | Self::Comment
            | Self::CommentNode
            | Self::Dollar
            | Self::DollarEqual
            | Self::Dot
            | Self::Equal
            | Self::ErrorNode
            | Self::ErrorToken
            | Self::Escape
            | Self::EscapeSequence
            | Self::Greater
            | Self::Hash
            | Self::JavaScriptComment
            | Self::Less
            | Self::Minus
            | Self::Newline
            | Self::ParenClose
            | Self::ParenOpen
            | Self::Percent
            | Self::Pipe
            | Self::Plus
            | Self::PostcssStatement
            | Self::Question
            | Self::Semicolon
            | Self::Slash
            | Self::Star
            | Self::StarEqual
            | Self::Tilde
            | Self::TildeEqual => Category::Other,
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
            assert_eq!(CSSKind::of_u16(kind.to_u16()), Some(*kind));
            assert_eq!(CSSKind::of_name(kind.name()), Some(*kind));
        }

        assert_eq!(KINDS.len(), KIND_COUNT as usize);
        assert_eq!(NAMES.len(), KIND_COUNT as usize);
        assert!(CSSKind::of_u16(KIND_COUNT).is_none());
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
