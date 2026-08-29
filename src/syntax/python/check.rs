use crate::bounded::{BoundedVec, Span};
use crate::syntax::python::ast::{Arg, View};
use crate::syntax::python::bind::ScopeKind;
use crate::syntax::python::kind::PythonKind;
use crate::syntax::python::literal;
use crate::syntax::python::semantic::{Binding, BindingKind, SCOPE_DEPTH_MAX, Semantic};
use crate::syntax::python::stdlib::PythonVersion;
use crate::token::Token;
use crate::tree::{NONE, Step, Tree, walk, walk_from};

pub const ERROR_COUNT_MAX_DEFAULT: u32 = 1 << 10;
const TARGET_STACK_MAX: usize = 1 << 8;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Feature {
    ExceptStar,
    MatchStatement,
    ParenthesizedWithItems,
    TemplateString,
    TypeAliasStatement,
    TypeParameterDefaults,
    TypeParameters,
    UnparenthesizedExceptTuple,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CheckKind {
    AwaitOutsideAsync,
    AwaitOutsideFunction,
    DuplicateParameter,
    ExceptNotLast,
    FutureImportLate,
    GlobalAfterUse,
    IrrefutableCaseNotLast,
    NonlocalAtModule,
    NonlocalWithoutBinding,
    ReturnOutsideFunction,
    StarredMultiple,
    StarredTargetAlone,
    TargetAssignInvalid,
    TargetDeleteInvalid,
    Unsupported(Feature),
    WalrusInComprehensionIterable,
    WalrusRebindsComprehensionVariable,
    YieldOutsideFunction,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Completion {
    Complete,
    ErrorsFull,
    FramesFull,
    ScratchFull,
    TargetStackFull,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CheckError {
    pub kind: CheckKind,
    pub span: Span,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum FrameKind {
    Class,
    Comprehension,
    Function,
    Module,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Frame {
    asynchronous: bool,
    kind: FrameKind,
    node: u32,
}

struct Checker<'run> {
    completion: Completion,
    depth: u32,
    errors: &'run mut BoundedVec<CheckError>,
    frames: [Frame; SCOPE_DEPTH_MAX as usize],
    future_allowed: bool,
    raw: &'run [PythonKind],
    scratch: &'run mut BoundedVec<Span>,
    semantic: &'run Semantic,
    source: &'run [u8],
    target_stack: [u32; TARGET_STACK_MAX],
    tokens: &'run [Token],
    tree: &'run Tree<PythonKind>,
    version: PythonVersion,
}

impl Feature {
    pub const fn name(self) -> &'static str {
        match self {
            Self::ExceptStar => "`except*`",
            Self::MatchStatement => "`match` statement",
            Self::ParenthesizedWithItems => "parentheses within a `with` statement",
            Self::TemplateString => "t-strings",
            Self::TypeAliasStatement => "`type` alias statement",
            Self::TypeParameterDefaults => "type parameter defaults",
            Self::TypeParameters => "type parameter lists",
            Self::UnparenthesizedExceptTuple => "unparenthesized except tuples",
        }
    }

    pub const fn message(self) -> &'static str {
        match self {
            Self::ExceptStar => "Cannot use `except*`",
            Self::MatchStatement => "Cannot use `match` statement",
            Self::ParenthesizedWithItems => "Cannot use parentheses within a `with` statement",
            Self::TemplateString => "Cannot use t-strings",
            Self::TypeAliasStatement => "Cannot use `type` alias statement",
            Self::TypeParameterDefaults => "Cannot set default type for a type parameter",
            Self::TypeParameters => "Cannot use type parameter lists",
            Self::UnparenthesizedExceptTuple => "Multiple exception types must be parenthesized",
        }
    }

    pub const fn since(self) -> PythonVersion {
        match self {
            Self::ParenthesizedWithItems => PythonVersion::Py39,
            Self::MatchStatement => PythonVersion::Py310,
            Self::ExceptStar => PythonVersion::Py311,
            Self::TypeAliasStatement | Self::TypeParameters => PythonVersion::Py312,
            Self::TypeParameterDefaults => PythonVersion::Py313,
            Self::TemplateString | Self::UnparenthesizedExceptTuple => PythonVersion::Py314,
        }
    }
}

impl CheckKind {
    pub const fn code(self) -> &'static str {
        match self {
            Self::AwaitOutsideAsync => "PLE1142",
            Self::AwaitOutsideFunction | Self::YieldOutsideFunction => "F704",
            Self::ExceptNotLast => "F707",
            Self::FutureImportLate => "F404",
            Self::GlobalAfterUse => "PLE0118",
            Self::NonlocalWithoutBinding => "PLE0117",
            Self::ReturnOutsideFunction => "F706",
            Self::StarredMultiple => "F622",
            Self::DuplicateParameter
            | Self::IrrefutableCaseNotLast
            | Self::NonlocalAtModule
            | Self::StarredTargetAlone
            | Self::TargetAssignInvalid
            | Self::TargetDeleteInvalid
            | Self::Unsupported(_)
            | Self::WalrusInComprehensionIterable
            | Self::WalrusRebindsComprehensionVariable => "invalid-syntax",
        }
    }

    pub const fn message(self) -> &'static str {
        match self {
            Self::AwaitOutsideAsync => "`await` should be used within an async function",
            Self::AwaitOutsideFunction => "`await` statement outside of a function",
            Self::DuplicateParameter => "Duplicate parameter",
            Self::ExceptNotLast => "An `except` block as not the last exception handler",
            Self::FutureImportLate => {
                "`from __future__` imports must occur at the beginning of the file"
            }
            Self::GlobalAfterUse => "Name is used prior to global declaration",
            Self::IrrefutableCaseNotLast => "wildcard makes remaining patterns unreachable",
            Self::NonlocalAtModule => "nonlocal declaration not allowed at module level",
            Self::NonlocalWithoutBinding => "Nonlocal name found without binding",
            Self::ReturnOutsideFunction => "`return` statement outside of a function/method",
            Self::StarredMultiple => "Two starred expressions in assignment",
            Self::StarredTargetAlone => "starred assignment target must be in a list or tuple",
            Self::TargetAssignInvalid => "Invalid assignment target",
            Self::TargetDeleteInvalid => "Invalid delete target",
            Self::Unsupported(feature) => feature.message(),
            Self::WalrusInComprehensionIterable => {
                "assignment expression cannot be used in a comprehension iterable expression"
            }
            Self::WalrusRebindsComprehensionVariable => {
                "assignment expression cannot rebind comprehension variable"
            }
            Self::YieldOutsideFunction => "`yield` statement outside of a function",
        }
    }
}

