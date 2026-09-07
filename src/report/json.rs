use core::fmt::Write as _;

use crate::bounded::BoundedString;
use crate::json::write::Writer;
use crate::sink::Sink;

use super::{
    Position,
    Report,
    Rows,
    SCHEMA_SARIF,
    Tool,
    fingerprint_of,
    first_line_trimmed,
    gitlab_severity,
    position_of,
    sarif_level,
    shown_path,
    url_into,
};

struct Resumed<'run> {
    out: &'run mut Sink,
    writer: &'run mut Writer,
}

impl<'run> Resumed<'run> {
    fn array_close(&mut self) {
        self.step(Writer::array_close);
    }

    fn array_open(&mut self) {
        self.step(Writer::array_open);
    }

    fn boolean(&mut self, value: bool) {
        self.step(|writer, out| writer.boolean(out, value));
    }

    fn key(&mut self, name: &[u8]) {
        self.step(|writer, out| writer.key(out, name));
    }

    fn number(&mut self, value: i64) {
        self.step(|writer, out| writer.number(out, value));
    }

    fn object_close(&mut self) {
        self.step(Writer::object_close);
    }

    fn object_open(&mut self) {
        self.step(Writer::object_open);
    }

    fn resume(writer: &'run mut Writer, out: &'run mut Sink) -> Self {
        Self { out, writer }
    }

    fn step(&mut self, write: impl FnOnce(&mut Writer, &mut Sink) -> bool) {
        let _written = write(self.writer, self.out);
    }

    fn string(&mut self, text: &[u8]) {
        self.step(|writer, out| writer.string(out, text));
    }
}

pub(super) fn array_begin(out: &mut Sink, report: &mut Report) {
    report.json.start();

    Resumed::resume(&mut report.json, out).array_open();
}

pub(super) fn array_end(out: &mut Sink, report: &mut Report) {
    Resumed::resume(&mut report.json, out).array_close();

    assert!(report.json.is_poisoned() || report.json.finish());
}

pub(super) fn gitlab_file(out: &mut Sink, report: &mut Report, rows: &impl Rows) {
    let Report { json, url, .. } = report;
    let mut pen = Resumed::resume(json, out);

    for index in 0..rows.count() {
        let row = rows.row(index);
        let text = rows.text(row.file);
        let path = shown_path(text);
        let position = position_of(text, row.span.offset);
        let first = first_line_trimmed(text, row.span);

        url.clear();

        let _written = write!(url, "{:016x}", fingerprint_of(path, row.code, first));

        pen.object_open();
        pen.key(b"check_name");
        pen.string(row.code.as_bytes());
        pen.key(b"description");
        pen.string(row.message);
        pen.key(b"fingerprint");
        pen.string(url.as_bytes());
        pen.key(b"location");
        pen.object_open();
        pen.key(b"lines");
        pen.object_open();
        pen.key(b"begin");
        pen.number(i64::from(position.line));
        pen.object_close();
        pen.key(b"path");
        pen.string(path.as_bytes());
        pen.object_close();
        pen.key(b"severity");
        pen.string(gitlab_severity(row.severity).as_bytes());
        pen.object_close();
    }
}

pub(super) fn json_file(out: &mut Sink, report: &mut Report, rows: &impl Rows, tool: &Tool<'_>) {
    let Report { json, url, .. } = report;
    let mut pen = Resumed::resume(json, out);

    for index in 0..rows.count() {
        write_json_entry(&mut pen, url, rows, tool, index);
    }
}

pub(super) fn rdjson_begin(out: &mut Sink, report: &mut Report) {
    report.json.start();

    let mut pen = Resumed::resume(&mut report.json, out);

    pen.object_open();
    pen.key(b"diagnostics");
    pen.array_open();
}

