use crate::bounded::{Bytes, Span, count_of};
use crate::markup::kind::MarkupKind;
use crate::markup::token::Token;
use crate::syntax::Category;
use crate::tree::Kind;

pub use crate::tree::{FRAME_DEPTH_MAX, Links, NONE, Step, Structure, Walk, walk, walk_from};

pub const ELEMENT_DEPTH_MAX: u32 = 256;
pub const UNWIND_DEPTH_MAX: u32 = 64;
pub type Node = crate::tree::Node<MarkupKind>;
pub type Tree = crate::tree::Tree<MarkupKind>;

const IMPLIED_CLOSE: [(&[u8], &[&[u8]]); 8] = [
    (b"dd", &[b"dd", b"dt"]),
    (b"dt", &[b"dd", b"dt"]),
    (b"li", &[b"li"]),
    (b"option", &[b"optgroup", b"option"]),
    (
        b"p",
        &[
            b"address",
            b"article",
            b"aside",
            b"blockquote",
            b"div",
            b"dl",
            b"fieldset",
            b"footer",
            b"form",
            b"h1",
            b"h2",
            b"h3",
            b"h4",
            b"h5",
            b"h6",
            b"header",
            b"hr",
            b"main",
            b"nav",
            b"ol",
            b"p",
            b"pre",
            b"section",
            b"table",
            b"ul",
        ],
    ),
    (b"td", &[b"td", b"th", b"tr"]),
    (b"th", &[b"td", b"th", b"tr"]),
    (b"tr", &[b"tr"]),
];

const VOID_ELEMENTS: [&[u8]; 14] = [
    b"area",
    b"base",
    b"br",
    b"col",
    b"embed",
    b"hr",
    b"img",
    b"input",
    b"link",
    b"meta",
    b"param",
    b"source",
    b"track",
    b"wbr",
];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TreeErrorKind {
    SourceTooLarge,
    UnclosedElement,
    UnexpectedCloseTag,
    UnterminatedAttributeValue,
    UnterminatedTemplateComment,
    UnterminatedTemplateTag,
    UnterminatedTemplateVariable,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TreeError {
    pub kind: TreeErrorKind,
    pub name: Span,
    pub span: Span,
}

#[derive(Clone, Copy, Debug)]
struct Frame {
    last_child: u32,
    name_token: u32,
    node: u32,
    offset: u32,
}

struct Builder<'source, 'tokens, 'tree> {
    depth: u32,
    outcome: Structure,
    position: u32,
    source: &'source [u8],
    stack: [Frame; FRAME_DEPTH_MAX as usize],
    tokens: &'tokens [Token],
    tree: &'tree mut Tree,
}

impl Kind for MarkupKind {
    type Error = TreeError;
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

    fn name(self) -> &'static str {
        Self::name(self)
    }
}

impl TreeErrorKind {
    pub const fn name(self) -> &'static str {
        match self {
            Self::SourceTooLarge => "SourceTooLarge",
            Self::UnclosedElement => "UnclosedElement",
            Self::UnexpectedCloseTag => "UnexpectedCloseTag",
            Self::UnterminatedAttributeValue => "UnterminatedAttributeValue",
            Self::UnterminatedTemplateComment => "UnterminatedTemplateComment",
            Self::UnterminatedTemplateTag => "UnterminatedTemplateTag",
            Self::UnterminatedTemplateVariable => "UnterminatedTemplateVariable",
        }
    }
}

impl<'source, 'tokens, 'tree> Builder<'source, 'tokens, 'tree> {
    fn new(source: &'source [u8], tokens: &'tokens [Token], tree: &'tree mut Tree) -> Self {
        let empty = Frame {
            last_child: NONE,
            name_token: NONE,
            node: NONE,
            offset: 0,
        };

        assert!(u32::try_from(tokens.len()).is_ok());

        Self {
            depth: 0,
            outcome: Structure::Complete,
            position: 0,
            source,
            stack: [empty; FRAME_DEPTH_MAX as usize],
            tokens,
            tree,
        }
    }

    fn bump(&mut self) {
        if self.position as usize >= self.tokens.len() {
            return;
        }

        self.position += 1;
    }

    fn bump_trivia(&mut self) {
        while self.current().is_some_and(MarkupKind::is_trivia) {
            self.bump();
        }
    }

    fn close_filters(&mut self, filters: &mut u8) {
        if *filters == 0 {
            return;
        }

        self.finish_node();
        self.finish_node();

        *filters = 0;
    }

