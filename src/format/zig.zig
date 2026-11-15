const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Buffer = @import("../stdx/bounded/buffer.zig");
const FormatterError = @import("formatters.zig").FormatterError;
pub const Kind = @import("../syntax/zig/kind.zig").Kind;
const Options = @import("print.zig").Options;
const Span = @import("../stdx/bounded/span.zig");
const Structure = @import("../syntax/tree.zig").Structure;
const Token = @import("../syntax/token.zig");
const Tokens = @import("../syntax/tokens.zig");
const Tree = @import("../syntax/tree.zig").TreeType(Kind);
const brace = @import("brace.zig");
const raw_of = @import("../syntax/raw.zig").raw_of;
const walk = @import("walk.zig");

pub const Formatter = struct {
    columns: ArrayType(u32),
    elements: ArrayType(Element),
    inner: brace.Formatter,
    lists: ArrayType(u8),
    mapped: ArrayType(u32),
    operand_ends: ArrayType(u32),
    operands: ArrayType(u32),
    patched: Buffer,
    patches: ArrayType(Patch),
    rekinds: ArrayType(Kind),
    relexed: Tokens,
    roles: ArrayType(u16),
    scratch: Buffer,
    staged: Buffer,
    widths: ArrayType(?u32),

    pub fn init(
        gpa: std.mem.Allocator,
        element_count_max: u32,
        scratch_bytes_max: u32,
    ) std.mem.Allocator.Error!Formatter {
        assert(element_count_max > 0);
        assert(scratch_bytes_max > 0);

        var columns = try ArrayType(u32).init(gpa, element_count_max);
        errdefer columns.deinit(gpa);

        var elements = try ArrayType(Element).init(gpa, element_count_max);
        errdefer elements.deinit(gpa);

        var inner = try brace.Formatter.init(gpa, element_count_max, scratch_bytes_max);
        errdefer inner.deinit(gpa);

        var lists = try ArrayType(u8).init(gpa, element_count_max);
        errdefer lists.deinit(gpa);

        var mapped = try ArrayType(u32).init(gpa, element_count_max);
        errdefer mapped.deinit(gpa);

        var operand_ends = try ArrayType(u32).init(gpa, element_count_max);
        errdefer operand_ends.deinit(gpa);

        var operands = try ArrayType(u32).init(gpa, element_count_max);
        errdefer operands.deinit(gpa);

        var patched = try Buffer.init(gpa, scratch_bytes_max);
        errdefer patched.deinit(gpa);

        var patches = try ArrayType(Patch).init(gpa, element_count_max);
        errdefer patches.deinit(gpa);

        var rekinds = try ArrayType(Kind).init(gpa, element_count_max);
        errdefer rekinds.deinit(gpa);

        var relexed = try Tokens.init(gpa, element_count_max);
        errdefer relexed.deinit(gpa);

        var roles = try ArrayType(u16).init(gpa, element_count_max);
        errdefer roles.deinit(gpa);

        var scratch = try Buffer.init(gpa, scratch_bytes_max);
        errdefer scratch.deinit(gpa);

        var staged = try Buffer.init(gpa, scratch_bytes_max);
        errdefer staged.deinit(gpa);

        const widths = try ArrayType(?u32).init(gpa, element_count_max);

        return .{
            .columns = columns,
            .elements = elements,
            .inner = inner,
            .lists = lists,
            .mapped = mapped,
            .operand_ends = operand_ends,
            .operands = operands,
            .patched = patched,
            .patches = patches,
            .rekinds = rekinds,
            .relexed = relexed,
            .roles = roles,
            .scratch = scratch,
            .staged = staged,
            .widths = widths,
        };
    }

    pub fn deinit(formatter: *Formatter, gpa: std.mem.Allocator) void {
        assert(formatter.lists.capacity() == formatter.roles.capacity());
        assert(formatter.scratch.capacity() == formatter.staged.capacity());

        formatter.widths.deinit(gpa);
        formatter.staged.deinit(gpa);
        formatter.scratch.deinit(gpa);
        formatter.roles.deinit(gpa);
        formatter.relexed.deinit(gpa);
        formatter.rekinds.deinit(gpa);
        formatter.patches.deinit(gpa);
        formatter.patched.deinit(gpa);
        formatter.operands.deinit(gpa);
        formatter.operand_ends.deinit(gpa);
        formatter.mapped.deinit(gpa);
        formatter.lists.deinit(gpa);
        formatter.inner.deinit(gpa);
        formatter.elements.deinit(gpa);
        formatter.columns.deinit(gpa);
        formatter.* = undefined;
    }

    pub fn format(formatter: *Formatter, input: *const Input, out: *Buffer) FormatterError!void {
        assert(input.tokens.len == input.raw.len);
        assert(input.source.len <= std.math.maxInt(u32));

        if (broken(input)) return error.SourceInvalid;

        formatter.format_listed(input) catch return error.OutputExhausted;

        try formatter.arrays(input);
        try formatter.unformatted(input);

        out.clear();

        out.push(formatter.scratch.const_slice()) catch {
            out.clear();

            return error.OutputExhausted;
        };

        assert(out.count() == formatter.scratch.count());
    }

    pub fn range(
        formatter: *Formatter,
        input: *const Input,
        lines: walk.LineRange,
        out: *Buffer,
    ) FormatterError!Span {
        assert(lines.first <= lines.last);
        assert(input.tokens.len == input.raw.len);

        try formatter.format(input, out);

        return brace.span_of(out.const_slice(), lines) orelse error.SourceInvalid;
    }

    fn format_listed(formatter: *Formatter, input: *const Input) error{Overflow}!void {
        assert(input.tokens.len == input.raw.len);
        assert(formatter.lists.capacity() == formatter.roles.capacity());

        if (input.tokens.len > formatter.lists.capacity()) return error.Overflow;

        try brace.marked(Kind, input.tree, input.tokens, &formatter.roles);
        formatter.spanned(input);
        try formatter.listed(input);
        try formatter.operanded(input);

        const held: brace.Input = .{
            .added = &.{},
            .gives = &.{},
            .lists = formatter.lists.const_slice(),
            .macros = &.{},
            .marks = &.{},
            .nests = &.{},
            .opaques = &.{},
            .operand_ends = formatter.operand_ends.const_slice(),
            .operands = formatter.operands.const_slice(),
            .options = input.options,
            .origin = &.{},
            .origins = &.{},
            .policy = policy,
            .roles = formatter.roles.const_slice(),
            .source = input.source,
            .tokens = input.tokens,
        };

        try formatter.inner.format(&held, &formatter.scratch);
    }

    fn spanned(formatter: *Formatter, input: *const Input) void {
        const roles = formatter.roles.slice();

        assert(roles.len == input.tokens.len);
        assert(input.raw.len == input.tokens.len);

        for (input.raw, 0..) |kind, position| {
            if (kind != .text_line) continue;

            if (position < roles.len) roles[position] |= brace.role_span;
        }
    }

    fn listed(formatter: *Formatter, input: *const Input) error{Overflow}!void {
        assert(input.tokens.len == input.raw.len);
        assert(input.tokens.len <= std.math.maxInt(u32));

        formatter.lists.clear();

        for (input.tokens) |_| {
            try formatter.lists.pushed(0);
        }

        formatter.listed_layouts(input);

        const lists = formatter.lists.slice();

        for (input.tokens, 0..) |token, at| {
            if (token.is_punctuation(.semicolon)) lists[at] = brace.item_break;
        }

        formatter.spaces(input);
        formatter.listed_nodes(input);

        assert(formatter.lists.count() == input.tokens.len);
    }

    fn operanded(formatter: *Formatter, input: *const Input) error{Overflow}!void {
        assert(input.tokens.len == input.raw.len);
        assert(input.tokens.len <= formatter.operands.capacity());

        formatter.operands.clear();
        formatter.operand_ends.clear();

        for (input.tokens) |_| {
            try formatter.operands.pushed(brace.operand_none);
            try formatter.operand_ends.pushed(brace.operand_none);
        }

        const operands = formatter.operands.slice();
        const operand_ends = formatter.operand_ends.slice();

        for (input.tree.slice(), 0..) |node, index| {
            if (!infixed(node.kind)) continue;

            const left = input.tree.child_first_of(@intCast(index)) orelse continue;
            const left_end = input.tree.at(left).token_end;
            const operator = code_within(input.tokens, left_end, node.token_end) orelse continue;
            const held = if (equals_held(input, @intCast(index))) brace.operand_held else 0;

            assert(operator < operands.len);
            assert(node.token_start < operator);
            assert(node.token_start < brace.operand_held);

            operands[operator] = node.token_start | held;

            const last = code_before(input.tokens, node.token_end, operator) orelse continue;

            assert(last > operator);

            operand_ends[last] = @min(operand_ends[last], node.token_start);
        }

        for (input.tree.slice(), 0..) |node, index| {
            if (!branch_headed(node.kind)) continue;

            branches_ended(input, @intCast(index), operand_ends);
        }

        assert(formatter.operands.count() == input.tokens.len);
        assert(formatter.operand_ends.count() == input.tokens.len);
    }

    fn listed_layouts(formatter: *Formatter, input: *const Input) void {
        const lists = formatter.lists.slice();

        assert(lists.len == input.tokens.len);
        assert(input.raw.len == input.tokens.len);

        for (input.tree.slice()) |node| {
            const braced = switch (node.kind) {
                .builtin_call, .call, .fn_proto => false,
                .array_init,
                .array_init_dot,
                .container_decl,
                .error_set_decl,
                .struct_init,
                .struct_init_dot,
                .tagged_union,
                => true,
                else => continue,
            };

            const proto = node.kind == .fn_proto;
            const start = node.token_start;
            const end = node.token_end;
            const open, const close = list_of(input, start, end, braced, proto) orelse continue;
            const layout = layout_of(input, node.kind, open, close);
            const inline_init = layout == brace.item_inline and initializes(node.kind);
            const flat: u8 = if (inline_init) brace.item_flat else 0;

            lists[open] = layout | flat | commas_of(input, node.kind, layout, open, close);
        }
    }

    fn listed_nodes(formatter: *Formatter, input: *const Input) void {
        assert(formatter.lists.count() == input.tokens.len);
        assert(input.raw.len == input.tokens.len);

        for (input.tree.slice(), 0..) |node, index| {
            const start = node.token_start;
            const end = node.token_end;

            switch (node.kind) {
                .block, .container_decl, .error_set_decl, .@"switch", .tagged_union => {
                    formatter.glued(input, start, end, node.kind);
                },
                else => {},
            }

            switch (node.kind) {
                .@"asm" => formatter.assembled(input, @intCast(index)),
                .array_type => formatter.array_typed(input, start, end),
                .block => formatter.blocked(input, start, end),
                .assign_destructure => formatter.destructured(input, start, end),
                .@"for" => formatter.iterated(input, start, end),
                .@"while" => formatter.continued(input, start, end),
                .root => formatter.rooted(input),
                .@"switch" => formatter.switched(input, start, end),
                .switch_case => formatter.cased(input, start, end),
                else => {},
            }
        }
    }

    fn spaces(formatter: *Formatter, input: *const Input) void {
        const tokens = input.tokens;
        const lists = formatter.lists.slice();

        assert(lists.len == tokens.len);
        assert(input.raw.len == tokens.len);

        if (tokens.len == 0) return;

        for (1..tokens.len) |index| {
            const at: u32 = @intCast(index);
            const before = code_before(tokens, at, 0) orelse continue;
            const operated = spaces_operated(input, at, before);
            const typed = spaces_typed(input, at, before);
            const spaced = operated or typed;

            if (spaced) lists[at] |= brace.item_spaced;
        }
    }

    fn commas(
        formatter: *Formatter,
        input: *const Input,
        from: u32,
        to: u32,
        code: u8,
        stop: []const []const u8,
    ) void {
        assert(from <= to);
        assert(to <= input.tokens.len);
        assert(stop.len <= std.math.maxInt(u32));

        const lists = formatter.lists.slice();
        var depth: u32 = 0;

        for (from..to) |at| {
            const token = input.tokens[at];

            if (opens(token.kind)) {
                depth += 1;

                continue;
            }

            if (closes(token.kind)) {
                depth -|= 1;

                continue;
            }

            if (depth > 0) continue;
            if (word_in(stop, token.text(input.source))) return;

            if (token.is_punctuation(.comma)) lists[at] = code;
        }
    }

    fn destructured(formatter: *Formatter, input: *const Input, start: u32, end: u32) void {
        assert(start <= end);
        assert(end <= input.tokens.len);

        formatter.commas(input, start, end, brace.item_join, &.{"="});
    }

    fn array_typed(formatter: *Formatter, input: *const Input, start: u32, end: u32) void {
        assert(start <= end);
        assert(end <= input.tokens.len);

        const tokens = input.tokens;
        const close = closing(tokens, start, end) orelse return;
        const strung = strung_within(input, start, close);

        if (same_line(input, start, close)) {
            if (!strung) return;
        }

        const lists = formatter.lists.slice();
        var depth: u32 = 0;

        lists[start] |= brace.item_edges;

        for (start + 1..close) |index| {
            const at: u32 = @intCast(index);
            const kind = tokens[at].kind;

            if (opens(kind)) {
                depth += 1;

                continue;
            }

            if (closes(kind)) {
                depth -|= 1;

                continue;
            }

            if (depth > 0) continue;
            if (!kind.eql(.{ .punctuation = .colon })) continue;
            if (tokens[code_after(tokens, at, close)].kind == .block_start) continue;

            if (code_before(tokens, at, start + 1)) |before| {
                lists[before] |= brace.item_break;
            }

            lists[at] |= brace.item_break;
        }
    }

    fn rooted(formatter: *Formatter, input: *const Input) void {
        assert(input.tokens.len <= std.math.maxInt(u32));
        assert(formatter.lists.count() == input.tokens.len);

        formatter.commas(input, 0, @intCast(input.tokens.len), brace.item_break, &.{});
    }

    fn assembled(formatter: *Formatter, input: *const Input, node: u32) void {
        assert(node < input.tree.count());
        assert(input.tree.at(node).kind == .@"asm");

        const tree = input.tree;
        const tokens = input.tokens;
        const lists = formatter.lists.slice();
        const close = tree.at(node).token_end - 1;
        const template = tree.child_first_of(node) orelse return;
        const template_last = tree.at(template).token_end - 1;
        const operands = asm_operands_of(tree, template);
        const first = code_after(tokens, template_last, close);

        assert(tokens[close].is_punctuation(.paren_close));

        if (first == close) return;

        if (operands.clobbers) |clobbers| joined(lists, tree.at(clobbers).token_end - 1);

        const bare = operands.outputs == null and operands.inputs == null;

        if (bare) {
            const colon = asm_clobbers_colon(input, operands) orelse return;

            asm_colons_joined(lists, tokens, template_last, colon);

            return;
        }

        severed(lists, template_last);

        const second = asm_section(formatter, input, first, operands.outputs, close);
        if (second == close) return;

        const third = asm_section(formatter, input, second, operands.inputs, close);

        assert(third == close or tokens[third].is_punctuation(.colon));
    }

    fn asm_section(
        formatter: *Formatter,
        input: *const Input,
        colon: u32,
        last: ?u32,
        close: u32,
    ) u32 {
        assert(colon < close);
        assert(input.tokens[colon].is_punctuation(.colon));
        if (last) |held| assert(held < std.math.maxInt(u32));

        const tokens = input.tokens;
        const lists = formatter.lists.slice();

        const held = last orelse {
            const next = code_after(tokens, colon, close);

            if (next != close) severed(lists, colon);

            return next;
        };

        const end = input.tree.at(held).token_end;
        const after = code_after(tokens, end - 1, close);
        const trailing = after != close and tokens[after].is_punctuation(.comma);
        const stop = if (trailing) after + 1 else end;

        formatter.commas(input, colon + 1, stop, brace.item_break, &.{});

        if (!trailing) {
            assert(after < std.math.maxInt(u32));

            return after;
        }

        return code_after(tokens, after, close);
    }

    fn continued(formatter: *Formatter, input: *const Input, start: u32, end: u32) void {
        assert(start <= end);
        assert(end <= input.tokens.len);

        const tokens = input.tokens;
        const open = paren_within(tokens, start, end) orelse return;
        const close = closing(tokens, open, end) orelse return;
        var at = code_after(tokens, close, end);
        if (at == tokens.len) return;

        if (walk.text_is(tokens[at].text(input.source), "|")) {
            const shut = bar_within(input, at + 1, end) orelse return;

            at = code_after(tokens, shut, end);

            if (at == tokens.len) return;
        }

        if (tokens[at].is_punctuation(.colon)) formatter.lists.slice()[at] |= brace.item_spaced;
    }

    fn iterated(formatter: *Formatter, input: *const Input, start: u32, end: u32) void {
        assert(start <= end);
        assert(end <= input.tokens.len);

        const tokens = input.tokens;
        const open = paren_within(tokens, start, end) orelse return;
        const close = closing(tokens, open, end) orelse return;

        formatter.lists.slice()[open] = layout_of(input, .call, open, close);

        const pipe = code_within(tokens, close + 1, end) orelse return;
        if (!walk.text_is(tokens[pipe].text(input.source), "|")) return;

        const shut = bar_within(input, pipe + 1, end) orelse return;
        const trailing = comma_at(tokens, code_before(tokens, shut, pipe + 1));
        const code = if (trailing) brace.item_break else brace.item_join;

        formatter.commas(input, pipe + 1, shut, code, &.{});
    }

    fn glued(formatter: *Formatter, input: *const Input, start: u32, end: u32, kind: Kind) void {
        assert(start <= end);
        assert(end <= input.tokens.len);
        assert(kind.is_node());

        const tokens = input.tokens;
        const open, const close = list_of(input, start, end, true, false) orelse return;
        const before = code_before(tokens, open, 0);
        const headed = glued_headed(input, open, before);
        const preceding = before orelse open;
        const paren = glued_paren(input, preceding);
        const spanned_lines = glued_spanned(input, paren, open, preceding);
        const fallback = glued_fallback(input, open, before);
        const hugged = !spanned_lines and !fallback;
        const lists = formatter.lists.slice();

        if (headed) {
            if (hugged) lists[open] |= brace.item_glued;
            if (kind != .error_set_decl) lists[open] |= brace.item_spaced;
        }

        if (kind != .block) return;

        formatter.glued_label(input, start, open);
        if (paren == null) return;

        const after = code_within(tokens, close + 1, @intCast(tokens.len)) orelse return;
        if (input.raw[after] != .else_keyword) return;
        if (tokens[after - 1].kind == .comment) return;

        lists[after] |= brace.item_glued;
    }

    fn glued_label(formatter: *Formatter, input: *const Input, label: u32, open: u32) void {
        assert(label <= open);
        assert(open < input.tokens.len);

        const tokens = input.tokens;

        if (label == open) return;
        if (input.raw[label] != .identifier) return;

        const colon = code_after(tokens, label, open);
        if (!tokens[colon].is_punctuation(.colon)) return;
        if (code_after(tokens, colon, open) != open) return;

        const before = code_before(tokens, label, 0);
        const preceding = before orelse label;
        const paren = glued_paren(input, preceding);
        const spanned_lines = glued_spanned(input, paren, label, preceding);
        const fallback = glued_fallback(input, label, before);
        const hugged = !spanned_lines and !fallback;
        const lists = formatter.lists.slice();

        if (!glued_headed(input, label, before)) return;

        if (hugged) lists[label] |= brace.item_glued;

        lists[label] |= brace.item_spaced;
    }

    fn blocked(formatter: *Formatter, input: *const Input, start: u32, end: u32) void {
        assert(start <= end);
        assert(end <= input.tokens.len);

        const open, const close = list_of(input, start, end, true, false) orelse return;

        if (code_within(input.tokens, open + 1, close) != null) {
            formatter.lists.slice()[open] |= brace.item_edges;
        }
    }

    fn switched(formatter: *Formatter, input: *const Input, start: u32, end: u32) void {
        assert(start <= end);
        assert(end <= input.tokens.len);

        const open, const close = list_of(input, start, end, true, false) orelse return;

        if (code_within(input.tokens, open + 1, close) != null) {
            formatter.lists.slice()[open] |= brace.item_edges | brace.item_commas;
        }
    }

    fn cased(formatter: *Formatter, input: *const Input, start: u32, end: u32) void {
        assert(start <= end);
        assert(end <= input.tokens.len);

        const tokens = input.tokens;
        const arrow = cased_arrow(input, start, end) orelse return;
        const trailing = comma_at(tokens, code_before(tokens, arrow, start));
        const commented = cased_commented(input, start, arrow);
        const separated = trailing or commented;
        const code = if (separated) brace.item_break else brace.item_join;

        formatter.commas(input, start, arrow, code, &.{});
        formatter.cased_capture(input, arrow, end);

        const after = code_within(tokens, end, @intCast(tokens.len)) orelse return;

        if (tokens[after].is_punctuation(.comma)) formatter.lists.slice()[after] = brace.item_break;
    }

    fn cased_capture(formatter: *Formatter, input: *const Input, arrow: u32, end: u32) void {
        assert(arrow < end);
        assert(end <= input.tokens.len);

        const tokens = input.tokens;
        const pipe = code_within(tokens, arrow + 1, end) orelse return;
        if (!walk.text_is(tokens[pipe].text(input.source), "|")) return;

        const shut = bar_within(input, pipe + 1, end) orelse return;

        formatter.commas(input, pipe + 1, shut, brace.item_join, &.{});
    }

    fn mapping(formatter: *Formatter, input: *const Input) bool {
        assert(input.tokens.len == input.raw.len);
        assert(formatter.relexed.count() <= formatter.rekinds.capacity());

        const printed = formatter.scratch.const_slice();
        const relexed = formatter.relexed.slice();

        raw_of(Kind, relexed, &formatter.rekinds) catch return false;

        formatter.mapped.clear();

        if (relexed.len != input.tokens.len) return false;

        for (input.tokens, relexed, 0..) |token, written, index| {
            const text = token.text(input.source);
            const held = written.text(printed);

            const agrees = if (token.kind == .comment)
                written.kind == .comment
            else
                mapping_agrees(text, held);

            if (!agrees) return false;
            if (formatter.mapped.full()) return false;

            formatter.mapped.push(@intCast(index));
        }

        assert(formatter.mapped.count() == input.tokens.len);

        return true;
    }

    fn arrays(formatter: *Formatter, input: *const Input) FormatterError!void {
        assert(input.tokens.len == input.raw.len);
        assert(formatter.lists.count() == input.tokens.len);

        if (!arrayed(input)) return;

        formatter.relexed.clear();

        formatter.relexed.lex(.of(.zig), formatter.scratch.const_slice()) catch {
            return error.OutputExhausted;
        };

        if (!formatter.mapping(input)) return;

        formatter.patches.clear();
        formatter.patched.clear();

        for (input.tree.slice()) |node| {
            const array = node.kind == .array_init or node.kind == .array_init_dot;
            if (!array) continue;

            formatter.array_laid(input, node.token_start, node.token_end) catch {
                return error.OutputExhausted;
            };
        }

        if (formatter.patches.count() == 0) return;

        formatter.arrays_patched() catch return error.OutputExhausted;
    }

    fn arrays_patched(formatter: *Formatter) error{Overflow}!void {
        assert(formatter.patches.count() > 0);
        assert(formatter.patched.count() <= formatter.patched.capacity());

        std.sort.pdq(Patch, formatter.patches.slice(), {}, patch_before);
        formatter.staged.clear();

        const printed = formatter.scratch.const_slice();
        const replacements = formatter.patched.const_slice();
        var cursor: u32 = 0;

        for (formatter.patches.const_slice()) |patch| {
            if (patch.from < cursor) return error.Overflow;

            try formatter.staged.push(printed[cursor..patch.from]);
            try formatter.staged.push(replacements[patch.start..][0..patch.size]);
            cursor = patch.to;
        }

        try formatter.staged.push(printed[cursor..]);
        std.mem.swap(Buffer, &formatter.scratch, &formatter.staged);

        assert(cursor <= formatter.staged.count());
    }

    fn array_laid(
        formatter: *Formatter,
        input: *const Input,
        start: u32,
        end: u32,
    ) error{Overflow}!void {
        assert(start <= end);
        assert(end <= input.tokens.len);

        const open, const close = list_of(input, start, end, true, false) orelse return;
        const held = listing(input, open, close);
        const loose = held.trailing or held.plain or held.stringed;

        if (held.items == 0) return;
        if (held.sole) return;
        if (!loose) return;

        try formatter.array_elements(input, open, close);

        const indent = formatter.array_indent(open, close) orelse return;

        try formatter.array_widths(input);

        const begun = formatter.patches.count();
        const kept = try formatter.array_sections(input, open, close, indent);

        if (!kept) formatter.patches.truncate(begun);
    }

    fn array_sections(
        formatter: *Formatter,
        input: *const Input,
        open: u32,
        close: u32,
        indent: Indent,
    ) error{Overflow}!bool {
        assert(open < std.math.maxInt(u32));
        assert(close < std.math.maxInt(u32));
        assert(indent.line <= indent.head);

        const element_count = formatter.elements.count();

        assert(element_count > 0);
        assert(formatter.widths.count() == element_count);

        var remaining: u32 = 0;

        while (remaining < element_count) {
            const row_count = formatter.row_size(input, remaining, close);
            const section = formatter.section_of(input, remaining, row_count, open, close);

            assert(section >= 1);
            assert(section <= element_count - remaining);

            try formatter.columns_of(remaining, section, row_count);

            const row: Row = .{ .remaining = remaining, .section = section, .size = row_count };
            const kept = try formatter.array_row(input, row, close, indent);
            if (!kept) return false;

            remaining += section;
        }

        assert(remaining == element_count);

        return true;
    }

    fn array_row(
        formatter: *Formatter,
        input: *const Input,
        row: Row,
        close: u32,
        indent: Indent,
    ) error{Overflow}!bool {
        assert(row.size >= 1);
        assert(row.remaining + row.section <= formatter.widths.count());
        assert(close < std.math.maxInt(u32));
        assert(indent.line <= indent.head);

        const columns = formatter.columns.const_slice();
        const section_end = row.remaining + row.section;
        var column: u32 = 0;

        for (row.remaining..section_end) |index| {
            const at: u32 = @intCast(index);
            const ends_section = at + 1 == section_end;
            const width = formatter.widths.get(at);

            const ends_row = ends_section or
                column + 1 == row.size or
                width == null or
                formatter.widths.get(at + 1) == null;

            const pad: u32 = if (ends_row) 0 else columns[column] - width.?;
            const ends: Ends = .{ .row = ends_row, .section = ends_section };
            const kept = try formatter.array_gap(input, at, ends, pad, close, indent);
            if (!kept) return false;

            column = if (ends_row) 0 else column + 1;
        }

        return true;
    }

    fn array_elements(
        formatter: *Formatter,
        input: *const Input,
        open: u32,
        close: u32,
    ) error{Overflow}!void {
        assert(open < close);
        assert(close < input.tokens.len);

        formatter.elements.clear();

        var depth: u32 = 0;
        var head: ?u32 = null;
        var tail: ?u32 = null;

        for (open + 1..close) |index| {
            const at: u32 = @intCast(index);
            const kind = input.tokens[at].kind;
            const separating = depth == 0 and kind.eql(.{ .punctuation = .comma });

            if (kind == .comment) continue;

            if (separating) {
                if (head) |from| {
                    const element: Element = .{ .head = from, .tail = tail.?, .comma = at };

                    try formatter.elements.pushed(element);
                }

                head = null;
                tail = null;

                continue;
            }

            if (opens(kind)) {
                depth += 1;
            } else if (closes(kind)) {
                depth -|= 1;
            } else {}

            head = head orelse at;
            tail = at;
        }

        const from = head orelse return;
        const to = tail orelse return;

        try formatter.elements.pushed(.{ .head = from, .tail = to, .comma = null });
    }

    fn array_indent(formatter: *const Formatter, open: u32, close: u32) ?Indent {
        const printed = formatter.scratch.const_slice();
        const elements = formatter.elements.const_slice();

        assert(elements.len > 0);
        assert(open < close);

        const head = formatter.printed_start(elements[0].head);
        const tail = formatter.printed_end(elements[elements.len - 1].tail);
        const opened = printed[formatter.printed_end(open)..head];
        if (std.mem.findScalar(u8, opened, '\n') == null) return null;

        const shut = printed[tail..formatter.printed_start(close)];
        if (std.mem.findScalar(u8, shut, '\n') == null) return null;

        const break_at = std.mem.findScalarLast(u8, printed[0..head], '\n');
        const line: u32 = if (break_at) |at| @intCast(at + 1) else 0;

        for (printed[line..head]) |byte| {
            if (byte != ' ') return null;
        }

        return .{ .line = line, .head = head };
    }

    fn printed_start(formatter: *const Formatter, at: u32) u32 {
        assert(at < formatter.mapped.count());

        const index = formatter.mapped.get(at);

        assert(index < formatter.relexed.count());

        return formatter.relexed.slice()[index].offset;
    }

    fn printed_end(formatter: *const Formatter, at: u32) u32 {
        assert(at < formatter.mapped.count());

        const index = formatter.mapped.get(at);

        assert(index < formatter.relexed.count());

        return formatter.relexed.slice()[index].end();
    }

    fn array_widths(formatter: *Formatter, input: *const Input) error{Overflow}!void {
        assert(formatter.elements.count() > 0);
        assert(formatter.mapped.count() == input.tokens.len);

        formatter.widths.clear();

        for (formatter.elements.const_slice()) |element| {
            const strung = strung_within(input, element.head, element.tail + 1);
            const from = formatter.printed_start(element.head);
            const to = formatter.printed_end(element.tail);
            const printed = formatter.scratch.const_slice()[from..to];
            const width = if (strung) null else width_of(printed);

            try formatter.widths.pushed(width);
        }

        assert(formatter.widths.count() == formatter.elements.count());
    }

    fn separator_of(formatter: *const Formatter, index: u32) u32 {
        assert(index < formatter.elements.count());

        const element = formatter.elements.get(index);

        assert(element.head <= element.tail);

        return element.comma orelse element.tail;
    }

    fn row_size(formatter: *const Formatter, input: *const Input, remaining: u32, close: u32) u32 {
        const element_count = formatter.elements.count();

        assert(remaining < element_count);
        assert(close < input.tokens.len);

        for (remaining..element_count) |index| {
            const at: u32 = @intCast(index);

            if (formatter.widths.get(at) == null) {
                const returned = @max(at - remaining, 1);

                assert(returned < std.math.maxInt(u32));

                return returned;
            }

            const separator = formatter.separator_of(at);
            const after = code_after(input.tokens, separator, close);

            if (!same_line(input, separator, after)) {
                assert(at - remaining + 1 < std.math.maxInt(u32));

                return at - remaining + 1;
            }
        }

        const trailing = comma_at(input.tokens, code_before(input.tokens, close, 0));
        if (trailing) return 1;
        assert(element_count - remaining < std.math.maxInt(u32));

        return element_count - remaining;
    }

    fn section_of(
        formatter: *const Formatter,
        input: *const Input,
        remaining: u32,
        row_count: u32,
        open: u32,
        close: u32,
    ) u32 {
        assert(open < std.math.maxInt(u32));
        assert(close < std.math.maxInt(u32));

        const element_count = formatter.elements.count();

        assert(remaining < element_count);
        assert(row_count >= 1);
        assert(row_count <= element_count - remaining);

        var line_start = row_count;

        for (row_count..element_count - remaining) |index| {
            const at: u32 = @intCast(index);
            const head = formatter.elements.get(remaining + at).head;
            const before = code_before(input.tokens, head, open) orelse open;
            const unprinted = formatter.widths.get(at - 1) == null;
            const broken_line = unprinted or !same_line(input, before, head);

            if (broken_line) line_start = at;
            if (trailed(input, formatter.separator_of(remaining + at), close)) return line_start;
        }

        assert(element_count - remaining < std.math.maxInt(u32));

        return element_count - remaining;
    }

    fn columns_of(
        formatter: *Formatter,
        remaining: u32,
        section: u32,
        row_count: u32,
    ) error{Overflow}!void {
        assert(row_count >= 1);
        assert(remaining + section <= formatter.widths.count());

        formatter.columns.clear();

        for (0..row_count) |_| {
            try formatter.columns.pushed(0);
        }

        const columns = formatter.columns.slice();
        var column: u32 = 0;

        for (remaining..remaining + section) |index| {
            const width = formatter.widths.get(@intCast(index)) orelse {
                column = 0;

                continue;
            };

            columns[column] = @max(columns[column], width);
            column = (column + 1) % row_count;
        }

        assert(column < row_count);
    }

    fn array_gap(
        formatter: *Formatter,
        input: *const Input,
        index: u32,
        ends: Ends,
        pad: u32,
        close: u32,
        indent: Indent,
    ) error{Overflow}!bool {
        assert(pad < std.math.maxInt(u32));
        assert(indent.line <= indent.head);
        if (ends.section) assert(ends.row);
        if (ends.row) assert(pad == 0);

        const elements = formatter.elements.const_slice();

        assert(index < elements.len);
        assert(close < input.tokens.len);

        const element = elements[index];
        const from = formatter.printed_end(element.tail);

        const to = if (index + 1 < elements.len)
            formatter.printed_start(elements[index + 1].head)
        else
            formatter.printed_start(close);

        const gap = formatter.scratch.const_slice()[from..to];
        const commented = std.mem.find(u8, gap, "//") != null;
        const patch = formatter.patched.count();

        if (!ends.row) {
            if (commented) return false;
        }

        try formatter.array_gap_written(input, index, ends, pad, gap, indent);

        if (std.mem.eql(u8, formatter.patched.const_slice()[patch..], gap)) {
            formatter.patched.truncate(patch);

            return true;
        }

        const size = formatter.patched.count() - patch;

        try formatter.patches.pushed(.{
            .from = from,
            .to = to,
            .start = patch,
            .size = size,
        });

        return true;
    }

    fn array_gap_written(
        formatter: *Formatter,
        input: *const Input,
        index: u32,
        ends: Ends,
        pad: u32,
        gap: []const u8,
        indent: Indent,
    ) error{Overflow}!void {
        assert(index < std.math.maxInt(u32));
        assert(pad < std.math.maxInt(u32));
        assert(gap.len <= std.math.maxInt(u32));
        if (ends.section) assert(ends.row);
        if (ends.row) assert(pad == 0);

        const element = formatter.elements.get(index);
        const element_count = formatter.elements.count();
        const commented = std.mem.find(u8, gap, "//") != null;

        assert(index < element_count);
        assert(indent.line <= indent.head);

        if (!ends.row) {
            assert(!commented);

            try formatter.patched.push(", ");

            for (0..pad) |_| {
                try formatter.patched.push(" ");
            }

            return;
        }

        if (input.raw[element.tail] == .text_line) return formatter.patched.push(gap);

        const ended = index + 1 == element_count or commented;

        if (ended) {
            if (element.comma == null) try formatter.patched.push(",");

            return formatter.patched.push(gap);
        }

        try formatter.array_gap_break(input, index, ends.section, indent);
    }

    fn array_gap_break(
        formatter: *Formatter,
        input: *const Input,
        index: u32,
        ends_section: bool,
        indent: Indent,
    ) error{Overflow}!void {
        const tokens = input.tokens;
        const elements = formatter.elements.const_slice();

        assert(index + 1 < elements.len);
        assert(indent.line <= indent.head);

        const from = tokens[formatter.separator_of(index)].end();
        const to = tokens[elements[index + 1].head].offset;
        const between = input.source[from..to];
        const break_head = std.mem.findScalar(u8, between, '\n') orelse between.len;
        const break_tail = std.mem.findScalarLast(u8, between, '\n') orelse between.len;
        const blank = !ends_section and break_head != break_tail;

        try formatter.patched.push(",\n");

        if (blank) try formatter.patched.push("\n");

        try formatter.patched.push(formatter.scratch.const_slice()[indent.line..indent.head]);
    }

    fn unformatted(formatter: *Formatter, input: *const Input) FormatterError!void {
        assert(input.tokens.len == input.raw.len);
        assert(input.source.len <= std.math.maxInt(u32));

        if (!silenced(input)) return;

        formatter.relexed.clear();

        formatter.relexed.lex(.of(.zig), formatter.scratch.const_slice()) catch {
            return error.OutputExhausted;
        };

        formatter.staged.clear();

        formatter.unformatted_copied(input) catch |err| switch (err) {
            error.Overflow => return error.OutputExhausted,
            error.SourceInvalid => return error.SourceInvalid,
        };

        std.mem.swap(Buffer, &formatter.scratch, &formatter.staged);
    }

    fn unformatted_copied(
        formatter: *Formatter,
        input: *const Input,
    ) error{ Overflow, SourceInvalid }!void {
        const printed = formatter.scratch.const_slice();
        const relexed = formatter.relexed.slice();
        const source = input.source;

        assert(formatter.staged.count() == 0);
        assert(relexed.len <= std.math.maxInt(u32));

        var cursor: u32 = 0;
        var copied: u32 = 0;
        var disabled: ?u32 = null;

        for (input.tokens) |comment| {
            if (comment.kind != .comment) continue;

            const written_at = comment_within(relexed, cursor) orelse return error.SourceInvalid;
            const written = relexed[written_at];
            const content = pragma(comment.text(source));

            cursor = written_at + 1;

            if (disabled) |start| {
                if (std.mem.eql(u8, content, format_on)) {
                    const end = @max(comment.offset, start);

                    try fixed(&formatter.staged, source[start..end]);
                    try formatter.staged.push(format_on_line);
                    copied = written.end();
                    disabled = null;
                }
            } else if (std.mem.eql(u8, content, format_off)) {
                try formatter.staged.push(printed[copied..written.offset]);
                try formatter.staged.push(format_off_line);
                disabled = line_past(source, comment);
            } else {}
        }

        if (comment_within(relexed, cursor) != null) return error.SourceInvalid;

        if (disabled) |start| {
            try fixed(&formatter.staged, source[start..]);
        } else {
            try formatter.staged.push(printed[copied..]);
        }
    }
};

