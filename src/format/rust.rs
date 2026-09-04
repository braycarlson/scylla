use core::cmp::Ordering;

use crate::bounded::{Buffer, Bytes as _, Span};
use crate::format::align::{self, Target};
use crate::format::brace::{self, Policy};
use crate::format::mask::{Tails, Terminators};
use crate::format::print::Options;
use crate::syntax::rust::kind::RustKind as Kind;
use crate::token::Token;
use crate::tree::{Structure, Tree};

pub const POLICY: Policy = Policy {
    angle_calls: false,
    angle_objects: false,
    arm_empties: true,
    arm_flattens: true,
    arm_guards: true,
    arrow_after: &[],
    arrow_parens: false,
    assign_groups: false,
    assign_joins: true,
    assign_values: false,
    assign_wraps: true,
    chain_soles: true,
    chain_hugs: true,
    chain_joins: true,
    chain_groups: false,
    chain_width: 60,
    call_budgets: true,
    call_nests: true,
    call_width: 60,
    attribute_ends: true,
    attribute_joins: true,
    attribute_spans: true,
    attribute_width: 70,
    attribute_words: &[b"derive"],
    bar_levels: false,
    binary_parts: false,
    binding_bases: &[b"if"],
    binding_codes: false,
    binding_leads: true,
    binding_words: &[
        &[b"*", b"/", b"%"],
        &[b"+", b"-"],
        &[b"<<", b">>"],
        &[b"&"],
        &[b"^"],
        &[b"|"],
        &[b"==", b"!=", b"<", b">", b"<=", b">="],
        &[b"&&"],
        &[b"||"],
    ],
    blank_edges: false,
    blank_max: 1,
    block_chains: true,
    block_joins: true,
    block_leads: &[
        b"->",
        b"async",
        b"do",
        b"else",
        b"enum",
        b"extern",
        b"fn",
        b"for",
        b"gen",
        b"if",
        b"impl",
        b"loop",
        b"match",
        b"mod",
        b"move",
        b"struct",
        b"trait",
        b"try",
        b"union",
        b"unsafe",
        b"while",
    ],
    block_words: &[],
    body_parts: false,
    body_words: &[],
    brace_continues: true,
    brace_counts: false,
    brace_dedents: true,
    brace_hugs: false,
    brace_leads: false,
    brace_levels: true,
    brace_pairs: true,
    brace_parts: false,
    brace_remarks: true,
    brace_spaces: true,
    brace_spans: false,
    brace_words: &[],
    branch_joins: true,
    branch_width: 50,
    branch_words: &[b"if"],
    bracket_types: false,
    build_blocks: false,
    carriage_breaks: true,
    callee_marks: &[],
    callee_words: &[],
    cast_words: &[],
    clause_bases: true,
    clause_ends: true,
    clause_words: &[b"where"],
    close_hugs: false,
    colon_continues: true,
    comma_continues: false,
    comma_adds: false,
    comma_drops: false,
    construct_words: &[],
    continue_words: &[
        b"!=",
        b"&&",
        b"*",
        b"+",
        b"-",
        b"/",
        b"<",
        b"<<",
        b"<=",
        b"==",
        b">=",
        b">>",
        b"^",
        b"as",
        b"|",
        b"||",
    ],
    convention_strings: false,
    define_joins: true,
    define_widths: true,
    define_words: &[b"fn"],
    declaration_words: &[],
    declare_words: &[],
    dedent_words: &[],
    document_blocks: false,
    else_width: 50,
    empty_words: &[],
    end_words: &[],
    field_width: 0,
    follow_heads: &[b"for"],
    follow_words: &[],
    generic_levels: true,
    generic_nests: true,
    generic_parts: true,
    group_words: &[],
    head_blocks: true,
    head_stops: &[],
    header_braces: true,
    header_extends: true,
    header_joins: true,
    header_levels: false,
    header_parens: false,
    header_words: &[b"for", b"if", b"match", b"while"],
    heritage_parts: false,
    hug_braces: false,
    hug_lambdas: true,
    hug_lasts: false,
    hug_soles: false,
    hug_words: &[b"!", b"::", b"fn"],
    item_words: &[b"impl"],
    key_quotes: false,
    key_words: &[],
    keyword_gaps: false,
    label_lines: false,
    label_words: &[],
    lambda_flattens: true,
    lead_words: &[b"/*"],
    level_words: &[],
    lifetime_tight: true,
    link_levels: true,
    link_nests: true,
    link_spans: true,
    list_blanks: true,
    list_fills: true,
    list_groups: true,
    list_hugs: true,
    list_leads: &[b"::", b"use"],
    list_mixes: 10,
    list_tight: &[b"::", b"*"],
    list_remarks: true,
    list_sorts: true,
    list_spreads: false,
    list_width: 98,
    list_words: &[b"pub", b"use"],
    literal_joins: true,
    literal_width: 18,
    macro_bodies: true,
    macro_defines: true,
    macro_gaps: true,
    macro_indents: true,
    macro_spans: true,
    member_words: &[],
    nested_levels: true,
    number_forms: false,
    operand_joins: true,
    operand_words: &[b"Self", b"await", b"crate", b"self", b"super"],
    operator_words: &[],
    order_words: &[],
    parameter_words: &[],
    pattern_frames: true,
    pattern_words: &[b"match"],
    postfix_words: &[],
    prefix_words: &[b"$", b"@", b"'"],
    raise_hugged: true,
    remark_carries: false,
    remark_dedents: true,
    sentinel_colons: false,
    remark_gaps: false,
    remark_levels: false,
    return_parens: false,
    rest_binds: false,
    remark_leads: false,
    root_joins: true,
    row_parts: false,
    signature_words: &[],
    skip_words: &[b"rustfmt", b"::", b"skip"],
    slice_colons: true,
    sole_hugs: false,
    sole_joins: true,
    source_gaps: false,
    source_values: &[],
    source_words: &[b"|"],
    spaced_words: &[],
    span_levels: false,
    tight_from_source: &[b"!", b"*", b"+", b":", b"<", b">", b">>", b"?"],
    spec_depths: false,
    special_macros: &[
        (b"assert", 1),
        (b"assert_eq", 2),
        (b"assert_ne", 2),
        (b"debug", 0),
        (b"debug_assert", 1),
        (b"debug_assert_eq", 2),
        (b"debug_assert_ne", 2),
        (b"eprint", 0),
        (b"eprintln", 0),
        (b"error", 0),
        (b"format", 0),
        (b"format_args", 0),
        (b"info", 0),
        (b"panic", 0),
        (b"print", 0),
        (b"println", 0),
        (b"unreachable", 0),
        (b"warn", 0),
        (b"write", 1),
        (b"writeln", 1),
    ],
    string_quotes: false,
    template_spans: false,
    template_units: false,
    ternary_colon: false,
    ternary_levels: false,
    tight_words: &[b"#", b"::"],
    type_leads: &[],
    type_words: &[],
    unary_words: &[b"!", b"&", b"*", b"-", b"..", b"..="],
    union_parts: false,
    value_cap: 0,
    value_columns: false,
    value_words: &[],
    variant_width: 35,
    verbatim_words: &[],
    units: false,
    width_lists: false,
};

