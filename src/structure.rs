use crate::bounded::{BoundedVec, Span, count_of};
use crate::brackets::Pairs;
use crate::token::{self, Keyword, Punctuation, Token, TokenKind};

pub const DEPTH_MAX: u32 = 64;
pub const NONE: u32 = u32::MAX;
const NONE_DEPTH: usize = usize::MAX;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Shape {
    pub colon_opens_a_block: bool,
    pub members_end_with_comma: bool,
    pub statements_end_with_semicolon: bool,
}

impl Shape {
    pub const DEFAULT: Self = Self {
        colon_opens_a_block: false,
        members_end_with_comma: false,
        statements_end_with_semicolon: false,
    };

    pub const PYTHON: Self = Self {
        colon_opens_a_block: true,
        members_end_with_comma: false,
        statements_end_with_semicolon: false,
    };
}

const WORD_BITS: u32 = 64;
const ARM_ARROW: &[u8] = b"=>";
const BRACE_CLOSE: &[u8] = b"}";
const BRACE_OPEN: &[u8] = b"{";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NodeKind {
    Block,
    Branch,
    Except,
    Function,
    Loop,
    Match,
    Struct,
    Try,
}

#[derive(Clone, Copy, Debug)]
pub struct Node {
    pub depth: u32,
    pub header: u32,
    pub kind: NodeKind,
    pub name: u32,
    pub parent: u32,
    pub token_end: u32,
    pub token_start: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Structure {
    Complete,
    TooDeep,
    Truncated,
}

#[derive(Debug)]
pub struct Nodes {
    items: BoundedVec<Node>,
}

pub struct Declared {
    words: BoundedVec<u64>,
}

impl Declared {
    pub fn reserve(token_count_max: u32) -> Self {
        assert!(token_count_max > 0);

        assert!(!crate::allocation::is_frozen());

        Self {
            words: BoundedVec::reserve(token_count_max / WORD_BITS + 1),
        }
    }

    pub fn build(&mut self, nodes: &[Node], token_count: u32) {
        self.words.clear();

        for _ in 0..=token_count / WORD_BITS {
            self.words.push_assert(0);
        }

        for node in nodes {
            if node.name == NONE {
                continue;
            }

            assert!(node.name < token_count);

            self.words[(node.name / WORD_BITS) as usize] |= 1 << (node.name % WORD_BITS);
        }
    }

    pub fn holds(&self, token: u32) -> bool {
        let word = (token / WORD_BITS) as usize;

        if word >= self.words.count() as usize {
            return false;
        }

        self.words[word] & (1 << (token % WORD_BITS)) != 0
    }
}

struct Builder {
    binding: u32,
    bound: u32,
    colon_held: bool,
    colon_opens: bool,
    depth: usize,
    ends_a_statement: bool,
    groups: u32,
    held_end: u32,
    held_parens: [u32; DEPTH_MAX as usize],
    inline_depth: usize,
    inner: [bool; DEPTH_MAX as usize],
    literal: bool,
    members_end: bool,
    parens: u32,
    pending: Pending,
    retract: u32,
    stack: [u32; DEPTH_MAX as usize],
    stale: bool,
}

#[derive(Clone, Copy)]
struct Pending {
    awaiting_name: bool,
    depth: usize,
    header: u32,
    kind: NodeKind,
    name: u32,
}

pub fn ancestor_of<'nodes>(
    nodes: &'nodes [Node],
    node: &'nodes Node,
    kind: NodeKind,
) -> Option<&'nodes Node> {
    let mut current = node;
    let mut steps = 0;

    while steps <= nodes.len() {
        if current.kind == kind {
            return Some(current);
        }

        if current.parent == NONE {
            return None;
        }

        current = &nodes[current.parent as usize];
        steps += 1;
    }

    None
}

pub fn of_header(nodes: &[Node], header: u32) -> Option<&Node> {
    nodes.iter().find(|node| node.header == header)
}

