use core::ptr::NonNull;
use core::sync::atomic::{AtomicBool, Ordering};

use crate::bounded::{Buffer, Bytes as _, count_of};
use crate::language::Language;
use crate::lines;
use crate::markup;
use crate::markup::tree::TreeError;
use crate::parallel::striped;
use crate::syntax::css::semantic::Semantic as CSSSemantic;
use crate::syntax::front::{self, Front, Options, Scratch, Tables, shrunk_of};
use crate::syntax::go::semantic::Semantic as GoSemantic;
use crate::syntax::javascript::semantic::Semantic as JavaScriptSemantic;
use crate::syntax::odin::semantic::Semantic as OdinSemantic;
use crate::syntax::python::check::CheckError as PythonCheckError;
use crate::syntax::python::semantic::Semantic as PythonSemantic;
use crate::syntax::python::stdlib::PythonVersion;
use crate::syntax::rust::semantic::Semantic as RustSemantic;
use crate::syntax::zig::semantic::Semantic as ZigSemantic;
use crate::syntax::{Fact, SyntaxError};
use crate::token::{Lex, Token, Tokens};
use crate::tree::Structure;

pub use crate::bounded::{HASH_OFFSET, HASH_PRIME, hash_of, hash_seeded};
pub use crate::diagnostic::{FileID, NONE};

pub const CLASS_BYTES_MIN: u32 = 1 << 10;
pub const CLASS_COUNT: usize = 13;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Eviction {
    LeastRecentlyUsed,
    Reject,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Limits {
    pub file_count_max: u32,
    pub front: front::Limits,
    pub line_count_max: u32,
    pub slots: [[u32; CLASS_COUNT]; Language::COUNT],
    pub source_bytes_max: u32,
}

pub struct Store {
    clock: u64,
    counter: u64,
    events: Box<Scratch>,
    eviction: Eviction,
    globals: [&'static [&'static [u8]]; Language::COUNT],
    index: Table,
    lexed: Tokens,
    limits: Limits,
    moves: u64,
    pending: Vec<u32>,
    python_version: PythonVersion,
    resident: u32,
    slots: Vec<Slot>,
    starts: [[u32; CLASS_COUNT]; Language::COUNT],
    template_imports: &'static [&'static [u8]],
}

struct Slot {
    class: u32,
    generation: u32,
    hash: u64,
    language: Language,
    lines: lines::Index,
    path_hash: u64,
    pending: AtomicBool,
    rebuilds: u32,
    resident: bool,
    sequence: u64,
    source: Buffer,
    structure: Structure,
    tables: Front,
    touch: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum State {
    Empty,
    Full,
    Removed,
}

struct Table {
    count: u32,
    count_max: u32,
    keys: Vec<u64>,
    states: Vec<State>,
    values: Vec<u32>,
}

impl Limits {
    pub const fn class_bytes(class: u32) -> u32 {
        assert!((class as usize) < CLASS_COUNT);

        CLASS_BYTES_MIN << class
    }

    pub fn class_of(bytes: u32) -> u32 {
        assert!(bytes <= Self::class_bytes(count_of(CLASS_COUNT) - 1));

        let mut class = 0;

        while Self::class_bytes(class) < bytes {
            class += 1;
        }

        assert!(Self::class_bytes(class) >= bytes);
        assert!(class == 0 || Self::class_bytes(class - 1) < bytes);

        class
    }

    pub fn class_top(&self) -> u32 {
        assert!(self.source_bytes_max >= CLASS_BYTES_MIN);
        assert!(self.source_bytes_max.is_power_of_two());

        let top = Self::class_of(self.source_bytes_max);

        assert_eq!(Self::class_bytes(top), self.source_bytes_max);

        top
    }

    pub fn slot_count(&self) -> u32 {
        let mut total = 0_u32;

        for classes in &self.slots {
            for count in classes {
                total = total.saturating_add(*count);
            }
        }

        total
    }

    pub fn slot_spec_of(&self, index: u32) -> (Language, u32) {
        assert!(index < self.file_count_max);
        assert_eq!(self.slot_count(), self.file_count_max);

        let mut at = 0_u32;

        for language in Language::EVERY {
            for (class, count) in self.slots[language.index()].iter().enumerate() {
                let next = at.saturating_add(*count);

                if index < next {
                    return (language, count_of(class));
                }

                at = next;
            }
        }

        unreachable!("a slot index below file_count_max lands in a populated class")
    }
}

impl Table {
    fn reserve(count_max: u32) -> Self {
        assert!(count_max > 0);

        assert!(!crate::allocation::is_frozen());

        let capacity = (count_max * 2).next_power_of_two();

        assert!(capacity >= count_max * 2);
        assert!(capacity.is_power_of_two());

        Self {
            count: 0,
            count_max,
            keys: vec![0; capacity as usize],
            states: vec![State::Empty; capacity as usize],
            values: vec![NONE; capacity as usize],
        }
    }

    fn clear(&mut self) {
        self.states.fill(State::Empty);

        self.count = 0;

        assert_eq!(self.count, 0);
    }

    fn get(&self, key: u64) -> u32 {
        let mut index = self.index_of(key);

        for _ in 0..self.states.len() {
            match self.states[index] {
                State::Empty => return NONE,
                State::Full => {
                    if self.keys[index] == key {
                        return self.values[index];
                    }
                }
                State::Removed => {}
            }

            index = self.index_next(index);
        }

        NONE
    }

