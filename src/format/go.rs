use crate::bounded::{BoundedVec, Buffer, Bytes as _, Span, count_of};
use crate::format::align::{self, Carry, Target};
use crate::format::brace::{self, Policy, ROLE_PART, ROLE_SPACED, ROLE_START, ROLE_TIGHT};
use crate::format::print::Options;
use crate::syntax::go::kind::GoKind as Kind;
use crate::token::{Punctuation, Token, TokenKind};
use crate::tree::{NONE, Structure, Tree};

const DEPTH_MAX: u32 = 64;

pub const POLICY: Policy = Policy {
    angle_calls: false,
    angle_objects: false,
    arm_bars: false,
    arm_empties: false,
    arm_flattens: false,
    arm_guards: false,
    arrow_after: &[],
    arrow_bodies: false,
    arrow_parens: false,
    assign_groups: false,
    assign_joins: false,
    assign_lines: false,
    assign_values: false,
    assign_wraps: false,
    chain_simples: false,
    chain_soles: false,
    chain_hugs: false,
    chain_joins: false,
    chain_groups: false,
    chain_width: 0,
    call_budgets: false,
    call_nests: false,
    call_width: 0,
    attribute_ends: false,
    attribute_joins: false,
    attribute_spans: false,
    attribute_width: 0,
    attribute_words: &[],
    bar_levels: false,
    binary_lines: false,
    binary_parts: false,
    binding_bases: &[],
    binding_codes: false,
    binding_leads: false,
    binder_words: &[],
    binding_words: &[],
    blank_edges: false,
    blank_max: 1,
    block_chains: false,
    block_joins: false,
    block_leads: &[],
    block_words: &[],
    body_owns: false,
    body_parts: false,
    body_words: &[],
    brace_bodies: false,
    brace_continues: true,
    brace_counts: false,
    brace_dedents: false,
    brace_hugs: true,
    brace_leads: false,
    brace_levels: true,
    brace_pairs: false,
    brace_parts: false,
    brace_remarks: false,
    brace_spaces: false,
    brace_spans: true,
    brace_words: &[b"interface", b"struct"],
    branch_joins: false,
    branch_width: 0,
    branch_words: &[],
    bracket_types: true,
    build_blocks: true,
    carriage_breaks: false,
    callee_marks: &[],
    callee_words: &[],
    cast_joins: false,
    cast_words: &[],
    clause_bases: false,
    clause_ends: false,
    clause_lines: false,
    clause_values: &[],
    clause_words: &[],
    close_hugs: true,
    colon_continues: false,
    comma_continues: true,
    comma_adds: false,
    comma_drops: false,
    comma_parts: false,
    compose_parts: false,
    construct_words: &[],
    continue_words: &[],
    convention_strings: false,
    define_joins: false,
    define_widths: false,
    define_words: &[],
    declare_lines: false,
    declaration_words: &[],
    declare_words: &[b"const", b"func", b"import", b"type", b"var"],
    dedent_words: &[b"case", b"default"],
    document_blocks: true,
    else_width: 0,
    empty_words: &[],
    end_words: &[b"break", b"continue", b"fallthrough", b"return"],
    field_width: 30,
    follow_heads: &[],
    follow_words: &[],
    generic_levels: false,
    generic_nests: false,
    generic_parts: false,
    group_words: &[],
    head_blocks: false,
    head_stops: &[],
    header_braces: false,
    header_extends: false,
    header_joins: false,
    header_levels: false,
    header_lines: false,
    header_parens: false,
    header_widths: false,
    header_words: &[],
    heritage_parts: false,
    hug_braces: true,
    hug_lambdas: false,
    hug_lasts: false,
    hug_soles: false,
    hug_words: &[b"chan", b"func", b"interface", b"map", b"struct"],
    inline_layout: false,
    inline_remarks: false,
    item_words: &[],
    key_quotes: false,
    key_words: &[],
    keyword_gaps: true,
    label_lines: true,
    label_words: &[],
    lambda_flattens: false,
    lead_words: &[b"/*"],
    level_words: &[],
    lifetime_tight: false,
    link_levels: false,
    link_nests: false,
    link_spans: false,
    list_blanks: false,
    list_fills: false,
    list_groups: false,
    list_hugs: false,
    list_leads: &[],
    list_mixes: 0,
    list_tight: &[],
    list_remarks: false,
    list_sorts: false,
    list_spreads: false,
    list_width: 0,
    list_words: &[],
    literal_joins: false,
    literal_width: 0,
    macro_bodies: false,
    macro_defines: false,
    macro_gaps: false,
    macro_indents: false,
    macro_spans: false,
    member_words: &[],
    nested_levels: false,
    number_forms: false,
    object_words: &[],
    operand_joins: false,
    operand_levels: false,
    operand_words: &[b"assert", b"require"],
    operator_words: &[],
    order_words: &[],
    parameter_words: &[],
    pattern_frames: false,
    pattern_words: &[],
    postfix_words: &[b"++", b"--"],
    prefix_words: &[],
    printed_gaps: false,
    raise_hugged: false,
    remark_carries: true,
    remark_dedents: false,
    sentinel_colons: false,
    sequence_lines: false,
    sequence_stops: &[],
    remark_gaps: true,
    remark_levels: false,
    remark_suffix: false,
    remark_tails: false,
    return_parens: false,
    rest_binds: false,
    remark_leads: true,
    root_joins: false,
    row_parts: false,
    signature_words: &[b"func"],
    skip_words: &[],
    slice_colons: true,
    sole_hugs: false,
    sole_joins: false,
    source_gaps: false,
    source_values: &[],
    source_words: &[],
    spaced_words: &[],
    span_levels: false,
    spread_blanks: false,
    spread_owns: false,
    tight_from_source: &[],
    spec_depths: true,
    special_macros: &[],
    string_quotes: false,
    template_spans: false,
    template_units: false,
    ternary_colon: false,
    ternary_levels: false,
    ternary_parts: false,
    test_joins: false,
    tight_words: &[],
    value_cap: 0,
    value_columns: true,
    value_words: &[],
    variant_width: 0,
    verbatim_words: &[],
    type_leads: &[],
    type_words: &[],
    unary_words: &[
        b"!",
        b"&",
        b"&^",
        b"*",
        b"+",
        b"-",
        b"...",
        b"<-",
        b"^",
        b"~",
    ],
    union_parts: false,
    units: false,
    width_lists: false,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Outcome {
    Complete,
    Overflow,
    Refusal,
}

pub struct Input<'held> {
    pub options: Options,
    pub outcome: Structure,
    pub raw: &'held [Kind],
    pub source: &'held [u8],
    pub tokens: &'held [Token],
    pub tree: &'held Tree<Kind>,
}

#[derive(Debug)]
pub struct Formatter {
    held: BoundedVec<Token>,
    inner: brace::Formatter,
    order: BoundedVec<u32>,
    placed: BoundedVec<u8>,
    positions: BoundedVec<u8>,
    roles: BoundedVec<u8>,
    scratch: Buffer,
    staged: Buffer,
    stream: Buffer,
}

const COMMENT: &[u8] = b"//";
const DOCUMENT_MARKS: [u8; 3] = *b"*+-";

#[derive(Clone, Copy)]
struct Run<'held> {
    bytes: &'held [u8],
    first: u32,
    from: u32,
    last: u32,
    prefix: u32,
    to: u32,
}

