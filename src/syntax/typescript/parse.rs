use crate::bounded::{Span, count_of};
use crate::syntax::typescript::dialect::Dialect;
use crate::syntax::typescript::expression::{
    EXPRESSION_DEPTH_MAX,
    Frame,
    POWER_ARROW,
    POWER_ASSIGN_RIGHT,
    POWER_BARRIER,
    POWER_RELATIONAL_LEFT,
    POWER_SHIFT_LEFT,
    POWER_SHIFT_RIGHT,
    POWER_SPREAD,
    POWER_TERNARY_LEFT,
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
use crate::syntax::typescript::kind::TypeScriptKind;
use crate::syntax::{SyntaxError, SyntaxErrorKind};
use crate::token::Token;
use crate::tree::{Checkpoint, Events, NONE, Structure, Tree, replay};

const BALANCED_SLOT_COUNT: u32 = 1 << 8;
const BALANCED_STACK_MAX: u32 = 1 << 6;
const NEST_DEPTH_MAX: u32 = 128;
const NONE_POSITION: u32 = u32::MAX;
const SCAN_STEP_MAX: u32 = 1 << 16;
const TYPE_MODIFIER_MAX: u32 = 3;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Step {
    Done,
    Operand,
    Operator,
}

struct Parser<'source, 'run> {
    balanced_ends: [u32; BALANCED_SLOT_COUNT as usize],
    balanced_opens: [u32; BALANCED_SLOT_COUNT as usize],
    dialect: Dialect,
    events: &'run mut Events<TypeScriptKind>,
    frame_count: u32,
    frames: [Frame; EXPRESSION_DEPTH_MAX as usize],
    nesting: u32,
    outcome: Structure,
    plain_failure: core::cell::Cell<u32>,
    position: u32,
    raw: &'run [TypeScriptKind],
    returning: bool,
    significant_next: u32,
    source: &'source [u8],
    tokens: &'run [Token],
    tree: &'run mut Tree<TypeScriptKind>,
    value_count: u32,
    values: [Checkpoint; VALUE_COUNT_MAX as usize],
}

const fn is_layout(kind: TypeScriptKind) -> bool {
    matches!(kind, TypeScriptKind::Comment)
}

const fn is_opener(kind: TypeScriptKind) -> bool {
    matches!(
        kind,
        TypeScriptKind::BraceOpen
            | TypeScriptKind::BracketOpen
            | TypeScriptKind::ParenOpen
            | TypeScriptKind::SubstitutionStart
    )
}

const fn is_closer(kind: TypeScriptKind) -> bool {
    matches!(
        kind,
        TypeScriptKind::BraceClose | TypeScriptKind::BracketClose | TypeScriptKind::ParenClose
    )
}

const PREDEFINED: [&[u8]; 9] = [
    b"any",
    b"boolean",
    b"never",
    b"number",
    b"object",
    b"string",
    b"symbol",
    b"unknown",
    b"void",
];

fn predefined_of(text: &[u8]) -> bool {
    PREDEFINED.contains(&text)
}

const fn is_type_token(kind: TypeScriptKind) -> bool {
    matches!(
        kind,
        TypeScriptKind::Ampersand
            | TypeScriptKind::Bar
            | TypeScriptKind::Colon
            | TypeScriptKind::Comma
            | TypeScriptKind::Comment
            | TypeScriptKind::Dot
            | TypeScriptKind::DotDotDot
            | TypeScriptKind::ExtendsKeyword
            | TypeScriptKind::FalseKeyword
            | TypeScriptKind::Identifier
            | TypeScriptKind::ImportKeyword
            | TypeScriptKind::Minus
            | TypeScriptKind::NewKeyword
            | TypeScriptKind::NullKeyword
            | TypeScriptKind::Number
            | TypeScriptKind::Question
            | TypeScriptKind::Star
            | TypeScriptKind::String
            | TypeScriptKind::TemplateChars
            | TypeScriptKind::TemplateEnd
            | TypeScriptKind::TemplateStart
            | TypeScriptKind::ThisKeyword
            | TypeScriptKind::TrueKeyword
            | TypeScriptKind::TypeofKeyword
            | TypeScriptKind::UndefinedKeyword
            | TypeScriptKind::VoidKeyword
    )
}

const fn is_literal_type(kind: TypeScriptKind) -> bool {
    matches!(
        kind,
        TypeScriptKind::FalseKeyword
            | TypeScriptKind::NullKeyword
            | TypeScriptKind::Number
            | TypeScriptKind::String
            | TypeScriptKind::TrueKeyword
            | TypeScriptKind::UndefinedKeyword
    )
}

const fn declares(kind: TypeScriptKind) -> bool {
    matches!(
        kind,
        TypeScriptKind::ConstKeyword | TypeScriptKind::LetKeyword | TypeScriptKind::VarKeyword
    )
}

const fn group_kind(variant: Variant) -> TypeScriptKind {
    match variant {
        Variant::Array => TypeScriptKind::Array,
        Variant::Object => TypeScriptKind::Object,
        Variant::Paren => TypeScriptKind::ParenthesizedExpression,
        Variant::Subscript => TypeScriptKind::SubscriptExpression,
        Variant::Substitution => TypeScriptKind::TemplateSubstitution,
        Variant::Argument
        | Variant::Arrow
        | Variant::Binary
        | Variant::Pair
        | Variant::Template
        | Variant::Ternary
        | Variant::Top
        | Variant::Unary => TypeScriptKind::ErrorNode,
    }
}

impl Parser<'_, '_> {
    fn count(&self) -> u32 {
        count_of(self.raw.len())
    }

    fn steps(&self) -> u32 {
        self.count() + 1
    }

    fn kind_at(&self, position: u32) -> Option<TypeScriptKind> {
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

    fn current(&self) -> Option<TypeScriptKind> {
        self.kind_at(self.significant(self.position))
    }

    fn ahead(&self, steps: u32) -> Option<TypeScriptKind> {
        self.kind_at(self.ahead_position(steps))
    }

    fn ahead_position(&self, steps: u32) -> u32 {
        let mut position = self.significant(self.position);

        for _ in 0..steps {
            position = self.significant(position + 1);
        }

        position
    }

    fn at(&self, kind: TypeScriptKind) -> bool {
        self.current() == Some(kind)
    }

    fn text_at(&self, position: u32) -> &[u8] {
        self.tokens
            .get(position as usize)
            .map_or(&[][..], |token| token.text(self.source))
    }

    fn word_at(&self, position: u32, word: &[u8]) -> bool {
        self.kind_at(position) == Some(TypeScriptKind::Identifier) && self.text_at(position) == word
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

    fn eat(&mut self, kind: TypeScriptKind) -> bool {
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

    fn expect(&mut self, kind: TypeScriptKind, failure: SyntaxErrorKind) -> bool {
        if self.eat(kind) {
            return true;
        }

        self.record(failure);

        false
    }

    fn open(&mut self, kind: TypeScriptKind) {
        self.skip_trivia();
        self.events.start(kind);
    }

    fn wrap(&mut self, kind: TypeScriptKind) {
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

    fn arrow_follows(&mut self, from: u32) -> bool {
        let end = self.balanced_end(from);
        let after = self.significant(end);

        if self.kind_at(after) != Some(TypeScriptKind::Arrow) {
            return false;
        }

        let mut depth = 0_u32;

        for position in after + 1..(after + 1).saturating_add(SCAN_STEP_MAX) {
            let Some(kind) = self.kind_at(position) else {
                return false;
            };

            if is_opener(kind) {
                depth += 1;

                continue;
            }

            if is_closer(kind) {
                if depth == 0 {
                    return false;
                }

                depth -= 1;

                continue;
            }

            if depth > 0 {
                continue;
            }

            if kind == TypeScriptKind::Arrow {
                return true;
            }

            if matches!(kind, TypeScriptKind::Comma | TypeScriptKind::Semicolon) {
                return false;
            }
        }

        false
    }

    fn arrow_ahead(&mut self, from: u32) -> bool {
        let end = self.balanced_end(from);
        let after = self.significant(end);

        if self.kind_at(after) == Some(TypeScriptKind::Arrow) {
            return true;
        }

        if self.kind_at(after) != Some(TypeScriptKind::Colon) {
            return false;
        }

        if self.behind(from) == Some(TypeScriptKind::Arrow) && self.in_a_branch() {
            return false;
        }

        self.parameters_here(from) && self.arrow_after_type(after)
    }

    fn in_a_branch(&self) -> bool {
        let mut index = self.frame_count;

        while index > 0 {
            index -= 1;

            let frame = self.frames[index as usize];

            if frame.variant == Variant::Ternary && frame.stage == 0 {
                return true;
            }
        }

        false
    }

    fn parameters_here(&self, from: u32) -> bool {
        let held = self.significant(from + 1);

        match self.kind_at(held) {
            None => false,
            Some(
                TypeScriptKind::BraceOpen
                | TypeScriptKind::BracketOpen
                | TypeScriptKind::DotDotDot
                | TypeScriptKind::ParenClose
                | TypeScriptKind::ThisKeyword,
            ) => true,
            Some(kind) => is_name(kind),
        }
    }

    fn arrow_after_type(&self, from: u32) -> bool {
        let mut angles = 0_u32;
        let mut depth = 0_u32;

        for position in from..from.saturating_add(SCAN_STEP_MAX) {
            let Some(kind) = self.kind_at(position) else {
                return false;
            };

            if is_opener(kind) {
                depth += 1;
            }

            if is_closer(kind) {
                if depth == 0 {
                    return false;
                }

                depth -= 1;
            }

            if depth == 0 && kind == TypeScriptKind::Less {
                angles += 1;
            }

            if depth == 0 && angles > 0 && kind == TypeScriptKind::Greater {
                angles -= 1;
            }

            if depth == 0 && angles == 0 {
                if kind == TypeScriptKind::Arrow {
                    return true;
                }

                if matches!(kind, TypeScriptKind::Comma | TypeScriptKind::Semicolon) {
                    return false;
                }
            }
        }

        false
    }

    fn assigned_ahead(&mut self, from: u32) -> bool {
        let end = self.balanced_end(from);
        let after = self.significant(end);

        self.kind_at(after) == Some(TypeScriptKind::Equal)
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

    fn unary(&mut self, kind: TypeScriptKind, power: u8) -> Step {
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

    fn binary(&mut self, kind: TypeScriptKind, left: u8, right: u8) -> Step {
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
        let opener = self.current().unwrap_or(TypeScriptKind::ParenOpen);
        let bracket = self.anchor();

        self.bump();

        let content = self.anchor();

        let closer = if opener == TypeScriptKind::SubstitutionStart {
            TypeScriptKind::BraceClose
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
                .start_at(frame.bracket, TypeScriptKind::Arguments);
            self.bump();
            self.events.finish();
        } else {
            if frame.variant == Variant::Paren && frame.elements > 0 {
                self.events
                    .start_at(frame.content, TypeScriptKind::SequenceExpression);
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
                .start_at(top.checkpoint, TypeScriptKind::SequenceExpression);
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

            if top.variant == Variant::Arrow && kind == TypeScriptKind::BraceOpen {
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

    fn operand_of(&mut self, kind: TypeScriptKind, group: u32) -> Step {
        if let Some(step) = self.operand_angle(kind) {
            return step;
        }

        if kind == TypeScriptKind::DotDotDot {
            return self.unary(TypeScriptKind::SpreadElement, POWER_SPREAD);
        }

        if is_prefix(kind) {
            return self.unary(TypeScriptKind::UnaryExpression, POWER_UNARY);
        }

        if matches!(kind, TypeScriptKind::MinusMinus | TypeScriptKind::PlusPlus) {
            return self.unary(TypeScriptKind::UpdateExpression, POWER_UNARY);
        }

        if kind == TypeScriptKind::AwaitKeyword && !self.starts_expression(1) {
            return self.identifier_operand();
        }

        if kind == TypeScriptKind::AwaitKeyword {
            return self.unary(TypeScriptKind::AwaitExpression, POWER_UNARY);
        }

        if kind == TypeScriptKind::YieldKeyword {
            return self.yield_operand();
        }

        if kind == TypeScriptKind::NewKeyword {
            return self.new_operand();
        }

        if kind == TypeScriptKind::ImportKeyword {
            return self.import_operand();
        }

        if kind == TypeScriptKind::FunctionKeyword
            || (kind == TypeScriptKind::AsyncKeyword
                && self.ahead(1) == Some(TypeScriptKind::FunctionKeyword))
        {
            let checkpoint = self.anchor();

            self.function_expression();
            self.push_value(checkpoint);

            return Step::Operator;
        }

        if kind == TypeScriptKind::ClassKeyword {
            let checkpoint = self.anchor();

            self.class_body_of(TypeScriptKind::Class);
            self.push_value(checkpoint);

            return Step::Operator;
        }

        self.operand_group(kind, group)
    }

    fn operand_angle(&mut self, kind: TypeScriptKind) -> Option<Step> {
        if kind == TypeScriptKind::Less && self.generic_arrow_ahead() {
            return Some(self.generic_arrow());
        }

        if kind == TypeScriptKind::Less && !self.dialect.is_tsx() && self.type_arguments_ahead() {
            return Some(self.type_assertion());
        }

        if kind != TypeScriptKind::JsxTagStart {
            return None;
        }

        let checkpoint = self.anchor();

        self.jsx();
        self.push_value(checkpoint);

        Some(Step::Operator)
    }

    fn operand_group(&mut self, kind: TypeScriptKind, group: u32) -> Step {
        if self.opens_an_arrow(kind) {
            return self.arrow_head();
        }

        if kind == TypeScriptKind::ParenOpen {
            let checkpoint = self.anchor();

            return self.open_group(Variant::Paren, checkpoint);
        }

        if kind == TypeScriptKind::BracketOpen {
            return self.operand_pattern(Variant::Array);
        }

        if kind == TypeScriptKind::BraceOpen {
            return self.operand_pattern(Variant::Object);
        }

        if kind == TypeScriptKind::TemplateStart {
            return self.open_template(Checkpoint::NONE);
        }

        if kind == TypeScriptKind::PrivateIdentifier {
            let checkpoint = self.anchor();

            self.wrap(TypeScriptKind::PrivatePropertyIdentifier);
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

        self.wrap(TypeScriptKind::IdentifierNode);
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
                TypeScriptKind::AwaitKeyword
                    | TypeScriptKind::ClassKeyword
                    | TypeScriptKind::DotDotDot
                    | TypeScriptKind::FunctionKeyword
                    | TypeScriptKind::ImportKeyword
                    | TypeScriptKind::JsxTagStart
                    | TypeScriptKind::Less
                    | TypeScriptKind::MinusMinus
                    | TypeScriptKind::NewKeyword
                    | TypeScriptKind::PlusPlus
                    | TypeScriptKind::PrivateIdentifier
                    | TypeScriptKind::Slash
                    | TypeScriptKind::TemplateStart
                    | TypeScriptKind::YieldKeyword
            )
    }

    fn yield_operand(&mut self) -> Step {
        let checkpoint = self.anchor();
        let star = self.ahead(1) == Some(TypeScriptKind::Star);
        let steps = u32::from(star) + 1;

        if self.starts_line(self.ahead_position(steps)) || !self.starts_expression(steps) {
            self.open(TypeScriptKind::YieldExpression);
            self.bump();
            let _ = self.eat(TypeScriptKind::Star);
            self.events.finish();
            self.push_value(checkpoint);

            return Step::Operator;
        }

        let frame = Frame {
            checkpoint,
            kind: TypeScriptKind::YieldExpression,
            power: POWER_YIELD,
            values: self.value_count,
            variant: Variant::Unary,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        self.bump();
        let _ = self.eat(TypeScriptKind::Star);

        Step::Operand
    }

    fn new_operand(&mut self) -> Step {
        let checkpoint = self.anchor();

        if self.ahead(1) == Some(TypeScriptKind::Dot) {
            self.open(TypeScriptKind::MetaProperty);
            self.bump();
            self.bump();

            if is_property_name(self.current().unwrap_or(TypeScriptKind::ErrorToken)) {
                self.bump();
            }

            self.events.finish();
            self.push_value(checkpoint);

            return Step::Operator;
        }

        let frame = Frame {
            checkpoint,
            kind: TypeScriptKind::NewExpression,
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

        if self.ahead(1) == Some(TypeScriptKind::Dot) {
            self.open(TypeScriptKind::MetaProperty);
            self.bump();
            self.bump();

            if is_property_name(self.current().unwrap_or(TypeScriptKind::ErrorToken)) {
                self.bump();
            }

            self.events.finish();
            self.push_value(checkpoint);

            return Step::Operator;
        }

        self.wrap(TypeScriptKind::ImportNode);
        self.push_value(checkpoint);

        Step::Operator
    }

    fn opens_an_arrow(&mut self, kind: TypeScriptKind) -> bool {
        if kind == TypeScriptKind::ParenOpen {
            return self.arrow_ahead(self.significant(self.position));
        }

        if kind == TypeScriptKind::AsyncKeyword && !self.starts_line(self.ahead_position(1)) {
            if self.ahead(1) == Some(TypeScriptKind::ParenOpen) {
                return self.arrow_ahead(self.ahead_position(1));
            }

            if is_name(self.ahead(1).unwrap_or(TypeScriptKind::ErrorToken))
                && self.ahead(2) == Some(TypeScriptKind::Arrow)
            {
                return true;
            }

            if self.ahead(1) == Some(TypeScriptKind::Less) {
                return self.generic_arrow_ahead_at(self.ahead_position(1));
            }
        }

        is_name(kind) && self.ahead(1) == Some(TypeScriptKind::Arrow)
    }

    fn arrow_head(&mut self) -> Step {
        let checkpoint = self.anchor();

        if self.at(TypeScriptKind::AsyncKeyword) {
            self.bump();
        }

        self.type_parameters();

        if self.at(TypeScriptKind::ParenOpen) {
            self.formal_parameters();
            self.returning = true;
            self.return_annotation();
            self.returning = false;
        } else {
            self.wrap(TypeScriptKind::IdentifierNode);
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
            closer: TypeScriptKind::TemplateEnd,
            content: bracket,
            element: bracket,
            element_values: self.value_count,
            kind: TypeScriptKind::TemplateString,
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

    fn template_piece(&mut self, group: u32, kind: TypeScriptKind) -> Step {
        if kind == TypeScriptKind::TemplateChars {
            self.bump();

            return Step::Operand;
        }

        if kind == TypeScriptKind::SubstitutionStart {
            let checkpoint = self.anchor();

            return self.open_group(Variant::Substitution, checkpoint);
        }

        if kind == TypeScriptKind::TemplateEnd {
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
                .start_at(frame.checkpoint, TypeScriptKind::CallExpression);

            self.events
                .start_at(frame.bracket, TypeScriptKind::TemplateString);

            let _ = self.eat(TypeScriptKind::TemplateEnd);
            self.events.finish();
        } else {
            self.events
                .start_at(frame.checkpoint, TypeScriptKind::TemplateString);

            let _ = self.eat(TypeScriptKind::TemplateEnd);
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

        if self.at(TypeScriptKind::Less) {
            self.type_arguments();
        }

        self.jsx_attributes();

        if self.eat(TypeScriptKind::JsxTagEndSelf) {
            self.events
                .start_at(checkpoint, TypeScriptKind::JsxSelfClosingElement);
            self.events.finish();

            return;
        }

        self.expect(TypeScriptKind::JsxTagEnd, SyntaxErrorKind::UnexpectedToken);

        self.events
            .start_at(checkpoint, TypeScriptKind::JsxOpeningElement);
        self.events.finish();
        self.jsx_children();
        self.jsx_closing_element();
        self.events.start_at(checkpoint, TypeScriptKind::JsxElement);
        self.events.finish();
    }

    fn jsx_closing_element(&mut self) {
        if !self.at(TypeScriptKind::JsxTagStartClose) {
            self.record(SyntaxErrorKind::UnmatchedBracket);

            return;
        }

        let checkpoint = self.anchor();

        self.bump();
        self.jsx_element_name();
        self.expect(TypeScriptKind::JsxTagEnd, SyntaxErrorKind::UnexpectedToken);

        self.events
            .start_at(checkpoint, TypeScriptKind::JsxClosingElement);
        self.events.finish();
    }

    fn jsx_element_name(&mut self) {
        if !self.at(TypeScriptKind::Identifier) {
            return;
        }

        let checkpoint = self.anchor();

        self.wrap(TypeScriptKind::IdentifierNode);

        if self.at(TypeScriptKind::Colon) {
            self.bump();

            if self.at(TypeScriptKind::Identifier) {
                self.wrap(TypeScriptKind::IdentifierNode);
            }

            self.events
                .start_at(checkpoint, TypeScriptKind::JsxNamespaceName);
            self.events.finish();

            return;
        }

        for _ in 0..self.steps() {
            if !self.at(TypeScriptKind::Dot) {
                return;
            }

            self.bump();

            if self.at(TypeScriptKind::Identifier) {
                self.wrap(TypeScriptKind::PropertyIdentifier);
            }

            self.events
                .start_at(checkpoint, TypeScriptKind::MemberExpression);
            self.events.finish();
        }
    }

    fn jsx_attributes(&mut self) {
        for _ in 0..self.steps() {
            match self.current() {
                Some(TypeScriptKind::BraceOpen) => self.jsx_expression(),
                Some(TypeScriptKind::Identifier) => self.jsx_attribute(),
                _ => return,
            }
        }
    }

    fn jsx_attribute(&mut self) {
        let checkpoint = self.anchor();

        self.jsx_attribute_name();

        if self.eat(TypeScriptKind::Equal) {
            self.jsx_attribute_value();
        }

        self.events
            .start_at(checkpoint, TypeScriptKind::JsxAttribute);
        self.events.finish();
    }

    fn jsx_attribute_name(&mut self) {
        if self.ahead(1) != Some(TypeScriptKind::Colon) {
            self.wrap(TypeScriptKind::PropertyIdentifier);

            return;
        }

        let checkpoint = self.anchor();

        self.wrap(TypeScriptKind::IdentifierNode);
        self.bump();

        if self.at(TypeScriptKind::Identifier) {
            self.wrap(TypeScriptKind::IdentifierNode);
        }

        self.events
            .start_at(checkpoint, TypeScriptKind::JsxNamespaceName);
        self.events.finish();
    }

    fn jsx_attribute_value(&mut self) {
        match self.current() {
            Some(TypeScriptKind::BraceOpen) => self.jsx_expression(),
            Some(TypeScriptKind::JsxTagStart) => self.jsx(),
            Some(TypeScriptKind::String) => self.wrap(TypeScriptKind::StringNode),
            _ => self.record(SyntaxErrorKind::ExpectedExpression),
        }
    }

    fn jsx_expression(&mut self) {
        let checkpoint = self.anchor();

        self.bump();

        if !self.at(TypeScriptKind::BraceClose) {
            self.expression();
        }

        self.expect(
            TypeScriptKind::BraceClose,
            SyntaxErrorKind::UnmatchedBracket,
        );

        self.events
            .start_at(checkpoint, TypeScriptKind::JsxExpression);
        self.events.finish();
    }

    fn jsx_children(&mut self) {
        for _ in 0..u32::MAX {
            match self.current() {
                Some(TypeScriptKind::BraceOpen) => self.jsx_expression(),
                Some(TypeScriptKind::JsxChars) => self.wrap(TypeScriptKind::JsxText),
                Some(TypeScriptKind::JsxEntity) => self.bump(),
                Some(TypeScriptKind::JsxTagStart) => self.jsx(),
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

        if kind == TypeScriptKind::Comma {
            return self.comma(group);
        }

        if matches!(kind, TypeScriptKind::Dot | TypeScriptKind::QuestionDot) {
            return self.member_trailer(kind);
        }

        if kind == TypeScriptKind::ParenOpen {
            return self.call_trailer();
        }

        if kind == TypeScriptKind::BracketOpen {
            return self.subscript_trailer();
        }

        if kind == TypeScriptKind::TemplateStart {
            return self.tagged_template();
        }

        if matches!(kind, TypeScriptKind::MinusMinus | TypeScriptKind::PlusPlus) {
            return self.postfix_update();
        }

        if let Some(step) = self.typed_operator(kind, group) {
            return step;
        }

        if kind == TypeScriptKind::Question {
            return self.ternary();
        }

        if kind == TypeScriptKind::Colon {
            return self.ternary_else(base);
        }

        if kind == TypeScriptKind::Arrow {
            return self.arrow_body();
        }

        if kind == TypeScriptKind::Greater && self.joined(self.significant(self.position)) {
            return self.shift();
        }

        if let Some((node, left, right)) = infix_of(kind) {
            return self.binary(node, left, right);
        }

        Step::Done
    }

    fn typed_operator(&mut self, kind: TypeScriptKind, group: u32) -> Option<Step> {
        if kind == TypeScriptKind::Bang {
            return Some(self.non_null(group));
        }

        if self.word(b"as") || self.word(b"satisfies") {
            return Some(self.type_operation());
        }

        if kind == TypeScriptKind::Less && self.call_arguments_ahead() {
            return Some(self.type_argument_trailer());
        }

        None
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

        self.value_count = self.frames[group as usize].values;
        self.frames[group as usize].element_values = self.value_count;

        Step::Operand
    }

    fn member_trailer(&mut self, kind: TypeScriptKind) -> Step {
        if self.value_count == 0 {
            return Step::Done;
        }

        if kind == TypeScriptKind::QuestionDot {
            let after = self.ahead(1);

            if after == Some(TypeScriptKind::BracketOpen) {
                self.optional_chain();

                return self.subscript_trailer();
            }

            if after == Some(TypeScriptKind::ParenOpen) {
                self.bump();

                return self.call_trailer();
            }

            if after == Some(TypeScriptKind::Less)
                && self.call_arguments_ahead_at(self.ahead_position(1))
            {
                self.bump();

                return self.type_argument_trailer();
            }
        }

        let checkpoint = self.values[self.value_count as usize - 1];

        self.events
            .start_at(checkpoint, TypeScriptKind::MemberExpression);

        if kind == TypeScriptKind::QuestionDot {
            self.open(TypeScriptKind::OptionalChain);
            self.bump();
            self.events.finish();
        } else {
            self.bump();
        }

        match self.current().unwrap_or(TypeScriptKind::ErrorToken) {
            TypeScriptKind::PrivateIdentifier => {
                self.wrap(TypeScriptKind::PrivatePropertyIdentifier);
            }
            current if is_property_name(current) => {
                self.wrap(TypeScriptKind::PropertyIdentifier);
            }
            _ => {}
        }

        self.events.finish();

        Step::Operator
    }

    fn optional_chain(&mut self) {
        self.open(TypeScriptKind::OptionalChain);
        self.bump();
        self.events.finish();
    }

    fn call_trailer(&mut self) -> Step {
        if self.value_count == 0 {
            return Step::Done;
        }

        let checkpoint = self.values[self.value_count as usize - 1];
        let mut kind = TypeScriptKind::CallExpression;

        self.value_count -= 1;

        if self.frame_count > 0 {
            let top = self.frames[self.frame_count as usize - 1];

            if top.variant == Variant::Unary
                && top.kind == TypeScriptKind::NewExpression
                && top.stage == 1
                && self.value_count == top.values
            {
                self.frame_count -= 1;
                kind = TypeScriptKind::NewExpression;

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
            .start_at(checkpoint, TypeScriptKind::UpdateExpression);

        self.bump();
        self.events.finish();

        Step::Operator
    }

    fn joined(&self, position: u32) -> bool {
        let Some(held) = self.tokens.get(position as usize) else {
            return false;
        };

        let Some(next) = self.tokens.get(position as usize + 1) else {
            return false;
        };

        held.end() == next.offset && self.kind_at(position + 1) == Some(TypeScriptKind::Greater)
    }

    fn shift(&mut self) -> Step {
        let step = self.binary(
            TypeScriptKind::BinaryExpression,
            POWER_SHIFT_LEFT,
            POWER_SHIFT_RIGHT,
        );

        for _ in 0..2 {
            if self.kind_at(self.position) != Some(TypeScriptKind::Greater) {
                break;
            }

            self.bump();
        }

        step
    }

    fn non_null(&mut self, _group: u32) -> Step {
        if self.value_count == 0 {
            return Step::Done;
        }

        let checkpoint = self.values[self.value_count as usize - 1];

        self.events
            .start_at(checkpoint, TypeScriptKind::NonNullExpression);

        self.bump();
        self.events.finish();

        Step::Operator
    }

    fn generic_arrow_ahead(&mut self) -> bool {
        self.generic_arrow_ahead_at(self.significant(self.position))
    }

    fn generic_arrow_ahead_at(&mut self, from: u32) -> bool {
        let end = self.type_arguments_end_at(from);

        if end == NONE_POSITION {
            return false;
        }

        let after = self.significant(end);

        self.kind_at(after) == Some(TypeScriptKind::ParenOpen) && self.arrow_ahead(after)
    }

    fn generic_arrow(&mut self) -> Step {
        let checkpoint = self.anchor();

        self.type_parameters();
        self.formal_parameters();
        self.returning = true;
        self.return_annotation();
        self.returning = false;
        self.push_value(checkpoint);

        Step::Operator
    }

    fn type_assertion(&mut self) -> Step {
        let checkpoint = self.anchor();

        let frame = Frame {
            checkpoint,
            kind: TypeScriptKind::TypeAssertion,
            power: POWER_UNARY,
            values: self.value_count,
            variant: Variant::Unary,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        self.type_arguments();

        Step::Operand
    }

    fn type_operation(&mut self) -> Step {
        self.reduce_for(POWER_RELATIONAL_LEFT);

        if self.value_count == 0 {
            return Step::Done;
        }

        let satisfies = self.word(b"satisfies");
        let checkpoint = self.values[self.value_count as usize - 1];

        let kind = if satisfies {
            TypeScriptKind::SatisfiesExpression
        } else {
            TypeScriptKind::AsExpression
        };

        self.bump();

        if self.at(TypeScriptKind::ConstKeyword) {
            self.bump();
        } else {
            self.type_expression();
        }

        self.events.start_at(checkpoint, kind);
        self.events.finish();

        Step::Operator
    }

    fn type_argument_trailer(&mut self) -> Step {
        if self.value_count == 0 {
            return Step::Done;
        }

        let checkpoint = self.values[self.value_count as usize - 1];

        self.type_arguments();

        if matches!(
            self.current(),
            Some(TypeScriptKind::ParenOpen | TypeScriptKind::TemplateStart)
        ) {
            return Step::Operator;
        }

        if self.frame_count > 0
            && self.frames[self.frame_count as usize - 1].kind == TypeScriptKind::NewExpression
        {
            return Step::Operator;
        }

        self.value_count -= 1;

        self.events
            .start_at(checkpoint, TypeScriptKind::InstantiationExpression);
        self.events.finish();
        self.push_value(checkpoint);

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
            kind: TypeScriptKind::TernaryExpression,
            power: POWER_ASSIGN_RIGHT,
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
            kind: TypeScriptKind::ArrowFunction,
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

    fn object_member(&mut self, kind: TypeScriptKind) -> Step {
        if kind == TypeScriptKind::DotDotDot {
            return self.unary(TypeScriptKind::SpreadElement, POWER_SPREAD);
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
            self.wrap(TypeScriptKind::ShorthandPropertyIdentifier);
            self.push_value(checkpoint);

            return Step::Operator;
        }

        self.property_key();

        if !self.at(TypeScriptKind::Colon) {
            self.push_value(checkpoint);

            return Step::Operator;
        }

        let frame = Frame {
            checkpoint,
            kind: TypeScriptKind::Pair,
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

    fn opens_a_key(kind: TypeScriptKind) -> bool {
        is_property_name(kind)
            || matches!(
                kind,
                TypeScriptKind::BracketOpen
                    | TypeScriptKind::Number
                    | TypeScriptKind::PrivateIdentifier
                    | TypeScriptKind::String
            )
    }

    fn key_ends_at_colon(&mut self) -> bool {
        let position = self.significant(self.position);

        if self.kind_at(position) == Some(TypeScriptKind::BracketOpen) {
            let end = self.balanced_end(position);
            let after = self.significant(end);

            return self.kind_at(after) == Some(TypeScriptKind::Colon);
        }

        self.ahead(1) == Some(TypeScriptKind::Colon)
    }

    fn method_ahead(&mut self) -> bool {
        let mut position = self.significant(self.position);

        for _ in 0..8 {
            let Some(kind) = self.kind_at(position) else {
                return false;
            };

            if kind == TypeScriptKind::Star {
                position = self.significant(position + 1);

                continue;
            }

            let modifier = kind == TypeScriptKind::AsyncKeyword
                || kind == TypeScriptKind::StaticKeyword
                || self.word_at(position, b"abstract")
                || self.word_at(position, b"declare")
                || self.word_at(position, b"get")
                || self.word_at(position, b"override")
                || self.word_at(position, b"private")
                || self.word_at(position, b"protected")
                || self.word_at(position, b"public")
                || self.word_at(position, b"readonly")
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
                TypeScriptKind::BraceClose
                    | TypeScriptKind::Colon
                    | TypeScriptKind::Comma
                    | TypeScriptKind::Equal
                    | TypeScriptKind::Less
                    | TypeScriptKind::ParenOpen
                    | TypeScriptKind::Semicolon
            ) {
                break;
            }

            position = after;
        }

        let held = if self.kind_at(position) == Some(TypeScriptKind::BracketOpen) {
            let end = self.balanced_end(position);

            self.significant(end)
        } else {
            self.significant(position + 1)
        };

        let after = if self.kind_at(held) == Some(TypeScriptKind::Question) {
            self.significant(held + 1)
        } else {
            held
        };

        matches!(
            self.kind_at(after),
            Some(TypeScriptKind::Less | TypeScriptKind::ParenOpen)
        ) && Self::opens_a_key(self.kind_at(position).unwrap_or(TypeScriptKind::ErrorToken))
    }

    fn property_key(&mut self) {
        let Some(kind) = self.current() else {
            return;
        };

        if kind == TypeScriptKind::BracketOpen {
            self.open(TypeScriptKind::ComputedPropertyName);
            self.bump();
            self.expression_single();
            let _ = self.eat(TypeScriptKind::BracketClose);
            self.events.finish();

            return;
        }

        if kind == TypeScriptKind::String {
            self.wrap(TypeScriptKind::StringNode);

            return;
        }

        if kind == TypeScriptKind::Number {
            self.wrap(TypeScriptKind::NumberNode);

            return;
        }

        if kind == TypeScriptKind::PrivateIdentifier {
            self.wrap(TypeScriptKind::PrivatePropertyIdentifier);

            return;
        }

        if is_property_name(kind) {
            self.wrap(TypeScriptKind::PropertyIdentifier);
        }
    }

    fn method_definition(&mut self) {
        let checkpoint = self.anchor();
        let abstracted = self.modifiers();

        self.property_key();
        let _ = self.eat(TypeScriptKind::Question);
        self.type_parameters();
        self.formal_parameters();
        self.return_annotation();

        if !self.at(TypeScriptKind::BraceOpen) {
            let kind = if abstracted {
                TypeScriptKind::AbstractMethodSignature
            } else {
                TypeScriptKind::MethodSignature
            };

            self.events.start_at(checkpoint, kind);
            self.events.finish();
            let _ = self.eat(TypeScriptKind::Semicolon);

            return;
        }

        self.statement_block();

        self.events
            .start_at(checkpoint, TypeScriptKind::MethodDefinition);
        self.events.finish();
    }

    fn modifiers(&mut self) -> bool {
        let mut abstracted = false;

        for _ in 0..8 {
            let before = self.position;

            abstracted = self.member_modifiers() || abstracted;

            self.method_modifiers();

            if self.position == before {
                break;
            }
        }

        abstracted
    }

    fn method_modifiers(&mut self) {
        for _ in 0..4 {
            if self.eat(TypeScriptKind::Star) {
                continue;
            }

            let position = self.significant(self.position);

            let Some(kind) = self.kind_at(position) else {
                return;
            };

            let modifier = kind == TypeScriptKind::AsyncKeyword
                || kind == TypeScriptKind::StaticKeyword
                || self.word_at(position, b"get")
                || self.word_at(position, b"set");

            if !modifier {
                return;
            }

            let after = self.significant(position + 1);

            if matches!(
                self.kind_at(after),
                None | Some(
                    TypeScriptKind::BraceClose
                        | TypeScriptKind::Colon
                        | TypeScriptKind::Comma
                        | TypeScriptKind::Equal
                        | TypeScriptKind::Less
                        | TypeScriptKind::ParenOpen
                        | TypeScriptKind::Question
                        | TypeScriptKind::Semicolon
                )
            ) {
                return;
            }

            self.bump();
        }
    }

    fn formal_parameters(&mut self) {
        self.open(TypeScriptKind::FormalParameters);
        self.expect(TypeScriptKind::ParenOpen, SyntaxErrorKind::UnexpectedToken);

        for _ in 0..self.steps() {
            self.skip_trivia();

            if self.at(TypeScriptKind::ParenClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.parameter();

            if !self.eat(TypeScriptKind::Comma) {
                break;
            }

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(TypeScriptKind::ParenClose);
        self.events.finish();
    }

    fn pattern(&mut self) {
        let Some(kind) = self.current() else {
            return;
        };

        if kind == TypeScriptKind::BracketOpen {
            self.array_pattern();

            return;
        }

        if kind == TypeScriptKind::BraceOpen {
            self.object_pattern();

            return;
        }

        if kind == TypeScriptKind::DotDotDot {
            self.open(TypeScriptKind::RestPattern);
            self.bump();
            self.pattern();
            self.events.finish();

            return;
        }

        let reached = matches!(
            self.ahead(1),
            Some(
                TypeScriptKind::BracketOpen
                    | TypeScriptKind::Dot
                    | TypeScriptKind::QuestionDot
            )
        );

        if is_name(kind) && !reached {
            self.wrap(TypeScriptKind::IdentifierNode);

            return;
        }

        self.expression_single();
    }

    fn pattern_element(&mut self) {
        let checkpoint = self.anchor();

        self.pattern();

        if !self.at(TypeScriptKind::Equal) {
            return;
        }

        self.events
            .start_at(checkpoint, TypeScriptKind::AssignmentPattern);

        self.bump();
        self.expression_single();
        self.events.finish();
    }

    fn array_pattern(&mut self) {
        self.open(TypeScriptKind::ArrayPattern);
        self.bump();

        for _ in 0..self.steps() {
            self.skip_trivia();

            if self.at(TypeScriptKind::BracketClose) || self.current().is_none() {
                break;
            }

            if self.eat(TypeScriptKind::Comma) {
                continue;
            }

            let before = self.position;

            self.pattern_element();

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(TypeScriptKind::BracketClose);
        self.events.finish();
    }

    fn object_pattern(&mut self) {
        self.open(TypeScriptKind::ObjectPattern);
        self.bump();

        for _ in 0..self.steps() {
            self.skip_trivia();

            if self.at(TypeScriptKind::BraceClose) || self.current().is_none() {
                break;
            }

            if self.eat(TypeScriptKind::Comma) {
                continue;
            }

            let before = self.position;

            self.object_pattern_member();

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(TypeScriptKind::BraceClose);
        self.events.finish();
    }

    fn object_pattern_member(&mut self) {
        let Some(kind) = self.current() else {
            return;
        };

        if kind == TypeScriptKind::DotDotDot {
            self.open(TypeScriptKind::RestPattern);
            self.bump();
            self.pattern();
            self.events.finish();

            return;
        }

        let checkpoint = self.anchor();

        if self.key_ends_at_colon() || kind == TypeScriptKind::BracketOpen {
            self.open(TypeScriptKind::PairPattern);
            self.property_key();
            self.expect(TypeScriptKind::Colon, SyntaxErrorKind::ExpectedColon);
            self.pattern_element();
            self.events.finish();

            return;
        }

        self.wrap(TypeScriptKind::ShorthandPropertyIdentifierPattern);

        if !self.at(TypeScriptKind::Equal) {
            return;
        }

        self.events
            .start_at(checkpoint, TypeScriptKind::ObjectAssignmentPattern);

        self.bump();
        self.expression_single();
        self.events.finish();
    }

    fn run(&mut self) {
        self.events.start(TypeScriptKind::Program);
        self.statements_until(TypeScriptKind::ErrorToken);
        self.events.finish();
    }

    fn statements_until(&mut self, closer: TypeScriptKind) {
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
        let kind = held.unwrap_or(TypeScriptKind::ErrorToken);

        match held {
            None => {}
            Some(TypeScriptKind::At) => self.decorated(),
            Some(TypeScriptKind::BraceOpen) => self.statement_block(),
            Some(TypeScriptKind::BreakKeyword) => {
                self.jump_statement(TypeScriptKind::BreakStatement);
            }
            Some(TypeScriptKind::ClassKeyword) => self.class_declaration(),
            Some(TypeScriptKind::ContinueKeyword) => {
                self.jump_statement(TypeScriptKind::ContinueStatement);
            }
            Some(TypeScriptKind::DebuggerKeyword) => self.debugger_statement(),
            Some(TypeScriptKind::DoKeyword) => self.do_statement(),
            Some(TypeScriptKind::ExportKeyword) => self.export_statement(),
            Some(TypeScriptKind::ForKeyword) => self.for_statement(),
            Some(TypeScriptKind::FunctionKeyword) => self.function_declaration(),
            Some(TypeScriptKind::IfKeyword) => self.if_statement(),
            Some(TypeScriptKind::ReturnKeyword) => self.return_statement(),
            Some(TypeScriptKind::Semicolon) => self.wrap(TypeScriptKind::EmptyStatement),
            Some(TypeScriptKind::SwitchKeyword) => self.switch_statement(),
            Some(TypeScriptKind::ThrowKeyword) => self.throw_statement(),
            Some(TypeScriptKind::TryKeyword) => self.try_statement(),
            Some(TypeScriptKind::WhileKeyword) => self.while_statement(),
            Some(TypeScriptKind::WithKeyword) => self.with_statement(),
            Some(TypeScriptKind::ConstKeyword) if self.word_at(self.ahead_position(1), b"enum") => {
                self.enum_declaration();
            }
            Some(TypeScriptKind::ConstKeyword | TypeScriptKind::VarKeyword) => self.declaration(),
            Some(TypeScriptKind::AsyncKeyword)
                if self.ahead(1) == Some(TypeScriptKind::FunctionKeyword)
                    && !self.starts_line(self.ahead_position(1)) =>
            {
                self.function_declaration();
            }
            Some(TypeScriptKind::LetKeyword) if self.opens_a_binding() => self.declaration(),
            Some(TypeScriptKind::AwaitKeyword) if self.opens_a_resource(1) => self.declaration(),
            Some(TypeScriptKind::Identifier) if self.opens_a_resource(0) => self.declaration(),
            Some(TypeScriptKind::ImportKeyword) if self.opens_an_import_alias() => {
                self.import_alias();
            }
            Some(TypeScriptKind::ImportKeyword)
                if !matches!(
                    self.ahead(1),
                    Some(TypeScriptKind::Dot | TypeScriptKind::ParenOpen)
                ) =>
            {
                self.import_statement();
            }
            Some(_) if self.typed_statement() => {}
            Some(_) if is_name(kind) && self.ahead(1) == Some(TypeScriptKind::Colon) => {
                self.labeled_statement();
            }
            Some(_) => self.expression_statement(),
        }
    }

    fn typed_statement(&mut self) -> bool {
        if self.word(b"interface") && self.opens_a_name(1) {
            self.interface_declaration();

            return true;
        }

        if self.word(b"type") && self.opens_an_alias() {
            self.type_alias();

            return true;
        }

        if self.word(b"enum") && self.opens_a_name(1) {
            self.enum_declaration();

            return true;
        }

        if self.word(b"declare") && self.opens_an_ambient() {
            self.ambient_declaration();

            return true;
        }

        if self.word(b"abstract") && self.ahead(1) == Some(TypeScriptKind::ClassKeyword) {
            self.abstract_class();

            return true;
        }

        if self.word(b"namespace") && self.opens_a_name(1) {
            self.open(TypeScriptKind::ExpressionStatement);
            self.internal_module();
            let _ = self.eat(TypeScriptKind::Semicolon);
            self.events.finish();

            return true;
        }

        if self.word(b"module") && self.opens_a_module(1) {
            self.module_declaration();

            return true;
        }

        false
    }

    fn opens_an_ambient(&self) -> bool {
        self.opens_a_name(1)
            || matches!(
                self.ahead(1),
                Some(
                    TypeScriptKind::ClassKeyword
                        | TypeScriptKind::ConstKeyword
                        | TypeScriptKind::FunctionKeyword
                        | TypeScriptKind::LetKeyword
                        | TypeScriptKind::VarKeyword
                )
            )
    }

    fn opens_a_binding(&self) -> bool {
        let Some(kind) = self.ahead(1) else {
            return false;
        };

        is_name(kind)
            || matches!(
                kind,
                TypeScriptKind::BraceOpen | TypeScriptKind::BracketOpen
            )
    }

    fn opens_a_resource(&self, steps: u32) -> bool {
        let position = self.ahead_position(steps);

        if !self.word_at(position, b"using") || (steps > 0 && self.starts_line(position)) {
            return false;
        }

        let name = self.ahead_position(steps + 1);
        let kind = self.kind_at(name).unwrap_or(TypeScriptKind::ErrorToken);

        is_name(kind)
            && kind != TypeScriptKind::AwaitKeyword
            && !self.starts_line(name)
            && self.ahead(steps + 2) == Some(TypeScriptKind::Equal)
    }

    fn iterates_a_resource(&self, steps: u32) -> bool {
        let position = self.ahead_position(steps);

        if !self.word_at(position, b"using") || (steps > 0 && self.starts_line(position)) {
            return false;
        }

        let name = self.ahead_position(steps + 1);
        let kind = self.kind_at(name).unwrap_or(TypeScriptKind::ErrorToken);

        is_name(kind)
            && !matches!(
                kind,
                TypeScriptKind::AwaitKeyword | TypeScriptKind::OfKeyword
            )
            && !self.starts_line(name)
    }

    fn expression_statement(&mut self) {
        self.open(TypeScriptKind::ExpressionStatement);
        self.expression();
        let _ = self.eat(TypeScriptKind::Semicolon);
        self.events.finish();
    }

    fn statement_block(&mut self) {
        self.open(TypeScriptKind::StatementBlock);
        self.expect(TypeScriptKind::BraceOpen, SyntaxErrorKind::UnexpectedToken);
        self.statements_until(TypeScriptKind::BraceClose);
        let _ = self.eat(TypeScriptKind::BraceClose);
        self.events.finish();
    }

    fn declaration(&mut self) {
        let lexical = !self.at(TypeScriptKind::VarKeyword);

        let kind = if lexical {
            TypeScriptKind::LexicalDeclaration
        } else {
            TypeScriptKind::VariableDeclaration
        };

        self.open(kind);

        if self.at(TypeScriptKind::AwaitKeyword) {
            self.bump();
        }

        self.bump();

        for _ in 0..self.steps() {
            let before = self.position;

            self.variable_declarator();

            if !self.eat(TypeScriptKind::Comma) {
                break;
            }

            if self.position == before {
                break;
            }
        }

        let _ = self.eat(TypeScriptKind::Semicolon);
        self.events.finish();
    }

    fn variable_declarator(&mut self) {
        self.open(TypeScriptKind::VariableDeclarator);
        self.pattern();
        let _ = self.eat(TypeScriptKind::Bang);
        self.type_annotation();

        if self.eat(TypeScriptKind::Equal) {
            self.expression_single();
        }

        self.events.finish();
    }

    fn function_declaration(&mut self) {
        let steps = u32::from(self.at(TypeScriptKind::AsyncKeyword));
        let generator = self.ahead(steps + 1) == Some(TypeScriptKind::Star);
        let checkpoint = self.anchor();

        self.function_head();

        let kind = if !self.at(TypeScriptKind::BraceOpen) {
            TypeScriptKind::FunctionSignature
        } else if generator {
            TypeScriptKind::GeneratorFunctionDeclaration
        } else {
            TypeScriptKind::FunctionDeclaration
        };

        if self.at(TypeScriptKind::BraceOpen) {
            self.statement_block();
        } else {
            let _ = self.eat(TypeScriptKind::Semicolon);
        }

        self.events.start_at(checkpoint, kind);
        self.events.finish();
    }

    fn function_expression(&mut self) {
        let steps = u32::from(self.at(TypeScriptKind::AsyncKeyword));
        let generator = self.ahead(steps + 1) == Some(TypeScriptKind::Star);

        let kind = if generator {
            TypeScriptKind::GeneratorFunction
        } else {
            TypeScriptKind::FunctionExpression
        };

        self.open(kind);
        self.function_body();
        self.events.finish();
    }

    fn function_body(&mut self) {
        self.function_head();
        self.statement_block();
    }

    fn function_head(&mut self) {
        let _ = self.eat(TypeScriptKind::AsyncKeyword);

        self.expect(
            TypeScriptKind::FunctionKeyword,
            SyntaxErrorKind::UnexpectedToken,
        );

        let _ = self.eat(TypeScriptKind::Star);

        if is_name(self.current().unwrap_or(TypeScriptKind::ErrorToken)) {
            self.wrap(TypeScriptKind::IdentifierNode);
        }

        self.type_parameters();
        self.formal_parameters();
        self.return_annotation();
    }

    fn decorated(&mut self) {
        let checkpoint = self.anchor();

        self.decorators();

        if self.at(TypeScriptKind::ClassKeyword) {
            self.class_at(checkpoint, TypeScriptKind::ClassDeclaration);

            return;
        }

        if self.word(b"abstract") && self.ahead(1) == Some(TypeScriptKind::ClassKeyword) {
            self.abstract_class_at(checkpoint);

            return;
        }

        if self.at(TypeScriptKind::ExportKeyword) {
            self.export_at(checkpoint);

            return;
        }

        self.statement();
    }

    fn decorators(&mut self) {
        for _ in 0..self.steps() {
            if !self.at(TypeScriptKind::At) {
                break;
            }

            self.open(TypeScriptKind::Decorator);
            self.bump();
            self.expression_single();
            self.events.finish();
            self.skip_trivia();
        }
    }

    fn class_declaration(&mut self) {
        self.class_body_of(TypeScriptKind::ClassDeclaration);
    }

    fn class_body_of(&mut self, kind: TypeScriptKind) {
        let checkpoint = self.anchor();

        self.class_at(checkpoint, kind);
    }

    fn class_at(&mut self, checkpoint: Checkpoint, kind: TypeScriptKind) {
        self.expect(
            TypeScriptKind::ClassKeyword,
            SyntaxErrorKind::UnexpectedToken,
        );

        if is_name(self.current().unwrap_or(TypeScriptKind::ErrorToken)) && !self.word(b"implements")
        {
            self.wrap(TypeScriptKind::TypeIdentifier);
        }

        self.type_parameters();
        self.class_heritage();
        self.class_body();
        self.events.start_at(checkpoint, kind);
        self.events.finish();
    }

    fn class_heritage(&mut self) {
        if !self.at(TypeScriptKind::ExtendsKeyword) && !self.word(b"implements") {
            return;
        }

        self.open(TypeScriptKind::ClassHeritage);

        for _ in 0..self.steps() {
            if self.at(TypeScriptKind::ExtendsKeyword) {
                self.open(TypeScriptKind::ExtendsClause);
                self.bump();
                self.heritage_list();
                self.events.finish();

                continue;
            }

            if self.word(b"implements") {
                self.open(TypeScriptKind::ImplementsClause);
                self.bump();
                self.type_list();
                self.events.finish();

                continue;
            }

            break;
        }

        self.events.finish();
    }

    fn heritage_item(&mut self) {
        if !self.heritage_generic_ahead() {
            self.expression_single();

            return;
        }

        let checkpoint = self.anchor();

        self.query_target();
        self.type_arguments();

        if !self.at(TypeScriptKind::ParenOpen) {
            return;
        }

        self.argument_list();

        self.events
            .start_at(checkpoint, TypeScriptKind::CallExpression);
        self.events.finish();
    }

    fn argument_list(&mut self) {
        self.open(TypeScriptKind::Arguments);
        self.bump();

        for _ in 0..self.steps() {
            self.skip_trivia();

            if self.at(TypeScriptKind::ParenClose) || self.current().is_none() {
                break;
            }

            if self.eat(TypeScriptKind::Comma) {
                continue;
            }

            let before = self.position;

            self.expression_single();

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(TypeScriptKind::ParenClose);
        self.events.finish();
    }

    fn heritage_generic_ahead(&self) -> bool {
        if !is_property_name(self.current().unwrap_or(TypeScriptKind::ErrorToken)) {
            return false;
        }

        let mut position = self.significant(self.position);

        for _ in 0..self.steps() {
            let after = self.significant(position + 1);

            if self.kind_at(after) != Some(TypeScriptKind::Dot) {
                break;
            }

            let next = self.significant(after + 1);

            if !is_property_name(self.kind_at(next).unwrap_or(TypeScriptKind::ErrorToken)) {
                break;
            }

            position = next;
        }

        self.kind_at(self.significant(position + 1)) == Some(TypeScriptKind::Less)
    }

    fn type_list(&mut self) {
        for _ in 0..self.steps() {
            let before = self.position;

            self.type_expression();

            if !self.eat(TypeScriptKind::Comma) {
                break;
            }

            if self.position == before {
                self.emit();
            }
        }
    }

    fn heritage_list(&mut self) {
        for _ in 0..self.steps() {
            let before = self.position;

            self.heritage_item();

            if !self.eat(TypeScriptKind::Comma) {
                break;
            }

            if self.position == before {
                self.emit();
            }
        }
    }

    fn class_body(&mut self) {
        self.open(TypeScriptKind::ClassBody);
        self.expect(TypeScriptKind::BraceOpen, SyntaxErrorKind::UnexpectedToken);

        for _ in 0..self.steps() {
            self.skip_trivia();

            if self.at(TypeScriptKind::BraceClose) || self.current().is_none() {
                break;
            }

            if self.eat(TypeScriptKind::Semicolon) {
                continue;
            }

            let before = self.position;

            self.class_member();

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(TypeScriptKind::BraceClose);
        self.events.finish();
    }

    fn class_member(&mut self) {
        let checkpoint = self.anchor();
        let decorated = self.at(TypeScriptKind::At);

        self.decorators();

        if decorated && self.method_ahead() {
            return;
        }

        if self.at(TypeScriptKind::StaticKeyword)
            && self.ahead(1) == Some(TypeScriptKind::BraceOpen)
        {
            self.open(TypeScriptKind::ClassStaticBlock);
            self.bump();
            self.statement_block();
            self.events.finish();

            return;
        }

        if self.method_ahead() {
            self.method_definition();

            return;
        }

        if self.readonly_index_ahead()
            || (self.at(TypeScriptKind::BracketOpen) && self.index_signature_ahead())
        {
            self.index_signature();
            let _ = self.eat(TypeScriptKind::Semicolon);

            return;
        }

        let _ = self.modifiers();

        self.property_key();
        let _ = self.eat(TypeScriptKind::Question);
        let _ = self.eat(TypeScriptKind::Bang);
        self.type_annotation();

        if self.eat(TypeScriptKind::Equal) {
            self.expression_single();
        }

        self.events
            .start_at(checkpoint, TypeScriptKind::PublicFieldDefinition);
        self.events.finish();
        let _ = self.eat(TypeScriptKind::Semicolon);
    }

    fn parenthesized(&mut self) {
        self.open(TypeScriptKind::ParenthesizedExpression);
        self.expect(TypeScriptKind::ParenOpen, SyntaxErrorKind::UnexpectedToken);
        self.expression();
        let _ = self.eat(TypeScriptKind::ParenClose);
        self.events.finish();
    }

    fn if_statement(&mut self) {
        self.open(TypeScriptKind::IfStatement);
        self.bump();
        self.parenthesized();
        self.statement();

        if self.at(TypeScriptKind::ElseKeyword) {
            self.open(TypeScriptKind::ElseClause);
            self.bump();
            self.statement();
            self.events.finish();
        }

        self.events.finish();
    }

    fn while_statement(&mut self) {
        self.open(TypeScriptKind::WhileStatement);
        self.bump();
        self.parenthesized();
        self.statement();
        self.events.finish();
    }

    fn with_statement(&mut self) {
        self.open(TypeScriptKind::WithStatement);
        self.bump();
        self.parenthesized();
        self.statement();
        self.events.finish();
    }

    fn do_statement(&mut self) {
        self.open(TypeScriptKind::DoStatement);
        self.bump();
        self.statement();

        self.expect(
            TypeScriptKind::WhileKeyword,
            SyntaxErrorKind::UnexpectedToken,
        );

        self.parenthesized();
        let _ = self.eat(TypeScriptKind::Semicolon);
        self.events.finish();
    }

    fn iterates(&self) -> bool {
        let mut position = self.ahead_position(1);
        let mut depth = 0_u32;

        if self.kind_at(position) == Some(TypeScriptKind::AwaitKeyword) {
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

            if depth == 1 && matches!(kind, TypeScriptKind::InKeyword | TypeScriptKind::OfKeyword) {
                return true;
            }

            if depth == 1 && kind == TypeScriptKind::Semicolon {
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

        self.open(TypeScriptKind::ForStatement);
        self.bump();
        self.expect(TypeScriptKind::ParenOpen, SyntaxErrorKind::UnexpectedToken);

        if self.at(TypeScriptKind::Semicolon) {
            self.wrap(TypeScriptKind::EmptyStatement);
        } else if declares(self.current().unwrap_or(TypeScriptKind::ErrorToken)) {
            self.declaration();
        } else {
            self.expression();
            let _ = self.eat(TypeScriptKind::Semicolon);
        }

        if self.at(TypeScriptKind::Semicolon) {
            self.wrap(TypeScriptKind::EmptyStatement);
        } else {
            self.expression();
            let _ = self.eat(TypeScriptKind::Semicolon);
        }

        if !self.at(TypeScriptKind::ParenClose) {
            self.expression();
        }

        let _ = self.eat(TypeScriptKind::ParenClose);
        self.statement();
        self.events.finish();
    }

    fn for_in_statement(&mut self) {
        self.open(TypeScriptKind::ForInStatement);
        self.bump();
        let _ = self.eat(TypeScriptKind::AwaitKeyword);
        self.expect(TypeScriptKind::ParenOpen, SyntaxErrorKind::UnexpectedToken);

        if self.at(TypeScriptKind::AwaitKeyword) && self.iterates_a_resource(1) {
            self.bump();
        }

        if declares(self.current().unwrap_or(TypeScriptKind::ErrorToken))
            || self.iterates_a_resource(0)
        {
            self.bump();
        }

        self.pattern();

        if !self.eat(TypeScriptKind::InKeyword) {
            let _ = self.eat(TypeScriptKind::OfKeyword);
        }

        self.expression();
        let _ = self.eat(TypeScriptKind::ParenClose);
        self.statement();
        self.events.finish();
    }

    fn switch_statement(&mut self) {
        self.open(TypeScriptKind::SwitchStatement);
        self.bump();
        self.parenthesized();
        self.switch_body();
        self.events.finish();
    }

    fn switch_body(&mut self) {
        self.open(TypeScriptKind::SwitchBody);
        self.expect(TypeScriptKind::BraceOpen, SyntaxErrorKind::UnexpectedToken);

        for _ in 0..self.steps() {
            self.skip_trivia();

            let Some(kind) = self.current() else {
                break;
            };

            if kind == TypeScriptKind::BraceClose {
                break;
            }

            let before = self.position;

            if kind == TypeScriptKind::CaseKeyword {
                self.switch_case(TypeScriptKind::SwitchCase);
            } else if kind == TypeScriptKind::DefaultKeyword {
                self.switch_case(TypeScriptKind::SwitchDefault);
            } else {
                self.statement();
            }

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(TypeScriptKind::BraceClose);
        self.events.finish();
    }

    fn switch_case(&mut self, kind: TypeScriptKind) {
        self.open(kind);
        self.bump();

        if kind == TypeScriptKind::SwitchCase {
            self.expression();
        }

        self.expect(TypeScriptKind::Colon, SyntaxErrorKind::ExpectedColon);

        for _ in 0..self.steps() {
            self.skip_trivia();

            let Some(held) = self.current() else {
                break;
            };

            if matches!(
                held,
                TypeScriptKind::BraceClose
                    | TypeScriptKind::CaseKeyword
                    | TypeScriptKind::DefaultKeyword
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
        self.open(TypeScriptKind::TryStatement);
        self.bump();
        self.statement_block();

        if self.at(TypeScriptKind::CatchKeyword) {
            self.open(TypeScriptKind::CatchClause);
            self.bump();

            if self.eat(TypeScriptKind::ParenOpen) {
                self.pattern();
                self.type_annotation();
                let _ = self.eat(TypeScriptKind::ParenClose);
            }

            self.statement_block();
            self.events.finish();
        }

        if self.at(TypeScriptKind::FinallyKeyword) {
            self.open(TypeScriptKind::FinallyClause);
            self.bump();
            self.statement_block();
            self.events.finish();
        }

        self.events.finish();
    }

    fn return_statement(&mut self) {
        self.open(TypeScriptKind::ReturnStatement);
        self.bump();

        if !self.breaks_line() && self.starts_expression(0) {
            self.expression();
        }

        let _ = self.eat(TypeScriptKind::Semicolon);
        self.events.finish();
    }

    fn throw_statement(&mut self) {
        self.open(TypeScriptKind::ThrowStatement);
        self.bump();
        self.expression();
        let _ = self.eat(TypeScriptKind::Semicolon);
        self.events.finish();
    }

    fn jump_statement(&mut self, kind: TypeScriptKind) {
        self.open(kind);
        self.bump();

        if !self.breaks_line() && is_name(self.current().unwrap_or(TypeScriptKind::ErrorToken)) {
            self.wrap(TypeScriptKind::StatementIdentifier);
        }

        let _ = self.eat(TypeScriptKind::Semicolon);
        self.events.finish();
    }

    fn debugger_statement(&mut self) {
        self.open(TypeScriptKind::DebuggerStatement);
        self.bump();
        let _ = self.eat(TypeScriptKind::Semicolon);
        self.events.finish();
    }

    fn labeled_statement(&mut self) {
        self.open(TypeScriptKind::LabeledStatement);
        self.wrap(TypeScriptKind::StatementIdentifier);
        self.expect(TypeScriptKind::Colon, SyntaxErrorKind::ExpectedColon);
        self.statement();
        self.events.finish();
    }

    fn import_statement(&mut self) {
        self.open(TypeScriptKind::ImportStatement);
        self.bump();

        if self.at(TypeScriptKind::String) {
            self.wrap(TypeScriptKind::StringNode);
        } else if self.opens_a_name(0) && self.ahead(1) == Some(TypeScriptKind::Equal) {
            self.open(TypeScriptKind::ImportRequireClause);
            self.wrap(TypeScriptKind::IdentifierNode);
            let _ = self.eat(TypeScriptKind::Equal);
            let _ = self.eat_word(b"require");
            let _ = self.eat(TypeScriptKind::ParenOpen);

            if self.at(TypeScriptKind::String) {
                self.wrap(TypeScriptKind::StringNode);
            }

            let _ = self.eat(TypeScriptKind::ParenClose);
            self.events.finish();
        } else {
            self.import_clause();

            if !self.eat_word(b"from") {
                self.record(SyntaxErrorKind::UnexpectedToken);
            }

            if self.at(TypeScriptKind::String) {
                self.wrap(TypeScriptKind::StringNode);
            } else {
                self.record(SyntaxErrorKind::UnexpectedToken);
            }
        }

        self.import_attribute();

        let _ = self.eat(TypeScriptKind::Semicolon);
        self.events.finish();
    }

    fn typed_modifier(&self, follower: &[u8]) -> bool {
        if !self.word(b"type") {
            return false;
        }

        if self.word_at(self.ahead_position(1), follower) {
            return self.word_at(self.ahead_position(2), follower);
        }

        true
    }

    fn import_attribute(&mut self) {
        if !self.at(TypeScriptKind::WithKeyword) || self.ahead(1) != Some(TypeScriptKind::BraceOpen)
        {
            return;
        }

        self.open(TypeScriptKind::ImportAttribute);
        self.bump();
        self.expression_single();
        self.events.finish();
    }

    fn import_clause(&mut self) {
        if self.typed_modifier(b"from")
            && !matches!(
                self.ahead(1),
                None | Some(TypeScriptKind::Comma | TypeScriptKind::Equal)
            )
        {
            self.bump();
        }

        self.open(TypeScriptKind::ImportClause);

        if self.at(TypeScriptKind::Star) {
            self.namespace_import(TypeScriptKind::NamespaceImport);
        } else if self.at(TypeScriptKind::BraceOpen) {
            self.named_imports();
        } else {
            if is_name(self.current().unwrap_or(TypeScriptKind::ErrorToken)) {
                self.wrap(TypeScriptKind::IdentifierNode);
            }

            if self.eat(TypeScriptKind::Comma) {
                if self.at(TypeScriptKind::Star) {
                    self.namespace_import(TypeScriptKind::NamespaceImport);
                } else {
                    self.named_imports();
                }
            }
        }

        self.events.finish();
    }

    fn namespace_import(&mut self, kind: TypeScriptKind) {
        self.open(kind);
        self.bump();
        let _ = self.eat_word(b"as");

        if is_name(self.current().unwrap_or(TypeScriptKind::ErrorToken)) {
            self.wrap(TypeScriptKind::IdentifierNode);
        }

        self.events.finish();
    }

    fn named_imports(&mut self) {
        self.specifier_list(
            TypeScriptKind::NamedImports,
            TypeScriptKind::ImportSpecifier,
        );
    }

    fn specifier_list(&mut self, list: TypeScriptKind, item: TypeScriptKind) {
        self.open(list);
        self.expect(TypeScriptKind::BraceOpen, SyntaxErrorKind::UnexpectedToken);

        for _ in 0..self.steps() {
            self.skip_trivia();

            if self.at(TypeScriptKind::BraceClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.open(item);

            if self.typed_modifier(b"as")
                && !matches!(
                    self.ahead(1),
                    None | Some(TypeScriptKind::BraceClose | TypeScriptKind::Comma)
                )
            {
                self.bump();
            }

            self.specifier_name();

            if self.eat_word(b"as") {
                self.specifier_name();
            }

            self.events.finish();

            if !self.eat(TypeScriptKind::Comma) {
                break;
            }

            if self.position == before {
                break;
            }
        }

        let _ = self.eat(TypeScriptKind::BraceClose);
        self.events.finish();
    }

    fn specifier_name(&mut self) {
        let Some(kind) = self.current() else {
            return;
        };

        if kind == TypeScriptKind::String {
            self.wrap(TypeScriptKind::StringNode);

            return;
        }

        if is_property_name(kind) {
            self.wrap(TypeScriptKind::IdentifierNode);
        }
    }

    fn export_statement(&mut self) {
        let checkpoint = self.anchor();

        self.export_at(checkpoint);
    }

    fn export_at(&mut self, checkpoint: Checkpoint) {
        self.bump();

        if self.at(TypeScriptKind::Star) {
            if self.word_at(self.ahead_position(1), b"as") {
                self.namespace_import(TypeScriptKind::NamespaceExport);
            } else {
                self.bump();
            }

            let _ = self.eat_word(b"from");

            if self.at(TypeScriptKind::String) {
                self.wrap(TypeScriptKind::StringNode);
            }
        } else if self.at(TypeScriptKind::BraceOpen)
            || (self.word(b"type") && self.ahead(1) == Some(TypeScriptKind::BraceOpen))
        {
            let _ = self.eat_word(b"type");

            self.specifier_list(
                TypeScriptKind::ExportClause,
                TypeScriptKind::ExportSpecifier,
            );

            let _ = self.eat_word(b"from");

            if self.at(TypeScriptKind::String) {
                self.wrap(TypeScriptKind::StringNode);
            }
        } else if self.at(TypeScriptKind::DefaultKeyword) {
            self.bump();
            self.export_default();
        } else if self.word(b"namespace") && self.opens_a_name(1) {
            self.internal_module();
        } else if self.at(TypeScriptKind::Equal) {
            self.bump();
            self.expression_single();
        } else {
            self.statement();
        }

        let _ = self.eat(TypeScriptKind::Semicolon);

        self.events
            .start_at(checkpoint, TypeScriptKind::ExportStatement);
        self.events.finish();
    }

    fn export_default(&mut self) {
        let kind = self.current().unwrap_or(TypeScriptKind::ErrorToken);

        if kind == TypeScriptKind::FunctionKeyword
            || (kind == TypeScriptKind::AsyncKeyword
                && self.ahead(1) == Some(TypeScriptKind::FunctionKeyword))
        {
            if self.names_a_function() {
                self.function_declaration();
            } else {
                self.function_expression();
            }

            return;
        }

        if kind == TypeScriptKind::ClassKeyword {
            let held = if is_name(self.ahead(1).unwrap_or(TypeScriptKind::ErrorToken)) {
                TypeScriptKind::ClassDeclaration
            } else {
                TypeScriptKind::Class
            };

            self.class_body_of(held);

            return;
        }

        if self.word(b"abstract") && self.ahead(1) == Some(TypeScriptKind::ClassKeyword) {
            let checkpoint = self.anchor();

            self.bump();
            self.class_at(checkpoint, TypeScriptKind::AbstractClassDeclaration);

            return;
        }

        self.expression();
    }

    fn names_a_function(&self) -> bool {
        let steps = u32::from(self.at(TypeScriptKind::AsyncKeyword));
        let generator = self.ahead(steps + 1) == Some(TypeScriptKind::Star);
        let at = steps + 1 + u32::from(generator);

        is_name(self.ahead(at).unwrap_or(TypeScriptKind::ErrorToken))
    }

    fn opens_a_name(&self, steps: u32) -> bool {
        is_name(self.ahead(steps).unwrap_or(TypeScriptKind::ErrorToken))
    }

    fn opens_a_module(&self, steps: u32) -> bool {
        self.opens_a_name(steps) || self.ahead(steps) == Some(TypeScriptKind::String)
    }

    fn opens_an_alias(&self) -> bool {
        self.opens_a_name(1)
            && matches!(
                self.ahead(2),
                Some(TypeScriptKind::Equal | TypeScriptKind::Less)
            )
    }

    fn opens_an_import_alias(&self) -> bool {
        self.opens_a_name(1)
            && self.ahead(2) == Some(TypeScriptKind::Equal)
            && !self.word_at(self.ahead_position(3), b"require")
    }

    fn interface_declaration(&mut self) {
        self.open(TypeScriptKind::InterfaceDeclaration);
        self.bump();

        if is_name(self.current().unwrap_or(TypeScriptKind::ErrorToken)) {
            self.wrap(TypeScriptKind::TypeIdentifier);
        }

        self.type_parameters();

        if self.at(TypeScriptKind::ExtendsKeyword) {
            self.open(TypeScriptKind::ExtendsTypeClause);
            self.bump();
            self.type_list();
            self.events.finish();
        }

        self.open(TypeScriptKind::InterfaceBody);
        let _ = self.eat(TypeScriptKind::BraceOpen);
        self.signature_list(TypeScriptKind::BraceClose);
        let _ = self.eat(TypeScriptKind::BraceClose);
        self.events.finish();
        self.events.finish();
    }

    fn type_alias(&mut self) {
        self.open(TypeScriptKind::TypeAliasDeclaration);
        self.bump();

        if is_name(self.current().unwrap_or(TypeScriptKind::ErrorToken)) {
            self.wrap(TypeScriptKind::TypeIdentifier);
        }

        self.type_parameters();
        let _ = self.eat(TypeScriptKind::Equal);
        self.type_expression();
        let _ = self.eat(TypeScriptKind::Semicolon);
        self.events.finish();
    }

    fn enum_declaration(&mut self) {
        self.open(TypeScriptKind::EnumDeclaration);
        let _ = self.eat(TypeScriptKind::ConstKeyword);
        self.bump();

        if is_name(self.current().unwrap_or(TypeScriptKind::ErrorToken)) {
            self.wrap(TypeScriptKind::IdentifierNode);
        }

        self.open(TypeScriptKind::EnumBody);
        let _ = self.eat(TypeScriptKind::BraceOpen);

        for _ in 0..self.steps() {
            self.skip_trivia();

            if self.at(TypeScriptKind::BraceClose) || self.current().is_none() {
                break;
            }

            if self.eat(TypeScriptKind::Comma) {
                continue;
            }

            let before = self.position;

            self.enum_member();

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(TypeScriptKind::BraceClose);
        self.events.finish();
        self.events.finish();
    }

    fn enum_member(&mut self) {
        let checkpoint = self.anchor();

        self.property_key();

        if !self.at(TypeScriptKind::Equal) {
            return;
        }

        self.bump();
        self.expression_single();

        self.events
            .start_at(checkpoint, TypeScriptKind::EnumAssignment);
        self.events.finish();
    }

    fn ambient_declaration(&mut self) {
        self.open(TypeScriptKind::AmbientDeclaration);
        self.bump();

        if self.word(b"global") {
            self.bump();
            self.statement_block();
            self.events.finish();

            return;
        }

        if self.word(b"module") && self.opens_a_module(1) {
            self.module_declaration();
            self.events.finish();

            return;
        }

        if self.word(b"namespace") && self.opens_a_name(1) {
            self.internal_module();
            self.events.finish();

            return;
        }

        self.statement();
        self.events.finish();
    }

    fn abstract_class(&mut self) {
        let checkpoint = self.anchor();

        self.abstract_class_at(checkpoint);
    }

    fn abstract_class_at(&mut self, checkpoint: Checkpoint) {
        self.bump();
        self.class_at(checkpoint, TypeScriptKind::AbstractClassDeclaration);
    }

    fn internal_module(&mut self) {
        self.open(TypeScriptKind::InternalModule);
        self.bump();
        self.module_name();
        self.statement_block();
        self.events.finish();
    }

    fn module_declaration(&mut self) {
        self.open(TypeScriptKind::Module);
        self.bump();
        self.module_name();

        if self.at(TypeScriptKind::BraceOpen) {
            self.statement_block();
        }

        self.events.finish();
    }

    fn module_name(&mut self) {
        if self.at(TypeScriptKind::String) {
            self.wrap(TypeScriptKind::StringNode);

            return;
        }

        self.type_reference(TypeScriptKind::IdentifierNode);
    }

    fn import_alias(&mut self) {
        self.open(TypeScriptKind::ImportAlias);
        self.bump();

        if is_name(self.current().unwrap_or(TypeScriptKind::ErrorToken)) {
            self.wrap(TypeScriptKind::IdentifierNode);
        }

        let _ = self.eat(TypeScriptKind::Equal);
        self.type_reference(TypeScriptKind::IdentifierNode);
        let _ = self.eat(TypeScriptKind::Semicolon);
        self.events.finish();
    }

    fn type_expression(&mut self) {
        if self.nesting >= NEST_DEPTH_MAX {
            self.outcome = Structure::TooDeep;
            self.emit();

            return;
        }

        self.nesting += 1;
        self.type_conditional();
        self.nesting -= 1;
    }

    fn type_conditional(&mut self) {
        let checkpoint = self.anchor();

        self.type_union();

        if !self.at(TypeScriptKind::ExtendsKeyword) {
            return;
        }

        self.bump();
        self.type_union();

        if self.eat(TypeScriptKind::Question) {
            self.type_expression();
            let _ = self.eat(TypeScriptKind::Colon);
            self.type_expression();
        }

        self.events
            .start_at(checkpoint, TypeScriptKind::ConditionalType);
        self.events.finish();
    }

    fn type_union(&mut self) {
        if self.word(b"readonly") {
            self.readonly_type();

            return;
        }

        let checkpoint = self.anchor();
        let leading = self.eat(TypeScriptKind::Bar);

        self.type_intersection();

        if leading {
            self.events.start_at(checkpoint, TypeScriptKind::UnionType);
            self.events.finish();
        }

        for _ in 0..self.steps() {
            if !self.at(TypeScriptKind::Bar) {
                break;
            }

            self.bump();

            if self.word(b"readonly") {
                self.readonly_type();
                self.events.start_at(checkpoint, TypeScriptKind::UnionType);
                self.events.finish();

                break;
            }

            self.type_intersection();
            self.events.start_at(checkpoint, TypeScriptKind::UnionType);
            self.events.finish();
        }
    }

    fn readonly_type(&mut self) {
        if self.nesting >= NEST_DEPTH_MAX {
            self.outcome = Structure::TooDeep;
            self.emit();

            return;
        }

        let checkpoint = self.anchor();

        self.nesting += 1;
        self.bump();
        self.type_union();
        self.nesting -= 1;

        self.events
            .start_at(checkpoint, TypeScriptKind::ReadonlyType);
        self.events.finish();
    }

    fn type_intersection(&mut self) {
        let checkpoint = self.anchor();
        let leading = self.eat(TypeScriptKind::Ampersand);

        self.type_operand();

        if leading {
            self.events
                .start_at(checkpoint, TypeScriptKind::IntersectionType);
            self.events.finish();
        }

        for _ in 0..self.steps() {
            if !self.at(TypeScriptKind::Ampersand) {
                break;
            }

            self.bump();
            self.type_operand();

            self.events
                .start_at(checkpoint, TypeScriptKind::IntersectionType);
            self.events.finish();
        }
    }

    fn type_operand(&mut self) {
        if self.type_prefix() {
            return;
        }

        self.type_postfix();
    }

    fn type_prefix(&mut self) -> bool {
        if self.word(b"keyof") {
            self.open(TypeScriptKind::IndexTypeQuery);
            self.bump();
            self.type_operand();
            self.events.finish();

            return true;
        }

        if self.word(b"readonly") {
            self.open(TypeScriptKind::ReadonlyType);
            self.bump();
            self.type_operand();
            self.events.finish();

            return true;
        }

        if self.word(b"infer") {
            self.open(TypeScriptKind::InferType);
            self.bump();

            if is_name(self.current().unwrap_or(TypeScriptKind::ErrorToken)) {
                self.wrap(TypeScriptKind::TypeIdentifier);
            }

            if self.at(TypeScriptKind::ExtendsKeyword) {
                self.bump();
                self.type_union();
            }

            self.events.finish();

            return true;
        }

        if self.at(TypeScriptKind::TypeofKeyword) {
            let checkpoint = self.anchor();

            self.open(TypeScriptKind::TypeQuery);
            self.bump();

            let target = self.anchor();

            self.query_target();

            if self.at(TypeScriptKind::Less) && self.type_arguments_ahead() {
                self.type_arguments();

                self.events
                    .start_at(target, TypeScriptKind::InstantiationExpression);
                self.events.finish();
            }

            self.events.finish();
            self.type_trailers(checkpoint);

            return true;
        }

        if self.word(b"unique") && self.word_at(self.ahead_position(1), b"symbol") {
            let checkpoint = self.anchor();

            self.bump();
            self.bump();

            self.events
                .start_at(checkpoint, TypeScriptKind::PredefinedType);
            self.events.finish();

            return true;
        }

        if self.at(TypeScriptKind::NewKeyword) {
            self.constructor_type();

            return true;
        }

        false
    }

    fn constructor_type(&mut self) {
        self.open(TypeScriptKind::ConstructorType);
        self.bump();
        self.type_parameters();
        self.formal_parameters();
        let _ = self.eat(TypeScriptKind::Arrow);
        self.type_return();
        self.events.finish();
    }

    fn type_postfix(&mut self) {
        let checkpoint = self.anchor();

        self.type_primary();
        self.type_trailers(checkpoint);
    }

    fn type_trailers(&mut self, checkpoint: Checkpoint) {
        for _ in 0..self.steps() {
            if !self.at(TypeScriptKind::BracketOpen) {
                break;
            }

            self.bump();

            if self.eat(TypeScriptKind::BracketClose) {
                self.events.start_at(checkpoint, TypeScriptKind::ArrayType);
                self.events.finish();

                continue;
            }

            self.type_expression();
            let _ = self.eat(TypeScriptKind::BracketClose);
            self.events.start_at(checkpoint, TypeScriptKind::LookupType);
            self.events.finish();
        }
    }

    fn type_primary(&mut self) {
        let returning = core::mem::take(&mut self.returning);

        let Some(kind) = self.current() else {
            return;
        };

        if kind == TypeScriptKind::ParenOpen {
            self.type_paren(returning);

            return;
        }

        if kind == TypeScriptKind::Less && !returning {
            self.open(TypeScriptKind::FunctionType);
            self.type_parameters();
            self.formal_parameters();
            let _ = self.eat(TypeScriptKind::Arrow);
            self.type_return();
            self.events.finish();

            return;
        }

        if kind == TypeScriptKind::BraceOpen {
            self.object_type();

            return;
        }

        if kind == TypeScriptKind::BracketOpen {
            self.tuple_type();

            return;
        }

        self.type_leaf(kind);
    }

    fn type_leaf(&mut self, kind: TypeScriptKind) {
        if kind == TypeScriptKind::ThisKeyword {
            self.wrap(TypeScriptKind::ThisType);

            return;
        }

        if kind == TypeScriptKind::Star {
            self.wrap(TypeScriptKind::ExistentialType);

            return;
        }

        if kind == TypeScriptKind::TemplateStart {
            self.template_literal_type();

            return;
        }

        if kind == TypeScriptKind::Question {
            self.open(TypeScriptKind::FlowMaybeType);
            self.bump();
            self.type_operand();
            self.events.finish();

            return;
        }

        if matches!(kind, TypeScriptKind::Minus | TypeScriptKind::Plus) {
            self.open(TypeScriptKind::LiteralType);
            self.open(TypeScriptKind::UnaryExpression);
            self.bump();

            if self.at(TypeScriptKind::Number) {
                self.wrap(TypeScriptKind::NumberNode);
            }

            self.events.finish();
            self.events.finish();

            return;
        }

        if kind == TypeScriptKind::ImportKeyword {
            let checkpoint = self.anchor();

            self.query_target();

            if self.at(TypeScriptKind::Less) && self.type_arguments_ahead() {
                self.type_arguments();

                self.events
                    .start_at(checkpoint, TypeScriptKind::GenericType);
                self.events.finish();
            }

            return;
        }

        if is_literal_type(kind) {
            self.open(TypeScriptKind::LiteralType);
            self.wrap(literal_kind(kind));
            self.events.finish();

            return;
        }

        if is_name(kind) || kind == TypeScriptKind::VoidKeyword {
            self.type_reference(TypeScriptKind::TypeIdentifier);

            return;
        }

        self.emit();
    }

    fn type_paren(&mut self, returning: bool) {
        let held = if returning {
            !self.arrow_follows(self.significant(self.position))
        } else {
            false
        };

        if !held && self.arrow_ahead(self.significant(self.position)) {
            self.open(TypeScriptKind::FunctionType);
            self.formal_parameters();
            let _ = self.eat(TypeScriptKind::Arrow);
            self.type_return();
            self.events.finish();

            return;
        }

        self.open(TypeScriptKind::ParenthesizedType);
        self.bump();
        self.type_expression();
        let _ = self.eat(TypeScriptKind::ParenClose);
        self.events.finish();
    }

    fn type_reference(&mut self, leaf: TypeScriptKind) {
        let position = self.significant(self.position);

        if leaf == TypeScriptKind::TypeIdentifier
            && (predefined_of(self.text_at(position)) || self.at(TypeScriptKind::VoidKeyword))
        {
            self.wrap(TypeScriptKind::PredefinedType);

            return;
        }

        let checkpoint = self.anchor();
        let segments = self.segments_ahead();

        self.wrap(if segments == 1 {
            leaf
        } else {
            TypeScriptKind::IdentifierNode
        });

        let typed = leaf == TypeScriptKind::TypeIdentifier;

        for index in 1..segments {
            self.bump();

            if index + 1 == segments && typed {
                self.wrap(TypeScriptKind::TypeIdentifier);

                self.events
                    .start_at(checkpoint, TypeScriptKind::NestedTypeIdentifier);
            } else {
                self.wrap(TypeScriptKind::PropertyIdentifier);

                let inner = typed && index + 2 < segments;

                self.events.start_at(
                    checkpoint,
                    if inner {
                        TypeScriptKind::MemberExpression
                    } else {
                        TypeScriptKind::NestedIdentifier
                    },
                );
            }

            self.events.finish();
        }

        if self.at(TypeScriptKind::Less) && self.type_arguments_ahead() {
            self.type_arguments();

            self.events
                .start_at(checkpoint, TypeScriptKind::GenericType);
            self.events.finish();
        }
    }

    fn query_target(&mut self) {
        let checkpoint = self.anchor();

        if self.at(TypeScriptKind::ImportKeyword) {
            self.wrap(TypeScriptKind::ImportNode);

            if self.at(TypeScriptKind::ParenOpen) {
                self.argument_list();

                self.events
                    .start_at(checkpoint, TypeScriptKind::CallExpression);
                self.events.finish();
            }

            self.query_trailers(checkpoint);

            return;
        }

        if self.at(TypeScriptKind::ThisKeyword) {
            self.wrap(TypeScriptKind::This);
            self.query_trailers(checkpoint);

            return;
        }

        if !is_property_name(self.current().unwrap_or(TypeScriptKind::ErrorToken)) {
            return;
        }

        self.wrap(TypeScriptKind::IdentifierNode);
        self.query_trailers(checkpoint);
    }

    fn query_trailers(&mut self, checkpoint: Checkpoint) {
        for _ in 0..self.steps() {
            if !self.at(TypeScriptKind::Dot) {
                break;
            }

            self.bump();

            if is_property_name(self.current().unwrap_or(TypeScriptKind::ErrorToken)) {
                self.wrap(TypeScriptKind::PropertyIdentifier);
            }

            self.events
                .start_at(checkpoint, TypeScriptKind::MemberExpression);
            self.events.finish();
        }
    }

    fn segments_ahead(&self) -> u32 {
        let mut position = self.significant(self.position);
        let mut count = 1;

        for _ in 0..self.steps() {
            let after = self.significant(position + 1);

            if self.kind_at(after) != Some(TypeScriptKind::Dot) {
                break;
            }

            let next = self.significant(after + 1);

            if !is_property_name(self.kind_at(next).unwrap_or(TypeScriptKind::ErrorToken)) {
                break;
            }

            position = next;
            count += 1;
        }

        count
    }

    fn type_arguments(&mut self) {
        if !self.at(TypeScriptKind::Less) {
            return;
        }

        self.open(TypeScriptKind::TypeArguments);
        self.bump();

        for _ in 0..self.steps() {
            self.skip_trivia();

            if self.at(TypeScriptKind::Greater) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.type_expression();

            if !self.eat(TypeScriptKind::Comma) {
                break;
            }

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(TypeScriptKind::Greater);
        self.events.finish();
    }

    fn type_parameters(&mut self) {
        if !self.at(TypeScriptKind::Less) {
            return;
        }

        self.open(TypeScriptKind::TypeParameters);
        self.bump();

        for _ in 0..self.steps() {
            self.skip_trivia();

            if self.at(TypeScriptKind::Greater) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.type_parameter();

            if !self.eat(TypeScriptKind::Comma) {
                break;
            }

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(TypeScriptKind::Greater);
        self.events.finish();
    }

    fn type_parameter(&mut self) {
        self.open(TypeScriptKind::TypeParameter);
        self.type_parameter_modifiers();

        if is_name(self.current().unwrap_or(TypeScriptKind::ErrorToken)) {
            self.wrap(TypeScriptKind::TypeIdentifier);
        }

        if self.at(TypeScriptKind::ExtendsKeyword) {
            self.open(TypeScriptKind::Constraint);
            self.bump();
            self.type_expression();
            self.events.finish();
        }

        if self.at(TypeScriptKind::Equal) {
            self.open(TypeScriptKind::DefaultType);
            self.bump();
            self.type_expression();
            self.events.finish();
        }

        self.events.finish();
    }

    fn type_parameter_modifiers(&mut self) {
        for _ in 0..TYPE_MODIFIER_MAX {
            if self.eat(TypeScriptKind::ConstKeyword) {
                continue;
            }

            if !self.at_variance() {
                return;
            }

            self.bump();
        }
    }

    fn at_variance(&self) -> bool {
        if !self.at(TypeScriptKind::InKeyword) && !self.word(b"out") {
            return false;
        }

        let held = self.ahead(1).unwrap_or(TypeScriptKind::ErrorToken);

        is_name(held) || held == TypeScriptKind::InKeyword
    }

    fn tuple_type(&mut self) {
        self.open(TypeScriptKind::TupleType);
        self.bump();

        for _ in 0..self.steps() {
            self.skip_trivia();

            if self.at(TypeScriptKind::BracketClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.tuple_member();

            if !self.eat(TypeScriptKind::Comma) {
                break;
            }

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(TypeScriptKind::BracketClose);
        self.events.finish();
    }

    fn tuple_member(&mut self) {
        if self.labelled_ahead() {
            self.parameter();

            return;
        }

        if self.at(TypeScriptKind::DotDotDot) {
            self.open(TypeScriptKind::RestType);
            self.bump();
            self.type_expression();
            self.events.finish();

            return;
        }

        let checkpoint = self.anchor();

        self.type_expression();

        if self.at(TypeScriptKind::Question) {
            self.bump();

            self.events
                .start_at(checkpoint, TypeScriptKind::OptionalType);
            self.events.finish();
        }
    }

    fn labelled_ahead(&self) -> bool {
        let mut position = self.significant(self.position);

        if self.kind_at(position) == Some(TypeScriptKind::DotDotDot) {
            position = self.significant(position + 1);
        }

        if !is_name(self.kind_at(position).unwrap_or(TypeScriptKind::ErrorToken)) {
            return false;
        }

        let mut after = self.significant(position + 1);

        if self.kind_at(after) == Some(TypeScriptKind::Question) {
            after = self.significant(after + 1);
        }

        self.kind_at(after) == Some(TypeScriptKind::Colon)
    }

    fn object_type(&mut self) {
        self.open(TypeScriptKind::ObjectType);
        self.bump();
        self.signature_list(TypeScriptKind::BraceClose);
        let _ = self.eat(TypeScriptKind::BraceClose);
        self.events.finish();
    }

    fn signature_list(&mut self, closer: TypeScriptKind) {
        for _ in 0..self.steps() {
            self.skip_trivia();

            if self.at(closer) || self.current().is_none() {
                break;
            }

            if self.eat(TypeScriptKind::Semicolon) || self.eat(TypeScriptKind::Comma) {
                continue;
            }

            let before = self.position;

            self.signature();

            if self.position == before {
                self.emit();
            }
        }
    }

    fn signature(&mut self) {
        if self.mapped_modifier_ahead() {
            self.index_signature();

            return;
        }

        if self.at(TypeScriptKind::BracketOpen) && self.index_signature_ahead() {
            self.index_signature();

            return;
        }

        if self.readonly_index_ahead() {
            self.index_signature();

            return;
        }

        if self.at(TypeScriptKind::NewKeyword)
            && !matches!(
                self.ahead(1),
                Some(TypeScriptKind::Less | TypeScriptKind::ParenOpen)
            )
        {
            self.signature_of(TypeScriptKind::PropertySignature);

            return;
        }

        if self.at(TypeScriptKind::NewKeyword) {
            self.open(TypeScriptKind::ConstructSignature);
            self.bump();
            self.type_parameters();
            self.formal_parameters();
            self.return_annotation();
            self.events.finish();

            return;
        }

        if self.at(TypeScriptKind::ParenOpen) || self.at(TypeScriptKind::Less) {
            self.open(TypeScriptKind::CallSignature);
            self.type_parameters();
            self.formal_parameters();
            self.return_annotation();
            self.events.finish();

            return;
        }

        self.signature_of(TypeScriptKind::PropertySignature);
    }

    fn signature_of(&mut self, property: TypeScriptKind) {
        let checkpoint = self.anchor();
        let _ = self.modifiers();

        self.property_key();
        let _ = self.eat(TypeScriptKind::Question);

        if self.at(TypeScriptKind::ParenOpen) || self.at(TypeScriptKind::Less) {
            self.type_parameters();
            self.formal_parameters();
            self.return_annotation();

            self.events
                .start_at(checkpoint, TypeScriptKind::MethodSignature);
            self.events.finish();

            return;
        }

        self.type_annotation();
        self.events.start_at(checkpoint, property);
        self.events.finish();
    }

    fn mapped_modifier_ahead(&self) -> bool {
        matches!(
            self.current(),
            Some(TypeScriptKind::Minus | TypeScriptKind::Plus)
        ) && self.word_at(self.ahead_position(1), b"readonly")
            && self.ahead(2) == Some(TypeScriptKind::BracketOpen)
    }

    fn readonly_index_ahead(&self) -> bool {
        self.word(b"readonly")
            && self.ahead(1) == Some(TypeScriptKind::BracketOpen)
            && is_name(
                self.kind_at(self.ahead_position(2))
                    .unwrap_or(TypeScriptKind::ErrorToken),
            )
            && matches!(
                self.kind_at(self.ahead_position(3)),
                Some(TypeScriptKind::Colon | TypeScriptKind::InKeyword)
            )
    }

    fn index_signature(&mut self) {
        self.open(TypeScriptKind::IndexSignature);

        if self.mapped_modifier_ahead() {
            self.bump();
            self.bump();
        } else if self.word(b"readonly") {
            self.bump();
        }

        self.bump();

        if self.mapped_ahead() {
            self.open(TypeScriptKind::MappedTypeClause);

            if is_name(self.current().unwrap_or(TypeScriptKind::ErrorToken)) {
                self.wrap(TypeScriptKind::TypeIdentifier);
            }

            let _ = self.eat(TypeScriptKind::InKeyword);
            self.type_expression();

            if self.eat_word(b"as") {
                self.type_expression();
            }

            self.events.finish();
        } else {
            if is_name(self.current().unwrap_or(TypeScriptKind::ErrorToken)) {
                self.wrap(TypeScriptKind::IdentifierNode);
            }

            if self.eat(TypeScriptKind::Colon) {
                self.type_expression();
            }
        }

        let _ = self.eat(TypeScriptKind::BracketClose);

        if matches!(
            self.current(),
            Some(TypeScriptKind::Minus | TypeScriptKind::Plus)
        ) && self.ahead(1) == Some(TypeScriptKind::Question)
        {
            let adding = self.at(TypeScriptKind::Plus);

            let kind = if adding {
                TypeScriptKind::AddingTypeAnnotation
            } else {
                TypeScriptKind::OmittingTypeAnnotation
            };

            self.open(kind);
            self.bump();
            self.bump();
            let _ = self.eat(TypeScriptKind::Colon);
            self.type_expression();
            self.events.finish();
        } else if self.at(TypeScriptKind::Question) {
            self.open(TypeScriptKind::OptingTypeAnnotation);
            self.bump();
            let _ = self.eat(TypeScriptKind::Colon);
            self.type_expression();
            self.events.finish();
        } else {
            self.type_annotation();
        }

        self.events.finish();
    }

    fn index_signature_ahead(&self) -> bool {
        let position = self.ahead_position(1);

        if !is_name(self.kind_at(position).unwrap_or(TypeScriptKind::ErrorToken)) {
            return false;
        }

        matches!(
            self.kind_at(self.significant(position + 1)),
            Some(TypeScriptKind::Colon | TypeScriptKind::InKeyword)
        )
    }

    fn mapped_ahead(&self) -> bool {
        let position = self.significant(self.position);

        is_name(self.kind_at(position).unwrap_or(TypeScriptKind::ErrorToken))
            && self.kind_at(self.significant(position + 1)) == Some(TypeScriptKind::InKeyword)
    }

    fn template_literal_type(&mut self) {
        self.open(TypeScriptKind::TemplateLiteralType);
        self.bump();

        for _ in 0..self.steps() {
            let Some(kind) = self.current() else {
                break;
            };

            if kind == TypeScriptKind::TemplateEnd {
                self.bump();

                break;
            }

            if kind == TypeScriptKind::SubstitutionStart {
                self.open(TypeScriptKind::TemplateType);
                self.bump();
                self.type_expression();
                let _ = self.eat(TypeScriptKind::BraceClose);
                self.events.finish();

                continue;
            }

            self.bump();
        }

        self.events.finish();
    }

    fn type_annotation(&mut self) {
        if !self.at(TypeScriptKind::Colon) {
            return;
        }

        self.open(TypeScriptKind::TypeAnnotation);
        self.bump();
        self.type_expression();
        self.events.finish();
    }

    fn return_annotation(&mut self) {
        if !self.at(TypeScriptKind::Colon) {
            return;
        }

        let after = self.ahead_position(1);

        if self.word_at(after, b"asserts") && self.asserts_ahead(self.significant(after + 1)) {
            self.open(TypeScriptKind::AssertsAnnotation);
            self.bump();
            self.open(TypeScriptKind::Asserts);
            self.bump();

            if self.predicate_ahead(self.significant(self.position)) {
                self.type_predicate();
            } else {
                match self.current().unwrap_or(TypeScriptKind::ErrorToken) {
                    TypeScriptKind::ThisKeyword => self.wrap(TypeScriptKind::This),
                    current if is_name(current) => self.wrap(TypeScriptKind::IdentifierNode),
                    _ => {}
                }
            }

            self.events.finish();
            self.events.finish();

            return;
        }

        if self.predicate_ahead(after) {
            self.open(TypeScriptKind::TypePredicateAnnotation);
            self.bump();
            self.type_predicate();
            self.events.finish();

            return;
        }

        self.type_annotation();
    }

    fn asserts_ahead(&self, position: u32) -> bool {
        is_name(self.kind_at(position).unwrap_or(TypeScriptKind::ErrorToken))
            || self.kind_at(position) == Some(TypeScriptKind::ThisKeyword)
    }

    fn predicate_ahead(&self, position: u32) -> bool {
        let named = is_name(self.kind_at(position).unwrap_or(TypeScriptKind::ErrorToken))
            || self.kind_at(position) == Some(TypeScriptKind::ThisKeyword);

        named && self.word_at(self.significant(position + 1), b"is")
    }

    fn type_return(&mut self) {
        if self.predicate_ahead(self.significant(self.position)) {
            self.type_predicate();

            return;
        }

        if self.word(b"asserts") && self.asserts_ahead(self.ahead_position(1)) {
            self.open(TypeScriptKind::Asserts);
            self.bump();

            if self.predicate_ahead(self.significant(self.position)) {
                self.type_predicate();
            } else {
                let current = self.current().unwrap_or(TypeScriptKind::ErrorToken);

                if is_name(current) {
                    self.wrap(TypeScriptKind::IdentifierNode);
                }
            }

            self.events.finish();

            return;
        }

        self.type_expression();
    }

    fn type_predicate(&mut self) {
        self.open(TypeScriptKind::TypePredicate);

        match self.current().unwrap_or(TypeScriptKind::ErrorToken) {
            TypeScriptKind::ThisKeyword => self.wrap(TypeScriptKind::This),
            current if is_name(current) => self.wrap(TypeScriptKind::IdentifierNode),
            _ => {}
        }

        let _ = self.eat_word(b"is");
        self.type_expression();
        self.events.finish();
    }

    fn type_arguments_ahead(&self) -> bool {
        self.type_arguments_end() != NONE_POSITION
    }

    fn type_arguments_end(&self) -> u32 {
        self.type_arguments_end_at(self.significant(self.position))
    }

    fn type_arguments_end_at(&self, from: u32) -> u32 {
        if from < self.plain_failure.get() {
            return NONE_POSITION;
        }

        let mut angles = 0_u32;
        let mut nested = 0_u32;
        let mut plain = true;

        for position in from..from.saturating_add(SCAN_STEP_MAX) {
            let Some(kind) = self.kind_at(position) else {
                return NONE_POSITION;
            };

            if is_opener(kind) {
                nested += 1;
                plain = false;

                continue;
            }

            if is_closer(kind) {
                if nested == 0 {
                    self.plain_mark(plain, position);

                    return NONE_POSITION;
                }

                nested -= 1;

                continue;
            }

            if nested > 0 {
                continue;
            }

            if kind == TypeScriptKind::Less {
                angles += 1;

                continue;
            }

            if kind == TypeScriptKind::Greater {
                angles -= 1;
                plain = false;

                if angles == 0 {
                    return position + 1;
                }

                continue;
            }

            if matches!(kind, TypeScriptKind::Arrow | TypeScriptKind::Equal) {
                continue;
            }

            if !(is_type_token(kind) || is_property_name(kind) && self.follows_a_dot(position)) {
                self.plain_mark(plain, position);

                return NONE_POSITION;
            }
        }

        NONE_POSITION
    }

    fn follows_a_dot(&self, position: u32) -> bool {
        self.behind(position) == Some(TypeScriptKind::Dot)
    }

    fn behind(&self, position: u32) -> Option<TypeScriptKind> {
        let mut at = position;

        for _ in 0..SCAN_STEP_MAX {
            if at == 0 {
                return None;
            }

            at -= 1;

            match self.kind_at(at) {
                Some(TypeScriptKind::Comment) => {}
                Some(kind) => return Some(kind),
                None => return None,
            }
        }

        None
    }

    fn plain_mark(&self, plain: bool, position: u32) {
        if plain {
            self.plain_failure.set(position);
        }
    }

    fn call_arguments_ahead(&self) -> bool {
        self.call_arguments_ahead_at(self.significant(self.position))
    }

    fn call_arguments_ahead_at(&self, from: u32) -> bool {
        let end = self.type_arguments_end_at(from);

        if end == NONE_POSITION {
            return false;
        }

        matches!(
            self.kind_at(self.significant(end)),
            None | Some(
                TypeScriptKind::BraceClose
                    | TypeScriptKind::BracketClose
                    | TypeScriptKind::Comma
                    | TypeScriptKind::ParenClose
                    | TypeScriptKind::ParenOpen
                    | TypeScriptKind::Semicolon
                    | TypeScriptKind::TemplateStart
            )
        )
    }

    fn parameter(&mut self) {
        let checkpoint = self.anchor();

        self.parameter_modifiers();
        self.pattern();

        let optional = self.at(TypeScriptKind::Question);

        if optional {
            self.bump();
        }

        self.type_annotation();

        if self.eat(TypeScriptKind::Equal) {
            self.expression_single();
        }

        let kind = if optional {
            TypeScriptKind::OptionalParameter
        } else {
            TypeScriptKind::RequiredParameter
        };

        self.events.start_at(checkpoint, kind);
        self.events.finish();
    }

    fn parameter_modifiers(&mut self) {
        for _ in 0..8 {
            if self.at(TypeScriptKind::At) {
                self.open(TypeScriptKind::Decorator);
                self.bump();
                self.expression_single();
                self.events.finish();

                continue;
            }

            if self.accessibility_here() {
                self.wrap(TypeScriptKind::AccessibilityModifier);

                continue;
            }

            if self.word(b"override") && !self.opens_a_type() {
                self.wrap(TypeScriptKind::OverrideModifier);

                continue;
            }

            if self.word(b"readonly") && !self.opens_a_type() {
                self.bump();

                continue;
            }

            break;
        }
    }

    fn accessibility_here(&self) -> bool {
        (self.word(b"private") || self.word(b"protected") || self.word(b"public"))
            && !self.opens_a_type()
    }

    fn opens_a_type(&self) -> bool {
        matches!(
            self.ahead(1),
            None | Some(
                TypeScriptKind::BracketClose
                    | TypeScriptKind::Colon
                    | TypeScriptKind::Comma
                    | TypeScriptKind::Equal
                    | TypeScriptKind::Less
                    | TypeScriptKind::ParenClose
                    | TypeScriptKind::ParenOpen
                    | TypeScriptKind::Question
                    | TypeScriptKind::Semicolon
            )
        )
    }

    fn member_modifiers(&mut self) -> bool {
        let mut abstracted = false;

        for _ in 0..8 {
            if self.accessibility_here() {
                self.wrap(TypeScriptKind::AccessibilityModifier);

                continue;
            }

            if self.word(b"override") && !self.opens_a_type() {
                self.wrap(TypeScriptKind::OverrideModifier);

                continue;
            }

            if (self.word(b"abstract") || self.word(b"declare") || self.word(b"readonly"))
                && !self.opens_a_type()
            {
                abstracted = abstracted || self.word(b"abstract");
                self.bump();

                continue;
            }

            break;
        }

        abstracted
    }
}

pub fn build(
    source: &[u8],
    tokens: &[Token],
    raw: &[TypeScriptKind],
    events: &mut Events<TypeScriptKind>,
    tree: &mut Tree<TypeScriptKind>,
    dialect: Dialect,
) -> Structure {
    assert!(u32::try_from(source.len()).is_ok());
    assert_eq!(tokens.len(), raw.len());

    events.clear();
    tree.clear();

    let mut parser = Parser {
        balanced_ends: [0; BALANCED_SLOT_COUNT as usize],
        balanced_opens: [NONE; BALANCED_SLOT_COUNT as usize],
        dialect,
        events,
        frame_count: 0,
        frames: [Frame::EMPTY; EXPRESSION_DEPTH_MAX as usize],
        nesting: 0,
        outcome: Structure::Complete,
        plain_failure: core::cell::Cell::new(0),
        position: 0,
        raw,
        returning: false,
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
