use crate::bounded::{BoundedVec, Span, count_of};
use crate::graph::{self, Scratch};
use crate::scan::find;
use crate::syntax::Category;
use crate::syntax::binding::{Binding, BindingClass, Reference, Resolution};
use crate::syntax::front::Front;
use crate::syntax::view::{Call, Declaration, Function as FunctionView, View};
use crate::token::{Keyword, Punctuation, Token, TokenKind};

const VOID_TYPES: &[&[u8]] = &[b"()", b"!noreturn", b"!void", b"None", b"noreturn", b"void"];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Returns<'run> {
    pub nothing_words: &'run [&'run [u8]],
    pub optional_markers: &'run [&'run [u8]],
    pub spelled: bool,
}

#[derive(Clone, Copy, Debug)]
pub struct Alias {
    pub name: Span,
    pub target: Span,
}

#[derive(Clone, Copy, Debug)]
pub struct Edge {
    pub call: Span,
    pub source: u32,
    pub target: u32,
}

#[derive(Clone, Copy, Debug)]
pub struct Field {
    pub container: Span,
    pub indexed: bool,
    pub name: Span,
    pub spelled: Span,
}

#[derive(Clone, Copy, Debug)]
pub struct Function {
    pub binding: u32,
    pub comptime: bool,
    pub container: Span,
    pub edge_count: u32,
    pub edge_start: u32,
    pub fallible: bool,
    pub name: Span,
    pub node: u32,
    pub recursive: bool,
    pub value: bool,
}

#[derive(Debug)]
pub struct Tables {
    aliases: BoundedVec<Alias>,
    edges: BoundedVec<Edge>,
    fields: BoundedVec<Field>,
    functions: BoundedVec<Function>,
    marks: BoundedVec<bool>,
    names: BoundedVec<u32>,
    nodes: BoundedVec<u32>,
    scratch: Scratch,
}

impl Tables {
    pub fn reserve(function_count_max: u32, edge_count_max: u32) -> Self {
        assert!(function_count_max > 0);
        assert!(edge_count_max > 0);
        assert!(!crate::allocation::is_frozen());

        Self {
            aliases: BoundedVec::reserve(function_count_max),
            edges: BoundedVec::reserve(edge_count_max),
            fields: BoundedVec::reserve(function_count_max),
            functions: BoundedVec::reserve(function_count_max),
            marks: BoundedVec::reserve(function_count_max),
            names: BoundedVec::reserve(function_count_max),
            nodes: BoundedVec::reserve(function_count_max),
            scratch: Scratch::reserve(function_count_max),
        }
    }

    pub fn alias_of(&self, name: &[u8], source: &[u8]) -> Option<Span> {
        for alias in self.aliases.iter() {
            if &source[alias.name.range()] == name {
                return Some(alias.target);
            }
        }

        None
    }

    pub fn function_of(&self, name: &[u8], source: &[u8]) -> Option<&Function> {
        if name.is_empty() {
            return None;
        }

        let first = self.names_start(name, source);

        if first == self.names.count() as usize {
            return None;
        }

        let position = self.names[first] as usize;

        if &source[self.functions[position].name.range()] != name {
            return None;
        }

        Some(&self.functions[position])
    }

    pub fn value_of(&self, name: &[u8], source: &[u8]) -> Option<bool> {
        if name.is_empty() {
            return None;
        }

        let first = self.names_start(name, source);
        let mut held = None;

        for offset in first..self.names.count() as usize {
            let position = self.names[offset] as usize;

            if &source[self.functions[position].name.range()] != name {
                break;
            }

            let value = self.functions[position].value;

            match held {
                None => held = Some(value),
                Some(seen) if seen == value => {}
                Some(_) => return None,
            }
        }

        held
    }

    fn names_index(&mut self, source: &[u8]) {
        assert!(self.names.is_empty());

        for position in 0..self.functions.count() {
            self.names.push_assert(position);
        }

        let functions = &self.functions;

        self.names.sort_unstable_by(|left, right| {
            let named = &source[functions[*left as usize].name.range()];
            let other = &source[functions[*right as usize].name.range()];

            named.cmp(other).then(left.cmp(right))
        });

        assert_eq!(self.names.count(), self.functions.count());
    }

    fn nodes_index(&mut self) {
        assert!(self.nodes.is_empty());

        for position in 0..self.functions.count() {
            self.nodes.push_assert(position);
        }

        let functions = &self.functions;

        self.nodes
            .sort_unstable_by_key(|position| (functions[*position as usize].node, *position));

        assert_eq!(self.nodes.count(), self.functions.count());
    }

    fn names_start(&self, name: &[u8], source: &[u8]) -> usize {
        assert!(!name.is_empty());

        self.names.partition_point(|position| {
            &source[self.functions[*position as usize].name.range()] < name
        })
    }

