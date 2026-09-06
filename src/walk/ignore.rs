use crate::bounded::{BoundedVec, Buffer, Bytes as _, Span};
use crate::glob::Patterns;
use crate::path::{PATH_BYTES_MAX, SEPARATOR, is_directory, join, open, trimmed};

const IGNORE_FILE: &[u8] = b".gitignore";
const GIT_DIRECTORY: &[u8] = b".git";
const ANCESTORS_MAX: u32 = 64;
const ROWS_PER_LINE: u32 = 4;
const TOKENS_PER_BYTE: u32 = 4;

#[expect(
    clippy::struct_field_names,
    reason = "each field is a bound, and `_max` is what every bound in this tree is named"
)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Bounds {
    pub arena_bytes_max: u32,
    pub file_count_max: u32,
    pub line_count_max: u32,
    pub text_bytes_max: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct File {
    base: Span,
    lead: Span,
    line_end: u32,
    line_first: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Line {
    anchored: bool,
    directory_only: bool,
    negated: bool,
    row_end: u32,
    row_first: u32,
}

#[derive(Debug)]
pub struct Ignores {
    arena: BoundedVec<u8>,
    files: BoundedVec<File>,
    lines: BoundedVec<Line>,
    patterns: Patterns,
    scratch: BoundedVec<u8>,
    text: Buffer,
}

impl Ignores {
    pub fn clear(&mut self) {
        self.arena.clear();
        self.files.clear();
        self.lines.clear();
        self.patterns.clear();
    }

    pub fn count(&self) -> u32 {
        self.files.count()
    }

    pub fn covers(&mut self, path: &[u8], directory: bool) -> bool {
        let mut decided = false;

        for file in self.files.iter() {
            let base = self.arena.get(file.base.range()).unwrap_or(&[]);
            let lead = self.arena.get(file.lead.range()).unwrap_or(&[]);

            let Some(relative) = relative_to(base, path) else {
                continue;
            };

            if relative.is_empty() {
                continue;
            }

            let lines = self
                .lines
                .get(
                    usize::try_from(file.line_first).unwrap_or(usize::MAX)
                        ..usize::try_from(file.line_end).unwrap_or(0),
                )
                .unwrap_or(&[]);

            for line in lines {
                if line.directory_only && !directory {
                    continue;
                }

                if !subject_written(&mut self.scratch, line.anchored, lead, relative) {
                    continue;
                }

                if self
                    .patterns
                    .matches_within(line.row_first, line.row_end, &self.scratch)
                {
                    decided = !line.negated;
                }
            }
        }

        decided
    }

    pub fn read(&mut self, directory: &[u8]) -> bool {
        self.read_as(directory, directory, &[])
    }

    fn read_as(&mut self, directory: &[u8], base: &[u8], lead: &[u8]) -> bool {
        let mut path = [0_u8; PATH_BYTES_MAX];

        let Some(length) = join(&mut path, directory, IGNORE_FILE) else {
            return true;
        };

        let Some(mut file) = open(path.get(..length).unwrap_or(&[])) else {
            return true;
        };

        self.text.clear();

        if !matches!(self.text.read_from(&mut file), Ok(true)) {
            return false;
        }

        let line_first = self.lines.count();

        let Self {
            lines,
            patterns,
            text,
            ..
        } = self;

        for line in text.as_bytes().split(|byte| *byte == b'\n') {
            let Some(held) = compiled(patterns, line) else {
                continue;
            };

            if !lines.push(held) {
                return false;
            }
        }

        let line_end = self.lines.count();

        if line_first == line_end {
            return true;
        }

        let Some(base_span) = interned(&mut self.arena, base) else {
            return false;
        };

        let Some(lead_span) = interned(&mut self.arena, lead) else {
            return false;
        };

        self.files.push(File {
            base: base_span,
            lead: lead_span,
            line_end,
            line_first,
        })
    }

    pub fn read_parents(&mut self, root: &[u8]) -> bool {
        let trimmed = trimmed(root);

        if holds_git(trimmed) {
            return true;
        }

        let mut top = trimmed.len();
        let mut ancestors = 0_u32;
        let mut cut = trimmed.len();
        let mut topped = false;

        while ancestors < ANCESTORS_MAX {
            ancestors = ancestors.saturating_add(1);

            let Some(parent) = parent_end(trimmed, cut) else {
                break;
            };

            let directory = trimmed.get(..parent).unwrap_or(&[]);

            top = parent;

            if holds_git(directory) {
                topped = true;

                break;
            }

            cut = parent;
        }

        if !topped {
            return true;
        }

        let mut end = top;

        while end < trimmed.len() {
            let directory = trimmed.get(..end).unwrap_or(&[]);
            let lead = trimmed.get(end.saturating_add(1)..).unwrap_or(&[]);

            if !self.read_as(directory_or_root(directory), trimmed, lead) {
                return false;
            }

            let Some(next) = child_end(trimmed, end) else {
                break;
            };

            end = next;
        }

        true
    }

    pub fn reserve(bounds: Bounds) -> Self {
        assert!(bounds.arena_bytes_max > 0);
        assert!(bounds.file_count_max > 0);
        assert!(bounds.line_count_max > 0);
        assert!(bounds.text_bytes_max > 0);
        assert!(!crate::allocation::is_frozen());

        Self {
            arena: BoundedVec::reserve(bounds.arena_bytes_max),
            files: BoundedVec::reserve(bounds.file_count_max),
            lines: BoundedVec::reserve(bounds.line_count_max),
            patterns: Patterns::reserve(
                bounds.line_count_max.saturating_mul(ROWS_PER_LINE),
                bounds.text_bytes_max.saturating_mul(TOKENS_PER_BYTE),
                bounds.line_count_max,
            ),
            scratch: BoundedVec::reserve(u32::try_from(PATH_BYTES_MAX).unwrap_or(u32::MAX)),
            text: Buffer::reserve(bounds.text_bytes_max),
        }
    }
}

fn compiled(patterns: &mut Patterns, line: &[u8]) -> Option<Line> {
    let mut pattern = line.trim_ascii();

    if pattern.is_empty() || pattern.first() == Some(&b'#') {
        return None;
    }

    let negated = pattern.first() == Some(&b'!');

    if negated {
        pattern = pattern.get(1..).unwrap_or(&[]);
    }

    let directory_only = pattern.last() == Some(&SEPARATOR);

    if directory_only {
        pattern = pattern
            .get(..pattern.len().saturating_sub(1))
            .unwrap_or(&[]);
    }

    let leading = pattern.first() == Some(&SEPARATOR);

    if leading {
        pattern = pattern.get(1..).unwrap_or(&[]);
    }

    if pattern.is_empty() {
        return None;
    }

    let anchored = leading || pattern.contains(&SEPARATOR);
    let row_first = patterns.count();

    let compiled = if anchored {
        patterns.push_anchored(pattern)
    } else {
        patterns.push(pattern)
    };

    if compiled.is_err() {
        patterns.truncate(row_first);

        return None;
    }

    Some(Line {
        anchored,
        directory_only,
        negated,
        row_end: patterns.count(),
        row_first,
    })
}

fn child_end(path: &[u8], end: usize) -> Option<usize> {
    let rest = path.get(end.saturating_add(1)..)?;

    let next = rest
        .iter()
        .position(|byte| *byte == SEPARATOR)
        .map_or(path.len(), |at| end.saturating_add(1).saturating_add(at));

    if next >= path.len() {
        return None;
    }

    Some(next)
}

const fn directory_or_root(directory: &[u8]) -> &[u8] {
    if directory.is_empty() {
        return b"/";
    }

    directory
}

fn holds_git(directory: &[u8]) -> bool {
    let mut path = [0_u8; PATH_BYTES_MAX];

    let Some(length) = join(&mut path, directory_or_root(directory), GIT_DIRECTORY) else {
        return false;
    };

    let held = path.get(..length).unwrap_or(&[]);

    is_directory(held) || open(held).is_some()
}

fn interned(arena: &mut BoundedVec<u8>, bytes: &[u8]) -> Option<Span> {
    let offset = arena.count();

    if !arena.push_bytes(bytes) {
        return None;
    }

    Some(Span {
        length: arena.count().saturating_sub(offset),
        offset,
    })
}

fn parent_end(path: &[u8], cut: usize) -> Option<usize> {
    let held = path.get(..cut)?;

    held.iter().rposition(|byte| *byte == SEPARATOR)
}

fn relative_to<'path>(directory: &[u8], path: &'path [u8]) -> Option<&'path [u8]> {
    if directory == b"/" {
        return path.strip_prefix(b"/");
    }

    let rest = path.strip_prefix(directory)?;

    if rest.is_empty() {
        return Some(rest);
    }

    if rest.first() == Some(&SEPARATOR) {
        return rest.get(1..);
    }

    None
}

