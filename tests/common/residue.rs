use std::path::PathBuf;

pub(crate) fn residue(name: &str) -> Vec<String> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join(name);

    let Ok(text) = std::fs::read(&path) else {
        return Vec::new();
    };

    let mut names = Vec::new();
    let mut offset = 0;

    while offset < text.len() {
        let Some(start) = quoted(&text, offset) else {
            break;
        };

        let (key, after) = start;

        offset = after;

        if key != "fixture" {
            continue;
        }

        let Some((value, next)) = quoted(&text, offset) else {
            break;
        };

        names.push(value);
        offset = next;
    }

    names
}

fn quoted(text: &[u8], from: usize) -> Option<(String, usize)> {
    let mut offset = from;

    while offset < text.len() && text[offset] != b'"' {
        offset += 1;
    }

    if offset >= text.len() {
        return None;
    }

    offset += 1;

    let mut found = String::new();

    while offset < text.len() {
        let byte = text[offset];

        offset += 1;

        if byte == b'"' {
            return Some((found, offset));
        }

        if byte == b'\\' && offset < text.len() {
            found.push(text[offset] as char);
            offset += 1;

            continue;
        }

        found.push(byte as char);
    }

    None
}
