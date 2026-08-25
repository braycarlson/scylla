use crate::bounded::{Span, count_of};
use crate::syntax::javascript::expression::{
    EXPRESSION_DEPTH_MAX,
    Frame,
    POWER_ARROW,
    POWER_BARRIER,
    POWER_SPREAD,
    POWER_TERNARY_LEFT,
    POWER_TERNARY_RIGHT,
    POWER_UNARY,
    POWER_YIELD,
    VALUE_COUNT_MAX,
    Variant,
    closer_of,
    infix_of,
    is_literal,
    is_name,
    is_prefix,
    is_property_name,
    literal_kind,
};
use crate::syntax::javascript::kind::JavaScriptKind;
use crate::syntax::{SyntaxError, SyntaxErrorKind};
use crate::token::Token;
use crate::tree::{Checkpoint, Events, NONE, Structure, Tree, replay};

const BALANCED_SLOT_COUNT: u32 = 1 << 8;
const BALANCED_STACK_MAX: u32 = 1 << 6;
const CHAIN_DEPTH_MAX: u32 = 4_096;
const NEST_DEPTH_MAX: u32 = 128;
const SCAN_STEP_MAX: u32 = 1 << 16;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Step {
    Done,
    Operand,
    Operator,
}

struct Parser<'source, 'run> {
    balanced_ends: [u32; BALANCED_SLOT_COUNT as usize],
    balanced_opens: [u32; BALANCED_SLOT_COUNT as usize],
    events: &'run mut Events<JavaScriptKind>,
    frame_count: u32,
    frames: [Frame; EXPRESSION_DEPTH_MAX as usize],
    nesting: u32,
    outcome: Structure,
    position: u32,
    raw: &'run [JavaScriptKind],
    significant_next: u32,
    source: &'source [u8],
    tokens: &'run [Token],
    tree: &'run mut Tree<JavaScriptKind>,
    value_count: u32,
    values: [Checkpoint; VALUE_COUNT_MAX as usize],
}

const fn is_layout(kind: JavaScriptKind) -> bool {
    matches!(kind, JavaScriptKind::Comment)
}

const fn is_opener(kind: JavaScriptKind) -> bool {
    matches!(
        kind,
        JavaScriptKind::BraceOpen
            | JavaScriptKind::BracketOpen
            | JavaScriptKind::ParenOpen
            | JavaScriptKind::SubstitutionStart
    )
}

const fn is_closer(kind: JavaScriptKind) -> bool {
    matches!(
        kind,
        JavaScriptKind::BraceClose | JavaScriptKind::BracketClose | JavaScriptKind::ParenClose
    )
}

const fn declares(kind: JavaScriptKind) -> bool {
    matches!(
        kind,
        JavaScriptKind::ConstKeyword | JavaScriptKind::LetKeyword | JavaScriptKind::VarKeyword
    )
}

const fn group_kind(variant: Variant) -> JavaScriptKind {
    match variant {
        Variant::Array => JavaScriptKind::Array,
        Variant::Object => JavaScriptKind::Object,
        Variant::Paren => JavaScriptKind::ParenthesizedExpression,
        Variant::Subscript => JavaScriptKind::SubscriptExpression,
        Variant::Substitution => JavaScriptKind::TemplateSubstitution,
        Variant::Argument
        | Variant::Arrow
        | Variant::Binary
        | Variant::Pair
        | Variant::Template
        | Variant::Ternary
        | Variant::Top
        | Variant::Unary => JavaScriptKind::ErrorNode,
    }
}

impl Parser<'_, '_> {
    fn count(&self) -> u32 {
        count_of(self.raw.len())
    }

    fn kind_at(&self, position: u32) -> Option<JavaScriptKind> {
        self.raw.get(position as usize).copied()
    }

    fn significant(&self, from: u32) -> u32 {
        if from == self.position {
            return self.significant_next;
        }

        self.scan_significant(from)
    }

    fn scan_significant(&self, from: u32) -> u32 {
        let mut position = from;

        while let Some(kind) = self.kind_at(position) {
            if !is_layout(kind) {
                break;
            }

            position += 1;
        }

        position
    }

    fn current(&self) -> Option<JavaScriptKind> {
        self.kind_at(self.significant(self.position))
    }

    fn ahead(&self, steps: u32) -> Option<JavaScriptKind> {
        self.kind_at(self.ahead_position(steps))
    }

    fn ahead_position(&self, steps: u32) -> u32 {
        let mut position = self.significant(self.position);

        for _ in 0..steps {
            position = self.significant(position + 1);
        }

        position
    }

    fn at(&self, kind: JavaScriptKind) -> bool {
        self.current() == Some(kind)
    }

    fn text_at(&self, position: u32) -> &[u8] {
        self.tokens
            .get(position as usize)
            .map_or(&[][..], |token| token.text(self.source))
    }

    fn word_at(&self, position: u32, word: &[u8]) -> bool {
        self.kind_at(position) == Some(JavaScriptKind::Identifier) && self.text_at(position) == word
    }

    fn word(&self, word: &[u8]) -> bool {
        self.word_at(self.significant(self.position), word)
    }

    fn starts_line(&self, position: u32) -> bool {
        if position == 0 || position > self.count() {
            return true;
        }

        let mut back = position - 1;

        while back > 0 && is_layout(self.raw[back as usize]) {
            back -= 1;
        }

        let from = self.tokens[back as usize].end() as usize;

        let stop = self
            .tokens
            .get(position as usize)
            .map_or(self.source.len(), |token| token.offset as usize);

        if stop <= from || stop > self.source.len() {
            return false;
        }

        self.source[from..stop].contains(&b'\n')
    }

