const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const Document = @import("document.zig").Document;
const Kind = @import("kind.zig").Kind;
const Span = @import("../../stdx/bounded/span.zig");
const Token = @import("token.zig").Token;
const Tree = @import("tree.zig").Tree;
const Node = Document.Node;

pub const View = struct {
    index: u32,
    tokens: []const Token,
    tree: *const Tree,

    pub const CapacityError = error{Overflow};

    pub const Attribute = struct {
        view: View,

        pub fn name_token(attribute: Attribute) ?u32 {
            assert(attribute.view.covered());
            assert(attribute.view.kind() == .attribute);

            return attribute.view.token_first(.attribute_name);
        }

        pub fn value(attribute: Attribute) ?AttributeValue {
            assert(attribute.view.covered());
            assert(attribute.view.kind() == .attribute);

            var found = attribute.view.children_of(.attribute_value);
            const held = found.next() orelse return null;

            return held.as_attribute_value();
        }
    };

    pub const AttributeValue = struct {
        view: View,

        pub fn inner_span(value: AttributeValue) Span {
            assert(value.view.index < value.view.tree.count());

            const whole = value.view.span();
            var start = whole.offset;
            var stop = whole.end();
            var quote_head: ?u32 = null;
            var quote_tail: ?u32 = null;
            var quotes = value.view.direct_tokens_of(.quote);

            for (0..value.view.tokens.len) |_| {
                const found = quotes.next() orelse break;

                if (quote_head == null) quote_head = found;

                quote_tail = found;
            }

            if (quote_head) |held| {
                const quote = value.view.token_at(held);

                if (quote.offset == start) start = quote.end();
            }

            if (quote_tail) |held| {
                const quote = value.view.token_at(held);

                if (quote.end() == stop) {
                    if (quote.offset >= start) stop = quote.offset;
                }
            }

            assert(start <= stop);
            assert(stop <= whole.end());

            return .{ .length = stop - start, .offset = start };
        }

        fn is_quoted(value: AttributeValue) bool {
            assert(value.view.covered());
            assert(value.view.kind() == .attribute_value);

            return value.view.token_first(.quote) != null;
        }

        pub fn template_holes(value: AttributeValue, out: *ArrayType(Span)) CapacityError!void {
            assert(out.capacity() > 0);
            assert(value.view.kind() == .attribute_value);

            var room = true;
            var listed = value.view.children();

            for (0..value.view.tree.count()) |_| {
                const child = listed.next() orelse break;

                switch (child.kind()) {
                    .template_comment, .template_tag, .template_variable => {},
                    else => continue,
                }

                if (out.full()) {
                    room = false;
                } else {
                    out.push(child.span());
                }
            }

            if (!room) return error.Overflow;
        }

        pub fn text_tokens(value: AttributeValue) SubtreeTokens {
            assert(value.view.covered());
            assert(value.view.kind() == .attribute_value);

            return value.view.subtree_tokens_of(.attribute_text);
        }
    };

    pub const Children = struct {
        current: ?u32,
        kind: ?Kind,
        remaining: u32,
        tokens: []const Token,
        tree: *const Tree,

        pub fn next(iterator: *Children) ?View {
            if (iterator.kind) |wanted| assert(wanted.is_node());
            if (iterator.current) |held| assert(held < iterator.tree.count());
            assert(iterator.remaining <= iterator.tree.count());

            if (iterator.remaining == 0) return null;

            for (0..iterator.tree.count()) |_| {
                const current = iterator.current orelse return null;
                const record = iterator.tree.at(current);

                const found: View = .{
                    .index = current,
                    .tokens = iterator.tokens,
                    .tree = iterator.tree,
                };

                iterator.current = iterator.tree.sibling_next_of(current);

                if (iterator.kind) |wanted| {
                    if (wanted != record.kind) continue;
                }

                iterator.remaining -= 1;

                return found;
            }

            assert(iterator.current == null);

            return null;
        }
    };

    pub const DirectTokens = struct {
        child: ?u32,
        kind: ?Kind,
        limit: u32,
        position: u32,
        remaining: u32,
        tokens: []const Token,
        tree: *const Tree,

        pub fn next(iterator: *DirectTokens) ?u32 {
            if (iterator.kind) |wanted| assert(wanted.is_token());
            assert(iterator.limit <= iterator.tokens.len);
            assert(iterator.remaining <= iterator.tokens.len);

            if (iterator.remaining == 0) return null;

            for (0..iterator.tokens.len + iterator.tree.count() + 1) |_| {
                if (iterator.position >= iterator.limit) return null;

                if (iterator.child) |child| {
                    const record = iterator.tree.at(child);

                    if (iterator.position >= record.token_end) {
                        iterator.child = iterator.tree.sibling_next_of(child);

                        continue;
                    }

                    if (iterator.position >= record.token_start) {
                        iterator.position = record.token_end;
                        iterator.child = iterator.tree.sibling_next_of(child);

                        continue;
                    }
                }

                const found = iterator.position;

                iterator.position += 1;

                if (iterator.kind) |wanted| {
                    if (iterator.tokens[found].kind != wanted) continue;
                }

                iterator.remaining -= 1;

                return found;
            }

            assert(iterator.position >= iterator.limit);

            return null;
        }
    };

    pub const Element = struct {
        view: View,

        pub const Attributes = struct {
            children: ?Children,
            remaining: u32,

            pub fn next(iterator: *Attributes) ?Attribute {
                if (iterator.children) |held| assert(held.kind == .attribute);
                if (iterator.children) |held| assert(iterator.remaining <= held.tree.count());
                if (iterator.children == null) assert(iterator.remaining == 0);

                if (iterator.remaining == 0) return null;

                const listed = if (iterator.children) |*held| held else return null;
                const found = listed.next() orelse return null;
                const attribute = found.as_attribute();

                assert(attribute != null);

                iterator.remaining -= 1;

                return attribute;
            }
        };

        pub const RawTextTokens = struct {
            direct: DirectTokens,
            remaining: u32,

            pub fn next(iterator: *RawTextTokens) ?u32 {
                assert(iterator.direct.kind == null);
                assert(iterator.direct.limit <= iterator.direct.tokens.len);
                assert(iterator.remaining <= iterator.direct.tokens.len);

                if (iterator.remaining == 0) return null;

                for (0..iterator.direct.tokens.len) |_| {
                    const found = iterator.direct.next() orelse return null;

                    switch (iterator.direct.tokens[found].kind) {
                        .script_text, .style_text => {},
                        else => continue,
                    }

                    iterator.remaining -= 1;

                    return found;
                }

                return null;
            }
        };

        pub fn attributes(element: Element) Attributes {
            assert(element.view.covered());
            assert(element.view.kind() == .element);

            const open = element.open_tag() orelse return .{ .children = null, .remaining = 0 };
            const listed = open.children_of(.attribute);

            return .{ .children = listed, .remaining = listed.remaining };
        }

        pub fn name(element: Element, source: []const u8) ?[]const u8 {
            assert(element.view.covered());
            assert(element.view.kind() == .element);
            assert(source.len <= std.math.maxInt(u32));

            const held = element.name_token() orelse return null;
            const spelled = element.view.token_at(held).text(source);

            assert(spelled.len <= source.len);

            return spelled;
        }

        fn name_token(element: Element) ?u32 {
            assert(element.view.covered());
            assert(element.view.kind() == .element);

            const open = element.open_tag() orelse return null;
            return open.token_first(.element_name);
        }

        pub fn open_tag(element: Element) ?View {
            assert(element.view.covered());
            assert(element.view.kind() == .element);

            var found = element.view.children_of(.open_tag);
            return found.next();
        }

        pub fn raw_text_tokens(element: Element) RawTextTokens {
            assert(element.view.covered());
            assert(element.view.kind() == .element);

            const direct = element.view.direct_tokens();
            return .{ .direct = direct, .remaining = direct.remaining };
        }
    };

    pub const SubtreeTokens = struct {
        kind: Kind,
        limit: u32,
        position: u32,
        remaining: u32,
        tokens: []const Token,

        pub fn next(iterator: *SubtreeTokens) ?u32 {
            assert(iterator.kind.is_token());
            assert(iterator.limit <= iterator.tokens.len);
            assert(iterator.remaining <= iterator.tokens.len);

            if (iterator.remaining == 0) return null;

            for (0..iterator.tokens.len + 1) |_| {
                if (iterator.position >= iterator.limit) return null;

                const found = iterator.position;

                iterator.position += 1;

                if (iterator.tokens[found].kind != iterator.kind) continue;

                iterator.remaining -= 1;

                return found;
            }

            assert(iterator.position >= iterator.limit);

            return null;
        }
    };

    pub const TemplateTag = struct {
        view: View,

        pub const ArgumentTokens = struct {
            direct: DirectTokens,
            remaining: u32,
            seen_name: bool,

            pub fn next(iterator: *ArgumentTokens) ?u32 {
                assert(iterator.direct.kind == null);
                assert(iterator.direct.limit <= iterator.direct.tokens.len);
                assert(iterator.remaining <= iterator.direct.tokens.len);

                if (iterator.remaining == 0) return null;

                for (0..iterator.direct.tokens.len) |_| {
                    const found = iterator.direct.next() orelse return null;
                    const found_kind = iterator.direct.tokens[found].kind;

                    if (found_kind == .tag_name) {
                        if (!iterator.seen_name) {
                            iterator.seen_name = true;

                            continue;
                        }
                    }

                    if (!iterator.seen_name) continue;
                    if (found_kind.is_trivia()) continue;

                    switch (found_kind) {
                        .tag_open, .tag_close => continue,
                        else => {},
                    }

                    iterator.remaining -= 1;

                    return found;
                }

                return null;
            }
        };

        pub const KeywordArgument = struct {
            name_token: u32,
            value: Span,
        };

        pub fn argument_tokens(tag: TemplateTag) ArgumentTokens {
            assert(tag.view.covered());
            assert(tag.view.kind() == .template_tag);

            const direct = tag.view.direct_tokens();
            return .{ .direct = direct, .remaining = direct.remaining, .seen_name = false };
        }

        fn is_closed(tag: TemplateTag) bool {
            assert(tag.view.covered());
            assert(tag.view.kind() == .template_tag);

            return tag.view.token_first(.tag_close) != null;
        }

        pub fn keyword_arguments(
            tag: TemplateTag,
            source: []const u8,
            out: *ArrayType(KeywordArgument),
        ) CapacityError!void {
            assert(tag.view.kind() == .template_tag);
            assert(out.capacity() > 0);
            assert(source.len <= std.math.maxInt(u32));

            var window: [3]u32 = @splat(0);
            var filled: u32 = 0;
            var room = true;
            var arguments = tag.argument_tokens();

            for (0..tag.view.tokens.len) |_| {
                const found = arguments.next() orelse break;

                window[0] = window[1];
                window[1] = window[2];
                window[2] = found;
                filled = @min(filled + 1, 3);

                if (filled < 3) continue;

                const name = tag.view.token_at(window[0]);
                const equals = tag.view.token_at(window[1]);
                const argument = tag.view.token_at(window[2]);

                if (name.kind != .identifier) continue;
                if (equals.kind != .equals) continue;
                if (argument.kind != .string) continue;

                const inner = argument.unquote(source) orelse continue;

                if (out.full()) {
                    room = false;
                } else {
                    out.push(.{ .name_token = window[0], .value = inner });
                }
            }

            if (!room) return error.Overflow;
        }

        pub fn name_token(tag: TemplateTag) ?u32 {
            assert(tag.view.covered());
            assert(tag.view.kind() == .template_tag);

            return tag.view.token_first(.tag_name);
        }

        pub fn string_arguments(
            tag: TemplateTag,
            source: []const u8,
            out: *ArrayType(Span),
        ) CapacityError!void {
            assert(tag.view.kind() == .template_tag);
            assert(out.capacity() > 0);
            assert(source.len <= std.math.maxInt(u32));

            var room = true;
            var arguments = tag.argument_tokens();

            for (0..tag.view.tokens.len) |_| {
                const found = arguments.next() orelse break;
                const held = tag.view.token_at(found);
                if (held.kind != .string) continue;

                const inner = held.unquote(source) orelse continue;

                if (out.full()) {
                    room = false;
                } else {
                    out.push(inner);
                }
            }

            if (!room) return error.Overflow;
        }
    };

    pub const TemplateVariable = struct {
        view: View,

        pub const ExpressionTokens = struct {
            direct: DirectTokens,
            remaining: u32,

            pub fn next(iterator: *ExpressionTokens) ?u32 {
                assert(iterator.direct.kind == null);
                assert(iterator.direct.limit <= iterator.direct.tokens.len);
                assert(iterator.remaining <= iterator.direct.tokens.len);

                if (iterator.remaining == 0) return null;

                for (0..iterator.direct.tokens.len) |_| {
                    const found = iterator.direct.next() orelse return null;
                    const found_kind = iterator.direct.tokens[found].kind;
                    if (found_kind.is_trivia()) continue;

                    switch (found_kind) {
                        .variable_open, .variable_close => continue,
                        else => {},
                    }

                    iterator.remaining -= 1;

                    return found;
                }

                return null;
            }
        };

        pub const FilterNames = struct {
            chains: Children,
            filters: ?Children,
            remaining: u32,

            pub fn next(iterator: *FilterNames) ?u32 {
                if (iterator.filters) |held| assert(held.kind == .filter);
                assert(iterator.chains.kind == .filter_chain);
                assert(iterator.remaining <= iterator.chains.tree.count());

                if (iterator.remaining == 0) return null;

                for (0..iterator.chains.tree.count() + 1) |_| {
                    if (iterator.filters) |*filters| {
                        if (filters.next()) |filter| {
                            const found = filter.token_first(.identifier) orelse continue;

                            iterator.remaining -= 1;

                            return found;
                        }

                        iterator.filters = null;
                    }

                    const chain = iterator.chains.next() orelse return null;

                    iterator.filters = chain.children_of(.filter);
                }

                unreachable;
            }
        };

        pub fn expression_tokens(variable: TemplateVariable) ExpressionTokens {
            assert(variable.view.covered());
            assert(variable.view.kind() == .template_variable);

            var chains = variable.view.children_of(.filter_chain);
            const limit = if (chains.next()) |chain| chain.token_start() else null;
            const direct = variable.view.direct_tokens_bounded(null, limit);

            return .{ .direct = direct, .remaining = direct.remaining };
        }

        pub fn filter_names(variable: TemplateVariable) FilterNames {
            assert(variable.view.covered());
            assert(variable.view.kind() == .template_variable);

            const chains = variable.view.children_of(.filter_chain);
            return .{ .chains = chains, .filters = null, .remaining = chains.remaining };
        }
    };

    pub const Walk = struct {
        current: ?u32,
        entering: bool,
        remaining: u32,
        root: u32,
        tokens: []const Token,
        tree: *const Tree,

        pub const Step = union(enum) {
            enter: View,
            leave: View,
        };

        pub fn next(iterator: *Walk) ?Step {
            assert(iterator.remaining <= 2 * iterator.tree.count());
            assert(iterator.root < iterator.tree.count());

            if (iterator.remaining == 0) return null;

            const at_index = iterator.current orelse return null;

            assert(at_index >= iterator.root);
            assert(at_index < iterator.tree.count());

            const found: View = .{
                .index = at_index,
                .tokens = iterator.tokens,
                .tree = iterator.tree,
            };

            iterator.remaining -= 1;

            if (iterator.entering) {
                if (iterator.tree.child_first_of(at_index)) |child| {
                    iterator.current = child;
                } else {
                    iterator.entering = false;
                }

                return .{ .enter = found };
            }

            iterator.advance(at_index);

            return .{ .leave = found };
        }

        fn advance(iterator: *Walk, at_index: u32) void {
            assert(!iterator.entering);
            assert(at_index < iterator.tree.count());

            if (at_index == iterator.root) {
                iterator.current = null;

                return;
            }

            if (iterator.tree.sibling_next_of(at_index)) |sibling| {
                iterator.current = sibling;
                iterator.entering = true;

                return;
            }

            const parent_index = iterator.tree.parent_of(at_index);

            assert(parent_index != null);

            iterator.current = parent_index;
        }
    };

    pub fn init(tree: *const Tree, tokens: []const Token, handle: Node) View {
        assert(@backingInt(handle) < tree.count());
        assert(tokens.len <= std.math.maxInt(u32));

        const at_index: u32 = @backingInt(handle);

        return .{ .index = at_index, .tokens = tokens, .tree = tree };
    }

    pub fn ancestor(view: View, wanted: Kind) ?View {
        assert(view.covered());
        assert(wanted.is_node());

        var at_index = view.index;

        for (0..view.tree.count()) |_| {
            at_index = view.tree.parent_of(at_index) orelse return null;

            assert(at_index < view.index);

            if (view.tree.kind_at(at_index) == wanted) return view.at(at_index);
        }

        return null;
    }

    pub fn as_attribute(view: View) ?Attribute {
        assert(view.covered());
        assert(view.index < view.tree.count());

        const held = view.cast(.attribute) orelse return null;
        return .{ .view = held };
    }

    fn as_attribute_value(view: View) ?AttributeValue {
        assert(view.covered());
        assert(view.index < view.tree.count());

        const held = view.cast(.attribute_value) orelse return null;
        return .{ .view = held };
    }

    pub fn as_element(view: View) ?Element {
        assert(view.covered());
        assert(view.index < view.tree.count());

        const held = view.cast(.element) orelse return null;
        return .{ .view = held };
    }

    pub fn as_template_tag(view: View) ?TemplateTag {
        assert(view.covered());
        assert(view.index < view.tree.count());

        const held = view.cast(.template_tag) orelse return null;
        return .{ .view = held };
    }

    pub fn as_template_variable(view: View) ?TemplateVariable {
        assert(view.covered());
        assert(view.index < view.tree.count());

        const held = view.cast(.template_variable) orelse return null;
        return .{ .view = held };
    }

    pub fn children(view: View) Children {
        assert(view.covered());
        assert(view.index < view.tree.count());

        return view.children_of_kind(null);
    }

    fn children_of(view: View, wanted: Kind) Children {
        assert(view.covered());
        assert(wanted.is_node());

        return view.children_of_kind(wanted);
    }

    pub fn direct_tokens(view: View) DirectTokens {
        assert(view.covered());
        assert(view.index < view.tree.count());

        return view.direct_tokens_bounded(null, null);
    }

    pub fn direct_tokens_of(view: View, wanted: Kind) DirectTokens {
        assert(view.covered());
        assert(wanted.is_token());

        return view.direct_tokens_bounded(wanted, null);
    }

    fn direct_tokens_bounded(view: View, wanted: ?Kind, limit: ?u32) DirectTokens {
        assert(view.index < view.tree.count());
        if (limit) |held| assert(held <= view.tokens.len);

        const record = view.tree.at(view.index);

        assert(record.token_end <= view.tokens.len);
        if (wanted) |held| assert(held.is_token());

        return .{
            .child = view.tree.child_first_of(view.index),
            .kind = wanted,
            .limit = @min(limit orelse record.token_end, record.token_end),
            .position = record.token_start,
            .remaining = record.token_end - record.token_start,
            .tokens = view.tokens,
            .tree = view.tree,
        };
    }

    pub fn kind(view: View) Kind {
        assert(view.covered());

        const held = view.tree.kind_at(view.index);

        assert(held.is_node());

        return held;
    }

    pub fn node(view: View) Node {
        assert(view.covered());
        assert(view.index < view.tree.count());

        return @fromBackingInt(view.index);
    }

    pub fn parent(view: View) ?View {
        assert(view.covered());

        const held = view.tree.parent_of(view.index) orelse return null;

        assert(held < view.index);

        return view.at(held);
    }

    pub fn span(view: View) Span {
        assert(view.covered());

        const held = view.tree.at(view.index).span(Token, view.tokens);

        assert(held.end() >= held.offset);

        return held;
    }

    fn subtree_tokens_of(view: View, wanted: Kind) SubtreeTokens {
        assert(view.index < view.tree.count());

        const record = view.tree.at(view.index);

        assert(wanted.is_token());
        assert(record.token_end <= view.tokens.len);

        return .{
            .kind = wanted,
            .limit = record.token_end,
            .position = record.token_start,
            .remaining = record.token_end - record.token_start,
            .tokens = view.tokens,
        };
    }

    pub fn token_at(view: View, position: u32) Token {
        assert(view.covered());
        assert(position < view.tokens.len);

        return view.tokens[position];
    }

    pub fn token_end(view: View) u32 {
        assert(view.covered());

        const held = view.tree.at(view.index).token_end;

        assert(held <= view.tokens.len);

        return held;
    }

    pub fn token_first(view: View, wanted: Kind) ?u32 {
        assert(view.covered());
        assert(wanted.is_token());

        var direct = view.direct_tokens_of(wanted);
        const found = direct.next();

        if (found) |held| assert(view.tokens[held].kind == wanted);

        return found;
    }

    pub fn token_start(view: View) u32 {
        assert(view.covered());
        assert(view.index < view.tree.count());

        return view.tree.at(view.index).token_start;
    }

    pub fn walk(view: View) Walk {
        assert(view.covered());
        assert(view.index < view.tree.count());

        return .{
            .current = view.index,
            .entering = true,
            .remaining = 2 * (view.tree.count() - view.index),
            .root = view.index,
            .tokens = view.tokens,
            .tree = view.tree,
        };
    }

    fn at(view: View, at_index: u32) View {
        assert(at_index < view.tree.count());
        assert(view.covered());

        return .{ .index = at_index, .tokens = view.tokens, .tree = view.tree };
    }

    fn covered(view: View) bool {
        assert(view.index < view.tree.count());

        return view.tree.at(view.index).token_end <= view.tokens.len;
    }

    fn cast(view: View, wanted: Kind) ?View {
        assert(view.covered());
        assert(wanted.is_node());

        if (view.kind() == wanted) return view;
        return null;
    }

    fn children_of_kind(view: View, wanted: ?Kind) Children {
        assert(view.covered());
        assert(view.index < view.tree.count());
        if (wanted) |held| assert(held.is_node());

        return .{
            .current = view.tree.child_first_of(view.index),
            .kind = wanted,
            .remaining = view.tree.count() - view.index - 1,
            .tokens = view.tokens,
            .tree = view.tree,
        };
    }
};

