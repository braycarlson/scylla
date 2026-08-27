use crate::bounded::{Span, count_of};
use crate::syntax::odin::expression::{
    EXPRESSION_DEPTH_MAX,
    Frame,
    POWER_BARRIER,
    POWER_CAST,
    POWER_PREFIX,
    POWER_RANGE_LEFT,
    VALUE_COUNT_MAX,
    Variant,
    assignment_of,
    infix_of,
    is_name,
    is_prefix,
    literal_node,
    opens_a_type,
};
use crate::syntax::odin::kind::OdinKind;
use crate::syntax::{SyntaxError, SyntaxErrorKind};
use crate::token::Token;
use crate::tree::{Checkpoint, Events, Structure, Tree, replay};

const NEST_DEPTH_MAX: u32 = 96;
const STAGE_VALUE: u8 = 0;
const CONTEXT_HEADER: u8 = 2;
const CONTEXT_CONDITIONAL: u8 = 5;
const CONTEXT_ELEMENT: u8 = 4;
const CONTEXT_ITERATION: u8 = 3;
const CONTEXT_TYPE: u8 = 0;
const CONTEXT_VALUE: u8 = 1;
const STAGE_MEMBER: u8 = 1;
const STAGE_SELECTOR: u8 = 2;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Step {
    Done,
    Operand,
    Operator,
}

struct Parser<'run> {
    events: &'run mut Events<OdinKind>,
    file_scope: bool,
    frame_count: u32,
    frames: [Frame; EXPRESSION_DEPTH_MAX as usize],
    nesting: u32,
    outcome: Structure,
    position: u32,
    raw: &'run [OdinKind],
    significant_next: u32,
    source: &'run [u8],
    suffixable: bool,
    tokens: &'run [Token],
    tree: &'run mut Tree<OdinKind>,
    value_count: u32,
    values: [Checkpoint; VALUE_COUNT_MAX as usize],
}

const fn trailer_node(stage: u8) -> Option<OdinKind> {
    match stage {
        STAGE_MEMBER => Some(OdinKind::MemberExpression),
        STAGE_SELECTOR => Some(OdinKind::SelectorCallExpression),
        _ => None,
    }
}

const fn is_layout(kind: OdinKind) -> bool {
    is_trivia(kind) || matches!(kind, OdinKind::Newline)
}

const fn is_trivia(kind: OdinKind) -> bool {
    matches!(
        kind,
        OdinKind::Comment | OdinKind::CommentBlock | OdinKind::CommentTag
    )
}

