use crate::bounded::{Arena, BoundedVec, Buffer, Span, Table, hash_of as name_hash_of};
use crate::brackets::Pairs;
use crate::diagnostic::{Diagnostic, Diagnostics, Message, Severity};
use crate::fix::{self, Applicability, Fixes};
use crate::format::css::{Formatter as CSSFormatter, Input as CSSInput, Outcome as CSSOutcome};
use crate::format::go::{Formatter as GoFormatter, Input as GoInput, Outcome as GoOutcome};
use crate::format::ir::{Document, Element, Source as ElementSource};
use crate::format::javascript::{
    Formatter as JavaScriptFormatter,
    Input as JavaScriptInput,
    Outcome as JavaScriptOutcome,
};
use crate::format::markup::{
    Formatter as MarkupFormatter,
    Input as MarkupInput,
    Outcome as MarkupOutcome,
};
use crate::format::odin::{Formatter as OdinFormatter, Input as OdinInput, Outcome as OdinOutcome};
use crate::format::print::Options;
use crate::format::python::{Formatter, Input, Outcome, QuotePreference};
use crate::format::rust::{Formatter as RustFormatter, Input as RustInput, Outcome as RustOutcome};
use crate::format::zig::{Formatter as ZigFormatter, Input as ZigInput, Outcome as ZigOutcome};
use crate::language::{Language, Lexer as _};
use crate::lex::{CSS, GO, JAVASCRIPT, ODIN, PYTHON, RUST, TYPESCRIPT, ZIG};
use crate::markup::blocks::{self, BlockMap};
use crate::markup::tree::{self, Tree};
use crate::markup::{self, Tokens as MarkupTokens};
use crate::outline::{javascript, python};
use crate::project::diagnostic::{Budget, Project};
use crate::project::graph::Graph;
use crate::project::view::Sink;
use crate::project::{CLASS_COUNT, Eviction, FileID, Limits, NONE, Store, hash_of};
use crate::rule::{Fixable, Registry, Rule};
use crate::structure::{self, Nodes, Shape};
use crate::suppress::Suppressions;
use crate::syntax::css::ast::View as CSSView;
use crate::syntax::css::classify::classify as css_classify;
use crate::syntax::css::kind::CSSKind;
use crate::syntax::css::parse as css_parse;
use crate::syntax::css::semantic::Semantic as CSSSemantic;
use crate::syntax::front;
use crate::syntax::go::ast::View as GoView;
use crate::syntax::go::classify::classify as go_classify;
use crate::syntax::go::kind::GoKind;
use crate::syntax::go::parse as go_parse;
use crate::syntax::go::semantic::Semantic as GoSemantic;
use crate::syntax::javascript::ast::View as JavaScriptView;
use crate::syntax::javascript::classify::classify as javascript_classify;
use crate::syntax::javascript::kind::JavaScriptKind;
use crate::syntax::javascript::parse as javascript_parse;
use crate::syntax::javascript::semantic::Semantic as JavaScriptSemantic;
use crate::syntax::odin::ast::View as OdinView;
use crate::syntax::odin::classify::classify as odin_classify;
use crate::syntax::odin::kind::OdinKind;
use crate::syntax::odin::parse as odin_parse;
use crate::syntax::odin::semantic::Semantic as OdinSemantic;
use crate::syntax::python::ast::View;
use crate::syntax::python::bind::{self, Outcome as BindOutcome, Tables};
use crate::syntax::python::classify::classify;
use crate::syntax::python::kind::PythonKind;
use crate::syntax::python::parse;
use crate::syntax::python::semantic::{AnnotationScratch, Semantic, SemanticInput};
use crate::syntax::python::stdlib::PythonVersion;
use crate::syntax::python::style::LineEnding;
use crate::syntax::rust::ast::View as RustView;
use crate::syntax::rust::classify::classify as rust_classify;
use crate::syntax::rust::kind::RustKind;
use crate::syntax::rust::parse as rust_parse;
use crate::syntax::rust::semantic::Semantic as RustSemantic;
use crate::syntax::typescript::ast::View as TypeScriptView;
use crate::syntax::typescript::classify::classify as typescript_classify;
use crate::syntax::typescript::dialect::Dialect;
use crate::syntax::typescript::kind::TypeScriptKind;
use crate::syntax::typescript::parse as typescript_parse;
use crate::syntax::zig::ast::View as ZigView;
use crate::syntax::zig::classify::classify as zig_classify;
use crate::syntax::zig::kind::ZigKind;
use crate::syntax::zig::parse as zig_parse;
use crate::syntax::zig::semantic::Semantic as ZigSemantic;
use crate::token::{Token, TokenKind, Tokens};
use crate::tree::{Events, Step, Tree as SyntaxTree};
use crate::{lines, mask, summary};

const CODE: &[u8] = b"class Widget(models.Model):\n    \
                      name = models.CharField(max_length=10)\n\n\
                      def run():\n    \
                      return build(self, name=\"x\")\n";

const TEMPLATE: &[u8] = b"<div x-data=\"{ open: false, async load() { await go(); } }\">\n\
                          {% for a in b %}{{ a|title }}{% endfor %}\n\
                          <script>const url = 1;</script>\n</div>\n";

#[test]
fn every_fixture_runs_on_a_frozen_thread() {
    let mut sources = Vec::new();

    collect(
        &std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/templates"),
        &mut sources,
    );

    assert!(sources.len() > 300);

    let mut markup_tokens = MarkupTokens::reserve(1 << 18);
    let mut built = Tree::reserve(1 << 17, 1 << 10);
    let mut map = BlockMap::reserve(1 << 12);
    let mut tokens = Tokens::reserve(1 << 17);
    let mut pairs = Pairs::reserve(1 << 17);
    let mut nodes = Nodes::reserve(1 << 14);
    let mut outline = python::Outline::reserve(1 << 13, 1 << 14);
    let mut islands = javascript::Outline::reserve(1 << 13, 1 << 14, 1 << 17);
    let mut index = lines::Index::reserve(1 << 16);
    let _scope = crate::allocation::freeze_scope();

    for (source, python) in &sources {
        assert!(index.build(source));

        if *python {
            tokens.clear();
            PYTHON.lex(source, &mut tokens);
            pairs.build(source, tokens.as_slice());

            structure::build(
                tokens.as_slice(),
                source,
                &mut nodes,
                Shape::DEFAULT,
                structure::DEPTH_MAX,
            );

            python::build(
                source,
                tokens.as_slice(),
                &pairs,
                nodes.as_slice(),
                &mut outline,
            );

            continue;
        }

        markup::lex(source, &mut markup_tokens);
        tree::build(source, markup_tokens.as_slice(), &mut built);
        blocks::build(source, markup_tokens.as_slice(), &built, &[], &[], &mut map);

        tokens.clear();
        JAVASCRIPT.lex(source, &mut tokens);
        pairs.build(source, tokens.as_slice());
        javascript::build(source, tokens.as_slice(), &pairs, &mut islands);
    }
}

fn collect(directory: &std::path::Path, out: &mut Vec<(Vec<u8>, bool)>) {
    let mut stack = vec![directory.to_path_buf()];

    while let Some(current) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&current) else {
            continue;
        };

        for entry in entries.flatten() {
            let path = entry.path();

            if path.is_dir() {
                stack.push(path);

                continue;
            }

            let Some(extension) = path.extension() else {
                continue;
            };

            if extension != "html" && extension != "py" {
                continue;
            }

            let Ok(source) = std::fs::read(&path) else {
                continue;
            };

            out.push((source, extension == "py"));
        }
    }
}