    fn index_next(&self, index: usize) -> usize {
        assert!(index < self.states.len());

        (index + 1) & (self.states.len() - 1)
    }

    fn index_of(&self, key: u64) -> usize {
        let mask = self.states.len() as u64 - 1;
        let index = usize::try_from(mix_of(key) & mask).expect("the masked hash fits in usize");

        assert!(index < self.states.len());

        index
    }

    fn insert(&mut self, key: u64, value: u32) {
        assert!(value != NONE);
        assert!(self.count < self.count_max);

        let mut index = self.index_of(key);
        let mut vacancy = None;

        for _ in 0..self.states.len() {
            match self.states[index] {
                State::Empty => {
                    let target = vacancy.unwrap_or(index);

                    self.keys[target] = key;
                    self.states[target] = State::Full;
                    self.values[target] = value;
                    self.count += 1;

                    assert!(self.count <= self.count_max);

                    return;
                }
                State::Full => {
                    if self.keys[index] == key {
                        self.values[index] = value;

                        return;
                    }
                }
                State::Removed => {
                    if vacancy.is_none() {
                        vacancy = Some(index);
                    }
                }
            }

            index = self.index_next(index);
        }

        unreachable!()
    }

    fn remove(&mut self, key: u64) {
        let mut index = self.index_of(key);

        for _ in 0..self.states.len() {
            match self.states[index] {
                State::Empty => return,
                State::Full => {
                    if self.keys[index] == key {
                        self.states[index] = State::Removed;
                        self.count -= 1;

                        return;
                    }
                }
                State::Removed => {}
            }

            index = self.index_next(index);
        }
    }
}

impl Store {
    pub fn reserve(limits: &Limits, eviction: Eviction) -> Self {
        assert!(limits.file_count_max > 0);
        assert!(limits.line_count_max > 0);
        assert!(limits.source_bytes_max > 0);

        let top = limits.class_top();
        let mut wanted = [false; Language::COUNT];

        for (index, classes) in limits.slots.iter().enumerate() {
            for (class, count) in classes.iter().enumerate() {
                assert!(*count == 0 || class <= top as usize);

                wanted[index] |= *count > 0;
            }
        }

        assert_eq!(limits.slot_count(), limits.file_count_max);

        assert!(!crate::allocation::is_frozen());

        let mut specs = Vec::with_capacity(limits.file_count_max as usize);
        let mut starts = [[0_u32; CLASS_COUNT]; Language::COUNT];

        for language in Language::EVERY {
            for (index, start) in starts[language.index()].iter_mut().enumerate() {
                *start = count_of(specs.len());

                for _ in 0..limits.slots[language.index()][index] {
                    specs.push((language, count_of(index)));
                }
            }
        }

        assert_eq!(count_of(specs.len()), limits.file_count_max);

        let slots = striped(limits.file_count_max, |index| {
            let (language, class) = specs[index as usize];

            slot_of(language, class, top, limits)
        });

        assert_eq!(count_of(slots.len()), limits.file_count_max);

        Self {
            clock: 0,
            counter: 0,
            events: Box::new(Scratch::reserve(&limits.front, wanted)),
            eviction,
            globals: [&[]; Language::COUNT],
            index: Table::reserve(limits.file_count_max),
            lexed: Tokens::reserve(limits.front.token_count_max),
            limits: *limits,
            moves: 0,
            pending: Vec::with_capacity(limits.file_count_max as usize),
            python_version: PythonVersion::Py310,
            resident: 0,
            slots,
            starts,
            template_imports: &[],
        }
    }

    pub fn clear(&mut self) {
        for slot in &mut self.slots {
            slot.hash = 0;
            slot.path_hash = 0;
            slot.rebuilds = 0;
            slot.resident = false;
            slot.sequence = 0;
            slot.source.clear();
            slot.structure = Structure::Complete;
            slot.tables.clear();
            slot.touch = 0;

            slot.lines.clear();
            slot.pending.store(false, Ordering::Release);
        }

        self.pending.clear();

        self.clock = 0;
        self.counter = 0;
        self.moves += 1;
        self.resident = 0;
        self.index.clear();

        assert_eq!(self.count(), 0);
    }

    pub fn count(&self) -> u32 {
        let resident = self.resident;

        assert!(resident <= self.limits.file_count_max);

        resident
    }

    pub const fn moves(&self) -> u64 {
        self.moves
    }

    pub fn errors_of(&self, file: FileID) -> &[SyntaxError] {
        self.slot_of(file).tables.errors()
    }

    pub fn evict(&mut self, file: FileID) {
        let index = file.index();

        assert!(index < self.limits.file_count_max);
        assert!(self.slots[index as usize].resident);

        let path_hash = self.slots[index as usize].path_hash;

        self.index.remove(path_hash);
        self.release(index);

        assert!(!self.slots[index as usize].resident);
    }

    pub fn css_semantic(&self, file: FileID) -> Option<&CSSSemantic> {
        match self.slot_of(file).tables.tables() {
            Tables::Css { semantic, .. } => Some(semantic),
            Tables::Go { .. } => None,
            Tables::JavaScript { .. } => None,
            Tables::Markup { .. } => None,
            Tables::Odin { .. } => None,
            Tables::Python { .. } => None,
            Tables::Rust { .. } => None,
            Tables::TypeScript { .. } => None,
            Tables::Zig { .. } => None,
        }
    }

