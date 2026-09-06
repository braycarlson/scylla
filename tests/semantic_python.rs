#[path = "common/corpus.rs"]
mod corpus;
#[path = "common/floor.rs"]
mod floor;
#[path = "common/oracle.rs"]
mod oracle;

use std::fs;
use std::path::{Path, PathBuf};

use scylla::bounded::BoundedVec;
use scylla::bounded::Span;
use scylla::language::Lexer as _;
use scylla::lex::PYTHON;
use scylla::lines;
use scylla::suppress::{self, Suppressions};
use scylla::syntax::python::bind::{self, Outcome as BindOutcome, ScopeKind, Tables};
use scylla::syntax::python::check::{self, CheckError, Completion};
use scylla::syntax::python::classify::classify;
use scylla::syntax::python::kind::PythonKind;
use scylla::syntax::python::parse;
use scylla::syntax::python::semantic::{
    AnnotationScratch,
    Binding,
    BindingKind,
    Context,
    Reference,
    Resolution,
    Semantic,
    SemanticInput,
};
use scylla::syntax::python::stdlib::PythonVersion;
use scylla::token::{Lex, TokenKind, Tokens};
use scylla::tree::{Events, NONE, Structure, Tree};

const ANNOTATION_COUNT_MAX: u32 = 1 << 8;
const BINDING_COUNT_MAX: u32 = 1 << 16;
const ERROR_COUNT_MAX: u32 = 1 << 10;
const EVENT_COUNT_MAX: u32 = 1 << 21;
const EVERY_CATEGORY: [&str; 4] = ["check", "model", "not-python", "ruff"];
const EXPORT_COUNT_MAX: u32 = 1 << 12;
const FILE_PREFIXES: [&[u8]; 2] = [b"flake8:", b"ruff:"];
const MODULE_SCOPE: u32 = 0;
const LINE_COUNT_MAX: u32 = 1 << 16;
const NODE_COUNT_MAX: u32 = 1 << 19;
const CHECK_VERSION: PythonVersion = PythonVersion::Py314;
const PYTHON_VERSION: PythonVersion = PythonVersion::Py310;
const REFERENCE_COUNT_MAX: u32 = 1 << 18;
const SCOPE_COUNT_MAX: u32 = 1 << 12;
const SEGMENT_COUNT_MAX: u32 = 1 << 14;
const TOKEN_COUNT_MAX: u32 = 1 << 19;

struct Fixture {
    name: String,
    source: Vec<u8>,
}

struct Machine {
    annotations: AnnotationScratch,
    checks: BoundedVec<CheckError>,
    comments: BoundedVec<Span>,
    events: Events<PythonKind>,
    index: lines::Index,
    lexed: Tokens,
    names: BoundedVec<Span>,
    raw: BoundedVec<PythonKind>,
    semantic: Semantic,
    suppressions: Suppressions,
    tables: Tables,
    tokens: Tokens,
    tree: Tree<PythonKind>,
}