#[test]
fn the_derived_tables_run_on_a_frozen_thread() {
    const NAMES: [&[u8]; 4] = [
        b"base.html",
        b"partials/row.html",
        b"index.html",
        b"mail.txt",
    ];

    let mut arena = Arena::reserve(4_096);
    let mut table = Table::<u32>::reserve(64);
    let _scope = crate::allocation::freeze_scope();

    for (row, name) in NAMES.iter().enumerate() {
        let key = arena.intern(name).expect("the arena holds the name");

        let written = table.insert(
            name_hash_of(name),
            key,
            u32::try_from(row).expect("the row fits"),
            |span| arena.bytes_of(span) == *name,
        );

        assert!(written);
    }

    for (row, name) in NAMES.iter().enumerate() {
        assert_eq!(
            table.get(name_hash_of(name), |span| arena.bytes_of(span) == *name),
            Some(u32::try_from(row).expect("the row fits"))
        );
    }

    assert_eq!(table.count(), 4);

    table.clear();
    arena.reset();

    assert!(table.is_empty());
    assert!(arena.is_empty());
}

#[test]
fn the_markup_layer_runs_on_a_frozen_thread() {
    let mut markup_tokens = MarkupTokens::reserve(4_096);
    let mut built = Tree::reserve(1_024, 128);
    let mut map = BlockMap::reserve(256);
    let mut index = lines::Index::reserve(256);
    let _scope = crate::allocation::freeze_scope();

    markup::lex(TEMPLATE, &mut markup_tokens);
    tree::build(TEMPLATE, markup_tokens.as_slice(), &mut built);

    blocks::build(
        TEMPLATE,
        markup_tokens.as_slice(),
        &built,
        &[],
        &[],
        &mut map,
    );

    assert!(index.build(TEMPLATE));
    assert!(built.count() > 0);
    assert!(!map.tags().is_empty());
}

#[test]
fn the_extraction_layer_runs_on_a_frozen_thread() {
    let mut tokens = Tokens::reserve(4_096);
    let mut pairs = Pairs::reserve(4_096);
    let mut nodes = Nodes::reserve(256);
    let mut outline = python::Outline::reserve(256, 512);
    let mut islands = javascript::Outline::reserve(256, 512, 4_096);
    let mut segments = BoundedVec::reserve(64);
    let mut items = BoundedVec::reserve(64);
    let mut prepared = BoundedVec::reserve(4_096);

    for _ in 0..4_096 {
        prepared.push_assert(0_u8);
    }

    let _scope = crate::allocation::freeze_scope();

    PYTHON.lex(CODE, &mut tokens);
    pairs.build(CODE, tokens.as_slice());

    structure::build(
        tokens.as_slice(),
        CODE,
        &mut nodes,
        Shape::DEFAULT,
        structure::DEPTH_MAX,
    );

    python::build(
        CODE,
        tokens.as_slice(),
        &pairs,
        nodes.as_slice(),
        &mut outline,
    );

    summary::read(
        CODE,
        tokens.as_slice(),
        &pairs,
        0,
        4,
        &mut segments,
        &mut items,
    );

    let region = Span {
        length: 21,
        offset: 0,
    };

    mask::write(CODE, region, &[], &mut prepared);

    tokens.clear();
    JAVASCRIPT.lex(CODE, &mut tokens);
    pairs.build(CODE, tokens.as_slice());
    javascript::build(CODE, tokens.as_slice(), &pairs, &mut islands);

    assert!(!outline.calls().is_empty());
    assert!(!islands.scopes().is_empty());
}

#[test]
fn the_syntax_layer_runs_on_a_frozen_thread() {
    let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/python");
    let mut sources = Vec::new();

    collect(&root, &mut sources);

    assert!(sources.len() > 8);

    let mut lexed = Tokens::reserve(1 << 16);
    let mut tokens = Tokens::reserve(1 << 16);
    let mut raw = BoundedVec::reserve(1 << 16);
    let mut events = Events::reserve(1 << 18);
    let mut built = SyntaxTree::reserve(1 << 16, 1 << 10);
    let mut tables = Tables::reserve(1 << 10, 1 << 14, 1 << 16, 1 << 12);
    let _scope = crate::allocation::freeze_scope();

    for (source, _) in &sources {
        lexed.clear();
        PYTHON.lex(source, &mut lexed);

        assert!(classify(source, lexed.as_slice(), &mut tokens, &mut raw));

        parse::build(source, tokens.as_slice(), &raw, &mut events, &mut built);

        let mut stack = [0_u32; 1 << 10];
        let mut depth = 0;
        let mut seen = 0;

        if built.count() > 0 {
            stack[depth] = 0;
            depth += 1;
        }

        while depth > 0 {
            depth -= 1;

            let view = View::new(&built, tokens.as_slice(), &raw, stack[depth]);
            let span = view.span();

            assert!(span.end() as usize <= source.len());

            seen += 1;

            for child in view.children() {
                if depth >= stack.len() {
                    break;
                }

                stack[depth] = child.index();
                depth += 1;
            }
        }

        assert!(seen > 0);

        assert_eq!(
            bind::bind(source, tokens.as_slice(), &raw, &built, &mut tables),
            BindOutcome::Complete
        );

        assert!(tables.scopes.count() > 0);
    }
}

fn collect_of(directory: &std::path::Path, extension: &str, out: &mut Vec<Vec<u8>>) {
    let mut stack = vec![directory.to_path_buf()];

    while let Some(current) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&current) else {
            continue;
        };

        for entry in entries.flatten() {
            let path = entry.path();

            if path.is_dir() {
                stack.push(path);

                continue;
            }

            if path.extension().is_none_or(|held| held != extension) {
                continue;
            }

            let Ok(source) = std::fs::read(&path) else {
                continue;
            };

            out.push(source);
        }
    }
}

#[test]
fn the_javascript_syntax_layer_runs_on_a_frozen_thread() {
    let root =
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/javascript");
    let mut sources = Vec::new();

    collect_of(&root, "js", &mut sources);

    assert!(sources.len() > 4);

    let mut lexed = Tokens::reserve(1 << 16);
    let mut tokens = Tokens::reserve(1 << 16);
    let mut raw = BoundedVec::reserve(1 << 16);
    let mut events = Events::reserve(1 << 18);
    let mut built = SyntaxTree::<JavaScriptKind>::reserve(1 << 16, 1 << 10);
    let _scope = crate::allocation::freeze_scope();

    for source in &sources {
        lexed.clear();
        JAVASCRIPT.lex(source, &mut lexed);

        assert!(javascript_classify(
            source,
            lexed.as_slice(),
            &mut tokens,
            &mut raw
        ));

        javascript_parse::build(source, tokens.as_slice(), &raw, &mut events, &mut built);

        let mut stack = [0_u32; 1 << 10];
        let mut depth = 0;
        let mut seen = 0;

        if built.count() > 0 {
            stack[depth] = 0;
            depth += 1;
        }

        while depth > 0 {
            depth -= 1;

            let view = JavaScriptView::new(&built, tokens.as_slice(), &raw, stack[depth]);
            let span = view.span();

            assert!(span.end() as usize <= source.len());

            seen += 1;

            for child in view.children() {
                if depth >= stack.len() {
                    break;
                }

                stack[depth] = child.index();
                depth += 1;
            }
        }

        assert!(seen > 0);
    }
}