pub const Input = struct {
    options: Options,
    outcome: Structure,
    raw: []const Kind,
    source: []const u8,
    tokens: []const Token,
    tree: *const Tree,
};

const Element = struct {
    head: u32,
    tail: u32,
    comma: ?u32,
};

const Ends = struct {
    row: bool,
    section: bool,
};

const Indent = struct {
    line: u32,
    head: u32,
};

const Listing = struct {
    declared: bool = false,
    documented: bool = false,
    documented_top: bool = false,
    items: u32 = 0,
    plain: bool = false,
    plain_top: bool = false,
    sole: bool = false,
    stringed: bool = false,
    trailing: bool = false,
};

const Operands = struct {
    clobbers: ?u32,
    inputs: ?u32,
    outputs: ?u32,
};

const Patch = struct {
    from: u32,
    to: u32,
    start: u32,
    size: u32,
};

const Row = struct {
    remaining: u32,
    section: u32,
    size: u32,
};

const ancestor_walk_max: u32 = 1 << 12;
const asm_colon_count: u32 = 3;
const branch_child_max: u32 = 1 << 12;
const compared_texts = [_][]const u8{ "!=", "<=", "==", ">=" };
const format_off = "zig fmt: off";
const format_off_line = "// zig fmt: off\n";
const format_on = "zig fmt: on";
const format_on_line = "// zig fmt: on";
const item_codes: u8 = brace.item_lines | brace.item_inline | brace.item_break;
const payload_token_max: u32 = 8;
const tab_spaces = "    ";

