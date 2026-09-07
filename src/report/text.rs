use crate::bounded::{Bytes as _, Span};
use crate::diagnostic::FileID;
use crate::scan::{decimal_width, text_of};
use crate::sink::Sink;

use super::{
    FIX_CONTEXT_LINES,
    Position,
    Report,
    Row,
    Rows,
    SNIPPET_LINES_MAX,
    TAB_WIDTH_COLUMNS,
    Text,
    Tool,
    azure_kind,
    fix_note,
    fixable_mark,
    github_level,
    line_text,
    painted_code,
    painted_severity_name,
    position_of,
    shown_path,
};

pub fn display_width_columns(text: &str, column: u32) -> usize {
    let wanted = usize::try_from(column)
        .unwrap_or(usize::MAX)
        .saturating_sub(1);

    let mut width_columns = 0_usize;

    for (index, character) in text.chars().enumerate() {
        if index >= wanted {
            break;
        }

        width_columns = width_columns.saturating_add(if character == '\t' {
            TAB_WIDTH_COLUMNS
        } else {
            1
        });
    }

    width_columns
}

fn grouped_width(rows: &impl Rows, first: u32) -> usize {
    assert!(first < rows.count());

    let file = rows.row(first).file;
    let mut width_columns = 1_usize;

    for index in first..rows.count() {
        let row = rows.row(index);

        if row.file != file {
            break;
        }

        let position = position_of(rows.text(row.file), row.span.offset);

        width_columns = width_columns.max(position_width(position));
    }

    width_columns
}

pub(super) fn junit_close(out: &mut Sink) {
    out.push("</testsuites>\n");
}

pub(super) fn junit_file(report: &mut Report, rows: &impl Rows) {
    let Report { body, streamed, .. } = report;

    junit_suites(body, rows);

    *streamed = streamed.saturating_add(rows.count());
}

pub(super) fn junit_open(out: &mut Sink, count: u32, tool: &Tool<'_>) {
    out.push_line(format_args!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<testsuites name=\"{}\" tests=\"{count}\" failures=\"{count}\">",
        tool.name
    ));
}

pub(super) fn junit_suites(out: &mut Sink, rows: &impl Rows) {
    let mut current: Option<FileID> = None;

    for index in 0..rows.count() {
        let file = rows.row(index).file;

        if Some(file) == current {
            continue;
        }

        if (0..index).any(|earlier| rows.row(earlier).file == file) {
            continue;
        }

        current = Some(file);

        write_testsuite(out, rows, file);
    }
}

fn position_width(position: Position) -> usize {
    decimal_width(u64::from(position.line))
        .saturating_add(decimal_width(u64::from(position.column)))
        .saturating_add(1)
}

pub(super) fn render_azure(out: &mut Sink, rows: &impl Rows) {
    for index in 0..rows.count() {
        let row = rows.row(index);
        let text = rows.text(row.file);
        let path = shown_path(text);
        let position = position_of(text, row.span.offset);
        let level = azure_kind(row.severity);

        out.push_format(format_args!(
            "##vso[task.logissue type={level};sourcepath={path};linenumber={};columnnumber={};code={};]",
            position.line, position.column, row.code
        ));

        out.push(text_of(row.message, ""));
        out.push("\n");
    }
}

pub(super) fn render_concise(
    out: &mut Sink,
    report: &mut Report,
    rows: &impl Rows,
    tool: &Tool<'_>,
) {
    for index in 0..rows.count() {
        let row = rows.row(index);

        write_headline(out, report, rows, tool, &row);
        write_related(out, rows, index);
    }
}

pub(super) fn render_full(out: &mut Sink, report: &mut Report, rows: &impl Rows, tool: &Tool<'_>) {
    for index in 0..rows.count() {
        let row = rows.row(index);
        let text = rows.text(row.file);

        write_headline(out, report, rows, tool, &row);

        let start = position_of(text, row.span.offset);
        let end = position_of(text, row.span.end());
        let gutter = write_snippet(out, text, row.span, start, end);

        if let Some(fix) = row.fix {
            for _ in 0..gutter {
                out.push(" ");
            }

            out.push(" = help: ");
            out.push(text_of(fix.title, ""));
            out.push("\n");

            write_fix_diff(out, report, rows, index, text);

            if let Some(note) = fix_note(fix.applicability) {
                for _ in 0..gutter {
                    out.push(" ");
                }

                out.push_line(format_args!(" = note: {note}"));
            }
        }

        write_related(out, rows, index);

        out.push("\n");
    }
}

