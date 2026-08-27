use std::path::{Path, PathBuf};

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

use crate::analyzer::{Analyzer, Native};
use crate::binder;
use crate::format::{program_of, Reference, Shape, Subprocess};
use crate::normalize::{self, Normalizer};
use crate::oracle::{Batch, Oracle, Ruff, Syn, TreeSitter, Version};
use crate::printer;

pub struct Descriptor {
    pub analyzer: Box<dyn Analyzer>,
    pub extensions: &'static [&'static str],
    pub name: &'static str,
    pub normalizer: Option<&'static Normalizer>,
    pub oracle: Box<dyn Oracle>,
    pub reference: Option<Box<dyn Reference>>,
    pub regroups: bool,
}

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

pub fn descriptor_of(name: &str, tools: &Path) -> Result<Descriptor, String> {
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
            extensions: &["css"],
            name: "css",
            normalizer: Some(&normalize::CSS),
            oracle: Box::new(TreeSitter::of(
                "tree-sitter",
                &tree_sitter_css::LANGUAGE.into(),
            )?),
            reference: None,
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
            extensions: &["go"],
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
            extensions: &["cjs", "js", "mjs"],
            name: "javascript",
            normalizer: Some(&normalize::JAVASCRIPT),
            oracle: Box::new(TreeSitter::of(
                "tree-sitter",
                &tree_sitter_javascript::LANGUAGE.into(),
            )?),
            reference: None,
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
            extensions: &["odin"],
            name: "odin",
            normalizer: Some(&normalize::ODIN),
            oracle: Box::new(TreeSitter::of(
                "tree-sitter",
                &tree_sitter_odin::LANGUAGE.into(),
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
            extensions: &["py", "pyi"],
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
            extensions: &["rs"],
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
            extensions: &["tsx"],
            name: "tsx",
            normalizer: Some(&normalize::TYPESCRIPT),
            oracle: Box::new(TreeSitter::of(
                "tree-sitter",
                &tree_sitter_typescript::LANGUAGE_TSX.into(),
            )?),
            reference: None,
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
            extensions: &["cts", "mts", "ts"],
            name: "typescript",
            normalizer: Some(&normalize::TYPESCRIPT),
            oracle: Box::new(TreeSitter::of(
                "tree-sitter",
                &tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(),
            )?),
            reference: None,
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
            extensions: &["zig"],
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
        Shape::Stdout,
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
