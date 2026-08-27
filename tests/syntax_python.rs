#[path = "common/corpus.rs"]
mod corpus;
#[path = "common/floor.rs"]
mod floor;
#[path = "common/python.rs"]
mod python;

use core::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};

use scylla::bounded::{BoundedVec, Random};
use scylla::language::Lexer as _;
use scylla::lex::PYTHON;
use scylla::lines::Index;
use scylla::syntax::Structure;
use scylla::syntax::python::PythonKind;
use scylla::syntax::python::ast::View;
use scylla::syntax::python::bind::{self, BindingKind, Outcome as BindOutcome, ScopeKind, Tables};
use scylla::syntax::python::classify::classify;
use scylla::syntax::python::parse;
use scylla::token::{Lex, Token, Tokens};
use scylla::tree::{Events, Tree};
use scylla::trivia::{self, Gap};

const NOT_PYTHON: [&str; 1] = ["not-python"];
const EVERY_CATEGORY: [&str; 1] = ["not-python"];
const SCOPE_CATEGORY: [&str; 2] = ["not-python", "pep-695-type-parameter-scopes"];
const CONTINUATION: u8 = b'\\';
const RAW_COUNT_MAX: u32 = 0x0004_0000;
const TOKEN_COUNT_MAX: u32 = 0x0004_0000;

struct Fixture {
    name: String,
    source: Vec<u8>,
}

const ERROR_COUNT_MAX: u32 = 0x0000_0400;
const EVENT_COUNT_MAX: u32 = 0x000C_0000;
const NODE_COUNT_MAX: u32 = 0x0004_0000;

const STATEMENTS: [&str; 28] = [
    "AnnAssign",
    "Assert",
    "Assign",
    "AsyncFor",
    "AsyncFunctionDef",
    "AsyncWith",
    "AugAssign",
    "Break",
    "ClassDef",
    "Continue",
    "Delete",
    "Expr",
    "For",
    "FunctionDef",
    "Global",
    "If",
    "Import",
    "ImportFrom",
    "Match",
    "Nonlocal",
    "Pass",
    "Raise",
    "Return",
    "Try",
    "TryStar",
    "TypeAlias",
    "While",
    "With",
];

const RENAMED: [(&str, &str); 3] = [("Alias", "alias"), ("Arg", "arg"), ("Keyword", "keyword")];