pub(super) fn render_github(out: &mut Sink, rows: &impl Rows) {
    for index in 0..rows.count() {
        let row = rows.row(index);
        let text = rows.text(row.file);
        let path = shown_path(text);
        let position = position_of(text, row.span.offset);
        let level = github_level(row.severity);

        out.push_format(format_args!(
            "::{level} file={path},line={},col={},title={} {}::",
            position.line, position.column, row.code, row.rule
        ));

        write_escaped_github(out, text_of(row.message, ""));

        out.push("\n");
    }
}

pub(super) fn render_grouped(
    out: &mut Sink,
    report: &mut Report,
    rows: &impl Rows,
    tool: &Tool<'_>,
) {
    let mut current: Option<FileID> = None;
    let mut width_columns = 1_usize;

    for index in 0..rows.count() {
        let row = rows.row(index);
        let text = rows.text(row.file);
        let path = shown_path(text);
        let position = position_of(text, row.span.offset);

        if current != Some(row.file) {
            if report.streamed > 0 {
                out.push("\n");
            }

            out.push_line(format_args!("{path}:"));

            current = Some(row.file);
            width_columns = grouped_width(rows, index);
        }

        out.push_format(format_args!("  {}:{}", position.line, position.column));

        for _ in 0..width_columns.saturating_sub(position_width(position)) {
            out.push(" ");
        }

        out.push("  ");
        painted_severity_name(out, row.severity);
        out.push(" ");
        painted_code(out, report, tool, row.code);
        out.push(fixable_mark(&row));
        out.push(" ");
        out.push(text_of(row.message, ""));
        out.push("\n");

        report.streamed = report.streamed.saturating_add(1);
    }
}

pub(super) fn render_junit(out: &mut Sink, rows: &impl Rows, tool: &Tool<'_>) {
    junit_open(out, rows.count(), tool);
    junit_suites(out, rows);
    junit_close(out);
}

pub(super) fn render_pylint(out: &mut Sink, rows: &impl Rows) {
    for index in 0..rows.count() {
        let row = rows.row(index);
        let text = rows.text(row.file);
        let path = shown_path(text);
        let position = position_of(text, row.span.offset);

        out.push_format(format_args!("{path}:{}: [{}] ", position.line, row.code));

        out.push(text_of(row.message, ""));
        out.push("\n");
    }
}

pub fn write_caret_band(out: &mut Sink, text: &str, number: u32, start: Position, end: Position) {
    let last = u32::try_from(text.chars().count())
        .unwrap_or(u32::MAX)
        .saturating_add(1);

    let from = if number == start.line {
        start.column
    } else {
        1
    };

    let to = if number == end.line { end.column } else { last };
    let lead = display_width_columns(text, from);
    let span = display_width_columns(text, to).saturating_sub(lead).max(1);

    for _ in 0..lead {
        out.push(" ");
    }

    for _ in 0..span {
        out.push("^");
    }
}

pub fn write_escaped_github(out: &mut Sink, message: &str) {
    for character in message.chars() {
        match character {
            '%' => out.push("%25"),
            '\r' => out.push("%0D"),
            '\n' => out.push("%0A"),
            _ => out.push(character.encode_utf8(&mut [0_u8; 4])),
        }
    }
}

pub fn write_escaped_xml(out: &mut Sink, text: &str) {
    for character in text.chars() {
        match character {
            '&' => out.push("&amp;"),
            '<' => out.push("&lt;"),
            '>' => out.push("&gt;"),
            '"' => out.push("&quot;"),
            _ => out.push(character.encode_utf8(&mut [0_u8; 4])),
        }
    }
}

