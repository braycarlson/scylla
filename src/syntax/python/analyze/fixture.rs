use crate::bounded::BoundedVec;
use crate::language::Lexer as _;
use crate::lex::PYTHON;
use crate::syntax::python::ast::View;
use crate::syntax::python::bind::{Tables, bind};
use crate::syntax::python::classify::classify;
use crate::syntax::python::kind::PythonKind;
use crate::syntax::python::parse;
use crate::syntax::python::semantic::{AnnotationScratch, Semantic, SemanticInput};
use crate::syntax::python::stdlib::PythonVersion;
use crate::token::Tokens;
use crate::tree::{Events, NONE, Structure, Tree};

pub(super) struct Fixture {
    pub(super) raw: BoundedVec<PythonKind>,
    pub(super) semantic: Semantic,
    pub(super) source: Vec<u8>,
    pub(super) tokens: Tokens,
    pub(super) tree: Tree<PythonKind>,
}

impl Fixture {
    pub(super) fn of(source: &[u8]) -> Self {
        let mut lexed = Tokens::reserve(1 << 14);
        let mut tokens = Tokens::reserve(1 << 14);
        let mut raw = BoundedVec::reserve(1 << 14);
        let mut events = Events::reserve(1 << 16);
        let mut tree = Tree::<PythonKind>::reserve(1 << 14, 1 << 8);
        let mut tables = Tables::reserve(1 << 8, 1 << 10, 1 << 12, 1 << 10);
        let mut semantic = Semantic::reserve(1 << 10, 1 << 12, 1 << 8);
        let mut scratch = AnnotationScratch::reserve(1 << 8, 1 << 8);

        PYTHON.lex(source, &mut lexed);

        assert!(classify(source, lexed.as_slice(), &mut tokens, &mut raw));

        assert_eq!(
            parse::build(source, tokens.as_slice(), &raw, &mut events, &mut tree),
            Structure::Complete
        );

        assert!(bind(source, tokens.as_slice(), &raw, &tree, &mut tables));

        assert_eq!(
            semantic.build(
                &SemanticInput {
                    builtins: &[],
                    raw: &raw,
                    scopes: &tables,
                    source,
                    tokens: tokens.as_slice(),
                    tree: &tree,
                    version: PythonVersion::Py312,
                },
                &mut scratch,
            ),
            Structure::Complete
        );

        Self {
            raw,
            semantic,
            source: source.to_vec(),
            tokens,
            tree,
        }
    }

    pub(super) fn view(&self, node: u32) -> View<'_> {
        View::new(&self.tree, self.tokens.as_slice(), &self.raw, node)
    }

    pub(super) fn nth(&self, kind: PythonKind, position: u32) -> u32 {
        let mut seen = 0;

        for node in 0..self.tree.count() {
            if self.tree.at(node).kind != kind {
                continue;
            }

            if seen == position {
                return node;
            }

            seen += 1;
        }

        NONE
    }

    pub(super) fn first(&self, kind: PythonKind) -> u32 {
        self.nth(kind, 0)
    }
}