impl Node {
    pub fn marker(&self, tokens: &[Token]) -> Span {
        if self.name != NONE {
            return tokens[self.name as usize].span();
        }

        if self.header != NONE {
            return tokens[self.header as usize].span();
        }

        tokens[self.token_start as usize].span()
    }

    pub fn marker_modified(
        &self,
        pairs: &Pairs,
        tokens: &[Token],
        source: &[u8],
        modifier_count_max: usize,
    ) -> Span {
        let anchor = if self.name != NONE {
            self.name
        } else if self.header != NONE {
            self.header
        } else {
            self.token_start
        };

        assert!((anchor as usize) < tokens.len());

        let first =
            token::modifier_start(pairs, tokens, source, anchor as usize, modifier_count_max);

        tokens[first].span()
    }

    pub fn marker_opening(&self, tokens: &[Token], source: &[u8]) -> Span {
        let anchor = if self.header == NONE {
            self.token_start
        } else {
            self.header
        };

        assert!((anchor as usize) < tokens.len());

        let first = token::line_start_of_token(tokens, source, anchor as usize);

        assert!(first <= anchor as usize);

        tokens[first].span()
    }

    pub fn span(&self, tokens: &[Token]) -> Span {
        let first = if self.header == NONE {
            self.token_start
        } else {
            self.header
        };

        assert!((first as usize) < tokens.len());

        let start = tokens[first as usize].offset;

        let mut last = if self.token_end == NONE {
            count_of(tokens.len()) - 1
        } else {
            self.token_end
        };

        if last > first && tokens[last as usize].kind == TokenKind::Newline {
            last -= 1;
        }

        let end = tokens[last as usize].offset + tokens[last as usize].length;

        assert!(end >= start);

        Span {
            length: end - start,
            offset: start,
        }
    }

    pub fn tokens<'tokens>(&self, tokens: &'tokens [Token]) -> &'tokens [Token] {
        let start = self.token_start as usize;

        let end = if self.token_end == NONE {
            tokens.len()
        } else {
            self.token_end as usize + 1
        };

        assert!(start <= end);
        assert!(end <= tokens.len());

        &tokens[start..end]
    }
}

impl Nodes {
    pub fn reserve(node_count_max: u32) -> Self {
        assert!(node_count_max > 0);

        assert!(!crate::allocation::is_frozen());

        Self {
            items: BoundedVec::reserve(node_count_max),
        }
    }

    pub fn as_slice(&self) -> &[Node] {
        &self.items
    }

    pub fn clear(&mut self) {
        self.items.clear();

        assert_eq!(self.count(), 0);
    }

    pub fn count(&self) -> u32 {
        self.items.count()
    }

    fn at(&self, index: u32) -> Node {
        assert!(index < self.count());

        self.items[index as usize]
    }

    fn close(&mut self, index: u32, token_end: u32) {
        assert!(index < self.count());

        let node = &mut self.items[index as usize];

        assert_eq!(node.token_end, NONE);

        node.token_end = token_end;
    }

    fn demote(&mut self, index: u32) {
        assert!(index < self.count());

        let node = &mut self.items[index as usize];

        node.header = NONE;
        node.kind = NodeKind::Block;
        node.name = NONE;
    }

    fn open(&mut self, node: Node) -> Option<u32> {
        let index = self.count();

        if !self.items.push(node) {
            return None;
        }

        Some(index)
    }
}

