use crate::bounded::{BoundedVec, FixedMap};
use crate::token::{Lex, Tokens};

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum Language {
    Css,
    Go,
    JavaScript,
    Markup,
    Odin,
    Python,
    Rust,
    Tsx,
    TypeScript,
    Zig,
}

pub trait Lexer: Sync {
    fn extensions(&self) -> &'static [&'static [u8]];
    fn identifier(&self) -> &'static str;
    fn lex(&self, source: &[u8], tokens: &mut Tokens) -> Lex;
}

pub struct Languages {
    by_extension: FixedMap<u32>,
    by_identifier: FixedMap<u32>,
    lexers: BoundedVec<&'static dyn Lexer>,
}

impl Language {
    pub const COUNT: usize = 10;

    pub const EVERY: [Self; Self::COUNT] = [
        Self::Css,
        Self::Go,
        Self::JavaScript,
        Self::Markup,
        Self::Odin,
        Self::Python,
        Self::Rust,
        Self::Tsx,
        Self::TypeScript,
        Self::Zig,
    ];

    pub const fn index(self) -> usize {
        self as usize
    }

    pub fn of_name(name: &str) -> Option<Self> {
        Self::EVERY.into_iter().find(|held| held.name() == name)
    }

    #[must_use]
    pub fn dialect_of_path(self, path: &[u8]) -> Self {
        if self == Self::TypeScript && path.ends_with(b".tsx") {
            return Self::Tsx;
        }

        self
    }

    pub const fn name(self) -> &'static str {
        match self {
            Self::Css => "css",
            Self::Go => "go",
            Self::JavaScript => "javascript",
            Self::Markup => "markup",
            Self::Odin => "odin",
            Self::Python => "python",
            Self::Rust => "rust",
            Self::Tsx => "tsx",
            Self::TypeScript => "typescript",
            Self::Zig => "zig",
        }
    }
}

impl Languages {
    pub fn reserve(language_count_max: u32) -> Self {
        assert!(language_count_max > 0);

        assert!(!crate::allocation::is_frozen());

        Self {
            by_extension: FixedMap::reserve(language_count_max * 4),
            by_identifier: FixedMap::reserve(language_count_max),
            lexers: BoundedVec::reserve(language_count_max),
        }
    }

    pub fn count(&self) -> u32 {
        self.lexers.count()
    }

    pub fn extension_count_max(&self) -> u32 {
        self.by_extension.count_max()
    }

    pub fn identifier_count_max(&self) -> u32 {
        self.by_identifier.count_max()
    }

    pub fn lexer(&self, index: u32) -> &'static dyn Lexer {
        assert!(index < self.count());

        self.lexers[index as usize]
    }

    pub fn of_identifier(&self, identifier: &[u8]) -> Option<u32> {
        if identifier.is_empty() {
            return None;
        }

        self.by_identifier.get(identifier)
    }

    pub fn of_path(&self, path: &[u8], separator: fn(u8) -> bool) -> Option<u32> {
        let extension = extension_of(path, separator)?;

        self.by_extension.get(extension)
    }

    pub fn register(&mut self, lexer: &'static dyn Lexer) {
        assert!(!lexer.extensions().is_empty());

        assert!(!crate::allocation::is_frozen());

        let index = self.lexers.count();

        self.by_identifier
            .insert_assert(lexer.identifier().as_bytes(), index);

        for extension in lexer.extensions() {
            self.by_extension.insert_assert(extension, index);
        }

        self.lexers.push_assert(lexer);

        assert_eq!(self.count(), index + 1);
    }
}

pub fn extension_of(path: &[u8], separator: fn(u8) -> bool) -> Option<&[u8]> {
    let mut dot = None;
    let mut offset = 0;

    while offset < path.len() {
        if separator(path[offset]) {
            dot = None;
        }

        if path[offset] == b'.' {
            dot = Some(offset);
        }

        offset += 1;
    }

    let found = dot?;

    if found + 1 >= path.len() {
        return None;
    }

    Some(&path[found + 1..])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lex::{PYTHON, RUST, ZIG};

    fn is_separator(byte: u8) -> bool {
        byte == b'/' || byte == b'\\'
    }

    fn is_slash(byte: u8) -> bool {
        byte == b'/'
    }

    #[test]
    fn an_extension_comes_from_the_last_dot() {
        assert_eq!(
            extension_of(b"file:///tmp/main.rs", is_slash),
            Some(&b"rs"[..])
        );

        assert_eq!(extension_of(b"/a.b/main.py", is_slash), Some(&b"py"[..]));
        assert_eq!(extension_of(b"/a.b/Makefile", is_slash), None);
        assert_eq!(extension_of(b"main.", is_slash), None);
        assert_eq!(extension_of(b"", is_slash), None);

        assert_eq!(extension_of(br"C:\v1.2\Makefile", is_separator), None);

        assert_eq!(
            extension_of(br"C:\v1.2\Makefile", is_slash),
            Some(&br"2\Makefile"[..])
        );

        assert_eq!(
            extension_of(br"C:\work\main.rs", is_separator),
            Some(&b"rs"[..])
        );
    }

    #[test]
    fn the_extension_map_reserves_four_extensions_a_language() {
        let languages = Languages::reserve(8);

        assert_eq!(languages.extension_count_max(), 32);
        assert_eq!(languages.identifier_count_max(), 8);
    }

    #[test]
    fn a_registry_maps_extensions_to_lexers() {
        let mut languages = Languages::reserve(8);

        languages.register(&RUST);
        languages.register(&ZIG);
        languages.register(&PYTHON);

        assert_eq!(languages.count(), 3);

        let index = languages
            .of_path(b"file:///tmp/main.rs", is_slash)
            .expect("rust is registered");

        assert_eq!(languages.lexer(index).identifier(), "rust");

        assert!(
            languages
                .of_path(b"file:///tmp/main.go", is_slash)
                .is_none()
        );
    }

    #[test]
    #[should_panic(expected = "inserted")]
    fn a_duplicate_registration_is_rejected() {
        let mut languages = Languages::reserve(8);

        languages.register(&RUST);
        languages.register(&RUST);
    }
}
