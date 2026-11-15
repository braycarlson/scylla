const std = @import("std");
const assert = std.debug.assert;
const Checkpoint = @import("../tree.zig").Checkpoint;
const EventsType = @import("../tree.zig").EventsType;
const Kind = @import("kind.zig").Kind;
const Span = @import("../../stdx/bounded/span.zig");
const Structure = @import("../tree.zig").Structure;
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const Token = @import("../token.zig");
const TreeType = @import("../tree.zig").TreeType;
const expression = @import("expression.zig");
const frame_depth_max = @import("../tree.zig").frame_depth_max;
const Events = EventsType(Kind);
const Frame = expression.Frame;
const Tree = TreeType(Kind);
const Variant = expression.Variant;

pub const Parser = struct {
    events: *Events,
    frame_count: u32,
    frames: [expression.depth_max]Frame,
    nesting: u32,
    outcome: Structure,
    position: u32,
    range_open_end: u32,
    raw: []const Kind,
    returned: Step,
    significant_next: u32,
    source: []const u8,
    task_count: u32,
    tasks: [task_count_max]Task,
    tokens: []const Token,
    tree: *Tree,
    value_count: u32,
    values: [expression.value_count_max]Checkpoint,

    pub fn build(
        parser: *Parser,
        source: []const u8,
        tokens: []const Token,
        raw: []const Kind,
        events: *Events,
        tree: *Tree,
    ) Structure {
        assert(source.len <= std.math.maxInt(u32));
        assert(tokens.len == raw.len);

        events.clear();
        tree.clear();

        parser.* = .{
            .events = events,
            .frame_count = 0,
            .frames = undefined,
            .nesting = 0,
            .outcome = .complete,
            .position = 0,
            .range_open_end = index_none,
            .raw = raw,
            .returned = .done,
            .significant_next = 0,
            .source = source,
            .task_count = 0,
            .tasks = undefined,
            .tokens = tokens,
            .tree = tree,
            .value_count = 0,
            .values = undefined,
        };

        parser.significant_next = parser.significant_scan(0);

        parser.run();

        assert(parser.task_count == 0);
        assert(parser.nesting == 0);

        const recorded = parser.outcome;
        const buffered = events.outcome;
        const replayed = events.replay(tree);

        if (recorded != .complete) return recorded;
        if (buffered != .complete) return buffered;
        return replayed;
    }

    fn run(parser: *Parser) void {
        assert(parser.task_count == 0);
        assert(parser.position == 0);

        _ = parser.call(.{ .file = .{} });

        var resumes: u64 = 0;

        while (parser.task_count > 0) {
            resumes += 1;

            assert(resumes <= resume_count_max);

            const depth = parser.task_count;

            switch (parser.task_resume(&parser.tasks[depth - 1])) {
                .called => assert(parser.task_count >= depth),
                .returned => {
                    assert(parser.task_count == depth);

                    parser.task_count -= 1;
                },
            }
        }
    }

    fn call(parser: *Parser, task: Task) Resumed {
        assert(parser.task_count <= task_count_max);
        assert(parser.nesting <= nest_depth_max);

        if (parser.task_count == task_count_max) {
            parser.outcome = .too_deep;
            parser.returned = .done;

            parser.emit();

            return .called;
        }

        parser.tasks[parser.task_count] = task;
        parser.task_count += 1;

        return .called;
    }

    fn task_resume(parser: *Parser, task: *Task) Resumed {
        assert(parser.task_count > 0);
        assert(parser.position <= parser.count());

        switch (task.*) {
            inline else => |*state, tag| {
                const resume_function = @field(Parser, @tagName(tag) ++ "_resume");
                return resume_function(parser, state);
            },
        }
    }

    fn file_resume(parser: *Parser, state: *File) Resumed {
        assert(parser.task_count > 0);
        assert(parser.nesting == 0);
        assert(parser.task_count == 1);

        switch (state.stage) {
            .start => {
                parser.events.start(.file);
                state.stage = .attributes;

                return parser.call(.{ .attributes = .{ .inner = true } });
            },
            .attributes => {
                state.stage = .items;

                return parser.call(.{ .items = .{ .closer = .error_token } });
            },
            .items => {
                if (parser.current() != null) parser.record(.unexpected_token);
                if (!parser.delimiters_balanced()) parser.record(.unmatched_bracket);
                if (!parser.literals_closed()) parser.record(.unexpected_token);
                if (!parser.documents_attached()) parser.record(.unexpected_token);

                parser.events.finish();

                return .returned;
            },
        }
    }

    fn delimiters_balanced(parser: *const Parser) bool {
        assert(parser.raw.len == parser.tokens.len);

        var closers: [delimiter_depth_max]Kind = undefined;
        var depth: u32 = 0;

        for (parser.raw) |kind| {
            const closer: ?Kind = switch (kind) {
                .brace_open => .brace_close,
                .bracket_open => .bracket_close,
                .paren_open => .paren_close,
                else => null,
            };

            if (closer) |held| {
                if (depth == delimiter_depth_max) return true;

                closers[depth] = held;
                depth += 1;

                continue;
            }

            switch (kind) {
                .brace_close, .bracket_close, .paren_close => {
                    if (depth == 0) return false;

                    depth -= 1;

                    if (closers[depth] != kind) return false;
                },
                else => {},
            }
        }

        return depth == 0;
    }

    fn documents_attached(parser: *const Parser) bool {
        assert(parser.raw.len == parser.tokens.len);

        var index = parser.raw.len;

        while (index > 0) {
            index -= 1;

            const kind = parser.raw[index];
            if (kind == .comment) continue;
            if (kind != .doc_comment) return true;

            const text = parser.tokens[index].text(parser.source);
            if (outer_documented(text)) return false;
        }

        return true;
    }

    fn literals_closed(parser: *const Parser) bool {
        assert(parser.raw.len == parser.tokens.len);

        for (parser.raw, parser.tokens) |kind, token| {
            if (token.end() < parser.source.len) continue;

            const text = token.text(parser.source);

            const closed = switch (kind) {
                .comment, .doc_comment => comment_closed(text),
                .byte_string_literal, .c_string_literal, .string_literal => string_closed(text),
                else => true,
            };

            if (!closed) return false;
        }

        return true;
    }

    fn items_resume(parser: *Parser, state: *Items) Resumed {
        assert(parser.task_count > 0);
        assert(state.iteration <= parser.steps());
        assert(state.before <= parser.position);
        assert(state.closer.is_token());

        stage: switch (state.stage) {
            .next => {
                if (state.iteration == item_iteration_max) return .returned;

                state.iteration += 1;

                parser.skip_trivia();

                const kind = parser.current() orelse return .returned;
                if (kind == state.closer) return .returned;

                state.before = parser.position;
                state.stage = .item;

                return parser.call(.{ .item = .{} });
            },
            .item => {
                parser.progress_force(state.before);

                continue :stage .next;
            },
        }
    }

    fn item_resume(parser: *Parser, state: *Item) Resumed {
        assert(parser.task_count > 0);
        assert(parser.position <= parser.count());

        switch (state.stage) {
            .start => {
                if (!parser.descend()) {
                    parser.emit();

                    return .returned;
                }

                state.checkpoint = parser.anchor();
                state.stage = .attributes;

                return parser.call(.{ .attributes = .{} });
            },
            .attributes => {
                state.stage = .visibility;

                return parser.call(.{ .visibility = .{} });
            },
            .visibility => {
                state.stage = .body;

                if (parser.item_task(state.checkpoint.?)) |task| return parser.call(task);
            },
            .body => {},
        }

        assert(parser.nesting > 0);

        parser.ascend();

        return .returned;
    }

    fn item_task(parser: *Parser, checkpoint: Checkpoint) ?Task {
        assert(parser.nesting > 0);
        assert(checkpoint.index <= parser.events.count());

        parser.defaultness();

        if (parser.restricts_impl()) {
            parser.bump();
            parser.skip_group();
        }

        const kind = parser.current() orelse return null;
        const next = parser.peek_ahead(1);

        switch (kind) {
            .use_keyword => return .{ .use_item = .{ .checkpoint = checkpoint } },
            .struct_keyword => return struct_item_of(checkpoint, .item_struct),
            .enum_keyword => return .{ .enum_item = .{ .checkpoint = checkpoint } },
            .trait_keyword => return .{ .trait_item = .{ .checkpoint = checkpoint } },
            .impl_keyword => return .{ .impl_item = .{ .checkpoint = checkpoint } },
            else => {},
        }

        if (kind == .union_keyword) {
            if (is_name(next)) return struct_item_of(checkpoint, .item_union);
        }

        if (kind == .unsafe_keyword) {
            if (next == .trait_keyword) return .{ .trait_item = .{ .checkpoint = checkpoint } };
            if (next == .impl_keyword) return .{ .impl_item = .{ .checkpoint = checkpoint } };
        }

        if (parser.opens_a_trait()) return .{ .trait_item = .{ .checkpoint = checkpoint } };
        return parser.item_task_keyword(checkpoint, kind, next);
    }

    fn item_task_keyword(parser: *Parser, checkpoint: Checkpoint, kind: Kind, next: Kind) ?Task {
        assert(kind.is_token());
        assert(checkpoint.index <= parser.events.count());
        assert(next.is_token());

        switch (kind) {
            .mod_keyword => return .{ .mod_item = .{ .checkpoint = checkpoint } },
            .type_keyword => return .{
                .type_alias = .{ .checkpoint = checkpoint, .kind = .item_type, .bounded = false },
            },
            .static_keyword => return static_item_of(checkpoint, .item_static, true),
            else => {},
        }

        if (kind == .macro_keyword) {
            if (is_name(next)) return macro_item_of(checkpoint, .item_macro);
        }

        if (kind == .extern_keyword) {
            if (next == .crate_keyword) {
                parser.extern_crate(checkpoint);

                return null;
            }
        }

        if (kind == .const_keyword) {
            const impl = next == .impl_keyword or
                next == .unsafe_keyword and parser.peek_ahead(2) == .impl_keyword;

            if (impl) return .{ .impl_item = .{ .checkpoint = checkpoint } };
            if (!parser.opens_a_function()) return static_item_of(checkpoint, .item_const, true);
        }

        if (parser.opens_a_foreign_module(parser.position)) {
            return .{ .foreign_mod = .{ .checkpoint = checkpoint } };
        }

        if (parser.opens_a_function()) {
            return .{ .function = .{ .checkpoint = checkpoint, .kind = .item_fn } };
        }

        if (parser.opens_a_macro_call()) return macro_item_of(checkpoint, .item_macro);

        parser.record(.unexpected_token);
        parser.emit();

        return null;
    }

    fn defaultness(parser: *Parser) void {
        assert(parser.position <= parser.count());

        if (!parser.word("default")) return;

        const qualified = switch (parser.peek_ahead(1)) {
            .async_keyword,
            .const_keyword,
            .extern_keyword,
            .fn_keyword,
            .impl_keyword,
            .type_keyword,
            .unsafe_keyword,
            => true,
            else => parser.word_at(parser.ahead_position(1), "safe"),
        };

        if (qualified) parser.bump();
    }

    fn extern_crate(parser: *Parser, checkpoint: Checkpoint) void {
        assert(parser.at(.extern_keyword));
        assert(checkpoint.index <= parser.events.count());

        parser.events.start_at(checkpoint, .item_extern_crate);
        parser.bump();
        parser.bump();
        parser.identifier();

        if (parser.eat(.as_keyword)) parser.identifier_or_underscore();

        _ = parser.eat(.semicolon);

        parser.events.finish();
    }

    fn attributes_resume(parser: *Parser, state: *Attributes) Resumed {
        assert(parser.task_count > 0);
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .next => {
                if (!parser.attribute_open(state)) {
                    if (state.step) |step| parser.returned = step;

                    return .returned;
                }

                if (!parser.at(.bracket_open)) {
                    parser.events.finish();

                    continue :stage .next;
                }

                state.end = parser.balanced_end(parser.significant(parser.position));

                parser.bump();

                const held = parser.peek();
                const unsafe = held == .unsafe_keyword;

                if (!parser.attribute_meta(held)) continue :stage .drain;

                state.checkpoint = parser.anchor();

                if (unsafe) {
                    parser.self_path();

                    continue :stage .path;
                }

                state.stage = .path;

                return parser.call(.{ .path = .{ .expression = true } });
            },
            .path => {
                if (parser.at(.equal)) {
                    parser.events.start_at(state.checkpoint.?, .meta_name_value);
                    parser.bump();
                    state.stage = .value;

                    return parser.meta_valued();
                }

                if (is_opener(parser.peek())) {
                    parser.events.start_at(state.checkpoint.?, .meta_list);
                    parser.skip_group();
                    parser.events.finish();
                }

                continue :stage .drain;
            },
            .value => {
                parser.events.finish();

                continue :stage .drain;
            },
            .drain => {
                parser.drain(state.end);
                parser.events.finish();

                continue :stage .next;
            },
        }
    }

    fn attribute_meta(parser: *Parser, held: Kind) bool {
        assert(held.is_token());

        if (held == .bracket_close) parser.record(.expected_identifier);

        const unsafe = held == .unsafe_keyword;

        if (unsafe) {
            if (parser.peek_ahead(1) != .paren_open) parser.record(.unexpected_token);
        }

        return expression.opens_a_path(held) or unsafe;
    }

    fn meta_valued(parser: *Parser) Resumed {
        assert(parser.position <= parser.count());

        if (parser.at(.bracket_close)) parser.record(.expected_expression);

        return parser.call(.{ .expression = .{ .structures = true } });
    }

    fn attribute_open(parser: *Parser, state: *Attributes) bool {
        assert(parser.position <= parser.count());
        assert(state.iteration <= parser.steps());

        if (state.iteration == parser.steps()) return false;

        state.iteration += 1;

        if (!parser.at(.pound)) return false;

        if (state.inner) {
            if (parser.ahead(1) != .bang) return false;
        }

        parser.open(.attribute);
        parser.bump();
        _ = parser.eat(.bang);

        return true;
    }

    fn visibility_resume(parser: *Parser, state: *Visibility) Resumed {
        assert(parser.task_count > 0);
        assert(parser.position <= parser.count());

        switch (state.stage) {
            .start => {
                if (!parser.at(.pub_keyword)) return .returned;

                if (!parser.restricts_visibility()) {
                    parser.bump();

                    return .returned;
                }

                state.end = parser.balanced_end(parser.ahead_position(1));

                parser.open(.vis_restricted);
                parser.bump();
                parser.bump();
                _ = parser.eat(.in_keyword);
                state.stage = .path;

                if (expression.opens_a_path(parser.peek())) {
                    return parser.call(.{ .path = .{ .expression = true } });
                }
            },
            .path => {},
        }

        assert(state.end > 0);

        parser.drain(state.end);
        parser.events.finish();

        return .returned;
    }

    fn use_item_resume(parser: *Parser, state: *UseItem) Resumed {
        assert(parser.task_count > 0);
        assert(state.checkpoint.index <= parser.events.count());

        switch (state.stage) {
            .start => {
                parser.events.start_at(state.checkpoint, .item_use);
                parser.bump();
                _ = parser.eat(.colon_colon);
                state.stage = .tree;

                return parser.call(.{ .use_tree = .{} });
            },
            .tree => {
                _ = parser.eat(.semicolon);

                parser.events.finish();

                return .returned;
            },
        }
    }

    fn use_tree_resume(parser: *Parser, state: *UseTree) Resumed {
        assert(parser.task_count > 0);
        assert(parser.position <= parser.count());

        switch (state.stage) {
            .start => {
                if (!parser.descend()) {
                    parser.emit();

                    return .returned;
                }

                if (parser.use_tree_open(state)) |task| return parser.call(task);
            },
            .path => parser.events.finish(),
            .group => {},
        }

        assert(parser.nesting > 0);

        parser.ascend();

        return .returned;
    }

    fn use_tree_open(parser: *Parser, state: *UseTree) ?Task {
        assert(state.stage == .start);
        assert(parser.nesting > 0);

        const kind = parser.current() orelse return null;

        if (kind == .star) {
            parser.wrap(.use_glob);

            return null;
        }

        if (kind == .brace_open) {
            state.stage = .group;

            return .{ .use_group = .{} };
        }

        const checkpoint = parser.anchor();
        const named = is_segment(kind) or kind == .underscore;

        if (!named) {
            parser.record(.expected_identifier);

            return null;
        }

        const next = parser.ahead(1);

        if (next == .colon_colon) {
            parser.events.start_at(checkpoint, .use_path);
            parser.wrap(.ident);
            parser.bump();
            state.stage = .path;

            return .{ .use_tree = .{} };
        }

        if (next == .as_keyword) {
            parser.events.start_at(checkpoint, .use_rename);
            parser.wrap(.ident);
            parser.bump();

            const renamed = is_name(parser.peek()) or parser.at(.underscore);

            if (renamed) parser.wrap(.ident);

            parser.events.finish();

            return null;
        }

        parser.events.start_at(checkpoint, .use_name);
        parser.wrap(.ident);
        parser.events.finish();

        return null;
    }

    fn use_group_resume(parser: *Parser, state: *UseGroup) Resumed {
        assert(parser.task_count > 0);
        assert(state.before <= parser.position);
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .start => {
                parser.open(.use_group);
                parser.bump();

                continue :stage .next;
            },
            .next => {
                if (parser.list_closed(&state.iteration, .brace_close)) continue :stage .closed;

                state.before = parser.position;
                state.stage = .tree;
                _ = parser.eat(.colon_colon);

                return parser.call(.{ .use_tree = .{} });
            },
            .tree => {
                if (parser.list_continued(state.before)) continue :stage .next;

                continue :stage .closed;
            },
            .closed => {
                _ = parser.eat(.brace_close);

                parser.events.finish();

                return .returned;
            },
        }
    }

    fn struct_item_resume(parser: *Parser, state: *StructItem) Resumed {
        assert(parser.task_count > 0);
        assert(state.checkpoint.index <= parser.events.count());
        assert(state.kind.is_node());

        switch (state.stage) {
            .start => {
                parser.events.start_at(state.checkpoint, state.kind);
                parser.bump();
                parser.identifier();
                state.stage = .generics;

                return parser.call(.{ .generics = .{} });
            },
            .generics => {
                if (parser.at(.paren_open)) {
                    state.stage = .unnamed;

                    return parser.call(fields_of(.fields_unnamed));
                }

                state.stage = .where;

                return parser.call(.{ .where_clause = .{} });
            },
            .unnamed => {
                state.stage = .unnamed_where;

                return parser.call(.{ .where_clause = .{} });
            },
            .unnamed_where => _ = parser.eat(.semicolon),
            .where => {
                if (parser.at(.brace_open)) {
                    state.stage = .named;

                    return parser.call(fields_of(.fields_named));
                }

                _ = parser.eat(.semicolon);
            },
            .named => {},
        }

        parser.events.finish();

        return .returned;
    }

    fn enum_item_resume(parser: *Parser, state: *EnumItem) Resumed {
        assert(parser.task_count > 0);
        assert(state.checkpoint.index <= parser.events.count());
        assert(state.before <= parser.position);
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .start => {
                parser.events.start_at(state.checkpoint, .item_enum);
                parser.bump();
                parser.identifier();
                state.stage = .generics;

                return parser.call(.{ .generics = .{} });
            },
            .generics => {
                state.stage = .where;

                return parser.call(.{ .where_clause = .{} });
            },
            .where => {
                _ = parser.expect(.brace_open, .unexpected_token);

                continue :stage .next;
            },
            .next => {
                if (parser.list_closed(&state.iteration, .brace_close)) continue :stage .closed;

                state.before = parser.position;
                state.stage = .variant;

                return parser.call(.{ .enum_variant = .{} });
            },
            .variant => {
                if (parser.list_continued(state.before)) continue :stage .next;

                continue :stage .closed;
            },
            .closed => {
                _ = parser.eat(.brace_close);

                parser.events.finish();

                return .returned;
            },
        }
    }

    fn enum_variant_resume(parser: *Parser, state: *EnumVariant) Resumed {
        assert(parser.task_count > 0);
        assert(parser.position <= parser.count());

        stage: switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();
                state.stage = .attributes;

                return parser.call(.{ .attributes = .{} });
            },
            .attributes => {
                parser.events.start_at(state.checkpoint.?, .variant);

                if (!is_segment(parser.peek())) parser.record(.expected_identifier);

                parser.identifier();
                state.stage = .fields;

                switch (parser.peek()) {
                    .paren_open => return parser.call(fields_of(.fields_unnamed)),
                    .brace_open => return parser.call(fields_of(.fields_named)),
                    else => continue :stage .fields,
                }
            },
            .fields => {
                if (parser.eat(.equal)) {
                    state.stage = .value;

                    return parser.call(.{ .expression = .{ .structures = true } });
                }

                continue :stage .value;
            },
            .value => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn fields_resume(parser: *Parser, state: *Fields) Resumed {
        assert(parser.task_count > 0);
        assert(state.before <= parser.position);

        const closer: Kind = if (state.kind == .fields_named) .brace_close else .paren_close;

        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .start => {
                parser.open(state.kind);
                parser.bump();

                continue :stage .next;
            },
            .next => {
                if (parser.list_closed(&state.iteration, closer)) continue :stage .closed;

                state.before = parser.position;
                state.stage = .field;

                return parser.call(.{ .field = .{ .named = state.kind == .fields_named } });
            },
            .field => {
                if (parser.list_continued(state.before)) continue :stage .next;

                continue :stage .closed;
            },
            .closed => {
                _ = parser.eat(closer);

                parser.events.finish();

                return .returned;
            },
        }
    }

    fn field_resume(parser: *Parser, state: *Field) Resumed {
        assert(parser.task_count > 0);
        assert(parser.position <= parser.count());

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();
                state.stage = .attributes;

                return parser.call(.{ .attributes = .{} });
            },
            .attributes => {
                state.stage = .visibility;

                return parser.call(.{ .visibility = .{} });
            },
            .visibility => {
                parser.events.start_at(state.checkpoint.?, .field);

                if (state.named) {
                    _ = parser.eat(.unsafe_keyword);

                    parser.identifier();
                    _ = parser.expect(.colon, .expected_colon);
                }

                state.stage = .typed;

                return parser.call(.{ .type_of = .{} });
            },
            .typed => {
                state.stage = .valued;

                if (state.named) {
                    if (parser.eat(.equal)) {
                        return parser.call(.{ .expression = .{ .structures = true } });
                    }
                }

                parser.events.finish();

                return .returned;
            },
            .valued => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn trait_item_resume(parser: *Parser, state: *TraitItem) Resumed {
        assert(parser.task_count > 0);
        assert(state.checkpoint.index <= parser.events.count());

        stage: switch (state.stage) {
            .start => {
                parser.trait_qualifiers();
                parser.bump();
                parser.identifier();
                state.stage = .generics;

                return parser.call(.{ .generics = .{} });
            },
            .generics => {
                if (parser.eat(.equal)) {
                    state.stage = .alias_bounds;

                    return parser.call(.{ .type_bounds = .{} });
                }

                if (parser.eat(.colon)) {
                    state.stage = .bounds;

                    return parser.call(.{ .type_bounds = .{} });
                }

                continue :stage .bounds;
            },
            .alias_bounds => {
                state.stage = .alias_where;

                return parser.call(.{ .where_clause = .{} });
            },
            .alias_where => {
                _ = parser.eat(.semicolon);

                parser.enclose(state.checkpoint, .item_trait_alias);

                return .returned;
            },
            .bounds => {
                state.stage = .where;

                return parser.call(.{ .where_clause = .{} });
            },
            .where => {
                _ = parser.expect(.brace_open, .unexpected_token);
                state.stage = .members;

                return parser.call(.{ .member_list = .{ .family = .trait_item_fn } });
            },
            .members => {
                parser.enclose(state.checkpoint, .item_trait);

                return .returned;
            },
        }
    }

    fn trait_qualifiers(parser: *Parser) void {
        for (0..trait_qualifier_max) |_| {
            const eaten = parser.eat(.unsafe_keyword) or parser.eat(.const_keyword);
            if (eaten) continue;
            if (!parser.word("auto")) break;

            parser.bump();
        }

        assert(parser.position <= parser.count());
    }

    fn impl_item_resume(parser: *Parser, state: *ImplItem) Resumed {
        assert(parser.task_count > 0);
        assert(state.checkpoint.index <= parser.events.count());

        stage: switch (state.stage) {
            .start => {
                parser.events.start_at(state.checkpoint, .item_impl);
                _ = parser.eat(.const_keyword);
                _ = parser.eat(.unsafe_keyword);

                parser.bump();
                state.stage = .generics;

                return parser.call(.{ .generics = .{} });
            },
            .generics => {
                _ = parser.eat(.const_keyword);

                if (parser.at(.bang)) {
                    if (expression.opens_a_path(parser.peek_ahead(1))) parser.bump();
                }

                if (parser.trait_ahead()) {
                    state.stage = .path;

                    return parser.call(.{ .path = .{ .expression = false } });
                }

                continue :stage .self_type;
            },
            .path => {
                _ = parser.eat(.for_keyword);

                continue :stage .self_type;
            },
            .self_type => {
                state.stage = .typed;

                return parser.call(.{ .type_of = .{} });
            },
            .typed => {
                state.stage = .where;

                return parser.call(.{ .where_clause = .{} });
            },
            .where => {
                _ = parser.expect(.brace_open, .unexpected_token);
                state.stage = .members;

                return parser.call(.{ .member_list = .{ .family = .impl_item_fn } });
            },
            .members => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn mod_item_resume(parser: *Parser, state: *ModItem) Resumed {
        assert(parser.task_count > 0);
        assert(state.checkpoint.index <= parser.events.count());

        switch (state.stage) {
            .start => {
                parser.events.start_at(state.checkpoint, .item_mod);
                parser.bump();
                parser.identifier();

                if (parser.eat(.semicolon)) {
                    parser.events.finish();

                    return .returned;
                }

                _ = parser.expect(.brace_open, .unexpected_token);
                state.stage = .attributes;

                return parser.call(.{ .attributes = .{ .inner = true } });
            },
            .attributes => {
                state.stage = .items;

                return parser.call(.{ .items = .{ .closer = .brace_close } });
            },
            .items => {
                _ = parser.eat(.brace_close);

                parser.events.finish();

                return .returned;
            },
        }
    }

    fn type_alias_resume(parser: *Parser, state: *TypeAlias) Resumed {
        assert(parser.task_count > 0);
        assert(state.checkpoint.index <= parser.events.count());
        assert(state.kind.is_node());

        stage: switch (state.stage) {
            .start => {
                parser.events.start_at(state.checkpoint, state.kind);
                parser.bump();
                parser.identifier();
                state.stage = .generics;

                return parser.call(.{ .generics = .{} });
            },
            .generics => {
                if (state.bounded) {
                    if (parser.eat(.colon)) {
                        state.stage = .bounds;

                        return parser.call(.{ .type_bounds = .{} });
                    }
                }

                continue :stage .bounds;
            },
            .bounds => {
                state.stage = .where;

                return parser.call(.{ .where_clause = .{} });
            },
            .where => {
                if (parser.eat(.equal)) {
                    state.stage = .typed;

                    return parser.call(.{ .type_of = .{} });
                }

                continue :stage .closed;
            },
            .typed => {
                state.stage = .closed;

                return parser.call(.{ .where_clause = .{} });
            },
            .closed => {
                _ = parser.eat(.semicolon);

                parser.events.finish();

                return .returned;
            },
        }
    }

    fn static_item_resume(parser: *Parser, state: *StaticItem) Resumed {
        assert(parser.task_count > 0);
        assert(state.checkpoint.index <= parser.events.count());
        assert(state.kind.is_node());

        stage: switch (state.stage) {
            .start => return parser.static_item_start(state),
            .generics => {
                if (parser.eat(.colon)) {
                    state.stage = .typed;

                    return parser.call(.{ .type_of = .{} });
                }

                parser.record(.expected_colon);

                continue :stage .typed;
            },
            .typed => {
                const assigned = parser.eat(.equal) or parser.eat_angled_equal();

                if (assigned) {
                    state.stage = .valued;

                    return parser.call(.{ .expression = .{ .structures = true } });
                }

                continue :stage .valued;
            },
            .valued => {
                state.stage = .bounded;

                const constant = switch (state.kind) {
                    .impl_item_const, .item_const, .trait_item_const => true,
                    else => false,
                };

                if (constant) {
                    if (parser.at(.where_keyword)) return parser.call(.{ .where_clause = .{} });
                }

                continue :stage .bounded;
            },
            .bounded => {
                _ = parser.eat(.semicolon);

                parser.events.finish();

                return .returned;
            },
        }
    }

    fn static_item_start(parser: *Parser, state: *StaticItem) Resumed {
        assert(state.stage == .start);
        assert(state.kind.is_node());

        parser.events.start_at(state.checkpoint, state.kind);
        parser.bump();

        const statics = state.kind == .item_static or state.kind == .foreign_item_static;

        if (!statics) {
            if (parser.at(.mut_keyword)) parser.record(.unexpected_token);
        }

        if (state.mutable) _ = parser.eat(.mut_keyword);

        if (statics) {
            if (parser.at(.underscore)) parser.record(.expected_identifier);
        }

        parser.identifier_or_underscore();
        state.stage = .generics;

        if (statics) {
            if (parser.at(.less)) parser.record(.unexpected_token);
        }

        return parser.call(.{ .generics = .{} });
    }

    fn macro_item_resume(parser: *Parser, state: *MacroItem) Resumed {
        assert(parser.task_count > 0);
        assert(state.checkpoint.index <= parser.events.count());
        assert(state.kind.is_node());

        switch (state.stage) {
            .start => {
                parser.events.start_at(state.checkpoint, state.kind);
                state.held = parser.anchor();

                if (state.kind == .item_macro) {
                    if (parser.at(.macro_keyword)) {
                        parser.macro_definition(state.held.?);

                        return .returned;
                    }
                }

                state.stage = .path;

                return parser.call(.{ .path = .{ .expression = true } });
            },
            .path => {
                _ = parser.eat(.bang);

                if (is_name(parser.peek())) parser.identifier();

                const braced = parser.at(.brace_open) and state.kind == .item_macro;

                parser.skip_group();
                parser.enclose(state.held.?, .macro);

                if (!braced) _ = parser.eat(.semicolon);

                parser.events.finish();

                return .returned;
            },
        }
    }

    fn macro_definition(parser: *Parser, held: Checkpoint) void {
        assert(parser.at(.macro_keyword));
        assert(held.index <= parser.events.count());

        parser.bump();
        parser.identifier();

        if (parser.at(.paren_open)) parser.skip_group();

        parser.skip_group();
        parser.enclose(held, .macro);
        parser.events.finish();
    }

    fn foreign_mod_resume(parser: *Parser, state: *ForeignMod) Resumed {
        assert(parser.task_count > 0);
        assert(state.checkpoint.index <= parser.events.count());

        switch (state.stage) {
            .start => {
                parser.events.start_at(state.checkpoint, .item_foreign_mod);
                _ = parser.eat(.unsafe_keyword);

                parser.abi();
                _ = parser.expect(.brace_open, .unexpected_token);
                state.stage = .members;

                return parser.call(.{ .member_list = .{ .family = .foreign_item_fn } });
            },
            .members => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn member_list_resume(parser: *Parser, state: *MemberList) Resumed {
        assert(parser.task_count > 0);
        assert(state.iteration <= parser.steps());
        assert(state.before <= parser.position);
        assert(state.family.is_node());

        stage: switch (state.stage) {
            .start => {
                state.stage = .next;

                return parser.call(.{ .attributes = .{ .inner = true } });
            },
            .next => {
                if (parser.list_closed(&state.iteration, .brace_close)) {
                    _ = parser.eat(.brace_close);

                    return .returned;
                }

                state.before = parser.position;
                state.stage = .member;

                return parser.call(.{ .member = .{ .family = state.family } });
            },
            .member => {
                parser.progress_force(state.before);

                continue :stage .next;
            },
        }
    }

    fn member_resume(parser: *Parser, state: *Member) Resumed {
        assert(parser.task_count > 0);
        assert(state.family.is_node());

        switch (state.stage) {
            .start => {
                if (!parser.descend()) {
                    parser.emit();

                    return .returned;
                }

                state.checkpoint = parser.anchor();
                state.stage = .attributes;

                return parser.call(.{ .attributes = .{} });
            },
            .attributes => {
                state.stage = .visibility;

                return parser.call(.{ .visibility = .{} });
            },
            .visibility => {
                state.stage = .body;

                if (parser.member_task(state.family, state.checkpoint.?)) |task| {
                    return parser.call(task);
                }
            },
            .body => {},
        }

        assert(parser.nesting > 0);

        parser.ascend();

        return .returned;
    }

    fn member_task(parser: *Parser, family: Kind, checkpoint: Checkpoint) ?Task {
        assert(family.is_node());
        assert(checkpoint.index <= parser.events.count());

        parser.defaultness();

        const safety = parser.at(.unsafe_keyword) or parser.word("safe");

        if (safety) {
            if (parser.peek_ahead(1) == .static_keyword) parser.bump();
        }

        const kind = parser.current() orelse return null;

        if (kind == .type_keyword) {
            const alias = member_kind_of(family, .{
                .trait_item_type,
                .impl_item_type,
                .foreign_item_type,
            });

            return .{ .type_alias = .{ .checkpoint = checkpoint, .kind = alias, .bounded = true } };
        }

        if (kind == .const_keyword) {
            if (!parser.opens_a_function()) {
                const constant: Kind = if (family == .trait_item_fn)
                    .trait_item_const
                else
                    .impl_item_const;

                return static_item_of(checkpoint, constant, false);
            }
        }

        if (kind == .static_keyword) return static_item_of(checkpoint, .foreign_item_static, true);

        if (parser.opens_a_function()) {
            return .{ .function = .{ .checkpoint = checkpoint, .kind = family } };
        }

        if (parser.opens_a_macro_call()) {
            const invocation = member_kind_of(family, .{
                .trait_item_macro,
                .impl_item_macro,
                .foreign_item_macro,
            });

            return macro_item_of(checkpoint, invocation);
        }

        parser.record(.unexpected_token);
        parser.emit();

        return null;
    }

    fn function_resume(parser: *Parser, state: *Function) Resumed {
        assert(parser.task_count > 0);
        assert(state.checkpoint.index <= parser.events.count());
        assert(state.kind.is_node());

        switch (state.stage) {
            .start => {
                parser.events.start_at(state.checkpoint, state.kind);
                state.stage = .signature;

                return parser.call(.{ .signature = .{} });
            },
            .signature => {
                if (parser.at(.brace_open)) {
                    state.stage = .body;

                    return parser.call(.{ .block = .{} });
                }

                _ = parser.eat(.semicolon);
            },
            .body => {},
        }

        parser.events.finish();

        return .returned;
    }

    fn signature_resume(parser: *Parser, state: *Signature) Resumed {
        assert(parser.task_count > 0);
        assert(parser.position <= parser.count());

        stage: switch (state.stage) {
            .start => {
                if (parser.word("default")) parser.bump();

                parser.open(.signature);
                parser.signature_qualifiers();
                _ = parser.expect(.fn_keyword, .unexpected_token);

                parser.identifier();
                state.stage = .generics;

                return parser.call(.{ .generics = .{} });
            },
            .generics => {
                state.stage = .parameters;

                return parser.call(.{ .parameters = .{} });
            },
            .parameters => {
                if (parser.eat(.r_arrow)) {
                    state.stage = .result;

                    return parser.call(.{ .type_of = .{} });
                }

                continue :stage .result;
            },
            .result => {
                state.stage = .where;

                return parser.call(.{ .where_clause = .{} });
            },
            .where => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn signature_qualifiers(parser: *Parser) void {
        var rank: u32 = 0;

        for (0..signature_qualifier_max) |_| {
            const held: u32 = switch (parser.peek()) {
                .const_keyword => 1,
                .async_keyword => 2,
                .unsafe_keyword => 3,
                .extern_keyword => 4,
                else => if (parser.word("safe")) 3 else if (parser.word("gen")) 2 else break,
            };

            if (held < rank) parser.record(.unexpected_token);

            rank = held;

            if (parser.at(.extern_keyword)) {
                parser.abi();
            } else {
                parser.bump();
            }
        }

        assert(parser.position <= parser.count());
    }

    fn parameters_resume(parser: *Parser, state: *Parameters) Resumed {
        assert(parser.task_count > 0);
        assert(state.before <= parser.position);
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .start => {
                if (!parser.expect(.paren_open, .unexpected_token)) return .returned;

                continue :stage .next;
            },
            .next => {
                if (parser.list_closed(&state.iteration, .paren_close)) continue :stage .closed;

                state.before = parser.position;
                state.stage = .parameter;

                return parser.call(.{ .parameter = .{} });
            },
            .parameter => {
                if (parser.list_continued(state.before)) continue :stage .next;

                continue :stage .closed;
            },
            .closed => {
                _ = parser.eat(.paren_close);

                return .returned;
            },
        }
    }

    fn parameter_resume(parser: *Parser, state: *Parameter) Resumed {
        assert(parser.task_count > 0);
        assert(parser.position <= parser.count());

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();
                state.stage = .attributes;

                return parser.call(.{ .attributes = .{} });
            },
            .attributes => {
                if (parser.at(.dot_dot_dot)) {
                    parser.variadic_parameter(state.checkpoint.?);

                    return .returned;
                }

                if (parser.receiver_ahead()) {
                    state.stage = .done;

                    return parser.call(.{ .receiver = .{ .checkpoint = state.checkpoint.? } });
                }

                state.stage = .pattern;

                return parser.call(.{ .pattern = .{} });
            },
            .pattern => {
                _ = parser.expect(.colon, .expected_colon);

                if (parser.at(.dot_dot_dot)) {
                    parser.variadic_parameter(state.checkpoint.?);

                    return .returned;
                }

                state.stage = .typed;

                return parser.call(.{ .type_of = .{} });
            },
            .typed => {
                parser.enclose(state.checkpoint.?, .pat_type);

                return .returned;
            },
            .done => return .returned,
        }
    }

    fn variadic_parameter(parser: *Parser, checkpoint: Checkpoint) void {
        assert(parser.at(.dot_dot_dot));
        assert(checkpoint.index <= parser.events.count());

        parser.bump();

        if (parser.at(.comma)) {
            if (parser.peek_ahead(1) == .paren_close) parser.bump();
        }

        parser.enclose(checkpoint, .variadic);
    }

    fn receiver_resume(parser: *Parser, state: *Receiver) Resumed {
        assert(parser.task_count > 0);
        assert(state.checkpoint.index <= parser.events.count());

        switch (state.stage) {
            .start => {
                parser.events.start_at(state.checkpoint, .receiver);

                const held = parser.anchor();
                const referenced = parser.at(.ampersand);

                if (referenced) {
                    parser.bump();
                    parser.lifetime_of(true);
                }

                _ = parser.eat(.mut_keyword);

                if (parser.ahead(1) == .colon) {
                    parser.bump();
                    parser.bump();
                    state.stage = .typed;

                    return parser.call(.{ .type_of = .{} });
                }

                const inner = parser.anchor();

                parser.self_path();
                parser.enclose(inner, .type_path);

                if (referenced) parser.enclose(held, .type_reference);
            },
            .typed => {},
        }

        parser.events.finish();

        return .returned;
    }

    fn generics_resume(parser: *Parser, state: *Generics) Resumed {
        assert(parser.task_count > 0);
        assert(state.before <= parser.position);
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .start => {
                if (!parser.at(.less)) return .returned;

                parser.open(.generics);
                parser.bump();

                continue :stage .next;
            },
            .next => {
                if (parser.list_closed(&state.iteration, .greater)) continue :stage .closed;

                state.before = parser.position;
                state.stage = .parameter;

                return parser.call(.{ .generic_parameter = .{} });
            },
            .parameter => {
                if (parser.list_continued(state.before)) continue :stage .next;

                continue :stage .closed;
            },
            .closed => {
                _ = parser.eat(.greater);

                parser.events.finish();

                return .returned;
            },
        }
    }

    fn generic_parameter_resume(parser: *Parser, state: *GenericParameter) Resumed {
        assert(parser.task_count > 0);
        assert(parser.position <= parser.count());

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();
                state.stage = .attributes;

                return parser.call(.{ .attributes = .{} });
            },
            .attributes => return parser.generic_parameter_open(state),
            .constant => {
                state.stage = .closed;

                if (parser.eat(.equal)) {
                    if (parser.constant_default_task()) |task| return parser.call(task);
                }
            },
            .bounds => return parser.generic_parameter_default(state),
            .closed => {},
        }

        parser.events.finish();

        return .returned;
    }

    fn generic_parameter_default(parser: *Parser, state: *GenericParameter) Resumed {
        assert(state.stage == .bounds);
        assert(state.checkpoint != null);

        state.stage = .closed;

        if (parser.eat(.equal)) return parser.call(.{ .type_of = .{} });

        parser.events.finish();

        return .returned;
    }

    fn generic_parameter_open(parser: *Parser, state: *GenericParameter) Resumed {
        assert(state.stage == .attributes);
        assert(state.checkpoint != null);

        if (parser.at(.apostrophe)) {
            parser.events.start_at(state.checkpoint.?, .lifetime_param);
            parser.lifetime();
            state.stage = .closed;

            if (parser.eat(.colon)) return parser.call(.{ .type_bounds = .{} });

            parser.events.finish();

            return .returned;
        }

        if (parser.at(.const_keyword)) {
            parser.events.start_at(state.checkpoint.?, .const_param);
            parser.bump();
            parser.identifier();
            _ = parser.expect(.colon, .expected_colon);
            state.stage = .constant;

            return parser.call(.{ .type_of = .{} });
        }

        parser.events.start_at(state.checkpoint.?, .type_param);
        parser.identifier();
        state.stage = .bounds;

        if (parser.eat(.colon)) return parser.call(.{ .type_bounds = .{} });
        return parser.generic_parameter_default(state);
    }

    fn constant_default_task(parser: *Parser) ?Task {
        assert(parser.significant_next >= parser.position);
        assert(parser.position <= parser.count());

        if (parser.constant_ahead()) return parser.constant_argument_task();

        const pathed = expression.opens_a_path(parser.peek()) and
            parser.peek_ahead(1) == .colon_colon;

        if (pathed) parser.record(.unexpected_token);

        return .{ .type_of = .{} };
    }

    fn constant_argument_task(parser: *Parser) ?Task {
        assert(parser.position <= parser.count());

        const kind = parser.current() orelse return null;

        assert(kind.is_token());

        const block = kind == .brace_open or kind == .const_keyword;
        if (block) return .{ .block_expression = .{ .checkpoint = parser.anchor() } };

        parser.literal_expression();

        return null;
    }

    fn where_clause_resume(parser: *Parser, state: *WhereClause) Resumed {
        assert(parser.task_count > 0);
        assert(state.before <= parser.position);
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .start => {
                if (!parser.at(.where_keyword)) return .returned;

                parser.open(.where_clause);
                parser.bump();

                continue :stage .next;
            },
            .next => {
                if (parser.where_closed(&state.iteration)) continue :stage .closed;

                state.before = parser.position;
                state.stage = .predicate;

                return parser.call(.{ .predicate = .{} });
            },
            .predicate => {
                if (parser.list_continued(state.before)) continue :stage .next;

                continue :stage .closed;
            },
            .closed => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn where_closed(parser: *Parser, iteration: *u32) bool {
        assert(iteration.* <= parser.steps());

        if (iteration.* == parser.steps()) return true;

        iteration.* += 1;

        parser.skip_trivia();

        const kind = parser.current() orelse return true;

        assert(kind.is_token());

        return switch (kind) {
            .brace_open, .equal, .semicolon => true,
            else => false,
        };
    }

    fn predicate_resume(parser: *Parser, state: *Predicate) Resumed {
        assert(parser.task_count > 0);
        assert(parser.position <= parser.count());

        switch (state.stage) {
            .start => {
                const checkpoint = parser.anchor();

                if (parser.at(.apostrophe)) {
                    parser.events.start_at(checkpoint, .predicate_lifetime);
                    parser.lifetime();
                    state.stage = .closed;

                    if (parser.eat(.colon)) return parser.call(.{ .type_bounds = .{} });
                } else {
                    parser.events.start_at(checkpoint, .predicate_type);
                    state.stage = .lifetimes;

                    return parser.call(.{ .bound_lifetimes = .{} });
                }
            },
            .lifetimes => {
                state.stage = .typed;

                return parser.call(.{ .type_of = .{} });
            },
            .typed => {
                _ = parser.expect(.colon, .expected_colon);
                state.stage = .closed;

                return parser.call(.{ .type_bounds = .{} });
            },
            .closed => {},
        }

        parser.events.finish();

        return .returned;
    }

    fn bound_lifetimes_resume(parser: *Parser, state: *BoundLifetimes) Resumed {
        assert(parser.task_count > 0);
        assert(state.before <= parser.position);
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .start => {
                if (!parser.at(.for_keyword)) return .returned;

                parser.open(.bound_lifetimes);
                parser.bump();

                if (!parser.at(.less)) continue :stage .finished;

                state.end = parser.balanced_generic(parser.significant(parser.position));

                parser.bump();

                continue :stage .next;
            },
            .next => {
                if (parser.list_closed(&state.iteration, .greater)) continue :stage .closed;
                if (parser.position >= state.end) continue :stage .closed;

                state.before = parser.position;
                state.stage = .parameter;

                return parser.call(.{ .generic_parameter = .{} });
            },
            .parameter => {
                if (parser.list_continued(state.before)) continue :stage .next;

                continue :stage .closed;
            },
            .closed => {
                _ = parser.eat(.greater);

                continue :stage .finished;
            },
            .finished => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn type_bounds_resume(parser: *Parser, state: *TypeBounds) Resumed {
        assert(parser.task_count > 0);
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .next => {
                if (state.iteration == parser.steps()) return .returned;

                state.iteration += 1;

                parser.skip_trivia();

                if (parser.type_bound_leaf()) continue :stage .separator;
                return parser.type_bounds_open(state);
            },
            .parenthesized => {
                state.stage = .parenthesized_path;

                parser.bound_modifiers();

                if (expression.opens_a_path(parser.peek())) {
                    return parser.call(.{ .path = .{ .expression = false } });
                }

                continue :stage .parenthesized_path;
            },
            .parenthesized_path => {
                parser.drain(state.end);
                parser.enclose(state.checkpoint.?, .trait_bound);

                continue :stage .separator;
            },
            .lifetimes => {
                parser.bound_qualifiers();

                if (!expression.opens_a_path(parser.peek())) return .returned;

                parser.events.start_at(state.checkpoint.?, .trait_bound);
                state.stage = .path;

                return parser.call(.{ .path = .{ .expression = false } });
            },
            .path => {
                parser.events.finish();

                continue :stage .separator;
            },
            .separator => {
                if (!parser.at(.plus)) return .returned;

                if (state.plusless) parser.record(.unexpected_token);

                _ = parser.eat(.plus);

                continue :stage .next;
            },
        }
    }

    fn type_bounds_open(parser: *Parser, state: *TypeBounds) Resumed {
        assert(state.iteration > 0);
        assert(state.iteration <= parser.steps());

        state.checkpoint = parser.anchor();

        if (parser.at(.paren_open)) {
            state.end = parser.balanced_end(parser.significant(parser.position));

            parser.bump();
            state.stage = .parenthesized;

            return parser.call(.{ .bound_lifetimes = .{} });
        }

        parser.bound_opened();
        state.stage = .lifetimes;

        return parser.call(.{ .bound_lifetimes = .{} });
    }

    fn type_bound_leaf(parser: *Parser) bool {
        assert(parser.significant_next >= parser.position);
        assert(parser.position <= parser.count());

        if (parser.at(.apostrophe)) {
            parser.lifetime();

            return true;
        }

        if (!parser.at(.use_keyword)) return false;
        if (parser.ahead(1) != .less) return false;

        parser.precise_capture();

        return true;
    }

    fn type_of_resume(parser: *Parser, state: *TypeOf) Resumed {
        assert(parser.task_count > 0);
        assert(parser.position <= parser.count());

        switch (state.stage) {
            .start => {
                if (!parser.descend()) {
                    parser.emit();

                    return .returned;
                }

                if (parser.type_of_open(state)) |task| return parser.call(task);
            },
            .node => parser.events.finish(),
            .lifetimes => {
                if (parser.opens_a_bare_function()) {
                    state.stage = .done;

                    return parser.call(.{ .bare_function = .{ .checkpoint = state.checkpoint.? } });
                }

                parser.events.start_at(state.checkpoint.?, .type_trait_object);
                state.stage = .node;

                return parser.call(.{ .type_bounds = .{ .plusless = state.plusless } });
            },
            .pathed => {
                const bounded = !state.plusless and parser.at(.plus);

                if (bounded) {
                    if (parser.events.retag(state.checkpoint.?, .type_path, .trait_bound)) {
                        parser.events.start_at(state.checkpoint.?, .type_trait_object);
                        parser.bump();
                        state.stage = .node;

                        return parser.call(.{ .type_bounds = .{} });
                    }
                }
            },
            .done => {},
        }

        assert(parser.nesting > 0);

        parser.ascend();

        return .returned;
    }

    fn type_of_open(parser: *Parser, state: *TypeOf) ?Task {
        assert(state.stage == .start);
        assert(parser.nesting > 0);

        const kind = parser.current() orelse return null;

        state.stage = .node;

        switch (kind) {
            .ampersand => {
                parser.open(.type_reference);
                parser.bump();
                parser.lifetime();
                _ = parser.eat(.mut_keyword);

                if (type_missing(parser.peek())) parser.record(.expected_type);

                return .{ .type_of = .{ .plusless = true } };
            },
            .star => {
                parser.open(.type_ptr);
                parser.bump();

                const qualified = parser.eat(.const_keyword) or parser.eat(.mut_keyword);

                if (!qualified) parser.record(.unexpected_token);
                if (type_missing(parser.peek())) parser.record(.expected_type);

                return .{ .type_of = .{ .plusless = true } };
            },
            .impl_keyword, .dyn_keyword => {
                const node: Kind = switch (kind) {
                    .impl_keyword => .type_impl_trait,
                    else => .type_trait_object,
                };

                parser.open(node);
                parser.bump();

                return .{ .type_bounds = .{ .plusless = state.plusless } };
            },
            .for_keyword => {
                if (parser.bare_function_bound()) {
                    state.checkpoint = parser.anchor();
                    state.stage = .lifetimes;

                    return .{ .bound_lifetimes = .{} };
                }
            },
            else => {},
        }

        if (parser.type_of_object(state, kind)) |task| return task;

        state.stage = .done;

        const path = expression.opens_a_path(kind) or kind == .less;

        if (path) {
            if (!parser.opens_a_bare_function()) {
                state.checkpoint = parser.anchor();
                state.stage = .pathed;

                return .{ .type_path = .{ .checkpoint = state.checkpoint } };
            }
        }

        return parser.type_of_other(kind);
    }

    fn type_of_object(parser: *Parser, state: *const TypeOf, kind: Kind) ?Task {
        assert(state.stage == .node);
        assert(kind.is_token());

        const bounded = switch (kind) {
            .apostrophe, .for_keyword => true,
            .paren_open => bounded: {
                const end = parser.balanced_end(parser.significant(parser.position));

                break :bounded parser.kind_at(parser.significant_scan(end)) == .plus;
            },
            else => false,
        };

        if (!bounded) return null;

        if (kind == .paren_open) {
            if (state.plusless) return null;
        }

        parser.open(.type_trait_object);

        return .{ .type_bounds = .{ .plusless = state.plusless } };
    }

    fn bare_function_bound(parser: *Parser) bool {
        assert(parser.at(.for_keyword));

        const opener = parser.significant(parser.significant(parser.position) + 1);
        if (parser.kind_at(opener) != .less) return true;

        const end = parser.balanced_generic(opener);
        return parser.bare_function_at(parser.significant_scan(end));
    }

    fn type_of_other(parser: *Parser, kind: Kind) ?Task {
        assert(kind.is_token());
        assert(parser.position <= parser.count());

        switch (kind) {
            .bang => parser.wrap(.type_never),
            .underscore => parser.wrap(.type_infer),
            .bracket_open => return .{ .type_bracketed = .{} },
            .paren_open => return .{ .type_tuple = .{} },
            else => {
                if (parser.opens_a_bare_function()) {
                    return .{ .bare_function = .{ .checkpoint = parser.anchor() } };
                }

                const path = expression.opens_a_path(kind) or kind == .less;
                if (path) return .{ .type_path = .{} };
            },
        }

        return null;
    }

    fn bare_function_resume(parser: *Parser, state: *BareFunction) Resumed {
        assert(parser.task_count > 0);
        assert(state.checkpoint.index <= parser.events.count());
        assert(state.before <= parser.position);
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .start => {
                parser.events.start_at(state.checkpoint, .type_bare_fn);
                _ = parser.eat(.unsafe_keyword);

                parser.abi();
                _ = parser.expect(.fn_keyword, .unexpected_token);

                if (!parser.eat(.paren_open)) continue :stage .result;

                continue :stage .next;
            },
            .next => {
                if (parser.list_closed(&state.iteration, .paren_close)) continue :stage .closed;

                state.before = parser.position;
                state.stage = .argument;

                return parser.call(.{ .bare_argument = .{} });
            },
            .argument => {
                if (parser.list_continued(state.before)) continue :stage .next;

                continue :stage .closed;
            },
            .closed => {
                _ = parser.eat(.paren_close);

                continue :stage .result;
            },
            .result => {
                state.stage = .finished;

                if (parser.eat(.r_arrow)) return parser.call(.{ .type_of = .{ .plusless = true } });

                continue :stage .finished;
            },
            .finished => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn bare_argument_resume(parser: *Parser, state: *BareArgument) Resumed {
        assert(parser.task_count > 0);
        assert(parser.position <= parser.count());

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();
                state.stage = .attributes;

                return parser.call(.{ .attributes = .{} });
            },
            .attributes => {
                const held = parser.peek();
                const named = is_name(held) or held == .underscore;
                const names = named and parser.ahead(1) == .colon;

                const variadic = if (names)
                    parser.ahead(2) == .dot_dot_dot
                else
                    held == .dot_dot_dot;

                const kind: Kind = if (variadic) .bare_variadic else .bare_fn_arg;

                parser.events.start_at(state.checkpoint.?, kind);

                if (names) {
                    parser.wrap(.ident);
                    parser.bump();
                }

                if (!variadic) {
                    state.stage = .typed;

                    return parser.call(.{ .type_of = .{} });
                }

                parser.bump();
            },
            .typed => {},
        }

        parser.events.finish();

        return .returned;
    }

    fn type_bracketed_resume(parser: *Parser, state: *TypeBracketed) Resumed {
        assert(parser.task_count > 0);
        assert(parser.position <= parser.count());

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();

                parser.bump();
                state.stage = .element;

                return parser.call(.{ .type_of = .{} });
            },
            .element => {
                if (parser.eat(.semicolon)) {
                    state.stage = .length;

                    return parser.call(.{ .expression = .{ .structures = true } });
                }

                _ = parser.eat(.bracket_close);

                parser.enclose(state.checkpoint.?, .type_slice);
            },
            .length => {
                _ = parser.eat(.bracket_close);

                parser.enclose(state.checkpoint.?, .type_array);
            },
        }

        return .returned;
    }

    fn type_tuple_resume(parser: *Parser, state: *TypeTuple) Resumed {
        assert(parser.task_count > 0);
        assert(state.before <= parser.position);
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();

                parser.bump();

                continue :stage .next;
            },
            .next => {
                if (parser.list_closed(&state.iteration, .paren_close)) continue :stage .closed;

                state.before = parser.position;
                state.stage = .element;

                return parser.call(.{ .type_of = .{} });
            },
            .element => {
                state.elements += 1;

                if (!parser.eat(.comma)) continue :stage .closed;

                state.commas += 1;

                if (parser.position == state.before) parser.emit();

                continue :stage .next;
            },
            .closed => {
                _ = parser.eat(.paren_close);

                const single = state.elements == 1 and state.commas == 0;
                const kind: Kind = if (single) .type_paren else .type_tuple;

                parser.enclose(state.checkpoint.?, kind);

                return .returned;
            },
        }
    }

    fn type_path_resume(parser: *Parser, state: *TypePath) Resumed {
        assert(parser.task_count > 0);
        assert(parser.position <= parser.count());

        switch (state.stage) {
            .start => {
                if (state.checkpoint == null) state.checkpoint = parser.anchor();

                state.stage = .path;

                if (parser.at(.less)) return parser.call(.{ .qualified_path = .{} });

                if (parser.opens_a_macro_call()) {
                    state.held = parser.anchor();
                    state.stage = .invocation;

                    return parser.call(.{ .path = .{ .expression = true } });
                }

                return parser.call(.{ .path = .{ .expression = false } });
            },
            .path => parser.enclose(state.checkpoint.?, .type_path),
            .invocation => {
                _ = parser.eat(.bang);

                parser.skip_group();
                parser.enclose(state.held.?, .macro);
                parser.enclose(state.checkpoint.?, .type_macro);
            },
        }

        return .returned;
    }

    fn qualified_path_resume(parser: *Parser, state: *QualifiedPath) Resumed {
        assert(parser.task_count > 0);
        assert(parser.position <= parser.count());

        switch (state.stage) {
            .start => {
                parser.bump();
                state.stage = .typed;

                return parser.call(.{ .type_of = .{} });
            },
            .typed => {
                if (parser.eat(.as_keyword)) {
                    parser.open(.path);
                    _ = parser.eat(.colon_colon);
                    state.stage = .segments;

                    return parser.call(.{ .path_segments = .{
                        .expression = state.expression,
                        .closing = true,
                        .typed = true,
                    } });
                }

                _ = parser.eat(.greater);
                state.stage = .done;

                if (!parser.at(.colon_colon)) {
                    parser.record_expected(.unexpected_token, .colon_colon);
                }

                return parser.call(.{ .path = .{ .expression = state.expression } });
            },
            .segments => parser.events.finish(),
            .done => {},
        }

        return .returned;
    }

    fn path_resume(parser: *Parser, state: *Path) Resumed {
        assert(parser.task_count > 0);
        assert(parser.position <= parser.count());

        switch (state.stage) {
            .start => {
                parser.open(.path);
                _ = parser.eat(.colon_colon);
                state.stage = .segments;

                return parser.call(.{ .path_segments = .{ .expression = state.expression } });
            },
            .segments => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn path_segments_resume(parser: *Parser, state: *PathSegments) Resumed {
        assert(parser.task_count > 0);
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .next => {
                if (state.iteration == parser.steps()) return .returned;

                state.iteration += 1;

                parser.skip_trivia();

                const kind = parser.current() orelse return .returned;

                if (!is_segment(kind)) {
                    if (state.separated) parser.record(.expected_identifier);

                    return .returned;
                }

                parser.open(.path_segment);
                parser.wrap(.ident);
                state.stage = .segment;

                if (parser.segment_arguments(state)) |task| return parser.call(task);

                continue :stage .segment;
            },
            .segment => {
                parser.events.finish();

                const closed = state.closing and parser.at(.greater);

                if (closed) {
                    state.closing = false;
                    state.typed = false;

                    parser.bump();

                    if (!parser.eat(.colon_colon)) return .returned;

                    continue :stage .next;
                }

                if (!parser.at(.colon_colon)) return .returned;
                if (parser.ahead(1) == .less) return .returned;

                parser.bump();
                state.separated = true;

                continue :stage .next;
            },
        }
    }

    fn segment_arguments(parser: *Parser, state: *const PathSegments) ?Task {
        assert(state.stage == .segment);
        assert(parser.position <= parser.count());

        switch (parser.peek()) {
            .less => {
                const generic = !state.expression or state.typed;
                if (generic) return .{ .generic_arguments = .{} };
            },
            .paren_open => {
                if (!state.expression) return .{ .parenthesized_arguments = .{} };
            },
            .colon_colon => {
                if (parser.ahead(1) == .less) {
                    parser.bump();

                    return .{ .generic_arguments = .{} };
                }

                if (parser.ahead(1) == .paren_open) {
                    if (!state.expression) {
                        parser.bump();

                        return .{ .parenthesized_arguments = .{} };
                    }
                }
            },
            else => {},
        }

        return null;
    }

    fn parenthesized_arguments_resume(
        parser: *Parser,
        state: *ParenthesizedArguments,
    ) Resumed {
        assert(parser.task_count > 0);
        assert(state.before <= parser.position);
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .start => {
                if (!parser.eat(.paren_open)) return .returned;

                continue :stage .next;
            },
            .next => {
                if (parser.list_closed(&state.iteration, .paren_close)) continue :stage .closed;

                state.before = parser.position;
                state.stage = .argument;

                if (parser.at(.dot_dot)) {
                    if (parser.peek_ahead(1) == .paren_close) {
                        parser.bump();

                        continue :stage .closed;
                    }
                }

                return parser.call(.{ .type_of = .{} });
            },
            .argument => {
                if (parser.list_continued(state.before)) continue :stage .next;

                continue :stage .closed;
            },
            .closed => {
                _ = parser.eat(.paren_close);
                state.stage = .done;

                if (parser.eat(.r_arrow)) return parser.call(.{ .type_of = .{ .plusless = true } });
                return .returned;
            },
            .done => return .returned,
        }
    }

    fn generic_arguments_resume(parser: *Parser, state: *GenericArguments) Resumed {
        assert(parser.task_count > 0);
        assert(state.before <= parser.position);
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .start => {
                if (!parser.eat(.less)) return .returned;

                continue :stage .next;
            },
            .next => {
                if (parser.list_closed(&state.iteration, .greater)) continue :stage .closed;

                state.before = parser.position;
                state.stage = .argument;

                return parser.call(.{ .generic_argument = .{} });
            },
            .argument => {
                if (parser.list_continued(state.before)) continue :stage .next;

                continue :stage .closed;
            },
            .closed => {
                if (parser.eat(.greater)) return .returned;
                if (parser.at(.greater_equal)) return .returned;
                if (parser.at(.greater_greater_equal)) return .returned;

                parser.record_expected(.unexpected_token, .greater);

                return .returned;
            },
        }
    }

    fn generic_argument_resume(parser: *Parser, state: *GenericArgument) Resumed {
        assert(parser.task_count > 0);
        assert(parser.position <= parser.count());

        switch (state.stage) {
            .start => return parser.generic_argument_open(state),
            .arguments => return parser.generic_argument_bind(state),
            .constraint => parser.enclose(state.checkpoint.?, .constraint),
            .assoc_const => parser.enclose(state.checkpoint.?, .assoc_const),
            .assoc_type => parser.enclose(state.checkpoint.?, .assoc_type),
            .done => {},
        }

        return .returned;
    }

    fn generic_argument_bind(parser: *Parser, state: *GenericArgument) Resumed {
        assert(state.stage == .arguments);
        assert(state.checkpoint != null);

        parser.bump();

        if (!state.associated) {
            state.stage = .constraint;

            return parser.call(.{ .type_bounds = .{} });
        }

        if (parser.constant_ahead()) {
            state.stage = .assoc_const;

            if (parser.constant_argument_task()) |task| return parser.call(task);

            parser.enclose(state.checkpoint.?, .assoc_const);

            return .returned;
        }

        state.stage = .assoc_type;
        const type_absent = parser.at(.comma) or parser.at(.greater);

        if (type_absent) parser.record(.expected_type);

        return parser.call(.{ .type_of = .{} });
    }

    fn generic_argument_open(parser: *Parser, state: *GenericArgument) Resumed {
        assert(state.stage == .start);
        assert(parser.position <= parser.count());

        if (parser.at(.apostrophe)) {
            if (parser.peek_ahead(2) != .plus) {
                parser.lifetime();

                return .returned;
            }

            state.stage = .done;

            return parser.call(.{ .type_of = .{} });
        }

        const behind = parser.binding_after();
        const binds = behind == .equal or behind == .colon;

        state.stage = .done;

        if (is_name(parser.peek())) {
            if (binds) {
                state.checkpoint = parser.anchor();
                state.associated = behind == .equal;

                parser.identifier();
                state.stage = .arguments;

                if (parser.at(.colon_colon)) parser.bump();
                if (parser.at(.less)) return parser.call(.{ .generic_arguments = .{} });
                if (parser.at(.paren_open)) return parser.call(.{ .parenthesized_arguments = .{} });
                return parser.generic_argument_bind(state);
            }
        }

        if (parser.constant_ahead()) {
            if (parser.constant_argument_task()) |task| return parser.call(task);
            return .returned;
        }

        return parser.call(.{ .type_of = .{} });
    }

    fn binding_after(parser: *Parser) ?Kind {
        assert(parser.position <= parser.count());

        var position = parser.ahead_position(1);

        if (parser.kind_at(position) == .colon_colon) {
            position = parser.significant(position + 1);
        }

        const kind = parser.kind_at(position) orelse return null;

        position = switch (kind) {
            .less => parser.balanced_generic(position),
            .paren_open => parser.balanced_end(position),
            else => return kind,
        };

        return parser.kind_at(parser.significant(position));
    }

    fn pattern_resume(parser: *Parser, state: *Pattern) Resumed {
        assert(parser.task_count > 0);
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .start => {
                if (!parser.descend()) {
                    parser.emit();

                    return .returned;
                }

                state.checkpoint = parser.anchor();
                state.leading = parser.eat(.@"or");
                state.stage = .single;

                return parser.call(.{ .pattern_single = .{} });
            },
            .single => {
                if (parser.at(.@"or")) continue :stage .alternative;
                if (state.leading) continue :stage .closed;

                continue :stage .finished;
            },
            .alternative => {
                if (state.iteration == parser.steps()) continue :stage .closed;

                state.iteration += 1;

                if (!parser.eat(.@"or")) continue :stage .closed;

                state.stage = .alternative;

                return parser.call(.{ .pattern_single = .{} });
            },
            .closed => {
                parser.enclose(state.checkpoint.?, .pat_or);

                continue :stage .finished;
            },
            .finished => {
                assert(parser.nesting > 0);

                parser.ascend();

                return .returned;
            },
        }
    }

    fn pattern_single_resume(parser: *Parser, state: *PatternSingle) Resumed {
        assert(parser.task_count > 0);
        assert(state.references <= parser.steps());

        switch (state.stage) {
            .start => {
                state.stage = .closed;

                if (parser.pattern_single_open(state)) |task| return parser.call(task);
            },
            .closed => {},
        }

        for (0..state.references) |_| {
            parser.events.finish();
        }

        return .returned;
    }

    fn pattern_single_open(parser: *Parser, state: *PatternSingle) ?Task {
        assert(state.references == 0);
        assert(state.stage == .closed);

        for (0..parser.steps()) |_| {
            if (parser.boxed()) {
                parser.bump();

                continue;
            }

            if (!parser.at(.ampersand)) break;

            parser.open(.pat_reference);
            parser.bump();
            _ = parser.eat(.mut_keyword);
            state.references += 1;
        }

        const kind = parser.current() orelse return null;

        if (kind == .const_keyword) {
            if (parser.peek_ahead(1) == .brace_open) {
                return .{ .pattern_const = .{ .checkpoint = parser.anchor() } };
            }
        }

        if (parser.word("builtin")) {
            if (parser.peek_ahead(1) == .pound) {
                parser.bump();
                parser.bump();

                return .{ .pattern_path = .{} };
            }
        }

        switch (kind) {
            .underscore => parser.wrap(.pat_wild),
            .dot_dot, .dot_dot_equal => return parser.pattern_rest(),
            .bracket_open => return .{ .pattern_slice = .{} },
            .paren_open => return .{ .pattern_tuple = .{ .checkpoint = null } },
            .mut_keyword, .ref_keyword => return .{ .pattern_binding = .{} },
            else => {
                const literal = expression.is_literal(kind) or kind == .minus;

                if (literal) {
                    const checkpoint = parser.anchor();

                    parser.literal_expression();

                    return .{ .pattern_range = .{ .checkpoint = checkpoint } };
                }

                const path = expression.opens_a_path(kind) or kind == .less;
                if (path) return .{ .pattern_path = .{} };

                parser.record(.unexpected_token);
            },
        }

        return null;
    }

    fn boxed(parser: *Parser) bool {
        assert(parser.position <= parser.count());

        if (!parser.word("box")) return false;

        return switch (parser.peek_ahead(1)) {
            .ampersand,
            .bracket_open,
            .identifier,
            .mut_keyword,
            .paren_open,
            .ref_keyword,
            .underscore,
            => true,
            else => false,
        };
    }

    fn pattern_rest(parser: *Parser) ?Task {
        assert(parser.position <= parser.count());

        const checkpoint = parser.anchor();

        assert(checkpoint.index <= parser.events.count());
        const behind = parser.peek_ahead(1);

        const bounded = expression.is_literal(behind) or expression.opens_a_path(behind) or
            behind == .minus or behind == .const_keyword;

        if (parser.at(.dot_dot)) {
            if (!bounded) {
                parser.wrap(.pat_rest);

                return null;
            }
        }

        return .{ .pattern_range = .{ .checkpoint = checkpoint } };
    }

    fn pattern_const_resume(parser: *Parser, state: *PatternConst) Resumed {
        assert(parser.task_count > 0);
        assert(state.checkpoint.index <= parser.events.count());

        switch (state.stage) {
            .start => {
                state.stage = .block;

                return parser.call(.{ .block_expression = .{ .checkpoint = state.checkpoint } });
            },
            .block => {
                state.stage = .done;

                return parser.call(.{ .pattern_range = .{ .checkpoint = state.checkpoint } });
            },
            .done => return .returned,
        }
    }

    fn pattern_range_resume(parser: *Parser, state: *PatternRange) Resumed {
        assert(parser.task_count > 0);
        assert(state.checkpoint.index <= parser.events.count());

        switch (state.stage) {
            .start => {
                const ranged = parser.at(.dot_dot) or parser.at(.dot_dot_equal) or
                    parser.at(.dot_dot_dot);

                if (!ranged) return .returned;

                parser.bump();

                const kind = parser.current() orelse {
                    parser.enclose(state.checkpoint, .expr_range);

                    return .returned;
                };

                const literal = expression.is_literal(kind) or kind == .minus;

                if (literal) parser.literal_expression();

                if (expression.opens_a_path(kind)) {
                    state.held = parser.anchor();
                    state.stage = .path;

                    return parser.call(.{ .path = .{ .expression = true } });
                }

                const const_block = kind == .const_keyword and parser.peek_ahead(1) == .brace_open;

                if (const_block) {
                    state.stage = .constant;

                    return parser.call(.{ .block_expression = .{ .checkpoint = parser.anchor() } });
                }
            },
            .path => parser.enclose(state.held.?, .expr_path),
            .constant => {},
        }

        parser.enclose(state.checkpoint, .expr_range);

        return .returned;
    }

    fn pattern_binding_resume(parser: *Parser, state: *PatternBinding) Resumed {
        assert(parser.task_count > 0);
        assert(parser.position <= parser.count());

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();
                _ = parser.eat(.ref_keyword);
                _ = parser.eat(.mut_keyword);

                if (state.doubled) {
                    parser.open(.ident);
                    parser.identifier();
                    parser.events.finish();
                } else {
                    parser.identifier();
                }

                state.stage = .bound;

                if (parser.eat(.at)) return parser.call(.{ .pattern_single = .{} });
            },
            .bound => {},
        }

        parser.enclose(state.checkpoint.?, .pat_ident);

        return .returned;
    }

    fn pattern_slice_resume(parser: *Parser, state: *PatternSlice) Resumed {
        assert(parser.task_count > 0);
        assert(state.before <= parser.position);
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .start => {
                parser.open(.pat_slice);
                parser.bump();

                continue :stage .next;
            },
            .next => {
                if (parser.list_closed(&state.iteration, .bracket_close)) continue :stage .closed;

                state.before = parser.position;
                state.stage = .element;

                return parser.call(.{ .pattern = .{} });
            },
            .element => {
                if (parser.list_continued(state.before)) continue :stage .next;

                continue :stage .closed;
            },
            .closed => {
                _ = parser.eat(.bracket_close);

                parser.events.finish();

                return .returned;
            },
        }
    }

    fn pattern_tuple_resume(parser: *Parser, state: *PatternTuple) Resumed {
        assert(parser.task_count > 0);
        if (state.checkpoint) |held| assert(held.index <= parser.events.count());
        assert(state.before <= parser.position);
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .start => {
                state.held = state.checkpoint orelse parser.anchor();

                parser.bump();

                continue :stage .next;
            },
            .next => {
                if (parser.list_closed(&state.iteration, .paren_close)) continue :stage .closed;

                state.before = parser.position;
                state.stage = .element;
                state.rested = parser.at(.dot_dot) and parser.peek_ahead(1) == .paren_close;

                return parser.call(.{ .pattern = .{} });
            },
            .element => {
                state.elements += 1;

                if (!parser.eat(.comma)) continue :stage .closed;

                state.commas += 1;

                if (parser.position == state.before) parser.emit();

                continue :stage .next;
            },
            .closed => {
                _ = parser.eat(.paren_close);

                const single = state.elements == 1 and state.commas == 0 and !state.rested;
                const tuple: Kind = if (single) .pat_paren else .pat_tuple;
                const kind: Kind = if (state.checkpoint == null) tuple else .pat_tuple_struct;

                parser.enclose(state.held.?, kind);

                return .returned;
            },
        }
    }

    fn pattern_path_resume(parser: *Parser, state: *PatternPath) Resumed {
        assert(parser.task_count > 0);
        assert(parser.position <= parser.count());

        switch (state.stage) {
            .start => return parser.pattern_path_open(state),
            .qualified => parser.enclose(state.checkpoint.?, .expr_path),
            .invocation => {
                _ = parser.eat(.bang);

                parser.skip_group();
                parser.enclose(state.held.?, .macro);
                parser.enclose(state.checkpoint.?, .expr_macro);
            },
            .path => {
                state.stage = .done;

                if (parser.at(.paren_open)) {
                    return parser.call(.{ .pattern_tuple = .{ .checkpoint = state.checkpoint } });
                }

                if (parser.at(.brace_open)) {
                    return parser.call(.{
                        .pattern_struct = .{ .checkpoint = state.checkpoint.? },
                    });
                }

                parser.enclose(state.checkpoint.?, .expr_path);

                return parser.call(.{ .pattern_range = .{ .checkpoint = state.checkpoint.? } });
            },
            .done => {},
        }

        return .returned;
    }

    fn pattern_path_open(parser: *Parser, state: *PatternPath) Resumed {
        assert(state.stage == .start);
        assert(parser.position <= parser.count());

        state.checkpoint = parser.anchor();

        if (is_name(parser.peek())) {
            const bound = switch (parser.peek_ahead(1)) {
                .bang,
                .brace_open,
                .colon_colon,
                .dot_dot,
                .dot_dot_equal,
                .paren_open,
                => false,
                else => true,
            };

            if (bound) {
                state.stage = .done;

                return parser.call(.{ .pattern_binding = .{} });
            }
        }

        if (parser.at(.less)) {
            state.stage = .qualified;

            return parser.call(.{ .qualified_path = .{ .expression = true } });
        }

        state.stage = .path;

        if (parser.opens_a_macro_call()) {
            state.held = parser.anchor();
            state.stage = .invocation;
        }

        return parser.call(.{ .path = .{ .expression = true } });
    }

    fn pattern_struct_resume(parser: *Parser, state: *PatternStruct) Resumed {
        assert(parser.task_count > 0);
        assert(state.checkpoint.index <= parser.events.count());
        assert(state.before <= parser.position);
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .start => {
                parser.bump();

                continue :stage .next;
            },
            .next => {
                if (parser.list_closed(&state.iteration, .brace_close)) continue :stage .closed;

                state.before = parser.position;
                state.stage = .element;

                if (!parser.at(.dot_dot)) return parser.call(.{ .field_pattern = .{} });

                parser.wrap(.pat_rest);

                continue :stage .element;
            },
            .element => {
                if (parser.list_continued(state.before)) continue :stage .next;

                continue :stage .closed;
            },
            .closed => {
                _ = parser.eat(.brace_close);

                parser.enclose(state.checkpoint, .pat_struct);

                return .returned;
            },
        }
    }

    fn field_pattern_resume(parser: *Parser, state: *FieldPattern) Resumed {
        assert(parser.task_count > 0);
        assert(parser.position <= parser.count());

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();
                state.stage = .attributes;

                return parser.call(.{ .attributes = .{} });
            },
            .attributes => {
                if (parser.at(.dot_dot)) {
                    parser.bump();
                    parser.enclose(state.checkpoint.?, .pat_rest);

                    return .returned;
                }

                state.stage = .done;

                if (parser.ahead(1) == .colon) {
                    if (parser.at(.number)) parser.wrap(.index) else parser.identifier();

                    parser.bump();

                    return parser.call(.{ .pattern = .{} });
                }

                if (parser.boxed()) return parser.call(.{ .pattern = .{} });
                return parser.call(.{ .pattern_binding = .{ .doubled = true } });
            },
            .done => {
                parser.enclose(state.checkpoint.?, .field_pat);

                return .returned;
            },
        }
    }

    fn block_resume(parser: *Parser, state: *Block) Resumed {
        assert(parser.task_count > 0);
        assert(state.before <= parser.position);
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .start => {
                if (!parser.descend()) {
                    parser.emit();

                    return .returned;
                }

                parser.open(.block);
                _ = parser.expect(.brace_open, .unexpected_token);
                state.stage = .next;

                return parser.call(.{ .attributes = .{ .inner = true } });
            },
            .next => {
                if (parser.list_closed(&state.iteration, .brace_close)) continue :stage .closed;

                state.before = parser.position;
                state.stage = .statement;

                return parser.call(.{ .statement = .{} });
            },
            .statement => {
                parser.progress_force(state.before);

                continue :stage .next;
            },
            .closed => {
                _ = parser.eat(.brace_close);

                parser.events.finish();

                assert(parser.nesting > 0);

                parser.ascend();

                return .returned;
            },
        }
    }

    fn statement_resume(parser: *Parser, state: *Statement) Resumed {
        assert(parser.task_count > 0);
        assert(parser.position <= parser.count());

        switch (state.stage) {
            .start => return parser.statement_open(state),
            .invocation => {
                state.stage = .done;

                return parser.call(macro_item_of(state.checkpoint.?, .stmt_macro));
            },
            .attributes => {
                const scoped = parser.at(.super_keyword) and parser.peek_ahead(1) == .let_keyword;

                if (scoped) parser.bump();

                if (parser.at(.let_keyword)) {
                    state.stage = .done;

                    return parser.call(.{ .local = .{ .checkpoint = state.checkpoint.? } });
                }

                if (parser.at(.brace_close)) parser.record(.expected_expression);

                state.stage = .valued;

                if (parser.opens_a_block_like()) return parser.call(.{ .block_statement = .{} });

                state.stage = .expressed;
                state.labelled = parser.at(.apostrophe);

                return parser.call(.{ .expression = .{ .structures = true } });
            },
            .valued => _ = parser.eat(.semicolon),
            .expressed => {
                const ended = parser.eat(.semicolon) or parser.at(.brace_close) or
                    parser.current() == null or state.labelled;

                if (!ended) parser.record_expected(.unexpected_token, .semicolon);
            },
            .done => {},
        }

        return .returned;
    }

    fn statement_open(parser: *Parser, state: *Statement) Resumed {
        assert(state.stage == .start);
        assert(parser.position <= parser.count());

        if (parser.eat(.semicolon)) return .returned;
        if (parser.current() == null) return .returned;

        if (parser.opens_a_statement_item()) {
            state.stage = .done;

            return parser.call(.{ .item = .{} });
        }

        state.stage = .attributes;

        if (parser.opens_a_statement_macro()) state.stage = .invocation;

        state.checkpoint = parser.anchor();

        return parser.call(.{ .attributes = .{} });
    }

    fn block_statement_resume(parser: *Parser, state: *BlockStatement) Resumed {
        assert(parser.task_count > 0);
        assert(parser.position <= parser.count());

        switch (state.stage) {
            .start => {
                state.held = parser.anchor();
                state.stage = .block;

                return parser.call(.{ .block_expression = .{ .checkpoint = state.held.? } });
            },
            .block => {
                const continued = parser.at(.dot) or parser.at(.question);

                state.stage = .done;

                if (continued) {
                    return parser.call(.{
                        .expression = .{ .structures = true, .continued = state.held },
                    });
                }
            },
            .done => {},
        }

        return .returned;
    }

    fn local_resume(parser: *Parser, state: *Local) Resumed {
        assert(parser.task_count > 0);
        assert(state.checkpoint.index <= parser.events.count());

        stage: switch (state.stage) {
            .start => {
                parser.events.start_at(state.checkpoint, .local);
                parser.bump();
                state.held = parser.anchor();
                state.stage = .pattern;

                return parser.call(.{ .pattern = .{} });
            },
            .pattern => {
                if (parser.eat(.colon)) {
                    state.stage = .typed;

                    return parser.call(.{ .type_of = .{} });
                }

                continue :stage .initializer;
            },
            .typed => {
                parser.enclose(state.held.?, .pat_type);

                continue :stage .initializer;
            },
            .initializer => {
                const assigned = parser.eat(.equal) or parser.eat_angled_equal();

                if (assigned) {
                    state.stage = .valued;

                    return parser.call(.{ .expression = .{ .structures = true } });
                }

                continue :stage .closed;
            },
            .valued => {
                if (parser.at(.else_keyword)) {
                    if (parser.braced_before()) parser.record(.unexpected_token);

                    parser.bump();
                    state.held = parser.anchor();
                    state.stage = .diverged;

                    return parser.call(.{ .block = .{} });
                }

                continue :stage .closed;
            },
            .diverged => {
                parser.enclose(state.held.?, .expr_block);

                continue :stage .closed;
            },
            .closed => {
                if (!parser.eat(.semicolon)) parser.record_expected(.unexpected_token, .semicolon);

                parser.events.finish();

                return .returned;
            },
        }
    }

    fn eat_angled_equal(parser: *Parser) bool {
        assert(parser.position <= parser.count());

        if (parser.eat(.greater_equal)) return true;
        return parser.eat(.greater_greater_equal);
    }

    fn braced_before(parser: *const Parser) bool {
        assert(parser.position <= parser.count());

        var position = parser.position;

        while (position > 0) {
            position -= 1;

            const kind = parser.raw[position];
            if (is_layout(kind)) continue;
            return kind == .brace_close;
        }

        return false;
    }

    fn block_expression_resume(parser: *Parser, state: *BlockExpression) Resumed {
        assert(parser.task_count > 0);
        assert(state.checkpoint.index <= parser.events.count());

        switch (state.stage) {
            .start => {
                state.stage = .closed;

                if (parser.block_expression_open(state)) |task| return parser.call(task);
            },
            .condition => {
                state.stage = .wrapped;

                return parser.call(.{ .block = .{} });
            },
            .pattern => {
                _ = parser.eat(.in_keyword);
                state.stage = .condition;

                return parser.call(.{ .expression = .{ .structures = false } });
            },
            .wrapped => parser.enclose(state.checkpoint, state.kind),
            .closed => {},
        }

        if (state.operand) {
            parser.push_value(state.checkpoint);
            parser.returned = .operator;
        }

        return .returned;
    }

    fn block_expression_open(parser: *Parser, state: *BlockExpression) ?Task {
        assert(state.stage == .closed);
        assert(parser.position <= parser.count());

        const kind = parser.current() orelse return null;

        state.stage = .wrapped;

        switch (kind) {
            .if_keyword => {
                state.stage = .closed;

                return .{ .if_expression = .{ .checkpoint = state.checkpoint } };
            },
            .match_keyword => {
                state.stage = .closed;

                return .{ .match_expression = .{ .checkpoint = state.checkpoint } };
            },
            .while_keyword => {
                parser.bump();
                state.kind = .expr_while;
                state.stage = .condition;

                return .{ .expression = .{ .structures = false } };
            },
            .for_keyword => {
                parser.bump();
                state.kind = .expr_for_loop;
                state.stage = .pattern;

                return .{ .pattern = .{} };
            },
            else => {},
        }

        if (parser.opens_a_generator()) {
            parser.bump();
            _ = parser.eat(.move_keyword);
            state.kind = .expr_async;

            return .{ .block = .{} };
        }

        if (parser.try_block_open(state, kind)) |task| return task;

        state.kind = block_kind_of(kind) orelse {
            state.stage = .closed;

            return null;
        };

        if (kind != .brace_open) parser.bump();

        if (kind == .async_keyword) {
            if (parser.word("gen")) parser.bump();

            _ = parser.eat(.move_keyword);
        }

        return .{ .block = .{} };
    }

    fn try_block_open(parser: *Parser, state: *BlockExpression, kind: Kind) ?Task {
        assert(state.stage == .wrapped);
        assert(parser.position <= parser.count());

        if (kind != .try_keyword) return null;
        if (!parser.word_at(parser.ahead_position(1), "bikeshed")) return null;

        parser.bump();
        parser.bump();
        state.kind = .expr_try_block;
        state.stage = .condition;

        return .{ .type_of = .{} };
    }

    fn if_expression_resume(parser: *Parser, state: *IfExpression) Resumed {
        assert(parser.task_count > 0);
        assert(state.checkpoint.index <= parser.events.count());

        switch (state.stage) {
            .start => {
                parser.bump();
                state.stage = .condition;

                return parser.call(.{ .expression = .{ .structures = false } });
            },
            .condition => {
                state.stage = .block;

                return parser.call(.{ .block = .{} });
            },
            .block => {
                if (parser.eat(.else_keyword)) return parser.if_alternative(state);
            },
            .chained => parser.ascend(),
            .alternative => parser.enclose(state.held.?, .expr_block),
        }

        parser.enclose(state.checkpoint, .expr_if);

        return .returned;
    }

    fn if_alternative(parser: *Parser, state: *IfExpression) Resumed {
        assert(state.stage == .block);
        assert(parser.position <= parser.count());

        if (parser.at(.if_keyword)) {
            if (!parser.descend()) {
                parser.enclose(state.checkpoint, .expr_if);

                return .returned;
            }

            state.held = parser.anchor();
            state.stage = .chained;

            return parser.call(.{ .if_expression = .{ .checkpoint = state.held.? } });
        }

        state.held = parser.anchor();
        state.stage = .alternative;

        return parser.call(.{ .block = .{} });
    }

    fn match_expression_resume(parser: *Parser, state: *MatchExpression) Resumed {
        assert(parser.task_count > 0);
        assert(state.checkpoint.index <= parser.events.count());
        assert(state.before <= parser.position);
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .start => {
                parser.bump();
                state.stage = .scrutinee;

                return parser.call(.{ .expression = .{ .structures = false } });
            },
            .scrutinee => {
                _ = parser.expect(.brace_open, .unexpected_token);
                state.stage = .inner;

                return parser.call(.{ .attributes = .{ .inner = true } });
            },
            .inner => continue :stage .next,
            .next => {
                if (parser.list_closed(&state.iteration, .brace_close)) continue :stage .closed;

                state.before = parser.position;
                state.stage = .arm;

                return parser.call(.{ .arm = .{} });
            },
            .arm => {
                if (parser.position == state.before) parser.emit();

                continue :stage .next;
            },
            .closed => {
                _ = parser.eat(.brace_close);

                parser.enclose(state.checkpoint, .expr_match);

                return .returned;
            },
        }
    }

    fn arm_resume(parser: *Parser, state: *Arm) Resumed {
        assert(parser.task_count > 0);
        assert(parser.position <= parser.count());

        stage: switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();
                state.stage = .attributes;

                return parser.call(.{ .attributes = .{} });
            },
            .attributes => {
                state.stage = .pattern;

                return parser.call(.{ .pattern = .{} });
            },
            .pattern => {
                if (parser.eat(.if_keyword)) {
                    state.stage = .guard;

                    return parser.call(.{ .expression = .{ .structures = true } });
                }

                continue :stage .guard;
            },
            .guard => {
                _ = parser.expect(.fat_arrow, .unexpected_token);
                state.stage = .body;

                if (parser.opens_a_block_like()) return parser.call(.{ .block_statement = .{} });
                return parser.call(.{ .expression = .{ .structures = true } });
            },
            .body => {
                _ = parser.eat(.comma);

                parser.enclose(state.checkpoint.?, .arm);

                return .returned;
            },
        }
    }

    fn expression_resume(parser: *Parser, state: *Expression) Resumed {
        assert(parser.task_count > 0);

        stage: switch (state.stage) {
            .start => {
                if (!parser.expression_open(state)) return .returned;

                continue :stage .machine;
            },
            .machine => {
                if (state.iteration == machine_step_max) continue :stage .finished;

                state.iteration += 1;
                state.before = parser.progress();

                const advance = if (state.operand)
                    parser.operand_step(state.frames_base)
                else
                    parser.operator_step(state.frames_base);

                switch (advance) {
                    .call => |task| {
                        state.stage = .resumed;

                        return parser.call(task);
                    },
                    .step => |step| parser.returned = step,
                }

                continue :stage .resumed;
            },
            .resumed => {
                if (parser.returned != .done) {
                    state.operand = parser.returned == .operand;

                    continue :stage .progressed;
                }

                if (!state.operand) continue :stage .finished;

                switch (parser.operator_step(state.frames_base)) {
                    .call => |task| {
                        state.stage = .fallback;

                        return parser.call(task);
                    },
                    .step => |step| parser.returned = step,
                }

                continue :stage .fallback;
            },
            .fallback => {
                if (parser.returned == .done) continue :stage .finished;

                state.operand = parser.returned == .operand;

                continue :stage .progressed;
            },
            .progressed => {
                if (parser.progressed(state.before)) continue :stage .machine;

                continue :stage .finished;
            },
            .finished => {
                parser.expression_close(state);

                return .returned;
            },
        }
    }

    fn expression_open(parser: *Parser, state: *Expression) bool {
        assert(state.stage == .start);
        assert(parser.frame_count <= expression.depth_max);

        const continued = state.continued != null;

        if (!parser.descend()) {
            if (!continued) parser.emit();

            return false;
        }

        state.frames_base = parser.frame_count;
        state.values_base = parser.value_count;

        const checkpoint = if (continued) state.continued else parser.anchor();
        var frame: Frame = .empty;

        frame.checkpoint = checkpoint;
        frame.content = checkpoint;
        frame.element_values = parser.value_count;
        frame.stage = @intFromBool(state.structures);
        frame.values = parser.value_count;
        frame.variant = .top;

        if (!parser.push_frame(frame)) {
            parser.ascend();

            return false;
        }

        if (continued) {
            parser.push_value(checkpoint.?);
            state.operand = false;
        }

        return true;
    }

    fn expression_close(parser: *Parser, state: *const Expression) void {
        assert(parser.frame_count > state.frames_base);
        assert(parser.nesting > 0);

        parser.reduce_above(state.frames_base + 1);
        parser.frame_count = state.frames_base;
        parser.value_count = state.values_base;

        parser.ascend();
    }

    fn operand_step(parser: *Parser, base: u32) Advance {
        assert(base < parser.frame_count);

        parser.skip_trivia();

        const kind = parser.current() orelse return .{ .step = .done };
        const group = parser.innermost_group(base);

        assert(group < parser.frame_count);

        const frame = &parser.frames[group];

        if (frame.variant == .@"struct") {
            const fresh = parser.frame_count == group + 1 and frame.stage == 0 and
                parser.value_count == frame.element_values;

            if (fresh) return .{ .call = .{ .struct_field = .{ .group = group } } };
        }

        return parser.operand_of(kind, base);
    }

    fn operand_of(parser: *Parser, kind: Kind, base: u32) Advance {
        assert(base < parser.frame_count);
        assert(kind.is_token());

        if (parser.opens_a_closure()) return .{ .call = .{ .closure = .{} } };
        if (parser.word("become")) return .{ .step = parser.jump(.expr_yield, false, base) };

        if (parser.opens_a_generator()) {
            const checkpoint = parser.anchor();

            return .{ .call = .{
                .block_expression = .{ .checkpoint = checkpoint, .operand = true },
            } };
        }

        if (parser.word("do")) {
            if (parser.word_at(parser.ahead_position(1), "yeet")) {
                return .{ .step = parser.jump_led(.expr_yield, false, base, 2) };
            }
        }

        const step: Step = switch (kind) {
            .pound => return .{ .call = .{ .attributes = .{ .step = .operand } } },
            .minus, .bang, .star => parser.unary(.expr_unary, expression.power_unary),
            .ampersand => parser.reference(),
            .dot_dot, .dot_dot_equal => parser.range_prefix(base),
            .underscore => parser.infer(),
            .let_keyword => return .{ .call = .{ .let_operand = .{} } },
            .return_keyword => parser.jump(.expr_return, false, base),
            .break_keyword => parser.jump(.expr_break, true, base),
            .continue_keyword => parser.jump(.expr_continue, true, base),
            .yield_keyword => parser.jump(.expr_yield, false, base),
            .apostrophe => return parser.labelled(),
            .paren_open => parser.open_group(.paren, parser.anchor()),
            .bracket_open => parser.open_group(.array, parser.anchor()),
            else => return parser.operand_other(kind, base),
        };

        return .{ .step = step };
    }

    fn operand_other(parser: *Parser, kind: Kind, base: u32) Advance {
        assert(base < parser.frame_count);
        assert(kind.is_token());

        if (is_block_like(kind)) {
            const checkpoint = parser.anchor();

            return .{ .call = .{
                .block_expression = .{ .checkpoint = checkpoint, .operand = true },
            } };
        }

        if (expression.is_literal(kind)) {
            const checkpoint = parser.anchor();

            parser.literal_node();
            parser.push_value(checkpoint);

            return .{ .step = .operator };
        }

        const path = expression.opens_a_path(kind) or kind == .less;
        if (path) return .{ .call = .{ .path_operand = .{ .base = base } } };
        return .{ .step = .done };
    }

    fn infer(parser: *Parser) Step {
        assert(parser.at(.underscore));

        const checkpoint = parser.anchor();

        parser.wrap(.expr_infer);
        parser.push_value(checkpoint);

        assert(parser.frame_count > 0);

        return .operator;
    }

    fn labelled(parser: *Parser) Advance {
        assert(parser.at(.apostrophe));
        assert(parser.frame_count > 0);

        const checkpoint = parser.anchor();

        parser.open(.label);
        parser.lifetime();
        _ = parser.eat(.colon);

        parser.events.finish();

        return .{ .call = .{
            .block_expression = .{ .checkpoint = checkpoint, .operand = true },
        } };
    }

    fn struct_field_resume(parser: *Parser, state: *StructField) Resumed {
        assert(parser.task_count > 0);
        assert(state.group < parser.frame_count);

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();
                state.stage = .attributes;

                return parser.call(.{ .attributes = .{} });
            },
            .attributes => {
                if (parser.at(.dot_dot)) {
                    parser.frames[state.group].stage = 2;

                    parser.bump();
                    parser.returned = .operand;

                    return .returned;
                }

                const named = parser.ahead(1) == .colon and parser.ahead(2) != .colon;
                if (!named) return parser.struct_shorthand(state);

                if (parser.at(.number)) parser.wrap(.index) else parser.wrap(.ident);

                parser.bump();

                var frame: Frame = .empty;

                frame.checkpoint = state.checkpoint;
                frame.kind = .field_value;
                frame.power = expression.power_barrier;
                frame.values = parser.value_count;
                frame.variant = .binary;
                parser.returned = if (parser.push_frame(frame)) .operand else .done;

                return .returned;
            },
            .forwarded => return .returned,
        }
    }

    fn struct_shorthand(parser: *Parser, state: *StructField) Resumed {
        assert(state.stage == .attributes);
        assert(state.group < parser.frame_count);

        const closes = switch (parser.peek_ahead(1)) {
            .brace_close, .comma => true,
            else => parser.ahead(1) == null,
        };

        const shorthand = is_name(parser.peek()) and closes;

        if (!shorthand) {
            if (!parser.at(.brace_close)) parser.record(.unexpected_token);

            const base = parser.innermost_group(state.group);

            switch (parser.operand_of(parser.peek(), base)) {
                .step => |step| parser.returned = step,
                .call => |task| {
                    state.stage = .forwarded;

                    return parser.call(task);
                },
            }

            return .returned;
        }

        const held = parser.anchor();

        parser.open(.path);
        parser.open(.path_segment);
        parser.open(.ident);
        parser.wrap(.ident);
        parser.events.finish();
        parser.events.finish();
        parser.events.finish();
        parser.enclose(held, .expr_path);
        parser.enclose(state.checkpoint.?, .field_value);
        parser.push_value(state.checkpoint.?);
        parser.returned = .operator;

        return .returned;
    }

    fn let_operand_resume(parser: *Parser, state: *LetOperand) Resumed {
        assert(parser.task_count > 0);
        assert(parser.frame_count > 0);

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();

                parser.bump();
                state.stage = .pattern;

                return parser.call(.{ .pattern = .{} });
            },
            .pattern => {
                _ = parser.eat(.equal);

                var frame: Frame = .empty;

                frame.checkpoint = state.checkpoint;
                frame.kind = .expr_let;
                frame.power = expression.power_compare_left;
                frame.values = parser.value_count;
                frame.variant = .unary;
                parser.returned = if (parser.push_frame(frame)) .operand else .done;

                return .returned;
            },
        }
    }

    fn closure_resume(parser: *Parser, state: *Closure) Resumed {
        assert(parser.task_count > 0);
        assert(state.before <= parser.position);
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();
                state.stage = .qualifiers;

                if (parser.at(.for_keyword)) return parser.call(.{ .bound_lifetimes = .{} });

                continue :stage .qualifiers;
            },
            .qualifiers => {
                if (parser.closure_barred()) continue :stage .body;

                continue :stage .next;
            },
            .next => {
                if (parser.list_closed(&state.iteration, .@"or")) continue :stage .closed;

                state.before = parser.position;
                state.held = parser.anchor();
                state.stage = .parameter;

                return parser.call(.{ .pattern_single = .{} });
            },
            .parameter => {
                if (parser.eat(.colon)) {
                    state.stage = .typed;

                    return parser.call(.{ .type_of = .{} });
                }

                continue :stage .separator;
            },
            .typed => {
                parser.enclose(state.held.?, .pat_type);

                continue :stage .separator;
            },
            .separator => {
                if (parser.list_continued(state.before)) continue :stage .next;

                continue :stage .closed;
            },
            .closed => {
                _ = parser.eat(.@"or");

                continue :stage .body;
            },
            .body => return parser.closure_body(state),
            .result => {
                state.stage = .block;

                if (!parser.at(.brace_open)) parser.record_expected(.unexpected_token, .brace_open);

                return parser.call(.{ .block_expression = .{ .checkpoint = parser.anchor() } });
            },
            .block => {
                parser.enclose(state.checkpoint.?, .expr_closure);
                parser.push_value(state.checkpoint.?);
                parser.returned = .operator;

                return .returned;
            },
        }
    }

    fn closure_barred(parser: *Parser) bool {
        assert(parser.position <= parser.count());

        _ = parser.eat(.const_keyword);
        _ = parser.eat(.static_keyword);
        _ = parser.eat(.async_keyword);
        _ = parser.eat(.move_keyword);

        if (parser.eat(.or_or)) return true;

        _ = parser.eat(.@"or");

        return false;
    }

    fn closure_body(parser: *Parser, state: *Closure) Resumed {
        assert(state.checkpoint != null);
        assert(parser.frame_count > 0);

        if (parser.eat(.r_arrow)) {
            state.stage = .result;

            return parser.call(.{ .type_of = .{} });
        }

        var frame: Frame = .empty;

        frame.checkpoint = state.checkpoint;
        frame.kind = .expr_closure;
        frame.power = expression.power_assign_right;
        frame.values = parser.value_count;
        frame.variant = .unary;
        parser.returned = if (parser.push_frame(frame)) .operand else .done;

        return .returned;
    }

    fn path_operand_resume(parser: *Parser, state: *PathOperand) Resumed {
        assert(parser.task_count > 0);
        assert(state.base < parser.frame_count);

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();
                state.stage = .path;

                if (parser.at(.less)) {
                    state.stage = .qualified;

                    return parser.call(.{ .qualified_path = .{ .expression = true } });
                }

                if (parser.opens_a_macro_call()) {
                    state.held = parser.anchor();
                    state.stage = .invocation;
                }

                return parser.call(.{ .path = .{ .expression = true } });
            },
            .qualified => parser.enclose(state.checkpoint.?, .expr_path),
            .invocation => {
                _ = parser.eat(.bang);

                parser.skip_group();
                parser.enclose(state.held.?, .macro);
                parser.enclose(state.checkpoint.?, .expr_macro);
            },
            .path => {
                if (parser.at(.brace_open)) {
                    if (parser.structures(state.base)) {
                        parser.returned = parser.open_group(.@"struct", state.checkpoint.?);

                        return .returned;
                    }
                }

                parser.enclose(state.checkpoint.?, .expr_path);
            },
        }

        parser.push_value(state.checkpoint.?);
        parser.returned = .operator;

        return .returned;
    }

    fn cast_resume(parser: *Parser, state: *Cast) Resumed {
        assert(parser.task_count > 0);
        assert(parser.frame_count > 0);

        switch (state.stage) {
            .start => {
                state.stage = .typed;

                return parser.call(.{ .type_of = .{ .plusless = true } });
            },
            .typed => {
                parser.events.finish();
                parser.returned = .operator;

                return .returned;
            },
        }
    }

    fn method_call_resume(parser: *Parser, state: *MethodCall) Resumed {
        assert(parser.task_count > 0);
        assert(state.checkpoint.index <= parser.events.count());
        assert(parser.frame_count > 0);

        switch (state.stage) {
            .start => {
                state.stage = .arguments;

                return parser.call(.{ .generic_arguments = .{} });
            },
            .arguments => {
                parser.method_open(state.checkpoint);
                parser.returned = .operand;

                return .returned;
            },
        }
    }

    fn operator_step(parser: *Parser, base: u32) Advance {
        assert(base < parser.frame_count);

        parser.skip_trivia();

        const kind = parser.current() orelse return .{ .step = .done };
        const group = parser.innermost_group(base);

        assert(group < parser.frame_count);

        const frame = parser.frames[group];

        if (frame.is_bracketed()) {
            if (kind == frame.closer) {
                parser.close_group(group);

                return .{ .step = .operator };
            }
        }

        if (kind == .comma) return .{ .step = parser.comma(group) };

        if (kind == .semicolon) {
            if (frame.variant == .array) {
                parser.reduce_above(group + 1);
                parser.frames[group].stage = 1;

                parser.bump();

                return .{ .step = .operand };
            }
        }

        const postfixed = kind == .dot or kind == .question;

        if (postfixed) parser.range_closure_reduce(group);

        const step: Step = switch (kind) {
            .dot => return parser.member_trailer(),
            .paren_open => parser.trailer(.call),
            .bracket_open => parser.trailer(.subscript),
            .question => parser.postfix(.expr_try),
            .as_keyword => return parser.cast(),
            .dot_dot, .dot_dot_equal => parser.range_infix(base),
            else => parser.operator_of(kind),
        };

        return .{ .step = step };
    }

    fn operator_of(parser: *Parser, kind: Kind) Step {
        assert(kind.is_token());
        assert(parser.frame_count > 0);

        if (parser.joined(.ampersand)) {
            return parser.binary(
                .expr_binary,
                expression.power_and_left,
                expression.power_and_right,
                2,
            );
        }

        const shift = parser.joined(.less) or parser.joined(.greater);

        if (shift) {
            return parser.binary(
                .expr_binary,
                expression.power_shift_left,
                expression.power_shift_right,
                2,
            );
        }

        const compare_left = expression.power_compare_left;
        const assign_right = expression.power_assign_right;

        switch (kind) {
            .less, .greater, .less_equal, .greater_equal => {
                return parser.binary(.expr_binary, compare_left, compare_left + 1, 1);
            },
            .less_less_equal, .greater_greater_equal => {
                return parser.binary(.expr_binary, assign_right + 1, assign_right, 1);
            },
            else => {},
        }

        const infix = expression.infix_of(kind) orelse return .done;
        return parser.binary(infix.node, infix.left, infix.right, 1);
    }

    fn unary(parser: *Parser, kind: Kind, power: u8) Step {
        assert(kind.is_node());
        assert(power > expression.power_barrier);

        var frame: Frame = .empty;

        frame.checkpoint = parser.anchor();
        frame.kind = kind;
        frame.power = power;
        frame.values = parser.value_count;
        frame.variant = .unary;

        if (!parser.push_frame(frame)) return .done;

        parser.bump();

        return .operand;
    }

    fn binary(parser: *Parser, kind: Kind, left: u8, right: u8, steps_bumped: u32) Step {
        assert(kind.is_node());
        assert(steps_bumped >= 1);
        assert(left != right);

        parser.reduce_for(left);

        if (parser.value_count == 0) {
            parser.bump();

            return .operand;
        }

        const values = parser.value_count - 1;

        if (left == expression.power_assign_left) {
            if (parser.events.outermost(parser.values[values]) == .expr_range) {
                parser.record(.unexpected_token);
            }
        }

        var frame: Frame = .empty;

        frame.checkpoint = parser.values[values];
        frame.kind = kind;
        frame.power = right;
        frame.values = values;
        frame.variant = .binary;

        if (!parser.push_frame(frame)) return .done;

        for (0..steps_bumped) |_| {
            parser.bump();
        }

        return .operand;
    }

    fn open_group(parser: *Parser, variant: Variant, checkpoint: Checkpoint) Step {
        assert(variant != .top);

        const opener = parser.current() orelse .paren_open;
        var frame: Frame = .empty;

        frame.bracket = parser.anchor();

        parser.bump();
        frame.content = parser.anchor();
        frame.checkpoint = checkpoint;

        frame.closer = switch (opener) {
            .bracket_open => .bracket_close,
            .brace_open => .brace_close,
            else => .paren_close,
        };

        frame.element_values = parser.value_count;
        frame.kind = group_kind(variant);
        frame.values = parser.value_count;
        frame.variant = variant;

        if (!parser.push_frame(frame)) return .done;
        return .operand;
    }

    fn close_group(parser: *Parser, group: u32) void {
        assert(group < parser.frame_count);

        parser.reduce_above(group + 1);

        const frame = parser.frames[group];

        assert(parser.value_count >= frame.values);

        const seen = parser.value_count - frame.values;

        parser.frame_count = group;

        const kind = group_close_kind(&frame, seen);

        parser.events.start_at(frame.checkpoint.?, kind);
        parser.bump();
        parser.events.finish();
        parser.value_count = frame.values;

        parser.push_value(frame.checkpoint.?);
    }

    fn comma(parser: *Parser, group: u32) Step {
        assert(parser.frames[group].is_group());
        assert(group < parser.frame_count);

        if (parser.frames[group].variant == .top) return .done;

        parser.reduce_above(group + 1);

        if (parser.value_count == parser.frames[group].element_values) {
            parser.record(.expected_expression);
        }

        parser.bump();

        const frame = &parser.frames[group];

        frame.elements += 1;
        parser.value_count = frame.values;
        frame.element_values = parser.value_count;

        return .operand;
    }

    fn postfix(parser: *Parser, kind: Kind) Step {
        assert(parser.at(.question));
        assert(kind.is_node());

        if (parser.value_count == 0) return .done;

        const checkpoint = parser.values[parser.value_count - 1];

        parser.events.start_at(checkpoint, kind);
        parser.bump();
        parser.events.finish();

        return .operator;
    }

    fn cast(parser: *Parser) Advance {
        assert(parser.frame_count > 0);
        assert(parser.at(.as_keyword));

        parser.reduce_for(expression.power_cast);

        if (parser.value_count == 0) return .{ .step = .done };

        const checkpoint = parser.values[parser.value_count - 1];

        parser.events.start_at(checkpoint, .expr_cast);
        parser.bump();

        return .{ .call = .{ .cast = .{} } };
    }

    fn range_infix(parser: *Parser, base: u32) Step {
        assert(parser.value_count <= expression.value_count_max);
        assert(base < parser.frame_count);

        parser.reduce_for(expression.power_range_left);

        if (parser.value_count == 0) return .done;

        const checkpoint = parser.values[parser.value_count - 1];
        const inclusive = parser.at(.dot_dot_equal);

        parser.bump();

        if (!parser.opens_a_range_end(base)) {
            if (inclusive) parser.record(.expected_expression);

            parser.enclose(checkpoint, .expr_range);
            parser.range_open_end = parser.position;

            return .operator;
        }

        var frame: Frame = .empty;

        frame.checkpoint = checkpoint;
        frame.kind = .expr_range;
        frame.power = expression.power_range_right;
        frame.values = parser.value_count - 1;
        frame.variant = .binary;

        if (!parser.push_frame(frame)) return .done;
        return .operand;
    }

    fn range_closure_reduce(parser: *Parser, group: u32) void {
        assert(group < parser.frame_count);
        assert(parser.position <= parser.count());

        if (parser.range_open_end == index_none) return;
        if (parser.range_open_end > parser.position) return;
        if (parser.significant_scan(parser.range_open_end) != parser.position) return;

        var index = parser.frame_count;

        while (index > group + 1) {
            index -= 1;

            switch (parser.frames[index].kind) {
                .expr_break, .expr_closure, .expr_return, .expr_yield => {
                    parser.reduce_above(index);

                    return;
                },
                else => {},
            }
        }
    }

    fn trailer(parser: *Parser, variant: Variant) Step {
        assert(parser.frame_count > 0);
        assert(variant == .call or variant == .subscript);

        if (parser.value_count == 0) return .done;

        const checkpoint = parser.values[parser.value_count - 1];

        parser.value_count -= 1;

        return parser.open_group(variant, checkpoint);
    }

    fn member_trailer(parser: *Parser) Advance {
        assert(parser.frame_count > 0);
        assert(parser.at(.dot));

        if (parser.value_count == 0) return .{ .step = .done };

        const checkpoint = parser.values[parser.value_count - 1];

        if (parser.ahead(1) == .await_keyword) {
            parser.events.start_at(checkpoint, .expr_await);
            parser.bump();
            parser.bump();
            parser.events.finish();

            return .{ .step = .operator };
        }

        const called = parser.ahead(2) == .paren_open or parser.ahead(2) == .colon_colon;
        const method = called and is_name(parser.peek_ahead(1));

        if (!method) {
            parser.events.start_at(checkpoint, .expr_field);
            parser.bump();

            const member = parser.peek();

            if (member_missing(member)) {
                parser.record(.expected_identifier);
            } else if (member == .number) {
                parser.wrap(.index);
            } else {
                parser.wrap(.ident);
            }

            parser.events.finish();

            return .{ .step = .operator };
        }

        parser.value_count -= 1;

        parser.bump();
        parser.wrap(.ident);

        if (parser.at(.colon_colon)) {
            parser.bump();

            return .{ .call = .{ .method_call = .{ .checkpoint = checkpoint } } };
        }

        parser.method_open(checkpoint);

        return .{ .step = .operand };
    }

    fn method_open(parser: *Parser, checkpoint: Checkpoint) void {
        assert(checkpoint.index <= parser.events.count());

        _ = parser.open_group(.call, checkpoint);

        assert(parser.frame_count > 0);

        parser.frames[parser.frame_count - 1].kind = .expr_method_call;
    }

    fn reference(parser: *Parser) Step {
        assert(parser.frame_count > 0);
        assert(parser.at(.ampersand));

        const raw = parser.word_at(parser.ahead_position(1), "raw");
        const qualified = parser.ahead(2) == .const_keyword or parser.ahead(2) == .mut_keyword;
        const raw_address = raw and qualified;
        var frame: Frame = .empty;

        frame.checkpoint = parser.anchor();
        frame.kind = .expr_reference;
        frame.power = expression.power_unary;
        frame.values = parser.value_count;
        frame.variant = .unary;

        if (raw_address) {
            frame.kind = .expr_raw_addr;

            if (!parser.push_frame(frame)) return .done;

            parser.bump();
            parser.bump();
            _ = parser.eat(.const_keyword);
            _ = parser.eat(.mut_keyword);

            return .operand;
        }

        if (!parser.push_frame(frame)) return .done;

        parser.bump();
        _ = parser.eat(.mut_keyword);

        return .operand;
    }

    fn range_prefix(parser: *Parser, base: u32) Step {
        assert(parser.value_count <= expression.value_count_max);
        assert(base < parser.frame_count);

        const checkpoint = parser.anchor();
        const inclusive = parser.at(.dot_dot_equal);

        parser.bump();

        if (!parser.opens_a_range_end(base)) {
            if (inclusive) parser.record(.expected_expression);

            parser.enclose(checkpoint, .expr_range);
            parser.push_value(checkpoint);
            parser.range_open_end = parser.position;

            return .operator;
        }

        var frame: Frame = .empty;

        frame.checkpoint = checkpoint;
        frame.kind = .expr_range;
        frame.power = expression.power_range_right;
        frame.values = parser.value_count;
        frame.variant = .unary;

        if (!parser.push_frame(frame)) return .done;
        return .operand;
    }

    fn jump(parser: *Parser, kind: Kind, labelled_jump: bool, base: u32) Step {
        assert(base < std.math.maxInt(u32));
        assert(kind.is_node());

        return parser.jump_led(kind, labelled_jump, base, 1);
    }

    fn jump_led(parser: *Parser, kind: Kind, labelled_jump: bool, base: u32, words: u32) Step {
        assert(parser.frame_count > 0);
        assert(kind.is_node());
        assert(base < parser.frame_count);
        assert(words > 0);

        const checkpoint = parser.anchor();

        for (0..words) |_| parser.bump();

        if (labelled_jump) parser.lifetime();

        const braced = kind == .expr_break and parser.at(.brace_open) and !parser.structures(base);
        const valueless = braced or !parser.opens_an_expression();

        if (valueless) {
            parser.enclose(checkpoint, kind);
            parser.push_value(checkpoint);

            return .operator;
        }

        var frame: Frame = .empty;

        frame.checkpoint = checkpoint;
        frame.kind = kind;
        frame.power = expression.power_assign_right;
        frame.values = parser.value_count;
        frame.variant = .unary;

        if (!parser.push_frame(frame)) return .done;
        return .operand;
    }

    fn literal_node(parser: *Parser) void {
        assert(parser.position <= parser.count());

        const checkpoint = parser.anchor();
        const kind = parser.current() orelse return;

        assert(kind.is_token());

        const held = parser.literal_at(kind, parser.significant(parser.position));

        parser.wrap(held);
        parser.enclose(checkpoint, .expr_lit);
    }

    fn literal_expression(parser: *Parser) void {
        assert(parser.position <= parser.count());

        const checkpoint = parser.anchor();

        if (!parser.at(.minus)) {
            parser.literal_node();

            return;
        }

        parser.bump();

        const kind = parser.current() orelse return;

        assert(kind.is_token());

        const held = parser.literal_at(kind, parser.significant(parser.position));

        parser.bump();
        parser.enclose(checkpoint, held);
        parser.enclose(checkpoint, .expr_lit);
    }

    fn literal_at(parser: *Parser, kind: Kind, position: u32) Kind {
        assert(kind.is_token());
        assert(position < std.math.maxInt(u32));

        const held = expression.literal_kind(kind) orelse .lit_int;

        assert(held.is_node());

        if (held != .lit_int) return held;
        if (position >= parser.tokens.len) return held;

        const bytes = parser.tokens[position].text(parser.source);

        if (bytes.len >= 2) {
            const radix = std.ascii.toLower(bytes[1]);
            const prefixed = bytes[0] == '0' and (radix == 'x' or radix == 'o' or radix == 'b');
            if (prefixed) return .lit_int;
        }

        if (std.mem.findScalar(u8, bytes, '.') != null) return .lit_float;
        if (exponent_of(bytes)) return .lit_float;
        return .lit_int;
    }

    fn opens_a_range_end(parser: *Parser, base: u32) bool {
        assert(parser.position <= parser.count());
        assert(base < parser.frame_count);

        if (parser.at(.brace_open)) {
            if (!parser.structures(base)) return false;
        }

        return parser.opens_an_expression();
    }

    fn opens_a_generator(parser: *Parser) bool {
        assert(parser.position <= parser.count());

        if (!parser.word("gen")) return false;

        return switch (parser.peek_ahead(1)) {
            .brace_open => true,
            .move_keyword => parser.peek_ahead(2) == .brace_open,
            else => false,
        };
    }

    fn opens_a_block_like(parser: *Parser) bool {
        assert(parser.position <= parser.count());

        if (!is_block_like(parser.peek())) return false;
        return !parser.opens_a_closure();
    }

    fn opens_a_closure(parser: *Parser) bool {
        assert(parser.position <= parser.count());

        const kind = parser.current() orelse return false;
        const next = parser.peek_ahead(1);
        const barred = next == .@"or" or next == .or_or;

        return switch (kind) {
            .move_keyword, .@"or", .or_or => true,
            .const_keyword => barred or next == .move_keyword,
            .static_keyword => barred or next == .move_keyword or next == .async_keyword,
            .async_keyword => barred or next == .move_keyword and switch (parser.peek_ahead(2)) {
                .@"or", .or_or => true,
                else => false,
            },
            .for_keyword => next == .less and switch (parser.peek_ahead(2)) {
                .apostrophe, .greater => true,
                else => false,
            },
            else => false,
        };
    }

    fn opens_an_expression(parser: *Parser) bool {
        assert(parser.position <= parser.count());

        const kind = parser.current() orelse return false;

        assert(kind.is_token());

        if (expression.is_literal(kind)) return true;
        if (expression.opens_a_path(kind)) return true;
        if (is_block_like(kind)) return true;

        return switch (kind) {
            .ampersand,
            .apostrophe,
            .bang,
            .bracket_open,
            .break_keyword,
            .continue_keyword,
            .dot_dot,
            .dot_dot_equal,
            .less,
            .minus,
            .move_keyword,
            .@"or",
            .or_or,
            .paren_open,
            .pound,
            .return_keyword,
            .star,
            .underscore,
            .yield_keyword,
            => true,
            else => false,
        };
    }

    fn structures(parser: *Parser, base: u32) bool {
        assert(base < parser.frame_count);

        const group = parser.innermost_group(base);

        assert(group >= base);
        const frame = &parser.frames[group];
        if (frame.variant != .top) return true;
        return frame.stage == 1;
    }

    fn innermost_group(parser: *Parser, base: u32) u32 {
        assert(parser.frame_count <= expression.depth_max);
        assert(base <= parser.frame_count);

        var index = parser.frame_count;

        while (index > base) {
            index -= 1;

            if (parser.frames[index].is_group()) return index;
        }

        return base;
    }

    fn reduce_top(parser: *Parser) void {
        assert(parser.frame_count > 0);

        parser.frame_count -= 1;

        const frame = parser.frames[parser.frame_count];

        assert(frame.kind.is_node());

        if (parser.value_count < frame.values + operands_owed(&frame)) {
            parser.record(.expected_expression);
        }

        parser.events.start_at(frame.checkpoint.?, frame.kind);
        parser.events.finish();
        parser.value_count = frame.values;

        parser.push_value(frame.checkpoint.?);
    }

    fn reduce_above(parser: *Parser, base: u32) void {
        assert(base <= expression.depth_max + 1);

        while (parser.frame_count > base) {
            parser.reduce_top();
        }

        assert(parser.frame_count <= base);
    }

    fn reduce_for(parser: *Parser, power_left: u8) void {
        assert(parser.frame_count <= expression.depth_max);
        assert(power_left > expression.power_barrier);

        while (parser.frame_count > 0) {
            const top = &parser.frames[parser.frame_count - 1];
            if (top.power == expression.power_barrier) break;
            if (top.power < power_left) break;

            parser.reduce_top();
        }
    }

    fn push_frame(parser: *Parser, frame: Frame) bool {
        assert(frame.kind.is_node());
        assert(parser.frame_count <= expression.depth_max);

        if (parser.frame_count >= expression.depth_max) {
            parser.outcome = .too_deep;

            return false;
        }

        parser.frames[parser.frame_count] = frame;
        parser.frame_count += 1;

        return true;
    }

    fn push_value(parser: *Parser, checkpoint: Checkpoint) void {
        assert(parser.value_count <= expression.value_count_max);

        if (parser.value_count >= expression.value_count_max) {
            parser.outcome = .too_deep;

            return;
        }

        parser.values[parser.value_count] = checkpoint;
        parser.value_count += 1;
    }

    fn progress(parser: *const Parser) Progress {
        assert(parser.frame_count <= expression.depth_max);
        assert(parser.value_count <= expression.value_count_max);

        return .{
            .frame_count = parser.frame_count,
            .position = parser.position,
            .value_count = parser.value_count,
        };
    }

    fn progressed(parser: *const Parser, before: Progress) bool {
        assert(parser.frame_count <= expression.depth_max);
        assert(parser.position >= before.position);

        if (parser.position != before.position) return true;
        if (parser.frame_count != before.frame_count) return true;
        return parser.value_count != before.value_count;
    }

    fn progress_force(parser: *Parser, before: u32) void {
        assert(parser.position <= parser.count());
        assert(parser.position >= before);

        if (parser.position != before) return;

        parser.record(.unexpected_token);
        parser.emit();
    }

    fn list_closed(parser: *Parser, iteration: *u32, closer: Kind) bool {
        assert(iteration.* <= parser.steps());
        assert(closer.is_token());

        if (iteration.* == parser.steps()) return true;

        iteration.* += 1;

        parser.skip_trivia();

        if (parser.at(closer)) return true;
        return parser.current() == null;
    }

    fn list_continued(parser: *Parser, before: u32) bool {
        assert(parser.position <= parser.count());
        assert(parser.position >= before);

        const empty = parser.position == before;

        if (!parser.eat(.comma)) return false;

        if (empty) parser.record(.unexpected_token);

        if (parser.position == before) parser.emit();

        return true;
    }

    fn descend(parser: *Parser) bool {
        if (parser.nesting >= nest_depth_max) {
            parser.outcome = .too_deep;

            return false;
        }

        parser.nesting += 1;

        assert(parser.nesting <= nest_depth_max);

        return true;
    }

    fn ascend(parser: *Parser) void {
        assert(parser.nesting <= nest_depth_max);
        assert(parser.nesting > 0);

        parser.nesting -= 1;
    }

    fn restricts_impl(parser: *Parser) bool {
        assert(parser.position <= parser.count());

        if (!parser.at(.impl_keyword)) return false;
        if (parser.peek_ahead(1) != .paren_open) return false;

        const end = parser.balanced_end(parser.ahead_position(1));
        const after = parser.significant(end);

        return switch (parser.kind_at(after) orelse return false) {
            .trait_keyword, .unsafe_keyword => true,
            else => parser.word_at(after, "auto"),
        };
    }

    fn opens_a_trait(parser: *Parser) bool {
        var position = parser.significant(parser.position);

        assert(position <= parser.count());

        for (0..trait_qualifier_max) |_| {
            const kind = parser.kind_at(position) orelse return false;
            if (kind == .trait_keyword) return true;

            const qualifier = kind == .const_keyword or kind == .unsafe_keyword or
                parser.word_at(position, "auto");

            if (!qualifier) return false;

            position = parser.significant(position + 1);

            assert(position <= parser.count());
        }

        return false;
    }

    fn opens_a_function(parser: *Parser) bool {
        var position = parser.significant(parser.position);

        assert(position <= parser.count());

        for (0..signature_qualifier_max) |_| {
            const kind = parser.kind_at(position) orelse return false;
            if (kind == .fn_keyword) return true;

            const qualifier = switch (kind) {
                .async_keyword, .const_keyword, .extern_keyword, .unsafe_keyword => true,
                else => parser.word_at(position, "default") or parser.word_at(position, "safe") or
                    parser.word_at(position, "gen"),
            };

            if (!qualifier) return false;

            position = parser.significant(position + 1);

            assert(position <= parser.count());

            if (parser.kind_at(position) == .string_literal) {
                position = parser.significant(position + 1);
            }
        }

        return false;
    }

    fn opens_a_foreign_module(parser: *Parser, from: u32) bool {
        assert(from < std.math.maxInt(u32));

        var position = parser.significant(from);

        assert(position >= from);

        if (parser.kind_at(position) == .unsafe_keyword) {
            position = parser.significant(position + 1);

            assert(position > from);
        }

        if (parser.kind_at(position) != .extern_keyword) return false;

        position = parser.significant(position + 1);

        if (parser.kind_at(position) == .string_literal) {
            position = parser.significant(position + 1);
        }

        return parser.kind_at(position) == .brace_open;
    }

    fn opens_a_macro_call(parser: *Parser) bool {
        assert(parser.significant_next >= parser.position);
        assert(parser.position <= parser.count());

        if (!expression.opens_a_path(parser.peek())) return false;
        return parser.macro_bang(parser.significant(parser.position)) != null;
    }

    fn macro_bang(parser: *Parser, from: u32) ?u32 {
        assert(from < std.math.maxInt(u32));

        var position = from;

        assert(position <= parser.count());

        for (0..parser.steps()) |_| {
            const kind = parser.kind_at(position) orelse return null;
            if (kind == .bang) return position;

            const segment = is_segment(kind) or kind == .colon_colon;
            if (!segment) return null;

            position = parser.significant(position + 1);

            assert(position > from);
        }

        return null;
    }

    fn trait_ahead(parser: *Parser) bool {
        var position = parser.significant(parser.position);
        var depth: u32 = 0;

        assert(position <= parser.count());

        for (0..scan_step_max) |_| {
            assert(position <= parser.count());

            const kind = parser.kind_at(position) orelse return false;

            if (kind == .less) depth += 1;
            if (kind == .greater) depth -|= 1;

            if (depth == 0) {
                if (kind == .brace_open) return false;
                if (kind == .where_keyword) return false;
            }

            if (is_opener(kind)) {
                position = parser.balanced_end(position);

                continue;
            }

            if (depth == 0) {
                if (kind == .for_keyword) return true;
            }

            if (is_closer(kind)) return false;

            position += 1;
        }

        return false;
    }

    fn receiver_ahead(parser: *Parser) bool {
        assert(parser.significant_next >= parser.position);

        var position = parser.significant(parser.position);

        assert(position <= parser.count());

        if (parser.kind_at(position) == .ampersand) {
            position = parser.significant(position + 1);

            if (parser.kind_at(position) == .apostrophe) {
                position = parser.significant(position + 2);
            }
        }

        if (parser.kind_at(position) == .mut_keyword) {
            position = parser.significant(position + 1);
        }

        if (parser.kind_at(position) != .self_lower) return false;
        return parser.kind_at(parser.significant(position + 1)) != .colon_colon;
    }

    fn constant_ahead(parser: *Parser) bool {
        const kind = parser.peek();

        assert(kind.is_token());

        assert(parser.position <= parser.count());

        if (expression.is_literal(kind)) return true;
        if (kind == .brace_open) return true;
        if (kind == .minus) return true;
        if (kind != .const_keyword) return false;
        return parser.ahead(1) == .brace_open;
    }

    fn attribute_end(parser: *Parser) u32 {
        var position = parser.significant(parser.position);

        assert(position <= parser.count());

        for (0..parser.steps()) |_| {
            if (parser.kind_at(position) != .pound) break;

            var after = parser.significant(position + 1);

            assert(after > position);

            if (parser.kind_at(after) == .bang) after = parser.significant(after + 1);

            if (parser.kind_at(after) != .bracket_open) break;

            position = parser.significant(parser.balanced_end(after));
        }

        return position;
    }

    fn opens_a_statement_item(parser: *Parser) bool {
        const position = parser.attribute_end();

        assert(position <= parser.count());

        const kind = parser.kind_at(position) orelse return false;
        const next = parser.kind_at(parser.significant(position + 1)) orelse .error_token;

        assert(next.is_token());

        switch (kind) {
            .enum_keyword,
            .impl_keyword,
            .mod_keyword,
            .pub_keyword,
            .struct_keyword,
            .trait_keyword,
            .type_keyword,
            .use_keyword,
            .macro_keyword,
            => return true,
            .static_keyword => {
                const closure = switch (next) {
                    .async_keyword, .move_keyword, .@"or", .or_or => true,
                    else => false,
                };

                if (!closure) return true;
            },
            .unsafe_keyword => {
                if (next == .impl_keyword) return true;
                if (next == .trait_keyword) return true;
            },
            .const_keyword => {
                const named = next == .identifier or next == .underscore;

                if (named) {
                    const after = parser.kind_at(parser.significant(position + 2));
                    if (after == .colon) return true;
                }
            },
            .union_keyword => {
                if (is_name(next)) return true;
            },
            else => {},
        }

        return parser.opens_a_statement_other(position, kind, next);
    }

    fn opens_a_statement_other(parser: *Parser, position: u32, kind: Kind, next: Kind) bool {
        assert(position < parser.count());
        assert(kind.is_token());

        if (parser.names_a_macro(position)) return true;
        assert(next.is_token());

        if (kind == .extern_keyword) {
            if (next == .crate_keyword) return true;
        }

        if (parser.opens_a_foreign_module(position)) return true;
        return parser.function_at(position);
    }

    fn names_a_macro(parser: *Parser, from: u32) bool {
        assert(from <= parser.count());

        const held = parser.kind_at(from) orelse .error_token;
        if (!expression.opens_a_path(held)) return false;

        const bang = parser.macro_bang(from) orelse return false;

        assert(bang >= from);
        const name = parser.kind_at(parser.significant(bang + 1)) orelse .error_token;

        return is_name(name);
    }

    fn function_at(parser: *Parser, from: u32) bool {
        assert(from < std.math.maxInt(u32));

        var position = from;

        assert(position <= parser.count());

        for (0..signature_qualifier_max) |_| {
            const kind = parser.kind_at(position) orelse return false;
            if (kind == .fn_keyword) return true;

            switch (kind) {
                .async_keyword, .const_keyword, .extern_keyword, .unsafe_keyword => {},
                else => return false,
            }

            const next = parser.kind_at(parser.significant(position + 1));

            if (kind != .extern_keyword) {
                if (next == .brace_open) return false;
            }

            position = parser.significant(position + 1);

            assert(position <= parser.count());

            if (parser.kind_at(position) == .string_literal) {
                position = parser.significant(position + 1);
            }
        }

        return false;
    }

    fn restricts_visibility(parser: *Parser) bool {
        assert(parser.at(.pub_keyword));

        if (parser.ahead(1) != .paren_open) return false;

        const inner = parser.ahead(2);
        if (inner == .in_keyword) return true;

        const scoped = inner == .crate_keyword or inner == .self_lower or inner == .super_keyword;
        if (!scoped) return false;

        const close = parser.significant(parser.ahead_position(2) + 1);
        return parser.kind_at(close) == .paren_close;
    }

    fn opens_a_statement_macro(parser: *Parser) bool {
        var position = parser.attribute_end();

        assert(position <= parser.count());

        const held = parser.kind_at(position) orelse .error_token;
        if (!expression.opens_a_path(held)) return false;

        position = parser.macro_bang(position) orelse return false;

        assert(position < parser.count());
        position = parser.significant(position + 1);

        if (is_name(parser.kind_at(position) orelse .error_token)) {
            position = parser.significant(position + 1);
        }

        const kind = parser.kind_at(position) orelse .error_token;
        if (!is_opener(kind)) return false;

        const after = parser.significant(parser.balanced_end(position));
        const follower = parser.kind_at(after) orelse .error_token;
        if (kind == .brace_open) return follower != .dot and follower != .question;
        return follower == .semicolon;
    }

    fn opens_a_bare_function(parser: *Parser) bool {
        assert(parser.position <= parser.count());

        return parser.bare_function_at(parser.significant(parser.position));
    }

    fn bare_function_at(parser: *Parser, from: u32) bool {
        assert(from < std.math.maxInt(u32));

        var position = from;

        assert(position <= parser.count());

        for (0..bare_qualifier_max) |_| {
            const kind = parser.kind_at(position) orelse return false;
            if (kind == .fn_keyword) return true;

            const qualifier = kind == .extern_keyword or kind == .unsafe_keyword;
            if (!qualifier) return false;

            position = parser.significant(position + 1);

            assert(position <= parser.count());

            if (parser.kind_at(position) == .string_literal) {
                position = parser.significant(position + 1);
            }
        }

        return false;
    }

    fn identifier(parser: *Parser) void {
        assert(parser.position <= parser.count());

        const kind = parser.current() orelse return;

        assert(kind.is_token());

        if (!is_segment(kind)) return;

        parser.wrap(.ident);
    }

    fn identifier_or_underscore(parser: *Parser) void {
        assert(parser.significant_next >= parser.position);
        assert(parser.position <= parser.count());

        if (parser.at(.underscore)) {
            parser.wrap(.ident);

            return;
        }

        parser.identifier();
    }

    fn lifetime(parser: *Parser) void {
        assert(parser.position <= parser.count());
        assert(parser.significant_next >= parser.position);

        parser.lifetime_of(false);
    }

    fn lifetime_of(parser: *Parser, doubled: bool) void {
        assert(parser.position <= parser.count());

        if (!parser.at(.apostrophe)) return;

        assert(parser.significant_next < parser.count());

        if (doubled) parser.open(.lifetime);

        parser.open(.lifetime);
        parser.bump();

        if (doubled) parser.open(.ident);

        parser.wrap(.ident);

        if (doubled) parser.events.finish();

        parser.events.finish();

        if (doubled) parser.events.finish();
    }

    fn self_path(parser: *Parser) void {
        assert(parser.current() != null);
        assert(parser.position <= parser.count());

        parser.open(.path);
        parser.open(.path_segment);
        parser.wrap(.ident);
        parser.events.finish();
        parser.events.finish();
    }

    fn abi(parser: *Parser) void {
        assert(parser.position <= parser.count());

        if (!parser.at(.extern_keyword)) return;

        assert(parser.significant_next < parser.count());

        parser.open(.abi);
        parser.bump();

        if (parser.at(.string_literal)) parser.wrap(.lit_str);

        parser.events.finish();
    }

    fn bound_opened(parser: *Parser) void {
        assert(parser.position <= parser.count());

        const polar = parser.at(.question);

        parser.bound_modifiers();

        if (polar) {
            if (parser.at(.for_keyword)) parser.record(.unexpected_token);
        }
    }

    fn bound_modifiers(parser: *Parser) void {
        assert(parser.position <= parser.count());

        _ = parser.eat(.question);

        parser.bound_qualifiers();
    }

    fn bound_qualifiers(parser: *Parser) void {
        assert(parser.position <= parser.count());

        parser.constness_bound();
        _ = parser.eat(.async_keyword);
    }

    fn constness_bound(parser: *Parser) void {
        assert(parser.position <= parser.count());

        if (parser.eat(.const_keyword)) return;
        if (!parser.at(.bracket_open)) return;
        if (parser.ahead(1) != .const_keyword) return;

        assert(parser.ahead_position(1) < parser.count());

        parser.bump();
        parser.bump();
        _ = parser.eat(.bracket_close);
    }

    fn precise_capture(parser: *Parser) void {
        assert(parser.at(.use_keyword));

        parser.open(.precise_capture);
        parser.bump();
        _ = parser.eat(.less);

        var iteration: u32 = 0;

        for (0..parser.steps()) |_| {
            if (parser.list_closed(&iteration, .greater)) break;

            const before = parser.position;

            if (parser.at(.apostrophe)) parser.lifetime() else parser.identifier();

            if (!parser.list_continued(before)) break;
        }

        assert(iteration <= parser.steps());

        _ = parser.eat(.greater);

        parser.events.finish();
    }

    fn balanced_end(parser: *Parser, from: u32) u32 {
        assert(from <= parser.count());

        var position = from;
        var depth: u32 = 0;

        for (0..scan_step_max) |_| {
            const kind = parser.kind_at(position) orelse return position;

            if (is_opener(kind)) depth += 1;

            if (is_closer(kind)) {
                if (depth == 0) return position;

                depth -= 1;

                if (depth == 0) {
                    assert(position + 1 <= parser.tokens.len);

                    return position + 1;
                }
            }

            position += 1;
        }

        assert(position >= from);

        return position;
    }

    fn balanced_generic(parser: *Parser, from: u32) u32 {
        assert(from < std.math.maxInt(u32));

        var position = from;
        var depth: u32 = 0;

        assert(parser.kind_at(from) == .less);

        for (0..scan_step_max) |_| {
            const kind = parser.kind_at(position) orelse return position;

            if (kind == .less) depth += 1;

            if (kind == .greater) {
                if (depth == 0) return position;

                depth -= 1;

                if (depth == 0) {
                    assert(position + 1 <= parser.tokens.len);

                    return position + 1;
                }
            }

            if (is_opener(kind)) {
                position = parser.balanced_end(position);

                continue;
            }

            position += 1;
        }

        assert(position >= from);

        return position;
    }

    fn skip_group(parser: *Parser) void {
        const kind = parser.current() orelse return;
        if (!is_opener(kind)) return;

        const end = parser.balanced_end(parser.significant(parser.position));

        assert(end > parser.position);

        parser.drain(end);
    }

    fn drain(parser: *Parser, end: u32) void {
        assert(parser.position <= parser.count());
        assert(end < std.math.maxInt(u32));

        while (parser.position < end) {
            if (parser.position >= parser.count()) break;

            parser.emit();
        }
    }

    fn record(parser: *Parser, kind: Diagnostic.Kind) void {
        assert(!kind.is_indentation());

        parser.record_expected(kind, null);
    }

    fn record_expected(parser: *Parser, kind: Diagnostic.Kind, expected: ?Kind) void {
        assert(parser.tokens.len == parser.raw.len);
        if (expected) |held| assert(held.is_token());

        const position = @min(parser.significant(parser.position), parser.count());
        const ended = position >= parser.tokens.len;
        const end: u32 = @intCast(parser.source.len);
        const ended_span: Span = .{ .offset = end, .length = 0 };
        const span = if (ended) ended_span else parser.tokens[position].span();
        const found: ?u16 = if (ended) null else parser.raw[position].to_u16();
        const wanted: ?u16 = if (expected) |held| held.to_u16() else null;

        const pushed: Diagnostic = .{
            .expected = wanted,
            .found = found,
            .kind = kind,
            .span = span,
        };

        assert(span.length <= std.math.maxInt(u32) - span.offset);

        parser.tree.push_diagnostic(pushed) catch |err| switch (err) {
            error.Truncated => {
                if (parser.outcome == .complete) parser.outcome = .{ .truncated = .diagnostics };
            },
        };
    }

    fn enclose(parser: *Parser, checkpoint: Checkpoint, kind: Kind) void {
        assert(kind.is_node());
        assert(checkpoint.index <= parser.events.count());

        parser.events.start_at(checkpoint, kind);
        parser.events.finish();
    }

    fn wrap(parser: *Parser, kind: Kind) void {
        assert(parser.position <= parser.count());
        assert(kind.is_node());

        parser.open(kind);
        parser.emit();
        parser.events.finish();
    }

    fn expect(parser: *Parser, kind: Kind, failure: Diagnostic.Kind) bool {
        assert(!failure.is_indentation());
        assert(parser.position <= parser.count());
        assert(kind.is_token());

        if (parser.eat(kind)) return true;

        parser.record_expected(failure, kind);

        return false;
    }

    fn eat(parser: *Parser, kind: Kind) bool {
        assert(kind.is_token());

        if (!parser.at(kind)) return false;

        assert(parser.significant_next < parser.count());

        parser.bump();

        return true;
    }

    fn bump(parser: *Parser) void {
        parser.skip_trivia();
        parser.emit();
    }

    fn open(parser: *Parser, kind: Kind) void {
        assert(parser.position <= parser.count());
        assert(kind.is_node());

        parser.skip_trivia();
        parser.events.start(kind);
    }

    fn anchor(parser: *Parser) Checkpoint {
        assert(parser.position <= parser.count());

        parser.skip_trivia();

        const checkpoint = parser.events.checkpoint();

        assert(checkpoint.index <= parser.events.count());

        return checkpoint;
    }

    fn skip_trivia(parser: *Parser) void {
        assert(parser.position <= parser.count());

        for (parser.position..parser.raw.len) |_| {
            if (!is_layout(parser.raw[parser.position])) break;

            parser.emit();
        }

        assert(parser.position == parser.significant_next);
    }

    fn emit(parser: *Parser) void {
        assert(parser.position <= parser.count());

        const kind = parser.kind_at(parser.position) orelse return;

        if (is_layout(kind)) {
            parser.events.layout(parser.position);
        } else {
            parser.events.token(parser.position);
        }

        parser.position += 1;

        if (parser.position > parser.significant_next) {
            parser.significant_next = parser.significant_scan(parser.position);
        }

        assert(parser.significant_next >= parser.position);
    }

    fn word(parser: *Parser, text: []const u8) bool {
        assert(text.len > 0);
        assert(parser.position <= parser.count());

        return parser.word_at(parser.significant(parser.position), text);
    }

    fn word_at(parser: *Parser, position: u32, text: []const u8) bool {
        assert(position <= parser.count());
        assert(text.len > 0);

        if (parser.kind_at(position) != .identifier) return false;
        return std.mem.eql(u8, parser.tokens[position].text(parser.source), text);
    }

    fn joined(parser: *Parser, kind: Kind) bool {
        const position = parser.significant(parser.position);

        assert(position <= parser.count());

        assert(kind.is_token());

        if (parser.kind_at(position) != kind) return false;
        if (parser.kind_at(position + 1) != kind) return false;
        return parser.tokens[position].end() == parser.tokens[position + 1].offset;
    }

    fn at(parser: *Parser, kind: Kind) bool {
        assert(kind.is_token());
        assert(parser.significant_next >= parser.position);

        return parser.current() == kind;
    }

    fn peek(parser: *Parser) Kind {
        assert(parser.significant_next >= parser.position);

        return parser.current() orelse .error_token;
    }

    fn peek_ahead(parser: *Parser, distance: u32) Kind {
        assert(distance > 0);
        assert(distance <= lookahead_max);

        return parser.ahead(distance) orelse .error_token;
    }

    fn ahead(parser: *Parser, distance: u32) ?Kind {
        assert(distance > 0);
        assert(distance <= lookahead_max);

        return parser.kind_at(parser.ahead_position(distance));
    }

    fn ahead_position(parser: *Parser, distance: u32) u32 {
        assert(distance > 0);

        var position = parser.significant(parser.position);

        assert(distance <= lookahead_max);

        for (0..distance) |_| {
            position = parser.significant(position + 1);
        }

        return position;
    }

    fn current(parser: *Parser) ?Kind {
        assert(parser.significant_next >= parser.position);
        assert(parser.significant_next <= parser.count());

        return parser.kind_at(parser.significant(parser.position));
    }

    fn significant(parser: *Parser, from: u32) u32 {
        assert(from >= parser.position);
        assert(parser.significant_next >= parser.position);

        if (from == parser.position) return parser.significant_next;
        return parser.significant_scan(from);
    }

    fn significant_scan(parser: *Parser, from: u32) u32 {
        assert(from < std.math.maxInt(u32));

        var position = from;

        while (position < parser.raw.len) : (position += 1) {
            if (!is_layout(parser.raw[position])) break;
        }

        assert(position >= from);

        return position;
    }

    fn kind_at(parser: *Parser, position: u32) ?Kind {
        assert(parser.raw.len == parser.tokens.len);

        if (position >= parser.raw.len) return null;
        return parser.raw[position];
    }

    fn count(parser: *const Parser) u32 {
        assert(parser.raw.len <= std.math.maxInt(u32));

        return @intCast(parser.raw.len);
    }

    fn steps(parser: *const Parser) u32 {
        const returned = parser.count() + 1;

        assert(returned < std.math.maxInt(u32));

        return returned;
    }
};

