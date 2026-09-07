use std::io::Read;

use ra_ap_rustc_lexer::{Cursor, FrontmatterAllowed, LiteralKind, TokenKind};

fn main() {
    let mut source = String::new();
    let path = std::env::args().nth(1).expect("a path");
    let mut file = std::fs::File::open(path).expect("the file opens");

    file.read_to_string(&mut source).expect("the file reads");

    let mut cursor = Cursor::new(&source, FrontmatterAllowed::Yes);
    let mut offset = 0_usize;
    let bound = source.len() + 1;

    for _ in 0..bound {
        let token = cursor.advance_token();
        let length = token.len as usize;

        if token.kind == TokenKind::Eof {
            break;
        }

        if let Some(class) = class_of(token.kind, &source[offset..offset + length]) {
            println!("{offset}:{length} {class}");
        }

        offset += length;
    }
}

const KEYWORDS: &[&str] = &[
    "Self",
    "as",
    "async",
    "await",
    "break",
    "const",
    "continue",
    "crate",
    "dyn",
    "else",
    "enum",
    "extern",
    "false",
    "fn",
    "for",
    "gen",
    "if",
    "impl",
    "in",
    "let",
    "loop",
    "match",
    "mod",
    "move",
    "mut",
    "pub",
    "ref",
    "return",
    "self",
    "static",
    "struct",
    "super",
    "trait",
    "true",
    "try",
    "type",
    "unsafe",
    "use",
    "where",
    "while",
];

fn class_of(kind: TokenKind, text: &str) -> Option<&'static str> {
    if kind == TokenKind::Ident {
        return Some(if KEYWORDS.contains(&text) {
            "keyword"
        } else {
            "identifier"
        });
    }

    match kind {
        TokenKind::BlockComment { .. } | TokenKind::LineComment { .. } => Some("comment"),
        TokenKind::RawIdent | TokenKind::Lifetime { .. } => Some("identifier"),
        TokenKind::Literal { kind, .. } => Some(match kind {
            LiteralKind::Float { .. } | LiteralKind::Int { .. } => "number",
            _ => "string",
        }),
        TokenKind::OpenBrace | TokenKind::CloseBrace => None,
        TokenKind::Whitespace | TokenKind::Eof => None,
        TokenKind::Unknown | TokenKind::Frontmatter { .. } => None,
        _ => Some("punctuation"),
    }
}
