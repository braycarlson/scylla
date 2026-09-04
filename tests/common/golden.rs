const ELEMENT_COUNT_MAX: usize = 1 << 20;

#[path = "reader.rs"]
mod reader;

use std::path::{Path, PathBuf};

pub(crate) use reader::{Reader, root};

pub(crate) struct Golden {
    pub(crate) errors: Vec<(String, u32)>,
    pub(crate) path: String,
    pub(crate) tokens: Vec<(String, u32, u32)>,
    pub(crate) tree: Vec<(String, u32, u32)>,
}

pub(crate) struct Fixture {
    pub(crate) golden: Golden,
    pub(crate) name: String,
    pub(crate) source: Vec<u8>,
}

pub(crate) fn corpus_templates(root: &Path) -> Vec<(String, Vec<u8>)> {
    let mut found = Vec::new();
    let mut pending = vec![root.to_path_buf()];

    while let Some(directory) = pending.pop() {
        let Ok(entries) = std::fs::read_dir(&directory) else {
            continue;
        };

        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(held) = std::fs::metadata(&path) else {
                continue;
            };

            if held.is_dir() {
                pending.push(path);

                continue;
            }

            if path.extension().is_none_or(|extension| extension != "html") {
                continue;
            }

            let Ok(source) = std::fs::read(&path) else {
                continue;
            };

            found.push((
                path.strip_prefix(root)
                    .unwrap_or(&path)
                    .to_string_lossy()
                    .into_owned(),
                source,
            ));
        }
    }

    found.sort();

    found
}

pub(crate) fn fixtures() -> Vec<Fixture> {
    let root = root();
    let templates = root.join("tests/fixtures/templates");
    let goldens = root.join("tests/fixtures/golden");
    let mut found = Vec::new();

    collect(&templates, &mut found);
    found.sort();

    assert!(
        !found.is_empty(),
        "no fixture templates under {}",
        templates.display()
    );

    let mut fixtures = Vec::with_capacity(found.len());

    for template in found {
        let relative = template
            .strip_prefix(&templates)
            .expect("a collected fixture sits under fixtures/templates");

        let mut golden = goldens.join(relative);

        golden.set_extension("json");

        let dumped = std::fs::read(&golden)
            .unwrap_or_else(|error| panic!("reading {}: {error}", golden.display()));

        let source = std::fs::read(&template)
            .unwrap_or_else(|error| panic!("reading {}: {error}", template.display()));

        fixtures.push(Fixture {
            golden: parse(&dumped),
            name: relative.to_string_lossy().replace('\\', "/"),
            source,
        });
    }

    fixtures
}

fn collect(directory: &Path, out: &mut Vec<PathBuf>) {
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

            if path
                .extension()
                .is_some_and(|extension| extension == "html")
            {
                out.push(path);
            }
        }
    }
}

fn parse(dumped: &[u8]) -> Golden {
    let mut reader = Reader {
        offset: 0,
        text: dumped,
    };

    let mut golden = Golden {
        errors: Vec::new(),
        path: String::new(),
        tokens: Vec::new(),
        tree: Vec::new(),
    };

    reader.expect(b'{');

    for _ in 0..ELEMENT_COUNT_MAX {
        let key = reader.string();

        reader.expect(b':');

        match key.as_str() {
            "path" => golden.path = reader.string(),
            "tokens" => golden.tokens = rows(&mut reader),
            "tree" => golden.tree = rows(&mut reader),
            "errors" => {
                golden.errors = rows(&mut reader)
                    .into_iter()
                    .map(|(name, start, _)| (name, start))
                    .collect();
            }
            other => panic!("the golden dump carries an unknown key `{other}`"),
        }

        if !reader.take(b',') {
            reader.expect(b'}');

            return golden;
        }
    }

    panic!("the golden dump carries more fields than the reader bounds")
}

fn rows(reader: &mut Reader<'_>) -> Vec<(String, u32, u32)> {
    reader.expect(b'[');

    let mut rows = Vec::new();

    reader.skip();

    if reader.take(b']') {
        return rows;
    }

    for _ in 0..ELEMENT_COUNT_MAX {
        reader.expect(b'[');

        let name = reader.string();

        reader.expect(b',');

        let start = reader.number();

        let end = if reader.take(b',') {
            reader.number()
        } else {
            start
        };

        reader.expect(b']');
        rows.push((name, start, end));

        if !reader.take(b',') {
            reader.expect(b']');

            return rows;
        }
    }

    panic!("the golden dump carries more rows than the reader bounds")
}
