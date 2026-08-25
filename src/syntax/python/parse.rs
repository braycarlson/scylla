use crate::bounded::{Span, count_of};
use crate::syntax::python::expression::{
    EXPRESSION_DEPTH_MAX,
    Frame,
    POWER_AWAIT,
    POWER_BAR_LEFT,
    POWER_BAR_RIGHT,
    POWER_BARRIER,
    POWER_COMPARE_LEFT,
    POWER_COMPARE_RIGHT,
    POWER_CONDITIONAL_LEFT,
    POWER_CONDITIONAL_RIGHT,
    POWER_NOT,
    POWER_SIGN,
    POWER_STARRED,
    VALUE_COUNT_MAX,
    Variant,
    closer_of,
    infix_of,
    is_contributor,
    is_literal,
    is_piece,
    is_string,
};
use crate::syntax::python::kind::PythonKind;
use crate::syntax::{SyntaxError, SyntaxErrorKind};
use crate::token::Token;
use crate::tree::{Checkpoint, Events, NONE, Structure, Tree, replay};

const AUGMENTED: [PythonKind; 13] = [
    PythonKind::AmpersandEqual,
    PythonKind::AtEqual,
    PythonKind::BarEqual,
    PythonKind::CaretEqual,
    PythonKind::GreaterGreaterEqual,
    PythonKind::LessLessEqual,
    PythonKind::MinusEqual,
    PythonKind::PercentEqual,
    PythonKind::PlusEqual,
    PythonKind::SlashEqual,
    PythonKind::SlashSlashEqual,
    PythonKind::StarEqual,
    PythonKind::StarStarEqual,
];