impl Machine {
    fn reserve() -> Self {
        Self {
            annotations: AnnotationScratch::reserve(ANNOTATION_COUNT_MAX, ANNOTATION_COUNT_MAX),
            checks: BoundedVec::reserve(ERROR_COUNT_MAX),
            comments: BoundedVec::reserve(TOKEN_COUNT_MAX),
            events: Events::reserve(EVENT_COUNT_MAX),
            index: lines::Index::reserve(LINE_COUNT_MAX),
            lexed: Tokens::reserve(TOKEN_COUNT_MAX),
            names: BoundedVec::reserve(BINDING_COUNT_MAX),
            raw: BoundedVec::reserve(TOKEN_COUNT_MAX),
            semantic: Semantic::reserve(BINDING_COUNT_MAX, REFERENCE_COUNT_MAX, EXPORT_COUNT_MAX),
            tables: Tables::reserve(
                SCOPE_COUNT_MAX,
                BINDING_COUNT_MAX,
                REFERENCE_COUNT_MAX,
                SEGMENT_COUNT_MAX,
            ),
            suppressions: Suppressions::reserve(BINDING_COUNT_MAX, BINDING_COUNT_MAX),
            tokens: Tokens::reserve(TOKEN_COUNT_MAX),
            tree: Tree::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX),
        }
    }

    fn suppress(&mut self, source: &[u8]) -> bool {
        self.comments.clear();

        for token in self.lexed.as_slice() {
            if token.kind != TokenKind::Comment {
                continue;
            }

            if !self.comments.push(token.span()) {
                return false;
            }
        }

        self.suppressions.scan(
            source,
            self.comments.iter().copied(),
            b"noqa",
            &FILE_PREFIXES,
            &self.index,
        );

        self.suppressions
            .join(source, self.lexed.as_slice(), &self.index)
    }

    fn run(&mut self, source: &[u8]) -> bool {
        self.lexed.clear();

        if PYTHON.lex(source, &mut self.lexed) != Lex::Complete {
            return false;
        }

        if !classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw,
        ) {
            return false;
        }

        let structure = parse::build(
            source,
            self.tokens.as_slice(),
            &self.raw,
            &mut self.events,
            &mut self.tree,
        );

        if structure != Structure::Complete {
            return false;
        }

        if bind::bind(
            source,
            self.tokens.as_slice(),
            &self.raw,
            &self.tree,
            &mut self.tables,
        ) != BindOutcome::Complete
        {
            return false;
        }

        if !self.index.build(source) {
            return false;
        }

        if !self.suppress(source) {
            return false;
        }

        if self.semantic.build(
            &SemanticInput {
                builtins: &[],
                raw: &self.raw,
                scopes: &self.tables,
                source,
                tokens: self.tokens.as_slice(),
                tree: &self.tree,
                version: PYTHON_VERSION,
            },
            &mut self.annotations,
        ) != Structure::Complete
        {
            return false;
        }

        check::check(
            &check::Input {
                raw: &self.raw,
                semantic: &self.semantic,
                source,
                tokens: self.tokens.as_slice(),
                tree: &self.tree,
                version: CHECK_VERSION,
            },
            &mut self.checks,
            &mut self.names,
        ) == Completion::Complete
    }

    fn errored(&self) -> bool {
        !self.tree.errors().is_empty()
    }

    fn rows(&self, source: &[u8]) -> Vec<(String, u32, u32)> {
        let mut found = Vec::new();

        self.unused_imports(source, &mut found);
        self.redefinitions(source, &mut found);
        self.undefined(source, &mut found);
        self.unused_variables(source, &mut found);
        self.checked(&mut found);

        found.retain(|row| !self.suppressed(source, row));
        found.sort();

        found
    }

    fn suppressed(&self, source: &[u8], row: &(String, u32, u32)) -> bool {
        if row.0 == "invalid-syntax" {
            return false;
        }

        self.suppressions
            .matches(row.1 - 1, row.0.as_bytes(), source)
            != suppress::NONE
    }

    fn checked(&self, found: &mut Vec<(String, u32, u32)>) {
        for held in self.checks.iter() {
            let (line, column) = self.place(held.span.offset);

            found.push((held.kind.code().to_owned(), line, column));
        }
    }

    fn suppressed_at(&self, source: &[u8], code: &str, node: u32) -> bool {
        let span = self.tree.at(node).span(self.tokens.as_slice());
        let line = self.index.line_of(span.offset);

        self.suppressions.matches(line, code.as_bytes(), source) != suppress::NONE
    }

    fn place(&self, offset: u32) -> (u32, u32) {
        let line = self.index.line_of(offset);

        (line + 1, offset - self.index.line_start(line) + 1)
    }

    fn unused_imports(&self, source: &[u8], found: &mut Vec<(String, u32, u32)>) {
        for (index, held) in self.semantic.bindings().iter().enumerate() {
            if !matches!(
                held.kind,
                BindingKind::Import | BindingKind::ImportFrom | BindingKind::SubmoduleImport
            ) {
                continue;
            }

            let position = u32::try_from(index).expect("a bounded index fits in u32");

            if self.semantic.is_used(position) || held.flags.shadowed {
                continue;
            }

            if held.flags.export_explicit {
                continue;
            }

            if self.semantic.scopes()[held.scope as usize].kind == ScopeKind::Class {
                continue;
            }

            let statement = self.tree.at(held.node).parent;

            if statement != NONE && self.suppressed_at(source, "F401", statement) {
                continue;
            }

            if held.flags.deleted || held.flags.alias {
                continue;
            }

            if self.package_alias_used(source, held) {
                continue;
            }

            let (line, column) = self.place(held.name.offset);

            found.push(("F401".to_owned(), line, column));
        }
    }

    fn package_alias_used(&self, source: &[u8], held: &Binding) -> bool {
        if held.kind != BindingKind::SubmoduleImport {
            return false;
        }

        let name = &source[held.name.range()];

        self.tables.imports.iter().any(|import| {
            let alias = &source[import.alias.range()];

            if import.level != 0 || import.segment_count != 1 || alias == name {
                return false;
            }

            let Some(segment) = self.tables.segments.get(import.segment_first as usize) else {
                return false;
            };

            &source[segment.range()] == name
                && self
                    .semantic
                    .is_used(self.semantic.binding_newest(source, held.scope, alias))
        })
    }

    fn binds_a_lambda(&self, held: &Binding) -> bool {
        if held.kind != BindingKind::Assignment || held.node == NONE {
            return false;
        }

        let parent = self.tree.at(held.node).parent;

        if parent == NONE {
            return false;
        }

        let mut child = self.tree.at(parent).child_first;

        for _ in 0..=self.tree.count() {
            if child == NONE {
                return false;
            }

            if self.tree.at(child).kind == PythonKind::Lambda {
                return true;
            }

            child = self.tree.at(child).sibling_next;
        }

        false
    }

    fn reads_locals(&self, source: &[u8], scope: u32) -> bool {
        self.semantic.references().iter().any(|reference| {
            reference.scope == scope && &source[reference.name.range()] == b"locals"
        })
    }

    fn redefinitions(&self, source: &[u8], found: &mut Vec<(String, u32, u32)>) {
        for held in self.semantic.bindings() {
            if !(definition(held.kind) || self.binds_a_lambda(held)) || held.previous == NONE {
                continue;
            }

            let Some(earlier) = self.semantic.get(held.previous) else {
                continue;
            };

            if held.scope == MODULE_SCOPE
                && !self.stands_at_module_level(self.tree.at(held.node).parent)
            {
                continue;
            }

            if !shadowable(earlier.kind) || self.semantic.is_used(held.previous) {
                continue;
            }

            if self.read_between(source, earlier, held) {
                continue;
            }

            if held.flags.private {
                continue;
            }

            if !self.semantic.same_branch(earlier.branch, held.branch) {
                continue;
            }

            if earlier.flags.overload || held.flags.overload {
                continue;
            }

            let (line, column) = self.place(held.name.offset);

            found.push(("F811".to_owned(), line, column));
        }

        for held in self.semantic.bindings() {
            if !self.shadows_an_import(source, held) && !self.shadows_a_global(source, held) {
                continue;
            }

            let (line, column) = self.place(held.name.offset);

            found.push(("F811".to_owned(), line, column));
        }
    }

    fn shadows_a_global(&self, source: &[u8], held: &Binding) -> bool {
        if !definition(held.kind) || held.scope != MODULE_SCOPE {
            return false;
        }

        if !self.stands_at_module_level(self.tree.at(held.node).parent) {
            return false;
        }

        let name = &source[held.name.range()];

        self.semantic
            .bindings()
            .iter()
            .enumerate()
            .any(|(index, global)| {
                let position = u32::try_from(index).expect("a bounded index fits in u32");

                global.kind == BindingKind::Global
                    && &source[global.name.range()] == name
                    && !self.semantic.is_used(position)
                    && self
                        .hoist_of(global)
                        .is_some_and(|offset| offset <= held.name.offset)
            })
    }

    fn stands_at_module_level(&self, node: u32) -> bool {
        let mut held = node;

        for _ in 0..=self.tree.count() {
            if held == NONE {
                return true;
            }

            if matches!(
                self.tree.at(held).kind,
                PythonKind::AsyncFunctionDef | PythonKind::FunctionDef | PythonKind::Lambda
            ) {
                return false;
            }

            held = self.tree.at(held).parent;
        }

        false
    }

    fn hoist_of(&self, global: &Binding) -> Option<u32> {
        let owner = self.semantic.scopes().get(global.scope as usize)?;

        if owner.kind != ScopeKind::Function || !self.eager_in(owner.parent, MODULE_SCOPE) {
            return None;
        }

        Some(self.tree.at(owner.node).span(self.tokens.as_slice()).offset)
    }

    fn shadows_an_import(&self, source: &[u8], held: &Binding) -> bool {
        if held.previous != NONE || held.kind == BindingKind::Annotation {
            return false;
        }

        let name = &source[held.name.range()];
        let scopes = self.semantic.scopes();
        let mut scope = scopes[held.scope as usize].parent;

        for _ in 0..=scopes.len() {
            if scope == NONE {
                return false;
            }

            let index = self.semantic.binding_newest(source, scope, name);

            if index != NONE {
                return self.semantic.get(index).is_some_and(|earlier| {
                    imports(earlier.kind)
                        && !earlier.flags.export_explicit
                        && !earlier.flags.type_checking
                        && !self.semantic.is_used(index)
                        && self.same_module_path(source, earlier, held)
                });
            }

            scope = scopes[scope as usize].parent;
        }

        false
    }

    fn read_between(&self, source: &[u8], earlier: &Binding, held: &Binding) -> bool {
        let name = &source[held.name.range()];
        let point = self.effect_of(held);

        self.semantic.references().iter().any(|reference| {
            reference.context == Context::Load
                && reference.name.offset > earlier.name.offset
                && reference.name.offset < point
                && &source[reference.name.range()] == name
                && matches!(
                    reference.resolution,
                    Resolution::Bound(binding)
                        if self
                            .semantic
                            .get(binding)
                            .is_some_and(|target| target.scope == held.scope)
                )
                && self.eager_in(reference.scope, held.scope)
        })
    }

    fn same_module_path(&self, source: &[u8], earlier: &Binding, held: &Binding) -> bool {
        if earlier.kind != BindingKind::SubmoduleImport {
            return true;
        }

        let Some(left) = self.module_path(earlier) else {
            return false;
        };

        let Some(right) = self.module_path(held) else {
            return false;
        };

        left.len() == right.len()
            && left
                .iter()
                .zip(right)
                .all(|(one, two)| source[one.range()] == source[two.range()])
    }

    fn module_path(&self, held: &Binding) -> Option<&[Span]> {
        let import = self
            .tables
            .imports
            .iter()
            .find(|import| import.alias == held.name)?;

        let first = import.segment_first as usize;
        let end = first + import.segment_count as usize;

        self.tables.segments.get(first..end)
    }

    fn effect_of(&self, held: &Binding) -> u32 {
        if held.kind != BindingKind::ClassDefinition {
            return held.name.offset;
        }

        self.tree.at(held.node).span(self.tokens.as_slice()).end()
    }

    fn eager_in(&self, scope: u32, wanted: u32) -> bool {
        let scopes = self.semantic.scopes();
        let mut held = scope;

        for _ in 0..=scopes.len() {
            if held == wanted {
                return true;
            }

            let Some(named) = scopes.get(held as usize) else {
                return false;
            };

            if matches!(named.kind, ScopeKind::Function | ScopeKind::Lambda) {
                return false;
            }

            held = named.parent;
        }

        false
    }

    fn undefined(&self, source: &[u8], found: &mut Vec<(String, u32, u32)>) {
        for held in self.semantic.references() {
            let gone = match held.resolution {
                Resolution::Bound(binding) => {
                    held.context == Context::Load
                        && self
                            .semantic
                            .get(binding)
                            .is_some_and(|target| target.kind == BindingKind::Deletion)
                }
                Resolution::Builtin | Resolution::Maybe => false,
                Resolution::Unresolved => true,
            };

            if !gone {
                continue;
            }

            if self.probed_for_a_name(source, held.node) {
                continue;
            }

            if self.rebound_past_a_clause(held) {
                continue;
            }

            let (line, column) = self.place(held.name.offset);

            found.push(("F821".to_owned(), line, column));
        }
    }

    fn rebound_past_a_clause(&self, held: &Reference) -> bool {
        let Resolution::Bound(index) = held.resolution else {
            return false;
        };

        let Some(handler) = self.clause_of(index) else {
            return false;
        };

        let Some(clause) = self.semantic.get(handler) else {
            return false;
        };

        if clause.previous == NONE {
            return false;
        }

        let span = self.tree.at(clause.node).span(self.tokens.as_slice());
        let outside = held.name.offset < span.offset || held.name.offset >= span.end();

        outside && self.tree.at(clause.node).kind == PythonKind::ExceptHandler
    }

    fn clause_of(&self, deletion: u32) -> Option<u32> {
        let mut index = deletion;

        for _ in 0..=self.semantic.bindings().len() {
            let held = self.semantic.get(index)?;

            if held.kind == BindingKind::ExceptVariable {
                return Some(index);
            }

            index = held.previous;
        }

        None
    }

    fn probed_for_a_name(&self, source: &[u8], node: u32) -> bool {
        let mut child = node;
        let mut held = self.tree.at(node).parent;

        for _ in 0..=self.tree.count() {
            if held == NONE {
                return false;
            }

            let kind = self.tree.at(held).kind;

            if matches!(
                kind,
                PythonKind::AsyncFunctionDef | PythonKind::FunctionDef | PythonKind::Lambda
            ) {
                return false;
            }

            if kind == PythonKind::Try
                && self.tree.at(child).kind == PythonKind::Block
                && self.catches_a_name_error(source, held)
            {
                return true;
            }

            child = held;
            held = self.tree.at(held).parent;
        }

        false
    }

    fn catches_a_name_error(&self, source: &[u8], node: u32) -> bool {
        let mut child = self.tree.at(node).child_first;

        for _ in 0..=self.tree.count() {
            if child == NONE {
                return false;
            }

            if self.tree.at(child).kind == PythonKind::ExceptHandler
                && self.names_a_name_error(source, child)
            {
                return true;
            }

            child = self.tree.at(child).sibling_next;
        }

        false
    }

    fn names_a_name_error(&self, source: &[u8], handler: u32) -> bool {
        let held = self.tree.at(handler);
        let mut end = held.token_end;
        let mut child = held.child_first;

        for _ in 0..=self.tree.count() {
            if child == NONE {
                break;
            }

            if self.tree.at(child).kind == PythonKind::Block {
                end = self.tree.at(child).token_start;

                break;
            }

            child = self.tree.at(child).sibling_next;
        }

        let tokens = self.tokens.as_slice();

        (held.token_start..end).any(|position| {
            self.raw.get(position as usize) == Some(&PythonKind::Identifier)
                && tokens
                    .get(position as usize)
                    .is_some_and(|token| token.text(source) == b"NameError")
        })
    }

    fn unused_variables(&self, source: &[u8], found: &mut Vec<(String, u32, u32)>) {
        for (index, held) in self.semantic.bindings().iter().enumerate() {
            if !matches!(
                held.kind,
                BindingKind::Assignment
                    | BindingKind::ExceptVariable
                    | BindingKind::Named
                    | BindingKind::WithVariable
            ) {
                continue;
            }

            if held.kind == BindingKind::Assignment
                && held.flags.unpacked
                && !self.unpacks_a_display(held.node)
            {
                continue;
            }

            let position = u32::try_from(index).expect("a bounded index fits in u32");
            let alone = held.kind == BindingKind::ExceptVariable;

            if held.flags.shadowed && !alone {
                continue;
            }

            let scope = self.semantic.scopes()[held.scope as usize];

            if !alone && !matches!(scope.kind, ScopeKind::Function | ScopeKind::Lambda) {
                continue;
            }

            if held.flags.private {
                continue;
            }

            if self.reads_locals(source, held.scope) {
                continue;
            }

            let dropped = held.flags.deleted && !alone;

            let used = if alone {
                self.semantic.is_used(position) || self.read_in_the_clause(source, held)
            } else {
                self.semantic.chain_used(source, position)
            };

            if used || dropped {
                continue;
            }

            if self.declared_nonlocal(source, held) {
                continue;
            }

            let (line, column) = self.place(held.name.offset);

            found.push(("F841".to_owned(), line, column));
        }
    }

    fn read_in_the_clause(&self, source: &[u8], held: &Binding) -> bool {
        let name = &source[held.name.range()];
        let span = self.tree.at(held.node).span(self.tokens.as_slice());

        self.semantic.references().iter().any(|reference| {
            reference.context == Context::Load
                && reference.name.offset >= span.offset
                && reference.name.offset < span.end()
                && &source[reference.name.range()] == name
        })
    }

    fn declared_nonlocal(&self, source: &[u8], held: &Binding) -> bool {
        let name = &source[held.name.range()];

        self.semantic.bindings().iter().any(|declaration| {
            declaration.kind == BindingKind::Nonlocal
                && &source[declaration.name.range()] == name
                && self.within(declaration.scope, held.scope)
                && self.reaches_a_binding(source, declaration, name)
        })
    }

    fn reaches_a_binding(&self, source: &[u8], declaration: &Binding, name: &[u8]) -> bool {
        let scopes = self.semantic.scopes();
        let Some(held) = scopes.get(declaration.scope as usize) else {
            return false;
        };

        let mut scope = held.parent;

        for _ in 0..=scopes.len() {
            let Some(named) = scopes.get(scope as usize) else {
                return false;
            };

            if named.kind == ScopeKind::Function
                && self.semantic.binding_newest(source, scope, name) != NONE
            {
                return true;
            }

            scope = named.parent;
        }

        false
    }

    fn within(&self, scope: u32, ancestor: u32) -> bool {
        let scopes = self.semantic.scopes();
        let mut held = scope;

        for _ in 0..=scopes.len() {
            if held == ancestor {
                return true;
            }

            let Some(named) = scopes.get(held as usize) else {
                return false;
            };

            held = named.parent;
        }

        false
    }

    fn unpacks_a_display(&self, node: u32) -> bool {
        let mut held = node;

        for _ in 0..=self.tree.count() {
            let parent = self.tree.at(held).parent;

            if parent == NONE {
                return false;
            }

            if self.tree.at(parent).kind == PythonKind::Assign {
                return matches!(
                    self.last_child(parent).map(|last| self.tree.at(last).kind),
                    Some(PythonKind::List | PythonKind::Tuple)
                );
            }

            held = parent;
        }

        false
    }

    fn last_child(&self, node: u32) -> Option<u32> {
        let mut child = self.tree.at(node).child_first;
        let mut last = None;

        for _ in 0..=self.tree.count() {
            if child == NONE {
                return last;
            }

            last = Some(child);
            child = self.tree.at(child).sibling_next;
        }

        last
    }
}