pub const policy: brace.Policy = .{
    .align_colons = true,
    .angle_calls = false,
    .angle_spreads = false,
    .angle_objects = false,
    .angle_types = false,
    .arm_bars = false,
    .arm_empties = false,
    .arm_flattens = false,
    .arm_guards = false,
    .arrow_after = &.{"anyframe"},
    .arrow_bodies = false,
    .arrow_commas = false,
    .arrow_parens = false,
    .asm_operands = true,
    .assign_groups = false,
    .assign_joins = false,
    .assign_lines = false,
    .assign_values = false,
    .assign_wraps = false,
    .chain_lets = false,
    .chain_simples = false,
    .chain_soles = false,
    .chain_hugs = false,
    .chain_joins = false,
    .chain_groups = false,
    .chain_width = 0,
    .call_budgets = false,
    .call_nests = false,
    .call_width = 0,
    .attribute_ends = false,
    .attribute_joins = false,
    .attribute_spans = false,
    .attribute_width = 0,
    .attribute_words = &.{},
    .bar_aligns = false,
    .bar_levels = true,
    .binary_lines = false,
    .binary_parts = false,
    .binding_bases = &.{},
    .binding_codes = true,
    .binding_leads = false,
    .binder_words = &.{},
    .binding_words = &.{
        &.{ "*", "/", "%", "**", "*%", "*|", "||" },
        &.{ "+", "-", "++", "+%", "-%", "+|", "-|" },
        &.{ "<<", ">>", "<<|" },
        &.{"&"},
        &.{"^"},
        &.{"|"},
        &.{ "orelse", "catch" },
        &.{ "==", "!=", "<", ">", "<=", ">=" },
        &.{"and"},
        &.{"or"},
    },
    .blank_edges = false,
    .blank_max = 1,
    .block_chains = false,
    .block_joins = false,
    .block_leads = &.{},
    .block_words = &.{ "comptime", "fn", "test" },
    .body_owns = false,
    .body_settles = false,
    .body_parts = false,
    .body_words = &.{},
    .brace_bodies = false,
    .brace_comments = false,
    .brace_continues = true,
    .brace_counts = true,
    .brace_dedents = false,
    .brace_hugs = true,
    .brace_leads = false,
    .brace_levels = true,
    .brace_pairs = false,
    .brace_parts = false,
    .brace_spaces = true,
    .brace_spans = true,
    .brace_words = &.{ "enum", "opaque", "struct", "union" },
    .branch_joins = false,
    .branch_width = 0,
    .branch_words = &.{},
    .bracket_types = true,
    .build_blocks = false,
    .carriage_breaks = true,
    .callee_marks = &.{},
    .callee_words = &.{},
    .cast_joins = false,
    .cast_words = &.{},
    .clause_bases = false,
    .clause_ends = false,
    .clause_heads = &.{},
    .clause_lines = false,
    .clause_values = &.{},
    .clause_words = &.{},
    .close_hugs = false,
    .colon_continues = false,
    .comma_continues = false,
    .comma_adds = false,
    .comma_drops = false,
    .comma_joins = true,
    .comma_parts = false,
    .comment_carries = false,
    .comment_dedents = false,
    .comment_gaps = false,
    .comment_leads = false,
    .comment_levels = true,
    .comment_opens = false,
    .comment_spaces = false,
    .comment_suffix = false,
    .comment_tails = false,
    .compose_parts = false,
    .construct_words = &.{},
    .continue_words = &.{
        "!=",
        "%",
        "*%",
        "**",
        "*|",
        "+",
        "++",
        "+%",
        "+|",
        "-|",
        "/",
        "<",
        "<<",
        "<<|",
        "<=",
        "==",
        ">",
        ">=",
        ">>",
        "^",
        "and",
        "catch",
        "or",
        "orelse",
        "||",
    },
    .convention_strings = false,
    .dangling_blanks = false,
    .define_joins = false,
    .define_widths = false,
    .define_words = &.{},
    .declare_lines = false,
    .declaration_words = &.{},
    .declare_words = &.{},
    .decorators = false,
    .dedent_words = &.{},
    .document_blocks = false,
    .edge_blanks = true,
    .else_width = 0,
    .empty_follows = &.{},
    .empty_joins = false,
    .empty_semis = false,
    .empty_words = &.{},
    .end_words = &.{},
    .field_width = 0,
    .fill_reserve = 1,
    .follow_heads = &.{},
    .follow_words = &.{},
    .gap_words = &.{
        "asm",
        "comptime",
        "defer",
        "else",
        "errdefer",
        "fn",
        "for",
        "if",
        "nosuspend",
        "resume",
        "return",
        "suspend",
        "switch",
        "try",
        "volatile",
        "while",
    },
    .generic_levels = false,
    .generic_nests = false,
    .generic_parts = false,
    .group_words = &.{},
    .head_blanks = false,
    .head_blocks = false,
    .head_stops = &.{ "catch", "orelse" },
    .header_braces = true,
    .header_extends = false,
    .header_joins = false,
    .header_levels = true,
    .header_lines = false,
    .header_parens = false,
    .header_widths = false,
    .header_words = &.{ "for", "if", "while" },
    .heritage_parts = false,
    .hole_spaces = false,
    .hug_braces = false,
    .hug_lambdas = false,
    .hug_lasts = false,
    .hug_soles = false,
    .hug_words = &.{ "align", "callconv", "enum", "error", "union" },
    .index_continues = false,
    .inline_comments = false,
    .inline_layout = false,
    .item_words = &.{},
    .key_numbers = false,
    .key_quotes = false,
    .key_words = &.{},
    .keyword_gaps = false,
    .label_lines = true,
    .label_words = &.{ "break", "continue" },
    .lambda_flattens = false,
    .lead_words = &.{},
    .level_words = &.{"else"},
    .lifetime_tight = false,
    .link_levels = false,
    .link_nests = false,
    .link_spans = false,
    .list_blanks = false,
    .list_comments = false,
    .list_fills = false,
    .list_groups = false,
    .list_hugs = false,
    .list_leads = &.{},
    .list_mixes = 0,
    .list_tight = &.{},
    .list_sorts = false,
    .list_spreads = false,
    .list_width = 0,
    .list_words = &.{},
    .literal_joins = false,
    .literal_width = 0,
    .macro_bodies = false,
    .macro_defines = false,
    .macro_gaps = false,
    .macro_indents = false,
    .macro_spans = false,
    .member_words = &.{},
    .nested_levels = false,
    .number_forms = false,
    .object_words = &.{},
    .operand_joins = false,
    .operand_levels = false,
    .operand_words = &.{"assert"},
    .operator_words = &.{},
    .order_words = &.{ "@ptrCast", "@alignCast", "@addrSpaceCast", "@constCast", "@volatileCast" },
    .parameter_words = &.{},
    .pattern_frames = false,
    .pattern_words = &.{},
    .postfix_words = &.{},
    .prefix_words = &.{"@"},
    .printed_gaps = false,
    .raise_hugged = false,
    .regex_flags = false,
    .sentinel_colons = true,
    .sequence_lines = false,
    .sequence_stops = &.{},
    .return_parens = false,
    .rest_binds = false,
    .root_joins = false,
    .row_parts = true,
    .sibling_levels = false,
    .signature_words = &.{},
    .skip_words = &.{},
    .slice_colons = true,
    .sole_hugs = true,
    .sole_joins = false,
    .source_gaps = false,
    .source_values = &.{},
    .source_words = &.{"|"},
    .spaced_words = &.{},
    .span_levels = true,
    .spread_blanks = false,
    .spread_owns = false,
    .spread_values = false,
    .tight_from_source = &.{ "!", "?" },
    .spec_depths = false,
    .special_macros = &.{},
    .string_quotes = false,
    .template_spans = false,
    .template_units = false,
    .ternary_colon = false,
    .ternary_levels = false,
    .ternary_parts = false,
    .test_joins = false,
    .tight_words = &.{},
    .type_leads = &.{},
    .type_words = &.{},
    .unary_tight = false,
    .unary_words = &.{ "!", "&", "*", "**", "-", "-%", "-|", "?", "~" },
    .union_parts = false,
    .value_cap = 0,
    .value_columns = false,
    .value_words = &.{},
    .variant_width = 0,
    .verbatim_words = &.{},
    .units = false,
    .width_lists = false,
    .wrap_words = &.{},
};

