const std = @import("std");
const assert = std.debug.assert;
const Checkpoint = @import("../tree.zig").Checkpoint;
const Dialect = @import("dialect.zig").Dialect;
const Goal = @import("dialect.zig").Goal;
const Grammar = @import("dialect.zig").Grammar;
const EventsType = @import("../tree.zig").EventsType;
const Kind = @import("kind.zig").Kind;
const Span = @import("../../stdx/bounded/span.zig");
const Structure = @import("../tree.zig").Structure;
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const Slash = @import("lex.zig").Slash;
const Token = @import("../token.zig");
const TreeType = @import("../tree.zig").TreeType;
const constraint = @import("constraint.zig");
const expression = @import("expression.zig");
const lookahead = @import("lookahead.zig");
const template = @import("lex/template.zig");
const Events = EventsType(Kind);
const Frame = expression.Frame;
const Tree = TreeType(Kind);
const Variant = expression.Variant;
const declares = expression.declares;
const ends_a_modifier = expression.ends_a_modifier;
const ends_a_nullable = expression.ends_a_nullable;
const is_closer = expression.is_closer;
const is_closer_of_list = expression.is_closer_of_list;
const is_layout = expression.is_layout;
const is_literal = expression.is_literal;
const is_literal_type = expression.is_literal_type;
const is_name = expression.is_name;
const is_opener = expression.is_opener;
const is_prefix = expression.is_prefix;
const is_property_name = expression.is_property_name;
const is_statement_word = expression.is_statement_word;
const is_type_token = expression.is_type_token;
const iterates_over = expression.iterates_over;
const opener_of = expression.opener_of;
const opens_a_key = expression.opens_a_key;
const opens_an_expression = expression.opens_an_expression;
const reaches = expression.reaches;

