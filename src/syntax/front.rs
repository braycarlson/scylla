use crate::bounded::{BoundedVec, Span, count_of};
use crate::language::{Language, Lexer};
use crate::lex::{CSS, GO, JAVASCRIPT, ODIN, PYTHON, RUST, TYPESCRIPT, ZIG};
use crate::markup;
use crate::markup::kind::MarkupKind;
use crate::markup::tree::TreeError;
use crate::syntax::Category;
use crate::syntax::binding::Bindings;
use crate::syntax::css::classify::classify as css_classify;
use crate::syntax::css::kind::CSSKind;
use crate::syntax::css::parse as css_parse;
use crate::syntax::css::semantic::{Definition as CSSDefinition, Semantic as CSSSemantic};
use crate::syntax::go::ast as go;
use crate::syntax::go::classify::classify as go_classify;
use crate::syntax::go::kind::GoKind;
use crate::syntax::go::parse as go_parse;
use crate::syntax::go::semantic::{Binding as GoBinding, Semantic as GoSemantic};
use crate::syntax::javascript::ast as javascript;
use crate::syntax::javascript::classify::classify as javascript_classify;
use crate::syntax::javascript::kind::JavaScriptKind;
use crate::syntax::javascript::parse as javascript_parse;
use crate::syntax::javascript::semantic::{
    Binding as JavaScriptBinding,
    Semantic as JavaScriptSemantic,
};
use crate::syntax::odin::ast as odin;
use crate::syntax::odin::classify::classify as odin_classify;
use crate::syntax::odin::kind::OdinKind;
use crate::syntax::odin::parse as odin_parse;
use crate::syntax::odin::semantic::{Binding as OdinBinding, Semantic as OdinSemantic};
use crate::syntax::python::ast as python;
use crate::syntax::python::bind::{self, Tables as PythonTables};
use crate::syntax::python::check::{self, CheckError as PythonCheckError, Completion};
use crate::syntax::python::classify::classify as python_classify;
use crate::syntax::python::kind::PythonKind;
use crate::syntax::python::parse as python_parse;
use crate::syntax::python::semantic::{
    AnnotationScratch as PythonAnnotationScratch,
    Binding as PythonBinding,
    Semantic as PythonSemantic,
    SemanticInput as PythonSemanticInput,
};
use crate::syntax::python::stdlib::PythonVersion;
use crate::syntax::rust::ast as rust;
use crate::syntax::rust::classify::classify as rust_classify;
use crate::syntax::rust::kind::RustKind;
use crate::syntax::rust::parse as rust_parse;
use crate::syntax::rust::semantic::{Binding as RustBinding, Semantic as RustSemantic};
use crate::syntax::typescript::ast as typescript;
use crate::syntax::typescript::classify::classify as typescript_classify;
use crate::syntax::typescript::dialect::Dialect;
use crate::syntax::typescript::kind::TypeScriptKind;
use crate::syntax::typescript::parse as typescript_parse;
use crate::syntax::view::View;
use crate::syntax::zig::ast as zig;
use crate::syntax::zig::classify::classify as zig_classify;
use crate::syntax::zig::kind::ZigKind;
use crate::syntax::zig::parse as zig_parse;
use crate::syntax::zig::semantic::{Binding as ZigBinding, Semantic as ZigSemantic};
use crate::syntax::{Fact, Facts, SyntaxError};
use crate::token::{Lex, Token, Tokens};
use crate::tree::{Events, Index, Kind, Links, Structure, Tree};

pub const NONE: u32 = u32::MAX;
const ANNOTATION_NODE_COUNT_MAX: u32 = 1 << 8;
const ANNOTATION_TOKEN_COUNT_MAX: u32 = 1 << 8;

#[expect(
    clippy::struct_field_names,
    reason = "the `_max` postfix is the big-endian convention naming the bound each field carries"
)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Limits {
    pub binding_count_max: u32,
    pub error_count_max: u32,
    pub event_count_max: u32,
    pub export_count_max: u32,
    pub fact_count_max: u32,
    pub node_count_max: u32,
    pub reference_count_max: u32,
    pub scope_count_max: u32,
    pub segment_count_max: u32,
    pub token_count_max: u32,
}

impl Limits {
    #[must_use]
    pub fn shrunk(&self, shift: u32) -> Self {
        assert!(shift < u32::BITS);

        Self {
            binding_count_max: shrunk_of(self.binding_count_max, shift),
            error_count_max: shrunk_of(self.error_count_max, shift),
            event_count_max: shrunk_of(self.event_count_max, shift),
            export_count_max: shrunk_of(self.export_count_max, shift),
            fact_count_max: shrunk_of(self.fact_count_max, shift),
            node_count_max: shrunk_of(self.node_count_max, shift),
            reference_count_max: shrunk_of(self.reference_count_max, shift),
            scope_count_max: shrunk_of(self.scope_count_max, shift),
            segment_count_max: shrunk_of(self.segment_count_max, shift),
            token_count_max: shrunk_of(self.token_count_max, shift),
        }
    }
}

pub fn shrunk_of(count: u32, shift: u32) -> u32 {
    assert!(shift < u32::BITS);

    let shrunk = (count >> shift).max(1);

    assert!(shrunk >= 1);
    assert!(shrunk <= count.max(1));

    shrunk
}

#[derive(Clone, Copy, Debug)]
pub struct Options<'run> {
    pub globals: &'run [&'run [u8]],
    pub python_version: PythonVersion,
}