pub fn build(
    tokens: &[Token],
    source: &[u8],
    nodes: &mut Nodes,
    shape: Shape,
    depth_max: u32,
) -> Structure {
    assert!(depth_max > 0);
    assert!(depth_max <= DEPTH_MAX);

    nodes.clear();

    let mut builder = Builder {
        binding: NONE,
        bound: NONE,
        colon_held: false,
        colon_opens: shape.colon_opens_a_block,
        depth: 0,
        ends_a_statement: shape.statements_end_with_semicolon,
        groups: 0,
        held_end: 0,
        held_parens: [0; DEPTH_MAX as usize],
        inline_depth: NONE_DEPTH,
        inner: [false; DEPTH_MAX as usize],
        members_end: shape.members_end_with_comma,
        literal: false,
        parens: 0,
        pending: Pending::EMPTY,
        retract: NONE,
        stack: [0; DEPTH_MAX as usize],
        stale: false,
    };

    for (index, token) in tokens.iter().enumerate() {
        let outcome = builder.step(nodes, source, count_of(index), token, depth_max);

        if outcome != Structure::Complete {
            return outcome;
        }
    }

    builder.finish(nodes, count_of(tokens.len()));

    Structure::Complete
}

fn line_between(source: &[u8], start: u32, end: u32) -> bool {
    let first = (start as usize).min(source.len());
    let last = (end as usize).min(source.len());

    if first >= last {
        return false;
    }

    source[first..last].contains(&b'\n')
}

impl Pending {
    const EMPTY: Self = Self {
        awaiting_name: false,
        depth: 0,
        header: NONE,
        kind: NodeKind::Block,
        name: NONE,
    };
}

impl Builder {
    fn finish(&mut self, nodes: &mut Nodes, count: u32) {
        assert!(count > 0 || self.depth == 0);

        while self.depth > 0 {
            self.depth -= 1;

            nodes.close(self.stack[self.depth], count - 1);
        }

        assert_eq!(self.depth, 0);
    }

    fn step(
        &mut self,
        nodes: &mut Nodes,
        source: &[u8],
        index: u32,
        token: &Token,
        depth_max: u32,
    ) -> Structure {
        let outcome = self.settle(nodes, source, index, token, depth_max);

        if outcome != Structure::Complete {
            return outcome;
        }

        self.dispatch(nodes, source, index, token, depth_max)
    }

    fn settle(
        &mut self,
        nodes: &mut Nodes,
        source: &[u8],
        index: u32,
        token: &Token,
        depth_max: u32,
    ) -> Structure {
        let trivia = matches!(token.kind, TokenKind::Comment | TokenKind::Newline);
        let grouped = self.parens > 0 || token.is_punctuation(Punctuation::ParenOpen);

        if !trivia && token.kind != TokenKind::BlockStart && !grouped {
            self.literal = false;
        }

        if self.stale && !trivia {
            self.stale = false;

            let opens = token.kind == TokenKind::BlockStart;
            let broke = self.retract != NONE && line_between(source, self.held_end, token.offset);

            if !opens || broke {
                self.forget();
            }
        }

        if self.colon_held && !matches!(token.kind, TokenKind::Comment) {
            self.colon_held = false;

            if !matches!(token.kind, TokenKind::Newline | TokenKind::BlockStart) {
                let outcome = self.block_start(nodes, index, depth_max);

                if outcome != Structure::Complete {
                    return outcome;
                }

                self.inline_depth = self.depth;
            }
        }

        Structure::Complete
    }

    fn dispatch(
        &mut self,
        nodes: &mut Nodes,
        source: &[u8],
        index: u32,
        token: &Token,
        depth_max: u32,
    ) -> Structure {
        match token.kind {
            TokenKind::BlockEnd => self.block_end(nodes, index, token),
            TokenKind::BlockStart => self.block_start(nodes, index, depth_max),
            TokenKind::Identifier => {
                if self.pending.awaiting_name && self.parens == 0 {
                    self.pending.awaiting_name = false;
                    self.pending.name = index;
                }

                self.binding = index;
                self.bound = NONE;

                Structure::Complete
            }
            TokenKind::Keyword(keyword) => {
                self.keyword(keyword, index);

                Structure::Complete
            }
            TokenKind::Newline => {
                if self.inline_depth == self.depth && self.depth > 0 {
                    self.inline_depth = NONE_DEPTH;
                    let _ = self.block_end(nodes, index, token);
                }

                self.stale = true;
                self.binding = NONE;
                self.bound = NONE;

                Structure::Complete
            }
            TokenKind::Punctuation(punctuation) => {
                self.punctuation(nodes, source, punctuation, token);

                Structure::Complete
            }
            TokenKind::Comment | TokenKind::Number | TokenKind::String => Structure::Complete,
        }
    }

