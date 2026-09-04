use std::path::{Path, PathBuf};

use oracle_treesitter::Correction;
use scylla::bounded::BoundedVec;
use scylla::lex::{CSS, GO, JAVASCRIPT, ODIN, PYTHON, RUST, TYPESCRIPT, ZIG};
use scylla::syntax::css::kind::CSSKind;
use scylla::syntax::css::{classify::classify as css_classify, parse as css_parse};
use scylla::syntax::go::kind::GoKind;
use scylla::syntax::go::{classify::classify as go_classify, parse as go_parse};
use scylla::syntax::javascript::kind::JavaScriptKind;
use scylla::syntax::javascript::{
    classify::classify as javascript_classify,
    parse as javascript_parse,
};
use scylla::syntax::odin::kind::OdinKind;
use scylla::syntax::odin::{classify::classify as odin_classify, parse as odin_parse};
use scylla::syntax::python::kind::PythonKind;
use scylla::syntax::python::{classify::classify as python_classify, parse as python_parse};
use scylla::syntax::rust::kind::RustKind;
use scylla::syntax::rust::{classify::classify as rust_classify, parse as rust_parse};
use scylla::syntax::typescript::{
    classify::classify as typescript_classify,
    dialect::Dialect,
    kind::TypeScriptKind,
    parse as typescript_parse,
};
use scylla::syntax::zig::kind::ZigKind;
use scylla::syntax::zig::{classify::classify as zig_classify, parse as zig_parse};
use scylla::syntax::Structure;
use scylla::token::{Token, Tokens};
use scylla::tree::{Events, Tree};
use scylla::trivia::CONTINUATION_NONE;

use crate::analyzer::{Analyzer, Native};
use crate::arbiter::{Arbiter, Program, Reading, Setup};
use crate::binder;
use crate::format::{program_of, Reference, Rewrites, Shape, Subprocess};
use crate::normalize::{self, Normalizer};
use crate::oracle::{Batch, Oracle, Ruff, Syn, TreeSitter, Version};
use crate::printer;

pub struct Descriptor {
    pub analyzer: Box<dyn Analyzer>,
    pub arbiter: Option<Box<dyn Arbiter>>,
    pub continuation: u8,
    pub extensions: &'static [&'static str],
    pub rewrites: Rewrites,
    pub name: &'static str,
    pub normalizer: Option<&'static Normalizer>,
    pub oracle: Box<dyn Oracle>,
    pub reference: Option<Box<dyn Reference>>,
    pub regroups: bool,
}

const CONTINUATION: u8 = b'\\';

pub const EVERY_LANGUAGE: [&str; 9] = [
    "css",
    "go",
    "javascript",
    "odin",
    "python",
    "rust",
    "tsx",
    "typescript",
    "zig",
];

