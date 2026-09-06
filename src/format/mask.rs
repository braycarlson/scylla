use crate::bounded::{BoundedVec, Buffer, Bytes as _, count_of};
use crate::format::brace::{ROLE_BLOCK, ROLE_JSX, ROLE_LAMBDA, ROLE_SPACED, ROLE_START};

const PAREN_CLOSE: &[u8] = b")";
const PAREN_OPEN: &[u8] = b"(";
const SEMICOLON: &[u8] = b";";
use crate::format::walk::{columns, ends_operand, is_close, is_open};
use crate::syntax::Category;
use crate::token::{Keyword, Punctuation, Token, TokenKind};
use crate::tree::{Kind, NONE, Node, Tree};

#[derive(Debug)]
pub struct Terminators {
    added: BoundedVec<u8>,
    marks: BoundedVec<u8>,
    origins: BoundedVec<u32>,
    roles: BoundedVec<u8>,
    source: Buffer,
    tokens: BoundedVec<Token>,
}

impl Terminators {
    pub fn reserve(element_count_max: u32, scratch_bytes_max: u32) -> Self {
        Self {
            added: BoundedVec::reserve(element_count_max),
            origins: BoundedVec::reserve(element_count_max),
            marks: BoundedVec::reserve(element_count_max),
            roles: BoundedVec::reserve(element_count_max),
            source: Buffer::reserve(scratch_bytes_max),
            tokens: BoundedVec::reserve(element_count_max),
        }
    }

    pub fn added(&self) -> &[u8] {
        &self.added
    }

    pub fn origins(&self) -> &[u32] {
        &self.origins
    }

    pub fn roles(&self) -> &[u8] {
        &self.roles
    }

    pub fn source(&self) -> &[u8] {
        self.source.as_bytes()
    }

    pub fn tokens(&self) -> &[Token] {
        &self.tokens
    }
}

const END_OWED: u8 = 1 << 0;
const END_DENIED: u8 = 1 << 1;
const PAREN_DROPS: u8 = 1 << 2;
const PAREN_OPENS: u8 = 1 << 3;
const PAREN_CLOSES: u8 = 1 << 4;
const JSX_OPENS: u8 = ROLE_JSX;
const NAME_WORDS: u8 = 1 << 5;
const OPERATOR_SPACED: u8 = 1 << 6;
const OPERAND_WALK_MAX: u32 = 16;
const BLOCK_OPENS: u8 = 1 << 3;
const BLOCK_CLOSES: u8 = 1 << 4;
const BLOCK_DROPS: u8 = 1 << 5;
const ARM_ARGUED: bool = true;
const ARM_ARROWS: bool = true;
const ARM_FORCES: bool = true;
const PATTERN_DEPTH_MAX: usize = 32;
const ARM_LINED: bool = true;
const TAB_COLUMNS: bool = true;
const ARM_INNERS: bool = true;
const ARM_LINES: bool = true;
const ARM_SEMIS: bool = true;
const ARM_JUMPS: [&[u8]; 4] = [b"break", b"continue", b"return", b"yield"];
const BODY_ONES: bool = true;
const BODY_FRONTS: bool = true;
const BODY_TAILS: bool = true;
const ARM_MARGINS: bool = true;
const BLOCK_BREAKS: bool = true;
const CALL_STUBS: bool = true;
const CALL_CASCADES: bool = true;
const BRACE_COLUMNS: u32 = 2;
const CALL_SEATS: bool = true;
const CALL_ARGS: bool = true;
const CALL_SOLES: bool = true;
const CALL_LINKS: u32 = 2;
const BRACE_OPEN: &[u8] = b" {\n";
const MASK_SEMICOLON: u8 = 1;
const MASK_CLOSE: u8 = 2;
const MASK_OPEN: u8 = 3;
const BRACE_CLOSE: &[u8] = b"\n}";
const BODY_LINKS: bool = true;
const BODY_NESTS: bool = true;
const BODY_STACK_MAX: usize = 32;
const BODY_WALK_MAX: u32 = 512;
const TAIL_SCAN_MAX: u32 = 256;
const TAIL_WALK_MAX: u32 = 2;
const CALL_WALK_MAX: u32 = 3;
const CHAIN_WALK_MAX: u32 = 6;
const SKIP_WALK_MAX: u32 = 8;
const CALL_DOTTED: bool = true;
const CALL_NESTED: bool = true;

#[derive(Clone, Copy, Debug)]
pub struct Rules<K> {
    pub braced: fn(K) -> bool,
    pub denies: fn(K, K) -> bool,
    pub drops: fn(K, K) -> bool,
    pub names: fn(K) -> bool,
    pub opens: fn(K) -> bool,
    pub operators: fn(K) -> bool,
    pub owes: fn(K, K) -> bool,
    pub parens: fn(K) -> bool,
    pub queries: fn(K) -> bool,
    pub spans: fn(K) -> bool,
    pub wraps: fn(K, K) -> bool,
}

fn separated_already(tokens: &[Token], flags: &[u8], position: u32) -> bool {
    if matches!(
        tokens[position as usize].kind,
        TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
    ) {
        return true;
    }

    let mut scan = position + 1;

    while (scan as usize) < tokens.len() {
        let token = tokens[scan as usize];

        if token.kind == TokenKind::Newline || token.length == 0 || token.kind == TokenKind::Comment
        {
            scan += 1;

            continue;
        }

        if flags[scan as usize] & BLOCK_DROPS != 0 {
            return false;
        }

        return matches!(
            token.kind,
            TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
        );
    }

    false
}

pub fn terminated<K, T>(
    tree: &Tree<K>,
    source: &[u8],
    tokens: &[Token],
    rules: Rules<K>,
    stream: &mut Terminators,
) -> bool
where
    K: Kind<Error = T>,
    T: Copy,
{
    let Terminators {
        marks,
        roles,
        source: out,
        tokens: held,
        ..
    } = stream;

    marks.clear();
    out.clear();
    roles.clear();
    held.clear();

    for _ in 0..tokens.len() {
        if !marks.push(0) {
            return false;
        }
    }

    let flags = &mut **marks;

    ended(tree, tokens, rules, flags);
    dropped(tree, source, tokens, rules, flags);

    let mut written = 0;

    for position in 0..count_of(tokens.len()) {
        let token = tokens[position as usize];
        let mark = flags[position as usize];

        if mark & PAREN_OPENS != 0 && !opened(source, token, &mut written, out, held, roles) {
            return false;
        }

        if mark & PAREN_DROPS == 0 {
            let moved = count_of(out.as_bytes().len()) + (token.offset - written);

            if !held.push(Token {
                kind: named_kind(token.kind, mark),
                length: token.length,
                offset: moved,
            }) || !roles.push((mark & JSX_OPENS) | spaced_role(mark))
            {
                return false;
            }
        } else {
            if !out.push_bytes(&source[written as usize..token.offset as usize]) {
                return false;
            }

            written = token.end();
        }

        if mark & PAREN_CLOSES != 0 && !closed(source, token, &mut written, out, held, roles) {
            return false;
        }

        if mark & END_OWED == 0
            || mark & END_DENIED != 0
            || separated_already(tokens, flags, position)
        {
            continue;
        }

        if !separates(source, token, &mut written, out, held, roles) {
            return false;
        }
    }

    out.push_bytes(&source[written as usize..])
}