const Step = enum {
    done,
    operand,
    operator,
};

const Resumed = enum {
    called,
    returned,
};

const Advance = union(enum) {
    step: Step,
    call: Task,
};

const Progress = struct {
    frame_count: u32,
    position: u32,
    value_count: u32,
};

const Task = union(enum) {
    arm: Arm,
    attributes: Attributes,
    bare_argument: BareArgument,
    bare_function: BareFunction,
    block: Block,
    block_expression: BlockExpression,
    block_statement: BlockStatement,
    bound_lifetimes: BoundLifetimes,
    cast: Cast,
    closure: Closure,
    enum_item: EnumItem,
    enum_variant: EnumVariant,
    expression: Expression,
    field: Field,
    field_pattern: FieldPattern,
    fields: Fields,
    file: File,
    foreign_mod: ForeignMod,
    function: Function,
    generic_argument: GenericArgument,
    generic_arguments: GenericArguments,
    generic_parameter: GenericParameter,
    generics: Generics,
    if_expression: IfExpression,
    impl_item: ImplItem,
    item: Item,
    items: Items,
    let_operand: LetOperand,
    local: Local,
    macro_item: MacroItem,
    match_expression: MatchExpression,
    member: Member,
    member_list: MemberList,
    method_call: MethodCall,
    mod_item: ModItem,
    parameter: Parameter,
    parameters: Parameters,
    parenthesized_arguments: ParenthesizedArguments,
    path: Path,
    path_operand: PathOperand,
    path_segments: PathSegments,
    pattern: Pattern,
    pattern_binding: PatternBinding,
    pattern_path: PatternPath,
    pattern_const: PatternConst,
    pattern_range: PatternRange,
    pattern_single: PatternSingle,
    pattern_slice: PatternSlice,
    pattern_struct: PatternStruct,
    pattern_tuple: PatternTuple,
    predicate: Predicate,
    qualified_path: QualifiedPath,
    receiver: Receiver,
    signature: Signature,
    statement: Statement,
    static_item: StaticItem,
    struct_field: StructField,
    struct_item: StructItem,
    trait_item: TraitItem,
    type_alias: TypeAlias,
    type_bounds: TypeBounds,
    type_bracketed: TypeBracketed,
    type_of: TypeOf,
    type_path: TypePath,
    type_tuple: TypeTuple,
    use_group: UseGroup,
    use_item: UseItem,
    use_tree: UseTree,
    visibility: Visibility,
    where_clause: WhereClause,
};

