const OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
const PRIME: u64 = 0x0000_0100_0000_01b3;
const SEPARATOR: u64 = 0xff;

pub fn signature_of(parts: &[&str]) -> String {
    let mut held = OFFSET;

    for part in parts {
        for byte in part.as_bytes() {
            held ^= u64::from(*byte);
            held = held.wrapping_mul(PRIME);
        }

        held ^= SEPARATOR;
        held = held.wrapping_mul(PRIME);
    }

    format!("{held:016x}")
}

#[cfg(test)]
mod tests {
    use super::signature_of;

    #[test]
    fn the_same_parts_hash_the_same_way() {
        assert_eq!(signature_of(&["a", "b"]), signature_of(&["a", "b"]));
    }

    #[test]
    fn the_separator_keeps_the_parts_apart() {
        assert_ne!(signature_of(&["ab", "c"]), signature_of(&["a", "bc"]));
    }
}
