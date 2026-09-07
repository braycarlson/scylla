use crate::bounded::{BoundedVec, Bytes as _, Span, count_of};
use crate::lines::{Encoding, Index, Position};
use crate::scan::{DECIMAL_BYTES_MAX, decimal_write};

pub const FIELDS: u32 = 5;

#[derive(Debug)]
pub struct Cache {
    issued: u64,
    slots: BoundedVec<Cached>,
}

#[derive(Debug)]
struct Cached {
    data: BoundedVec<Encoded>,
    result_id: u64,
    uri: BoundedVec<u8>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Edit {
    pub delete_count: u32,
    pub inserted_end: u32,
    pub inserted_start: u32,
    pub start: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Encoded {
    pub delta_line: u32,
    pub delta_start: u32,
    pub kind: u32,
    pub length: u32,
    pub modifiers: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Token {
    pub kind: u32,
    pub modifiers: u32,
    pub span: Span,
}

impl Cache {
    pub fn matching(&self, uri: &[u8], result_id: &[u8]) -> Option<&[Encoded]> {
        let held = self.slots.iter().find(|held| &*held.uri == uri)?;

        if !spells(held.result_id, result_id) {
            return None;
        }

        Some(&held.data)
    }

    pub fn remember(&mut self, uri: &[u8], data: &[Encoded]) -> u64 {
        assert!(!uri.is_empty());

        self.issued += 1;

        let row = self
            .slots
            .iter()
            .position(|held| &*held.uri == uri)
            .or_else(|| self.slots.iter().position(|held| held.uri.is_empty()));

        let Some(at) = row else {
            return self.issued;
        };

        let held = &mut self.slots[at];

        held.result_id = self.issued;
        held.uri.clear();
        held.data.clear();

        if !held.uri.push_bytes(uri) {
            held.uri.clear();

            return self.issued;
        }

        for token in data {
            if !held.data.push(*token) {
                break;
            }
        }

        self.issued
    }

    pub fn remove(&mut self, uri: &[u8]) {
        let Some(row) = self.slots.iter().position(|held| &*held.uri == uri) else {
            return;
        };

        self.slots[row].uri.clear();
        self.slots[row].data.clear();

        assert!(self.slots[row].uri.is_empty());
    }

    pub fn reserve(open_count_max: u32, token_count_max: u32, uri_bytes_max: u32) -> Self {
        assert!(open_count_max > 0);
        assert!(token_count_max > 0);
        assert!(!crate::allocation::is_frozen());

        let mut slots = BoundedVec::reserve(open_count_max);

        for _ in 0..open_count_max {
            slots.push_assert(Cached {
                data: BoundedVec::reserve(token_count_max),
                result_id: 0,
                uri: BoundedVec::reserve(uri_bytes_max),
            });
        }

        Self { issued: 0, slots }
    }
}

pub fn dedup_by_span(out: &mut BoundedVec<Token>) {
    let mut write = 0_usize;
    let mut previous: Option<Span> = None;

    for index in 0..out.len() {
        let token = out[index];

        if previous == Some(token.span) {
            assert!(write > 0);

            let kept = &mut out[write - 1];

            if kept.modifiers == 0 && token.modifiers != 0 {
                *kept = token;
            }

            continue;
        }

        previous = Some(token.span);
        out[write] = token;
        write += 1;
    }

    out.truncate(count_of(write));
}

pub fn edit_of(before: &[Encoded], after: &[Encoded]) -> Option<Edit> {
    let shortest = before.len().min(after.len());
    let mut head = 0_usize;

    while head < shortest && before[head] == after[head] {
        head += 1;
    }

    let mut tail = 0_usize;

    while tail < shortest - head && before[before.len() - tail - 1] == after[after.len() - tail - 1]
    {
        tail += 1;
    }

    let deleted = before.len() - head - tail;
    let inserted_end = after.len() - tail;

    if deleted == 0 && inserted_end <= head {
        return None;
    }

    assert!(head <= inserted_end);

    Some(Edit {
        delete_count: count_of(deleted) * FIELDS,
        inserted_end: count_of(inserted_end),
        inserted_start: count_of(head),
        start: count_of(head) * FIELDS,
    })
}

pub fn encode(
    tokens: &[Token],
    lines: &Index,
    source: &[u8],
    encoding: Encoding,
    out: &mut BoundedVec<Encoded>,
) -> bool {
    out.clear();

    let mut previous = Position::default();
    let mut room = true;

    for token in tokens {
        let start = lines.position_clamped(source, token.span.offset, encoding);
        let end = lines.position_clamped(source, token.span.end(), encoding);

        if end.line != start.line {
            continue;
        }

        assert!(start.line >= previous.line);

        let delta_line = start.line - previous.line;

        let delta_start = if delta_line == 0 {
            start.character.saturating_sub(previous.character)
        } else {
            start.character
        };

        room = out.push(Encoded {
            delta_line,
            delta_start,
            kind: token.kind,
            length: end.character.saturating_sub(start.character),
            modifiers: token.modifiers,
        }) && room;

        previous = start;
    }

    room
}

pub fn normalised(out: &mut BoundedVec<Token>, scratch: &mut BoundedVec<Token>) -> bool {
    retain_non_empty(out);

    out.sort_unstable_by_key(|token| (token.span.offset, token.span.end()));

    dedup_by_span(out);

    resolve_overlaps(out, scratch)
}

pub fn resolve_overlaps(out: &mut BoundedVec<Token>, scratch: &mut BoundedVec<Token>) -> bool {
    scratch.clear();

    out.sort_unstable_by_key(|token| (token.span.offset, u32::MAX - token.span.end()));

    let mut room = true;

    for at in 0..out.len() {
        let token = out[at];
        let mut cut = token.span.offset;

        for inner in out.iter().skip(at + 1) {
            if inner.span.offset >= token.span.end() {
                break;
            }

            if inner.span.end() <= token.span.end() {
                if cut < inner.span.offset {
                    room = push_cut(scratch, token, cut, inner.span.offset) && room;
                }

                cut = cut.max(inner.span.end());
            }
        }

        if cut < token.span.end() {
            room = push_cut(scratch, token, cut, token.span.end()) && room;
        }
    }

    scratch.sort_unstable_by_key(|token| (token.span.offset, token.span.end()));

    out.clear();

    for token in scratch.iter() {
        room = out.push(*token) && room;
    }

    room
}

pub fn retain_non_empty(out: &mut BoundedVec<Token>) {
    let mut write = 0_usize;

    for index in 0..out.len() {
        let token = out[index];

        if token.span.length == 0 {
            continue;
        }

        out[write] = token;
        write += 1;
    }

    out.truncate(count_of(write));
}

fn push_cut(out: &mut BoundedVec<Token>, token: Token, start: u32, end: u32) -> bool {
    assert!(start < end);

    out.push(Token {
        kind: token.kind,
        modifiers: token.modifiers,
        span: Span::between(start, end),
    })
}

fn spells(issued: u64, quoted: &[u8]) -> bool {
    let mut held = [0_u8; DECIMAL_BYTES_MAX];
    let width = decimal_write(&mut held, issued);

    &held[..width] == quoted
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::allocation;

    const OPEN_COUNT_MAX: u32 = 2;
    const TOKEN_COUNT_MAX: u32 = 64;
    const URI_BYTES_MAX: u32 = 256;

    fn cache() -> Cache {
        Cache::reserve(OPEN_COUNT_MAX, TOKEN_COUNT_MAX, URI_BYTES_MAX)
    }

    fn encoded(line: u32, start: u32) -> Encoded {
        Encoded {
            delta_line: line,
            delta_start: start,
            kind: 0,
            length: 1,
            modifiers: 0,
        }
    }

    fn token(start: u32, end: u32, kind: u32, modifiers: u32) -> Token {
        Token {
            kind,
            modifiers,
            span: Span::between(start, end),
        }
    }

    fn spans_of(out: &BoundedVec<Token>) -> Vec<(u32, u32, u32)> {
        out.iter()
            .map(|token| (token.span.offset, token.span.end(), token.kind))
            .collect()
    }

    #[test]
    fn a_remembered_set_reads_back_under_the_id_it_was_issued() {
        let mut held = cache();
        let data = [encoded(0, 0), encoded(1, 0)];

        allocation::frozen(|| {
            assert_eq!(held.remember(b"file:///one.html", &data), 1);

            let quoted = held
                .matching(b"file:///one.html", b"1")
                .expect("the id matches");

            assert_eq!(quoted, data.as_slice());

            held.remember(b"file:///one.html", &[encoded(0, 1)]);

            assert!(held.matching(b"file:///one.html", b"1").is_none());
            assert!(held.matching(b"file:///one.html", b"2").is_some());

            held.remove(b"file:///one.html");

            assert!(held.matching(b"file:///one.html", b"2").is_none());
        });
    }

    #[test]
    fn a_full_cache_still_issues_ids_but_remembers_nothing_new() {
        let mut held = cache();

        allocation::frozen(|| {
            assert_eq!(held.remember(b"file:///a", &[encoded(0, 0)]), 1);
            assert_eq!(held.remember(b"file:///b", &[encoded(0, 0)]), 2);
            assert_eq!(held.remember(b"file:///c", &[encoded(0, 0)]), 3);
            assert!(held.matching(b"file:///c", b"3").is_none());
            assert!(held.matching(b"file:///a", b"1").is_some());

            held.remove(b"file:///a");

            assert_eq!(held.remember(b"file:///c", &[encoded(0, 0)]), 4);
            assert!(held.matching(b"file:///c", b"4").is_some());
        });
    }

    #[test]
    fn a_set_wider_than_the_slot_keeps_what_fit() {
        let mut held = Cache::reserve(1, 2, URI_BYTES_MAX);
        let data = [encoded(0, 0), encoded(1, 0), encoded(2, 0)];

        allocation::frozen(|| {
            held.remember(b"file:///a", &data);

            let kept = held.matching(b"file:///a", b"1").expect("the id matches");

            assert_eq!(kept, &data[..2]);
        });

        let mut narrow = Cache::reserve(1, 2, 4);

        allocation::frozen(|| {
            assert_eq!(narrow.remember(b"file:///long", &data), 1);
            assert!(narrow.matching(b"file:///long", b"1").is_none());
        });
    }

    #[test]
    fn two_sets_that_differ_name_one_run() {
        let same = [encoded(0, 0), encoded(1, 0)];

        assert_eq!(edit_of(&same, &same), None);

        let before = [encoded(0, 0), encoded(1, 0), encoded(2, 0)];
        let after = [encoded(0, 0), encoded(1, 5), encoded(2, 0)];

        assert_eq!(
            edit_of(&before, &after),
            Some(Edit {
                delete_count: 5,
                inserted_end: 2,
                inserted_start: 1,
                start: 5,
            })
        );

        assert_eq!(
            edit_of(&before[..1], &before[..2]),
            Some(Edit {
                delete_count: 0,
                inserted_end: 2,
                inserted_start: 1,
                start: 5,
            })
        );

        assert_eq!(
            edit_of(&before[..2], &before[..1]),
            Some(Edit {
                delete_count: 5,
                inserted_end: 1,
                inserted_start: 1,
                start: 5,
            })
        );
    }

    #[test]
    fn an_id_spells_itself_in_decimal() {
        assert!(spells(1, b"1"));
        assert!(spells(0, b"0"));
        assert!(spells(1_234, b"1234"));
        assert!(!spells(12, b"1"));
        assert!(!spells(1, b"01"));
    }

    #[test]
    fn tokens_encode_as_deltas_and_skip_multi_line_spans() {
        const SOURCE: &[u8] = b"ab cd\nef\n";

        let mut lines = Index::reserve(8);
        let mut out = BoundedVec::reserve(8);

        assert!(lines.build(SOURCE));

        let tokens = [
            token(0, 2, 1, 0),
            token(3, 5, 2, 1),
            token(4, 7, 3, 0),
            token(6, 8, 4, 0),
        ];

        allocation::frozen(|| {
            assert!(encode(&tokens, &lines, SOURCE, Encoding::Utf16, &mut out));
        });

        assert_eq!(
            &*out,
            &[
                Encoded {
                    delta_line: 0,
                    delta_start: 0,
                    kind: 1,
                    length: 2,
                    modifiers: 0,
                },
                Encoded {
                    delta_line: 0,
                    delta_start: 3,
                    kind: 2,
                    length: 2,
                    modifiers: 1,
                },
                Encoded {
                    delta_line: 1,
                    delta_start: 0,
                    kind: 4,
                    length: 2,
                    modifiers: 0,
                },
            ]
        );

        let mut narrow = BoundedVec::reserve(1);

        assert!(!encode(&tokens, &lines, SOURCE, Encoding::Utf16, &mut narrow));
        assert_eq!(narrow.count(), 1);
    }

    #[test]
    fn a_normalised_table_is_sorted_deduplicated_and_cut_around_inner_spans() {
        let mut out = BoundedVec::reserve(16);
        let mut scratch = BoundedVec::reserve(16);

        out.push_assert(token(0, 10, 1, 0));
        out.push_assert(token(2, 4, 2, 0));
        out.push_assert(token(6, 6, 9, 0));
        out.push_assert(token(2, 4, 2, 1));
        out.push_assert(token(8, 12, 3, 0));

        allocation::frozen(|| {
            assert!(normalised(&mut out, &mut scratch));
        });

        assert_eq!(
            spans_of(&out),
            vec![(0, 2, 1), (2, 4, 2), (4, 10, 1), (8, 12, 3)]
        );

        assert_eq!(out[1].modifiers, 1);
    }

    #[test]
    fn a_table_that_outgrows_its_scratch_reports_the_loss() {
        let mut out = BoundedVec::reserve(4);
        let mut scratch = BoundedVec::reserve(2);

        out.push_assert(token(0, 10, 1, 0));
        out.push_assert(token(2, 4, 2, 0));
        out.push_assert(token(6, 8, 3, 0));

        allocation::frozen(|| {
            assert!(!normalised(&mut out, &mut scratch));
        });

        assert_eq!(out.count(), 2);
    }
}
