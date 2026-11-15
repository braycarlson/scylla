const std = @import("std");
const assert = std.debug.assert;
const Kind = @import("kind.zig").Kind;
const Lexeme = @import("check_tokenizer.zig").Lexeme;
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const Tag = @import("check_tokenizer.zig").Tag;
const Tokenizer = @import("check_tokenizer.zig").Tokenizer;

pub const Failure = struct {
    expected: ?Kind,
    kind: Diagnostic.Kind,
    offset: u32,
};

pub const Checker = struct {
    exhausted: bool,
    failure: ?Failure,
    frame_count: u32,
    frames: [frame_count_max]Frame,
    position: u32,
    produced: u32,
    result: Result,
    ring: [ring_size]Lexeme,
    scratch: [scratch_count_max]u32,
    scratch_count: u32,
    source: []const u8,
    tokenizer: Tokenizer,

    pub fn check(checker: *Checker, source: []const u8) ?Failure {
        assert(source.len < std.math.maxInt(u32));

        checker.reset(source);

        const steps = (@as(u64, source.len) + step_padding) * step_count_per_byte;
        var step: u64 = 0;

        while (checker.frame_count > 0) : (step += 1) {
            assert(step < steps);

            if (checker.failure != null) break;
            if (checker.exhausted) return null;

            checker.advance();
        }

        if (checker.exhausted) return null;
        return checker.failure;
    }

    fn reset(checker: *Checker, source: []const u8) void {
        assert(source.len < std.math.maxInt(u32));

        checker.exhausted = false;
        checker.failure = null;
        checker.frame_count = 0;
        checker.position = 0;
        checker.produced = 0;
        checker.result = .absent;
        checker.scratch_count = 0;
        checker.source = source;
        checker.tokenizer = .init(source);
        checker.frames[0] = .of(.root, .{});
        checker.frame_count = 1;

        assert(checker.frame_count == 1);
    }

    fn advance(checker: *Checker) void {
        assert(checker.frame_count > 0);
        assert(checker.failure == null);

        const frame = &checker.frames[checker.frame_count - 1];

        switch (frame.proc) {
            .assign => checker.assign(frame),
            .asm_input => checker.asm_input(frame),
            .asm_output => checker.asm_output(frame),
            .assembly => checker.assembly(frame),
            .attribute => checker.attribute(frame),
            .block => checker.block(frame),
            .block_statement => checker.block_statement(frame),
            .builtin_call => checker.builtin_call(frame),
            .container => checker.container(frame),
            .container_field => checker.container_field(frame),
            .continued => checker.continued(frame),
            .curly => checker.curly(frame),
            .declaration => checker.declaration(frame),
            .error_union => checker.error_union(frame),
            .expression => checker.expression(frame),
            .for_expression => checker.for_expression(frame),
            .for_prefix => checker.for_prefix(frame),
            .for_statement => checker.for_statement(frame),
            .function => checker.function(frame),
            .global => checker.global(frame),
            .if_expression => checker.if_expression(frame),
            .if_statement => checker.if_statement(frame),
            .init_list => checker.init_list(frame),
            .labeled => checker.labeled(frame),
            .loop_statement => checker.loop_statement(frame),
            .members => checker.members(frame),
            .parameters => checker.parameters(frame),
            .primary => checker.primary(frame),
            .primary_type => checker.primary_type(frame),
            .prong => checker.prong(frame),
            .prongs => checker.prongs(frame),
            .root => checker.root(frame),
            .single_assign => checker.single_assign(frame),
            .statement => checker.statement(frame),
            .suffix => checker.suffix(frame),
            .switch_expression => checker.switch_expression(frame),
            .test_declaration => checker.test_declaration(frame),
            .type_expression => checker.type_expression(frame),
            .variable => checker.variable(frame),
            .variable_statement => checker.variable_statement(frame),
            .while_expression => checker.while_expression(frame),
            .while_statement => checker.while_statement(frame),
        }
    }

    fn root(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .root);
        assert(checker.frame_count == 1);

        switch (frame.stage) {
            0 => checker.call(frame, 1, .members, .{}),
            1 => {
                if (checker.current() != .eof) return checker.fail_token(.eof);

                checker.returns(frame, false, offset_none);
            },
            else => unreachable,
        }
    }

    fn members(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .members);
        assert(frame.slots[slot_state] <= field_state_error);

        stage: switch (frame.stage) {
            0 => {
                for (0..checker.steps_bound()) |_| {
                    if (!checker.eat(.container_doc_comment)) break;
                }

                continue :stage 1;
            },
            1 => checker.members_open(frame),
            2 => {
                if (checker.result.present) checker.members_declared(frame, checker.result.main);

                continue :stage 1;
            },
            3 => {
                checker.members_declared(frame, frame.slots[slot_main]);

                continue :stage 1;
            },
            4 => checker.members_field(frame),
            else => unreachable,
        }
    }

    fn members_open(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .members);
        assert(frame.stage <= 4);

        const doc = checker.doc_comments() orelse offset_none;

        if (checker.failure != null) return;

        switch (checker.current()) {
            .test_keyword => {
                if (doc != offset_none) return checker.fail_at(doc, .doc_comment_on_test);

                checker.call(frame, 2, .test_declaration, .{});
            },
            .comptime_keyword => {
                if (checker.peek(1) != .brace_open) return checker.members_field_open(frame);
                if (doc != offset_none) return checker.fail_at(doc, .doc_comment_on_comptime);

                frame.slots[slot_main] = checker.here();

                checker.bump();
                checker.call(frame, 3, .block, .{});
            },
            .eof, .brace_close => {
                if (doc != offset_none) return checker.fail_at(doc, .doc_comment_unattached);

                checker.returns(frame, false, offset_none);
            },
            else => |tag| checker.members_other(frame, tag),
        }
    }

    fn members_other(checker: *Checker, frame: *Frame, tag: Tag) void {
        assert(frame.proc == .members);
        assert(tag != .eof);

        switch (tag) {
            .pub_keyword,
            .const_keyword,
            .var_keyword,
            .threadlocal_keyword,
            .export_keyword,
            .extern_keyword,
            .inline_keyword,
            .noinline_keyword,
            .fn_keyword,
            => {
                if (tag == .extern_keyword) {
                    const contained = checker.peek(1).is_container_keyword();
                    if (contained) return checker.members_field_open(frame);
                }

                if (tag == .inline_keyword) {
                    const looped = checker.peek(1).is_loop_keyword();
                    if (looped) return checker.members_field_open(frame);
                }

                if (tag == .pub_keyword) checker.bump();

                checker.call(frame, 2, .declaration, .{});
            },
            else => {
                if (checker.c_style()) return;

                checker.members_field_open(frame);
            },
        }
    }

    fn members_field_open(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .members);
        assert(checker.failure == null);

        checker.call(frame, 4, .container_field, .{});
    }

    fn members_field(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .members);
        assert(checker.result.present);

        switch (frame.slots[slot_state]) {
            field_state_none => frame.slots[slot_state] = field_state_seen,
            field_state_seen, field_state_error => {},
            field_state_end => {
                return checker.fail_at(frame.slots[slot_end], .declaration_between_fields);
            },
            else => unreachable,
        }

        switch (checker.current()) {
            .comma => {
                checker.bump();
                frame.stage = 1;
            },
            .brace_close, .eof => checker.returns(frame, false, offset_none),
            else => checker.fail(.comma_after_field_expected),
        }
    }

    fn members_declared(checker: *const Checker, frame: *Frame, main: u32) void {
        assert(frame.proc == .members);
        assert(checker.failure == null);
        assert(main < std.math.maxInt(u32));

        if (frame.slots[slot_state] != field_state_seen) return;

        frame.slots[slot_state] = field_state_end;
        frame.slots[slot_end] = main;
    }

    fn c_style(checker: *Checker) bool {
        assert(checker.failure == null);

        switch (checker.current()) {
            .enum_keyword, .union_keyword, .struct_keyword => {},
            else => return false,
        }

        if (checker.peek(1) != .identifier) return false;

        checker.bump();

        const identifier = checker.here();

        checker.bump();
        checker.fail_at(identifier, .container_in_c_style);

        return true;
    }

    fn test_declaration(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .test_declaration);
        assert(frame.stage <= 1);

        switch (frame.stage) {
            0 => {
                assert(checker.current() == .test_keyword);

                frame.slots[slot_main] = checker.here();

                checker.bump();

                switch (checker.current()) {
                    .text, .identifier => checker.bump(),
                    else => {},
                }

                if (checker.current() != .brace_open) return checker.fail(.block_expected);

                checker.call(frame, 1, .block, .{});
            },
            1 => checker.returns(frame, true, frame.slots[slot_main]),
            else => unreachable,
        }
    }

    fn declaration(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .declaration);
        assert(frame.stage <= 4);

        switch (frame.stage) {
            0 => checker.declaration_open(frame),
            1 => switch (checker.current()) {
                .semicolon => {
                    checker.bump();
                    checker.returns(frame, true, checker.result.main);
                },
                .brace_open => {
                    if (frame.mark & mark_extern != 0) {
                        return checker.fail_at(frame.slots[slot_first], .extern_function_body);
                    }

                    frame.slots[slot_main] = checker.result.main;

                    checker.call(frame, 2, .block, .{});
                },
                else => checker.fail(.semicolon_or_brace_expected),
            },
            2 => checker.returns(frame, true, frame.slots[slot_main]),
            3 => checker.declaration_variable(frame),
            4 => checker.returns(frame, true, checker.result.main),
            else => unreachable,
        }
    }

    fn declaration_open(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .declaration);
        assert(frame.stage == 0);

        frame.slots[slot_first] = checker.here();

        switch (checker.current()) {
            .extern_keyword => {
                checker.bump();
                _ = checker.eat(.text);
                frame.mark |= mark_extern | mark_variable_or_function;
            },
            .export_keyword => {
                checker.bump();
                frame.mark |= mark_variable_or_function;
            },
            .inline_keyword, .noinline_keyword => {
                checker.bump();
                frame.mark |= mark_function;
            },
            else => {},
        }

        if (checker.current() == .fn_keyword) return checker.call(frame, 1, .function, .{});

        frame.stage = 3;
    }

    fn declaration_variable(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .declaration);
        assert(frame.stage == 3);

        if (frame.mark & mark_function != 0) return checker.fail(.function_expected);

        const local = checker.eat(.threadlocal_keyword);

        switch (checker.current()) {
            .const_keyword, .var_keyword => return checker.call(frame, 4, .global, .{}),
            else => {},
        }

        if (local) return checker.fail(.variable_expected);

        if (frame.mark & mark_variable_or_function != 0) {
            return checker.fail(.variable_or_function_expected);
        }

        checker.fail(.public_item_expected);
    }

    fn function(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .function);
        assert(frame.stage <= 6);

        stage: switch (frame.stage) {
            0 => {
                assert(checker.current() == .fn_keyword);

                frame.slots[slot_main] = checker.here();

                checker.bump();
                _ = checker.eat(.identifier);

                checker.call(frame, 1, .parameters, .{});
            },
            1 => {
                if (checker.current() == .align_keyword) {
                    return checker.call(frame, 2, .attribute, .{});
                }

                continue :stage 2;
            },
            2 => {
                if (checker.current() == .addrspace_keyword) {
                    return checker.call(frame, 3, .attribute, .{});
                }

                continue :stage 3;
            },
            3 => {
                if (checker.current() == .linksection_keyword) {
                    return checker.call(frame, 4, .attribute, .{});
                }

                continue :stage 4;
            },
            4 => {
                if (checker.current() == .callconv_keyword) {
                    return checker.call(frame, 5, .attribute, .{});
                }

                continue :stage 5;
            },
            5 => {
                _ = checker.eat(.bang);

                checker.call(frame, 6, .type_expression, .{});
            },
            6 => {
                if (!checker.result.present) return checker.fail(.return_type_expected);

                checker.returns(frame, true, frame.slots[slot_main]);
            },
            else => unreachable,
        }
    }

    fn attribute(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .attribute);
        assert(frame.stage <= 1);

        switch (frame.stage) {
            0 => {
                assert(checker.current().is_attribute_keyword());

                checker.bump();

                if (!checker.expect(.paren_open)) return;

                checker.call_expression(frame, 1, 0);
            },
            1 => {
                if (!checker.result.present) return checker.fail(.expression_expected);
                if (!checker.expect(.paren_close)) return;

                checker.returns(frame, true, offset_none);
            },
            else => unreachable,
        }
    }

    fn parameters(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .parameters);
        assert(frame.slots[slot_state] <= varargs_nonfinal);

        stage: switch (frame.stage) {
            0 => {
                if (!checker.expect(.paren_open)) return;

                continue :stage 1;
            },
            1 => {
                if (checker.eat(.paren_close)) continue :stage 3;

                checker.parameters_open(frame);
            },
            2 => checker.parameters_separator(frame),
            3 => {
                if (frame.slots[slot_state] == varargs_nonfinal) {
                    return checker.fail_at(frame.slots[slot_end], .varargs_not_final);
                }

                checker.returns(frame, true, offset_none);
            },
            else => unreachable,
        }
    }

    fn parameters_open(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .parameters);
        assert(frame.stage <= 1);

        if (frame.slots[slot_state] == varargs_seen) {
            frame.slots[slot_state] = varargs_nonfinal;
            frame.slots[slot_end] = checker.here();
        }

        _ = checker.doc_comments();

        if (checker.failure != null) return;

        switch (checker.current()) {
            .noalias_keyword, .comptime_keyword => checker.bump(),
            .dot_dot_dot => {
                checker.bump();

                if (frame.slots[slot_state] == varargs_none) frame.slots[slot_state] = varargs_seen;

                frame.stage = 2;

                return;
            },
            else => {},
        }

        _ = checker.eat_pair(.identifier, .colon);

        if (checker.eat(.anytype_keyword)) {
            frame.stage = 2;

            return;
        }

        checker.call(frame, 2, .type_expression, .{ .expect = true });
    }

    fn parameters_separator(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .parameters);
        assert(frame.stage == 2);

        switch (checker.current()) {
            .comma => {
                checker.bump();
                frame.stage = 1;
            },
            .paren_close => {
                checker.bump();
                frame.stage = 3;
            },
            .colon, .brace_close, .bracket_close => checker.fail_token(.paren_close),
            else => checker.fail(.comma_after_parameter_expected),
        }
    }

    fn variable(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .variable);
        assert(frame.stage <= 4);

        stage: switch (frame.stage) {
            0 => {
                assert(checker.current().is_declaration_keyword());

                frame.slots[slot_main] = checker.here();

                checker.bump();

                if (!checker.expect(.identifier)) return;

                if (checker.eat(.colon)) {
                    return checker.call(frame, 1, .type_expression, .{ .expect = true });
                }

                continue :stage 1;
            },
            1 => {
                if (checker.current() == .align_keyword) {
                    return checker.call(frame, 2, .attribute, .{});
                }

                continue :stage 2;
            },
            2 => {
                if (checker.current() == .addrspace_keyword) {
                    return checker.call(frame, 3, .attribute, .{});
                }

                continue :stage 3;
            },
            3 => {
                if (checker.current() == .linksection_keyword) {
                    return checker.call(frame, 4, .attribute, .{});
                }

                continue :stage 4;
            },
            4 => checker.returns(frame, true, frame.slots[slot_main]),
            else => unreachable,
        }
    }

    fn global(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .global);
        assert(frame.stage <= 3);

        stage: switch (frame.stage) {
            0 => checker.call(frame, 1, .variable, .{}),
            1 => {
                frame.slots[slot_main] = checker.result.main;

                switch (checker.current()) {
                    .equal_equal => return checker.fail(.equal_equal_in_declaration),
                    .equal => {
                        checker.bump();

                        return checker.call_expression(frame, 2, 0);
                    },
                    else => continue :stage 3,
                }
            },
            2 => {
                if (!checker.result.present) return checker.fail(.expression_expected);

                continue :stage 3;
            },
            3 => {
                if (!checker.eat(.semicolon)) {
                    return checker.fail(.semicolon_after_declaration_expected);
                }

                checker.returns(frame, true, frame.slots[slot_main]);
            },
            else => unreachable,
        }
    }

    fn container_field(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .container_field);
        assert(frame.stage <= 3);

        stage: switch (frame.stage) {
            0 => {
                _ = checker.eat(.comptime_keyword);
                _ = checker.eat_pair(.identifier, .colon);

                checker.call(frame, 1, .type_expression, .{ .expect = true });
            },
            1 => {
                if (checker.current() == .align_keyword) {
                    return checker.call(frame, 2, .attribute, .{});
                }

                continue :stage 2;
            },
            2 => {
                if (checker.eat(.equal)) return checker.call_expression(frame, 3, 0);

                checker.returns(frame, true, offset_none);
            },
            3 => {
                if (!checker.result.present) return checker.fail(.expression_expected);

                checker.returns(frame, true, offset_none);
            },
            else => unreachable,
        }
    }

    fn statement(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .statement);
        assert(frame.stage <= 4);

        switch (frame.stage) {
            0 => checker.statement_open(frame),
            1 => checker.returns(frame, true, offset_none),
            2 => {
                if (!checker.result.present) {
                    return checker.fail(.expression_or_assignment_expected);
                }

                checker.semicolon_closed(frame);
            },
            3 => {
                if (checker.result.present) return checker.returns(frame, true, offset_none);
                if (frame.flags.block_level) return checker.tail(frame, .variable_statement, .{});

                checker.call(frame, 2, .assign, .{});
            },
            else => unreachable,
        }
    }

    fn statement_open(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .statement);
        assert(frame.stage == 0);

        if (checker.eat(.comptime_keyword)) {
            if (checker.block_expression_open(frame, 1)) return;
            if (frame.flags.block_level) return checker.tail(frame, .variable_statement, .{});
            return checker.call(frame, 2, .assign, .{});
        }

        switch (checker.current()) {
            .nosuspend_keyword, .suspend_keyword => {
                checker.bump();

                return checker.tail(frame, .block_statement, .{});
            },
            .defer_keyword => if (frame.flags.block_level) {
                checker.bump();

                return checker.tail(frame, .block_statement, .{});
            },
            .errdefer_keyword => if (frame.flags.block_level) {
                checker.bump();

                if (!checker.payload()) return;
                return checker.tail(frame, .block_statement, .{});
            },
            .if_keyword => return checker.tail(frame, .if_statement, .{}),
            .enum_keyword, .struct_keyword, .union_keyword => if (checker.c_style()) return,
            else => {},
        }

        checker.call(frame, 3, .labeled, .{});
    }

    fn block_expression_open(checker: *Checker, frame: *Frame, stage: u8) bool {
        assert(checker.failure == null);
        assert(stage > frame.stage);

        switch (checker.current()) {
            .identifier => {
                if (checker.peek(1) != .colon) return false;
                if (checker.peek(2) != .brace_open) return false;

                checker.bump();
                checker.bump();
            },
            .brace_open => {},
            else => return false,
        }

        checker.call(frame, stage, .block, .{});

        return true;
    }

    fn semicolon_closed(checker: *Checker, frame: *Frame) void {
        assert(checker.failure == null);
        assert(frame.stage > 0);

        if (!checker.eat(.semicolon)) return checker.fail(.semicolon_after_statement_expected);

        checker.returns(frame, true, offset_none);
    }

    fn labeled(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .labeled);
        assert(frame.stage <= 6);

        stage: switch (frame.stage) {
            0 => checker.labeled_open(frame),
            1 => {
                if (!checker.result.present) {
                    return checker.fail_at(frame.slots[slot_after], .labelable_expected);
                }

                if (checker.current() == .align_keyword) {
                    frame.mark |= mark_attributed;

                    return checker.call(frame, 2, .attribute, .{});
                }

                continue :stage 2;
            },
            2 => {
                if (checker.current() == .addrspace_keyword) {
                    frame.mark |= mark_attributed;

                    return checker.call(frame, 3, .attribute, .{});
                }

                continue :stage 3;
            },
            3 => {
                if (checker.current() == .linksection_keyword) {
                    frame.mark |= mark_attributed;

                    return checker.call(frame, 4, .attribute, .{});
                }

                continue :stage 4;
            },
            4 => {
                if (checker.eat(.equal)) return checker.call_expression(frame, 5, 0);

                continue :stage 6;
            },
            5 => {
                if (!checker.result.present) return checker.fail(.expression_expected);

                frame.mark |= mark_attributed;

                continue :stage 6;
            },
            6 => checker.labeled_failed(frame),
            else => unreachable,
        }
    }

    fn labeled_open(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .labeled);
        assert(frame.stage == 0);

        const label = checker.here();
        const labelled = checker.eat_pair(.identifier, .colon);

        switch (checker.current()) {
            .brace_open => return checker.tail(frame, .block, .{}),
            .inline_keyword, .for_keyword, .while_keyword => {
                return checker.tail(frame, .loop_statement, .{});
            },
            .switch_keyword => {
                const main = if (labelled) label else checker.here();

                checker.tail(frame, .switch_expression, .{});
                frame.slots[slot_main] = main;

                return;
            },
            else => {},
        }

        if (!labelled) return checker.returns(frame, false, offset_none);

        frame.slots[slot_label] = label;
        frame.slots[slot_after] = checker.here();

        checker.call(frame, 1, .type_expression, .{});
    }

    fn labeled_failed(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .labeled);
        assert(frame.stage >= 1);

        if (frame.mark & mark_attributed != 0) {
            return checker.fail_at(frame.slots[slot_label], .variable_constant_expected);
        }

        checker.fail_at(frame.slots[slot_after], .labelable_expected);
    }

    fn loop_statement(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .loop_statement);
        assert(frame.stage == 0);

        const inlined = checker.eat(.inline_keyword);

        switch (checker.current()) {
            .for_keyword => return checker.tail(frame, .for_statement, .{}),
            .while_keyword => return checker.tail(frame, .while_statement, .{}),
            else => {},
        }

        if (inlined) return checker.fail(.inlinable_expected);

        checker.returns(frame, false, offset_none);
    }

    fn for_statement(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .for_statement);
        assert(frame.stage <= 4);

        stage: switch (frame.stage) {
            0 => {
                assert(checker.current() == .for_keyword);

                checker.bump();
                checker.call(frame, 1, .for_prefix, .{});
            },
            1 => {
                if (checker.block_expression_open(frame, 3)) return;

                checker.call(frame, 2, .assign, .{});
            },
            2 => {
                if (!checker.result.present) return checker.fail(.block_or_assignment_expected);

                if (checker.eat(.semicolon)) {
                    frame.flags.semicolon_seen = true;
                } else {
                    frame.flags.else_required = true;
                }

                continue :stage 3;
            },
            3 => {
                if (!frame.flags.semicolon_seen) {
                    if (checker.eat(.else_keyword)) {
                        return checker.call(frame, 4, .statement, .{});
                    }
                }

                if (frame.flags.else_required) return checker.fail(.semicolon_or_else_expected);

                checker.returns(frame, true, offset_none);
            },
            4 => checker.returns(frame, true, offset_none),
            else => unreachable,
        }
    }

    fn while_statement(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .while_statement);
        assert(frame.stage <= 6);

        stage: switch (frame.stage) {
            0 => {
                assert(checker.current() == .while_keyword);

                checker.bump();

                if (!checker.expect(.paren_open)) return;

                checker.call_expression(frame, 1, 0);
            },
            1 => {
                if (!checker.condition_closed()) return;
                if (checker.current() == .colon) return checker.call(frame, 2, .continued, .{});

                continue :stage 2;
            },
            2 => {
                if (checker.block_expression_open(frame, 4)) return;

                checker.call(frame, 3, .assign, .{});
            },
            3 => {
                if (!checker.result.present) return checker.fail(.block_or_assignment_expected);
                if (checker.eat(.semicolon)) return checker.returns(frame, true, offset_none);

                frame.flags.else_required = true;

                continue :stage 4;
            },
            4 => {
                if (checker.eat(.else_keyword)) {
                    if (!checker.payload()) return;
                    return checker.call(frame, 5, .statement, .{});
                }

                if (frame.flags.else_required) return checker.fail(.semicolon_or_else_expected);

                checker.returns(frame, true, offset_none);
            },
            5 => checker.returns(frame, true, offset_none),
            else => unreachable,
        }
    }

    fn condition_closed(checker: *Checker) bool {
        assert(checker.failure == null);
        assert(checker.frame_count > 0);

        if (!checker.result.present) {
            checker.fail(.expression_expected);

            return false;
        }

        if (!checker.expect(.paren_close)) return false;
        return checker.pointer_payload();
    }

    fn if_statement(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .if_statement);
        assert(frame.stage <= 4);

        stage: switch (frame.stage) {
            0 => {
                assert(checker.current() == .if_keyword);

                checker.bump();

                if (!checker.expect(.paren_open)) return;

                checker.call_expression(frame, 1, 0);
            },
            1 => {
                if (!checker.condition_closed()) return;
                if (checker.block_expression_open(frame, 3)) return;

                checker.call(frame, 2, .assign, .{});
            },
            2 => {
                if (!checker.result.present) return checker.fail(.block_or_assignment_expected);
                if (checker.eat(.semicolon)) return checker.returns(frame, true, offset_none);

                frame.flags.else_required = true;

                continue :stage 3;
            },
            3 => {
                if (checker.eat(.else_keyword)) {
                    if (!checker.payload()) return;
                    return checker.call(frame, 4, .statement, .{});
                }

                if (frame.flags.else_required) return checker.fail(.semicolon_or_else_expected);

                checker.returns(frame, true, offset_none);
            },
            4 => checker.returns(frame, true, offset_none),
            else => unreachable,
        }
    }

    fn block_statement(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .block_statement);
        assert(frame.stage <= 1);

        switch (frame.stage) {
            0 => {
                if (checker.current() == .identifier) {
                    if (checker.peek(1) == .colon) {
                        if (checker.peek(2) == .brace_open) {
                            checker.bump();
                            checker.bump();

                            return checker.tail(frame, .block, .{});
                        }
                    }
                }

                if (checker.current() == .brace_open) return checker.tail(frame, .block, .{});

                checker.call(frame, 1, .assign, .{});
            },
            1 => {
                if (!checker.result.present) return checker.fail(.block_or_expression_expected);

                checker.semicolon_closed(frame);
            },
            else => unreachable,
        }
    }

    fn variable_statement(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .variable_statement);
        assert(frame.stage <= 6);

        stage: switch (frame.stage) {
            0 => {
                if (checker.current().is_declaration_keyword()) {
                    return checker.call(frame, 1, .variable, .{});
                }

                checker.call_expression(frame, 2, 0);
            },
            1 => {
                if (frame.slots[slot_count] == 0) frame.mark |= mark_declared;

                frame.slots[slot_count] += 1;

                continue :stage 3;
            },
            2 => {
                if (!checker.result.present) {
                    if (frame.slots[slot_count] == 0) return checker.fail(.statement_expected);
                    return checker.fail(.expression_or_variable_expected);
                }

                frame.slots[slot_count] += 1;

                continue :stage 3;
            },
            3 => {
                if (checker.eat(.comma)) continue :stage 0;
                if (checker.eat(.equal)) return checker.call_expression(frame, 4, 0);

                checker.variable_statement_unassigned(frame);
            },
            4 => {
                if (!checker.result.present) return checker.fail(.expression_expected);

                checker.semicolon_closed(frame);
            },
            else => unreachable,
        }
    }

    fn variable_statement_unassigned(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .variable_statement);
        assert(frame.slots[slot_count] > 0);

        const declared = frame.mark & mark_declared != 0;
        const definite = frame.slots[slot_count] > 1 or declared;

        if (definite) {
            if (checker.current() == .equal_equal) return checker.fail(.equal_equal_in_declaration);
            return checker.fail_token(.equal);
        }

        if (checker.current().is_compound()) {
            checker.bump();

            return checker.call_expression(frame, 4, 0);
        }

        checker.semicolon_closed(frame);
    }

    fn assign(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .assign);
        assert(frame.stage <= 4);

        stage: switch (frame.stage) {
            0 => checker.call_expression(frame, 1, 0),
            1 => {
                if (!checker.result.present) return checker.returns(frame, false, offset_none);

                frame.slots[slot_main] = checker.result.main;

                if (checker.current() == .comma) continue :stage 2;

                if (checker.current().is_assignment()) {
                    checker.bump();

                    return checker.call_expression(frame, 4, 0);
                }

                checker.returns(frame, true, frame.slots[slot_main]);
            },
            2 => {
                if (checker.eat(.comma)) return checker.call_expression(frame, 3, 0);
                if (!checker.expect(.equal)) return;

                checker.call_expression(frame, 4, 0);
            },
            3 => {
                if (!checker.result.present) return checker.fail(.expression_expected);

                continue :stage 2;
            },
            4 => {
                if (!checker.result.present) return checker.fail(.expression_expected);

                checker.returns(frame, true, frame.slots[slot_main]);
            },
            else => unreachable,
        }
    }

    fn single_assign(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .single_assign);
        assert(frame.stage <= 2);

        switch (frame.stage) {
            0 => checker.call_expression(frame, 1, 0),
            1 => {
                if (!checker.result.present) return checker.returns(frame, false, offset_none);

                frame.slots[slot_main] = checker.result.main;

                if (checker.current().is_assignment()) {
                    checker.bump();

                    return checker.call_expression(frame, 2, 0);
                }

                checker.returns(frame, true, frame.slots[slot_main]);
            },
            2 => {
                if (!checker.result.present) return checker.fail(.expression_expected);

                checker.returns(frame, true, frame.slots[slot_main]);
            },
            else => unreachable,
        }
    }

    fn expression(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .expression);
        assert(frame.slots[slot_precedence] <= precedence_max);

        switch (frame.stage) {
            0 => {
                frame.slots[slot_prefix] = offset_none;

                for (0..checker.steps_bound()) |_| {
                    if (!checker.current().is_prefix()) break;

                    if (frame.slots[slot_prefix] == offset_none) {
                        frame.slots[slot_prefix] = checker.here();
                    }

                    checker.bump();
                }

                checker.call(frame, 1, .primary, .{});
            },
            1 => {
                const prefixed = frame.slots[slot_prefix] != offset_none;

                if (!checker.result.present) {
                    if (prefixed) return checker.fail(.prefix_expression_expected);
                    return checker.returns(frame, false, offset_none);
                }

                const main = if (prefixed) frame.slots[slot_prefix] else checker.result.main;

                frame.slots[slot_main] = main;
                frame.slots[slot_banned] = precedence_none;
                frame.stage = 2;
            },
            2 => checker.expression_operator(frame),
            3 => checker.expression_operand(frame),
            else => unreachable,
        }
    }

    fn expression_operator(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .expression);
        assert(frame.stage == 2);

        const tag = checker.current();

        const operator = operator_of(tag) orelse {
            return checker.returns(frame, true, frame.slots[slot_main]);
        };

        if (operator.precedence < frame.slots[slot_precedence]) {
            return checker.returns(frame, true, frame.slots[slot_main]);
        }

        if (operator.precedence == frame.slots[slot_banned]) {
            return checker.fail(.comparison_chained);
        }

        frame.slots[slot_operator] = checker.here();
        frame.mark = @backingInt(tag);

        checker.bump();

        if (tag == .catch_keyword) {
            if (!checker.payload()) return;
        }

        checker.call_expression(frame, 3, operator.precedence + 1);
    }

    fn expression_operand(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .expression);
        assert(frame.stage == 3);

        if (!checker.result.present) return checker.fail(.expression_expected);

        const tag: Tag = @fromBackingInt(@intCast(frame.mark));
        const operator = operator_of(tag).?;
        const start = frame.slots[slot_operator];
        const width = tag.width().?;

        assert(start > 0);

        const before = checker.byte_at(start - 1);
        const after = checker.byte_at(start + width);

        if (tag == .ampersand) {
            if (after == '&') return checker.fail_at(start, .ampersand_ampersand);
        }

        if (is_whitespace(before) != is_whitespace(after)) {
            return checker.fail_at(start, .operator_whitespace_mismatched);
        }

        frame.slots[slot_main] = start;

        if (!operator.associative) frame.slots[slot_banned] = operator.precedence;

        frame.stage = 2;
    }

    fn primary(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .primary);
        assert(frame.stage <= 2);

        switch (frame.stage) {
            0 => checker.primary_open(frame),
            1 => checker.returns(frame, true, frame.slots[slot_main]),
            2 => {
                if (!checker.result.present) return checker.fail(.expression_expected);

                checker.returns(frame, true, frame.slots[slot_main]);
            },
            else => unreachable,
        }
    }

    fn primary_open(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .primary);
        assert(frame.stage == 0);

        frame.slots[slot_main] = checker.here();

        switch (checker.current()) {
            .asm_keyword => checker.tail(frame, .assembly, .{}),
            .if_keyword => checker.tail(frame, .if_expression, .{}),
            .break_keyword, .continue_keyword => {
                checker.bump();
                _ = checker.eat_pair(.colon, .identifier);

                checker.call_expression(frame, 1, 0);
            },
            .comptime_keyword, .nosuspend_keyword, .resume_keyword => {
                checker.bump();
                checker.call_expression(frame, 2, 0);
            },
            .return_keyword => {
                checker.bump();
                checker.call_expression(frame, 1, 0);
            },
            .identifier => checker.primary_identifier(frame),
            .inline_keyword => {
                checker.bump();
                checker.loop_inlined(frame, .{});
            },
            .for_keyword => checker.tail(frame, .for_expression, .{}),
            .while_keyword => checker.tail(frame, .while_expression, .{}),
            .brace_open => checker.tail(frame, .block, .{}),
            else => checker.tail(frame, .curly, .{}),
        }
    }

    fn primary_identifier(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .primary);
        assert(checker.current() == .identifier);

        if (checker.peek(1) != .colon) return checker.tail(frame, .curly, .{});

        switch (checker.peek(2)) {
            .inline_keyword => {
                checker.bump();
                checker.bump();
                checker.bump();
                checker.loop_inlined(frame, .{});
            },
            .for_keyword => {
                checker.bump();
                checker.bump();
                checker.tail(frame, .for_expression, .{});
            },
            .while_keyword => {
                checker.bump();
                checker.bump();
                checker.tail(frame, .while_expression, .{});
            },
            else => checker.tail(frame, .curly, .{}),
        }
    }

    fn loop_inlined(checker: *Checker, frame: *Frame, flags: Flags) void {
        assert(checker.failure == null);
        assert(frame.stage == 0);
        assert(!flags.unused);

        switch (checker.current()) {
            .for_keyword => checker.tail(frame, .for_expression, flags),
            .while_keyword => checker.tail(frame, .while_expression, flags),
            else => checker.fail(.inlinable_expected),
        }
    }

    fn if_expression(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .if_expression);
        assert(frame.stage <= 3);

        switch (frame.stage) {
            0 => {
                assert(checker.current() == .if_keyword);

                frame.slots[slot_main] = checker.here();

                checker.bump();

                if (!checker.expect(.paren_open)) return;

                checker.call_expression(frame, 1, 0);
            },
            1 => {
                if (!checker.condition_closed()) return;

                checker.body_open(frame, 2);
            },
            2 => {
                if (!checker.body_closed(frame)) return;

                if (checker.eat(.else_keyword)) {
                    if (!checker.payload()) return;
                    return checker.body_open(frame, 3);
                }

                checker.returns(frame, true, frame.slots[slot_main]);
            },
            3 => {
                if (!checker.body_closed(frame)) return;

                checker.returns(frame, true, frame.slots[slot_main]);
            },
            else => unreachable,
        }
    }

    fn body_open(checker: *Checker, frame: *Frame, stage: u8) void {
        assert(checker.failure == null);
        assert(stage > frame.stage);

        if (frame.flags.typed) return checker.call(frame, stage, .type_expression, .{});

        checker.call_expression(frame, stage, 0);
    }

    fn body_closed(checker: *Checker, frame: *const Frame) bool {
        assert(checker.failure == null);
        assert(frame.stage > 0);

        if (checker.result.present) return true;

        if (frame.flags.typed) {
            checker.fail(.type_expected);
        } else {
            checker.fail(.expression_expected);
        }

        return false;
    }

    fn for_expression(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .for_expression);
        assert(frame.stage <= 3);

        switch (frame.stage) {
            0 => {
                assert(checker.current() == .for_keyword);

                frame.slots[slot_main] = checker.here();

                checker.bump();
                checker.call(frame, 1, .for_prefix, .{});
            },
            1 => checker.body_open(frame, 2),
            2 => {
                if (!checker.body_closed(frame)) return;
                if (checker.eat(.else_keyword)) return checker.body_open(frame, 3);

                checker.returns(frame, true, frame.slots[slot_main]);
            },
            3 => {
                if (!checker.body_closed(frame)) return;

                checker.returns(frame, true, frame.slots[slot_main]);
            },
            else => unreachable,
        }
    }

    fn while_expression(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .while_expression);
        assert(frame.stage <= 4);

        stage: switch (frame.stage) {
            0 => {
                assert(checker.current() == .while_keyword);

                frame.slots[slot_main] = checker.here();

                checker.bump();

                if (!checker.expect(.paren_open)) return;

                checker.call_expression(frame, 1, 0);
            },
            1 => {
                if (!checker.condition_closed()) return;
                if (checker.current() == .colon) return checker.call(frame, 2, .continued, .{});

                continue :stage 2;
            },
            2 => checker.body_open(frame, 3),
            3 => {
                if (!checker.body_closed(frame)) return;

                if (checker.eat(.else_keyword)) {
                    if (!checker.payload()) return;
                    return checker.body_open(frame, 4);
                }

                checker.returns(frame, true, frame.slots[slot_main]);
            },
            4 => {
                if (!checker.body_closed(frame)) return;

                checker.returns(frame, true, frame.slots[slot_main]);
            },
            else => unreachable,
        }
    }

    fn continued(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .continued);
        assert(frame.stage <= 1);

        switch (frame.stage) {
            0 => {
                assert(checker.current() == .colon);

                checker.bump();

                if (!checker.expect(.paren_open)) return;

                checker.call(frame, 1, .assign, .{});
            },
            1 => {
                if (!checker.result.present) {
                    return checker.fail(.expression_or_assignment_expected);
                }

                if (!checker.expect(.paren_close)) return;

                checker.returns(frame, true, offset_none);
            },
            else => unreachable,
        }
    }

    fn block(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .block);
        assert(frame.stage <= 1);

        switch (frame.stage) {
            0 => {
                assert(checker.current() == .brace_open);

                frame.slots[slot_main] = checker.here();

                checker.bump();
                frame.stage = 1;
            },
            1 => {
                if (checker.current() == .brace_close) {
                    checker.bump();

                    return checker.returns(frame, true, frame.slots[slot_main]);
                }

                checker.call(frame, 1, .statement, .{ .block_level = true });
            },
            else => unreachable,
        }
    }

    fn for_prefix(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .for_prefix);
        assert(frame.stage <= 5);

        switch (frame.stage) {
            0 => {
                if (!checker.expect(.paren_open)) return;

                frame.slots[slot_base] = checker.scratch_count;

                checker.call_expression(frame, 1, 0);
            },
            1 => checker.for_prefix_input(frame),
            2 => checker.for_prefix_separator(frame),
            3 => {
                if (!checker.eat(.pipe)) return checker.fail(.loop_payload_expected);

                frame.stage = 4;
            },
            4 => checker.for_prefix_capture(frame),
            5 => checker.for_prefix_closed(frame),
            else => unreachable,
        }
    }

    fn for_prefix_input(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .for_prefix);
        assert(frame.stage == 1);

        if (!checker.result.present) return checker.fail(.expression_expected);

        var main = checker.result.main;
        const ranged = checker.current() == .dot_dot;

        if (ranged) main = checker.here();

        if (checker.scratch_count == scratch_count_max) {
            checker.exhausted = true;

            return;
        }

        checker.scratch[checker.scratch_count] = main;
        checker.scratch_count += 1;
        frame.slots[slot_count] += 1;

        if (ranged) {
            checker.bump();

            return checker.call_expression(frame, 2, 0);
        }

        frame.stage = 2;
    }

    fn for_prefix_separator(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .for_prefix);
        assert(frame.stage == 2);

        switch (checker.current()) {
            .comma => checker.bump(),
            .paren_close => {
                checker.bump();
                frame.stage = 3;

                return;
            },
            .colon, .brace_close, .bracket_close => return checker.fail_token(.paren_close),
            else => return checker.fail(.comma_after_for_operand_expected),
        }

        if (checker.eat(.paren_close)) {
            frame.stage = 3;

            return;
        }

        checker.call_expression(frame, 1, 0);
    }

    fn for_prefix_capture(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .for_prefix);
        assert(frame.stage == 4);

        _ = checker.eat(.star);

        const identifier = checker.here();
        if (!checker.expect(.identifier)) return;

        frame.slots[slot_captures] += 1;

        if (frame.slots[slot_captures] > frame.slots[slot_count]) {
            return checker.fail_at(identifier, .capture_extra);
        }

        switch (checker.current()) {
            .comma => checker.bump(),
            .pipe => {
                checker.bump();
                frame.stage = 5;

                return;
            },
            else => return checker.fail(.comma_after_capture_expected),
        }

        if (checker.eat(.pipe)) frame.stage = 5;
    }

    fn for_prefix_closed(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .for_prefix);
        assert(frame.stage == 5);

        const inputs = frame.slots[slot_count];
        const captures = frame.slots[slot_captures];
        const base = frame.slots[slot_base];

        assert(base + inputs == checker.scratch_count);

        if (captures < inputs) {
            const main = checker.scratch[base + inputs - captures];
            return checker.fail_at(main, .input_not_captured);
        }

        checker.scratch_count = base;

        checker.returns(frame, true, offset_none);
    }

    fn curly(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .curly);
        assert(frame.stage <= 1);

        switch (frame.stage) {
            0 => checker.call(frame, 1, .type_expression, .{}),
            1 => {
                if (!checker.result.present) return checker.returns(frame, false, offset_none);
                if (checker.current() == .brace_open) return checker.tail(frame, .init_list, .{});

                checker.returns(frame, true, checker.result.main);
            },
            else => unreachable,
        }
    }

    fn init_list(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .init_list);
        assert(frame.stage <= 4);

        switch (frame.stage) {
            0 => {
                assert(checker.current() == .brace_open);

                frame.slots[slot_main] = checker.here();

                checker.bump();

                if (checker.eat_field()) return checker.call_expression(frame, 1, 0);

                frame.stage = 3;
            },
            1 => {
                if (!checker.result.present) return checker.fail(.expression_expected);

                frame.stage = 2;
            },
            2 => checker.init_list_field(frame),
            3 => {
                if (checker.eat(.brace_close)) {
                    return checker.returns(frame, true, frame.slots[slot_main]);
                }

                checker.call_expression(frame, 4, 0);
            },
            4 => checker.init_list_element(frame),
            else => unreachable,
        }
    }

    fn init_list_field(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .init_list);
        assert(frame.stage == 2);

        switch (checker.current()) {
            .comma => checker.bump(),
            .brace_close => {
                checker.bump();

                return checker.returns(frame, true, frame.slots[slot_main]);
            },
            .colon, .paren_close, .bracket_close => return checker.fail_token(.brace_close),
            else => return checker.fail(.comma_after_initializer_expected),
        }

        if (checker.eat(.brace_close)) return checker.returns(frame, true, frame.slots[slot_main]);
        if (!checker.eat_field()) return checker.fail(.initializer_expected);

        checker.call_expression(frame, 1, 0);
    }

    fn init_list_element(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .init_list);
        assert(frame.stage == 4);

        if (!checker.result.present) return checker.fail(.expression_expected);

        switch (checker.current()) {
            .comma => {
                checker.bump();
                frame.stage = 3;
            },
            .brace_close => {
                checker.bump();
                checker.returns(frame, true, frame.slots[slot_main]);
            },
            .colon, .paren_close, .bracket_close => checker.fail_token(.brace_close),
            else => checker.fail(.comma_after_initializer_expected),
        }
    }

    fn type_expression(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .type_expression);
        assert(frame.stage <= 8);

        switch (frame.stage) {
            0 => checker.type_open(frame),
            1 => checker.type_modifiers(frame),
            2 => checker.type_aligned(frame),
            3 => {
                if (!checker.result.present) return checker.fail(.expression_expected);

                frame.slots[slot_range] = checker.result.main;
                frame.flags.ranged = true;

                if (!checker.expect(.colon)) return;

                checker.call_expression(frame, 4, 0);
            },
            4 => {
                if (!checker.result.present) return checker.fail(.expression_expected);
                if (!checker.expect(.paren_close)) return;

                frame.stage = 1;
            },
            5 => {
                assert(frame.flags.ranged);

                checker.fail_at(frame.slots[slot_range], .bit_range_invalid);
            },
            6 => {
                if (!checker.result.present) return checker.fail(.expression_expected);
                if (!checker.expect(.bracket_close)) return;

                checker.type_pointer(frame, true);
            },
            7 => checker.type_length(frame),
            8 => {
                if (!checker.result.present) return checker.fail(.expression_expected);

                checker.type_closed(frame);
            },
            else => unreachable,
        }
    }

    fn type_open(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .type_expression);
        assert(frame.stage == 0);

        const start = checker.here();

        switch (checker.current()) {
            .question => {
                checker.outer_set(frame, start);
                checker.bump();
                frame.flags.expect = true;
            },
            .anyframe_keyword => {
                if (checker.peek(1) != .minus_greater) return checker.type_union(frame);

                checker.outer_set(frame, start);
                checker.bump();
                checker.bump();
                frame.flags.expect = true;
            },
            .star, .star_star => {
                checker.outer_set(frame, start);
                checker.bump();
                checker.type_pointer(frame, false);
            },
            .bracket_open => {
                checker.outer_set(frame, start);
                checker.type_bracket(frame);
            },
            else => checker.type_union(frame),
        }
    }

    fn type_union(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .type_expression);
        assert(checker.failure == null);

        const flags: Flags = .{ .expect = frame.flags.expect };

        checker.tail(frame, .error_union, flags);
    }

    fn type_pointer(checker: *const Checker, frame: *Frame, many: bool) void {
        assert(frame.proc == .type_expression);
        assert(checker.failure == null);

        frame.flags.many = many;
        frame.flags.ranged = false;
        frame.mark = 0;
        frame.stage = 1;
    }

    fn type_bracket(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .type_expression);
        assert(checker.current() == .bracket_open);

        checker.bump();

        if (checker.current() != .star) return checker.call_expression(frame, 7, 0);

        checker.bump();

        if (checker.current() == .identifier) {
            const identifier = checker.here();
            const next = checker.start_at(checker.position + 1);
            const text = std.mem.trimEnd(u8, checker.source[identifier..next], whitespace);

            checker.bump();

            if (!std.mem.eql(u8, text, "c")) checker.position -= 1;
        } else if (checker.eat(.colon)) {
            return checker.call_expression(frame, 6, 0);
        } else {}

        if (!checker.expect(.bracket_close)) return;

        checker.type_pointer(frame, true);
    }

    fn type_length(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .type_expression);
        assert(frame.stage == 7);

        if (checker.result.present) frame.mark = mark_array;
        if (checker.eat(.colon)) return checker.call_expression(frame, 8, 0);

        checker.type_closed(frame);
    }

    fn type_closed(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .type_expression);
        assert(frame.stage >= 7);

        if (!checker.expect(.bracket_close)) return;
        if (frame.mark != mark_array) return checker.type_pointer(frame, true);

        if (checker.current().is_pointer_modifier()) {
            return checker.fail(.modifier_on_array_child);
        }

        frame.flags.expect = true;
        frame.mark = 0;
        frame.stage = 0;
    }

    fn type_modifiers(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .type_expression);
        assert(frame.stage == 1);

        const tag = checker.current();
        const bit = tag.modifier_bit_of() orelse return checker.type_child(frame);
        if (frame.mark & bit != 0) return checker.fail(repeated_of(tag));

        frame.mark |= bit;

        switch (tag) {
            .align_keyword => {
                checker.bump();

                if (!checker.expect(.paren_open)) return;

                checker.call_expression(frame, 2, 0);
            },
            .addrspace_keyword => checker.call(frame, 1, .attribute, .{}),
            else => checker.bump(),
        }
    }

    fn type_aligned(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .type_expression);
        assert(frame.stage == 2);

        if (!checker.result.present) return checker.fail(.expression_expected);
        if (checker.eat(.colon)) return checker.call_expression(frame, 3, 0);
        if (!checker.expect(.paren_close)) return;

        frame.stage = 1;
    }

    fn type_child(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .type_expression);
        assert(frame.stage == 1);

        if (frame.flags.many) {
            if (frame.flags.ranged) {
                return checker.call(frame, 5, .type_expression, .{ .expect = true });
            }
        }

        frame.flags.expect = true;
        frame.flags.many = false;
        frame.flags.ranged = false;
        frame.mark = 0;
        frame.stage = 0;
    }

    fn error_union(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .error_union);
        assert(frame.stage <= 2);

        switch (frame.stage) {
            0 => checker.call(frame, 1, .suffix, .{}),
            1 => {
                if (!checker.result.present) {
                    if (frame.flags.expect) return checker.fail(.type_expected);
                    return checker.returns(frame, false, offset_none);
                }

                if (checker.current() != .bang) {
                    return checker.returns(frame, true, checker.result.main);
                }

                frame.slots[slot_main] = checker.here();

                checker.bump();
                checker.call(frame, 2, .type_expression, .{ .expect = true });
            },
            2 => checker.returns(frame, true, frame.slots[slot_main]),
            else => unreachable,
        }
    }

    fn suffix(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .suffix);
        assert(frame.stage <= 7);

        switch (frame.stage) {
            0 => checker.call(frame, 1, .primary_type, .{}),
            1 => {
                if (!checker.result.present) return checker.returns(frame, false, offset_none);

                frame.slots[slot_main] = checker.result.main;
                frame.stage = 2;
            },
            2 => checker.suffix_operator(frame),
            3 => {
                if (!checker.result.present) return checker.fail(.expression_expected);
                if (checker.eat(.dot_dot)) return checker.call_expression(frame, 4, 0);

                checker.suffix_indexed(frame);
            },
            4 => {
                if (checker.eat(.colon)) return checker.call_expression(frame, 5, 0);

                checker.suffix_indexed(frame);
            },
            5 => {
                if (!checker.result.present) return checker.fail(.expression_expected);

                checker.suffix_indexed(frame);
            },
            6 => {
                if (checker.eat(.paren_close)) return checker.suffix_called(frame);

                checker.call_expression(frame, 7, 0);
            },
            7 => checker.suffix_argument(frame),
            else => unreachable,
        }
    }

    fn suffix_operator(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .suffix);
        assert(frame.stage == 2);

        const start = checker.here();

        switch (checker.current()) {
            .bracket_open => {
                frame.slots[slot_open] = start;

                checker.bump();

                return checker.call_expression(frame, 3, 0);
            },
            .dot_asterisk => {
                frame.slots[slot_main] = start;

                checker.bump();

                return;
            },
            .invalid_dot_asterisks => return checker.fail(.asterisk_after_dereference),
            .dot => switch (checker.peek(1)) {
                .identifier, .question => {
                    frame.slots[slot_main] = start;

                    checker.bump();
                    checker.bump();

                    return;
                },
                .brace_open => {},
                else => {
                    checker.bump();

                    return checker.fail(.suffix_operator_expected);
                },
            },
            else => {},
        }

        if (checker.current() != .paren_open) {
            return checker.returns(frame, true, frame.slots[slot_main]);
        }

        frame.slots[slot_open] = start;

        checker.bump();
        frame.stage = 6;
    }

    fn suffix_indexed(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .suffix);
        assert(frame.stage >= 3);

        if (!checker.expect(.bracket_close)) return;

        frame.slots[slot_main] = frame.slots[slot_open];
        frame.stage = 2;
    }

    fn suffix_called(checker: *const Checker, frame: *Frame) void {
        assert(frame.proc == .suffix);
        assert(checker.failure == null);

        frame.slots[slot_main] = frame.slots[slot_open];
        frame.stage = 2;
    }

    fn suffix_argument(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .suffix);
        assert(frame.stage == 7);

        if (!checker.result.present) return checker.fail(.expression_expected);

        switch (checker.current()) {
            .comma => {
                checker.bump();
                frame.stage = 6;
            },
            .paren_close => {
                checker.bump();
                checker.suffix_called(frame);
            },
            .colon, .brace_close, .bracket_close => checker.fail_token(.paren_close),
            else => checker.fail(.comma_after_argument_expected),
        }
    }

    fn primary_type(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .primary_type);
        assert(frame.stage <= 3);

        switch (frame.stage) {
            0 => checker.primary_type_open(frame),
            1 => checker.returns(frame, true, frame.slots[slot_main]),
            2 => checker.error_set(frame),
            3 => {
                if (!checker.result.present) return checker.fail(.expression_expected);
                if (!checker.expect(.paren_close)) return;

                checker.returns(frame, true, frame.slots[slot_main]);
            },
            else => unreachable,
        }
    }

    fn primary_type_open(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .primary_type);
        assert(frame.stage == 0);

        const start = checker.here();

        frame.slots[slot_main] = start;

        switch (checker.current()) {
            .character, .number, .unreachable_keyword, .anyframe_keyword, .text => {
                checker.bump();
                checker.returns(frame, true, start);
            },
            .builtin => checker.tail(frame, .builtin_call, .{}),
            .fn_keyword => checker.tail(frame, .function, .{}),
            .if_keyword => checker.tail(frame, .if_expression, .{ .typed = true }),
            .switch_keyword => {
                checker.tail(frame, .switch_expression, .{});
                frame.slots[slot_main] = start;
            },
            .extern_keyword, .packed_keyword => {
                checker.bump();
                checker.tail(frame, .container, .{});
            },
            .struct_keyword, .opaque_keyword, .enum_keyword, .union_keyword => {
                checker.tail(frame, .container, .{});
            },
            .comptime_keyword => {
                checker.bump();
                checker.call(frame, 1, .type_expression, .{ .expect = true });
            },
            .text_line => {
                for (0..checker.steps_bound()) |_| {
                    if (!checker.eat(.text_line)) break;
                }

                checker.returns(frame, true, start);
            },
            else => checker.primary_type_other(frame),
        }
    }

    fn primary_type_other(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .primary_type);
        assert(frame.stage == 0);

        const start = checker.here();

        switch (checker.current()) {
            .identifier => checker.primary_type_identifier(frame),
            .inline_keyword => {
                checker.bump();
                checker.loop_inlined(frame, .{ .typed = true });
            },
            .for_keyword => checker.tail(frame, .for_expression, .{ .typed = true }),
            .while_keyword => checker.tail(frame, .while_expression, .{ .typed = true }),
            .dot => switch (checker.peek(1)) {
                .identifier => {
                    checker.bump();

                    const identifier = checker.here();

                    checker.bump();
                    checker.returns(frame, true, identifier);
                },
                .brace_open => {
                    checker.bump();
                    checker.tail(frame, .init_list, .{});
                },
                else => checker.returns(frame, false, offset_none),
            },
            .error_keyword => checker.error_open(frame),
            .paren_open => {
                checker.bump();
                checker.call_expression(frame, 3, 0);
            },
            else => {
                assert(frame.slots[slot_main] == start);

                checker.returns(frame, false, offset_none);
            },
        }
    }

    fn primary_type_identifier(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .primary_type);
        assert(checker.current() == .identifier);

        const start = checker.here();

        if (checker.peek(1) != .colon) {
            checker.bump();

            return checker.returns(frame, true, start);
        }

        switch (checker.peek(2)) {
            .inline_keyword => {
                checker.bump();
                checker.bump();
                checker.bump();
                checker.loop_inlined(frame, .{ .typed = true });
            },
            .for_keyword, .while_keyword, .switch_keyword, .brace_open => |tag| {
                checker.bump();
                checker.bump();

                switch (tag) {
                    .for_keyword => checker.tail(frame, .for_expression, .{ .typed = true }),
                    .while_keyword => checker.tail(frame, .while_expression, .{ .typed = true }),
                    .switch_keyword => {
                        checker.tail(frame, .switch_expression, .{});
                        frame.slots[slot_main] = start;
                    },
                    else => checker.tail(frame, .block, .{}),
                }
            },
            else => {
                checker.bump();
                checker.returns(frame, true, start);
            },
        }
    }

    fn error_open(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .primary_type);
        assert(checker.current() == .error_keyword);

        const start = checker.here();

        if (checker.peek(1) == .brace_open) {
            checker.bump();
            checker.bump();
            frame.stage = 2;

            return;
        }

        checker.bump();

        if (!checker.eat(.dot)) return checker.fail_token(.dot);
        if (!checker.eat(.identifier)) return checker.fail_token(.identifier);

        checker.returns(frame, true, start);
    }

    fn error_set(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .primary_type);
        assert(frame.stage == 2);

        if (checker.eat(.brace_close)) return checker.returns(frame, true, frame.slots[slot_main]);

        _ = checker.doc_comments();

        if (checker.failure != null) return;
        if (!checker.expect(.identifier)) return;

        switch (checker.current()) {
            .comma => checker.bump(),
            .brace_close => {
                checker.bump();
                checker.returns(frame, true, frame.slots[slot_main]);
            },
            .colon, .paren_close, .bracket_close => checker.fail_token(.brace_close),
            else => checker.fail(.comma_after_field_expected),
        }
    }

    fn builtin_call(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .builtin_call);
        assert(frame.stage <= 2);

        switch (frame.stage) {
            0 => {
                assert(checker.current() == .builtin);

                frame.slots[slot_main] = checker.here();

                checker.bump();

                if (!checker.eat(.paren_open)) return checker.fail(.parameter_list_expected);

                frame.stage = 1;
            },
            1 => {
                if (checker.eat(.paren_close)) {
                    return checker.returns(frame, true, frame.slots[slot_main]);
                }

                checker.call_expression(frame, 2, 0);
            },
            2 => {
                if (!checker.result.present) return checker.fail(.expression_expected);

                switch (checker.current()) {
                    .comma => {
                        checker.bump();
                        frame.stage = 1;
                    },
                    .paren_close => {
                        checker.bump();
                        checker.returns(frame, true, frame.slots[slot_main]);
                    },
                    else => checker.fail(.comma_after_argument_expected),
                }
            },
            else => unreachable,
        }
    }

    fn switch_expression(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .switch_expression);
        assert(frame.stage <= 2);

        switch (frame.stage) {
            0 => {
                assert(checker.current() == .switch_keyword);
                assert(frame.slots[slot_main] <= checker.here());

                checker.bump();

                if (!checker.expect(.paren_open)) return;

                checker.call_expression(frame, 1, 0);
            },
            1 => {
                if (!checker.result.present) return checker.fail(.expression_expected);
                if (!checker.expect(.paren_close)) return;
                if (!checker.expect(.brace_open)) return;

                checker.call(frame, 2, .prongs, .{});
            },
            2 => {
                if (!checker.expect(.brace_close)) return;

                checker.returns(frame, true, frame.slots[slot_main]);
            },
            else => unreachable,
        }
    }

    fn prongs(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .prongs);
        assert(frame.stage <= 1);

        switch (frame.stage) {
            0 => checker.call(frame, 1, .prong, .{}),
            1 => {
                if (!checker.result.present) return checker.returns(frame, true, offset_none);

                switch (checker.current()) {
                    .comma => {
                        checker.bump();
                        frame.stage = 0;
                    },
                    .colon, .paren_close, .brace_close, .bracket_close => {
                        checker.returns(frame, true, offset_none);
                    },
                    else => checker.fail(.comma_after_switch_prong_expected),
                }
            },
            else => unreachable,
        }
    }

    fn prong(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .prong);
        assert(frame.stage <= 5);

        stage: switch (frame.stage) {
            0 => {
                if (checker.eat(.inline_keyword)) frame.mark |= mark_inlined;
                if (checker.eat(.else_keyword)) continue :stage 4;

                checker.call_expression(frame, 1, 0);
            },
            1 => {
                if (!checker.result.present) continue :stage 3;
                if (checker.eat(.dot_dot_dot)) return checker.call_expression(frame, 2, 0);

                continue :stage 2;
            },
            2 => {
                if (!checker.result.present) return checker.fail(.expression_expected);

                frame.slots[slot_count] += 1;

                if (checker.eat(.comma)) return checker.call_expression(frame, 1, 0);

                continue :stage 3;
            },
            3 => {
                if (frame.slots[slot_count] == 0) {
                    if (frame.mark & mark_inlined != 0) checker.position -= 1;

                    return checker.returns(frame, false, offset_none);
                }

                continue :stage 4;
            },
            4 => {
                if (!checker.expect(.arrow)) return;
                if (!checker.index_payload()) return;

                checker.call(frame, 5, .single_assign, .{});
            },
            5 => {
                if (!checker.result.present) {
                    return checker.fail(.expression_or_assignment_expected);
                }

                checker.returns(frame, true, offset_none);
            },
            else => unreachable,
        }
    }

    fn assembly(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .assembly);
        assert(frame.stage <= 5);

        switch (frame.stage) {
            0 => {
                assert(checker.current() == .asm_keyword);

                frame.slots[slot_main] = checker.here();

                checker.bump();
                _ = checker.eat(.volatile_keyword);

                if (!checker.expect(.paren_open)) return;

                checker.call_expression(frame, 1, 0);
            },
            1 => {
                if (!checker.result.present) return checker.fail(.expression_expected);

                if (checker.eat(.paren_close)) {
                    return checker.returns(frame, true, frame.slots[slot_main]);
                }

                if (!checker.expect(.colon)) return;

                checker.assembly_item(frame, 2, .asm_output);
            },
            2 => checker.assembly_separator(frame, .asm_output),
            3 => checker.assembly_item(frame, 4, .asm_input),
            4 => checker.assembly_separator(frame, .asm_input),
            5 => {
                if (!checker.result.present) return checker.fail(.expression_expected);

                checker.assembly_closed(frame);
            },
            else => unreachable,
        }
    }

    fn assembly_item(checker: *Checker, frame: *Frame, stage: u8, proc: Proc) void {
        assert(frame.proc == .assembly);
        assert(stage == 2 or stage == 4);

        if (checker.current() == .bracket_open) return checker.call(frame, stage, proc, .{});

        checker.assembly_section(frame, proc);
    }

    fn assembly_separator(checker: *Checker, frame: *Frame, proc: Proc) void {
        assert(frame.proc == .assembly);
        assert(checker.result.present);

        switch (checker.current()) {
            .comma => {
                checker.bump();
                checker.assembly_item(frame, frame.stage, proc);
            },
            .colon, .paren_close, .brace_close, .bracket_close => {
                checker.assembly_section(frame, proc);
            },
            else => checker.fail_token(.comma),
        }
    }

    fn assembly_section(checker: *Checker, frame: *Frame, proc: Proc) void {
        assert(frame.proc == .assembly);
        assert(proc == .asm_output or proc == .asm_input);

        if (proc == .asm_output) {
            if (checker.eat(.colon)) {
                frame.stage = 3;

                return;
            }

            return checker.assembly_closed(frame);
        }

        if (checker.eat(.colon)) return checker.call_expression(frame, 5, 0);

        checker.assembly_closed(frame);
    }

    fn assembly_closed(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .assembly);
        assert(checker.failure == null);

        if (!checker.expect(.paren_close)) return;

        checker.returns(frame, true, frame.slots[slot_main]);
    }

    fn asm_output(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .asm_output);
        assert(frame.stage <= 1);

        switch (frame.stage) {
            0 => {
                if (!checker.asm_item_open()) return;

                if (checker.eat(.minus_greater)) {
                    return checker.call(frame, 1, .type_expression, .{ .expect = true });
                }

                if (!checker.expect(.identifier)) return;

                frame.stage = 1;
            },
            1 => {
                if (!checker.expect(.paren_close)) return;

                checker.returns(frame, true, offset_none);
            },
            else => unreachable,
        }
    }

    fn asm_input(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .asm_input);
        assert(frame.stage <= 1);

        switch (frame.stage) {
            0 => {
                if (!checker.asm_item_open()) return;

                checker.call_expression(frame, 1, 0);
            },
            1 => {
                if (!checker.result.present) return checker.fail(.expression_expected);
                if (!checker.expect(.paren_close)) return;

                checker.returns(frame, true, offset_none);
            },
            else => unreachable,
        }
    }

    fn asm_item_open(checker: *Checker) bool {
        assert(checker.current() == .bracket_open);
        assert(checker.failure == null);

        checker.bump();

        if (!checker.expect(.identifier)) return false;
        if (!checker.expect(.bracket_close)) return false;
        if (!checker.expect(.text)) return false;
        return checker.expect(.paren_open);
    }

    fn container(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .container);
        assert(frame.stage <= 4);

        stage: switch (frame.stage) {
            0 => checker.container_open(frame),
            1 => {
                if (!checker.result.present) return checker.fail(.expression_expected);
                if (!checker.expect(.paren_close)) return;

                continue :stage 3;
            },
            2 => {
                if (!checker.result.present) return checker.fail(.expression_expected);
                if (!checker.expect(.paren_close)) return;
                if (!checker.expect(.paren_close)) return;

                continue :stage 3;
            },
            3 => {
                if (!checker.expect(.brace_open)) return;

                checker.call(frame, 4, .members, .{});
            },
            4 => {
                if (!checker.expect(.brace_close)) return;

                checker.returns(frame, true, frame.slots[slot_main]);
            },
            else => unreachable,
        }
    }

    fn container_open(checker: *Checker, frame: *Frame) void {
        assert(frame.proc == .container);
        assert(frame.stage == 0);

        const tag = checker.current();

        frame.slots[slot_main] = checker.here();

        checker.bump();

        switch (tag) {
            .opaque_keyword => frame.stage = 3,
            .struct_keyword, .enum_keyword => {
                if (checker.eat(.paren_open)) return checker.call_expression(frame, 1, 0);

                frame.stage = 3;
            },
            .union_keyword => {
                if (!checker.eat(.paren_open)) {
                    frame.stage = 3;

                    return;
                }

                if (!checker.eat(.enum_keyword)) return checker.call_expression(frame, 1, 0);
                if (checker.eat(.paren_open)) return checker.call_expression(frame, 2, 0);
                if (!checker.expect(.paren_close)) return;

                frame.stage = 3;
            },
            else => {
                checker.position -= 1;

                checker.fail(.container_expected);
            },
        }
    }

    fn payload(checker: *Checker) bool {
        assert(checker.failure == null);
        assert(checker.frame_count > 0);

        if (!checker.eat(.pipe)) return true;
        if (!checker.expect(.identifier)) return false;
        return checker.expect(.pipe);
    }

    fn pointer_payload(checker: *Checker) bool {
        assert(checker.failure == null);
        assert(checker.frame_count > 0);

        if (!checker.eat(.pipe)) return true;

        _ = checker.eat(.star);

        if (!checker.expect(.identifier)) return false;
        return checker.expect(.pipe);
    }

    fn index_payload(checker: *Checker) bool {
        assert(checker.failure == null);
        assert(checker.frame_count > 0);

        if (!checker.eat(.pipe)) return true;

        _ = checker.eat(.star);

        if (!checker.expect(.identifier)) return false;

        if (checker.eat(.comma)) {
            if (!checker.expect(.identifier)) return false;
        }

        return checker.expect(.pipe);
    }

    fn doc_comments(checker: *Checker) ?u32 {
        assert(checker.failure == null);
        assert(checker.frame_count > 0);

        if (checker.current() != .doc_comment) return null;

        const first = checker.here();

        if (checker.position > 0) {
            const prior = checker.start_at(checker.position - 1);

            if (std.mem.findScalar(u8, checker.source[prior..first], '\n') == null) {
                checker.fail_at(first, .doc_comment_on_same_line);

                return null;
            }
        }

        for (0..checker.steps_bound()) |_| {
            if (!checker.eat(.doc_comment)) break;
        }

        return first;
    }

    fn eat_field(checker: *Checker) bool {
        assert(checker.failure == null);

        if (checker.current() != .dot) return false;
        if (checker.peek(1) != .identifier) return false;
        if (checker.peek(2) != .equal) return false;

        checker.bump();
        checker.bump();
        checker.bump();

        return true;
    }

    fn eat_pair(checker: *Checker, first: Tag, second: Tag) bool {
        assert(first != second);

        if (checker.current() != first) return false;
        if (checker.peek(1) != second) return false;

        checker.bump();
        checker.bump();

        return true;
    }

    fn eat(checker: *Checker, tag: Tag) bool {
        assert(checker.position < std.math.maxInt(u32));

        if (checker.current() != tag) return false;

        checker.bump();

        return true;
    }

    fn expect(checker: *Checker, tag: Tag) bool {
        assert(checker.failure == null);

        if (checker.eat(tag)) return true;

        checker.fail_token(tag);

        return false;
    }

    fn bump(checker: *Checker) void {
        assert(checker.position < std.math.maxInt(u32));
        assert(checker.position <= checker.produced);

        checker.position += 1;
    }

    fn current(checker: *Checker) Tag {
        return checker.peek(0);
    }

    fn peek(checker: *Checker, ahead: u32) Tag {
        assert(ahead < lookahead_max);

        return checker.lexeme_at(checker.position + ahead).tag;
    }

    fn here(checker: *Checker) u32 {
        return checker.start_at(checker.position);
    }

    fn start_at(checker: *Checker, index: u32) u32 {
        assert(index < std.math.maxInt(u32));

        return checker.lexeme_at(index).start;
    }

    fn lexeme_at(checker: *Checker, index: u32) Lexeme {
        assert(index + ring_size > checker.produced);
        assert(index < checker.position + lookahead_max);

        for (0..ring_size) |_| {
            if (checker.produced > index) break;

            checker.ring[checker.produced % ring_size] = checker.tokenizer.next();
            checker.produced += 1;
        }

        assert(checker.produced > index);

        return checker.ring[index % ring_size];
    }

    fn byte_at(checker: *const Checker, offset: u32) u8 {
        assert(offset < std.math.maxInt(u32));

        if (offset >= checker.source.len) return 0;

        assert(offset < checker.source.len);

        return checker.source[offset];
    }

    fn steps_bound(checker: *const Checker) u32 {
        assert(checker.source.len < std.math.maxInt(u32));

        return @as(u32, @intCast(checker.source.len)) + step_padding;
    }

    fn call(checker: *Checker, frame: *Frame, stage: u8, proc: Proc, flags: Flags) void {
        assert(frame == &checker.frames[checker.frame_count - 1]);
        assert(proc != .root);
        assert(!flags.unused);

        frame.stage = stage;

        if (checker.frame_count == frame_count_max) {
            checker.exhausted = true;

            return;
        }

        checker.frames[checker.frame_count] = .of(proc, flags);
        checker.frame_count += 1;
    }

    fn call_expression(checker: *Checker, frame: *Frame, stage: u8, precedence: u32) void {
        assert(precedence <= precedence_max);
        assert(frame == &checker.frames[checker.frame_count - 1]);
        assert(stage > 0);

        checker.call(frame, stage, .expression, .{});

        if (checker.exhausted) return;

        checker.frames[checker.frame_count - 1].slots[slot_precedence] = precedence;
    }

    fn tail(checker: *const Checker, frame: *Frame, proc: Proc, flags: Flags) void {
        assert(frame == &checker.frames[checker.frame_count - 1]);
        assert(proc != .root);
        assert(!flags.unused);

        const outer = frame.outer;

        frame.* = .of(proc, flags);
        frame.outer = outer;
    }

    fn outer_set(checker: *const Checker, frame: *Frame, start_offset: u32) void {
        assert(frame == &checker.frames[checker.frame_count - 1]);
        assert(start_offset != offset_none);

        if (frame.outer == offset_none) frame.outer = start_offset;
    }

    fn returns(checker: *Checker, frame: *const Frame, present: bool, main: u32) void {
        assert(checker.frame_count > 0);
        assert(frame == &checker.frames[checker.frame_count - 1]);

        const outer = present and frame.outer != offset_none;

        checker.result = .{ .main = if (outer) frame.outer else main, .present = present };
        checker.frame_count -= 1;
    }

    fn fail(checker: *Checker, problem: Problem) void {
        checker.fail_at(checker.here(), problem);
    }

    fn fail_token(checker: *Checker, tag: Tag) void {
        assert(checker.failure == null);
        assert(checker.current() != tag);

        const offset = checker.here();

        checker.failure = .{
            .expected = kind_of(tag),
            .kind = .unexpected_token,
            .offset = offset,
        };
    }

    fn fail_at(checker: *Checker, offset: u32, problem: Problem) void {
        assert(offset <= checker.source.len);

        if (checker.failure != null) return;

        checker.failure = .{
            .expected = problem.expected(),
            .kind = problem.kind(),
            .offset = offset,
        };
    }
};