pub fn descriptor_of(name: &str, tools: &Path, corpus: &Path) -> Result<Descriptor, String> {
    match name {
        "css" => Ok(Descriptor {
            analyzer: Box::new(Native::reserve(
                &CSS,
                css_classify,
                css_parse::build,
                CSSKind::name,
                Box::new(printer::Css::reserve()),
                None,
            )),
            arbiter: postcss(tools),
            continuation: CONTINUATION_NONE,
            extensions: &["css"],
            rewrites: Rewrites {
                cases: true,
                counts: true,
                folds: true,
                quotes: true,
                separators: true,
                ..Rewrites::default()
            },
            name: "css",
            normalizer: Some(&normalize::CSS),
            oracle: Box::new(TreeSitter::of(
                "tree-sitter",
                &tree_sitter_css::LANGUAGE.into(),
                Correction::None,
            )?),
            reference: biome(tools, "css"),
            regroups: false,
        }),
        "go" => Ok(Descriptor {
            analyzer: Box::new(Native::reserve(
                &GO,
                go_classify,
                go_parse::build,
                GoKind::name,
                Box::new(printer::Go::reserve()),
                None,
            )),
            arbiter: None,
            continuation: CONTINUATION_NONE,
            extensions: &["go"],
            rewrites: Rewrites {
                semicolons: true,
                ..Rewrites::default()
            },
            name: "go",
            normalizer: None,
            oracle: Box::new(Batch::of(
                "go",
                tools.join("oracle-go/oracle-go"),
                "go",
                &Version {
                    arguments: &["version"],
                    pin: &tools.join("oracle-go/PIN"),
                    program: "go",
                },
            )?),
            reference: gofmt(tools),
            regroups: false,
        }),
        "javascript" => Ok(Descriptor {
            analyzer: Box::new(Native::reserve(
                &JAVASCRIPT,
                javascript_classify,
                javascript_parse::build,
                JavaScriptKind::name,
                Box::new(printer::JavaScript::reserve()),
                None,
            )),
            arbiter: estree(tools, "js"),
            continuation: CONTINUATION_NONE,
            extensions: &["cjs", "js", "mjs"],
            rewrites: Rewrites {
                commas: true,
                constructs: true,
                grouped: true,
                keys: true,
                numbers: true,
                parens: true,
                returns: true,
                terminators: true,
                unions: true,
                ..Rewrites::default()
            },
            name: "javascript",
            normalizer: Some(&normalize::JAVASCRIPT),
            oracle: Box::new(TreeSitter::of(
                "tree-sitter",
                &tree_sitter_javascript::LANGUAGE.into(),
                Correction::None,
            )?),
            reference: biome(tools, "js"),
            regroups: false,
        }),
        "odin" => Ok(Descriptor {
            analyzer: Box::new(Native::reserve(
                &ODIN,
                odin_classify,
                odin_parse::build,
                OdinKind::name,
                Box::new(printer::Odin::reserve()),
                None,
            )),
            arbiter: odin(tools),
            continuation: CONTINUATION,
            extensions: &["odin"],
            rewrites: Rewrites::default(),
            name: "odin",
            normalizer: Some(&normalize::ODIN),
            oracle: Box::new(TreeSitter::of(
                "tree-sitter",
                &tree_sitter_odin::LANGUAGE.into(),
                Correction::Odin,
            )?),
            reference: None,
            regroups: false,
        }),
        "python" => Ok(Descriptor {
            analyzer: Box::new(Native::reserve(
                &PYTHON,
                python_classify,
                python_parse::build,
                PythonKind::name,
                Box::new(printer::Python::reserve()),
                Some(Box::new(binder::Python::reserve())),
            )),
            arbiter: None,
            continuation: CONTINUATION,
            extensions: &["py", "pyi"],
            rewrites: Rewrites {
                cases: true,
                groups: true,
                joins: true,
                semicolons: true,
                zeros: true,
                ..Rewrites::default()
            },
            name: "python",
            normalizer: None,
            oracle: Box::new(Ruff),
            reference: ruff_format(tools),
            regroups: true,
        }),
        "rust" => Ok(Descriptor {
            analyzer: Box::new(Native::reserve(
                &RUST,
                rust_classify,
                rust_parse::build,
                RustKind::name,
                Box::new(printer::Rust::reserve()),
                None,
            )),
            arbiter: rust(corpus),
            continuation: CONTINUATION_NONE,
            extensions: &["rs"],
            rewrites: Rewrites {
                arms: true,
                blocks: true,
                commas: true,
                imports: true,
                orders: true,
                terminators: true,
                ..Rewrites::default()
            },
            name: "rust",
            normalizer: None,
            oracle: Box::new(Syn),
            reference: rustfmt(tools),
            regroups: false,
        }),
        "tsx" => Ok(Descriptor {
            analyzer: Box::new(Native::reserve(
                &TYPESCRIPT,
                classify_tsx,
                build_tsx,
                TypeScriptKind::name,
                Box::new(printer::TypeScript::reserve()),
                None,
            )),
            arbiter: estree(tools, "tsx"),
            continuation: CONTINUATION_NONE,
            extensions: &["tsx"],
            rewrites: Rewrites {
                commas: true,
                constructs: true,
                grouped: true,
                keys: true,
                members: true,
                numbers: true,
                parens: true,
                returns: true,
                terminators: true,
                unions: true,
                ..Rewrites::default()
            },
            name: "tsx",
            normalizer: Some(&normalize::TYPESCRIPT),
            oracle: Box::new(TreeSitter::of(
                "tree-sitter",
                &tree_sitter_typescript::LANGUAGE_TSX.into(),
                Correction::TypeScript,
            )?),
            reference: biome(tools, "tsx"),
            regroups: false,
        }),
        "typescript" => Ok(Descriptor {
            analyzer: Box::new(Native::reserve(
                &TYPESCRIPT,
                classify_ts,
                build_ts,
                TypeScriptKind::name,
                Box::new(printer::TypeScript::reserve()),
                None,
            )),
            arbiter: estree(tools, "ts"),
            continuation: CONTINUATION_NONE,
            extensions: &["cts", "mts", "ts"],
            rewrites: Rewrites {
                commas: true,
                constructs: true,
                grouped: true,
                keys: true,
                members: true,
                numbers: true,
                parens: true,
                returns: true,
                terminators: true,
                unions: true,
                ..Rewrites::default()
            },
            name: "typescript",
            normalizer: Some(&normalize::TYPESCRIPT),
            oracle: Box::new(TreeSitter::of(
                "tree-sitter",
                &tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(),
                Correction::TypeScript,
            )?),
            reference: biome(tools, "ts"),
            regroups: false,
        }),
        "zig" => Ok(Descriptor {
            analyzer: Box::new(Native::reserve(
                &ZIG,
                zig_classify,
                zig_parse::build,
                ZigKind::name,
                Box::new(printer::Zig::reserve()),
                None,
            )),
            arbiter: None,
            continuation: CONTINUATION_NONE,
            extensions: &["zig"],
            rewrites: Rewrites {
                casts: true,
                ..Rewrites::default()
            },
            name: "zig",
            normalizer: None,
            oracle: Box::new(Batch::of(
                "zig",
                tools.join("oracle-zig/zig-out/bin/oracle-zig"),
                "zig",
                &Version {
                    arguments: &["version"],
                    pin: &tools.join("oracle-zig/PIN"),
                    program: &zig_program(&tools.join("oracle-zig/PIN")),
                },
            )?),
            reference: zigfmt(tools),
            regroups: false,
        }),
        other => Err(format!("`{other}` names no language the runner carries")),
    }
}

