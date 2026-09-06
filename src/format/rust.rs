use core::cmp::Ordering;

use crate::bounded::{BoundedVec, Buffer, Bytes as _, Span, count_of};
use crate::format::align::{self, Target};
use crate::format::brace::{self, Policy};
use crate::format::mask::{Tails, Terminators};
use crate::format::print::Options;
use crate::format::walk::{columns, ends_operand, is_close, is_open};
use crate::syntax::rust::kind::RustKind as Kind;
use crate::token::{Punctuation, Token, TokenKind};
use crate::tree::{Structure, Tree};

pub const POLICY: Policy = Policy {
    angle_calls: false,
    angle_objects: false,
    arm_bars: true,
    arm_empties: true,
    arm_flattens: true,
    arm_guards: true,
    arrow_after: &[],
    arrow_bodies: false,
    arrow_parens: false,
    assign_groups: false,
    assign_joins: true,
    assign_lines: false,
    assign_values: false,
    assign_wraps: true,
    chain_simples: false,
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
    binary_lines: false,
    binary_parts: false,
    binding_bases: &[b"if"],
    binding_codes: false,
    binding_leads: true,
    binder_words: &[],
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
    blank_edges: true,
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
    body_owns: false,
    body_parts: false,
    body_words: &[],
    brace_bodies: true,
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
    cast_joins: true,
    cast_words: &[],
    clause_bases: true,
    clause_ends: true,
    clause_lines: false,
    clause_values: &[b"type"],
    clause_words: &[b"where"],
    close_hugs: false,
    colon_continues: true,
    comma_continues: false,
    comma_adds: false,
    comma_drops: false,
    comma_parts: true,
    compose_parts: false,
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
    declare_lines: false,
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
    header_lines: true,
    header_parens: false,
    header_widths: true,
    header_words: &[b"for", b"if", b"match", b"while"],
    heritage_parts: false,
    hug_braces: false,
    hug_lambdas: true,
    hug_lasts: false,
    hug_soles: false,
    hug_words: &[b"!", b"::", b"fn"],
    inline_layout: false,
    inline_remarks: false,
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
    object_words: &[],
    operand_joins: true,
    operand_levels: true,
    operand_words: &[b"Self", b"await", b"crate", b"self", b"super"],
    operator_words: &[],
    order_words: &[],
    parameter_words: &[],
    pattern_frames: true,
    pattern_words: &[b"match"],
    postfix_words: &[],
    prefix_words: &[b"$", b"@", b"'"],
    printed_gaps: false,
    raise_hugged: true,
    remark_carries: false,
    remark_dedents: true,
    sentinel_colons: false,
    sequence_lines: false,
    sequence_stops: &[],
    remark_gaps: false,
    remark_levels: false,
    remark_suffix: false,
    remark_tails: true,
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
    spread_blanks: false,
    spread_owns: false,
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
    ternary_parts: false,
    test_joins: false,
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
const STRUCT_BODIES: bool = true;
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
    gives: BoundedVec<u32>,
    inner: brace::Formatter,
    lines: BoundedVec<u32>,
    macros: BoundedVec<u32>,
    scratch: Buffer,
    staged: Buffer,
    stream: Terminators,
}

const ELEMENT_ALIGNS: bool = true;
const GIVE_UPS: bool = true;
const GIVE_PASSES: u32 = 3;
const GIVE_REMARKS: bool = true;
const GIVE_VALUES: bool = true;
const GIVE_MACROS: bool = true;
const GIVE_COLONS: bool = true;
const GIVE_ITEMS: bool = true;
const GIVE_BRACES: bool = true;
const GIVE_LAMBDAS: bool = true;
const GIVE_LIVES: bool = true;
const GIVE_STRINGS: bool = true;

const GIVE_OPERATORS: [&[u8]; 12] = [
    b"!=",
    b"%",
    b"&&",
    b"*",
    b"+",
    b"-",
    b"/",
    b"<=",
    b"==",
    b">=",
    b"^",
    b"||",
];
const GIVE_MARKS_MAX: u32 = 1 << 12;
const GIVE_TOKENS: bool = true;
const MACRO_UPS: bool = true;
const MACRO_RULE_MAX: u32 = 8;
const MACRO_HEADS: &[&[u8]] = &[b"pub", b"unsafe"];
const ARM_GIVES: bool = true;
const GIVE_LONES: bool = true;
const GIVE_ATS: bool = true;
const LONE_KEEPS: &[&[u8]] = &[b"!", b"..", b","];
const ARM_GIVE_MAX: u32 = 8;
const ARM_SCAN_MAX: u32 = 256;

