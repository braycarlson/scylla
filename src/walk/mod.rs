pub mod ignore;
#[cfg(unix)]
pub mod unix;
#[cfg(windows)]
pub mod windows;

use core::iter::from_fn;

use crate::bounded::{BoundedVec, Bytes as _, Span, count_of};
use crate::glob::Patterns;
use crate::path::{PATH_BYTES_MAX, SEPARATOR, trimmed};
use crate::walk::ignore::Ignores;
#[cfg(unix)]
pub use crate::walk::unix::{Directory, Listing};
#[cfg(windows)]
pub use crate::walk::windows::{Directory, Listing};

const DOTS: [&[u8]; 2] = [b".", b".."];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Outcome {
    Complete,
    TooDeep,
    Truncated,
    Unopenable,
    Unsupported,
}

#[expect(
    clippy::struct_field_names,
    reason = "each field is a bound, and `_max` is what every bound in this tree is named"
)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Bounds {
    pub arena_bytes_max: u32,
    pub depth_max: u32,
    pub entry_count_max: u32,
    pub pending_max: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Pending {
    depth: u32,
    path: Span,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Entry {
    pub path: Span,
}

pub struct Filter<'run> {
    pub excludes: Option<&'run Patterns>,
    pub ignores: Option<&'run mut Ignores>,
    pub skipped: &'run [&'run [u8]],
}

#[derive(Debug)]
pub struct Walk {
    arena: BoundedVec<u8>,
    depth_max: u32,
    entries: BoundedVec<Entry>,
    scratch: BoundedVec<u8>,
    stack: BoundedVec<Pending>,
}

impl Walk {
    pub fn clear(&mut self) {
        self.arena.clear();
        self.entries.clear();
        self.scratch.clear();
        self.stack.clear();

        assert!(self.is_empty());
    }

    pub fn count(&self) -> u32 {
        self.entries.count()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.count() == 0
    }

    pub fn path_of(&self, index: u32) -> Option<&[u8]> {
        let Ok(slot) = usize::try_from(index) else {
            return None;
        };

        let entry = self.entries.get(slot).copied()?;

        self.arena.get(entry.path.range())
    }

    pub fn paths(&self) -> impl Iterator<Item = &[u8]> {
        let mut index = 0_u32;

        from_fn(move || {
            if index >= self.entries.count() {
                return None;
            }

            let held = self.path_of(index);

            index = index.saturating_add(1);

            held
        })
    }

    fn read(&mut self, directory: Pending, filter: &mut Filter<'_>, opened: &mut bool) -> Outcome {
        if let Some(held) = filter.ignores.as_deref_mut()
            && let Some(path) = self.arena.get(directory.path.range())
            && !held.read(path)
        {
            return Outcome::Truncated;
        }

        if !terminated(&mut self.scratch, &self.arena, directory.path) {
            return Outcome::Truncated;
        }

        let Some(mut handle) = Directory::open(&self.scratch) else {
            return Outcome::Complete;
        };

        *opened = true;

        while let Some(listing) = handle.read() {
            let name = listing.name;

            if DOTS.contains(&name) || filter.skipped.contains(&name) || listing.is_link() {
                continue;
            }

            if !joined(&mut self.scratch, &self.arena, directory.path, name) {
                return Outcome::Truncated;
            }

            if filter
                .excludes
                .is_some_and(|patterns| patterns.matches(&self.scratch))
            {
                continue;
            }

            let descend = if listing.is_known() {
                listing.is_directory()
            } else {
                probe(&mut self.scratch)
            };

            if filter
                .ignores
                .as_deref_mut()
                .is_some_and(|held| held.covers(&self.scratch, descend))
            {
                continue;
            }

            let admitted = self.admitted(directory.depth, descend);

            if admitted != Outcome::Complete {
                return admitted;
            }
        }

        Outcome::Complete
    }

    fn admitted(&mut self, depth: u32, descend: bool) -> Outcome {
        let Some(span) = copied(&mut self.arena, &self.scratch) else {
            return Outcome::Truncated;
        };

        if !descend {
            if self.entries.push(Entry { path: span }) {
                return Outcome::Complete;
            }

            return Outcome::Truncated;
        }

        let deeper = depth.saturating_add(1);

        if deeper > self.depth_max {
            return Outcome::TooDeep;
        }

        if self.stack.push(Pending {
            depth: deeper,
            path: span,
        }) {
            return Outcome::Complete;
        }

        Outcome::Truncated
    }

