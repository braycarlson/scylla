use crate::bounded::{BoundedVec, Span};
use crate::markup::kind::MarkupKind;
use crate::markup::token::Token;
use crate::markup::tree::{NONE, Tree};

#[derive(Clone, Copy, Debug)]
pub struct View<'tree, 'tokens> {
    node: u32,
    tokens: &'tokens [Token],
    tree: &'tree Tree,
}

#[derive(Clone, Copy, Debug)]
pub struct Element<'tree, 'tokens>(View<'tree, 'tokens>);

#[derive(Clone, Copy, Debug)]
pub struct Attribute<'tree, 'tokens>(View<'tree, 'tokens>);

#[derive(Clone, Copy, Debug)]
pub struct AttributeValue<'tree, 'tokens>(View<'tree, 'tokens>);

#[derive(Clone, Copy, Debug)]
pub struct TemplateTag<'tree, 'tokens>(View<'tree, 'tokens>);

#[derive(Clone, Copy, Debug)]
pub struct TemplateVariable<'tree, 'tokens>(View<'tree, 'tokens>);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct KeywordArgument {
    pub name_token: u32,
    pub value: Span,
}

#[derive(Clone, Debug)]
pub struct Children<'tree, 'tokens> {
    current: u32,
    kind: Option<MarkupKind>,
    tokens: &'tokens [Token],
    tree: &'tree Tree,
}

#[derive(Clone, Debug)]
pub struct DirectTokens<'tree, 'tokens> {
    child: u32,
    kind: Option<MarkupKind>,
    limit: u32,
    position: u32,
    tokens: &'tokens [Token],
    tree: &'tree Tree,
}

impl<'tree, 'tokens> View<'tree, 'tokens> {
    pub fn new(tree: &'tree Tree, tokens: &'tokens [Token], node: u32) -> Self {
        assert!(node < tree.count());
        assert!(u32::try_from(tokens.len()).is_ok());

        Self { node, tokens, tree }
    }

    pub fn as_attribute(self) -> Option<Attribute<'tree, 'tokens>> {
        self.cast(MarkupKind::Attribute).map(Attribute)
    }

    pub fn as_attribute_value(self) -> Option<AttributeValue<'tree, 'tokens>> {
        self.cast(MarkupKind::AttributeValue).map(AttributeValue)
    }

    pub fn as_element(self) -> Option<Element<'tree, 'tokens>> {
        self.cast(MarkupKind::Element).map(Element)
    }

    pub fn as_template_tag(self) -> Option<TemplateTag<'tree, 'tokens>> {
        self.cast(MarkupKind::TemplateTag).map(TemplateTag)
    }

    pub fn as_template_variable(self) -> Option<TemplateVariable<'tree, 'tokens>> {
        self.cast(MarkupKind::TemplateVariable)
            .map(TemplateVariable)
    }

    pub fn children(self) -> Children<'tree, 'tokens> {
        self.children_of_kind(None)
    }

    pub fn children_of(self, kind: MarkupKind) -> Children<'tree, 'tokens> {
        self.children_of_kind(Some(kind))
    }

    pub fn direct_tokens(self) -> DirectTokens<'tree, 'tokens> {
        self.direct_tokens_bounded(None, NONE)
    }

    pub fn direct_tokens_of(self, kind: MarkupKind) -> DirectTokens<'tree, 'tokens> {
        self.direct_tokens_bounded(Some(kind), NONE)
    }

    pub fn direct_tokens_bounded(
        self,
        kind: Option<MarkupKind>,
        limit: u32,
    ) -> DirectTokens<'tree, 'tokens> {
        let node = self.tree.at(self.node);

        DirectTokens {
            child: node.child_first,
            kind,
            limit: limit.min(node.token_end),
            position: node.token_start,
            tokens: self.tokens,
            tree: self.tree,
        }
    }

    pub fn index(self) -> u32 {
        self.node
    }

    pub fn kind(self) -> MarkupKind {
        self.tree.at(self.node).kind
    }

    pub fn span(self) -> Span {
        self.tree.at(self.node).span(self.tokens)
    }

    pub fn subtree_tokens_of(self, kind: MarkupKind) -> impl Iterator<Item = u32> + use<'tokens> {
        let node = self.tree.at(self.node);
        let tokens = self.tokens;