const IMPORT_RUN_MAX: usize = 256;
const IMPORT_ITEM_MAX: u32 = 128;
const LIST_TREES: bool = true;
const FILE_SKIPS: bool = true;
const ALIAS_TIES: bool = true;
const FILE_HEAD_MAX: u32 = 4096;
const TAIL_ENDS: bool = true;
const BODY_BLOCKS: bool = true;
const BODY_DROPS: bool = true;
const ARM_BLOCKS: bool = true;
const NO_MACRO: i32 = i32::MIN;
const RANK_CRATE: u8 = 2;
const RANK_GLOB: u8 = 4;
const RANK_LIST: u8 = 5;
const RANK_NAME: u8 = 3;
const RANK_SELF: u8 = 0;
const RANK_SUPER: u8 = 1;

#[derive(Clone, Copy, Debug)]
struct Import {
    end: usize,
    head: usize,
    start: usize,
}

#[derive(Clone, Copy, Debug)]
struct Reading {
    depth: i32,
    hashes: usize,
    macros: i32,
    raw: bool,
}

impl Import {
    const EMPTY: Self = Self {
        end: 0,
        head: 0,
        start: 0,
    };
}

impl Reading {
    const NEW: Self = Self {
        depth: 0,
        hashes: 0,
        macros: NO_MACRO,
        raw: false,
    };

