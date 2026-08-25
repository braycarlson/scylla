use crate::bounded::{BoundedVec, Span};
use crate::markup::kind::MarkupKind;
use crate::markup::token::Token;
use crate::markup::tree::{NONE, Tree};
use crate::markup::view::View;

pub const BLOCK_DEPTH_MAX: u32 = 128;
pub const INTERMEDIATE_COUNT_MAX: u32 = 32;
pub const PAIRING_LOOKBACK_MAX: u32 = 64;
const END_PREFIX: &[u8] = b"end";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TagSpecification {
    pub intermediates: &'static [&'static [u8]],
    pub name: &'static [u8],
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TagRef {
    pub name_token: u32,
    pub span: Span,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Block {
    pub close: TagRef,
    pub intermediate_count: u32,
    pub intermediate_first: u32,
    pub open: TagRef,
    pub span: Span,
}

#[derive(Debug)]
pub struct BlockMap {
    blocks: BoundedVec<Block>,
    intermediates: BoundedVec<TagRef>,
    scratch: BoundedVec<TagRef>,
    stack: BoundedVec<OpenBlock>,
    tags: BoundedVec<TagRef>,
    unmatched_closers: BoundedVec<TagRef>,
    unmatched_openers: BoundedVec<TagRef>,
}

#[derive(Clone, Copy, Debug)]
struct OpenBlock {
    intermediate_count: u32,
    known: bool,
    open: TagRef,
}

impl TagRef {
    pub const NONE: Self = Self {
        name_token: NONE,
        span: Span::EMPTY,
    };

    pub const fn is_none(self) -> bool {
        self.name_token == NONE
    }

    pub fn name<'source>(self, tokens: &[Token], source: &'source [u8]) -> &'source [u8] {
        if self.is_none() {
            return &[];
        }

        tokens[self.name_token as usize].text(source)
    }
}

impl Block {
    pub const fn is_closed(&self) -> bool {
        !self.close.is_none()
    }
}

impl BlockMap {
    pub fn reserve(tag_count_max: u32) -> Self {
        assert!(tag_count_max > 0);

        assert!(!crate::allocation::is_frozen());

        let mut scratch = BoundedVec::reserve(BLOCK_DEPTH_MAX * INTERMEDIATE_COUNT_MAX);

        for _ in 0..scratch.capacity() {
            scratch.push_assert(TagRef::NONE);
        }

        Self {
            blocks: BoundedVec::reserve(tag_count_max),
            intermediates: BoundedVec::reserve(tag_count_max),
            scratch,
            stack: BoundedVec::reserve(BLOCK_DEPTH_MAX),
            tags: BoundedVec::reserve(tag_count_max),
            unmatched_closers: BoundedVec::reserve(tag_count_max),
            unmatched_openers: BoundedVec::reserve(tag_count_max),
        }
    }

    pub fn blocks(&self) -> &[Block] {
        &self.blocks
    }

    pub fn clear(&mut self) {
        self.blocks.clear();
        self.intermediates.clear();
        self.stack.clear();
        self.tags.clear();
        self.unmatched_closers.clear();
        self.unmatched_openers.clear();

        assert_eq!(self.blocks.count(), 0);

        assert_eq!(
            self.scratch.count(),
            BLOCK_DEPTH_MAX * INTERMEDIATE_COUNT_MAX
        );
    }

    pub fn innermost_at(&self, offset: u32) -> Option<&Block> {
        self.blocks
            .iter()
            .filter(|block| block.span.offset <= offset && offset < block.span.end())
            .min_by_key(|block| block.span.length)
    }

    pub fn intermediates_of(&self, block: &Block) -> &[TagRef] {
        let first = block.intermediate_first as usize;
        let end = first + block.intermediate_count as usize;

        assert!(end <= self.intermediates.count() as usize);

        &self.intermediates[first..end]
    }

    pub fn tags(&self) -> &[TagRef] {
        &self.tags
    }

    pub fn unmatched_closers(&self) -> &[TagRef] {
        &self.unmatched_closers
    }

    pub fn unmatched_openers(&self) -> &[TagRef] {
        &self.unmatched_openers
    }
}

struct Pairer<'run> {
    map: &'run mut BlockMap,
    source: &'run [u8],
    specifications: &'run [TagSpecification],
    tokens: &'run [Token],
    words: &'run [&'run [u8]],
}