impl<'held> Run<'held> {
    fn count(&self) -> u32 {
        let mut found = 0;
        let mut offset = self.from;

        while offset < self.to {
            found += 1;
            offset = ended(self.bytes, offset) + 1;
        }

        found
    }

    fn line(&self, index: u32) -> &'held [u8] {
        let held = self.text(index);

        if held.len() < self.prefix as usize {
            return &[];
        }

        let body = &held[self.prefix as usize..];

        if blanked(body) { &[] } else { body }
    }

    fn raw(&self, index: u32) -> &'held [u8] {
        let mut found = 0;
        let mut offset = self.from;

        while offset < self.to {
            let end = ended(self.bytes, offset);

            if found == index {
                return &self.bytes[offset as usize..end as usize];
            }

            found += 1;
            offset = end + 1;
        }

        &[]
    }

    fn text(&self, index: u32) -> &'held [u8] {
        let held = &self.raw(index)[COMMENT.len().min(self.raw(index).len())..];

        if held.first() == Some(&b' ') {
            &held[1..]
        } else {
            held
        }
    }
}

fn blanked(text: &[u8]) -> bool {
    text.iter().all(|byte| *byte == b' ' || *byte == b'\t')
}

fn ended(bytes: &[u8], offset: u32) -> u32 {
    let mut end = offset as usize;

    while end < bytes.len() && bytes[end] != b'\n' {
        end += 1;
    }

    count_of(end)
}

fn shared(left: &[u8], right: &[u8]) -> u32 {
    let mut held = 0;

    while held < left.len() && held < right.len() && left[held] == right[held] {
        held += 1;
    }

    count_of(held)
}

fn spaced(text: &[u8]) -> u32 {
    let mut held = 0;

    while held < text.len() && (text[held] == b' ' || text[held] == b'\t') {
        held += 1;
    }

    count_of(held)
}

fn directed(text: &[u8]) -> bool {
    if text.starts_with(b"line ") || text.starts_with(b"extern ") || text.starts_with(b"export ") {
        return true;
    }

    let Some(colon) = text.iter().position(|byte| *byte == b':') else {
        return false;
    };

    if colon == 0 || colon + 1 >= text.len() {
        return false;
    }

    (0..=colon + 1)
        .all(|held| held == colon || text[held].is_ascii_lowercase() || text[held].is_ascii_digit())
}

fn marked(text: &[u8]) -> bool {
    let body = &text[spaced(text) as usize..];

    let Some(head) = body.first() else {
        return false;
    };

    if DOCUMENT_MARKS.contains(head) || *head == b'#' || body.starts_with(b"\xE2\x80\xA2") {
        return true;
    }

    if *head == b'['
        && body
            .iter()
            .position(|byte| *byte == b']')
            .is_some_and(|at| body[at + 1..].starts_with(b":"))
    {
        return true;
    }

    let digits = body.iter().take_while(|byte| byte.is_ascii_digit()).count();

    digits > 0 && matches!(body.get(digits), Some(b'.' | b')'))
}

fn documents(bytes: &[u8], to: u32) -> bool {
    if to >= count_of(bytes.len()) {
        return false;
    }

    let end = ended(bytes, to);
    let past = &bytes[to as usize..end as usize];

    past.first()
        .is_some_and(|byte| *byte != b' ' && *byte != b'\t')
        && !past.starts_with(b"/*")
        && !past.starts_with(b"import")
}

fn spanned(run: &Run<'_>, at: u32) -> Option<(u32, u32, bool)> {
    if spaced(run.line(at)) > 0 {
        let mut index = at + 1;

        while index < run.last {
            let line = run.line(index);

            if !line.is_empty() && spaced(line) == 0 {
                break;
            }

            index += 1;
        }

        let mut end = index;

        while end > at && run.line(end - 1).is_empty() {
            end -= 1;
        }

        if end < run.last && run.line(end).starts_with(b"}") {
            return None;
        }

        return Some((at, end, true));
    }

    let mut index = at + 1;

    while index < run.last {
        let line = run.line(index);

        if line.is_empty() || spaced(line) > 0 {
            break;
        }

        index += 1;
    }

    if index < run.last && !run.line(index).is_empty() {
        let above = run.line(index - 1);

        if above.ends_with(b"{") || above.ends_with(b"\\") {
            return None;
        }
    }

    Some((at, index, false))
}

fn coded(run: &Run<'_>, start: u32, end: u32, out: &mut Buffer) -> bool {
    let head = run.line(start);
    let mut prefix = &head[..spaced(head) as usize];

    for index in start + 1..end {
        let line = run.line(index);

        if line.is_empty() {
            continue;
        }

        prefix = &prefix[..shared(prefix, &line[..spaced(line) as usize]) as usize];
    }

    for index in start..end {
        let line = run.line(index);

        if line.is_empty() {
            if !out.push_bytes(b"//\n") {
                return false;
            }

            continue;
        }

        if !out.push_bytes(b"//\t")
            || !out.push_bytes(&line[prefix.len()..])
            || !out.push_bytes(b"\n")
        {
            return false;
        }
    }

    true
}

fn parted(run: &Run<'_>, start: u32, end: u32, out: &mut Buffer) -> bool {
    for index in start..end {
        if !out.push_bytes(b"// ") || !out.push_bytes(run.line(index)) || !out.push_bytes(b"\n") {
            return false;
        }
    }

    true
}

fn unindented(run: &mut Run<'_>) -> bool {
    let count = run.count();

    for index in 0..count {
        let text = run.text(index);

        if directed(text) || marked(text) {
            return false;
        }
    }

    run.first = 0;
    run.last = count;

    while run.first < run.last && blanked(run.text(run.first)) {
        run.first += 1;
    }

    while run.last > run.first && blanked(run.text(run.last - 1)) {
        run.last -= 1;
    }

    if run.first == run.last {
        return false;
    }

    let head = run.text(run.first);
    let mut prefix = &head[..spaced(head) as usize];

    for index in run.first + 1..run.last {
        let text = run.text(index);

        if blanked(text) {
            continue;
        }

        prefix = &prefix[..shared(prefix, &text[..spaced(text) as usize]) as usize];
    }

    run.prefix = count_of(prefix.len());

    true
}

fn spanning(run: &Run<'_>) -> bool {
    let mut index = run.first;

    while index < run.last {
        while index < run.last && run.line(index).is_empty() {
            index += 1;
        }

        if index >= run.last {
            break;
        }

        let Some((_, end, _)) = spanned(run, index) else {
            return false;
        };

        index = end;
    }

    true
}

fn remarked(bytes: &[u8], from: u32, to: u32, out: &mut Buffer) -> bool {
    if !documents(bytes, to) {
        return false;
    }

    let mut run = Run {
        bytes,
        first: 0,
        from,
        last: 0,
        prefix: 0,
        to,
    };

    if !unindented(&mut run) || !spanning(&run) {
        return false;
    }

    let mut blocks = 0;
    let mut index = run.first;

    while index < run.last {
        while index < run.last && run.line(index).is_empty() {
            index += 1;
        }

        if index >= run.last {
            break;
        }

        let Some((start, end, code)) = spanned(&run, index) else {
            return false;
        };

        if blocks > 0 && !out.push_bytes(b"//\n") {
            return false;
        }

        blocks += 1;

        if !(if code {
            coded(&run, start, end, out)
        } else {
            parted(&run, start, end, out)
        }) {
            return false;
        }

        index = end;
    }

    true
}

