use std::io::Write as _;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::bounded::{
    Arena,
    BoundedString,
    BoundedVec,
    Buffer,
    Bytes as _,
    HASH_PRIME,
    Span,
    Table,
    count_of,
    hash_of,
};
use crate::log_line;
use crate::path::{self, Facts as Stamp};
use crate::scan::{
    DECIMAL_BYTES_MAX,
    decimal_read,
    decimal_write,
    read_u16_le,
    read_u32_le,
    read_u64_le,
};

pub const EVICTION_SECONDS: u64 = 30 * 24 * 60 * 60;
pub const MAGIC_BYTES: usize = 8;
pub const TAG_NAME: &[u8] = b"CACHEDIR.TAG";
pub const TAG_SIGNATURE: &[u8] = b"Signature: 8a477f597d28d172789f06886806bc55\n";
pub const VERSION: u32 = 1;
const COUNT_OFFSET: u32 = 12;
const HEADER_BYTES: usize = 24;
const STAMP_BYTES: usize = 36;

#[expect(
    clippy::struct_field_names,
    reason = "the `_max` postfix is the big-endian convention naming the bound each field carries"
)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Limits {
    pub bytes_max: u32,
    pub entry_count_max: u32,
    pub path_bytes_max: u32,
}

#[derive(Clone, Copy, Debug)]
struct Entry {
    mode: u32,
    nanoseconds: i64,
    path: Span,
    seconds: i64,
    seen: u64,
    size: u64,
}

#[derive(Debug)]
pub struct Baseline {
    entries: BoundedVec<u64>,
    source: Buffer,
}

#[derive(Debug)]
pub struct Cache {
    entries: BoundedVec<Entry>,
    index: Table<u32>,
    key: u64,
    magic: [u8; MAGIC_BYTES],
    paths: Arena,
    scratch: Buffer,
    target: BoundedString,
    temporary: BoundedString,
}

impl Entry {
    const fn stamp(&self) -> Stamp {
        Stamp {
            mode: self.mode,
            nanoseconds: self.nanoseconds,
            seconds: self.seconds,
            size: self.size,
        }
    }
}

impl Baseline {
    pub fn count(&self) -> u32 {
        self.entries.count()
    }

    pub fn covers(&self, key: u64) -> bool {
        debug_assert!(self.entries.is_sorted());

        self.entries.binary_search(&key).is_ok()
    }

    pub fn key_at(&self, index: u32) -> u64 {
        assert!(index < self.count());

        self.entries[index as usize]
    }

    pub fn load(&mut self, path: &[u8]) -> bool {
        self.entries.clear();
        self.source.clear();

        let Some(mut file) = path::open(path) else {
            return false;
        };

        if !matches!(self.source.read_from(&mut file), Ok(true)) {
            return false;
        }

        for line in self.source.as_bytes().split(|byte| *byte == b'\n') {
            let text = line.trim_ascii();

            if text.is_empty() {
                continue;
            }

            let Some(key) = decimal_read(text) else {
                continue;
            };

            if !self.entries.push(key) {
                break;
            }
        }

        self.entries.sort_unstable();

        assert!(self.entries.is_sorted());

        true
    }

    pub fn record(&mut self, key: u64) -> bool {
        if self.entries.is_empty() {
            return self.entries.push(key);
        }

        let at = count_of(self.entries.partition_point(|entry| *entry < key));

        if !self.entries.shift_tail(at, at + 1) {
            return false;
        }

        self.entries[at as usize] = key;

        debug_assert!(self.entries.is_sorted());

        true
    }

    pub fn reserve(entry_count_max: u32, file_bytes_max: u32) -> Self {
        assert!(entry_count_max > 0);
        assert!(file_bytes_max > 0);
        assert!(!crate::allocation::is_frozen());

        Self {
            entries: BoundedVec::reserve(entry_count_max),
            source: Buffer::reserve(file_bytes_max),
        }
    }

    pub fn write(path: &[u8], lines: &[u8]) -> bool {
        let Some(mut file) = path::create(path) else {
            return false;
        };

        file.write_all(lines).is_ok()
    }
}

impl Cache {
    fn clear(&mut self) {
        self.entries.clear();
        self.index.clear();
        self.paths.reset();
    }

    pub fn count(&self) -> u32 {
        self.entries.count()
    }

    fn count_patch(&mut self, count: u32) {
        let patched = self.scratch.patch(COUNT_OFFSET, &count.to_le_bytes());

        assert!(patched);
    }

