#[path = "common/corpus.rs"]
mod corpus;
#[path = "common/floor.rs"]
mod floor;
#[path = "common/oracle.rs"]
mod oracle;

use std::fs;
use std::path::{Path, PathBuf};

use scylla::bounded::{BoundedVec, Span, count_of};
use scylla::language::Lexer as _;
use scylla::lex::{JAVASCRIPT, TYPESCRIPT};
use scylla::syntax::javascript::classify::classify;
use scylla::syntax::javascript::kind::JavaScriptKind;
use scylla::syntax::javascript::parse;
use scylla::syntax::javascript::semantic::{
    Binding,
    BindingKind,
    Context,
    Kinds,
    Namespace,
    PARAMETER_NONE,
    Reference,
    Resolution,
    Role,
    ScopeKind,
    Semantic,
};
use scylla::syntax::typescript::classify::classify as typescript_classify;
use scylla::syntax::typescript::dialect::Dialect;
use scylla::syntax::typescript::kind::TypeScriptKind;
use scylla::syntax::typescript::parse as typescript_parse;
use scylla::syntax::{Category, FactKind, Structure};
use scylla::token::{Token, Tokens};
use scylla::tree::{Events, Kind, NONE, Tree};

const BINDING_COUNT_MAX: u32 = 1 << 15;
const ERROR_COUNT_MAX: u32 = 1 << 12;
const EVENT_COUNT_MAX: u32 = 1 << 20;
const EVERY_CATEGORY: [&str; 3] = ["not-javascript", "oxlint", "scylla"];
const FACT_COUNT_MAX: u32 = 1 << 13;
const NODE_COUNT_MAX: u32 = 1 << 18;
const REFERENCE_COUNT_MAX: u32 = 1 << 17;
const SCOPE_COUNT_MAX: u32 = 1 << 14;
const TOKEN_COUNT_MAX: u32 = 1 << 18;

const GLOBALS: [&[u8]; 61] = [
    b"AggregateError",
    b"arguments",
    b"Array",
    b"ArrayBuffer",
    b"Atomics",
    b"BigInt",
    b"BigInt64Array",
    b"BigUint64Array",
    b"Boolean",
    b"DataView",
    b"Date",
    b"decodeURI",
    b"decodeURIComponent",
    b"encodeURI",
    b"encodeURIComponent",
    b"Error",
    b"escape",
    b"eval",
    b"EvalError",
    b"FinalizationRegistry",
    b"Float32Array",
    b"Float64Array",
    b"Function",
    b"globalThis",
    b"Infinity",
    b"Int16Array",
    b"Int32Array",
    b"Int8Array",
    b"Intl",
    b"isFinite",
    b"isNaN",
    b"JSON",
    b"Map",
    b"Math",
    b"NaN",
    b"Number",
    b"Object",
    b"parseFloat",
    b"parseInt",
    b"Promise",
    b"Proxy",
    b"RangeError",
    b"ReferenceError",
    b"Reflect",
    b"RegExp",
    b"Set",
    b"SharedArrayBuffer",
    b"String",
    b"Symbol",
    b"SyntaxError",
    b"TypeError",
    b"Uint16Array",
    b"Uint32Array",
    b"Uint8Array",
    b"Uint8ClampedArray",
    b"undefined",
    b"unescape",
    b"URIError",
    b"WeakMap",
    b"WeakRef",
    b"WeakSet",
];

struct Fixture {
    dialect: Option<Dialect>,
    name: String,
    source: Vec<u8>,
}

struct Machine {
    declaration: bool,
    events: Events<JavaScriptKind>,
    lexed: Tokens,
    raw: BoundedVec<JavaScriptKind>,
    semantic: Semantic,
    tokens: Tokens,
    tree: Tree<JavaScriptKind>,
    typed: bool,
    typed_events: Events<TypeScriptKind>,
    typed_raw: BoundedVec<TypeScriptKind>,
    typed_tokens: Tokens,
    typed_tree: Tree<TypeScriptKind>,
}