    fn close_implied_by(&mut self, opening: u32) {
        if opening == NONE || self.depth == 0 {
            return;
        }

        let open = self.stack[self.depth as usize - 1].name_token;

        if open == NONE {
            return;
        }

        let name = self.name_of(opening);

        let closes = IMPLIED_CLOSE
            .iter()
            .find(|entry| name_equals(self.name_of(open), entry.0))
            .is_some_and(|entry| entry.1.iter().any(|closer| name_equals(name, closer)));

        if closes {
            self.finish_node();
        }
    }

    fn close_open_elements(&mut self) {
        while self.depth > 1 {
            self.close_unclosed_element();
        }
    }

    fn close_unclosed_element(&mut self) {
        assert!(self.depth > 0);

        let frame = self.stack[self.depth as usize - 1];

        if frame.name_token != NONE {
            self.record(
                TreeErrorKind::UnclosedElement,
                frame.offset,
                frame.name_token,
            );
        }

        self.finish_node();
    }

    fn current(&self) -> Option<MarkupKind> {
        self.tokens
            .get(self.position as usize)
            .map(|token| token.kind)
    }

    fn current_offset(&self) -> u32 {
        self.tokens
            .get(self.position as usize)
            .map_or(0, |token| token.offset)
    }

    fn element_depth(&self) -> u32 {
        let mut count = 0;

        for index in 0..self.depth {
            if self.stack[index as usize].name_token != NONE {
                count += 1;
            }
        }

        count
    }

    fn element_name_at(&self, position: u32) -> u32 {
        let Some(token) = self.tokens.get(position as usize) else {
            return NONE;
        };

        if token.kind != MarkupKind::ElementName {
            return NONE;
        }

        position
    }

    fn finish(&mut self) {
        while self.depth > 0 {
            self.finish_node();
        }
    }

    fn finish_node(&mut self) {
        if self.depth == 0 {
            return;
        }

        self.depth -= 1;

        let frame = self.stack[self.depth as usize];

        if frame.node == NONE {
            return;
        }

        self.tree.set_token_end(frame.node, self.position);
    }

    fn matching_frame(&self, name: u32) -> u32 {
        if name == NONE {
            return NONE;
        }

        let wanted = self.name_of(name);
        let mut seen = 0;
        let mut index = self.depth;

        while index > 0 {
            if seen >= UNWIND_DEPTH_MAX {
                return NONE;
            }

            index -= 1;

            let frame = self.stack[index as usize];

            if frame.name_token != NONE && name_equals(self.name_of(frame.name_token), wanted) {
                return seen;
            }

            seen += 1;
        }

        NONE
    }

    fn name_of(&self, token: u32) -> &'source [u8] {
        assert!(token != NONE);

        let Some(found) = self.tokens.get(token as usize) else {
            return &[];
        };

        let end = found.end() as usize;

        assert!(end <= self.source.len());

