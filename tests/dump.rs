#![expect(
    clippy::print_stdout,
    clippy::use_debug,
    reason = "a tool run by hand that prints a tree"
)]

use scylla::language::Language;
use scylla::syntax::front::{self, Front, Limits, Options, Scratch};
use scylla::syntax::python::stdlib::PythonVersion;
use scylla::syntax::view::View;
use scylla::token::Tokens;

const OPTIONS: Options<'static> = Options {
    globals: &[],
    python_version: PythonVersion::Py310,
    template_imports: &[],
};

const LIMITS: Limits = Limits {
    binding_count_max: 1 << 12,
    error_count_max: 1 << 8,
    event_count_max: 1 << 18,
    export_count_max: 1 << 10,
    fact_count_max: 1 << 10,
    node_count_max: 1 << 16,
    reference_count_max: 1 << 12,
    scope_count_max: 1 << 10,
    segment_count_max: 1 << 10,
    token_count_max: 1 << 16,
};

fn kind_name(held: View<'_>) -> String {
    match held {
        View::Go(view) => format!("{:?}", view.kind()),
        View::JavaScript(view) => format!("{:?}", view.kind()),
        View::Odin(view) => format!("{:?}", view.kind()),
        View::Python(view) => format!("{:?}", view.kind()),
        View::Rust(view) => format!("{:?}", view.kind()),
        View::TypeScript(view) => format!("{:?}", view.kind()),
        View::Zig(view) => format!("{:?}", view.kind()),
    }
}

fn show(front: &Front, source: &[u8], held: View<'_>, depth: usize) {
    let positions: Vec<String> = held
        .positions()
        .map(|position| {
            String::from_utf8_lossy(front.tokens()[position as usize].text(source)).into_owned()
        })
        .collect();

    println!(
        "{}{:?} #{} [{}..{}] {:?} {}",
        "  ".repeat(depth),
        held.category(),
        held.index(),
        held.token_start(),
        held.token_end(),
        positions,
        kind_name(held)
    );

    let mut stack = vec![(held, depth)];
    let _ = stack.pop();

    for child in held.children() {
        show_child(front, source, child, depth + 1);
    }
}

fn show_child(front: &Front, source: &[u8], held: View<'_>, depth: usize) {
    show(front, source, held, depth);
}

#[test]
#[ignore = "a tool run by hand with DUMP_LANGUAGE and DUMP_SOURCE set"]
fn dump() {
    let named = std::env::var("DUMP_LANGUAGE").expect("DUMP_LANGUAGE names a language");
    let language = Language::of_name(&named).expect("a known language");
    let text = std::env::var("DUMP_SOURCE").expect("DUMP_SOURCE holds the text");
    let unescaped = text.replace("\\n", "\n").replace("\\t", "\t");
    let source = unescaped.as_bytes();
    let mut front = Front::reserve(language, &LIMITS);
    let mut wanted = [false; Language::COUNT];

    wanted[language.index()] = true;

    let mut scratch = Scratch::reserve(&LIMITS, wanted);
    let mut lexed = Tokens::reserve(LIMITS.token_count_max);

    front::lexer_of(language)
        .expect("a lexer")
        .lex(source, &mut lexed);

    let outcome = front.build(source, lexed.as_slice(), &mut scratch, &OPTIONS);

    println!("outcome {outcome:?}");

    for error in front.errors() {
        println!(
            "error {:?} at {}..{}",
            error.kind,
            error.span.offset,
            error.span.end()
        );
    }

    if let Some(root) = front.root() {
        show(&front, source, root, 0);
    }

    let bindings = front.bindings();

    for index in 0..bindings.count() {
        let Some(binding) = bindings.at(index) else {
            continue;
        };

        println!(
            "binding #{index} {:?} {:?} node #{} scope {}",
            binding.class,
            String::from_utf8_lossy(&source[binding.name.range()]),
            binding.node,
            binding.scope
        );
    }

    for index in 0..bindings.reference_count() {
        let Some(reference) = bindings.reference_at(index) else {
            continue;
        };

        println!(
            "reference #{index} {:?} {:?} node #{} scope {}",
            reference.resolution,
            String::from_utf8_lossy(&source[reference.name.range()]),
            reference.node,
            reference.scope
        );
    }
}
