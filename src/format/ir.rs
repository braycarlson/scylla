use crate::bounded::{BoundedVec, Span, count_of};

pub const GROUP_DEPTH_MAX: u32 = 256;
pub const INDENT_DEPTH_MAX: u32 = 256;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Source {
    Arena,
    Document,
    Literal,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Element {
    BlankLine(u32),
    Dedent,
    GroupClose,
    GroupOpen,
    HardLine,
    IfBroken(Span),
    Indent,
    Line,
    SoftLine,
    Space,
    Text(Source, Span),
    Verbatim(Span),
    VerbatimArena(Span),
}

#[derive(Debug)]
pub struct Document {
    elements: BoundedVec<Element>,
    group_depth: u32,
    indent_depth: u32,
    literals: BoundedVec<&'static [u8]>,
}

impl Document {
    pub fn reserve(element_count_max: u32, literal_count_max: u32) -> Self {
        assert!(element_count_max > 0);
        assert!(literal_count_max > 0);

        assert!(!crate::allocation::is_frozen());

        Self {
            elements: BoundedVec::reserve(element_count_max),
            group_depth: 0,
            indent_depth: 0,
            literals: BoundedVec::reserve(literal_count_max),
        }
    }

    pub fn clear(&mut self) {
        self.elements.clear();
        self.group_depth = 0;
        self.indent_depth = 0;

        assert_eq!(self.count(), 0);
    }

    pub fn close(&self) {
        assert_eq!(self.group_depth, 0);
        assert_eq!(self.indent_depth, 0);
    }

    pub fn count(&self) -> u32 {
        self.elements.count()
    }

    pub fn elements(&self) -> &[Element] {
        &self.elements
    }

    pub fn literal(&mut self, bytes: &'static [u8]) -> u32 {
        assert!(!bytes.is_empty());

        let index = self.literals.count();

        assert!(self.literals.push(bytes));
        assert!(index < self.literals.count());

        index
    }

    pub fn literal_of(&self, index: u32) -> &'static [u8] {
        assert!(index < self.literals.count());

        self.literals[index as usize]
    }

    pub fn literal_span(&self, index: u32) -> Span {
        Span {
            length: count_of(self.literal_of(index).len()),
            offset: index,
        }
    }

    #[must_use]
    pub fn push(&mut self, element: Element) -> bool {
        match element {
            Element::Dedent => assert!(self.indent_depth > 0),
            Element::GroupClose => assert!(self.group_depth > 0),
            Element::GroupOpen => {
                if self.group_depth == GROUP_DEPTH_MAX {
                    return false;
                }
            }
            Element::Indent => {
                if self.indent_depth == INDENT_DEPTH_MAX {
                    return false;
                }
            }
            Element::Text(Source::Literal, span) => {
                assert!(span.offset < self.literals.count());
                assert_eq!(span.length, count_of(self.literal_of(span.offset).len()));
            }
            Element::BlankLine(_)
            | Element::HardLine
            | Element::IfBroken(_)
            | Element::Line
            | Element::SoftLine
            | Element::Space
            | Element::Text(Source::Arena | Source::Document, _)
            | Element::Verbatim(_)
            | Element::VerbatimArena(_) => (),
        }

        if !self.elements.push(element) {
            return false;
        }

        match element {
            Element::Dedent => self.indent_depth -= 1,
            Element::GroupClose => self.group_depth -= 1,
            Element::GroupOpen => self.group_depth += 1,
            Element::Indent => self.indent_depth += 1,
            Element::BlankLine(_)
            | Element::HardLine
            | Element::IfBroken(_)
            | Element::Line
            | Element::SoftLine
            | Element::Space
            | Element::Text(_, _)
            | Element::Verbatim(_)
            | Element::VerbatimArena(_) => (),
        }

        assert!(self.group_depth <= GROUP_DEPTH_MAX);
        assert!(self.indent_depth <= INDENT_DEPTH_MAX);

        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const COMMA: &[u8] = b",";

    fn reserved() -> Document {
        Document::reserve(16, 4)
    }

    fn span(offset: u32, length: u32) -> Span {
        Span { length, offset }
    }

    #[test]
    fn a_built_document_reads_back_what_went_in() {
        let mut document = reserved();
        let comma = document.literal(COMMA);

        assert_eq!(comma, 0);
        assert!(document.push(Element::GroupOpen));
        assert!(document.push(Element::Indent));
        assert!(document.push(Element::Text(Source::Document, span(0, 3))));
        assert!(document.push(Element::Text(Source::Literal, document.literal_span(comma))));
        assert!(document.push(Element::SoftLine));
        assert!(document.push(Element::Verbatim(span(4, 9))));
        assert!(document.push(Element::BlankLine(2)));
        assert!(document.push(Element::IfBroken(document.literal_span(comma))));
        assert!(document.push(Element::Dedent));
        assert!(document.push(Element::GroupClose));

        document.close();

        assert_eq!(document.count(), 10);
        assert_eq!(document.elements()[0], Element::GroupOpen);

        assert_eq!(
            document.elements()[3],
            Element::Text(Source::Literal, span(0, 1))
        );

        assert_eq!(document.elements()[6], Element::BlankLine(2));
        assert_eq!(document.literal_of(comma), COMMA);
    }

    #[test]
    fn a_cleared_document_forgets_every_element() {
        let mut document = reserved();

        assert!(document.push(Element::GroupOpen));

        document.clear();

        assert_eq!(document.count(), 0);
        assert!(document.elements().is_empty());
        assert!(document.push(Element::Space));

        document.close();
    }

    #[test]
    fn an_overflowing_push_leaves_the_arena_as_it_was() {
        let mut document = Document::reserve(2, 2);

        assert!(document.push(Element::Space));
        assert!(document.push(Element::Space));
        assert!(!document.push(Element::GroupOpen));
        assert_eq!(document.count(), 2);
        assert_eq!(document.elements(), &[Element::Space, Element::Space]);

        document.close();
    }

    #[test]
    #[should_panic(expected = "self.group_depth > 0")]
    fn an_unopened_group_close_fires_the_balance_assertion() {
        let mut document = reserved();

        assert!(document.push(Element::GroupClose));
    }

    #[test]
    #[should_panic(expected = "self.indent_depth > 0")]
    fn an_unopened_dedent_fires_the_balance_assertion() {
        let mut document = reserved();

        assert!(document.push(Element::Dedent));
    }

    #[test]
    #[should_panic(expected = "assertion `left == right` failed")]
    fn an_unclosed_group_fires_the_balance_assertion() {
        let mut document = reserved();

        assert!(document.push(Element::GroupOpen));

        document.close();
    }

    #[test]
    #[should_panic(expected = "assertion `left == right` failed")]
    fn an_unclosed_indent_fires_the_balance_assertion() {
        let mut document = reserved();

        assert!(document.push(Element::Indent));

        document.close();
    }

    #[test]
    fn a_nested_group_run_holds_its_bound() {
        let mut document = Document::reserve(1 << 10, 2);

        for _ in 0..GROUP_DEPTH_MAX {
            assert!(document.push(Element::GroupOpen));
        }

        for _ in 0..GROUP_DEPTH_MAX {
            assert!(document.push(Element::GroupClose));
        }

        document.close();

        assert_eq!(document.count(), GROUP_DEPTH_MAX * 2);
    }

    #[test]
    fn an_indent_deeper_than_the_bound_reports_the_overflow() {
        let mut document = Document::reserve(1 << 10, 2);

        for _ in 0..INDENT_DEPTH_MAX {
            assert!(document.push(Element::Indent));
        }

        assert!(!document.push(Element::Indent));

        for _ in 0..INDENT_DEPTH_MAX {
            assert!(document.push(Element::Dedent));
        }

        document.close();
    }

    #[test]
    fn a_group_deeper_than_the_bound_reports_the_overflow() {
        let mut document = Document::reserve(1 << 10, 2);

        for _ in 0..GROUP_DEPTH_MAX {
            assert!(document.push(Element::GroupOpen));
        }

        assert!(!document.push(Element::GroupOpen));

        for _ in 0..GROUP_DEPTH_MAX {
            assert!(document.push(Element::GroupClose));
        }

        document.close();
    }
}
