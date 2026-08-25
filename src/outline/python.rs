use crate::bounded::{BoundedVec, Span, count_of};
use crate::brackets::Pairs;
use crate::outline::Scopes;
use crate::structure::{NONE, Node, NodeKind};
use crate::summary::{self, Summary};
use crate::token::{Punctuation, Token, TokenKind};

const DECORATOR_PREFIX: &[u8] = b"@";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Argument {
    pub name: Span,
    pub summary: Summary,
    pub value_token_end: u32,
    pub value_token_start: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Assignment {
    pub annotation: Span,
    pub scope: u32,
    pub target: Span,
    pub target_is_simple: bool,
    pub value_token_end: u32,
    pub value_token_start: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Base {
    pub class_definition: u32,
    pub summary: Summary,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Call {
    pub argument_count: u32,
    pub argument_first: u32,
    pub callee_segment_count: u32,
    pub callee_segment_first: u32,
    pub paren_close: u32,
    pub paren_open: u32,
    pub scope: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Decorator {
    pub call: u32,
    pub definition: u32,
    pub segment_count: u32,
    pub segment_first: u32,
}

#[derive(Debug)]
pub struct Outline {
    arguments: BoundedVec<Argument>,
    assignments: BoundedVec<Assignment>,
    bases: BoundedVec<Base>,
    calls: BoundedVec<Call>,
    decorators: BoundedVec<Decorator>,
    items: BoundedVec<Summary>,
    segments: BoundedVec<Span>,
}

struct Builder<'run> {
    nodes: &'run [Node],
    outline: &'run mut Outline,
    pairs: &'run Pairs,
    source: &'run [u8],
    tokens: &'run [Token],
}

impl Outline {
    pub fn reserve(row_count_max: u32, segment_count_max: u32) -> Self {
        assert!(row_count_max > 0);
        assert!(segment_count_max > 0);

        assert!(!crate::allocation::is_frozen());

        Self {
            arguments: BoundedVec::reserve(row_count_max),
            assignments: BoundedVec::reserve(row_count_max),
            bases: BoundedVec::reserve(row_count_max),
            calls: BoundedVec::reserve(row_count_max),
            decorators: BoundedVec::reserve(row_count_max),
            items: BoundedVec::reserve(row_count_max),
            segments: BoundedVec::reserve(segment_count_max),
        }
    }

    pub fn arguments(&self) -> &[Argument] {
        &self.arguments
    }

    pub fn assignments(&self) -> &[Assignment] {
        &self.assignments
    }

    pub fn bases(&self) -> &[Base] {
        &self.bases
    }

    pub fn calls(&self) -> &[Call] {
        &self.calls
    }

    pub fn clear(&mut self) {
        self.arguments.clear();
        self.assignments.clear();
        self.bases.clear();
        self.calls.clear();
        self.decorators.clear();
        self.items.clear();
        self.segments.clear();

        assert_eq!(self.calls.count(), 0);
    }

    pub fn decorators(&self) -> &[Decorator] {
        &self.decorators
    }

    pub fn items(&self) -> &[Summary] {
        &self.items
    }

    pub fn segments(&self) -> &[Span] {
        &self.segments
    }

    pub fn segments_of(&self, first: u32, count: u32) -> &[Span] {
        let start = first as usize;
        let end = start + count as usize;

        assert!(end <= self.segments.count() as usize);

        &self.segments[start..end]
    }
}

impl Builder<'_> {
    fn chain_end(&self, first: u32) -> u32 {
        let mut last = first;

        while last + 2 < self.count() {
            if !self.tokens[last as usize + 1].is_punctuation(Punctuation::Dot) {
                break;
            }

            if !self.is_name(last + 2) {
                break;
            }

            last += 2;
        }

        last
    }

    fn count(&self) -> u32 {
        count_of(self.tokens.len())
    }

    fn is_name(&self, index: u32) -> bool {
        index < self.count()
            && matches!(
                self.tokens[index as usize].kind,
                TokenKind::Identifier | TokenKind::Keyword(_)
            )
    }

    fn is_significant(&self, index: u32) -> bool {
        !matches!(
            self.tokens[index as usize].kind,
            TokenKind::Comment | TokenKind::Newline
        )
    }

    fn significant_next(&self, from: u32, end: u32) -> u32 {
        let mut index = from;

        while index < end {
            if self.is_significant(index) {
                return index;
            }

            index += 1;
        }

        NONE
    }

    fn summarize(&mut self, start: u32, end: u32) -> Summary {
        summary::read(
            self.source,
            self.tokens,
            self.pairs,
            start,
            end,
            &mut self.outline.segments,
            &mut self.outline.items,
        )
    }

    fn text(&self, index: u32) -> &[u8] {
        self.tokens[index as usize].text(self.source)
    }

    fn build_arguments(&mut self, open: u32, close: u32) -> (u32, u32) {
        let first = self.outline.arguments.count();
        let depth = self.pairs.depth_of(open) + 1;
        let mut count = 0;
        let mut start = open + 1;
        let mut index = open + 1;

        while index <= close {
            let splits = index == close
                || (self.tokens[index as usize].is_punctuation(Punctuation::Comma)
                    && self.pairs.depth_of(index) == depth);

            if !splits {
                index += 1;

                continue;
            }

            if self.significant_next(start, index) != NONE {
                let argument = self.read_argument(start, index);

                if self.outline.arguments.push(argument) {
                    count += 1;
                }
            }

            start = index + 1;
            index += 1;
        }

        (first, count)
    }

    fn build_bases(&mut self, definition: u32) {
        let node = self.nodes[definition as usize];

        if node.kind != NodeKind::Struct || node.name == NONE {
            return;
        }

        let after = self.significant_next(node.name + 1, node.token_end.min(self.count()));

        if after == NONE || !self.tokens[after as usize].is_punctuation(Punctuation::ParenOpen) {
            return;
        }

        let close = self.pairs.partner_of(after);

        if close == crate::brackets::NONE {
            return;
        }

        let depth = self.pairs.depth_of(after) + 1;
        let mut start = after + 1;
        let mut index = after + 1;

        while index <= close {
            let splits = index == close
                || (self.tokens[index as usize].is_punctuation(Punctuation::Comma)
                    && self.pairs.depth_of(index) == depth);

            if !splits {
                index += 1;

                continue;
            }

            if self.significant_next(start, index) != NONE {
                let summary = self.summarize(start, index);
                let _ = self.outline.bases.push(Base {
                    class_definition: definition,
                    summary,
                });
            }

            start = index + 1;
            index += 1;
        }
    }

    fn build_calls(&mut self) {
        let mut scopes = Scopes::new(self.nodes, self.count());
        let mut index = 0;

        while index < self.count() {
            if !self.is_name(index) || self.is_dotted_tail(index) {
                index += 1;

                continue;
            }

            let chain = self.chain_end(index);
            let open = chain + 1;

            if open >= self.count()
                || !self.tokens[open as usize].is_punctuation(Punctuation::ParenOpen)
            {
                index = chain + 1;

                continue;
            }

            let close = self.pairs.partner_of(open);

            if close == crate::brackets::NONE {
                index = chain + 1;

                continue;
            }

            scopes.advance(index);

            let scope = scopes.enclosing(&[NodeKind::Function, NodeKind::Struct]);
            let segment_first = self.outline.segments.count();
            let mut segment_count = 0;
            let mut segment = index;

            while segment <= chain {
                if self.is_name(segment)
                    && self
                        .outline
                        .segments
                        .push(self.tokens[segment as usize].span())
                {
                    segment_count += 1;
                }

                segment += 2;
            }

            let (argument_first, argument_count) = self.build_arguments(open, close);

            let _ = self.outline.calls.push(Call {
                argument_count,
                argument_first,
                callee_segment_count: segment_count,
                callee_segment_first: segment_first,
                paren_close: close,
                paren_open: open,
                scope,
            });

            index = open + 1;
        }
    }

    fn build_definitions(&mut self) {
        for index in 0..self.nodes.len() {
            self.build_bases(count_of(index));
        }
    }

    fn build_statements(&mut self) {
        let mut scopes = Scopes::new(self.nodes, self.count());
        let mut start = 0;
        let mut index = 0;

        while index <= self.count() {
            let ends = index == self.count() || self.statement_ends(start, index);

            if !ends {
                index += 1;

                continue;
            }

            if self.significant_next(start, index) != NONE {
                scopes.advance(start);

                let scope = scopes.enclosing(&[NodeKind::Function, NodeKind::Struct]);

                self.read_statement(start, index, scope);
            }

            start = index + 1;
            index += 1;
        }
    }

    fn is_dotted_tail(&self, index: u32) -> bool {
        index >= 2
            && self.tokens[index as usize - 1].is_punctuation(Punctuation::Dot)
            && self.is_name(index - 2)
    }

    fn read_argument(&mut self, start: u32, end: u32) -> Argument {
        let first = self.significant_next(start, end);
        let mut name = Span::EMPTY;
        let mut value = start;

        if first != NONE && self.is_name(first) {
            let equals = self.significant_next(first + 1, end);

            if equals != NONE
                && self.tokens[equals as usize].is_punctuation(Punctuation::Assign)
                && self.chain_end(first) == first
            {
                name = self.tokens[first as usize].span();
                value = equals + 1;
            }
        }

        let summary = self.summarize(value, end);

        Argument {
            name,
            summary,
            value_token_end: end,
            value_token_start: value,
        }
    }

    fn read_statement(&mut self, start: u32, end: u32, scope: u32) {
        let first = self.significant_next(start, end);

        if first == NONE {
            return;
        }

        if self.text(first) == DECORATOR_PREFIX {
            self.read_decorator(first + 1, end);

            return;
        }

        if !self.is_name(first) {
            return;
        }

        let chain = self.chain_end(first);
        let after = self.significant_next(chain + 1, end);

        if after == NONE {
            return;
        }

        let colon = self.tokens[after as usize].is_punctuation(Punctuation::Colon);

        if !colon && !self.tokens[after as usize].is_punctuation(Punctuation::Assign) {
            return;
        }

        let equals = if colon {
            self.assign_after(after + 1, end)
        } else {
            after
        };

        let annotation = if colon {
            self.run_between(after + 1, if equals == NONE { end } else { equals })
        } else {
            Span::EMPTY
        };

        let target = Span {
            length: self.tokens[chain as usize].offset + self.tokens[chain as usize].length
                - self.tokens[first as usize].offset,
            offset: self.tokens[first as usize].offset,
        };

        let value_token_start = if equals == NONE { end } else { equals + 1 };

        let _ = self.outline.assignments.push(Assignment {
            annotation,
            scope,
            target,
            target_is_simple: chain == first,
            value_token_end: end,
            value_token_start,
        });
    }

    fn assign_after(&self, start: u32, end: u32) -> u32 {
        let mut index = start;

        while index < end {
            if self.tokens[index as usize].is_punctuation(Punctuation::Assign) {
                return index;
            }

            let partner = self.pairs.partner_of(index);

            index = if partner > index && partner < end {
                partner + 1
            } else {
                index + 1
            };
        }

        NONE
    }

    fn run_between(&self, start: u32, end: u32) -> Span {
        let first = self.significant_next(start, end);

        if first == NONE {
            return Span::EMPTY;
        }

        let mut last = first;
        let mut index = first;

        while index < end {
            if self.is_significant(index) {
                last = index;
            }

            index += 1;
        }

        let head = self.tokens[first as usize];
        let tail = self.tokens[last as usize];

        Span {
            length: tail.offset + tail.length - head.offset,
            offset: head.offset,
        }
    }

    fn read_decorator(&mut self, start: u32, end: u32) {
        let first = self.significant_next(start, end);

        if first == NONE || !self.is_name(first) {
            return;
        }

        let chain = self.chain_end(first);
        let segment_first = self.outline.segments.count();
        let mut segment_count = 0;
        let mut segment = first;

        while segment <= chain {
            if self.is_name(segment)
                && self
                    .outline
                    .segments
                    .push(self.tokens[segment as usize].span())
            {
                segment_count += 1;
            }

            segment += 2;
        }

        let open = self.significant_next(chain + 1, end);

        let call =
            if open != NONE && self.tokens[open as usize].is_punctuation(Punctuation::ParenOpen) {
                self.call_at(open)
            } else {
                NONE
            };

        let _ = self.outline.decorators.push(Decorator {
            call,
            definition: self.definition_after(end),
            segment_count,
            segment_first,
        });
    }

    fn call_at(&self, open: u32) -> u32 {
        for (index, call) in self.outline.calls.iter().enumerate() {
            if call.paren_open == open {
                return count_of(index);
            }
        }

        NONE
    }

    fn definition_after(&self, token: u32) -> u32 {
        for (index, node) in self.nodes.iter().enumerate() {
            if !matches!(node.kind, NodeKind::Function | NodeKind::Struct) {
                continue;
            }

            if node.token_start >= token {
                return count_of(index);
            }
        }

        NONE
    }

    fn annotates(&self, start: u32, colon: u32) -> bool {
        let first = self.significant_next(start, colon);

        if first == NONE || !self.is_name(first) {
            return false;
        }

        if matches!(self.tokens[first as usize].kind, TokenKind::Keyword(_)) {
            return false;
        }

        self.significant_next(self.chain_end(first) + 1, colon) == NONE
    }

    fn statement_ends(&self, start: u32, index: u32) -> bool {
        let token = self.tokens[index as usize];

        match token.kind {
            TokenKind::BlockEnd | TokenKind::BlockStart => true,
            TokenKind::Newline => self.pairs.depth_of(index) == 0,
            TokenKind::Punctuation(Punctuation::Colon) => {
                self.pairs.depth_of(index) == 0 && !self.annotates(start, index)
            }
            TokenKind::Comment
            | TokenKind::Identifier
            | TokenKind::Keyword(_)
            | TokenKind::Number
            | TokenKind::Punctuation(_)
            | TokenKind::String => false,
        }
    }
}

pub fn build(
    source: &[u8],
    tokens: &[Token],
    pairs: &Pairs,
    nodes: &[Node],
    outline: &mut Outline,
) {
    assert!(u32::try_from(source.len()).is_ok());
    assert_eq!(pairs.count() as usize, tokens.len());

    outline.clear();

    let mut builder = Builder {
        nodes,
        outline,
        pairs,
        source,
        tokens,
    };

    builder.build_calls();
    builder.build_statements();
    builder.build_definitions();
}