impl Machine {
    fn reserve() -> Self {
        Self {
            declaration: false,
            events: Events::reserve(EVENT_COUNT_MAX),
            lexed: Tokens::reserve(TOKEN_COUNT_MAX),
            raw: BoundedVec::reserve(TOKEN_COUNT_MAX),
            semantic: Semantic::reserve(
                BINDING_COUNT_MAX,
                REFERENCE_COUNT_MAX,
                SCOPE_COUNT_MAX,
                FACT_COUNT_MAX,
            ),
            tokens: Tokens::reserve(TOKEN_COUNT_MAX),
            tree: Tree::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX),
            typed: false,
            typed_events: Events::reserve(EVENT_COUNT_MAX),
            typed_raw: BoundedVec::reserve(TOKEN_COUNT_MAX),
            typed_tokens: Tokens::reserve(TOKEN_COUNT_MAX),
            typed_tree: Tree::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX),
        }
    }

    fn run_fixture(&mut self, fixture: &Fixture) -> Structure {
        self.declaration = fixture.name.ends_with(".d.ts")
            || fixture.name.ends_with(".d.cts")
            || fixture.name.ends_with(".d.mts");

        match fixture.dialect {
            None => self.run(&fixture.source),
            Some(dialect) => self.run_typed(&fixture.source, dialect),
        }
    }

    fn run_typed(&mut self, source: &[u8], dialect: Dialect) -> Structure {
        self.typed = true;
        self.lexed.clear();
        TYPESCRIPT.lex(source, &mut self.lexed);

        assert!(typescript_classify(
            source,
            self.lexed.as_slice(),
            &mut self.typed_tokens,
            &mut self.typed_raw,
            dialect
        ));

        typescript_parse::build(
            source,
            self.typed_tokens.as_slice(),
            &self.typed_raw,
            &mut self.typed_events,
            &mut self.typed_tree,
            dialect,
        );

        self.semantic.build(
            source,
            self.typed_tokens.as_slice(),
            &self.typed_raw,
            &self.typed_tree,
            None,
            &GLOBALS,
        )
    }

    fn run(&mut self, source: &[u8]) -> Structure {
        self.typed = false;
        self.lexed.clear();
        JAVASCRIPT.lex(source, &mut self.lexed);

        assert!(classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw
        ));

        parse::build(
            source,
            self.tokens.as_slice(),
            &self.raw,
            &mut self.events,
            &mut self.tree,
        );

        self.semantic.build(
            source,
            self.tokens.as_slice(),
            &self.raw,
            &self.tree,
            None,
            &GLOBALS,
        )
    }

    fn rows(&self, source: &[u8]) -> Vec<(String, u32)> {
        let mut found = Vec::new();

        self.undefined(source, &mut found);
        self.unused(source, &mut found);
        self.redeclared(source, &mut found);

        found.retain(|row| !suppressed(source, &row.0, row.1));
        found.sort();

        found
    }

    fn undefined(&self, source: &[u8], found: &mut Vec<(String, u32)>) {
        for held in self.semantic.references() {
            if matches!(held.resolution, Resolution::Bound(_) | Resolution::Builtin) {
                continue;
            }

            if held.namespace == Namespace::Type {
                continue;
            }

            if typeof_at(source, held.name.offset)
                && !self.queried(held.node)
                && self.role_above(held.node, 1) != Some(Role::MemberExpression)
            {
                continue;
            }

            found.push(("no-undef".to_owned(), held.name.offset));
        }
    }

    fn unused(&self, source: &[u8], found: &mut Vec<(String, u32)>) {
        if self.declaration {
            return;
        }

        let jsx = self.holds_jsx();

        for index in 0..self.semantic.count() {
            let held = self.semantic.bindings()[index as usize];

            if !reportable(held.kind) || self.names_itself(index) {
                continue;
            }

            if jsx && &source[held.name.range()] == b"React" {
                continue;
            }

            if ignorable(held.kind, &source[held.name.range()]) {
                continue;
            }

            if self.exported(held.name) || self.ambient(held.scope) || self.declared(held.node) {
                continue;
            }

            let (first, read, merged) = self.group_of(source, index);

            if merged {
                if index != first || read {
                    continue;
                }

                found.push(("no-unused-vars".to_owned(), held.name.offset));

                continue;
            }

            if self.read(source, index) {
                continue;
            }

            if self.shadowed(source, index) {
                continue;
            }

            found.push(("no-unused-vars".to_owned(), held.name.offset));
        }

        self.unused_parameters(source, found);
    }

    fn holds_jsx(&self) -> bool {
        if self.typed {
            return (0..self.typed_tree.count()).any(|at| {
                matches!(
                    self.typed_tree.at(at).kind,
                    TypeScriptKind::JsxElement | TypeScriptKind::JsxSelfClosingElement
                )
            });
        }

        (0..self.tree.count()).any(|at| {
            matches!(
                self.tree.at(at).kind,
                JavaScriptKind::JsxElement | JavaScriptKind::JsxSelfClosingElement
            )
        })
    }

    fn declared(&self, node: u32) -> bool {
        if !self.typed {
            return false;
        }

        if self.ambient_variable(node) {
            return false;
        }

        let mut held = node;

        for _ in 0..=self.typed_tree.count() {
            if held == NONE {
                return false;
            }

            let kind = self.typed_tree.at(held).kind;

            if kind == TypeScriptKind::InternalModule {
                return false;
            }

            if kind == TypeScriptKind::AmbientDeclaration {
                return true;
            }

            held = self.typed_tree.at(held).parent;
        }

        false
    }

    fn ambient_variable(&self, node: u32) -> bool {
        let declarator = self.typed_tree.at(node).parent;

        if declarator == NONE
            || self.typed_tree.at(declarator).kind.role() != Role::VariableDeclarator
        {
            return false;
        }

        let declaration = self.typed_tree.at(declarator).parent;

        if declaration == NONE
            || !matches!(
                self.typed_tree.at(declaration).kind.role(),
                Role::LexicalDeclaration | Role::VariableDeclaration
            )
        {
            return false;
        }

        let above = self.typed_tree.at(declaration).parent;

        above != NONE && self.typed_tree.at(above).kind == TypeScriptKind::AmbientDeclaration
    }

    fn ambient(&self, scope: u32) -> bool {
        let mut held = scope;

        for _ in 0..=self.semantic.scopes().len() {
            let found = self.semantic.scopes()[held as usize];

            if self.typed && self.typed_tree.at(found.node).kind == TypeScriptKind::InternalModule {
                return false;
            }

            if found.kind == ScopeKind::Ambient {
                return true;
            }

            if found.parent == NONE {
                return false;
            }

            held = found.parent;
        }

        false
    }

    fn exported(&self, name: Span) -> bool {
        self.semantic.facts().iter().any(|held| {
            matches!(held.kind, FactKind::ExportDefault | FactKind::ExportNamed)
                && held.local == name
        })
    }

    fn group_of(&self, source: &[u8], index: u32) -> (u32, bool, bool) {
        let held = self.semantic.bindings()[index as usize];
        let name = &source[held.name.range()];
        let mut first = index;
        let mut read = self.read(source, index);
        let mut merged = merges(held.kind);
        let mut counted = 1;

        for other in 0..self.semantic.count() {
            if other == index {
                continue;
            }

            let seen = self.semantic.bindings()[other as usize];

            if seen.scope != held.scope || &source[seen.name.range()] != name {
                continue;
            }

            if self.names_itself(other) {
                continue;
            }

            merged = merged || merges(seen.kind);
            read = read || self.read(source, other);
            counted += 1;

            if other < first {
                first = other;
            }
        }

        (first, read, merged && counted > 1)
    }

    fn read(&self, source: &[u8], index: u32) -> bool {
        let held = self.semantic.bindings()[index as usize];

        self.semantic.references_of(index).any(|found| {
            let reference = self.semantic.references()[found as usize];

            reference.context == Context::Load
                && !self.discarded(&reference, held.scope)
                && !self.recursive(&reference, held)
                && !self.thrown_away(source, &reference, held)
        })
    }

    fn thrown_away(&self, source: &[u8], reference: &Reference, held: Binding) -> bool {
        if self.functional(reference.scope) != self.functional(held.scope) {
            return false;
        }

        let name = &source[held.name.range()];

        if self.typed {
            return thrown(
                &self.typed_tree,
                self.typed_tokens.as_slice(),
                source,
                reference.node,
                name,
            );
        }

        thrown(
            &self.tree,
            self.tokens.as_slice(),
            source,
            reference.node,
            name,
        )
    }

    fn recursive(&self, reference: &Reference, held: Binding) -> bool {
        let Some(body) = self.self_body(held) else {
            return false;
        };

        if self.typed {
            return inside(&self.typed_tree, reference.node, body);
        }

        inside(&self.tree, reference.node, body)
    }

    fn self_body(&self, held: Binding) -> Option<u32> {
        if matches!(
            held.kind,
            BindingKind::Class | BindingKind::Function | BindingKind::TypeParameter
        ) {
            return Some(held.node);
        }

        if !matches!(
            held.kind,
            BindingKind::Const | BindingKind::Let | BindingKind::Var
        ) {
            return None;
        }

        let declarator = self.parent_at(held.node);

        if declarator == NONE || self.role_of(declarator) != Role::VariableDeclarator {
            return None;
        }

        let value = self.last_at(declarator);

        matches!(
            self.role_of(value),
            Role::ArrowFunction | Role::Class | Role::FunctionExpression
        )
        .then_some(value)
    }

    fn parent_at(&self, node: u32) -> u32 {
        if self.typed {
            return self.typed_tree.at(node).parent;
        }

        self.tree.at(node).parent
    }

    fn last_at(&self, node: u32) -> u32 {
        if self.typed {
            return last_child(&self.typed_tree, node);
        }

        last_child(&self.tree, node)
    }

    fn discarded(&self, reference: &Reference, scope: u32) -> bool {
        if self.functional(reference.scope) == self.functional(scope) {
            return false;
        }

        self.role_above(reference.node, 1) == Some(Role::UpdateExpression)
            && self.role_above(reference.node, 2) == Some(Role::ExpressionStatement)
    }

    fn role_above(&self, node: u32, steps: u32) -> Option<Role> {
        let mut held = node;

        for _ in 0..steps {
            held = if self.typed {
                self.typed_tree.as_slice().get(held as usize)?.parent
            } else {
                self.tree.as_slice().get(held as usize)?.parent
            };

            if held == NONE {
                return None;
            }
        }

        if self.typed {
            return Some(self.typed_tree.as_slice().get(held as usize)?.kind.role());
        }

        Some(self.tree.as_slice().get(held as usize)?.kind.role())
    }

    fn functional(&self, scope: u32) -> u32 {
        let mut held = scope;

        for _ in 0..=self.semantic.scopes().len() {
            let found = self.semantic.scopes()[held as usize];

            if matches!(
                found.kind,
                ScopeKind::Function | ScopeKind::Global | ScopeKind::Module
            ) || found.parent == NONE
            {
                return held;
            }

            held = found.parent;
        }

        held
    }

    fn names_itself(&self, index: u32) -> bool {
        let held = self.semantic.bindings()[index as usize];

        self.semantic.scopes()[held.scope as usize].node == held.node
    }

    fn unused_parameters(&self, source: &[u8], found: &mut Vec<(String, u32)>) {
        let mut used = vec![0_u8; self.semantic.scopes().len()];

        for index in 0..self.semantic.count() {
            let held = self.semantic.bindings()[index as usize];

            let held_property = held.kind == BindingKind::ParameterProperty;

            if !(held.kind == BindingKind::Parameter || held_property)
                || held.parameter == PARAMETER_NONE
            {
                continue;
            }

            if !held_property && !self.read(source, index) && !self.shadowed(source, index) {
                continue;
            }

            if spread_at(source, held.name.offset) {
                continue;
            }

            let seen = &mut used[held.scope as usize];
            *seen = (*seen).max(held.parameter);
        }

        for index in 0..self.semantic.count() {
            let held = self.semantic.bindings()[index as usize];

            if held.kind != BindingKind::Parameter || held.parameter == PARAMETER_NONE {
                continue;
            }

            if held.parameter < used[held.scope as usize] && !self.patterned(held.node) {
                continue;
            }

            if self.read(source, index) || self.shadowed(source, index) {
                continue;
            }

            if ignorable(held.kind, &source[held.name.range()]) {
                continue;
            }

            if !spread_at(source, held.name.offset) && self.overriding(source, held.scope) {
                continue;
            }

            if self.setting(source, held.scope) {
                continue;
            }

            found.push(("no-unused-vars".to_owned(), held.name.offset));
        }
    }

    fn queried(&self, node: u32) -> bool {
        if !self.typed || node == NONE {
            return false;
        }

        let nodes = self.typed_tree.as_slice();
        let mut held = node;

        for _ in 0..nodes.len() {
            let Some(found) = nodes.get(held as usize) else {
                return false;
            };

            if found.parent == NONE {
                return false;
            }

            let Some(parent) = nodes.get(found.parent as usize) else {
                return false;
            };

            if parent.kind == TypeScriptKind::TypeQuery {
                return true;
            }

            if parent.kind != TypeScriptKind::MemberExpression {
                return false;
            }

            held = found.parent;
        }

        false
    }

    fn overriding(&self, source: &[u8], scope: u32) -> bool {
        self.accessed(source, scope, b"override")
    }

    fn patterned(&self, node: u32) -> bool {
        if self.typed {
            return pattern_above(&self.typed_tree, node);
        }

        pattern_above(&self.tree, node)
    }

    fn setting(&self, source: &[u8], scope: u32) -> bool {
        self.accessed(source, scope, b"set")
    }

    fn accessed(&self, source: &[u8], scope: u32, word: &[u8]) -> bool {
        let Some(signature) = self.signature(source, scope) else {
            return false;
        };

        let mut words = signature
            .split(u8::is_ascii_whitespace)
            .filter(|found| !found.is_empty());

        words.any(|found| found == word) && words.next().is_some()
    }

    fn signature<'source>(&self, source: &'source [u8], scope: u32) -> Option<&'source [u8]> {
        let held = self.semantic.scopes()[scope as usize];

        if held.node == NONE {
            return None;
        }

        let span = if self.typed {
            let node = self.typed_tree.as_slice().get(held.node as usize)?;

            node.span(self.typed_tokens.as_slice())
        } else {
            let node = self.tree.as_slice().get(held.node as usize)?;

            node.span(self.tokens.as_slice())
        };

        let text = source.get(span.range())?;

        Some(text.split(|byte| *byte == b'(').next().unwrap_or(text))
    }

    fn shadowed(&self, source: &[u8], index: u32) -> bool {
        let held = self.semantic.bindings()[index as usize];
        let name = &source[held.name.range()];

        for later in index + 1..self.semantic.count() {
            let found = self.semantic.bindings()[later as usize];

            if found.scope != held.scope || &source[found.name.range()] != name {
                continue;
            }

            return true;
        }

        false
    }

    fn redeclared(&self, source: &[u8], found: &mut Vec<(String, u32)>) {
        let script = self.semantic.scopes()[0].kind == ScopeKind::Global;

        for index in 0..self.semantic.count() {
            let held = self.semantic.bindings()[index as usize];

            if !declares(held.kind) {
                continue;
            }

            let name = &source[held.name.range()];

            if self.names_itself(index) {
                if script && shadows_a_global(name) {
                    found.push(("no-redeclare".to_owned(), held.name.offset));
                }

                continue;
            }

            let scope = self.namespaced(held.scope);
            let mut earlier = false;

            for before in 0..index {
                let seen = self.semantic.bindings()[before as usize];

                if self.namespaced(seen.scope) != scope
                    || &source[seen.name.range()] != name
                {
                    continue;
                }

                earlier = declares(seen.kind) && !self.names_itself(before);
            }

            if !(earlier || script && shadows_a_global(name)) {
                continue;
            }

            found.push(("no-redeclare".to_owned(), held.name.offset));
        }
    }

    fn namespaced(&self, scope: u32) -> u32 {
        let held = self.semantic.scopes()[scope as usize];

        if held.kind != ScopeKind::Block || held.parent == NONE {
            return scope;
        }

        let above = self.semantic.scopes()[held.parent as usize];

        if above.node == NONE || self.role_of(above.node) != Role::Namespace {
            return scope;
        }

        held.parent
    }

    fn role_of(&self, node: u32) -> Role {
        if self.typed {
            return self.typed_tree.at(node).kind.role();
        }

        self.tree.at(node).kind.role()
    }
}