pub(super) fn rdjson_end(out: &mut Sink, report: &mut Report, tool: &Tool<'_>) {
    let mut pen = Resumed::resume(&mut report.json, out);

    pen.array_close();
    pen.key(b"severity");
    pen.string(b"WARNING");
    pen.key(b"source");
    pen.object_open();
    pen.key(b"name");
    pen.string(tool.name.as_bytes());
    pen.key(b"url");
    pen.string(tool.information_uri.as_bytes());
    pen.object_close();
    pen.object_close();

    assert!(report.json.is_poisoned() || report.json.finish());
}

pub(super) fn rdjson_file(out: &mut Sink, report: &mut Report, rows: &impl Rows, tool: &Tool<'_>) {
    let Report { json, url, .. } = report;
    let mut pen = Resumed::resume(json, out);

    for index in 0..rows.count() {
        write_rdjson_entry(&mut pen, url, rows, tool, index);
    }
}

pub(super) fn render_json_lines(
    out: &mut Sink,
    report: &mut Report,
    rows: &impl Rows,
    tool: &Tool<'_>,
) {
    let Report {
        json_lines, url, ..
    } = report;

    for index in 0..rows.count() {
        json_lines.start();

        let mut pen = Resumed::resume(json_lines, out);

        write_json_entry(&mut pen, url, rows, tool, index);
        pen.out.push("\n");
    }
}

pub(super) fn sarif_begin(out: &mut Sink, report: &mut Report) {
    report.json.start();

    let mut pen = Resumed::resume(&mut report.json, out);

    pen.object_open();
    pen.key(b"$schema");
    pen.string(SCHEMA_SARIF.as_bytes());
    pen.key(b"runs");
    pen.array_open();
    pen.object_open();
    pen.key(b"results");
    pen.array_open();
}

pub(super) fn sarif_end(out: &mut Sink, report: &mut Report, rows: &impl Rows, tool: &Tool<'_>) {
    let Report { json, url, .. } = report;
    let mut pen = Resumed::resume(json, out);

    pen.array_close();
    pen.key(b"tool");
    pen.object_open();
    pen.key(b"driver");
    pen.object_open();
    pen.key(b"informationUri");
    pen.string(tool.information_uri.as_bytes());
    pen.key(b"name");
    pen.string(tool.name.as_bytes());
    pen.key(b"rules");
    pen.array_open();

    for at in 0..rows.rule_count() {
        let rule = rows.rule(at);

        url_into(url, tool, rule.code);

        pen.object_open();
        pen.key(b"helpUri");
        pen.string(url.as_bytes());
        pen.key(b"id");
        pen.string(rule.code.as_bytes());
        pen.key(b"name");
        pen.string(rule.name.as_bytes());
        pen.key(b"shortDescription");
        pen.object_open();
        pen.key(b"text");
        pen.string(rule.summary.as_bytes());
        pen.object_close();
        pen.object_close();
    }

    pen.array_close();
    pen.key(b"version");
    pen.string(tool.version.as_bytes());
    pen.object_close();
    pen.object_close();
    pen.object_close();
    pen.array_close();
    pen.key(b"version");
    pen.string(b"2.1.0");
    pen.object_close();

    assert!(json.is_poisoned() || json.finish());
}

pub(super) fn sarif_file(out: &mut Sink, report: &mut Report, rows: &impl Rows) {
    let mut pen = Resumed::resume(&mut report.json, out);

    for index in 0..rows.count() {
        write_sarif_result(&mut pen, rows, index);
    }
}

pub(super) fn statistics_json(out: &mut Sink, report: &mut Report, tool: &Tool<'_>) {
    let Report {
        json, tally, url, ..
    } = report;

    json.start();

    let mut pen = Resumed::resume(json, out);

    pen.array_open();

    for held in tally.iter() {
        url_into(url, tool, held.code);

        pen.object_open();
        pen.key(b"code");
        pen.string(held.code.as_bytes());
        pen.key(b"count");
        pen.number(i64::from(held.count));
        pen.key(b"fixable");
        pen.boolean(held.fixable_count == held.count);
        pen.key(b"fixable_count");
        pen.number(i64::from(held.fixable_count));
        pen.key(b"name");
        pen.string(held.rule.as_bytes());
        pen.key(b"url");
        pen.string(url.as_bytes());
        pen.object_close();
    }

    pen.array_close();
    pen.out.push("\n");
}