#[test]
fn the_rust_syntax_layer_runs_on_a_frozen_thread() {
    let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/rust");
    let mut sources = Vec::new();

    collect_of(&root, "rs", &mut sources);

    assert!(sources.len() > 4);

    let mut lexed = Tokens::reserve(1 << 16);
    let mut tokens = Tokens::reserve(1 << 16);
    let mut raw = BoundedVec::reserve(1 << 16);
    let mut events = Events::reserve(1 << 19);
    let mut built = SyntaxTree::<RustKind>::reserve(1 << 16, 1 << 10);
    let _scope = crate::allocation::freeze_scope();

    for source in &sources {
        lexed.clear();
        RUST.lex(source, &mut lexed);

        assert!(rust_classify(
            source,
            lexed.as_slice(),
            &mut tokens,
            &mut raw
        ));

        rust_parse::build(source, tokens.as_slice(), &raw, &mut events, &mut built);

        let mut stack = [0_u32; 1 << 10];
        let mut depth = 0;
        let mut seen = 0;

        if built.count() > 0 {
            stack[depth] = 0;
            depth += 1;
        }

        while depth > 0 {
            depth -= 1;

            let view = RustView::new(&built, tokens.as_slice(), &raw, stack[depth]);
            let span = view.span();

            assert!(span.end() as usize <= source.len());

            seen += 1;

            for child in view.children() {
                if depth >= stack.len() {
                    break;
                }

                stack[depth] = child.index();
                depth += 1;
            }
        }

        assert!(seen > 0);
    }
}

#[test]
fn the_go_syntax_layer_runs_on_a_frozen_thread() {
    let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/go");
    let mut sources = Vec::new();

    collect_of(&root, "go", &mut sources);

    assert!(sources.len() > 4);

    let mut lexed = Tokens::reserve(1 << 16);
    let mut tokens = Tokens::reserve(1 << 16);
    let mut raw = BoundedVec::reserve(1 << 16);
    let mut events = Events::reserve(1 << 19);
    let mut built = SyntaxTree::<GoKind>::reserve(1 << 16, 1 << 10);
    let _scope = crate::allocation::freeze_scope();

    for source in &sources {
        lexed.clear();
        GO.lex(source, &mut lexed);

        assert!(go_classify(source, lexed.as_slice(), &mut tokens, &mut raw));

        go_parse::build(source, tokens.as_slice(), &raw, &mut events, &mut built);

        let mut stack = [0_u32; 1 << 10];
        let mut depth = 0;
        let mut seen = 0;

        if built.count() > 0 {
            stack[depth] = 0;
            depth += 1;
        }

        while depth > 0 {
            depth -= 1;

            let view = GoView::new(&built, tokens.as_slice(), &raw, stack[depth]);
            let span = view.span();

            assert!(span.end() as usize <= source.len());

            seen += 1;

            for child in view.children() {
                if depth >= stack.len() {
                    break;
                }

                stack[depth] = child.index();
                depth += 1;
            }
        }

        assert!(seen > 0);
    }
}

#[test]
fn the_zig_syntax_layer_runs_on_a_frozen_thread() {
    let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/zig");
    let mut sources = Vec::new();

    collect_of(&root, "zig", &mut sources);

    assert!(sources.len() > 4);

    let mut lexed = Tokens::reserve(1 << 16);
    let mut tokens = Tokens::reserve(1 << 16);
    let mut raw = BoundedVec::reserve(1 << 16);
    let mut events = Events::reserve(1 << 19);
    let mut built = SyntaxTree::<ZigKind>::reserve(1 << 16, 1 << 10);
    let _scope = crate::allocation::freeze_scope();

    for source in &sources {
        lexed.clear();
        ZIG.lex(source, &mut lexed);

        assert!(zig_classify(
            source,
            lexed.as_slice(),
            &mut tokens,
            &mut raw
        ));

        zig_parse::build(source, tokens.as_slice(), &raw, &mut events, &mut built);

        let mut stack = [0_u32; 1 << 10];
        let mut depth = 0;
        let mut seen = 0;

        if built.count() > 0 {
            stack[depth] = 0;
            depth += 1;
        }

        while depth > 0 {
            depth -= 1;

            let view = ZigView::new(&built, tokens.as_slice(), &raw, stack[depth]);
            let span = view.span();

            assert!(span.end() as usize <= source.len());

            seen += 1;

            for child in view.children() {
                if depth >= stack.len() {
                    break;
                }

                stack[depth] = child.index();
                depth += 1;
            }
        }

        assert!(seen > 0);
    }
}

#[test]
fn the_odin_syntax_layer_runs_on_a_frozen_thread() {
    let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/odin");
    let mut sources = Vec::new();

    collect_of(&root, "odin", &mut sources);

    assert!(sources.len() > 4);

    let mut lexed = Tokens::reserve(1 << 16);
    let mut tokens = Tokens::reserve(1 << 16);
    let mut raw = BoundedVec::reserve(1 << 16);
    let mut events = Events::reserve(1 << 19);
    let mut built = SyntaxTree::<OdinKind>::reserve(1 << 16, 1 << 10);
    let _scope = crate::allocation::freeze_scope();

    for source in &sources {
        lexed.clear();
        ODIN.lex(source, &mut lexed);

        assert!(odin_classify(
            source,
            lexed.as_slice(),
            &mut tokens,
            &mut raw
        ));

        odin_parse::build(source, tokens.as_slice(), &raw, &mut events, &mut built);

        let mut stack = [0_u32; 1 << 10];
        let mut depth = 0;
        let mut seen = 0;

        if built.count() > 0 {
            stack[depth] = 0;
            depth += 1;
        }

        while depth > 0 {
            depth -= 1;

            let view = OdinView::new(&built, tokens.as_slice(), &raw, stack[depth]);
            let span = view.span();

            assert!(span.end() as usize <= source.len());

            seen += 1;

            for child in view.children() {
                if depth >= stack.len() {
                    break;
                }

                stack[depth] = child.index();
                depth += 1;
            }
        }

        assert!(seen > 0);
    }
}

#[test]
fn the_css_syntax_layer_runs_on_a_frozen_thread() {
    let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/css");
    let mut sources = Vec::new();

    collect_of(&root, "css", &mut sources);

    assert!(sources.len() > 4);

    let mut lexed = Tokens::reserve(1 << 16);
    let mut tokens = Tokens::reserve(1 << 16);
    let mut raw = BoundedVec::reserve(1 << 16);
    let mut events = Events::reserve(1 << 19);
    let mut built = SyntaxTree::<CSSKind>::reserve(1 << 16, 1 << 10);
    let _scope = crate::allocation::freeze_scope();

    for source in &sources {
        lexed.clear();
        CSS.lex(source, &mut lexed);

        assert!(css_classify(
            source,
            lexed.as_slice(),
            &mut tokens,
            &mut raw
        ));

        css_parse::build(source, tokens.as_slice(), &raw, &mut events, &mut built);

        let mut stack = [0_u32; 1 << 10];
        let mut depth = 0;
        let mut seen = 0;

        if built.count() > 0 {
            stack[depth] = 0;
            depth += 1;
        }

        while depth > 0 {
            depth -= 1;

            let view = CSSView::new(&built, tokens.as_slice(), &raw, stack[depth]);
            let span = view.span();

            assert!(span.end() as usize <= source.len());

            seen += 1;

            for child in view.children() {
                if depth >= stack.len() {
                    break;
                }

                stack[depth] = child.index();
                depth += 1;
            }
        }

        assert!(seen > 0);
    }
}

#[test]
fn the_fix_engine_runs_on_a_frozen_thread() {
    let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/python");
    let mut sources = Vec::new();

    collect_of(&root, "py", &mut sources);

    assert!(sources.len() > 8);

    let mut claimed = BoundedVec::reserve(1 << 10);
    let mut diagnostics = Diagnostics::reserve(1 << 10, 1 << 16);
    let mut fixes = Fixes::reserve(1 << 10, 1 << 11, 1 << 14);
    let mut held = BoundedVec::reserve(1 << 11);
    let mut out = Buffer::reserve(1 << 20);
    let mut selected = BoundedVec::reserve(1 << 10);
    let mut tokens = Tokens::reserve(1 << 16);
    let _scope = crate::allocation::freeze_scope();

    for source in &sources {
        claimed.clear();
        diagnostics.clear();
        fixes.clear();
        held.clear();
        selected.clear();
        tokens.clear();

        PYTHON.lex(source, &mut tokens);
        record_renames(tokens.as_slice(), &mut fixes, &mut diagnostics);
        diagnostics.sort();
        fix::plan(&fixes, Applicability::Safe, &mut claimed, &mut selected);

        for index in &*selected {
            let fix = *fixes.get(*index).expect("a selected fix is recorded");

            for edit in fixes.edits_of(&fix) {
                if !held.push(*edit) {
                    break;
                }
            }
        }

        let _ = fix::apply(source, &fixes, &held, &mut out);
    }
}

