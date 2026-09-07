pub mod blocks;
pub mod comments;
pub mod facts;
pub mod kind;
pub mod lexer;
pub mod regions;
pub mod semantic;
pub mod token;
pub mod tree;
pub mod view;

pub use kind::{KIND_COUNT, MarkupKind};
pub use lexer::{RawTextTag, lex, lex_with};
pub use token::{Token, Tokens};
pub use tree::{NONE, Node, Structure, Tree, TreeError, TreeErrorKind};

#[derive(Clone, Copy, Debug)]
pub struct Vocabulary<'run> {
    pub end_prefix: &'run [u8],
    pub extends_tags: &'run [&'run [u8]],
    pub intermediate_words: &'run [&'run [u8]],
    pub only_word: &'run [u8],
    pub raw_text_tags: &'run [RawTextTag<'run>],
    pub specifications: &'run [blocks::TagSpecification],
}

impl Vocabulary<'_> {
    pub const EMPTY: Self = Self {
        end_prefix: b"",
        extends_tags: &[],
        intermediate_words: &[],
        only_word: b"",
        raw_text_tags: &[],
        specifications: &[],
    };
}