impl<'run> Checker<'run> {
    fn run(&mut self) {
        self.frames[0] = Frame {
            asynchronous: false,
            kind: FrameKind::Module,
            node: 0,
        };

        self.depth = 1;

        for step in walk(self.tree) {
            match step {
                Step::Enter(node) => self.enter(node),
                Step::Leave(node) => self.leave(node),
            }
        }

        assert_eq!(self.depth, 1);
        assert_eq!(self.frames[0].kind, FrameKind::Module);
    }

    fn enter(&mut self, node: u32) {
        let kind = self.kind_of(node);

        self.frame_open(node, kind);
        self.future_track(node, kind);
        self.flow(node, kind);
        self.declarations(node, kind);
        self.targets(node, kind);
        self.clauses(node, kind);
        self.parameters(node, kind);
        self.walrus(node, kind);
        self.gate(node, kind);
    }

    fn leave(&mut self, node: u32) {
        if self.depth > 1 && self.frames[self.depth as usize - 1].node == node {
            self.depth -= 1;
        }
    }

    fn frame_open(&mut self, node: u32, kind: PythonKind) {
        if !opens_frame(kind) {
            return;
        }

        if self.depth as usize >= self.frames.len() {
            self.overrun(Completion::FramesFull);

            return;
        }

        self.frames[self.depth as usize] = Frame {
            asynchronous: kind == PythonKind::AsyncFunctionDef,
            kind: frame_kind_of(kind),
            node,
        };

        self.depth += 1;

        assert!(self.depth > 1);
    }

    fn enclosing(&self) -> Frame {
        let mut index = self.depth;

        while index > 1 {
            let held = self.frames[index as usize - 1];

            if held.kind != FrameKind::Comprehension {
                return held;
            }

            index -= 1;
        }

        self.frames[0]
    }

    fn flow(&mut self, node: u32, kind: PythonKind) {
        if kind == PythonKind::Return {
            self.flow_report(node, CheckKind::ReturnOutsideFunction);

            return;
        }

        if matches!(kind, PythonKind::Yield | PythonKind::YieldFrom) {
            self.flow_report(node, CheckKind::YieldOutsideFunction);

            return;
        }

        if !matches!(
            kind,
            PythonKind::AsyncFor | PythonKind::AsyncWith | PythonKind::Await
        ) {
            return;
        }

        if kind == PythonKind::Await {
            self.flow_report(node, CheckKind::AwaitOutsideFunction);
        }

        let held = self.enclosing();

        if held.kind != FrameKind::Function || !held.asynchronous {
            self.report(CheckKind::AwaitOutsideAsync, self.span_of(node));
        }
    }

    fn flow_report(&mut self, node: u32, kind: CheckKind) {
        if self.enclosing().kind == FrameKind::Function {
            return;
        }

        self.report(kind, self.span_of(node));
    }

    fn declarations(&mut self, node: u32, kind: PythonKind) {
        if kind == PythonKind::Global {
            self.global_uses(node);

            return;
        }

        if kind != PythonKind::Nonlocal {
            return;
        }

        if self.frames[self.depth as usize - 1].kind == FrameKind::Module {
            self.report(CheckKind::NonlocalAtModule, self.span_of(node));

            return;
        }

        self.nonlocal_bindings(node);
    }

    fn global_uses(&mut self, node: u32) {
        let semantic = self.semantic;
        let source = self.source;

        for held in semantic.bindings() {
            if held.node != node || held.kind != BindingKind::Global {
                continue;
            }

            let name = &source[held.name.range()];

            for reference in semantic.references() {
                if reference.scope != held.scope || reference.node >= node {
                    continue;
                }

                if &source[reference.name.range()] == name {
                    self.report(CheckKind::GlobalAfterUse, reference.name);
                }
            }

            for earlier in semantic.bindings() {
                if !self.global_use_binding(earlier, held.scope, node, name) {
                    continue;
                }

                self.report(CheckKind::GlobalAfterUse, earlier.name);
            }
        }
    }

    fn global_use_binding(&self, binding: &Binding, scope: u32, node: u32, name: &[u8]) -> bool {
        if binding.scope != scope || binding.node >= node {
            return false;
        }

        if matches!(binding.kind, BindingKind::Global | BindingKind::Nonlocal) {
            return false;
        }

        if &self.source[binding.name.range()] != name {
            return false;
        }

        self.semantic.reference_at(binding.node) == NONE
    }

    fn nonlocal_bindings(&mut self, node: u32) {
        let semantic = self.semantic;
        let source = self.source;

        for held in semantic.bindings() {
            if held.node != node || held.kind != BindingKind::Nonlocal {
                continue;
            }

            if self.nonlocal_bound(held.scope, &source[held.name.range()]) {
                continue;
            }

            self.report(CheckKind::NonlocalWithoutBinding, held.name);
        }
    }

    fn nonlocal_bound(&self, scope: u32, name: &[u8]) -> bool {
        let scopes = self.semantic.scopes();

        assert!((scope as usize) < scopes.len());

        let mut held = scopes[scope as usize].parent;

        for _ in 0..SCOPE_DEPTH_MAX {
            if held == NONE {
                return false;
            }

            let outer = scopes[held as usize];

            if matches!(
                outer.kind,
                ScopeKind::Comprehension | ScopeKind::Function | ScopeKind::Lambda
            ) {
                let found = self.semantic.binding_newest(self.source, held, name);

                if self
                    .semantic
                    .get(found)
                    .is_some_and(|binding| binding.kind.binds())
                {
                    return true;
                }
            }

            if outer.kind == ScopeKind::Module {
                return false;
            }

            held = outer.parent;
        }

        false
    }

    fn future_track(&mut self, node: u32, kind: PythonKind) {
        if kind == PythonKind::ImportFrom && self.is_future_import(node) {
            if !self.future_allowed {
                self.report(CheckKind::FutureImportLate, self.span_of(node));
            }

            return;
        }

        if node == 0 || self.tree.at(node).parent != 0 {
            return;
        }

        if node == self.tree.at(0).child_first && self.is_docstring(node) {
            return;
        }

        self.future_allowed = false;
    }

