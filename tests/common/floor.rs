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
pub(crate) const CORPUS_WALK_RUST: usize = 3_008;
pub(crate) const CORPUS_WALK_TYPESCRIPT: usize = 13_483;
pub(crate) const CORPUS_WALK_ZIG: usize = 249;
pub(crate) const CORPUS_SCOPE_PYTHON: usize = 4_057;
pub(crate) const CORPUS_RESOLVE_JAVASCRIPT: usize = 13_847;
pub(crate) const CORPUS_SEMANTIC_GO: usize = 7_677;
pub(crate) const CORPUS_SEMANTIC_JAVASCRIPT: usize = 13_889;
pub(crate) const CORPUS_SEMANTIC_PYTHON: usize = 4_055;
pub(crate) const CORPUS_LOSSLESS: usize = 31_723;
pub(crate) const FIXTURE_FORMAT_CSS: usize = 3;
pub(crate) const FIXTURE_FORMAT_GO: usize = 3;
pub(crate) const FIXTURE_FORMAT_JAVASCRIPT: usize = 6;
pub(crate) const FIXTURE_FORMAT_ODIN: usize = 5;
pub(crate) const FIXTURE_FORMAT_PYTHON: usize = 15;
pub(crate) const FIXTURE_FORMAT_RUST: usize = 3;
pub(crate) const FIXTURE_FORMAT_TYPESCRIPT: usize = 14;
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
pub(crate) const FIXTURE_RESOLVE_JAVASCRIPT: usize = 15;
pub(crate) const FIXTURE_SEMANTIC_GO: usize = 5;
pub(crate) const FIXTURE_SEMANTIC_JAVASCRIPT: usize = 12;
pub(crate) const FIXTURE_LOSSLESS: usize = 93;

pub(crate) struct Relation {
    pub(crate) corpus: usize,
    pub(crate) every: usize,
    pub(crate) window: usize,
}

pub(crate) const RELATION_CSS: Relation = Relation {
    corpus: 570,
    every: 5,
    window: 5,
};

pub(crate) const RELATION_GO: Relation = Relation {
    corpus: 7_678,
    every: 6,
    window: 6,
};

pub(crate) const RELATION_JAVASCRIPT: Relation = Relation {
    corpus: 378,
    every: 18,
    window: 17,
};

pub(crate) const RELATION_ODIN: Relation = Relation {
    corpus: 1_995,
    every: 5,
    window: 5,
};

pub(crate) const RELATION_PYTHON: Relation = Relation {
    corpus: 4_054,
    every: 20,
    window: 20,
};

pub(crate) const RELATION_RUST: Relation = Relation {
    corpus: 3_142,
    every: 8,
    window: 8,
};

pub(crate) const RELATION_TSX: Relation = Relation {
    corpus: 296,
    every: 6,
    window: 5,
};

pub(crate) const RELATION_TYPESCRIPT: Relation = Relation {
    corpus: 13_134,
    every: 20,
    window: 20,
};

pub(crate) const RELATION_ZIG: Relation = Relation {
    corpus: 248,
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
        held, CORPUS_PIN,
        "corpus/manifest.txt hashes to {held:#018x} and the floors were counted over {CORPUS_PIN:#018x}: \
         re-count the floors against the corpus this manifest resolves to and stamp the new pin"
    );
}

pub(crate) struct Relations {
    pub(crate) built: usize,
    pub(crate) renamed: usize,
}

pub(crate) const CORPUS_RELATIONS_GO: Relations = Relations {
    built: 7_677,
    renamed: 7_030,
};

pub(crate) const CORPUS_RELATIONS_JAVASCRIPT: Relations = Relations {
    built: 378,
    renamed: 263,
};

pub(crate) const CORPUS_RELATIONS_ODIN: Relations = Relations {
    built: 1_995,
    renamed: 1_761,
};

pub(crate) const CORPUS_RELATIONS_PYTHON: Relations = Relations {
    built: 4_054,
    renamed: 3_158,
};

pub(crate) const CORPUS_RELATIONS_RUST: Relations = Relations {
    built: 3_142,
    renamed: 2_688,
};

pub(crate) const CORPUS_RELATIONS_TYPESCRIPT: Relations = Relations {
    built: 13_134,
    renamed: 12_667,
};

pub(crate) const CORPUS_RELATIONS_ZIG: Relations = Relations {
    built: 248,
    renamed: 247,
};

pub(crate) const fn corpus_relations_of(name: &str) -> Relations {
    match name.as_bytes() {
        b"go" => CORPUS_RELATIONS_GO,
        b"javascript" => CORPUS_RELATIONS_JAVASCRIPT,
        b"odin" => CORPUS_RELATIONS_ODIN,
        b"python" => CORPUS_RELATIONS_PYTHON,
        b"rust" => CORPUS_RELATIONS_RUST,
        b"typescript" => CORPUS_RELATIONS_TYPESCRIPT,
        b"zig" => CORPUS_RELATIONS_ZIG,
        _ => panic!("no relations floor for that language"),
    }
}

pub(crate) const CORPUS_CENSUS_CSS: usize = 527;
pub(crate) const CORPUS_CENSUS_GO: usize = 7_678;
pub(crate) const CORPUS_CENSUS_JAVASCRIPT: usize = 409;
pub(crate) const CORPUS_CENSUS_ODIN: usize = 1_925;
pub(crate) const CORPUS_CENSUS_RUST: usize = 3_006;
pub(crate) const CORPUS_CENSUS_TYPESCRIPT: usize = 13_476;
pub(crate) const CORPUS_CENSUS_ZIG: usize = 248;
pub(crate) const CORPUS_FORMAT_MARKUP: usize = 514;
pub(crate) const CORPUS_MARKUP_LEX: usize = 528;
pub(crate) const CORPUS_MARKUP_TREE: usize = 528;
pub(crate) const CORPUS_SEMANTIC_CSS: usize = 581;
pub(crate) const CORPUS_POSTCSS_CSS: usize = 572;

pub(crate) struct Resolve {
    pub(crate) files: usize,
    pub(crate) rows: usize,
}

pub(crate) const CORPUS_PARSE5_MARKUP: Resolve = Resolve {
    files: 528,
    rows: 21_140,
};

pub(crate) const CORPUS_RESOLVE_ZIG: Resolve = Resolve {
    files: 249,
    rows: 90_120,
};

pub(crate) const CORPUS_RESOLVE_RUST: Resolve = Resolve {
    files: 1_959,
    rows: 202_455,
};

pub(crate) const CORPUS_RESOLVE_ODIN: Resolve = Resolve {
    files: 1_992,
    rows: 304_385,
};