fn oracle_name(name: &'static str) -> &'static str {
    RENAMED
        .iter()
        .find(|entry| entry.0 == name)
        .map_or(name, |entry| entry.1)
}

const SKIPPED: [&str; 11] = [
    "Arguments",
    "Block",
    "Comprehension",
    "Decorator",
    "ElseClause",
    "ErrorNode",
    "FinallyClause",
    "MatchCase",
    "Parenthesized",
    "TypeParams",
    "WithItem",
];

#[derive(Clone, Copy, Debug)]
struct Marks {
    assigned: bool,
    bound: bool,
    declared_global: bool,
    declared_nonlocal: bool,
    imported: bool,
    parameter: bool,
}

impl Marks {
    const EMPTY: Self = Self {
        assigned: false,
        bound: false,
        declared_global: false,
        declared_nonlocal: false,
        imported: false,
        parameter: false,
    };
}

struct Machine {
    events: Events<PythonKind>,
    lexed: Tokens,
    lines: Index,
    raw: BoundedVec<PythonKind>,
    tables: Tables,
    tokens: Tokens,
    tree: Tree<PythonKind>,
}

impl Machine {
    fn reserve() -> Self {
        Self {
            events: Events::reserve(EVENT_COUNT_MAX),
            lexed: Tokens::reserve(TOKEN_COUNT_MAX),
            lines: Index::reserve(1 << 16),
            raw: BoundedVec::reserve(RAW_COUNT_MAX),
            tables: Tables::reserve(1 << 12, 1 << 16, 1 << 18, 1 << 14),
            tokens: Tokens::reserve(TOKEN_COUNT_MAX),
            tree: Tree::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX),
        }
    }

    fn parse(&mut self, source: &[u8]) -> Structure {
        assert!(self.run(source));

        parse::build(
            source,
            self.tokens.as_slice(),
            &self.raw,
            &mut self.events,
            &mut self.tree,
        )
    }

    fn walk(&self, length: u32) -> Vec<(String, u32, u32)> {
        let mut found = Vec::new();

        if self.tree.count() == 0 {
            return found;
        }

        let mut stack = vec![View::new(&self.tree, self.tokens(), &self.raw, 0)];

        while let Some(view) = stack.pop() {
            let name = oracle_name(view.kind().name());

            if name == "Module" {
                found.push((name.to_owned(), 0, length));
            } else if !SKIPPED.contains(&name) {
                let span = view.span();

                found.push((name.to_owned(), span.offset, span.end()));
            }

            let mut children: Vec<View<'_>> = Vec::new();

            children.extend(view.children());
            children.reverse();
            stack.extend(children);
        }

        found.sort();

        found
    }

    fn bind(&mut self, source: &[u8]) -> bool {
        assert!(self.lines.build(source));

        bind::bind(
            source,
            self.tokens.as_slice(),
            &self.raw,
            &self.tree,
            &mut self.tables,
        ) == BindOutcome::Complete
    }

    fn scope_name(&self, source: &[u8], index: u32) -> String {
        let scope = self.tables.scopes[index as usize];

        match scope.kind {
            ScopeKind::Module => "top".to_owned(),
            ScopeKind::Comprehension => "genexpr".to_owned(),
            ScopeKind::Lambda => "lambda".to_owned(),
            ScopeKind::Type => "type params".to_owned(),
            ScopeKind::Class | ScopeKind::Function => {
                let view = View::new(&self.tree, self.tokens(), &self.raw, scope.node);

                let position = view
                    .token_first(PythonKind::Identifier)
                    .expect("a definition names itself");

                String::from_utf8_lossy(view.token_at(position).text(source)).into_owned()
            }
        }
    }

    fn scope_kind(&self, index: u32) -> &'static str {
        match self.tables.scopes[index as usize].kind {
            ScopeKind::Class => "class",
            ScopeKind::Module => "module",
            ScopeKind::Comprehension
            | ScopeKind::Function
            | ScopeKind::Lambda
            | ScopeKind::Type => "function",
        }
    }

    fn scope_line(&self, index: u32) -> u32 {
        let scope = self.tables.scopes[index as usize];

        if scope.kind == ScopeKind::Module {
            return 0;
        }

        let view = View::new(&self.tree, self.tokens(), &self.raw, scope.node);

        self.lines.line_of(view.span().offset) + 1
    }

    fn class_owner(&self, index: u32) -> u32 {
        let mut held = self.tables.scopes[index as usize].parent;

        for _ in 0..self.tables.scopes.count() {
            if held == scylla::tree::NONE {
                return scylla::tree::NONE;
            }

            let kind = self.tables.scopes[held as usize].kind;

            if kind == ScopeKind::Class {
                return held;
            }

            if kind == ScopeKind::Module {
                return scylla::tree::NONE;
            }

            held = self.tables.scopes[held as usize].parent;
        }

        scylla::tree::NONE
    }

    fn uses_class_cell(&self, source: &[u8], index: u32) -> bool {
        let scope = self.tables.scopes[index as usize];

        if !matches!(scope.kind, ScopeKind::Function | ScopeKind::Lambda) {
            return false;
        }

        if self.class_owner(index) == scylla::tree::NONE {
            return false;
        }

        self.tables.references.iter().any(|reference| {
            reference.scope == index
                && matches!(&source[reference.name.range()], b"super" | b"__class__")
        })
    }

    fn binds(&self, source: &[u8], scope: u32, name: &[u8]) -> bool {
        self.tables.bindings.iter().any(|binding| {
            binding.scope == scope
                && &source[binding.name.range()] == name
                && !matches!(binding.kind, BindingKind::Global | BindingKind::Nonlocal)
        })
    }

    fn owner_of(&self, source: &[u8], scope: u32, name: &[u8]) -> u32 {
        let mut held = self.tables.scopes[scope as usize].parent;

        for _ in 0..self.tables.scopes.count() {
            if held == scylla::tree::NONE {
                return scylla::tree::NONE;
            }

            let kind = self.tables.scopes[held as usize].kind;

            if kind == ScopeKind::Module {
                return scylla::tree::NONE;
            }

            if kind != ScopeKind::Class && self.binds(source, held, name) {
                return held;
            }

            held = self.tables.scopes[held as usize].parent;
        }

        scylla::tree::NONE
    }

    fn symbol_names(&self, source: &[u8], index: u32) -> Vec<Vec<u8>> {
        let mut names: Vec<Vec<u8>> = Vec::new();

        for binding in self.tables.bindings.iter() {
            if binding.scope == index {
                names.push(source[binding.name.range()].to_vec());
            }
        }

        for reference in self.tables.references.iter() {
            if reference.scope == index {
                names.push(source[reference.name.range()].to_vec());
            }
        }

        names.sort();
        names.dedup();

        names
    }

    fn letters_of(&self, source: &[u8], index: u32, name: &[u8]) -> String {
        let mut held = Marks::EMPTY;

        self.marks_of(source, index, name, &mut held);

        let module = self.tables.scopes[index as usize].kind == ScopeKind::Module;
        let local = held.bound && !held.declared_global && !held.declared_nonlocal;

        let free = !local
            && (held.declared_nonlocal || self.owner_of(source, index, name) != scylla::tree::NONE);

        let global = module || held.declared_global || (!local && !free);
        let mut letters = String::new();

        if held.assigned {
            letters.push('a');
        }

        if free {
            letters.push('f');
        }

        if global {
            letters.push('g');
        }

        if held.imported {
            letters.push('i');
        }

        if local {
            letters.push('l');
        }

        if held.parameter {
            letters.push('p');
        }

        letters
    }

    fn marks_of(&self, source: &[u8], index: u32, name: &[u8], held: &mut Marks) {
        let mut isolated = false;
        let mut comprehension_only = false;

        for binding in self.tables.bindings.iter() {
            if binding.scope != index || source[binding.name.range()] != *name {
                continue;
            }

            match binding.kind {
                BindingKind::Global => held.declared_global = true,
                BindingKind::Nonlocal => held.declared_nonlocal = true,
                BindingKind::Parameter => {
                    held.parameter = true;
                    held.bound = true;
                    isolated = true;
                }
                BindingKind::Import => {
                    held.imported = true;
                    held.bound = true;
                    isolated = true;
                }
                BindingKind::ComprehensionTarget => comprehension_only = true,
                BindingKind::Assignment
                | BindingKind::ClassDef
                | BindingKind::FunctionDef
                | BindingKind::PatternCapture
                | BindingKind::TypeParameter
                | BindingKind::WalrusTarget => {
                    held.bound = true;
                    isolated = true;
                }
            }

            if binding.kind.assigns() && binding.kind != BindingKind::ComprehensionTarget {
                held.assigned = true;
            }
        }

        let outside = self.tables.references.iter().any(|reference| {
            reference.scope == index
                && source[reference.name.range()] == *name
                && !reference.comprehension
        });

        if comprehension_only && !isolated && !outside {
            held.bound = true;
            held.assigned = true;
        }
    }

    fn scopes(&self, source: &[u8]) -> Vec<(String, String, u32, String)> {
        let count = self.tables.scopes.count();
        let mut held: Vec<Vec<(Vec<u8>, String)>> = Vec::new();

        for index in 0..count {
            let mut symbols: Vec<(Vec<u8>, String)> = Vec::new();

            if self.tables.scopes[index as usize].kind == ScopeKind::Comprehension {
                symbols.push((b".0".to_vec(), "lp".to_owned()));
            }

            if self.uses_class_cell(source, index) {
                symbols.push((b"__class__".to_vec(), "f".to_owned()));
            }

            for name in self.symbol_names(source, index) {
                let letters = self.letters_of(source, index, &name);

                symbols.push((name, letters));
            }

            held.push(symbols);
        }

        self.propagate(source, &mut held);
        self.globalise(source, &mut held);

        let mut found = Vec::new();

        for index in 0..count {
            let mut symbols = held[index as usize].clone();

            symbols.sort();

            let joined: Vec<String> = symbols
                .iter()
                .map(|(name, letters)| format!("{}:{letters}", String::from_utf8_lossy(name)))
                .collect();

            found.push((
                self.scope_kind(index).to_owned(),
                self.scope_name(source, index),
                self.scope_line(index),
                joined.join(","),
            ));
        }

        found.sort();

        found
    }

    fn globalise(&self, source: &[u8], held: &mut [Vec<(Vec<u8>, String)>]) {
        let mut declared: Vec<Vec<u8>> = Vec::new();

        for binding in self.tables.bindings.iter() {
            if binding.kind == BindingKind::Global {
                declared.push(source[binding.name.range()].to_vec());
            }
        }

        for name in declared {
            let module = held
                .iter()
                .position(|_| true)
                .map_or(0, |_| self.module_scope());

            if held[module as usize]
                .iter()
                .any(|(existing, _)| *existing == name)
            {
                continue;
            }

            held[module as usize].push((name, "g".to_owned()));
        }
    }

    fn module_scope(&self) -> u32 {
        for index in 0..self.tables.scopes.count() {
            if self.tables.scopes[index as usize].kind == ScopeKind::Module {
                return index;
            }
        }

        0
    }

    fn propagate(&self, source: &[u8], held: &mut [Vec<(Vec<u8>, String)>]) {
        let count = self.tables.scopes.count();

        for _ in 0..count {
            let mut added = false;

            for index in 0..count {
                let free: Vec<Vec<u8>> = held[index as usize]
                    .iter()
                    .filter(|(_, letters)| letters.contains('f'))
                    .map(|(name, _)| name.clone())
                    .collect();

                for name in free {
                    let owner = if name == b"__class__" {
                        self.class_owner(index)
                    } else {
                        self.owner_of(source, index, &name)
                    };

                    let parent = self.tables.scopes[index as usize].parent;

                    if parent == scylla::tree::NONE || parent == owner {
                        continue;
                    }

                    if self.tables.scopes[parent as usize].kind == ScopeKind::Module {
                        continue;
                    }

                    if held[parent as usize]
                        .iter()
                        .any(|(existing, _)| *existing == name)
                    {
                        continue;
                    }

                    held[parent as usize].push((name, "f".to_owned()));
                    added = true;
                }
            }

            if !added {
                return;
            }
        }
    }

    fn census(&self) -> Vec<(String, u32)> {
        let mut found = Vec::new();

        for name in STATEMENTS {
            let kind = PythonKind::of_name(name).expect("the plan names a kind the library holds");
            let count = self
                .tree
                .as_slice()
                .iter()
                .filter(|node| node.kind == kind)
                .count();

            if count > 0 {
                found.push((name.to_owned(), u32::try_from(count).expect("small")));
            }
        }

        found
    }

    fn run(&mut self, source: &[u8]) -> bool {
        self.lexed.clear();
        PYTHON.lex(source, &mut self.lexed);

        classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw,
        )
    }

    fn tokens(&self) -> &[Token] {
        self.tokens.as_slice()
    }
}