fn write_expanded(out: &mut Sink, text: &str) {
    for (index, piece) in text.split('\t').enumerate() {
        if index > 0 {
            for _ in 0..TAB_WIDTH_COLUMNS {
                out.push(" ");
            }
        }

        out.push(piece);
    }
}

fn write_fix_diff(
    out: &mut Sink,
    report: &mut Report,
    rows: &impl Rows,
    index: u32,
    text: Text<'_>,
) {
    let edit_count = rows.edit_count(index);

    if edit_count == 0 {
        return;
    }

    let length = u32::try_from(text.source.len()).unwrap_or(u32::MAX);
    let mut lowest = u32::MAX;
    let mut highest = 0_u32;

    for at in 0..edit_count {
        let edit = rows.edit(index, at);

        lowest = lowest.min(edit.span.offset);
        highest = highest.max(edit.span.end());
    }

    let first = text
        .lines
        .line_of(lowest.min(length))
        .saturating_sub(FIX_CONTEXT_LINES);

    let last = text
        .lines
        .line_of(highest.min(length))
        .saturating_add(FIX_CONTEXT_LINES)
        .min(text.lines.count().saturating_sub(1));

    let window_start = text.lines.line_start(first);
    let window_end = text.lines.line_end(last, length);

    let Some(before) = text
        .source
        .get(usize::try_from(window_start).unwrap_or(0)..usize::try_from(window_end).unwrap_or(0))
    else {
        return;
    };

    report.window.clear();

    let mut cursor = window_start;

    for at in 0..edit_count {
        let edit = rows.edit(index, at);
        let start = edit.span.offset.max(cursor).min(window_end);
        let end = edit.span.end().max(start).min(window_end);

        let kept = text
            .source
            .get(usize::try_from(cursor).unwrap_or(0)..usize::try_from(start).unwrap_or(0))
            .unwrap_or(&[]);

        if !report.window.push_bytes(kept) || !report.window.push_bytes(edit.replacement) {
            return;
        }

        cursor = end;
    }

    let tail = text
        .source
        .get(usize::try_from(cursor).unwrap_or(0)..usize::try_from(window_end).unwrap_or(0))
        .unwrap_or(&[]);

    if !report.window.push_bytes(tail) {
        return;
    }

    let Report { diff, window, .. } = report;

    diff.write_window(out, before, window.as_bytes(), first.saturating_add(1));
}

fn write_headline(
    out: &mut Sink,
    report: &mut Report,
    rows: &impl Rows,
    tool: &Tool<'_>,
    row: &Row<'_>,
) {
    let text = rows.text(row.file);
    let path = shown_path(text);
    let position = position_of(text, row.span.offset);

    out.push_format(format_args!(
        "{path}:{}:{}: ",
        position.line, position.column
    ));

    painted_severity_name(out, row.severity);
    out.push(" ");
    painted_code(out, report, tool, row.code);
    out.push(fixable_mark(row));
    out.push(" ");
    out.push(text_of(row.message, ""));
    out.push("\n");
}

fn write_related(out: &mut Sink, rows: &impl Rows, index: u32) {
    for at in 0..rows.related_count(index) {
        let related = rows.related(index, at);
        let text = rows.text(related.file);
        let path = shown_path(text);
        let position = position_of(text, related.span.offset);

        out.push_format(format_args!(
            "    {path}:{}:{}: ",
            position.line, position.column
        ));

        out.push(text_of(related.message, ""));
        out.push("\n");
    }
}

pub fn write_snippet(
    out: &mut Sink,
    text: Text<'_>,
    span: Span,
    start: Position,
    end: Position,
) -> usize {
    let length = u32::try_from(text.source.len()).unwrap_or(u32::MAX);
    let first = text.lines.line_of(span.offset.min(length));
    let mut last = text.lines.line_of(span.end().min(length));

    if last > first && text.lines.line_start(last) == span.end() {
        last = last.saturating_sub(1);
    }

    let shown_last = last.min(first.saturating_add(SNIPPET_LINES_MAX).saturating_sub(1));
    let truncated = last > shown_last;
    let gutter = decimal_width(u64::from(shown_last.saturating_add(1)));

    assert!(shown_last >= first);

    for _ in 0..gutter {
        out.push(" ");
    }

    out.push(" |\n");

    for line in first..=shown_last {
        let held = line_text(text, line);
        let number = line.saturating_add(1);

        out.push_format(format_args!("{number:>gutter$} | "));

        write_expanded(out, held);
        out.push("\n");

        if number != start.line && number != end.line {
            continue;
        }

        for _ in 0..gutter {
            out.push(" ");
        }

        out.push(" | ");
        write_caret_band(out, held, number, start, end);
        out.push("\n");
    }

    if truncated {
        for _ in 0..gutter {
            out.push(" ");
        }

        out.push(" | ...\n");
    }

    for _ in 0..gutter {
        out.push(" ");
    }

    out.push(" |\n");

    gutter
}