fn shadowable(kind: BindingKind) -> bool {
    kind.binds()
}

fn imports(kind: BindingKind) -> bool {
    matches!(
        kind,
        BindingKind::Import | BindingKind::ImportFrom | BindingKind::SubmoduleImport
    )
}

fn definition(kind: BindingKind) -> bool {
    matches!(
        kind,
        BindingKind::ClassDefinition
            | BindingKind::FunctionDefinition
            | BindingKind::Import
            | BindingKind::ImportFrom
    )
}

#[test]
fn every_fixture_reports_the_rows_ruff_reports() {
    let goldens = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-ruff");
    let found = fixtures();

    assert!(
        !found.is_empty(),
        "tests/fixtures/python-semantic holds no source"
    );

    let mut machine = Machine::reserve();
    let mut compared = 0;

    for fixture in &found {
        assert!(machine.run(&fixture.source), "{} overran", fixture.name);

        let held = machine.rows(&fixture.source);
        let golden = oracle::golden(&goldens, &fixture.name).expect("a golden");

        assert!(!golden.broken, "{}", fixture.name);

        let expected = wanted(&golden.ast);

        assert_eq!(
            held,
            expected,
            "{}",
            report(&fixture.name, &held, &expected)
        );

        compared += 1;
    }

    assert_eq!(compared, found.len());
}

