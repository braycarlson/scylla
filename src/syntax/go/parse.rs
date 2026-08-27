use crate::bounded::{Span, count_of};
use crate::syntax::go::expression::{
    EXPRESSION_DEPTH_MAX,
    Frame,
    POWER_BARRIER,
    POWER_UNARY,
    VALUE_COUNT_MAX,
    Variant,
    assigns,
    infix_of,
    is_literal,
    is_prefix,
    opens_a_type,
};
use crate::syntax::go::kind::GoKind;
use crate::syntax::{SyntaxError, SyntaxErrorKind};
use crate::token::Token;
use crate::tree::{Checkpoint, Events, Structure, Tree, replay};

const NEST_DEPTH_MAX: u32 = 96;
const SCAN_STEP_MAX: u32 = 1 << 16;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Step {
    Done,
    Operand,
    Operator,
}

struct Parser<'run> {
    events: &'run mut Events<GoKind>,
    frame_count: u32,
    frames: [Frame; EXPRESSION_DEPTH_MAX as usize],
    nesting: u32,
    outcome: Structure,
    position: u32,
    raw: &'run [GoKind],
    significant_next: u32,
    tokens: &'run [Token],
    tree: &'run mut Tree<GoKind>,
    value_count: u32,
    values: [Checkpoint; VALUE_COUNT_MAX as usize],
}

const fn is_layout(kind: GoKind) -> bool {
    matches!(kind, GoKind::Comment | GoKind::Newline)
}

const fn is_opener(kind: GoKind) -> bool {
    matches!(
        kind,
        GoKind::BraceOpen | GoKind::BracketOpen | GoKind::ParenOpen
    )
}

const fn ends_operand(kind: GoKind) -> bool {
    matches!(
        kind,
        GoKind::BraceClose
            | GoKind::BracketClose
            | GoKind::Identifier
            | GoKind::Number
            | GoKind::ParenClose
            | GoKind::RuneLiteral
            | GoKind::StringLiteral
    )
}

const fn is_closer(kind: GoKind) -> bool {
    matches!(
        kind,
        GoKind::BraceClose | GoKind::BracketClose | GoKind::ParenClose
    )
}