const fn spaced_role(mark: u8) -> u8 {
    if mark & OPERATOR_SPACED != 0 {
        return ROLE_SPACED;
    }

    0
}

const fn named_kind(kind: TokenKind, mark: u8) -> TokenKind {
    if matches!(kind, TokenKind::Keyword(Keyword::Assert)) {
        return TokenKind::Identifier;
    }

    if mark & NAME_WORDS != 0 && matches!(kind, TokenKind::Keyword(_)) {
        return TokenKind::Identifier;
    }

    kind
}

fn opened(
    source: &[u8],
    token: Token,
    written: &mut u32,
    out: &mut Buffer,
    held: &mut BoundedVec<Token>,
    roles: &mut BoundedVec<u8>,
) -> bool {
    if !out.push_bytes(&source[*written as usize..token.offset as usize])
        || !out.push_bytes(PAREN_OPEN)
    {
        return false;
    }

    *written = token.offset;

    let at = count_of(out.as_bytes().len()) - 1;

    held.push(Token {
        kind: TokenKind::Punctuation(Punctuation::ParenOpen),
        length: 1,
        offset: at,
    }) && roles.push(0)
}

fn closed(
    source: &[u8],
    token: Token,
    written: &mut u32,
    out: &mut Buffer,
    held: &mut BoundedVec<Token>,
    roles: &mut BoundedVec<u8>,
) -> bool {
    if !out.push_bytes(&source[*written as usize..token.end() as usize])
        || !out.push_bytes(PAREN_CLOSE)
    {
        return false;
    }

    *written = token.end();

    let at = count_of(out.as_bytes().len()) - 1;

    held.push(Token {
        kind: TokenKind::Punctuation(Punctuation::ParenClose),
        length: 1,
        offset: at,
    }) && roles.push(0)
}

fn separates(
    source: &[u8],
    token: Token,
    written: &mut u32,
    out: &mut Buffer,
    held: &mut BoundedVec<Token>,
    roles: &mut BoundedVec<u8>,
) -> bool {
    if !out.push_bytes(&source[*written as usize..token.end() as usize])
        || !out.push_bytes(SEMICOLON)
    {
        return false;
    }

    *written = token.end();

    let at = count_of(out.as_bytes().len()) - 1;

    held.push(Token {
        kind: TokenKind::Punctuation(Punctuation::Semicolon),
        length: 1,
        offset: at,
    }) && roles.push(0)
}

fn dropped<K, T>(tree: &Tree<K>, source: &[u8], tokens: &[Token], rules: Rules<K>, flags: &mut [u8])
where
    K: Kind<Error = T>,
    T: Copy,
{
    let nodes = tree.as_slice();

    for node in nodes {
        if !(rules.parens)(node.kind) || node.parent == NONE || node.child_first == NONE {
            continue;
        }

        if node.token_end == 0 || node.token_end as usize > tokens.len() {
            continue;
        }

        let inner = nodes[node.child_first as usize];
        let parent = nodes[node.parent as usize].kind;

        if !(rules.drops)(inner.kind, parent) {
            continue;
        }

        let open = node.token_start;
        let close = node.token_end - 1;

        if inner.token_start != open + 1 || inner.token_end != close {
            continue;
        }

        if tokens[open as usize].text(source) != b"(" || tokens[close as usize].text(source) != b")"
        {
            continue;
        }

        if (rules.braced)(parent) && tokens[inner.token_start as usize].text(source) == b"{" {
            continue;
        }

        let span =
            &source[tokens[open as usize].offset as usize..tokens[close as usize].end() as usize];

        if span.contains(&b'\n') && !(rules.spans)(inner.kind) {
            continue;
        }

        flags[open as usize] |= PAREN_DROPS;
        flags[close as usize] |= PAREN_DROPS;
    }
}

fn ended<K, T>(tree: &Tree<K>, tokens: &[Token], rules: Rules<K>, flags: &mut [u8])
where
    K: Kind<Error = T>,
    T: Copy,
{
    let nodes = tree.as_slice();

    for (index, node) in nodes.iter().enumerate() {
        if wrapped(nodes, rules, count_of(index), node) {
            if let Some(mark_at) = flags.get_mut(node.token_start as usize) {
                *mark_at |= PAREN_OPENS;
            }

            if let Some(mark_at) = flags.get_mut((node.token_end - 1) as usize) {
                *mark_at |= PAREN_CLOSES;
            }
        }

        if (rules.opens)(node.kind) {
            if let Some(mark_at) = flags.get_mut(node.token_start as usize) {
                *mark_at |= JSX_OPENS;
            }
        }

        if (rules.names)(node.kind) {
            for position in node.token_start..node.token_end {
                if let Some(mark_at) = flags.get_mut(position as usize) {
                    *mark_at |= NAME_WORDS;
                }
            }
        }

        if (rules.operators)(node.kind) {
            operated(nodes, tokens, node, flags);
        }

        if (rules.queries)(node.kind) {
            queried(nodes, tokens, node, flags);
        }

        if node.token_end == 0 || node.token_end as usize > tokens.len() {
            continue;
        }

        let parent = if node.parent == NONE {
            node.kind
        } else {
            nodes[node.parent as usize].kind
        };

        let mark = if (rules.denies)(node.kind, parent) {
            END_DENIED
        } else if (rules.owes)(node.kind, parent) {
            END_OWED
        } else {
            continue;
        };

        if let Some(mark_at) = flags.get_mut((node.token_end - 1) as usize) {
            *mark_at |= mark;
        }
    }
}

fn wrapped<K, T>(nodes: &[Node<K>], rules: Rules<K>, index: u32, node: &Node<K>) -> bool
where
    K: Kind<Error = T>,
    T: Copy,
{
    if node.parent == NONE || node.token_end == 0 {
        return false;
    }

    let parent = nodes[node.parent as usize];

    parent.child_first == index && (rules.wraps)(node.kind, parent.kind)
}