    fn discard(&self) {
        let _removed = path::remove(self.target.as_bytes());
    }

    fn encode(&mut self) {
        let cutoff = now_seconds().saturating_sub(EVICTION_SECONDS);

        self.scratch.clear();
        self.header_write();

        let mut written = 0_u32;

        for index in 0..self.entries.count() as usize {
            let entry = self.entries[index];

            if entry.seen < cutoff {
                continue;
            }

            if !self.record_write(&entry) {
                log_line!("the cache did not fit its buffer; it is written short");

                break;
            }

            written += 1;
        }

        assert!(written <= self.entries.count());

        self.count_patch(written);
    }

    fn find(&self, path: &[u8]) -> Option<u32> {
        find_in(&self.index, &self.paths, path)
    }

    fn flush(&self) {
        let Some(mut file) = path::create(self.temporary.as_bytes()) else {
            log_line!("the cache could not be written");

            return;
        };

        if file.write_all(self.scratch.as_bytes()).is_err() {
            log_line!("the cache could not be written");

            return;
        }

        drop(file);

        if !path::rename(self.temporary.as_bytes(), self.target.as_bytes()) {
            let _removed = path::remove(self.temporary.as_bytes());

            log_line!("the cache could not be replaced");
        }
    }

    fn header_write(&mut self) {
        let written = self.scratch.push_bytes(&self.magic)
            && self.scratch.push_bytes(&VERSION.to_le_bytes())
            && self.scratch.push_bytes(&0_u32.to_le_bytes())
            && self.scratch.push_bytes(&self.key.to_le_bytes());

        assert!(written);
        assert_eq!(self.scratch.count() as usize, HEADER_BYTES);
    }

    pub fn is_clean(&self, path: &[u8], stamp: Stamp) -> bool {
        let Some(index) = self.find(path) else {
            return false;
        };

        self.entries[index as usize].stamp() == stamp
    }

    fn load(&mut self) {
        self.clear();
        self.scratch.clear();

        let Some(mut file) = path::open(self.target.as_bytes()) else {
            return;
        };

        if !matches!(self.scratch.read_from(&mut file), Ok(true)) {
            self.discard();

            return;
        }

        if !self.parse() {
            self.clear();
            self.discard();
        }
    }

    pub fn open(&mut self, directory: &[u8], key: u64, tag_body: &[u8]) -> bool {
        assert!(!crate::allocation::is_frozen());
        assert!(!directory.is_empty());

        self.key = key;

        if !self.paths_build(directory) {
            log_line!("the cache path does not fit; the cache is off");

            return false;
        }

        if !directories_create(directory) {
            log_line!("the cache directory could not be created; the cache is off");

            return false;
        }

        tag_write(directory, tag_body);
        self.load();

        true
    }

    fn parse(&mut self) -> bool {
        let bytes = self.scratch.as_bytes();

        if bytes.len() < HEADER_BYTES || bytes[..MAGIC_BYTES] != self.magic {
            return false;
        }

        if read_u32_le(bytes, 8) != Some(VERSION) || read_u64_le(bytes, 16) != Some(self.key) {
            return false;
        }

        let Some(count) = read_u32_le(bytes, COUNT_OFFSET as usize) else {
            return false;
        };

        let mut offset = HEADER_BYTES;

        for _ in 0..count {
            let Some(length) = read_u16_le(bytes, offset) else {
                return false;
            };

            offset += 2;

            let path_end = offset + length as usize;

            if path_end + STAMP_BYTES > bytes.len() {
                return false;
            }

            let path = &bytes[offset..path_end];
            let Some(entry) = entry_read(bytes, path_end) else {
                return false;
            };

            offset = path_end + STAMP_BYTES;

            let held = find_in(&self.index, &self.paths, path).is_none()
                && insert_into(
                    &mut self.entries,
                    &mut self.index,
                    &mut self.paths,
                    path,
                    entry,
                );

            if !held {
                return false;
            }
        }

        assert_eq!(self.entries.count(), count);

        true
    }

    fn paths_build(&mut self, directory: &[u8]) -> bool {
        self.target.clear();
        self.temporary.clear();

        let mut digits = [0_u8; DECIMAL_BYTES_MAX];
        let length = decimal_write(&mut digits, u64::from(std::process::id()));

        for (target, suffix) in [
            (&mut self.target, &[][..]),
            (&mut self.temporary, &digits[..length]),
        ] {
            if !target.push_bytes(directory) || !target.push_bytes(b"/1/clean.bin") {
                return false;
            }

            if suffix.is_empty() {
                continue;
            }

            if !target.push_bytes(b".tmp") || !target.push_bytes(suffix) {
                return false;
            }
        }

        true
    }