    pub fn go_semantic(&self, file: FileID) -> Option<&GoSemantic> {
        match self.slot_of(file).tables.tables() {
            Tables::Go { semantic, .. } => Some(semantic),
            Tables::Css { .. } => None,
            Tables::JavaScript { .. } => None,
            Tables::Markup { .. } => None,
            Tables::Odin { .. } => None,
            Tables::Python { .. } => None,
            Tables::Rust { .. } => None,
            Tables::TypeScript { .. } => None,
            Tables::Zig { .. } => None,
        }
    }

    pub fn javascript_semantic(&self, file: FileID) -> Option<&JavaScriptSemantic> {
        match self.slot_of(file).tables.tables() {
            Tables::JavaScript { semantic, .. } | Tables::TypeScript { semantic, .. } => {
                Some(semantic)
            }
            Tables::Css { .. } => None,
            Tables::Go { .. } => None,
            Tables::Markup { .. } => None,
            Tables::Odin { .. } => None,
            Tables::Python { .. } => None,
            Tables::Rust { .. } => None,
            Tables::Zig { .. } => None,
        }
    }

    pub fn odin_semantic(&self, file: FileID) -> Option<&OdinSemantic> {
        match self.slot_of(file).tables.tables() {
            Tables::Odin { semantic, .. } => Some(semantic),
            Tables::Css { .. } => None,
            Tables::Go { .. } => None,
            Tables::JavaScript { .. } => None,
            Tables::Markup { .. } => None,
            Tables::Python { .. } => None,
            Tables::Rust { .. } => None,
            Tables::TypeScript { .. } => None,
            Tables::Zig { .. } => None,
        }
    }

    pub fn python_checks_of(&self, file: FileID) -> &[PythonCheckError] {
        self.slot_of(file).tables.python_checks()
    }

    pub fn python_semantic(&self, file: FileID) -> Option<&PythonSemantic> {
        match self.slot_of(file).tables.tables() {
            Tables::Python { semantic, .. } => Some(semantic),
            Tables::Css { .. } => None,
            Tables::Go { .. } => None,
            Tables::JavaScript { .. } => None,
            Tables::Markup { .. } => None,
            Tables::Odin { .. } => None,
            Tables::Rust { .. } => None,
            Tables::TypeScript { .. } => None,
            Tables::Zig { .. } => None,
        }
    }

    pub fn rust_semantic(&self, file: FileID) -> Option<&RustSemantic> {
        match self.slot_of(file).tables.tables() {
            Tables::Rust { semantic, .. } => Some(semantic),
            Tables::Css { .. } => None,
            Tables::Go { .. } => None,
            Tables::JavaScript { .. } => None,
            Tables::Markup { .. } => None,
            Tables::Odin { .. } => None,
            Tables::Python { .. } => None,
            Tables::TypeScript { .. } => None,
            Tables::Zig { .. } => None,
        }
    }

    pub fn zig_semantic(&self, file: FileID) -> Option<&ZigSemantic> {
        match self.slot_of(file).tables.tables() {
            Tables::Zig { semantic, .. } => Some(semantic),
            Tables::Css { .. } => None,
            Tables::Go { .. } => None,
            Tables::JavaScript { .. } => None,
            Tables::Markup { .. } => None,
            Tables::Odin { .. } => None,
            Tables::Python { .. } => None,
            Tables::Rust { .. } => None,
            Tables::TypeScript { .. } => None,
        }
    }

    pub fn declaration_of(&self, file: FileID, name: &[u8]) -> u32 {
        let slot = self.slot_of(file);

        slot.tables.declaration_of(slot.source.as_bytes(), name)
    }

    pub fn facts_of(&self, file: FileID) -> &[Fact] {
        self.slot_of(file).tables.facts()
    }

    pub fn files(&self) -> impl Iterator<Item = FileID> {
        self.slots
            .iter()
            .enumerate()
            .filter(|(_, slot)| slot.resident)
            .map(|(index, _)| FileID::of(count_of(index)))
    }

    pub fn find(&self, path_hash: u64) -> u32 {
        let index = self.index.get(path_hash);

        if index == NONE {
            return NONE;
        }

        assert!(self.slots[index as usize].resident);

        index
    }

    pub fn globals_set(&mut self, language: Language, names: &'static [&'static [u8]]) {
        self.globals[language.index()] = names;

        assert_eq!(self.globals[language.index()].len(), names.len());
    }

    pub fn python_version_set(&mut self, version: PythonVersion) {
        self.python_version = version;

        assert_eq!(self.python_version, version);
    }