fn record_renames(tokens: &[Token], fixes: &mut Fixes, diagnostics: &mut Diagnostics) {
    for token in tokens {
        if token.kind != TokenKind::Identifier {
            continue;
        }

        fixes.open("Rename", Applicability::Safe, 0);

        if !fixes.edit(token.span(), b"held") {
            let _ = fixes.close();

            break;
        }

        let index = fixes.close();

        if index == fix::NONE {
            break;
        }

        let pushed = diagnostics.push(Diagnostic {
            code: "PR001",
            fix: index,
            message: Message::Static("a name is renamed"),
            rule: crate::rule::NONE,
            severity: Severity::Warning,
            span: token.span(),
        });

        if !pushed {
            break;
        }
    }
}

#[test]
fn the_suppression_scanner_runs_on_a_frozen_thread() {
    let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/python");
    let mut sources = Vec::new();

    collect_of(&root, "py", &mut sources);

    assert!(sources.len() > 8);

    let mut index = lines::Index::reserve(1 << 16);
    let mut spans = BoundedVec::reserve(1 << 14);
    let mut suppressions = Suppressions::reserve(1 << 12, 1 << 13);
    let mut tokens = Tokens::reserve(1 << 16);
    let _scope = crate::allocation::freeze_scope();

    for source in &sources {
        assert!(index.build(source));

        spans.clear();
        tokens.clear();
        PYTHON.lex(source, &mut tokens);

        for token in tokens.as_slice() {
            if token.kind != TokenKind::Comment {
                continue;
            }

            if !spans.push(token.span()) {
                break;
            }
        }

        suppressions.scan(source, spans.iter().copied(), b"noqa", &index);

        for directive in 0..suppressions.count() {
            let held = *suppressions
                .get(directive)
                .expect("the directive is recorded");

            let _ = suppressions.matches(held.line, b"F401", source);
        }

        let _ = suppressions.unconsumed().count();
    }
}

#[test]
fn the_typescript_syntax_layer_runs_on_a_frozen_thread() {
    let root =
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/typescript");
    let mut sources = Vec::new();

    collect_of(&root, "ts", &mut sources);

    assert!(sources.len() > 4);

    let mut lexed = Tokens::reserve(1 << 16);
    let mut tokens = Tokens::reserve(1 << 16);
    let mut raw = BoundedVec::reserve(1 << 16);
    let mut events = Events::reserve(1 << 19);
    let mut built = SyntaxTree::<TypeScriptKind>::reserve(1 << 16, 1 << 10);
    let _scope = crate::allocation::freeze_scope();

    for source in &sources {
        lexed.clear();
        TYPESCRIPT.lex(source, &mut lexed);

        assert!(typescript_classify(
            source,
            lexed.as_slice(),
            &mut tokens,
            &mut raw,
            Dialect::Ts
        ));

        typescript_parse::build(
            source,
            tokens.as_slice(),
            &raw,
            &mut events,
            &mut built,
            Dialect::Ts,
        );

        let mut stack = [0_u32; 1 << 10];
        let mut depth = 0;
        let mut seen = 0;

        if built.count() > 0 {
            stack[depth] = 0;
            depth += 1;
        }

        while depth > 0 {
            depth -= 1;

            let view = TypeScriptView::new(&built, tokens.as_slice(), &raw, stack[depth]);
            let span = view.span();

            assert!(span.end() as usize <= source.len());

            seen += 1;

            for child in view.children() {
                if depth >= stack.len() {
                    break;
                }

                stack[depth] = child.index();
                depth += 1;
            }
        }

        assert!(seen > 0);
    }
}

#[test]
fn the_python_semantic_model_runs_on_a_frozen_thread() {
    let root =
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/python-semantic");

    let mut sources = Vec::new();

    collect_of(&root, "py", &mut sources);

    assert!(sources.len() > 8);

    let builtins: [&[u8]; 4] = [b"len", b"list", b"print", b"str"];
    let mut lexed = Tokens::reserve(1 << 16);
    let mut tokens = Tokens::reserve(1 << 16);
    let mut raw = BoundedVec::reserve(1 << 16);
    let mut events = Events::reserve(1 << 18);
    let mut built = SyntaxTree::<PythonKind>::reserve(1 << 16, 1 << 10);
    let mut tables = Tables::reserve(1 << 10, 1 << 14, 1 << 16, 1 << 12);
    let mut semantic = Semantic::reserve(1 << 12, 1 << 14, 1 << 8);
    let mut scratch = AnnotationScratch::reserve(1 << 8, 1 << 8);
    let _scope = crate::allocation::freeze_scope();

    for source in &sources {
        lexed.clear();
        PYTHON.lex(source, &mut lexed);

        assert!(classify(source, lexed.as_slice(), &mut tokens, &mut raw));

        parse::build(source, tokens.as_slice(), &raw, &mut events, &mut built);

        assert_eq!(
            bind::bind(source, tokens.as_slice(), &raw, &built, &mut tables),
            BindOutcome::Complete
        );

        let outcome = semantic.build(
            &SemanticInput {
                builtins: &builtins,
                raw: &raw,
                scopes: &tables,
                source,
                tokens: tokens.as_slice(),
                tree: &built,
                version: PythonVersion::Py310,
            },
            &mut scratch,
        );

        assert_eq!(outcome, crate::syntax::Structure::Complete);
        assert!(semantic.count() > 0);
    }
}

#[test]
fn the_javascript_semantic_model_runs_on_a_frozen_thread() {
    let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/javascript-semantic");

    let mut sources = Vec::new();

    collect_of(&root, "js", &mut sources);

    assert!(sources.len() > 8);

    let globals: [&[u8]; 3] = [b"console", b"eval", b"require"];
    let mut lexed = Tokens::reserve(1 << 16);
    let mut tokens = Tokens::reserve(1 << 16);
    let mut raw = BoundedVec::reserve(1 << 16);
    let mut events = Events::reserve(1 << 18);
    let mut built = SyntaxTree::<JavaScriptKind>::reserve(1 << 16, 1 << 10);
    let mut semantic = JavaScriptSemantic::reserve(1 << 12, 1 << 14, 1 << 10, 1 << 10);
    let _scope = crate::allocation::freeze_scope();

    for source in &sources {
        lexed.clear();
        JAVASCRIPT.lex(source, &mut lexed);

        assert!(javascript_classify(
            source,
            lexed.as_slice(),
            &mut tokens,
            &mut raw
        ));

        javascript_parse::build(source, tokens.as_slice(), &raw, &mut events, &mut built);

        let outcome = semantic.build(source, tokens.as_slice(), &raw, &built, None, &globals);

        assert_eq!(outcome, crate::syntax::Structure::Complete);
        assert!(semantic.count() > 0);
    }
}