    fn punctuation(
        &mut self,
        nodes: &Nodes,
        source: &[u8],
        punctuation: Punctuation,
        token: &Token,
    ) {
        match punctuation {
            Punctuation::AssignDeclare => {
                self.bound = self.binding;
            }
            Punctuation::Comma => {
                if self.members_end && self.parens == 0 && self.inside_a_container(nodes) {
                    self.forget();
                }
            }
            Punctuation::Other => self.punctuation_other(nodes, source, token),
            Punctuation::BracketClose => self.groups = self.groups.saturating_sub(1),
            Punctuation::BracketOpen => self.groups += 1,
            Punctuation::Colon => {
                if self.colon_opens && self.groups == 0 && self.pending.kind != NodeKind::Block {
                    self.colon_held = true;
                }
            }
            Punctuation::ParenClose => {
                self.parens = self.parens.saturating_sub(1);
                self.groups = self.groups.saturating_sub(1);
            }
            Punctuation::ParenOpen => {
                self.parens += 1;
                self.groups += 1;
            }
            Punctuation::Semicolon => {
                let names = matches!(self.pending.kind, NodeKind::Function | NodeKind::Struct);

                if names || self.ends_a_statement {
                    self.forget();
                }
            }
            Punctuation::Ampersand
            | Punctuation::AmpersandDouble
            | Punctuation::Arrow
            | Punctuation::Assign
            | Punctuation::Bang
            | Punctuation::BarDouble
            | Punctuation::Dot
            | Punctuation::Equal
            | Punctuation::Greater
            | Punctuation::GreaterEqual
            | Punctuation::Less
            | Punctuation::LessEqual
            | Punctuation::NotEqual
            | Punctuation::Slash
            | Punctuation::Star => {}
        }
    }

    fn punctuation_other(&mut self, nodes: &Nodes, source: &[u8], token: &Token) {
        let text = token.text(source);
        let arm = text == ARM_ARROW;

        if text == BRACE_OPEN {
            self.groups += 1;
        }

        if text == BRACE_CLOSE {
            self.groups = self.groups.saturating_sub(1);
        }

        if arm && self.parens == 0 && self.inside_an_arm(nodes) {
            self.forget();
        }
    }

    fn block_end(&mut self, nodes: &mut Nodes, index: u32, token: &Token) -> Structure {
        if self.depth == 0 {
            self.parens = 0;
            self.forget();

            return Structure::Complete;
        }

        self.depth -= 1;

        let slot = self.stack[self.depth];

        if self.inner[self.depth] {
            self.parens = self.held_parens[self.depth];
        } else {
            self.parens = 0;
            self.forget();
            self.hold(nodes.at(slot), slot, token.offset + token.length);
        }

        nodes.close(slot, index);

        Structure::Complete
    }

    fn inside_an_arm(&self, nodes: &Nodes) -> bool {
        if self.depth == 0 {
            return false;
        }

        nodes.at(self.stack[self.depth - 1]).kind == NodeKind::Match
    }

    fn inside_a_container(&self, nodes: &Nodes) -> bool {
        if self.depth == 0 {
            return false;
        }

        nodes.at(self.stack[self.depth - 1]).kind == NodeKind::Struct
    }

    const fn forget(&mut self) {
        self.literal = false;
        self.pending = Pending::EMPTY;
        self.retract = NONE;
    }

    const fn hold(&mut self, node: Node, slot: u32, end: u32) {
        if matches!(node.kind, NodeKind::Block | NodeKind::Struct) {
            return;
        }

        self.held_end = end;

        self.pending = Pending {
            awaiting_name: false,
            depth: self.depth,
            header: node.header,
            kind: node.kind,
            name: node.name,
        };

        self.retract = slot;
        self.stale = true;
    }