const Proc = enum(u8) {
    asm_input,
    asm_output,
    assembly,
    assign,
    attribute,
    block,
    block_statement,
    builtin_call,
    container,
    container_field,
    continued,
    curly,
    declaration,
    error_union,
    expression,
    for_expression,
    for_prefix,
    for_statement,
    function,
    global,
    if_expression,
    if_statement,
    init_list,
    labeled,
    loop_statement,
    members,
    parameters,
    primary,
    primary_type,
    prong,
    prongs,
    root,
    single_assign,
    statement,
    suffix,
    switch_expression,
    test_declaration,
    type_expression,
    variable,
    variable_statement,
    while_expression,
    while_statement,
};

const Flags = packed struct(u8) {
    block_level: bool = false,
    else_required: bool = false,
    expect: bool = false,
    many: bool = false,
    ranged: bool = false,
    semicolon_seen: bool = false,
    typed: bool = false,
    unused: bool = false,
};

const Frame = struct {
    flags: Flags,
    mark: u8,
    outer: u32,
    proc: Proc,
    slots: [slot_count_max]u32,
    stage: u8,

    fn of(proc: Proc, flags: Flags) Frame {
        assert(!flags.unused);

        return .{
            .flags = flags,
            .mark = 0,
            .outer = offset_none,
            .proc = proc,
            .slots = @splat(0),
            .stage = 0,
        };
    }
};