const capacity_test: Document.Capacity = .{
    .diagnostic_count_max = 1 << 4,
    .node_count_max = 1 << 10,
    .tag_count_max = 1 << 6,
    .token_count_max = 1 << 10,
};

fn view_first(document: *const Document, wanted: Kind) !View {
    assert(wanted.is_node());

    for (0..document.node_count()) |position| {
        const held = document.at(@intCast(position));
        if (held.kind() == wanted) return held;
    }

    std.debug.print("the source carries no {s}\n", .{wanted.name()});

    return error.TestUnexpectedResult;
}

test View {
    const source = "<div class=\"card\"><p>{{ title }}</p></div>";
    var document: Document = try .init(std.testing.allocator, capacity_test);
    defer document.deinit(std.testing.allocator);

    try document.parse(source, &.empty);

    var listed = document.root().children();
    const child = listed.next() orelse return error.TestUnexpectedResult;
    const element = child.as_element() orelse return error.TestUnexpectedResult;
    const variable = try view_first(&document, .template_variable);
    const paragraph = variable.ancestor(.element) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("div", element.name(source).?);
    try std.testing.expectEqual(child.node(), document.view(child.node()).node());
    try std.testing.expectEqualStrings("<p>{{ title }}</p>", paragraph.span().text(source));
    try std.testing.expectEqual(element.view.node(), paragraph.parent().?.node());
}