impl Pairer<'_> {
    fn attach_intermediate(&mut self, tag: TagRef) -> bool {
        let Some(at) = self.innermost_known() else {
            return false;
        };

        let open = self.map.stack[at as usize];

        let Some(specification) = self.specification_of(open.open) else {
            return false;
        };

        let name = tag.name(self.tokens, self.source);

        if !specification.intermediates.contains(&name) {
            return false;
        }

        if open.intermediate_count >= INTERMEDIATE_COUNT_MAX {
            return true;
        }

        let slot = at * INTERMEDIATE_COUNT_MAX + open.intermediate_count;

        self.map.scratch[slot as usize] = tag;
        self.map.stack[at as usize].intermediate_count = open.intermediate_count + 1;

        true
    }

    fn close(&mut self, tag: TagRef, target: &[u8]) {
        let Some(depth) = self.find_open(target) else {
            let _ = self.map.unmatched_closers.push(tag);

            return;
        };

        for _ in 0..depth {
            let Some(open) = self.map.stack.pop() else {
                break;
            };

            self.push_unclosed(open);
        }

        let Some(open) = self.map.stack.pop() else {
            return;
        };

        let (first, count) = self.harvest(self.map.stack.count(), open.intermediate_count);

        let span = Span {
            length: tag.span.end() - open.open.span.offset,
            offset: open.open.span.offset,
        };

        let _ = self.map.blocks.push(Block {
            close: tag,
            intermediate_count: count,
            intermediate_first: first,
            open: open.open,
            span,
        });
    }

    fn find_open(&self, target: &[u8]) -> Option<u32> {
        let mut seen = 0;
        let mut index = self.map.stack.count();

        while index > 0 {
            if seen >= PAIRING_LOOKBACK_MAX {
                return None;
            }

            index -= 1;

            let open = self.map.stack[index as usize];

            if open.open.name(self.tokens, self.source) == target {
                return Some(seen);
            }

            seen += 1;
        }

        None
    }

    fn finish(&mut self) {
        while let Some(open) = self.map.stack.pop() {
            self.push_unclosed(open);
        }

        self.map
            .blocks
            .sort_unstable_by_key(|block| (block.span.offset, block.span.end()));

        self.map
            .unmatched_openers
            .sort_unstable_by_key(|tag| tag.span.offset);
    }

    fn harvest(&mut self, frame: u32, count: u32) -> (u32, u32) {
        let first = self.map.intermediates.count();
        let mut moved = 0;

        for slot in 0..count {
            let index = frame * INTERMEDIATE_COUNT_MAX + slot;
            let tag = self.map.scratch[index as usize];

            if !self.map.intermediates.push(tag) {
                break;
            }

            moved += 1;
        }

        (first, moved)
    }

    fn innermost_known(&self) -> Option<u32> {
        let mut index = self.map.stack.count();

        while index > 0 {
            index -= 1;

            if self.map.stack[index as usize].known {
                return Some(index);
            }
        }

        None
    }

    fn open(&mut self, tag: TagRef) {
        let known = self.specification_of(tag).is_some();

        if self.map.stack.count() >= BLOCK_DEPTH_MAX {
            if known {
                let _ = self.map.unmatched_openers.push(tag);
            }

            return;
        }

        self.map.stack.push_assert(OpenBlock {
            intermediate_count: 0,
            known,
            open: tag,
        });
    }

    fn push_unclosed(&mut self, open: OpenBlock) {
        if open.known {
            let _ = self.map.unmatched_openers.push(open.open);
        }

        let frame = self.map.stack.count();

        let last = if open.intermediate_count == 0 {
            None
        } else {
            let slot = frame * INTERMEDIATE_COUNT_MAX + open.intermediate_count - 1;

            Some(self.map.scratch[slot as usize])
        };

        let (first, count) = self.harvest(frame, open.intermediate_count);

        let span = last.map_or(open.open.span, |tag| Span {
            length: tag.span.end() - open.open.span.offset,
            offset: open.open.span.offset,
        });

        let _ = self.map.blocks.push(Block {
            close: TagRef::NONE,
            intermediate_count: count,
            intermediate_first: first,
            open: open.open,
            span,
        });
    }

    fn run(&mut self) {
        for index in 0..self.map.tags.count() {
            let tag = self.map.tags[index as usize];
            let name = tag.name(self.tokens, self.source);

            if let Some(target) = name.strip_prefix(END_PREFIX) {
                self.close(tag, target);

                continue;
            }

            if self.attach_intermediate(tag) {
                continue;
            }

            if self.words.contains(&name) {
                continue;
            }

            self.open(tag);
        }
    }

    fn specification_of(&self, tag: TagRef) -> Option<&TagSpecification> {
        let name = tag.name(self.tokens, self.source);

        self.specifications
            .iter()
            .find(|specification| specification.name == name)
    }
}

pub fn build(
    source: &[u8],
    tokens: &[Token],
    tree: &Tree,
    specifications: &[TagSpecification],
    words: &[&[u8]],
    map: &mut BlockMap,
) {
    assert!(u32::try_from(source.len()).is_ok());

    map.clear();

    collect(source, tokens, tree, map);

    let mut pairer = Pairer {
        map,
        source,
        specifications,
        tokens,
        words,
    };

    pairer.run();
    pairer.finish();
}

fn collect(source: &[u8], tokens: &[Token], tree: &Tree, map: &mut BlockMap) {
    assert!(!source.is_empty() || tree.count() <= 1);

    for index in 0..tree.count() {
        if tree.at(index).kind != MarkupKind::TemplateTag {
            continue;
        }

        let view = View::new(tree, tokens, index);

        let Some(tag) = view.as_template_tag() else {
            continue;
        };

        let Some(name_token) = tag.name_token() else {
            continue;
        };

        if !map.tags.push(TagRef {
            name_token,
            span: view.span(),
        }) {
            return;
        }
    }
}
