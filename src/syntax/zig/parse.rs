use crate::bounded::{Span, count_of};
use crate::syntax::zig::expression::{
    EXPRESSION_DEPTH_MAX,
    Frame,
    POWER_BARRIER,
    POWER_PREFIX,
    VALUE_COUNT_MAX,
    Variant,
    assignment_of,
    infix_of,
    is_literal,
    literal_node,
    prefix_of,
};
use crate::syntax::zig::kind::ZigKind;
use crate::syntax::{SyntaxError, SyntaxErrorKind};
use crate::token::Token;
use crate::tree::{Checkpoint, Events, Structure, Tree, replay};

const CHAIN_DEPTH_MAX: u32 = 4_096;
const NEST_DEPTH_MAX: u32 = 96;
const SCAN_STEP_MAX: u32 = 1 << 16;
const CONTEXT_EXPRESSION: u8 = 1;
const CONTEXT_STATEMENT: u8 = 2;
const CONTEXT_TYPE: u8 = 0;
const STAGE_VALUE: u8 = 0;
const STAGE_TYPE: u8 = 1;
const STAGE_KEEP: u8 = 2;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Step {
    Done,
    Operand,
    Operator,
}

struct Parser<'run> {
    events: &'run mut Events<ZigKind>,
    frame_count: u32,
    frames: [Frame; EXPRESSION_DEPTH_MAX as usize],
    nesting: u32,
    outcome: Structure,
    position: u32,
    raw: &'run [ZigKind],
    significant_next: u32,
    suffixable: bool,
    tokens: &'run [Token],
    tree: &'run mut Tree<ZigKind>,
    value_count: u32,
    values: [Checkpoint; VALUE_COUNT_MAX as usize],
}

const fn is_layout(kind: ZigKind) -> bool {
    matches!(kind, ZigKind::Comment | ZigKind::DocComment)
}

const fn is_opener(kind: ZigKind) -> bool {
    matches!(
        kind,
        ZigKind::BraceOpen | ZigKind::BracketOpen | ZigKind::ParenOpen
    )
}

const fn is_closer(kind: ZigKind) -> bool {
    matches!(
        kind,
        ZigKind::BraceClose | ZigKind::BracketClose | ZigKind::ParenClose
    )
}

const fn opens_a_body(kind: ZigKind) -> bool {
    matches!(
        kind,
        ZigKind::EnumKeyword
            | ZigKind::OpaqueKeyword
            | ZigKind::ParenClose
            | ZigKind::StructKeyword
            | ZigKind::UnionKeyword
    )
}

const fn opens_a_container(kind: ZigKind) -> bool {
    matches!(
        kind,
        ZigKind::EnumKeyword
            | ZigKind::ExternKeyword
            | ZigKind::OpaqueKeyword
            | ZigKind::PackedKeyword
            | ZigKind::StructKeyword
            | ZigKind::UnionKeyword
    )
}

