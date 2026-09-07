use std::fmt::Write as _;
use std::path::Path;

use scylla::language::Languages;
use scylla::lex::{CSS, GO, JAVASCRIPT, ODIN, PYTHON, RUST, TYPESCRIPT, ZIG};
use scylla::token::{Lex, TokenKind, Tokens};

const LANGUAGE_COUNT_MAX: u32 = 8;
const TOKEN_COUNT_MAX: u32 = 1 << 21;

pub fn run(arguments: &[String]) -> i32 {
    let [path] = arguments else {
        return crate::fault("tokens takes exactly one path");
    };

    match dumped(Path::new(path)) {
        Ok(text) => {
            print!("{text}");

            0
        }
        Err(error) => crate::fault(&error),
    }
}

fn dumped(path: &Path) -> Result<String, String> {
    let languages = registered();
    let Some(index) = languages.of_path(path.as_os_str().as_encoded_bytes()) else {
        return Err(format!("{} carries no extension scylla lexes", path.display()));
    };

    let source = std::fs::read(path)
        .map_err(|error| format!("{} is not readable: {error}", path.display()))?;

    let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);

    if languages.lexer(index).lex(&source, &mut tokens) == Lex::Truncated {
        return Err(format!(
            "{} lexes to more than {TOKEN_COUNT_MAX} tokens",
            path.display()
        ));
    }

    let mut out = String::new();

    for token in tokens.as_slice() {
        assert!(token.length > 0);

        writeln!(
            out,
            "{}:{} {}",
            token.offset,
            token.length,
            kind_text(token.kind)
        )
        .expect("a string write cannot fail");
    }

    Ok(out)
}

const fn kind_text(kind: TokenKind) -> &'static str {
    match kind {
        TokenKind::BlockEnd => "block-end",
        TokenKind::BlockStart => "block-start",
        TokenKind::Comment => "comment",
        TokenKind::Identifier => "identifier",
        TokenKind::Keyword(_) => "keyword",
        TokenKind::Newline => "newline",
        TokenKind::Number => "number",
        TokenKind::Punctuation(_) => "punctuation",
        TokenKind::String => "string",
    }
}

fn registered() -> Languages {
    let mut languages = Languages::reserve(LANGUAGE_COUNT_MAX);

    languages.register(&CSS);
    languages.register(&GO);
    languages.register(&JAVASCRIPT);
    languages.register(&ODIN);
    languages.register(&PYTHON);
    languages.register(&RUST);
    languages.register(&TYPESCRIPT);
    languages.register(&ZIG);

    assert_eq!(languages.count(), LANGUAGE_COUNT_MAX);

    languages
}