    pub fn functions(&self) -> &[Function] {
        &self.functions
    }

    pub fn edges_of(&self, function: &Function) -> &[Edge] {
        let start = function.edge_start as usize;
        let end = start + function.edge_count as usize;

        assert!(end <= self.edges.count() as usize);

        &self.edges[start..end]
    }

    pub fn build(&mut self, front: &Front, source: &[u8], returns: &Returns<'_>) {
        self.aliases.clear();
        self.fields.clear();
        self.edges.clear();
        self.functions.clear();
        self.names.clear();
        self.nodes.clear();

        self.functions_collect(front, source, returns);
        self.names_index(source);
        self.nodes_index();
        self.values_mark(front, source, returns);
        self.edges_collect(front, source);
        self.aliases_collect(front, source);
        self.cycles_mark();
    }

    fn aliases_collect(&mut self, front: &Front, source: &[u8]) {
        let tokens = front.tokens();

        for position in front.index_of(Category::Declaration) {
            let Some(node) = front.view(*position) else {
                continue;
            };
            let Some(declaration) = node.as_declaration() else {
                continue;
            };
            let Some(name) = declaration.name_token() else {
                continue;
            };
            let Some(value) = declaration.value() else {
                continue;
            };

            assert!((name as usize) < tokens.len());

            if !is_bare_path(&source[value.span().range()]) {
                continue;
            }

            let pushed = self.aliases.push(Alias {
                name: tokens[name as usize].span(),
                target: value.span(),
            });

            if !pushed {
                return;
            }
        }
    }

    fn edges_collect(&mut self, front: &Front, source: &[u8]) {
        self.fields_collect(front, source);
        self.calls_collect(front);
        self.methods_collect(front, source);

        self.edges
            .sort_unstable_by_key(|edge| (edge.source, edge.call.offset, edge.target));

        self.edges_range();
    }

    fn calls_collect(&mut self, front: &Front) {
        let bindings = front.bindings();

        for index in 0..bindings.reference_count() {
            let Some(reference) = bindings.reference_at(index) else {
                continue;
            };
            let Resolution::Bound(binding) = reference.resolution else {
                continue;
            };
            let Some(target) = self.row_of_binding(binding) else {
                continue;
            };
            let Some(node) = callee_call_of(front, reference) else {
                continue;
            };

            if !self.edges_push(node, node.span(), target) {
                return;
            }
        }
    }

    fn fields_collect(&mut self, front: &Front, source: &[u8]) {
        let tokens = front.tokens();

        for position in front.index_of(Category::Struct) {
            let Some(node) = front.view(*position) else {
                continue;
            };
            let Some(container) = node.as_container() else {
                continue;
            };
            let Some(named) = container.name_token() else {
                continue;
            };
            let held = tokens[named as usize].span();

            for member in container.body().children() {
                let Some(name) = member.name_token() else {
                    continue;
                };
                let Some(spelled) = member.type_of() else {
                    continue;
                };
                let Some(leaf) = first_name_of(front, spelled, source) else {
                    continue;
                };

                let pushed = self.fields.push(Field {
                    container: held,
                    indexed: spells_an_index(&source[spelled.span().range()]),
                    name: tokens[name as usize].span(),
                    spelled: leaf,
                });

                if !pushed {
                    return;
                }
            }
        }
    }

    fn field_type_of(&self, held: &[u8], name: &[u8], source: &[u8]) -> Option<(Span, bool)> {
        if held.is_empty() || name.is_empty() {
            return None;
        }

        let mut found = None;

        for field in self.fields.iter() {
            if &source[field.name.range()] != name || &source[field.container.range()] != held {
                continue;
            }

            if found.is_some() {
                return None;
            }

            found = Some((field.spelled, field.indexed));
        }

        found
    }

    fn methods_collect(&mut self, front: &Front, source: &[u8]) {
        let tokens = front.tokens();

        for position in front.index_of(Category::Call) {
            let Some(node) = front.view(*position) else {
                continue;
            };
            let Some(call) = node.as_call() else {
                continue;
            };
            let Some(name) = call.name_token() else {
                continue;
            };

            assert!((name as usize) < tokens.len());

            let method = tokens[name as usize].text(source);

            let held = match call.receiver() {
                Some(receiver) => self.receiver_type_of(front, node, receiver, source),
                None => self.path_head_of(front, node, call, source),
            };

            let Some(target) = self.method_position_of(held, method, source) else {
                continue;
            };

            if !self.edges_push(node, node.span(), target) {
                return;
            }
        }
    }