const Arm = struct {
    stage: enum { start, attributes, pattern, guard, body } = .start,
    checkpoint: ?Checkpoint = null,
};

const Attributes = struct {
    stage: enum { next, path, value, drain } = .next,
    inner: bool = false,
    step: ?Step = null,
    iteration: u32 = 0,
    checkpoint: ?Checkpoint = null,
    end: u32 = 0,
};

const BareArgument = struct {
    stage: enum { start, attributes, typed } = .start,
    checkpoint: ?Checkpoint = null,
};

const BareFunction = struct {
    stage: enum { start, next, argument, closed, result, finished } = .start,
    checkpoint: Checkpoint,
    iteration: u32 = 0,
    before: u32 = 0,
};

const Block = struct {
    stage: enum { start, next, statement, closed } = .start,
    iteration: u32 = 0,
    before: u32 = 0,
};

const BlockExpression = struct {
    stage: enum { start, condition, pattern, wrapped, closed } = .start,
    checkpoint: Checkpoint,
    kind: Kind = .expr_block,
    operand: bool = false,
};

const BlockStatement = struct {
    stage: enum { start, block, done } = .start,
    held: ?Checkpoint = null,
};

const BoundLifetimes = struct {
    stage: enum { start, next, parameter, closed, finished } = .start,
    end: u32 = 0,
    iteration: u32 = 0,
    before: u32 = 0,
};