fn list_of(
    input: *const Input,
    start: u32,
    end: u32,
    braced: bool,
    proto: bool,
) ?struct { u32, u32 } {
    assert(start <= end);
    assert(end <= input.tokens.len);

    const tokens = input.tokens;
    const code_last = code_before(tokens, end, start) orelse return null;

    if (braced) {
        if (tokens[code_last].kind != .block_end) return null;

        const at = opener(tokens, start, code_last) orelse return null;
        if (tokens[at].kind != .block_start) return null;
        return .{ at, code_last };
    }

    const open = list_open(input, start, end, code_last, proto) orelse return null;
    const at = closing(tokens, open, end) orelse return null;
    if (!tokens[at].is_punctuation(.paren_close)) return null;

    assert(open < at);

    return .{ open, at };
}

fn list_open(input: *const Input, start: u32, end: u32, code_last: u32, proto: bool) ?u32 {
    assert(start <= code_last);
    assert(code_last < end);

    const tokens = input.tokens;
    const tailed = tokens[code_last].is_punctuation(.paren_close) and !proto;

    if (tailed) {
        const at = opener(tokens, start, code_last) orelse return null;
        if (!tokens[at].is_punctuation(.paren_open)) return null;
        return at;
    }

    return paren_within(tokens, start, end);
}