fn queried<K>(nodes: &[Node<K>], tokens: &[Token], node: &Node<K>, flags: &mut [u8])
where
    K: Kind,
{
    let mut child = node.child_first;

    for _ in 0..OPERAND_WALK_MAX {
        let next = if child == NONE {
            NONE
        } else {
            nodes[child as usize].sibling_next
        };

        if next == NONE {
            return;
        }

        spaced(
            tokens,
            nodes[child as usize].token_end,
            nodes[next as usize].token_start,
            flags,
        );

        child = next;
    }
}

fn spaced(tokens: &[Token], from: u32, to: u32, flags: &mut [u8]) {
    for position in from..to.min(count_of(tokens.len())) {
        if tokens[position as usize].kind == TokenKind::Comment {
            continue;
        }

        if let Some(mark_at) = flags.get_mut(position as usize) {
            *mark_at |= OPERATOR_SPACED;
        }
    }
}

fn operated<K>(nodes: &[Node<K>], tokens: &[Token], node: &Node<K>, flags: &mut [u8])
where
    K: Kind,
{
    let mut previous = NONE;
    let mut last = node.child_first;

    for _ in 0..OPERAND_WALK_MAX {
        if last == NONE || nodes[last as usize].sibling_next == NONE {
            break;
        }

        previous = last;
        last = nodes[last as usize].sibling_next;
    }

    if previous == NONE || last == NONE {
        return;
    }

    spaced(
        tokens,
        nodes[previous as usize].token_end,
        nodes[last as usize].token_start,
        flags,
    );
}

pub fn marked<K, T>(tree: &Tree<K>, tokens: &[Token], roles: &mut BoundedVec<u8>) -> bool
where
    K: Kind<Error = T>,
    T: Copy,
{
    roles.clear();

    for _ in 0..tokens.len() {
        if !roles.push(0) {
            return false;
        }
    }

    let held = &mut **roles;

    for node in tree.as_slice() {
        let Some(flags) = held.get_mut(node.token_start as usize) else {
            continue;
        };

        *flags |= ROLE_START;

        if node.kind.category() == Category::Block {
            *flags |= ROLE_BLOCK;
        }

        if node.kind.category() == Category::Lambda {
            *flags |= ROLE_LAMBDA;
        }
    }

    true
}

fn spans_lines(source: &[u8], tokens: &[Token], from: u32, to: u32) -> bool {
    let stop = (to as usize).min(tokens.len());

    if from as usize >= stop {
        return false;
    }

    let head = tokens[from as usize].offset as usize;
    let tail = (tokens[stop - 1].end() as usize).min(source.len());

    head < tail && source[head..tail].contains(&b'\n')
}

#[derive(Clone, Copy, Debug)]
pub struct Tails<K> {
    pub argued: fn(K) -> bool,
    pub arms: fn(K) -> bool,
    pub bodies: fn(K) -> u32,
    pub bounds: fn(K) -> bool,
    pub call_width: u32,
    pub chained: fn(K) -> bool,
    pub flattens: fn(K) -> bool,
    pub forces: fn(K) -> bool,
    pub indent: u32,
    pub lambda: fn(K) -> bool,
    pub line: u32,
    pub literal: u32,
    pub owes: fn(K, K) -> bool,
    pub width: u32,
    pub wraps: fn(K) -> bool,
}

fn calling(source: &[u8], tokens: &[Token], at: u32) -> Option<(u32, bool)> {
    let mut depth = 0_u32;
    let mut scan = at;
    let mut separated = false;

    for _ in 0..TAIL_SCAN_MAX {
        if scan == 0 {
            return None;
        }

        scan -= 1;

        let text = tokens[scan as usize].text(source);

        if matches!(text, b")" | b"]" | b"}") {
            depth += 1;
        } else if matches!(text, b"(" | b"[" | b"{") {
            if depth == 0 {
                return Some((scan, separated));
            }

            depth -= 1;
        } else if depth == 0 && text == b"," {
            separated = true;
        }
    }

    None
}

fn dotted_item(source: &[u8], tokens: &[Token], open: u32) -> u32 {
    let mut depth = 0_u32;
    let mut links = 0_u32;
    let mut scan = open as usize + 1;

    while scan < tokens.len() {
        let text = tokens[scan].text(source);

        if matches!(text, b"(" | b"[" | b"{") {
            depth += 1;
        } else if matches!(text, b")" | b"]" | b"}") {
            if depth == 0 {
                return links;
            }

            depth -= 1;
        } else if depth == 0 && text == b"." {
            links += 1;
        }

        scan += 1;
    }

    links
}

fn capping(source: &[u8], tokens: &[Token], open: u32, separated: bool, nested: bool) -> bool {
    if separated || !nested {
        return separated;
    }

    let Some(held) = tokens.get(open as usize + 1) else {
        return true;
    };

    !matches!(held.text(source), b"|" | b"||" | b"move")
}

fn headed(source: &[u8], tokens: &[Token], from: u32, to: u32) -> usize {
    let stop = (to as usize).min(tokens.len());
    let mut scan = from as usize;

    while scan < stop {
        if matches!(tokens[scan].text(source), b"(" | b"[" | b"{") {
            return scan + 1;
        }

        scan += 1;
    }

    stop
}

fn closed_after(tokens: &[Token], from: usize, stop: usize) -> bool {
    let mut scan = from + 1;

    while scan < stop {
        let kind = tokens[scan].kind;

        if tokens[scan].length == 0 || kind == TokenKind::Newline {
            scan += 1;

            continue;
        }

        return matches!(
            kind,
            TokenKind::BlockEnd
                | TokenKind::Punctuation(Punctuation::BracketClose | Punctuation::ParenClose)
        );
    }

    true
}

fn spelled(source: &[u8], tokens: &[Token], from: u32, stop: usize) -> u32 {
    let mut held = 0;
    let mut previous: Option<usize> = None;
    let mut scan = from as usize;
    let mut separated = false;

    while scan < stop {
        let token = tokens[scan];

        let comma = token.kind == TokenKind::Punctuation(Punctuation::Comma)
            && closed_after(tokens, scan, stop);

        if token.length == 0 || token.kind == TokenKind::Newline || comma {
            separated |= comma;
            scan += 1;

            continue;
        }

        let banged = previous
            .is_some_and(|before| tokens[before].kind == TokenKind::Punctuation(Punctuation::Bang))
            && matches!(
                token.kind,
                TokenKind::Punctuation(Punctuation::ParenOpen | Punctuation::BracketOpen)
                    | TokenKind::BlockStart
            );

        let gapped = if separated {
            token.kind == TokenKind::BlockEnd
        } else {
            !banged && previous.is_some_and(|before| tokens[before].end() < token.offset)
        };

        held += u32::from(gapped) + columns(source, token.offset, token.end());
        previous = Some(scan);
        separated = false;
        scan += 1;
    }

    held
}

