use crate::bounded::{BoundedVec, FixedMap, Span, count_of};
use crate::diagnostic::{Diagnostic, Diagnostics, FileID, Message, Severity};
use crate::fix::{Applicability, Fixes};
use crate::lines;
use crate::suppress::Regions;

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

    pub fn fix_edit(&mut self, span: Span, replacement: &[u8]) {
        if !self.fixes.edit(span, replacement) {
            self.fix_failed = true;
        }
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
            rule: NONE,
            severity: self.severity,
            span,
        });
    }

    pub fn report_formatted(&mut self, span: Span, arguments: core::fmt::Arguments<'_>) {
        if self.suppression_claimed(span) {
            return;
        }

        let _ = self.diagnostics.push_formatted(
            self.code,
            self.severity,
            span,
            crate::fix::NONE,
            arguments,
        );
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
            rule: NONE,
            severity: self.severity,
            span,
        });
    }

    pub fn report_fixed_formatted(&mut self, span: Span, arguments: core::fmt::Arguments<'_>) {
        let Some(fix) = self.fix_settled(span) else {
            return;
        };

        let _ = self
            .diagnostics
            .push_formatted(self.code, self.severity, span, fix, arguments);
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
        self.fixable.clear();
        self.fixable_replaced = false;
        self.ignore.clear();
        self.preview = Preview::default();
        self.select.clear();
        self.selected = false;
        self.unfixable.clear();
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

fn exact_in(selectors: &[Selector], code: &str) -> bool {
    selectors.iter().any(|selector| selector.is_exact(code))
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
}
