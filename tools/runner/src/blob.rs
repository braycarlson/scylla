const BLOCK_BYTES: usize = 64;

const STATE: [u32; 5] = [
    0x6745_2301,
    0xefcd_ab89,
    0x98ba_dcfe,
    0x1032_5476,
    0xc3d2_e1f0,
];

pub fn blob_of(source: &[u8]) -> String {
    let mut message = format!("blob {}\0", source.len()).into_bytes();

    message.extend_from_slice(source);

    hex_of(&sha1_of(&message))
}

fn hex_of(digest: &[u8; 20]) -> String {
    let mut found = String::with_capacity(40);

    for byte in digest {
        found.push_str(&format!("{byte:02x}"));
    }

    found
}

fn sha1_of(message: &[u8]) -> [u8; 20] {
    let mut state = STATE;
    let mut padded = message.to_vec();
    let length = (message.len() as u64) * 8;

    padded.push(0x80);

    while padded.len() % BLOCK_BYTES != BLOCK_BYTES - 8 {
        padded.push(0);
    }

    padded.extend_from_slice(&length.to_be_bytes());

    for block in padded.as_chunks::<BLOCK_BYTES>().0 {
        compress(&mut state, block);
    }

    let mut digest = [0_u8; 20];

    for (index, word) in state.iter().enumerate() {
        digest[index * 4..index * 4 + 4].copy_from_slice(&word.to_be_bytes());
    }

    digest
}

fn compress(state: &mut [u32; 5], block: &[u8]) {
    let mut schedule = [0_u32; 80];

    for (index, word) in block.as_chunks::<4>().0.iter().enumerate() {
        schedule[index] = u32::from_be_bytes(*word);
    }

    for index in 16..80 {
        let held =
            schedule[index - 3] ^ schedule[index - 8] ^ schedule[index - 14] ^ schedule[index - 16];

        schedule[index] = held.rotate_left(1);
    }

    let mut a = state[0];
    let mut b = state[1];
    let mut c = state[2];
    let mut d = state[3];
    let mut e = state[4];

    for (index, word) in schedule.iter().enumerate() {
        let (mixed, constant) = round_of(index, b, c, d);

        let held = a
            .rotate_left(5)
            .wrapping_add(mixed)
            .wrapping_add(e)
            .wrapping_add(constant)
            .wrapping_add(*word);

        e = d;
        d = c;
        c = b.rotate_left(30);
        b = a;
        a = held;
    }

    state[0] = state[0].wrapping_add(a);
    state[1] = state[1].wrapping_add(b);
    state[2] = state[2].wrapping_add(c);
    state[3] = state[3].wrapping_add(d);
    state[4] = state[4].wrapping_add(e);
}

fn round_of(index: usize, b: u32, c: u32, d: u32) -> (u32, u32) {
    match index {
        0..=19 => ((b & c) | ((!b) & d), 0x5a82_7999),
        20..=39 => (b ^ c ^ d, 0x6ed9_eba1),
        40..=59 => ((b & c) | (b & d) | (c & d), 0x8f1b_bcdc),
        _ => (b ^ c ^ d, 0xca62_c1d6),
    }
}

#[cfg(test)]
mod tests {
    use super::blob_of;

    #[test]
    fn an_empty_blob_hashes_the_way_git_hashes_it() {
        assert_eq!(blob_of(b""), "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    }

    #[test]
    fn a_short_blob_hashes_the_way_git_hashes_it() {
        assert_eq!(
            blob_of(b"hello\n"),
            "ce013625030ba8dba906f756967f9e9ca394464a"
        );
    }
}
