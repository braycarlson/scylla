use crate::bounded::{BoundedVec, FixedMap, Span, count_of};
use crate::diagnostic::Severity;
use crate::diagnostic::{Diagnostic, Diagnostics, Message};
use crate::fix::{Applicability, Fixes};
use crate::lines;
use crate::project::store::FileID;
use crate::scan::{DECIMAL_BYTES_MAX, decimal_write};
use crate::suppress::Regions;

pub const NONE: u32 = u32::MAX;
pub const CODE_COUNT_MAX: u32 = 128;
pub const CODE_TEXT_BYTES_MAX: usize = 5;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Fixable {
    Always,
    Never,
    Sometimes,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Rule {
    pub citation_nasa: &'static str,
    pub citation_tigerstyle: &'static str,
    pub code: &'static str,
    pub default_on: bool,
    pub description: &'static str,
    pub explanation: &'static str,
    pub fix_title: &'static str,
    pub fixable: Fixable,
    pub name: &'static str,
    pub preview: bool,
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
    rules: BoundedVec<&'static Rule>,
}

impl Fixable {
    pub const fn name(self) -> &'static str {
        match self {
            Self::Always => "always",
            Self::Never => "never",
            Self::Sometimes => "sometimes",
        }
    }
}

impl CodeSet {
    pub const EMPTY: Self = Self { bits: 0 };

    pub fn with_all(count: u32) -> Self {
        assert!(count <= CODE_COUNT_MAX);

        if count == CODE_COUNT_MAX {
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

    pub fn contains(self, code: u32) -> bool {
        assert!(code < CODE_COUNT_MAX);

        self.bits & (1_u128 << code) != 0
    }

    pub fn insert(&mut self, code: u32) {
        assert!(code < CODE_COUNT_MAX);

        self.bits |= 1_u128 << code;
    }
}

impl Registry {
    pub fn reserve_from(rules: &[&'static Rule], count_max: u32) -> Self {
        assert!(count_max > 0);
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

    pub fn reserve(rules: &'static [Rule]) -> Self {
        assert!(!rules.is_empty());

        let held: Vec<&'static Rule> = rules.iter().collect();

        Self::reserve_from(&held, count_of(rules.len()))
    }

    pub fn register(&mut self, rule: &'static Rule) {
        assert!(!crate::allocation::is_frozen());

        let index = self.rules.count();
        assert!(code_number_of(rule.code.as_bytes()).is_some());
        assert!(!rule.name.is_empty());
        assert!(self.by_code.get(rule.code.as_bytes()).is_none());

        self.by_code.insert_assert(rule.code.as_bytes(), index);
        self.rules.push_assert(rule);

        assert_eq!(self.count(), index + 1);
    }

    pub fn at(&self, index: u32) -> &'static Rule {
        assert!(index < self.count());

        self.rules[index as usize]
    }

    pub fn count(&self) -> u32 {
        self.rules.count()
    }

    pub fn find(&self, code: &[u8]) -> Option<&'static Rule> {
        if code.is_empty() {
            return None;
        }

        let index = self.by_code.get(code)?;

        Some(self.rules[index as usize])
    }

    pub fn get(&self, code: &str) -> Option<&'static Rule> {
        self.find(code.as_bytes())
    }

    pub fn find_name(&self, name: &[u8]) -> Option<&'static Rule> {
        if name.is_empty() {
            return None;
        }

        self.rules
            .iter()
            .copied()
            .find(|rule| rule.name.as_bytes() == name)
    }

    pub fn index_of(&self, code: &str) -> u32 {
        self.by_code.get(code.as_bytes()).unwrap_or(NONE)
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

    pub fn at_number(&self, code: u32) -> Option<&'static Rule> {
        let mut text = [0_u8; CODE_TEXT_BYTES_MAX];
        let prefix = self.prefix()?;
        let mut digits = [0_u8; DECIMAL_BYTES_MAX];
        let written = decimal_write(&mut digits, u64::from(code));

        if written > CODE_TEXT_BYTES_MAX - prefix.len() {
            return None;
        }

        let start = CODE_TEXT_BYTES_MAX - written;

        text[..prefix.len()].copy_from_slice(prefix);
        text[start..].copy_from_slice(&digits[..written]);

        for byte in &mut text[prefix.len()..start] {
            *byte = b'0';
        }

        self.find(&text)
    }

