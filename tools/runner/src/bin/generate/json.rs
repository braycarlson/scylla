use std::collections::HashMap;

const DEPTH_MAX: u32 = 1 << 8;

#[derive(Debug)]
#[allow(
    dead_code,
    reason = "the parser reads every JSON value, and the generator reads the half of them a \
              grammar carries"
)]
pub enum Value {
    Array(Vec<Value>),
    Bool(bool),
    Null,
    Number(f64),
    Object(HashMap<String, Value>),
    Text(String),
}

impl Value {
    pub fn get(&self, key: &str) -> Option<&Self> {
        match self {
            Self::Object(held) => held.get(key),
            Self::Array(_) | Self::Bool(_) | Self::Null | Self::Number(_) | Self::Text(_) => None,
        }
    }

    pub fn text(&self) -> Option<&str> {
        match self {
            Self::Text(held) => Some(held),
            Self::Array(_) | Self::Bool(_) | Self::Null | Self::Number(_) | Self::Object(_) => None,
        }
    }
}

pub fn parse(text: &str) -> Result<Value, String> {
    let bytes = text.as_bytes();
    let mut reader = Reader { bytes, offset: 0 };
    let held = reader.value(0)?;

    reader.blank();

    if reader.offset != bytes.len() {
        return Err(format!("trailing bytes at {}", reader.offset));
    }

    Ok(held)
}

struct Reader<'run> {
    bytes: &'run [u8],
    offset: usize,
}

impl Reader<'_> {
    fn blank(&mut self) {
        while self.byte().is_ascii_whitespace() {
            self.offset += 1;
        }
    }

    fn byte(&self) -> u8 {
        self.bytes.get(self.offset).copied().unwrap_or(0)
    }

    fn expect(&mut self, byte: u8) -> Result<(), String> {
        self.blank();

        if self.byte() != byte {
            return Err(format!(
                "expected `{}` at {}",
                byte as char, self.offset
            ));
        }

        self.offset += 1;

        Ok(())
    }

    fn take(&mut self, byte: u8) -> bool {
        self.blank();

        if self.byte() != byte {
            return false;
        }

        self.offset += 1;

        true
    }

    fn value(&mut self, depth: u32) -> Result<Value, String> {
        if depth > DEPTH_MAX {
            return Err(format!("the document nests deeper than {DEPTH_MAX}"));
        }

        self.blank();

        match self.byte() {
            b'{' => self.object(depth),
            b'[' => self.array(depth),
            b'"' => Ok(Value::Text(self.text()?)),
            b't' => self.literal("true", Value::Bool(true)),
            b'f' => self.literal("false", Value::Bool(false)),
            b'n' => self.literal("null", Value::Null),
            _ => self.number(),
        }
    }

    fn array(&mut self, depth: u32) -> Result<Value, String> {
        self.expect(b'[')?;

        let mut found = Vec::new();

        if self.take(b']') {
            return Ok(Value::Array(found));
        }

        loop {
            found.push(self.value(depth + 1)?);

            if self.take(b',') {
                continue;
            }

            self.expect(b']')?;

            return Ok(Value::Array(found));
        }
    }

    fn object(&mut self, depth: u32) -> Result<Value, String> {
        self.expect(b'{')?;

        let mut found = HashMap::new();

        if self.take(b'}') {
            return Ok(Value::Object(found));
        }

        loop {
            self.blank();

            let key = self.text()?;

            self.expect(b':')?;
            found.insert(key, self.value(depth + 1)?);

            if self.take(b',') {
                continue;
            }

            self.expect(b'}')?;

            return Ok(Value::Object(found));
        }
    }

    fn literal(&mut self, name: &str, held: Value) -> Result<Value, String> {
        if !self.bytes[self.offset..].starts_with(name.as_bytes()) {
            return Err(format!("expected `{name}` at {}", self.offset));
        }

        self.offset += name.len();

        Ok(held)
    }

    fn number(&mut self) -> Result<Value, String> {
        let start = self.offset;

        while matches!(self.byte(), b'-' | b'+' | b'.' | b'e' | b'E' | b'0'..=b'9') {
            self.offset += 1;
        }

        if start == self.offset {
            return Err(format!("expected a value at {start}"));
        }

        core::str::from_utf8(&self.bytes[start..self.offset])
            .map_err(|error| format!("the number at {start} is not text: {error}"))?
            .parse()
            .map(Value::Number)
            .map_err(|error| format!("the number at {start} does not parse: {error}"))
    }

    fn text(&mut self) -> Result<String, String> {
        self.expect(b'"')?;

        let mut found = String::new();

        while self.offset < self.bytes.len() {
            let byte = self.byte();

            self.offset += 1;

            if byte == b'"' {
                return Ok(found);
            }

            if byte != b'\\' {
                found.push(byte as char);

                continue;
            }

            let escaped = self.byte();

            self.offset += 1;

            match escaped {
                b'b' => found.push('\u{8}'),
                b'f' => found.push('\u{c}'),
                b'n' => found.push('\n'),
                b'r' => found.push('\r'),
                b't' => found.push('\t'),
                b'u' => found.push(self.escape()?),
                other => found.push(other as char),
            }
        }

        Err("the string is unterminated".to_owned())
    }

    fn escape(&mut self) -> Result<char, String> {
        if self.offset + 4 > self.bytes.len() {
            return Err(format!("the escape at {} is short", self.offset));
        }

        let digits = core::str::from_utf8(&self.bytes[self.offset..self.offset + 4])
            .map_err(|error| format!("the escape at {} is not text: {error}", self.offset))?;

        let point = u32::from_str_radix(digits, 16)
            .map_err(|error| format!("the escape at {} is not hex: {error}", self.offset))?;

        self.offset += 4;

        char::from_u32(point).ok_or_else(|| format!("`{digits}` names no character"))
    }
}

#[cfg(test)]
mod tests {
    use super::{parse, Value};

    #[test]
    fn an_object_reads_its_members_back() {
        let held = parse(r#"{"type":"STRING","value":"held"}"#).expect("the object parses");

        assert_eq!(held.get("value").and_then(Value::text), Some("held"));
    }

    #[test]
    fn a_nested_array_reads_back_in_order() {
        let held =
            parse(r#"{"members":[{"type":"BLANK"},{"type":"SEQ"}]}"#).expect("the object parses");

        let Some(Value::Array(members)) = held.get("members") else {
            panic!("the members are an array");
        };

        assert_eq!(members.len(), 2);
        assert_eq!(members[0].get("type").and_then(Value::text), Some("BLANK"));
    }

    #[test]
    fn an_escape_reads_back_as_one_character() {
        let held = parse(r#"{"value":"a\nbA"}"#).expect("the object parses");

        assert_eq!(held.get("value").and_then(Value::text), Some("a\nbA"));
    }

    #[test]
    fn trailing_bytes_are_refused() {
        assert!(parse("{} {}").is_err());
    }
}