pub struct Front {
    language: Language,
    outcome: Structure,
    tables: Tables,
}

pub(crate) struct Syntax<K: Kind> {
    pub(crate) index: Index<K>,
    pub(crate) raw: BoundedVec<K>,
    pub(crate) tokens: Tokens,
    pub(crate) tree: Tree<K>,
}

#[expect(
    clippy::large_enum_variant,
    reason = "boxing a variant would allocate, which the project store forbids"
)]
pub(crate) enum Tables {
    Css {
        semantic: CSSSemantic,
        syntax: Syntax<CSSKind>,
    },
    Go {
        semantic: GoSemantic,
        syntax: Syntax<GoKind>,
    },
    JavaScript {
        semantic: JavaScriptSemantic,
        syntax: Syntax<JavaScriptKind>,
    },
    Markup {
        facts: Facts,
        tokens: markup::Tokens,
        tree: Tree<MarkupKind>,
    },
    Odin {
        semantic: OdinSemantic,
        syntax: Syntax<OdinKind>,
    },
    Python {
        checks: BoundedVec<PythonCheckError>,
        scopes: PythonTables,
        semantic: PythonSemantic,
        syntax: Syntax<PythonKind>,
    },
    Rust {
        semantic: RustSemantic,
        syntax: Syntax<RustKind>,
    },
    TypeScript {
        semantic: JavaScriptSemantic,
        syntax: Syntax<TypeScriptKind>,
    },
    Zig {
        semantic: ZigSemantic,
        syntax: Syntax<ZigKind>,
    },
}

pub struct Scratch {
    css: Option<Events<CSSKind>>,
    go: Option<Events<GoKind>>,
    javascript: Option<Events<JavaScriptKind>>,
    odin: Option<Events<OdinKind>>,
    python: Option<Events<PythonKind>>,
    python_annotation: Option<PythonAnnotationScratch>,
    rust: Option<Events<RustKind>>,
    typescript: Option<Events<TypeScriptKind>>,
    zig: Option<Events<ZigKind>>,
}

pub(crate) trait Declared {
    fn name(&self) -> Span;
    fn node(&self) -> u32;
    fn scope(&self) -> u32;
}

impl Declared for CSSDefinition {
    fn name(&self) -> Span {
        self.name
    }

    fn node(&self) -> u32 {
        self.node
    }

    fn scope(&self) -> u32 {
        0
    }
}

impl Declared for GoBinding {
    fn name(&self) -> Span {
        self.name
    }

    fn node(&self) -> u32 {
        self.node
    }

    fn scope(&self) -> u32 {
        self.scope
    }
}

impl Declared for JavaScriptBinding {
    fn name(&self) -> Span {
        self.name
    }

    fn node(&self) -> u32 {
        self.node
    }

    fn scope(&self) -> u32 {
        self.scope
    }
}

impl Declared for OdinBinding {
    fn name(&self) -> Span {
        self.name
    }

    fn node(&self) -> u32 {
        self.node
    }

    fn scope(&self) -> u32 {
        self.scope
    }
}

impl Declared for PythonBinding {
    fn name(&self) -> Span {
        self.name
    }

    fn node(&self) -> u32 {
        self.node
    }

    fn scope(&self) -> u32 {
        self.scope
    }
}

impl Declared for RustBinding {
    fn name(&self) -> Span {
        self.name
    }

    fn node(&self) -> u32 {
        self.node
    }

    fn scope(&self) -> u32 {
        self.scope
    }
}

impl Declared for ZigBinding {
    fn name(&self) -> Span {
        self.name
    }

    fn node(&self) -> u32 {
        self.node
    }

    fn scope(&self) -> u32 {
        self.scope
    }
}

impl Front {
    pub fn reserve(language: Language, limits: &Limits) -> Self {
        assert!(limits.node_count_max > 0);
        assert!(limits.token_count_max > 0);

        assert!(!crate::allocation::is_frozen());

        Self {
            language,
            outcome: Structure::Truncated,
            tables: Tables::reserve(language, limits),
        }
    }

    pub fn build(
        &mut self,
        source: &[u8],
        lexed: &[Token],
        scratch: &mut Scratch,
        options: &Options<'_>,
    ) -> Structure {
        assert!(u32::try_from(source.len()).is_ok());

        self.tables.clear();

        let dialect = dialect_of(self.language);

        self.outcome = build_of(source, &mut self.tables, lexed, scratch, options, dialect);

        if self.outcome == Structure::Complete {
            self.tables.index_build();
        } else {
            self.tables.clear();
        }

        self.outcome
    }

    pub fn clear(&mut self) {
        self.outcome = Structure::Truncated;
        self.tables.clear();

        assert_eq!(self.count(), 0);
    }

    pub fn count(&self) -> u32 {
        self.tables.count()
    }

    pub(crate) fn declaration_of(&self, source: &[u8], name: &[u8]) -> u32 {
        self.tables.declaration_of(source, name)
    }

    pub fn errors(&self) -> &[SyntaxError] {
        self.tables.errors()
    }

    pub fn facts(&self) -> &[Fact] {
        self.tables.facts()
    }

    pub const fn language(&self) -> Language {
        self.language
    }

    pub fn markup_errors(&self) -> &[TreeError] {
        match &self.tables {
            Tables::Markup { tree, .. } => tree.errors(),
            Tables::Css { .. }
            | Tables::Go { .. }
            | Tables::JavaScript { .. }
            | Tables::Odin { .. }
            | Tables::Python { .. }
            | Tables::Rust { .. }
            | Tables::TypeScript { .. }
            | Tables::Zig { .. } => &[],
        }
    }