test "a walk enters and leaves every node of the subtree" {
    var document: Document = try .init(std.testing.allocator, capacity_test);
    defer document.deinit(std.testing.allocator);

    try document.parse("<ul><li>a</li><li>b</li></ul>", &.empty);

    const list = try view_first(&document, .element);
    var steps = list.walk();
    var entered: u32 = 0;
    var left: u32 = 0;

    for (0..steps.remaining) |_| {
        const step = steps.next() orelse break;

        switch (step) {
            .enter => entered += 1,
            .leave => left += 1,
        }
    }

    try std.testing.expectEqual(entered, left);
    try std.testing.expect(entered > 3);

    const steps_next = steps.next();

    try std.testing.expect(steps_next == null);
}

test "an attribute value strips its quotes" {
    const source = "<div id=\"one\">";
    var document: Document = try .init(std.testing.allocator, capacity_test);
    defer document.deinit(std.testing.allocator);

    try document.parse(source, &.empty);

    const element = (try view_first(&document, .element)).as_element() orelse
        return error.NotElement;

    var attributes = element.attributes();
    const attribute = attributes.next() orelse return error.NoAttribute;
    const value = attribute.value() orelse return error.NoValue;

    try std.testing.expect(value.is_quoted());
    try std.testing.expectEqualStrings("one", value.inner_span().text(source));
}