    fn block_start(&mut self, nodes: &mut Nodes, index: u32, depth_max: u32) -> Structure {
        if self.depth == depth_max as usize {
            return Structure::TooDeep;
        }

        let parent = if self.depth == 0 {
            NONE
        } else {
            self.stack[self.depth - 1]
        };

        let held = self.pending.kind != NodeKind::Block;
        let introduced = self.pending.kind == NodeKind::Struct && index == self.pending.header + 1;
        let nested = self.parens > 0 && !introduced;
        let inner = self.literal || (held && (nested || self.pending.depth != self.depth));
        let pending = if inner { Pending::EMPTY } else { self.pending };

        self.literal = false;

        if !inner && self.retract != NONE {
            nodes.demote(self.retract);
        }

        let node = Node {
            depth: count_of(self.depth),
            header: pending.header,
            kind: pending.kind,
            name: pending.name,
            parent,
            token_end: NONE,
            token_start: index,
        };

        let Some(slot) = nodes.open(node) else {
            return Structure::Truncated;
        };

        self.held_parens[self.depth] = self.parens;
        self.inner[self.depth] = inner;
        self.stack[self.depth] = slot;
        self.depth += 1;
        self.parens = 0;

        if !inner {
            self.forget();
        }

        Structure::Complete
    }