fn argued(tokens: &[Token], source: &[u8], from: u32, stop: usize) -> u32 {
    let mut scan = from as usize;

    while scan < stop {
        if matches!(tokens[scan].text(source), b"(" | b"{") {
            return count_of(scan);
        }

        scan += 1;
    }

    from
}

fn soled(tokens: &[Token], source: &[u8], open: u32, stop: usize) -> bool {
    if tokens[open as usize].text(source) != b"(" {
        return false;
    }

    let mut depth = 0_u32;
    let mut lambda = false;
    let mut previous: Option<usize> = None;
    let mut scan = open as usize;

    while scan < stop {
        let token = tokens[scan];
        let kind = token.kind;
        let opens = previous.is_none_or(|held| !ends_operand(tokens[held].kind));

        if token.text(source).contains(&b'\n') || kind == TokenKind::BlockStart {
            return false;
        }

        if is_open(kind) {
            depth += 1;
        } else if is_close(kind) {
            depth = depth.saturating_sub(1);

            if depth == 0 {
                return true;
            }
        } else if depth == 1 && token.text(source) == b"|" && (lambda || opens) {
            lambda = !lambda;
        } else if depth == 1
            && !lambda
            && kind == TokenKind::Punctuation(Punctuation::Comma)
            && tokens[scan + 1..stop]
                .iter()
                .any(|held| held.length > 0 && !is_close(held.kind))
        {
            return false;
        }

        if token.length > 0 && kind != TokenKind::Newline && kind != TokenKind::Comment {
            previous = Some(scan);
        }

        scan += 1;
    }

    false
}

fn linked(tokens: &[Token], from: u32, stop: usize) -> u32 {
    let mut depth = 0_u32;
    let mut found = 0;
    let mut scan = from as usize;

    while scan < stop {
        let kind = tokens[scan].kind;

        if matches!(
            kind,
            TokenKind::BlockStart | TokenKind::Punctuation(Punctuation::ParenOpen)
        ) {
            depth += 1;
        } else if matches!(
            kind,
            TokenKind::BlockEnd | TokenKind::Punctuation(Punctuation::ParenClose)
        ) {
            depth = depth.saturating_sub(1);
        } else if depth == 0 && kind == TokenKind::Punctuation(Punctuation::Dot) {
            found += 1;
        }

        scan += 1;
    }

    found
}

fn brokens<K, T>(
    nodes: &[Node<K>],
    source: &[u8],
    tokens: &[Token],
    rules: Tails<K>,
    body: &Node<K>,
) -> bool
where
    K: Kind<Error = T>,
    T: Copy,
{
    if !BODY_NESTS {
        return false;
    }

    let mut stack = [NONE; BODY_STACK_MAX];
    let mut depth = 0_usize;
    let mut found = body.child_first;

    for _ in 0..BODY_WALK_MAX {
        if found == NONE {
            if depth == 0 {
                return false;
            }

            depth -= 1;
            found = stack[depth];

            continue;
        }

        let node = &nodes[found as usize];
        let end = (node.token_end as usize).min(tokens.len());
        let width = (rules.bodies)(node.kind);

        if width > 0 && (node.token_start as usize) < end {
            let head = if (rules.argued)(node.kind) {
                argued(tokens, source, node.token_start, end)
            } else {
                node.token_start
            };

            let chained = BODY_LINKS
                && (rules.chained)(node.kind)
                && linked(tokens, node.token_start, end) < 2;

            if !chained && spelled(source, tokens, head, end) > width {
                return true;
            }
        }

        if node.child_first != NONE && depth < BODY_STACK_MAX {
            stack[depth] = node.sibling_next;
            depth += 1;
            found = node.child_first;
        } else {
            found = node.sibling_next;
        }
    }

    false
}

fn overflows<K, T>(
    nodes: &[Node<K>],
    source: &[u8],
    tokens: &[Token],
    rules: Tails<K>,
    lambda: u32,
    body: &Node<K>,
    nested: bool,
) -> bool
where
    K: Kind<Error = T>,
    T: Copy,
{
    let end = (body.token_end as usize).min(tokens.len());

    if body.token_start as usize >= end {
        return false;
    }

    if brokens(nodes, source, tokens, rules, body) {
        return true;
    }

    if (rules.wraps)(body.kind) {
        let argues = (rules.argued)(body.kind);
        let head = if argues {
            argued(tokens, source, body.token_start, end)
        } else {
            body.token_start
        };

        let chained = (rules.chained)(body.kind) && linked(tokens, body.token_start, end) < 2;
        let width = (rules.bodies)(body.kind);
        let ones = BODY_ONES && argues && soled(tokens, source, head, end);

        // `LimitedHorizontalVertical(fn_call_width)` measures the ITEMS and their separators,
        // never the brackets around them, so an argued body owes its two delimiters back.
        let inside = CALL_ARGS && argues && head < count_of(end) && end > 0;
        let (from, stop) = if inside {
            (head + 1, end - 1)
        } else {
            (head, end)
        };

        if width > 0 && !chained && !ones && spelled(source, tokens, from, stop) > width {
            return true;
        }
    }

    let stop = if (rules.wraps)(body.kind) {
        end
    } else {
        headed(source, tokens, body.token_start, body.token_end)
    };

    let mut scan = lambda;

    for _ in 0..CALL_WALK_MAX {
        let Some((open, separated)) = calling(source, tokens, scan) else {
            return false;
        };

        let horizontal =
            !CALL_STUBS || stubbed_run(source, tokens, open, body.token_start) <= rules.call_width;

        // `last_item_shape` hands a SOLE item the whole one-line shape unless `is_nested_call`
        // answers for it, and that reads through the unary prefixes to a Call or a MacCall and
        // nothing else. A sole item carrying a `.` is a chain, and its budget is the LINE.
        let soled = CALL_SOLES && !separated && dotted_item(source, tokens, open) >= CALL_LINKS;

        if capping(source, tokens, open, separated, nested)
            && horizontal
            && !soled
            && !spans_lines(source, tokens, open, lambda)
            && spelled(source, tokens, open + 1, stop) > rules.call_width
        {
            return true;
        }

        if !nested {
            break;
        }

        scan = open;
    }

    cascaded(source, tokens, rules, lambda, stop)
}

