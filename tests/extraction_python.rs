#[path = "common/extraction.rs"]
mod common;

#[path = "common/residue.rs"]
mod residue;

use common::{Argument, Field, Model, Registration, Value};
use scylla::bounded::{Span, count_of};
use scylla::brackets::Pairs;
use scylla::language::Lexer as _;
use scylla::lex::PYTHON;
use scylla::outline::python::{self, Outline};
use scylla::structure::{self, NONE, Node, NodeKind, Nodes, Shape};
use scylla::summary::Summary;
use scylla::token::{Token, TokenKind, Tokens};

const NODE_COUNT_MAX: u32 = 1 << 14;
const ROW_COUNT_MAX: u32 = 1 << 13;
const SEGMENT_COUNT_MAX: u32 = 1 << 14;
const TOKEN_COUNT_MAX: u32 = 1 << 17;
const ACCESS_NAMES: [&[u8]; 3] = [b"CHANGE", b"DELETE", b"VIEW"];
const GLUE_BASE: &[u8] = b"BaseGlue";
const GLUE_ROOT: &[u8] = b"Glue";
const META_CLASS: &[u8] = b"Meta";
const NON_EDITABLE_FIELDS: [&[u8]; 3] = [b"AutoField", b"BigAutoField", b"SmallAutoField"];
const OBJECT_PARAMETERS: [&str; 2] = ["request", "glue"];
const REGISTRATION_PARAMETERS: [&str; 4] = ["request", "unique_name", "target", "access"];
const RELATION_FIELDS: [&[u8]; 3] = [b"ForeignKey", b"ManyToManyField", b"OneToOneField"];

const LEGACY_REGISTRATIONS: [(&[u8], &str); 4] = [
    (b"glue_function", "function"),
    (b"glue_model_object", "model"),
    (b"glue_query_set", "queryset"),
    (b"glue_template", "template"),
];

const NAMESPACES: [&[u8]; 8] = [
    b"collection",
    b"form",
    b"function",
    b"json",
    b"model",
    b"object",
    b"queryset",
    b"template",
];

struct Built {
    nodes: Vec<Node>,
    outline: Outline,
    source: Vec<u8>,
    tokens: Vec<Token>,
}

#[test]
fn every_registration_the_oracle_recorded_comes_back_field_for_field() {
    let residue = residue::residue("residue-extraction.json");
    let mut compared = 0;

    for case in &common::extractions("py") {
        if residue.contains(&case.name) {
            continue;
        }

        let built = Built::new(&case.source);
        let found = built.registrations();

        assert_eq!(
            found.len(),
            case.extraction.registrations.len(),
            "{}: the registration counts differ\n{found:#?}\n{:#?}",
            case.name,
            case.extraction.registrations
        );

        for (index, (came, recorded)) in found
            .iter()
            .zip(case.extraction.registrations.iter())
            .enumerate()
        {
            assert_eq!(
                came, recorded,
                "{}: registration {index} differs",
                case.name
            );

            compared += 1;
        }
    }

    assert_eq!(compared, 26, "the corpus lost its registrations");
}

#[test]
fn every_model_the_oracle_recorded_comes_back_field_for_field() {
    let residue = residue::residue("residue-extraction.json");
    let mut compared = 0;

    for case in &common::extractions("py") {
        if residue.contains(&case.name) {
            continue;
        }

        let built = Built::new(&case.source);
        let found = built.models();

        assert_eq!(
            found.len(),
            case.extraction.models.len(),
            "{}: the model counts differ\n{found:#?}\n{:#?}",
            case.name,
            case.extraction.models
        );

        for (index, (came, recorded)) in found.iter().zip(case.extraction.models.iter()).enumerate()
        {
            assert_eq!(came, recorded, "{}: model {index} differs", case.name);

            compared += 1;
        }
    }

    assert_eq!(compared, 12, "the corpus lost its model definitions");
}

impl Built {
    fn new(source: &[u8]) -> Self {
        let bytes = source.to_vec();
        let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);
        let mut pairs = Pairs::reserve(TOKEN_COUNT_MAX);
        let mut nodes = Nodes::reserve(NODE_COUNT_MAX);
        let mut outline = Outline::reserve(ROW_COUNT_MAX, SEGMENT_COUNT_MAX);

        PYTHON.lex(&bytes, &mut tokens);
        pairs.build(&bytes, tokens.as_slice());