const Cast = struct {
    stage: enum { start, typed } = .start,
};

const Closure = struct {
    stage: enum {
        start,
        qualifiers,
        next,
        parameter,
        typed,
        separator,
        closed,
        body,
        result,
        block,
    } = .start,
    checkpoint: ?Checkpoint = null,
    held: ?Checkpoint = null,
    iteration: u32 = 0,
    before: u32 = 0,
};

const EnumItem = struct {
    stage: enum { start, generics, where, next, variant, closed } = .start,
    checkpoint: Checkpoint,
    iteration: u32 = 0,
    before: u32 = 0,
};

const EnumVariant = struct {
    stage: enum { start, attributes, fields, value } = .start,
    checkpoint: ?Checkpoint = null,
};

const Expression = struct {
    stage: enum { start, machine, resumed, fallback, progressed, finished } = .start,
    structures: bool,
    continued: ?Checkpoint = null,
    frames_base: u32 = 0,
    values_base: u32 = 0,
    operand: bool = true,
    before: Progress = .{ .frame_count = 0, .position = 0, .value_count = 0 },
    iteration: u32 = 0,
};

const Field = struct {
    stage: enum { start, attributes, visibility, typed, valued } = .start,
    named: bool,
    checkpoint: ?Checkpoint = null,
};