        &self.source[found.offset as usize..end]
    }

    fn open_filter(&mut self, filters: &mut u8) {
        if *filters == 0 {
            self.start(MarkupKind::FilterChain, NONE);
        } else {
            self.finish_node();
        }

        self.start(MarkupKind::Filter, NONE);

        *filters = 2;
    }

    fn parse_attribute(&mut self) {
        assert_eq!(self.current(), Some(MarkupKind::AttributeName));

        self.start(MarkupKind::Attribute, NONE);
        self.bump();

        if self.peek_significant() != Some(MarkupKind::Equals) {
            self.finish_node();

            return;
        }

        self.bump_trivia();
        self.bump();
        self.bump_trivia();

        let current = self.current();

        match current {
            Some(MarkupKind::Quote) => self.parse_quoted_value(),
            Some(MarkupKind::AttributeText) => self.parse_wrapped(MarkupKind::AttributeValue),
            _ => {}
        }

        self.finish_node();
    }

    fn parse_attributes(&mut self) -> Option<MarkupKind> {
        while let Some(kind) = self.current() {
            if matches!(kind, MarkupKind::AngleClose | MarkupKind::SlashAngleClose) {
                self.bump();

                return Some(kind);
            } else if kind == MarkupKind::AttributeName {
                self.parse_attribute();
            } else if is_construct_open(kind) {
                self.parse_template_construct(kind);
            } else {
                self.bump();
            }
        }

        None
    }

    fn parse_close_tag(&mut self) {
        let name = self.element_name_at(self.position.saturating_add(1));
        let start = self.current_offset();
        let unwind = self.matching_frame(name);

        if unwind == NONE {
            self.record(TreeErrorKind::UnexpectedCloseTag, start, name);
            self.parse_wrapped_close_tag(MarkupKind::ErrorNode);

            return;
        }

        for _ in 0..unwind {
            self.close_unclosed_element();
        }

        self.parse_wrapped_close_tag(MarkupKind::CloseTag);
        self.finish_node();
    }

    fn parse_html_comment(&mut self) {
        self.start(MarkupKind::HTMLComment, NONE);
        self.bump();

        while let Some(kind) = self.current() {
            if is_construct_open(kind) {
                self.parse_template_construct(kind);
            } else if kind == MarkupKind::HTMLCommentClose {
                self.bump();

                break;
            } else {
                self.bump();
            }
        }

        self.finish_node();
    }

    fn parse_open_tag(&mut self) {
        let name = self.element_name_at(self.position.saturating_add(1));

        self.close_implied_by(name);

        let nests = self.element_depth() < ELEMENT_DEPTH_MAX;

        self.start(MarkupKind::Element, name);
        self.start(MarkupKind::OpenTag, NONE);
        self.bump();

        if self.current() == Some(MarkupKind::ElementName) {
            self.bump();
        }

        let closed = self.parse_attributes();

        self.finish_node();

        let void = name != NONE
            && VOID_ELEMENTS
                .iter()
                .any(|element| name_equals(self.name_of(name), element));

        if closed.is_none() || closed == Some(MarkupKind::SlashAngleClose) || void || !nests {
            self.finish_node();
        }
    }

    fn parse_quoted_value(&mut self) {
        let start = self.current_offset();

        self.start(MarkupKind::AttributeValue, NONE);
        self.bump();

        let mut terminated = false;

        while let Some(kind) = self.current() {
            if kind == MarkupKind::Quote {
                self.bump();
                terminated = true;

                break;
            } else if is_construct_open(kind) {
                self.parse_template_construct(kind);
            } else if kind == MarkupKind::AttributeText {
                self.bump();
            } else {
                break;
            }
        }

        if !terminated {
            self.record(TreeErrorKind::UnterminatedAttributeValue, start, NONE);
        }

        self.finish_node();
    }

    fn parse_template_construct(&mut self, open: MarkupKind) {
        let (node, close, error) = construct_shape(open);
        let start = self.current_offset();

        self.start(node, NONE);
        self.bump();

        let mut filters = 0_u8;
        let mut terminated = false;

        while let Some(kind) = self.current() {
            if kind == close {
                self.close_filters(&mut filters);
                self.bump();
                terminated = true;

                break;
            }

            if kind == MarkupKind::Pipe {
                self.open_filter(&mut filters);
            }

            self.bump();
        }

        self.close_filters(&mut filters);

        if !terminated {
            self.record(error, start, NONE);
        }

        self.finish_node();
    }

    fn parse_wrapped(&mut self, node: MarkupKind) {
        self.start(node, NONE);
        self.bump();
        self.finish_node();
    }

    fn parse_wrapped_close_tag(&mut self, wrapper: MarkupKind) {
        self.start(wrapper, NONE);
        self.bump();

        while let Some(kind) = self.current() {
            self.bump();

            if kind == MarkupKind::AngleClose {
                break;
            }
        }

        self.finish_node();
    }

    fn peek_significant(&self) -> Option<MarkupKind> {
        let rest = self.tokens.get(self.position as usize..)?;

        rest.iter()
            .find(|token| !token.kind.is_trivia())
            .map(|token| token.kind)
    }

    fn record(&mut self, kind: TreeErrorKind, offset: u32, name_token: u32) {
        let name = self
            .tokens
            .get(name_token as usize)
            .map_or(Span::EMPTY, Token::span);

        let recorded = self.tree.push_error(TreeError {
            kind,
            name,
            span: Span { length: 0, offset },
        });

        if !recorded && self.outcome == Structure::Complete {
            self.outcome = Structure::Truncated;
        }
    }

    fn run(&mut self) -> Structure {
        self.start(MarkupKind::Document, NONE);

        while (self.position as usize) < self.tokens.len() {
            let before = self.position;

            self.step();

            if self.outcome == Structure::TooDeep {
                break;
            }

            if self.position <= before {
                self.bump();
            }
        }

        self.close_open_elements();
        self.finish();

        self.outcome
    }

    fn start(&mut self, kind: MarkupKind, name_token: u32) {
        assert!(kind.is_node());

        if self.depth >= FRAME_DEPTH_MAX {
            self.outcome = Structure::TooDeep;

            return;
        }

        let offset = self.current_offset();

        let parent = if self.depth == 0 {
            NONE
        } else {
            self.stack[self.depth as usize - 1].node
        };

        let index = self.tree.count();

        let pushed = self.tree.push(Node {
            child_first: NONE,
            kind,
            parent,
            sibling_next: NONE,
            token_end: NONE,
            token_start: self.position,
        });

        if !pushed {
            self.outcome = Structure::Truncated;

            self.stack[self.depth as usize] = Frame {
                last_child: NONE,
                name_token,
                node: NONE,
                offset,
            };

            self.depth += 1;

            return;
        }

        if self.depth > 0 {
            self.link(index);
        }

        self.stack[self.depth as usize] = Frame {
            last_child: NONE,
            name_token,
            node: index,
            offset,
        };

        self.depth += 1;
    }

    fn link(&mut self, index: u32) {
        let parent = self.depth as usize - 1;
        let last = self.stack[parent].last_child;

        if last == NONE {
            let node = self.stack[parent].node;

            if node != NONE {
                self.tree.set_child_first(node, index);
            }
        } else {
            self.tree.set_sibling_next(last, index);
        }

        self.stack[parent].last_child = index;
    }

    fn step(&mut self) {
        let Some(kind) = self.current() else {
            return;
        };

        match kind {
            MarkupKind::AngleOpen => self.parse_open_tag(),
            MarkupKind::AngleOpenSlash => self.parse_close_tag(),
            MarkupKind::CommentOpen | MarkupKind::TagOpen | MarkupKind::VariableOpen => {
                self.parse_template_construct(kind);
            }
            MarkupKind::DoctypeText => self.parse_wrapped(MarkupKind::Doctype),
            MarkupKind::HTMLCommentOpen => self.parse_html_comment(),
            MarkupKind::AngleClose
            | MarkupKind::AttributeName
            | MarkupKind::AttributeText
            | MarkupKind::AttributeValue
            | MarkupKind::Attribute
            | MarkupKind::CloseTag
            | MarkupKind::Colon
            | MarkupKind::Comma
            | MarkupKind::CommentClose
            | MarkupKind::CommentText
            | MarkupKind::Doctype
            | MarkupKind::Document
            | MarkupKind::Dot
            | MarkupKind::Element
            | MarkupKind::ElementName
            | MarkupKind::Equals
            | MarkupKind::ErrorNode
            | MarkupKind::ErrorToken
            | MarkupKind::Filter
            | MarkupKind::FilterChain
            | MarkupKind::HTMLComment
            | MarkupKind::HTMLCommentClose
            | MarkupKind::Identifier
            | MarkupKind::Number
            | MarkupKind::OpenTag
            | MarkupKind::Pipe
            | MarkupKind::Quote
            | MarkupKind::ScriptText
            | MarkupKind::SlashAngleClose
            | MarkupKind::String
            | MarkupKind::StyleText
            | MarkupKind::TagClose
            | MarkupKind::TagName
            | MarkupKind::TemplateComment
            | MarkupKind::TemplateTag
            | MarkupKind::TemplateVariable
            | MarkupKind::Text
            | MarkupKind::VariableClose
            | MarkupKind::VerbatimText
            | MarkupKind::Whitespace => self.bump(),
        }
    }
}