    pub const fn outcome(&self) -> Structure {
        self.outcome
    }

    pub fn python_checks(&self) -> &[PythonCheckError] {
        match &self.tables {
            Tables::Python { checks, .. } => checks,
            Tables::Css { .. }
            | Tables::Go { .. }
            | Tables::JavaScript { .. }
            | Tables::Markup { .. }
            | Tables::Odin { .. }
            | Tables::Rust { .. }
            | Tables::TypeScript { .. }
            | Tables::Zig { .. } => &[],
        }
    }

    pub(crate) const fn tables(&self) -> &Tables {
        &self.tables
    }

    pub fn tokens(&self) -> &[Token] {
        self.tables.tokens()
    }

    pub fn bindings(&self) -> Bindings<'_> {
        if self.outcome != Structure::Complete {
            return Bindings::Empty;
        }

        match &self.tables {
            Tables::Css { .. } | Tables::Markup { .. } => Bindings::Empty,
            Tables::Go { semantic, .. } => Bindings::Go(semantic),
            Tables::JavaScript { semantic, .. } | Tables::TypeScript { semantic, .. } => {
                Bindings::JavaScript(semantic)
            }
            Tables::Odin { semantic, .. } => Bindings::Odin(semantic),
            Tables::Python { semantic, .. } => Bindings::Python(semantic),
            Tables::Rust { semantic, .. } => Bindings::Rust(semantic),
            Tables::Zig { semantic, .. } => Bindings::Zig(semantic),
        }
    }

    pub fn index_of(&self, category: Category) -> &[u32] {
        self.tables.index_of(category)
    }

    pub fn root(&self) -> Option<View<'_>> {
        if self.count() == 0 {
            return None;
        }

        self.view(0)
    }

    pub fn view(&self, node: u32) -> Option<View<'_>> {
        assert!(node < self.count());

        self.tables.view(node)
    }
}

impl Links for Front {
    fn count(&self) -> u32 {
        self.tables.count()
    }

    fn first_child_of(&self, node: u32) -> u32 {
        self.tables.first_child_of(node)
    }

    fn next_sibling_of(&self, node: u32) -> u32 {
        self.tables.next_sibling_of(node)
    }

    fn parent_of(&self, node: u32) -> u32 {
        self.tables.parent_of(node)
    }
}

impl<K: Kind> Syntax<K> {
    fn reserve(limits: &Limits) -> Self {
        assert!(!crate::allocation::is_frozen());

        Self {
            index: Index::reserve(limits.node_count_max),
            raw: BoundedVec::reserve(limits.token_count_max),
            tokens: Tokens::reserve(limits.token_count_max),
            tree: Tree::reserve(limits.node_count_max, limits.error_count_max),
        }
    }

    fn index_build(&mut self) {
        self.index.build(&self.tree);

        assert_eq!(self.index.count(), self.tree.count());
    }

    fn clear(&mut self) {
        self.index.clear();
        self.raw.clear();
        self.tokens.clear();
        self.tree.clear();

        assert_eq!(self.raw.count(), 0);
        assert_eq!(self.tree.count(), 0);
    }
}

impl Tables {
    fn reserve(language: Language, limits: &Limits) -> Self {
        assert!(!crate::allocation::is_frozen());

        match language {
            Language::Css => reserve_css(limits),
            Language::Go => reserve_go(limits),
            Language::JavaScript => reserve_javascript(limits),
            Language::Markup => reserve_markup(limits),
            Language::Odin => reserve_odin(limits),
            Language::Python => reserve_python(limits),
            Language::Rust => reserve_rust(limits),
            Language::Tsx | Language::TypeScript => reserve_typescript(limits),
            Language::Zig => reserve_zig(limits),
        }
    }

    fn clear(&mut self) {
        match self {
            Self::Css { semantic, syntax } => {
                semantic.clear();
                syntax.clear();
            }
            Self::Go { semantic, syntax } => {
                semantic.clear();
                syntax.clear();
            }
            Self::JavaScript { semantic, syntax } => {
                semantic.clear();
                syntax.clear();
            }
            Self::Markup {
                facts,
                tokens,
                tree,
            } => {
                facts.clear();
                tokens.clear();
                tree.clear();
            }
            Self::Odin { semantic, syntax } => {
                semantic.clear();
                syntax.clear();
            }
            Self::Python {
                checks,
                scopes,
                semantic,
                syntax,
            } => {
                checks.clear();
                scopes.clear();
                semantic.clear();
                syntax.clear();
            }
            Self::Rust { semantic, syntax } => {
                semantic.clear();
                syntax.clear();
            }
            Self::TypeScript { semantic, syntax } => {
                semantic.clear();
                syntax.clear();
            }
            Self::Zig { semantic, syntax } => {
                semantic.clear();
                syntax.clear();
            }
        }
    }

    fn index_build(&mut self) {
        match self {
            Self::Css { syntax, .. } => syntax.index_build(),
            Self::Go { syntax, .. } => syntax.index_build(),
            Self::JavaScript { syntax, .. } => syntax.index_build(),
            Self::Markup { .. } => {}
            Self::Odin { syntax, .. } => syntax.index_build(),
            Self::Python { syntax, .. } => syntax.index_build(),
            Self::Rust { syntax, .. } => syntax.index_build(),
            Self::TypeScript { syntax, .. } => syntax.index_build(),
            Self::Zig { syntax, .. } => syntax.index_build(),
        }
    }

