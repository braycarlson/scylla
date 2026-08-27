use scylla::bounded::{BoundedVec, Buffer};
use scylla::language::Lexer;
use scylla::syntax::{Structure, SyntaxError};
use scylla::token::{Token, Tokens};
use scylla::tree::{Events, Kind, Tree};

use crate::binder::Binder;
use crate::format::{buffer, Print, Printer};

const ERROR_COUNT_MAX: u32 = 1 << 10;
const EVENT_COUNT_MAX: u32 = 1 << 22;
const NODE_COUNT_MAX: u32 = 1 << 21;
const TOKEN_COUNT_MAX: u32 = 1 << 21;

pub type Build<K> = fn(&[u8], &[Token], &[K], &mut Events<K>, &mut Tree<K>) -> Structure;
pub type Classify<K> = fn(&[u8], &[Token], &mut Tokens, &mut BoundedVec<K>) -> bool;
pub type Error<K> = fn(<K as Kind>::Error) -> &'static str;
pub type ErrorSpan<K> = fn(<K as Kind>::Error) -> u32;
pub type Name<K> = fn(K) -> &'static str;

pub struct Read {
    pub accepted: bool,
    pub error: &'static str,
    pub error_offset: u32,
    pub nodes: Vec<(String, u32, u32)>,
    pub outcome: &'static str,
    pub tokens: Vec<(u32, u32)>,
}

pub struct Bound {
    pub complete: bool,
    pub limit: &'static str,
}

pub trait Analyzer {
    fn bind(&mut self, source: &[u8]) -> Option<Bound>;

    fn read(&mut self, source: &[u8]) -> Read;

    fn print(&mut self, source: &[u8]) -> Option<Vec<u8>>;

    fn lexer(&self) -> &'static dyn Lexer;
}

pub struct Native<K: Kind> {
    binder: Option<Box<dyn Binder<K>>>,
    build: Build<K>,
    classify: Classify<K>,
    error: Error<K>,
    error_span: ErrorSpan<K>,
    events: Events<K>,
    lexed: Tokens,
    lexer: &'static dyn Lexer,
    name: Name<K>,
    out: Buffer,
    printer: Box<dyn Printer<K>>,
    raw: BoundedVec<K>,
    tokens: Tokens,
    tree: Tree<K>,
}

impl<K: Kind> Native<K> {
    pub fn reserve(
        lexer: &'static dyn Lexer,
        classify: Classify<K>,
        build: Build<K>,
        name: Name<K>,
        printer: Box<dyn Printer<K>>,
        binder: Option<Box<dyn Binder<K>>>,
    ) -> Self
    where
        K: Kind<Error = SyntaxError>,
    {
        Self {
            binder,
            build,
            classify,
            error: |held: SyntaxError| held.kind.message(),
            error_span: |held: SyntaxError| held.span.offset,
            events: Events::reserve(EVENT_COUNT_MAX),
            lexed: Tokens::reserve(TOKEN_COUNT_MAX),
            lexer,
            name,
            out: buffer(),
            printer,
            raw: BoundedVec::reserve(TOKEN_COUNT_MAX),
            tokens: Tokens::reserve(TOKEN_COUNT_MAX),
            tree: Tree::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX),
        }
    }

    fn built(&mut self, source: &[u8]) -> Option<Structure> {
        self.lexed.clear();
        self.lexer.lex(source, &mut self.lexed);

        let classified = (self.classify)(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw,
        );

        if !classified {
            return None;
        }

        self.tree.clear();

        Some((self.build)(
            source,
            self.tokens.as_slice(),
            &self.raw,
            &mut self.events,
            &mut self.tree,
        ))
    }
}

impl<K: Kind> Analyzer for Native<K> {
    fn bind(&mut self, source: &[u8]) -> Option<Bound> {
        let mut binder = self.binder.take()?;
        let outcome = self.built(source);

        let held = match outcome {
            Some(Structure::Complete) if self.tree.errors().is_empty() => {
                Some(binder.bind(source, self.tokens.as_slice(), &self.raw, &self.tree))
            }
            Some(_) | None => None,
        };

        self.binder = Some(binder);

        held
    }

    fn lexer(&self) -> &'static dyn Lexer {
        self.lexer
    }

    fn print(&mut self, source: &[u8]) -> Option<Vec<u8>> {
        let outcome = self.built(source)?;

        if outcome != Structure::Complete || !self.tree.errors().is_empty() {
            return None;
        }

        self.out.clear();

        let held = Print {
            outcome,
            raw: &self.raw,
            source,
            tokens: self.tokens.as_slice(),
            tree: &self.tree,
        };

        if !self.printer.print(&held, &mut self.out) {
            return None;
        }

        Some(self.out.as_bytes().to_vec())
    }

    fn read(&mut self, source: &[u8]) -> Read {
        self.lexed.clear();
        self.lexer.lex(source, &mut self.lexed);

        let classified = (self.classify)(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw,
        );

        if !classified {
            return Read {
                accepted: false,
                error: "none",
                error_offset: 0,
                nodes: Vec::new(),
                outcome: "overran",
                tokens: Vec::new(),
            };
        }

        self.tree.clear();

        let outcome = (self.build)(
            source,
            self.tokens.as_slice(),
            &self.raw,
            &mut self.events,
            &mut self.tree,
        );

        let held = self.tokens.as_slice();

        let tokens: Vec<(u32, u32)> = held
            .iter()
            .map(|token| (token.offset, token.offset + token.length))
            .collect();

        let nodes: Vec<(String, u32, u32)> = self
            .tree
            .as_slice()
            .iter()
            .map(|node| {
                let span = node.span(held);

                ((self.name)(node.kind).to_owned(), span.offset, span.end())
            })
            .collect();

        Read {
            accepted: outcome == Structure::Complete && self.tree.errors().is_empty(),
            error: self
                .tree
                .errors()
                .first()
                .map_or("none", |held| (self.error)(*held)),
            error_offset: self
                .tree
                .errors()
                .first()
                .map_or(0, |held| (self.error_span)(*held)),
            nodes,
            outcome: name_of(outcome),
            tokens,
        }
    }
}

fn name_of(outcome: Structure) -> &'static str {
    match outcome {
        Structure::Complete => "complete",
        Structure::TooDeep => "too-deep",
        Structure::Truncated => "truncated",
    }
}