    pub fn template_imports_set(&mut self, names: &'static [&'static [u8]]) {
        self.template_imports = names;

        assert_eq!(self.template_imports.len(), names.len());
    }

    pub fn generation_of(&self, file: FileID) -> u32 {
        let index = file.index();

        assert!(index < self.limits.file_count_max);

        self.slots[index as usize].generation
    }

    pub fn hash_of(&self, file: FileID) -> u64 {
        self.slot_of(file).hash
    }

    pub fn insert(&mut self, path_hash: u64, language: Language, source: &[u8]) -> u32 {
        self.insert_with(path_hash, language, source, false, hash_of(source))
    }

    pub fn insert_pending(&mut self, path_hash: u64, language: Language, source: &[u8]) -> u32 {
        self.insert_with(path_hash, language, source, true, hash_of(source))
    }

    pub fn insert_pending_hashed(
        &mut self,
        path_hash: u64,
        language: Language,
        source: &[u8],
        hash: u64,
    ) -> u32 {
        debug_assert_eq!(hash, hash_of(source));

        self.insert_with(path_hash, language, source, true, hash)
    }

    fn insert_with(
        &mut self,
        path_hash: u64,
        language: Language,
        source: &[u8],
        deferred: bool,
        hash: u64,
    ) -> u32 {
        assert!(u32::try_from(source.len()).is_ok());

        if count_of(source.len()) > self.limits.source_bytes_max {
            return NONE;
        }

        let class = Limits::class_of(count_of(source.len()));
        let held = self.index.get(path_hash);

        if held != NONE {
            let slot = &self.slots[held as usize];

            assert!(slot.resident);

            if slot.language == language && slot.hash == hash {
                self.touch(FileID::of(held));

                return held;
            }

            if slot.language == language && slot.class >= class {
                self.settled(held, path_hash, hash, source, deferred);

                return held;
            }

            let moved = self.vacancy_of(language, class);

            if moved == NONE {
                return NONE;
            }

            self.index.remove(path_hash);
            self.release(held);
            self.settled(moved, path_hash, hash, source, deferred);
            self.index.insert(path_hash, moved);

            assert!(self.slots[moved as usize].resident);

            return moved;
        }

        let target = self.vacancy_of(language, class);

        if target == NONE {
            return NONE;
        }

        self.settled(target, path_hash, hash, source, deferred);
        self.index.insert(path_hash, target);

        assert!(self.slots[target as usize].resident);

        target
    }

    pub fn pending_builds(&mut self) -> PendingBuilds<'_> {
        let Self {
            globals,
            pending,
            python_version,
            slots,
            template_imports,
            ..
        } = self;

        let Some(base) = NonNull::new(slots.as_mut_ptr()) else {
            panic!("a reserved slot table hands back a non-null base")
        };

        PendingBuilds {
            globals: *globals,
            pending,
            python_version: *python_version,
            slot_count: count_of(slots.len()),
            slots: base,
            template_imports,
        }
    }

    pub fn pending_clear(&mut self) {
        for index in &self.pending {
            let slot = &self.slots[*index as usize];

            assert!(
                !slot.pending.load(Ordering::Acquire),
                "every pending slot was built before the list is cleared"
            );
        }

        self.pending.clear();
    }

    pub fn is_pending(&self, file: FileID) -> bool {
        let index = file.index();

        assert!(index < self.limits.file_count_max);

        self.slots[index as usize].pending.load(Ordering::Acquire)
    }

    pub fn pending_count(&self) -> u32 {
        count_of(self.pending.len())
    }

    pub fn language_of(&self, file: FileID) -> Language {
        self.slot_of(file).language
    }

    pub fn limits(&self) -> &Limits {
        &self.limits
    }

    pub fn lines_of(&self, file: FileID) -> &lines::Index {
        &self.slot_of(file).lines
    }

    pub fn markup_errors_of(&self, file: FileID) -> &[TreeError] {
        self.slot_of(file).tables.markup_errors()
    }

    pub fn markup_tree_of(&self, file: FileID) -> Option<&markup::tree::Tree> {
        match self.slot_of(file).tables.tables() {
            Tables::Markup { tree, .. } => Some(tree),
            Tables::Css { .. }
            | Tables::Go { .. }
            | Tables::JavaScript { .. }
            | Tables::Odin { .. }
            | Tables::Python { .. }
            | Tables::Rust { .. }
            | Tables::TypeScript { .. }
            | Tables::Zig { .. } => None,
        }
    }

    pub fn markup_tokens_of(&self, file: FileID) -> &[markup::Token] {
        match self.slot_of(file).tables.tables() {
            Tables::Markup { tokens, .. } => tokens.as_slice(),
            Tables::Css { .. }
            | Tables::Go { .. }
            | Tables::JavaScript { .. }
            | Tables::Odin { .. }
            | Tables::Python { .. }
            | Tables::Rust { .. }
            | Tables::TypeScript { .. }
            | Tables::Zig { .. } => &[],
        }
    }

    pub fn path_hash_of(&self, file: FileID) -> u64 {
        self.slot_of(file).path_hash
    }

    pub fn rebuilds_of(&self, file: FileID) -> u32 {
        self.slot_of(file).rebuilds
    }

    pub fn resident(&self, file: FileID) -> bool {
        let index = file.index();

        assert!(index < self.limits.file_count_max);

        self.slots[index as usize].resident
    }

    pub fn slot_bytes_of(&self, index: u32) -> u32 {
        assert!(index < self.limits.file_count_max);

        Limits::class_bytes(self.slots[index as usize].class)
    }

    pub fn slot_language_of(&self, index: u32) -> Language {
        assert!(index < self.limits.file_count_max);

        self.slots[index as usize].language
    }

    pub fn sequence_of(&self, file: FileID) -> u64 {
        let sequence = self.slot_of(file).sequence;

        assert!(sequence > 0);

        sequence
    }

    pub fn source_of(&self, file: FileID) -> &[u8] {
        self.slot_of(file).source.as_bytes()
    }

    pub(crate) fn tables_of(&self, file: FileID) -> &Front {
        &self.slot_of(file).tables
    }

    pub fn structure_of(&self, file: FileID) -> Structure {
        self.slot_of(file).structure
    }

    pub fn tokens_of(&self, file: FileID) -> &[Token] {
        self.slot_of(file).tables.tokens()
    }

    pub fn touch(&mut self, file: FileID) {
        let index = file.index();

        assert!(index < self.limits.file_count_max);
        assert!(self.slots[index as usize].resident);

        self.clock += 1;
        self.slots[index as usize].touch = self.clock;

        assert_eq!(self.slots[index as usize].touch, self.clock);
    }

    fn place(&mut self, index: u32, path_hash: u64, hash: u64, source: &[u8]) {
        assert!(index < self.limits.file_count_max);
        assert!(count_of(source.len()) <= self.limits.source_bytes_max);

        let Self {
            clock,
            counter,
            moves,
            resident,
            slots,
            ..
        } = self;

        *moves += 1;

        let slot = &mut slots[index as usize];
        let rebuilds = slot.rebuilds;

        assert!(count_of(source.len()) <= Limits::class_bytes(slot.class));
        assert!(!slot.pending.load(Ordering::Acquire));

        if !slot.resident {
            *counter += 1;
            slot.sequence = *counter;
            *resident += 1;
        }

        slot.lines.clear();
        slot.source.clear();
        slot.tables.clear();

        let written = slot.source.push_bytes(source);

        assert!(written);

        slot.generation = slot.generation.wrapping_add(1);
        slot.hash = hash;
        slot.path_hash = path_hash;
        slot.rebuilds = rebuilds + 1;
        slot.resident = true;
        slot.structure = Structure::Truncated;

        *clock += 1;
        slot.touch = *clock;

        assert!(slot.resident);
        assert_eq!(slot.rebuilds, rebuilds + 1);
    }

    fn rebuild(&mut self, index: u32, path_hash: u64, hash: u64, source: &[u8]) {
        self.place(index, path_hash, hash, source);

        let Self {
            events,
            globals,
            lexed,
            python_version,
            slots,
            template_imports,
            ..
        } = self;

        let slot = &mut slots[index as usize];

        build_slot(
            slot,
            events,
            lexed,
            globals,
            *python_version,
            template_imports,
        );
    }

    fn settled(&mut self, index: u32, path_hash: u64, hash: u64, source: &[u8], deferred: bool) {
        if !deferred {
            self.rebuild(index, path_hash, hash, source);

            return;
        }

        self.place(index, path_hash, hash, source);
        self.slots[index as usize]
            .pending
            .store(true, Ordering::Release);
        self.pending.push(index);

        assert!(count_of(self.pending.len()) <= self.limits.file_count_max);
    }

    fn release(&mut self, index: u32) {
        assert!(index < self.limits.file_count_max);

        assert!(
            !self.slots[index as usize].pending.load(Ordering::Acquire),
            "a slot is never released while its build is pending"
        );

        self.moves += 1;

        if self.slots[index as usize].resident {
            self.resident -= 1;
        }

        let slot = &mut self.slots[index as usize];

        slot.generation = slot.generation.wrapping_add(1);
        slot.hash = 0;
        slot.path_hash = 0;
        slot.resident = false;
        slot.sequence = 0;
        slot.source.clear();
        slot.structure = Structure::Complete;
        slot.tables.clear();
        slot.touch = 0;

        slot.lines.clear();

        assert!(!slot.resident);
    }

    fn slot_of(&self, file: FileID) -> &Slot {
        let index = file.index();

        assert!(index < self.limits.file_count_max);
        assert!(self.slots[index as usize].resident);

        &self.slots[index as usize]
    }

    fn vacancy_of(&mut self, language: Language, class: u32) -> u32 {
        let top = self.limits.class_top();

        assert!(class <= top);

        let mut oldest = NONE;
        let mut oldest_touch = u64::MAX;

        for held in class..=top {
            let start = self.starts[language.index()][held as usize];
            let count = self.limits.slots[language.index()][held as usize];

            for offset in 0..count {
                let index = start + offset;
                let slot = &self.slots[index as usize];

                if !slot.resident {
                    return index;
                }

                if slot.pending.load(Ordering::Acquire) {
                    continue;
                }

                if slot.touch < oldest_touch {
                    oldest = index;
                    oldest_touch = slot.touch;
                }
            }
        }

        if oldest == NONE || self.eviction == Eviction::Reject {
            return NONE;
        }

        self.evict(FileID::of(oldest));

        assert!(!self.slots[oldest as usize].resident);

        oldest
    }
}

