mod json;
mod text;

use core::fmt::Write as _;

use crate::bounded::{BoundedString, BoundedVec, Buffer, HASH_OFFSET, Span, hash_seeded};
use crate::diagnostic::{FileID, Severity};
use crate::diff::Diff;
use crate::fix::Applicability;
use crate::json::write::Writer;
use crate::lines::{Encoding, Index};
use crate::scan::{decimal_width, text_of};
use crate::sink::{BLUE, BOLD, RED, RESET, Sink, Target, YELLOW};

pub use text::{
    display_width_columns,
    write_caret_band,
    write_escaped_github,
    write_escaped_xml,
    write_snippet,
};

pub const DISPLAY_ONLY_FIX_NOTE: &str = "This fix is shown for reference and is never applied";
pub const FIX_CONTEXT_LINES: u32 = 1;
pub const PAINTED_BYTES_MAX: u32 = 256;
pub const PATH_UNKNOWN: &str = "<unknown>";
pub const SCHEMA_SARIF: &str = "https://json.schemastore.org/sarif-2.1.0.json";
pub const SNIPPET_LINES_MAX: u32 = 10;
pub const TAB_WIDTH_COLUMNS: usize = 4;
pub const TALLY_ROWS_MAX: u32 = 256;
pub const UNSAFE_FIX_NOTE: &str = "This is an unsafe fix and may change runtime behavior";
pub const URL_BYTES_MAX: u32 = 1 << 10;
pub const WINDOW_BYTES_MAX: u32 = 1 << 16;
const JSON_DEPTH_MAX: u32 = 16;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum Format {
    Azure,
    Concise,
    #[default]
    Full,
    Github,
    Gitlab,
    Grouped,
    Json,
    JsonLines,
    Junit,
    Pylint,
    Rdjson,
    Sarif,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Counted {
    pub code: &'static str,
    pub count: u32,
    pub fixable_count: u32,
    pub rule: &'static str,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Edit<'text> {
    pub replacement: &'text [u8],
    pub span: Span,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Fix<'text> {
    pub applicability: Applicability,
    pub title: &'text [u8],
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Position {
    pub column: u32,
    pub line: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Related<'text> {
    pub file: FileID,
    pub message: &'text [u8],
    pub span: Span,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Row<'text> {
    pub code: &'static str,
    pub file: FileID,
    pub fix: Option<Fix<'text>>,
    pub message: &'text [u8],
    pub rule: &'static str,
    pub severity: Severity,
    pub span: Span,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Rule<'text> {
    pub code: &'text str,
    pub name: &'text str,
    pub summary: &'text str,
}

#[derive(Clone, Copy, Debug)]
pub struct Text<'text> {
    pub lines: &'text Index,
    pub path: &'text [u8],
    pub source: &'text [u8],
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Tool<'text> {
    pub information_uri: &'text str,
    pub name: &'text str,
    pub rule_uri_prefix: &'text str,
    pub rule_uri_suffix: &'text str,
    pub version: &'text str,
}

pub trait Rows {
    fn count(&self) -> u32;

    fn edit(&self, index: u32, at: u32) -> Edit<'_>;

    fn edit_count(&self, index: u32) -> u32;

    fn related(&self, index: u32, at: u32) -> Related<'_>;

    fn related_count(&self, index: u32) -> u32;

    fn row(&self, index: u32) -> Row<'_>;

    fn rule(&self, at: u32) -> Rule<'_>;

    fn rule_count(&self) -> u32;

    fn text(&self, file: FileID) -> Text<'_>;
}

pub struct Report {
    body: Sink,
    diff: Diff,
    json: Writer,
    json_lines: Writer,
    painted: BoundedString,
    streamed: u32,
    tally: BoundedVec<Counted>,
    url: BoundedString,
    window: Buffer,
}

impl Format {
    pub const fn colors(self) -> bool {
        matches!(self, Self::Concise | Self::Full | Self::Grouped)
    }

    pub const fn name(self) -> &'static str {
        match self {
            Self::Azure => "azure",
            Self::Concise => "concise",
            Self::Full => "full",
            Self::Github => "github",
            Self::Gitlab => "gitlab",
            Self::Grouped => "grouped",
            Self::Json => "json",
            Self::JsonLines => "json-lines",
            Self::Junit => "junit",
            Self::Pylint => "pylint",
            Self::Rdjson => "rdjson",
            Self::Sarif => "sarif",
        }
    }

    pub fn of(name: &str) -> Option<Self> {
        match name {
            "azure" => Some(Self::Azure),
            "concise" | "text" => Some(Self::Concise),
            "full" | "human" => Some(Self::Full),
            "github" => Some(Self::Github),
            "gitlab" => Some(Self::Gitlab),
            "grouped" => Some(Self::Grouped),
            "json" => Some(Self::Json),
            "json-lines" => Some(Self::JsonLines),
            "junit" => Some(Self::Junit),
            "pylint" => Some(Self::Pylint),
            "rdjson" => Some(Self::Rdjson),
            "sarif" => Some(Self::Sarif),
            _ => None,
        }
    }
}

impl Report {
    pub const fn is_truncated(&self) -> bool {
        self.body.is_truncated()
    }

    pub fn reserve(body_bytes_max: u32, line_count_max: u32) -> Self {
        assert!(body_bytes_max > 0);
        assert!(line_count_max > 0);
        assert!(!crate::allocation::is_frozen());

        Self {
            body: Sink::reserve(body_bytes_max, Target::Memory, false),
            diff: Diff::reserve(line_count_max),
            json: Writer::reserve_pretty(JSON_DEPTH_MAX),
            json_lines: Writer::reserve(JSON_DEPTH_MAX),
            painted: BoundedString::reserve(PAINTED_BYTES_MAX),
            streamed: 0,
            tally: BoundedVec::reserve(TALLY_ROWS_MAX),
            url: BoundedString::reserve(URL_BYTES_MAX),
            window: Buffer::reserve(WINDOW_BYTES_MAX),
        }
    }

    pub fn tally(&self) -> &[Counted] {
        &self.tally
    }
}

pub const fn azure_kind(severity: Severity) -> &'static str {
    match severity {
        Severity::Error => "error",
        Severity::Hint | Severity::Information | Severity::Warning => "warning",
    }
}