#[test]
fn the_corpus_reports_the_rows_ruff_reports() {
    let Some(named) = corpus::ruff() else {
        return;
    };

    let found = corpus();

    if found.is_empty() {
        return;
    }

    let goldens = named;
    let carried = oracle::residue_of("residue-semantic.json", &EVERY_CATEGORY);
    let mut machine = Machine::reserve();
    let mut compared = 0;
    let mut differing = Vec::new();

    for fixture in &found {
        if carried.contains(&fixture.name) {
            continue;
        }

        let Some(golden) = oracle::golden(&goldens, &fixture.name) else {
            continue;
        };

        if !machine.run(&fixture.source) {
            differing.push(format!("{}: the model overran\n", fixture.name));

            continue;
        }

        if machine.errored() {
            continue;
        }

        let held = machine.rows(&fixture.source);
        let expected = wanted(&golden.ast);

        if held != expected {
            differing.push(report(&fixture.name, &held, &expected));
        }

        compared += 1;
    }

    assert!(
        compared + carried.len() >= floor::CORPUS_SEMANTIC_PYTHON,
        "the corpus lost its Python files: {} named, floor {}",
        compared + carried.len(),
        floor::CORPUS_SEMANTIC_PYTHON
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
fn the_model_is_total_over_the_fixtures() {
    let mut machine = Machine::reserve();

    for fixture in &fixtures() {
        assert!(machine.run(&fixture.source), "{} overran", fixture.name);

        for held in machine.semantic.references() {
            assert!(
                (held.scope as usize) < machine.semantic.scopes().len(),
                "{}: a reference names a scope out of bounds",
                fixture.name
            );
        }

        for held in machine.semantic.bindings() {
            assert!(
                (held.scope as usize) < machine.semantic.scopes().len(),
                "{}: a binding names a scope out of bounds",
                fixture.name
            );

            assert!(
                held.previous == NONE || machine.semantic.get(held.previous).is_some(),
                "{}: a binding chains to nothing",
                fixture.name
            );
        }
    }
}

fn wanted(rows: &[(String, u32, u32)]) -> Vec<(String, u32, u32)> {
    let mut found: Vec<(String, u32, u32)> = rows.to_vec();

    found.sort();

    found
}

fn diverges(machine: &mut Machine, root: &Path, fixture: &Fixture) -> bool {
    let Some(golden) = oracle::golden(root, &fixture.name) else {
        return true;
    };

    if golden.broken {
        return true;
    }

    if !machine.run(&fixture.source) {
        return true;
    }

    machine.rows(&fixture.source) != wanted(&golden.ast)
}

fn report(name: &str, held: &[(String, u32, u32)], expected: &[(String, u32, u32)]) -> String {
    use core::fmt::Write as _;

    let mut lines = format!("{name}: the rows differ\n");
    let mut shown = 0;
    let mut mine = 0;
    let mut theirs = 0;

    while shown < 24 && (mine < held.len() || theirs < expected.len()) {
        if theirs >= expected.len() || (mine < held.len() && held[mine] < expected[theirs]) {
            let row = &held[mine];
            let _ = writeln!(lines, "  extra   {} {} {}", row.0, row.1, row.2);

            mine += 1;
            shown += 1;

            continue;
        }

        if mine >= held.len() || expected[theirs] < held[mine] {
            let row = &expected[theirs];
            let _ = writeln!(lines, "  missing {} {} {}", row.0, row.1, row.2);

            theirs += 1;
            shown += 1;

            continue;
        }

        mine += 1;
        theirs += 1;
    }

    lines
}

fn fixtures() -> Vec<Fixture> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/python-semantic");
    let mut found = Vec::new();

    collect(&root, &root, &mut found);
    found.sort_by(|left, right| left.name.cmp(&right.name));

    found
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

        if path.extension().and_then(|held| held.to_str()) != Some("py") {
            continue;
        }

        let Ok(source) = fs::read(&path) else {
            continue;
        };

        let name = path
            .strip_prefix(base)
            .unwrap_or(&path)
            .to_string_lossy()
            .replace('\\', "/");

        found.push(Fixture { name, source });
    }
}

#[test]
fn every_residue_row_names_a_file_that_diverges() {
    let carried = oracle::residue_of("residue-semantic.json", &EVERY_CATEGORY);
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-ruff");
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

    let Some(held) = corpus::golden() else {
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
