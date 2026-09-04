use std::fs;

use oracle_treesitter::grammars;
use tree_sitter::{Node, Parser};

const REACH: usize = 48;

fn faults(root: Node<'_>) -> Vec<(String, usize, usize)> {
    let mut cursor = root.walk();
    let mut found = Vec::new();
    let mut stack = vec![root];

    while let Some(node) = stack.pop() {
        if node.is_error() {
            found.push((String::from("ERROR"), node.start_byte(), node.end_byte()));
        }

        if node.is_missing() {
            found.push((
                format!("MISSING {}", node.kind()),
                node.start_byte(),
                node.end_byte(),
            ));
        }

        let children: Vec<Node<'_>> = node.children(&mut cursor).collect();

        for child in children.into_iter().rev() {
            stack.push(child);
        }
    }

    found.sort_by_key(|held| held.1);

    found
}

fn excerpt(source: &[u8], start: usize, end: usize) -> String {
    let from = start.saturating_sub(REACH);
    let to = end.saturating_add(REACH).min(source.len());
    let text = String::from_utf8_lossy(&source[from..to]);

    text.replace('\n', "\\n").replace('\t', "\\t")
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let arguments: Vec<String> = std::env::args().collect();

    if arguments.len() < 3 {
        eprintln!("usage: errors <language> <file>...");

        std::process::exit(2);
    }

    let held = grammars();

    let grammar = held
        .iter()
        .find(|entry| entry.identifier == arguments[1])
        .ok_or_else(|| format!("unknown language {}", arguments[1]))?;

    let mut parser = Parser::new();

    parser.set_language(&(grammar.language)())?;

    for path in &arguments[2..] {
        let source = fs::read(path)?;

        let Some(tree) = parser.parse(&source, None) else {
            println!("{path}: the parser returned nothing");

            continue;
        };

        let found = faults(tree.root_node());

        if found.is_empty() {
            println!("{path}: clean");

            continue;
        }

        println!("{path}: {} faults", found.len());

        for (kind, start, end) in found.iter().take(3) {
            println!("  {kind} at {start}..{end}: {}", excerpt(&source, *start, *end));
        }
    }

    Ok(())
}
