use std::ffi::OsStr;
use std::fs::File;
#[cfg(not(windows))]
use std::fs::Metadata;
use std::path::Path;

pub const PATH_BYTES_MAX: usize = 1 << 10;
pub const SEPARATOR: u8 = b'/';
#[cfg(windows)]
const PATH_UNITS_MAX: usize = PATH_BYTES_MAX + 8;
#[cfg(windows)]
const VERBATIM: &[u8] = b"\\\\?\\";
#[cfg(windows)]
const VERBATIM_DEVICE: &[u8] = b"\\\\.\\";
#[cfg(windows)]
const VERBATIM_SHARE: &[u8] = b"\\\\?\\UNC\\";

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Facts {
    pub mode: u32,
    pub nanoseconds: i64,
    pub seconds: i64,
    pub size: u64,
}

#[cfg(windows)]
mod windows {
    use core::ffi::c_void;

    pub(super) type Handle = *mut c_void;

    pub(super) const CREATE_ALWAYS: u32 = 2;
    pub(super) const FILE_ATTRIBUTE_NORMAL: u32 = 0x0000_0080;
    pub(super) const FILE_ATTRIBUTE_READONLY: u32 = 0x0000_0001;
    pub(super) const FILE_SHARE_ALL: u32 = 0x0000_0007;
    pub(super) const GENERIC_READ: u32 = 0x8000_0000;
    pub(super) const GENERIC_WRITE: u32 = 0x4000_0000;
    pub(super) const MOVEFILE_REPLACE_EXISTING: u32 = 0x0000_0001;
    pub(super) const OPEN_EXISTING: u32 = 3;
    pub(super) const EPOCH_TICKS: u64 = 116_444_736_000_000_000;
    pub(super) const TICKS_PER_SECOND: u64 = 10_000_000;

    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    pub(super) struct FileTime {
        pub(super) low: u32,
        pub(super) high: u32,
    }

    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    pub(super) struct AttributeData {
        pub(super) attributes: u32,
        pub(super) created: FileTime,
        pub(super) accessed: FileTime,
        pub(super) written: FileTime,
        pub(super) size_high: u32,
        pub(super) size_low: u32,
    }

    impl FileTime {
        pub(super) fn ticks(self) -> u64 {
            (u64::from(self.high) << 32) | u64::from(self.low)
        }
    }

    pub(super) fn is_invalid(handle: Handle) -> bool {
        handle.is_null() || handle as isize == -1
    }

    unsafe extern "system" {
        pub(super) fn CreateFileW(
            name: *const u16,
            access: u32,
            share: u32,
            security: *mut c_void,
            disposition: u32,
            flags: u32,
            template: Handle,
        ) -> Handle;

        pub(super) fn DeleteFileW(name: *const u16) -> i32;

        pub(super) fn GetFileAttributesExW(
            name: *const u16,
            level: i32,
            information: *mut c_void,
        ) -> i32;

        pub(super) fn MoveFileExW(existing: *const u16, replacement: *const u16, flags: u32)
        -> i32;

        pub(super) fn RemoveDirectoryW(name: *const u16) -> i32;
    }
}

#[cfg(unix)]
#[expect(
    clippy::unnecessary_wraps,
    reason = "the windows variant of this function is fallible, and the callers read both"
)]
pub fn bytes_of(name: &OsStr) -> Option<&[u8]> {
    use std::os::unix::ffi::OsStrExt as _;

    Some(name.as_bytes())
}

#[cfg(not(unix))]
pub fn bytes_of(name: &OsStr) -> Option<&[u8]> {
    name.to_str().map(str::as_bytes)
}

pub fn bytes_or_empty(name: &OsStr) -> &[u8] {
    let Some(bytes) = bytes_of(name) else {
        crate::log_line!("a path this platform cannot spell as text is read as empty");

        return b"";
    };

    bytes
}

#[cfg(unix)]
pub fn path_of(bytes: &[u8]) -> Option<&Path> {
    use std::os::unix::ffi::OsStrExt as _;

    if bytes.len() > PATH_BYTES_MAX {
        return None;
    }

    Some(Path::new(OsStr::from_bytes(bytes)))
}

