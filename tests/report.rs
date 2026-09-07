use scylla::allocation;
use scylla::bounded::Span;
use scylla::diagnostic::{FileID, Severity};
use scylla::lines::Index;
use scylla::report::{
    Edit,
    Format,
    Related,
    Report,
    Row,
    Rows,
    Rule,
    Text,
    Tool,
    begin,
    end,
    render,
    render_file,
};
use scylla::sink::{Sink, Target};

const LINE_COUNT_MAX: u32 = 64;
const OUT_BYTES_MAX: u32 = 1 << 16;
const REPORT_LINE_COUNT_MAX: u32 = 1 << 10;

const CHILD: &str = "\n\n\n\n\n{{ block.super }}\n\n\n\n\n\n{% block script %}<script></script>{% \
                     endblock %}\n\n\n\n\n\n<link rel=\"stylesheet\" href=\"{% static \
                     'location/ap.css' %}\">\n";

const CONTEXT: &str = "\n\n\n\n\n<ul class=\"{% if locations %}has-items{% endif %}\">\n\n\x20   \
                       <li>{{ title }}</li>\n";

const RENDER: &str = "    return render(request, 'django/context.html')\n";

const FORMATS: [Format; 12] = [
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

const TOOL: Tool<'static> = Tool {
    information_uri: "https://github.com/stratusadv/parhelion",
    name: "parhelion",
    rule_uri_prefix: "https://github.com/stratusadv/parhelion/blob/main/docs/rules/",
    rule_uri_suffix: ".md",
    version: "<version>",
};

const RULES: [Rule<'static>; 4] = [
    Rule {
        code: "DG004",
        name: "django/unknown-context-variable",
        summary: "Checks for template variables that no view rendering the template puts in its \
                  context, and for variables that some of the rendering views leave out.",
    },
    Rule {
        code: "DG008",
        name: "django/unknown-block",
        summary: "Checks for `{% block %}` tags in a child template whose name no template in its \
                  `{% extends %}` chain defines.",
    },
    Rule {
        code: "DG009",
        name: "django/block-super-outside-block",
        summary: "Checks for `{{ block.super }}` written outside any `{% block %}`, or in a \
                  template that extends nothing.",
    },
    Rule {
        code: "DG013",
        name: "django/unknown-static",
        summary: "Checks for `{% static %}` tags naming a file no `static/` directory in this \
                  project holds.",
    },
];

struct Seed {
    code: &'static str,
    column: u32,
    file: u32,
    length: u32,
    line: u32,
    message: &'static str,
    rule: &'static str,
    severity: Severity,
}

struct RelatedSeed {
    line: u32,
    message: &'static str,
    row: u32,
}

const SEEDS: [Seed; 5] = [
    Seed {
        code: "DG009",
        column: 4,
        file: 0,
        length: 11,
        line: 6,
        message: "`{{ block.super }}` outside any `{% block %}` renders nothing",
        rule: "django/block-super-outside-block",
        severity: Severity::Warning,
    },
    Seed {
        code: "DG008",
        column: 1,
        file: 0,
        length: 49,
        line: 12,
        message: "`script` is not a block `django/base.html` or its parents define",
        rule: "django/unknown-block",
        severity: Severity::Warning,
    },
    Seed {
        code: "DG013",
        column: 41,
        file: 0,
        length: 15,
        line: 18,
        message: "`location/ap.css` is not a file under any `static/` directory this project has",
        rule: "django/unknown-static",
        severity: Severity::Warning,
    },
    Seed {
        code: "DG004",
        column: 18,
        file: 1,
        length: 9,
        line: 6,
        message: "`locations` is not in the context of any view that renders this template. \
                  Rendered by `detail_view` in `./app/location/views.py`, `list_view` in \
                  `./app/location/views.py`, `stale_view` in `./app/location/views.py`",
        rule: "django/unknown-context-variable",
        severity: Severity::Warning,
    },
    Seed {
        code: "DG004",
        column: 12,
        file: 1,
        length: 5,
        line: 8,
        message: "`title` is read here, but `list_view` in `./app/location/views.py`, \
                  `stale_view` in `./app/location/views.py` render this template without it",
        rule: "django/unknown-context-variable",
        severity: Severity::Warning,
    },
];