const ARM_STOPS: &[&[u8]] = &[
    b"=>",
    b"else",
    b"fn",
    b"if",
    b"impl",
    b"loop",
    b"mod",
    b"trait",
    b"unsafe",
    b"while",
];

fn remarked_line(line: &[u8]) -> bool {
    let text = line
        .iter()
        .position(|byte| !matches!(*byte, b' ' | b'\t'))
        .map_or(&line[..0], |at| &line[at..]);

    text.starts_with(b"//") || text.starts_with(b"/*") || text.starts_with(b"*")
}

fn token_at(tokens: &[Token], offset: u32) -> Option<u32> {
    let mut low = 0_usize;
    let mut high = tokens.len();

    while low < high {
        let middle = low + (high - low) / 2;

        if tokens[middle].offset <= offset {
            low = middle + 1;
        } else {
            high = middle;
        }
    }

    (low > 0).then(|| count_of(low - 1))
}

fn carried_end(source: &[u8], tokens: &[Token], position: u32) -> bool {
    let mut scan = position as usize + 1;

    while scan < tokens.len() {
        let token = tokens[scan];

        if token.length > 0 && token.kind != TokenKind::Newline {
            let text = token.text(source);

            return matches!(text, b"else" | b"." | b"?");
        }

        scan += 1;
    }

    false
}

const GIVE_CLIMB_MAX: u32 = 8;
const GIVE_GUARD_MAX: u32 = 16;
const ITEM_WORDS: &[&[u8]] = &[
    b"async",
    b"const",
    b"default",
    b"enum",
    b"extern",
    b"fn",
    b"impl",
    b"macro_rules",
    b"mod",
    b"pub",
    b"static",
    b"struct",
    b"trait",
    b"type",
    b"union",
    b"unsafe",
    b"use",
];

fn settled(tokens: &[Token], position: u32) -> u32 {
    let mut scan = position;

    while (scan as usize) < tokens.len() {
        let token = tokens[scan as usize];

        if token.length > 0 && token.kind != TokenKind::Comment && token.kind != TokenKind::Newline
        {
            return scan;
        }

        scan += 1;
    }

    position
}

fn statement_head(source: &[u8], tokens: &[Token], position: u32) -> u32 {
    let mut depth = 0_u32;
    let mut scan = position;

    while scan > 0 {
        let held = scan - 1;
        let kind = tokens[held as usize].kind;

        if kind == TokenKind::BlockEnd {
            if depth == 0 && !carried_end(source, tokens, held) {
                return settled(tokens, scan);
            }

            depth += 1;
        } else if is_close(kind) {
            depth += 1;
        } else if kind == TokenKind::BlockStart {
            if depth == 0 {
                return settled(tokens, scan);
            }

            depth -= 1;
        } else if is_open(kind) {
            depth = depth.saturating_sub(1);
        } else if depth == 0 && kind == TokenKind::Punctuation(Punctuation::Semicolon) {
            return settled(tokens, scan);
        }

        scan = held;
    }

    settled(tokens, 0)
}

fn block_open(tokens: &[Token], position: u32) -> Option<u32> {
    let mut depth = 0_u32;
    let mut scan = position;

    while scan > 0 {
        let held = scan - 1;
        let kind = tokens[held as usize].kind;

        if kind == TokenKind::BlockEnd {
            depth += 1;
        } else if kind == TokenKind::BlockStart {
            if depth == 0 {
                return Some(held);
            }

            depth -= 1;
        }

        scan = held;
    }

    None
}

fn item_headed(source: &[u8], tokens: &[Token], head: u32) -> bool {
    let text = tokens[head as usize].text(source);

    text == b"#" || ITEM_WORDS.contains(&text)
}

fn behind(tokens: &[Token], position: u32) -> Option<u32> {
    let mut scan = position;

    while scan > 0 {
        let held = scan - 1;
        let token = tokens[held as usize];

        if token.length > 0 && token.kind != TokenKind::Comment && token.kind != TokenKind::Newline
        {
            return Some(held);
        }

        scan = held;
    }

    None
}

fn group_open(tokens: &[Token], position: u32) -> Option<u32> {
    let mut depth = 0_u32;
    let mut scan = position;

    while scan > 0 {
        let held = scan - 1;
        let kind = tokens[held as usize].kind;

        if is_close(kind) || kind == TokenKind::BlockEnd {
            depth += 1;
        } else if is_open(kind) || kind == TokenKind::BlockStart {
            if depth == 0 {
                return Some(held);
            }

            depth -= 1;
        }

        scan = held;
    }

    None
}