#[cfg(not(unix))]
pub fn path_of(bytes: &[u8]) -> Option<&Path> {
    if bytes.len() > PATH_BYTES_MAX {
        return None;
    }

    core::str::from_utf8(bytes).ok().map(Path::new)
}

pub fn named(bytes: &[u8]) -> &Path {
    let Some(path) = path_of(bytes) else {
        crate::log_line!("a path that is not valid text is opened as empty");

        return Path::new("");
    };

    path
}

pub const fn is_separator(byte: u8) -> bool {
    byte == SEPARATOR || (cfg!(windows) && byte == b'\\')
}

pub fn is_absolute(path: &[u8]) -> bool {
    if path.first().copied().is_some_and(is_separator) {
        return true;
    }

    let (Some(drive), Some(colon)) = (path.first(), path.get(1)) else {
        return false;
    };

    cfg!(windows) && drive.is_ascii_alphabetic() && *colon == b':'
}

pub fn directory_of(path: &[u8]) -> &[u8] {
    let mut end = path.len();

    while end > 0 {
        end -= 1;

        if !is_separator(path[end]) {
            continue;
        }

        if end == 0 {
            return &path[..1];
        }

        return &path[..end];
    }

    b"."
}

pub fn trimmed(path: &[u8]) -> &[u8] {
    let mut end = path.len();

    while end > 1 && is_separator(path[end - 1]) {
        end -= 1;
    }

    &path[..end]
}

pub fn copied_into(out: &mut [u8], bytes: &[u8]) -> usize {
    let width = out.len().min(bytes.len());

    out[..width].copy_from_slice(&bytes[..width]);

    width
}

pub fn join(target: &mut [u8], base: &[u8], relative: &[u8]) -> Option<usize> {
    if is_absolute(relative) {
        return written(target, 0, relative);
    }

    let mut length = written(target, 0, trimmed(base))?;
    let mut cursor = 0;

    while cursor < relative.len() {
        let end = relative[cursor..]
            .iter()
            .position(|byte| is_separator(*byte))
            .map_or(relative.len(), |offset| cursor + offset);

        let part = &relative[cursor..end];

        cursor = end + 1;

        if part.is_empty() || part == b"." {
            continue;
        }

        if part == b".." {
            length = parent_end(&target[..length]);

            continue;
        }

        let separated = length > 0 && !is_separator(target[length - 1]);

        if separated {
            *target.get_mut(length)? = SEPARATOR;
            length += 1;
        }

        length = written(target, length, part)?;
    }

    Some(length)
}

#[cfg(not(windows))]
pub fn facts_of(bytes: &[u8]) -> Option<Facts> {
    let metadata = std::fs::metadata(path_of(bytes)?).ok()?;
    let (seconds, nanoseconds) = modified_of(&metadata);

    Some(Facts {
        mode: mode_of(&metadata),
        nanoseconds,
        seconds,
        size: metadata.len(),
    })
}

#[cfg(windows)]
pub fn facts_of(bytes: &[u8]) -> Option<Facts> {
    let mut buffer = [0_u16; PATH_UNITS_MAX];

    wide(bytes, &mut buffer)?;

    let mut data = windows::AttributeData::default();
    let information = core::ptr::from_mut(&mut data).cast();
    let read = unsafe { windows::GetFileAttributesExW(buffer.as_ptr(), 0, information) };

    if read == 0 {
        return None;
    }

    let ticks = data.written.ticks();

    let (seconds, nanoseconds) = if ticks >= windows::EPOCH_TICKS {
        let since = ticks - windows::EPOCH_TICKS;

        (
            i64::try_from(since / windows::TICKS_PER_SECOND).unwrap_or(0),
            i64::try_from((since % windows::TICKS_PER_SECOND) * 100).unwrap_or(0),
        )
    } else {
        (0, 0)
    };

    Some(Facts {
        mode: u32::from(data.attributes & windows::FILE_ATTRIBUTE_READONLY != 0),
        nanoseconds,
        seconds,
        size: (u64::from(data.size_high) << 32) | u64::from(data.size_low),
    })
}

