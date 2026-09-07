use crate::bounded::{BoundedVec, FixedMap, Span, count_of};
use crate::diagnostic::{Diagnostic, Diagnostics, FileID, Message, Related, Severity};
use crate::fix::{Applicability, Fixes};
use crate::json::{Cursor, Kind};
use crate::lines;
use crate::suppress::Regions;
use crate::timing::Clock;

pub const NONE: u32 = u32::MAX;
pub const CODE_TEXT_BYTES_MAX: usize = 8;
pub const RULE_COUNT_MAX: u32 = 128;
const ALL: &[u8] = b"ALL";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Citation {
    pub standard: &'static str,
    pub text: &'static str,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Fixable {
    Always,
    Never,
    Sometimes,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Group {
    Deprecated,
    Preview,
    Removed,
    Stable,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Preview {
    pub enabled: bool,
    pub explicit: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Rule {
    pub citations: &'static [Citation],
    pub code: &'static str,
    pub default_on: bool,
    pub description: &'static str,
    pub explanation: &'static str,
    pub fix_title: &'static str,
    pub fixable: Fixable,
    pub group: Group,
    pub name: &'static str,
    pub severity: Severity,
    pub summary: &'static str,
    pub url: &'static str,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct CodeSet {
    bits: u128,
}

#[derive(Debug)]
pub struct Registry {
    by_code: FixedMap<u32>,
    rules: BoundedVec<Rule>,
}

pub trait Contextual {
    type Context<'run>;
}

pub type Run<R> = fn(&<R as Contextual>::Context<'_>, &mut Sink<'_>);

#[derive(Debug)]
pub struct Entry<R: Contextual> {
    pub languages: u64,
    pub run: Run<R>,
}

pub trait Policy {
    fn applicability_of(&self, rule: u32) -> Option<Applicability>;
    fn enables(&self, rule: u32) -> bool;
    fn fixes(&self, rule: u32) -> bool;
    fn severity_of(&self, rule: u32, default: Severity) -> Severity;
}

#[derive(Debug)]
pub struct Runner<R: Contextual> {
    entries: BoundedVec<Entry<R>>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SelectorsFault {
    Selector,
    Value,
}

pub struct Tables<'run> {
    pub diagnostics: &'run mut Diagnostics,
    pub file: FileID,
    pub fixes: &'run mut Fixes,
    pub lines: &'run lines::Index,
    pub registry: &'run Registry,
    pub suppressions: &'run mut Regions,
}

#[derive(Clone, Copy, Debug)]
pub struct Timings<const STAGE_COUNT: usize> {
    documents: u64,
    rules: [u64; RULE_COUNT_MAX as usize],
    stages: [u64; STAGE_COUNT],
}

impl Fixable {
    pub const fn applicability(self) -> Applicability {
        match self {
            Self::Always | Self::Sometimes => Applicability::Safe,
            Self::Never => Applicability::DisplayOnly,
        }
    }

    pub const fn is_offered(self) -> bool {
        matches!(self, Self::Always | Self::Sometimes)
    }

    pub const fn name(self) -> &'static str {
        match self {
            Self::Always => "always",
            Self::Never => "never",
            Self::Sometimes => "sometimes",
        }
    }
}

impl Group {
    pub const fn name(self) -> &'static str {
        match self {
            Self::Deprecated => "deprecated",
            Self::Preview => "preview",
            Self::Removed => "removed",
            Self::Stable => "stable",
        }
    }
}

impl Rule {
    pub const fn is_preview(&self) -> bool {
        matches!(self.group, Group::Preview)
    }
}

impl CodeSet {
    pub const EMPTY: Self = Self { bits: 0 };

    pub fn with_all(count: u32) -> Self {
        assert!(count <= RULE_COUNT_MAX);

        if count == RULE_COUNT_MAX {
            return Self { bits: u128::MAX };
        }

        Self {
            bits: (1_u128 << count) - 1,
        }
    }

    pub const fn of_bits(bits: u128) -> Self {
        Self { bits }
    }

    pub const fn bits(self) -> u128 {
        self.bits
    }

    pub fn contains(self, rule: u32) -> bool {
        assert!(rule < RULE_COUNT_MAX);

        self.bits & (1_u128 << rule) != 0
    }

    pub fn insert(&mut self, rule: u32) {
        assert!(rule < RULE_COUNT_MAX);

        self.bits |= 1_u128 << rule;
    }

    pub fn remove(&mut self, rule: u32) {
        assert!(rule < RULE_COUNT_MAX);

        self.bits &= !(1_u128 << rule);
    }
}

impl Registry {
    pub fn reserve_from(rules: &[&Rule], count_max: u32) -> Self {
        assert!(count_max > 0);
        assert!(count_max <= RULE_COUNT_MAX);
        assert!(count_of(rules.len()) <= count_max);
        assert!(!crate::allocation::is_frozen());

        let mut registry = Self {
            by_code: FixedMap::reserve(count_max),
            rules: BoundedVec::reserve(count_max),
        };

        for rule in rules {
            registry.register(rule);
        }

        assert_eq!(registry.count() as usize, rules.len());

        registry
    }

    pub fn reserve(rules: &[Rule]) -> Self {
        assert!(!rules.is_empty());

        let held: Vec<&Rule> = rules.iter().collect();

        Self::reserve_from(&held, count_of(rules.len()))
    }

    pub fn register(&mut self, rule: &Rule) {
        assert!(!crate::allocation::is_frozen());

        let index = self.rules.count();
        assert!(code_number_of(rule.code.as_bytes()).is_some());
        assert!(!rule.name.is_empty());
        assert!(self.by_code.get(rule.code.as_bytes()).is_none());

        self.by_code.insert_assert(rule.code.as_bytes(), index);
        self.rules.push_assert(*rule);

        assert_eq!(self.count(), index + 1);
    }

    pub fn at(&self, index: u32) -> &Rule {
        assert!(index < self.count());

        &self.rules[index as usize]
    }

    pub fn count(&self) -> u32 {
        self.rules.count()
    }

    pub fn find(&self, code: &[u8]) -> Option<&Rule> {
        let index = self.index_of_code(code);

        if index == NONE {
            return None;
        }

        Some(&self.rules[index as usize])
    }

    pub fn get(&self, code: &str) -> Option<&Rule> {
        self.find(code.as_bytes())
    }

    pub fn find_name(&self, name: &[u8]) -> Option<&Rule> {
        let index = self.index_of_name(name);

        if index == NONE {
            return None;
        }

        Some(&self.rules[index as usize])
    }

    pub fn index_of(&self, code: &str) -> u32 {
        self.index_of_code(code.as_bytes())
    }

    pub fn index_of_code(&self, code: &[u8]) -> u32 {
        if code.is_empty() {
            return NONE;
        }

        self.by_code.get(code).unwrap_or(NONE)
    }

    pub fn index_of_name(&self, name: &[u8]) -> u32 {
        if name.is_empty() {
            return NONE;
        }

        for index in 0..self.count() {
            if self.rules[index as usize].name.as_bytes() == name {
                return index;
            }
        }

        NONE
    }

    pub fn rules(&self) -> impl Iterator<Item = &Rule> {
        self.rules.iter()
    }
}

impl<R: Contextual> Runner<R> {
    pub fn at(&self, index: u32) -> &Entry<R> {
        assert!(index < self.count());

        &self.entries[index as usize]
    }

    pub fn count(&self) -> u32 {
        self.entries.count()
    }

    pub fn covers(&self, index: u32, language: u32) -> bool {
        assert!(language < u64::BITS);

        self.at(index).languages & (1_u64 << language) != 0
    }

    pub fn register(&mut self, languages: u64, run: Run<R>) {
        assert!(!crate::allocation::is_frozen());

        let index = self.entries.count();

        assert!(index < RULE_COUNT_MAX);

        self.entries.push_assert(Entry { languages, run });

        assert_eq!(self.count(), index + 1);
    }

    pub fn reserve(rule_count_max: u32) -> Self {
        assert!(rule_count_max > 0);
        assert!(rule_count_max <= RULE_COUNT_MAX);
        assert!(!crate::allocation::is_frozen());

        Self {
            entries: BoundedVec::reserve(rule_count_max),
        }
    }

    pub fn run<const STAGE_COUNT: usize>(
        &self,
        language: u32,
        context: &R::Context<'_>,
        policy: &impl Policy,
        tables: Tables<'_>,
        timings: &mut Timings<STAGE_COUNT>,
    ) {
        assert!(self.count() <= tables.registry.count());

        self.run_with(language, context, policy, tables, timings, Some);
    }

    pub fn run_with<const STAGE_COUNT: usize>(
        &self,
        language: u32,
        context: &R::Context<'_>,
        policy: &impl Policy,
        tables: Tables<'_>,
        timings: &mut Timings<STAGE_COUNT>,
        rule_of: impl Fn(u32) -> Option<u32>,
    ) {
        assert!(language < u64::BITS);

        let Tables {
            diagnostics,
            file,
            fixes,
            lines,
            registry,
            suppressions,
        } = tables;

        for index in 0..self.count() {
            let run = self.entries[index as usize].run;

            let Some(code) = rule_of(index) else {
                continue;
            };

            assert!(code < registry.count());

            if !self.covers(index, language) || !policy.enables(code) {
                continue;
            }

            let rule = registry.at(code);

            let mut sink = Sink::open(Opened {
                applicability: policy.applicability_of(code),
                code: rule.code,
                code_index: code,
                diagnostics: &mut *diagnostics,
                file,
                fixable: policy.fixes(code),
                fixes: &mut *fixes,
                lines,
                severity: policy.severity_of(code, rule.severity),
                suppressions: &mut *suppressions,
            });

            let clock = Clock::start();

            run(context, &mut sink);

            timings.rule_add(code, clock.nanoseconds());
        }
    }
}

impl<const STAGE_COUNT: usize> Timings<STAGE_COUNT> {
    pub const fn document_record(&mut self) {
        self.documents = self.documents.saturating_add(1);
    }

    pub const fn documents(&self) -> u64 {
        self.documents
    }

    pub const fn new() -> Self {
        Self {
            documents: 0,
            rules: [0; RULE_COUNT_MAX as usize],
            stages: [0; STAGE_COUNT],
        }
    }

    pub const fn rule_add(&mut self, code: u32, nanoseconds: u64) {
        assert!(code < RULE_COUNT_MAX);

        self.rules[code as usize] = self.rules[code as usize].saturating_add(nanoseconds);
    }

    pub const fn rule_at(&self, code: u32) -> u64 {
        assert!(code < RULE_COUNT_MAX);

        self.rules[code as usize]
    }

    pub const fn stage_add(&mut self, stage: usize, nanoseconds: u64) {
        assert!(stage < STAGE_COUNT);

        self.stages[stage] = self.stages[stage].saturating_add(nanoseconds);
    }

    pub const fn stage_at(&self, stage: usize) -> u64 {
        assert!(stage < STAGE_COUNT);

        self.stages[stage]
    }

    pub fn total(&self) -> u64 {
        let mut total = 0_u64;

        for stage in self.stages {
            total = total.saturating_add(stage);
        }

        assert!(self.stages.iter().all(|stage| *stage <= total));

        total
    }
}

impl<const STAGE_COUNT: usize> Default for Timings<STAGE_COUNT> {
    fn default() -> Self {
        Self::new()
    }
}

pub struct Sink<'run> {
    applicability: Option<Applicability>,
    code: &'static str,
    code_index: u32,
    diagnostics: &'run mut Diagnostics,
    file: FileID,
    fix_failed: bool,
    fixable: bool,
    fixes: &'run mut Fixes,
    lines: &'run lines::Index,
    severity: Severity,
    suppressions: &'run mut Regions,
}

