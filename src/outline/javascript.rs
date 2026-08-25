use crate::bounded::{BoundedVec, Span, count_of};
use crate::brackets::{self, Bracket, Pairs};
use crate::structure::NONE;
use crate::token::{Keyword, Punctuation, Token, TokenKind};

pub const PATTERN_NODES_MAX: u32 = 1_024;
const CHAIN_LINKS: [&[u8]; 3] = [b"catch", b"finally", b"then"];
const SCOPE_STACK_MAX: usize = 1 << 8;
const HEADER_WORDS: [&[u8]; 6] = [b"catch", b"for", b"if", b"switch", b"while", b"with"];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BraceKind {
    Block,
    None,
    Object,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DeclarationKind {
    CatchParameter,
    Class,
    Const,
    Function,
    Let,
    Parameter,
    Var,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ScopeKind {
    Block,
    Function,
    Program,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Scope {
    pub kind: ScopeKind,
    pub parent: u32,
    pub token_end: u32,
    pub token_start: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Declaration {
    pub kind: DeclarationKind,
    pub name: Span,
    pub scope_token_end: u32,
    pub scope_token_start: u32,
    pub value_token_end: u32,
    pub value_token_start: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Member {
    pub has_await: bool,
    pub is_async: bool,
    pub is_method: bool,
    pub is_shorthand: bool,
    pub is_spread: bool,
    pub name: Span,
    pub object: u32,
    pub token_end: u32,
    pub token_start: u32,
    pub value_token_end: u32,
    pub value_token_start: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ObjectLiteral {
    pub brace_close: u32,
    pub brace_open: u32,
    pub member_count: u32,
    pub member_first: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Call {
    pub callee_segment_count: u32,
    pub callee_segment_first: u32,
    pub paren_close: u32,
    pub paren_open: u32,
    pub scope: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Assigned {
    pub name: Span,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Statement {
    pub scope: u32,
    pub token_end: u32,
    pub token_start: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Fate {
    pub chained: bool,
    pub floating: bool,
}

#[derive(Debug)]
pub struct Outline {
    assigned: BoundedVec<Assigned>,
    braces: BoundedVec<BraceKind>,
    by_start: BoundedVec<u32>,
    calls: BoundedVec<Call>,
    declarations: BoundedVec<Declaration>,
    members: BoundedVec<Member>,
    objects: BoundedVec<ObjectLiteral>,
    scopes: BoundedVec<Scope>,
    segments: BoundedVec<Span>,
    statements: BoundedVec<Statement>,
}

struct Builder<'run> {
    outline: &'run mut Outline,
    pairs: &'run Pairs,
    source: &'run [u8],
    tokens: &'run [Token],
}

impl Outline {
    pub fn reserve(row_count_max: u32, segment_count_max: u32, token_count_max: u32) -> Self {
        assert!(row_count_max > 0);
        assert!(segment_count_max > 0);
        assert!(token_count_max > 0);

        assert!(!crate::allocation::is_frozen());

        Self {
            assigned: BoundedVec::reserve(row_count_max),
            braces: BoundedVec::reserve(token_count_max),
            by_start: BoundedVec::reserve(row_count_max),
            calls: BoundedVec::reserve(row_count_max),
            declarations: BoundedVec::reserve(row_count_max),
            members: BoundedVec::reserve(row_count_max),
            objects: BoundedVec::reserve(row_count_max),
            scopes: BoundedVec::reserve(row_count_max),
            segments: BoundedVec::reserve(segment_count_max),
            statements: BoundedVec::reserve(row_count_max),
        }
    }

    pub fn assigned(&self) -> &[Assigned] {
        &self.assigned
    }

    pub fn brace_kind(&self, token: u32) -> BraceKind {
        assert!(token < self.braces.count());

        self.braces[token as usize]
    }

    pub fn calls(&self) -> &[Call] {
        &self.calls
    }

    pub fn clear(&mut self) {
        self.assigned.clear();
        self.braces.clear();
        self.by_start.clear();
        self.calls.clear();
        self.declarations.clear();
        self.members.clear();
        self.objects.clear();
        self.scopes.clear();
        self.segments.clear();
        self.statements.clear();

        assert_eq!(self.scopes.count(), 0);
    }

    pub fn declarations(&self) -> &[Declaration] {
        &self.declarations
    }

    pub fn members(&self) -> &[Member] {
        &self.members
    }

    pub fn members_of(&self, object: &ObjectLiteral) -> &[Member] {
        let first = object.member_first as usize;
        let end = first + object.member_count as usize;

        assert!(end <= self.members.count() as usize);

        &self.members[first..end]
    }

    pub fn objects(&self) -> &[ObjectLiteral] {
        &self.objects
    }

    pub fn scopes(&self) -> &[Scope] {
        &self.scopes
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

    pub fn statements(&self) -> &[Statement] {
        &self.statements
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

    fn significant_next(&self, from: u32) -> u32 {
        let mut index = from;

        while index < self.count() {
            if self.is_significant(index) {
                return index;
            }

            index += 1;
        }

        NONE
    }

    fn last_significant(&self, from: u32, end: u32) -> u32 {
        let mut index = end.min(self.count());

        while index > from {
            index -= 1;

            if self.is_significant(index) {
                return index;
            }
        }

        NONE
    }

    fn previous_significant(&self, before: u32) -> u32 {
        let mut index = before;

        while index > 0 {
            index -= 1;

            if self.is_significant(index) {
                return index;
            }
        }

        NONE
    }

    fn text(&self, index: u32) -> &[u8] {
        if index >= self.count() {
            return &[];
        }

        self.tokens[index as usize].text(self.source)
    }

    fn breaks_line(&self, index: u32) -> bool {
        if index + 1 >= self.count() {
            return true;
        }

        let start = self.tokens[index as usize].end() as usize;
        let end = self.tokens[index as usize + 1].offset as usize;

        assert!(start <= end);

        self.source[start..end].contains(&b'\n')
    }

    fn opener(&self, index: u32) -> Option<Bracket> {
        let (kind, opens) = brackets::classify(self.source, &self.tokens[index as usize])?;

        opens.then_some(kind)
    }

    fn build_braces(&mut self) {
        for index in 0..self.count() {
            let kind = if self.opener(index) == Some(Bracket::Brace) {
                if self.brace_is_object(index) {
                    BraceKind::Object
                } else {
                    BraceKind::Block
                }
            } else {
                BraceKind::None
            };

            self.outline.braces.push_assert(kind);
        }

        assert_eq!(self.outline.braces.count(), self.count());
    }

    fn brace_is_object(&self, index: u32) -> bool {
        let previous = self.previous_significant(index);

        if previous == NONE {
            return self.brace_holds_members(index);
        }

        if self.is_function_body(index) {
            return false;
        }

        let token = self.tokens[previous as usize];

        if token.is_keyword(Keyword::Return) {
            return true;
        }

        if matches!(
            token.kind,
            TokenKind::Identifier | TokenKind::Keyword(_) | TokenKind::Number | TokenKind::String
        ) {
            return false;
        }

        #[expect(
            clippy::wildcard_enum_match_arm,
            reason = "every kind the arms above did not name closes no object literal"
        )]
        match token.kind {
            TokenKind::Punctuation(
                Punctuation::Assign
                | Punctuation::AssignDeclare
                | Punctuation::BracketOpen
                | Punctuation::Colon
                | Punctuation::Comma
                | Punctuation::ParenOpen,
            ) => true,
            TokenKind::Punctuation(Punctuation::Other) => !matches!(self.text(previous), b"}"),
            _ => false,
        }
    }

    fn brace_holds_members(&self, brace: u32) -> bool {
        let mut first = self.significant_next(brace + 1);

        if first == NONE {
            return false;
        }

        if self.text(first) == b"}" || self.text(first) == b"..." {
            return true;
        }

        if self.text(first) == b"async" {
            let after = self.significant_next(first + 1);

            if after != NONE {
                first = after;
            }
        }

        let token = self.tokens[first as usize];

        if !matches!(token.kind, TokenKind::Identifier | TokenKind::String) {
            return false;
        }

        let next = self.significant_next(first + 1);

        if next == NONE {
            return false;
        }

        let after = self.tokens[next as usize];

        after.is_punctuation(Punctuation::Colon)
            || after.is_punctuation(Punctuation::Comma)
            || after.is_punctuation(Punctuation::ParenOpen)
            || self.text(next) == b"}"
    }

    fn is_function_body(&self, brace: u32) -> bool {
        let previous = self.previous_significant(brace);

        if previous == NONE {
            return false;
        }

        if self.text(previous) == b"=>" {
            return true;
        }

        if !self.tokens[previous as usize].is_punctuation(Punctuation::ParenClose) {
            return false;
        }

        let open = self.pairs.partner_of(previous);

        if open == brackets::NONE {
            return false;
        }

        let before = self.previous_significant(open);

        if before == NONE {
            return false;
        }

        !HEADER_WORDS.contains(&self.text(before))
    }

    fn build_scopes(&mut self) {
        let program = Scope {
            kind: ScopeKind::Program,
            parent: NONE,
            token_end: self.count(),
            token_start: 0,
        };

        self.outline.scopes.push_assert(program);

        let mut stack = [0_u32; SCOPE_STACK_MAX];
        let mut depth = 1;

        for index in 0..self.count() {
            self.scope_open(index, &mut stack, &mut depth);
        }

        self.build_arrow_scopes();
    }

    fn open_at(&self, stack: &[u32; SCOPE_STACK_MAX], depth: &mut usize, start: u32) -> u32 {
        for _ in 0..SCOPE_STACK_MAX {
            if *depth <= 1 {
                break;
            }

            let held = self.outline.scopes[stack[*depth - 1] as usize];

            if held.token_end > start && held.token_start <= start {
                break;
            }

            *depth -= 1;
        }

        stack[*depth - 1]
    }

    fn scope_open(&mut self, index: u32, stack: &mut [u32; SCOPE_STACK_MAX], depth: &mut usize) {
        if self.opener(index) != Some(Bracket::Brace) {
            return;
        }

        let close = self.pairs.partner_of(index);

        let end = if close == brackets::NONE {
            self.count()
        } else {
            close + 1
        };

        let function_body = self.is_function_body(index);

        if !function_body && self.outline.braces[index as usize] != BraceKind::Block {
            return;
        }

        let start = if function_body {
            self.function_start(index)
        } else {
            self.block_start(index)
        };

        let parent = self.open_at(stack, depth, start);
        let held = self.outline.scopes.count();

        let pushed = self.outline.scopes.push(Scope {
            kind: if function_body {
                ScopeKind::Function
            } else {
                ScopeKind::Block
            },
            parent,
            token_end: end,
            token_start: start,
        });

        if !pushed {
            return;
        }

        if *depth < SCOPE_STACK_MAX {
            stack[*depth] = held;
            *depth += 1;
        }

        if !function_body {
            return;
        }

        let body = self.outline.scopes.count();

        let recorded = self.outline.scopes.push(Scope {
            kind: ScopeKind::Block,
            parent: held,
            token_end: end,
            token_start: index,
        });

        if recorded && *depth < SCOPE_STACK_MAX {
            stack[*depth] = body;
            *depth += 1;
        }
    }

    fn build_arrow_scopes(&mut self) {
        for index in 0..self.count() {
            if self.text(index) != b"=>" {
                continue;
            }

            let body = self.significant_next(index + 1);

            if body != NONE && self.opener(body) == Some(Bracket::Brace) {
                continue;
            }

            let start = self.arrow_start(index);
            let end = self.expression_end(index + 1);
            let parent = self.scope_covering(start);

            let _ = self.outline.scopes.push(Scope {
                kind: ScopeKind::Function,
                parent,
                token_end: end,
                token_start: start,
            });
        }
    }

    fn arrow_start(&self, arrow: u32) -> u32 {
        let previous = self.previous_significant(arrow);

        if previous == NONE {
            return arrow;
        }

        if self.tokens[previous as usize].is_punctuation(Punctuation::ParenClose) {
            let open = self.pairs.partner_of(previous);

            if open != brackets::NONE {
                return open;
            }
        }

        previous
    }

    fn block_start(&self, brace: u32) -> u32 {
        let previous = self.previous_significant(brace);

        if previous == NONE {
            return brace;
        }

        if !self.tokens[previous as usize].is_punctuation(Punctuation::ParenClose) {
            return brace;
        }

        let open = self.pairs.partner_of(previous);

        if open == brackets::NONE {
            return brace;
        }

        let before = self.previous_significant(open);

        if before != NONE && HEADER_WORDS.contains(&self.text(before)) {
            return before;
        }

        brace
    }

    fn expression_end(&self, from: u32) -> u32 {
        let depth = if from < self.count() {
            self.pairs.depth_of(from)
        } else {
            0
        };

        let mut index = from;

        while index < self.count() {
            let here = self.pairs.depth_of(index);

            if here < depth {
                return index;
            }

            if here == depth {
                let token = self.tokens[index as usize];

                if token.is_punctuation(Punctuation::Comma)
                    || token.is_punctuation(Punctuation::Semicolon)
                {
                    return index;
                }

                if self.breaks_line(index) && !self.continues_expression(index + 1) {
                    return index + 1;
                }
            }

            index += 1;
        }

        self.count()
    }

    fn function_start(&self, brace: u32) -> u32 {
        let previous = self.previous_significant(brace);

        if previous == NONE {
            return brace;
        }

        if self.text(previous) == b"=>" {
            return self.arrow_start(previous);
        }

        let open = self.pairs.partner_of(previous);

        if open == brackets::NONE {
            return brace;
        }

        self.header_start(open)
    }

    fn header_start(&self, open: u32) -> u32 {
        let mut start = open;
        let mut previous = self.previous_significant(start);

        while previous != NONE {
            let token = self.tokens[previous as usize];
            let extends = matches!(
                token.kind,
                TokenKind::Identifier | TokenKind::Number | TokenKind::String
            ) || token.is_keyword(Keyword::Function)
                || matches!(self.text(previous), b"async" | b"get" | b"set" | b"*");

            if !extends {
                break;
            }

            start = previous;
            previous = self.previous_significant(start);
        }

        start
    }

    fn scope_covering(&self, token: u32) -> u32 {
        self.narrowest(token, false)
    }

    fn scope_of(&self, token: u32, functions_only: bool) -> u32 {
        self.narrowest(token, functions_only)
    }

    fn narrowest(&self, token: u32, functions_only: bool) -> u32 {
        if self.outline.by_start.count() == self.outline.scopes.count() {
            return self.indexed(token, functions_only);
        }

        let mut found = NONE;
        let mut width = u32::MAX;

        for (index, scope) in self.outline.scopes.iter().enumerate().rev() {
            if scope.token_start > token || scope.token_end <= token {
                continue;
            }

            if functions_only && scope.kind == ScopeKind::Block {
                continue;
            }

            let span = scope.token_end - scope.token_start;

            if span < width {
                found = count_of(index);
                width = span;
            }
        }

        found
    }

    fn indexed(&self, token: u32, functions_only: bool) -> u32 {
        let scopes = &*self.outline.scopes;

        let above = self
            .outline
            .by_start
            .partition_point(|index| scopes[*index as usize].token_start <= token);

        if above == 0 {
            return NONE;
        }

        let mut scope = self.outline.by_start[above - 1];

        for _ in 0..=scopes.len() {
            if scope == NONE {
                return NONE;
            }

            let held = scopes[scope as usize];
            let covers = held.token_start <= token && held.token_end > token;

            if covers && !(functions_only && held.kind == ScopeKind::Block) {
                return scope;
            }

            scope = held.parent;
        }

        NONE
    }

    fn index_scopes(&mut self) {
        let scopes = &self.outline.scopes;
        let count = scopes.count();

        self.outline.by_start.clear();

        for index in 0..count {
            self.outline.by_start.push_assert(index);
        }

        let held_scopes = &*self.outline.scopes;

        self.outline.by_start.sort_unstable_by_key(|index| {
            let held = held_scopes[*index as usize];

            (held.token_start, u32::MAX - held.token_end)
        });
    }

    fn push_declaration(&mut self, kind: DeclarationKind, name: u32, value: (u32, u32)) {
        let block_scoped = !matches!(kind, DeclarationKind::Var | DeclarationKind::Function);
        let scope = self.scope_of(name, !block_scoped);

        let (token_start, token_end) = if scope == NONE {
            (0, self.count())
        } else {
            let held = self.outline.scopes[scope as usize];

            (held.token_start, held.token_end)
        };

        let _ = self.outline.declarations.push(Declaration {
            kind,
            name: self.tokens[name as usize].span(),
            scope_token_end: token_end,
            scope_token_start: token_start,
            value_token_end: value.1,
            value_token_start: value.0,
        });
    }

    fn build_declarations(&mut self) {
        let mut index = 0;

        while index < self.count() {
            let token = self.tokens[index as usize];

            match token.kind {
                TokenKind::Keyword(Keyword::Constant) => {
                    index = self.read_declarators(index, DeclarationKind::Const);

                    continue;
                }
                TokenKind::Keyword(Keyword::Mutable) => {
                    let kind = if self.text(index) == b"var" {
                        DeclarationKind::Var
                    } else {
                        DeclarationKind::Let
                    };

                    index = self.read_declarators(index, kind);

                    continue;
                }
                TokenKind::Keyword(Keyword::Function) => self.read_function(index),
                TokenKind::Keyword(Keyword::Struct) => {
                    let name = self.significant_next(index + 1);

                    if name != NONE && self.tokens[name as usize].kind == TokenKind::Identifier {
                        self.push_declaration(DeclarationKind::Class, name, (name, name));
                    }
                }
                TokenKind::Keyword(Keyword::Except) => self.read_catch(index),
                TokenKind::BlockEnd
                | TokenKind::BlockStart
                | TokenKind::Comment
                | TokenKind::Identifier
                | TokenKind::Keyword(_)
                | TokenKind::Newline
                | TokenKind::Number
                | TokenKind::Punctuation(_)
                | TokenKind::String => {}
            }

            index += 1;
        }

        self.read_arrow_parameters();
        self.read_parameters();
    }

    fn read_parameters(&mut self) {
        for index in 0..self.count() {
            if self.opener(index) != Some(Bracket::Brace) || !self.is_function_body(index) {
                continue;
            }

            let previous = self.previous_significant(index);

            if previous == NONE
                || !self.tokens[previous as usize].is_punctuation(Punctuation::ParenClose)
            {
                continue;
            }

            let open = self.pairs.partner_of(previous);

            if open == brackets::NONE {
                continue;
            }

            self.read_pattern(open + 1, previous, DeclarationKind::Parameter);
        }
    }

    fn read_arrow_parameters(&mut self) {
        for index in 0..self.count() {
            if self.text(index) != b"=>" {
                continue;
            }

            let previous = self.previous_significant(index);

            if previous == NONE {
                continue;
            }

            if self.tokens[previous as usize].kind == TokenKind::Identifier {
                self.push_declaration(DeclarationKind::Parameter, previous, (previous, previous));

                continue;
            }

            if !self.tokens[previous as usize].is_punctuation(Punctuation::ParenClose) {
                continue;
            }

            let open = self.pairs.partner_of(previous);

            if open == brackets::NONE {
                continue;
            }

            self.read_pattern(open + 1, previous, DeclarationKind::Parameter);
        }
    }

    fn read_catch(&mut self, index: u32) {
        let open = self.significant_next(index + 1);

        if open == NONE || !self.tokens[open as usize].is_punctuation(Punctuation::ParenOpen) {
            return;
        }

        let close = self.pairs.partner_of(open);

        if close == brackets::NONE {
            return;
        }

        self.read_pattern(open + 1, close, DeclarationKind::CatchParameter);
    }

    fn read_declarators(&mut self, keyword: u32, kind: DeclarationKind) -> u32 {
        let depth = self.pairs.depth_of(keyword);
        let end = self.expression_run(keyword + 1, depth);
        let mut start = self.significant_next(keyword + 1);
        let mut index = start;

        while index != NONE && index <= end {
            let splits = index == end
                || (self.tokens[index as usize].is_punctuation(Punctuation::Comma)
                    && self.pairs.depth_of(index) == depth);

            if !splits {
                index += 1;

                continue;
            }

            self.read_declarator(start, index, kind);

            start = index + 1;
            index += 1;
        }

        end.max(keyword + 1)
    }

    fn read_declarator(&mut self, start: u32, end: u32, kind: DeclarationKind) {
        let first = self.significant_next(start);

        if first == NONE || first >= end {
            return;
        }

        let mut assign = first;

        while assign < end {
            if self.tokens[assign as usize].is_punctuation(Punctuation::Assign)
                && self.pairs.depth_of(assign) == self.pairs.depth_of(first)
            {
                break;
            }

            assign += 1;
        }

        let value = if assign < end {
            (assign + 1, end)
        } else {
            (end, end)
        };

        if self.tokens[first as usize].kind == TokenKind::Identifier {
            self.push_declaration(kind, first, value);

            return;
        }

        self.read_pattern(first, assign.min(end), kind);
    }

    fn read_pattern(&mut self, start: u32, end: u32, kind: DeclarationKind) {
        let bound = end.min(start.saturating_add(PATTERN_NODES_MAX));
        let mut index = start;

        while index < bound {
            if self.tokens[index as usize].kind != TokenKind::Identifier {
                index += 1;

                continue;
            }

            let next = self.significant_next(index + 1);

            if next != NONE
                && next < bound
                && self.tokens[next as usize].is_punctuation(Punctuation::Colon)
            {
                index += 1;

                continue;
            }

            self.push_declaration(kind, index, (index, index));

            index += 1;

            while index < bound {
                let token = self.tokens[index as usize];

                if token.is_punctuation(Punctuation::Comma)
                    || brackets::classify(self.source, &token).is_some()
                {
                    break;
                }

                index += 1;
            }
        }
    }

    fn read_function(&mut self, keyword: u32) {
        let name = self.significant_next(keyword + 1);

        if name == NONE {
            return;
        }

        if !self.tokens[name as usize].is_punctuation(Punctuation::ParenOpen)
            && self.tokens[name as usize].kind == TokenKind::Identifier
        {
            self.push_declaration(DeclarationKind::Function, name, (name, name));
        }
    }

    fn expression_run(&self, from: u32, depth: u32) -> u32 {
        let mut index = from;

        while index < self.count() {
            let here = self.pairs.depth_of(index);

            if here < depth {
                return index;
            }

            if here == depth {
                let token = self.tokens[index as usize];

                if token.is_punctuation(Punctuation::Semicolon) {
                    return index;
                }

                if self.breaks_line(index) && !self.continues_expression(index + 1) {
                    return index + 1;
                }
            }

            index += 1;
        }

        self.count()
    }

    fn continues_expression(&self, from: u32) -> bool {
        let next = self.significant_next(from);

        if next == NONE {
            return false;
        }

        let token = self.tokens[next as usize];

        if matches!(
            token.kind,
            TokenKind::Punctuation(
                Punctuation::Dot
                    | Punctuation::Comma
                    | Punctuation::Colon
                    | Punctuation::ParenClose
                    | Punctuation::BracketClose
                    | Punctuation::Assign
                    | Punctuation::Equal
                    | Punctuation::NotEqual
                    | Punctuation::AmpersandDouble
                    | Punctuation::BarDouble
                    | Punctuation::Arrow
                    | Punctuation::Star
                    | Punctuation::Slash
            )
        ) {
            return true;
        }

        matches!(
            self.text(next),
            b"+" | b"-" | b"?" | b"=>" | b"%" | b"else" | b"catch" | b"finally"
        )
    }

    fn build_objects(&mut self) {
        for index in 0..self.count() {
            if self.outline.braces[index as usize] != BraceKind::Object {
                continue;
            }

            let close = self.pairs.partner_of(index);

            if close == brackets::NONE {
                continue;
            }

            let object = self.outline.objects.count();
            let member_first = self.outline.members.count();
            let count = self.read_members(object, index, close);

            let _ = self.outline.objects.push(ObjectLiteral {
                brace_close: close,
                brace_open: index,
                member_count: count,
                member_first,
            });
        }
    }

    fn read_members(&mut self, object: u32, open: u32, close: u32) -> u32 {
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

            let first = self.significant_next(start);

            if first != NONE && first < index {
                let member = self.read_member(object, start, index);

                if self.outline.members.push(member) {
                    count += 1;
                }
            }

            start = index + 1;
            index += 1;
        }

        count
    }

    fn read_member(&self, object: u32, start: u32, end: u32) -> Member {
        let mut first = self.significant_next(start);
        let mut is_async = false;
        let is_spread = first != NONE && self.text(first) == b"...";

        if first != NONE && self.text(first) == b"async" {
            let after = self.significant_next(first + 1);

            if after != NONE && after < end {
                is_async = true;
                first = after;
            }
        }

        let name = if first != NONE
            && first < end
            && (self.is_name(first) || self.tokens[first as usize].kind == TokenKind::String)
        {
            self.tokens[first as usize].span()
        } else {
            Span::EMPTY
        };

        let colon = self.member_colon(first, end);

        let after_name = if first == NONE {
            NONE
        } else {
            self.significant_next(first + 1)
        };

        let is_method = colon == NONE
            && after_name != NONE
            && after_name < end
            && self.tokens[after_name as usize].is_punctuation(Punctuation::ParenOpen);

        let value = if colon == NONE {
            (first.min(end), end)
        } else {
            (colon + 1, end)
        };

        let head = self.significant_next(start);
        let tail = self.last_significant(start, end);

        Member {
            has_await: self.has_await(value.0, value.1),
            is_async,
            is_method,
            is_shorthand: colon == NONE && !is_method && !is_spread,
            is_spread,
            name: if is_spread { Span::EMPTY } else { name },
            object,
            token_end: if tail == NONE { end } else { tail + 1 },
            token_start: if head == NONE { start } else { head },
            value_token_end: value.1,
            value_token_start: value.0,
        }
    }

    fn member_colon(&self, first: u32, end: u32) -> u32 {
        if first == NONE {
            return NONE;
        }

        let next = self.significant_next(first + 1);

        if next != NONE
            && next < end
            && self.tokens[next as usize].is_punctuation(Punctuation::Colon)
        {
            return next;
        }

        NONE
    }

    fn has_await(&self, start: u32, end: u32) -> bool {
        let mut index = start;

        while index < end && index < self.count() {
            if self.text(index) == b"await" && self.function_depth(index, start, end) < 2 {
                return true;
            }

            index += 1;
        }

        false
    }

    fn function_depth(&self, token: u32, start: u32, end: u32) -> u32 {
        let mut depth = 0;

        for scope in self.outline.scopes.iter() {
            if scope.kind != ScopeKind::Function {
                continue;
            }

            if scope.token_start <= token
                && token < scope.token_end
                && scope.token_start >= start
                && scope.token_end <= end
            {
                depth += 1;
            }
        }

        depth
    }

    fn build_calls(&mut self) {
        let mut index = 0;

        while index < self.count() {
            if !self.is_name(index) || self.is_dotted_tail(index) {
                index += 1;

                continue;
            }

            let is_new = self.text(index) == b"new";

            let head = if is_new {
                self.significant_next(index + 1)
            } else {
                index
            };

            if head == NONE || !self.is_name(head) {
                index += 1;

                continue;
            }

            let chain = self.chain_end(head);
            let open = chain + 1;
            let close = self.call_close(open);

            if close == NONE {
                index = chain + 1;

                continue;
            }

            self.push_call(index, head, chain, open, close, is_new);

            index = open + 1;
        }
    }

    fn call_close(&self, open: u32) -> u32 {
        if open >= self.count()
            || !self.tokens[open as usize].is_punctuation(Punctuation::ParenOpen)
        {
            return NONE;
        }

        let close = self.pairs.partner_of(open);

        if close == brackets::NONE {
            return NONE;
        }

        close
    }

    fn push_call(
        &mut self,
        index: u32,
        head: u32,
        chain: u32,
        open: u32,
        close: u32,
        is_new: bool,
    ) {
        let callee_segment_first = self.outline.segments.count();
        let mut callee_segment_count = 0;

        if is_new
            && self
                .outline
                .segments
                .push(self.tokens[index as usize].span())
        {
            callee_segment_count += 1;
        }

        let mut segment = head;

        while segment <= chain {
            if self.is_name(segment)
                && self
                    .outline
                    .segments
                    .push(self.tokens[segment as usize].span())
            {
                callee_segment_count += 1;
            }

            segment += 2;
        }

        let scope = self.scope_of(open, false);

        let _ = self.outline.calls.push(Call {
            callee_segment_count,
            callee_segment_first,
            paren_close: close,
            paren_open: open,
            scope,
        });
    }

    fn is_dotted_tail(&self, index: u32) -> bool {
        index >= 2
            && self.tokens[index as usize - 1].is_punctuation(Punctuation::Dot)
            && self.is_name(index - 2)
    }

    fn build_statements(&mut self) {
        let mut start = 0;
        let mut index = 0;

        while index < self.count() {
            if self.pairs.depth_of(index) > 0 {
                index += 1;

                continue;
            }

            let token = self.tokens[index as usize];

            let terminates = token.is_punctuation(Punctuation::Semicolon)
                || self.outline.braces[index as usize] == BraceKind::Block
                || token.kind == TokenKind::BlockEnd;

            let breaks = self.breaks_line(index) && !self.continues_expression(index + 1);

            if !terminates && !breaks {
                index += 1;

                continue;
            }

            let end = if terminates { index } else { index + 1 };

            self.push_statement(start, end);

            start = index + 1;
            index += 1;
        }

        self.push_statement(start, self.count());
    }

    fn push_statement(&mut self, start: u32, end: u32) {
        let first = self.significant_next(start);

        if first == NONE || first >= end {
            return;
        }

        let scope = self.scope_of(first, false);

        let _ = self.outline.statements.push(Statement {
            scope,
            token_end: end,
            token_start: first,
        });
    }

    fn build_assigned(&mut self) {
        for index in 0..self.count() {
            let token = self.tokens[index as usize];

            let writes = token.is_punctuation(Punctuation::Assign)
                || self.is_compound_assign(index)
                || self.is_update(index);

            if !writes {
                continue;
            }

            let from = if self.is_update(index) {
                index - 1
            } else {
                index
            };

            let target = self.previous_significant(from);

            if target == NONE || self.tokens[target as usize].kind != TokenKind::Identifier {
                continue;
            }

            let before = self.previous_significant(target);

            if before != NONE && self.tokens[before as usize].is_punctuation(Punctuation::Dot) {
                continue;
            }

            let _ = self.outline.assigned.push(Assigned {
                name: self.tokens[target as usize].span(),
            });
        }
    }

    fn is_compound_assign(&self, index: u32) -> bool {
        let token = self.tokens[index as usize];

        if !token.is_punctuation(Punctuation::Other) {
            return false;
        }

        let text = self.text(index);

        text.len() >= 2 && text.ends_with(b"=") && !matches!(text, b"==" | b"=>" | b"===")
    }

    fn is_update(&self, index: u32) -> bool {
        if index == 0 {
            return false;
        }

        let text = self.text(index);

        matches!(text, b"+" | b"-")
            && text == self.text(index - 1)
            && self.tokens[index as usize].offset == self.tokens[index as usize - 1].offset + 1
    }
}

pub fn build(source: &[u8], tokens: &[Token], pairs: &Pairs, outline: &mut Outline) {
    assert!(u32::try_from(source.len()).is_ok());
    assert_eq!(pairs.count() as usize, tokens.len());

    outline.clear();

    let mut builder = Builder {
        outline,
        pairs,
        source,
        tokens,
    };

    builder.build_braces();
    builder.build_scopes();
    builder.index_scopes();
    builder.build_declarations();
    builder.build_objects();
    builder.build_calls();
    builder.build_statements();
    builder.build_assigned();
}

pub fn chain_fate(call: &Call, source: &[u8], tokens: &[Token], statements: &[Statement]) -> Fate {
    assert!(call.paren_close as usize <= tokens.len());
    assert!(call.paren_open <= call.paren_close);

    let Some(statement) = statements
        .iter()
        .find(|held| held.token_start <= call.paren_open && call.paren_open < held.token_end)
    else {
        return Fate {
            chained: false,
            floating: false,
        };
    };

    let mut index = call.paren_close + 1;
    let mut chained = false;

    while index < statement.token_end {
        let token = tokens[index as usize];

        if matches!(token.kind, TokenKind::Comment | TokenKind::Newline) {
            index += 1;

            continue;
        }

        if !token.is_punctuation(Punctuation::Dot) {
            break;
        }

        let name = index + 1;

        if name >= statement.token_end {
            break;
        }

        if CHAIN_LINKS.contains(&tokens[name as usize].text(source)) {
            chained = true;
        }

        index = name + 1;
    }

    let leads = !leading_tokens(statement, call, tokens, source);

    Fate {
        chained,
        floating: leads && !chained,
    }
}

fn leading_tokens(statement: &Statement, call: &Call, tokens: &[Token], source: &[u8]) -> bool {
    let mut index = statement.token_start;

    while index < call.paren_open {
        let token = tokens[index as usize];

        if matches!(token.kind, TokenKind::Comment | TokenKind::Newline) {
            index += 1;

            continue;
        }

        if matches!(
            token.kind,
            TokenKind::Identifier | TokenKind::Punctuation(Punctuation::Dot)
        ) {
            index += 1;

            continue;
        }

        if token.text(source) == b"new" {
            index += 1;

            continue;
        }

        return true;
    }

    false
}