    fn prefix(&self) -> Option<&'static [u8]> {
        let first = self.rules.first()?;
        let code = first.code.as_bytes();

        code.get(..code.len() - 3)
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
    if code.len() < 3 || code.len() > CODE_TEXT_BYTES_MAX {
        return None;
    }

    let digits = code.len() - 3;

    if digits == 0 {
        return None;
    }

    for byte in &code[..digits] {
        if byte.is_ascii_digit() {
            return None;
        }
    }

    let mut value = 0_u32;

    for digit in &code[digits..] {
        if !digit.is_ascii_digit() {
            return None;
        }

        value = value * 10 + u32::from(digit - b'0');
    }

    Some(value)
}

#[expect(
    clippy::arbitrary_source_item_ordering,
    reason = "the derived `Ord` makes the order the ladder the selector compares on"
)]
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum Specificity {
    All,
    Linter,
    Prefix,
    Group,
    Rule,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Selector {
    pub specificity: Specificity,
    pub value: u32,
}

#[derive(Debug)]
pub struct Selection {
    pub extend_fixable: BoundedVec<Selector>,
    pub extend_select: BoundedVec<Selector>,
    pub fixable: BoundedVec<Selector>,
    pub fixable_replaced: bool,
    pub ignore: BoundedVec<Selector>,
    pub preview: bool,
    pub select: BoundedVec<Selector>,
    pub selected: bool,
    pub unfixable: BoundedVec<Selector>,
}

impl Selector {
    pub fn matches(self, code: u32) -> bool {
        assert!(code < CODE_COUNT_MAX);

        match self.specificity {
            Specificity::All | Specificity::Linter => true,
            Specificity::Prefix => code / 100 == self.value,
            Specificity::Group => code / 10 == self.value,
            Specificity::Rule => code == self.value,
        }
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
            preview: false,
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
        self.preview = false;
        self.select.clear();
        self.selected = false;
        self.unfixable.clear();
    }

    pub fn resolve(&self, rules: &Registry) -> CodeSet {
        let mut enabled = CodeSet::EMPTY;

        for index in 0..rules.count() {
            let rule = rules.at(index);
            let code = code_number_of(rule.code.as_bytes()).expect("the code parses");

            assert!(code < CODE_COUNT_MAX);

            if rule.preview && !self.preview {
                continue;
            }

            if !self.covers(rule.default_on, code) {
                continue;
            }

            enabled.insert(code);
        }

        enabled
    }

    pub fn resolve_fixable(&self, rules: &Registry) -> CodeSet {
        let mut allowed = CodeSet::EMPTY;

        for index in 0..rules.count() {
            let rule = rules.at(index);
            let code = code_number_of(rule.code.as_bytes()).expect("the code parses");

            assert!(code < CODE_COUNT_MAX);

            if !self.fixes(code) {
                continue;
            }

            allowed.insert(code);
        }

        allowed
    }

    pub fn resolve_language(&self, overlay: &Self, rules: &Registry) -> CodeSet {
        let mut enabled = CodeSet::EMPTY;

        for index in 0..rules.count() {
            let rule = rules.at(index);
            let code = code_number_of(rule.code.as_bytes()).expect("the code parses");

            assert!(code < CODE_COUNT_MAX);

            if rule.preview && !self.preview {
                continue;
            }

            if !self.covers_with(overlay, rule.default_on, code) {
                continue;
            }

            enabled.insert(code);
        }

        enabled
    }

    fn covers_with(&self, overlay: &Self, default_on: bool, code: u32) -> bool {
        let replaced = overlay.selected;

        let mut chosen = if replaced || self.selected || !default_on {
            None
        } else {
            Some(Specificity::All)
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

    fn fixes(&self, code: u32) -> bool {
        let mut chosen = if self.fixable_replaced {
            None
        } else {
            Some(Specificity::All)
        };

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

    fn covers(&self, default_on: bool, code: u32) -> bool {
        let mut chosen = if self.selected {
            None
        } else if default_on {
            Some(Specificity::All)
        } else {
            None
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

pub fn parse(text: &[u8], rules: &Registry) -> Option<Selector> {
    if text.is_empty() {
        return None;
    }

    if text == b"ALL" {
        return Some(Selector {
            specificity: Specificity::All,
            value: 0,
        });
    }

    if text == b"TS" {
        return Some(Selector {
            specificity: Specificity::Linter,
            value: 0,
        });
    }

    if let Some(selector) = numeric(text) {
        return Some(selector);
    }

    let rule = rules.find_name(text)?;
    let code = code_number_of(rule.code.as_bytes())?;

    Some(Selector {
        specificity: Specificity::Rule,
        value: code,
    })
}

fn numeric(text: &[u8]) -> Option<Selector> {
    if text.len() < 3 || &text[..2] != b"TS" {
        return None;
    }

    let digits = &text[2..];

    let specificity = match digits.len() {
        1 => Specificity::Prefix,
        2 => Specificity::Group,
        3 => Specificity::Rule,
        _ => return None,
    };

    let mut value = 0_u32;

    for digit in digits {
        if !digit.is_ascii_digit() {
            return None;
        }

        value = value * 10 + u32::from(digit - b'0');
    }

    if specificity == Specificity::Rule && value >= CODE_COUNT_MAX {
        return None;
    }

    Some(Selector { specificity, value })
}

fn strongest(
    current: Option<Specificity>,
    selectors: &[Selector],
    code: u32,
) -> Option<Specificity> {
    let mut chosen = current;

    for selector in selectors {
        if !selector.matches(code) {
            continue;
        }

        chosen = match chosen {
            Some(seen) if seen >= selector.specificity => Some(seen),
            _ => Some(selector.specificity),
        };
    }

    chosen
}

#[cfg(test)]
mod tests {
    use super::*;

    static RULES: [Rule; 3] = [
        Rule {
            citation_nasa: "",
            citation_tigerstyle: "",
            code: "TS001",
            default_on: true,
            description: "An import the module never reads costs a load and says nothing.",
            explanation: "An import the module never reads costs a load and says nothing.",
            fix_title: "Remove the unused import",
            fixable: Fixable::Always,
            name: "unused-import",
            preview: false,
            severity: Severity::Warning,
            summary: "Unused import",
            url: "https://example.invalid/TS001",
        },
        Rule {
            citation_nasa: "",
            citation_tigerstyle: "",
            code: "TS004",
            default_on: true,
            description: "A late future import is a syntax error the interpreter reports.",
            explanation: "A late future import is a syntax error the interpreter reports.",
            fix_title: "Move the import to the head of the file",
            fixable: Fixable::Never,
            name: "late-future-import",
            preview: false,
            severity: Severity::Error,
            summary: "Late future import",
            url: "https://example.invalid/TS004",
        },
        Rule {
            citation_nasa: "",
            citation_tigerstyle: "",
            code: "TS011",
            default_on: false,
            description: "A redefinition of an unused name drops the first definition.",
            explanation: "A redefinition of an unused name drops the first definition.",
            fix_title: "Remove the earlier definition",
            fixable: Fixable::Sometimes,
            name: "redefined-while-unused",
            preview: true,
            severity: Severity::Warning,
            summary: "Redefinition of unused name",
            url: "https://example.invalid/TS011",
        },
    ];

    fn registry() -> Registry {
        Registry::reserve(&RULES)
    }

    fn selection(text: &[&[u8]], ignore: &[&[u8]]) -> Selection {
        let held = registry();
        let mut selection = Selection::reserve(8);

        selection.preview = true;
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
            Rule {
                citation_nasa: "",
                citation_tigerstyle: "",
                code: "TS001",
                default_on: true,
                description: "",
                explanation: "",
                fix_title: "",
                fixable: Fixable::Never,
                name: "first",
                preview: false,
                severity: Severity::Warning,
                summary: "",
                url: "",
            },
            Rule {
                citation_nasa: "",
                citation_tigerstyle: "",
                code: "TS001",
                default_on: true,
                description: "",
                explanation: "",
                fix_title: "",
                fixable: Fixable::Never,
                name: "second",
                preview: false,
                severity: Severity::Warning,
                summary: "",
                url: "",
            },
        ];

        assert!(std::panic::catch_unwind(|| Registry::reserve(&DOUBLED)).is_err());
    }

    #[test]
    fn an_ignore_composes_over_the_select_before_it() {
        let held = registry();
        let enabled = selection(&[b"TS"], &[b"TS00"]).resolve(&held);

        assert!(!enabled.contains(1));
        assert!(!enabled.contains(4));
        assert!(enabled.contains(11));
    }

    #[test]
    fn a_group_selector_names_the_rules_of_its_own_ten() {
        let held = registry();
        let enabled = selection(&[b"TS00"], &[]).resolve(&held);

        assert!(enabled.contains(1));
        assert!(enabled.contains(4));
        assert!(!enabled.contains(11));
    }

    #[test]
    fn the_all_selector_names_every_rule() {
        let held = registry();
        let enabled = selection(&[b"ALL"], &[]).resolve(&held);

        assert!(enabled.contains(1));
        assert!(enabled.contains(4));
        assert!(enabled.contains(11));
    }

    #[test]
    fn a_whole_code_names_the_one_rule_it_spells() {
        let held = registry();
        let enabled = selection(&[b"TS011"], &[]).resolve(&held);

        assert!(!enabled.contains(1));
        assert!(enabled.contains(11));
    }

    #[test]
    fn a_preview_rule_waits_for_the_preview_flag() {
        let held = registry();
        let mut selection = Selection::reserve(8);

        selection.select.push_assert(Selector {
            specificity: Specificity::All,
            value: 0,
        });

        selection.selected = true;

        assert!(!selection.resolve(&held).contains(11));

        selection.preview = true;

        assert!(selection.resolve(&held).contains(11));
    }

    #[test]
    fn a_name_selects_the_rule_that_carries_it() {
        let held = registry();
        let selector = parse(b"late-future-import", &held).expect("the name is registered");

        assert_eq!(selector.specificity, Specificity::Rule);
        assert_eq!(selector.value, 4);
    }

    #[test]
    fn an_unknown_code_names_no_rule_at_all() {
        let held = registry();

        assert_eq!(held.index_of("TS501"), NONE);
        assert!(held.get("TS501").is_none());
        assert!(parse(b"TS501", &held).is_none());
    }

    #[test]
    fn a_known_code_reads_back_its_own_row() {
        let held = registry();
        let rule = held.get("TS004").expect("the rule is registered");

        assert_eq!(rule.name, "late-future-import");
        assert_eq!(rule.fixable, Fixable::Never);
        assert_eq!(rule.severity, Severity::Error);
        assert_eq!(held.count(), 3);
        assert_eq!(held.at_number(4), Some(rule));
        assert_eq!(held.index_of_name(b"late-future-import"), 1);
    }

    #[test]
    fn a_code_number_reads_its_digits_and_refuses_everything_else() {
        assert_eq!(code_number_of(b"TS042"), Some(42));
        assert_eq!(code_number_of(b"F401"), Some(401));
        assert_eq!(code_number_of(b""), None);
        assert_eq!(code_number_of(b"042"), None);
        assert_eq!(code_number_of(b"TSxyz"), None);
    }

    #[test]
    fn a_code_set_holds_what_it_is_given() {
        let mut held = CodeSet::EMPTY;

        assert!(!held.contains(3));

        held.insert(3);

        assert!(held.contains(3));
        assert!(!held.contains(4));
        assert!(CodeSet::with_all(5).contains(4));
        assert!(!CodeSet::with_all(5).contains(5));
        assert!(CodeSet::with_all(CODE_COUNT_MAX).contains(CODE_COUNT_MAX - 1));
    }

    #[test]
    fn each_fixable_names_itself() {
        assert_eq!(Fixable::Always.name(), "always");
        assert_eq!(Fixable::Never.name(), "never");
        assert_eq!(Fixable::Sometimes.name(), "sometimes");
    }
}