fn corpus() -> Vec<Fixture> {
    let Some(held) = corpus::root() else {
        return Vec::new();
    };

    let mut found = Vec::new();
    let mut lexed = Tokens::reserve(TOKEN_COUNT_MAX);

    collect(&held, &held, &mut found);

    found.retain(|fixture| {
        lexed.clear();

        PYTHON.lex(&fixture.source, &mut lexed) == Lex::Complete
    });

    found.sort_by(|left, right| left.name.cmp(&right.name));

    found
}

fn fixtures() -> Vec<Fixture> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/python");

    if !root.is_dir() {
        return Vec::new();
    }

    let mut found = Vec::new();

    collect(&root, &root, &mut found);
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

        if path.extension().and_then(|extension| extension.to_str()) != Some("py") {
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

fn soup(random: &mut Random, length: u32) -> Vec<u8> {
    const ALPHABET: &[u8] =
        b"abc_09 \t\n\r()[]{}:,.=+-*/%<>!&|^~@;'\"\\#defclassifrtuwyn\x00\xff\xc3\xa9";

    let width = u32::try_from(ALPHABET.len()).expect("the alphabet is small");
    let mut found = Vec::with_capacity(length as usize);

    for _ in 0..length {
        found.push(ALPHABET[random.below(width) as usize]);
    }

    found
}

fn gaps_are_blank(source: &[u8], tokens: &[Token], name: &str) {
    let length = u32::try_from(source.len()).expect("a fixture fits in u32");
    let mut end_previous = 0;
    let mut count = 0;

    for Gap { span, token } in trivia::gaps(length, tokens) {
        assert!(
            trivia::gap_is_blank(source, span, CONTINUATION),
            "{name} carries a non-blank gap at {} of {} bytes",
            span.offset,
            span.length
        );

        assert!(
            span.offset >= end_previous,
            "{name} runs its gaps backwards"
        );

        assert_eq!(token, count, "{name} numbers its gaps out of order");

        end_previous = span.end();
        count += 1;
    }

    assert_eq!(
        count as usize,
        tokens.len() + 1,
        "{name} owes one gap per token plus a trailing one"
    );

    assert_eq!(
        end_previous,
        length,
        "{name} leaves bytes past its last gap"
    );
}

#[test]
fn classify_is_total_over_the_fixtures() {
    let found = fixtures();

    assert!(!found.is_empty(), "tests/fixtures/python holds no source");

    let mut machine = Machine::reserve();

    for fixture in &found {
        assert!(machine.run(&fixture.source), "{} overran", fixture.name);

        let errors = machine
            .raw
            .iter()
            .filter(|kind| **kind == PythonKind::ErrorToken)
            .count();

        assert_eq!(errors, 0, "{} classifies to an ErrorToken", fixture.name);
        assert_eq!(machine.raw.count() as usize, machine.tokens().len());
    }
}

#[test]
fn the_gaps_over_the_fixtures_hold_only_blank_bytes() {
    let found = fixtures();

    assert!(!found.is_empty(), "tests/fixtures/python holds no source");

    let mut machine = Machine::reserve();

    for fixture in &found {
        let _ = machine.run(&fixture.source);
        gaps_are_blank(&fixture.source, machine.tokens(), &fixture.name);
    }
}

#[test]
fn classify_is_total_on_byte_soup() {
    let mut random = Random::new(0x2545_F491_4F6C_DD1D);
    let mut machine = Machine::reserve();

    for round in 0..512_u32 {
        let length = random.below(512) + 1;
        let source = soup(&mut random, length);

        assert!(machine.run(&source), "round {round} overran");
        assert_eq!(machine.raw.count() as usize, machine.tokens().len());
        gaps_are_blank(&source, machine.tokens(), "byte soup");
    }
}

#[test]
fn the_parser_holds_its_invariants_on_byte_soup() {
    let mut random = Random::new(0x9E37_79B9_7F4A_7C15);
    let mut machine = Machine::reserve();

    for round in 0..512_u32 {
        let length = random.below(512) + 1;
        let source = soup(&mut random, length);

        let _ = machine.parse(&source);
        invariants_hold(&machine, "byte soup");

        let first: Vec<_> = machine.tree.as_slice().to_vec();

        let _ = machine.parse(&source);

        assert_eq!(
            machine.tree.as_slice(),
            first,
            "round {round} parses differently the second time"
        );
    }
}

#[test]
fn classify_runs_the_corpus_without_an_unclaimed_byte() {
    let found = corpus();

    if found.is_empty() {
        return;
    }

    let carried = python::residue_of("residue-python.json", &NOT_PYTHON);
    let mut machine = Machine::reserve();
    let mut classified = 0;
    let mut compared = 0;

    for fixture in &found {
        if carried.contains(&fixture.name) {
            classified += 1;

            continue;
        }

        assert!(machine.run(&fixture.source), "{} overran", fixture.name);

        for (position, kind) in machine.raw.iter().enumerate() {
            assert_ne!(
                *kind,
                PythonKind::ErrorToken,
                "{} classifies token {position} to an ErrorToken",
                fixture.name
            );
        }

        gaps_are_blank(&fixture.source, machine.tokens(), &fixture.name);

        compared += 1;
    }

    assert_eq!(
        classified,
        carried.len(),
        "tests/residue-python.json names a file the corpus does not carry"
    );

    assert!(
        compared >= floor::CORPUS_CLASSIFY_PYTHON,
        "the corpus lost its Python files: {compared} classified, floor {}",
        floor::CORPUS_CLASSIFY_PYTHON
    );
}

fn census_of(rows: &[(String, u32, u32)]) -> Vec<(String, u32)> {
    let mut found = Vec::new();

    for name in STATEMENTS {
        let count = rows.iter().filter(|row| row.0 == name).count();

        if count > 0 {
            found.push((name.to_owned(), u32::try_from(count).expect("small")));
        }
    }

    found
}

#[test]
fn the_statement_census_matches_the_goldens() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-python");
    let found = fixtures();

    assert!(!found.is_empty(), "tests/fixtures/python holds no source");

    let mut machine = Machine::reserve();
    let mut compared = 0;

    for fixture in &found {
        let golden = python::golden(&root, &fixture.name)
            .unwrap_or_else(|| panic!("{} has no golden", fixture.name));

        let outcome = machine.parse(&fixture.source);

        assert_eq!(outcome, Structure::Complete, "{}", fixture.name);

        assert_eq!(
            machine.census(),
            census_of(&golden.ast),
            "{} counts its statements differently",
            fixture.name
        );

        compared += 1;
    }

    assert_eq!(compared, found.len(), "a fixture went uncompared");
}