    fn breaks_line(&self) -> bool {
        self.starts_line(self.significant(self.position))
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

    fn anchor(&mut self) -> Checkpoint {
        self.skip_trivia();

        self.events.checkpoint()
    }

    fn skip_trivia(&mut self) {
        while self.kind_at(self.position).is_some_and(is_layout) {
            self.emit();
        }
    }

    fn bump(&mut self) {
        self.skip_trivia();
        self.emit();
    }

    fn eat(&mut self, kind: JavaScriptKind) -> bool {
        if !self.at(kind) {
            return false;
        }

        self.bump();

        true
    }

    fn eat_word(&mut self, word: &[u8]) -> bool {
        if !self.word(word) {
            return false;
        }

        self.bump();

        true
    }

    fn expect(&mut self, kind: JavaScriptKind, failure: SyntaxErrorKind) -> bool {
        if self.eat(kind) {
            return true;
        }

        self.record(failure);

        false
    }

    fn open(&mut self, kind: JavaScriptKind) {
        self.skip_trivia();
        self.events.start(kind);
    }

    fn wrap(&mut self, kind: JavaScriptKind) {
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

    fn balanced_end(&mut self, from: u32) -> u32 {
        let probe = (from % BALANCED_SLOT_COUNT) as usize;

        if self.balanced_opens[probe] == from {
            return self.balanced_ends[probe];
        }

        let mut depth = 0_u32;
        let mut opens = [0_u32; BALANCED_STACK_MAX as usize];
        let mut position = from;

        for _ in 0..SCAN_STEP_MAX {
            let Some(kind) = self.kind_at(position) else {
                return position;
            };

            if is_opener(kind) {
                if depth < BALANCED_STACK_MAX {
                    opens[depth as usize] = position;
                }

                depth += 1;
            }

            if is_closer(kind) {
                depth -= 1;

                if depth < BALANCED_STACK_MAX {
                    let open = opens[depth as usize];
                    let slot = (open % BALANCED_SLOT_COUNT) as usize;

                    self.balanced_ends[slot] = position + 1;
                    self.balanced_opens[slot] = open;
                }

                if depth == 0 {
                    return position + 1;
                }
            }

            position += 1;
        }

        position
    }

    fn arrow_ahead(&mut self, from: u32) -> bool {
        let end = self.balanced_end(from);
        let after = self.significant(end);

        self.kind_at(after) == Some(JavaScriptKind::Arrow)
    }

    fn assigned_ahead(&mut self, from: u32) -> bool {
        let end = self.balanced_end(from);
        let after = self.significant(end);

        self.kind_at(after) == Some(JavaScriptKind::Equal)
    }

    fn push_frame(&mut self, frame: Frame) -> bool {
        if self.frame_count >= EXPRESSION_DEPTH_MAX {
            self.outcome = Structure::TooDeep;

            return false;
        }

        self.frames[self.frame_count as usize] = frame;
        self.frame_count += 1;

        true
    }

    fn push_value(&mut self, checkpoint: Checkpoint) {
        if self.value_count >= VALUE_COUNT_MAX {
            self.outcome = Structure::TooDeep;

            return;
        }

        self.values[self.value_count as usize] = checkpoint;
        self.value_count += 1;
    }

    fn innermost_group(&self, base: u32) -> u32 {
        let mut index = self.frame_count;

        while index > base {
            index -= 1;

            if self.frames[index as usize].is_group() {
                return index;
            }
        }

        base
    }

    fn reduce_top(&mut self) {
        assert!(self.frame_count > 0);

        self.frame_count -= 1;

        let frame = self.frames[self.frame_count as usize];

        self.events.start_at(frame.checkpoint, frame.kind);
        self.events.finish();
        self.value_count = frame.values;
        self.push_value(frame.checkpoint);
    }

    fn reduce_above(&mut self, base: u32) {
        while self.frame_count > base {
            self.reduce_top();
        }
    }

    fn reduce_for(&mut self, power_left: u8) {
        while self.frame_count > 0 {
            let top = self.frames[self.frame_count as usize - 1];

            if top.power == POWER_BARRIER || top.power < power_left {
                break;
            }

            self.reduce_top();
        }
    }

    fn unary(&mut self, kind: JavaScriptKind, power: u8) -> Step {
        let checkpoint = self.anchor();

        let frame = Frame {
            checkpoint,
            kind,
            power,
            values: self.value_count,
            variant: Variant::Unary,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        self.bump();

        Step::Operand
    }

    fn binary(&mut self, kind: JavaScriptKind, left: u8, right: u8) -> Step {
        self.reduce_for(left);

        if self.value_count == 0 {
            self.bump();

            return Step::Operand;
        }

        let values = self.value_count - 1;

        let frame = Frame {
            checkpoint: self.values[values as usize],
            kind,
            power: right,
            values,
            variant: Variant::Binary,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        self.bump();

        Step::Operand
    }

    fn open_group(&mut self, variant: Variant, checkpoint: Checkpoint) -> Step {
        let opener = self.current().unwrap_or(JavaScriptKind::ParenOpen);
        let bracket = self.anchor();

        self.bump();

        let content = self.anchor();

        let closer = if opener == JavaScriptKind::SubstitutionStart {
            JavaScriptKind::BraceClose
        } else {
            closer_of(opener)
        };

        let frame = Frame {
            bracket,
            checkpoint,
            closer,
            content,
            element: content,
            element_values: self.value_count,
            kind: group_kind(variant),
            values: self.value_count,
            variant,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        Step::Operand
    }

    fn close_group(&mut self, group: u32) {
        self.reduce_above(group + 1);

        let frame = self.frames[group as usize];

        self.frame_count = group;

        if frame.variant == Variant::Argument {
            self.events.start_at(frame.checkpoint, frame.kind);
            self.events
                .start_at(frame.bracket, JavaScriptKind::Arguments);
            self.bump();
            self.events.finish();
        } else {
            if frame.variant == Variant::Paren && frame.elements > 0 {
                self.events
                    .start_at(frame.content, JavaScriptKind::SequenceExpression);
                self.events.finish();
            }

            self.events.start_at(frame.checkpoint, frame.kind);
            self.bump();
        }

        self.events.finish();

        self.value_count = frame.values;
        self.push_value(frame.checkpoint);
    }

    fn expression(&mut self) {
        self.expression_with(true);
    }

    fn expression_single(&mut self) {
        self.expression_with(false);
    }

    fn expression_with(&mut self, sequence: bool) {
        let frames_base = self.frame_count;
        let values_base = self.value_count;
        let checkpoint = self.anchor();

        let frame = Frame {
            checkpoint,
            content: checkpoint,
            element: checkpoint,
            element_values: self.value_count,
            stage: u8::from(sequence),
            values: self.value_count,
            variant: Variant::Top,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return;
        }

        self.machine(frames_base);
        self.reduce_above(frames_base + 1);

        let top = self.frames[frames_base as usize];

        self.frame_count = frames_base;

        if top.elements > 0 {
            self.events
                .start_at(top.checkpoint, JavaScriptKind::SequenceExpression);
            self.events.finish();
        }

        self.value_count = values_base;
    }

    fn machine(&mut self, base: u32) {
        let mut operand = true;

        for _ in 0..u32::MAX {
            let before = (self.position, self.frame_count, self.value_count);
            let step = if operand {
                self.operand_step(base)
            } else {
                self.operator_step(base)
            };

            match step {
                Step::Operand => operand = true,
                Step::Operator => operand = false,
                Step::Done => {
                    if !operand {
                        return;
                    }

                    match self.operator_step(base) {
                        Step::Done => return,
                        Step::Operand => operand = true,
                        Step::Operator => operand = false,
                    }
                }
            }

            if before == (self.position, self.frame_count, self.value_count) {
                return;
            }
        }
    }

    fn operand_step(&mut self, base: u32) -> Step {
        self.skip_trivia();

        let Some(kind) = self.current() else {
            return Step::Done;
        };

        if self.frame_count > 0 {
            let top = self.frames[self.frame_count as usize - 1];

            if top.variant == Variant::Arrow && kind == JavaScriptKind::BraceOpen {
                let checkpoint = self.anchor();

                self.statement_block();
                self.push_value(checkpoint);

                return Step::Operator;
            }
        }

        let group = self.innermost_group(base);
        let frame = self.frames[group as usize];

        if frame.variant == Variant::Template {
            return self.template_piece(group, kind);
        }

        if frame.variant == Variant::Object
            && self.frame_count == group + 1
            && self.value_count == frame.element_values
        {
            return self.object_member(kind);
        }

        self.operand_of(kind, group)
    }

    fn operand_of(&mut self, kind: JavaScriptKind, group: u32) -> Step {
        if kind == JavaScriptKind::DotDotDot {
            return self.unary(JavaScriptKind::SpreadElement, POWER_SPREAD);
        }

        if is_prefix(kind) {
            return self.unary(JavaScriptKind::UnaryExpression, POWER_UNARY);
        }

        if matches!(kind, JavaScriptKind::MinusMinus | JavaScriptKind::PlusPlus) {
            return self.unary(JavaScriptKind::UpdateExpression, POWER_UNARY);
        }

        if kind == JavaScriptKind::AwaitKeyword && !self.starts_expression(1) {
            return self.identifier_operand();
        }

        if kind == JavaScriptKind::AwaitKeyword {
            return self.unary(JavaScriptKind::AwaitExpression, POWER_UNARY);
        }

        if kind == JavaScriptKind::YieldKeyword {
            return self.yield_operand();
        }

        if kind == JavaScriptKind::NewKeyword {
            return self.new_operand();
        }

        if kind == JavaScriptKind::ImportKeyword {
            return self.import_operand();
        }

        if kind == JavaScriptKind::FunctionKeyword
            || (kind == JavaScriptKind::AsyncKeyword
                && self.ahead(1) == Some(JavaScriptKind::FunctionKeyword))
        {
            let checkpoint = self.anchor();

            self.function_expression();
            self.push_value(checkpoint);

            return Step::Operator;
        }

        if kind == JavaScriptKind::ClassKeyword {
            let checkpoint = self.anchor();

            self.class_body_of(JavaScriptKind::Class);
            self.push_value(checkpoint);

            return Step::Operator;
        }

        if kind == JavaScriptKind::JsxTagStart {
            let checkpoint = self.anchor();

            self.jsx();
            self.push_value(checkpoint);

            return Step::Operator;
        }

        self.operand_group(kind, group)
    }

    fn operand_group(&mut self, kind: JavaScriptKind, group: u32) -> Step {
        if self.opens_an_arrow(kind) {
            return self.arrow_head();
        }

        if kind == JavaScriptKind::ParenOpen {
            let checkpoint = self.anchor();

            return self.open_group(Variant::Paren, checkpoint);
        }

        if kind == JavaScriptKind::BracketOpen {
            return self.operand_pattern(Variant::Array);
        }

        if kind == JavaScriptKind::BraceOpen {
            return self.operand_pattern(Variant::Object);
        }

        if kind == JavaScriptKind::TemplateStart {
            return self.open_template(Checkpoint::NONE);
        }

        if kind == JavaScriptKind::PrivateIdentifier {
            let checkpoint = self.anchor();

            self.wrap(JavaScriptKind::PrivatePropertyIdentifier);
            self.push_value(checkpoint);

            return Step::Operator;
        }

        if is_literal(kind) {
            let checkpoint = self.anchor();

            self.wrap(literal_kind(kind));
            self.push_value(checkpoint);

            return Step::Operator;
        }

        if is_name(kind) {
            return self.identifier_operand();
        }

        let _ = group;

        Step::Done
    }

    fn operand_pattern(&mut self, variant: Variant) -> Step {
        if self.assigned_ahead(self.significant(self.position)) {
            let checkpoint = self.anchor();

            self.pattern();
            self.push_value(checkpoint);

            return Step::Operator;
        }

        let checkpoint = self.anchor();

        self.open_group(variant, checkpoint)
    }

    fn identifier_operand(&mut self) -> Step {
        let checkpoint = self.anchor();

        self.wrap(JavaScriptKind::IdentifierNode);
        self.push_value(checkpoint);

        Step::Operator
    }

    fn starts_expression(&self, steps: u32) -> bool {
        let Some(kind) = self.ahead(steps) else {
            return false;
        };

        is_literal(kind)
            || is_name(kind)
            || is_prefix(kind)
            || is_opener(kind)
            || matches!(
                kind,
                JavaScriptKind::AwaitKeyword
                    | JavaScriptKind::ClassKeyword
                    | JavaScriptKind::DotDotDot
                    | JavaScriptKind::FunctionKeyword
                    | JavaScriptKind::ImportKeyword
                    | JavaScriptKind::JsxTagStart
                    | JavaScriptKind::MinusMinus
                    | JavaScriptKind::NewKeyword
                    | JavaScriptKind::PlusPlus
                    | JavaScriptKind::PrivateIdentifier
                    | JavaScriptKind::Slash
                    | JavaScriptKind::TemplateStart
                    | JavaScriptKind::YieldKeyword
            )
    }

    fn yield_operand(&mut self) -> Step {
        let checkpoint = self.anchor();
        let star = self.ahead(1) == Some(JavaScriptKind::Star);
        let steps = u32::from(star) + 1;

        if self.starts_line(self.ahead_position(steps)) || !self.starts_expression(steps) {
            self.open(JavaScriptKind::YieldExpression);
            self.bump();
            let _ = self.eat(JavaScriptKind::Star);
            self.events.finish();
            self.push_value(checkpoint);

            return Step::Operator;
        }

        let frame = Frame {
            checkpoint,
            kind: JavaScriptKind::YieldExpression,
            power: POWER_YIELD,
            values: self.value_count,
            variant: Variant::Unary,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        self.bump();
        let _ = self.eat(JavaScriptKind::Star);

        Step::Operand
    }

    fn new_operand(&mut self) -> Step {
        let checkpoint = self.anchor();

        if self.ahead(1) == Some(JavaScriptKind::Dot) {
            self.open(JavaScriptKind::MetaProperty);
            self.bump();
            self.bump();

            if is_property_name(self.current().unwrap_or(JavaScriptKind::ErrorToken)) {
                self.bump();
            }

            self.events.finish();
            self.push_value(checkpoint);

            return Step::Operator;
        }

        let frame = Frame {
            checkpoint,
            kind: JavaScriptKind::NewExpression,
            power: POWER_UNARY,
            stage: 1,
            values: self.value_count,
            variant: Variant::Unary,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        self.bump();

        Step::Operand
    }

    fn import_operand(&mut self) -> Step {
        let checkpoint = self.anchor();

        if self.ahead(1) == Some(JavaScriptKind::Dot) {
            self.open(JavaScriptKind::MetaProperty);
            self.bump();
            self.bump();

            if is_property_name(self.current().unwrap_or(JavaScriptKind::ErrorToken)) {
                self.bump();
            }

            self.events.finish();
            self.push_value(checkpoint);

            return Step::Operator;
        }

        self.wrap(JavaScriptKind::ImportNode);
        self.push_value(checkpoint);

        Step::Operator
    }

    fn opens_an_arrow(&mut self, kind: JavaScriptKind) -> bool {
        if kind == JavaScriptKind::ParenOpen {
            return self.arrow_ahead(self.significant(self.position));
        }

        if kind == JavaScriptKind::AsyncKeyword && !self.starts_line(self.ahead_position(1)) {
            if self.ahead(1) == Some(JavaScriptKind::ParenOpen) {
                return self.arrow_ahead(self.ahead_position(1));
            }

            if is_name(self.ahead(1).unwrap_or(JavaScriptKind::ErrorToken))
                && self.ahead(2) == Some(JavaScriptKind::Arrow)
            {
                return true;
            }
        }

        is_name(kind) && self.ahead(1) == Some(JavaScriptKind::Arrow)
    }

    fn arrow_head(&mut self) -> Step {
        let checkpoint = self.anchor();

        if self.at(JavaScriptKind::AsyncKeyword) {
            self.bump();
        }

        if self.at(JavaScriptKind::ParenOpen) {
            self.formal_parameters();
        } else {
            self.wrap(JavaScriptKind::IdentifierNode);
        }

        self.push_value(checkpoint);

        Step::Operator
    }

    fn open_template(&mut self, tag: Checkpoint) -> Step {
        let bracket = self.anchor();
        let checkpoint = if tag.is_none() { bracket } else { tag };

        self.bump();

        let frame = Frame {
            bracket,
            checkpoint,
            closer: JavaScriptKind::TemplateEnd,
            content: bracket,
            element: bracket,
            element_values: self.value_count,
            kind: JavaScriptKind::TemplateString,
            stage: u8::from(!tag.is_none()),
            values: self.value_count,
            variant: Variant::Template,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        Step::Operand
    }

    fn template_piece(&mut self, group: u32, kind: JavaScriptKind) -> Step {
        if kind == JavaScriptKind::TemplateChars {
            self.bump();

            return Step::Operand;
        }

        if kind == JavaScriptKind::SubstitutionStart {
            let checkpoint = self.anchor();

            return self.open_group(Variant::Substitution, checkpoint);
        }

        if kind == JavaScriptKind::TemplateEnd {
            self.close_template(group);

            return Step::Operator;
        }

        self.close_template(group);

        Step::Operator
    }

    fn close_template(&mut self, group: u32) {
        self.reduce_above(group + 1);

        let frame = self.frames[group as usize];

        self.frame_count = group;

        if frame.stage == 1 {
            self.events
                .start_at(frame.checkpoint, JavaScriptKind::CallExpression);

            self.events
                .start_at(frame.bracket, JavaScriptKind::TemplateString);

            let _ = self.eat(JavaScriptKind::TemplateEnd);
            self.events.finish();
        } else {
            self.events
                .start_at(frame.checkpoint, JavaScriptKind::TemplateString);

            let _ = self.eat(JavaScriptKind::TemplateEnd);
        }

        self.events.finish();

        self.value_count = frame.values;
        self.push_value(frame.checkpoint);
    }

    fn jsx(&mut self) {
        if self.nesting >= NEST_DEPTH_MAX {
            self.outcome = Structure::TooDeep;
            self.emit();

            return;
        }

        self.nesting += 1;
        self.jsx_element();
        self.nesting -= 1;
    }

    fn jsx_element(&mut self) {
        let checkpoint = self.anchor();

        self.bump();
        self.jsx_element_name();
        self.jsx_attributes();

        if self.eat(JavaScriptKind::JsxTagEndSelf) {
            self.events
                .start_at(checkpoint, JavaScriptKind::JsxSelfClosingElement);
            self.events.finish();

            return;
        }

        self.expect(JavaScriptKind::JsxTagEnd, SyntaxErrorKind::UnexpectedToken);

        self.events
            .start_at(checkpoint, JavaScriptKind::JsxOpeningElement);
        self.events.finish();
        self.jsx_children();
        self.jsx_closing_element();
        self.events.start_at(checkpoint, JavaScriptKind::JsxElement);
        self.events.finish();
    }

    fn jsx_closing_element(&mut self) {
        if !self.at(JavaScriptKind::JsxTagStartClose) {
            self.record(SyntaxErrorKind::UnmatchedBracket);

            return;
        }

        let checkpoint = self.anchor();

        self.bump();
        self.jsx_element_name();
        self.expect(JavaScriptKind::JsxTagEnd, SyntaxErrorKind::UnexpectedToken);

        self.events
            .start_at(checkpoint, JavaScriptKind::JsxClosingElement);
        self.events.finish();
    }

    fn jsx_element_name(&mut self) {
        if !self.at(JavaScriptKind::Identifier) {
            return;
        }

        let checkpoint = self.anchor();

        self.wrap(JavaScriptKind::IdentifierNode);

        if self.at(JavaScriptKind::Colon) {
            self.bump();

            if self.at(JavaScriptKind::Identifier) {
                self.wrap(JavaScriptKind::IdentifierNode);
            }

            self.events
                .start_at(checkpoint, JavaScriptKind::JsxNamespaceName);
            self.events.finish();

            return;
        }

        for _ in 0..CHAIN_DEPTH_MAX {
            if !self.at(JavaScriptKind::Dot) {
                return;
            }

            self.bump();

            if self.at(JavaScriptKind::Identifier) {
                self.wrap(JavaScriptKind::PropertyIdentifier);
            }

            self.events
                .start_at(checkpoint, JavaScriptKind::MemberExpression);
            self.events.finish();
        }
    }

    fn jsx_attributes(&mut self) {
        for _ in 0..CHAIN_DEPTH_MAX {
            match self.current() {
                Some(JavaScriptKind::BraceOpen) => self.jsx_expression(),
                Some(JavaScriptKind::Identifier) => self.jsx_attribute(),
                _ => return,
            }
        }
    }

    fn jsx_attribute(&mut self) {
        let checkpoint = self.anchor();

        self.jsx_attribute_name();

        if self.eat(JavaScriptKind::Equal) {
            self.jsx_attribute_value();
        }

        self.events
            .start_at(checkpoint, JavaScriptKind::JsxAttribute);
        self.events.finish();
    }

    fn jsx_attribute_name(&mut self) {
        if self.ahead(1) != Some(JavaScriptKind::Colon) {
            self.wrap(JavaScriptKind::PropertyIdentifier);

            return;
        }

        let checkpoint = self.anchor();

        self.wrap(JavaScriptKind::IdentifierNode);
        self.bump();

        if self.at(JavaScriptKind::Identifier) {
            self.wrap(JavaScriptKind::IdentifierNode);
        }

        self.events
            .start_at(checkpoint, JavaScriptKind::JsxNamespaceName);
        self.events.finish();
    }

    fn jsx_attribute_value(&mut self) {
        match self.current() {
            Some(JavaScriptKind::BraceOpen) => self.jsx_expression(),
            Some(JavaScriptKind::JsxTagStart) => self.jsx(),
            Some(JavaScriptKind::String) => self.wrap(JavaScriptKind::StringNode),
            _ => self.record(SyntaxErrorKind::ExpectedExpression),
        }
    }

    fn jsx_expression(&mut self) {
        let checkpoint = self.anchor();

        self.bump();

        if !self.at(JavaScriptKind::BraceClose) {
            self.expression();
        }

        self.expect(
            JavaScriptKind::BraceClose,
            SyntaxErrorKind::UnmatchedBracket,
        );

        self.events
            .start_at(checkpoint, JavaScriptKind::JsxExpression);
        self.events.finish();
    }

    fn jsx_children(&mut self) {
        for _ in 0..u32::MAX {
            match self.current() {
                Some(JavaScriptKind::BraceOpen) => self.jsx_expression(),
                Some(JavaScriptKind::JsxChars) => self.wrap(JavaScriptKind::JsxText),
                Some(JavaScriptKind::JsxEntity) => self.bump(),
                Some(JavaScriptKind::JsxTagStart) => self.jsx(),
                _ => return,
            }
        }
    }

    fn operator_step(&mut self, base: u32) -> Step {
        self.skip_trivia();

        let Some(kind) = self.current() else {
            return Step::Done;
        };

        let group = self.innermost_group(base);
        let frame = self.frames[group as usize];

        if frame.variant == Variant::Template {
            return self.template_piece(group, kind);
        }

        if frame.is_bracketed() && kind == frame.closer {
            self.close_group(group);

            return Step::Operator;
        }

        if kind == JavaScriptKind::Comma {
            return self.comma(group);
        }

        if matches!(kind, JavaScriptKind::Dot | JavaScriptKind::QuestionDot) {
            return self.member_trailer(kind);
        }

        if kind == JavaScriptKind::ParenOpen {
            return self.call_trailer();
        }

        if kind == JavaScriptKind::BracketOpen {
            return self.subscript_trailer();
        }

        if kind == JavaScriptKind::TemplateStart {
            return self.tagged_template();
        }

        if matches!(kind, JavaScriptKind::MinusMinus | JavaScriptKind::PlusPlus) {
            return self.postfix_update();
        }

        if kind == JavaScriptKind::Question {
            return self.ternary();
        }

        if kind == JavaScriptKind::Colon {
            return self.ternary_else(base);
        }

        if kind == JavaScriptKind::Arrow {
            return self.arrow_body();
        }

        if let Some((node, left, right)) = infix_of(kind) {
            return self.binary(node, left, right);
        }

        Step::Done
    }

    fn comma(&mut self, group: u32) -> Step {
        let frame = self.frames[group as usize];

        if frame.variant == Variant::Top && frame.stage == 0 {
            return Step::Done;
        }

        if frame.variant == Variant::Substitution {
            return Step::Done;
        }

        self.reduce_above(group + 1);
        self.bump();

        self.frames[group as usize].elements += 1;
        self.frames[group as usize].element = self.anchor();
        self.frames[group as usize].element_values = self.value_count;

        Step::Operand
    }

    fn member_trailer(&mut self, kind: JavaScriptKind) -> Step {
        if self.value_count == 0 {
            return Step::Done;
        }

        if kind == JavaScriptKind::QuestionDot {
            let after = self.ahead(1);

            if after == Some(JavaScriptKind::BracketOpen) {
                self.optional_chain();

                return self.subscript_trailer();
            }

            if after == Some(JavaScriptKind::ParenOpen) {
                self.optional_chain();

                return self.call_trailer();
            }
        }

        let checkpoint = self.values[self.value_count as usize - 1];

        self.events
            .start_at(checkpoint, JavaScriptKind::MemberExpression);

        if kind == JavaScriptKind::QuestionDot {
            self.open(JavaScriptKind::OptionalChain);
            self.bump();
            self.events.finish();
        } else {
            self.bump();
        }

        match self.current().unwrap_or(JavaScriptKind::ErrorToken) {
            JavaScriptKind::PrivateIdentifier => {
                self.wrap(JavaScriptKind::PrivatePropertyIdentifier);
            }
            current if is_property_name(current) => {
                self.wrap(JavaScriptKind::PropertyIdentifier);
            }
            _ => {}
        }

        self.events.finish();

        Step::Operator
    }

    fn optional_chain(&mut self) {
        self.open(JavaScriptKind::OptionalChain);
        self.bump();
        self.events.finish();
    }

    fn call_trailer(&mut self) -> Step {
        if self.value_count == 0 {
            return Step::Done;
        }

        let checkpoint = self.values[self.value_count as usize - 1];
        let mut kind = JavaScriptKind::CallExpression;

        self.value_count -= 1;

        if self.frame_count > 0 {
            let top = self.frames[self.frame_count as usize - 1];

            if top.variant == Variant::Unary
                && top.kind == JavaScriptKind::NewExpression
                && top.stage == 1
                && self.value_count == top.values
            {
                self.frame_count -= 1;
                kind = JavaScriptKind::NewExpression;

                let step = self.open_group(Variant::Argument, top.checkpoint);

                self.frames[self.frame_count as usize - 1].kind = kind;

                return step;
            }
        }

        let step = self.open_group(Variant::Argument, checkpoint);

        self.frames[self.frame_count as usize - 1].kind = kind;

        step
    }

    fn subscript_trailer(&mut self) -> Step {
        if self.value_count == 0 {
            return Step::Done;
        }

        let checkpoint = self.values[self.value_count as usize - 1];

        self.value_count -= 1;

        self.open_group(Variant::Subscript, checkpoint)
    }

    fn tagged_template(&mut self) -> Step {
        if self.value_count == 0 {
            return Step::Done;
        }

        let checkpoint = self.values[self.value_count as usize - 1];

        self.value_count -= 1;

        self.open_template(checkpoint)
    }

    fn postfix_update(&mut self) -> Step {
        if self.value_count == 0 || self.breaks_line() {
            return Step::Done;
        }

        let checkpoint = self.values[self.value_count as usize - 1];

        self.events
            .start_at(checkpoint, JavaScriptKind::UpdateExpression);

        self.bump();
        self.events.finish();

        Step::Operator
    }

    fn ternary(&mut self) -> Step {
        self.reduce_for(POWER_TERNARY_LEFT);

        if self.value_count == 0 {
            return Step::Done;
        }

        let values = self.value_count - 1;

        let frame = Frame {
            checkpoint: self.values[values as usize],
            kind: JavaScriptKind::TernaryExpression,
            power: POWER_TERNARY_RIGHT,
            values,
            variant: Variant::Ternary,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        self.bump();

        Step::Operand
    }

    fn ternary_else(&mut self, base: u32) -> Step {
        let mut index = self.frame_count;

        while index > base {
            index -= 1;

            if self.frames[index as usize].variant == Variant::Ternary
                && self.frames[index as usize].stage == 0
            {
                self.reduce_above(index + 1);
                self.bump();
                self.frames[index as usize].stage = 1;

                return Step::Operand;
            }

            if self.frames[index as usize].is_group() {
                break;
            }
        }

        Step::Done
    }

    fn arrow_body(&mut self) -> Step {
        if self.value_count == 0 {
            return Step::Done;
        }

        let values = self.value_count - 1;

        let frame = Frame {
            checkpoint: self.values[values as usize],
            kind: JavaScriptKind::ArrowFunction,
            power: POWER_ARROW,
            values,
            variant: Variant::Arrow,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        self.bump();

        Step::Operand
    }

    fn object_member(&mut self, kind: JavaScriptKind) -> Step {
        if kind == JavaScriptKind::DotDotDot {
            return self.unary(JavaScriptKind::SpreadElement, POWER_SPREAD);
        }

        if self.method_ahead() {
            let checkpoint = self.anchor();

            self.method_definition();
            self.push_value(checkpoint);

            return Step::Operator;
        }

        if !Self::opens_a_key(kind) {
            return self.operand_of(kind, 0);
        }

        let checkpoint = self.anchor();
        let colon = self.key_ends_at_colon();

        if !colon && is_name(kind) {
            self.wrap(JavaScriptKind::ShorthandPropertyIdentifier);
            self.push_value(checkpoint);

            return Step::Operator;
        }

        self.property_key();

        if !self.at(JavaScriptKind::Colon) {
            self.push_value(checkpoint);

            return Step::Operator;
        }

        let frame = Frame {
            checkpoint,
            kind: JavaScriptKind::Pair,
            power: POWER_BARRIER,
            values: self.value_count,
            variant: Variant::Pair,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        self.bump();

        Step::Operand
    }

    fn opens_a_key(kind: JavaScriptKind) -> bool {
        is_property_name(kind)
            || matches!(
                kind,
                JavaScriptKind::BracketOpen
                    | JavaScriptKind::Number
                    | JavaScriptKind::PrivateIdentifier
                    | JavaScriptKind::String
            )
    }

    fn key_ends_at_colon(&mut self) -> bool {
        let position = self.significant(self.position);

        if self.kind_at(position) == Some(JavaScriptKind::BracketOpen) {
            let end = self.balanced_end(position);
            let after = self.significant(end);

            return self.kind_at(after) == Some(JavaScriptKind::Colon);
        }

        self.ahead(1) == Some(JavaScriptKind::Colon)
    }

    fn method_ahead(&mut self) -> bool {
        let mut position = self.significant(self.position);

        for _ in 0..4 {
            let Some(kind) = self.kind_at(position) else {
                return false;
            };

            if kind == JavaScriptKind::Star {
                position = self.significant(position + 1);

                continue;
            }

            let modifier = kind == JavaScriptKind::AsyncKeyword
                || kind == JavaScriptKind::StaticKeyword
                || self.word_at(position, b"get")
                || self.word_at(position, b"set");

            if !modifier {
                break;
            }

            let after = self.significant(position + 1);

            let Some(next) = self.kind_at(after) else {
                return false;
            };

            if matches!(
                next,
                JavaScriptKind::BraceClose
                    | JavaScriptKind::Colon
                    | JavaScriptKind::Comma
                    | JavaScriptKind::Equal
                    | JavaScriptKind::ParenOpen
                    | JavaScriptKind::Semicolon
            ) {
                break;
            }

            position = after;
        }

        let after = if self.kind_at(position) == Some(JavaScriptKind::BracketOpen) {
            let end = self.balanced_end(position);

            self.significant(end)
        } else {
            self.significant(position + 1)
        };

        self.kind_at(after) == Some(JavaScriptKind::ParenOpen)
            && Self::opens_a_key(self.kind_at(position).unwrap_or(JavaScriptKind::ErrorToken))
    }

    fn property_key(&mut self) {
        let Some(kind) = self.current() else {
            return;
        };

        if kind == JavaScriptKind::BracketOpen {
            self.open(JavaScriptKind::ComputedPropertyName);
            self.bump();
            self.expression_single();
            let _ = self.eat(JavaScriptKind::BracketClose);
            self.events.finish();

            return;
        }

        if kind == JavaScriptKind::String {
            self.wrap(JavaScriptKind::StringNode);

            return;
        }

        if kind == JavaScriptKind::Number {
            self.wrap(JavaScriptKind::NumberNode);

            return;
        }

        if kind == JavaScriptKind::PrivateIdentifier {
            self.wrap(JavaScriptKind::PrivatePropertyIdentifier);

            return;
        }

        if is_property_name(kind) {
            self.wrap(JavaScriptKind::PropertyIdentifier);
        }
    }

    fn method_definition(&mut self) {
        self.open(JavaScriptKind::MethodDefinition);
        self.method_modifiers();
        self.property_key();
        self.formal_parameters();
        self.statement_block();
        self.events.finish();
    }

    fn method_modifiers(&mut self) {
        for _ in 0..4 {
            if self.eat(JavaScriptKind::Star) {
                continue;
            }

            let position = self.significant(self.position);

            let Some(kind) = self.kind_at(position) else {
                return;
            };

            let modifier = kind == JavaScriptKind::AsyncKeyword
                || kind == JavaScriptKind::StaticKeyword
                || self.word_at(position, b"get")
                || self.word_at(position, b"set");

            if !modifier {
                return;
            }

            let after = self.significant(position + 1);

            if matches!(
                self.kind_at(after),
                None | Some(
                    JavaScriptKind::BraceClose
                        | JavaScriptKind::Colon
                        | JavaScriptKind::Comma
                        | JavaScriptKind::Equal
                        | JavaScriptKind::ParenOpen
                        | JavaScriptKind::Semicolon
                )
            ) {
                return;
            }

            self.bump();
        }
    }

    fn formal_parameters(&mut self) {
        self.open(JavaScriptKind::FormalParameters);
        self.expect(JavaScriptKind::ParenOpen, SyntaxErrorKind::UnexpectedToken);

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if self.at(JavaScriptKind::ParenClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.pattern_element();

            if !self.eat(JavaScriptKind::Comma) {
                break;
            }

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(JavaScriptKind::ParenClose);
        self.events.finish();
    }

    fn pattern(&mut self) {
        let Some(kind) = self.current() else {
            return;
        };

        if kind == JavaScriptKind::BracketOpen {
            self.array_pattern();

            return;
        }

        if kind == JavaScriptKind::BraceOpen {
            self.object_pattern();

            return;
        }

        if kind == JavaScriptKind::DotDotDot {
            self.open(JavaScriptKind::RestPattern);
            self.bump();
            self.pattern();
            self.events.finish();

            return;
        }

        if is_name(kind) {
            self.wrap(JavaScriptKind::IdentifierNode);

            return;
        }

        self.expression_single();
    }

    fn pattern_element(&mut self) {
        let checkpoint = self.anchor();

        self.pattern();

        if !self.at(JavaScriptKind::Equal) {
            return;
        }

        self.events
            .start_at(checkpoint, JavaScriptKind::AssignmentPattern);

        self.bump();
        self.expression_single();
        self.events.finish();
    }

    fn array_pattern(&mut self) {
        self.open(JavaScriptKind::ArrayPattern);
        self.bump();

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if self.at(JavaScriptKind::BracketClose) || self.current().is_none() {
                break;
            }

            if self.eat(JavaScriptKind::Comma) {
                continue;
            }

            let before = self.position;

            self.pattern_element();

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(JavaScriptKind::BracketClose);
        self.events.finish();
    }

    fn object_pattern(&mut self) {
        self.open(JavaScriptKind::ObjectPattern);
        self.bump();

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if self.at(JavaScriptKind::BraceClose) || self.current().is_none() {
                break;
            }

            if self.eat(JavaScriptKind::Comma) {
                continue;
            }

            let before = self.position;

            self.object_pattern_member();

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(JavaScriptKind::BraceClose);
        self.events.finish();
    }

    fn object_pattern_member(&mut self) {
        let Some(kind) = self.current() else {
            return;
        };

        if kind == JavaScriptKind::DotDotDot {
            self.open(JavaScriptKind::RestPattern);
            self.bump();
            self.pattern();
            self.events.finish();

            return;
        }

        let checkpoint = self.anchor();

        if self.key_ends_at_colon() || kind == JavaScriptKind::BracketOpen {
            self.open(JavaScriptKind::PairPattern);
            self.property_key();
            self.expect(JavaScriptKind::Colon, SyntaxErrorKind::ExpectedColon);
            self.pattern_element();
            self.events.finish();

            return;
        }

        self.wrap(JavaScriptKind::ShorthandPropertyIdentifierPattern);

        if !self.at(JavaScriptKind::Equal) {
            return;
        }

        self.events
            .start_at(checkpoint, JavaScriptKind::ObjectAssignmentPattern);

        self.bump();
        self.expression_single();
        self.events.finish();
    }

    fn run(&mut self) {
        self.events.start(JavaScriptKind::Program);
        self.statements_until(JavaScriptKind::ErrorToken);
        self.events.finish();
    }

    fn statements_until(&mut self, closer: JavaScriptKind) {
        for _ in 0..u32::MAX {
            self.skip_trivia();

            let Some(kind) = self.current() else {
                return;
            };

            if kind == closer {
                return;
            }

            let before = self.position;

            self.statement();

            if self.position == before {
                self.record(SyntaxErrorKind::UnexpectedToken);
                self.emit();
            }
        }
    }

    fn statement(&mut self) {
        if self.nesting >= NEST_DEPTH_MAX {
            self.outcome = Structure::TooDeep;
            self.emit();

            return;
        }

        self.nesting += 1;
        self.statement_of();
        self.nesting -= 1;
    }

    fn statement_of(&mut self) {
        let held = self.current();
        let kind = held.unwrap_or(JavaScriptKind::ErrorToken);

        match held {
            None => {}
            Some(JavaScriptKind::At) => self.decorated(),
            Some(JavaScriptKind::BraceOpen) => self.statement_block(),
            Some(JavaScriptKind::BreakKeyword) => {
                self.jump_statement(JavaScriptKind::BreakStatement);
            }
            Some(JavaScriptKind::ClassKeyword) => self.class_declaration(),
            Some(JavaScriptKind::ContinueKeyword) => {
                self.jump_statement(JavaScriptKind::ContinueStatement);
            }
            Some(JavaScriptKind::DebuggerKeyword) => self.debugger_statement(),
            Some(JavaScriptKind::DoKeyword) => self.do_statement(),
            Some(JavaScriptKind::ExportKeyword) => self.export_statement(),
            Some(JavaScriptKind::ForKeyword) => self.for_statement(),
            Some(JavaScriptKind::FunctionKeyword) => self.function_declaration(),
            Some(JavaScriptKind::IfKeyword) => self.if_statement(),
            Some(JavaScriptKind::ReturnKeyword) => self.return_statement(),
            Some(JavaScriptKind::Semicolon) => self.wrap(JavaScriptKind::EmptyStatement),
            Some(JavaScriptKind::SwitchKeyword) => self.switch_statement(),
            Some(JavaScriptKind::ThrowKeyword) => self.throw_statement(),
            Some(JavaScriptKind::TryKeyword) => self.try_statement(),
            Some(JavaScriptKind::WhileKeyword) => self.while_statement(),
            Some(JavaScriptKind::WithKeyword) => self.with_statement(),
            Some(JavaScriptKind::ConstKeyword | JavaScriptKind::VarKeyword) => self.declaration(),
            Some(JavaScriptKind::AsyncKeyword)
                if self.ahead(1) == Some(JavaScriptKind::FunctionKeyword)
                    && !self.starts_line(self.ahead_position(1)) =>
            {
                self.function_declaration();
            }
            Some(JavaScriptKind::LetKeyword) if self.opens_a_binding() => self.declaration(),
            Some(JavaScriptKind::ImportKeyword)
                if !matches!(
                    self.ahead(1),
                    Some(JavaScriptKind::Dot | JavaScriptKind::ParenOpen)
                ) =>
            {
                self.import_statement();
            }
            Some(_) if is_name(kind) && self.ahead(1) == Some(JavaScriptKind::Colon) => {
                self.labeled_statement();
            }
            Some(_) => self.expression_statement(),
        }
    }

    fn opens_a_binding(&self) -> bool {
        let Some(kind) = self.ahead(1) else {
            return false;
        };

        is_name(kind)
            || matches!(
                kind,
                JavaScriptKind::BraceOpen | JavaScriptKind::BracketOpen
            )
    }

    fn expression_statement(&mut self) {
        self.open(JavaScriptKind::ExpressionStatement);
        self.expression();
        let _ = self.eat(JavaScriptKind::Semicolon);
        self.events.finish();
    }

    fn statement_block(&mut self) {
        self.open(JavaScriptKind::StatementBlock);
        self.expect(JavaScriptKind::BraceOpen, SyntaxErrorKind::UnexpectedToken);
        self.statements_until(JavaScriptKind::BraceClose);
        let _ = self.eat(JavaScriptKind::BraceClose);
        self.events.finish();
    }

    fn declaration(&mut self) {
        let lexical = !self.at(JavaScriptKind::VarKeyword);

        let kind = if lexical {
            JavaScriptKind::LexicalDeclaration
        } else {
            JavaScriptKind::VariableDeclaration
        };

        self.open(kind);
        self.bump();

        for _ in 0..CHAIN_DEPTH_MAX {
            let before = self.position;

            self.variable_declarator();

            if !self.eat(JavaScriptKind::Comma) {
                break;
            }

            if self.position == before {
                break;
            }
        }

        let _ = self.eat(JavaScriptKind::Semicolon);
        self.events.finish();
    }

    fn variable_declarator(&mut self) {
        self.open(JavaScriptKind::VariableDeclarator);
        self.pattern();

        if self.eat(JavaScriptKind::Equal) {
            self.expression_single();
        }

        self.events.finish();
    }

    fn function_declaration(&mut self) {
        let steps = u32::from(self.at(JavaScriptKind::AsyncKeyword));
        let generator = self.ahead(steps + 1) == Some(JavaScriptKind::Star);

        let kind = if generator {
            JavaScriptKind::GeneratorFunctionDeclaration
        } else {
            JavaScriptKind::FunctionDeclaration
        };

        self.open(kind);
        self.function_body();
        self.events.finish();
    }

    fn function_expression(&mut self) {
        let steps = u32::from(self.at(JavaScriptKind::AsyncKeyword));
        let generator = self.ahead(steps + 1) == Some(JavaScriptKind::Star);

        let kind = if generator {
            JavaScriptKind::GeneratorFunction
        } else {
            JavaScriptKind::FunctionExpression
        };

        self.open(kind);
        self.function_body();
        self.events.finish();
    }

    fn function_body(&mut self) {
        let _ = self.eat(JavaScriptKind::AsyncKeyword);

        self.expect(
            JavaScriptKind::FunctionKeyword,
            SyntaxErrorKind::UnexpectedToken,
        );

        let _ = self.eat(JavaScriptKind::Star);

        if is_name(self.current().unwrap_or(JavaScriptKind::ErrorToken)) {
            self.wrap(JavaScriptKind::IdentifierNode);
        }

        self.formal_parameters();
        self.statement_block();
    }

    fn decorated(&mut self) {
        for _ in 0..CHAIN_DEPTH_MAX {
            if !self.at(JavaScriptKind::At) {
                break;
            }

            self.open(JavaScriptKind::Decorator);
            self.bump();
            self.expression_single();
            self.events.finish();
            self.skip_trivia();
        }

        self.statement();
    }

    fn class_declaration(&mut self) {
        self.class_body_of(JavaScriptKind::ClassDeclaration);
    }

    fn class_body_of(&mut self, kind: JavaScriptKind) {
        self.open(kind);

        self.expect(
            JavaScriptKind::ClassKeyword,
            SyntaxErrorKind::UnexpectedToken,
        );

        if is_name(self.current().unwrap_or(JavaScriptKind::ErrorToken)) {
            self.wrap(JavaScriptKind::IdentifierNode);
        }

        if self.at(JavaScriptKind::ExtendsKeyword) {
            self.open(JavaScriptKind::ClassHeritage);
            self.bump();
            self.expression_single();
            self.events.finish();
        }

        self.class_body();
        self.events.finish();
    }

    fn class_body(&mut self) {
        self.open(JavaScriptKind::ClassBody);
        self.expect(JavaScriptKind::BraceOpen, SyntaxErrorKind::UnexpectedToken);

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if self.at(JavaScriptKind::BraceClose) || self.current().is_none() {
                break;
            }

            if self.eat(JavaScriptKind::Semicolon) {
                continue;
            }

            let before = self.position;

            self.class_member();

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(JavaScriptKind::BraceClose);
        self.events.finish();
    }

    fn class_member(&mut self) {
        let checkpoint = self.anchor();

        self.member_decorators();

        if self.at(JavaScriptKind::StaticKeyword)
            && self.ahead(1) == Some(JavaScriptKind::BraceOpen)
        {
            self.open(JavaScriptKind::ClassStaticBlock);
            self.bump();
            self.statement_block();
            self.events.finish();

            return;
        }

        if self.method_ahead() {
            self.method_modifiers();
            self.property_key();
            self.formal_parameters();
            self.statement_block();

            self.events
                .start_at(checkpoint, JavaScriptKind::MethodDefinition);
            self.events.finish();

            return;
        }

        self.method_modifiers();
        self.property_key();

        if self.eat(JavaScriptKind::Equal) {
            self.expression_single();
        }

        self.events
            .start_at(checkpoint, JavaScriptKind::FieldDefinition);
        self.events.finish();
        let _ = self.eat(JavaScriptKind::Semicolon);
    }

    fn member_decorators(&mut self) {
        for _ in 0..CHAIN_DEPTH_MAX {
            if !self.at(JavaScriptKind::At) {
                break;
            }

            self.open(JavaScriptKind::Decorator);
            self.bump();
            self.expression_single();
            self.events.finish();
            self.skip_trivia();
        }
    }

    fn parenthesized(&mut self) {
        self.open(JavaScriptKind::ParenthesizedExpression);
        self.expect(JavaScriptKind::ParenOpen, SyntaxErrorKind::UnexpectedToken);
        self.expression();
        let _ = self.eat(JavaScriptKind::ParenClose);
        self.events.finish();
    }

    fn if_statement(&mut self) {
        self.open(JavaScriptKind::IfStatement);
        self.bump();
        self.parenthesized();
        self.statement();

        if self.at(JavaScriptKind::ElseKeyword) {
            self.open(JavaScriptKind::ElseClause);
            self.bump();
            self.statement();
            self.events.finish();
        }

        self.events.finish();
    }

    fn while_statement(&mut self) {
        self.open(JavaScriptKind::WhileStatement);
        self.bump();
        self.parenthesized();
        self.statement();
        self.events.finish();
    }

    fn with_statement(&mut self) {
        self.open(JavaScriptKind::WithStatement);
        self.bump();
        self.parenthesized();
        self.statement();
        self.events.finish();
    }

    fn do_statement(&mut self) {
        self.open(JavaScriptKind::DoStatement);
        self.bump();
        self.statement();

        self.expect(
            JavaScriptKind::WhileKeyword,
            SyntaxErrorKind::UnexpectedToken,
        );

        self.parenthesized();
        let _ = self.eat(JavaScriptKind::Semicolon);
        self.events.finish();
    }

    fn iterates(&self) -> bool {
        let mut position = self.ahead_position(1);
        let mut depth = 0_u32;

        if self.kind_at(position) == Some(JavaScriptKind::AwaitKeyword) {
            position = self.significant(position + 1);
        }

        for _ in 0..SCAN_STEP_MAX {
            let Some(kind) = self.kind_at(position) else {
                return false;
            };

            if is_opener(kind) {
                depth += 1;
            }

            if is_closer(kind) {
                if depth <= 1 {
                    return false;
                }

                depth -= 1;
            }

            if depth == 1 && matches!(kind, JavaScriptKind::InKeyword | JavaScriptKind::OfKeyword) {
                return true;
            }

            if depth == 1 && kind == JavaScriptKind::Semicolon {
                return false;
            }

            position += 1;
        }

        false
    }

    fn for_statement(&mut self) {
        if self.iterates() {
            self.for_in_statement();

            return;
        }

        self.open(JavaScriptKind::ForStatement);
        self.bump();
        self.expect(JavaScriptKind::ParenOpen, SyntaxErrorKind::UnexpectedToken);

        if self.at(JavaScriptKind::Semicolon) {
            self.wrap(JavaScriptKind::EmptyStatement);
        } else if declares(self.current().unwrap_or(JavaScriptKind::ErrorToken)) {
            self.declaration();
        } else {
            self.expression();
            let _ = self.eat(JavaScriptKind::Semicolon);
        }

        if self.at(JavaScriptKind::Semicolon) {
            self.wrap(JavaScriptKind::EmptyStatement);
        } else {
            self.expression();
            let _ = self.eat(JavaScriptKind::Semicolon);
        }

        if !self.at(JavaScriptKind::ParenClose) {
            self.expression();
        }

        let _ = self.eat(JavaScriptKind::ParenClose);
        self.statement();
        self.events.finish();
    }

    fn for_in_statement(&mut self) {
        self.open(JavaScriptKind::ForInStatement);
        self.bump();
        let _ = self.eat(JavaScriptKind::AwaitKeyword);
        self.expect(JavaScriptKind::ParenOpen, SyntaxErrorKind::UnexpectedToken);

        if declares(self.current().unwrap_or(JavaScriptKind::ErrorToken)) {
            self.bump();
        }

        self.pattern();

        if !self.eat(JavaScriptKind::InKeyword) {
            let _ = self.eat(JavaScriptKind::OfKeyword);
        }

        self.expression();
        let _ = self.eat(JavaScriptKind::ParenClose);
        self.statement();
        self.events.finish();
    }

    fn switch_statement(&mut self) {
        self.open(JavaScriptKind::SwitchStatement);
        self.bump();
        self.parenthesized();
        self.switch_body();
        self.events.finish();
    }

    fn switch_body(&mut self) {
        self.open(JavaScriptKind::SwitchBody);
        self.expect(JavaScriptKind::BraceOpen, SyntaxErrorKind::UnexpectedToken);

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            let Some(kind) = self.current() else {
                break;
            };

            if kind == JavaScriptKind::BraceClose {
                break;
            }

            let before = self.position;

            if kind == JavaScriptKind::CaseKeyword {
                self.switch_case(JavaScriptKind::SwitchCase);
            } else if kind == JavaScriptKind::DefaultKeyword {
                self.switch_case(JavaScriptKind::SwitchDefault);
            } else {
                self.statement();
            }

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(JavaScriptKind::BraceClose);
        self.events.finish();
    }

    fn switch_case(&mut self, kind: JavaScriptKind) {
        self.open(kind);
        self.bump();

        if kind == JavaScriptKind::SwitchCase {
            self.expression();
        }

        self.expect(JavaScriptKind::Colon, SyntaxErrorKind::ExpectedColon);

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            let Some(held) = self.current() else {
                break;
            };

            if matches!(
                held,
                JavaScriptKind::BraceClose
                    | JavaScriptKind::CaseKeyword
                    | JavaScriptKind::DefaultKeyword
            ) {
                break;
            }

            let before = self.position;

            self.statement();

            if self.position == before {
                self.emit();
            }
        }

        self.events.finish();
    }

    fn try_statement(&mut self) {
        self.open(JavaScriptKind::TryStatement);
        self.bump();
        self.statement_block();

        if self.at(JavaScriptKind::CatchKeyword) {
            self.open(JavaScriptKind::CatchClause);
            self.bump();

            if self.eat(JavaScriptKind::ParenOpen) {
                self.pattern();
                let _ = self.eat(JavaScriptKind::ParenClose);
            }

            self.statement_block();
            self.events.finish();
        }

        if self.at(JavaScriptKind::FinallyKeyword) {
            self.open(JavaScriptKind::FinallyClause);
            self.bump();
            self.statement_block();
            self.events.finish();
        }

        self.events.finish();
    }

    fn return_statement(&mut self) {
        self.open(JavaScriptKind::ReturnStatement);
        self.bump();

        if !self.breaks_line() && self.starts_expression(0) {
            self.expression();
        }

        let _ = self.eat(JavaScriptKind::Semicolon);
        self.events.finish();
    }

    fn throw_statement(&mut self) {
        self.open(JavaScriptKind::ThrowStatement);
        self.bump();
        self.expression();
        let _ = self.eat(JavaScriptKind::Semicolon);
        self.events.finish();
    }

    fn jump_statement(&mut self, kind: JavaScriptKind) {
        self.open(kind);
        self.bump();

        if !self.breaks_line() && is_name(self.current().unwrap_or(JavaScriptKind::ErrorToken)) {
            self.wrap(JavaScriptKind::StatementIdentifier);
        }

        let _ = self.eat(JavaScriptKind::Semicolon);
        self.events.finish();
    }

    fn debugger_statement(&mut self) {
        self.open(JavaScriptKind::DebuggerStatement);
        self.bump();
        let _ = self.eat(JavaScriptKind::Semicolon);
        self.events.finish();
    }

    fn labeled_statement(&mut self) {
        self.open(JavaScriptKind::LabeledStatement);
        self.wrap(JavaScriptKind::StatementIdentifier);
        self.expect(JavaScriptKind::Colon, SyntaxErrorKind::ExpectedColon);
        self.statement();
        self.events.finish();
    }

    fn import_statement(&mut self) {
        self.open(JavaScriptKind::ImportStatement);
        self.bump();

        if self.at(JavaScriptKind::String) {
            self.wrap(JavaScriptKind::StringNode);
        } else {
            self.import_clause();
            let _ = self.eat_word(b"from");

            if self.at(JavaScriptKind::String) {
                self.wrap(JavaScriptKind::StringNode);
            }
        }

        self.import_attribute();

        let _ = self.eat(JavaScriptKind::Semicolon);
        self.events.finish();
    }

    fn import_attribute(&mut self) {
        if !self.at(JavaScriptKind::WithKeyword) || self.ahead(1) != Some(JavaScriptKind::BraceOpen)
        {
            return;
        }

        self.open(JavaScriptKind::ImportAttribute);
        self.bump();
        self.expression_single();
        self.events.finish();
    }

    fn import_clause(&mut self) {
        self.open(JavaScriptKind::ImportClause);

        if self.at(JavaScriptKind::Star) {
            self.namespace_import(JavaScriptKind::NamespaceImport);
        } else if self.at(JavaScriptKind::BraceOpen) {
            self.named_imports();
        } else {
            if is_name(self.current().unwrap_or(JavaScriptKind::ErrorToken)) {
                self.wrap(JavaScriptKind::IdentifierNode);
            }

            if self.eat(JavaScriptKind::Comma) {
                if self.at(JavaScriptKind::Star) {
                    self.namespace_import(JavaScriptKind::NamespaceImport);
                } else {
                    self.named_imports();
                }
            }
        }

        self.events.finish();
    }

    fn namespace_import(&mut self, kind: JavaScriptKind) {
        self.open(kind);
        self.bump();
        let _ = self.eat_word(b"as");

        if is_name(self.current().unwrap_or(JavaScriptKind::ErrorToken)) {
            self.wrap(JavaScriptKind::IdentifierNode);
        }

        self.events.finish();
    }

    fn named_imports(&mut self) {
        self.specifier_list(
            JavaScriptKind::NamedImports,
            JavaScriptKind::ImportSpecifier,
        );
    }

    fn specifier_list(&mut self, list: JavaScriptKind, item: JavaScriptKind) {
        self.open(list);
        self.expect(JavaScriptKind::BraceOpen, SyntaxErrorKind::UnexpectedToken);

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if self.at(JavaScriptKind::BraceClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.open(item);
            self.specifier_name();

            if self.eat_word(b"as") {
                self.specifier_name();
            }

            self.events.finish();

            if !self.eat(JavaScriptKind::Comma) {
                break;
            }

            if self.position == before {
                break;
            }
        }

        let _ = self.eat(JavaScriptKind::BraceClose);
        self.events.finish();
    }

    fn specifier_name(&mut self) {
        let Some(kind) = self.current() else {
            return;
        };

        if kind == JavaScriptKind::String {
            self.wrap(JavaScriptKind::StringNode);

            return;
        }

        if is_property_name(kind) {
            self.wrap(JavaScriptKind::IdentifierNode);
        }
    }

    fn export_statement(&mut self) {
        self.open(JavaScriptKind::ExportStatement);
        self.bump();

        if self.at(JavaScriptKind::Star) {
            if self.word_at(self.ahead_position(1), b"as") {
                self.namespace_import(JavaScriptKind::NamespaceExport);
            } else {
                self.bump();
            }

            let _ = self.eat_word(b"from");

            if self.at(JavaScriptKind::String) {
                self.wrap(JavaScriptKind::StringNode);
            }
        } else if self.at(JavaScriptKind::BraceOpen) {
            self.specifier_list(
                JavaScriptKind::ExportClause,
                JavaScriptKind::ExportSpecifier,
            );

            let _ = self.eat_word(b"from");

            if self.at(JavaScriptKind::String) {
                self.wrap(JavaScriptKind::StringNode);
            }
        } else if self.at(JavaScriptKind::DefaultKeyword) {
            self.bump();
            self.export_default();
        } else {
            self.statement();
        }

        let _ = self.eat(JavaScriptKind::Semicolon);
        self.events.finish();
    }

    fn export_default(&mut self) {
        let kind = self.current().unwrap_or(JavaScriptKind::ErrorToken);

        if kind == JavaScriptKind::FunctionKeyword
            || (kind == JavaScriptKind::AsyncKeyword
                && self.ahead(1) == Some(JavaScriptKind::FunctionKeyword))
        {
            if self.names_a_function() {
                self.function_declaration();
            } else {
                self.function_expression();
            }

            return;
        }

        if kind == JavaScriptKind::ClassKeyword {
            let held = if is_name(self.ahead(1).unwrap_or(JavaScriptKind::ErrorToken)) {
                JavaScriptKind::ClassDeclaration
            } else {
                JavaScriptKind::Class
            };

            self.class_body_of(held);

            return;
        }

        self.expression();
    }

    fn names_a_function(&self) -> bool {
        let steps = u32::from(self.at(JavaScriptKind::AsyncKeyword));
        let generator = self.ahead(steps + 1) == Some(JavaScriptKind::Star);
        let at = steps + 1 + u32::from(generator);

        is_name(self.ahead(at).unwrap_or(JavaScriptKind::ErrorToken))
    }
}

pub fn build(
    source: &[u8],
    tokens: &[Token],
    raw: &[JavaScriptKind],
    events: &mut Events<JavaScriptKind>,
    tree: &mut Tree<JavaScriptKind>,
) -> Structure {
    assert!(u32::try_from(source.len()).is_ok());
    assert_eq!(tokens.len(), raw.len());

    events.clear();
    tree.clear();

    let mut parser = Parser {
        balanced_ends: [0; BALANCED_SLOT_COUNT as usize],
        balanced_opens: [NONE; BALANCED_SLOT_COUNT as usize],
        events,
        frame_count: 0,
        frames: [Frame::EMPTY; EXPRESSION_DEPTH_MAX as usize],
        nesting: 0,
        outcome: Structure::Complete,
        position: 0,
        raw,
        significant_next: 0,
        source,
        tokens,
        tree,
        value_count: 0,
        values: [Checkpoint::NONE; VALUE_COUNT_MAX as usize],
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