fn dotted_callee(source: &[u8], tokens: &[Token], open: u32) -> bool {
    if !matches!(
        tokens[open as usize].kind,
        TokenKind::Punctuation(Punctuation::BracketOpen | Punctuation::ParenOpen)
    ) {
        return false;
    }

    let Some(name) = behind(tokens, open) else {
        return false;
    };

    if tokens[name as usize].kind != TokenKind::Identifier {
        return false;
    }

    let Some(dot) = behind(tokens, name) else {
        return false;
    };

    tokens[dot as usize].kind == TokenKind::Punctuation(Punctuation::Dot)
        && !tokens[dot as usize].text(source).starts_with(b"..")
}

fn guarded(source: &[u8], tokens: &[Token], position: u32, head: u32) -> bool {
    let mut scan = position;

    for _ in 0..GIVE_GUARD_MAX {
        let Some(open) = group_open(tokens, scan).filter(|held| *held >= head) else {
            return false;
        };

        if dotted_callee(source, tokens, open) {
            return true;
        }

        scan = open;
    }

    false
}

fn stated_head(source: &[u8], tokens: &[Token], position: u32) -> u32 {
    let mut head = statement_head(source, tokens, position);

    if !ARM_GIVES {
        return head;
    }

    for _ in 0..ARM_GIVE_MAX {
        let Some(open) = block_open(tokens, head) else {
            return head;
        };

        let Some(matched) = matching(source, tokens, open) else {
            return head;
        };

        head = statement_head(source, tokens, matched);
    }

    head
}

fn matching(source: &[u8], tokens: &[Token], open: u32) -> Option<u32> {
    let mut depth = 0_u32;
    let mut scan = open;

    for _ in 0..ARM_SCAN_MAX {
        scan = scan.checked_sub(1)?;

        let kind = tokens[scan as usize].kind;

        if is_close(kind) || kind == TokenKind::BlockEnd {
            depth += 1;

            continue;
        }

        if is_open(kind) || kind == TokenKind::BlockStart {
            depth = depth.checked_sub(1)?;

            continue;
        }

        if depth > 0 || tokens[scan as usize].length == 0 {
            continue;
        }

        let text = tokens[scan as usize].text(source);

        if text == b"match" {
            return Some(scan);
        }

        if kind == TokenKind::Punctuation(Punctuation::Semicolon) || ARM_STOPS.contains(&text) {
            return None;
        }
    }

    None
}

fn outer_head(source: &[u8], tokens: &[Token], position: u32) -> u32 {
    let mut head = statement_head(source, tokens, position);

    for _ in 0..GIVE_CLIMB_MAX {
        let Some(open) = block_open(tokens, head) else {
            return head;
        };

        let owner = statement_head(source, tokens, open);

        if item_headed(source, tokens, owner) {
            return head;
        }

        head = owner;
    }

    head
}

fn assigned(tokens: &[Token], position: u32) -> bool {
    let mut scan = position;

    while scan > 0 {
        scan -= 1;

        let token = tokens[scan as usize];

        if token.kind == TokenKind::Newline || token.length == 0 || token.kind == TokenKind::Comment
        {
            continue;
        }

        return token.kind == TokenKind::Punctuation(Punctuation::Assign);
    }

    false
}

fn operated(source: &[u8], tokens: &[Token], position: u32) -> bool {
    let token = tokens[position as usize];
    let text = token.text(source);

    if GIVE_OPERATORS.contains(&text) {
        return true;
    }

    if !matches!(text, b"&" | b"|") {
        return false;
    }

    tokens
        .get(position as usize + 1)
        .is_some_and(|next| next.text(source) == text && next.offset == token.end())
}

fn remarks(source: &[u8], tokens: &[Token], gives: &mut BoundedVec<u32>) -> bool {
    if !GIVE_REMARKS {
        return false;
    }

    let mut found = false;

    for position in 0..count_of(tokens.len()) {
        if tokens[position as usize].kind != TokenKind::Comment {
            continue;
        }

        let mut scan = position + 1;

        while (scan as usize) < tokens.len()
            && (tokens[scan as usize].kind == TokenKind::Newline
                || tokens[scan as usize].length == 0
                || tokens[scan as usize].kind == TokenKind::Comment)
        {
            scan += 1;
        }

        let valued = GIVE_VALUES && assigned(tokens, position);

        if !valued && (scan as usize >= tokens.len() || !operated(source, tokens, scan)) {
            continue;
        }

        found |= given(gives, statement_head(source, tokens, position));
    }

    found
}