impl Parser<'_> {
    fn count(&self) -> u32 {
        count_of(self.raw.len())
    }

    fn steps(&self) -> u32 {
        self.count() + 1
    }

    fn kind_at(&self, position: u32) -> Option<OdinKind> {
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
            if !is_trivia(kind) {
                break;
            }

            position += 1;
        }

        position
    }

    fn current(&self) -> Option<OdinKind> {
        self.kind_at(self.significant(self.position))
    }

    fn ahead(&self, steps: u32) -> Option<OdinKind> {
        self.kind_at(self.ahead_position(steps))
    }

    fn ahead_position(&self, steps: u32) -> u32 {
        let mut position = self.significant(self.position);

        for _ in 0..steps {
            position = self.significant(position + 1);
        }

        position
    }

    fn at_name(&self) -> bool {
        self.current().is_some_and(is_name)
    }

    fn at(&self, kind: OdinKind) -> bool {
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
        while self.kind_at(self.position).is_some_and(is_trivia) {
            self.trivia_step();
        }
    }

    fn trivia_step(&mut self) {
        if self.builds_a_tag() {
            self.events.start(OdinKind::BuildTag);
            self.mark();
            self.events.finish();

            return;
        }

        self.emit();
    }

    fn mark(&mut self) {
        self.events.token(self.position);
        self.position += 1;

        if self.position > self.significant_next {
            self.significant_next = self.scan_significant(self.position);
        }
    }

    fn builds_a_tag(&self) -> bool {
        if self.kind_at(self.position) != Some(OdinKind::CommentTag) {
            return false;
        }

        self.tokens
            .get(self.position as usize)
            .is_some_and(|token| token.text(self.source).starts_with(b"#+"))
    }

    fn anchor(&mut self) -> Checkpoint {
        self.skip_trivia();

        self.events.checkpoint()
    }

    fn open(&mut self, kind: OdinKind) {
        self.skip_trivia();
        self.events.start(kind);
    }

    fn bump(&mut self) {
        self.skip_trivia();
        self.emit();
    }

    fn eat(&mut self, kind: OdinKind) -> bool {
        if !self.at(kind) {
            return false;
        }

        self.bump();

        true
    }

    fn expect(&mut self, kind: OdinKind, failure: SyntaxErrorKind) -> bool {
        if self.eat(kind) {
            return true;
        }

        self.record(failure);

        false
    }

    fn wrap(&mut self, kind: OdinKind) {
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

    fn skip_breaks(&mut self) {
        while self.kind_at(self.position).is_some_and(is_layout) {
            self.trivia_step();
        }
    }

    fn terminator(&mut self) {
        if !self.eat(OdinKind::Semicolon) {
            let _ = self.eat(OdinKind::Newline);
        }
    }

    fn ends_here(&self) -> bool {
        matches!(
            self.current(),
            None | Some(
                OdinKind::BraceClose
                    | OdinKind::CaseKeyword
                    | OdinKind::Newline
                    | OdinKind::ParenClose
                    | OdinKind::Semicolon
            )
        )
    }

    fn run(&mut self) {
        self.events.start(OdinKind::SourceFile);
        self.skip_breaks();

        if self.at(OdinKind::PackageKeyword) {
            let checkpoint = self.anchor();

            self.bump();
            self.name();

            self.events
                .start_at(checkpoint, OdinKind::PackageDeclaration);
            self.events.finish();
            self.terminator();
        }

        for _ in 0..u32::MAX {
            self.skip_breaks();

            if self.current().is_none() {
                break;
            }

            let before = self.position;

            self.declaration();

            if self.position == before {
                self.record(SyntaxErrorKind::UnexpectedToken);
                self.emit();
            }
        }

        self.events.finish();
    }

    fn name(&mut self) {
        if !self.at_name() {
            return;
        }

        self.wrap(OdinKind::IdentifierNode);
    }

    fn name_list(&mut self) {
        for _ in 0..self.steps() {
            if !self.at_name() {
                break;
            }

            self.name();

            if !self.eat(OdinKind::Comma) {
                break;
            }
        }
    }

    fn declaration(&mut self) {
        if !self.descend() {
            self.emit();

            return;
        }

        self.declaration_of();
        self.ascend();
    }

    fn declaration_of(&mut self) {
        let checkpoint = self.anchor();

        self.attributes();

        match self.current() {
            None => {}
            Some(OdinKind::ImportKeyword) => self.import_declaration(checkpoint),
            Some(OdinKind::ForeignKeyword) => self.foreign(checkpoint),
            Some(OdinKind::WhenKeyword) => self.when_statement(checkpoint),
            Some(OdinKind::UsingKeyword) => self.using_statement(checkpoint),
            Some(_) => {
                self.bound_declaration(checkpoint);
            }
        }
    }

    fn attributes(&mut self) {
        if !self.at(OdinKind::At) {
            return;
        }

        let checkpoint = self.anchor();

        for _ in 0..self.steps() {
            if !self.at(OdinKind::At) {
                if !self.marks_an_attribute() {
                    break;
                }

                self.skip_breaks();
            }

            let held = self.anchor();

            self.bump();

            if self.at(OdinKind::ParenOpen) {
                self.attribute_arguments();
            } else {
                self.name();
            }

            self.events.start_at(held, OdinKind::Attribute);
            self.events.finish();
        }

        self.events.start_at(checkpoint, OdinKind::Attributes);
        self.events.finish();
        self.skip_breaks();
    }

    fn marks_an_attribute(&self) -> bool {
        let mut position = self.position;

        for _ in 0..self.steps() {
            match self.kind_at(position) {
                Some(OdinKind::At) => return true,
                Some(kind) if is_layout(kind) => position += 1,
                Some(_) | None => return false,
            }
        }

        false
    }

    fn attribute_arguments(&mut self) {
        let _ = self.eat(OdinKind::ParenOpen);

        for _ in 0..self.steps() {
            self.skip_breaks();

            if self.at(OdinKind::ParenClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.name();

            if self.eat(OdinKind::Equal) {
                self.expression();
            }

            if !self.eat(OdinKind::Comma) {
                break;
            }

            if self.position == before {
                self.emit();
            }
        }

        self.skip_breaks();
        let _ = self.eat(OdinKind::ParenClose);
    }

    fn import_declaration(&mut self, checkpoint: Checkpoint) {
        self.bump();
        self.name();

        if self.at(OdinKind::Text) {
            self.wrap(OdinKind::String);
        }

        self.events
            .start_at(checkpoint, OdinKind::ImportDeclaration);
        self.events.finish();
        self.terminator();
    }

    fn foreign(&mut self, checkpoint: Checkpoint) {
        self.bump();

        if self.at(OdinKind::ImportKeyword) {
            self.import_declaration(checkpoint);

            return;
        }

        self.name();
        self.reach_a_brace();
        self.block();
        self.events.start_at(checkpoint, OdinKind::ForeignBlock);
        self.events.finish();
        self.terminator();
    }

    fn using_statement(&mut self, checkpoint: Checkpoint) {
        self.bump();
        self.expression();
        self.events.start_at(checkpoint, OdinKind::UsingStatement);
        self.events.finish();
        self.terminator();
    }

    fn bound_declaration(&mut self, checkpoint: Checkpoint) {
        if !self.at_name() {
            self.statement_at(checkpoint);

            return;
        }

        let binder = self.binder();

        match binder {
            Some(OdinKind::ColonColon) => self.constant_declaration(checkpoint),
            Some(OdinKind::Colon) => self.variable_declaration(checkpoint),
            Some(_) | None => self.statement_at(checkpoint),
        }
    }

    fn binder(&self) -> Option<OdinKind> {
        let mut position = self.significant(self.position);

        for _ in 0..self.steps() {
            if !self.kind_at(position).is_some_and(is_name) {
                return None;
            }

            position = self.significant(position + 1);

            match self.kind_at(position) {
                Some(OdinKind::Colon | OdinKind::ColonColon) => {
                    return self.kind_at(position);
                }
                Some(OdinKind::Comma) => {
                    position = self.significant(position + 1);
                }
                Some(_) | None => return None,
            }
        }

        None
    }

    fn constant_declaration(&mut self, checkpoint: Checkpoint) {
        self.name_list();
        self.bump();
        self.attributes();

        let kind = self.constant_kind();

        if kind == OdinKind::ProcedureDeclaration && self.opens_an_overload() {
            self.overloaded(checkpoint);

            return;
        }

        if kind == OdinKind::ConstTypeDeclaration {
            self.type_of();
        } else if kind == OdinKind::ConstDeclaration {
            self.expression();
        } else {
            self.container_value();
        }

        self.events.start_at(checkpoint, kind);
        self.events.finish();
        self.terminator();
    }

    fn constant_kind(&self) -> OdinKind {
        let mut position = self.significant(self.position);

        for _ in 0..self.steps() {
            let Some(kind) = self.kind_at(position) else {
                return OdinKind::ConstDeclaration;
            };

            if kind == OdinKind::Directive {
                position = self.significant(position + 1);

                continue;
            }

            return match Some(kind) {
                Some(OdinKind::StructKeyword) => OdinKind::StructDeclaration,
                Some(OdinKind::EnumKeyword) => OdinKind::EnumDeclaration,
                Some(OdinKind::UnionKeyword) => OdinKind::UnionDeclaration,
                Some(OdinKind::BitFieldKeyword) => OdinKind::BitFieldDeclaration,
                Some(OdinKind::ProcKeyword) => OdinKind::ProcedureDeclaration,
                Some(_) | None => OdinKind::ConstDeclaration,
            };
        }

        OdinKind::ConstDeclaration
    }

    fn opens_an_overload(&self) -> bool {
        let mut position = self.significant(self.position);

        while self.kind_at(position) == Some(OdinKind::Directive) {
            position = self.significant(position + 1);
        }

        if self.kind_at(position) != Some(OdinKind::ProcKeyword) {
            return false;
        }

        self.kind_at(self.significant(position + 1)) == Some(OdinKind::BraceOpen)
    }

    fn overloaded(&mut self, checkpoint: Checkpoint) {
        for _ in 0..self.steps() {
            if !self.at(OdinKind::Directive) {
                break;
            }

            self.bump();
        }

        self.bump();
        let _ = self.eat(OdinKind::BraceOpen);

        for _ in 0..self.steps() {
            self.skip_breaks();

            if self.at(OdinKind::BraceClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.expression();

            if !self.eat(OdinKind::Comma) {
                break;
            }

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(OdinKind::BraceClose);

        self.events
            .start_at(checkpoint, OdinKind::OverloadedProcedureDeclaration);
        self.events.finish();
        self.terminator();
    }

    fn variable_declaration(&mut self, checkpoint: Checkpoint) {
        self.name_list();
        self.bump();

        if !self.at(OdinKind::Equal) && !self.ends_here() {
            self.type_of();
        }

        if self.eat(OdinKind::Colon) {
            self.expression();

            self.events
                .start_at(checkpoint, OdinKind::ConstTypeDeclaration);
            self.events.finish();
            self.terminator();

            return;
        }

        if self.eat(OdinKind::Equal) {
            self.expression_list();
        }

        self.events.start_at(checkpoint, OdinKind::VarDeclaration);
        self.events.finish();
        self.terminator();
    }

    fn container_value(&mut self) {
        self.directives();

        match self.current() {
            Some(OdinKind::ProcKeyword) => self.procedure(),
            Some(OdinKind::StructKeyword | OdinKind::BitFieldKeyword) => self.record_body(),
            Some(OdinKind::EnumKeyword) => self.enumeration_body(),
            Some(OdinKind::UnionKeyword) => self.union_body(),
            Some(_) | None => self.expression(),
        }
    }

    fn procedure(&mut self) {
        let checkpoint = self.anchor();

        self.bump();

        if self.at(OdinKind::Text) {
            self.wrap(OdinKind::CallingConvention);
        }

        self.parameters();

        if self.eat(OdinKind::Arrow) {
            self.results();
        }

        self.qualifiers();

        match self.current().unwrap_or(OdinKind::ErrorToken) {
            OdinKind::MinusMinusMinus => self.wrap(OdinKind::Uninitialized),
            current if current == OdinKind::BraceOpen || self.brace_follows() => {
                self.reach_a_brace();
                self.block();
            }
            _ => {}
        }

        self.events.start_at(checkpoint, OdinKind::Procedure);
        self.events.finish();
    }

    fn qualifiers(&mut self) {
        for _ in 0..self.steps() {
            if self.at(OdinKind::Directive) {
                self.wrap(OdinKind::Tag);

                if self.at(OdinKind::Number) {
                    self.wrap(OdinKind::NumberNode);
                }

                continue;
            }

            self.reach_a_where();

            if self.at(OdinKind::WhereKeyword) {
                self.where_clause();

                continue;
            }

            return;
        }
    }

    fn reach_a_where(&mut self) {
        let mut position = self.position;

        for _ in 0..self.steps() {
            match self.kind_at(position) {
                Some(OdinKind::WhereKeyword) => break,
                Some(kind) if is_layout(kind) => position += 1,
                Some(_) | None => return,
            }
        }

        self.skip_breaks();
    }

    fn directives(&mut self) {
        for _ in 0..self.steps() {
            if !self.at(OdinKind::Directive) {
                break;
            }

            self.wrap(OdinKind::Tag);
        }
    }

    fn where_clause(&mut self) {
        let checkpoint = self.anchor();

        self.bump();
        self.expression_list_with(false);
        self.events.start_at(checkpoint, OdinKind::WhereClause);
        self.events.finish();
    }

    fn parameters(&mut self) {
        if !self.at(OdinKind::ParenOpen) {
            return;
        }

        let checkpoint = self.anchor();

        self.bump();

        for _ in 0..self.steps() {
            self.skip_breaks();

            if self.at(OdinKind::ParenClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.parameter();

            if !self.eat(OdinKind::Comma) {
                break;
            }

            if self.position == before {
                self.emit();
            }
        }

        self.skip_breaks();
        let _ = self.eat(OdinKind::ParenClose);
        self.events.start_at(checkpoint, OdinKind::Parameters);
        self.events.finish();
    }

    fn parameter(&mut self) {
        let checkpoint = self.anchor();
        let _ = self.eat(OdinKind::UsingKeyword);

        self.directives();

        let _ = self.eat(OdinKind::Dollar);

        if self.at_name() && self.ahead(1) == Some(OdinKind::ColonEqual) {
            self.name();
            self.bump();
            self.expression();
            self.events.start_at(checkpoint, OdinKind::DefaultParameter);
            self.events.finish();

            return;
        }

        if self.at_name() && self.names_a_parameter() {
            self.name_list();
            self.bump();
            self.directives();
            self.type_of();
            self.name();

            if self.eat(OdinKind::Equal) {
                self.expression();
            }

            self.events.start_at(checkpoint, OdinKind::Parameter);
            self.events.finish();

            return;
        }

        self.type_of();
        self.events.start_at(checkpoint, OdinKind::Parameter);
        self.events.finish();
    }

    fn names_a_parameter(&self) -> bool {
        let mut position = self.significant(self.position);

        for _ in 0..self.steps() {
            if !self.kind_at(position).is_some_and(is_name) {
                return false;
            }

            position = self.significant(position + 1);

            match self.kind_at(position) {
                Some(OdinKind::Colon) => return true,
                Some(OdinKind::Comma) => position = self.significant(position + 1),
                Some(_) | None => return false,
            }
        }

        false
    }

    fn results(&mut self) {
        if self.at(OdinKind::Bang) {
            self.open(OdinKind::Type);
            self.open(OdinKind::EmptyType);
            self.bump();
            self.events.finish();
            self.events.finish();

            return;
        }

        self.type_of();
    }

    fn result(&mut self) {
        if self.at_name() && self.ahead(1) == Some(OdinKind::ColonEqual) {
            self.open(OdinKind::DefaultType);
            self.name();
            self.bump();
            self.expression();
            self.events.finish();

            return;
        }

        if !self.at_name() || !self.names_a_parameter() {
            self.type_of();

            return;
        }

        for _ in 0..self.steps() {
            let checkpoint = self.anchor();

            self.name();

            if self.eat(OdinKind::Comma) {
                continue;
            }

            let _ = self.eat(OdinKind::Colon);
            self.type_of();

            if self.eat(OdinKind::Equal) {
                self.expression();
            }

            self.events.start_at(checkpoint, OdinKind::NamedType);
            self.events.finish();

            return;
        }
    }

    fn record_body(&mut self) {
        self.record_body_of(OdinKind::Field);
    }

    fn record_body_of(&mut self, member: OdinKind) {
        let checkpoint = self.anchor();
        let keyword = self.current();

        self.bump();

        if self.at(OdinKind::ParenOpen) {
            self.polymorphic_parameters();
        }

        self.qualifiers();

        if keyword == Some(OdinKind::BitFieldKeyword) {
            if !self.at(OdinKind::BraceOpen) {
                self.named_type();
            }

            self.bit_field_block();
            let _ = checkpoint;

            return;
        }

        if self.at(OdinKind::BracketOpen) {
            self.bump();
            self.type_of();
            let _ = self.eat(OdinKind::BracketClose);
        }

        self.field_block(member);

        let _ = checkpoint;
    }

    fn bit_field_block(&mut self) {
        if !self.eat(OdinKind::BraceOpen) {
            return;
        }

        for _ in 0..self.steps() {
            self.skip_breaks();

            if self.at(OdinKind::BraceClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.bit_field_member();

            if !self.eat(OdinKind::Comma) {
                self.terminator();
            }

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(OdinKind::BraceClose);
    }

    fn bit_field_member(&mut self) {
        self.directives();
        self.name();
        let _ = self.eat(OdinKind::Colon);
        self.named_type();

        if self.eat(OdinKind::Bar) {
            self.expression();
        }
    }

    fn named_type(&mut self) {
        let checkpoint = self.anchor();

        self.name();

        for _ in 0..self.steps() {
            if !self.eat(OdinKind::Dot) {
                break;
            }

            self.name();
        }

        self.events.start_at(checkpoint, OdinKind::Type);
        self.events.finish();
    }

    fn polymorphic_parameters(&mut self) {
        let checkpoint = self.anchor();

        self.bump();

        for _ in 0..self.steps() {
            self.skip_breaks();

            if self.at(OdinKind::ParenClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.polymorphic_group();

            if !self.eat(OdinKind::Comma) {
                break;
            }

            if self.position == before {
                self.emit();
            }
        }

        self.skip_breaks();
        let _ = self.eat(OdinKind::ParenClose);

        self.events
            .start_at(checkpoint, OdinKind::PolymorphicParameters);
        self.events.finish();
    }

    fn polymorphic_group(&mut self) {
        for _ in 0..self.steps() {
            let _ = self.eat(OdinKind::Dollar);

            if !self.at_name() {
                break;
            }

            self.name();

            if self.at(OdinKind::Colon) {
                break;
            }

            if !self.eat(OdinKind::Comma) {
                return;
            }
        }

        if self.eat(OdinKind::Colon) {
            self.type_of();
        }
    }

    fn field_block(&mut self, member: OdinKind) {
        if !self.descend() {
            self.emit();

            return;
        }

        self.field_block_of(member);
        self.ascend();
    }

    fn field_block_of(&mut self, member: OdinKind) {
        if !self.eat(OdinKind::BraceOpen) {
            return;
        }

        for _ in 0..self.steps() {
            self.skip_breaks();

            if self.at(OdinKind::BraceClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.field(member);

            if !self.eat(OdinKind::Comma) {
                self.terminator();
            }

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(OdinKind::BraceClose);
    }

    fn field(&mut self, member: OdinKind) {
        let checkpoint = self.anchor();
        let _ = self.eat(OdinKind::UsingKeyword);
        self.directives();
        let _ = self.eat(OdinKind::UsingKeyword);
        self.name_list();
        let _ = self.eat(OdinKind::Colon);
        self.type_of();

        if self.eat(OdinKind::Bar) {
            self.expression();
        }

        if self.at(OdinKind::Text) {
            self.wrap(OdinKind::String);
        }

        self.events.start_at(checkpoint, member);
        self.events.finish();
    }

    fn enumeration_body(&mut self) {
        self.bump();

        if !self.at(OdinKind::BraceOpen) && !self.brace_follows() {
            self.type_of();
        }

        self.reach_a_brace();
        let _ = self.eat(OdinKind::BraceOpen);

        for _ in 0..self.steps() {
            self.skip_breaks();

            if self.at(OdinKind::BraceClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.name();

            if self.eat(OdinKind::Equal) {
                self.expression();
            }

            if !self.eat(OdinKind::Comma) {
                self.terminator();
            }

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(OdinKind::BraceClose);
    }

    fn union_body(&mut self) {
        self.bump();

        if self.at(OdinKind::ParenOpen) {
            self.polymorphic_parameters();
        }

        self.qualifiers();
        self.reach_a_brace();
        let _ = self.eat(OdinKind::BraceOpen);

        for _ in 0..self.steps() {
            self.skip_breaks();

            if self.at(OdinKind::BraceClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.type_of();

            if !self.eat(OdinKind::Comma) {
                self.terminator();
            }

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(OdinKind::BraceClose);
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
        let held = self.file_scope;

        self.file_scope = false;

        self.expect(OdinKind::BraceOpen, SyntaxErrorKind::UnexpectedToken);

        for _ in 0..self.steps() {
            self.skip_breaks();

            if self.at(OdinKind::BraceClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.statement();

            if self.position == before {
                self.record(SyntaxErrorKind::UnexpectedToken);
                self.emit();
            }
        }

        let _ = self.eat(OdinKind::BraceClose);
        self.events.start_at(checkpoint, OdinKind::Block);
        self.events.finish();
        self.file_scope = held;
    }

    fn statement(&mut self) {
        if !self.descend() {
            self.emit();

            return;
        }

        let checkpoint = self.anchor();

        self.attributes();
        self.statement_at(checkpoint);
        self.ascend();
    }

    fn statement_at(&mut self, checkpoint: Checkpoint) {
        match self.current() {
            None => {}
            Some(OdinKind::Semicolon | OdinKind::Newline) => {
                self.bump();
            }
            Some(OdinKind::BraceOpen) => {
                self.block_at(checkpoint);
                self.terminator();
            }
            Some(OdinKind::ImportKeyword) => self.import_declaration(checkpoint),
            Some(OdinKind::ForeignKeyword) => self.foreign(checkpoint),
            Some(OdinKind::UsingKeyword) => self.using_statement(checkpoint),
            Some(OdinKind::WhenKeyword) => self.when_statement(checkpoint),
            Some(OdinKind::IfKeyword) => self.if_statement(checkpoint),
            Some(OdinKind::ForKeyword) => self.for_statement(checkpoint),
            Some(OdinKind::SwitchKeyword) => self.switch_statement(checkpoint, false),
            Some(OdinKind::Directive) if self.tags_a_block() => self.tagged_block(checkpoint),
            Some(OdinKind::Directive) if self.tags_an_assignment() || self.tags_a_statement() => {
                self.tagged_statement();
            }
            Some(OdinKind::ReturnKeyword) => self.return_statement(checkpoint),
            Some(OdinKind::DeferKeyword) => {
                self.bump();
                self.statement_body(checkpoint, OdinKind::DeferStatement);
            }
            Some(OdinKind::BreakKeyword) => self.branch(checkpoint, OdinKind::BreakStatement),
            Some(OdinKind::ContinueKeyword) => self.branch(checkpoint, OdinKind::ContinueStatement),
            Some(OdinKind::FallthroughKeyword) => {
                self.bump();

                self.events
                    .start_at(checkpoint, OdinKind::FallthroughStatement);
                self.events.finish();
                self.terminator();
            }
            Some(kind) if is_name(kind) && self.labels_a_block() => {
                self.name();
                self.bump();
                self.statement();
                self.events.start_at(checkpoint, OdinKind::LabelStatement);
                self.events.finish();
            }
            Some(kind) if is_name(kind) && self.binder().is_some() => {
                self.bound_declaration(checkpoint);
            }
            Some(_) => {
                self.expression_statement(checkpoint);
                self.terminator();
            }
        }
    }

    fn tagged_statement(&mut self) {
        self.wrap(OdinKind::Tag);

        let held = self.anchor();

        self.statement_at(held);
    }

    fn return_statement(&mut self, checkpoint: Checkpoint) {
        self.bump();

        if !self.ends_here() {
            self.expression_list();
        }

        self.events.start_at(checkpoint, OdinKind::ReturnStatement);
        self.events.finish();
        self.terminator();
    }

    fn tagged_block(&mut self, checkpoint: Checkpoint) {
        self.wrap(OdinKind::Tag);

        let held = self.anchor();

        self.block_at(held);
        self.events.start_at(checkpoint, OdinKind::TaggedBlock);
        self.events.finish();
        self.terminator();
    }

    fn tags_a_block(&self) -> bool {
        self.ahead(1) == Some(OdinKind::BraceOpen) && self.follows_a_tag()
    }

    fn follows_a_tag(&self) -> bool {
        let mut position = self.position;

        while position > 0 {
            position -= 1;

            let Some(kind) = self.kind_at(position) else {
                return false;
            };

            if is_layout(kind) {
                continue;
            }

            return kind == OdinKind::Directive;
        }

        false
    }

    fn tags_a_statement(&self) -> bool {
        matches!(
            self.ahead(1),
            Some(
                OdinKind::ForKeyword
                    | OdinKind::IfKeyword
                    | OdinKind::SwitchKeyword
                    | OdinKind::WhenKeyword
            )
        )
    }

    fn tags_an_assignment(&self) -> bool {
        let start = self.significant(self.position + 1);

        for step in 0..self.steps() {
            let position = start + step;

            let Some(kind) = self.kind_at(position) else {
                return false;
            };

            if matches!(kind, OdinKind::Newline | OdinKind::Semicolon) {
                return false;
            }

            if assignment_of(kind).is_some() {
                return true;
            }

            if matches!(
                kind,
                OdinKind::BraceOpen | OdinKind::BracketOpen | OdinKind::ParenOpen
            ) {
                return false;
            }
        }

        false
    }

    fn labels_a_block(&self) -> bool {
        if self.ahead(1) != Some(OdinKind::Colon) {
            return false;
        }

        matches!(
            self.ahead(2),
            Some(
                OdinKind::BraceOpen
                    | OdinKind::ForKeyword
                    | OdinKind::IfKeyword
                    | OdinKind::SwitchKeyword
            )
        )
    }

    fn statement_body(&mut self, checkpoint: Checkpoint, kind: OdinKind) {
        let held = self.anchor();

        if self.at(OdinKind::BraceOpen) {
            self.block_at(held);
        } else if self.opens_a_compound() {
            self.statement_at(held);
        } else {
            self.expression_statement(held);
        }

        self.events.start_at(checkpoint, kind);
        self.events.finish();
        self.terminator();
    }

    fn opens_a_compound(&self) -> bool {
        matches!(
            self.current(),
            Some(
                OdinKind::ForKeyword
                    | OdinKind::IfKeyword
                    | OdinKind::SwitchKeyword
                    | OdinKind::WhenKeyword
            )
        )
    }

    fn branch(&mut self, checkpoint: Checkpoint, kind: OdinKind) {
        self.bump();
        self.name();
        self.events.start_at(checkpoint, kind);
        self.events.finish();
        self.terminator();
    }

    fn body(&mut self) {
        if self.eat(OdinKind::DoKeyword) {
            self.statement();

            return;
        }

        self.reach_a_brace();
        self.block();
    }

    fn reach_a_brace(&mut self) {
        if !self.brace_follows() {
            return;
        }

        self.skip_breaks();
    }

    fn brace_follows(&self) -> bool {
        let mut position = self.position;

        for _ in 0..self.steps() {
            match self.kind_at(position) {
                Some(OdinKind::BraceOpen) => return true,
                Some(kind) if is_layout(kind) => position += 1,
                Some(_) | None => return false,
            }
        }

        false
    }

    fn when_statement(&mut self, checkpoint: Checkpoint) {
        self.bump();
        self.header();
        self.body();
        self.else_tail(true);
        self.events.start_at(checkpoint, OdinKind::WhenStatement);
        self.events.finish();
        self.terminator();
    }

    fn if_statement(&mut self, checkpoint: Checkpoint) {
        self.bump();
        self.header();
        self.body();
        self.else_tail(false);
        self.events.start_at(checkpoint, OdinKind::IfStatement);
        self.events.finish();
        self.terminator();
    }

    fn else_tail(&mut self, whenever: bool) {
        for _ in 0..self.steps() {
            self.reach_an_else();

            if !self.at(OdinKind::ElseKeyword) {
                return;
            }

            let checkpoint = self.anchor();

            self.bump();

            let branched = self.at(OdinKind::IfKeyword) || self.at(OdinKind::WhenKeyword);

            if branched {
                self.bump();
                self.header();
                self.body();

                self.events.start_at(
                    checkpoint,
                    if whenever {
                        OdinKind::ElseWhenClause
                    } else {
                        OdinKind::ElseIfClause
                    },
                );
                self.events.finish();

                continue;
            }

            self.body();
            self.events.start_at(checkpoint, OdinKind::ElseClause);
            self.events.finish();

            return;
        }
    }

    fn reach_an_else(&mut self) {
        self.skip_trivia();

        let mut position = self.position;

        for _ in 0..self.steps() {
            match self.kind_at(position) {
                Some(OdinKind::ElseKeyword) => break,
                Some(kind) if is_layout(kind) => position += 1,
                Some(_) | None => return,
            }
        }

        self.skip_breaks();
    }

    fn header(&mut self) {
        for _ in 0..self.steps() {
            let before = self.position;
            let checkpoint = self.anchor();

            if self.at_name() && self.binder().is_some() {
                self.bound_declaration(checkpoint);
            } else {
                self.expression_statement_with(checkpoint, false);
            }

            if !self.eat(OdinKind::Semicolon) {
                break;
            }

            if self.position == before {
                break;
            }
        }
    }

    fn for_statement(&mut self, checkpoint: Checkpoint) {
        self.bump();

        if !self.at(OdinKind::BraceOpen) && !self.at(OdinKind::DoKeyword) && !self.brace_follows() {
            self.for_header();
        }

        self.body();
        self.events.start_at(checkpoint, OdinKind::ForStatement);
        self.events.finish();
        self.terminator();
    }

    fn for_header(&mut self) {
        let held = self.anchor();

        self.expression_list_iteration();

        if self.eat(OdinKind::InKeyword) {
            self.expression_with(false);

            return;
        }

        let _ = held;

        if let Some(node) = self.current().and_then(assignment_of) {
            self.bump();
            self.expression_list_with(false);
            self.events.start_at(held, node);
            self.events.finish();
        }

        if !self.eat(OdinKind::Semicolon) {
            return;
        }

        if !self.at(OdinKind::Semicolon) {
            self.expression_with(false);
        }

        let _ = self.eat(OdinKind::Semicolon);

        if !self.at(OdinKind::BraceOpen) && !self.at(OdinKind::DoKeyword) {
            let tail = self.anchor();

            self.expression_statement_with(tail, false);
        }
    }

    fn switch_statement(&mut self, checkpoint: Checkpoint, _typed: bool) {
        self.bump();

        if !self.at(OdinKind::BraceOpen) && !self.brace_follows() {
            self.switch_header();
        }

        self.reach_a_brace();
        let _ = self.eat(OdinKind::BraceOpen);

        for _ in 0..self.steps() {
            self.skip_breaks();

            if self.at(OdinKind::BraceClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.switch_case();

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(OdinKind::BraceClose);
        self.events.start_at(checkpoint, OdinKind::SwitchStatement);
        self.events.finish();
        self.terminator();
    }

    fn switch_header(&mut self) {
        self.switch_clause();

        if !self.eat(OdinKind::Semicolon) {
            return;
        }

        if self.at(OdinKind::BraceOpen) || self.brace_follows() {
            return;
        }

        self.switch_clause();
    }

    fn switch_clause(&mut self) {
        let checkpoint = self.anchor();
        let before = self.position;

        if self.at_name() && self.binder().is_some() {
            self.bound_declaration(checkpoint);
        } else {
            self.iteration_statement(checkpoint);
        }

        let carried = self.position > before;

        if !self.eat(OdinKind::InKeyword) {
            return;
        }

        if !carried {
            self.expression_with(false);

            return;
        }

        {
            self.expression_with(false);
            self.events.start_at(checkpoint, OdinKind::InExpression);
            self.events.finish();
        }
    }

    fn iteration_statement(&mut self, checkpoint: Checkpoint) {
        self.expression_list_iteration();

        let Some(node) = self.current().and_then(assignment_of) else {
            return;
        };

        self.bump();
        self.skip_trivia();
        self.expression_list_iteration();
        self.events.start_at(checkpoint, node);
        self.events.finish();
    }

    fn switch_case(&mut self) {
        let checkpoint = self.anchor();

        if !self.eat(OdinKind::CaseKeyword) {
            self.statement();

            return;
        }

        if !self.at(OdinKind::Colon) {
            self.expression_list();

            if self.eat(OdinKind::InKeyword) {
                self.expression();
            }
        }

        let _ = self.eat(OdinKind::Colon);

        for _ in 0..self.steps() {
            self.skip_breaks();

            let Some(held) = self.current() else {
                break;
            };

            if matches!(held, OdinKind::BraceClose | OdinKind::CaseKeyword) {
                break;
            }

            let before = self.position;

            self.statement();

            if self.position == before {
                self.emit();
            }
        }

        self.events.start_at(checkpoint, OdinKind::SwitchCase);
        self.events.finish();
    }

    fn expression_statement(&mut self, checkpoint: Checkpoint) {
        self.expression_statement_with(checkpoint, true);
    }

    fn expression_statement_with(&mut self, checkpoint: Checkpoint, structures: bool) {
        self.expression_list_with(structures);

        let Some(held) = self.current().and_then(assignment_of) else {
            return;
        };

        let declared = self.file_scope
            && held == OdinKind::AssignmentStatement
            && self.at(OdinKind::ColonEqual);

        let node = if declared {
            OdinKind::VariableDeclaration
        } else {
            held
        };

        self.bump();
        self.skip_trivia();
        self.expression_list_with(structures);
        self.events.start_at(checkpoint, node);
        self.events.finish();
    }

    fn expression(&mut self) {
        self.expression_with(true);
    }

    fn expression_with(&mut self, structures: bool) {
        self.expression_staged(if structures {
            CONTEXT_VALUE
        } else {
            CONTEXT_HEADER
        });
    }

    fn type_of(&mut self) {
        let checkpoint = self.anchor();

        self.expression_staged(CONTEXT_TYPE);
        self.events.start_at(checkpoint, OdinKind::Type);
        self.events.finish();
    }

    fn expression_iteration(&mut self) {
        self.expression_staged(CONTEXT_ITERATION);
    }

    fn expression_list_iteration(&mut self) {
        for _ in 0..self.steps() {
            let before = self.position;

            self.expression_iteration();

            if !self.eat(OdinKind::Comma) {
                break;
            }

            if self.position == before {
                break;
            }
        }
    }

    fn element_type(&mut self) {
        let checkpoint = self.anchor();

        self.expression_staged(CONTEXT_ELEMENT);
        self.events.start_at(checkpoint, OdinKind::Type);
        self.events.finish();
    }

    fn bare_type(&mut self) {
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

    fn expression_list(&mut self) {
        self.expression_list_with(true);
    }

    fn expression_list_with(&mut self, structures: bool) {
        for _ in 0..self.steps() {
            let before = self.position;

            self.expression_with(structures);

            if !self.eat(OdinKind::Comma) {
                break;
            }

            self.skip_breaks();

            if self.position == before {
                break;
            }
        }
    }

    fn context(&self, base: u32) -> u8 {
        let group = self.innermost_group(base);

        if self.frames[group as usize].variant != Variant::Top {
            return CONTEXT_VALUE;
        }

        self.frames[group as usize].stage
    }

    fn curly_allowed(&self, base: u32) -> bool {
        self.context(base) == CONTEXT_VALUE
    }

    fn in_a_type(&self, base: u32) -> bool {
        matches!(self.context(base), CONTEXT_ELEMENT | CONTEXT_TYPE)
    }

    fn takes_arguments(&self, base: u32) -> bool {
        self.context(base) == CONTEXT_TYPE
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

    fn prefix(&mut self, kind: OdinKind, power: u8, stage: u8) -> Step {
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

    fn binary(&mut self, kind: OdinKind, left: u8, right: u8) -> Step {
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
            stage: u8::from(kind == OdinKind::TernaryExpression),
            values,
            variant: Variant::Binary,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        self.bump();
        self.skip_trivia();

        Step::Operand
    }

    fn open_group(&mut self, variant: Variant, checkpoint: Checkpoint, kind: OdinKind) -> Step {
        let opener = self.current().unwrap_or(OdinKind::ParenOpen);
        let bracket = self.anchor();

        self.bump();
        self.skip_breaks();

        let content = self.anchor();

        let closer = if opener == OdinKind::BracketOpen {
            OdinKind::BracketClose
        } else if opener == OdinKind::BraceOpen {
            OdinKind::BraceClose
        } else {
            OdinKind::ParenClose
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
        self.close_element(group);

        let frame = self.frames[group as usize];

        self.frame_count = group;

        let kind = if frame.variant == Variant::Index && frame.stage == 1 {
            OdinKind::SliceExpression
        } else {
            frame.kind
        };

        self.events.start_at(frame.checkpoint, kind);
        self.bump();
        self.events.finish();

        let member = trailer_node(frame.stage)
            .filter(|_| matches!(frame.variant, Variant::Call | Variant::Init));

        if let Some(held) = member {
            self.events.start_at(frame.bracket, held);
            self.events.finish();
        }

        self.value_count = frame.values;

        self.push_value(if member.is_some() {
            frame.bracket
        } else {
            frame.checkpoint
        });

        self.suffixable = true;
    }

    fn close_element(&mut self, group: u32) {
        let frame = self.frames[group as usize];

        if frame.variant != Variant::Init || frame.kind != OdinKind::Struct {
            return;
        }

        if self.value_count <= frame.element_values {
            return;
        }

        self.events.start_at(frame.content, OdinKind::StructField);
        self.events.finish();
    }

    fn operand_step(&mut self, base: u32) -> Step {
        self.skip_trivia();

        let group = self.innermost_group(base);

        if self.frames[group as usize].is_bracketed() {
            self.skip_breaks();
        }

        let Some(kind) = self.current() else {
            return Step::Done;
        };

        if self.frames[group as usize].is_bracketed() && kind == self.frames[group as usize].closer
        {
            return Step::Done;
        }

        if self.frames[group as usize].variant == Variant::Init {
            return self.init_element(group, kind, base);
        }

        self.operand_of(kind, base)
    }

    fn init_element(&mut self, group: u32, kind: OdinKind, base: u32) -> Step {
        let checkpoint = self.anchor();
        let step = self.operand_of(kind, base);

        if step == Step::Done {
            return step;
        }

        let _ = group;
        let _ = checkpoint;

        step
    }

    fn operand_of(&mut self, kind: OdinKind, base: u32) -> Step {
        if let Some(node) = literal_node(kind) {
            return self.leaf(node);
        }

        match Some(kind) {
            None => Step::Done,
            Some(OdinKind::Minus) if self.signs_a_number() => {
                let checkpoint = self.anchor();

                self.open(OdinKind::NumberNode);
                self.emit();
                self.emit();
                self.events.finish();

                self.settle(checkpoint, true)
            }
            Some(held) if is_name(held) => self.leaf(OdinKind::IdentifierNode),
            Some(OdinKind::MinusMinusMinus) => self.leaf(OdinKind::Uninitialized),
            Some(OdinKind::Directive) => self.directive_operand(base),
            Some(OdinKind::Dollar) => {
                let checkpoint = self.anchor();

                self.bump();
                self.type_of();
                self.events.start_at(checkpoint, OdinKind::ConstantType);
                self.events.finish();

                self.settle(checkpoint, true)
            }
            Some(OdinKind::DistinctKeyword) => self.distinct_type(base),
            Some(OdinKind::Caret) => self.pointer_type(base),
            Some(OdinKind::DotDotDot) => {
                let checkpoint = self.anchor();

                self.bump();

                self.settle(checkpoint, true)
            }
            Some(OdinKind::DotDot) if self.in_a_type(base) => self.variadic_type(base),
            Some(OdinKind::DotDot) => self.variadic_expression(base),
            Some(OdinKind::BracketOpen) => self.bracket_type(base),
            Some(OdinKind::MapKeyword) => self.map_type(base),
            Some(OdinKind::MatrixKeyword) => self.matrix_type(base),
            Some(_) => self.operand_tail(kind, base),
        }
    }

    fn operand_tail(&mut self, kind: OdinKind, base: u32) -> Step {
        match Some(kind) {
            None => Step::Done,
            Some(OdinKind::BitSetKeyword) => self.bit_set_type(base),
            Some(OdinKind::ProcKeyword) => self.procedure_operand(),
            Some(OdinKind::BitFieldKeyword) => self.record_operand(OdinKind::BitFieldType),
            Some(OdinKind::StructKeyword) => self.record_operand(OdinKind::StructType),
            Some(OdinKind::EnumKeyword) => self.enumeration_operand(),
            Some(OdinKind::UnionKeyword) => self.union_operand(),
            Some(OdinKind::CastKeyword | OdinKind::TransmuteKeyword) => self.cast_operand(),
            Some(OdinKind::AutoCastKeyword) => {
                self.prefix(OdinKind::CastExpression, POWER_PREFIX, STAGE_VALUE)
            }
            Some(OdinKind::BraceOpen) if !self.in_a_type(base) => {
                let checkpoint = self.anchor();

                self.open_group(Variant::Init, checkpoint, OdinKind::Struct)
            }
            Some(OdinKind::ParenOpen) if self.in_a_type(base) => self.tuple_type(),
            Some(OdinKind::ParenOpen) if self.opens_a_cast() => self.parenthesized_cast(),
            Some(OdinKind::ParenOpen) => {
                let checkpoint = self.anchor();

                self.open_group(
                    Variant::Paren,
                    checkpoint,
                    OdinKind::ParenthesizedExpression,
                )
            }
            Some(OdinKind::Dot) => {
                let checkpoint = self.anchor();

                self.bump();
                self.name();
                self.events.start_at(checkpoint, OdinKind::MemberExpression);
                self.events.finish();

                self.settle(checkpoint, true)
            }
            Some(_) if is_prefix(kind) => {
                self.prefix(OdinKind::UnaryExpression, POWER_PREFIX, STAGE_VALUE)
            }
            Some(_) => Step::Done,
        }
    }

    fn signs_a_number(&self) -> bool {
        let held = self.significant(self.position);
        let next = self.significant(held + 1);

        if self.kind_at(next) != Some(OdinKind::Number) {
            return false;
        }

        let Some(left) = self.tokens.get(held as usize) else {
            return false;
        };

        let Some(right) = self.tokens.get(next as usize) else {
            return false;
        };

        left.end() == right.offset
    }

    fn leaf(&mut self, kind: OdinKind) -> Step {
        let checkpoint = self.anchor();

        self.wrap(kind);

        self.settle(checkpoint, true)
    }

    fn settle(&mut self, checkpoint: Checkpoint, suffixable: bool) -> Step {
        self.push_value(checkpoint);
        self.suffixable = suffixable;

        Step::Operator
    }

    fn directive_operand(&mut self, base: u32) -> Step {
        let checkpoint = self.anchor();

        self.wrap(OdinKind::Tag);

        let Some(kind) = self.current() else {
            return self.settle(checkpoint, true);
        };

        if kind == OdinKind::ParenOpen && self.in_a_type(base) {
            self.bump();

            for _ in 0..self.steps() {
                if self.at(OdinKind::ParenClose) || self.current().is_none() {
                    break;
                }

                self.bump();
            }

            let _ = self.eat(OdinKind::ParenClose);

            let Some(held) = self.current() else {
                return self.settle(checkpoint, true);
            };

            return self.operand_of(held, base);
        }

        if kind == OdinKind::ParenOpen {
            return self.open_group(Variant::Call, checkpoint, OdinKind::CallExpression);
        }

        if kind == OdinKind::ProcKeyword {
            let _ = self.procedure_operand();
            self.reduce_tag(checkpoint);

            return Step::Operator;
        }

        if !opens_a_type(kind) && literal_node(kind).is_none() && kind != OdinKind::BraceOpen {
            return self.settle(checkpoint, true);
        }

        let step = self.operand_of(kind, base);

        if step == Step::Done {
            return self.settle(checkpoint, true);
        }

        self.reduce_tag(checkpoint);

        step
    }

    fn reduce_tag(&mut self, checkpoint: Checkpoint) {
        if self.value_count > 0 {
            self.value_count -= 1;
        }

        self.push_value(checkpoint);
    }

    fn conditions_a_type(&self) -> bool {
        let mut position = self.significant(self.position);
        let mut depth = 0_u32;

        for _ in 0..self.steps() {
            match self.kind_at(position) {
                None => return false,
                Some(OdinKind::ParenOpen) => depth += 1,
                Some(OdinKind::ParenClose) => {
                    depth -= 1;

                    if depth == 0 {
                        return false;
                    }
                }
                Some(OdinKind::WhenKeyword) if depth == 1 => return true,
                Some(_) => {}
            }

            position = self.significant(position + 1);
        }

        false
    }

    fn branch_type(&mut self) {
        let checkpoint = self.anchor();

        self.expression_staged(CONTEXT_CONDITIONAL);
        self.events.start_at(checkpoint, OdinKind::Type);
        self.events.finish();
    }

    fn conditional_type(&mut self) -> Step {
        let checkpoint = self.anchor();

        self.bump();
        self.branch_type();
        let _ = self.eat(OdinKind::WhenKeyword);
        self.expression();
        let _ = self.eat(OdinKind::ElseKeyword);
        self.branch_type();
        let _ = self.eat(OdinKind::ParenClose);
        self.events.start_at(checkpoint, OdinKind::ConditionalType);
        self.events.finish();

        self.settle(checkpoint, true)
    }

    fn tuple_type(&mut self) -> Step {
        if self.conditions_a_type() {
            return self.conditional_type();
        }

        let checkpoint = self.anchor();

        self.bump();

        for _ in 0..self.steps() {
            self.skip_breaks();

            if self.at(OdinKind::ParenClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.result();

            if !self.eat(OdinKind::Comma) {
                break;
            }

            if self.position == before {
                self.emit();
            }
        }

        self.skip_breaks();
        let _ = self.eat(OdinKind::ParenClose);
        self.events.start_at(checkpoint, OdinKind::TupleType);
        self.events.finish();

        self.settle(checkpoint, true)
    }

    fn opens_a_cast(&self) -> bool {
        matches!(
            self.ahead(1),
            Some(OdinKind::BracketOpen | OdinKind::Caret | OdinKind::ProcKeyword)
        )
    }

    fn parenthesized_cast(&mut self) -> Step {
        let checkpoint = self.anchor();

        self.bump();
        self.bare_type();
        let _ = self.eat(OdinKind::ParenClose);
        self.events.start_at(checkpoint, OdinKind::CastExpression);
        self.events.finish();

        self.settle(checkpoint, true)
    }

    fn cast_operand(&mut self) -> Step {
        let checkpoint = self.anchor();

        let frame = Frame {
            checkpoint,
            kind: OdinKind::CastExpression,
            power: POWER_PREFIX,
            stage: STAGE_VALUE,
            values: self.value_count,
            variant: Variant::Unary,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        self.bump();

        if self.eat(OdinKind::ParenOpen) {
            self.type_of();
            let _ = self.eat(OdinKind::ParenClose);
        }

        Step::Operand
    }

    fn bracket_type(&mut self, base: u32) -> Step {
        let checkpoint = self.anchor();

        self.bracket_type_at(checkpoint, base)
    }

    fn bracket_type_at(&mut self, checkpoint: Checkpoint, base: u32) -> Step {
        self.bump();
        let _ = self.eat(OdinKind::Dollar);

        match self.current().unwrap_or(OdinKind::ErrorToken) {
            OdinKind::DynamicKeyword | OdinKind::Caret | OdinKind::Question => {
                self.bump();

                if self.eat(OdinKind::Semicolon) {
                    self.type_of();
                }
            }
            OdinKind::BracketClose => {}
            _ => self.expression(),
        }

        let _ = self.eat(OdinKind::BracketClose);

        self.element(checkpoint, OdinKind::ArrayType, OdinKind::Struct, base)
    }

    fn element(
        &mut self,
        checkpoint: Checkpoint,
        wrapper: OdinKind,
        literal: OdinKind,
        base: u32,
    ) -> Step {
        if self.current().is_some_and(opens_a_type) {
            self.element_type();
        }

        if self.at(OdinKind::BraceOpen) && self.curly_allowed(base) {
            return self.open_group(Variant::Init, checkpoint, literal);
        }

        self.events.start_at(checkpoint, wrapper);
        self.events.finish();

        self.settle(checkpoint, true)
    }

    fn pointer_type(&mut self, base: u32) -> Step {
        let checkpoint = self.anchor();

        self.bump();

        self.element(checkpoint, OdinKind::PointerType, OdinKind::Struct, base)
    }

    fn distinct_type(&mut self, base: u32) -> Step {
        let checkpoint = self.anchor();

        self.bump();

        self.element(checkpoint, OdinKind::DistinctType, OdinKind::Struct, base)
    }

    fn variadic_type(&mut self, base: u32) -> Step {
        let checkpoint = self.anchor();

        self.bump();

        self.element(checkpoint, OdinKind::VariadicType, OdinKind::Struct, base)
    }

    fn variadic_expression(&mut self, base: u32) -> Step {
        let checkpoint = self.anchor();

        self.bump();

        let Some(kind) = self.current() else {
            return self.settle(checkpoint, true);
        };

        if self.operand_of(kind, base) != Step::Operator {
            return Step::Operand;
        }

        if self.value_count > 0 {
            self.value_count -= 1;
        }

        self.events
            .start_at(checkpoint, OdinKind::VariadicExpression);
        self.events.finish();

        self.settle(checkpoint, true)
    }

    fn map_type(&mut self, base: u32) -> Step {
        let checkpoint = self.anchor();

        self.bump();
        let _ = self.eat(OdinKind::BracketOpen);
        self.type_of();
        let _ = self.eat(OdinKind::BracketClose);

        self.element(checkpoint, OdinKind::MapType, OdinKind::Map, base)
    }

    fn matrix_type(&mut self, base: u32) -> Step {
        let checkpoint = self.anchor();

        self.bump();
        let _ = self.eat(OdinKind::BracketOpen);
        self.expression();
        let _ = self.eat(OdinKind::Comma);
        self.expression();
        let _ = self.eat(OdinKind::BracketClose);

        self.element(checkpoint, OdinKind::MatrixType, OdinKind::Matrix, base)
    }

    fn bit_set_type(&mut self, base: u32) -> Step {
        let checkpoint = self.anchor();

        self.bump();
        let _ = self.eat(OdinKind::BracketOpen);
        self.bare_type();

        if self.eat(OdinKind::Semicolon) {
            self.type_of();
        }

        let _ = self.eat(OdinKind::BracketClose);

        if self.at(OdinKind::BraceOpen) && self.curly_allowed(base) {
            return self.open_group(Variant::Init, checkpoint, OdinKind::BitSet);
        }

        self.events.start_at(checkpoint, OdinKind::BitSetType);
        self.events.finish();

        self.settle(checkpoint, true)
    }

    fn procedure_operand(&mut self) -> Step {
        let checkpoint = self.anchor();

        self.bump();

        if self.at(OdinKind::Text) {
            self.wrap(OdinKind::CallingConvention);
        }

        self.parameters();

        if self.eat(OdinKind::Arrow) {
            self.results();
        }

        self.qualifiers();

        if self.at(OdinKind::MinusMinusMinus) {
            self.wrap(OdinKind::Uninitialized);
            self.events.start_at(checkpoint, OdinKind::Procedure);
            self.events.finish();

            return self.settle(checkpoint, true);
        }

        if !self.at(OdinKind::BraceOpen) && !self.brace_follows() {
            self.events.start_at(checkpoint, OdinKind::ProcedureType);
            self.events.finish();

            return self.settle(checkpoint, true);
        }

        self.reach_a_brace();
        self.block();
        self.events.start_at(checkpoint, OdinKind::Procedure);
        self.events.finish();

        self.settle(checkpoint, false)
    }

    fn record_operand(&mut self, kind: OdinKind) -> Step {
        let checkpoint = self.anchor();

        self.record_body_of(OdinKind::StructMember);
        self.events.start_at(checkpoint, kind);
        self.events.finish();

        self.settle(checkpoint, true)
    }

    fn enumeration_operand(&mut self) -> Step {
        let checkpoint = self.anchor();

        self.enumeration_body();
        self.events.start_at(checkpoint, OdinKind::EnumType);
        self.events.finish();

        self.settle(checkpoint, true)
    }

    fn union_operand(&mut self) -> Step {
        let checkpoint = self.anchor();

        self.union_body();
        self.events.start_at(checkpoint, OdinKind::UnionType);
        self.events.finish();

        self.settle(checkpoint, true)
    }

    fn operator_step(&mut self, base: u32) -> Step {
        self.skip_trivia();

        let group = self.innermost_group(base);

        if self.frames[group as usize].is_bracketed() {
            self.skip_breaks();
        }

        let Some(kind) = self.current() else {
            return Step::Done;
        };

        let frame = self.frames[group as usize];

        if frame.is_bracketed() && kind == frame.closer {
            self.close_group(group);

            return Step::Operator;
        }

        if kind == OdinKind::Comma {
            return self.comma(group);
        }

        if kind == OdinKind::Colon && frame.variant == Variant::Index {
            self.reduce_above(group + 1);
            self.bump();
            self.frames[group as usize].stage = 1;

            return Step::Operand;
        }

        if kind == OdinKind::Equal && matches!(frame.variant, Variant::Call | Variant::Init) {
            self.reduce_above(group + 1);
            self.bump();
            self.value_count = frame.element_values;

            return Step::Operand;
        }

        if matches!(kind, OdinKind::Colon | OdinKind::ElseKeyword) {
            if let Some(held) = self.ternary_frame(group) {
                self.reduce_above(held + 1);
                self.bump();

                return Step::Operand;
            }
        }

        if self.in_a_type(base) {
            match Some(kind) {
                Some(OdinKind::Dot) => return self.field_type(),
                Some(OdinKind::ParenOpen) => {
                    if !self.takes_arguments(base) {
                        return Step::Done;
                    }

                    return self.polymorphic_type();
                }
                Some(OdinKind::Slash) => return self.specialized_type(),
                Some(_) | None => {}
            }
        }

        self.postfix_step(kind, base)
    }

    fn postfix_step(&mut self, kind: OdinKind, base: u32) -> Step {
        match Some(kind) {
            Some(OdinKind::Dot) => self.member(base),
            Some(OdinKind::Caret) => {
                self.reduce_for(POWER_CAST);

                self.postfix(OdinKind::Address, false)
            }
            Some(OdinKind::OrReturnKeyword) => self.postfix(OdinKind::OrReturnExpression, false),
            Some(OdinKind::OrBreakKeyword) => self.postfix(OdinKind::OrBreakExpression, true),
            Some(OdinKind::OrContinueKeyword) => self.postfix(OdinKind::OrContinueExpression, true),
            Some(OdinKind::Arrow) => self.selector_call(),
            Some(OdinKind::ParenOpen) => self.trailer(Variant::Call, OdinKind::CallExpression),
            Some(OdinKind::BracketOpen) => self.trailer(Variant::Index, OdinKind::IndexExpression),
            Some(OdinKind::BraceOpen) if self.suffixable && self.curly_allowed(base) => {
                self.trailer(Variant::Init, OdinKind::Struct)
            }
            Some(_) | None => match self.infix_here(kind, base) {
                Some((node, left, right)) => self.binary(node, left, right),
                None => Step::Done,
            },
        }
    }

    fn infix_here(&self, kind: OdinKind, base: u32) -> Option<(OdinKind, u8, u8)> {
        if matches!(kind, OdinKind::InKeyword | OdinKind::NotInKeyword)
            && self.context(base) == CONTEXT_ITERATION
        {
            return None;
        }

        if kind == OdinKind::WhenKeyword && self.context(base) == CONTEXT_CONDITIONAL {
            return None;
        }

        infix_of(kind)
    }

    fn ternary_frame(&self, base: u32) -> Option<u32> {
        let mut index = self.frame_count;

        while index > base {
            index -= 1;

            let held = self.frames[index as usize];

            if held.variant == Variant::Binary && held.kind == OdinKind::TernaryExpression {
                return Some(index);
            }

            if held.is_group() {
                return None;
            }
        }

        None
    }

    fn polymorphic_type(&mut self) -> Step {
        if self.value_count == 0 {
            return Step::Done;
        }

        let checkpoint = self.values[self.value_count as usize - 1];

        self.value_count -= 1;
        self.events.start_at(checkpoint, OdinKind::Type);
        self.events.finish();
        self.bump();

        for _ in 0..self.steps() {
            self.skip_breaks();

            if self.at(OdinKind::ParenClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.type_argument();

            if !self.eat(OdinKind::Comma) {
                break;
            }

            if self.position == before {
                self.emit();
            }
        }

        self.skip_breaks();
        let _ = self.eat(OdinKind::ParenClose);
        self.events.start_at(checkpoint, OdinKind::PolymorphicType);
        self.events.finish();

        self.settle(checkpoint, true)
    }

    fn type_argument(&mut self) {
        if self.current().and_then(literal_node).is_some() {
            self.expression();

            return;
        }

        self.type_of();
    }

    fn specialized_type(&mut self) -> Step {
        if self.value_count == 0 {
            return Step::Done;
        }

        let checkpoint = self.values[self.value_count as usize - 1];

        self.value_count -= 1;
        self.events.start_at(checkpoint, OdinKind::Type);
        self.events.finish();
        self.bump();
        self.type_of();
        self.events.start_at(checkpoint, OdinKind::SpecializedType);
        self.events.finish();

        self.settle(checkpoint, true)
    }

    fn field_type(&mut self) -> Step {
        if self.value_count == 0 {
            return Step::Done;
        }

        let checkpoint = self.values[self.value_count as usize - 1];

        for _ in 0..self.steps() {
            if !self.eat(OdinKind::Dot) {
                break;
            }

            self.name();
        }

        self.events.start_at(checkpoint, OdinKind::FieldType);
        self.events.finish();
        self.suffixable = true;

        Step::Operator
    }

    fn trails_a_group(&self, base: u32) -> bool {
        match self.ahead(1) {
            Some(OdinKind::ParenOpen) => true,
            Some(OdinKind::BraceOpen) => self.curly_allowed(base),
            Some(_) | None => false,
        }
    }

    fn member(&mut self, base: u32) -> Step {
        self.reduce_for(POWER_RANGE_LEFT);

        if self.value_count == 0 {
            return Step::Done;
        }

        let checkpoint = self.values[self.value_count as usize - 1];

        self.bump();

        if self.at(OdinKind::ParenOpen) {
            let held = self.anchor();
            let casts = self.opens_a_cast();

            self.bump();

            if casts {
                self.bare_type();
            } else {
                self.expression();
            }

            let _ = self.eat(OdinKind::ParenClose);

            self.events.start_at(
                held,
                if casts {
                    OdinKind::CastExpression
                } else {
                    OdinKind::ParenthesizedExpression
                },
            );
            self.events.finish();
        } else if self.at(OdinKind::Question) {
            self.bump();
        } else if self.at_name() && self.trails_a_group(base) {
            let held = self.anchor();
            let calls = self.ahead(1) == Some(OdinKind::ParenOpen);

            self.value_count -= 1;
            self.wrap(OdinKind::IdentifierNode);

            let step = if calls {
                self.open_group(Variant::Call, held, OdinKind::CallExpression)
            } else {
                self.open_group(Variant::Init, held, OdinKind::Struct)
            };

            let group = self.frame_count - 1;

            self.frames[group as usize].bracket = checkpoint;
            self.frames[group as usize].stage = STAGE_MEMBER;

            return step;
        } else {
            self.name();
        }

        self.events.start_at(checkpoint, OdinKind::MemberExpression);
        self.events.finish();
        self.suffixable = true;

        Step::Operator
    }

    fn selector_call(&mut self) -> Step {
        if self.value_count == 0 || self.ahead(2) != Some(OdinKind::ParenOpen) {
            return Step::Done;
        }

        let checkpoint = self.values[self.value_count as usize - 1];

        self.bump();

        if !self.at_name() {
            return Step::Done;
        }

        let held = self.anchor();

        self.value_count -= 1;
        self.wrap(OdinKind::IdentifierNode);

        let step = self.open_group(Variant::Call, held, OdinKind::CallExpression);
        let group = self.frame_count - 1;

        self.frames[group as usize].bracket = checkpoint;
        self.frames[group as usize].stage = STAGE_SELECTOR;

        step
    }

    fn postfix(&mut self, kind: OdinKind, labelled: bool) -> Step {
        if self.value_count == 0 {
            return Step::Done;
        }

        let checkpoint = self.values[self.value_count as usize - 1];

        self.events.start_at(checkpoint, kind);
        self.bump();

        if labelled && self.at_name() {
            self.name();
        }

        self.events.finish();
        self.suffixable = true;

        Step::Operator
    }

    fn trailer(&mut self, variant: Variant, kind: OdinKind) -> Step {
        if self.value_count == 0 {
            return Step::Done;
        }

        let checkpoint = self.values[self.value_count as usize - 1];

        self.value_count -= 1;

        self.open_group(variant, checkpoint, kind)
    }

    fn comma(&mut self, group: u32) -> Step {
        let frame = self.frames[group as usize];

        if frame.variant == Variant::Top || frame.variant == Variant::Paren {
            return Step::Done;
        }

        self.reduce_above(group + 1);
        self.close_element(group);
        self.bump();
        self.skip_breaks();
        self.value_count = frame.values;
        self.frames[group as usize].elements += 1;
        self.frames[group as usize].element_values = self.value_count;

        let content = self.anchor();

        self.frames[group as usize].content = content;

        Step::Operand
    }
}

pub fn build(
    source: &[u8],
    tokens: &[Token],
    raw: &[OdinKind],
    events: &mut Events<OdinKind>,
    tree: &mut Tree<OdinKind>,
) -> Structure {
    assert!(u32::try_from(source.len()).is_ok());
    assert_eq!(tokens.len(), raw.len());

    events.clear();
    tree.clear();

    let mut parser = Parser {
        events,
        file_scope: true,
        frame_count: 0,
        frames: [Frame::EMPTY; EXPRESSION_DEPTH_MAX as usize],
        nesting: 0,
        outcome: Structure::Complete,
        position: 0,
        raw,
        significant_next: 0,
        source,
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