    fn is_future_import(&self, node: u32) -> bool {
        let held = self.view(node);

        let Some(import) = held.as_import() else {
            return false;
        };

        if import.level() != 0 {
            return false;
        }

        let mut found = false;

        for position in held.positions() {
            let kind = held.token_kind(position);

            if kind == PythonKind::ImportKeyword {
                break;
            }

            if kind != PythonKind::Identifier {
                continue;
            }

            if found || held.token_at(position).text(self.source) != b"__future__" {
                return false;
            }

            found = true;
        }

        found
    }

    fn is_docstring(&self, node: u32) -> bool {
        if self.kind_of(node) != PythonKind::Expr {
            return false;
        }

        let Some(child) = self.view(node).child_first() else {
            return false;
        };

        if child.kind() != PythonKind::Constant {
            return false;
        }

        let held = self.tree.at(child.index());

        held.token_end > held.token_start
            && matches!(
                self.raw[held.token_start as usize],
                PythonKind::StringFormat | PythonKind::StringPlain
            )
    }

    fn targets(&mut self, node: u32, kind: PythonKind) {
        if kind == PythonKind::Delete {
            for child in self.view(node).children() {
                self.target(child.index(), CheckKind::TargetDeleteInvalid);
            }

            return;
        }

        if binds_first_child(kind) {
            if let Some(target) = self.view(node).child_first() {
                self.assign_target(target.index(), target.kind());
            }

            return;
        }

        if kind == PythonKind::WithItem {
            for target in self.view(node).children().skip(1) {
                self.assign_target(target.index(), target.kind());
            }

            return;
        }

        if kind != PythonKind::Assign {
            return;
        }

        let Some(assign) = self.view(node).as_assign() else {
            return;
        };

        for target in assign.targets() {
            self.assign_target(target.index(), target.kind());
        }
    }

    fn assign_target(&mut self, node: u32, kind: PythonKind) {
        if kind == PythonKind::Starred {
            self.report(CheckKind::StarredTargetAlone, self.span_of(node));

            return;
        }

        self.target(node, CheckKind::TargetAssignInvalid);
    }

    fn target(&mut self, node: u32, kind: CheckKind) {
        let mut depth = 1;

        self.target_stack[0] = node;

        for _ in 0..=self.tree.count() {
            if depth == 0 {
                return;
            }

            depth -= 1;

            let held = self.target_stack[depth];

            if !self.target_holds(held, kind) {
                continue;
            }

            depth = self.target_push(held, depth);
        }

        unreachable!("a target walk visits each node once");
    }

    fn target_holds(&mut self, node: u32, kind: CheckKind) -> bool {
        let form = self.kind_of(node);

        if matches!(
            form,
            PythonKind::Attribute | PythonKind::Name | PythonKind::Subscript
        ) {
            return false;
        }

        let starred = form == PythonKind::Starred;

        if !holds_targets(form) || (starred && kind == CheckKind::TargetDeleteInvalid) {
            self.report(kind, self.span_of(node));

            return false;
        }

        if kind == CheckKind::TargetAssignInvalid {
            self.starred(node);
        }

        true
    }

    fn target_push(&mut self, node: u32, depth: usize) -> usize {
        let view = self.view(node);
        let mut held = depth;

        for child in view.children() {
            if held == TARGET_STACK_MAX {
                self.overrun(Completion::TargetStackFull);

                return 0;
            }

            self.target_stack[held] = child.index();
            held += 1;
        }

        held
    }

    fn starred(&mut self, node: u32) {
        if !matches!(self.kind_of(node), PythonKind::List | PythonKind::Tuple) {
            return;
        }

        let mut found = 0;

        for child in self.view(node).children() {
            if child.kind() == PythonKind::Starred {
                found += 1;
            }
        }

        if found > 1 {
            self.report(CheckKind::StarredMultiple, self.span_of(node));
        }
    }

    fn clauses(&mut self, node: u32, kind: PythonKind) {
        if matches!(kind, PythonKind::Try | PythonKind::TryStar) {
            self.handlers(node);

            return;
        }

        if kind != PythonKind::Match {
            return;
        }

        self.cases(node);
    }

    fn handlers(&mut self, node: u32) {
        let held = self.view(node);

        let Some(final_handler) = held.children_of(PythonKind::ExceptHandler).last() else {
            return;
        };

        for handler in held.children_of(PythonKind::ExceptHandler) {
            if handler.index() == final_handler.index() {
                break;
            }

            if handler.children_of(PythonKind::Block).count() == handler.children().count() {
                self.report(CheckKind::ExceptNotLast, self.span_of(handler.index()));
            }
        }
    }

    fn cases(&mut self, node: u32) {
        let held = self.view(node);

        let Some(final_case) = held.children_of(PythonKind::MatchCase).last() else {
            return;
        };

        for case in held.children_of(PythonKind::MatchCase) {
            if case.index() == final_case.index() {
                break;
            }

            if case.children().count() > 2 {
                continue;
            }

            let Some(pattern) = case.child_first() else {
                continue;
            };

            if irrefutable(pattern) {
                self.report(
                    CheckKind::IrrefutableCaseNotLast,
                    self.span_of(pattern.index()),
                );
            }
        }
    }

    fn parameters(&mut self, node: u32, kind: PythonKind) {
        if !matches!(kind, PythonKind::Arguments | PythonKind::Lambda) {
            return;
        }

        let source = self.source;

        self.scratch.clear();

        for child in self.view(node).children_of(PythonKind::Arg) {
            let Some(position) = child.as_argument().and_then(Arg::name_token) else {
                continue;
            };

            let name = child.token_at(position).span();

            let seen = self
                .scratch
                .iter()
                .any(|held| source[held.range()] == source[name.range()]);

            if seen {
                self.report(CheckKind::DuplicateParameter, name);

                continue;
            }

            if !self.scratch.push(name) {
                self.overrun(Completion::ScratchFull);

                return;
            }
        }
    }

    fn walrus(&mut self, node: u32, kind: PythonKind) {
        if kind == PythonKind::Comprehension {
            self.walrus_iterable(node);

            return;
        }

        if !opens_comprehension(kind) {
            return;
        }

        self.walrus_rebind(node);
    }

