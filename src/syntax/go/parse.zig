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
const Quoting = @import("../../text/scan.zig").Quoting;
const string_is_terminated = @import("../../text/scan.zig").string_is_terminated;
const unicode = @import("../../text/unicode.zig");
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
        assert(parser.frame_count == 0);
        assert(parser.value_count == 0);

        const recorded = parser.outcome;
        const buffered = events.outcome;
        const replayed = events.replay(tree);
        const truncated = tokens_unterminated(source, tokens, raw, tree);

        if (recorded != .complete) return recorded;
        if (buffered != .complete) return buffered;
        if (truncated) return .{ .truncated = .diagnostics };
        return replayed;
    }

    fn run(parser: *Parser) void {
        assert(parser.position == 0);
        assert(parser.task_count == 0);

        parser.events.start(.file);
        parser.skip_breaks();

        if (parser.at(.package_keyword)) {
            parser.bump();
            parser.required_identifier();
            parser.terminator();
        } else {
            parser.record(.unexpected_token);
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

        parser.events.finish();
    }

    fn drive(parser: *Parser, task: Task) void {
        assert(parser.task_count == 0);
        assert(parser.nesting == 0);
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
        assert(task == &parser.tasks[parser.task_count - 1]);

        return switch (task.*) {
            .array => |*state| parser.array_resume(state),
            .block => |*state| parser.block_resume(state),
            .clause => |*state| parser.clause_resume(state),
            .clause_block => |*state| parser.clause_block_resume(state),
            .declaration => |*state| parser.declaration_resume(state),
            .expression => |*state| parser.expression_resume(state),
            .expression_list => |*state| parser.expression_list_resume(state),
            .field => |*state| parser.field_resume(state),
            .field_list => |*state| parser.field_list_resume(state),
            .for_statement => |*state| parser.for_resume(state),
            .function_declaration => |*state| parser.function_declaration_resume(state),
            .function_literal => |*state| parser.function_literal_resume(state),
            .general_declaration => |*state| parser.general_declaration_resume(state),
            .if_statement => |*state| parser.if_resume(state),
            .map => |*state| parser.map_resume(state),
            .range_statement => |*state| parser.range_resume(state),
            .signature => |*state| parser.signature_resume(state),
            .simple_statement => |*state| parser.simple_statement_resume(state),
            .statement => |*state| parser.statement_resume(state),
            .switch_statement => |*state| parser.switch_resume(state),
            .type_assertion => |*state| parser.type_assertion_resume(state),
            .type_body => |*state| parser.type_body_resume(state),
            .type_specification => |*state| parser.type_specification_resume(state),
            .value_specification => |*state| parser.value_specification_resume(state),
            .wrapped_statement => |*state| parser.wrapped_statement_resume(state),
        };
    }

    fn declaration_resume(parser: *Parser, state: *Declaration) Resumed {
        assert(parser.task_count == 1);
        if (state.stage != .start) assert(parser.nesting > 0);

        switch (state.stage) {
            .start => {
                if (!parser.descend()) {
                    parser.emit();

                    return .returned;
                }

                if (parser.declaration_open(state)) |task| return parser.call(task);
            },
            .function => {},
            .general => parser.terminator(),
        }

        parser.ascend();

        return .returned;
    }

    fn declaration_open(parser: *Parser, state: *Declaration) ?Task {
        assert(state.stage == .start);
        assert(parser.nesting > 0);

        const kind = parser.current() orelse return null;

        switch (kind) {
            .func_keyword => {
                state.stage = .function;

                return .{ .function_declaration = .{} };
            },
            .const_keyword, .import_keyword, .type_keyword, .var_keyword => {
                state.stage = .general;

                return .{ .general_declaration = .{} };
            },
            else => {
                parser.record(.unexpected_token);
                parser.emit();

                return null;
            },
        }
    }

    fn function_declaration_resume(parser: *Parser, state: *FunctionDeclaration) Resumed {
        assert(parser.nesting > 0);
        if (state.stage != .start) assert(state.checkpoint != null);

        stage: switch (state.stage) {
            .start => {
                assert(parser.at(.func_keyword));

                state.checkpoint = parser.anchor();

                parser.open(.func_type);
                parser.bump();
                state.received = parser.at(.paren_open);
                state.stage = .receiver;

                if (state.received) return parser.field_list(.paren_open, false);

                continue :stage .receiver;
            },
            .receiver => {
                parser.required_identifier();
                state.stage = .parameters;

                if (!parser.at(.bracket_open)) continue :stage .parameters;

                if (state.received) parser.record(.unexpected_token);

                return parser.type_parameters();
            },
            .parameters => {
                state.stage = .signature;

                return parser.call(.{ .signature = .{} });
            },
            .signature => {
                parser.events.finish();
                state.stage = .body;

                if (parser.at(.brace_open)) return parser.call(.{ .block = .{} });

                continue :stage .body;
            },
            .body => {
                parser.enclose(state.checkpoint.?, .func_decl);
                parser.terminator();

                return .returned;
            },
        }
    }

    fn general_declaration_resume(parser: *Parser, state: *GeneralDeclaration) Resumed {
        assert(state.iteration <= parser.steps());
        if (state.stage != .start) assert(state.keyword != .error_token);

        stage: switch (state.stage) {
            .start => {
                state.keyword = parser.current() orelse return .returned;

                parser.open(.gen_decl);
                parser.bump();

                if (parser.eat(.paren_open)) continue :stage .specifications;

                state.stage = .single;

                if (parser.specification(state.keyword)) |task| return parser.call(task);

                continue :stage .single;
            },
            .single => {
                parser.events.finish();

                return .returned;
            },
            .specifications => {
                if (parser.list_closed(&state.iteration, .paren_close)) {
                    _ = parser.eat(.paren_close);

                    parser.events.finish();

                    return .returned;
                }

                state.before = parser.position;
                state.stage = .specification;

                if (parser.specification(state.keyword)) |task| return parser.call(task);

                continue :stage .specification;
            },
            .specification => {
                parser.terminator();

                if (parser.position == state.before) parser.emit();

                continue :stage .specifications;
            },
        }
    }

    fn specification(parser: *Parser, keyword: Kind) ?Task {
        assert(keyword.is_token());
        assert(parser.nesting > 0);

        switch (keyword) {
            .import_keyword => {
                parser.import_specification();

                return null;
            },
            .type_keyword => return .{ .type_specification = .{} },
            else => return .{ .value_specification = .{ .keyword = keyword } },
        }
    }

    fn import_specification(parser: *Parser) void {
        assert(parser.nesting > 0);
        assert(parser.position <= parser.count());

        parser.open(.import_spec);

        if (parser.at(.dot)) {
            parser.wrap(.ident);
        } else {
            parser.identifier();
        }

        if (parser.at(.string_literal)) parser.wrap(.basic_lit);

        parser.events.finish();
    }

    fn type_specification_resume(parser: *Parser, state: *TypeSpecification) Resumed {
        assert(parser.nesting > 0);
        assert(state.before <= parser.count());

        stage: switch (state.stage) {
            .start => {
                parser.open(.type_spec);
                parser.required_identifier();
                state.stage = .parameters;

                const parameterized = parser.at(.bracket_open) and parser.opens_type_parameters();
                if (parameterized) return parser.type_parameters();

                continue :stage .parameters;
            },
            .parameters => {
                _ = parser.eat(.equal);
                state.before = parser.significant(parser.position);
                state.stage = .typed;

                return parser.call(expression_of(context_type));
            },
            .typed => {
                if (parser.significant(parser.position) == state.before) {
                    parser.record(.expected_type);
                }

                parser.events.finish();

                return .returned;
            },
        }
    }

    fn type_parameters(parser: *Parser) Resumed {
        assert(parser.at(.bracket_open));
        assert(parser.nesting > 0);

        const opener = parser.significant(parser.position);
        const after = parser.significant(opener + 1);
        const empty = parser.kind_at(after) == .bracket_close;
        const named = empty or parser.fields_are_named(.bracket_close);

        if (empty) parser.record(.expected_identifier);
        if (!named) parser.record(.expected_type);

        return parser.field_list(.bracket_open, false);
    }

    fn value_specification_resume(parser: *Parser, state: *ValueSpecification) Resumed {
        assert(state.keyword.is_token());
        assert(parser.nesting > 0);

        stage: switch (state.stage) {
            .start => {
                parser.open(.value_spec);

                if (!parser.at(.identifier)) parser.record(.expected_identifier);

                parser.name_list();

                state.typed = !parser.at(.equal) and parser.current() != null and
                    !parser.ends_here();

                state.stage = .typed;

                if (state.typed) return parser.call(expression_of(context_type));

                continue :stage .typed;
            },
            .typed => {
                state.valued = parser.eat(.equal);
                state.stage = .valued;

                if (state.valued) return parser.call(expression_list_of(context_expression));

                continue :stage .valued;
            },
            .valued => {
                const missing = !state.typed and !state.valued and state.keyword == .var_keyword;

                if (missing) parser.record(.expected_type);

                parser.events.finish();

                return .returned;
            },
        }
    }

    fn field_list(parser: *Parser, opener: Kind, methods: bool) Resumed {
        assert(is_opener(opener));
        if (methods) assert(opener == .brace_open);

        return parser.call(.{ .field_list = .{ .opener = opener, .methods = methods } });
    }

    fn field_list_resume(parser: *Parser, state: *FieldList) Resumed {
        assert(is_opener(state.opener));
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .start => {
                state.closer = closer_of(state.opener);
                state.named = parser.fields_are_named(state.closer);

                parser.open(.field_list);
                parser.bump();

                continue :stage .fields;
            },
            .fields => {
                if (parser.list_closed(&state.iteration, state.closer)) {
                    _ = parser.eat(state.closer);

                    parser.events.finish();

                    return .returned;
                }

                state.before = parser.position;
                state.written = state.named and parser.at(.identifier) and !parser.embeds();
                state.stage = .field;

                return parser.call(.{
                    .field = .{ .methods = state.methods, .written = state.written },
                });
            },
            .field => {
                const missing = state.named and !state.written and state.opener != .brace_open;

                if (missing) parser.record(.expected_type);
                if (!parser.eat(.comma)) parser.terminator();
                if (parser.position == state.before) parser.emit();

                continue :stage .fields;
            },
        }
    }

    fn field_resume(parser: *Parser, state: *Field) Resumed {
        assert(parser.nesting > 0);
        if (state.stage == .signature) assert(state.methods);

        switch (state.stage) {
            .start => return parser.field_open(state),
            .parameters => {
                state.stage = .signature;

                return parser.call(.{ .signature = .{} });
            },
            .signature => parser.enclose(state.held.?, .func_type),
            .typed => {},
        }

        if (parser.at(.string_literal)) parser.wrap(.basic_lit);

        parser.events.finish();

        return .returned;
    }

    fn field_open(parser: *Parser, state: *Field) Resumed {
        assert(state.stage == .start);
        if (state.written) assert(parser.at(.identifier));

        _ = parser.anchor();

        parser.open(.field);

        if (state.written) parser.name_list();

        const method = state.methods and state.written;

        if (method) {
            if (parser.at(.bracket_open)) parser.record(.unexpected_token);

            if (parser.at(.paren_open)) {
                state.held = parser.anchor();
                state.stage = .parameters;

                return parser.field_list(.paren_open, false);
            }
        }

        state.stage = .typed;

        return parser.call(expression_of(context_type));
    }

    fn signature_resume(parser: *Parser, state: *Signature) Resumed {
        assert(parser.nesting > 0);
        if (state.stage == .result) assert(state.checkpoint != null);

        stage: switch (state.stage) {
            .start => {
                state.stage = .parameters;

                if (parser.at(.paren_open)) return parser.field_list(.paren_open, false);

                continue :stage .parameters;
            },
            .parameters => {
                if (parser.at(.paren_open)) {
                    state.stage = .results;

                    return parser.field_list(.paren_open, false);
                }

                if (!parser.opens_a_result()) return .returned;

                state.checkpoint = parser.anchor();

                parser.open(.field);
                state.stage = .result;

                return parser.call(expression_of(context_type));
            },
            .results => return .returned,
            .result => {
                parser.events.finish();
                parser.enclose(state.checkpoint.?, .field_list);

                return .returned;
            },
        }
    }

    fn block_resume(parser: *Parser, state: *Block) Resumed {
        assert(parser.task_count > 1);
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .start => {
                if (!parser.descend()) {
                    parser.emit();

                    return .returned;
                }

                parser.open(.block_stmt);
                parser.expect(.brace_open, .unexpected_token);

                continue :stage .statements;
            },
            .statements => {
                if (parser.list_closed(&state.iteration, .brace_close)) {
                    _ = parser.eat(.brace_close);

                    parser.events.finish();
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

                if (parser.statement_open(state)) |task| return parser.call(task);
            },
            .block, .simple => parser.terminator(),
            .declaration => {
                parser.enclose(state.checkpoint.?, .decl_stmt);
                parser.terminator();
            },
            .results, .selected => {
                parser.events.finish();
                parser.terminator();
            },
            .labeled => parser.events.finish(),
            .delegated => {},
        }

        parser.ascend();

        return .returned;
    }

    fn statement_open(parser: *Parser, state: *Statement) ?Task {
        assert(state.stage == .start);
        assert(parser.nesting > 0);

        const kind = parser.current() orelse return null;

        switch (kind) {
            .brace_open => {
                state.stage = .block;

                return .{ .block = .{} };
            },
            .const_keyword, .type_keyword, .var_keyword => {
                state.checkpoint = parser.anchor();
                state.stage = .declaration;

                return .{ .general_declaration = .{} };
            },
            .return_keyword => return parser.return_open(state),
            .break_keyword, .continue_keyword, .fallthrough_keyword, .goto_keyword => {
                parser.branch_statement(kind);

                return null;
            },
            .semicolon => {
                parser.open(.empty_stmt);
                parser.bump();
                parser.events.finish();

                return null;
            },
            .identifier => {
                const labeled = parser.ahead(1) == .colon and parser.ahead(2) != .equal;
                if (labeled) return parser.labeled_open(state);
            },
            else => {
                if (parser.statement_keyword(state, kind)) |task| return task;
            },
        }

        state.stage = .simple;

        return simple_statement_of(context_expression);
    }

    fn statement_keyword(parser: *Parser, state: *Statement, kind: Kind) ?Task {
        assert(state.stage == .start);
        assert(parser.current() == kind);

        const task: Task = switch (kind) {
            .if_keyword => .{ .if_statement = .{} },
            .for_keyword => parser.loop_of(),
            .switch_keyword => .{ .switch_statement = .{} },
            .go_keyword => .{ .wrapped_statement = .{ .kind = .go_stmt } },
            .defer_keyword => .{ .wrapped_statement = .{ .kind = .defer_stmt } },
            .select_keyword => {
                parser.open(.select_stmt);
                parser.bump();
                state.stage = .selected;

                return .{ .clause_block = .{ .kind = .comm_clause } };
            },
            else => return null,
        };

        state.stage = .delegated;

        return task;
    }

    fn loop_of(parser: *Parser) Task {
        assert(parser.at(.for_keyword));
        assert(parser.nesting > 0);

        if (parser.header_holds(.range_keyword)) return .{ .range_statement = .{} };
        return .{ .for_statement = .{} };
    }

    fn return_open(parser: *Parser, state: *Statement) ?Task {
        assert(state.stage == .start);
        assert(parser.at(.return_keyword));

        parser.open(.return_stmt);
        parser.bump();

        const empty = parser.ends_here() or parser.at(.brace_close);

        if (empty) {
            parser.events.finish();
            parser.terminator();

            return null;
        }

        state.stage = .results;

        return expression_list_of(context_expression);
    }

    fn labeled_open(parser: *Parser, state: *Statement) ?Task {
        assert(state.stage == .start);
        assert(parser.at(.identifier));

        parser.open(.labeled_stmt);
        parser.identifier();
        parser.bump();
        parser.skip_breaks();

        const empty = parser.at(.brace_close) or parser.current() == null;

        if (empty) {
            parser.events.finish();

            return null;
        }

        state.stage = .labeled;

        return .{ .statement = .{} };
    }

    fn branch_statement(parser: *Parser, kind: Kind) void {
        assert(kind.is_token());
        assert(parser.current() == kind);

        parser.open(.branch_stmt);
        parser.bump();

        if (kind == .goto_keyword) {
            if (!parser.at(.identifier)) parser.record(.expected_identifier);
        }

        parser.identifier();
        parser.events.finish();
        parser.terminator();
    }

    fn wrapped_statement_resume(parser: *Parser, state: *WrappedStatement) Resumed {
        assert(state.kind.category() == .expression);
        assert(parser.nesting > 0);

        switch (state.stage) {
            .start => {
                parser.open(state.kind);
                parser.bump();
                state.head = parser.significant(parser.position);
                state.stage = .expression;

                return parser.call(expression_of(context_expression));
            },
            .expression => {
                const end = parser.significant(parser.position);

                const missing = end == state.head or parser.wraps(state.head, end) or
                    parser.preceding(end) != .paren_close;

                if (missing) parser.record(.expected_expression);

                parser.events.finish();
                parser.terminator();

                return .returned;
            },
        }
    }

    fn simple_statement_resume(parser: *Parser, state: *SimpleStatement) Resumed {
        assert(state.context <= context_header);
        if (state.stage != .start) assert(state.checkpoint != null);

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();
                state.stage = .left;

                return parser.call(expression_list_of(state.context));
            },
            .left => {
                const kind = parser.current() orelse .error_token;

                if (expression.assigns(kind)) {
                    parser.bump();

                    if (parser.at(.range_keyword)) parser.bump();

                    state.node = .assign_stmt;
                    state.stage = .right;

                    return parser.call(expression_list_of(state.context));
                }

                if (kind == .arrow) {
                    parser.bump();
                    state.node = .send_stmt;
                    state.stage = .right;

                    return parser.call(expression_of(state.context));
                }

                const node: Kind = switch (kind) {
                    .minus_minus, .plus_plus => .inc_dec_stmt,
                    else => .expr_stmt,
                };

                if (node == .inc_dec_stmt) parser.bump();

                parser.enclose(state.checkpoint.?, node);
            },
            .right => parser.enclose(state.checkpoint.?, state.node),
        }

        return .returned;
    }

    fn if_resume(parser: *Parser, state: *IfStatement) Resumed {
        assert(state.opened <= state.iteration);
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .arm => {
                if (state.iteration == parser.steps()) continue :stage .closed;

                state.iteration += 1;

                parser.open(.if_stmt);
                parser.bump();
                state.opened += 1;

                if (!parser.header_semicolon()) continue :stage .condition;

                state.stage = .initialized;

                return parser.call(simple_statement_of(context_header));
            },
            .initialized => {
                _ = parser.eat(.semicolon);

                continue :stage .condition;
            },
            .condition => {
                if (parser.at(.brace_open)) parser.record(.expected_expression);

                state.stage = .body;

                return parser.call(expression_of(context_header));
            },
            .body => {
                state.stage = .chained;

                return parser.call(.{ .block = .{} });
            },
            .chained => {
                if (!parser.eat(.else_keyword)) {
                    parser.terminator();

                    continue :stage .closed;
                }

                if (parser.at(.if_keyword)) continue :stage .arm;

                state.stage = .otherwise;

                return parser.call(.{ .block = .{} });
            },
            .otherwise => {
                parser.terminator();

                continue :stage .closed;
            },
            .closed => {
                for (0..state.opened) |_| parser.events.finish();

                return .returned;
            },
        }
    }

    fn for_resume(parser: *Parser, state: *ForStatement) Resumed {
        assert(parser.nesting > 0);
        assert(parser.task_count > 1);

        stage: switch (state.stage) {
            .start => {
                parser.open(.for_stmt);
                parser.bump();

                if (parser.at(.brace_open)) continue :stage .header;

                if (!parser.header_semicolon()) {
                    state.stage = .header;

                    return parser.call(expression_of(context_header));
                }

                if (parser.at(.semicolon)) continue :stage .initialized;

                state.stage = .initialized;

                return parser.call(simple_statement_of(context_header));
            },
            .initialized => {
                _ = parser.eat(.semicolon);

                if (parser.at(.semicolon)) continue :stage .conditioned;

                state.stage = .conditioned;

                return parser.call(expression_of(context_header));
            },
            .conditioned => {
                _ = parser.eat(.semicolon);

                if (parser.at(.brace_open)) continue :stage .header;

                state.stage = .header;

                return parser.call(simple_statement_of(context_header));
            },
            .header => {
                state.stage = .body;

                return parser.call(.{ .block = .{} });
            },
            .body => {
                parser.events.finish();
                parser.terminator();

                return .returned;
            },
        }
    }

    fn range_resume(parser: *Parser, state: *RangeStatement) Resumed {
        assert(parser.nesting > 0);
        assert(parser.task_count > 1);

        stage: switch (state.stage) {
            .start => {
                parser.open(.range_stmt);
                parser.bump();

                if (parser.at(.range_keyword)) continue :stage .subject;

                if (parser.range_variables() > 2) parser.record(.unexpected_token);

                state.stage = .variables;

                return parser.call(expression_list_of(context_header));
            },
            .variables => {
                if (expression.assigns(parser.current() orelse .error_token)) parser.bump();

                continue :stage .subject;
            },
            .subject => {
                _ = parser.eat(.range_keyword);
                state.stage = .header;

                return parser.call(expression_of(context_header));
            },
            .header => {
                state.stage = .body;

                return parser.call(.{ .block = .{} });
            },
            .body => {
                parser.events.finish();
                parser.terminator();

                return .returned;
            },
        }
    }

    fn switch_resume(parser: *Parser, state: *SwitchStatement) Resumed {
        assert(parser.nesting > 0);
        assert(parser.task_count > 1);

        stage: switch (state.stage) {
            .start => {
                state.typed = parser.header_holds(.type_keyword);

                parser.open(if (state.typed) .type_switch_stmt else .switch_stmt);
                parser.bump();

                if (!parser.header_semicolon()) continue :stage .subject;

                state.stage = .initialized;

                return parser.call(simple_statement_of(context_header));
            },
            .initialized => {
                _ = parser.eat(.semicolon);

                continue :stage .subject;
            },
            .subject => {
                if (parser.at(.brace_open)) continue :stage .header;

                state.stage = .header;

                if (state.typed) return parser.call(simple_statement_of(context_header));
                return parser.call(expression_of(context_header));
            },
            .header => {
                state.stage = .body;

                return parser.call(.{ .clause_block = .{ .kind = .case_clause } });
            },
            .body => {
                parser.events.finish();
                parser.terminator();

                return .returned;
            },
        }
    }

    fn clause_block_resume(parser: *Parser, state: *ClauseBlock) Resumed {
        assert(state.kind.category() == .block);
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .start => {
                parser.open(.block_stmt);
                parser.expect(.brace_open, .unexpected_token);

                continue :stage .clauses;
            },
            .clauses => {
                if (parser.list_closed(&state.iteration, .brace_close)) {
                    _ = parser.eat(.brace_close);

                    parser.events.finish();

                    return .returned;
                }

                state.before = parser.position;
                state.stage = .clause;

                return parser.call(.{ .clause = .{ .kind = state.kind } });
            },
            .clause => {
                if (parser.position == state.before) parser.emit();

                continue :stage .clauses;
            },
        }
    }

    fn clause_resume(parser: *Parser, state: *Clause) Resumed {
        assert(state.kind.category() == .block);
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .start => {
                parser.open(state.kind);

                if (!parser.eat(.case_keyword)) {
                    _ = parser.eat(.default_keyword);

                    continue :stage .head;
                }

                state.stage = .head;

                if (state.kind == .comm_clause) {
                    return parser.call(simple_statement_of(context_expression));
                }

                return parser.call(expression_list_of(context_expression));
            },
            .head => {
                parser.expect(.colon, .expected_colon);

                continue :stage .statements;
            },
            .statements => {
                if (parser.clause_closed(&state.iteration)) {
                    parser.events.finish();

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

    fn expression_list_resume(parser: *Parser, state: *ExpressionList) Resumed {
        assert(state.context <= context_header);
        assert(state.iteration <= parser.steps());

        stage: switch (state.stage) {
            .start => {
                if (state.iteration == parser.steps()) return .returned;

                state.iteration += 1;
                state.before = parser.position;
                state.stage = .expression;

                return parser.call(expression_of(state.context));
            },
            .expression => {
                if (!parser.eat(.comma)) return .returned;

                parser.skip_breaks();

                if (parser.position == state.before) return .returned;

                continue :stage .start;
            },
        }
    }

    fn expression_resume(parser: *Parser, state: *Expression) Resumed {
        assert(state.context <= context_header);
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
                state.stage = .stepped;

                const advance = if (state.operand)
                    parser.operand_step(state.frames_base)
                else
                    parser.operator_step(state.frames_base);

                switch (advance) {
                    .step => |step| parser.returned = step,
                    .call => |task| return parser.call(task),
                }

                continue :stage .stepped;
            },
            .stepped => {
                if (parser.returned != .done) {
                    state.operand = parser.returned == .operand;

                    continue :stage .checked;
                }

                if (!state.operand) continue :stage .finished;

                state.stage = .fallback;

                switch (parser.operator_step(state.frames_base)) {
                    .step => |step| parser.returned = step,
                    .call => |task| return parser.call(task),
                }

                continue :stage .fallback;
            },
            .fallback => {
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

                return .returned;
            },
        }
    }

    fn expression_close(parser: *Parser, state: *const Expression) void {
        assert(parser.frame_count > state.frames_base);
        assert(parser.nesting > 0);

        parser.reduce_above(state.frames_base + 1);

        assert(parser.frame_count == state.frames_base + 1);

        if (parser.value_count == state.values_base) parser.record(.expected_expression);

        parser.frame_count = state.frames_base;
        parser.value_count = state.values_base;

        parser.ascend();
    }

    fn expression_open(parser: *Parser, state: *Expression) bool {
        assert(state.stage == .start);
        assert(state.context <= context_header);

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

    fn operand_step(parser: *Parser, base: u32) Advance {
        assert(base < parser.frame_count);

        parser.skip_trivia();

        const group = parser.innermost_group(base);
        const bracketed = parser.frames[group].is_bracketed();

        if (bracketed) parser.skip_breaks();

        const kind = parser.current() orelse return .{ .step = .done };

        if (bracketed) {
            if (kind == parser.frames[group].closer) return .{ .step = .done };
        }

        return parser.operand_of(kind, base);
    }

    fn operand_of(parser: *Parser, kind: Kind, base: u32) Advance {
        assert(base < parser.frame_count);
        assert(parser.current() == kind);

        const step: Step = switch (kind) {
            .star => parser.prefix(.star_expr, 2),
            .arrow => parser.arrow(),
            .chan_keyword => parser.channel_type(),
            .dot_dot_dot => parser.prefix(.ellipsis, 1),
            .tilde => parser.tilde(base),
            .paren_open => parser.open_group(.paren, parser.anchor()),
            .brace_open => parser.composite_open(base),
            .identifier => parser.leaf(.ident),
            .number, .rune_literal, .string_literal => parser.leaf(.basic_lit),
            .ampersand, .bang, .caret, .minus, .plus => parser.prefix(.unary_expr, 0),
            else => return parser.operand_task(kind, base),
        };

        return .{ .step = step };
    }

    fn operand_task(parser: *Parser, kind: Kind, base: u32) Advance {
        assert(base < parser.frame_count);
        assert(kind.is_token());

        const task: Task = switch (kind) {
            .map_keyword => .{ .map = .{} },
            .bracket_open => .{ .array = .{} },
            .struct_keyword => .{ .type_body = .{ .kind = .struct_type } },
            .interface_keyword => .{ .type_body = .{ .kind = .interface_type } },
            .func_keyword => .{ .function_literal = .{
                .structured = parser.bodies(base) and !parser.holds_a_type(),
            } },
            else => return .{ .step = .done },
        };

        return .{ .call = task };
    }

    fn prefix(parser: *Parser, kind: Kind, stage: u8) Step {
        assert(kind.is_node());
        assert(stage <= 2);

        var frame: Frame = .empty;

        frame.checkpoint = parser.anchor();
        frame.kind = kind;
        frame.power = expression.power_unary;
        frame.stage = stage;
        frame.values = parser.value_count;
        frame.variant = .unary;

        if (!parser.push_frame(frame)) return .done;

        parser.bump();

        return .operand;
    }

    fn arrow(parser: *Parser) Step {
        assert(parser.at(.arrow));
        assert(parser.frame_count > 0);

        if (parser.ahead(1) == .chan_keyword) return parser.channel_type();
        return parser.prefix(.unary_expr, 0);
    }

    fn tilde(parser: *Parser, base: u32) Step {
        assert(parser.at(.tilde));
        assert(base < parser.frame_count);

        if (parser.frames[parser.innermost_group(base)].variant == .paren) {
            parser.record(.expected_type);
        }

        return parser.prefix(.unary_expr, 0);
    }

    fn channel_type(parser: *Parser) Step {
        assert(parser.frame_count > 0);

        const checkpoint = parser.anchor();
        const received = parser.eat(.arrow);

        assert(parser.at(.chan_keyword));

        _ = parser.eat(.chan_keyword);

        if (!received) _ = parser.eat(.arrow);

        return parser.type_frame(checkpoint, .chan_type);
    }

    fn type_frame(parser: *Parser, checkpoint: Checkpoint, kind: Kind) Step {
        assert(kind.category() == .type);

        var frame: Frame = .empty;

        frame.checkpoint = checkpoint;
        frame.kind = kind;
        frame.power = expression.power_unary;
        frame.stage = 1;
        frame.values = parser.value_count;
        frame.variant = .unary;

        if (!parser.push_frame(frame)) return .done;
        return .operand;
    }

    fn composite_open(parser: *Parser, base: u32) Step {
        assert(parser.at(.brace_open));
        assert(base < parser.frame_count);

        if (!parser.in_composite(base)) return .done;
        return parser.open_group(.composite, parser.anchor());
    }

    fn leaf(parser: *Parser, kind: Kind) Step {
        assert(kind.is_node());
        assert(parser.current() != null);

        const checkpoint = parser.anchor();

        parser.wrap(kind);
        parser.push_value(checkpoint);

        return .operator;
    }

    fn map_resume(parser: *Parser, state: *Map) Resumed {
        assert(parser.nesting > 0);
        if (state.stage != .start) assert(state.checkpoint != null);

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();

                parser.bump();
                _ = parser.eat(.bracket_open);
                state.stage = .key;

                return parser.call(expression_of(context_type));
            },
            .key => {
                _ = parser.eat(.bracket_close);
                parser.returned = parser.type_frame(state.checkpoint.?, .map_type);

                return .returned;
            },
        }
    }

    fn array_resume(parser: *Parser, state: *Array) Resumed {
        assert(parser.nesting > 0);
        if (state.stage != .start) assert(state.checkpoint != null);

        stage: switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();

                parser.bump();

                if (parser.at(.dot_dot_dot)) {
                    parser.wrap(.ellipsis);

                    continue :stage .length;
                }

                if (parser.at(.bracket_close)) continue :stage .length;

                state.stage = .length;

                return parser.call(expression_of(context_expression));
            },
            .length => {
                _ = parser.eat(.bracket_close);
                parser.returned = parser.type_frame(state.checkpoint.?, .array_type);

                return .returned;
            },
        }
    }

    fn type_body_resume(parser: *Parser, state: *TypeBody) Resumed {
        assert(state.kind.category() == .@"struct");
        if (state.stage != .start) assert(state.checkpoint != null);

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();

                parser.bump();
                state.stage = .body;

                return parser.field_list(.brace_open, state.kind == .interface_type);
            },
            .body => {
                parser.enclose(state.checkpoint.?, state.kind);
                parser.push_value(state.checkpoint.?);
                parser.returned = .operator;

                return .returned;
            },
        }
    }

    fn function_literal_resume(parser: *Parser, state: *FunctionLiteral) Resumed {
        assert(parser.nesting > 0);
        if (state.stage != .start) assert(state.checkpoint != null);

        switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();

                parser.open(.func_type);
                parser.bump();
                state.stage = .signature;

                return parser.call(.{ .signature = .{} });
            },
            .signature => {
                parser.events.finish();

                const body = parser.at(.brace_open) and state.structured;

                if (body) {
                    state.stage = .body;

                    return parser.call(.{ .block = .{} });
                }
            },
            .body => parser.enclose(state.checkpoint.?, .func_lit),
        }

        parser.push_value(state.checkpoint.?);
        parser.returned = .operator;

        return .returned;
    }

    fn type_assertion_resume(parser: *Parser, state: *TypeAssertion) Resumed {
        assert(parser.nesting > 0);

        stage: switch (state.stage) {
            .start => {
                parser.events.start_at(state.checkpoint, .type_assert_expr);
                parser.bump();
                parser.bump();

                if (parser.at(.type_keyword)) {
                    parser.bump();

                    continue :stage .typed;
                }

                state.stage = .typed;

                return parser.call(expression_of(context_type));
            },
            .typed => {
                _ = parser.eat(.paren_close);

                parser.events.finish();
                parser.returned = .operator;

                return .returned;
            },
        }
    }

    fn operator_step(parser: *Parser, base: u32) Advance {
        assert(base < parser.frame_count);

        parser.skip_trivia();

        const group = parser.innermost_group(base);
        const frame = parser.frames[group];

        if (frame.is_bracketed()) parser.skip_breaks();

        const kind = parser.current() orelse return .{ .step = .done };

        if (frame.is_bracketed()) {
            if (kind == frame.closer) {
                parser.close_group(group);

                return .{ .step = .operator };
            }
        }

        switch (kind) {
            .dot => return parser.selector(),
            .dot_dot_dot => {
                parser.reduce_above(group + 1);
                parser.bump();

                return .{ .step = .operator };
            },
            .comma => return .{ .step = parser.comma(group) },
            .colon => {
                if (frame.variant == .index) return .{ .step = parser.slice_colon(group) };
                if (frame.variant == .composite) return .{ .step = parser.key_value(group) };
            },
            else => {},
        }

        if (parser.trailer_step(kind, base)) |step| return .{ .step = step };

        const binding = expression.infix_of(kind) orelse return .{ .step = .done };
        return .{ .step = parser.binary(binding) };
    }

    fn slice_colon(parser: *Parser, group: u32) Step {
        assert(group < parser.frame_count);
        assert(parser.frames[group].variant == .index);

        parser.reduce_above(group + 1);

        if (parser.frames[group].stage == 1) {
            const colon = parser.significant(parser.position);

            const empty = parser.preceding(colon) == .colon or
                parser.kind_at(parser.significant(colon + 1)) == .bracket_close;

            if (empty) parser.record(.expected_expression);
        }

        parser.bump();
        parser.frames[group].stage = 1;

        return .operand;
    }

    fn selector(parser: *Parser) Advance {
        assert(parser.at(.dot));
        assert(parser.value_count <= expression.value_count_max);

        if (parser.value_count == 0) return .{ .step = .done };

        const checkpoint = parser.values[parser.value_count - 1];

        if (parser.ahead(1) == .paren_open) {
            return .{ .call = .{ .type_assertion = .{ .checkpoint = checkpoint } } };
        }

        parser.events.start_at(checkpoint, .selector_expr);
        parser.bump();
        parser.identifier();
        parser.events.finish();

        return .{ .step = .operator };
    }

    fn trailer_step(parser: *Parser, kind: Kind, base: u32) ?Step {
        assert(base < parser.frame_count);
        assert(kind.is_token());

        switch (kind) {
            .paren_open => {
                const stage: u8 = if (parser.holds_a_type()) 2 else 1;

                parser.drain_types(stage);

                return parser.trailer(.call);
            },
            .bracket_open => {
                if (parser.holds_a_type()) parser.index_checked();

                return parser.trailer(.index);
            },
            .brace_open => {
                if (parser.value_count == 0) return null;
                if (!parser.composes(base)) return null;

                parser.drain_types(2);

                return parser.trailer(.composite);
            },
            else => return null,
        }
    }

    fn composes(parser: *Parser, base: u32) bool {
        assert(base < parser.frame_count);
        assert(parser.value_count > 0);

        if (parser.structures(base)) return true;
        return parser.heads_a_clause(base) and parser.holds_a_type();
    }

    fn index_checked(parser: *Parser) void {
        assert(parser.at(.bracket_open));
        assert(parser.holds_a_type());

        const opener = parser.significant(parser.position);
        const element = parser.significant(opener + 1);
        const kind = parser.kind_at(element) orelse return;
        if (!expression.is_literal(kind)) return;

        const after = parser.kind_at(parser.significant(element + 1)) orelse return;
        const closes = after == .bracket_close or after == .comma;

        if (closes) parser.record(.expected_type);
    }

    fn binary(parser: *Parser, binding: expression.Binding) Step {
        assert(binding.left > expression.power_barrier);
        assert(binding.left < binding.right);

        parser.reduce_for(binding.left);

        if (parser.value_count == 0) {
            parser.record(.expected_expression);
            parser.bump();

            return .operand;
        }

        const values_kept = parser.value_count - 1;
        var frame: Frame = .empty;

        frame.checkpoint = parser.values[values_kept];
        frame.kind = .binary_expr;
        frame.power = binding.right;
        frame.values = values_kept;
        frame.variant = .binary;

        if (!parser.push_frame(frame)) return .done;

        parser.bump();
        parser.skip_breaks();

        return .operand;
    }

    fn open_group(parser: *Parser, variant: Variant, checkpoint: Checkpoint) Step {
        assert(variant != .top);

        const opener = parser.current() orelse .paren_open;

        _ = parser.anchor();

        parser.bump();
        parser.skip_breaks();
        _ = parser.anchor();

        var frame: Frame = .empty;

        frame.checkpoint = checkpoint;
        frame.closer = closer_of(opener);

        frame.kind = switch (variant) {
            .call => .call_expr,
            .composite => .composite_lit,
            .index => .index_expr,
            .paren => .paren_expr,
            .binary, .top, .unary => .error_node,
        };

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

        const empty = frame.variant == .index and frame.stage != 1 and
            parser.value_count == frame.values;

        if (empty) parser.record(.expected_expression);

        parser.frame_count = group;

        const kind = if (frame.variant == .index) index_kind_of(&frame) else frame.kind;

        parser.events.start_at(frame.checkpoint.?, kind);
        parser.bump();
        parser.events.finish();
        parser.value_count = frame.values;

        parser.push_value(frame.checkpoint.?);
    }

    fn comma(parser: *Parser, group: u32) Step {
        assert(group < parser.frame_count);
        assert(parser.frames[group].is_group());

        const frame = parser.frames[group];
        if (frame.variant == .top) return .done;
        if (frame.variant == .paren) return .done;

        parser.reduce_above(group + 1);
        parser.bump();
        parser.skip_breaks();
        parser.value_count = frame.values;
        parser.frames[group].elements += 1;

        return .operand;
    }

    fn key_value(parser: *Parser, group: u32) Step {
        assert(group < parser.frame_count);
        assert(parser.frames[group].variant == .composite);

        parser.reduce_above(group + 1);

        if (parser.value_count == 0) return .done;

        const values_kept = parser.value_count - 1;
        var frame: Frame = .empty;

        frame.checkpoint = parser.values[values_kept];
        frame.kind = .key_value_expr;
        frame.power = expression.power_barrier;
        frame.values = values_kept;
        frame.variant = .binary;

        if (!parser.push_frame(frame)) return .done;

        parser.bump();
        parser.skip_breaks();

        return .operand;
    }

    fn trailer(parser: *Parser, variant: Variant) Step {
        assert(variant != .top);
        assert(parser.value_count <= expression.value_count_max);

        if (parser.value_count == 0) return .done;

        const checkpoint = parser.values[parser.value_count - 1];

        parser.value_count -= 1;

        return parser.open_group(variant, checkpoint);
    }

    fn holds_a_type(parser: *Parser) bool {
        assert(parser.frame_count <= expression.depth_max);

        var index = parser.frame_count;

        while (index > 0) : (index -= 1) {
            const held = parser.frames[index - 1];
            if (held.variant != .unary) return false;
            if (held.stage == 0) return false;
            if (held.stage == 1) return true;

            assert(held.stage == 2);
        }

        assert(index == 0);

        return false;
    }

    fn drain_types(parser: *Parser, stage: u8) void {
        assert(stage >= 1);
        assert(stage <= 2);

        for (0..expression.depth_max) |_| {
            if (parser.frame_count == 0) return;

            const top = parser.frames[parser.frame_count - 1];
            if (top.variant != .unary) return;
            if (top.stage == 0) return;
            if (top.stage > stage) return;

            parser.reduce_top();
        }
    }

    fn heads_a_clause(parser: *Parser, base: u32) bool {
        assert(base < std.math.maxInt(u32));

        const frame = parser.frames[parser.innermost_group(base)];

        assert(frame.is_group());

        if (frame.variant != .top) return false;

        assert(frame.stage <= context_header);

        return frame.stage == context_header;
    }

    fn structures(parser: *Parser, base: u32) bool {
        assert(base < std.math.maxInt(u32));

        const frame = parser.frames[parser.innermost_group(base)];

        assert(frame.is_group());

        if (frame.variant != .top) return true;

        assert(frame.stage <= context_header);

        return frame.stage == context_expression;
    }

    fn bodies(parser: *Parser, base: u32) bool {
        assert(base < std.math.maxInt(u32));

        const frame = parser.frames[parser.innermost_group(base)];

        assert(frame.is_group());

        if (frame.variant != .top) return true;

        assert(frame.stage <= context_header);

        return frame.stage != context_type;
    }

    fn in_composite(parser: *Parser, base: u32) bool {
        assert(base < std.math.maxInt(u32));

        const frame = parser.frames[parser.innermost_group(base)];

        assert(frame.is_group());
        if (frame.variant == .composite) assert(is_closer(frame.closer));

        return frame.variant == .composite;
    }

    fn innermost_group(parser: *Parser, base: u32) u32 {
        assert(base < parser.frame_count);

        var index = parser.frame_count;

        while (index > base) {
            index -= 1;

            if (parser.frames[index].is_group()) return index;
        }

        assert(index == base);

        return base;
    }

    fn reduce_top(parser: *Parser) void {
        assert(parser.frame_count > 0);

        parser.frame_count -= 1;

        const frame = parser.frames[parser.frame_count];
        const operands = expression.operands_of(frame.variant);

        assert(frame.variant != .top);

        if (parser.value_count < operands + frame.values) parser.record(.expected_type);

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
            const top = parser.frames[parser.frame_count - 1];
            const stopped = top.power == expression.power_barrier or top.power < power_left;

            assert(stopped);
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

        if (parser.value_count >= expression.value_count_max) {
            parser.outcome = .too_deep;

            return;
        }

        parser.values[parser.value_count] = checkpoint;
        parser.value_count += 1;
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

    fn progressed(parser: *const Parser, before: Progress) bool {
        assert(parser.position >= before.position);
        assert(before.position <= parser.count());

        if (parser.position != before.position) return true;
        if (parser.frame_count != before.frame_count) return true;
        return parser.value_count != before.value_count;
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
        assert(is_closer(closer));

        if (iteration.* == parser.steps()) return true;

        iteration.* += 1;

        parser.skip_breaks();

        if (parser.at(closer)) return true;
        return parser.current() == null;
    }

    fn clause_closed(parser: *Parser, iteration: *u32) bool {
        assert(iteration.* <= parser.steps());
        assert(parser.position <= parser.count());

        if (iteration.* == parser.steps()) return true;

        iteration.* += 1;

        parser.skip_breaks();

        const kind = parser.current() orelse return true;

        return switch (kind) {
            .brace_close, .case_keyword, .default_keyword => true,
            else => false,
        };
    }

    fn terminator(parser: *Parser) void {
        assert(parser.position <= parser.count());
        assert(parser.significant_next <= parser.count());

        if (parser.at(.semicolon)) return parser.separate();
        if (parser.eat(.newline)) return;

        const kind = parser.current() orelse return;

        switch (kind) {
            .brace_close, .bracket_close, .paren_close => {},
            else => parser.record(.unexpected_token),
        }
    }

    fn required_identifier(parser: *Parser) void {
        assert(parser.position <= parser.count());

        if (parser.at(.identifier)) {
            parser.identifier();

            return;
        }

        parser.record(.expected_identifier);

        assert(!parser.at(.identifier));
    }

    fn identifier(parser: *Parser) void {
        assert(parser.position <= parser.count());

        if (!parser.at(.identifier)) return;

        const before = parser.position;

        parser.wrap(.ident);

        assert(parser.position > before);
    }

    fn wrap(parser: *Parser, kind: Kind) void {
        assert(kind.is_node());
        assert(parser.current() != null);

        parser.open(kind);
        parser.emit();
        parser.events.finish();
    }

    fn name_list(parser: *Parser) void {
        assert(parser.position <= parser.count());

        for (0..parser.steps()) |_| {
            if (!parser.at(.identifier)) return;

            parser.identifier();

            if (!parser.eat(.comma)) return;
        }
    }

    fn ends_here(parser: *Parser) bool {
        assert(parser.significant_next <= parser.count());

        const kind = parser.current() orelse return true;

        assert(kind.is_token());

        return switch (kind) {
            .newline, .paren_close, .semicolon => true,
            else => false,
        };
    }

    fn opens_a_result(parser: *Parser) bool {
        assert(parser.significant_next <= parser.count());

        const kind = parser.current() orelse return false;

        assert(kind.is_token());

        if (kind == .paren_open) return false;
        return expression.opens_a_type(kind);
    }

    fn fields_are_named(parser: *Parser, closer: Kind) bool {
        assert(is_closer(closer));
        assert(parser.position <= parser.count());

        var position = parser.significant(parser.significant(parser.position) + 1);
        var start = true;

        for (0..scan_step_max) |_| {
            const kind = parser.kind_at(position) orelse return false;
            if (kind == closer) return false;
            if (is_closer(kind)) return false;

            const naming = start and kind == .identifier and parser.names_a_field(position);
            if (naming) return true;

            if (is_opener(kind)) {
                position = parser.balanced_end(position);
                start = false;

                continue;
            }

            start = switch (kind) {
                .comma, .comment, .newline, .semicolon => true,
                else => false,
            };

            position += 1;
        }

        return false;
    }

    fn names_a_field(parser: *Parser, position: u32) bool {
        assert(position < parser.count());
        assert(parser.kind_at(position) == .identifier);

        const after = parser.significant(position + 1);
        const next = parser.kind_at(after) orelse return false;

        if (next == .bracket_open) {
            const held = parser.significant(parser.balanced_end(after));
            const kind = parser.kind_at(held) orelse return false;

            return expression.opens_a_type(kind) or kind == .string_literal;
        }

        if (next == .comma) return false;
        return expression.opens_a_type(next) or next == .string_literal;
    }

    fn embeds(parser: *Parser) bool {
        assert(parser.at(.identifier));

        const position = parser.significant(parser.position);

        assert(position < parser.count());

        if (parser.names_a_field(position)) return false;
        return parser.kind_at(parser.significant(position + 1)) != .comma;
    }

    fn opens_type_parameters(parser: *Parser) bool {
        assert(parser.at(.bracket_open));

        const opener = parser.significant(parser.position);
        const after = parser.significant(opener + 1);

        assert(opener < parser.count());

        if (parser.kind_at(after) != .identifier) return false;

        const next = parser.kind_at(parser.significant(after + 1));
        if (next == .bracket_close) return false;
        if (parser.holds_a_separator(opener)) return true;

        const kind = next orelse return false;

        return switch (kind) {
            .paren_open, .star => parser.holds_a_type_element(opener),
            .arrow,
            .bracket_open,
            .chan_keyword,
            .func_keyword,
            .identifier,
            .interface_keyword,
            .map_keyword,
            .struct_keyword,
            .tilde,
            => true,
            else => false,
        };
    }

    fn holds_a_type_element(parser: *Parser, from: u32) bool {
        assert(parser.kind_at(from) == .bracket_open);

        const stop = parser.balanced_end(from);

        assert(stop > from);
        assert(stop <= parser.count());

        for (parser.raw[from + 1 .. stop]) |kind| {
            switch (kind) {
                .chan_keyword,
                .func_keyword,
                .interface_keyword,
                .map_keyword,
                .struct_keyword,
                .tilde,
                => return true,
                else => {},
            }
        }

        return false;
    }

    fn holds_a_separator(parser: *Parser, from: u32) bool {
        assert(parser.kind_at(from) == .bracket_open);

        const stop = parser.balanced_end(from);
        var position = from + 1;

        assert(stop > from);

        for (0..scan_step_max) |_| {
            if (position >= stop) return false;

            const kind = parser.kind_at(position) orelse return false;
            if (kind == .comma) return true;

            if (is_opener(kind)) {
                position = parser.balanced_end(position);

                continue;
            }

            position += 1;
        }

        return false;
    }

    fn header_semicolon(parser: *Parser) bool {
        assert(parser.position <= parser.count());
        assert(parser.task_count > 0);

        return parser.header_holds(.semicolon);
    }

    fn header_holds(parser: *Parser, held: Kind) bool {
        assert(held.is_token());
        assert(parser.position <= parser.count());

        var scan: HeaderScan = .{ .position = parser.significant(parser.position) };

        for (0..scan_step_max) |_| {
            const kind = parser.kind_at(scan.position) orelse return false;

            switch (parser.header_step(&scan, kind, held)) {
                .holds => return true,
                .lacks => return false,
                .next => {},
            }
        }

        return false;
    }

    fn header_step(parser: *Parser, scan: *HeaderScan, kind: Kind, held: Kind) HeaderStep {
        assert(scan.position < parser.count());
        assert(parser.kind_at(scan.position) == kind);
        assert(held.is_token());

        if (kind == .brace_open) {
            const literal = scan.typed or scan.kind_last == .interface_keyword or
                scan.kind_last == .struct_keyword;

            if (!literal) {
                if (scan.functions == 0) return .lacks;

                scan.functions -= 1;
            }

            scan.position = parser.balanced_end(scan.position);
            scan.kind_last = .brace_close;
            scan.typed = false;

            return .next;
        }

        if (kind == .func_keyword) scan.functions += 1;

        if (is_opener(kind)) {
            if (parser.kind_at(parser.significant(scan.position + 1)) == held) return .holds;

            if (kind == .bracket_open) {
                if (!ends_operand(scan.kind_last)) scan.typed = true;
            }

            scan.position = parser.balanced_end(scan.position);
            scan.kind_last = .paren_close;

            return .next;
        }

        if (is_closer(kind)) return .lacks;
        if (kind == held) return .holds;

        if (kind == .chan_keyword) scan.typed = true;
        if (kind == .map_keyword) scan.typed = true;
        if (kind != .comment) scan.kind_last = kind;

        scan.position += 1;

        return .next;
    }

    fn range_variables(parser: *Parser) u32 {
        assert(parser.position <= parser.count());

        var position = parser.significant(parser.position);
        var found: u32 = 1;

        for (0..scan_step_max) |_| {
            const kind = parser.kind_at(position) orelse return found;

            if (kind == .comma) {
                found += 1;
                position += 1;

                continue;
            }

            const stops = expression.assigns(kind) or kind == .range_keyword or is_closer(kind);
            if (stops) return found;

            if (is_opener(kind)) {
                position = parser.balanced_end(position);

                continue;
            }

            position += 1;
        }

        assert(found >= 1);

        return found;
    }

    fn wraps(parser: *Parser, head: u32, end: u32) bool {
        assert(head <= end);
        assert(end <= parser.count());

        if (parser.kind_at(head) != .paren_open) return false;
        return parser.significant(parser.balanced_end(head)) == end;
    }

    fn preceding(parser: *Parser, from: u32) ?Kind {
        assert(from <= parser.count());

        var position = from;

        while (position > 0) {
            position -= 1;

            const kind = parser.raw[position];
            if (!is_layout(kind)) return kind;
        }

        assert(position == 0);

        return null;
    }

    fn balanced_end(parser: *Parser, from: u32) u32 {
        assert(from < parser.count());
        assert(is_opener(parser.raw[from]));

        var position = from;
        var depth: u32 = 0;

        for (0..scan_step_max) |_| {
            const kind = parser.kind_at(position) orelse return position;

            if (is_opener(kind)) depth += 1;

            if (is_closer(kind)) {
                assert(depth > 0);

                depth -= 1;

                if (depth == 0) {
                    assert(position + 1 <= parser.tokens.len);

                    return position + 1;
                }
            }

            position += 1;
        }

        assert(position > from);

        return position;
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
            if (parser.raw[parser.position] != .comment) break;

            parser.emit();
        }

        assert(parser.position == parser.significant_next);
    }

    fn skip_breaks(parser: *Parser) void {
        assert(parser.position <= parser.count());

        for (parser.position..parser.raw.len) |_| {
            const kind = parser.raw[parser.position];
            const breaks = kind == .comment or kind == .newline;
            if (!breaks) break;

            parser.emit();
        }

        if (parser.position < parser.count()) assert(!is_layout(parser.raw[parser.position]));
    }

    fn emit(parser: *Parser) void {
        assert(parser.position <= parser.count());

        const kind = parser.kind_at(parser.position) orelse return;

        if (kind == .identifier) {
            if (!parser.name_is_lettered(parser.position)) parser.record(.expected_identifier);
        }

        if (is_layout(kind)) {
            parser.events.layout(parser.position);
        } else {
            parser.events.token(parser.position);
        }

        parser.position_advance();
    }

    fn separate(parser: *Parser) void {
        parser.skip_trivia();

        assert(parser.at(.semicolon));

        parser.events.layout(parser.position);
        parser.position_advance();
    }

    fn position_advance(parser: *Parser) void {
        assert(parser.position < parser.count());

        parser.position += 1;

        if (parser.position > parser.significant_next) {
            parser.significant_next = parser.significant_scan(parser.position);
        }

        assert(parser.significant_next >= parser.position);
        assert(parser.significant_next <= parser.count());
    }

    fn name_is_lettered(parser: *Parser, position: u32) bool {
        assert(position < parser.tokens.len);
        assert(parser.raw[position] == .identifier);

        const text = parser.tokens[position].text(parser.source);
        if (is_ascii(text)) return true;
        if (!std.unicode.utf8ValidateSlice(text)) return false;

        var scalars = std.unicode.Utf8View.initUnchecked(text).iterator();

        for (0..text.len) |_| {
            const scalar = scalars.nextCodepoint() orelse return true;
            if (!scalar_is_lettered(scalar)) return false;
        }

        return true;
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
        assert(from <= parser.count() + 2);

        if (from == parser.position) return parser.significant_next;
        return parser.significant_scan(from);
    }

    fn significant_scan(parser: *Parser, from: u32) u32 {
        assert(from < std.math.maxInt(u32));

        var position = from;

        while (position < parser.raw.len) : (position += 1) {
            if (parser.raw[position] != .comment) break;
        }

        assert(position >= from);
        if (position < parser.raw.len) assert(parser.raw[position] != .comment);

        return position;
    }

    fn kind_at(parser: *Parser, position: u32) ?Kind {
        assert(parser.raw.len == parser.tokens.len);

        if (position >= parser.raw.len) return null;
        return parser.raw[position];
    }

    fn count(parser: *const Parser) u32 {
        assert(parser.raw.len < std.math.maxInt(u32));

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

const Progress = struct {
    frame_count: u32,
    position: u32,
    value_count: u32,
};

const HeaderScan = struct {
    position: u32,
    kind_last: Kind = .error_token,
    functions: u32 = 0,
    typed: bool = false,
};

const HeaderStep = enum {
    holds,
    lacks,
    next,
};

const Task = union(enum) {
    array: Array,
    block: Block,
    clause: Clause,
    clause_block: ClauseBlock,
    declaration: Declaration,
    expression: Expression,
    expression_list: ExpressionList,
    field: Field,
    field_list: FieldList,
    for_statement: ForStatement,
    function_declaration: FunctionDeclaration,
    function_literal: FunctionLiteral,
    general_declaration: GeneralDeclaration,
    if_statement: IfStatement,
    map: Map,
    range_statement: RangeStatement,
    signature: Signature,
    simple_statement: SimpleStatement,
    statement: Statement,
    switch_statement: SwitchStatement,
    type_assertion: TypeAssertion,
    type_body: TypeBody,
    type_specification: TypeSpecification,
    value_specification: ValueSpecification,
    wrapped_statement: WrappedStatement,
};

const Array = struct {
    stage: enum { start, length } = .start,
    checkpoint: ?Checkpoint = null,
};

const Block = struct {
    stage: enum { start, statements, statement } = .start,
    before: u32 = 0,
    iteration: u32 = 0,
};

const Clause = struct {
    stage: enum { start, head, statements, statement } = .start,
    kind: Kind,
    before: u32 = 0,
    iteration: u32 = 0,
};

const ClauseBlock = struct {
    stage: enum { start, clauses, clause } = .start,
    kind: Kind,
    before: u32 = 0,
    iteration: u32 = 0,
};

const Declaration = struct {
    stage: enum { start, function, general } = .start,
};

const Expression = struct {
    stage: enum { start, machine, stepped, fallback, checked, finished } = .start,
    context: u8,
    frames_base: u32 = 0,
    values_base: u32 = 0,
    operand: bool = true,
    before: Progress = .{ .frame_count = 0, .position = 0, .value_count = 0 },
    iteration: u32 = 0,
};

const ExpressionList = struct {
    stage: enum { start, expression } = .start,
    context: u8,
    before: u32 = 0,
    iteration: u32 = 0,
};

const Field = struct {
    stage: enum { start, parameters, signature, typed } = .start,
    held: ?Checkpoint = null,
    methods: bool,
    written: bool,
};

const FieldList = struct {
    stage: enum { start, fields, field } = .start,
    opener: Kind,
    closer: Kind = .paren_close,
    methods: bool,
    named: bool = false,
    written: bool = false,
    before: u32 = 0,
    iteration: u32 = 0,
};

const ForStatement = struct {
    stage: enum { start, initialized, conditioned, header, body } = .start,
};

const FunctionDeclaration = struct {
    stage: enum { start, receiver, parameters, signature, body } = .start,
    checkpoint: ?Checkpoint = null,
    received: bool = false,
};

const FunctionLiteral = struct {
    stage: enum { start, signature, body } = .start,
    checkpoint: ?Checkpoint = null,
    structured: bool,
};

const GeneralDeclaration = struct {
    stage: enum { start, single, specifications, specification } = .start,
    keyword: Kind = .error_token,
    before: u32 = 0,
    iteration: u32 = 0,
};

const IfStatement = struct {
    stage: enum { arm, initialized, condition, body, chained, otherwise, closed } = .arm,
    opened: u32 = 0,
    iteration: u32 = 0,
};

const Map = struct {
    stage: enum { start, key } = .start,
    checkpoint: ?Checkpoint = null,
};

const RangeStatement = struct {
    stage: enum { start, variables, subject, header, body } = .start,
};

const Signature = struct {
    stage: enum { start, parameters, results, result } = .start,
    checkpoint: ?Checkpoint = null,
};

const SimpleStatement = struct {
    stage: enum { start, left, right } = .start,
    context: u8,
    checkpoint: ?Checkpoint = null,
    node: Kind = .expr_stmt,
};

const Statement = struct {
    stage: enum {
        start,
        block,
        declaration,
        results,
        selected,
        labeled,
        simple,
        delegated,
    } = .start,
    checkpoint: ?Checkpoint = null,
};

const SwitchStatement = struct {
    stage: enum { start, initialized, subject, header, body } = .start,
    typed: bool = false,
};

const TypeAssertion = struct {
    stage: enum { start, typed } = .start,
    checkpoint: Checkpoint,
};

const TypeBody = struct {
    stage: enum { start, body } = .start,
    checkpoint: ?Checkpoint = null,
    kind: Kind,
};

const TypeSpecification = struct {
    stage: enum { start, parameters, typed } = .start,
    before: u32 = 0,
};

const ValueSpecification = struct {
    stage: enum { start, typed, valued } = .start,
    keyword: Kind,
    typed: bool = false,
    valued: bool = false,
};

const WrappedStatement = struct {
    stage: enum { start, expression } = .start,
    kind: Kind,
    head: u32 = 0,
};

const nest_depth_max: u32 = 96;
const task_chain_max: u32 = 7;
const task_count_max: u32 = (nest_depth_max + 1) * task_chain_max;
const scan_step_max: u32 = 1 << 16;
const declaration_iteration_max: u32 = std.math.maxInt(u32);
const machine_step_max: u32 = std.math.maxInt(u32);
const resume_count_max: u64 = std.math.maxInt(u32);
const context_type: u8 = 0;
const context_expression: u8 = 1;
const context_header: u8 = 2;

comptime {
    assert(task_count_max > nest_depth_max);
    assert(context_type < context_expression);
    assert(context_expression < context_header);
    assert(expression.value_count_max > expression.depth_max);
}

fn expression_of(context: u8) Task {
    assert(context <= context_header);

    return .{ .expression = .{ .context = context } };
}

fn expression_list_of(context: u8) Task {
    assert(context <= context_header);
    assert(context != context_type);

    return .{ .expression_list = .{ .context = context } };
}

fn simple_statement_of(context: u8) Task {
    assert(context <= context_header);
    assert(context != context_type);

    return .{ .simple_statement = .{ .context = context } };
}

fn closer_of(opener: Kind) Kind {
    assert(opener.is_token());

    const closer: Kind = switch (opener) {
        .bracket_open => .bracket_close,
        .brace_open => .brace_close,
        else => .paren_close,
    };

    assert(is_closer(closer));

    return closer;
}

fn index_kind_of(frame: *const Frame) Kind {
    assert(frame.variant == .index);
    assert(frame.stage <= 1);

    if (frame.stage == 1) return .slice_expr;
    if (frame.elements > 0) return .index_list_expr;
    return .index_expr;
}

fn is_layout(kind: Kind) bool {
    assert(kind.is_token());

    return kind == .comment or kind == .newline;
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

fn ends_operand(kind: Kind) bool {
    assert(kind.is_token());

    return switch (kind) {
        .brace_close,
        .bracket_close,
        .identifier,
        .number,
        .paren_close,
        .rune_literal,
        .string_literal,
        => true,
        else => false,
    };
}

fn is_ascii(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    for (text) |byte| {
        if (byte >= 0x80) return false;
    }

    return true;
}

fn scalar_is_lettered(scalar: u21) bool {
    assert(scalar <= 0x10ffff);

    if (scalar == '_') return true;
    if (scalar < 0x80) return std.ascii.isAlphanumeric(@intCast(scalar));
    return unicode.is_alphanumeric(scalar);
}

fn tokens_unterminated(
    source: []const u8,
    tokens: []const Token,
    raw: []const Kind,
    tree: *Tree,
) bool {
    assert(tokens.len == raw.len);
    assert(source.len <= std.math.maxInt(u32));

    var truncated = false;

    for (raw, tokens) |kind, token| {
        if (terminated(kind, token.text(source))) continue;

        const unclosed: Diagnostic = .{
            .expected = null,
            .found = kind.to_u16(),
            .kind = .unexpected_token,
            .span = token.span(),
        };

        tree.push_diagnostic(unclosed) catch |err| {
            switch (err) {
                error.Truncated => truncated = true,
            }
        };
    }

    return truncated;
}

fn terminated(kind: Kind, text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));
    assert(kind.is_token());

    return switch (kind) {
        .comment => comment_terminated(text),
        .rune_literal, .string_literal => string_is_terminated(text, raw_quoted(text)),
        else => true,
    };
}

fn comment_terminated(text: []const u8) bool {
    if (!std.mem.startsWith(u8, text, "/*")) return true;
    if (text.len < 4) return false;
    return std.mem.endsWith(u8, text, "*/");
}

fn raw_quoted(text: []const u8) Quoting {
    assert(text.len <= std.math.maxInt(u32));

    if (std.mem.startsWith(u8, text, "`")) return .raw;
    return .escaped;
}
