use crate::bounded::{Span, count_of};
use crate::syntax::css::expression::{
    CHAIN_DEPTH_MAX,
    NEST_DEPTH_MAX,
    NTH_LITERALS,
    QUERY_JOINS,
    QUERY_PREFIXES,
    SCAN_STEP_MAX,
    SELECTOR_LITERALS,
    combinator_node,
    hex_end,
    identifier_end,
    is_combinator,
    is_loose_postfix,
    is_tight_postfix,
    is_value_operator,
    opens_a_selector,
    plain_value_end,
};
use crate::syntax::css::kind::CSSKind;
use crate::syntax::{SyntaxError, SyntaxErrorKind};
use crate::token::Token;
use crate::tree::{Checkpoint, Events, Structure, Tree, replay};

const ATTRIBUTE_OPERATORS: [CSSKind; 6] = [
    CSSKind::BarEqual,
    CSSKind::CaretEqual,
    CSSKind::DollarEqual,
    CSSKind::Equal,
    CSSKind::StarEqual,
    CSSKind::TildeEqual,
];

const BLOCK_STOP: [CSSKind; 3] = [CSSKind::BraceClose, CSSKind::BraceOpen, CSSKind::Semicolon];
const DECLARATION_STOP: [CSSKind; 2] = [CSSKind::BraceClose, CSSKind::Semicolon];
const QUERY_STOP: [CSSKind; 2] = [CSSKind::BraceOpen, CSSKind::Semicolon];

struct Parser<'run> {
    events: &'run mut Events<CSSKind>,
    nesting: u32,
    outcome: Structure,
    position: u32,
    raw: &'run [CSSKind],
    significant_next: u32,
    source: &'run [u8],
    tokens: &'run [Token],
    tree: &'run mut Tree<CSSKind>,
}

const fn is_layout(kind: CSSKind) -> bool {
    matches!(kind, CSSKind::Comment | CSSKind::Newline)
}

const fn opens_a_group(kind: CSSKind) -> bool {
    matches!(kind, CSSKind::BracketOpen | CSSKind::ParenOpen)
}

const fn closes_a_group(kind: CSSKind) -> bool {
    matches!(kind, CSSKind::BracketClose | CSSKind::ParenClose)
}