fn barred(source: &[u8], tokens: &[Token], previous: Option<u32>) -> bool {
    GIVE_LAMBDAS
        && previous.is_some_and(|held| matches!(tokens[held as usize].text(source), b"|" | b"||"))
}

fn lived(source: &[u8], tokens: &[Token], scan: u32, previous: Option<u32>) -> bool {
    lifetimed(source, tokens[scan as usize])
        && previous.is_none_or(|held| {
            matches!(
                tokens[held as usize].kind,
                TokenKind::Punctuation(
                    Punctuation::BracketOpen | Punctuation::Comma | Punctuation::ParenOpen
                )
            )
        })
        && matches!(
            tokens[named_end(tokens, scan) as usize].kind,
            TokenKind::Punctuation(
                Punctuation::BracketClose | Punctuation::Comma | Punctuation::ParenClose
            )
        )
}

fn arrowed(source: &[u8], tokens: &[Token], open: u32) -> bool {
    let mut braced = 0_u32;
    let mut depth = 0_u32;
    let mut lambda = false;
    let mut previous: Option<u32> = None;
    let mut scan = open;

    while (scan as usize) < tokens.len() {
        let token = tokens[scan as usize];
        let kind = token.kind;
        let opens = previous.is_none_or(|held| !ends_operand(tokens[held as usize].kind));
        let inner = depth == 1 || GIVE_BRACES && braced > 0 && depth == braced;

        if is_open(kind) || kind == TokenKind::BlockStart {
            depth += 1;

            if braced == 0
                && kind == TokenKind::BlockStart
                && opens
                && !barred(source, tokens, previous)
            {
                braced = depth;
            }
        } else if is_close(kind) || kind == TokenKind::BlockEnd {
            if braced == depth {
                braced = 0;
            }

            depth -= 1;

            if depth == 0 {
                return false;
            }
        } else if depth == 1 && token.text(source) == b"|" && (lambda || opens) {
            lambda = !lambda;
        } else if inner
            && !lambda
            && (token.text(source) == b"=>"
                || GIVE_COLONS && token.text(source) == b":"
                || lived(source, tokens, scan, previous)
                || GIVE_LONES && loned(source, tokens, scan, previous)
                || GIVE_ATS && token.text(source) == b"@"
                || GIVE_ITEMS
                    && token.text(source) == b"fn"
                    && !item_bodied(tokens, scan, count_of(tokens.len())))
        {
            return true;
        }

        if GIVE_ATS
            && !lambda
            && token.text(source) == b"@"
            && previous.is_some_and(|held| is_open(tokens[held as usize].kind))
        {
            return true;
        }

        if token.length > 0 && kind != TokenKind::Newline && kind != TokenKind::Comment {
            previous = Some(scan);
        }

        scan += 1;
    }

    false
}

fn loned(source: &[u8], tokens: &[Token], scan: u32, previous: Option<u32>) -> bool {
    let token = tokens[scan as usize];

    if !matches!(token.kind, TokenKind::Punctuation(_)) || LONE_KEEPS.contains(&token.text(source))
    {
        return false;
    }

    let opened = previous.is_some_and(|held| {
        matches!(
            tokens[held as usize].kind,
            TokenKind::Punctuation(
                Punctuation::BracketOpen | Punctuation::Comma | Punctuation::ParenOpen
            )
        )
    });

    opened
        && matches!(
            tokens[settled(tokens, scan + 1) as usize].kind,
            TokenKind::Punctuation(
                Punctuation::BracketClose | Punctuation::Comma | Punctuation::ParenClose
            )
        )
}

fn lifetimed(source: &[u8], token: Token) -> bool {
    if !GIVE_LIVES {
        return false;
    }

    let text = token.text(source);

    if !text.starts_with(b"'") {
        return false;
    }

    if token.kind == TokenKind::Identifier {
        return true;
    }

    if token.kind != TokenKind::String
        || text.len() < 4
        || !text.ends_with(b"'")
        || text[1] == b'\\'
    {
        return false;
    }

    let held = &text[1..text.len() - 1];

    held.iter().filter(|byte| (**byte & 0xC0) != 0x80).count() > 1
}

fn named_end(tokens: &[Token], apostrophe: u32) -> u32 {
    let held = settled(tokens, apostrophe + 1);

    if tokens[held as usize].kind != TokenKind::Identifier {
        return held;
    }

    settled(tokens, held + 1)
}