#[test]
fn the_typescript_semantic_model_runs_on_a_frozen_thread() {
    let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/typescript-semantic");

    let mut sources = Vec::new();

    collect_of(&root, "ts", &mut sources);

    assert!(sources.len() > 2);

    let globals: [&[u8]; 3] = [b"console", b"eval", b"require"];
    let mut lexed = Tokens::reserve(1 << 16);
    let mut tokens = Tokens::reserve(1 << 16);
    let mut raw = BoundedVec::reserve(1 << 16);
    let mut events = Events::reserve(1 << 18);
    let mut built = SyntaxTree::<TypeScriptKind>::reserve(1 << 16, 1 << 10);
    let mut semantic = JavaScriptSemantic::reserve(1 << 12, 1 << 14, 1 << 10, 1 << 10);
    let _scope = crate::allocation::freeze_scope();

    for source in &sources {
        lexed.clear();
        TYPESCRIPT.lex(source, &mut lexed);

        assert!(typescript_classify(
            source,
            lexed.as_slice(),
            &mut tokens,
            &mut raw,
            Dialect::Ts
        ));

        typescript_parse::build(
            source,
            tokens.as_slice(),
            &raw,
            &mut events,
            &mut built,
            Dialect::Ts,
        );

        let outcome = semantic.build(source, tokens.as_slice(), &raw, &built, None, &globals);

        assert_eq!(outcome, crate::syntax::Structure::Complete);
        assert!(semantic.count() > 0);
    }
}

#[test]
fn the_go_semantic_model_runs_on_a_frozen_thread() {
    let root =
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/go-semantic");
    let mut sources = Vec::new();

    collect_of(&root, "go", &mut sources);

    assert!(sources.len() > 3);

    let universe: [&[u8]; 3] = [b"error", b"len", b"string"];
    let mut lexed = Tokens::reserve(1 << 16);
    let mut tokens = Tokens::reserve(1 << 16);
    let mut raw = BoundedVec::reserve(1 << 16);
    let mut events = Events::reserve(1 << 18);
    let mut built = SyntaxTree::<GoKind>::reserve(1 << 16, 1 << 10);
    let mut semantic = GoSemantic::reserve(1 << 12, 1 << 14, 1 << 10, 1 << 10);
    let _scope = crate::allocation::freeze_scope();

    for source in &sources {
        lexed.clear();
        GO.lex(source, &mut lexed);

        assert!(go_classify(source, lexed.as_slice(), &mut tokens, &mut raw));

        go_parse::build(source, tokens.as_slice(), &raw, &mut events, &mut built);

        let outcome = semantic.build(source, tokens.as_slice(), &raw, &built, &universe);

        assert_eq!(outcome, crate::syntax::Structure::Complete);
        assert!(semantic.count() > 0);
    }
}

#[test]
fn the_rust_semantic_model_runs_on_a_frozen_thread() {
    let root =
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/rust-semantic");
    let mut sources = Vec::new();

    collect_of(&root, "rs", &mut sources);

    assert!(sources.len() > 6);

    let universe: [&[u8]; 3] = [b"Self", b"usize", b"Some"];
    let mut lexed = Tokens::reserve(1 << 16);
    let mut tokens = Tokens::reserve(1 << 16);
    let mut raw = BoundedVec::reserve(1 << 16);
    let mut events = Events::reserve(1 << 18);
    let mut built = SyntaxTree::<RustKind>::reserve(1 << 16, 1 << 10);
    let mut semantic = RustSemantic::reserve(1 << 12, 1 << 14, 1 << 10, 1 << 10);
    let _scope = crate::allocation::freeze_scope();

    for source in &sources {
        lexed.clear();
        RUST.lex(source, &mut lexed);

        assert!(rust_classify(
            source,
            lexed.as_slice(),
            &mut tokens,
            &mut raw
        ));

        rust_parse::build(source, tokens.as_slice(), &raw, &mut events, &mut built);

        let outcome = semantic.build(source, tokens.as_slice(), &raw, &built, &universe);

        assert_eq!(outcome, crate::syntax::Structure::Complete);
        assert!(semantic.count() > 0);
    }
}

#[test]
fn the_zig_semantic_model_runs_on_a_frozen_thread() {
    let root =
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/zig-semantic");
    let mut sources = Vec::new();

    collect_of(&root, "zig", &mut sources);

    assert!(sources.len() > 4);

    let universe: [&[u8]; 3] = [b"bool", b"usize", b"void"];
    let mut lexed = Tokens::reserve(1 << 16);
    let mut tokens = Tokens::reserve(1 << 16);
    let mut raw = BoundedVec::reserve(1 << 16);
    let mut events = Events::reserve(1 << 18);
    let mut built = SyntaxTree::<ZigKind>::reserve(1 << 16, 1 << 10);
    let mut semantic = ZigSemantic::reserve(1 << 12, 1 << 14, 1 << 10, 1 << 10);
    let _scope = crate::allocation::freeze_scope();

    for source in &sources {
        lexed.clear();
        ZIG.lex(source, &mut lexed);

        assert!(zig_classify(
            source,
            lexed.as_slice(),
            &mut tokens,
            &mut raw
        ));

        zig_parse::build(source, tokens.as_slice(), &raw, &mut events, &mut built);

        let outcome = semantic.build(source, tokens.as_slice(), &raw, &built, &universe);

        assert_eq!(outcome, crate::syntax::Structure::Complete);
        assert!(semantic.count() > 0);
    }
}

#[test]
fn the_odin_semantic_model_runs_on_a_frozen_thread() {
    let root =
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/odin-semantic");
    let mut sources = Vec::new();

    collect_of(&root, "odin", &mut sources);

    assert!(sources.len() > 3);

    let universe: [&[u8]; 3] = [b"bool", b"int", b"string"];
    let mut lexed = Tokens::reserve(1 << 16);
    let mut tokens = Tokens::reserve(1 << 16);
    let mut raw = BoundedVec::reserve(1 << 16);
    let mut events = Events::reserve(1 << 18);
    let mut built = SyntaxTree::<OdinKind>::reserve(1 << 16, 1 << 10);
    let mut semantic = OdinSemantic::reserve(1 << 12, 1 << 14, 1 << 10, 1 << 10);
    let _scope = crate::allocation::freeze_scope();

    for source in &sources {
        lexed.clear();
        ODIN.lex(source, &mut lexed);

        assert!(odin_classify(
            source,
            lexed.as_slice(),
            &mut tokens,
            &mut raw
        ));

        odin_parse::build(source, tokens.as_slice(), &raw, &mut events, &mut built);

        let outcome = semantic.build(source, tokens.as_slice(), &raw, &built, &universe);

        assert_eq!(outcome, crate::syntax::Structure::Complete);
        assert!(semantic.count() > 0);
    }
}

#[test]
fn the_css_reference_model_runs_on_a_frozen_thread() {
    let root =
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/css-semantic");
    let mut sources = Vec::new();

    collect_of(&root, "css", &mut sources);

    assert!(sources.len() > 3);

    let mut lexed = Tokens::reserve(1 << 16);
    let mut tokens = Tokens::reserve(1 << 16);
    let mut raw = BoundedVec::reserve(1 << 16);
    let mut events = Events::reserve(1 << 18);
    let mut built = SyntaxTree::<CSSKind>::reserve(1 << 16, 1 << 10);
    let mut semantic = CSSSemantic::reserve(1 << 12, 1 << 12, 1 << 10);
    let _scope = crate::allocation::freeze_scope();

    for source in &sources {
        lexed.clear();
        CSS.lex(source, &mut lexed);

        assert!(css_classify(
            source,
            lexed.as_slice(),
            &mut tokens,
            &mut raw
        ));

        css_parse::build(source, tokens.as_slice(), &raw, &mut events, &mut built);

        let outcome = semantic.build(source, tokens.as_slice(), &raw, &built);

        assert_eq!(outcome, crate::syntax::Structure::Complete);
        assert!(semantic.count() > 0);
    }
}