fn write_testsuite(out: &mut Sink, rows: &impl Rows, file: FileID) {
    let text = rows.text(file);
    let path = shown_path(text);
    let mut count = 0_u32;

    for index in 0..rows.count() {
        if rows.row(index).file == file {
            count = count.saturating_add(1);
        }
    }

    assert!(count > 0);

    out.push("  <testsuite name=\"");
    write_escaped_xml(out, path);

    out.push_line(format_args!("\" tests=\"{count}\" failures=\"{count}\">"));

    for index in 0..rows.count() {
        let row = rows.row(index);

        if row.file != file {
            continue;
        }

        let position = position_of(text, row.span.offset);

        out.push_format(format_args!(
            "    <testcase name=\"{} {}:{}\" classname=\"",
            row.code, position.line, position.column
        ));

        write_escaped_xml(out, path);

        out.push_format(format_args!(
            "\">\n      <failure type=\"{}\" message=\"",
            row.code
        ));

        write_escaped_xml(out, text_of(row.message, ""));

        out.push_line(format_args!(
            "\">{} at {}:{}</failure>\n    </testcase>",
            row.severity.name(),
            position.line,
            position.column
        ));
    }

    out.push("  </testsuite>\n");
}

#[cfg(test)]
mod tests {
    use super::super::Format;
    use super::super::tests::{OUT_BYTES_MAX, rendered};
    use super::{
        Position,
        display_width_columns,
        write_caret_band,
        write_escaped_github,
        write_escaped_xml,
    };
    use crate::allocation;
    use crate::sink::{Sink, Target};

    fn band(text: &str, number: u32, start: Position, end: Position) -> String {
        let mut out = Sink::reserve(OUT_BYTES_MAX, Target::Memory, false);

        allocation::frozen(|| write_caret_band(&mut out, text, number, start, end));

        out.as_str().to_owned()
    }

    #[test]
    fn carets_sit_under_the_range_they_mark() {
        let start = Position { column: 5, line: 1 };
        let end = Position { column: 8, line: 1 };

        assert_eq!(band("abcdefgh", 1, start, end), "    ^^^");
    }

    #[test]
    fn a_tab_widens_the_run_up_to_the_carets() {
        let start = Position { column: 2, line: 1 };
        let end = Position { column: 4, line: 1 };

        assert_eq!(display_width_columns("\tab", 2), 4);
        assert_eq!(band("\tab", 1, start, end), "    ^^");
    }

    #[test]
    fn an_empty_range_still_takes_one_caret() {
        let at = Position { column: 3, line: 1 };

        assert_eq!(band("abcd", 1, at, at), "  ^");
    }

    #[test]
    fn a_range_running_past_a_line_is_marked_to_that_line_s_end() {
        let start = Position { column: 3, line: 1 };
        let end = Position { column: 2, line: 3 };

        assert_eq!(band("abcd", 1, start, end), "  ^^");
        assert_eq!(band("abcd", 3, start, end), "^");
    }

    #[test]
    fn workflow_commands_escape_what_would_end_them() {
        let mut out = Sink::reserve(OUT_BYTES_MAX, Target::Memory, false);

        allocation::frozen(|| write_escaped_github(&mut out, "a\nb%c\rd"));

        assert_eq!(out.as_str(), "a%0Ab%25c%0Dd");
    }

