use crate::bounded::{BoundedVec, Span, count_of};
use crate::markup::kind::MarkupKind;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Token {
    pub kind: MarkupKind,
    pub length: u32,
    pub offset: u32,
}

#[derive(Debug)]
pub struct Tokens {
    end_previous: u32,
    items: BoundedVec<Token>,
}

impl crate::tree::Positioned for Token {
    fn end(&self) -> u32 {
        Self::end(self)
    }

    fn offset(&self) -> u32 {
        self.offset
    }
}

impl Token {
    pub const fn end(&self) -> u32 {
        self.offset + self.length
    }

    pub const fn span(&self) -> Span {
        Span {
            length: self.length,
            offset: self.offset,
        }
    }

    pub fn text<'source>(&self, source: &'source [u8]) -> &'source [u8] {
        let end = self.end() as usize;

        assert!(end <= source.len());

        &source[self.offset as usize..end]
    }
}

impl Tokens {
    pub fn reserve(token_count_max: u32) -> Self {
        assert!(token_count_max > 0);

        assert!(!crate::allocation::is_frozen());

        Self {
            end_previous: 0,
            items: BoundedVec::reserve(token_count_max),
        }
    }

    pub fn as_slice(&self) -> &[Token] {
        &self.items
    }

    pub fn clear(&mut self) {
        self.items.clear();
        self.end_previous = 0;

        assert_eq!(self.items.count(), 0);
    }

    pub fn count(&self) -> u32 {
        self.items.count()
    }

    pub const fn count_max(&self) -> u32 {
        self.items.capacity()
    }

    pub fn is_full(&self) -> bool {
        self.items.is_full()
    }

    #[must_use]
    pub fn push(&mut self, kind: MarkupKind, offset: u32, end: u32) -> bool {
        assert!(kind.is_token());

        if end <= offset {
            return true;
        }

        assert_eq!(offset, self.end_previous);

        if !self.items.push(Token {
            kind,
            length: end - offset,
            offset,
        }) {
            return false;
        }

        self.end_previous = end;

        true
    }

    pub(crate) const fn end_previous(&self) -> u32 {
        self.end_previous
    }
}

pub(crate) fn length_of(source: &[u8]) -> u32 {
    assert!(u32::try_from(source.len()).is_ok());

    count_of(source.len())
}