#[must_use]
pub fn documented(bytes: &[u8], out: &mut Buffer) -> bool {
    out.clear();

    let count = count_of(bytes.len());
    let mut carry = Carry::None;
    let mut offset = 0;

    while offset < count {
        let end = ended(bytes, offset);
        let line = &bytes[offset as usize..end as usize];

        if carry != Carry::None || !line.starts_with(COMMENT) {
            carry = align::crosses(line, carry);

            if !out.push_bytes(&bytes[offset as usize..(end + 1).min(count) as usize]) {
                return false;
            }

            offset = end + 1;

            continue;
        }

        let mut stop = offset;

        while stop < count {
            let held = ended(bytes, stop);

            if !bytes[stop as usize..held as usize].starts_with(COMMENT) {
                break;
            }

            stop = held + 1;
        }

        let edge = stop.min(count);
        let staged = remarked(bytes, offset, edge, out);

        if !staged && !out.push_bytes(&bytes[offset as usize..edge as usize]) {
            return false;
        }

        offset = stop;
    }

    true
}

const CONSTRAINT_AND: u8 = 2;
const CONSTRAINT_MAX: usize = 128;
const CONSTRAINT_NOT: u8 = 1;
const CONSTRAINT_OR: u8 = 3;
const CONSTRAINT_TAG: u8 = 0;
const GO_BUILD: &[u8] = b"//go:build";
const IGNORE_TAG: &[u8] = b"ignore";
const PLUS_BUILD: &[u8] = b"+build";

#[derive(Clone, Copy)]
struct Node<'held> {
    kind: u8,
    left: u32,
    right: u32,
    text: &'held [u8],
}

struct Constraint<'held> {
    at: u32,
    count: u32,
    held: [Node<'held>; CONSTRAINT_MAX],
    line: &'held [u8],
    tagged: bool,
    token: (u32, u32),
}

fn tagging(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'.' || byte >= 0x80
}

fn valid_tag(word: &[u8]) -> bool {
    !word.is_empty() && word.iter().all(|byte| tagging(*byte))
}

impl<'held> Constraint<'held> {
    fn new(line: &'held [u8]) -> Self {
        Self {
            at: 0,
            count: 0,
            held: [Node {
                kind: CONSTRAINT_TAG,
                left: 0,
                right: 0,
                text: b"",
            }; CONSTRAINT_MAX],
            line,
            tagged: false,
            token: (0, 0),
        }
    }

    fn push(&mut self, node: Node<'held>) -> Option<u32> {
        if self.count as usize >= CONSTRAINT_MAX {
            return None;
        }

        self.held[self.count as usize] = node;
        self.count += 1;

        Some(self.count - 1)
    }

    fn tag(&mut self, text: &'held [u8]) -> Option<u32> {
        self.push(Node {
            kind: CONSTRAINT_TAG,
            left: 0,
            right: 0,
            text,
        })
    }

    fn joined(&mut self, kind: u8, left: u32, right: u32) -> Option<u32> {
        self.push(Node {
            kind,
            left,
            right,
            text: b"",
        })
    }

    fn negate(&mut self, held: u32) -> Option<u32> {
        self.push(Node {
            kind: CONSTRAINT_NOT,
            left: held,
            right: 0,
            text: b"",
        })
    }

    fn text(&self) -> &'held [u8] {
        &self.line[self.token.0 as usize..self.token.1 as usize]
    }

    fn lex(&mut self) -> bool {
        self.tagged = false;

        while (self.at as usize) < self.line.len()
            && matches!(self.line[self.at as usize], b' ' | b'\t')
        {
            self.at += 1;
        }

        if self.at as usize >= self.line.len() {
            self.token = (self.at, self.at);

            return true;
        }

        let byte = self.line[self.at as usize];

        if matches!(byte, b'(' | b')' | b'!') {
            self.token = (self.at, self.at + 1);
            self.at += 1;

            return true;
        }

        if matches!(byte, b'&' | b'|') {
            if self.line.get(self.at as usize + 1) != Some(&byte) {
                return false;
            }

            self.token = (self.at, self.at + 2);
            self.at += 2;

            return true;
        }

        let mut end = self.at;

        while (end as usize) < self.line.len() && tagging(self.line[end as usize]) {
            end += 1;
        }

        if end == self.at {
            return false;
        }

        self.token = (self.at, end);
        self.at = end;
        self.tagged = true;

        true
    }

    fn or(&mut self, budget: u32) -> Option<u32> {
        let mut held = self.and(budget)?;

        while self.text() == b"||" {
            let right = self.and(budget)?;

            held = self.joined(CONSTRAINT_OR, held, right)?;
        }

        Some(held)
    }

    fn and(&mut self, budget: u32) -> Option<u32> {
        let mut held = self.not(budget)?;

        while self.text() == b"&&" {
            let right = self.not(budget)?;

            held = self.joined(CONSTRAINT_AND, held, right)?;
        }

        Some(held)
    }

    fn not(&mut self, budget: u32) -> Option<u32> {
        if budget == 0 || !self.lex() {
            return None;
        }

        if self.text() != b"!" {
            return self.atom(budget);
        }

        if !self.lex() || self.text() == b"!" {
            return None;
        }

        let held = self.atom(budget)?;

        self.negate(held)
    }

    fn atom(&mut self, budget: u32) -> Option<u32> {
        if self.text() == b"(" {
            let held = self.or(budget - 1)?;

            if self.text() != b")" || !self.lex() {
                return None;
            }

            return Some(held);
        }

        if !self.tagged {
            return None;
        }

        let held = self.text();

        if !self.lex() {
            return None;
        }

        self.tag(held)
    }

    fn read(&mut self, text: &'held [u8]) -> Option<u32> {
        self.at = 0;
        self.line = text;

        let held = self.or(count_of(CONSTRAINT_MAX))?;

        if !self.text().is_empty() {
            return None;
        }

        Some(held)
    }

    fn read_plus(&mut self, text: &'held [u8]) -> Option<u32> {
        let mut clauses = None;

        for clause in text.split(|byte| matches!(*byte, b' ' | b'\t')) {
            if clause.is_empty() {
                continue;
            }

            let mut lits = None;

            for lit in clause.split(|byte| *byte == b',') {
                let mut word = lit;
                let mut negated = false;

                if word.starts_with(b"!!") || word == b"!" {
                    word = IGNORE_TAG;
                } else {
                    if let Some(rest) = word.strip_prefix(b"!") {
                        negated = true;
                        word = rest;
                    }

                    if !valid_tag(word) {
                        word = IGNORE_TAG;
                    }
                }

                let mut one = self.tag(word)?;

                if negated {
                    one = self.negate(one)?;
                }

                lits = Some(match lits {
                    Some(found) => self.joined(CONSTRAINT_AND, found, one)?,
                    None => one,
                });
            }

            let Some(found) = lits else {
                continue;
            };

            clauses = Some(match clauses {
                Some(one) => self.joined(CONSTRAINT_OR, one, found)?,
                None => found,
            });
        }

        match clauses {
            Some(held) => Some(held),
            None => self.tag(IGNORE_TAG),
        }
    }

    fn lowered(&mut self, node: u32, negated: bool, budget: u32) -> Option<u32> {
        if budget == 0 {
            return None;
        }

        let held = self.held[node as usize];

        if held.kind == CONSTRAINT_TAG {
            return if negated {
                self.negate(node)
            } else {
                Some(node)
            };
        }

        if held.kind == CONSTRAINT_NOT {
            if self.held[held.left as usize].kind == CONSTRAINT_TAG && !negated {
                return Some(node);
            }

            return self.lowered(held.left, !negated, budget - 1);
        }

        let left = self.lowered(held.left, negated, budget - 1)?;
        let right = self.lowered(held.right, negated, budget - 1)?;

        let kind = if negated == (held.kind == CONSTRAINT_AND) {
            CONSTRAINT_OR
        } else {
            CONSTRAINT_AND
        };

        self.joined(kind, left, right)
    }
}