fn biome(tools: &Path, extension: &str) -> Option<Box<dyn Reference>> {
    let program = program_of("BIOME", Path::new("biome"));

    Subprocess::of(
        "biome",
        program.clone(),
        &[
            "format",
            &format!("--stdin-file-path=input.{extension}"),
            "--indent-style=space",
            "--indent-width=4",
            "--line-width=88",
            "--javascript-formatter-quote-style=double",
            "--semicolons=always",
        ],
        "ts",
        Shape::Stream,
        &Version {
            arguments: &["--version"],
            pin: &tools.join("oracle-biome/PIN"),
            program: &program.to_string_lossy(),
        },
    )
    .ok()
    .map(|held| Box::new(held) as Box<dyn Reference>)
}

fn estree(tools: &Path, extension: &'static str) -> Option<Box<dyn Arbiter>> {
    scripted(
        "typescript-estree",
        tools.join("oracle-tsscope/accepts.mjs"),
        &tools.join("oracle-tsscope/PIN"),
        extension,
    )
}

fn odin(tools: &Path) -> Option<Box<dyn Arbiter>> {
    let program = tools.join("arbiter-odin/odin");
    let named = program.to_string_lossy().into_owned();

    Program::of(Setup {
        arguments: &["check", "-file", "-no-entry-point"],
        environment: &[],
        extension: "odin",
        identifier: "odin",
        program: program.clone(),
        reading: Reading::Syntax,
        version: Some(&Version {
            arguments: &["version"],
            pin: &tools.join("arbiter-odin/PIN"),
            program: &named,
        }),
    })
    .ok()
    .map(|held| Box::new(held) as Box<dyn Arbiter>)
}

fn postcss(tools: &Path) -> Option<Box<dyn Arbiter>> {
    scripted(
        "postcss",
        tools.join("oracle-css/accepts.mjs"),
        &tools.join("oracle-css/PIN"),
        "css",
    )
}

fn rust(corpus: &Path) -> Option<Box<dyn Arbiter>> {
    Program::of(Setup {
        arguments: &["--edition", "2024", "-Zparse-crate-root-only"],
        environment: &[("RUSTC_BOOTSTRAP", "1")],
        extension: "rs",
        identifier: "rustc",
        program: toolchain(corpus, "rustc")?,
        reading: Reading::Status,
        version: None,
    })
    .ok()
    .map(|held| Box::new(held) as Box<dyn Arbiter>)
}

fn scripted(
    identifier: &'static str,
    script: PathBuf,
    pin: &Path,
    extension: &'static str,
) -> Option<Box<dyn Arbiter>> {
    let script = script.to_string_lossy().into_owned();
    let program = program_of("NODE", Path::new("node"));
    let named = program.to_string_lossy().into_owned();

    Program::of(Setup {
        arguments: &[&script],
        environment: &[],
        extension,
        identifier,
        program: program.clone(),
        reading: Reading::Word,
        version: Some(&Version {
            arguments: &[&script, "--version"],
            pin,
            program: &named,
        }),
    })
    .ok()
    .map(|held| Box::new(held) as Box<dyn Arbiter>)
}