        structure::build(
            tokens.as_slice(),
            &bytes,
            &mut nodes,
            Shape::PYTHON,
            structure::DEPTH_MAX,
        );

        python::build(
            &bytes,
            tokens.as_slice(),
            &pairs,
            nodes.as_slice(),
            &mut outline,
        );

        Self {
            nodes: nodes.as_slice().to_vec(),
            outline,
            source: bytes,
            tokens: tokens.as_slice().to_vec(),
        }
    }

    fn registrations(&self) -> Vec<Registration> {
        let mut found = Vec::new();

        for call in self.outline.calls() {
            let segments = self
                .outline
                .segments_of(call.callee_segment_first, call.callee_segment_count);

            let Some((namespace, legacy)) = self.namespace_of(segments) else {
                continue;
            };

            let parameters: &[&str] = if namespace == "object" {
                &OBJECT_PARAMETERS
            } else {
                &REGISTRATION_PARAMETERS
            };

            let arguments = self.arguments_of(call, parameters);
            let is_object = namespace == "object";

            found.push(Registration {
                explicit_name: is_object && self.constructor_names(&arguments),
                legacy,
                name: value_of(&arguments, "unique_name"),
                name_range: range_of(&arguments, "unique_name")
                    .unwrap_or_else(|| self.call_range(call)),
                namespace: namespace.to_owned(),
                range: self.call_range(call),
                target: value_of(&arguments, "target"),
                target_class: if is_object {
                    root_of(&arguments, "glue")
                } else {
                    None
                },
                target_model: root_of(&arguments, "target"),
                view: self.owner_of(call.scope),
                arguments,
            });
        }

        found
    }

    fn models(&self) -> Vec<Model> {
        let mut found = Vec::new();

        for (index, node) in self.nodes.iter().enumerate() {
            if node.kind != NodeKind::Struct || node.name == NONE {
                continue;
            }

            let definition = count_of(index);
            let bases = self.bases_of(definition);

            if bases.is_empty() {
                continue;
            }

            if bases
                .iter()
                .any(|base| base.kind == "Literal" && base.text.as_bytes() == GLUE_BASE)
            {
                continue;
            }

            found.push(Model {
                app_label: self.app_label_of(definition),
                bases,
                fields: self.fields_of(definition),
                name: self.text_of(self.tokens[node.name as usize].span()),
                range: self.node_range(definition),
            });
        }

        found
    }

    fn app_label_of(&self, definition: u32) -> Option<String> {
        for (index, node) in self.nodes.iter().enumerate() {
            if node.kind != NodeKind::Struct || node.parent != definition || node.name == NONE {
                continue;
            }

            if self.tokens[node.name as usize].text(&self.source) != META_CLASS {
                continue;
            }

            let inner = count_of(index);

            for assignment in self.outline.assignments() {
                if assignment.scope != inner || !assignment.target_is_simple {
                    continue;
                }

                if self.source[assignment.target.range()] != *b"app_label" {
                    continue;
                }

                return self.literal_of(assignment.value_token_start, assignment.value_token_end);
            }
        }

        None
    }

    fn arguments_of(&self, call: &python::Call, parameters: &[&str]) -> Vec<Argument> {
        let rows = &self.outline.arguments()
            [call.argument_first as usize..(call.argument_first + call.argument_count) as usize];

        let mut found = Vec::new();
        let mut positional = 0;

        for row in rows {
            let name = if row.name == Span::EMPTY {
                let held = parameters.get(positional).map(|name| (*name).to_owned());

                positional += 1;

                held
            } else {
                Some(rename(&self.text_of(row.name)))
            };

            found.push(Argument {
                items: self.items_of(row.summary),
                name,
                range: (
                    self.tokens[row.value_token_start as usize].offset,
                    self.tokens[row.value_token_end as usize - 1].end(),
                ),
                root: self.root_of(row.value_token_start, row.value_token_end),
                value: self.value_of(row.summary),
            });
        }

        found
    }

    fn bases_of(&self, definition: u32) -> Vec<Value> {
        self.outline
            .bases()
            .iter()
            .filter(|base| base.class_definition == definition)
            .map(|base| self.dotted_of(base.summary))
            .collect()
    }

    fn call_range(&self, call: &python::Call) -> (u32, u32) {
        let first = self.callee_start(call);

        (
            self.tokens[first as usize].offset,
            self.tokens[call.paren_close as usize].end(),
        )
    }

    fn callee_start(&self, call: &python::Call) -> u32 {
        let segments = self
            .outline
            .segments_of(call.callee_segment_first, call.callee_segment_count);

        let head = segments.first().map_or(call.paren_open, |span| span.offset);
        let mut index = call.paren_open;

        while index > 0 {
            if self.tokens[index as usize].offset == head {
                return index;
            }

            index -= 1;
        }

        call.paren_open
    }

    fn constructor_names(&self, arguments: &[Argument]) -> bool {
        let Some(glue) = arguments
            .iter()
            .find(|argument| argument.name.as_deref() == Some("glue"))
        else {
            return false;
        };

        for call in self.outline.calls() {
            let start = self.tokens[self.callee_start(call) as usize].offset;

            if start != glue.range.0 {
                continue;
            }

            let rows = &self.outline.arguments()[call.argument_first as usize
                ..(call.argument_first + call.argument_count) as usize];

            return rows
                .iter()
                .any(|row| row.name != Span::EMPTY && self.source[row.name.range()] == *b"name");
        }

        false
    }

    fn dotted_of(&self, summary: Summary) -> Value {
        match summary {
            Summary::DottedName {
                segment_count,
                segment_first,
            } => {
                let segments = self.outline.segments_of(segment_first, segment_count);
                let parts: Vec<String> = segments.iter().map(|span| self.text_of(*span)).collect();

                literal(&parts.join("."))
            }
            Summary::Call { .. }
            | Summary::Dynamic
            | Summary::Literal { .. }
            | Summary::Sequence { .. } => dynamic(),
        }
    }

    fn fields_of(&self, definition: u32) -> Vec<Field> {
        let mut found = Vec::new();

        for assignment in self.outline.assignments() {
            if assignment.scope != definition || !assignment.target_is_simple {
                continue;
            }

            let Some(call) = self.call_at(assignment.value_token_start) else {
                continue;
            };

            let segments = self
                .outline
                .segments_of(call.callee_segment_first, call.callee_segment_count);

            let Some(last) = segments.last() else {
                continue;
            };

            let kind = self.text_of(*last);

            if !kind.ends_with("Field") && !RELATION_FIELDS.contains(&kind.as_bytes()) {
                continue;
            }

            let arguments = self.arguments_of(call, &["to"]);

            found.push(Field {
                editable: is_editable(kind.as_bytes(), &arguments),
                kind: kind.clone(),
                name: self.text_of(assignment.target),
                range: (
                    assignment.target.offset,
                    self.tokens[assignment.value_token_end as usize - 1].end(),
                ),
                relates_to: relation_target(kind.as_bytes(), &arguments),
            });
        }

        found
    }

    fn call_at(&self, token: u32) -> Option<&python::Call> {
        self.outline
            .calls()
            .iter()
            .find(|call| self.callee_start(call) == token)
    }

    fn items_of(&self, summary: Summary) -> Vec<Value> {
        let Summary::Sequence {
            item_count,
            item_first,
        } = summary
        else {
            return Vec::new();
        };

        (item_first..item_first + item_count)
            .map(|index| self.value_of(self.outline.items()[index as usize]))
            .collect()
    }

    fn literal_of(&self, start: u32, end: u32) -> Option<String> {
        if start >= end {
            return None;
        }

        let token = self.tokens[start as usize];

        if token.kind != TokenKind::String || start + 1 != end {
            return None;
        }

        let text = token.text(&self.source);
        let quote = *text.first()?;

        if quote != b'"' && quote != b'\'' {
            return None;
        }

        Some(String::from_utf8_lossy(&text[1..text.len() - 1]).into_owned())
    }

    fn namespace_of(&self, segments: &[Span]) -> Option<(&'static str, bool)> {
        let parts: Vec<&[u8]> = segments
            .iter()
            .map(|span| &self.source[span.range()])
            .collect();

        let head = *parts.first()?;

        if head == GLUE_ROOT {
            if parts.len() != 2 {
                return None;
            }

            let found = *parts.get(1)?;

            return NAMESPACES
                .iter()
                .position(|known| known.eq_ignore_ascii_case(found) && *known == found)
                .map(|index| (namespace_name(index), false));
        }

        let last = *parts.last()?;

        LEGACY_REGISTRATIONS
            .iter()
            .find(|entry| entry.0 == last)
            .map(|entry| (entry.1, true))
    }

    fn node_range(&self, definition: u32) -> (u32, u32) {
        let node = self.nodes[definition as usize];
        let end = node.token_end.min(count_of(self.tokens.len()));
        let mut last = end;

        while last > node.token_start {
            last -= 1;

            let token = self.tokens[last as usize];

            if !matches!(
                token.kind,
                TokenKind::Newline | TokenKind::BlockEnd | TokenKind::BlockStart
            ) {
                return (self.tokens[node.header as usize].offset, token.end());
            }
        }

        (
            self.tokens[node.header as usize].offset,
            self.tokens[node.header as usize].end(),
        )
    }

    fn owner_of(&self, scope: u32) -> Option<String> {
        if scope == NONE {
            return None;
        }

        let node = self.nodes[scope as usize];

        if node.name == NONE {
            return None;
        }

        Some(self.text_of(self.tokens[node.name as usize].span()))
    }

    fn root_of(&self, start: u32, end: u32) -> Option<String> {
        if start >= end {
            return None;
        }

        let token = self.tokens[start as usize];

        if token.kind != TokenKind::Identifier && !matches!(token.kind, TokenKind::Keyword(_)) {
            return None;
        }

        Some(self.text_of(token.span()))
    }

    fn text_of(&self, span: Span) -> String {
        String::from_utf8_lossy(&self.source[span.range()]).into_owned()
    }

    fn value_of(&self, summary: Summary) -> Value {
        match summary {
            Summary::Literal { content } => literal(&self.text_of(content)),
            Summary::DottedName {
                segment_count,
                segment_first,
            } => {
                let segments = self.outline.segments_of(segment_first, segment_count);

                let Some(last) = segments.last() else {
                    return dynamic();
                };

                let text = &self.source[last.range()];

                if ACCESS_NAMES.contains(&text) {
                    return literal(&self.text_of(*last));
                }

                dynamic()
            }
            Summary::Sequence { .. } => {
                let items = self.items_of(summary);

                if items.iter().any(|item| item.kind == "Dynamic") {
                    return dynamic();
                }

                let parts: Vec<String> = items.iter().map(|item| item.text.clone()).collect();

                literal(&parts.join(","))
            }
            Summary::Call { .. } | Summary::Dynamic => dynamic(),
        }
    }
}