    const fn quoted(self) -> bool {
        self.raw || self.macros != NO_MACRO
    }
}

const fn worded(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'_'
}

fn indent_of(line: &[u8]) -> usize {
    let mut held = 0;

    while held < line.len() && line[held] == b' ' {
        held += 1;
    }

    held
}

fn line_end(bytes: &[u8], offset: usize) -> usize {
    let mut held = offset;

    while held < bytes.len() && bytes[held] != b'\n' {
        held += 1;
    }

    held
}

fn found_at(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    let mut held = 0;

    while held + needle.len() <= haystack.len() {
        if haystack[held..].starts_with(needle) {
            return Some(held);
        }

        held += 1;
    }

    None
}

fn attributed(line: &[u8]) -> bool {
    let body = line.trim_ascii();

    body.starts_with(b"#[") && body.ends_with(b"]")
}

fn skips(line: &[u8]) -> bool {
    found_at(line, b"rustfmt::skip").is_some()
}

fn skipped_file(source: &[u8]) -> bool {
    if !FILE_SKIPS {
        return false;
    }

    let mut scan = 0;

    for _ in 0..FILE_HEAD_MAX {
        if scan >= source.len() {
            return false;
        }

        let stop = line_end(source, scan);
        let line = source[scan..stop.min(source.len())].trim_ascii();

        scan = stop + 1;

        if line.is_empty() || line.starts_with(b"//") {
            continue;
        }

        if !line.starts_with(b"#![") {
            return false;
        }

        if skips(line) {
            return true;
        }
    }

    false
}

fn use_at(line: &[u8]) -> Option<usize> {
    let mut held = 0;

    while held < line.len() && line[held] == b' ' {
        held += 1;
    }

    if line[held..].starts_with(b"pub") {
        held += 3;

        if line[held..].starts_with(b"(") {
            held += found_at(&line[held..], b")")? + 1;
        }

        while held < line.len() && line[held] == b' ' {
            held += 1;
        }
    }

    line[held..].starts_with(b"use ").then_some(held)
}

fn braced(line: &[u8]) -> i32 {
    let mut held = 0;

    for byte in line {
        if *byte == b'{' {
            held += 1;
        }

        if *byte == b'}' {
            held -= 1;
        }
    }

    held
}

fn macroed(line: &[u8]) -> bool {
    let body = line.trim_ascii_end();

    body.ends_with(b"! {") || body.ends_with(b"!{") || found_at(line, b"macro_rules!").is_some()
}

fn closes_raw(line: &[u8], hashes: usize) -> bool {
    let mut held = 0;

    while held < line.len() {
        if line[held] != b'"' {
            held += 1;

            continue;
        }

        let mut count = 0;

        while count < hashes && line.get(held + 1 + count) == Some(&b'#') {
            count += 1;
        }

        if count == hashes {
            return true;
        }

        held += 1;
    }

    false
}

fn opens_raw(line: &[u8]) -> Option<usize> {
    let mut held = 0;

    while held < line.len() {
        if line[held] != b'r' || held > 0 && worded(line[held - 1]) {
            held += 1;

            continue;
        }

        let mut hashes = held + 1;

        while hashes < line.len() && line[hashes] == b'#' {
            hashes += 1;
        }

        if line.get(hashes) != Some(&b'"') {
            held += 1;

            continue;
        }

        let count = hashes - held - 1;

        if !closes_raw(&line[hashes + 1..], count) {
            return Some(count);
        }

        held = hashes + 1;
    }

    None
}

