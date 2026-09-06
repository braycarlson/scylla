use crate::bounded::{BoundedVec, Buffer, Bytes as _, Span, count_of};
use crate::format::brace::{self, Policy};
use crate::format::print::Options;
use crate::syntax::css::kind::CSSKind as Kind;
use crate::token::Token;
use crate::tree::{Structure, Tree};

const RULE_WORDS: [&[u8]; 21] = [
    b"charset",
    b"color-profile",
    b"container",
    b"counter-style",
    b"document",
    b"font-face",
    b"font-feature-values",
    b"font-palette-values",
    b"import",
    b"keyframes",
    b"layer",
    b"media",
    b"namespace",
    b"page",
    b"position-try",
    b"property",
    b"scope",
    b"starting-style",
    b"styleset",
    b"supports",
    b"view-transition",
];

const COUNT_WORDS: [&[u8]; 6] = [
    b"nth-child",
    b"nth-col",
    b"nth-last-child",
    b"nth-last-col",
    b"nth-last-of-type",
    b"nth-of-type",
];

const LAYER_FILL_MAX: u32 = 12;

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
    blank_edges: true,
    blank_max: 1,
    block_chains: false,
    block_joins: false,
    block_leads: &[],
    block_words: &[],
    body_owns: false,
    body_parts: false,
    body_words: &[],
    brace_bodies: false,
    brace_continues: false,
    brace_counts: false,
    brace_dedents: false,
    brace_hugs: false,
    brace_leads: true,
    brace_levels: false,
    brace_pairs: false,
    brace_parts: true,
    brace_remarks: false,
    brace_spaces: false,
    brace_spans: false,
    brace_words: &[],
    branch_joins: false,
    branch_width: 0,
    branch_words: &[],
    bracket_types: false,
    build_blocks: false,
    carriage_breaks: true,
    callee_marks: &[],
    callee_words: &[],
    cast_joins: false,
    cast_words: &[],
    clause_bases: false,
    clause_ends: false,
    clause_lines: false,
    clause_values: &[],
    clause_words: &[],
    close_hugs: false,
    colon_continues: false,
    comma_adds: false,
    comma_continues: false,
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
    declare_words: &[],
    dedent_words: &[],
    document_blocks: false,
    else_width: 0,
    empty_words: &[],
    end_words: &[],
    field_width: 0,
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
    hug_braces: false,
    hug_lambdas: false,
    hug_lasts: false,
    hug_soles: false,
    hug_words: &[],
    inline_layout: false,
    inline_remarks: false,
    item_words: &[],
    key_quotes: false,
    key_words: &[],
    keyword_gaps: false,
    label_lines: false,
    label_words: &[],
    lambda_flattens: false,
    lead_words: &[b"/**"],
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
    operand_words: &[],
    operator_words: &[],
    order_words: &[],
    parameter_words: &[],
    pattern_frames: false,
    pattern_words: &[],
    postfix_words: &[],
    prefix_words: &[b"#", b"$", b"--", b"@"],
    printed_gaps: false,
    raise_hugged: false,
    remark_carries: false,
    remark_dedents: false,
    sentinel_colons: false,
    sequence_lines: false,
    sequence_stops: &[],
    remark_gaps: false,
    remark_levels: false,
    remark_suffix: false,
    remark_tails: false,
    return_parens: false,
    rest_binds: false,
    remark_leads: false,
    root_joins: false,
    row_parts: false,
    signature_words: &[],
    skip_words: &[],
    slice_colons: true,
    sole_hugs: false,
    sole_joins: false,
    source_gaps: true,
    source_values: &[
        b"grid",
        b"grid-template",
        b"grid-template-areas",
        b"grid-template-columns",
        b"grid-template-rows",
    ],
    source_words: &[],
    spaced_words: &[b"/"],
    span_levels: false,
    spec_depths: false,
    special_macros: &[],
    spread_blanks: false,
    spread_owns: false,
    string_quotes: false,
    template_spans: false,
    template_units: false,
    ternary_colon: false,
    ternary_levels: false,
    ternary_parts: false,
    test_joins: false,
    tight_from_source: &[b"*", b"+", b"-", b">", b"~"],
    tight_words: &[],
    type_leads: &[],
    type_words: &[],
    unary_words: &[b"-"],
    union_parts: false,
    units: true,
    width_lists: false,
    value_cap: 12,
    value_columns: false,
    value_words: &[],
    variant_width: 0,
    verbatim_words: &[b"url"],
};

fn columns(bytes: &[u8]) -> u32 {
    let mut found = 0;

    for byte in bytes {
        if byte & 0xC0 != 0x80 {
            found += 1;
        }
    }

    found
}

fn indent_of(line: &[u8]) -> usize {
    let mut held = 0;

    while held < line.len() && line[held] == b' ' {
        held += 1;
    }

    held
}

fn lowered(text: &[u8], out: &mut Buffer) -> bool {
    for byte in text {
        if !out.push_bytes(&[byte.to_ascii_lowercase()]) {
            return false;
        }
    }

    true
}