const FieldPattern = struct {
    stage: enum { start, attributes, done } = .start,
    checkpoint: ?Checkpoint = null,
};

const Fields = struct {
    stage: enum { start, next, field, closed } = .start,
    kind: Kind,
    iteration: u32 = 0,
    before: u32 = 0,
};

const File = struct {
    stage: enum { start, attributes, items } = .start,
};

const ForeignMod = struct {
    stage: enum { start, members } = .start,
    checkpoint: Checkpoint,
};

const Function = struct {
    stage: enum { start, signature, body } = .start,
    checkpoint: Checkpoint,
    kind: Kind,
};

const GenericArgument = struct {
    stage: enum { start, arguments, constraint, assoc_const, assoc_type, done } = .start,
    checkpoint: ?Checkpoint = null,
    associated: bool = false,
};

const GenericArguments = struct {
    stage: enum { start, next, argument, closed } = .start,
    iteration: u32 = 0,
    before: u32 = 0,
};

const GenericParameter = struct {
    stage: enum { start, attributes, constant, bounds, closed } = .start,
    checkpoint: ?Checkpoint = null,
};

const Generics = struct {
    stage: enum { start, next, parameter, closed } = .start,
    iteration: u32 = 0,
    before: u32 = 0,
};

const IfExpression = struct {
    stage: enum { start, condition, block, chained, alternative } = .start,
    checkpoint: Checkpoint,
    held: ?Checkpoint = null,
};