fn opener(tokens: []const Token, floor: u32, close: u32) ?u32 {
    assert(floor <= close);
    assert(close < tokens.len);

    var depth: u32 = 0;
    var at = close;

    while (at > floor) {
        at -= 1;

        const kind = tokens[at].kind;

        if (closes(kind)) {
            depth += 1;
        } else if (opens(kind)) {
            if (depth == 0) return at;

            depth -= 1;
        } else {}
    }

    assert(at == floor);

    return null;
}

fn closing(tokens: []const Token, open: u32, end: u32) ?u32 {
    assert(open < tokens.len);
    assert(end <= tokens.len);

    var depth: u32 = 0;
    var at = open + 1;

    while (at < end) : (at += 1) {
        const kind = tokens[at].kind;

        if (opens(kind)) {
            depth += 1;
        } else if (closes(kind)) {
            if (depth == 0) {
                assert(at <= tokens.len);

                return at;
            }

            depth -= 1;
        } else {}
    }

    return null;
}

fn declares(input: *const Input, at: u32, close: u32) bool {
    assert(at < close);
    assert(close < input.tokens.len);

    const held = code_within(input.tokens, at + 1, close);
    const blocked = if (held) |found| input.tokens[found].kind == .block_start else false;

    return switch (input.raw[at]) {
        .fn_keyword,
        .const_keyword,
        .var_keyword,
        .pub_keyword,
        .test_keyword,
        .export_keyword,
        .extern_keyword,
        .inline_keyword,
        .noinline_keyword,
        .threadlocal_keyword,
        => true,
        .comptime_keyword => blocked,
        else => false,
    };
}