impl Parser<'_> {
    fn count(&self) -> u32 {
        count_of(self.raw.len())
    }

    fn kind_at(&self, position: u32) -> Option<CSSKind> {
        self.raw.get(position as usize).copied()
    }

    fn text_at(&self, position: u32) -> &[u8] {
        self.tokens
            .get(position as usize)
            .map_or(&[][..], |token| token.text(self.source))
    }

    fn significant(&self, from: u32) -> u32 {
        if from == self.position {
            return self.significant_next;
        }

        self.scan_significant(from)
    }

    fn scan_significant(&self, from: u32) -> u32 {
        let mut position = from;

        for _ in 0..=self.count() {
            let Some(kind) = self.kind_at(position) else {
                break;
            };

            if !is_layout(kind) {
                break;
            }

            position += 1;
        }

        position
    }

    fn current(&self) -> Option<CSSKind> {
        self.kind_at(self.significant(self.position))
    }

    fn current_text(&self) -> &[u8] {
        self.text_at(self.significant(self.position))
    }

    fn ahead(&self, steps: u32) -> Option<CSSKind> {
        let mut position = self.significant(self.position);

        for _ in 0..steps {
            position = self.significant(position + 1);
        }

        self.kind_at(position)
    }

    fn at(&self, kind: CSSKind) -> bool {
        self.current() == Some(kind)
    }

    fn separated(&self) -> bool {
        let held = self.significant(self.position);

        if held > self.position {
            return true;
        }

        if held == 0 {
            return false;
        }

        let Some(token) = self.tokens.get(held as usize) else {
            return false;
        };

        token.offset > self.tokens[held as usize - 1].end()
    }

    fn adjacent(&self, position: u32) -> bool {
        if position == 0 {
            return false;
        }

        let Some(token) = self.tokens.get(position as usize) else {
            return false;
        };

        token.offset == self.tokens[position as usize - 1].end()
    }

    fn emit(&mut self) {
        let Some(kind) = self.kind_at(self.position) else {
            return;
        };

        if is_layout(kind) {
            self.events.layout(self.position);
        } else {
            self.events.token(self.position);
        }

        self.position += 1;

        if self.position > self.significant_next {
            self.significant_next = self.scan_significant(self.position);
        }
    }

    fn emit_layout(&mut self) {
        if self.kind_at(self.position).is_none() {
            return;
        }

        self.events.layout(self.position);
        self.position += 1;

        if self.position > self.significant_next {
            self.significant_next = self.scan_significant(self.position);
        }
    }

    fn skip_trivia(&mut self) {
        for _ in 0..=self.count() {
            let Some(kind) = self.kind_at(self.position) else {
                break;
            };

            if !is_layout(kind) {
                break;
            }

            self.emit();
        }
    }

    fn skip_layout(&mut self) {
        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if !self.at_line_comment() {
                break;
            }

            self.skip_line_comment();
        }
    }

    fn at_line_comment(&self) -> bool {
        self.kind_at(self.position) == Some(CSSKind::Slash)
            && self.kind_at(self.position + 1) == Some(CSSKind::Slash)
            && self.adjacent(self.position + 1)
    }

    fn skip_line_comment(&mut self) {
        for _ in 0..=self.count() {
            match self.kind_at(self.position) {
                None | Some(CSSKind::Newline) => break,
                Some(_) => self.emit_layout(),
            }
        }
    }

    fn anchor(&mut self) -> Checkpoint {
        self.settle();

        self.events.checkpoint()
    }

    fn open(&mut self, kind: CSSKind) {
        self.settle();
        self.events.start(kind);
    }

    fn settle(&mut self) {
        if self.current().is_none() {
            return;
        }

        self.skip_trivia();
    }

    fn bump(&mut self) {
        self.skip_trivia();
        self.emit();
    }

    fn eat(&mut self, kind: CSSKind) -> bool {
        if !self.at(kind) {
            return false;
        }

        self.bump();

        true
    }

    fn expect(&mut self, kind: CSSKind, failure: SyntaxErrorKind) -> bool {
        if self.eat(kind) {
            return true;
        }

        self.record(failure);

        false
    }

    fn wrap(&mut self, kind: CSSKind) {
        self.open(kind);
        self.emit();
        self.events.finish();
    }

    fn record(&mut self, kind: SyntaxErrorKind) {
        let position = self.significant(self.position).min(self.count());

        let span = self
            .tokens
            .get(position as usize)
            .map_or(Span::EMPTY, Token::span);

        let recorded = self.tree.push_error(SyntaxError { kind, span });

        if !recorded && self.outcome == Structure::Complete {
            self.outcome = Structure::Truncated;
        }
    }

    fn descend(&mut self) -> bool {
        if self.nesting >= NEST_DEPTH_MAX {
            self.outcome = Structure::TooDeep;

            return false;
        }

        self.nesting += 1;

        true
    }

    fn ascend(&mut self) {
        self.nesting -= 1;
    }

    fn consume_through(&mut self, end: usize) {
        self.skip_trivia();

        let before = self.position;

        for _ in 0..CHAIN_DEPTH_MAX {
            let Some(token) = self.tokens.get(self.position as usize) else {
                break;
            };

            if token.end() as usize > end {
                break;
            }

            self.emit();
        }

        if self.position == before {
            self.emit();
        }
    }

    fn run(&mut self) {
        self.events.start(CSSKind::Stylesheet);

        for _ in 0..u32::MAX {
            self.skip_layout();

            if self.current().is_none() {
                break;
            }

            let before = self.position;

            self.item(true);

            if self.position == before {
                self.record(SyntaxErrorKind::UnexpectedToken);
                self.emit();
            }
        }

        self.skip_layout();
        self.events.finish();
    }

    fn item(&mut self, top: bool) {
        match self.current() {
            None => {}
            Some(CSSKind::At) => self.at_statement(top),
            Some(_) => {
                if self.opens_a_declaration() {
                    self.declaration();
                } else {
                    self.rule_set();
                }
            }
        }
    }

    fn opens_a_declaration(&self) -> bool {
        let start = self.significant(self.position);

        if self.kind_at(start) != Some(CSSKind::Identifier) {
            return false;
        }

        if self.kind_at(self.significant(start + 1)) != Some(CSSKind::Colon) {
            return false;
        }

        let mut depth = 0_u32;

        for step in 0..SCAN_STEP_MAX {
            let position = start + step;

            let Some(kind) = self.kind_at(position) else {
                return true;
            };

            match Some(kind) {
                Some(_) if opens_a_group(kind) => depth += 1,
                Some(_) if closes_a_group(kind) => depth = depth.saturating_sub(1),
                Some(CSSKind::BraceOpen) if depth == 0 => return false,
                Some(CSSKind::BraceClose | CSSKind::Semicolon) if depth == 0 => return true,
                Some(_) | None => {}
            }
        }

        true
    }

    fn rule_set(&mut self) {
        self.open(CSSKind::RuleSet);
        self.selectors();

        if self.at(CSSKind::BraceOpen) {
            self.block();
        }

        self.events.finish();
    }

    fn declaration(&mut self) {
        self.open(CSSKind::Declaration);
        self.wrap(CSSKind::PropertyName);
        self.expect(CSSKind::Colon, SyntaxErrorKind::ExpectedColon);
        self.value_list(&DECLARATION_STOP);
        let _ = self.eat(CSSKind::Semicolon);
        self.events.finish();
    }

    fn block(&mut self) {
        if !self.descend() {
            self.bump();

            return;
        }

        self.block_of();
        self.ascend();
    }

    fn block_of(&mut self) {
        self.open(CSSKind::Block);
        self.bump();

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_layout();

            match self.current() {
                None | Some(CSSKind::BraceClose) => break,
                Some(_) => {}
            }

            let before = self.position;

            self.item(false);

            if self.position == before {
                self.record(SyntaxErrorKind::UnexpectedToken);
                self.bump();
            }
        }

        let _ = self.eat(CSSKind::BraceClose);
        self.events.finish();
    }

    fn selectors(&mut self) {
        self.open(CSSKind::Selectors);

        for _ in 0..CHAIN_DEPTH_MAX {
            let before = self.position;

            self.selector();

            if self.position == before {
                break;
            }

            if !self.eat(CSSKind::Comma) {
                break;
            }
        }

        self.events.finish();
    }

    fn selector(&mut self) {
        if !self.descend() {
            self.bump();

            return;
        }

        self.selector_of();
        self.ascend();
    }

    fn selector_of(&mut self) {
        let left = self.anchor();

        if !self.selector_operand() {
            return;
        }

        let mut inner = left;

        for _ in 0..CHAIN_DEPTH_MAX {
            let separated = self.separated();

            let Some(kind) = self.current() else {
                break;
            };

            if is_combinator(kind) {
                self.bump();
                self.selector_tail(left, combinator_node(kind));
                inner = left;

                continue;
            }

            if separated && opens_a_selector(kind) {
                self.selector_tail(left, CSSKind::DescendantSelector);
                inner = left;

                continue;
            }

            if separated {
                break;
            }

            if is_tight_postfix(kind) {
                self.class_suffix(inner);

                continue;
            }

            if is_loose_postfix(kind) {
                self.loose_suffix(left, kind);
                inner = left;

                continue;
            }

            break;
        }
    }

    fn selector_tail(&mut self, left: Checkpoint, kind: CSSKind) {
        let right = self.anchor();
        let _ = self.selector_operand();
        self.tight_suffixes(right);
        self.events.start_at(left, kind);
        self.events.finish();
    }

    fn tight_suffixes(&mut self, checkpoint: Checkpoint) {
        for _ in 0..CHAIN_DEPTH_MAX {
            if self.separated() {
                break;
            }

            if !self.current().is_some_and(is_tight_postfix) {
                break;
            }

            self.class_suffix(checkpoint);
        }
    }

    fn selector_operand(&mut self) -> bool {
        let Some(kind) = self.current() else {
            return false;
        };

        match Some(kind) {
            Some(CSSKind::Ampersand) => self.wrap(CSSKind::NestingSelector),
            Some(CSSKind::Identifier) => self.wrap(CSSKind::TagName),
            Some(CSSKind::Star) => self.wrap(CSSKind::UniversalSelector),
            Some(CSSKind::Text) => self.wrap(CSSKind::StringValue),
            Some(CSSKind::Dot) => {
                let checkpoint = self.anchor();

                self.class_suffix(checkpoint);
            }
            Some(CSSKind::BracketOpen | CSSKind::Colon | CSSKind::ColonColon | CSSKind::Hash) => {
                let checkpoint = self.anchor();

                self.loose_suffix(checkpoint, kind);
            }
            Some(CSSKind::Greater | CSSKind::Pipe | CSSKind::Plus | CSSKind::Tilde) => {
                let checkpoint = self.anchor();

                self.bump();
                self.selector_tail(checkpoint, combinator_node(kind));
            }
            Some(_) | None => return false,
        }

        true
    }

    fn class_suffix(&mut self, checkpoint: Checkpoint) {
        self.bump();
        self.class_name(false);
        self.events.start_at(checkpoint, CSSKind::ClassSelector);
        self.events.finish();
    }

    fn class_name(&mut self, literal: bool) {
        self.open(CSSKind::ClassName);

        for seen in 0..CHAIN_DEPTH_MAX {
            let Some(kind) = self.kind_at(self.position) else {
                break;
            };

            if !matches!(kind, CSSKind::Escape | CSSKind::Identifier) {
                break;
            }

            if seen > 0 && !self.adjacent(self.position) {
                break;
            }

            if literal || kind == CSSKind::Escape {
                self.emit();
            } else {
                self.wrap(CSSKind::IdentifierNode);
            }
        }

        self.events.finish();
    }

    fn loose_suffix(&mut self, checkpoint: Checkpoint, kind: CSSKind) {
        match Some(kind) {
            Some(CSSKind::Hash) => {
                self.bump();
                self.wrap(CSSKind::IdName);
                self.events.start_at(checkpoint, CSSKind::IdSelector);
            }
            Some(CSSKind::Colon) => {
                self.bump();
                self.pseudo_class_tail();

                self.events
                    .start_at(checkpoint, CSSKind::PseudoClassSelector);
            }
            Some(CSSKind::ColonColon) => {
                self.bump();
                self.wrap(CSSKind::TagName);
                self.selector_arguments(false);

                self.events
                    .start_at(checkpoint, CSSKind::PseudoElementSelector);
            }
            Some(_) | None => {
                self.attribute_tail();
                self.events.start_at(checkpoint, CSSKind::AttributeSelector);
            }
        }

        self.events.finish();
    }

    fn pseudo_class_tail(&mut self) {
        let name = self.current_text();
        let literal = SELECTOR_LITERALS.contains(&name);
        let nth = NTH_LITERALS.contains(&name);

        self.class_name(literal);
        self.selector_arguments(nth);
    }

    fn selector_arguments(&mut self, nth: bool) {
        if self.separated() || !self.at(CSSKind::ParenOpen) {
            return;
        }

        if !self.descend() {
            self.bump();

            return;
        }

        if nth {
            self.nth_arguments();
        } else {
            self.selector_arguments_of();
        }

        self.ascend();
    }

    fn selector_arguments_of(&mut self) {
        self.open(CSSKind::Arguments);
        self.bump();

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            match self.current() {
                None | Some(CSSKind::ParenClose) => break,
                Some(CSSKind::Comma) => {
                    self.bump();

                    continue;
                }
                Some(_) => {}
            }

            let before = self.position;

            if self.current().is_some_and(opens_a_selector) {
                self.selector();
            } else {
                self.value();
            }

            if self.position == before {
                self.bump();
            }
        }

        let _ = self.eat(CSSKind::ParenClose);
        self.events.finish();
    }

    fn nth_arguments(&mut self) {
        self.open(CSSKind::Arguments);
        self.bump();

        if self.at(CSSKind::Number) && self.ahead(1) == Some(CSSKind::ParenClose) {
            self.numeric(CSSKind::IntegerValue);
        } else {
            self.nth_notation();
        }

        for _ in 0..CHAIN_DEPTH_MAX {
            match self.current() {
                None | Some(CSSKind::ParenClose) => break,
                Some(CSSKind::Identifier) if self.current_text() == b"of" => {
                    self.bump();
                    self.selector();
                }
                Some(_) => self.bump(),
            }
        }

        let _ = self.eat(CSSKind::ParenClose);
        self.events.finish();
    }

    fn nth_notation(&mut self) {
        match self.current() {
            None | Some(CSSKind::ParenClose) => return,
            Some(_) => {}
        }

        self.open(CSSKind::PlainValue);

        for _ in 0..CHAIN_DEPTH_MAX {
            match self.current() {
                None | Some(CSSKind::ParenClose) => break,
                Some(CSSKind::Identifier) if self.current_text() == b"of" => break,
                Some(_) => self.bump(),
            }
        }

        self.events.finish();
    }

    fn attribute_tail(&mut self) {
        self.bump();
        self.attribute_name();

        if self
            .current()
            .is_some_and(|kind| ATTRIBUTE_OPERATORS.contains(&kind))
        {
            self.bump();
            self.value();
        }

        let _ = self.eat(CSSKind::BracketClose);
    }

    fn attribute_name(&mut self) {
        self.open(CSSKind::AttributeName);

        for _ in 0..CHAIN_DEPTH_MAX {
            match self.current() {
                Some(CSSKind::Identifier | CSSKind::Pipe | CSSKind::Star) => self.bump(),
                _ => break,
            }
        }

        self.events.finish();
    }

    fn value_list(&mut self, stop: &[CSSKind]) {
        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            let Some(kind) = self.current() else {
                break;
            };

            if stop.contains(&kind) {
                break;
            }

            if kind == CSSKind::Comma {
                self.bump();

                continue;
            }

            let before = self.position;

            self.value();

            if self.position == before {
                self.record(SyntaxErrorKind::ExpectedExpression);
                self.bump();
            }
        }
    }

    fn value(&mut self) {
        if !self.descend() {
            self.bump();

            return;
        }

        self.value_of();
        self.ascend();
    }

    fn value_of(&mut self) {
        let checkpoint = self.anchor();

        if !self.value_atom() {
            return;
        }

        for _ in 0..CHAIN_DEPTH_MAX {
            let Some(kind) = self.current() else {
                break;
            };

            if !is_value_operator(kind) {
                break;
            }

            self.bump();
            let _ = self.value_atom();
            self.events.start_at(checkpoint, CSSKind::BinaryExpression);
            self.events.finish();
        }
    }

    fn value_atom(&mut self) -> bool {
        let Some(kind) = self.current() else {
            return false;
        };

        match Some(kind) {
            Some(CSSKind::Bang) => self.important(),
            Some(CSSKind::BracketOpen) => self.grid_value(),
            Some(CSSKind::Float) => self.numeric(CSSKind::FloatValue),
            Some(CSSKind::Hash) => self.color_value(),
            Some(CSSKind::Identifier) => self.plain_or_call(),
            Some(CSSKind::Number) => self.numeric(CSSKind::IntegerValue),
            Some(CSSKind::ParenOpen) => self.parenthesized_value(),
            Some(CSSKind::Text) => self.wrap(CSSKind::StringValue),
            Some(_) | None => return false,
        }

        true
    }

    fn numeric(&mut self, kind: CSSKind) {
        self.open(kind);
        self.bump();

        if self.kind_at(self.position) == Some(CSSKind::Unit) {
            self.wrap(CSSKind::UnitNode);
        }

        self.events.finish();
    }

    fn important(&mut self) {
        self.open(CSSKind::Important);
        self.bump();

        if self.kind_at(self.position) == Some(CSSKind::Identifier)
            && self.text_at(self.position) == b"important"
        {
            self.emit();
        }

        self.events.finish();
    }

    fn color_value(&mut self) {
        self.open(CSSKind::ColorValue);
        self.bump();

        let start = self
            .tokens
            .get(self.position as usize)
            .map_or(self.source.len(), |token| token.offset as usize);

        match hex_end(self.source, start) {
            Some(end) => self.consume_through(end),
            None => self.bump(),
        }

        self.events.finish();
    }

    fn grid_value(&mut self) {
        if !self.descend() {
            self.bump();

            return;
        }

        self.open(CSSKind::GridValue);
        self.bump();
        self.value_list(&[CSSKind::BracketClose]);
        let _ = self.eat(CSSKind::BracketClose);
        self.events.finish();
        self.ascend();
    }

    fn parenthesized_value(&mut self) {
        if !self.descend() {
            self.bump();

            return;
        }

        self.open(CSSKind::ParenthesizedValue);
        self.bump();
        self.value_list(&[CSSKind::ParenClose]);
        let _ = self.eat(CSSKind::ParenClose);
        self.events.finish();
        self.ascend();
    }

    fn plain_or_call(&mut self) {
        let position = self.significant(self.position);
        let start = self.tokens[position as usize].offset as usize;
        let plain = plain_value_end(self.source, start).unwrap_or(0);
        let name = identifier_end(self.source, start).unwrap_or(0);

        if name >= plain && self.source.get(name) == Some(&b'(') {
            self.open(CSSKind::CallExpression);
            self.wrap(CSSKind::FunctionName);
            self.arguments();
            self.events.finish();

            return;
        }

        self.open(CSSKind::PlainValue);
        self.consume_through(plain.max(name));
        self.events.finish();
    }

    fn arguments(&mut self) {
        if !self.descend() {
            self.bump();

            return;
        }

        self.arguments_of();
        self.ascend();
    }

    fn arguments_of(&mut self) {
        self.open(CSSKind::Arguments);
        self.bump();

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            match self.current() {
                None | Some(CSSKind::ParenClose) => break,
                Some(CSSKind::Comma | CSSKind::Semicolon) => {
                    self.bump();

                    continue;
                }
                Some(_) => {}
            }

            let before = self.position;

            self.value();

            if self.position == before {
                self.bump();
            }
        }

        let _ = self.eat(CSSKind::ParenClose);
        self.events.finish();
    }

    fn at_statement(&mut self, top: bool) {
        if !self.descend() {
            self.bump();

            return;
        }

        self.at_statement_of(top);
        self.ascend();
    }

    fn at_statement_of(&mut self, top: bool) {
        let name = self.at_name();

        match name {
            b"charset" => self.charset_statement(),
            b"import" => self.import_statement(),
            b"media" => self.media_statement(),
            b"namespace" => self.namespace_statement(),
            b"supports" => self.supports_statement(),
            _ if names_keyframes(name) => self.keyframes_statement(name == b"keyframes"),
            _ => self.at_rule(top),
        }
    }

    fn at_name(&self) -> &[u8] {
        let position = self.significant(self.position) + 1;

        if self.kind_at(position) != Some(CSSKind::Identifier) {
            return &[];
        }

        self.text_at(position)
    }

    fn at_mark(&mut self) {
        self.bump();
        let _ = self.eat(CSSKind::Identifier);
    }

    fn at_keyword(&mut self) {
        self.open(CSSKind::AtKeyword);
        self.emit();
        let _ = self.eat(CSSKind::Identifier);
        self.events.finish();
    }

    fn charset_statement(&mut self) {
        self.open(CSSKind::CharsetStatement);
        self.at_mark();
        self.value();
        let _ = self.eat(CSSKind::Semicolon);
        self.events.finish();
    }

    fn import_statement(&mut self) {
        self.open(CSSKind::ImportStatement);
        self.at_mark();

        if !self.at(CSSKind::Semicolon) {
            self.value();
        }

        self.query_list(&[CSSKind::Semicolon]);
        let _ = self.eat(CSSKind::Semicolon);
        self.events.finish();
    }

    fn media_statement(&mut self) {
        self.open(CSSKind::MediaStatement);
        self.at_mark();
        self.query_list(&QUERY_STOP);

        if self.at(CSSKind::BraceOpen) {
            self.block();
        } else {
            let _ = self.eat(CSSKind::Semicolon);
        }

        self.events.finish();
    }

    fn namespace_statement(&mut self) {
        self.open(CSSKind::NamespaceStatement);
        self.at_mark();

        if self.at(CSSKind::Identifier) && !self.names_a_call() {
            self.wrap(CSSKind::NamespaceName);
        }

        self.value();
        let _ = self.eat(CSSKind::Semicolon);
        self.events.finish();
    }

    fn names_a_call(&self) -> bool {
        let position = self.significant(self.position);
        let start = self.tokens[position as usize].offset as usize;

        let Some(name) = identifier_end(self.source, start) else {
            return false;
        };

        self.source.get(name) == Some(&b'(')
    }

    fn supports_statement(&mut self) {
        self.open(CSSKind::SupportsStatement);
        self.at_mark();
        self.query();

        if self.at(CSSKind::BraceOpen) {
            self.block();
        } else {
            let _ = self.eat(CSSKind::Semicolon);
        }

        self.events.finish();
    }

    fn keyframes_statement(&mut self, bare: bool) {
        self.open(CSSKind::KeyframesStatement);

        if bare {
            self.at_mark();
        } else {
            self.skip_trivia();
            self.at_keyword();
        }

        if self.at(CSSKind::Identifier) {
            self.wrap(CSSKind::KeyframesName);
        }

        if self.at(CSSKind::BraceOpen) {
            self.keyframe_block_list();
        }

        self.events.finish();
    }

    fn keyframe_block_list(&mut self) {
        if !self.descend() {
            self.bump();

            return;
        }

        self.open(CSSKind::KeyframeBlockList);
        self.bump();

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_layout();

            match self.current() {
                None | Some(CSSKind::BraceClose) => break,
                Some(_) => {}
            }

            let before = self.position;

            self.keyframe_block();

            if self.position == before {
                self.bump();
            }
        }

        let _ = self.eat(CSSKind::BraceClose);
        self.events.finish();
        self.ascend();
    }

    fn keyframe_block(&mut self) {
        self.open(CSSKind::KeyframeBlock);

        match self.current() {
            Some(CSSKind::Identifier) if self.current_text() == b"from" => {
                self.wrap(CSSKind::From);
            }
            Some(CSSKind::Identifier) if self.current_text() == b"to" => self.wrap(CSSKind::To),
            Some(CSSKind::Number) => self.numeric(CSSKind::IntegerValue),
            Some(CSSKind::BraceOpen) | None => {}
            Some(_) => self.bump(),
        }

        if self.at(CSSKind::BraceOpen) {
            self.block();
        }

        self.events.finish();
    }

    fn at_rule(&mut self, top: bool) {
        if !top && self.opens_a_postcss_statement() {
            self.postcss_statement();

            return;
        }

        self.open(CSSKind::AtRule);
        self.at_keyword();
        self.query_list(&QUERY_STOP);

        if self.at(CSSKind::BraceOpen) {
            self.block();
        } else {
            let _ = self.eat(CSSKind::Semicolon);
        }

        self.events.finish();
    }

    fn postcss_statement(&mut self) {
        self.open(CSSKind::PostcssStatement);
        self.at_keyword();
        self.value_list(&BLOCK_STOP);
        let _ = self.eat(CSSKind::Semicolon);
        self.events.finish();
    }

    fn opens_a_postcss_statement(&self) -> bool {
        let mut depth = 0_u32;
        let mut position = self.significant(self.position) + 2;
        let mut carried = false;

        for _ in 0..SCAN_STEP_MAX {
            let Some(kind) = self.kind_at(position) else {
                break;
            };

            position += 1;

            if closes_a_group(kind) {
                depth = depth.saturating_sub(1);

                continue;
            }

            if opens_a_group(kind) {
                if depth == 0 && carried {
                    return true;
                }

                carried = depth == 0;
                depth += 1;

                continue;
            }

            if depth > 0 || is_layout(kind) {
                continue;
            }

            if kind == CSSKind::BraceOpen {
                return false;
            }

            if matches!(kind, CSSKind::BraceClose | CSSKind::Semicolon) {
                break;
            }

            if kind == CSSKind::Comma {
                carried = false;

                continue;
            }

            if kind != CSSKind::Identifier {
                return true;
            }

            let text = self.text_at(position - 1);

            if QUERY_JOINS.contains(&text) || QUERY_PREFIXES.contains(&text) {
                carried = false;

                continue;
            }

            if carried {
                return true;
            }

            carried = true;
        }

        false
    }

    fn query_list(&mut self, stop: &[CSSKind]) {
        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            let Some(kind) = self.current() else {
                break;
            };

            if stop.contains(&kind) {
                break;
            }

            if kind == CSSKind::Comma {
                self.bump();

                continue;
            }

            let before = self.position;

            self.query();

            if self.position == before {
                self.bump();
            }
        }
    }

    fn query(&mut self) {
        if !self.descend() {
            self.bump();

            return;
        }

        self.query_of();
        self.ascend();
    }

    fn query_of(&mut self) {
        let checkpoint = self.anchor();

        self.query_unary();

        for _ in 0..CHAIN_DEPTH_MAX {
            if self.current() != Some(CSSKind::Identifier) {
                break;
            }

            if !QUERY_JOINS.contains(&self.current_text()) {
                break;
            }

            self.bump();
            self.query_unary();
            self.events.start_at(checkpoint, CSSKind::BinaryQuery);
            self.events.finish();
        }
    }

    fn query_unary(&mut self) {
        if self.current() == Some(CSSKind::Identifier)
            && QUERY_PREFIXES.contains(&self.current_text())
        {
            let checkpoint = self.anchor();

            self.bump();
            self.query_atom();
            self.events.start_at(checkpoint, CSSKind::UnaryQuery);
            self.events.finish();

            return;
        }

        self.query_atom();
    }

    fn query_atom(&mut self) {
        match self.current() {
            Some(CSSKind::Identifier) => {
                if self.current_text() == b"selector" && self.ahead(1) == Some(CSSKind::ParenOpen) {
                    self.selector_query();
                } else {
                    self.wrap(CSSKind::KeywordQuery);
                }
            }
            Some(CSSKind::ParenOpen) => {
                if self.opens_a_feature() {
                    self.feature_query();
                } else {
                    self.parenthesized_query();
                }
            }
            _ => {}
        }
    }

    fn opens_a_feature(&self) -> bool {
        self.ahead(1) == Some(CSSKind::Identifier) && self.ahead(2) == Some(CSSKind::Colon)
    }

    fn selector_query(&mut self) {
        self.open(CSSKind::SelectorQuery);
        self.bump();
        self.bump();
        self.selector();
        let _ = self.eat(CSSKind::ParenClose);
        self.events.finish();
    }

    fn feature_query(&mut self) {
        self.open(CSSKind::FeatureQuery);
        self.bump();
        self.wrap(CSSKind::FeatureName);
        let _ = self.eat(CSSKind::Colon);
        self.value_list(&[CSSKind::ParenClose]);
        let _ = self.eat(CSSKind::ParenClose);
        self.events.finish();
    }

    fn parenthesized_query(&mut self) {
        self.open(CSSKind::ParenthesizedQuery);
        self.bump();
        self.query();
        let _ = self.eat(CSSKind::ParenClose);
        self.events.finish();
    }
}

fn names_keyframes(name: &[u8]) -> bool {
    if !name.ends_with(b"keyframes") {
        return false;
    }

    name.iter()
        .all(|byte| byte.is_ascii_lowercase() || *byte == b'-')
}

pub fn build(
    source: &[u8],
    tokens: &[Token],
    raw: &[CSSKind],
    events: &mut Events<CSSKind>,
    tree: &mut Tree<CSSKind>,
) -> Structure {
    assert!(u32::try_from(source.len()).is_ok());
    assert_eq!(tokens.len(), raw.len());

    events.clear();
    tree.clear();

    let mut parser = Parser {
        events,
        nesting: 0,
        outcome: Structure::Complete,
        position: 0,
        raw,
        significant_next: 0,
        source,
        tokens,
        tree,
    };

    parser.significant_next = parser.scan_significant(0);

    parser.run();

    let recorded = parser.outcome;
    let buffered = events.outcome();
    let replayed = replay(events, tree);

    if recorded != Structure::Complete {
        return recorded;
    }

    if buffered != Structure::Complete {
        return buffered;
    }

    replayed
}