const ImplItem = struct {
    stage: enum { start, generics, path, self_type, typed, where, members } = .start,
    checkpoint: Checkpoint,
};

const Item = struct {
    stage: enum { start, attributes, visibility, body } = .start,
    checkpoint: ?Checkpoint = null,
};

const Items = struct {
    stage: enum { next, item } = .next,
    closer: Kind,
    iteration: u32 = 0,
    before: u32 = 0,
};

const LetOperand = struct {
    stage: enum { start, pattern } = .start,
    checkpoint: ?Checkpoint = null,
};

const Local = struct {
    stage: enum { start, pattern, typed, initializer, valued, diverged, closed } = .start,
    checkpoint: Checkpoint,
    held: ?Checkpoint = null,
};

const MacroItem = struct {
    stage: enum { start, path } = .start,
    checkpoint: Checkpoint,
    held: ?Checkpoint = null,
    kind: Kind,
};

const MatchExpression = struct {
    stage: enum { start, scrutinee, inner, next, arm, closed } = .start,
    checkpoint: Checkpoint,
    iteration: u32 = 0,
    before: u32 = 0,
};

const Member = struct {
    stage: enum { start, attributes, visibility, body } = .start,
    checkpoint: ?Checkpoint = null,
    family: Kind,
};

const MemberList = struct {
    stage: enum { start, next, member } = .start,
    family: Kind,
    iteration: u32 = 0,
    before: u32 = 0,
};

