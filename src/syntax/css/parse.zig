const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const Checkpoint = @import("../tree.zig").Checkpoint;
const EventsType = @import("../tree.zig").EventsType;
const Kind = @import("kind.zig").Kind;
const Span = @import("../../stdx/bounded/span.zig");
const Structure = @import("../tree.zig").Structure;
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const Token = @import("../token.zig");
const Tokens = @import("../tokens.zig");
const TreeType = @import("../tree.zig").TreeType;
const expression = @import("expression.zig");
const lex = @import("lex.zig").lex;
const raw_of = @import("../raw.zig").raw_of;
const scan = @import("../../text/scan.zig");
const Events = EventsType(Kind);
const Tree = TreeType(Kind);
const combinator_node = expression.combinator_node;
const is_combinator = expression.is_combinator;
const is_loose_postfix = expression.is_loose_postfix;
const is_tight_postfix = expression.is_tight_postfix;
const is_value_operator = expression.is_value_operator;
const opens_a_selector = expression.opens_a_selector;

pub const Parser = struct {
    custom_value: bool,
    declarations: bool,
    events: *Events,
    nesting: u32,
    outcome: Structure,
    position: u32,
    raw: []const Kind,
    returned: bool,
    significant_next: u32,
    source: []const u8,
    task_count: u32,
    tasks: [task_count_max]Task,
    tokens: []const Token,
    tree: *Tree,

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

        return parser.build_with(source, tokens, raw, events, tree, false);
    }

    pub fn build_declarations(
        parser: *Parser,
        source: []const u8,
        tokens: []const Token,
        raw: []const Kind,
        events: *Events,
        tree: *Tree,
    ) Structure {
        assert(source.len <= std.math.maxInt(u32));
        assert(tokens.len == raw.len);

        return parser.build_with(source, tokens, raw, events, tree, true);
    }

    fn build_with(
        parser: *Parser,
        source: []const u8,
        tokens: []const Token,
        raw: []const Kind,
        events: *Events,
        tree: *Tree,
        declarations: bool,
    ) Structure {
        assert(source.len <= std.math.maxInt(u32));
        assert(tokens.len == raw.len);
        assert(raw.len < std.math.maxInt(u32));

        events.clear();
        tree.clear();

        parser.* = .{
            .custom_value = false,
            .declarations = declarations,
            .events = events,
            .nesting = 0,
            .outcome = .complete,
            .position = 0,
            .raw = raw,
            .returned = false,
            .significant_next = 0,
            .source = source,
            .task_count = 0,
            .tasks = undefined,
            .tokens = tokens,
            .tree = tree,
        };

        parser.significant_next = parser.significant_scan(0);

        parser.run();

        assert(parser.task_count == 0);
        assert(parser.nesting == 0);
        assert(!parser.custom_value);

        const recorded = parser.outcome;
        const buffered = events.outcome;
        const replayed = events.replay(tree);

        if (recorded != .complete) return recorded;
        if (buffered != .complete) return buffered;
        return replayed;
    }

    fn run(parser: *Parser) void {
        assert(parser.position == 0);
        assert(parser.task_count == 0);

        parser.events.start(.stylesheet);

        var iteration: u32 = 0;

        while (iteration < item_iteration_max) : (iteration += 1) {
            parser.skip_layout();

            if (parser.current() == null) break;

            const before = parser.position;

            parser.drive(parser.item_task(true));

            if (parser.position == before) {
                parser.record(.unexpected_token);
                parser.emit();
            }

            assert(parser.position > before);
            assert(parser.nesting == 0);
        }

        parser.skip_layout();
        parser.events.finish();

        assert(parser.position == parser.count());
    }

    fn drive(parser: *Parser, task: Task) void {
        assert(parser.task_count == 0);
        assert(task == .at_statement or task == .declaration or task == .rule_set);
        if (task == .at_statement) assert(task.at_statement.top);

        _ = parser.call(task);

        var resumes: u64 = 0;

        while (parser.task_count > 0) {
            resumes += 1;

            assert(resumes <= resume_count_max);

            const depth = parser.task_count;

            switch (parser.task_resume(&parser.tasks[depth - 1])) {
                .called => assert(parser.task_count == depth + 1),
                .returned => {
                    assert(parser.task_count == depth);

                    parser.task_count -= 1;
                },
            }
        }
    }

    fn call(parser: *Parser, task: Task) Resumed {
        assert(parser.task_count < task_count_max);
        assert(parser.nesting <= nest_depth_max);

        parser.tasks[parser.task_count] = task;
        parser.task_count += 1;

        return .called;
    }

    fn task_resume(parser: *Parser, task: *Task) Resumed {
        assert(parser.task_count > 0);
        assert(parser.position <= parser.count());
        assert(task == &parser.tasks[parser.task_count - 1]);

        return switch (task.*) {
            .arguments => |*state| parser.arguments_resume(state),
            .at_statement => |*state| parser.at_statement_resume(state),
            .block => |*state| parser.block_resume(state),
            .call_expression => |*state| parser.call_expression_resume(state),
            .declaration => |*state| parser.declaration_resume(state),
            .grouped_value => |*state| parser.grouped_value_resume(state),
            .keyframe_blocks => |*state| parser.keyframe_blocks_resume(state),
            .loose_suffix => |*state| parser.loose_suffix_resume(state),
            .query => |*state| parser.query_resume(state),
            .query_group => |*state| parser.query_group_resume(state),
            .query_list => |*state| parser.query_list_resume(state),
            .rule_set => |*state| parser.rule_set_resume(state),
            .selector => |*state| parser.selector_resume(state),
            .selector_arguments => |*state| parser.selector_arguments_resume(state),
            .selector_operand => |*state| parser.selector_operand_resume(state),
            .selector_tail => |*state| parser.selector_tail_resume(state),
            .value => |*state| parser.value_resume(state),
            .value_list => |*state| parser.value_list_resume(state),
        };
    }

    fn item_task(parser: *Parser, top: bool) Task {
        assert(parser.position <= parser.count());

        const kind = parser.current().?;

        if (!top) assert(kind != .brace_close);

        if (kind == .at) return .{ .at_statement = .{ .top = top } };
        if (parser.opens_a_declaration()) return .{ .declaration = .{} };
        return .{ .rule_set = .{} };
    }

    fn opens_a_declaration(parser: *Parser) bool {
        assert(parser.position <= parser.count());

        const start = parser.significant(parser.position);
        if (parser.kind_at(start) != .identifier) return false;
        if (parser.kind_at(parser.significant(parser.escaped_end(start))) != .colon) return false;

        if (parser.declarations) {
            if (parser.nesting == 0) return true;
        }

        if (parser.nesting > 0) {
            if (std.mem.startsWith(u8, parser.text_at(start), "--")) return true;
        }

        var depth: u32 = 0;

        for (0..scan_step_max) |step| {
            const kind = parser.kind_at(start +| @as(u32, @intCast(step))) orelse return true;

            if (opens_a_group(kind)) {
                depth += 1;

                continue;
            }

            if (closes_a_group(kind)) {
                depth -|= 1;

                continue;
            }

            if (depth > 0) continue;
            if (kind == .brace_open) return false;
            if (kind == .brace_close) return true;
            if (kind == .semicolon) return true;
        }

        assert(depth <= scan_step_max);

        return true;
    }

    fn rule_set_resume(parser: *Parser, state: *RuleSet) Resumed {
        if (state.stage == .selector) assert(state.before <= parser.position);
        assert(state.iteration <= parser.steps());

        switch (state.stage) {
            .start => {
                state.start = parser.significant(parser.position);

                parser.open(.rule_set);
                parser.open(.selectors);
            },
            .selector => {
                if (parser.position == state.before) return parser.rule_set_block(state);
                if (!parser.eat(.comma)) return parser.rule_set_block(state);
            },
            .block => {
                parser.events.finish();

                return .returned;
            },
        }

        if (!parser.iterate(&state.iteration)) return parser.rule_set_block(state);

        state.before = parser.position;
        state.stage = .selector;

        return parser.call(.{ .selector = .{} });
    }

    fn rule_set_block(parser: *Parser, state: *RuleSet) Resumed {
        assert(state.stage != .block);
        assert(state.iteration <= parser.steps());

        parser.events.finish();

        if (parser.at(.brace_open)) {
            state.stage = .block;

            return parser.call(.{ .block = .{} });
        }

        if (parser.rule_set_unfinished(state.start)) {
            parser.record_expected(.unexpected_token, .brace_open);
        }

        parser.events.finish();

        return .returned;
    }

    fn rule_set_unfinished(parser: *Parser, start: u32) bool {
        assert(start <= parser.count());
        assert(parser.position <= parser.count());

        if (parser.nesting == 0) return false;

        const closer = parser.current() orelse .brace_close;
        if (closer != .brace_close) return false;
        if (parser.kind_at(start) == .colon) return true;

        for (start..parser.position) |position| {
            if (parser.kind_at(@intCast(position)) == .colon) return false;
        }

        return true;
    }

    fn declaration_resume(parser: *Parser, state: *Declaration) Resumed {
        if (state.stage == .start) assert(parser.at(.identifier));
        assert(parser.task_count > 0);

        switch (state.stage) {
            .start => {
                assert(!parser.custom_value);

                parser.custom_value = std.mem.startsWith(u8, parser.text_current(), "--");

                parser.open(.declaration);
                parser.name(.property_name);
                parser.expect(.colon, .expected_colon);
                state.stage = .values;

                return parser.call(.{ .value_list = .{ .stop = .declaration } });
            },
            .values => {
                parser.custom_value = false;
                _ = parser.eat(.semicolon);

                parser.events.finish();

                return .returned;
            },
        }
    }

    fn block_resume(parser: *Parser, state: *Block) Resumed {
        switch (state.stage) {
            .start => {
                if (!parser.descend()) {
                    parser.bump();

                    return .returned;
                }

                parser.open(.block);
                parser.bump();
            },
            .item => {
                assert(parser.nesting > 0);

                if (parser.position == state.before) {
                    parser.record(.unexpected_token);
                    parser.bump();
                }
            },
        }

        while (parser.iterate(&state.iteration)) {
            assert(state.iteration <= parser.steps());

            parser.skip_layout();

            const kind = parser.current() orelse break;
            if (kind == .brace_close) break;

            state.before = parser.position;
            state.stage = .item;

            return parser.call(parser.item_task(false));
        }

        _ = parser.eat(.brace_close);

        parser.events.finish();
        parser.ascend();

        return .returned;
    }

    fn selector_resume(parser: *Parser, state: *Selector) Resumed {
        switch (state.stage) {
            .start => {
                if (!parser.descend()) {
                    parser.bump();

                    return .returned;
                }

                state.left = parser.anchor();
                state.stage = .operand;

                return parser.call(.{ .selector_operand = .{} });
            },
            .operand => {
                if (!parser.returned) {
                    parser.ascend();

                    return .returned;
                }
            },
            .suffix => assert(state.left != null),
        }

        while (parser.iterate(&state.iteration)) {
            assert(state.iteration <= parser.steps());

            const spaced = parser.separated();
            const kind = parser.current() orelse break;

            if (is_combinator(kind)) {
                parser.bump();
                state.stage = .suffix;

                return parser.call(.{
                    .selector_tail = .{ .left = state.left.?, .kind = combinator_node(kind) },
                });
            }

            if (spaced) {
                if (!opens_a_selector(kind)) break;

                state.stage = .suffix;

                return parser.call(.{
                    .selector_tail = .{ .left = state.left.?, .kind = .descendant_selector },
                });
            }

            if (is_tight_postfix(kind)) {
                parser.class_suffix(state.left.?);

                continue;
            }

            if (!is_loose_postfix(kind)) break;

            state.stage = .suffix;

            return parser.call(.{ .loose_suffix = .{ .checkpoint = state.left.?, .kind = kind } });
        }

        parser.ascend();

        return .returned;
    }

    fn selector_tail_resume(parser: *Parser, state: *SelectorTail) Resumed {
        assert(state.kind.is_node());

        switch (state.stage) {
            .start => {
                state.right = parser.anchor();
                state.stage = .operand;

                return parser.call(.{ .selector_operand = .{} });
            },
            .operand => {
                parser.tight_suffixes(state.right.?);
                parser.enclose(state.left, state.kind);

                return .returned;
            },
        }
    }

    fn selector_operand_resume(parser: *Parser, state: *SelectorOperand) Resumed {
        assert(parser.task_count > 0);

        switch (state.stage) {
            .start => {
                const kind = parser.current() orelse {
                    parser.returned = false;

                    return .returned;
                };

                if (is_combinator(kind)) {
                    state.chain = parser.anchor();
                    state.position_first = parser.position;

                    return parser.chain_advance(state);
                }

                if (parser.operand_inline(kind)) {
                    parser.returned = true;

                    return .returned;
                }

                if (!is_loose_postfix(kind)) {
                    parser.returned = false;

                    return .returned;
                }

                state.stage = .loose;

                return parser.call(.{
                    .loose_suffix = .{ .checkpoint = parser.anchor(), .kind = kind },
                });
            },
            .loose => assert(state.levels == 0),
            .chain_loose => parser.chain_close(state),
        }

        parser.returned = true;

        return .returned;
    }

    fn operand_inline(parser: *Parser, kind: Kind) bool {
        assert(kind.is_token());
        assert(!is_combinator(kind));

        switch (kind) {
            .ampersand => parser.wrap(.nesting_selector),
            .escape, .identifier => parser.name(.tag_name),
            .star => parser.wrap(.universal_selector),
            .text => parser.wrap(.string_value),
            .dot => parser.class_suffix(parser.anchor()),
            else => return false,
        }

        return true;
    }

    fn chain_advance(parser: *Parser, state: *SelectorOperand) Resumed {
        assert(state.stage == .start);
        assert(state.chain != null);

        for (0..parser.steps()) |_| {
            state.levels += 1;
            state.position_last = parser.position;

            parser.bump();
            state.right = parser.anchor();

            const kind = parser.current() orelse break;

            if (is_combinator(kind)) {
                _ = parser.anchor();

                continue;
            }

            if (parser.operand_inline(kind)) break;
            if (!is_loose_postfix(kind)) break;

            state.stage = .chain_loose;

            return parser.call(.{
                .loose_suffix = .{ .checkpoint = parser.anchor(), .kind = kind },
            });
        }

        parser.chain_close(state);
        parser.returned = true;

        return .returned;
    }

    fn chain_close(parser: *Parser, state: *SelectorOperand) void {
        assert(state.levels > 0);
        assert(state.position_first <= state.position_last);

        parser.tight_suffixes(state.right.?);

        var position = state.position_last;
        var level = state.levels;

        for (0..state.levels) |_| {
            level -= 1;

            const offset: u64 = position - state.position_first;
            const index = state.chain.?.index + offset + 2 * @as(u64, level);
            const held = @min(index, parser.events.count());
            const checkpoint: Checkpoint = .{ .index = @intCast(held) };

            parser.enclose(checkpoint, combinator_node(parser.raw[position]));

            if (level == 0) break;

            position = parser.significant_before(position);
        }

        assert(level == 0);
        assert(position == state.position_first);
    }

    fn significant_before(parser: *const Parser, position: u32) u32 {
        assert(position > 0);
        assert(position < parser.count());

        var held = position - 1;

        while (held > 0) : (held -= 1) {
            if (!is_layout(parser.raw[held])) break;
        }

        assert(is_combinator(parser.raw[held]));

        return held;
    }

    fn loose_suffix_resume(parser: *Parser, state: *LooseSuffix) Resumed {
        assert(is_loose_postfix(state.kind));

        switch (state.stage) {
            .start => return parser.loose_suffix_open(state),
            .arguments => {
                const node: Kind = if (state.kind == .colon)
                    .pseudo_class_selector
                else
                    .pseudo_element_selector;

                parser.enclose(state.checkpoint, node);
            },
            .value => {
                if (parser.at(.identifier)) {
                    if (scan.word_in(&attribute_modifiers, parser.text_current())) parser.bump();
                }

                _ = parser.eat(.bracket_close);

                parser.enclose(state.checkpoint, .attribute_selector);
            },
        }

        return .returned;
    }

    fn loose_suffix_open(parser: *Parser, state: *LooseSuffix) Resumed {
        assert(state.stage == .start);
        assert(parser.current() == state.kind);

        parser.bump();

        switch (state.kind) {
            .hash => {
                if (parser.names_an_id()) parser.name(.id_name);

                parser.enclose(state.checkpoint, .id_selector);

                return .returned;
            },
            .colon => {
                const text = parser.text_current();
                const literal = scan.word_in(&expression.selector_literals, text);
                const nth = scan.word_in(&expression.nth_literals, text);

                parser.class_name(literal);
                state.stage = .arguments;

                return parser.call(.{ .selector_arguments = .{ .nth = nth } });
            },
            .colon_colon => {
                if (parser.names_an_id()) parser.name(.tag_name);

                state.stage = .arguments;

                return parser.call(.{ .selector_arguments = .{ .nth = false } });
            },
            else => {
                parser.attribute_name();

                const operator = parser.current() orelse .error_token;

                if (is_attribute_operator(operator)) {
                    parser.bump();
                    state.stage = .value;

                    return parser.call(.{ .value = .{} });
                }

                _ = parser.eat(.bracket_close);

                parser.enclose(state.checkpoint, .attribute_selector);

                return .returned;
            },
        }
    }

    fn selector_arguments_resume(parser: *Parser, state: *SelectorArguments) Resumed {
        assert(state.iteration <= parser.steps());

        switch (state.stage) {
            .start => {
                if (parser.separated()) return .returned;
                if (!parser.at(.paren_open)) return .returned;

                if (!parser.descend()) {
                    parser.bump();

                    return .returned;
                }

                parser.open(.arguments);
                parser.bump();

                if (state.nth) parser.nth_head();
            },
            .item => {
                assert(!state.nth);

                if (parser.position == state.before) parser.bump();
            },
            .of => assert(state.nth),
        }

        if (state.nth) return parser.nth_arguments_next(state);
        return parser.selector_arguments_next(state);
    }

    fn selector_arguments_next(parser: *Parser, state: *SelectorArguments) Resumed {
        assert(!state.nth);
        assert(parser.nesting > 0);

        while (parser.iterate(&state.iteration)) {
            assert(state.iteration <= parser.steps());

            parser.skip_trivia();

            const kind = parser.current() orelse break;

            switch (kind) {
                .paren_close => break,
                .comma => {
                    parser.bump();

                    continue;
                },
                else => {},
            }

            const selects = opens_a_selector(kind) or is_combinator(kind);

            state.before = parser.position;
            state.stage = .item;

            if (selects) return parser.call(.{ .selector = .{} });
            return parser.call(.{ .value = .{} });
        }

        return parser.arguments_close();
    }

    fn nth_arguments_next(parser: *Parser, state: *SelectorArguments) Resumed {
        assert(state.nth);
        assert(parser.nesting > 0);

        while (parser.iterate(&state.iteration)) {
            assert(state.iteration <= parser.steps());

            const kind = parser.current() orelse break;
            if (kind == .paren_close) break;

            if (kind == .identifier) {
                if (std.mem.eql(u8, parser.text_current(), "of")) {
                    parser.bump();
                    state.stage = .of;

                    return parser.call(.{ .selector = .{} });
                }
            }

            parser.bump();
        }

        return parser.arguments_close();
    }

    fn arguments_close(parser: *Parser) Resumed {
        assert(parser.nesting > 0);
        assert(parser.task_count > 0);

        _ = parser.eat(.paren_close);

        parser.events.finish();
        parser.ascend();

        return .returned;
    }

    fn nth_head(parser: *Parser) void {
        assert(parser.nesting > 0);
        assert(parser.position <= parser.count());

        if (parser.at(.number)) {
            if (parser.ahead(1) == .paren_close) {
                parser.numeric(.integer_value);

                return;
            }
        }

        parser.nth_notation();
    }

    fn nth_notation(parser: *Parser) void {
        assert(parser.nesting > 0);

        const held = parser.current() orelse return;
        if (held == .paren_close) return;

        parser.open(.plain_value);

        for (0..parser.steps()) |_| {
            const kind = parser.current() orelse break;
            if (kind == .paren_close) break;

            if (kind == .identifier) {
                if (std.mem.eql(u8, parser.text_current(), "of")) break;
            }

            parser.bump();
        }

        parser.events.finish();

        assert(parser.position <= parser.count());
    }

    fn value_list_resume(parser: *Parser, state: *ValueList) Resumed {
        if (state.depth > 0) assert(parser.custom_value);

        if (state.stage == .value) {
            assert(state.before <= parser.position);

            if (parser.position == state.before) {
                if (parser.value_rejected()) parser.record(.expected_expression);

                parser.bump();
            }
        }

        while (parser.iterate(&state.iteration)) {
            assert(state.iteration <= parser.steps());

            parser.skip_trivia();

            const kind = parser.current() orelse break;

            if (parser.custom_value) {
                if (parser.custom_brace(state, kind)) continue;
                if (parser.custom_closed(state, kind)) break;
            }

            if (state.depth == 0) {
                if (state.stop.holds(kind)) break;
            }

            if (kind == .comma) {
                parser.bump();

                continue;
            }

            state.before = parser.position;
            state.stage = .value;

            return parser.call(.{ .value = .{} });
        }

        return .returned;
    }

    fn value_rejected(parser: *Parser) bool {
        assert(parser.position <= parser.count());

        if (!parser.custom_value) return true;

        const kind = parser.current() orelse return false;
        return closes_a_group(kind);
    }

    fn custom_brace(parser: *Parser, state: *ValueList, kind: Kind) bool {
        assert(parser.custom_value);
        assert(kind.is_token());

        switch (kind) {
            .brace_open => state.depth += 1,
            .brace_close => {
                if (state.depth == 0) return false;

                state.depth -= 1;
            },
            .semicolon => {
                if (state.depth == 0) return false;
            },
            else => return false,
        }

        parser.bump();

        return true;
    }

    fn custom_closed(parser: *Parser, state: *const ValueList, kind: Kind) bool {
        assert(parser.custom_value);
        assert(kind.is_token());

        if (state.depth > 0) return false;
        if (kind != .brace_close) return false;

        if (state.stop != .declaration) parser.record(.unexpected_token);

        return true;
    }

    fn value_resume(parser: *Parser, state: *Value) Resumed {
        switch (state.stage) {
            .start => {
                if (!parser.descend()) {
                    parser.bump();

                    return .returned;
                }

                state.checkpoint = parser.anchor();

                switch (parser.value_atom()) {
                    .none => {
                        parser.ascend();

                        return .returned;
                    },
                    .done => {},
                    .call => |task| {
                        state.stage = .atom;

                        return parser.call(task);
                    },
                }
            },
            .atom => assert(state.checkpoint != null),
            .operand => parser.enclose(state.checkpoint.?, .binary_expression),
        }

        while (parser.iterate(&state.iteration)) {
            assert(state.iteration <= parser.steps());

            const kind = parser.current() orelse break;
            if (!is_value_operator(kind)) break;

            parser.bump();

            switch (parser.value_atom()) {
                .none, .done => {},
                .call => |task| {
                    state.stage = .operand;

                    return parser.call(task);
                },
            }

            parser.enclose(state.checkpoint.?, .binary_expression);
        }

        parser.ascend();

        return .returned;
    }

    fn value_atom(parser: *Parser) Atom {
        assert(parser.nesting > 0);

        const kind = parser.current() orelse return .none;

        assert(kind.is_token());

        switch (kind) {
            .bang => parser.important(),
            .bracket_open => return .{ .call = .{ .grouped_value = .{ .node = .grid_value } } },
            .escape => parser.name(.plain_value),
            .float => parser.numeric(.float_value),
            .hash => parser.color_value(),
            .identifier => return parser.plain_or_call(),
            .number => parser.numeric(.integer_value),
            .paren_open => return .{
                .call = .{ .grouped_value = .{ .node = .parenthesized_value } },
            },
            .slash => {
                if (!parser.opens_a_plain_value()) return .none;
                return parser.plain_or_call();
            },
            .text => parser.wrap(.string_value),
            else => return .none,
        }

        return .done;
    }

    fn numeric(parser: *Parser, kind: Kind) void {
        assert(parser.current() != null);
        assert(kind.is_node());

        parser.open(kind);
        parser.bump();

        if (parser.kind_at(parser.position) == .unit) parser.wrap(.unit_node);

        parser.events.finish();
    }

    fn important(parser: *Parser) void {
        assert(parser.nesting > 0);
        assert(parser.at(.bang));

        parser.open(.important);
        parser.bump();

        if (parser.kind_at(parser.position) == .identifier) {
            if (std.mem.eql(u8, parser.text_at(parser.position), "important")) parser.emit();
        }

        parser.events.finish();
    }

    fn color_value(parser: *Parser) void {
        assert(parser.nesting > 0);
        assert(parser.at(.hash));

        parser.open(.color_value);
        parser.bump();

        const start: u32 = if (parser.position < parser.tokens.len)
            parser.tokens[parser.position].offset
        else
            @intCast(parser.source.len);

        if (expression.hex_end(parser.source, start)) |end| {
            parser.consume_through(end);
        } else {
            parser.bump();
        }

        parser.events.finish();
    }

    fn grouped_value_resume(parser: *Parser, state: *GroupedValue) Resumed {
        if (state.stage == .values) assert(parser.nesting > 0);
        assert(state.node == .grid_value or state.node == .parenthesized_value);

        const grid = state.node == .grid_value;

        switch (state.stage) {
            .start => {
                if (!parser.descend()) {
                    parser.bump();

                    return .returned;
                }

                parser.open(state.node);
                parser.bump();
                state.stage = .values;

                const stop: Stop = if (grid) .bracket else .paren;
                return parser.call(.{ .value_list = .{ .stop = stop } });
            },
            .values => {
                const closer: Kind = if (grid) .bracket_close else .paren_close;

                _ = parser.eat(closer);

                parser.events.finish();
                parser.ascend();

                return .returned;
            },
        }
    }

    fn opens_a_plain_value(parser: *Parser) bool {
        assert(parser.at(.slash));

        const position = parser.significant(parser.position);

        assert(position < parser.tokens.len);

        const start = parser.tokens[position].offset;
        const end = expression.plain_value_end(parser.source, start) orelse return false;

        return end > start;
    }

    fn plain_or_call(parser: *Parser) Atom {
        assert(parser.nesting > 0);

        const position = parser.significant(parser.position);

        assert(position < parser.tokens.len);

        const start = parser.tokens[position].offset;
        const plain = expression.plain_value_end(parser.source, start) orelse 0;
        const name_end = expression.identifier_end(parser.source, start) orelse 0;

        if (name_end >= plain) {
            if (name_end < parser.source.len) {
                if (parser.source[name_end] == '(') return .{ .call = .{ .call_expression = .{} } };
            }
        }

        parser.open(.plain_value);
        parser.consume_through(@max(plain, name_end));
        parser.escaped_tail();
        parser.events.finish();

        return .done;
    }

    fn call_expression_resume(parser: *Parser, state: *CallExpression) Resumed {
        assert(parser.task_count > 0);

        switch (state.stage) {
            .start => {
                assert(parser.at(.identifier));

                parser.open(.call_expression);
                parser.wrap(.function_name);
                state.stage = .arguments;

                return parser.call(.{ .arguments = .{} });
            },
            .arguments => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn arguments_resume(parser: *Parser, state: *Arguments) Resumed {
        switch (state.stage) {
            .start => {
                if (!parser.descend()) {
                    parser.bump();

                    return .returned;
                }

                parser.open(.arguments);
                parser.bump();
            },
            .value => {
                assert(parser.nesting > 0);

                if (parser.position == state.before) parser.bump();
            },
        }

        while (parser.iterate(&state.iteration)) {
            assert(state.iteration <= parser.steps());

            parser.skip_trivia();

            const kind = parser.current() orelse break;

            switch (kind) {
                .paren_close => break,
                .comma, .semicolon => {
                    parser.bump();

                    continue;
                },
                else => {},
            }

            state.before = parser.position;
            state.stage = .value;

            return parser.call(.{ .value = .{} });
        }

        return parser.arguments_close();
    }

    fn at_statement_resume(parser: *Parser, state: *AtStatement) Resumed {
        assert(parser.task_count > 0);
        if (state.stage != .start) assert(parser.nesting > 0);

        stage: switch (state.stage) {
            .start => {
                if (!parser.descend()) {
                    parser.bump();

                    return .returned;
                }

                state.form = parser.form_of(state.top);

                parser.statement_head(state.form);
                state.stage = .first;

                if (parser.statement_first(state.form)) |task| return parser.call(task);

                continue :stage .first;
            },
            .first => {
                state.stage = .second;

                if (state.form == .import) {
                    return parser.call(.{ .query_list = .{ .stop = .declaration } });
                }

                continue :stage .second;
            },
            .second => switch (state.form) {
                .at_rule, .media, .supports => {
                    if (parser.at(.brace_open)) {
                        state.stage = .tail;

                        return parser.call(.{ .block = .{} });
                    }

                    _ = parser.eat(.semicolon);
                },
                .keyframes, .keyframes_vendor => {},
                .charset, .import, .namespace, .postcss => _ = parser.eat(.semicolon),
            },
            .tail => {},
        }

        parser.events.finish();
        parser.ascend();

        return .returned;
    }

    fn form_of(parser: *Parser, top: bool) Form {
        assert(parser.at(.at));
        assert(parser.nesting > 0);

        const name_text = parser.at_name();
        if (std.mem.eql(u8, name_text, "charset")) return .charset;
        if (std.mem.eql(u8, name_text, "import")) return .import;
        if (std.mem.eql(u8, name_text, "media")) return .media;
        if (std.mem.eql(u8, name_text, "namespace")) return .namespace;
        if (std.mem.eql(u8, name_text, "supports")) return .supports;

        if (names_keyframes(name_text)) {
            if (std.mem.eql(u8, name_text, "keyframes")) return .keyframes;
            return .keyframes_vendor;
        }

        if (top) return .at_rule;
        if (parser.opens_a_postcss_statement()) return .postcss;
        return .at_rule;
    }

    fn statement_head(parser: *Parser, form: Form) void {
        assert(parser.at(.at));
        assert(form.node().is_node());

        parser.open(form.node());

        switch (form) {
            .charset, .import, .media, .supports => parser.at_mark(),
            .namespace => {
                parser.at_mark();

                if (parser.at(.identifier)) {
                    if (!parser.names_a_call()) parser.wrap(.namespace_name);
                }
            },
            .keyframes, .keyframes_vendor => {
                if (form == .keyframes) {
                    parser.at_mark();
                } else {
                    parser.skip_trivia();
                    parser.at_keyword();
                }

                const keyframes_named = parser.at(.identifier) or parser.at(.escape);

                if (keyframes_named) parser.name(.keyframes_name);
                if (parser.at(.text)) parser.keyframes_string();
            },
            .at_rule, .postcss => parser.at_keyword(),
        }
    }

    fn statement_first(parser: *Parser, form: Form) ?Task {
        assert(parser.nesting > 0);
        assert(parser.task_count > 0);

        return switch (form) {
            .charset, .namespace => .{ .value = .{} },
            .import => if (parser.at(.semicolon)) null else .{ .value = .{} },
            .media, .at_rule => .{ .query_list = .{ .stop = .query } },
            .supports => .{ .query = .{} },
            .keyframes, .keyframes_vendor => parser.keyframes_first(),
            .postcss => .{ .value_list = .{ .stop = .block } },
        };
    }

    fn keyframes_string(parser: *Parser) void {
        assert(parser.at(.text));
        assert(parser.nesting > 0);

        parser.open(.keyframes_name);
        parser.wrap(.string_value);
        parser.events.finish();
    }

    fn keyframes_first(parser: *Parser) ?Task {
        assert(parser.nesting > 0);
        assert(parser.position <= parser.count());

        if (parser.at(.brace_open)) return .{ .keyframe_blocks = .{} };
        return null;
    }

    fn at_name(parser: *Parser) []const u8 {
        assert(parser.at(.at));

        const position = parser.significant(parser.position) + 1;

        assert(position > parser.position);

        if (parser.kind_at(position) != .identifier) return "";
        return parser.text_at(position);
    }

    fn at_mark(parser: *Parser) void {
        assert(parser.nesting > 0);
        assert(parser.at(.at));

        parser.bump();
        _ = parser.eat(.identifier);
    }

    fn at_keyword(parser: *Parser) void {
        assert(parser.at(.at));
        assert(parser.position <= parser.count());

        parser.open(.at_keyword);
        parser.emit();
        _ = parser.eat(.identifier);

        parser.events.finish();
    }

    fn names_a_call(parser: *Parser) bool {
        assert(parser.at(.identifier));

        const position = parser.significant(parser.position);

        assert(position < parser.tokens.len);

        const start = parser.tokens[position].offset;
        const name_end = expression.identifier_end(parser.source, start) orelse return false;
        if (name_end >= parser.source.len) return false;
        return parser.source[name_end] == '(';
    }

    fn opens_a_postcss_statement(parser: *Parser) bool {
        assert(parser.at(.at));
        assert(parser.nesting > 0);

        var depth: u32 = 0;
        var position = parser.significant(parser.position) +| 2;
        var carried = false;

        for (0..scan_step_max) |_| {
            const kind = parser.kind_at(position) orelse break;

            position += 1;

            if (closes_a_group(kind)) {
                depth -|= 1;

                continue;
            }

            if (opens_a_group(kind)) {
                if (depth == 0) {
                    if (carried) return true;
                }

                carried = depth == 0;
                depth += 1;

                continue;
            }

            if (depth > 0) continue;
            if (is_layout(kind)) continue;
            if (kind == .brace_open) return false;
            if (kind == .brace_close) break;
            if (kind == .semicolon) break;

            if (kind == .comma) {
                carried = false;

                continue;
            }

            if (kind != .identifier) return true;

            const text = parser.text_at(position - 1);
            const joins = scan.word_in(&expression.query_joins, text);
            const linked = joins or scan.word_in(&expression.query_prefixes, text);

            if (linked) {
                carried = false;

                continue;
            }

            if (carried) return true;

            carried = true;
        }

        return false;
    }

    fn keyframe_blocks_resume(parser: *Parser, state: *KeyframeBlocks) Resumed {
        switch (state.stage) {
            .start => {
                if (!parser.descend()) {
                    parser.bump();

                    return .returned;
                }

                parser.open(.keyframe_block_list);
                parser.bump();
            },
            .block => {
                parser.events.finish();

                if (parser.position == state.before) parser.bump();
            },
        }

        while (parser.iterate(&state.iteration)) {
            assert(state.iteration <= parser.steps());

            parser.skip_layout();

            const kind = parser.current() orelse break;
            if (kind == .brace_close) break;

            state.before = parser.position;

            parser.keyframe_head();

            if (parser.at(.brace_open)) {
                state.stage = .block;

                return parser.call(.{ .block = .{} });
            }

            parser.events.finish();

            if (parser.position == state.before) parser.bump();
        }

        _ = parser.eat(.brace_close);

        parser.events.finish();
        parser.ascend();

        return .returned;
    }

    fn keyframe_head(parser: *Parser) void {
        assert(parser.nesting > 0);

        const kind = parser.current().?;

        assert(kind != .brace_close);

        parser.open(.keyframe_block);

        switch (kind) {
            .identifier => parser.keyframe_selector(),
            .number => parser.numeric(.integer_value),
            .brace_open => {},
            else => parser.bump(),
        }
    }

    fn keyframe_selector(parser: *Parser) void {
        assert(parser.at(.identifier));

        const text = parser.text_current();

        assert(text.len > 0);

        if (std.mem.eql(u8, text, "from")) {
            parser.wrap(.from);

            return;
        }

        if (std.mem.eql(u8, text, "to")) {
            parser.wrap(.to);

            return;
        }

        parser.bump();
    }

    fn query_list_resume(parser: *Parser, state: *QueryList) Resumed {
        if (state.stage == .query) {
            assert(state.before <= parser.position);

            if (parser.position == state.before) parser.bump();
        }

        while (parser.iterate(&state.iteration)) {
            assert(state.iteration <= parser.steps());

            parser.skip_trivia();

            const kind = parser.current() orelse break;
            if (state.stop.holds(kind)) break;

            if (kind == .comma) {
                parser.bump();

                continue;
            }

            state.before = parser.position;
            state.stage = .query;

            return parser.call(.{ .query = .{} });
        }

        return .returned;
    }

    fn query_resume(parser: *Parser, state: *Query) Resumed {
        switch (state.stage) {
            .start => {
                if (!parser.descend()) {
                    parser.bump();

                    return .returned;
                }

                state.checkpoint = parser.anchor();

                if (parser.query_unary_open(state)) |task| {
                    state.stage = .first;

                    return parser.call(task);
                }

                parser.query_unary_close(state);
            },
            .first => parser.query_unary_close(state),
            .joined => {
                parser.query_unary_close(state);
                parser.enclose(state.checkpoint.?, .binary_query);
            },
        }

        while (parser.iterate(&state.iteration)) {
            assert(state.iteration <= parser.steps());

            if (parser.current() != .identifier) break;
            if (!scan.word_in(&expression.query_joins, parser.text_current())) break;

            parser.bump();

            if (parser.query_unary_open(state)) |task| {
                state.stage = .joined;

                return parser.call(task);
            }

            parser.query_unary_close(state);
            parser.enclose(state.checkpoint.?, .binary_query);
        }

        parser.ascend();

        return .returned;
    }

    fn query_unary_open(parser: *Parser, state: *Query) ?Task {
        assert(parser.nesting > 0);
        assert(state.checkpoint != null);

        state.unary = null;

        if (parser.current() == .identifier) {
            if (scan.word_in(&expression.query_prefixes, parser.text_current())) {
                state.unary = parser.anchor();

                parser.bump();
            }
        }

        return parser.query_atom();
    }

    fn query_unary_close(parser: *Parser, state: *Query) void {
        assert(state.checkpoint != null);
        assert(parser.nesting > 0);

        const unary = state.unary orelse return;

        parser.enclose(unary, .unary_query);
        state.unary = null;
    }

    fn query_atom(parser: *Parser) ?Task {
        assert(parser.nesting > 0);

        const kind = parser.current() orelse return null;

        assert(kind.is_token());

        switch (kind) {
            .identifier => {
                if (std.mem.eql(u8, parser.text_current(), "selector")) {
                    if (parser.ahead(1) == .paren_open) {
                        return .{ .query_group = .{ .node = .selector_query } };
                    }
                }

                parser.wrap(.keyword_query);

                return null;
            },
            .paren_open => {
                if (parser.opens_a_feature()) {
                    return .{ .query_group = .{ .node = .feature_query } };
                }

                return .{ .query_group = .{ .node = .parenthesized_query } };
            },
            else => return null,
        }
    }

    fn opens_a_feature(parser: *Parser) bool {
        assert(parser.nesting > 0);
        assert(parser.at(.paren_open));

        if (parser.ahead(1) != .identifier) return false;
        return parser.ahead(2) == .colon;
    }

    fn query_group_resume(parser: *Parser, state: *QueryGroup) Resumed {
        assert(state.node.is_node());
        assert(parser.nesting > 0);

        switch (state.stage) {
            .start => {
                parser.open(state.node);
                parser.bump();
                state.stage = .inner;

                switch (state.node) {
                    .selector_query => {
                        parser.bump();

                        return parser.call(.{ .selector = .{} });
                    },
                    .feature_query => {
                        parser.wrap(.feature_name);
                        _ = parser.eat(.colon);

                        return parser.call(.{ .value_list = .{ .stop = .paren } });
                    },
                    else => return parser.call(.{ .query = .{} }),
                }
            },
            .inner => {
                _ = parser.eat(.paren_close);

                parser.events.finish();

                return .returned;
            },
        }
    }

    fn class_suffix(parser: *Parser, checkpoint: Checkpoint) void {
        assert(parser.at(.dot));
        assert(checkpoint.index <= parser.events.count());

        parser.bump();
        parser.class_name(false);
        parser.enclose(checkpoint, .class_selector);
    }

    fn class_name(parser: *Parser, literal: bool) void {
        assert(parser.nesting > 0);
        assert(parser.position <= parser.count());

        parser.open(.class_name);

        var escaped = false;

        for (0..parser.steps()) |seen| {
            const kind = parser.kind_at(parser.position) orelse break;
            const named_escape = escaped and parser.named(parser.position);
            const joined = kind == .escape or kind == .identifier or named_escape;
            if (!joined) break;

            if (seen > 0) {
                if (!parser.adjacent(parser.position)) break;
            }

            if (kind == .escape) escaped = true;

            const verbatim = literal or kind != .identifier;

            if (verbatim) {
                parser.emit();
            } else {
                parser.wrap(.identifier_node);
            }
        }

        parser.events.finish();
    }

    fn tight_suffixes(parser: *Parser, checkpoint: Checkpoint) void {
        assert(checkpoint.index <= parser.events.count());

        for (0..parser.steps()) |_| {
            if (parser.separated()) break;

            const kind = parser.current() orelse break;
            if (!is_tight_postfix(kind)) break;

            parser.class_suffix(checkpoint);
        }
    }

    fn attribute_name(parser: *Parser) void {
        assert(parser.nesting > 0);
        assert(parser.position <= parser.count());

        const namespaced = parser.attribute_namespaced();

        parser.open(.attribute_name);

        for (0..parser.steps()) |_| {
            const kind = parser.current() orelse break;

            switch (kind) {
                .identifier => if (namespaced) parser.wrap(.tag_name) else parser.bump(),
                .pipe => parser.bump(),
                .star => if (namespaced) parser.wrap(.universal_selector) else parser.bump(),
                else => break,
            }
        }

        parser.events.finish();
    }

    fn attribute_namespaced(parser: *Parser) bool {
        assert(parser.nesting > 0);
        assert(parser.position <= parser.count());

        var position = parser.significant(parser.position);

        for (0..parser.steps()) |_| {
            const kind = parser.kind_at(position) orelse return false;

            switch (kind) {
                .pipe => return true,
                .identifier, .star => {},
                else => return false,
            }

            position = parser.significant(position + 1);
        }

        return false;
    }

    fn names_an_id(parser: *Parser) bool {
        assert(parser.nesting > 0);

        const kind = parser.current() orelse return false;

        assert(kind.is_token());

        return switch (kind) {
            .escape, .identifier, .number, .text, .unit => true,
            else => false,
        };
    }

    fn wrap(parser: *Parser, kind: Kind) void {
        assert(parser.current() != null);
        assert(kind.is_node());

        parser.open(kind);
        parser.emit();
        parser.events.finish();
    }

    fn name(parser: *Parser, kind: Kind) void {
        assert(parser.current() != null);
        assert(kind.is_node());

        parser.open(kind);
        parser.emit();
        parser.escaped_tail();
        parser.events.finish();
    }

    fn escaped_tail(parser: *Parser) void {
        assert(parser.tokens.len == parser.raw.len);
        assert(parser.position <= parser.count());

        var escaped = false;

        if (parser.position > 0) escaped = parser.raw[parser.position - 1] == .escape;

        for (0..parser.steps()) |_| {
            const kind = parser.kind_at(parser.position) orelse break;

            if (!parser.adjacent(parser.position)) break;

            if (kind == .escape) {
                escaped = true;
            } else {
                if (!escaped) break;
                if (!parser.named(parser.position)) break;
            }

            parser.emit();
        }
    }

    fn escaped_end(parser: *const Parser, start: u32) u32 {
        assert(start < parser.count());
        assert(parser.tokens.len == parser.raw.len);

        var escaped = parser.raw[start] == .escape;
        var position = start + 1;

        for (0..parser.steps()) |_| {
            const kind = parser.kind_at(position) orelse break;

            if (!parser.adjacent(position)) break;

            if (kind == .escape) {
                escaped = true;
            } else {
                if (!escaped) break;
                if (!parser.named(position)) break;
            }

            position += 1;
        }

        assert(position > start);

        return position;
    }

    fn consume_through(parser: *Parser, end: u32) void {
        assert(parser.position <= parser.count());
        assert(end <= parser.source.len);

        parser.skip_trivia();

        const before = parser.position;

        for (0..parser.steps()) |_| {
            if (parser.position >= parser.tokens.len) break;
            if (parser.tokens[parser.position].end() > end) break;

            parser.emit();
        }

        if (parser.position == before) parser.emit();
    }

    fn enclose(parser: *Parser, checkpoint: Checkpoint, kind: Kind) void {
        assert(kind.is_node());
        assert(checkpoint.index <= parser.events.count());

        parser.events.start_at(checkpoint, kind);
        parser.events.finish();
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

    fn descend(parser: *Parser) bool {
        assert(parser.task_count > 0);
        assert(parser.nesting <= nest_depth_max);

        if (parser.nesting >= nest_depth_max) {
            parser.outcome = .too_deep;

            return false;
        }

        parser.nesting += 1;

        return true;
    }

    fn ascend(parser: *Parser) void {
        assert(parser.nesting > 0);
        assert(parser.nesting <= nest_depth_max);

        parser.nesting -= 1;
    }

    fn iterate(parser: *const Parser, iteration: *u32) bool {
        assert(parser.count() < std.math.maxInt(u32));
        assert(iteration.* <= parser.steps());

        if (iteration.* == parser.steps()) return false;

        iteration.* += 1;

        return true;
    }

    fn expect(parser: *Parser, kind: Kind, failure: Diagnostic.Kind) void {
        assert(failure == .expected_colon);
        assert(kind.is_token());

        if (parser.eat(kind)) return;

        parser.record_expected(failure, kind);
    }

    fn eat(parser: *Parser, kind: Kind) bool {
        assert(parser.position <= parser.count());
        assert(kind.is_token());

        if (!parser.at(kind)) return false;

        parser.bump();

        return true;
    }

    fn bump(parser: *Parser) void {
        assert(parser.position <= parser.count());

        parser.skip_trivia();

        const before = parser.position;

        parser.emit();

        if (before < parser.count()) assert(parser.position == before + 1);
    }

    fn open(parser: *Parser, kind: Kind) void {
        assert(parser.position <= parser.count());
        assert(kind.is_node());

        parser.settle();
        parser.events.start(kind);
    }

    fn anchor(parser: *Parser) Checkpoint {
        parser.settle();

        const checkpoint = parser.events.checkpoint();

        assert(checkpoint.index <= parser.events.count());

        return checkpoint;
    }

    fn settle(parser: *Parser) void {
        assert(parser.significant_next <= parser.count());
        assert(parser.position <= parser.significant_next);

        if (parser.current() == null) return;

        parser.skip_trivia();
    }

    fn skip_layout(parser: *Parser) void {
        assert(parser.position <= parser.significant_next);
        assert(parser.position <= parser.count());

        for (0..parser.steps()) |_| {
            parser.skip_trivia();

            if (!parser.at_line_comment()) break;

            parser.skip_line_comment();
        }
    }

    fn at_line_comment(parser: *Parser) bool {
        assert(parser.raw.len == parser.tokens.len);
        assert(parser.position <= parser.count());

        if (parser.kind_at(parser.position) != .slash) return false;
        if (parser.kind_at(parser.position + 1) != .slash) return false;
        return parser.adjacent(parser.position + 1);
    }

    fn skip_line_comment(parser: *Parser) void {
        assert(parser.at_line_comment());

        const start = parser.tokens[parser.position].offset;
        const line_end = std.mem.findScalarPos(u8, parser.source, start, '\n');
        const end: u32 = @intCast(line_end orelse parser.source.len);

        for (0..parser.steps()) |_| {
            if (parser.position >= parser.count()) break;
            if (parser.tokens[parser.position].offset >= end) break;

            parser.emit_layout();
        }

        assert(parser.position <= parser.count());
    }

    fn skip_trivia(parser: *Parser) void {
        assert(parser.position <= parser.significant_next);

        for (parser.position..parser.raw.len) |_| {
            if (!is_layout(parser.raw[parser.position])) break;

            parser.emit();
        }

        assert(parser.position == parser.significant_next);
    }

    fn emit(parser: *Parser) void {
        assert(parser.significant_next >= parser.position);
        assert(parser.position <= parser.count());

        const kind = parser.kind_at(parser.position) orelse return;

        if (is_layout(kind)) {
            parser.events.layout(parser.position);
        } else {
            parser.events.token(parser.position);
        }

        parser.advance();
    }

    fn emit_layout(parser: *Parser) void {
        assert(parser.kind_at(parser.position) != .newline);
        assert(parser.position < parser.count());

        parser.events.layout(parser.position);
        parser.advance();
    }

    fn advance(parser: *Parser) void {
        assert(parser.position < parser.count());

        parser.position += 1;

        if (parser.position > parser.significant_next) {
            parser.significant_next = parser.significant_scan(parser.position);
        }

        assert(parser.significant_next >= parser.position);
        assert(parser.significant_next <= parser.count());
    }

    fn separated(parser: *Parser) bool {
        assert(parser.significant_next <= parser.count());

        const held = parser.significant(parser.position);

        assert(held >= parser.position);

        if (held > parser.position) return true;
        if (held == 0) return false;
        if (held >= parser.tokens.len) return false;
        return parser.tokens[held].offset > parser.tokens[held - 1].end();
    }

    fn adjacent(parser: *const Parser, position: u32) bool {
        assert(position <= parser.count());
        assert(parser.tokens.len == parser.raw.len);

        if (position == 0) return false;
        if (position >= parser.tokens.len) return false;
        return parser.tokens[position].offset == parser.tokens[position - 1].end();
    }

    fn named(parser: *const Parser, position: u32) bool {
        assert(position < parser.count());
        assert(parser.tokens.len == parser.raw.len);

        for (parser.text_at(position)) |byte| {
            if (!expression.is_name_byte(byte)) return false;
        }

        return true;
    }

    fn text_at(parser: *const Parser, position: u32) []const u8 {
        assert(position <= parser.count());
        assert(parser.tokens.len == parser.raw.len);

        if (position >= parser.tokens.len) return "";
        return parser.tokens[position].text(parser.source);
    }

    fn text_current(parser: *Parser) []const u8 {
        const position = parser.significant(parser.position);

        assert(position >= parser.position);
        assert(position <= parser.count());

        return parser.text_at(position);
    }

    fn at(parser: *Parser, kind: Kind) bool {
        assert(parser.position <= parser.count());
        assert(kind.is_token());

        return parser.current() == kind;
    }

    fn ahead(parser: *Parser, distance: u32) ?Kind {
        assert(distance > 0);
        assert(distance <= 2);

        var position = parser.significant(parser.position);

        for (0..distance) |_| {
            position = parser.significant(position + 1);
        }

        return parser.kind_at(position);
    }

    fn current(parser: *Parser) ?Kind {
        assert(parser.significant_next <= parser.count());

        const held = parser.kind_at(parser.significant(parser.position));

        if (held) |kind| assert(!is_layout(kind));

        return held;
    }

    fn significant(parser: *Parser, from: u32) u32 {
        assert(parser.significant_next >= parser.position);
        assert(from >= parser.position);

        if (from == parser.position) return parser.significant_next;
        return parser.significant_scan(from);
    }

    fn significant_scan(parser: *const Parser, from: u32) u32 {
        assert(from < std.math.maxInt(u32));

        var position = from;

        while (position < parser.raw.len) : (position += 1) {
            if (!is_layout(parser.raw[position])) break;
        }

        assert(position >= from);
        if (position < parser.raw.len) assert(!is_layout(parser.raw[position]));

        return position;
    }

    fn kind_at(parser: *const Parser, position: u32) ?Kind {
        assert(parser.raw.len == parser.tokens.len);

        if (position >= parser.raw.len) return null;
        return parser.raw[position];
    }

    fn count(parser: *const Parser) u32 {
        assert(parser.raw.len < std.math.maxInt(u32));
        assert(parser.tokens.len == parser.raw.len);

        return @intCast(parser.raw.len);
    }

    fn steps(parser: *const Parser) u32 {
        assert(parser.raw.len < std.math.maxInt(u32));
        assert(parser.tokens.len == parser.raw.len);

        return parser.count() + 1;
    }
};

const Resumed = enum {
    called,
    returned,
};

const Atom = union(enum) {
    none,
    done,
    call: Task,
};

const Form = enum {
    at_rule,
    charset,
    import,
    keyframes,
    keyframes_vendor,
    media,
    namespace,
    postcss,
    supports,

    fn node(form: Form) Kind {
        const kind: Kind = switch (form) {
            .at_rule => .at_rule,
            .charset => .charset_statement,
            .import => .import_statement,
            .keyframes, .keyframes_vendor => .keyframes_statement,
            .media => .media_statement,
            .namespace => .namespace_statement,
            .postcss => .postcss_statement,
            .supports => .supports_statement,
        };

        assert(kind.is_node());

        return kind;
    }
};

const Stop = enum {
    block,
    bracket,
    declaration,
    paren,
    query,

    fn holds(stop: Stop, kind: Kind) bool {
        assert(kind.is_token());

        return switch (stop) {
            .block, .query => kind == .brace_close or kind == .brace_open or kind == .semicolon,
            .bracket => kind == .bracket_close,
            .declaration => kind == .brace_close or kind == .semicolon,
            .paren => kind == .paren_close,
        };
    }
};

const Task = union(enum) {
    arguments: Arguments,
    at_statement: AtStatement,
    block: Block,
    call_expression: CallExpression,
    declaration: Declaration,
    grouped_value: GroupedValue,
    keyframe_blocks: KeyframeBlocks,
    loose_suffix: LooseSuffix,
    query: Query,
    query_group: QueryGroup,
    query_list: QueryList,
    rule_set: RuleSet,
    selector: Selector,
    selector_arguments: SelectorArguments,
    selector_operand: SelectorOperand,
    selector_tail: SelectorTail,
    value: Value,
    value_list: ValueList,
};

const Arguments = struct {
    stage: enum { start, value } = .start,
    iteration: u32 = 0,
    before: u32 = 0,
};

const AtStatement = struct {
    stage: enum { start, first, second, tail } = .start,
    form: Form = .at_rule,
    top: bool,
};

const Block = struct {
    stage: enum { start, item } = .start,
    iteration: u32 = 0,
    before: u32 = 0,
};

const CallExpression = struct {
    stage: enum { start, arguments } = .start,
};

const Declaration = struct {
    stage: enum { start, values } = .start,
};

const GroupedValue = struct {
    stage: enum { start, values } = .start,
    node: Kind,
};

const KeyframeBlocks = struct {
    stage: enum { start, block } = .start,
    iteration: u32 = 0,
    before: u32 = 0,
};

const LooseSuffix = struct {
    stage: enum { start, arguments, value } = .start,
    checkpoint: Checkpoint,
    kind: Kind,
};

const Query = struct {
    stage: enum { start, first, joined } = .start,
    checkpoint: ?Checkpoint = null,
    unary: ?Checkpoint = null,
    iteration: u32 = 0,
};

const QueryGroup = struct {
    stage: enum { start, inner } = .start,
    node: Kind,
};

const QueryList = struct {
    stage: enum { start, query } = .start,
    stop: Stop,
    iteration: u32 = 0,
    before: u32 = 0,
};

const RuleSet = struct {
    stage: enum { start, selector, block } = .start,
    iteration: u32 = 0,
    before: u32 = 0,
    start: u32 = 0,
};

const Selector = struct {
    stage: enum { start, operand, suffix } = .start,
    left: ?Checkpoint = null,
    iteration: u32 = 0,
};

const SelectorArguments = struct {
    stage: enum { start, item, of } = .start,
    nth: bool,
    iteration: u32 = 0,
    before: u32 = 0,
};

const SelectorOperand = struct {
    stage: enum { start, loose, chain_loose } = .start,
    chain: ?Checkpoint = null,
    right: ?Checkpoint = null,
    position_first: u32 = 0,
    position_last: u32 = 0,
    levels: u32 = 0,
};

const SelectorTail = struct {
    stage: enum { start, operand } = .start,
    left: Checkpoint,
    right: ?Checkpoint = null,
    kind: Kind,
};

const Value = struct {
    stage: enum { start, atom, operand } = .start,
    checkpoint: ?Checkpoint = null,
    iteration: u32 = 0,
};

const ValueList = struct {
    stage: enum { start, value } = .start,
    stop: Stop,
    iteration: u32 = 0,
    before: u32 = 0,
    depth: u32 = 0,
};

const Fixture = struct {
    events: Events,
    parser: Parser,
    raw: ArrayType(Kind),
    tokens: Tokens,
    tree: Tree,

    fn init(fixture: *Fixture) !void {
        const gpa = std.testing.allocator;

        try fixture.events.init(gpa, 1 << 10);
        errdefer fixture.events.deinit(gpa);

        fixture.raw = try .init(gpa, 1 << 8);
        errdefer fixture.raw.deinit(gpa);

        fixture.tokens = try .init(gpa, 1 << 8);
        errdefer fixture.tokens.deinit(gpa);

        fixture.tree = try .init(gpa, 1 << 8, 1 << 4);

        assert(fixture.raw.empty());
        assert(fixture.tree.count() == 0);
    }

    fn deinit(fixture: *Fixture) void {
        const gpa = std.testing.allocator;

        assert(fixture.raw.capacity() == fixture.tokens.items.capacity());
        assert(fixture.events.items.capacity() > 0);

        fixture.tree.deinit(gpa);
        fixture.tokens.deinit(gpa);
        fixture.raw.deinit(gpa);
        fixture.events.deinit(gpa);
    }

    fn kinds(fixture: *Fixture, source: []const u8, declarations: bool) ![]const Tree.Node {
        assert(source.len <= std.math.maxInt(u32));

        fixture.tokens.clear();

        try lex(source, &fixture.tokens);
        try raw_of(Kind, fixture.tokens.slice(), &fixture.raw);

        assert(fixture.tokens.count() == fixture.raw.count());

        const built = if (declarations)
            fixture.parser.build_declarations(
                source,
                fixture.tokens.slice(),
                fixture.raw.const_slice(),
                &fixture.events,
                &fixture.tree,
            )
        else
            fixture.parser.build(
                source,
                fixture.tokens.slice(),
                fixture.raw.const_slice(),
                &fixture.events,
                &fixture.tree,
            );

        try std.testing.expectEqual(Structure.complete, built);

        return fixture.tree.slice();
    }
};

const nest_depth_max: u32 = expression.nest_depth_max;
const task_chain_max: u32 = 4;
const task_count_max: u32 = (nest_depth_max + 1) * task_chain_max;
const scan_step_max: u32 = expression.scan_step_max;
const item_iteration_max: u32 = std.math.maxInt(u32);
const resume_count_max: u64 = std.math.maxInt(u32);
const attribute_modifiers = [_][]const u8{ "I", "S", "i", "s" };

comptime {
    assert(task_count_max > nest_depth_max);
    assert(scan_step_max > nest_depth_max);
}

fn is_layout(kind: Kind) bool {
    assert(kind.is_token());

    return kind == .comment or kind == .newline;
}

fn opens_a_group(kind: Kind) bool {
    assert(kind.is_token());

    return kind == .bracket_open or kind == .paren_open;
}

fn closes_a_group(kind: Kind) bool {
    assert(kind.is_token());

    return kind == .bracket_close or kind == .paren_close;
}

fn is_attribute_operator(kind: Kind) bool {
    assert(kind.is_token());

    return switch (kind) {
        .bar_equal, .caret_equal, .dollar_equal, .equal, .star_equal, .tilde_equal => true,
        else => false,
    };
}

fn names_keyframes(text: []const u8) bool {
    if (!std.mem.endsWith(u8, text, "keyframes")) return false;

    assert(text.len >= "keyframes".len);

    for (text) |byte| {
        if (byte == '-') continue;
        if (!std.ascii.isLower(byte)) return false;
    }

    return true;
}

fn kind_count_of(nodes: []const Tree.Node, kind: Kind) u32 {
    assert(nodes.len <= std.math.maxInt(u32));
    assert(kind.is_node());

    var held: u32 = 0;

    for (nodes) |node| {
        if (node.kind == kind) held += 1;
    }

    return held;
}

test "a style value reads as declarations" {
    var fixture: Fixture = undefined;

    try fixture.init();
    defer fixture.deinit();

    const nodes = try fixture.kinds("color: red; margin: 0", true);

    try std.testing.expectEqual(2, kind_count_of(nodes, .declaration));
    try std.testing.expectEqual(0, kind_count_of(nodes, .rule_set));
}

test "a pseudo class prefix stays a declaration in a declaration list" {
    var fixture: Fixture = undefined;

    try fixture.init();
    defer fixture.deinit();

    const list = try fixture.kinds("a:hover {color: red}", true);

    try std.testing.expectEqual(Kind.declaration, list[1].kind);

    const sheet = try fixture.kinds("a:hover {color: red}", false);

    try std.testing.expectEqual(Kind.rule_set, sheet[1].kind);
}

test "a custom property takes a braced value up to its own semicolon" {
    var fixture: Fixture = undefined;

    try fixture.init();
    defer fixture.deinit();

    const source = "a { --x: { color: red; }; --y: blue; --z: {b:c;} --w: d; }";
    const nodes = try fixture.kinds(source, false);

    try std.testing.expectEqual(3, kind_count_of(nodes, .declaration));
    try std.testing.expectEqual(1, kind_count_of(nodes, .rule_set));
    try std.testing.expectEqual(0, fixture.tree.diagnostic_slice().len);
}

test "a custom value with a closer it never opened is an error" {
    var fixture: Fixture = undefined;

    try fixture.init();
    defer fixture.deinit();

    const sources = [_][]const u8{ "a { --x: ); }", "a { --x: ]; }", "a { --x: (b }" };

    for (sources) |source| {
        _ = try fixture.kinds(source, false);

        try std.testing.expect(fixture.tree.diagnostic_slice().len > 0);
    }

    _ = try fixture.kinds("a { --x: (b; c) [d; e]; }", false);

    try std.testing.expectEqual(0, fixture.tree.diagnostic_slice().len);
}

test "a nested rule inside a declaration list keeps the sheet reading" {
    var fixture: Fixture = undefined;

    try fixture.init();
    defer fixture.deinit();

    const nodes = try fixture.kinds("@media print { a:hover { color: red } }", true);

    try std.testing.expect(kind_count_of(nodes, .rule_set) > 0);
}
