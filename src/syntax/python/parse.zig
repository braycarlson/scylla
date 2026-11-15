const std = @import("std");
const assert = std.debug.assert;
const Checkpoint = @import("../tree.zig").Checkpoint;
const EventsType = @import("../tree.zig").EventsType;
const Kind = @import("kind.zig").Kind;
const Span = @import("../../stdx/bounded/span.zig");
const Structure = @import("../tree.zig").Structure;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const Token = @import("../token.zig");
const Tokens = @import("../tokens.zig");
const TreeType = @import("../tree.zig").TreeType;
const raw_of = @import("../raw.zig").raw_of;
const escape = @import("escape.zig");
const expression = @import("expression.zig");
const lex = @import("lex.zig").lex;
const frame_depth_max = @import("../tree.zig").frame_depth_max;

const Part = enum {
    bytes,
    template,
    text,
};

const Runs = struct {
    bytes: u64,
    mixed: u64,
    raws: u64,
    template: u64,
    text: u64,

    const empty: Runs = .{ .bytes = 0, .mixed = 0, .raws = 0, .template = 0, .text = 0 };

    fn clear(runs: *Runs, bit: u64) void {
        assert(@popCount(bit) == 1);

        runs.bytes &= ~bit;
        runs.mixed &= ~bit;
        runs.template &= ~bit;
        runs.text &= ~bit;
    }

    fn joins(runs: *Runs, bit: u64, part: Part) bool {
        assert(@popCount(bit) == 1);

        const others = switch (part) {
            .bytes => runs.template | runs.text,
            .template => runs.bytes | runs.text,
            .text => runs.bytes | runs.template,
        };

        switch (part) {
            .bytes => runs.bytes |= bit,
            .template => runs.template |= bit,
            .text => runs.text |= bit,
        }

        if (others & bit == 0) return false;
        if (runs.mixed & bit != 0) return false;

        runs.mixed |= bit;

        return true;
    }
};