    fn index_of(&self, category: Category) -> &[u32] {
        match self {
            Self::Css { syntax, .. } => syntax.index.of(category),
            Self::Go { syntax, .. } => syntax.index.of(category),
            Self::JavaScript { syntax, .. } => syntax.index.of(category),
            Self::Markup { .. } => &[],
            Self::Odin { syntax, .. } => syntax.index.of(category),
            Self::Python { syntax, .. } => syntax.index.of(category),
            Self::Rust { syntax, .. } => syntax.index.of(category),
            Self::TypeScript { syntax, .. } => syntax.index.of(category),
            Self::Zig { syntax, .. } => syntax.index.of(category),
        }
    }

    fn view(&self, node: u32) -> Option<View<'_>> {
        match self {
            Self::Css { .. } | Self::Markup { .. } => None,
            Self::Go { syntax, .. } => Some(View::Go(go::View::new(
                &syntax.tree,
                syntax.tokens.as_slice(),
                &syntax.raw,
                node,
            ))),
            Self::JavaScript { syntax, .. } => Some(View::JavaScript(javascript::View::new(
                &syntax.tree,
                syntax.tokens.as_slice(),
                &syntax.raw,
                node,
            ))),
            Self::Odin { syntax, .. } => Some(View::Odin(odin::View::new(
                &syntax.tree,
                syntax.tokens.as_slice(),
                &syntax.raw,
                node,
            ))),
            Self::Python { syntax, .. } => Some(View::Python(python::View::new(
                &syntax.tree,
                syntax.tokens.as_slice(),
                &syntax.raw,
                node,
            ))),
            Self::Rust { syntax, .. } => Some(View::Rust(rust::View::new(
                &syntax.tree,
                syntax.tokens.as_slice(),
                &syntax.raw,
                node,
            ))),
            Self::TypeScript { syntax, .. } => Some(View::TypeScript(typescript::View::new(
                &syntax.tree,
                syntax.tokens.as_slice(),
                &syntax.raw,
                node,
            ))),
            Self::Zig { syntax, .. } => Some(View::Zig(zig::View::new(
                &syntax.tree,
                syntax.tokens.as_slice(),
                &syntax.raw,
                node,
            ))),
        }
    }

    fn count(&self) -> u32 {
        match self {
            Self::Css { syntax, .. } => syntax.tree.count(),
            Self::Go { syntax, .. } => syntax.tree.count(),
            Self::JavaScript { syntax, .. } => syntax.tree.count(),
            Self::Markup { tree, .. } => tree.count(),
            Self::Odin { syntax, .. } => syntax.tree.count(),
            Self::Python { syntax, .. } => syntax.tree.count(),
            Self::Rust { syntax, .. } => syntax.tree.count(),
            Self::TypeScript { syntax, .. } => syntax.tree.count(),
            Self::Zig { syntax, .. } => syntax.tree.count(),
        }
    }

    fn first_child_of(&self, node: u32) -> u32 {
        match self {
            Self::Css { syntax, .. } => syntax.tree.at(node).child_first,
            Self::Go { syntax, .. } => syntax.tree.at(node).child_first,
            Self::JavaScript { syntax, .. } => syntax.tree.at(node).child_first,
            Self::Markup { tree, .. } => tree.at(node).child_first,
            Self::Odin { syntax, .. } => syntax.tree.at(node).child_first,
            Self::Python { syntax, .. } => syntax.tree.at(node).child_first,
            Self::Rust { syntax, .. } => syntax.tree.at(node).child_first,
            Self::TypeScript { syntax, .. } => syntax.tree.at(node).child_first,
            Self::Zig { syntax, .. } => syntax.tree.at(node).child_first,
        }
    }

    fn next_sibling_of(&self, node: u32) -> u32 {
        match self {
            Self::Css { syntax, .. } => syntax.tree.at(node).sibling_next,
            Self::Go { syntax, .. } => syntax.tree.at(node).sibling_next,
            Self::JavaScript { syntax, .. } => syntax.tree.at(node).sibling_next,
            Self::Markup { tree, .. } => tree.at(node).sibling_next,
            Self::Odin { syntax, .. } => syntax.tree.at(node).sibling_next,
            Self::Python { syntax, .. } => syntax.tree.at(node).sibling_next,
            Self::Rust { syntax, .. } => syntax.tree.at(node).sibling_next,
            Self::TypeScript { syntax, .. } => syntax.tree.at(node).sibling_next,
            Self::Zig { syntax, .. } => syntax.tree.at(node).sibling_next,
        }
    }

    fn parent_of(&self, node: u32) -> u32 {
        match self {
            Self::Css { syntax, .. } => syntax.tree.at(node).parent,
            Self::Go { syntax, .. } => syntax.tree.at(node).parent,
            Self::JavaScript { syntax, .. } => syntax.tree.at(node).parent,
            Self::Markup { tree, .. } => tree.at(node).parent,
            Self::Odin { syntax, .. } => syntax.tree.at(node).parent,
            Self::Python { syntax, .. } => syntax.tree.at(node).parent,
            Self::Rust { syntax, .. } => syntax.tree.at(node).parent,
            Self::TypeScript { syntax, .. } => syntax.tree.at(node).parent,
            Self::Zig { syntax, .. } => syntax.tree.at(node).parent,
        }
    }

    fn declaration_of(&self, source: &[u8], name: &[u8]) -> u32 {
        match self {
            Self::Css { semantic, .. } => declared_of(semantic.definitions(), source, name),
            Self::Go { semantic, .. } => declared_of(semantic.bindings(), source, name),
            Self::JavaScript { semantic, .. } => declared_of(semantic.bindings(), source, name),
            Self::Markup { .. } => NONE,
            Self::Odin { semantic, .. } => declared_of(semantic.bindings(), source, name),
            Self::Python { semantic, .. } => declared_of(semantic.bindings(), source, name),
            Self::Rust { semantic, .. } => declared_of(semantic.bindings(), source, name),
            Self::TypeScript { semantic, .. } => declared_of(semantic.bindings(), source, name),
            Self::Zig { semantic, .. } => declared_of(semantic.bindings(), source, name),
        }
    }

    fn facts(&self) -> &[Fact] {
        match self {
            Self::Css { semantic, .. } => semantic.facts(),
            Self::Go { semantic, .. } => semantic.facts(),
            Self::JavaScript { semantic, .. } => semantic.facts(),
            Self::Markup { facts, .. } => facts.as_slice(),
            Self::Odin { semantic, .. } => semantic.facts(),
            Self::Python { semantic, .. } => semantic.facts(),
            Self::Rust { semantic, .. } => semantic.facts(),
            Self::TypeScript { semantic, .. } => semantic.facts(),
            Self::Zig { semantic, .. } => semantic.facts(),
        }
    }

    fn errors(&self) -> &[SyntaxError] {
        match self {
            Self::Css { syntax, .. } => syntax.tree.errors(),
            Self::Go { syntax, .. } => syntax.tree.errors(),
            Self::JavaScript { syntax, .. } => syntax.tree.errors(),
            Self::Markup { .. } => &[],
            Self::Odin { syntax, .. } => syntax.tree.errors(),
            Self::Python { syntax, .. } => syntax.tree.errors(),
            Self::Rust { syntax, .. } => syntax.tree.errors(),
            Self::TypeScript { syntax, .. } => syntax.tree.errors(),
            Self::Zig { syntax, .. } => syntax.tree.errors(),
        }
    }

    fn tokens(&self) -> &[Token] {
        match self {
            Self::Css { syntax, .. } => syntax.tokens.as_slice(),
            Self::Go { syntax, .. } => syntax.tokens.as_slice(),
            Self::JavaScript { syntax, .. } => syntax.tokens.as_slice(),
            Self::Markup { .. } => &[],
            Self::Odin { syntax, .. } => syntax.tokens.as_slice(),
            Self::Python { syntax, .. } => syntax.tokens.as_slice(),
            Self::Rust { syntax, .. } => syntax.tokens.as_slice(),
            Self::TypeScript { syntax, .. } => syntax.tokens.as_slice(),
            Self::Zig { syntax, .. } => syntax.tokens.as_slice(),
        }
    }
}