pub struct Opened<'run> {
    pub applicability: Option<Applicability>,
    pub code: &'static str,
    pub code_index: u32,
    pub diagnostics: &'run mut Diagnostics,
    pub file: FileID,
    pub fixable: bool,
    pub fixes: &'run mut Fixes,
    pub lines: &'run lines::Index,
    pub severity: Severity,
    pub suppressions: &'run mut Regions,
}

impl<'run> Sink<'run> {
    pub fn open(opened: Opened<'run>) -> Self {
        let Opened {
            applicability,
            code,
            code_index,
            diagnostics,
            file,
            fixable,
            fixes,
            lines,
            severity,
            suppressions,
        } = opened;

        Self {
            applicability,
            code,
            code_index,
            diagnostics,
            file,
            fix_failed: false,
            fixable,
            fixes,
            lines,
            severity,
            suppressions,
        }
    }

    pub const fn file(&self) -> FileID {
        self.file
    }

    pub const fn code(&self) -> &'static str {
        self.code
    }

    pub const fn code_index(&self) -> u32 {
        self.code_index
    }

    pub const fn severity(&self) -> Severity {
        self.severity
    }

    pub const fn suppressions(&mut self) -> &mut Regions {
        self.suppressions
    }

    pub fn fix_begin(&mut self, title: &'static str, applicability: Applicability, isolation: u32) {
        self.fixes.open(
            title,
            self.applicability.unwrap_or(applicability),
            isolation,
        );

        self.fix_failed = false;
    }

    pub fn fix_begin_formatted(
        &mut self,
        applicability: Applicability,
        isolation: u32,
        arguments: core::fmt::Arguments<'_>,
    ) {
        self.fixes.open_formatted(
            self.applicability.unwrap_or(applicability),
            isolation,
            arguments,
        );

        self.fix_failed = false;
    }

    pub fn fix_discard(&mut self) {
        self.fixes.discard();

        self.fix_failed = false;
    }

    pub fn fix_edit(&mut self, span: Span, replacement: &[u8]) {
        if !self.fixes.edit(span, replacement) {
            self.fix_failed = true;
        }
    }

    pub fn fix_edit_formatted(&mut self, span: Span, arguments: core::fmt::Arguments<'_>) {
        if !self.fixes.edit_formatted(span, arguments) {
            self.fix_failed = true;
        }
    }

    pub fn related(&mut self, file: FileID, span: Span, text: &'static str) -> bool {
        self.diagnostics.push_related(Related {
            file,
            message: Message::Static(text),
            span,
        })
    }

    pub fn related_count(&self) -> u32 {
        self.diagnostics.related_count()
    }

    pub fn related_formatted(
        &mut self,
        file: FileID,
        span: Span,
        arguments: core::fmt::Arguments<'_>,
    ) -> bool {
        self.diagnostics
            .push_related_formatted(file, span, arguments)
    }

    pub fn report(&mut self, span: Span, text: &'static str) {
        if self.suppression_claimed(span) {
            return;
        }

        let _ = self.diagnostics.push(Diagnostic {
            code: self.code,
            fix: crate::fix::NONE,
            message: Message::Static(text),
            related_count: 0,
            related_start: 0,
            rule: self.code_index,
            severity: self.severity,
            span,
        });
    }

    pub fn report_row(&mut self, row: Diagnostic) -> bool {
        if self.suppression_claimed(row.span) {
            return false;
        }

        self.diagnostics.push(self.rowed(row))
    }

    pub fn report_row_formatted(
        &mut self,
        row: Diagnostic,
        arguments: core::fmt::Arguments<'_>,
    ) -> bool {
        if self.suppression_claimed(row.span) {
            return false;
        }

        let held = self.rowed(row);

        self.diagnostics.push_formatted_row(held, arguments)
    }

    pub fn report_formatted(&mut self, span: Span, arguments: core::fmt::Arguments<'_>) {
        if self.suppression_claimed(span) {
            return;
        }

        let row = self.rowed(Diagnostic {
            code: self.code,
            fix: crate::fix::NONE,
            message: Message::Static(""),
            related_count: 0,
            related_start: 0,
            rule: self.code_index,
            severity: self.severity,
            span,
        });

        let _ = self.diagnostics.push_formatted_row(row, arguments);
    }

    pub fn report_fixed(&mut self, span: Span, text: &'static str) {
        let Some(fix) = self.fix_settled(span) else {
            return;
        };

        let _ = self.diagnostics.push(Diagnostic {
            code: self.code,
            fix,
            message: Message::Static(text),
            related_count: 0,
            related_start: 0,
            rule: self.code_index,
            severity: self.severity,
            span,
        });
    }

    pub fn report_fixed_formatted(&mut self, span: Span, arguments: core::fmt::Arguments<'_>) {
        let Some(row) = self.fixed_row(span, 0, 0) else {
            return;
        };

        let _ = self.diagnostics.push_formatted_row(row, arguments);
    }

    pub fn report_fixed_related_formatted(
        &mut self,
        span: Span,
        related_start: u32,
        arguments: core::fmt::Arguments<'_>,
    ) {
        let related_count = self.related_count().saturating_sub(related_start);

        let Some(row) = self.fixed_row(span, related_start, related_count) else {
            return;
        };

        let _ = self.diagnostics.push_formatted_row(row, arguments);
    }

    fn fixed_row(
        &mut self,
        span: Span,
        related_start: u32,
        related_count: u32,
    ) -> Option<Diagnostic> {
        let fix = self.fix_settled(span)?;

        Some(Diagnostic {
            code: self.code,
            fix,
            message: Message::Static(""),
            related_count,
            related_start,
            rule: self.code_index,
            severity: self.severity,
            span,
        })
    }

    fn rowed(&self, row: Diagnostic) -> Diagnostic {
        Diagnostic {
            code: self.code,
            rule: self.code_index,
            severity: row.severity.min(self.severity),
            ..row
        }
    }

    fn fix_settled(&mut self, span: Span) -> Option<u32> {
        let suppressed = self.suppression_claimed(span);

        if suppressed || self.fix_failed || !self.fixable {
            self.fixes.discard();

            if suppressed {
                return None;
            }

            return Some(crate::fix::NONE);
        }

        Some(self.fixes.close())
    }

    fn suppression_claimed(&mut self, span: Span) -> bool {
        let line = self.lines.line_of(span.offset);

        self.suppressions.claim(line, self.code_index)
    }
}

