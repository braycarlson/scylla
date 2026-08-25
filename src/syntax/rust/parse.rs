use crate::bounded::{Span, count_of};
use crate::syntax::rust::expression::{
    EXPRESSION_DEPTH_MAX,
    Frame,
    POWER_AND_LEFT,
    POWER_AND_RIGHT,
    POWER_ASSIGN_RIGHT,
    POWER_BARRIER,
    POWER_CAST,
    POWER_COMPARE_LEFT,
    POWER_RANGE_LEFT,
    POWER_RANGE_RIGHT,
    POWER_SHIFT_LEFT,
    POWER_SHIFT_RIGHT,
    POWER_UNARY,
    VALUE_COUNT_MAX,
    Variant,
    infix_of,
    is_literal,
    literal_kind,
    opens_a_path,
};
use crate::syntax::rust::kind::RustKind;
use crate::syntax::{SyntaxError, SyntaxErrorKind};
use crate::token::Token;
use crate::tree::{Checkpoint, Events, Structure, Tree, replay};

const CHAIN_DEPTH_MAX: u32 = 4_096;
const NEST_DEPTH_MAX: u32 = 96;
const SCAN_STEP_MAX: u32 = 1 << 16;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Step {
    Done,
    Operand,
    Operator,
}

struct Parser<'source, 'run> {
    events: &'run mut Events<RustKind>,
    frame_count: u32,
    frames: [Frame; EXPRESSION_DEPTH_MAX as usize],
    nesting: u32,
    outcome: Structure,
    position: u32,
    raw: &'run [RustKind],
    significant_next: u32,
    source: &'source [u8],
    tokens: &'run [Token],
    tree: &'run mut Tree<RustKind>,
    value_count: u32,
    values: [Checkpoint; VALUE_COUNT_MAX as usize],
}

const fn is_layout(kind: RustKind) -> bool {
    matches!(kind, RustKind::Comment | RustKind::DocComment)
}

const fn is_opener(kind: RustKind) -> bool {
    matches!(
        kind,
        RustKind::BraceOpen | RustKind::BracketOpen | RustKind::ParenOpen
    )
}

const fn is_closer(kind: RustKind) -> bool {
    matches!(
        kind,
        RustKind::BraceClose | RustKind::BracketClose | RustKind::ParenClose
    )
}

const fn is_block_like(kind: RustKind) -> bool {
    matches!(
        kind,
        RustKind::AsyncKeyword
            | RustKind::BraceOpen
            | RustKind::ConstKeyword
            | RustKind::ForKeyword
            | RustKind::IfKeyword
            | RustKind::LoopKeyword
            | RustKind::MatchKeyword
            | RustKind::TryKeyword
            | RustKind::UnsafeKeyword
            | RustKind::WhileKeyword
    )
}

const fn is_name(kind: RustKind) -> bool {
    matches!(
        kind,
        RustKind::Identifier
            | RustKind::MacroKeyword
            | RustKind::TryKeyword
            | RustKind::UnionKeyword
    )
}

const fn group_kind(variant: Variant) -> RustKind {
    match variant {
        Variant::Array => RustKind::ExprArray,
        Variant::Call => RustKind::ExprCall,
        Variant::Paren => RustKind::ExprParen,
        Variant::Struct => RustKind::ExprStruct,
        Variant::Subscript => RustKind::ExprIndex,
        Variant::Binary | Variant::Group | Variant::Top | Variant::Unary => RustKind::ErrorNode,
    }
}

impl Parser<'_, '_> {
    fn count(&self) -> u32 {
        count_of(self.raw.len())
    }