const Events = EventsType(Kind);
const Frame = expression.Frame;
const Signature = expression.Signature;
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

        parser.events = events;
        parser.frame_count = 0;
        parser.nesting = 0;
        parser.outcome = .complete;
        parser.position = 0;
        parser.raw = raw;
        parser.source = source;
        parser.task_count = 0;
        parser.tokens = tokens;
        parser.tree = tree;
        parser.value_count = 0;
        parser.significant_next = parser.significant_scan(0);

        parser.run();
        parser.literals();

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

    fn run(parser: *Parser) void {
        assert(parser.position == 0);
        assert(parser.task_count == 0);

        parser.events.start(.module);

        for (0..parser.steps()) |_| {
            if (parser.position >= parser.count()) break;

            const before = parser.position;

            parser.drive(.{ .statements = .{} });

            if (parser.position == before) parser.emit();

            assert(parser.position > before);
            assert(parser.nesting == 0);
        }

        assert(parser.position == parser.count());

        parser.events.finish();
    }

    fn drive(parser: *Parser, task: Task) void {
        assert(parser.task_count == 0);
        assert(task == .statements);

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
            .block => |*state| parser.block_resume(state),
            .compound => |*state| parser.compound_resume(state),
            .else_clause => |*state| parser.else_clause_resume(state),
            .if_statement => |*state| parser.if_resume(state),
            .match_statement => |*state| parser.match_resume(state),
            .statements => |*state| parser.statements_resume(state),
            .try_statement => |*state| parser.try_resume(state),
        };
    }

    fn statements_resume(parser: *Parser, state: *Statements) Resumed {
        if (state.stage == .statement) assert(state.before <= parser.position);

        if (state.stage == .statement) {
            if (parser.position == state.before) parser.emit();

            state.stage = .loop;
        }

        while (parser.position < parser.count()) {
            state.iteration += 1;

            assert(state.iteration <= parser.steps());

            const before = parser.position;

            parser.skip_trivia();

            const kind = parser.current() orelse break;
            if (kind == .dedent) break;

            if (kind == .newline) {
                parser.bump();

                continue;
            }

            if (parser.statement_open(kind)) |task| {
                state.before = before;
                state.stage = .statement;

                return parser.call(task);
            }

            if (parser.position == before) parser.emit();
        }

        return .returned;
    }

    fn statement_open(parser: *Parser, kind: Kind) ?Task {
        assert(kind.is_token());
        assert(parser.current() == kind);

        switch (kind) {
            .at => return parser.decorated(),
            .async_keyword => return parser.asynchronous(),
            .class_keyword => return compound_of(.class_def),
            .def_keyword => return compound_of(.function_def),
            .for_keyword => return compound_of(.@"for"),
            .if_keyword => return .{ .if_statement = .{} },
            .indent => {
                parser.record(.unexpected_indent);
                parser.recover();

                return null;
            },
            .try_keyword => return .{ .try_statement = .{} },
            .while_keyword => return compound_of(.@"while"),
            .with_keyword => return compound_of(.with),
            else => {},
        }

        if (parser.is_match_header()) return .{ .match_statement = .{} };

        if (parser.is_type_alias()) {
            parser.type_alias();

            return null;
        }

        parser.simple_line();

        return null;
    }

    fn decorated(parser: *Parser) ?Task {
        assert(parser.at(.at));
        assert(parser.frame_count == 0);

        for (0..parser.steps()) |_| {
            if (!parser.at(.at)) break;

            parser.events.start(.decorator);
            parser.bump();
            parser.expression_with(options_named);
            _ = parser.eat(.newline);

            parser.events.finish();
            parser.skip_trivia();
        }

        const kind = parser.current() orelse .error_token;

        switch (kind) {
            .async_keyword => return compound_of(.async_function_def),
            .class_keyword => return compound_of(.class_def),
            .def_keyword => return compound_of(.function_def),
            else => {
                parser.record(.unexpected_token);
                parser.recover();

                return null;
            },
        }
    }

    fn asynchronous(parser: *Parser) ?Task {
        assert(parser.at(.async_keyword));
        assert(parser.frame_count == 0);

        const next = parser.ahead(1) orelse .error_token;

        switch (next) {
            .def_keyword => return compound_of(.async_function_def),
            .for_keyword => return compound_of(.async_for),
            .with_keyword => return compound_of(.async_with),
            else => {
                parser.simple_line();

                return null;
            },
        }
    }

    fn compound_resume(parser: *Parser, state: *Compound) Resumed {
        assert(state.kind.is_node());
        assert(parser.frame_count == 0);

        switch (state.stage) {
            .start => {
                parser.events.start(state.kind);
                parser.compound_header(state.kind);
                state.stage = .body;

                return parser.call(.{ .block = .{} });
            },
            .body => {
                if (has_else(state.kind)) {
                    state.stage = .alternate;

                    return parser.call(.{ .else_clause = .{} });
                }
            },
            .alternate => assert(has_else(state.kind)),
        }

        parser.events.finish();

        return .returned;
    }

    fn compound_header(parser: *Parser, kind: Kind) void {
        assert(kind.is_node());
        assert(parser.frame_count == 0);

        switch (kind) {
            .async_for, .async_function_def, .async_with => parser.bump(),
            else => {},
        }

        switch (kind) {
            .class_def => parser.class_header(),
            .async_function_def, .function_def => parser.definition_header(),
            .async_for, .@"for" => parser.for_header(),
            .async_with, .with => parser.with_header(),
            .@"while" => {
                parser.bump();
                parser.expression_with(options_named);
            },
            else => unreachable,
        }
    }

    fn class_header(parser: *Parser) void {
        assert(parser.at(.class_keyword));
        assert(parser.frame_count == 0);

        parser.bump();
        parser.expect(.identifier, .expected_identifier);
        parser.type_parameters();

        if (parser.at(.paren_open)) parser.argument_list();
    }

    fn definition_header(parser: *Parser) void {
        assert(parser.frame_count == 0);
        assert(parser.value_count == 0);

        parser.bump();
        parser.expect(.identifier, .expected_identifier);
        parser.type_parameters();
        parser.parameters();

        if (parser.eat(.arrow)) parser.expression_with(options_single);
    }

    fn for_header(parser: *Parser) void {
        assert(parser.frame_count == 0);
        assert(parser.value_count == 0);

        parser.bump();
        parser.expression_with(options_target);
        parser.expect(.in_keyword, .expected_in);
        parser.expression_with(options_tuple);
    }

    fn with_header(parser: *Parser) void {
        assert(parser.frame_count == 0);
        assert(parser.value_count == 0);

        parser.bump();

        const parenthesized = parser.at(.paren_open) and parser.with_is_parenthesized();

        if (parenthesized) parser.bump();

        for (0..parser.steps()) |_| {
            parser.events.start(.with_item);
            parser.expression_with(options_single);

            if (parser.eat(.as_keyword)) parser.expression_with(options_starred);

            parser.events.finish();

            if (!parser.eat(.comma)) break;

            if (parenthesized) {
                if (parser.at(.paren_close)) break;
            }
        }

        if (parenthesized) _ = parser.eat(.paren_close);
    }

    fn block_resume(parser: *Parser, state: *Block) Resumed {
        assert(parser.frame_count == 0);
        if (state.stage == .statements) assert(parser.nesting > 0);

        switch (state.stage) {
            .start => {
                parser.expect(.colon, .expected_colon);

                if (!parser.at(.newline)) {
                    parser.events.start(.block);
                    parser.simple_line();
                    parser.events.finish();

                    return .returned;
                }

                parser.bump();

                if (!parser.at(.indent)) {
                    parser.record(.expected_block);

                    return .returned;
                }

                parser.events.start(.block);
                parser.bump();

                if (parser.descend()) {
                    state.stage = .statements;

                    return parser.call(.{ .statements = .{} });
                }
            },
            .statements => parser.ascend(),
        }

        if (!parser.eat(.dedent)) parser.record(.unexpected_dedent);

        parser.events.finish();

        return .returned;
    }

    fn else_clause_resume(parser: *Parser, state: *ElseClause) Resumed {
        assert(parser.frame_count == 0);
        assert(parser.value_count == 0);

        switch (state.stage) {
            .start => {
                parser.skip_trivia();

                if (!parser.at(.else_keyword)) return .returned;

                parser.events.start(.else_clause);
                parser.bump();
                state.stage = .body;

                return parser.call(.{ .block = .{} });
            },
            .body => parser.events.finish(),
        }

        return .returned;
    }

    fn if_resume(parser: *Parser, state: *If) Resumed {
        assert(state.opened <= parser.steps());
        assert(parser.frame_count == 0);

        switch (state.stage) {
            .start => {
                parser.events.start(.@"if");
                parser.bump();
                parser.expression_with(options_named);
                state.stage = .branch;

                return parser.call(.{ .block = .{} });
            },
            .branch => {
                parser.skip_trivia();

                const elif = parser.at(.elif_keyword) and state.opened < parser.steps();

                if (elif) {
                    parser.events.start(.else_clause);
                    parser.events.start(.@"if");
                    parser.bump();
                    parser.expression_with(options_named);
                    state.opened += 1;

                    return parser.call(.{ .block = .{} });
                }

                state.stage = .alternate;

                return parser.call(.{ .else_clause = .{} });
            },
            .alternate => {
                for (0..state.opened) |_| {
                    parser.events.finish();
                    parser.events.finish();
                }

                parser.events.finish();

                return .returned;
            },
        }
    }

    fn try_resume(parser: *Parser, state: *Try) Resumed {
        assert(parser.frame_count == 0);

        stage: switch (state.stage) {
            .start => {
                state.checkpoint = parser.anchor();

                parser.bump();
                state.stage = .handlers;

                return parser.call(.{ .block = .{} });
            },
            .handler => {
                parser.events.finish();

                continue :stage .handlers;
            },
            .handlers => {
                parser.skip_trivia();

                if (parser.at(.except_keyword)) {
                    state.iteration += 1;

                    assert(state.iteration <= parser.steps());

                    parser.except_header(state);
                    state.stage = .handler;

                    return parser.call(.{ .block = .{} });
                }

                if (state.iteration == 0) {
                    if (parser.at(.else_keyword)) parser.record(.unexpected_token);
                }

                state.stage = .alternate;

                return parser.call(.{ .else_clause = .{} });
            },
            .alternate => {
                parser.skip_trivia();

                if (parser.at(.finally_keyword)) {
                    parser.events.start(.finally_clause);
                    parser.bump();
                    state.stage = .finally;

                    return parser.call(.{ .block = .{} });
                }

                if (state.iteration == 0) parser.record(.unexpected_token);
            },
            .finally => parser.events.finish(),
        }

        const kind: Kind = if (state.starred) .try_star else .@"try";

        parser.enclose(state.checkpoint.?, kind);

        return .returned;
    }

    fn except_header(parser: *Parser, state: *Try) void {
        assert(parser.at(.except_keyword));
        assert(state.checkpoint != null);

        parser.events.start(.except_handler);
        parser.bump();

        const starred = parser.eat(.star);

        if (starred) state.starred = true else state.plain = true;

        if (state.starred) {
            if (state.plain) parser.record(.unexpected_token);
        }

        if (parser.at(.colon)) {
            if (starred) parser.record(.unexpected_token);

            return;
        }

        const held = parser.anchor();

        parser.expression_with(options_single);
        parser.except_tuple(held);

        if (parser.eat(.as_keyword)) _ = parser.eat(.identifier);
    }

    fn except_tuple(parser: *Parser, checkpoint: Checkpoint) void {
        assert(parser.frame_count == 0);
        assert(checkpoint.index <= parser.events.count());

        if (!parser.at(.comma)) return;

        for (0..parser.steps()) |_| {
            if (!parser.eat(.comma)) break;
            if (parser.at(.as_keyword)) break;
            if (parser.at(.colon)) break;

            const before = parser.position;

            parser.expression_with(options_single);

            if (parser.position == before) break;
        }

        parser.enclose(checkpoint, .tuple);
    }

    fn match_resume(parser: *Parser, state: *Match) Resumed {
        assert(state.iteration <= parser.steps());
        assert(parser.frame_count == 0);

        switch (state.stage) {
            .start => {
                parser.events.start(.match);
                parser.bump();
                parser.expression_with(options_subject);
                parser.expect(.colon, .expected_colon);

                if (!parser.at(.newline)) {
                    parser.events.finish();

                    return .returned;
                }

                parser.bump();

                if (!parser.eat(.indent)) {
                    parser.events.finish();

                    return .returned;
                }
            },
            .case => parser.events.finish(),
        }

        if (parser.match_case_open(state)) {
            state.stage = .case;

            return parser.call(.{ .block = .{} });
        }

        _ = parser.eat(.dedent);

        parser.events.finish();

        return .returned;
    }

    fn match_case_open(parser: *Parser, state: *Match) bool {
        assert(parser.frame_count == 0);

        while (parser.position < parser.count()) {
            state.iteration += 1;

            assert(state.iteration <= parser.steps());

            parser.skip_trivia();

            if (parser.at(.newline)) {
                parser.bump();

                continue;
            }

            if (!parser.soft_header("case")) return false;

            parser.events.start(.match_case);
            parser.bump();
            parser.pattern();

            return true;
        }

        return false;
    }

    fn simple_line(parser: *Parser) void {
        assert(parser.frame_count == 0);
        assert(parser.value_count == 0);

        for (0..parser.steps()) |_| {
            const before = parser.position;

            parser.simple_statement();

            if (parser.position == before) parser.record(.unexpected_token);

            if (!parser.eat(.semicolon)) break;

            parser.skip_trivia();

            const kind = parser.current() orelse break;
            if (kind == .newline) break;
            if (parser.position == before) break;
        }

        parser.line_terminator();
        _ = parser.eat(.newline);
    }

    fn line_terminator(parser: *Parser) void {
        assert(parser.position <= parser.count());

        const kind = parser.current() orelse return;

        assert(kind.is_token());

        switch (kind) {
            .dedent, .newline => {},
            else => parser.record(.unexpected_token),
        }
    }

    fn simple_statement(parser: *Parser) void {
        assert(parser.frame_count == 0);

        const kind = parser.current() orelse return;

        assert(kind.is_token());

        switch (kind) {
            .assert_keyword => parser.assert_statement(),
            .break_keyword => parser.wrap(.@"break"),
            .continue_keyword => parser.wrap(.@"continue"),
            .del_keyword => parser.delete_statement(),
            .from_keyword => parser.import_from(),
            .global_keyword => parser.names_statement(.global),
            .import_keyword => parser.import_statement(),
            .nonlocal_keyword => parser.names_statement(.nonlocal),
            .pass_keyword => parser.wrap(.pass),
            .raise_keyword => parser.raise_statement(),
            .return_keyword => parser.return_statement(),
            else => parser.assignment(),
        }
    }

    fn assert_statement(parser: *Parser) void {
        assert(parser.at(.assert_keyword));
        assert(parser.frame_count == 0);

        parser.events.start(.assert);
        parser.bump();
        parser.expression_with(options_single);

        if (parser.eat(.comma)) parser.expression_with(options_single);

        parser.events.finish();
    }

    fn delete_statement(parser: *Parser) void {
        assert(parser.at(.del_keyword));
        assert(parser.frame_count == 0);

        parser.events.start(.delete);
        parser.bump();

        for (0..parser.steps()) |_| {
            parser.expression_with(options_single);

            if (!parser.eat(.comma)) break;
            if (parser.ends_statement()) break;
        }

        parser.events.finish();
    }

    fn ends_statement(parser: *Parser) bool {
        assert(parser.position <= parser.count());

        const kind = parser.current() orelse return true;
        return kind == .newline or kind == .semicolon;
    }

    fn names_statement(parser: *Parser, kind: Kind) void {
        assert(kind == .global or kind == .nonlocal);
        assert(parser.frame_count == 0);

        parser.events.start(kind);
        parser.bump();

        for (0..parser.steps()) |_| {
            parser.expect(.identifier, .expected_identifier);

            if (!parser.eat(.comma)) break;
        }

        parser.events.finish();
    }

    fn import_statement(parser: *Parser) void {
        assert(parser.at(.import_keyword));
        assert(parser.frame_count == 0);

        parser.events.start(.import);
        parser.bump();
        parser.alias_list(.dotted);
        parser.events.finish();
    }

    fn import_from(parser: *Parser) void {
        assert(parser.at(.from_keyword));
        assert(parser.frame_count == 0);

        parser.events.start(.import_from);
        parser.bump();

        for (0..parser.steps()) |_| {
            const kind = parser.current() orelse break;

            switch (kind) {
                .dot, .ellipsis, .identifier => parser.bump(),
                else => break,
            }
        }

        parser.expect(.import_keyword, .expected_import);

        const parenthesized = parser.eat(.paren_open);

        parser.alias_list(if (parenthesized) .enclosed else .bare);

        if (parenthesized) _ = parser.eat(.paren_close);

        parser.events.finish();
    }

    fn alias_list(parser: *Parser, form: AliasForm) void {
        assert(parser.frame_count == 0);
        assert(parser.position <= parser.count());

        var produced = false;
        defer if (!produced) parser.record(.expected_identifier);

        for (0..parser.steps()) |index| {
            parser.skip_trivia();

            const kind = parser.current() orelse break;

            if (kind != .identifier) {
                if (kind != .star) break;

                const lone = form == .bare and index == 0;

                if (!lone) parser.record(.unexpected_token);
            }

            produced = true;

            parser.events.start(.alias);
            parser.bump();

            for (0..parser.steps()) |_| {
                if (!parser.at(.dot)) break;

                if (form != .dotted) parser.record(.unexpected_token);

                parser.bump();
                _ = parser.eat(.identifier);
            }

            if (parser.eat(.as_keyword)) _ = parser.eat(.identifier);

            parser.events.finish();

            if (kind == .star) {
                if (parser.at(.comma)) parser.record(.unexpected_token);
            }

            if (!parser.eat(.comma)) break;

            if (form != .enclosed) {
                if (parser.ends_statement()) {
                    parser.record(.unexpected_token);

                    break;
                }
            }
        }
    }

    fn raise_statement(parser: *Parser) void {
        assert(parser.at(.raise_keyword));
        assert(parser.frame_count == 0);

        parser.events.start(.raise);
        parser.bump();

        if (parser.continues_line()) {
            parser.expression_with(options_single);

            if (parser.eat(.from_keyword)) parser.expression_with(options_single);
        }

        parser.events.finish();
    }

    fn return_statement(parser: *Parser) void {
        assert(parser.at(.return_keyword));
        assert(parser.frame_count == 0);

        parser.events.start(.@"return");
        parser.bump();

        if (parser.continues_line()) parser.expression_with(options_tuple);

        parser.events.finish();
    }

    fn continues_line(parser: *Parser) bool {
        assert(parser.position <= parser.count());

        const kind = parser.current() orelse return false;

        assert(kind.is_token());

        return kind != .newline;
    }

    fn assignment(parser: *Parser) void {
        assert(parser.frame_count == 0);
        assert(parser.value_count == 0);

        const outline = parser.shape();
        const assign = outline.assign orelse position_none;

        if (outline.augmented) |augmented| {
            if (assign > augmented) {
                const start = parser.significant(parser.position);

                if (!parser.single_target(start, augmented)) parser.record(.unexpected_token);

                parser.events.start(.aug_assign);
                parser.expression_with(options_tuple);
                parser.bump();
                parser.expression_with(options_valued);
                parser.events.finish();

                return;
            }
        }

        if (outline.annotation) |annotation| {
            if (annotation < assign) {
                const start = parser.significant(parser.position);

                if (!parser.single_target(start, annotation)) parser.record(.unexpected_token);

                return parser.annotated();
            }
        }

        if (outline.assign != null) {
            parser.events.start(.assign);

            for (0..parser.steps()) |_| {
                parser.expression_with(options_valued);

                if (!parser.eat(.equal)) break;
            }

            parser.events.finish();

            return;
        }

        parser.events.start(.expr);
        parser.expression_with(options_valued);
        parser.events.finish();
    }

    fn single_target(parser: *Parser, from: u32, to: u32) bool {
        assert(from <= to);
        assert(to <= parser.count());

        var first = from;
        var last = to;

        for (0..parser.steps()) |_| {
            last = parser.target_last(first, last) orelse return false;

            const enclosed = parser.raw[first] == .paren_open and parser.closer_of(first) == last;
            if (!enclosed) break;

            first = parser.target_first(first + 1, last) orelse return false;
        }

        const head = parser.raw[first];
        if (head == .star) return false;
        if (is_unary_kind(head)) return false;

        var depth: u32 = 0;
        var scan = first;

        while (scan <= last) : (scan += 1) {
            const kind = parser.raw[scan];
            if (is_layout(kind)) continue;

            if (is_opener(kind)) depth += 1;
            if (is_closer(kind)) depth -|= 1;

            const bracket = is_opener(kind) or is_closer(kind);
            const operand = kind == .identifier or kind == .dot or expression.is_literal(kind);
            const foreign = !bracket and !operand;

            if (depth == 0) {
                if (foreign) return false;
            }
        }

        const tail = parser.raw[last];

        if (tail == .bracket_close) return parser.raw[first] != .bracket_open or
            parser.closer_of(first) != last;

        if (tail != .identifier) return false;
        if (first == last) return true;

        const before = parser.target_last(first, last) orelse return false;
        return parser.raw[before] == .dot;
    }

    fn target_first(parser: *Parser, from: u32, to: u32) ?u32 {
        assert(from <= to);
        assert(to <= parser.count());

        var scan = from;

        while (scan < to) : (scan += 1) {
            if (!is_layout(parser.raw[scan])) return scan;
        }

        return null;
    }

    fn target_last(parser: *Parser, from: u32, to: u32) ?u32 {
        assert(from <= to);
        assert(to <= parser.count());

        var scan = to;

        while (scan > from) {
            scan -= 1;

            if (!is_layout(parser.raw[scan])) return scan;
        }

        return null;
    }

    fn closer_of(parser: *Parser, opening: u32) ?u32 {
        assert(opening < parser.count());
        assert(is_opener(parser.raw[opening]));

        var depth: u32 = 0;
        var scan = opening;

        while (scan < parser.count()) : (scan += 1) {
            const kind = parser.raw[scan];

            if (is_opener(kind)) depth += 1;

            if (is_closer(kind)) {
                depth -= 1;

                if (depth == 0) return scan;
            }
        }

        return null;
    }

    fn annotated(parser: *Parser) void {
        assert(parser.frame_count == 0);
        assert(parser.value_count == 0);

        parser.events.start(.ann_assign);
        parser.expression_with(options_single);
        parser.expect(.colon, .expected_colon);
        parser.expression_with(options_single);

        if (parser.eat(.equal)) parser.expression_with(options_valued);

        parser.events.finish();
    }

    fn type_alias(parser: *Parser) void {
        assert(parser.at(.identifier));
        assert(parser.frame_count == 0);

        parser.events.start(.type_alias);
        parser.bump();
        parser.wrap(.name_node);
        parser.type_parameters();
        parser.expect(.equal, .expected_equal);
        parser.expression_with(options_single);
        parser.events.finish();
    }

    fn recover(parser: *Parser) void {
        assert(parser.frame_count == 0);
        assert(parser.position <= parser.count());

        parser.events.start(.error_node);

        const before = parser.position;

        while (parser.position < parser.count()) {
            const kind = parser.raw[parser.position];
            if (kind == .dedent) break;

            parser.emit();

            if (kind == .newline) break;
        }

        if (parser.position == before) parser.emit();

        parser.events.finish();
    }

    fn argument_list(parser: *Parser) void {
        assert(parser.at(.paren_open));
        assert(parser.frame_count == 0);

        parser.bump();

        var keywords = false;
        var unpacked = false;

        for (0..parser.steps()) |_| {
            parser.skip_trivia();

            if (parser.at(.paren_close)) break;

            const kind = parser.current() orelse break;
            const named = kind == .identifier and parser.ahead(1) == .equal;
            const positional = kind != .star and kind != .star_star and !named;
            const follows = positional and (keywords or unpacked);
            const misplaced = follows or (kind == .star and unpacked);

            if (misplaced) parser.record(.unexpected_token);

            keywords = keywords or named;
            unpacked = unpacked or kind == .star_star;

            parser.argument();

            if (!parser.eat(.comma)) break;
        }

        _ = parser.eat(.paren_close);
    }

    fn argument(parser: *Parser) void {
        assert(parser.frame_count == 0);
        assert(parser.current() != null);

        const checkpoint = parser.anchor();
        const kind = parser.current().?;

        if (kind == .star_star) {
            parser.bump();
            parser.expression_with(options_single);
            parser.enclose(checkpoint, .keyword);

            return;
        }

        if (kind == .star) {
            parser.bump();
            parser.expression_with(options_single);
            parser.enclose(checkpoint, .starred);

            return;
        }

        const named = kind == .identifier and parser.ahead(1) == .equal;

        if (named) {
            parser.bump();
            parser.bump();
            parser.expression_with(options_single);
            parser.enclose(checkpoint, .keyword);

            return;
        }

        parser.expression_with(options_named);
    }

    fn parameters(parser: *Parser) void {
        assert(parser.frame_count == 0);
        assert(parser.value_count == 0);

        if (!parser.at(.paren_open)) return;

        parser.events.start(.arguments);
        parser.bump();

        var signature: Signature = .empty;

        for (0..parser.steps()) |_| {
            parser.skip_trivia();

            if (parser.at(.paren_close)) break;
            if (parser.current() == null) break;

            parser.parameter(&signature);

            if (!parser.eat(.comma)) break;
        }

        if (signature.bare) parser.record(.unexpected_token);

        _ = parser.eat(.paren_close);

        parser.events.finish();
    }

    fn parameter(parser: *Parser, signature: *Signature) void {
        assert(parser.frame_count == 0);
        assert(parser.current() != null);

        const lead = parser.current().?;
        const annotation = if (lead == .star) options_starred else options_single;

        switch (lead) {
            .slash, .star, .star_star => parser.bump(),
            else => {},
        }

        const named = parser.at(.identifier);

        if (named) {
            parser.events.start(.arg);
            parser.bump();

            if (parser.eat(.colon)) parser.expression_with(annotation);

            parser.events.finish();
        }

        const defaulted = parser.eat(.equal);

        if (defaulted) parser.expression_with(options_single);
        if (!signature.admits(lead, named, defaulted)) parser.record(.unexpected_token);
    }

    fn type_parameters(parser: *Parser) void {
        assert(parser.frame_count == 0);
        assert(parser.value_count == 0);

        if (!parser.at(.bracket_open)) return;

        parser.events.start(.type_params);
        parser.bump();

        for (0..parser.steps()) |_| {
            parser.skip_trivia();

            if (parser.at(.bracket_close)) break;
            if (parser.current() == null) break;

            parser.type_parameter();

            if (!parser.eat(.comma)) break;
        }

        _ = parser.eat(.bracket_close);

        parser.events.finish();
    }

    fn type_parameter(parser: *Parser) void {
        assert(parser.frame_count == 0);
        assert(parser.current() != null);

        const checkpoint = parser.anchor();

        const kind: Kind = switch (parser.current().?) {
            .star_star => .param_spec,
            .star => .type_var_tuple,
            else => .type_var,
        };

        if (kind != .type_var) parser.bump();

        if (!parser.at(.identifier)) return;

        parser.bump();

        if (parser.eat(.colon)) parser.expression_with(options_single);
        if (parser.eat(.equal)) parser.expression_with(options_single);

        parser.enclose(checkpoint, kind);
    }

    fn with_is_parenthesized(parser: *Parser) bool {
        assert(parser.at(.paren_open));
        assert(parser.position <= parser.count());

        var position = parser.significant(parser.position);
        var depth: u32 = 0;
        var signature = false;
        var previous: Kind = .paren_open;

        while (position < parser.count()) : (position += 1) {
            const kind = parser.raw[position];

            switch (kind) {
                .newline, .dedent => return false,
                .comment => continue,
                else => {},
            }

            if (depth == 1) {
                const leading = previous == .paren_open or previous == .comma;
                const unpacked = kind == .star or kind == .star_star or kind == .yield_keyword;
                const expressed = kind == .colon_equal or kind == .for_keyword;
                const empty = kind == .paren_close and previous == .paren_open;

                if (kind == .lambda_keyword) signature = true;
                if (kind == .colon) signature = false;

                const unpacked_early = leading and unpacked and !signature;

                if (expressed) return false;
                if (empty) return false;
                if (unpacked_early) return false;
                if (kind == .as_keyword) return true;

                previous = kind;
            }

            if (is_opener(kind)) {
                depth += 1;

                continue;
            }

            if (is_closer(kind)) {
                depth -|= 1;

                if (depth == 1) previous = kind;
                if (depth > 0) continue;

                const next = parser.significant(position + 1);
                return parser.kind_at(next) == .colon;
            }
        }

        return false;
    }

    fn is_match_header(parser: *Parser) bool {
        assert(parser.position <= parser.count());
        assert(parser.frame_count == 0);

        return parser.soft_header("match");
    }

    fn soft_header(parser: *Parser, word: []const u8) bool {
        assert(word.len > 0);
        assert(parser.frame_count == 0);

        if (!parser.word_at(word)) return false;

        const separator = parser.header_colon() orelse return false;
        const after = parser.significant(parser.significant(parser.position) + 1);
        if (after >= separator) return false;

        const kind = parser.kind_at(parser.significant(separator + 1)) orelse return true;
        return kind == .newline;
    }

    fn is_type_alias(parser: *Parser) bool {
        assert(parser.position <= parser.count());
        assert(parser.frame_count == 0);

        if (!parser.word_at("type")) return false;

        const after = parser.significant(parser.significant(parser.position) + 1);
        if (parser.kind_at(after) != .identifier) return false;
        return parser.shape().assign != null;
    }

    fn word_at(parser: *Parser, word: []const u8) bool {
        assert(word.len > 0);
        assert(parser.tokens.len == parser.raw.len);

        const position = parser.significant(parser.position);
        if (parser.kind_at(position) != .identifier) return false;
        return std.mem.eql(u8, parser.tokens[position].text(parser.source), word);
    }

    fn line_end(parser: *Parser) u32 {
        assert(parser.position <= parser.count());

        var position = parser.significant(parser.position);
        var depth: u32 = 0;

        while (position < parser.count()) : (position += 1) {
            const kind = parser.raw[position];

            if (is_opener(kind)) {
                depth += 1;

                continue;
            }

            if (is_closer(kind)) {
                depth -|= 1;

                continue;
            }

            switch (kind) {
                .dedent, .newline => return position,
                .semicolon => if (depth == 0) return position,
                else => {},
            }
        }

        assert(position == parser.count());

        return position;
    }

    fn header_colon(parser: *Parser) ?u32 {
        assert(parser.position <= parser.count());

        var position = parser.significant(parser.position);
        var depth: u32 = 0;
        var lambdas: u32 = 0;

        while (position < parser.count()) : (position += 1) {
            const kind = parser.raw[position];

            if (is_opener(kind)) {
                depth += 1;

                continue;
            }

            if (is_closer(kind)) {
                depth -|= 1;

                continue;
            }

            switch (kind) {
                .lambda_keyword => if (depth == 0) {
                    lambdas += 1;
                },
                .colon => if (depth == 0) {
                    if (lambdas == 0) return position;

                    lambdas -= 1;
                },
                .dedent, .newline => return null,
                else => {},
            }
        }

        return null;
    }

    fn shape(parser: *Parser) Shape {
        assert(parser.position <= parser.count());

        const end = parser.line_end();
        var position = parser.significant(parser.position);
        var depth: u32 = 0;
        var lambdas: u32 = 0;
        var found: Shape = .{ .annotation = null, .assign = null, .augmented = null };

        while (position < end) : (position += 1) {
            const kind = parser.kind_at(position) orelse break;

            if (is_opener(kind)) {
                depth += 1;

                continue;
            }

            if (is_closer(kind)) {
                depth -|= 1;

                continue;
            }

            if (depth > 0) continue;

            switch (kind) {
                .lambda_keyword => lambdas += 1,
                .colon => {
                    if (lambdas > 0) {
                        lambdas -= 1;
                    } else {
                        if (found.annotation == null) found.annotation = position;
                    }
                },
                .equal => {
                    if (found.assign == null) found.assign = position;
                },
                else => {
                    if (is_augmented(kind)) {
                        if (found.augmented == null) found.augmented = position;
                    }
                },
            }
        }

        assert(position <= end);

        return found;
    }

    fn expression_with(parser: *Parser, options: Options) void {
        assert(parser.frame_count <= expression.depth_max);
        assert(parser.value_count <= expression.value_count_max);

        const frames_base = parser.frame_count;
        const values_base = parser.value_count;
        const checkpoint = parser.anchor();
        var frame: Frame = .empty;

        frame.checkpoint = checkpoint;
        frame.content = checkpoint;
        frame.element = checkpoint;
        frame.element_values = parser.value_count;
        frame.named = options.named;
        frame.no_in = options.no_in;
        frame.tuple = options.tuple;
        frame.unpacks = options.unpacks;
        frame.values = parser.value_count;
        frame.variant = .top;
        frame.yields = options.yields;

        if (!parser.push_frame(frame)) return;

        parser.machine(frames_base);

        if (parser.unclosed_above(frames_base + 1)) parser.record(.unexpected_token);

        parser.reduce_above(frames_base + 1);

        const top = parser.frames[frames_base];
        const produced = top.elements > 0 or parser.value_count > values_base;
        const lone = top.elements == 0 and top.starred;
        const lone_refused = lone and !options.lone;

        parser.frame_count = frames_base;

        if (!produced) parser.record(.expected_expression);
        if (lone_refused) parser.record(.unexpected_token);
        if (top.elements > 0) parser.enclose(top.checkpoint.?, .tuple);

        parser.value_count = values_base;
    }

    fn unclosed_above(parser: *const Parser, base: u32) bool {
        assert(base <= parser.frame_count);
        assert(parser.frame_count <= expression.depth_max);

        for (parser.frames[base..parser.frame_count]) |*frame| {
            if (frame.is_bracketed()) return true;
            if (frame.variant == .formatted) return true;
        }

        return false;
    }

    fn machine(parser: *Parser, base: u32) void {
        assert(base < parser.frame_count);
        assert(parser.frames[base].variant == .top);

        var operand = true;

        for (0..machine_step_max) |_| {
            const before = parser.progress();
            const step = if (operand) parser.operand_step(base) else parser.operator_step(base);

            switch (step) {
                .operand => operand = true,
                .operator => operand = false,
                .done => {
                    if (!operand) return;

                    switch (parser.operator_step(base)) {
                        .done => return,
                        .operand => operand = true,
                        .operator => operand = false,
                    }
                },
            }

            const now = parser.progress();
            if (std.meta.eql(now, before)) return;
        }
    }

    fn operand_step(parser: *Parser, base: u32) Step {
        assert(base < parser.frame_count);

        parser.skip_trivia();

        const kind = parser.current() orelse return .done;
        const group = parser.innermost_group(base);
        const frame = parser.frames[group];

        assert(frame.is_group());

        if (frame.variant == .joined) return parser.joined_piece(group, kind);

        if (frame.variant == .lambda) {
            if (frame.stage == 0) return parser.lambda_parameter(group, kind);
        }

        const keyword = kind == .identifier and frame.variant == .call and
            group + 1 == parser.frame_count and parser.value_count == frame.element_values and
            parser.ahead(1) == .equal;

        if (keyword) return parser.keyword_argument(group);

        const leading = group + 1 == parser.frame_count and
            parser.value_count == frame.element_values;

        const opens = kind != .star and kind != .star_star and kind != .paren_close;
        const positional = frame.variant == .call and leading and opens;
        const misplaced = positional and (frame.keywords or frame.unpacked);

        if (misplaced) parser.record(.unexpected_token);

        return parser.operand_of(kind, group);
    }

    fn operand_of(parser: *Parser, kind: Kind, group: u32) Step {
        assert(kind.is_token());
        assert(group < parser.frame_count);

        switch (kind) {
            .await_keyword, .lambda_keyword, .minus, .not_keyword, .plus, .tilde => {
                if (!parser.prefix_allowed(kind)) parser.record(.unexpected_token);
            },
            else => {},
        }

        switch (kind) {
            .await_keyword => return parser.unary(.await, expression.power_await),
            .lambda_keyword => return parser.open_lambda(),
            .minus, .plus, .tilde => return parser.unary(.unary_op, expression.power_sign),
            .not_keyword => return parser.unary(.unary_op, expression.power_not),
            .star => {
                const frame = parser.frames[group];

                if (frame.variant == .call) {
                    if (frame.unpacked) parser.record(.unexpected_token);
                }

                if (!parser.starrable(group)) parser.record(.unexpected_token);

                parser.frames[group].starred = true;

                return parser.unary(.starred, expression.power_starred);
            },
            .star_star => return parser.double_star(group),
            .yield_keyword => return parser.open_yield(),
            .brace_open, .bracket_open, .paren_open => {
                const checkpoint = parser.anchor();

                const variant: Variant = switch (kind) {
                    .brace_open => .brace,
                    .bracket_open => .bracket,
                    else => .paren,
                };

                return parser.open_group(variant, checkpoint);
            },
            .identifier => {
                const checkpoint = parser.anchor();

                parser.wrap(.name_node);
                parser.push_value(checkpoint);

                return .operator;
            },
            else => {},
        }

        const joined = kind == .f_string_start or
            (expression.is_string(kind) and parser.run_has_format());

        if (joined) return parser.open_joined(false);

        if (expression.is_literal(kind)) {
            const checkpoint = parser.anchor();

            parser.constant(kind);
            parser.push_value(checkpoint);

            return .operator;
        }

        return .done;
    }

    fn run_has_format(parser: *Parser) bool {
        assert(parser.position <= parser.count());

        var position = parser.significant(parser.position);

        for (0..parser.steps()) |_| {
            const kind = parser.kind_at(position) orelse return false;
            if (kind == .f_string_start) return true;
            if (!expression.is_string(kind)) return false;

            position = parser.significant(position + 1);
        }

        return false;
    }

    fn literal_continues(parser: *Parser) bool {
        assert(parser.position <= parser.count());

        var position = parser.significant(parser.position);
        var crossed = false;

        for (0..parser.steps()) |_| {
            const kind = parser.kind_at(position) orelse return false;

            switch (kind) {
                .f_string_end, .f_string_start => {
                    crossed = true;
                    position = parser.significant(position + 1);
                },
                .brace_open => return crossed and parser.field_debugged(position),
                else => return expression.is_contributor(kind),
            }
        }

        return false;
    }

    fn field_debugged(parser: *Parser, open: u32) bool {
        assert(open < parser.count());
        assert(parser.raw[open] == .brace_open);

        var depth: u32 = 0;
        var formats: u32 = 0;
        var position = open + 1;

        for (0..parser.steps()) |_| {
            const kind = parser.kind_at(position) orelse return false;

            position += 1;

            if (kind == .f_string_start) {
                formats += 1;

                continue;
            }

            if (kind == .f_string_end) {
                if (formats == 0) return false;

                formats -= 1;

                continue;
            }

            if (formats > 0) continue;

            if (depth == 0) {
                switch (kind) {
                    .equal => return true,
                    .bang, .brace_close, .colon => return false,
                    else => {},
                }
            }

            if (is_opener(kind)) depth += 1;
            if (is_closer(kind)) depth -|= 1;
        }

        return false;
    }

    fn open_joined(parser: *Parser, spec: bool) Step {
        assert(parser.frame_count > 0);
        if (spec) assert(parser.at(.colon));

        const checkpoint = parser.anchor();

        if (spec) parser.bump();

        var frame: Frame = .empty;

        frame.checkpoint = checkpoint;
        frame.dictionary = spec;
        frame.kind = .joined_str;
        frame.power = expression.power_barrier;
        frame.values = parser.value_count;
        frame.variant = .joined;

        if (!parser.push_frame(frame)) return .done;
        return .operand;
    }

    fn close_literal(parser: *Parser, group: u32) void {
        assert(group < parser.frame_count);
        assert(parser.frames[group].variant == .joined);

        if (!parser.frames[group].slice) return;

        parser.enclose(parser.frames[group].element.?, .constant);
        parser.frames[group].slice = false;
    }

    fn close_joined(parser: *Parser, group: u32) void {
        assert(group < parser.frame_count);
        assert(parser.frames[group].variant == .joined);

        parser.close_literal(group);

        const frame = parser.frames[group];

        parser.frame_count = group;

        parser.enclose(frame.checkpoint.?, .joined_str);
        parser.value_count = frame.values;

        parser.push_value(frame.checkpoint.?);
    }

    fn field_opens(parser: *Parser) bool {
        assert(parser.at(.brace_open));

        var position = parser.significant(parser.position);

        for (0..position) |_| {
            position -= 1;

            switch (parser.raw[position]) {
                .comment => {},
                .brace_close, .colon, .f_string_middle, .f_string_start => return true,
                else => return false,
            }
        }

        return false;
    }

    fn joined_piece(parser: *Parser, group: u32, kind: Kind) Step {
        assert(group < parser.frame_count);
        assert(parser.frames[group].variant == .joined);
        assert(kind.is_token());

        switch (kind) {
            .f_string_end, .f_string_start => {
                parser.bump();

                return .operand;
            },
            .brace_open => if (parser.field_opens()) return parser.open_formatted(group),
            else => {},
        }

        if (!expression.is_contributor(kind)) return .done;

        if (!parser.frames[group].slice) {
            parser.frames[group].element = parser.anchor();
            parser.frames[group].slice = true;
        }

        parser.bump();
        parser.frames[group].stage = 0;

        if (!parser.literal_continues()) parser.close_literal(group);

        return .operand;
    }

    fn open_formatted(parser: *Parser, group: u32) Step {
        assert(group < parser.frame_count);
        assert(parser.at(.brace_open));

        parser.close_literal(group);

        const checkpoint = parser.anchor();

        parser.bump();

        const element = parser.anchor();
        var frame: Frame = .empty;

        frame.checkpoint = checkpoint;
        frame.content = element;
        frame.element = element;
        frame.element_values = parser.value_count;
        frame.kind = .formatted_value;
        frame.power = expression.power_barrier;
        frame.values = parser.value_count;
        frame.variant = .formatted;

        if (!parser.push_frame(frame)) return .done;
        return .operand;
    }

    fn formatted_step(parser: *Parser, group: u32, kind: Kind, base: u32) Step {
        assert(group < parser.frame_count);
        assert(parser.frames[group].variant == .formatted);
        assert(base < std.math.maxInt(u32));
        assert(kind.is_token());

        switch (kind) {
            .bang, .brace_close, .colon, .equal => {},
            else => return .done,
        }

        parser.reduce_above(group + 1);

        const frame = parser.frames[group];
        const stage = frame.stage;
        const empty = frame.elements == 0 and parser.value_count == frame.values;
        const missing = stage == field_stage_expression and empty;

        if (missing) parser.record(.expected_expression);

        switch (kind) {
            .equal => {
                if (stage != field_stage_expression) {
                    parser.record(.unexpected_token);
                    parser.bump();

                    return .operator;
                }

                parser.frames[group].stage = field_stage_debug;

                parser.bump();
                parser.enclose(parser.frames[group].element.?, .constant);

                return .operator;
            },
            .bang => {
                if (stage > field_stage_debug) parser.record(.unexpected_token);

                parser.frames[group].stage = field_stage_converted;

                parser.bump();

                if (!parser.conversion()) parser.record(.unexpected_token);

                return .operator;
            },
            .colon => {
                parser.frames[group].stage = field_stage_spec;

                return parser.open_joined(true);
            },
            else => {},
        }

        parser.close_formatted(group, base);

        return .operator;
    }

    fn conversion(parser: *Parser) bool {
        assert(parser.position <= parser.count());

        if (!parser.at(.identifier)) return false;

        const token = parser.tokens[parser.significant(parser.position)];
        const text = token.text(parser.source);

        parser.bump();

        if (text.len != 1) return false;
        return std.mem.findScalar(u8, "ars", text[0]) != null;
    }

    fn close_formatted(parser: *Parser, group: u32, base: u32) void {
        assert(group < parser.frame_count);
        assert(parser.at(.brace_close));
        assert(base < std.math.maxInt(u32));

        parser.close_element(group);

        const frame = parser.frames[group];

        if (frame.elements > 0) parser.enclose(frame.content.?, .tuple);

        parser.frame_count = group;

        parser.events.start_at(frame.checkpoint.?, .formatted_value);
        parser.bump();
        parser.events.finish();
        parser.value_count = frame.values;

        parser.push_value(frame.checkpoint.?);

        const outer = parser.innermost_group(base);

        if (parser.frames[outer].variant == .joined) parser.frames[outer].stage = 1;
    }

    fn constant(parser: *Parser, kind: Kind) void {
        assert(kind.is_token());
        assert(parser.current() == kind);

        parser.events.start(.constant);
        parser.bump();

        if (expression.is_string(kind)) {
            for (0..parser.steps()) |_| {
                const next = parser.current() orelse break;
                if (!expression.is_string(next)) break;

                parser.bump();
            }
        }

        parser.events.finish();
    }

    fn double_star(parser: *Parser, group: u32) Step {
        assert(group < parser.frame_count);
        assert(parser.at(.star_star));

        const frame = parser.frames[group];

        const leading = group + 1 == parser.frame_count and
            parser.value_count == frame.element_values;

        const variant = frame.variant;

        parser.frames[group].starred = true;

        if (variant == .call) {
            const misplaced = !leading or frame.comprehension;

            if (misplaced) parser.record(.unexpected_token);

            parser.frames[group].unpacked = true;

            return parser.unary(.keyword, expression.power_starred);
        }

        const unpacks = variant == .brace and leading and !frame.keyed and !frame.comprehension;

        if (!unpacks) parser.record(.unexpected_token);

        if (variant == .brace) {
            parser.frames[group].dictionary = true;
            parser.frames[group].keyed = true;
        }

        parser.bump();

        return .operand;
    }

    fn starrable(parser: *Parser, group: u32) bool {
        assert(group < parser.frame_count);
        assert(parser.frames[group].is_group());

        const frame = parser.frames[group];
        const base = if (frame.variant == .formatted) frame.values else frame.element_values;
        const targeted = frame.comprehension and frame.stage == 1;
        const leading = parser.value_count == base or targeted;
        const untargeted = frame.comprehension and !targeted;

        if (group + 1 != parser.frame_count) return false;
        if (!leading) return false;
        if (untargeted) return false;

        return switch (frame.variant) {
            .top => frame.tuple or frame.unpacks,
            .brace => !frame.keyed,
            .bracket, .call, .formatted, .paren, .yield => true,
            .subscript => !frame.slice,
            else => false,
        };
    }

    fn keyword_argument(parser: *Parser, group: u32) Step {
        assert(group < parser.frame_count);
        assert(parser.at(.identifier));

        parser.frames[group].keywords = true;

        var frame: Frame = .empty;

        frame.checkpoint = parser.frames[group].element;
        frame.kind = .keyword;
        frame.power = expression.power_barrier;
        frame.values = parser.value_count;
        frame.variant = .keyword;

        if (!parser.push_frame(frame)) return .done;

        parser.bump();
        parser.bump();

        return .operand;
    }

    fn open_lambda(parser: *Parser) Step {
        assert(parser.at(.lambda_keyword));
        assert(parser.frame_count > 0);

        const checkpoint = parser.anchor();
        var frame: Frame = .empty;

        frame.checkpoint = checkpoint;
        frame.element = checkpoint;
        frame.kind = .lambda;
        frame.power = expression.power_barrier;
        frame.values = parser.value_count;
        frame.variant = .lambda;

        if (!parser.push_frame(frame)) return .done;

        parser.bump();

        return .operand;
    }

    fn open_yield(parser: *Parser) Step {
        assert(parser.at(.yield_keyword));
        assert(parser.frame_count > 0);

        const checkpoint = parser.anchor();
        const from = parser.ahead(1) == .from_keyword;

        if (!parser.yields()) parser.record(.unexpected_token);

        parser.bump();

        if (from) parser.bump();

        const content = parser.anchor();
        var frame: Frame = .empty;

        frame.checkpoint = checkpoint;
        frame.content = content;
        frame.element = content;
        frame.element_values = parser.value_count;
        frame.kind = if (from) .yield_from else .yield;
        frame.power = expression.power_starred;
        frame.values = parser.value_count;
        frame.variant = .yield;

        if (!parser.push_frame(frame)) return .done;
        return .operand;
    }

    fn yields(parser: *Parser) bool {
        assert(parser.frame_count > 0);

        const group = parser.innermost_group(0);
        const frame = parser.frames[group];
        const base = if (frame.variant == .formatted) frame.values else frame.element_values;
        const leading = frame.elements == 0 and parser.value_count == base;

        if (group + 1 != parser.frame_count) return false;
        if (!leading) return false;

        return switch (frame.variant) {
            .top => frame.yields,
            .formatted, .paren => true,
            else => false,
        };
    }

    fn lambda_parameter(parser: *Parser, group: u32, kind: Kind) Step {
        assert(group < parser.frame_count);
        assert(parser.frames[group].variant == .lambda);
        assert(kind.is_token());

        switch (kind) {
            .identifier, .slash, .star, .star_star => {
                const named = kind == .identifier or parser.ahead(1) == .identifier;

                if (kind != .identifier) parser.bump();
                if (named) parser.wrap(.arg);

                const defaulted = parser.at(.equal);
                const signature = &parser.frames[group].signature;

                if (!signature.admits(kind, named, defaulted)) parser.record(.unexpected_token);
                if (!defaulted) return .operator;

                parser.bump();
                parser.frames[group].stage = 2;
                parser.frames[group].element_values = parser.value_count;

                return .operand;
            },
            .colon => {
                if (parser.frames[group].signature.bare) parser.record(.unexpected_token);

                parser.reduce_above(group + 1);
                parser.bump();
                parser.frames[group].stage = 1;
                parser.frames[group].content = parser.anchor();

                return .operand;
            },
            else => {
                parser.record(.unexpected_token);

                return .done;
            },
        }
    }

    fn enclosing_closer(parser: *Parser, base: u32) Kind {
        assert(base < parser.frame_count);

        var index = parser.frame_count;

        while (index > base) {
            index -= 1;

            if (parser.frames[index].is_bracketed()) return parser.frames[index].closer;
            if (parser.frames[index].variant == .formatted) return .brace_close;
        }

        assert(index == base);

        return .error_token;
    }

    fn settle(parser: *Parser, base: u32, kind: Kind) void {
        assert(base < parser.frame_count);
        assert(kind.is_token());

        const closer = parser.enclosing_closer(base);

        for (0..expression.depth_max) |_| {
            const group = parser.innermost_group(base);
            const frame = parser.frames[group];
            const lambda = frame.variant == .lambda and frame.stage == 1;
            const yielded = frame.variant == .yield;

            if (!lambda) {
                if (!yielded) return;
            }

            if (kind != closer) {
                const separated = lambda and kind == .comma;
                const field = kind == .bang or kind == .colon or kind == .equal;
                const fielded = yielded and closer == .brace_close and field;

                if (!separated) {
                    if (!fielded) return;
                }
            }

            parser.reduce_above(group);
        }
    }

    fn operator_step(parser: *Parser, base: u32) Step {
        assert(base < parser.frame_count);

        parser.skip_trivia();

        const kind = parser.current() orelse return .done;
        const held = parser.innermost_group(base);

        switch (parser.frames[held].variant) {
            .joined => {
                const piece = expression.is_piece(kind) or kind == .brace_open;
                if (piece) return parser.joined_piece(held, kind);

                parser.close_joined(held);

                return .operator;
            },
            .formatted => {
                const step = parser.formatted_step(held, kind, base);
                if (step != .done) return step;
            },
            else => {},
        }

        if (parser.frames[held].variant == .lambda) {
            if (parser.frames[held].stage == 0) {
                switch (kind) {
                    .colon, .comma => {},
                    else => {
                        parser.record(.unexpected_token);

                        return .done;
                    },
                }
            }
        }

        parser.settle(base, kind);

        const group = parser.innermost_group(base);
        const frame = parser.frames[group];

        if (frame.variant == .formatted) {
            if (held != group) {
                const step = parser.formatted_step(group, kind, base);
                if (step != .done) return step;
            }
        }

        if (frame.is_bracketed()) {
            if (kind == frame.closer) {
                parser.close_group(group);

                return .operator;
            }
        }

        return switch (kind) {
            .comma => parser.comma(group),
            .dot => parser.attribute(),
            .paren_open => parser.trailer(.call),
            .bracket_open => parser.trailer(.subscript),
            .colon => parser.colon(group),
            else => parser.operator_of(kind, group, base),
        };
    }

    fn operator_of(parser: *Parser, kind: Kind, group: u32, base: u32) Step {
        assert(kind.is_token());
        assert(group < parser.frame_count);
        assert(base < std.math.maxInt(u32));

        const frame = parser.frames[group];

        switch (kind) {
            .in_keyword => {
                if (group == base) {
                    if (frame.no_in) return .done;
                }

                if (frame.comprehension) {
                    if (frame.stage == 1) return parser.comprehension_in(group);
                }
            },
            .for_keyword => return parser.comprehension_for(group),
            .async_keyword => {
                if (parser.ahead(1) == .for_keyword) return parser.comprehension_for(group);
            },
            .if_keyword => return parser.if_operator(group),
            .else_keyword => return parser.conditional_else(base),
            .colon_equal => {
                if (!parser.walrus_allowed()) parser.record(.unexpected_token);
            },
            .not_keyword => {
                if (parser.ahead(1) == .in_keyword) return parser.comparison(2);
            },
            .is_keyword => {
                const negated: u32 = @intFromBool(parser.ahead(1) == .not_keyword);
                return parser.comparison(negated + 1);
            },
            else => {},
        }

        const infix = expression.infix_of(kind) orelse return .done;
        return parser.binary(infix.node, kind, infix.left, infix.right);
    }

    fn walrus_allowed(parser: *Parser) bool {
        assert(parser.at(.colon_equal));
        assert(parser.frame_count > 0);

        parser.reduce_for(expression.power_walrus_left);

        const group = parser.frame_count - 1;
        const frame = parser.frames[group];
        if (!frame.is_group()) return false;
        if (parser.value_count != frame.element_values + 1) return false;

        const value = parser.values[parser.value_count - 1];
        if (parser.events.started(value) != .name_node) return false;

        const allowed = switch (frame.variant) {
            .top => frame.named,
            .brace => !frame.comprehension and !frame.keyed,
            .bracket, .call, .paren => !frame.comprehension,
            .subscript => !frame.slice,
            else => false,
        };

        if (allowed) parser.frames[group].walrus = true;

        return allowed;
    }

    fn if_operator(parser: *Parser, group: u32) Step {
        assert(group < parser.frame_count);
        assert(parser.at(.if_keyword));

        const frame = parser.frames[group];
        const filter = frame.comprehension and frame.stage >= 2;
        if (!filter) return parser.conditional();

        parser.reduce_above(group + 1);
        parser.clause_check(group);
        parser.bump();
        parser.frames[group].stage = 3;
        parser.frames[group].element_values = parser.value_count;

        return .operand;
    }

    fn comma(parser: *Parser, group: u32) Step {
        assert(group < parser.frame_count);
        assert(parser.at(.comma));

        const frame = parser.frames[group];

        if (frame.variant == .lambda) {
            parser.reduce_above(group + 1);
            parser.default_check(group);
            parser.bump();

            if (frame.stage == 2) parser.frames[group].stage = 0;

            return .operand;
        }

        if (frame.variant == .top) {
            if (!frame.tuple) return .done;
        }

        if (frame.variant == .yield) {
            if (frame.kind == .yield_from) parser.record(.unexpected_token);
        }

        parser.reduce_above(group + 1);

        if (frame.comprehension) {
            if (frame.stage == 1) {
                parser.frames[group].slice = true;

                parser.bump();

                return .operand;
            }

            parser.record(.unexpected_token);
        }

        const empty = parser.value_count == frame.element_values and !frame.slice;

        if (empty) parser.record(.expected_expression);

        parser.brace_entry(group);
        parser.close_element(group);
        parser.bump();
        parser.frames[group].elements += 1;
        parser.frames[group].keyed = false;
        parser.frames[group].starred = false;
        parser.frames[group].walrus = false;
        parser.frames[group].element = parser.anchor();
        parser.value_count = parser.frames[group].values;
        parser.frames[group].element_values = parser.value_count;

        if (frame.variant == .subscript) parser.frames[group].stage = 0;

        return .operand;
    }

    fn attribute(parser: *Parser) Step {
        assert(parser.at(.dot));
        assert(parser.value_count <= expression.value_count_max);

        if (!parser.operand_held()) return .done;

        const checkpoint = parser.values[parser.value_count - 1];

        parser.events.start_at(checkpoint, .attribute);
        parser.bump();

        if (!parser.eat(.identifier)) parser.record(.expected_identifier);

        parser.events.finish();

        return .operator;
    }

    fn operand_held(parser: *Parser) bool {
        assert(parser.frame_count > 0);
        assert(parser.value_count <= expression.value_count_max);

        if (parser.value_count <= parser.frames[parser.frame_count - 1].values) return false;

        var position = parser.significant(parser.position);

        for (0..position) |_| {
            position -= 1;

            const kind = parser.raw[position];
            if (kind == .comment) continue;

            return kind == .identifier or kind == .f_string_end or kind == .string_format or
                expression.is_literal(kind) or is_closer(kind);
        }

        return false;
    }

    fn trailer(parser: *Parser, variant: Variant) Step {
        assert(variant == .call or variant == .subscript);
        assert(parser.value_count <= expression.value_count_max);

        if (!parser.operand_held()) return .done;

        const checkpoint = parser.values[parser.value_count - 1];

        parser.value_count -= 1;

        return parser.open_group(variant, checkpoint);
    }

    fn colon(parser: *Parser, group: u32) Step {
        assert(group < parser.frame_count);
        assert(parser.at(.colon));

        const owner = parser.colon_owner(group) orelse return .done;
        const frame = parser.frames[owner];
        const filled = frame.keyed or frame.plain;

        if (frame.variant == .brace) {
            if (filled) parser.record(.unexpected_token);
        }

        const element = frame.variant == .brace or frame.variant == .subscript;
        const marked = frame.starred or frame.walrus;

        if (element) {
            if (marked) parser.record(.unexpected_token);
        }

        parser.reduce_above(owner + 1);

        if (frame.variant == .brace) {
            if (parser.value_count == frame.element_values) parser.record(.expected_expression);
        }

        if (frame.variant == .lambda) parser.default_check(owner);

        parser.bump();

        switch (frame.variant) {
            .lambda => {
                if (frame.signature.bare) parser.record(.unexpected_token);

                parser.frames[owner].stage = 1;
                parser.frames[owner].content = parser.anchor();
            },
            .brace => {
                parser.frames[owner].dictionary = true;
                parser.frames[owner].keyed = true;
            },
            .subscript => {
                if (frame.stage >= slice_colon_count_max) parser.record(.unexpected_token);

                parser.frames[owner].slice = true;
                parser.frames[owner].stage = frame.stage + 1;
            },
            else => unreachable,
        }

        return .operand;
    }

    fn default_check(parser: *Parser, group: u32) void {
        assert(group < parser.frame_count);
        assert(parser.frames[group].variant == .lambda);

        const frame = parser.frames[group];
        if (frame.stage != 2) return;

        if (parser.value_count == frame.element_values) parser.record(.expected_expression);
    }

    fn brace_entry(parser: *Parser, group: u32) void {
        assert(group < parser.frame_count);
        assert(parser.frames[group].is_group());

        const frame = parser.frames[group];
        if (frame.variant != .brace) return;
        if (frame.comprehension) return;

        if (frame.keyed) {
            const owed: u32 = if (frame.starred) 1 else 2;
            const short = parser.value_count < frame.element_values + owed;

            if (short) parser.record(.expected_expression);

            return;
        }

        if (parser.value_count == frame.element_values) return;

        if (frame.dictionary) parser.record(.unexpected_token);

        parser.frames[group].plain = true;
    }

    fn colon_owner(parser: *Parser, group: u32) ?u32 {
        assert(group < parser.frame_count);
        assert(parser.frames[group].is_group());

        var held = group;

        for (0..expression.depth_max) |_| {
            const frame = parser.frames[held];

            switch (frame.variant) {
                .brace, .subscript => return held,
                .lambda => if (frame.stage != 1) return held,
                else => return null,
            }

            var below = held;

            while (below > 0) {
                below -= 1;

                if (parser.frames[below].is_group()) break;
            }

            if (below == held) return null;
            if (!parser.frames[below].is_group()) return null;

            held = below;
        }

        return null;
    }

    fn comprehension_for(parser: *Parser, group: u32) Step {
        assert(group < parser.frame_count);
        assert(parser.current() != null);

        var held = group;

        for (0..expression.depth_max) |_| {
            if (held >= parser.frame_count) return .done;
            if (parser.frames[held].variant != .lambda) break;
            if (held == 0) return .done;

            parser.reduce_above(held);

            if (parser.frame_count == 0) return .done;

            held = parser.innermost_group(0);
        }

        const frame = parser.frames[held];

        switch (frame.variant) {
            .formatted, .lambda, .top, .yield => return .done,
            else => {},
        }

        const leading = !frame.comprehension and frame.starred;
        const misplaced = frame.elements > 0 or leading or frame.variant == .subscript;

        if (misplaced) parser.record(.unexpected_token);

        parser.reduce_above(held + 1);
        parser.clause_check(held);

        if (!frame.comprehension) {
            const paired = frame.variant == .brace and frame.keyed;
            const owed: u32 = if (paired) 2 else 1;
            const short = parser.value_count < frame.element_values + owed;

            if (short) parser.record(.expected_expression);
        }

        parser.close_clause(held);
        parser.value_count = parser.frames[held].values;
        parser.frames[held].element_values = parser.value_count;

        const clause = parser.anchor();

        _ = parser.eat(.async_keyword);

        parser.bump();

        const element = parser.anchor();

        parser.frames[held].clause = clause;
        parser.frames[held].comprehension = true;
        parser.frames[held].element = element;
        parser.frames[held].slice = false;
        parser.frames[held].stage = 1;
        parser.frames[held].starred = false;

        return .operand;
    }

    fn comprehension_in(parser: *Parser, group: u32) Step {
        assert(group < parser.frame_count);
        assert(parser.at(.in_keyword));

        parser.reduce_above(group + 1);

        const targetless = parser.value_count == parser.frames[group].element_values;

        if (targetless) parser.record(.expected_expression);

        if (parser.frames[group].slice) {
            parser.enclose(parser.frames[group].element.?, .tuple);
            parser.frames[group].slice = false;
        }

        parser.bump();
        parser.frames[group].stage = 2;
        parser.frames[group].element_values = parser.value_count;

        return .operand;
    }

    fn clause_check(parser: *Parser, group: u32) void {
        assert(group < parser.frame_count);
        assert(parser.frames[group].is_group());

        const frame = parser.frames[group];
        if (!frame.comprehension) return;

        const complete = frame.stage >= 2 and parser.value_count > frame.element_values;

        if (!complete) parser.record(.expected_expression);
    }

    fn comparison(parser: *Parser, width: u32) Step {
        assert(width >= 1);
        assert(width <= 2);

        const outcome = parser.binary(
            .compare,
            .in_keyword,
            expression.power_compare_left,
            expression.power_compare_right,
        );

        for (1..width) |_| parser.bump();

        return outcome;
    }

    fn conditional(parser: *Parser) Step {
        assert(parser.at(.if_keyword));
        assert(parser.frame_count > 0);

        parser.reduce_for(expression.power_conditional_left);

        if (!parser.operand_held()) {
            parser.record(.expected_expression);
            parser.bump();

            return .operand;
        }

        if (parser.narrowed()) parser.record(.unexpected_token);

        const values = parser.value_count - 1;
        var frame: Frame = .empty;

        frame.checkpoint = parser.values[values];
        frame.kind = .if_exp;
        frame.power = expression.power_conditional_right;
        frame.values = values;
        frame.variant = .conditional;

        if (!parser.push_frame(frame)) return .done;

        parser.bump();

        return .operand;
    }

    fn conditional_else(parser: *Parser, base: u32) Step {
        assert(base < parser.frame_count);
        assert(parser.at(.else_keyword));

        var index = parser.frame_count;

        while (index > base) {
            index -= 1;

            if (parser.frames[index].variant == .conditional) {
                if (parser.frames[index].stage != 0) return .done;

                parser.reduce_above(index + 1);
                parser.bump();
                parser.frames[index].stage = 1;

                return .operand;
            }

            if (parser.frames[index].is_group()) break;
        }

        return .done;
    }

    fn unary(parser: *Parser, kind: Kind, power: u8) Step {
        assert(kind.is_node());
        assert(power > expression.power_barrier);

        const checkpoint = parser.anchor();
        var frame: Frame = .empty;

        frame.checkpoint = checkpoint;
        frame.kind = kind;
        frame.power = power;
        frame.values = parser.value_count;
        frame.variant = .unary;

        if (!parser.push_frame(frame)) return .done;

        parser.bump();

        return .operand;
    }

    fn prefix_allowed(parser: *Parser, kind: Kind) bool {
        assert(kind.is_token());
        assert(parser.frame_count > 0);

        const top = parser.frames[parser.frame_count - 1];
        const lambda = kind == .lambda_keyword;
        const loose = lambda or kind == .not_keyword;
        if (parser.narrowed()) return !loose;

        return switch (top.variant) {
            .unary => switch (top.kind) {
                .await => false,
                .unary_op => if (top.power == expression.power_not) !lambda else !loose,
                else => true,
            },
            .binary => switch (top.kind) {
                .named_expr => true,
                .bool_op => !lambda,
                else => !loose,
            },
            .conditional => !lambda or top.stage == 1,
            else => !(lambda and top.comprehension and top.stage >= 2),
        };
    }

    fn narrowed(parser: *Parser) bool {
        assert(parser.frame_count <= expression.depth_max);

        if (parser.frame_count == 0) return false;

        const top = parser.frames[parser.frame_count - 1];
        if (top.variant != .unary) return false;
        if (top.kind != .starred) return false;

        const variant = parser.frames[parser.innermost_group(0)].variant;
        return variant != .call and variant != .subscript;
    }

    fn merges(parser: *Parser, kind: Kind, token: Kind) bool {
        assert(kind.is_node());
        assert(token.is_token());

        if (parser.frame_count == 0) return false;

        const top = parser.frames[parser.frame_count - 1];
        if (top.variant != .binary) return false;
        if (top.kind != kind) return false;

        return switch (kind) {
            .compare, .match_or => true,
            .bool_op => top.token == token,
            else => false,
        };
    }

    fn binary(parser: *Parser, kind: Kind, token: Kind, left: u8, right: u8) Step {
        assert(kind.is_node());
        assert(left != right);
        assert(token.is_token());

        while (parser.frame_count > 0) {
            if (parser.merges(kind, token)) break;

            const top = parser.frames[parser.frame_count - 1];
            if (top.power == expression.power_barrier) break;
            if (top.power < left) break;

            parser.reduce_top();
        }

        if (!parser.operand_held()) {
            parser.record(.expected_expression);
            parser.bump();

            return .operand;
        }

        if (parser.merges(kind, token)) {
            const top = &parser.frames[parser.frame_count - 1];
            const chained = parser.value_count == top.values + top.elements + 1;

            if (!chained) parser.record(.expected_expression);

            top.elements += 1;

            parser.bump();

            return .operand;
        }

        if (left < expression.power_bar_left) {
            if (parser.narrowed()) parser.record(.unexpected_token);
        }

        const values = parser.value_count - 1;
        var frame: Frame = .empty;

        frame.checkpoint = parser.values[values];
        frame.elements = 1;
        frame.kind = kind;
        frame.power = right;
        frame.token = token;
        frame.values = values;
        frame.variant = .binary;

        if (!parser.push_frame(frame)) return .done;

        parser.bump();

        return .operand;
    }

    fn open_group(parser: *Parser, variant: Variant, checkpoint: Checkpoint) Step {
        assert(checkpoint.index <= parser.events.count());

        const opener = parser.current() orelse .paren_open;
        const bracket = parser.anchor();

        parser.bump();

        const content = parser.anchor();
        var frame: Frame = .empty;

        frame.bracket = bracket;
        frame.checkpoint = checkpoint;
        frame.closer = expression.closer_of(opener);
        frame.content = content;
        frame.element = content;
        frame.element_values = parser.value_count;
        frame.values = parser.value_count;
        frame.variant = variant;

        if (!parser.push_frame(frame)) return .done;
        return .operand;
    }

    fn close_clause(parser: *Parser, group: u32) void {
        assert(group < parser.frame_count);
        assert(parser.frames[group].is_group());

        const clause = parser.frames[group].clause orelse return;

        parser.enclose(clause, .comprehension);
        parser.frames[group].clause = null;
    }

    fn close_element(parser: *Parser, group: u32) void {
        assert(group < parser.frame_count);
        assert(parser.frames[group].is_group());

        const frame = parser.frames[group];
        if (frame.variant != .subscript) return;
        if (!frame.slice) return;

        parser.enclose(frame.element.?, .slice);
        parser.frames[group].slice = false;
    }

    fn close_group(parser: *Parser, group: u32) void {
        assert(group < parser.frame_count);
        assert(parser.frames[group].is_bracketed());

        parser.reduce_above(group + 1);
        parser.brace_entry(group);
        parser.clause_check(group);
        parser.close_clause(group);

        const held = parser.frames[group];

        const indexless = held.variant == .subscript and !held.slice and held.elements == 0 and
            parser.value_count == held.values;

        parser.close_element(group);

        const frame = parser.frames[group];
        const seen = parser.value_count -% frame.values;
        const lone = frame.variant == .paren and frame.elements == 0 and frame.starred;
        const bare = lone and !frame.comprehension;

        if (bare) parser.record(.unexpected_token);
        if (indexless) parser.record(.expected_expression);

        parser.frame_count = group;

        if (frame.variant == .subscript) {
            const listed = frame.elements > 0 or frame.starred;

            if (listed) parser.enclose(frame.content.?, .tuple);
        }

        const kind = group_kind(&frame, seen);
        const generator = frame.variant == .call and frame.comprehension;

        parser.events.start_at(frame.checkpoint.?, kind);

        if (generator) parser.events.start_at(frame.bracket.?, .generator_exp);

        parser.bump();
        parser.events.finish();

        if (generator) parser.events.finish();

        parser.value_count = frame.values;

        parser.push_value(frame.checkpoint.?);
    }

    fn reduce_top(parser: *Parser) void {
        assert(parser.frame_count > 0);
        assert(parser.frame_count <= expression.depth_max);

        parser.frame_count -= 1;

        const frame = parser.frames[parser.frame_count];

        const owed: u32 = switch (frame.variant) {
            .binary => frame.elements + 1,
            .conditional => 3,
            .keyword, .unary => 1,
            .yield => @intFromBool(frame.kind == .yield_from),
            else => 0,
        };

        if (parser.value_count < frame.values + owed) parser.record(.expected_expression);
        const bodiless = frame.variant == .lambda and !parser.bodied(&frame);

        if (bodiless) parser.record(.expected_expression);

        if (frame.variant == .yield) {
            if (frame.elements > 0) parser.enclose(frame.content.?, .tuple);
        }

        parser.enclose(frame.checkpoint.?, frame.kind);
        parser.value_count = frame.values;

        parser.push_value(frame.checkpoint.?);
    }

    fn bodied(parser: *const Parser, frame: *const Frame) bool {
        assert(frame.variant == .lambda);
        assert(parser.value_count <= expression.value_count_max);

        if (frame.stage != 1) return false;
        if (parser.value_count <= frame.values) return false;

        const content = frame.content orelse return false;
        return parser.values[parser.value_count - 1].index >= content.index;
    }

    fn reduce_above(parser: *Parser, base: u32) void {
        assert(parser.frame_count <= expression.depth_max);
        assert(base < std.math.maxInt(u32));

        while (parser.frame_count > base) parser.reduce_top();

        assert(parser.frame_count <= base);
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

    fn push_frame(parser: *Parser, frame: Frame) bool {
        assert(parser.frame_count <= expression.depth_max);
        assert(frame.checkpoint != null);

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

    fn innermost_group(parser: *Parser, base: u32) u32 {
        assert(base <= parser.frame_count);

        var index = parser.frame_count;

        while (index > base) {
            index -= 1;

            if (parser.frames[index].is_group()) return index;
        }

        assert(index == base);

        return base;
    }

    fn pattern(parser: *Parser) void {
        assert(parser.frame_count == 0);
        assert(parser.value_count == 0);

        const base = parser.frame_count;
        var frame: Frame = .empty;

        frame.checkpoint = parser.anchor();
        frame.tuple = true;
        frame.values = parser.value_count;
        frame.variant = .top;

        if (!parser.push_frame(frame)) return;

        var operand = true;

        for (0..pattern_step_max) |_| {
            const position = parser.position;
            const frames = parser.frame_count;

            const step = if (operand)
                parser.pattern_operand(base)
            else
                parser.pattern_operator(base);

            switch (step) {
                .operand => operand = true,
                .operator => operand = false,
                .done => break,
            }

            if (parser.position == position) {
                if (parser.frame_count == frames) break;
            }
        }

        parser.reduce_above(base + 1);

        const top = parser.frames[base];

        parser.frame_count = base;

        if (top.elements > 0) parser.enclose(top.checkpoint.?, .match_sequence);

        if (top.elements == 0) {
            if (top.starred) parser.record(.unexpected_token);
        }

        parser.value_count = top.values;

        if (parser.eat(.if_keyword)) parser.expression_with(options_named);
    }

    fn pattern_string(parser: *Parser) void {
        assert(parser.current() != null);
        assert(parser.frame_count < expression.depth_max);

        const frames_base = parser.frame_count;
        const values_base = parser.value_count;
        var frame: Frame = .empty;

        frame.checkpoint = parser.anchor();
        frame.element_values = parser.value_count;
        frame.values = parser.value_count;
        frame.variant = .top;

        if (!parser.push_frame(frame)) return;

        var operand = parser.open_joined(false) == .operand;

        for (0..machine_step_max) |_| {
            if (parser.frame_count <= frames_base + 1) break;

            const before = parser.progress();

            const step = if (operand)
                parser.operand_step(frames_base)
            else
                parser.operator_step(frames_base);

            switch (step) {
                .operand => operand = true,
                .operator => operand = false,
                .done => break,
            }

            if (std.meta.eql(parser.progress(), before)) break;
        }

        parser.reduce_above(frames_base + 1);
        parser.frame_count = frames_base;
        parser.value_count = values_base;
    }

    fn capture(parser: *Parser) bool {
        assert(parser.position <= parser.count());

        if (!parser.at(.identifier)) return false;

        const wildcard = parser.word_at("_");

        parser.bump();

        return !wildcard and !parser.at(.dot);
    }

    fn dotted(parser: *Parser, checkpoint: Checkpoint) void {
        assert(parser.at(.identifier));
        assert(checkpoint.index <= parser.events.count());

        parser.wrap(.name_node);

        for (0..parser.steps()) |_| {
            if (!parser.at(.dot)) break;

            parser.events.start_at(checkpoint, .attribute);
            parser.bump();
            _ = parser.eat(.identifier);

            parser.events.finish();
        }
    }

    fn pattern_value(parser: *Parser, checkpoint: Checkpoint) void {
        assert(parser.current() != null);
        assert(checkpoint.index <= parser.events.count());

        parser.signed_literal(checkpoint);
        parser.enclose(checkpoint, .match_value);
    }

    fn signed_literal(parser: *Parser, checkpoint: Checkpoint) void {
        assert(parser.current() != null);
        assert(checkpoint.index <= parser.events.count());

        const sign = parser.current().?;
        const signed = sign == .minus or sign == .plus;

        if (sign == .plus) parser.record(.unexpected_token);
        if (signed) parser.bump();

        const real = parser.current();

        if (real) |kind| {
            if (signed) {
                if (!is_number(kind)) parser.record(.unexpected_token);
            }

            if (expression.is_literal(kind)) parser.constant(kind);
        }

        if (signed) parser.enclose(checkpoint, .unary_op);

        const joined = parser.at(.plus) or parser.at(.minus);
        if (!joined) return;

        const left_real = if (real) |kind| is_number(kind) and kind != .number_complex else false;

        if (!left_real) parser.record(.unexpected_token);

        parser.bump();

        const imaginary = parser.current();

        if (imaginary != .number_complex) parser.record(.unexpected_token);

        if (imaginary) |kind| {
            if (is_number(kind)) parser.constant(kind);
        }

        parser.enclose(checkpoint, .bin_op);
    }

    fn open_pattern_group(parser: *Parser, variant: Variant, closer: Kind) Step {
        assert(variant != .class_args);
        assert(closer.is_token());

        const checkpoint = parser.anchor();
        return parser.open_pattern_group_at(variant, closer, checkpoint);
    }

    fn open_pattern_group_at(
        parser: *Parser,
        variant: Variant,
        closer: Kind,
        checkpoint: Checkpoint,
    ) Step {
        assert(closer.is_token());

        parser.bump();

        const content = parser.anchor();
        var frame: Frame = .empty;

        frame.checkpoint = checkpoint;
        frame.closer = closer;
        frame.content = content;
        frame.element = content;
        frame.values = parser.value_count;
        frame.variant = variant;

        if (!parser.push_frame(frame)) return .done;
        return .operand;
    }

    fn close_pattern_group(parser: *Parser, group: u32) void {
        assert(group < parser.frame_count);
        assert(parser.frames[group].is_pattern());

        parser.reduce_above(group + 1);

        const frame = parser.frames[group];
        const seen = parser.value_count -% frame.values;
        const inner = if (seen > 0) parser.values[parser.value_count - 1] else frame.checkpoint;

        parser.frame_count = group;

        const transparent = frame.variant == .pattern_group and frame.elements == 0 and
            seen == 1;

        const lone = frame.variant == .pattern_group and frame.elements == 0 and frame.starred;

        if (lone) parser.record(.unexpected_token);

        if (transparent) {
            parser.bump();
            parser.value_count = frame.values;

            parser.push_value(inner.?);

            return;
        }

        const kind: Kind = switch (frame.variant) {
            .class_args => .match_class,
            .mapping => .match_mapping,
            else => .match_sequence,
        };

        parser.events.start_at(frame.checkpoint.?, kind);
        parser.bump();
        parser.events.finish();
        parser.value_count = frame.values;

        parser.push_value(frame.checkpoint.?);
    }

    fn pattern_operand(parser: *Parser, base: u32) Step {
        assert(base < parser.frame_count);

        parser.skip_trivia();

        const kind = parser.current() orelse return .done;
        const group = parser.innermost_group(base);
        const frame = parser.frames[group];

        if (frame.is_pattern()) {
            if (kind == frame.closer) {
                parser.close_pattern_group(group);

                return .operator;
            }
        }

        if (frame.variant == .mapping) {
            if (frame.stage == 0) return parser.mapping_key(group, kind);
        }

        const leading = frame.variant == .class_args and frame.stage == 0;

        if (leading) {
            const keyword = kind == .identifier and parser.ahead(1) == .equal;

            parser.frames[group].stage = 1;

            if (keyword) {
                parser.frames[group].keywords = true;

                parser.bump();
                parser.bump();

                return .operand;
            }

            if (frame.keywords) parser.record(.unexpected_token);
        }

        return parser.pattern_atom(kind);
    }

    fn mapping_key(parser: *Parser, group: u32, kind: Kind) Step {
        assert(group < parser.frame_count);
        assert(parser.frames[group].variant == .mapping);
        assert(kind.is_token());

        if (parser.frames[group].unpacked) parser.record(.unexpected_token);

        if (kind == .star_star) {
            parser.frames[group].unpacked = true;

            parser.bump();

            if (!parser.capture()) parser.record(.unexpected_token);

            return .operator;
        }

        const checkpoint = parser.anchor();

        const joined = kind == .f_string_start or
            (expression.is_string(kind) and parser.run_has_format());

        const literal = kind == .minus or kind == .plus or expression.is_literal(kind);

        if (kind == .identifier) {
            if (parser.ahead(1) != .dot) parser.record(.unexpected_token);

            parser.dotted(checkpoint);
        } else if (joined) {
            parser.pattern_string();
        } else if (literal) {
            parser.signed_literal(checkpoint);
        } else {
            parser.constant(kind);
        }

        _ = parser.eat(.colon);
        parser.frames[group].stage = 1;

        return .operand;
    }

    fn pattern_atom(parser: *Parser, kind: Kind) Step {
        assert(kind.is_token());
        assert(parser.current() == kind);

        switch (kind) {
            .bracket_open => return parser.open_pattern_group(.sequence, .bracket_close),
            .paren_open => return parser.open_pattern_group(.pattern_group, .paren_close),
            .brace_open => return parser.open_pattern_group(.mapping, .brace_close),
            .star => {
                const group = parser.innermost_group(0);
                const variant = parser.frames[group].variant;
                const nested = variant == .class_args or variant == .mapping;
                const checkpoint = parser.anchor();
                const misplaced = nested or group + 1 != parser.frame_count;

                if (misplaced) parser.record(.unexpected_token);

                parser.frames[group].starred = true;

                parser.bump();
                parser.expect(.identifier, .expected_identifier);
                parser.enclose(checkpoint, .match_star);
                parser.push_value(checkpoint);

                const followed = parser.at(.bar) or parser.at(.as_keyword);

                if (followed) parser.record(.unexpected_token);

                return .operator;
            },
            .false_keyword, .none_keyword, .true_keyword => {
                const checkpoint = parser.anchor();

                parser.wrap(.match_singleton);
                parser.push_value(checkpoint);

                return .operator;
            },
            .identifier => return parser.pattern_name(),
            else => {},
        }

        const joined = kind == .f_string_start or
            (expression.is_string(kind) and parser.run_has_format());

        const valued = expression.is_literal(kind) or kind == .minus or kind == .plus;

        if (!joined) {
            if (!valued) return .done;
        }

        const checkpoint = parser.anchor();

        if (joined) {
            parser.pattern_string();
            parser.enclose(checkpoint, .match_value);
        } else {
            parser.pattern_value(checkpoint);
        }

        parser.push_value(checkpoint);

        return .operator;
    }

    fn pattern_name(parser: *Parser) Step {
        assert(parser.at(.identifier));
        assert(parser.frame_count > 0);

        const checkpoint = parser.anchor();
        const next = parser.ahead(1) orelse .error_token;

        switch (next) {
            .dot, .paren_open => {},
            else => {
                parser.wrap(.match_as);
                parser.push_value(checkpoint);

                return .operator;
            },
        }

        parser.dotted(checkpoint);

        if (parser.at(.paren_open)) {
            return parser.open_pattern_group_at(.class_args, .paren_close, checkpoint);
        }

        parser.enclose(checkpoint, .match_value);
        parser.push_value(checkpoint);

        return .operator;
    }

    fn pattern_operator(parser: *Parser, base: u32) Step {
        assert(base < parser.frame_count);

        parser.skip_trivia();

        const kind = parser.current() orelse return .done;
        const group = parser.innermost_group(base);
        const frame = parser.frames[group];

        if (frame.is_pattern()) {
            if (kind == frame.closer) {
                parser.close_pattern_group(group);

                return .operator;
            }
        }

        switch (kind) {
            .comma => return parser.pattern_comma(group),
            .bar => return parser.binary(
                .match_or,
                .bar,
                expression.power_bar_left,
                expression.power_bar_right,
            ),
            .as_keyword => {
                parser.reduce_above(group + 1);

                if (parser.value_count == 0) return .done;

                const checkpoint = parser.values[parser.value_count - 1];

                parser.bump();

                if (!parser.capture()) parser.record(.unexpected_token);

                parser.enclose(checkpoint, .match_as);

                const followed = parser.at(.as_keyword) or parser.at(.bar);

                if (followed) parser.record(.unexpected_token);

                return .operator;
            },
            else => return .done,
        }
    }

    fn pattern_comma(parser: *Parser, group: u32) Step {
        assert(group < parser.frame_count);
        assert(parser.at(.comma));

        const frame = parser.frames[group];

        if (!frame.is_pattern()) {
            if (frame.variant != .top) return .done;
        }

        parser.reduce_above(group + 1);
        parser.bump();
        parser.frames[group].elements += 1;

        const keyed = frame.variant == .mapping or frame.variant == .class_args;

        if (keyed) parser.frames[group].stage = 0;

        return .operand;
    }

    fn descend(parser: *Parser) bool {
        assert(parser.nesting <= nest_depth_max);

        if (parser.nesting >= nest_depth_max) {
            assert(parser.events.outcome == .too_deep);

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

    fn enclose(parser: *Parser, checkpoint: Checkpoint, kind: Kind) void {
        assert(kind.is_node());
        assert(checkpoint.index <= parser.events.count());

        parser.events.start_at(checkpoint, kind);
        parser.events.finish();
    }

    fn literals(parser: *Parser) void {
        assert(parser.tokens.len == parser.raw.len);
        assert(parser.source.len <= std.math.maxInt(u32));

        var runs: Runs = .empty;
        var depth: u32 = 0;

        for (parser.raw, parser.tokens) |kind, token| {
            const text = token.text(parser.source);
            const bit = @as(u64, 1) << @intCast(depth % 64);

            switch (kind) {
                .comment => {},
                .f_string_start => {
                    const template = std.mem.findAny(u8, text, "Tt") != null;
                    const raw = std.mem.findAny(u8, text, "Rr") != null;
                    const inner = @as(u64, 1) << @intCast((depth + 1) % 64);

                    if (runs.joins(bit, if (template) .template else .text)) {
                        parser.record_literal(kind, token);
                    }

                    runs.raws = if (raw) runs.raws | inner else runs.raws & ~inner;

                    runs.clear(inner);
                    depth += 1;
                },
                .f_string_end => depth -|= 1,
                .f_string_middle => {
                    runs.clear(bit);

                    if (depth == 0) continue;
                    if (runs.raws & bit != 0) continue;

                    if (escape.invalid(text, true) != null) parser.record_literal(kind, token);
                },
                .string_bytes, .string_plain => {
                    const part: Part = if (kind == .string_bytes) .bytes else .text;
                    const mixed = runs.joins(bit, part);
                    const faulted = mixed or escape.literal_invalid(text);

                    if (faulted) parser.record_literal(kind, token);
                },
                else => runs.clear(bit),
            }
        }
    }

    fn record_literal(parser: *Parser, kind: Kind, token: Token) void {
        assert(kind.is_token());
        assert(token.end() <= parser.source.len);

        const pushed: Diagnostic = .{
            .expected = null,
            .found = kind.to_u16(),
            .kind = .unexpected_token,
            .span = token.span(),
        };

        parser.tree.push_diagnostic(pushed) catch |err| switch (err) {
            error.Truncated => {
                if (parser.outcome == .complete) parser.outcome = .{ .truncated = .diagnostics };
            },
        };
    }

    fn record(parser: *Parser, kind: Diagnostic.Kind) void {
        assert(kind != .depth_exceeded);

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
        assert(kind.is_token());
        assert(failure != .depth_exceeded);

        if (parser.eat(kind)) return;

        parser.record_expected(failure, kind);
    }

    fn eat(parser: *Parser, kind: Kind) bool {
        assert(kind.is_token());

        if (!parser.at(kind)) return false;

        const before = parser.position;

        parser.bump();

        assert(parser.position > before);

        return true;
    }

    fn wrap(parser: *Parser, kind: Kind) void {
        assert(kind.is_node());
        assert(parser.position <= parser.count());

        parser.events.start(kind);
        parser.bump();
        parser.events.finish();
    }

    fn bump(parser: *Parser) void {
        assert(parser.position <= parser.count());

        parser.skip_trivia();

        const before = parser.position;

        parser.emit();

        if (before < parser.count()) assert(parser.position == before + 1);
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

    fn at(parser: *Parser, kind: Kind) bool {
        assert(kind.is_token());
        assert(parser.position <= parser.count());

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
            if (parser.raw[position] != .comment) break;
        }

        assert(position >= from);
        if (position < parser.raw.len) assert(parser.raw[position] != .comment);

        return position;
    }

    fn kind_at(parser: *Parser, position: u32) ?Kind {
        if (position >= parser.raw.len) return null;

        const kind = parser.raw[position];

        assert(kind.is_token());

        return kind;
    }

    fn count(parser: *const Parser) u32 {
        assert(parser.raw.len <= std.math.maxInt(u32));
        assert(parser.tokens.len == parser.raw.len);

        return @intCast(parser.raw.len);
    }

    fn steps(parser: *const Parser) u32 {
        const returned = parser.count() + 1;

        assert(returned < std.math.maxInt(u32));

        return returned;
    }
};

const AliasForm = enum {
    bare,
    dotted,
    enclosed,
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

const Options = struct {
    tuple: bool,
    no_in: bool,
    lone: bool = true,
    named: bool = false,
    unpacks: bool = false,
    yields: bool = false,
};

const Progress = struct {
    frame_count: u32,
    position: u32,
    value_count: u32,
};

const Shape = struct {
    annotation: ?u32,
    assign: ?u32,
    augmented: ?u32,
};

const Task = union(enum) {
    block: Block,
    compound: Compound,
    else_clause: ElseClause,
    if_statement: If,
    match_statement: Match,
    statements: Statements,
    try_statement: Try,
};

const Block = struct {
    stage: enum { start, statements } = .start,
};

const Compound = struct {
    stage: enum { start, body, alternate } = .start,
    kind: Kind,
};

const ElseClause = struct {
    stage: enum { start, body } = .start,
};

const If = struct {
    stage: enum { start, branch, alternate } = .start,
    opened: u32 = 0,
};

const Match = struct {
    stage: enum { start, case } = .start,
    iteration: u32 = 0,
};

const Statements = struct {
    stage: enum { loop, statement } = .loop,
    before: u32 = 0,
    iteration: u32 = 0,
};

const Try = struct {
    stage: enum { start, handlers, handler, alternate, finally } = .start,
    checkpoint: ?Checkpoint = null,
    iteration: u32 = 0,
    plain: bool = false,
    starred: bool = false,
};

const field_stage_converted: u8 = 2;
const field_stage_debug: u8 = 1;
const field_stage_expression: u8 = 0;
const field_stage_spec: u8 = 3;
const slice_colon_count_max: u8 = 2;
const nest_depth_max: u32 = 1 << 14;
const task_chain_max: u32 = 4;
const task_count_max: u32 = (nest_depth_max + 1) * task_chain_max;
const pattern_step_max: u32 = 4_096;
const machine_step_max: u32 = std.math.maxInt(u32);
const resume_count_max: u64 = std.math.maxInt(u32);
const position_none: u32 = std.math.maxInt(u32);
const options_named: Options = .{ .tuple = false, .no_in = false, .named = true };
const options_single: Options = .{ .tuple = false, .no_in = false };
const options_starred: Options = .{ .tuple = false, .no_in = false, .unpacks = true };
const options_subject: Options = .{ .tuple = true, .no_in = false, .lone = false, .named = true };
const options_target: Options = .{ .tuple = true, .no_in = true };
const options_tuple: Options = .{ .tuple = true, .no_in = false };
const options_valued: Options = .{ .tuple = true, .no_in = false, .yields = true };

const augmented_kinds = [_]Kind{
    .ampersand_equal,
    .at_equal,
    .bar_equal,
    .caret_equal,
    .greater_greater_equal,
    .less_less_equal,
    .minus_equal,
    .percent_equal,
    .plus_equal,
    .slash_equal,
    .slash_slash_equal,
    .star_equal,
    .star_star_equal,
};

comptime {
    assert(nest_depth_max + 2 > frame_depth_max);
    assert(task_count_max > nest_depth_max * task_chain_max);
    assert(augmented_kinds.len == 13);
}

fn compound_of(kind: Kind) Task {
    assert(kind.is_node());
    assert(kind.category() != .other);

    return .{ .compound = .{ .kind = kind } };
}

fn has_else(kind: Kind) bool {
    assert(kind.is_node());

    return switch (kind) {
        .async_for, .@"for", .@"while" => true,
        else => false,
    };
}

fn group_kind(frame: *const Frame, seen: u32) Kind {
    assert(frame.is_group());

    return switch (frame.variant) {
        .brace => brace_kind(frame, seen),
        .bracket => if (frame.comprehension) .list_comp else .list,
        .call => .call,
        .paren => paren_kind(frame, seen),
        .subscript => .subscript,
        else => .error_node,
    };
}

fn brace_kind(frame: *const Frame, seen: u32) Kind {
    assert(frame.variant == .brace);

    if (frame.comprehension) {
        if (frame.dictionary) return .dict_comp;
        return .set_comp;
    }

    if (frame.dictionary) return .dict;

    const empty = seen == 0 and frame.elements == 0;
    if (empty) return .dict;
    return .set;
}

fn paren_kind(frame: *const Frame, seen: u32) Kind {
    assert(frame.variant == .paren);

    if (frame.comprehension) return .generator_exp;

    const single = seen == 1 and frame.elements == 0;
    if (single) return .parenthesized;
    return .tuple;
}

fn closes_operand(kind: Kind) bool {
    assert(kind.is_token());

    if (expression.is_literal(kind)) return true;
    if (is_closer(kind)) return true;
    return kind == .identifier or kind == .f_string_end;
}

fn is_unary_kind(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .await_keyword, .lambda_keyword, .minus, .not_keyword, .plus, .tilde => true,
        else => false,
    };

    if (result) assert(kind.is_token());

    return result;
}

fn is_number(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .number_binary,
        .number_complex,
        .number_float,
        .number_hexadecimal,
        .number_integer,
        .number_octal,
        => true,
        else => false,
    };

    if (result) assert(kind.is_token());

    return result;
}

fn is_augmented(kind: Kind) bool {
    assert(kind.is_token());

    return std.mem.findScalar(Kind, &augmented_kinds, kind) != null;
}

fn is_layout(kind: Kind) bool {
    assert(kind.is_token());

    return switch (kind) {
        .comment, .dedent, .indent, .newline => true,
        else => false,
    };
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

test "a nesting past the statement bound stays too deep" {
    const gpa = std.testing.allocator;
    const level = "if a:\n @d\n";
    const level_count = nest_depth_max + 8;
    const source = try gpa.alloc(u8, level.len * level_count);
    defer gpa.free(source);

    for (0..level_count) |index| @memcpy(source[index * level.len ..][0..level.len], level);

    var out: Tokens = try .init(gpa, 1 << 18);
    defer out.deinit(gpa);

    var raw: ArrayType(Kind) = try .init(gpa, 1 << 18);
    defer raw.deinit(gpa);

    var events: Events = undefined;

    try events.init(gpa, 1 << 21);
    defer events.deinit(gpa);

    var tree: Tree = try .init(gpa, 1 << 18, 1 << 17);
    defer tree.deinit(gpa);

    const parser = try gpa.create(Parser);
    defer gpa.destroy(parser);

    try lex(source, &out);
    try raw_of(Kind, out.slice(), &raw);

    const structure = parser.build(source, out.slice(), raw.const_slice(), &events, &tree);

    try std.testing.expectEqual(Structure.too_deep, structure);
    try std.testing.expectEqual(Structure.too_deep, events.outcome);
    try std.testing.expectEqual(Kind.module, tree.kind_at(0));
}

test "a dedent eaten by a stray decorator keeps the block open" {
    const gpa = std.testing.allocator;
    const source = "if a:\n @d\nb\n";
    var out: Tokens = try .init(gpa, 64);
    defer out.deinit(gpa);

    var raw: ArrayType(Kind) = try .init(gpa, 64);
    defer raw.deinit(gpa);

    var events: Events = undefined;

    try events.init(gpa, 256);
    defer events.deinit(gpa);

    var tree: Tree = try .init(gpa, 64, 16);
    defer tree.deinit(gpa);

    const parser = try gpa.create(Parser);
    defer gpa.destroy(parser);

    try lex(source, &out);
    try raw_of(Kind, out.slice(), &raw);

    const structure = parser.build(source, out.slice(), raw.const_slice(), &events, &tree);

    const expected = [_]Kind{
        .module,
        .@"if",
        .name_node,
        .block,
        .decorator,
        .name_node,
        .error_node,
        .expr,
        .name_node,
    };

    try std.testing.expectEqual(Structure.complete, structure);
    try std.testing.expectEqual(expected.len, tree.count());
    try std.testing.expectEqual(2, tree.diagnostic_slice().len);

    for (expected, 0..) |kind, index| {
        try std.testing.expectEqual(kind, tree.kind_at(@intCast(index)));
    }
}