fn suppressed(source: &[u8], code: &str, offset: u32) -> bool {
    if window(source, 0, b"eslint-disable").is_none() {
        return false;
    }

    let line = line_of(source, offset);
    let above = line_above(source, line);

    directive(source, line, b"eslint-disable-line", code)
        || above.is_some_and(|held| directive(source, held, b"eslint-disable-next-line", code))
        || blocked(source, line, code)
}

fn blocked(source: &[u8], line: (usize, usize), code: &str) -> bool {
    let mut held = (0, 0);
    let mut open = false;

    for _ in 0..=source.len() {
        if held.0 >= line.0 {
            break;
        }

        if directive(source, held, b"eslint-enable", code) {
            open = false;
        } else if directive(source, held, b"eslint-disable", code) {
            open = true;
        }

        match line_below(source, held) {
            Some(next) => held = next,
            None => break,
        }
    }

    open
}

fn directive(source: &[u8], line: (usize, usize), word: &[u8], code: &str) -> bool {
    let text = &source[line.0..line.1];
    let mut at = 0;

    while at + word.len() <= text.len() {
        let Some(found) = window(text, at, word) else {
            return false;
        };

        at = found + word.len();

        let rest = &text[at..];

        if rest.first().is_some_and(|byte| is_name_byte(*byte) || *byte == b'-') {
            continue;
        }

        if covers(rest, code) {
            return true;
        }
    }

    false
}