fn cascaded<K, T>(
    source: &[u8],
    tokens: &[Token],
    rules: Tails<K>,
    lambda: u32,
    stop: usize,
) -> bool
where
    K: Kind<Error = T>,
    T: Copy,
{
    if !CALL_CASCADES {
        return false;
    }

    let Some((inner, split)) = calling(source, tokens, lambda) else {
        return false;
    };

    if split || tokens[inner as usize].text(source) != b"(" {
        return false;
    }

    let mut narrow = 0;
    let mut walk = inner;

    for _ in 0..CALL_WALK_MAX {
        let Some((open, separated)) = calling(source, tokens, walk) else {
            break;
        };

        if separated || tokens[open as usize].text(source) != b"(" {
            break;
        }

        if CALL_DOTTED && dotted(source, tokens, walk) {
            break;
        }

        narrow += callee_width(source, tokens, walk) + BRACE_COLUMNS;
        walk = open;
    }

    narrow > 0 && spelled(source, tokens, inner + 1, stop) + narrow > rules.call_width
}

fn dotted(source: &[u8], tokens: &[Token], open: u32) -> bool {
    let mut scan = open;

    while scan > 0 {
        let token = tokens[(scan - 1) as usize];

        if token.kind == TokenKind::Newline || token.length == 0 {
            scan -= 1;

            continue;
        }

        if token.kind != TokenKind::Identifier && !matches!(token.text(source), b"::" | b"!" | b":")
        {
            return token.text(source) == b".";
        }

        scan -= 1;
    }

    false
}

fn callee_width(source: &[u8], tokens: &[Token], open: u32) -> u32 {
    let mut scan = open;
    let mut width = 0;

    while scan > 0 {
        let token = tokens[(scan - 1) as usize];

        if token.kind == TokenKind::Newline || token.length == 0 {
            scan -= 1;

            continue;
        }

        if token.kind != TokenKind::Identifier && !matches!(token.text(source), b"::" | b"!" | b":")
        {
            break;
        }

        width += columns(source, token.offset, token.end());
        scan -= 1;
    }

    width
}

fn stubbed_run(source: &[u8], tokens: &[Token], open: u32, body: u32) -> u32 {
    let opened = if braced_head(tokens, body) {
        0
    } else {
        BRACE_COLUMNS
    };

    spelled(source, tokens, open + 1, body as usize) + opened
}

fn braced_head(tokens: &[Token], body: u32) -> bool {
    let mut scan = body;

    while scan > 0 {
        scan -= 1;

        let token = tokens[scan as usize];

        if token.length == 0 || token.kind == TokenKind::Newline {
            continue;
        }

        return token.kind == TokenKind::BlockStart;
    }

    false
}

fn last_child<K, T>(nodes: &[Node<K>], node: &Node<K>) -> u32
where
    K: Kind<Error = T>,
    T: Copy,
{
    let mut held = node.child_first;

    while held != NONE && nodes[held as usize].sibling_next != NONE {
        held = nodes[held as usize].sibling_next;
    }

    held
}

fn bodied<K, T>(tree: &Tree<K>, source: &[u8], tokens: &[Token], rules: Tails<K>, flags: &mut [u8])
where
    K: Kind<Error = T>,
    T: Copy,
{
    let nodes = tree.as_slice();

    for node in nodes {
        if !(rules.lambda)(node.kind) {
            continue;
        }

        let held = last_child(nodes, node);

        if held == NONE {
            continue;
        }

        let body = &nodes[held as usize];

        if body.token_start == node.token_start
            || !(rules.wraps)(body.kind)
            || !overflows(nodes, source, tokens, rules, node.token_start, body, false)
        {
            continue;
        }

        let stop = (body.token_end as usize).min(tokens.len());

        let Some(open) = body.token_start.checked_sub(1) else {
            continue;
        };

        if let Some(mark_at) = flags.get_mut(open as usize) {
            *mark_at |= BLOCK_OPENS;
        }

        if let Some(mark_at) = flags.get_mut(stop - 1) {
            *mark_at |= BLOCK_CLOSES;
        }
    }
}

fn skipped<K, T>(nodes: &[Node<K>], source: &[u8], tokens: &[Token], node: &Node<K>) -> bool
where
    K: Kind<Error = T>,
    T: Copy,
{
    let mut held = node;

    for _ in 0..SKIP_WALK_MAX {
        let start = held.token_start as usize;

        let inside = start + 4 < tokens.len()
            && tokens[start].text(source) == b"#"
            && tokens[start + 2].text(source) == b"rustfmt"
            && tokens[start + 4].text(source) == b"skip";

        let before = start >= 4
            && tokens[start - 1].text(source) == b"]"
            && tokens[start - 2].text(source) == b"skip"
            && tokens[start - 3].text(source) == b"::"
            && tokens[start - 4].text(source) == b"rustfmt";

        if inside || before {
            return true;
        }

        if held.parent == NONE {
            return false;
        }

        held = &nodes[held.parent as usize];
    }

    false
}

fn inner_of<'held, K, T>(nodes: &'held [Node<K>], node: &'held Node<K>) -> &'held Node<K>
where
    K: Kind<Error = T>,
    T: Copy,
{
    let mut held = node;

    for _ in 0..TAIL_WALK_MAX {
        let child = held.child_first;

        if child == NONE {
            return held;
        }

        let inner = &nodes[child as usize];

        let inside = inner.token_start >= held.token_start
            && inner.token_end <= held.token_end
            && (inner.token_start > held.token_start || inner.token_end < held.token_end);

        if inner.sibling_next != NONE || !inside {
            return held;
        }

        held = inner;
    }

    held
}

fn bodied_head(source: &[u8], tokens: &[Token], position: u32) -> bool {
    let token = tokens[position as usize];

    token.kind == TokenKind::BlockStart
        || matches!(
            token.text(source),
            b"async"
                | b"const"
                | b"for"
                | b"if"
                | b"loop"
                | b"match"
                | b"try"
                | b"unsafe"
                | b"while"
        )
}

fn pattern_flat(source: &[u8], tokens: &[Token], from: u32, arrow: u32, rules: (u32, u32)) -> bool {
    let (call, literal) = rules;

    if tokens[from as usize].text(source) == b"#" {
        return false;
    }

    let mut opens = [0_u32; PATTERN_DEPTH_MAX];
    let mut depth = 0_usize;
    let mut scan = from;

    while scan < arrow {
        let kind = tokens[scan as usize].kind;

        if is_open(kind) || kind == TokenKind::BlockStart {
            if depth == PATTERN_DEPTH_MAX {
                return false;
            }

            opens[depth] = scan;
            depth += 1;
        } else if is_close(kind) || kind == TokenKind::BlockEnd {
            if depth == 0 {
                return false;
            }

            depth -= 1;

            let open = opens[depth];
            let cap = if tokens[open as usize].kind == TokenKind::BlockStart {
                literal
            } else {
                call
            };

            if spelled(source, tokens, open + 1, scan as usize) > cap {
                return false;
            }
        } else if depth == 0 && tokens[scan as usize].text(source) == b"|" {
            return false;
        }

        scan += 1;
    }

    depth == 0
}