const fn construct_shape(open: MarkupKind) -> (MarkupKind, MarkupKind, TreeErrorKind) {
    if matches!(open, MarkupKind::CommentOpen) {
        return (
            MarkupKind::TemplateComment,
            MarkupKind::CommentClose,
            TreeErrorKind::UnterminatedTemplateComment,
        );
    }

    if matches!(open, MarkupKind::TagOpen) {
        return (
            MarkupKind::TemplateTag,
            MarkupKind::TagClose,
            TreeErrorKind::UnterminatedTemplateTag,
        );
    }

    (
        MarkupKind::TemplateVariable,
        MarkupKind::VariableClose,
        TreeErrorKind::UnterminatedTemplateVariable,
    )
}

const fn is_construct_open(kind: MarkupKind) -> bool {
    matches!(
        kind,
        MarkupKind::CommentOpen | MarkupKind::TagOpen | MarkupKind::VariableOpen
    )
}

fn name_equals(name: &[u8], other: &[u8]) -> bool {
    name.eq_ignore_ascii_case(other)
}

pub fn dump<W>(out: &mut W, tree: &Tree, tokens: &[Token], source: &[u8]) -> bool
where
    W: Bytes,
{
    assert!(u32::try_from(source.len()).is_ok());

    if !crate::tree::dump(out, tree, tokens, source, |token| token.kind.name()) {
        return false;
    }

    if tree.errors().is_empty() {
        return true;
    }

    if !out.push_bytes(b"\nerrors:\n") {
        return false;
    }

    for error in tree.errors() {
        let mut digits = [0_u8; crate::scan::DECIMAL_BYTES_MAX];
        let length = crate::scan::decimal_write(&mut digits, u64::from(error.span.offset));

        let written = out.push_bytes(b"  ")
            && out.push_bytes(error.kind.name().as_bytes())
            && out.push_bytes(b"@")
            && out.push_bytes(&digits[..length])
            && out.push_bytes(b"\n");

        if !written {
            return false;
        }
    }

    true
}