impl Scratch {
    pub fn reserve(limits: &Limits, wanted: [bool; Language::COUNT]) -> Self {
        assert!(limits.event_count_max > 0);

        assert!(!crate::allocation::is_frozen());

        let count = limits.event_count_max;

        Self {
            css: events_of(wanted[Language::Css.index()], count),
            go: events_of(wanted[Language::Go.index()], count),
            javascript: events_of(wanted[Language::JavaScript.index()], count),
            odin: events_of(wanted[Language::Odin.index()], count),
            python: events_of(wanted[Language::Python.index()], count),
            python_annotation: wanted[Language::Python.index()].then(|| {
                PythonAnnotationScratch::reserve(
                    ANNOTATION_TOKEN_COUNT_MAX,
                    ANNOTATION_NODE_COUNT_MAX,
                )
            }),
            rust: events_of(wanted[Language::Rust.index()], count),
            typescript: events_of(
                wanted[Language::Tsx.index()] || wanted[Language::TypeScript.index()],
                count,
            ),
            zig: events_of(wanted[Language::Zig.index()], count),
        }
    }
}

fn declared_of<T>(items: &[T], source: &[u8], name: &[u8]) -> u32
where
    T: Declared,
{
    assert!(!name.is_empty());

    let mut found = NONE;

    for item in items {
        if item.scope() != 0 {
            continue;
        }

        if item.name() == Span::EMPTY {
            continue;
        }

        if &source[item.name().range()] != name {
            continue;
        }

        found = item.node();
    }

    found
}

fn events_of<K>(wanted: bool, event_count_max: u32) -> Option<Events<K>>
where
    K: Kind,
{
    assert!(event_count_max > 0);

    if wanted {
        return Some(Events::reserve(event_count_max));
    }

    None
}

pub struct Fronts {
    front_of_language: [u32; Language::COUNT],
    held: Vec<Front>,
    scratch: Box<Scratch>,
    wanted: [bool; Language::COUNT],
}

impl Fronts {
    pub fn reserve(limits: &Limits, languages: &[Language]) -> Self {
        assert!(!crate::allocation::is_frozen());

        let mut fronts = Vec::with_capacity(Language::COUNT);
        let mut front_of_language = [NONE; Language::COUNT];
        let mut wanted = [false; Language::COUNT];

        for language in languages {
            reserve_one(
                &mut fronts,
                &mut front_of_language,
                &mut wanted,
                *language,
                limits,
            );

            if *language == Language::TypeScript {
                reserve_one(
                    &mut fronts,
                    &mut front_of_language,
                    &mut wanted,
                    Language::Tsx,
                    limits,
                );
            }
        }

        assert!(fronts.len() <= Language::COUNT);

        Self {
            front_of_language,
            held: fronts,
            scratch: Box::new(Scratch::reserve(limits, wanted)),
            wanted,
        }
    }

