pub type Trim = fn(&[u8], &[(u32, u32)], u32, u32) -> u32;

pub struct Normalizer {
    pub comments: &'static [&'static str],
    pub drops_empty: bool,
    pub root: &'static str,
    pub root_starts_at_zero: bool,
    pub skipped: &'static [&'static str],
    pub trims: Trim,
    pub unrepresented: &'static [&'static str],
}

const SCRIPT_UNREPRESENTED: [&str; 8] = [
    "comment",
    "escape_sequence",
    "hash_bang_line",
    "html_character_reference",
    "html_comment",
    "regex_flags",
    "regex_pattern",
    "string_fragment",
];

const SKIPPED: [&str; 1] = ["error_node"];

pub const CSS: Normalizer = Normalizer {
    comments: &["comment", "js_comment"],
    drops_empty: true,
    root: "stylesheet",
    root_starts_at_zero: true,
    skipped: &SKIPPED,
    trims: abutting,
    unrepresented: &["comment", "escape_sequence", "js_comment", "string_content"],
};

pub const JAVASCRIPT: Normalizer = Normalizer {
    comments: &["comment"],
    drops_empty: false,
    root: "program",
    root_starts_at_zero: false,
    skipped: &SKIPPED,
    trims: scripted,
    unrepresented: &SCRIPT_UNREPRESENTED,
};

pub const ODIN: Normalizer = Normalizer {
    comments: &["block_comment", "comment"],
    drops_empty: true,
    root: "source_file",
    root_starts_at_zero: true,
    skipped: &SKIPPED,
    trims: spanning,
    unrepresented: &[
        "block_comment",
        "comment",
        "escape_sequence",
        "string_content",
    ],
};

pub const TYPESCRIPT: Normalizer = Normalizer {
    comments: &["comment"],
    drops_empty: false,
    root: "program",
    root_starts_at_zero: false,
    skipped: &SKIPPED,
    trims: scripted,
    unrepresented: &SCRIPT_UNREPRESENTED,
};

impl Normalizer {
    pub fn held(&self, length: u32, nodes: &[(String, u32, u32)]) -> Vec<(String, u32, u32)> {
        let mut found = Vec::with_capacity(nodes.len());

        for node in nodes {
            if self.skipped.contains(&node.0.as_str()) {
                continue;
            }

            if node.0 == self.root {
                let offset = if self.root_starts_at_zero { 0 } else { node.1 };

                found.push((node.0.clone(), offset, length));

                continue;
            }

            found.push(node.clone());
        }

        found.sort();

        found
    }

    pub fn wanted(
        &self,
        source: &[u8],
        length: u32,
        rows: &[(String, u32, u32)],
    ) -> Vec<(String, u32, u32)> {
        let comments: Vec<(u32, u32)> = rows
            .iter()
            .filter(|row| self.comments.contains(&row.0.as_str()))
            .map(|row| (row.1, row.2))
            .collect();

        let mut found: Vec<(String, u32, u32)> = Vec::with_capacity(rows.len());

        for row in rows {
            if self.unrepresented.contains(&row.0.as_str()) {
                continue;
            }

            if row.0 == self.root {
                let offset = if self.root_starts_at_zero { 0 } else { row.1 };

                found.push((row.0.clone(), offset, length));

                continue;
            }

            if self.drops_empty && row.1 >= row.2 {
                continue;
            }

            found.push((
                row.0.clone(),
                row.1,
                (self.trims)(source, &comments, row.1, row.2),
            ));
        }

        found.sort();

        found
    }
}

fn abutting(source: &[u8], comments: &[(u32, u32)], offset: u32, end: u32) -> u32 {
    let mut held = end;

    for _ in 0..=comments.len() {
        held = blank(source, offset, held);

        let found = comments
            .iter()
            .find(|comment| comment.1 == held && comment.0 > offset);

        let Some(comment) = found else {
            break;
        };

        held = comment.0;
    }

    held
}

fn spanning(source: &[u8], comments: &[(u32, u32)], offset: u32, end: u32) -> u32 {
    let mut held = end;

    for _ in 0..=comments.len() {
        held = blank(source, offset, held);

        let found = comments
            .iter()
            .find(|comment| comment.1 >= held && comment.0 < held && comment.0 > offset);

        let Some(comment) = found else {
            break;
        };

        held = comment.0;
    }

    held
}

fn scripted(source: &[u8], comments: &[(u32, u32)], offset: u32, end: u32) -> u32 {
    let mut held = end;
    let mut cut = false;

    for _ in 0..=comments.len() {
        let back = blank(source, offset, held);

        let found = comments
            .iter()
            .find(|comment| comment.1 == back && comment.0 > offset);

        let Some(comment) = found else {
            break;
        };

        cut = true;
        held = comment.0;
    }

    if !cut {
        return held;
    }

    blank(source, offset, held)
}