    fn walrus_iterable(&mut self, node: u32) {
        let tree = self.tree;

        let Some(iterable) = self.view(node).child_at(1) else {
            return;
        };

        for step in walk_from(tree, iterable.index()) {
            let Step::Enter(held) = step else {
                continue;
            };

            if self.kind_of(held) == PythonKind::NamedExpr {
                self.report(CheckKind::WalrusInComprehensionIterable, self.span_of(held));
            }
        }
    }

    fn walrus_rebind(&mut self, node: u32) {
        self.comprehension_targets(node);

        let source = self.source;
        let tree = self.tree;

        for step in walk_from(tree, node) {
            let Step::Enter(held) = step else {
                continue;
            };

            if self.kind_of(held) != PythonKind::NamedExpr {
                continue;
            }

            let Some(target) = self.view(held).child_first() else {
                continue;
            };

            let name = target.span();

            let written = self
                .scratch
                .iter()
                .any(|seen| source[seen.range()] == source[name.range()]);

            if written {
                self.report(
                    CheckKind::WalrusRebindsComprehensionVariable,
                    self.span_of(held),
                );
            }
        }
    }

    fn comprehension_targets(&mut self, node: u32) {
        let tree = self.tree;

        self.scratch.clear();

        for clause in self.view(node).children_of(PythonKind::Comprehension) {
            let Some(target) = clause.child_first() else {
                continue;
            };

            for step in walk_from(tree, target.index()) {
                let Step::Enter(held) = step else {
                    continue;
                };

                if self.kind_of(held) != PythonKind::Name {
                    continue;
                }

                let span = self.span_of(held);

                if !self.scratch.push(span) {
                    self.overrun(Completion::ScratchFull);

                    return;
                }
            }
        }
    }

    fn gate(&mut self, node: u32, kind: PythonKind) {
        if kind == PythonKind::Match {
            self.unsupported(Feature::MatchStatement, self.span_of(node));

            return;
        }

        if kind == PythonKind::TypeAlias {
            self.unsupported(Feature::TypeAliasStatement, self.span_of(node));

            return;
        }

        if kind == PythonKind::TypeParams {
            self.unsupported(Feature::TypeParameters, self.span_of(node));

            return;
        }

        if kind == PythonKind::ExceptHandler {
            self.gate_handler(node);
            self.gate_except_tuple(node);

            return;
        }

        if matches!(
            kind,
            PythonKind::ParamSpec | PythonKind::TypeVar | PythonKind::TypeVarTuple
        ) {
            self.gate_type_parameter(node);

            return;
        }

        if matches!(kind, PythonKind::AsyncWith | PythonKind::With) {
            self.gate_with(node);

            return;
        }

        if matches!(kind, PythonKind::Constant | PythonKind::JoinedStr) {
            self.gate_string(node);
        }
    }

    fn gate_handler(&mut self, node: u32) {
        let parent = self.tree.at(node).parent;

        if parent == NONE || self.kind_of(parent) != PythonKind::TryStar {
            return;
        }

        let held = self.view(node);

        let Some(position) = held.token_first(PythonKind::Star) else {
            return;
        };

        self.unsupported(Feature::ExceptStar, held.token_at(position).span());
    }

    fn gate_type_parameter(&mut self, node: u32) {
        let held = self.view(node);

        let Some(position) = held.token_first(PythonKind::Equal) else {
            return;
        };

        self.unsupported(
            Feature::TypeParameterDefaults,
            held.token_at(position).span(),
        );
    }

    fn gate_except_tuple(&mut self, node: u32) {
        let Some(held) = self.view(node).child_first_of(PythonKind::Tuple) else {
            return;
        };

        let span = held.span();

        if self.source.get(span.offset as usize) == Some(&b'(') {
            return;
        }

        self.unsupported(Feature::UnparenthesizedExceptTuple, span);
    }

    fn gate_with(&mut self, node: u32) {
        let held = self.view(node);

        if held.children_of(PythonKind::WithItem).count() < 2 {
            return;
        }

        let Some(position) = held.token_first(PythonKind::ParenOpen) else {
            return;
        };

        self.unsupported(
            Feature::ParenthesizedWithItems,
            held.token_at(position).span(),
        );
    }

    fn gate_string(&mut self, node: u32) {
        let held = self.view(node);

        for position in held.positions() {
            if !matches!(
                held.token_kind(position),
                PythonKind::StringBytes | PythonKind::StringFormat | PythonKind::StringPlain
            ) {
                continue;
            }

            let token = held.token_at(position);

            if !literal::prefix_of(token.text(self.source)).template {
                continue;
            }

            self.unsupported(Feature::TemplateString, token.span());
        }
    }

    fn unsupported(&mut self, feature: Feature, span: Span) {
        if self.version.at_least(feature.since()) {
            return;
        }

        self.report(CheckKind::Unsupported(feature), span);
    }

    fn report(&mut self, kind: CheckKind, span: Span) {
        if !self.errors.push(CheckError { kind, span }) {
            self.overrun(Completion::ErrorsFull);
        }
    }

    fn overrun(&mut self, completion: Completion) {
        assert_ne!(completion, Completion::Complete);

        if self.completion == Completion::Complete {
            self.completion = completion;
        }
    }

    fn kind_of(&self, node: u32) -> PythonKind {
        self.tree.at(node).kind
    }

    fn span_of(&self, node: u32) -> Span {
        self.tree.at(node).span(self.tokens)
    }

    fn view(&self, node: u32) -> View<'run> {
        View::new(self.tree, self.tokens, self.raw, node)
    }
}

pub struct Input<'run> {
    pub raw: &'run [PythonKind],
    pub semantic: &'run Semantic,
    pub source: &'run [u8],
    pub tokens: &'run [Token],
    pub tree: &'run Tree<PythonKind>,
    pub version: PythonVersion,
}

pub fn check(
    input: &Input<'_>,
    errors: &mut BoundedVec<CheckError>,
    scratch: &mut BoundedVec<Span>,
) -> Completion {
    let Input {
        raw,
        semantic,
        source,
        tokens,
        tree,
        version,
    } = *input;

    assert_eq!(tokens.len(), raw.len());

    errors.clear();
    scratch.clear();

    assert_eq!(errors.count(), 0);

    if tree.count() == 0 {
        return Completion::Complete;
    }

    let mut checker = Checker {
        completion: Completion::Complete,
        depth: 0,
        errors,
        frames: [Frame {
            asynchronous: false,
            kind: FrameKind::Module,
            node: NONE,
        }; SCOPE_DEPTH_MAX as usize],
        future_allowed: true,
        raw,
        scratch,
        semantic,
        source,
        target_stack: [NONE; TARGET_STACK_MAX],
        tokens,
        tree,
        version,
    };

    checker.run();

    checker.completion
}

