const std = @import("std");
const assert = std.debug.assert;
const Checker = @import("check.zig").Checker;
const Checkpoint = @import("../tree.zig").Checkpoint;
const EventsType = @import("../tree.zig").EventsType;
const Kind = @import("kind.zig").Kind;
const Span = @import("../../stdx/bounded/span.zig");
const Structure = @import("../tree.zig").Structure;
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const Token = @import("../token.zig");
const TreeType = @import("../tree.zig").TreeType;
const expression = @import("expression.zig");
const Events = EventsType(Kind);
const Frame = expression.Frame;
const Tree = TreeType(Kind);

pub const Parser = struct {
    braced: bool,
    checker: Checker,
    events: *Events,
    frame_count: u32,
    frames: [expression.depth_max]Frame,
    nesting: u32,
    outcome: Structure,
    position: u32,
    raw: []const Kind,
    returned: Step,
    significant_next: u32,
    source: []const u8,
    statement_closed: bool,
    suffixable: bool,
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
            .braced = false,
            .checker = undefined,
            .events = events,
            .frame_count = 0,
            .frames = undefined,
            .nesting = 0,
            .outcome = .complete,
            .position = 0,
            .raw = raw,
            .returned = .done,
            .significant_next = 0,
            .source = source,
            .statement_closed = false,
            .suffixable = true,
            .task_count = 0,
            .tasks = undefined,
            .tokens = tokens,
            .tree = tree,
            .value_count = 0,
            .values = undefined,
        };

        parser.checked();
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
        return replayed;
    }

    fn checked(parser: *Parser) void {
        assert(parser.tree.diagnostic_slice().len == 0);
        assert(parser.position == 0);

        const failure = parser.checker.check(parser.source) orelse return;
        const end: u32 = @intCast(parser.source.len);
        const position = parser.token_at(failure.offset);
        const wanted: ?u16 = if (failure.expected) |kind| kind.to_u16() else null;

        assert(failure.offset <= end);

        const pushed: Diagnostic = if (position) |index| .{
            .expected = wanted,
            .found = parser.raw[index].to_u16(),
            .kind = failure.kind,
            .span = Span.between(failure.offset, parser.tokens[index].end()),
        } else .{
            .expected = wanted,
            .found = null,
            .kind = failure.kind,
            .span = Span{ .offset = failure.offset, .length = 0 },
        };

        parser.tree.push_diagnostic(pushed) catch |err| switch (err) {
            error.Truncated => parser.outcome = .{ .truncated = .diagnostics },
        };
    }

    fn token_at(parser: *const Parser, offset: u32) ?u32 {
        assert(offset <= parser.source.len);
        assert(parser.tokens.len <= std.math.maxInt(u32));

        var low: u32 = 0;
        var high: u32 = @intCast(parser.tokens.len);

        while (low < high) {
            const middle = low + (high - low) / 2;

            if (parser.tokens[middle].end() <= offset) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }

        assert(low <= parser.tokens.len);

        if (low == parser.tokens.len) return null;
        if (parser.tokens[low].offset > offset) return null;
        return low;
    }

    fn run(parser: *Parser) void {
        assert(parser.position == 0);
        assert(parser.task_count == 0);

        parser.events.start(.root);

        var iteration: u32 = 0;

        while (iteration < member_iteration_max) : (iteration += 1) {
            parser.skip_trivia();

            if (parser.current() == null) break;

            const before = parser.position;

            parser.drive(.{ .member = .{} });
            parser.progress_force(before);

            assert(parser.position > before);
            assert(parser.nesting == 0);
        }

        assert(parser.position == parser.count());

        parser.events.finish();
    }

    fn drive(parser: *Parser, task: Task) void {
        assert(parser.task_count == 0);
        assert(task == .member);

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
            .assembly => |*state| parser.assembly_resume(state),
            .assembly_operands => |*state| parser.assembly_operands_resume(state),
            .block => |*state| parser.block_resume(state),
            .block_value => |*state| parser.block_value_resume(state),
            .bracket_type => |*state| parser.bracket_type_resume(state),
            .branch_body => |*state| parser.branch_body_resume(state),
            .callable_attributes => |*state| parser.callable_attributes_resume(state),
            .container_body => |*state| parser.container_body_resume(state),
            .container_field => |*state| parser.container_field_resume(state),
            .container_type => |*state| parser.container_type_resume(state),
            .deferred => |*state| parser.deferred_resume(state),
            .destructure => |*state| parser.destructure_resume(state),
            .expression => |*state| parser.expression_resume(state),
            .expression_statement => |*state| parser.expression_statement_resume(state),
            .for_inputs => |*state| parser.for_inputs_resume(state),
            .function => |*state| parser.function_resume(state),
            .function_type => |*state| parser.function_type_resume(state),
            .if_expression => |*state| parser.if_resume(state),
            .loop => |*state| parser.loop_resume(state),
            .member => |*state| parser.member_resume(state),
            .parameter_list => |*state| parser.parameter_list_resume(state),
            .parenthesized => |*state| parser.parenthesized_resume(state),
            .pointer_attributes => |*state| parser.pointer_attributes_resume(state),
            .pointer_type => |*state| parser.pointer_type_resume(state),
            .statement => |*state| parser.statement_resume(state),
            .switch_case => |*state| parser.switch_case_resume(state),
            .switch_expression => |*state| parser.switch_resume(state),
            .variable_declaration => |*state| parser.variable_declaration_resume(state),
        };
    }

    fn member_resume(parser: *Parser, state: *Member) Resumed {
        assert(parser.task_count > 0);
        if (state.stage != .start) assert(state.checkpoint != null);

        switch (state.stage) {
            .start => {
                if (!parser.descend()) {
                    parser.emit();

                    return .returned;
                }

                state.checkpoint = parser.anchor();

                return parser.member_open(state);
            },
            .test_body => parser.enclose(state.checkpoint.?, .test_decl),
            .comptime_body => parser.enclose(state.checkpoint.?, .@"comptime"),
            .function => {},
            .variable => _ = parser.eat(.semicolon),
            .field => _ = parser.eat(.comma),
        }

        parser.ascend();

        return .returned;
    }

    fn member_open(parser: *Parser, state: *Member) Resumed {
        assert(state.stage == .start);
        assert(parser.nesting > 0);

        if (parser.at(.test_keyword)) {
            parser.bump();

            const named = parser.at(.text) or parser.at(.identifier);

            if (named) parser.bump();

            state.stage = .test_body;

            return parser.call(.{ .block = .{ .checkpoint = parser.anchor() } });
        }

        const comptime_block = parser.at(.comptime_keyword) and parser.ahead(1) == .brace_open;

        if (comptime_block) {
            parser.bump();
            state.stage = .comptime_body;

            return parser.call(.{ .block = .{ .checkpoint = parser.anchor() } });
        }

        parser.modifiers();

        const kind = parser.current() orelse {
            parser.ascend();

            return .returned;
        };

        switch (kind) {
            .fn_keyword => {
                state.stage = .function;

                return parser.call(.{ .function = .{ .checkpoint = state.checkpoint.? } });
            },
            .const_keyword, .var_keyword => {
                state.stage = .variable;

                return parser.call(.{
                    .variable_declaration = .{ .checkpoint = state.checkpoint.? },
                });
            },
            else => {
                state.stage = .field;

                return parser.call(.{ .container_field = .{ .checkpoint = state.checkpoint.? } });
            },
        }
    }

    fn modifiers(parser: *Parser) void {
        assert(parser.nesting > 0);
        assert(!parser.at(.test_keyword));

        for (0..parser.steps()) |_| {
            const kind = parser.current() orelse return;

            const held = switch (kind) {
                .comptime_keyword,
                .export_keyword,
                .noinline_keyword,
                .pub_keyword,
                .threadlocal_keyword,
                => true,
                .extern_keyword => !opens_a_container(parser.ahead(1)),
                .inline_keyword => !opens_a_loop(parser.ahead(1)),
                else => false,
            };

            if (!held) return;

            parser.bump();

            if (kind == .comptime_keyword) return;

            if (kind == .extern_keyword) _ = parser.eat(.text);
        }
    }

    fn function_resume(parser: *Parser, state: *Function) Resumed {
        assert(parser.nesting > 0);

        switch (state.stage) {
            .start => {
                assert(parser.at(.fn_keyword));

                parser.bump();

                if (parser.at(.identifier)) parser.bump();

                state.stage = .parameters;

                return parser.call(.{ .parameter_list = .{} });
            },
            .parameters => {
                state.stage = .attributes;

                return parser.call(.{ .callable_attributes = .{} });
            },
            .attributes => {
                _ = parser.eat(.bang);
                state.stage = .result;

                return parser.call(expression_of(context_type));
            },
            .result => {
                parser.enclose(state.checkpoint, .fn_proto);

                if (!parser.at(.brace_open)) {
                    _ = parser.eat(.semicolon);

                    return .returned;
                }

                state.stage = .body;

                return parser.call(.{ .block = .{ .checkpoint = parser.anchor() } });
            },
            .body => {
                parser.enclose(state.checkpoint, .fn_decl);

                return .returned;
            },
        }
    }

    fn parameter_list_resume(parser: *Parser, state: *ParameterList) Resumed {
        assert(state.iteration <= parser.steps());
        if (state.stage == .parameter) assert(state.before <= parser.position);

        stage: switch (state.stage) {
            .start => {
                if (!parser.eat(.paren_open)) return .returned;

                continue :stage .parameters;
            },
            .parameters => {
                if (parser.list_closed(&state.iteration, .paren_close)) {
                    _ = parser.eat(.paren_close);

                    return .returned;
                }

                state.before = parser.position;

                parser.parameter_prefix();

                const untyped = parser.at(.anytype_keyword) or parser.at(.dot_dot_dot);

                if (untyped) {
                    parser.bump();

                    continue :stage .parameter;
                }

                state.stage = .parameter;

                return parser.call(expression_of(context_type));
            },
            .parameter => {
                if (!parser.eat(.comma)) {
                    _ = parser.eat(.paren_close);

                    return .returned;
                }

                if (parser.position == state.before) parser.emit();

                continue :stage .parameters;
            },
        }
    }

    fn parameter_prefix(parser: *Parser) void {
        assert(parser.nesting > 0);

        const before = parser.position;

        _ = parser.eat(.comptime_keyword);
        _ = parser.eat(.noalias_keyword);

        const labelled = parser.at(.identifier) and parser.ahead(1) == .colon;

        if (labelled) {
            parser.bump();
            parser.bump();
        }

        if (labelled) assert(parser.position >= before + 2);
    }

    fn callable_attributes_resume(parser: *Parser, state: *Attributes) Resumed {
        assert(state.iteration <= parser.steps());
        assert(parser.nesting > 0);

        if (state.iteration == parser.steps()) return .returned;

        state.iteration += 1;

        const kind = parser.current() orelse return .returned;

        const held = switch (kind) {
            .addrspace_keyword, .align_keyword, .callconv_keyword, .linksection_keyword => true,
            else => false,
        };

        if (!held) return .returned;

        parser.bump();

        return parser.call(.{ .parenthesized = .{} });
    }

    fn pointer_attributes_resume(parser: *Parser, state: *Attributes) Resumed {
        assert(state.iteration <= parser.steps());

        while (state.iteration < parser.steps()) {
            state.iteration += 1;

            const kind = parser.current() orelse return .returned;

            switch (kind) {
                .allowzero_keyword, .const_keyword, .volatile_keyword => parser.bump(),
                .addrspace_keyword => {
                    parser.bump();

                    return parser.call(.{ .parenthesized = .{} });
                },
                .align_keyword => {
                    parser.bump();

                    return parser.call(.{ .parenthesized = .{ .ranged = true } });
                },
                else => return .returned,
            }
        }

        assert(state.iteration == parser.steps());

        return .returned;
    }

    fn parenthesized_resume(parser: *Parser, state: *Parenthesized) Resumed {
        assert(parser.nesting > 0);
        assert(parser.task_count > 1);

        switch (state.stage) {
            .start => {
                if (!parser.eat(.paren_open)) return .returned;

                state.stage = .inner;

                return parser.call(expression_of(context_expression));
            },
            .inner => {
                if (state.ranged) {
                    if (parser.eat(.colon)) {
                        state.stage = .ranged;

                        return parser.call(expression_of(context_expression));
                    }
                }

                _ = parser.eat(.paren_close);

                return .returned;
            },
            .ranged => {
                _ = parser.eat(.colon);
                state.stage = .closed;

                return parser.call(expression_of(context_expression));
            },
            .closed => {
                _ = parser.eat(.paren_close);

                return .returned;
            },
        }
    }

    fn variable_declaration_resume(parser: *Parser, state: *VariableDeclaration) Resumed {
        assert(parser.nesting > 0);

        stage: switch (state.stage) {
            .start => {
                assert(is_declaration(parser.current()));

                parser.bump();

                if (parser.at(.identifier)) parser.bump();

                if (parser.eat(.colon)) {
                    state.stage = .typed;

                    return parser.call(expression_of(context_type));
                }

                continue :stage .typed;
            },
            .typed => {
                state.stage = .attributed;

                return parser.call(.{ .callable_attributes = .{} });
            },
            .attributed => {
                if (parser.eat(.equal)) {
                    state.stage = .valued;

                    return parser.call(expression_of(context_expression));
                }

                continue :stage .valued;
            },
            .valued => {
                parser.enclose(state.checkpoint, .var_decl);

                return .returned;
            },
        }
    }

    fn container_field_resume(parser: *Parser, state: *ContainerField) Resumed {
        assert(parser.nesting > 0);

        stage: switch (state.stage) {
            .start => {
                const labelled = parser.at(.identifier) and parser.ahead(1) == .colon;

                if (labelled) {
                    parser.bump();
                    parser.bump();
                }

                state.stage = .typed;

                return parser.call(expression_of(context_type));
            },
            .typed => {
                if (parser.at(.align_keyword)) {
                    parser.bump();
                    state.stage = .aligned;

                    return parser.call(.{ .parenthesized = .{} });
                }

                continue :stage .aligned;
            },
            .aligned => {
                if (parser.eat(.equal)) {
                    state.stage = .valued;

                    return parser.call(expression_of(context_expression));
                }

                continue :stage .valued;
            },
            .valued => {
                parser.enclose(state.checkpoint, .container_field);

                return .returned;
            },
        }
    }

    fn block_resume(parser: *Parser, state: *Block) Resumed {
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .start => {
                if (!parser.descend()) {
                    parser.emit();

                    return .returned;
                }

                parser.expect(.brace_open, .unexpected_token);

                continue :stage .statements;
            },
            .statements => {
                if (parser.list_closed(&state.iteration, .brace_close)) {
                    _ = parser.eat(.brace_close);

                    parser.enclose(state.checkpoint, .block);
                    parser.ascend();

                    return .returned;
                }

                state.before = parser.position;
                state.stage = .statement;

                return parser.call(.{ .statement = .{} });
            },
            .statement => {
                parser.progress_force(state.before);

                continue :stage .statements;
            },
        }
    }

    fn statement_resume(parser: *Parser, state: *Statement) Resumed {
        assert(parser.task_count > 1);
        if (state.stage != .start) assert(parser.nesting > 0);

        switch (state.stage) {
            .start => {
                if (!parser.descend()) {
                    parser.emit();

                    return .returned;
                }

                const checkpoint = parser.anchor();
                if (parser.statement_open(state, checkpoint)) |task| return parser.call(task);
            },
            .declared => {
                if (parser.statement_closed) {
                    parser.statement_closed = false;
                } else {
                    _ = parser.eat(.semicolon);
                }
            },
            .finished => {},
        }

        parser.ascend();

        return .returned;
    }

    fn statement_open(parser: *Parser, state: *Statement, checkpoint: Checkpoint) ?Task {
        assert(state.stage == .start);
        assert(parser.nesting > 0);
        assert(checkpoint.index <= parser.events.count());

        const kind = parser.current() orelse return null;

        state.stage = .finished;

        switch (kind) {
            .semicolon => {
                parser.bump();

                return null;
            },
            .brace_open => return .{ .block = .{ .checkpoint = checkpoint } },
            .comptime_keyword => return parser.comptime_statement(state, checkpoint),
            .const_keyword, .var_keyword => {
                if (parser.destructures()) return .{ .destructure = .{ .checkpoint = checkpoint } };

                state.stage = .declared;

                return .{ .variable_declaration = .{ .checkpoint = checkpoint } };
            },
            .defer_keyword => return parser.deferred_open(checkpoint, .@"defer"),
            .errdefer_keyword => {
                parser.bump();
                parser.payload();

                return .{ .deferred = .{ .checkpoint = checkpoint, .kind = .@"errdefer" } };
            },
            .suspend_keyword => return parser.deferred_open(checkpoint, .@"suspend"),
            .nosuspend_keyword => return parser.deferred_open(checkpoint, .@"nosuspend"),
            else => {
                if (parser.labels_a_block()) {
                    parser.bump();
                    parser.bump();

                    return .{ .block = .{ .checkpoint = checkpoint } };
                }

                const destructuring = parser.targets_a_destructure() and parser.destructures();
                if (destructuring) return .{ .destructure = .{ .checkpoint = checkpoint } };

                state.stage = .declared;

                return .{ .expression_statement = .{ .checkpoint = checkpoint } };
            },
        }
    }

    fn comptime_statement(parser: *Parser, state: *Statement, checkpoint: Checkpoint) Task {
        assert(state.stage == .finished);
        assert(parser.at(.comptime_keyword));
        assert(checkpoint.index <= parser.events.count());

        if (is_declaration(parser.ahead(1))) {
            if (parser.destructures()) return .{ .destructure = .{ .checkpoint = checkpoint } };

            parser.bump();
            state.stage = .declared;

            return .{ .variable_declaration = .{ .checkpoint = checkpoint } };
        }

        if (parser.ahead(1) != .brace_open) {
            if (parser.destructures()) {
                parser.bump();

                return .{ .destructure = .{ .checkpoint = parser.anchor() } };
            }
        }

        return parser.deferred_open(checkpoint, .@"comptime");
    }

    fn deferred_open(parser: *Parser, checkpoint: Checkpoint, kind: Kind) Task {
        assert(kind.is_node());
        assert(parser.current() != null);
        assert(checkpoint.index <= parser.events.count());

        parser.bump();

        return .{ .deferred = .{ .checkpoint = checkpoint, .kind = kind } };
    }

    fn deferred_resume(parser: *Parser, state: *Deferred) Resumed {
        assert(state.kind.is_node());

        switch (state.stage) {
            .start => {
                const held = parser.anchor();

                state.stage = .body;

                if (parser.labels_a_block()) {
                    parser.bump();
                    parser.bump();
                }

                if (parser.at(.brace_open)) {
                    return parser.call(.{ .block = .{ .checkpoint = held } });
                }

                if (parser.body_destructures()) |checkpoint| {
                    return parser.call(.{
                        .destructure = .{ .checkpoint = checkpoint, .terminated = false },
                    });
                }

                return parser.call(.{
                    .expression_statement = .{ .checkpoint = held, .context = context_expression },
                });
            },
            .body => {
                parser.enclose(state.checkpoint, state.kind);
                _ = parser.eat(.semicolon);

                return .returned;
            },
        }
    }

    fn destructure_resume(parser: *Parser, state: *Destructure) Resumed {
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .elements => {
                if (state.iteration == parser.steps()) continue :stage .assigned;

                state.iteration += 1;
                state.held = parser.anchor();

                const comptime_held = parser.at(.comptime_keyword) and
                    is_declaration(parser.ahead(1));

                if (comptime_held) parser.bump();

                if (!is_declaration(parser.current())) {
                    state.stage = .element;

                    return parser.call(expression_of(context_expression));
                }

                parser.bump();

                if (parser.at(.identifier)) parser.bump();

                if (parser.eat(.colon)) {
                    state.stage = .typed;

                    return parser.call(expression_of(context_type));
                }

                continue :stage .typed;
            },
            .typed => {
                assert(state.held != null);

                parser.enclose(state.held.?, .var_decl);

                continue :stage .element;
            },
            .element => {
                if (parser.eat(.comma)) continue :stage .elements;

                continue :stage .assigned;
            },
            .assigned => {
                _ = parser.eat(.equal);
                state.stage = .valued;

                return parser.call(expression_of(context_expression));
            },
            .valued => {
                parser.enclose(state.checkpoint, .assign_destructure);

                if (state.terminated) _ = parser.eat(.semicolon);

                return .returned;
            },
        }
    }

    fn expression_statement_resume(parser: *Parser, state: *ExpressionStatement) Resumed {
        if (state.stage == .right) assert(state.node.is_node());

        switch (state.stage) {
            .start => {
                state.stage = .left;

                return parser.call(expression_of(state.context));
            },
            .left => {
                if (parser.statement_closed) return .returned;

                const kind = parser.current() orelse return .returned;
                const node = expression.assignment_of(kind) orelse return .returned;

                parser.bump();
                state.node = node;
                state.stage = .right;

                return parser.call(expression_of(context_expression));
            },
            .right => {
                parser.enclose(state.checkpoint, state.node);

                return .returned;
            },
        }
    }

    fn expression_resume(parser: *Parser, state: *Expression) Resumed {
        assert(state.context <= context_statement);
        if (state.stage != .start) assert(parser.frame_count > state.frames_base);

        stage: switch (state.stage) {
            .start => {
                if (!parser.expression_open(state)) return .returned;

                continue :stage .machine;
            },
            .machine => {
                if (state.iteration == machine_step_max) continue :stage .finished;

                state.iteration += 1;
                state.before = parser.progress();

                if (state.operand) {
                    switch (parser.operand_step(state.frames_base)) {
                        .step => |step| {
                            if (parser.machine_advanced(state, step)) continue :stage .machine;

                            continue :stage .finished;
                        },
                        .call => |task| {
                            state.stage = .resumed;

                            return parser.call(task);
                        },
                    }
                }

                const step = parser.operator_step(state.frames_base);
                if (parser.machine_advanced(state, step)) continue :stage .machine;

                continue :stage .finished;
            },
            .resumed => {
                if (parser.machine_advanced(state, parser.returned)) continue :stage .machine;

                continue :stage .finished;
            },
            .finished => {
                parser.reduce_above(state.frames_base + 1);

                assert(parser.frame_count == state.frames_base + 1);

                if (parser.value_count == state.values_base) parser.record(.expected_expression);

                parser.frame_count = state.frames_base;
                parser.value_count = state.values_base;

                parser.ascend();

                return .returned;
            },
        }
    }

    fn expression_open(parser: *Parser, state: *Expression) bool {
        assert(state.stage == .start);
        assert(state.context <= context_statement);

        if (!parser.descend()) {
            parser.emit();

            return false;
        }

        state.frames_base = parser.frame_count;
        state.values_base = parser.value_count;

        var frame: Frame = .empty;

        frame.checkpoint = parser.anchor();
        frame.stage = state.context;
        frame.values = parser.value_count;
        frame.variant = .top;

        if (!parser.push_frame(frame)) {
            parser.ascend();

            return false;
        }

        assert(parser.frame_count == state.frames_base + 1);

        return true;
    }

    fn machine_advanced(parser: *Parser, state: *Expression, step: Step) bool {
        assert(parser.frame_count >= state.frames_base);
        assert(state.iteration > 0);

        switch (step) {
            .operand => state.operand = true,
            .operator => state.operand = false,
            .done => {
                if (!state.operand) return false;

                switch (parser.operator_step(state.frames_base)) {
                    .done => return false,
                    .operand => state.operand = true,
                    .operator => state.operand = false,
                }
            },
        }

        const now = parser.progress();
        if (now.position != state.before.position) return true;
        if (now.frame_count != state.before.frame_count) return true;
        return now.value_count != state.before.value_count;
    }

    fn operand_step(parser: *Parser, base: u32) Advance {
        assert(base < parser.frame_count);

        parser.skip_trivia();

        const group = parser.innermost_group(base);
        const kind = parser.current() orelse return .{ .step = .done };
        const frame = &parser.frames[group];

        assert(frame.is_group());

        if (frame.is_bracketed()) {
            if (kind == frame.closer) return .{ .step = .done };
        }

        if (frame.variant == .init) {
            if (frame.stage == 0) frame.stage = 1;

            const named = kind == .dot and parser.ahead(1) == .identifier and
                parser.ahead(2) == .equal;

            if (named) {
                frame.stage = 2;

                parser.bump();
                parser.bump();
                parser.bump();

                return .{ .step = .operand };
            }
        }

        return parser.operand_of(kind, base);
    }

    fn operand_of(parser: *Parser, kind: Kind, base: u32) Advance {
        assert(base < parser.frame_count);
        assert(parser.current() == kind);

        const labelling = switch (kind) {
            .identifier, .inline_keyword => parser.labels_a_loop(),
            else => false,
        };

        if (labelling) return parser.labelled_operand(base);

        const step: Step = switch (kind) {
            .identifier => parser.leaf(.identifier_node),
            .number => parser.leaf(.number_literal),
            .unreachable_keyword => parser.leaf(.unreachable_literal),
            .text_line => parser.multiline_text(),
            .character, .text => parser.leaf(expression.literal_node(kind)),
            .builtin => parser.builtin_call(),
            .dot => parser.dotted(),
            .error_keyword => parser.error_of(),
            .anyframe_keyword => parser.anyframe_of(),
            .question => parser.prefix(.optional_type, expression.power_prefix, stage_type),
            .paren_open => parser.grouped(),
            .break_keyword, .continue_keyword => parser.branch(kind),
            .return_keyword => parser.keyword_prefix(.@"return"),
            .comptime_keyword => parser.keyword_prefix(.@"comptime"),
            .nosuspend_keyword => parser.keyword_prefix(.@"nosuspend"),
            .resume_keyword => parser.keyword_prefix(.@"resume"),
            .suspend_keyword => parser.keyword_prefix(.@"suspend"),
            else => return parser.operand_task(kind, base),
        };

        return .{ .step = step };
    }

    fn operand_task(parser: *Parser, kind: Kind, base: u32) Advance {
        assert(base < parser.frame_count);
        assert(kind.is_token());

        const task: Task = switch (kind) {
            .star, .star_star => .{ .pointer_type = .{} },
            .bracket_open => .{ .bracket_type = .{} },
            .brace_open => .{ .block_value = .{ .checkpoint = parser.anchor() } },
            .fn_keyword => .{ .function_type = .{} },
            .if_keyword => .{ .if_expression = .{ .base = base } },
            .switch_keyword => .{
                .switch_expression = .{
                    .checkpoint = parser.anchor(),
                    .leading = parser.leads_a_statement(base),
                },
            },
            .for_keyword, .while_keyword => .{
                .loop = .{ .checkpoint = parser.anchor(), .base = base },
            },
            .asm_keyword => .{ .assembly = .{} },
            .enum_keyword,
            .extern_keyword,
            .opaque_keyword,
            .packed_keyword,
            .struct_keyword,
            .union_keyword,
            => .{ .container_type = .{} },
            else => {
                const node = expression.prefix_of(kind) orelse return .{ .step = .done };
                return .{ .step = parser.prefix(node, expression.power_prefix, stage_value) };
            },
        };

        return .{ .call = task };
    }

    fn labelled_operand(parser: *Parser, base: u32) Advance {
        assert(base < parser.frame_count);
        assert(parser.labels_a_loop());

        const checkpoint = parser.anchor();

        if (parser.at(.identifier)) {
            parser.bump();
            parser.bump();
        }

        _ = parser.eat(.inline_keyword);

        if (parser.at(.brace_open)) {
            return .{ .call = .{ .block_value = .{ .checkpoint = checkpoint, .labelled = true } } };
        }

        if (parser.at(.switch_keyword)) {
            return .{
                .call = .{
                    .switch_expression = .{
                        .checkpoint = checkpoint,
                        .leading = parser.leads_a_statement(base),
                    },
                },
            };
        }

        return .{ .call = .{ .loop = .{ .checkpoint = checkpoint, .base = base } } };
    }

    fn leaf(parser: *Parser, kind: Kind) Step {
        assert(kind.is_node());
        assert(parser.current() != null);

        const checkpoint = parser.anchor();

        parser.open(kind);
        parser.emit();
        parser.events.finish();

        return parser.settle(checkpoint, true);
    }

    fn settle(parser: *Parser, checkpoint: Checkpoint, suffixable: bool) Step {
        assert(checkpoint.index <= parser.events.count());

        parser.push_value(checkpoint);
        parser.suffixable = suffixable;

        assert(parser.value_count > 0);

        return .operator;
    }

    fn multiline_text(parser: *Parser) Step {
        assert(parser.at(.text_line));

        const checkpoint = parser.anchor();

        parser.open(.multiline_string_literal);

        for (0..parser.steps()) |_| {
            if (!parser.at(.text_line)) break;

            parser.bump();
        }

        assert(!parser.at(.text_line));

        parser.events.finish();

        return parser.settle(checkpoint, true);
    }

    fn builtin_call(parser: *Parser) Step {
        assert(parser.at(.builtin));
        assert(parser.frame_count > 0);

        const checkpoint = parser.anchor();

        parser.bump();

        if (!parser.at(.paren_open)) return parser.settle(checkpoint, true);
        return parser.open_group(.call, checkpoint, .builtin_call);
    }

    fn dotted(parser: *Parser) Step {
        assert(parser.at(.dot));
        assert(parser.frame_count > 0);

        const checkpoint = parser.anchor();

        if (parser.ahead(1) == .brace_open) {
            parser.bump();

            return parser.open_group(.init, checkpoint, .struct_init_dot);
        }

        parser.open(.enum_literal);
        parser.emit();

        if (parser.at(.identifier)) parser.bump();

        parser.events.finish();

        return parser.settle(checkpoint, true);
    }

    fn error_of(parser: *Parser) Step {
        assert(parser.at(.error_keyword));
        assert(parser.frame_count > 0);

        const checkpoint = parser.anchor();

        if (parser.ahead(1) == .dot) {
            parser.open(.error_value);
            parser.emit();
            parser.bump();

            if (parser.at(.identifier)) parser.bump();

            parser.events.finish();

            return parser.settle(checkpoint, true);
        }

        parser.open(.error_set_decl);
        parser.bump();

        if (parser.eat(.brace_open)) {
            var iteration: u32 = 0;

            for (0..parser.steps()) |_| {
                if (parser.list_closed(&iteration, .brace_close)) break;

                const before = parser.position;

                parser.bump();

                if (!parser.eat(.comma)) break;
                if (parser.position == before) break;
            }

            assert(iteration <= parser.steps());

            _ = parser.eat(.brace_close);
        }

        parser.events.finish();

        return parser.settle(checkpoint, true);
    }

    fn anyframe_of(parser: *Parser) Step {
        assert(parser.at(.anyframe_keyword));
        assert(parser.frame_count > 0);

        const next = parser.ahead(1);
        const literal = next != .minus and next != .arrow;
        if (literal) return parser.leaf(.anyframe_literal);

        const pushed = parser.push_frame(parser.unary_of(.anyframe_type, stage_type));
        if (!pushed) return .done;

        parser.bump();
        parser.bump();

        if (parser.at(.greater)) parser.bump();

        return .operand;
    }

    fn grouped(parser: *Parser) Step {
        assert(parser.at(.paren_open));
        assert(parser.frame_count > 0);

        const checkpoint = parser.anchor();
        return parser.open_group(.paren, checkpoint, .grouped_expression);
    }

    fn prefix(parser: *Parser, kind: Kind, power: u8, stage: u8) Step {
        assert(kind.is_node());
        assert(stage <= stage_keep);

        var frame = parser.unary_of(kind, stage);

        frame.power = power;

        if (!parser.push_frame(frame)) return .done;

        parser.bump();

        return .operand;
    }

    fn keyword_prefix(parser: *Parser, kind: Kind) Step {
        assert(kind.is_node());
        assert(parser.current() != null);

        return parser.prefix(kind, expression.power_barrier, stage_keep);
    }

    fn unary_of(parser: *Parser, kind: Kind, stage: u8) Frame {
        assert(kind.is_node());
        assert(stage <= stage_keep);

        var frame: Frame = .empty;

        frame.checkpoint = parser.anchor();
        frame.kind = kind;
        frame.power = expression.power_prefix;
        frame.stage = stage;
        frame.values = parser.value_count;
        frame.variant = .unary;

        return frame;
    }

    fn branch(parser: *Parser, kind: Kind) Step {
        if (kind != .break_keyword) assert(kind == .continue_keyword);
        assert(parser.at(kind));

        const node: Kind = if (kind == .break_keyword) .@"break" else .@"continue";
        if (parser.keyword_prefix(node) == .done) return .done;

        if (parser.at(.colon)) {
            if (parser.ahead(1) == .identifier) {
                parser.bump();
                parser.bump();
            }
        }

        return .operand;
    }

    fn block_value_resume(parser: *Parser, state: *BlockValue) Resumed {
        assert(parser.frame_count > 0);

        switch (state.stage) {
            .start => {
                state.stage = .body;

                return parser.call(.{ .block = .{ .checkpoint = state.checkpoint } });
            },
            .body => {
                parser.returned = parser.settle(state.checkpoint, state.labelled);

                return .returned;
            },
        }
    }

    fn pointer_type_resume(parser: *Parser, state: *PointerType) Resumed {
        assert(parser.frame_count > 0);

        switch (state.stage) {
            .start => {
                const doubled = parser.at(.star_star);
                const frame = parser.unary_of(.ptr_type, stage_type);

                if (!doubled) assert(parser.at(.star));

                if (doubled) {
                    if (!parser.push_frame(frame)) return parser.operand_returned(.done);
                }

                if (!parser.push_frame(frame)) return parser.operand_returned(.done);

                parser.bump();
                state.stage = .attributes;

                return parser.call(.{ .pointer_attributes = .{} });
            },
            .attributes => return parser.operand_returned(.operand),
        }
    }

    fn bracket_type_resume(parser: *Parser, state: *BracketType) Resumed {
        assert(parser.frame_count > 0);

        stage: switch (state.stage) {
            .start => {
                assert(parser.at(.bracket_open));

                state.checkpoint = parser.anchor();

                parser.bump();

                switch (parser.current() orelse .error_token) {
                    .star => {
                        parser.bump();

                        if (parser.at(.identifier)) parser.bump();
                    },
                    .bracket_close, .colon => {},
                    else => {
                        state.kind = .array_type;
                        state.stage = .length;

                        return parser.call(expression_of(context_expression));
                    },
                }

                continue :stage .length;
            },
            .length => {
                if (parser.eat(.colon)) {
                    state.stage = .sentinel;

                    return parser.call(expression_of(context_expression));
                }

                continue :stage .sentinel;
            },
            .sentinel => {
                _ = parser.eat(.bracket_close);
                state.stage = .attributes;

                return parser.call(.{ .pointer_attributes = .{} });
            },
            .attributes => {
                assert(state.checkpoint != null);

                var frame: Frame = .empty;

                frame.checkpoint = state.checkpoint;
                frame.kind = state.kind;
                frame.power = expression.power_prefix;
                frame.stage = stage_type;
                frame.values = parser.value_count;
                frame.variant = .unary;

                if (!parser.push_frame(frame)) return parser.operand_returned(.done);
                return parser.operand_returned(.operand);
            },
        }
    }

    fn operand_returned(parser: *Parser, step: Step) Resumed {
        assert(parser.task_count > 0);
        assert(parser.frame_count <= expression.depth_max);

        parser.returned = step;

        return .returned;
    }

    fn function_type_resume(parser: *Parser, state: *FunctionType) Resumed {
        assert(parser.frame_count > 0);

        switch (state.stage) {
            .start => {
                assert(parser.at(.fn_keyword));

                state.checkpoint = parser.anchor();

                parser.bump();

                if (parser.at(.identifier)) parser.bump();

                state.stage = .parameters;

                return parser.call(.{ .parameter_list = .{} });
            },
            .parameters => {
                state.stage = .attributes;

                return parser.call(.{ .callable_attributes = .{} });
            },
            .attributes => {
                _ = parser.eat(.bang);
                state.stage = .result;

                return parser.call(expression_of(context_type));
            },
            .result => {
                assert(state.checkpoint != null);

                parser.enclose(state.checkpoint.?, .fn_proto);

                return parser.operand_returned(parser.settle(state.checkpoint.?, true));
            },
        }
    }

    fn if_resume(parser: *Parser, state: *If) Resumed {
        assert(state.base < parser.frame_count);
        assert(state.links == state.iteration);

        stage: switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();
                state.leading = parser.leads_a_statement(state.base);

                continue :stage .arm;
            },
            .arm => {
                if (state.iteration == parser.steps()) continue :stage .closed;

                state.iteration += 1;

                parser.open(.@"if");
                state.links += 1;

                parser.bump();
                _ = parser.eat(.paren_open);
                state.stage = .condition;

                return parser.call(expression_of(context_expression));
            },
            .condition => {
                _ = parser.eat(.paren_close);

                parser.payload();
                state.stage = .body;

                const mode: BodyMode = if (state.leading) .assign else .expression;
                return parser.call(.{ .branch_body = .{ .base = state.base, .mode = mode } });
            },
            .body => {
                if (!parser.eat(.else_keyword)) continue :stage .closed;

                parser.payload();

                if (parser.at(.if_keyword)) continue :stage .arm;

                state.stage = .closed;

                const mode: BodyMode = if (state.leading) .statement else .expression;
                return parser.call(.{ .branch_body = .{ .base = state.base, .mode = mode } });
            },
            .closed => {
                assert(state.links > 0);

                for (0..state.links) |_| {
                    parser.events.finish();
                }

                if (state.leading) parser.statement_closed = parser.braced;

                return parser.operand_returned(parser.settle(state.checkpoint.?, false));
            },
        }
    }

    fn branch_body_resume(parser: *Parser, state: *BranchBody) Resumed {
        assert(state.base < parser.frame_count);
        if (state.stage == .right) assert(state.checkpoint != null);

        switch (state.stage) {
            .start => return parser.branch_body_open(state),
            .left => {
                parser.braced = parser.statement_closed;
                parser.statement_closed = false;

                if (parser.braced) return .returned;
                if (state.mode == .expression) return .returned;

                const kind = parser.current() orelse return .returned;
                const node = expression.assignment_of(kind) orelse return .returned;

                parser.bump();
                state.node = node;
                state.stage = .right;

                return parser.call(expression_of(context_expression));
            },
            .right => {
                parser.enclose(state.checkpoint.?, state.node);
                parser.braced = false;

                return .returned;
            },
            .closed => {
                parser.braced = true;

                return .returned;
            },
            .destructured => {
                parser.braced = false;

                return .returned;
            },
        }
    }

    fn branch_body_open(parser: *Parser, state: *BranchBody) Resumed {
        assert(state.stage == .start);
        assert(state.base < parser.frame_count);

        const held = parser.anchor();
        const inherited = parser.context(state.base);
        const plain = if (inherited == context_statement) context_expression else inherited;
        const chosen: u8 = if (state.mode == .statement) context_statement else plain;

        if (state.mode != .expression) {
            if (parser.labels_a_block()) {
                parser.bump();
                parser.bump();
            }
        }

        if (parser.at(.brace_open)) {
            state.stage = .closed;

            return parser.call(.{ .block = .{ .checkpoint = held } });
        }

        if (state.mode != .expression) {
            if (parser.body_destructures()) |checkpoint| {
                state.stage = .destructured;

                return parser.call(.{
                    .destructure = .{ .checkpoint = checkpoint, .terminated = false },
                });
            }
        }

        state.checkpoint = held;
        state.stage = .left;

        return parser.call(expression_of(chosen));
    }

    fn switch_resume(parser: *Parser, state: *Switch) Resumed {
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .start => {
                parser.bump();
                _ = parser.eat(.paren_open);
                state.stage = .subject;

                return parser.call(expression_of(context_expression));
            },
            .subject => {
                _ = parser.eat(.paren_close);

                parser.expect(.brace_open, .unexpected_token);

                continue :stage .cases;
            },
            .cases => {
                if (parser.list_closed(&state.iteration, .brace_close)) continue :stage .closed;

                state.before = parser.position;
                state.stage = .case;

                return parser.call(.{ .switch_case = .{} });
            },
            .case => {
                assert(parser.position >= state.before);

                if (!parser.eat(.comma)) continue :stage .closed;

                if (parser.position == state.before) parser.emit();

                continue :stage .cases;
            },
            .closed => {
                _ = parser.eat(.brace_close);

                parser.enclose(state.checkpoint, .@"switch");

                if (state.leading) parser.statement_closed = true;

                return parser.operand_returned(parser.settle(state.checkpoint, false));
            },
        }
    }

    fn switch_case_resume(parser: *Parser, state: *SwitchCase) Resumed {
        assert(state.iteration <= parser.steps());
        if (state.stage != .start) assert(state.checkpoint != null);

        stage: switch (state.stage) {
            .start => {
                if (!parser.descend()) {
                    parser.emit();

                    return .returned;
                }

                state.checkpoint = parser.anchor();
                _ = parser.eat(.inline_keyword);

                if (parser.eat(.else_keyword)) continue :stage .arrow;

                continue :stage .items;
            },
            .items => {
                if (state.iteration == parser.steps()) continue :stage .arrow;

                state.iteration += 1;
                state.held = parser.anchor();
                state.stage = .item;

                return parser.call(expression_of(context_expression));
            },
            .item => {
                if (parser.eat(.dot_dot_dot)) {
                    state.stage = .range;

                    return parser.call(expression_of(context_expression));
                }

                continue :stage .listed;
            },
            .range => {
                assert(state.held != null);

                parser.enclose(state.held.?, .switch_range);

                continue :stage .listed;
            },
            .listed => {
                if (!parser.eat(.comma)) continue :stage .arrow;
                if (parser.at(.arrow)) continue :stage .arrow;

                continue :stage .items;
            },
            .arrow => return parser.switch_case_body(state),
            .body => {
                parser.enclose(state.checkpoint.?, .switch_case);
                parser.ascend();

                return .returned;
            },
        }
    }

    fn switch_case_body(parser: *Parser, state: *SwitchCase) Resumed {
        assert(parser.nesting > 0);
        assert(state.checkpoint != null);

        _ = parser.eat(.arrow);

        parser.payload();

        const braced = parser.at(.brace_open);
        const held = parser.anchor();

        state.stage = .body;

        if (braced) return parser.call(.{ .block = .{ .checkpoint = held } });

        return parser.call(.{
            .expression_statement = .{ .checkpoint = held, .context = context_expression },
        });
    }

    fn loop_resume(parser: *Parser, state: *Loop) Resumed {
        assert(state.base < parser.frame_count);

        stage: switch (state.stage) {
            .start => {
                state.is_for = parser.at(.for_keyword);
                state.leading = parser.leads_a_statement(state.base);

                parser.bump();
                state.stage = .header;

                if (state.is_for) return parser.call(.{ .for_inputs = .{} });

                _ = parser.eat(.paren_open);
                state.stage = .condition;

                return parser.call(expression_of(context_expression));
            },
            .condition => {
                _ = parser.eat(.paren_close);

                continue :stage .header;
            },
            .header => {
                parser.payload();

                if (parser.eat(.colon)) return parser.loop_continued(state);

                continue :stage .body;
            },
            .continued => {
                _ = parser.eat(.paren_close);

                continue :stage .body;
            },
            .body => {
                state.stage = .otherwise;

                const mode: BodyMode = if (state.leading) .assign else .expression;
                return parser.call(.{ .branch_body = .{ .base = state.base, .mode = mode } });
            },
            .otherwise => {
                if (!parser.eat(.else_keyword)) continue :stage .closed;

                parser.payload();
                state.stage = .closed;

                const mode: BodyMode = if (state.leading) .statement else .expression;
                return parser.call(.{ .branch_body = .{ .base = state.base, .mode = mode } });
            },
            .closed => {
                const kind: Kind = if (state.is_for) .@"for" else .@"while";

                parser.enclose(state.checkpoint, kind);

                if (state.leading) parser.statement_closed = parser.braced;

                return parser.operand_returned(parser.settle(state.checkpoint, false));
            },
        }
    }

    fn loop_continued(parser: *Parser, state: *Loop) Resumed {
        assert(state.base < parser.frame_count);
        assert(parser.nesting > 0);

        _ = parser.eat(.paren_open);
        state.stage = .continued;

        const held = parser.anchor();
        const destructuring = parser.current() != null and parser.destructures();

        if (destructuring) {
            return parser.call(.{ .destructure = .{ .checkpoint = held, .terminated = false } });
        }

        return parser.call(.{
            .expression_statement = .{ .checkpoint = held, .context = context_expression },
        });
    }

    fn for_inputs_resume(parser: *Parser, state: *ForInputs) Resumed {
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .start => {
                if (!parser.eat(.paren_open)) return .returned;

                continue :stage .inputs;
            },
            .inputs => {
                if (parser.list_closed(&state.iteration, .paren_close)) continue :stage .closed;

                state.before = parser.position;
                state.checkpoint = parser.anchor();
                state.stage = .input;

                return parser.call(expression_of(context_expression));
            },
            .input => {
                if (!parser.eat(.dot_dot)) continue :stage .listed;

                const open_ended = parser.at(.paren_close) or parser.at(.comma);
                if (open_ended) continue :stage .range;

                state.stage = .range;

                return parser.call(expression_of(context_expression));
            },
            .range => {
                assert(state.checkpoint != null);

                parser.enclose(state.checkpoint.?, .for_range);

                continue :stage .listed;
            },
            .listed => {
                if (!parser.eat(.comma)) continue :stage .closed;

                if (parser.position == state.before) parser.emit();

                continue :stage .inputs;
            },
            .closed => {
                _ = parser.eat(.paren_close);

                return .returned;
            },
        }
    }

    fn assembly_resume(parser: *Parser, state: *Assembly) Resumed {
        assert(state.section <= assembly_section_count);

        stage: switch (state.stage) {
            .start => {
                assert(parser.at(.asm_keyword));

                state.checkpoint = parser.anchor();

                parser.bump();
                _ = parser.eat(.volatile_keyword);
                _ = parser.eat(.paren_open);
                state.stage = .sections;

                return parser.call(expression_of(context_expression));
            },
            .sections => {
                if (state.section == assembly_section_count) continue :stage .closed;
                if (!parser.eat(.colon)) continue :stage .closed;

                if (state.section + 1 == assembly_section_count) {
                    if (parser.at(.paren_close)) continue :stage .closed;

                    state.stage = .closed;

                    return parser.call(expression_of(context_expression));
                }

                state.stage = .operands;

                return parser.call(.{ .assembly_operands = .{ .output = state.section == 0 } });
            },
            .operands => {
                state.section += 1;

                continue :stage .sections;
            },
            .closed => {
                assert(state.checkpoint != null);

                _ = parser.eat(.paren_close);

                parser.enclose(state.checkpoint.?, .@"asm");

                return parser.operand_returned(parser.settle(state.checkpoint.?, false));
            },
        }
    }

    fn assembly_operands_resume(parser: *Parser, state: *AssemblyOperands) Resumed {
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .start => {
                if (state.iteration == parser.steps()) return .returned;

                state.iteration += 1;

                parser.skip_trivia();

                const operand_open = parser.at(.bracket_open) or parser.at(.text);
                if (!operand_open) return .returned;

                parser.assembly_operand_open(state);

                if (!parser.eat(.paren_open)) continue :stage .closed;

                state.stage = .operand;

                if (!state.output) return parser.call(expression_of(context_expression));
                if (parser.eat(.identifier)) continue :stage .operand;

                _ = parser.eat(.minus);
                _ = parser.eat(.greater);

                return parser.call(expression_of(context_type));
            },
            .operand => {
                _ = parser.eat(.paren_close);

                continue :stage .closed;
            },
            .closed => {
                assert(state.checkpoint != null);
                assert(state.before <= parser.position);

                if (state.named) {
                    const kind: Kind = if (state.output) .asm_output else .asm_input;

                    parser.enclose(state.checkpoint.?, kind);
                }

                if (!parser.eat(.comma)) return .returned;
                if (parser.position == state.before) return .returned;

                continue :stage .start;
            },
        }
    }

    fn assembly_operand_open(parser: *Parser, state: *AssemblyOperands) void {
        assert(state.iteration > 0);
        assert(state.iteration <= parser.steps());

        state.before = parser.position;
        state.checkpoint = parser.anchor();
        state.named = false;

        if (parser.eat(.bracket_open)) {
            state.named = true;
            _ = parser.eat(.identifier);
            _ = parser.eat(.bracket_close);
        }

        _ = parser.eat(.text);

        if (state.named) assert(parser.position > state.before);
    }

    fn container_type_resume(parser: *Parser, state: *ContainerType) Resumed {
        assert(state.kind.is_node());

        stage: switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();
                _ = parser.eat(.extern_keyword);
                _ = parser.eat(.packed_keyword);

                const tagged = parser.at(.union_keyword) and parser.ahead(1) == .paren_open;

                parser.bump();

                if (!parser.eat(.paren_open)) continue :stage .body;

                if (tagged) {
                    if (parser.eat(.enum_keyword)) {
                        state.kind = .tagged_union;

                        if (!parser.eat(.paren_open)) continue :stage .argument;

                        state.stage = .tag;

                        return parser.call(expression_of(context_expression));
                    }
                }

                state.stage = .argument;

                return parser.call(expression_of(context_expression));
            },
            .tag => {
                _ = parser.eat(.paren_close);

                continue :stage .argument;
            },
            .argument => {
                _ = parser.eat(.paren_close);

                continue :stage .body;
            },
            .body => {
                state.stage = .closed;

                return parser.call(.{ .container_body = .{} });
            },
            .closed => {
                assert(state.checkpoint != null);

                parser.enclose(state.checkpoint.?, state.kind);

                return parser.operand_returned(parser.settle(state.checkpoint.?, true));
            },
        }
    }

    fn container_body_resume(parser: *Parser, state: *ContainerBody) Resumed {
        assert(state.iteration <= parser.steps());
        if (state.stage == .member) assert(parser.nesting > 0);

        stage: switch (state.stage) {
            .start => {
                if (!parser.descend()) {
                    parser.emit();

                    return .returned;
                }

                if (!parser.eat(.brace_open)) {
                    parser.ascend();

                    return .returned;
                }

                continue :stage .members;
            },
            .members => {
                if (parser.list_closed(&state.iteration, .brace_close)) {
                    _ = parser.eat(.brace_close);

                    parser.ascend();

                    return .returned;
                }

                state.before = parser.position;
                state.stage = .member;

                return parser.call(.{ .member = .{} });
            },
            .member => {
                parser.progress_force(state.before);

                continue :stage .members;
            },
        }
    }

    fn operator_step(parser: *Parser, base: u32) Step {
        assert(base < parser.frame_count);

        if (parser.statement_closed) return .done;

        parser.skip_trivia();

        const group = parser.innermost_group(base);
        const kind = parser.current() orelse return .done;
        const frame = parser.frames[group];

        assert(frame.is_group());

        if (frame.is_bracketed()) {
            if (kind == frame.closer) {
                parser.close_group(group);

                return .operator;
            }
        }

        if (kind == .comma) return parser.comma(group);

        if (frame.variant == .index) {
            const sliced = kind == .colon or kind == .dot_dot;

            if (sliced) {
                parser.reduce_above(group + 1);
                parser.bump();
                parser.frames[group].stage = 1;

                return .operand;
            }
        }

        return switch (kind) {
            .dot => parser.field_access(),
            .dot_asterisk => parser.suffix(.deref),
            .dot_question => parser.suffix(.unwrap_optional),
            .paren_open => parser.trailer(.call, .call),
            .bracket_open => parser.trailer(.index, .array_access),
            .brace_open => parser.initializer(base),
            else => parser.binary_of(base, kind),
        };
    }

    fn initializer(parser: *Parser, base: u32) Step {
        assert(parser.at(.brace_open));
        assert(base < parser.frame_count);

        const curly = parser.suffixable and parser.context(base) != context_type;
        if (!curly) return .done;

        parser.drain_types();

        return parser.trailer(.init, .struct_init);
    }

    fn binary_of(parser: *Parser, base: u32, kind: Kind) Step {
        assert(base < parser.frame_count);
        assert(kind.is_token());

        const infix = expression.infix_of(kind) orelse return .done;

        assert(infix.node.is_node());

        const admitted = infix.node == .error_union or parser.context(base) != context_type;
        if (!admitted) return .done;

        parser.branch_closed();
        parser.reduce_for(infix.left);

        if (parser.value_count == 0) {
            parser.record(.expected_expression);
            parser.bump();

            return .operand;
        }

        const values = parser.value_count - 1;
        var frame: Frame = .empty;

        frame.checkpoint = parser.values[values];
        frame.kind = infix.node;
        frame.power = infix.right;
        frame.values = values;
        frame.variant = .binary;

        if (!parser.push_frame(frame)) return .done;

        parser.bump();

        if (infix.node == .@"catch") parser.payload();

        return .operand;
    }

    fn open_group(
        parser: *Parser,
        variant: expression.Variant,
        checkpoint: Checkpoint,
        kind: Kind,
    ) Step {
        assert(kind.is_node());

        const opener = parser.current() orelse .paren_open;

        _ = parser.anchor();

        parser.bump();
        _ = parser.anchor();

        var frame: Frame = .empty;

        frame.checkpoint = checkpoint;

        frame.closer = switch (opener) {
            .bracket_open => .bracket_close,
            .brace_open => .brace_close,
            else => .paren_close,
        };

        frame.kind = kind;
        frame.values = parser.value_count;
        frame.variant = variant;

        if (!parser.push_frame(frame)) return .done;

        assert(parser.frames[parser.frame_count - 1].is_bracketed());

        return .operand;
    }

    fn close_group(parser: *Parser, group: u32) void {
        assert(group < parser.frame_count);

        parser.reduce_above(group + 1);

        const frame = parser.frames[group];

        assert(frame.is_bracketed());

        parser.frame_count = group;

        const kind: Kind = switch (frame.variant) {
            .index => if (frame.stage == 0) .array_access else .slice,
            .init => init_kind(&frame),
            else => frame.kind,
        };

        parser.events.start_at(frame.checkpoint.?, kind);
        parser.bump();
        parser.events.finish();
        parser.value_count = frame.values;

        parser.push_value(frame.checkpoint.?);
        parser.suffixable = true;

        assert(parser.value_count > 0);
    }

    fn drain_types(parser: *Parser) void {
        assert(parser.at(.brace_open));
        assert(parser.suffixable);

        for (0..expression.depth_max) |_| {
            if (parser.frame_count == 0) return;

            const top = parser.frames[parser.frame_count - 1];
            if (top.variant != .unary) return;
            if (top.stage != stage_type) return;

            parser.reduce_top();
        }
    }

    fn field_access(parser: *Parser) Step {
        assert(parser.at(.dot));

        if (parser.value_count == 0) return .done;

        const checkpoint = parser.values[parser.value_count - 1];

        parser.events.start_at(checkpoint, .field_access);
        parser.bump();

        if (parser.at(.identifier)) parser.bump();

        parser.events.finish();
        parser.suffixable = true;

        return .operator;
    }

    fn suffix(parser: *Parser, kind: Kind) Step {
        assert(kind.is_node());

        if (parser.value_count == 0) return .done;

        const checkpoint = parser.values[parser.value_count - 1];

        parser.events.start_at(checkpoint, kind);
        parser.bump();
        parser.events.finish();
        parser.suffixable = true;

        return .operator;
    }

    fn trailer(parser: *Parser, variant: expression.Variant, kind: Kind) Step {
        assert(kind.is_node());
        assert(is_opener(parser.current() orelse .error_token));
        assert(variant == .call or variant == .index or variant == .init);
        if (variant == .call) assert(kind == .call);
        if (variant == .index) assert(kind == .array_access);
        if (variant == .init) assert(kind == .struct_init);

        if (parser.value_count == 0) return .done;

        const checkpoint = parser.values[parser.value_count - 1];

        parser.value_count -= 1;

        return parser.open_group(variant, checkpoint, kind);
    }

    fn comma(parser: *Parser, group: u32) Step {
        assert(group < parser.frame_count);
        assert(parser.at(.comma));

        const frame = parser.frames[group];

        switch (frame.variant) {
            .top, .paren => return .done,
            else => {},
        }

        parser.reduce_above(group + 1);
        parser.bump();
        parser.value_count = frame.values;

        return .operand;
    }

    fn context(parser: *Parser, base: u32) u8 {
        assert(base < parser.frame_count);

        const group = parser.innermost_group(base);

        assert(group < parser.frame_count);

        if (parser.frames[group].variant != .top) return context_expression;

        assert(parser.frames[group].stage <= context_statement);

        return parser.frames[group].stage;
    }

    fn innermost_group(parser: *Parser, base: u32) u32 {
        assert(base <= parser.frame_count);

        var index = parser.frame_count;

        while (index > base) {
            index -= 1;

            if (parser.frames[index].is_group()) return index;
        }

        assert(base == parser.frame_count);

        return base;
    }

    fn reduce_top(parser: *Parser) void {
        assert(parser.frame_count > 0);

        parser.frame_count -= 1;

        const frame = parser.frames[parser.frame_count];

        assert(frame.variant != .top);

        parser.enclose(frame.checkpoint.?, frame.kind);
        parser.value_count = frame.values;

        parser.push_value(frame.checkpoint.?);

        assert(parser.value_count > 0);
    }

    fn reduce_above(parser: *Parser, base: u32) void {
        assert(base > 0);

        while (parser.frame_count > base) {
            parser.reduce_top();
        }

        assert(parser.frame_count <= base);
    }

    fn reduce_for(parser: *Parser, power_left: u8) void {
        assert(power_left > expression.power_barrier);

        while (parser.frame_count > 0) {
            const top = parser.frames[parser.frame_count - 1];
            if (top.power == expression.power_barrier) break;
            if (top.power < power_left) break;

            parser.reduce_top();
        }

        if (parser.frame_count > 0) {
            assert(parser.frames[parser.frame_count - 1].power < power_left);
        }
    }

    fn push_frame(parser: *Parser, frame: Frame) bool {
        assert(parser.frame_count <= expression.depth_max);
        assert(frame.kind.is_node());
        if (frame.is_bracketed()) assert(is_closer(frame.closer));

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
        assert(checkpoint.index <= parser.events.count());

        if (parser.value_count >= expression.value_count_max) {
            parser.outcome = .too_deep;

            return;
        }

        parser.values[parser.value_count] = checkpoint;
        parser.value_count += 1;
    }

    fn descend(parser: *Parser) bool {
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

    fn progress(parser: *const Parser) Progress {
        assert(parser.position <= parser.count());
        assert(parser.frame_count <= expression.depth_max);

        return .{
            .frame_count = parser.frame_count,
            .position = parser.position,
            .value_count = parser.value_count,
        };
    }

    fn progress_force(parser: *Parser, before: u32) void {
        assert(parser.position >= before);

        if (parser.position != before) return;

        parser.record(.unexpected_token);
        parser.emit();

        assert(parser.position > before);
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

    fn enclose(parser: *Parser, checkpoint: Checkpoint, kind: Kind) void {
        assert(kind.is_node());
        assert(checkpoint.index <= parser.events.count());

        parser.events.start_at(checkpoint, kind);
        parser.events.finish();
    }

    fn payload(parser: *Parser) void {
        assert(parser.nesting > 0);

        if (!parser.eat(.pipe)) return;

        for (0..parser.steps()) |_| {
            _ = parser.eat(.star);

            if (!parser.eat(.identifier)) break;
            if (!parser.eat(.comma)) break;
        }

        _ = parser.eat(.pipe);
    }

    fn body_destructures(parser: *Parser) ?Checkpoint {
        assert(parser.nesting > 0);
        assert(parser.position <= parser.count());

        const kind = parser.current() orelse return null;
        if (is_declaration(kind)) return null;

        if (parser.at(.comptime_keyword)) {
            if (parser.ahead(1) == .brace_open) return null;
            if (!parser.destructures()) return null;

            parser.bump();

            return parser.anchor();
        }

        if (!parser.targets_a_destructure()) return null;
        if (!parser.destructures()) return null;
        return parser.anchor();
    }

    fn branch_closed(parser: *Parser) void {
        assert(parser.frame_count <= expression.depth_max);
        assert(parser.value_count <= expression.value_count_max);

        if (parser.frame_count == 0) return;

        const top = parser.frames[parser.frame_count - 1];
        if (top.variant != .unary) return;
        if (parser.value_count != top.values) return;

        switch (top.kind) {
            .@"break", .@"continue", .@"return" => parser.reduce_top(),
            else => {},
        }
    }

    fn leads_a_statement(parser: *const Parser, base: u32) bool {
        assert(base < parser.frame_count);
        assert(parser.frame_count <= expression.depth_max);

        const top = parser.frames[base];
        if (top.variant != .top) return false;
        if (top.stage != context_statement) return false;
        if (parser.frame_count != base + 1) return false;
        return parser.value_count == top.values;
    }

    fn labels_a_block(parser: *Parser) bool {
        assert(parser.position <= parser.count());

        if (!parser.at(.identifier)) return false;
        if (parser.ahead(1) != .colon) return false;
        return parser.ahead(2) == .brace_open;
    }

    fn labels_a_loop(parser: *Parser) bool {
        assert(parser.current() != null);

        if (parser.at(.inline_keyword)) {
            const next = parser.ahead(1) orelse return false;
            return next == .for_keyword or next == .while_keyword;
        }

        if (parser.ahead(1) != .colon) return false;

        const target = parser.ahead(2) orelse return false;

        return switch (target) {
            .brace_open, .for_keyword, .inline_keyword, .switch_keyword, .while_keyword => true,
            else => false,
        };
    }

    fn targets_a_destructure(parser: *Parser) bool {
        assert(parser.current() != null);
        assert(!is_declaration(parser.current()));

        if (!parser.at(.identifier)) return false;
        return !parser.labels_a_loop();
    }

    fn destructures(parser: *Parser) bool {
        assert(parser.current() != null);

        var position = parser.significant(parser.position);
        var previous: Kind = .error_token;
        var depth: u32 = 0;

        for (0..scan_step_max) |_| {
            const kind = parser.kind_at(position) orelse return false;

            if (depth == 0) {
                if (parser.payload_skipped(position, previous)) |end| {
                    assert(end > position);

                    position = end;
                    previous = .pipe;

                    continue;
                }

                if (kind == .brace_open) {
                    if (!opens_a_body(previous)) return false;

                    const opened = position;
                    position = parser.balanced_end(position);
                    previous = .brace_close;

                    assert(position > opened);

                    continue;
                }

                switch (kind) {
                    .arrow, .equal, .semicolon => return false,
                    .comma => return true,
                    else => {},
                }
            }

            if (is_opener(kind)) depth += 1;

            if (is_closer(kind)) {
                if (depth == 0) return false;

                depth -= 1;
            }

            previous = kind;
            position += 1;
        }

        return false;
    }

    fn payload_skipped(parser: *Parser, position: u32, previous: Kind) ?u32 {
        assert(position < parser.count());
        assert(previous.is_token());

        if (parser.raw[position] != .pipe) return null;
        if (previous != .paren_close) return null;
        return parser.payload_end(position);
    }

    fn payload_end(parser: *Parser, bar: u32) ?u32 {
        assert(bar < parser.count());
        assert(parser.raw[bar] == .pipe);

        var position = bar + 1;

        for (0..payload_name_count_max) |_| {
            position = parser.significant_scan(position);

            if (parser.kind_at(position) == .star) position = parser.significant_scan(position + 1);
            if (parser.kind_at(position) != .identifier) return null;

            position = parser.significant_scan(position + 1);

            const kind = parser.kind_at(position) orelse return null;

            if (kind == .pipe) {
                assert(position + 1 <= parser.tokens.len);

                return position + 1;
            }

            if (kind != .comma) return null;

            position += 1;
        }

        return null;
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

        if (parser.tree.diagnostic_slice().len > 0) {
            if (parser.tree.diagnostic_slice()[0].span.offset == span.offset) return;
        }

        parser.tree.push_diagnostic(pushed) catch |err| switch (err) {
            error.Truncated => {
                if (parser.outcome == .complete) parser.outcome = .{ .truncated = .diagnostics };
            },
        };
    }

    fn expect(parser: *Parser, kind: Kind, failure: Diagnostic.Kind) void {
        assert(!failure.is_indentation());
        assert(kind.is_token());

        if (parser.eat(kind)) return;

        parser.record_expected(failure, kind);
    }

    fn eat(parser: *Parser, kind: Kind) bool {
        assert(kind.is_token());

        if (!parser.at(kind)) return false;

        parser.bump();

        return true;
    }

    fn bump(parser: *Parser) void {
        parser.skip_trivia();

        const before = parser.position;

        parser.emit();

        if (before < parser.count()) assert(parser.position == before + 1);
    }

    fn open(parser: *Parser, kind: Kind) void {
        assert(kind.is_node());

        parser.skip_trivia();
        parser.events.start(kind);
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
        assert(parser.significant_next <= parser.count());
    }

    fn at(parser: *Parser, kind: Kind) bool {
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

        return parser.kind_at(parser.significant(parser.position));
    }

    fn significant(parser: *Parser, from: u32) u32 {
        assert(from >= parser.position);

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
        if (position < parser.raw.len) assert(!is_layout(parser.raw[position]));

        return position;
    }

    fn kind_at(parser: *Parser, position: u32) ?Kind {
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
    assembly: Assembly,
    assembly_operands: AssemblyOperands,
    block: Block,
    block_value: BlockValue,
    bracket_type: BracketType,
    branch_body: BranchBody,
    callable_attributes: Attributes,
    container_body: ContainerBody,
    container_field: ContainerField,
    container_type: ContainerType,
    deferred: Deferred,
    destructure: Destructure,
    expression: Expression,
    expression_statement: ExpressionStatement,
    for_inputs: ForInputs,
    function: Function,
    function_type: FunctionType,
    if_expression: If,
    loop: Loop,
    member: Member,
    parameter_list: ParameterList,
    parenthesized: Parenthesized,
    pointer_attributes: Attributes,
    pointer_type: PointerType,
    statement: Statement,
    switch_case: SwitchCase,
    switch_expression: Switch,
    variable_declaration: VariableDeclaration,
};

const Assembly = struct {
    stage: enum { start, sections, operands, closed } = .start,
    checkpoint: ?Checkpoint = null,
    section: u32 = 0,
};

const AssemblyOperands = struct {
    stage: enum { start, operand, closed } = .start,
    checkpoint: ?Checkpoint = null,
    iteration: u32 = 0,
    before: u32 = 0,
    named: bool = false,
    output: bool = false,
};

const Attributes = struct {
    iteration: u32 = 0,
};

const Block = struct {
    stage: enum { start, statements, statement } = .start,
    checkpoint: Checkpoint,
    iteration: u32 = 0,
    before: u32 = 0,
};

const BlockValue = struct {
    stage: enum { start, body } = .start,
    checkpoint: Checkpoint,
    labelled: bool = false,
};

const BodyMode = enum {
    assign,
    expression,
    statement,
};

const BracketType = struct {
    stage: enum { start, length, sentinel, attributes } = .start,
    checkpoint: ?Checkpoint = null,
    kind: Kind = .ptr_type,
};

const BranchBody = struct {
    stage: enum { start, left, right, closed, destructured } = .start,
    base: u32,
    checkpoint: ?Checkpoint = null,
    mode: BodyMode = .expression,
    node: Kind = .assign,
};

const ContainerBody = struct {
    stage: enum { start, members, member } = .start,
    iteration: u32 = 0,
    before: u32 = 0,
};

const ContainerField = struct {
    stage: enum { start, typed, aligned, valued } = .start,
    checkpoint: Checkpoint,
};

const ContainerType = struct {
    stage: enum { start, tag, argument, body, closed } = .start,
    checkpoint: ?Checkpoint = null,
    kind: Kind = .container_decl,
};

const Deferred = struct {
    stage: enum { start, body } = .start,
    checkpoint: Checkpoint,
    kind: Kind,
};

const Destructure = struct {
    stage: enum { elements, typed, element, assigned, valued } = .elements,
    checkpoint: Checkpoint,
    held: ?Checkpoint = null,
    iteration: u32 = 0,
    terminated: bool = true,
};

const Expression = struct {
    stage: enum { start, machine, resumed, finished } = .start,
    context: u8,
    frames_base: u32 = 0,
    values_base: u32 = 0,
    operand: bool = true,
    before: Progress = .{ .frame_count = 0, .position = 0, .value_count = 0 },
    iteration: u32 = 0,
};

const ExpressionStatement = struct {
    stage: enum { start, left, right } = .start,
    checkpoint: Checkpoint,
    context: u8 = context_statement,
    node: Kind = .assign,
};

const ForInputs = struct {
    stage: enum { start, inputs, input, range, listed, closed } = .start,
    checkpoint: ?Checkpoint = null,
    iteration: u32 = 0,
    before: u32 = 0,
};

const Function = struct {
    stage: enum { start, parameters, attributes, result, body } = .start,
    checkpoint: Checkpoint,
};

const FunctionType = struct {
    stage: enum { start, parameters, attributes, result } = .start,
    checkpoint: ?Checkpoint = null,
};

const If = struct {
    stage: enum { start, arm, condition, body, closed } = .start,
    base: u32,
    checkpoint: ?Checkpoint = null,
    iteration: u32 = 0,
    leading: bool = false,
    links: u32 = 0,
};

const Loop = struct {
    stage: enum { start, condition, header, continued, body, otherwise, closed } = .start,
    base: u32,
    checkpoint: Checkpoint,
    is_for: bool = false,
    leading: bool = false,
};

const Member = struct {
    stage: enum { start, test_body, comptime_body, function, variable, field } = .start,
    checkpoint: ?Checkpoint = null,
};

const ParameterList = struct {
    stage: enum { start, parameters, parameter } = .start,
    iteration: u32 = 0,
    before: u32 = 0,
};

const Parenthesized = struct {
    stage: enum { start, inner, ranged, closed } = .start,
    ranged: bool = false,
};

const PointerType = struct {
    stage: enum { start, attributes } = .start,
};

const Statement = struct {
    stage: enum { start, declared, finished } = .start,
};

const Switch = struct {
    stage: enum { start, subject, cases, case, closed } = .start,
    checkpoint: Checkpoint,
    iteration: u32 = 0,
    before: u32 = 0,
    leading: bool = false,
};

const SwitchCase = struct {
    stage: enum { start, items, item, range, listed, arrow, body } = .start,
    checkpoint: ?Checkpoint = null,
    held: ?Checkpoint = null,
    iteration: u32 = 0,
};

const VariableDeclaration = struct {
    stage: enum { start, typed, attributed, valued } = .start,
    checkpoint: Checkpoint,
};

const nest_depth_max: u32 = 96;
const payload_name_count_max: u32 = 64;
const task_chain_max: u32 = 4;
const task_count_max: u32 = (nest_depth_max + 1) * task_chain_max;
const scan_step_max: u32 = 1 << 16;
const member_iteration_max: u32 = std.math.maxInt(u32);
const machine_step_max: u32 = std.math.maxInt(u32);
const resume_count_max: u64 = std.math.maxInt(u32);
const assembly_section_count: u32 = 3;
const context_type: u8 = 0;
const context_expression: u8 = 1;
const context_statement: u8 = 2;
const stage_value: u8 = 0;
const stage_type: u8 = 1;
const stage_keep: u8 = 2;

comptime {
    assert(context_type == stage_value);
    assert(context_expression == stage_type);
    assert(context_statement == stage_keep);
    assert(task_count_max > nest_depth_max);
}

fn expression_of(context: u8) Task {
    assert(context <= context_statement);

    return .{ .expression = .{ .context = context } };
}

fn init_kind(frame: *const Frame) Kind {
    assert(frame.variant == .init);
    assert(frame.stage <= 2);

    const dotted = frame.kind == .struct_init_dot;

    if (frame.stage == 1) {
        if (dotted) return .array_init_dot;
        return .array_init;
    }

    if (dotted) return .struct_init_dot;
    return .struct_init;
}

fn is_declaration(kind: ?Kind) bool {
    if (kind) |held| assert(held.is_token());

    const held = kind orelse return false;

    assert(held.is_token());

    return held == .const_keyword or held == .var_keyword;
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

fn opens_a_container(kind: ?Kind) bool {
    if (kind) |held| assert(held.is_token());

    const held = kind orelse return false;

    assert(held.is_token());

    return switch (held) {
        .brace_open, .enum_keyword, .opaque_keyword, .struct_keyword, .union_keyword => true,
        else => false,
    };
}

fn opens_a_loop(kind: ?Kind) bool {
    if (kind) |held| assert(held.is_token());

    const held = kind orelse return false;

    assert(held.is_token());

    return held == .for_keyword or held == .while_keyword;
}

fn opens_a_body(kind: Kind) bool {
    assert(kind.is_token());

    return switch (kind) {
        .enum_keyword, .opaque_keyword, .paren_close, .struct_keyword, .union_keyword => true,
        else => false,
    };
}