fn stepped(held: Reading, line: &[u8]) -> Reading {
    let mut reading = held;

    if reading.raw {
        reading.raw = !closes_raw(line, reading.hashes);

        return reading;
    }

    if let Some(hashes) = opens_raw(line) {
        reading.hashes = hashes;
        reading.raw = true;

        return reading;
    }

    let opens = braced(line);

    if reading.macros == NO_MACRO && opens > 0 && macroed(line) {
        reading.macros = reading.depth;
    }

    reading.depth += opens;

    if reading.macros != NO_MACRO && reading.depth <= reading.macros {
        reading.macros = NO_MACRO;
    }

    reading
}

fn skipping(bytes: &[u8], offset: usize) -> Option<usize> {
    let mut held = false;
    let mut scan = offset;

    while scan < bytes.len() {
        let stop = line_end(bytes, scan);

        if !attributed(&bytes[scan..stop]) {
            break;
        }

        held = held || skips(&bytes[scan..stop]);
        scan = stop + 1;
    }

    if !held {
        return None;
    }

    let mut depth = 0;

    while scan < bytes.len() {
        let stop = line_end(bytes, scan);
        let body = bytes[scan..stop].trim_ascii_end();

        depth += braced(&bytes[scan..stop]);
        scan = stop + 1;

        if depth <= 0 && (body.ends_with(b";") || body.ends_with(b"}")) {
            break;
        }
    }

    Some(scan)
}

fn imported(bytes: &[u8], offset: usize) -> Option<Import> {
    let mut scan = offset;

    while scan < bytes.len() {
        let stop = line_end(bytes, scan);

        if !attributed(&bytes[scan..stop]) {
            break;
        }

        scan = stop + 1;
    }

    let opened = line_end(bytes, scan);

    use_at(&bytes[scan..opened])?;

    let head = scan;
    let mut end = scan;

    while end < bytes.len() {
        let stop = line_end(bytes, end);
        let ends = bytes[end..stop].trim_ascii_end().ends_with(b";");

        end = stop + 1;

        if ends {
            return Some(Import {
                end,
                head,
                start: offset,
            });
        }
    }

    None
}

fn collected(bytes: &[u8], offset: usize, held: &mut [Import]) -> usize {
    let mut count = 0;
    let mut indent = usize::MAX;
    let mut scan = offset;

    while count < held.len() {
        if skipping(bytes, scan).is_some() {
            break;
        }

        let Some(import) = imported(bytes, scan) else {
            break;
        };

        let stop = line_end(bytes, import.head);
        let level = indent_of(&bytes[import.head..stop]);

        if indent == usize::MAX {
            indent = level;
        }

        if level != indent {
            break;
        }

        held[count] = import;
        count += 1;
        scan = import.end;
    }

    count
}

fn aliased(text: &[u8]) -> (&[u8], Option<&[u8]>) {
    let held = text.trim_ascii();

    let Some(at) = found_at(held, b" as ") else {
        return (unraw(held), None);
    };

    (
        unraw(held[..at].trim_ascii_end()),
        Some(unraw(held[at + 4..].trim_ascii())),
    )
}

fn unraw(text: &[u8]) -> &[u8] {
    if text.starts_with(b"r#") {
        &text[2..]
    } else {
        text
    }
}

fn ranked_segment(text: &[u8]) -> u8 {
    match text {
        b"self" => RANK_SELF,
        b"super" => RANK_SUPER,
        b"crate" => RANK_CRATE,
        b"*" => RANK_GLOB,
        held if held.starts_with(b"{") => RANK_LIST,
        _ => RANK_NAME,
    }
}

fn compared(left: &[u8], right: &[u8]) -> Ordering {
    match ranked_pair(left, right) {
        Some(found) => found,
        None if LIST_TREES => listed_before(left, right),
        None => listed_bytes(left, right),
    }
}