    fn container_span_at(&self, node: View<'_>) -> Option<Span> {
        let mut current = node;

        for _ in 0..crate::tree::FRAME_DEPTH_MAX {
            if let Some(row) = self.row_of_node(current.index()) {
                let container = self.functions[row as usize].container;

                return (container != Span::EMPTY).then_some(container);
            }

            current = current.parent()?;
        }

        None
    }

    fn path_head_of<'source>(
        &self,
        front: &Front,
        node: View<'_>,
        call: Call<'_>,
        source: &'source [u8],
    ) -> &'source [u8] {
        let Some(callee) = call.callee() else {
            return &[];
        };
        let span = callee.span();
        let mut head = Span::EMPTY;
        let mut names = 0_u32;
        let mut separators = 0_u32;

        for token in front.tokens() {
            if token.offset < span.offset {
                continue;
            }

            if token.offset >= span.end() {
                break;
            }

            let text = token.text(source);

            if text == b"::" {
                separators += 1;
            } else if token.kind == TokenKind::Identifier || receives_itself(text) {
                if names == 0 {
                    head = token.span();
                }

                names += 1;
            } else {
                return &[];
            }
        }

        if names != 2 || separators != 1 {
            return &[];
        }

        if receives_itself(&source[head.range()]) {
            return match self.container_span_at(node) {
                Some(container) => &source[container.range()],
                None => &[],
            };
        }

        &source[head.range()]
    }

    pub fn receiver_type_of<'source>(
        &self,
        front: &Front,
        node: View<'_>,
        receiver: View<'_>,
        source: &'source [u8],
    ) -> &'source [u8] {
        let container = self.container_span_at(node);
        let resolved =
            self.fields_walk(front, receiver.span(), source, container, |name, itself| {
                if itself {
                    return bound_type_shape_of(front, name, source)
                        .or_else(|| container.map(|held| (held, false)));
                }

                bound_type_shape_of(front, name, source).or_else(|| {
                    self.element_type_of(front, name, source)
                        .map(|held| (held, false))
                })
            });

        match resolved {
            Some((spelled, _)) => &source[spelled.range()],
            None => &[],
        }
    }

    fn element_type_of(&self, front: &Front, name: Span, source: &[u8]) -> Option<Span> {
        let held = declaring_view_of(front, name)?;

        if held.declaring.category() != Category::Loop {
            return None;
        }

        let iterable = iterable_of(held.declaring)?;

        let (spelled, indexed) =
            self.fields_walk(front, iterable.span(), source, None, |head, _| {
                bound_type_shape_of(front, head, source)
            })?;

        indexed.then_some(spelled)
    }

    fn fields_walk(
        &self,
        front: &Front,
        span: Span,
        source: &[u8],
        container: Option<Span>,
        resolve: impl Fn(Span, bool) -> Option<(Span, bool)>,
    ) -> Option<(Span, bool)> {
        let tokens = front.tokens();
        let mut held: Option<(Span, bool)> = None;
        let mut steps = 0_u32;
        let mut dead = false;

        for token in tokens {
            if token.offset < span.offset {
                continue;
            }

            if token.offset >= span.end() {
                break;
            }

            if token.is_punctuation(Punctuation::BracketOpen)
                || token.is_punctuation(Punctuation::ParenOpen)
            {
                dead = true;

                break;
            }

            let text = token.text(source);
            let itself = steps == 0 && receives_itself(text);
            let indexes = steps > 0 && token.kind == TokenKind::Number;

            if token.kind != TokenKind::Identifier && !itself && !indexes {
                continue;
            }

            held = match held {
                None if steps == 0 => resolve(token.span(), itself),
                None => None,
                Some((outer, _)) => self.field_type_of(&source[outer.range()], text, source),
            };

            dead = dead || held.is_none();
            steps += 1;
        }

        if dead && steps >= 1 {
            return None;
        }

        if let Some((spelled, _)) = held
            && receives_itself(&source[spelled.range()])
        {
            return names_a_type_of_itself(&source[spelled.range()])
                .then_some(container)
                .flatten()
                .map(|outer| (outer, false));
        }

        match held {
            Some(shape) => Some(shape),
            None if steps == 0 => Some((span, false)),
            None => None,
        }
    }

    fn method_position_of(&self, held: &[u8], name: &[u8], source: &[u8]) -> Option<u32> {
        if held.is_empty() || name.is_empty() {
            return None;
        }

        let mut found = None;

        for (position, function) in self.functions.iter().enumerate() {
            if &source[function.name.range()] != name || &source[function.container.range()] != held
            {
                continue;
            }

            if found.is_some() {
                return None;
            }

            found = Some(count_of(position));
        }

        found
    }

    pub fn method_of(&self, held: &[u8], name: &[u8], source: &[u8]) -> Option<&Function> {
        let position = self.method_position_of(held, name, source)?;

        self.functions.get(position as usize)
    }

    fn edges_push(&mut self, node: View<'_>, call: Span, target: u32) -> bool {
        let mut current = Some(node);

        for _ in 0..crate::tree::FRAME_DEPTH_MAX {
            let Some(held) = current else {
                return true;
            };

            if let Some(source) = self.row_of_node(held.index()) {
                return self.edges.push(Edge {
                    call,
                    source,
                    target,
                });
            }

            current = held.parent();
        }

        true
    }

    fn edges_range(&mut self) {
        let count = self.edges.count();
        let mut start = 0;

        while start < count {
            let source = self.edges[start as usize].source;
            let mut end = start;

            while end < count && self.edges[end as usize].source == source {
                end += 1;
            }

            let function = &mut self.functions[source as usize];

            function.edge_count = end - start;
            function.edge_start = start;

            start = end;
        }
    }

    fn functions_collect(&mut self, front: &Front, source: &[u8], returns: &Returns<'_>) {
        let bindings = front.bindings();

        for index in 0..bindings.count() {
            let Some(binding) = bindings.at(index) else {
                continue;
            };

            if !matches!(binding.class, BindingClass::Function | BindingClass::Method) {
                continue;
            }

            let Some(node) = function_view_of(front, binding) else {
                continue;
            };
            let function = node.as_function().expect("the view is a function");

            let spelled = function
                .returns_span()
                .map_or(&[][..], |span| spelled_of(source, span));

            let pushed = self.functions.push(Function {
                binding: index,
                comptime: is_comptime(function, source, spelled),
                container: container_of(front, node, function, source),
                edge_count: 0,
                edge_start: 0,
                fallible: is_fallible(spelled, returns.optional_markers),
                name: binding.name,
                node: node.index(),
                recursive: false,
                value: is_value(spelled),
            });

            if !pushed {
                return;
            }
        }
    }

    fn values_mark(&mut self, front: &Front, source: &[u8], returns: &Returns<'_>) {
        if returns.spelled {
            return;
        }

        for position in front.index_of(Category::Return) {
            let Some(statement) = front.view(*position) else {
                continue;
            };

            if !returns_something(statement, source, returns.nothing_words) {
                continue;
            }

            let Some(owner) = owner_of(statement) else {
                continue;
            };
            let Some(row) = self.row_of_node(owner.index()) else {
                continue;
            };

            let spelled = owner
                .as_function()
                .and_then(FunctionView::returns_span)
                .is_some();

            if spelled {
                continue;
            }

            self.functions[row as usize].value = true;
        }
    }

    fn row_of_binding(&self, binding: u32) -> Option<u32> {
        let first = self
            .functions
            .partition_point(|function| function.binding < binding);

        assert!(first <= self.functions.count() as usize);

        self.functions
            .get(first)
            .filter(|function| function.binding == binding)
            .map(|_| count_of(first))
    }

    fn row_of_node(&self, node: u32) -> Option<u32> {
        let functions = &self.functions;

        let first = self
            .nodes
            .partition_point(|position| functions[*position as usize].node < node);

        assert!(first <= self.nodes.count() as usize);

        self.nodes
            .get(first)
            .copied()
            .filter(|position| functions[*position as usize].node == node)
    }

    fn cycles_mark(&mut self) {
        let Self {
            edges,
            functions,
            marks,
            scratch,
            ..
        } = self;

        let count = functions.count();

        marks.clear();

        for _ in 0..count {
            marks.push_assert(false);
        }

        let called = Called { edges, functions };
        let mut recursion = Recursion { marks };
        let walked = graph::components(count, scratch, &called, &mut recursion);

        assert!(walked);

        for index in 0..count {
            if marks[index as usize] {
                self.functions[index as usize].recursive = true;
            }
        }
    }
}