impl Parser<'_> {
    fn count(&self) -> u32 {
        count_of(self.raw.len())
    }

    fn steps(&self) -> u32 {
        self.count() + 1
    }

    fn kind_at(&self, position: u32) -> Option<GoKind> {
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
            if kind != GoKind::Comment {
                break;
            }

            position += 1;
        }

        position
    }

    fn current(&self) -> Option<GoKind> {
        self.kind_at(self.significant(self.position))
    }

    fn ahead(&self, steps: u32) -> Option<GoKind> {
        self.kind_at(self.ahead_position(steps))
    }

    fn ahead_position(&self, steps: u32) -> u32 {
        let mut position = self.significant(self.position);

        for _ in 0..steps {
            position = self.significant(position + 1);
        }

        position
    }

    fn at(&self, kind: GoKind) -> bool {
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
        while self.kind_at(self.position) == Some(GoKind::Comment) {
            self.emit();
        }
    }

    fn skip_breaks(&mut self) {
        while self
            .kind_at(self.position)
            .is_some_and(|kind| kind == GoKind::Comment || kind == GoKind::Newline)
        {
            self.emit();
        }
    }

    fn anchor(&mut self) -> Checkpoint {
        self.skip_trivia();

        self.events.checkpoint()
    }

    fn open(&mut self, kind: GoKind) {
        self.skip_trivia();
        self.events.start(kind);
    }

    fn bump(&mut self) {
        self.skip_trivia();
        self.emit();
    }

    fn eat(&mut self, kind: GoKind) -> bool {
        if !self.at(kind) {
            return false;
        }

        self.bump();

        true
    }

    fn expect(&mut self, kind: GoKind, failure: SyntaxErrorKind) -> bool {
        if self.eat(kind) {
            return true;
        }

        self.record(failure);

        false
    }

    fn wrap(&mut self, kind: GoKind) {
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
        self.events.start(GoKind::File);
        self.skip_breaks();

        if self.at(GoKind::PackageKeyword) {
            self.bump();

            if self.at(GoKind::Identifier) {
                self.identifier();
            } else {
                self.record(SyntaxErrorKind::ExpectedIdentifier);
            }

            self.terminator();
        } else {
            self.record(SyntaxErrorKind::UnexpectedToken);
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

    fn terminator(&mut self) {
        if !self.eat(GoKind::Semicolon) {
            let _ = self.eat(GoKind::Newline);
        }
    }

    fn identifier(&mut self) {
        if !self.at(GoKind::Identifier) {
            return;
        }

        self.wrap(GoKind::Ident);
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
        match self.current() {
            None => {}
            Some(GoKind::FuncKeyword) => self.function_declaration(),
            Some(
                GoKind::ConstKeyword
                | GoKind::ImportKeyword
                | GoKind::TypeKeyword
                | GoKind::VarKeyword,
            ) => {
                self.general_declaration();
                self.terminator();
            }
            Some(_) => {
                self.record(SyntaxErrorKind::UnexpectedToken);
                self.emit();
            }
        }
    }

    fn general_declaration(&mut self) {
        let Some(keyword) = self.current() else {
            return;
        };

        self.open(GoKind::GenDecl);
        self.bump();

        if !self.eat(GoKind::ParenOpen) {
            self.specification(keyword);
            self.events.finish();

            return;
        }

        for _ in 0..self.steps() {
            self.skip_breaks();

            if self.at(GoKind::ParenClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.specification(keyword);
            self.terminator();

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(GoKind::ParenClose);
        self.events.finish();
    }

    fn specification(&mut self, keyword: GoKind) {
        if keyword == GoKind::ImportKeyword {
            self.import_specification();

            return;
        }

        if keyword == GoKind::TypeKeyword {
            self.type_specification();

            return;
        }

        self.value_specification();
    }

    fn import_specification(&mut self) {
        self.open(GoKind::ImportSpec);

        if self.at(GoKind::Dot) {
            self.wrap(GoKind::Ident);
        } else {
            self.identifier();
        }

        if self.at(GoKind::StringLiteral) {
            self.wrap(GoKind::BasicLit);
        }

        self.events.finish();
    }

    fn type_specification(&mut self) {
        self.open(GoKind::TypeSpec);
        self.identifier();

        if self.at(GoKind::BracketOpen) && self.opens_type_parameters() {
            self.field_list(GoKind::BracketOpen);
        }

        let _ = self.eat(GoKind::Equal);
        self.type_of();
        self.events.finish();
    }

    fn opens_type_parameters(&self) -> bool {
        let after = self.significant(self.position + 1);
        let held = self.kind_at(after);

        if held != Some(GoKind::Identifier) {
            return false;
        }

        let next = self.kind_at(self.significant(after + 1));

        !matches!(next, Some(GoKind::BracketClose))
    }

    fn value_specification(&mut self) {
        self.open(GoKind::ValueSpec);
        self.name_list();

        if !self.at(GoKind::Equal) && self.current().is_some() && !self.ends_here() {
            self.type_of();
        }

        if self.eat(GoKind::Equal) {
            self.expression_list();
        }

        self.events.finish();
    }

    fn ends_here(&self) -> bool {
        matches!(
            self.current(),
            None | Some(GoKind::Newline | GoKind::ParenClose | GoKind::Semicolon)
        )
    }

    fn name_list(&mut self) {
        for _ in 0..self.steps() {
            if !self.at(GoKind::Identifier) {
                break;
            }

            self.identifier();

            if !self.eat(GoKind::Comma) {
                break;
            }
        }
    }

    fn function_declaration(&mut self) {
        let checkpoint = self.anchor();

        self.open(GoKind::FuncType);
        self.bump();

        if self.at(GoKind::ParenOpen) {
            self.field_list(GoKind::ParenOpen);
        }

        self.identifier();

        if self.at(GoKind::BracketOpen) {
            self.field_list(GoKind::BracketOpen);
        }

        self.signature();
        self.events.finish();

        if self.at(GoKind::BraceOpen) {
            self.block();
        }

        self.events.start_at(checkpoint, GoKind::FuncDecl);
        self.events.finish();
        self.terminator();
    }

    fn signature(&mut self) {
        if self.at(GoKind::ParenOpen) {
            self.field_list(GoKind::ParenOpen);
        }

        if self.at(GoKind::ParenOpen) {
            self.field_list(GoKind::ParenOpen);

            return;
        }

        if self.opens_a_result() {
            let checkpoint = self.anchor();

            self.open(GoKind::Field);
            self.type_of();
            self.events.finish();
            self.events.start_at(checkpoint, GoKind::FieldList);
            self.events.finish();
        }
    }

    fn opens_a_result(&self) -> bool {
        let Some(kind) = self.current() else {
            return false;
        };

        opens_a_type(kind) && kind != GoKind::ParenOpen
    }

    fn field_list(&mut self, opener: GoKind) {
        let closer = if opener == GoKind::BracketOpen {
            GoKind::BracketClose
        } else if opener == GoKind::BraceOpen {
            GoKind::BraceClose
        } else {
            GoKind::ParenClose
        };

        let named = self.fields_are_named(closer);

        self.open(GoKind::FieldList);
        self.bump();

        for _ in 0..self.steps() {
            self.skip_breaks();

            if self.at(closer) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.field(named, closer);

            if !self.eat(GoKind::Comma) {
                self.terminator();
            }

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(closer);
        self.events.finish();
    }

    fn fields_are_named(&self, closer: GoKind) -> bool {
        let mut position = self.significant(self.position + 1);
        let mut start = true;

        for _ in 0..SCAN_STEP_MAX {
            let Some(kind) = self.kind_at(position) else {
                return false;
            };

            if kind == closer || is_closer(kind) {
                return false;
            }

            if start && kind == GoKind::Identifier && self.names_a_field(position) {
                return true;
            }

            if is_opener(kind) {
                position = self.balanced_end(position);
                start = false;

                continue;
            }

            start = matches!(
                kind,
                GoKind::Comma | GoKind::Newline | GoKind::Semicolon | GoKind::Comment
            );

            position += 1;
        }

        false
    }

    fn names_a_field(&self, position: u32) -> bool {
        let after = self.significant(position + 1);

        let Some(next) = self.kind_at(after) else {
            return false;
        };

        if next == GoKind::BracketOpen {
            let held = self.significant(self.balanced_end(after));

            return self
                .kind_at(held)
                .is_some_and(|kind| opens_a_type(kind) || kind == GoKind::StringLiteral);
        }

        if next == GoKind::Comma {
            return false;
        }

        opens_a_type(next) || next == GoKind::StringLiteral
    }

    fn field(&mut self, named: bool, closer: GoKind) {
        let checkpoint = self.anchor();

        self.open(GoKind::Field);

        if named && self.at(GoKind::Identifier) && !self.embeds() {
            self.name_list();
        }

        if self.at(GoKind::ParenOpen) && closer == GoKind::BraceClose {
            let held = self.anchor();

            self.field_list(GoKind::ParenOpen);
            self.signature();
            self.events.start_at(held, GoKind::FuncType);
            self.events.finish();
        } else {
            self.type_of();
        }

        if self.at(GoKind::StringLiteral) {
            self.wrap(GoKind::BasicLit);
        }

        self.events.finish();

        let _ = checkpoint;
    }

    fn embeds(&self) -> bool {
        let position = self.significant(self.position);

        if self.names_a_field(position) {
            return false;
        }

        self.kind_at(self.significant(position + 1)) != Some(GoKind::Comma)
    }

    fn block(&mut self) {
        if !self.descend() {
            self.emit();

            return;
        }

        self.block_of();
        self.ascend();
    }

    fn block_of(&mut self) {
        self.open(GoKind::BlockStmt);
        self.expect(GoKind::BraceOpen, SyntaxErrorKind::UnexpectedToken);

        for _ in 0..self.steps() {
            self.skip_breaks();

            if self.at(GoKind::BraceClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.statement();

            if self.position == before {
                self.record(SyntaxErrorKind::UnexpectedToken);
                self.emit();
            }
        }

        let _ = self.eat(GoKind::BraceClose);
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
        match self.current() {
            None => {}
            Some(GoKind::BraceOpen) => {
                self.block();
                self.terminator();
            }
            Some(GoKind::ConstKeyword | GoKind::TypeKeyword | GoKind::VarKeyword) => {
                let checkpoint = self.anchor();

                self.general_declaration();
                self.events.start_at(checkpoint, GoKind::DeclStmt);
                self.events.finish();
                self.terminator();
            }
            Some(GoKind::ReturnKeyword) => {
                self.open(GoKind::ReturnStmt);
                self.bump();

                if !self.ends_here() && !self.at(GoKind::BraceClose) {
                    self.expression_list();
                }

                self.events.finish();
                self.terminator();
            }
            Some(GoKind::IfKeyword) => self.if_statement(),
            Some(GoKind::ForKeyword) => self.for_statement(),
            Some(GoKind::SwitchKeyword) => self.switch_statement(),
            Some(GoKind::SelectKeyword) => self.select_statement(),
            Some(GoKind::GoKeyword) => self.wrapped_statement(GoKind::GoStmt),
            Some(GoKind::DeferKeyword) => self.wrapped_statement(GoKind::DeferStmt),
            Some(
                GoKind::BreakKeyword
                | GoKind::ContinueKeyword
                | GoKind::FallthroughKeyword
                | GoKind::GotoKeyword,
            ) => {
                self.open(GoKind::BranchStmt);
                self.bump();
                self.identifier();
                self.events.finish();
                self.terminator();
            }
            Some(GoKind::Semicolon) => {
                self.bump();
            }
            Some(GoKind::Identifier)
                if self.ahead(1) == Some(GoKind::Colon) && self.ahead(2) != Some(GoKind::Equal) =>
            {
                self.open(GoKind::LabeledStmt);
                self.identifier();
                self.bump();
                self.skip_breaks();

                if !self.at(GoKind::BraceClose) && self.current().is_some() {
                    self.statement();
                }

                self.events.finish();
            }
            Some(_) => {
                self.simple_statement(1);
                self.terminator();
            }
        }
    }

    fn wrapped_statement(&mut self, kind: GoKind) {
        self.open(kind);
        self.bump();
        self.expression();
        self.events.finish();
        self.terminator();
    }

    fn simple_statement(&mut self, stage: u8) {
        let checkpoint = self.anchor();

        self.expression_list_staged(stage);

        let Some(kind) = self.current() else {
            self.events.start_at(checkpoint, GoKind::ExprStmt);
            self.events.finish();

            return;
        };

        if assigns(kind) {
            self.bump();

            if self.at(GoKind::RangeKeyword) {
                self.bump();
            }

            self.expression_list_staged(stage);
            self.events.start_at(checkpoint, GoKind::AssignStmt);
            self.events.finish();

            return;
        }

        if kind == GoKind::Arrow {
            self.bump();
            self.expression_staged(stage);
            self.events.start_at(checkpoint, GoKind::SendStmt);
            self.events.finish();

            return;
        }

        if matches!(kind, GoKind::MinusMinus | GoKind::PlusPlus) {
            self.bump();
            self.events.start_at(checkpoint, GoKind::IncDecStmt);
            self.events.finish();

            return;
        }

        self.events.start_at(checkpoint, GoKind::ExprStmt);
        self.events.finish();
    }

    fn header_semicolon(&self) -> bool {
        self.header_holds(GoKind::Semicolon)
    }

    fn header_holds(&self, held: GoKind) -> bool {
        let mut position = self.significant(self.position);
        let mut previous = GoKind::ErrorToken;
        let mut typed = false;

        for _ in 0..SCAN_STEP_MAX {
            let Some(kind) = self.kind_at(position) else {
                return false;
            };

            if kind == GoKind::BraceOpen {
                let literal =
                    typed || matches!(previous, GoKind::InterfaceKeyword | GoKind::StructKeyword);

                if !literal {
                    return false;
                }

                position = self.balanced_end(position);
                previous = GoKind::BraceClose;
                typed = false;

                continue;
            }

            if is_opener(kind) {
                if self.kind_at(self.significant(position + 1)) == Some(held) {
                    return true;
                }

                if kind == GoKind::BracketOpen && !ends_operand(previous) {
                    typed = true;
                }

                position = self.balanced_end(position);
                previous = GoKind::ParenClose;

                continue;
            }

            if is_closer(kind) {
                return false;
            }

            if kind == held {
                return true;
            }

            if matches!(kind, GoKind::ChanKeyword | GoKind::MapKeyword) {
                typed = true;
            }

            if kind != GoKind::Comment {
                previous = kind;
            }

            position += 1;
        }

        false
    }

    fn if_statement(&mut self) {
        self.open(GoKind::IfStmt);
        self.bump();

        if self.header_semicolon() {
            self.simple_statement(2);
            let _ = self.eat(GoKind::Semicolon);
        }

        self.expression_header();
        self.block();

        if self.eat(GoKind::ElseKeyword) {
            if self.at(GoKind::IfKeyword) {
                if self.descend() {
                    self.if_statement();
                    self.ascend();
                }
            } else {
                self.block();
                self.terminator();
            }
        } else {
            self.terminator();
        }

        self.events.finish();
    }

    fn for_statement(&mut self) {
        if self.header_holds(GoKind::RangeKeyword) {
            self.range_statement();

            return;
        }

        self.open(GoKind::ForStmt);
        self.bump();

        if self.at(GoKind::BraceOpen) {
            self.block();
            self.events.finish();
            self.terminator();

            return;
        }

        if self.header_semicolon() {
            if !self.at(GoKind::Semicolon) {
                self.simple_statement(2);
            }

            let _ = self.eat(GoKind::Semicolon);

            if !self.at(GoKind::Semicolon) {
                self.expression_header();
            }

            let _ = self.eat(GoKind::Semicolon);

            if !self.at(GoKind::BraceOpen) {
                self.simple_statement(2);
            }
        } else {
            self.expression_header();
        }

        self.block();
        self.events.finish();
        self.terminator();
    }

    fn range_statement(&mut self) {
        self.open(GoKind::RangeStmt);
        self.bump();

        if !self.at(GoKind::RangeKeyword) {
            self.expression_list_staged(2);

            if assigns(self.current().unwrap_or(GoKind::ErrorToken)) {
                self.bump();
            }
        }

        let _ = self.eat(GoKind::RangeKeyword);
        self.expression_header();
        self.block();
        self.events.finish();
        self.terminator();
    }

    fn switch_statement(&mut self) {
        let typed = self.header_holds(GoKind::TypeKeyword);

        let kind = if typed {
            GoKind::TypeSwitchStmt
        } else {
            GoKind::SwitchStmt
        };

        self.open(kind);
        self.bump();

        if self.header_semicolon() {
            self.simple_statement(2);
            let _ = self.eat(GoKind::Semicolon);
        }

        if !self.at(GoKind::BraceOpen) {
            if typed {
                self.simple_statement(2);
            } else {
                self.expression_header();
            }
        }

        self.clause_block(GoKind::CaseClause);
        self.events.finish();
        self.terminator();
    }

    fn select_statement(&mut self) {
        self.open(GoKind::SelectStmt);
        self.bump();
        self.clause_block(GoKind::CommClause);
        self.events.finish();
        self.terminator();
    }

    fn clause_block(&mut self, kind: GoKind) {
        self.open(GoKind::BlockStmt);
        self.expect(GoKind::BraceOpen, SyntaxErrorKind::UnexpectedToken);

        for _ in 0..self.steps() {
            self.skip_breaks();

            if self.at(GoKind::BraceClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.clause(kind);

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(GoKind::BraceClose);
        self.events.finish();
    }

    fn clause(&mut self, kind: GoKind) {
        self.open(kind);

        if self.eat(GoKind::CaseKeyword) {
            if kind == GoKind::CommClause {
                self.simple_statement(1);
            } else {
                self.expression_list();
            }
        } else {
            let _ = self.eat(GoKind::DefaultKeyword);
        }

        self.expect(GoKind::Colon, SyntaxErrorKind::ExpectedColon);

        for _ in 0..self.steps() {
            self.skip_breaks();

            let Some(held) = self.current() else {
                break;
            };

            if matches!(
                held,
                GoKind::BraceClose | GoKind::CaseKeyword | GoKind::DefaultKeyword
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

    fn expression(&mut self) {
        self.expression_with(true);
    }

    fn expression_with(&mut self, structures: bool) {
        self.expression_staged(u8::from(structures));
    }

    fn expression_header(&mut self) {
        self.expression_staged(2);
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
        self.expression_list_staged(1);
    }

    fn expression_list_staged(&mut self, stage: u8) {
        for _ in 0..self.steps() {
            let before = self.position;

            self.expression_staged(stage);

            if !self.eat(GoKind::Comma) {
                break;
            }

            self.skip_breaks();

            if self.position == before {
                break;
            }
        }
    }

    fn type_of(&mut self) {
        self.expression_with(false);
    }

    fn heads_a_clause(&self, base: u32) -> bool {
        let group = self.innermost_group(base);

        self.frames[group as usize].variant == Variant::Top
            && self.frames[group as usize].stage == 2
    }

    fn structures(&self, base: u32) -> bool {
        let group = self.innermost_group(base);

        if self.frames[group as usize].variant != Variant::Top {
            return true;
        }

        self.frames[group as usize].stage == 1
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

    fn pointer_prefix(&mut self) -> Step {
        let checkpoint = self.anchor();

        let frame = Frame {
            checkpoint,
            kind: GoKind::StarExpr,
            power: POWER_UNARY,
            stage: 2,
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

    fn type_prefix(&mut self, kind: GoKind) -> Step {
        let checkpoint = self.anchor();

        let frame = Frame {
            checkpoint,
            kind,
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

    fn unary(&mut self, kind: GoKind, power: u8) -> Step {
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

    fn binary(&mut self, left: u8, right: u8) -> Step {
        self.reduce_for(left);

        if self.value_count == 0 {
            self.bump();

            return Step::Operand;
        }

        let values = self.value_count - 1;

        let frame = Frame {
            checkpoint: self.values[values as usize],
            kind: GoKind::BinaryExpr,
            power: right,
            values,
            variant: Variant::Binary,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        self.bump();
        self.skip_breaks();

        Step::Operand
    }

    fn open_group(&mut self, variant: Variant, checkpoint: Checkpoint) -> Step {
        let opener = self.current().unwrap_or(GoKind::ParenOpen);
        let bracket = self.anchor();

        self.bump();
        self.skip_breaks();

        let content = self.anchor();

        let closer = if opener == GoKind::BracketOpen {
            GoKind::BracketClose
        } else if opener == GoKind::BraceOpen {
            GoKind::BraceClose
        } else {
            GoKind::ParenClose
        };

        let kind = if variant == Variant::Call {
            GoKind::CallExpr
        } else if variant == Variant::Composite {
            GoKind::CompositeLit
        } else if variant == Variant::Index {
            GoKind::IndexExpr
        } else if variant == Variant::Paren {
            GoKind::ParenExpr
        } else {
            GoKind::ErrorNode
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
            if frame.stage == 1 {
                GoKind::SliceExpr
            } else if frame.elements > 0 {
                GoKind::IndexListExpr
            } else {
                GoKind::IndexExpr
            }
        } else {
            frame.kind
        };

        self.events.start_at(frame.checkpoint, kind);
        self.bump();
        self.events.finish();
        self.value_count = frame.values;
        self.push_value(frame.checkpoint);
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

        self.operand_of(kind, base)
    }

    fn operand_of(&mut self, kind: GoKind, base: u32) -> Step {
        match Some(kind) {
            None => Step::Done,
            Some(GoKind::Star) => self.pointer_prefix(),
            Some(GoKind::Arrow) => {
                if self.ahead(1) == Some(GoKind::ChanKeyword) {
                    return self.channel_type();
                }

                self.unary(GoKind::UnaryExpr, POWER_UNARY)
            }
            Some(GoKind::ChanKeyword) => self.channel_type(),
            Some(GoKind::DotDotDot) => self.type_prefix(GoKind::Ellipsis),
            Some(GoKind::MapKeyword) => self.map_type(),
            Some(GoKind::BracketOpen) => self.array_type(),
            Some(GoKind::StructKeyword) => {
                let checkpoint = self.anchor();

                self.bump();
                self.field_list(GoKind::BraceOpen);
                self.events.start_at(checkpoint, GoKind::StructType);
                self.events.finish();
                self.push_value(checkpoint);

                Step::Operator
            }
            Some(GoKind::InterfaceKeyword) => {
                let checkpoint = self.anchor();

                self.bump();
                self.field_list(GoKind::BraceOpen);
                self.events.start_at(checkpoint, GoKind::InterfaceType);
                self.events.finish();
                self.push_value(checkpoint);

                Step::Operator
            }
            Some(GoKind::FuncKeyword) => self.function_literal(base),
            Some(GoKind::ParenOpen) => {
                let checkpoint = self.anchor();

                self.open_group(Variant::Paren, checkpoint)
            }
            Some(GoKind::BraceOpen) if self.in_composite(base) => {
                let checkpoint = self.anchor();

                self.open_group(Variant::Composite, checkpoint)
            }
            Some(GoKind::Identifier) => {
                let checkpoint = self.anchor();

                self.wrap(GoKind::Ident);
                self.push_value(checkpoint);

                Step::Operator
            }
            Some(_) if is_literal(kind) => {
                let checkpoint = self.anchor();

                self.wrap(GoKind::BasicLit);
                self.push_value(checkpoint);

                Step::Operator
            }
            Some(_) if is_prefix(kind) => self.unary(GoKind::UnaryExpr, POWER_UNARY),
            Some(_) => Step::Done,
        }
    }

    fn in_composite(&self, base: u32) -> bool {
        let group = self.innermost_group(base);

        self.frames[group as usize].variant == Variant::Composite
    }

    fn channel_type(&mut self) -> Step {
        let checkpoint = self.anchor();
        let _ = self.eat(GoKind::Arrow);
        let _ = self.eat(GoKind::ChanKeyword);
        let _ = self.eat(GoKind::Arrow);

        let frame = Frame {
            checkpoint,
            kind: GoKind::ChanType,
            power: POWER_UNARY,
            stage: 1,
            values: self.value_count,
            variant: Variant::Unary,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        Step::Operand
    }

    fn map_type(&mut self) -> Step {
        let checkpoint = self.anchor();

        self.bump();
        let _ = self.eat(GoKind::BracketOpen);
        self.type_of();
        let _ = self.eat(GoKind::BracketClose);

        let frame = Frame {
            checkpoint,
            kind: GoKind::MapType,
            power: POWER_UNARY,
            stage: 1,
            values: self.value_count,
            variant: Variant::Unary,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        Step::Operand
    }

    fn array_type(&mut self) -> Step {
        let checkpoint = self.anchor();

        self.bump();

        if !self.at(GoKind::BracketClose) {
            self.expression();
        }

        let _ = self.eat(GoKind::BracketClose);

        let frame = Frame {
            checkpoint,
            kind: GoKind::ArrayType,
            power: POWER_UNARY,
            stage: 1,
            values: self.value_count,
            variant: Variant::Unary,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        Step::Operand
    }

    fn function_literal(&mut self, base: u32) -> Step {
        let checkpoint = self.anchor();
        let structures = self.structures(base) && !self.holds_a_type();

        self.open(GoKind::FuncType);
        self.bump();
        self.signature();
        self.events.finish();

        if !self.at(GoKind::BraceOpen) || !structures {
            self.push_value(checkpoint);

            return Step::Operator;
        }

        self.block();
        self.events.start_at(checkpoint, GoKind::FuncLit);
        self.events.finish();
        self.push_value(checkpoint);

        Step::Operator
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

        if kind == GoKind::DotDotDot {
            self.reduce_above(group + 1);
            self.bump();

            return Step::Operator;
        }

        if kind == GoKind::Comma {
            return self.comma(group);
        }

        if kind == GoKind::Colon && frame.variant == Variant::Index {
            self.reduce_above(group + 1);
            self.bump();
            self.frames[group as usize].stage = 1;

            return Step::Operand;
        }

        if kind == GoKind::Colon && frame.variant == Variant::Composite {
            return self.key_value(group);
        }

        if kind == GoKind::Dot {
            return self.selector();
        }

        if let Some(step) = self.trailer_step(kind, base) {
            return step;
        }

        if let Some((left, right)) = infix_of(kind) {
            return self.binary(left, right);
        }

        Step::Done
    }

    fn trailer_step(&mut self, kind: GoKind, base: u32) -> Option<Step> {
        if kind == GoKind::ParenOpen {
            self.drain_types(1);

            return Some(self.trailer(Variant::Call));
        }

        if kind == GoKind::BracketOpen {
            return Some(self.trailer(Variant::Index));
        }

        if kind == GoKind::BraceOpen
            && self.value_count > 0
            && (self.structures(base) || (self.heads_a_clause(base) && self.holds_a_type()))
        {
            self.drain_types(2);

            return Some(self.trailer(Variant::Composite));
        }

        None
    }

    fn holds_a_type(&self) -> bool {
        if self.frame_count == 0 {
            return false;
        }

        let top = self.frames[self.frame_count as usize - 1];

        top.variant == Variant::Unary && top.stage == 1
    }

    fn drain_types(&mut self, stage: u8) {
        for _ in 0..EXPRESSION_DEPTH_MAX {
            if self.frame_count == 0 {
                return;
            }

            let top = self.frames[self.frame_count as usize - 1];

            if top.variant != Variant::Unary || top.stage == 0 || top.stage > stage {
                return;
            }

            self.reduce_top();
        }
    }

    fn comma(&mut self, group: u32) -> Step {
        let frame = self.frames[group as usize];

        if frame.variant == Variant::Top || frame.variant == Variant::Paren {
            return Step::Done;
        }

        self.reduce_above(group + 1);
        self.bump();
        self.skip_breaks();
        self.value_count = frame.values;
        self.frames[group as usize].elements += 1;
        self.frames[group as usize].element_values = self.value_count;

        Step::Operand
    }

    fn key_value(&mut self, group: u32) -> Step {
        self.reduce_above(group + 1);

        if self.value_count == 0 {
            return Step::Done;
        }

        let values = self.value_count - 1;

        let frame = Frame {
            checkpoint: self.values[values as usize],
            kind: GoKind::KeyValueExpr,
            power: POWER_BARRIER,
            values,
            variant: Variant::Binary,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        self.bump();
        self.skip_breaks();

        Step::Operand
    }

    fn selector(&mut self) -> Step {
        if self.value_count == 0 {
            return Step::Done;
        }

        let checkpoint = self.values[self.value_count as usize - 1];

        if self.ahead(1) == Some(GoKind::ParenOpen) {
            self.events.start_at(checkpoint, GoKind::TypeAssertExpr);
            self.bump();
            self.bump();

            if self.at(GoKind::TypeKeyword) {
                self.bump();
            } else {
                self.type_of();
            }

            let _ = self.eat(GoKind::ParenClose);
            self.events.finish();

            return Step::Operator;
        }

        self.events.start_at(checkpoint, GoKind::SelectorExpr);
        self.bump();
        self.identifier();
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
}

pub fn build(
    source: &[u8],
    tokens: &[Token],
    raw: &[GoKind],
    events: &mut Events<GoKind>,
    tree: &mut Tree<GoKind>,
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