const RELATED: [RelatedSeed; 5] = [
    RelatedSeed {
        line: 21,
        message: "rendered here by `detail_view` without `locations`",
        row: 3,
    },
    RelatedSeed {
        line: 25,
        message: "rendered here by `list_view` without `locations`",
        row: 3,
    },
    RelatedSeed {
        line: 30,
        message: "rendered here by `stale_view` without `locations`",
        row: 3,
    },
    RelatedSeed {
        line: 25,
        message: "rendered here by `list_view` without `title`",
        row: 4,
    },
    RelatedSeed {
        line: 30,
        message: "rendered here by `stale_view` without `title`",
        row: 4,
    },
];

struct Chunk<'run> {
    count: u32,
    first: u32,
    whole: &'run Fixture,
}

struct Fixture {
    child: Index,
    context: Index,
    views: Index,
    views_source: String,
}

impl Fixture {
    fn new() -> Self {
        let mut child = Index::reserve(LINE_COUNT_MAX);
        let mut context = Index::reserve(LINE_COUNT_MAX);
        let mut views = Index::reserve(LINE_COUNT_MAX);
        let mut views_source = String::new();

        for line in 1..=30 {
            if matches!(line, 21 | 25 | 30) {
                views_source.push_str(RENDER);
            } else {
                views_source.push('\n');
            }
        }

        assert!(child.build(CHILD.as_bytes()));
        assert!(context.build(CONTEXT.as_bytes()));
        assert!(views.build(views_source.as_bytes()));

        Self {
            child,
            context,
            views,
            views_source,
        }
    }

    fn related_seeds(index: u32) -> impl Iterator<Item = &'static RelatedSeed> {
        RELATED.iter().filter(move |seed| seed.row == index)
    }
}

impl Rows for Chunk<'_> {
    fn count(&self) -> u32 {
        self.count
    }

    fn edit(&self, index: u32, at: u32) -> Edit<'_> {
        self.whole.edit(self.first + index, at)
    }

    fn edit_count(&self, index: u32) -> u32 {
        self.whole.edit_count(self.first + index)
    }

    fn related(&self, index: u32, at: u32) -> Related<'_> {
        self.whole.related(self.first + index, at)
    }

    fn related_count(&self, index: u32) -> u32 {
        self.whole.related_count(self.first + index)
    }

    fn row(&self, index: u32) -> Row<'_> {
        assert!(index < self.count);

        self.whole.row(self.first + index)
    }

    fn rule(&self, at: u32) -> Rule<'_> {
        self.whole.rule(at)
    }

    fn rule_count(&self) -> u32 {
        self.whole.rule_count()
    }

    fn text(&self, file: FileID) -> Text<'_> {
        self.whole.text(file)
    }
}

fn span_at(lines: &Index, line: u32, column: u32, length: u32) -> Span {
    let start = lines.line_start(line - 1) + column - 1;

    Span::new(start, length)
}

impl Rows for Fixture {
    fn count(&self) -> u32 {
        u32::try_from(SEEDS.len()).expect("the seed count fits")
    }

    fn edit(&self, _index: u32, _at: u32) -> Edit<'_> {
        unreachable!("no seed carries a fix");
    }

    fn edit_count(&self, _index: u32) -> u32 {
        0
    }

    fn related(&self, index: u32, at: u32) -> Related<'_> {
        let seed = Self::related_seeds(index)
            .nth(at as usize)
            .expect("the related row exists");

        Related {
            file: FileID::of(2),
            message: seed.message.as_bytes(),
            span: span_at(&self.views, seed.line, 28, 21),
        }
    }

    fn related_count(&self, index: u32) -> u32 {
        u32::try_from(Self::related_seeds(index).count()).expect("the related count fits")
    }

    fn row(&self, index: u32) -> Row<'_> {
        let seed = &SEEDS[index as usize];

        let lines = if seed.file == 0 {
            &self.child
        } else {
            &self.context
        };

        Row {
            code: seed.code,
            file: FileID::of(seed.file),
            fix: None,
            message: seed.message.as_bytes(),
            rule: seed.rule,
            severity: seed.severity,
            span: span_at(lines, seed.line, seed.column, seed.length),
        }
    }

    fn rule(&self, at: u32) -> Rule<'_> {
        RULES[at as usize]
    }

    fn rule_count(&self) -> u32 {
        u32::try_from(RULES.len()).expect("the rule count fits")
    }

    fn text(&self, file: FileID) -> Text<'_> {
        match file.index() {
            0 => Text {
                lines: &self.child,
                path: b"./templates/django/child.html",
                source: CHILD.as_bytes(),
            },
            1 => Text {
                lines: &self.context,
                path: b"./templates/django/context.html",
                source: CONTEXT.as_bytes(),
            },
            _ => Text {
                lines: &self.views,
                path: b"./app/location/views.py",
                source: self.views_source.as_bytes(),
            },
        }
    }
}