fn is_bare_path(text: &[u8]) -> bool {
    if text.is_empty() {
        return false;
    }

    if !text[0].is_ascii_alphabetic() && text[0] != b'_' {
        return false;
    }

    for byte in text {
        let allowed =
            byte.is_ascii_alphanumeric() || *byte == b'_' || *byte == b'.' || *byte == b':';

        if !allowed {
            return false;
        }
    }

    true
}

pub fn is_fallible(spelled: &[u8], optional_markers: &[&[u8]]) -> bool {
    if spelled.is_empty() {
        return false;
    }

    if find(spelled, b"error").is_some() {
        return true;
    }

    for marker in optional_markers {
        if find(spelled, marker).is_some() {
            return true;
        }
    }

    false
}

pub fn is_value(spelled: &[u8]) -> bool {
    if spelled.is_empty() {
        return false;
    }

    !VOID_TYPES.contains(&spelled)
}

fn is_comptime(function: FunctionView<'_>, source: &[u8], spelled: &[u8]) -> bool {
    if spelled.trim_ascii() == b"type" {
        return true;
    }

    for parameter in function.parameters() {
        let Some(span) = parameter.type_span else {
            continue;
        };

        assert!(span.end() as usize <= source.len());

        if source[span.range()].trim_ascii() == b"type" {
            return true;
        }
    }

    false
}