#[test]
fn the_statement_census_matches_the_corpus_goldens() {
    let Some(held) = corpus::golden() else {
        return;
    };

    let found = corpus();

    if found.is_empty() {
        return;
    }

    let carried = python::residue_of("residue-python.json", &NOT_PYTHON);
    let mut abstained = 0;
    let mut machine = Machine::reserve();
    let mut compared = 0;

    for fixture in &found {
        if carried.contains(&fixture.name) {
            continue;
        }

        let Some(golden) = python::golden(&held, &fixture.name) else {
            abstained += 1;

            continue;
        };

        let _ = machine.parse(&fixture.source);

        assert_eq!(
            machine.census(),
            census_of(&golden.ast),
            "{} counts its statements differently",
            fixture.name
        );

        compared += 1;
    }

    assert!(
        compared >= floor::CORPUS_CENSUS_PYTHON,
        "the corpus lost its Python files: {compared} counted, {abstained} abstained, floor {}",
        floor::CORPUS_CENSUS_PYTHON
    );
}

#[test]
fn the_tree_holds_its_invariants_over_the_corpus() {
    let found = corpus();

    if found.is_empty() {
        return;
    }

    let carried = python::residue_of("residue-python.json", &NOT_PYTHON);
    let mut machine = Machine::reserve();

    for fixture in &found {
        if carried.contains(&fixture.name) {
            continue;
        }

        let _ = machine.parse(&fixture.source);
        invariants_hold(&machine, &fixture.name);
    }
}