pub fn code_number_of(code: &[u8]) -> Option<u32> {
    if code.len() > CODE_TEXT_BYTES_MAX {
        return None;
    }

    let letters = code_prefix_of(code).len();

    if letters == 0 || letters == code.len() {
        return None;
    }

    let mut value = 0_u32;

    for digit in &code[letters..] {
        if !digit.is_ascii_digit() {
            return None;
        }

        value = value * 10 + u32::from(digit - b'0');
    }

    Some(value)
}

pub fn code_prefix_of(code: &[u8]) -> &[u8] {
    let letters = code
        .iter()
        .take_while(|byte| byte.is_ascii_uppercase())
        .count();

    &code[..letters]
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Selector {
    length: u8,
    text: [u8; CODE_TEXT_BYTES_MAX],
}

#[derive(Debug)]
pub struct Selection {
    pub extend_fixable: BoundedVec<Selector>,
    pub extend_select: BoundedVec<Selector>,
    pub external: BoundedVec<Selector>,
    pub fixable: BoundedVec<Selector>,
    pub fixable_replaced: bool,
    pub ignore: BoundedVec<Selector>,
    pub preview: Preview,
    pub select: BoundedVec<Selector>,
    pub selected: bool,
    pub unfixable: BoundedVec<Selector>,
}

impl Selector {
    pub const ALL: Self = Self {
        length: 0,
        text: [0; CODE_TEXT_BYTES_MAX],
    };

    pub fn of(text: &[u8]) -> Option<Self> {
        if text == ALL {
            return Some(Self::ALL);
        }

        if text.is_empty() || text.len() > CODE_TEXT_BYTES_MAX {
            return None;
        }

        let mut held = [0_u8; CODE_TEXT_BYTES_MAX];

        held[..text.len()].copy_from_slice(text);

        Some(Self {
            length: u8::try_from(text.len()).ok()?,
            text: held,
        })
    }

    pub fn as_bytes(&self) -> &[u8] {
        &self.text[..self.length as usize]
    }

    pub const fn is_all(&self) -> bool {
        self.length == 0
    }

    pub fn is_exact(&self, code: &str) -> bool {
        self.as_bytes() == code.as_bytes()
    }

    pub fn matches(&self, code: &str) -> bool {
        code.as_bytes().starts_with(self.as_bytes())
    }

    pub const fn specificity(&self) -> u8 {
        self.length
    }
}

impl Selection {
    pub fn reserve(selector_count_max: u32) -> Self {
        assert!(!crate::allocation::is_frozen());

        Self {
            extend_fixable: BoundedVec::reserve(selector_count_max),
            extend_select: BoundedVec::reserve(selector_count_max),
            external: BoundedVec::reserve(selector_count_max),
            fixable: BoundedVec::reserve(selector_count_max),
            fixable_replaced: false,
            ignore: BoundedVec::reserve(selector_count_max),
            preview: Preview::default(),
            select: BoundedVec::reserve(selector_count_max),
            selected: false,
            unfixable: BoundedVec::reserve(selector_count_max),
        }
    }

    pub fn clear(&mut self) {
        self.extend_fixable.clear();
        self.extend_select.clear();
        self.external.clear();
        self.fixable.clear();
        self.fixable_replaced = false;
        self.ignore.clear();
        self.preview = Preview::default();
        self.select.clear();
        self.selected = false;
        self.unfixable.clear();
    }

    pub fn is_external(&self, code: &[u8]) -> bool {
        if code.is_empty() {
            return false;
        }

        self.external
            .iter()
            .any(|prefix| !prefix.is_all() && code.starts_with(prefix.as_bytes()))
    }

    pub fn overlay(&mut self, over: &Self) -> u32 {
        let mut dropped = 0_u32;

        if over.selected {
            self.select.clear();
            self.extend_select.clear();
            self.ignore.clear();
            self.selected = true;

            dropped += pushed_from(&mut self.select, &over.select);
        }

        if over.fixable_replaced {
            self.fixable.clear();
            self.extend_fixable.clear();
            self.unfixable.clear();
            self.fixable_replaced = true;

            dropped += pushed_from(&mut self.fixable, &over.fixable);
        }

        dropped += pushed_from(&mut self.extend_select, &over.extend_select);
        dropped += pushed_from(&mut self.ignore, &over.ignore);
        dropped += pushed_from(&mut self.extend_fixable, &over.extend_fixable);
        dropped += pushed_from(&mut self.unfixable, &over.unfixable);
        dropped += pushed_from(&mut self.external, &over.external);

        assert!(dropped <= over.count());

        dropped
    }

    fn count(&self) -> u32 {
        self.extend_fixable.count()
            + self.extend_select.count()
            + self.external.count()
            + self.fixable.count()
            + self.ignore.count()
            + self.select.count()
            + self.unfixable.count()
    }

    pub fn resolve(&self, rules: &Registry) -> CodeSet {
        let mut enabled = CodeSet::EMPTY;

        for index in 0..rules.count() {
            let rule = rules.at(index);
            let exact =
                exact_in(&self.select, rule.code) || exact_in(&self.extend_select, rule.code);

            if !reachable(rule.group, exact, self.preview) {
                continue;
            }

            if !self.covers(rule.default_on, rule.code) {
                continue;
            }

            enabled.insert(index);
        }

        enabled
    }

    pub fn resolve_fixable(&self, rules: &Registry) -> CodeSet {
        let mut allowed = CodeSet::EMPTY;

        for index in 0..rules.count() {
            if !self.fixes(rules.at(index).code) {
                continue;
            }

            allowed.insert(index);
        }

        allowed
    }

    pub fn resolve_language(&self, overlay: &Self, rules: &Registry) -> CodeSet {
        let mut enabled = CodeSet::EMPTY;

        for index in 0..rules.count() {
            let rule = rules.at(index);

            let exact = exact_in(&self.select, rule.code)
                || exact_in(&self.extend_select, rule.code)
                || exact_in(&overlay.select, rule.code)
                || exact_in(&overlay.extend_select, rule.code);

            if !reachable(rule.group, exact, self.preview) {
                continue;
            }

            if !self.covers_with(overlay, rule.default_on, rule.code) {
                continue;
            }

            enabled.insert(index);
        }

        enabled
    }

    fn covers_with(&self, overlay: &Self, default_on: bool, code: &str) -> bool {
        let replaced = overlay.selected;

        let mut chosen = if replaced || self.selected || !default_on {
            None
        } else {
            Some(0)
        };

        if replaced {
            chosen = strongest(chosen, &overlay.select, code);
        } else {
            chosen = strongest(chosen, &self.select, code);
            chosen = strongest(chosen, &self.extend_select, code);
        }

        chosen = strongest(chosen, &overlay.extend_select, code);

        let Some(strength) = chosen else {
            return false;
        };

        let inherited = if replaced {
            None
        } else {
            strongest(None, &self.ignore, code)
        };

        match strongest(inherited, &overlay.ignore, code) {
            Some(ignored) => strength > ignored,
            None => true,
        }
    }

    fn fixes(&self, code: &str) -> bool {
        let mut chosen = if self.fixable_replaced { None } else { Some(0) };

        chosen = strongest(chosen, &self.fixable, code);
        chosen = strongest(chosen, &self.extend_fixable, code);

        let Some(strength) = chosen else {
            return false;
        };

        match strongest(None, &self.unfixable, code) {
            Some(refused) => strength > refused,
            None => true,
        }
    }

    fn covers(&self, default_on: bool, code: &str) -> bool {
        let mut chosen = if self.selected || !default_on {
            None
        } else {
            Some(0)
        };

        chosen = strongest(chosen, &self.select, code);
        chosen = strongest(chosen, &self.extend_select, code);

        let Some(strength) = chosen else {
            return false;
        };

        match strongest(None, &self.ignore, code) {
            Some(ignored) => strength > ignored,
            None => true,
        }
    }
}

pub const fn reachable(group: Group, exact: bool, preview: Preview) -> bool {
    match group {
        Group::Deprecated => !preview.enabled && exact,
        Group::Preview => exact || (preview.enabled && !preview.explicit),
        Group::Removed => exact,
        Group::Stable => true,
    }
}

pub fn parse(text: &[u8], rules: &Registry) -> Option<Selector> {
    if text.is_empty() {
        return None;
    }

    if text == ALL {
        return Some(Selector::ALL);
    }

    if let Some(selector) = Selector::of(text) {
        for index in 0..rules.count() {
            if selector.matches(rules.at(index).code) {
                return Some(selector);
            }
        }
    }

    let rule = rules.find_name(text)?;

    Selector::of(rule.code.as_bytes())
}

pub fn selectors_read(
    listed: Cursor<'_>,
    rules: &Registry,
    out: &mut BoundedVec<Selector>,
    mut fault: impl FnMut(SelectorsFault),
) {
    if listed.kind() != Some(Kind::Array) {
        fault(SelectorsFault::Value);

        return;
    }

    for name in listed.elements() {
        let Some(raw) = name.raw().filter(|_| name.kind() == Some(Kind::String)) else {
            fault(SelectorsFault::Value);

            return;
        };

        let Some(parsed) = parse(raw, rules) else {
            fault(SelectorsFault::Selector);

            continue;
        };

        if !out.push(parsed) {
            fault(SelectorsFault::Value);
        }
    }
}

fn exact_in(selectors: &[Selector], code: &str) -> bool {
    selectors.iter().any(|selector| selector.is_exact(code))
}

fn pushed_from(target: &mut BoundedVec<Selector>, source: &[Selector]) -> u32 {
    let mut dropped = 0_u32;

    for selector in source {
        if !target.push(*selector) {
            dropped += 1;
        }
    }

    assert!(dropped as usize <= source.len());

    dropped
}

fn strongest(current: Option<u8>, selectors: &[Selector], code: &str) -> Option<u8> {
    let mut chosen = current;

    for selector in selectors {
        if !selector.matches(code) {
            continue;
        }

        chosen = match chosen {
            Some(seen) if seen >= selector.specificity() => Some(seen),
            _ => Some(selector.specificity()),
        };
    }

    chosen
}

#[cfg(test)]
mod tests {
    use super::*;

    const fn rule(code: &'static str, name: &'static str, default_on: bool, group: Group) -> Rule {
        Rule {
            citations: &[],
            code,
            default_on,
            description: "",
            explanation: "",
            fix_title: "",
            fixable: Fixable::Never,
            group,
            name,
            severity: Severity::Warning,
            summary: "",
            url: "",
        }
    }

    static RULES: [Rule; 5] = [
        rule("TS001", "unused-import", true, Group::Stable),
        rule("TS004", "late-future-import", true, Group::Stable),
        rule("TS011", "redefined-while-unused", false, Group::Preview),
        rule("GL001", "registration-args", true, Group::Stable),
        rule("GL015", "unregistered-name", true, Group::Deprecated),
    ];

    fn registry() -> Registry {
        Registry::reserve(&RULES)
    }

    fn selection(text: &[&[u8]], ignore: &[&[u8]]) -> Selection {
        let held = registry();
        let mut selection = Selection::reserve(8);

        selection.preview.enabled = true;
        selection.selected = !text.is_empty();

        for spelled in text {
            selection
                .select
                .push_assert(parse(spelled, &held).expect("the selector parses"));
        }

        for spelled in ignore {
            selection
                .ignore
                .push_assert(parse(spelled, &held).expect("the selector parses"));
        }

        selection
    }

    #[test]
    fn a_table_with_a_code_twice_is_refused_where_it_is_reserved() {
        static DOUBLED: [Rule; 2] = [
            rule("TS001", "first", true, Group::Stable),
            rule("TS001", "second", true, Group::Stable),
        ];

        assert!(std::panic::catch_unwind(|| Registry::reserve(&DOUBLED)).is_err());
    }

    #[test]
    fn an_ignore_composes_over_the_select_before_it() {
        let held = registry();
        let enabled = selection(&[b"TS"], &[b"TS00"]).resolve(&held);

        assert!(!enabled.contains(0));
        assert!(!enabled.contains(1));
        assert!(enabled.contains(2));
        assert!(!enabled.contains(3));
    }

    #[test]
    fn a_group_selector_names_the_rules_of_its_own_ten() {
        let held = registry();
        let enabled = selection(&[b"TS00"], &[]).resolve(&held);

        assert!(enabled.contains(0));
        assert!(enabled.contains(1));
        assert!(!enabled.contains(2));
    }

    #[test]
    fn the_all_selector_names_every_rule() {
        let held = registry();
        let enabled = selection(&[b"ALL"], &[]).resolve(&held);

        assert!(enabled.contains(0));
        assert!(enabled.contains(1));
        assert!(enabled.contains(2));
        assert!(enabled.contains(3));
    }

    #[test]
    fn a_whole_code_names_the_one_rule_it_spells() {
        let held = registry();
        let enabled = selection(&[b"TS011"], &[]).resolve(&held);

        assert!(!enabled.contains(0));
        assert!(enabled.contains(2));
    }

    #[test]
    fn a_prefix_stays_inside_its_own_linter() {
        let held = registry();
        let enabled = selection(&[b"GL"], &[]).resolve(&held);

        assert!(!enabled.contains(0));
        assert!(!enabled.contains(1));
        assert!(enabled.contains(3));
    }

    #[test]
    fn a_preview_rule_waits_for_the_preview_flag_unless_named_exactly() {
        let held = registry();
        let mut selection = Selection::reserve(8);

        selection.select.push_assert(Selector::ALL);
        selection.selected = true;

        assert!(!selection.resolve(&held).contains(2));

        selection.preview.enabled = true;

        assert!(selection.resolve(&held).contains(2));

        selection.preview.explicit = true;

        assert!(!selection.resolve(&held).contains(2));

        selection
            .extend_select
            .push_assert(parse(b"TS011", &held).expect("the code parses"));

        assert!(selection.resolve(&held).contains(2));
    }

    #[test]
    fn a_deprecated_rule_is_reached_only_by_name_and_only_outside_preview() {
        let held = registry();
        let mut selection = Selection::reserve(8);

        selection.select.push_assert(Selector::ALL);
        selection.selected = true;

        assert!(!selection.resolve(&held).contains(4));

        selection
            .select
            .push_assert(parse(b"GL015", &held).expect("the code parses"));

        assert!(selection.resolve(&held).contains(4));

        selection.preview.enabled = true;

        assert!(!selection.resolve(&held).contains(4));
    }

    #[test]
    fn a_name_selects_the_rule_that_carries_it() {
        let held = registry();
        let selector = parse(b"late-future-import", &held).expect("the name is registered");

        assert!(selector.is_exact("TS004"));
        assert_eq!(selector.specificity(), 5);
    }

    #[test]
    fn an_unknown_code_names_no_rule_at_all() {
        let held = registry();

        assert_eq!(held.index_of("TS501"), NONE);
        assert!(held.get("TS501").is_none());
        assert!(parse(b"TS501", &held).is_none());
        assert!(parse(b"XX", &held).is_none());
    }

    #[test]
    fn a_known_code_reads_back_its_own_row() {
        let held = registry();
        let rule = held.get("TS004").expect("the rule is registered");

        assert_eq!(rule.name, "late-future-import");
        assert_eq!(rule.fixable, Fixable::Never);
        assert_eq!(rule.severity, Severity::Warning);
        assert_eq!(held.count(), 5);
        assert_eq!(held.index_of("TS004"), 1);
        assert_eq!(held.index_of_name(b"late-future-import"), 1);
    }

    #[test]
    fn a_code_number_reads_its_digits_and_refuses_everything_else() {
        assert_eq!(code_number_of(b"TS042"), Some(42));
        assert_eq!(code_number_of(b"F401"), Some(401));
        assert_eq!(code_number_of(b"E1"), Some(1));
        assert_eq!(code_number_of(b"PRJ1234"), Some(1234));
        assert_eq!(code_number_of(b""), None);
        assert_eq!(code_number_of(b"042"), None);
        assert_eq!(code_number_of(b"TS"), None);
        assert_eq!(code_number_of(b"TSxyz"), None);
        assert_eq!(code_number_of(b"TS04x"), None);
        assert_eq!(code_number_of(b"ts042"), None);
        assert_eq!(code_number_of(b"ABCDEF123"), None);
        assert_eq!(code_prefix_of(b"GL015"), b"GL");
        assert_eq!(code_prefix_of(b"E1"), b"E");
        assert_eq!(code_prefix_of(b"01"), b"");
    }

    #[test]
    fn a_code_set_holds_what_it_is_given() {
        let mut held = CodeSet::EMPTY;

        assert!(!held.contains(3));

        held.insert(3);

        assert!(held.contains(3));
        assert!(!held.contains(4));

        held.remove(3);

        assert!(!held.contains(3));
        assert!(CodeSet::with_all(5).contains(4));
        assert!(!CodeSet::with_all(5).contains(5));
        assert!(CodeSet::with_all(RULE_COUNT_MAX).contains(RULE_COUNT_MAX - 1));
    }

    #[test]
    fn each_fixable_names_itself() {
        assert_eq!(Fixable::Always.name(), "always");
        assert_eq!(Fixable::Never.name(), "never");
        assert_eq!(Fixable::Sometimes.name(), "sometimes");
        assert_eq!(Group::Preview.name(), "preview");
    }

    #[test]
    fn an_external_prefix_exempts_the_codes_under_it() {
        let mut selection = Selection::reserve(8);

        selection
            .external
            .push_assert(Selector::of(b"DJ").expect("the prefix fits"));
        selection.external.push_assert(Selector::ALL);

        assert!(selection.is_external(b"DJ001"));
        assert!(!selection.is_external(b"TS001"));
        assert!(!selection.is_external(b""));
    }

    #[test]
    fn an_overlay_replaces_the_selection_when_it_selects_and_extends_otherwise() {
        let held = registry();
        let mut base = selection(&[b"TS"], &[b"TS00"]);
        let mut over = Selection::reserve(8);

        over.extend_select
            .push_assert(parse(b"GL", &held).expect("the selector parses"));
        over.ignore
            .push_assert(parse(b"GL015", &held).expect("the selector parses"));

        assert_eq!(base.overlay(&over), 0);
        assert_eq!(base.select.count(), 1);
        assert_eq!(base.extend_select.count(), 1);
        assert_eq!(base.ignore.count(), 2);

        over.selected = true;
        over.select
            .push_assert(parse(b"GL001", &held).expect("the selector parses"));

        assert_eq!(base.overlay(&over), 0);
        assert!(base.selected);
        assert_eq!(base.select.count(), 1);
        assert!(base.select[0].is_exact("GL001"));
        assert_eq!(base.extend_select.count(), 1);
        assert_eq!(base.ignore.count(), 1);
    }

    #[test]
    fn an_overlay_counts_the_selectors_that_did_not_fit() {
        let held = registry();
        let mut base = Selection::reserve(1);
        let mut over = Selection::reserve(8);

        over.ignore
            .push_assert(parse(b"GL", &held).expect("the selector parses"));
        over.ignore
            .push_assert(parse(b"TS", &held).expect("the selector parses"));

        assert_eq!(base.overlay(&over), 1);
        assert_eq!(base.ignore.count(), 1);
    }

    #[test]
    fn selectors_read_takes_an_array_of_names_and_reports_each_fault() {
        let held = registry();
        let mut document = crate::json::Document::reserve(16);
        let source =
            br#"{"good": ["TS", "late-future-import", "XX9"], "bad": "TS", "mixed": ["TS", 4]}"#;

        assert_eq!(document.parse(source), crate::json::Outcome::Complete);

        let root = document.root(source).expect("the document parsed");
        let mut out = BoundedVec::reserve(4);
        let mut faults = Vec::new();

        selectors_read(
            root.member(b"good").expect("the member exists"),
            &held,
            &mut out,
            |fault| faults.push(fault),
        );

        assert_eq!(out.count(), 2);
        assert!(out[1].is_exact("TS004"));
        assert_eq!(faults, vec![SelectorsFault::Selector]);

        faults.clear();

        selectors_read(
            root.member(b"bad").expect("the member exists"),
            &held,
            &mut out,
            |fault| faults.push(fault),
        );

        assert_eq!(faults, vec![SelectorsFault::Value]);

        faults.clear();

        selectors_read(
            root.member(b"mixed").expect("the member exists"),
            &held,
            &mut out,
            |fault| faults.push(fault),
        );

        assert_eq!(out.count(), 3);
        assert_eq!(faults, vec![SelectorsFault::Value]);
    }

    #[test]
    fn a_full_target_reports_a_value_fault_for_the_selector_that_did_not_fit() {
        let held = registry();
        let mut document = crate::json::Document::reserve(8);
        let source = br#"["TS", "GL"]"#;

        assert_eq!(document.parse(source), crate::json::Outcome::Complete);

        let root = document.root(source).expect("the document parsed");
        let mut out = BoundedVec::reserve(1);
        let mut faults = Vec::new();

        selectors_read(root, &held, &mut out, |fault| faults.push(fault));

        assert_eq!(out.count(), 1);
        assert_eq!(faults, vec![SelectorsFault::Value]);
    }

    struct Counting {
        enabled: CodeSet,
    }

    struct Source;

    impl Contextual for Source {
        type Context<'run> = &'run [u8];
    }

    impl Policy for Counting {
        fn applicability_of(&self, _rule: u32) -> Option<Applicability> {
            None
        }

        fn enables(&self, rule: u32) -> bool {
            self.enabled.contains(rule)
        }

        fn fixes(&self, _rule: u32) -> bool {
            false
        }

        fn severity_of(&self, _rule: u32, default: Severity) -> Severity {
            default
        }
    }

    fn report_first_byte(source: &&[u8], sink: &mut Sink<'_>) {
        assert!(!source.is_empty());

        sink.report(Span::new(0, 1), "the first byte is reported");
    }

    fn report_nothing(_source: &&[u8], _sink: &mut Sink<'_>) {}

    #[test]
    fn a_runner_runs_the_enabled_rules_of_the_language_and_times_each() {
        let held = registry();
        let mut runner: Runner<Source> = Runner::reserve(8);

        runner.register(0b01, report_first_byte);
        runner.register(0b10, report_first_byte);
        runner.register(0b11, report_nothing);
        runner.register(0b11, report_first_byte);

        assert_eq!(runner.count(), 4);
        assert!(runner.covers(0, 0));
        assert!(!runner.covers(0, 1));
        assert!(runner.covers(2, 1));

        let mut enabled = CodeSet::EMPTY;

        enabled.insert(0);
        enabled.insert(1);
        enabled.insert(2);

        let policy = Counting { enabled };
        let source: &[u8] = b"fn main() {}\n";
        let mut diagnostics = Diagnostics::reserve(8, 1 << 10);
        let mut fixes = Fixes::reserve(4, 4, 1 << 10);
        let mut lines = lines::Index::reserve(8);
        let mut suppressions = Regions::reserve(4);
        let mut timings: Timings<2> = Timings::new();

        assert!(lines.build(source));

        runner.run(
            0,
            &source,
            &policy,
            Tables {
                diagnostics: &mut diagnostics,
                file: FileID::of(0),
                fixes: &mut fixes,
                lines: &lines,
                registry: &held,
                suppressions: &mut suppressions,
            },
            &mut timings,
        );

        assert_eq!(diagnostics.count(), 1);
        assert_eq!(diagnostics.at(0).expect("the row was pushed").rule, 0);
        assert_eq!(diagnostics.at(0).expect("the row was pushed").code, "TS001");
        assert_eq!(timings.rule_at(3), 0);
        assert_eq!(timings.documents(), 0);

        timings.document_record();
        timings.stage_add(1, 7);
        timings.stage_add(1, 5);
        timings.rule_add(0, 3);

        assert_eq!(timings.documents(), 1);
        assert_eq!(timings.stage_at(1), 12);
        assert_eq!(timings.stage_at(0), 0);
        assert_eq!(timings.total(), 12);
        assert!(timings.rule_at(0) >= 3);
    }

    #[test]
    fn a_runner_maps_each_entry_to_the_rule_the_caller_names() {
        let held = registry();
        let mut runner: Runner<Source> = Runner::reserve(2);

        runner.register(0b01, report_first_byte);
        runner.register(0b01, report_first_byte);

        let mut enabled = CodeSet::EMPTY;

        enabled.insert(3);

        let policy = Counting { enabled };
        let source: &[u8] = b"fn main() {}\n";
        let mut diagnostics = Diagnostics::reserve(8, 1 << 10);
        let mut fixes = Fixes::reserve(4, 4, 1 << 10);
        let mut lines = lines::Index::reserve(8);
        let mut suppressions = Regions::reserve(4);
        let mut timings: Timings<1> = Timings::new();

        assert!(lines.build(source));

        runner.run_with(
            0,
            &source,
            &policy,
            Tables {
                diagnostics: &mut diagnostics,
                file: FileID::of(0),
                fixes: &mut fixes,
                lines: &lines,
                registry: &held,
                suppressions: &mut suppressions,
            },
            &mut timings,
            |entry| [Some(4), Some(3)][entry as usize],
        );

        assert_eq!(diagnostics.count(), 1);

        let row = diagnostics.at(0).copied().expect("the row was pushed");

        assert_eq!(row.rule, 3);
        assert_eq!(row.code, "GL001");
        assert_eq!(timings.rule_at(4), 0);

        runner.run_with(
            0,
            &source,
            &policy,
            Tables {
                diagnostics: &mut diagnostics,
                file: FileID::of(0),
                fixes: &mut fixes,
                lines: &lines,
                registry: &held,
                suppressions: &mut suppressions,
            },
            &mut timings,
            |entry| (entry == 0).then_some(3),
        );

        assert_eq!(diagnostics.count(), 2);
    }

    #[test]
    fn a_sink_settles_a_formatted_fix_and_carries_related_rows_on_a_fixed_row() {
        let source: &[u8] = b"let value = 1;\n";
        let mut diagnostics = Diagnostics::reserve(8, 1 << 10);
        let mut fixes = Fixes::reserve(4, 4, 1 << 10);
        let mut lines = lines::Index::reserve(8);
        let mut suppressions = Regions::reserve(4);

        assert!(lines.build(source));

        let mut sink = Sink::open(Opened {
            applicability: Some(Applicability::Unsafe),
            code: "TS001",
            code_index: 0,
            diagnostics: &mut diagnostics,
            file: FileID::of(0),
            fixable: true,
            fixes: &mut fixes,
            lines: &lines,
            severity: Severity::Warning,
            suppressions: &mut suppressions,
        });

        let related_start = sink.related_count();

        assert!(sink.related(FileID::of(1), Span::new(4, 5), "declared here"));

        sink.fix_begin_formatted(Applicability::Safe, 0, format_args!("Rename `{}`", "value"));
        sink.fix_edit_formatted(Span::new(4, 5), format_args!("{}_{}", "held", 2));
        sink.report_fixed_related_formatted(
            Span::new(0, 3),
            related_start,
            format_args!("`{}` is renamed", "value"),
        );

        sink.fix_begin("Drop it", Applicability::Safe, 0);
        sink.fix_edit(Span::new(0, 3), b"");
        sink.fix_discard();
        sink.report_fixed(Span::new(0, 3), "the fix was discarded");

        let first = diagnostics.at(0).copied().expect("the row was pushed");
        let second = diagnostics.at(1).copied().expect("the row was pushed");
        let fix = fixes.get(first.fix).expect("the fix was closed");

        assert_eq!(fix.applicability, Applicability::Unsafe);
        assert_eq!(fixes.title_of(fix), b"Rename `value`");
        assert_eq!(fixes.edits_of(fix).len(), 1);
        assert_eq!(fixes.replacement_of(&fixes.edits_of(fix)[0]), b"held_2");
        assert_eq!(diagnostics.message_of(&first), b"`value` is renamed");
        assert_eq!(first.related_start, related_start);
        assert_eq!(first.related_count, 1);
        assert_eq!(diagnostics.related_of(&first).len(), 1);
        assert_eq!(second.fix, crate::fix::NONE);
        assert_eq!(fixes.count(), 1);
    }

    #[test]
    fn a_sink_carries_related_rows_and_ranks_a_row_below_its_own_severity() {
        let source: &[u8] = b"let value = 1;\n";
        let mut diagnostics = Diagnostics::reserve(8, 1 << 10);
        let mut fixes = Fixes::reserve(4, 4, 1 << 10);
        let mut lines = lines::Index::reserve(8);
        let mut suppressions = Regions::reserve(4);

        assert!(lines.build(source));

        let mut sink = Sink::open(Opened {
            applicability: None,
            code: "TS001",
            code_index: 0,
            diagnostics: &mut diagnostics,
            file: FileID::of(0),
            fixable: false,
            fixes: &mut fixes,
            lines: &lines,
            severity: Severity::Warning,
            suppressions: &mut suppressions,
        });

        let related_start = sink.related_count();

        assert!(sink.related(FileID::of(1), Span::new(4, 5), "declared here"));
        assert!(sink.related_formatted(
            FileID::of(1),
            Span::new(12, 1),
            format_args!("used {} times", 2)
        ));

        let row = Diagnostic {
            code: "",
            fix: crate::fix::NONE,
            message: Message::Static("a row with related rows"),
            related_count: sink.related_count() - related_start,
            related_start,
            rule: NONE,
            severity: Severity::Error,
            span: Span::new(0, 3),
        };

        assert!(sink.report_row(row));
        assert!(sink.report_row_formatted(
            Diagnostic {
                severity: Severity::Hint,
                ..row
            },
            format_args!("formatted {}", "row")
        ));

        let first = diagnostics.at(0).copied().expect("the row was pushed");
        let second = diagnostics.at(1).copied().expect("the row was pushed");

        assert_eq!(first.code, "TS001");
        assert_eq!(first.rule, 0);
        assert_eq!(first.severity, Severity::Warning);
        assert_eq!(first.related_count, 2);
        assert_eq!(diagnostics.related_of(&first).len(), 2);
        assert_eq!(second.severity, Severity::Hint);
        assert_eq!(diagnostics.message_of(&second), b"formatted row");
    }
}
