use std::path::Path;

pub(crate) struct Golden {
    pub(crate) ast: Vec<(String, u32, u32)>,
    pub(crate) scopes: Vec<(String, String, u32, String)>,
}

pub(crate) fn residue_of(name: &str, categories: &[&str]) -> Vec<String> {
    let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join(name);

    let Ok(text) = std::fs::read(&path) else {
        return Vec::new();
    };

    let mut found = Vec::new();
    let mut offset = 0;
    let mut fixture = String::new();

    while offset < text.len() {
        let Some((key, after)) = quoted(&text, offset) else {
            break;
        };

        offset = after;

        let Some((value, next)) = quoted(&text, offset) else {
            break;
        };

        offset = next;

        if key == "fixture" {
            fixture = value;
        } else if key == "category" && categories.contains(&value.as_str()) {
            found.push(fixture.clone());
        }
    }

    found
}

pub(crate) fn golden(root: &Path, name: &str) -> Option<Golden> {
    let path = root.join(format!("{name}.json"));
    let text = std::fs::read(&path).ok()?;

    Some(Golden {
        ast: rows(&text, b"\"ast\":["),
        scopes: scopes(&text),
    })
}

fn scopes(text: &[u8]) -> Vec<(String, String, u32, String)> {
    let key = b"\"scopes\":[";

    let Some(start) = find(text, key) else {
        return Vec::new();
    };

    let mut offset = start + key.len();
    let mut found = Vec::new();

    while offset < text.len() {
        if text[offset] != b'[' {
            break;
        }

        let Some((held, after)) = quoted(text, offset) else {
            break;
        };

        let Some((name, next)) = quoted(text, after) else {
            break;
        };

        let (line, tail) = number(text, next);

        let Some((symbols, stop)) = quoted(text, tail) else {
            break;
        };

        found.push((held, name, line, symbols));

        offset = stop;

        if offset < text.len() && text[offset] == b']' {
            offset += 1;
        }

        if offset < text.len() && text[offset] == b',' {
            offset += 1;

            continue;
        }

        break;
    }

    found
}

fn rows(text: &[u8], key: &[u8]) -> Vec<(String, u32, u32)> {
    let Some(start) = find(text, key) else {
        return Vec::new();
    };

    let mut offset = start + key.len();
    let mut found = Vec::new();

    while offset < text.len() {
        if text[offset] != b'[' {
            break;
        }

        let Some((name, after)) = quoted(text, offset) else {
            break;
        };

        let (first, next) = number(text, after);
        let (second, tail) = number(text, next);

        found.push((name, first, second));

        offset = tail;

        if offset < text.len() && text[offset] == b']' {
            offset += 1;
        }

        if offset < text.len() && text[offset] == b',' {
            offset += 1;

            continue;
        }

        break;
    }

    found
}

fn find(text: &[u8], key: &[u8]) -> Option<usize> {
    text.windows(key.len()).position(|window| window == key)
}

fn number(text: &[u8], from: usize) -> (u32, usize) {
    let mut offset = from;

    while offset < text.len() && !text[offset].is_ascii_digit() {
        offset += 1;
    }

    let mut value = 0_u32;

    while offset < text.len() && text[offset].is_ascii_digit() {
        value = value * 10 + u32::from(text[offset] - b'0');
        offset += 1;
    }

    (value, offset)
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

    let mut found = Vec::new();

    while offset < text.len() {
        let byte = text[offset];

        offset += 1;

        if byte == b'"' {
            return Some((String::from_utf8_lossy(&found).into_owned(), offset));
        }

        if byte == b'\\' && offset < text.len() {
            found.push(text[offset]);
            offset += 1;

            continue;
        }

        found.push(byte);
    }

    None
}