const Result = struct {
    main: u32,
    present: bool,

    const absent: Result = .{ .main = offset_none, .present = false };
};

const Operator = struct {
    associative: bool,
    precedence: u32,
};

const Problem = enum {
    ampersand_ampersand,
    asterisk_after_dereference,
    bit_range_invalid,
    block_expected,
    block_or_assignment_expected,
    block_or_expression_expected,
    capture_extra,
    comma_after_argument_expected,
    comma_after_capture_expected,
    comma_after_field_expected,
    comma_after_for_operand_expected,
    comma_after_initializer_expected,
    comma_after_parameter_expected,
    comma_after_switch_prong_expected,
    comparison_chained,
    container_expected,
    container_in_c_style,
    declaration_between_fields,
    doc_comment_on_comptime,
    doc_comment_on_same_line,
    doc_comment_on_test,
    doc_comment_unattached,
    equal_equal_in_declaration,
    expression_expected,
    expression_or_assignment_expected,
    expression_or_variable_expected,
    extern_function_body,
    function_expected,
    initializer_expected,
    inlinable_expected,
    input_not_captured,
    labelable_expected,
    loop_payload_expected,
    modifier_on_array_child,
    operator_whitespace_mismatched,
    parameter_list_expected,
    prefix_expression_expected,
    public_item_expected,
    qualifier_addrspace_repeated,
    qualifier_align_repeated,
    qualifier_allowzero_repeated,
    qualifier_const_repeated,
    qualifier_volatile_repeated,
    return_type_expected,
    semicolon_after_declaration_expected,
    semicolon_after_statement_expected,
    semicolon_or_brace_expected,
    semicolon_or_else_expected,
    statement_expected,
    suffix_operator_expected,
    type_expected,
    variable_constant_expected,
    variable_expected,
    variable_or_function_expected,
    varargs_not_final,

    fn kind(problem: Problem) Diagnostic.Kind {
        return switch (problem) {
            .block_or_expression_expected,
            .expression_expected,
            .expression_or_assignment_expected,
            .expression_or_variable_expected,
            .prefix_expression_expected,
            .statement_expected,
            => .expected_expression,
            .return_type_expected, .type_expected => .expected_type,
            else => .unexpected_token,
        };
    }

    fn expected(problem: Problem) ?Kind {
        return switch (problem) {
            .comma_after_argument_expected,
            .comma_after_capture_expected,
            .comma_after_field_expected,
            .comma_after_for_operand_expected,
            .comma_after_initializer_expected,
            .comma_after_parameter_expected,
            .comma_after_switch_prong_expected,
            => .comma,
            .semicolon_after_declaration_expected,
            .semicolon_after_statement_expected,
            => .semicolon,
            .block_expected => .brace_open,
            .loop_payload_expected => .pipe,
            .parameter_list_expected => .paren_open,
            else => null,
        };
    }
};