#[test]
fn the_formatting_document_runs_on_a_frozen_thread() {
    let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/python");
    let mut sources = Vec::new();

    collect_of(&root, "py", &mut sources);

    assert!(sources.len() > 8);

    let mut document = Document::reserve(1 << 17, 1 << 4);
    let mut tokens = Tokens::reserve(1 << 16);
    let comma = document.literal(b",");
    let span = document.literal_span(comma);
    let _scope = crate::allocation::freeze_scope();

    for source in &sources {
        document.clear();
        tokens.clear();

        PYTHON.lex(source, &mut tokens);

        if !document.push(Element::GroupOpen) {
            continue;
        }

        for token in tokens.as_slice() {
            if !document.push(Element::Text(ElementSource::Document, token.span())) {
                break;
            }

            if !document.push(Element::IfBroken(span)) {
                break;
            }

            if !document.push(Element::Line) {
                break;
            }
        }

        assert!(document.count() > 0);
    }
}

#[test]
fn the_python_formatter_runs_on_a_frozen_thread() {
    let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/python");
    let mut sources = Vec::new();

    collect_of(&root, "py", &mut sources);

    assert!(sources.len() > 8);

    let mut built = SyntaxTree::<PythonKind>::reserve(1 << 16, 1 << 10);
    let mut events = Events::reserve(1 << 18);
    let mut formatter = Formatter::reserve(1 << 18, 1 << 18);
    let mut lexed = Tokens::reserve(1 << 16);
    let mut out = Buffer::reserve(1 << 20);
    let mut raw = BoundedVec::reserve(1 << 16);
    let mut tokens = Tokens::reserve(1 << 16);
    let _scope = crate::allocation::freeze_scope();

    for source in &sources {
        lexed.clear();
        PYTHON.lex(source, &mut lexed);

        assert!(classify(source, lexed.as_slice(), &mut tokens, &mut raw));

        let outcome = parse::build(source, tokens.as_slice(), &raw, &mut events, &mut built);

        let input = Input {
            line_ending: LineEnding::LineFeed,
            magic_trailing_comma: true,
            options: Options::DEFAULT,
            outcome,
            pragmas: &[],
            quote: QuotePreference::Double,
            raw: &raw,
            source,
            tokens: tokens.as_slice(),
            tree: &built,
        };

        assert_eq!(formatter.format(&input, &mut out), Outcome::Complete);
        assert!(!out.is_empty());
    }
}

#[test]
fn the_markup_formatter_runs_on_a_frozen_thread() {
    let mut sources = Vec::new();

    collect(
        &std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/templates"),
        &mut sources,
    );

    assert!(sources.len() > 300);

    let mut built = Tree::reserve(1 << 17, 1 << 10);
    let mut formatter = MarkupFormatter::reserve(1 << 18, 1 << 14, 1 << 20);
    let mut index = lines::Index::reserve(1 << 14);
    let mut map = BlockMap::reserve(1 << 12);
    let mut out = Buffer::reserve(1 << 20);
    let mut tokens = MarkupTokens::reserve(1 << 18);
    let _scope = crate::allocation::freeze_scope();

    for (source, python) in &sources {
        if *python {
            continue;
        }

        assert!(index.build(source));

        markup::lex(source, &mut tokens);
        tree::build(source, tokens.as_slice(), &mut built);
        blocks::build(source, tokens.as_slice(), &built, &[], &[], &mut map);

        let input = MarkupInput {
            index: &index,
            map: &map,
            options: Options::DEFAULT,
            source,
            tokens: tokens.as_slice(),
            tree: &built,
        };

        assert_ne!(formatter.format(&input, &mut out), MarkupOutcome::Overflow);
    }
}

#[test]
fn the_go_formatter_runs_on_a_frozen_thread() {
    let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/go");
    let mut sources = Vec::new();

    collect_of(&root, "go", &mut sources);

    assert!(sources.len() > 4);

    let mut built = SyntaxTree::<GoKind>::reserve(1 << 16, 1 << 10);
    let mut events = Events::<GoKind>::reserve(1 << 18);
    let mut formatter = GoFormatter::reserve(1 << 18, 1 << 20);
    let mut lexed = Tokens::reserve(1 << 16);
    let mut out = Buffer::reserve(1 << 20);
    let mut raw = BoundedVec::reserve(1 << 16);
    let mut tokens = Tokens::reserve(1 << 16);
    let _scope = crate::allocation::freeze_scope();

    for source in &sources {
        lexed.clear();
        GO.lex(source, &mut lexed);

        assert!(go_classify(source, lexed.as_slice(), &mut tokens, &mut raw));

        let outcome = go_parse::build(source, tokens.as_slice(), &raw, &mut events, &mut built);

        let input = GoInput {
            options: Options::DEFAULT,
            outcome,
            raw: &raw,
            source,
            tokens: tokens.as_slice(),
            tree: &built,
        };

        assert_eq!(formatter.format(&input, &mut out), GoOutcome::Complete);
    }
}

#[test]
fn the_rust_formatter_runs_on_a_frozen_thread() {
    let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/rust");
    let mut sources = Vec::new();

    collect_of(&root, "rs", &mut sources);

    assert!(sources.len() > 4);

    let mut built = SyntaxTree::<RustKind>::reserve(1 << 16, 1 << 10);
    let mut events = Events::<RustKind>::reserve(1 << 18);
    let mut formatter = RustFormatter::reserve(1 << 18, 1 << 20);
    let mut lexed = Tokens::reserve(1 << 16);
    let mut out = Buffer::reserve(1 << 20);
    let mut raw = BoundedVec::reserve(1 << 16);
    let mut tokens = Tokens::reserve(1 << 16);
    let _scope = crate::allocation::freeze_scope();

    for source in &sources {
        lexed.clear();
        RUST.lex(source, &mut lexed);

        assert!(rust_classify(
            source,
            lexed.as_slice(),
            &mut tokens,
            &mut raw
        ));

        let outcome = rust_parse::build(source, tokens.as_slice(), &raw, &mut events, &mut built);

        let input = RustInput {
            options: Options::DEFAULT,
            outcome,
            raw: &raw,
            source,
            tokens: tokens.as_slice(),
            tree: &built,
        };

        assert_eq!(formatter.format(&input, &mut out), RustOutcome::Complete);
    }
}

#[test]
fn the_zig_formatter_runs_on_a_frozen_thread() {
    let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/zig");
    let mut sources = Vec::new();

    collect_of(&root, "zig", &mut sources);

    assert!(sources.len() > 4);

    let mut built = SyntaxTree::<ZigKind>::reserve(1 << 16, 1 << 10);
    let mut events = Events::<ZigKind>::reserve(1 << 18);
    let mut formatter = ZigFormatter::reserve(1 << 18, 1 << 20);
    let mut lexed = Tokens::reserve(1 << 16);
    let mut out = Buffer::reserve(1 << 20);
    let mut raw = BoundedVec::reserve(1 << 16);
    let mut tokens = Tokens::reserve(1 << 16);
    let _scope = crate::allocation::freeze_scope();

    for source in &sources {
        lexed.clear();
        ZIG.lex(source, &mut lexed);

        assert!(zig_classify(
            source,
            lexed.as_slice(),
            &mut tokens,
            &mut raw
        ));

        let outcome = zig_parse::build(source, tokens.as_slice(), &raw, &mut events, &mut built);

        let input = ZigInput {
            options: Options::DEFAULT,
            outcome,
            raw: &raw,
            source,
            tokens: tokens.as_slice(),
            tree: &built,
        };

        assert_eq!(formatter.format(&input, &mut out), ZigOutcome::Complete);
    }
}

