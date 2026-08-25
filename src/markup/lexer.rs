use crate::markup::kind::MarkupKind;
use crate::markup::token::{Tokens, length_of};
use crate::token::Lex;

const VERBATIM_END_TAG_NAME: &[u8] = b"endverbatim";
const VERBATIM_SCAN_BYTES_MAX: u32 = 1_024;
const VERBATIM_TAG_NAME: &[u8] = b"verbatim";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Mode {
    AttributeValue(u8),
    HTMLComment,
    RawText(RawKind),
    Tag,
    Text,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RawKind {
    Script,
    Style,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Name {
    end: u32,
    start: u32,
}

struct Lexer<'source, 'tokens> {
    after_equals: bool,
    length: u32,
    mode: Mode,
    position: u32,
    raw_pending: Option<RawKind>,
    source: &'source [u8],
    tokens: &'tokens mut Tokens,
    truncated: bool,
}

impl RawKind {
    const fn element_name(self) -> &'static [u8] {
        match self {
            Self::Script => b"script",
            Self::Style => b"style",
        }
    }

    fn of_element_name(name: &[u8]) -> Option<Self> {
        if name.eq_ignore_ascii_case(b"script") {
            return Some(Self::Script);
        }

        if name.eq_ignore_ascii_case(b"style") {
            return Some(Self::Style);
        }

        None
    }

    const fn text_kind(self) -> MarkupKind {
        match self {
            Self::Script => MarkupKind::ScriptText,
            Self::Style => MarkupKind::StyleText,
        }
    }
}

impl Name {
    const EMPTY: Self = Self { end: 0, start: 0 };

    const fn is_empty(self) -> bool {
        self.end <= self.start
    }
}

impl<'source, 'tokens> Lexer<'source, 'tokens> {
    fn new(source: &'source [u8], tokens: &'tokens mut Tokens) -> Self {
        let length = length_of(source);

        assert_eq!(tokens.count(), 0);

        Self {
            after_equals: false,
            length,
            mode: Mode::Text,
            position: 0,
            raw_pending: None,
            source,
            tokens,
            truncated: false,
        }
    }

    fn advance(&mut self, count: u32) {
        self.position = self.position.saturating_add(count).min(self.length);

        assert!(self.position <= self.length);
    }

    fn byte_ahead(&self, position: u32, offset: u32) -> Option<u8> {
        let target = position.checked_add(offset)?;

        self.byte_at(target)
    }

    fn byte_at(&self, position: u32) -> Option<u8> {
        self.source.get(position as usize).copied()
    }

    fn close_open_tag(&mut self) {
        self.after_equals = false;

        self.mode = match self.raw_pending.take() {
            Some(kind) => Mode::RawText(kind),
            None => Mode::Text,
        };
    }

    fn is_interior_boundary(&self, position: u32, closer: &[u8]) -> bool {
        let Some(byte) = self.byte_at(position) else {
            return true;
        };

        if byte.is_ascii_whitespace() || byte == b'"' || byte == b'\'' {
            return true;
        }

        if interior_punctuation(byte).is_some() {
            return true;
        }

        self.matches_at(position, closer)
    }

    fn is_name_byte(&self, position: u32) -> bool {
        let Some(byte) = self.byte_at(position) else {
            return false;
        };

        !byte.is_ascii_whitespace()
            && byte != b'/'
            && byte != b'>'
            && byte != b'='
            && !self.is_template_open(position)
    }

    fn is_name_start(&self, position: u32) -> bool {
        self.byte_at(position)
            .is_some_and(|byte| byte.is_ascii_alphabetic())
    }

    fn is_number_byte(&self, position: u32) -> bool {
        let Some(byte) = self.byte_at(position) else {
            return false;
        };

        if byte.is_ascii_digit() {
            return true;
        }

        byte == b'.'
            && self
                .byte_ahead(position, 1)
                .is_some_and(|next| next.is_ascii_digit())
    }

    fn is_raw_text_end(&self, position: u32, kind: RawKind) -> bool {
        if !self.matches_at(position, b"</") {
            return false;
        }

        let name = kind.element_name();

        let Some(after_slash) = position.checked_add(2) else {
            return false;
        };

        let start = after_slash as usize;

        let Some(end) = start.checked_add(name.len()) else {
            return false;
        };

        let Some(candidate) = self.source.get(start..end) else {
            return false;
        };

        candidate.eq_ignore_ascii_case(name)
    }

    fn is_tag_run_boundary(&self, position: u32) -> bool {
        let Some(byte) = self.byte_at(position) else {
            return true;
        };

        if byte.is_ascii_whitespace() || matches!(byte, b'>' | b'=' | b'"' | b'\'') {
            return true;
        }

        if byte == b'/' && self.byte_ahead(position, 1) == Some(b'>') {
            return true;
        }

        self.is_template_open(position)
    }

    fn is_template_open(&self, position: u32) -> bool {
        self.byte_at(position) == Some(b'{')
            && matches!(self.byte_ahead(position, 1), Some(b'{' | b'%' | b'#'))
    }

    fn is_verbatim_end(&self, position: u32) -> bool {
        if !self.matches_at(position, b"{%") {
            return false;
        }

        let Some(after_open) = position.checked_add(2) else {
            return false;
        };

        let start = after_open as usize;

        let end = start
            .saturating_add(VERBATIM_SCAN_BYTES_MAX as usize)
            .min(self.source.len());

        let Some(window) = self.source.get(start..end) else {
            return false;
        };

        let Some(close) = window.windows(2).position(|pair| pair == b"%}") else {
            return false;
        };

        let Some(name) = window.get(..close) else {
            return false;
        };

        name.trim_ascii() == VERBATIM_END_TAG_NAME
    }

    fn matches_at(&self, position: u32, needle: &[u8]) -> bool {
        let start = position as usize;

        let Some(end) = start.checked_add(needle.len()) else {
            return false;
        };

        self.source.get(start..end) == Some(needle)
    }

    fn name_bytes(&self, name: Name) -> &'source [u8] {
        assert!(name.end <= self.length);

        self.source
            .get(name.start as usize..name.end as usize)
            .unwrap_or_default()
    }

    fn push(&mut self, kind: MarkupKind, start: u32, end: u32) {
        assert!(start <= end);

        if self.truncated {
            return;
        }

        if end <= start {
            return;
        }

        if self.tokens.count() + 1 < self.tokens.count_max() && self.tokens.push(kind, start, end) {
            return;
        }

        self.truncated = true;
        self.position = self.length;
    }

    fn scan_while(&mut self, keep: fn(&Self, u32) -> bool) {
        while self.position < self.length && keep(self, self.position) {
            self.advance(1);
        }

        assert!(self.position <= self.length);
    }

    fn lex_angle(&mut self) {
        assert_eq!(self.byte_at(self.position), Some(b'<'));

        let start = self.position;

        if self.matches_at(start, b"<!--") {
            self.advance(4);
            self.push(MarkupKind::HTMLCommentOpen, start, self.position);
            self.mode = Mode::HTMLComment;

            return;
        }

        if self.matches_at(start, b"<!") || self.matches_at(start, b"<?") {
            self.lex_markup_declaration();

            return;
        }

        if self.matches_at(start, b"</") && self.is_name_start(start.saturating_add(2)) {
            self.lex_close_tag_name();

            return;
        }

        if self.is_name_start(start.saturating_add(1)) {
            self.advance(1);
            self.push(MarkupKind::AngleOpen, start, self.position);

            let name = self.lex_element_name();

            self.raw_pending = RawKind::of_element_name(self.name_bytes(name));
            self.mode = Mode::Tag;

            return;
        }

        self.advance(1);
        self.push(MarkupKind::Text, start, self.position);
    }

    fn lex_close_tag_name(&mut self) {
        assert!(self.matches_at(self.position, b"</"));

        let start = self.position;

        self.advance(2);
        self.push(MarkupKind::AngleOpenSlash, start, self.position);
        let _ = self.lex_element_name();

        self.raw_pending = None;
        self.mode = Mode::Tag;
    }

    fn lex_delimited(&mut self, open: MarkupKind, close: MarkupKind, closer: &[u8]) -> Name {
        let start = self.position;

        self.advance(2);
        self.push(open, start, self.position);

        let mut name = Name::EMPTY;
        let mut first = open == MarkupKind::TagOpen;

        while self.position < self.length {
            if self.matches_at(self.position, closer) {
                let close_start = self.position;

                self.advance(length_of(closer));
                self.push(close, close_start, self.position);

                return name;
            }

            let scanned = self.lex_interior_token(closer, first);

            if first && !scanned.is_empty() {
                name = scanned;
                first = false;
            }
        }

        name
    }

    fn lex_element_name(&mut self) -> Name {
        let start = self.position;

        self.scan_while(Self::is_name_byte);

        if self.position == start {
            return Name::EMPTY;
        }

        let end = self.position;

        self.push(MarkupKind::ElementName, start, end);

        Name { end, start }
    }

    fn lex_interior_string(&mut self, quote: u8) {
        let start = self.position;

        self.advance(1);

        while self.position < self.length {
            let Some(byte) = self.byte_at(self.position) else {
                break;
            };

            if byte == b'\n' {
                break;
            }

            if byte == b'\\' {
                self.advance(2);

                continue;
            }

            self.advance(1);

            if byte == quote {
                break;
            }
        }

        self.push(MarkupKind::String, start, self.position);
    }

    fn lex_interior_token(&mut self, closer: &[u8], first: bool) -> Name {
        let start = self.position;

        let Some(byte) = self.byte_at(start) else {
            return Name::EMPTY;
        };

        if byte.is_ascii_whitespace() {
            self.lex_whitespace();

            return Name::EMPTY;
        }

        if let Some(kind) = interior_punctuation(byte) {
            self.advance(1);
            self.push(kind, start, self.position);

            return Name::EMPTY;
        }

        if byte == b'"' || byte == b'\'' {
            self.lex_interior_string(byte);

            return Name::EMPTY;
        }

        if byte.is_ascii_digit() {
            self.scan_while(Self::is_number_byte);
            self.push(MarkupKind::Number, start, self.position);

            return Name::EMPTY;
        }

        let kind = if first {
            MarkupKind::TagName
        } else {
            MarkupKind::Identifier
        };

        self.scan_interior_run(closer);

        if self.position == start {
            self.advance(1);
        }

        let end = self.position;

        self.push(kind, start, end);

        Name { end, start }
    }

    fn lex_markup_declaration(&mut self) {
        let start = self.position;

        self.advance(2);
        self.scan_while(|lexer, position| lexer.byte_at(position) != Some(b'>'));

        if self.position < self.length {
            self.advance(1);
        }

        self.push(MarkupKind::DoctypeText, start, self.position);
    }

    fn lex_tag_punctuation(&mut self, byte: u8) -> bool {
        let start = self.position;

        if byte == b'>' {
            self.advance(1);
            self.push(MarkupKind::AngleClose, start, self.position);
            self.close_open_tag();

            return true;
        }

        if byte == b'/' && self.byte_ahead(start, 1) == Some(b'>') {
            self.advance(2);
            self.push(MarkupKind::SlashAngleClose, start, self.position);

            self.raw_pending = None;
            self.mode = Mode::Text;
            self.after_equals = false;

            return true;
        }

        if byte == b'=' {
            self.advance(1);
            self.push(MarkupKind::Equals, start, self.position);

            self.after_equals = true;

            return true;
        }

        if byte == b'"' || byte == b'\'' {
            self.advance(1);
            self.push(MarkupKind::Quote, start, self.position);

            self.mode = Mode::AttributeValue(byte);

            return true;
        }

        false
    }

    fn lex_template_comment(&mut self) {
        let start = self.position;

        self.advance(2);
        self.push(MarkupKind::CommentOpen, start, self.position);

        let text_start = self.position;

        self.scan_while(|lexer, position| !lexer.matches_at(position, b"#}"));
        self.push(MarkupKind::CommentText, text_start, self.position);

        if self.matches_at(self.position, b"#}") {
            let close_start = self.position;

            self.advance(2);
            self.push(MarkupKind::CommentClose, close_start, self.position);
        }
    }

    fn lex_template_construct(&mut self) -> bool {
        if self.byte_at(self.position) != Some(b'{') {
            return false;
        }

        match self.byte_ahead(self.position, 1) {
            Some(b'{') => {
                let _ =
                    self.lex_delimited(MarkupKind::VariableOpen, MarkupKind::VariableClose, b"}}");

                true
            }
            Some(b'%') => {
                self.lex_template_tag();

                true
            }
            Some(b'#') => {
                self.lex_template_comment();

                true
            }
            _ => false,
        }
    }

    fn lex_template_tag(&mut self) {
        let name = self.lex_delimited(MarkupKind::TagOpen, MarkupKind::TagClose, b"%}");

        if self.name_bytes(name) == VERBATIM_TAG_NAME {
            self.lex_verbatim_body();
        }
    }

    fn lex_verbatim_body(&mut self) {
        let start = self.position;

        self.scan_while(|lexer, position| !lexer.is_verbatim_end(position));
        self.push(MarkupKind::VerbatimText, start, self.position);
    }

    fn lex_whitespace(&mut self) {
        let start = self.position;

        self.scan_while(|lexer, position| {
            lexer
                .byte_at(position)
                .is_some_and(|byte| byte.is_ascii_whitespace())
        });

        self.push(MarkupKind::Whitespace, start, self.position);
    }

    fn scan_interior_run(&mut self, closer: &[u8]) {
        while self.position < self.length && !self.is_interior_boundary(self.position, closer) {
            self.advance(1);
        }

        assert!(self.position <= self.length);
    }

    fn run(&mut self) -> Lex {
        while self.position < self.length {
            let start = self.position;

            self.step();

            if self.truncated {
                break;
            }

            if self.position <= start {
                self.push(MarkupKind::ErrorToken, start, self.length);
                self.position = self.length;

                break;
            }
        }

        if self.truncated {
            let start = self.tokens.end_previous();

            assert!(start <= self.length);

            let covered = self.tokens.push(MarkupKind::ErrorToken, start, self.length);

            assert!(covered);

            return Lex::Truncated;
        }

        assert_eq!(self.position, self.length);

        Lex::Complete
    }

    fn step(&mut self) {
        match self.mode {
            Mode::AttributeValue(quote) => self.step_attribute_value(quote),
            Mode::HTMLComment => self.step_html_comment(),
            Mode::RawText(kind) => self.step_raw_text(kind),
            Mode::Tag => self.step_tag(),
            Mode::Text => self.step_text(),
        }
    }

    fn step_attribute_value(&mut self, quote: u8) {
        if self.lex_template_construct() {
            return;
        }

        if self.byte_at(self.position) == Some(quote) {
            let start = self.position;

            self.advance(1);
            self.push(MarkupKind::Quote, start, self.position);

            self.mode = Mode::Tag;
            self.after_equals = false;

            return;
        }

        let start = self.position;

        while self.position < self.length
            && self.byte_at(self.position) != Some(quote)
            && !self.is_template_open(self.position)
        {
            self.advance(1);
        }

        self.push(MarkupKind::AttributeText, start, self.position);
    }

    fn step_html_comment(&mut self) {
        if self.lex_template_construct() {
            return;
        }

        if self.matches_at(self.position, b"-->") {
            let start = self.position;

            self.advance(3);
            self.push(MarkupKind::HTMLCommentClose, start, self.position);

            self.mode = Mode::Text;

            return;
        }

        let start = self.position;

        self.advance(1);

        self.scan_while(|lexer, position| {
            lexer.byte_at(position) != Some(b'-') && !lexer.is_template_open(position)
        });

        self.push(MarkupKind::Text, start, self.position);
    }

    fn step_raw_text(&mut self, kind: RawKind) {
        if self.lex_template_construct() {
            return;
        }

        if self.is_raw_text_end(self.position, kind) {
            self.lex_close_tag_name();

            return;
        }

        let start = self.position;

        self.advance(1);

        self.scan_while(|lexer, position| {
            lexer.byte_at(position) != Some(b'<') && !lexer.is_template_open(position)
        });

        self.push(kind.text_kind(), start, self.position);
    }

    fn step_tag(&mut self) {
        if self.lex_template_construct() {
            return;
        }

        let Some(byte) = self.byte_at(self.position) else {
            return;
        };

        if byte.is_ascii_whitespace() {
            self.lex_whitespace();

            return;
        }

        if self.lex_tag_punctuation(byte) {
            return;
        }

        let kind = if self.after_equals {
            MarkupKind::AttributeText
        } else {
            MarkupKind::AttributeName
        };

        let start = self.position;

        self.scan_while(|lexer, position| !lexer.is_tag_run_boundary(position));
        self.push(kind, start, self.position);

        self.after_equals = false;
    }

    fn step_text(&mut self) {
        if self.lex_template_construct() {
            return;
        }

        if self.byte_at(self.position) == Some(b'<') {
            self.lex_angle();

            return;
        }

        let start = self.position;

        self.scan_while(|lexer, position| {
            lexer.byte_at(position) != Some(b'<') && !lexer.is_template_open(position)
        });

        self.push(MarkupKind::Text, start, self.position);
    }
}

const fn interior_punctuation(byte: u8) -> Option<MarkupKind> {
    match byte {
        b'|' => Some(MarkupKind::Pipe),
        b':' => Some(MarkupKind::Colon),
        b',' => Some(MarkupKind::Comma),
        b'.' => Some(MarkupKind::Dot),
        b'=' => Some(MarkupKind::Equals),
        _ => None,
    }
}

pub fn lex(source: &[u8], tokens: &mut Tokens) -> Lex {
    assert!(u32::try_from(source.len()).is_ok());

    tokens.clear();

    let mut lexer = Lexer::new(source, tokens);

    lexer.run()
}
