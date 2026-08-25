use std::fs;
use std::path::{Path, PathBuf};

use tree_sitter::{Node, Parser};

struct Grammar {
    extensions: &'static [&'static str],
    identifier: &'static str,
    language: fn() -> tree_sitter::Language,
}

fn grammars() -> Vec<Grammar> {
    vec![
        Grammar {
            extensions: &["css"],
            identifier: "css",
            language: || tree_sitter_css::LANGUAGE.into(),
        },
        Grammar {
            extensions: &["cjs", "js", "mjs"],
            identifier: "javascript",
            language: || tree_sitter_javascript::LANGUAGE.into(),
        },
        Grammar {
            extensions: &["odin"],
            identifier: "odin",
            language: || tree_sitter_odin::LANGUAGE.into(),
        },
        Grammar {
            extensions: &["cts", "mts", "ts"],
            identifier: "typescript",
            language: || tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(),
        },
        Grammar {
            extensions: &["tsx"],
            identifier: "tsx",
            language: || tree_sitter_typescript::LANGUAGE_TSX.into(),
        },
    ]
}

fn escape(text: &str) -> String {
    let mut found = String::new();

    for held in text.chars() {
        match held {
            '"' => found.push_str("\\\""),
            '\\' => found.push_str("\\\\"),
            '\n' => found.push_str("\\n"),
            '\r' => found.push_str("\\r"),
            '\t' => found.push_str("\\t"),
            _ => found.push(held),
        }
    }

    found
}

fn walk(root: Node<'_>) -> (Vec<(String, usize, usize)>, bool) {
    let mut rows = Vec::new();
    let mut broken = false;
    let mut cursor = root.walk();
    let mut stack = vec![root];

    while let Some(node) = stack.pop() {
        if node.is_error() || node.is_missing() {
            broken = true;
        }

        if node.is_named() {
            rows.push((node.kind().to_owned(), node.start_byte(), node.end_byte()));
        }

        let children: Vec<Node<'_>> = node.named_children(&mut cursor).collect();

        for child in children.into_iter().rev() {
            stack.push(child);
        }
    }

    (rows, broken)
}

fn render(path: &str, rows: &[(String, usize, usize)], broken: bool) -> String {
    let mut text = String::from("{\"ast\":[");

    for (index, row) in rows.iter().enumerate() {
        if index > 0 {
            text.push(',');
        }

        text.push_str(&format!("[\"{}\",{},{}]", escape(&row.0), row.1, row.2));
    }

    text.push_str(&format!(
        "],\"broken\":{},\"path\":\"{}\"}}\n",
        broken,
        escape(path)
    ));

    text
}

fn sources(root: &Path, extensions: &[&str]) -> Vec<(String, PathBuf)> {
    let mut found = Vec::new();
    let mut stack = vec![root.to_path_buf()];

    while let Some(current) = stack.pop() {
        let Ok(entries) = fs::read_dir(&current) else {
            continue;
        };

        for entry in entries.flatten() {
            let path = entry.path();

            if path.is_dir() {
                stack.push(path);

                continue;
            }

            let Some(extension) = path.extension().and_then(|held| held.to_str()) else {
                continue;
            };

            if !extensions.contains(&extension) {
                continue;
            }

            let relative = path
                .strip_prefix(root)
                .unwrap_or(&path)
                .to_string_lossy()
                .replace('\\', "/");

            found.push((relative, path));
        }
    }

    found.sort();

    found
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let arguments: Vec<String> = std::env::args().collect();

    if arguments.len() != 4 {
        eprintln!("usage: oracle-treesitter <language> <source root> <destination root>");

        std::process::exit(2);
    }

    let held = grammars();

    let grammar = held
        .iter()
        .find(|entry| entry.identifier == arguments[1])
        .ok_or_else(|| format!("unknown language {}", arguments[1]))?;

    let root = PathBuf::from(&arguments[2]);
    let destination = PathBuf::from(&arguments[3]);
    let mut parser = Parser::new();

    parser.set_language(&(grammar.language)())?;

    let mut skipped = 0;

    for (relative, path) in sources(&root, grammar.extensions) {
        let Ok(source) = fs::read(&path) else {
            skipped += 1;

            continue;
        };

        let Some(tree) = parser.parse(&source, None) else {
            skipped += 1;

            continue;
        };

        let (rows, broken) = walk(tree.root_node());
        let target = destination.join(format!("{relative}.json"));

        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }

        fs::write(&target, render(&relative, &rows, broken))?;
    }

    if skipped > 0 {
        eprintln!("skipped {skipped} files");
    }

    Ok(())
}