fn invariants_hold(machine: &Machine, name: &str) {
    let walk = machine.tree.as_slice();
    let tokens = machine.tokens();
    let count = u32::try_from(walk.len()).expect("a tree fits in u32");

    for (position, node) in walk.iter().enumerate() {
        let index = u32::try_from(position).expect("a tree fits in u32");

        assert!(node.token_start <= node.token_end, "{name}: node {index}");

        assert!(
            node.token_end as usize <= tokens.len(),
            "{name}: node {index} runs past the tokens"
        );

        assert!(
            node.parent == scylla::tree::NONE || node.parent < index,
            "{name}: node {index} names a parent out of preorder"
        );

        assert!(
            node.child_first == scylla::tree::NONE || node.child_first > index,
            "{name}: node {index} names a child out of preorder"
        );

        assert!(
            node.sibling_next == scylla::tree::NONE || node.sibling_next < count,
            "{name}: node {index} names a sibling out of bounds"
        );

        let mut child = node.child_first;
        let mut end_previous = node.token_start;
        let mut seen = 0;

        while child != scylla::tree::NONE {
            let held = walk[child as usize];

            assert_eq!(
                held.parent,
                index,
                "{name}: node {child} disowns its parent"
            );

            assert!(
                held.token_start >= end_previous,
                "{name}: node {child} overlaps its sibling"
            );

            assert!(
                held.token_end <= node.token_end,
                "{name}: node {child} runs past its parent"
            );

            end_previous = held.token_end;
            child = held.sibling_next;
            seen += 1;

            assert!(
                seen <= count,
                "{name}: node {index} loops over its children"
            );
        }
    }
}

