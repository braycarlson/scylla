use crate::token::{Punctuation, Token, TokenKind};

use super::walk::{Brackets, is_close, is_open, opened_by, substituting};

const SHORT_ELEMENT_MAX: u32 = 10;

pub(crate) fn branched(
    source: &[u8],
    tokens: &[Token],
    brackets: &Brackets,
    position: u32,
) -> bool {
    let mut depth = 0_u32;
    let mut scan = position;

    while scan > 0 {
        scan -= 1;

        let token = tokens[scan as usize];

        if is_close(token.kind) {
            if depth == 0 {
                if let Some(open) = brackets.open_of(scan) {
                    scan = open;

                    continue;
                }
            }

            depth += 1;

            continue;
        }

        if is_open(token.kind) || substituting(source, token) {
            if depth == 0 {
                return false;
            }

            depth -= 1;

            continue;
        }

        if depth > 0 {
            continue;
        }

        if token.text(source) == b"?" {
            return true;
        }

        if matches!(
            token.kind,
            TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
        ) {
            return false;
        }
    }

    false
}

pub(crate) fn short_elements(tokens: &[Token], open: u32, close: u32) -> bool {
    let mut depth = 0_u32;
    let mut first: Option<u32> = None;
    let mut last = open;
    let mut scan = open + 1;

    while scan <= close {
        let kind = tokens[scan as usize].kind;
        let ended =
            scan == close || depth == 0 && kind == TokenKind::Punctuation(Punctuation::Comma);

        if ended {
            if let Some(held) = first {
                let from = tokens[held as usize].offset;

                if tokens[last as usize].end() - from > SHORT_ELEMENT_MAX {
                    return false;
                }
            }

            first = None;
        } else if kind != TokenKind::Newline {
            first = first.or(Some(scan));
            last = scan;
        }

        if is_open(kind) || kind == TokenKind::BlockStart {
            depth += 1;
        } else if is_close(kind) || kind == TokenKind::BlockEnd {
            depth = depth.saturating_sub(1);
        }

        scan += 1;
    }

    true
}

pub(crate) fn opened(source: &[u8], tokens: &[Token], position: u32) -> Option<u32> {
    let close = tokens[position as usize].kind;
    let open = opened_by(close);
    let mut depth = 0_u32;
    let mut scan = position;

    loop {
        let held = tokens[scan as usize];

        let opens =
            held.kind == open || open == TokenKind::BlockStart && substituting(source, held);

        if held.kind == close {
            depth += 1;
        } else if opens {
            depth = depth.saturating_sub(1);

            if depth == 0 {
                return Some(scan);
            }
        }

        if scan == 0 {
            return None;
        }

        scan -= 1;
    }
}

pub(crate) fn opening_statement(source: &[u8], tokens: &[Token], position: u32) -> bool {
    let mut depth = 0_u32;
    let mut scan = position;

    while scan > 0 {
        scan -= 1;

        let token = tokens[scan as usize];

        if is_close(token.kind) {
            depth += 1;

            continue;
        }

        if is_open(token.kind) || substituting(source, token) {
            if depth == 0 {
                return true;
            }

            depth -= 1;

            continue;
        }

        if depth > 0 {
            continue;
        }

        if token.kind == TokenKind::Punctuation(Punctuation::Comma) {
            return false;
        }

        if matches!(
            token.kind,
            TokenKind::BlockEnd
                | TokenKind::Comment
                | TokenKind::Punctuation(Punctuation::Semicolon)
        ) {
            return true;
        }
    }

    true
}