    pub fn reserve(bounds: Bounds) -> Self {
        assert!(bounds.entry_count_max > 0);
        assert!(bounds.arena_bytes_max > 0);
        assert!(bounds.depth_max > 0);
        assert!(bounds.pending_max > 0);
        assert!(!crate::allocation::is_frozen());

        Self {
            arena: BoundedVec::reserve(bounds.arena_bytes_max),
            depth_max: bounds.depth_max,
            entries: BoundedVec::reserve(bounds.entry_count_max),
            scratch: BoundedVec::reserve(count_of(PATH_BYTES_MAX) + 1),
            stack: BoundedVec::reserve(bounds.pending_max),
        }
    }

    pub fn run(&mut self, root: &[u8], mut filter: Filter<'_>) -> Outcome {
        self.clear();

        let trimmed = trimmed(root);

        if trimmed.is_empty() {
            return Outcome::Unopenable;
        }

        let Some(span) = copied(&mut self.arena, trimmed) else {
            return Outcome::Truncated;
        };

        if !self.stack.push(Pending {
            depth: 0,
            path: span,
        }) {
            return Outcome::Truncated;
        }

        if let Some(held) = filter.ignores.as_deref_mut() {
            held.clear();

            if !held.read_parents(trimmed) {
                return Outcome::Truncated;
            }
        }

        let mut opened = false;

        while let Some(directory) = self.stack.pop() {
            let read = self.read(directory, &mut filter, &mut opened);

            if read != Outcome::Complete {
                return read;
            }
        }

        if opened {
            return Outcome::Complete;
        }

        Outcome::Unopenable
    }

    pub fn sort(&mut self) {
        let arena = &self.arena;

        self.entries.sort_unstable_by(|first, second| {
            let left = arena.get(first.path.range()).unwrap_or(b"");
            let right = arena.get(second.path.range()).unwrap_or(b"");

            left.cmp(right)
        });
    }
}

fn copied(arena: &mut BoundedVec<u8>, bytes: &[u8]) -> Option<Span> {
    let offset = arena.count();

    if !arena.push_bytes(bytes) {
        return None;
    }

    Some(Span {
        length: arena.count().saturating_sub(offset),
        offset,
    })
}

fn joined(scratch: &mut BoundedVec<u8>, arena: &BoundedVec<u8>, parent: Span, name: &[u8]) -> bool {
    scratch.clear();

    let Some(bytes) = arena.get(parent.range()) else {
        return false;
    };

    scratch.push_bytes(bytes) && scratch.push(SEPARATOR) && scratch.push_bytes(name)
}

fn probe(scratch: &mut BoundedVec<u8>) -> bool {
    let restore = scratch.count();

    if !scratch.push(0) {
        return false;
    }

    let held = Directory::open(scratch).is_some();

    scratch.truncate(restore);

    held
}

fn terminated(scratch: &mut BoundedVec<u8>, arena: &BoundedVec<u8>, directory: Span) -> bool {
    scratch.clear();

    let Some(bytes) = arena.get(directory.range()) else {
        return false;
    };

    scratch.push_bytes(bytes) && scratch.push(0)
}

#[cfg(test)]
mod tests {
    use core::fmt::Write as _;
    use std::fs::{File, create_dir_all, remove_dir_all};
    use std::path::{Path, PathBuf};

    use super::*;
    use crate::allocation;

    const BOUNDS: Bounds = Bounds {
        arena_bytes_max: 1 << 16,
        depth_max: 64,
        entry_count_max: 256,
        pending_max: 64,
    };

    const FILES: [&str; 8] = [
        "a.html",
        "b.py",
        "templates/page.html",
        "templates/admin/list.html",
        "static/app.js",
        "static/vendor/lib.js",
        ".git/config",
        ".hidden/keep.html",
    ];

    const SKIPPED: &[&[u8]] = &[b".git"];