fn write_json_entry(
    pen: &mut Resumed<'_>,
    url: &mut BoundedString,
    rows: &impl Rows,
    tool: &Tool<'_>,
    index: u32,
) {
    let row = rows.row(index);
    let text = rows.text(row.file);
    let path = shown_path(text);
    let start = position_of(text, row.span.offset);
    let end = position_of(text, row.span.end());

    url_into(url, tool, row.code);

    pen.object_open();
    pen.key(b"code");
    pen.string(row.code.as_bytes());
    pen.key(b"column");
    pen.number(i64::from(start.column));
    pen.key(b"end_column");
    pen.number(i64::from(end.column));
    pen.key(b"end_line");
    pen.number(i64::from(end.line));
    pen.key(b"file");
    pen.string(path.as_bytes());
    pen.key(b"fixable");
    pen.boolean(row.fix.is_some());
    pen.key(b"line");
    pen.number(i64::from(start.line));
    pen.key(b"message");
    pen.string(row.message);
    pen.key(b"related");
    pen.array_open();

    for at in 0..rows.related_count(index) {
        let related = rows.related(index, at);
        let held = rows.text(related.file);
        let position = position_of(held, related.span.offset);

        pen.object_open();
        pen.key(b"column");
        pen.number(i64::from(position.column));
        pen.key(b"file");
        pen.string(shown_path(held).as_bytes());
        pen.key(b"line");
        pen.number(i64::from(position.line));
        pen.key(b"message");
        pen.string(related.message);
        pen.object_close();
    }

    pen.array_close();
    pen.key(b"rule");
    pen.string(row.rule.as_bytes());
    pen.key(b"severity");
    pen.string(row.severity.name().as_bytes());
    pen.key(b"url");
    pen.string(url.as_bytes());
    pen.object_close();
}

fn write_range(pen: &mut Resumed<'_>, start: Position, end: Position) {
    pen.object_open();
    pen.key(b"end");
    pen.object_open();
    pen.key(b"column");
    pen.number(i64::from(end.column));
    pen.key(b"line");
    pen.number(i64::from(end.line));
    pen.object_close();
    pen.key(b"start");
    pen.object_open();
    pen.key(b"column");
    pen.number(i64::from(start.column));
    pen.key(b"line");
    pen.number(i64::from(start.line));
    pen.object_close();
    pen.object_close();
}

fn write_rdjson_entry(
    pen: &mut Resumed<'_>,
    url: &mut BoundedString,
    rows: &impl Rows,
    tool: &Tool<'_>,
    index: u32,
) {
    let row = rows.row(index);
    let text = rows.text(row.file);
    let path = shown_path(text);
    let start = position_of(text, row.span.offset);
    let end = position_of(text, row.span.end());

    url_into(url, tool, row.code);

    pen.object_open();
    pen.key(b"code");
    pen.object_open();
    pen.key(b"url");
    pen.string(url.as_bytes());
    pen.key(b"value");
    pen.string(row.code.as_bytes());
    pen.object_close();
    pen.key(b"location");
    pen.object_open();
    pen.key(b"path");
    pen.string(path.as_bytes());
    pen.key(b"range");

    write_range(pen, start, end);

    pen.object_close();
    pen.key(b"message");
    pen.string(row.message);
    pen.key(b"suggestions");
    pen.array_open();

    if row.fix.is_some() {
        for at in 0..rows.edit_count(index) {
            let edit = rows.edit(index, at);
            let from = position_of(text, edit.span.offset);
            let to = position_of(text, edit.span.end());

            pen.object_open();
            pen.key(b"range");

            write_range(pen, from, to);

            pen.key(b"text");
            pen.string(edit.replacement);
            pen.object_close();
        }
    }

    pen.array_close();
    pen.object_close();
}

