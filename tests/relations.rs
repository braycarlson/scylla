use std::path::{Path, PathBuf};

use scylla::markup::{self, MarkupKind, Token, Tokens};

const MARK: &[u8] = &[0xef, 0xbb, 0xbf];
const NOTE: &[u8] = b"{# note #}";
const TOKEN_COUNT_MAX: u32 = 1 << 18;

#[test]
fn a_mark_prepended_shifts_every_token_and_changes_no_kind() {
    let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);
    let mut compared = 0;

    for fixture in &fixtures() {
        markup::lex(&fixture.source, &mut tokens);

        let plain: Vec<Token> = tokens.as_slice().to_vec();
        let mut marked_source = MARK.to_vec();

        marked_source.extend_from_slice(&fixture.source);
        markup::lex(&marked_source, &mut tokens);

        let marked = tokens.as_slice();
        let extra = marked.len() - plain.len();

        assert!(
            extra <= 1,
            "{}: the mark added {extra} tokens",
            fixture.name
        );

        for (index, (before, after)) in plain
            .iter()
            .rev()
            .zip(marked.iter().rev())
            .take(plain.len().saturating_sub(1))
            .enumerate()
        {
            assert_eq!(
                before.kind, after.kind,
                "{}: token {index} from the end changed kind behind the mark",
                fixture.name
            );

            assert_eq!(
                before.offset + 3,
                after.offset,
                "{}: token {index} from the end is not three bytes further along",
                fixture.name
            );
        }

        if extra == 1 {
            assert_eq!(
                marked[0].kind,
                MarkupKind::Text,
                "{}: the mark opened a token that is not text",
                fixture.name
            );
        }

        compared += 1;
    }

    assert!(compared > 300, "the corpus lost its fixtures");
}

#[test]
fn windows_line_endings_change_no_token_kind() {
    let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);

    for fixture in &fixtures() {
        if fixture.source.contains(&b'\r') {
            continue;
        }

        markup::lex(&fixture.source, &mut tokens);

        let plain: Vec<MarkupKind> = tokens.as_slice().iter().map(|token| token.kind).collect();

        markup::lex(&windows(&fixture.source), &mut tokens);

        let carried: Vec<MarkupKind> = tokens.as_slice().iter().map(|token| token.kind).collect();

        assert_eq!(
            plain, carried,
            "{}: the carriage returns changed the token kinds",
            fixture.name
        );
    }
}

#[test]
fn a_comment_inserted_at_a_tag_boundary_adds_only_its_own_tokens() {
    let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);
    let mut compared = 0;

    for fixture in &fixtures() {
        markup::lex(&fixture.source, &mut tokens);

        let plain: Vec<Token> = tokens.as_slice().to_vec();

        let Some(at) = boundary(&plain) else {
            continue;
        };

        let mut inserted = fixture.source[..at as usize].to_vec();

        inserted.extend_from_slice(NOTE);
        inserted.extend_from_slice(&fixture.source[at as usize..]);
        markup::lex(&inserted, &mut tokens);

        let carried = tokens.as_slice();

        assert_eq!(
            carried.len(),
            plain.len() + 3,
            "{}: the comment did not add three tokens",
            fixture.name
        );

        let head = plain
            .iter()
            .position(|token| token.offset == at)
            .unwrap_or(0);

        assert_eq!(
            carried[head].kind,
            MarkupKind::CommentOpen,
            "{}: the comment did not open where it was inserted",
            fixture.name
        );

        assert_eq!(carried[head + 1].kind, MarkupKind::CommentText);
        assert_eq!(carried[head + 2].kind, MarkupKind::CommentClose);

        for (index, (before, after)) in plain[..head].iter().zip(carried[..head].iter()).enumerate()
        {
            assert_eq!(
                before, after,
                "{}: token {index} before the comment moved",
                fixture.name
            );
        }

        for (index, (before, after)) in plain[head..]
            .iter()
            .zip(carried[head + 3..].iter())
            .enumerate()
        {
            assert_eq!(
                before.kind, after.kind,
                "{}: token {index} after the comment changed kind",
                fixture.name
            );

            assert_eq!(
                before.offset + 10,
                after.offset,
                "{}: token {index} after the comment is not ten bytes further along",
                fixture.name
            );
        }

        compared += 1;
    }

    assert!(
        compared > 90,
        "too few fixtures carry a tag boundary: {compared}"
    );
}

fn boundary(tokens: &[Token]) -> Option<u32> {
    for (index, token) in tokens.iter().enumerate() {
        if token.kind != MarkupKind::AngleClose {
            continue;
        }

        let Some(next) = tokens.get(index + 1) else {
            continue;
        };

        if !matches!(
            next.kind,
            MarkupKind::AngleOpen | MarkupKind::AngleOpenSlash | MarkupKind::Text
        ) {
            continue;
        }

        return Some(next.offset);
    }

    None
}

struct Fixture {
    name: String,
    source: Vec<u8>,
}

fn fixtures() -> Vec<Fixture> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/templates");
    let mut found = Vec::new();

    collect(&root, &mut found);
    found.sort();

    assert!(
        !found.is_empty(),
        "no fixture templates under {}",
        root.display()
    );

    found
        .into_iter()
        .map(|path| Fixture {
            name: path
                .strip_prefix(&root)
                .expect("a collected fixture sits under fixtures/templates")
                .to_string_lossy()
                .replace('\\', "/"),

            source: std::fs::read(&path).expect("a collected fixture is readable"),
        })
        .collect()
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

fn windows(source: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(source.len() * 2);

    for byte in source {
        if *byte == b'\n' {
            out.push(b'\r');
        }

        out.push(*byte);
    }

    out
}
