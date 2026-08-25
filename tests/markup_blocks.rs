use scylla::markup::blocks::{self, BlockMap, TagSpecification};
use scylla::markup::tree::{self, Tree};
use scylla::markup::{self, Tokens};

const ERROR_COUNT_MAX: u32 = 1 << 10;
const NODE_COUNT_MAX: u32 = 1 << 12;
const TAG_COUNT_MAX: u32 = 1 << 11;
const TOKEN_COUNT_MAX: u32 = 1 << 14;

const SPECIFICATIONS: &[TagSpecification] = &[
    TagSpecification {
        intermediates: &[b"empty"],
        name: b"for",
    },
    TagSpecification {
        intermediates: &[b"elif", b"else"],
        name: b"if",
    },
    TagSpecification {
        intermediates: &[b"else"],
        name: b"ifequal",
    },
    TagSpecification {
        intermediates: &[b"plural"],
        name: b"blocktranslate",
    },
];

const WORDS: &[&[u8]] = &[b"elif", b"else", b"empty", b"plural"];

struct Built {
    map: BlockMap,
    source: Vec<u8>,
    tokens: Tokens,
}

impl Built {
    fn new(source: &str) -> Self {
        let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);
        let mut built = Tree::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX);
        let mut map = BlockMap::reserve(TAG_COUNT_MAX);
        let bytes = source.as_bytes().to_vec();

        markup::lex(&bytes, &mut tokens);
        tree::build(&bytes, tokens.as_slice(), &mut built);

        blocks::build(
            &bytes,
            tokens.as_slice(),
            &built,
            SPECIFICATIONS,
            WORDS,
            &mut map,
        );

        Self {
            map,
            source: bytes,
            tokens,
        }
    }

    fn intermediates(&self, name: &str) -> Vec<String> {
        let block = self
            .map
            .blocks()
            .iter()
            .find(|block| self.name_of(block.open.name_token) == name)
            .unwrap_or_else(|| panic!("the {name} block pairs"));

        self.map
            .intermediates_of(block)
            .iter()
            .map(|tag| self.name_of(tag.name_token))
            .collect()
    }

    fn names(&self) -> Vec<(String, bool)> {
        self.map
            .blocks()
            .iter()
            .map(|block| (self.name_of(block.open.name_token), block.is_closed()))
            .collect()
    }

    fn name_of(&self, token: u32) -> String {
        String::from_utf8_lossy(self.tokens.as_slice()[token as usize].text(&self.source))
            .into_owned()
    }
}

#[test]
fn a_simple_block_pairs() {
    assert_eq!(
        Built::new("{% if x %}a{% endif %}").names(),
        vec![("if".to_owned(), true)]
    );
}

#[test]
fn a_block_pairs_across_element_boundaries() {
    assert_eq!(
        Built::new("{% if x %}<div>{% endif %}</div>").names(),
        vec![("if".to_owned(), true)]
    );
}

#[test]
fn an_intermediate_attaches_without_opening_a_block_of_its_own() {
    let built = Built::new("{% for a in b %}x{% empty %}y{% endfor %}");

    assert_eq!(built.map.blocks().len(), 1);
    assert_eq!(built.intermediates("for"), ["empty"]);
}

#[test]
fn a_known_opener_with_no_end_is_reported() {
    let built = Built::new("{% if x %}body");

    assert_eq!(built.map.unmatched_openers().len(), 1);
    assert!(built.map.unmatched_closers().is_empty());
}

#[test]
fn a_single_tag_is_not_reported_as_unclosed() {
    let built = Built::new("{% django_glue_init %}{% csrf_token %}");

    assert!(built.map.unmatched_openers().is_empty());
}

#[test]
fn a_custom_tag_pairs_generically() {
    let built = Built::new("{% mytag %}body{% endmytag %}");

    assert_eq!(built.map.blocks().len(), 1);
    assert!(built.map.blocks()[0].is_closed());
}

#[test]
fn a_closer_with_no_opener_is_reported() {
    assert_eq!(Built::new("{% endif %}").map.unmatched_closers().len(), 1);
}

#[test]
fn a_legacy_block_still_pairs() {
    assert_eq!(
        Built::new("{% ifequal a b %}x{% else %}y{% endifequal %}").names(),
        vec![("ifequal".to_owned(), true)]
    );
}

#[test]
fn a_crossed_pair_is_tolerated() {
    let built = Built::new("{% if a %}{% for b in c %}{% endif %}{% endfor %}");

    assert_eq!(built.map.blocks().len(), 2);
    assert_eq!(built.map.unmatched_openers().len(), 1);
}

#[test]
fn an_intermediate_reaches_past_a_tag_that_opens_no_block() {
    let built = Built::new(
        "{% for item in items %}\n{% cycle 'a' 'b' %}\n{% empty %}\nnone\n{% endfor %}\n",
    );

    assert_eq!(built.intermediates("for"), ["empty"]);
}

#[test]
fn an_intermediate_does_not_reach_past_another_open_block() {
    let built =
        Built::new("{% for item in items %}\n{% if x %}\n{% empty %}\n{% endif %}\n{% endfor %}\n");

    assert!(built.intermediates("for").is_empty());
}

#[test]
fn the_blocks_come_back_sorted_by_span() {
    let built =
        Built::new("{% if a %}{% for b in c %}{% endfor %}{% endif %}{% if d %}{% endif %}");

    let spans: Vec<_> = built
        .map
        .blocks()
        .iter()
        .map(|block| (block.span.offset, block.span.end()))
        .collect();

    let mut sorted = spans.clone();

    sorted.sort_unstable();

    assert_eq!(spans, sorted);
}

#[test]
fn the_innermost_block_at_an_offset_is_the_shortest_that_covers_it() {
    let source = "{% if a %}{% for b in c %}X{% endfor %}{% endif %}";
    let built = Built::new(source);

    let offset = u32::try_from(source.find('X').expect("the marker is present"))
        .expect("the source is small");

    let innermost = built
        .map
        .innermost_at(offset)
        .expect("both blocks cover the marker");

    assert_eq!(built.name_of(innermost.open.name_token), "for");
}

#[test]
fn every_tag_the_tree_carries_is_collected() {
    let built =
        Built::new("{% if a %}{{ value }}{% endif %}{# note #}{% for b in c %}{% endfor %}");

    assert_eq!(built.map.tags().len(), 4);
}
