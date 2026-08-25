use crate::syntax::Category;

pub const KIND_COUNT: u16 = 47;

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
#[repr(u16)]
pub enum MarkupKind {
    AngleClose = 0,
    AngleOpen = 1,
    AngleOpenSlash = 2,
    AttributeName = 3,
    AttributeText = 4,
    AttributeValue = 5,
    Attribute = 6,
    CloseTag = 7,
    Colon = 8,
    Comma = 9,
    CommentClose = 10,
    CommentOpen = 11,
    CommentText = 12,
    Doctype = 13,
    DoctypeText = 14,
    Document = 15,
    Dot = 16,
    Element = 17,
    ElementName = 18,
    Equals = 19,
    ErrorNode = 20,
    ErrorToken = 21,
    Filter = 22,
    FilterChain = 23,
    HTMLComment = 24,
    HTMLCommentClose = 25,
    HTMLCommentOpen = 26,
    Identifier = 27,
    Number = 28,
    OpenTag = 29,
    Pipe = 30,
    Quote = 31,
    ScriptText = 32,
    SlashAngleClose = 33,
    String = 34,
    StyleText = 35,
    TagClose = 36,
    TagName = 37,
    TagOpen = 38,
    TemplateComment = 39,
    TemplateTag = 40,
    TemplateVariable = 41,
    Text = 42,
    VariableClose = 43,
    VariableOpen = 44,
    VerbatimText = 45,
    Whitespace = 46,
}

static KINDS: [MarkupKind; KIND_COUNT as usize] = [
    MarkupKind::AngleClose,
    MarkupKind::AngleOpen,
    MarkupKind::AngleOpenSlash,
    MarkupKind::AttributeName,
    MarkupKind::AttributeText,
    MarkupKind::AttributeValue,
    MarkupKind::Attribute,
    MarkupKind::CloseTag,
    MarkupKind::Colon,
    MarkupKind::Comma,
    MarkupKind::CommentClose,
    MarkupKind::CommentOpen,
    MarkupKind::CommentText,
    MarkupKind::Doctype,
    MarkupKind::DoctypeText,
    MarkupKind::Document,
    MarkupKind::Dot,
    MarkupKind::Element,
    MarkupKind::ElementName,
    MarkupKind::Equals,
    MarkupKind::ErrorNode,
    MarkupKind::ErrorToken,
    MarkupKind::Filter,
    MarkupKind::FilterChain,
    MarkupKind::HTMLComment,
    MarkupKind::HTMLCommentClose,
    MarkupKind::HTMLCommentOpen,
    MarkupKind::Identifier,
    MarkupKind::Number,
    MarkupKind::OpenTag,
    MarkupKind::Pipe,
    MarkupKind::Quote,
    MarkupKind::ScriptText,
    MarkupKind::SlashAngleClose,
    MarkupKind::String,
    MarkupKind::StyleText,
    MarkupKind::TagClose,
    MarkupKind::TagName,
    MarkupKind::TagOpen,
    MarkupKind::TemplateComment,
    MarkupKind::TemplateTag,
    MarkupKind::TemplateVariable,
    MarkupKind::Text,
    MarkupKind::VariableClose,
    MarkupKind::VariableOpen,
    MarkupKind::VerbatimText,
    MarkupKind::Whitespace,
];

impl MarkupKind {
    pub const fn category(self) -> Category {
        match self {
            Self::Attribute | Self::AttributeName | Self::AttributeText | Self::AttributeValue => {
                Category::Attribute
            }
            Self::CloseTag | Self::Element | Self::OpenTag | Self::TagClose | Self::TagOpen => {
                Category::Block
            }
            Self::Filter | Self::FilterChain => Category::Call,
            Self::Document => Category::File,
            Self::ElementName | Self::Identifier | Self::TagName => Category::Name,
            Self::Number
            | Self::String
            | Self::TemplateVariable
            | Self::Text
            | Self::VerbatimText => Category::Value,
            Self::AngleClose
            | Self::AngleOpen
            | Self::AngleOpenSlash
            | Self::Colon
            | Self::Comma
            | Self::CommentClose
            | Self::CommentOpen
            | Self::CommentText
            | Self::Doctype
            | Self::DoctypeText
            | Self::Dot
            | Self::Equals
            | Self::ErrorNode
            | Self::ErrorToken
            | Self::HTMLComment
            | Self::HTMLCommentClose
            | Self::HTMLCommentOpen
            | Self::Pipe
            | Self::Quote
            | Self::ScriptText
            | Self::SlashAngleClose
            | Self::StyleText
            | Self::TemplateComment
            | Self::TemplateTag
            | Self::VariableClose
            | Self::VariableOpen
            | Self::Whitespace => Category::Other,
        }
    }