test "a bare attribute value keeps its whole span" {
    const source = "<div id=one>";
    var document: Document = try .init(std.testing.allocator, capacity_test);
    defer document.deinit(std.testing.allocator);

    try document.parse(source, &.empty);

    const element = (try view_first(&document, .element)).as_element() orelse
        return error.NotElement;

    var attributes = element.attributes();
    const attribute = attributes.next() orelse return error.NoAttribute;
    const value = attribute.value() orelse return error.NoValue;

    try std.testing.expect(!value.is_quoted());
    try std.testing.expectEqualStrings("one", value.inner_span().text(source));
}

test "a template tag names itself and splits its arguments" {
    const gpa = std.testing.allocator;
    const source = "{% include 'partial.html' with title=\"Hello\" only %}";
    var document: Document = try .init(gpa, capacity_test);
    defer document.deinit(gpa);

    try document.parse(source, &.empty);

    const tag = (try view_first(&document, .template_tag)).as_template_tag() orelse
        return error.NotTag;

    try std.testing.expect(tag.is_closed());

    const name = tag.name_token() orelse return error.NoName;

    try std.testing.expectEqualStrings("include", tag.view.token_at(name).text(source));

    var strings: ArrayType(Span) = try .init(gpa, 8);
    defer strings.deinit(gpa);

    try tag.string_arguments(source, &strings);
    try std.testing.expectEqual(2, strings.count());
    try std.testing.expectEqualStrings("partial.html", strings.get(0).text(source));
    try std.testing.expectEqualStrings("Hello", strings.get(1).text(source));

    var keywords: ArrayType(View.TemplateTag.KeywordArgument) = try .init(gpa, 8);
    defer keywords.deinit(gpa);

    try tag.keyword_arguments(source, &keywords);
    try std.testing.expectEqual(1, keywords.count());

    const keyword = keywords.get(0);

    try std.testing.expectEqualStrings("title", tag.view.token_at(keyword.name_token).text(source));
    try std.testing.expectEqualStrings("Hello", keyword.value.text(source));
}

test "an unterminated template tag is not closed" {
    var document: Document = try .init(std.testing.allocator, capacity_test);
    defer document.deinit(std.testing.allocator);

    try document.parse("{% include 'partial.html'", &.empty);

    const tag = (try view_first(&document, .template_tag)).as_template_tag() orelse
        return error.NotTag;

    try std.testing.expect(!tag.is_closed());
}