impl Parser<'_> {
    fn count(&self) -> u32 {
        count_of(self.raw.len())
    }

    fn kind_at(&self, position: u32) -> Option<ZigKind> {
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

    fn current(&self) -> Option<ZigKind> {
        self.kind_at(self.significant(self.position))
    }

    fn ahead(&self, steps: u32) -> Option<ZigKind> {
        self.kind_at(self.ahead_position(steps))
    }

    fn ahead_position(&self, steps: u32) -> u32 {
        let mut position = self.significant(self.position);

        for _ in 0..steps {
            position = self.significant(position + 1);
        }

        position
    }

    fn at(&self, kind: ZigKind) -> bool {
        self.current() == Some(kind)
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

    fn skip_trivia(&mut self) {
        while self.kind_at(self.position).is_some_and(is_layout) {
            self.emit();
        }
    }

    fn anchor(&mut self) -> Checkpoint {
        self.skip_trivia();

        self.events.checkpoint()
    }

    fn open(&mut self, kind: ZigKind) {
        self.skip_trivia();
        self.events.start(kind);
    }

    fn bump(&mut self) {
        self.skip_trivia();
        self.emit();
    }

    fn eat(&mut self, kind: ZigKind) -> bool {
        if !self.at(kind) {
            return false;
        }

        self.bump();

        true
    }

    fn expect(&mut self, kind: ZigKind, failure: SyntaxErrorKind) -> bool {
        if self.eat(kind) {
            return true;
        }

        self.record(failure);

        false
    }

    fn wrap(&mut self, kind: ZigKind) {
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

    fn balanced_end(&self, from: u32) -> u32 {
        let mut position = from;
        let mut depth = 0_u32;

        for _ in 0..SCAN_STEP_MAX {
            let Some(kind) = self.kind_at(position) else {
                return position;
            };

            if is_opener(kind) {
                depth += 1;
            }

            if is_closer(kind) {
                if depth == 0 {
                    return position;
                }

                depth -= 1;

                if depth == 0 {
                    return position + 1;
                }
            }

            position += 1;
        }

        position
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

    fn run(&mut self) {
        self.events.start(ZigKind::Root);

        for _ in 0..u32::MAX {
            self.skip_trivia();

            if self.current().is_none() {
                break;
            }

            let before = self.position;

            self.member();

            if self.position == before {
                self.record(SyntaxErrorKind::UnexpectedToken);
                self.emit();
            }
        }

        self.events.finish();
    }

    fn member(&mut self) {
        if !self.descend() {
            self.emit();

            return;
        }

        self.member_of();
        self.ascend();
    }

    fn member_of(&mut self) {
        let checkpoint = self.anchor();

        if self.at(ZigKind::TestKeyword) {
            self.test_declaration(checkpoint);

            return;
        }

        if self.at(ZigKind::ComptimeKeyword) && self.ahead(1) == Some(ZigKind::BraceOpen) {
            self.bump();

            let held = self.anchor();

            self.block_at(held);
            self.events.start_at(checkpoint, ZigKind::Comptime);
            self.events.finish();

            return;
        }

        self.modifiers();

        match self.current() {
            None => {}
            Some(ZigKind::FnKeyword) => self.function(checkpoint),
            Some(ZigKind::ConstKeyword | ZigKind::VarKeyword) => {
                self.variable_declaration(checkpoint);
                let _ = self.eat(ZigKind::Semicolon);
            }
            Some(_) => {
                self.container_field(checkpoint);
                let _ = self.eat(ZigKind::Comma);
            }
        }
    }

    fn modifiers(&mut self) {
        for _ in 0..CHAIN_DEPTH_MAX {
            let held = match self.current() {
                Some(
                    ZigKind::ComptimeKeyword
                    | ZigKind::ExportKeyword
                    | ZigKind::InlineKeyword
                    | ZigKind::NoinlineKeyword
                    | ZigKind::PubKeyword
                    | ZigKind::ThreadlocalKeyword,
                ) => true,
                Some(ZigKind::ExternKeyword) => self.ahead(1) != Some(ZigKind::BraceOpen),
                _ => false,
            };

            if !held {
                return;
            }

            let extern_held = self.at(ZigKind::ExternKeyword);

            self.bump();

            if extern_held {
                let _ = self.eat(ZigKind::Text);
            }
        }
    }

    fn test_declaration(&mut self, checkpoint: Checkpoint) {
        self.bump();

        if self.at(ZigKind::Text) || self.at(ZigKind::Identifier) {
            self.bump();
        }

        let held = self.anchor();

        self.block_at(held);
        self.events.start_at(checkpoint, ZigKind::TestDecl);
        self.events.finish();
    }

    fn function(&mut self, checkpoint: Checkpoint) {
        self.bump();

        if self.at(ZigKind::Identifier) {
            self.bump();
        }

        self.parameter_list();
        self.callable_attributes();
        let _ = self.eat(ZigKind::Bang);
        self.type_of();
        self.events.start_at(checkpoint, ZigKind::FnProto);
        self.events.finish();

        if !self.at(ZigKind::BraceOpen) {
            let _ = self.eat(ZigKind::Semicolon);

            return;
        }

        let held = self.anchor();

        self.block_at(held);
        self.events.start_at(checkpoint, ZigKind::FnDecl);
        self.events.finish();
    }

    fn parameter_list(&mut self) {
        if !self.eat(ZigKind::ParenOpen) {
            return;
        }

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if self.at(ZigKind::ParenClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.parameter();

            if !self.eat(ZigKind::Comma) {
                break;
            }

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(ZigKind::ParenClose);
    }

    fn parameter(&mut self) {
        let _ = self.eat(ZigKind::ComptimeKeyword);
        let _ = self.eat(ZigKind::NoaliasKeyword);

        if self.at(ZigKind::Identifier) && self.ahead(1) == Some(ZigKind::Colon) {
            self.bump();
            self.bump();
        }

        if self.at(ZigKind::AnytypeKeyword) || self.at(ZigKind::DotDotDot) {
            self.bump();

            return;
        }

        self.type_of();
    }

    fn callable_attributes(&mut self) {
        for _ in 0..CHAIN_DEPTH_MAX {
            let held = matches!(
                self.current(),
                Some(
                    ZigKind::AddrspaceKeyword
                        | ZigKind::AlignKeyword
                        | ZigKind::CallconvKeyword
                        | ZigKind::LinksectionKeyword
                )
            );

            if !held {
                return;
            }

            self.bump();
            self.parenthesized();
        }
    }

    fn parenthesized(&mut self) {
        if !self.eat(ZigKind::ParenOpen) {
            return;
        }

        self.expression();
        let _ = self.eat(ZigKind::ParenClose);
    }

    fn pointer_attributes(&mut self) {
        for _ in 0..CHAIN_DEPTH_MAX {
            match self.current() {
                Some(
                    ZigKind::ConstKeyword | ZigKind::VolatileKeyword | ZigKind::AllowzeroKeyword,
                ) => {
                    self.bump();
                }
                Some(ZigKind::AddrspaceKeyword | ZigKind::AlignKeyword) => {
                    self.bump();
                    self.parenthesized();
                }
                _ => return,
            }
        }
    }

    fn variable_declaration(&mut self, checkpoint: Checkpoint) {
        self.bump();

        if self.at(ZigKind::Identifier) {
            self.bump();
        }

        if self.eat(ZigKind::Colon) {
            self.type_of();
        }

        self.callable_attributes();

        if self.eat(ZigKind::Equal) {
            self.expression();
        }

        self.events.start_at(checkpoint, ZigKind::VarDecl);
        self.events.finish();
    }

    fn container_field(&mut self, checkpoint: Checkpoint) {
        if self.at(ZigKind::Identifier) && self.ahead(1) == Some(ZigKind::Colon) {
            self.bump();
            self.bump();
        }

        self.type_of();

        if self.at(ZigKind::AlignKeyword) {
            self.bump();
            self.parenthesized();
        }

        if self.eat(ZigKind::Equal) {
            self.expression();
        }

        self.events.start_at(checkpoint, ZigKind::ContainerField);
        self.events.finish();
    }

    fn block(&mut self) {
        let checkpoint = self.anchor();

        self.block_at(checkpoint);
    }

    fn block_at(&mut self, checkpoint: Checkpoint) {
        if !self.descend() {
            self.emit();

            return;
        }

        self.block_of(checkpoint);
        self.ascend();
    }

    fn block_of(&mut self, checkpoint: Checkpoint) {
        self.expect(ZigKind::BraceOpen, SyntaxErrorKind::UnexpectedToken);

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if self.at(ZigKind::BraceClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.statement();

            if self.position == before {
                self.record(SyntaxErrorKind::UnexpectedToken);
                self.emit();
            }
        }

        let _ = self.eat(ZigKind::BraceClose);
        self.events.start_at(checkpoint, ZigKind::Block);
        self.events.finish();
    }

    fn statement(&mut self) {
        if !self.descend() {
            self.emit();

            return;
        }

        self.statement_of();
        self.ascend();
    }

    fn statement_of(&mut self) {
        let checkpoint = self.anchor();

        match self.current() {
            None => {}
            Some(ZigKind::Semicolon) => {
                self.bump();
            }
            Some(ZigKind::ComptimeKeyword) => self.comptime_statement(checkpoint),
            Some(ZigKind::ConstKeyword | ZigKind::VarKeyword) => {
                if self.destructures() {
                    self.destructure(checkpoint);
                } else {
                    self.variable_declaration(checkpoint);
                    let _ = self.eat(ZigKind::Semicolon);
                }
            }
            Some(ZigKind::DeferKeyword) => {
                self.bump();
                self.deferred(checkpoint, ZigKind::Defer);
            }
            Some(ZigKind::ErrdeferKeyword) => {
                self.bump();
                self.payload();
                self.deferred(checkpoint, ZigKind::Errdefer);
            }
            Some(ZigKind::SuspendKeyword) => {
                self.bump();
                self.deferred(checkpoint, ZigKind::Suspend);
            }
            Some(ZigKind::NosuspendKeyword) => {
                self.bump();
                self.deferred(checkpoint, ZigKind::Nosuspend);
            }
            Some(_) => {
                if self.targets_a_destructure() && self.destructures() {
                    self.destructure(checkpoint);
                } else {
                    self.expression_statement(checkpoint);
                    let _ = self.eat(ZigKind::Semicolon);
                }
            }
        }
    }

    fn comptime_statement(&mut self, checkpoint: Checkpoint) {
        if matches!(
            self.ahead(1),
            Some(ZigKind::ConstKeyword | ZigKind::VarKeyword)
        ) {
            if self.destructures() {
                self.destructure(checkpoint);

                return;
            }

            self.bump();
            self.variable_declaration(checkpoint);
            let _ = self.eat(ZigKind::Semicolon);

            return;
        }

        self.bump();
        self.deferred(checkpoint, ZigKind::Comptime);
    }

    fn deferred(&mut self, checkpoint: Checkpoint, kind: ZigKind) {
        let held = self.anchor();

        if self.at(ZigKind::BraceOpen) {
            self.block_at(held);
        } else {
            self.expression_statement(held);
        }

        self.events.start_at(checkpoint, kind);
        self.events.finish();
        let _ = self.eat(ZigKind::Semicolon);
    }

    fn targets_a_destructure(&self) -> bool {
        self.at(ZigKind::Identifier) && !self.labels_a_loop()
    }

    fn destructures(&self) -> bool {
        let mut position = self.significant(self.position);
        let mut previous = ZigKind::ErrorToken;
        let mut depth = 0_u32;

        for _ in 0..SCAN_STEP_MAX {
            let Some(kind) = self.kind_at(position) else {
                return false;
            };

            if depth == 0 && kind == ZigKind::BraceOpen {
                if !opens_a_body(previous) {
                    return false;
                }

                position = self.balanced_end(position);
                previous = ZigKind::BraceClose;

                continue;
            }

            if depth == 0 {
                if matches!(kind, ZigKind::Arrow | ZigKind::Equal | ZigKind::Semicolon) {
                    return false;
                }

                if kind == ZigKind::Comma {
                    return true;
                }
            }

            if is_opener(kind) {
                depth += 1;
            }

            if is_closer(kind) {
                if depth == 0 {
                    return false;
                }

                depth -= 1;
            }

            previous = kind;
            position += 1;
        }

        false
    }

    fn destructure(&mut self, checkpoint: Checkpoint) {
        for _ in 0..CHAIN_DEPTH_MAX {
            let held = self.anchor();

            if self.at(ZigKind::ComptimeKeyword)
                && matches!(
                    self.ahead(1),
                    Some(ZigKind::ConstKeyword | ZigKind::VarKeyword)
                )
            {
                self.bump();
            }

            if matches!(
                self.current(),
                Some(ZigKind::ConstKeyword | ZigKind::VarKeyword)
            ) {
                self.bump();

                if self.at(ZigKind::Identifier) {
                    self.bump();
                }

                if self.eat(ZigKind::Colon) {
                    self.type_of();
                }

                self.events.start_at(held, ZigKind::VarDecl);
                self.events.finish();
            } else {
                self.expression();
            }

            if !self.eat(ZigKind::Comma) {
                break;
            }
        }

        let _ = self.eat(ZigKind::Equal);
        self.expression();
        self.events.start_at(checkpoint, ZigKind::AssignDestructure);
        self.events.finish();
        let _ = self.eat(ZigKind::Semicolon);
    }

    fn expression_statement(&mut self, checkpoint: Checkpoint) {
        self.statement_expression();

        let Some(node) = self.current().and_then(assignment_of) else {
            return;
        };

        self.bump();
        self.expression();
        self.events.start_at(checkpoint, node);
        self.events.finish();
    }

    fn assign_expression(&mut self) {
        let checkpoint = self.anchor();

        self.expression_statement(checkpoint);
    }

    fn payload(&mut self) {
        if !self.eat(ZigKind::Pipe) {
            return;
        }

        for _ in 0..CHAIN_DEPTH_MAX {
            let _ = self.eat(ZigKind::Star);

            if !self.eat(ZigKind::Identifier) {
                break;
            }

            if !self.eat(ZigKind::Comma) {
                break;
            }
        }

        let _ = self.eat(ZigKind::Pipe);
    }

    fn expression(&mut self) {
        self.expression_staged(CONTEXT_EXPRESSION);
    }

    fn statement_expression(&mut self) {
        self.expression_staged(CONTEXT_STATEMENT);
    }

    fn type_of(&mut self) {
        self.expression_staged(CONTEXT_TYPE);
    }

    fn expression_staged(&mut self, stage: u8) {
        if !self.descend() {
            self.emit();

            return;
        }

        let frames_base = self.frame_count;
        let values_base = self.value_count;
        let checkpoint = self.anchor();

        let frame = Frame {
            checkpoint,
            content: checkpoint,
            element_values: self.value_count,
            stage,
            values: self.value_count,
            variant: Variant::Top,
            ..Frame::EMPTY
        };

        if self.push_frame(frame) {
            self.machine(frames_base);
            self.reduce_above(frames_base + 1);
            self.frame_count = frames_base;
            self.value_count = values_base;
        }

        self.ascend();
    }

    fn context(&self, base: u32) -> u8 {
        let group = self.innermost_group(base);

        if self.frames[group as usize].variant != Variant::Top {
            return CONTEXT_EXPRESSION;
        }

        self.frames[group as usize].stage
    }

    fn curly_allowed(&self, base: u32) -> bool {
        self.context(base) != CONTEXT_TYPE
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

    fn prefix(&mut self, kind: ZigKind, power: u8, stage: u8) -> Step {
        let checkpoint = self.anchor();

        let frame = Frame {
            checkpoint,
            kind,
            power,
            stage,
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

    fn keyword_prefix(&mut self, kind: ZigKind) -> Step {
        self.prefix(kind, POWER_BARRIER, STAGE_KEEP)
    }

    fn binary(&mut self, kind: ZigKind, left: u8, right: u8) -> Step {
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

        if kind == ZigKind::Catch {
            self.payload();
        }

        Step::Operand
    }

    fn open_group(&mut self, variant: Variant, checkpoint: Checkpoint, kind: ZigKind) -> Step {
        let opener = self.current().unwrap_or(ZigKind::ParenOpen);
        let bracket = self.anchor();

        self.bump();

        let content = self.anchor();

        let closer = if opener == ZigKind::BracketOpen {
            ZigKind::BracketClose
        } else if opener == ZigKind::BraceOpen {
            ZigKind::BraceClose
        } else {
            ZigKind::ParenClose
        };

        let frame = Frame {
            bracket,
            checkpoint,
            closer,
            content,
            element_values: self.value_count,
            kind,
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

        let kind = if frame.variant == Variant::Index {
            if frame.stage == 0 {
                ZigKind::ArrayAccess
            } else {
                ZigKind::Slice
            }
        } else if frame.variant == Variant::Init {
            init_kind(frame)
        } else {
            frame.kind
        };

        self.events.start_at(frame.checkpoint, kind);
        self.bump();
        self.events.finish();
        self.value_count = frame.values;
        self.push_value(frame.checkpoint);
        self.suffixable = true;
    }

    fn operand_step(&mut self, base: u32) -> Step {
        self.skip_trivia();

        let group = self.innermost_group(base);

        let Some(kind) = self.current() else {
            return Step::Done;
        };

        if self.frames[group as usize].is_bracketed() && kind == self.frames[group as usize].closer
        {
            return Step::Done;
        }

        if self.frames[group as usize].variant == Variant::Init {
            if self.frames[group as usize].stage == 0 {
                self.frames[group as usize].stage = 1;
            }

            if kind == ZigKind::Dot
                && self.ahead(1) == Some(ZigKind::Identifier)
                && self.ahead(2) == Some(ZigKind::Equal)
            {
                self.frames[group as usize].stage = 2;
                self.bump();
                self.bump();
                self.bump();

                return Step::Operand;
            }
        }

        self.operand_of(kind, base)
    }

    fn operand_of(&mut self, kind: ZigKind, base: u32) -> Step {
        match Some(kind) {
            None => Step::Done,
            Some(ZigKind::Identifier | ZigKind::InlineKeyword) if self.labels_a_loop() => {
                self.labelled(base)
            }
            Some(ZigKind::Identifier) => self.leaf(ZigKind::IdentifierNode),
            Some(ZigKind::Number) => self.leaf(ZigKind::NumberLiteral),
            Some(ZigKind::UnreachableKeyword) => self.leaf(ZigKind::UnreachableLiteral),
            Some(ZigKind::TextLine) => self.multiline_text(),
            Some(_) if is_literal(kind) => self.leaf(literal_node(kind)),
            Some(ZigKind::Builtin) => self.builtin_call(),
            Some(ZigKind::Dot) => self.dotted(),
            Some(ZigKind::ErrorKeyword) => self.error_of(),
            Some(ZigKind::AnyframeKeyword) => self.anyframe_of(),
            Some(ZigKind::Question) => self.prefix(ZigKind::OptionalType, POWER_PREFIX, STAGE_TYPE),
            Some(ZigKind::Star | ZigKind::StarStar) => self.pointer_type(),
            Some(ZigKind::BracketOpen) => self.bracket_type(),
            Some(ZigKind::ParenOpen) => {
                let checkpoint = self.anchor();

                self.open_group(Variant::Paren, checkpoint, ZigKind::GroupedExpression)
            }
            Some(ZigKind::BraceOpen) => {
                let checkpoint = self.anchor();

                self.block_at(checkpoint);

                self.settle(checkpoint, false)
            }
            Some(ZigKind::FnKeyword) => self.function_type(),
            Some(ZigKind::IfKeyword) => self.if_expression(base),
            Some(ZigKind::SwitchKeyword) => self.switch_expression(),
            Some(ZigKind::WhileKeyword | ZigKind::ForKeyword) => self.loop_expression(base),
            Some(ZigKind::AsmKeyword) => self.assembly(),
            Some(ZigKind::BreakKeyword | ZigKind::ContinueKeyword) => self.branch(kind),
            Some(ZigKind::ReturnKeyword) => self.keyword_prefix(ZigKind::Return),
            Some(ZigKind::ComptimeKeyword) => self.keyword_prefix(ZigKind::Comptime),
            Some(ZigKind::NosuspendKeyword) => self.keyword_prefix(ZigKind::Nosuspend),
            Some(ZigKind::ResumeKeyword) => self.keyword_prefix(ZigKind::Resume),
            Some(ZigKind::SuspendKeyword) => self.keyword_prefix(ZigKind::Suspend),
            Some(_) if opens_a_container(kind) => self.container_type(),
            Some(_) => match prefix_of(kind) {
                Some(node) => self.prefix(node, POWER_PREFIX, STAGE_VALUE),
                None => Step::Done,
            },
        }
    }

    fn leaf(&mut self, kind: ZigKind) -> Step {
        let checkpoint = self.anchor();

        self.wrap(kind);
        self.settle(checkpoint, true)
    }

    fn settle(&mut self, checkpoint: Checkpoint, suffixable: bool) -> Step {
        self.push_value(checkpoint);
        self.suffixable = suffixable;

        Step::Operator
    }

    fn multiline_text(&mut self) -> Step {
        let checkpoint = self.anchor();

        self.open(ZigKind::MultilineStringLiteral);

        for _ in 0..CHAIN_DEPTH_MAX {
            if !self.at(ZigKind::TextLine) {
                break;
            }

            self.bump();
        }

        self.events.finish();

        self.settle(checkpoint, true)
    }

    fn builtin_call(&mut self) -> Step {
        let checkpoint = self.anchor();

        self.bump();

        if !self.at(ZigKind::ParenOpen) {
            return self.settle(checkpoint, true);
        }

        self.open_group(Variant::Call, checkpoint, ZigKind::BuiltinCall)
    }

    fn dotted(&mut self) -> Step {
        let checkpoint = self.anchor();

        if self.ahead(1) == Some(ZigKind::BraceOpen) {
            self.bump();

            return self.open_group(Variant::Init, checkpoint, ZigKind::StructInitDot);
        }

        self.open(ZigKind::EnumLiteral);
        self.emit();

        if self.at(ZigKind::Identifier) {
            self.bump();
        }

        self.events.finish();

        self.settle(checkpoint, true)
    }

    fn error_of(&mut self) -> Step {
        let checkpoint = self.anchor();

        if self.ahead(1) == Some(ZigKind::Dot) {
            self.open(ZigKind::ErrorValue);
            self.emit();
            self.bump();

            if self.at(ZigKind::Identifier) {
                self.bump();
            }

            self.events.finish();

            return self.settle(checkpoint, true);
        }

        self.open(ZigKind::ErrorSetDecl);
        self.bump();

        if self.eat(ZigKind::BraceOpen) {
            for _ in 0..CHAIN_DEPTH_MAX {
                self.skip_trivia();

                if self.at(ZigKind::BraceClose) || self.current().is_none() {
                    break;
                }

                let before = self.position;

                self.bump();

                if !self.eat(ZigKind::Comma) {
                    break;
                }

                if self.position == before {
                    break;
                }
            }

            let _ = self.eat(ZigKind::BraceClose);
        }

        self.events.finish();

        self.settle(checkpoint, true)
    }

    fn anyframe_of(&mut self) -> Step {
        if self.ahead(1) != Some(ZigKind::Minus) && self.ahead(1) != Some(ZigKind::Arrow) {
            return self.leaf(ZigKind::AnyframeLiteral);
        }

        let checkpoint = self.anchor();

        let frame = Frame {
            checkpoint,
            kind: ZigKind::AnyframeType,
            power: POWER_PREFIX,
            stage: STAGE_TYPE,
            values: self.value_count,
            variant: Variant::Unary,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        self.bump();
        self.bump();

        if self.at(ZigKind::Greater) {
            self.bump();
        }

        Step::Operand
    }

    fn pointer_type(&mut self) -> Step {
        let doubled = self.at(ZigKind::StarStar);
        let checkpoint = self.anchor();

        if doubled {
            let frame = Frame {
                checkpoint,
                kind: ZigKind::PtrType,
                power: POWER_PREFIX,
                stage: STAGE_TYPE,
                values: self.value_count,
                variant: Variant::Unary,
                ..Frame::EMPTY
            };

            if !self.push_frame(frame) {
                return Step::Done;
            }
        }

        let frame = Frame {
            checkpoint,
            kind: ZigKind::PtrType,
            power: POWER_PREFIX,
            stage: STAGE_TYPE,
            values: self.value_count,
            variant: Variant::Unary,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        self.bump();
        self.pointer_attributes();

        Step::Operand
    }

    fn bracket_type(&mut self) -> Step {
        let checkpoint = self.anchor();
        let mut kind = ZigKind::PtrType;

        self.bump();

        match self.current().unwrap_or(ZigKind::ErrorToken) {
            ZigKind::Star => {
                self.bump();

                if self.at(ZigKind::Identifier) {
                    self.bump();
                }
            }
            ZigKind::BracketClose | ZigKind::Colon => {}
            _ => {
                kind = ZigKind::ArrayType;
                self.expression();
            }
        }

        if self.eat(ZigKind::Colon) {
            self.expression();
        }

        let _ = self.eat(ZigKind::BracketClose);
        self.pointer_attributes();

        let frame = Frame {
            checkpoint,
            kind,
            power: POWER_PREFIX,
            stage: STAGE_TYPE,
            values: self.value_count,
            variant: Variant::Unary,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        Step::Operand
    }

    fn labels_a_loop(&self) -> bool {
        if self.at(ZigKind::InlineKeyword) {
            return matches!(
                self.ahead(1),
                Some(ZigKind::ForKeyword | ZigKind::WhileKeyword)
            );
        }

        if self.ahead(1) != Some(ZigKind::Colon) {
            return false;
        }

        matches!(
            self.ahead(2),
            Some(
                ZigKind::BraceOpen
                    | ZigKind::ForKeyword
                    | ZigKind::InlineKeyword
                    | ZigKind::SwitchKeyword
                    | ZigKind::WhileKeyword
            )
        )
    }

    fn labelled(&mut self, base: u32) -> Step {
        let checkpoint = self.anchor();

        if self.at(ZigKind::Identifier) {
            self.bump();
            self.bump();
        }

        let _ = self.eat(ZigKind::InlineKeyword);

        if self.at(ZigKind::BraceOpen) {
            self.block_at(checkpoint);

            return self.settle(checkpoint, false);
        }

        if self.at(ZigKind::SwitchKeyword) {
            return self.switch_at(checkpoint);
        }

        self.loop_at(checkpoint, base)
    }

    fn loop_expression(&mut self, base: u32) -> Step {
        let checkpoint = self.anchor();

        self.loop_at(checkpoint, base)
    }

    fn loop_at(&mut self, checkpoint: Checkpoint, base: u32) -> Step {
        let held = self.at(ZigKind::ForKeyword);

        self.bump();

        if held {
            self.for_inputs();
        } else {
            let _ = self.eat(ZigKind::ParenOpen);
            self.expression();
            let _ = self.eat(ZigKind::ParenClose);
        }

        self.payload();

        if self.eat(ZigKind::Colon) {
            let _ = self.eat(ZigKind::ParenOpen);
            self.assign_expression();
            let _ = self.eat(ZigKind::ParenClose);
        }

        self.branch_body(base);

        if self.eat(ZigKind::ElseKeyword) {
            self.payload();
            self.branch_body(base);
        }

        self.events
            .start_at(checkpoint, if held { ZigKind::For } else { ZigKind::While });
        self.events.finish();

        self.settle(checkpoint, false)
    }

    fn for_inputs(&mut self) {
        if !self.eat(ZigKind::ParenOpen) {
            return;
        }

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if self.at(ZigKind::ParenClose) || self.current().is_none() {
                break;
            }

            let before = self.position;
            let checkpoint = self.anchor();

            self.expression();

            if self.eat(ZigKind::DotDot) {
                if !self.at(ZigKind::ParenClose) && !self.at(ZigKind::Comma) {
                    self.expression();
                }

                self.events.start_at(checkpoint, ZigKind::ForRange);
                self.events.finish();
            }

            if !self.eat(ZigKind::Comma) {
                break;
            }

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(ZigKind::ParenClose);
    }

    fn if_expression(&mut self, base: u32) -> Step {
        let checkpoint = self.anchor();

        self.bump();
        let _ = self.eat(ZigKind::ParenOpen);
        self.expression();
        let _ = self.eat(ZigKind::ParenClose);
        self.payload();
        self.branch_body(base);

        if self.eat(ZigKind::ElseKeyword) {
            self.payload();
            self.branch_body(base);
        }

        self.events.start_at(checkpoint, ZigKind::If);
        self.events.finish();

        self.settle(checkpoint, false)
    }

    fn branch_body(&mut self, base: u32) {
        if self.at(ZigKind::BraceOpen) {
            self.block();

            return;
        }

        let checkpoint = self.anchor();
        let stage = self.context(base);

        self.expression_staged(stage);

        if stage != CONTEXT_STATEMENT {
            return;
        }

        let Some(node) = self.current().and_then(assignment_of) else {
            return;
        };

        self.bump();
        self.expression();
        self.events.start_at(checkpoint, node);
        self.events.finish();
    }

    fn switch_expression(&mut self) -> Step {
        let checkpoint = self.anchor();

        self.switch_at(checkpoint)
    }

    fn switch_at(&mut self, checkpoint: Checkpoint) -> Step {
        self.bump();
        let _ = self.eat(ZigKind::ParenOpen);
        self.expression();
        let _ = self.eat(ZigKind::ParenClose);
        self.expect(ZigKind::BraceOpen, SyntaxErrorKind::UnexpectedToken);

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if self.at(ZigKind::BraceClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.switch_case();

            if !self.eat(ZigKind::Comma) {
                break;
            }

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(ZigKind::BraceClose);
        self.events.start_at(checkpoint, ZigKind::Switch);
        self.events.finish();

        self.settle(checkpoint, false)
    }

    fn switch_case(&mut self) {
        if !self.descend() {
            self.emit();

            return;
        }

        self.switch_case_of();
        self.ascend();
    }

    fn switch_case_of(&mut self) {
        let checkpoint = self.anchor();
        let _ = self.eat(ZigKind::InlineKeyword);

        if !self.eat(ZigKind::ElseKeyword) {
            for _ in 0..CHAIN_DEPTH_MAX {
                let held = self.anchor();

                self.expression();

                if self.eat(ZigKind::DotDotDot) {
                    self.expression();
                    self.events.start_at(held, ZigKind::SwitchRange);
                    self.events.finish();
                }

                if !self.eat(ZigKind::Comma) {
                    break;
                }

                if self.at(ZigKind::Arrow) {
                    break;
                }
            }
        }

        let _ = self.eat(ZigKind::Arrow);
        self.payload();

        if self.at(ZigKind::BraceOpen) {
            self.block();
        } else {
            self.assign_expression();
        }

        self.events.start_at(checkpoint, ZigKind::SwitchCase);
        self.events.finish();
    }

    fn branch(&mut self, kind: ZigKind) -> Step {
        let checkpoint = self.anchor();

        let node = if kind == ZigKind::BreakKeyword {
            ZigKind::Break
        } else {
            ZigKind::Continue
        };

        let frame = Frame {
            checkpoint,
            kind: node,
            power: POWER_BARRIER,
            stage: STAGE_KEEP,
            values: self.value_count,
            variant: Variant::Unary,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        self.bump();

        if self.eat(ZigKind::Colon) {
            let _ = self.eat(ZigKind::Identifier);
        }

        Step::Operand
    }

    fn container_type(&mut self) -> Step {
        let checkpoint = self.anchor();
        let mut kind = ZigKind::ContainerDecl;
        let _ = self.eat(ZigKind::ExternKeyword);
        let _ = self.eat(ZigKind::PackedKeyword);
        let tagged = self.at(ZigKind::UnionKeyword) && self.ahead(1) == Some(ZigKind::ParenOpen);

        self.bump();

        if self.eat(ZigKind::ParenOpen) {
            if tagged && self.eat(ZigKind::EnumKeyword) {
                kind = ZigKind::TaggedUnion;

                if self.eat(ZigKind::ParenOpen) {
                    self.type_of();
                    let _ = self.eat(ZigKind::ParenClose);
                }
            } else {
                self.type_of();
            }

            let _ = self.eat(ZigKind::ParenClose);
        }

        self.container_body();
        self.events.start_at(checkpoint, kind);
        self.events.finish();

        self.settle(checkpoint, true)
    }

    fn container_body(&mut self) {
        if !self.descend() {
            self.emit();

            return;
        }

        self.container_body_of();
        self.ascend();
    }

    fn container_body_of(&mut self) {
        if !self.eat(ZigKind::BraceOpen) {
            return;
        }

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if self.at(ZigKind::BraceClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.member();

            if self.position == before {
                self.record(SyntaxErrorKind::UnexpectedToken);
                self.emit();
            }
        }

        let _ = self.eat(ZigKind::BraceClose);
    }

    fn function_type(&mut self) -> Step {
        let checkpoint = self.anchor();

        self.bump();
        self.parameter_list();
        self.callable_attributes();
        let _ = self.eat(ZigKind::Bang);
        self.type_of();
        self.events.start_at(checkpoint, ZigKind::FnProto);
        self.events.finish();

        self.settle(checkpoint, true)
    }

    fn assembly(&mut self) -> Step {
        let checkpoint = self.anchor();

        self.bump();
        let _ = self.eat(ZigKind::VolatileKeyword);
        let _ = self.eat(ZigKind::ParenOpen);
        self.expression();

        for section in 0..3_u32 {
            if !self.eat(ZigKind::Colon) {
                break;
            }

            if section == 2 {
                if !self.at(ZigKind::ParenClose) {
                    self.expression();
                }

                break;
            }

            self.assembly_operands();
        }

        let _ = self.eat(ZigKind::ParenClose);
        self.events.start_at(checkpoint, ZigKind::Asm);
        self.events.finish();

        self.settle(checkpoint, false)
    }

    fn assembly_operands(&mut self) {
        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if !self.at(ZigKind::BracketOpen) && !self.at(ZigKind::Text) {
                break;
            }

            let before = self.position;
            let checkpoint = self.anchor();
            let mut named = false;

            if self.eat(ZigKind::BracketOpen) {
                named = true;
                let _ = self.eat(ZigKind::Identifier);
                let _ = self.eat(ZigKind::BracketClose);
            }

            let _ = self.eat(ZigKind::Text);

            let output =
                self.ahead(1) == Some(ZigKind::Minus) && self.ahead(2) == Some(ZigKind::Greater);

            if self.eat(ZigKind::ParenOpen) {
                if output {
                    let _ = self.eat(ZigKind::Minus);
                    let _ = self.eat(ZigKind::Greater);
                    self.type_of();
                } else {
                    self.expression();
                }

                let _ = self.eat(ZigKind::ParenClose);
            }

            if named {
                self.events.start_at(
                    checkpoint,
                    if output {
                        ZigKind::AsmOutput
                    } else {
                        ZigKind::AsmInput
                    },
                );
                self.events.finish();
            }

            if !self.eat(ZigKind::Comma) {
                break;
            }

            if self.position == before {
                break;
            }
        }
    }

    fn operator_step(&mut self, base: u32) -> Step {
        self.skip_trivia();

        let group = self.innermost_group(base);

        let Some(kind) = self.current() else {
            return Step::Done;
        };

        let frame = self.frames[group as usize];

        if frame.is_bracketed() && kind == frame.closer {
            self.close_group(group);

            return Step::Operator;
        }

        if kind == ZigKind::Comma {
            return self.comma(group);
        }

        if frame.variant == Variant::Index && matches!(kind, ZigKind::Colon | ZigKind::DotDot) {
            self.reduce_above(group + 1);
            self.bump();
            self.frames[group as usize].stage = 1;

            return Step::Operand;
        }

        match Some(kind) {
            Some(ZigKind::Dot) => self.field_access(),
            Some(ZigKind::DotAsterisk) => self.suffix(ZigKind::Deref),
            Some(ZigKind::DotQuestion) => self.suffix(ZigKind::UnwrapOptional),
            Some(ZigKind::ParenOpen) => self.trailer(Variant::Call, ZigKind::Call),
            Some(ZigKind::BracketOpen) => self.trailer(Variant::Index, ZigKind::ArrayAccess),
            Some(ZigKind::BraceOpen) if self.suffixable && self.curly_allowed(base) => {
                self.drain_types();

                self.trailer(Variant::Init, ZigKind::StructInit)
            }
            Some(_) | None => match infix_of(kind) {
                Some((node, left, right)) => self.binary(node, left, right),
                None => Step::Done,
            },
        }
    }

    fn drain_types(&mut self) {
        for _ in 0..EXPRESSION_DEPTH_MAX {
            if self.frame_count == 0 {
                return;
            }

            let top = self.frames[self.frame_count as usize - 1];

            if top.variant != Variant::Unary || top.stage != STAGE_TYPE {
                return;
            }

            self.reduce_top();
        }
    }

    fn field_access(&mut self) -> Step {
        if self.value_count == 0 {
            return Step::Done;
        }

        let checkpoint = self.values[self.value_count as usize - 1];

        self.events.start_at(checkpoint, ZigKind::FieldAccess);
        self.bump();

        if self.at(ZigKind::Identifier) {
            self.bump();
        }

        self.events.finish();
        self.suffixable = true;

        Step::Operator
    }

    fn suffix(&mut self, kind: ZigKind) -> Step {
        if self.value_count == 0 {
            return Step::Done;
        }

        let checkpoint = self.values[self.value_count as usize - 1];

        self.events.start_at(checkpoint, kind);
        self.bump();
        self.events.finish();
        self.suffixable = true;

        Step::Operator
    }

    fn trailer(&mut self, variant: Variant, kind: ZigKind) -> Step {
        if self.value_count == 0 {
            return Step::Done;
        }

        let checkpoint = self.values[self.value_count as usize - 1];

        self.value_count -= 1;

        let node = if variant == Variant::Init && kind == ZigKind::StructInit {
            ZigKind::StructInit
        } else {
            kind
        };

        self.open_group(variant, checkpoint, node)
    }

    fn comma(&mut self, group: u32) -> Step {
        let frame = self.frames[group as usize];

        if frame.variant == Variant::Top || frame.variant == Variant::Paren {
            return Step::Done;
        }

        self.reduce_above(group + 1);
        self.bump();
        self.value_count = frame.values;
        self.frames[group as usize].elements += 1;
        self.frames[group as usize].element_values = self.value_count;

        Step::Operand
    }
}

const fn init_kind(frame: Frame) -> ZigKind {
    let dotted = matches!(frame.kind, ZigKind::StructInitDot);

    if frame.stage == 1 {
        if dotted {
            return ZigKind::ArrayInitDot;
        }

        return ZigKind::ArrayInit;
    }

    if dotted {
        return ZigKind::StructInitDot;
    }

    ZigKind::StructInit
}

pub fn build(
    source: &[u8],
    tokens: &[Token],
    raw: &[ZigKind],
    events: &mut Events<ZigKind>,
    tree: &mut Tree<ZigKind>,
) -> Structure {
    assert!(u32::try_from(source.len()).is_ok());
    assert_eq!(tokens.len(), raw.len());

    events.clear();
    tree.clear();

    let mut parser = Parser {
        events,
        frame_count: 0,
        frames: [Frame::EMPTY; EXPRESSION_DEPTH_MAX as usize],
        nesting: 0,
        outcome: Structure::Complete,
        position: 0,
        raw,
        significant_next: 0,
        suffixable: true,
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