pub struct BuildScratch {
    events: Box<Scratch>,
    lexed: Tokens,
}

impl BuildScratch {
    pub fn reserve(limits: &Limits) -> Self {
        assert!(!crate::allocation::is_frozen());

        let mut wanted = [false; Language::COUNT];

        for (index, classes) in limits.slots.iter().enumerate() {
            for count in classes {
                wanted[index] |= *count > 0;
            }
        }

        Self {
            events: Box::new(Scratch::reserve(&limits.front, wanted)),
            lexed: Tokens::reserve(limits.front.token_count_max),
        }
    }
}

pub struct PendingBuilds<'store> {
    globals: [&'static [&'static [u8]]; Language::COUNT],
    pending: &'store [u32],
    python_version: PythonVersion,
    slot_count: u32,
    slots: NonNull<Slot>,
    template_imports: &'static [&'static [u8]],
}

unsafe impl Send for PendingBuilds<'_> {}

unsafe impl Sync for PendingBuilds<'_> {}

impl PendingBuilds<'_> {
    pub fn build(&self, at: u32, scratch: &mut BuildScratch) {
        let index = self.pending[at as usize];

        assert!(index < self.slot_count);

        let mut held = unsafe { self.slots.add(index as usize) };
        let flag = unsafe { &held.as_ref().pending };
        let claimed = flag.swap(false, Ordering::AcqRel);

        assert!(claimed, "a pending slot is built exactly once");

        let slot = unsafe { held.as_mut() };

        build_slot(
            slot,
            &mut scratch.events,
            &mut scratch.lexed,
            &self.globals,
            self.python_version,
            self.template_imports,
        );
    }

    pub fn count(&self) -> u32 {
        count_of(self.pending.len())
    }
}