const field_state_none: u32 = 0;
const field_state_seen: u32 = 1;
const field_state_end: u32 = 2;
const field_state_error: u32 = 3;
const frame_count_max: u32 = 1024;
const lookahead_max: u32 = 4;
const mark_array: u8 = 1 << 0;
const mark_attributed: u8 = 1 << 1;
const mark_declared: u8 = 1 << 2;
const mark_extern: u8 = 1 << 3;
const mark_function: u8 = 1 << 4;
const mark_inlined: u8 = 1 << 5;
const mark_variable_or_function: u8 = 1 << 6;
const offset_none: u32 = std.math.maxInt(u32);
const precedence_max: u32 = 71;
const precedence_none: u32 = 255;
const ring_size: u32 = 16;
const scratch_count_max: u32 = 256;
const slot_count_max: u32 = 4;
const slot_after: u32 = 1;
const slot_banned: u32 = 2;
const slot_base: u32 = 2;
const slot_captures: u32 = 3;
const slot_count: u32 = 1;
const slot_end: u32 = 1;
const slot_first: u32 = 1;
const slot_label: u32 = 2;
const slot_main: u32 = 0;
const slot_open: u32 = 1;
const slot_operator: u32 = 3;
const slot_precedence: u32 = 1;
const slot_prefix: u32 = 3;
const slot_range: u32 = 1;
const slot_state: u32 = 2;
const step_count_per_byte: u64 = 64;
const step_padding: u32 = 16;
const varargs_none: u32 = 0;
const varargs_seen: u32 = 1;
const varargs_nonfinal: u32 = 2;
const whitespace = " \t\n\r\x0b\x0c";