fn ranked_pair(left: &[u8], right: &[u8]) -> Option<Ordering> {
    let (one, first) = aliased(left);
    let (two, second) = aliased(right);
    let held = ranked_segment(one);
    let other = ranked_segment(two);

    if held != other {
        return Some(held.cmp(&other));
    }

    if held == RANK_LIST {
        return None;
    }

    if one != two {
        return Some(ordering(brace::versioned(one, two)));
    }

    if ALIAS_TIES {
        return Some(Ordering::Equal);
    }

    Some(match (first, second) {
        (Some(alias), Some(named)) if alias != named => ordering(brace::versioned(alias, named)),
        (Some(_), None) => Ordering::Less,
        (None, Some(_)) => Ordering::Greater,
        _ => Ordering::Equal,
    })
}

fn listed_before(left: &[u8], right: &[u8]) -> Ordering {
    let mut held = element_at(left, 1);
    let mut other = element_at(right, 1);

    for _ in 0..IMPORT_ITEM_MAX {
        let (Some(one), Some(two)) = (held, other) else {
            return match (held.is_some(), other.is_some()) {
                (false, true) => Ordering::Less,
                (true, false) => Ordering::Greater,
                _ => Ordering::Equal,
            };
        };

        match treed_before(&left[one.0..one.1], &right[two.0..two.1]) {
            Ordering::Equal => (),
            found => return found,
        }

        held = element_at(left, one.2);
        other = element_at(right, two.2);
    }

    Ordering::Equal
}

fn treed_before(left: &[u8], right: &[u8]) -> Ordering {
    let mut held = 0;
    let mut other = 0;

    for _ in 0..IMPORT_ITEM_MAX {
        if held >= left.len() || other >= right.len() {
            break;
        }

        let (one, past) = segment(left, held, left.len());
        let (two, next) = segment(right, other, right.len());

        let found = match ranked_pair(&left[held..one], &right[other..two]) {
            Some(found) => found,
            None => listed_bytes(&left[held..one], &right[other..two]),
        };

        if found != Ordering::Equal {
            return found;
        }

        held = past;
        other = next;
    }

    match (held < left.len(), other < right.len()) {
        (false, true) => Ordering::Less,
        (true, false) => Ordering::Greater,
        _ => Ordering::Equal,
    }
}

fn element_at(text: &[u8], from: usize) -> Option<(usize, usize, usize)> {
    let stop = text.len().saturating_sub(1);
    let head = skipped(text, from);

    if head >= stop {
        return None;
    }

    let mut depth = 0_i32;
    let mut scan = head;

    while scan < stop {
        match text[scan] {
            b'{' => depth += 1,
            b'}' => depth -= 1,
            b',' if depth == 0 => break,
            _ => (),
        }

        scan += 1;
    }

    let mut end = scan;

    while end > head && text[end - 1].is_ascii_whitespace() {
        end -= 1;
    }

    Some((head, end, scan + 1))
}

fn skipped(text: &[u8], from: usize) -> usize {
    let mut held = from;

    while held < text.len() && text[held].is_ascii_whitespace() {
        held += 1;
    }

    held
}

fn digits_at(text: &[u8], from: usize) -> usize {
    let mut held = from;

    while held < text.len() && text[held].is_ascii_digit() {
        held += 1;
    }

    held
}

fn listed_bytes(left: &[u8], right: &[u8]) -> Ordering {
    let mut held = skipped(left, 0);
    let mut other = skipped(right, 0);

    while held < left.len() && other < right.len() {
        if left[held].is_ascii_digit() && right[other].is_ascii_digit() {
            let first = digits_at(left, held);
            let second = digits_at(right, other);
            let counted = (first - held).cmp(&(second - other));
            let found = counted.then_with(|| left[held..first].cmp(&right[other..second]));

            if found != Ordering::Equal {
                return found;
            }

            held = skipped(left, first);
            other = skipped(right, second);

            continue;
        }

        let one = brace::ranked(left[held]);
        let two = brace::ranked(right[other]);

        if one != two {
            return one.cmp(&two);
        }

        held = skipped(left, held + 1);
        other = skipped(right, other + 1);
    }

    (left.len() - held).cmp(&(right.len() - other))
}

const fn ordering(held: bool) -> Ordering {
    if held {
        Ordering::Less
    } else {
        Ordering::Greater
    }
}