fn item_bodied(tokens: &[Token], head: u32, stop: u32) -> bool {
    let mut depth = 0_u32;
    let mut last = head;
    let mut scan = head;

    while scan < stop {
        let token = tokens[scan as usize];
        let kind = token.kind;

        if is_open(kind) || kind == TokenKind::BlockStart {
            depth += 1;
        } else if is_close(kind) || kind == TokenKind::BlockEnd {
            if depth == 0 {
                break;
            }

            depth -= 1;
        } else if depth == 0
            && matches!(
                kind,
                TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
            )
        {
            break;
        }

        if token.length > 0 && kind != TokenKind::Newline && kind != TokenKind::Comment {
            last = scan;
        }

        scan += 1;
    }

    matches!(
        tokens[last as usize].kind,
        TokenKind::BlockEnd | TokenKind::Punctuation(Punctuation::Semicolon)
    )
}

fn headed(source: &[u8], tokens: &[Token], bang: u32) -> u32 {
    let mut head = statement_head(source, tokens, bang);

    for _ in 0..GIVE_CLIMB_MAX {
        if head >= bang || tokens[head as usize].text(source) != b"#" {
            return head;
        }

        let mut scan = head;

        while scan < bang {
            if tokens[scan as usize].kind == TokenKind::Punctuation(Punctuation::BracketClose) {
                break;
            }

            scan += 1;
        }

        head = settled(tokens, scan + 1);
    }

    head
}

fn banged(source: &[u8], tokens: &[Token], position: u32) -> bool {
    if tokens[position as usize].text(source) != b"!" {
        return false;
    }

    behind(tokens, position).is_some_and(|held| {
        matches!(
            tokens[held as usize].kind,
            TokenKind::Identifier | TokenKind::Keyword(_)
        ) && tokens[held as usize].end() == tokens[position as usize].offset
    })
}

fn give_macros(
    source: &[u8],
    tokens: &[Token],
    gives: &mut BoundedVec<u32>,
    macros: &mut BoundedVec<u32>,
) -> bool {
    if !GIVE_MACROS {
        return false;
    }

    let mut found = false;

    for position in 0..count_of(tokens.len()) {
        if !banged(source, tokens, position) {
            continue;
        }

        let open = settled(tokens, position + 1);

        if !matches!(
            tokens[open as usize].kind,
            TokenKind::Punctuation(Punctuation::ParenOpen | Punctuation::BracketOpen)
        ) || !arrowed(source, tokens, open)
        {
            continue;
        }

        let head = headed(source, tokens, position);

        given(macros, head);

        found |= given(gives, head);
    }

    found
}

fn linked_below(printed: &[u8], stop: u32) -> bool {
    let mut scan = stop as usize + 1;

    while scan < printed.len() && matches!(printed[scan], b' ' | b'\t') {
        scan += 1;
    }

    printed.get(scan) == Some(&b'.')
}

fn given(gives: &mut BoundedVec<u32>, head: u32) -> bool {
    let Err(at) = gives.binary_search(&head) else {
        return false;
    };

    if !gives.push(head) {
        return false;
    }

    gives[at..].rotate_right(1);

    true
}

fn copied(source: &[u8], out: &mut Buffer) -> Outcome {
    out.clear();

    if out.push_bytes(source) {
        return Outcome::Complete;
    }

    Outcome::Overflow
}

fn printing(
    inner: &mut brace::Formatter,
    gives: &mut BoundedVec<u32>,
    macros: &mut BoundedVec<u32>,
    lines: &mut BoundedVec<u32>,
    scratch: &mut Buffer,
    held: &brace::Input<'_>,
    width: u32,
) -> bool {
    gives.clear();
    macros.clear();

    remarks(held.source, held.tokens, gives);
    give_macros(held.source, held.tokens, gives, macros);

    for _ in 0..GIVE_PASSES {
        let round = brace::Input {
            gives: gives.as_ref(),
            macros: macros.as_ref(),
            ..*held
        };

        if !inner.formatting(&round, scratch, Some(lines)) {
            return false;
        }

        if !GIVE_UPS
            || !marks(
                held.source,
                held.tokens,
                scratch.as_bytes(),
                lines,
                width,
                held.options.indent_width,
                gives,
            )
        {
            break;
        }
    }

    true
}