fn sorted(rows: &[(String, u32, u32)]) -> Vec<(String, u32, u32)> {
    let mut found = rows.to_vec();

    found.sort();

    found
}

fn walk_diverges(machine: &mut Machine, root: &Path, fixture: &Fixture) -> bool {
    let Some(golden) = python::golden(root, &fixture.name) else {
        return true;
    };

    if !machine.run(&fixture.source) {
        return true;
    }

    if machine.raw.contains(&PythonKind::ErrorToken) {
        return true;
    }

    let _ = machine.parse(&fixture.source);

    let length = u32::try_from(fixture.source.len()).expect("a file fits in u32");

    machine.walk(length) != sorted(&golden.ast)
}

fn scopes_diverge(machine: &mut Machine, root: &Path, fixture: &Fixture) -> bool {
    let Some(golden) = python::golden(root, &fixture.name) else {
        return true;
    };

    let _ = machine.parse(&fixture.source);

    if !machine.bind(&fixture.source) {
        return true;
    }

    machine.scopes(&fixture.source) != golden.scopes
}

fn report(name: &str, held: &[(String, u32, u32)], wanted: &[(String, u32, u32)]) -> String {
    use core::fmt::Write as _;

    let mut lines = format!("{name}: the walks differ\n");
    let mut shown = 0;

    for row in held {
        if !wanted.contains(row) {
            let _ = writeln!(lines, "  extra   {} {} {}", row.0, row.1, row.2);

            shown += 1;
        }

        if shown > 12 {
            return lines;
        }
    }

    for row in wanted {
        if !held.contains(row) {
            let _ = writeln!(lines, "  missing {} {} {}", row.0, row.1, row.2);

            shown += 1;
        }

        if shown > 24 {
            return lines;
        }
    }

    lines
}

#[test]
fn a_type_parameter_carries_a_default() {
    let source = b"def read[Held = int]() -> Held:\n    return Held()\n";
    let length = u32::try_from(source.len()).expect("a source fits in u32");
    let mut machine = Machine::reserve();

    assert_eq!(machine.parse(source), Structure::Complete);

    let walk = machine.walk(length);

    assert!(walk.contains(&("TypeVar".to_owned(), 9, 19)), "{walk:?}");
    assert!(walk.contains(&("Name".to_owned(), 16, 19)), "{walk:?}");
}

#[test]
fn an_except_clause_reads_an_unparenthesized_tuple() {
    let source = b"try:\n    pass\nexcept ValueError, TypeError:\n    pass\n";
    let length = u32::try_from(source.len()).expect("a source fits in u32");
    let mut machine = Machine::reserve();

    assert_eq!(machine.parse(source), Structure::Complete);

    let walk = machine.walk(length);

    assert!(walk.contains(&("Tuple".to_owned(), 21, 42)), "{walk:?}");
}

