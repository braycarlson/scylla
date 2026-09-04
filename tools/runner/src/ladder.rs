use scylla::trivia::CONTINUATION_NONE;

use crate::analyzer::{self, Analyzer};
use crate::format::{parting, words, Reference};
use crate::normalize::Normalizer;
use crate::oracle;
use crate::signature::signature_of;

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum Level {
    Verdict,
    Tokens,
    Census,
    Tree,
    Bind,
    Format,
}

pub const EVERY_LEVEL: [Level; 6] = [
    Level::Verdict,
    Level::Tokens,
    Level::Census,
    Level::Tree,
    Level::Bind,
    Level::Format,
];

pub struct Divergence {
    pub level: Level,
    pub offset: u32,
    pub signature: String,
    pub summary: String,
}

impl Level {
    pub const fn name(self) -> &'static str {
        match self {
            Self::Bind => "bind",
            Self::Census => "census",
            Self::Format => "format",
            Self::Tokens => "tokens",
            Self::Tree => "tree",
            Self::Verdict => "verdict",
        }
    }

    pub fn of_name(name: &str) -> Option<Self> {
        EVERY_LEVEL.into_iter().find(|held| held.name() == name)
    }
}

pub struct Subject<'a> {
    pub continuation: u8,
    pub language: &'a str,
    pub normalizer: Option<&'a Normalizer>,
    pub oracle: &'a str,
}

pub fn compare(
    subject: &Subject<'_>,
    level: Level,
    source: &[u8],
    held: &analyzer::Read,
    theirs: &oracle::Read,
) -> Option<Divergence> {
    match level {
        Level::Verdict => verdict(subject, held, theirs),
        Level::Tokens => tokens(subject, source, held, theirs),
        Level::Census => census(subject, source, held, theirs),
        Level::Tree => tree(subject, source, held, theirs),
        Level::Bind | Level::Format => None,
    }
}

