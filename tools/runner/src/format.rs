use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use scylla::bounded::Buffer;
use scylla::format::brace::renumbered;
use scylla::format::print::Options;
use scylla::syntax::Structure;
use scylla::token::{Token, TokenKind, Tokens};
use scylla::tree::{Kind, Tree};

use crate::blob::blob_of;
use crate::oracle::Version;

const NUMBER_BYTES_MAX: u32 = 1 << 8;
const CACHE_COUNT_MAX: usize = 1 << 12;
const OUT_BYTES_MAX: u32 = 1 << 24;

pub struct Print<'run, K: Kind> {
    pub outcome: Structure,
    pub raw: &'run [K],
    pub source: &'run [u8],
    pub tokens: &'run [Token],
    pub tree: &'run Tree<K>,
}

pub trait Printer<K: Kind> {
    fn print(&mut self, held: &Print<'_, K>, out: &mut Buffer) -> bool;
}

pub trait Reference {
    fn identifier(&self) -> &'static str;
    fn print(&mut self, source: &[u8]) -> Option<Vec<u8>>;
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Shape {
    Stdout,
    InPlace,
    Stream,
}

pub struct Subprocess {
    arguments: Vec<String>,
    cache: HashMap<String, Option<Vec<u8>>>,
    extension: &'static str,
    identifier: &'static str,
    program: PathBuf,
    scratch: PathBuf,
    shape: Shape,
}

impl Subprocess {
    pub fn of(
        identifier: &'static str,
        program: PathBuf,
        arguments: &[&str],
        extension: &'static str,
        shape: Shape,
        version: &Version<'_>,
    ) -> Result<Self, String> {
        version.enforce(identifier)?;

        Ok(Self {
            arguments: arguments.iter().map(|held| (*held).to_owned()).collect(),
            cache: HashMap::new(),
            extension,
            identifier,
            program,
            scratch: std::env::temp_dir().join(format!("scylla-format-{identifier}")),
            shape,
        })
    }

    fn run(&self, source: &[u8]) -> Option<Vec<u8>> {
        if self.shape == Shape::Stream {
            return self.streamed(source);
        }

        let _ = std::fs::remove_dir_all(&self.scratch);

        std::fs::create_dir_all(&self.scratch).ok()?;

        let target = self.scratch.join(format!("input.{}", self.extension));

        std::fs::write(&target, source).ok()?;

        let outcome = Command::new(&self.program)
            .args(&self.arguments)
            .arg(&target)
            .output()
            .ok()?;

        if !outcome.status.success() {
            return None;
        }

        if self.shape == Shape::InPlace {
            return std::fs::read(&target).ok();
        }

        Some(outcome.stdout)
    }

    fn streamed(&self, source: &[u8]) -> Option<Vec<u8>> {
        use std::io::Write as _;

        let mut child = Command::new(&self.program)
            .args(&self.arguments)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .ok()?;

        let mut held = child.stdin.take()?;

        let outcome = std::thread::scope(|scope| {
            scope.spawn(move || held.write_all(source));

            child.wait_with_output().ok()
        })?;

        if !outcome.status.success() {
            return None;
        }

        Some(outcome.stdout)
    }
}

impl Reference for Subprocess {
    fn identifier(&self) -> &'static str {
        self.identifier
    }

