use std::path::PathBuf;

pub(crate) struct Reader<'text> {
    pub(crate) offset: usize,
    pub(crate) text: &'text [u8],
}

pub(crate) fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

impl Reader<'_> {
    pub(crate) fn byte(&self) -> u8 {
        self.text.get(self.offset).copied().unwrap_or(0)
    }

    pub(crate) fn expect(&mut self, byte: u8) {
        self.skip();

        assert_eq!(
            self.byte(),
            byte,
            "expected `{}` at offset {}",
            byte as char,
            self.offset
        );

        self.offset += 1;
    }

    pub(crate) fn number(&mut self) -> u32 {
        self.skip();

        let start = self.offset;

        while self.byte().is_ascii_digit() {
            self.offset += 1;
        }

        assert!(self.offset > start, "expected a number at offset {start}");

        core::str::from_utf8(&self.text[start..self.offset])
            .expect("the digits are ASCII")
            .parse()
            .expect("the digits fit in u32")
    }

    pub(crate) fn skip(&mut self) {
        while self.byte().is_ascii_whitespace() {
            self.offset += 1;
        }
    }

    pub(crate) fn string(&mut self) -> String {
        self.expect(b'"');

        let mut out = String::new();

        while self.offset < self.text.len() {
            let byte = self.byte();

            self.offset += 1;

            match byte {
                b'"' => return out,
                b'\\' => {
                    let escaped = self.byte();

                    self.offset += 1;
                    out.push(escaped as char);
                }
                0 => panic!("the golden string is unterminated"),
                other => out.push(other as char),
            }
        }

        panic!("the golden string is unterminated")
    }

    pub(crate) fn take(&mut self, byte: u8) -> bool {
        self.skip();

        if self.byte() != byte {
            return false;
        }

        self.offset += 1;

        true
    }
}