pub fn bound(
    language: &str,
    analyzer: &mut (dyn Analyzer + '_),
    source: &[u8],
) -> Option<Divergence> {
    let held = analyzer.bind(source)?;

    if held.complete {
        return None;
    }

    Some(Divergence {
        level: Level::Bind,
        offset: 0,
        signature: signature_of(&[Level::Bind.name(), language, held.limit]),
        summary: format!("the binder ran out of {}", held.limit),
    })
}

pub enum Formatted {
    Agreed,
    Diverged(Divergence),
    Ungraded,
}

pub fn formatted(
    language: &str,
    analyzer: &mut (dyn Analyzer + '_),
    reference: Option<&mut (dyn Reference + '_)>,
    regroups: bool,
    rewrites: crate::format::Rewrites,
    source: &[u8],
) -> Formatted {
    let Some(printed) = analyzer.print(source) else {
        return ungraded("the printer refused the file");
    };

    let lexer = analyzer.lexer();

    if let Some(again) = analyzer.print(&printed) {
        if again != printed {
            let (offset, ours, theirs) = parting(&printed, &again);

            return Formatted::Diverged(Divergence {
                level: Level::Format,
                offset,
                signature: signature_of(&[
                    Level::Format.name(),
                    language,
                    "idempotence",
                    &ours,
                    &theirs,
                ]),
                summary: format!("a second printing changed `{ours}` to `{theirs}` at {offset}"),
            });
        }
    }

    let braces = rewrites.commas;
    let before = words(
        lexer,
        source,
        regroups,
        braces,
        rewrites.keys,
        rewrites.numbers,
    );
    let after = words(
        lexer,
        &printed,
        regroups,
        braces,
        rewrites.keys,
        rewrites.numbers,
    );

    if let Some(offset) = crate::format::preserved(&before, &after, rewrites) {
        let ours = after.get(offset).map_or("", String::as_str).to_owned();
        let theirs = before.get(offset).map_or("", String::as_str).to_owned();

        return Formatted::Diverged(Divergence {
            level: Level::Format,
            offset: u32::try_from(offset).unwrap_or(u32::MAX),
            signature: signature_of(&[
                Level::Format.name(),
                language,
                "round-trip",
                &ours,
                &theirs,
            ]),
            summary: format!(
                "printing read word {offset} as `{ours}` where the source reads `{theirs}`"
            ),
        });
    }

    let Some(reference) = reference else {
        return ungraded("no reference is configured");
    };

    let identifier = reference.identifier();

    let Some(wanted) = reference.print(source) else {
        return ungraded("the reference refused the file");
    };

    if printed == wanted {
        return Formatted::Agreed;
    }

    let (offset, ours, theirs) = parting(&printed, &wanted);

    Formatted::Diverged(Divergence {
        level: Level::Format,
        offset,
        signature: signature_of(&[Level::Format.name(), language, identifier, &ours, &theirs]),
        summary: format!("scylla printed `{ours}` where {identifier} printed `{theirs}`"),
    })
}

fn ungraded(reason: &str) -> Formatted {
    if std::env::var_os("SCYLLA_UNGRADED").is_some() {
        eprintln!("ungraded: {reason}");
    }

    Formatted::Ungraded
}

fn verdict(
    subject: &Subject<'_>,
    held: &analyzer::Read,
    theirs: &oracle::Read,
) -> Option<Divergence> {
    let language = subject.language;
    let oracle_name = subject.oracle;

    if held.accepted == theirs.accepted {
        return None;
    }

    let direction = if held.accepted {
        "scylla-accepts"
    } else {
        "oracle-accepts"
    };

    Some(Divergence {
        level: Level::Verdict,
        offset: 0,
        signature: signature_of(&[
            Level::Verdict.name(),
            language,
            oracle_name,
            direction,
            held.outcome,
            held.error,
            &kind_at(&held.nodes, held.error_offset),
            &enclosing_of(&held.nodes, held.error_offset),
        ]),
        summary: format!(
            "scylla {} [{}] ({} in {}) and {oracle_name} {}",
            accepted_of(held.accepted),
            held.outcome,
            held.error,
            kind_at(&held.nodes, held.error_offset),
            accepted_of(theirs.accepted)
        ),
    })
}

fn tokens(
    subject: &Subject<'_>,
    source: &[u8],
    held: &analyzer::Read,
    theirs: &oracle::Read,
) -> Option<Divergence> {
    let language = subject.language;
    let oracle_name = subject.oracle;
    let mine = claimed(subject.continuation, source, &held.tokens);
    let ours = claimed(subject.continuation, source, &theirs.tokens);
    let offset = (0..source.len()).find(|offset| mine[*offset] != ours[*offset])?;
    let offset = offset as u32;

    let side = if mine[offset as usize] {
        "scylla-only"
    } else {
        "oracle-only"
    };

    Some(Divergence {
        level: Level::Tokens,
        offset,
        signature: signature_of(&[
            Level::Tokens.name(),
            language,
            oracle_name,
            side,
            &kind_at(&held.nodes, offset),
        ]),
        summary: format!("the non-blank byte at {offset} is {side}"),
    })
}

fn census(
    subject: &Subject<'_>,
    source: &[u8],
    held: &analyzer::Read,
    theirs: &oracle::Read,
) -> Option<Divergence> {
    let language = subject.language;
    let normalizer = subject.normalizer?;
    let oracle_name = subject.oracle;
    let length = source.len() as u32;
    let mine = counted(&normalizer.held(length, &held.nodes));
    let ours = counted(&normalizer.wanted(source, length, &theirs.nodes));

    let mut names: Vec<&str> = mine
        .iter()
        .chain(ours.iter())
        .map(|row| row.0.as_str())
        .collect();

    names.sort_unstable();
    names.dedup();

    for name in names {
        let first = count_of(&mine, name);
        let second = count_of(&ours, name);

        if first == second {
            continue;
        }

        let direction = if first > second {
            "scylla-more"
        } else {
            "oracle-more"
        };

        return Some(Divergence {
            level: Level::Census,
            offset: 0,
            signature: signature_of(&[
                Level::Census.name(),
                language,
                oracle_name,
                direction,
                name,
            ]),
            summary: format!("scylla counts {first} `{name}` and {oracle_name} counts {second}"),
        });
    }

    None
}

fn tree(
    subject: &Subject<'_>,
    source: &[u8],
    held: &analyzer::Read,
    theirs: &oracle::Read,
) -> Option<Divergence> {
    let language = subject.language;
    let normalizer = subject.normalizer?;
    let oracle_name = subject.oracle;
    let length = source.len() as u32;
    let mine = normalizer.held(length, &held.nodes);
    let ours = normalizer.wanted(source, length, &theirs.nodes);

    if mine == ours {
        return None;
    }

    let (side, row) = first_difference(&mine, &ours)?;

    Some(Divergence {
        level: Level::Tree,
        offset: row.1,
        signature: signature_of(&[
            Level::Tree.name(),
            language,
            oracle_name,
            side,
            &row.0,
            &parent_of(&mine, &row),
        ]),
        summary: format!("{side} `{}` at {}..{}", row.0, row.1, row.2),
    })
}

fn accepted_of(accepted: bool) -> &'static str {
    if accepted {
        "accepts"
    } else {
        "rejects"
    }
}

fn claimed(continuation: u8, source: &[u8], spans: &[(u32, u32)]) -> Vec<bool> {
    let mut found = vec![false; source.len()];

    for span in spans {
        let start = (span.0 as usize).min(source.len());
        let end = (span.1 as usize).min(source.len());

        for held in &mut found[start..end] {
            *held = true;
        }
    }

    for (held, byte) in found.iter_mut().zip(source.iter()) {
        if byte.is_ascii_whitespace()
            || (continuation != CONTINUATION_NONE && *byte == continuation)
        {
            *held = true;
        }
    }

    found
}

fn counted(rows: &[(String, u32, u32)]) -> Vec<(String, u32)> {
    let mut found: Vec<(String, u32)> = Vec::new();

    for row in rows {
        if let Some(held) = found.iter_mut().find(|entry| entry.0 == row.0) {
            held.1 += 1;

            continue;
        }

        found.push((row.0.clone(), 1));
    }

    found
}

fn count_of(rows: &[(String, u32)], name: &str) -> u32 {
    rows.iter().find(|row| row.0 == name).map_or(0, |row| row.1)
}

fn first_difference(
    mine: &[(String, u32, u32)],
    ours: &[(String, u32, u32)],
) -> Option<(&'static str, (String, u32, u32))> {
    let mut held = 0;
    let mut theirs = 0;

    while held < mine.len() || theirs < ours.len() {
        if theirs >= ours.len() {
            return Some(("scylla-only", mine[held].clone()));
        }

        if held >= mine.len() {
            return Some(("oracle-only", ours[theirs].clone()));
        }

        if mine[held] == ours[theirs] {
            held += 1;
            theirs += 1;

            continue;
        }

        if mine[held] < ours[theirs] {
            return Some(("scylla-only", mine[held].clone()));
        }

        return Some(("oracle-only", ours[theirs].clone()));
    }

    None
}

fn enclosing_of(nodes: &[(String, u32, u32)], offset: u32) -> String {
    let mut held: Vec<&(String, u32, u32)> = nodes
        .iter()
        .filter(|node| node.1 <= offset && offset < node.2)
        .collect();

    held.sort_by_key(|node| node.2 - node.1);

    held.get(1)
        .map_or_else(|| "none".to_owned(), |node| node.0.clone())
}

fn kind_at(nodes: &[(String, u32, u32)], offset: u32) -> String {
    nodes
        .iter()
        .filter(|node| node.1 <= offset && offset < node.2)
        .min_by_key(|node| node.2 - node.1)
        .map_or_else(|| "none".to_owned(), |node| node.0.clone())
}

fn parent_of(rows: &[(String, u32, u32)], row: &(String, u32, u32)) -> String {
    rows.iter()
        .filter(|held| held.1 <= row.1 && row.2 <= held.2 && *held != row)
        .min_by_key(|held| held.2 - held.1)
        .map_or_else(|| "none".to_owned(), |held| held.0.clone())
}