fn rendered(format: Format) -> String {
    let fixture = Fixture::new();

    rendered_rows(format, &fixture)
}

fn rendered_rows(format: Format, rows: &impl Rows) -> String {
    let mut report = Report::reserve(OUT_BYTES_MAX, REPORT_LINE_COUNT_MAX);
    let mut out = Sink::reserve(OUT_BYTES_MAX, Target::Memory, false);

    allocation::frozen(|| render(&mut out, &mut report, rows, &TOOL, format));

    assert!(!out.is_truncated(), "{}", format.name());
    assert!(!out.is_failed(), "{}", format.name());

    out.as_str().to_owned()
}

fn streamed(format: Format, chunks: &[(u32, u32)]) -> String {
    let fixture = Fixture::new();
    let mut report = Report::reserve(OUT_BYTES_MAX, REPORT_LINE_COUNT_MAX);
    let mut out = Sink::reserve(OUT_BYTES_MAX, Target::Memory, false);

    allocation::frozen(|| {
        begin(&mut out, &mut report, format);

        for (first, count) in chunks {
            let chunk = Chunk {
                count: *count,
                first: *first,
                whole: &fixture,
            };

            render_file(&mut out, &mut report, &chunk, &TOOL, format);
        }

        end(&mut out, &mut report, &fixture, &TOOL, format);
    });

    assert!(!out.is_truncated(), "{}", format.name());
    assert!(!out.is_failed(), "{}", format.name());
    assert!(!report.is_truncated(), "{}", format.name());

    out.as_str().to_owned()
}

#[test]
fn every_format_matches_the_reference_bytes() {
    let goldens = [
        (Format::Azure, include_str!("fixtures/report/azure.txt")),
        (Format::Concise, include_str!("fixtures/report/concise.txt")),
        (Format::Full, include_str!("fixtures/report/full.txt")),
        (Format::Github, include_str!("fixtures/report/github.txt")),
        (Format::Gitlab, include_str!("fixtures/report/gitlab.txt")),
        (Format::Grouped, include_str!("fixtures/report/grouped.txt")),
        (Format::Json, include_str!("fixtures/report/json.txt")),
        (
            Format::JsonLines,
            include_str!("fixtures/report/json-lines.txt"),
        ),
        (Format::Junit, include_str!("fixtures/report/junit.txt")),
        (Format::Pylint, include_str!("fixtures/report/pylint.txt")),
        (Format::Rdjson, include_str!("fixtures/report/rdjson.txt")),
        (Format::Sarif, include_str!("fixtures/report/sarif.txt")),
    ];

    for (format, golden) in goldens {
        assert_eq!(rendered(format), golden, "{}", format.name());
    }
}

#[test]
fn streaming_a_run_file_by_file_matches_rendering_it_whole() {
    for format in FORMATS {
        let whole = rendered(format);

        assert_eq!(streamed(format, &[(0, 3), (3, 2)]), whole, "{}", format.name());
        assert_eq!(streamed(format, &[(0, 3), (3, 0), (3, 2)]), whole, "{}", format.name());
    }
}

#[test]
fn streaming_an_empty_run_matches_rendering_it_whole() {
    let fixture = Fixture::new();

    let empty = Chunk {
        count: 0,
        first: 0,
        whole: &fixture,
    };

    for format in FORMATS {
        assert_eq!(streamed(format, &[]), rendered_rows(format, &empty), "{}", format.name());
    }
}