fn write_sarif_result(pen: &mut Resumed<'_>, rows: &impl Rows, index: u32) {
    let row = rows.row(index);
    let text = rows.text(row.file);
    let path = shown_path(text);
    let start = position_of(text, row.span.offset);
    let end = position_of(text, row.span.end());

    pen.object_open();
    pen.key(b"level");
    pen.string(sarif_level(row.severity).as_bytes());
    pen.key(b"locations");
    pen.array_open();
    pen.object_open();
    pen.key(b"physicalLocation");
    pen.object_open();
    pen.key(b"artifactLocation");
    pen.object_open();
    pen.key(b"uri");
    pen.string(path.as_bytes());
    pen.object_close();
    pen.key(b"region");
    pen.object_open();
    pen.key(b"endColumn");
    pen.number(i64::from(end.column));
    pen.key(b"endLine");
    pen.number(i64::from(end.line));
    pen.key(b"startColumn");
    pen.number(i64::from(start.column));
    pen.key(b"startLine");
    pen.number(i64::from(start.line));
    pen.object_close();
    pen.object_close();
    pen.object_close();
    pen.array_close();
    pen.key(b"message");
    pen.object_open();
    pen.key(b"text");
    pen.string(row.message);
    pen.object_close();
    pen.key(b"ruleId");
    pen.string(row.code.as_bytes());
    pen.object_close();
}

#[cfg(test)]
mod tests {
    use super::super::tests::{Fixture, OUT_BYTES_MAX, TOOL, rendered};
    use super::super::{Format, Report, statistics, tallied};
    use crate::allocation;
    use crate::json::read::{Document, Outcome};
    use crate::sink::{Sink, Target};

    const RDJSON_EXPECTED: &str = "{\n\
        \x20 \"diagnostics\": [\n\
        \x20   {\n\
        \x20     \"code\": {\n\
        \x20       \"url\": \"https://example.invalid/rules/TP001.md\",\n\
        \x20       \"value\": \"TP001\"\n\
        \x20     },\n\
        \x20     \"location\": {\n\
        \x20       \"path\": \"templates/page.html\",\n\
        \x20       \"range\": {\n\
        \x20         \"end\": {\n\
        \x20           \"column\": 19,\n\
        \x20           \"line\": 2\n\
        \x20         },\n\
        \x20         \"start\": {\n\
        \x20           \"column\": 2,\n\
        \x20           \"line\": 2\n\
        \x20         }\n\
        \x20       }\n\
        \x20     },\n\
        \x20     \"message\": \"`block.super` outside any block\",\n\
        \x20     \"suggestions\": [\n\
        \x20       {\n\
        \x20         \"range\": {\n\
        \x20           \"end\": {\n\
        \x20             \"column\": 19,\n\
        \x20             \"line\": 2\n\
        \x20           },\n\
        \x20           \"start\": {\n\
        \x20             \"column\": 2,\n\
        \x20             \"line\": 2\n\
        \x20           }\n\
        \x20         },\n\
        \x20         \"text\": \"{% block body %}{{ block.super }}{% endblock %}\"\n\
        \x20       }\n\
        \x20     ]\n\
        \x20   },\n\
        \x20   {\n\
        \x20     \"code\": {\n\
        \x20       \"url\": \"https://example.invalid/rules/TP002.md\",\n\
        \x20       \"value\": \"TP002\"\n\
        \x20     },\n\
        \x20     \"location\": {\n\
        \x20       \"path\": \"templates/page.html\",\n\
        \x20       \"range\": {\n\
        \x20         \"end\": {\n\
        \x20           \"column\": 6,\n\
        \x20           \"line\": 1\n\
        \x20         },\n\
        \x20         \"start\": {\n\
        \x20           \"column\": 1,\n\
        \x20           \"line\": 1\n\
        \x20         }\n\
        \x20       }\n\
        \x20     },\n\
        \x20     \"message\": \"`div` is never closed % of the time\",\n\
        \x20     \"suggestions\": []\n\
        \x20   }\n\
        \x20 ],\n\
        \x20 \"severity\": \"WARNING\",\n\
        \x20 \"source\": {\n\
        \x20   \"name\": \"tool\",\n\
        \x20   \"url\": \"https://example.invalid/tool\"\n\
        \x20 }\n\
        }";

