use tree_sitter::Language;

fn main() {
    let arguments: Vec<String> = std::env::args().collect();

    let language: Language = match arguments[1].as_str() {
        "css" => tree_sitter_css::LANGUAGE.into(),
        "javascript" => tree_sitter_javascript::LANGUAGE.into(),
        "odin" => tree_sitter_odin::LANGUAGE.into(),
        _ => panic!("unknown"),
    };

    let mut found: Vec<&str> = Vec::new();

    for id in 0..language.node_kind_count() {
        let id = id as u16;

        if !language.node_kind_is_named(id) {
            continue;
        }

        let name = language.node_kind_for_id(id).unwrap();

        if !found.contains(&name) {
            found.push(name);
        }
    }

    found.sort();

    for name in found {
        println!("{name}");
    }
}
