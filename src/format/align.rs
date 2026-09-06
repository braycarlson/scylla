use crate::bounded::{Buffer, Bytes as _, count_of};

pub const PADDING_MAX: u32 = 1024;
const COMMENT_CAPS: bool = true;
const BLOCK_CLOSE: &[u8] = b"*/";
const BLOCK_OPEN: &[u8] = b"/*";
const COMMENT: &[u8] = b"//";
const GROUP_DEPTH_MAX: usize = 64;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Target {
    Assign,
    Body,
    Comment,
    Element,
    Field,
    Key,
    Row(u32),
    Tag,
    Type,
    Value,
}

pub const ROW_COLUMN_MAX: u32 = 8;
const ATTRIBUTE_COLUMNS: bool = true;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Carry {
    Block,
    None,
    Raw,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Cut {
    head: u32,
    tail: u32,
}

#[derive(Clone, Copy)]
struct Kept {
    from: u32,
    held: bool,
    indent: u32,
    to: u32,
    typed: bool,
}

impl Kept {
    const NONE: Self = Self {
        from: 0,
        held: false,
        indent: 0,
        to: 0,
        typed: false,
    };
}

#[derive(Clone, Copy)]
struct Counted {
    at: u32,
    count: u32,
    held: bool,
    indent: u32,
    lnsum: u64,
    previous: u32,
}

impl Counted {
    const NONE: Self = Self {
        at: 0,
        count: 0,
        held: false,
        indent: 0,
        lnsum: 0,
        previous: 0,
    };
}

#[derive(Clone, Copy)]
struct Filled {
    found: u32,
    from: u32,
    held: bool,
    indent: u32,
    to: u32,
}

impl Filled {
    const NONE: Self = Self {
        found: 0,
        from: 0,
        held: false,
        indent: 0,
        to: 0,
    };
}

#[derive(Clone, Copy)]
struct Groups {
    at: u32,
    depth: usize,
    held: bool,
    stack: [(u32, u32, u32); GROUP_DEPTH_MAX],
}

impl Groups {
    const NONE: Self = Self {
        at: 0,
        depth: 0,
        held: false,
        stack: [(0, 0, 0); GROUP_DEPTH_MAX],
    };

    fn header_of<'held>(&mut self, bytes: &'held [u8], start: u32) -> Option<&'held [u8]> {
        if !self.held || start < self.at {
            *self = Self::NONE;
            self.held = true;
        }

        let mut offset = self.at;

        while offset < start {
            let (from, to) = line_at(bytes, offset);
            let line = &bytes[from as usize..to as usize];

            offset = to + 1;

            if line.trim_ascii().is_empty() {
                continue;
            }

            let indent = indent_of(line);

            while self.depth > 0 && self.stack[self.depth - 1].0 >= indent {
                self.depth -= 1;
            }

            if self.depth == GROUP_DEPTH_MAX {
                self.held = false;

                return group_of(bytes, start);
            }

            self.stack[self.depth] = (indent, from, to);
            self.depth += 1;
        }

        self.at = start;

        let indent = {
            let (from, to) = line_at(bytes, start);

            indent_of(&bytes[from as usize..to as usize])
        };

        let mut scan = self.depth;

        while scan > 0 {
            scan -= 1;

            let (held, from, to) = self.stack[scan];

            if held < indent {
                let line = &bytes[from as usize..to as usize];

                return Some(body_of(line.trim_ascii()).trim_ascii_end());
            }
        }

        None
    }
}

#[derive(Clone, Copy)]
struct Memo {
    counted: Counted,
    filled: Filled,
    groups: Groups,
    kept: Kept,
}

impl Memo {
    const NONE: Self = Self {
        counted: Counted::NONE,
        filled: Filled::NONE,
        groups: Groups::NONE,
        kept: Kept::NONE,
    };
}

#[derive(Clone, Copy)]
struct Reading<'held> {
    body: &'held [u8],
    closes: bool,
    fielded: Option<Cut>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Quotes {
    backtick: bool,
    double: bool,
    single: bool,
    skip: bool,
}

impl Quotes {
    const NONE: Self = Self {
        backtick: false,
        double: false,
        single: false,
        skip: false,
    };

    const fn inside(self) -> bool {
        self.backtick || self.double || self.single
    }

    fn opens(&mut self, byte: u8) {
        match byte {
            b'"' => self.double = true,
            b'\'' => self.single = true,
            b'`' => self.backtick = true,
            _ => (),
        }
    }