fn rendered(held: &Constraint<'_>, node: u32, rank: u8, out: &mut Buffer, budget: u32) -> bool {
    if budget == 0 {
        return false;
    }

    let one = held.held[node as usize];

    if one.kind == CONSTRAINT_TAG {
        return out.push_bytes(one.text);
    }

    if one.kind == CONSTRAINT_NOT {
        let inner = held.held[one.left as usize].kind;
        let wrapped = inner == CONSTRAINT_AND || inner == CONSTRAINT_OR;

        return out.push_bytes(b"!")
            && (!wrapped || out.push_bytes(b"("))
            && rendered(held, one.left, CONSTRAINT_TAG, out, budget - 1)
            && (!wrapped || out.push_bytes(b")"));
    }

    let wrapped = rank != 0 && one.kind != rank;
    let word: &[u8] = if one.kind == CONSTRAINT_AND {
        b" && "
    } else {
        b" || "
    };

    (!wrapped || out.push_bytes(b"("))
        && rendered(held, one.left, one.kind, out, budget - 1)
        && out.push_bytes(word)
        && rendered(held, one.right, one.kind, out, budget - 1)
        && (!wrapped || out.push_bytes(b")"))
}

fn constrained(line: &[u8]) -> Option<&[u8]> {
    let held = line.strip_prefix(GO_BUILD)?;
    let trim = held.trim_ascii();

    if held.len() == trim.len() && !held.is_empty() {
        return None;
    }

    Some(trim)
}

fn plussed(line: &[u8]) -> Option<&[u8]> {
    let held = line.strip_prefix(COMMENT)?.trim_ascii();
    let rest = held.strip_prefix(PLUS_BUILD)?;
    let trim = rest.trim_ascii();

    if rest.len() == trim.len() && !rest.is_empty() {
        return None;
    }

    Some(trim)
}

fn literal(held: &Constraint<'_>, node: u32) -> bool {
    let one = held.held[node as usize];

    one.kind == CONSTRAINT_TAG
        || one.kind == CONSTRAINT_NOT && held.held[one.left as usize].kind == CONSTRAINT_TAG
}

fn anded_literals(held: &Constraint<'_>, node: u32, budget: u32) -> bool {
    if budget == 0 {
        return false;
    }

    let one = held.held[node as usize];

    if one.kind != CONSTRAINT_AND {
        return literal(held, node);
    }

    anded_literals(held, one.left, budget - 1) && anded_literals(held, one.right, budget - 1)
}

fn ored_literals(held: &Constraint<'_>, node: u32, budget: u32) -> bool {
    if budget == 0 {
        return false;
    }

    let one = held.held[node as usize];

    if one.kind != CONSTRAINT_OR {
        return anded_literals(held, node, budget - 1);
    }

    ored_literals(held, one.left, budget - 1) && ored_literals(held, one.right, budget - 1)
}

fn plus_read_ok(held: &Constraint<'_>, node: u32, budget: u32, flat: &mut bool) -> bool {
    if budget == 0 {
        return false;
    }

    let one = held.held[node as usize];

    if one.kind == CONSTRAINT_AND {
        return plus_read_ok(held, one.left, budget - 1, flat)
            && plus_read_ok(held, one.right, budget - 1, flat);
    }

    if one.kind == CONSTRAINT_OR {
        *flat = false;
    }

    ored_literals(held, node, budget)
}

fn plus_commas(
    held: &Constraint<'_>,
    node: u32,
    out: &mut Buffer,
    budget: u32,
    first: &mut bool,
) -> bool {
    if budget == 0 {
        return false;
    }

    let one = held.held[node as usize];

    if one.kind == CONSTRAINT_AND {
        return plus_commas(held, one.left, out, budget - 1, first)
            && plus_commas(held, one.right, out, budget - 1, first);
    }

    if !*first && !out.push_bytes(b",") {
        return false;
    }

    *first = false;

    rendered(held, node, 0, out, budget)
}

fn plus_spaces(held: &Constraint<'_>, node: u32, out: &mut Buffer, budget: u32) -> bool {
    if budget == 0 {
        return false;
    }

    let one = held.held[node as usize];

    if one.kind == CONSTRAINT_OR {
        return plus_spaces(held, one.left, out, budget - 1)
            && plus_spaces(held, one.right, out, budget - 1);
    }

    let mut first = true;

    out.push_bytes(b" ") && plus_commas(held, node, out, budget, &mut first)
}

fn plus_lines(held: &Constraint<'_>, node: u32, out: &mut Buffer, budget: u32) -> bool {
    if budget == 0 {
        return false;
    }

    let one = held.held[node as usize];

    if one.kind == CONSTRAINT_AND {
        return plus_lines(held, one.left, out, budget - 1)
            && plus_lines(held, one.right, out, budget - 1);
    }

    out.push_bytes(b"// +build") && plus_spaces(held, node, out, budget) && out.push_bytes(b"\n")
}

const CONSTRAINT_LINES: usize = 32;

struct Placement {
    goes: [u32; CONSTRAINT_LINES],
    going: usize,
    insert: u32,
    last: u32,
    plus: [u32; CONSTRAINT_LINES],
    plussing: usize,
}

fn placed(bytes: &[u8]) -> Option<Placement> {
    let count = count_of(bytes.len());
    let mut carry = Carry::None;
    let mut held = Placement {
        goes: [0; CONSTRAINT_LINES],
        going: 0,
        insert: 0,
        last: 0,
        plus: [0; CONSTRAINT_LINES],
        plussing: 0,
    };
    let mut leading = true;
    let mut offset = 0;

    while offset < count {
        let end = ended(bytes, offset);
        let line = &bytes[offset as usize..end as usize];
        let crossed = carry != Carry::None;

        carry = align::crosses(line, carry);

        let body = line.trim_ascii_start();

        if !crossed && constrained(body).is_some() {
            held.goes[held.going.min(CONSTRAINT_LINES - 1)] = offset;
            held.going += 1;
        } else if !crossed && plussed(body).is_some() {
            held.plus[held.plussing.min(CONSTRAINT_LINES - 1)] = offset;
            held.plussing += 1;
        } else {
            held.last = offset;
        }

        if leading {
            if crossed || !body.is_empty() && !body.starts_with(COMMENT) {
                leading = false;
            } else if body.is_empty() {
                held.insert = end + 1;
            }
        }

        offset = end + 1;
    }

    if held.going == 0 && held.plussing == 0
        || held.going > CONSTRAINT_LINES
        || held.plussing > CONSTRAINT_LINES
    {
        return None;
    }

    if held.going > 0 && held.goes[0] < held.insert {
        held.insert = held.goes[0];
    } else if held.plussing > 0 && held.plus[0] < held.insert {
        held.insert = held.plus[0];
    }

    Some(held)
}