#[test]
fn the_css_formatter_runs_on_a_frozen_thread() {
    let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/css");
    let mut sources = Vec::new();

    collect_of(&root, "css", &mut sources);

    assert!(sources.len() > 3);

    let mut built = SyntaxTree::<CSSKind>::reserve(1 << 16, 1 << 10);
    let mut events = Events::<CSSKind>::reserve(1 << 18);
    let mut formatter = CSSFormatter::reserve(1 << 18, 1 << 20);
    let mut lexed = Tokens::reserve(1 << 16);
    let mut out = Buffer::reserve(1 << 20);
    let mut raw = BoundedVec::reserve(1 << 16);
    let mut tokens = Tokens::reserve(1 << 16);
    let _scope = crate::allocation::freeze_scope();

    for source in &sources {
        lexed.clear();
        CSS.lex(source, &mut lexed);

        assert!(css_classify(
            source,
            lexed.as_slice(),
            &mut tokens,
            &mut raw
        ));

        let outcome = css_parse::build(source, tokens.as_slice(), &raw, &mut events, &mut built);

        let input = CSSInput {
            options: Options::DEFAULT,
            outcome,
            raw: &raw,
            source,
            tokens: tokens.as_slice(),
            tree: &built,
        };

        assert_eq!(formatter.format(&input, &mut out), CSSOutcome::Complete);
    }
}

#[test]
fn the_javascript_formatter_runs_on_a_frozen_thread() {
    let root =
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/javascript");
    let mut sources = Vec::new();

    collect_of(&root, "js", &mut sources);

    assert!(sources.len() > 8);

    let mut built = SyntaxTree::<JavaScriptKind>::reserve(1 << 16, 1 << 10);
    let mut events = Events::<JavaScriptKind>::reserve(1 << 18);
    let mut formatter = JavaScriptFormatter::reserve(1 << 18, 1 << 20);
    let mut lexed = Tokens::reserve(1 << 16);
    let mut out = Buffer::reserve(1 << 20);
    let mut raw = BoundedVec::reserve(1 << 16);
    let mut tokens = Tokens::reserve(1 << 16);
    let _scope = crate::allocation::freeze_scope();

    for source in &sources {
        lexed.clear();
        JAVASCRIPT.lex(source, &mut lexed);

        assert!(javascript_classify(
            source,
            lexed.as_slice(),
            &mut tokens,
            &mut raw
        ));

        let outcome =
            javascript_parse::build(source, tokens.as_slice(), &raw, &mut events, &mut built);

        let input = JavaScriptInput {
            options: Options::DEFAULT,
            outcome,
            raw: &raw,
            source,
            tokens: tokens.as_slice(),
            tree: &built,
        };

        assert_ne!(
            formatter.format(&input, &mut out),
            JavaScriptOutcome::Overflow
        );
    }
}

#[test]
fn the_odin_formatter_runs_on_a_frozen_thread() {
    let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/odin");
    let mut sources = Vec::new();

    collect_of(&root, "odin", &mut sources);

    assert!(sources.len() > 3);

    let mut built = SyntaxTree::<OdinKind>::reserve(1 << 16, 1 << 10);
    let mut events = Events::<OdinKind>::reserve(1 << 18);
    let mut formatter = OdinFormatter::reserve(1 << 18, 1 << 20);
    let mut lexed = Tokens::reserve(1 << 16);
    let mut out = Buffer::reserve(1 << 20);
    let mut raw = BoundedVec::reserve(1 << 16);
    let mut tokens = Tokens::reserve(1 << 16);
    let _scope = crate::allocation::freeze_scope();

    for source in &sources {
        lexed.clear();
        ODIN.lex(source, &mut lexed);

        assert!(odin_classify(
            source,
            lexed.as_slice(),
            &mut tokens,
            &mut raw
        ));

        let outcome = odin_parse::build(source, tokens.as_slice(), &raw, &mut events, &mut built);

        let input = OdinInput {
            options: Options::DEFAULT,
            outcome,
            raw: &raw,
            source,
            tokens: tokens.as_slice(),
            tree: &built,
        };

        assert_eq!(formatter.format(&input, &mut out), OdinOutcome::Complete);
    }
}

fn project_limits() -> Limits {
    let mut slots = [[0_u32; CLASS_COUNT]; Language::COUNT];

    slots[Language::Css.index()][Limits::class_of(1 << 14) as usize] = 1;
    slots[Language::Go.index()][Limits::class_of(1 << 14) as usize] = 1;
    slots[Language::Markup.index()][Limits::class_of(1 << 14) as usize] = 1;
    slots[Language::Python.index()][Limits::class_of(1 << 14) as usize] = 2;
    slots[Language::Rust.index()][Limits::class_of(1 << 14) as usize] = 1;
    slots[Language::TypeScript.index()][Limits::class_of(1 << 14) as usize] = 1;

    Limits {
        file_count_max: 7,
        front: front::Limits {
            binding_count_max: 1 << 10,
            error_count_max: 1 << 8,
            event_count_max: 1 << 14,
            export_count_max: 1 << 10,
            fact_count_max: 1 << 10,
            node_count_max: 1 << 13,
            reference_count_max: 1 << 10,
            scope_count_max: 1 << 8,
            segment_count_max: 1 << 10,
            token_count_max: 1 << 12,
        },
        line_count_max: 1 << 10,
        slots,
        source_bytes_max: 1 << 14,
    }
}

#[test]
fn the_project_store_runs_on_a_frozen_thread() {
    const CSS_SOURCE: &[u8] = b"a { color: red; }\n";

    const GO_SOURCE: &[u8] =
        b"package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(1)\n}\n";

    const PYTHON_SOURCE: &[u8] = b"import os\n\n\ndef run():\n    return os\n";
    const RUST_SOURCE: &[u8] = b"fn run() -> u32 {\n    1\n}\n";
    const TEMPLATE_SOURCE: &[u8] = b"<div>{% block body %}{% endblock %}</div>\n";
    const TYPESCRIPT_SOURCE: &[u8] = b"export const one: number = 1;\n";
    let limits = project_limits();
    let mut store = Store::reserve(&limits, Eviction::LeastRecentlyUsed);
    let _scope = crate::allocation::freeze_scope();

    let files = [
        (b"a.css".as_slice(), Language::Css, CSS_SOURCE),
        (b"a.go".as_slice(), Language::Go, GO_SOURCE),
        (b"a.html".as_slice(), Language::Markup, TEMPLATE_SOURCE),
        (b"a.py".as_slice(), Language::Python, PYTHON_SOURCE),
        (b"b.py".as_slice(), Language::Python, PYTHON_SOURCE),
        (b"a.rs".as_slice(), Language::Rust, RUST_SOURCE),
        (b"a.ts".as_slice(), Language::TypeScript, TYPESCRIPT_SOURCE),
    ];

    for (path, language, source) in files {
        let index = store.insert(hash_of(path), language, source);

        assert!(index != NONE);
        assert_eq!(store.source_of(FileID::of(index)), source);
    }

    assert_eq!(store.count(), 7);

    for round in 0..64_u32 {
        let path = if round % 2 == 0 { b"c.py" } else { b"d.py" };
        let index = store.insert(hash_of(path), Language::Python, PYTHON_SOURCE);

        assert!(index != NONE);

        store.touch(FileID::of(index));
        store.evict(FileID::of(index));
    }

    store.clear();

    assert_eq!(store.count(), 0);
}

fn project_resolve(specifier: &[u8], _from: FileID, store: &Store) -> u32 {
    store.find(hash_of(specifier))
}

