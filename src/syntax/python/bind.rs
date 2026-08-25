use crate::bounded::{BoundedVec, Span};
use crate::syntax::python::kind::PythonKind;
use crate::token::Token;
use crate::tree::{NONE, Tree};

pub const JOB_COUNT_MAX: u32 = 1 << 10;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BindingKind {
    Assignment,
    ClassDef,
    ComprehensionTarget,
    FunctionDef,
    Global,
    Import,
    Nonlocal,
    Parameter,
    PatternCapture,
    TypeParameter,
    WalrusTarget,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ScopeKind {
    Class,
    Comprehension,
    Function,
    Lambda,
    Module,
    Type,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Binding {
    pub kind: BindingKind,
    pub name: Span,
    pub scope: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Import {
    pub alias: Span,
    pub binding: u32,
    pub level: u32,
    pub segment_count: u32,
    pub segment_first: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Reference {
    pub comprehension: bool,
    pub name: Span,
    pub scope: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Scope {
    pub kind: ScopeKind,
    pub node: u32,
    pub parent: u32,
}

#[derive(Debug)]
pub struct Tables {
    pub bindings: BoundedVec<Binding>,
    pub imports: BoundedVec<Import>,
    pub references: BoundedVec<Reference>,
    pub scopes: BoundedVec<Scope>,
    pub segments: BoundedVec<Span>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Mode {
    Load,
    Store,
}

#[derive(Clone, Copy, Debug)]
struct Job {
    comprehension: bool,
    kind: BindingKind,
    mode: Mode,
    node: u32,
    scope: u32,
}

struct Binder<'run> {
    deferred: bool,
    jobs: [Job; JOB_COUNT_MAX as usize],
    length: u32,
    overran: bool,
    raw: &'run [PythonKind],
    source: &'run [u8],
    tables: &'run mut Tables,
    tokens: &'run [Token],
    tree: &'run Tree<PythonKind>,
}

impl ScopeKind {
    pub const fn name(self) -> &'static str {
        match self {
            Self::Class => "class",
            Self::Comprehension => "comprehension",
            Self::Function => "function",
            Self::Lambda => "lambda",
            Self::Module => "module",
            Self::Type => "type",
        }
    }
}

impl BindingKind {
    pub const fn assigns(self) -> bool {
        matches!(
            self,
            Self::Assignment
                | Self::ClassDef
                | Self::ComprehensionTarget
                | Self::FunctionDef
                | Self::PatternCapture
                | Self::WalrusTarget
        )
    }
}

impl Tables {
    pub fn reserve(
        scope_count_max: u32,
        binding_count_max: u32,
        reference_count_max: u32,
        segment_count_max: u32,
    ) -> Self {
        assert!(!crate::allocation::is_frozen());

        Self {
            bindings: BoundedVec::reserve(binding_count_max),
            imports: BoundedVec::reserve(binding_count_max),
            references: BoundedVec::reserve(reference_count_max),
            scopes: BoundedVec::reserve(scope_count_max),
            segments: BoundedVec::reserve(segment_count_max),
        }
    }

    pub fn clear(&mut self) {
        self.bindings.clear();
        self.imports.clear();
        self.references.clear();
        self.scopes.clear();
        self.segments.clear();
    }
}

impl Binder<'_> {
    fn kind_of(&self, node: u32) -> PythonKind {
        self.tree.at(node).kind
    }

    fn text_of(&self, position: u32) -> Span {
        self.tokens[position as usize].span()
    }

    fn name_bytes(&self, name: Span) -> &[u8] {
        &self.source[name.range()]
    }

    fn push(&mut self, job: Job) {
        if self.length >= JOB_COUNT_MAX {
            self.overran = true;

            return;
        }

        self.jobs[self.length as usize] = job;
        self.length += 1;
    }

    fn pop(&mut self) -> Option<Job> {
        if self.length == 0 {
            return None;
        }

        self.length -= 1;

        Some(self.jobs[self.length as usize])
    }

    fn children_marked(
        &mut self,
        node: u32,
        scope: u32,
        mode: Mode,
        kind: BindingKind,
        comprehension: bool,
    ) {
        let mut found = [NONE; 64];
        let mut count = 0;
        let mut child = self.tree.at(node).child_first;

        while child != NONE && count < found.len() {
            found[count] = child;
            count += 1;
            child = self.tree.at(child).sibling_next;
        }

        while child != NONE {
            self.push(Job {
                comprehension,
                kind,
                mode,
                node: child,
                scope,
            });

            child = self.tree.at(child).sibling_next;
        }

        for index in (0..count).rev() {
            self.push(Job {
                comprehension,
                kind,
                mode,
                node: found[index],
                scope,
            });
        }
    }

    fn child_at(&self, node: u32, index: u32) -> u32 {
        let mut child = self.tree.at(node).child_first;
        let mut seen = 0;

        while child != NONE && seen < index {
            child = self.tree.at(child).sibling_next;
            seen += 1;
        }

        child
    }

    fn open_scope(&mut self, kind: ScopeKind, node: u32, parent: u32) -> u32 {
        let index = self.tables.scopes.count();

        if !self.tables.scopes.push(Scope { kind, node, parent }) {
            self.overran = true;

            return parent;
        }

        index
    }

    fn bind(&mut self, kind: BindingKind, name: Span, scope: u32) -> u32 {
        let index = self.tables.bindings.count();

        if !self.tables.bindings.push(Binding { kind, name, scope }) {
            self.overran = true;

            return NONE;
        }

        index
    }

    fn refer(&mut self, name: Span, scope: u32, comprehension: bool) {
        if !self.tables.references.push(Reference {
            comprehension,
            name,
            scope,
        }) {
            self.overran = true;
        }
    }

    fn positions(&self, node: u32) -> (u32, u32) {
        let held = self.tree.at(node);

        (held.token_start, held.token_end)
    }

    fn own_tokens(&self, node: u32, kind: PythonKind, out: &mut [u32; 16]) -> usize {
        let (start, end) = self.positions(node);
        let mut child = self.tree.at(node).child_first;
        let mut position = start;
        let mut count = 0;

        while position < end && count < out.len() {
            if child != NONE {
                let held = self.tree.at(child);

                if held.token_start <= position && held.token_end > position {
                    position = held.token_end;
                    child = held.sibling_next;

                    continue;
                }

                if held.token_end <= position {
                    child = held.sibling_next;

                    continue;
                }
            }

            if self.raw[position as usize] == kind {
                out[count] = position;
                count += 1;
            }

            position += 1;
        }

        count
    }

    fn run(&mut self) {
        let module = self.open_scope(ScopeKind::Module, 0, NONE);

        if self.tree.count() == 0 {
            return;
        }

        self.push(Job {
            comprehension: false,
            kind: BindingKind::Assignment,
            mode: Mode::Load,
            node: 0,
            scope: module,
        });

        for _ in 0..u32::MAX {
            let Some(job) = self.pop() else {
                break;
            };

            self.step(job);

            if self.overran {
                return;
            }
        }
    }

    fn step(&mut self, job: Job) {
        if job.mode == Mode::Store {
            self.store(job);

            return;
        }

        self.load(job);
    }

    fn store(&mut self, job: Job) {
        let kind = self.kind_of(job.node);

        if kind == PythonKind::Name {
            let (start, _) = self.positions(job.node);
            let _ = self.bind(job.kind, self.text_of(start), job.scope);

            return;
        }

        if matches!(
            kind,
            PythonKind::List | PythonKind::Parenthesized | PythonKind::Starred | PythonKind::Tuple
        ) {
            self.children_marked(
                job.node,
                job.scope,
                Mode::Store,
                job.kind,
                job.comprehension,
            );

            return;
        }

        if matches!(kind, PythonKind::Attribute | PythonKind::Subscript) {
            self.children_marked(job.node, job.scope, Mode::Load, job.kind, job.comprehension);

            return;
        }

        self.children_marked(job.node, job.scope, Mode::Load, job.kind, job.comprehension);
    }

    fn load(&mut self, job: Job) {
        let kind = self.kind_of(job.node);

        if kind == PythonKind::Name {
            let (start, _) = self.positions(job.node);

            self.refer(self.text_of(start), job.scope, job.comprehension);

            return;
        }

        if matches!(kind, PythonKind::AsyncFunctionDef | PythonKind::FunctionDef) {
            self.definition(job);

            return;
        }

        if kind == PythonKind::ClassDef {
            self.class(job);

            return;
        }

        if kind == PythonKind::Lambda {
            self.lambda(job);

            return;
        }

        if kind == PythonKind::GeneratorExp {
            self.generator(job);

            return;
        }

        if self.statement(job, kind) {
            return;
        }

        self.children_marked(
            job.node,
            job.scope,
            Mode::Load,
            BindingKind::Assignment,
            job.comprehension,
        );
    }

    fn statement(&mut self, job: Job, kind: PythonKind) -> bool {
        if kind == PythonKind::Assign {
            let count = self.count_children(job.node);

            self.split(job, count.saturating_sub(1), BindingKind::Assignment);

            return true;
        }

        if kind == PythonKind::AugAssign {
            self.split(job, 1, BindingKind::Assignment);

            return true;
        }

        if kind == PythonKind::AnnAssign {
            self.annotated(job);

            return true;
        }

        if matches!(kind, PythonKind::AsyncFor | PythonKind::For) {
            self.split(job, 1, BindingKind::Assignment);

            return true;
        }

        if kind == PythonKind::Comprehension {
            let held = if job.comprehension {
                BindingKind::ComprehensionTarget
            } else {
                BindingKind::Assignment
            };

            self.split(job, 1, held);

            return true;
        }

        if matches!(
            kind,
            PythonKind::DictComp | PythonKind::ListComp | PythonKind::SetComp
        ) {
            self.inlined(job);

            return true;
        }

        if kind == PythonKind::NamedExpr {
            self.split(job, 1, BindingKind::WalrusTarget);

            return true;
        }

        self.bound(job, kind)
    }

    fn bound(&mut self, job: Job, kind: PythonKind) -> bool {
        if kind == PythonKind::Delete {
            self.children_marked(
                job.node,
                job.scope,
                Mode::Store,
                BindingKind::Assignment,
                job.comprehension,
            );

            return true;
        }

        if kind == PythonKind::WithItem {
            self.with_item(job);

            return true;
        }

        if kind == PythonKind::ExceptHandler {
            self.handler(job);

            return true;
        }

        self.declared(job, kind)
    }

    fn declared(&mut self, job: Job, kind: PythonKind) -> bool {
        if matches!(kind, PythonKind::Import | PythonKind::ImportFrom) {
            self.import(job, kind);

            return true;
        }

        if matches!(kind, PythonKind::Global | PythonKind::Nonlocal) {
            self.declaration(job, kind);

            return true;
        }

        if matches!(
            kind,
            PythonKind::MatchAs | PythonKind::MatchMapping | PythonKind::MatchStar
        ) {
            self.capture(job);

            return true;
        }

        if kind == PythonKind::TypeAlias {
            self.type_alias(job);

            return true;
        }

        false
    }

    fn type_alias(&mut self, job: Job) {
        let mut names = [NONE; 16];
        let count = self.own_tokens(job.node, PythonKind::Identifier, &mut names);

        if count > 0 {
            let name = self.text_of(names[0]);
            let _ = self.bind(BindingKind::Assignment, name, job.scope);
        }

        let inner = self.type_scope(job.node, job.scope);
        let mut child = self.tree.at(job.node).child_first;
        let mut found = [(NONE, inner, Mode::Load); 64];
        let mut held = 0;
        let mut first = true;

        while child != NONE && held < found.len() {
            let kind = self.kind_of(child);
            let heading = first && kind == PythonKind::Name;

            first = first && !heading;

            if !heading && kind != PythonKind::TypeParams {
                found[held] = (child, inner, Mode::Load);
                held += 1;
            }

            child = self.tree.at(child).sibling_next;
        }

        self.schedule(&found[..held], false);
    }

    fn type_scope(&mut self, node: u32, parent: u32) -> u32 {
        let mut child = self.tree.at(node).child_first;

        while child != NONE {
            if self.kind_of(child) == PythonKind::TypeParams {
                let scope = self.open_scope(ScopeKind::Type, child, parent);

                self.type_parameters(child, scope);

                return scope;
            }

            child = self.tree.at(child).sibling_next;
        }

        parent
    }

    fn type_parameters(&mut self, node: u32, scope: u32) {
        let mut child = self.tree.at(node).child_first;

        while child != NONE {
            if matches!(
                self.kind_of(child),
                PythonKind::ParamSpec | PythonKind::TypeVar | PythonKind::TypeVarTuple
            ) {
                let mut names = [NONE; 16];
                let count = self.own_tokens(child, PythonKind::Identifier, &mut names);

                if count > 0 {
                    let name = self.text_of(names[0]);
                    let _ = self.bind(BindingKind::TypeParameter, name, scope);
                }
            }

            child = self.tree.at(child).sibling_next;
        }
    }

    fn inlined(&mut self, job: Job) {
        let mut child = self.tree.at(job.node).child_first;
        let mut found = [(NONE, job.scope, Mode::Load); 64];
        let mut held = 0;
        let mut first = true;

        while child != NONE && held < found.len() {
            if self.kind_of(child) == PythonKind::Comprehension && first {
                first = false;

                let target = self.child_at(child, 0);
                let iterable = self.child_at(child, 1);
                let mut clause = self.tree.at(child).child_first;

                while clause != NONE && held < found.len() {
                    let mode = if clause == target {
                        Mode::Store
                    } else {
                        Mode::Load
                    };

                    found[held] = (clause, job.scope, mode);
                    held += 1;

                    if clause == iterable {
                        self.push(Job {
                            comprehension: job.comprehension,
                            kind: BindingKind::Assignment,
                            mode: Mode::Load,
                            node: clause,
                            scope: job.scope,
                        });

                        held -= 1;
                    }

                    clause = self.tree.at(clause).sibling_next;
                }
            } else {
                found[held] = (child, job.scope, Mode::Load);
                held += 1;
            }

            child = self.tree.at(child).sibling_next;
        }

        for entry in found[..held].iter().rev() {
            self.push(Job {
                comprehension: true,
                kind: BindingKind::ComprehensionTarget,
                mode: entry.2,
                node: entry.0,
                scope: entry.1,
            });
        }
    }

    fn annotated(&mut self, job: Job) {
        let count = self.count_children(job.node);
        let mut child = self.tree.at(job.node).child_first;
        let mut index = 0;
        let mut found = [(NONE, job.scope, Mode::Load); 8];
        let mut held = 0;

        while child != NONE && held < found.len() {
            let mode = if index == 0 { Mode::Store } else { Mode::Load };
            let skipped = index == 1 && self.deferred;

            if !skipped {
                found[held] = (child, job.scope, mode);
                held += 1;
            }

            index += 1;
            child = self.tree.at(child).sibling_next;
        }

        let _ = count;

        self.schedule(&found[..held], job.comprehension);
    }

    fn count_children(&self, node: u32) -> u32 {
        let mut child = self.tree.at(node).child_first;
        let mut count = 0;

        while child != NONE {
            child = self.tree.at(child).sibling_next;
            count += 1;
        }

        count
    }

    fn split(&mut self, job: Job, stored: u32, kind: BindingKind) {
        let mut child = self.tree.at(job.node).child_first;
        let mut index = 0;
        let mut found = [(NONE, Mode::Load); 64];
        let mut count = 0;

        while child != NONE && count < found.len() {
            let mode = if index < stored {
                Mode::Store
            } else {
                Mode::Load
            };

            found[count] = (child, mode);
            count += 1;
            index += 1;
            child = self.tree.at(child).sibling_next;
        }

        for position in (0..count).rev() {
            let (node, mode) = found[position];

            self.push(Job {
                comprehension: job.comprehension,
                kind,
                mode,
                node,
                scope: job.scope,
            });
        }
    }

    fn with_item(&mut self, job: Job) {
        let count = self.count_children(job.node);

        if count < 2 {
            self.children_marked(
                job.node,
                job.scope,
                Mode::Load,
                BindingKind::Assignment,
                job.comprehension,
            );

            return;
        }

        let target = self.child_at(job.node, 1);
        let value = self.child_at(job.node, 0);

        self.push(Job {
            comprehension: job.comprehension,
            kind: BindingKind::Assignment,
            mode: Mode::Store,
            node: target,
            scope: job.scope,
        });

        self.push(Job {
            comprehension: job.comprehension,
            kind: BindingKind::Assignment,
            mode: Mode::Load,
            node: value,
            scope: job.scope,
        });
    }

    fn handler(&mut self, job: Job) {
        let mut names = [NONE; 16];
        let count = self.own_tokens(job.node, PythonKind::Identifier, &mut names);

        if count > 0 {
            let name = self.text_of(names[count - 1]);
            let _ = self.bind(BindingKind::Assignment, name, job.scope);
        }

        self.children_marked(
            job.node,
            job.scope,
            Mode::Load,
            BindingKind::Assignment,
            job.comprehension,
        );
    }

    fn capture(&mut self, job: Job) {
        let mut names = [NONE; 16];
        let count = self.own_tokens(job.node, PythonKind::Identifier, &mut names);

        for position in names.iter().take(count) {
            let name = self.text_of(*position);

            if self.name_bytes(name) == b"_" {
                continue;
            }

            let _ = self.bind(BindingKind::PatternCapture, name, job.scope);
        }

        self.children_marked(
            job.node,
            job.scope,
            Mode::Load,
            BindingKind::Assignment,
            job.comprehension,
        );
    }

    fn declaration(&mut self, job: Job, kind: PythonKind) {
        let held = if kind == PythonKind::Global {
            BindingKind::Global
        } else {
            BindingKind::Nonlocal
        };

        let mut names = [NONE; 16];
        let count = self.own_tokens(job.node, PythonKind::Identifier, &mut names);

        for position in names.iter().take(count) {
            let name = self.text_of(*position);
            let _ = self.bind(held, name, job.scope);
        }
    }

    fn import(&mut self, job: Job, kind: PythonKind) {
        let level = if kind == PythonKind::ImportFrom {
            self.import_level(job.node)
        } else {
            0
        };

        let mut child = self.tree.at(job.node).child_first;

        while child != NONE {
            if self.kind_of(child) == PythonKind::Alias {
                self.alias(child, job.scope, level);
            }

            child = self.tree.at(child).sibling_next;
        }
    }

    fn import_level(&self, node: u32) -> u32 {
        let (start, end) = self.positions(node);
        let mut found = 0;

        for position in start..end {
            let kind = self.raw[position as usize];

            match kind {
                PythonKind::Dot => found += 1,
                PythonKind::Ellipsis => found += 3,
                PythonKind::FromKeyword => {}
                _ => break,
            }
        }

        found
    }

    fn alias(&mut self, node: u32, scope: u32, level: u32) {
        let mut names = [NONE; 16];
        let count = self.own_tokens(node, PythonKind::Identifier, &mut names);

        if count == 0 {
            return;
        }

        let mut renamed = false;
        let (start, end) = self.positions(node);

        for position in start..end {
            if self.raw[position as usize] == PythonKind::AsKeyword {
                renamed = true;
            }
        }

        let alias = if renamed {
            self.text_of(names[count - 1])
        } else {
            self.text_of(names[0])
        };

        let binding = self.bind(BindingKind::Import, alias, scope);
        let segment_first = self.tables.segments.count();
        let segments = if renamed { count - 1 } else { count };

        for position in names.iter().take(segments) {
            let span = self.text_of(*position);

            if !self.tables.segments.push(span) {
                self.overran = true;

                return;
            }
        }

        if !self.tables.imports.push(Import {
            alias,
            binding,
            level,
            segment_count: u32::try_from(segments).expect("a name is short"),
            segment_first,
        }) {
            self.overran = true;
        }
    }

    fn definition(&mut self, job: Job) {
        let mut names = [NONE; 16];
        let count = self.own_tokens(job.node, PythonKind::Identifier, &mut names);

        if count > 0 {
            let name = self.text_of(names[0]);
            let _ = self.bind(BindingKind::FunctionDef, name, job.scope);
        }

        let outer = self.type_scope(job.node, job.scope);
        let inner = self.open_scope(ScopeKind::Function, job.node, outer);
        let mut child = self.tree.at(job.node).child_first;
        let mut found = [(NONE, outer, Mode::Load); 64];
        let mut held = 0;

        while child != NONE && held < found.len() {
            let kind = self.kind_of(child);

            match kind {
                PythonKind::Arguments => self.parameters(child, inner, outer),
                PythonKind::Block => {
                    found[held] = (child, inner, Mode::Load);
                    held += 1;
                }
                _ if kind != PythonKind::TypeParams && !self.deferred => {
                    found[held] = (child, outer, Mode::Load);
                    held += 1;
                }
                _ => {}
            }

            child = self.tree.at(child).sibling_next;
        }

        self.schedule(&found[..held], false);
    }

    fn parameters(&mut self, node: u32, inner: u32, outer: u32) {
        let mut child = self.tree.at(node).child_first;
        let mut found = [(NONE, outer, Mode::Load); 64];
        let mut held = 0;

        while child != NONE && held < found.len() {
            if self.kind_of(child) == PythonKind::Arg {
                let mut names = [NONE; 16];
                let count = self.own_tokens(child, PythonKind::Identifier, &mut names);

                if count > 0 {
                    let name = self.text_of(names[0]);
                    let _ = self.bind(BindingKind::Parameter, name, inner);
                }

                let mut annotation = self.tree.at(child).child_first;

                while annotation != NONE && held < found.len() {
                    if !self.deferred {
                        found[held] = (annotation, outer, Mode::Load);
                        held += 1;
                    }

                    annotation = self.tree.at(annotation).sibling_next;
                }
            } else {
                found[held] = (child, outer, Mode::Load);
                held += 1;
            }

            child = self.tree.at(child).sibling_next;
        }

        self.schedule(&found[..held], false);
    }

    fn schedule(&mut self, jobs: &[(u32, u32, Mode)], comprehension: bool) {
        for entry in jobs.iter().rev() {
            self.push(Job {
                comprehension,
                kind: BindingKind::Assignment,
                mode: entry.2,
                node: entry.0,
                scope: entry.1,
            });
        }
    }

    fn class(&mut self, job: Job) {
        let mut names = [NONE; 16];
        let count = self.own_tokens(job.node, PythonKind::Identifier, &mut names);

        if count > 0 {
            let name = self.text_of(names[0]);
            let _ = self.bind(BindingKind::ClassDef, name, job.scope);
        }

        let outer = self.type_scope(job.node, job.scope);
        let inner = self.open_scope(ScopeKind::Class, job.node, outer);
        let mut child = self.tree.at(job.node).child_first;
        let mut found = [(NONE, outer, Mode::Load); 64];
        let mut held = 0;

        while child != NONE && held < found.len() {
            let kind = self.kind_of(child);

            match kind {
                PythonKind::Block => {
                    found[held] = (child, inner, Mode::Load);
                    held += 1;
                }
                PythonKind::TypeParams => {}
                _ => {
                    found[held] = (child, outer, Mode::Load);
                    held += 1;
                }
            }

            child = self.tree.at(child).sibling_next;
        }

        self.schedule(&found[..held], false);
    }

    fn lambda(&mut self, job: Job) {
        let inner = self.open_scope(ScopeKind::Lambda, job.node, job.scope);
        let count = self.count_children(job.node);
        let mut child = self.tree.at(job.node).child_first;
        let mut index = 0;
        let mut found = [(NONE, job.scope, Mode::Load); 64];
        let mut held = 0;

        while child != NONE && held < found.len() {
            let kind = self.kind_of(child);

            if kind == PythonKind::Arg {
                let mut names = [NONE; 16];
                let seen = self.own_tokens(child, PythonKind::Identifier, &mut names);

                if seen > 0 {
                    let name = self.text_of(names[0]);
                    let _ = self.bind(BindingKind::Parameter, name, inner);
                }
            } else if index + 1 == count {
                found[held] = (child, inner, Mode::Load);
                held += 1;
            } else {
                found[held] = (child, job.scope, Mode::Load);
                held += 1;
            }

            index += 1;
            child = self.tree.at(child).sibling_next;
        }

        self.schedule(&found[..held], false);
    }

    fn generator(&mut self, job: Job) {
        let inner = self.open_scope(ScopeKind::Comprehension, job.node, job.scope);
        let mut child = self.tree.at(job.node).child_first;
        let mut found = [(NONE, inner, Mode::Load); 64];
        let mut held = 0;
        let mut first = true;

        while child != NONE && held < found.len() {
            if self.kind_of(child) == PythonKind::Comprehension && first {
                first = false;

                let target = self.child_at(child, 0);
                let mut clause = self.tree.at(child).child_first;
                let mut index = 0;

                while clause != NONE && held < found.len() {
                    let scope = if index == 1 { job.scope } else { inner };

                    let mode = if clause == target {
                        Mode::Store
                    } else {
                        Mode::Load
                    };

                    found[held] = (clause, scope, mode);
                    held += 1;
                    index += 1;
                    clause = self.tree.at(clause).sibling_next;
                }
            } else {
                found[held] = (child, inner, Mode::Load);
                held += 1;
            }

            child = self.tree.at(child).sibling_next;
        }

        self.schedule(&found[..held], false);
    }
}

fn defers_annotations(source: &[u8], tokens: &[Token], raw: &[PythonKind]) -> bool {
    let mut future = false;

    for position in 0..raw.len() {
        let kind = raw[position];

        if kind == PythonKind::FromKeyword {
            future = false;
        }

        if kind != PythonKind::Identifier {
            continue;
        }

        let text = tokens[position].text(source);

        if text == b"__future__" {
            future = true;

            continue;
        }

        if future && text == b"annotations" {
            return true;
        }
    }

    false
}

#[must_use]
pub fn bind(
    source: &[u8],
    tokens: &[Token],
    raw: &[PythonKind],
    tree: &Tree<PythonKind>,
    tables: &mut Tables,
) -> bool {
    assert_eq!(tokens.len(), raw.len());

    tables.clear();

    let deferred = defers_annotations(source, tokens, raw);

    let mut binder = Binder {
        deferred,
        jobs: [Job {
            comprehension: false,
            kind: BindingKind::Assignment,
            mode: Mode::Load,
            node: 0,
            scope: 0,
        }; JOB_COUNT_MAX as usize],
        length: 0,
        overran: false,
        raw,
        source,
        tables,
        tokens,
        tree,
    };

    binder.run();

    !binder.overran
}