fn arm_arrow(
    source: &[u8],
    tokens: &[Token],
    start: u32,
    arrow: u32,
    lead: u32,
    flattens: bool,
    width: u32,
) -> u32 {
    if !flattens {
        return column_of(source, tokens, arrow, width) + 3;
    }

    lead + spelled(source, tokens, start, arrow as usize) + 4
}

fn armed<K, T>(tree: &Tree<K>, source: &[u8], tokens: &[Token], rules: Tails<K>, flags: &mut [u8])
where
    K: Kind<Error = T>,
    T: Copy,
{
    let nodes = tree.as_slice();

    for node in nodes {
        let Some((body, stop)) = arm_body(nodes, source, tokens, rules, node) else {
            continue;
        };

        if arm_forced(source, tokens, body.token_start) {
            arm_marks(source, tokens, body.token_start, stop, flags);

            continue;
        }

        if bodied_head(source, tokens, body.token_start) {
            continue;
        }

        let lead = leading_of(source, tokens, node.token_start, rules.indent);

        let flattens = ARM_ARROWS
            && pattern_flat(
                source,
                tokens,
                node.token_start,
                body.token_start - 1,
                (rules.call_width, rules.literal),
            );

        let arrow = arm_arrow(
            source,
            tokens,
            node.token_start,
            body.token_start - 1,
            lead,
            flattens,
            rules.indent,
        );
        let margin = u32::from(ARM_MARGINS);
        let spread = spelled(source, tokens, body.token_start, stop);

        if arrow + spread + margin <= rules.line {
            continue;
        }

        let next = lead + rules.indent + spread + margin;
        let seated = ARM_LINES && next <= rules.line;

        if ARM_LINED
            && !seated
            && lined_of(source, tokens, node.token_start, rules.indent) > rules.line
        {
            continue;
        }

        let jumped =
            ARM_INNERS && ARM_JUMPS.contains(&tokens[body.token_start as usize].text(source));
        let inner = if jumped { body } else { inner_of(nodes, body) };
        let width = (rules.bodies)(inner.kind);
        let chained = (rules.chained)(inner.kind) && linked(tokens, body.token_start, stop) < 2;

        let capped = if ARM_ARGUED && (rules.argued)(inner.kind) {
            argued(tokens, source, body.token_start, stop)
        } else {
            body.token_start
        };

        let over = width > 0 && !chained && spelled(source, tokens, capped, stop) > width;
        let lined = !over && next <= rules.line;

        if !lined && (rules.flattens)(inner.kind) {
            continue;
        }

        arm_marks(source, tokens, body.token_start, stop, flags);
    }
}