fn subject_written(
    scratch: &mut BoundedVec<u8>,
    anchored: bool,
    lead: &[u8],
    relative: &[u8],
) -> bool {
    scratch.clear();

    if !anchored {
        let name = relative
            .iter()
            .rposition(|byte| *byte == SEPARATOR)
            .map_or(relative, |at| {
                relative.get(at.saturating_add(1)..).unwrap_or(relative)
            });

        return scratch.push_bytes(name);
    }

    if !lead.is_empty() && (!scratch.push_bytes(lead) || !scratch.push(SEPARATOR)) {
        return false;
    }

    scratch.push_bytes(relative)
}

#[cfg(test)]
mod tests {
    use std::fs::{create_dir_all, remove_dir_all, write};
    use std::path::{Path, PathBuf};

    use super::*;
    use crate::allocation;
    use crate::walk::{Bounds as WalkBounds, Filter, Outcome, Walk};

    const BOUNDS: WalkBounds = WalkBounds {
        arena_bytes_max: 1 << 16,
        depth_max: 64,
        entry_count_max: 256,
        pending_max: 64,
    };

    const IGNORE_BOUNDS: Bounds = Bounds {
        arena_bytes_max: 1 << 12,
        file_count_max: 16,
        line_count_max: 64,
        text_bytes_max: 1 << 12,
    };