fn dropping(held: &Placement, offset: u32) -> bool {
    held.goes[..held.going].contains(&offset) || held.plus[..held.plussing].contains(&offset)
}

fn written_block(bytes: &[u8], held: &Placement, out: &mut Buffer) -> bool {
    let mut read = Constraint::new(b"");
    let mut root = None;

    if held.going == 0 {
        for offset in &held.plus[..held.plussing] {
            let line = &bytes[*offset as usize..ended(bytes, *offset) as usize];

            let one = plussed(line.trim_ascii_start())
                .and_then(|text| read.read_plus(text))
                .and_then(|one| match root {
                    Some(found) => read.joined(CONSTRAINT_AND, found, one),
                    None => Some(one),
                });

            if one.is_none() {
                root = None;

                break;
            }

            root = one;
        }
    } else if held.going == 1 {
        let offset = held.goes[0];
        let line = &bytes[offset as usize..ended(bytes, offset) as usize];

        root = constrained(line.trim_ascii_start()).and_then(|text| read.read(text));
    }

    let Some(node) = root else {
        for offset in held.goes[..held.going]
            .iter()
            .chain(held.plus[..held.plussing].iter())
        {
            let line = &bytes[*offset as usize..ended(bytes, *offset) as usize];

            if !out.push_bytes(line) || !out.push_bytes(b"\n") {
                return false;
            }
        }

        return out.push_bytes(b"\n");
    };

    let budget = count_of(CONSTRAINT_MAX);

    if !out.push_bytes(b"//go:build ")
        || !rendered(&read, node, 0, out, budget)
        || !out.push_bytes(b"\n")
    {
        return false;
    }

    if held.plussing > 0 && !written_plus(&mut read, node, out, budget) {
        return false;
    }

    out.push_bytes(b"\n")
}

fn written_plus(read: &mut Constraint<'_>, node: u32, out: &mut Buffer, budget: u32) -> bool {
    let mut flat = true;

    let Some(held) = read
        .lowered(node, false, budget)
        .filter(|found| plus_read_ok(read, *found, budget, &mut flat))
    else {
        return out.push_bytes(b"// +build error: expression too complex for // +build lines\n");
    };

    if !flat {
        return plus_lines(read, held, out, budget);
    }

    let mut first = true;

    out.push_bytes(b"// +build ")
        && plus_commas(read, held, out, budget, &mut first)
        && out.push_bytes(b"\n")
}

const DIRECTIVE_RUN_MAX: usize = 256;
const LINE_DIRECTIVE: &[u8] = b"//line ";

fn line_columns(source: &[u8]) -> Option<([bool; DIRECTIVE_RUN_MAX], usize)> {
    let mut carry = Carry::None;
    let mut found = 0;
    let mut held = [false; DIRECTIVE_RUN_MAX];
    let mut offset = 0;

    while offset < count_of(source.len()) {
        let end = ended(source, offset);
        let line = &source[offset as usize..end as usize];
        let inside = carry != Carry::None;

        carry = align::crosses(line, carry);

        if !inside && line.trim_ascii_start().starts_with(LINE_DIRECTIVE) {
            if found == DIRECTIVE_RUN_MAX {
                return None;
            }

            held[found] = line.starts_with(LINE_DIRECTIVE);
            found += 1;
        }

        offset = end + 1;
    }

    Some((held, found))
}

pub fn relined(source: &[u8], bytes: &[u8], out: &mut Buffer) -> bool {
    out.clear();

    let Some((held, found)) = line_columns(source) else {
        return out.push_bytes(bytes);
    };

    let count = count_of(bytes.len());
    let mut carry = Carry::None;
    let mut offset = 0;
    let mut seen = 0;

    while offset < count {
        let end = ended(bytes, offset);
        let line = &bytes[offset as usize..end as usize];
        let inside = carry != Carry::None;

        carry = align::crosses(line, carry);

        let directive = !inside && line.trim_ascii_start().starts_with(LINE_DIRECTIVE);
        let raised = directive && seen < found && held[seen];

        if directive {
            seen += 1;
        }

        let written = if raised {
            line.trim_ascii_start()
        } else {
            line
        };

        if !out.push_bytes(written) {
            return false;
        }

        if end < count && !out.push_bytes(b"\n") {
            return false;
        }

        offset = end + 1;
    }

    true
}

#[must_use]
pub fn built(bytes: &[u8], out: &mut Buffer) -> bool {
    out.clear();

    let Some(held) = placed(bytes) else {
        return out.push_bytes(bytes);
    };

    if !out.push_bytes(&bytes[..held.insert as usize]) || !written_block(bytes, &held, out) {
        return false;
    }

    let count = count_of(bytes.len());
    let mut blanked = true;
    let mut offset = held.insert;
    let mut opened = true;

    while offset < count {
        let end = ended(bytes, offset);
        let line = &bytes[offset as usize..end as usize];

        if dropping(&held, offset) {
            opened = true;
            offset = end + 1;

            continue;
        }

        let empty = line.is_empty();
        let skipped = empty && (opened && blanked || offset == held.last);

        opened = false;

        if !skipped {
            if !out.push_bytes(line) || !out.push_bytes(b"\n") {
                return false;
            }

            blanked = empty;
        }

        offset = end + 1;
    }

    true
}

const POSITION_FREE: u8 = 1;
const QUEUE_MAX: usize = 8;

fn meaningful(raw: &[Kind], from: u32, to: u32) -> Option<u32> {
    let end = to.min(count_of(raw.len()));

    (from..end).find(|&at| !matches!(raw[at as usize], Kind::Comment | Kind::Newline))
}

fn closes(raw: &[Kind], open: u32) -> Option<u32> {
    let count = count_of(raw.len());
    let mut depth = 0;
    let mut at = open;

    while at < count {
        match raw[at as usize] {
            Kind::BraceOpen | Kind::BracketOpen | Kind::ParenOpen => depth += 1,
            Kind::BraceClose | Kind::BracketClose | Kind::ParenClose => {
                depth -= 1;

                if depth == 0 {
                    return (raw[at as usize] == Kind::BracketClose).then_some(at);
                }
            }
            _ => {}
        }

        at += 1;
    }

    None
}

fn depthless(raw: &[Kind], from: u32, to: u32, wanted: Kind) -> Option<u32> {
    let end = to.min(count_of(raw.len()));
    let mut depth: i32 = 0;
    let mut at = from;

    while at < end {
        let kind = raw[at as usize];

        match kind {
            Kind::BraceOpen | Kind::BracketOpen | Kind::ParenOpen => depth += 1,
            Kind::BraceClose | Kind::BracketClose | Kind::ParenClose => depth -= 1,
            _ if kind == wanted && depth == 0 => return Some(at),
            _ => {}
        }

        at += 1;
    }

    None
}