const kinds = kinds: {
    const names = @typeInfo(Tag).@"enum".field_names;
    var table: [names.len]?Kind = undefined;

    for (names, 0..) |name, index| {
        table[index] = if (@hasField(Kind, name)) @field(Kind, name) else null;
    }

    break :kinds table;
};

comptime {
    assert(lookahead_max < ring_size);
    assert(precedence_max < precedence_none);
    assert(slot_main != slot_precedence);
    assert(slot_operator != slot_precedence);
}

fn kind_of(tag: Tag) ?Kind {
    if (tag == .eof) return null;

    const held = kinds[@backingInt(tag)];

    if (held) |kind| assert(kind.is_token());

    return held;
}

fn operator_of(tag: Tag) ?Operator {
    if (tag == .eof) return null;

    const precedence: u32, const associative: bool = switch (tag) {
        .or_keyword => .{ 10, true },
        .and_keyword => .{ 20, true },
        .equal_equal, .bang_equal, .less, .greater, .less_equal, .greater_equal => .{ 30, false },
        .ampersand, .caret, .pipe, .orelse_keyword, .catch_keyword => .{ 40, true },
        .less_less, .less_less_pipe, .greater_greater => .{ 50, true },
        .plus, .minus, .plus_plus, .plus_percent, .minus_percent, .plus_pipe, .minus_pipe => .{
            60,
            true,
        },
        .pipe_pipe, .star, .slash, .percent, .star_star, .star_percent, .star_pipe => .{ 70, true },
        else => return null,
    };

    assert(precedence > 0);
    assert(precedence < precedence_max);

    return .{ .associative = associative, .precedence = precedence };
}