fn quoted(source: &[u8], position: u32, tokens: &[Token]) -> bool {
    let token = tokens[position as usize];

    token.kind == TokenKind::String && token.text(source).starts_with(b"\"")
}

fn columned(source: &[u8], tokens: &[Token], head: u32) -> u32 {
    let offset = (tokens[head as usize].offset as usize).min(source.len());
    let mut start = offset;

    while start > 0 && source[start - 1] != b'\n' {
        start -= 1;
    }

    columns(source, count_of(start), count_of(offset))
}

fn ruled_head(source: &[u8], tokens: &[Token], head: u32) -> bool {
    let mut scan = head;

    for _ in 0..MACRO_RULE_MAX {
        let text = tokens[scan as usize].text(source);

        if text == b"macro_rules" || text == b"macro" {
            return true;
        }

        if !MACRO_HEADS.contains(&text) {
            return false;
        }

        scan = settled(tokens, scan + 1);
    }

    false
}

fn macro_ruled(source: &[u8], tokens: &[Token], position: u32) -> Option<u32> {
    let mut scan = position;

    for _ in 0..GIVE_CLIMB_MAX {
        let open = block_open(tokens, scan)?;
        let head = statement_head(source, tokens, open);

        if ruled_head(source, tokens, head) {
            return Some(head);
        }

        scan = open;
    }

    None
}

fn marks(
    source: &[u8],
    tokens: &[Token],
    printed: &[u8],
    lines: &[u32],
    width: u32,
    indent: u32,
    gives: &mut BoundedVec<u32>,
) -> bool {
    let mut found = false;
    let mut index = 0_usize;
    let mut start = 0_u32;

    for (at, byte) in printed.iter().enumerate() {
        if *byte != b'\n' {
            continue;
        }

        let stop = count_of(at);
        let line = &printed[start as usize..at];

        start = stop + 1;
        index += 1;

        let owed = u32::from(GIVE_STRINGS && line.ends_with(b"\"") && linked_below(printed, stop));
        let spread = columns(printed, stop.saturating_sub(count_of(line.len())), stop) + owed;

        if spread <= width || remarked_line(line) {
            continue;
        }

        let Some(offset) = lines.get(index - 1).copied() else {
            continue;
        };

        let Some(position) = token_at(tokens, offset) else {
            continue;
        };

        if MACRO_UPS && let Some(ruled) = macro_ruled(source, tokens, position) {
            found |= given(gives, ruled);

            continue;
        }

        if GIVE_TOKENS && !quoted(source, position, tokens) {
            let token = tokens[position as usize];
            let owner = stated_head(source, tokens, position);
            let spelled = columns(source, token.offset, token.end());

            if columned(source, tokens, owner) + indent + spelled > width {
                found |= given(gives, owner);

                continue;
            }
        }

        if owed > 0 {
            found |= given(gives, stated_head(source, tokens, position));

            continue;
        }

        let head = outer_head(source, tokens, position);

        if !guarded(source, tokens, position, head) {
            continue;
        }

        found |= given(gives, head);
    }

    found
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
        Kind::ExprStruct if STRUCT_BODIES => POLICY.literal_width,
        _ => 0,
    }
}

fn argued(kind: Kind) -> bool {
    matches!(kind, Kind::ExprCall | Kind::ExprMacro) || STRUCT_BODIES && kind == Kind::ExprStruct
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
    literal: POLICY.literal_width,
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
            gives: BoundedVec::reserve(GIVE_MARKS_MAX),
            inner: brace::Formatter::reserve(element_count_max, scratch_bytes_max),
            lines: BoundedVec::reserve(element_count_max),
            macros: BoundedVec::reserve(GIVE_MARKS_MAX),
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
            return copied(input.source, out);
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
            added: if TAIL_ENDS { self.stream.added() } else { &[] },
            origin: input.source,
            origins: if TAIL_ENDS {
                self.stream.origins()
            } else {
                &[]
            },
            gives: &[],
            macros: &[],
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

        if !printing(
            &mut self.inner,
            &mut self.gives,
            &mut self.macros,
            &mut self.lines,
            &mut self.scratch,
            &held,
            input.options.line_width,
        ) {
            return Outcome::Overflow;
        }

        if !self.columned(input.options.line_width) {
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
    fn columned(&mut self, line_width: u32) -> bool {
        if ELEMENT_ALIGNS {
            return align::align(
                self.scratch.as_bytes(),
                Target::Element,
                line_width,
                &mut self.staged,
            );
        }

        self.staged.clear();

        self.staged.push_bytes(self.scratch.as_bytes())
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
