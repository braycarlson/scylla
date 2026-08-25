#[path = "reader.rs"]
mod reader;

use std::path::{Path, PathBuf};

pub(crate) use reader::{Reader, root};

#[derive(Debug, Default)]
pub(crate) struct Extraction {
    pub(crate) bindings: Vec<Binding>,
    pub(crate) kind: String,
    pub(crate) models: Vec<Model>,
    pub(crate) objects: Vec<Object>,
    pub(crate) path: String,
    pub(crate) registrations: Vec<Registration>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct Value {
    pub(crate) kind: String,
    pub(crate) text: String,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct Argument {
    pub(crate) items: Vec<Value>,
    pub(crate) name: Option<String>,
    pub(crate) range: (u32, u32),
    pub(crate) root: Option<String>,
    pub(crate) value: Value,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct Registration {
    pub(crate) arguments: Vec<Argument>,
    pub(crate) explicit_name: bool,
    pub(crate) legacy: bool,
    pub(crate) name: Value,
    pub(crate) name_range: (u32, u32),
    pub(crate) namespace: String,
    pub(crate) range: (u32, u32),
    pub(crate) target: Value,
    pub(crate) target_class: Option<String>,
    pub(crate) target_model: Option<String>,
    pub(crate) view: Option<String>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct Field {
    pub(crate) editable: bool,
    pub(crate) kind: String,
    pub(crate) name: String,
    pub(crate) range: (u32, u32),
    pub(crate) relates_to: Option<Value>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct Model {
    pub(crate) app_label: Option<String>,
    pub(crate) bases: Vec<Value>,
    pub(crate) fields: Vec<Field>,
    pub(crate) name: String,
    pub(crate) range: (u32, u32),
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct Member {
    pub(crate) has_await: bool,
    pub(crate) is_async: bool,
    pub(crate) kind: String,
    pub(crate) name: String,
    pub(crate) range: (u32, u32),
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct Object {
    pub(crate) members: Vec<Member>,
    pub(crate) range: (u32, u32),
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct Binding {
    pub(crate) initializer: Vec<String>,
    pub(crate) kind: String,
    pub(crate) name: String,
    pub(crate) name_range: (u32, u32),
    pub(crate) scope_range: (u32, u32),
}

pub(crate) struct Case {
    pub(crate) extraction: Extraction,
    pub(crate) name: String,
    pub(crate) source: Vec<u8>,
}

pub(crate) fn extractions(extension: &str) -> Vec<Case> {
    let root = root();
    let sources = root.join("tests/fixtures/templates");
    let goldens = root.join("tests/fixtures/extraction");
    let mut found = Vec::new();

    collect_extension(&sources, extension, &mut found);
    found.sort();

    assert!(!found.is_empty(), "no .{extension} fixtures to extract");

    let mut cases = Vec::with_capacity(found.len());

    for path in found {
        let relative = path
            .strip_prefix(&sources)
            .expect("a collected fixture sits under fixtures/templates");

        let mut golden = goldens.join(relative);

        golden.set_extension("json");

        let dumped = std::fs::read(&golden)
            .unwrap_or_else(|error| panic!("reading {}: {error}", golden.display()));

        let source = std::fs::read(&path)
            .unwrap_or_else(|error| panic!("reading {}: {error}", path.display()));

        cases.push(Case {
            extraction: parse_extraction(&dumped),
            name: relative.to_string_lossy().replace('\\', "/"),
            source,
        });
    }

    cases
}

fn collect_extension(directory: &Path, extension: &str, out: &mut Vec<PathBuf>) {
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

            if path.extension().is_some_and(|found| found == extension) {
                out.push(path);
            }
        }
    }
}

fn parse_extraction(dumped: &[u8]) -> Extraction {
    let mut reader = Reader {
        offset: 0,
        text: dumped,
    };

    extraction(&mut reader)
}

const ELEMENT_COUNT_MAX: usize = 1 << 20;

fn fields(reader: &mut Reader<'_>, mut read: impl FnMut(&mut Reader<'_>, &str)) {
    reader.expect(b'{');

    for _ in 0..ELEMENT_COUNT_MAX {
        let key = reader.string();

        reader.expect(b':');
        read(reader, key.as_str());

        if !reader.take(b',') {
            reader.expect(b'}');

            return;
        }
    }

    panic!("the dump carries more fields than the reader bounds")
}

fn extraction(reader: &mut Reader<'_>) -> Extraction {
    let mut found = Extraction::default();

    fields(reader, |inner, key| match key {
        "path" => found.path = inner.string(),
        "kind" => found.kind = inner.string(),
        "registrations" => found.registrations = list(inner, registration),
        "models" => found.models = list(inner, model),
        "objects" => found.objects = list(inner, object),
        "bindings" => found.bindings = list(inner, binding),
        other => panic!("the extraction dump carries an unknown key `{other}`"),
    });

    found
}

fn list<T>(reader: &mut Reader<'_>, read: impl Fn(&mut Reader<'_>) -> T) -> Vec<T> {
    reader.expect(b'[');

    let mut items = Vec::new();

    reader.skip();

    if reader.take(b']') {
        return items;
    }

    for _ in 0..ELEMENT_COUNT_MAX {
        items.push(read(reader));

        if !reader.take(b',') {
            reader.expect(b']');

            return items;
        }
    }

    panic!("the dump carries more elements than the reader bounds")
}

fn boolean(reader: &mut Reader<'_>) -> bool {
    reader.skip();

    if reader.take(b't') {
        reader.offset += 3;

        return true;
    }

    reader.take(b'f');
    reader.offset += 4;

    false
}

fn optional(reader: &mut Reader<'_>) -> Option<String> {
    reader.skip();

    if reader.byte() == b'n' {
        reader.offset += 4;

        return None;
    }

    Some(reader.string())
}

fn pair(reader: &mut Reader<'_>) -> (u32, u32) {
    reader.expect(b'[');

    let start = reader.number();

    reader.expect(b',');

    let end = reader.number();

    reader.expect(b']');

    (start, end)
}

fn value(reader: &mut Reader<'_>) -> Value {
    let mut found = Value::default();

    fields(reader, |inner, key| match key {
        "kind" => found.kind = inner.string(),
        "text" => found.text = inner.string(),
        other => panic!("a value carries an unknown key `{other}`"),
    });

    found
}

fn optional_value(reader: &mut Reader<'_>) -> Option<Value> {
    reader.skip();

    if reader.byte() == b'n' {
        reader.offset += 4;

        return None;
    }

    Some(value(reader))
}

fn argument(reader: &mut Reader<'_>) -> Argument {
    let mut found = Argument::default();

    fields(reader, |inner, key| match key {
        "name" => found.name = optional(inner),
        "root" => found.root = optional(inner),
        "value" => found.value = value(inner),
        "items" => found.items = list(inner, value),
        "range" => found.range = pair(inner),
        other => panic!("an argument carries an unknown key `{other}`"),
    });

    found
}

fn registration(reader: &mut Reader<'_>) -> Registration {
    let mut found = Registration::default();

    fields(reader, |inner, key| match key {
        "namespace" => found.namespace = inner.string(),
        "legacy" => found.legacy = boolean(inner),
        "explicit_name" => found.explicit_name = boolean(inner),
        "name" => found.name = value(inner),
        "target" => found.target = value(inner),
        "target_class" => found.target_class = optional(inner),
        "target_model" => found.target_model = optional(inner),
        "view" => found.view = optional(inner),
        "name_range" => found.name_range = pair(inner),
        "range" => found.range = pair(inner),
        "arguments" => found.arguments = list(inner, argument),
        other => panic!("a registration carries an unknown key `{other}`"),
    });

    found
}

fn field(reader: &mut Reader<'_>) -> Field {
    let mut found = Field::default();

    fields(reader, |inner, key| match key {
        "name" => found.name = inner.string(),
        "kind" => found.kind = inner.string(),
        "editable" => found.editable = boolean(inner),
        "relates_to" => found.relates_to = optional_value(inner),
        "range" => found.range = pair(inner),
        other => panic!("a field carries an unknown key `{other}`"),
    });

    found
}

fn model(reader: &mut Reader<'_>) -> Model {
    let mut found = Model::default();

    fields(reader, |inner, key| match key {
        "name" => found.name = inner.string(),
        "app_label" => found.app_label = optional(inner),
        "range" => found.range = pair(inner),
        "bases" => found.bases = list(inner, value),
        "fields" => found.fields = list(inner, field),
        other => panic!("a model carries an unknown key `{other}`"),
    });

    found
}

fn member(reader: &mut Reader<'_>) -> Member {
    let mut found = Member::default();

    fields(reader, |inner, key| match key {
        "name" => found.name = inner.string(),
        "kind" => found.kind = inner.string(),
        "is_async" => found.is_async = boolean(inner),
        "has_await" => found.has_await = boolean(inner),
        "range" => found.range = pair(inner),
        other => panic!("a member carries an unknown key `{other}`"),
    });

    found
}

fn object(reader: &mut Reader<'_>) -> Object {
    let mut found = Object::default();

    fields(reader, |inner, key| match key {
        "range" => found.range = pair(inner),
        "members" => found.members = list(inner, member),
        other => panic!("an object carries an unknown key `{other}`"),
    });

    found
}

fn binding(reader: &mut Reader<'_>) -> Binding {
    let mut found = Binding::default();

    fields(reader, |inner, key| match key {
        "name" => found.name = inner.string(),
        "kind" => found.kind = inner.string(),
        "name_range" => found.name_range = pair(inner),
        "scope_range" => found.scope_range = pair(inner),
        "initializer" => found.initializer = list(inner, read_string),
        other => panic!("a binding carries an unknown key `{other}`"),
    });

    found
}

fn read_string(reader: &mut Reader<'_>) -> String {
    reader.string()
}