        (node.token_start..node.token_end).filter(move |index| tokens[*index as usize].kind == kind)
    }

    pub fn token_at(self, index: u32) -> Token {
        self.tokens[index as usize]
    }

    pub fn token_first(self, kind: MarkupKind) -> Option<u32> {
        self.direct_tokens_of(kind).next()
    }

    pub fn token_start(self) -> u32 {
        self.tree.at(self.node).token_start
    }

    fn cast(self, kind: MarkupKind) -> Option<Self> {
        if self.kind() == kind {
            return Some(self);
        }

        None
    }

    fn children_of_kind(self, kind: Option<MarkupKind>) -> Children<'tree, 'tokens> {
        Children {
            current: self.tree.at(self.node).child_first,
            kind,
            tokens: self.tokens,
            tree: self.tree,
        }
    }
}

impl<'tree, 'tokens> Iterator for Children<'tree, 'tokens> {
    type Item = View<'tree, 'tokens>;

    fn next(&mut self) -> Option<Self::Item> {
        while self.current != NONE {
            let node = self.tree.at(self.current);
            let found = View {
                node: self.current,
                tokens: self.tokens,
                tree: self.tree,
            };

            self.current = node.sibling_next;

            if self.kind.is_none_or(|wanted| wanted == node.kind) {
                return Some(found);
            }
        }

        None
    }
}

impl Iterator for DirectTokens<'_, '_> {
    type Item = u32;

    fn next(&mut self) -> Option<Self::Item> {
        while self.position < self.limit {
            if self.child != NONE {
                let node = self.tree.at(self.child);

                if self.position >= node.token_end {
                    self.child = node.sibling_next;

                    continue;
                }

                if self.position >= node.token_start {
                    self.position = node.token_end;
                    self.child = node.sibling_next;

                    continue;
                }
            }

            let found = self.position;

            self.position += 1;

            let kind = self.tokens[found as usize].kind;

            if self.kind.is_none_or(|wanted| wanted == kind) {
                return Some(found);
            }
        }

        None
    }
}

impl<'tree, 'tokens> Element<'tree, 'tokens> {
    pub fn attributes(self) -> impl Iterator<Item = Attribute<'tree, 'tokens>> {
        self.open_tag()
            .into_iter()
            .flat_map(|open| open.children_of(MarkupKind::Attribute))
            .filter_map(View::as_attribute)
    }

    pub fn name_equals_ignore_case(self, name: &[u8], source: &[u8]) -> bool {
        let Some(token) = self.name_token() else {
            return false;
        };

        self.0
            .token_at(token)
            .text(source)
            .eq_ignore_ascii_case(name)
    }

    pub fn name_token(self) -> Option<u32> {
        self.open_tag()?.token_first(MarkupKind::ElementName)
    }

    pub fn open_tag(self) -> Option<View<'tree, 'tokens>> {
        self.0.children_of(MarkupKind::OpenTag).next()
    }

    pub fn raw_text_tokens(self) -> impl Iterator<Item = u32> + use<'tree, 'tokens> {
        self.0.direct_tokens().filter(move |index| {
            matches!(
                self.0.token_at(*index).kind,
                MarkupKind::ScriptText | MarkupKind::StyleText
            )
        })
    }

    pub fn view(self) -> View<'tree, 'tokens> {
        self.0
    }
}

impl<'tree, 'tokens> Attribute<'tree, 'tokens> {
    pub fn name_token(self) -> Option<u32> {
        self.0.token_first(MarkupKind::AttributeName)
    }

    pub fn value(self) -> Option<AttributeValue<'tree, 'tokens>> {
        self.0
            .children_of(MarkupKind::AttributeValue)
            .next()
            .and_then(View::as_attribute_value)
    }

    pub fn view(self) -> View<'tree, 'tokens> {
        self.0
    }
}

impl<'tree, 'tokens> AttributeValue<'tree, 'tokens> {
    pub fn inner_span(self) -> Span {
        let span = self.0.span();
        let mut start = span.offset;
        let mut end = span.end();
        let mut first = None;
        let mut last = None;

        for index in self.0.direct_tokens_of(MarkupKind::Quote) {
            if first.is_none() {
                first = Some(index);
            }

            last = Some(index);
        }

        if let Some(index) = first {
            let quote = self.0.token_at(index);

            if quote.offset == start {
                start = quote.end();
            }
        }

        if let Some(index) = last {
            let quote = self.0.token_at(index);

            if quote.end() == end && quote.offset >= start {
                end = quote.offset;
            }
        }

        assert!(start <= end);

        Span {
            length: end - start,
            offset: start,
        }
    }