    pub fn at(&self, index: u32) -> &Front {
        assert!((index as usize) < self.held.len());

        &self.held[index as usize]
    }

    pub fn build(
        &mut self,
        index: u32,
        source: &[u8],
        lexed: &[Token],
        options: &Options<'_>,
    ) -> Structure {
        assert!((index as usize) < self.held.len());

        self.held[index as usize].build(source, lexed, &mut self.scratch, options)
    }

    pub fn of_language(&self, language: Language) -> u32 {
        self.front_of_language[language.index()]
    }

    pub fn of_path(&self, language: Language, path: &[u8]) -> u32 {
        self.of_language(language.dialect_of_path(path))
    }

    pub const fn wanted(&self) -> [bool; Language::COUNT] {
        self.wanted
    }
}

fn reserve_one(
    fronts: &mut Vec<Front>,
    front_of_language: &mut [u32; Language::COUNT],
    wanted: &mut [bool; Language::COUNT],
    language: Language,
    limits: &Limits,
) {
    assert!(!crate::allocation::is_frozen());
    assert!(fronts.len() < fronts.capacity());

    front_of_language[language.index()] = count_of(fronts.len());
    wanted[language.index()] = true;
    fronts.push(Front::reserve(language, limits));

    assert_eq!(
        fronts.len(),
        front_of_language[language.index()] as usize + 1
    );
}

pub const fn lexer_of(language: Language) -> Option<&'static dyn Lexer> {
    match language {
        Language::Css => Some(&CSS),
        Language::Go => Some(&GO),
        Language::JavaScript => Some(&JAVASCRIPT),
        Language::Markup => None,
        Language::Odin => Some(&ODIN),
        Language::Python => Some(&PYTHON),
        Language::Rust => Some(&RUST),
        Language::Tsx | Language::TypeScript => Some(&TYPESCRIPT),
        Language::Zig => Some(&ZIG),
    }
}

const fn dialect_of(language: Language) -> Dialect {
    match language {
        Language::Tsx => Dialect::Tsx,
        Language::Css
        | Language::Go
        | Language::JavaScript
        | Language::Markup
        | Language::Odin
        | Language::Python
        | Language::Rust
        | Language::TypeScript
        | Language::Zig => Dialect::Ts,
    }
}

fn build_of(
    source: &[u8],
    tables: &mut Tables,
    lexed: &[Token],
    events: &mut Scratch,
    options: &Options<'_>,
    dialect: Dialect,
) -> Structure {
    let globals = options.globals;

    match tables {
        Tables::Css { semantic, syntax } => build_css(source, semantic, syntax, lexed, events),
        Tables::Go { semantic, syntax } => {
            build_go(source, semantic, syntax, lexed, events, globals)
        }
        Tables::JavaScript { semantic, syntax } => {
            build_javascript(source, semantic, syntax, lexed, events, globals)
        }
        Tables::Markup {
            facts,
            tokens,
            tree,
        } => build_markup(source, facts, tokens, tree),
        Tables::Odin { semantic, syntax } => {
            build_odin(source, semantic, syntax, lexed, events, globals)
        }
        Tables::Python {
            checks,
            scopes,
            semantic,
            syntax,
        } => build_python_of(
            source,
            lexed,
            events,
            options,
            (checks, scopes, semantic, syntax),
        ),
        Tables::Rust { semantic, syntax } => {
            build_rust(source, semantic, syntax, lexed, events, globals)
        }
        Tables::TypeScript { semantic, syntax } => {
            build_typescript(source, semantic, syntax, lexed, events, globals, dialect)
        }
        Tables::Zig { semantic, syntax } => {
            build_zig(source, semantic, syntax, lexed, events, globals)
        }
    }
}

fn build_python_of(
    source: &[u8],
    lexed: &[Token],
    events: &mut Scratch,
    options: &Options<'_>,
    tables: (
        &mut BoundedVec<PythonCheckError>,
        &mut PythonTables,
        &mut PythonSemantic,
        &mut Syntax<PythonKind>,
    ),
) -> Structure {
    let (checks, scopes, semantic, syntax) = tables;

    build_python(
        source,
        PythonBuildInput {
            annotations: events.python_annotation.as_mut(),
            checks,
            events: events.python.as_mut(),
            lexed,
            scopes,
            semantic,
            syntax,
        },
        options.globals,
        options.python_version,
    )
}

fn build_css(
    source: &[u8],
    semantic: &mut CSSSemantic,
    syntax: &mut Syntax<CSSKind>,
    lexed: &[Token],
    events: &mut Scratch,
) -> Structure {
    let Some(held) = events.css.as_mut() else {
        return Structure::Truncated;
    };

    if !css_classify(source, lexed, &mut syntax.tokens, &mut syntax.raw) {
        return Structure::Truncated;
    }

    let built = css_parse::build(
        source,
        syntax.tokens.as_slice(),
        &syntax.raw,
        held,
        &mut syntax.tree,
    );

    if built != Structure::Complete {
        return built;
    }

    semantic.build(source, syntax.tokens.as_slice(), &syntax.raw, &syntax.tree)
}