fn window(text: &[u8], from: usize, word: &[u8]) -> Option<usize> {
    (from..=text.len().saturating_sub(word.len())).find(|at| &text[*at..at + word.len()] == word)
}

fn covers(rest: &[u8], code: &str) -> bool {
    let mut held = rest;

    if let Some(at) = window(held, 0, b"--") {
        held = &held[..at];
    }

    for closer in [&b"*/"[..], &b"\n"[..]] {
        if let Some(at) = window(held, 0, closer) {
            held = &held[..at];
        }
    }

    let mut named = false;

    for part in held.split(|byte| *byte == b',') {
        let trimmed = trim(part);

        if trimmed.is_empty() {
            continue;
        }

        named = true;

        if trimmed == code.as_bytes() {
            return true;
        }
    }

    !named
}

fn trim(text: &[u8]) -> &[u8] {
    let mut start = 0;
    let mut end = text.len();

    while start < end && text[start].is_ascii_whitespace() {
        start += 1;
    }

    while end > start && text[end - 1].is_ascii_whitespace() {
        end -= 1;
    }

    &text[start..end]
}

fn line_of(source: &[u8], offset: u32) -> (usize, usize) {
    let held = (offset as usize).min(source.len());
    let start = source[..held].iter().rposition(|byte| *byte == b'\n').map_or(0, |at| at + 1);
    let end = source[held..]
        .iter()
        .position(|byte| *byte == b'\n')
        .map_or(source.len(), |at| held + at);

    (start, end)
}

