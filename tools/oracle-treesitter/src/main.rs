use std::fs;
use std::path::PathBuf;

use oracle_treesitter::{grammars, render, sources, walk};
use tree_sitter::Parser;

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

        let (rows, broken) = walk(tree.root_node(), &source, &grammar.correction);
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