    fn step(&mut self, byte: u8) {
        if self.skip {
            self.skip = false;

            return;
        }

        if (self.double || self.single) && byte == b'\\' {
            self.skip = true;

            return;
        }

        match byte {
            b'"' if !self.single && !self.backtick => self.double = !self.double,
            b'\'' if !self.double && !self.backtick => self.single = !self.single,
            b'`' if !self.double && !self.single => self.backtick = !self.backtick,
            _ => (),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Spec {
    Bare,
    Blank,
    Typed,
    Valued,
}

const fn remarks(target: Target) -> bool {
    matches!(
        target,
        Target::Body | Target::Comment | Target::Element | Target::Field | Target::Type
    )
}

fn columns_of(line: &[u8], width: u32) -> u32 {
    let stop = (width as usize).min(line.len());
    let mut found = 0;

    for byte in &line[..stop] {
        if byte & 0xC0 != 0x80 {
            found += 1;
        }
    }

    found
}

fn elements_of(line: &[u8]) -> u32 {
    let body = body_of(line).trim_ascii_end();

    if !body.ends_with(b",") {
        return 1;
    }

    let mut depth = 0;
    let mut found = 0;
    let mut quotes = Quotes::NONE;

    for byte in body {
        if quotes.inside() {
            quotes.step(*byte);

            continue;
        }

        match *byte {
            b'(' | b'[' | b'{' => depth += 1,
            b')' | b']' | b'}' => depth -= 1,
            b',' if depth == 0 => found += 1,
            _ => quotes.opens(*byte),
        }
    }

    found
}

fn elements_ranked(line: &[u8]) -> Option<(u32, u32, u32, u64)> {
    let indent = indent_of(line) as usize;
    let body = body_of(line).trim_ascii_end();

    if body.len() <= indent {
        return None;
    }

    let mut count = 0;
    let mut depth = 0;
    let mut first = 0;
    let mut last = 0;
    let mut lnsum = 0;
    let mut quotes = Quotes::NONE;
    let mut start = indent;

    for held in indent..=body.len() {
        let byte = if held < body.len() { body[held] } else { b',' };

        if quotes.inside() {
            quotes.step(byte);

            continue;
        }

        match byte {
            b'(' | b'[' | b'{' => depth += 1,
            b')' | b']' | b'}' => depth -= 1,
            b',' if depth == 0 => {
                let width = columns_of(&body[start..held], count_of(held - start));

                if width > 0 {
                    if count == 0 {
                        first = width;
                    }

                    count += 1;
                    last = width;
                    lnsum += u64::from(log2_of(width));
                }

                start = held + 1;

                while start < body.len() && body[start] == b' ' {
                    start += 1;
                }
            }
            _ => quotes.opens(byte),
        }
    }

    (count > 0).then_some((first, last, count, lnsum))
}

fn indent_of(line: &[u8]) -> u32 {
    let mut held = 0;

    while held < line.len() && (line[held] == b' ' || line[held] == b'\t') {
        held += 1;
    }

    count_of(held)
}

fn padded(out: &mut Buffer, width: u32) -> bool {
    for _ in 0..width {
        if !out.push_bytes(b" ") {
            return false;
        }
    }

    true
}

#[must_use]
pub fn crosses(line: &[u8], carry: Carry) -> Carry {
    let mut held = carry;
    let mut offset = 0;
    let mut quotes = Quotes::NONE;

    while offset < line.len() {
        if held == Carry::Block {
            if line[offset..].starts_with(BLOCK_CLOSE) {
                held = Carry::None;
                offset += BLOCK_CLOSE.len();

                continue;
            }

            offset += 1;

            continue;
        }

        if held == Carry::Raw {
            if line[offset] == b'`' {
                held = Carry::None;
            }

            offset += 1;

            continue;
        }

        if quotes.inside() {
            quotes.step(line[offset]);
            offset += 1;

            continue;
        }

        if line[offset..].starts_with(COMMENT) {
            return Carry::None;
        }

        if line[offset..].starts_with(BLOCK_OPEN) {
            held = Carry::Block;
            offset += BLOCK_OPEN.len();

            continue;
        }

        if line[offset] == b'`' {
            held = Carry::Raw;
            offset += 1;

            continue;
        }

        quotes.opens(line[offset]);
        offset += 1;
    }

    held
}

fn cuts_at(line: &[u8], target: Target, held: usize, indent: usize, read: Reading<'_>) -> bool {
    match target {
        Target::Assign => assigns_at(line, held, indent),
        Target::Body => bodies_at(line, held, indent, read.body),
        Target::Comment => {
            (line[held..].starts_with(COMMENT) || line[held..].starts_with(BLOCK_OPEN))
                && held > indent
                && !operates(line, held, indent)
        }
        Target::Element => elements_at(line, held, indent),
        Target::Field => fields_at(line, held, indent),
        Target::Key => keys_at(line, held, indent, read),
        Target::Row(column) => rows_at(line, held, indent, column, read.body),
        Target::Tag => tags_at(line, held, indent, read.body),
        Target::Type => types_at(line, held, indent, read.fielded),
        Target::Value => assigns_at(line, held, indent),
    }
}

fn elements_at(line: &[u8], held: usize, indent: usize) -> bool {
    if held <= indent {
        return false;
    }

    if !line[held..].starts_with(COMMENT) && !line[held..].starts_with(BLOCK_OPEN) {
        return false;
    }

    if line[indent] == b'$' {
        return false;
    }

    let code = line[indent..held].trim_ascii_end();

    code.ends_with(b",") || ELEMENT_BODIES && code.ends_with(b"}")
}

fn operates(line: &[u8], held: usize, indent: usize) -> bool {
    let code = line[indent..held].trim_ascii_end();

    if code.ends_with(b"++") || code.ends_with(b"--") {
        return false;
    }

    code.last().is_some_and(|byte| {
        matches!(
            byte,
            b'!' | b'%' | b'&' | b'*' | b'+' | b'-' | b'/' | b'<' | b'=' | b'>' | b'^' | b'|'
        )
    })
}

fn assigns_at(line: &[u8], held: usize, indent: usize) -> bool {
    line[held] == b'='
        && held > indent
        && line[held - 1] == b' '
        && line.get(held + 1) != Some(&b'=')
        && line.get(held.wrapping_sub(2)) != Some(&b'=')
        && line.get(held.wrapping_sub(2)) != Some(&b'!')
        && line.get(held.wrapping_sub(2)) != Some(&b'<')
        && line.get(held.wrapping_sub(2)) != Some(&b'>')
        && line.get(held.wrapping_sub(2)) != Some(&b':')
}

const fn lettered(byte: u8) -> bool {
    byte.is_ascii_alphabetic() || byte >= 0x80
}

fn fields_at(line: &[u8], held: usize, indent: usize) -> bool {
    if held <= indent || line[held] == b' ' || line[held - 1] != b' ' {
        return false;
    }

    let mut start = held;

    while start > indent && line[start - 1] == b' ' {
        start -= 1;
    }

    if start == indent {
        return false;
    }

    if !lettered(line[indent]) && !matches!(line[indent], b'*' | b'_') {
        return false;
    }

    if line[start - 1] == b',' {
        return false;
    }

    line[indent..start].iter().all(|byte| {
        byte.is_ascii_alphanumeric()
            || *byte >= 0x80
            || matches!(*byte, b'*' | b'.' | b'_' | b',' | b' ')
    })
}

fn bodies_at(line: &[u8], held: usize, indent: usize, body: &[u8]) -> bool {
    if held <= indent || line[held] != b'{' || line[held - 1] != b' ' {
        return false;
    }

    if !line[indent..].starts_with(b"func ") {
        return false;
    }

    body.ends_with(b"}")
}

fn tags_at(line: &[u8], held: usize, indent: usize, body: &[u8]) -> bool {
    if held <= indent || line[held - 1] != b' ' {
        return false;
    }

    let quote = line[held];

    if quote != b'`' && quote != b'"' {
        return false;
    }

    body.len() > held + 1 && body.ends_with(&[quote])
}

fn types_at(line: &[u8], held: usize, indent: usize, fielded: Option<Cut>) -> bool {
    if held <= indent || line[held] == b' ' || line[held - 1] != b' ' {
        return false;
    }

    if !matches!(line[held], b'`' | b'"')
        && !line[held..].starts_with(COMMENT)
        && !line[held..].starts_with(BLOCK_OPEN)
    {
        return false;
    }

    if worded(line, indent) {
        return false;
    }

    if !celled(line, indent, held, true) {
        return false;
    }

    fielded.is_some_and(|cut| {
        (cut.tail as usize) < held && celled(line, cut.tail as usize, held, false)
    })
}

fn celled(line: &[u8], from: usize, held: usize, whole: bool) -> bool {
    let cell = line[from..held].trim_ascii_end();

    if !whole
        && !cell.first().is_some_and(|byte| {
            byte.is_ascii_alphanumeric()
                || *byte >= 0x80
                || matches!(*byte, b'*' | b'[' | b'<' | b'_')
        })
    {
        return false;
    }

    let mut depth = 0_i32;
    let mut quotes = Quotes::NONE;

    for byte in cell {
        if quotes.inside() {
            quotes.step(*byte);

            continue;
        }

        quotes.step(*byte);

        if whole && matches!(*byte, b'=' | b':' | b';') {
            return false;
        }

        match *byte {
            b'(' | b'[' | b'{' => depth += 1,
            b')' | b']' | b'}' => depth -= 1,
            b' ' if depth == 0 && !whole => return false,
            _ => (),
        }
    }

    true
}

fn worded(line: &[u8], indent: usize) -> bool {
    const WORDS: [&[u8]; 25] = [
        b"break",
        b"case",
        b"chan",
        b"const",
        b"continue",
        b"default",
        b"defer",
        b"else",
        b"fallthrough",
        b"for",
        b"func",
        b"go",
        b"goto",
        b"if",
        b"import",
        b"interface",
        b"map",
        b"package",
        b"range",
        b"return",
        b"select",
        b"struct",
        b"switch",
        b"type",
        b"var",
    ];

    let rest = &line[indent.min(line.len())..];
    let word = rest
        .iter()
        .position(|byte| !byte.is_ascii_alphanumeric() && *byte != b'_')
        .map_or(rest, |at| &rest[..at]);

    WORDS.contains(&word)
}

fn body_of(line: &[u8]) -> &[u8] {
    let mut held = 0;
    let mut quotes = Quotes::NONE;

    while held < line.len() {
        if !quotes.inside() && line[held..].starts_with(COMMENT) {
            return &line[..held];
        }

        quotes.step(line[held]);
        held += 1;
    }

    line
}

fn group_of(bytes: &[u8], start: u32) -> Option<&[u8]> {
    if start == 0 {
        return None;
    }

    let indent = {
        let (from, to) = line_at(bytes, start);

        indent_of(&bytes[from as usize..to as usize])
    };

    let mut end = start as usize - 1;

    loop {
        let mut from = end;

        while from > 0 && bytes[from - 1] != b'\n' {
            from -= 1;
        }

        let held = &bytes[from..end];

        if !held.trim_ascii().is_empty() && indent_of(held) < indent {
            return Some(body_of(held.trim_ascii()).trim_ascii_end());
        }

        if from == 0 {
            return None;
        }

        end = from - 1;
    }
}

fn declares(line: &[u8]) -> bool {
    matches!(line, b"const (" | b"type (" | b"var (")
}

fn specifies(line: &[u8]) -> bool {
    matches!(line, b"const (" | b"var (")
}

fn opens_a_group(bytes: &[u8], start: u32, target: Target, groups: &mut Groups) -> bool {
    if !matches!(
        target,
        Target::Assign | Target::Field | Target::Tag | Target::Value
    ) {
        return true;
    }

    let Some(line) = groups.header_of(bytes, start) else {
        return false;
    };

    if target == Target::Assign {
        return declares(line);
    }

    if target == Target::Tag {
        return line.ends_with(b"struct {");
    }

    if target == Target::Value {
        return specifies(line);
    }

    declares(line) || line.ends_with(b"struct {") || line.ends_with(b"interface {")
}

fn valued_at(line: &[u8]) -> Option<u32> {
    let indent = indent_of(line) as usize;
    let mut depth = 0_i32;
    let mut held = indent;
    let mut quotes = Quotes::NONE;

    while held < line.len() {
        let byte = line[held];

        if quotes.inside() {
            quotes.step(byte);
            held += 1;

            continue;
        }

        if line[held..].starts_with(COMMENT) || line[held..].starts_with(BLOCK_OPEN) {
            return None;
        }

        match byte {
            b'(' | b'[' | b'{' => depth += 1,
            b')' | b']' | b'}' => depth -= 1,
            b'=' if depth == 0
                && held > indent
                && line[held - 1] == b' '
                && line.get(held + 1) == Some(&b' ') =>
            {
                return Some(columns_of(line, count_of(held)));
            }
            _ => quotes.opens(byte),
        }

        held += 1;
    }

    None
}

fn blocked(line: &[u8], indent: u32) -> bool {
    let body = line.trim_ascii();

    !body.is_empty()
        && indent_of(line) == indent
        && body.contains(&b' ')
        && !body.starts_with(COMMENT)
        && !body.starts_with(BLOCK_OPEN)
}

fn continues_a_list(bytes: &[u8], start: u32) -> bool {
    let (from, _) = line_at(bytes, start);

    if from == 0 {
        return false;
    }

    let mut held = from - 1;

    while held > 0 && bytes[held as usize - 1] != b'\n' {
        held -= 1;
    }

    let (_, to) = line_at(bytes, held);

    body_of(&bytes[held as usize..to as usize])
        .trim_ascii_end()
        .ends_with(b",")
}

fn labelled(body: &[u8]) -> bool {
    body.len() > 1
        && body[..body.len() - 1]
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'_')
}

fn attributed(header: &[u8]) -> bool {
    let held = header.trim_ascii_start();

    (held.starts_with(b"#[") || held.starts_with(b"#!["))
        && !held.windows(7).any(|found| found == b"derive(")
}

fn columnless(bytes: &[u8], start: u32, line: &[u8], target: Target, groups: &mut Groups) -> bool {
    if target == Target::Element {
        return ATTRIBUTE_COLUMNS && groups.header_of(bytes, start).is_some_and(attributed);
    }

    if target != Target::Comment {
        return false;
    }

    let body = body_of(line).trim_ascii();

    if body.ends_with(b":") && (body.starts_with(b"case ") || labelled(body)) {
        return !continues_a_list(bytes, start);
    }

    body.ends_with(b",")
        && groups
            .header_of(bytes, start)
            .is_some_and(|held| declares(held) || held.ends_with(b"struct {"))
}

fn filled_at(bytes: &[u8], start: u32, indent: u32, target: Target, memo: &mut Memo) -> u32 {
    if target != Target::Comment || !memo.groups.header_of(bytes, start).is_some_and(declares) {
        return 0;
    }

    let filled = memo.filled;

    if filled.held && filled.indent == indent && filled.from <= start && start < filled.to {
        return filled.found;
    }

    let (from, _) = line_at(bytes, start);
    let mut found = 0;
    let mut edge = from;

    while edge > 0 {
        let mut held = edge - 1;

        while held > 0 && bytes[held as usize - 1] != b'\n' {
            held -= 1;
        }

        let (_, to) = line_at(bytes, held);
        let line = &bytes[held as usize..to as usize];

        if !blocked(line, indent) {
            break;
        }

        found = found.max(valued_at(line).unwrap_or(0));
        edge = held;
    }

    let mut offset = from;

    while offset < count_of(bytes.len()) {
        let (held, to) = line_at(bytes, offset);
        let line = &bytes[held as usize..to as usize];

        if !blocked(line, indent) {
            break;
        }

        found = found.max(valued_at(line).unwrap_or(0));
        offset = to + 1;
    }

    memo.filled = Filled {
        found,
        from: edge,
        held: true,
        indent,
        to: offset,
    };

    found
}

fn remarked(line: &[u8]) -> bool {
    body_of(line).len() != line.len()
}

fn coded(line: &[u8]) -> u32 {
    count_of(body_of(line).trim_ascii_end().len())
}

fn spec_of(line: &[u8]) -> Spec {
    let indent = indent_of(line) as usize;

    let Some(cut) = cut_of(line, Target::Field) else {
        return Spec::Bare;
    };

    let at = cut.tail as usize;

    if line[at..].starts_with(COMMENT) || line[at..].starts_with(BLOCK_OPEN) {
        return Spec::Blank;
    }

    if assigns_at(line, at, indent) {
        return Spec::Valued;
    }

    Spec::Typed
}

fn keeps_a_type(bytes: &[u8], start: u32, indent: u32, kept: &mut Kept) -> bool {
    if kept.held && kept.indent == indent && kept.from <= start && start < kept.to {
        return kept.typed;
    }

    let runs = |line: &[u8]| indent_of(line) == indent && cut_of(line, Target::Value).is_some();
    let (first, _) = line_at(bytes, start);
    let mut from = first;
    let mut typed = false;

    while let Some((held, end)) = line_before(bytes, from) {
        let line = &bytes[held as usize..end as usize];

        if !runs(line) {
            break;
        }

        typed |= spec_of(line) == Spec::Typed;
        from = held;
    }

    let mut offset = first;
    let mut to = first;

    while offset < count_of(bytes.len()) {
        let (held, end) = line_at(bytes, offset);
        let line = &bytes[held as usize..end as usize];

        if !runs(line) {
            break;
        }

        typed |= spec_of(line) == Spec::Typed;
        to = end + 1;
        offset = end + 1;
    }

    *kept = Kept {
        from,
        held: true,
        indent,
        to,
        typed,
    };

    typed
}

fn owns_a_value(bytes: &[u8], start: u32, line: &[u8], kept: &mut Kept) -> bool {
    match spec_of(line) {
        Spec::Typed => true,
        Spec::Valued => keeps_a_type(bytes, start, indent_of(line), kept),
        Spec::Bare | Spec::Blank => false,
    }
}

fn celled_at(bytes: &[u8], start: u32, line: &[u8], indent: u32, kept: &mut Kept) -> Option<u32> {
    if indent_of(line) != indent {
        return None;
    }

    let field = cut_of(line, Target::Field)?;
    let spec = spec_of(line);

    if spec == Spec::Blank || spec == Spec::Valued && keeps_a_type(bytes, start, indent, kept) {
        return Some(columns_of(line, field.tail));
    }

    if spec == Spec::Typed
        && let Some(cut) = cut_of(line, Target::Value)
    {
        return Some(columns_of(line, cut.head));
    }

    if remarked(line) {
        return Some(columns_of(line, coded(line)));
    }

    None
}

fn values_run(bytes: &[u8], start: u32, indent: u32, kept: &mut Kept) -> (u32, u32) {
    let (_, first) = line_at(bytes, start);

    if cut_of(&bytes[start as usize..first as usize], Target::Value).is_none() {
        return (0, start);
    }

    let mut edge = start;
    let mut width = 0;

    while edge > 0 {
        let mut held = edge - 1;

        while held > 0 && bytes[held as usize - 1] != b'\n' {
            held -= 1;
        }

        let (_, to) = line_at(bytes, held);

        let Some(found) = celled_at(
            bytes,
            held,
            &bytes[held as usize..to as usize],
            indent,
            kept,
        ) else {
            break;
        };

        width = width.max(found);
        edge = held;
    }

    let mut offset = start;
    let mut stop = start;

    while offset < count_of(bytes.len()) {
        let (held, to) = line_at(bytes, offset);

        let Some(found) = celled_at(
            bytes,
            held,
            &bytes[held as usize..to as usize],
            indent,
            kept,
        ) else {
            break;
        };

        width = width.max(found);
        stop = to + 1;
        offset = to + 1;
    }

    (width, stop)
}

fn cut_at(bytes: &[u8], start: u32, line: &[u8], target: Target, memo: &mut Memo) -> Option<Cut> {
    let cut = cut_of(line, target)?;

    if target == Target::Value && !owns_a_value(bytes, start, line, &mut memo.kept) {
        return None;
    }

    Some(cut)
}

fn closing(line: &[u8]) -> bool {
    let body = body_of(line).trim_ascii_end();

    body.last()
        .is_some_and(|byte| matches!(*byte, b')' | b']' | b'}'))
        && depth_of(line) < 0
}

fn keys_at(line: &[u8], held: usize, indent: usize, read: Reading<'_>) -> bool {
    if held <= indent || line[held] == b' ' {
        return false;
    }

    if !read.body.ends_with(b",") && !read.closes {
        return false;
    }

    let mut start = held;

    while start > indent && line[start - 1] == b' ' {
        start -= 1;
    }

    if start == held || start <= indent + 1 || line[start - 1] != b':' {
        return false;
    }

    line[start - 2] != b':' && line.get(start) != Some(&b'=')
}

fn rows_at(line: &[u8], held: usize, indent: usize, column: u32, body: &[u8]) -> bool {
    if held <= indent || line[held] == b' ' {
        return false;
    }

    if !body.ends_with(b",") {
        return false;
    }

    if line[held..].starts_with(COMMENT) || line[held..].starts_with(BLOCK_OPEN) {
        return false;
    }

    if arrowed(line, indent) {
        return false;
    }

    let mut start = held;

    while start > indent && line[start - 1] == b' ' {
        start -= 1;
    }

    if start == held || start <= indent || line[start - 1] != b',' {
        return false;
    }

    separators(line, indent, start) == column + 1
}

fn arrowed(line: &[u8], indent: usize) -> bool {
    let mut depth = 0_i32;
    let mut held = indent;
    let mut quotes = Quotes::NONE;

    while held + 1 < line.len() {
        let byte = line[held];

        if quotes.inside() {
            quotes.step(byte);
            held += 1;

            continue;
        }

        match byte {
            b'(' | b'[' | b'{' => depth += 1,
            b')' | b']' | b'}' => depth -= 1,
            b'=' if depth == 0 && line[held + 1] == b'>' => return true,
            _ => quotes.opens(byte),
        }

        held += 1;
    }

    false
}

fn separators(line: &[u8], indent: usize, stop: usize) -> u32 {
    let mut depth = 0_i32;
    let mut found = 0;
    let mut held = indent;
    let mut quotes = Quotes::NONE;

    while held < stop {
        let byte = line[held];

        if quotes.inside() {
            quotes.step(byte);
            held += 1;

            continue;
        }

        match byte {
            b'(' | b'[' | b'{' => depth += 1,
            b')' | b']' | b'}' => depth -= 1,
            b',' if depth == 0 => found += 1,
            _ => quotes.opens(byte),
        }

        held += 1;
    }

    found
}

fn rows_run(bytes: &[u8], start: u32, indent: u32, column: u32) -> (u32, u32) {
    let mut carry = Carry::None;
    let mut offset = start;
    let mut stop = start;
    let mut width = 0;

    while offset < count_of(bytes.len()) {
        let (from, to) = line_at(bytes, offset);
        let line = &bytes[from as usize..to as usize];
        let held = carry != Carry::None;

        carry = crosses(line, carry);

        let body = line.trim_ascii();

        if !held && !body.starts_with(COMMENT) && !body.starts_with(BLOCK_OPEN) {
            if indent_of(line) != indent {
                break;
            }

            let Some(cut) = cut_of(line, Target::Row(column)) else {
                break;
            };

            width = width.max(columns_of(line, cut.head));
        }

        stop = to + 1;
        offset = to + 1;
    }

    (width, stop)
}

fn reading(line: &[u8], target: Target) -> Reading<'_> {
    Reading {
        body: body_of(line).trim_ascii_end(),
        closes: target == Target::Key && closing(line),
        fielded: if target == Target::Type {
            cut_of(line, Target::Field)
        } else {
            None
        },
    }
}

fn lifetime_at(line: &[u8], held: usize, target: Target) -> bool {
    if !ELEMENT_LIFETIMES || target != Target::Element || line[held] != b'\'' {
        return false;
    }

    let named = line
        .get(held + 1)
        .is_some_and(|byte| byte.is_ascii_alphabetic() || *byte == b'_');

    named && line.get(held + 2) != Some(&b'\'')
}

fn cut_of(line: &[u8], target: Target) -> Option<Cut> {
    let read = reading(line, target);
    let indent = indent_of(line) as usize;
    let mut block = false;
    let mut depth = 0_i32;
    let mut held = indent;
    let mut quotes = Quotes::NONE;

    while held < line.len() {
        let byte = line[held];

        if block {
            if line[held..].starts_with(BLOCK_CLOSE) {
                block = false;
                held += BLOCK_CLOSE.len();

                continue;
            }

            held += 1;

            continue;
        }

        if quotes.inside() {
            quotes.step(byte);
            held += 1;

            continue;
        }

        if line[held..].starts_with(BLOCK_OPEN) {
            if !remarks(target) || held == indent {
                return None;
            }

            if !line[held..].trim_ascii_end().ends_with(BLOCK_CLOSE) {
                block = true;
                held += BLOCK_OPEN.len();

                continue;
            }
        }

        if line[held..].starts_with(COMMENT) {
            if held == indent {
                return None;
            }

            if !matches!(
                target,
                Target::Comment | Target::Element | Target::Field | Target::Type
            ) || !cuts_at(line, target, held, indent, read)
            {
                return None;
            }
        }

        if depth != 0 && target != Target::Comment || !cuts_at(line, target, held, indent, read) {
            if matches!(byte, b'(' | b'[' | b'{') {
                depth += 1;
            }

            if matches!(byte, b')' | b']' | b'}') {
                depth -= 1;
            }

            if !lifetime_at(line, held, target) {
                quotes.opens(byte);
            }

            held += 1;

            continue;
        }

        let mut start = held;

        while start > indent && line[start - 1] == b' ' {
            start -= 1;
        }

        if start == indent {
            return None;
        }

        return Some(Cut {
            head: count_of(start),
            tail: count_of(held),
        });
    }

    None
}

fn line_at(bytes: &[u8], offset: u32) -> (u32, u32) {
    let mut end = offset as usize;

    while end < bytes.len() && bytes[end] != b'\n' {
        end += 1;
    }

    (offset, count_of(end))
}

fn log2_of(value: u32) -> u32 {
    const ONE: u64 = 1 << 16;
    const TWO: u64 = 2 << 16;

    if value == 0 {
        return 0;
    }

    let bits = value.ilog2();
    let mut found = u64::from(bits) << 16;
    let mut held = (u64::from(value) << 16) >> bits;
    let mut step = ONE >> 1;

    while step > 0 {
        held = (held * held) >> 16;

        if held >= TWO {
            held >>= 1;
            found += step;
        }

        step >>= 1;
    }

    u32::try_from(found).unwrap_or(u32::MAX)
}

fn parts_run(size: u32, previous: u32, lnsum: u64, count: u32) -> bool {
    const RATIO: u32 = 86630;
    const SMALL: u32 = 40;

    if previous == 0 || size == 0 || count == 0 || previous <= SMALL && size <= SMALL {
        return false;
    }

    let mean = u32::try_from(lnsum / u64::from(count)).unwrap_or(u32::MAX);
    let held = log2_of(size);

    held + RATIO <= mean || held >= mean.saturating_add(RATIO)
}

fn struct_tagged(line: &[u8]) -> bool {
    cut_of(line, Target::Type).is_some_and(|cut| line.get(cut.tail as usize) == Some(&b'`'))
}

fn depth_of(line: &[u8]) -> i32 {
    let mut block = false;
    let mut depth = 0_i32;
    let mut held = 0;
    let mut quotes = Quotes::NONE;

    while held < line.len() {
        let byte = line[held];

        if block {
            if line[held..].starts_with(BLOCK_CLOSE) {
                block = false;
                held += BLOCK_CLOSE.len();

                continue;
            }

            held += 1;

            continue;
        }

        if quotes.inside() {
            quotes.step(byte);
            held += 1;

            continue;
        }

        if line[held..].starts_with(COMMENT) {
            break;
        }

        if line[held..].starts_with(BLOCK_OPEN) {
            block = true;
            held += BLOCK_OPEN.len();

            continue;
        }

        if matches!(byte, b'(' | b'[' | b'{') {
            depth += 1;
        }

        if matches!(byte, b')' | b']' | b'}') {
            depth -= 1;
        }

        quotes.opens(byte);
        held += 1;
    }

    depth
}

const ELEMENT_RUNS_END: bool = true;
const ELEMENT_ATTRIBUTES: bool = true;
const ELEMENT_BODIES: bool = true;
const ELEMENT_LIFETIMES: bool = true;
const ELEMENT_RUNS_FILL: bool = true;

fn capped(line: &[u8], cut: Cut, indent: u32, line_width: u32, overhead: &mut u32) -> bool {
    if !COMMENT_CAPS || line_width == 0 {
        return false;
    }

    if *overhead == 0 {
        let text = &line[cut.tail as usize..];

        if !text.starts_with(COMMENT) && !text.starts_with(BLOCK_OPEN) {
            return false;
        }

        *overhead = columns_of(line, cut.head) + columns_of(line, count_of(line.len()))
            - columns_of(line, cut.tail);

        return false;
    }

    let inner = columns_of(line, cut.head).saturating_sub(indent + 1);

    inner + *overhead > line_width
}

fn elements_run(
    bytes: &[u8],
    start: u32,
    indent: u32,
    line_width: u32,
    groups: &mut Groups,
) -> (u32, u32) {
    let attributed = ELEMENT_ATTRIBUTES
        && groups
            .header_of(bytes, start)
            .is_some_and(|line| line.trim_ascii_start().starts_with(b"#["));

    if attributed {
        let (_, to) = line_at(bytes, start);

        return (0, to + 1);
    }

    let mut carry = Carry::None;
    let mut ends = false;
    let mut growing = true;
    let mut offset = start;
    let mut overhead = 0;
    let mut stop = start;
    let mut width = 0;

    while offset < count_of(bytes.len()) {
        let (from, to) = line_at(bytes, offset);
        let line = &bytes[from as usize..to as usize];
        let held = carry != Carry::None;

        carry = crosses(line, carry);

        let body = line.trim_ascii();

        if !held && !body.is_empty() {
            if indent_of(line) != indent
                || body.starts_with(COMMENT)
                || body.starts_with(BLOCK_OPEN)
            {
                break;
            }

            let found = cut_of(line, Target::Element);

            let filled = ELEMENT_RUNS_FILL
                && found.is_some_and(|at| {
                    separators(line, indent_of(line) as usize, at.head as usize) > 1
                });

            match found {
                Some(_) if filled && offset > start => break,
                Some(cut) if growing => {
                    if !capped(line, cut, indent, line_width, &mut overhead) {
                        width = width.max(columns_of(line, cut.head));
                    }

                    ends = filled;
                }
                Some(_) => (),
                None if ELEMENT_RUNS_END => break,
                None => growing = false,
            }
        } else {
            growing = false;
        }

        stop = to + 1;
        offset = to + 1;

        if ends {
            break;
        }
    }

    (width, stop)
}

fn ranked(line: &[u8]) -> Option<(u32, u32, u32, u64)> {
    if depth_of(line) != 0 {
        return None;
    }

    if let Some(key) = cut_of(line, Target::Key) {
        let width = columns_of(line, key.head).saturating_sub(indent_of(line) + 1);

        return (width > 0).then_some((width, width, 1, u64::from(log2_of(width))));
    }

    elements_ranked(line)
}

fn line_before(bytes: &[u8], from: u32) -> Option<(u32, u32)> {
    if from == 0 {
        return None;
    }

    let end = from - 1;
    let mut held = end;

    while held > 0 && bytes[held as usize - 1] != b'\n' {
        held -= 1;
    }

    Some((held, end))
}

fn parts_entries(line: &[u8], indent: u32) -> bool {
    let held = &line[(indent as usize).min(line.len())..];

    held.starts_with(COMMENT) || held.starts_with(BLOCK_OPEN)
}

fn list_head(bytes: &[u8], start: u32, indent: u32) -> u32 {
    let mut head = start;
    let mut offset = start;

    while let Some((from, to)) = line_before(bytes, offset) {
        let line = &bytes[from as usize..to as usize];

        if line.trim_ascii().is_empty() || indent_of(line) < indent {
            break;
        }

        if indent_of(line) == indent && parts_entries(line, indent) {
            break;
        }

        head = from;
        offset = from;
    }

    head
}

fn population(bytes: &[u8], start: u32, indent: u32, counted: &mut Counted) -> (u64, u32, u32) {
    if !counted.held || counted.indent != indent || counted.at > start {
        *counted = Counted {
            at: list_head(bytes, start, indent),
            count: 0,
            held: true,
            indent,
            lnsum: 0,
            previous: 0,
        };
    }

    let mut count = counted.count;
    let mut lnsum = counted.lnsum;
    let mut offset = counted.at;
    let mut previous = counted.previous;

    while offset < start {
        let (from, to) = line_at(bytes, offset);
        let line = &bytes[from as usize..to as usize];

        offset = to + 1;

        if line.trim_ascii().is_empty()
            || indent_of(line) < indent
            || indent_of(line) == indent && parts_entries(line, indent)
        {
            count = 0;
            lnsum = 0;
            previous = 0;

            continue;
        }

        if indent_of(line) != indent {
            continue;
        }

        let Some((first, last, entries, weight)) = ranked(line) else {
            continue;
        };

        if parts_run(first, previous, lnsum, count) {
            count = 0;
            lnsum = 0;
        }

        count += entries;
        lnsum += weight;
        previous = last;
    }

    *counted = Counted {
        at: start,
        count,
        held: true,
        indent,
        lnsum,
        previous,
    };

    (lnsum, count, previous)
}

fn run_of(
    bytes: &[u8],
    start: u32,
    indent: u32,
    target: Target,
    tagged: bool,
    memo: &mut Memo,
) -> (u32, u32) {
    let (mut lnsum, mut count, mut previous) = if matches!(target, Target::Comment | Target::Key) {
        population(bytes, start, indent, &mut memo.counted)
    } else {
        (0, 0, 0)
    };

    let mut carry = Carry::None;
    let mut listed = false;
    let mut offset = start;
    let mut stop = start;
    let mut width = 0;

    while offset < count_of(bytes.len()) {
        let (from, to) = line_at(bytes, offset);
        let line = &bytes[from as usize..to as usize];
        let held = carry != Carry::None;

        carry = crosses(line, carry);

        if held {
            stop = to + 1;
            offset = to + 1;

            continue;
        }

        let spanned = depth_of(line);

        if indent_of(line) != indent
            || matches!(target, Target::Comment | Target::Tag) && struct_tagged(line) != tagged
            || target == Target::Comment && spanned > 0 && listed
            || columnless(bytes, from, line, target, &mut memo.groups)
        {
            break;
        }

        let Some(cut) = cut_of(line, target) else {
            break;
        };

        let element = body_of(line).trim_ascii_end().ends_with(b",");
        let weighs = target == Target::Key || target == Target::Comment && element;
        let entry = ranked(line);
        let size = columns_of(line, cut.head);

        if weighs && entry.is_some_and(|(first, ..)| parts_run(first, previous, lnsum, count)) {
            if offset > start {
                break;
            }

            count = 0;
            lnsum = 0;
        }

        if target == Target::Key && (spanned > 0 || carry != Carry::None) {
            break;
        }

        if let Some((_, last, entries, sum)) = entry {
            count += entries;
            lnsum += sum;
            previous = last;
        }

        listed = element;
        width = width.max(size);
        stop = to + 1;
        offset = to + 1;

        if element && elements_of(line) > 1 && matches!(target, Target::Comment | Target::Key)
            || target == Target::Key && spanned < 0
            || target == Target::Comment && spanned != 0
        {
            break;
        }
    }

    (width, stop)
}

fn width_of(
    bytes: &[u8],
    start: u32,
    target: Target,
    line_width: u32,
    memo: &mut Memo,
) -> (u32, u32) {
    let (indent, tagged) = {
        let (from, to) = line_at(bytes, start);
        let held = &bytes[from as usize..to as usize];

        (indent_of(held), struct_tagged(held))
    };

    if target == Target::Element {
        return elements_run(bytes, start, indent, line_width, &mut memo.groups);
    }

    if let Target::Row(column) = target {
        return rows_run(bytes, start, indent, column);
    }

    if target == Target::Value {
        return values_run(bytes, start, indent, &mut memo.kept);
    }

    let filled = filled_at(bytes, start, indent, target, memo);
    let (width, stop) = run_of(bytes, start, indent, target, tagged, memo);

    (width.max(filled.saturating_sub(1)), stop)
}

#[must_use]
pub fn align(bytes: &[u8], target: Target, line_width: u32, out: &mut Buffer) -> bool {
    out.clear();

    let count = count_of(bytes.len());
    let mut carry = Carry::None;
    let mut memo = Memo::NONE;
    let mut offset = 0;

    while offset < count {
        let (from, to) = line_at(bytes, offset);
        let line = &bytes[from as usize..to as usize];
        let held = carry != Carry::None;

        let opened = cut_at(bytes, from, line, target, &mut memo)
            .filter(|_| !columnless(bytes, from, line, target, &mut memo.groups));

        let grouped =
            !held && opened.is_some() && opens_a_group(bytes, from, target, &mut memo.groups);

        let (width, stop) = if grouped {
            width_of(bytes, offset, target, line_width, &mut memo)
        } else {
            (0, 0)
        };

        let widened = opened.is_some_and(|found| width > columns_of(line, found.head));

        if !grouped || stop <= to + 1 && !widened || width > PADDING_MAX {
            carry = crosses(line, carry);

            if !out.push_bytes(&bytes[from as usize..(to + 1).min(count) as usize]) {
                return false;
            }

            offset = to + 1;

            continue;
        }

        let mut scan = offset;

        while scan < stop {
            let (start, end) = line_at(bytes, scan);
            let text = &bytes[start as usize..end as usize];
            let crossed = carry != Carry::None;

            carry = crosses(text, carry);

            match cut_at(bytes, start, text, target, &mut memo).filter(|_| !crossed) {
                Some(cut) => {
                    if !out.push_bytes(&text[..cut.head as usize]) {
                        return false;
                    }

                    let gap = (width + 1)
                        .saturating_sub(columns_of(text, cut.head))
                        .max(cut.tail - cut.head);

                    if !padded(out, gap) {
                        return false;
                    }

                    if !out.push_bytes(&text[cut.tail as usize..]) {
                        return false;
                    }
                }
                None => {
                    if !out.push_bytes(text) {
                        return false;
                    }
                }
            }

            if end < count && !out.push_bytes(b"\n") {
                return false;
            }

            scan = end + 1;
        }

        offset = stop;
    }

    true
}