fn padded(out: &mut Buffer, width: usize) -> bool {
    for _ in 0..width {
        if !out.push_bytes(b" ") {
            return false;
        }
    }

    true
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

fn line_end(bytes: &[u8], offset: usize) -> usize {
    let mut held = offset;

    while held < bytes.len() && bytes[held] != b'\n' {
        held += 1;
    }

    held
}

fn skipped(bytes: &[u8], offset: usize) -> usize {
    let mut held = offset;

    while held < bytes.len() && bytes[held] == b' ' {
        held += 1;
    }

    held
}

fn remark_at(line: &[u8]) -> usize {
    let mut held = 0;
    let mut quote = 0;

    while held < line.len() {
        let byte = line[held];

        if quote != 0 {
            held += if byte == b'\\' { 2 } else { 1 };

            if byte == quote {
                quote = 0;
            }

            continue;
        }

        if byte == b'"' || byte == b'\'' {
            quote = byte;
            held += 1;

            continue;
        }

        if !line[held..].starts_with(b"/*") {
            held += 1;

            continue;
        }

        let Some(end) = found_at(&line[held + 2..], b"*/") else {
            return held;
        };

        let stop = held + 4 + end;

        if line[stop..].iter().all(u8::is_ascii_whitespace) {
            return held;
        }

        held = stop;
    }

    line.len()
}

fn separator(body: &[u8], from: usize, comma: bool) -> Option<usize> {
    let mut depth = 0_u32;
    let mut held = from;
    let mut quote = 0;

    while held < body.len() {
        let byte = body[held];

        if quote != 0 {
            held += if byte == b'\\' { 2 } else { 1 };

            if byte == quote {
                quote = 0;
            }

            continue;
        }

        if body[held..].starts_with(b"/*") {
            held = crossed(body, held);

            continue;
        }

        match byte {
            b'"' | b'\'' => quote = byte,
            b'(' | b'[' => depth += 1,
            b')' | b']' => depth = depth.saturating_sub(1),
            b',' if comma && depth == 0 => return Some(held),
            b' ' if !comma && depth == 0 && !body[skipped(body, held)..].starts_with(b"/*") => {
                return Some(held);
            }
            _ => (),
        }

        held += 1;
    }

    None
}

fn crossed(body: &[u8], from: usize) -> usize {
    found_at(&body[from + 2..], b"*/").map_or(body.len(), |end| from + 4 + end)
}

fn closes(bytes: &[u8], end: usize) -> bool {
    let mut offset = end;

    while offset < bytes.len() {
        let from = offset + 1;
        let stop = line_end(bytes, from.min(bytes.len()));
        let line = bytes[from.min(bytes.len())..stop].trim_ascii();

        if !line.is_empty() {
            return line.starts_with(b"}");
        }

        offset = stop;
    }

    false
}

fn unterminated(code: &[u8]) -> bool {
    let body = code.trim_ascii();

    if body.is_empty() || body.ends_with(b";") || body.ends_with(b"{") || body.ends_with(b"}") {
        return false;
    }

    colon_of(body).is_some()
}

fn colon_of(body: &[u8]) -> Option<usize> {
    let mut depth = 0_u32;
    let mut held = 0;
    let mut quote = 0;

    while held < body.len() {
        let byte = body[held];

        if quote != 0 {
            held += if byte == b'\\' { 2 } else { 1 };

            if byte == quote {
                quote = 0;
            }

            continue;
        }

        if body[held..].starts_with(b"/*") {
            held = crossed(body, held);

            continue;
        }

        match byte {
            b'"' | b'\'' => quote = byte,
            b'(' | b'[' => depth += 1,
            b')' | b']' => depth = depth.saturating_sub(1),
            b':' if depth == 0 => return Some(held),
            _ => (),
        }

        held += 1;
    }

    None
}

fn measured(part: &[u8]) -> u32 {
    let held = found_at(part, b"/*").map_or(part, |at| part[..at].trim_ascii_end());

    columns(held) - u32::from(held.ends_with(b";"))
}

fn argued(part: &[u8]) -> u32 {
    measured(part) - u32::from(part.ends_with(b","))
}

fn closing(part: &[u8], open: usize) -> Option<usize> {
    let mut depth = 0_u32;
    let mut held = open;
    let mut quote = 0;

    while held < part.len() {
        let byte = part[held];

        if quote != 0 {
            held += if byte == b'\\' { 2 } else { 1 };

            if byte == quote {
                quote = 0;
            }

            continue;
        }

        if part[held..].starts_with(b"/*") {
            held = crossed(part, held);

            continue;
        }

        match byte {
            b'"' | b'\'' => quote = byte,
            b'(' | b'[' => depth += 1,
            b')' | b']' => {
                depth -= 1;

                if depth == 0 {
                    return Some(held);
                }
            }
            _ => (),
        }

        held += 1;
    }

    None
}

fn callable(part: &[u8]) -> Option<(usize, usize)> {
    let open = part.iter().position(|byte| *byte == b'(')?;

    if open > 0 && !worded(part[open - 1]) {
        return None;
    }

    if part[..open].eq_ignore_ascii_case(b"url") {
        return None;
    }

    let close = closing(part, open)?;

    if !closes_a_value(&part[close + 1..]) {
        return None;
    }

    Some((open, close))
}

fn closes_a_value(tail: &[u8]) -> bool {
    let mut held = 0;

    while held < tail.len() {
        if tail[held..].starts_with(b"/*") {
            held = crossed(tail, held);

            continue;
        }

        if !matches!(tail[held], b',' | b';') && !tail[held].is_ascii_whitespace() {
            return false;
        }

        held += 1;
    }

    true
}

fn called(part: &[u8], indent: usize, width: u32, out: &mut Buffer) -> bool {
    let Some((open, close)) = callable(part) else {
        return false;
    };

    if !out.push_bytes(&part[..=open]) {
        return false;
    }

    let args = &part[open + 1..close];
    let operated = separator(args, 0, true).is_none();
    let mut offset = 0;

    while offset < args.len() {
        let found = if operated {
            operator(args, offset)
        } else {
            separator(args, offset, true)
        };

        let stop = found.map_or(args.len(), |held| held + 1);
        let piece = args[offset..stop].trim_ascii();
        let ridden = operated && found.is_some() && !piece.is_empty();

        let (body, rider) = if ridden {
            piece.split_at(piece.len() - 1)
        } else {
            (piece, &piece[piece.len()..])
        };

        if !out.push_bytes(b"\n") || !padded(out, indent + 4) {
            return false;
        }

        if !spilled(
            body.trim_ascii_end(),
            indent + 4,
            columns(rider) + u32::from(ridden),
            width,
            out,
        ) {
            return false;
        }

        if ridden && (!out.push_bytes(b" ") || !out.push_bytes(rider)) {
            return false;
        }

        offset = skipped(args, stop);
    }

    out.push_bytes(b"\n") && padded(out, indent) && out.push_bytes(&part[close..])
}

fn spilled(part: &[u8], indent: usize, carried: u32, width: u32, out: &mut Buffer) -> bool {
    let level = indent + 4;

    let held = if separator(part, 0, false).is_some() {
        level
    } else {
        indent
    };

    let mut column = count_of(indent);
    let mut first = true;
    let mut offset = 0;
    let mut parted = false;

    while offset < part.len() {
        let stop = separator(part, offset, false).unwrap_or(part.len());
        let piece = &part[offset..stop];

        offset = skipped(part, stop);

        let owed = if offset < part.len() { 0 } else { carried };

        if !first {
            if parted || column + 1 + argued(piece) + owed > width {
                if !out.push_bytes(b"\n") || !padded(out, level) {
                    return false;
                }

                column = count_of(level);
            } else {
                if !out.push_bytes(b" ") {
                    return false;
                }

                column += 1;
            }
        }

        if !placed(piece, held, column + owed, width, out) {
            return false;
        }

        parted = column + sized(piece) + owed > width && callable(piece).is_some();

        column = if parted {
            count_of(held) + 2
        } else {
            column + measured(piece)
        };

        first = false;
    }

    true
}

fn compound(head: &[u8], from: usize) -> usize {
    let stop = separator(head, from, false).unwrap_or(head.len());

    if matches!(&head[from..stop], b">" | b"+" | b"~") {
        return separator(head, skipped(head, stop), false).unwrap_or(head.len());
    }

    stop
}

fn leading(first: bool, indent: usize, level: usize, out: &mut Buffer) -> bool {
    if first {
        return padded(out, indent);
    }

    out.push_bytes(b"\n") && padded(out, level)
}

fn pairs(head: &[u8]) -> bool {
    let second = skipped(head, compound(head, 0));

    second < head.len() && compound(head, second) >= head.len()
}

fn heads(head: &[u8]) -> bool {
    head.first()
        .is_some_and(|byte| *byte == b'.' || worded(*byte))
}

fn pseudo_open(head: &[u8], from: usize) -> Option<usize> {
    let mut scan = from;

    while scan < head.len() {
        if head[scan] == b'(' {
            let mut start = scan;

            while start > 0 && worded(head[start - 1]) {
                start -= 1;
            }

            if start > 0 && head[start - 1] == b':' {
                return Some(scan);
            }
        }

        scan += 1;
    }

    None
}

fn pseudo_at(head: &[u8], indent: usize, tail: usize, width: u32) -> Option<(usize, usize)> {
    let mut found = None;
    let mut offset = 0;

    while offset < head.len() {
        let Some(open) = pseudo_open(head, offset) else {
            break;
        };

        let close = closing(head, open)?;
        let stop = pseudo_open(head, close + 1).map_or(head.len(), |next| next + 1);

        let carried = if stop == head.len() {
            count_of(tail)
        } else {
            0
        };

        if count_of(indent) + columns(&head[..stop]) + carried > width {
            return Some((open, close));
        }

        found = Some((open, close));
        offset = close + 1;
    }

    found.filter(|_| count_of(indent) + columns(head) + count_of(tail) > width)
}

fn pseudoed(
    part: &[u8],
    level: usize,
    found: (usize, usize),
    tail: usize,
    width: u32,
    out: &mut Buffer,
) -> bool {
    let mut held = part;
    let mut spot = found;

    loop {
        let (open, close) = spot;

        if !out.push_bytes(&held[..=open]) {
            return false;
        }

        let args = &held[open + 1..close];
        let mut offset = 0;

        while offset < args.len() {
            let stop = separator(args, offset, true).map_or(args.len(), |at| at + 1);

            if !out.push_bytes(b"\n") || !matched(&args[offset..stop], level + 4, width, out) {
                return false;
            }

            offset = skipped(args, stop);
        }

        if !out.push_bytes(b"\n") || !padded(out, level) {
            return false;
        }

        let rest = &held[close..];

        let Some(next) = pseudo_at(rest, level, tail, width) else {
            return out.push_bytes(rest);
        };

        held = rest;
        spot = next;
    }
}

fn matched(argument: &[u8], indent: usize, width: u32, out: &mut Buffer) -> bool {
    let held = argument.trim_ascii();

    if count_of(indent) + columns(held) <= width {
        return padded(out, indent) && out.push_bytes(held);
    }

    if separator(held, 0, false).is_none() {
        let Some(found) = pseudo_at(held, indent, 0, width) else {
            return padded(out, indent) && out.push_bytes(held);
        };

        return padded(out, indent) && pseudoed(held, indent + 4, found, 0, width, out);
    }

    let mut first = true;
    let mut offset = 0;

    while offset < held.len() {
        let start = offset;
        let stop = compound(held, start);

        offset = skipped(held, stop);

        if !leading(first, indent, indent + 4, out) || !out.push_bytes(&held[start..stop]) {
            return false;
        }

        first = false;
    }

    true
}

fn selectors(
    body: &[u8],
    indent: usize,
    remarked: bool,
    nested: bool,
    moved: bool,
    width: u32,
    out: &mut Buffer,
) -> bool {
    let dropped = &body[..body.len() - 1];

    let (head, tail): (&[u8], &[u8]) = if body.ends_with(b"{") {
        (dropped.trim_ascii_end(), b" {")
    } else if moved {
        (dropped, b"")
    } else {
        (dropped, b",")
    };

    let led = remarked && heads(head);
    let paired = led && pairs(head);

    if nested && paired {
        return padded(out, indent) && out.push_bytes(head) && out.push_bytes(tail);
    }

    let based = if nested { indent + 4 } else { indent };
    let opened = if paired { indent } else { based + 4 };
    let mut first = true;
    let mut offset = 0;

    while offset < head.len() {
        let start = offset;
        let mut stop = compound(head, start);

        if first && led && !paired && skipped(head, stop) < head.len() {
            stop = compound(head, skipped(head, stop));
        }

        offset = skipped(head, stop);

        let part = &head[start..stop];

        let level = if paired {
            indent
        } else if first {
            based
        } else {
            indent + 4
        };

        let carried = if offset < head.len() { 0 } else { tail.len() };

        if !leading(first, based, level, out) {
            return false;
        }

        let written = match pseudo_at(part, level, carried, width) {
            Some(found) => pseudoed(part, opened, found, carried, width, out),
            None => out.push_bytes(part),
        };

        if !written {
            return false;
        }

        first = false;
    }

    out.push_bytes(tail)
}

fn counted(value: &[u8]) -> u32 {
    let mut found = 0;
    let mut offset = 0;

    while offset < value.len() {
        let stop = separator(value, offset, true).unwrap_or(value.len());
        let part = value[offset..stop].trim_ascii();
        let mut held = 0;

        while held < part.len() {
            found += 1;
            held = skipped(part, separator(part, held, false).unwrap_or(part.len()));
        }

        offset = skipped(value, (stop + 1).min(value.len()));
    }

    found
}

fn layers(value: &[u8]) -> bool {
    let mut offset = 0;

    while offset < value.len() {
        let stop = separator(value, offset, true).unwrap_or(value.len());
        let part = value[offset..stop].trim_ascii();

        if separator(part, 0, false).is_some() {
            return true;
        }

        offset = skipped(value, stop + 1);
    }

    false
}

fn layered(
    prop: &[u8],
    value: &[u8],
    indent: usize,
    whole: bool,
    width: u32,
    out: &mut Buffer,
) -> bool {
    if !padded(out, indent) || !out.push_bytes(prop) {
        return false;
    }

    if !out.push_bytes(b"\n") || !padded(out, indent + 4) {
        return false;
    }

    let capped = whole && counted(value) > LAYER_FILL_MAX;
    let mut column = count_of(indent) + 4;
    let mut first = true;
    let mut offset = 0;
    let mut parted = false;

    while offset < value.len() {
        let stop = separator(value, offset, true).map_or(value.len(), |found| found + 1);
        let part = value[offset..stop].trim_ascii_end();

        offset = skipped(value, stop);

        if !first && !capped && (!whole || parted || column + 1 + measured(part) > width) {
            if !out.push_bytes(b"\n") || !padded(out, indent + 4) {
                return false;
            }

            column = count_of(indent) + 4;
        } else if !first {
            if !out.push_bytes(b" ") {
                return false;
            }

            column += 1;
        }

        let written = if capped {
            out.push_bytes(part)
                .then(|| (column + measured(part), false))
        } else {
            spread(part, indent + 4, column, width, out)
        };

        let Some((held, spilt)) = written else {
            return false;
        };

        column = held;
        parted = spilt;
        first = false;
    }

    true
}

fn spread(
    part: &[u8],
    indent: usize,
    column: u32,
    width: u32,
    out: &mut Buffer,
) -> Option<(u32, bool)> {
    let mut held = column;
    let mut first = true;
    let mut offset = 0;
    let mut parted = false;
    let mut spilt = false;

    while offset < part.len() {
        let stop = separator(part, offset, false).unwrap_or(part.len());
        let piece = &part[offset..stop];

        offset = skipped(part, stop);

        if !first {
            if parted || held + 1 + measured(piece) > width {
                if !out.push_bytes(b"\n") || !padded(out, indent) {
                    return None;
                }

                held = count_of(indent);
                spilt = true;
            } else {
                if !out.push_bytes(b" ") {
                    return None;
                }

                held += 1;
            }
        }

        if !placed(piece, indent, held, width, out) {
            return None;
        }

        parted = held + sized(piece) > width && callable(piece).is_some();
        spilt = spilt || parted;

        held = if parted {
            count_of(indent) + 2
        } else {
            held + measured(piece)
        };

        first = false;
    }

    Some((held, spilt))
}

fn divides(value: &[u8]) -> bool {
    let mut offset = 0;

    while offset < value.len() {
        let stop = separator(value, offset, false).unwrap_or(value.len());

        if &value[offset..stop] == b"/" {
            return true;
        }

        offset = skipped(value, stop);
    }

    false
}

fn filled(
    prop: &[u8],
    value: &[u8],
    tail: &[u8],
    indent: usize,
    width: u32,
    trailed: u32,
    out: &mut Buffer,
) -> bool {
    if separator(value, 0, false).is_none() && callable(value).is_none() {
        return false;
    }

    if !padded(out, indent) || !out.push_bytes(prop) {
        return false;
    }

    let carried = if separator(value, 0, false).is_some() {
        0
    } else if tail.is_empty() {
        trailed
    } else {
        trailed + measured(tail) + 1
    };

    let level = if separator(value, 0, false).is_some() {
        indent + 4
    } else {
        indent
    };

    let divided = divides(value);
    let mut column = count_of(indent) + columns(prop);
    let mut first = true;
    let mut offset = 0;
    let mut parted = false;

    while offset < value.len() {
        let stop = separator(value, offset, false).unwrap_or(value.len());
        let part = &value[offset..stop];

        offset = skipped(value, stop);

        let held = if offset < value.len() {
            columns(part)
        } else {
            measured(part)
        };

        let opens = if first {
            divided
        } else {
            parted || column + 1 + held > width
        };

        if opens {
            if !out.push_bytes(b"\n") || !padded(out, indent + 4) {
                return false;
            }

            column = count_of(indent) + 4;
        } else if !out.push_bytes(b" ") {
            return false;
        } else {
            column += 1;
        }

        if !placed(part, level, column + carried, width, out) {
            return false;
        }

        parted = column + sized(part) + carried > width && callable(part).is_some();

        column = if parted {
            count_of(level) + 2
        } else {
            column + held
        };

        first = false;
    }

    true
}

fn sized(part: &[u8]) -> u32 {
    columns(part) - u32::from(part.ends_with(b";") || part.ends_with(b","))
}

fn placed(part: &[u8], level: usize, column: u32, width: u32, out: &mut Buffer) -> bool {
    if column + sized(part) > width && callable(part).is_some() {
        return called(part, level, width, out);
    }

    out.push_bytes(part)
}

fn declaration(
    body: &[u8],
    indent: usize,
    wide: bool,
    width: u32,
    trailed: u32,
    out: &mut Buffer,
) -> bool {
    let Some(colon) = colon_of(body) else {
        return false;
    };

    if POLICY.source_values.contains(&body[..colon].trim_ascii()) {
        return false;
    }

    let start = skipped(body, colon + 1);
    let held = &body[start..];

    if held.is_empty() {
        return false;
    }

    let (value, tail) = match bang_at(held) {
        Some(at) => (held[..at].trim_ascii_end(), &held[at..]),
        None => (held, &held[held.len()..]),
    };

    if value.is_empty() {
        return false;
    }

    if separator(value, 0, true).is_some() {
        let whole = !layers(value) || body.starts_with(b"--");

        if !wide && whole {
            return false;
        }

        return layered(&body[..=colon], value, indent, whole, width, out) && tailed(tail, out);
    }

    wide && filled(&body[..=colon], value, tail, indent, width, trailed, out) && tailed(tail, out)
}

fn bang_at(value: &[u8]) -> Option<usize> {
    let mut depth = 0_u32;
    let mut held = 0;
    let mut quote = 0;

    while held < value.len() {
        let byte = value[held];

        if quote != 0 {
            held += if byte == b'\\' { 2 } else { 1 };

            if byte == quote {
                quote = 0;
            }

            continue;
        }

        if value[held..].starts_with(b"/*") {
            held = crossed(value, held);

            continue;
        }

        match byte {
            b'"' | b'\'' => quote = byte,
            b'(' | b'[' => depth += 1,
            b')' | b']' => depth = depth.saturating_sub(1),
            b'!' if depth == 0 => return Some(held),
            _ => (),
        }

        held += 1;
    }

    None
}

fn wrapped(
    line: &[u8],
    remarked: bool,
    nested: bool,
    wide: bool,
    width: u32,
    trailed: u32,
    out: &mut Buffer,
) -> bool {
    let at = remark_at(line);
    let code = line[..at].trim_ascii_end();
    let indent = indent_of(code);
    let body = &code[indent..];

    if body.is_empty() || body.starts_with(b"@") {
        return false;
    }

    if body.ends_with(b"{") || body.ends_with(b",") {
        let moved = at < line.len() && body.ends_with(b",");

        return (wide || nested) && selectors(body, indent, remarked, nested, moved, width, out);
    }

    declaration(body, indent, wide, width, trailed, out)
}

fn tailed(remark: &[u8], out: &mut Buffer) -> bool {
    if remark.is_empty() {
        return true;
    }

    out.push_bytes(b" ") && out.push_bytes(remark)
}

fn written(
    line: &[u8],
    closed: bool,
    remarked: bool,
    nested: bool,
    options: Options,
    out: &mut Buffer,
) -> bool {
    let held = remark_at(line);
    let code = line[..held].trim_ascii_end();
    let remark = line[held..].trim_ascii_end();
    if code.trim_ascii().is_empty() {
        return out.push_bytes(line.trim_ascii_end());
    }

    let semi = closed && unterminated(code);

    let carried = if remark.is_empty() {
        0
    } else {
        columns(remark) + 1
    };

    let trailed = carried + u32::from(semi || code.ends_with(b";"));
    let width = columns(code) + u32::from(semi) + carried;
    let wide = width > options.line_width;
    let moved = !remark.is_empty() && code.ends_with(b",");
    let stripped = if moved { &code[..code.len() - 1] } else { code };

    if !wrapped(
        line,
        remarked,
        nested,
        wide,
        options.line_width,
        trailed,
        out,
    ) && !out.push_bytes(stripped)
    {
        return false;
    }

    let closing: &[u8] = if code.ends_with(b":") { b" ;" } else { b";" };

    if semi && !out.push_bytes(closing) {
        return false;
    }

    if moved {
        return tailed(remark, out) && out.push_bytes(b",");
    }

    tailed(remark, out)
}

const fn worded(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-'
}

fn declares(line: &[u8]) -> bool {
    let body = line[..remark_at(line)].trim_ascii();

    if body.is_empty() {
        return false;
    }

    if body.starts_with(b"@") {
        return true;
    }

    if body.ends_with(b"{") || body.ends_with(b",") {
        return false;
    }

    colon_of(body).is_some()
}

fn quoted(line: &[u8], from: usize, out: &mut Buffer) -> Option<usize> {
    let quote = line[from];
    let mut held = from + 1;

    while held < line.len() {
        if line[held] == b'\\' {
            held += 2;

            continue;
        }

        if line[held] == quote {
            break;
        }

        held += 1;
    }

    if held >= line.len() {
        return out.push_bytes(&line[from..]).then_some(line.len());
    }

    let body = &line[from + 1..held];
    let plain = quote == b'\'' && !holds(body, b'"');

    if !plain {
        return out.push_bytes(&line[from..=held]).then_some(held + 1);
    }

    if !out.push_bytes(b"\"") || !unescaped(body, out) || !out.push_bytes(b"\"") {
        return None;
    }

    Some(held + 1)
}

fn holds(body: &[u8], byte: u8) -> bool {
    let mut held = 0;

    while held < body.len() {
        if body[held] == b'\\' {
            held += 2;

            continue;
        }

        if body[held] == byte {
            return true;
        }

        held += 1;
    }

    false
}

fn unescaped(body: &[u8], out: &mut Buffer) -> bool {
    let mut held = 0;

    while held < body.len() {
        if body[held] == b'\\' && body.get(held + 1) == Some(&b'\'') {
            if !out.push_bytes(b"'") {
                return false;
            }

            held += 2;

            continue;
        }

        if !out.push_bytes(&body[held..=held]) {
            return false;
        }

        held += 1;
    }

    true
}

fn coloured(line: &[u8], from: usize, out: &mut Buffer) -> Option<usize> {
    let mut held = from + 1;

    while held < line.len() && line[held].is_ascii_hexdigit() {
        held += 1;
    }

    let count = held - from - 1;

    if !matches!(count, 3 | 4 | 6 | 8) || line.get(held).is_some_and(|byte| worded(*byte)) {
        return None;
    }

    if !out.push_bytes(b"#") {
        return None;
    }

    for byte in &line[from + 1..held] {
        if !out.push_bytes(&[byte.to_ascii_lowercase()]) {
            return None;
        }
    }

    Some(held)
}

fn digits(line: &[u8], from: usize) -> (usize, usize, usize) {
    let mut held = from;

    while held < line.len() && line[held].is_ascii_digit() {
        held += 1;
    }

    let whole = held;

    if line.get(held) == Some(&b'.') {
        held += 1;

        while held < line.len() && line[held].is_ascii_digit() {
            held += 1;
        }
    }

    let fraction = held;
    let mut scan = held;

    if matches!(line.get(scan), Some(b'e' | b'E')) {
        scan += 1;

        if matches!(line.get(scan), Some(b'+' | b'-')) {
            scan += 1;
        }

        if line.get(scan).is_some_and(u8::is_ascii_digit) {
            while scan < line.len() && line[scan].is_ascii_digit() {
                scan += 1;
            }

            held = scan;
        }
    }

    (whole, fraction, held)
}

fn numbered(line: &[u8], from: usize, out: &mut Buffer) -> Option<usize> {
    let (whole, fraction, held) = digits(line, from);

    if whole == from && !out.push_bytes(b"0") {
        return None;
    }

    if !out.push_bytes(&line[from..whole]) {
        return None;
    }

    let trimmed = trailing(&line[whole..fraction]);

    if !trimmed.is_empty() && !out.push_bytes(trimmed) {
        return None;
    }

    if !lowered(&line[fraction..held], out) {
        return None;
    }

    united(line, held, out)
}

fn trailing(fraction: &[u8]) -> &[u8] {
    let mut held = fraction.len();

    while held > 0 && fraction[held - 1] == b'0' {
        held -= 1;
    }

    if held <= 1 { &[] } else { &fraction[..held] }
}

fn united(line: &[u8], from: usize, out: &mut Buffer) -> Option<usize> {
    let mut held = from;

    while held < line.len() && line[held].is_ascii_alphabetic() {
        held += 1;
    }

    let unit = &line[from..held];

    if unit == b"Q" || line.get(held).is_some_and(|byte| worded(*byte)) {
        return out.push_bytes(unit).then_some(held);
    }

    lowered(unit, out).then_some(held)
}

fn counts(line: &[u8], open: usize) -> bool {
    let mut start = open;

    while start > 0 && worded(line[start - 1]) {
        start -= 1;
    }

    if start == 0 || line[start - 1] != b':' {
        return false;
    }

    COUNT_WORDS
        .iter()
        .any(|word| line[start..open].eq_ignore_ascii_case(word))
}

fn counted_at(line: &[u8], from: usize, out: &mut Buffer) -> Option<usize> {
    let mut step = from;

    if matches!(line.get(step), Some(b'+' | b'-')) {
        step += 1;
    }

    while line.get(step).is_some_and(u8::is_ascii_digit) {
        step += 1;
    }

    if !matches!(line.get(step), Some(b'n' | b'N')) {
        return None;
    }

    if !out.push_bytes(&line[from..step]) || !out.push_bytes(b"n") {
        return None;
    }

    let sign = skipped(line, step + 1);

    if !matches!(line.get(sign), Some(b'+' | b'-')) {
        return Some(step + 1);
    }

    let offset = skipped(line, sign + 1);

    if !line.get(offset).is_some_and(u8::is_ascii_digit) {
        return Some(step + 1);
    }

    let written =
        out.push_bytes(b" ") && out.push_bytes(&line[sign..=sign]) && out.push_bytes(b" ");

    written.then_some(offset)
}

fn ruled(name: &[u8]) -> bool {
    if RULE_WORDS
        .iter()
        .any(|word| name.eq_ignore_ascii_case(word))
    {
        return true;
    }

    let Some(rest) = name.strip_prefix(b"-") else {
        return false;
    };

    let Some(at) = rest.iter().position(|byte| *byte == b'-') else {
        return false;
    };

    RULE_WORDS
        .iter()
        .any(|word| rest[at + 1..].eq_ignore_ascii_case(word))
}

fn named_rule(line: &[u8], from: usize, out: &mut Buffer) -> Option<usize> {
    let mut stop = from + 1;

    while stop < line.len() && worded(line[stop]) {
        stop += 1;
    }

    if !ruled(&line[from + 1..stop]) {
        return None;
    }

    lowered(&line[from..stop], out).then_some(stop)
}

fn attributed(line: &[u8], offset: usize, out: &mut Buffer) -> Option<usize> {
    let start = offset + 1;
    let mut stop = start;

    while stop < line.len() && line[stop] != b']' && line[stop] != b' ' {
        stop += 1;
    }

    if stop == start || matches!(line[start], b'"' | b'\'') {
        return None;
    }

    let held = out.push_bytes(b"=\"") && out.push_bytes(&line[start..stop]);

    (held && out.push_bytes(b"\"")).then_some(stop)
}

fn opens_a_number(line: &[u8], held: usize) -> bool {
    let opens = line[held].is_ascii_digit()
        || line[held] == b'.' && line.get(held + 1).is_some_and(u8::is_ascii_digit);

    if !opens {
        return false;
    }

    if held == 0 {
        return true;
    }

    let before = line[held - 1];

    !worded(before) || before == b'-' && (held < 2 || !worded(line[held - 2]))
}

fn opens_a_url(line: &[u8], held: usize) -> bool {
    if held + 4 > line.len() || !line[held..held + 3].eq_ignore_ascii_case(b"url") {
        return false;
    }

    line[held + 3] == b'(' && (held == 0 || !worded(line[held - 1]))
}

struct Reading {
    block: bool,
    bracket: bool,
    depth: u32,
    urled: u32,
    valued: bool,
}

fn lined(line: &[u8], values: bool, held: &mut Reading, out: &mut Buffer) -> bool {
    let mut offset = 0;

    while offset < line.len() {
        if held.block {
            let found = found_at(&line[offset..], b"*/");
            let stop = found.map_or(line.len(), |end| offset + end + 2);

            held.block = found.is_none();

            if !out.push_bytes(&line[offset..stop]) {
                return false;
            }

            offset = stop;

            continue;
        }

        let Some(stop) = stepped(line, offset, values, held, out) else {
            return false;
        };

        offset = stop;
    }

    true
}

fn stepped(
    line: &[u8],
    offset: usize,
    values: bool,
    held: &mut Reading,
    out: &mut Buffer,
) -> Option<usize> {
    let byte = line[offset];

    if line[offset..].starts_with(b"/*") {
        held.block = true;

        return out.push_bytes(b"/*").then_some(offset + 2);
    }

    if byte == b'"' || byte == b'\'' {
        return quoted(line, offset, out);
    }

    if opens_a_url(line, offset) {
        held.depth += 1;
        held.urled = held.depth;

        return out.push_bytes(b"url(").then_some(offset + 4);
    }

    match byte {
        b'(' => held.depth += 1,
        b'[' => {
            held.bracket = true;
            held.depth += 1;
        }
        b')' | b']' => {
            held.bracket = false;
            held.depth = held.depth.saturating_sub(1);

            if held.depth < held.urled {
                held.urled = 0;
            }
        }
        b':' if held.depth == 0 => held.valued = true,
        _ => (),
    }

    if byte == b'@' && line[..offset].iter().all(|blank| *blank == b' ') {
        if let Some(stop) = named_rule(line, offset, out) {
            return Some(stop);
        }
    }

    if !values && byte == b'(' && counts(line, offset) {
        if !out.push_bytes(b"(") {
            return None;
        }

        let start = skipped(line, offset + 1);

        return Some(counted_at(line, start, out).unwrap_or(start));
    }

    if held.bracket && byte == b'=' {
        if let Some(stop) = attributed(line, offset, out) {
            return Some(stop);
        }
    }

    let operator = matches!(byte, b'>' | b'+' | b'~') && line.get(offset + 1) != Some(&b'=');

    if !values && held.depth == 0 && operator {
        let leads = line[..offset].iter().all(|blank| *blank == b' ');
        let lead: &[u8] = if leads || line[offset - 1] == b' ' {
            b""
        } else {
            b" "
        };

        let written =
            out.push_bytes(lead) && out.push_bytes(&line[offset..=offset]) && out.push_bytes(b" ");

        return written.then_some(skipped(line, offset + 1));
    }

    let reads = values && held.valued && held.urled == 0;

    if reads && byte == b'*' {
        let leads = line[..offset].iter().all(|blank| *blank == b' ');
        let lead: &[u8] = if leads || line[offset - 1] == b' ' {
            b""
        } else {
            b" "
        };

        let written = out.push_bytes(lead) && out.push_bytes(b"* ");

        return written.then_some(skipped(line, offset + 1));
    }

    if reads && byte == b'#' {
        if let Some(stop) = coloured(line, offset, out) {
            return Some(stop);
        }
    }

    if reads && opens_a_number(line, offset) {
        return numbered(line, offset, out);
    }

    out.push_bytes(&line[offset..=offset]).then_some(offset + 1)
}

fn carries(line: &[u8]) -> bool {
    let at = remark_at(line);

    if at >= line.len() {
        return false;
    }

    let body = line[..at].trim_ascii();

    !body.is_empty() && !matches!(body.last(), Some(b';' | b'{' | b'}' | b','))
}

fn normalized(bytes: &[u8], out: &mut Buffer) -> bool {
    let mut held = Reading {
        block: false,
        bracket: false,
        depth: 0,
        urled: 0,
        valued: false,
    };
    let mut carried = false;
    let mut offset = 0;

    while offset < bytes.len() {
        let end = line_end(bytes, offset);
        let whole = &bytes[offset..end];

        let line = if carried {
            whole.trim_ascii_start()
        } else {
            whole
        };

        let values = carried || !held.block && declares(line);

        held.bracket = false;
        held.depth = 0;
        held.urled = 0;
        held.valued = line.trim_ascii().starts_with(b"@");

        if !lined(line, values, &mut held, out) {
            return false;
        }

        let joins = !held.block && carries(line);
        let after = (end + 1).min(bytes.len());
        let next = bytes[after..line_end(bytes, after)].trim_ascii();

        let gap: &[u8] = if !joins {
            b"\n"
        } else if matches!(next.first(), Some(b',' | b';')) {
            b""
        } else {
            b" "
        };

        if !out.push_bytes(gap) {
            return false;
        }

        carried = joins && values;
        offset = end + 1;
    }

    true
}

fn laid(bytes: &[u8], options: Options, out: &mut Buffer) -> bool {
    let mut block = false;
    let mut listed = false;
    let mut offset = 0;
    let mut remarked = false;

    while offset < bytes.len() {
        let end = line_end(bytes, offset);
        let line = &bytes[offset..end];
        let body = line.trim_ascii();

        if listed && !block && body.is_empty() {
            offset = end + 1;

            continue;
        }

        let crossed = crossing(line, block);

        let held = if block || crossed {
            out.push_bytes(line)
        } else {
            written(
                line,
                closes(bytes, end),
                remarked,
                listed && remarked,
                options,
                out,
            )
        };

        if !held || !out.push_bytes(b"\n") {
            return false;
        }

        if !block && !body.is_empty() {
            remarked = body.starts_with(b"/*");
        } else if block {
            remarked = true;
        }

        if !block && !crossed && !body.is_empty() && !remarked {
            listed = body.ends_with(b",");
        }

        block = crossed;
        offset = end + 1;
    }

    true
}

fn operator(body: &[u8], from: usize) -> Option<usize> {
    let mut held = from;

    while held < body.len() {
        let stop = separator(body, held, false)?;
        let part = &body[held..stop];

        if matches!(part, b"+" | b"-" | b"*" | b"/") {
            return Some(stop - 1);
        }

        held = skipped(body, stop);
    }

    None
}

fn crossing(line: &[u8], block: bool) -> bool {
    let mut held = block;
    let mut offset = 0;
    let mut quote = 0;

    while offset < line.len() {
        if held {
            let Some(end) = found_at(&line[offset..], b"*/") else {
                return true;
            };

            held = false;
            offset += end + 2;

            continue;
        }

        let byte = line[offset];

        if quote != 0 {
            offset += if byte == b'\\' { 2 } else { 1 };

            if byte == quote {
                quote = 0;
            }

            continue;
        }

        if byte == b'"' || byte == b'\'' {
            quote = byte;
            offset += 1;

            continue;
        }

        if line[offset..].starts_with(b"/*") {
            held = true;
            offset += 2;

            continue;
        }

        offset += 1;
    }

    held
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
    roles: BoundedVec<u8>,
    scratch: Buffer,
    staged: Buffer,
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

    if !brace::closed(input.source, input.tokens, false, false) {
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
            roles: BoundedVec::reserve(element_count_max),
            scratch: Buffer::reserve(scratch_bytes_max),
            staged: Buffer::reserve(scratch_bytes_max),
        }
    }

    #[must_use]
    pub fn format(&mut self, input: &Input<'_>, out: &mut Buffer) -> Outcome {
        assert_eq!(input.tokens.len(), input.raw.len());

        if broken(input) {
            return Outcome::Refusal;
        }

        if !brace::marked(input.tree, input.tokens, &mut self.roles) {
            return Outcome::Overflow;
        }

        let held = brace::Input {
            added: &[],
            origin: &[],
            origins: &[],
            gives: &[],
            macros: &[],
            roles: &self.roles,
            options: input.options,
            policy: POLICY,
            source: input.source,
            tokens: input.tokens,
        };

        if !self.inner.format(&held, &mut self.scratch) {
            return Outcome::Overflow;
        }

        self.staged.clear();

        if !normalized(self.scratch.as_bytes(), &mut self.staged) {
            return Outcome::Overflow;
        }

        out.clear();

        if !laid(self.staged.as_bytes(), input.options, out) {
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
