use crate::bounded::Span;
use crate::diagnostic::{Diagnostic, Diagnostics, Message, Severity};
use crate::fix::NONE as FIX_NONE;
use crate::markup;
use crate::project::store::{FileID, Store};
use crate::rule::Registry;
use crate::syntax::front::{Front, Tables};
use crate::syntax::{css, go, javascript, odin, python, rust, typescript, zig};
use crate::tree::{Walk, walk, walk_from};

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct Node {
    pub file: FileID,
    pub node: u32,
}

pub struct Sink<'run> {
    diagnostics: &'run mut Diagnostics,
    file: FileID,
    registry: &'run Registry,
}

impl Node {
    pub const fn new(file: FileID, node: u32) -> Self {
        Self { file, node }
    }
}

impl<'run> Sink<'run> {
    pub fn new(file: FileID, diagnostics: &'run mut Diagnostics, registry: &'run Registry) -> Self {
        Self {
            diagnostics,
            file,
            registry,
        }
    }

    pub fn rule_of(&self, code: &str) -> u32 {
        self.registry.index_of(code)
    }

    pub fn count(&self) -> u32 {
        self.diagnostics.count()
    }

    pub const fn file(&self) -> FileID {
        self.file
    }

    #[must_use]
    pub fn record(
        &mut self,
        code: &'static str,
        severity: Severity,
        span: Span,
        text: &'static str,
    ) -> bool {
        assert!(!code.is_empty());

        let rule = self.registry.index_of(code);

        self.diagnostics.push(Diagnostic {
            code,
            fix: FIX_NONE,
            message: Message::Static(text),
            rule,
            severity,
            span,
        })
    }

    #[must_use]
    pub fn record_formatted(
        &mut self,
        code: &'static str,
        severity: Severity,
        span: Span,
        arguments: core::fmt::Arguments<'_>,
    ) -> bool {
        assert!(!code.is_empty());

        let rule = self.registry.index_of(code);

        self.diagnostics
            .push_formatted_for(code, rule, severity, span, FIX_NONE, arguments)
    }

    #[must_use]
    pub fn record_fixed(
        &mut self,
        code: &'static str,
        severity: Severity,
        span: Span,
        text: &'static str,
        fix: u32,
    ) -> bool {
        assert!(!code.is_empty());

        let rule = self.registry.index_of(code);

        self.diagnostics.push(Diagnostic {
            code,
            fix,
            message: Message::Static(text),
            rule,
            severity,
            span,
        })
    }
}

#[expect(
    clippy::multiple_inherent_impl,
    reason = "the view accessors live in `view.rs`, beside the `Node` and `Sink` they exist for, \
              rather than in `store.rs`"
)]
impl Store {
    pub fn css_view(&self, file: FileID, node: u32) -> Option<css::ast::View<'_>> {
        let Tables::Css { syntax, .. } = self.tables_of(file).tables() else {
            return None;
        };

        if node >= syntax.tree.count() {
            return None;
        }

        Some(css::ast::View::new(
            &syntax.tree,
            syntax.tokens.as_slice(),
            &syntax.raw,
            node,
        ))
    }

    pub fn go_view(&self, file: FileID, node: u32) -> Option<go::ast::View<'_>> {
        let Tables::Go { syntax, .. } = self.tables_of(file).tables() else {
            return None;
        };

        if node >= syntax.tree.count() {
            return None;
        }

        Some(go::ast::View::new(
            &syntax.tree,
            syntax.tokens.as_slice(),
            &syntax.raw,
            node,
        ))
    }

    pub fn javascript_view(&self, file: FileID, node: u32) -> Option<javascript::ast::View<'_>> {
        let Tables::JavaScript { syntax, .. } = self.tables_of(file).tables() else {
            return None;
        };

        if node >= syntax.tree.count() {
            return None;
        }

        Some(javascript::ast::View::new(
            &syntax.tree,
            syntax.tokens.as_slice(),
            &syntax.raw,
            node,
        ))
    }

    pub fn markup_view(&self, file: FileID, node: u32) -> Option<markup::view::View<'_, '_>> {
        let Tables::Markup { tokens, tree, .. } = self.tables_of(file).tables() else {
            return None;
        };

        if node >= tree.count() {
            return None;
        }

        Some(markup::view::View::new(tree, tokens.as_slice(), node))
    }

    pub fn odin_view(&self, file: FileID, node: u32) -> Option<odin::ast::View<'_>> {
        let Tables::Odin { syntax, .. } = self.tables_of(file).tables() else {
            return None;
        };

        if node >= syntax.tree.count() {
            return None;
        }

        Some(odin::ast::View::new(
            &syntax.tree,
            syntax.tokens.as_slice(),
            &syntax.raw,
            node,
        ))
    }

    pub fn python_view(&self, file: FileID, node: u32) -> Option<python::ast::View<'_>> {
        let Tables::Python { syntax, .. } = self.tables_of(file).tables() else {
            return None;
        };

        if node >= syntax.tree.count() {
            return None;
        }

        Some(python::ast::View::new(
            &syntax.tree,
            syntax.tokens.as_slice(),
            &syntax.raw,
            node,
        ))
    }

    pub fn rust_view(&self, file: FileID, node: u32) -> Option<rust::ast::View<'_>> {
        let Tables::Rust { syntax, .. } = self.tables_of(file).tables() else {
            return None;
        };

        if node >= syntax.tree.count() {
            return None;
        }

        Some(rust::ast::View::new(
            &syntax.tree,
            syntax.tokens.as_slice(),
            &syntax.raw,
            node,
        ))
    }

    pub fn typescript_view(&self, file: FileID, node: u32) -> Option<typescript::ast::View<'_>> {
        let Tables::TypeScript { syntax, .. } = self.tables_of(file).tables() else {
            return None;
        };

        if node >= syntax.tree.count() {
            return None;
        }

        Some(typescript::ast::View::new(
            &syntax.tree,
            syntax.tokens.as_slice(),
            &syntax.raw,
            node,
        ))
    }

    pub fn zig_view(&self, file: FileID, node: u32) -> Option<zig::ast::View<'_>> {
        let Tables::Zig { syntax, .. } = self.tables_of(file).tables() else {
            return None;
        };

        if node >= syntax.tree.count() {
            return None;
        }

        Some(zig::ast::View::new(
            &syntax.tree,
            syntax.tokens.as_slice(),
            &syntax.raw,
            node,
        ))
    }

    pub fn walk(&self, file: FileID) -> Walk<'_, Front> {
        walk(self.tables_of(file))
    }

    pub fn walk_from(&self, file: FileID, node: u32) -> Walk<'_, Front> {
        walk_from(self.tables_of(file), node)
    }
}