fn arm_body<'held, K, T>(
    nodes: &'held [Node<K>],
    source: &[u8],
    tokens: &[Token],
    rules: Tails<K>,
    node: &'held Node<K>,
) -> Option<(&'held Node<K>, usize)>
where
    K: Kind<Error = T>,
    T: Copy,
{
    if !(rules.arms)(node.kind) || rules.line == 0 {
        return None;
    }

    let held = last_child(nodes, node);

    if held == NONE {
        return None;
    }

    let body = &nodes[held as usize];
    let stop = (body.token_end as usize).min(tokens.len());

    if body.token_start as usize >= stop || body.token_start == node.token_start {
        return None;
    }

    if remarked(tokens, node.token_start, node.token_end) || skipped(nodes, source, tokens, node) {
        return None;
    }

    Some((body, stop))
}

fn arm_forced(source: &[u8], tokens: &[Token], start: u32) -> bool {
    ARM_FORCES
        && matches!(
            tokens[start as usize].text(source),
            b"for" | b"if" | b"while"
        )
}

fn arm_marks(source: &[u8], tokens: &[Token], start: u32, stop: usize, flags: &mut [u8]) {
    let Some(open) = start.checked_sub(1) else {
        return;
    };

    if let Some(mark_at) = flags.get_mut(open as usize) {
        *mark_at |= BLOCK_OPENS;
    }

    if let Some(mark_at) = flags.get_mut(stop - 1) {
        *mark_at |= BLOCK_CLOSES;
    }

    if ARM_SEMIS && ARM_JUMPS.contains(&tokens[start as usize].text(source)) {
        if let Some(mark_at) = flags.get_mut(stop - 1) {
            *mark_at |= END_OWED;
        }
    }

    if let Some(comma) = tokens.get(stop) {
        if comma.kind == TokenKind::Punctuation(Punctuation::Comma) {
            if let Some(mark_at) = flags.get_mut(stop) {
                *mark_at |= BLOCK_DROPS;
            }
        }
    }
}

fn trailing(source: &[u8], tokens: &[Token], stop: usize, dropped: usize) -> u32 {
    let mut held = 0;
    let mut scan = stop;

    while scan < tokens.len() {
        let token = tokens[scan];

        if token.length == 0 || token.kind == TokenKind::Newline || scan == dropped {
            scan += 1;

            continue;
        }

        let text = token.text(source);

        if !matches!(text, b")" | b"]" | b"?" | b"," | b";") {
            return held;
        }

        held += u32::from(text == b"?") + columns(source, token.offset, token.end());

        if matches!(text, b"," | b";") {
            return held;
        }

        scan += 1;
    }

    held
}

fn dropped_body<K, T>(
    tree: &Tree<K>,
    source: &[u8],
    tokens: &[Token],
    rules: Tails<K>,
    flags: &mut [u8],
) where
    K: Kind<Error = T>,
    T: Copy,
{
    let nodes = tree.as_slice();

    for node in nodes {
        if !(rules.lambda)(node.kind) {
            continue;
        }

        let Some(block) = blocked(nodes, source, tokens, node) else {
            continue;
        };

        let expr = &nodes[block.child_first as usize];

        if (rules.forces)(expr.kind)
            || overflows(
                nodes,
                source,
                tokens,
                rules,
                node.token_start,
                expr,
                CALL_NESTED,
            )
        {
            continue;
        }

        let stop = (expr.token_end as usize).min(tokens.len());
        let under = seated(nodes, source, tokens, rules, node);
        let spread = under + spelled(source, tokens, node.token_start, stop);

        let flat = under
            + spelled(source, tokens, node.token_start, block.token_start as usize)
            + 1
            + spelled(source, tokens, expr.token_start, stop)
            + trailing(
                source,
                tokens,
                stop,
                (block.token_end as usize).saturating_sub(1),
            );

        let measured = if BODY_TAILS { flat } else { spread };

        if (rules.wraps)(expr.kind) && measured > rules.line {
            continue;
        }

        let front = column_of(source, tokens, node.token_start, rules.indent)
            + spelled(
                source,
                tokens,
                node.token_start,
                fronted(tokens, expr, stop),
            );

        if BODY_FRONTS && !(rules.wraps)(expr.kind) && front > rules.line {
            continue;
        }

        if let Some(mark_at) = flags.get_mut(block.token_start as usize) {
            *mark_at |= BLOCK_DROPS;
        }

        if let Some(mark_at) = flags.get_mut(block.token_end as usize - 1) {
            *mark_at |= BLOCK_DROPS;
        }
    }
}

fn fronted<K, T>(tokens: &[Token], expr: &Node<K>, stop: usize) -> usize
where
    K: Kind<Error = T>,
    T: Copy,
{
    let mut depth = 0_u32;
    let mut scan = expr.token_start as usize;

    while scan < stop {
        let kind = tokens[scan].kind;

        if kind == TokenKind::BlockStart && depth == 0 {
            return scan + 1;
        }

        if is_open(kind) {
            depth += 1;
        } else if is_close(kind) {
            depth = depth.saturating_sub(1);
        }

        scan += 1;
    }

    stop
}

fn columned_at(source: &[u8], head: u32, stop: u32, width: u32) -> u32 {
    if !TAB_COLUMNS {
        return columns(source, head, stop);
    }

    let mut total = 0;
    let mut run = head;
    let mut scan = head;

    while scan < stop && (scan as usize) < source.len() {
        if source[scan as usize] == b'\t' {
            total += columns(source, run, scan) + width;
            run = scan + 1;
        }

        scan += 1;
    }

    total + columns(source, run, scan)
}

fn lined_of(source: &[u8], tokens: &[Token], position: u32, width: u32) -> u32 {
    let offset = tokens[position as usize].offset as usize;
    let mut head = offset;

    while head > 0 && source[head - 1] != b'\n' {
        head -= 1;
    }

    let mut stop = offset;

    while stop < source.len() && source[stop] != b'\n' {
        stop += 1;
    }

    columned_at(source, count_of(head), count_of(stop), width)
}

fn leading_of(source: &[u8], tokens: &[Token], position: u32, width: u32) -> u32 {
    let offset = tokens[position as usize].offset as usize;
    let mut head = offset;

    while head > 0 && source[head - 1] != b'\n' {
        head -= 1;
    }

    let mut stop = head;

    while stop < source.len() && matches!(source[stop], b' ' | b'\t') {
        stop += 1;
    }

    columned_at(source, count_of(head), count_of(stop), width)
}

fn linked_at(source: &[u8], tokens: &[Token], from: u32, to: u32) -> u32 {
    let mut depth = 0_u32;
    let mut held = from;
    let mut scan = from;

    while scan < to {
        let text = tokens[scan as usize].text(source);

        if matches!(text, b"(" | b"[" | b"{") {
            depth += 1;
        } else if matches!(text, b")" | b"]" | b"}") {
            depth = depth.saturating_sub(1);
        } else if depth == 0 && text == b"." {
            held = scan;
        }

        scan += 1;
    }

    held
}

fn seated<K, T>(
    nodes: &[Node<K>],
    source: &[u8],
    tokens: &[Token],
    rules: Tails<K>,
    node: &Node<K>,
) -> u32
where
    K: Kind<Error = T>,
    T: Copy,
{
    let mut found = None;
    let mut held = node;

    for _ in 0..CHAIN_WALK_MAX {
        if held.parent == NONE {
            break;
        }

        held = &nodes[held.parent as usize];

        if (rules.chained)(held.kind) {
            found = Some(held);
        }
    }

    let Some(chain) = found else {
        return parted_seat(nodes, source, tokens, rules, node)
            .unwrap_or_else(|| column_of(source, tokens, node.token_start, rules.indent));
    };

    let stop = (chain.token_end as usize).min(tokens.len());
    let width = (rules.bodies)(chain.kind);
    let room =
        rules
            .line
            .saturating_sub(column_of(source, tokens, chain.token_start, rules.indent));

    let budget = if width > 0 && linked(tokens, chain.token_start, stop) >= 2 {
        room.min(width)
    } else {
        room
    };

    if spelled(source, tokens, chain.token_start, stop) <= budget {
        return column_of(source, tokens, node.token_start, rules.indent);
    }

    let dot = linked_at(source, tokens, chain.token_start, node.token_start);

    leading_of(source, tokens, chain.token_start, rules.indent)
        + rules.indent
        + spelled(source, tokens, dot, node.token_start as usize)
}

fn parted_seat<K, T>(
    nodes: &[Node<K>],
    source: &[u8],
    tokens: &[Token],
    rules: Tails<K>,
    node: &Node<K>,
) -> Option<u32>
where
    K: Kind<Error = T>,
    T: Copy,
{
    if !CALL_SEATS {
        return None;
    }

    let held = last_child(nodes, node);

    if held == NONE {
        return None;
    }

    let body = &nodes[held as usize];
    let (open, _) = calling(source, tokens, node.token_start)?;

    if stubbed_run(source, tokens, open, body.token_start) <= rules.call_width {
        return None;
    }

    Some(leading_of(source, tokens, open, rules.indent) + rules.indent)
}

fn column_of(source: &[u8], tokens: &[Token], position: u32, width: u32) -> u32 {
    let offset = tokens[position as usize].offset as usize;
    let mut head = offset;

    while head > 0 && source[head - 1] != b'\n' {
        head -= 1;
    }

    columned_at(source, count_of(head), count_of(offset), width)
}

fn remarked(tokens: &[Token], from: u32, to: u32) -> bool {
    let stop = (to as usize).min(tokens.len());

    if stop.saturating_sub(from as usize) > TAIL_SCAN_MAX as usize {
        return true;
    }

    tokens[from as usize..stop]
        .iter()
        .any(|token| token.kind == TokenKind::Comment)
}

fn blocked<'held, K, T>(
    nodes: &'held [Node<K>],
    source: &[u8],
    tokens: &[Token],
    node: &Node<K>,
) -> Option<&'held Node<K>>
where
    K: Kind<Error = T>,
    T: Copy,
{
    let held = last_child(nodes, node);

    if held == NONE {
        return None;
    }

    let mut block = &nodes[held as usize];

    if block.token_start <= node.token_start || block.token_end as usize > tokens.len() {
        return None;
    }

    let bar = tokens[block.token_start as usize - 1].text(source);

    if bar != b"|" && bar != b"||" {
        return None;
    }

    for _ in 0..TAIL_WALK_MAX {
        let inner = block.child_first;

        if inner == NONE {
            return None;
        }

        let child = &nodes[inner as usize];

        if child.sibling_next != NONE {
            return None;
        }

        if child.token_start == block.token_start && child.token_end == block.token_end {
            block = child;

            continue;
        }

        if child.token_start != block.token_start + 1 || child.token_end + 1 != block.token_end {
            return None;
        }

        if tokens[child.token_end as usize - 1].kind
            == TokenKind::Punctuation(Punctuation::Semicolon)
        {
            return None;
        }

        return (tokens[block.token_start as usize].kind == TokenKind::BlockStart
            && tokens[block.token_end as usize - 1].kind == TokenKind::BlockEnd
            && !remarked(tokens, block.token_start, block.token_end))
        .then_some(block);
    }

    None
}