const fn opens_comprehension(kind: PythonKind) -> bool {
    matches!(
        kind,
        PythonKind::DictComp
            | PythonKind::GeneratorExp
            | PythonKind::ListComp
            | PythonKind::SetComp
    )
}

fn irrefutable(pattern: View<'_>) -> bool {
    if pattern.kind() == PythonKind::MatchAs {
        return pattern.children().next().is_none();
    }

    if pattern.kind() != PythonKind::MatchOr {
        return false;
    }

    pattern
        .children()
        .any(|held| held.kind() == PythonKind::MatchAs && held.children().next().is_none())
}

const fn binds_first_child(kind: PythonKind) -> bool {
    matches!(
        kind,
        PythonKind::AsyncFor | PythonKind::Comprehension | PythonKind::For
    )
}

const fn holds_targets(kind: PythonKind) -> bool {
    matches!(
        kind,
        PythonKind::List | PythonKind::Parenthesized | PythonKind::Starred | PythonKind::Tuple
    )
}

const fn opens_frame(kind: PythonKind) -> bool {
    if opens_comprehension(kind) {
        return true;
    }

    matches!(
        kind,
        PythonKind::AsyncFunctionDef
            | PythonKind::ClassDef
            | PythonKind::FunctionDef
            | PythonKind::Lambda
    )
}

