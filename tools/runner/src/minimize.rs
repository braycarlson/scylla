const ROUND_COUNT_MAX: u32 = 1 << 12;

pub fn minimized(
    signature: &str,
    source: &[u8],
    probe: &mut impl FnMut(&[u8]) -> Option<String>,
) -> Vec<u8> {
    let held = shrunk(signature, source, lines_of, probe);

    shrunk(signature, &held, tokens_of, probe)
}

fn shrunk(
    signature: &str,
    source: &[u8],
    split: fn(&[u8]) -> Vec<(usize, usize)>,
    probe: &mut impl FnMut(&[u8]) -> Option<String>,
) -> Vec<u8> {
    let mut held = source.to_vec();
    let mut granularity = 2;
    let mut rounds = 0;

    while rounds < ROUND_COUNT_MAX {
        let units = split(&held);

        if units.len() < 2 {
            return held;
        }

        let width = units.len().div_ceil(granularity);
        let mut shrank = false;
        let mut start = 0;

        while start < units.len() {
            rounds += 1;

            if rounds >= ROUND_COUNT_MAX {
                return held;
            }

            let end = (start + width).min(units.len());
            let candidate = without(&held, &units, start, end);

            if candidate.len() < held.len() && probe(&candidate).as_deref() == Some(signature) {
                held = candidate;
                shrank = true;

                break;
            }

            start = end;
        }

        if shrank {
            granularity = 2;

            continue;
        }

        if granularity >= units.len() {
            return held;
        }

        granularity = (granularity * 2).min(units.len());
    }

    held
}

fn without(source: &[u8], units: &[(usize, usize)], start: usize, end: usize) -> Vec<u8> {
    let mut found = Vec::with_capacity(source.len());

    for (index, unit) in units.iter().enumerate() {
        if index >= start && index < end {
            continue;
        }

        found.extend_from_slice(&source[unit.0..unit.1]);
    }

    found
}

fn lines_of(source: &[u8]) -> Vec<(usize, usize)> {
    let mut found = Vec::new();
    let mut start = 0;

    for (offset, byte) in source.iter().enumerate() {
        if *byte != b'\n' {
            continue;
        }

        found.push((start, offset + 1));
        start = offset + 1;
    }

    if start < source.len() {
        found.push((start, source.len()));
    }

    found
}

fn tokens_of(source: &[u8]) -> Vec<(usize, usize)> {
    let mut found = Vec::new();
    let mut start = 0;

    while start < source.len() {
        let class = class_of(source[start]);
        let mut end = start + 1;

        while end < source.len() && class_of(source[end]) == class && class != Class::Other {
            end += 1;
        }

        found.push((start, end));
        start = end;
    }

    found
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum Class {
    Blank,
    Digit,
    Other,
    Word,
}

fn class_of(byte: u8) -> Class {
    if byte.is_ascii_whitespace() {
        return Class::Blank;
    }

    if byte.is_ascii_digit() {
        return Class::Digit;
    }

    if byte.is_ascii_alphabetic() || byte == b'_' {
        return Class::Word;
    }

    Class::Other
}

#[cfg(test)]
mod tests {
    use super::minimized;

    #[test]
    fn a_shrink_keeps_only_what_holds_the_signature() {
        let mut probe = |candidate: &[u8]| {
            candidate
                .windows(3)
                .any(|window| window == b"bug")
                .then(|| "held".to_owned())
        };

        let held = minimized("held", b"one\ntwo\nbug\nfour\n", &mut probe);

        assert_eq!(held, b"bug");
    }

    #[test]
    fn a_signature_that_never_holds_shrinks_nothing() {
        let mut probe = |_: &[u8]| None;
        let held = minimized("held", b"one\ntwo\n", &mut probe);

        assert_eq!(held, b"one\ntwo\n");
    }
}