fn bounded<K, T>(
    nodes: &[Node<K>],
    source: &[u8],
    tokens: &[Token],
    rules: Tails<K>,
    block: &Node<K>,
) -> bool
where
    K: Kind<Error = T>,
    T: Copy,
{
    if rules.width == 0 {
        return false;
    }

    let mut held = block;

    for _ in 0..TAIL_WALK_MAX {
        if held.parent == NONE {
            return false;
        }

        held = &nodes[held.parent as usize];

        if !(rules.bounds)(held.kind) {
            continue;
        }

        let stop = (held.token_end as usize).min(tokens.len());

        if held.token_start as usize >= stop {
            return false;
        }

        let from = tokens[held.token_start as usize].offset;
        let to = tokens[stop - 1].end();

        return columns(source, from, to) > rules.width;
    }

    false
}

fn tails<K, T>(tree: &Tree<K>, source: &[u8], tokens: &[Token], rules: Tails<K>, flags: &mut [u8])
where
    K: Kind<Error = T>,
    T: Copy,
{
    let nodes = tree.as_slice();

    for node in nodes {
        if node.token_end == 0 || node.token_end as usize > tokens.len() || node.parent == NONE {
            continue;
        }

        let parent = &nodes[node.parent as usize];

        if !(rules.owes)(node.kind, parent.kind) {
            continue;
        }

        if !spans_lines(source, tokens, parent.token_start, parent.token_end)
            && !bounded(nodes, source, tokens, rules, parent)
        {
            continue;
        }

        if let Some(mark_at) = flags.get_mut((node.token_end - 1) as usize) {
            *mark_at |= END_OWED;
        }
    }
}

fn dropping(
    source: &[u8],
    tokens: &[Token],
    position: u32,
    out: &mut Buffer,
    written: &mut u32,
) -> bool {
    let token = tokens[position as usize];
    let opens = token.kind == TokenKind::BlockStart;

    let head = if opens {
        token.offset
    } else {
        tokens[position as usize - 1].end()
    };

    if head > *written && !out.push_bytes(&source[*written as usize..head as usize]) {
        return false;
    }

    *written = token.end().max(*written);

    if !opens {
        return true;
    }

    if out.as_bytes().last().is_none_or(|byte| *byte != b' ') && !out.push_bytes(b" ") {
        return false;
    }

    let Some(next) = tokens.get(position as usize + 1) else {
        return true;
    };

    *written = next.offset.max(*written);

    true
}

pub fn tailed<K, T>(
    tree: &Tree<K>,
    source: &[u8],
    tokens: &[Token],
    rules: Tails<K>,
    stream: &mut Terminators,
) -> bool
where
    K: Kind<Error = T>,
    T: Copy,
{
    let Terminators {
        added,
        origins,
        marks,
        roles,
        source: out,
        tokens: held,
    } = stream;

    added.clear();
    origins.clear();
    marks.clear();
    out.clear();
    roles.clear();
    held.clear();

    for _ in 0..tokens.len() {
        if !marks.push(0) {
            return false;
        }
    }

    let flags = &mut **marks;

    tails(tree, source, tokens, rules, flags);
    bodied(tree, source, tokens, rules, flags);
    dropped_body(tree, source, tokens, rules, flags);
    armed(tree, source, tokens, rules, flags);

    let mut written = 0;

    for position in 0..count_of(tokens.len()) {
        let token = tokens[position as usize];
        let mark = flags[position as usize];

        if mark & BLOCK_DROPS != 0 {
            if !dropping(source, tokens, position, out, &mut written) {
                return false;
            }

            continue;
        }

        let moved = count_of(out.as_bytes().len()) + (token.offset - written);

        if !held.push(Token {
            kind: token.kind,
            length: token.length,
            offset: moved,
        }) || !added.push(0)
            || !origins.push(token.offset)
        {
            return false;
        }

        let wanted = (
            mark & END_OWED != 0 && !separated_already(tokens, flags, position),
            mark & BLOCK_CLOSES != 0,
            mark & BLOCK_OPENS != 0,
        );

        if !adding(
            source,
            token,
            wanted,
            out,
            (held, added, origins),
            &mut written,
        ) {
            return false;
        }
    }

    out.push_bytes(&source[written as usize..])
}

fn adding(
    source: &[u8],
    token: Token,
    wanted: (bool, bool, bool),
    out: &mut Buffer,
    marks: (
        &mut BoundedVec<Token>,
        &mut BoundedVec<u8>,
        &mut BoundedVec<u32>,
    ),
    written: &mut u32,
) -> bool {
    let (owed, closes, opens) = wanted;
    let (held, added, origins) = marks;

    if !owed && !closes && !opens {
        return true;
    }

    if !out.push_bytes(&source[*written as usize..token.end() as usize]) {
        return false;
    }

    *written = token.end();

    let writing = [
        (
            owed,
            SEMICOLON,
            1_u32,
            TokenKind::Punctuation(Punctuation::Semicolon),
            MASK_SEMICOLON,
        ),
        (closes, BRACE_CLOSE, 1, TokenKind::BlockEnd, MASK_CLOSE),
        (opens, BRACE_OPEN, 2, TokenKind::BlockStart, MASK_OPEN),
    ];

    for (writes, text, back, kind, code) in writing {
        if !writes {
            continue;
        }

        if !out.push_bytes(text) {
            return false;
        }

        let at = count_of(out.as_bytes().len()) - back;

        if !held.push(Token {
            kind,
            length: 1,
            offset: at,
        }) || !added.push(code)
            || !origins.push(u32::MAX)
        {
            return false;
        }
    }

    if BLOCK_BREAKS && opens {
        *written = blanked(source, *written);
    }

    true
}

fn blanked(source: &[u8], from: u32) -> u32 {
    let mut scan = from as usize;

    while scan < source.len() && matches!(source[scan], b' ' | b'\t' | b'\r') {
        scan += 1;
    }

    if scan < source.len() && source[scan] == b'\n' {
        return count_of(scan + 1);
    }

    from
}