fn unpositioned(tree: &Tree<Kind>, raw: &[Kind], held: &mut [u8]) {
    for node in 0..tree.count() {
        let at = tree.at(node);

        let found = match at.kind {
            Kind::SelectorExpr | Kind::TypeAssertExpr => {
                let child = at.child_first;

                if child == NONE {
                    continue;
                }

                meaningful(raw, tree.at(child).token_end, at.token_end)
                    .filter(|&found| raw[found as usize] == Kind::Dot)
            }
            Kind::TypeSpec | Kind::ValueSpec => {
                depthless(raw, at.token_start, at.token_end, Kind::Equal)
            }
            Kind::ArrayType => closes(raw, at.token_start),
            Kind::MapType => {
                let Some(open) = meaningful(raw, at.token_start + 1, at.token_end)
                    .filter(|&found| raw[found as usize] == Kind::BracketOpen)
                else {
                    continue;
                };

                if let Some(flags) = held.get_mut(open as usize) {
                    *flags |= POSITION_FREE;
                }

                closes(raw, open)
            }
            _ => continue,
        };

        if let Some(flags) = found.and_then(|marked| held.get_mut(marked as usize)) {
            *flags |= POSITION_FREE;
        }
    }
}

fn queues(source: &[u8], tokens: &[Token], raw: &[Kind], at: u32) -> bool {
    let text = tokens[at as usize].text(source);

    if !text.starts_with(b"/*") || text.contains(&b'\n') {
        return false;
    }

    let mut scan = at;

    while scan > 0 {
        scan -= 1;

        if raw[scan as usize] == Kind::Comment {
            continue;
        }

        return raw[scan as usize] != Kind::Newline;
    }

    false
}

fn ordered(
    source: &[u8],
    tokens: &[Token],
    raw: &[Kind],
    positions: &[u8],
    order: &mut BoundedVec<u32>,
) -> bool {
    order.clear();

    let count = count_of(tokens.len());
    let mut queue = [0_u32; QUEUE_MAX];
    let mut queued = 0;
    let mut position = 0;

    for at in 0..count {
        if raw[at as usize] == Kind::Comment
            && queued < QUEUE_MAX
            && queues(source, tokens, raw, at)
        {
            queue[queued] = at;
            queued += 1;

            continue;
        }

        let token = tokens[at as usize];

        let next = if positions[at as usize] & POSITION_FREE != 0 {
            position
        } else {
            token.offset
        };

        let mut sent = 0;

        while sent < queued && tokens[queue[sent] as usize].offset < next {
            if !order.push(queue[sent]) {
                return false;
            }

            sent += 1;
        }

        queue.copy_within(sent..queued, 0);
        queued -= sent;

        if !order.push(at) {
            return false;
        }

        position = next + token.length;
    }

    for &held in queue.iter().take(queued) {
        if !order.push(held) {
            return false;
        }
    }

    true
}

fn braced<'held>(
    input: &Input<'held>,
    source: &'held [u8],
    tokens: &'held [Token],
    roles: &'held [u8],
) -> brace::Input<'held> {
    brace::Input {
        added: &[],
        origin: &[],
        origins: &[],
        gives: &[],
        macros: &[],
        roles,
        options: input.options,
        policy: POLICY,
        source,
        tokens,
    }
}

fn restreamed(
    source: &[u8],
    tokens: &[Token],
    roles: &[u8],
    order: &[u32],
    out: &mut Buffer,
    held: &mut BoundedVec<Token>,
    placed: &mut BoundedVec<u8>,
) -> bool {
    out.clear();
    held.clear();
    placed.clear();

    let mut last = 0;
    let mut previous = NONE;

    for &at in order {
        let token = tokens[at as usize];

        let gap: &[u8] = if previous == NONE {
            &source[..token.offset as usize]
        } else if at == previous + 1 {
            &source[tokens[previous as usize].end() as usize..token.offset as usize]
        } else if token.kind == TokenKind::Comment {
            b" "
        } else {
            b""
        };

        if !out.push_bytes(gap) {
            return false;
        }

        let offset = out.count();

        if !out.push_bytes(token.text(source)) {
            return false;
        }

        if !held.push(Token { offset, ..token }) || !placed.push(roles[at as usize]) {
            return false;
        }

        last = last.max(token.end());
        previous = at;
    }

    out.push_bytes(&source[last as usize..])
}

fn broken(input: &Input<'_>) -> bool {
    if input.outcome != Structure::Complete || !input.tree.errors().is_empty() {
        return true;
    }

    if input.raw.contains(&Kind::ErrorToken) {
        return true;
    }

    if input
        .tree
        .as_slice()
        .iter()
        .any(|node| node.kind == Kind::ErrorNode)
    {
        return true;
    }

    if !brace::closed(input.source, input.tokens, false, true) {
        return true;
    }

    !brace::balanced(input.source, input.tokens)
}

fn combines(tokens: &[Token], source: &[u8], position: u32) -> bool {
    let held = tokens[position as usize].text(source);

    let Some(next) = tokens
        .get(position as usize + 1..)
        .and_then(|rest| rest.iter().find(|token| token.length > 0))
    else {
        return false;
    };

    let past = next.text(source);

    matches!(
        (held, past.first()),
        (b"&", Some(b'&' | b'^'))
            | (b"+", Some(b'+'))
            | (b"-", Some(b'-'))
            | (b"/", Some(b'*'))
            | (b"<", Some(b'-' | b'<'))
    )
}

fn precedence_of(text: &[u8]) -> u32 {
    match text {
        b"||" => 1,
        b"&&" => 2,
        b"==" | b"!=" | b"<" | b"<=" | b">" | b">=" => 3,
        b"+" | b"-" | b"|" | b"^" => 4,
        b"*" | b"/" | b"%" | b"<<" | b">>" | b"&" | b"&^" => 5,
        _ => 0,
    }
}

#[derive(Clone, Copy, Debug)]
struct Levels {
    five: bool,
    four: bool,
    problem: u32,
}

impl Levels {
    fn merged(self, other: Self) -> Self {
        Self {
            five: self.five || other.five,
            four: self.four || other.four,
            problem: self.problem.max(other.problem),
        }
    }
}

fn operands(tree: &Tree<Kind>, node: u32) -> (u32, u32) {
    let left = tree.at(node).child_first;

    if left == NONE {
        return (NONE, NONE);
    }

    (left, tree.at(left).sibling_next)
}

fn operator_of(tree: &Tree<Kind>, tokens: &[Token], source: &[u8], node: u32) -> Option<u32> {
    let (left, right) = operands(tree, node);

    if left == NONE {
        return None;
    }

    let last = if right == NONE {
        tree.at(node).token_end
    } else {
        tree.at(right).token_start
    };

    (tree.at(left).token_end..last)
        .find(|held| precedence_of(tokens[*held as usize].text(source)) > 0)
}

fn precedence_at(tree: &Tree<Kind>, tokens: &[Token], source: &[u8], node: u32) -> u32 {
    if tree.at(node).kind != Kind::BinaryExpr {
        return 0;
    }

    operator_of(tree, tokens, source, node)
        .map_or(0, |held| precedence_of(tokens[held as usize].text(source)))
}

fn unary_of(tree: &Tree<Kind>, tokens: &[Token], source: &[u8], node: u32) -> &'static [u8] {
    const SIGNS: [&[u8]; 4] = [b"&", b"*", b"+", b"-"];

    let start = tree.at(node).token_start;
    let text = tokens[start as usize].text(source);

    SIGNS
        .into_iter()
        .find(|held| *held == text)
        .unwrap_or_default()
}

