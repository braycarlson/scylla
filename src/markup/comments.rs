use crate::bounded::{BoundedVec, Span, count_of};
use crate::markup::kind::MarkupKind;
use crate::markup::token::Token;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Island {
    Script,
    Style,
}

fn attribute(
    source: &[u8],
    tokens: &[Token],
    name: u32,
    out: &mut BoundedVec<Span>,
) -> (u32, bool) {
    let count = count_of(tokens.len());
    let mut index = name + 1;

    while index < count && tokens[index as usize].kind == MarkupKind::Whitespace {
        index += 1;
    }

    if index >= count || tokens[index as usize].kind != MarkupKind::Equals {
        return (name + 1, true);
    }

    index += 1;

    while index < count && tokens[index as usize].kind == MarkupKind::Whitespace {
        index += 1;
    }

    if index >= count {
        return (index, true);
    }

    let value = tokens[index as usize];

    if value.kind == MarkupKind::AttributeText {
        let pushed = island_comments(source, value.offset, value.end(), Island::Script, out);

        return (index + 1, pushed);
    }

    if value.kind != MarkupKind::Quote {
        return (index, true);
    }

    let start = value.end();
    let mut end = start;

    index += 1;

    while index < count && tokens[index as usize].kind != MarkupKind::Quote {
        end = tokens[index as usize].end();
        index += 1;
    }

    assert!(start <= end);

    (
        index,
        island_comments(source, start, end, Island::Script, out),
    )
}

fn block_end(source: &[u8], from: u32, end: u32) -> u32 {
    let mut at = from;

    while at + 1 < end {
        if source[at as usize] == b'*' && source[at as usize + 1] == b'/' {
            return at + 2;
        }

        at += 1;
    }

    end
}

fn html_comment(
    source: &[u8],
    tokens: &[Token],
    open: u32,
    out: &mut BoundedVec<Span>,
) -> (u32, bool) {
    let count = count_of(tokens.len());
    let start = tokens[open as usize].offset;
    let mut index = open + 1;

    while index < count {
        let token = tokens[index as usize];

        index += 1;

        if token.kind == MarkupKind::HTMLCommentClose {
            return (index, out.push(Span::between(start, token.end())));
        }
    }

    (
        index,
        out.push(Span::between(start, count_of(source.len()))),
    )
}

fn island(
    source: &[u8],
    tokens: &[Token],
    first: u32,
    kind: Island,
    out: &mut BoundedVec<Span>,
) -> (u32, bool) {
    let count = count_of(tokens.len());
    let wanted = tokens[first as usize].kind;
    let start = tokens[first as usize].offset;
    let mut index = first;
    let mut end = start;

    while index < count && tokens[index as usize].kind == wanted {
        end = tokens[index as usize].end();
        index += 1;
    }

    assert!(index > first);

    (index, island_comments(source, start, end, kind, out))
}

fn island_comments(
    source: &[u8],
    start: u32,
    end: u32,
    kind: Island,
    out: &mut BoundedVec<Span>,
) -> bool {
    let mut at = start;

    while at < end {
        let byte = source[at as usize];

        if byte == b'"' || byte == b'\'' || byte == b'`' {
            at = string_end(source, at, end, byte);

            continue;
        }

        if byte != b'/' || at + 1 >= end {
            at += 1;

            continue;
        }

        let next = source[at as usize + 1];

        if next == b'*' {
            let stop = block_end(source, at + 2, end);

            if !out.push(Span::between(at, stop)) {
                return false;
            }

            at = stop;

            continue;
        }

        if next == b'/' && kind == Island::Script {
            let stop = line_end(source, at, end);

            if !out.push(Span::between(at, stop)) {
                return false;
            }

            at = stop;

            continue;
        }

        at += 1;
    }

    true
}

fn line_end(source: &[u8], from: u32, end: u32) -> u32 {
    let mut at = from;

    while at < end && source[at as usize] != b'\n' {
        at += 1;
    }

    at
}

pub fn spans(source: &[u8], tokens: &[Token], out: &mut BoundedVec<Span>) -> bool {
    spans_with(source, tokens, |_| false, out)
}

pub fn spans_with(
    source: &[u8],
    tokens: &[Token],
    is_script_attribute: impl Fn(&[u8]) -> bool,
    out: &mut BoundedVec<Span>,
) -> bool {
    assert!(u32::try_from(source.len()).is_ok());

    let count = count_of(tokens.len());
    let mut index = 0;

    while index < count {
        let token = tokens[index as usize];

        let (next, pushed) = match token.kind {
            MarkupKind::AttributeName if is_script_attribute(token.text(source)) => {
                attribute(source, tokens, index, out)
            }
            MarkupKind::CommentOpen => template_comment(source, tokens, index, out),
            MarkupKind::HTMLCommentOpen => html_comment(source, tokens, index, out),
            MarkupKind::ScriptText => island(source, tokens, index, Island::Script, out),
            MarkupKind::StyleText => island(source, tokens, index, Island::Style, out),
            _ => (index + 1, true),
        };

        assert!(next > index);

        if !pushed {
            return false;
        }

        index = next;
    }

    true
}