fn build_go(
    source: &[u8],
    semantic: &mut GoSemantic,
    syntax: &mut Syntax<GoKind>,
    lexed: &[Token],
    events: &mut Scratch,
    globals: &[&[u8]],
) -> Structure {
    let Some(held) = events.go.as_mut() else {
        return Structure::Truncated;
    };

    if !go_classify(source, lexed, &mut syntax.tokens, &mut syntax.raw) {
        return Structure::Truncated;
    }

    let built = go_parse::build(
        source,
        syntax.tokens.as_slice(),
        &syntax.raw,
        held,
        &mut syntax.tree,
    );

    if built != Structure::Complete {
        return built;
    }

    semantic.build(
        source,
        syntax.tokens.as_slice(),
        &syntax.raw,
        &syntax.tree,
        globals,
    )
}

fn build_javascript(
    source: &[u8],
    semantic: &mut JavaScriptSemantic,
    syntax: &mut Syntax<JavaScriptKind>,
    lexed: &[Token],
    events: &mut Scratch,
    globals: &[&[u8]],
) -> Structure {
    let Some(held) = events.javascript.as_mut() else {
        return Structure::Truncated;
    };

    if !javascript_classify(source, lexed, &mut syntax.tokens, &mut syntax.raw) {
        return Structure::Truncated;
    }

    let built = javascript_parse::build(
        source,
        syntax.tokens.as_slice(),
        &syntax.raw,
        held,
        &mut syntax.tree,
    );

    if built != Structure::Complete {
        return built;
    }

    semantic.build(
        source,
        syntax.tokens.as_slice(),
        &syntax.raw,
        &syntax.tree,
        None,
        globals,
    )
}

fn build_markup(
    source: &[u8],
    facts: &mut Facts,
    tokens: &mut markup::Tokens,
    tree: &mut Tree<MarkupKind>,
) -> Structure {
    tokens.clear();

    assert_eq!(tokens.count(), 0);

    if markup::lex(source, tokens) != Lex::Complete {
        return Structure::Truncated;
    }

    let built = markup::tree::build(source, tokens.as_slice(), tree);

    if built != Structure::Complete {
        return built;
    }

    markup::facts::build(source, tokens.as_slice(), tree, facts)
}

fn build_odin(
    source: &[u8],
    semantic: &mut OdinSemantic,
    syntax: &mut Syntax<OdinKind>,
    lexed: &[Token],
    events: &mut Scratch,
    globals: &[&[u8]],
) -> Structure {
    let Some(held) = events.odin.as_mut() else {
        return Structure::Truncated;
    };

    if !odin_classify(source, lexed, &mut syntax.tokens, &mut syntax.raw) {
        return Structure::Truncated;
    }

    let built = odin_parse::build(
        source,
        syntax.tokens.as_slice(),
        &syntax.raw,
        held,
        &mut syntax.tree,
    );

    if built != Structure::Complete {
        return built;
    }

    semantic.build(
        source,
        syntax.tokens.as_slice(),
        &syntax.raw,
        &syntax.tree,
        globals,
    )
}

struct PythonBuildInput<'run> {
    annotations: Option<&'run mut PythonAnnotationScratch>,
    checks: &'run mut BoundedVec<PythonCheckError>,
    events: Option<&'run mut Events<PythonKind>>,
    lexed: &'run [Token],
    scopes: &'run mut PythonTables,
    semantic: &'run mut PythonSemantic,
    syntax: &'run mut Syntax<PythonKind>,
}

fn build_python(
    source: &[u8],
    input: PythonBuildInput<'_>,
    globals: &[&[u8]],
    version: PythonVersion,
) -> Structure {
    let PythonBuildInput {
        annotations,
        checks,
        events,
        lexed,
        scopes,
        semantic,
        syntax,
    } = input;

    let Some(held) = events else {
        return Structure::Truncated;
    };

    let Some(scratch) = annotations else {
        return Structure::Truncated;
    };

    let parsed = parse_python(source, lexed, syntax, held);

    if parsed != Structure::Complete {
        return parsed;
    }

    if !bind::bind(
        source,
        syntax.tokens.as_slice(),
        &syntax.raw,
        &syntax.tree,
        scopes,
    ) {
        return Structure::Truncated;
    }

    let model = semantic.build(
        &PythonSemanticInput {
            builtins: globals,
            raw: &syntax.raw,
            scopes,
            source,
            tokens: syntax.tokens.as_slice(),
            tree: &syntax.tree,
            version,
        },
        scratch,
    );

    if model != Structure::Complete {
        return model;
    }

    check_python(source, checks, semantic, syntax, version)
}

fn parse_python(
    source: &[u8],
    lexed: &[Token],
    syntax: &mut Syntax<PythonKind>,
    events: &mut Events<PythonKind>,
) -> Structure {
    if !python_classify(source, lexed, &mut syntax.tokens, &mut syntax.raw) {
        return Structure::Truncated;
    }

    python_parse::build(
        source,
        syntax.tokens.as_slice(),
        &syntax.raw,
        events,
        &mut syntax.tree,
    )
}

fn check_python(
    source: &[u8],
    checks: &mut BoundedVec<PythonCheckError>,
    semantic: &PythonSemantic,
    syntax: &Syntax<PythonKind>,
    version: PythonVersion,
) -> Structure {
    if check::check(
        source,
        syntax.tokens.as_slice(),
        &syntax.raw,
        &syntax.tree,
        semantic,
        version,
        checks,
    ) == Completion::Complete
    {
        return Structure::Complete;
    }

    Structure::Truncated
}