fn slot_of(language: Language, class: u32, top: u32, limits: &Limits) -> Slot {
    assert!(class <= top);

    let shift = top - class;
    let front = limits.front.shrunk(shift);

    Slot {
        class,
        generation: 0,
        hash: 0,
        language,
        lines: lines::Index::reserve(shrunk_of(limits.line_count_max, shift)),
        path_hash: 0,
        pending: AtomicBool::new(false),
        rebuilds: 0,
        resident: false,
        sequence: 0,
        source: Buffer::reserve(Limits::class_bytes(class)),
        structure: Structure::Complete,
        tables: Front::reserve(language, &front),
        touch: 0,
    }
}

fn build_slot(
    slot: &mut Slot,
    events: &mut Scratch,
    lexed: &mut Tokens,
    globals: &[&'static [&'static [u8]]; Language::COUNT],
    python_version: PythonVersion,
    template_imports: &[&[u8]],
) {
    let held = slot.source.as_bytes();
    let indexed = slot.lines.build(held);

    let options = Options {
        globals: globals[slot.language.index()],
        python_version,
        template_imports,
    };

    let built = if lexed_of(slot.language, held, lexed) {
        slot.tables.build(held, lexed.as_slice(), events, &options)
    } else {
        slot.tables.clear();

        Structure::Truncated
    };

    slot.structure = if indexed { built } else { Structure::Truncated };
}

fn lexed_of(language: Language, source: &[u8], out: &mut Tokens) -> bool {
    out.clear();

    assert_eq!(out.as_slice().len(), 0);

    let Some(lexer) = front::lexer_of(language) else {
        return true;
    };

    lexer.lex(source, out) == Lex::Complete
}

fn mix_of(key: u64) -> u64 {
    let mut hash = key;

    hash ^= hash >> 33;
    hash = hash.wrapping_mul(0xff51_afd7_ed55_8ccd);
    hash ^= hash >> 33;

    hash
}

#[cfg(test)]
mod tests {
    use super::*;

    const CSS: &[u8] = b"a { color: red; }\n";
    const PYTHON: &[u8] = b"import os\n\n\ndef run():\n    return os\n";
    const PYTHON_OTHER: &[u8] = b"import sys\n\n\ndef run():\n    return sys\n";
    const RUST: &[u8] = b"fn run() -> u32 {\n    1\n}\n";
    const TEMPLATE: &[u8] = b"<div>{% block body %}{% endblock %}</div>\n";

    fn limits_of(mix: &[(Language, u32)]) -> Limits {
        let mut slots = [[0_u32; CLASS_COUNT]; Language::COUNT];
        let mut total = 0;

        for (language, count) in mix {
            slots[language.index()][Limits::class_of(4_096) as usize] = *count;
            total += *count;
        }

        Limits {
            file_count_max: total,
            front: front::Limits {
                binding_count_max: 256,
                error_count_max: 64,
                event_count_max: 4_096,
                export_count_max: 256,
                fact_count_max: 256,
                node_count_max: 2_048,
                reference_count_max: 256,
                scope_count_max: 64,
                segment_count_max: 256,
                token_count_max: 1_024,
            },
            line_count_max: 256,
            slots,
            source_bytes_max: 4_096,
        }
    }

    #[test]
    fn an_insert_reads_back() {
        let limits = limits_of(&[(Language::Python, 2)]);
        let mut store = Store::reserve(&limits, Eviction::Reject);
        let index = store.insert(hash_of(b"a.py"), Language::Python, PYTHON);

        assert!(index != NONE);

        let file = FileID::of(index);

        assert_eq!(store.count(), 1);
        assert_eq!(store.source_of(file), PYTHON);
        assert_eq!(store.language_of(file), Language::Python);
        assert_eq!(store.structure_of(file), Structure::Complete);
        assert_eq!(store.hash_of(file), hash_of(PYTHON));
        assert_eq!(store.find(hash_of(b"a.py")), index);
        assert_eq!(store.find(hash_of(b"b.py")), NONE);
        assert!(store.errors_of(file).is_empty());
        assert!(!store.tokens_of(file).is_empty());
        assert_eq!(store.lines_of(file).count(), 6);
    }

    #[test]
    fn an_eviction_never_takes_a_slot_whose_build_is_pending() {
        let limits = limits_of(&[(Language::Python, 2)]);
        let mut store = Store::reserve(&limits, Eviction::LeastRecentlyUsed);
        let first = store.insert_pending(hash_of(b"a.py"), Language::Python, PYTHON);
        let second = store.insert_pending(hash_of(b"b.py"), Language::Python, PYTHON_OTHER);

        assert!(first != NONE);
        assert!(second != NONE);
        assert!(store.is_pending(FileID::of(first)));
        assert!(store.is_pending(FileID::of(second)));

        let third = store.insert_pending(hash_of(b"c.py"), Language::Python, PYTHON);

        assert_eq!(
            third, NONE,
            "a store whose every slot is waiting on a build has no room, and \
             answering with a pending slot would drop a build the caller is \
             about to run"
        );

        assert!(store.is_pending(FileID::of(first)));
        assert!(store.is_pending(FileID::of(second)));
        assert_eq!(store.pending_count(), 2);
    }