    fn keyword(&mut self, keyword: Keyword, index: u32) {
        let kind = match keyword {
            Keyword::Branch | Keyword::BranchElse => NodeKind::Branch,
            Keyword::Except => NodeKind::Except,
            Keyword::Function => NodeKind::Function,
            Keyword::Loop | Keyword::LoopUnbounded => NodeKind::Loop,
            Keyword::Match => NodeKind::Match,
            Keyword::Struct => NodeKind::Struct,
            Keyword::Try => NodeKind::Try,
            Keyword::Assert
            | Keyword::Break
            | Keyword::Constant
            | Keyword::Continue
            | Keyword::Declare
            | Keyword::Global
            | Keyword::Goto
            | Keyword::Import
            | Keyword::Lambda
            | Keyword::Mutable
            | Keyword::Other
            | Keyword::Return => return,
        };

        let named = matches!(kind, NodeKind::Function | NodeKind::Struct);

        if named && self.parens > 0 && kind != NodeKind::Struct {
            return;
        }

        let headed = !matches!(self.pending.kind, NodeKind::Block | NodeKind::Try);

        if named && self.parens > 0 && headed {
            return;
        }

        if !named {
            if self.pending.kind != NodeKind::Block {
                return;
            }
        }

        if named && self.pending.name != NONE {
            if self.pending.kind != kind {
                self.literal = true;
            }

            return;
        }

        let bound = if named { self.bound } else { NONE };

        self.pending = Pending {
            awaiting_name: named && bound == NONE,
            depth: self.depth,
            header: if bound == NONE { index } else { bound },
            kind,
            name: bound,
        };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::language::Lexer;
    use crate::lex::{GO, PYTHON, RUST, ZIG, tests_support};

    fn shape_of(lexer: &dyn Lexer) -> Shape {
        match lexer.identifier() {
            "odin" => Shape {
                colon_opens_a_block: false,
                members_end_with_comma: true,
                statements_end_with_semicolon: false,
            },
            "python" => Shape::PYTHON,
            "rust" => Shape {
                colon_opens_a_block: false,
                members_end_with_comma: false,
                statements_end_with_semicolon: true,
            },
            "zig" => Shape {
                colon_opens_a_block: false,
                members_end_with_comma: true,
                statements_end_with_semicolon: true,
            },
            _ => Shape::DEFAULT,
        }
    }

    fn nodes_of(lexer: &dyn Lexer, source: &[u8]) -> (Vec<Token>, Vec<Node>) {
        let tokens = tests_support::lex(lexer, source);
        let mut nodes = Nodes::reserve(256);

        assert_eq!(
            build(&tokens, source, &mut nodes, shape_of(lexer), DEPTH_MAX),
            Structure::Complete
        );

        (tokens, nodes.as_slice().to_vec())
    }

    fn kinds_of(lexer: &dyn Lexer, source: &[u8]) -> Vec<NodeKind> {
        let (_, nodes) = nodes_of(lexer, source);

        nodes.iter().map(|node| node.kind).collect()
    }

    #[test]
    fn a_stray_closing_brace_at_depth_zero_leaves_the_file_standing() {
        let source =
            b"fn first() {\n    let value = 1;\n}\n}\nfn second() {\n    let value = 2;\n}\n";

        let (_, nodes) = nodes_of(&RUST, source);

        let functions = nodes
            .iter()
            .filter(|node| node.kind == NodeKind::Function)
            .count();

        assert_eq!(functions, 2, "{nodes:?}");
    }

    #[test]
    fn a_pending_header_reaches_a_block_on_the_next_line() {
        let source = b"fn first()\n{\n    let value = 1;\n}\n";
        let (tokens, nodes) = nodes_of(&RUST, source);

        let function = nodes
            .iter()
            .find(|node| node.kind == NodeKind::Function)
            .expect("the function is a node");

        let text = &source[function.span(&tokens).range()];

        assert!(text.ends_with(b"}"), "{}", String::from_utf8_lossy(text));
    }

    #[test]
    fn a_comma_inside_a_container_forgets_the_pending_header() {
        let source = b"const Held = struct {\n    callback: fn () void,\n    slot: u32,\n};\n\
            \n                       fn helper() void {\n    return;\n}\n";

        let kinds = kinds_of(&ZIG, source);

        let functions = kinds
            .iter()
            .filter(|kind| **kind == NodeKind::Function)
            .count();

        assert_eq!(functions, 1, "{kinds:?}");
    }

    #[test]
    fn an_arrow_arm_forgets_the_pending_header() {
        let source = b"fn f() void {\n    switch (value) {\n        \
            .a => fn_table[0](),\n                       else => {},\n    }\n}\n";

        let kinds = kinds_of(&ZIG, source);

        let functions = kinds
            .iter()
            .filter(|kind| **kind == NodeKind::Function)
            .count();

        assert_eq!(functions, 1, "{kinds:?}");
    }

    #[test]
    fn a_truncated_file_with_open_headers_closes_every_node() {
        let source = b"fn first() {\n    if ready {\n        while more {\n";
        let (tokens, nodes) = nodes_of(&RUST, source);

        assert!(nodes.len() > 1, "{nodes:?}");

        for node in &nodes {
            assert!(node.token_end >= node.token_start, "{node:?}");
            assert!(node.token_end as usize <= tokens.len(), "{node:?}");
        }
    }

    #[test]
    fn a_nested_literal_does_not_adopt_a_shallower_keyword() {
        let source = b"fn f() void {\n    try tasks.put(key, .{\n\
                       .inner = .{ .value = 1 },\n    });\n}\n";

        let (_, nodes) = nodes_of(&ZIG, source);

        assert!(
            nodes.iter().all(|node| node.kind != NodeKind::Try),
            "{nodes:?}"
        );
    }

    #[test]
    fn a_struct_passed_through_a_try_call_keeps_its_kind() {
        let source =
            b"fn f() void {\n    try spawn(struct {\n        fn run() void {}\n    }.run);\n}\n";

        let (_, nodes) = nodes_of(&ZIG, source);
        let kinds: Vec<NodeKind> = nodes.iter().map(|node| node.kind).collect();

        assert_eq!(
            kinds,
            [NodeKind::Function, NodeKind::Struct, NodeKind::Function],
            "{nodes:?}"
        );

        assert_eq!(nodes[2].parent, 1);
    }

    #[test]
    fn a_prong_keyword_does_not_leak_into_the_next_prong() {
        let source = b"fn f() void {\n    switch (value) {\n        .a => if (ready) continue,\n\
                       else => {},\n    }\n}\n";

        let (_, nodes) = nodes_of(&ZIG, source);

        assert_eq!(
            nodes
                .iter()
                .filter(|node| node.kind == NodeKind::Branch)
                .count(),
            0,
            "{nodes:?}"
        );
    }

    #[test]
    fn a_function_pointer_field_does_not_hold_the_next_function() {
        let source = b"const Completion = struct {\n    callback: *const fn (\n\
                       context: *anyopaque,\n    ) void,\n};\n\n\
                       fn helper() void {\n    return;\n}\n";

        let (tokens, nodes) = nodes_of(&ZIG, source);

        let named = nodes
            .iter()
            .find(|node| node.kind == NodeKind::Function)
            .expect("a function node");

        assert_eq!(tokens[named.name as usize].text(source), b"helper");
    }

    #[test]
    fn a_rust_function_becomes_a_function_node() {
        let source = b"fn main() {\n    if x {\n        return;\n    }\n}\n";
        let (tokens, nodes) = nodes_of(&RUST, source);

        assert_eq!(nodes.len(), 2);
        assert_eq!(nodes[0].kind, NodeKind::Function);
        assert_eq!(nodes[0].depth, 0);
        assert_eq!(tokens[nodes[0].name as usize].text(source), b"main");
        assert_eq!(nodes[1].kind, NodeKind::Branch);
        assert_eq!(nodes[1].depth, 1);
        assert_eq!(nodes[1].parent, 0);

        let span = nodes[0].span(&tokens);

        assert_eq!(span.offset, 0);
        assert_eq!(span.end() as usize, source.len() - 1);
    }

    #[test]
    fn a_python_function_becomes_a_function_node() {
        let source = b"def main():\n    if x:\n        return 1\n";
        let (tokens, nodes) = nodes_of(&PYTHON, source);

        assert_eq!(nodes.len(), 2);
        assert_eq!(nodes[0].kind, NodeKind::Function);
        assert_eq!(tokens[nodes[0].name as usize].text(source), b"main");
        assert_eq!(nodes[1].kind, NodeKind::Branch);
        assert_eq!(nodes[1].parent, 0);
        assert_eq!(nodes[0].span(&tokens).offset, 0);
    }

    #[test]
    fn a_python_body_on_the_header_line_is_a_block() {
        let source = b"def main(): return 1\n";
        let (tokens, nodes) = nodes_of(&PYTHON, source);

        assert_eq!(nodes.len(), 1, "{nodes:?}");
        assert_eq!(nodes[0].kind, NodeKind::Function);
        assert_eq!(tokens[nodes[0].name as usize].text(source), b"main");

        let span = nodes[0].span(&tokens);

        assert_eq!(span.offset, 0);

        assert!(
            source[span.range()].ends_with(b"1"),
            "{}",
            String::from_utf8_lossy(&source[span.range()])
        );
    }

    #[test]
    fn a_python_branch_on_the_header_line_is_a_block() {
        let source = b"if ready: run()\nelse: wait()\n";
        let kinds = kinds_of(&PYTHON, source);

        assert_eq!(kinds, [NodeKind::Branch, NodeKind::Branch], "{kinds:?}");
    }

    #[test]
    fn a_python_class_on_the_header_line_holds_its_method() {
        let source = b"class Row:\n    def name(self): return self.value\n";
        let (_, nodes) = nodes_of(&PYTHON, source);

        assert_eq!(nodes.len(), 2, "{nodes:?}");
        assert_eq!(nodes[0].kind, NodeKind::Struct);
        assert_eq!(nodes[1].kind, NodeKind::Function);
        assert_eq!(nodes[1].parent, 0);
    }

    #[test]
    fn a_python_indented_body_still_opens_one_block() {
        let source = b"def main():\n    return 1\n";
        let kinds = kinds_of(&PYTHON, source);

        assert_eq!(kinds, [NodeKind::Function], "{kinds:?}");
    }

    #[test]
    fn a_python_colon_inside_brackets_opens_nothing() {
        for source in [
            b"mapping = {\"a\": 1}\n".as_slice(),
            b"held = values[1:2]\n".as_slice(),
            b"count: int = 5\n".as_slice(),
            b"pick = lambda value: value\n".as_slice(),
        ] {
            let kinds = kinds_of(&PYTHON, source);

            assert!(
                kinds.is_empty(),
                "{}: {kinds:?}",
                String::from_utf8_lossy(source)
            );
        }
    }

    #[test]
    fn a_python_header_holding_a_dict_still_opens_one_block() {
        let source = b"if value in {1: 2}: run()\n";
        let kinds = kinds_of(&PYTHON, source);

        assert_eq!(kinds, [NodeKind::Branch], "{kinds:?}");
    }

    #[test]
    fn a_go_anonymous_container_keeps_its_fields() {
        let source = b"func T() {\n\tcases := map[string]struct {\n\t\tname string\n\t}{}\n}\n";
        let (_, nodes) = nodes_of(&GO, source);

        let container = nodes
            .iter()
            .find(|node| node.kind == NodeKind::Struct)
            .expect("a container node");

        assert!(container.token_end > container.token_start + 2, "{nodes:?}");
    }

    #[test]
    fn a_zig_container_in_argument_position_opens_a_scope() {
        let source = b"fn caller() void {\n    run(struct {\n        \
            fn hash() u32 {\n                       return 0;\n        }\n    });\n}\n";

        let (_, nodes) = nodes_of(&ZIG, source);

        assert!(
            nodes.iter().any(|node| node.kind == NodeKind::Struct),
            "{nodes:?}"
        );
    }

    #[test]
    fn a_struct_literal_is_a_plain_block() {
        let source = b"fn f() {\n    let value = Point { x: 1 };\n}\n";
        let (_, nodes) = nodes_of(&RUST, source);

        assert_eq!(nodes.len(), 2);
        assert_eq!(nodes[0].kind, NodeKind::Function);
        assert_eq!(nodes[1].kind, NodeKind::Block);
    }

    #[test]
    fn an_else_block_is_a_branch() {
        let source = b"fn f() {\n    if a {\n    } else {\n    }\n}\n";
        let (_, nodes) = nodes_of(&RUST, source);

        assert_eq!(nodes.len(), 3);
        assert_eq!(nodes[1].kind, NodeKind::Branch);
        assert_eq!(nodes[2].kind, NodeKind::Branch);
    }

    #[test]
    fn a_loop_body_is_a_loop() {
        let source = b"fn f() {\n    while x {\n    }\n    loop {\n    }\n}\n";
        let (_, nodes) = nodes_of(&RUST, source);

        assert_eq!(nodes[1].kind, NodeKind::Loop);
        assert_eq!(nodes[2].kind, NodeKind::Loop);
    }

    #[test]
    fn nesting_past_the_limit_is_rejected() {
        let mut source = Vec::new();

        for _ in 0..40 {
            source.extend_from_slice(b"fn f() {");
        }

        let tokens = tests_support::lex(&RUST, &source);
        let mut nodes = Nodes::reserve(256);

        assert_eq!(
            build(&tokens, &source, &mut nodes, shape_of(&RUST), 8),
            Structure::TooDeep
        );
    }

    #[test]
    fn an_unclosed_block_still_closes() {
        let source = b"fn f() {\n    let value = 1;\n";
        let (tokens, nodes) = nodes_of(&RUST, source);

        assert_eq!(nodes.len(), 1);
        assert_ne!(nodes[0].token_end, NONE);
        assert!(nodes[0].span(&tokens).length > 0);
    }
}