pub fn is_directory(bytes: &[u8]) -> bool {
    path_of(bytes).is_some_and(|path| std::fs::metadata(path).is_ok_and(|held| held.is_dir()))
}

pub fn is_file(bytes: &[u8]) -> bool {
    path_of(bytes).is_some_and(|path| std::fs::metadata(path).is_ok_and(|held| held.is_file()))
}

#[cfg(not(windows))]
pub fn open(bytes: &[u8]) -> Option<File> {
    File::open(path_of(bytes)?).ok()
}

#[cfg(windows)]
pub fn open(bytes: &[u8]) -> Option<File> {
    opened(bytes, windows::GENERIC_READ, windows::OPEN_EXISTING)
}

#[cfg(not(windows))]
pub fn create(bytes: &[u8]) -> Option<File> {
    File::create(path_of(bytes)?).ok()
}

#[cfg(windows)]
pub fn create(bytes: &[u8]) -> Option<File> {
    opened(bytes, windows::GENERIC_WRITE, windows::CREATE_ALWAYS)
}

#[cfg(not(windows))]
pub fn rename(from: &[u8], to: &[u8]) -> bool {
    let (Some(source), Some(target)) = (path_of(from), path_of(to)) else {
        return false;
    };

    std::fs::rename(source, target).is_ok()
}

#[cfg(windows)]
pub fn rename(from: &[u8], to: &[u8]) -> bool {
    let mut source = [0_u16; PATH_UNITS_MAX];
    let mut target = [0_u16; PATH_UNITS_MAX];

    if wide(from, &mut source).is_none() || wide(to, &mut target).is_none() {
        return false;
    }

    let flags = windows::MOVEFILE_REPLACE_EXISTING;

    unsafe { windows::MoveFileExW(source.as_ptr(), target.as_ptr(), flags) != 0 }
}

#[cfg(not(windows))]
pub fn remove(bytes: &[u8]) -> bool {
    path_of(bytes).is_some_and(|path| std::fs::remove_file(path).is_ok())
}

#[cfg(windows)]
pub fn remove(bytes: &[u8]) -> bool {
    let mut buffer = [0_u16; PATH_UNITS_MAX];

    if wide(bytes, &mut buffer).is_none() {
        return false;
    }

    unsafe { windows::DeleteFileW(buffer.as_ptr()) != 0 }
}

#[cfg(not(windows))]
pub fn remove_directory(bytes: &[u8]) -> bool {
    path_of(bytes).is_some_and(|path| std::fs::remove_dir(path).is_ok())
}

#[cfg(windows)]
pub fn remove_directory(bytes: &[u8]) -> bool {
    let mut buffer = [0_u16; PATH_UNITS_MAX];

    if wide(bytes, &mut buffer).is_none() {
        return false;
    }

    unsafe { windows::RemoveDirectoryW(buffer.as_ptr()) != 0 }
}

fn parent_end(path: &[u8]) -> usize {
    let mut end = path.len();

    while end > 0 {
        end -= 1;

        if is_separator(path[end]) {
            return end.max(1);
        }
    }

    0
}

fn written(target: &mut [u8], offset: usize, bytes: &[u8]) -> Option<usize> {
    let end = offset.checked_add(bytes.len())?;

    target.get_mut(offset..end)?.copy_from_slice(bytes);

    Some(end)
}

#[cfg(unix)]
fn mode_of(metadata: &Metadata) -> u32 {
    use std::os::unix::fs::PermissionsExt as _;

    metadata.permissions().mode()
}

#[cfg(all(not(unix), not(windows)))]
fn mode_of(metadata: &Metadata) -> u32 {
    u32::from(metadata.permissions().readonly())
}

#[cfg(not(windows))]
fn modified_of(metadata: &Metadata) -> (i64, i64) {
    let Ok(modified) = metadata.modified() else {
        return (0, 0);
    };

    let Ok(since) = modified.duration_since(std::time::UNIX_EPOCH) else {
        return (0, 0);
    };

    (
        i64::try_from(since.as_secs()).unwrap_or(0),
        i64::from(since.subsec_nanos()),
    )
}