fn segment(bytes: &[u8], from: usize, to: usize) -> (usize, usize) {
    let mut depth = 0_i32;
    let mut held = from;

    while held < to {
        if depth == 0 && bytes[held..to].starts_with(b"::") {
            return (held, held + 2);
        }

        if bytes[held] == b'{' {
            depth += 1;
        }

        if bytes[held] == b'}' {
            depth -= 1;
        }

        held += 1;
    }

    (to, to)
}

fn pathed(bytes: &[u8], held: Import) -> (usize, usize) {
    let stop = line_end(bytes, held.head);
    let from = held.head + use_at(&bytes[held.head..stop]).unwrap_or(0) + b"use ".len();
    let mut to = held.end.min(bytes.len());

    while to > from && bytes[to - 1] != b';' {
        to -= 1;
    }

    (from, to.saturating_sub(1).max(from))
}

fn precedes_import(bytes: &[u8], left: Import, right: Import) -> bool {
    let (mut held, first) = pathed(bytes, left);
    let (mut other, second) = pathed(bytes, right);

    while held < first && other < second {
        let (one, past) = segment(bytes, held, first);
        let (two, next) = segment(bytes, other, second);

        match compared(&bytes[held..one], &bytes[other..two]) {
            Ordering::Equal => (),
            found => return found == Ordering::Less,
        }

        held = past;
        other = next;
    }

    held >= first && other < second
}

fn ordered_imports(bytes: &[u8], held: &mut [Import]) {
    let mut index = 1;

    while index < held.len() {
        let mut scan = index;

        while scan > 0 && precedes_import(bytes, held[scan], held[scan - 1]) {
            held.swap(scan, scan - 1);

            scan -= 1;
        }

        index += 1;
    }
}

fn stepping(bytes: &[u8], from: usize, to: usize, reading: &mut Reading) {
    let mut scan = from;

    while scan < to {
        let stop = line_end(bytes, scan);

        *reading = stepped(*reading, &bytes[scan..stop]);
        scan = stop + 1;
    }
}

fn written(bytes: &[u8], from: usize, to: usize, reading: &mut Reading, out: &mut Buffer) -> bool {
    stepping(bytes, from, to, reading);

    out.push_bytes(&bytes[from..to.min(bytes.len())])
}

fn reordered(bytes: &[u8], out: &mut Buffer) -> bool {
    let mut held = [Import::EMPTY; IMPORT_RUN_MAX];
    let mut offset = 0;
    let mut reading = Reading::NEW;

    while offset < bytes.len() {
        let quoted = reading.quoted();
        let past = if quoted {
            None
        } else {
            skipping(bytes, offset)
        };

        if let Some(stop) = past {
            if !written(bytes, offset, stop, &mut reading, out) {
                return false;
            }

            offset = stop;

            continue;
        }

        let count = if quoted {
            0
        } else {
            collected(bytes, offset, &mut held)
        };

        if count < 2 {
            let stop = (line_end(bytes, offset) + 1).min(bytes.len());

            if !written(bytes, offset, stop, &mut reading, out) {
                return false;
            }

            offset = stop;

            continue;
        }

        let end = held[count - 1].end;

        stepping(bytes, offset, end, &mut reading);
        ordered_imports(bytes, &mut held[..count]);

        for import in &held[..count] {
            if !out.push_bytes(&bytes[import.start..import.end.min(bytes.len())]) {
                return false;
            }
        }

        offset = end;
    }

    true
}

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
    inner: brace::Formatter,
    scratch: Buffer,
    staged: Buffer,
    stream: Terminators,
}

fn owes(kind: Kind, parent: Kind) -> bool {
    parent == Kind::Block
        && matches!(
            kind,
            Kind::ExprBreak | Kind::ExprContinue | Kind::ExprReturn
        )
}

fn bounds(kind: Kind) -> bool {
    matches!(kind, Kind::ExprIf | Kind::Local)
}

fn lambda(kind: Kind) -> bool {
    BODY_BLOCKS && kind == Kind::ExprClosure
}