#[test]
fn a_flat_literal_is_not_nesting() {
    const ELEMENT_COUNT: usize = 4_000;

    let mut list = String::from("held = [");
    let mut dict = String::from("held = {");
    let mut tuple = String::from("held = (");

    for index in 0..ELEMENT_COUNT {
        let _ = write!(list, "{index}, ");
        let _ = write!(dict, "\"k{index}\": {index}, ");
        let _ = write!(tuple, "{index}, ");
    }

    list.push_str("]\n");
    dict.push_str("}\n");
    tuple.push_str(")\n");

    let mut machine = Machine::reserve();

    for (name, source) in [("a list", &list), ("a dict", &dict), ("a tuple", &tuple)] {
        let held = source.as_bytes();

        assert_eq!(
            machine.parse(held),
            Structure::Complete,
            "{name} of {ELEMENT_COUNT} elements does not parse whole"
        );

        assert!(
            machine.tree.errors().is_empty(),
            "{name} of {ELEMENT_COUNT} elements parses with {:?}",
            machine.tree.errors()
        );
    }
}

#[test]
fn a_literal_reads_back_as_the_kind_its_brackets_name() {
    const HELD: [(&[u8], &str); 6] = [
        (b"held = {}\n", "Dict"),
        (b"held = {1: 2}\n", "Dict"),
        (b"held = {1}\n", "Set"),
        (b"held = {1, 2}\n", "Set"),
        (b"held = {1,}\n", "Set"),
        (b"held = (1,)\n", "Tuple"),
    ];

    let mut machine = Machine::reserve();

    for (source, wanted) in HELD {
        let _ = machine.parse(source);

        let length = u32::try_from(source.len()).expect("a source fits in u32");
        let walk = machine.walk(length);

        assert!(
            walk.iter().any(|(name, _, _)| name == wanted),
            "{} reads as {walk:?} and not as a {wanted}",
            String::from_utf8_lossy(source)
        );
    }
}

#[test]
fn the_normalized_walk_matches_the_goldens() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-python");
    let carried = python::residue_of("residue-python.json", &EVERY_CATEGORY);
    let found = fixtures();

    assert!(!found.is_empty(), "tests/fixtures/python holds no source");

    let mut machine = Machine::reserve();
    let mut compared = 0;

    for fixture in &found {
        if carried.contains(&fixture.name) {
            continue;
        }

        let golden = python::golden(&root, &fixture.name)
            .unwrap_or_else(|| panic!("{} has no golden", fixture.name));

        let _ = machine.parse(&fixture.source);

        let length = u32::try_from(fixture.source.len()).expect("a fixture fits in u32");
        let held = machine.walk(length);
        let wanted = sorted(&golden.ast);

        assert!(held == wanted, "{}", report(&fixture.name, &held, &wanted));

        compared += 1;
    }

    assert!(
        compared >= floor::FIXTURE_WALK_PYTHON,
        "the Python fixtures lost a walk: {compared} compared, floor {}",
        floor::FIXTURE_WALK_PYTHON
    );
}