fn string_end(source: &[u8], from: u32, end: u32, quote: u8) -> u32 {
    let mut at = from + 1;

    while at < end {
        let byte = source[at as usize];

        at += 1;

        if byte == b'\\' {
            at += 1;

            continue;
        }

        if byte == quote || (byte == b'\n' && quote != b'`') {
            return at;
        }
    }

    at.min(end)
}

fn template_comment(
    source: &[u8],
    tokens: &[Token],
    open: u32,
    out: &mut BoundedVec<Span>,
) -> (u32, bool) {
    let count = count_of(tokens.len());
    let start = tokens[open as usize].offset;
    let mut end = tokens[open as usize].end();
    let mut index = open + 1;

    while index < count {
        let token = tokens[index as usize];

        if !matches!(
            token.kind,
            MarkupKind::CommentClose | MarkupKind::CommentText
        ) {
            break;
        }

        end = token.end();
        index += 1;
    }

    assert!(end as usize <= source.len());

    (index, out.push(Span::between(start, end)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::markup::{self, Tokens};

    fn found(source: &[u8]) -> Vec<Vec<u8>> {
        let mut tokens = Tokens::reserve(1 << 10);
        let mut out = BoundedVec::reserve(1 << 6);

        markup::lex(source, &mut tokens);

        assert!(spans(source, tokens.as_slice(), &mut out));

        out.iter()
            .map(|span| source[span.range()].to_vec())
            .collect()
    }

    #[test]
    fn an_html_comment_spans_its_delimiters() {
        let held = found(b"<p>a</p><!-- noqa: X -->\n<!-- open");

        assert_eq!(held, [b"<!-- noqa: X -->".to_vec(), b"<!-- open".to_vec()]);
    }

    #[test]
    fn a_template_comment_spans_its_delimiters() {
        let held = found(b"{# one #}<p>{# two");

        assert_eq!(held, [b"{# one #}".to_vec(), b"{# two".to_vec()]);
    }

    #[test]
    fn a_script_island_yields_its_line_and_block_comments() {
        let held = found(
            b"<script>\nlet a = 'no // here'; // line\n/* block */ let b = `x//y`;\n</script>",
        );

        assert_eq!(held, [b"// line".to_vec(), b"/* block */".to_vec()]);
    }

    #[test]
    fn a_script_comment_crosses_a_split_token() {
        let held = found(b"<script>// a < b\n</script>");

        assert_eq!(held, [b"// a < b".to_vec()]);
    }

    #[test]
    fn a_style_island_yields_only_block_comments() {
        let held = found(b"<style>/* one */ a { b: url(//x) } /* two");

        assert_eq!(held, [b"/* one */".to_vec(), b"/* two".to_vec()]);
    }

    #[test]
    fn a_script_attribute_value_yields_its_comments_and_other_attributes_do_not() {
        let source: &[u8] = b"<div class=\"a // b\" x-data=\"{ open: '// {{ v }}', // note\n toggle() { /* flip */ this.open = !this.open } }\" x-on:click = 'go() // fire' title=\"/* c */\"></div>";
        let mut tokens = Tokens::reserve(1 << 10);
        let mut out = BoundedVec::reserve(1 << 6);

        markup::lex(source, &mut tokens);

        assert!(spans_with(
            source,
            tokens.as_slice(),
            |name| name.starts_with(b"x-"),
            &mut out
        ));

        let held: Vec<Vec<u8>> = out
            .iter()
            .map(|span| source[span.range()].to_vec())
            .collect();

        assert_eq!(
            held,
            [
                b"// note".to_vec(),
                b"/* flip */".to_vec(),
                b"// fire".to_vec()
            ]
        );

        out.clear();

        assert!(spans(source, tokens.as_slice(), &mut out));
        assert_eq!(out.count(), 0);
    }

    #[test]
    fn a_full_table_reports_the_overflow() {
        let source = b"{# a #}{# b #}";
        let mut tokens = Tokens::reserve(1 << 6);
        let mut out = BoundedVec::reserve(1);

        markup::lex(source, &mut tokens);

        assert!(!spans(source, tokens.as_slice(), &mut out));
        assert_eq!(out.count(), 1);
    }
}