    #[test]
    fn an_eviction_passes_over_a_pending_slot_for_a_settled_one() {
        let limits = limits_of(&[(Language::Python, 2)]);
        let mut store = Store::reserve(&limits, Eviction::LeastRecentlyUsed);
        let settled = store.insert(hash_of(b"a.py"), Language::Python, PYTHON);
        let waiting = store.insert_pending(hash_of(b"b.py"), Language::Python, PYTHON_OTHER);

        assert!(settled != NONE);
        assert!(waiting != NONE);

        let third = store.insert(hash_of(b"c.py"), Language::Python, PYTHON);

        assert_eq!(
            third, settled,
            "the settled slot is the older one and the only one free to take"
        );

        assert!(store.is_pending(FileID::of(waiting)));
        assert_eq!(store.find(hash_of(b"a.py")), NONE);
        assert_eq!(store.find(hash_of(b"b.py")), waiting);
        assert_eq!(store.find(hash_of(b"c.py")), third);
    }

    #[test]
    fn identical_bytes_reuse_the_slot_without_a_rebuild() {
        let limits = limits_of(&[(Language::Python, 2)]);
        let mut store = Store::reserve(&limits, Eviction::Reject);
        let first = store.insert(hash_of(b"a.py"), Language::Python, PYTHON);
        let again = store.insert(hash_of(b"a.py"), Language::Python, PYTHON);

        assert_eq!(first, again);
        assert_eq!(store.count(), 1);
        assert_eq!(store.rebuilds_of(FileID::of(first)), 1);
    }

    #[test]
    fn changed_bytes_rebuild_the_same_slot() {
        let limits = limits_of(&[(Language::Python, 2)]);
        let mut store = Store::reserve(&limits, Eviction::Reject);
        let first = store.insert(hash_of(b"a.py"), Language::Python, PYTHON);
        let again = store.insert(hash_of(b"a.py"), Language::Python, PYTHON_OTHER);
        let file = FileID::of(again);

        assert_eq!(first, again);
        assert_eq!(store.count(), 1);
        assert_eq!(store.rebuilds_of(file), 2);
        assert_eq!(store.source_of(file), PYTHON_OTHER);
        assert_eq!(store.hash_of(file), hash_of(PYTHON_OTHER));
    }

    #[test]
    fn a_full_store_rejects_under_reject() {
        let limits = limits_of(&[(Language::Python, 1)]);
        let mut store = Store::reserve(&limits, Eviction::Reject);
        let first = store.insert(hash_of(b"a.py"), Language::Python, PYTHON);
        let second = store.insert(hash_of(b"b.py"), Language::Python, PYTHON_OTHER);

        assert!(first != NONE);
        assert_eq!(second, NONE);
        assert_eq!(store.count(), 1);
        assert_eq!(store.find(hash_of(b"a.py")), first);
        assert_eq!(store.find(hash_of(b"b.py")), NONE);
    }

    #[test]
    fn a_full_store_evicts_the_least_recently_touched_slot() {
        let limits = limits_of(&[(Language::Python, 2)]);
        let mut store = Store::reserve(&limits, Eviction::LeastRecentlyUsed);
        let first = store.insert(hash_of(b"a.py"), Language::Python, PYTHON);
        let second = store.insert(hash_of(b"b.py"), Language::Python, PYTHON_OTHER);

        store.touch(FileID::of(first));

        let third = store.insert(hash_of(b"c.py"), Language::Python, PYTHON);

        assert_eq!(third, second);
        assert_eq!(store.count(), 2);
        assert_eq!(store.find(hash_of(b"a.py")), first);
        assert_eq!(store.find(hash_of(b"b.py")), NONE);
        assert_eq!(store.find(hash_of(b"c.py")), third);
    }

    #[test]
    fn an_eviction_frees_the_slot_for_the_next_insert() {
        let limits = limits_of(&[(Language::Python, 1)]);
        let mut store = Store::reserve(&limits, Eviction::Reject);
        let first = store.insert(hash_of(b"a.py"), Language::Python, PYTHON);

        store.evict(FileID::of(first));

        assert_eq!(store.count(), 0);
        assert_eq!(store.find(hash_of(b"a.py")), NONE);

        let second = store.insert(hash_of(b"b.py"), Language::Python, PYTHON_OTHER);

        assert_eq!(second, first);
        assert_eq!(store.count(), 1);
        assert_eq!(store.source_of(FileID::of(second)), PYTHON_OTHER);
    }