    pub fn persist(&mut self) {
        self.encode();
        self.flush();
    }

    pub fn record(&mut self, path: &[u8], stamp: Stamp) {
        let seen = now_seconds();

        if let Some(index) = self.find(path) {
            let entry = &mut self.entries[index as usize];

            entry.mode = stamp.mode;
            entry.nanoseconds = stamp.nanoseconds;
            entry.seconds = stamp.seconds;
            entry.seen = seen;
            entry.size = stamp.size;

            return;
        }

        let _inserted = insert_into(
            &mut self.entries,
            &mut self.index,
            &mut self.paths,
            path,
            Entry {
                mode: stamp.mode,
                nanoseconds: stamp.nanoseconds,
                path: Span::EMPTY,
                seconds: stamp.seconds,
                seen,
                size: stamp.size,
            },
        );
    }

    fn record_write(&mut self, entry: &Entry) -> bool {
        let path = self.paths.bytes_of(entry.path);
        let Ok(width) = u16::try_from(path.len()) else {
            return false;
        };

        self.scratch.push_bytes(&width.to_le_bytes())
            && self.scratch.push_bytes(path)
            && self.scratch.push_bytes(&entry.seconds.to_le_bytes())
            && self.scratch.push_bytes(&entry.nanoseconds.to_le_bytes())
            && self.scratch.push_bytes(&entry.seen.to_le_bytes())
            && self.scratch.push_bytes(&entry.mode.to_le_bytes())
            && self.scratch.push_bytes(&entry.size.to_le_bytes())
    }

    pub fn reserve(limits: &Limits, magic: &[u8]) -> Self {
        assert!(limits.bytes_max > 0);
        assert!(limits.entry_count_max > 0);
        assert!(u16::try_from(limits.path_bytes_max).is_ok());
        assert!(!magic.is_empty());
        assert!(magic.len() < MAGIC_BYTES);
        assert!(!crate::allocation::is_frozen());

        let mut held = [0_u8; MAGIC_BYTES];

        held[..magic.len()].copy_from_slice(magic);

        Self {
            entries: BoundedVec::reserve(limits.entry_count_max),
            index: Table::reserve(limits.entry_count_max),
            key: 0,
            magic: held,
            paths: Arena::reserve(limits.bytes_max),
            scratch: Buffer::reserve(limits.bytes_max),
            target: BoundedString::reserve(limits.path_bytes_max),
            temporary: BoundedString::reserve(limits.path_bytes_max),
        }
    }
}

pub fn baseline_key_of(path: &[u8], code: &[u8], line: &[u8]) -> u64 {
    let mut value = hash_of(path);

    value ^= hash_of(code);
    value = value.wrapping_mul(HASH_PRIME);
    value ^= hash_of(line.trim_ascii());
    value.wrapping_mul(HASH_PRIME)
}

pub fn now_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| since.as_secs())
}

fn directories_create(directory: &[u8]) -> bool {
    assert!(!crate::allocation::is_frozen());

    let target = path::named(directory).join("1");

    std::fs::create_dir_all(&target).is_ok()
}

fn entry_read(bytes: &[u8], offset: usize) -> Option<Entry> {
    Some(Entry {
        mode: read_u32_le(bytes, offset + 24)?,
        nanoseconds: read_u64_le(bytes, offset + 8)?.cast_signed(),
        path: Span::EMPTY,
        seconds: read_u64_le(bytes, offset)?.cast_signed(),
        seen: read_u64_le(bytes, offset + 16)?,
        size: read_u64_le(bytes, offset + 28)?,
    })
}

fn find_in(index: &Table<u32>, paths: &Arena, path: &[u8]) -> Option<u32> {
    if path.is_empty() {
        return None;
    }

    index.get(hash_of(path), |key| paths.bytes_of(key) == path)
}

fn insert_into(
    entries: &mut BoundedVec<Entry>,
    index: &mut Table<u32>,
    paths: &mut Arena,
    path: &[u8],
    entry: Entry,
) -> bool {
    if path.is_empty() || entries.is_full() {
        return false;
    }

    let Some(span) = paths.intern(path) else {
        return false;
    };

    let position = entries.count();
    let inserted = index.insert(hash_of(path), span, position, |key| {
        paths.bytes_of(key) == path
    });

    assert!(inserted);

    entries.push_assert(Entry {
        path: span,
        ..entry
    });

    true
}

