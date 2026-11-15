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
const Events = EventsType(Kind);
const Frame = expression.Frame;
const Tree = TreeType(Kind);

pub const Parser = struct {
    chain_count: u32,
    events: *Events,
    file_scope: bool,
    frame_count: u32,
    frames: [expression.depth_max]Frame,
    nesting: u32,
    outcome: Structure,
    position: u32,
    raw: []const Kind,
    returned: Step,
    significant_next: u32,
    source: []const u8,
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
            .chain_count = 0,
            .events = events,
            .file_scope = true,
            .frame_count = 0,
            .frames = undefined,
            .nesting = 0,
            .outcome = .complete,
            .position = 0,
            .raw = raw,
            .returned = .done,
            .significant_next = 0,
            .source = source,
            .suffixable = true,
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
        assert(parser.frame_count == 0);
        assert(parser.value_count == 0);
        assert(parser.chain_count == 0);

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

        parser.events.start(.source_file);
        parser.skip_breaks();

        if (parser.at(.package_keyword)) {
            const checkpoint = parser.anchor();

            parser.bump();
            parser.name();
            parser.enclose(checkpoint, .package_declaration);
            parser.terminator();
        }

        var iteration: u32 = 0;

        while (iteration < declaration_iteration_max) : (iteration += 1) {
            parser.skip_breaks();

            if (parser.current() == null) break;

            const before = parser.position;

            parser.drive(.{ .declaration = .{} });
            parser.progress_force(before);

            assert(parser.position > before);
            assert(parser.nesting == 0);
        }

        assert(parser.position == parser.count());

        parser.events.finish();
    }

    fn drive(parser: *Parser, task: Task) void {
        assert(parser.task_count == 0);
        assert(task == .declaration);

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
            .attributes => |*state| parser.attributes_resume(state),
            .bit_field_block => |*state| parser.bit_field_block_resume(state),
            .block => |*state| parser.block_resume(state),
            .bracketed => |*state| parser.bracketed_resume(state),
            .cast_operand => |*state| parser.cast_operand_resume(state),
            .conditional => |*state| parser.conditional_resume(state),
            .conditional_type => |*state| parser.conditional_type_resume(state),
            .constant => |*state| parser.constant_resume(state),
            .declaration => |*state| parser.entry_resume(state, false),
            .directive => |*state| parser.directive_resume(state),
            .element => |*state| parser.element_resume(state),
            .else_tail => |*state| parser.else_tail_resume(state),
            .enclosed => |*state| parser.enclosed_resume(state),
            .enumeration_body => |*state| parser.enumeration_body_resume(state),
            .expression => |*state| parser.expression_resume(state),
            .expression_list => |*state| parser.expression_list_resume(state),
            .expression_statement => |*state| parser.expression_statement_resume(state),
            .field => |*state| parser.field_resume(state),
            .field_block => |*state| parser.field_block_resume(state),
            .for_clauses => |*state| parser.for_clauses_resume(state),
            .for_header => |*state| parser.for_header_resume(state),
            .for_statement => |*state| parser.for_statement_resume(state),
            .header => |*state| parser.header_resume(state),
            .listed => |*state| parser.listed_resume(state),
            .member => |*state| parser.member_resume(state),
            .overloaded => |*state| parser.overloaded_resume(state),
            .parameter => |*state| parser.parameter_resume(state),
            .procedure => |*state| parser.procedure_resume(state),
            .qualifiers => |*state| parser.qualifiers_resume(state),
            .record_body => |*state| parser.record_body_resume(state),
            .result => |*state| parser.result_resume(state),
            .statement => |*state| parser.entry_resume(state, true),
            .switch_case => |*state| parser.switch_case_resume(state),
            .switch_clause => |*state| parser.switch_clause_resume(state),
            .switch_header => |*state| parser.switch_header_resume(state),
            .switch_statement => |*state| parser.switch_statement_resume(state),
            .typed => |*state| parser.typed_resume(state),
            .union_body => |*state| parser.union_body_resume(state),
            .variable => |*state| parser.variable_resume(state),
            .variadic => |*state| parser.variadic_resume(state),
        };
    }

    fn entry_resume(parser: *Parser, state: *Entry, statement: bool) Resumed {
        if (!statement) assert(parser.task_count == 1);
        if (state.stage != .start) assert(state.checkpoint != null);

        stage: switch (state.stage) {
            .start => {
                if (!parser.descend()) {
                    parser.emit();

                    return .returned;
                }

                state.checkpoint = parser.anchor();

                if (parser.at(.at)) {
                    state.stage = .attributed;

                    return parser.call(.{ .attributes = .{} });
                }

                continue :stage .attributed;
            },
            .attributed => {
                state.stage = .finished;

                const task = if (statement)
                    parser.statement_task(state.checkpoint.?)
                else
                    parser.declaration_task(state.checkpoint.?);

                if (task) |held| return parser.call(held);

                continue :stage .finished;
            },
            .finished => {
                parser.ascend();

                return .returned;
            },
        }
    }

    fn declaration_task(parser: *Parser, checkpoint: Checkpoint) ?Task {
        assert(parser.nesting > 0);
        assert(checkpoint.index <= parser.events.count());

        const kind = parser.current() orelse return null;

        switch (kind) {
            .import_keyword => {
                parser.import_declaration(checkpoint);

                return null;
            },
            .foreign_keyword => return parser.foreign_task(checkpoint),
            .when_keyword => return conditional_of(checkpoint, true),
            .using_keyword => return enclosed_of(.using, checkpoint),
            else => return parser.bound_task(checkpoint),
        }
    }

    fn foreign_task(parser: *Parser, checkpoint: Checkpoint) ?Task {
        assert(parser.at(.foreign_keyword));
        assert(checkpoint.index <= parser.events.count());

        parser.bump();

        if (parser.at(.import_keyword)) {
            parser.import_declaration(checkpoint);

            return null;
        }

        return enclosed_of(.foreign, checkpoint);
    }

    fn bound_task(parser: *Parser, checkpoint: Checkpoint) ?Task {
        assert(parser.current() != null);
        assert(checkpoint.index <= parser.events.count());

        if (parser.binds_a_universal()) return .{ .constant = .{ .checkpoint = checkpoint } };
        if (!parser.at_name()) return parser.statement_task(checkpoint);
        return parser.binding_of(checkpoint) orelse parser.statement_task(checkpoint);
    }

    fn binding_of(parser: *Parser, checkpoint: Checkpoint) ?Task {
        assert(parser.at_name());
        assert(checkpoint.index <= parser.events.count());

        const bound = parser.binder() orelse return null;
        if (bound == .colon) return .{ .variable = .{ .checkpoint = checkpoint } };

        assert(bound == .colon_colon);

        return .{ .constant = .{ .checkpoint = checkpoint } };
    }

    fn statement_task(parser: *Parser, checkpoint: Checkpoint) ?Task {
        assert(parser.nesting > 0);

        var held = checkpoint;

        for (0..parser.steps()) |_| {
            if (!parser.tags_a_statement_here()) return parser.statement_open(held);

            parser.wrap(.tag);
            held = parser.anchor();
        }

        return null;
    }

    fn tags_a_statement_here(parser: *Parser) bool {
        assert(parser.position <= parser.count());
        assert(parser.nesting > 0);

        if (!parser.at(.directive)) return false;
        if (parser.tags_a_block()) return false;
        if (parser.tags_an_assignment()) return true;
        return parser.tags_a_statement();
    }

    fn statement_open(parser: *Parser, checkpoint: Checkpoint) ?Task {
        assert(parser.nesting > 0);
        assert(checkpoint.index <= parser.events.count());

        const kind = parser.current() orelse return null;

        switch (kind) {
            .semicolon, .newline => {
                parser.bump();

                return null;
            },
            .brace_open => return .{ .block = .{ .checkpoint = checkpoint, .terminated = true } },
            .import_keyword => {
                parser.import_declaration(checkpoint);

                return null;
            },
            .foreign_keyword => return parser.foreign_task(checkpoint),
            .using_keyword => return enclosed_of(.using, checkpoint),
            .when_keyword => return conditional_of(checkpoint, true),
            .if_keyword => return conditional_of(checkpoint, false),
            .for_keyword => return .{ .for_statement = .{ .checkpoint = checkpoint } },
            .switch_keyword => return .{ .switch_statement = .{ .checkpoint = checkpoint } },
            .return_keyword => return enclosed_of(.@"return", checkpoint),
            .defer_keyword => return enclosed_of(.deferred, checkpoint),
            .break_keyword => parser.branch(checkpoint, .break_statement),
            .continue_keyword => parser.branch(checkpoint, .continue_statement),
            .fallthrough_keyword => parser.branch(checkpoint, .fallthrough_statement),
            else => return parser.statement_other(checkpoint, kind),
        }

        return null;
    }

    fn statement_other(parser: *Parser, checkpoint: Checkpoint, kind: Kind) ?Task {
        assert(parser.current() == kind);
        assert(checkpoint.index <= parser.events.count());

        if (kind == .directive) {
            if (parser.tags_a_block()) return enclosed_of(.tagged_block, checkpoint);
        }

        if (expression.is_name(kind)) {
            if (parser.labels_a_block()) return enclosed_of(.label, checkpoint);
            if (parser.binder() != null) return parser.binding_of(checkpoint);
        }

        return .{ .expression_statement = .{
            .checkpoint = checkpoint,
            .context = context_value,
            .terminated = true,
        } };
    }

    fn import_declaration(parser: *Parser, checkpoint: Checkpoint) void {
        assert(parser.at(.import_keyword));
        assert(checkpoint.index <= parser.events.count());

        parser.bump();
        parser.name();

        const pathed = parser.at(.text) or parser.at(.brace_open);

        if (!pathed) parser.record_expected(.unexpected_token, .text);
        if (parser.at(.text)) parser.wrap(.string);

        if (parser.eat(.brace_open)) {
            for (0..parser.steps()) |_| {
                parser.skip_breaks();

                const kind = parser.current() orelse break;
                if (kind == .brace_close) break;
                if (parser.eat(.comma)) continue;

                if (kind == .text) {
                    parser.wrap(.string);

                    continue;
                }

                if (expression.is_name(kind)) {
                    parser.wrap(.identifier_node);

                    continue;
                }

                parser.emit();
            }

            _ = parser.eat(.brace_close);
        }

        parser.enclose(checkpoint, .import_declaration);
        parser.terminator();
    }

    fn branch(parser: *Parser, checkpoint: Checkpoint, kind: Kind) void {
        assert(kind.is_node());
        assert(checkpoint.index <= parser.events.count());

        parser.bump();

        if (kind != .fallthrough_statement) parser.name();

        parser.enclose(checkpoint, kind);
        parser.terminator();
    }

    fn attributes_resume(parser: *Parser, state: *Attributes) Resumed {
        assert(state.iteration <= parser.steps());
        assert(state.inner <= parser.steps());

        stage: switch (state.stage) {
            .start => {
                assert(parser.at(.at));

                state.checkpoint = parser.anchor();

                continue :stage .attributes;
            },
            .attributes => {
                if (!parser.attribute_open(state)) {
                    parser.enclose(state.checkpoint.?, .attributes);
                    parser.skip_breaks();

                    return .returned;
                }

                if (!parser.at(.paren_open)) {
                    parser.name();
                    parser.enclose(state.held.?, .attribute);

                    continue :stage .attributes;
                }

                _ = parser.eat(.paren_open);
                state.inner = 0;

                continue :stage .arguments;
            },
            .arguments => {
                if (parser.list_closed(&state.inner, .paren_close)) continue :stage .closed;

                state.before = parser.position;

                parser.name();

                if (parser.eat(.equal)) {
                    state.stage = .argument;

                    return parser.call(expression_of(context_value));
                }

                continue :stage .argument;
            },
            .argument => {
                if (parser.list_continues(state.before)) continue :stage .arguments;

                continue :stage .closed;
            },
            .closed => {
                parser.skip_breaks();
                _ = parser.eat(.paren_close);

                parser.enclose(state.held.?, .attribute);

                continue :stage .attributes;
            },
        }
    }

    fn attribute_open(parser: *Parser, state: *Attributes) bool {
        assert(state.checkpoint != null);
        assert(state.iteration <= parser.steps());

        if (state.iteration == parser.steps()) return false;

        state.iteration += 1;

        if (!parser.at(.at)) {
            if (!parser.marks_an_attribute()) return false;

            parser.skip_breaks();
        }

        state.held = parser.anchor();

        parser.bump();

        return true;
    }

    fn enclosed_resume(parser: *Parser, state: *Enclosed) Resumed {
        assert(state.kind.is_node());

        if (state.stage == .start) {
            state.stage = .inner;

            if (parser.enclosed_open(state)) |task| return parser.call(task);
        }

        if (state.form == .cast) _ = parser.eat(.paren_close);

        parser.enclose(state.checkpoint.?, state.kind);

        switch (state.form) {
            .using, .@"return", .tagged_block, .deferred, .foreign => parser.terminator(),
            .label, .where => {},
            .constant_type, .cast, .record, .enumeration, .@"union", .specialized => {
                parser.returned = parser.settle(state.checkpoint.?, true);
            },
        }

        return .returned;
    }

    fn enclosed_open(parser: *Parser, state: *Enclosed) ?Task {
        assert(state.stage == .inner);
        assert(state.kind.is_node());

        switch (state.form) {
            .using => parser.bump(),
            .@"return" => {
                parser.bump();

                if (parser.ends_here()) return null;
                return list_of(context_value);
            },
            .label => {
                parser.name();
                parser.bump();

                return .{ .statement = .{} };
            },
            .tagged_block => {
                parser.wrap(.tag);

                return .{ .block = .{ .checkpoint = parser.anchor() } };
            },
            .deferred => return parser.deferred_body(),
            .foreign => {
                parser.name();
                parser.reach_a_brace();

                return .{ .block = .{ .checkpoint = parser.anchor() } };
            },
            .record, .enumeration, .@"union" => state.checkpoint = parser.anchor(),
            .where, .constant_type, .cast => {
                state.checkpoint = parser.anchor();

                parser.bump();
            },
            .specialized => {
                assert(parser.value_count > 0);

                state.checkpoint = parser.values[parser.value_count - 1];
                parser.value_count -= 1;

                parser.enclose(state.checkpoint.?, .type);
                parser.bump();
            },
        }

        return enclosed_inner(state.form);
    }

    fn deferred_body(parser: *Parser) Task {
        assert(parser.at(.defer_keyword));
        assert(parser.nesting > 0);

        parser.bump();

        const held = parser.anchor();
        if (parser.at(.brace_open)) return .{ .block = .{ .checkpoint = held } };

        if (parser.opens_a_compound()) {
            const task = parser.statement_open(held);

            assert(task != null);

            return task.?;
        }

        return .{ .expression_statement = .{ .checkpoint = held, .context = context_value } };
    }

    fn constant_resume(parser: *Parser, state: *Constant) Resumed {
        assert(state.kind.is_node());

        stage: switch (state.stage) {
            .start => {
                if (parser.binds_a_universal()) parser.universal() else parser.name_list();

                parser.bump();

                if (parser.at(.at)) {
                    state.stage = .attributed;

                    return parser.call(.{ .attributes = .{} });
                }

                continue :stage .attributed;
            },
            .attributed => {
                state.kind = parser.constant_kind();

                const overload = state.kind == .procedure_declaration and
                    parser.opens_an_overload();

                if (overload) {
                    state.stage = .overloaded;

                    return parser.call(.{ .overloaded = .{ .checkpoint = state.checkpoint } });
                }

                state.stage = .valued;

                if (state.kind == .const_declaration) return parser.call(list_of(context_value));
                return parser.call(parser.container_value());
            },
            .overloaded => return .returned,
            .valued => {
                parser.enclose(state.checkpoint, state.kind);
                parser.terminator();

                return .returned;
            },
        }
    }

    fn container_value(parser: *Parser) Task {
        assert(parser.nesting > 0);
        assert(parser.task_count > 0);

        parser.directives();

        const kind = parser.current() orelse return expression_of(context_value);

        return switch (kind) {
            .proc_keyword => .{ .procedure = .{} },
            .struct_keyword, .bit_field_keyword => .{ .record_body = .{ .member = .field } },
            .enum_keyword => .{ .enumeration_body = .{} },
            .union_keyword => .{ .union_body = .{} },
            else => expression_of(context_value),
        };
    }

    fn overloaded_resume(parser: *Parser, state: *Overloaded) Resumed {
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .start => {
                for (0..parser.steps()) |_| {
                    if (!parser.at(.directive)) break;

                    parser.bump();
                }

                parser.bump();
                _ = parser.eat(.brace_open);

                continue :stage .items;
            },
            .items => {
                if (parser.list_closed(&state.iteration, .brace_close)) continue :stage .closed;

                state.before = parser.position;
                state.stage = .item;

                return parser.call(expression_of(context_value));
            },
            .item => {
                if (parser.list_continues(state.before)) continue :stage .items;

                continue :stage .closed;
            },
            .closed => {
                _ = parser.eat(.brace_close);

                parser.enclose(state.checkpoint, .overloaded_procedure_declaration);
                parser.terminator();

                return .returned;
            },
        }
    }

    fn variable_resume(parser: *Parser, state: *Variable) Resumed {
        assert(parser.nesting > 0);

        stage: switch (state.stage) {
            .start => {
                parser.name_list();
                parser.bump();
                state.stage = .typed;

                if (parser.at(.equal)) continue :stage .typed;
                if (parser.ends_here()) continue :stage .typed;
                return parser.call(typed_of(context_type));
            },
            .typed => {
                if (parser.eat(.colon)) {
                    state.stage = .constant;

                    return parser.call(list_of(context_value));
                }

                state.stage = .valued;

                if (parser.eat(.equal)) return parser.call(list_of(context_value));

                continue :stage .valued;
            },
            .constant => {
                parser.enclose(state.checkpoint, .const_type_declaration);
                parser.terminator();

                return .returned;
            },
            .valued => {
                parser.enclose(state.checkpoint, .var_declaration);
                parser.terminator();

                return .returned;
            },
        }
    }

    fn procedure_resume(parser: *Parser, state: *Procedure) Resumed {
        if (state.stage != .start) assert(state.checkpoint != null);
        if (state.typed) assert(state.operand);

        stage: switch (state.stage) {
            .start => {
                assert(parser.at(.proc_keyword));

                state.checkpoint = parser.anchor();

                parser.bump();

                if (parser.at(.text)) parser.wrap(.calling_convention);

                state.stage = .parameters;

                if (parser.at(.paren_open)) return parser.call(listed_of(.parameters));

                continue :stage .parameters;
            },
            .parameters => {
                state.stage = .results;

                if (parser.eat(.arrow)) {
                    if (!parser.at(.bang)) return parser.call(typed_of(context_type));

                    parser.results_empty();
                }

                continue :stage .results;
            },
            .results => {
                state.stage = .qualified;

                return parser.call(.{ .qualifiers = .{} });
            },
            .qualified => {
                if (state.operand) return parser.procedure_operand_tail(state);
                return parser.procedure_tail(state);
            },
            .body => {
                parser.enclose(state.checkpoint.?, .procedure);

                if (state.operand) parser.returned = parser.settle(state.checkpoint.?, false);

                return .returned;
            },
        }
    }

    fn procedure_tail(parser: *Parser, state: *Procedure) Resumed {
        assert(!state.operand);
        assert(state.stage == .qualified);

        const kind = parser.current() orelse .error_token;

        if (kind == .minus_minus_minus) {
            parser.wrap(.uninitialized);
        } else {
            const bodied = kind == .brace_open or parser.brace_follows();

            if (bodied) {
                parser.reach_a_brace();
                state.stage = .body;

                return parser.call(.{ .block = .{ .checkpoint = parser.anchor() } });
            }
        }

        parser.enclose(state.checkpoint.?, .procedure);

        return .returned;
    }

    fn procedure_operand_tail(parser: *Parser, state: *Procedure) Resumed {
        assert(state.operand);
        assert(state.stage == .qualified);

        if (parser.at(.minus_minus_minus)) {
            const kind: Kind = if (state.typed) .procedure_type else .procedure;

            parser.wrap(.uninitialized);
            parser.enclose(state.checkpoint.?, kind);

            return parser.yield_step(parser.settle(state.checkpoint.?, true));
        }

        const braced = parser.at(.brace_open) or parser.brace_follows();
        const typed = state.typed or !braced;

        if (typed) {
            parser.enclose(state.checkpoint.?, .procedure_type);

            return parser.yield_step(parser.settle(state.checkpoint.?, true));
        }

        parser.reach_a_brace();
        state.stage = .body;

        return parser.call(.{ .block = .{ .checkpoint = parser.anchor() } });
    }

    fn results_empty(parser: *Parser) void {
        assert(parser.at(.bang));
        assert(parser.nesting > 0);

        parser.open(.type);
        parser.open(.empty_type);
        parser.bump();
        parser.events.finish();
        parser.events.finish();
    }

    fn qualifiers_resume(parser: *Parser, state: *Qualifiers) Resumed {
        assert(state.iteration <= parser.steps());
        assert(parser.task_count > 1);

        while (state.iteration < parser.steps()) {
            state.iteration += 1;

            if (parser.at(.directive)) {
                parser.wrap(.tag);

                if (parser.at(.number)) parser.wrap(.number_node);
                if (parser.at(.paren_open)) return parser.call(expression_of(context_header));

                continue;
            }

            parser.reach_a_where();

            if (!parser.at(.where_keyword)) return .returned;
            return parser.call(enclosed_of(.where, null));
        }

        return .returned;
    }

    fn listed_resume(parser: *Parser, state: *Listed) Resumed {
        assert(state.iteration <= parser.steps());
        if (state.stage != .start) assert(state.checkpoint != null);

        stage: switch (state.stage) {
            .start => {
                parser.listed_open(state);

                continue :stage .items;
            },
            .items => {
                if (parser.list_closed(&state.iteration, .paren_close)) continue :stage .closed;

                state.before = parser.position;
                state.stage = .item;

                if (parser.listed_item(state.form)) |task| return parser.call(task);

                continue :stage .item;
            },
            .item => {
                if (parser.list_continues(state.before)) continue :stage .items;

                continue :stage .closed;
            },
            .closed => {
                parser.skip_breaks();
                _ = parser.eat(.paren_close);

                parser.enclose(state.checkpoint.?, state.form.node());

                switch (state.form) {
                    .parameters, .polymorphic_parameters => {},
                    .tuple, .polymorphic_type => {
                        parser.returned = parser.settle(state.checkpoint.?, true);
                    },
                }

                return .returned;
            },
        }
    }

    fn listed_open(parser: *Parser, state: *Listed) void {
        assert(state.stage == .start);
        assert(parser.at(.paren_open));

        if (state.form != .polymorphic_type) {
            state.checkpoint = parser.anchor();

            parser.bump();

            return;
        }

        assert(parser.value_count > 0);

        state.checkpoint = parser.values[parser.value_count - 1];
        parser.value_count -= 1;

        parser.enclose(state.checkpoint.?, .type);
        parser.bump();
    }

    fn listed_item(parser: *Parser, form: ListForm) ?Task {
        assert(parser.current() != null);
        assert(parser.task_count > 1);

        return switch (form) {
            .parameters => .{ .parameter = .{} },
            .polymorphic_parameters => parser.polymorphic_group(),
            .tuple => .{ .result = .{} },
            .polymorphic_type => parser.type_argument(),
        };
    }

    fn polymorphic_group(parser: *Parser) ?Task {
        assert(parser.current() != null);
        assert(parser.task_count > 1);

        for (0..parser.steps()) |_| {
            _ = parser.eat(.dollar);

            if (!parser.at_name()) break;

            parser.name();

            if (parser.at(.colon)) break;
            if (!parser.eat(.comma)) return null;
        }

        if (parser.eat(.colon)) return typed_of(context_type);
        return null;
    }

    fn type_argument(parser: *Parser) Task {
        assert(parser.current() != null);
        assert(parser.task_count > 1);

        const kind = parser.current().?;
        if (expression.literal_node(kind) != null) return expression_of(context_value);
        if (parser.opens_a_literal()) return expression_of(context_value);
        return typed_of(context_type);
    }

    fn parameter_resume(parser: *Parser, state: *Parameter) Resumed {
        if (state.stage != .start) assert(state.checkpoint != null);
        assert(parser.task_count > 1);

        stage: switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();
                _ = parser.eat(.using_keyword);

                parser.directives();
                _ = parser.eat(.dollar);

                const defaulted = parser.at_name() and parser.ahead(1) == .colon_equal;

                if (defaulted) {
                    parser.name();
                    parser.bump();
                    state.stage = .defaulted;

                    return parser.call(expression_of(context_value));
                }

                const named = parser.at_name() and parser.names_a_parameter();

                state.stage = if (named) .typed else .valued;

                if (named) {
                    parser.parameter_name_list();
                    parser.bump();
                    parser.directives();
                }

                return parser.call(typed_of(context_type));
            },
            .defaulted => {
                parser.enclose(state.checkpoint.?, .default_parameter);

                return .returned;
            },
            .typed => {
                parser.name();
                state.stage = .valued;

                if (parser.eat(.equal)) return parser.call(expression_of(context_value));

                continue :stage .valued;
            },
            .valued => {
                parser.enclose(state.checkpoint.?, .parameter);

                return .returned;
            },
        }
    }

    fn result_resume(parser: *Parser, state: *Result) Resumed {
        assert(state.iteration <= parser.steps());
        assert(parser.task_count > 1);

        stage: switch (state.stage) {
            .start => {
                const defaulted = parser.at_name() and parser.ahead(1) == .colon_equal;

                if (defaulted) {
                    parser.open(.default_type);
                    parser.name();
                    parser.bump();
                    state.stage = .defaulted;

                    return parser.call(expression_of(context_value));
                }

                const named = parser.at_name() and parser.names_a_parameter();
                if (named) continue :stage .named;

                state.stage = .plain;

                return parser.call(typed_of(context_type));
            },
            .defaulted => {
                parser.events.finish();

                return .returned;
            },
            .plain => return .returned,
            .named => {
                if (state.iteration == parser.steps()) return .returned;

                state.iteration += 1;
                state.checkpoint = parser.anchor();

                parser.name();

                if (parser.eat(.comma)) continue :stage .named;

                _ = parser.eat(.colon);
                state.stage = .typed;

                return parser.call(typed_of(context_type));
            },
            .typed => {
                state.stage = .valued;

                if (parser.eat(.equal)) return parser.call(expression_of(context_value));

                continue :stage .valued;
            },
            .valued => {
                parser.enclose(state.checkpoint.?, .named_type);

                return .returned;
            },
        }
    }

    fn typed_resume(parser: *Parser, state: *Typed) Resumed {
        assert(state.context != context_value);
        if (state.stage == .inner) assert(state.checkpoint != null);

        switch (state.stage) {
            .start => {
                if (state.tagged) parser.directives();

                state.checkpoint = parser.anchor();
                state.stage = .inner;

                return parser.call(expression_of(state.context));
            },
            .inner => {
                parser.enclose(state.checkpoint.?, .type);

                return .returned;
            },
        }
    }

    fn record_body_resume(parser: *Parser, state: *RecordBody) Resumed {
        assert(state.member.is_node());
        assert(parser.task_count > 1);

        stage: switch (state.stage) {
            .start => {
                _ = parser.anchor();
                state.bit_field = parser.at(.bit_field_keyword);

                parser.bump();
                state.stage = .polymorphic;

                if (parser.at(.paren_open)) {
                    return parser.call(listed_of(.polymorphic_parameters));
                }

                continue :stage .polymorphic;
            },
            .polymorphic => {
                state.stage = .qualified;

                return parser.call(.{ .qualifiers = .{} });
            },
            .qualified => {
                if (state.bit_field) {
                    state.stage = .bit_field;

                    if (parser.at(.brace_open)) continue :stage .bit_field;
                    if (!parser.at_name()) return parser.call(typed_of(context_type));

                    parser.named_type();

                    continue :stage .bit_field;
                }

                if (!parser.at(.bracket_open)) continue :stage .fields;

                parser.bump();
                state.stage = .bracketed;

                return parser.call(typed_of(context_type));
            },
            .bracketed => {
                _ = parser.eat(.bracket_close);

                continue :stage .fields;
            },
            .bit_field => {
                state.stage = .closed;

                return parser.call(.{ .bit_field_block = .{} });
            },
            .fields => {
                state.stage = .closed;

                return parser.call(.{ .field_block = .{ .member = state.member } });
            },
            .closed => return .returned,
        }
    }

    fn bit_field_block_resume(parser: *Parser, state: *BitFieldBlock) Resumed {
        assert(state.iteration <= parser.steps());
        assert(parser.task_count > 1);

        stage: switch (state.stage) {
            .start => {
                if (!parser.eat(.brace_open)) return .returned;

                continue :stage .items;
            },
            .items => {
                if (parser.list_closed(&state.iteration, .brace_close)) {
                    _ = parser.eat(.brace_close);

                    return .returned;
                }

                state.before = parser.position;

                parser.directives();
                parser.name();
                _ = parser.eat(.colon);

                parser.named_type();
                state.stage = .item;

                if (parser.eat(.bar)) return parser.call(expression_of(context_value));

                continue :stage .item;
            },
            .item => {
                parser.item_close(state.before);

                continue :stage .items;
            },
        }
    }

    fn field_block_resume(parser: *Parser, state: *FieldBlock) Resumed {
        assert(state.iteration <= parser.steps());
        assert(state.member.is_node());

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

                continue :stage .items;
            },
            .items => {
                if (parser.list_closed(&state.iteration, .brace_close)) {
                    _ = parser.eat(.brace_close);

                    parser.ascend();

                    return .returned;
                }

                state.before = parser.position;
                state.stage = .item;

                return parser.call(.{ .field = .{ .member = state.member } });
            },
            .item => {
                parser.item_close(state.before);

                continue :stage .items;
            },
        }
    }

    fn field_resume(parser: *Parser, state: *Field) Resumed {
        assert(state.member.is_node());
        if (state.stage != .start) assert(state.checkpoint != null);

        stage: switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();
                _ = parser.eat(.using_keyword);

                parser.directives();
                _ = parser.eat(.using_keyword);

                parser.name_list();
                _ = parser.eat(.colon);
                state.stage = .typed;

                return parser.call(typed_of(context_type));
            },
            .typed => {
                state.stage = .valued;

                if (parser.eat(.bar)) return parser.call(expression_of(context_value));

                continue :stage .valued;
            },
            .valued => {
                if (parser.at(.text)) parser.wrap(.string);

                parser.enclose(state.checkpoint.?, state.member);

                return .returned;
            },
        }
    }

    fn enumeration_body_resume(parser: *Parser, state: *EnumerationBody) Resumed {
        assert(state.iteration <= parser.steps());
        assert(parser.task_count > 1);

        stage: switch (state.stage) {
            .start => {
                parser.bump();
                state.stage = .opened;

                const braced = parser.at(.brace_open) or parser.brace_follows();
                if (!braced) return parser.call(typed_of(context_type));

                continue :stage .opened;
            },
            .opened => {
                parser.reach_a_brace();
                _ = parser.eat(.brace_open);

                continue :stage .items;
            },
            .items => {
                if (parser.list_closed(&state.iteration, .brace_close)) {
                    _ = parser.eat(.brace_close);

                    return .returned;
                }

                state.before = parser.position;

                parser.name();
                state.stage = .item;

                if (parser.eat(.equal)) return parser.call(expression_of(context_value));

                continue :stage .item;
            },
            .item => {
                parser.item_close(state.before);

                continue :stage .items;
            },
        }
    }

    fn union_body_resume(parser: *Parser, state: *UnionBody) Resumed {
        assert(state.iteration <= parser.steps());
        assert(parser.task_count > 1);

        stage: switch (state.stage) {
            .start => {
                parser.bump();
                state.stage = .polymorphic;

                if (parser.at(.paren_open)) {
                    return parser.call(listed_of(.polymorphic_parameters));
                }

                continue :stage .polymorphic;
            },
            .polymorphic => {
                state.stage = .opened;

                return parser.call(.{ .qualifiers = .{} });
            },
            .opened => {
                parser.reach_a_brace();
                _ = parser.eat(.brace_open);

                continue :stage .items;
            },
            .items => {
                if (parser.list_closed(&state.iteration, .brace_close)) {
                    _ = parser.eat(.brace_close);

                    return .returned;
                }

                state.before = parser.position;
                state.stage = .item;

                return parser.call(typed_of(context_type));
            },
            .item => {
                parser.item_close(state.before);

                continue :stage .items;
            },
        }
    }

    fn item_close(parser: *Parser, before: u32) void {
        assert(before <= parser.position);
        assert(parser.position <= parser.count());

        if (!parser.eat(.comma)) parser.terminator();
        if (parser.position == before) parser.emit();
    }

    fn block_resume(parser: *Parser, state: *Block) Resumed {
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .start => {
                if (!parser.descend()) {
                    parser.emit();

                    if (state.terminated) parser.terminator();

                    return .returned;
                }

                state.scope = parser.file_scope;
                parser.file_scope = false;

                parser.expect(.brace_open, .unexpected_token);

                continue :stage .statements;
            },
            .statements => {
                if (parser.list_closed(&state.iteration, .brace_close)) {
                    _ = parser.eat(.brace_close);

                    parser.enclose(state.checkpoint, .block);
                    parser.file_scope = state.scope;

                    parser.ascend();

                    if (state.terminated) parser.terminator();

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

    fn body_task(parser: *Parser) Task {
        assert(parser.nesting > 0);
        assert(parser.task_count > 0);

        if (parser.eat(.do_keyword)) return .{ .statement = .{} };

        parser.reach_a_brace();

        return .{ .block = .{ .checkpoint = parser.anchor() } };
    }

    fn conditional_resume(parser: *Parser, state: *Conditional) Resumed {
        assert(parser.nesting > 0);

        switch (state.stage) {
            .start => {
                parser.bump();
                state.stage = .headed;

                return parser.call(.{ .header = .{} });
            },
            .headed => {
                state.stage = .bodied;

                return parser.call(parser.body_task());
            },
            .bodied => {
                state.stage = .tailed;

                return parser.call(.{ .else_tail = .{ .whenever = state.whenever } });
            },
            .tailed => {
                const kind: Kind = if (state.whenever) .when_statement else .if_statement;

                parser.enclose(state.checkpoint, kind);
                parser.terminator();

                return .returned;
            },
        }
    }

    fn else_tail_resume(parser: *Parser, state: *ElseTail) Resumed {
        assert(state.iteration <= parser.steps());
        assert(parser.nesting > 0);

        stage: switch (state.stage) {
            .start => {
                if (state.iteration == parser.steps()) return .returned;

                state.iteration += 1;

                parser.reach_an_else();

                if (!parser.at(.else_keyword)) return .returned;

                state.checkpoint = parser.anchor();

                parser.bump();

                const branched = parser.at(.if_keyword) or parser.at(.when_keyword);

                if (branched) {
                    parser.bump();
                    state.stage = .headed;

                    return parser.call(.{ .header = .{} });
                }

                state.stage = .otherwise;

                return parser.call(parser.body_task());
            },
            .headed => {
                state.stage = .branched;

                return parser.call(parser.body_task());
            },
            .branched => {
                const kind: Kind = if (state.whenever) .else_when_clause else .else_if_clause;

                parser.enclose(state.checkpoint.?, kind);

                continue :stage .start;
            },
            .otherwise => {
                parser.enclose(state.checkpoint.?, .else_clause);

                return .returned;
            },
        }
    }

    fn header_resume(parser: *Parser, state: *Header) Resumed {
        assert(state.iteration <= parser.steps());
        assert(parser.nesting > 0);

        stage: switch (state.stage) {
            .start => {
                if (state.iteration == parser.steps()) return .returned;

                state.iteration += 1;
                state.before = parser.position;
                state.stage = .clause;

                const checkpoint = parser.anchor();
                return parser.call(parser.clause_of(checkpoint, context_header));
            },
            .clause => {
                if (!parser.follows_a_semicolon()) {
                    if (!parser.eat(.semicolon)) return .returned;
                }

                if (parser.position == state.before) return .returned;

                continue :stage .start;
            },
        }
    }

    fn clause_of(parser: *Parser, checkpoint: Checkpoint, context: u8) Task {
        assert(context == context_header or context == context_iteration);
        assert(checkpoint.index <= parser.events.count());

        const bound = parser.at_name() and parser.binder() != null;
        if (bound) return parser.binding_of(checkpoint).?;
        return .{ .expression_statement = .{ .checkpoint = checkpoint, .context = context } };
    }

    fn for_statement_resume(parser: *Parser, state: *ForStatement) Resumed {
        assert(parser.nesting > 0);

        stage: switch (state.stage) {
            .start => {
                parser.bump();
                state.stage = .headed;

                if (parser.at(.brace_open)) continue :stage .headed;
                if (parser.at(.do_keyword)) continue :stage .headed;
                if (parser.brace_follows()) continue :stage .headed;
                return parser.call(.{ .for_header = .{} });
            },
            .headed => {
                state.stage = .bodied;

                return parser.call(parser.body_task());
            },
            .bodied => {
                parser.enclose(state.checkpoint, .for_statement);
                parser.terminator();

                return .returned;
            },
        }
    }

    fn for_header_resume(parser: *Parser, state: *ForHeader) Resumed {
        if (state.stage != .start) assert(state.held != null);
        assert(parser.nesting > 0);

        stage: switch (state.stage) {
            .start => {
                state.held = parser.anchor();

                const bound = parser.at_name() and parser.binder() != null;

                if (bound) {
                    state.stage = .bound;

                    return parser.call(parser.binding_of(state.held.?).?);
                }

                state.stage = .listed;

                return parser.call(list_of(context_iteration));
            },
            .bound => {
                const clauses = parser.follows_a_semicolon() or parser.eat(.semicolon);
                if (!clauses) return .returned;

                continue :stage .clauses;
            },
            .listed => {
                if (parser.eat(.in_keyword)) {
                    state.stage = .ranged;

                    return parser.call(expression_of(context_header));
                }

                const kind = parser.current() orelse .error_token;
                const node = expression.assignment_of(kind) orelse continue :stage .assigned;

                parser.bump();
                state.node = node;
                state.stage = .assigned;

                return parser.call(list_of(context_header));
            },
            .assigned => {
                if (state.node) |node| parser.enclose(state.held.?, node);
                if (!parser.eat(.semicolon)) return .returned;

                continue :stage .clauses;
            },
            .ranged, .finished => return .returned,
            .clauses => {
                state.stage = .finished;

                return parser.call(.{ .for_clauses = .{} });
            },
        }
    }

    fn for_clauses_resume(parser: *Parser, state: *ForClauses) Resumed {
        assert(parser.nesting > 0);
        assert(parser.task_count > 1);

        stage: switch (state.stage) {
            .start => {
                state.stage = .condition;

                if (!parser.at(.semicolon)) return parser.call(expression_of(context_header));

                continue :stage .condition;
            },
            .condition => {
                _ = parser.eat(.semicolon);
                state.stage = .post;

                if (parser.at(.brace_open)) return .returned;
                if (parser.at(.do_keyword)) return .returned;

                const tail = parser.anchor();

                return parser.call(.{
                    .expression_statement = .{ .checkpoint = tail, .context = context_header },
                });
            },
            .post => return .returned,
        }
    }

    fn switch_statement_resume(parser: *Parser, state: *SwitchStatement) Resumed {
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .start => {
                parser.bump();
                state.stage = .headed;

                const braced = parser.at(.brace_open) or parser.brace_follows();
                if (!braced) return parser.call(.{ .switch_header = .{} });

                continue :stage .headed;
            },
            .headed => {
                parser.reach_a_brace();
                _ = parser.eat(.brace_open);

                continue :stage .cases;
            },
            .cases => {
                if (parser.list_closed(&state.iteration, .brace_close)) {
                    _ = parser.eat(.brace_close);

                    parser.enclose(state.checkpoint, .switch_statement);
                    parser.terminator();

                    return .returned;
                }

                state.before = parser.position;
                state.stage = .case;

                return parser.call(.{ .switch_case = .{} });
            },
            .case => {
                if (parser.position == state.before) parser.emit();

                continue :stage .cases;
            },
        }
    }

    fn switch_header_resume(parser: *Parser, state: *SwitchHeader) Resumed {
        assert(parser.nesting > 0);
        assert(parser.task_count > 1);

        switch (state.stage) {
            .start => {
                state.stage = .first;

                return parser.call(.{ .switch_clause = .{} });
            },
            .first => {
                if (!parser.eat(.semicolon)) return .returned;
                if (parser.at(.brace_open)) return .returned;
                if (parser.brace_follows()) return .returned;

                state.stage = .second;

                return parser.call(.{ .switch_clause = .{} });
            },
            .second => return .returned,
        }
    }

    fn switch_clause_resume(parser: *Parser, state: *SwitchClause) Resumed {
        if (state.stage != .start) assert(state.checkpoint != null);
        assert(parser.nesting > 0);

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();
                state.before = parser.position;
                state.stage = .clause;

                return parser.call(parser.clause_of(state.checkpoint.?, context_iteration));
            },
            .clause => {
                const carried = parser.position > state.before;

                if (!parser.eat(.in_keyword)) return .returned;

                state.stage = if (carried) .carried else .uncarried;

                return parser.call(expression_of(context_header));
            },
            .carried => {
                parser.enclose(state.checkpoint.?, .in_expression);

                return .returned;
            },
            .uncarried => return .returned,
        }
    }

    fn switch_case_resume(parser: *Parser, state: *SwitchCase) Resumed {
        assert(state.iteration <= parser.steps());
        if (state.stage != .start) assert(state.checkpoint != null);

        stage: switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();

                if (!parser.eat(.case_keyword)) {
                    state.stage = .plain;

                    return parser.call(.{ .statement = .{} });
                }

                state.stage = .listed;

                if (!parser.at(.colon)) return parser.call(list_of(context_value));

                continue :stage .ranged;
            },
            .plain => return .returned,
            .listed => {
                state.stage = .ranged;

                if (parser.eat(.in_keyword)) return parser.call(expression_of(context_value));

                continue :stage .ranged;
            },
            .ranged => {
                _ = parser.eat(.colon);

                continue :stage .statements;
            },
            .statements => {
                if (parser.switch_case_closed(state)) {
                    parser.enclose(state.checkpoint.?, .switch_case);

                    return .returned;
                }

                state.before = parser.position;
                state.stage = .statement;

                return parser.call(.{ .statement = .{} });
            },
            .statement => {
                if (parser.position == state.before) parser.emit();

                continue :stage .statements;
            },
        }
    }

    fn switch_case_closed(parser: *Parser, state: *SwitchCase) bool {
        assert(state.iteration <= parser.steps());
        assert(state.checkpoint != null);

        if (state.iteration == parser.steps()) return true;

        state.iteration += 1;

        parser.skip_breaks();

        const kind = parser.current() orelse return true;

        return switch (kind) {
            .brace_close, .case_keyword => true,
            else => false,
        };
    }

    fn expression_statement_resume(parser: *Parser, state: *ExpressionStatement) Resumed {
        assert(state.context != context_type);

        switch (state.stage) {
            .start => {
                state.first = parser.significant(parser.position);
                state.stage = .left;

                return parser.call(list_of(state.context));
            },
            .left => {
                const kind = parser.current() orelse return parser.statement_close(state);

                const held = expression.assignment_of(kind) orelse
                    return parser.statement_close(state);

                const declared = state.context != context_iteration and parser.file_scope and
                    held == .assignment_statement and kind == .colon_equal;

                if (parser.significant(parser.position) == state.first) {
                    parser.record(.expected_expression);
                }

                state.node = if (declared) .variable_declaration else held;

                parser.bump();
                parser.skip_trivia();
                state.stage = .right;

                return parser.call(list_of(state.context));
            },
            .right => {
                parser.enclose(state.checkpoint, state.node);

                return parser.statement_close(state);
            },
        }
    }

    fn statement_close(parser: *Parser, state: *ExpressionStatement) Resumed {
        assert(state.stage != .start);
        assert(parser.task_count > 0);

        if (state.terminated) parser.terminator();

        return .returned;
    }

    fn expression_list_resume(parser: *Parser, state: *ExpressionList) Resumed {
        assert(state.iteration <= parser.steps());
        if (state.stage == .item) assert(state.before <= parser.position);

        stage: switch (state.stage) {
            .start => {
                if (state.iteration == parser.steps()) return .returned;

                state.iteration += 1;
                state.before = parser.position;
                state.stage = .item;

                return parser.call(expression_of(state.context));
            },
            .item => {
                if (!parser.eat(.comma)) return .returned;

                if (state.context != context_iteration) parser.skip_breaks();
                if (parser.position == state.before) return .returned;

                continue :stage .start;
            },
        }
    }

    fn expression_resume(parser: *Parser, state: *Expression) Resumed {
        assert(state.context <= context_conditional);
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

                const next = if (state.operand)
                    parser.operand_step(state.frames_base)
                else
                    parser.operator_step(state.frames_base);

                switch (next) {
                    .step => |step| {
                        switch (parser.machine_step(state, step)) {
                            .proceed => continue :stage .machine,
                            .stop => continue :stage .finished,
                            .call => |task| {
                                state.stage = .fallback;

                                return parser.call(task);
                            },
                        }
                    },
                    .call => |task| {
                        state.stage = .resumed;

                        return parser.call(task);
                    },
                }
            },
            .resumed => {
                switch (parser.machine_step(state, parser.returned)) {
                    .proceed => continue :stage .machine,
                    .stop => continue :stage .finished,
                    .call => |task| {
                        state.stage = .fallback;

                        return parser.call(task);
                    },
                }
            },
            .fallback => {
                if (parser.machine_fallback(state, parser.returned)) continue :stage .machine;

                continue :stage .finished;
            },
            .finished => {
                parser.reduce_above(state.frames_base + 1);

                assert(parser.frame_count == state.frames_base + 1);

                parser.frame_count = state.frames_base;
                parser.value_count = state.values_base;

                parser.ascend();

                return .returned;
            },
        }
    }

    fn expression_open(parser: *Parser, state: *Expression) bool {
        assert(state.stage == .start);
        assert(state.context <= context_conditional);

        if (!parser.descend()) {
            parser.emit();

            return false;
        }

        state.frames_base = parser.frame_count;
        state.values_base = parser.value_count;

        const checkpoint = parser.anchor();
        var frame: Frame = .empty;

        frame.checkpoint = checkpoint;
        frame.content = checkpoint;
        frame.element_values = parser.value_count;
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

    fn machine_step(parser: *Parser, state: *Expression, step: Step) Flow {
        assert(parser.frame_count >= state.frames_base);
        assert(state.iteration > 0);

        switch (step) {
            .operand => state.operand = true,
            .operator => state.operand = false,
            .done => {
                if (!state.operand) return .stop;

                switch (parser.operator_step(state.frames_base)) {
                    .step => |held| {
                        if (parser.machine_fallback(state, held)) return .proceed;
                        return .stop;
                    },
                    .call => |task| return .{ .call = task },
                }
            },
        }

        if (parser.advanced(state)) return .proceed;
        return .stop;
    }

    fn machine_fallback(parser: *Parser, state: *Expression, step: Step) bool {
        assert(parser.frame_count >= state.frames_base);
        assert(state.iteration > 0);

        switch (step) {
            .done => return false,
            .operand => state.operand = true,
            .operator => state.operand = false,
        }

        return parser.advanced(state);
    }

    fn advanced(parser: *Parser, state: *const Expression) bool {
        assert(parser.position >= state.before.position);
        assert(state.iteration > 0);

        const now = parser.progress();
        if (now.position != state.before.position) return true;
        if (now.frame_count != state.before.frame_count) return true;
        return now.value_count != state.before.value_count;
    }

    fn operand_step(parser: *Parser, base: u32) Advance {
        assert(base < parser.frame_count);

        parser.skip_trivia();

        const group = parser.innermost_group(base);
        const frame = parser.frames[group];

        assert(frame.is_group());

        if (frame.is_bracketed()) parser.skip_breaks();

        const kind = parser.current() orelse return .{ .step = .done };

        if (frame.is_bracketed()) {
            if (kind == frame.closer) return .{ .step = .done };
        }

        if (frame.variant == .init) _ = parser.anchor();

        return parser.operand_of(kind, base);
    }

    fn operand_of(parser: *Parser, kind: Kind, base: u32) Advance {
        assert(base < parser.frame_count);
        assert(parser.current() == kind);

        if (expression.literal_node(kind)) |node| return .{ .step = parser.leaf(node) };
        if (expression.is_name(kind)) return .{ .step = parser.leaf(.identifier_node) };

        switch (kind) {
            .minus_minus_minus => return .{ .step = parser.leaf(.uninitialized) },
            .directive => return parser.chain_open(.{ .directive = .{ .base = base } }),
            .dollar => return .{ .call = enclosed_of(.constant_type, null) },
            .distinct_keyword => return parser.element_of(.distinct_type, base),
            .caret => return parser.element_of(.pointer_type, base),
            .dot_dot_dot => {
                const checkpoint = parser.anchor();

                parser.bump();

                return .{ .step = parser.settle(checkpoint, true) };
            },
            .dot_dot => {
                if (parser.in_a_type(base)) return parser.element_of(.variadic_type, base);
                return parser.chain_open(.{ .variadic = .{ .base = base } });
            },
            .bracket_open => return .{ .call = bracketed_of(.array, base) },
            .map_keyword => return .{ .call = bracketed_of(.map, base) },
            .matrix_keyword => return .{ .call = bracketed_of(.matrix, base) },
            else => return parser.operand_tail(kind, base),
        }
    }

    fn operand_tail(parser: *Parser, kind: Kind, base: u32) Advance {
        assert(base < parser.frame_count);
        assert(parser.current() == kind);

        switch (kind) {
            .bit_set_keyword => return .{ .call = bracketed_of(.bit_set, base) },
            .proc_keyword => return .{ .call = .{
                .procedure = .{ .operand = true, .typed = parser.in_a_type(base) },
            } },
            .bit_field_keyword => return .{ .call = record_of(.bit_field_type) },
            .struct_keyword => return .{ .call = record_of(.struct_type) },
            .enum_keyword => return .{ .call = enclosed_of(.enumeration, null) },
            .union_keyword => return .{ .call = enclosed_of(.@"union", null) },
            .cast_keyword, .transmute_keyword => return parser.cast_operand(),
            .auto_cast_keyword => return .{ .step = parser.prefix(.cast_expression) },
            .paren_open => return parser.parenthesized(base),
            .dot => {
                const checkpoint = parser.anchor();

                parser.bump();
                parser.name();
                parser.enclose(checkpoint, .member_expression);

                return .{ .step = parser.settle(checkpoint, true) };
            },
            .brace_open => {
                if (!parser.in_a_type(base)) {
                    const checkpoint = parser.anchor();
                    return .{ .step = parser.open_group(.init, checkpoint, .@"struct") };
                }
            },
            else => {},
        }

        if (expression.is_prefix(kind)) return .{ .step = parser.prefix(.unary_expression) };
        return .{ .step = .done };
    }

    fn parenthesized(parser: *Parser, base: u32) Advance {
        assert(parser.at(.paren_open));
        assert(base < parser.frame_count);

        if (parser.in_a_type(base)) {
            if (parser.conditions_a_type()) return .{ .call = .{ .conditional_type = .{} } };
            return .{ .call = listed_of(.tuple) };
        }

        if (parser.opens_a_cast()) return .{ .call = enclosed_of(.cast, null) };

        const checkpoint = parser.anchor();
        return .{ .step = parser.open_group(.paren, checkpoint, .parenthesized_expression) };
    }

    fn element_of(parser: *Parser, wrapper: Kind, base: u32) Advance {
        assert(wrapper.category() == .type);
        assert(base < parser.frame_count);

        const checkpoint = parser.anchor();

        parser.bump();

        return .{ .call = .{ .element = .{
            .base = base,
            .checkpoint = checkpoint,
            .literal = .@"struct",
            .wrapper = wrapper,
        } } };
    }

    fn chain_open(parser: *Parser, task: Task) Advance {
        assert(parser.chain_count <= chain_depth_max);
        assert(task == .directive or task == .variadic);

        if (parser.chain_count == chain_depth_max) {
            parser.outcome = .too_deep;

            return .{ .step = .done };
        }

        parser.chain_count += 1;

        return .{ .call = task };
    }

    fn chain_return(parser: *Parser, step: Step) Resumed {
        assert(parser.chain_count > 0);
        assert(parser.chain_count <= chain_depth_max);

        parser.chain_count -= 1;
        parser.returned = step;

        return .returned;
    }

    fn cast_operand(parser: *Parser) Advance {
        assert(parser.current() != null);
        assert(parser.frame_count > 0);

        if (!parser.unary_pushed(.cast_expression)) return .{ .step = .done };

        parser.bump();

        if (parser.eat(.paren_open)) return .{ .call = .{ .cast_operand = .{} } };
        return .{ .step = .operand };
    }

    fn cast_operand_resume(parser: *Parser, state: *CastOperand) Resumed {
        assert(parser.frame_count > 0);
        assert(parser.task_count > 1);

        switch (state.stage) {
            .start => {
                state.stage = .typed;

                return parser.call(typed_of(context_type));
            },
            .typed => {
                _ = parser.eat(.paren_close);

                return parser.yield_step(.operand);
            },
        }
    }

    fn prefix(parser: *Parser, kind: Kind) Step {
        assert(kind.is_node());
        assert(parser.current() != null);

        if (!parser.unary_pushed(kind)) return .done;

        parser.bump();

        return .operand;
    }

    fn unary_pushed(parser: *Parser, kind: Kind) bool {
        assert(kind.category() == .expression);
        assert(parser.frame_count > 0);

        var frame: Frame = .empty;

        frame.checkpoint = parser.anchor();
        frame.kind = kind;
        frame.power = expression.power_prefix;
        frame.stage = stage_value;
        frame.values = parser.value_count;
        frame.variant = .unary;

        return parser.push_frame(frame);
    }

    fn leaf(parser: *Parser, kind: Kind) Step {
        assert(kind.is_node());
        assert(parser.current() != null);

        const checkpoint = parser.anchor();

        parser.wrap(kind);

        return parser.settle(checkpoint, true);
    }

    fn settle(parser: *Parser, checkpoint: Checkpoint, suffixable: bool) Step {
        assert(checkpoint.index <= parser.events.count());

        parser.push_value(checkpoint);
        parser.suffixable = suffixable;

        return .operator;
    }

    fn yield_step(parser: *Parser, step: Step) Resumed {
        assert(parser.task_count > 1);
        assert(parser.frame_count > 0);

        parser.returned = step;

        return .returned;
    }

    fn reduce_tag(parser: *Parser, checkpoint: Checkpoint) void {
        assert(parser.value_count <= expression.value_count_max);
        assert(checkpoint.index <= parser.events.count());

        if (parser.value_count > 0) parser.value_count -= 1;

        parser.push_value(checkpoint);
    }

    fn directive_resume(parser: *Parser, state: *Directive) Resumed {
        assert(parser.chain_count > 0);
        assert(state.base < parser.frame_count);

        switch (state.stage) {
            .start => return parser.directive_open(state),
            .passed => return parser.chain_return(parser.returned),
            .procedure => {
                if (state.typing) parser.enclose(state.held.?, .type);

                parser.reduce_tag(state.marked.?);

                return parser.chain_return(.operator);
            },
            .operand => return parser.directive_close(state, parser.returned),
        }
    }

    fn directive_open(parser: *Parser, state: *Directive) Resumed {
        assert(state.stage == .start);
        assert(parser.at(.directive));

        state.checkpoint = parser.anchor();
        state.typing = parser.text_is(parser.position, "#type");

        parser.wrap(.tag);
        state.marked = parser.anchor();

        const kind = parser.current() orelse
            return parser.chain_return(parser.settle(state.checkpoint.?, true));

        if (kind == .paren_open) {
            if (parser.in_a_type(state.base)) return parser.directive_parenthesized(state);

            const step = parser.open_group(.call, state.checkpoint.?, .call_expression);
            return parser.chain_return(step);
        }

        if (kind == .proc_keyword) {
            const typed = state.typing or parser.in_a_type(state.base);

            state.held = parser.anchor();
            state.stage = .procedure;

            return parser.call(.{ .procedure = .{ .operand = true, .typed = typed } });
        }

        const operand = expression.opens_a_type(kind) or
            expression.literal_node(kind) != null or kind == .brace_open;

        if (!operand) return parser.chain_return(parser.settle(state.checkpoint.?, true));

        switch (parser.operand_of(kind, state.base)) {
            .step => |step| return parser.directive_close(state, step),
            .call => |task| {
                state.stage = .operand;

                return parser.call(task);
            },
        }
    }

    fn directive_parenthesized(parser: *Parser, state: *Directive) Resumed {
        assert(state.stage == .start);
        assert(parser.at(.paren_open));

        parser.bump();

        for (0..parser.steps()) |_| {
            if (parser.at(.paren_close)) break;
            if (parser.current() == null) break;

            parser.bump();
        }

        _ = parser.eat(.paren_close);

        const kind = parser.current() orelse
            return parser.chain_return(parser.settle(state.checkpoint.?, true));

        switch (parser.operand_of(kind, state.base)) {
            .step => |step| return parser.chain_return(step),
            .call => |task| {
                state.stage = .passed;

                return parser.call(task);
            },
        }
    }

    fn directive_close(parser: *Parser, state: *Directive, step: Step) Resumed {
        assert(state.marked != null);
        assert(state.checkpoint != null);

        if (step == .done) return parser.chain_return(parser.settle(state.checkpoint.?, true));

        parser.reduce_tag(state.marked.?);

        return parser.chain_return(step);
    }

    fn variadic_resume(parser: *Parser, state: *Variadic) Resumed {
        assert(parser.chain_count > 0);
        assert(state.base < parser.frame_count);

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();

                parser.bump();

                const kind = parser.current() orelse
                    return parser.chain_return(parser.settle(state.checkpoint.?, true));

                switch (parser.operand_of(kind, state.base)) {
                    .step => |step| return parser.variadic_close(state, step),
                    .call => |task| {
                        state.stage = .operand;

                        return parser.call(task);
                    },
                }
            },
            .operand => return parser.variadic_close(state, parser.returned),
        }
    }

    fn variadic_close(parser: *Parser, state: *Variadic, step: Step) Resumed {
        assert(state.checkpoint != null);
        assert(parser.chain_count > 0);

        if (step != .operator) return parser.chain_return(.operand);

        if (parser.value_count > 0) parser.value_count -= 1;

        parser.enclose(state.checkpoint.?, .variadic_expression);

        return parser.chain_return(parser.settle(state.checkpoint.?, true));
    }

    fn element_resume(parser: *Parser, state: *Element) Resumed {
        assert(state.base < parser.frame_count);

        if (state.stage == .start) {
            state.stage = .typed;

            const kind = parser.current() orelse .error_token;
            if (expression.opens_a_type(kind)) return parser.call(typed_of(context_element));

            parser.record(.expected_type);
        }

        const curly = parser.at(.brace_open) and parser.curly_allowed(state.base);

        if (curly) {
            return parser.yield_step(parser.open_group(.init, state.checkpoint, state.literal));
        }

        parser.enclose(state.checkpoint, state.wrapper);

        return parser.yield_step(parser.settle(state.checkpoint, true));
    }

    fn bracketed_resume(parser: *Parser, state: *Bracketed) Resumed {
        assert(state.base < parser.frame_count);
        if (state.stage != .start) assert(state.checkpoint != null);

        stage: switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();

                parser.bump();
                state.stage = .closing;

                if (state.form == .array) {
                    if (parser.bracketed_array()) |task| return parser.call(task);

                    continue :stage .closing;
                }

                _ = parser.eat(.bracket_open);

                if (state.form != .map) state.stage = .second;

                return parser.call(switch (state.form) {
                    .array, .map => typed_of(context_type),
                    .matrix => expression_of(context_value),
                    .bit_set => expression_of(context_header),
                });
            },
            .second => {
                state.stage = .closing;

                if (state.form == .matrix) {
                    _ = parser.eat(.comma);

                    return parser.call(expression_of(context_value));
                }

                if (parser.eat(.semicolon)) return parser.call(typed_of(context_type));

                continue :stage .closing;
            },
            .closing => {
                _ = parser.eat(.bracket_close);

                if (state.form == .bit_set) return parser.bit_set_close(state);

                state.stage = .element;

                return parser.call(.{ .element = .{
                    .base = state.base,
                    .checkpoint = state.checkpoint.?,
                    .literal = state.form.literal(),
                    .wrapper = state.form.wrapper(),
                } });
            },
            .element => return .returned,
        }
    }

    fn bracketed_array(parser: *Parser) ?Task {
        assert(parser.frame_count > 0);
        assert(parser.task_count > 1);

        _ = parser.eat(.dollar);

        switch (parser.current() orelse .error_token) {
            .dynamic_keyword, .caret, .question => {
                parser.bump();

                if (parser.eat(.semicolon)) return typed_of(context_type);
            },
            .bracket_close => {},
            else => return expression_of(context_value),
        }

        return null;
    }

    fn bit_set_close(parser: *Parser, state: *Bracketed) Resumed {
        assert(state.form == .bit_set);
        assert(state.checkpoint != null);

        const curly = parser.at(.brace_open) and parser.curly_allowed(state.base);

        if (curly) {
            return parser.yield_step(parser.open_group(.init, state.checkpoint.?, .bit_set));
        }

        parser.enclose(state.checkpoint.?, .bit_set_type);

        return parser.yield_step(parser.settle(state.checkpoint.?, true));
    }

    fn conditional_type_resume(parser: *Parser, state: *ConditionalType) Resumed {
        if (state.stage != .start) assert(state.checkpoint != null);
        assert(parser.frame_count > 0);

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();

                parser.bump();
                state.stage = .then;

                return parser.call(typed_of(context_conditional));
            },
            .then => {
                _ = parser.eat(.when_keyword);
                state.stage = .condition;

                return parser.call(expression_of(context_value));
            },
            .condition => {
                _ = parser.eat(.else_keyword);
                state.stage = .otherwise;

                return parser.call(typed_of(context_conditional));
            },
            .otherwise => {
                _ = parser.eat(.paren_close);

                parser.enclose(state.checkpoint.?, .conditional_type);

                return parser.yield_step(parser.settle(state.checkpoint.?, true));
            },
        }
    }

    fn member_resume(parser: *Parser, state: *Member) Resumed {
        assert(parser.frame_count > 0);

        switch (state.stage) {
            .start => {
                state.held = parser.anchor();
                state.casts = parser.opens_a_cast();

                parser.bump();
                state.stage = .inner;

                const context = if (state.casts) context_type else context_value;
                return parser.call(expression_of(context));
            },
            .inner => {
                const kind: Kind = if (state.casts) .cast_expression else .parenthesized_expression;

                _ = parser.eat(.paren_close);

                parser.enclose(state.held.?, kind);

                return parser.yield_step(parser.member_close(state.checkpoint));
            },
        }
    }

    fn operator_step(parser: *Parser, base: u32) Advance {
        assert(base < parser.frame_count);

        parser.skip_trivia();

        const group = parser.innermost_group(base);
        const frame = parser.frames[group];

        assert(frame.is_group());

        if (frame.is_bracketed()) parser.skip_breaks();

        const kind = parser.current() orelse return .{ .step = .done };

        if (frame.is_bracketed()) {
            if (kind == frame.closer) {
                parser.close_group(group);

                return .{ .step = .operator };
            }
        }

        if (kind == .comma) return .{ .step = parser.comma(group) };
        if (parser.separator(group, kind)) |step| return .{ .step = step };

        if (parser.in_a_type(base)) {
            switch (kind) {
                .dot => return .{ .step = parser.field_type() },
                .paren_open => return parser.polymorphic_type(),
                .slash => return parser.specialized_type(),
                else => {},
            }
        }

        return parser.postfix_step(kind, base);
    }

    fn separator(parser: *Parser, group: u32, kind: Kind) ?Step {
        assert(group < parser.frame_count);
        assert(parser.current() == kind);

        const frame = parser.frames[group];
        const sliced = kind == .colon and frame.variant == .index;
        const named = kind == .equal and (frame.variant == .call or frame.variant == .init);

        if (sliced) {
            parser.reduce_above(group + 1);
            parser.bump();
            parser.frames[group].stage = 1;

            return .operand;
        }

        if (named) {
            parser.reduce_above(group + 1);
            parser.bump();
            parser.value_count = frame.element_values;

            return .operand;
        }

        const branching = kind == .colon or kind == .else_keyword;
        if (!branching) return null;

        const held = parser.ternary_frame(group) orelse return null;

        parser.reduce_above(held + 1);
        parser.bump();

        return .operand;
    }

    fn postfix_step(parser: *Parser, kind: Kind, base: u32) Advance {
        assert(base < parser.frame_count);
        assert(parser.current() == kind);

        switch (kind) {
            .dot => return parser.member(base),
            .caret => {
                parser.reduce_for(expression.power_trailer);

                return .{ .step = parser.postfix(.address, false) };
            },
            .or_return_keyword => return .{ .step = parser.postfix(.or_return_expression, false) },
            .or_break_keyword => return .{ .step = parser.postfix(.or_break_expression, true) },
            .or_continue_keyword => {
                return .{ .step = parser.postfix(.or_continue_expression, true) };
            },
            .arrow => return .{ .step = parser.selector_call() },
            .paren_open => return .{ .step = parser.trailer(.call, .call_expression) },
            .bracket_open => return .{ .step = parser.trailer(.index, .index_expression) },
            .brace_open => {
                const curly = parser.suffixable and parser.curly_allowed(base);
                if (curly) return .{ .step = parser.trailer(.init, .@"struct") };
            },
            else => {},
        }

        const infix = parser.infix_here(kind, base) orelse return .{ .step = .done };
        return .{ .step = parser.binary(infix) };
    }

    fn infix_here(parser: *Parser, kind: Kind, base: u32) ?expression.Infix {
        assert(base < parser.frame_count);
        assert(kind.is_token());

        const context = parser.context_of(base);

        switch (kind) {
            .in_keyword, .not_in_keyword => {
                if (context == context_iteration) return null;
            },
            .when_keyword => {
                if (context == context_conditional) return null;
            },
            else => {},
        }

        const branching = kind == .if_keyword or kind == .when_keyword;

        if (branching) {
            if (parser.opens_a_line()) {
                const group = parser.innermost_group(base);
                if (parser.frames[group].variant == .top) return null;
            }
        }

        return expression.infix_of(kind);
    }

    fn binary(parser: *Parser, infix: expression.Infix) Step {
        assert(infix.node.is_node());
        assert(infix.left > expression.power_barrier);

        parser.reduce_for(infix.left);

        if (parser.value_count == 0) {
            parser.bump();

            return .operand;
        }

        const values = parser.value_count - 1;
        var frame: Frame = .empty;

        frame.checkpoint = parser.values[values];
        frame.kind = infix.node;
        frame.power = infix.right;
        frame.stage = @intFromBool(infix.node == .ternary_expression);
        frame.values = values;
        frame.variant = .binary;

        if (!parser.push_frame(frame)) return .done;

        parser.bump();
        parser.skip_trivia();

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
        const bracket = parser.anchor();

        parser.bump();
        parser.skip_breaks();

        const content = parser.anchor();
        var frame: Frame = .empty;

        frame.bracket = bracket;
        frame.checkpoint = checkpoint;

        frame.closer = switch (opener) {
            .bracket_open => .bracket_close,
            .brace_open => .brace_close,
            else => .paren_close,
        };

        frame.content = content;
        frame.element_values = parser.value_count;
        frame.kind = kind;
        frame.values = parser.value_count;
        frame.variant = variant;

        if (!parser.push_frame(frame)) return .done;

        assert(parser.frames[parser.frame_count - 1].is_bracketed());

        return .operand;
    }

    fn close_group(parser: *Parser, group: u32) void {
        assert(group < parser.frame_count);
        assert(parser.frames[group].is_bracketed());

        parser.reduce_above(group + 1);
        parser.close_element(group);

        const frame = parser.frames[group];

        parser.frame_count = group;

        const sliced = frame.variant == .index and frame.stage == 1;
        const kind: Kind = if (sliced) .slice_expression else frame.kind;

        parser.events.start_at(frame.checkpoint.?, kind);
        parser.bump();
        parser.events.finish();

        const trailing = trailer_node(frame);

        if (trailing) |held| parser.enclose(frame.bracket.?, held);

        parser.value_count = frame.values;

        parser.push_value(if (trailing == null) frame.checkpoint.? else frame.bracket.?);
        parser.suffixable = true;
    }

    fn close_element(parser: *Parser, group: u32) void {
        assert(group < parser.frame_count);
        assert(parser.frames[group].is_group());

        const frame = parser.frames[group];
        if (frame.variant != .init) return;
        if (frame.kind != .@"struct") return;
        if (parser.value_count <= frame.element_values) return;

        parser.enclose(frame.content.?, .struct_field);
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
        parser.close_element(group);
        parser.bump();
        parser.skip_breaks();
        parser.value_count = frame.values;
        parser.frames[group].elements += 1;
        parser.frames[group].element_values = parser.value_count;
        parser.frames[group].content = parser.anchor();

        return .operand;
    }

    fn field_type(parser: *Parser) Step {
        assert(parser.at(.dot));
        assert(parser.frame_count > 0);

        if (parser.value_count == 0) return .done;

        const checkpoint = parser.values[parser.value_count - 1];

        for (0..parser.steps()) |_| {
            if (!parser.eat(.dot)) break;

            parser.name();
        }

        parser.enclose(checkpoint, .field_type);
        parser.suffixable = true;

        return .operator;
    }

    fn polymorphic_type(parser: *Parser) Advance {
        assert(parser.at(.paren_open));
        assert(parser.frame_count > 0);

        if (parser.value_count == 0) return .{ .step = .done };
        return .{ .call = listed_of(.polymorphic_type) };
    }

    fn specialized_type(parser: *Parser) Advance {
        assert(parser.at(.slash));
        assert(parser.frame_count > 0);

        if (parser.value_count == 0) return .{ .step = .done };
        return .{ .call = enclosed_of(.specialized, null) };
    }

    fn member(parser: *Parser, base: u32) Advance {
        assert(parser.at(.dot));
        assert(base < parser.frame_count);

        parser.reduce_for(expression.power_trailer);

        if (parser.value_count == 0) return .{ .step = .done };

        const checkpoint = parser.values[parser.value_count - 1];

        parser.bump();

        if (parser.at(.paren_open)) {
            return .{ .call = .{ .member = .{ .checkpoint = checkpoint } } };
        }

        if (parser.at(.question)) {
            parser.bump();
        } else {
            const grouped = parser.at_name() and parser.trails_a_group(base);
            if (grouped) return .{ .step = parser.member_group(checkpoint) };

            parser.name();
        }

        return .{ .step = parser.member_close(checkpoint) };
    }

    fn member_group(parser: *Parser, checkpoint: Checkpoint) Step {
        assert(parser.value_count > 0);

        const held = parser.anchor();
        const calls = parser.ahead(1) == .paren_open;

        parser.value_count -= 1;

        parser.wrap(.identifier_node);

        const step = if (calls)
            parser.open_group(.call, held, .call_expression)
        else
            parser.open_group(.init, held, .@"struct");

        const group = parser.frame_count - 1;

        parser.frames[group].bracket = checkpoint;
        parser.frames[group].stage = stage_member;

        return step;
    }

    fn member_close(parser: *Parser, checkpoint: Checkpoint) Step {
        assert(parser.frame_count > 0);
        assert(checkpoint.index <= parser.events.count());

        parser.enclose(checkpoint, .member_expression);
        parser.suffixable = true;

        return .operator;
    }

    fn selector_call(parser: *Parser) Step {
        assert(parser.at(.arrow));
        assert(parser.frame_count > 0);

        if (parser.value_count == 0) return .done;
        if (parser.ahead(2) != .paren_open) return .done;

        const checkpoint = parser.values[parser.value_count - 1];

        parser.bump();

        if (!parser.at_name()) return .done;

        const held = parser.anchor();

        parser.value_count -= 1;

        parser.wrap(.identifier_node);

        const step = parser.open_group(.call, held, .call_expression);
        const group = parser.frame_count - 1;

        parser.frames[group].bracket = checkpoint;
        parser.frames[group].stage = stage_selector;

        return step;
    }

    fn postfix(parser: *Parser, kind: Kind, labelled: bool) Step {
        assert(kind.is_node());
        assert(parser.frame_count > 0);

        if (parser.value_count == 0) return .done;

        const checkpoint = parser.values[parser.value_count - 1];

        parser.events.start_at(checkpoint, kind);
        parser.bump();

        if (labelled) {
            if (parser.at_name()) parser.name();
        }

        parser.events.finish();
        parser.suffixable = true;

        return .operator;
    }

    fn trailer(parser: *Parser, variant: expression.Variant, kind: Kind) Step {
        assert(kind.is_node());
        assert(parser.frame_count > 0);
        assert(variant == .call or variant == .index or variant == .init);
        if (variant == .call) assert(kind == .call_expression);
        if (variant == .index) assert(kind == .index_expression);
        if (variant == .init) assert(kind == .@"struct");

        if (parser.value_count == 0) return .done;

        const checkpoint = parser.values[parser.value_count - 1];

        parser.value_count -= 1;

        return parser.open_group(variant, checkpoint, kind);
    }

    fn context_of(parser: *Parser, base: u32) u8 {
        assert(base < parser.frame_count);

        const group = parser.innermost_group(base);

        assert(group < parser.frame_count);

        if (parser.frames[group].variant != .top) return context_value;

        assert(parser.frames[group].stage <= context_conditional);

        return parser.frames[group].stage;
    }

    fn curly_allowed(parser: *Parser, base: u32) bool {
        assert(base < parser.frame_count);
        assert(parser.frames[base].variant == .top);

        return parser.context_of(base) == context_value;
    }

    fn in_a_type(parser: *Parser, base: u32) bool {
        assert(base < parser.frame_count);
        assert(parser.frames[base].variant == .top);

        return switch (parser.context_of(base)) {
            context_conditional, context_element, context_type => true,
            else => false,
        };
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

    fn ternary_frame(parser: *Parser, base: u32) ?u32 {
        assert(base < parser.frame_count);
        assert(parser.frames[base].is_group());

        var index = parser.frame_count;

        while (index > base) {
            index -= 1;

            const held = parser.frames[index];

            if (held.variant == .binary) {
                if (held.kind == .ternary_expression) return index;
            }

            if (held.is_group()) return null;
        }

        return null;
    }

    fn reduce_top(parser: *Parser) void {
        assert(parser.frame_count > 0);

        parser.frame_count -= 1;

        const frame = parser.frames[parser.frame_count];

        assert(frame.variant != .top);

        parser.enclose(frame.checkpoint.?, frame.kind);
        parser.value_count = frame.values;

        parser.push_value(frame.checkpoint.?);
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

    fn name(parser: *Parser) void {
        assert(parser.position <= parser.count());

        if (!parser.at_name()) return;

        parser.wrap(.identifier_node);

        assert(parser.position > 0);
    }

    fn name_list(parser: *Parser) void {
        assert(parser.position <= parser.count());

        const before = parser.position;

        for (0..parser.steps()) |_| {
            if (!parser.at_name()) break;

            parser.name();

            if (!parser.eat(.comma)) break;
        }

        assert(parser.position >= before);
    }

    fn universal(parser: *Parser) void {
        assert(parser.binds_a_universal());

        const kind = parser.current() orelse return;
        const node = expression.literal_node(kind) orelse return;

        assert(node.is_node());

        parser.wrap(node);
    }

    fn binds_a_universal(parser: *Parser) bool {
        assert(parser.position <= parser.count());

        const position = parser.significant(parser.position);

        assert(position >= parser.position);

        const kind = parser.kind_at(position) orelse return false;
        if (!expression.is_universal(kind)) return false;
        return parser.kind_at(parser.significant(position + 1)) == .colon_colon;
    }

    fn binder(parser: *Parser) ?Kind {
        assert(parser.position <= parser.count());
        assert(parser.significant_next <= parser.count());

        var position = parser.significant(parser.position);

        for (0..parser.steps()) |_| {
            const kind = parser.kind_at(position) orelse return null;
            if (!expression.is_name(kind)) return null;

            position = parser.significant(position + 1);

            const held = parser.kind_at(position) orelse return null;

            switch (held) {
                .colon, .colon_colon => return held,
                .comma => position = parser.significant(position + 1),
                else => return null,
            }
        }

        return null;
    }

    fn constant_kind(parser: *Parser) Kind {
        assert(parser.position <= parser.count());
        assert(parser.significant_next <= parser.count());

        var position = parser.significant(parser.position);

        for (0..parser.steps()) |_| {
            const kind = parser.kind_at(position) orelse return .const_declaration;

            if (kind == .directive) {
                if (parser.text_is(position, "#type")) return .const_declaration;

                position = parser.significant(position + 1);

                continue;
            }

            return switch (kind) {
                .struct_keyword => .struct_declaration,
                .enum_keyword => .enum_declaration,
                .union_keyword => .union_declaration,
                .bit_field_keyword => .bit_field_declaration,
                .proc_keyword => .procedure_declaration,
                else => .const_declaration,
            };
        }

        return .const_declaration;
    }

    fn opens_an_overload(parser: *Parser) bool {
        assert(parser.position <= parser.count());

        var position = parser.significant(parser.position);

        for (0..parser.steps()) |_| {
            if (parser.kind_at(position) != .directive) break;

            position = parser.significant(position + 1);
        }

        assert(position >= parser.position);

        if (parser.kind_at(position) != .proc_keyword) return false;
        return parser.kind_at(parser.significant(position + 1)) == .brace_open;
    }

    fn reach_a_where(parser: *Parser) void {
        assert(parser.position <= parser.count());

        var position = parser.position;

        for (0..parser.steps()) |_| {
            const kind = parser.kind_at(position) orelse return;
            if (kind == .where_keyword) break;
            if (!is_layout(kind)) return;

            position += 1;
        }

        parser.skip_breaks();

        assert(parser.at(.where_keyword));
    }

    fn directives(parser: *Parser) void {
        assert(parser.position <= parser.count());

        for (0..parser.steps()) |_| {
            if (!parser.at(.directive)) break;

            parser.wrap(.tag);
        }

        assert(!parser.at(.directive));
    }

    fn parameter_name_list(parser: *Parser) void {
        assert(parser.at_name());

        const before = parser.position;

        for (0..parser.steps()) |_| {
            parser.directives();

            if (parser.at(.dollar)) {
                const kind = parser.ahead(1) orelse .error_token;

                if (expression.is_name(kind)) parser.bump();
            }

            if (!parser.at_name()) break;

            parser.name();

            if (!parser.eat(.comma)) break;
        }

        assert(parser.position > before);
    }

    fn past_prefixes(parser: *Parser, from: u32) u32 {
        assert(from >= parser.position);

        var position = from;

        for (0..parser.steps()) |_| {
            const kind = parser.kind_at(position) orelse break;

            if (kind != .directive) {
                if (kind != .dollar) break;
            }

            position = parser.significant(position + 1);
        }

        assert(position >= from);

        return position;
    }

    fn names_a_parameter(parser: *Parser) bool {
        assert(parser.at_name());

        var position = parser.significant(parser.position);

        assert(position >= parser.position);

        for (0..parser.steps()) |_| {
            position = parser.past_prefixes(position);

            const kind = parser.kind_at(position) orelse return false;
            if (!expression.is_name(kind)) return false;

            position = parser.significant(position + 1);

            switch (parser.kind_at(position) orelse return false) {
                .colon => return true,
                .comma => position = parser.significant(position + 1),
                else => return false,
            }
        }

        return false;
    }

    fn named_type(parser: *Parser) void {
        assert(parser.position <= parser.count());

        const checkpoint = parser.anchor();
        var qualified = false;

        parser.name();

        for (0..parser.steps()) |_| {
            if (!parser.eat(.dot)) break;

            parser.name();
            qualified = true;
        }

        if (qualified) parser.enclose(checkpoint, .field_type);

        parser.enclose(checkpoint, .type);
    }

    fn marks_an_attribute(parser: *Parser) bool {
        assert(!parser.at(.at));
        assert(parser.position <= parser.count());

        var position = parser.position;

        for (0..parser.steps()) |_| {
            const kind = parser.kind_at(position) orelse return false;
            if (kind == .at) return true;
            if (!is_layout(kind)) return false;

            position += 1;
        }

        return false;
    }

    fn tags_a_block(parser: *Parser) bool {
        assert(parser.at(.directive));
        assert(parser.nesting > 0);

        if (parser.ahead(1) != .brace_open) return false;
        return parser.follows(.directive);
    }

    fn tags_a_statement(parser: *Parser) bool {
        assert(parser.at(.directive));
        assert(parser.nesting > 0);

        const kind = parser.ahead(1) orelse return false;

        return switch (kind) {
            .brace_open, .for_keyword, .if_keyword, .switch_keyword, .when_keyword => true,
            else => false,
        };
    }

    fn tags_an_assignment(parser: *Parser) bool {
        assert(parser.at(.directive));

        const start = parser.significant(parser.position + 1);
        var depth: u32 = 0;

        assert(start > parser.position);

        for (0..parser.steps()) |step| {
            const kind = parser.kind_at(start + @as(u32, @intCast(step))) orelse return false;

            switch (kind) {
                .brace_open, .bracket_open, .paren_open => {
                    depth += 1;

                    continue;
                },
                .brace_close, .bracket_close, .paren_close => {
                    if (depth == 0) return false;

                    depth -= 1;

                    continue;
                },
                else => {},
            }

            if (depth > 0) continue;

            switch (kind) {
                .newline, .semicolon => return false,
                .colon, .colon_colon => return true,
                else => {},
            }

            if (expression.assignment_of(kind) != null) return true;
        }

        return false;
    }

    fn labels_a_block(parser: *Parser) bool {
        assert(parser.at_name());
        assert(parser.nesting > 0);

        if (parser.ahead(1) != .colon) return false;

        const kind = parser.ahead(2) orelse return false;

        return switch (kind) {
            .brace_open, .for_keyword, .if_keyword, .switch_keyword => true,
            else => false,
        };
    }

    fn opens_a_compound(parser: *Parser) bool {
        assert(parser.position <= parser.count());
        assert(parser.nesting > 0);

        const kind = parser.current() orelse return false;

        return switch (kind) {
            .for_keyword, .if_keyword, .switch_keyword, .when_keyword => true,
            else => false,
        };
    }

    fn reach_a_brace(parser: *Parser) void {
        assert(parser.position <= parser.count());

        if (!parser.brace_follows()) return;

        parser.skip_breaks();

        assert(parser.at(.brace_open));
    }

    fn brace_follows(parser: *Parser) bool {
        assert(parser.position <= parser.count());
        assert(parser.significant_next <= parser.count());

        var position = parser.position;

        for (0..parser.steps()) |_| {
            const kind = parser.kind_at(position) orelse return false;
            if (kind == .brace_open) return true;
            if (!is_layout(kind)) return false;

            position += 1;
        }

        return false;
    }

    fn reach_an_else(parser: *Parser) void {
        parser.skip_trivia();

        assert(parser.position == parser.significant_next);

        var position = parser.position;

        for (0..parser.steps()) |_| {
            const kind = parser.kind_at(position) orelse return;
            if (kind == .else_keyword) break;
            if (!is_layout(kind)) return;

            position += 1;
        }

        parser.skip_breaks();

        assert(parser.position <= parser.count());
    }

    fn follows_a_semicolon(parser: *Parser) bool {
        assert(parser.position <= parser.count());
        assert(parser.nesting > 0);

        return parser.follows(.semicolon);
    }

    fn follows(parser: *Parser, wanted: Kind) bool {
        assert(wanted.is_token());
        assert(parser.position <= parser.count());

        var position = parser.position;

        while (position > 0) {
            position -= 1;

            const kind = parser.kind_at(position) orelse return false;
            if (is_layout(kind)) continue;
            return kind == wanted;
        }

        return false;
    }

    fn conditions_a_type(parser: *Parser) bool {
        assert(parser.at(.paren_open));

        var position = parser.significant(parser.position);
        var depth: u32 = 0;

        for (0..parser.steps()) |_| {
            const kind = parser.kind_at(position) orelse return false;

            switch (kind) {
                .paren_open => depth += 1,
                .paren_close => {
                    assert(depth > 0);

                    depth -= 1;

                    if (depth == 0) return false;
                },
                .when_keyword => {
                    if (depth == 1) return true;
                },
                else => {},
            }

            position = parser.significant(position + 1);
        }

        return false;
    }

    fn opens_a_cast(parser: *Parser) bool {
        assert(parser.at(.paren_open));

        switch (parser.ahead(1) orelse return false) {
            .bracket_open, .caret, .proc_keyword => {},
            else => return false,
        }

        var position = parser.ahead_position(1);
        var cast: Cast = .{};

        assert(position > parser.position);

        for (0..parser.steps()) |_| {
            const kind = parser.kind_at(position) orelse return true;
            if (cast.decided(kind)) |result| return result;

            position = parser.significant(position + 1);
        }

        return true;
    }

    fn opens_a_line(parser: *Parser) bool {
        assert(parser.position <= parser.count());

        const position = parser.significant(parser.position);

        assert(position >= parser.position);

        if (position >= parser.tokens.len) return false;
        if (position == 0) return false;

        const from = parser.tokens[position - 1].end();
        const to = parser.tokens[position].offset;
        if (from > to) return false;
        return std.mem.findScalar(u8, parser.source[from..to], '\n') != null;
    }

    fn trails_a_group(parser: *Parser, base: u32) bool {
        assert(parser.at_name());
        assert(base < parser.frame_count);

        const kind = parser.ahead(1) orelse return false;

        return switch (kind) {
            .paren_open => true,
            .brace_open => parser.curly_allowed(base),
            else => false,
        };
    }

    fn opens_a_literal(parser: *Parser) bool {
        assert(parser.current() != null);

        if (!parser.at_name()) return false;

        var distance: u32 = 1;

        for (0..parser.steps()) |_| {
            assert(distance % 2 == 1);

            if (parser.ahead(distance) == .brace_open) return true;
            if (parser.ahead(distance) != .dot) return false;

            const kind = parser.ahead(distance + 1) orelse return false;
            if (!expression.is_name(kind)) return false;

            distance += 2;
        }

        return false;
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

        parser.skip_breaks();

        if (parser.at(closer)) return true;
        return parser.current() == null;
    }

    fn list_continues(parser: *Parser, before: u32) bool {
        assert(before <= parser.position);
        assert(parser.position <= parser.count());

        if (!parser.eat(.comma)) return false;

        if (parser.position == before) parser.emit();

        return true;
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

    fn expect(parser: *Parser, kind: Kind, failure: Diagnostic.Kind) void {
        assert(!failure.is_indentation());
        assert(kind.is_token());
        assert(parser.position <= parser.count());

        if (parser.eat(kind)) return;

        parser.record_expected(failure, kind);
    }

    fn eat(parser: *Parser, kind: Kind) bool {
        assert(kind.is_token());

        if (!parser.at(kind)) return false;

        parser.bump();

        assert(parser.position > 0);

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

        parser.skip_trivia();

        assert(parser.position == parser.significant_next);

        parser.events.start(kind);
    }

    fn wrap(parser: *Parser, kind: Kind) void {
        assert(kind.is_node());
        assert(parser.current() != null);

        parser.open(kind);
        parser.emit();
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
            if (!parser.raw[parser.position].is_trivia()) break;

            parser.trivia_step();
        }

        assert(parser.position == parser.significant_next);
    }

    fn skip_breaks(parser: *Parser) void {
        assert(parser.position <= parser.count());

        for (parser.position..parser.raw.len) |_| {
            if (!is_layout(parser.raw[parser.position])) break;

            parser.trivia_step();
        }

        if (parser.position < parser.raw.len) assert(!is_layout(parser.raw[parser.position]));
    }

    fn trivia_step(parser: *Parser) void {
        assert(parser.position < parser.count());

        if (!parser.builds_a_tag()) {
            parser.emit();

            return;
        }

        parser.events.start(.build_tag);
        parser.events.token(parser.position);
        parser.advance();
        parser.events.finish();

        assert(parser.position > 0);
    }

    fn builds_a_tag(parser: *Parser) bool {
        assert(parser.position < parser.count());
        assert(parser.tokens.len == parser.raw.len);

        if (parser.raw[parser.position] != .comment_tag) return false;

        const text = parser.tokens[parser.position].text(parser.source);
        return std.mem.startsWith(u8, text, "#+");
    }

    fn terminator(parser: *Parser) void {
        assert(parser.position <= parser.count());

        const before = parser.position;

        if (parser.eat(.semicolon)) return;

        _ = parser.eat(.newline);

        assert(parser.position >= before);
    }

    fn ends_here(parser: *Parser) bool {
        assert(parser.significant_next <= parser.count());

        const kind = parser.current() orelse return true;

        assert(kind.is_token());

        return switch (kind) {
            .brace_close, .case_keyword, .newline, .paren_close, .semicolon => true,
            else => false,
        };
    }

    fn emit(parser: *Parser) void {
        assert(parser.position <= parser.count());

        const kind = parser.kind_at(parser.position) orelse return;
        const quoted = kind == .character or kind == .text;

        if (quoted) {
            if (!parser.string_closes(parser.position)) parser.record(.unexpected_token);
        }

        if (is_layout(kind)) {
            parser.events.layout(parser.position);
        } else {
            parser.events.token(parser.position);
        }

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

    fn string_closes(parser: *Parser, position: u32) bool {
        assert(position < parser.count());

        const text = parser.tokens[position].text(parser.source);
        if (text.len == 0) return true;

        assert(text.len <= parser.source.len);

        return text.len > 1 and text[text.len - 1] == text[0];
    }

    fn text_is(parser: *Parser, position: u32, wanted: []const u8) bool {
        assert(wanted.len > 0);
        assert(parser.tokens.len == parser.raw.len);

        if (position >= parser.tokens.len) return false;
        return std.mem.eql(u8, parser.tokens[position].text(parser.source), wanted);
    }

    fn at(parser: *Parser, kind: Kind) bool {
        assert(kind.is_token());
        assert(parser.position <= parser.count());

        return parser.current() == kind;
    }

    fn at_name(parser: *Parser) bool {
        assert(parser.position <= parser.count());

        const kind = parser.current() orelse return false;

        assert(kind.is_token());

        return expression.is_name(kind);
    }

    fn ahead(parser: *Parser, distance: u32) ?Kind {
        assert(distance > 0);
        assert(parser.position <= parser.count());

        return parser.kind_at(parser.ahead_position(distance));
    }

    fn ahead_position(parser: *Parser, distance: u32) u32 {
        assert(distance > 0);
        assert(distance <= 2 * parser.steps());

        var position = parser.significant(parser.position);

        for (0..distance) |_| {
            position = parser.significant(position + 1);
        }

        return position;
    }

    fn current(parser: *Parser) ?Kind {
        assert(parser.significant_next <= parser.count());
        assert(parser.position <= parser.significant_next);

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
            if (!parser.raw[position].is_trivia()) break;
        }

        assert(position >= from);
        if (position < parser.raw.len) assert(!parser.raw[position].is_trivia());

        return position;
    }

    fn kind_at(parser: *Parser, position: u32) ?Kind {
        assert(parser.raw.len == parser.tokens.len);

        if (position >= parser.raw.len) return null;
        return parser.raw[position];
    }

    fn count(parser: *const Parser) u32 {
        assert(parser.raw.len <= std.math.maxInt(u32));
        assert(parser.raw.len == parser.tokens.len);

        return @intCast(parser.raw.len);
    }

    fn steps(parser: *const Parser) u32 {
        const result = parser.count() + 1;

        assert(result > parser.position);

        return result;
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

const Flow = union(enum) {
    proceed,
    stop,
    call: Task,
};

const Progress = struct {
    frame_count: u32,
    position: u32,
    value_count: u32,
};

const Task = union(enum) {
    attributes: Attributes,
    bit_field_block: BitFieldBlock,
    block: Block,
    bracketed: Bracketed,
    cast_operand: CastOperand,
    conditional: Conditional,
    conditional_type: ConditionalType,
    constant: Constant,
    declaration: Entry,
    directive: Directive,
    element: Element,
    else_tail: ElseTail,
    enclosed: Enclosed,
    enumeration_body: EnumerationBody,
    expression: Expression,
    expression_list: ExpressionList,
    expression_statement: ExpressionStatement,
    field: Field,
    field_block: FieldBlock,
    for_clauses: ForClauses,
    for_header: ForHeader,
    for_statement: ForStatement,
    header: Header,
    listed: Listed,
    member: Member,
    overloaded: Overloaded,
    parameter: Parameter,
    procedure: Procedure,
    qualifiers: Qualifiers,
    record_body: RecordBody,
    result: Result,
    statement: Entry,
    switch_case: SwitchCase,
    switch_clause: SwitchClause,
    switch_header: SwitchHeader,
    switch_statement: SwitchStatement,
    typed: Typed,
    union_body: UnionBody,
    variable: Variable,
    variadic: Variadic,
};

const Attributes = struct {
    stage: enum { start, attributes, arguments, argument, closed } = .start,
    checkpoint: ?Checkpoint = null,
    held: ?Checkpoint = null,
    iteration: u32 = 0,
    inner: u32 = 0,
    before: u32 = 0,
};

const Block = struct {
    stage: enum { start, statements, statement } = .start,
    checkpoint: Checkpoint,
    terminated: bool = false,
    scope: bool = false,
    iteration: u32 = 0,
    before: u32 = 0,
};

const Bracketed = struct {
    stage: enum { start, second, closing, element } = .start,
    form: BracketForm,
    base: u32,
    checkpoint: ?Checkpoint = null,
};

const BracketForm = enum {
    array,
    bit_set,
    map,
    matrix,

    fn literal(form: BracketForm) Kind {
        assert(form != .bit_set);

        const kind: Kind = switch (form) {
            .array, .bit_set => .@"struct",
            .map => .map,
            .matrix => .matrix,
        };

        assert(kind.is_node());

        return kind;
    }

    fn wrapper(form: BracketForm) Kind {
        assert(form != .bit_set);

        const kind: Kind = switch (form) {
            .array, .bit_set => .array_type,
            .map => .map_type,
            .matrix => .matrix_type,
        };

        assert(kind.category() == .type);

        return kind;
    }
};

const Cast = struct {
    braces: u32 = 0,
    depth: u32 = 0,
    record: bool = false,

    fn decided(cast: *Cast, kind: Kind) ?bool {
        assert(kind.is_token());
        assert(cast.depth <= std.math.maxInt(u32) - 1);

        switch (kind) {
            .bracket_open, .paren_open => cast.depth += 1,
            .paren_close => {
                if (cast.depth == 0) {
                    if (cast.braces == 0) return true;
                }

                cast.depth -|= 1;
            },
            .bracket_close => cast.depth -|= 1,
            .bit_field_keyword, .enum_keyword, .struct_keyword, .union_keyword => {
                cast.record = true;
            },
            .brace_open => {
                const opens = cast.depth == 0 and cast.braces == 0 and !cast.record;
                if (opens) return false;

                cast.braces += 1;
                cast.record = false;
            },
            .brace_close => cast.braces -|= 1,
            else => {},
        }

        return null;
    }
};

const CastOperand = struct {
    stage: enum { start, typed } = .start,
};

const Conditional = struct {
    stage: enum { start, headed, bodied, tailed } = .start,
    checkpoint: Checkpoint,
    whenever: bool,
};

const ConditionalType = struct {
    stage: enum { start, then, condition, otherwise } = .start,
    checkpoint: ?Checkpoint = null,
};

const Constant = struct {
    stage: enum { start, attributed, overloaded, valued } = .start,
    checkpoint: Checkpoint,
    kind: Kind = .const_declaration,
};

const Directive = struct {
    stage: enum { start, passed, procedure, operand } = .start,
    base: u32,
    checkpoint: ?Checkpoint = null,
    marked: ?Checkpoint = null,
    held: ?Checkpoint = null,
    typing: bool = false,
};

const Element = struct {
    stage: enum { start, typed } = .start,
    base: u32,
    checkpoint: Checkpoint,
    literal: Kind,
    wrapper: Kind,
};

const ElseTail = struct {
    stage: enum { start, headed, branched, otherwise } = .start,
    checkpoint: ?Checkpoint = null,
    whenever: bool,
    iteration: u32 = 0,
};

const Enclosed = struct {
    stage: enum { start, inner } = .start,
    form: Form,
    checkpoint: ?Checkpoint,
    kind: Kind,
};

const Form = enum {
    cast,
    constant_type,
    deferred,
    enumeration,
    foreign,
    label,
    record,
    @"return",
    specialized,
    tagged_block,
    @"union",
    using,
    where,

    fn node(form: Form) Kind {
        const kind: Kind = switch (form) {
            .cast => .cast_expression,
            .constant_type => .constant_type,
            .deferred => .defer_statement,
            .enumeration => .enum_type,
            .foreign => .foreign_block,
            .label => .label_statement,
            .record => .struct_type,
            .@"return" => .return_statement,
            .specialized => .specialized_type,
            .tagged_block => .tagged_block,
            .@"union" => .union_type,
            .using => .using_statement,
            .where => .where_clause,
        };

        assert(kind.is_node());
        assert(kind != .error_node);

        return kind;
    }
};

const Entry = struct {
    stage: enum { start, attributed, finished } = .start,
    checkpoint: ?Checkpoint = null,
};

const Expression = struct {
    stage: enum { start, machine, resumed, fallback, finished } = .start,
    context: u8,
    frames_base: u32 = 0,
    values_base: u32 = 0,
    operand: bool = true,
    before: Progress = .{ .frame_count = 0, .position = 0, .value_count = 0 },
    iteration: u32 = 0,
};

const ExpressionList = struct {
    stage: enum { start, item } = .start,
    context: u8,
    iteration: u32 = 0,
    before: u32 = 0,
};

const ExpressionStatement = struct {
    stage: enum { start, left, right } = .start,
    checkpoint: Checkpoint,
    context: u8,
    first: u32 = 0,
    terminated: bool = false,
    node: Kind = .assignment_statement,
};

const Field = struct {
    stage: enum { start, typed, valued } = .start,
    checkpoint: ?Checkpoint = null,
    member: Kind,
};

const FieldBlock = struct {
    stage: enum { start, items, item } = .start,
    member: Kind,
    iteration: u32 = 0,
    before: u32 = 0,
};

const ForClauses = struct {
    stage: enum { start, condition, post } = .start,
};

const ForHeader = struct {
    stage: enum { start, bound, listed, assigned, ranged, clauses, finished } = .start,
    held: ?Checkpoint = null,
    node: ?Kind = null,
};

const ForStatement = struct {
    stage: enum { start, headed, bodied } = .start,
    checkpoint: Checkpoint,
};

const Header = struct {
    stage: enum { start, clause } = .start,
    iteration: u32 = 0,
    before: u32 = 0,
};

const ListForm = enum {
    parameters,
    polymorphic_parameters,
    polymorphic_type,
    tuple,

    fn node(form: ListForm) Kind {
        const kind: Kind = switch (form) {
            .parameters => .parameters,
            .polymorphic_parameters => .polymorphic_parameters,
            .polymorphic_type => .polymorphic_type,
            .tuple => .tuple_type,
        };

        assert(kind.is_node());
        assert(kind != .error_node);

        return kind;
    }
};

const Listed = struct {
    stage: enum { start, items, item, closed } = .start,
    form: ListForm,
    checkpoint: ?Checkpoint = null,
    iteration: u32 = 0,
    before: u32 = 0,
};

const Member = struct {
    stage: enum { start, inner } = .start,
    checkpoint: Checkpoint,
    held: ?Checkpoint = null,
    casts: bool = false,
};

const BitFieldBlock = struct {
    stage: enum { start, items, item } = .start,
    iteration: u32 = 0,
    before: u32 = 0,
};

const EnumerationBody = struct {
    stage: enum { start, opened, items, item } = .start,
    iteration: u32 = 0,
    before: u32 = 0,
};

const UnionBody = struct {
    stage: enum { start, polymorphic, opened, items, item } = .start,
    iteration: u32 = 0,
    before: u32 = 0,
};

const Overloaded = struct {
    stage: enum { start, items, item, closed } = .start,
    checkpoint: Checkpoint,
    iteration: u32 = 0,
    before: u32 = 0,
};

const Parameter = struct {
    stage: enum { start, defaulted, typed, valued } = .start,
    checkpoint: ?Checkpoint = null,
};

const Procedure = struct {
    stage: enum { start, parameters, results, qualified, body } = .start,
    checkpoint: ?Checkpoint = null,
    operand: bool = false,
    typed: bool = false,
};

const Qualifiers = struct {
    iteration: u32 = 0,
};

const RecordBody = struct {
    stage: enum { start, polymorphic, qualified, bracketed, bit_field, fields, closed } = .start,
    member: Kind,
    bit_field: bool = false,
};

const Result = struct {
    stage: enum { start, defaulted, plain, named, typed, valued } = .start,
    checkpoint: ?Checkpoint = null,
    iteration: u32 = 0,
};

const SwitchCase = struct {
    stage: enum { start, plain, listed, ranged, statements, statement } = .start,
    checkpoint: ?Checkpoint = null,
    iteration: u32 = 0,
    before: u32 = 0,
};

const SwitchClause = struct {
    stage: enum { start, clause, carried, uncarried } = .start,
    checkpoint: ?Checkpoint = null,
    before: u32 = 0,
};

const SwitchHeader = struct {
    stage: enum { start, first, second } = .start,
};

const SwitchStatement = struct {
    stage: enum { start, headed, cases, case } = .start,
    checkpoint: Checkpoint,
    iteration: u32 = 0,
    before: u32 = 0,
};

const Typed = struct {
    stage: enum { start, inner } = .start,
    checkpoint: ?Checkpoint = null,
    context: u8,
    tagged: bool,
};

const Variable = struct {
    stage: enum { start, typed, constant, valued } = .start,
    checkpoint: Checkpoint,
};

const Variadic = struct {
    stage: enum { start, operand } = .start,
    base: u32,
    checkpoint: ?Checkpoint = null,
};

const nest_depth_max: u32 = 96;
const task_chain_max: u32 = 12;
const chain_depth_max: u32 = 1_024;
const task_count_max: u32 = (nest_depth_max + 1) * task_chain_max + chain_depth_max;
const declaration_iteration_max: u32 = std.math.maxInt(u32);
const machine_step_max: u32 = std.math.maxInt(u32);
const resume_count_max: u64 = std.math.maxInt(u32);
const context_type: u8 = 0;
const context_value: u8 = 1;
const context_header: u8 = 2;
const context_iteration: u8 = 3;
const context_element: u8 = 4;
const context_conditional: u8 = 5;
const stage_value: u8 = 0;
const stage_member: u8 = 1;
const stage_selector: u8 = 2;

comptime {
    assert(task_count_max > nest_depth_max);
    assert(task_count_max > chain_depth_max);
    assert(stage_value == context_type);
    assert(stage_member != stage_selector);
}

fn expression_of(context: u8) Task {
    assert(context <= context_conditional);

    return .{ .expression = .{ .context = context } };
}

fn list_of(context: u8) Task {
    assert(context != context_type);
    assert(context <= context_iteration);

    return .{ .expression_list = .{ .context = context } };
}

fn typed_of(context: u8) Task {
    assert(context != context_value);
    assert(context <= context_conditional);

    return .{ .typed = .{ .context = context, .tagged = context != context_conditional } };
}

fn listed_of(form: ListForm) Task {
    assert(form.node().is_node());

    return .{ .listed = .{ .form = form } };
}

fn bracketed_of(form: BracketForm, base: u32) Task {
    assert(base < expression.depth_max);

    return .{ .bracketed = .{ .form = form, .base = base } };
}

fn conditional_of(checkpoint: Checkpoint, whenever: bool) Task {
    assert(checkpoint.index < std.math.maxInt(u32));

    return .{ .conditional = .{ .checkpoint = checkpoint, .whenever = whenever } };
}

fn enclosed_of(form: Form, checkpoint: ?Checkpoint) Task {
    assert(form != .record);
    if (checkpoint) |held| assert(held.index < std.math.maxInt(u32));

    return .{ .enclosed = .{ .form = form, .checkpoint = checkpoint, .kind = form.node() } };
}

fn record_of(kind: Kind) Task {
    assert(kind == .struct_type or kind == .bit_field_type);

    return .{ .enclosed = .{ .form = .record, .checkpoint = null, .kind = kind } };
}

fn enclosed_inner(form: Form) Task {
    assert(form.node().is_node());

    return switch (form) {
        .using => expression_of(context_value),
        .where => list_of(context_header),
        .constant_type, .specialized => typed_of(context_type),
        .cast => expression_of(context_type),
        .record => .{ .record_body = .{ .member = .struct_member } },
        .enumeration => .{ .enumeration_body = .{} },
        .@"union" => .{ .union_body = .{} },
        .@"return", .label, .tagged_block, .deferred, .foreign => unreachable,
    };
}

fn trailer_node(frame: Frame) ?Kind {
    assert(frame.kind.is_node());

    switch (frame.variant) {
        .call, .init => {},
        else => return null,
    }

    return switch (frame.stage) {
        stage_member => .member_expression,
        stage_selector => .selector_call_expression,
        else => null,
    };
}

fn is_layout(kind: Kind) bool {
    assert(kind.is_token());

    return kind.is_trivia() or kind == .newline;
}