fn bound_type_shape_of(front: &Front, name: Span, source: &[u8]) -> Option<(Span, bool)> {
    let held = declaring_view_of(front, name)?;
    let spelled = type_span_of(front, &held)?;
    let leading = first_name_in(front, spelled, source)?;

    Some((leading, spells_an_index(&source[spelled.range()])))
}

fn spells_an_index(spelled: &[u8]) -> bool {
    spelled.contains(&b'[')
}

struct Called<'run> {
    edges: &'run [Edge],
    functions: &'run [Function],
}

struct Recursion<'run> {
    marks: &'run mut [bool],
}

impl graph::Topology for Called<'_> {
    fn edge_count_of(&self, node: u32) -> u32 {
        self.functions[node as usize].edge_count
    }

    fn edge_target_of(&self, node: u32, ordinal: u32) -> Option<u32> {
        let function = self.functions[node as usize];

        Some(self.edges[(function.edge_start + ordinal) as usize].target)
    }

    fn holds(&self, _node: u32) -> bool {
        true
    }
}

impl graph::Visitor for Recursion<'_> {
    fn component(&mut self, members: &[u32], looping: bool) -> bool {
        if !looping {
            return true;
        }

        for member in members {
            self.marks[*member as usize] = true;
        }

        true
    }
}

struct Bound<'run> {
    declaring: View<'run>,
    name: Span,
    reference: View<'run>,
}

fn declaring_view_of(front: &Front, name: Span) -> Option<Bound<'_>> {
    let bindings = front.bindings();

    for index in 0..bindings.reference_count() {
        let Some(reference) = bindings.reference_at(index) else {
            continue;
        };

        if reference.name != name {
            continue;
        }

        let Resolution::Bound(bound) = reference.resolution else {
            continue;
        };
        let binding = bindings.at(bound)?;
        let declared = front.view(binding.node)?;
        let referenced = front.view(reference.node)?;

        return Some(Bound {
            declaring: declared.declaring_of(),
            name: binding.name,
            reference: referenced,
        });
    }

    None
}

fn type_span_of(front: &Front, bound: &Bound<'_>) -> Option<Span> {
    let switched = bound.declaring.category() == Category::Assignment
        && bound
            .declaring
            .parent()
            .is_some_and(|parent| parent.category() == Category::Match);

    if switched {
        return case_type_span_of(bound);
    }

    if bound.declaring.category() == Category::Parameters {
        return parameter_type_span_of(front, bound);
    }

    if let Some(spelled) = bound.declaring.type_of() {
        return Some(spelled.span());
    }

    let value = bound.declaring.as_declaration()?.value()?;

    Some(value.span())
}

fn parameter_type_span_of(front: &Front, bound: &Bound<'_>) -> Option<Span> {
    let limit = parameter_end_of(front, bound.name.end());

    bound
        .declaring
        .children()
        .find(|child| {
            let offset = child.span().offset;

            offset >= bound.name.end() && offset < limit
        })
        .map(|child| child.span())
}

fn parameter_end_of(front: &Front, from: u32) -> u32 {
    let mut depth = 0_u32;

    for token in front.tokens() {
        if token.offset < from {
            continue;
        }

        if token.is_punctuation(Punctuation::ParenOpen)
            || token.is_punctuation(Punctuation::BracketOpen)
        {
            depth += 1;

            continue;
        }

        if token.is_punctuation(Punctuation::BracketClose) {
            depth = depth.saturating_sub(1);

            continue;
        }

        if token.is_punctuation(Punctuation::ParenClose) {
            if depth == 0 {
                return token.offset;
            }

            depth -= 1;

            continue;
        }

        if depth == 0 && token.is_punctuation(Punctuation::Comma) {
            return token.offset;
        }
    }

    u32::MAX
}

fn case_type_span_of(bound: &Bound<'_>) -> Option<Span> {
    let switch = bound.declaring.parent()?;
    let mut current = bound.reference;

    for _ in 0..crate::tree::FRAME_DEPTH_MAX {
        let parent = current.parent()?;
        let grandparent = parent.parent()?;

        if grandparent.index() == switch.index() {
            return current.child_first().map(|spelled| spelled.span());
        }

        current = parent;
    }

    None
}