    fn kind_at(&self, position: u32) -> Option<RustKind> {
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

    fn current(&self) -> Option<RustKind> {
        self.kind_at(self.significant(self.position))
    }

    fn ahead(&self, steps: u32) -> Option<RustKind> {
        self.kind_at(self.ahead_position(steps))
    }

    fn ahead_position(&self, steps: u32) -> u32 {
        let mut position = self.significant(self.position);

        for _ in 0..steps {
            position = self.significant(position + 1);
        }

        position
    }

    fn at(&self, kind: RustKind) -> bool {
        self.current() == Some(kind)
    }

    fn adjacent(&self, first: u32, second: u32) -> bool {
        let Some(left) = self.tokens.get(first as usize) else {
            return false;
        };

        let Some(right) = self.tokens.get(second as usize) else {
            return false;
        };

        left.end() == right.offset
    }

    fn joined(&self, kind: RustKind) -> bool {
        let position = self.significant(self.position);

        self.kind_at(position) == Some(kind)
            && self.kind_at(position + 1) == Some(kind)
            && self.adjacent(position, position + 1)
    }

    fn word(&self, word: &[u8]) -> bool {
        let position = self.significant(self.position);

        self.kind_at(position) == Some(RustKind::Identifier)
            && self
                .tokens
                .get(position as usize)
                .is_some_and(|token| token.text(self.source) == word)
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

    fn open(&mut self, kind: RustKind) {
        self.skip_trivia();
        self.events.start(kind);
    }

    fn bump(&mut self) {
        self.skip_trivia();
        self.emit();
    }

    fn eat(&mut self, kind: RustKind) -> bool {
        if !self.at(kind) {
            return false;
        }

        self.bump();

        true
    }

    fn expect(&mut self, kind: RustKind, failure: SyntaxErrorKind) -> bool {
        if self.eat(kind) {
            return true;
        }

        self.record(failure);

        false
    }

    fn wrap(&mut self, kind: RustKind) {
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

    fn skip_group(&mut self) {
        let Some(kind) = self.current() else {
            return;
        };

        if !is_opener(kind) {
            return;
        }

        let end = self.balanced_end(self.significant(self.position));

        while self.position < end && self.position < self.count() {
            self.emit();
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

    fn run(&mut self) {
        self.events.start(RustKind::File);
        self.inner_attributes();
        self.items_until(RustKind::ErrorToken);
        self.events.finish();
    }

    fn items_until(&mut self, closer: RustKind) {
        for _ in 0..u32::MAX {
            self.skip_trivia();

            let Some(kind) = self.current() else {
                return;
            };

            if kind == closer {
                return;
            }

            let before = self.position;

            self.item();

            if self.position == before {
                self.record(SyntaxErrorKind::UnexpectedToken);
                self.emit();
            }
        }
    }

    fn inner_attributes(&mut self) {
        for _ in 0..CHAIN_DEPTH_MAX {
            if !self.at(RustKind::Pound) || self.ahead(1) != Some(RustKind::Bang) {
                break;
            }

            self.attribute();
        }
    }

    fn attributes(&mut self) {
        for _ in 0..CHAIN_DEPTH_MAX {
            if !self.at(RustKind::Pound) {
                break;
            }

            self.attribute();
        }
    }

    fn attribute(&mut self) {
        {
            self.open(RustKind::Attribute);
            self.bump();
            let _ = self.eat(RustKind::Bang);

            if self.at(RustKind::BracketOpen) {
                let end = self.balanced_end(self.significant(self.position));

                self.bump();
                self.meta(end - 1);

                while self.position < end && self.position < self.count() {
                    self.emit();
                }
            }

            self.events.finish();
        }
    }

    fn meta(&mut self, limit: u32) {
        if !opens_a_path(self.current().unwrap_or(RustKind::ErrorToken)) {
            return;
        }

        let checkpoint = self.anchor();

        self.path(true);

        if self.at(RustKind::Equal) {
            self.events.start_at(checkpoint, RustKind::MetaNameValue);
            self.bump();
            self.expression_single();
            self.events.finish();

            return;
        }

        if !matches!(
            self.current(),
            Some(RustKind::BraceOpen | RustKind::BracketOpen | RustKind::ParenOpen)
        ) {
            return;
        }

        self.events.start_at(checkpoint, RustKind::MetaList);
        self.skip_group();
        self.events.finish();

        let _ = limit;
    }

    fn visibility(&mut self) {
        if !self.at(RustKind::PubKeyword) {
            return;
        }

        if self.ahead(1) != Some(RustKind::ParenOpen) {
            self.bump();

            return;
        }

        let end = self.balanced_end(self.ahead_position(1));

        self.open(RustKind::VisRestricted);
        self.bump();
        self.bump();
        let _ = self.eat(RustKind::InKeyword);

        if opens_a_path(self.current().unwrap_or(RustKind::ErrorToken)) {
            self.path(true);
        }

        while self.position < end && self.position < self.count() {
            self.emit();
        }

        self.events.finish();
    }

    fn item(&mut self) {
        if !self.descend() {
            self.emit();

            return;
        }

        self.item_of();
        self.ascend();
    }

    fn item_of(&mut self) {
        let checkpoint = self.anchor();

        self.attributes();
        self.visibility();

        match self.current() {
            None => {}
            Some(RustKind::UseKeyword) => self.item_use(checkpoint),
            Some(RustKind::StructKeyword) => self.item_struct(checkpoint, RustKind::ItemStruct),
            Some(RustKind::UnionKeyword)
                if is_name(self.ahead(1).unwrap_or(RustKind::ErrorToken)) =>
            {
                self.item_struct(checkpoint, RustKind::ItemUnion);
            }
            Some(RustKind::EnumKeyword) => self.item_enum(checkpoint),
            Some(RustKind::TraitKeyword) => self.item_trait(checkpoint),
            Some(RustKind::ImplKeyword) => self.item_impl(checkpoint),
            Some(RustKind::UnsafeKeyword) if self.ahead(1) == Some(RustKind::TraitKeyword) => {
                self.item_trait(checkpoint);
            }
            Some(RustKind::UnsafeKeyword) if self.ahead(1) == Some(RustKind::ImplKeyword) => {
                self.item_impl(checkpoint);
            }
            Some(RustKind::ModKeyword) => self.item_mod(checkpoint),
            Some(RustKind::TypeKeyword) => self.item_type(checkpoint),
            Some(RustKind::MacroKeyword)
                if is_name(self.ahead(1).unwrap_or(RustKind::ErrorToken)) =>
            {
                self.item_macro(checkpoint);
            }
            Some(RustKind::ExternKeyword) if self.ahead(1) == Some(RustKind::CrateKeyword) => {
                self.item_extern_crate(checkpoint);
            }
            Some(RustKind::StaticKeyword) => self.item_static(checkpoint, RustKind::ItemStatic),
            Some(RustKind::ConstKeyword) if self.ahead(1) != Some(RustKind::FnKeyword) => {
                self.item_static(checkpoint, RustKind::ItemConst);
            }
            Some(_) if self.opens_a_foreign_module(self.position) => {
                self.item_foreign_mod(checkpoint);
            }
            Some(_) if self.opens_a_function() => self.item_fn(checkpoint, RustKind::ItemFn),
            Some(_) if self.opens_a_macro_call() => self.item_macro(checkpoint),
            Some(_) => {
                self.record(SyntaxErrorKind::UnexpectedToken);
                self.emit();
            }
        }
    }

    fn opens_a_function(&self) -> bool {
        let mut position = self.significant(self.position);

        for _ in 0..8 {
            let Some(kind) = self.kind_at(position) else {
                return false;
            };

            if kind == RustKind::FnKeyword {
                return true;
            }

            if !matches!(
                kind,
                RustKind::AsyncKeyword
                    | RustKind::ConstKeyword
                    | RustKind::ExternKeyword
                    | RustKind::UnsafeKeyword
            ) && !self.word_at(position, b"default")
            {
                return false;
            }

            position = self.significant(position + 1);

            if self.kind_at(position) == Some(RustKind::StringLiteral) {
                position = self.significant(position + 1);
            }
        }

        false
    }

    fn word_at(&self, position: u32, word: &[u8]) -> bool {
        self.kind_at(position) == Some(RustKind::Identifier)
            && self
                .tokens
                .get(position as usize)
                .is_some_and(|token| token.text(self.source) == word)
    }

    fn opens_a_foreign_module(&self, from: u32) -> bool {
        let mut position = self.significant(from);

        if self.kind_at(position) == Some(RustKind::UnsafeKeyword) {
            position = self.significant(position + 1);
        }

        if self.kind_at(position) != Some(RustKind::ExternKeyword) {
            return false;
        }

        position = self.significant(position + 1);

        if self.kind_at(position) == Some(RustKind::StringLiteral) {
            position = self.significant(position + 1);
        }

        self.kind_at(position) == Some(RustKind::BraceOpen)
    }

    fn opens_a_macro_call(&self) -> bool {
        if !opens_a_path(self.current().unwrap_or(RustKind::ErrorToken)) {
            return false;
        }

        let mut position = self.significant(self.position);

        for _ in 0..CHAIN_DEPTH_MAX {
            let Some(kind) = self.kind_at(position) else {
                return false;
            };

            if kind == RustKind::Bang {
                return true;
            }

            if !is_name(kind)
                && !matches!(
                    kind,
                    RustKind::ColonColon
                        | RustKind::CrateKeyword
                        | RustKind::SelfLower
                        | RustKind::SelfUpper
                        | RustKind::SuperKeyword
                )
            {
                return false;
            }

            position = self.significant(position + 1);
        }

        false
    }

    fn item_use(&mut self, checkpoint: Checkpoint) {
        self.events.start_at(checkpoint, RustKind::ItemUse);
        self.bump();
        let _ = self.eat(RustKind::ColonColon);
        self.use_tree();
        let _ = self.eat(RustKind::Semicolon);
        self.events.finish();
    }

    fn use_tree(&mut self) {
        if !self.descend() {
            self.emit();

            return;
        }

        self.use_tree_of();
        self.ascend();
    }

    fn use_tree_of(&mut self) {
        let Some(kind) = self.current() else {
            return;
        };

        if kind == RustKind::Star {
            self.wrap(RustKind::UseGlob);

            return;
        }

        if kind == RustKind::BraceOpen {
            self.use_group();

            return;
        }

        let checkpoint = self.anchor();

        if !is_name(kind)
            && !matches!(
                kind,
                RustKind::CrateKeyword
                    | RustKind::SelfLower
                    | RustKind::SelfUpper
                    | RustKind::SuperKeyword
                    | RustKind::Underscore
            )
        {
            return;
        }

        if self.ahead(1) == Some(RustKind::ColonColon) {
            self.events.start_at(checkpoint, RustKind::UsePath);
            self.wrap(RustKind::Ident);
            self.bump();
            self.use_tree();
            self.events.finish();

            return;
        }

        if self.ahead(1) == Some(RustKind::AsKeyword) {
            self.events.start_at(checkpoint, RustKind::UseRename);
            self.wrap(RustKind::Ident);
            self.bump();

            if is_name(self.current().unwrap_or(RustKind::ErrorToken))
                || self.at(RustKind::Underscore)
            {
                self.wrap(RustKind::Ident);
            }

            self.events.finish();

            return;
        }

        self.events.start_at(checkpoint, RustKind::UseName);
        self.wrap(RustKind::Ident);
        self.events.finish();
    }

    fn use_group(&mut self) {
        self.open(RustKind::UseGroup);
        self.bump();

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if self.at(RustKind::BraceClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.use_tree();

            if !self.eat(RustKind::Comma) {
                break;
            }

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(RustKind::BraceClose);
        self.events.finish();
    }

    fn item_struct(&mut self, checkpoint: Checkpoint, kind: RustKind) {
        self.events.start_at(checkpoint, kind);
        self.bump();
        self.identifier();
        self.generics();

        if self.at(RustKind::ParenOpen) {
            self.fields(RustKind::FieldsUnnamed);
            self.where_clause();
            let _ = self.eat(RustKind::Semicolon);
            self.events.finish();

            return;
        }

        self.where_clause();

        if self.at(RustKind::BraceOpen) {
            self.fields(RustKind::FieldsNamed);
        } else {
            let _ = self.eat(RustKind::Semicolon);
        }

        self.events.finish();
    }

    fn item_enum(&mut self, checkpoint: Checkpoint) {
        self.events.start_at(checkpoint, RustKind::ItemEnum);
        self.bump();
        self.identifier();
        self.generics();
        self.where_clause();
        self.expect(RustKind::BraceOpen, SyntaxErrorKind::UnexpectedToken);

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if self.at(RustKind::BraceClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.variant();

            if !self.eat(RustKind::Comma) {
                break;
            }

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(RustKind::BraceClose);
        self.events.finish();
    }

    fn variant(&mut self) {
        let checkpoint = self.anchor();

        self.attributes();
        self.events.start_at(checkpoint, RustKind::Variant);
        self.identifier();

        match self.current().unwrap_or(RustKind::ErrorToken) {
            RustKind::ParenOpen => self.fields(RustKind::FieldsUnnamed),
            RustKind::BraceOpen => self.fields(RustKind::FieldsNamed),
            _ => {}
        }

        if self.eat(RustKind::Equal) {
            self.expression_single();
        }

        self.events.finish();
    }

    fn fields(&mut self, kind: RustKind) {
        let closer = if kind == RustKind::FieldsNamed {
            RustKind::BraceClose
        } else {
            RustKind::ParenClose
        };

        self.open(kind);
        self.bump();

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if self.at(closer) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.field(kind == RustKind::FieldsNamed);

            if !self.eat(RustKind::Comma) {
                break;
            }

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(closer);
        self.events.finish();
    }

    fn field(&mut self, named: bool) {
        let checkpoint = self.anchor();

        self.attributes();
        self.visibility();
        self.events.start_at(checkpoint, RustKind::Field);

        if named {
            self.identifier();
            self.expect(RustKind::Colon, SyntaxErrorKind::ExpectedColon);
        }

        self.type_of();
        self.events.finish();
    }

    fn item_trait(&mut self, checkpoint: Checkpoint) {
        let _ = self.eat(RustKind::UnsafeKeyword);
        self.bump();
        self.identifier();
        self.generics();

        if self.eat(RustKind::Equal) {
            self.type_bounds();
            self.where_clause();
            let _ = self.eat(RustKind::Semicolon);
            self.events.start_at(checkpoint, RustKind::ItemTraitAlias);
            self.events.finish();

            return;
        }

        if self.eat(RustKind::Colon) {
            self.type_bounds();
        }

        self.where_clause();
        self.expect(RustKind::BraceOpen, SyntaxErrorKind::UnexpectedToken);
        self.member_list(RustKind::TraitItemFn);
        self.events.start_at(checkpoint, RustKind::ItemTrait);
        self.events.finish();
    }

    fn item_impl(&mut self, checkpoint: Checkpoint) {
        self.events.start_at(checkpoint, RustKind::ItemImpl);
        let _ = self.eat(RustKind::UnsafeKeyword);
        self.bump();
        self.generics();
        let _ = self.eat(RustKind::Bang);
        let path = self.trait_ahead();

        if path {
            self.path(false);
            let _ = self.eat(RustKind::ForKeyword);
        }

        self.type_of();
        self.where_clause();
        self.expect(RustKind::BraceOpen, SyntaxErrorKind::UnexpectedToken);
        self.member_list(RustKind::ImplItemFn);
        self.events.finish();
    }

    fn trait_ahead(&self) -> bool {
        let mut position = self.significant(self.position);
        let mut depth = 0_u32;

        for _ in 0..SCAN_STEP_MAX {
            let Some(kind) = self.kind_at(position) else {
                return false;
            };

            if kind == RustKind::Less {
                depth += 1;
            }

            if kind == RustKind::Greater {
                depth = depth.saturating_sub(1);
            }

            if depth == 0 && matches!(kind, RustKind::BraceOpen | RustKind::WhereKeyword) {
                return false;
            }

            if is_opener(kind) {
                position = self.balanced_end(position);

                continue;
            }

            if depth == 0 && kind == RustKind::ForKeyword {
                return true;
            }

            if is_closer(kind) {
                return false;
            }

            position += 1;
        }

        false
    }

    fn item_mod(&mut self, checkpoint: Checkpoint) {
        self.events.start_at(checkpoint, RustKind::ItemMod);
        self.bump();
        self.identifier();

        if self.eat(RustKind::Semicolon) {
            self.events.finish();

            return;
        }

        self.expect(RustKind::BraceOpen, SyntaxErrorKind::UnexpectedToken);
        self.inner_attributes();
        self.items_until(RustKind::BraceClose);
        let _ = self.eat(RustKind::BraceClose);
        self.events.finish();
    }

    fn item_type(&mut self, checkpoint: Checkpoint) {
        self.events.start_at(checkpoint, RustKind::ItemType);
        self.bump();
        self.identifier();
        self.generics();
        self.where_clause();

        if self.eat(RustKind::Equal) {
            self.type_of();
        }

        let _ = self.eat(RustKind::Semicolon);
        self.events.finish();
    }

    fn item_static(&mut self, checkpoint: Checkpoint, kind: RustKind) {
        self.events.start_at(checkpoint, kind);
        self.bump();
        let _ = self.eat(RustKind::MutKeyword);

        if self.at(RustKind::Underscore) {
            self.wrap(RustKind::Ident);
        } else {
            self.identifier();
        }

        self.generics();

        if self.eat(RustKind::Colon) {
            self.type_of();
        }

        if self.eat(RustKind::Equal) {
            self.expression_single();
        }

        let _ = self.eat(RustKind::Semicolon);
        self.events.finish();
    }

    fn item_extern_crate(&mut self, checkpoint: Checkpoint) {
        self.events.start_at(checkpoint, RustKind::ItemExternCrate);
        self.bump();
        self.bump();
        self.identifier();

        if self.eat(RustKind::AsKeyword) {
            if self.at(RustKind::Underscore) {
                self.wrap(RustKind::Ident);
            } else {
                self.identifier();
            }
        }

        let _ = self.eat(RustKind::Semicolon);
        self.events.finish();
    }

    fn item_macro(&mut self, checkpoint: Checkpoint) {
        self.events.start_at(checkpoint, RustKind::ItemMacro);

        let held = self.anchor();

        if self.at(RustKind::MacroKeyword) {
            self.bump();
            self.identifier();
            self.skip_group();
            self.events.start_at(held, RustKind::Macro);
            self.events.finish();
            self.events.finish();

            return;
        }

        self.path(true);
        let _ = self.eat(RustKind::Bang);

        if is_name(self.current().unwrap_or(RustKind::ErrorToken)) {
            self.identifier();
        }

        self.skip_group();
        self.events.start_at(held, RustKind::Macro);
        self.events.finish();
        let _ = self.eat(RustKind::Semicolon);
        self.events.finish();
    }

    fn item_foreign_mod(&mut self, checkpoint: Checkpoint) {
        self.events.start_at(checkpoint, RustKind::ItemForeignMod);
        let _ = self.eat(RustKind::UnsafeKeyword);
        self.abi();
        self.expect(RustKind::BraceOpen, SyntaxErrorKind::UnexpectedToken);
        self.member_list(RustKind::ForeignItemFn);
        self.events.finish();
    }

    fn abi(&mut self) {
        if !self.at(RustKind::ExternKeyword) {
            return;
        }

        self.open(RustKind::Abi);
        self.bump();

        if self.at(RustKind::StringLiteral) {
            self.wrap(RustKind::LitStr);
        }

        self.events.finish();
    }

    fn member_list(&mut self, family: RustKind) {
        self.inner_attributes();

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if self.at(RustKind::BraceClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.member(family);

            if self.position == before {
                self.record(SyntaxErrorKind::UnexpectedToken);
                self.emit();
            }
        }

        let _ = self.eat(RustKind::BraceClose);
    }

    fn member(&mut self, family: RustKind) {
        if !self.descend() {
            self.emit();

            return;
        }

        self.member_of(family);
        self.ascend();
    }

    fn member_of(&mut self, family: RustKind) {
        let checkpoint = self.anchor();

        self.attributes();
        self.visibility();

        let Some(kind) = self.current() else {
            return;
        };

        let function = if family == RustKind::TraitItemFn {
            RustKind::TraitItemFn
        } else if family == RustKind::ImplItemFn {
            RustKind::ImplItemFn
        } else {
            RustKind::ForeignItemFn
        };

        if kind == RustKind::TypeKeyword {
            self.member_type(checkpoint, family);

            return;
        }

        if kind == RustKind::ConstKeyword && self.ahead(1) != Some(RustKind::FnKeyword) {
            self.member_const(checkpoint, family);

            return;
        }

        if kind == RustKind::StaticKeyword {
            self.item_static(checkpoint, RustKind::ForeignItemStatic);

            return;
        }

        if self.opens_a_function() {
            self.item_fn(checkpoint, function);

            return;
        }

        if self.opens_a_macro_call() {
            let macro_kind = if family == RustKind::TraitItemFn {
                RustKind::TraitItemMacro
            } else if family == RustKind::ImplItemFn {
                RustKind::ImplItemMacro
            } else {
                RustKind::ForeignItemMacro
            };

            self.member_macro(checkpoint, macro_kind);

            return;
        }

        self.record(SyntaxErrorKind::UnexpectedToken);
        self.emit();
    }

    fn member_macro(&mut self, checkpoint: Checkpoint, kind: RustKind) {
        self.events.start_at(checkpoint, kind);

        let held = self.anchor();

        self.path(true);
        let _ = self.eat(RustKind::Bang);

        if is_name(self.current().unwrap_or(RustKind::ErrorToken)) {
            self.identifier();
        }

        self.skip_group();
        self.events.start_at(held, RustKind::Macro);
        self.events.finish();
        let _ = self.eat(RustKind::Semicolon);
        self.events.finish();
    }

    fn member_type(&mut self, checkpoint: Checkpoint, family: RustKind) {
        let kind = if family == RustKind::TraitItemFn {
            RustKind::TraitItemType
        } else if family == RustKind::ImplItemFn {
            RustKind::ImplItemType
        } else {
            RustKind::ForeignItemType
        };

        self.events.start_at(checkpoint, kind);
        self.bump();
        self.identifier();
        self.generics();

        if self.eat(RustKind::Colon) {
            self.type_bounds();
        }

        self.where_clause();

        if self.eat(RustKind::Equal) {
            self.type_of();
        }

        let _ = self.eat(RustKind::Semicolon);
        self.events.finish();
    }

    fn member_const(&mut self, checkpoint: Checkpoint, family: RustKind) {
        let kind = if family == RustKind::TraitItemFn {
            RustKind::TraitItemConst
        } else {
            RustKind::ImplItemConst
        };

        self.events.start_at(checkpoint, kind);
        self.bump();

        if self.at(RustKind::Underscore) {
            self.wrap(RustKind::Ident);
        } else {
            self.identifier();
        }

        self.generics();

        if self.eat(RustKind::Colon) {
            self.type_of();
        }

        if self.eat(RustKind::Equal) {
            self.expression_single();
        }

        let _ = self.eat(RustKind::Semicolon);
        self.events.finish();
    }

    fn item_fn(&mut self, checkpoint: Checkpoint, kind: RustKind) {
        self.events.start_at(checkpoint, kind);
        self.signature();

        if self.at(RustKind::BraceOpen) {
            self.block();
        } else {
            let _ = self.eat(RustKind::Semicolon);
        }

        self.events.finish();
    }

    fn signature(&mut self) {
        self.open(RustKind::Signature);

        for _ in 0..8 {
            if self.eat(RustKind::ConstKeyword)
                || self.eat(RustKind::AsyncKeyword)
                || self.eat(RustKind::UnsafeKeyword)
            {
                continue;
            }

            if self.word(b"default") {
                self.bump();

                continue;
            }

            if self.at(RustKind::ExternKeyword) {
                self.abi();

                continue;
            }

            break;
        }

        self.expect(RustKind::FnKeyword, SyntaxErrorKind::UnexpectedToken);
        self.identifier();
        self.generics();
        self.parameters();

        if self.eat(RustKind::RArrow) {
            self.type_of();
        }

        self.where_clause();
        self.events.finish();
    }

    fn parameters(&mut self) {
        if !self.eat(RustKind::ParenOpen) {
            return;
        }

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if self.at(RustKind::ParenClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.parameter();

            if !self.eat(RustKind::Comma) {
                break;
            }

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(RustKind::ParenClose);
    }

    fn parameter(&mut self) {
        let checkpoint = self.anchor();

        self.attributes();

        if self.at(RustKind::DotDotDot) {
            self.events.start_at(checkpoint, RustKind::Variadic);
            self.bump();
            self.events.finish();

            return;
        }

        if self.receiver_ahead() {
            self.receiver(checkpoint);

            return;
        }

        self.events.start_at(checkpoint, RustKind::PatType);
        self.pattern();
        self.expect(RustKind::Colon, SyntaxErrorKind::ExpectedColon);
        self.type_of();
        self.events.finish();
    }

    fn receiver_ahead(&self) -> bool {
        let mut position = self.significant(self.position);

        if self.kind_at(position) == Some(RustKind::Ampersand) {
            position = self.significant(position + 1);

            if self.kind_at(position) == Some(RustKind::Apostrophe) {
                position = self.significant(position + 2);
            }
        }

        if self.kind_at(position) == Some(RustKind::MutKeyword) {
            position = self.significant(position + 1);
        }

        self.kind_at(position) == Some(RustKind::SelfLower)
    }

    fn receiver(&mut self, checkpoint: Checkpoint) {
        self.events.start_at(checkpoint, RustKind::Receiver);

        let held = self.anchor();
        let referenced = self.at(RustKind::Ampersand);

        if referenced {
            self.bump();
            self.lifetime_of(true);
        }

        let _ = self.eat(RustKind::MutKeyword);

        if self.ahead(1) == Some(RustKind::Colon) {
            self.bump();
            self.bump();
            self.type_of();
            self.events.finish();

            return;
        }

        let inner = self.anchor();

        self.self_path();

        self.events.start_at(inner, RustKind::TypePath);
        self.events.finish();

        if referenced {
            self.events.start_at(held, RustKind::TypeReference);
            self.events.finish();
        }

        self.events.finish();
    }

    fn self_path(&mut self) {
        self.open(RustKind::Path);
        self.open(RustKind::PathSegment);
        self.wrap(RustKind::Ident);
        self.events.finish();
        self.events.finish();
    }

    fn identifier(&mut self) {
        let Some(kind) = self.current() else {
            return;
        };

        if !is_name(kind)
            && !matches!(
                kind,
                RustKind::CrateKeyword
                    | RustKind::SelfLower
                    | RustKind::SelfUpper
                    | RustKind::SuperKeyword
            )
        {
            return;
        }

        self.wrap(RustKind::Ident);
    }

    fn lifetime(&mut self) {
        self.lifetime_of(false);
    }

    fn lifetime_of(&mut self, doubled: bool) {
        if !self.at(RustKind::Apostrophe) {
            return;
        }

        if doubled {
            self.open(RustKind::Lifetime);
        }

        self.open(RustKind::Lifetime);
        self.bump();

        if doubled {
            self.open(RustKind::Ident);
        }

        self.wrap(RustKind::Ident);

        if doubled {
            self.events.finish();
        }

        self.events.finish();

        if doubled {
            self.events.finish();
        }
    }

    fn generics(&mut self) {
        if !self.at(RustKind::Less) {
            return;
        }

        self.open(RustKind::Generics);
        self.bump();

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if self.at(RustKind::Greater) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.generic_parameter();

            if !self.eat(RustKind::Comma) {
                break;
            }

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(RustKind::Greater);
        self.events.finish();
    }

    fn generic_parameter(&mut self) {
        let checkpoint = self.anchor();

        self.attributes();

        if self.at(RustKind::Apostrophe) {
            self.events.start_at(checkpoint, RustKind::LifetimeParam);
            self.lifetime();

            if self.eat(RustKind::Colon) {
                self.type_bounds();
            }

            self.events.finish();

            return;
        }

        if self.at(RustKind::ConstKeyword) {
            self.events.start_at(checkpoint, RustKind::ConstParam);
            self.bump();
            self.identifier();
            self.expect(RustKind::Colon, SyntaxErrorKind::ExpectedColon);
            self.type_of();

            if self.eat(RustKind::Equal) {
                self.expression_single();
            }

            self.events.finish();

            return;
        }

        self.events.start_at(checkpoint, RustKind::TypeParam);
        self.identifier();

        if self.eat(RustKind::Colon) {
            self.type_bounds();
        }

        if self.eat(RustKind::Equal) {
            self.type_of();
        }

        self.events.finish();
    }

    fn where_clause(&mut self) {
        if !self.at(RustKind::WhereKeyword) {
            return;
        }

        self.open(RustKind::WhereClause);
        self.bump();

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if matches!(
                self.current(),
                None | Some(RustKind::BraceOpen | RustKind::Semicolon | RustKind::Equal)
            ) {
                break;
            }

            let before = self.position;

            self.predicate();

            if !self.eat(RustKind::Comma) {
                break;
            }

            if self.position == before {
                self.emit();
            }
        }

        self.events.finish();
    }

    fn predicate(&mut self) {
        let checkpoint = self.anchor();

        if self.at(RustKind::Apostrophe) {
            self.events
                .start_at(checkpoint, RustKind::PredicateLifetime);

            self.lifetime();

            if self.eat(RustKind::Colon) {
                self.type_bounds();
            }

            self.events.finish();

            return;
        }

        self.events.start_at(checkpoint, RustKind::PredicateType);
        self.bound_lifetimes();
        self.type_of();
        self.expect(RustKind::Colon, SyntaxErrorKind::ExpectedColon);
        self.type_bounds();
        self.events.finish();
    }

    fn bound_lifetimes(&mut self) {
        if !self.at(RustKind::ForKeyword) {
            return;
        }

        self.open(RustKind::BoundLifetimes);
        self.bump();

        if self.at(RustKind::Less) {
            let end = self.balanced_generic(self.significant(self.position));

            self.bump();

            for _ in 0..CHAIN_DEPTH_MAX {
                self.skip_trivia();

                if self.position >= end || self.at(RustKind::Greater) || self.current().is_none() {
                    break;
                }

                let before = self.position;

                self.generic_parameter();

                if !self.eat(RustKind::Comma) {
                    break;
                }

                if self.position == before {
                    self.emit();
                }
            }

            let _ = self.eat(RustKind::Greater);
        }

        self.events.finish();
    }

    fn balanced_generic(&self, from: u32) -> u32 {
        let mut position = from;
        let mut depth = 0_u32;

        for _ in 0..SCAN_STEP_MAX {
            let Some(kind) = self.kind_at(position) else {
                return position;
            };

            if kind == RustKind::Less {
                depth += 1;
            }

            if kind == RustKind::Greater {
                depth -= 1;

                if depth == 0 {
                    return position + 1;
                }
            }

            if is_opener(kind) {
                position = self.balanced_end(position);

                continue;
            }

            position += 1;
        }

        position
    }

    fn type_bounds(&mut self) {
        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if self.at(RustKind::Apostrophe) {
                self.lifetime();
            } else if self.at(RustKind::UseKeyword) && self.ahead(1) == Some(RustKind::Less) {
                self.precise_capture();
            } else if self.at(RustKind::ParenOpen) {
                self.skip_group();
            } else {
                let checkpoint = self.anchor();
                let _ = self.eat(RustKind::Question);
                self.bound_lifetimes();

                if !opens_a_path(self.current().unwrap_or(RustKind::ErrorToken)) {
                    return;
                }

                self.events.start_at(checkpoint, RustKind::TraitBound);
                self.path(false);
                self.events.finish();
            }

            if !self.eat(RustKind::Plus) {
                return;
            }
        }
    }

    fn precise_capture(&mut self) {
        self.open(RustKind::PreciseCapture);
        self.bump();
        let _ = self.eat(RustKind::Less);

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if self.at(RustKind::Greater) || self.current().is_none() {
                break;
            }

            let before = self.position;

            if self.at(RustKind::Apostrophe) {
                self.lifetime();
            } else {
                self.identifier();
            }

            if !self.eat(RustKind::Comma) {
                break;
            }

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(RustKind::Greater);
        self.events.finish();
    }

    fn type_of(&mut self) {
        if !self.descend() {
            self.emit();

            return;
        }

        self.type_dispatch();
        self.ascend();
    }

    fn type_dispatch(&mut self) {
        let held = self.current();
        let kind = held.unwrap_or(RustKind::ErrorToken);

        match held {
            None => {}
            Some(RustKind::Ampersand) => {
                self.open(RustKind::TypeReference);
                self.bump();
                self.lifetime();
                let _ = self.eat(RustKind::MutKeyword);
                self.type_of();
                self.events.finish();
            }
            Some(RustKind::Star) => {
                self.open(RustKind::TypePtr);
                self.bump();
                let _ = self.eat(RustKind::ConstKeyword);
                let _ = self.eat(RustKind::MutKeyword);
                self.type_of();
                self.events.finish();
            }
            Some(RustKind::Bang) => self.wrap(RustKind::TypeNever),
            Some(RustKind::Underscore) => self.wrap(RustKind::TypeInfer),
            Some(RustKind::BracketOpen) => self.type_bracketed(),
            Some(RustKind::ParenOpen) => self.type_parenthesized(),
            Some(RustKind::ImplKeyword) => {
                self.open(RustKind::TypeImplTrait);
                self.bump();
                self.type_bounds();
                self.events.finish();
            }
            Some(RustKind::DynKeyword) => {
                self.open(RustKind::TypeTraitObject);
                self.bump();
                self.type_bounds();
                self.events.finish();
            }
            Some(RustKind::ForKeyword) => {
                let checkpoint = self.anchor();

                self.bound_lifetimes();

                if self.opens_a_bare_function() {
                    self.type_bare_function(checkpoint);

                    return;
                }

                self.events.start_at(checkpoint, RustKind::TypeTraitObject);
                self.type_bounds();
                self.events.finish();
            }
            Some(_) if self.opens_a_bare_function() => {
                let checkpoint = self.anchor();

                self.type_bare_function(checkpoint);
            }
            Some(_) if opens_a_path(kind) || kind == RustKind::Less => self.type_path(),
            Some(_) => {}
        }
    }

    fn opens_a_bare_function(&self) -> bool {
        let mut position = self.significant(self.position);

        for _ in 0..4 {
            let Some(kind) = self.kind_at(position) else {
                return false;
            };

            if kind == RustKind::FnKeyword {
                return true;
            }

            if !matches!(kind, RustKind::ExternKeyword | RustKind::UnsafeKeyword) {
                return false;
            }

            position = self.significant(position + 1);

            if self.kind_at(position) == Some(RustKind::StringLiteral) {
                position = self.significant(position + 1);
            }
        }

        false
    }

    fn type_bare_function(&mut self, checkpoint: Checkpoint) {
        self.events.start_at(checkpoint, RustKind::TypeBareFn);
        let _ = self.eat(RustKind::UnsafeKeyword);
        self.abi();
        self.expect(RustKind::FnKeyword, SyntaxErrorKind::UnexpectedToken);

        if self.eat(RustKind::ParenOpen) {
            for _ in 0..CHAIN_DEPTH_MAX {
                self.skip_trivia();

                if self.at(RustKind::ParenClose) || self.current().is_none() {
                    break;
                }

                let before = self.position;

                self.bare_argument();

                if !self.eat(RustKind::Comma) {
                    break;
                }

                if self.position == before {
                    self.emit();
                }
            }

            let _ = self.eat(RustKind::ParenClose);
        }

        if self.eat(RustKind::RArrow) {
            self.type_of();
        }

        self.events.finish();
    }

    fn bare_argument(&mut self) {
        let checkpoint = self.anchor();

        self.attributes();

        if self.at(RustKind::DotDotDot) {
            self.events.start_at(checkpoint, RustKind::BareVariadic);
            self.bump();
            self.events.finish();

            return;
        }

        self.events.start_at(checkpoint, RustKind::BareFnArg);

        if is_name(self.current().unwrap_or(RustKind::ErrorToken))
            && self.ahead(1) == Some(RustKind::Colon)
        {
            self.identifier();
            self.bump();
        }

        self.type_of();
        self.events.finish();
    }

    fn type_bracketed(&mut self) {
        let checkpoint = self.anchor();

        self.bump();
        self.type_of();

        if self.eat(RustKind::Semicolon) {
            self.expression_single();
            let _ = self.eat(RustKind::BracketClose);
            self.events.start_at(checkpoint, RustKind::TypeArray);
            self.events.finish();

            return;
        }

        let _ = self.eat(RustKind::BracketClose);
        self.events.start_at(checkpoint, RustKind::TypeSlice);
        self.events.finish();
    }

    fn type_parenthesized(&mut self) {
        let checkpoint = self.anchor();
        let mut elements = 0;
        let mut commas = 0;

        self.bump();

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if self.at(RustKind::ParenClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.type_of();
            elements += 1;

            if !self.eat(RustKind::Comma) {
                break;
            }

            commas += 1;

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(RustKind::ParenClose);

        let kind = if elements == 1 && commas == 0 {
            RustKind::TypeParen
        } else {
            RustKind::TypeTuple
        };

        self.events.start_at(checkpoint, kind);
        self.events.finish();
    }

    fn type_path(&mut self) {
        let checkpoint = self.anchor();

        if self.at(RustKind::Less) {
            self.qualified_path(false);
            self.events.start_at(checkpoint, RustKind::TypePath);
            self.events.finish();

            return;
        }

        if self.opens_a_macro_call() {
            let held = self.anchor();

            self.path(true);
            let _ = self.eat(RustKind::Bang);
            self.skip_group();
            self.events.start_at(held, RustKind::Macro);
            self.events.finish();
            self.events.start_at(checkpoint, RustKind::TypeMacro);
            self.events.finish();

            return;
        }

        self.path(false);

        self.events.start_at(checkpoint, RustKind::TypePath);
        self.events.finish();
    }

    fn qualified_path(&mut self, expression: bool) {
        self.bump();
        self.type_of();

        if self.eat(RustKind::AsKeyword) {
            self.open(RustKind::Path);
            let _ = self.eat(RustKind::ColonColon);
            self.path_segments(expression, true);
            self.events.finish();

            return;
        }

        let _ = self.eat(RustKind::Greater);
        self.path(expression);
    }

    fn path(&mut self, expression: bool) {
        self.open(RustKind::Path);
        let _ = self.eat(RustKind::ColonColon);
        self.path_segments(expression, false);
        self.events.finish();
    }

    fn path_segments(&mut self, expression: bool, qualified: bool) {
        let mut typed = qualified;

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            let Some(kind) = self.current() else {
                break;
            };

            if !is_name(kind)
                && !matches!(
                    kind,
                    RustKind::CrateKeyword
                        | RustKind::SelfLower
                        | RustKind::SelfUpper
                        | RustKind::SuperKeyword
                )
            {
                break;
            }

            self.open(RustKind::PathSegment);
            self.wrap(RustKind::Ident);

            match self.current().unwrap_or(RustKind::ErrorToken) {
                RustKind::Less if !expression || typed => self.generic_arguments(),
                RustKind::ParenOpen if !expression => self.parenthesized_arguments(),
                RustKind::ColonColon if self.ahead(1) == Some(RustKind::Less) => {
                    self.bump();
                    self.generic_arguments();
                }
                _ => {}
            }

            self.events.finish();

            if qualified && self.at(RustKind::Greater) {
                typed = false;

                self.bump();

                if !self.eat(RustKind::ColonColon) {
                    break;
                }

                continue;
            }

            if !self.at(RustKind::ColonColon) || self.ahead(1) == Some(RustKind::Less) {
                break;
            }

            self.bump();
        }
    }

    fn parenthesized_arguments(&mut self) {
        if !self.eat(RustKind::ParenOpen) {
            return;
        }

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if self.at(RustKind::ParenClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.type_of();

            if !self.eat(RustKind::Comma) {
                break;
            }

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(RustKind::ParenClose);

        if self.eat(RustKind::RArrow) {
            self.type_of();
        }
    }

    fn generic_arguments(&mut self) {
        if !self.eat(RustKind::Less) {
            return;
        }

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if self.at(RustKind::Greater) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.generic_argument();

            if !self.eat(RustKind::Comma) {
                break;
            }

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(RustKind::Greater);
    }

    fn generic_argument(&mut self) {
        if self.at(RustKind::Apostrophe) {
            self.lifetime();

            return;
        }

        if is_name(self.current().unwrap_or(RustKind::ErrorToken))
            && matches!(self.ahead(1), Some(RustKind::Equal | RustKind::Colon))
        {
            let checkpoint = self.anchor();
            let associated = self.ahead(1) == Some(RustKind::Equal);

            self.identifier();
            self.bump();

            if !associated {
                self.type_bounds();
                self.events.start_at(checkpoint, RustKind::Constraint);
                self.events.finish();

                return;
            }

            if self.constant_ahead() {
                self.constant_argument();
                self.events.start_at(checkpoint, RustKind::AssocConst);
                self.events.finish();

                return;
            }

            self.type_of();
            self.events.start_at(checkpoint, RustKind::AssocType);
            self.events.finish();

            return;
        }

        if self.constant_ahead() {
            self.constant_argument();

            return;
        }

        self.type_of();
    }

    fn constant_argument(&mut self) {
        let Some(kind) = self.current() else {
            return;
        };

        if kind == RustKind::BraceOpen || kind == RustKind::ConstKeyword {
            let checkpoint = self.anchor();

            self.block_expression_at(checkpoint);

            return;
        }

        self.literal_expression();
    }

    fn constant_ahead(&self) -> bool {
        let kind = self.current().unwrap_or(RustKind::ErrorToken);

        is_literal(kind)
            || matches!(kind, RustKind::BraceOpen | RustKind::Minus)
            || (kind == RustKind::ConstKeyword && self.ahead(1) == Some(RustKind::BraceOpen))
    }

    fn pattern(&mut self) {
        if !self.descend() {
            self.emit();

            return;
        }

        self.pattern_alternatives();
        self.ascend();
    }

    fn pattern_alternatives(&mut self) {
        let checkpoint = self.anchor();
        let _ = self.eat(RustKind::Or);
        self.pattern_single();

        if !self.at(RustKind::Or) {
            return;
        }

        for _ in 0..CHAIN_DEPTH_MAX {
            if !self.eat(RustKind::Or) {
                break;
            }

            self.pattern_single();
        }

        self.events.start_at(checkpoint, RustKind::PatOr);
        self.events.finish();
    }

    fn pattern_single(&mut self) {
        let held = self.current();
        let kind = held.unwrap_or(RustKind::ErrorToken);

        match held {
            None => {}
            Some(RustKind::Underscore) => self.wrap(RustKind::PatWild),
            Some(RustKind::DotDot) => self.wrap(RustKind::PatRest),
            Some(RustKind::Ampersand) => {
                self.open(RustKind::PatReference);
                self.bump();
                let _ = self.eat(RustKind::MutKeyword);
                self.pattern_single();
                self.events.finish();
            }
            Some(RustKind::BracketOpen) => self.pattern_slice(),
            Some(RustKind::ParenOpen) => self.pattern_tuple(Checkpoint::NONE),
            Some(RustKind::MutKeyword | RustKind::RefKeyword) => self.pattern_binding(),
            Some(_) if is_literal(kind) || kind == RustKind::Minus => self.pattern_literal(),
            Some(_) if opens_a_path(kind) || kind == RustKind::Less => self.pattern_path(),
            Some(_) => {}
        }
    }

    fn pattern_literal(&mut self) {
        let checkpoint = self.anchor();

        self.literal_expression();
        self.pattern_range(checkpoint);
    }

    fn pattern_range(&mut self, checkpoint: Checkpoint) {
        if !self.at(RustKind::DotDot) && !self.at(RustKind::DotDotEqual) {
            return;
        }

        self.bump();

        let Some(kind) = self.current() else {
            self.events.start_at(checkpoint, RustKind::ExprRange);
            self.events.finish();

            return;
        };

        if is_literal(kind) || kind == RustKind::Minus {
            self.literal_expression();
        }

        if opens_a_path(kind) {
            let held = self.anchor();

            self.path(true);
            self.events.start_at(held, RustKind::ExprPath);
            self.events.finish();
        }

        self.events.start_at(checkpoint, RustKind::ExprRange);
        self.events.finish();
    }

    fn pattern_binding(&mut self) {
        self.pattern_binding_of(false);
    }

    fn pattern_binding_of(&mut self, doubled: bool) {
        let checkpoint = self.anchor();
        let _ = self.eat(RustKind::RefKeyword);
        let _ = self.eat(RustKind::MutKeyword);

        if doubled {
            self.open(RustKind::Ident);
            self.identifier();
            self.events.finish();
        } else {
            self.identifier();
        }

        if self.eat(RustKind::At) {
            self.pattern_single();
        }

        self.events.start_at(checkpoint, RustKind::PatIdent);
        self.events.finish();
    }

    fn pattern_slice(&mut self) {
        self.open(RustKind::PatSlice);
        self.bump();

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if self.at(RustKind::BracketClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.pattern();

            if !self.eat(RustKind::Comma) {
                break;
            }

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(RustKind::BracketClose);
        self.events.finish();
    }

    fn pattern_tuple(&mut self, checkpoint: Checkpoint) {
        let held = if checkpoint.is_none() {
            self.anchor()
        } else {
            checkpoint
        };

        let mut elements = 0;
        let mut commas = 0;

        self.bump();

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if self.at(RustKind::ParenClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.pattern();
            elements += 1;

            if !self.eat(RustKind::Comma) {
                break;
            }

            commas += 1;

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(RustKind::ParenClose);

        if !checkpoint.is_none() {
            self.events.start_at(held, RustKind::PatTupleStruct);
            self.events.finish();

            return;
        }

        let kind = if elements == 1 && commas == 0 {
            RustKind::PatParen
        } else {
            RustKind::PatTuple
        };

        self.events.start_at(held, kind);
        self.events.finish();
    }

    fn pattern_path(&mut self) {
        let checkpoint = self.anchor();

        if is_name(self.current().unwrap_or(RustKind::ErrorToken))
            && !matches!(
                self.ahead(1),
                Some(
                    RustKind::BraceOpen
                        | RustKind::ColonColon
                        | RustKind::DotDot
                        | RustKind::DotDotEqual
                        | RustKind::ParenOpen
                )
            )
        {
            self.pattern_binding();

            return;
        }

        if self.at(RustKind::Less) {
            self.qualified_path(true);
            self.events.start_at(checkpoint, RustKind::ExprPath);
            self.events.finish();

            return;
        }

        if self.opens_a_macro_call() {
            let held = self.anchor();

            self.path(true);
            let _ = self.eat(RustKind::Bang);
            self.skip_group();
            self.events.start_at(held, RustKind::Macro);
            self.events.finish();
            self.events.start_at(checkpoint, RustKind::ExprMacro);
            self.events.finish();

            return;
        }

        self.path(true);

        if self.at(RustKind::ParenOpen) {
            self.pattern_tuple(checkpoint);

            return;
        }

        if self.at(RustKind::BraceOpen) {
            self.pattern_struct(checkpoint);

            return;
        }

        self.events.start_at(checkpoint, RustKind::ExprPath);
        self.events.finish();
        self.pattern_range(checkpoint);
    }

    fn pattern_struct(&mut self, checkpoint: Checkpoint) {
        self.bump();

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if self.at(RustKind::BraceClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            if self.at(RustKind::DotDot) {
                self.wrap(RustKind::PatRest);
            } else {
                self.field_pattern();
            }

            if !self.eat(RustKind::Comma) {
                break;
            }

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(RustKind::BraceClose);
        self.events.start_at(checkpoint, RustKind::PatStruct);
        self.events.finish();
    }

    fn field_pattern(&mut self) {
        let checkpoint = self.anchor();

        self.attributes();

        let named = matches!(self.ahead(1), Some(RustKind::Colon));

        if named {
            if self.at(RustKind::Number) {
                self.wrap(RustKind::Index);
            } else {
                self.identifier();
            }

            self.bump();
            self.pattern();
        } else {
            self.pattern_binding_of(true);
        }

        self.events.start_at(checkpoint, RustKind::FieldPat);
        self.events.finish();
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
        self.open(RustKind::Block);
        self.expect(RustKind::BraceOpen, SyntaxErrorKind::UnexpectedToken);
        self.inner_attributes();

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if self.at(RustKind::BraceClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.statement();

            if self.position == before {
                self.record(SyntaxErrorKind::UnexpectedToken);
                self.emit();
            }
        }

        let _ = self.eat(RustKind::BraceClose);
        self.events.finish();
    }

    fn statement(&mut self) {
        if self.eat(RustKind::Semicolon) {
            return;
        }

        if self.current().is_none() {
            return;
        }

        if self.opens_a_statement_item() {
            self.item();

            return;
        }

        if self.opens_a_statement_macro() {
            let checkpoint = self.anchor();

            self.attributes();
            self.member_macro(checkpoint, RustKind::StmtMacro);

            return;
        }

        let checkpoint = self.anchor();

        self.attributes();

        if self.at(RustKind::LetKeyword) {
            self.local(checkpoint);

            return;
        }

        if is_block_like(self.current().unwrap_or(RustKind::ErrorToken)) {
            let held = self.anchor();

            self.block_expression_at(held);

            if matches!(self.current(), Some(RustKind::Dot | RustKind::Question)) {
                self.expression_continued(held);
            }

            let _ = self.eat(RustKind::Semicolon);

            return;
        }

        self.expression();
        let _ = self.eat(RustKind::Semicolon);
    }

    fn attribute_end(&self) -> u32 {
        let mut position = self.significant(self.position);

        for _ in 0..CHAIN_DEPTH_MAX {
            if self.kind_at(position) != Some(RustKind::Pound) {
                break;
            }

            let mut after = self.significant(position + 1);

            if self.kind_at(after) == Some(RustKind::Bang) {
                after = self.significant(after + 1);
            }

            if self.kind_at(after) != Some(RustKind::BracketOpen) {
                break;
            }

            position = self.significant(self.balanced_end(after));
        }

        position
    }

    fn opens_a_statement_item(&self) -> bool {
        let position = self.attribute_end();

        if self.kind_at(position) == Some(RustKind::PubKeyword) {
            return true;
        }

        let Some(kind) = self.kind_at(position) else {
            return false;
        };

        if matches!(
            kind,
            RustKind::EnumKeyword
                | RustKind::ImplKeyword
                | RustKind::ModKeyword
                | RustKind::StaticKeyword
                | RustKind::StructKeyword
                | RustKind::TraitKeyword
                | RustKind::TypeKeyword
                | RustKind::UseKeyword
        ) {
            return true;
        }

        if kind == RustKind::UnsafeKeyword
            && matches!(
                self.kind_at(self.significant(position + 1)),
                Some(RustKind::ImplKeyword | RustKind::TraitKeyword)
            )
        {
            return true;
        }

        if kind == RustKind::ConstKeyword
            && matches!(
                self.kind_at(self.significant(position + 1)),
                Some(RustKind::Identifier | RustKind::Underscore)
            )
            && self.kind_at(self.significant(position + 2)) == Some(RustKind::Colon)
        {
            return true;
        }

        if kind == RustKind::UnionKeyword
            && is_name(
                self.kind_at(self.significant(position + 1))
                    .unwrap_or(RustKind::ErrorToken),
            )
        {
            return true;
        }

        if kind == RustKind::MacroKeyword {
            return true;
        }

        if self.names_a_macro(position) {
            return true;
        }

        if kind == RustKind::ExternKeyword
            && self.kind_at(self.significant(position + 1)) == Some(RustKind::CrateKeyword)
        {
            return true;
        }

        if self.opens_a_foreign_module(position) {
            return true;
        }

        self.function_at(position)
    }

    fn names_a_macro(&self, from: u32) -> bool {
        let mut position = from;

        if !opens_a_path(self.kind_at(position).unwrap_or(RustKind::ErrorToken)) {
            return false;
        }

        for _ in 0..CHAIN_DEPTH_MAX {
            let Some(kind) = self.kind_at(position) else {
                return false;
            };

            if kind == RustKind::Bang {
                break;
            }

            if !is_name(kind)
                && !matches!(
                    kind,
                    RustKind::ColonColon
                        | RustKind::CrateKeyword
                        | RustKind::SelfLower
                        | RustKind::SelfUpper
                        | RustKind::SuperKeyword
                )
            {
                return false;
            }

            position = self.significant(position + 1);
        }

        if self.kind_at(position) != Some(RustKind::Bang) {
            return false;
        }

        is_name(
            self.kind_at(self.significant(position + 1))
                .unwrap_or(RustKind::ErrorToken),
        )
    }

    fn function_at(&self, from: u32) -> bool {
        let mut position = from;

        for _ in 0..8 {
            let Some(kind) = self.kind_at(position) else {
                return false;
            };

            if kind == RustKind::FnKeyword {
                return true;
            }

            if !matches!(
                kind,
                RustKind::AsyncKeyword
                    | RustKind::ConstKeyword
                    | RustKind::ExternKeyword
                    | RustKind::UnsafeKeyword
            ) {
                return false;
            }

            if kind == RustKind::UnsafeKeyword
                && self.kind_at(self.significant(position + 1)) == Some(RustKind::BraceOpen)
            {
                return false;
            }

            if kind == RustKind::ConstKeyword
                && self.kind_at(self.significant(position + 1)) != Some(RustKind::FnKeyword)
            {
                return false;
            }

            if kind == RustKind::AsyncKeyword
                && self.kind_at(self.significant(position + 1)) == Some(RustKind::BraceOpen)
            {
                return false;
            }

            position = self.significant(position + 1);

            if self.kind_at(position) == Some(RustKind::StringLiteral) {
                position = self.significant(position + 1);
            }
        }

        false
    }

    fn opens_a_statement_macro(&self) -> bool {
        let mut position = self.attribute_end();

        if !opens_a_path(self.kind_at(position).unwrap_or(RustKind::ErrorToken)) {
            return false;
        }

        for _ in 0..CHAIN_DEPTH_MAX {
            let Some(kind) = self.kind_at(position) else {
                return false;
            };

            if kind == RustKind::Bang {
                break;
            }

            if !is_name(kind)
                && !matches!(
                    kind,
                    RustKind::ColonColon
                        | RustKind::CrateKeyword
                        | RustKind::SelfLower
                        | RustKind::SelfUpper
                        | RustKind::SuperKeyword
                )
            {
                return false;
            }

            position = self.significant(position + 1);
        }

        if self.kind_at(position) != Some(RustKind::Bang) {
            return false;
        }

        position = self.significant(position + 1);

        if is_name(self.kind_at(position).unwrap_or(RustKind::ErrorToken)) {
            position = self.significant(position + 1);
        }

        if self.kind_at(position) == Some(RustKind::BraceOpen) {
            return true;
        }

        if !is_opener(self.kind_at(position).unwrap_or(RustKind::ErrorToken)) {
            return false;
        }

        let after = self.significant(self.balanced_end(position));

        self.kind_at(after) == Some(RustKind::Semicolon)
    }

    fn local(&mut self, checkpoint: Checkpoint) {
        self.events.start_at(checkpoint, RustKind::Local);
        self.bump();

        let held = self.anchor();

        self.pattern();

        if self.eat(RustKind::Colon) {
            self.type_of();
            self.events.start_at(held, RustKind::PatType);
            self.events.finish();
        }

        if self.eat(RustKind::Equal) {
            self.expression_single();

            if self.eat(RustKind::ElseKeyword) {
                let diverge = self.anchor();

                self.block();
                self.events.start_at(diverge, RustKind::ExprBlock);
                self.events.finish();
            }
        }

        let _ = self.eat(RustKind::Semicolon);
        self.events.finish();
    }

    fn literal_expression(&mut self) {
        let checkpoint = self.anchor();

        if !self.at(RustKind::Minus) {
            self.literal_node();

            return;
        }

        self.bump();

        let Some(kind) = self.current() else {
            return;
        };

        let held = self.literal_at(kind, self.significant(self.position));

        self.bump();
        self.events.start_at(checkpoint, held);
        self.events.finish();
        self.events.start_at(checkpoint, RustKind::ExprLit);
        self.events.finish();
    }

    fn expression(&mut self) {
        self.expression_with(true);
    }

    fn expression_single(&mut self) {
        self.expression_with(true);
    }

    fn expression_no_struct(&mut self) {
        self.expression_with(false);
    }

    fn expression_with(&mut self, structures: bool) {
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
            stage: u8::from(structures),
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

    fn expression_continued(&mut self, checkpoint: Checkpoint) {
        if !self.descend() {
            return;
        }

        let frames_base = self.frame_count;
        let values_base = self.value_count;

        let frame = Frame {
            checkpoint,
            content: checkpoint,
            element_values: self.value_count,
            stage: 1,
            values: self.value_count,
            variant: Variant::Top,
            ..Frame::EMPTY
        };

        if self.push_frame(frame) {
            self.push_value(checkpoint);
            self.machine_from(frames_base, false);
            self.reduce_above(frames_base + 1);
            self.frame_count = frames_base;
            self.value_count = values_base;
        }

        self.ascend();
    }

    fn structures(&self, base: u32) -> bool {
        let group = self.innermost_group(base);

        if self.frames[group as usize].variant != Variant::Top {
            return true;
        }

        self.frames[group as usize].stage == 1
    }

    fn machine(&mut self, base: u32) {
        self.machine_from(base, true);
    }

    fn machine_from(&mut self, base: u32, start: bool) {
        let mut operand = start;

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

    fn unary(&mut self, kind: RustKind, power: u8) -> Step {
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

    fn binary(&mut self, kind: RustKind, left: u8, right: u8, steps: u32) -> Step {
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

        for _ in 0..steps {
            self.bump();
        }

        Step::Operand
    }

    fn open_group(&mut self, variant: Variant, checkpoint: Checkpoint) -> Step {
        let opener = self.current().unwrap_or(RustKind::ParenOpen);
        let bracket = self.anchor();

        self.bump();

        let content = self.anchor();

        let closer = if opener == RustKind::BracketOpen {
            RustKind::BracketClose
        } else if opener == RustKind::BraceOpen {
            RustKind::BraceClose
        } else {
            RustKind::ParenClose
        };

        let frame = Frame {
            bracket,
            checkpoint,
            closer,
            content,
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
        let seen = self.value_count - frame.values;

        self.frame_count = group;

        let kind = if frame.variant == Variant::Paren {
            if seen == 1 && frame.elements == 0 {
                RustKind::ExprParen
            } else {
                RustKind::ExprTuple
            }
        } else if frame.variant == Variant::Array && frame.stage == 1 {
            RustKind::ExprRepeat
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

        let Some(kind) = self.current() else {
            return Step::Done;
        };

        let group = self.innermost_group(base);

        if self.frames[group as usize].variant == Variant::Struct
            && self.frame_count == group + 1
            && self.frames[group as usize].stage == 0
            && self.value_count == self.frames[group as usize].element_values
        {
            return self.struct_field(group);
        }

        self.operand_of(kind, base)
    }

    fn struct_field(&mut self, group: u32) -> Step {
        let checkpoint = self.anchor();

        self.attributes();

        if self.at(RustKind::DotDot) {
            self.frames[group as usize].stage = 2;
            self.bump();

            return Step::Operand;
        }

        let named = matches!(self.ahead(1), Some(RustKind::Colon))
            && self.ahead(2) != Some(RustKind::Colon);

        if !named {
            return self.struct_shorthand(group, checkpoint);
        }

        if self.at(RustKind::Number) {
            self.wrap(RustKind::Index);
        } else {
            self.wrap(RustKind::Ident);
        }

        self.bump();

        let frame = Frame {
            checkpoint,
            kind: RustKind::FieldValue,
            power: POWER_BARRIER,
            values: self.value_count,
            variant: Variant::Binary,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        Step::Operand
    }

    fn struct_shorthand(&mut self, group: u32, checkpoint: Checkpoint) -> Step {
        let shorthand = is_name(self.current().unwrap_or(RustKind::ErrorToken))
            && matches!(
                self.ahead(1),
                None | Some(RustKind::BraceClose | RustKind::Comma)
            );

        if !shorthand {
            return self.operand_of(
                self.current().unwrap_or(RustKind::ErrorToken),
                self.innermost_group(group),
            );
        }

        let held = self.anchor();

        self.open(RustKind::Path);
        self.open(RustKind::PathSegment);
        self.open(RustKind::Ident);
        self.wrap(RustKind::Ident);
        self.events.finish();
        self.events.finish();
        self.events.finish();
        self.events.start_at(held, RustKind::ExprPath);
        self.events.finish();
        self.events.start_at(checkpoint, RustKind::FieldValue);
        self.events.finish();
        self.push_value(checkpoint);

        Step::Operator
    }

    fn operand_of(&mut self, kind: RustKind, base: u32) -> Step {
        match Some(kind) {
            None => Step::Done,
            Some(RustKind::Pound) => {
                self.attributes();

                Step::Operand
            }
            Some(RustKind::Minus | RustKind::Bang | RustKind::Star) => {
                self.unary(RustKind::ExprUnary, POWER_UNARY)
            }
            Some(RustKind::Ampersand) => self.reference(),
            Some(RustKind::DotDot | RustKind::DotDotEqual) => self.range_prefix(),
            Some(RustKind::Underscore) => {
                let checkpoint = self.anchor();

                self.wrap(RustKind::ExprInfer);
                self.push_value(checkpoint);

                Step::Operator
            }
            Some(RustKind::LetKeyword) => self.let_operand(),
            Some(RustKind::ReturnKeyword) => self.jump(RustKind::ExprReturn, false),
            Some(RustKind::BreakKeyword) => self.jump(RustKind::ExprBreak, true),
            Some(RustKind::ContinueKeyword) => self.jump(RustKind::ExprContinue, true),
            Some(RustKind::YieldKeyword) => self.jump(RustKind::ExprYield, false),
            Some(RustKind::MoveKeyword | RustKind::Or | RustKind::OrOr) => self.closure(),
            Some(RustKind::Apostrophe) => self.labelled(),
            Some(RustKind::ParenOpen) => {
                let checkpoint = self.anchor();

                self.open_group(Variant::Paren, checkpoint)
            }
            Some(RustKind::BracketOpen) => {
                let checkpoint = self.anchor();

                self.open_group(Variant::Array, checkpoint)
            }
            Some(_) if is_block_like(kind) => {
                let checkpoint = self.anchor();

                self.block_expression();
                self.push_value(checkpoint);

                Step::Operator
            }
            Some(_) if is_literal(kind) => {
                let checkpoint = self.anchor();

                self.literal_node();
                self.push_value(checkpoint);

                Step::Operator
            }
            Some(_) if opens_a_path(kind) || kind == RustKind::Less => self.path_operand(base),
            Some(_) => Step::Done,
        }
    }

    fn literal_node(&mut self) {
        let checkpoint = self.anchor();

        let Some(kind) = self.current() else {
            return;
        };

        let held = self.literal_at(kind, self.significant(self.position));

        self.wrap(held);
        self.events.start_at(checkpoint, RustKind::ExprLit);
        self.events.finish();
    }

    fn literal_at(&self, kind: RustKind, position: u32) -> RustKind {
        let held = literal_kind(kind).unwrap_or(RustKind::LitInt);

        if held != RustKind::LitInt {
            return held;
        }

        let Some(token) = self.tokens.get(position as usize) else {
            return held;
        };

        let bytes = token.text(self.source);
        let radix = bytes.get(..2).unwrap_or_default();

        if radix.eq_ignore_ascii_case(b"0x")
            || radix.eq_ignore_ascii_case(b"0o")
            || radix.eq_ignore_ascii_case(b"0b")
        {
            return RustKind::LitInt;
        }

        if bytes.contains(&b'.') {
            return RustKind::LitFloat;
        }

        for offset in 1..bytes.len() {
            if !bytes[offset].eq_ignore_ascii_case(&b'e') {
                continue;
            }

            let mut after = offset + 1;

            if matches!(bytes.get(after), Some(&b'+' | &b'-')) {
                after += 1;
            }

            if bytes.get(after).is_some_and(u8::is_ascii_digit) {
                return RustKind::LitFloat;
            }
        }

        RustKind::LitInt
    }

    fn let_operand(&mut self) -> Step {
        let checkpoint = self.anchor();

        self.bump();
        self.pattern();
        let _ = self.eat(RustKind::Equal);

        let frame = Frame {
            checkpoint,
            kind: RustKind::ExprLet,
            power: POWER_COMPARE_LEFT,
            values: self.value_count,
            variant: Variant::Unary,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        Step::Operand
    }

    fn reference(&mut self) -> Step {
        let checkpoint = self.anchor();

        if self.word_at(self.ahead_position(1), b"raw")
            && matches!(
                self.ahead(2),
                Some(RustKind::ConstKeyword | RustKind::MutKeyword)
            )
        {
            let frame = Frame {
                checkpoint,
                kind: RustKind::ExprRawAddr,
                power: POWER_UNARY,
                values: self.value_count,
                variant: Variant::Unary,
                ..Frame::EMPTY
            };

            if !self.push_frame(frame) {
                return Step::Done;
            }

            self.bump();
            self.bump();
            let _ = self.eat(RustKind::ConstKeyword);
            let _ = self.eat(RustKind::MutKeyword);

            return Step::Operand;
        }

        let frame = Frame {
            checkpoint,
            kind: RustKind::ExprReference,
            power: POWER_UNARY,
            values: self.value_count,
            variant: Variant::Unary,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        self.bump();
        let _ = self.eat(RustKind::MutKeyword);

        Step::Operand
    }

    fn range_prefix(&mut self) -> Step {
        let checkpoint = self.anchor();

        self.bump();

        if !self.opens_an_expression() {
            self.events.start_at(checkpoint, RustKind::ExprRange);
            self.events.finish();
            self.push_value(checkpoint);

            return Step::Operator;
        }

        let frame = Frame {
            checkpoint,
            kind: RustKind::ExprRange,
            power: POWER_RANGE_RIGHT,
            values: self.value_count,
            variant: Variant::Unary,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        Step::Operand
    }

    fn opens_an_expression(&self) -> bool {
        let Some(kind) = self.current() else {
            return false;
        };

        is_literal(kind)
            || opens_a_path(kind)
            || is_block_like(kind)
            || matches!(
                kind,
                RustKind::Ampersand
                    | RustKind::Apostrophe
                    | RustKind::Bang
                    | RustKind::BracketOpen
                    | RustKind::BreakKeyword
                    | RustKind::ContinueKeyword
                    | RustKind::Less
                    | RustKind::Minus
                    | RustKind::MoveKeyword
                    | RustKind::Or
                    | RustKind::OrOr
                    | RustKind::ParenOpen
                    | RustKind::ReturnKeyword
                    | RustKind::Star
                    | RustKind::Underscore
                    | RustKind::YieldKeyword
            )
    }

    fn jump(&mut self, kind: RustKind, labelled: bool) -> Step {
        let checkpoint = self.anchor();

        self.bump();

        if labelled {
            self.lifetime();
        }

        if !self.opens_an_expression() {
            self.events.start_at(checkpoint, kind);
            self.events.finish();
            self.push_value(checkpoint);

            return Step::Operator;
        }

        let frame = Frame {
            checkpoint,
            kind,
            power: POWER_ASSIGN_RIGHT,
            values: self.value_count,
            variant: Variant::Unary,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        Step::Operand
    }

    fn closure(&mut self) -> Step {
        let checkpoint = self.anchor();
        let _ = self.eat(RustKind::MoveKeyword);

        if self.eat(RustKind::OrOr) {
            return self.closure_body(checkpoint);
        }

        let _ = self.eat(RustKind::Or);

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if self.at(RustKind::Or) || self.current().is_none() {
                break;
            }

            let before = self.position;
            let held = self.anchor();

            self.pattern_single();

            if self.eat(RustKind::Colon) {
                self.type_of();
                self.events.start_at(held, RustKind::PatType);
                self.events.finish();
            }

            if !self.eat(RustKind::Comma) {
                break;
            }

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(RustKind::Or);
        self.closure_body(checkpoint)
    }

    fn closure_body(&mut self, checkpoint: Checkpoint) -> Step {
        if self.eat(RustKind::RArrow) {
            self.type_of();
            self.block_expression();
            self.events.start_at(checkpoint, RustKind::ExprClosure);
            self.events.finish();
            self.push_value(checkpoint);

            return Step::Operator;
        }

        let frame = Frame {
            checkpoint,
            kind: RustKind::ExprClosure,
            power: POWER_ASSIGN_RIGHT,
            values: self.value_count,
            variant: Variant::Unary,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        Step::Operand
    }

    fn labelled(&mut self) -> Step {
        let checkpoint = self.anchor();

        self.open(RustKind::Label);
        self.lifetime();
        let _ = self.eat(RustKind::Colon);
        self.events.finish();
        self.block_expression_at(checkpoint);
        self.push_value(checkpoint);

        Step::Operator
    }

    fn block_expression(&mut self) {
        let checkpoint = self.anchor();

        self.block_expression_at(checkpoint);
    }

    fn block_expression_at(&mut self, checkpoint: Checkpoint) {
        match self.current() {
            None => {}
            Some(RustKind::IfKeyword) => self.if_expression(checkpoint),
            Some(RustKind::MatchKeyword) => self.match_expression(checkpoint),
            Some(RustKind::LoopKeyword) => {
                self.bump();
                self.block();
                self.events.start_at(checkpoint, RustKind::ExprLoop);
                self.events.finish();
            }
            Some(RustKind::WhileKeyword) => {
                self.bump();
                self.condition();
                self.block();
                self.events.start_at(checkpoint, RustKind::ExprWhile);
                self.events.finish();
            }
            Some(RustKind::ForKeyword) => {
                self.bump();
                self.pattern();
                let _ = self.eat(RustKind::InKeyword);
                self.expression_no_struct();
                self.block();
                self.events.start_at(checkpoint, RustKind::ExprForLoop);
                self.events.finish();
            }
            Some(RustKind::UnsafeKeyword) => {
                self.bump();
                self.block();
                self.events.start_at(checkpoint, RustKind::ExprUnsafe);
                self.events.finish();
            }
            Some(RustKind::AsyncKeyword) => {
                self.bump();
                let _ = self.eat(RustKind::MoveKeyword);
                self.block();
                self.events.start_at(checkpoint, RustKind::ExprAsync);
                self.events.finish();
            }
            Some(RustKind::ConstKeyword) => {
                self.bump();
                self.block();
                self.events.start_at(checkpoint, RustKind::ExprConst);
                self.events.finish();
            }
            Some(RustKind::TryKeyword) => {
                self.bump();
                self.block();
                self.events.start_at(checkpoint, RustKind::ExprTryBlock);
                self.events.finish();
            }
            Some(RustKind::BraceOpen) => {
                self.block();
                self.events.start_at(checkpoint, RustKind::ExprBlock);
                self.events.finish();
            }
            Some(_) => {}
        }
    }

    fn condition(&mut self) {
        self.expression_no_struct();
    }

    fn if_expression(&mut self, checkpoint: Checkpoint) {
        self.bump();
        self.condition();
        self.block();

        if self.eat(RustKind::ElseKeyword) {
            if self.at(RustKind::IfKeyword) {
                if !self.descend() {
                    self.events.start_at(checkpoint, RustKind::ExprIf);
                    self.events.finish();

                    return;
                }

                let held = self.anchor();

                self.if_expression(held);
                self.ascend();
            } else {
                let held = self.anchor();

                self.block();
                self.events.start_at(held, RustKind::ExprBlock);
                self.events.finish();
            }
        }

        self.events.start_at(checkpoint, RustKind::ExprIf);
        self.events.finish();
    }

    fn match_expression(&mut self, checkpoint: Checkpoint) {
        self.bump();
        self.expression_no_struct();
        self.expect(RustKind::BraceOpen, SyntaxErrorKind::UnexpectedToken);

        for _ in 0..CHAIN_DEPTH_MAX {
            self.skip_trivia();

            if self.at(RustKind::BraceClose) || self.current().is_none() {
                break;
            }

            let before = self.position;

            self.arm();

            if self.position == before {
                self.emit();
            }
        }

        let _ = self.eat(RustKind::BraceClose);
        self.events.start_at(checkpoint, RustKind::ExprMatch);
        self.events.finish();
    }

    fn arm(&mut self) {
        let checkpoint = self.anchor();

        self.attributes();
        self.pattern();

        if self.eat(RustKind::IfKeyword) {
            self.expression();
        }

        let _ = self.eat(RustKind::FatArrow);

        if is_block_like(self.current().unwrap_or(RustKind::ErrorToken)) {
            let held = self.anchor();

            self.block_expression_at(held);

            if matches!(self.current(), Some(RustKind::Dot | RustKind::Question)) {
                self.expression_continued(held);
            }
        } else {
            self.expression();
        }

        let _ = self.eat(RustKind::Comma);
        self.events.start_at(checkpoint, RustKind::Arm);
        self.events.finish();
    }

    fn path_operand(&mut self, base: u32) -> Step {
        let checkpoint = self.anchor();

        if self.at(RustKind::Less) {
            self.qualified_path(true);
            self.events.start_at(checkpoint, RustKind::ExprPath);
            self.events.finish();
            self.push_value(checkpoint);

            return Step::Operator;
        }

        if self.opens_a_macro_call() {
            let held = self.anchor();

            self.path(true);
            let _ = self.eat(RustKind::Bang);
            self.skip_group();
            self.events.start_at(held, RustKind::Macro);
            self.events.finish();
            self.events.start_at(checkpoint, RustKind::ExprMacro);
            self.events.finish();
            self.push_value(checkpoint);

            return Step::Operator;
        }

        self.path(true);

        if self.at(RustKind::BraceOpen) && self.structures(base) {
            return self.open_group(Variant::Struct, checkpoint);
        }

        self.events.start_at(checkpoint, RustKind::ExprPath);
        self.events.finish();
        self.push_value(checkpoint);

        Step::Operator
    }

    fn operator_step(&mut self, base: u32) -> Step {
        self.skip_trivia();

        let Some(kind) = self.current() else {
            return Step::Done;
        };

        let group = self.innermost_group(base);
        let frame = self.frames[group as usize];

        if frame.is_bracketed() && kind == frame.closer {
            self.close_group(group);

            return Step::Operator;
        }

        if kind == RustKind::Comma {
            return self.comma(group);
        }

        if kind == RustKind::Semicolon && frame.variant == Variant::Array {
            self.frames[group as usize].stage = 1;
            self.bump();

            return Step::Operand;
        }

        if kind == RustKind::Dot {
            return self.member_trailer();
        }

        if kind == RustKind::ParenOpen {
            return self.trailer(Variant::Call);
        }

        if kind == RustKind::BracketOpen {
            return self.trailer(Variant::Subscript);
        }

        if kind == RustKind::Question {
            return self.postfix(RustKind::ExprTry);
        }

        if kind == RustKind::AsKeyword {
            return self.cast();
        }

        if matches!(kind, RustKind::DotDot | RustKind::DotDotEqual) {
            return self.range_infix();
        }

        self.operator_of(kind)
    }

    fn operator_of(&mut self, kind: RustKind) -> Step {
        if self.joined(RustKind::Ampersand) {
            return self.binary(RustKind::ExprBinary, POWER_AND_LEFT, POWER_AND_RIGHT, 2);
        }

        if self.joined(RustKind::Less) {
            return self.binary(RustKind::ExprBinary, POWER_SHIFT_LEFT, POWER_SHIFT_RIGHT, 2);
        }

        if self.joined(RustKind::Greater) {
            return self.binary(RustKind::ExprBinary, POWER_SHIFT_LEFT, POWER_SHIFT_RIGHT, 2);
        }

        if matches!(kind, RustKind::Less | RustKind::Greater) {
            return self.binary(
                RustKind::ExprBinary,
                POWER_COMPARE_LEFT,
                POWER_COMPARE_LEFT + 1,
                1,
            );
        }

        if matches!(kind, RustKind::LessEqual | RustKind::GreaterEqual) {
            return self.binary(
                RustKind::ExprBinary,
                POWER_COMPARE_LEFT,
                POWER_COMPARE_LEFT + 1,
                1,
            );
        }

        if matches!(
            kind,
            RustKind::LessLessEqual | RustKind::GreaterGreaterEqual
        ) {
            return self.binary(
                RustKind::ExprBinary,
                POWER_ASSIGN_RIGHT + 1,
                POWER_ASSIGN_RIGHT,
                1,
            );
        }

        if let Some((node, left, right)) = infix_of(kind) {
            return self.binary(node, left, right, 1);
        }

        Step::Done
    }

    fn comma(&mut self, group: u32) -> Step {
        let frame = self.frames[group as usize];

        if frame.variant == Variant::Top {
            return Step::Done;
        }

        self.reduce_above(group + 1);
        self.bump();
        self.frames[group as usize].elements += 1;
        self.frames[group as usize].element_values = self.value_count;

        Step::Operand
    }

    fn postfix(&mut self, kind: RustKind) -> Step {
        if self.value_count == 0 {
            return Step::Done;
        }

        let checkpoint = self.values[self.value_count as usize - 1];

        self.events.start_at(checkpoint, kind);
        self.bump();
        self.events.finish();

        Step::Operator
    }

    fn cast(&mut self) -> Step {
        self.reduce_for(POWER_CAST);

        if self.value_count == 0 {
            return Step::Done;
        }

        let checkpoint = self.values[self.value_count as usize - 1];

        self.events.start_at(checkpoint, RustKind::ExprCast);
        self.bump();
        self.type_of();
        self.events.finish();

        Step::Operator
    }

    fn range_infix(&mut self) -> Step {
        self.reduce_for(POWER_RANGE_LEFT);

        if self.value_count == 0 {
            return Step::Done;
        }

        let checkpoint = self.values[self.value_count as usize - 1];

        self.bump();

        if !self.opens_an_expression() {
            self.events.start_at(checkpoint, RustKind::ExprRange);
            self.events.finish();

            return Step::Operator;
        }

        let values = self.value_count - 1;

        let frame = Frame {
            checkpoint,
            kind: RustKind::ExprRange,
            power: POWER_RANGE_RIGHT,
            values,
            variant: Variant::Binary,
            ..Frame::EMPTY
        };

        if !self.push_frame(frame) {
            return Step::Done;
        }

        Step::Operand
    }

    fn trailer(&mut self, variant: Variant) -> Step {
        if self.value_count == 0 {
            return Step::Done;
        }

        let checkpoint = self.values[self.value_count as usize - 1];

        self.value_count -= 1;

        self.open_group(variant, checkpoint)
    }

    fn member_trailer(&mut self) -> Step {
        if self.value_count == 0 {
            return Step::Done;
        }

        let checkpoint = self.values[self.value_count as usize - 1];

        if self.ahead(1) == Some(RustKind::AwaitKeyword) {
            self.events.start_at(checkpoint, RustKind::ExprAwait);
            self.bump();
            self.bump();
            self.events.finish();

            return Step::Operator;
        }

        let method = matches!(
            self.ahead(2),
            Some(RustKind::ParenOpen | RustKind::ColonColon)
        ) && is_name(self.ahead(1).unwrap_or(RustKind::ErrorToken));

        if !method {
            self.events.start_at(checkpoint, RustKind::ExprField);
            self.bump();

            match self.current().unwrap_or(RustKind::ErrorToken) {
                RustKind::Number => self.wrap(RustKind::Index),
                current if is_name(current) => self.wrap(RustKind::Ident),
                _ => {}
            }

            self.events.finish();

            return Step::Operator;
        }

        self.value_count -= 1;
        self.bump();
        self.wrap(RustKind::Ident);

        if self.at(RustKind::ColonColon) {
            self.bump();
            self.generic_arguments();
        }

        let _ = self.open_group(Variant::Call, checkpoint);
        self.frames[self.frame_count as usize - 1].kind = RustKind::ExprMethodCall;

        Step::Operand
    }
}

pub fn build(
    source: &[u8],
    tokens: &[Token],
    raw: &[RustKind],
    events: &mut Events<RustKind>,
    tree: &mut Tree<RustKind>,
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
