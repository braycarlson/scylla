use crate::ladder::Level;

const REPRO_BYTES_MAX: usize = 1 << 12;

pub struct Record {
    pub blob: String,
    pub language: String,
    pub level: Level,
    pub offset: u32,
    pub oracle: String,
    pub path: String,
    pub repro: Vec<u8>,
    pub signature: String,
    pub summary: String,
}

impl Record {
    pub fn line(&self) -> String {
        format!(
            concat!(
                "{{\"signature\":\"{}\",\"language\":\"{}\",\"oracle\":\"{}\",",
                "\"level\":\"{}\",\"path\":\"{}\",\"blob\":\"{}\",\"offset\":{},",
                "\"summary\":\"{}\",\"repro_bytes\":{},\"repro_clipped\":{},",
                "\"repro\":\"{}\"}}"
            ),
            escaped(&self.signature),
            escaped(&self.language),
            escaped(&self.oracle),
            self.level.name(),
            escaped(&self.path),
            escaped(&self.blob),
            self.offset,
            escaped(&self.summary),
            self.repro.len(),
            self.repro.len() > REPRO_BYTES_MAX,
            escaped(&String::from_utf8_lossy(&clipped(&self.repro))),
        )
    }
}

fn clipped(repro: &[u8]) -> Vec<u8> {
    if repro.len() <= REPRO_BYTES_MAX {
        return repro.to_vec();
    }

    repro[..REPRO_BYTES_MAX].to_vec()
}

fn escaped(text: &str) -> String {
    let mut found = String::with_capacity(text.len());

    for held in text.chars() {
        match held {
            '"' => found.push_str("\\\""),
            '\\' => found.push_str("\\\\"),
            '\n' => found.push_str("\\n"),
            '\r' => found.push_str("\\r"),
            '\t' => found.push_str("\\t"),
            other if (other as u32) < 0x20 => {
                found.push_str(&format!("\\u{:04x}", other as u32));
            }
            other => found.push(other),
        }
    }

    found
}

#[cfg(test)]
mod tests {
    use super::{escaped, Record};
    use crate::ladder::Level;

    #[test]
    fn a_row_escapes_what_json_cannot_carry_raw() {
        assert_eq!(escaped("a\"b\\c\nd"), "a\\\"b\\\\c\\nd");
    }

    #[test]
    fn a_row_names_its_signature_first() {
        let record = Record {
            blob: "abc".to_owned(),
            language: "odin".to_owned(),
            level: Level::Verdict,
            offset: 7,
            oracle: "tree-sitter".to_owned(),
            path: "held.odin".to_owned(),
            repro: b"x := 1\n".to_vec(),
            signature: "0123456789abcdef".to_owned(),
            summary: "scylla accepts and tree-sitter rejects".to_owned(),
        };

        assert!(record.line().starts_with("{\"signature\":\"0123456789abcdef\""));
    }
}