fn bodies(kind: Kind) -> u32 {
    match kind {
        Kind::ExprCall | Kind::ExprMacro | Kind::ExprTuple => POLICY.call_width,
        Kind::ExprMethodCall => POLICY.chain_width,
        Kind::ExprIf => POLICY.branch_width,
        _ => 0,
    }
}

fn argued(kind: Kind) -> bool {
    matches!(kind, Kind::ExprCall | Kind::ExprMacro)
}

fn chained(kind: Kind) -> bool {
    kind == Kind::ExprMethodCall
}

fn arms(kind: Kind) -> bool {
    ARM_BLOCKS && kind == Kind::Arm
}

fn flattens(kind: Kind) -> bool {
    matches!(
        kind,
        Kind::Block
            | Kind::ExprArray
            | Kind::ExprBlock
            | Kind::ExprCall
            | Kind::ExprClosure
            | Kind::ExprMacro
            | Kind::ExprMatch
            | Kind::ExprMethodCall
            | Kind::ExprStruct
            | Kind::ExprTuple
            | Kind::Macro
    )
}

fn forces(kind: Kind) -> bool {
    !BODY_DROPS
        || matches!(
            kind,
            Kind::ExprForLoop | Kind::ExprIf | Kind::ExprLoop | Kind::ExprWhile
        )
}

fn wraps(kind: Kind) -> bool {
    !matches!(
        kind,
        Kind::Block
            | Kind::ExprAsync
            | Kind::ExprBlock
            | Kind::ExprConst
            | Kind::ExprForLoop
            | Kind::ExprLoop
            | Kind::ExprMatch
            | Kind::ExprStruct
            | Kind::ExprTryBlock
            | Kind::ExprUnsafe
            | Kind::ExprWhile
    )
}

const TAILS: Tails<Kind> = Tails {
    argued,
    arms,
    bodies,
    bounds,
    call_width: POLICY.call_width,
    chained,
    flattens,
    forces,
    indent: 0,
    lambda,
    line: 0,
    owes,
    width: POLICY.else_width,
    wraps,
};

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

    if !brace::closed(input.source, input.tokens, true, true) {
        return true;
    }

    !brace::balanced(input.source, input.tokens)
}

impl Formatter {
    pub fn reserve(element_count_max: u32, scratch_bytes_max: u32) -> Self {
        assert!(scratch_bytes_max > 0);

        assert!(!crate::allocation::is_frozen());

        Self {
            inner: brace::Formatter::reserve(element_count_max, scratch_bytes_max),
            scratch: Buffer::reserve(scratch_bytes_max),
            staged: Buffer::reserve(scratch_bytes_max),
            stream: Terminators::reserve(element_count_max, scratch_bytes_max),
        }
    }

    #[must_use]
    pub fn format(&mut self, input: &Input<'_>, out: &mut Buffer) -> Outcome {
        assert_eq!(input.tokens.len(), input.raw.len());

        if broken(input) {
            return Outcome::Refusal;
        }

        if skipped_file(input.source) {
            out.clear();

            return if out.push_bytes(input.source) {
                Outcome::Complete
            } else {
                Outcome::Overflow
            };
        }

        if TAIL_ENDS
            && !brace::tailed(
                input.tree,
                input.source,
                input.tokens,
                Tails {
                    indent: input.options.indent_width,
                    line: input.options.line_width,
                    ..TAILS
                },
                &mut self.stream,
            )
        {
            return Outcome::Overflow;
        }

        let held = brace::Input {
            roles: &[],
            options: input.options,
            policy: POLICY,
            source: if TAIL_ENDS {
                self.stream.source()
            } else {
                input.source
            },
            tokens: if TAIL_ENDS {
                self.stream.tokens()
            } else {
                input.tokens
            },
        };

        if !self.inner.format(&held, &mut self.scratch) {
            return Outcome::Overflow;
        }

        if !align::align(self.scratch.as_bytes(), Target::Element, &mut self.staged) {
            return Outcome::Overflow;
        }

        out.clear();

        if !reordered(self.staged.as_bytes(), out) {
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