    fn filter(excludes: Option<&Patterns>) -> Filter<'_> {
        Filter {
            excludes,
            ignores: None,
            skipped: SKIPPED,
        }
    }

    fn root_of(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!("scylla-walk-{name}-{}", std::process::id()));

        let _ = remove_dir_all(&root);

        create_dir_all(&root).expect("the directory is created");

        root
    }

    fn tree(name: &str) -> PathBuf {
        let root = root_of(name);

        for file in FILES {
            write(&root, file);
        }

        root
    }

    fn bytes_of(root: &Path) -> Vec<u8> {
        crate::path::bytes_of(root.as_os_str())
            .expect("a text path")
            .to_vec()
    }

    fn walked(root: &Path, excludes: Option<&Patterns>) -> (Outcome, Vec<String>) {
        let mut walk = Walk::reserve(BOUNDS);
        let held = bytes_of(root);
        let outcome = walk.run(&held, filter(excludes));

        walk.sort();

        let paths = walk
            .paths()
            .map(|path| {
                let text = String::from_utf8_lossy(path).into_owned();

                text.get(held.len() + 1..).unwrap_or(&text).to_owned()
            })
            .collect::<Vec<_>>();

        (outcome, paths)
    }

    fn write(root: &Path, name: &str) {
        let path = root.join(name);

        if let Some(parent) = path.parent() {
            create_dir_all(parent).expect("the parent directory is made");
        }

        File::create(&path).expect("the file is made");
    }

    #[test]
    fn every_file_under_the_root_is_found() {
        let root = tree("every-file");
        let (outcome, paths) = walked(&root, None);

        assert_eq!(outcome, Outcome::Complete);

        assert_eq!(
            paths,
            [
                ".hidden/keep.html",
                "a.html",
                "b.py",
                "static/app.js",
                "static/vendor/lib.js",
                "templates/admin/list.html",
                "templates/page.html",
            ]
        );

        let _ = remove_dir_all(&root);
    }

    #[test]
    fn a_skipped_directory_is_never_walked() {
        let root = tree("skipped");
        let (_, paths) = walked(&root, None);

        assert!(!paths.iter().any(|path| path.contains(".git")));

        let mut walk = Walk::reserve(BOUNDS);
        let held = bytes_of(&root);

        let filter = Filter {
            excludes: None,
            ignores: None,
            skipped: &[b".git", b"static"],
        };

        assert_eq!(walk.run(&held, filter), Outcome::Complete);
        assert!(!walk.paths().any(|path| path.ends_with(b"app.js")));
        assert!(walk.paths().any(|path| path.ends_with(b"a.html")));

        let _ = remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn a_symbolic_link_is_never_followed() {
        let root = tree("link");

        std::os::unix::fs::symlink(root.join("static"), root.join("linked")).expect("the link");
        std::os::unix::fs::symlink(root.join("a.html"), root.join("linked.html"))
            .expect("the link");

        let (outcome, paths) = walked(&root, None);

        assert_eq!(outcome, Outcome::Complete);
        assert!(!paths.iter().any(|path| path.starts_with("linked")));
        assert!(paths.iter().any(|path| path == "static/app.js"));

        let _ = remove_dir_all(&root);
    }

    #[test]
    fn a_directory_is_never_reported_as_a_file() {
        let root = tree("directory");
        let (_, paths) = walked(&root, None);

        assert!(!paths.iter().any(|path| path == "templates"));
        assert!(!paths.iter().any(|path| path == "static/vendor"));

        let _ = remove_dir_all(&root);
    }

    #[test]
    fn a_trailing_separator_on_the_root_changes_nothing() {
        let root = tree("trailing");
        let held = bytes_of(&root);
        let mut slashed = held.clone();

        slashed.extend_from_slice(b"///");

        let mut plain = Walk::reserve(BOUNDS);
        let mut trailed = Walk::reserve(BOUNDS);

        assert_eq!(plain.run(&held, filter(None)), Outcome::Complete);
        assert_eq!(trailed.run(&slashed, filter(None)), Outcome::Complete);
        assert_eq!(plain.count(), trailed.count());

        let _ = remove_dir_all(&root);
    }

    #[test]
    fn an_excluded_directory_is_not_descended_into() {
        let root = tree("excluded-directory");
        let mut excludes = Patterns::reserve(64, 1_024, 8);
        let mut pattern = bytes_of(&root);

        pattern.extend_from_slice(b"/static");

        excludes.push(&pattern).expect("the pattern compiles");

        let (outcome, paths) = walked(&root, Some(&excludes));

        assert_eq!(outcome, Outcome::Complete);
        assert!(!paths.iter().any(|path| path.starts_with("static")));
        assert!(paths.iter().any(|path| path == "templates/page.html"));

        let _ = remove_dir_all(&root);
    }

    #[test]
    fn an_excluded_file_is_left_out_while_its_neighbours_stay() {
        let root = tree("excluded-file");
        let mut excludes = Patterns::reserve(64, 1_024, 8);

        excludes.push(b"*.py").expect("the pattern compiles");

        let (outcome, paths) = walked(&root, Some(&excludes));

        assert_eq!(outcome, Outcome::Complete);
        assert!(!paths.iter().any(|path| path.contains(".py")));
        assert!(paths.iter().any(|path| path == "a.html"));

        let _ = remove_dir_all(&root);
    }

    #[test]
    fn a_root_that_names_nothing_says_so() {
        let mut walk = Walk::reserve(BOUNDS);

        assert_eq!(
            walk.run(b"/no/such/directory/anywhere", filter(None)),
            Outcome::Unopenable
        );

        assert_eq!(walk.run(b"", filter(None)), Outcome::Unopenable);
        assert!(walk.is_empty());
    }

    #[test]
    fn an_empty_directory_walks_to_nothing() {
        let root = root_of("empty");
        let (outcome, paths) = walked(&root, None);

        assert_eq!(outcome, Outcome::Complete);
        assert!(paths.is_empty());

        let _ = remove_dir_all(&root);
    }

    #[test]
    fn a_tree_deeper_than_the_stack_is_refused() {
        let root = root_of("deep");
        let mut name = String::new();

        for index in 0_u32..12_u32 {
            write!(&mut name, "d{index}/").expect("the name is built");
        }

        name.push_str("leaf.html");
        write(&root, &name);

        let mut walk = Walk::reserve(Bounds {
            depth_max: 2,
            ..BOUNDS
        });

        assert_eq!(walk.run(&bytes_of(&root), filter(None)), Outcome::TooDeep);

        let _ = remove_dir_all(&root);
    }

    #[test]
    fn a_walk_larger_than_the_entry_table_is_truncated() {
        let root = root_of("entries");

        for index in 0_u32..32_u32 {
            write(&root, &format!("file{index}.html"));
        }

        let mut walk = Walk::reserve(Bounds {
            entry_count_max: 4,
            ..BOUNDS
        });

        assert_eq!(walk.run(&bytes_of(&root), filter(None)), Outcome::Truncated);

        let _ = remove_dir_all(&root);
    }

    #[test]
    fn a_walk_that_outgrows_its_arena_is_truncated() {
        let root = tree("arena");

        let mut walk = Walk::reserve(Bounds {
            arena_bytes_max: 64,
            ..BOUNDS
        });

        assert_eq!(walk.run(&bytes_of(&root), filter(None)), Outcome::Truncated);

        let _ = remove_dir_all(&root);
    }

    #[test]
    fn a_second_run_forgets_the_first() {
        let root = tree("second");
        let held = bytes_of(&root);
        let mut walk = Walk::reserve(BOUNDS);

        assert_eq!(walk.run(&held, filter(None)), Outcome::Complete);

        let first = walk.count();

        assert_eq!(walk.run(&held, filter(None)), Outcome::Complete);
        assert_eq!(walk.count(), first);

        let _ = remove_dir_all(&root);
    }

    #[test]
    fn a_sorted_walk_reads_the_same_every_time() {
        let root = tree("sorted");
        let (_, first) = walked(&root, None);
        let (_, second) = walked(&root, None);

        assert_eq!(first, second);

        let _ = remove_dir_all(&root);
    }

    #[test]
    fn a_walk_allocates_nothing_once_its_tables_are_reserved() {
        let root = tree("frozen");
        let held = bytes_of(&root);
        let mut walk = Walk::reserve(BOUNDS);

        assert_eq!(walk.run(&held, filter(None)), Outcome::Complete);

        let expected = walk.count();

        allocation::frozen(|| {
            assert_eq!(walk.run(&held, filter(None)), Outcome::Complete);

            walk.sort();

            assert_eq!(walk.count(), expected);
        });

        let _ = remove_dir_all(&root);
    }
}