fn iterable_of(held: View<'_>) -> Option<View<'_>> {
    let mut found = None;

    for child in held.children() {
        if child.category() == Category::Block {
            break;
        }

        found = Some(child);
    }

    found
}

fn container_of(front: &Front, node: View<'_>, function: FunctionView<'_>, source: &[u8]) -> Span {
    if let Some(receiver) = function.receiver()
        && let Some(name) = last_name_of(front, receiver, source)
        && !receives_itself(&source[name.range()])
    {
        return name;
    }

    let mut current = node;

    for _ in 0..crate::tree::FRAME_DEPTH_MAX {
        let Some(parent) = current.parent() else {
            return Span::EMPTY;
        };

        if parent.category() == Category::Struct {
            if let Some(container) = parent.as_container()
                && let Some(name) = container.name_token()
            {
                return front.tokens()[name as usize].span();
            }

            if let Some(name) = this_alias_of(front, parent, source) {
                return name;
            }

            if let Some(name) = header_name_of(front, parent, source) {
                return name;
            }
        }

        current = parent;
    }

    Span::EMPTY
}

fn this_alias_of(front: &Front, node: View<'_>, source: &[u8]) -> Option<Span> {
    let container = node.as_container()?;

    for member in container.body().children() {
        let Some(declaration) = member.as_declaration() else {
            continue;
        };
        let Some(value) = declaration.value() else {
            continue;
        };

        if source[value.span().range()].trim_ascii() != b"@This()" {
            continue;
        }

        let name = member.name_token()?;

        return Some(front.tokens()[name as usize].span());
    }

    None
}

fn header_name_of(front: &Front, node: View<'_>, source: &[u8]) -> Option<Span> {
    let span = node.span();
    let mut first = None;
    let mut implements = false;
    let mut previous: Option<&Token> = None;

    for token in front.tokens() {
        if token.offset < span.offset {
            continue;
        }

        if token.offset >= span.end() || token.kind == TokenKind::BlockStart {
            break;
        }

        let quoted = previous.is_some_and(|held| held.text(source) == b"'");
        previous = Some(token);

        if token.kind == TokenKind::Keyword(Keyword::Loop)
            && &source[token.span().range()] == b"for"
        {
            implements = true;
            first = None;

            continue;
        }

        if spells_a_name(token, quoted, source) && first.is_none() {
            first = Some(token.span());

            if implements {
                return first;
            }
        }
    }

    first
}

fn first_name_of(front: &Front, node: View<'_>, source: &[u8]) -> Option<Span> {
    first_name_in(front, node.span(), source)
}

fn first_name_in(front: &Front, span: Span, source: &[u8]) -> Option<Span> {
    let mut previous: Option<&Token> = None;

    for token in front.tokens() {
        if token.offset < span.offset {
            continue;
        }

        if token.offset >= span.end() {
            break;
        }

        let quoted = previous.is_some_and(|held| held.text(source) == b"'");
        previous = Some(token);

        if spells_a_name(token, quoted, source) {
            return Some(token.span());
        }
    }

    None
}

fn last_name_of(front: &Front, node: View<'_>, source: &[u8]) -> Option<Span> {
    last_name_in(front, node.span(), source)
}

fn last_name_in(front: &Front, span: Span, source: &[u8]) -> Option<Span> {
    let tokens = front.tokens();
    let mut found = None;
    let mut previous: Option<&Token> = None;

    for token in tokens {
        if token.offset < span.offset {
            continue;
        }

        if token.offset >= span.end() {
            break;
        }

        let quoted = previous.is_some_and(|held| held.text(source) == b"'");
        previous = Some(token);

        if spells_a_name(token, quoted, source) {
            found = Some(token.span());
        }
    }

    found
}

fn owner_of(node: View<'_>) -> Option<View<'_>> {
    let mut current = node.parent();

    for _ in 0..crate::tree::FRAME_DEPTH_MAX {
        let held = current?;

        if matches!(held.category(), Category::Function | Category::Lambda) {
            return Some(held);
        }

        current = held.parent();
    }

    None
}

fn function_view_of(front: &Front, binding: Binding) -> Option<View<'_>> {
    let named = front.view(binding.node)?;
    let held = (named).declaring_of();

    if held.as_function().is_some() {
        return Some(held);
    }

    if let Some(value) = held.as_declaration().and_then(Declaration::value)
        && value.as_function().is_some()
    {
        return Some(value);
    }

    let owner = owner_of(held)?;
    let position = owner.as_function().and_then(FunctionView::name_token)?;
    let tokens = front.tokens();

    assert!((position as usize) < tokens.len());

    (tokens[position as usize].offset == binding.name.offset).then_some(owner)
}

fn callee_call_of(front: &Front, reference: Reference) -> Option<View<'_>> {
    let mut current = front.view(reference.node);

    for _ in 0..crate::tree::FRAME_DEPTH_MAX {
        let held = current?;

        if let Some(call) = held.as_call() {
            let position = call.name_token()?;
            let tokens = front.tokens();

            assert!((position as usize) < tokens.len());

            let named = tokens[position as usize].offset == reference.name.offset;

            return named.then_some(held);
        }

        current = held.parent();
    }

    None
}