#[test]
fn the_project_graph_runs_on_a_frozen_thread() {
    const SOURCES: [(&[u8], &[u8]); 5] = [
        (b"a", b"import b\nimport c\n"),
        (b"b", b"import d\n"),
        (b"c", b"import d\nimport missing\n"),
        (b"d", b"import a\n"),
        (b"e", b"x = 1\n"),
    ];

    let mut slots = [[0_u32; CLASS_COUNT]; Language::COUNT];

    slots[Language::Python.index()][Limits::class_of(1 << 10) as usize] = 5;

    let limits = Limits {
        file_count_max: 5,
        front: front::Limits {
            binding_count_max: 1 << 8,
            error_count_max: 1 << 6,
            event_count_max: 1 << 12,
            export_count_max: 1 << 8,
            fact_count_max: 1 << 8,
            node_count_max: 1 << 11,
            reference_count_max: 1 << 8,
            scope_count_max: 1 << 6,
            segment_count_max: 1 << 8,
            token_count_max: 1 << 9,
        },
        line_count_max: 1 << 8,
        slots,
        source_bytes_max: 1 << 10,
    };

    let mut store = Store::reserve(&limits, Eviction::Reject);
    let mut graph = Graph::reserve(1 << 8, 5);
    let _scope = crate::allocation::freeze_scope();

    for (name, source) in SOURCES {
        let index = store.insert(hash_of(name), Language::Python, source);

        assert!(index != NONE);
    }

    for _ in 0..64 {
        assert!(graph.build(&store, &project_resolve));
        assert_eq!(graph.order().len(), 5);
        assert_eq!(graph.cycles().count(), 1);

        graph.clear();

        assert_eq!(graph.count(), 0);
    }
}

fn report_limits() -> Limits {
    let mut slots = [[0_u32; CLASS_COUNT]; Language::COUNT];

    slots[Language::Python.index()][Limits::class_of(1 << 10) as usize] = 3;

    Limits {
        file_count_max: 3,
        front: front::Limits {
            binding_count_max: 1 << 8,
            error_count_max: 1 << 6,
            event_count_max: 1 << 12,
            export_count_max: 1 << 8,
            fact_count_max: 1 << 8,
            node_count_max: 1 << 11,
            reference_count_max: 1 << 8,
            scope_count_max: 1 << 6,
            segment_count_max: 1 << 8,
            token_count_max: 1 << 9,
        },
        line_count_max: 1 << 8,
        slots,
        source_bytes_max: 1 << 10,
    }
}

fn report_budget() -> Budget {
    Budget {
        arena_bytes_max: 1 << 12,
        diagnostic_bytes_max: 1 << 12,
        diagnostic_count_max: 1 << 6,
        edge_count_max: 1 << 6,
        edit_count_max: 1 << 6,
        fix_count_max: 1 << 5,
    }
}

fn report_row(offset: u32) -> Diagnostic {
    Diagnostic {
        code: "PRJ900",
        fix: fix::NONE,
        message: Message::Static("a recorded finding"),
        rule: crate::rule::NONE,
        severity: Severity::Warning,
        span: Span { length: 1, offset },
    }
}

#[test]
fn the_project_report_runs_on_a_frozen_thread() {
    const SOURCES: [(&[u8], &[u8]); 3] = [
        (b"a", b"import b\n"),
        (b"b", b"value = 1\n"),
        (b"c", b"other = 2\n"),
    ];

    let limits = report_limits();
    let mut project = Project::reserve(&limits, Eviction::Reject, &report_budget());
    let _scope = crate::allocation::freeze_scope();

    for (name, source) in SOURCES {
        let index = project
            .store_mut()
            .insert(hash_of(name), Language::Python, source);

        assert!(index != NONE);
    }

    assert!(project.build(&project_resolve));

    let mut expected = 0;

    for round in 0..64_u32 {
        for file in 0..3_u32 {
            let recorded = project.record(FileID::of(file), report_row(round % 8));

            assert!(recorded);

            expected += 1;
        }

        project.sort();

        assert_eq!(project.count(), expected);

        if expected < 180 {
            continue;
        }

        for file in 0..3_u32 {
            project.clear_file(FileID::of(file));
        }

        expected = 0;
    }

    project.clear();

    assert_eq!(project.count(), 0);
}

const PARALLEL_SHARD_COUNT: usize = 4;

fn parallel_limits() -> Limits {
    let mut slots = [[0_u32; CLASS_COUNT]; Language::COUNT];

    slots[Language::Python.index()][Limits::class_of(1 << 10) as usize] = 16;

    Limits {
        file_count_max: 16,
        front: front::Limits {
            binding_count_max: 1 << 8,
            error_count_max: 1 << 6,
            event_count_max: 1 << 12,
            export_count_max: 1 << 8,
            fact_count_max: 1 << 8,
            node_count_max: 1 << 11,
            reference_count_max: 1 << 8,
            scope_count_max: 1 << 6,
            segment_count_max: 1 << 8,
            token_count_max: 1 << 9,
        },
        line_count_max: 1 << 8,
        slots,
        source_bytes_max: 1 << 10,
    }
}

fn parallel_rule(store: &Store, file: FileID, sink: &mut Sink<'_>) {
    for step in store.walk(file) {
        let Step::Enter(node) = step else {
            continue;
        };

        let Some(view) = store.python_view(file, node) else {
            continue;
        };

        let recorded = sink.record("PRJ901", Severity::Hint, view.span(), "a recorded finding");

        assert!(recorded);
    }
}

#[test]
fn a_project_fan_out_runs_on_frozen_threads() {
    let limits = parallel_limits();
    let mut store = Store::reserve(&limits, Eviction::Reject);

    for index in 0..16_u32 {
        let key = [
            b'f',
            b'0' + u8::try_from(index / 10).expect("a digit"),
            b'0' + u8::try_from(index % 10).expect("a digit"),
        ];

        let inserted = store.insert(
            hash_of(&key),
            Language::Python,
            b"value = 1\n\n\ndef run():\n    return value\n",
        );

        assert!(inserted != NONE);
    }

    let mut scratch = Vec::with_capacity(PARALLEL_SHARD_COUNT);

    for _ in 0..PARALLEL_SHARD_COUNT {
        scratch.push(Diagnostics::reserve(1 << 12, 1 << 16));
    }

    let files: Vec<FileID> = store.files().collect();
    let held = &store;
    let registry = Registry::reserve(&PARALLEL_RULES);
    let rules = &registry;
    let single = parallel_single(held, &files, rules);

    let merged: usize = std::thread::scope(|scope| {
        let mut handles = Vec::with_capacity(PARALLEL_SHARD_COUNT);

        for (shard, out) in scratch.iter_mut().enumerate() {
            let names = &files;

            handles.push(scope.spawn(move || {
                let _scope = crate::allocation::freeze_scope();
                let mut found = 0;

                for (position, file) in names.iter().enumerate() {
                    if position % PARALLEL_SHARD_COUNT != shard {
                        continue;
                    }

                    out.clear();

                    let mut sink = Sink::new(*file, out, rules);

                    parallel_rule(held, *file, &mut sink);

                    found += sink.count() as usize;
                }

                found
            }));
        }

        handles
            .into_iter()
            .map(|handle| handle.join().expect("the shard finished"))
            .sum()
    });

    assert_eq!(merged, single);
    assert!(merged > 0);
}

static PARALLEL_RULES: [Rule; 1] = [Rule {
    citation_nasa: "",
    citation_tigerstyle: "",
    default_on: true,
    description: "",
    code: "P001",
    explanation: "The fan-out records one row a file so the shards have something to merge.",
    fix_title: "",
    fixable: Fixable::Never,
    name: "parallel-probe",
    preview: false,
    severity: Severity::Warning,
    summary: "Parallel probe",
    url: "",
}];

fn parallel_single(store: &Store, files: &[FileID], registry: &Registry) -> usize {
    let mut out = Diagnostics::reserve(1 << 12, 1 << 16);
    let mut found = 0;

    for file in files {
        out.clear();

        let mut sink = Sink::new(*file, &mut out, registry);

        parallel_rule(store, *file, &mut sink);

        found += sink.count() as usize;
    }

    found
}