const MethodCall = struct {
    stage: enum { start, arguments } = .start,
    checkpoint: Checkpoint,
};

const ModItem = struct {
    stage: enum { start, attributes, items } = .start,
    checkpoint: Checkpoint,
};

const Parameter = struct {
    stage: enum { start, attributes, pattern, typed, done } = .start,
    checkpoint: ?Checkpoint = null,
};

const Parameters = struct {
    stage: enum { start, next, parameter, closed } = .start,
    iteration: u32 = 0,
    before: u32 = 0,
};

const ParenthesizedArguments = struct {
    stage: enum { start, next, argument, closed, done } = .start,
    iteration: u32 = 0,
    before: u32 = 0,
};

const Path = struct {
    stage: enum { start, segments } = .start,
    expression: bool,
};

const PathOperand = struct {
    stage: enum { start, qualified, invocation, path } = .start,
    base: u32,
    checkpoint: ?Checkpoint = null,
    held: ?Checkpoint = null,
};

const PathSegments = struct {
    stage: enum { next, segment } = .next,
    expression: bool,
    closing: bool = false,
    separated: bool = false,
    typed: bool = false,
    iteration: u32 = 0,
};

const Pattern = struct {
    stage: enum { start, single, alternative, closed, finished } = .start,
    checkpoint: ?Checkpoint = null,
    iteration: u32 = 0,
    leading: bool = false,
};