    fn tree(name: &str, files: &[(&str, &str)]) -> PathBuf {
        let root =
            std::env::temp_dir().join(format!("scylla-ignore-{name}-{}", std::process::id()));

        let _ = remove_dir_all(&root);

        create_dir_all(&root).expect("the directory is created");

        for (relative, text) in files {
            let path = root.join(relative);

            if let Some(parent) = path.parent() {
                create_dir_all(parent).expect("the directory is created");
            }

            write(path, text).expect("the file is written");
        }

        root
    }

    fn bytes_of(root: &Path) -> Vec<u8> {
        crate::path::bytes_of(root.as_os_str())
            .expect("a text path")
            .to_vec()
    }

    fn walked(root: &Path) -> Vec<String> {
        let mut walk = Walk::reserve(BOUNDS);
        let mut ignores = Ignores::reserve(IGNORE_BOUNDS);
        let held = bytes_of(root);

        let outcome = allocation::frozen(|| {
            walk.run(
                &held,
                Filter {
                    excludes: None,
                    ignores: Some(&mut ignores),
                    skipped: &[b".git"],
                },
            )
        });

        assert_eq!(outcome, Outcome::Complete);

        walk.sort();

        walk.paths()
            .map(|path| {
                String::from_utf8_lossy(path)
                    .get(held.len() + 1..)
                    .unwrap_or_default()
                    .to_owned()
            })
            .collect()
    }

    #[test]
    fn a_bare_name_is_ignored_at_any_depth() {
        let root = tree(
            "bare",
            &[
                (".gitignore", "notes.txt\n"),
                ("notes.txt", ""),
                ("deep/notes.txt", ""),
                ("deep/page.html", ""),
            ],
        );

        assert_eq!(walked(&root), [".gitignore", "deep/page.html"]);

        let _ = remove_dir_all(&root);
    }

    #[test]
    fn a_trailing_slash_names_a_directory_and_takes_everything_under_it() {
        let root = tree(
            "trailing",
            &[
                (".gitignore", "build/\n"),
                ("build", ""),
                ("build.html", ""),
                ("out/build/page.html", ""),
                ("templates/page.html", ""),
            ],
        );

        assert_eq!(
            walked(&root),
            [".gitignore", "build", "build.html", "templates/page.html"],
        );

        let _ = remove_dir_all(&root);
    }