    fn parsed(text: &str) -> Document {
        let mut document = Document::reserve(256);

        assert_eq!(document.parse(text.as_bytes()), Outcome::Complete, "{text}");

        document
    }

    #[test]
    fn the_gitlab_format_carries_what_code_quality_reads() {
        let text = rendered(Format::Gitlab);

        assert_eq!(
            text,
            "[\n\
             \x20 {\n\
             \x20   \"check_name\": \"TP001\",\n\
             \x20   \"description\": \"`block.super` outside any block\",\n\
             \x20   \"fingerprint\": \"97ad2eb8eaa705f7\",\n\
             \x20   \"location\": {\n\
             \x20     \"lines\": {\n\
             \x20       \"begin\": 2\n\
             \x20     },\n\
             \x20     \"path\": \"templates/page.html\"\n\
             \x20   },\n\
             \x20   \"severity\": \"minor\"\n\
             \x20 },\n\
             \x20 {\n\
             \x20   \"check_name\": \"TP002\",\n\
             \x20   \"description\": \"`div` is never closed % of the time\",\n\
             \x20   \"fingerprint\": \"13d52df7505df7b5\",\n\
             \x20   \"location\": {\n\
             \x20     \"lines\": {\n\
             \x20       \"begin\": 1\n\
             \x20     },\n\
             \x20     \"path\": \"templates/page.html\"\n\
             \x20   },\n\
             \x20   \"severity\": \"major\"\n\
             \x20 }\n\
             ]"
        );
    }

    #[test]
    fn the_json_format_carries_every_field_a_row_has() {
        let text = rendered(Format::Json);

        assert_eq!(
            text,
            "[\n\
             \x20 {\n\
             \x20   \"code\": \"TP001\",\n\
             \x20   \"column\": 2,\n\
             \x20   \"end_column\": 19,\n\
             \x20   \"end_line\": 2,\n\
             \x20   \"file\": \"templates/page.html\",\n\
             \x20   \"fixable\": true,\n\
             \x20   \"line\": 2,\n\
             \x20   \"message\": \"`block.super` outside any block\",\n\
             \x20   \"related\": [],\n\
             \x20   \"rule\": \"template/super-outside-block\",\n\
             \x20   \"severity\": \"warning\",\n\
             \x20   \"url\": \"https://example.invalid/rules/TP001.md\"\n\
             \x20 },\n\
             \x20 {\n\
             \x20   \"code\": \"TP002\",\n\
             \x20   \"column\": 1,\n\
             \x20   \"end_column\": 6,\n\
             \x20   \"end_line\": 1,\n\
             \x20   \"file\": \"templates/page.html\",\n\
             \x20   \"fixable\": false,\n\
             \x20   \"line\": 1,\n\
             \x20   \"message\": \"`div` is never closed % of the time\",\n\
             \x20   \"related\": [\n\
             \x20     {\n\
             \x20       \"column\": 12,\n\
             \x20       \"file\": \"app/views.py\",\n\
             \x20       \"line\": 2,\n\
             \x20       \"message\": \"rendered here\"\n\
             \x20     }\n\
             \x20   ],\n\
             \x20   \"rule\": \"template/unclosed\",\n\
             \x20   \"severity\": \"error\",\n\
             \x20   \"url\": \"https://example.invalid/rules/TP002.md\"\n\
             \x20 }\n\
             ]"
        );
    }