const fn frame_kind_of(kind: PythonKind) -> FrameKind {
    if opens_comprehension(kind) {
        return FrameKind::Comprehension;
    }

    if matches!(kind, PythonKind::ClassDef) {
        return FrameKind::Class;
    }

    FrameKind::Function
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::language::Lexer as _;
    use crate::lex::PYTHON;
    use crate::syntax::python::bind::{Outcome as BindOutcome, Tables, bind};
    use crate::syntax::python::classify::classify;
    use crate::syntax::python::parse;
    use crate::syntax::python::semantic::{AnnotationScratch, SemanticInput};
    use crate::token::Tokens;
    use crate::tree::{Events, Structure};

    struct Fixture {
        errors: BoundedVec<CheckError>,
        source: Vec<u8>,
    }

    impl Fixture {
        fn of(source: &[u8], version: PythonVersion) -> Self {
            let mut lexed = Tokens::reserve(1 << 14);
            let mut tokens = Tokens::reserve(1 << 14);
            let mut raw = BoundedVec::reserve(1 << 14);
            let mut events = Events::reserve(1 << 16);
            let mut tree = Tree::<PythonKind>::reserve(1 << 14, 1 << 8);
            let mut tables = Tables::reserve(1 << 8, 1 << 10, 1 << 12, 1 << 10);
            let mut semantic = Semantic::reserve(1 << 10, 1 << 12, 1 << 8);
            let mut scratch = AnnotationScratch::reserve(1 << 8, 1 << 8);
            let mut errors = BoundedVec::reserve(ERROR_COUNT_MAX_DEFAULT);
            let mut names = BoundedVec::reserve(ERROR_COUNT_MAX_DEFAULT);

            PYTHON.lex(source, &mut lexed);

            assert!(classify(source, lexed.as_slice(), &mut tokens, &mut raw));

            assert_eq!(
                parse::build(source, tokens.as_slice(), &raw, &mut events, &mut tree),
                Structure::Complete
            );

            assert_eq!(
                bind(source, tokens.as_slice(), &raw, &tree, &mut tables),
                BindOutcome::Complete
            );

            assert_eq!(
                semantic.build(
                    &SemanticInput {
                        builtins: &[],
                        raw: &raw,
                        scopes: &tables,
                        source,
                        tokens: tokens.as_slice(),
                        tree: &tree,
                        version,
                    },
                    &mut scratch,
                ),
                Structure::Complete
            );

            assert_eq!(
                check(
                    &Input {
                        raw: &raw,
                        semantic: &semantic,
                        source,
                        tokens: tokens.as_slice(),
                        tree: &tree,
                        version,
                    },
                    &mut errors,
                    &mut names,
                ),
                Completion::Complete
            );

            Self {
                errors,
                source: source.to_vec(),
            }
        }

        fn kinds(&self) -> Vec<CheckKind> {
            self.errors.iter().map(|held| held.kind).collect()
        }

        fn rows(&self) -> Vec<(CheckKind, String)> {
            self.errors
                .iter()
                .map(|held| {
                    (
                        held.kind,
                        String::from_utf8_lossy(&self.source[held.span.range()]).into_owned(),
                    )
                })
                .collect()
        }
    }

    const GATED: &[u8] = b"try:\n    pass\nexcept* ValueError:\n    pass\n";

    fn source_of(lines: &[&str]) -> Vec<u8> {
        let mut found = Vec::new();

        for line in lines {
            found.extend_from_slice(line.as_bytes());
            found.push(b'\n');
        }

        found
    }

    #[test]
    fn a_return_outside_a_function_reads_as_an_error() {
        let held = Fixture::of(b"value = 1\nreturn value\n", PythonVersion::Py310);

        assert_eq!(
            held.rows(),
            vec![(CheckKind::ReturnOutsideFunction, "return value".to_owned())]
        );
    }

    #[test]
    fn a_return_inside_a_function_reads_as_nothing() {
        let held = Fixture::of(b"def read():\n    return 1\n", PythonVersion::Py310);

        assert!(held.kinds().is_empty());
    }

    #[test]
    fn a_yield_in_a_class_body_reads_as_an_error() {
        let held = Fixture::of(b"class Holder:\n    yield 1\n", PythonVersion::Py310);

        assert_eq!(held.kinds(), vec![CheckKind::YieldOutsideFunction]);
    }

    #[test]
    fn an_await_in_a_synchronous_function_reads_as_an_error() {
        let held = Fixture::of(
            b"def read(value):\n    return await value\n",
            PythonVersion::Py310,
        );

        assert_eq!(held.kinds(), vec![CheckKind::AwaitOutsideAsync]);
    }

    #[test]
    fn an_await_in_a_comprehension_inherits_the_function_it_stands_in() {
        let held = Fixture::of(
            b"async def read(values):\n    return [await item for item in values]\n",
            PythonVersion::Py310,
        );

        assert!(held.kinds().is_empty());
    }

    #[test]
    fn an_await_in_a_lambda_reads_as_an_error_inside_an_async_function() {
        let held = Fixture::of(
            b"async def read(value):\n    return lambda: (await value)\n",
            PythonVersion::Py310,
        );

        assert_eq!(held.kinds(), vec![CheckKind::AwaitOutsideAsync]);
    }

    #[test]
    fn a_bare_except_before_another_handler_reads_as_an_error() {
        let held = Fixture::of(
            b"try:\n    pass\nexcept:\n    pass\nexcept ValueError:\n    pass\n",
            PythonVersion::Py310,
        );

        assert_eq!(held.kinds(), vec![CheckKind::ExceptNotLast]);
    }

    #[test]
    fn a_bare_except_standing_last_reads_as_nothing() {
        let held = Fixture::of(
            b"try:\n    pass\nexcept ValueError:\n    pass\nexcept:\n    pass\n",
            PythonVersion::Py310,
        );

        assert!(held.kinds().is_empty());
    }

    #[test]
    fn a_duplicate_parameter_reads_at_the_second_one() {
        let held = Fixture::of(b"def read(value, value):\n    pass\n", PythonVersion::Py310);

        assert_eq!(
            held.rows(),
            vec![(CheckKind::DuplicateParameter, "value".to_owned())]
        );

        assert_eq!(held.errors[0].span.offset, 16);
    }

    #[test]
    fn a_lambda_repeating_a_parameter_reads_the_same_way() {
        let held = Fixture::of(b"read = lambda value, value: 0\n", PythonVersion::Py310);

        assert_eq!(held.kinds(), vec![CheckKind::DuplicateParameter]);
    }

    #[test]
    fn a_future_import_below_a_statement_reads_as_late() {
        let held = Fixture::of(
            b"import os\nfrom __future__ import annotations\n",
            PythonVersion::Py310,
        );

        assert_eq!(held.kinds(), vec![CheckKind::FutureImportLate]);
    }

    #[test]
    fn a_future_import_below_the_docstring_reads_as_nothing() {
        let held = Fixture::of(
            b"\"doc\"\nfrom __future__ import annotations\nfrom __future__ import division\n",
            PythonVersion::Py310,
        );

        assert!(held.kinds().is_empty());
    }

    #[test]
    fn a_global_declared_below_a_read_names_the_read() {
        let held = Fixture::of(
            b"counter = 0\ndef read():\n    print(counter)\n    global counter\n    counter = 1\n",
            PythonVersion::Py310,
        );

        assert_eq!(
            held.rows(),
            vec![(CheckKind::GlobalAfterUse, "counter".to_owned())]
        );
    }

    #[test]
    fn a_global_declared_above_every_read_reads_as_nothing() {
        let held = Fixture::of(
            b"counter = 0\ndef read():\n    global counter\n    print(counter)\n",
            PythonVersion::Py310,
        );

        assert!(held.kinds().is_empty());
    }

    #[test]
    fn a_nonlocal_at_module_level_reads_as_an_error() {
        let held = Fixture::of(b"held = 1\nnonlocal held\n", PythonVersion::Py310);

        assert_eq!(held.kinds(), vec![CheckKind::NonlocalAtModule]);
    }

    #[test]
    fn a_nonlocal_with_no_enclosing_binding_names_the_identifier() {
        let held = Fixture::of(
            b"def outer():\n    def inner():\n        nonlocal missing\n        missing = 1\n",
            PythonVersion::Py310,
        );

        assert_eq!(
            held.rows(),
            vec![(CheckKind::NonlocalWithoutBinding, "missing".to_owned())]
        );
    }

    #[test]
    fn a_nonlocal_reaching_past_a_class_body_reads_as_unbound() {
        let held = Fixture::of(
            b"class Holder:\n    held = 1\n\n    def read(self):\n        nonlocal held\n",
            PythonVersion::Py310,
        );

        assert_eq!(held.kinds(), vec![CheckKind::NonlocalWithoutBinding]);
    }

    #[test]
    fn a_nonlocal_finding_a_binding_two_scopes_out_reads_as_nothing() {
        let source = source_of(&[
            "def outer():",
            "    def middle():",
            "        def inner():",
            "            nonlocal held",
            "            held = 1",
            "    held = 2",
        ]);

        let held = Fixture::of(&source, PythonVersion::Py310);

        assert!(held.kinds().is_empty());
    }

    #[test]
    fn two_starred_targets_read_on_the_tuple_that_holds_them() {
        let held = Fixture::of(
            b"values = [1]\n*first, *second = values\n",
            PythonVersion::Py310,
        );

        assert_eq!(
            held.rows(),
            vec![(CheckKind::StarredMultiple, "*first, *second".to_owned())]
        );
    }

    #[test]
    fn two_starred_targets_nested_one_level_read_on_the_inner_tuple() {
        let held = Fixture::of(
            b"values = [1]\nfirst, (second, *third, *fourth) = values\n",
            PythonVersion::Py310,
        );

        assert_eq!(
            held.rows(),
            vec![(
                CheckKind::StarredMultiple,
                "(second, *third, *fourth)".to_owned()
            )]
        );
    }

    #[test]
    fn one_starred_value_reads_as_nothing() {
        let held = Fixture::of(
            b"values = [1]\nfirst = *values, *values\n",
            PythonVersion::Py310,
        );

        assert!(held.kinds().is_empty());
    }

    #[test]
    fn a_call_written_to_in_a_for_target_reads_as_an_invalid_assignment_target() {
        let held = Fixture::of(
            b"def read():\n    pass\nfor read() in [1]:\n    pass\n",
            PythonVersion::Py310,
        );

        assert_eq!(
            held.rows(),
            vec![(CheckKind::TargetAssignInvalid, "read()".to_owned())]
        );
    }

    #[test]
    fn a_call_written_to_in_a_with_target_reads_as_an_invalid_assignment_target() {
        let held = Fixture::of(
            b"def read():\n    pass\nwith read as read():\n    pass\n",
            PythonVersion::Py310,
        );

        assert_eq!(
            held.rows(),
            vec![(CheckKind::TargetAssignInvalid, "read()".to_owned())]
        );
    }

    #[test]
    fn a_call_written_to_in_a_comprehension_target_reads_as_an_invalid_assignment_target() {
        let held = Fixture::of(
            b"def read():\n    pass\nheld = [1 for read() in [1]]\n",
            PythonVersion::Py310,
        );

        assert_eq!(
            held.rows(),
            vec![(CheckKind::TargetAssignInvalid, "read()".to_owned())]
        );
    }

    #[test]
    fn two_starred_targets_of_a_for_read_on_the_tuple() {
        let held = Fixture::of(
            b"for *first, *second in [1]:\n    pass\n",
            PythonVersion::Py310,
        );

        assert_eq!(
            held.rows(),
            vec![(CheckKind::StarredMultiple, "*first, *second".to_owned())]
        );
    }

    #[test]
    fn a_call_written_to_reads_as_an_invalid_assignment_target() {
        let held = Fixture::of(b"def read():\n    pass\nread() = 1\n", PythonVersion::Py310);

        assert_eq!(
            held.rows(),
            vec![(CheckKind::TargetAssignInvalid, "read()".to_owned())]
        );
    }

    #[test]
    fn a_call_written_to_inside_a_tuple_names_the_call() {
        let held = Fixture::of(
            b"def read():\n    pass\nheld, read() = 1, 2\n",
            PythonVersion::Py310,
        );

        assert_eq!(
            held.rows(),
            vec![(CheckKind::TargetAssignInvalid, "read()".to_owned())]
        );
    }

    #[test]
    fn a_starred_target_standing_alone_reads_as_an_error() {
        let held = Fixture::of(b"*held = [1]\n", PythonVersion::Py310);

        assert_eq!(
            held.rows(),
            vec![(CheckKind::StarredTargetAlone, "*held".to_owned())]
        );

        let inner = Fixture::of(b"*held, = [1]\n[*held] = [1]\n", PythonVersion::Py310);

        assert!(inner.kinds().is_empty());
    }

    #[test]
    fn a_call_deleted_reads_as_an_invalid_delete_target() {
        let held = Fixture::of(b"def read():\n    pass\ndel read()\n", PythonVersion::Py310);

        assert_eq!(
            held.rows(),
            vec![(CheckKind::TargetDeleteInvalid, "read()".to_owned())]
        );
    }

    #[test]
    fn an_attribute_and_a_subscript_are_targets_the_grammar_allows() {
        let held = Fixture::of(
            b"held = [0]\nheld[0] = 1\nheld.first = 2\ndel held[0], held.first\n",
            PythonVersion::Py310,
        );

        assert!(held.kinds().is_empty());
    }

    #[test]
    fn an_irrefutable_case_before_another_names_the_pattern() {
        let source = source_of(&[
            "def read(value):",
            "    match value:",
            "        case _:",
            "            return 0",
            "        case 1:",
            "            return 1",
        ]);

        let held = Fixture::of(&source, PythonVersion::Py310);

        assert_eq!(
            held.rows(),
            vec![(CheckKind::IrrefutableCaseNotLast, "_".to_owned())]
        );
    }

    #[test]
    fn an_irrefutable_case_under_a_guard_reads_as_nothing() {
        let source = source_of(&[
            "def read(value, other):",
            "    match value:",
            "        case _ if other:",
            "            return 0",
            "        case 1:",
            "            return 1",
        ]);

        let held = Fixture::of(&source, PythonVersion::Py310);

        assert!(held.kinds().is_empty());
    }

    #[test]
    fn a_walrus_in_a_comprehension_iterable_reads_as_an_error() {
        let held = Fixture::of(
            b"values = [1]\nfound = [item for item in (other := values)]\n",
            PythonVersion::Py310,
        );

        assert_eq!(
            held.rows(),
            vec![(
                CheckKind::WalrusInComprehensionIterable,
                "other := values".to_owned()
            )]
        );
    }

    #[test]
    fn a_walrus_rebinding_a_comprehension_variable_reads_as_an_error() {
        let held = Fixture::of(
            b"values = [1]\nfound = [item for item in values if (item := 0)]\n",
            PythonVersion::Py310,
        );

        assert_eq!(
            held.kinds(),
            vec![CheckKind::WalrusRebindsComprehensionVariable]
        );
    }

    #[test]
    fn a_walrus_rebinding_from_the_element_expression_reads_the_same_way() {
        let held = Fixture::of(
            b"values = [1]\nfound = [(item := 2) for item in values]\n",
            PythonVersion::Py310,
        );

        assert_eq!(
            held.kinds(),
            vec![CheckKind::WalrusRebindsComprehensionVariable]
        );
    }

    #[test]
    fn a_walrus_writing_another_name_reads_as_nothing() {
        let held = Fixture::of(
            b"values = [1]\nfound = [item for item in values if (other := item)]\n",
            PythonVersion::Py310,
        );

        assert!(held.kinds().is_empty());
    }

    #[test]
    fn a_match_statement_is_unsupported_before_python_310() {
        let source = b"def read(value):\n    match value:\n        case 1:\n            return 1\n";

        assert_eq!(
            Fixture::of(source, PythonVersion::Py39).kinds(),
            vec![CheckKind::Unsupported(Feature::MatchStatement)]
        );

        assert!(Fixture::of(source, PythonVersion::Py310).kinds().is_empty());
    }

    #[test]
    fn a_type_alias_statement_is_unsupported_before_python_312() {
        let source = b"type Held = int\n";

        assert_eq!(
            Fixture::of(source, PythonVersion::Py311).kinds(),
            vec![CheckKind::Unsupported(Feature::TypeAliasStatement)]
        );

        assert!(Fixture::of(source, PythonVersion::Py312).kinds().is_empty());
    }

    #[test]
    fn a_type_parameter_list_is_unsupported_before_python_312() {
        let source = b"def read[Held](value: Held) -> Held:\n    return value\n";

        assert_eq!(
            Fixture::of(source, PythonVersion::Py311).kinds(),
            vec![CheckKind::Unsupported(Feature::TypeParameters)]
        );

        assert!(Fixture::of(source, PythonVersion::Py312).kinds().is_empty());
    }

    #[test]
    fn a_type_parameter_default_is_unsupported_before_python_313() {
        let source = b"def read[Held = int]() -> Held:\n    return Held()\n";

        assert_eq!(
            Fixture::of(source, PythonVersion::Py312).rows(),
            vec![(
                CheckKind::Unsupported(Feature::TypeParameterDefaults),
                "=".to_owned()
            )]
        );

        assert!(Fixture::of(source, PythonVersion::Py313).kinds().is_empty());
    }

    #[test]
    fn an_unparenthesized_except_tuple_is_unsupported_before_python_314() {
        let source = b"try:\n    pass\nexcept ValueError, TypeError:\n    pass\n";

        assert_eq!(
            Fixture::of(source, PythonVersion::Py313).rows(),
            vec![(
                CheckKind::Unsupported(Feature::UnparenthesizedExceptTuple),
                "ValueError, TypeError".to_owned()
            )]
        );

        assert!(Fixture::of(source, PythonVersion::Py314).kinds().is_empty());

        assert!(
            Fixture::of(
                b"try:\n    pass\nexcept (ValueError, TypeError):\n    pass\n",
                PythonVersion::Py313
            )
            .kinds()
            .is_empty()
        );
    }

    #[test]
    fn an_except_star_is_unsupported_before_python_311() {
        assert_eq!(
            Fixture::of(GATED, PythonVersion::Py310).kinds(),
            vec![CheckKind::Unsupported(Feature::ExceptStar)]
        );

        assert!(Fixture::of(GATED, PythonVersion::Py311).kinds().is_empty());
    }

    #[test]
    fn parenthesized_with_items_are_unsupported_before_python_39() {
        let source = source_of(&[
            "def read(first, second):",
            "    with (first as one, second as two):",
            "        return one, two",
        ]);

        assert_eq!(
            Fixture::of(&source, PythonVersion::Py38).kinds(),
            vec![CheckKind::Unsupported(Feature::ParenthesizedWithItems)]
        );

        assert!(Fixture::of(&source, PythonVersion::Py39).kinds().is_empty());
    }

    #[test]
    fn one_parenthesized_with_item_is_no_version_gate_at_all() {
        let source = b"def read(first):\n    with (first as one):\n        return one\n";

        assert!(Fixture::of(source, PythonVersion::Py38).kinds().is_empty());
    }

    #[test]
    fn a_template_string_is_unsupported_before_python_314() {
        let source = b"held = t\"text\"\n";

        assert_eq!(
            Fixture::of(source, PythonVersion::Py313).kinds(),
            vec![CheckKind::Unsupported(Feature::TemplateString)]
        );

        assert!(Fixture::of(source, PythonVersion::Py314).kinds().is_empty());
    }

    #[test]
    fn a_plain_string_is_no_template_however_it_is_written() {
        let source = b"held = \"text\"\nother = rb\"text\"\nthird = f\"{held}\"\n";

        assert!(Fixture::of(source, PythonVersion::Py38).kinds().is_empty());
    }

    #[test]
    fn every_feature_names_itself_and_the_release_that_added_it() {
        let features = [
            Feature::ExceptStar,
            Feature::MatchStatement,
            Feature::ParenthesizedWithItems,
            Feature::TemplateString,
            Feature::TypeAliasStatement,
            Feature::TypeParameterDefaults,
            Feature::TypeParameters,
            Feature::UnparenthesizedExceptTuple,
        ];

        for feature in features {
            assert!(!feature.name().is_empty());
            assert!(feature.message().len() > feature.name().len());
            assert!(feature.since().at_least(PythonVersion::Py39));
        }
    }

    #[test]
    fn an_error_table_that_fills_reports_the_pass_incomplete() {
        let mut lexed = Tokens::reserve(1 << 14);
        let mut tokens = Tokens::reserve(1 << 14);
        let mut raw = BoundedVec::reserve(1 << 14);
        let mut events = Events::reserve(1 << 16);
        let mut tree = Tree::<PythonKind>::reserve(1 << 14, 1 << 8);
        let mut tables = Tables::reserve(1 << 8, 1 << 10, 1 << 12, 1 << 10);
        let mut semantic = Semantic::reserve(1 << 10, 1 << 12, 1 << 8);
        let mut scratch = AnnotationScratch::reserve(1 << 8, 1 << 8);
        let mut errors = BoundedVec::reserve(1);
        let mut names = BoundedVec::reserve(1 << 10);
        let mut source = Vec::from(b"return 1\n".as_slice());

        source.extend_from_slice(b"return 2\n");

        PYTHON.lex(&source, &mut lexed);

        assert!(classify(&source, lexed.as_slice(), &mut tokens, &mut raw));

        parse::build(&source, tokens.as_slice(), &raw, &mut events, &mut tree);

        assert_eq!(
            bind(&source, tokens.as_slice(), &raw, &tree, &mut tables),
            BindOutcome::Complete
        );

        semantic.build(
            &SemanticInput {
                builtins: &[],
                raw: &raw,
                scopes: &tables,
                source: &source,
                tokens: tokens.as_slice(),
                tree: &tree,
                version: PythonVersion::Py310,
            },
            &mut scratch,
        );

        assert_eq!(
            check(
                &Input {
                    raw: &raw,
                    semantic: &semantic,
                    source: &source,
                    tokens: tokens.as_slice(),
                    tree: &tree,
                    version: PythonVersion::Py310,
                },
                &mut errors,
                &mut names,
            ),
            Completion::ErrorsFull
        );

        assert_eq!(errors.count(), 1);
    }

    #[test]
    fn every_kind_carries_a_code_and_a_message() {
        let kinds = [
            CheckKind::AwaitOutsideAsync,
            CheckKind::AwaitOutsideFunction,
            CheckKind::DuplicateParameter,
            CheckKind::ExceptNotLast,
            CheckKind::FutureImportLate,
            CheckKind::GlobalAfterUse,
            CheckKind::IrrefutableCaseNotLast,
            CheckKind::NonlocalAtModule,
            CheckKind::NonlocalWithoutBinding,
            CheckKind::ReturnOutsideFunction,
            CheckKind::StarredMultiple,
            CheckKind::StarredTargetAlone,
            CheckKind::TargetAssignInvalid,
            CheckKind::TargetDeleteInvalid,
            CheckKind::Unsupported(Feature::MatchStatement),
            CheckKind::WalrusInComprehensionIterable,
            CheckKind::WalrusRebindsComprehensionVariable,
            CheckKind::YieldOutsideFunction,
        ];

        for kind in kinds {
            assert!(!kind.code().is_empty());
            assert!(!kind.message().is_empty());
        }
    }
}