fn listing(input: *const Input, open: u32, close: u32) Listing {
    assert(open < close);
    assert(close < input.tokens.len);

    var held: Listing = .{};
    var depth: u32 = 0;
    var pending = false;
    var member = true;
    var code_first: ?u32 = null;
    var code_last = open;

    for (open + 1..close) |index| {
        const at: u32 = @intCast(index);
        const token = input.tokens[at];

        if (token.kind == .comment) {
            listing_comment(&held, token.text(input.source), depth);

            continue;
        }

        const declared = depth == 0 and member and declares(input, at, close);

        held.stringed = held.stringed or input.raw[at] == .text_line;
        held.declared = held.declared or declared;
        member = member and depth > 0;
        code_first = code_first orelse at;
        code_last = at;

        const bracket = opens(token.kind) or closes(token.kind);

        if (bracket) {
            depth = if (opens(token.kind)) depth + 1 else depth -| 1;
            pending = true;
            member = depth == 0 and token.kind == .block_end;

            continue;
        }

        if (depth > 0) continue;

        if (token.is_punctuation(.comma)) {
            held.items += @intFromBool(pending);
            pending = false;
            member = true;
        } else if (token.is_punctuation(.semicolon)) {
            held.declared = true;
            member = true;
        } else {
            pending = true;
        }
    }

    held.items += @intFromBool(pending);
    held.trailing = input.tokens[code_last].is_punctuation(.comma);

    const plain_head = if (code_first) |at| input.raw[at] != .text_line else false;

    held.sole = held.items == 1 and plain_head and !held.trailing and close == code_last + 1;

    assert(code_last < close);
    assert(held.items <= close - open);

    return held;
}

fn listing_comment(held: *Listing, text: []const u8, depth: u32) void {
    assert(text.len <= std.math.maxInt(u32));

    const doc = std.mem.startsWith(u8, text, "///") or std.mem.startsWith(u8, text, "//!");

    held.plain = held.plain or !doc;
    held.plain_top = held.plain_top or (!doc and depth == 0);
    held.documented = held.documented or doc;
    held.documented_top = held.documented_top or (doc and depth == 0);

    assert(held.plain or held.documented);
    if (depth == 0) assert(held.plain_top or held.documented_top);
}

fn commas_of(input: *const Input, kind: Kind, layout: u8, open: u32, close: u32) u8 {
    assert(open < close);
    assert(layout <= brace.item_edges);
    assert(kind.is_node());

    const code_last = code_before(input.tokens, close, open + 1);
    const strung = if (code_last) |at| input.raw[at] == .text_line else false;

    const owed = switch (kind) {
        .array_init, .array_init_dot => layout == brace.item_edges and !strung,
        .container_decl, .tagged_union => owed: {
            if (layout != brace.item_lines) break :owed false;

            break :owed !listing(input, open, close).declared;
        },
        .error_set_decl,
        .fn_proto,
        .struct_init,
        .struct_init_dot,
        => layout == brace.item_lines and !strung,
        else => false,
    };

    if (owed) return brace.item_commas;
    return 0;
}

fn initializes(kind: Kind) bool {
    assert(kind.is_node());

    return switch (kind) {
        .array_init, .array_init_dot, .struct_init, .struct_init_dot => true,
        else => false,
    };
}

fn layout_of(input: *const Input, kind: Kind, open: u32, close: u32) u8 {
    assert(open < close);
    assert(close < input.tokens.len);
    assert(kind.is_node());

    const held = listing(input, open, close);
    if (held.items == 0) return 0;

    const lines = switch (kind) {
        .builtin_call, .call => called: {
            const commented = !held.trailing and held.plain_top;
            if (commented) return 0;

            break :called held.trailing;
        },
        .fn_proto => held.trailing or held.plain or held.documented_top,
        .error_set_decl => held.trailing or held.plain or held.documented,
        .struct_init, .struct_init_dot => held.trailing or held.plain,
        .array_init, .array_init_dot => {
            const loose = held.trailing or held.plain or held.stringed;

            if (held.sole) return brace.item_inline;
            if (!loose) return brace.item_inline;
            return brace.item_edges;
        },
        else => held.trailing or
            held.plain or
            held.documented or
            held.stringed or
            held.declared,
    };

    if (lines) return brace.item_lines;
    return brace.item_inline;
}

fn code_after(tokens: []const Token, at: u32, close: u32) u32 {
    assert(at <= close);
    assert(at < tokens.len);

    const stop = @min(close + 1, tokens.len);

    for (at + 1..stop) |index| {
        if (tokens[index].kind != .comment) {
            assert(index <= tokens.len);

            return @intCast(index);
        }
    }

    return close;
}

fn code_before(tokens: []const Token, at: u32, floor: u32) ?u32 {
    assert(at <= tokens.len);
    assert(tokens.len <= std.math.maxInt(u32));
    assert(floor < std.math.maxInt(u32));

    var held = at;

    while (held > floor) {
        held -= 1;

        if (tokens[held].kind != .comment) return held;
    }

    return null;
}

fn code_within(tokens: []const Token, from: u32, to: u32) ?u32 {
    assert(to <= tokens.len);
    assert(tokens.len <= std.math.maxInt(u32));
    assert(from < std.math.maxInt(u32));

    var held = from;

    while (held < to) : (held += 1) {
        if (tokens[held].kind != .comment) return held;
    }

    return null;
}

fn paren_within(tokens: []const Token, from: u32, to: u32) ?u32 {
    assert(from <= to);
    assert(to <= tokens.len);

    for (from..to) |index| {
        if (tokens[index].is_punctuation(.paren_open)) {
            assert(index < to);

            return @intCast(index);
        }
    }

    return null;
}