fn line_above(source: &[u8], line: (usize, usize)) -> Option<(usize, usize)> {
    if line.0 == 0 {
        return None;
    }

    Some(line_of(source, u32::try_from(line.0 - 1).ok()?))
}

fn line_below(source: &[u8], line: (usize, usize)) -> Option<(usize, usize)> {
    if line.1 >= source.len() {
        return None;
    }

    Some(line_of(source, u32::try_from(line.1 + 1).ok()?))
}

fn shadows_a_global(name: &[u8]) -> bool {
    name != b"arguments" && GLOBALS.contains(&name)
}

const fn merges(kind: BindingKind) -> bool {
    matches!(
        kind,
        BindingKind::Enum
            | BindingKind::Interface
            | BindingKind::Namespace
            | BindingKind::TypeAlias
    )
}

const fn declares(kind: BindingKind) -> bool {
    !matches!(kind, BindingKind::Signature | BindingKind::TypeParameter)
}

fn spread_at(source: &[u8], offset: u32) -> bool {
    let mut held = offset as usize;

    while held > 0 && source[held - 1].is_ascii_whitespace() {
        held -= 1;
    }

    held >= 3 && &source[held - 3..held] == b"..."
}

fn typeof_at(source: &[u8], offset: u32) -> bool {
    let mut held = offset as usize;

    while held > 0 && source[held - 1].is_ascii_whitespace() {
        held -= 1;
    }

    let word = b"typeof";

    if held < word.len() {
        return false;
    }

    if &source[held - word.len()..held] != word {
        return false;
    }

    if held != word.len() && is_name_byte(source[held - word.len() - 1]) {
        return false;
    }

    let mut after = offset as usize;

    while after < source.len() && is_name_byte(source[after]) {
        after += 1;
    }

    while after < source.len() && source[after].is_ascii_whitespace() {
        after += 1;
    }

    !matches!(source.get(after), Some(b'.' | b'[' | b'('))
}

const fn is_name_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'$' | b'_')
}

fn ignorable(kind: BindingKind, name: &[u8]) -> bool {
    if kind == BindingKind::CatchParameter {
        return false;
    }

    if !name.starts_with(b"_") {
        return false;
    }

    kind != BindingKind::Parameter || name.len() > 1
}