#[test]
fn the_normalized_walk_matches_the_corpus_goldens() {
    let Some(held) = corpus::golden() else {
        return;
    };

    let found = corpus();

    if found.is_empty() {
        return;
    }

    let carried = python::residue_of("residue-python.json", &EVERY_CATEGORY);
    let mut abstained = 0;
    let mut machine = Machine::reserve();
    let mut differing = Vec::new();
    let mut compared = 0;

    for fixture in &found {
        if carried.contains(&fixture.name) {
            continue;
        }

        let Some(golden) = python::golden(&held, &fixture.name) else {
            abstained += 1;

            continue;
        };

        let _ = machine.parse(&fixture.source);

        let length = u32::try_from(fixture.source.len()).expect("a file fits in u32");
        let walk = machine.walk(length);
        let wanted = sorted(&golden.ast);

        if walk != wanted {
            differing.push(report(&fixture.name, &walk, &wanted));
        }

        compared += 1;
    }

    assert!(
        compared + carried.len() >= floor::CORPUS_WALK_PYTHON,
        "the corpus lost its Python files: {} named, {abstained} abstained, floor {}",
        compared + carried.len(),
        floor::CORPUS_WALK_PYTHON
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
fn the_scope_tables_match_the_goldens() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-python");
    let carried = python::residue_of("residue-python.json", &SCOPE_CATEGORY);
    let found = fixtures();

    assert!(!found.is_empty(), "tests/fixtures/python holds no source");

    let mut machine = Machine::reserve();
    let mut compared = 0;

    for fixture in &found {
        if carried.contains(&fixture.name) {
            continue;
        }

        let golden = python::golden(&root, &fixture.name)
            .unwrap_or_else(|| panic!("{} has no golden", fixture.name));

        let _ = machine.parse(&fixture.source);

        assert!(machine.bind(&fixture.source), "{} overran", fixture.name);

        let held = machine.scopes(&fixture.source);

        assert_eq!(
            held,
            golden.scopes,
            "{} binds its scopes differently",
            fixture.name
        );

        compared += 1;
    }

    assert!(
        compared >= floor::FIXTURE_SCOPE_PYTHON,
        "the Python fixtures lost a scope table: {compared} compared, floor {}",
        floor::FIXTURE_SCOPE_PYTHON
    );
}

#[test]
fn the_scope_tables_match_the_corpus_goldens() {
    let Some(held) = corpus::golden() else {
        return;
    };

    let found = corpus();

    if found.is_empty() {
        return;
    }

    let carried = python::residue_of("residue-python.json", &SCOPE_CATEGORY);
    let mut abstained = 0;
    let mut machine = Machine::reserve();
    let mut differing = Vec::new();
    let mut compared = 0;

    for fixture in &found {
        if carried.contains(&fixture.name) {
            continue;
        }

        let Some(golden) = python::golden(&held, &fixture.name) else {
            abstained += 1;

            continue;
        };

        let _ = machine.parse(&fixture.source);

        assert!(machine.bind(&fixture.source), "{} overran", fixture.name);

        let scopes = machine.scopes(&fixture.source);

        if scopes != golden.scopes {
            differing.push(scope_report(&fixture.name, &scopes, &golden.scopes));
        }

        compared += 1;
    }

    assert!(
        compared + carried.len() >= floor::CORPUS_SCOPE_PYTHON,
        "the corpus lost its Python files: {} named, {abstained} abstained, floor {}",
        compared + carried.len(),
        floor::CORPUS_SCOPE_PYTHON
    );

    if !differing.is_empty() {
        if let Ok(path) = std::env::var("SCYLLA_SCOPE_REPORT") {
            fs::write(path, differing.join("")).expect("the report is writable");
        }

        panic!(
            "{} of {compared} corpus files bind differently\n{}",
            differing.len(),
            differing
                .iter()
                .take(2)
                .map(|line| line.as_str())
                .collect::<Vec<&str>>()
                .join("")
        );
    }
}

fn scope_report(
    name: &str,
    held: &[(String, String, u32, String)],
    wanted: &[(String, String, u32, String)],
) -> String {
    use core::fmt::Write as _;

    let mut lines = format!("{name}: the scopes differ\n");
    let mut shown = 0;

    for row in held {
        if !wanted.contains(row) {
            let _ = writeln!(lines, "  extra   {} {} {} {}", row.0, row.1, row.2, row.3);

            shown += 1;
        }

        if shown > 6 {
            return lines;
        }
    }

    for row in wanted {
        if !held.contains(row) {
            let _ = writeln!(lines, "  missing {} {} {} {}", row.0, row.1, row.2, row.3);

            shown += 1;
        }

        if shown > 12 {
            return lines;
        }
    }

    lines
}

#[test]
fn every_residue_row_names_a_file_that_diverges() {
    const SCOPES_ONLY: [&str; 1] = ["pep-695-type-parameter-scopes"];

    let carried = python::residue_of("residue-python.json", &EVERY_CATEGORY);
    let scoped = python::residue_of("residue-python.json", &SCOPES_ONLY);
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-python");
    let mut machine = Machine::reserve();
    let mut named = Vec::new();

    for fixture in &fixtures() {
        if carried.contains(&fixture.name) {
            named.push(fixture.name.clone());

            assert!(
                walk_diverges(&mut machine, &root, fixture),
                "{} matches its golden and needs no residue row",
                fixture.name
            );
        }

        if scoped.contains(&fixture.name) {
            named.push(fixture.name.clone());

            assert!(
                scopes_diverge(&mut machine, &root, fixture),
                "{} binds the scopes its golden records and needs no residue row",
                fixture.name
            );
        }
    }

    let Some(held) = corpus::golden() else {
        return;
    };

    for fixture in &corpus() {
        if carried.contains(&fixture.name) {
            named.push(fixture.name.clone());

            assert!(
                walk_diverges(&mut machine, &held, fixture),
                "{} matches its corpus golden and needs no residue row",
                fixture.name
            );
        }

        if scoped.contains(&fixture.name) {
            named.push(fixture.name.clone());

            assert!(
                scopes_diverge(&mut machine, &held, fixture),
                "{} binds the scopes its corpus golden records and needs no residue row",
                fixture.name
            );
        }
    }

    for name in carried.iter().chain(scoped.iter()) {
        assert!(
            named.contains(name),
            "the residue names `{name}` and neither the fixtures nor the corpus carry it"
        );
    }
}