    fn print(&mut self, source: &[u8]) -> Option<Vec<u8>> {
        let blob = blob_of(source);

        if let Some(held) = self.cache.get(&blob) {
            return held.clone();
        }

        let printed = self.run(source);

        if self.cache.len() >= CACHE_COUNT_MAX {
            self.cache.clear();
        }

        self.cache.insert(blob, printed.clone());

        printed
    }
}

pub fn buffer() -> Buffer {
    Buffer::reserve(OUT_BYTES_MAX)
}

pub fn parting(ours: &[u8], theirs: &[u8]) -> (u32, String, String) {
    let mut offset = 0;

    while offset < ours.len() && offset < theirs.len() && ours[offset] == theirs[offset] {
        offset += 1;
    }

    let held = u32::try_from(offset).unwrap_or(u32::MAX);

    (held, window(ours, offset), window(theirs, offset))
}

fn window(held: &[u8], offset: usize) -> String {
    let start = offset.saturating_sub(12);
    let end = (offset + 12).min(held.len());

    if start >= end {
        return String::new();
    }

    let mut out = String::new();
    let mut blank = false;

    for byte in &held[start..end] {
        if byte.is_ascii_whitespace() {
            blank = true;

            continue;
        }

        if blank && !out.is_empty() {
            out.push(' ');
        }

        blank = false;
        out.push(char::from(*byte));
    }

    out
}

fn named_key<'held>(held: &[Token], source: &'held [u8], index: usize) -> Option<&'held [u8]> {
    let text = held[index].text(source);
    let after = held.get(index + 1).map(|token| token.text(source));

    let keyed = after == Some(b":".as_slice())
        || after == Some(b"?".as_slice())
            && held.get(index + 2).map(|token| token.text(source)) == Some(b":".as_slice());

    if !keyed {
        return None;
    }

    let quote = *text.first()?;

    if quote != b'"' && quote != b'\'' || text.len() < 2 || *text.last()? != quote {
        return None;
    }

    let body = &text[1..text.len() - 1];
    let first = *body.first()?;

    if !first.is_ascii_alphabetic() && first != b'_' && first != b'$' {
        return None;
    }

    body.iter()
        .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'_' || *byte == b'$')
        .then_some(body)
}

