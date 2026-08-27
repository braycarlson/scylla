#![allow(
    dead_code,
    reason = "each suite that includes this module reads the floors its language owns"
)]

pub(crate) const CORPUS_PIN: u64 = 0x0989_5548_95c7_1c60;

pub(crate) const CORPUS_CLASSIFY_CSS: usize = 574;
pub(crate) const CORPUS_CLASSIFY_GO: usize = 7_725;
pub(crate) const CORPUS_CLASSIFY_JAVASCRIPT: usize = 415;
pub(crate) const CORPUS_CLASSIFY_ODIN: usize = 2_006;
pub(crate) const CORPUS_CLASSIFY_PYTHON: usize = 4_057;
pub(crate) const CORPUS_CLASSIFY_RUST: usize = 3_146;
pub(crate) const CORPUS_CLASSIFY_TYPESCRIPT: usize = 13_523;
pub(crate) const CORPUS_CLASSIFY_ZIG: usize = 248;

pub(crate) const CORPUS_CENSUS_PYTHON: usize = 4_054;

pub(crate) const CORPUS_WALK_CSS: usize = 536;
pub(crate) const CORPUS_WALK_GO: usize = 7_679;
pub(crate) const CORPUS_WALK_JAVASCRIPT: usize = 411;
pub(crate) const CORPUS_WALK_ODIN: usize = 1_943;
pub(crate) const CORPUS_WALK_PYTHON: usize = 4_057;
pub(crate) const CORPUS_WALK_RUST: usize = 3_108;
pub(crate) const CORPUS_WALK_TYPESCRIPT: usize = 13_483;
pub(crate) const CORPUS_WALK_ZIG: usize = 249;

pub(crate) const CORPUS_SCOPE_PYTHON: usize = 4_058;

pub(crate) const CORPUS_SEMANTIC_GO: usize = 7_727;
pub(crate) const CORPUS_SEMANTIC_JAVASCRIPT: usize = 13_892;
pub(crate) const CORPUS_SEMANTIC_PYTHON: usize = 4_060;

pub(crate) const CORPUS_LOSSLESS: usize = 31_723;

pub(crate) const FIXTURE_FORMAT_CSS: usize = 5;
pub(crate) const FIXTURE_FORMAT_GO: usize = 2;
pub(crate) const FIXTURE_FORMAT_JAVASCRIPT: usize = 4;
pub(crate) const FIXTURE_FORMAT_ODIN: usize = 5;
pub(crate) const FIXTURE_FORMAT_PYTHON: usize = 15;
pub(crate) const FIXTURE_FORMAT_RUST: usize = 3;
pub(crate) const FIXTURE_FORMAT_TYPESCRIPT: usize = 10;
pub(crate) const FIXTURE_FORMAT_ZIG: usize = 3;

pub(crate) const FIXTURE_WALK_CSS: usize = 5;
pub(crate) const FIXTURE_WALK_GO: usize = 6;
pub(crate) const FIXTURE_WALK_JAVASCRIPT: usize = 18;
pub(crate) const FIXTURE_WALK_ODIN: usize = 5;
pub(crate) const FIXTURE_WALK_PYTHON: usize = 20;
pub(crate) const FIXTURE_WALK_RUST: usize = 8;
pub(crate) const FIXTURE_WALK_TYPESCRIPT: usize = 26;
pub(crate) const FIXTURE_WALK_ZIG: usize = 5;

pub(crate) const FIXTURE_SCOPE_PYTHON: usize = 19;

pub(crate) const FIXTURE_SEMANTIC_GO: usize = 5;
pub(crate) const FIXTURE_SEMANTIC_JAVASCRIPT: usize = 12;

pub(crate) const FIXTURE_LOSSLESS: usize = 93;

pub(crate) struct Relation {
    pub(crate) every: usize,
    pub(crate) window: usize,
}

pub(crate) const RELATION_CSS: Relation = Relation {
    every: 5,
    window: 5,
};

pub(crate) const RELATION_GO: Relation = Relation {
    every: 6,
    window: 6,
};

pub(crate) const RELATION_JAVASCRIPT: Relation = Relation {
    every: 18,
    window: 17,
};

pub(crate) const RELATION_ODIN: Relation = Relation {
    every: 5,
    window: 5,
};

pub(crate) const RELATION_PYTHON: Relation = Relation {
    every: 20,
    window: 20,
};

pub(crate) const RELATION_RUST: Relation = Relation {
    every: 8,
    window: 8,
};

pub(crate) const RELATION_TSX: Relation = Relation {
    every: 6,
    window: 5,
};

pub(crate) const RELATION_TYPESCRIPT: Relation = Relation {
    every: 20,
    window: 20,
};

pub(crate) const RELATION_ZIG: Relation = Relation {
    every: 5,
    window: 5,
};

pub(crate) const fn pin_of(manifest: &str) -> u64 {
    let bytes = manifest.as_bytes();
    let mut held: u64 = 0xcbf2_9ce4_8422_2325;
    let mut offset = 0;

    while offset < bytes.len() {
        held ^= bytes[offset] as u64;
        held = held.wrapping_mul(0x0000_0100_0000_01b3);
        offset += 1;
    }

    held
}

#[test]
fn the_floors_name_the_corpus_they_were_counted_over() {
    let held = pin_of(include_str!("../../corpus/manifest.txt"));

    assert_eq!(
        held,
        CORPUS_PIN,
        "corpus/manifest.txt hashes to {held:#018x} and the floors were counted over {CORPUS_PIN:#018x}: \
         re-count the floors against the corpus this manifest resolves to and stamp the new pin"
    );
}