fn bar_within(input: *const Input, from: u32, to: u32) ?u32 {
    assert(to <= input.tokens.len);
    assert(input.tokens.len <= std.math.maxInt(u32));
    assert(from < std.math.maxInt(u32));

    var held = from;

    while (held < to) : (held += 1) {
        if (walk.text_is(input.tokens[held].text(input.source), "|")) return held;
    }

    return null;
}

fn bar_before(input: *const Input, at: u32) ?u32 {
    assert(at < input.tokens.len);
    assert(input.tokens.len <= std.math.maxInt(u32));

    var held = at;

    while (held > 0) {
        held -= 1;

        if (walk.text_is(input.tokens[held].text(input.source), "|")) return held;
    }

    return null;
}

fn comma_at(tokens: []const Token, at: ?u32) bool {
    if (at) |held| assert(held < tokens.len);

    const held = at orelse return false;

    assert(held < tokens.len);
    assert(tokens[held].kind != .comment);

    return tokens[held].is_punctuation(.comma);
}

fn strung_within(input: *const Input, from: u32, to: u32) bool {
    assert(from <= to);
    assert(to <= input.raw.len);

    for (input.raw[from..to]) |kind| {
        if (kind == .text_line) return true;
    }

    return false;
}

fn same_line(input: *const Input, from: u32, to: u32) bool {
    assert(from < input.tokens.len);
    assert(to < input.tokens.len);

    const start = input.tokens[from].offset;
    const end = input.tokens[to].offset;

    return std.mem.findScalar(u8, input.source[start..end], '\n') == null;
}

fn trailed(input: *const Input, at: u32, close: u32) bool {
    assert(at < close);
    assert(close < input.tokens.len);

    const from = input.tokens[at].end();
    const to = input.tokens[code_after(input.tokens, at, close)].offset;
    const gap = input.source[from..to];
    const found = std.mem.findAny(u8, gap, "\n/") orelse return false;

    return gap[found] == '/';
}

fn opens(kind: Token.Kind) bool {
    if (kind == .comment) return false;

    const result = switch (kind) {
        .block_start => true,
        .punctuation => |punctuation| punctuation == .bracket_open or punctuation == .paren_open,
        else => false,
    };

    if (result) assert(kind != .block_end);
    if (result) assert(kind != .comment);

    return result;
}

fn closes(kind: Token.Kind) bool {
    if (kind == .comment) return false;

    const result = switch (kind) {
        .block_end => true,
        .punctuation => |punctuation| punctuation == .bracket_close or punctuation == .paren_close,
        else => false,
    };

    if (result) assert(kind != .block_start);
    if (result) assert(kind != .comment);

    return result;
}

fn width_of(text: []const u8) ?u32 {
    assert(text.len <= std.math.maxInt(u32));

    for (text) |byte| {
        if (byte < 0x20) return null;
        if (byte >= 0x7f) return null;
    }

    const width: u32 = @intCast(text.len);

    assert(width == text.len);

    return width;
}

fn pragma(text: []const u8) []const u8 {
    assert(text.len <= std.math.maxInt(u32));

    const body = if (std.mem.startsWith(u8, text, "//")) text[2..] else text;
    const result = std.mem.trim(u8, body, " \t\n\r\x0c");

    assert(result.len <= body.len);

    return result;
}

fn fixed(out: *Buffer, text: []const u8) error{Overflow}!void {
    assert(text.len <= std.math.maxInt(u32));

    const held = out.count();
    var start: usize = 0;

    for (text, 0..) |byte, at| {
        const stray = byte == '\t' or byte == '\r';
        if (!stray) continue;

        try out.push(text[start..at]);

        if (byte == '\t') try out.push(tab_spaces);

        start = at + 1;
    }

    try out.push(text[start..]);

    assert(out.count() - held <= text.len * tab_spaces.len);
}

fn line_past(source: []const u8, comment: Token) u32 {
    assert(comment.offset <= source.len);

    const end = @min(comment.end(), @as(u32, @intCast(source.len)));
    const at = std.mem.findScalarPos(u8, source, end, '\n') orelse {
        assert(source.len <= std.math.maxInt(u32));

        return @intCast(source.len);
    };

    assert(at + 1 <= source.len);

    return @intCast(at + 1);
}

fn broken(input: *const Input) bool {
    assert(input.tokens.len == input.raw.len);
    assert(input.source.len <= std.math.maxInt(u32));

    if (input.outcome != .complete) return true;
    if (input.tree.diagnostic_slice().len > 0) return true;

    for (input.raw) |kind| {
        if (kind == .error_token) return true;
    }

    for (input.tree.slice()) |node| {
        if (node.kind == .error_node) return true;
    }

    if (!brace.closed(input.source, input.tokens, false, false)) return true;
    return !brace.balanced(input.source, input.tokens);
}

fn word_in(words: []const []const u8, text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));
    assert(words.len <= std.math.maxInt(u32));

    for (words) |word| {
        assert(word.len > 0);

        if (std.mem.eql(u8, word, text)) return true;
    }

    return false;
}

fn binding(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));
    assert(policy.binding_words.len > 0);

    for (policy.binding_words) |tier| {
        if (word_in(tier, text)) return true;
    }

    return false;
}

fn asm_operands_of(tree: *const Tree, template: u32) Operands {
    assert(template < tree.count());

    var operands: Operands = .{ .clobbers = null, .inputs = null, .outputs = null };
    var held = template;

    for (0..tree.count()) |_| {
        held = tree.sibling_next_of(held) orelse break;

        switch (tree.at(held).kind) {
            .asm_input => operands.inputs = held,
            .asm_output => operands.outputs = held,
            else => operands.clobbers = held,
        }
    }

    return operands;
}

fn asm_clobbers_colon(input: *const Input, operands: Operands) ?u32 {
    if (operands.clobbers == null) return null;

    const clobbers = operands.clobbers.?;
    const first = input.tree.at(clobbers).token_start;
    const colon = code_before(input.tokens, first, 0) orelse return null;

    assert(input.tokens[colon].is_punctuation(.colon));

    return colon;
}

fn asm_colons_joined(lists: []u8, tokens: []const Token, template_last: u32, colon: u32) void {
    assert(template_last < colon);
    assert(tokens[colon].is_punctuation(.colon));
    assert(lists.len <= std.math.maxInt(u32));

    var at = template_last;

    for (0..asm_colon_count) |_| {
        joined(lists, at);
        at = code_after(tokens, at, colon);
    }

    assert(at == colon);

    joined(lists, colon);
}

fn severed(lists: []u8, at: u32) void {
    assert(at < lists.len);
    assert(lists[at] & item_codes == 0);

    lists[at] |= brace.item_break;
}

fn joined(lists: []u8, at: u32) void {
    assert(at < lists.len);
    assert(lists[at] & item_codes == 0);

    lists[at] |= brace.item_join;
}

fn branches_ended(input: *const Input, index: u32, operand_ends: []u32) void {
    assert(index < input.tree.count());
    assert(operand_ends.len == input.tokens.len);

    const node = input.tree.at(index);
    var then_indented = false;
    var child = input.tree.child_first_of(index);

    for (0..branch_child_max) |_| {
        const held = child orelse break;

        child = input.tree.sibling_next_of(held);

        const branch = input.tree.at(held);
        const start = branch.token_start;
        const prior = code_before(input.tokens, start, node.token_start) orelse continue;
        const head = branch_head(input, prior, node.token_start) orelse continue;
        const last = code_before(input.tokens, branch.token_end, start) orelse continue;
        const blocked = branch.kind == .block;
        const stringed = input.raw[branch.token_start] == .text_line;
        const lined = branch_lined(input, prior, branch.token_start);
        const elsed = walk.text_is(input.tokens[head].text(input.source), "else");

        assert(head < branch.token_start);
        assert(last >= branch.token_start);

        const nested = branch_headed(branch.kind) or branch.kind == .@"switch";

        const indented = if (elsed)
            else_indented(then_indented, blocked, nested, stringed)
        else
            then_indented_of(blocked, lined, stringed);

        if (!elsed) then_indented = indented;
        if (indented) operand_ends[last] = @min(operand_ends[last], head);
    }
}

fn else_indented(then_indented: bool, blocked: bool, nested: bool, stringed: bool) bool {
    if (stringed) return true;
    if (!then_indented) return false;
    if (blocked) return false;
    return !nested;
}

fn then_indented_of(blocked: bool, lined: bool, stringed: bool) bool {
    if (blocked) return false;
    if (lined) return true;
    return stringed;
}

fn branch_head(input: *const Input, prior: u32, floor: u32) ?u32 {
    assert(prior < input.tokens.len);
    assert(floor <= prior);

    const text = input.tokens[prior].text(input.source);
    if (walk.text_is(text, "else")) return prior;
    if (walk.text_is(text, ")")) return prior;
    if (!walk.text_is(text, "|")) return null;

    var scan = prior;

    for (0..payload_token_max) |_| {
        scan = code_before(input.tokens, scan, floor) orelse return null;

        if (!walk.text_is(input.tokens[scan].text(input.source), "|")) continue;

        const before = code_before(input.tokens, scan, floor) orelse return null;
        const word = input.tokens[before].text(input.source);
        if (walk.text_is(word, "else")) return before;
        if (walk.text_is(word, ")")) return prior;
        return null;
    }

    return null;
}

fn branch_lined(input: *const Input, prior: u32, start: u32) bool {
    assert(prior < start);
    assert(start < input.tokens.len);

    const gap = input.source[input.tokens[prior].end()..input.tokens[start].offset];
    return std.mem.findScalar(u8, gap, '\n') != null;
}