#[cfg(windows)]
fn opened(bytes: &[u8], access: u32, disposition: u32) -> Option<File> {
    use std::os::windows::io::FromRawHandle as _;

    let mut buffer = [0_u16; PATH_UNITS_MAX];

    wide(bytes, &mut buffer)?;

    let handle = unsafe {
        windows::CreateFileW(
            buffer.as_ptr(),
            access,
            windows::FILE_SHARE_ALL,
            core::ptr::null_mut(),
            disposition,
            windows::FILE_ATTRIBUTE_NORMAL,
            core::ptr::null_mut(),
        )
    };

    if windows::is_invalid(handle) {
        return None;
    }

    Some(unsafe { File::from_raw_handle(handle.cast()) })
}

#[cfg(windows)]
fn is_qualified(bytes: &[u8]) -> bool {
    let [drive, colon, separator, ..] = bytes else {
        return false;
    };

    drive.is_ascii_alphabetic() && *colon == b':' && is_separator(*separator)
}

#[cfg(windows)]
fn is_share(bytes: &[u8]) -> bool {
    let [first, second, third, ..] = bytes else {
        return false;
    };

    is_separator(*first) && is_separator(*second) && !is_separator(*third)
}

#[cfg(windows)]
fn is_plain(bytes: &[u8], from: usize) -> bool {
    assert!(from <= bytes.len());

    let mut start = from;

    for index in from..=bytes.len() {
        if index < bytes.len() && !is_separator(bytes[index]) {
            continue;
        }

        let component = bytes.get(start..index).unwrap_or_default();

        if component.is_empty() || component == b".".as_slice() || component == b"..".as_slice() {
            return false;
        }

        start = index + 1;
    }

    assert!(start > from);

    true
}

#[cfg(windows)]
fn verbatim_of(bytes: &[u8]) -> Option<(&'static [u8], usize)> {
    if bytes.starts_with(VERBATIM) || bytes.starts_with(VERBATIM_DEVICE) {
        return None;
    }

    if is_share(bytes) {
        return is_plain(bytes, 2).then_some((VERBATIM_SHARE, 2));
    }

    if is_qualified(bytes) {
        return is_plain(bytes, 0).then_some((VERBATIM, 0));
    }

    None
}