pub fn begin(out: &mut Sink, report: &mut Report, format: Format) {
    report.body.clear();
    report.streamed = 0;

    match format {
        Format::Gitlab | Format::Json => json::array_begin(out, report),
        Format::Rdjson => json::rdjson_begin(out, report),
        Format::Sarif => json::sarif_begin(out, report),
        Format::Azure
        | Format::Concise
        | Format::Full
        | Format::Github
        | Format::Grouped
        | Format::JsonLines
        | Format::Junit
        | Format::Pylint => {}
    }

    assert_eq!(report.streamed, 0);
}

pub fn end(out: &mut Sink, report: &mut Report, rows: &impl Rows, tool: &Tool<'_>, format: Format) {
    match format {
        Format::Gitlab | Format::Json => json::array_end(out, report),
        Format::Junit => {
            text::junit_open(out, report.streamed, tool);
            out.push(report.body.as_str());
            text::junit_close(out);
        }
        Format::Rdjson => json::rdjson_end(out, report, tool),
        Format::Sarif => json::sarif_end(out, report, rows, tool),
        Format::Azure
        | Format::Concise
        | Format::Full
        | Format::Github
        | Format::Grouped
        | Format::JsonLines
        | Format::Pylint => {}
    }
}

pub fn fingerprint_of(path: &str, code: &str, text: &str) -> u64 {
    assert!(!code.is_empty());

    let mut hash = HASH_OFFSET;

    for piece in [path, code, text] {
        hash = hash_seeded(hash, piece.as_bytes());
        hash = hash_seeded(hash, &[0xff]);
    }

    hash
}