fn walk_binary(tree: &Tree<Kind>, tokens: &[Token], source: &[u8], node: u32) -> Levels {
    let prec = precedence_at(tree, tokens, source, node);
    let (left, right) = operands(tree, node);

    let mut held = Levels {
        five: prec == 5,
        four: prec == 4,
        problem: 0,
    };

    if left != NONE
        && tree.at(left).kind == Kind::BinaryExpr
        && precedence_at(tree, tokens, source, left) >= prec
    {
        held = held.merged(walk_binary(tree, tokens, source, left));
    }

    if right == NONE {
        return held;
    }

    if tree.at(right).kind == Kind::BinaryExpr {
        if precedence_at(tree, tokens, source, right) > prec {
            held = held.merged(walk_binary(tree, tokens, source, right));
        }

        return held;
    }

    let Some(operator) = operator_of(tree, tokens, source, node) else {
        return held;
    };

    held.problem = held.problem.max(problem_of(
        tokens[operator as usize].text(source),
        tree,
        tokens,
        source,
        right,
    ));

    held
}

fn problem_of(
    operator: &[u8],
    tree: &Tree<Kind>,
    tokens: &[Token],
    source: &[u8],
    right: u32,
) -> u32 {
    if tree.at(right).kind == Kind::StarExpr {
        return if operator == b"/" { 5 } else { 0 };
    }

    if tree.at(right).kind != Kind::UnaryExpr {
        return 0;
    }

    let sign = unary_of(tree, tokens, source, right);

    if matches!((operator, sign), (b"/", b"*") | (b"&" | b"&^", b"&")) {
        return 5;
    }

    if matches!((operator, sign), (b"+", b"+") | (b"-", b"-")) {
        return 4;
    }

    0
}

fn cutoff_of(tree: &Tree<Kind>, tokens: &[Token], source: &[u8], node: u32, depth: u32) -> u32 {
    let held = walk_binary(tree, tokens, source, node);

    if held.problem > 0 {
        return held.problem + 1;
    }

    if held.four && held.five {
        return if depth == 1 { 5 } else { 4 };
    }

    if depth == 1 {
        return 6;
    }

    4
}

fn arguments(tree: &Tree<Kind>, node: u32) -> u32 {
    let mut count = 0;
    let mut child = tree.at(node).child_first;

    while child != NONE && count <= DEPTH_MAX {
        count += 1;
        child = tree.at(child).sibling_next;
    }

    count.saturating_sub(1)
}

fn values(tree: &Tree<Kind>, tokens: &[Token], source: &[u8], node: u32) -> u32 {
    let held = tree.at(node);
    let mut assign = None;
    let mut count = 0;
    let mut child = held.child_first;

    while child != NONE && count <= DEPTH_MAX {
        let bytes = tree.at(child).token_start;

        if assign.is_none() {
            let mut scan = bytes;

            while scan > held.token_start && assign.is_none() {
                scan -= 1;

                if tokens[scan as usize].text(source).ends_with(b"=") {
                    assign = Some(scan);
                }
            }
        }

        if assign.is_some_and(|found| bytes > found) {
            count += 1;
        }

        child = tree.at(child).sibling_next;
    }

    count
}

const fn reduced(depth: u32) -> u32 {
    if depth > 1 { depth - 1 } else { 1 }
}

struct Walk<'held> {
    roles: &'held mut [u8],
    source: &'held [u8],
    tokens: &'held [Token],
    tree: &'held Tree<Kind>,
}

impl Walk<'_> {
    fn expression(&mut self, node: u32, depth: u32, budget: u32) {
        if node == NONE || budget == 0 {
            return;
        }

        match self.tree.at(node).kind {
            Kind::BinaryExpr => self.binary(node, depth, budget),
            Kind::ParenExpr => self.children(node, reduced(depth), budget),
            Kind::SelectorExpr | Kind::UnaryExpr => self.children(node, depth, budget),
            Kind::StarExpr => self.children(node, 1, budget),
            Kind::CallExpr => {
                let held = if arguments(self.tree, node) > 1 {
                    depth + 1
                } else {
                    depth
                };

                self.children(node, held, budget);
            }
            Kind::IndexExpr | Kind::IndexListExpr => self.indexed(node, depth, budget),
            Kind::SliceExpr => {
                if depth == 1 {
                    self.sliced(node);
                }

                self.indexed(node, depth, budget);
            }
            Kind::AssignStmt => {
                let held = u32::from(values(self.tree, self.tokens, self.source, node) > 1);

                self.children(node, 1 + held, budget);
            }
            Kind::ValueSpec => {
                let held = u32::from(
                    !POLICY.spec_depths && values(self.tree, self.tokens, self.source, node) > 1,
                );

                self.children(node, 1 + held, budget);
            }
            _ => self.children(node, 1, budget),
        }
    }

    fn indexed(&mut self, node: u32, depth: u32, budget: u32) {
        let mut child = self.tree.at(node).child_first;
        let mut first = true;

        while child != NONE {
            let held = if first { 1 } else { depth + 1 };

            self.expression(child, held, budget - 1);

            first = false;
            child = self.tree.at(child).sibling_next;
        }
    }

    fn sliced(&mut self, node: u32) {
        let mut binaries = false;
        let mut indices = 0;
        let mut child = self.tree.at(self.tree.at(node).child_first).sibling_next;

        while child != NONE && indices <= DEPTH_MAX {
            binaries = binaries || self.tree.at(child).kind == Kind::BinaryExpr;
            indices += 1;
            child = self.tree.at(child).sibling_next;
        }

        if indices < 2 || !binaries {
            return;
        }

        let mut depth = 0;

        for position in self.tree.at(node).token_start..self.tree.at(node).token_end {
            let kind = self.tokens[position as usize].kind;

            if kind == TokenKind::Punctuation(Punctuation::BracketOpen) {
                depth += 1;
            }

            if kind == TokenKind::Punctuation(Punctuation::BracketClose) {
                depth -= 1;
            }

            if depth != 1 || kind != TokenKind::Punctuation(Punctuation::Colon) {
                continue;
            }

            if let Some(flags) = self.roles.get_mut(position as usize) {
                *flags |= ROLE_SPACED;
            }
        }
    }

    fn children(&mut self, node: u32, depth: u32, budget: u32) {
        let mut child = self.tree.at(node).child_first;

        while child != NONE {
            self.expression(child, depth, budget - 1);

            child = self.tree.at(child).sibling_next;
        }
    }

    fn binary(&mut self, node: u32, depth: u32, budget: u32) {
        let cutoff = cutoff_of(self.tree, self.tokens, self.source, node, depth);
        let prec = precedence_at(self.tree, self.tokens, self.source, node);
        let (left, right) = operands(self.tree, node);

        if prec >= cutoff {
            if let Some(operator) = operator_of(self.tree, self.tokens, self.source, node) {
                if !combines(self.tokens, self.source, operator) {
                    if let Some(flags) = self.roles.get_mut(operator as usize) {
                        *flags |= ROLE_TIGHT;
                    }
                }
            }
        }

        let same = u32::from(precedence_at(self.tree, self.tokens, self.source, left) != prec);

        self.expression(left, depth + same, budget - 1);
        self.expression(right, depth + 1, budget - 1);
    }
}