pub fn build(source: &[u8], tokens: &[Token], tree: &mut Tree) -> Structure {
    assert!(u32::try_from(source.len()).is_ok());
    assert!(u32::try_from(tokens.len()).is_ok());

    tree.clear();

    let mut builder = Builder::new(source, tokens, tree);
    let outcome = builder.run();

    assert!(count_of(tokens.len()) >= tree.count() || tree.count() > 0);

    outcome
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bounded::BoundedString;
    use crate::markup::{self, Tokens};

    fn built(source: &[u8]) -> (Tokens, Tree) {
        let mut tokens = Tokens::reserve(1 << 10);
        let mut tree = Tree::reserve(1 << 10, 1 << 4);

        markup::lex(source, &mut tokens);
        let _ = build(source, tokens.as_slice(), &mut tree);

        (tokens, tree)
    }

    #[test]
    fn an_unclosed_element_names_its_tag() {
        const SOURCE: &[u8] = b"<div><span>a</div>\n";

        let (_, tree) = built(SOURCE);
        let error = tree.errors()[0];

        assert_eq!(error.kind, TreeErrorKind::UnclosedElement);
        assert_eq!(&SOURCE[error.name.range()], b"span");
        assert_eq!(error.span.offset, 5);
    }

    #[test]
    fn an_unexpected_close_tag_names_its_tag() {
        const SOURCE: &[u8] = b"<div></p></div>\n";

        let (_, tree) = built(SOURCE);
        let error = tree.errors()[0];

        assert_eq!(error.kind, TreeErrorKind::UnexpectedCloseTag);
        assert_eq!(&SOURCE[error.name.range()], b"p");
        assert_eq!(error.span.offset, 5);
    }

    #[test]
    fn an_unterminated_construct_names_nothing() {
        const SOURCE: &[u8] = b"{{ a ";

        let (_, tree) = built(SOURCE);

        assert_eq!(tree.errors().len(), 1);
        assert_eq!(tree.errors()[0].kind, TreeErrorKind::UnterminatedTemplateVariable);
        assert_eq!(tree.errors()[0].name, Span::EMPTY);
    }

    #[test]
    fn a_dump_lists_the_tree_then_its_errors() {
        const SOURCE: &[u8] = b"<p>a";

        let (tokens, tree) = built(SOURCE);
        let mut out = BoundedString::reserve(1 << 10);

        assert!(dump(&mut out, &tree, tokens.as_slice(), SOURCE));

        assert_eq!(
            out.as_str(),
            "Document@0..4\n  Element@0..4\n    OpenTag@0..3\n      AngleOpen@0..1 \"<\"\n      ElementName@1..2 \"p\"\n      AngleClose@2..3 \">\"\n    Text@3..4 \"a\"\n\nerrors:\n  UnclosedElement@0\n"
        );
    }

    #[test]
    fn a_starved_dump_reports_the_overflow() {
        const SOURCE: &[u8] = b"<p>a</p>\n";

        let (tokens, tree) = built(SOURCE);
        let mut out = BoundedString::reserve(8);

        assert!(!dump(&mut out, &tree, tokens.as_slice(), SOURCE));
    }
}