fn first_line_trimmed(text: Text<'_>, span: Span) -> &str {
    let length = u32::try_from(text.source.len()).unwrap_or(u32::MAX);
    let line = text.lines.line_of(span.offset.min(length));

    line_text(text, line).trim()
}

const fn fix_note(applicability: Applicability) -> Option<&'static str> {
    match applicability {
        Applicability::DisplayOnly => Some(DISPLAY_ONLY_FIX_NOTE),
        Applicability::Safe => None,
        Applicability::Unsafe => Some(UNSAFE_FIX_NOTE),
    }
}

const fn fixability_mark(held: &Counted) -> &'static str {
    if held.fixable_count == held.count {
        return "[*] ";
    }

    if held.fixable_count > 0 {
        return "[-] ";
    }

    "[ ] "
}

const fn fixable_mark(row: &Row<'_>) -> &'static str {
    if row.fix.is_some() { " [*]" } else { "" }
}

pub const fn github_level(severity: Severity) -> &'static str {
    match severity {
        Severity::Error => "error",
        Severity::Hint | Severity::Information => "notice",
        Severity::Warning => "warning",
    }
}

pub const fn gitlab_severity(severity: Severity) -> &'static str {
    match severity {
        Severity::Error => "major",
        Severity::Hint | Severity::Information => "info",
        Severity::Warning => "minor",
    }
}

fn line_text(text: Text<'_>, line: u32) -> &str {
    assert!(line < text.lines.count());

    let span = text.lines.line_span(line, text.source);

    text_of(text.source.get(span.range()).unwrap_or(&[]), "")
}

fn painted_code(out: &mut Sink, report: &mut Report, tool: &Tool<'_>, code: &str) {
    if !out.colored() {
        out.push(code);

        return;
    }

    url_into(&mut report.url, tool, code);
    report.painted.clear();

    let _written = write!(&mut report.painted, "{BOLD}{RED}{code}{RESET}");

    out.hyperlink(report.painted.as_str(), report.url.as_str());
}

fn painted_severity_name(out: &mut Sink, held: Severity) {
    let ink = match held {
        Severity::Error => RED,
        Severity::Hint | Severity::Information => BLUE,
        Severity::Warning => YELLOW,
    };

    out.painted(held.name(), &[BOLD, ink]);
}

pub fn position_of(text: Text<'_>, offset: u32) -> Position {
    let held = text
        .lines
        .position_clamped(text.source, offset, Encoding::Utf32);

    Position {
        column: held.character.saturating_add(1),
        line: held.line.saturating_add(1),
    }
}

pub const fn rdjson_severity(severity: Severity) -> &'static str {
    match severity {
        Severity::Error => "ERROR",
        Severity::Hint | Severity::Information => "INFO",
        Severity::Warning => "WARNING",
    }
}

pub fn render(
    out: &mut Sink,
    report: &mut Report,
    rows: &impl Rows,
    tool: &Tool<'_>,
    format: Format,
) {
    if format == Format::Junit {
        text::render_junit(out, rows, tool);

        return;
    }

    begin(out, report, format);
    render_file(out, report, rows, tool, format);
    end(out, report, rows, tool, format);
}

pub fn render_file(
    out: &mut Sink,
    report: &mut Report,
    rows: &impl Rows,
    tool: &Tool<'_>,
    format: Format,
) {
    match format {
        Format::Azure => text::render_azure(out, rows),
        Format::Concise => text::render_concise(out, report, rows, tool),
        Format::Full => text::render_full(out, report, rows, tool),
        Format::Github => text::render_github(out, rows),
        Format::Gitlab => json::gitlab_file(out, report, rows),
        Format::Grouped => text::render_grouped(out, report, rows, tool),
        Format::Json => json::json_file(out, report, rows, tool),
        Format::JsonLines => json::render_json_lines(out, report, rows, tool),
        Format::Junit => text::junit_file(report, rows),
        Format::Pylint => text::render_pylint(out, rows),
        Format::Rdjson => json::rdjson_file(out, report, rows, tool),
        Format::Sarif => json::sarif_file(out, report, rows),
    }
}