const fn escapes(role: Role) -> bool {
    matches!(
        role,
        Role::Arguments
            | Role::ArrowFunction
            | Role::ClassStaticBlock
            | Role::FunctionDeclaration
            | Role::FunctionExpression
            | Role::MethodDefinition
    )
}

fn thrown<K>(tree: &Tree<K>, tokens: &[Token], source: &[u8], node: u32, name: &[u8]) -> bool
where
    K: Kind + Kinds,
{
    if sequence_term(tree, node) {
        return true;
    }

    if looped(tree, node) {
        return false;
    }

    if update_target(tree, node) {
        return discarded_value(tree, tree.at(node).parent);
    }

    let mut child = node;

    for _ in 0..=tree.count() {
        let parent = tree.at(child).parent;

        if parent == NONE {
            return false;
        }

        let role = tree.at(parent).kind.role();

        if escapes(role) {
            return false;
        }

        if matches!(role, Role::AssignmentExpression | Role::AugmentedAssignment) {
            return last_child(tree, parent) == child
                && names(tree, tokens, source, tree.at(parent).child_first, name)
                && discarded_value(tree, parent);
        }

        child = parent;
    }

    false
}

fn looped<K>(tree: &Tree<K>, node: u32) -> bool
where
    K: Kind + Kinds,
{
    let mut held = node;

    for _ in 0..=tree.count() {
        if held == NONE {
            return false;
        }

        let kind = tree.at(held).kind;

        if kind.category() == Category::Loop {
            return true;
        }

        if escapes(kind.role()) {
            return false;
        }

        held = tree.at(held).parent;
    }

    false
}

fn update_target<K>(tree: &Tree<K>, node: u32) -> bool
where
    K: Kind + Kinds,
{
    let parent = tree.at(node).parent;

    parent != NONE
        && tree.at(parent).kind.role() == Role::AugmentedAssignment
        && tree.at(parent).child_first == node
}

fn sequence_term<K>(tree: &Tree<K>, node: u32) -> bool
where
    K: Kind + Kinds,
{
    let parent = tree.at(node).parent;

    parent != NONE
        && tree.at(parent).kind.role() == Role::SequenceExpression
        && last_child(tree, parent) != node
}

fn discarded_value<K>(tree: &Tree<K>, node: u32) -> bool
where
    K: Kind + Kinds,
{
    let mut child = node;

    for _ in 0..=tree.count() {
        let parent = tree.at(child).parent;

        if parent == NONE {
            return false;
        }

        let role = tree.at(parent).kind.role();

        if role == Role::ExpressionStatement {
            return true;
        }

        if role != Role::SequenceExpression {
            return false;
        }

        if last_child(tree, parent) != child {
            return true;
        }

        child = parent;
    }

    false
}

fn names<K>(tree: &Tree<K>, tokens: &[Token], source: &[u8], node: u32, name: &[u8]) -> bool
where
    K: Kind + Kinds,
{
    node != NONE
        && tree.at(node).kind.role() == Role::IdentifierNode
        && &source[tree.at(node).span(tokens).range()] == name
}

fn last_child<K>(tree: &Tree<K>, node: u32) -> u32
where
    K: Kind,
{
    let mut child = tree.at(node).child_first;
    let mut last = NONE;

    for _ in 0..=tree.count() {
        if child == NONE {
            return last;
        }

        last = child;
        child = tree.at(child).sibling_next;
    }

    last
}

fn inside<K>(tree: &Tree<K>, node: u32, ancestor: u32) -> bool
where
    K: Kind,
{
    let mut held = node;

    for _ in 0..=tree.count() {
        if held == ancestor {
            return true;
        }

        if held == NONE {
            return false;
        }

        held = tree.at(held).parent;
    }

    false
}

fn pattern_above<K>(tree: &Tree<K>, node: u32) -> bool
where
    K: Kind + Kinds,
{
    let mut held = node;

    for _ in 0..=tree.count() {
        if held == NONE {
            return false;
        }

        let role = tree.at(held).kind.role();

        if matches!(role, Role::ArrayPattern | Role::ObjectPattern) {
            return true;
        }

        if role == Role::FormalParameters {
            return false;
        }

        held = tree.at(held).parent;
    }

    false
}

const fn reportable(kind: BindingKind) -> bool {
    matches!(
        kind,
        BindingKind::CatchParameter
            | BindingKind::Class
            | BindingKind::Const
            | BindingKind::Enum
            | BindingKind::Function
            | BindingKind::Import
            | BindingKind::ImportDefault
            | BindingKind::ImportNamespace
            | BindingKind::ImportType
            | BindingKind::Interface
            | BindingKind::Let
            | BindingKind::Namespace
            | BindingKind::TypeAlias
            | BindingKind::TypeParameter
            | BindingKind::Var
    )
}

fn corpus() -> Vec<Fixture> {
    let Some(held) = corpus::root() else {
        return Vec::new();
    };

    let mut found = Vec::new();

    collect(&held, &held, &mut found);
    found.sort_by(|left, right| left.name.cmp(&right.name));

    found
}

fn fixtures() -> Vec<Fixture> {
    let mut found = Vec::new();

    for name in [
        "tests/fixtures/javascript-semantic",
        "tests/fixtures/typescript-semantic",
    ] {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(name);

        if !root.is_dir() {
            continue;
        }

        collect(&root, &root, &mut found);
    }

    found.sort_by(|left, right| left.name.cmp(&right.name));

    found
}