    #[test]
    fn markup_in_a_message_is_escaped_for_xml() {
        let mut out = Sink::reserve(OUT_BYTES_MAX, Target::Memory, false);

        allocation::frozen(|| write_escaped_xml(&mut out, "a <b> & \"c\" 'd'"));

        assert_eq!(out.as_str(), "a &lt;b&gt; &amp; &quot;c&quot; 'd'");
    }

    #[test]
    fn the_azure_format_logs_one_issue_a_row() {
        assert_eq!(
            rendered(Format::Azure),
            "##vso[task.logissue type=warning;sourcepath=templates/page.html;linenumber=2;columnnumber=2;code=TP001;]`block.super` outside any block\n\
             ##vso[task.logissue type=error;sourcepath=templates/page.html;linenumber=1;columnnumber=1;code=TP002;]`div` is never closed % of the time\n"
        );
    }

    #[test]
    fn the_concise_format_is_one_headline_a_row_with_its_related_lines() {
        assert_eq!(
            rendered(Format::Concise),
            "templates/page.html:2:2: warning TP001 [*] `block.super` outside any block\n\
             templates/page.html:1:1: error TP002 `div` is never closed % of the time\n\
             \x20   app/views.py:2:12: rendered here\n"
        );
    }

    #[test]
    fn the_full_format_quotes_the_line_and_shows_the_fix() {
        assert_eq!(
            rendered(Format::Full),
            "templates/page.html:2:2: warning TP001 [*] `block.super` outside any block\n\
             \x20 |\n\
             2 |     {{ block.super }}\n\
             \x20 |     ^^^^^^^^^^^^^^^^^\n\
             \x20 |\n\
             \x20 = help: Wrap the super call in a block\n\
             \x20 |\n\
             1 | <div>\n\
             \x20 - \t{{ block.super }}\n\
             2 + \t{% block body %}{{ block.super }}{% endblock %}\n\
             3 | </div>\n\
             \x20 |\n\
             \x20 = note: This is an unsafe fix and may change runtime behavior\n\
             \n\
             templates/page.html:1:1: error TP002 `div` is never closed % of the time\n\
             \x20 |\n\
             1 | <div>\n\
             \x20 | ^^^^^\n\
             \x20 |\n\
             \x20   app/views.py:2:12: rendered here\n\
             \n"
        );
    }

    #[test]
    fn the_github_format_writes_workflow_commands() {
        assert_eq!(
            rendered(Format::Github),
            "::warning file=templates/page.html,line=2,col=2,title=TP001 template/super-outside-block::`block.super` outside any block\n\
             ::error file=templates/page.html,line=1,col=1,title=TP002 template/unclosed::`div` is never closed %25 of the time\n"
        );
    }

    #[test]
    fn the_grouped_format_names_the_file_once_and_aligns_the_positions() {
        assert_eq!(
            rendered(Format::Grouped),
            "templates/page.html:\n\
             \x20 2:2  warning TP001 [*] `block.super` outside any block\n\
             \x20 1:1  error TP002 `div` is never closed % of the time\n"
        );
    }

    #[test]
    fn the_junit_format_wraps_one_suite_a_file() {
        assert_eq!(
            rendered(Format::Junit),
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
             <testsuites name=\"tool\" tests=\"2\" failures=\"2\">\n\
             \x20 <testsuite name=\"templates/page.html\" tests=\"2\" failures=\"2\">\n\
             \x20   <testcase name=\"TP001 2:2\" classname=\"templates/page.html\">\n\
             \x20     <failure type=\"TP001\" message=\"`block.super` outside any block\">warning at 2:2</failure>\n\
             \x20   </testcase>\n\
             \x20   <testcase name=\"TP002 1:1\" classname=\"templates/page.html\">\n\
             \x20     <failure type=\"TP002\" message=\"`div` is never closed % of the time\">error at 1:1</failure>\n\
             \x20   </testcase>\n\
             \x20 </testsuite>\n\
             </testsuites>\n"
        );
    }

    #[test]
    fn the_pylint_format_is_path_line_and_code() {
        assert_eq!(
            rendered(Format::Pylint),
            "templates/page.html:2: [TP001] `block.super` outside any block\n\
             templates/page.html:1: [TP002] `div` is never closed % of the time\n"
        );
    }
}