pub const fn sarif_level(severity: Severity) -> &'static str {
    match severity {
        Severity::Error => "error",
        Severity::Hint | Severity::Information => "note",
        Severity::Warning => "warning",
    }
}

pub fn shown_path(text: Text<'_>) -> &str {
    text_of(text.path, PATH_UNKNOWN)
}

pub fn statistics(out: &mut Sink, report: &mut Report, tool: &Tool<'_>, format: Format) -> bool {
    if report.tally.is_empty() {
        return matches!(format, Format::Concise | Format::Full | Format::Json);
    }

    match format {
        Format::Concise | Format::Full => {
            statistics_text(out, report, tool);

            true
        }
        Format::Json => {
            json::statistics_json(out, report, tool);

            true
        }
        Format::Azure
        | Format::Github
        | Format::Gitlab
        | Format::Grouped
        | Format::JsonLines
        | Format::Junit
        | Format::Pylint
        | Format::Rdjson
        | Format::Sarif => false,
    }
}

fn statistics_text(out: &mut Sink, report: &mut Report, tool: &Tool<'_>) {
    assert!(!report.tally.is_empty());

    let width_columns = report
        .tally
        .iter()
        .map(|held| decimal_width(u64::from(held.count)))
        .max()
        .unwrap_or(1);

    let code_columns = report
        .tally
        .iter()
        .map(|held| held.code.len())
        .max()
        .unwrap_or_default();

    let any_fixable = report.tally.iter().any(|held| held.fixable_count > 0);
    let mut at = 0_usize;

    while let Some(held) = report.tally.get(at).copied() {
        at = at.saturating_add(1);

        for _ in 0..width_columns.saturating_sub(decimal_width(u64::from(held.count))) {
            out.push(" ");
        }

        report.painted.clear();

        let _written = write!(&mut report.painted, "{}", held.count);

        out.painted(report.painted.as_str(), &[BOLD]);
        out.push("  ");
        painted_code(out, report, tool, held.code);

        for _ in 0..code_columns.saturating_sub(held.code.len()) {
            out.push(" ");
        }

        out.push("  ");

        if any_fixable {
            out.push(fixability_mark(&held));
        }

        out.push(held.rule);
        out.push("\n");
    }
}

pub fn tallied(report: &mut Report, rows: &impl Rows, unsafe_fixes: bool) {
    report.tally.clear();

    for index in 0..rows.count() {
        let row = rows.row(index);

        let fixable = row
            .fix
            .is_some_and(|fix| unsafe_fixes || fix.applicability == Applicability::Safe);

        if let Some(entry) = report.tally.iter_mut().find(|held| held.code == row.code) {
            entry.count = entry.count.saturating_add(1);

            if fixable {
                entry.fixable_count = entry.fixable_count.saturating_add(1);
            }

            continue;
        }

        let _pushed = report.tally.push(Counted {
            code: row.code,
            count: 1,
            fixable_count: u32::from(fixable),
            rule: row.rule,
        });
    }

    report.tally.sort_unstable_by(|left, right| {
        right.count.cmp(&left.count).then(left.code.cmp(right.code))
    });

    assert!(report.tally.count() <= rows.count());
}

pub fn url_into(url: &mut BoundedString, tool: &Tool<'_>, code: &str) {
    assert!(!code.is_empty());

    url.clear();

    let _written = url.push_str(tool.rule_uri_prefix)
        && url.push_str(code)
        && url.push_str(tool.rule_uri_suffix);
}