pub const Parser = struct {
    arrow_awaits: bool,
    arrowed: u32,
    reduced: u32,
    balanced_ends: [balanced_slot_count]u32,
    balanced_opens: [balanced_slot_count]u32,
    dialect: Dialect,
    events: *Events,
    frame_count: u32,
    frames: [expression.depth_max]Frame,
    goal: Goal,
    nesting: u32,
    outcome: Structure,
    plain_failure: u32,
    position: u32,
    raw: []const Kind,
    returned: Step,
    sealed: u32,
    significant_next: u32,
    slash: ?Slash,
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
        grammar: Grammar,
    ) Structure {
        assert(source.len <= std.math.maxInt(u32));
        assert(tokens.len == raw.len);

        events.clear();
        tree.clear();

        parser.arrow_awaits = false;
        parser.arrowed = position_none;
        parser.reduced = position_none;
        parser.balanced_ends = @splat(0);
        parser.balanced_opens = @splat(position_none);
        parser.dialect = grammar.dialect;
        parser.events = events;
        parser.frame_count = 0;
        parser.goal = grammar.goal;
        parser.nesting = 0;
        parser.outcome = .complete;
        parser.plain_failure = 0;
        parser.position = 0;
        parser.raw = raw;
        parser.returned = .done;
        parser.sealed = position_none;
        parser.significant_next = 0;
        parser.slash = null;
        parser.source = source;
        parser.task_count = 0;
        parser.tokens = tokens;
        parser.tree = tree;
        parser.value_count = 0;

        parser.significant_next = parser.significant_scan(0);

        parser.run();

        assert(parser.task_count == 0);
        assert(parser.nesting == 0);
        assert(parser.frame_count == 0);
        assert(parser.value_count == 0);

        const recorded = parser.outcome;
        const buffered = events.outcome;
        const replayed = events.replay(tree);

        if (recorded != .complete) return recorded;
        if (buffered != .complete) return buffered;
        if (replayed != .complete) return replayed;

        parser.constraints_check();

        return parser.outcome;
    }

    fn constraints_check(parser: *Parser) void {
        const tree = parser.tree;

        assert(parser.outcome == .complete);
        assert(parser.task_count == 0);

        for (tree.slice(), 0..) |node, position| {
            const index: u32 = @intCast(position);

            switch (node.kind) {
                .for_in_statement => parser.iteration_check(index),
                .function_type, .constructor_type => {
                    if (constraint.operand_unparenthesized(tree, index)) {
                        parser.record_at(.unexpected_token, null, node.token_start);
                    }
                },
                .index_signature => {
                    if (constraint.mapped_shared(tree, index)) {
                        parser.record_at(.unexpected_token, null, node.token_start);
                    }
                },
                .member_expression, .subscript_expression => {
                    if (constraint.target_refused(tree, index)) {
                        parser.record_at(.unexpected_token, null, node.token_start);
                    }
                },
                else => {},
            }
        }
    }

    fn iteration_check(parser: *Parser, index: u32) void {
        assert(index < std.math.maxInt(u32));

        const tree = parser.tree;
        const head = tree.child_first_of(index) orelse return;
        const start = tree.at(head).token_start;

        assert(tree.kind_at(index) == .for_in_statement);
        assert(head > index);

        if (parser.iteration_declared(tree.at(index).token_start, start)) return;
        if (constraint.iteration_target(tree, head)) return;

        parser.record_at(.unexpected_token, null, start);
    }

    fn iteration_declared(parser: *Parser, from: u32, to: u32) bool {
        assert(from <= to);
        assert(to <= parser.count());

        for (from..to) |position| {
            if (declares(parser.raw[position])) return true;
            if (parser.word_at(@intCast(position), "using")) return true;
        }

        return false;
    }

    fn run(parser: *Parser) void {
        assert(parser.position == 0);
        assert(parser.task_count == 0);

        parser.events.start(.program);
        parser.drive(.{ .statements = .{ .closer = .error_token } });

        if (parser.current() != null) parser.record(.unexpected_token);

        parser.events.finish();
    }

    fn drive(parser: *Parser, task: Task) void {
        assert(parser.task_count == 0);
        assert(parser.nesting == 0);

        parser.tasks[0] = task;
        parser.task_count = 1;

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
        assert(parser.task_count > 0);
        assert(parser.task_count <= task_count_max);

        if (parser.task_count >= task_count_max) {
            parser.outcome = .too_deep;
            parser.returned = .done;

            return .called;
        }

        parser.tasks[parser.task_count] = task;
        parser.task_count += 1;

        return .called;
    }

    fn invoke(parser: *Parser, held: ?Task) Resumed {
        assert(parser.task_count > 0);
        assert(parser.task_count <= task_count_max);
        if (held) |task| assert(task != .statements);

        const task = held orelse return .called;
        return parser.call(task);
    }

    fn task_resume(parser: *Parser, task: *Task) Resumed {
        assert(parser.task_count > 0);
        assert(task == &parser.tasks[parser.task_count - 1]);

        return switch (task.*) {
            inline else => |*state, tag| @field(Parser, @tagName(tag) ++ "_resume")(parser, state),
        };
    }

    fn statements_resume(parser: *Parser, state: *Statements) Resumed {
        assert(state.closer.is_token());
        assert(state.iteration <= loop_step_max);

        if (state.stage == .statement) {
            if (parser.position == state.before) {
                parser.record(.unexpected_token);
                parser.emit();
            }
        }

        if (state.iteration == loop_step_max) return .returned;

        state.iteration += 1;

        parser.skip_trivia();

        const kind = parser.current() orelse return .returned;

        if (state.closer != .error_token) {
            if (kind == state.closer) return .returned;
        }

        state.before = parser.position;
        state.stage = .statement;

        return parser.call(.{ .statement = .{} });
    }

    fn statement_resume(parser: *Parser, state: *Statement) Resumed {
        assert(parser.nesting <= nest_depth_max);
        if (state.stage == .done) assert(parser.nesting > 0);

        switch (state.stage) {
            .start => {
                if (parser.nesting >= nest_depth_max) {
                    parser.outcome = .too_deep;

                    parser.emit();

                    return .returned;
                }

                parser.nesting += 1;
                state.stage = .done;

                return parser.invoke(parser.statement_task());
            },
            .done => {
                parser.nesting -= 1;

                return .returned;
            },
        }
    }

    fn statement_task(parser: *Parser) ?Task {
        assert(parser.nesting > 0);

        const kind = parser.current() orelse return null;

        assert(kind.is_token());

        switch (kind) {
            .at => return .{ .decorated = .{} },
            .brace_open => return .{ .statement_block = .{} },
            .break_keyword => parser.jump_statement(.break_statement),
            .class_keyword => return .{ .class = .{ .kind = .class_declaration } },
            .continue_keyword => parser.jump_statement(.continue_statement),
            .debugger_keyword => parser.debugger_statement(),
            .do_keyword => return .{ .do_statement = .{} },
            .export_keyword => return .{ .export_statement = .{} },
            .for_keyword => return parser.for_task(),
            .function_keyword => return .{ .function_declaration = .{} },
            .if_keyword => return .{ .if_statement = .{} },
            .return_keyword => return .{ .keyword_statement = .{ .kind = .return_statement } },
            .semicolon => parser.wrap(.empty_statement),
            .switch_keyword => return .{ .switch_statement = .{} },
            .throw_keyword => return .{ .keyword_statement = .{ .kind = .throw_statement } },
            .try_keyword => return .{ .try_statement = .{} },
            .while_keyword => return .{ .loop_statement = .{ .kind = .while_statement } },
            .with_keyword => return .{ .loop_statement = .{ .kind = .with_statement } },
            else => return parser.statement_guarded(kind),
        }

        return null;
    }

    fn statement_guarded(parser: *Parser, kind: Kind) Task {
        assert(kind.is_token());
        assert(parser.nesting > 0);

        const declaration: Task = .{ .declaration = .{} };

        switch (kind) {
            .const_keyword => {
                if (parser.typed()) {
                    if (parser.word_at(parser.ahead_position(1), "enum")) {
                        return .{ .enum_declaration = .{} };
                    }
                }

                return declaration;
            },
            .var_keyword => return declaration,
            .async_keyword => {
                if (parser.ahead(1) == .function_keyword) {
                    if (!parser.starts_line(parser.ahead_position(1))) {
                        return .{ .function_declaration = .{} };
                    }
                }
            },
            .let_keyword => if (parser.opens_a_binding()) return declaration,
            .await_keyword => if (parser.opens_a_resource(1)) return declaration,
            .identifier => if (parser.opens_a_resource(0)) return declaration,
            else => {},
        }

        return parser.statement_fallback(kind);
    }

    fn statement_fallback(parser: *Parser, kind: Kind) Task {
        assert(kind.is_token());
        assert(parser.nesting > 0);

        if (kind == .import_keyword) {
            if (parser.typed()) {
                if (parser.opens_an_import_alias()) return .{ .import_alias = .{} };
            }

            const after = parser.ahead(1);
            const called = after == .dot or after == .paren_open;
            if (!called) return .{ .import_statement = .{} };
        }

        if (parser.typed_statement_task()) |task| return task;

        if (is_name(kind)) {
            if (parser.ahead(1) == .colon) return .{ .labeled_statement = .{} };
        }

        return .{ .expression_statement = .{} };
    }

    fn typed_statement_task(parser: *Parser) ?Task {
        assert(parser.position <= parser.count());
        assert(parser.nesting > 0);

        if (!parser.typed()) return null;

        const lined = !parser.starts_line(parser.ahead_position(1));

        if (parser.word("interface")) {
            if (lined) {
                if (parser.opens_a_name(1)) return .{ .interface_declaration = .{} };
            }
        }

        if (parser.word("type")) {
            if (parser.opens_an_alias()) return .{ .type_alias = .{} };
        }

        if (parser.word("enum")) {
            if (parser.opens_a_name(1)) return .{ .enum_declaration = .{} };
        }

        if (parser.word("declare")) {
            if (parser.opens_an_ambient()) return .{ .ambient_declaration = .{} };
        }

        if (parser.word("abstract")) {
            if (lined) {
                if (parser.ahead(1) == .class_keyword) {
                    return .{ .class = .{
                        .kind = .abstract_class_declaration,
                        .abstracted = true,
                    } };
                }
            }
        }

        if (parser.word("namespace")) {
            if (lined) {
                if (parser.opens_a_name(1)) return .{ .namespace_statement = .{} };
            }
        }

        if (parser.word("module")) {
            if (lined) {
                if (parser.opens_a_module(1)) return .{ .module_declaration = .{} };
            }
        }

        if (parser.word("global")) {
            if (parser.ahead(1) == .brace_open) return .{ .module_declaration = .{} };
        }

        return null;
    }

    fn statement_block_resume(parser: *Parser, state: *StatementBlock) Resumed {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        switch (state.stage) {
            .start => {
                parser.open(.statement_block);
                parser.expect(.brace_open, .unexpected_token);
                state.stage = .body;

                return parser.call(.{ .statements = .{ .closer = .brace_close } });
            },
            .body => {
                parser.expect(.brace_close, .unmatched_bracket);
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn expression_statement_resume(parser: *Parser, state: *ExpressionStatement) Resumed {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        switch (state.stage) {
            .start => {
                parser.open(.expression_statement);
                state.stage = .done;

                return parser.call(expression_of(true));
            },
            .done => {
                parser.terminate();
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn declaration_resume(parser: *Parser, state: *Declaration) Resumed {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        switch (state.stage) {
            .start => {
                const lexical = !parser.at(.var_keyword);
                const kind: Kind = if (lexical) .lexical_declaration else .variable_declaration;

                parser.open(kind);

                if (parser.at(.await_keyword)) parser.bump();

                parser.bump();
                state.stage = .declared;

                return parser.call(.{ .comma_list = .{
                    .item = .variable_declarator,
                    .stuck_ends = true,
                } });
            },
            .declared => {
                if (state.headed) {
                    parser.expect(.semicolon, .unexpected_token);
                } else {
                    parser.terminate();
                }

                parser.events.finish();

                return .returned;
            },
        }
    }

    fn variable_declarator_resume(parser: *Parser, state: *VariableDeclarator) Resumed {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        switch (state.stage) {
            .start => {
                const kind = parser.current() orelse .error_token;
                const bindable = is_name(kind) or kind == .bracket_open or kind == .brace_open;

                parser.open(.variable_declarator);
                state.stage = .patterned;

                if (!bindable) parser.record(.expected_identifier);

                return parser.invoke(parser.binding_task());
            },
            .patterned => {
                if (parser.typed()) {
                    if (!parser.breaks_line()) _ = parser.eat(.bang);
                }

                state.stage = .annotated;

                return parser.invoke(parser.type_annotation_task());
            },
            .annotated => {
                state.stage = .done;

                if (parser.eat(.equal)) return parser.call(expression_required());
                return .called;
            },
            .done => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn comma_list_resume(parser: *Parser, state: *CommaList) Resumed {
        assert(state.iteration <= parser.steps());
        assert(parser.position <= parser.count());

        if (state.stage == .item) {
            if (!parser.eat(.comma)) return .returned;

            if (parser.position == state.before) {
                if (state.stuck_ends) return .returned;

                parser.record(.unexpected_token);
                parser.emit();
            }
        }

        if (state.iteration == parser.steps()) return .returned;

        state.iteration += 1;
        state.before = parser.position;
        state.stage = .item;

        return parser.invoke(parser.procedure_task(state.item));
    }

    fn function_declaration_resume(parser: *Parser, state: *FunctionDeclaration) Resumed {
        assert(parser.position <= parser.count());
        if (state.stage != .start) assert(state.checkpoint != null);

        switch (state.stage) {
            .start => {
                const skipped: u32 = @intFromBool(parser.at(.async_keyword));

                if (!parser.names_a_function()) parser.record(.expected_identifier);

                state.awaits = skipped > 0;
                state.generator = parser.ahead(skipped + 1) == .star;
                state.checkpoint = parser.anchor();
                state.stage = .head;

                return parser.call(.{ .function_head = .{} });
            },
            .head => {
                state.stage = .done;
                state.kind = .function_signature;

                if (!parser.at(.brace_open)) {
                    parser.terminate();

                    return .called;
                }

                state.kind = .function_declaration;

                if (state.generator) state.kind = .generator_function_declaration;

                return parser.call(.{ .statement_block = .{} });
            },
            .done => {
                parser.events.start_at(state.checkpoint.?, state.kind);
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn function_expression_resume(parser: *Parser, state: *FunctionExpression) Resumed {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        switch (state.stage) {
            .start => {
                const skipped: u32 = @intFromBool(parser.at(.async_keyword));
                const generator = parser.ahead(skipped + 1) == .star;
                const kind: Kind = if (generator) .generator_function else .function_expression;

                parser.open(kind);
                state.awaits = skipped > 0;
                state.generator = generator;
                state.stage = .head;

                return parser.call(.{ .function_head = .{} });
            },
            .head => {
                state.stage = .done;

                return parser.call(.{ .statement_block = .{} });
            },
            .done => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn function_head_resume(parser: *Parser, state: *FunctionHead) Resumed {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        switch (state.stage) {
            .start => {
                _ = parser.eat(.async_keyword);

                parser.expect(.function_keyword, .unexpected_token);
                _ = parser.eat(.star);

                if (is_name(parser.current() orelse .error_token)) parser.wrap(.identifier_node);

                state.stage = .typed;

                return parser.invoke(parser.type_parameters_task());
            },
            .typed => {
                state.stage = .parameters;

                return parser.call(formal_parameters_of());
            },
            .parameters => {
                state.stage = .done;

                return parser.invoke(parser.return_annotation_task());
            },
            .done => return .returned,
        }
    }

    fn decorated_resume(parser: *Parser, state: *Decorated) Resumed {
        assert(parser.position <= parser.count());
        if (state.stage != .start) assert(state.checkpoint != null);

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();
                state.stage = .decorated;

                return parser.call(.{ .decorators = .{} });
            },
            .decorated => {
                const checkpoint = state.checkpoint.?;

                const task: Task = if (state.expression)
                    .{ .class = .{ .checkpoint = checkpoint, .kind = .class } }
                else
                    parser.decorated_task(checkpoint);

                state.stage = .done;

                return parser.call(task);
            },
            .done => return .returned,
        }
    }

    fn decorated_task(parser: *Parser, checkpoint: Checkpoint) Task {
        assert(parser.position <= parser.count());
        assert(checkpoint.index <= parser.events.count());

        if (parser.at(.class_keyword)) {
            return .{ .class = .{ .checkpoint = checkpoint, .kind = .class_declaration } };
        }

        if (parser.typed()) {
            if (parser.word("abstract")) {
                if (parser.ahead(1) == .class_keyword) return .{ .class = .{
                    .checkpoint = checkpoint,
                    .kind = .abstract_class_declaration,
                    .abstracted = true,
                } };
            }
        }

        if (parser.at(.export_keyword)) {
            if (!parser.exports_a_class()) parser.record(.unexpected_token);

            return .{ .export_statement = .{ .checkpoint = checkpoint } };
        }

        parser.record(.unexpected_token);

        return .{ .statement = .{} };
    }

    fn exports_a_class(parser: *Parser) bool {
        assert(parser.at(.export_keyword));
        assert(parser.position < parser.count());

        var distance: u32 = 1;

        if (parser.ahead(distance) == .default_keyword) distance += 1;
        if (parser.ahead(distance) == .class_keyword) return true;
        if (!parser.typed()) return false;
        if (!parser.word_at(parser.ahead_position(distance), "abstract")) return false;
        return parser.ahead(distance + 1) == .class_keyword;
    }

    fn decorators_resume(parser: *Parser, state: *Decorators) Resumed {
        assert(state.iteration <= parser.steps());
        assert(parser.position <= parser.count());

        if (state.stage == .decorator) parser.skip_trivia();
        if (state.iteration == parser.steps()) return .returned;

        state.iteration += 1;

        if (!parser.at(.at)) return .returned;

        state.stage = .decorator;

        return parser.call(enclosed(.decorator, .expression_decorator));
    }

    fn class_resume(parser: *Parser, state: *Class) Resumed {
        assert(state.kind.is_node());
        if (state.stage != .start) assert(state.checkpoint != null);

        switch (state.stage) {
            .start => {
                if (state.checkpoint == null) state.checkpoint = parser.anchor();
                if (state.abstracted) parser.bump();

                parser.expect(.class_keyword, .unexpected_token);

                if (is_name(parser.current() orelse .error_token)) {
                    if (!parser.typed()) {
                        parser.wrap(.identifier_node);
                    } else if (parser.word("implements")) {} else {
                        parser.wrap(.type_identifier);
                    }
                }

                state.stage = .typed;

                return parser.invoke(parser.type_parameters_task());
            },
            .typed => {
                state.stage = .heritage;

                return parser.call(.{ .class_heritage = .{} });
            },
            .heritage => {
                state.stage = .done;

                return parser.call(.{ .list = .{
                    .kind = .class_body,
                    .opening = .expect,
                    .closer = .brace_close,
                    .item = .class_member,
                    .style = .semicolon_skips,
                } });
            },
            .done => {
                parser.events.start_at(state.checkpoint.?, state.kind);
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn class_heritage_resume(parser: *Parser, state: *ClassHeritage) Resumed {
        assert(state.iteration <= parser.steps());
        assert(parser.position <= parser.count());

        if (state.stage == .start) {
            const implemented = parser.typed() and parser.word("implements");
            const heritable = parser.at(.extends_keyword) or implemented;
            if (!heritable) return .returned;

            parser.open(.class_heritage);
            state.stage = .clause;
        }

        if (state.stage == .plain) {
            parser.events.finish();

            return .returned;
        }

        if (state.iteration < parser.steps()) {
            state.iteration += 1;

            if (parser.at(.extends_keyword)) {
                if (!parser.typed()) {
                    parser.bump();
                    state.stage = .plain;

                    return parser.call(expression_required());
                }

                return parser.call(enclosed(.extends_clause, .heritage_list));
            }

            if (parser.typed()) {
                if (parser.word("implements")) {
                    return parser.call(enclosed(.implements_clause, .type_list));
                }
            }
        }

        parser.events.finish();

        return .returned;
    }

    fn heritage_item_resume(parser: *Parser, state: *HeritageItem) Resumed {
        assert(parser.position <= parser.count());
        if (state.stage == .called) assert(state.checkpoint != null);

        switch (state.stage) {
            .start => {
                state.stage = .done;

                if (parser.parenthesized_generic_ahead()) {
                    state.stage = .parenthesized;

                    return parser.call(.{ .parenthesized = .{} });
                }

                if (!lookahead.heritage_generic_ahead(parser)) {
                    return parser.call(expression_required());
                }

                state.checkpoint = parser.anchor();
                state.stage = .targeted;

                return parser.call(.{ .query_target = .{} });
            },
            .parenthesized => {
                state.stage = .done;

                return parser.invoke(parser.type_arguments_task());
            },
            .targeted => {
                state.stage = .typed;

                return parser.invoke(parser.type_arguments_task());
            },
            .typed => {
                if (!parser.at(.paren_open)) return .returned;

                state.stage = .called;

                return parser.call(argument_list_of());
            },
            .called => {
                parser.events.start_at(state.checkpoint.?, .call_expression);
                parser.events.finish();

                return .returned;
            },
            .done => return .returned,
        }
    }

    fn class_member_resume(parser: *Parser, state: *ClassMember) Resumed {
        assert(parser.position <= parser.count());
        if (state.stage != .start) assert(state.checkpoint != null);

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();
                state.decorated = parser.at(.at);
                state.stage = .decorated;

                return parser.call(.{ .decorators = .{} });
            },
            .decorated => return parser.class_member_open(state),
            .indexed => {
                parser.terminate();

                return .returned;
            },
            .keyed => {
                _ = parser.eat(.question);

                if (parser.typed()) {
                    if (!parser.breaks_line()) _ = parser.eat(.bang);
                }

                state.stage = .annotated;

                return parser.invoke(parser.type_annotation_task());
            },
            .annotated => {
                state.stage = .valued;

                if (!parser.eat(.equal)) return .called;

                if (state.abstracted) parser.record(.unexpected_token);

                return parser.call(expression_required());
            },
            .valued => {
                const kind: Kind = if (parser.typed())
                    .public_field_definition
                else
                    .field_definition;

                parser.events.start_at(state.checkpoint.?, kind);
                parser.events.finish();
                parser.terminate();

                return .returned;
            },
            .done => return .returned,
        }
    }

    fn class_member_open(parser: *Parser, state: *ClassMember) Resumed {
        assert(state.stage == .decorated);
        assert(state.checkpoint != null);

        if (state.decorated) {
            if (parser.method_ahead()) {
                if (parser.typed()) return .returned;

                state.stage = .done;

                return parser.call(.{ .method_definition = .{ .checkpoint = state.checkpoint } });
            }
        }

        state.stage = .done;

        if (parser.at(.static_keyword)) {
            if (parser.ahead(1) == .brace_open) {
                return parser.call(enclosed(.class_static_block, .statement_block));
            }
        }

        if (parser.method_ahead()) return parser.call(.{ .method_definition = .{} });

        if (parser.typed()) {
            if (parser.index_member_ahead()) {
                state.stage = .indexed;

                return parser.call(.{ .index_signature = .{} });
            }
        }

        state.abstracted = parser.modifiers();
        state.stage = .keyed;

        return parser.invoke(parser.property_key_task());
    }

    fn index_member_ahead(parser: *Parser) bool {
        assert(parser.position <= parser.count());

        if (lookahead.readonly_index_ahead(parser)) return true;
        if (parser.at(.bracket_open)) return lookahead.index_signature_ahead(parser);

        var position = parser.significant(parser.position);

        for (0..modifier_words.len) |_| {
            const kind = parser.kind_at(position) orelse return false;
            if (kind == .bracket_open) return lookahead.index_signature_at(parser, position);
            if (!parser.modifier_at(position)) return false;

            position = parser.significant(position + 1);
        }

        return false;
    }

    fn modifier_at(parser: *Parser, position: u32) bool {
        assert(position < parser.count());
        assert(parser.tokens.len == parser.raw.len);

        const kind = parser.raw[position];
        if (kind == .async_keyword) return true;
        if (kind == .static_keyword) return true;

        for (modifier_words) |modifier| {
            if (parser.word_at(position, modifier)) return true;
        }

        return false;
    }

    fn parenthesized_resume(parser: *Parser, state: *Parenthesized) Resumed {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        switch (state.stage) {
            .start => {
                parser.open(.parenthesized_expression);
                parser.expect(.paren_open, .unexpected_token);
                state.stage = .done;

                return parser.call(expression_of(true));
            },
            .done => {
                parser.expect(.paren_close, .unmatched_bracket);
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn if_statement_resume(parser: *Parser, state: *IfStatement) Resumed {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        switch (state.stage) {
            .start => {
                parser.open(.if_statement);
                parser.bump();
                state.stage = .condition;

                return parser.call(.{ .parenthesized = .{} });
            },
            .condition => {
                state.stage = .body;

                return parser.call(.{ .statement = .{} });
            },
            .body => {
                state.stage = .done;

                if (!parser.at(.else_keyword)) return .called;
                return parser.call(enclosed(.else_clause, .statement));
            },
            .done => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn loop_statement_resume(parser: *Parser, state: *LoopStatement) Resumed {
        assert(state.kind.is_node());
        assert(parser.position <= parser.count());

        switch (state.stage) {
            .start => {
                parser.open(state.kind);
                parser.bump();
                state.stage = .condition;

                return parser.call(.{ .parenthesized = .{} });
            },
            .condition => {
                state.stage = .done;

                return parser.call(.{ .statement = .{} });
            },
            .done => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn do_statement_resume(parser: *Parser, state: *DoStatement) Resumed {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        switch (state.stage) {
            .start => {
                parser.open(.do_statement);
                parser.bump();
                state.stage = .body;

                return parser.call(.{ .statement = .{} });
            },
            .body => {
                parser.expect(.while_keyword, .unexpected_token);
                state.stage = .done;

                return parser.call(.{ .parenthesized = .{} });
            },
            .done => {
                _ = parser.eat(.semicolon);

                parser.events.finish();

                return .returned;
            },
        }
    }

    fn for_task(parser: *Parser) Task {
        assert(parser.at(.for_keyword));
        assert(parser.nesting > 0);

        if (lookahead.iterates(parser)) return .{ .for_in_statement = .{} };
        return .{ .for_statement = .{} };
    }

    fn for_statement_resume(parser: *Parser, state: *ForStatement) Resumed {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        switch (state.stage) {
            .start => return parser.for_open(state),
            .initializer => {
                parser.expect(.semicolon, .unexpected_token);
                state.stage = .initialized;

                return .called;
            },
            .initialized => {
                state.stage = .conditioned;

                if (parser.at(.semicolon)) {
                    parser.wrap(.empty_statement);

                    return .called;
                }

                state.stage = .condition;

                return parser.call(expression_of(true));
            },
            .condition => {
                parser.expect(.semicolon, .unexpected_token);
                state.stage = .conditioned;

                return .called;
            },
            .conditioned => {
                state.stage = .updated;

                if (!parser.at(.paren_close)) return parser.call(expression_of(true));
                return .called;
            },
            .updated => {
                parser.expect(.paren_close, .unmatched_bracket);
                state.stage = .done;

                return parser.call(.{ .statement = .{} });
            },
            .done => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn for_in_statement_resume(parser: *Parser, state: *ForInStatement) Resumed {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        switch (state.stage) {
            .start => return parser.for_in_open(state),
            .patterned => {
                if (state.variable) {
                    if (parser.eat(.equal)) {
                        state.stage = .initialized;

                        return parser.call(expression_iterated());
                    }
                }

                return parser.for_in_iterate(state);
            },
            .initialized => return parser.for_in_iterate(state),
            .subject => {
                parser.expect(.paren_close, .unmatched_bracket);
                state.stage = .done;

                return parser.call(.{ .statement = .{} });
            },
            .done => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn for_open(parser: *Parser, state: *ForStatement) Resumed {
        assert(state.stage == .start);
        assert(parser.at(.for_keyword));

        parser.open(.for_statement);
        parser.bump();
        parser.expect(.paren_open, .unexpected_token);
        state.stage = .initialized;

        if (parser.at(.semicolon)) {
            parser.wrap(.empty_statement);

            return .called;
        }

        const resource = parser.opens_a_resource(0) or
            (parser.at(.await_keyword) and parser.opens_a_resource(1));

        const declared = parser.declares_ahead() or resource;

        if (declared) {
            return parser.call(.{ .declaration = .{ .headed = true } });
        }

        state.stage = .initializer;

        return parser.call(expression_of(true));
    }

    fn for_in_open(parser: *Parser, state: *ForInStatement) Resumed {
        assert(state.stage == .start);
        assert(parser.at(.for_keyword));

        parser.open(.for_in_statement);
        parser.bump();
        _ = parser.eat(.await_keyword);

        parser.expect(.paren_open, .unexpected_token);

        var awaited = false;

        if (parser.at(.await_keyword)) {
            awaited = parser.iterates_a_resource(1);

            if (awaited) parser.bump();
        }

        state.resource = awaited or parser.iterates_a_resource(0);

        const declared = parser.declares_ahead() or state.resource;

        state.stage = .patterned;

        if (!declared) return parser.invoke(parser.iteration_target_task());

        state.variable = parser.at(.var_keyword);

        parser.bump();

        return parser.invoke(parser.binding_task());
    }

    fn for_in_iterate(parser: *Parser, state: *ForInStatement) Resumed {
        assert(state.stage == .patterned or state.stage == .initialized);
        assert(parser.position <= parser.count());

        const each = parser.at(.of_keyword);

        if (state.resource) {
            if (parser.at(.in_keyword)) parser.record(.unexpected_token);
        }

        const iterated = parser.eat(.in_keyword) or parser.eat(.of_keyword);

        if (!iterated) parser.record(.unexpected_token);

        state.stage = .subject;

        return parser.call(expression_of(!each));
    }

    fn declares_ahead(parser: *Parser) bool {
        const kind = parser.current() orelse return false;
        if (kind == .let_keyword) return parser.opens_a_binding();
        return declares(kind);
    }

    fn switch_statement_resume(parser: *Parser, state: *SwitchStatement) Resumed {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        switch (state.stage) {
            .start => {
                parser.open(.switch_statement);
                parser.bump();
                state.stage = .subject;

                return parser.call(.{ .parenthesized = .{} });
            },
            .subject => {
                state.stage = .done;

                return parser.call(.{ .switch_body = .{} });
            },
            .done => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn switch_body_resume(parser: *Parser, state: *SwitchBody) Resumed {
        assert(state.iteration <= parser.steps());
        assert(parser.position <= parser.count());

        switch (state.stage) {
            .start => {
                parser.open(.switch_body);
                parser.expect(.brace_open, .unexpected_token);
            },
            .item => if (parser.position == state.before) {
                parser.record(.unexpected_token);
                parser.emit();
            },
        }

        state.stage = .item;

        if (parser.switch_item(state)) |task| return parser.call(task);

        parser.expect(.brace_close, .unmatched_bracket);
        parser.events.finish();

        return .returned;
    }

    fn switch_item(parser: *Parser, state: *SwitchBody) ?Task {
        assert(state.stage == .item);
        assert(state.iteration <= parser.steps());

        if (state.iteration == parser.steps()) return null;

        state.iteration += 1;

        parser.skip_trivia();

        const kind = parser.current() orelse return null;
        if (kind == .brace_close) return null;

        state.before = parser.position;

        return switch (kind) {
            .case_keyword => .{ .switch_case = .{ .kind = .switch_case } },
            .default_keyword => .{ .switch_case = .{ .kind = .switch_default } },
            else => .{ .statement = .{} },
        };
    }

    fn switch_case_resume(parser: *Parser, state: *SwitchCase) Resumed {
        assert(state.kind.is_node());
        assert(state.iteration <= parser.steps());

        switch (state.stage) {
            .start => {
                parser.open(state.kind);
                parser.bump();
                state.stage = .head;

                if (state.kind == .switch_case) return parser.call(expression_of(true));
                return .called;
            },
            .head => parser.expect(.colon, .expected_colon),
            .item => if (parser.position == state.before) {
                parser.record(.unexpected_token);
                parser.emit();
            },
        }

        state.stage = .item;

        if (state.iteration < parser.steps()) {
            state.iteration += 1;

            parser.skip_trivia();

            const kind = parser.current() orelse .brace_close;

            const closes = kind == .brace_close or kind == .case_keyword or
                kind == .default_keyword;

            if (!closes) {
                state.before = parser.position;

                return parser.call(.{ .statement = .{} });
            }
        }

        parser.events.finish();

        return .returned;
    }

    fn try_statement_resume(parser: *Parser, state: *TryStatement) Resumed {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        switch (state.stage) {
            .start => {
                parser.open(.try_statement);
                parser.bump();
                state.stage = .block;

                return parser.call(.{ .statement_block = .{} });
            },
            .block => return parser.try_catch_open(state),
            .caught => {
                state.stage = .typed;

                return parser.invoke(parser.type_annotation_task());
            },
            .typed => {
                parser.expect(.paren_close, .unmatched_bracket);
                state.stage = .handler;

                return parser.call(.{ .statement_block = .{} });
            },
            .handler => {
                parser.events.finish();

                return parser.try_finally_open(state);
            },
            .done => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn try_catch_open(parser: *Parser, state: *TryStatement) Resumed {
        assert(state.stage == .block);
        assert(parser.position <= parser.count());

        if (!parser.at(.catch_keyword)) return parser.try_finally_open(state);

        parser.open(.catch_clause);
        parser.bump();

        if (parser.eat(.paren_open)) {
            state.stage = .caught;

            return parser.invoke(parser.binding_task());
        }

        state.stage = .handler;

        return parser.call(.{ .statement_block = .{} });
    }

    fn try_finally_open(parser: *Parser, state: *TryStatement) Resumed {
        assert(state.stage == .block or state.stage == .handler);
        assert(parser.position <= parser.count());

        const caught = state.stage == .handler;

        state.stage = .done;

        if (parser.at(.finally_keyword)) {
            return parser.call(enclosed(.finally_clause, .statement_block));
        }

        if (!caught) parser.record_expected(.unexpected_token, .finally_keyword);

        return .called;
    }

    fn keyword_statement_resume(parser: *Parser, state: *KeywordStatement) Resumed {
        assert(state.kind == .return_statement or state.kind == .throw_statement);
        assert(parser.position <= parser.count());

        switch (state.stage) {
            .start => {
                parser.open(state.kind);
                parser.bump();
                state.stage = .done;

                if (state.kind == .throw_statement) return parser.call(expression_of(true));
                if (parser.breaks_line()) return .called;
                if (!parser.starts_expression(0)) return .called;
                return parser.call(expression_of(true));
            },
            .done => {
                parser.terminate();
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn labeled_statement_resume(parser: *Parser, state: *LabeledStatement) Resumed {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        switch (state.stage) {
            .start => {
                parser.open(.labeled_statement);
                parser.wrap(.statement_identifier);
                parser.expect(.colon, .expected_colon);
                state.stage = .done;

                return parser.call(.{ .statement = .{} });
            },
            .done => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn import_statement_resume(parser: *Parser, state: *ImportStatement) Resumed {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        switch (state.stage) {
            .start => {
                parser.open(.import_statement);
                parser.bump();
                parser.import_head();
                state.stage = .done;

                return parser.invoke(parser.import_attribute_task());
            },
            .done => {
                parser.terminate();
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn export_statement_resume(parser: *Parser, state: *ExportStatement) Resumed {
        assert(parser.position <= parser.count());
        if (state.stage == .done) assert(state.checkpoint != null);

        switch (state.stage) {
            .start => {
                if (state.checkpoint == null) state.checkpoint = parser.anchor();

                parser.bump();
                state.owes = parser.export_owes();
                state.stage = .done;

                const task = parser.export_task();
                state.trails = parser.export_trails(task);

                return parser.invoke(task);
            },
            .done => {
                if (state.owes) {
                    parser.terminate();
                } else if (state.trails) {
                    _ = parser.eat(.semicolon);
                } else {}

                parser.events.start_at(state.checkpoint.?, .export_statement);
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn export_task(parser: *Parser) ?Task {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        if (parser.typed_star_ahead()) parser.bump();

        if (parser.at(.star)) {
            const sourced = parser.export_star();
            return parser.export_attribute_task(sourced);
        }

        const clause = parser.at(.brace_open) or parser.typed_clause_ahead();

        if (clause) {
            const sourced = parser.export_clause();
            return parser.export_attribute_task(sourced);
        }

        if (parser.at(.default_keyword)) {
            parser.bump();

            return parser.export_default_task();
        }

        if (parser.typed()) {
            if (parser.word("namespace")) {
                if (parser.opens_a_name(1)) return .{ .internal_module = .{} };
            }

            if (parser.at(.equal)) {
                parser.bump();

                return expression_of(false);
            }

            if (parser.namespace_exported()) {
                parser.bump();
                parser.bump();

                if (is_name(parser.current() orelse .error_token)) {
                    parser.wrap(.identifier_node);
                } else {
                    parser.record(.unexpected_token);
                }

                return null;
            }
        }

        if (!parser.exports_a_declaration()) parser.record(.unexpected_token);

        return .{ .statement = .{} };
    }

    fn exports_a_declaration(parser: *Parser) bool {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        const kind = parser.current() orelse return false;

        switch (kind) {
            .at, .class_keyword, .const_keyword, .function_keyword, .let_keyword => return true,
            .var_keyword => return true,
            .async_keyword => return parser.ahead(1) == .function_keyword,
            .import_keyword => return parser.typed(),
            else => {},
        }

        if (!parser.typed()) return false;
        if (parser.word("type")) return parser.opens_an_alias();
        if (parser.word("abstract")) return parser.ahead(1) == .class_keyword;
        if (parser.word("declare")) return true;

        if (parser.word("module")) {
            if (parser.ahead(1) == .string) return true;
        }

        for (exported_words) |text| {
            if (parser.word(text)) return parser.opens_a_name(1);
        }

        return false;
    }

    fn namespace_exported(parser: *Parser) bool {
        assert(parser.position <= parser.count());
        assert(parser.typed());

        if (!parser.word("as")) return false;
        return parser.word_at(parser.ahead_position(1), "namespace");
    }

    fn export_owes(parser: *Parser) bool {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        if (parser.at(.star)) return true;
        if (parser.at(.brace_open)) return true;
        if (parser.typed_clause_ahead()) return true;
        if (parser.typed_star_ahead()) return true;
        if (parser.at(.equal)) return parser.typed();

        if (parser.typed()) {
            if (parser.namespace_exported()) return true;
        }

        if (!parser.at(.default_keyword)) return false;

        const kind = parser.ahead(1) orelse return true;
        const async_function = kind == .async_keyword and parser.ahead(2) == .function_keyword;

        if (kind == .function_keyword) return false;
        if (kind == .class_keyword) return false;
        if (async_function) return false;
        if (!parser.typed()) return true;

        const abstracted = parser.word_at(parser.ahead_position(1), "abstract") and
            parser.ahead(2) == .class_keyword;

        const interfaced = parser.word_at(parser.ahead_position(1), "interface") and
            parser.opens_a_name(2);

        return !abstracted and !interfaced;
    }

    fn export_trails(parser: *Parser, task: ?Task) bool {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        if (task == null) return false;

        const held = task.?;

        return switch (held) {
            .function_expression => true,
            .class => |class| class.kind == .class,
            else => false,
        };
    }

    fn typed_star_ahead(parser: *Parser) bool {
        assert(parser.position <= parser.count());

        if (!parser.typed()) return false;
        if (!parser.word("type")) return false;

        const result = parser.ahead(1) == .star;

        assert(parser.word("type"));

        return result;
    }

    fn typed_clause_ahead(parser: *Parser) bool {
        assert(parser.position <= parser.count());

        if (!parser.typed()) return false;
        if (!parser.word("type")) return false;

        const result = parser.ahead(1) == .brace_open;

        assert(parser.word("type"));

        return result;
    }

    fn export_default_task(parser: *Parser) Task {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        const kind = parser.current() orelse .error_token;
        const async_function = kind == .async_keyword and parser.ahead(1) == .function_keyword;
        const opens_function = kind == .function_keyword or async_function;

        if (opens_function) {
            if (parser.names_a_function()) return .{ .function_declaration = .{} };
            return .{ .function_expression = .{} };
        }

        if (kind == .class_keyword) {
            const named = is_name(parser.ahead(1) orelse .error_token);
            const held: Kind = if (named) .class_declaration else .class;

            return .{ .class = .{ .kind = held } };
        }

        if (parser.typed()) {
            if (parser.word("abstract")) {
                if (parser.ahead(1) == .class_keyword) {
                    return .{ .class = .{
                        .kind = .abstract_class_declaration,
                        .abstracted = true,
                    } };
                }
            }

            if (parser.word("interface")) {
                if (parser.opens_a_name(1)) return .{ .interface_declaration = .{} };
            }
        }

        return expression_of(true);
    }

    fn interface_declaration_resume(parser: *Parser, state: *InterfaceDeclaration) Resumed {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        switch (state.stage) {
            .start => {
                parser.open(.interface_declaration);
                parser.bump();

                if (is_name(parser.current() orelse .error_token)) parser.wrap(.type_identifier);

                state.stage = .typed;

                return parser.invoke(parser.type_parameters_task());
            },
            .typed => {
                state.stage = .extended;

                if (!parser.at(.extends_keyword)) return .called;
                return parser.call(enclosed(.extends_type_clause, .type_list));
            },
            .extended => {
                state.stage = .done;

                return parser.call(.{ .list = .{
                    .kind = .interface_body,
                    .opening = .expect,
                    .closer = .brace_close,
                    .item = .signature,
                    .style = .separator_skips,
                } });
            },
            .done => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn type_alias_resume(parser: *Parser, state: *TypeAlias) Resumed {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        switch (state.stage) {
            .start => {
                parser.open(.type_alias_declaration);
                parser.bump();

                if (is_name(parser.current() orelse .error_token)) parser.wrap(.type_identifier);

                state.stage = .typed;

                return parser.invoke(parser.type_parameters_task());
            },
            .typed => {
                _ = parser.eat(.equal);
                state.stage = .done;

                return parser.call(.{ .type_expression = .{} });
            },
            .done => {
                parser.terminate();
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn enum_declaration_resume(parser: *Parser, state: *EnumDeclaration) Resumed {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        switch (state.stage) {
            .start => {
                parser.open(.enum_declaration);
                _ = parser.eat(.const_keyword);

                parser.bump();

                if (is_name(parser.current() orelse .error_token)) parser.wrap(.identifier_node);

                state.stage = .done;

                return parser.call(.{ .list = .{
                    .kind = .enum_body,
                    .opening = .expect,
                    .closer = .brace_close,
                    .item = .enum_member,
                    .style = .comma_skips,
                } });
            },
            .done => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn enum_member_resume(parser: *Parser, state: *EnumMember) Resumed {
        assert(parser.position <= parser.count());
        if (state.stage != .start) assert(state.checkpoint != null);

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();
                state.stage = .keyed;

                return parser.invoke(parser.property_key_task());
            },
            .keyed => {
                if (!parser.at(.equal)) return .returned;

                parser.bump();
                state.stage = .done;

                return parser.call(expression_required());
            },
            .done => {
                parser.events.start_at(state.checkpoint.?, .enum_assignment);
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn ambient_declaration_resume(parser: *Parser, state: *AmbientDeclaration) Resumed {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        switch (state.stage) {
            .start => {
                parser.open(.ambient_declaration);
                parser.bump();
                state.stage = .done;

                return parser.call(parser.ambient_task());
            },
            .done => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn ambient_task(parser: *Parser) Task {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        if (parser.word("global")) {
            parser.bump();

            return .{ .statement_block = .{} };
        }

        if (parser.word("type")) {
            if (parser.opens_a_name(1)) {
                if (parser.starts_line(parser.ahead_position(1))) parser.record(.unexpected_token);

                return .{ .type_alias = .{} };
            }
        }

        if (parser.word("module")) {
            if (parser.opens_a_module(1)) return .{ .module_declaration = .{} };
        }

        if (parser.word("namespace")) {
            if (parser.opens_a_name(1)) return .{ .internal_module = .{} };
        }

        return .{ .statement = .{} };
    }

    fn internal_module_resume(parser: *Parser, state: *InternalModule) Resumed {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        switch (state.stage) {
            .start => {
                parser.open(.internal_module);
                parser.bump();
                state.stage = .named;

                return parser.invoke(parser.module_name_task());
            },
            .named => {
                state.stage = .done;

                return parser.call(.{ .statement_block = .{} });
            },
            .done => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn module_declaration_resume(parser: *Parser, state: *ModuleDeclaration) Resumed {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        switch (state.stage) {
            .start => {
                parser.open(.module);
                parser.bump();
                state.stage = .named;

                return parser.invoke(parser.module_name_task());
            },
            .named => {
                state.stage = .done;

                if (!parser.at(.brace_open)) return .called;
                return parser.call(.{ .statement_block = .{} });
            },
            .done => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn module_name_task(parser: *Parser) ?Task {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        if (parser.at(.string)) {
            parser.wrap(.string_node);

            return null;
        }

        if (parser.at(.brace_open)) return null;
        return .{ .type_reference = .{ .leaf = .identifier_node } };
    }

    fn import_alias_resume(parser: *Parser, state: *ImportAlias) Resumed {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        switch (state.stage) {
            .start => {
                parser.open(.import_alias);
                parser.bump();

                if (is_name(parser.current() orelse .error_token)) parser.wrap(.identifier_node);

                _ = parser.eat(.equal);
                state.stage = .done;

                if (!is_name(parser.current() orelse .error_token)) {
                    parser.record(.expected_identifier);

                    return .called;
                }

                return parser.call(.{ .type_reference = .{ .leaf = .identifier_node } });
            },
            .done => {
                parser.terminate();
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn namespace_statement_resume(parser: *Parser, state: *NamespaceStatement) Resumed {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        switch (state.stage) {
            .start => {
                parser.open(.expression_statement);
                state.stage = .done;

                return parser.call(.{ .internal_module = .{} });
            },
            .done => {
                _ = parser.eat(.semicolon);

                parser.events.finish();

                return .returned;
            },
        }
    }

    fn list_resume(parser: *Parser, state: *List) Resumed {
        assert(is_closer_of_list(state.closer));
        assert(state.iteration <= parser.steps());

        switch (state.stage) {
            .start => {
                if (state.kind != .error_node) parser.open(state.kind);

                switch (state.opening) {
                    .bump => parser.bump(),
                    .eat => _ = parser.eat(opener_of(state.closer)),
                    .expect => parser.expect(opener_of(state.closer), .unexpected_token),
                    .none => {},
                }
            },
            .item => {
                if (parser.position == state.before) parser.record(.unexpected_token);

                state.items += 1;

                if (state.style == .comma_ends) {
                    if (!parser.eat(.comma)) return parser.list_close(state);
                }

                if (parser.position == state.before) parser.emit();

                state.owed = true;
            },
        }

        state.stage = .item;

        for (0..parser.steps()) |_| {
            if (state.iteration == parser.steps()) break;

            state.iteration += 1;

            parser.skip_trivia();

            if (parser.at(state.closer)) break;
            if (parser.current() == null) break;

            if (parser.list_separator(state.style)) {
                if (!state.owed) {
                    if (!list_elides(state)) parser.record(.unexpected_token);
                }

                state.owed = false;

                continue;
            }

            if (state.owed) {
                if (!parser.list_parted(state.style)) parser.record(.unexpected_token);
            }

            state.owed = false;
            state.before = parser.position;

            return parser.invoke(parser.procedure_task(state.item));
        }

        return parser.list_close(state);
    }

    fn list_separator(parser: *Parser, style: Style) bool {
        assert(parser.position <= parser.count());
        assert(parser.current() != null);

        return switch (style) {
            .comma_ends => false,
            .comma_skips => parser.eat(.comma),
            .semicolon_skips => parser.eat(.semicolon),
            .separator_skips => parser.eat(.semicolon) or parser.eat(.comma),
        };
    }

    fn list_parted(parser: *Parser, style: Style) bool {
        assert(parser.position <= parser.count());
        assert(parser.current() != null);

        return switch (style) {
            .comma_ends, .semicolon_skips => true,
            .comma_skips => false,
            .separator_skips => parser.breaks_line(),
        };
    }

    fn list_close(parser: *Parser, state: *const List) Resumed {
        assert(state.stage == .item);
        assert(parser.position <= parser.count());

        if (state.kind == .error_node) return .returned;

        const filled = state.kind == .type_arguments or state.kind == .type_parameters;

        if (filled) {
            if (state.items == 0) parser.record(.expected_type);
        }

        parser.expect(state.closer, .unmatched_bracket);
        parser.events.finish();

        return .returned;
    }

    fn enclosed_resume(parser: *Parser, state: *Enclosed) Resumed {
        assert(state.kind.is_node());
        assert(state.closer.is_token());

        switch (state.stage) {
            .start => {
                parser.open(state.kind);
                parser.bump();
                state.stage = .done;

                return parser.invoke(parser.procedure_task(state.inner));
            },
            .done => {
                if (state.closer != .error_token) parser.expect(state.closer, .unmatched_bracket);

                parser.events.finish();

                return .returned;
            },
        }
    }

    fn procedure_task(parser: *Parser, procedure: Procedure) ?Task {
        assert(parser.position <= parser.count());
        assert(parser.task_count > 0);

        return switch (procedure) {
            .binding_element => .{ .pattern_element = .{ .bound = true } },
            .binding_pattern => parser.binding_element_task(),
            .class_member => .{ .class_member = .{} },
            .enum_member => .{ .enum_member = .{} },
            .expression_decorator => expression_decorated(),
            .expression_single => expression_of(false),
            .heritage_item => .{ .heritage_item = .{} },
            .heritage_list => .{ .comma_list = .{ .item = .heritage_item } },
            .object_binding_member => parser.object_pattern_member_task(true),
            .object_pattern_member => parser.object_pattern_member_task(false),
            .parameter => .{ .parameter = .{} },
            .pattern => parser.pattern_task(),
            .pattern_element => .{ .pattern_element = .{} },
            .signature => parser.signature_task(),
            .statement => .{ .statement = .{} },
            .statement_block => .{ .statement_block = .{} },
            .tuple_member => parser.tuple_member_task(),
            .type_expression => .{ .type_expression = .{} },
            .type_list => .{ .comma_list = .{ .item = .type_expression } },
            .type_operand => parser.type_operand_task(),
            .type_parameter => .{ .type_parameter = .{} },
            .type_predicate => .{ .type_predicate = .{} },
            .variable_declarator => .{ .variable_declarator = .{} },
        };
    }

    fn iteration_target_task(parser: *Parser) ?Task {
        assert(parser.position <= parser.count());
        assert(parser.task_count > 0);

        const kind = parser.current() orelse return null;
        const position = parser.significant(parser.position);

        switch (kind) {
            .brace_open, .bracket_open => {
                const after = parser.significant(parser.balanced_end(position));
                if (iterates_over(parser.kind_at(after))) return parser.pattern_task();
            },
            else => if (is_name(kind)) {
                if (iterates_over(parser.ahead(1))) return parser.pattern_task();
            },
        }

        return expression_iterated();
    }

    fn pattern_task(parser: *Parser) ?Task {
        return parser.pattern_named(.undefined, false);
    }

    fn binding_task(parser: *Parser) ?Task {
        return parser.pattern_named(.identifier_node, true);
    }

    fn binding_element_task(parser: *Parser) ?Task {
        return parser.pattern_named(.undefined, true);
    }

    fn pattern_named(parser: *Parser, undefined_leaf: Kind, bound: bool) ?Task {
        assert(parser.position <= parser.count());
        assert(parser.task_count > 0);
        assert(undefined_leaf == .undefined or undefined_leaf == .identifier_node);
        if (undefined_leaf == .identifier_node) assert(bound);

        const kind = parser.current() orelse return null;
        const rest: Procedure = if (bound) .binding_pattern else .pattern;

        switch (kind) {
            .brace_open, .bracket_open => {
                if (bound) return pattern_nested(kind, bound);
                if (!parser.literal_reached()) return pattern_nested(kind, bound);
            },
            .dot_dot_dot => return enclosed(.rest_pattern, rest),
            else => {},
        }

        const reached = reaches(parser.ahead(1));
        const asserted = !bound and parser.assertion_ahead();
        const bare = bound or (!reached and !asserted);

        if (is_name(kind)) {
            if (bare) {
                parser.wrap(if (kind == .undefined_keyword) undefined_leaf else .identifier_node);

                return null;
            }
        }

        if (!parser.starts_expression(0)) parser.record(.expected_identifier);

        return expression_of(false);
    }

    fn literal_reached(parser: *Parser) bool {
        assert(parser.position <= parser.count());
        assert(parser.at(.brace_open) or parser.at(.bracket_open));

        const position = parser.significant(parser.position);
        const after = parser.significant(parser.balanced_end(position));

        assert(after > position);

        return reaches(parser.kind_at(after));
    }

    fn assertion_ahead(parser: *Parser) bool {
        assert(parser.position <= parser.count());
        assert(parser.significant_next <= parser.count());

        if (!parser.typed()) return false;
        if (parser.ahead(1) == .bang) return true;

        const position = parser.ahead_position(1);
        return parser.word_at(position, "as") or parser.word_at(position, "satisfies");
    }

    fn pattern_element_resume(parser: *Parser, state: *PatternElement) Resumed {
        assert(parser.position <= parser.count());
        if (state.stage != .start) assert(state.checkpoint != null);

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();
                state.before = parser.position;
                state.stage = .patterned;

                return parser.invoke(parser.pattern_named(.undefined, state.bound));
            },
            .patterned => {
                if (parser.position == state.before) parser.record(.expected_identifier);
                if (!parser.at(.equal)) return .returned;

                parser.events.start_at(state.checkpoint.?, .assignment_pattern);
                parser.bump();
                state.stage = .done;

                return parser.call(expression_required());
            },
            .done => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn object_pattern_member_task(parser: *Parser, bound: bool) ?Task {
        assert(parser.position <= parser.count());
        assert(parser.task_count > 0);

        const kind = parser.current() orelse return null;
        const rest: Procedure = if (bound) .binding_pattern else .pattern;
        if (kind == .dot_dot_dot) return enclosed(.rest_pattern, rest);
        return .{ .object_pattern_member = .{ .bound = bound } };
    }

    fn object_pattern_member_resume(parser: *Parser, state: *ObjectPatternMember) Resumed {
        assert(parser.position <= parser.count());
        if (state.stage != .start) assert(state.checkpoint != null);

        switch (state.stage) {
            .start => {
                const bracketed = parser.at(.bracket_open);

                state.checkpoint = parser.anchor();

                const paired = parser.key_ends_at_colon() or bracketed;

                if (paired) {
                    parser.open(.pair_pattern);
                    state.stage = .keyed;

                    return parser.invoke(parser.property_key_task());
                }

                if (!is_name(parser.current() orelse .error_token)) {
                    parser.record(.expected_identifier);
                }

                parser.wrap(.shorthand_property_identifier_pattern);

                if (!parser.at(.equal)) return .returned;

                parser.events.start_at(state.checkpoint.?, .object_assignment_pattern);
                parser.bump();
                state.stage = .done;

                return parser.call(expression_required());
            },
            .keyed => {
                parser.expect(.colon, .expected_colon);
                state.stage = .done;

                return parser.call(.{ .pattern_element = .{ .bound = state.bound } });
            },
            .done => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn property_key_task(parser: *Parser) ?Task {
        assert(parser.position <= parser.count());
        assert(parser.task_count > 0);

        const kind = parser.current() orelse return null;

        switch (kind) {
            .bracket_open => {
                return enclosed_closed(.computed_property_name, .expression_single, .bracket_close);
            },
            .string => parser.wrap(.string_node),
            .number => parser.wrap(.number_node),
            .private_identifier => parser.wrap(.private_property_identifier),
            else => if (is_property_name(kind)) {
                parser.wrap(.property_identifier);
            } else {
                parser.record(.expected_identifier);
            },
        }

        return null;
    }

    fn method_definition_resume(parser: *Parser, state: *MethodDefinition) Resumed {
        assert(parser.position <= parser.count());
        if (state.stage != .start) assert(state.checkpoint != null);

        switch (state.stage) {
            .start => {
                if (state.checkpoint == null) state.checkpoint = parser.anchor();

                const start = parser.position;

                state.abstracted = parser.modifiers();
                state.stage = .keyed;

                const prefix = parser.raw[start..parser.position];

                state.awaits = std.mem.findScalar(Kind, prefix, .async_keyword) != null;
                state.generator = std.mem.findScalar(Kind, prefix, .star) != null;

                if (parser.word_between(start, parser.position, "declare")) {
                    parser.record(.unexpected_token);
                }

                return parser.invoke(parser.property_key_task());
            },
            .keyed => {
                _ = parser.eat(.question);
                state.stage = .typed;

                return parser.invoke(parser.type_parameters_task());
            },
            .typed => {
                state.stage = .parameters;

                return parser.call(formal_parameters_of());
            },
            .parameters => {
                state.stage = .annotated;

                return parser.invoke(parser.return_annotation_task());
            },
            .annotated => return parser.method_body_open(state),
            .done => {
                parser.events.start_at(state.checkpoint.?, .method_definition);
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn method_body_open(parser: *Parser, state: *MethodDefinition) Resumed {
        assert(state.stage == .annotated);
        assert(state.checkpoint != null);

        if (!parser.at(.brace_open)) {
            const signature_refused = state.literal or !parser.typed();

            if (signature_refused) parser.record(.unexpected_token);

            const kind: Kind = if (state.abstracted)
                .abstract_method_signature
            else
                .method_signature;

            parser.events.start_at(state.checkpoint.?, kind);
            parser.events.finish();
            parser.terminate();

            return .returned;
        }

        if (state.abstracted) parser.record(.unexpected_token);

        state.stage = .done;

        return parser.call(.{ .statement_block = .{} });
    }

    fn parameter_resume(parser: *Parser, state: *Parameter) Resumed {
        assert(parser.position <= parser.count());
        if (state.stage != .start) assert(state.checkpoint != null);

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();
                state.stage = .modified;

                return parser.call(.{ .parameter_modifiers = .{} });
            },
            .modified => {
                state.stage = .patterned;

                if (!parser.binding_ahead()) parser.record(.expected_identifier);

                return parser.invoke(parser.binding_element_task());
            },
            .patterned => {
                state.optional = parser.at(.question);

                if (state.optional) parser.bump();

                state.stage = .annotated;

                return parser.invoke(parser.type_annotation_task());
            },
            .annotated => {
                state.stage = .done;
                state.defaulted = parser.eat(.equal);

                if (state.defaulted) return parser.call(expression_required());
                return .called;
            },
            .done => {
                if (!parser.typed()) {
                    if (!state.defaulted) return .returned;

                    parser.events.start_at(state.checkpoint.?, .assignment_pattern);
                    parser.events.finish();

                    return .returned;
                }

                const kind: Kind = if (state.optional)
                    .optional_parameter
                else
                    .required_parameter;

                parser.events.start_at(state.checkpoint.?, kind);
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn parameter_modifiers_resume(parser: *Parser, state: *ParameterModifiers) Resumed {
        assert(state.iteration <= modifier_step_max);
        assert(parser.position <= parser.count());

        for (0..modifier_step_max) |_| {
            if (state.iteration == modifier_step_max) break;

            state.iteration += 1;

            if (parser.at(.at)) {
                state.start = position_none;

                return parser.call(enclosed(.decorator, .expression_decorator));
            }

            if (!parser.typed()) break;

            if (state.start == position_none) state.start = parser.position;

            if (parser.accessibility_here()) {
                parser.wrap(.accessibility_modifier);

                continue;
            }

            if (parser.word("override")) {
                if (!parser.opens_a_type()) {
                    parser.wrap(.override_modifier);

                    continue;
                }
            }

            if (!parser.word("readonly")) break;
            if (parser.opens_a_type()) break;

            parser.bump();
        }

        if (state.start != position_none) {
            if (parser.modifiers_repeated(state.start)) parser.record(.unexpected_token);
        }

        return .returned;
    }

    fn type_expression_resume(parser: *Parser, state: *TypeExpression) Resumed {
        assert(parser.nesting <= nest_depth_max);
        if (state.stage == .done) assert(parser.nesting > 0);

        switch (state.stage) {
            .start => {
                if (parser.nesting >= nest_depth_max) {
                    parser.outcome = .too_deep;

                    parser.emit();

                    return .returned;
                }

                parser.nesting += 1;
                state.stage = .done;

                return parser.call(.{ .type_conditional = .{} });
            },
            .done => {
                parser.nesting -= 1;

                return .returned;
            },
        }
    }

    fn type_conditional_resume(parser: *Parser, state: *TypeConditional) Resumed {
        assert(parser.position <= parser.count());
        if (state.stage != .start) assert(state.checkpoint != null);

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();
                state.stage = .checked;

                return parser.call(.{ .type_union = .{} });
            },
            .checked => {
                if (!parser.at(.extends_keyword)) return .returned;
                if (parser.breaks_line()) return .returned;

                parser.bump();
                state.stage = .extended;

                return parser.call(.{ .type_union = .{} });
            },
            .extended => {
                state.stage = .done;

                if (!parser.eat(.question)) return .called;

                state.stage = .consequent;

                return parser.call(.{ .type_expression = .{} });
            },
            .consequent => {
                _ = parser.eat(.colon);
                state.stage = .done;

                return parser.call(.{ .type_expression = .{} });
            },
            .done => {
                parser.events.start_at(state.checkpoint.?, .conditional_type);
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn type_union_resume(parser: *Parser, state: *TypeUnion) Resumed {
        assert(state.iteration <= parser.steps());
        if (state.stage == .member) assert(state.checkpoint != null);

        switch (state.stage) {
            .start => {
                if (parser.word("readonly")) {
                    state.stage = .done;

                    return parser.call(.{ .readonly_type = .{} });
                }

                state.checkpoint = parser.anchor();
                state.leading = parser.eat(.bar);
                state.stage = .first;

                return parser.call(.{ .type_intersection = .{} });
            },
            .first => if (state.leading) parser.wrap_at(state.checkpoint.?, .union_type),
            .member => parser.wrap_at(state.checkpoint.?, .union_type),
            .readonly => {
                parser.wrap_at(state.checkpoint.?, .union_type);

                return .returned;
            },
            .done => return .returned,
        }

        if (state.iteration == parser.steps()) return .returned;

        state.iteration += 1;

        if (!parser.at(.bar)) return .returned;

        parser.bump();

        if (parser.word("readonly")) {
            state.stage = .readonly;

            return parser.call(.{ .readonly_type = .{} });
        }

        state.stage = .member;

        return parser.call(.{ .type_intersection = .{} });
    }

    fn readonly_type_resume(parser: *Parser, state: *ReadonlyType) Resumed {
        assert(parser.nesting <= nest_depth_max);
        if (state.stage == .done) assert(parser.nesting > 0);

        switch (state.stage) {
            .start => {
                if (parser.nesting >= nest_depth_max) {
                    parser.outcome = .too_deep;

                    parser.emit();

                    return .returned;
                }

                state.checkpoint = parser.anchor();
                parser.nesting += 1;

                parser.bump();
                state.stage = .done;

                return parser.call(.{ .type_union = .{} });
            },
            .done => {
                parser.nesting -= 1;

                parser.wrap_at(state.checkpoint.?, .readonly_type);

                return .returned;
            },
        }
    }

    fn type_intersection_resume(parser: *Parser, state: *TypeIntersection) Resumed {
        assert(state.iteration <= parser.steps());
        if (state.stage != .start) assert(state.checkpoint != null);

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();
                state.leading = parser.eat(.ampersand);
                state.stage = .first;

                return parser.invoke(parser.type_operand_task());
            },
            .first => if (state.leading) parser.wrap_at(state.checkpoint.?, .intersection_type),
            .member => parser.wrap_at(state.checkpoint.?, .intersection_type),
        }

        if (state.iteration == parser.steps()) return .returned;

        state.iteration += 1;

        if (!parser.at(.ampersand)) return .returned;

        parser.bump();
        state.stage = .member;

        return parser.invoke(parser.type_operand_task());
    }

    fn type_operand_task(parser: *Parser) ?Task {
        assert(parser.position <= parser.count());
        assert(parser.task_count > 0);

        if (parser.word("keyof")) return enclosed(.index_type_query, .type_operand);
        if (parser.word("readonly")) return enclosed(.readonly_type, .type_operand);
        if (parser.word("infer")) return .{ .infer_type = .{} };
        if (parser.at(.typeof_keyword)) return .{ .type_query = .{} };

        if (parser.word("unique")) {
            if (parser.word_at(parser.ahead_position(1), "symbol")) {
                const checkpoint = parser.anchor();

                parser.bump();
                parser.bump();
                parser.wrap_at(checkpoint, .predefined_type);

                return null;
            }
        }

        if (parser.at(.new_keyword)) {
            return .{ .function_type = .{
                .kind = .constructor_type,
                .bumped = true,
                .generic = true,
            } };
        }

        if (parser.word("abstract")) {
            if (parser.ahead(1) == .new_keyword) {
                return .{ .function_type = .{
                    .kind = .constructor_type,
                    .abstracted = true,
                    .bumped = true,
                    .generic = true,
                } };
            }
        }

        return .{ .type_postfix = .{} };
    }

    fn infer_type_resume(parser: *Parser, state: *InferType) Resumed {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        switch (state.stage) {
            .start => {
                const infer_at = parser.significant(parser.position);

                parser.open(.infer_type);
                parser.bump();

                if (is_name(parser.current() orelse .error_token)) parser.wrap(.type_identifier);

                state.stage = .done;

                if (!parser.at(.extends_keyword)) return .called;
                if (!parser.infer_constrained(infer_at)) return .called;

                parser.bump();

                return parser.call(.{ .type_union = .{} });
            },
            .done => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn infer_constrained(parser: *Parser, infer_at: u32) bool {
        assert(parser.at(.extends_keyword));
        assert(infer_at < parser.position);

        if (parser.infer_disallowed(infer_at)) return true;
        return !parser.infer_questioned(parser.significant(parser.position));
    }

    fn infer_disallowed(parser: *Parser, infer_at: u32) bool {
        assert(infer_at < parser.count());
        assert(parser.raw.len == parser.tokens.len);

        var depth: u32 = 0;
        var position = infer_at;

        for (0..scan_step_max) |_| {
            if (position == 0) return false;

            position -= 1;

            const kind = parser.raw[position];
            if (is_layout(kind)) continue;

            const closes = is_closer(kind) or kind == .greater;

            if (closes) {
                depth += 1;

                continue;
            }

            const opens = is_opener(kind) or kind == .less;

            if (opens) {
                if (depth == 0) return false;

                depth -= 1;

                continue;
            }

            if (depth > 0) continue;

            switch (kind) {
                .extends_keyword => return true,
                .arrow, .colon, .comma, .equal, .question, .semicolon => return false,
                else => {},
            }
        }

        return false;
    }

    fn infer_questioned(parser: *Parser, extends_at: u32) bool {
        assert(extends_at < parser.count());
        assert(parser.raw[extends_at] == .extends_keyword);

        var angles: u32 = 0;
        var position = parser.significant(extends_at + 1);

        for (0..scan_step_max) |_| {
            const kind = parser.kind_at(position) orelse return false;

            if (is_opener(kind)) {
                position = parser.significant(parser.balanced_end(position));

                continue;
            }

            switch (kind) {
                .less => angles += 1,
                .greater => {
                    if (angles == 0) return false;

                    angles -= 1;
                },
                .question => {
                    const after = parser.significant(position + 1);
                    const next = parser.kind_at(after) orelse return false;

                    if (angles == 0) {
                        if (!ends_a_nullable(next)) return true;
                    }
                },
                .arrow, .brace_close, .bracket_close, .colon, .comma, .equal => {
                    if (angles == 0) return false;
                },
                .paren_close, .semicolon => return false,
                else => {},
            }

            position = parser.significant(position + 1);
        }

        return false;
    }

    fn type_query_resume(parser: *Parser, state: *TypeQuery) Resumed {
        assert(parser.position <= parser.count());
        if (state.stage != .start) assert(state.target != null);

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();

                parser.open(.type_query);
                parser.bump();
                state.target = parser.anchor();
                state.stage = .targeted;

                return parser.call(.{ .query_target = .{} });
            },
            .targeted => {
                state.stage = .closed;

                if (!parser.at(.less)) return .called;
                if (parser.breaks_line()) return .called;
                if (!parser.type_arguments_ahead()) return .called;

                state.stage = .instantiated;

                return parser.invoke(parser.type_arguments_task());
            },
            .instantiated => {
                parser.wrap_at(state.target.?, .instantiation_expression);
                state.stage = .closed;

                return .called;
            },
            .closed => {
                parser.events.finish();
                state.stage = .done;

                return parser.call(.{ .type_trailers = .{ .checkpoint = state.checkpoint.? } });
            },
            .done => return .returned,
        }
    }

    fn function_type_resume(parser: *Parser, state: *FunctionType) Resumed {
        assert(state.kind == .function_type or state.kind == .constructor_type);
        assert(parser.position <= parser.count());

        switch (state.stage) {
            .start => {
                parser.open(state.kind);

                if (state.abstracted) parser.bump();
                if (state.bumped) parser.bump();

                state.stage = .typed;

                if (!state.generic) return .called;
                return parser.invoke(parser.type_parameters_task());
            },
            .typed => {
                state.stage = .parameters;

                return parser.call(formal_parameters_of());
            },
            .parameters => {
                _ = parser.eat(.arrow);
                state.stage = .done;

                return parser.invoke(parser.type_return_task());
            },
            .done => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn type_postfix_resume(parser: *Parser, state: *TypePostfix) Resumed {
        assert(parser.position <= parser.count());
        if (state.stage != .start) assert(state.checkpoint != null);

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();
                state.stage = .primary;

                return parser.invoke(parser.type_primary_task());
            },
            .primary => {
                state.stage = .done;

                return parser.call(.{ .type_trailers = .{ .checkpoint = state.checkpoint.? } });
            },
            .done => return .returned,
        }
    }

    fn type_trailers_resume(parser: *Parser, state: *TypeTrailers) Resumed {
        assert(state.iteration <= parser.steps());

        if (state.stage == .lookup) {
            parser.expect(.bracket_close, .unmatched_bracket);
            parser.wrap_at(state.checkpoint, .lookup_type);
        }

        for (0..parser.steps()) |_| {
            if (state.iteration == parser.steps()) return .returned;

            state.iteration += 1;

            if (!parser.at(.bracket_open)) return .returned;
            if (parser.breaks_line()) return .returned;

            parser.bump();

            if (!parser.eat(.bracket_close)) {
                state.stage = .lookup;

                return parser.call(.{ .type_expression = .{} });
            }

            parser.wrap_at(state.checkpoint, .array_type);
        }

        return .returned;
    }

    fn type_primary_task(parser: *Parser) ?Task {
        assert(parser.position <= parser.count());
        assert(parser.task_count > 0);

        const kind = parser.current() orelse {
            parser.record(.expected_type);

            return null;
        };

        switch (kind) {
            .paren_open => return parser.type_paren_task(),
            .less => return .{ .function_type = .{
                .kind = .function_type,
                .generic = true,
            } },
            .brace_open => return .{ .list = .{
                .kind = .object_type,
                .opening = .bump,
                .closer = .brace_close,
                .item = .signature,
                .style = .separator_skips,
            } },
            .bracket_open => return .{ .list = .{
                .kind = .tuple_type,
                .opening = .bump,
                .closer = .bracket_close,
                .item = .tuple_member,
                .style = .comma_ends,
            } },
            else => {},
        }

        return parser.type_leaf_task(kind);
    }

    fn type_leaf_task(parser: *Parser, kind: Kind) ?Task {
        assert(kind.is_token());
        assert(parser.current() == kind);

        switch (kind) {
            .this_keyword => parser.wrap(.this_type),
            .star => parser.wrap(.existential_type),
            .template_start => return .{ .template_literal_type = .{} },
            .question => return enclosed(.flow_maybe_type, .type_operand),
            .minus, .plus => parser.literal_signed(),
            .import_keyword => return .{ .type_import = .{} },
            else => return parser.type_word_task(kind),
        }

        return null;
    }

    fn type_word_task(parser: *Parser, kind: Kind) ?Task {
        assert(kind.is_token());
        assert(parser.current() == kind);

        if (is_literal_type(kind)) {
            parser.open(.literal_type);
            parser.wrap(expression.literal_kind(kind));
            parser.events.finish();

            return null;
        }

        const named = is_name(kind) or kind == .void_keyword;
        if (named) return .{ .type_reference = .{ .leaf = .type_identifier } };

        parser.record(.expected_type);
        parser.emit();

        return null;
    }

    fn literal_signed(parser: *Parser) void {
        assert(parser.at(.minus) or parser.at(.plus));
        assert(parser.position <= parser.count());

        parser.open(.literal_type);
        parser.open(.unary_expression);
        parser.bump();

        if (parser.at(.number)) parser.wrap(.number_node);

        parser.events.finish();
        parser.events.finish();
    }

    fn type_paren_task(parser: *Parser) Task {
        assert(parser.at(.paren_open));
        assert(parser.position <= parser.count());

        if (lookahead.function_type_ahead(parser, parser.significant(parser.position))) {
            return .{ .function_type = .{ .kind = .function_type } };
        }

        return enclosed_closed(.parenthesized_type, .type_expression, .paren_close);
    }

    fn type_import_resume(parser: *Parser, state: *TypeImport) Resumed {
        assert(parser.position <= parser.count());
        if (state.stage != .start) assert(state.checkpoint != null);

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();
                state.stage = .targeted;

                return parser.call(.{ .query_target = .{} });
            },
            .targeted => {
                if (!parser.at(.less)) return .returned;
                if (parser.breaks_line()) return .returned;
                if (!parser.type_arguments_ahead()) return .returned;

                state.stage = .done;

                return parser.invoke(parser.type_arguments_task());
            },
            .done => {
                parser.wrap_at(state.checkpoint.?, .generic_type);

                return .returned;
            },
        }
    }

    fn type_reference_resume(parser: *Parser, state: *TypeReference) Resumed {
        assert(state.leaf == .type_identifier or state.leaf == .identifier_node);
        assert(parser.position <= parser.count());

        switch (state.stage) {
            .start => {
                if (state.leaf == .type_identifier) {
                    const position = parser.significant(parser.position);

                    const predefined = predefined_of(parser.text_at(position)) or
                        parser.at(.void_keyword);

                    if (predefined) {
                        parser.wrap(.predefined_type);

                        return .returned;
                    }
                }

                state.checkpoint = parser.anchor();

                parser.type_segments(state.checkpoint.?, state.leaf);

                if (!parser.at(.less)) return .returned;
                if (parser.breaks_line()) return .returned;
                if (!parser.type_arguments_ahead()) return .returned;

                state.stage = .done;

                return parser.invoke(parser.type_arguments_task());
            },
            .done => {
                parser.wrap_at(state.checkpoint.?, .generic_type);

                return .returned;
            },
        }
    }

    fn type_segments(parser: *Parser, checkpoint: Checkpoint, leaf: Kind) void {
        assert(leaf.is_node());
        assert(checkpoint.index <= parser.events.count());

        const segments = lookahead.segments_ahead(parser);
        const type_leaf = leaf == .type_identifier;

        parser.wrap(if (segments == 1) leaf else .identifier_node);

        var index: u32 = 1;

        while (index < segments) : (index += 1) {
            parser.bump();

            if (index + 1 == segments) {
                if (type_leaf) {
                    parser.wrap(.type_identifier);
                    parser.wrap_at(checkpoint, .nested_type_identifier);

                    continue;
                }
            }

            parser.wrap(.property_identifier);

            const inner = if (type_leaf) index + 2 < segments else index + 1 < segments;

            parser.wrap_at(checkpoint, if (inner) .member_expression else .nested_identifier);
        }
    }

    fn query_target_resume(parser: *Parser, state: *QueryTarget) Resumed {
        assert(parser.position <= parser.count());
        if (state.stage != .start) assert(state.checkpoint != null);

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();

                if (parser.at(.import_keyword)) {
                    parser.wrap(.import_node);

                    if (parser.at(.paren_open)) {
                        state.stage = .called;

                        return parser.call(argument_list_of());
                    }

                    parser.query_trailers(state.checkpoint.?);

                    return .returned;
                }

                if (parser.at(.this_keyword)) {
                    parser.wrap(.this);
                    parser.query_trailers(state.checkpoint.?);

                    return .returned;
                }

                if (!is_property_name(parser.current() orelse .error_token)) return .returned;

                parser.wrap(.identifier_node);
                parser.query_trailers(state.checkpoint.?);

                return .returned;
            },
            .called => {
                parser.wrap_at(state.checkpoint.?, .call_expression);
                parser.query_trailers(state.checkpoint.?);

                return .returned;
            },
        }
    }

    fn type_parameter_resume(parser: *Parser, state: *TypeParameter) Resumed {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        switch (state.stage) {
            .start => {
                parser.open(.type_parameter);
                parser.type_parameter_modifiers();

                if (is_name(parser.current() orelse .error_token)) parser.wrap(.type_identifier);

                state.stage = .constrained;

                if (!parser.at(.extends_keyword)) return .called;
                return parser.call(enclosed(.constraint, .type_expression));
            },
            .constrained => {
                state.stage = .done;

                if (!parser.at(.equal)) return .called;
                return parser.call(enclosed(.default_type, .type_expression));
            },
            .done => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn tuple_member_task(parser: *Parser) Task {
        assert(parser.position <= parser.count());
        assert(parser.task_count > 0);

        if (lookahead.labelled_ahead(parser)) return .{ .parameter = .{} };
        if (parser.at(.dot_dot_dot)) return enclosed(.rest_type, .type_expression);
        return .{ .optional_type = .{} };
    }

    fn optional_type_resume(parser: *Parser, state: *OptionalType) Resumed {
        assert(parser.position <= parser.count());
        if (state.stage != .start) assert(state.checkpoint != null);

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();
                state.stage = .typed;

                return parser.call(.{ .type_expression = .{} });
            },
            .typed => {
                if (parser.at(.question)) {
                    parser.bump();
                    parser.wrap_at(state.checkpoint.?, .optional_type);
                }

                return .returned;
            },
        }
    }

    fn signature_task(parser: *Parser) Task {
        assert(parser.position <= parser.count());
        assert(parser.task_count > 0);

        if (lookahead.mapped_modifier_ahead(parser)) return .{ .index_signature = .{} };

        if (parser.at(.bracket_open)) {
            if (lookahead.index_signature_ahead(parser)) return .{ .index_signature = .{} };
        }

        if (lookahead.readonly_index_ahead(parser)) return .{ .index_signature = .{} };

        const property: Task = .{ .signature_member = .{ .property = .property_signature } };

        if (parser.at(.new_keyword)) {
            const after = parser.ahead(1);
            const called = after == .less or after == .paren_open;
            if (!called) return property;
            return .{ .call_signature = .{ .kind = .construct_signature, .bumped = true } };
        }

        if (parser.at(.paren_open)) return .{ .call_signature = .{ .kind = .call_signature } };
        if (parser.at(.less)) return .{ .call_signature = .{ .kind = .call_signature } };
        return property;
    }

    fn call_signature_resume(parser: *Parser, state: *CallSignature) Resumed {
        assert(state.kind == .call_signature or state.kind == .construct_signature);
        assert(parser.position <= parser.count());

        switch (state.stage) {
            .start => {
                parser.open(state.kind);

                if (state.bumped) parser.bump();

                state.stage = .typed;

                return parser.invoke(parser.type_parameters_task());
            },
            .typed => {
                state.stage = .parameters;

                return parser.call(formal_parameters_of());
            },
            .parameters => {
                state.stage = .done;

                return parser.invoke(parser.return_annotation_task());
            },
            .done => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn signature_member_resume(parser: *Parser, state: *SignatureMember) Resumed {
        assert(state.property.is_node());
        if (state.stage != .start) assert(state.checkpoint != null);

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();
                state.modified = parser.position;
                _ = parser.modifiers();
                state.keyed = parser.position;
                state.stage = .keyed;

                return parser.invoke(parser.property_key_task());
            },
            .keyed => {
                _ = parser.eat(.question);

                const called = parser.at(.paren_open) or parser.at(.less);

                if (called) {
                    state.stage = .typed;

                    return parser.invoke(parser.type_parameters_task());
                }

                if (parser.modifiers_methodic(state.modified, state.keyed)) {
                    parser.record(.unexpected_token);
                }

                state.stage = .annotated;

                return parser.invoke(parser.type_annotation_task());
            },
            .typed => {
                state.stage = .parameters;

                return parser.call(formal_parameters_of());
            },
            .parameters => {
                state.stage = .method;

                return parser.invoke(parser.return_annotation_task());
            },
            .method => {
                parser.wrap_at(state.checkpoint.?, .method_signature);

                return .returned;
            },
            .annotated => {
                parser.wrap_at(state.checkpoint.?, state.property);

                return .returned;
            },
        }
    }

    fn index_signature_resume(parser: *Parser, state: *IndexSignature) Resumed {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        switch (state.stage) {
            .start => return parser.index_signature_open(state),
            .mapped => {
                state.stage = .remapped;

                if (!parser.eat_word("as")) return .called;
                return parser.call(.{ .type_expression = .{} });
            },
            .remapped => {
                parser.events.finish();
                state.stage = .keyed;

                return .called;
            },
            .keyed => return parser.index_signature_annotate(state),
            .annotated => {
                parser.events.finish();
                parser.events.finish();

                return .returned;
            },
            .done => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn index_signature_open(parser: *Parser, state: *IndexSignature) Resumed {
        assert(state.stage == .start);
        assert(parser.position <= parser.count());

        parser.open(.index_signature);

        if (lookahead.mapped_modifier_ahead(parser)) {
            parser.bump();
            parser.bump();
        } else {
            for (0..modifier_words.len) |_| {
                if (parser.at(.bracket_open)) break;
                if (!parser.modifier_at(parser.significant(parser.position))) break;

                parser.bump();
            }
        }

        parser.bump();

        if (lookahead.mapped_ahead(parser)) {
            parser.open(.mapped_type_clause);

            if (is_name(parser.current() orelse .error_token)) parser.wrap(.type_identifier);

            _ = parser.eat(.in_keyword);
            state.stage = .mapped;

            return parser.call(.{ .type_expression = .{} });
        }

        if (is_name(parser.current() orelse .error_token)) parser.wrap(.identifier_node);

        state.stage = .keyed;

        if (!parser.eat(.colon)) return .called;
        return parser.call(.{ .type_expression = .{} });
    }

    fn index_signature_typed(parser: *Parser) Resumed {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        if (parser.eat(.colon)) return parser.call(.{ .type_expression = .{} });

        const kind = parser.current() orelse return .called;
        const closed = kind == .brace_close or kind == .semicolon or kind == .comma;

        if (!closed) parser.record(.expected_colon);

        return .called;
    }

    fn index_signature_annotate(parser: *Parser, state: *IndexSignature) Resumed {
        assert(state.stage == .keyed);
        assert(parser.position <= parser.count());

        if (parser.at(.comma)) {
            if (parser.ahead(1) == .bracket_close) parser.bump();
        }

        if (lookahead.index_parameter_ahead(parser)) {
            parser.bump();
            parser.wrap(.identifier_node);
            parser.bump();

            return parser.call(.{ .type_expression = .{} });
        }

        parser.expect(.bracket_close, .unmatched_bracket);

        const signed = parser.at(.minus) or parser.at(.plus);

        if (signed) {
            if (parser.ahead(1) == .question) {
                const kind: Kind = if (parser.at(.plus))
                    .adding_type_annotation
                else
                    .omitting_type_annotation;

                parser.open(kind);
                parser.bump();
                parser.bump();
                state.stage = .annotated;

                return parser.index_signature_typed();
            }
        }

        if (parser.at(.question)) {
            parser.open(.opting_type_annotation);
            parser.bump();
            state.stage = .annotated;

            return parser.index_signature_typed();
        }

        state.stage = .done;

        return parser.invoke(parser.type_annotation_task());
    }

    fn template_literal_type_resume(parser: *Parser, state: *TemplateLiteralType) Resumed {
        assert(state.iteration <= parser.steps());
        assert(parser.position <= parser.count());

        if (state.stage == .start) {
            parser.open(.template_literal_type);
            parser.bump();
            state.stage = .chars;
        }

        for (0..parser.steps()) |_| {
            if (state.iteration == parser.steps()) break;

            state.iteration += 1;

            const kind = parser.current() orelse {
                parser.record_expected(.unmatched_bracket, .template_end);

                break;
            };

            if (kind == .template_end) {
                parser.bump();

                break;
            }

            if (kind == .substitution_start) {
                return parser.call(enclosed_closed(.template_type, .type_expression, .brace_close));
            }

            parser.bump();
        }

        parser.events.finish();

        return .returned;
    }

    fn type_annotation_task(parser: *Parser) ?Task {
        assert(parser.position <= parser.count());
        assert(parser.task_count > 0);

        if (!parser.typed()) return null;
        if (!parser.at(.colon)) return null;
        return enclosed(.type_annotation, .type_expression);
    }

    fn return_annotation_task(parser: *Parser) ?Task {
        assert(parser.position <= parser.count());
        assert(parser.task_count > 0);

        if (!parser.typed()) return null;
        if (!parser.at(.colon)) return null;

        const after = parser.ahead_position(1);

        if (parser.word_at(after, "asserts")) {
            if (parser.asserts_lined(parser.significant(after + 1))) {
                return .{ .asserts = .{ .annotated = true } };
            }
        }

        if (parser.predicate_ahead(after)) {
            return enclosed(.type_predicate_annotation, .type_predicate);
        }

        return parser.type_annotation_task();
    }

    fn type_return_task(parser: *Parser) Task {
        assert(parser.position <= parser.count());
        assert(parser.task_count > 0);

        if (parser.predicate_ahead(parser.significant(parser.position))) {
            return .{ .type_predicate = .{} };
        }

        if (parser.word("asserts")) {
            if (parser.asserts_lined(parser.ahead_position(1))) return .{ .asserts = .{} };
        }

        return .{ .type_expression = .{} };
    }

    fn asserts_resume(parser: *Parser, state: *Asserts) Resumed {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        switch (state.stage) {
            .start => {
                if (state.annotated) {
                    parser.open(.asserts_annotation);
                    parser.bump();
                }

                parser.open(.asserts);
                parser.bump();
                state.stage = .done;

                if (parser.predicate_asserted(parser.significant(parser.position))) {
                    return parser.call(.{ .type_predicate = .{} });
                }

                const kind = parser.current() orelse .error_token;

                if (kind == .this_keyword) {
                    if (state.annotated) parser.wrap(.this);
                }

                if (is_name(kind)) parser.wrap(.identifier_node);

                return .called;
            },
            .done => {
                parser.events.finish();

                if (state.annotated) parser.events.finish();

                return .returned;
            },
        }
    }

    fn type_predicate_resume(parser: *Parser, state: *TypePredicate) Resumed {
        assert(parser.position <= parser.count());
        assert(parser.nesting <= nest_depth_max);

        switch (state.stage) {
            .start => {
                parser.open(.type_predicate);

                const kind = parser.current() orelse .error_token;

                if (kind == .this_keyword) parser.wrap(.this);
                if (is_name(kind)) parser.wrap(.identifier_node);

                _ = parser.eat_word("is");
                state.stage = .done;

                return parser.call(.{ .type_expression = .{} });
            },
            .done => {
                parser.events.finish();

                return .returned;
            },
        }
    }

    fn type_arguments_task(parser: *Parser) ?Task {
        assert(parser.position <= parser.count());
        assert(parser.task_count > 0);

        if (!parser.at(.less)) return null;

        return .{ .list = .{
            .kind = .type_arguments,
            .opening = .bump,
            .closer = .greater,
            .item = .type_expression,
            .style = .comma_ends,
        } };
    }

    fn type_parameters_task(parser: *Parser) ?Task {
        assert(parser.position <= parser.count());
        assert(parser.task_count > 0);

        if (!parser.typed()) return null;
        if (!parser.at(.less)) return null;

        return .{ .list = .{
            .kind = .type_parameters,
            .opening = .bump,
            .closer = .greater,
            .item = .type_parameter,
            .style = .comma_ends,
        } };
    }

    fn jsx_resume(parser: *Parser, state: *Jsx) Resumed {
        assert(parser.nesting <= nest_depth_max);
        if (state.stage == .done) assert(parser.nesting > 0);

        switch (state.stage) {
            .start => {
                if (parser.nesting >= nest_depth_max) {
                    parser.outcome = .too_deep;

                    parser.emit();

                    return .returned;
                }

                parser.nesting += 1;
                state.stage = .done;

                return parser.call(.{ .jsx_element = .{} });
            },
            .done => {
                parser.nesting -= 1;

                return .returned;
            },
        }
    }

    fn jsx_element_resume(parser: *Parser, state: *JsxElement) Resumed {
        assert(parser.position <= parser.count());
        if (state.stage != .start) assert(state.checkpoint != null);

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();

                parser.bump();
                parser.jsx_element_name();
                state.stage = .typed;

                return parser.invoke(parser.type_arguments_task());
            },
            .typed => {
                state.stage = .attributed;

                return parser.call(.{ .jsx_attributes = .{} });
            },
            .attributed => {
                if (parser.eat(.jsx_tag_end_self)) {
                    parser.wrap_at(state.checkpoint.?, .jsx_self_closing_element);

                    return .returned;
                }

                parser.expect(.jsx_tag_end, .unexpected_token);
                parser.wrap_at(state.checkpoint.?, .jsx_opening_element);
                state.stage = .children;

                return parser.call(.{ .jsx_children = .{} });
            },
            .children => {
                parser.jsx_closing_element();
                parser.wrap_at(state.checkpoint.?, .jsx_element);

                return .returned;
            },
        }
    }

    fn jsx_attributes_resume(parser: *Parser, state: *JsxAttributes) Resumed {
        assert(state.iteration <= parser.steps());
        assert(parser.position <= parser.count());

        if (state.iteration == parser.steps()) return .returned;

        state.iteration += 1;

        const kind = parser.current() orelse return .returned;

        return switch (kind) {
            .brace_open => parser.call(.{ .jsx_expression = .{} }),
            .identifier => parser.call(.{ .jsx_attribute = .{} }),
            else => .returned,
        };
    }

    fn jsx_attribute_resume(parser: *Parser, state: *JsxAttribute) Resumed {
        assert(parser.position <= parser.count());
        if (state.stage != .start) assert(state.checkpoint != null);

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();

                parser.jsx_attribute_name();
                state.stage = .done;

                if (!parser.eat(.equal)) return .called;
                return parser.invoke(parser.jsx_attribute_value_task());
            },
            .done => {
                parser.wrap_at(state.checkpoint.?, .jsx_attribute);

                return .returned;
            },
        }
    }

    fn jsx_attribute_value_task(parser: *Parser) ?Task {
        assert(parser.position <= parser.count());
        assert(parser.task_count > 0);

        const kind = parser.current() orelse .error_token;

        switch (kind) {
            .brace_open => return .{ .jsx_expression = .{ .valued = true } },
            .jsx_tag_start => return .{ .jsx = .{} },
            .string => parser.wrap(.string_node),
            else => parser.record(.expected_expression),
        }

        return null;
    }

    fn jsx_expression_resume(parser: *Parser, state: *JsxExpression) Resumed {
        assert(parser.position <= parser.count());
        if (state.stage != .start) assert(state.checkpoint != null);

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();

                parser.bump();
                state.stage = .done;

                if (parser.at(.brace_close)) return .called;

                if (parser.at(.dot_dot_dot)) {
                    if (!state.valued) return parser.call(expression_spread());
                }

                return parser.call(expression_of(true));
            },
            .done => {
                parser.expect(.brace_close, .unmatched_bracket);
                parser.wrap_at(state.checkpoint.?, .jsx_expression);

                return .returned;
            },
        }
    }

    fn jsx_children_resume(parser: *Parser, state: *JsxChildren) Resumed {
        assert(state.iteration <= loop_step_max);
        assert(parser.position <= parser.count());

        for (0..parser.steps()) |_| {
            if (state.iteration == loop_step_max) return .returned;

            state.iteration += 1;

            const kind = parser.current() orelse return .returned;

            switch (kind) {
                .brace_open => return parser.call(.{ .jsx_expression = .{} }),
                .jsx_chars => parser.wrap(.jsx_text),
                .jsx_entity => parser.bump(),
                .jsx_tag_start => return parser.call(.{ .jsx = .{} }),
                else => return .returned,
            }
        }

        return .called;
    }

    fn expression_resume(parser: *Parser, state: *Expression) Resumed {
        assert(parser.frame_count <= expression.depth_max);
        if (state.stage != .start) assert(parser.frame_count > state.frames_base);

        stage: switch (state.stage) {
            .start => {
                if (!parser.expression_start(state)) return .returned;

                continue :stage .machine;
            },
            .machine => {
                if (state.iteration == loop_step_max) continue :stage .finished;

                state.iteration += 1;
                state.before = parser.progress();
                state.stage = .stepped;

                const advance = if (state.operand)
                    parser.operand_step(state.frames_base)
                else
                    parser.operator_step_of(state);

                if (parser.advance_apply(state, advance)) |resumed| return resumed;

                continue :stage .stepped;
            },
            .stepped => {
                parser.pending_apply(state);

                if (parser.returned != .done) {
                    state.operand = parser.returned == .operand;

                    continue :stage .checked;
                }

                if (!state.operand) continue :stage .finished;

                state.stage = .fallback;

                const advance = parser.operator_step_of(state);
                if (parser.advance_apply(state, advance)) |resumed| return resumed;

                continue :stage .fallback;
            },
            .fallback => {
                parser.pending_apply(state);

                if (parser.returned == .done) continue :stage .finished;

                state.operand = parser.returned == .operand;

                continue :stage .checked;
            },
            .checked => {
                if (parser.progressed(state.before)) continue :stage .machine;

                continue :stage .finished;
            },
            .finished => {
                parser.expression_close(state);
                parser.required_check(state);

                return .returned;
            },
        }
    }

    fn expression_start(parser: *Parser, state: *Expression) bool {
        assert(state.stage == .start);
        assert(parser.frame_count <= expression.depth_max);

        if (state.required) state.significant_before = parser.significant(parser.position);
        if (parser.expression_open(state)) return true;

        parser.required_check(state);

        return false;
    }

    fn advance_apply(parser: *Parser, state: *Expression, advance: Advance) ?Resumed {
        assert(state.pending == .none);
        assert(parser.frame_count > state.frames_base);
        if (advance == .call) assert(advance.call.task != .statements);

        switch (advance) {
            .step => |step| {
                parser.returned = step;

                return null;
            },
            .call => |held| {
                state.pending = held.pending;

                return parser.call(held.task);
            },
        }
    }

    fn pending_apply(parser: *Parser, state: *Expression) void {
        assert(state.stage == .stepped or state.stage == .fallback);
        assert(parser.frame_count > state.frames_base);

        switch (state.pending) {
            .arrow_block => |checkpoint| {
                parser.push_value(checkpoint);
                parser.reduce_top();
                parser.returned = .operator;
                parser.sealed = parser.significant(parser.position);
            },
            .none => {},
            .step => |step| parser.returned = step,
            .value => |checkpoint| {
                parser.push_value(checkpoint);
                parser.returned = .operator;
            },
        }

        state.pending = .none;
    }

    fn expression_open(parser: *Parser, state: *Expression) bool {
        assert(state.stage == .start);
        assert(parser.frame_count <= expression.depth_max);

        state.frames_base = parser.frame_count;
        state.values_base = parser.value_count;

        const checkpoint = parser.anchor();
        var frame: Frame = .empty;

        frame.checkpoint = checkpoint;
        frame.content = checkpoint;
        frame.element = checkpoint;
        frame.element_values = parser.value_count;
        frame.spreads = state.spread;
        frame.stage = @intFromBool(state.sequence);
        frame.values = parser.value_count;
        frame.variant = .top;

        if (!parser.push_frame(frame)) return false;

        assert(parser.frame_count == state.frames_base + 1);

        return true;
    }

    fn expression_close(parser: *Parser, state: *const Expression) void {
        assert(parser.frame_count > state.frames_base);
        assert(parser.frame_count <= expression.depth_max);

        parser.reduce_above(state.frames_base + 1);

        const top = parser.frames[state.frames_base];

        assert(top.variant == .top);

        parser.frame_count = state.frames_base;

        if (top.elements > 0) {
            if (parser.value_count == top.element_values) parser.record(.expected_expression);

            parser.wrap_at(top.checkpoint.?, .sequence_expression);
        }

        parser.value_count = state.values_base;
    }

    fn required_check(parser: *Parser, state: *const Expression) void {
        assert(parser.frame_count == state.frames_base);
        assert(parser.position <= parser.count());

        if (!state.required) return;

        if (parser.significant(parser.position) == state.significant_before) {
            parser.record(.expected_expression);
        }
    }

    fn operand_step(parser: *Parser, base: u32) Advance {
        assert(base < parser.frame_count);
        assert(parser.frame_count <= expression.depth_max);

        parser.skip_trivia();

        const kind = parser.current() orelse return .{ .step = .done };
        const top = parser.frames[parser.frame_count - 1];

        if (top.variant == .arrow) {
            if (kind == .brace_open) {
                const checkpoint = parser.anchor();
                const pending: Pending = .{ .arrow_block = checkpoint };

                return .{ .call = .{ .task = .{ .statement_block = .{} }, .pending = pending } };
            }
        }

        const group = parser.innermost_group(base);
        const frame = parser.frames[group];
        if (frame.variant == .template) return .{ .step = parser.template_piece(group, kind) };

        if (frame.variant == .object) {
            if (parser.frame_count == group + 1) {
                if (parser.value_count == frame.element_values) return parser.object_member(kind);
            }
        }

        return parser.operand_of(kind);
    }

    fn operand_of(parser: *Parser, kind: Kind) Advance {
        assert(kind.is_token());
        assert(parser.current() == kind);

        switch (kind) {
            .slash, .slash_equal => parser.slash_misread(true),
            else => {},
        }

        if (parser.constructs_refused(kind)) parser.record(.unexpected_token);

        if (parser.operand_angle(kind)) |advance| return advance;

        if (kind == .dot_dot_dot) {
            if (!parser.spread_allowed()) parser.record(.unexpected_token);

            return parser.unary(.spread_element, expression.power_spread);
        }

        if (is_prefix(kind)) return parser.unary(.unary_expression, expression.power_unary);

        switch (kind) {
            .minus_minus, .plus_plus => {
                return parser.unary(.update_expression, expression.power_unary);
            },
            .await_keyword => {
                if (parser.ahead(1) == .arrow) return parser.operand_group(kind);
                if (!parser.starts_expression(1)) return .{ .step = parser.identifier_operand() };

                if (parser.name_continues()) {
                    if (!parser.context_here().awaits) {
                        return .{ .step = parser.identifier_operand() };
                    }
                }

                return parser.unary(.await_expression, expression.power_unary);
            },
            .yield_keyword => {
                if (parser.ahead(1) == .arrow) return parser.operand_group(kind);

                if (!parser.context_here().yields) {
                    if (parser.yield_named()) return .{ .step = parser.identifier_operand() };
                }

                return .{ .step = parser.yield_operand() };
            },
            .new_keyword => return .{ .step = parser.new_operand() },
            .import_keyword => return .{ .step = parser.import_operand() },
            .function_keyword => return parser.valued(.{ .function_expression = .{} }),
            .async_keyword => {
                if (parser.ahead(1) == .function_keyword) {
                    return parser.valued(.{ .function_expression = .{} });
                }
            },
            .class_keyword => return parser.valued(.{ .class = .{ .kind = .class } }),
            .at => return parser.valued(.{ .decorated = .{ .expression = true } }),
            else => {},
        }

        return parser.operand_group(kind);
    }

    fn operand_angle(parser: *Parser, kind: Kind) ?Advance {
        assert(kind.is_token());
        assert(parser.current() == kind);

        if (kind == .less) {
            if (parser.generic_arrow_ahead()) {
                if (!parser.assignment_operand()) parser.record(.unexpected_token);

                return .{ .call = .{ .task = .{ .generic_arrow = .{} }, .pending = .none } };
            }

            if (parser.dialect == .typescript) {
                if (parser.type_arguments_ahead()) return parser.type_assertion();
            }
        }

        if (kind != .jsx_tag_start) return null;
        return parser.valued(.{ .jsx = .{} });
    }

    fn operand_group(parser: *Parser, kind: Kind) Advance {
        assert(kind.is_token());
        assert(parser.current() == kind);

        if (parser.opens_an_arrow(kind)) {
            if (!parser.assignment_operand()) parser.record(.unexpected_token);

            return .{ .call = .{ .task = .{ .arrow_head = .{} }, .pending = .none } };
        }

        switch (kind) {
            .paren_open => {
                const checkpoint = parser.anchor();
                return .{ .step = parser.open_group(.paren, checkpoint) };
            },
            .bracket_open => return parser.operand_pattern(.array),
            .brace_open => return parser.operand_pattern(.object),
            .template_start => return .{ .step = parser.open_template(null) },
            .private_identifier => {
                if (parser.ahead(1) != .in_keyword) parser.record(.unexpected_token);

                return .{ .step = parser.leaf_operand(.private_property_identifier) };
            },
            else => {},
        }

        if (is_literal(kind)) {
            return .{ .step = parser.leaf_operand(expression.literal_kind(kind)) };
        }

        if (is_name(kind)) return .{ .step = parser.identifier_operand() };
        return .{ .step = .done };
    }

    fn leaf_operand(parser: *Parser, kind: Kind) Step {
        assert(kind.is_node());
        assert(parser.current() != null);

        const checkpoint = parser.anchor();

        parser.wrap(kind);
        parser.push_value(checkpoint);

        return .operator;
    }

    fn valued(parser: *Parser, task: Task) Advance {
        assert(parser.current() != null);
        assert(parser.frame_count > 0);
        assert(task == .class or task == .decorated or task == .function_expression or
            task == .jsx or task == .method_definition);

        const checkpoint = parser.anchor();
        return .{ .call = .{ .task = task, .pending = .{ .value = checkpoint } } };
    }

    fn operand_pattern(parser: *Parser, variant: Variant) Advance {
        assert(variant == .array or variant == .object);
        assert(parser.current() != null);

        if (parser.assigned_ahead(parser.significant(parser.position))) {
            const checkpoint = parser.anchor();
            const task = parser.pattern_task() orelse return .{ .step = .done };

            return .{ .call = .{ .task = task, .pending = .{ .value = checkpoint } } };
        }

        const checkpoint = parser.anchor();
        return .{ .step = parser.open_group(variant, checkpoint) };
    }

    fn type_assertion(parser: *Parser) Advance {
        assert(parser.at(.less));
        assert(parser.frame_count > 0);

        var frame: Frame = .empty;

        frame.checkpoint = parser.anchor();
        frame.kind = .type_assertion;
        frame.power = expression.power_unary;
        frame.values = parser.value_count;
        frame.variant = .unary;

        if (!parser.push_frame(frame)) return .{ .step = .done };

        const task = parser.type_arguments_task() orelse return .{ .step = .operand };
        return .{ .call = .{ .task = task, .pending = .{ .step = .operand } } };
    }

    fn object_member(parser: *Parser, kind: Kind) Advance {
        assert(kind.is_token());
        assert(parser.current() == kind);

        if (kind == .dot_dot_dot) return parser.unary(.spread_element, expression.power_spread);

        if (parser.method_ahead()) {
            return parser.valued(.{ .method_definition = .{ .literal = true } });
        }

        if (!opens_a_key(kind)) return parser.operand_of(kind);

        const checkpoint = parser.anchor();
        const colon = parser.key_ends_at_colon();

        if (!colon) {
            if (is_name(kind)) {
                parser.wrap(.shorthand_property_identifier);
                parser.push_value(checkpoint);

                return .{ .step = .operator };
            }
        }

        const task: Task = .{ .object_key = .{ .checkpoint = checkpoint } };
        return .{ .call = .{ .task = task, .pending = .none } };
    }

    fn object_key_resume(parser: *Parser, state: *ObjectKey) Resumed {
        assert(parser.frame_count > 0);

        switch (state.stage) {
            .start => {
                state.stage = .keyed;

                return parser.invoke(parser.property_key_task());
            },
            .keyed => {
                parser.returned = parser.object_pair(state.checkpoint);

                return .returned;
            },
        }
    }

    fn object_pair(parser: *Parser, checkpoint: Checkpoint) Step {
        assert(parser.frame_count > 0);
        assert(checkpoint.index <= parser.events.count());

        if (!parser.at(.colon)) {
            parser.record(.expected_colon);
            parser.push_value(checkpoint);

            return .operator;
        }

        var frame: Frame = .empty;

        frame.checkpoint = checkpoint;
        frame.kind = .pair;
        frame.power = expression.power_barrier;
        frame.values = parser.value_count;
        frame.variant = .pair;

        if (!parser.push_frame(frame)) return .done;

        parser.bump();

        return .operand;
    }

    fn generic_arrow_resume(parser: *Parser, state: *GenericArrow) Resumed {
        assert(parser.frame_count > 0);
        if (state.stage != .start) assert(state.checkpoint != null);

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();
                state.stage = .typed;

                return parser.invoke(parser.type_parameters_task());
            },
            .typed => {
                state.stage = .parameters;

                return parser.call(formal_parameters_of());
            },
            .parameters => {
                state.stage = .done;

                return parser.invoke(parser.return_annotation_task());
            },
            .done => {
                if (!parser.at(.arrow)) parser.record_expected(.unexpected_token, .arrow);

                parser.push_value(state.checkpoint.?);
                parser.returned = .operator;
                parser.arrow_awaits = false;
                parser.arrowed = parser.significant(parser.position);

                return .returned;
            },
        }
    }

    fn arrow_head_resume(parser: *Parser, state: *ArrowHead) Resumed {
        assert(parser.frame_count > 0);
        if (state.stage != .start) assert(state.checkpoint != null);

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();

                if (parser.at(.async_keyword)) {
                    state.awaits = parser.ahead(1) != .arrow;

                    if (state.awaits) parser.bump();
                }

                state.stage = .typed;

                return parser.invoke(parser.type_parameters_task());
            },
            .typed => {
                state.stage = .done;

                if (!parser.at(.paren_open)) {
                    parser.wrap(.identifier_node);

                    return .called;
                }

                state.stage = .parameters;

                return parser.call(formal_parameters_of());
            },
            .parameters => {
                state.stage = .annotated;

                return parser.invoke(parser.return_annotation_task());
            },
            .annotated => {
                state.stage = .done;

                return .called;
            },
            .done => {
                if (!parser.at(.arrow)) parser.record_expected(.unexpected_token, .arrow);

                parser.push_value(state.checkpoint.?);
                parser.returned = .operator;
                parser.arrow_awaits = state.awaits;
                parser.arrowed = parser.significant(parser.position);

                return .returned;
            },
        }
    }

    fn type_operation_resume(parser: *Parser, state: *TypeOperation) Resumed {
        assert(state.kind == .as_expression or state.kind == .satisfies_expression);

        switch (state.stage) {
            .start => {
                state.stage = .done;

                if (parser.at(.const_keyword)) {
                    parser.bump();

                    return .called;
                }

                return parser.call(.{ .type_expression = .{} });
            },
            .done => {
                parser.wrap_at(state.checkpoint, state.kind);
                parser.returned = .operator;

                return .returned;
            },
        }
    }

    fn type_argument_trailer_resume(parser: *Parser, state: *TypeArgumentTrailer) Resumed {
        assert(parser.frame_count > 0);

        switch (state.stage) {
            .start => {
                state.stage = .done;

                return parser.invoke(parser.type_arguments_task());
            },
            .done => {
                parser.returned = .operator;

                const kind = parser.current() orelse .error_token;
                if (kind == .paren_open) return .returned;
                if (kind == .template_start) return .returned;
                if (parser.frames[parser.frame_count - 1].kind == .new_expression) return .returned;

                const member_follows = kind == .dot or kind == .question_dot;

                if (member_follows) parser.record(.unexpected_token);

                assert(parser.value_count > 0);

                parser.value_count -= 1;

                parser.wrap_at(state.checkpoint, .instantiation_expression);
                parser.push_value(state.checkpoint);

                return .returned;
            },
        }
    }

    fn operator_step_of(parser: *Parser, state: *const Expression) Advance {
        assert(parser.frame_count > state.frames_base);
        assert(parser.frame_count <= expression.depth_max);

        if (state.decorated) {
            if (parser.decorator_ended(state.frames_base)) return .{ .step = .done };
        }

        if (state.iterated) {
            if (parser.iteration_ended(state.frames_base)) return .{ .step = .done };
        }

        return parser.operator_step(state.frames_base);
    }

    fn iteration_ended(parser: *Parser, base: u32) bool {
        assert(base < parser.frame_count);
        assert(parser.frame_count <= expression.depth_max);

        parser.skip_trivia();

        if (parser.innermost_group(base) != base) return false;
        return parser.at(.in_keyword);
    }

    fn decorator_ended(parser: *Parser, base: u32) bool {
        assert(base < parser.frame_count);
        assert(parser.frame_count <= expression.depth_max);

        parser.skip_trivia();

        if (parser.innermost_group(base) != base) return false;

        const kind = parser.current() orelse return false;

        return switch (kind) {
            .dot, .paren_open, .question_dot, .template_start => false,
            .bang => !parser.typed(),
            .less => !parser.typed() or !parser.call_arguments_ahead(),
            else => true,
        };
    }

    fn operator_step(parser: *Parser, base: u32) Advance {
        assert(base < parser.frame_count);
        assert(parser.frame_count <= expression.depth_max);

        parser.skip_trivia();

        const kind = parser.current() orelse return .{ .step = .done };
        const group = parser.innermost_group(base);
        const frame = parser.frames[group];
        if (frame.variant == .template) return .{ .step = parser.template_piece(group, kind) };

        if (frame.is_bracketed()) {
            if (kind == frame.closer) {
                parser.close_group(group);

                return .{ .step = .operator };
            }
        }

        if (parser.sealed == parser.significant(parser.position)) {
            switch (kind) {
                .colon, .comma => {},
                else => return .{ .step = .done },
            }
        }

        switch (kind) {
            .comma => return .{ .step = parser.comma(group) },
            .dot, .question_dot => return parser.member_trailer(kind),
            .paren_open => return .{ .step = parser.call_trailer() },
            .bracket_open => return .{ .step = parser.subscript_trailer() },
            .template_start => return .{ .step = parser.tagged_template() },
            .minus_minus, .plus_plus => return .{ .step = parser.postfix_update() },
            else => {},
        }

        if (parser.typed_operator(kind)) |advance| return advance;
        return .{ .step = parser.operator_plain(kind, base) };
    }

    fn operator_plain(parser: *Parser, kind: Kind, base: u32) Step {
        assert(kind.is_token());
        assert(base < parser.frame_count);

        switch (kind) {
            .question => return parser.ternary(),
            .colon => return parser.ternary_else(base),
            .arrow => return parser.arrow_body(),
            .regex => {
                parser.slash_misread(false);

                return .done;
            },
            .greater => {
                if (parser.joined(parser.significant(parser.position))) return parser.shift();
            },
            else => {},
        }

        const binding = expression.infix_of(kind) orelse return .done;
        return parser.binary(binding);
    }

    fn typed_operator(parser: *Parser, kind: Kind) ?Advance {
        assert(kind.is_token());
        assert(parser.frame_count > 0);

        if (!parser.typed()) return null;
        if (kind == .bang) return .{ .step = parser.non_null() };

        const operation = parser.word("as") or parser.word("satisfies");

        if (operation) {
            if (parser.breaks_line()) return .{ .step = .done };
            return parser.type_operation();
        }

        if (kind == .less) {
            if (parser.call_arguments_ahead()) return parser.type_argument_trailer();
        }

        return null;
    }

    fn type_operation(parser: *Parser) Advance {
        assert(parser.word("as") or parser.word("satisfies"));
        assert(parser.frame_count > 0);

        parser.reduce_for(expression.power_relational_left);

        if (!parser.operand_held()) return .{ .step = .done };

        const satisfies = parser.word("satisfies");
        const checkpoint = parser.values[parser.value_count - 1];
        const kind: Kind = if (satisfies) .satisfies_expression else .as_expression;

        parser.bump();

        const task: Task = .{ .type_operation = .{ .checkpoint = checkpoint, .kind = kind } };
        return .{ .call = .{ .task = task, .pending = .none } };
    }

    fn type_argument_trailer(parser: *Parser) Advance {
        assert(parser.at(.less));
        assert(parser.frame_count > 0);

        if (!parser.operand_held()) return .{ .step = .done };

        const checkpoint = parser.values[parser.value_count - 1];
        const task: Task = .{ .type_argument_trailer = .{ .checkpoint = checkpoint } };

        return .{ .call = .{ .task = task, .pending = .none } };
    }

    fn unary(parser: *Parser, kind: Kind, power: u8) Advance {
        assert(kind.is_node());
        assert(power > expression.power_barrier);

        var frame: Frame = .empty;

        frame.checkpoint = parser.anchor();
        frame.kind = kind;
        frame.power = power;
        frame.values = parser.value_count;
        frame.variant = .unary;

        if (!parser.push_frame(frame)) return .{ .step = .done };

        parser.bump();

        return .{ .step = .operand };
    }

    fn binary(parser: *Parser, binding: expression.Binding) Step {
        assert(binding.kind.is_node());
        assert(binding.left > expression.power_barrier);

        parser.reduce_for(binding.left);

        if (!parser.operand_held()) {
            parser.record(.expected_expression);
            parser.bump();

            return .operand;
        }

        if (!parser.binary_placed(binding.kind)) parser.record(.unexpected_token);

        const values = parser.value_count - 1;
        var frame: Frame = .empty;

        frame.checkpoint = parser.values[values];
        frame.kind = binding.kind;
        frame.power = binding.right;
        frame.values = values;
        frame.variant = .binary;

        if (!parser.push_frame(frame)) return .done;

        parser.bump();

        return .operand;
    }

    fn assignment_operand(parser: *const Parser) bool {
        assert(parser.frame_count > 0);
        assert(parser.frame_count <= expression.depth_max);

        const top = &parser.frames[parser.frame_count - 1];

        return switch (top.variant) {
            .argument, .array, .object, .paren, .subscript, .substitution, .template, .top => true,
            .arrow, .pair, .ternary => true,
            .binary => switch (top.kind) {
                .assignment_expression, .augmented_assignment_expression => true,
                else => false,
            },
            .unary => switch (top.kind) {
                .spread_element, .yield_expression => true,
                else => false,
            },
        };
    }

    fn binding_ahead(parser: *Parser) bool {
        assert(parser.position <= parser.count());
        assert(parser.significant_next <= parser.count());

        const kind = parser.current() orelse return false;
        if (is_name(kind)) return true;
        if (kind == .this_keyword) return parser.typed();

        return switch (kind) {
            .brace_open, .bracket_open, .dot_dot_dot => true,
            else => false,
        };
    }

    fn spread_allowed(parser: *const Parser) bool {
        assert(parser.frame_count > 0);
        assert(parser.frame_count <= expression.depth_max);

        const top = &parser.frames[parser.frame_count - 1];

        switch (top.variant) {
            .argument, .array, .object => {},
            .top => if (!top.spreads) return false,
            else => return false,
        }

        return parser.value_count == top.element_values;
    }

    fn constructs_refused(parser: *const Parser, kind: Kind) bool {
        assert(kind.is_token());
        assert(parser.frame_count > 0);

        const top = &parser.frames[parser.frame_count - 1];
        if (top.variant != .unary) return false;
        if (top.kind != .new_expression) return false;
        if (parser.value_count != top.values) return false;
        if (is_prefix(kind)) return true;

        return switch (kind) {
            .await_keyword, .dot_dot_dot, .minus_minus, .plus_plus, .yield_keyword => true,
            else => false,
        };
    }

    fn object_trailed(parser: *const Parser) bool {
        assert(parser.frame_count > 0);
        assert(parser.frame_count <= expression.depth_max);

        return parser.frames[parser.frame_count - 1].variant == .object;
    }

    fn super_before(parser: *Parser) bool {
        assert(parser.position > 0);
        assert(parser.position <= parser.count());

        var scan = parser.position;

        while (scan > 0) {
            scan -= 1;

            if (is_layout(parser.raw[scan])) continue;
            return parser.raw[scan] == .super_keyword;
        }

        return false;
    }

    fn binary_placed(parser: *const Parser, kind: Kind) bool {
        assert(kind.is_node());
        assert(parser.frame_count > 0);

        const assigning = kind == .assignment_expression or
            kind == .augmented_assignment_expression;

        const top = &parser.frames[parser.frame_count - 1];
        if (!assigning) return top.variant != .object;
        if (parser.value_count == 0) return true;
        return parser.reduced != parser.value_count - 1;
    }

    fn operand_held(parser: *const Parser) bool {
        assert(parser.frame_count > 0);
        assert(parser.frame_count <= expression.depth_max);

        const top = &parser.frames[parser.frame_count - 1];
        if (top.is_group()) return parser.value_count > top.element_values;
        return parser.value_count >= top.values + @max(owed_of(top), 1);
    }

    fn open_group(parser: *Parser, variant: Variant, checkpoint: Checkpoint) Step {
        assert(variant != .top);

        const opener = parser.current() orelse .paren_open;
        const bracket = parser.anchor();

        parser.bump();

        const content = parser.anchor();
        var frame: Frame = .empty;

        frame.bracket = bracket;
        frame.checkpoint = checkpoint;
        frame.closer = expression.closer_of(opener);

        if (opener == .substitution_start) frame.closer = .brace_close;

        frame.content = content;
        frame.element = content;
        frame.element_values = parser.value_count;
        frame.kind = variant.group_kind();
        frame.values = parser.value_count;
        frame.variant = variant;

        if (!parser.push_frame(frame)) return .done;
        return .operand;
    }

    fn close_group(parser: *Parser, group: u32) void {
        assert(group < parser.frame_count);
        assert(parser.frames[group].is_bracketed());

        parser.reduce_above(group + 1);

        const frame = parser.frames[group];

        if (frame.variant == .paren) {
            if (parser.value_count == frame.values) parser.record(.expected_expression);
        }

        const holds = frame.variant == .substitution or frame.variant == .subscript;

        if (holds) {
            if (parser.value_count == frame.element_values) parser.record(.expected_expression);
        }

        parser.frame_count = group;

        if (frame.variant == .argument) {
            parser.events.start_at(frame.checkpoint.?, frame.kind);
            parser.events.start_at(frame.bracket.?, .arguments);
            parser.bump();
            parser.events.finish();
        } else {
            const sequenced = frame.variant == .paren or frame.variant == .substitution;

            if (sequenced) {
                if (frame.elements > 0) parser.wrap_at(frame.content.?, .sequence_expression);
            }

            parser.events.start_at(frame.checkpoint.?, frame.kind);
            parser.bump();
        }

        parser.events.finish();
        parser.value_count = frame.values;

        parser.push_value(frame.checkpoint.?);
    }

    fn comma(parser: *Parser, group: u32) Step {
        assert(group < parser.frame_count);
        assert(parser.at(.comma));

        const frame = parser.frames[group];

        if (frame.variant == .top) {
            if (frame.stage == 0) return .done;
        }

        parser.reduce_above(group + 1);

        if (frame.variant != .array) {
            if (parser.value_count == frame.element_values) parser.record(.expected_expression);
        }

        parser.bump();

        const held = &parser.frames[group];

        held.elements += 1;
        held.element = parser.anchor();
        parser.value_count = held.values;
        held.element_values = parser.value_count;

        return .operand;
    }

    fn member_trailer(parser: *Parser, kind: Kind) Advance {
        assert(kind == .dot or kind == .question_dot);
        assert(parser.frame_count > 0);

        if (!parser.operand_held()) return .{ .step = .done };

        if (parser.object_trailed()) parser.record(.unexpected_token);

        if (kind == .question_dot) {
            if (parser.super_before()) parser.record(.unexpected_token);
            if (parser.member_optional()) |advance| return advance;
        }

        const checkpoint = parser.values[parser.value_count - 1];

        parser.reduced = position_none;

        parser.events.start_at(checkpoint, .member_expression);

        if (kind == .question_dot) {
            parser.open(.optional_chain);
            parser.bump();
            parser.events.finish();
        } else {
            parser.bump();
        }

        const held = parser.current() orelse .error_token;

        if (held == .private_identifier) {
            parser.wrap(.private_property_identifier);
        } else {
            if (is_property_name(held)) {
                parser.wrap(.property_identifier);
            } else {
                parser.record(.expected_identifier);
            }
        }

        parser.events.finish();

        return .{ .step = .operator };
    }

    fn member_optional(parser: *Parser) ?Advance {
        assert(parser.at(.question_dot));
        assert(parser.value_count > 0);

        const after = parser.ahead(1);

        if (after == .bracket_open) {
            parser.open(.optional_chain);
            parser.bump();
            parser.events.finish();

            return .{ .step = parser.subscript_trailer() };
        }

        if (after == .paren_open) {
            if (parser.typed()) {
                parser.bump();
            } else {
                parser.open(.optional_chain);
                parser.bump();
                parser.events.finish();
            }

            return .{ .step = parser.call_trailer() };
        }

        if (after == .less) {
            if (parser.call_arguments_ahead_at(parser.ahead_position(1))) {
                parser.bump();

                return parser.type_argument_trailer();
            }
        }

        return null;
    }

    fn call_trailer(parser: *Parser) Step {
        assert(parser.at(.paren_open));
        assert(parser.frame_count > 0);

        if (!parser.operand_held()) return .done;

        if (parser.object_trailed()) parser.record(.unexpected_token);

        const checkpoint = parser.values[parser.value_count - 1];

        parser.value_count -= 1;

        const top = parser.frames[parser.frame_count - 1];

        const constructing = top.variant == .unary and top.kind == .new_expression and
            top.stage == 1 and parser.value_count == top.values;

        if (constructing) {
            parser.frame_count -= 1;

            const step = parser.open_group(.argument, top.checkpoint.?);

            parser.frames[parser.frame_count - 1].kind = .new_expression;

            return step;
        }

        const step = parser.open_group(.argument, checkpoint);

        parser.frames[parser.frame_count - 1].kind = .call_expression;

        return step;
    }

    fn subscript_trailer(parser: *Parser) Step {
        assert(parser.at(.bracket_open));
        assert(parser.frame_count > 0);

        if (!parser.operand_held()) return .done;

        if (parser.object_trailed()) parser.record(.unexpected_token);

        const checkpoint = parser.values[parser.value_count - 1];

        parser.value_count -= 1;

        return parser.open_group(.subscript, checkpoint);
    }

    fn tagged_template(parser: *Parser) Step {
        assert(parser.at(.template_start));
        assert(parser.frame_count > 0);

        if (!parser.operand_held()) return .done;

        const checkpoint = parser.values[parser.value_count - 1];

        parser.value_count -= 1;

        return parser.open_template(checkpoint);
    }

    fn postfix_update(parser: *Parser) Step {
        assert(parser.at(.minus_minus) or parser.at(.plus_plus));
        assert(parser.frame_count > 0);

        if (!parser.operand_held()) return .done;
        if (parser.breaks_line()) return .done;

        const checkpoint = parser.values[parser.value_count - 1];

        parser.events.start_at(checkpoint, .update_expression);
        parser.bump();
        parser.events.finish();
        parser.reduced = parser.value_count - 1;

        return .operator;
    }

    fn joined(parser: *Parser, position: u32) bool {
        assert(position <= parser.count());
        assert(parser.tokens.len == parser.raw.len);

        if (position + 1 >= parser.tokens.len) return false;

        const held = parser.tokens[position];
        const next = parser.tokens[position + 1];
        if (held.end() != next.offset) return false;
        return parser.raw[position + 1] == .greater;
    }

    fn shift(parser: *Parser) Step {
        assert(parser.at(.greater));
        assert(parser.frame_count > 0);

        const step = parser.binary(.{
            .kind = .binary_expression,
            .left = expression.power_shift_left,
            .right = expression.power_shift_right,
        });

        for (0..2) |_| {
            if (parser.kind_at(parser.position) != .greater) break;

            parser.bump();
        }

        return step;
    }

    fn non_null(parser: *Parser) Step {
        assert(parser.at(.bang));
        assert(parser.frame_count > 0);

        if (!parser.operand_held()) return .done;
        if (parser.breaks_line()) return .done;

        const checkpoint = parser.values[parser.value_count - 1];

        parser.reduced = position_none;

        parser.events.start_at(checkpoint, .non_null_expression);
        parser.bump();
        parser.events.finish();

        return .operator;
    }

    fn ternary(parser: *Parser) Step {
        assert(parser.at(.question));
        assert(parser.frame_count > 0);

        parser.reduce_for(expression.power_ternary_left);

        if (!parser.operand_held()) return .done;

        const values = parser.value_count - 1;
        var frame: Frame = .empty;

        frame.checkpoint = parser.values[values];
        frame.kind = .ternary_expression;
        frame.power = expression.power_assign_right;
        frame.values = values;
        frame.variant = .ternary;

        if (!parser.push_frame(frame)) return .done;

        parser.bump();

        return .operand;
    }

    fn ternary_else(parser: *Parser, base: u32) Step {
        assert(base < parser.frame_count);
        assert(parser.at(.colon));

        var index = parser.frame_count;

        while (index > base) {
            index -= 1;

            const frame = parser.frames[index];

            if (frame.variant == .ternary) {
                if (frame.stage == 0) {
                    parser.reduce_above(index + 1);
                    parser.bump();
                    parser.frames[index].stage = 1;

                    return .operand;
                }
            }

            if (frame.is_group()) break;
        }

        return .done;
    }

    fn arrow_body(parser: *Parser) Step {
        assert(parser.at(.arrow));
        assert(parser.frame_count > 0);

        if (parser.value_count == 0) return .done;

        const headed = parser.arrowed == parser.significant(parser.position);
        const arrow_misplaced = !headed or parser.breaks_line();

        if (arrow_misplaced) parser.record(.unexpected_token);

        const values = parser.value_count - 1;
        var frame: Frame = .empty;

        if (headed) frame.awaits = parser.arrow_awaits;

        frame.checkpoint = parser.values[values];
        frame.kind = .arrow_function;
        frame.power = expression.power_arrow;
        frame.values = values;
        frame.variant = .arrow;

        if (!parser.push_frame(frame)) return .done;

        parser.bump();

        return .operand;
    }

    fn identifier_operand(parser: *Parser) Step {
        assert(parser.current() != null);
        assert(parser.frame_count > 0);

        return parser.leaf_operand(.identifier_node);
    }

    fn starts_expression(parser: *Parser, steps_ahead: u32) bool {
        assert(steps_ahead <= 2);
        assert(parser.position <= parser.count());

        const kind = parser.ahead(steps_ahead) orelse return false;
        return opens_an_expression(kind);
    }

    fn yield_operand(parser: *Parser) Step {
        assert(parser.at(.yield_keyword));
        assert(parser.frame_count > 0);

        if (!parser.assignment_operand()) parser.record(.unexpected_token);

        const checkpoint = parser.anchor();
        const star = parser.ahead(1) == .star;
        const steps_ahead: u32 = @as(u32, @intFromBool(star)) + 1;

        const bare = parser.starts_line(parser.ahead_position(steps_ahead)) or
            !parser.starts_expression(steps_ahead);

        if (bare) {
            parser.open(.yield_expression);
            parser.bump();
            _ = parser.eat(.star);

            parser.events.finish();
            parser.push_value(checkpoint);
            parser.sealed = parser.significant(parser.position);

            return .operator;
        }

        var frame: Frame = .empty;

        frame.checkpoint = checkpoint;
        frame.kind = .yield_expression;
        frame.power = expression.power_yield;
        frame.values = parser.value_count;
        frame.variant = .unary;

        if (!parser.push_frame(frame)) return .done;

        parser.bump();
        _ = parser.eat(.star);

        return .operand;
    }

    fn new_operand(parser: *Parser) Step {
        assert(parser.at(.new_keyword));
        assert(parser.frame_count > 0);

        const checkpoint = parser.anchor();
        if (parser.ahead(1) == .dot) return parser.meta_property(checkpoint);

        var frame: Frame = .empty;

        frame.checkpoint = checkpoint;
        frame.kind = .new_expression;
        frame.power = expression.power_unary;
        frame.stage = 1;
        frame.values = parser.value_count;
        frame.variant = .unary;

        if (!parser.push_frame(frame)) return .done;

        parser.bump();

        return .operand;
    }

    fn import_operand(parser: *Parser) Step {
        assert(parser.at(.import_keyword));
        assert(parser.frame_count > 0);

        const checkpoint = parser.anchor();
        if (parser.ahead(1) == .dot) return parser.meta_property(checkpoint);

        parser.wrap(.import_node);
        parser.push_value(checkpoint);

        return .operator;
    }

    fn meta_property(parser: *Parser, checkpoint: Checkpoint) Step {
        assert(parser.ahead(1) == .dot);
        assert(checkpoint.index <= parser.events.count());

        const imported = parser.at(.import_keyword);

        parser.open(.meta_property);
        parser.bump();
        parser.bump();

        const position = parser.significant(parser.position);

        const known = if (imported)
            parser.word_at(position, "meta") or parser.word_at(position, "defer")
        else
            parser.word_at(position, "target");

        if (!known) parser.record(.unexpected_token);

        if (is_property_name(parser.current() orelse .error_token)) {
            parser.bump();
        } else {
            parser.record(.expected_identifier);
        }

        parser.events.finish();
        parser.push_value(checkpoint);

        return .operator;
    }

    fn opens_an_arrow(parser: *Parser, kind: Kind) bool {
        assert(kind.is_token());
        assert(parser.current() == kind);

        if (kind == .paren_open) return parser.arrow_ahead(parser.significant(parser.position));

        if (kind == .async_keyword) {
            if (!parser.starts_line(parser.ahead_position(1))) {
                const after = parser.ahead(1) orelse .error_token;
                if (after == .paren_open) return parser.arrow_ahead(parser.ahead_position(1));

                if (is_name(after)) {
                    if (parser.ahead(2) == .arrow) return true;
                }

                if (after == .less) return parser.generic_arrow_ahead_at(parser.ahead_position(1));
            }
        }

        if (!is_name(kind)) return false;
        return parser.ahead(1) == .arrow;
    }

    fn generic_arrow_ahead(parser: *Parser) bool {
        assert(parser.at(.less));
        assert(parser.position <= parser.count());

        return parser.generic_arrow_ahead_at(parser.significant(parser.position));
    }

    fn generic_arrow_ahead_at(parser: *Parser, from: u32) bool {
        assert(from <= parser.count());
        assert(parser.kind_at(from) == .less);

        if (!parser.typed()) return false;

        const end = parser.type_arguments_end_at(from) orelse return false;
        const after = parser.significant(end);
        if (parser.kind_at(after) != .paren_open) return false;
        return parser.arrow_ahead(after);
    }

    fn open_template(parser: *Parser, tag: ?Checkpoint) Step {
        assert(parser.at(.template_start));
        assert(parser.frame_count > 0);
        if (tag) |held| assert(held.index <= parser.events.count());

        const bracket = parser.anchor();
        const checkpoint = tag orelse bracket;

        parser.bump();

        var frame: Frame = .empty;

        frame.bracket = bracket;
        frame.checkpoint = checkpoint;
        frame.closer = .template_end;
        frame.content = bracket;
        frame.element = bracket;
        frame.element_values = parser.value_count;
        frame.kind = .template_string;
        frame.stage = @intFromBool(tag != null);
        frame.values = parser.value_count;
        frame.variant = .template;

        if (!parser.push_frame(frame)) return .done;
        return .operand;
    }

    fn template_piece(parser: *Parser, group: u32, kind: Kind) Step {
        assert(group < parser.frame_count);
        assert(parser.frames[group].variant == .template);
        assert(kind.is_token());

        if (kind == .template_chars) {
            const position = parser.significant(parser.position);
            const text = parser.tokens[position].text(parser.source);

            if (parser.frames[group].stage == 0) {
                if (!template.escapes_valid(text, true)) parser.record(.unexpected_token);
            }

            parser.bump();

            return .operand;
        }

        if (kind == .substitution_start) {
            const checkpoint = parser.anchor();
            return parser.open_group(.substitution, checkpoint);
        }

        parser.close_template(group);

        return .operator;
    }

    fn close_template(parser: *Parser, group: u32) void {
        assert(group < parser.frame_count);
        assert(parser.frames[group].variant == .template);

        parser.reduce_above(group + 1);

        const frame = parser.frames[group];

        parser.frame_count = group;

        if (frame.stage == 1) {
            parser.events.start_at(frame.checkpoint.?, .call_expression);
            parser.events.start_at(frame.bracket.?, .template_string);
            _ = parser.eat(.template_end);

            parser.events.finish();
        } else {
            parser.events.start_at(frame.checkpoint.?, .template_string);
            _ = parser.eat(.template_end);
        }

        parser.events.finish();
        parser.value_count = frame.values;

        parser.push_value(frame.checkpoint.?);
    }

    fn push_frame(parser: *Parser, frame: Frame) bool {
        assert(parser.frame_count <= expression.depth_max);
        assert(frame.kind.is_node());

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
        parser.reduced = position_none;
    }

    fn innermost_group(parser: *Parser, base: u32) u32 {
        assert(base < parser.frame_count);
        assert(parser.frame_count <= expression.depth_max);

        var index = parser.frame_count;

        while (index > base) {
            index -= 1;

            if (parser.frames[index].is_group()) return index;
        }

        return base;
    }

    fn reduce_top(parser: *Parser) void {
        assert(parser.frame_count > 0);
        assert(parser.frame_count <= expression.depth_max);

        parser.frame_count -= 1;

        const frame = parser.frames[parser.frame_count];

        if (frame.variant == .ternary) {
            if (frame.stage == 0) parser.record(.expected_colon);
        }

        const owed = frame.values + owed_of(&frame);
        const unclosed = frame.is_bracketed() or frame.variant == .template;

        if (parser.value_count < owed) parser.record(.expected_expression);
        if (unclosed) parser.record_expected(.unmatched_bracket, frame.closer);

        parser.wrap_at(frame.checkpoint.?, frame.kind);
        parser.value_count = frame.values;

        parser.push_value(frame.checkpoint.?);
        parser.reduced = parser.value_count - 1;
    }

    fn reduce_above(parser: *Parser, base: u32) void {
        assert(base > 0);
        assert(parser.frame_count <= expression.depth_max);

        while (parser.frame_count > base) {
            parser.reduce_top();
        }
    }

    fn reduce_for(parser: *Parser, power_left: u8) void {
        assert(power_left > expression.power_barrier);
        assert(parser.frame_count <= expression.depth_max);

        while (parser.frame_count > 0) {
            const top = parser.frames[parser.frame_count - 1];
            if (top.power == expression.power_barrier) break;
            if (top.power < power_left) break;

            parser.reduce_top();
        }
    }

    fn progress(parser: *const Parser) Progress {
        assert(parser.position <= parser.count());
        assert(parser.frame_count <= expression.depth_max);

        return .{
            .frame_count = parser.frame_count,
            .position = parser.position,
            .value_count = parser.value_count,
        };
    }

    fn progressed(parser: *const Parser, before: Progress) bool {
        assert(before.position <= parser.count());
        assert(parser.position <= parser.count());

        if (parser.position != before.position) return true;
        if (parser.frame_count != before.frame_count) return true;
        return parser.value_count != before.value_count;
    }

    pub fn balanced_end(parser: *Parser, from: u32) u32 {
        assert(from < parser.count());
        assert(is_opener(parser.raw[from]));

        const probe = from % balanced_slot_count;
        if (parser.balanced_opens[probe] == from) return parser.balanced_ends[probe];

        var depth: u32 = 0;
        var opens: [balanced_stack_max]u32 = undefined;
        var position = from;

        for (0..scan_step_max) |_| {
            const kind = parser.kind_at(position) orelse return position;

            if (is_opener(kind)) {
                if (depth < balanced_stack_max) opens[depth] = position;

                depth += 1;
            }

            if (is_closer(kind)) {
                assert(depth > 0);

                depth -= 1;

                if (depth < balanced_stack_max) {
                    const opened = opens[depth];
                    const slot = opened % balanced_slot_count;

                    parser.balanced_ends[slot] = position + 1;
                    parser.balanced_opens[slot] = opened;
                }

                if (depth == 0) {
                    assert(position + 1 <= parser.tokens.len);

                    return position + 1;
                }
            }

            position += 1;
        }

        return position;
    }

    fn arrow_ahead(parser: *Parser, from: u32) bool {
        assert(from < parser.count());
        assert(is_opener(parser.raw[from]));

        const end = parser.balanced_end(from);
        const after = parser.significant(end);
        const kind = parser.kind_at(after) orelse return false;
        if (kind == .arrow) return true;
        if (kind != .colon) return false;
        if (!parser.assignment_operand()) return false;

        const start = lookahead.arrow_start(parser, from);
        if (start == .never) return false;

        const arrow = lookahead.arrow_after_type(parser, after) orelse return false;

        if (start == .definite) return true;
        if (!parser.in_a_branch()) return true;
        return lookahead.colon_after_body(parser, arrow);
    }

    fn in_a_branch(parser: *const Parser) bool {
        assert(parser.frame_count <= expression.depth_max);
        assert(parser.position <= parser.count());

        var index = parser.frame_count;

        while (index > 0) {
            index -= 1;

            const frame = parser.frames[index];

            switch (frame.variant) {
                .ternary => if (frame.stage == 0) return true,
                .arrow => {},
                .binary => switch (frame.kind) {
                    .assignment_expression, .augmented_assignment_expression => {},
                    else => return false,
                },
                else => return false,
            }
        }

        return false;
    }

    fn assigned_ahead(parser: *Parser, from: u32) bool {
        assert(from < parser.count());
        assert(is_opener(parser.raw[from]));

        const end = parser.balanced_end(from);
        const after = parser.significant(end);

        return parser.kind_at(after) == .equal;
    }

    fn opens_a_key_ahead(parser: *Parser, position: u32) bool {
        assert(position <= parser.count());
        assert(parser.position <= parser.count());

        return opens_a_key(parser.kind_at(position) orelse .error_token);
    }

    fn key_ends_at_colon(parser: *Parser) bool {
        assert(parser.position <= parser.count());
        assert(parser.current() != null);

        const position = parser.significant(parser.position);

        if (parser.kind_at(position) == .bracket_open) {
            const end = parser.balanced_end(position);
            return parser.kind_at(parser.significant(end)) == .colon;
        }

        return parser.ahead(1) == .colon;
    }

    fn method_ahead(parser: *Parser) bool {
        assert(parser.position <= parser.count());
        assert(parser.significant_next <= parser.count());

        var position = parser.significant(parser.position);
        var static_seen = false;

        for (0..method_step_max) |_| {
            const kind = parser.kind_at(position) orelse return false;

            if (kind == .star) {
                position = parser.significant(position + 1);

                continue;
            }

            if (!parser.method_modifier_at(position, kind)) break;

            if (static_seen) {
                if (kind == .static_keyword) break;
            }

            if (parser.modifier_broken(position)) break;

            static_seen = static_seen or kind == .static_keyword;

            const after = parser.significant(position + 1);
            const next = parser.kind_at(after) orelse return false;
            if (ends_a_modifier(next)) break;

            position = after;
        }

        const held = if (parser.kind_at(position) == .bracket_open)
            parser.significant(parser.balanced_end(position))
        else
            parser.significant(position + 1);

        const after = if (parser.kind_at(held) == .question) parser.significant(held + 1) else held;
        const opens = parser.kind_at(after) == .less or parser.kind_at(after) == .paren_open;
        if (!opens) return false;
        return parser.opens_a_key_ahead(position);
    }

    fn method_modifier_at(parser: *Parser, position: u32, kind: Kind) bool {
        assert(position < parser.count());
        assert(parser.raw[position] == kind);

        if (kind == .async_keyword) return true;
        if (kind == .static_keyword) return true;
        if (parser.word_at(position, "get")) return true;
        if (parser.word_at(position, "set")) return true;
        if (!parser.typed()) return false;

        const words = [_][]const u8{
            "abstract",
            "declare",
            "override",
            "private",
            "protected",
            "public",
            "readonly",
        };

        for (words) |word_held| {
            if (parser.word_at(position, word_held)) return true;
        }

        return false;
    }

    fn modifiers(parser: *Parser) bool {
        assert(parser.position <= parser.count());
        assert(parser.significant_next <= parser.count());

        const start = parser.position;
        var abstracted = false;
        var static_seen = false;

        for (0..method_step_max) |_| {
            const before = parser.position;

            abstracted = parser.member_modifiers() or abstracted;

            parser.method_modifiers(&static_seen);

            if (parser.position == before) break;
        }

        if (parser.modifiers_repeated(start)) parser.record(.unexpected_token);

        return abstracted;
    }

    fn word_between(parser: *Parser, from: u32, to: u32, text: []const u8) bool {
        assert(from <= to);
        assert(to <= parser.count());
        assert(text.len <= std.math.maxInt(u32));

        for (from..to) |index| {
            if (parser.word_at(@intCast(index), text)) return true;
        }

        return false;
    }

    fn modifiers_methodic(parser: *Parser, from: u32, to: u32) bool {
        assert(from <= to);
        assert(to <= parser.count());

        for (from..to) |index| {
            const scan: u32 = @intCast(index);

            switch (parser.raw[scan]) {
                .async_keyword, .star, .static_keyword => return true,
                .identifier => {
                    if (parser.word_at(scan, "get")) return true;
                    if (parser.word_at(scan, "set")) return true;
                },
                else => {},
            }
        }

        return false;
    }

    fn modifiers_repeated(parser: *Parser, from: u32) bool {
        assert(from <= parser.position);
        assert(parser.position <= parser.count());

        var accessed = false;

        for (from..parser.position) |index| {
            const scan: u32 = @intCast(index);
            const kind = parser.raw[scan];
            if (kind != .identifier) continue;

            const text = parser.text_at(scan);

            for (modifier_words[0..accessibility_word_count]) |modifier| {
                if (!std.mem.eql(u8, text, modifier)) continue;
                if (accessed) return true;

                accessed = true;
            }
        }

        return false;
    }

    fn method_modifiers(parser: *Parser, static_seen: *bool) void {
        assert(parser.position <= parser.count());
        assert(parser.significant_next <= parser.count());

        for (0..4) |_| {
            if (parser.eat(.star)) continue;

            const position = parser.significant(parser.position);
            const kind = parser.kind_at(position) orelse return;

            const modifier = kind == .async_keyword or kind == .static_keyword or
                parser.word_at(position, "get") or parser.word_at(position, "set");

            if (!modifier) return;

            if (static_seen.*) {
                if (kind == .static_keyword) return;
            }

            if (parser.modifier_broken(position)) return;

            const next = parser.kind_at(parser.significant(position + 1)) orelse return;
            if (ends_a_modifier(next)) return;
            if (next == .question) return;

            const accessor = kind != .async_keyword and kind != .static_keyword;

            static_seen.* = static_seen.* or kind == .static_keyword;

            parser.bump();

            if (accessor) {
                if (parser.at(.star)) parser.record(.unexpected_token);
            }
        }
    }

    fn modifier_broken(parser: *Parser, position: u32) bool {
        assert(position < parser.count());
        assert(parser.raw[position].is_token());

        if (parser.raw[position] == .static_keyword) return false;
        if (parser.word_at(position, "get")) return false;
        if (parser.word_at(position, "set")) return false;
        return parser.starts_line(parser.significant(position + 1));
    }

    fn member_modifiers(parser: *Parser) bool {
        assert(parser.position <= parser.count());
        assert(parser.significant_next <= parser.count());

        if (!parser.typed()) return false;

        var abstracted = false;

        for (0..method_step_max) |_| {
            const position = parser.significant(parser.position);
            if (position >= parser.count()) break;
            if (parser.modifier_broken(position)) break;

            if (parser.accessibility_here()) {
                parser.wrap(.accessibility_modifier);

                continue;
            }

            if (parser.word("override")) {
                if (!parser.opens_a_type()) {
                    parser.wrap(.override_modifier);

                    continue;
                }
            }

            const worded = parser.word("abstract") or parser.word("accessor") or
                parser.word("declare") or parser.word("readonly");

            if (!worded) break;
            if (parser.opens_a_type()) break;

            abstracted = abstracted or parser.word("abstract");

            parser.bump();
        }

        return abstracted;
    }

    fn accessibility_here(parser: *Parser) bool {
        assert(parser.position <= parser.count());
        assert(parser.significant_next <= parser.count());

        if (!parser.typed()) return false;

        const worded = parser.word("private") or parser.word("protected") or
            parser.word("public");

        if (!worded) return false;
        return !parser.opens_a_type();
    }

    fn opens_a_type(parser: *Parser) bool {
        assert(parser.position <= parser.count());
        assert(parser.significant_next <= parser.count());

        const kind = parser.ahead(1) orelse return true;

        return switch (kind) {
            .bang, .brace_close, .bracket_close, .colon, .comma, .equal, .less => true,
            .paren_close, .paren_open, .question, .semicolon => true,
            else => false,
        };
    }

    fn type_arguments_ahead(parser: *Parser) bool {
        assert(parser.at(.less));
        assert(parser.position <= parser.count());

        if (!parser.typed()) return false;
        return parser.type_arguments_end_at(parser.significant(parser.position)) != null;
    }

    fn type_arguments_end_at(parser: *Parser, from: u32) ?u32 {
        assert(from <= parser.count());
        assert(parser.position <= parser.count());

        if (from < parser.plain_failure) return null;

        var angles: u32 = 0;
        var nested: u32 = 0;
        var plain = true;
        var position = from;

        for (0..scan_step_max) |_| {
            const kind = parser.kind_at(position) orelse return null;

            position += 1;

            if (is_opener(kind)) {
                nested += 1;
                plain = false;

                continue;
            }

            if (is_closer(kind)) {
                if (nested == 0) {
                    const returned = parser.plain_mark(plain, position - 1);

                    if (returned) |mark| assert(mark < std.math.maxInt(u32));

                    return returned;
                }

                nested -= 1;

                continue;
            }

            if (nested > 0) continue;

            switch (kind) {
                .less => angles += 1,
                .greater => {
                    assert(angles > 0);

                    angles -= 1;
                    plain = false;

                    if (angles == 0) return position;
                },
                .arrow, .equal => {},
                else => if (!parser.typed_token_at(kind, position - 1)) {
                    const returned = parser.plain_mark(plain, position - 1);

                    if (returned) |mark| assert(mark < std.math.maxInt(u32));

                    return returned;
                },
            }
        }

        return null;
    }

    fn typed_token_at(parser: *Parser, kind: Kind, position: u32) bool {
        assert(position < parser.count());
        assert(parser.raw[position] == kind);

        if (is_type_token(kind)) return true;
        if (!is_property_name(kind)) return false;

        const before = parser.behind(position);
        if (kind == .const_keyword) return before == .less or before == .comma;
        return before == .dot;
    }

    fn plain_mark(parser: *Parser, plain: bool, position: u32) ?u32 {
        assert(position < parser.count());
        assert(parser.position <= parser.count());

        if (plain) parser.plain_failure = position;

        return null;
    }

    fn behind(parser: *Parser, position: u32) ?Kind {
        assert(position <= parser.count());
        assert(parser.raw.len == parser.tokens.len);

        var at_position = position;

        for (0..scan_step_max) |_| {
            if (at_position == 0) return null;

            at_position -= 1;

            const kind = parser.raw[at_position];
            if (kind != .comment) return kind;
        }

        return null;
    }

    fn call_arguments_ahead(parser: *Parser) bool {
        assert(parser.at(.less));
        assert(parser.position <= parser.count());

        return parser.call_arguments_ahead_at(parser.significant(parser.position));
    }

    fn call_arguments_ahead_at(parser: *Parser, from: u32) bool {
        assert(from <= parser.count());
        assert(parser.kind_at(from) == .less);

        const end = parser.type_arguments_end_at(from) orelse return false;
        const next = parser.significant(end);
        const kind = parser.kind_at(next) orelse return true;

        switch (kind) {
            .paren_open, .template_start => return true,
            .greater, .less, .minus, .plus => return false,
            else => {},
        }

        if (parser.starts_line(next)) return true;
        if (expression.infix_of(kind) != null) return true;
        return !opens_an_expression(kind);
    }

    fn parenthesized_generic_ahead(parser: *Parser) bool {
        assert(parser.position <= parser.count());
        assert(parser.significant_next <= parser.count());

        if (!parser.typed()) return false;
        if (!parser.at(.paren_open)) return false;

        const position = parser.significant(parser.position);
        const after = parser.significant(parser.balanced_end(position));
        if (parser.kind_at(after) != .less) return false;
        return parser.type_arguments_end_at(after) != null;
    }

    fn asserts_ahead(parser: *Parser, position: u32) bool {
        assert(position <= parser.count());
        assert(parser.position <= parser.count());

        const kind = parser.kind_at(position) orelse return false;
        return is_name(kind) or kind == .this_keyword;
    }

    fn asserts_lined(parser: *Parser, position: u32) bool {
        assert(position <= parser.count());
        assert(parser.position <= parser.count());

        if (!parser.asserts_ahead(position)) return false;
        return !parser.starts_line(position);
    }

    fn predicate_ahead(parser: *Parser, position: u32) bool {
        assert(position <= parser.count());
        assert(parser.position <= parser.count());

        if (!parser.predicate_asserted(position)) return false;
        return !parser.starts_line(parser.significant(position + 1));
    }

    fn predicate_asserted(parser: *Parser, position: u32) bool {
        assert(position <= parser.count());
        assert(parser.position <= parser.count());

        if (!parser.asserts_ahead(position)) return false;
        return parser.word_at(parser.significant(position + 1), "is");
    }

    fn opens_a_binding(parser: *Parser) bool {
        assert(parser.at(.let_keyword));
        assert(parser.position <= parser.count());

        const kind = parser.ahead(1) orelse return false;
        if (is_name(kind)) return true;
        return kind == .brace_open or kind == .bracket_open;
    }

    fn opens_a_resource(parser: *Parser, steps_ahead: u32) bool {
        assert(steps_ahead <= 1);
        assert(parser.position <= parser.count());

        const position = parser.ahead_position(steps_ahead);
        if (!parser.word_at(position, "using")) return false;

        if (steps_ahead > 0) {
            if (parser.starts_line(position)) return false;
        }

        const name = parser.ahead_position(steps_ahead + 1);
        const kind = parser.kind_at(name) orelse .error_token;
        if (!is_name(kind)) return false;
        if (kind == .await_keyword) return false;
        if (parser.starts_line(name)) return false;

        const after = parser.ahead(steps_ahead + 2);
        if (after == .colon) return parser.typed();
        return after == .equal;
    }

    fn iterates_a_resource(parser: *Parser, steps_ahead: u32) bool {
        assert(steps_ahead <= 1);
        assert(parser.position <= parser.count());

        const position = parser.ahead_position(steps_ahead);
        if (!parser.word_at(position, "using")) return false;

        if (steps_ahead > 0) {
            if (parser.starts_line(position)) return false;
        }

        const name = parser.ahead_position(steps_ahead + 1);
        const kind = parser.kind_at(name) orelse .error_token;
        if (!is_name(kind)) return false;
        if (kind == .await_keyword) return false;

        if (kind == .of_keyword) {
            if (steps_ahead == 0) return false;
        }

        return !parser.starts_line(name);
    }

    fn opens_an_ambient(parser: *Parser) bool {
        assert(parser.word("declare"));
        assert(parser.position <= parser.count());

        const position = parser.ahead_position(1);
        const kind = parser.kind_at(position) orelse return false;

        if (parser.starts_line(position)) return false;

        switch (kind) {
            .class_keyword, .const_keyword, .function_keyword, .let_keyword => return true,
            .var_keyword => return true,
            else => {},
        }

        for (ambient_words) |text| {
            if (!parser.word_at(position, text)) continue;
            if (std.mem.eql(u8, text, "enum")) return true;
            if (std.mem.eql(u8, text, "global")) return true;
            if (std.mem.eql(u8, text, "type")) return true;
            return !parser.starts_line(parser.ahead_position(2));
        }

        return false;
    }

    fn opens_a_name(parser: *Parser, steps_ahead: u32) bool {
        assert(steps_ahead <= 2);
        assert(parser.position <= parser.count());

        return is_name(parser.ahead(steps_ahead) orelse .error_token);
    }

    fn opens_a_module(parser: *Parser, steps_ahead: u32) bool {
        assert(steps_ahead <= 2);
        assert(parser.position <= parser.count());

        if (parser.opens_a_name(steps_ahead)) return true;
        return parser.ahead(steps_ahead) == .string;
    }

    fn opens_an_alias(parser: *Parser) bool {
        assert(parser.word("type"));
        assert(parser.position <= parser.count());

        if (!parser.opens_a_name(1)) return false;
        if (parser.starts_line(parser.ahead_position(1))) return false;

        const kind = parser.ahead(2) orelse return false;
        return kind == .equal or kind == .less;
    }

    fn opens_an_import_alias(parser: *Parser) bool {
        assert(parser.at(.import_keyword));
        assert(parser.position <= parser.count());

        if (!parser.opens_a_name(1)) return false;
        if (parser.ahead(2) != .equal) return false;
        return !parser.word_at(parser.ahead_position(3), "require");
    }

    fn names_a_function(parser: *Parser) bool {
        assert(parser.position <= parser.count());
        assert(parser.current() != null);

        const steps_ahead: u32 = @intFromBool(parser.at(.async_keyword));
        const generator = parser.ahead(steps_ahead + 1) == .star;
        const at_name = steps_ahead + 1 + @as(u32, @intFromBool(generator));

        return is_name(parser.ahead(at_name) orelse .error_token);
    }

    fn typed_modifier(parser: *Parser, follower: []const u8) bool {
        assert(follower.len > 0);
        assert(parser.position <= parser.count());

        if (!parser.typed()) return false;
        if (!parser.word("type")) return false;

        if (parser.word_at(parser.ahead_position(1), follower)) {
            return parser.word_at(parser.ahead_position(2), follower);
        }

        return true;
    }

    fn type_parameter_modifiers(parser: *Parser) void {
        assert(parser.position <= parser.count());
        assert(parser.significant_next <= parser.count());

        for (0..type_modifier_max) |_| {
            if (parser.eat(.const_keyword)) continue;
            if (!parser.at_variance()) return;

            parser.bump();
        }
    }

    fn at_variance(parser: *Parser) bool {
        assert(parser.position <= parser.count());
        assert(parser.significant_next <= parser.count());

        const variance = parser.at(.in_keyword) or parser.word("out");
        if (!variance) return false;

        const held = parser.ahead(1) orelse .error_token;
        return is_name(held) or held == .in_keyword or held == .const_keyword;
    }

    fn jump_statement(parser: *Parser, kind: Kind) void {
        assert(kind == .break_statement or kind == .continue_statement);
        assert(parser.current() != null);

        parser.open(kind);
        parser.bump();

        if (!parser.breaks_line()) {
            if (is_name(parser.current() orelse .error_token)) parser.wrap(.statement_identifier);
        }

        parser.terminate();
        parser.events.finish();
    }

    fn debugger_statement(parser: *Parser) void {
        assert(parser.at(.debugger_keyword));
        assert(parser.position < parser.count());

        parser.open(.debugger_statement);
        parser.bump();
        parser.terminate();
        parser.events.finish();
    }

    fn import_head(parser: *Parser) void {
        assert(parser.position <= parser.count());
        assert(parser.significant_next <= parser.count());

        if (parser.at(.string)) {
            parser.wrap(.string_node);

            return;
        }

        if (parser.typed()) {
            if (parser.word("type")) {
                if (parser.opens_a_name(1)) {
                    if (parser.ahead(2) == .equal) parser.bump();
                }
            }
        }

        if (parser.opens_a_name(0)) {
            if (parser.ahead(1) == .equal) {
                parser.import_require();

                return;
            }
        }

        parser.import_clause();

        if (!parser.eat_word("from")) parser.record(.unexpected_token);

        if (parser.at(.string)) {
            parser.wrap(.string_node);
        } else {
            parser.record(.unexpected_token);
        }
    }

    fn import_require(parser: *Parser) void {
        assert(parser.ahead(1) == .equal);
        assert(parser.position < parser.count());

        parser.open(.import_require_clause);
        parser.wrap(.identifier_node);
        _ = parser.eat(.equal);

        if (!parser.eat_word("require")) parser.record(.unexpected_token);

        parser.expect(.paren_open, .unexpected_token);

        if (parser.at(.string)) {
            parser.wrap(.string_node);
        } else {
            parser.record(.unexpected_token);
        }

        parser.expect(.paren_close, .unmatched_bracket);
        parser.events.finish();
    }

    fn import_attribute_task(parser: *Parser) ?Task {
        assert(parser.position <= parser.count());
        assert(parser.task_count > 0);

        if (parser.word("assert")) {
            if (parser.breaks_line()) return null;
        } else {
            if (!parser.at(.with_keyword)) return null;
        }

        if (parser.ahead(1) != .brace_open) return null;
        return enclosed(.import_attribute, .expression_single);
    }

    fn export_attribute_task(parser: *Parser, sourced: bool) ?Task {
        assert(parser.position <= parser.count());
        assert(parser.task_count > 0);

        if (!sourced) return null;
        if (parser.breaks_line()) return null;
        return parser.import_attribute_task();
    }

    fn import_clause(parser: *Parser) void {
        assert(parser.position <= parser.count());
        assert(parser.significant_next <= parser.count());

        if (parser.typed_modifier("from")) {
            const after = parser.ahead(1);
            const bare = after == null or after == .comma or after == .equal;

            if (!bare) parser.bump();
        }

        parser.open(.import_clause);

        if (parser.word("defer")) {
            if (parser.ahead(1) == .star) parser.bump();
        }

        if (parser.at(.star)) {
            parser.namespace_import(.namespace_import);
            parser.events.finish();

            return;
        }

        if (parser.at(.brace_open)) {
            parser.specifier_list(.named_imports, .import_specifier);
            parser.events.finish();

            return;
        }

        if (is_name(parser.current() orelse .error_token)) parser.wrap(.identifier_node);

        if (parser.eat(.comma)) {
            if (parser.at(.star)) {
                parser.namespace_import(.namespace_import);
            } else {
                parser.specifier_list(.named_imports, .import_specifier);
            }
        }

        parser.events.finish();
    }

    fn namespace_import(parser: *Parser, kind: Kind) void {
        assert(kind == .namespace_import or kind == .namespace_export);
        assert(parser.at(.star));

        parser.open(kind);
        parser.bump();

        if (!parser.eat_word("as")) parser.record(.unexpected_token);

        const name = parser.current() orelse .error_token;
        const exported = kind == .namespace_export;
        const named = is_name(name) or (exported and is_property_name(name));

        if (named) {
            parser.wrap(.identifier_node);
        } else {
            const stringed = exported and name == .string;

            if (stringed) {
                parser.wrap(.string_node);
            } else {
                parser.record(.expected_identifier);
            }
        }

        parser.events.finish();
    }

    fn specifier_list(parser: *Parser, list: Kind, item: Kind) void {
        assert(list.is_node());
        assert(item.is_node());

        parser.open(list);
        parser.expect(.brace_open, .unexpected_token);

        for (0..parser.steps()) |_| {
            parser.skip_trivia();

            if (parser.at(.brace_close)) break;
            if (parser.current() == null) break;

            const before = parser.position;

            parser.open(item);

            if (parser.typed_modifier("as")) {
                const after = parser.ahead(1);
                const bare = after == null or after == .brace_close or after == .comma;

                if (!bare) parser.bump();
            }

            parser.specifier_name();

            if (parser.eat_word("as")) parser.specifier_name();

            parser.events.finish();

            if (!parser.eat(.comma)) break;
            if (parser.position == before) break;
        }

        parser.expect(.brace_close, .unmatched_bracket);
        parser.events.finish();
    }

    fn specifier_name(parser: *Parser) void {
        assert(parser.position <= parser.count());
        assert(parser.significant_next <= parser.count());

        const kind = parser.current() orelse return;

        if (kind == .string) {
            parser.wrap(.string_node);

            return;
        }

        if (is_property_name(kind)) {
            parser.wrap(.identifier_node);
        } else {
            parser.record(.expected_identifier);
        }
    }

    fn export_star(parser: *Parser) bool {
        assert(parser.at(.star));
        assert(parser.position < parser.count());

        if (parser.word_at(parser.ahead_position(1), "as")) {
            parser.namespace_import(.namespace_export);
        } else {
            parser.bump();
        }

        if (!parser.eat_word("from")) parser.record(.unexpected_token);

        return parser.export_source();
    }

    fn export_clause(parser: *Parser) bool {
        assert(parser.position < parser.count());
        assert(parser.significant_next <= parser.count());

        if (parser.typed()) _ = parser.eat_word("type");

        parser.specifier_list(.export_clause, .export_specifier);

        if (!parser.eat_word("from")) return false;
        return parser.export_source();
    }

    fn export_source(parser: *Parser) bool {
        assert(parser.position <= parser.count());
        assert(parser.significant_next <= parser.count());

        if (!parser.at(.string)) {
            parser.record(.unexpected_token);

            return false;
        }

        parser.wrap(.string_node);

        return true;
    }

    fn jsx_element_name(parser: *Parser) void {
        assert(parser.position <= parser.count());
        assert(parser.significant_next <= parser.count());

        if (!parser.at(.identifier)) return;

        const checkpoint = parser.anchor();

        parser.wrap(.identifier_node);

        if (parser.at(.colon)) {
            parser.bump();

            if (parser.at(.identifier)) parser.wrap(.identifier_node);

            parser.wrap_at(checkpoint, .jsx_namespace_name);

            return;
        }

        for (0..parser.steps()) |_| {
            if (!parser.at(.dot)) return;

            parser.bump();

            if (parser.at(.identifier)) parser.wrap(.property_identifier);

            parser.wrap_at(checkpoint, .member_expression);
        }
    }

    fn jsx_closing_element(parser: *Parser) void {
        assert(parser.position <= parser.count());
        assert(parser.significant_next <= parser.count());

        if (!parser.at(.jsx_tag_start_close)) {
            parser.record(.unmatched_bracket);

            return;
        }

        const checkpoint = parser.anchor();

        parser.bump();
        parser.jsx_element_name();
        parser.expect(.jsx_tag_end, .unexpected_token);
        parser.wrap_at(checkpoint, .jsx_closing_element);
    }

    fn jsx_attribute_name(parser: *Parser) void {
        assert(parser.at(.identifier));
        assert(parser.position < parser.count());

        if (parser.ahead(1) != .colon) {
            parser.wrap(.property_identifier);

            return;
        }

        const checkpoint = parser.anchor();

        parser.wrap(.identifier_node);
        parser.bump();

        if (parser.at(.identifier)) parser.wrap(.identifier_node);

        parser.wrap_at(checkpoint, .jsx_namespace_name);
    }

    fn query_trailers(parser: *Parser, checkpoint: Checkpoint) void {
        assert(parser.position <= parser.count());
        assert(checkpoint.index <= parser.events.count());

        for (0..parser.steps()) |_| {
            if (!parser.at(.dot)) break;

            parser.bump();

            if (is_property_name(parser.current() orelse .error_token)) {
                parser.wrap(.property_identifier);
            }

            parser.wrap_at(checkpoint, .member_expression);
        }
    }

    fn name_continues(parser: *Parser) bool {
        const kind = parser.ahead(1) orelse return false;

        assert(kind.is_token());
        assert(parser.starts_expression(1));

        return switch (kind) {
            .bracket_open, .less, .minus, .minus_minus, .of_keyword, .paren_open => true,
            .plus, .plus_plus, .regex, .slash, .template_start => true,
            else => false,
        };
    }

    fn yield_named(parser: *Parser) bool {
        assert(parser.at(.yield_keyword));

        if (!parser.starts_expression(1)) return true;
        return parser.name_continues();
    }

    pub fn context_here(parser: *const Parser) Context {
        var frame_top = parser.frame_count;
        var depth = parser.task_count;

        assert(parser.task_count <= task_count_max);
        assert(parser.frame_count <= expression.depth_max);

        for (0..task_count_max) |_| {
            if (depth == 0) break;

            depth -= 1;

            switch (parser.tasks[depth]) {
                .expression => |*state| {
                    if (state.stage == .start) continue;
                    if (parser.arrow_context(state.frames_base, frame_top)) |held| return held;

                    frame_top = state.frames_base;
                },
                .function_declaration => |*state| {
                    return .{ .awaits = state.awaits, .yields = state.generator };
                },
                .function_expression => |*state| {
                    return .{ .awaits = state.awaits, .yields = state.generator };
                },
                .method_definition => |*state| switch (state.stage) {
                    .start, .keyed => {},
                    else => return .{ .awaits = state.awaits, .yields = state.generator },
                },
                .class_member => |*state| {
                    if (state.stage == .valued) return .{ .awaits = false, .yields = false };
                },
                .enclosed => |*state| {
                    const static_block = state.kind == .class_static_block;
                    if (static_block) return .{ .awaits = true, .yields = false };
                },
                else => {},
            }
        }

        return .{ .awaits = parser.goal == .module, .yields = false };
    }

    fn arrow_context(parser: *const Parser, base: u32, top: u32) ?Context {
        assert(base <= top);
        assert(top <= parser.frame_count);

        for (0..top - base) |step| {
            const frame = &parser.frames[top - 1 - step];
            if (frame.variant == .arrow) return .{ .awaits = frame.awaits, .yields = false };
        }

        return null;
    }

    fn slash_misread(parser: *Parser, regex: bool) void {
        const position = parser.significant(parser.position);
        const kind = parser.kind_at(position) orelse return;

        assert(position < parser.count());
        if (regex) assert(kind != .regex);
        if (!regex) assert(kind == .regex);

        if (parser.slash != null) return;

        parser.slash = .{ .offset = parser.tokens[position].offset, .regex = regex };
    }

    fn record(parser: *Parser, kind: Diagnostic.Kind) void {
        assert(!kind.is_indentation());

        parser.record_expected(kind, null);
    }

    fn record_expected(parser: *Parser, kind: Diagnostic.Kind, expected: ?Kind) void {
        assert(!kind.is_indentation());
        if (expected) |held| assert(held.is_token());

        const position = @min(parser.significant(parser.position), parser.count());

        parser.record_at(kind, expected, position);
    }

    fn record_at(parser: *Parser, kind: Diagnostic.Kind, expected: ?Kind, position: u32) void {
        assert(parser.tokens.len == parser.raw.len);
        assert(position <= parser.count());
        if (expected) |held| assert(held.is_token());

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

    fn expect(parser: *Parser, kind: Kind, failure: Diagnostic.Kind) void {
        assert(!failure.is_indentation());
        assert(kind.is_token());
        assert(parser.position <= parser.count());

        if (parser.eat(kind)) return;

        parser.record_expected(failure, kind);
    }

    fn terminate(parser: *Parser) void {
        assert(parser.position <= parser.count());
        assert(parser.significant_next <= parser.count());

        if (parser.eat(.semicolon)) return;
        if (parser.breaks_line()) return;
        if (parser.current() == null) return;
        if (parser.at(.brace_close)) return;

        parser.record(.unexpected_token);
    }

    fn eat(parser: *Parser, kind: Kind) bool {
        assert(kind.is_token());
        assert(parser.position <= parser.count());

        if (!parser.at(kind)) return false;

        parser.bump();

        return true;
    }

    fn eat_word(parser: *Parser, text: []const u8) bool {
        assert(text.len > 0);
        assert(parser.position <= parser.count());

        if (!parser.word(text)) return false;

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
        assert(kind.is_node());
        assert(parser.position <= parser.count());

        parser.skip_trivia();
        parser.events.start(kind);
    }

    fn wrap(parser: *Parser, kind: Kind) void {
        assert(kind.is_node());
        assert(parser.position <= parser.count());

        parser.open(kind);
        parser.emit();
        parser.events.finish();
    }

    fn wrap_at(parser: *Parser, checkpoint: Checkpoint, kind: Kind) void {
        assert(kind.is_node());
        assert(checkpoint.index <= parser.events.count());

        parser.events.start_at(checkpoint, kind);
        parser.events.finish();
    }

    fn anchor(parser: *Parser) Checkpoint {
        parser.skip_trivia();

        const checkpoint = parser.events.checkpoint();

        assert(checkpoint.index <= parser.events.count());

        return checkpoint;
    }

    fn skip_trivia(parser: *Parser) void {
        assert(parser.position <= parser.significant_next);

        for (parser.position..parser.raw.len) |_| {
            if (parser.raw[parser.position] != .comment) break;

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
        assert(parser.significant_next <= parser.count());
    }

    fn starts_line(parser: *Parser, position: u32) bool {
        assert(parser.tokens.len == parser.raw.len);
        assert(parser.source.len <= std.math.maxInt(u32));

        if (position == 0) return true;
        if (position > parser.count()) return true;

        var back = position - 1;

        while (back > 0) : (back -= 1) {
            if (!is_layout(parser.raw[back])) break;
        }

        const from = parser.tokens[back].end();

        const stop: u32 = if (position < parser.tokens.len)
            parser.tokens[position].offset
        else
            @intCast(parser.source.len);

        if (stop <= from) return false;
        return terminates_line(parser.source[from..stop]);
    }

    fn breaks_line(parser: *Parser) bool {
        assert(parser.position <= parser.count());
        assert(parser.significant_next <= parser.count());

        return parser.starts_line(parser.significant(parser.position));
    }

    pub fn word(parser: *Parser, text: []const u8) bool {
        assert(text.len > 0);
        assert(parser.position <= parser.count());

        return parser.word_at(parser.significant(parser.position), text);
    }

    fn typed(parser: *const Parser) bool {
        const result = parser.dialect.typed();

        if (!result) assert(parser.dialect == .javascript);

        return result;
    }

    pub fn word_at(parser: *Parser, position: u32, text: []const u8) bool {
        assert(text.len > 0);
        assert(parser.raw.len == parser.tokens.len);

        if (parser.kind_at(position) != .identifier) return false;
        return std.mem.eql(u8, parser.text_at(position), text);
    }

    fn text_at(parser: *Parser, position: u32) []const u8 {
        assert(parser.raw.len == parser.tokens.len);
        assert(parser.source.len <= std.math.maxInt(u32));
        assert(position < std.math.maxInt(u32));

        if (position >= parser.tokens.len) return "";
        return parser.tokens[position].text(parser.source);
    }

    pub fn at(parser: *Parser, kind: Kind) bool {
        assert(kind.is_token());
        assert(parser.position <= parser.count());

        return parser.current() == kind;
    }

    pub fn ahead(parser: *Parser, distance: u32) ?Kind {
        assert(distance <= 3);
        assert(parser.position <= parser.count());

        return parser.kind_at(parser.ahead_position(distance));
    }

    pub fn ahead_position(parser: *Parser, distance: u32) u32 {
        assert(distance <= 3);
        assert(parser.position <= parser.count());

        var position = parser.significant(parser.position);

        for (0..distance) |_| {
            position = parser.significant(position + 1);
        }

        return position;
    }

    pub fn current(parser: *Parser) ?Kind {
        assert(parser.significant_next <= parser.count());
        assert(parser.position <= parser.significant_next);

        return parser.kind_at(parser.significant(parser.position));
    }

    pub fn significant(parser: *Parser, from: u32) u32 {
        assert(from <= parser.count() + 4);
        assert(parser.significant_next <= parser.count());

        if (from == parser.position) return parser.significant_next;
        return parser.significant_scan(from);
    }

    fn significant_scan(parser: *Parser, from: u32) u32 {
        assert(parser.raw.len == parser.tokens.len);
        assert(from < std.math.maxInt(u32));

        var position = from;

        while (position < parser.raw.len) : (position += 1) {
            if (!is_layout(parser.raw[position])) break;
        }

        assert(position >= from);

        return position;
    }

    pub fn kind_at(parser: *Parser, position: u32) ?Kind {
        assert(parser.raw.len == parser.tokens.len);

        if (position >= parser.raw.len) return null;
        return parser.raw[position];
    }

    pub fn count(parser: *const Parser) u32 {
        assert(parser.raw.len < std.math.maxInt(u32));

        return @intCast(parser.raw.len);
    }

    pub fn steps(parser: *const Parser) u32 {
        const result = parser.count() + 1;

        assert(result > parser.position);

        return result;
    }
};

const Context = struct {
    awaits: bool,
    yields: bool,
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

const Pending = union(enum) {
    arrow_block: Checkpoint,
    none,
    step: Step,
    value: Checkpoint,
};

const Call = struct {
    task: Task,
    pending: Pending,
};

const Advance = union(enum) {
    step: Step,
    call: Call,
};

const Progress = struct {
    frame_count: u32,
    position: u32,
    value_count: u32,

    const zero: Progress = .{ .frame_count = 0, .position = 0, .value_count = 0 };
};

const Opening = enum {
    bump,
    eat,
    expect,
    none,
};

const Style = enum {
    comma_ends,
    comma_skips,
    semicolon_skips,
    separator_skips,
};

const Procedure = enum {
    binding_element,
    binding_pattern,
    class_member,
    enum_member,
    expression_decorator,
    expression_single,
    heritage_item,
    heritage_list,
    object_binding_member,
    object_pattern_member,
    parameter,
    pattern,
    pattern_element,
    signature,
    statement,
    statement_block,
    tuple_member,
    type_expression,
    type_list,
    type_operand,
    type_parameter,
    type_predicate,
    variable_declarator,
};

const Task = union(enum) {
    ambient_declaration: AmbientDeclaration,
    arrow_head: ArrowHead,
    asserts: Asserts,
    call_signature: CallSignature,
    class: Class,
    class_heritage: ClassHeritage,
    class_member: ClassMember,
    comma_list: CommaList,
    declaration: Declaration,
    decorated: Decorated,
    decorators: Decorators,
    do_statement: DoStatement,
    enclosed: Enclosed,
    enum_declaration: EnumDeclaration,
    enum_member: EnumMember,
    export_statement: ExportStatement,
    expression: Expression,
    expression_statement: ExpressionStatement,
    for_in_statement: ForInStatement,
    for_statement: ForStatement,
    function_declaration: FunctionDeclaration,
    function_expression: FunctionExpression,
    function_head: FunctionHead,
    function_type: FunctionType,
    generic_arrow: GenericArrow,
    heritage_item: HeritageItem,
    if_statement: IfStatement,
    import_alias: ImportAlias,
    import_statement: ImportStatement,
    index_signature: IndexSignature,
    infer_type: InferType,
    interface_declaration: InterfaceDeclaration,
    internal_module: InternalModule,
    jsx: Jsx,
    jsx_attribute: JsxAttribute,
    jsx_attributes: JsxAttributes,
    jsx_children: JsxChildren,
    jsx_element: JsxElement,
    jsx_expression: JsxExpression,
    keyword_statement: KeywordStatement,
    labeled_statement: LabeledStatement,
    list: List,
    loop_statement: LoopStatement,
    method_definition: MethodDefinition,
    module_declaration: ModuleDeclaration,
    namespace_statement: NamespaceStatement,
    object_key: ObjectKey,
    object_pattern_member: ObjectPatternMember,
    optional_type: OptionalType,
    parameter: Parameter,
    parameter_modifiers: ParameterModifiers,
    parenthesized: Parenthesized,
    pattern_element: PatternElement,
    query_target: QueryTarget,
    readonly_type: ReadonlyType,
    signature_member: SignatureMember,
    statement: Statement,
    statement_block: StatementBlock,
    statements: Statements,
    switch_body: SwitchBody,
    switch_case: SwitchCase,
    switch_statement: SwitchStatement,
    template_literal_type: TemplateLiteralType,
    try_statement: TryStatement,
    type_alias: TypeAlias,
    type_argument_trailer: TypeArgumentTrailer,
    type_conditional: TypeConditional,
    type_expression: TypeExpression,
    type_import: TypeImport,
    type_intersection: TypeIntersection,
    type_operation: TypeOperation,
    type_parameter: TypeParameter,
    type_postfix: TypePostfix,
    type_predicate: TypePredicate,
    type_query: TypeQuery,
    type_reference: TypeReference,
    type_trailers: TypeTrailers,
    type_union: TypeUnion,
    variable_declarator: VariableDeclarator,
};

const AmbientDeclaration = struct {
    stage: enum { start, done } = .start,
};

const ArrowHead = struct {
    stage: enum { start, typed, parameters, annotated, done } = .start,
    checkpoint: ?Checkpoint = null,
    awaits: bool = false,
};

const Asserts = struct {
    stage: enum { start, done } = .start,
    annotated: bool = false,
};

const CallSignature = struct {
    stage: enum { start, typed, parameters, done } = .start,
    kind: Kind,
    bumped: bool = false,
};

const Class = struct {
    stage: enum { start, typed, heritage, done } = .start,
    checkpoint: ?Checkpoint = null,
    kind: Kind,
    abstracted: bool = false,
};

const ClassHeritage = struct {
    stage: enum { start, clause, plain } = .start,
    iteration: u32 = 0,
};

const ClassMember = struct {
    stage: enum { start, decorated, indexed, keyed, annotated, valued, done } = .start,
    abstracted: bool = false,
    checkpoint: ?Checkpoint = null,
    decorated: bool = false,
};

const CommaList = struct {
    stage: enum { start, item } = .start,
    item: Procedure,
    stuck_ends: bool = false,
    before: u32 = 0,
    iteration: u32 = 0,
};

const Declaration = struct {
    stage: enum { start, declared } = .start,
    headed: bool = false,
};

const Decorated = struct {
    stage: enum { start, decorated, done } = .start,
    checkpoint: ?Checkpoint = null,
    expression: bool = false,
};

const Decorators = struct {
    stage: enum { start, decorator } = .start,
    iteration: u32 = 0,
};

const DoStatement = struct {
    stage: enum { start, body, done } = .start,
};

const Enclosed = struct {
    stage: enum { start, done } = .start,
    kind: Kind,
    inner: Procedure,
    closer: Kind = .error_token,
};

const EnumDeclaration = struct {
    stage: enum { start, done } = .start,
};

const EnumMember = struct {
    stage: enum { start, keyed, done } = .start,
    checkpoint: ?Checkpoint = null,
};

const ExportStatement = struct {
    stage: enum { start, done } = .start,
    checkpoint: ?Checkpoint = null,
    owes: bool = false,
    trails: bool = false,
};

const Expression = struct {
    stage: enum { start, machine, stepped, fallback, checked, finished } = .start,
    sequence: bool,
    decorated: bool = false,
    iterated: bool = false,
    required: bool = false,
    spread: bool = false,
    significant_before: u32 = 0,
    frames_base: u32 = 0,
    values_base: u32 = 0,
    operand: bool = true,
    before: Progress = .zero,
    iteration: u32 = 0,
    pending: Pending = .none,
};

const ExpressionStatement = struct {
    stage: enum { start, done } = .start,
};

const ForInStatement = struct {
    stage: enum { start, patterned, initialized, subject, done } = .start,
    resource: bool = false,
    variable: bool = false,
};

const ForStatement = struct {
    stage: enum {
        start,
        initializer,
        initialized,
        condition,
        conditioned,
        updated,
        done,
    } = .start,
};

const FunctionDeclaration = struct {
    stage: enum { start, head, done } = .start,
    checkpoint: ?Checkpoint = null,
    awaits: bool = false,
    generator: bool = false,
    kind: Kind = .function_declaration,
};

const FunctionExpression = struct {
    stage: enum { start, head, done } = .start,
    awaits: bool = false,
    generator: bool = false,
};

const FunctionHead = struct {
    stage: enum { start, typed, parameters, done } = .start,
};

const FunctionType = struct {
    stage: enum { start, typed, parameters, done } = .start,
    kind: Kind,
    abstracted: bool = false,
    bumped: bool = false,
    generic: bool = false,
};

const GenericArrow = struct {
    stage: enum { start, typed, parameters, done } = .start,
    checkpoint: ?Checkpoint = null,
};

const HeritageItem = struct {
    stage: enum { start, parenthesized, targeted, typed, called, done } = .start,
    checkpoint: ?Checkpoint = null,
};

const IfStatement = struct {
    stage: enum { start, condition, body, done } = .start,
};

const ImportAlias = struct {
    stage: enum { start, done } = .start,
};

const ImportStatement = struct {
    stage: enum { start, done } = .start,
};

const IndexSignature = struct {
    stage: enum { start, mapped, remapped, keyed, annotated, done } = .start,
};

const InferType = struct {
    stage: enum { start, done } = .start,
};

const InterfaceDeclaration = struct {
    stage: enum { start, typed, extended, done } = .start,
};

const InternalModule = struct {
    stage: enum { start, named, done } = .start,
};

const Jsx = struct {
    stage: enum { start, done } = .start,
};

const JsxAttribute = struct {
    stage: enum { start, done } = .start,
    checkpoint: ?Checkpoint = null,
};

const JsxAttributes = struct {
    iteration: u32 = 0,
};

const JsxChildren = struct {
    iteration: u32 = 0,
};

const JsxElement = struct {
    stage: enum { start, typed, attributed, children } = .start,
    checkpoint: ?Checkpoint = null,
};

const JsxExpression = struct {
    stage: enum { start, done } = .start,
    checkpoint: ?Checkpoint = null,
    valued: bool = false,
};

const KeywordStatement = struct {
    stage: enum { start, done } = .start,
    kind: Kind,
};

const LabeledStatement = struct {
    stage: enum { start, done } = .start,
};

const List = struct {
    stage: enum { start, item } = .start,
    kind: Kind,
    opening: Opening,
    closer: Kind,
    item: Procedure,
    style: Style,
    before: u32 = 0,
    iteration: u32 = 0,
    items: u32 = 0,
    owed: bool = false,
};

const LoopStatement = struct {
    stage: enum { start, condition, done } = .start,
    kind: Kind,
};

const MethodDefinition = struct {
    stage: enum { start, keyed, typed, parameters, annotated, done } = .start,
    checkpoint: ?Checkpoint = null,
    abstracted: bool = false,
    awaits: bool = false,
    generator: bool = false,
    literal: bool = false,
};

const ModuleDeclaration = struct {
    stage: enum { start, named, done } = .start,
};

const NamespaceStatement = struct {
    stage: enum { start, done } = .start,
};

const ObjectKey = struct {
    stage: enum { start, keyed } = .start,
    checkpoint: Checkpoint,
};

const ObjectPatternMember = struct {
    stage: enum { start, keyed, done } = .start,
    checkpoint: ?Checkpoint = null,
    bound: bool = false,
};

const OptionalType = struct {
    stage: enum { start, typed } = .start,
    checkpoint: ?Checkpoint = null,
};

const Parameter = struct {
    stage: enum { start, modified, patterned, annotated, done } = .start,
    checkpoint: ?Checkpoint = null,
    defaulted: bool = false,
    optional: bool = false,
};

const ParameterModifiers = struct {
    iteration: u32 = 0,
    start: u32 = position_none,
};

const Parenthesized = struct {
    stage: enum { start, done } = .start,
};

const PatternElement = struct {
    stage: enum { start, patterned, done } = .start,
    checkpoint: ?Checkpoint = null,
    before: u32 = 0,
    bound: bool = false,
};

const QueryTarget = struct {
    stage: enum { start, called } = .start,
    checkpoint: ?Checkpoint = null,
};

const ReadonlyType = struct {
    stage: enum { start, done } = .start,
    checkpoint: ?Checkpoint = null,
};

const SignatureMember = struct {
    stage: enum { start, keyed, typed, parameters, method, annotated } = .start,
    checkpoint: ?Checkpoint = null,
    property: Kind,
    modified: u32 = 0,
    keyed: u32 = 0,
};

const Statement = struct {
    stage: enum { start, done } = .start,
};

const StatementBlock = struct {
    stage: enum { start, body } = .start,
};

const Statements = struct {
    stage: enum { start, statement } = .start,
    closer: Kind,
    before: u32 = 0,
    iteration: u32 = 0,
};

const SwitchBody = struct {
    stage: enum { start, item } = .start,
    before: u32 = 0,
    iteration: u32 = 0,
};

const SwitchCase = struct {
    stage: enum { start, head, item } = .start,
    kind: Kind,
    before: u32 = 0,
    iteration: u32 = 0,
};

const SwitchStatement = struct {
    stage: enum { start, subject, done } = .start,
};

const TemplateLiteralType = struct {
    stage: enum { start, chars } = .start,
    iteration: u32 = 0,
};

const TryStatement = struct {
    stage: enum { start, block, caught, typed, handler, done } = .start,
};

const TypeAlias = struct {
    stage: enum { start, typed, done } = .start,
};

const TypeArgumentTrailer = struct {
    stage: enum { start, done } = .start,
    checkpoint: Checkpoint,
};

const TypeConditional = struct {
    stage: enum { start, checked, extended, consequent, done } = .start,
    checkpoint: ?Checkpoint = null,
};

const TypeExpression = struct {
    stage: enum { start, done } = .start,
};

const TypeImport = struct {
    stage: enum { start, targeted, done } = .start,
    checkpoint: ?Checkpoint = null,
};

const TypeIntersection = struct {
    stage: enum { start, first, member } = .start,
    checkpoint: ?Checkpoint = null,
    leading: bool = false,
    iteration: u32 = 0,
};

const TypeOperation = struct {
    stage: enum { start, done } = .start,
    checkpoint: Checkpoint,
    kind: Kind,
};

const TypeParameter = struct {
    stage: enum { start, constrained, done } = .start,
};

const TypePostfix = struct {
    stage: enum { start, primary, done } = .start,
    checkpoint: ?Checkpoint = null,
};

const TypePredicate = struct {
    stage: enum { start, done } = .start,
};

const TypeQuery = struct {
    stage: enum { start, targeted, instantiated, closed, done } = .start,
    checkpoint: ?Checkpoint = null,
    target: ?Checkpoint = null,
};

const TypeReference = struct {
    stage: enum { start, done } = .start,
    checkpoint: ?Checkpoint = null,
    leaf: Kind,
};

const TypeTrailers = struct {
    stage: enum { start, lookup } = .start,
    checkpoint: Checkpoint,
    iteration: u32 = 0,
};

const TypeUnion = struct {
    stage: enum { start, first, member, readonly, done } = .start,
    checkpoint: ?Checkpoint = null,
    leading: bool = false,
    iteration: u32 = 0,
};

const VariableDeclarator = struct {
    stage: enum { start, patterned, annotated, done } = .start,
};

const accessibility_word_count: u32 = 3;
const balanced_slot_count: u32 = 1 << 8;
const balanced_stack_max: u32 = 1 << 6;
const loop_step_max: u32 = std.math.maxInt(u32);
const method_step_max: u32 = 8;
const modifier_step_max: u32 = 8;
const nest_depth_max: u32 = 256;
const position_none: u32 = std.math.maxInt(u32);
const resume_count_max: u64 = std.math.maxInt(u32);
pub const scan_step_max: u32 = 1 << 16;
const task_count_max: u32 = 1 << 14;
const type_modifier_max: u32 = 3;

const ambient_words = [_][]const u8{
    "abstract",
    "async",
    "enum",
    "global",
    "interface",
    "module",
    "namespace",
    "type",
};

const exported_words = [_][]const u8{
    "enum",
    "interface",
    "module",
    "namespace",
};

const modifier_words = [_][]const u8{
    "private",
    "protected",
    "public",
    "abstract",
    "accessor",
    "async",
    "declare",
    "override",
    "readonly",
    "static",
};

const predefined_names = [_][]const u8{
    "any",
    "boolean",
    "never",
    "number",
    "object",
    "string",
    "symbol",
    "unknown",
    "void",
};

comptime {
    assert(task_count_max > nest_depth_max * 8);
    assert(balanced_stack_max < balanced_slot_count);
    assert(expression.value_count_max > expression.depth_max);
}

fn owed_of(frame: *const Frame) u32 {
    assert(frame.checkpoint != null);
    assert(frame.stage <= 1);

    return switch (frame.variant) {
        .arrow, .binary => 2,
        .pair => 1,
        .ternary => 2 + @as(u32, frame.stage),
        .unary => if (frame.kind == .yield_expression) 0 else 1,
        .argument, .array, .object, .paren, .subscript, .substitution, .template, .top => 0,
    };
}

fn expression_of(sequence: bool) Task {
    const task: Task = .{ .expression = .{ .sequence = sequence } };

    assert(task.expression.stage == .start);
    assert(!task.expression.required);

    return task;
}

fn expression_decorated() Task {
    const task: Task = .{ .expression = .{ .sequence = false, .decorated = true } };

    assert(task.expression.stage == .start);
    assert(!task.expression.required);

    return task;
}

fn expression_iterated() Task {
    const task: Task = .{ .expression = .{
        .sequence = false,
        .iterated = true,
        .required = true,
    } };

    assert(task.expression.stage == .start);
    assert(task.expression.iterated);

    return task;
}

fn expression_spread() Task {
    const task: Task = .{ .expression = .{ .sequence = false, .spread = true } };

    assert(task.expression.stage == .start);
    assert(task.expression.spread);

    return task;
}

fn expression_required() Task {
    const task: Task = .{ .expression = .{ .sequence = false, .required = true } };

    assert(task.expression.stage == .start);
    assert(task.expression.required);

    return task;
}

fn enclosed(kind: Kind, inner: Procedure) Task {
    assert(kind.is_node());
    assert(kind != .error_node);

    return .{ .enclosed = .{ .kind = kind, .inner = inner } };
}

fn enclosed_closed(kind: Kind, inner: Procedure, closer: Kind) Task {
    assert(kind.is_node());
    assert(is_closer(closer));

    return .{ .enclosed = .{ .kind = kind, .inner = inner, .closer = closer } };
}

fn formal_parameters_of() Task {
    const task: Task = .{ .list = .{
        .kind = .formal_parameters,
        .opening = .expect,
        .closer = .paren_close,
        .item = .parameter,
        .style = .comma_ends,
    } };

    assert(task.list.kind.is_node());
    assert(is_closer(task.list.closer));

    return task;
}

fn argument_list_of() Task {
    const task: Task = .{ .list = .{
        .kind = .arguments,
        .opening = .bump,
        .closer = .paren_close,
        .item = .expression_single,
        .style = .comma_skips,
    } };

    assert(task.list.kind.is_node());
    assert(is_closer(task.list.closer));

    return task;
}

fn predefined_of(text: []const u8) bool {
    if (text.len == 0) return false;

    for (predefined_names) |held| {
        if (std.mem.eql(u8, held, text)) return true;
    }

    assert(text.len > 0);

    return false;
}

fn pattern_nested(kind: Kind, bound: bool) Task {
    const element: Procedure = if (bound) .binding_element else .pattern_element;
    const member: Procedure = if (bound) .object_binding_member else .object_pattern_member;

    assert(kind == .brace_open or kind == .bracket_open);
    assert(element != member);

    return switch (kind) {
        .bracket_open => .{ .list = .{
            .kind = .array_pattern,
            .opening = .bump,
            .closer = .bracket_close,
            .item = element,
            .style = .comma_skips,
        } },
        else => .{ .list = .{
            .kind = .object_pattern,
            .opening = .bump,
            .closer = .brace_close,
            .item = member,
            .style = .comma_skips,
        } },
    };
}

fn terminates_line(gap: []const u8) bool {
    assert(gap.len > 0);

    if (std.mem.findAny(u8, gap, "\n\r") != null) return true;

    const separator = std.mem.find(u8, gap, "\u{2028}") != null;
    const paragraph = std.mem.find(u8, gap, "\u{2029}") != null;

    return separator or paragraph;
}

fn list_elides(state: *const List) bool {
    assert(state.closer.is_token());
    assert(state.kind.is_node());

    if (state.style == .semicolon_skips) return true;
    return state.kind == .array_pattern;
}