    #[test]
    fn every_json_line_is_a_document_of_its_own() {
        let text = rendered(Format::JsonLines);

        assert_eq!(
            text,
            "{\"code\":\"TP001\",\"column\":2,\"end_column\":19,\"end_line\":2,\"file\":\"templates/page.html\",\"fixable\":true,\"line\":2,\"message\":\"`block.super` outside any block\",\"related\":[],\"rule\":\"template/super-outside-block\",\"severity\":\"warning\",\"url\":\"https://example.invalid/rules/TP001.md\"}\n\
             {\"code\":\"TP002\",\"column\":1,\"end_column\":6,\"end_line\":1,\"file\":\"templates/page.html\",\"fixable\":false,\"line\":1,\"message\":\"`div` is never closed % of the time\",\"related\":[{\"column\":12,\"file\":\"app/views.py\",\"line\":2,\"message\":\"rendered here\"}],\"rule\":\"template/unclosed\",\"severity\":\"error\",\"url\":\"https://example.invalid/rules/TP002.md\"}\n"
        );

        for line in text.lines() {
            let document = parsed(line);

            assert!(
                document
                    .root(line.as_bytes())
                    .and_then(|root| root.member(b"code"))
                    .is_some()
            );
        }
    }

    #[test]
    fn the_rdjson_format_names_its_source_and_lists_the_edits() {
        assert_eq!(rendered(Format::Rdjson), RDJSON_EXPECTED);
    }

    #[test]
    fn the_sarif_format_lists_every_rule_and_result() {
        let text = rendered(Format::Sarif);
        let document = parsed(&text);
        let root = document
            .root(text.as_bytes())
            .expect("the document has a root");

        assert!(
            root.member(b"version")
                .is_some_and(|held| held.text_is(b"2.1.0"))
        );

        let run = root
            .member(b"runs")
            .and_then(|runs| runs.elements().next())
            .expect("one run is written");

        let driver = run
            .member(b"tool")
            .and_then(|tool| tool.member(b"driver"))
            .expect("the run names its driver");

        assert!(
            driver
                .member(b"name")
                .is_some_and(|name| name.text_is(b"tool"))
        );
        assert!(
            driver
                .member(b"version")
                .is_some_and(|version| version.text_is(b"1.2.3"))
        );
        assert_eq!(
            driver.member(b"rules").map(|held| held.elements().count()),
            Some(2)
        );
        assert_eq!(
            run.member(b"results").map(|held| held.elements().count()),
            Some(2)
        );
        assert!(text.starts_with(
            "{\n  \"$schema\": \"https://json.schemastore.org/sarif-2.1.0.json\",\n  \"runs\": [\n    {\n      \"results\": [\n        {\n          \"level\": \"warning\",\n"
        ));
        assert!(text.contains(
            "            {\n              \"helpUri\": \"https://example.invalid/rules/TP001.md\",\n              \"id\": \"TP001\",\n              \"name\": \"template/super-outside-block\",\n              \"shortDescription\": {\n                \"text\": \"Checks for a super call outside any block.\"\n              }\n            },\n"
        ));
        assert!(text.ends_with("\n  \"version\": \"2.1.0\"\n}"));
    }

    #[test]
    fn the_json_statistics_are_one_object_a_code() {
        let fixture = Fixture::new();
        let mut report = Report::reserve(OUT_BYTES_MAX, 64);
        let mut out = Sink::reserve(OUT_BYTES_MAX, Target::Memory, false);

        allocation::frozen(|| {
            tallied(&mut report, &fixture, false);

            assert!(statistics(&mut out, &mut report, &TOOL, Format::Json));
        });

        assert_eq!(
            out.as_str(),
            "[\n\
             \x20 {\n\
             \x20   \"code\": \"TP001\",\n\
             \x20   \"count\": 1,\n\
             \x20   \"fixable\": false,\n\
             \x20   \"fixable_count\": 0,\n\
             \x20   \"name\": \"template/super-outside-block\",\n\
             \x20   \"url\": \"https://example.invalid/rules/TP001.md\"\n\
             \x20 },\n\
             \x20 {\n\
             \x20   \"code\": \"TP002\",\n\
             \x20   \"count\": 1,\n\
             \x20   \"fixable\": false,\n\
             \x20   \"fixable_count\": 0,\n\
             \x20   \"name\": \"template/unclosed\",\n\
             \x20   \"url\": \"https://example.invalid/rules/TP002.md\"\n\
             \x20 }\n\
             ]\n"
        );
    }
}
