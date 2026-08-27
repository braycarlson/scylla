use crate::bounded::Buffer;
use crate::format::{Formatters, Input, Outcome, QuotePreference, print};
use crate::language::Language;
use crate::syntax::front::{self, Front, Limits, Options, Scratch};
use crate::syntax::python::stdlib::PythonVersion;
use crate::token::Tokens;

const FRONT_LIMITS: Limits = Limits {
    binding_count_max: 1 << 14,
    error_count_max: 1 << 10,
    event_count_max: 1 << 19,
    export_count_max: 1 << 12,
    fact_count_max: 1 << 12,
    node_count_max: 1 << 16,
    reference_count_max: 1 << 14,
    scope_count_max: 1 << 12,
    segment_count_max: 1 << 12,
    token_count_max: 1 << 16,
};

const FORMAT_LIMITS: crate::format::Limits = crate::format::Limits {
    arena_bytes_max: 1 << 22,
    element_count_max: 1 << 18,
    line_count_max: 1 << 14,
    pragma_count_max: 1 << 10,
    scratch_bytes_max: 1 << 22,
};

const INPUT: Input = Input {
    line_ending: None,
    magic_trailing_comma: true,
    options: print::Options::DEFAULT,
    quote: QuotePreference::Double,
};

const OPTIONS: Options<'static> = Options {
    globals: &[],
    python_version: PythonVersion::Py310,
};

const OUT_BYTES_MAX: u32 = 1 << 22;

pub struct FormatHarness {
    first: Buffer,
    formatters: Formatters,
    front: Front,
    language: Language,
    lexed: Tokens,
    scratch: Scratch,
    second: Buffer,
}

impl FormatHarness {
    pub fn reserve(language: Language) -> Self {
        assert!(front::lexer_of(language).is_some());
        assert!(!crate::allocation::is_frozen());

        let mut wanted = [false; Language::COUNT];

        wanted[language.index()] = true;

        Self {
            first: Buffer::reserve(OUT_BYTES_MAX),
            formatters: Formatters::reserve(&FORMAT_LIMITS, wanted),
            front: Front::reserve(language, &FRONT_LIMITS),
            language,
            lexed: Tokens::reserve(FRONT_LIMITS.token_count_max),
            scratch: Scratch::reserve(&FRONT_LIMITS, wanted),
            second: Buffer::reserve(OUT_BYTES_MAX),
        }
    }

    pub fn check(&mut self, source: &[u8]) {
        assert!(self.first.capacity() > 0);

        if u32::try_from(source.len()).is_err() {
            return;
        }

        let outcome = pass(
            self.language,
            &mut self.formatters,
            &mut self.front,
            &mut self.lexed,
            &mut self.scratch,
            source,
            &mut self.first,
        );

        if outcome != Outcome::Complete {
            return;
        }

        let repeated = pass(
            self.language,
            &mut self.formatters,
            &mut self.front,
            &mut self.lexed,
            &mut self.scratch,
            self.first.as_bytes(),
            &mut self.second,
        );

        assert_eq!(
            repeated,
            Outcome::Complete,
            "{}: formatted output does not format",
            name_of(self.language)
        );

        assert!(
            self.first.as_bytes() == self.second.as_bytes(),
            "{}: formatting formatted output changes it",
            name_of(self.language)
        );
    }
}

fn name_of(language: Language) -> &'static str {
    front::lexer_of(language).map_or("markup", |lexer| lexer.identifier())
}

fn pass(
    language: Language,
    formatters: &mut Formatters,
    front: &mut Front,
    lexed: &mut Tokens,
    scratch: &mut Scratch,
    source: &[u8],
    out: &mut Buffer,
) -> Outcome {
    assert!(u32::try_from(source.len()).is_ok());

    let held = front::lexer_of(language).expect("the harness holds a lexed language");

    lexed.clear();
    held.lex(source, lexed);
    front.build(source, lexed.as_slice(), scratch, &OPTIONS);
    out.clear();

    formatters.format(front, lexed.as_slice(), source, &INPUT, out)
}
