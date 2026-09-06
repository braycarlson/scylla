use core::ffi::{c_int, c_void};
use core::ptr::null_mut;
use core::str::from_utf8;

use crate::path::{PATH_BYTES_MAX, SEPARATOR};

const ALTERNATE_UNITS_MAX: usize = 14;
const ATTRIBUTE_DIRECTORY: u32 = 0x0000_0010;
const ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;
const DIRECTORY: u8 = 1;
const FILE: u8 = 2;
const LINK: u8 = 3;
const NAME_UNITS_MAX: usize = 260;
const NAME_BYTES_MAX: usize = NAME_UNITS_MAX * 3;
const PATTERN_UNITS_MAX: usize = PATH_BYTES_MAX + 3;
const UNDECODABLE_NAMES_MAX: u32 = 1 << 20;
const UNKNOWN: u8 = 0;

#[repr(C)]
struct FileTime {
    low: u32,
    high: u32,
}

#[repr(C)]
struct FindData {
    attributes: u32,
    created: FileTime,
    accessed: FileTime,
    written: FileTime,
    size_high: u32,
    size_low: u32,
    reserved_first: u32,
    reserved_second: u32,
    name: [u16; NAME_UNITS_MAX],
    alternate: [u16; ALTERNATE_UNITS_MAX],
}

#[link(name = "kernel32")]
unsafe extern "system" {
    #[link_name = "FindClose"]
    fn find_close(handle: *mut c_void) -> c_int;
    #[link_name = "FindFirstFileW"]
    fn find_first_file(pattern: *const u16, data: *mut FindData) -> *mut c_void;
    #[link_name = "FindNextFileW"]
    fn find_next_file(handle: *mut c_void, data: *mut FindData) -> c_int;
}

pub struct Directory {
    data: FindData,
    handle: *mut c_void,
    kind: u8,
    length: usize,
    name: [u8; NAME_BYTES_MAX],
    pending: bool,
}

pub struct Listing<'name> {
    pub kind: u8,
    pub name: &'name [u8],
}

impl FileTime {
    const EMPTY: Self = Self { high: 0, low: 0 };
}

impl FindData {
    const EMPTY: Self = Self {
        accessed: Self::UNSET,
        alternate: [0_u16; ALTERNATE_UNITS_MAX],
        attributes: 0,
        created: Self::UNSET,
        name: [0_u16; NAME_UNITS_MAX],
        reserved_first: 0,
        reserved_second: 0,
        size_high: 0,
        size_low: 0,
        written: Self::UNSET,
    };
    const UNSET: FileTime = FileTime::EMPTY;
}

impl Listing<'_> {
    pub const fn is_directory(&self) -> bool {
        self.kind == DIRECTORY
    }

    pub const fn is_known(&self) -> bool {
        self.kind != UNKNOWN
    }

    pub const fn is_link(&self) -> bool {
        self.kind == LINK
    }
}

impl Drop for Directory {
    fn drop(&mut self) {
        if self.handle.is_null() {
            return;
        }

        let _closed = unsafe { find_close(self.handle) };

        self.handle = null_mut();
    }
}

impl Directory {
    pub fn open(path: &[u8]) -> Option<Self> {
        let last = path.last()?;

        if *last != 0 {
            return None;
        }

        let mut pattern = [0_u16; PATTERN_UNITS_MAX];

        if !patterned(path, &mut pattern) {
            return None;
        }

        let mut data = FindData::EMPTY;
        let handle = unsafe { find_first_file(pattern.as_ptr(), &raw mut data) };

        if handle.is_null() || handle.addr() == usize::MAX {
            return None;
        }

        Some(Self {
            data,
            handle,
            kind: UNKNOWN,
            length: 0,
            name: [0_u8; NAME_BYTES_MAX],
            pending: true,
        })
    }

    pub fn read(&mut self) -> Option<Listing<'_>> {
        let mut found = false;

        for _ in 0..UNDECODABLE_NAMES_MAX {
            if self.pending {
                self.pending = false;
            } else {
                let stepped = unsafe { find_next_file(self.handle, &raw mut self.data) };

                if stepped == 0_i32 {
                    return None;
                }
            }

            let Some(length) = decoded(&self.data.name, &mut self.name) else {
                continue;
            };

            self.kind = kind_of(self.data.attributes);
            self.length = length;
            found = true;

            break;
        }

        if !found {
            return None;
        }

        Some(Listing {
            kind: self.kind,
            name: self.name.get(..self.length).unwrap_or(&[]),
        })
    }
}

fn decoded(units: &[u16; NAME_UNITS_MAX], target: &mut [u8; NAME_BYTES_MAX]) -> Option<usize> {
    let named = units.iter().copied().take_while(|unit| *unit != 0);
    let mut length = 0_usize;

    for held in char::decode_utf16(named) {
        let Ok(character) = held else {
            return None;
        };

        let room = target.get_mut(length..)?;

        if room.len() < character.len_utf8() {
            return None;
        }

        length = length.saturating_add(character.encode_utf8(room).len());
    }

    Some(length)
}

const fn kind_of(attributes: u32) -> u8 {
    if attributes & ATTRIBUTE_REPARSE_POINT != 0 {
        return LINK;
    }

    if attributes & ATTRIBUTE_DIRECTORY != 0 {
        return DIRECTORY;
    }

    FILE
}

fn patterned(path: &[u8], target: &mut [u16; PATTERN_UNITS_MAX]) -> bool {
    let trimmed = path.get(..path.len().saturating_sub(1)).unwrap_or_default();

    let Ok(text) = from_utf8(trimmed) else {
        return false;
    };

    if text.is_empty() {
        return false;
    }

    let mut encoded = [0_u16; 2];
    let mut length = 0_usize;

    for character in text.chars() {
        for unit in character.encode_utf16(&mut encoded).iter() {
            let Some(moved) = pushed(target, length, *unit) else {
                return false;
            };

            length = moved;
        }
    }

    if !text.ends_with('/') && !text.ends_with('\\') {
        let Some(moved) = pushed(target, length, u16::from(SEPARATOR)) else {
            return false;
        };

        length = moved;
    }

    let Some(starred) = pushed(target, length, u16::from(b'*')) else {
        return false;
    };

    pushed(target, starred, 0).is_some()
}

fn pushed(target: &mut [u16; PATTERN_UNITS_MAX], length: usize, unit: u16) -> Option<usize> {
    let slot = target.get_mut(length)?;

    *slot = unit;

    Some(length.saturating_add(1))
}

const _: () = assert!(UNKNOWN == 0);