fn equals_held(input: *const Input, index: u32) bool {
    assert(index < input.tree.count());
    assert(infixed(input.tree.kind_at(index)));

    var top = index;

    for (0..ancestor_walk_max) |_| {
        const parent = input.tree.parent_of(top) orelse return false;
        const kind = input.tree.kind_at(parent);
        const wrapped = kind == .@"comptime" or kind == .@"nosuspend";
        const first = input.tree.child_first_of(parent) == top;
        const leftmost = infixed(kind) and first;
        const conditioned = branch_headed(kind) and first;
        const chained = branch_headed(kind) and else_chained(input, top);
        const passed = wrapped or leftmost or conditioned or chained;

        if (passed) {
            top = parent;

            continue;
        }

        const declared = kind == .var_decl or kind.category() == .assignment;
        if (!declared) return false;

        break;
    } else return false;

    const start = input.tree.at(top).token_start;
    const equals = code_before(input.tokens, start, 0) orelse return false;
    const text = input.tokens[equals].text(input.source);
    if (!assigning(text)) return false;

    const gap = input.source[input.tokens[equals].end()..input.tokens[start].offset];
    return std.mem.findScalar(u8, gap, '\n') != null;
}

fn branch_headed(kind: Kind) bool {
    assert(kind.is_node());

    return kind == .@"if" or kind == .@"while" or kind == .@"for";
}

fn else_chained(input: *const Input, index: u32) bool {
    assert(index < input.tree.count());

    const kind = input.tree.kind_at(index);
    const branching = branch_headed(kind) or kind == .@"switch";
    if (!branching) return false;

    const start = input.tree.at(index).token_start;
    var before = code_before(input.tokens, start, 0) orelse return false;

    if (walk.text_is(input.tokens[before].text(input.source), "|")) {
        const name = code_before(input.tokens, before, 0) orelse return false;
        const bar = code_before(input.tokens, name, 0) orelse return false;

        before = code_before(input.tokens, bar, 0) orelse return false;
    }

    return walk.text_is(input.tokens[before].text(input.source), "else");
}

fn assigning(text: []const u8) bool {
    assert(text.len > 0);

    if (text[text.len - 1] != '=') return false;

    for (compared_texts) |compared| {
        if (std.mem.eql(u8, text, compared)) return false;
    }

    return true;
}

fn infixed(kind: Kind) bool {
    assert(kind.is_node());

    return switch (kind) {
        .add,
        .add_sat,
        .add_wrap,
        .array_cat,
        .array_mult,
        .bang_equal_node,
        .bit_and,
        .bit_or,
        .bit_xor,
        .bool_and,
        .bool_or,
        .@"catch",
        .div,
        .equal_equal_node,
        .greater_or_equal,
        .greater_than,
        .less_or_equal,
        .less_than,
        .merge_error_sets,
        .mod,
        .mul,
        .mul_sat,
        .mul_wrap,
        .@"orelse",
        .shl,
        .shl_sat,
        .shr,
        .sub,
        .sub_sat,
        .sub_wrap,
        => true,
        else => false,
    };
}

fn arrayed(input: *const Input) bool {
    assert(input.tokens.len == input.raw.len);
    assert(input.source.len <= std.math.maxInt(u32));

    for (input.tree.slice()) |node| {
        if (node.kind == .array_init) return true;
        if (node.kind == .array_init_dot) return true;
    }

    return false;
}

fn silenced(input: *const Input) bool {
    assert(input.tokens.len == input.raw.len);
    assert(input.source.len <= std.math.maxInt(u32));

    for (input.tokens) |token| {
        if (token.kind != .comment) continue;
        if (std.mem.eql(u8, pragma(token.text(input.source)), format_off)) return true;
    }

    return false;
}

fn comment_within(tokens: []const Token, from: u32) ?u32 {
    assert(from <= tokens.len);
    assert(tokens.len <= std.math.maxInt(u32));

    for (from..tokens.len) |index| {
        if (tokens[index].kind == .comment) {
            assert(index < tokens.len);

            return @intCast(index);
        }
    }

    return null;
}

fn patch_before(context: void, left: Patch, right: Patch) bool {
    _ = context;

    assert(left.from <= left.to);
    assert(right.from <= right.to);

    return left.from < right.from;
}

fn mapping_agrees(text: []const u8, held: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));
    assert(held.len <= std.math.maxInt(u32));

    if (std.mem.eql(u8, text, held)) return true;
    return word_in(policy.order_words, text) and word_in(policy.order_words, held);
}

fn spaces_operated(input: *const Input, at: u32, before: u32) bool {
    assert(before < at);
    assert(at < input.tokens.len);

    const prior = input.tokens[before].text(input.source);
    if (!walk.text_is(prior, ".*")) return false;

    const text = input.tokens[at].text(input.source);

    if (input.tokens[at].is_punctuation(.assign)) return true;
    if (walk.text_is(text, "=")) return true;
    return binding(text);
}

fn spaces_typed(input: *const Input, at: u32, before: u32) bool {
    assert(before < at);
    assert(at < input.tokens.len);

    const text = input.tokens[at].text(input.source);
    const prior = input.tokens[before].text(input.source);
    const marker = walk.text_is(text, "?") or walk.text_is(text, "!");

    const separated = walk.text_is(prior, ":") or
        walk.text_is(prior, ",") or
        walk.text_is(prior, "=");

    if (!marker) return false;
    if (separated) return true;
    if (!walk.text_is(prior, ")")) return false;
    if (walk.text_is(text, "?")) return true;
    return spaces_returned(input, before);
}

fn spaces_returned(input: *const Input, before: u32) bool {
    assert(before < input.tokens.len);
    assert(input.raw.len == input.tokens.len);

    const tokens = input.tokens;
    const open = opener(tokens, 0, before) orelse return false;
    const name = code_before(tokens, open, 0) orelse return false;
    if (input.raw[name] == .fn_keyword) return true;

    const held = code_before(tokens, name, 0) orelse return false;
    return input.raw[held] == .fn_keyword;
}

fn glued_fallback(input: *const Input, open: u32, before: ?u32) bool {
    assert(open < input.tokens.len);
    assert(input.raw.len == input.tokens.len);
    if (before) |held| assert(held < std.math.maxInt(u32));

    const tokens = input.tokens;
    const at = before orelse return false;
    var operator = at;

    assert(at < open);

    if (input.raw[at] == .pipe) {
        const pipe = bar_before(input, at) orelse return false;

        operator = code_before(tokens, pipe, 0) orelse return false;
    }

    const raw = input.raw[operator];
    const falls_back = raw == .orelse_keyword or raw == .catch_keyword;
    if (!falls_back) return false;

    const between = input.source[tokens[at].end()..tokens[open].offset];
    return std.mem.findScalar(u8, between, '\n') != null;
}

fn glued_headed(input: *const Input, open: u32, before: ?u32) bool {
    assert(open < input.tokens.len);
    if (before) |at| assert(at < open);

    const tokens = input.tokens;

    if (open == 0) return false;
    if (tokens[open - 1].kind == .comment) return false;

    const at = before orelse return false;
    const token = tokens[at];

    const kinded = switch (token.kind) {
        .identifier, .string, .keyword => true,
        .punctuation => |punctuation| punctuation == .paren_close,
        else => false,
    };

    if (kinded) return true;

    const text = token.text(input.source);

    return walk.text_is(text, "|") or
        walk.text_is(text, "=>") or
        walk.text_is(text, ":");
}

fn glued_paren(input: *const Input, preceding: u32) ?u32 {
    assert(preceding < input.tokens.len);
    assert(input.raw.len == input.tokens.len);

    const tokens = input.tokens;
    const text = tokens[preceding].text(input.source);
    if (walk.text_is(text, ")")) return opener(tokens, 0, preceding);
    if (!walk.text_is(text, "|")) return null;

    const pipe = bar_before(input, preceding) orelse return null;
    const shut = code_before(tokens, pipe, 0) orelse return null;
    if (!walk.text_is(tokens[shut].text(input.source), ")")) return null;
    return opener(tokens, 0, shut);
}

fn glued_spanned(input: *const Input, paren: ?u32, open: u32, preceding: u32) bool {
    assert(open < input.tokens.len);
    assert(preceding <= open);
    if (paren) |held| assert(held < std.math.maxInt(u32));

    const at = paren orelse return false;
    const source = input.source;
    const tokens = input.tokens;
    const opened = source[tokens[at].offset..tokens[open].offset];
    if (std.mem.findScalar(u8, opened, '\n') == null) return false;

    const headed = source[tokens[at].offset..tokens[preceding].offset];
    return std.mem.findScalar(u8, headed, '\n') != null;
}

fn cased_arrow(input: *const Input, start: u32, end: u32) ?u32 {
    assert(start <= end);
    assert(end <= input.tokens.len);

    var depth: u32 = 0;

    for (start..end) |index| {
        const token = input.tokens[index];

        if (opens(token.kind)) {
            depth += 1;
        } else if (closes(token.kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (walk.text_is(token.text(input.source), "=>")) {
                assert(index < end);

                return @intCast(index);
            }
        } else {}
    }

    return null;
}

fn cased_commented(input: *const Input, start: u32, arrow: u32) bool {
    assert(start <= arrow);
    assert(arrow < input.tokens.len);

    for (input.tokens[start..arrow]) |token| {
        if (token.kind != .comment) continue;
        if (!std.mem.startsWith(u8, token.text(input.source), "///")) return true;
    }

    return false;
}