const fn namespace_name(index: usize) -> &'static str {
    match index {
        0 => "collection",
        1 => "form",
        2 => "function",
        3 => "json",
        4 => "model",
        5 => "object",
        6 => "queryset",
        _ => "template",
    }
}

fn dynamic() -> Value {
    Value {
        kind: "Dynamic".to_owned(),
        text: String::new(),
    }
}

fn literal(text: &str) -> Value {
    Value {
        kind: "Literal".to_owned(),
        text: text.to_owned(),
    }
}

fn is_editable(kind: &[u8], arguments: &[Argument]) -> bool {
    if NON_EDITABLE_FIELDS.contains(&kind) {
        return false;
    }

    for name in ["auto_now", "auto_now_add"] {
        if literal_text(arguments, name).as_deref() == Some("True") {
            return false;
        }
    }

    literal_text(arguments, "editable").as_deref() != Some("False")
}

fn literal_text(arguments: &[Argument], name: &str) -> Option<String> {
    let found = value_of(arguments, name);

    if found.kind == "Literal" {
        return Some(found.text);
    }

    None
}

fn range_of(arguments: &[Argument], name: &str) -> Option<(u32, u32)> {
    arguments
        .iter()
        .find(|argument| argument.name.as_deref() == Some(name))
        .map(|argument| argument.range)
}

fn relation_target(kind: &[u8], arguments: &[Argument]) -> Option<Value> {
    if !RELATION_FIELDS.contains(&kind) {
        return None;
    }

    let found = arguments
        .iter()
        .find(|argument| argument.name.as_deref() == Some("to"))?;

    if found.value.kind == "Literal" && found.value.text.is_empty() {
        return Some(dynamic());
    }

    Some(found.value.clone())
}

fn rename(name: &str) -> String {
    if name == "model_object" {
        return "target".to_owned();
    }

    name.to_owned()
}

fn root_of(arguments: &[Argument], name: &str) -> Option<String> {
    arguments
        .iter()
        .find(|argument| argument.name.as_deref() == Some(name))
        .and_then(|argument| argument.root.clone())
}

fn value_of(arguments: &[Argument], name: &str) -> Value {
    arguments
        .iter()
        .find(|argument| argument.name.as_deref() == Some(name))
        .map_or_else(dynamic, |argument| argument.value.clone())
}
