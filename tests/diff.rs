use core::fmt::Write as _;

use scylla::allocation;
use scylla::diff::{CONTEXT_LINES, Diff, LINES_MAX, Step};
use scylla::sink::{Sink, Target};

const LINE_COUNT_MAX: u32 = 1 << 10;
const OUT_BYTES_MAX: u32 = 1 << 16;

fn steps_of(before: &str, after: &str) -> Vec<Step> {
    let mut diff = Diff::reserve(LINE_COUNT_MAX);

    allocation::frozen(|| diff.align(before.as_bytes(), after.as_bytes()));

    diff.steps().to_vec()
}

fn unified(before: &str, after: &str) -> String {
    let mut diff = Diff::reserve(LINE_COUNT_MAX);
    let mut out = Sink::reserve(OUT_BYTES_MAX, Target::Memory, false);

    allocation::frozen(|| {
        diff.write_unified(
            &mut out,
            "page.html",
            before.as_bytes(),
            after.as_bytes(),
            CONTEXT_LINES,
        );
    });

    assert!(!out.is_truncated());

    out.as_str().to_owned()
}

fn window(before: &str, after: &str, first: u32) -> String {
    let mut diff = Diff::reserve(LINE_COUNT_MAX);
    let mut out = Sink::reserve(OUT_BYTES_MAX, Target::Memory, false);

    allocation::frozen(|| {
        diff.write_window(&mut out, before.as_bytes(), after.as_bytes(), first);
    });

    out.as_str().to_owned()
}

#[test]
fn two_equal_texts_print_nothing() {
    assert_eq!(unified("a\nb\n", "a\nb\n"), "");
}

#[test]
fn one_changed_line_is_one_hunk_with_its_context() {
    assert_eq!(
        unified("a\nb\nc\n", "a\nB\nc\n"),
        "--- page.html\n+++ page.html\n@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n",
    );
}

#[test]
fn a_change_far_from_another_opens_a_second_hunk() {
    let before = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\n";
    let after = "A\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nL\n";
    let patch = unified(before, after);

    assert!(
        patch.contains("@@ -1,4 +1,4 @@\n-a\n+A\n b\n c\n d\n"),
        "{patch}"
    );
    assert!(
        patch.contains("@@ -9,4 +9,4 @@\n i\n j\n k\n-l\n+L\n"),
        "{patch}"
    );
}

#[test]
fn a_narrower_context_shortens_the_hunk() {
    let mut diff = Diff::reserve(LINE_COUNT_MAX);
    let mut out = Sink::reserve(OUT_BYTES_MAX, Target::Memory, false);

    allocation::frozen(|| {
        diff.write_unified(&mut out, "p", b"a\nb\nc\nd\ne\n", b"a\nb\nC\nd\ne\n", 1);
    });

    assert_eq!(out.as_str(), "--- p\n+++ p\n@@ -2,3 +2,3 @@\n b\n-c\n+C\n d\n");
}

#[test]
fn an_insertion_and_a_deletion_are_spelled_in_the_header() {
    assert_eq!(
        unified("a\nb\n", "a\nb\nc\n"),
        "--- page.html\n+++ page.html\n@@ -1,2 +1,3 @@\n a\n b\n+c\n",
    );

    assert_eq!(
        unified("a\nb\nc\n", "a\nb\n"),
        "--- page.html\n+++ page.html\n@@ -1,3 +1,2 @@\n a\n b\n-c\n",
    );
}

#[test]
fn a_missing_final_newline_is_noted_on_both_sides() {
    assert_eq!(
        unified("a", "b"),
        "--- page.html\n+++ page.html\n@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+b\n\\ No newline at end of file\n",
    );
}

#[test]
fn a_middle_past_the_table_is_one_removal_and_one_insertion() {
    let count = LINES_MAX + 88;
    let mut before = String::new();
    let mut after = String::new();

    for index in 0..count {
        writeln!(before, "x{index}").expect("a string grows");
        writeln!(after, "y{index}").expect("a string grows");
    }

    let patch = unified(&before, &after);
    let removed = patch
        .lines()
        .filter(|line| line.starts_with('-') && !line.starts_with("---"))
        .count();
    let added = patch
        .lines()
        .filter(|line| line.starts_with('+') && !line.starts_with("+++"))
        .count();

    assert!(
        patch.contains(&format!("@@ -1,{count} +1,{count} @@")),
        "{patch}"
    );
    assert_eq!(u32::try_from(removed).expect("the count fits"), count);
    assert_eq!(u32::try_from(added).expect("the count fits"), count);

    let lines: Vec<&str> = patch.lines().collect();
    let first_added = lines.iter().position(|line| line.starts_with("+y"));
    let last_removed = lines.iter().rposition(|line| line.starts_with("-x"));

    assert!(
        last_removed < first_added,
        "every removal precedes every insertion"
    );
}

#[test]
fn carriage_returns_do_not_make_two_lines_differ() {
    assert_eq!(unified("a\r\nb\r\n", "a\nb\n"), "");
}

#[test]
fn the_alignment_keeps_the_longest_common_run() {
    assert_eq!(
        steps_of("a\nb\nc\nd\n", "b\nc\nd\na\n"),
        [
            Step::Delete,
            Step::Equal,
            Step::Equal,
            Step::Equal,
            Step::Insert
        ]
    );
    assert_eq!(steps_of("", "a\n"), [Step::Insert]);
    assert_eq!(steps_of("a\n", ""), [Step::Delete]);
    assert_eq!(steps_of("", ""), []);
}

#[test]
fn the_window_numbers_the_kept_lines_and_marks_the_moved_ones() {
    assert_eq!(
        window("a\nb\nc\n", "a\nB\nc\n", 1),
        "  |\n1 | a\n  - b\n2 + B\n3 | c\n  |\n",
    );
}

#[test]
fn the_window_starts_counting_where_it_is_told() {
    assert_eq!(
        window("b\nc\n", "B\nc\n", 9),
        "   |\n   - b\n 9 + B\n10 | c\n   |\n",
    );
}