fn spells_a_name(token: &Token, quoted: bool, source: &[u8]) -> bool {
    token.kind == TokenKind::Identifier && !quoted && token.text(source) != b"'"
}

fn names_a_type_of_itself(spelled: &[u8]) -> bool {
    matches!(spelled.trim_ascii(), b"Self" | b"cls")
}

fn receives_itself(receiver: &[u8]) -> bool {
    let text = receiver.trim_ascii();
    let bare = text.strip_prefix(b"&").unwrap_or(text).trim_ascii_start();

    matches!(bare, b"self" | b"Self" | b"cls")
}

fn spelled_of(source: &[u8], span: Span) -> &[u8] {
    assert!(span.end() as usize <= source.len());

    let text = source[span.range()].trim_ascii();

    let stripped = text
        .strip_prefix(b"->")
        .or_else(|| text.strip_prefix(b":"))
        .unwrap_or(text);

    stripped.trim_ascii()
}

fn returns_something(statement: View<'_>, source: &[u8], nothing_words: &[&[u8]]) -> bool {
    let mut children = statement.children();
    let Some(first) = children.next() else {
        return false;
    };

    if children.next().is_some() {
        return true;
    }

    let span = first.span();

    assert!(span.end() as usize <= source.len());

    !nothing_words.contains(&source[span.range()].trim_ascii())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::language::Language;
    use crate::syntax::front::{self, Limits, Options, Scratch};
    use crate::syntax::python::stdlib::PythonVersion;
    use crate::token::{Lex, Tokens};
    use crate::tree::Structure;

    const LIMITS: Limits = Limits {
        binding_count_max: 1 << 10,
        error_count_max: 1 << 6,
        event_count_max: 1 << 14,
        export_count_max: 1 << 8,
        fact_count_max: 1 << 8,
        node_count_max: 1 << 12,
        reference_count_max: 1 << 10,
        scope_count_max: 1 << 8,
        segment_count_max: 1 << 8,
        token_count_max: 1 << 12,
    };

    const RETURNS: Returns<'static> = Returns {
        nothing_words: &[b"None"],
        optional_markers: &[b"Option<", b"Result<"],
        spelled: true,
    };

    const PYTHON: &[u8] = b"def gives():\n    return 1\n\n\n\
        def gives_nothing():\n    return None\n\n\n\
        def quiet():\n    pass\n";

    const RUST: &[u8] = b"struct Server {\n    port: Port,\n}\n\n\
        struct Port {\n    value: u16,\n}\n\n\
        impl Port {\n    fn open(&self) -> Result<(), Error> {\n        helper();\n\n\
        \x20       Ok(())\n    }\n}\n\n\
        fn helper() {\n    other();\n}\n\n\
        fn other() {\n    helper();\n}\n\n\
        fn run(server: &Server) -> u32 {\n    server.port.open();\n\n    1\n}\n\n\
        fn quiet() {}\n";

    fn built(language: Language, source: &[u8]) -> Front {
        let mut held = Front::reserve(language, &LIMITS);
        let mut wanted = [false; Language::COUNT];

        wanted[language.index()] = true;

        let mut scratch = Scratch::reserve(&LIMITS, wanted);
        let mut lexed = Tokens::reserve(LIMITS.token_count_max);
        let scanner = front::lexer_of(language).expect("a code language has a lexer");

        assert_eq!(scanner.lex(source, &mut lexed), Lex::Complete);

        let options = Options {
            globals: &[],
            python_version: PythonVersion::Py310,
            template_imports: &[],
        };

        let outcome = held.build(source, lexed.as_slice(), &mut scratch, &options);

        assert_eq!(outcome, Structure::Complete);

        held
    }

    fn tables_of(front: &Front, source: &[u8], returns: &Returns<'_>) -> Tables {
        let mut tables = Tables::reserve(64, 256);

        crate::allocation::frozen(|| tables.build(front, source, returns));

        tables
    }

    fn named<'source>(source: &'source [u8], function: &Function) -> &'source [u8] {
        &source[function.name.range()]
    }

    #[test]
    fn every_function_and_method_takes_a_row() {
        let front = built(Language::Rust, RUST);
        let tables = tables_of(&front, RUST, &RETURNS);
        let mut names: Vec<&[u8]> = tables
            .functions()
            .iter()
            .map(|function| named(RUST, function))
            .collect();

        names.sort_unstable();

        assert_eq!(names, [b"helper".as_slice(), b"open", b"other", b"quiet", b"run"]);

        let open = tables
            .function_of(b"open", RUST)
            .expect("the method is a row");

        assert_eq!(&RUST[open.container.range()], b"Port");
        assert!(open.fallible);
        assert!(open.value);

        let quiet = tables
            .function_of(b"quiet", RUST)
            .expect("the function is a row");

        assert!(!quiet.fallible);
        assert!(!quiet.value);
        assert_eq!(tables.function_of(b"missing", RUST).map(|_| ()), None);
    }

    #[test]
    fn a_call_becomes_an_edge_from_the_caller_to_the_callee() {
        let front = built(Language::Rust, RUST);
        let tables = tables_of(&front, RUST, &RETURNS);
        let open = tables
            .function_of(b"open", RUST)
            .expect("the method is a row");

        let targets: Vec<&[u8]> = tables
            .edges_of(open)
            .iter()
            .map(|edge| named(RUST, &tables.functions()[edge.target as usize]))
            .collect();

        assert_eq!(targets, [b"helper".as_slice()]);
        assert_eq!(&RUST[tables.edges_of(open)[0].call.range()], b"helper()");
    }

    #[test]
    fn a_method_call_through_a_field_resolves_by_the_field_type() {
        let front = built(Language::Rust, RUST);
        let tables = tables_of(&front, RUST, &RETURNS);
        let run = tables
            .function_of(b"run", RUST)
            .expect("the function is a row");

        let targets: Vec<&[u8]> = tables
            .edges_of(run)
            .iter()
            .map(|edge| named(RUST, &tables.functions()[edge.target as usize]))
            .collect();

        assert_eq!(targets, [b"open".as_slice()]);

        assert!(tables.method_of(b"Port", b"open", RUST).is_some());
        assert!(tables.method_of(b"Server", b"open", RUST).is_none());
    }

    #[test]
    fn a_cycle_marks_every_member_recursive() {
        let front = built(Language::Rust, RUST);
        let tables = tables_of(&front, RUST, &RETURNS);

        for name in [b"helper".as_slice(), b"other"] {
            let function = tables.function_of(name, RUST).expect("the row is present");

            assert!(function.recursive, "{}", String::from_utf8_lossy(name));
        }

        for name in [b"open".as_slice(), b"run", b"quiet"] {
            let function = tables.function_of(name, RUST).expect("the row is present");

            assert!(!function.recursive, "{}", String::from_utf8_lossy(name));
        }
    }

    #[test]
    fn value_of_answers_by_the_spelled_return_or_the_returned_value() {
        let front = built(Language::Rust, RUST);
        let tables = tables_of(&front, RUST, &RETURNS);

        assert_eq!(tables.value_of(b"run", RUST), Some(true));
        assert_eq!(tables.value_of(b"quiet", RUST), Some(false));
        assert_eq!(tables.value_of(b"missing", RUST), None);

        let unspelled = Returns {
            nothing_words: &[b"None"],
            optional_markers: &[],
            spelled: false,
        };

        let python = built(Language::Python, PYTHON);
        let unspelled_tables = tables_of(&python, PYTHON, &unspelled);

        assert_eq!(unspelled_tables.value_of(b"gives", PYTHON), Some(true));
        assert_eq!(unspelled_tables.value_of(b"gives_nothing", PYTHON), Some(false));
        assert_eq!(unspelled_tables.value_of(b"quiet", PYTHON), Some(false));
    }

    #[test]
    fn an_alias_names_the_path_it_stands_for() {
        const SOURCE: &[u8] = b"const held = std.mem;\nconst count = 4;\n\nfn run() void {}\n";

        let front = built(Language::Zig, SOURCE);
        let tables = tables_of(&front, SOURCE, &RETURNS);
        let target = tables
            .alias_of(b"held", SOURCE)
            .expect("the alias is recorded");

        assert_eq!(&SOURCE[target.range()], b"std.mem");
        assert!(tables.alias_of(b"count", SOURCE).is_none());
    }

    #[test]
    fn a_fallible_return_is_read_from_the_markers() {
        assert!(is_fallible(b"Result<(), Error>", &[b"Result<"]));
        assert!(is_fallible(b"error", &[]));
        assert!(is_fallible(b"?u32", &[b"?"]));
        assert!(!is_fallible(b"u32", &[b"Result<"]));
        assert!(!is_fallible(b"", &[b"Result<"]));
        assert!(is_value(b"u32"));
        assert!(!is_value(b"void"));
        assert!(!is_value(b""));
    }
}
