use core::ffi::{c_char, c_int, c_void};
use core::ptr::null_mut;
use core::slice::from_raw_parts;

const DT_DIR: u8 = 4;
const DT_LNK: u8 = 10;
const DT_REG: u8 = 8;
const DT_UNKNOWN: u8 = 0;

#[cfg(target_os = "linux")]
#[repr(C)]
struct Dirent {
    inode: u64,
    offset: i64,
    length: u16,
    kind: u8,
    name: [c_char; 256],
}

#[cfg(target_os = "macos")]
#[repr(C)]
struct Dirent {
    inode: u64,
    seek: u64,
    length: u16,
    name_length: u16,
    kind: u8,
    name: [c_char; 1_024],
}

unsafe extern "C" {
    fn closedir(directory: *mut c_void) -> c_int;
    fn opendir(path: *const c_char) -> *mut c_void;
    fn readdir(directory: *mut c_void) -> *mut c_void;
}

pub struct Directory {
    handle: *mut c_void,
}

pub struct Listing<'name> {
    pub kind: u8,
    pub name: &'name [u8],
}

impl Listing<'_> {
    pub const fn is_directory(&self) -> bool {
        self.kind == DT_DIR
    }

    pub const fn is_known(&self) -> bool {
        self.kind == DT_DIR || self.kind == DT_REG
    }

    pub const fn is_link(&self) -> bool {
        self.kind == DT_LNK
    }
}

impl Drop for Directory {
    fn drop(&mut self) {
        if self.handle.is_null() {
            return;
        }

        let _closed = unsafe { closedir(self.handle) };

        self.handle = null_mut();
    }
}

impl Directory {
    pub fn open(path: &[u8]) -> Option<Self> {
        let last = path.last()?;

        if *last != 0 {
            return None;
        }

        let handle = unsafe { opendir(path.as_ptr().cast::<c_char>()) };

        if handle.is_null() {
            return None;
        }

        Some(Self { handle })
    }

    pub fn read(&mut self) -> Option<Listing<'_>> {
        let entry = unsafe { readdir(self.handle) };

        if entry.is_null() {
            return None;
        }

        let held: &Dirent = unsafe { &*entry.cast::<Dirent>() };
        let name = name_of(held.name.as_slice());

        Some(Listing {
            kind: held.kind,
            name,
        })
    }
}

fn name_of(field: &[c_char]) -> &[u8] {
    let mut length = 0_usize;

    while length < field.len() {
        let Some(byte) = field.get(length).copied() else {
            break;
        };

        if byte == 0 {
            break;
        }

        length = length.saturating_add(1);
    }

    unsafe { from_raw_parts(field.as_ptr().cast::<u8>(), length) }
}

const _: () = assert!(DT_UNKNOWN == 0);