pub fn words(
    lexer: &'static dyn scylla::language::Lexer,
    source: &[u8],
    regroups: bool,
    braces: bool,
    keys: bool,
    numbers: bool,
) -> Vec<String> {
    let mut held = Tokens::reserve(1 << 21);

    lexer.lex(source, &mut held);

    let carried: Vec<Token> = held
        .as_slice()
        .iter()
        .filter(|token| {
            !matches!(token.kind, TokenKind::Comment | TokenKind::Newline)
                && (braces || !matches!(token.kind, TokenKind::BlockEnd | TokenKind::BlockStart))
                && token.length > 0
        })
        .copied()
        .collect();

    let held: Vec<String> = carried
        .iter()
        .enumerate()
        .map(|(index, token)| {
            if numbers && token.kind == TokenKind::Number {
                let mut form = Buffer::reserve(NUMBER_BYTES_MAX);

                assert!(renumbered(&mut form, token.text(source)));

                return String::from_utf8_lossy(form.as_bytes()).into_owned();
            }

            if token.kind != TokenKind::String {
                return String::from_utf8_lossy(token.text(source)).into_owned();
            }

            match named_key(&carried, source, index).filter(|_| keys) {
                Some(body) => String::from_utf8_lossy(body).into_owned(),
                None => "<string>".to_owned(),
            }
        })
        .collect();

    if regroups {
        return ungrouped(held);
    }

    held
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Rewrites {
    pub arms: bool,
    pub blocks: bool,
    pub cases: bool,
    pub casts: bool,
    pub constructs: bool,
    pub commas: bool,
    pub counts: bool,
    pub folds: bool,
    pub keys: bool,
    pub members: bool,
    pub numbers: bool,
    pub orders: bool,
    pub groups: bool,
    pub grouped: bool,
    pub returns: bool,
    pub imports: bool,
    pub terminators: bool,
    pub unions: bool,
    pub joins: bool,
    pub parens: bool,
    pub quotes: bool,
    pub semicolons: bool,
    pub separators: bool,
    pub zeros: bool,
}

const CASTS: [&str; 4] = ["@alignCast", "@constCast", "@ptrCast", "@volatileCast"];

fn remarked_close(words: &[String], from: usize) -> bool {
    let mut at = from;

    while words
        .get(at)
        .is_some_and(|word| word.starts_with("//") || word.starts_with("/*"))
    {
        at += 1;
    }

    matches!(words.get(at).map(String::as_str), Some(")" | "]" | "}"))
}

fn casted(words: &[String]) -> Vec<String> {
    words
        .iter()
        .map(|word| {
            if CASTS.contains(&word.as_str()) {
                return "@cast".to_owned();
            }

            word.clone()
        })
        .collect()
}

pub fn preserved(before: &[String], after: &[String], rewrites: Rewrites) -> Option<usize> {
    if rewrites.casts {
        let held = Rewrites {
            casts: false,
            ..rewrites
        };

        return preserved(&casted(before), &casted(after), held);
    }

    if rewrites.returns {
        let held = Rewrites {
            returns: false,
            ..rewrites
        };

        return preserved(&wrapped(before), &wrapped(after), held);
    }

    if rewrites.imports {
        let held = Rewrites {
            imports: false,
            ..rewrites
        };

        return preserved(&imported(before), &imported(after), held);
    }

    if rewrites == Rewrites::default() {
        return before
            .iter()
            .zip(after.iter())
            .position(|(left, right)| left != right)
            .or_else(|| (before.len() != after.len()).then(|| before.len().min(after.len())));
    }

    let mut blocked: Vec<usize> = Vec::new();
    let mut bodies: Vec<usize> = Vec::new();
    let mut closes: Vec<usize> = Vec::new();
    let mut drops: Vec<usize> = Vec::new();
    let mut opens: Vec<usize> = Vec::new();
    let mut source = 0;
    let mut printed = 0;

    while printed < after.len() {
        if rewrites.grouped && drops.last() == Some(&source) {
            drops.pop();
            source += 1;

            continue;
        }

        if rewrites.grouped
            && before.get(source).is_some_and(|word| word == "(")
            && after[printed] != ";"
        {
            if let Some(close) = dropping(before, after, source, printed) {
                drops.push(close);
                source += 1;

                continue;
            }
        }

        if rewrites.groups && closes.last() == Some(&source) {
            closes.pop();
            source += 1;

            continue;
        }

        if rewrites.groups
            && before.get(source).is_some_and(|word| word == "(")
            && after[printed] != "("
        {
            if let Some(close) = closing(before, source) {
                closes.push(close);
                source += 1;

                continue;
            }
        }

        if rewrites.groups && opens.last() == Some(&printed) {
            opens.pop();
            printed += 1;

            continue;
        }

        if rewrites.groups
            && after[printed] == "("
            && before.get(source).map(String::as_str) != Some("(")
        {
            if let Some(close) = closing(after, printed) {
                opens.push(close);
                printed += 1;

                continue;
            }
        }

        if rewrites.constructs
            && after[printed] == "("
            && printed > 0
            && after[printed - 1] == "new"
            && after.get(printed + 1).map(String::as_str) == Some("class")
        {
            if let Some(close) = closing(after, printed) {
                opens.push(close);
                printed += 1;

                continue;
            }
        }

        if rewrites.constructs && opens.last() == Some(&printed) {
            opens.pop();
            printed += 1;

            continue;
        }

        if rewrites.constructs
            && after[printed] == "("
            && printed > 0
            && after[printed - 1] == "}"
            && after.get(printed + 1).map(String::as_str) == Some(")")
            && before.get(source).is_none_or(|word| word != "(")
        {
            printed += 2;

            continue;
        }

        if rewrites.orders
            && before.get(source).is_some_and(|word| word == "{")
            && after[printed] == "{"
            && matches!(
                before.get(source.wrapping_sub(1)).map(String::as_str),
                Some(":" | "use")
            )
        {
            if let Some((held, taken)) = reordered(before, after, source, printed) {
                source = held;
                printed = taken;

                continue;
            }
        }

        let (held, taken) = stepped(before, after, source, printed, rewrites);

        if taken > 0 {
            source += held;
            printed += taken;

            continue;
        }

        if rewrites.arms
            && before.get(source).is_some_and(|word| word == "{")
            && source > 0
            && matches!(before[source - 1].as_str(), "=>" | "|" | "||")
            && after[printed] != "{"
        {
            if let Some(close) = braced(before, source) {
                bodies.push(close);
                source += 1;

                continue;
            }
        }

        if rewrites.blocks
            && after[printed] == "{"
            && printed > 0
            && matches!(after[printed - 1].as_str(), "=>" | "|" | "||")
            && before.get(source).map(String::as_str) != Some("{")
        {
            if let Some(close) = braced(after, printed) {
                blocked.push(close);
                printed += 1;

                continue;
            }
        }

        if rewrites.blocks && blocked.last() == Some(&printed) {
            blocked.pop();
            printed += 1;

            continue;
        }

        if rewrites.arms && bodies.last() == Some(&source) {
            let arm = bodies.pop() == Some(source) && barred(before, source);

            source += 1;

            if !arm && after[printed] == "," && before.get(source).map(String::as_str) != Some(",")
            {
                printed += 1;
            }

            continue;
        }

        if rewrites.commas
            && before.get(source).is_some_and(|word| word == ",")
            && matches!(after[printed].as_str(), ")" | "]" | "}")
        {
            source += 1;

            continue;
        }

        if rewrites.commas && after[printed] == "," && remarked_close(after, printed + 1) {
            printed += 1;

            continue;
        }

        if rewrites.unions
            && after[printed] == "|"
            && before.get(source).map(String::as_str) != Some("|")
            && printed > 0
            && matches!(after[printed - 1].as_str(), "=" | ":")
        {
            printed += 1;

            continue;
        }

        if rewrites.terminators && after[printed] == ";" {
            printed += 1;

            continue;
        }

        if rewrites.semicolons && before.get(source).is_some_and(|word| word == ";") {
            source += 1;

            continue;
        }

        if rewrites.parens
            && after[printed] == "("
            && after.get(printed + 2).map(String::as_str) == Some(")")
            && after.get(printed + 3).map(String::as_str) == Some("=>")
            && before.get(source) == after.get(printed + 1)
            && before.get(source + 1).map(String::as_str) == Some("=>")
        {
            source += 2;
            printed += 4;

            continue;
        }

        if !rewrites.separators || after[printed] != ";" {
            return Some(printed);
        }

        printed += 1;
    }

    while rewrites.semicolons && before.get(source).is_some_and(|word| word == ";") {
        source += 1;
    }

    (source != before.len()).then_some(after.len())
}

fn dropping(before: &[String], after: &[String], source: usize, printed: usize) -> Option<usize> {
    let close = closing(before, source)?;

    if after.get(printed).map(String::as_str) != Some("(") {
        return Some(close);
    }

    let held = closing(after, printed)?;

    (spanned(before, source, close) != spanned(after, printed, held)).then_some(close)
}

fn spanned(words: &[String], open: usize, close: usize) -> usize {
    words[open + 1..close]
        .iter()
        .filter(|word| !matches!(word.as_str(), "(" | ")" | ";"))
        .count()
}

fn barred(words: &[String], close: usize) -> bool {
    let mut depth = 0_usize;
    let mut index = close;

    while index > 0 {
        match words[index].as_str() {
            ")" | "]" | "}" => depth += 1,
            "(" | "[" | "{" => {
                depth -= 1;

                if depth == 0 {
                    return index > 0 && matches!(words[index - 1].as_str(), "|" | "||");
                }
            }
            _ => (),
        }

        index -= 1;
    }

    false
}

fn braced(words: &[String], open: usize) -> Option<usize> {
    let mut depth = 0_usize;

    for (index, word) in words.iter().enumerate().skip(open) {
        match word.as_str() {
            "(" | "[" | "{" => depth += 1,
            ")" | "]" | "}" => {
                depth -= 1;

                if depth == 0 {
                    return (word == "}").then_some(index);
                }
            }
            _ => (),
        }
    }

    None
}

fn wrapped(words: &[String]) -> Vec<String> {
    let mut held: Vec<String> = Vec::with_capacity(words.len());
    let mut skips: Vec<usize> = Vec::new();
    let mut index = 0;

    while index < words.len() {
        if let Some(close) = returning(words, index) {
            held.push(words[index].clone());
            skips.push(close);
            index += 2;

            continue;
        }

        if skips.last() == Some(&index) {
            skips.pop();
            index += 1;

            continue;
        }

        held.push(words[index].clone());
        index += 1;
    }

    held
}

fn returning(words: &[String], index: usize) -> Option<usize> {
    if !matches!(words[index].as_str(), "return" | "throw") {
        return None;
    }

    if words.get(index + 1).map(String::as_str) != Some("(") {
        return None;
    }

    let close = closing(words, index + 1)?;

    let ends = words
        .get(close + 1)
        .is_none_or(|word| matches!(word.as_str(), ";" | "}"));

    ends.then_some(close)
}

fn closing(words: &[String], open: usize) -> Option<usize> {
    let mut depth = 0_usize;

    for (index, word) in words.iter().enumerate().skip(open) {
        match word.as_str() {
            "(" | "[" | "{" => depth += 1,
            ")" | "]" | "}" => {
                depth -= 1;

                if depth == 0 {
                    return (word == ")").then_some(index);
                }
            }
            _ => (),
        }
    }

    None
}

fn reordered(
    before: &[String],
    after: &[String],
    source: usize,
    printed: usize,
) -> Option<(usize, usize)> {
    let held = listing(before, source)?;
    let taken = listing(after, printed)?;

    let mut first: Vec<&str> = before[source + 1..held]
        .iter()
        .map(String::as_str)
        .collect();
    let mut second: Vec<&str> = after[printed + 1..taken]
        .iter()
        .map(String::as_str)
        .collect();

    first.sort_unstable();
    second.sort_unstable();

    (first == second).then_some((held + 1, taken + 1))
}

fn listing(words: &[String], open: usize) -> Option<usize> {
    let mut index = open + 1;

    while index < words.len() {
        if words[index] == "{" {
            return None;
        }

        if words[index] == "}" {
            return Some(index);
        }

        index += 1;
    }

    None
}

fn stepped(
    before: &[String],
    after: &[String],
    source: usize,
    printed: usize,
    rewrites: Rewrites,
) -> (usize, usize) {
    if rewrites.joins && after[printed] == "<string>" {
        let held = run_of(before, source);
        let taken = run_of(after, printed);

        if held >= taken && taken > 0 {
            return (held, taken);
        }
    }

    if source < before.len() && kept(&before[source], &after[printed], after, printed, rewrites) {
        return (1, 1);
    }

    if rewrites.counts && source < before.len() {
        if let Some(taken) = counted(&before[source], after, printed) {
            return (1, taken);
        }
    }

    if !rewrites.folds && !rewrites.zeros {
        return (0, 0);
    }

    if source + 1 < before.len() && before[source] == "." {
        let joined = format!(".{}", before[source + 1]);

        if kept(&joined, &after[printed], after, printed, rewrites) {
            return (2, 1);
        }
    }

    if printed + 1 < after.len() && source < before.len() {
        let joined = format!("{}{}", after[printed], after[printed + 1]);

        if kept(&before[source], &joined, after, printed, rewrites) {
            return (1, 2);
        }
    }

    (0, 0)
}

fn counted(word: &str, after: &[String], printed: usize) -> Option<usize> {
    let signed = word
        .as_bytes()
        .iter()
        .skip(1)
        .any(|byte| matches!(byte, b'+' | b'-'));

    if !signed {
        return None;
    }

    (2..=3).find(|taken| {
        printed + taken <= after.len()
            && after[printed..printed + taken]
                .concat()
                .eq_ignore_ascii_case(word)
    })
}

fn imported(words: &[String]) -> Vec<String> {
    let mut found = Vec::with_capacity(words.len());
    let mut index = 0;

    while index < words.len() {
        let mut run: Vec<Vec<String>> = Vec::new();
        let mut scan = index;

        while let Some(stop) = statement_end(words, scan) {
            if !heads(&words[scan]) || !opened_at(&words[scan..stop]) {
                break;
            }

            run.push(words[scan..stop].to_vec());
            scan = stop;
        }

        if run.len() < 2 {
            found.push(words[index].clone());
            index += 1;

            continue;
        }

        run.sort_by_cached_key(|statement| {
            let mut held: Vec<String> = statement
                .iter()
                .filter(|word| *word != ",")
                .cloned()
                .collect();

            held.sort();

            held
        });

        for statement in run {
            found.extend(statement);
        }

        index = scan;
    }

    found
}

fn heads(word: &str) -> bool {
    matches!(word, "#" | "pub" | "use")
}

fn nested(word: &str) -> i32 {
    match word {
        "{" | "[" | "(" => 1,
        "}" | "]" | ")" => -1,
        _ => 0,
    }
}

fn opened_at(words: &[String]) -> bool {
    let mut depth = 0;

    for word in words {
        if depth == 0 && word == "use" {
            return true;
        }

        depth += nested(word);
    }

    false
}

fn statement_end(words: &[String], from: usize) -> Option<usize> {
    let mut depth = 0;
    let mut index = from;

    while index < words.len() {
        depth += nested(&words[index]);

        if depth < 0 {
            return None;
        }

        if depth == 0 && words[index] == ";" {
            return Some(index + 1);
        }

        index += 1;
    }

    None
}

fn run_of(words: &[String], offset: usize) -> usize {
    let mut held = 0;

    while offset + held < words.len() && words[offset + held] == "<string>" {
        held += 1;
    }

    held
}

fn kept(source: &str, printed: &str, after: &[String], index: usize, rewrites: Rewrites) -> bool {
    if source == printed {
        return true;
    }

    if rewrites.cases && source.eq_ignore_ascii_case(printed) {
        return true;
    }

    if rewrites.members && source == "," && printed == ";" {
        return true;
    }

    if rewrites.folds || rewrites.zeros {
        let held = spelled(source, rewrites.folds);

        if held.eq_ignore_ascii_case(&spelled(printed, rewrites.folds)) {
            return true;
        }

        if matches!(source, "-" | "+") && printed.len() == 2 && printed.starts_with(source) {
            return printed.ends_with('0');
        }
    }

    rewrites.quotes
        && printed == "<string>"
        && index > 0
        && matches!(
            after[index - 1].as_str(),
            "*=" | "=" | "^=" | "|=" | "~=" | "$="
        )
}

fn spelled(word: &str, folds: bool) -> String {
    if let Some(rest) = word.strip_prefix('-') {
        return format!("-{}", spelled(rest, folds));
    }

    if let Some(rest) = word.strip_prefix('+') {
        return format!("+{}", spelled(rest, folds));
    }

    let Some((whole, rest)) = word.split_once('.') else {
        return word.to_owned();
    };

    if !whole.bytes().all(|byte| byte.is_ascii_digit()) {
        return word.to_owned();
    }

    let digits = rest.len()
        - rest
            .trim_start_matches(|held: char| held.is_ascii_digit())
            .len();
    let (fraction, unit) = rest.split_at(digits);
    let held = if folds {
        fraction.trim_end_matches('0')
    } else {
        fraction
    };

    let leading = if whole.is_empty() { "0" } else { whole };

    if held.is_empty() {
        return if folds {
            format!("{leading}{unit}")
        } else {
            format!("{leading}.0{unit}")
        };
    }

    format!("{leading}.{held}{unit}")
}

fn ungrouped(held: Vec<String>) -> Vec<String> {
    let mut found = Vec::with_capacity(held.len());

    for (index, word) in held.iter().enumerate() {
        let trailing = word == ","
            && held
                .get(index + 1)
                .is_some_and(|next| matches!(next.as_str(), ")" | "]" | "}"));

        if trailing || word == "(" || word == ")" {
            continue;
        }

        found.push(word.clone());
    }

    found
}

pub fn options_of(tabs: bool, indent_width: u32) -> Options {
    Options {
        indent_width,
        tabs,
        ..Options::DEFAULT
    }
}

pub fn width_of(line_width: u32) -> Options {
    Options {
        line_width,
        ..Options::DEFAULT
    }
}

pub fn program_of(named: &str, fallback: &Path) -> PathBuf {
    std::env::var_os(named).map_or_else(|| fallback.to_path_buf(), PathBuf::from)
}

#[cfg(test)]
mod tests {
    use super::{parting, words};

    #[test]
    fn two_printings_part_at_the_first_byte_that_differs() {
        let (offset, ours, theirs) = parting(b"var named[] string\n", b"var named []string\n");

        assert_eq!(offset, 9);
        assert_eq!(ours, "var named[] string");
        assert_eq!(theirs, "var named []string");
    }

    #[test]
    fn two_identical_printings_part_at_the_end() {
        let (offset, ours, theirs) = parting(b"held\n", b"held\n");

        assert_eq!(offset, 5);
        assert_eq!(ours, theirs);
    }

    #[test]
    fn a_split_word_reads_as_two() {
        let held = words(
            &scylla::lex::ZIG,
            b"var typed: anyframe->u32 = undefined;\n",
            false,
            false,
            false,
            false,
        );
        let split = words(
            &scylla::lex::ZIG,
            b"var typed: anyframe - > u32 = undefined;\n",
            false,
            false,
            false,
            false,
        );

        assert_ne!(held, split);
        assert!(held.contains(&"->".to_owned()));
        assert!(split.contains(&"-".to_owned()));
    }

    #[test]
    fn a_string_reads_as_a_string_whatever_its_bytes() {
        let single = words(
            &scylla::lex::PYTHON,
            b"held = 'one'\n",
            false,
            false,
            false,
            false,
        );
        let double = words(
            &scylla::lex::PYTHON,
            b"held = \"one\"\n",
            false,
            false,
            false,
            false,
        );

        assert_eq!(single, double);
        assert!(single.contains(&"<string>".to_owned()));
    }

    #[test]
    fn a_quoted_key_reads_as_the_name_it_holds() {
        let quoted = words(
            &scylla::lex::TYPESCRIPT,
            b"const held = { \"key\": 1, \"a-b\": 2 };\n",
            false,
            false,
            true,
            false,
        );

        let bare = words(
            &scylla::lex::TYPESCRIPT,
            b"const held = { key: 1, \"a-b\": 2 };\n",
            false,
            false,
            true,
            false,
        );

        assert_eq!(quoted, bare);
        assert!(quoted.contains(&"key".to_owned()));
        assert!(quoted.contains(&"<string>".to_owned()));
    }

    #[test]
    fn a_regrouping_formatter_drops_the_parentheses_from_the_comparison() {
        let bare = words(
            &scylla::lex::PYTHON,
            b"held = one + two\n",
            true,
            false,
            false,
            false,
        );
        let grouped = words(
            &scylla::lex::PYTHON,
            b"held = (one + two)\n",
            true,
            false,
            false,
            false,
        );

        assert_eq!(bare, grouped);
        assert_ne!(
            words(&scylla::lex::PYTHON, b"held = one + two\n", false, false, false, false),
            words(&scylla::lex::PYTHON, b"held = (one + two)\n", false, false, false, false)
        );
    }
}