fn collect(root: &Path, base: &Path, found: &mut Vec<Fixture>) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };

    let mut stack: Vec<PathBuf> = entries
        .filter_map(|entry| Some(entry.ok()?.path()))
        .collect();

    while let Some(path) = stack.pop() {
        if path.is_dir() {
            let Ok(nested) = fs::read_dir(&path) else {
                continue;
            };

            stack.extend(nested.filter_map(|entry| Some(entry.ok()?.path())));

            continue;
        }

        let extension = path.extension().and_then(|held| held.to_str());

        let dialect = match extension {
            Some("cjs" | "js" | "mjs") => None,
            Some(held) => match Dialect::of_extension(held) {
                None => continue,
                Some(dialect) => Some(dialect),
            },
            None => continue,
        };

        let Ok(source) = fs::read(&path) else {
            continue;
        };

        let name = path
            .strip_prefix(base)
            .unwrap_or(&path)
            .to_string_lossy()
            .replace('\\', "/");

        found.push(Fixture {
            dialect,
            name,
            source,
        });
    }
}

fn golden(root: &Path, name: &str) -> Option<(Vec<(String, u32)>, bool)> {
    let path = root.join(format!("{name}.json"));
    let text = fs::read(&path).ok()?;
    let broken = find(&text, b"\"broken\":true").is_some();
    let mut found = Vec::new();

    let Some(start) = find(&text, b"\"ast\":[") else {
        return Some((found, broken));
    };

    let mut offset = start + b"\"ast\":[".len();

    while offset < text.len() && text[offset] == b'[' {
        let Some((code, after)) = quoted(&text, offset) else {
            break;
        };

        let (position, tail) = number(&text, after);

        found.push((code, position));

        offset = tail;

        if offset < text.len() && text[offset] == b']' {
            offset += 1;
        }

        if offset < text.len() && text[offset] == b',' {
            offset += 1;

            continue;
        }

        break;
    }

    found.sort();

    Some((found, broken))
}

fn find(text: &[u8], key: &[u8]) -> Option<usize> {
    text.windows(key.len()).position(|window| window == key)
}

fn number(text: &[u8], from: usize) -> (u32, usize) {
    let mut offset = from;

    while offset < text.len() && !text[offset].is_ascii_digit() {
        offset += 1;
    }

    let mut value = 0_u32;

    while offset < text.len() && text[offset].is_ascii_digit() {
        value = value * 10 + u32::from(text[offset] - b'0');
        offset += 1;
    }

    (value, offset)
}

fn quoted(text: &[u8], from: usize) -> Option<(String, usize)> {
    let mut offset = from;

    while offset < text.len() && text[offset] != b'"' {
        offset += 1;
    }

    if offset >= text.len() {
        return None;
    }

    offset += 1;

    let mut found = String::new();

    while offset < text.len() {
        let byte = text[offset];

        offset += 1;

        if byte == b'"' {
            return Some((found, offset));
        }

        found.push(byte as char);
    }

    None
}

fn diverges(machine: &mut Machine, root: &Path, fixture: &Fixture) -> bool {
    let Some((expected, broken)) = golden(root, &fixture.name) else {
        return true;
    };

    if broken {
        return true;
    }

    if machine.run_fixture(fixture) != Structure::Complete {
        return true;
    }

    machine.rows(&fixture.source) != expected
}

fn report(name: &str, held: &[(String, u32)], expected: &[(String, u32)]) -> String {
    use core::fmt::Write as _;

    let mut lines = format!("{name}: the rows differ\n");
    let mut shown = 0;
    let mut mine = 0;
    let mut theirs = 0;

    while shown < 24 && (mine < held.len() || theirs < expected.len()) {
        if theirs >= expected.len() || (mine < held.len() && held[mine] < expected[theirs]) {
            let row = &held[mine];
            let _ = writeln!(lines, "  extra   {} {}", row.0, row.1);

            mine += 1;
            shown += 1;

            continue;
        }

        if mine >= held.len() || expected[theirs] < held[mine] {
            let row = &expected[theirs];
            let _ = writeln!(lines, "  missing {} {}", row.0, row.1);

            theirs += 1;
            shown += 1;

            continue;
        }

        mine += 1;
        theirs += 1;
    }

    lines
}

#[test]
fn the_model_is_total_over_the_fixtures() {
    let found = fixtures();

    assert!(
        !found.is_empty(),
        "tests/fixtures/javascript-semantic holds no source"
    );

    let mut machine = Machine::reserve();

    for fixture in &found {
        let outcome = machine.run_fixture(fixture);

        assert_eq!(outcome, Structure::Complete, "{}", fixture.name);
        assert!(machine.semantic.count() > 0, "{}", fixture.name);

        let count = count_of(machine.semantic.scopes().len());

        for held in machine.semantic.scopes() {
            assert!(held.parent == NONE || held.parent < count);
        }

        for held in machine.semantic.bindings() {
            assert!(held.scope < count);
            assert!(held.name.end() as usize <= fixture.source.len());
        }
    }
}