    pub fn is_quoted(self) -> bool {
        self.0.direct_tokens_of(MarkupKind::Quote).next().is_some()
    }

    pub fn template_holes(self, out: &mut BoundedVec<Span>) -> bool {
        let mut room = true;

        for child in self.0.children() {
            if !matches!(
                child.kind(),
                MarkupKind::TemplateComment
                    | MarkupKind::TemplateTag
                    | MarkupKind::TemplateVariable
            ) {
                continue;
            }

            room = out.push(child.span()) && room;
        }

        room
    }

    pub fn text_tokens(self) -> impl Iterator<Item = u32> + use<'tokens> {
        self.0.subtree_tokens_of(MarkupKind::AttributeText)
    }

    pub fn view(self) -> View<'tree, 'tokens> {
        self.0
    }
}

impl<'tree, 'tokens> TemplateTag<'tree, 'tokens> {
    pub fn argument_tokens(self) -> impl Iterator<Item = u32> + use<'tree, 'tokens> {
        let mut seen_name = false;

        self.0.direct_tokens().filter(move |index| {
            let kind = self.0.token_at(*index).kind;

            if kind == MarkupKind::TagName && !seen_name {
                seen_name = true;

                return false;
            }

            seen_name
                && !kind.is_trivia()
                && !matches!(kind, MarkupKind::TagOpen | MarkupKind::TagClose)
        })
    }

    pub fn is_closed(self) -> bool {
        self.0.token_first(MarkupKind::TagClose).is_some()
    }

    pub fn keyword_arguments(self, source: &[u8], out: &mut BoundedVec<KeywordArgument>) -> bool {
        let mut window = [NONE; 3];
        let mut filled = 0_u32;
        let mut room = true;

        for index in self.argument_tokens() {
            window[0] = window[1];
            window[1] = window[2];
            window[2] = index;
            filled = (filled + 1).min(3);

            if filled < 3 {
                continue;
            }

            let name = self.0.token_at(window[0]);
            let equals = self.0.token_at(window[1]);
            let value = self.0.token_at(window[2]);

            if name.kind != MarkupKind::Identifier
                || equals.kind != MarkupKind::Equals
                || value.kind != MarkupKind::String
            {
                continue;
            }

            let Some(inner) = unquote(value, source) else {
                continue;
            };

            room = out.push(KeywordArgument {
                name_token: window[0],
                value: inner,
            }) && room;
        }

        room
    }

    pub fn name_token(self) -> Option<u32> {
        self.0.token_first(MarkupKind::TagName)
    }

    pub fn string_arguments(self, source: &[u8], out: &mut BoundedVec<Span>) -> bool {
        let mut room = true;

        for index in self.argument_tokens() {
            let token = self.0.token_at(index);

            if token.kind != MarkupKind::String {
                continue;
            }

            let Some(inner) = unquote(token, source) else {
                continue;
            };

            room = out.push(inner) && room;
        }

        room
    }

    pub fn view(self) -> View<'tree, 'tokens> {
        self.0
    }
}

impl<'tree, 'tokens> TemplateVariable<'tree, 'tokens> {
    pub fn expression_tokens(self) -> impl Iterator<Item = u32> + use<'tree, 'tokens> {
        let limit = self
            .0
            .children_of(MarkupKind::FilterChain)
            .next()
            .map_or(NONE, View::token_start);

        self.0
            .direct_tokens_bounded(None, limit)
            .filter(move |index| {
                let kind = self.0.token_at(*index).kind;

                !kind.is_trivia()
                    && !matches!(kind, MarkupKind::VariableOpen | MarkupKind::VariableClose)
            })
    }

    pub fn filter_names(self) -> impl Iterator<Item = u32> + use<'tree, 'tokens> {
        self.0
            .children_of(MarkupKind::FilterChain)
            .flat_map(|chain| chain.children_of(MarkupKind::Filter))
            .filter_map(|filter| filter.token_first(MarkupKind::Identifier))
    }

    pub fn view(self) -> View<'tree, 'tokens> {
        self.0
    }
}

pub fn unquote(token: Token, source: &[u8]) -> Option<Span> {
    let text = token.text(source);
    let quote = *text.first()?;

    if quote != b'"' && quote != b'\'' {
        return Some(token.span());
    }

    let last = text.len().checked_sub(1)?;

    if text.len() < 2 || text.get(last) != Some(&quote) {
        return None;
    }

    Some(Span {
        length: token.length - 2,
        offset: token.offset + 1,
    })
}
