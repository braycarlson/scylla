use std::fs;
use std::path::{Path, PathBuf};

const DEPTH_MAX: u32 = 8;
const DIRECTORY_COUNT_MAX: u32 = 64;
const ENTRY_COUNT_MAX: u32 = 512;
const FILE_BYTES_MAX: u64 = 1 << 20;
const FILE_COUNT_MAX: u32 = 512;
const LINE_COUNT_MAX: u32 = 8_192;
const ROOTS: [&str; 2] = ["src", "tests"];
const SKIPPED: [&str; 1] = ["tests/fixtures"];

fn sources() -> Vec<PathBuf> {
    let mut pending: Vec<(PathBuf, u32)> =
        ROOTS.iter().map(|root| (PathBuf::from(root), 0)).collect();

    let mut found = Vec::new();

    for _ in 0..DIRECTORY_COUNT_MAX {
        let Some((directory, depth)) = pending.pop() else {
            break;
        };

        assert!(
            depth <= DEPTH_MAX,
            "{} nests deeper than {DEPTH_MAX}",
            directory.display()
        );

        let mut entries = fs::read_dir(&directory)
            .unwrap_or_else(|error| panic!("{} is readable: {error}", directory.display()));

        for _ in 0..ENTRY_COUNT_MAX {
            let Some(entry) = entries.next() else {
                break;
            };

            let path = entry
                .unwrap_or_else(|error| {
                    panic!("{} lists its entries: {error}", directory.display())
                })
                .path();

            let metadata = fs::metadata(&path)
                .unwrap_or_else(|error| panic!("{} carries metadata: {error}", path.display()));

            if metadata.is_dir() {
                let skipped = SKIPPED.iter().any(|name| path == Path::new(name));

                if !skipped {
                    pending.push((path, depth + 1));
                }

                continue;
            }

            if path.extension().is_none_or(|extension| extension != "rs") {
                continue;
            }

            assert!(
                metadata.len() <= FILE_BYTES_MAX,
                "{} is larger than {FILE_BYTES_MAX} bytes",
                path.display()
            );

            found.push(path);
        }

        assert!(
            entries.next().is_none(),
            "{} holds more than {ENTRY_COUNT_MAX} entries",
            directory.display()
        );
    }

    assert!(
        pending.is_empty(),
        "the walk left {} directories unvisited",
        pending.len()
    );

    assert!(
        !found.is_empty(),
        "the walk found no Rust source under {ROOTS:?}"
    );

    assert!(
        found.len() <= FILE_COUNT_MAX as usize,
        "the walk found more than {FILE_COUNT_MAX} files"
    );

    found
}

fn violation(path: &Path, number: usize, check: &str) -> String {
    format!("{}:{number}: {check}", path.display())
}

fn use_item_count(line: &str) -> usize {
    let trimmed = line.trim().trim_end_matches(',');

    if trimmed.is_empty() {
        return 0;
    }

    trimmed.split(',').count()
}

fn line_is_tidy(path: &Path, lines: &[&str], index: usize) {
    let number = index + 1;
    let line = lines[index];
    let previous = if index == 0 { "" } else { lines[index - 1] };
    let next = lines.get(index + 1).copied().unwrap_or("");

    assert!(
        !line.contains('\t'),
        "{}",
        violation(path, number, "the line holds a tab")
    );

    assert!(
        !line.contains('\r'),
        "{}",
        violation(path, number, "the line holds a carriage return")
    );

    assert!(
        line.len() == line.trim_end().len(),
        "{}",
        violation(path, number, "the line ends in whitespace")
    );

    if !line.is_empty() {
        return;
    }

    assert!(
        !previous.is_empty() || index == 0,
        "{}",
        violation(path, number, "the blank line follows another blank line")
    );

    assert!(
        !previous.trim_end().ends_with('{'),
        "{}",
        violation(path, number, "the blank line opens a block")
    );

    assert!(
        !next.trim_start().starts_with('}'),
        "{}",
        violation(path, number, "the blank line closes a block")
    );
}

fn file_is_tidy(path: &Path) {
    let text = fs::read_to_string(path)
        .unwrap_or_else(|error| panic!("{} is valid UTF-8: {error}", path.display()));

    assert!(!text.is_empty(), "{} is empty", path.display());

    assert!(
        text.ends_with('\n'),
        "{} does not end with a newline",
        path.display()
    );

    assert!(
        !text.ends_with("\n\n"),
        "{} ends with more than one newline",
        path.display()
    );

    let lines: Vec<&str> = text
        .strip_suffix('\n')
        .unwrap_or(&text)
        .split('\n')
        .collect();

    assert!(
        lines.len() <= LINE_COUNT_MAX as usize,
        "{} is longer than {LINE_COUNT_MAX} lines",
        path.display()
    );

    let mut in_use_list = false;

    for index in 0..lines.len() {
        line_is_tidy(path, &lines, index);

        let line = lines[index];

        if in_use_list {
            if line.trim_start().starts_with('}') {
                in_use_list = false;

                continue;
            }

            assert!(
                use_item_count(line) <= 1,
                "{}",
                violation(
                    path,
                    index + 1,
                    "the wrapped use list packs more than one item onto a line"
                )
            );

            continue;
        }

        let trimmed = line.trim_start();
        let opens = trimmed.starts_with("use ") || trimmed.starts_with("pub use ");

        if opens && line.ends_with('{') {
            in_use_list = true;
        }
    }

    assert!(
        !in_use_list,
        "{} leaves a use list unclosed",
        path.display()
    );
}

#[test]
fn every_rust_source_holds_its_whitespace() {
    let paths = sources();

    for path in &paths {
        file_is_tidy(path);
    }
}

#[test]
fn every_category_projection_names_each_kind() {
    let paths = sources();
    let mut checked = 0;

    for path in &paths {
        let source = fs::read_to_string(path)
            .unwrap_or_else(|error| panic!("{} is readable: {error}", path.display()));

        let mut reading = false;

        for (index, line) in source.lines().enumerate() {
            let trimmed = line.trim_start();

            if trimmed.starts_with("fn category(self) -> Category {") {
                reading = true;
                checked += 1;

                continue;
            }

            if !reading {
                continue;
            }

            if line == "    }" {
                reading = false;

                continue;
            }

            let wildcard = trimmed.starts_with("_ =>") || trimmed.starts_with("_ if");

            assert!(
                !wildcard,
                "{}",
                violation(
                    path,
                    index + 1,
                    "a category projection carries a wildcard arm"
                )
            );
        }

        assert!(!reading, "{} leaves a projection unclosed", path.display());
    }

    assert!(checked > 0, "no category projection was read");
}