#[test]
fn every_scope_a_reference_resolves_into_is_on_its_own_chain() {
    let found = fixtures();

    assert!(
        !found.is_empty(),
        "tests/fixtures/javascript-semantic holds no source"
    );

    let mut machine = Machine::reserve();

    for fixture in &found {
        let _ = machine.run_fixture(fixture);

        for held in machine.semantic.references() {
            let Resolution::Bound(index) = held.resolution else {
                continue;
            };

            let binding = machine.semantic.bindings()[index as usize];
            let mut scope = held.scope;
            let mut steps = 0;
            let mut walked = false;

            while scope != NONE && steps <= 1 << 8 {
                if scope == binding.scope {
                    walked = true;

                    break;
                }

                scope = machine.semantic.scopes()[scope as usize].parent;
                steps += 1;
            }

            assert!(
                walked,
                "{}: a reference resolves outside its own scope chain",
                fixture.name
            );
        }
    }
}

#[test]
fn the_root_scope_reports_the_module_kind_the_source_wrote() {
    let mut machine = Machine::reserve();

    let _ = machine.run(b"var held = 1;\n");

    assert_eq!(machine.semantic.scopes()[0].kind, ScopeKind::Global);

    let _ = machine.run(b"export const held = 1;\n");

    assert_eq!(machine.semantic.scopes()[0].kind, ScopeKind::Module);
}

#[test]
fn every_fixture_reports_the_rows_oxlint_reports() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-oxlint");
    let carried = oracle::residue_of("residue-javascript-semantic.json", &EVERY_CATEGORY);
    let found = fixtures();

    assert!(
        !found.is_empty(),
        "tests/fixtures/javascript-semantic holds no source"
    );

    let mut machine = Machine::reserve();
    let mut compared = 0;

    for fixture in &found {
        if carried.contains(&fixture.name) {
            continue;
        }

        let (expected, broken) = golden(&root, &fixture.name)
            .unwrap_or_else(|| panic!("{} has no golden", fixture.name));

        if broken {
            continue;
        }

        let _ = machine.run_fixture(fixture);

        let held = machine.rows(&fixture.source);

        assert!(
            held == expected,
            "{}",
            report(&fixture.name, &held, &expected)
        );

        compared += 1;
    }

    assert!(
        compared >= floor::FIXTURE_SEMANTIC_JAVASCRIPT,
        "the JavaScript fixtures lost a binding table: {compared} compared, floor {}",
        floor::FIXTURE_SEMANTIC_JAVASCRIPT
    );
}

#[test]
fn the_corpus_reports_the_rows_oxlint_reports() {
    let Some(held) = corpus::oxlint() else {
        return;
    };

    let found = corpus();

    if found.is_empty() {
        return;
    }

    let carried = oracle::residue_of("residue-javascript-semantic.json", &EVERY_CATEGORY);
    let mut abstained = 0;
    let mut machine = Machine::reserve();
    let mut differing = Vec::new();
    let mut compared = 0;

    for fixture in &found {
        if carried.contains(&fixture.name) {
            continue;
        }

        let Some((expected, broken)) = golden(&held, &fixture.name) else {
            abstained += 1;

            continue;
        };

        if broken {
            continue;
        }

        if machine.run_fixture(fixture) != Structure::Complete {
            continue;
        }

        let rows = machine.rows(&fixture.source);

        if rows != expected {
            differing.push(report(&fixture.name, &rows, &expected));
        }

        compared += 1;
    }

    assert!(
        compared >= floor::CORPUS_SEMANTIC_JAVASCRIPT,
        "the corpus lost its JavaScript files: {compared} compared, {abstained} abstained, floor {}",
        floor::CORPUS_SEMANTIC_JAVASCRIPT
    );

    if !differing.is_empty() {
        if let Ok(path) = std::env::var("SCYLLA_REPORT") {
            fs::write(path, differing.join("")).expect("the report is writable");
        }

        let shown: Vec<&String> = differing.iter().take(3).collect();

        panic!(
            "{} of {compared} corpus files differ\n{}",
            differing.len(),
            shown
                .iter()
                .map(|line| line.as_str())
                .collect::<Vec<&str>>()
                .join("")
        );
    }
}

#[test]
fn every_residue_row_names_a_file_that_diverges() {
    let carried = oracle::residue_of("residue-javascript-semantic.json", &EVERY_CATEGORY);
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-oxlint");
    let mut machine = Machine::reserve();
    let mut named = Vec::new();

    for fixture in &fixtures() {
        if !carried.contains(&fixture.name) {
            continue;
        }

        named.push(fixture.name.clone());

        assert!(
            diverges(&mut machine, &root, fixture),
            "{} matches its golden and needs no residue row",
            fixture.name
        );
    }

    let Some(held) = corpus::oxlint() else {
        return;
    };

    for fixture in &corpus() {
        if !carried.contains(&fixture.name) {
            continue;
        }

        named.push(fixture.name.clone());

        assert!(
            diverges(&mut machine, &held, fixture),
            "{} matches its corpus golden and needs no residue row",
            fixture.name
        );
    }

    for name in &carried {
        assert!(
            named.contains(name),
            "the residue names `{name}` and neither the fixtures nor the corpus carry it"
        );
    }
}
