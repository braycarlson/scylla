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
    BindingKind,
    Context,
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

        self.suppressions
            .scan(source, self.comments.iter().copied(), b"noqa", &self.index);

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

    fn rows(&self, source: &[u8]) -> Vec<(String, u32, u32)> {
        let mut found = Vec::new();

        self.unused_imports(source, &mut found);
        self.redefinitions(&mut found);
        self.undefined(&mut found);
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

            let statement = self.tree.at(held.node).parent;

            if statement != NONE && self.suppressed_at(source, "F401", statement) {
                continue;
            }

            if held.flags.deleted || held.flags.alias {
                continue;
            }

            let (line, column) = self.place(held.name.offset);

            found.push(("F401".to_owned(), line, column));
        }
    }

    fn redefinitions(&self, found: &mut Vec<(String, u32, u32)>) {
        for held in self.semantic.bindings() {
            if !definition(held.kind) || held.previous == NONE {
                continue;
            }

            let Some(earlier) = self.semantic.get(held.previous) else {
                continue;
            };

            if !definition(earlier.kind) || self.semantic.is_used(held.previous) {
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
    }

    fn undefined(&self, found: &mut Vec<(String, u32, u32)>) {
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

            let (line, column) = self.place(held.name.offset);

            found.push(("F821".to_owned(), line, column));
        }
    }

    fn unused_variables(&self, source: &[u8], found: &mut Vec<(String, u32, u32)>) {
        for (index, held) in self.semantic.bindings().iter().enumerate() {
            if !matches!(
                held.kind,
                BindingKind::Assignment | BindingKind::Named | BindingKind::WithVariable
            ) {
                continue;
            }

            if held.kind == BindingKind::Assignment && held.flags.unpacked {
                continue;
            }

            let position = u32::try_from(index).expect("a bounded index fits in u32");

            if held.flags.shadowed {
                continue;
            }

            let scope = self.semantic.scopes()[held.scope as usize];

            if !matches!(scope.kind, ScopeKind::Function | ScopeKind::Lambda) {
                continue;
            }

            if held.flags.private {
                continue;
            }

            if self.semantic.chain_used(source, position) || held.flags.deleted {
                continue;
            }

            let (line, column) = self.place(held.name.offset);

            found.push(("F841".to_owned(), line, column));
        }
    }
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