    #[test]
    fn a_store_holds_several_languages_at_once() {
        let limits = limits_of(&[
            (Language::Css, 1),
            (Language::Markup, 1),
            (Language::Python, 1),
            (Language::Rust, 1),
        ]);

        let mut store = Store::reserve(&limits, Eviction::Reject);
        let css = store.insert(hash_of(b"a.css"), Language::Css, CSS);
        let markup = store.insert(hash_of(b"a.html"), Language::Markup, TEMPLATE);
        let python = store.insert(hash_of(b"a.py"), Language::Python, PYTHON);
        let rust = store.insert(hash_of(b"a.rs"), Language::Rust, RUST);

        assert_eq!(store.count(), 4);
        assert_eq!(store.structure_of(FileID::of(css)), Structure::Complete);
        assert_eq!(store.structure_of(FileID::of(markup)), Structure::Complete);
        assert_eq!(store.structure_of(FileID::of(python)), Structure::Complete);
        assert_eq!(store.structure_of(FileID::of(rust)), Structure::Complete);
        assert!(store.tokens_of(FileID::of(markup)).is_empty());
        assert!(!store.markup_tokens_of(FileID::of(markup)).is_empty());
        assert!(store.markup_errors_of(FileID::of(markup)).is_empty());
    }

    #[test]
    fn a_language_with_no_slots_refuses_every_insert() {
        let limits = limits_of(&[(Language::Python, 1)]);
        let mut store = Store::reserve(&limits, Eviction::LeastRecentlyUsed);

        assert_eq!(store.insert(hash_of(b"a.rs"), Language::Rust, RUST), NONE);
        assert_eq!(store.count(), 0);
    }

    #[test]
    fn a_source_past_the_byte_limit_is_refused() {
        let limits = limits_of(&[(Language::Python, 1)]);
        let mut store = Store::reserve(&limits, Eviction::Reject);
        let long = [b'#'; 4_097];

        assert_eq!(
            store.insert(hash_of(b"a.py"), Language::Python, &long),
            NONE
        );

        assert_eq!(store.count(), 0);
    }

    fn classed_limits() -> Limits {
        let mut limits = limits_of(&[(Language::Python, 0)]);

        limits.slots[Language::Python.index()][0] = 1;
        limits.slots[Language::Python.index()][2] = 1;
        limits.file_count_max = 2;

        limits
    }

    #[test]
    fn a_file_lands_in_the_smallest_class_that_holds_it() {
        let limits = classed_limits();
        let mut store = Store::reserve(&limits, Eviction::Reject);
        let small = store.insert(hash_of(b"a.py"), Language::Python, PYTHON);
        let long = [b'#'; 2_048];
        let large = store.insert(hash_of(b"b.py"), Language::Python, &long);

        assert_eq!(small, 0);
        assert_eq!(large, 1);
        assert_eq!(store.slot_bytes_of(small), 1_024);
        assert_eq!(store.slot_bytes_of(large), 4_096);
        assert_eq!(store.count(), 2);
    }

    #[test]
    fn a_small_file_borrows_a_larger_slot_when_its_class_is_full() {
        let limits = classed_limits();
        let mut store = Store::reserve(&limits, Eviction::Reject);
        let first = store.insert(hash_of(b"a.py"), Language::Python, PYTHON);
        let second = store.insert(hash_of(b"b.py"), Language::Python, PYTHON_OTHER);
        let long = [b'#'; 2_048];
        let third = store.insert(hash_of(b"c.py"), Language::Python, &long);

        assert_eq!(first, 0);
        assert_eq!(second, 1);
        assert_eq!(third, NONE);
        assert_eq!(store.count(), 2);
    }

    #[test]
    fn a_file_that_outgrows_its_slot_moves_to_a_larger_one() {
        let limits = classed_limits();
        let mut store = Store::reserve(&limits, Eviction::Reject);
        let first = store.insert(hash_of(b"a.py"), Language::Python, PYTHON);
        let long = [b'#'; 2_048];
        let moved = store.insert(hash_of(b"a.py"), Language::Python, &long);

        assert_eq!(first, 0);
        assert_eq!(moved, 1);
        assert_eq!(store.count(), 1);
        assert_eq!(store.find(hash_of(b"a.py")), moved);
        assert!(!store.resident(FileID::of(first)));
        assert_eq!(store.source_of(FileID::of(moved)), &long[..]);
    }

    #[test]
    fn a_file_that_shrinks_keeps_its_slot() {
        let limits = classed_limits();
        let mut store = Store::reserve(&limits, Eviction::Reject);
        let long = [b'#'; 2_048];
        let first = store.insert(hash_of(b"a.py"), Language::Python, &long);
        let again = store.insert(hash_of(b"a.py"), Language::Python, PYTHON);

        assert_eq!(first, 1);
        assert_eq!(again, first);
        assert_eq!(store.count(), 1);
        assert_eq!(store.rebuilds_of(FileID::of(again)), 2);
    }

    #[test]
    fn clear_empties_every_slot() {
        let limits = limits_of(&[(Language::Python, 2)]);
        let mut store = Store::reserve(&limits, Eviction::Reject);

        store.insert(hash_of(b"a.py"), Language::Python, PYTHON);
        store.insert(hash_of(b"b.py"), Language::Python, PYTHON_OTHER);
        store.clear();

        assert_eq!(store.count(), 0);
        assert_eq!(store.find(hash_of(b"a.py")), NONE);

        let again = store.insert(hash_of(b"a.py"), Language::Python, PYTHON);

        assert!(again != NONE);
        assert_eq!(store.rebuilds_of(FileID::of(again)), 1);
    }

    #[test]
    #[should_panic(expected = "resident")]
    fn an_accessor_rejects_a_vacant_slot() {
        let limits = limits_of(&[(Language::Python, 1)]);
        let store = Store::reserve(&limits, Eviction::Reject);
        let _ = store.source_of(FileID::of(0));
    }
}
