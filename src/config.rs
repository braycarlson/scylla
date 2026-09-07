use core::fmt::Write as _;
use std::env::var_os;

use crate::bounded::{Arena, BoundedString, BoundedVec, Buffer, Bytes, Span, count_of};
use crate::json::Pen;
use crate::path::{bytes_of, directory_of, is_file, is_separator, join, open, trimmed};
use crate::toml::{Reader, Value};

pub const DIRECTORY_DEPTH_MAX: u32 = 64;
pub const EXTEND_KEY: &[u8] = b"extend";
pub const NAME_BYTES_MAX: usize = 64;
const SCHEMA_URI: &[u8] = b"https://json-schema.org/draft/2020-12/schema";

#[expect(
    clippy::struct_field_names,
    reason = "the `_max` postfix is the big-endian convention naming the bound each field carries"
)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Limits {
    pub config_bytes_max: u32,
    pub extend_depth_max: u32,
    pub path_bytes_max: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Names {
    pub file_names: &'static [&'static [u8]],
    pub section_file_name: &'static [u8],
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Kind {
    Boolean,
    Integer,
    Map,
    Strings,
    Text,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Metadata {
    pub default: &'static str,
    pub description: &'static str,
    pub example: &'static str,
    pub kind: Kind,
    pub name: &'static str,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Extend {
    Faulted,
    None,
    Target(usize),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Outcome<F = ()> {
    Cycle,
    Faulted(F),
    Malformed,
    Missing,
    Oversized,
    Read,
    TooDeep,
    Unreadable,
}

#[derive(Debug)]
pub struct Resolver {
    buffer: Buffer,
    chain: BoundedVec<Span>,
    directory: BoundedVec<u8>,
    name: usize,
    names: Names,
    paths: Arena,
    relative: Vec<u8>,
    steps: u32,
    target: Vec<u8>,
}

impl Kind {
    pub const fn schema(self) -> &'static [u8] {
        match self {
            Self::Boolean => b"boolean",
            Self::Integer => b"integer",
            Self::Map => b"object",
            Self::Strings => b"array",
            Self::Text => b"string",
        }
    }
}

impl Metadata {
    fn default_write<W>(&self, pen: &mut Pen<'_, W>)
    where
        W: Bytes,
    {
        match self.kind {
            Kind::Boolean | Kind::Integer => pen.raw(self.default.as_bytes()),
            Kind::Map | Kind::Strings | Kind::Text => pen.string(self.default.as_bytes()),
        }
    }

    fn property_write<W>(&self, pen: &mut Pen<'_, W>, name: &[u8])
    where
        W: Bytes,
    {
        pen.key(name);
        pen.object_open();
        pen.key(b"type");
        pen.string(self.kind.schema());
        pen.key(b"description");
        pen.string(self.description.as_bytes());

        if !self.default.is_empty() {
            pen.key(b"default");
            self.default_write(pen);
        }

        pen.object_close();
    }
}

impl Names {
    pub fn needs_section(&self, path: &[u8]) -> bool {
        if self.section_file_name.is_empty() || !path.ends_with(self.section_file_name) {
            return false;
        }

        let at = path.len() - self.section_file_name.len();

        at == 0 || is_separator(path[at - 1])
    }
}

impl Resolver {
    pub fn reserve(limits: &Limits, names: Names) -> Self {
        assert!(limits.config_bytes_max > 0);
        assert!(limits.extend_depth_max > 0);
        assert!(limits.path_bytes_max > 0);
        assert!(!names.file_names.is_empty());
        assert!(!crate::allocation::is_frozen());

        Self {
            buffer: Buffer::reserve(limits.config_bytes_max),
            chain: BoundedVec::reserve(limits.extend_depth_max),
            directory: BoundedVec::reserve(limits.path_bytes_max),
            name: 0,
            names,
            paths: Arena::reserve(limits.path_bytes_max * limits.extend_depth_max * 2),
            relative: vec![0; limits.path_bytes_max as usize],
            steps: DIRECTORY_DEPTH_MAX,
            target: vec![0; limits.path_bytes_max as usize],
        }
    }

    pub fn clear(&mut self) {
        self.chain.clear();
        self.paths.reset();
        self.steps = DIRECTORY_DEPTH_MAX;
    }

    pub fn chain_at(&self, index: u32) -> &[u8] {
        assert!(index < self.chain_count());

        self.paths.bytes_of(self.chain[index as usize])
    }

    pub fn chain_count(&self) -> u32 {
        self.chain.count()
    }

    pub fn found(&self) -> Option<&[u8]> {
        self.chain.first().map(|span| self.paths.bytes_of(*span))
    }

    pub const fn names(&self) -> &Names {
        &self.names
    }

    pub fn path_of(&self, span: Span) -> &[u8] {
        self.paths.bytes_of(span)
    }

    pub fn record(&mut self, path: &[u8]) -> Option<Span> {
        if path.is_empty() || path.len() > self.relative.len() {
            return None;
        }

        self.paths.intern(path)
    }

    pub fn discover(&mut self, start: &[u8], rooted: bool) -> Option<Span> {
        let directory = if rooted { start } else { directory_of(start) };

        self.discover_start(directory);

        self.discover_next()
    }

    pub fn discover_start(&mut self, directory: &[u8]) {
        self.directory.clear();
        self.name = 0;
        self.steps = 0;

        let root = if directory.is_empty() {
            b".".as_slice()
        } else {
            trimmed(directory)
        };

        if !self.directory.push_bytes(root) {
            self.directory.clear();
            self.steps = DIRECTORY_DEPTH_MAX;
        }
    }

    pub fn discover_next(&mut self) -> Option<Span> {
        while self.steps < DIRECTORY_DEPTH_MAX {
            while self.name < self.names.file_names.len() {
                let name = self.names.file_names[self.name];

                self.name += 1;

                let Some(length) = join(&mut self.target, &self.directory, name) else {
                    continue;
                };

                if !is_file(&self.target[..length]) {
                    continue;
                }

                return self.paths.intern(&self.target[..length]);
            }

            let parent = count_of(directory_of(&self.directory).len());

            if parent >= self.directory.count() {
                self.steps = DIRECTORY_DEPTH_MAX;

                return None;
            }

            self.directory.truncate(parent);
            self.name = 0;
            self.steps += 1;
        }

        None
    }

    pub fn load<E, A, F>(&mut self, path: Span, extend_of: E, mut apply: A) -> Outcome<F>
    where
        E: Fn(&[u8], &[u8], &mut [u8]) -> Extend,
        A: FnMut(&[u8], &[u8]) -> Outcome<F>,
    {
        let chained = self.chain_collect(path, &extend_of);

        if !matches!(chained, Outcome::Read) {
            return chained;
        }

        let mut index = self.chain.count();
        let mut read_any = false;

        while index > 0 {
            index -= 1;

            let held = self.chain[index as usize];
            let read = self.read(held);

            if !matches!(read, Outcome::Read) {
                return read;
            }

            match apply(self.paths.bytes_of(held), self.buffer.as_bytes()) {
                Outcome::Read => read_any = true,
                Outcome::Missing if index == 0 && !read_any => return Outcome::Missing,
                Outcome::Missing => {}
                faulted => return faulted,
            }
        }

        Outcome::Read
    }

    fn chain_collect<E, F>(&mut self, path: Span, extend_of: &E) -> Outcome<F>
    where
        E: Fn(&[u8], &[u8], &mut [u8]) -> Extend,
    {
        self.chain.clear();
        self.chain.push_assert(path);

        let mut index = 0_u32;

        while index < self.chain.count() {
            let current = self.chain[index as usize];

            index += 1;

            let target = match self.extend_of(current, extend_of) {
                Ok(Some(target)) => target,
                Ok(None) => return Outcome::Read,
                Err(outcome) => return outcome,
            };

            let seen = self
                .chain
                .iter()
                .any(|held| self.paths.bytes_of(*held) == self.paths.bytes_of(target));

            if seen {
                return Outcome::Cycle;
            }

            if !self.chain.push(target) {
                return Outcome::TooDeep;
            }
        }

        Outcome::Read
    }

    fn extend_of<E, F>(&mut self, path: Span, extend_of: &E) -> Result<Option<Span>, Outcome<F>>
    where
        E: Fn(&[u8], &[u8], &mut [u8]) -> Extend,
    {
        let read = self.read(path);

        if !matches!(read, Outcome::Read) {
            return Err(read);
        }

        let length = match extend_of(
            self.paths.bytes_of(path),
            self.buffer.as_bytes(),
            &mut self.relative,
        ) {
            Extend::Faulted => return Err(Outcome::Malformed),
            Extend::None => return Ok(None),
            Extend::Target(length) => length,
        };

        if length == 0 || length > self.relative.len() {
            return Err(Outcome::Oversized);
        }

        let base = directory_of(self.paths.bytes_of(path));

        let Some(joined) = join(&mut self.target, base, &self.relative[..length]) else {
            return Err(Outcome::Oversized);
        };

        self.paths
            .intern(&self.target[..joined])
            .map_or(Err(Outcome::Oversized), |span| Ok(Some(span)))
    }

    fn read<F>(&mut self, path: Span) -> Outcome<F> {
        self.buffer.clear();

        let Some(mut file) = open(self.paths.bytes_of(path)) else {
            return Outcome::Unreadable;
        };

        match self.buffer.read_from(&mut file) {
            Ok(true) => Outcome::Read,
            Ok(false) => Outcome::Oversized,
            Err(_) => Outcome::Unreadable,
        }
    }
}

pub fn documentation_write(out: &mut BoundedString, options: &[Metadata]) -> bool {
    let mut fits = writeln!(out, "# Settings").is_ok();

    fits &= writeln!(out).is_ok();
    fits &= writeln!(
        out,
        "Every key is accepted in `snake_case` and `kebab-case`."
    )
    .is_ok();
    fits &= writeln!(out).is_ok();

    for option in options {
        fits &= writeln!(out, "## `{}`", option.name).is_ok();
        fits &= writeln!(out).is_ok();
        fits &= writeln!(out, "{}", option.description).is_ok();
        fits &= writeln!(out).is_ok();

        if !option.default.is_empty() {
            fits &= writeln!(out, "Default: `{}`", option.default).is_ok();
            fits &= writeln!(out).is_ok();
        }

        fits &= writeln!(out, "```toml").is_ok();
        fits &= writeln!(out, "{}", option.example).is_ok();
        fits &= writeln!(out, "```").is_ok();
        fits &= writeln!(out).is_ok();
    }

    fits
}

pub fn extend_toml(_path: &[u8], source: &[u8], out: &mut [u8]) -> Extend {
    let mut reader = Reader::new(source);
    let mut found = None;

    while let Some(entry) = reader.read() {
        let Ok(parsed) = entry else {
            continue;
        };

        if !parsed.table.is_empty() || parsed.key != EXTEND_KEY {
            continue;
        }

        let Value::String(text) = parsed.value else {
            return Extend::Faulted;
        };

        found = Some(text);
    }

    let Some(text) = found else {
        return Extend::None;
    };

    text.write_into(out).map_or(Extend::Faulted, Extend::Target)
}

pub fn kebab_of<'text>(name: &str, buffer: &'text mut [u8; NAME_BYTES_MAX]) -> Option<&'text str> {
    assert!(name.len() <= NAME_BYTES_MAX);

    let mut underscored = false;

    for (index, byte) in name.bytes().enumerate() {
        if byte == b'_' {
            buffer[index] = b'-';
            underscored = true;

            continue;
        }

        buffer[index] = byte;
    }

    if !underscored {
        return None;
    }

    core::str::from_utf8(&buffer[..name.len()]).ok()
}

pub fn schema_write<W>(pen: &mut Pen<'_, W>, title: &[u8], options: &[Metadata])
where
    W: Bytes,
{
    pen.object_open();
    pen.key(b"$schema");
    pen.string(SCHEMA_URI);
    pen.key(b"title");
    pen.string(title);
    pen.key(b"type");
    pen.string(b"object");
    pen.key(b"additionalProperties");
    pen.boolean(false);
    pen.key(b"properties");
    pen.object_open();

    for option in options {
        let mut kebab = [0_u8; NAME_BYTES_MAX];

        option.property_write(pen, option.name.as_bytes());

        if let Some(spelled) = kebab_of(option.name, &mut kebab) {
            option.property_write(pen, spelled.as_bytes());
        }
    }

    pen.object_close();
    pen.object_close();
}

pub fn user_config_path(
    out: &mut BoundedVec<u8>,
    override_variable: &str,
    directory_name: &[u8],
    file_name: &[u8],
) -> bool {
    assert!(!directory_name.is_empty());
    assert!(!file_name.is_empty());

    out.clear();

    let (found, tail): (Option<std::ffi::OsString>, &[u8]) = if cfg!(target_os = "windows") {
        (var_os("APPDATA"), b"")
    } else if let Some(named) = var_os(override_variable).filter(|_| !override_variable.is_empty())
    {
        (Some(named), b"")
    } else if let Some(named) = var_os("XDG_CONFIG_HOME") {
        (Some(named), b"")
    } else if cfg!(target_os = "macos") {
        (var_os("HOME"), b"/Library/Application Support")
    } else {
        (var_os("HOME"), b"/.config")
    };

    let Some(directory) = found else {
        return false;
    };

    let Some(bytes) = bytes_of(&directory) else {
        return false;
    };

    let pushed = out.push_bytes(bytes)
        && out.push_bytes(tail)
        && out.push_bytes(b"/")
        && out.push_bytes(directory_name)
        && out.push_bytes(b"/")
        && out.push_bytes(file_name);

    if !pushed {
        out.clear();
    }

    pushed
}

#[cfg(test)]
mod tests {
    use super::*;

    use core::sync::atomic::{AtomicU32, Ordering};
    use std::fs::{create_dir_all, remove_dir_all, write};
    use std::path::{Path, PathBuf};

    const LIMITS: Limits = Limits {
        config_bytes_max: 1 << 12,
        extend_depth_max: 4,
        path_bytes_max: 256,
    };

    const NAMES: Names = Names {
        file_names: &[b"tool.toml", b".tool.toml", b"pyproject.toml"],
        section_file_name: b"pyproject.toml",
    };

    static COUNTER: AtomicU32 = AtomicU32::new(0);

    struct Tree {
        root: PathBuf,
    }

    impl Tree {
        fn new() -> Self {
            let unique = COUNTER.fetch_add(1, Ordering::SeqCst);
            let root = std::env::temp_dir().join(format!(
                "scylla-config-{}-{unique}",
                std::process::id()
            ));

            create_dir_all(&root).expect("the tree root is created");

            Self { root }
        }

        fn seed(&self, name: &str, text: &str) {
            let path = self.root.join(name);

            create_dir_all(path.parent().expect("a seeded file has a parent"))
                .expect("the parent is created");
            write(path, text).expect("the fixture is written");
        }

        fn bytes(&self, name: &str) -> Vec<u8> {
            self.root
                .join(name)
                .to_string_lossy()
                .into_owned()
                .into_bytes()
        }

        fn path(&self) -> &Path {
            &self.root
        }
    }

    impl Drop for Tree {
        fn drop(&mut self) {
            let _removed = remove_dir_all(&self.root);
        }
    }

    fn extend_of(_path: &[u8], source: &[u8], out: &mut [u8]) -> Extend {
        for line in source.split(|byte| *byte == b'\n') {
            let Some(rest) = line.strip_prefix(EXTEND_KEY) else {
                continue;
            };

            let value = rest
                .trim_ascii()
                .strip_prefix(b"=")
                .unwrap_or(b"")
                .trim_ascii();

            let Some(inner) = value
                .strip_prefix(b"\"")
                .and_then(|held| held.strip_suffix(b"\""))
            else {
                return Extend::Faulted;
            };

            out[..inner.len()].copy_from_slice(inner);

            return Extend::Target(inner.len());
        }

        Extend::None
    }

    fn resolver() -> Resolver {
        Resolver::reserve(&LIMITS, NAMES)
    }

    fn discovered(
        resolver: &mut Resolver,
        directory: &[u8],
        applied: &mut Vec<Vec<u8>>,
    ) -> Outcome {
        resolver.clear();
        resolver.discover_start(directory);

        while let Some(path) = resolver.discover_next() {
            let outcome = resolver.load(path, extend_of, |found, source| {
                if resolver_names().needs_section(found) && !source.starts_with(b"[tool.tool]") {
                    return Outcome::Missing;
                }

                applied.push(source.to_vec());

                Outcome::Read
            });

            if outcome != Outcome::Missing {
                return outcome;
            }
        }

        Outcome::Missing
    }

    const fn resolver_names() -> Names {
        NAMES
    }

    fn loaded(resolver: &mut Resolver, path: &[u8], applied: &mut Vec<Vec<u8>>) -> Outcome {
        resolver.clear();

        let Some(span) = resolver.record(path) else {
            return Outcome::Oversized;
        };

        resolver.load(span, extend_of, |_, source| {
            applied.push(source.to_vec());

            Outcome::Read
        })
    }

    #[test]
    fn discovery_with_no_config_file_returns_missing() {
        let tree = Tree::new();
        let mut held = resolver();
        let mut applied = Vec::new();
        let outcome = discovered(&mut held, &tree.bytes(""), &mut applied);

        assert_eq!(outcome, Outcome::Missing);
        assert!(applied.is_empty());
        assert!(held.found().is_none());
    }

    #[test]
    fn discovery_walks_up_from_the_starting_directory() {
        let tree = Tree::new();

        tree.seed("tool.toml", "select = [\"GL\"]\n");
        create_dir_all(tree.path().join("a/b")).expect("the tree");

        let mut held = resolver();
        let mut applied = Vec::new();
        let outcome = discovered(&mut held, &tree.bytes("a/b"), &mut applied);

        assert_eq!(outcome, Outcome::Read);
        assert_eq!(applied, [b"select = [\"GL\"]\n".to_vec()]);
        assert_eq!(held.found(), Some(tree.bytes("tool.toml").as_slice()));
        assert_eq!(held.chain_count(), 1);
    }

    #[test]
    fn the_nearest_config_wins_and_the_first_name_beats_the_later_ones() {
        let tree = Tree::new();

        tree.seed("tool.toml", "select = [\"GL\"]\n");
        tree.seed("a/.tool.toml", "select = [\"HS\"]\n");
        tree.seed("a/pyproject.toml", "[tool.tool]\nselect = [\"AL\"]\n");

        let mut held = resolver();
        let mut applied = Vec::new();
        let outcome = discovered(&mut held, &tree.bytes("a"), &mut applied);

        assert_eq!(outcome, Outcome::Read);
        assert_eq!(applied, [b"select = [\"HS\"]\n".to_vec()]);
    }

    #[test]
    fn a_pyproject_with_no_section_does_not_stop_the_walk() {
        let tree = Tree::new();

        tree.seed("tool.toml", "select = [\"GL\"]\n");
        tree.seed("a/pyproject.toml", "[tool.other]\nx = 1\n");

        let mut held = resolver();
        let mut applied = Vec::new();
        let outcome = discovered(&mut held, &tree.bytes("a"), &mut applied);

        assert_eq!(outcome, Outcome::Read);
        assert_eq!(applied, [b"select = [\"GL\"]\n".to_vec()]);
    }

    #[test]
    fn a_trailing_separator_on_the_start_directory_is_ignored() {
        let tree = Tree::new();

        tree.seed("tool.toml", "x = 1\n");

        let mut held = resolver();
        let mut applied = Vec::new();
        let mut start = tree.bytes("");

        start.push(b'/');

        assert_eq!(discovered(&mut held, &start, &mut applied), Outcome::Read);
    }

    #[test]
    fn a_missing_config_named_explicitly_is_unreadable() {
        let tree = Tree::new();
        let mut held = resolver();
        let mut applied = Vec::new();
        let outcome = loaded(&mut held, &tree.bytes("nope.toml"), &mut applied);

        assert_eq!(outcome, Outcome::Unreadable);
    }

    #[test]
    fn a_config_applies_the_one_it_extends_first() {
        let tree = Tree::new();

        tree.seed("base.toml", "select = [\"GL\"]\n");
        tree.seed(
            "child/tool.toml",
            "extend = \"../base.toml\"\nselect = [\"HS\"]\n",
        );

        let mut held = resolver();
        let mut applied = Vec::new();
        let outcome = discovered(&mut held, &tree.bytes("child"), &mut applied);

        assert_eq!(outcome, Outcome::Read);
        assert_eq!(
            applied,
            [
                b"select = [\"GL\"]\n".to_vec(),
                b"extend = \"../base.toml\"\nselect = [\"HS\"]\n".to_vec(),
            ]
        );
        assert_eq!(held.chain_count(), 2);
        assert_eq!(held.chain_at(0), tree.bytes("child/tool.toml").as_slice());
        assert_eq!(held.chain_at(1), tree.bytes("base.toml").as_slice());
    }

    #[test]
    fn a_cycle_in_the_extend_chain_is_an_error_rather_than_a_loop() {
        let tree = Tree::new();

        tree.seed("a.toml", "extend = \"b.toml\"\n");
        tree.seed("b.toml", "extend = \"a.toml\"\n");

        let mut held = resolver();
        let mut applied = Vec::new();
        let outcome = loaded(&mut held, &tree.bytes("a.toml"), &mut applied);

        assert_eq!(outcome, Outcome::Cycle);
        assert!(applied.is_empty());
    }

    #[test]
    fn a_chain_past_the_depth_is_refused() {
        let tree = Tree::new();

        tree.seed("a.toml", "extend = \"b.toml\"\n");
        tree.seed("b.toml", "extend = \"c.toml\"\n");
        tree.seed("c.toml", "extend = \"d.toml\"\n");
        tree.seed("d.toml", "extend = \"e.toml\"\n");
        tree.seed("e.toml", "x = 1\n");

        let mut held = resolver();
        let mut applied = Vec::new();
        let outcome = loaded(&mut held, &tree.bytes("a.toml"), &mut applied);

        assert_eq!(outcome, Outcome::TooDeep);
    }

    #[test]
    fn a_malformed_extend_is_reported() {
        let tree = Tree::new();

        tree.seed("a.toml", "extend = 3\n");

        let mut held = resolver();
        let mut applied = Vec::new();

        assert_eq!(
            loaded(&mut held, &tree.bytes("a.toml"), &mut applied),
            Outcome::Malformed
        );
    }

    #[test]
    fn an_extend_naming_a_missing_file_is_unreadable() {
        let tree = Tree::new();

        tree.seed("a.toml", "extend = \"gone.toml\"\n");

        let mut held = resolver();
        let mut applied = Vec::new();

        assert_eq!(
            loaded(&mut held, &tree.bytes("a.toml"), &mut applied),
            Outcome::Unreadable
        );
    }

    #[test]
    fn a_config_past_the_byte_ceiling_is_oversized() {
        let tree = Tree::new();

        tree.seed("a.toml", &"x = 1\n".repeat(1 << 11));

        let mut held = resolver();
        let mut applied = Vec::new();

        assert_eq!(
            loaded(&mut held, &tree.bytes("a.toml"), &mut applied),
            Outcome::Oversized
        );
    }

    #[test]
    fn a_faulted_apply_stops_the_chain() {
        let tree = Tree::new();

        tree.seed("base.toml", "x = 1\n");
        tree.seed("tool.toml", "extend = \"base.toml\"\n");

        let mut held = resolver();

        held.discover_start(&tree.bytes(""));

        let path = held.discover_next().expect("the config is found");
        let mut seen = 0;

        let outcome = held.load(path, extend_of, |_, _| {
            seen += 1;

            Outcome::Faulted(seen)
        });

        assert_eq!(outcome, Outcome::Faulted(1));
        assert_eq!(seen, 1);
    }

    #[test]
    fn a_section_file_is_recognised_by_its_last_segment_only() {
        assert!(NAMES.needs_section(b"pyproject.toml"));
        assert!(NAMES.needs_section(b"/a/b/pyproject.toml"));
        assert!(!NAMES.needs_section(b"/a/b/mypyproject.toml"));
        assert!(!NAMES.needs_section(b"/a/b/pyproject.toml.bak"));
    }

    #[test]
    fn discover_starts_from_the_directory_of_a_file_unless_rooted() {
        let tree = Tree::new();

        tree.seed("tool.toml", "x = 1\n");
        tree.seed("a/b/main.rs", "");

        let mut held = resolver();
        let found = held
            .discover(&tree.bytes("a/b/main.rs"), false)
            .expect("the config is found");

        assert_eq!(held.path_of(found), tree.bytes("tool.toml").as_slice());

        let rooted = held
            .discover(&tree.bytes("a/b"), true)
            .expect("the config is found");

        assert_eq!(held.path_of(rooted), tree.bytes("tool.toml").as_slice());
    }

    #[test]
    fn extend_toml_reads_the_top_level_extend_key_only() {
        let mut out = [0_u8; 64];

        assert_eq!(
            extend_toml(b"", b"select = [\"GL\"]\nextend = \"../base.toml\"\n", &mut out),
            Extend::Target(12)
        );
        assert_eq!(&out[..12], b"../base.toml");
        assert_eq!(extend_toml(b"", b"[tool]\nextend = \"x\"\n", &mut out), Extend::None);
        assert_eq!(extend_toml(b"", b"extend = 3\n", &mut out), Extend::Faulted);
        assert_eq!(extend_toml(b"", b"extend = \"a\\tb\"\n", &mut out), Extend::Target(3));
        assert_eq!(&out[..3], b"a\tb");
        assert_eq!(extend_toml(b"", b"x = 1\n", &mut out), Extend::None);
    }

    #[test]
    fn a_config_extended_through_extend_toml_applies_the_base_first() {
        let tree = Tree::new();

        tree.seed("base.toml", "select = [\"GL\"]\n");
        tree.seed("child/tool.toml", "extend = \"../base.toml\"\n");

        let mut held = resolver();
        let mut applied: Vec<Vec<u8>> = Vec::new();
        let path = held
            .discover(&tree.bytes("child"), true)
            .expect("the config is found");

        let outcome: Outcome = held.load(path, extend_toml, |_, source| {
            applied.push(source.to_vec());

            Outcome::Read
        });

        assert_eq!(outcome, Outcome::Read);
        assert_eq!(applied.len(), 2);
        assert_eq!(applied[0], b"select = [\"GL\"]\n".to_vec());
    }

    const OPTIONS: [Metadata; 3] = [
        Metadata {
            default: "2",
            description: "The assertions a function is expected to carry.",
            example: "assertions_min = 2",
            kind: Kind::Integer,
            name: "assertions_min",
        },
        Metadata {
            default: "",
            description: "A \"quoted\" description.",
            example: "select = []",
            kind: Kind::Strings,
            name: "select",
        },
        Metadata {
            default: "auto",
            description: "Colour.",
            example: "color = \"auto\"",
            kind: Kind::Text,
            name: "color",
        },
    ];

    #[test]
    fn a_schema_lists_each_option_under_both_spellings() {
        let mut writer = crate::json::Writer::reserve(8);
        let mut out = Buffer::reserve(1 << 12);
        let mut pen = Pen::bound(&mut writer, &mut out);

        schema_write(&mut pen, b"tool.toml", &OPTIONS);

        assert!(pen.finish());

        let text = core::str::from_utf8(out.as_bytes()).expect("the schema is utf-8");

        assert!(text.starts_with("{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"title\":\"tool.toml\","));
        assert!(text.contains("\"additionalProperties\":false"));
        assert!(text.contains("\"assertions_min\":{\"type\":\"integer\",\"description\":\"The assertions a function is expected to carry.\",\"default\":2}"));
        assert!(text.contains("\"assertions-min\":{\"type\":\"integer\""));
        assert!(text.contains("\"select\":{\"type\":\"array\",\"description\":\"A \\\"quoted\\\" description.\"}"));
        assert!(!text.contains("\"select\":{\"type\":\"array\",\"description\":\"A \\\"quoted\\\" description.\",\"default\""));
        assert!(text.contains("\"color\":{\"type\":\"string\",\"description\":\"Colour.\",\"default\":\"auto\"}"));
        assert_eq!(text.matches("\"color\"").count(), 1);
        assert!(text.ends_with("}}"));
    }

    #[test]
    fn the_documentation_writes_a_section_for_each_option() {
        let mut out = BoundedString::reserve(1 << 12);

        assert!(documentation_write(&mut out, &OPTIONS));

        let text = out.as_str();

        assert!(text.starts_with("# Settings\n\nEvery key is accepted in `snake_case` and `kebab-case`.\n\n## `assertions_min`\n\n"));
        assert!(text.contains("Default: `2`\n\n```toml\nassertions_min = 2\n```\n"));
        assert!(text.contains("## `select`\n\nA \"quoted\" description.\n\n```toml\nselect = []\n```\n"));
        assert!(!text.contains("Default: ``"));

        let mut small = BoundedString::reserve(16);

        assert!(!documentation_write(&mut small, &OPTIONS));
    }

    #[test]
    fn a_kebab_spelling_appears_only_where_an_underscore_did() {
        let mut buffer = [0_u8; NAME_BYTES_MAX];

        assert_eq!(kebab_of("line_length_max", &mut buffer), Some("line-length-max"));
        assert_eq!(kebab_of("select", &mut buffer), None);
        assert_eq!(Kind::Map.schema(), b"object");
        assert_eq!(Kind::Boolean.schema(), b"boolean");
    }

    #[test]
    fn a_user_config_path_ends_in_the_tool_directory_and_file() {
        let mut out = BoundedVec::reserve(256);
        let found = user_config_path(&mut out, "", b"tool", b"tool.toml");

        if found {
            assert!(out.ends_with(b"/tool/tool.toml"));
        } else {
            assert!(out.is_empty());
        }

        let mut small = BoundedVec::reserve(4);

        assert!(!user_config_path(&mut small, "", b"tool", b"tool.toml"));
        assert!(small.is_empty());
    }
}