fn tag_write(directory: &[u8], tag_body: &[u8]) {
    assert!(!crate::allocation::is_frozen());

    let target = path::named(directory).join(path::named(TAG_NAME));

    if target.exists() {
        return;
    }

    let _written = std::fs::write(target, tag_body);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::allocation;

    const LIMITS: Limits = Limits {
        bytes_max: 1 << 16,
        entry_count_max: 64,
        path_bytes_max: 256,
    };

    const MAGIC: &[u8] = b"TESTSC";

    const STAMP: Stamp = Stamp {
        mode: 0o644,
        nanoseconds: 123_456_789,
        seconds: 1_700_000_000,
        size: 4_096,
    };

    fn reserved(key: u64) -> Cache {
        let mut cache = Cache::reserve(&LIMITS, MAGIC);

        cache.key = key;

        cache
    }

    fn written(key: u64) -> Cache {
        let mut cache = reserved(key);

        allocation::frozen(|| {
            cache.record(b"src/one.rs", STAMP);

            cache.record(
                b"src/two.rs",
                Stamp {
                    size: 8_192,
                    ..STAMP
                },
            );

            cache.encode();
        });

        cache
    }

    fn parsed(bytes: &[u8], key: u64) -> Option<Cache> {
        let mut cache = reserved(key);

        let parsed = allocation::frozen(|| {
            assert!(cache.scratch.push_bytes(bytes));

            cache.parse()
        });

        parsed.then_some(cache)
    }

    #[test]
    fn a_written_cache_reads_its_entries_back() {
        let written = written(7);
        let read = parsed(written.scratch.as_bytes(), 7).expect("the file parses");

        allocation::frozen(|| {
            assert_eq!(read.count(), 2);
            assert!(read.is_clean(b"src/one.rs", STAMP));

            assert!(read.is_clean(
                b"src/two.rs",
                Stamp {
                    size: 8_192,
                    ..STAMP
                }
            ));

            assert!(!read.is_clean(b"src/three.rs", STAMP));

            assert!(!read.is_clean(
                b"src/one.rs",
                Stamp {
                    seconds: STAMP.seconds + 1,
                    ..STAMP
                }
            ));
        });
    }

    #[test]
    fn the_header_carries_the_magic_the_version_the_count_and_the_key() {
        let written = written(7);
        let bytes = written.scratch.as_bytes();

        allocation::frozen(|| {
            assert_eq!(&bytes[..MAGIC.len()], MAGIC);
            assert_eq!(bytes[MAGIC.len()], 0);
            assert_eq!(read_u32_le(bytes, 8), Some(VERSION));
            assert_eq!(read_u32_le(bytes, 12), Some(2));
            assert_eq!(read_u64_le(bytes, 16), Some(7));
        });
    }

    #[test]
    fn an_entry_older_than_the_eviction_window_is_not_written() {
        let mut cache = reserved(7);

        allocation::frozen(|| {
            cache.record(b"src/fresh.rs", STAMP);
            cache.record(b"src/stale.rs", STAMP);
            cache.entries[1].seen = now_seconds().saturating_sub(EVICTION_SECONDS + 1);
            cache.encode();

            assert_eq!(read_u32_le(cache.scratch.as_bytes(), 12), Some(1));
        });

        let read = parsed(cache.scratch.as_bytes(), 7).expect("the file parses");

        allocation::frozen(|| {
            assert_eq!(read.count(), 1);
            assert!(read.is_clean(b"src/fresh.rs", STAMP));
            assert!(!read.is_clean(b"src/stale.rs", STAMP));
        });
    }

    #[test]
    fn a_key_a_magic_or_a_version_that_moved_refuses_the_whole_file() {
        let written = written(7);
        let bytes = written.scratch.as_bytes().to_vec();

        assert!(parsed(&bytes, 8).is_none());

        let mut foreign = bytes.clone();

        foreign[0] = b'X';

        assert!(parsed(&foreign, 7).is_none());

        let mut versioned = bytes;

        versioned[8..12].copy_from_slice(&(VERSION + 1).to_le_bytes());

        assert!(parsed(&versioned, 7).is_none());
    }

    #[test]
    fn a_frame_cut_anywhere_is_refused() {
        let written = written(7);
        let bytes = written.scratch.as_bytes().to_vec();

        for length in 0..bytes.len() {
            assert!(parsed(&bytes[..length], 7).is_none(), "at {length} bytes");
        }

        assert!(parsed(&bytes, 7).is_some());
    }

    #[test]
    fn a_count_that_disagrees_with_the_frames_is_read_by_the_count() {
        let written = written(7);
        let bytes = written.scratch.as_bytes().to_vec();
        let mut overlong = bytes.clone();

        overlong[24..26].copy_from_slice(&u16::try_from(bytes.len()).expect("small").to_le_bytes());

        assert!(parsed(&overlong, 7).is_none());

        let mut more = bytes.clone();

        more[12..16].copy_from_slice(&3_u32.to_le_bytes());

        assert!(parsed(&more, 7).is_none());

        let mut fewer = bytes;

        fewer[12..16].copy_from_slice(&1_u32.to_le_bytes());

        let read = parsed(&fewer, 7).expect("the file parses");

        allocation::frozen(|| {
            assert_eq!(read.count(), 1);
            assert!(read.is_clean(b"src/one.rs", STAMP));
        });
    }

    #[test]
    fn recording_a_path_twice_moves_the_entry_rather_than_adding_one() {
        let mut cache = reserved(7);

        allocation::frozen(|| {
            cache.record(b"src/one.rs", STAMP);
            cache.record(b"src/one.rs", Stamp { size: 1, ..STAMP });

            assert_eq!(cache.count(), 1);
            assert!(cache.is_clean(b"src/one.rs", Stamp { size: 1, ..STAMP }));
        });
    }

    #[test]
    fn an_opened_cache_persists_and_reopens_from_disk_with_its_tag() {
        let directory = std::env::temp_dir().join(format!(
            "scylla-cache-{}-{}",
            std::process::id(),
            now_seconds()
        ));
        let bytes = directory.to_string_lossy().into_owned().into_bytes();
        let mut cache = reserved(7);

        assert!(cache.open(&bytes, 9, b"a tag body\n"));
        assert_eq!(cache.count(), 0);

        allocation::frozen(|| {
            cache.record(b"src/one.rs", STAMP);
            cache.persist();
        });

        let tag = std::fs::read(directory.join("CACHEDIR.TAG")).expect("the tag was written");

        assert_eq!(tag, b"a tag body\n");

        let mut reopened = reserved(0);

        assert!(reopened.open(&bytes, 9, b"another body\n"));
        assert_eq!(reopened.count(), 1);
        assert!(reopened.is_clean(b"src/one.rs", STAMP));

        let mut rekeyed = reserved(0);

        assert!(rekeyed.open(&bytes, 10, b""));
        assert_eq!(rekeyed.count(), 0);

        let _removed = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn a_baseline_key_ignores_leading_and_trailing_space_and_separates_paths_and_codes() {
        allocation::frozen(|| {
            assert_eq!(
                baseline_key_of(b"a.rs", b"TS001", b"    let value = 1;  "),
                baseline_key_of(b"a.rs", b"TS001", b"let value = 1;")
            );

            assert_ne!(
                baseline_key_of(b"a.rs", b"TS001", b"let value = 1;"),
                baseline_key_of(b"b.rs", b"TS001", b"let value = 1;")
            );

            assert_ne!(
                baseline_key_of(b"a.rs", b"TS001", b"let value = 1;"),
                baseline_key_of(b"a.rs", b"TS002", b"let value = 1;")
            );
        });
    }

    #[test]
    fn a_baseline_records_sorted_and_loads_what_it_wrote() {
        let mut baseline = Baseline::reserve(8, 1 << 10);

        allocation::frozen(|| {
            assert!(baseline.record(7));
            assert!(baseline.record(3));
            assert!(baseline.record(5));
            assert!(baseline.covers(3));
            assert!(baseline.covers(5));
            assert!(!baseline.covers(4));
            assert_eq!(baseline.count(), 3);
            assert_eq!(baseline.key_at(0), 3);
            assert_eq!(baseline.key_at(2), 7);
        });

        let file = std::env::temp_dir().join(format!("scylla-baseline-{}", std::process::id()));
        let path = file.to_string_lossy().into_owned().into_bytes();

        assert!(Baseline::write(&path, b"7\n\n3\nnot a key\n5\n"));

        let mut loaded = Baseline::reserve(8, 1 << 10);

        assert!(loaded.load(&path));
        assert_eq!(loaded.count(), 3);
        assert!(loaded.covers(7));
        assert!(!loaded.load(b"/nonexistent/scylla-baseline"));

        let _removed = std::fs::remove_file(&file);
    }
}