fn toolchain(corpus: &Path, name: &str) -> Option<PathBuf> {
    let mut held = std::fs::canonicalize(corpus.join("rust")).ok()?;

    while held.pop() {
        let found = held.join("bin").join(name);

        if found.is_file() {
            return Some(found);
        }
    }

    None
}

fn gofmt(tools: &Path) -> Option<Box<dyn Reference>> {
    Subprocess::of(
        "gofmt",
        program_of("GOFMT", Path::new("gofmt")),
        &[],
        "go",
        Shape::Stdout,
        &Version {
            arguments: &["version"],
            pin: &tools.join("oracle-gofmt/PIN"),
            program: "go",
        },
    )
    .ok()
    .map(|held| Box::new(held) as Box<dyn Reference>)
}

fn rustfmt(tools: &Path) -> Option<Box<dyn Reference>> {
    Subprocess::of(
        "rustfmt",
        program_of("RUSTFMT", Path::new("rustfmt")),
        &["--edition", "2024", "--emit", "stdout", "--quiet"],
        "rs",
        Shape::Stream,
        &Version {
            arguments: &["--version"],
            pin: &tools.join("oracle-rustfmt/PIN"),
            program: "rustfmt",
        },
    )
    .ok()
    .map(|held| Box::new(held) as Box<dyn Reference>)
}

fn zigfmt(tools: &Path) -> Option<Box<dyn Reference>> {
    let pin = tools.join("oracle-zigfmt/PIN");
    let program = zig_program(&pin);

    Subprocess::of(
        "zigfmt",
        PathBuf::from(&program),
        &["fmt"],
        "zig",
        Shape::InPlace,
        &Version {
            arguments: &["version"],
            pin: &pin,
            program: &program,
        },
    )
    .ok()
    .map(|held| Box::new(held) as Box<dyn Reference>)
}

fn zig_program(pin: &Path) -> String {
    if let Some(held) = std::env::var_os("ZIG") {
        return held.to_string_lossy().into_owned();
    }

    let Ok(version) = std::fs::read_to_string(pin) else {
        return "zig".to_owned();
    };

    let Some(home) = std::env::var_os("HOME") else {
        return "zig".to_owned();
    };

    let held = PathBuf::from(home)
        .join(".native/toolchains")
        .join(format!("zig-{}", version.trim()))
        .join("zig");

    if held.is_file() {
        return held.to_string_lossy().into_owned();
    }

    "zig".to_owned()
}

fn ruff_format(tools: &Path) -> Option<Box<dyn Reference>> {
    let pin = std::fs::read_to_string(tools.join("oracle-ruff-format/PIN")).ok()?;
    let pinned = format!("ruff@{}", pin.trim());

    Subprocess::of(
        "ruff-format",
        program_of("UVX", Path::new("uvx")),
        &[
            &pinned,
            "format",
            "--no-cache",
            "--isolated",
            "--stdin-filename",
            "input.py",
            "-",
        ],
        "py",
        Shape::Stream,
        &Version {
            arguments: &[&pinned, "--version"],
            pin: &tools.join("oracle-ruff-format/PIN"),
            program: "uvx",
        },
    )
    .ok()
    .map(|held| Box::new(held) as Box<dyn Reference>)
}

pub fn tools_of() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("the runner sits under tools/")
        .to_path_buf()
}

fn classify_ts(
    source: &[u8],
    tokens: &[Token],
    out: &mut Tokens,
    raw: &mut BoundedVec<TypeScriptKind>,
) -> bool {
    typescript_classify(source, tokens, out, raw, Dialect::Ts)
}

fn classify_tsx(
    source: &[u8],
    tokens: &[Token],
    out: &mut Tokens,
    raw: &mut BoundedVec<TypeScriptKind>,
) -> bool {
    typescript_classify(source, tokens, out, raw, Dialect::Tsx)
}

fn build_ts(
    source: &[u8],
    tokens: &[Token],
    raw: &[TypeScriptKind],
    events: &mut Events<TypeScriptKind>,
    tree: &mut Tree<TypeScriptKind>,
) -> Structure {
    typescript_parse::build(source, tokens, raw, events, tree, Dialect::Ts)
}

fn build_tsx(
    source: &[u8],
    tokens: &[Token],
    raw: &[TypeScriptKind],
    events: &mut Events<TypeScriptKind>,
    tree: &mut Tree<TypeScriptKind>,
) -> Structure {
    typescript_parse::build(source, tokens, raw, events, tree, Dialect::Tsx)
}