    #[test]
    fn a_slash_anchors_a_pattern_to_its_own_directory() {
        let root = tree(
            "anchored",
            &[
                (".gitignore", "/vendor/*.html\n"),
                ("vendor/widget.html", ""),
                ("nested/vendor/widget.html", ""),
            ],
        );

        assert_eq!(walked(&root), [".gitignore", "nested/vendor/widget.html"]);

        let _ = remove_dir_all(&root);
    }

    #[test]
    fn a_leading_slash_anchors_a_bare_name_to_its_own_directory() {
        let root = tree(
            "leading",
            &[
                (".gitignore", "/vendor\n"),
                ("vendor/widget.html", ""),
                ("nested/vendor/widget.html", ""),
            ],
        );

        assert_eq!(walked(&root), [".gitignore", "nested/vendor/widget.html"]);

        let _ = remove_dir_all(&root);
    }

    #[test]
    fn a_negation_takes_an_earlier_match_back() {
        let root = tree(
            "negation",
            &[
                (".gitignore", "*.html\n!keep.html\n"),
                ("keep.html", ""),
                ("page.html", ""),
            ],
        );

        assert_eq!(walked(&root), [".gitignore", "keep.html"]);

        let _ = remove_dir_all(&root);
    }

    #[test]
    fn a_file_under_an_ignored_directory_cannot_be_re_included() {
        let root = tree(
            "reincluded",
            &[
                (".gitignore", "build/\n!build/keep.html\n"),
                ("build/keep.html", ""),
                ("page.html", ""),
            ],
        );

        assert_eq!(walked(&root), [".gitignore", "page.html"]);

        let _ = remove_dir_all(&root);
    }

    #[test]
    fn a_nested_file_governs_its_own_directory_and_wins_over_the_root() {
        let root = tree(
            "nested",
            &[
                (".gitignore", "*.log\n"),
                ("app/.gitignore", "!debug.log\ncache/\n"),
                ("app/debug.log", ""),
                ("app/cache/page.html", ""),
                ("app/page.html", ""),
                ("root.log", ""),
            ],
        );

        assert_eq!(
            walked(&root),
            [
                ".gitignore",
                "app/.gitignore",
                "app/debug.log",
                "app/page.html"
            ],
        );

        let _ = remove_dir_all(&root);
    }

    #[test]
    fn a_file_above_the_root_governs_the_root_by_its_own_spelling() {
        let root = tree(
            "above",
            &[
                (".git/HEAD", "ref: refs/heads/main\n"),
                (".gitignore", "/project/build/\n*.tmp\n"),
                ("project/build/page.html", ""),
                ("project/page.html", ""),
                ("project/scratch.tmp", ""),
            ],
        );

        assert_eq!(walked(&root.join("project")), ["page.html"]);

        let _ = remove_dir_all(&root);
    }

    #[test]
    fn comments_and_blank_lines_are_not_patterns() {
        let root = tree(
            "comments",
            &[(".gitignore", "# nothing here\n\n   \n"), ("page.html", "")],
        );

        assert_eq!(walked(&root), [".gitignore", "page.html"]);

        let _ = remove_dir_all(&root);
    }

    #[test]
    fn the_tables_are_cleared_between_walks() {
        let first = tree(
            "cleared-first",
            &[(".gitignore", "*.html\n"), ("page.html", "")],
        );
        let second = tree("cleared-second", &[("page.html", "")]);
        let mut walk = Walk::reserve(BOUNDS);
        let mut ignores = Ignores::reserve(IGNORE_BOUNDS);

        let _first = walk.run(
            &bytes_of(&first),
            Filter {
                excludes: None,
                ignores: Some(&mut ignores),
                skipped: &[],
            },
        );

        assert_eq!(ignores.count(), 1);

        let _second = walk.run(
            &bytes_of(&second),
            Filter {
                excludes: None,
                ignores: Some(&mut ignores),
                skipped: &[],
            },
        );

        assert_eq!(ignores.count(), 0);
        assert_eq!(walk.count(), 1);

        let _ = remove_dir_all(&first);
        let _ = remove_dir_all(&second);
    }
}