fn repeated_of(tag: Tag) Problem {
    assert(tag.is_pointer_modifier());

    return switch (tag) {
        .align_keyword => .qualifier_align_repeated,
        .const_keyword => .qualifier_const_repeated,
        .volatile_keyword => .qualifier_volatile_repeated,
        .allowzero_keyword => .qualifier_allowzero_repeated,
        .addrspace_keyword => .qualifier_addrspace_repeated,
        else => unreachable,
    };
}

fn is_whitespace(byte: u8) bool {
    if (byte > ' ') return false;

    return std.mem.findScalar(u8, whitespace, byte) != null;
}

fn expect_failure(source: []const u8, offset: ?u32) !void {
    assert(source.len <= std.math.maxInt(u32));
    if (offset) |held| assert(held < std.math.maxInt(u32));

    const gpa = std.testing.allocator;
    const checker = try gpa.create(Checker);
    defer gpa.destroy(checker);

    const failure = checker.check(source);
    const held: ?u32 = if (failure) |found| found.offset else null;

    try std.testing.expectEqual(offset, held);
}

test "a missing terminator fails where std.zig.Ast fails" {
    try expect_failure("const x = 1", 11);
    try expect_failure("fn f() void {\n    x();\n", 23);
    try expect_failure("const S = struct { a: u32 b: u32 };", 26);
    try expect_failure("const x = (a b);", 13);
    try expect_failure("const s = \"open\n;", 10);
}

test "a pointer takes a bit range and repeats no qualifier" {
    try expect_failure("const A = *align(4:0:4) u8;", null);
    try expect_failure("const A = []align(4:0:4) u8;", 20);
    try expect_failure("const A = *const const u8;", 17);
    try expect_failure("const A = [*x]u8;", 12);
    try expect_failure("const A = [4]const u8;", 13);
    try expect_failure("const x = a.**b;", 11);
}

test "an operator, an attribute and a doc comment fail in the order zig reports them" {
    try expect_failure("const x = a == b == c;", 17);
    try expect_failure("const x = a +b;", 12);
    try expect_failure("fn f() callconv(.c) align(4) void {}", 20);
    try expect_failure("test \"x\" {\n    /// doc\n    x();\n}\n", 15);
    try expect_failure("pub CharacterSet = 1;", 4);
}

test "a bare return takes an operator and a labeled block takes a suffix" {
    try expect_failure("fn f() u8 {\n    return + 1;\n}\n", null);
    try expect_failure("const x = blk: {\n    break :blk 1;\n}.y;\n", null);
}