#[cfg(windows)]
fn wide(bytes: &[u8], buffer: &mut [u16; PATH_UNITS_MAX]) -> Option<usize> {
    use std::os::windows::ffi::OsStrExt as _;

    let path = path_of(bytes)?;
    let taken = verbatim_of(bytes);
    let mut length = 0;

    if let Some((prefix, _)) = taken {
        for byte in prefix {
            *buffer.get_mut(length)? = u16::from(*byte);
            length += 1;
        }
    }

    let skipped = taken.map_or(0, |(_, count)| count);

    for unit in path.as_os_str().encode_wide().skip(skipped) {
        let unit_written = if taken.is_some() && unit == u16::from(b'/') {
            u16::from(b'\\')
        } else {
            unit
        };

        *buffer.get_mut(length)? = unit_written;
        length += 1;
    }

    *buffer.get_mut(length)? = 0;

    Some(length + 1)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn joined(base: &[u8], relative: &[u8]) -> Vec<u8> {
        let mut target = [0_u8; 64];
        let length = join(&mut target, base, relative).expect("the join fits");

        target[..length].to_vec()
    }

    #[test]
    fn a_text_path_reads_back() {
        let bytes = b"/tmp/scylla.rs";

        crate::allocation::frozen(|| {
            let path = path_of(bytes).expect("the path reads");

            assert_eq!(bytes_of(path.as_os_str()), Some(&bytes[..]));
            assert_eq!(bytes_or_empty(path.as_os_str()), &bytes[..]);
        });
    }

    #[test]
    fn a_missing_path_is_empty() {
        crate::allocation::frozen(|| assert_eq!(named(b"").as_os_str().len(), 0));
    }

    #[cfg(not(unix))]
    #[test]
    fn a_non_text_path_is_refused() {
        crate::allocation::frozen(|| assert!(path_of(&[0xff, 0xfe]).is_none()));
    }

    #[test]
    fn a_directory_drops_the_last_part() {
        assert_eq!(directory_of(b"/a/b/c.toml"), b"/a/b");
        assert_eq!(directory_of(b"/a"), b"/");
        assert_eq!(directory_of(b"c.toml"), b".");
    }

    #[test]
    fn a_trailing_separator_is_trimmed_but_the_root_stays() {
        assert_eq!(trimmed(b"/a/b/"), b"/a/b");
        assert_eq!(trimmed(b"/"), b"/");
        assert_eq!(trimmed(b""), b"");
    }

    #[test]
    fn a_relative_path_resolves_against_its_base() {
        assert_eq!(joined(b"/a/b", b"../c/scylla.toml"), b"/a/c/scylla.toml");
        assert_eq!(joined(b"/a/b/", b"c"), b"/a/b/c");
        assert_eq!(joined(b"/", b"c"), b"/c");
        assert_eq!(joined(b"", b"c"), b"c");
        assert_eq!(joined(b"/a", b"./c//d"), b"/a/c/d");
        assert_eq!(joined(b"/a", b"../../c"), b"/c");
    }

    #[test]
    fn an_absolute_path_replaces_the_base() {
        assert_eq!(joined(b"/a/b", b"/etc/scylla.toml"), b"/etc/scylla.toml");
    }

    #[test]
    fn a_join_past_the_buffer_is_refused() {
        let mut target = [0_u8; 8];

        assert!(join(&mut target, b"/a/b", b"../c/scylla.toml").is_none());
        assert!(join(&mut target, b"/a/b", b"/etc/scylla.toml").is_none());
    }

    #[test]
    fn a_copy_stops_at_the_target() {
        let mut out = [0_u8; 4];

        assert_eq!(copied_into(&mut out, b"abcdef"), 4);
        assert_eq!(&out, b"abcd");
        assert_eq!(copied_into(&mut out, b"xy"), 2);
        assert_eq!(&out[..2], b"xy");
    }

    #[test]
    fn a_windows_path_has_a_directory() {
        if cfg!(windows) {
            assert_eq!(directory_of(br"C:\work\a.rs"), br"C:\work");
            assert_eq!(directory_of(br"C:\work"), b"C:");

            return;
        }

        assert_eq!(directory_of(br"C:\work\a.rs"), b".");
        assert_eq!(directory_of(br"C:\work"), b".");
    }

    #[test]
    fn a_windows_path_loses_its_trailing_separator() {
        assert_eq!(
            trimmed(br"C:\work\"),
            if cfg!(windows) {
                &br"C:\work"[..]
            } else {
                &br"C:\work\"[..]
            },
        );
    }

    #[test]
    fn a_name_joins_a_windows_directory_with_a_forward_slash() {
        let held = joined(br"C:\work", b"scylla.toml");

        assert_eq!(held, br"C:\work/scylla.toml");

        if cfg!(windows) {
            assert_eq!(directory_of(&held), br"C:\work");
        }
    }

    #[test]
    fn a_drive_letter_is_an_absolute_path() {
        assert_eq!(is_absolute(br"C:\shared\scylla.toml"), cfg!(windows));
        assert_eq!(is_absolute(b"C:/shared/scylla.toml"), cfg!(windows));
        assert!(is_absolute(b"/shared/scylla.toml"));
        assert!(!is_absolute(b"shared/scylla.toml"));
        assert!(!is_absolute(b"CC:/shared"));
    }

    #[test]
    fn the_filesystem_entry_points_round_trip() {
        let root =
            std::env::temp_dir().join(format!("scylla-path-round-trip-{}", std::process::id()));

        let _ = std::fs::remove_dir_all(&root);

        std::fs::create_dir_all(&root).expect("the directory is created");

        let source = root.join("one.rs");
        let target = root.join("two.rs");
        let source_bytes = bytes_of(source.as_os_str()).expect("a text path").to_vec();
        let target_bytes = bytes_of(target.as_os_str()).expect("a text path").to_vec();
        let root_bytes = bytes_of(root.as_os_str()).expect("a text path").to_vec();

        crate::allocation::frozen(|| {
            use std::io::Write as _;

            assert!(open(&source_bytes).is_none());
            assert!(facts_of(&source_bytes).is_none());
            assert!(is_directory(&root_bytes));
            assert!(!is_file(&root_bytes));

            let mut file = create(&source_bytes).expect("the file is created");

            file.write_all(b"fn helper() {}\n")
                .expect("the body writes");
        });

        let mut body = String::new();

        {
            use std::io::Read as _;

            let mut file = open(&source_bytes).expect("the file opens");

            #[expect(
                clippy::verbose_file_reads,
                reason = "the test drives the open-then-read shape it is asserting"
            )]
            file.read_to_string(&mut body).expect("the body reads");
        }

        assert_eq!(body, "fn helper() {}\n");

        crate::allocation::frozen(|| {
            let facts = facts_of(&source_bytes).expect("the facts read");

            assert_eq!(facts.size, 15);
            assert!(facts.seconds > 1_600_000_000);
            assert!(is_file(&source_bytes));
            assert!(rename(&source_bytes, &target_bytes));
            assert!(open(&source_bytes).is_none());
            assert!(open(&target_bytes).is_some());
            assert!(remove(&target_bytes));
            assert!(open(&target_bytes).is_none());
            assert!(!remove(&target_bytes));
            assert!(remove_directory(&root_bytes));
            assert!(!is_directory(&root_bytes));
        });

        let _ = std::fs::remove_dir_all(&root);
    }

    #[cfg(windows)]
    #[test]
    fn a_qualified_path_becomes_verbatim() {
        crate::allocation::frozen(|| {
            assert_eq!(verbatim_of(b"C:\\deep\\file.rs"), Some((VERBATIM, 0)));
            assert_eq!(verbatim_of(b"C:/deep/file.rs"), Some((VERBATIM, 0)));
            assert_eq!(verbatim_of(b"\\\\host\\share\\file.rs"), Some((VERBATIM_SHARE, 2)));
        });
    }

    #[cfg(windows)]
    #[test]
    fn a_path_the_prefix_cannot_spell_is_left_alone() {
        crate::allocation::frozen(|| {
            assert_eq!(verbatim_of(b"deep\\file.rs"), None);
            assert_eq!(verbatim_of(b"C:\\deep\\.\\file.rs"), None);
            assert_eq!(verbatim_of(b"C:\\deep\\..\\file.rs"), None);
            assert_eq!(verbatim_of(b"C:\\deep\\\\file.rs"), None);
            assert_eq!(verbatim_of(b"\\\\?\\C:\\deep\\file.rs"), None);
            assert_eq!(verbatim_of(b"\\\\.\\pipe\\name"), None);
        });
    }

    #[cfg(windows)]
    #[test]
    fn a_path_past_the_short_windows_limit_round_trips() {
        const NAME_BYTES: usize = 32;

        let root = std::env::temp_dir().join(format!("scylla-path-long-{}", std::process::id()));

        let _ = std::fs::remove_dir_all(&root);

        let mut held = root.clone();

        while held.as_os_str().len() + NAME_BYTES + 4 < 320 {
            held = held.join("a".repeat(NAME_BYTES - 1));
        }

        std::fs::create_dir_all(&held).expect("the directory is created");

        let file_path = held.join("one.rs");
        let bytes = bytes_of(file_path.as_os_str())
            .expect("a text path")
            .to_vec();

        assert!(file_path.as_os_str().len() > 260);

        crate::allocation::frozen(|| {
            use std::io::Write as _;

            let mut file = create(&bytes).expect("the long path is created");

            file.write_all(b"fn helper() {}\n")
                .expect("the body writes");
        });

        crate::allocation::frozen(|| {
            let facts = facts_of(&bytes).expect("the long path reads");

            assert_eq!(facts.size, 15);
            assert!(open(&bytes).is_some());
            assert!(remove(&bytes));
        });

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_path_that_does_not_fit_is_refused_rather_than_truncated() {
        let overlong = vec![b'a'; PATH_BYTES_MAX + 1];

        assert!(path_of(&overlong).is_none());
        assert!(open(&overlong).is_none());
        assert!(create(&overlong).is_none());
        assert!(facts_of(&overlong).is_none());
        assert!(!remove(&overlong));
        assert!(!is_file(&overlong));
    }
}