impl Formatter {
    pub fn reserve(element_count_max: u32, scratch_bytes_max: u32) -> Self {
        assert!(scratch_bytes_max > 0);

        assert!(!crate::allocation::is_frozen());

        Self {
            held: BoundedVec::reserve(element_count_max),
            inner: brace::Formatter::reserve(element_count_max, scratch_bytes_max),
            order: BoundedVec::reserve(element_count_max),
            placed: BoundedVec::reserve(element_count_max),
            positions: BoundedVec::reserve(element_count_max),
            roles: BoundedVec::reserve(element_count_max),
            scratch: Buffer::reserve(scratch_bytes_max),
            staged: Buffer::reserve(scratch_bytes_max),
            stream: Buffer::reserve(scratch_bytes_max),
        }
    }

    fn hoisted(&mut self, input: &Input<'_>) -> Option<bool> {
        self.positions.clear();

        for _ in 0..input.tokens.len() {
            if !self.positions.push(0) {
                return None;
            }
        }

        unpositioned(input.tree, input.raw, &mut self.positions);

        if !ordered(
            input.source,
            input.tokens,
            input.raw,
            &self.positions,
            &mut self.order,
        ) {
            return None;
        }

        if self
            .order
            .iter()
            .enumerate()
            .all(|(at, &held)| count_of(at) == held)
        {
            return Some(false);
        }

        let staged = restreamed(
            input.source,
            input.tokens,
            &self.roles,
            &self.order,
            &mut self.stream,
            &mut self.held,
            &mut self.placed,
        );

        staged.then_some(true)
    }

    fn parted(&mut self, input: &Input<'_>) {
        let tree = input.tree;
        let held = &mut *self.roles;

        for node in 0..tree.count() {
            let at = tree.at(node);

            if at.kind != Kind::BlockStmt || at.parent == NONE {
                continue;
            }

            let parent = tree.at(at.parent).kind;

            if matches!(parent, Kind::FuncDecl | Kind::FuncLit) {
                continue;
            }

            if parent == Kind::SelectStmt && at.child_first == NONE {
                continue;
            }

            if let Some(flags) = held.get_mut(at.token_start as usize) {
                *flags |= ROLE_PART;
            }
        }

        for node in 0..tree.count() {
            let at = tree.at(node);

            if !matches!(
                at.kind,
                Kind::CaseClause | Kind::CommClause | Kind::LabeledStmt
            ) {
                continue;
            }

            let found = depthless(input.raw, at.token_start, at.token_end, Kind::Colon);

            if let Some(flags) = found.and_then(|colon| held.get_mut(colon as usize)) {
                *flags |= ROLE_PART;
            }
        }
    }

    fn tightened(&mut self, input: &Input<'_>) {
        let mut walk = Walk {
            roles: &mut self.roles,
            source: input.source,
            tokens: input.tokens,
            tree: input.tree,
        };

        walk.expression(0, 1, DEPTH_MAX);
    }

    fn generics(&mut self, input: &Input<'_>) {
        let tree = input.tree;
        let held = &mut *self.roles;

        for node in 0..tree.count() {
            let start = tree.at(node).token_start;

            if tree.at(node).kind != Kind::FieldList {
                continue;
            }

            let open = input.tokens.get(start as usize).map(|token| token.kind);

            let close = match open {
                Some(TokenKind::Punctuation(Punctuation::BracketOpen)) => {
                    TokenKind::Punctuation(Punctuation::BracketClose)
                }
                Some(TokenKind::Punctuation(Punctuation::ParenOpen)) => {
                    TokenKind::Punctuation(Punctuation::ParenClose)
                }
                _ => continue,
            };

            let end = tree.at(node).token_end;

            if end == 0
                || input.tokens.get((end - 1) as usize).map(|token| token.kind) != Some(close)
            {
                continue;
            }

            if let Some(flags) = held.get_mut(start as usize) {
                *flags &= !ROLE_START;
            }
        }
    }

    #[must_use]
    fn columned(&mut self, line_width: u32) -> bool {
        if !align::align(
            self.scratch.as_bytes(),
            Target::Field,
            line_width,
            &mut self.staged,
        ) {
            return false;
        }

        if POLICY.value_columns {
            if !align::align(
                self.staged.as_bytes(),
                Target::Value,
                line_width,
                &mut self.scratch,
            ) {
                return false;
            }

            core::mem::swap(&mut self.scratch, &mut self.staged);
        }

        if !align::align(
            self.staged.as_bytes(),
            Target::Type,
            line_width,
            &mut self.scratch,
        ) {
            return false;
        }

        if !align::align(
            self.scratch.as_bytes(),
            Target::Tag,
            line_width,
            &mut self.staged,
        ) {
            return false;
        }

        if !align::align(
            self.staged.as_bytes(),
            Target::Assign,
            line_width,
            &mut self.scratch,
        ) {
            return false;
        }

        if !align::align(
            self.scratch.as_bytes(),
            Target::Body,
            line_width,
            &mut self.staged,
        ) {
            return false;
        }

        if !align::align(
            self.staged.as_bytes(),
            Target::Key,
            line_width,
            &mut self.scratch,
        ) {
            return false;
        }

        align::align(
            self.scratch.as_bytes(),
            Target::Comment,
            line_width,
            &mut self.staged,
        )
    }

    pub fn format(&mut self, input: &Input<'_>, out: &mut Buffer) -> Outcome {
        assert_eq!(input.tokens.len(), input.raw.len());

        if broken(input) {
            return Outcome::Refusal;
        }

        if !brace::marked(input.tree, input.tokens, &mut self.roles) {
            return Outcome::Overflow;
        }

        self.generics(input);
        self.parted(input);
        self.tightened(input);

        let Some(hoisted) = self.hoisted(input) else {
            return Outcome::Overflow;
        };

        let held = if hoisted {
            braced(input, self.stream.as_bytes(), &self.held, &self.placed)
        } else {
            braced(input, input.source, input.tokens, &self.roles)
        };

        if !self.inner.format(&held, &mut self.scratch) {
            return Outcome::Overflow;
        }

        if !self.columned(input.options.line_width) {
            return Outcome::Overflow;
        }

        if POLICY.document_blocks {
            if !documented(self.staged.as_bytes(), &mut self.scratch) {
                return Outcome::Overflow;
            }

            core::mem::swap(&mut self.scratch, &mut self.staged);
        }

        if POLICY.build_blocks {
            if !built(self.staged.as_bytes(), &mut self.scratch) {
                return Outcome::Overflow;
            }

            core::mem::swap(&mut self.scratch, &mut self.staged);
        }

        if !relined(input.source, self.staged.as_bytes(), &mut self.scratch) {
            return Outcome::Overflow;
        }

        core::mem::swap(&mut self.scratch, &mut self.staged);

        core::mem::swap(&mut self.scratch, &mut self.staged);

        out.clear();

        if !out.push_bytes(self.scratch.as_bytes()) {
            out.clear();

            return Outcome::Overflow;
        }

        Outcome::Complete
    }

    #[must_use]
    pub fn range(
        &mut self,
        input: &Input<'_>,
        lines: (u32, u32),
        out: &mut Buffer,
    ) -> Option<Span> {
        if self.format(input, out) != Outcome::Complete {
            return None;
        }

        brace::span_of(out.as_bytes(), lines)
    }
}
