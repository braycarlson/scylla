use crate::bounded::{Buffer, Bytes as _};
use crate::format::text::spaced;
use crate::token::{Token, TokenKind};

pub fn prefix_width(line: &[u8], width: u32) -> u32 {
    let mut held = 0;

    for byte in line {
        match byte {
            b' ' => held += 1,
            b'\t' => held += width,
            _ => break,
        }
    }

    held
}

pub fn restreamed(out: &mut Buffer, text: &[u8], width: u32) -> bool {
    let mut first = true;

    for line in text.split(|byte| *byte == b'\n') {
        if !first && !out.push_bytes(b"\n") {
            return false;
        }

        if first {
            first = false;

            if !out.push_bytes(line.trim_ascii_end()) {
                return false;
            }

            continue;
        }

        let body = line.trim_ascii();

        if body.is_empty() {
            continue;
        }

        if !spaced(out, prefix_width(line, width)) || !out.push_bytes(body) {
            return false;
        }
    }

    true
}

pub fn spilled(tokens: &[Token], source: &[u8], position: u32, close: u32) -> bool {
    let mut scan = position;

    while scan <= close {
        let token = tokens[scan as usize];

        if matches!(token.kind, TokenKind::Comment | TokenKind::String)
            && token.text(source).contains(&b'\n')
        {
            return true;
        }

        scan += 1;
    }

    false
}
