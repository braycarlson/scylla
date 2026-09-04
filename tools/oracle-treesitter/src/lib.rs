use std::fs;
use std::path::{Path, PathBuf};

use tree_sitter::Node;

pub enum Correction {
    None,
    Odin,
    TypeScript,
}

pub struct Grammar {
    pub correction: Correction,
    pub extensions: &'static [&'static str],
    pub identifier: &'static str,
    pub language: fn() -> tree_sitter::Language,
}

struct Item {
    children: Vec<usize>,
    end: usize,
    kind: String,
    operator: String,
    start: usize,
}

struct Turn {
    hinge: usize,
    leading: bool,
}

pub fn grammars() -> Vec<Grammar> {
    vec![
        Grammar {
            correction: Correction::None,
            extensions: &["css"],
            identifier: "css",
            language: || tree_sitter_css::LANGUAGE.into(),
        },
        Grammar {
            correction: Correction::None,
            extensions: &["cjs", "js", "mjs"],
            identifier: "javascript",
            language: || tree_sitter_javascript::LANGUAGE.into(),
        },
        Grammar {
            correction: Correction::Odin,
            extensions: &["odin"],
            identifier: "odin",
            language: || tree_sitter_odin::LANGUAGE.into(),
        },
        Grammar {
            correction: Correction::TypeScript,
            extensions: &["cts", "mts", "ts"],
            identifier: "typescript",
            language: || tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(),
        },
        Grammar {
            correction: Correction::TypeScript,
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

fn build(root: Node<'_>) -> (Vec<Item>, bool) {
    let mut arena: Vec<Item> = Vec::new();
    let mut broken = false;
    let mut cursor = root.walk();
    let mut stack = vec![(root, usize::MAX)];

    while let Some((node, parent)) = stack.pop() {
        if node.is_error() || node.is_missing() {
            broken = true;
        }

        let index = arena.len();

        let operator = node
            .child_by_field_name("operator")
            .map(|held| held.kind().to_owned())
            .unwrap_or_default();

        arena.push(Item {
            children: Vec::new(),
            end: node.end_byte(),
            kind: node.kind().to_owned(),
            operator,
            start: node.start_byte(),
        });

        if parent != usize::MAX {
            arena[parent].children.push(index);
        }

        let children: Vec<Node<'_>> = node.named_children(&mut cursor).collect();

        for child in children.into_iter().rev() {
            stack.push((child, index));
        }
    }

    (arena, broken)
}

fn assertion(kind: &str) -> bool {
    matches!(kind, "as_expression" | "satisfies_expression")
}

const POWER_RELATIONAL: u8 = 11;

fn power(operator: &str) -> u8 {
    match operator {
        "??" => 4,
        "||" => 5,
        "&&" => 6,
        "|" => 7,
        "^" => 8,
        "&" => 9,
        "!=" | "!==" | "==" | "===" => 10,
        "<" | "<=" | ">" | ">=" | "in" | "instanceof" => POWER_RELATIONAL,
        "<<" | ">>" | ">>>" => 12,
        "+" | "-" => 13,
        "%" | "*" | "/" => 14,
        "**" => 15,
        _ => 0,
    }
}

fn postfix(kind: &str) -> bool {
    matches!(
        kind,
        "call_expression" | "member_expression" | "non_null_expression" | "subscript_expression"
    )
}

fn prefix(kind: &str) -> bool {
    matches!(
        kind,
        "await_expression" | "type_assertion" | "unary_expression" | "update_expression"
    )
}

fn typescript(outer: &Item, inner: &Item) -> Option<Turn> {
    if postfix(&outer.kind) && prefix(&inner.kind) {
        return Some(Turn {
            hinge: inner.children.len().checked_sub(1)?,
            leading: false,
        });
    }

    if postfix(&outer.kind) && inner.kind == "binary_expression" {
        return Some(Turn {
            hinge: 1,
            leading: false,
        });
    }

    if outer.kind == "await_expression" && assertion(&inner.kind) {
        return Some(Turn {
            hinge: 0,
            leading: true,
        });
    }

    let below = power(&inner.operator);

    if assertion(&outer.kind)
        && inner.kind == "binary_expression"
        && below > 0
        && below < POWER_RELATIONAL
    {
        return Some(Turn {
            hinge: 1,
            leading: false,
        });
    }

    let above = power(&outer.operator);

    if outer.kind == "binary_expression"
        && inner.kind == "binary_expression"
        && below > 0
        && above > 0
        && below < above
    {
        return Some(Turn {
            hinge: 1,
            leading: false,
        });
    }

    None
}

fn resources(arena: &mut Vec<Item>, source: &[u8]) {
    for index in 0..arena.len() {
        if arena[index].kind != "expression_statement" || arena[index].children.len() != 1 {
            continue;
        }

        let mut held = arena[index].children[0];

        if arena[held].kind == "await_expression" && arena[held].children.len() == 1 {
            held = arena[held].children[0];
        }

        let carried = if arena[held].kind == "sequence_expression" {
            arena[held].children.clone()
        } else {
            vec![held]
        };

        let Some(&first) = carried.first() else {
            continue;
        };

        if !declared(arena, first, source) {
            continue;
        }

        let bound = carried.iter().all(|&at| {
            arena[at].kind == "assignment_expression" && arena[at].children.len() == 2
        });

        if !bound {
            continue;
        }

        for &at in &carried {
            arena[at].kind = String::from("variable_declarator");
            arena[at].operator = String::new();
            arena[at].start = arena[arena[at].children[0]].start;
        }

        arena[index].kind = String::from("lexical_declaration");
        arena[index].children = carried;
    }
}

fn declared(arena: &[Item], index: usize, source: &[u8]) -> bool {
    if arena[index].kind != "assignment_expression" || arena[index].children.len() != 2 {
        return false;
    }

    let name = arena[index].children[0];
    let head = &source[arena[index].start..arena[name].start];

    head.starts_with(b"using") && head[5..].iter().all(u8::is_ascii_whitespace)
}

fn annotations(arena: &mut Vec<Item>) {
    for index in 0..arena.len() {
        let children = arena[index].children.clone();
        let mut kept = Vec::with_capacity(children.len());
        let mut at = 0;

        while at < children.len() {
            let child = children[at];

            kept.push(child);

            at += 1;

            let Some(&next) = children.get(at) else {
                continue;
            };

            let Some(annotation) = annotated(arena, child) else {
                continue;
            };

            let Some((held, pattern, value)) = destructured(arena, next) else {
                continue;
            };

            if arena[annotation].end != arena[pattern].start {
                continue;
            }

            let typed = arena[annotation].children[0];

            if !imported(arena, typed) {
                continue;
            }

            let reach = arena[pattern].end;

            arena.push(Item {
                children: vec![typed],
                end: reach,
                kind: String::from("array_type"),
                operator: String::new(),
                start: arena[typed].start,
            });

            let grown = arena.len() - 1;
            let declarator = arena[child].children[arena[child].children.len() - 1];

            arena[annotation].children = vec![grown];
            arena[annotation].end = reach;

            arena[declarator].children.push(value);
            arena[declarator].end = arena[held].end;

            arena[child].end = arena[next].end;

            at += 1;
        }

        arena[index].children = kept;
    }
}

fn annotated(arena: &[Item], index: usize) -> Option<usize> {
    if !matches!(
        arena[index].kind.as_str(),
        "lexical_declaration" | "variable_declaration"
    ) {
        return None;
    }

    let &declarator = arena[index].children.last()?;

    if arena[declarator].kind != "variable_declarator" || arena[declarator].end != arena[index].end {
        return None;
    }

    let &annotation = arena[declarator].children.last()?;

    if arena[annotation].kind != "type_annotation"
        || arena[annotation].end != arena[declarator].end
        || arena[annotation].children.len() != 1
    {
        return None;
    }

    Some(annotation)
}

fn destructured(arena: &[Item], index: usize) -> Option<(usize, usize, usize)> {
    if arena[index].kind != "expression_statement" || arena[index].children.len() != 1 {
        return None;
    }

    let held = arena[index].children[0];

    if arena[held].kind != "assignment_expression" || arena[held].children.len() != 2 {
        return None;
    }

    let pattern = arena[held].children[0];
    let value = arena[held].children[1];

    if arena[pattern].kind != "array_pattern" || !arena[pattern].children.is_empty() {
        return None;
    }

    Some((held, pattern, value))
}

fn imported(arena: &[Item], index: usize) -> bool {
    let mut held = index;

    for _ in 0..arena.len() {
        match arena[held].kind.as_str() {
            "call_expression" | "member_expression" => {}
            "import" => return true,
            _ => return false,
        }

        let Some(&first) = arena[held].children.first() else {
            return false;
        };

        held = first;
    }

    false
}

fn queries(arena: &mut Vec<Item>, source: &[u8]) {
    for index in 0..arena.len() {
        if arena[index].kind != "binary_expression"
            || arena[index].operator != ">"
            || arena[index].children.len() != 2
        {
            continue;
        }

        let held = arena[index].children[0];

        if arena[held].kind != "binary_expression"
            || arena[held].operator != "<"
            || arena[held].children.len() != 2
        {
            continue;
        }

        let mut spine = Vec::new();
        let mut group = arena[index].children[1];

        for _ in 0..arena.len() {
            if arena[group].kind == "parenthesized_expression" {
                break;
            }

            if !matches!(
                arena[group].kind.as_str(),
                "call_expression" | "member_expression" | "subscript_expression"
            ) {
                break;
            }

            let Some(&first) = arena[group].children.first() else {
                break;
            };

            spine.push(group);

            group = first;
        }

        if arena[group].kind != "parenthesized_expression" {
            continue;
        }

        let callee = arena[held].children[0];
        let named = arena[held].children[1];

        if arena[named].kind != "unary_expression" || arena[named].operator != "typeof" {
            continue;
        }

        let Some(open) = (arena[callee].end..arena[named].start).find(|&at| source[at] == b'<')
        else {
            continue;
        };

        let Some(close) = (arena[named].end..arena[group].start).find(|&at| source[at] == b'>')
        else {
            continue;
        };

        arena[named].kind = String::from("type_query");

        arena.push(Item {
            children: vec![named],
            end: close + 1,
            kind: String::from("type_arguments"),
            operator: String::new(),
            start: open,
        });

        let typed = arena.len() - 1;
        let carried = arena[group].children.clone();

        let listed = match carried.first() {
            Some(&only) if arena[only].kind == "sequence_expression" => {
                arena[only].children.clone()
            }
            Some(_) | None => carried,
        };

        arena[group].kind = String::from("arguments");
        arena[group].children = listed;

        let Some(&outer) = spine.first() else {
            arena[index].kind = String::from("call_expression");
            arena[index].operator = String::new();
            arena[index].children = vec![callee, typed, group];

            continue;
        };

        let reach = arena[callee].start;

        arena.push(Item {
            children: vec![callee, typed, group],
            end: arena[group].end,
            kind: String::from("call_expression"),
            operator: String::new(),
            start: reach,
        });

        let built = arena.len() - 1;
        let inner = spine[spine.len() - 1];

        arena[inner].children[0] = built;

        for &node in &spine[1..] {
            arena[node].start = reach;
        }

        arena[index].kind = arena[outer].kind.clone();
        arena[index].operator = String::new();
        arena[index].children = arena[outer].children.clone();
    }
}

fn assertions(arena: &mut Vec<Item>) {
    for index in (0..arena.len()).rev() {
        if arena[index].kind != "member_expression" || arena[index].children.len() != 2 {
            continue;
        }

        let held = arena[index].children[0];
        let property = arena[index].children[1];

        if !assertion(&arena[held].kind) || arena[property].kind != "property_identifier" {
            continue;
        }

        let Some(&last) = arena[held].children.last() else {
            continue;
        };

        let mut named = last;
        let mut spine = vec![held];

        for _ in 0..arena.len() {
            if arena[named].kind != "union_type" {
                break;
            }

            let Some(&inner) = arena[named].children.last() else {
                break;
            };

            spine.push(named);

            named = inner;
        }

        if !matches!(
            arena[named].kind.as_str(),
            "nested_type_identifier" | "type_identifier"
        ) {
            continue;
        }

        let reach = arena[index].end;

        arena.push(Item {
            children: vec![named, property],
            end: reach,
            kind: String::from("nested_type_identifier"),
            operator: String::new(),
            start: arena[named].start,
        });

        let grown = arena.len() - 1;
        let owner = spine[spine.len() - 1];
        let last = arena[owner].children.len() - 1;

        arena[owner].children[last] = grown;

        for &node in &spine {
            arena[node].end = reach;
        }

        arena[index].kind = arena[held].kind.clone();
        arena[index].children = arena[held].children.clone();

        qualify(arena, grown);
    }

    unions(arena);
    lookups(arena);
    generics(arena);
}

fn generics(arena: &mut Vec<Item>) {
    for index in (0..arena.len()).rev() {
        if arena[index].kind != "instantiation_expression" || arena[index].children.len() != 2 {
            continue;
        }

        let held = arena[index].children[0];
        let arguments = arena[index].children[1];

        if !assertion(&arena[held].kind)
            || arena[held].children.len() < 2
            || arena[arguments].kind != "type_arguments"
        {
            continue;
        }

        let mut named = arena[held].children[arena[held].children.len() - 1];
        let mut spine = vec![held];

        for _ in 0..arena.len() {
            if arena[named].kind != "union_type" {
                break;
            }

            let Some(&inner) = arena[named].children.last() else {
                break;
            };

            spine.push(named);

            named = inner;
        }

        let reach = arena[index].end;

        arena.push(Item {
            children: vec![named, arguments],
            end: reach,
            kind: String::from("generic_type"),
            operator: String::new(),
            start: arena[named].start,
        });

        let grown = arena.len() - 1;
        let owner = spine[spine.len() - 1];
        let last = arena[owner].children.len() - 1;

        arena[owner].children[last] = grown;

        for &node in &spine {
            arena[node].end = reach;
        }

        arena[index].kind = arena[held].kind.clone();
        arena[index].children = arena[held].children.clone();
    }
}

fn lookups(arena: &mut Vec<Item>) {
    for index in (0..arena.len()).rev() {
        if arena[index].kind != "subscript_expression" || arena[index].children.len() != 2 {
            continue;
        }

        let held = arena[index].children[0];
        let key = arena[index].children[1];

        if !assertion(&arena[held].kind) || arena[held].children.len() < 2 {
            continue;
        }

        let mut named = arena[held].children[arena[held].children.len() - 1];
        let mut spine = vec![held];

        for _ in 0..arena.len() {
            if arena[named].kind != "union_type" {
                break;
            }

            let Some(&inner) = arena[named].children.last() else {
                break;
            };

            spine.push(named);

            named = inner;
        }

        let reach = arena[index].end;

        arena.push(Item {
            children: vec![key],
            end: arena[key].end,
            kind: String::from("literal_type"),
            operator: String::new(),
            start: arena[key].start,
        });

        let literal = arena.len() - 1;

        arena.push(Item {
            children: vec![named, literal],
            end: reach,
            kind: String::from("lookup_type"),
            operator: String::new(),
            start: arena[named].start,
        });

        let grown = arena.len() - 1;
        let owner = spine[spine.len() - 1];
        let last = arena[owner].children.len() - 1;

        arena[owner].children[last] = grown;

        for &node in &spine {
            arena[node].end = reach;
        }

        arena[index].kind = arena[held].kind.clone();
        arena[index].children = arena[held].children.clone();
    }
}

fn unions(arena: &mut Vec<Item>) {
    for index in (0..arena.len()).rev() {
        if arena[index].kind != "binary_expression"
            || arena[index].operator != "|"
            || arena[index].children.len() != 2
        {
            continue;
        }

        let held = arena[index].children[0];
        let member = arena[index].children[1];

        if !assertion(&arena[held].kind) || arena[held].children.len() < 2 {
            continue;
        }

        let named = arena[held].children[arena[held].children.len() - 1];

        let held_member = if matches!(
            arena[member].kind.as_str(),
            "false" | "null" | "number" | "string" | "true" | "undefined"
        ) {
            arena.push(Item {
                children: vec![member],
                end: arena[member].end,
                kind: String::from("literal_type"),
                operator: String::new(),
                start: arena[member].start,
            });

            arena.len() - 1
        } else {
            member
        };

        arena.push(Item {
            children: vec![named, held_member],
            end: arena[index].end,
            kind: String::from("union_type"),
            operator: String::new(),
            start: arena[named].start,
        });

        let grown = arena.len() - 1;
        let mut carried = arena[held].children.clone();
        let last = carried.len() - 1;

        carried[last] = grown;

        arena[index].kind = arena[held].kind.clone();
        arena[index].operator = String::new();
        arena[index].children = carried;
    }
}

fn qualify(arena: &mut [Item], index: usize) {
    let mut held = index;
    let mut depth = 0;

    for _ in 0..arena.len() {
        arena[held].kind = String::from(match depth {
            0 => "nested_type_identifier",
            1 => "nested_identifier",
            _ => "member_expression",
        });

        if arena[held].children.len() != 2 {
            return;
        }

        let first = arena[held].children[0];
        let last = arena[held].children[1];

        arena[last].kind = String::from(if depth == 0 {
            "type_identifier"
        } else {
            "property_identifier"
        });

        if !matches!(
            arena[first].kind.as_str(),
            "member_expression" | "nested_identifier" | "nested_type_identifier"
        ) {
            return;
        }

        held = first;
        depth += 1;
    }
}

fn rotate(
    arena: &mut [Item],
    index: usize,
    turn: fn(&Item, &Item) -> Option<Turn>,
) -> Option<usize> {
    let child = *arena[index].children.first()?;
    let held = turn(&arena[index], &arena[child])?;
    let hinge = *arena[child].children.get(held.hinge)?;
    let start = arena[index].start;
    let end = arena[index].end;
    let kind = arena[index].kind.clone();
    let operator = arena[index].operator.clone();
    let trailing: Vec<usize> = arena[index].children[1..].to_vec();

    let (sunk_start, sunk_end) = if held.leading {
        (start, arena[hinge].end)
    } else {
        (arena[hinge].start, end)
    };

    let mut risen: Vec<usize> = arena[child].children.clone();

    risen[held.hinge] = child;

    arena[index].kind = arena[child].kind.clone();
    arena[index].operator = arena[child].operator.clone();
    arena[index].children = risen;

    arena[child].kind = kind;
    arena[child].operator = operator;
    arena[child].start = sunk_start;
    arena[child].end = sunk_end;
    arena[child].children = core::iter::once(hinge).chain(trailing).collect();

    Some(child)
}

fn parameters(arena: &mut Vec<Item>) {
    let mut index = 0;

    while index < arena.len() {
        if arena[index].kind != "parameters" {
            index += 1;

            continue;
        }

        let children = arena[index].children.clone();
        let mut rebuilt = Vec::with_capacity(children.len());

        for child in children {
            if !anonymous(arena, child) {
                rebuilt.push(child);

                continue;
            }

            for (place, item) in arena[child].children.clone().into_iter().enumerate() {
                let start = arena[item].start;
                let end = arena[item].end;
                let typed = arena.len();

                arena.push(Item {
                    children: vec![item],
                    end,
                    kind: String::from("type"),
                    operator: String::new(),
                    start,
                });

                if place == 0 {
                    arena[child].children = vec![typed];
                    arena[child].start = start;
                    arena[child].end = end;
                    rebuilt.push(child);

                    continue;
                }

                rebuilt.push(arena.len());

                arena.push(Item {
                    children: vec![typed],
                    end,
                    kind: String::from("parameter"),
                    operator: String::new(),
                    start,
                });
            }
        }

        arena[index].children = rebuilt;
        index += 1;
    }
}

fn dereferences(arena: &mut Vec<Item>, source: &[u8]) {
    for index in 0..arena.len() {
        if arena[index].kind != "update_statement" || arena[index].children.len() != 2 {
            continue;
        }

        let held = arena[index].children[0];
        let value = arena[index].children[1];
        let mut at = arena[held].end;

        while at < arena[value].start && source[at].is_ascii_whitespace() {
            at += 1;
        }

        if source.get(at..at + 2) != Some(b"^=".as_slice()) {
            continue;
        }

        arena.push(Item {
            children: vec![held],
            end: at + 1,
            kind: String::from("address"),
            operator: String::new(),
            start: arena[held].start,
        });

        let grown = arena.len() - 1;

        arena[index].kind = String::from("assignment_statement");
        arena[index].operator = String::new();
        arena[index].children = vec![grown, value];
    }
}

fn blank(source: &[u8], from: usize, to: usize) -> usize {
    let mut at = from;

    while at < to && source[at].is_ascii_whitespace() {
        at += 1;
    }

    at
}

fn closures(arena: &mut Vec<Item>, source: &[u8]) {
    for index in 0..arena.len() {
        if arena[index].kind != "struct" || arena[index].children.len() != 1 {
            continue;
        }

        let held = arena[index].children[0];

        if arena[held].kind != "identifier"
            || &source[arena[held].start..arena[held].end] != b"proc"
        {
            continue;
        }

        let Some((open, close, brace, shut)) =
            emptied(source, arena[held].end, arena[index].end)
        else {
            continue;
        };

        arena.push(Item {
            children: Vec::new(),
            end: close + 1,
            kind: String::from("parameters"),
            operator: String::new(),
            start: open,
        });

        let listed = arena.len() - 1;

        arena.push(Item {
            children: Vec::new(),
            end: shut + 1,
            kind: String::from("block"),
            operator: String::new(),
            start: brace,
        });

        let body = arena.len() - 1;

        arena[index].kind = String::from("procedure");
        arena[index].children = vec![listed, body];
    }
}

fn emptied(source: &[u8], from: usize, to: usize) -> Option<(usize, usize, usize, usize)> {
    let open = blank(source, from, to);
    let close = blank(source, open.checked_add(1)?, to);
    let brace = blank(source, close.checked_add(1)?, to);
    let shut = blank(source, brace.checked_add(1)?, to);

    let held = source.get(open) == Some(&b'(')
        && source.get(close) == Some(&b')')
        && source.get(brace) == Some(&b'{')
        && source.get(shut) == Some(&b'}')
        && shut + 1 == to;

    held.then_some((open, close, brace, shut))
}

fn records(arena: &mut Vec<Item>, source: &[u8]) {
    for index in 0..arena.len() {
        let end = arena[index].end;
        let start = arena[index].start;

        if arena[index].kind != "struct_type" || end < start + 2 {
            continue;
        }

        if source.get(end - 2..end) != Some(b"{}".as_slice()) {
            continue;
        }

        let shut = back(source, start, end - 2);

        if shut == start || source.get(shut - 1) != Some(&b'}') {
            continue;
        }

        let carried = core::mem::take(&mut arena[index].children);

        arena.push(Item {
            children: carried,
            end: shut,
            kind: String::from("struct_type"),
            operator: String::new(),
            start,
        });

        let grown = arena.len() - 1;

        arena[index].kind = String::from("struct");
        arena[index].children = vec![grown];
    }
}

fn composites(arena: &mut Vec<Item>, source: &[u8]) {
    for index in 0..arena.len() {
        if arena[index].kind != "cast_expression" || arena[index].children.len() != 2 {
            continue;
        }

        let typed = arena[index].children[0];
        let body = arena[index].children[1];

        if arena[body].kind != "struct"
            || arena[body].end != arena[index].end
            || source.get(arena[index].start) != Some(&b'(')
            || source.get(arena[body].start) != Some(&b'{')
        {
            continue;
        }

        let close = back(source, arena[typed].end, arena[body].start);

        if close == arena[typed].end || source.get(close - 1) != Some(&b')') {
            continue;
        }

        arena.push(Item {
            children: vec![typed],
            end: close,
            kind: String::from("cast_expression"),
            operator: String::new(),
            start: arena[index].start,
        });

        let grown = arena.len() - 1;

        arena[index].kind = String::from("struct");
        arena[index].children = vec![grown];
    }
}

fn selections(arena: &mut Vec<Item>, source: &[u8]) {
    for index in 0..arena.len() {
        let children = arena[index].children.clone();
        let mut kept = Vec::with_capacity(children.len());
        let mut at = 0;

        while at < children.len() {
            let held = children[at];

            at += 1;

            let joined = children.get(at).is_some_and(|&next| {
                arena[held].kind == "tag"
                    && arena[next].kind == "member_expression"
                    && arena[next].start == arena[held].end
                    && source.get(arena[next].start) == Some(&b'.')
            });

            if !joined {
                kept.push(held);

                continue;
            }

            let next = children[at];
            let mut carried = vec![held];

            carried.append(&mut arena[next].children);

            arena[next].start = arena[held].start;
            arena[next].children = carried;

            kept.push(next);

            at += 1;
        }

        arena[index].children = kept;
    }
}

fn selectors(arena: &mut [Item]) {
    for index in 0..arena.len() {
        if !asserts(arena, index) {
            continue;
        }

        let left = arena[index].children[0];
        let right = arena[index].children[1];
        let carried = core::mem::take(&mut arena[right].children);
        let typed = carried[0];

        arena[right].kind =
            core::mem::replace(&mut arena[index].kind, String::from("call_expression"));
        arena[right].start = arena[index].start;
        arena[right].end = arena[typed].end;
        arena[right].children = vec![left, typed];

        let mut rebuilt = vec![right];

        rebuilt.extend_from_slice(&carried[1..]);

        arena[index].children = rebuilt;
    }
}

fn asserts(arena: &[Item], index: usize) -> bool {
    if arena[index].kind != "member_expression" || arena[index].children.len() != 2 {
        return false;
    }

    let right = arena[index].children[1];

    if arena[right].kind != "call_expression" {
        return false;
    }

    arena[right]
        .children
        .first()
        .is_some_and(|&first| arena[first].kind == "cast_expression")
}

fn back(source: &[u8], from: usize, to: usize) -> usize {
    let mut at = to;

    while at > from && source[at - 1].is_ascii_whitespace() {
        at -= 1;
    }

    at
}

fn returns(arena: &mut Vec<Item>, source: &[u8]) {
    for index in 0..arena.len() {
        if arena[index].kind != "binary_expression" || arena[index].children.len() != 2 {
            continue;
        }

        let held = arena[index].children[0];
        let value = arena[index].children[1];

        if arena[held].kind != "identifier"
            || &source[arena[held].start..arena[held].end] != b"return"
        {
            continue;
        }

        let sign = blank(source, arena[held].end, arena[value].start);

        if !matches!(source.get(sign), Some(b'!' | b'&' | b'+' | b'-' | b'~'))
            || blank(source, sign + 1, arena[value].start) != arena[value].start
        {
            continue;
        }

        arena.push(Item {
            children: vec![value],
            end: arena[value].end,
            kind: String::from("unary_expression"),
            operator: String::new(),
            start: sign,
        });

        let grown = arena.len() - 1;

        arena[index].kind = String::from("return_statement");
        arena[index].operator = String::new();
        arena[index].children = vec![grown];
    }
}

fn spaced(arena: &mut Vec<Item>, source: &[u8]) {
    for index in 0..arena.len() {
        let children = arena[index].children.clone();
        let mut kept = Vec::with_capacity(children.len());
        let mut at = 0;

        while at < children.len() {
            let held = children[at];

            at += 1;

            let Some(&next) = children.get(at) else {
                kept.push(held);

                continue;
            };

            if !parenthesized(arena, held, next, source) {
                kept.push(held);

                continue;
            }

            let reach = arena[next].end;
            let listed = if arena[next].kind == "call_expression"
                && arena[next].start == blank(source, arena[held].end, reach)
            {
                arena[next].children.clone()
            } else {
                shed(arena, next, reach);

                vec![next]
            };

            let mut carried = vec![held];

            carried.extend(listed);

            arena.push(Item {
                children: carried,
                end: reach,
                kind: String::from("call_expression"),
                operator: String::new(),
                start: arena[held].start,
            });

            kept.push(arena.len() - 1);

            at += 1;
        }

        arena[index].children = kept;
    }
}

fn parenthesized(arena: &[Item], held: usize, next: usize, source: &[u8]) -> bool {
    if arena[held].kind != "tag" || arena[next].end == 0 {
        return false;
    }

    let open = blank(source, arena[held].end, arena[next].start);

    open > arena[held].end
        && open == arena[next].start
        && source.get(open) == Some(&b'(')
        && source.get(arena[next].end - 1) == Some(&b')')
}

fn shed(arena: &mut [Item], index: usize, reach: usize) {
    let Some(&last) = arena[index].children.last() else {
        return;
    };

    if arena[last].kind == "call_expression" && arena[last].end == reach {
        let listed = arena[last].children.clone();
        let mut carried = arena[index].children.clone();

        carried.pop();
        carried.extend(listed);

        arena[index].children = carried;
    }

    let Some(&first) = arena[index].children.first() else {
        return;
    };

    let Some(&last) = arena[index].children.last() else {
        return;
    };

    arena[index].start = arena[first].start;
    arena[index].end = arena[last].end;
}

fn elements(arena: &mut [Item], source: &[u8]) {
    for index in 0..arena.len() {
        if arena[index].kind != "polymorphic_type" || arena[index].children.len() < 2 {
            continue;
        }

        let at = usize::from(arena[arena[index].children[0]].kind == "tag");

        let Some(&outer) = arena[index].children.get(at) else {
            continue;
        };

        if arena[outer].kind != "type"
            || arena[outer].children.len() != 1
            || arena[outer].start != arena[index].start
        {
            continue;
        }

        let arrayed = arena[outer].children[0];

        if arena[arrayed].kind != "array_type"
            || arena[arrayed].end != arena[outer].end
            || arena[arrayed].children.len() < 2
            || source.get(arena[outer].end) != Some(&b'(')
        {
            continue;
        }

        let mut listed = arena[arrayed].children.clone();
        let element = listed.pop().unwrap_or(arrayed);
        let reach = arena[index].end;
        let start = arena[element].start;
        let mut carried: Vec<usize> = arena[index].children[..at].to_vec();

        carried.push(element);
        carried.extend_from_slice(&arena[index].children[at + 1..]);

        arena[arrayed].kind = String::from("polymorphic_type");
        arena[arrayed].start = start;
        arena[arrayed].end = reach;
        arena[arrayed].children = carried;

        arena[outer].start = start;
        arena[outer].end = reach;
        arena[outer].children = vec![arrayed];

        listed.push(outer);

        arena[index].kind = String::from("array_type");
        arena[index].children = listed;
    }
}

fn counted(arena: &mut Vec<Item>, source: &[u8]) {
    for index in 0..arena.len() {
        if arena[index].kind != "binary_expression" {
            continue;
        }

        let Some(&child) = arena[index].children.last() else {
            continue;
        };

        if arena[child].kind != "number" || arena[child].start == 0 {
            continue;
        }

        if source.get(arena[child].start - 1) != Some(&b'[')
            || source.get(arena[child].end) != Some(&b']')
        {
            continue;
        }

        let from = arena[child].end + 1;
        let reach = spelled(source, from);

        if reach == from || reach != arena[index].end {
            continue;
        }

        arena.push(Item {
            children: Vec::new(),
            end: reach,
            kind: String::from("identifier"),
            operator: String::new(),
            start: from,
        });

        let named = arena.len() - 1;

        arena.push(Item {
            children: vec![named],
            end: reach,
            kind: String::from("type"),
            operator: String::new(),
            start: from,
        });

        let typed = arena.len() - 1;

        arena.push(Item {
            children: vec![child, typed],
            end: reach,
            kind: String::from("array_type"),
            operator: String::new(),
            start: arena[child].start - 1,
        });

        let grown = arena.len() - 1;
        let last = arena[index].children.len() - 1;

        arena[index].children[last] = grown;
    }
}

fn spelled(source: &[u8], from: usize) -> usize {
    let mut at = from;

    while source
        .get(at)
        .is_some_and(|byte| byte.is_ascii_alphanumeric() || *byte == b'_')
    {
        at += 1;
    }

    at
}

fn sparse(arena: &mut [Item], source: &[u8]) {
    for index in 0..arena.len() {
        let children = arena[index].children.clone();
        let mut kept = Vec::with_capacity(children.len());
        let mut at = 0;

        while at < children.len() {
            let held = children[at];

            at += 1;

            let Some(&next) = children.get(at) else {
                kept.push(held);

                continue;
            };

            let carrier = if arena[held].kind == "index_expression" {
                held
            } else {
                match arena[held].children.last() {
                    Some(&last) if arena[last].end == arena[held].end => last,
                    Some(_) | None => {
                        kept.push(held);

                        continue;
                    }
                }
            };

            let Some((tag, keyed, open)) = keyword(arena, carrier, next, source) else {
                kept.push(held);

                continue;
            };

            let Some(&element) = arena[next].children.first() else {
                kept.push(held);

                continue;
            };

            let mut listed = arena[next].children.clone();
            let rest = listed.split_off(1);
            let reach = arena[next].end;

            arena[next].kind = String::from("type");
            arena[next].start = arena[element].start;
            arena[next].end = arena[element].end;
            arena[next].children = vec![element];

            let mut carried = vec![keyed, next];

            carried.extend(rest);

            arena[carrier].kind = String::from("struct");
            arena[carrier].start = open;
            arena[carrier].end = reach;
            arena[carrier].children = carried;

            if carrier == held {
                kept.push(tag);
                kept.push(carrier);
            } else {
                let last = arena[held].children.len() - 1;

                arena[held].children.truncate(last);
                arena[held].children.push(tag);
                arena[held].children.push(carrier);
                arena[held].end = reach;

                kept.push(held);
            }

            at += 1;
        }

        arena[index].children = kept;
    }
}

fn keyword(
    arena: &[Item],
    held: usize,
    next: usize,
    source: &[u8],
) -> Option<(usize, usize, usize)> {
    if arena[held].kind != "index_expression"
        || arena[held].children.len() != 2
        || arena[next].kind != "struct"
        || arena[next].start != arena[held].end
        || arena[held].end == 0
        || source.get(arena[held].end - 1) != Some(&b']')
    {
        return None;
    }

    let tag = arena[held].children[0];
    let keyed = arena[held].children[1];

    if arena[tag].kind != "tag" || arena[keyed].start == 0 {
        return None;
    }

    let open = arena[keyed].start - 1;

    (source.get(open) == Some(&b'[')).then_some((tag, keyed, open))
}

fn results(arena: &mut [Item]) {
    let mut index = 0;

    while index < arena.len() {
        if arena[index].kind != "tuple_type" || !shares_a_type(arena, index) {
            index += 1;

            continue;
        }

        let children = arena[index].children.clone();
        let mut rebuilt = Vec::with_capacity(children.len());

        for child in children {
            rebuilt.push(named(arena, child).unwrap_or(child));
        }

        arena[index].children = rebuilt;
        index += 1;
    }
}

fn shares_a_type(arena: &[Item], index: usize) -> bool {
    arena[index]
        .children
        .iter()
        .any(|&child| arena[child].kind == "named_type")
}

fn named(arena: &[Item], index: usize) -> Option<usize> {
    if arena[index].kind != "type" || arena[index].children.len() != 1 {
        return None;
    }

    let held = arena[index].children[0];

    (arena[held].kind == "identifier").then_some(held)
}

fn instances(arena: &mut Vec<Item>, source: &[u8]) {
    for index in 0..arena.len() {
        if arena[index].kind != "struct" {
            continue;
        }

        let head: Vec<usize> = arena[index]
            .children
            .iter()
            .copied()
            .take_while(|&child| arena[child].kind != "struct_field")
            .collect();

        if head.len() < 2 {
            continue;
        }

        let start = arena[head[0]].start;

        if resumed(source, arena[head[0]].end) != arena[head[0]].end
            || source.get(arena[head[0]].end) != Some(&b'(')
        {
            continue;
        }

        let last = head[head.len() - 1];
        let Some(open) = (arena[last].end..arena[index].end).find(|&at| source[at] == b'{') else {
            continue;
        };

        let mut reach = open;

        while reach > arena[last].end && source[reach - 1] != b')' {
            reach -= 1;
        }

        if reach == arena[last].end {
            continue;
        }

        let mut carried = arena[index].children[head.len()..].to_vec();

        arena.push(Item {
            children: head,
            end: reach,
            kind: String::from("call_expression"),
            operator: String::new(),
            start,
        });

        let held = arena.len() - 1;
        let mut rebuilt = vec![held];

        rebuilt.append(&mut carried);

        arena[index].children = rebuilt;
    }
}

const RECORDS: [(&str, &str); 4] = [
    ("bit_field", "bit_field_type"),
    ("enum", "enum_type"),
    ("struct", "struct_type"),
    ("union", "union_type"),
];

fn literals(arena: &mut Vec<Item>, source: &[u8]) {
    for index in 0..arena.len() {
        if arena[index].kind != "struct" || arena[index].children.is_empty() {
            continue;
        }

        let head = arena[index].children[0];

        if arena[head].kind != "identifier" || arena[head].start != arena[index].start {
            continue;
        }

        let named = String::from_utf8_lossy(&source[arena[head].start..arena[head].end]);
        let fields: Vec<usize> = arena[index].children[1..].to_vec();

        if named == "return" {
            let Some(open) = (arena[head].end..arena[index].end).find(|&at| source[at] == b'{')
            else {
                continue;
            };

            arena.push(Item {
                children: fields,
                end: arena[index].end,
                kind: String::from("struct"),
                operator: String::new(),
                start: open,
            });

            let held = arena.len() - 1;

            arena[index].kind = String::from("return_statement");
            arena[index].children = vec![held];

            continue;
        }

        let Some(record) = RECORDS
            .iter()
            .find(|(word, _)| *word == named)
            .map(|(_, kind)| *kind)
        else {
            continue;
        };

        let mut carried = Vec::with_capacity(fields.len());

        for field in fields {
            if arena[field].kind != "struct_field" {
                carried.push(field);

                continue;
            }

            if record == "enum_type" {
                carried.extend(arena[field].children.clone());

                continue;
            }

            arena[field].kind = String::from("struct_member");
            carried.push(field);
        }

        arena[index].kind = String::from(record);
        arena[index].children = carried;
    }
}

fn operands(arena: &mut [Item], source: &[u8]) {
    for index in 0..arena.len() {
        let children = arena[index].children.clone();
        let mut rebuilt = Vec::with_capacity(children.len());
        let mut at = 0;
        let mut joined = false;

        while at < children.len() {
            let held = children[at];

            let paired = children.get(at + 1).is_some_and(|&next| {
                arena[held].kind == "tag"
                    && arena[next].kind == "unary_expression"
                    && arena[next].children.len() == 1
                    && arena[next].start >= arena[held].end
                    && blank(source, arena[held].end, arena[next].start) == arena[next].start
            });

            if !paired {
                rebuilt.push(held);
                at += 1;

                continue;
            }

            let next = children[at + 1];
            let operand = arena[next].children[0];

            arena[next].kind = String::from("binary_expression");
            arena[next].start = arena[held].start;
            arena[next].children = vec![held, operand];

            rebuilt.push(next);

            at += 2;
            joined = true;
        }

        if joined {
            arena[index].children = rebuilt;
        }
    }
}

fn guards(arena: &mut Vec<Item>, source: &[u8]) {
    let parents = parents(arena);

    for index in 0..arena.len() {
        if arena[index].kind != "struct" {
            continue;
        }

        let stop = arena[index].end;
        let Some((clause, owner)) = enclosing(arena, &parents, index, stop) else {
            continue;
        };

        let fields: Vec<usize> = arena[index]
            .children
            .iter()
            .copied()
            .filter(|&child| arena[child].kind == "struct_field")
            .collect();

        let head: Vec<usize> = arena[index]
            .children
            .iter()
            .copied()
            .filter(|&child| arena[child].kind != "struct_field")
            .collect();

        let (Some(&last), false) = (head.last(), fields.is_empty()) else {
            continue;
        };

        let Some(open) = (arena[last].end..stop).find(|&at| source[at] == b'{') else {
            continue;
        };

        let mut reach = open;

        while reach > arena[last].end && source[reach - 1].is_ascii_whitespace() {
            reach -= 1;
        }

        let mut held = index;

        for _ in 0..arena.len() {
            arena[held].end = reach;

            if held == clause {
                break;
            }

            held = parents[held];
        }

        let mut carried = Vec::new();

        for field in fields {
            if arena[field].children.len() > 1 {
                let held = arena[field].children.clone();

                arena.push(Item {
                    children: held,
                    end: arena[field].end,
                    kind: String::from("assignment_statement"),
                    operator: String::new(),
                    start: arena[field].start,
                });

                carried.push(arena.len() - 1);

                continue;
            }

            carried.extend(arena[field].children.clone());
        }

        if source.get(reach - 1) == Some(&b')') {
            arena[index].kind = String::from("call_expression");
            arena[index].children = head;
        } else if let (Some(&only), holder) = (head.first(), parents[index]) {
            let at = arena[holder]
                .children
                .iter()
                .position(|&child| child == index);

            if let Some(at) = at {
                arena[holder].children[at] = only;
            }
        }

        arena.push(Item {
            children: carried,
            end: stop,
            kind: String::from("block"),
            operator: String::new(),
            start: open,
        });

        let block = arena.len() - 1;

        let at = arena[owner]
            .children
            .iter()
            .position(|&child| child == clause)
            .map_or(arena[owner].children.len(), |held| held + 1);

        arena[owner].children.insert(at, block);

        if arena[clause].kind == "where_clause" {
            continue;
        }

        let children = arena[owner].children.clone();
        let mut trailing = Vec::new();
        let mut kept = Vec::with_capacity(children.len());

        for child in children {
            if arena[child].start >= stop {
                trailing.push(child);

                continue;
            }

            kept.push(child);
        }

        arena[owner].children = kept;
        arena[owner].end = stop;

        let holder = parents[owner];

        if holder == usize::MAX || trailing.is_empty() {
            continue;
        }

        let at = arena[holder]
            .children
            .iter()
            .position(|&child| child == owner)
            .map_or(arena[holder].children.len(), |held| held + 1);

        for (step, child) in trailing.into_iter().enumerate() {
            arena[holder].children.insert(at + step, child);
        }
    }
}

fn enclosing(
    arena: &[Item],
    parents: &[usize],
    index: usize,
    stop: usize,
) -> Option<(usize, usize)> {
    let mut held = index;

    for _ in 0..arena.len() {
        let parent = parents[held];

        if parent == usize::MAX {
            return None;
        }

        if matches!(
            arena[parent].kind.as_str(),
            "for_statement" | "if_statement" | "switch_statement" | "when_statement"
        ) {
            return Some((held, parent));
        }

        if arena[parent].end != stop {
            return None;
        }

        if arena[parent].kind == "where_clause" {
            let owner = parents[parent];

            if owner == usize::MAX {
                return None;
            }

            return Some((parent, owner));
        }

        held = parent;
    }

    None
}

fn bodies(arena: &mut [Item]) {
    let parents = parents(arena);

    for index in (0..arena.len()).rev() {
        if arena[index].kind != "procedure_type" {
            continue;
        }

        let Some(&block) = arena[index].children.last() else {
            continue;
        };

        if arena[block].kind != "block" {
            continue;
        }

        let mut wrappers = Vec::new();
        let mut held = index;

        for _ in 0..arena.len() {
            let parent = parents[held];

            if parent == usize::MAX {
                held = usize::MAX;

                break;
            }

            if arena[parent].kind != "type" {
                held = parent;

                break;
            }

            wrappers.push(parent);
            held = parent;
        }

        let returning = held != usize::MAX
            && matches!(arena[held].kind.as_str(), "procedure" | "procedure_type");

        if !returning {
            arena[index].kind = String::from("procedure");

            continue;
        }

        arena[index].children.pop();

        let reach = arena[index]
            .children
            .last()
            .map_or(arena[index].start, |&child| arena[child].end);

        arena[index].end = reach;

        for wrapper in wrappers {
            arena[wrapper].end = reach;
        }

        arena[held].children.push(block);
    }
}

fn parents(arena: &[Item]) -> Vec<usize> {
    let mut found = vec![usize::MAX; arena.len()];

    for index in 0..arena.len() {
        for &child in &arena[index].children {
            found[child] = index;
        }
    }

    found
}

const ALIGNMENTS: [&str; 4] = [
    "#align",
    "#field_align",
    "#max_field_align",
    "#min_field_align",
];

fn arguments(arena: &mut Vec<Item>, source: &[u8]) {
    for index in 0..arena.len() {
        let children = arena[index].children.clone();
        let mut rebuilt = Vec::with_capacity(children.len());
        let mut split = false;

        for child in children {
            let Some((open, argument)) = swallowed(arena, child, source) else {
                rebuilt.push(child);

                continue;
            };

            let start = arena[child].start;
            let reach = arena[child].end;
            let named = &source[start..open];

            arena[child].end = open;

            let held = argument.map(|(kind, from, to)| {
                arena.push(Item {
                    children: Vec::new(),
                    end: to,
                    kind,
                    operator: String::new(),
                    start: from,
                });

                arena.len() - 1
            });

            let alignment = ALIGNMENTS.contains(&String::from_utf8_lossy(named).as_ref());

            let (kind, from) = if alignment {
                (String::from("parenthesized_expression"), open)
            } else {
                (String::from("call_expression"), start)
            };

            let mut carried: Vec<usize> = if alignment { Vec::new() } else { vec![child] };

            carried.extend(held);

            arena.push(Item {
                children: carried,
                end: reach,
                kind,
                operator: String::new(),
                start: from,
            });

            let raised = arena.len() - 1;

            if alignment {
                rebuilt.push(child);
            }

            rebuilt.push(raised);

            split = true;
        }

        if split {
            arena[index].children = rebuilt;
        }
    }
}

fn swallowed(
    arena: &[Item],
    index: usize,
    source: &[u8],
) -> Option<(usize, Option<(String, usize, usize)>)> {
    if arena[index].kind != "tag" {
        return None;
    }

    let start = arena[index].start;
    let end = arena[index].end;

    if source.get(end - 1) != Some(&b')') {
        return None;
    }

    let open = start + source[start..end].iter().position(|&byte| byte == b'(')?;
    let mut from = open + 1;
    let mut to = end - 1;

    while from < to && source[from].is_ascii_whitespace() {
        from += 1;
    }

    while to > from && source[to - 1].is_ascii_whitespace() {
        to -= 1;
    }

    if from == to {
        return Some((open, None));
    }

    let held = &source[from..to];

    let kind = if held[0].is_ascii_digit() {
        if !held.iter().all(|byte| byte.is_ascii_digit() || *byte == b'_') {
            return None;
        }

        String::from("number")
    } else {
        if !held
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'_')
        {
            return None;
        }

        String::from("identifier")
    };

    Some((open, Some((kind, from, to))))
}

fn tags(arena: &mut [Item], source: &[u8]) {
    let mut lifted: Vec<(usize, usize, usize)> = Vec::new();
    let mut index = 0;

    while index < arena.len() {
        let children = arena[index].children.clone();
        let mut rebuilt = Vec::with_capacity(children.len());
        let mut moved = false;

        for child in children {
            let Some(held) = tagged(arena, child, source) else {
                rebuilt.push(child);

                continue;
            };

            let tag = arena[held].children[0];
            let reach = resumed(source, arena[tag].end);

            arena[held].children.remove(0);
            arena[held].start = reach;
            arena[child].start = reach;

            lifted.push((arena[tag].start, arena[tag].end, reach));
            rebuilt.push(tag);
            rebuilt.push(child);

            moved = true;
        }

        if moved {
            arena[index].children = rebuilt;
        }

        index += 1;
    }

    for (start, end, reach) in lifted {
        for item in arena.iter_mut() {
            if item.kind != "tag" && item.start == start && item.end > end {
                item.start = reach;
            }
        }
    }
}

fn resumed(source: &[u8], end: usize) -> usize {
    let mut held = end;

    while matches!(source.get(held), Some(b' ' | b'\t')) {
        held += 1;
    }

    held
}

fn tagged(arena: &[Item], index: usize, source: &[u8]) -> Option<usize> {
    let held = if arena[index].kind == "type" && arena[index].children.len() == 1 {
        arena[index].children[0]
    } else {
        index
    };

    if !matches!(arena[held].kind.as_str(), "array_type" | "call_expression") {
        return None;
    }

    let first = *arena[held].children.first()?;

    if arena[first].kind != "tag" {
        return None;
    }

    let called = arena[held].kind == "call_expression"
        && source.get(arena[first].end) == Some(&b'(');

    (!called).then_some(held)
}

fn anonymous(arena: &[Item], index: usize) -> bool {
    if arena[index].kind != "parameter" || arena[index].children.is_empty() {
        return false;
    }

    !arena[index]
        .children
        .iter()
        .any(|&child| matches!(arena[child].kind.as_str(), "tag" | "type"))
}

fn signs(arena: &mut Vec<Item>, source: &[u8]) {
    let mut index = 0;

    while index < arena.len() {
        let signed = matches!(arena[index].kind.as_str(), "float" | "number")
            && matches!(source.get(arena[index].start), Some(b'+' | b'-'));

        if !signed {
            index += 1;

            continue;
        }

        let held = arena.len();
        let kind = core::mem::take(&mut arena[index].kind);
        let end = arena[index].end;
        let start = arena[index].start + 1;

        arena.push(Item {
            children: Vec::new(),
            end,
            kind,
            operator: String::new(),
            start,
        });

        arena[index].children = vec![held];
        arena[index].kind = String::from("unary_expression");
        index += 1;
    }
}

fn hexadecimals(arena: &mut [Item], source: &[u8]) {
    for item in arena.iter_mut() {
        if item.kind != "number" {
            continue;
        }

        if !matches!(source.get(item.start..item.start + 2), Some(b"0h" | b"0H")) {
            continue;
        }

        item.kind = String::from("float");
    }
}

fn floats(arena: &mut [Item], source: &[u8]) {
    for index in 0..arena.len() {
        if arena[index].kind != "member_expression" || arena[index].children.len() != 2 {
            continue;
        }

        let left = arena[index].children[0];
        let right = arena[index].children[1];

        let numeric = matches!(arena[left].kind.as_str(), "float" | "number")
            && matches!(arena[right].kind.as_str(), "float" | "number");

        let joined = arena[left].start == arena[index].start
            && arena[right].end == arena[index].end
            && arena[left].end + 1 == arena[right].start
            && source.get(arena[left].end) == Some(&b'.');

        if !numeric || !joined {
            continue;
        }

        arena[index].kind = String::from("float");
        arena[index].children.clear();
    }
}

fn odin(outer: &Item, inner: &Item) -> Option<Turn> {
    let postfixed = matches!(
        outer.kind.as_str(),
        "address"
            | "call_expression"
            | "index_expression"
            | "member_expression"
            | "or_break_expression"
            | "or_continue_expression"
            | "or_return_expression"
    );

    if postfixed && inner.kind == "unary_expression" {
        return Some(Turn {
            hinge: 0,
            leading: false,
        });
    }

    if postfixed && inner.kind == "cast_expression" && inner.children.len() == 2 {
        return Some(Turn {
            hinge: 1,
            leading: false,
        });
    }

    if postfixed && matches!(inner.kind.as_str(), "binary_expression" | "range_expression") {
        return Some(Turn {
            hinge: 1,
            leading: false,
        });
    }

    if outer.kind == "binary_expression" && inner.kind == "range_expression" {
        return Some(Turn {
            hinge: 1,
            leading: false,
        });
    }

    if outer.kind == "unary_expression" && inner.kind == "range_expression" {
        return Some(Turn {
            hinge: 0,
            leading: true,
        });
    }

    let below = strength(&inner.operator);
    let above = strength(&outer.operator);

    if outer.kind == "binary_expression"
        && inner.kind == "binary_expression"
        && below > 0
        && above > 0
        && below < above
    {
        return Some(Turn {
            hinge: 1,
            leading: false,
        });
    }

    None
}

fn instantiations(arena: &mut [Item]) {
    for index in 0..arena.len() {
        if arena[index].kind != "polymorphic_type" || arena[index].children.len() < 2 {
            continue;
        }

        let head = arena[index].children[0];

        let inner = if arena[head].kind == "type" && arena[head].children.len() == 1 {
            arena[head].children[0]
        } else {
            head
        };

        if !matches!(arena[inner].kind.as_str(), "array_type" | "pointer_type") {
            continue;
        }

        let Some(&element) = arena[inner].children.last() else {
            continue;
        };

        let arguments: Vec<usize> = arena[index].children[1..].to_vec();
        let mut carried = arena[inner].children.clone();
        let last = carried.len() - 1;
        let reach = arena[index].end;
        let start = arena[element].start;

        carried[last] = head;

        arena[index].kind = arena[inner].kind.clone();
        arena[index].children = carried;

        if head != inner {
            arena[head].start = start;
            arena[head].end = reach;
            arena[head].children = vec![inner];
        }

        arena[inner].kind = String::from("polymorphic_type");
        arena[inner].start = start;
        arena[inner].end = reach;
        arena[inner].children = core::iter::once(element).chain(arguments).collect();
    }
}

fn ranges(arena: &mut [Item]) {
    for _ in 0..arena.len().saturating_add(1) {
        let mut turned = false;

        for index in 0..arena.len() {
            if !overreaches(arena, index) {
                continue;
            }

            let left = arena[index].children[0];
            let right = arena[index].children[1];
            let start = arena[right].children[0];
            let stop = arena[right].children[1];
            let reach = arena[start].end;

            arena[right].kind = core::mem::replace(
                &mut arena[index].kind,
                String::from("range_expression"),
            );
            arena[right].operator = core::mem::take(&mut arena[index].operator);
            arena[right].start = arena[index].start;
            arena[right].end = reach;
            arena[right].children = vec![left, start];

            arena[index].children = vec![right, stop];

            turned = true;
        }

        if !turned {
            break;
        }
    }
}

fn overreaches(arena: &[Item], index: usize) -> bool {
    if arena[index].kind != "binary_expression" || arena[index].children.len() != 2 {
        return false;
    }

    let right = arena[index].children[1];

    if arena[right].kind != "range_expression" || arena[right].children.len() != 2 {
        return false;
    }

    strength(&arena[index].operator) > 0
}

fn conditionals(arena: &mut [Item]) {
    for _ in 0..arena.len().saturating_add(1) {
        let mut turned = false;

        for index in 0..arena.len() {
            if !chooses(arena, index) {
                continue;
            }

            let left = arena[index].children[0];
            let right = arena[index].children[1];
            let carried = arena[right].children.clone();
            let condition = carried[0];
            let reach = arena[condition].end;

            arena[right].kind =
                core::mem::replace(&mut arena[index].kind, String::from("ternary_expression"));
            arena[right].operator = core::mem::take(&mut arena[index].operator);
            arena[right].start = arena[index].start;
            arena[right].end = reach;
            arena[right].children = vec![left, condition];

            let mut rebuilt = vec![right];

            rebuilt.extend_from_slice(&carried[1..]);

            arena[index].children = rebuilt;

            turned = true;
        }

        if !turned {
            break;
        }
    }
}

fn chooses(arena: &[Item], index: usize) -> bool {
    if arena[index].kind != "binary_expression" || arena[index].children.len() != 2 {
        return false;
    }

    let right = arena[index].children[1];

    if arena[right].kind != "ternary_expression" || arena[right].children.len() < 2 {
        return false;
    }

    strength(&arena[index].operator) > 0
}

fn associativity(arena: &mut [Item]) -> bool {
    let mut moved = false;

    for _ in 0..arena.len().saturating_add(1) {
        let mut turned = false;

        for index in 0..arena.len() {
            if !leans(arena, index) {
                continue;
            }

            let left = arena[index].children[0];
            let right = arena[index].children[1];
            let inner = arena[right].children[0];
            let held = arena[right].children[1];
            let start = arena[index].start;
            let reach = arena[inner].end;
            let above = core::mem::take(&mut arena[index].operator);
            let below = core::mem::take(&mut arena[right].operator);

            arena[right].operator = above;
            arena[right].start = start;
            arena[right].end = reach;
            arena[right].children = vec![left, inner];

            arena[index].operator = below;
            arena[index].children = vec![right, held];

            turned = true;
            moved = true;
        }

        if !turned {
            break;
        }
    }

    moved
}

fn leans(arena: &[Item], index: usize) -> bool {
    if arena[index].kind != "binary_expression" || arena[index].children.len() != 2 {
        return false;
    }

    let right = arena[index].children[1];

    if arena[right].kind != "binary_expression" || arena[right].children.len() != 2 {
        return false;
    }

    let above = strength(&arena[index].operator);
    let below = strength(&arena[right].operator);

    above > 0 && below > 0 && below <= above
}

fn strength(operator: &str) -> u8 {
    match operator {
        "||" => 1,
        "&&" => 2,
        "!=" | "<" | "<=" | "==" | ">" | ">=" | "in" | "not_in" => 3,
        "+" | "-" | "|" | "~" => 4,
        "%" | "%%" | "&" | "&~" | "*" | "/" | "<<" | ">>" => 5,
        _ => 0,
    }
}

fn constants(arena: &mut [Item], source: &[u8]) {
    for index in 0..arena.len() {
        if arena[index].kind != "var_declaration" || arena[index].children.len() < 3 {
            continue;
        }

        let found = arena[index]
            .children
            .iter()
            .copied()
            .find(|&child| arena[child].kind == "type");

        let Some(typed) = found else {
            continue;
        };

        let mut offset = arena[typed].end;

        while matches!(source.get(offset), Some(b' ' | b'\t')) {
            offset += 1;
        }

        if source.get(offset) == Some(&b':') {
            arena[index].kind = String::from("const_type_declaration");
        }
    }
}

fn precedence(arena: &mut [Item], turn: fn(&Item, &Item) -> Option<Turn>) {
    let limit = arena.len().saturating_add(1);
    let mut order = order(arena);

    while let Some(index) = order.pop() {
        let mut work = vec![index];
        let mut turns = 0;

        while let Some(node) = work.pop() {
            let Some(demoted) = rotate(arena, node, turn) else {
                continue;
            };

            turns += 1;

            assert!(
                turns <= limit,
                "the rotations at node {index} did not settle in {limit} turns"
            );

            work.push(node);
            work.push(demoted);
        }
    }
}

fn order(arena: &[Item]) -> Vec<usize> {
    let mut found = Vec::with_capacity(arena.len());
    let mut stack = vec![0];

    while let Some(index) = stack.pop() {
        found.push(index);

        for &child in &arena[index].children {
            stack.push(child);
        }
    }

    found
}

fn flatten(arena: &[Item]) -> Vec<(String, usize, usize)> {
    let mut rows = Vec::with_capacity(arena.len());
    let mut stack = vec![0];

    while let Some(index) = stack.pop() {
        let item = &arena[index];

        rows.push((item.kind.clone(), item.start, item.end));

        for &child in item.children.iter().rev() {
            stack.push(child);
        }
    }

    rows
}

pub fn walk(
    root: Node<'_>,
    source: &[u8],
    correction: &Correction,
) -> (Vec<(String, usize, usize)>, bool) {
    let (mut arena, broken) = build(root);

    match *correction {
        Correction::None => {}
        Correction::Odin => {
            parameters(&mut arena);
            results(&mut arena);
            dereferences(&mut arena, source);
            closures(&mut arena, source);
            records(&mut arena, source);
            composites(&mut arena, source);
            selections(&mut arena, source);
            selectors(&mut arena);
            returns(&mut arena, source);
            floats(&mut arena, source);
            signs(&mut arena, source);
            hexadecimals(&mut arena, source);
            constants(&mut arena, source);
            guards(&mut arena, source);
            literals(&mut arena, source);
            instances(&mut arena, source);
            operands(&mut arena, source);
            bodies(&mut arena);
            arguments(&mut arena, source);
            tags(&mut arena, source);
            spaced(&mut arena, source);
            elements(&mut arena, source);
            counted(&mut arena, source);
            sparse(&mut arena, source);
            instantiations(&mut arena);
            ranges(&mut arena);
            conditionals(&mut arena);

            for _ in 0..arena.len().saturating_add(1) {
                precedence(&mut arena, odin);

                if !associativity(&mut arena) {
                    break;
                }
            }
        }
        Correction::TypeScript => {
            resources(&mut arena, source);
            annotations(&mut arena);
            queries(&mut arena, source);
            assertions(&mut arena);
            precedence(&mut arena, typescript);
        }
    }

    (flatten(&arena), broken)
}

pub fn render(path: &str, rows: &[(String, usize, usize)], broken: bool) -> String {
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

pub fn sources(root: &Path, extensions: &[&str]) -> Vec<(String, PathBuf)> {
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