const CHAIN_DEPTH_MAX: u32 = 256;
const PATTERN_STEP_MAX: u32 = 4_096;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Step {
    Done,
    Operand,
    Operator,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Shape {
    annotation: u32,
    assign: u32,
    augmented: u32,
    end: u32,
}

struct Parser<'source, 'run> {
    brackets: u32,
    events: &'run mut Events<PythonKind>,
    frame_count: u32,
    frames: [Frame; EXPRESSION_DEPTH_MAX as usize],
    outcome: Structure,
    position: u32,
    raw: &'run [PythonKind],
    significant_next: u32,
    source: &'source [u8],
    tokens: &'run [Token],
    tree: &'run mut Tree<PythonKind>,
    value_count: u32,
    values: [Checkpoint; VALUE_COUNT_MAX as usize],
}

const fn is_layout(kind: PythonKind) -> bool {
    matches!(
        kind,
        PythonKind::Comment | PythonKind::Dedent | PythonKind::Indent | PythonKind::Newline
    )
}

const fn is_closer(kind: PythonKind) -> bool {
    matches!(
        kind,
        PythonKind::BraceClose | PythonKind::BracketClose | PythonKind::ParenClose
    )
}

const fn is_opener(kind: PythonKind) -> bool {
    matches!(
        kind,
        PythonKind::BraceOpen | PythonKind::BracketOpen | PythonKind::ParenOpen
    )
}

const fn group_kind(frame: &Frame, seen: u32) -> PythonKind {
    match frame.variant {
        Variant::Brace => {
            if frame.comprehension {
                if frame.dictionary {
                    PythonKind::DictComp
                } else {
                    PythonKind::SetComp
                }
            } else if frame.dictionary || seen == 0 {
                PythonKind::Dict
            } else {
                PythonKind::Set
            }
        }
        Variant::Bracket => {
            if frame.comprehension {
                PythonKind::ListComp
            } else {
                PythonKind::List
            }
        }
        Variant::Call => PythonKind::Call,
        Variant::Paren => {
            if frame.comprehension {
                PythonKind::GeneratorExp
            } else if seen == 1 && frame.elements == 0 {
                PythonKind::Parenthesized
            } else {
                PythonKind::Tuple
            }
        }
        Variant::Subscript => PythonKind::Subscript,
        Variant::Bare
        | Variant::Binary
        | Variant::ClassArgs
        | Variant::Conditional
        | Variant::Formatted
        | Variant::Joined
        | Variant::Keyword
        | Variant::Lambda
        | Variant::Mapping
        | Variant::PatternGroup
        | Variant::Sequence
        | Variant::Top
        | Variant::Unary
        | Variant::Yield => PythonKind::ErrorNode,
    }
}

impl Parser<'_, '_> {
    fn count(&self) -> u32 {
        count_of(self.raw.len())
    }

    fn kind_at(&self, position: u32) -> Option<PythonKind> {
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
            if kind != PythonKind::Comment {
                break;
            }

            position += 1;
        }

        position
    }

    fn current(&self) -> Option<PythonKind> {
        self.kind_at(self.significant(self.position))
    }

    fn ahead(&self, steps: u32) -> Option<PythonKind> {
        self.kind_at(self.ahead_position(steps))
    }

    fn ahead_position(&self, steps: u32) -> u32 {
        let mut position = self.significant(self.position);

        for _ in 0..steps {
            position = self.significant(position + 1);
        }

        position
    }

    fn at(&self, kind: PythonKind) -> bool {
        self.current() == Some(kind)
    }

    fn word(&self, word: &[u8]) -> bool {
        let position = self.significant(self.position);

        self.kind_at(position) == Some(PythonKind::Identifier)
            && self.tokens[position as usize].text(self.source) == word
    }

    fn track(&mut self, kind: PythonKind) {
        if is_opener(kind) {
            self.brackets += 1;
        }

        if is_closer(kind) {
            self.brackets = self.brackets.saturating_sub(1);
        }
    }

    fn emit(&mut self) {
        let Some(kind) = self.kind_at(self.position) else {
            return;
        };

        self.track(kind);

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
        while self.kind_at(self.position) == Some(PythonKind::Comment) {
            self.emit();
        }
    }

    fn bump(&mut self) {
        self.skip_trivia();
        self.emit();
    }

    fn eat(&mut self, kind: PythonKind) -> bool {
        if !self.at(kind) {
            return false;
        }

        self.bump();

        true
    }

    fn expect(&mut self, kind: PythonKind, failure: SyntaxErrorKind) -> bool {
        if self.eat(kind) {
            return true;
        }

        self.record(failure);

        false
    }

    fn wrap(&mut self, kind: PythonKind) {
        self.events.start(kind);
        self.bump();
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

    fn line_end(&self) -> u32 {
        let mut position = self.significant(self.position);
        let mut depth = 0_u32;
        let mut lambdas = 0_u32;

        while let Some(kind) = self.kind_at(position) {
            match Some(kind) {
                Some(_) if is_opener(kind) => depth += 1,
                Some(_) if is_closer(kind) => depth = depth.saturating_sub(1),
                Some(PythonKind::LambdaKeyword) if depth == 0 => lambdas += 1,
                Some(PythonKind::Colon) if depth == 0 && lambdas > 0 => lambdas -= 1,
                Some(PythonKind::Dedent | PythonKind::Newline) => return position,
                Some(PythonKind::Semicolon) if depth == 0 => return position,
                Some(_) | None => {}
            }

            position += 1;
        }

        position
    }

    fn header_colon(&self) -> u32 {
        let mut position = self.significant(self.position);
        let mut depth = 0_u32;
        let mut lambdas = 0_u32;

        while let Some(kind) = self.kind_at(position) {
            match Some(kind) {
                Some(_) if is_opener(kind) => depth += 1,
                Some(_) if is_closer(kind) => depth = depth.saturating_sub(1),
                Some(PythonKind::LambdaKeyword) if depth == 0 => lambdas += 1,
                Some(PythonKind::Colon) if depth == 0 && lambdas > 0 => lambdas -= 1,
                Some(PythonKind::Colon) if depth == 0 => return position,
                Some(PythonKind::Dedent | PythonKind::Newline) => return NONE,
                Some(_) | None => {}
            }

            position += 1;
        }

        NONE
    }

    fn shape(&self) -> Shape {
        let end = self.line_end();
        let mut position = self.significant(self.position);
        let mut depth = 0_u32;
        let mut lambdas = 0_u32;

        let mut found = Shape {
            annotation: NONE,
            assign: NONE,
            augmented: NONE,
            end,
        };

        while position < end {
            let Some(kind) = self.kind_at(position) else {
                break;
            };

            match Some(kind) {
                Some(_) if is_opener(kind) => depth += 1,
                Some(_) if is_closer(kind) => depth = depth.saturating_sub(1),
                Some(PythonKind::LambdaKeyword) if depth == 0 => lambdas += 1,
                Some(PythonKind::Colon) if depth == 0 && lambdas > 0 => lambdas -= 1,
                Some(PythonKind::Colon) if depth == 0 && found.annotation == NONE => {
                    found.annotation = position;
                }
                Some(PythonKind::Equal) if depth == 0 && found.assign == NONE => {
                    found.assign = position;
                }
                Some(_) if depth == 0 && found.augmented == NONE && AUGMENTED.contains(&kind) => {
                    found.augmented = position;
                }
                Some(_) | None => {}
            }

            position += 1;
        }

        found
    }

    fn recover(&mut self) {
        self.events.start(PythonKind::ErrorNode);

        let before = self.position;

        while let Some(kind) = self.kind_at(self.position) {
            if matches!(kind, PythonKind::Dedent) {
                break;
            }

            self.emit();

            if kind == PythonKind::Newline {
                break;
            }
        }

        if self.position == before {
            self.emit();
        }

        self.events.finish();
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

        if frame.variant == Variant::Yield && frame.elements > 0 {
            self.events.start_at(frame.content, PythonKind::Tuple);
            self.events.finish();
        }

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

    fn unary(&mut self, kind: PythonKind, power: u8) -> Step {
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

    fn merges(&self, kind: PythonKind, token: PythonKind) -> bool {
        if self.frame_count == 0 {
            return false;
        }

        let top = self.frames[self.frame_count as usize - 1];

        top.variant == Variant::Binary
            && top.kind == kind
            && (kind == PythonKind::Compare || (kind == PythonKind::BoolOp && top.token == token))
    }

    fn binary(&mut self, kind: PythonKind, token: PythonKind, left: u8, right: u8) -> Step {
        while self.frame_count > 0 && !self.merges(kind, token) {
            let top = self.frames[self.frame_count as usize - 1];

            if top.power == POWER_BARRIER || top.power < left {
                break;
            }

            self.reduce_top();
        }

        if self.value_count == 0 {
            self.bump();

            return Step::Operand;
        }

        if self.merges(kind, token) {
            self.bump();

            return Step::Operand;
        }

        let values = self.value_count - 1;

        let frame = Frame {
            checkpoint: self.values[values as usize],
            kind,
            power: right,
            token,
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
        let opener = self.current().unwrap_or(PythonKind::ParenOpen);
        let bracket = self.anchor();

        self.bump();

        let content = self.anchor();

        let frame = Frame {
            bracket,
            checkpoint,
            closer: closer_of(opener),
            content,
            element: content,
            element_values: self.value_count,
            values: self.value_count,
            variant,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        Step::Operand
    }

    fn close_clause(&mut self, group: u32) {
        if self.frames[group as usize].clause.is_none() {
            return;
        }

        self.events.start_at(
            self.frames[group as usize].clause,
            PythonKind::Comprehension,
        );
        self.events.finish();
        self.frames[group as usize].clause = Checkpoint::NONE;
    }

    fn close_element(&mut self, group: u32) {
        let frame = self.frames[group as usize];

        if frame.variant == Variant::Subscript && frame.slice {
            self.events.start_at(frame.element, PythonKind::Slice);
            self.events.finish();
            self.frames[group as usize].slice = false;
        }
    }

    fn close_group(&mut self, group: u32) {
        self.reduce_above(group + 1);
        self.close_clause(group);
        self.close_element(group);

        let frame = self.frames[group as usize];
        let seen = self.value_count - frame.values;

        self.frame_count = group;

        if frame.variant == Variant::Subscript && frame.elements > 0 {
            self.events.start_at(frame.content, PythonKind::Tuple);
            self.events.finish();
        }

        let kind = group_kind(&frame, seen);
        let generator = frame.variant == Variant::Call && frame.comprehension;

        self.events.start_at(frame.checkpoint, kind);

        if generator {
            self.events
                .start_at(frame.bracket, PythonKind::GeneratorExp);
        }

        self.bump();
        self.events.finish();

        if generator {
            self.events.finish();
        }

        self.value_count = frame.values;
        self.push_value(frame.checkpoint);
    }

    fn expression(&mut self) {
        self.expression_with(true, false);
    }

    fn expression_single(&mut self) {
        self.expression_with(false, false);
    }

    fn expression_target(&mut self) {
        self.expression_with(true, true);
    }

    fn expression_with(&mut self, tuple: bool, no_in: bool) {
        let frames_base = self.frame_count;
        let values_base = self.value_count;
        let checkpoint = self.anchor();

        let frame = Frame {
            checkpoint,
            content: checkpoint,
            element: checkpoint,
            no_in,
            tuple,
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
            self.events.start_at(top.checkpoint, PythonKind::Tuple);
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

        let group = self.innermost_group(base);
        let frame = self.frames[group as usize];

        if frame.variant == Variant::Joined {
            return self.joined_piece(group, kind);
        }

        if frame.variant == Variant::Lambda && frame.stage == 0 {
            return self.lambda_parameter(group, kind);
        }

        if kind == PythonKind::Identifier
            && frame.variant == Variant::Call
            && self.value_count == frame.element_values
            && self.ahead(1) == Some(PythonKind::Equal)
        {
            return self.keyword_argument(group);
        }

        self.operand_of(kind, group)
    }

    fn operand_of(&mut self, kind: PythonKind, group: u32) -> Step {
        if kind == PythonKind::AwaitKeyword {
            return self.unary(PythonKind::Await, POWER_AWAIT);
        }

        if kind == PythonKind::LambdaKeyword {
            return self.open_lambda();
        }

        if matches!(
            kind,
            PythonKind::Minus | PythonKind::Plus | PythonKind::Tilde
        ) {
            return self.unary(PythonKind::UnaryOp, POWER_SIGN);
        }

        if kind == PythonKind::NotKeyword {
            return self.unary(PythonKind::UnaryOp, POWER_NOT);
        }

        if kind == PythonKind::Star {
            return self.unary(PythonKind::Starred, POWER_STARRED);
        }

        if kind == PythonKind::StarStar {
            return self.double_star(group);
        }

        if kind == PythonKind::YieldKeyword {
            return self.open_yield();
        }

        if is_opener(kind) {
            let checkpoint = self.anchor();

            let variant = if kind == PythonKind::BraceOpen {
                Variant::Brace
            } else if kind == PythonKind::BracketOpen {
                Variant::Bracket
            } else {
                Variant::Paren
            };

            return self.open_group(variant, checkpoint);
        }

        if kind == PythonKind::Identifier {
            let checkpoint = self.anchor();

            self.wrap(PythonKind::Name);
            self.push_value(checkpoint);

            return Step::Operator;
        }

        if kind == PythonKind::FStringStart || (is_string(kind) && self.run_has_format()) {
            return self.open_joined(false);
        }

        if is_literal(kind) {
            let checkpoint = self.anchor();

            self.constant(kind);
            self.push_value(checkpoint);

            return Step::Operator;
        }

        Step::Done
    }

    fn run_has_format(&self) -> bool {
        let mut position = self.significant(self.position);

        for _ in 0..CHAIN_DEPTH_MAX {
            match self.kind_at(position) {
                Some(PythonKind::FStringStart) => return true,
                Some(held) if is_string(held) => position = self.significant(position + 1),
                _ => return false,
            }
        }

        false
    }

    fn literal_continues(&self) -> bool {
        let mut position = self.significant(self.position);

        for _ in 0..CHAIN_DEPTH_MAX {
            match self.kind_at(position) {
                Some(PythonKind::FStringEnd | PythonKind::FStringStart) => {
                    position = self.significant(position + 1);
                }
                Some(held) => return is_contributor(held),
                None => return false,
            }
        }

        false
    }

    fn open_joined(&mut self, spec: bool) -> Step {
        let checkpoint = self.anchor();

        if spec {
            self.bump();
        }

        let frame = Frame {
            checkpoint,
            dictionary: spec,
            kind: PythonKind::JoinedStr,
            power: POWER_BARRIER,
            values: self.value_count,
            variant: Variant::Joined,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        Step::Operand
    }

    fn close_literal(&mut self, group: u32) {
        if !self.frames[group as usize].slice {
            return;
        }

        self.events
            .start_at(self.frames[group as usize].element, PythonKind::Constant);
        self.events.finish();
        self.frames[group as usize].slice = false;
    }

    fn close_joined(&mut self, group: u32) {
        self.close_literal(group);

        let frame = self.frames[group as usize];

        self.frame_count = group;

        if frame.dictionary && frame.stage == 1 {
            self.events.start(PythonKind::Constant);
            self.events.finish();
        }

        self.events
            .start_at(frame.checkpoint, PythonKind::JoinedStr);
        self.events.finish();
        self.value_count = frame.values;
        self.push_value(frame.checkpoint);
    }

    fn joined_piece(&mut self, group: u32, kind: PythonKind) -> Step {
        if matches!(kind, PythonKind::FStringEnd | PythonKind::FStringStart) {
            self.bump();

            return Step::Operand;
        }

        if is_contributor(kind) {
            if !self.frames[group as usize].slice {
                self.frames[group as usize].element = self.anchor();
                self.frames[group as usize].slice = true;
            }

            self.bump();
            self.frames[group as usize].stage = 0;

            if !self.literal_continues() {
                self.close_literal(group);
            }

            return Step::Operand;
        }

        if kind == PythonKind::BraceOpen {
            self.close_literal(group);

            let checkpoint = self.anchor();

            self.bump();

            let element = self.anchor();
            let frame = Frame {
                checkpoint,
                element,
                kind: PythonKind::FormattedValue,
                power: POWER_BARRIER,
                values: self.value_count,
                variant: Variant::Formatted,
                ..Frame::EMPTY
            };

            if !self.push_frame(frame) {
                return Step::Done;
            }

            return Step::Operand;
        }

        Step::Done
    }

    fn formatted_step(&mut self, group: u32, kind: PythonKind, base: u32) -> Step {
        if !matches!(
            kind,
            PythonKind::Bang | PythonKind::BraceClose | PythonKind::Colon | PythonKind::Equal
        ) {
            return Step::Done;
        }

        self.reduce_above(group + 1);

        if kind == PythonKind::Equal {
            self.bump();
            self.events
                .start_at(self.frames[group as usize].element, PythonKind::Constant);
            self.events.finish();

            return Step::Operator;
        }

        if kind == PythonKind::Bang {
            self.bump();
            let _ = self.eat(PythonKind::Identifier);

            return Step::Operator;
        }

        if kind == PythonKind::Colon {
            return self.open_joined(true);
        }

        let frame = self.frames[group as usize];

        self.frame_count = group;

        self.events
            .start_at(frame.checkpoint, PythonKind::FormattedValue);

        self.bump();
        self.events.finish();
        self.value_count = frame.values;
        self.push_value(frame.checkpoint);

        let outer = self.innermost_group(base);

        if self.frames[outer as usize].variant == Variant::Joined {
            self.frames[outer as usize].stage = 1;
        }

        Step::Operator
    }

    fn constant(&mut self, kind: PythonKind) {
        self.events.start(PythonKind::Constant);
        self.bump();

        if is_string(kind) {
            while self.current().is_some_and(is_string) {
                self.bump();
            }
        }

        self.events.finish();
    }

    fn double_star(&mut self, group: u32) -> Step {
        if self.frames[group as usize].variant == Variant::Call {
            return self.unary(PythonKind::Keyword, POWER_STARRED);
        }

        if self.frames[group as usize].variant == Variant::Brace {
            self.frames[group as usize].dictionary = true;
        }

        self.bump();

        Step::Operand
    }

    fn keyword_argument(&mut self, group: u32) -> Step {
        let frame = Frame {
            checkpoint: self.frames[group as usize].element,
            kind: PythonKind::Keyword,
            power: POWER_BARRIER,
            values: self.value_count,
            variant: Variant::Keyword,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        self.bump();
        self.bump();

        Step::Operand
    }

    fn open_lambda(&mut self) -> Step {
        let checkpoint = self.anchor();

        let frame = Frame {
            checkpoint,
            element: checkpoint,
            kind: PythonKind::Lambda,
            power: POWER_BARRIER,
            values: self.value_count,
            variant: Variant::Lambda,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        self.bump();

        Step::Operand
    }

    fn open_yield(&mut self) -> Step {
        let checkpoint = self.anchor();
        let from = self.ahead(1) == Some(PythonKind::FromKeyword);

        let kind = if from {
            PythonKind::YieldFrom
        } else {
            PythonKind::Yield
        };

        self.bump();

        if from {
            self.bump();
        }

        let content = self.anchor();

        let frame = Frame {
            checkpoint,
            content,
            element: content,
            element_values: self.value_count,
            kind,
            power: POWER_STARRED,
            values: self.value_count,
            variant: Variant::Yield,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        Step::Operand
    }

    fn lambda_parameter(&mut self, group: u32, kind: PythonKind) -> Step {
        if kind == PythonKind::Identifier {
            self.events.start(PythonKind::Arg);
            self.bump();
            self.events.finish();

            if self.at(PythonKind::Equal) {
                self.bump();
                self.frames[group as usize].stage = 2;

                return Step::Operand;
            }

            return Step::Operator;
        }

        if matches!(
            kind,
            PythonKind::Slash | PythonKind::Star | PythonKind::StarStar
        ) {
            self.bump();

            return Step::Operand;
        }

        if kind == PythonKind::Colon {
            self.reduce_above(group + 1);
            self.bump();
            self.frames[group as usize].stage = 1;

            return Step::Operand;
        }

        Step::Done
    }

    fn enclosing_closer(&self, base: u32) -> PythonKind {
        let mut index = self.frame_count;

        while index > base {
            index -= 1;

            if self.frames[index as usize].is_bracketed() {
                return self.frames[index as usize].closer;
            }
        }

        PythonKind::ErrorToken
    }

    fn settle(&mut self, base: u32, kind: PythonKind) {
        let closer = self.enclosing_closer(base);

        for _ in 0..EXPRESSION_DEPTH_MAX {
            let group = self.innermost_group(base);
            let frame = self.frames[group as usize];
            let lambda = frame.variant == Variant::Lambda && frame.stage == 1;
            let yielded = frame.variant == Variant::Yield;

            if !lambda && !yielded {
                return;
            }

            if matches!(frame.variant, Variant::Formatted | Variant::Joined) {
                return;
            }

            if kind != closer && !(lambda && kind == PythonKind::Comma) {
                return;
            }

            self.reduce_above(group);
        }
    }

    fn operator_step(&mut self, base: u32) -> Step {
        self.skip_trivia();

        let Some(kind) = self.current() else {
            return Step::Done;
        };

        let held = self.innermost_group(base);

        if self.frames[held as usize].variant == Variant::Joined {
            if is_piece(kind) || kind == PythonKind::BraceOpen {
                return self.joined_piece(held, kind);
            }

            self.close_joined(held);

            return Step::Operator;
        }

        if self.frames[held as usize].variant == Variant::Formatted {
            let step = self.formatted_step(held, kind, base);

            if step != Step::Done {
                return step;
            }
        }

        self.settle(base, kind);

        let group = self.innermost_group(base);
        let frame = self.frames[group as usize];

        if frame.is_bracketed() && kind == frame.closer {
            self.close_group(group);

            return Step::Operator;
        }

        if kind == PythonKind::Comma {
            return self.comma(group);
        }

        if kind == PythonKind::Dot {
            return self.attribute();
        }

        if kind == PythonKind::ParenOpen {
            return self.trailer(Variant::Call);
        }

        if kind == PythonKind::BracketOpen {
            return self.trailer(Variant::Subscript);
        }

        if kind == PythonKind::Colon {
            return self.colon(group);
        }

        self.operator_of(kind, group, base)
    }

    fn operator_of(&mut self, kind: PythonKind, group: u32, base: u32) -> Step {
        let frame = self.frames[group as usize];

        if kind == PythonKind::InKeyword && group == base && frame.no_in {
            return Step::Done;
        }

        if kind == PythonKind::ForKeyword
            || (kind == PythonKind::AsyncKeyword && self.ahead(1) == Some(PythonKind::ForKeyword))
        {
            return self.comprehension_for(group);
        }

        if kind == PythonKind::InKeyword && frame.comprehension && frame.stage == 1 {
            return self.comprehension_in(group);
        }

        if kind == PythonKind::IfKeyword && frame.comprehension && frame.stage >= 2 {
            self.reduce_above(group + 1);
            self.bump();
            self.frames[group as usize].stage = 3;

            return Step::Operand;
        }

        if kind == PythonKind::IfKeyword {
            return self.conditional();
        }

        if kind == PythonKind::ElseKeyword {
            return self.conditional_else(base);
        }

        if kind == PythonKind::NotKeyword && self.ahead(1) == Some(PythonKind::InKeyword) {
            return self.comparison(2);
        }

        if kind == PythonKind::IsKeyword {
            let steps = u32::from(self.ahead(1) == Some(PythonKind::NotKeyword)) + 1;

            return self.comparison(steps);
        }

        if let Some((node, left, right)) = infix_of(kind) {
            return self.binary(node, kind, left, right);
        }

        Step::Done
    }

    fn comma(&mut self, group: u32) -> Step {
        let frame = self.frames[group as usize];

        if frame.variant == Variant::Lambda {
            self.reduce_above(group + 1);
            self.bump();

            if frame.stage == 2 {
                self.frames[group as usize].stage = 0;
            }

            return Step::Operand;
        }

        if frame.variant == Variant::Top && !frame.tuple {
            return Step::Done;
        }

        self.reduce_above(group + 1);

        if frame.comprehension && frame.stage == 1 {
            self.frames[group as usize].slice = true;
            self.bump();

            return Step::Operand;
        }

        self.close_element(group);
        self.bump();
        self.frames[group as usize].elements += 1;
        self.frames[group as usize].element = self.anchor();
        self.frames[group as usize].element_values = self.value_count;

        Step::Operand
    }

    fn attribute(&mut self) -> Step {
        if self.value_count == 0 {
            return Step::Done;
        }

        let checkpoint = self.values[self.value_count as usize - 1];

        self.events.start_at(checkpoint, PythonKind::Attribute);
        self.bump();
        let _ = self.eat(PythonKind::Identifier);
        self.events.finish();

        Step::Operator
    }

    fn trailer(&mut self, variant: Variant) -> Step {
        if self.value_count == 0 {
            return Step::Done;
        }

        let checkpoint = self.values[self.value_count as usize - 1];

        self.value_count -= 1;

        self.open_group(variant, checkpoint)
    }

    fn colon(&mut self, group: u32) -> Step {
        let frame = self.frames[group as usize];

        if frame.variant == Variant::Lambda && frame.stage != 1 {
            self.reduce_above(group + 1);
            self.bump();
            self.frames[group as usize].stage = 1;

            return Step::Operand;
        }

        if frame.variant == Variant::Brace {
            self.reduce_above(group + 1);
            self.bump();
            self.frames[group as usize].dictionary = true;

            return Step::Operand;
        }

        if frame.variant == Variant::Subscript {
            self.reduce_above(group + 1);
            self.bump();
            self.frames[group as usize].slice = true;

            return Step::Operand;
        }

        Step::Done
    }

    fn comprehension_for(&mut self, group: u32) -> Step {
        let frame = self.frames[group as usize];

        if frame.variant == Variant::Top || frame.variant == Variant::Lambda {
            return Step::Done;
        }

        self.reduce_above(group + 1);
        self.close_clause(group);

        let clause = self.anchor();
        let _ = self.eat(PythonKind::AsyncKeyword);
        self.bump();

        let element = self.anchor();

        self.frames[group as usize].clause = clause;
        self.frames[group as usize].comprehension = true;
        self.frames[group as usize].element = element;
        self.frames[group as usize].slice = false;
        self.frames[group as usize].stage = 1;

        Step::Operand
    }

    fn comprehension_in(&mut self, group: u32) -> Step {
        self.reduce_above(group + 1);

        if self.frames[group as usize].slice {
            self.events
                .start_at(self.frames[group as usize].element, PythonKind::Tuple);
            self.events.finish();
            self.frames[group as usize].slice = false;
        }

        self.bump();
        self.frames[group as usize].stage = 2;

        Step::Operand
    }

    fn comparison(&mut self, steps: u32) -> Step {
        let outcome = self.binary(
            PythonKind::Compare,
            PythonKind::InKeyword,
            POWER_COMPARE_LEFT,
            POWER_COMPARE_RIGHT,
        );

        for _ in 1..steps {
            self.bump();
        }

        outcome
    }

    fn conditional(&mut self) -> Step {
        self.reduce_for(POWER_CONDITIONAL_LEFT);

        if self.value_count == 0 {
            return Step::Done;
        }

        let values = self.value_count - 1;

        let frame = Frame {
            checkpoint: self.values[values as usize],
            kind: PythonKind::IfExp,
            power: POWER_CONDITIONAL_RIGHT,
            values,
            variant: Variant::Conditional,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        self.bump();

        Step::Operand
    }

    fn conditional_else(&mut self, base: u32) -> Step {
        let mut index = self.frame_count;

        while index > base {
            index -= 1;

            if self.frames[index as usize].variant == Variant::Conditional {
                self.reduce_above(index + 1);
                self.bump();

                return Step::Operand;
            }

            if self.frames[index as usize].is_group() {
                break;
            }
        }

        Step::Done
    }

    fn run(&mut self) {
        self.events.start(PythonKind::Module);

        while self.position < self.count() {
            let before = self.position;

            self.statements_until();

            if self.position == before {
                self.emit();
            }
        }

        self.events.finish();
    }

    fn statements_until(&mut self) {
        while self.position < self.count() {
            let before = self.position;

            self.skip_trivia();

            match self.current() {
                None => break,
                Some(PythonKind::Newline) => {
                    self.bump();

                    continue;
                }
                Some(PythonKind::Dedent) => break,
                Some(_) => self.statement(),
            }

            if self.position == before {
                self.emit();
            }
        }
    }

    fn statement(&mut self) {
        match self.current() {
            None => {}
            Some(PythonKind::At) => self.decorated(),
            Some(PythonKind::AsyncKeyword) => self.asynchronous(),
            Some(PythonKind::ClassKeyword) => self.class_definition(),
            Some(PythonKind::DefKeyword) => self.function_definition(),
            Some(PythonKind::ForKeyword) => self.for_statement(PythonKind::For),
            Some(PythonKind::IfKeyword) => self.if_statement(),
            Some(PythonKind::Indent) => {
                self.record(SyntaxErrorKind::UnexpectedIndent);
                self.recover();
            }
            Some(PythonKind::TryKeyword) => self.try_statement(),
            Some(PythonKind::WhileKeyword) => self.while_statement(),
            Some(PythonKind::WithKeyword) => self.with_statement(PythonKind::With),
            Some(_) if self.is_match_header() => self.match_statement(),
            Some(_) if self.is_type_alias() => self.type_alias(),
            Some(_) => self.simple_line(),
        }
    }

    fn asynchronous(&mut self) {
        match self.ahead(1) {
            Some(PythonKind::DefKeyword) => {
                self.events.start(PythonKind::AsyncFunctionDef);
                self.bump();
                self.definition_body();
                self.events.finish();
            }
            Some(PythonKind::ForKeyword) => {
                self.events.start(PythonKind::AsyncFor);
                self.bump();
                self.for_body();
                self.events.finish();
            }
            Some(PythonKind::WithKeyword) => {
                self.events.start(PythonKind::AsyncWith);
                self.bump();
                self.with_body();
                self.events.finish();
            }
            _ => self.simple_line(),
        }
    }

    fn block(&mut self) {
        if !self.at(PythonKind::Newline) {
            self.events.start(PythonKind::Block);
            self.simple_line();
            self.events.finish();

            return;
        }

        self.bump();

        if !self.at(PythonKind::Indent) {
            return;
        }

        self.events.start(PythonKind::Block);
        self.bump();
        self.statements_until();

        if !self.eat(PythonKind::Dedent) {
            self.record(SyntaxErrorKind::UnexpectedDedent);
        }

        self.events.finish();
    }

    fn colon_block(&mut self) {
        self.expect(PythonKind::Colon, SyntaxErrorKind::ExpectedColon);
        self.block();
    }

    fn class_definition(&mut self) {
        self.events.start(PythonKind::ClassDef);
        self.bump();
        self.expect(PythonKind::Identifier, SyntaxErrorKind::ExpectedIdentifier);
        self.type_parameters();

        if self.at(PythonKind::ParenOpen) {
            self.argument_list();
        }

        self.colon_block();
        self.events.finish();
    }

    fn decorated(&mut self) {
        while self.at(PythonKind::At) {
            self.events.start(PythonKind::Decorator);
            self.bump();
            self.expression();
            let _ = self.eat(PythonKind::Newline);
            self.events.finish();
            self.skip_trivia();
        }

        match self.current() {
            Some(PythonKind::AsyncKeyword) => {
                self.events.start(PythonKind::AsyncFunctionDef);
                self.bump();
                self.definition_body();
                self.events.finish();
            }
            Some(PythonKind::ClassKeyword) => self.class_definition(),
            Some(PythonKind::DefKeyword) => self.function_definition(),
            _ => {
                self.record(SyntaxErrorKind::UnexpectedToken);
                self.recover();
            }
        }
    }

    fn definition_body(&mut self) {
        self.bump();
        self.expect(PythonKind::Identifier, SyntaxErrorKind::ExpectedIdentifier);
        self.type_parameters();
        self.parameters();

        if self.eat(PythonKind::Arrow) {
            self.expression_single();
        }

        self.colon_block();
    }

    fn function_definition(&mut self) {
        self.events.start(PythonKind::FunctionDef);
        self.definition_body();
        self.events.finish();
    }

    fn for_body(&mut self) {
        self.bump();
        self.expression_target();
        self.expect(PythonKind::InKeyword, SyntaxErrorKind::ExpectedIn);
        self.expression();
        self.colon_block();
        self.else_clause();
    }

    fn for_statement(&mut self, kind: PythonKind) {
        self.events.start(kind);
        self.for_body();
        self.events.finish();
    }

    fn with_is_parenthesized(&self) -> bool {
        let mut position = self.ahead_position(0);
        let mut depth = 0_u32;

        while let Some(kind) = self.kind_at(position) {
            match Some(kind) {
                Some(_) if is_opener(kind) => depth += 1,
                Some(_) if is_closer(kind) => {
                    depth = depth.saturating_sub(1);

                    if depth == 0 {
                        let next = self.significant(position + 1);

                        return self.kind_at(next) == Some(PythonKind::Colon);
                    }
                }
                Some(PythonKind::Newline | PythonKind::Dedent) => break,
                Some(PythonKind::AsKeyword) if depth == 1 => return true,
                Some(_) | None => {}
            }

            position += 1;
        }

        false
    }

    fn with_body(&mut self) {
        self.bump();

        let parenthesized = self.at(PythonKind::ParenOpen) && self.with_is_parenthesized();

        if parenthesized {
            self.bump();
        }

        for _ in 0..CHAIN_DEPTH_MAX {
            self.events.start(PythonKind::WithItem);
            self.expression_single();

            if self.eat(PythonKind::AsKeyword) {
                self.expression_single();
            }

            self.events.finish();

            if !self.eat(PythonKind::Comma) {
                break;
            }

            if parenthesized && self.at(PythonKind::ParenClose) {
                break;
            }
        }

        if parenthesized {
            let _ = self.eat(PythonKind::ParenClose);
        }

        self.colon_block();
    }

    fn with_statement(&mut self, kind: PythonKind) {
        self.events.start(kind);
        self.with_body();
        self.events.finish();
    }

    fn while_statement(&mut self) {
        self.events.start(PythonKind::While);
        self.bump();
        self.expression();
        self.colon_block();
        self.else_clause();
        self.events.finish();
    }

    fn else_clause(&mut self) {
        self.skip_trivia();

        if !self.at(PythonKind::ElseKeyword) {
            return;
        }

        self.events.start(PythonKind::ElseClause);
        self.bump();
        self.colon_block();
        self.events.finish();
    }

    fn if_statement(&mut self) {
        let mut opened = 0_u32;

        self.events.start(PythonKind::If);
        self.bump();
        self.expression();
        self.colon_block();
        self.skip_trivia();

        while self.at(PythonKind::ElifKeyword) && opened < CHAIN_DEPTH_MAX {
            self.events.start(PythonKind::ElseClause);
            self.events.start(PythonKind::If);
            self.bump();
            self.expression();
            self.colon_block();
            self.skip_trivia();

            opened += 1;
        }

        self.else_clause();

        for _ in 0..opened {
            self.events.finish();
            self.events.finish();
        }

        self.events.finish();
    }

    fn try_statement(&mut self) {
        let checkpoint = self.anchor();
        let mut starred = false;

        self.bump();
        self.colon_block();
        self.skip_trivia();

        while self.at(PythonKind::ExceptKeyword) {
            self.events.start(PythonKind::ExceptHandler);
            self.bump();

            if self.eat(PythonKind::Star) {
                starred = true;
            }

            if !self.at(PythonKind::Colon) {
                let held = self.anchor();

                self.expression_single();
                self.except_tuple(held);

                if self.eat(PythonKind::AsKeyword) {
                    let _ = self.eat(PythonKind::Identifier);
                }
            }

            self.colon_block();
            self.events.finish();
            self.skip_trivia();
        }

        self.else_clause();
        self.skip_trivia();

        if self.at(PythonKind::FinallyKeyword) {
            self.events.start(PythonKind::FinallyClause);
            self.bump();
            self.colon_block();
            self.events.finish();
        }

        let kind = if starred {
            PythonKind::TryStar
        } else {
            PythonKind::Try
        };

        self.events.start_at(checkpoint, kind);
        self.events.finish();
    }

    fn except_tuple(&mut self, checkpoint: Checkpoint) {
        if !self.at(PythonKind::Comma) {
            return;
        }

        for _ in 0..CHAIN_DEPTH_MAX {
            if !self.eat(PythonKind::Comma) {
                break;
            }

            if self.at(PythonKind::AsKeyword) || self.at(PythonKind::Colon) {
                break;
            }

            let before = self.position;

            self.expression_single();

            if self.position == before {
                break;
            }
        }

        self.events.start_at(checkpoint, PythonKind::Tuple);
        self.events.finish();
    }

    fn argument_list(&mut self) {
        self.bump();

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if self.at(PythonKind::ParenClose) || self.current().is_none() {
                break;
            }

            self.argument();

            if !self.eat(PythonKind::Comma) {
                break;
            }
        }

        let _ = self.eat(PythonKind::ParenClose);
    }

    fn argument(&mut self) {
        let checkpoint = self.anchor();

        if self.at(PythonKind::StarStar) {
            self.bump();
            self.expression_single();
            self.events.start_at(checkpoint, PythonKind::Keyword);
            self.events.finish();

            return;
        }

        if self.at(PythonKind::Star) {
            self.bump();
            self.expression_single();
            self.events.start_at(checkpoint, PythonKind::Starred);
            self.events.finish();

            return;
        }

        if self.at(PythonKind::Identifier) && self.ahead(1) == Some(PythonKind::Equal) {
            self.bump();
            self.bump();
            self.expression_single();
            self.events.start_at(checkpoint, PythonKind::Keyword);
            self.events.finish();

            return;
        }

        self.expression_single();
    }

    fn parameters(&mut self) {
        if !self.at(PythonKind::ParenOpen) {
            return;
        }

        self.events.start(PythonKind::Arguments);
        self.bump();

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if self.at(PythonKind::ParenClose) || self.current().is_none() {
                break;
            }

            self.parameter();

            if !self.eat(PythonKind::Comma) {
                break;
            }
        }

        let _ = self.eat(PythonKind::ParenClose);
        self.events.finish();
    }

    fn parameter(&mut self) {
        if matches!(
            self.current(),
            Some(PythonKind::Slash | PythonKind::Star | PythonKind::StarStar)
        ) {
            self.bump();
        }

        if !self.at(PythonKind::Identifier) {
            return;
        }

        self.events.start(PythonKind::Arg);
        self.bump();

        if self.eat(PythonKind::Colon) {
            self.expression_single();
        }

        self.events.finish();

        if self.eat(PythonKind::Equal) {
            self.expression_single();
        }
    }

    fn type_parameters(&mut self) {
        if !self.at(PythonKind::BracketOpen) {
            return;
        }

        self.events.start(PythonKind::TypeParams);
        self.bump();

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if self.at(PythonKind::BracketClose) || self.current().is_none() {
                break;
            }

            self.type_parameter();

            if !self.eat(PythonKind::Comma) {
                break;
            }
        }

        let _ = self.eat(PythonKind::BracketClose);
        self.events.finish();
    }

    fn type_parameter(&mut self) {
        let checkpoint = self.anchor();

        let kind = if self.at(PythonKind::StarStar) {
            PythonKind::ParamSpec
        } else if self.at(PythonKind::Star) {
            PythonKind::TypeVarTuple
        } else {
            PythonKind::TypeVar
        };

        if kind != PythonKind::TypeVar {
            self.bump();
        }

        if !self.at(PythonKind::Identifier) {
            return;
        }

        self.bump();

        if self.eat(PythonKind::Colon) {
            self.expression_single();
        }

        if self.eat(PythonKind::Equal) {
            self.expression_single();
        }

        self.events.start_at(checkpoint, kind);
        self.events.finish();
    }

    fn is_match_header(&self) -> bool {
        self.soft_header(b"match")
    }

    fn soft_header(&self, word: &[u8]) -> bool {
        if !self.word(word) {
            return false;
        }

        let colon = self.header_colon();

        if colon == NONE {
            return false;
        }

        let after = self.significant(self.significant(self.position) + 1);

        if after >= colon {
            return false;
        }

        matches!(
            self.kind_at(self.significant(colon + 1)),
            Some(PythonKind::Newline) | None
        )
    }

    fn is_type_alias(&self) -> bool {
        if !self.word(b"type") {
            return false;
        }

        let after = self.significant(self.significant(self.position) + 1);

        if self.kind_at(after) != Some(PythonKind::Identifier) {
            return false;
        }

        self.shape().assign != NONE
    }

    fn match_statement(&mut self) {
        self.events.start(PythonKind::Match);
        self.bump();
        self.expression();
        self.expect(PythonKind::Colon, SyntaxErrorKind::ExpectedColon);

        if !self.at(PythonKind::Newline) {
            self.events.finish();

            return;
        }

        self.bump();

        if !self.eat(PythonKind::Indent) {
            self.events.finish();

            return;
        }

        self.match_cases();
        let _ = self.eat(PythonKind::Dedent);
        self.events.finish();
    }

    fn match_cases(&mut self) {
        while self.position < self.count() {
            self.skip_trivia();

            if self.at(PythonKind::Newline) {
                self.bump();

                continue;
            }

            if !self.soft_header(b"case") {
                break;
            }

            self.events.start(PythonKind::MatchCase);
            self.bump();
            self.pattern();
            self.colon_block();
            self.events.finish();
        }
    }

    fn pattern(&mut self) {
        let base = self.frame_count;
        let checkpoint = self.anchor();

        let frame = Frame {
            checkpoint,
            tuple: true,
            values: self.value_count,
            variant: Variant::Top,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return;
        }

        let mut operand = true;

        for _ in 0..PATTERN_STEP_MAX {
            let before = (self.position, self.frame_count);

            let step = if operand {
                self.pattern_operand(base)
            } else {
                self.pattern_operator(base)
            };

            match step {
                Step::Operand => operand = true,
                Step::Operator => operand = false,
                Step::Done => break,
            }

            if before == (self.position, self.frame_count) {
                break;
            }
        }

        self.reduce_above(base + 1);

        let top = self.frames[base as usize];

        self.frame_count = base;

        if top.elements > 0 {
            self.events
                .start_at(top.checkpoint, PythonKind::MatchSequence);
            self.events.finish();
        }

        self.value_count = top.values;

        if self.at(PythonKind::IfKeyword) {
            self.bump();
            self.expression_single();
        }
    }

    fn dotted(&mut self, checkpoint: Checkpoint) {
        self.wrap(PythonKind::Name);

        while self.at(PythonKind::Dot) {
            self.events.start_at(checkpoint, PythonKind::Attribute);
            self.bump();
            let _ = self.eat(PythonKind::Identifier);
            self.events.finish();
        }
    }

    fn pattern_value(&mut self, checkpoint: Checkpoint) {
        let signed = matches!(self.current(), Some(PythonKind::Minus | PythonKind::Plus));

        if signed {
            self.bump();
        }

        if let Some(kind) = self.current() {
            self.constant(kind);
        }

        if signed {
            self.events.start_at(checkpoint, PythonKind::UnaryOp);
            self.events.finish();
        }

        self.events.start_at(checkpoint, PythonKind::MatchValue);
        self.events.finish();
    }

    fn open_pattern_group(&mut self, variant: Variant, closer: PythonKind) -> Step {
        let checkpoint = self.anchor();

        self.open_pattern_group_at(variant, closer, checkpoint)
    }

    fn open_pattern_group_at(
        &mut self,
        variant: Variant,
        closer: PythonKind,
        checkpoint: Checkpoint,
    ) -> Step {
        self.bump();

        let content = self.anchor();

        let frame = Frame {
            checkpoint,
            closer,
            content,
            element: content,
            values: self.value_count,
            variant,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        Step::Operand
    }

    fn close_pattern_group(&mut self, group: u32) {
        self.reduce_above(group + 1);

        let frame = self.frames[group as usize];
        let seen = self.value_count - frame.values;

        let inner = if seen > 0 {
            self.values[self.value_count as usize - 1]
        } else {
            frame.checkpoint
        };

        self.frame_count = group;

        let transparent =
            frame.variant == Variant::PatternGroup && frame.elements == 0 && seen == 1;

        if transparent {
            self.bump();
            self.value_count = frame.values;
            self.push_value(inner);

            return;
        }

        let kind = if frame.variant == Variant::ClassArgs {
            PythonKind::MatchClass
        } else if frame.variant == Variant::Mapping {
            PythonKind::MatchMapping
        } else {
            PythonKind::MatchSequence
        };

        self.events.start_at(frame.checkpoint, kind);
        self.bump();
        self.events.finish();
        self.value_count = frame.values;
        self.push_value(frame.checkpoint);
    }

    fn pattern_operand(&mut self, base: u32) -> Step {
        self.skip_trivia();

        let Some(kind) = self.current() else {
            return Step::Done;
        };

        let group = self.innermost_group(base);
        let frame = self.frames[group as usize];

        if frame.variant == Variant::Mapping && frame.stage == 0 {
            return self.mapping_key(group, kind);
        }

        if frame.variant == Variant::ClassArgs
            && kind == PythonKind::Identifier
            && self.ahead(1) == Some(PythonKind::Equal)
        {
            self.bump();
            self.bump();

            return Step::Operand;
        }

        self.pattern_atom(kind)
    }

    fn mapping_key(&mut self, group: u32, kind: PythonKind) -> Step {
        if kind == PythonKind::StarStar {
            self.bump();
            let _ = self.eat(PythonKind::Identifier);

            return Step::Operator;
        }

        let checkpoint = self.anchor();

        if kind == PythonKind::Identifier {
            self.dotted(checkpoint);
        } else {
            self.constant(kind);
        }

        let _ = self.eat(PythonKind::Colon);
        self.frames[group as usize].stage = 1;

        Step::Operand
    }

    fn pattern_atom(&mut self, kind: PythonKind) -> Step {
        if kind == PythonKind::BracketOpen {
            return self.open_pattern_group(Variant::Sequence, PythonKind::BracketClose);
        }

        if kind == PythonKind::ParenOpen {
            return self.open_pattern_group(Variant::PatternGroup, PythonKind::ParenClose);
        }

        if kind == PythonKind::BraceOpen {
            return self.open_pattern_group(Variant::Mapping, PythonKind::BraceClose);
        }

        if kind == PythonKind::Star {
            let checkpoint = self.anchor();

            self.bump();
            let _ = self.eat(PythonKind::Identifier);
            self.events.start_at(checkpoint, PythonKind::MatchStar);
            self.events.finish();
            self.push_value(checkpoint);

            return Step::Operator;
        }

        if matches!(
            kind,
            PythonKind::FalseKeyword | PythonKind::NoneKeyword | PythonKind::TrueKeyword
        ) {
            let checkpoint = self.anchor();

            self.wrap(PythonKind::MatchSingleton);
            self.push_value(checkpoint);

            return Step::Operator;
        }

        if kind == PythonKind::Identifier {
            return self.pattern_name();
        }

        if is_literal(kind) || matches!(kind, PythonKind::Minus | PythonKind::Plus) {
            let checkpoint = self.anchor();

            self.pattern_value(checkpoint);
            self.push_value(checkpoint);

            return Step::Operator;
        }

        Step::Done
    }

    fn pattern_name(&mut self) -> Step {
        let checkpoint = self.anchor();

        if !matches!(self.ahead(1), Some(PythonKind::Dot | PythonKind::ParenOpen)) {
            self.wrap(PythonKind::MatchAs);
            self.push_value(checkpoint);

            return Step::Operator;
        }

        self.dotted(checkpoint);

        if self.at(PythonKind::ParenOpen) {
            return self.open_pattern_group_at(
                Variant::ClassArgs,
                PythonKind::ParenClose,
                checkpoint,
            );
        }

        self.events.start_at(checkpoint, PythonKind::MatchValue);
        self.events.finish();
        self.push_value(checkpoint);

        Step::Operator
    }

    fn pattern_operator(&mut self, base: u32) -> Step {
        self.skip_trivia();

        let Some(kind) = self.current() else {
            return Step::Done;
        };

        let group = self.innermost_group(base);
        let frame = self.frames[group as usize];

        if frame.is_pattern() && kind == frame.closer {
            self.close_pattern_group(group);

            return Step::Operator;
        }

        if kind == PythonKind::Comma {
            if !frame.is_pattern() && frame.variant != Variant::Top {
                return Step::Done;
            }

            self.reduce_above(group + 1);
            self.bump();
            self.frames[group as usize].elements += 1;

            if frame.variant == Variant::Mapping {
                self.frames[group as usize].stage = 0;
            }

            return Step::Operand;
        }

        if kind == PythonKind::Bar {
            return self.binary(
                PythonKind::MatchOr,
                PythonKind::Bar,
                POWER_BAR_LEFT,
                POWER_BAR_RIGHT,
            );
        }

        if kind == PythonKind::AsKeyword {
            self.reduce_above(group + 1);

            if self.value_count == 0 {
                return Step::Done;
            }

            let checkpoint = self.values[self.value_count as usize - 1];

            self.bump();
            let _ = self.eat(PythonKind::Identifier);
            self.events.start_at(checkpoint, PythonKind::MatchAs);
            self.events.finish();

            return Step::Operator;
        }

        Step::Done
    }

    fn type_alias(&mut self) {
        self.events.start(PythonKind::TypeAlias);
        self.bump();
        self.wrap(PythonKind::Name);
        self.type_parameters();
        self.expect(PythonKind::Equal, SyntaxErrorKind::ExpectedEqual);
        self.expression();
        self.events.finish();
    }

    fn simple_line(&mut self) {
        for _ in 0..CHAIN_DEPTH_MAX {
            let before = self.position;

            self.simple_statement();

            if !self.eat(PythonKind::Semicolon) {
                break;
            }

            self.skip_trivia();

            if self.at(PythonKind::Newline) || self.current().is_none() {
                break;
            }

            if self.position == before {
                break;
            }
        }

        let _ = self.eat(PythonKind::Newline);
    }

    fn simple_statement(&mut self) {
        match self.current() {
            Some(PythonKind::AssertKeyword) => self.assert_statement(),
            Some(PythonKind::BreakKeyword) => self.wrap(PythonKind::Break),
            Some(PythonKind::ContinueKeyword) => self.wrap(PythonKind::Continue),
            Some(PythonKind::DelKeyword) => self.delete_statement(),
            Some(PythonKind::FromKeyword) => self.import_from(),
            Some(PythonKind::GlobalKeyword) => self.names_statement(PythonKind::Global),
            Some(PythonKind::ImportKeyword) => self.import_statement(),
            Some(PythonKind::NonlocalKeyword) => self.names_statement(PythonKind::Nonlocal),
            Some(PythonKind::PassKeyword) => self.wrap(PythonKind::Pass),
            Some(PythonKind::RaiseKeyword) => self.raise_statement(),
            Some(PythonKind::ReturnKeyword) => self.return_statement(),
            Some(_) => self.assignment(),
            None => {}
        }
    }

    fn assert_statement(&mut self) {
        self.events.start(PythonKind::Assert);
        self.bump();
        self.expression_single();

        if self.eat(PythonKind::Comma) {
            self.expression_single();
        }

        self.events.finish();
    }

    fn delete_statement(&mut self) {
        self.events.start(PythonKind::Delete);
        self.bump();

        for _ in 0..CHAIN_DEPTH_MAX {
            self.expression_single();

            if !self.eat(PythonKind::Comma) {
                break;
            }
        }

        self.events.finish();
    }

    fn names_statement(&mut self, kind: PythonKind) {
        let end = self.line_end();

        self.events.start(kind);

        while self.position < end && self.position < self.count() {
            self.emit();
        }

        self.events.finish();
    }

    fn import_statement(&mut self) {
        self.events.start(PythonKind::Import);
        self.bump();
        self.alias_list();
        self.events.finish();
    }

    fn import_from(&mut self) {
        self.events.start(PythonKind::ImportFrom);
        self.bump();

        while matches!(
            self.current(),
            Some(PythonKind::Dot | PythonKind::Ellipsis | PythonKind::Identifier)
        ) {
            self.bump();
        }

        self.expect(PythonKind::ImportKeyword, SyntaxErrorKind::ExpectedImport);

        let parenthesized = self.eat(PythonKind::ParenOpen);

        self.alias_list();

        if parenthesized {
            let _ = self.eat(PythonKind::ParenClose);
        }

        self.events.finish();
    }

    fn alias_list(&mut self) {
        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if !matches!(
                self.current(),
                Some(PythonKind::Identifier | PythonKind::Star)
            ) {
                break;
            }

            self.events.start(PythonKind::Alias);
            self.bump();

            while self.at(PythonKind::Dot) {
                self.bump();
                let _ = self.eat(PythonKind::Identifier);
            }

            if self.eat(PythonKind::AsKeyword) {
                let _ = self.eat(PythonKind::Identifier);
            }

            self.events.finish();

            if !self.eat(PythonKind::Comma) {
                break;
            }
        }
    }

    fn raise_statement(&mut self) {
        self.events.start(PythonKind::Raise);
        self.bump();

        if !self.at(PythonKind::Newline) && self.current().is_some() {
            self.expression_single();

            if self.eat(PythonKind::FromKeyword) {
                self.expression_single();
            }
        }

        self.events.finish();
    }

    fn return_statement(&mut self) {
        self.events.start(PythonKind::Return);
        self.bump();

        if !self.at(PythonKind::Newline) && self.current().is_some() {
            self.expression();
        }

        self.events.finish();
    }

    fn assignment(&mut self) {
        let shape = self.shape();

        if shape.augmented != NONE && shape.assign > shape.augmented {
            self.events.start(PythonKind::AugAssign);
            self.expression();
            self.bump();
            self.expression();
            self.events.finish();

            return;
        }

        if shape.annotation != NONE && shape.annotation < shape.assign {
            self.annotated();

            return;
        }

        if shape.assign != NONE {
            self.events.start(PythonKind::Assign);

            for _ in 0..CHAIN_DEPTH_MAX {
                self.expression();

                if !self.eat(PythonKind::Equal) {
                    break;
                }
            }

            self.events.finish();

            return;
        }

        self.events.start(PythonKind::Expr);
        self.expression();
        self.events.finish();
    }

    fn annotated(&mut self) {
        self.events.start(PythonKind::AnnAssign);
        self.expression_single();
        self.expect(PythonKind::Colon, SyntaxErrorKind::ExpectedColon);
        self.expression_single();

        if self.eat(PythonKind::Equal) {
            self.expression();
        }

        self.events.finish();
    }
}

pub fn build(
    source: &[u8],
    tokens: &[Token],
    raw: &[PythonKind],
    events: &mut Events<PythonKind>,
    tree: &mut Tree<PythonKind>,
) -> Structure {
    assert!(u32::try_from(source.len()).is_ok());
    assert_eq!(tokens.len(), raw.len());

    events.clear();
    tree.clear();

    let mut parser = Parser {
        brackets: 0,
        events,
        frame_count: 0,
        frames: [Frame::EMPTY; EXPRESSION_DEPTH_MAX as usize],
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