const PatternBinding = struct {
    stage: enum { start, bound } = .start,
    checkpoint: ?Checkpoint = null,
    doubled: bool = false,
};

const PatternPath = struct {
    stage: enum { start, qualified, invocation, path, done } = .start,
    checkpoint: ?Checkpoint = null,
    held: ?Checkpoint = null,
};

const PatternConst = struct {
    stage: enum { start, block, done } = .start,
    checkpoint: Checkpoint,
};

const PatternRange = struct {
    stage: enum { start, path, constant } = .start,
    checkpoint: Checkpoint,
    held: ?Checkpoint = null,
};

const PatternSingle = struct {
    stage: enum { start, closed } = .start,
    references: u32 = 0,
};

const PatternSlice = struct {
    stage: enum { start, next, element, closed } = .start,
    iteration: u32 = 0,
    before: u32 = 0,
};

const PatternStruct = struct {
    stage: enum { start, next, element, closed } = .start,
    checkpoint: Checkpoint,
    iteration: u32 = 0,
    before: u32 = 0,
};

const PatternTuple = struct {
    stage: enum { start, next, element, closed } = .start,
    checkpoint: ?Checkpoint,
    held: ?Checkpoint = null,
    elements: u32 = 0,
    commas: u32 = 0,
    iteration: u32 = 0,
    before: u32 = 0,
    rested: bool = false,
};

const Predicate = struct {
    stage: enum { start, lifetimes, typed, closed } = .start,
};

const QualifiedPath = struct {
    stage: enum { start, typed, segments, done } = .start,
    expression: bool = false,
};

const Receiver = struct {
    stage: enum { start, typed } = .start,
    checkpoint: Checkpoint,
};

const Signature = struct {
    stage: enum { start, generics, parameters, result, where } = .start,
};

const Statement = struct {
    stage: enum { start, invocation, attributes, valued, expressed, done } = .start,
    checkpoint: ?Checkpoint = null,
    labelled: bool = false,
};

const StaticItem = struct {
    stage: enum { start, generics, typed, valued, bounded } = .start,
    checkpoint: Checkpoint,
    kind: Kind,
    mutable: bool,
};

const StructField = struct {
    stage: enum { start, attributes, forwarded } = .start,
    group: u32,
    checkpoint: ?Checkpoint = null,
};

const StructItem = struct {
    stage: enum { start, generics, unnamed, unnamed_where, where, named } = .start,
    checkpoint: Checkpoint,
    kind: Kind,
};

const TraitItem = struct {
    stage: enum { start, generics, alias_bounds, alias_where, bounds, where, members } = .start,
    checkpoint: Checkpoint,
};

const TypeAlias = struct {
    stage: enum { start, generics, bounds, where, typed, closed } = .start,
    checkpoint: Checkpoint,
    kind: Kind,
    bounded: bool,
};

const TypeBounds = struct {
    stage: enum { next, parenthesized, parenthesized_path, lifetimes, path, separator } = .next,
    checkpoint: ?Checkpoint = null,
    end: u32 = 0,
    iteration: u32 = 0,
    plusless: bool = false,
};

const TypeBracketed = struct {
    stage: enum { start, element, length } = .start,
    checkpoint: ?Checkpoint = null,
};

const TypeOf = struct {
    stage: enum { start, node, lifetimes, pathed, done } = .start,
    checkpoint: ?Checkpoint = null,
    plusless: bool = false,
};

const TypePath = struct {
    stage: enum { start, path, invocation } = .start,
    checkpoint: ?Checkpoint = null,
    held: ?Checkpoint = null,
};

const TypeTuple = struct {
    stage: enum { start, next, element, closed } = .start,
    checkpoint: ?Checkpoint = null,
    elements: u32 = 0,
    commas: u32 = 0,
    iteration: u32 = 0,
    before: u32 = 0,
};

const UseGroup = struct {
    stage: enum { start, next, tree, closed } = .start,
    iteration: u32 = 0,
    before: u32 = 0,
};

const UseItem = struct {
    stage: enum { start, tree } = .start,
    checkpoint: Checkpoint,
};

const UseTree = struct {
    stage: enum { start, path, group } = .start,
};

const Visibility = struct {
    stage: enum { start, path } = .start,
    end: u32 = 0,
};

const WhereClause = struct {
    stage: enum { start, next, predicate, closed } = .start,
    iteration: u32 = 0,
    before: u32 = 0,
};

const delimiter_depth_max: u32 = 1 << 10;
const index_none: u32 = std.math.maxInt(u32);
const nest_depth_max: u32 = 96;
const task_chain_max: u32 = 16;
const task_count_max: u32 = (frame_depth_max + nest_depth_max + 1) * task_chain_max;
const scan_step_max: u32 = 1 << 16;
const item_iteration_max: u32 = std.math.maxInt(u32);
const machine_step_max: u32 = std.math.maxInt(u32);
const resume_count_max: u64 = std.math.maxInt(u64);
const trait_qualifier_max: u32 = 8;
const signature_qualifier_max: u32 = 8;
const bare_qualifier_max: u32 = 4;
const lookahead_max: u32 = 2;

comptime {
    assert(task_count_max > nest_depth_max);
    assert(bare_qualifier_max < signature_qualifier_max);
    assert(@sizeOf(Task) <= 64);
}

fn fields_of(kind: Kind) Task {
    assert(kind.is_node());
    assert(kind == .fields_named or kind == .fields_unnamed);

    return .{ .fields = .{ .kind = kind } };
}

fn struct_item_of(checkpoint: Checkpoint, kind: Kind) Task {
    assert(kind == .item_struct or kind == .item_union);
    assert(checkpoint.index < std.math.maxInt(u32));

    return .{ .struct_item = .{ .checkpoint = checkpoint, .kind = kind } };
}

fn static_item_of(checkpoint: Checkpoint, kind: Kind, mutable: bool) Task {
    assert(kind.is_node());
    assert(checkpoint.index < std.math.maxInt(u32));

    return .{ .static_item = .{ .checkpoint = checkpoint, .kind = kind, .mutable = mutable } };
}

fn macro_item_of(checkpoint: Checkpoint, kind: Kind) Task {
    assert(kind.is_node());
    assert(checkpoint.index < std.math.maxInt(u32));

    return .{ .macro_item = .{ .checkpoint = checkpoint, .kind = kind } };
}

fn member_kind_of(family: Kind, kinds: [3]Kind) Kind {
    assert(family != .error_node);
    assert(family.is_node());
    assert(kinds[0].is_node());
    assert(kinds[1].is_node());
    assert(kinds[2].is_node());

    return switch (family) {
        .trait_item_fn => kinds[0],
        .impl_item_fn => kinds[1],
        else => kinds[2],
    };
}

fn group_kind(variant: Variant) Kind {
    assert(variant != .group);

    return switch (variant) {
        .array => .expr_array,
        .call => .expr_call,
        .paren => .expr_paren,
        .@"struct" => .expr_struct,
        .subscript => .expr_index,
        .binary, .group, .top, .unary => .error_node,
    };
}

fn group_close_kind(frame: *const Frame, seen: u32) Kind {
    assert(frame.kind.is_node());
    assert(frame.is_bracketed());

    if (frame.variant == .paren) {
        const single = seen == 1 and frame.elements == 0;
        if (single) return .expr_paren;
        return .expr_tuple;
    }

    if (frame.variant == .array) {
        if (frame.stage == 1) return .expr_repeat;
    }

    return frame.kind;
}

fn block_kind_of(kind: Kind) ?Kind {
    assert(kind.is_token());

    return switch (kind) {
        .async_keyword => .expr_async,
        .brace_open => .expr_block,
        .const_keyword => .expr_const,
        .loop_keyword => .expr_loop,
        .try_keyword => .expr_try_block,
        .unsafe_keyword => .expr_unsafe,
        else => null,
    };
}

fn exponent_of(bytes: []const u8) bool {
    assert(bytes.len > 0);

    for (1..bytes.len) |offset| {
        if (std.ascii.toLower(bytes[offset]) != 'e') continue;

        var after = offset + 1;

        if (after < bytes.len) {
            const signed = bytes[after] == '+' or bytes[after] == '-';

            if (signed) after += 1;
        }

        if (after < bytes.len) {
            if (std.ascii.isDigit(bytes[after])) return true;
        }
    }

    return false;
}

fn type_missing(kind: Kind) bool {
    assert(kind.is_token());

    return switch (kind) {
        .brace_close,
        .bracket_close,
        .comma,
        .equal,
        .error_token,
        .greater,
        .paren_close,
        .semicolon,
        => true,
        else => false,
    };
}

fn member_missing(kind: Kind) bool {
    assert(kind.is_token());

    return switch (kind) {
        .brace_close,
        .bracket_close,
        .comma,
        .error_token,
        .paren_close,
        .paren_open,
        .semicolon,
        => true,
        else => false,
    };
}

fn operands_owed(frame: *const Frame) u32 {
    assert(frame.kind.is_node());

    return switch (frame.variant) {
        .unary => 1,
        .binary => if (frame.kind == .field_value) 1 else 2,
        .array, .call, .group, .paren, .@"struct", .subscript, .top => 0,
    };
}

fn outer_documented(text: []const u8) bool {
    if (std.mem.startsWith(u8, text, "////")) return false;
    if (std.mem.startsWith(u8, text, "///")) return true;
    if (std.mem.startsWith(u8, text, "/***")) return false;
    if (std.mem.eql(u8, text, "/**/")) return false;
    return std.mem.startsWith(u8, text, "/**");
}

fn comment_closed(text: []const u8) bool {
    if (!std.mem.startsWith(u8, text, "/*")) return true;

    var depth: u32 = 0;
    var offset: usize = 0;

    while (offset + 1 < text.len) {
        const pair = text[offset..][0..2];

        if (std.mem.eql(u8, pair, "/*")) {
            depth += 1;
            offset += 2;

            continue;
        }

        if (std.mem.eql(u8, pair, "*/")) {
            depth -|= 1;
            offset += 2;

            if (depth == 0) return offset == text.len;

            continue;
        }

        offset += 1;
    }

    return false;
}

fn string_closed(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    const quote = std.mem.findScalar(u8, text, '"') orelse return true;
    const prefix = text[0..quote];
    if (std.mem.findScalar(u8, prefix, 'r') == null) return string_escaped_closed(text, quote);

    const hashes = std.mem.countScalar(u8, prefix, '#');
    var offset = quote + 1;

    while (offset < text.len) : (offset += 1) {
        if (text[offset] != '"') continue;

        const stop = offset + 1 + hashes;
        if (stop > text.len) return false;
        if (std.mem.countScalar(u8, text[offset + 1 .. stop], '#') == hashes) return true;
    }

    return false;
}

fn string_escaped_closed(text: []const u8, quote: usize) bool {
    assert(quote < text.len);
    assert(text[quote] == '"');

    var offset = quote + 1;

    while (offset < text.len) {
        if (text[offset] == '\\') {
            offset += 2;

            continue;
        }

        if (text[offset] == '"') return true;

        offset += 1;
    }

    return false;
}

fn is_layout(kind: Kind) bool {
    assert(kind.is_token());

    return kind == .comment or kind == .doc_comment;
}

fn is_opener(kind: Kind) bool {
    assert(kind.is_token());

    return switch (kind) {
        .brace_open, .bracket_open, .paren_open => true,
        else => false,
    };
}

fn is_closer(kind: Kind) bool {
    assert(kind.is_token());

    return switch (kind) {
        .brace_close, .bracket_close, .paren_close => true,
        else => false,
    };
}

fn is_block_like(kind: Kind) bool {
    assert(kind.is_token());

    return switch (kind) {
        .async_keyword,
        .brace_open,
        .const_keyword,
        .for_keyword,
        .if_keyword,
        .loop_keyword,
        .match_keyword,
        .try_keyword,
        .unsafe_keyword,
        .while_keyword,
        => true,
        else => false,
    };
}

fn is_name(kind: Kind) bool {
    assert(kind.is_token());

    return switch (kind) {
        .identifier, .macro_keyword, .try_keyword, .union_keyword => true,
        else => false,
    };
}

fn is_segment(kind: Kind) bool {
    assert(kind.is_token());

    if (is_name(kind)) return true;

    return switch (kind) {
        .crate_keyword, .self_lower, .self_upper, .super_keyword => true,
        else => false,
    };
}