fn build_rust(
    source: &[u8],
    semantic: &mut RustSemantic,
    syntax: &mut Syntax<RustKind>,
    lexed: &[Token],
    events: &mut Scratch,
    globals: &[&[u8]],
) -> Structure {
    let Some(held) = events.rust.as_mut() else {
        return Structure::Truncated;
    };

    if !rust_classify(source, lexed, &mut syntax.tokens, &mut syntax.raw) {
        return Structure::Truncated;
    }

    let built = rust_parse::build(
        source,
        syntax.tokens.as_slice(),
        &syntax.raw,
        held,
        &mut syntax.tree,
    );

    if built != Structure::Complete {
        return built;
    }

    semantic.build(
        source,
        syntax.tokens.as_slice(),
        &syntax.raw,
        &syntax.tree,
        globals,
    )
}

fn build_typescript(
    source: &[u8],
    semantic: &mut JavaScriptSemantic,
    syntax: &mut Syntax<TypeScriptKind>,
    lexed: &[Token],
    events: &mut Scratch,
    globals: &[&[u8]],
    dialect: Dialect,
) -> Structure {
    let Some(held) = events.typescript.as_mut() else {
        return Structure::Truncated;
    };

    if !typescript_classify(source, lexed, &mut syntax.tokens, &mut syntax.raw, dialect) {
        return Structure::Truncated;
    }

    let built = typescript_parse::build(
        source,
        syntax.tokens.as_slice(),
        &syntax.raw,
        held,
        &mut syntax.tree,
        dialect,
    );

    if built != Structure::Complete {
        return built;
    }

    semantic.build(
        source,
        syntax.tokens.as_slice(),
        &syntax.raw,
        &syntax.tree,
        None,
        globals,
    )
}

fn build_zig(
    source: &[u8],
    semantic: &mut ZigSemantic,
    syntax: &mut Syntax<ZigKind>,
    lexed: &[Token],
    events: &mut Scratch,
    globals: &[&[u8]],
) -> Structure {
    let Some(held) = events.zig.as_mut() else {
        return Structure::Truncated;
    };

    if !zig_classify(source, lexed, &mut syntax.tokens, &mut syntax.raw) {
        return Structure::Truncated;
    }

    let built = zig_parse::build(
        source,
        syntax.tokens.as_slice(),
        &syntax.raw,
        held,
        &mut syntax.tree,
    );

    if built != Structure::Complete {
        return built;
    }

    semantic.build(
        source,
        syntax.tokens.as_slice(),
        &syntax.raw,
        &syntax.tree,
        globals,
    )
}

fn reserve_css(limits: &Limits) -> Tables {
    Tables::Css {
        semantic: CSSSemantic::reserve(
            limits.binding_count_max,
            limits.reference_count_max,
            limits.fact_count_max,
        ),
        syntax: Syntax::reserve(limits),
    }
}

fn reserve_go(limits: &Limits) -> Tables {
    Tables::Go {
        semantic: GoSemantic::reserve(
            limits.binding_count_max,
            limits.reference_count_max,
            limits.scope_count_max,
            limits.fact_count_max,
        ),
        syntax: Syntax::reserve(limits),
    }
}

fn reserve_javascript(limits: &Limits) -> Tables {
    Tables::JavaScript {
        semantic: JavaScriptSemantic::reserve(
            limits.binding_count_max,
            limits.reference_count_max,
            limits.scope_count_max,
            limits.fact_count_max,
        ),
        syntax: Syntax::reserve(limits),
    }
}

fn reserve_markup(limits: &Limits) -> Tables {
    Tables::Markup {
        facts: Facts::reserve(limits.fact_count_max),
        tokens: markup::Tokens::reserve(limits.token_count_max),
        tree: Tree::reserve(limits.node_count_max, limits.error_count_max),
    }
}

fn reserve_odin(limits: &Limits) -> Tables {
    Tables::Odin {
        semantic: OdinSemantic::reserve(
            limits.binding_count_max,
            limits.reference_count_max,
            limits.scope_count_max,
            limits.fact_count_max,
        ),
        syntax: Syntax::reserve(limits),
    }
}

fn reserve_python(limits: &Limits) -> Tables {
    Tables::Python {
        checks: BoundedVec::reserve(check::ERROR_COUNT_MAX_DEFAULT),
        scopes: PythonTables::reserve(
            limits.scope_count_max,
            limits.binding_count_max,
            limits.reference_count_max,
            limits.segment_count_max,
        ),
        semantic: PythonSemantic::reserve(
            limits.binding_count_max,
            limits.reference_count_max,
            limits.export_count_max,
        ),
        syntax: Syntax::reserve(limits),
    }
}

fn reserve_rust(limits: &Limits) -> Tables {
    Tables::Rust {
        semantic: RustSemantic::reserve(
            limits.binding_count_max,
            limits.reference_count_max,
            limits.scope_count_max,
            limits.fact_count_max,
        ),
        syntax: Syntax::reserve(limits),
    }
}

fn reserve_typescript(limits: &Limits) -> Tables {
    Tables::TypeScript {
        semantic: JavaScriptSemantic::reserve(
            limits.binding_count_max,
            limits.reference_count_max,
            limits.scope_count_max,
            limits.fact_count_max,
        ),
        syntax: Syntax::reserve(limits),
    }
}

fn reserve_zig(limits: &Limits) -> Tables {
    Tables::Zig {
        semantic: ZigSemantic::reserve(
            limits.binding_count_max,
            limits.reference_count_max,
            limits.scope_count_max,
            limits.fact_count_max,
        ),
        syntax: Syntax::reserve(limits),
    }
}