#[cfg(test)]
pub(super) mod tests {
    use super::{
        Counted,
        Edit,
        FileID,
        Fix,
        Format,
        Position,
        Related,
        Report,
        Row,
        Rows,
        Rule,
        Text,
        Tool,
        azure_kind,
        fingerprint_of,
        github_level,
        gitlab_severity,
        position_of,
        rdjson_severity,
        render,
        sarif_level,
        statistics,
        tallied,
    };
    use crate::allocation;
    use crate::bounded::Span;
    use crate::diagnostic::Severity;
    use crate::fix::Applicability;
    use crate::lines::Index;
    use crate::sink::{Sink, Target};

    pub(super) const OUT_BYTES_MAX: u32 = 1 << 14;
    pub(super) const PAGE: &[u8] = b"<div>\n\t{{ block.super }}\n</div>\n";
    pub(super) const VIEW: &[u8] = b"def view(request):\n    return render(request, 'page.html')\n";

    pub(super) const TOOL: Tool<'static> = Tool {
        information_uri: "https://example.invalid/tool",
        name: "tool",
        rule_uri_prefix: "https://example.invalid/rules/",
        rule_uri_suffix: ".md",
        version: "1.2.3",
    };

    pub(super) struct Fixture {
        page_lines: Index,
        view_lines: Index,
    }

    impl Fixture {
        pub(super) fn new() -> Self {
            let mut page_lines = Index::reserve(16);
            let mut view_lines = Index::reserve(16);

            assert!(page_lines.build(PAGE));
            assert!(view_lines.build(VIEW));

            Self {
                page_lines,
                view_lines,
            }
        }
    }

    impl Rows for Fixture {
        fn count(&self) -> u32 {
            2
        }

        fn edit(&self, index: u32, at: u32) -> Edit<'_> {
            assert_eq!(index, 0);
            assert_eq!(at, 0);

            Edit {
                replacement: b"{% block body %}{{ block.super }}{% endblock %}",
                span: Span::new(7, 17),
            }
        }

        fn edit_count(&self, index: u32) -> u32 {
            u32::from(index == 0)
        }

        fn related(&self, index: u32, at: u32) -> Related<'_> {
            assert_eq!(index, 1);
            assert_eq!(at, 0);

            Related {
                file: FileID::of(1),
                message: b"rendered here",
                span: Span::new(30, 6),
            }
        }

        fn related_count(&self, index: u32) -> u32 {
            u32::from(index == 1)
        }

        fn row(&self, index: u32) -> Row<'_> {
            assert!(index < self.count());

            if index == 0 {
                return Row {
                    code: "TP001",
                    file: FileID::of(0),
                    fix: Some(Fix {
                        applicability: Applicability::Unsafe,
                        title: b"Wrap the super call in a block",
                    }),
                    message: b"`block.super` outside any block",
                    rule: "template/super-outside-block",
                    severity: Severity::Warning,
                    span: Span::new(7, 17),
                };
            }

            Row {
                code: "TP002",
                file: FileID::of(0),
                fix: None,
                message: b"`div` is never closed % of the time",
                rule: "template/unclosed",
                severity: Severity::Error,
                span: Span::new(0, 5),
            }
        }

        fn rule(&self, at: u32) -> Rule<'_> {
            assert!(at < self.rule_count());

            if at == 0 {
                return Rule {
                    code: "TP001",
                    name: "template/super-outside-block",
                    summary: "Checks for a super call outside any block.",
                };
            }

            Rule {
                code: "TP002",
                name: "template/unclosed",
                summary: "Checks for an element that is never closed.",
            }
        }

        fn rule_count(&self) -> u32 {
            2
        }

        fn text(&self, file: FileID) -> Text<'_> {
            if file == FileID::of(0) {
                return Text {
                    lines: &self.page_lines,
                    path: b"templates/page.html",
                    source: PAGE,
                };
            }

            Text {
                lines: &self.view_lines,
                path: b"app/views.py",
                source: VIEW,
            }
        }
    }

    pub(super) fn rendered(format: Format) -> String {
        let fixture = Fixture::new();
        let mut report = Report::reserve(OUT_BYTES_MAX, 64);
        let mut out = Sink::reserve(OUT_BYTES_MAX, Target::Memory, false);

        allocation::frozen(|| render(&mut out, &mut report, &fixture, &TOOL, format));

        assert!(!out.is_truncated());

        out.as_str().to_owned()
    }

    #[test]
    fn positions_are_one_based_character_columns() {
        let fixture = Fixture::new();
        let text = fixture.text(FileID::of(0));

        allocation::frozen(|| {
            assert_eq!(position_of(text, 0), Position { column: 1, line: 1 });
            assert_eq!(position_of(text, 7), Position { column: 2, line: 2 });
            assert_eq!(position_of(text, 999), Position { column: 1, line: 4 });
        });
    }

    #[test]
    fn a_fingerprint_matches_the_reference_renderer() {
        allocation::frozen(|| {
            assert_eq!(
                fingerprint_of(
                    "./templates/django/child.html",
                    "DG009",
                    "{{ block.super }}"
                ),
                0xbd26_916e_ae1d_a9a4
            );
        });
    }

    #[test]
    fn every_severity_maps_to_each_vocabulary() {
        allocation::frozen(|| {
            assert_eq!(azure_kind(Severity::Hint), "warning");
            assert_eq!(github_level(Severity::Information), "notice");
            assert_eq!(gitlab_severity(Severity::Warning), "minor");
            assert_eq!(rdjson_severity(Severity::Error), "ERROR");
            assert_eq!(sarif_level(Severity::Hint), "note");
        });
    }

    #[test]
    fn every_format_name_parses_and_spells_itself() {
        let formats = [
            Format::Azure,
            Format::Concise,
            Format::Full,
            Format::Github,
            Format::Gitlab,
            Format::Grouped,
            Format::Json,
            Format::JsonLines,
            Format::Junit,
            Format::Pylint,
            Format::Rdjson,
            Format::Sarif,
        ];

        allocation::frozen(|| {
            for format in formats {
                assert_eq!(Format::of(format.name()), Some(format));
            }

            assert_eq!(Format::of("text"), Some(Format::Concise));
            assert_eq!(Format::of("human"), Some(Format::Full));
            assert_eq!(Format::of("nonsense"), None);
            assert!(Format::Grouped.colors());
            assert!(!Format::Sarif.colors());
        });
    }

    #[test]
    fn the_tally_counts_each_code_once_and_sorts_by_count() {
        let fixture = Fixture::new();
        let mut report = Report::reserve(OUT_BYTES_MAX, 64);

        allocation::frozen(|| {
            tallied(&mut report, &fixture, false);

            assert_eq!(
                report.tally(),
                [
                    Counted {
                        code: "TP001",
                        count: 1,
                        fixable_count: 0,
                        rule: "template/super-outside-block",
                    },
                    Counted {
                        code: "TP002",
                        count: 1,
                        fixable_count: 0,
                        rule: "template/unclosed",
                    },
                ]
            );

            tallied(&mut report, &fixture, true);

            assert_eq!(report.tally()[0].fixable_count, 1);
        });
    }

    #[test]
    fn the_text_statistics_align_counts_and_mark_fixability() {
        let fixture = Fixture::new();
        let mut report = Report::reserve(OUT_BYTES_MAX, 64);
        let mut out = Sink::reserve(OUT_BYTES_MAX, Target::Memory, false);

        allocation::frozen(|| {
            tallied(&mut report, &fixture, true);

            assert!(statistics(&mut out, &mut report, &TOOL, Format::Full));
            assert_eq!(
                out.as_str(),
                "1  TP001  [*] template/super-outside-block\n1  TP002  [ ] template/unclosed\n"
            );
            assert!(!statistics(&mut out, &mut report, &TOOL, Format::Sarif));
        });
    }
}