    pub const fn is_node(self) -> bool {
        matches!(
            self,
            Self::AttributeValue
                | Self::Attribute
                | Self::CloseTag
                | Self::Doctype
                | Self::Document
                | Self::Element
                | Self::ErrorNode
                | Self::Filter
                | Self::FilterChain
                | Self::HTMLComment
                | Self::OpenTag
                | Self::TemplateComment
                | Self::TemplateTag
                | Self::TemplateVariable
        )
    }

    pub const fn is_token(self) -> bool {
        !self.is_node()
    }

    pub const fn is_trivia(self) -> bool {
        matches!(self, Self::Whitespace)
    }

    pub const fn name(self) -> &'static str {
        match self {
            Self::AngleClose => "AngleClose",
            Self::AngleOpen => "AngleOpen",
            Self::AngleOpenSlash => "AngleOpenSlash",
            Self::AttributeName => "AttributeName",
            Self::AttributeText => "AttributeText",
            Self::AttributeValue => "AttributeValue",
            Self::Attribute => "Attribute",
            Self::CloseTag => "CloseTag",
            Self::Colon => "Colon",
            Self::Comma => "Comma",
            Self::CommentClose => "CommentClose",
            Self::CommentOpen => "CommentOpen",
            Self::CommentText => "CommentText",
            Self::Doctype => "Doctype",
            Self::DoctypeText => "DoctypeText",
            Self::Document => "Document",
            Self::Dot => "Dot",
            Self::Element => "Element",
            Self::ElementName => "ElementName",
            Self::Equals => "Equals",
            Self::ErrorNode => "ErrorNode",
            Self::ErrorToken => "ErrorToken",
            Self::Filter => "Filter",
            Self::FilterChain => "FilterChain",
            Self::HTMLComment => "HTMLComment",
            Self::HTMLCommentClose => "HTMLCommentClose",
            Self::HTMLCommentOpen => "HTMLCommentOpen",
            Self::Identifier => "Identifier",
            Self::Number => "Number",
            Self::OpenTag => "OpenTag",
            Self::Pipe => "Pipe",
            Self::Quote => "Quote",
            Self::ScriptText => "ScriptText",
            Self::SlashAngleClose => "SlashAngleClose",
            Self::String => "String",
            Self::StyleText => "StyleText",
            Self::TagClose => "TagClose",
            Self::TagName => "TagName",
            Self::TagOpen => "TagOpen",
            Self::TemplateComment => "TemplateComment",
            Self::TemplateTag => "TemplateTag",
            Self::TemplateVariable => "TemplateVariable",
            Self::Text => "Text",
            Self::VariableClose => "VariableClose",
            Self::VariableOpen => "VariableOpen",
            Self::VerbatimText => "VerbatimText",
            Self::Whitespace => "Whitespace",
        }
    }

    pub const fn to_u16(self) -> u16 {
        self as u16
    }

    pub fn of_name(name: &str) -> Option<Self> {
        KINDS.iter().copied().find(|kind| kind.name() == name)
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
            assert_eq!(MarkupKind::of_u16(kind.to_u16()), Some(*kind));
            assert_eq!(MarkupKind::of_name(kind.name()), Some(*kind));
        }

        assert_eq!(KINDS.len(), KIND_COUNT as usize);
        assert!(MarkupKind::of_u16(KIND_COUNT).is_none());
    }

    #[test]
    fn a_node_kind_is_never_a_token_kind() {
        for kind in &KINDS {
            assert_ne!(kind.is_node(), kind.is_token(), "{}", kind.name());
        }

        assert!(MarkupKind::Document.is_node());
        assert!(MarkupKind::Text.is_token());
        assert!(MarkupKind::Whitespace.is_trivia());
        assert!(!MarkupKind::Text.is_trivia());
    }
}