fn blank(source: &[u8], offset: u32, end: u32) -> u32 {
    let mut held = end;

    while held > offset && source[held as usize - 1].is_ascii_whitespace() {
        held -= 1;
    }

    held
}

#[cfg(test)]
mod tests {
    use super::{JAVASCRIPT, ODIN};

    fn rows(held: &[(&str, u32, u32)]) -> Vec<(String, u32, u32)> {
        held.iter()
            .map(|row| (row.0.to_owned(), row.1, row.2))
            .collect()
    }

    #[test]
    fn the_root_span_is_rewritten_to_the_whole_file() {
        let source = b"x := 1\n\n\n";
        let held = ODIN.wanted(source, 9, &rows(&[("source_file", 0, 6)]));

        assert_eq!(held, rows(&[("source_file", 0, 9)]));
    }

    #[test]
    fn a_root_that_does_not_start_at_zero_keeps_its_offset() {
        let source = b"\n\nx;\n";
        let held = JAVASCRIPT.wanted(source, 5, &rows(&[("program", 2, 4)]));

        assert_eq!(held, rows(&[("program", 2, 5)]));
    }

    #[test]
    fn an_unrepresented_kind_is_dropped_from_both_sides() {
        let source = b"// held\nx := 1\n";
        let held = ODIN.wanted(
            source,
            15,
            &rows(&[("comment", 0, 7), ("var_declaration", 8, 14)]),
        );

        assert_eq!(held, rows(&[("var_declaration", 8, 14)]));
    }

    #[test]
    fn a_span_ending_in_a_trailing_comment_is_pulled_back_off_it() {
        let source = b"{\n    x := 1\n    // held\n}\n";
        let held = ODIN.wanted(source, 27, &rows(&[("block", 6, 24), ("comment", 17, 24)]));

        assert_eq!(held, rows(&[("block", 6, 12)]));
    }

    #[test]
    fn a_span_ending_in_a_run_of_comments_is_pulled_back_off_all_of_them() {
        let source = b"{\n    x := 1\n    // a\n    // b\n}\n";
        let carried = rows(&[("block", 6, 30), ("comment", 17, 21), ("comment", 26, 30)]);
        let held = ODIN.wanted(source, 33, &carried);

        assert_eq!(held, rows(&[("block", 6, 12)]));
    }

    #[test]
    fn a_comment_that_opens_the_span_is_kept_because_it_is_not_trailing() {
        let source = b"// held\nx";
        let held = ODIN.wanted(
            source,
            9,
            &rows(&[("var_declaration", 0, 9), ("comment", 0, 7)]),
        );

        assert_eq!(held, rows(&[("var_declaration", 0, 9)]));
    }

    #[test]
    fn an_empty_span_is_dropped_where_the_language_drops_it_and_kept_where_it_does_not() {
        let source = b"x";

        assert!(ODIN.wanted(source, 1, &rows(&[("field", 1, 1)])).is_empty());

        assert_eq!(
            JAVASCRIPT.wanted(source, 1, &rows(&[("jsx_text", 1, 1)])),
            rows(&[("jsx_text", 1, 1)])
        );
    }

    #[test]
    fn scylla_s_own_error_nodes_are_dropped_and_the_rest_sorts() {
        let held = ODIN.held(
            9,
            &rows(&[("error_node", 0, 2), ("block", 4, 6), ("field", 2, 3)]),
        );

        assert_eq!(held, rows(&[("block", 4, 6), ("field", 2, 3)]));
    }

    #[test]
    fn a_span_of_only_blanks_pulls_back_to_its_own_start_and_no_further() {
        let source = b"   \n";
        let held = ODIN.wanted(source, 4, &rows(&[("field", 1, 4)]));

        assert_eq!(held, rows(&[("field", 1, 1)]));
    }

    #[test]
    fn a_script_span_keeps_the_blanks_it_ends_on_because_they_are_its_own_text() {
        let source = b"<p>held </p>";
        let held = JAVASCRIPT.wanted(source, 12, &rows(&[("jsx_text", 3, 8)]));

        assert_eq!(held, rows(&[("jsx_text", 3, 8)]));
    }

    #[test]
    fn a_span_a_comment_runs_past_is_still_pulled_back_off_that_comment() {
        let source = b"{\n    x := 1\n    // held\n}\n";
        let held = ODIN.wanted(source, 27, &rows(&[("block", 6, 20), ("comment", 17, 24)]));

        assert_eq!(held, rows(&[("block", 6, 12)]));
    }
}
