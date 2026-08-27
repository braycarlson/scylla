const DEPTH_MAX: u32 = 1 << 6;

pub fn sample_of(pattern: &str) -> String {
    let bytes = pattern.as_bytes();
    let mut reader = Reader { bytes, offset: 0 };

    reader.alternation(0)
}

struct Reader<'run> {
    bytes: &'run [u8],
    offset: usize,
}

impl Reader<'_> {
    fn byte(&self) -> u8 {
        self.bytes.get(self.offset).copied().unwrap_or(0)
    }

    fn done(&self) -> bool {
        self.offset >= self.bytes.len()
    }

    fn alternation(&mut self, depth: u32) -> String {
        let mut found = self.sequence(depth);

        while !self.done() && self.byte() == b'|' {
            self.offset += 1;

            let held = self.sequence(depth);

            if held.len() < found.len() {
                found = held;
            }
        }

        found
    }

    fn sequence(&mut self, depth: u32) -> String {
        let mut found = String::new();

        while !self.done() && self.byte() != b'|' && self.byte() != b')' {
            let piece = self.piece(depth);

            found.push_str(&piece);
        }

        found
    }

    fn piece(&mut self, depth: u32) -> String {
        let atom = self.atom(depth);
        let (least, held) = self.quantifier();

        self.offset = held;

        atom.repeat(least)
    }

    fn atom(&mut self, depth: u32) -> String {
        if depth > DEPTH_MAX {
            self.offset = self.bytes.len();

            return "a".to_owned();
        }

        let byte = self.byte();

        self.offset += 1;

        match byte {
            b'(' => {
                self.group();

                let held = self.alternation(depth + 1);

                if !self.done() && self.byte() == b')' {
                    self.offset += 1;
                }

                held
            }
            b'[' => self.class(),
            b'\\' => self.escaped(),
            b'.' => "a".to_owned(),
            b'^' | b'$' => String::new(),
            other => (other as char).to_string(),
        }
    }

    fn group(&mut self) {
        if self.byte() != b'?' {
            return;
        }

        self.offset += 1;

        while !self.done() && !matches!(self.byte(), b':' | b')') {
            self.offset += 1;
        }

        if !self.done() && self.byte() == b':' {
            self.offset += 1;
        }
    }

    fn class(&mut self) -> String {
        let negated = self.byte() == b'^';

        if negated {
            self.offset += 1;
        }

        let mut named: Vec<(char, char)> = Vec::new();

        while !self.done() && self.byte() != b']' {
            let byte = self.byte();

            self.offset += 1;

            let held = if byte == b'\\' {
                self.escaped().chars().next()
            } else {
                Some(byte as char)
            };

            let Some(first) = held else {
                continue;
            };

            let ranged = !self.done()
                && self.byte() == b'-'
                && self
                    .bytes
                    .get(self.offset + 1)
                    .is_some_and(|byte| *byte != b']');

            if !ranged {
                named.push((first, first));

                continue;
            }

            self.offset += 1;

            let last = self.byte() as char;

            self.offset += 1;
            named.push((first, last));
        }

        if !self.done() {
            self.offset += 1;
        }

        if negated {
            return outside_of(&named).to_string();
        }

        named
            .first()
            .map_or_else(|| "a".to_owned(), |held| held.0.to_string())
    }

    fn escaped(&mut self) -> String {
        let byte = self.byte();

        self.offset += 1;

        match byte {
            b'd' => "0".to_owned(),
            b'n' => "\n".to_owned(),
            b'r' => "\r".to_owned(),
            b's' => " ".to_owned(),
            b't' => "\t".to_owned(),
            b'w' => "a".to_owned(),
            b'D' | b'S' | b'W' => "a".to_owned(),
            b'u' | b'x' => {
                while !self.done() && self.byte().is_ascii_hexdigit() {
                    self.offset += 1;
                }

                "a".to_owned()
            }
            b'p' | b'P' => {
                if !self.done() && self.byte() == b'{' {
                    while !self.done() && self.byte() != b'}' {
                        self.offset += 1;
                    }

                    if !self.done() {
                        self.offset += 1;
                    }
                }

                "a".to_owned()
            }
            other => (other as char).to_string(),
        }
    }

    fn quantifier(&self) -> (usize, usize) {
        if self.done() {
            return (1, self.offset);
        }

        let mut offset = self.offset;

        let least = match self.bytes[offset] {
            b'*' | b'?' => {
                offset += 1;

                0
            }
            b'+' => {
                offset += 1;

                1
            }
            b'{' => {
                offset += 1;

                let start = offset;

                while offset < self.bytes.len() && self.bytes[offset].is_ascii_digit() {
                    offset += 1;
                }

                let held = core::str::from_utf8(&self.bytes[start..offset])
                    .ok()
                    .and_then(|text| text.parse().ok())
                    .unwrap_or(1);

                while offset < self.bytes.len() && self.bytes[offset] != b'}' {
                    offset += 1;
                }

                if offset < self.bytes.len() {
                    offset += 1;
                }

                held
            }
            _ => return (1, self.offset),
        };

        if offset < self.bytes.len() && matches!(self.bytes[offset], b'?' | b'+') {
            offset += 1;
        }

        (least, offset)
    }
}

fn outside_of(named: &[(char, char)]) -> char {
    const CANDIDATES: [char; 8] = ['a', 'z', 'q', '0', '_', '.', ' ', '~'];

    for held in CANDIDATES {
        let refused = named.iter().any(|range| range.0 <= held && held <= range.1);

        if !refused {
            return held;
        }
    }

    'a'
}

#[cfg(test)]
mod tests {
    use super::sample_of;

    #[test]
    fn a_class_takes_the_first_character_it_names() {
        assert_eq!(sample_of("[a-zA-Z_]"), "a");
    }

    #[test]
    fn a_star_takes_none_and_a_plus_takes_one() {
        assert_eq!(sample_of("[a-z]+[0-9]*"), "a");
    }

    #[test]
    fn an_alternation_takes_its_shortest_branch() {
        assert_eq!(sample_of("abc|d"), "d");
    }

    #[test]
    fn an_escape_takes_the_character_it_stands_for() {
        assert_eq!(sample_of(r"\d\d"), "00");
    }

    #[test]
    fn a_counted_repeat_takes_its_least() {
        assert_eq!(sample_of("a{3,5}"), "aaa");
    }

    #[test]
    fn a_group_reads_through_its_flags() {
        assert_eq!(sample_of("(?:xy)"), "xy");
    }

    #[test]
    fn a_negated_class_takes_a_character_it_does_not_refuse() {
        assert_eq!(sample_of(r"[^abq]"), "z");
    }

    #[test]
    fn a_unicode_property_reads_as_a_letter() {
        assert_eq!(sample_of(r"\p{XID_Start}"), "a");
    }

    #[test]
    fn an_identifier_class_takes_the_underscore_it_names_first() {
        assert_eq!(sample_of(r"[_\p{XID_Start}][_\p{XID_Continue}]*"), "_");
    }
}
