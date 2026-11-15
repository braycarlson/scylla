const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Buffer = @import("../stdx/bounded/buffer.zig");
const Cells = @import("go/cells.zig").Cells;
const FormatterError = @import("formatters.zig").FormatterError;
pub const Kind = @import("../syntax/go/kind.zig").Kind;
const Options = @import("print.zig").Options;
const Span = @import("../stdx/bounded/span.zig");
const Structure = @import("../syntax/tree.zig").Structure;
const Token = @import("../syntax/token.zig");
const Tabwriter = @import("go/tabwriter.zig").Tabwriter;
const Tree = @import("../syntax/tree.zig").TreeType(Kind);
const brace = @import("brace.zig");
const comments = @import("go/comments.zig");
const specs = @import("go/specs.zig");
const walk = @import("walk.zig");

pub const Formatter = struct {
    cells: Cells,
    depths: ArrayType(u32),
    held: ArrayType(Token),
    inner: brace.Formatter,
    marked: ArrayType(u8),
    marks: ArrayType(u8),
    nodes: ArrayType(u32),
    order: ArrayType(u32),
    placed: ArrayType(u16),
    positions: ArrayType(u8),
    roles: ArrayType(u16),
    scratch: Buffer,
    staged: Buffer,
    stream: Buffer,
    tabwriter: Tabwriter,

    pub fn init(
        gpa: std.mem.Allocator,
        element_count_max: u32,
        scratch_bytes_max: u32,
    ) std.mem.Allocator.Error!Formatter {
        assert(element_count_max > 0);
        assert(scratch_bytes_max > 0);

        var formatter: Formatter = undefined;

        try formatter.init_tables(gpa, element_count_max);
        errdefer formatter.deinit_tables(gpa);

        try formatter.init_engines(gpa, element_count_max, scratch_bytes_max);

        assert(formatter.roles.capacity() == element_count_max);
        assert(formatter.stream.capacity() == scratch_bytes_max);

        return formatter;
    }

    fn init_tables(
        formatter: *Formatter,
        gpa: std.mem.Allocator,
        element_count_max: u32,
    ) std.mem.Allocator.Error!void {
        assert(element_count_max > 0);

        formatter.depths = try .init(gpa, element_count_max);
        errdefer formatter.depths.deinit(gpa);

        formatter.held = try .init(gpa, element_count_max);
        errdefer formatter.held.deinit(gpa);

        formatter.marked = try .init(gpa, element_count_max);
        errdefer formatter.marked.deinit(gpa);

        formatter.marks = try .init(gpa, element_count_max);
        errdefer formatter.marks.deinit(gpa);

        formatter.nodes = try .init(gpa, element_count_max);
        errdefer formatter.nodes.deinit(gpa);

        formatter.order = try .init(gpa, element_count_max);
        errdefer formatter.order.deinit(gpa);

        formatter.placed = try .init(gpa, element_count_max);
        errdefer formatter.placed.deinit(gpa);

        formatter.positions = try .init(gpa, element_count_max);
        errdefer formatter.positions.deinit(gpa);

        formatter.roles = try .init(gpa, element_count_max);

        assert(formatter.depths.capacity() == element_count_max);
        assert(formatter.roles.empty());
    }

    fn init_engines(
        formatter: *Formatter,
        gpa: std.mem.Allocator,
        element_count_max: u32,
        scratch_bytes_max: u32,
    ) std.mem.Allocator.Error!void {
        assert(element_count_max > 0);
        assert(scratch_bytes_max > 0);

        formatter.cells = try .init(gpa, element_count_max);
        errdefer formatter.cells.deinit(gpa);

        formatter.inner = try .init(gpa, element_count_max, scratch_bytes_max);
        errdefer formatter.inner.deinit(gpa);

        formatter.scratch = try .init(gpa, scratch_bytes_max);
        errdefer formatter.scratch.deinit(gpa);

        formatter.staged = try .init(gpa, scratch_bytes_max);
        errdefer formatter.staged.deinit(gpa);

        formatter.stream = try .init(gpa, scratch_bytes_max);
        errdefer formatter.stream.deinit(gpa);

        formatter.tabwriter = try .init(gpa, element_count_max *| 4, scratch_bytes_max);

        assert(formatter.scratch.empty());
        assert(formatter.staged.capacity() == scratch_bytes_max);
    }

    pub fn deinit(formatter: *Formatter, gpa: std.mem.Allocator) void {
        assert(formatter.roles.capacity() == formatter.positions.capacity());
        assert(formatter.scratch.capacity() == formatter.staged.capacity());

        formatter.deinit_engines(gpa);
        formatter.deinit_tables(gpa);
        formatter.* = undefined;
    }

    fn deinit_tables(formatter: *Formatter, gpa: std.mem.Allocator) void {
        assert(formatter.depths.capacity() == formatter.roles.capacity());
        assert(formatter.held.capacity() == formatter.order.capacity());

        formatter.roles.deinit(gpa);
        formatter.positions.deinit(gpa);
        formatter.placed.deinit(gpa);
        formatter.order.deinit(gpa);
        formatter.nodes.deinit(gpa);
        formatter.marks.deinit(gpa);
        formatter.marked.deinit(gpa);
        formatter.held.deinit(gpa);
        formatter.depths.deinit(gpa);
    }

    fn deinit_engines(formatter: *Formatter, gpa: std.mem.Allocator) void {
        assert(formatter.scratch.capacity() == formatter.stream.capacity());
        assert(formatter.staged.capacity() == formatter.stream.capacity());

        formatter.tabwriter.deinit(gpa);
        formatter.stream.deinit(gpa);
        formatter.staged.deinit(gpa);
        formatter.scratch.deinit(gpa);
        formatter.inner.deinit(gpa);
        formatter.cells.deinit(gpa);
    }

    pub fn format(formatter: *Formatter, input: *const Input, out: *Buffer) FormatterError!void {
        assert(input.tokens.len == input.raw.len);
        assert(input.source.len <= std.math.maxInt(u32));

        try formatter.unaligned(input);

        formatter.cells.written(formatter.scratch.const_slice(), &formatter.staged) catch {
            return error.OutputExhausted;
        };

        out.clear();

        formatter.tabwriter.write(formatter.staged.const_slice(), out) catch {
            out.clear();

            return error.OutputExhausted;
        };

        assert(out.count() <= out.capacity());
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

    fn unaligned(formatter: *Formatter, input: *const Input) FormatterError!void {
        assert(input.tokens.len == input.raw.len);
        assert(input.source.len <= std.math.maxInt(u32));

        if (broken(input)) return error.SourceInvalid;

        formatter.unaligned_passes(input) catch return error.OutputExhausted;
    }

    fn unaligned_passes(formatter: *Formatter, input: *const Input) error{Overflow}!void {
        assert(input.tokens.len == input.raw.len);
        assert(input.tree.count() > 0);

        try brace.marked(Kind, input.tree, input.tokens, &formatter.roles);
        formatter.generics(input);
        formatter.parted(input);
        formatter.tightened(input);
        try formatter.stepped(input);
        packed_marks(input.tree, input.raw, formatter.marks.slice());

        const rebuilt = try formatter.hoisted(input);

        leveled(input.tree, input.raw, formatter.positions.const_slice(), formatter.marks.slice());

        if (rebuilt) try formatter.remarked();

        const brace_input = if (rebuilt) braced(
            input,
            formatter.stream.const_slice(),
            formatter.held.const_slice(),
            formatter.placed.const_slice(),
            formatter.marked.const_slice(),
        ) else braced(
            input,
            input.source,
            input.tokens,
            formatter.roles.const_slice(),
            formatter.marks.const_slice(),
        );

        try formatter.inner.format(&brace_input, &formatter.scratch);
        try formatter.unaligned_text(input);
    }

    fn unaligned_text(formatter: *Formatter, input: *const Input) error{Overflow}!void {
        assert(input.source.len <= std.math.maxInt(u32));
        assert(formatter.scratch.capacity() == formatter.staged.capacity());

        try specs.sorted_imports(formatter.scratch.const_slice(), &formatter.staged);

        if (policy.document_blocks) {
            try comments.documented(formatter.staged.const_slice(), &formatter.scratch);
            std.mem.swap(Buffer, &formatter.scratch, &formatter.staged);
        }

        if (policy.build_blocks) {
            try comments.built(formatter.staged.const_slice(), &formatter.scratch);
            std.mem.swap(Buffer, &formatter.scratch, &formatter.staged);
        }

        try comments.relined(input.source, formatter.staged.const_slice(), &formatter.scratch);
    }

    fn remarked(formatter: *Formatter) error{Overflow}!void {
        const marks = formatter.marks.const_slice();

        assert(formatter.order.count() <= marks.len);
        assert(formatter.marked.capacity() >= formatter.marks.capacity());

        formatter.marked.clear();

        for (formatter.order.const_slice()) |at| {
            if (formatter.marked.full()) return error.Overflow;

            formatter.marked.push(marks[at]);
        }

        assert(formatter.marked.count() == formatter.order.count());
    }

    fn hoisted(formatter: *Formatter, input: *const Input) error{Overflow}!bool {
        assert(input.tokens.len == input.raw.len);
        assert(formatter.roles.count() == input.tokens.len);

        formatter.positions.clear();

        for (input.tokens) |_| {
            if (formatter.positions.full()) return error.Overflow;

            formatter.positions.push(0);
        }

        const positions = formatter.positions.slice();

        unpositioned(input.tree, input.raw, positions);
        dropped(input.tree, input.source, input.tokens, input.raw, positions);
        broken_braces(input.tree, input.source, input.tokens, input.raw, positions);

        try semicolons(
            input.tree,
            input.source,
            input.tokens,
            input.raw,
            &formatter.nodes,
            positions,
        );

        try ordered(input.source, input.tokens, input.raw, positions, &formatter.order);

        if (!restream_needed(positions, formatter.order.const_slice())) return false;

        const stream: Stream = .{
            .order = formatter.order.const_slice(),
            .positions = positions,
            .roles = formatter.roles.const_slice(),
            .source = input.source,
            .tokens = input.tokens,
        };

        try restreamed(&stream, &formatter.stream, &formatter.held, &formatter.placed);

        assert(formatter.held.count() == formatter.order.count());

        return true;
    }

    fn parted(formatter: *Formatter, input: *const Input) void {
        const tree = input.tree;
        const roles = formatter.roles.slice();

        assert(roles.len == input.tokens.len);
        assert(input.raw.len == input.tokens.len);

        for (0..tree.count()) |index| {
            const node: u32 = @intCast(index);
            const at = tree.at(node);
            if (at.kind != .block_stmt) continue;

            const parent = tree.parent_of(node) orelse continue;
            const parent_kind = tree.kind_at(parent);

            switch (parent_kind) {
                .func_decl, .func_lit => continue,
                else => {},
            }

            if (parent_kind == .select_stmt) {
                if (tree.child_first_of(node) == null) continue;
            }

            role_at(roles, at.token_start, brace.role_part);
        }

        for (0..tree.count()) |index| {
            const at = tree.at(@intCast(index));

            switch (at.kind) {
                .case_clause, .comm_clause, .labeled_stmt => {},
                else => continue,
            }

            const colon = depthless(input.raw, at.token_start, at.token_end, .colon) orelse {
                continue;
            };

            role_at(roles, colon, brace.role_part);
        }
    }

    fn stepped(formatter: *Formatter, input: *const Input) error{Overflow}!void {
        assert(input.tokens.len == input.raw.len);
        assert(input.source.len <= std.math.maxInt(u32));

        formatter.depths.clear();
        formatter.nodes.clear();
        formatter.marks.clear();

        try stepped_depths(input.raw, &formatter.depths);

        const layout: Layout = .{
            .depths = formatter.depths.const_slice(),
            .raw = input.raw,
            .source = input.source,
            .tokens = input.tokens,
            .tree = input.tree,
        };

        var fresh = true;
        var cursor: u32 = 0;

        for (input.tokens, 0..) |token, index| {
            const at: u32 = @intCast(index);
            const kind = input.raw[at];

            try enclosing_advance(input.tree, &formatter.nodes, at, &cursor);

            if (at > 0) {
                const end = input.tokens[at - 1].end();

                if (newline_in(input.source, end, token.offset)) fresh = true;
            }

            const leading = fresh and !is_filler(kind);
            const step = if (leading) stepped_step(&layout, formatter.nodes.const_slice()) else 0;

            if (formatter.marks.full()) return error.Overflow;

            formatter.marks.push((std.math.cast(u8, step) orelse 0) & brace.mark_steps);

            fresh = switch (kind) {
                .newline => true,
                .comment => fresh,
                else => false,
            };
        }

        assert(formatter.marks.count() == input.tokens.len);
    }

    fn tightened(formatter: *Formatter, input: *const Input) void {
        assert(formatter.roles.count() == input.tokens.len);
        assert(input.tree.count() > 0);

        var tightening: Tightening = .{
            .roles = formatter.roles.slice(),
            .source = input.source,
            .tokens = input.tokens,
            .tree = input.tree,
        };

        tightening.expression(0, 1, depth_max);
    }

    fn generics(formatter: *Formatter, input: *const Input) void {
        const tree = input.tree;
        const roles = formatter.roles.slice();
        const tokens = input.tokens;

        assert(roles.len == tokens.len);
        assert(input.raw.len == tokens.len);

        for (0..tree.count()) |index| {
            const at = tree.at(@intCast(index));
            const start = at.token_start;

            if (at.kind != .field_list) continue;
            if (start >= tokens.len) continue;

            const close: Token.Punctuation = if (tokens[start].is_punctuation(.bracket_open))
                .bracket_close
            else if (tokens[start].is_punctuation(.paren_open))
                .paren_close
            else
                continue;

            const end = at.token_end;
            if (end == 0) continue;
            if (end - 1 >= tokens.len) continue;
            if (!tokens[end - 1].is_punctuation(close)) continue;

            if (start < roles.len) roles[start] &= ~brace.role_start;
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

const Layout = struct {
    depths: []const u32,
    raw: []const Kind,
    source: []const u8,
    tokens: []const Token,
    tree: *const Tree,

    fn after(layout: *const Layout, node: u32, operator: u32) ?u32 {
        assert(node < layout.tree.count());
        assert(operator < layout.tokens.len);

        var child = layout.tree.child_first_of(node);

        for (0..step_list_max) |_| {
            const held = child orelse return null;
            if (layout.tree.at(held).token_start > operator) return held;

            child = layout.tree.sibling_next_of(held);
        }

        return null;
    }

    fn assigned(layout: *const Layout, node: u32, to: u32) ?u32 {
        assert(node < std.math.maxInt(u32));

        const start = layout.tree.at(node).token_start;
        const base = layout.depths[start];

        assert(layout.depths.len == layout.raw.len);
        assert(to <= layout.raw.len);

        var at = start;

        while (at < to) : (at += 1) {
            if (layout.depths[at] != base) continue;
            if (is_assignment(layout.raw[at])) return at;
        }

        return null;
    }

    fn broken_gap(layout: *const Layout, from: u32, to: u32) bool {
        assert(from < layout.tokens.len);
        assert(to < layout.tokens.len);

        return newline_in(layout.source, layout.tokens[from].end(), layout.tokens[to].offset);
    }

    fn counted(layout: *const Layout, parent: u32, node: u32) u32 {
        assert(parent < node);

        const held = layout.tree.at(parent);
        const start = layout.tree.at(node).token_start;

        assert(start >= held.token_start);

        const applies = switch (held.kind) {
            .assign_stmt => layout.counted_assign(parent, node, start),
            .binary_expr => layout.counted_binary(parent, node, start),
            .case_clause => layout.counted_case(parent, node, start),
            .return_stmt => layout.indent_listed(parent),
            .value_spec => layout.counted_spec(parent, node, start),
            else => false,
        };

        return @intFromBool(applies);
    }

    fn counted_assign(layout: *const Layout, parent: u32, node: u32, start: u32) bool {
        assert(parent < node);
        assert(start < layout.tokens.len);

        if (layout.assigned(parent, start)) |operator| {
            return layout.listed(layout.after(parent, operator), operator, node);
        }

        return layout.listed(layout.tree.child_first_of(parent), null, node);
    }

    fn counted_binary(layout: *const Layout, parent: u32, node: u32, start: u32) bool {
        assert(parent < node);
        assert(start < layout.tokens.len);

        const operands = operands_of(layout.tree, parent);
        const right = operands.right orelse return false;
        if (right != node) return false;

        const left = operands.left orelse return false;
        return layout.broken_gap(layout.tail(left), start);
    }

    fn counted_case(layout: *const Layout, parent: u32, node: u32, start: u32) bool {
        assert(parent < node);

        const held = layout.tree.at(parent);

        assert(start >= held.token_start);

        const colon = depthless(layout.raw, held.token_start, held.token_end, .colon) orelse {
            return false;
        };

        if (start >= colon) return false;
        return layout.listed(layout.tree.child_first_of(parent), held.token_start, node);
    }

    fn counted_spec(layout: *const Layout, parent: u32, node: u32, start: u32) bool {
        assert(parent < node);
        assert(start < layout.tokens.len);

        const operator = layout.assigned(parent, start) orelse return false;
        return layout.listed(layout.after(parent, operator), null, node);
    }

    fn indent_listed(layout: *const Layout, node: u32) bool {
        assert(node < layout.tree.count());
        assert(layout.tokens.len == layout.raw.len);

        var child = layout.tree.child_first_of(node);
        var before: ?u32 = null;
        var spanning: u32 = 0;

        for (0..step_list_max) |_| {
            const held = child orelse break;
            const start = layout.tree.at(held).token_start;
            const end = layout.tail(held);

            if (before) |gap| {
                if (layout.broken_gap(gap, start)) return true;
            }

            if (layout.spans(start, end)) spanning += 1;

            before = end;
            child = layout.tree.sibling_next_of(held);
        }

        return spanning > 1;
    }

    fn tail(layout: *const Layout, node: u32) u32 {
        assert(node < layout.tree.count());
        assert(layout.raw.len == layout.tokens.len);

        return tail_of(layout.tree, layout.raw, node);
    }

    fn listed(layout: *const Layout, head: ?u32, prior: ?u32, node: u32) bool {
        assert(node < layout.tree.count());
        if (prior) |held| assert(held < layout.tokens.len);
        if (head) |held| assert(held < std.math.maxInt(u32));

        var child = head;
        var before = prior;

        for (0..step_list_max) |_| {
            const held = child orelse return false;
            const start = layout.tree.at(held).token_start;

            if (before) |gap| {
                if (layout.broken_gap(gap, start)) return true;
            }

            if (held == node) return false;

            before = layout.tail(held);
            child = layout.tree.sibling_next_of(held);
        }

        return false;
    }

    fn opened(layout: *const Layout, parent: u32, node: u32) bool {
        assert(parent < node);
        assert(layout.depths.len == layout.raw.len);

        const inside = layout.depths[layout.tree.at(node).token_start];
        const outside = layout.depths[layout.tree.at(parent).token_start];

        return inside > outside;
    }

    fn spans(layout: *const Layout, from: u32, to: u32) bool {
        assert(from < layout.tokens.len);
        assert(to < layout.tokens.len);

        return newline_in(layout.source, layout.tokens[from].offset, layout.tokens[to].end());
    }

    fn steps(layout: *const Layout, node: u32) u32 {
        assert(node < layout.tree.count());
        assert(layout.depths.len == layout.raw.len);

        var breaks: u32 = 0;
        var extra: u32 = 0;
        var held = node;

        for (0..step_depth_max) |_| {
            const parent = layout.tree.parent_of(held) orelse break;

            breaks += layout.counted(parent, held);

            if (layout.opened(parent, held)) {
                extra += breaks -| 1;
                breaks = 0;
            }

            held = parent;
        }

        const result = @min(extra + (breaks -| 1), step_max);

        assert(result <= step_max);

        return result;
    }
};

const Tightening = struct {
    roles: []u16,
    source: []const u8,
    tokens: []const Token,
    tree: *const Tree,

    const Frame = struct {
        budget: u32,
        child: ?u32,
        depth_head: u32,
        depth_tail: u32,
        entered: u32,
        limit: u32,
    };

    fn expression(tightening: *Tightening, root: u32, depth: u32, budget: u32) void {
        assert(budget <= depth_max);
        assert(tightening.roles.len == tightening.tokens.len);
        assert(root < std.math.maxInt(u32));
        assert(depth <= depth_max);

        var frames: [depth_max]Frame = undefined;
        var frame_count: u32 = 0;
        const step_count_max = 2 * @as(usize, tightening.tree.count()) + 2;

        frames[0] = tightening.entered(root, depth, budget) orelse return;
        frame_count = 1;

        for (0..step_count_max) |_| {
            if (frame_count == 0) break;

            const top = &frames[frame_count - 1];

            const child = top.child orelse {
                frame_count -= 1;

                continue;
            };

            if (top.entered == top.limit) {
                frame_count -= 1;

                continue;
            }

            const child_depth = if (top.entered == 0) top.depth_head else top.depth_tail;

            top.entered += 1;
            top.child = tightening.tree.sibling_next_of(child);

            const frame = tightening.entered(child, child_depth, top.budget - 1) orelse continue;

            assert(frame_count < depth_max);

            frames[frame_count] = frame;
            frame_count += 1;
        }

        assert(frame_count == 0);
    }

    fn entered(tightening: *Tightening, node: u32, depth: u32, budget: u32) ?Frame {
        assert(node < tightening.tree.count());
        assert(budget <= depth_max);

        if (budget == 0) return null;
        assert(depth <= depth_max);

        const tree = tightening.tree;
        const child = tree.child_first_of(node);

        switch (tree.kind_at(node)) {
            .binary_expr => return tightening.binary(node, depth, budget),
            .paren_expr => return frame_all(child, budget, paren_depth_of(tree, node, depth)),
            .selector_expr, .unary_expr => return frame_all(child, budget, depth),
            .star_expr => return frame_all(child, budget, 1),
            .call_expr => {
                const spread = arguments(tree, node) > 1;
                return frame_all(child, budget, if (spread) depth + 1 else depth);
            },
            .index_expr, .index_list_expr => return frame_indexed(child, budget, depth),
            .slice_expr => {
                if (depth == 1) tightening.sliced(node);

                return frame_indexed(child, budget, depth);
            },
            .assign_stmt => {
                const spread = values(tree, tightening.tokens, tightening.source, node) > 1;
                return frame_all(child, budget, 1 + @as(u32, @intFromBool(spread)));
            },
            .value_spec => {
                const spread = !policy.spec_depths and
                    values(tree, tightening.tokens, tightening.source, node) > 1;

                return frame_all(child, budget, 1 + @as(u32, @intFromBool(spread)));
            },
            else => return frame_all(child, budget, 1),
        }
    }

    fn binary(tightening: *Tightening, node: u32, depth: u32, budget: u32) Frame {
        assert(depth <= depth_max);

        const tree = tightening.tree;

        assert(tree.kind_at(node) == .binary_expr);
        assert(budget > 0);

        const cutoff = cutoff_of(tree, tightening.tokens, tightening.source, node, depth);
        const precedence = precedence_at(tree, tightening.tokens, tightening.source, node);

        if (precedence >= cutoff) tightening.binary_tight(node);

        const left = tree.at(node).child_first;

        assert(left < tree.count());

        const same = precedence_at(tree, tightening.tokens, tightening.source, left) != precedence;

        return .{
            .budget = budget,
            .child = tree.child_first_of(node),
            .depth_head = depth + @intFromBool(same),
            .depth_tail = depth + 1,
            .entered = 0,
            .limit = 2,
        };
    }

    fn binary_tight(tightening: *Tightening, node: u32) void {
        assert(node < tightening.tree.count());
        assert(tightening.roles.len == tightening.tokens.len);

        const operator = operator_of(
            tightening.tree,
            tightening.tokens,
            tightening.source,
            node,
        ) orelse {
            return;
        };

        if (combines(tightening.tokens, tightening.source, operator)) return;

        role_at(tightening.roles, operator, brace.role_tight);
    }

    fn sliced(tightening: *Tightening, node: u32) void {
        assert(node < std.math.maxInt(u32));

        const tree = tightening.tree;
        const held = tree.at(node);

        assert(held.kind == .slice_expr);
        assert(tightening.roles.len == tightening.tokens.len);

        var child = tree.sibling_next_of(held.child_first);
        var binaries = false;
        var indices: u32 = 0;

        for (0..depth_max + 1) |_| {
            const current = child orelse break;

            binaries = binaries or tree.kind_at(current) == .binary_expr;
            indices += 1;
            child = tree.sibling_next_of(current);
        }

        if (indices < 2) return;
        if (!binaries) return;

        var bracket_depth: i32 = 0;
        var position = held.token_start;

        while (position < held.token_end) : (position += 1) {
            const token = tightening.tokens[position];

            if (token.is_punctuation(.bracket_open)) bracket_depth += 1;
            if (token.is_punctuation(.bracket_close)) bracket_depth -= 1;
            if (bracket_depth != 1) continue;
            if (!token.is_punctuation(.colon)) continue;

            role_at(tightening.roles, position, brace.role_spaced);
        }
    }
};

const Stream = struct {
    order: []const u32,
    positions: []const u8,
    roles: []const u16,
    source: []const u8,
    tokens: []const Token,
};

const Levels = struct {
    five: bool,
    four: bool,
    problem: u32,

    fn merged(levels: Levels, other: Levels) Levels {
        assert(levels.problem <= 5);
        assert(other.problem <= 5);

        return .{
            .five = levels.five or other.five,
            .four = levels.four or other.four,
            .problem = @max(levels.problem, other.problem),
        };
    }
};

const BinaryStep = struct {
    left: ?u32,
    levels: Levels,
    right: ?u32,
};

const Operands = struct {
    left: ?u32,
    right: ?u32,
};

const Opening = struct {
    blank: bool,
    open: u32,
};

const Precedence = struct {
    level: u32,
    text: []const u8,
};

pub const policy: brace.Policy = .{
    .align_colons = false,
    .angle_calls = false,
    .angle_spreads = false,
    .angle_objects = false,
    .angle_types = false,
    .arm_bars = false,
    .arm_empties = false,
    .arm_flattens = false,
    .arm_guards = false,
    .arrow_after = &.{},
    .arrow_bodies = false,
    .arrow_commas = false,
    .arrow_parens = false,
    .asm_operands = false,
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
    .bar_levels = false,
    .binary_lines = false,
    .binary_parts = false,
    .binding_bases = &.{},
    .binding_codes = false,
    .binding_leads = false,
    .binder_words = &.{},
    .binding_words = &.{},
    .blank_edges = false,
    .blank_max = 1,
    .block_chains = false,
    .block_joins = false,
    .block_leads = &.{},
    .block_words = &.{},
    .body_owns = false,
    .body_settles = false,
    .body_parts = false,
    .body_words = &.{},
    .brace_bodies = false,
    .brace_comments = false,
    .brace_continues = true,
    .brace_counts = false,
    .brace_dedents = false,
    .brace_hugs = true,
    .brace_leads = false,
    .brace_levels = true,
    .brace_pairs = false,
    .brace_parts = false,
    .brace_spaces = false,
    .brace_spans = true,
    .brace_words = &.{ "interface", "struct" },
    .branch_joins = false,
    .branch_width = 0,
    .branch_words = &.{},
    .bracket_types = true,
    .build_blocks = true,
    .carriage_breaks = false,
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
    .close_hugs = true,
    .colon_continues = false,
    .comma_continues = true,
    .comma_adds = false,
    .comma_drops = false,
    .comma_joins = false,
    .comma_parts = false,
    .comment_carries = true,
    .comment_dedents = false,
    .comment_gaps = true,
    .comment_leads = true,
    .comment_levels = false,
    .comment_opens = false,
    .comment_spaces = false,
    .comment_suffix = false,
    .comment_tails = false,
    .compose_parts = false,
    .construct_words = &.{},
    .continue_words = &.{},
    .convention_strings = false,
    .dangling_blanks = false,
    .define_joins = false,
    .define_widths = false,
    .define_words = &.{},
    .declare_lines = false,
    .declaration_words = &.{},
    .declare_words = &.{ "const", "func", "import", "type", "var" },
    .decorators = false,
    .dedent_words = &.{ "case", "default" },
    .document_blocks = true,
    .edge_blanks = false,
    .else_width = 0,
    .empty_follows = &.{},
    .empty_joins = false,
    .empty_semis = false,
    .empty_words = &.{},
    .end_words = &.{ "break", "continue", "else", "fallthrough", "return" },
    .field_width = 30,
    .fill_reserve = 1,
    .follow_heads = &.{},
    .follow_words = &.{},
    .gap_words = &.{},
    .generic_levels = false,
    .generic_nests = false,
    .generic_parts = false,
    .group_words = &.{},
    .head_blanks = false,
    .head_blocks = false,
    .head_stops = &.{},
    .header_braces = false,
    .header_extends = false,
    .header_joins = false,
    .header_levels = false,
    .header_lines = false,
    .header_parens = false,
    .header_widths = false,
    .header_words = &.{},
    .heritage_parts = false,
    .hole_spaces = false,
    .hug_braces = true,
    .hug_lambdas = false,
    .hug_lasts = false,
    .hug_soles = false,
    .hug_words = &.{ "chan", "func", "interface", "map", "struct" },
    .index_continues = false,
    .inline_comments = false,
    .inline_layout = false,
    .item_words = &.{},
    .key_numbers = false,
    .key_quotes = false,
    .key_words = &.{},
    .keyword_gaps = true,
    .label_lines = true,
    .label_words = &.{},
    .lambda_flattens = false,
    .lead_words = &.{"/*"},
    .level_words = &.{},
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
    .operand_words = &.{ "assert", "require" },
    .operator_words = &.{},
    .order_words = &.{},
    .parameter_words = &.{},
    .pattern_frames = false,
    .pattern_words = &.{},
    .postfix_words = &.{ "++", "--" },
    .prefix_words = &.{},
    .printed_gaps = false,
    .raise_hugged = false,
    .regex_flags = false,
    .sentinel_colons = false,
    .sequence_lines = false,
    .sequence_stops = &.{},
    .return_parens = false,
    .rest_binds = false,
    .root_joins = false,
    .row_parts = false,
    .sibling_levels = true,
    .signature_words = &.{"func"},
    .skip_words = &.{},
    .slice_colons = true,
    .sole_hugs = false,
    .sole_joins = false,
    .source_gaps = false,
    .source_values = &.{},
    .source_words = &.{},
    .spaced_words = &.{},
    .span_levels = false,
    .spread_blanks = false,
    .spread_owns = false,
    .spread_values = false,
    .tight_from_source = &.{},
    .spec_depths = true,
    .special_macros = &.{},
    .string_quotes = false,
    .template_spans = false,
    .template_units = false,
    .ternary_colon = false,
    .ternary_levels = false,
    .ternary_parts = false,
    .test_joins = false,
    .tight_words = &.{},
    .value_cap = 0,
    .value_columns = true,
    .value_words = &.{},
    .variant_width = 0,
    .verbatim_words = &.{},
    .type_leads = &.{},
    .type_words = &.{},
    .unary_tight = true,
    .unary_words = &.{
        "!",
        "&",
        "&^",
        "*",
        "+",
        "-",
        "...",
        "<-",
        "^",
        "~",
    },
    .union_parts = false,
    .units = false,
    .width_lists = false,
    .wrap_words = &.{},
};

const depth_max: u32 = 64;
const position_blank: u8 = 8;
const position_break: u8 = 4;
const position_drop: u8 = 2;
const position_free: u8 = 1;
const position_join: u8 = 32;
const position_number: u8 = 16;
const position_restreamed: u8 = position_blank | position_break | position_join | position_number;
const body_width_max: u32 = 100;
const body_statements_max: u32 = 5;
const queue_max: u32 = 8;
const paren_depth_max: u32 = 64;
const binary_pending_max: u32 = 16;
const step_depth_max: u32 = 4096;
const step_list_max: u32 = 1024;
const step_max: u32 = 8;
const unary_signs = [_][]const u8{ "&", "*", "+", "-" };

const precedences = [_]Precedence{
    .{ .level = 1, .text = "||" },
    .{ .level = 2, .text = "&&" },
    .{ .level = 3, .text = "==" },
    .{ .level = 3, .text = "!=" },
    .{ .level = 3, .text = "<" },
    .{ .level = 3, .text = "<=" },
    .{ .level = 3, .text = ">" },
    .{ .level = 3, .text = ">=" },
    .{ .level = 4, .text = "+" },
    .{ .level = 4, .text = "-" },
    .{ .level = 4, .text = "|" },
    .{ .level = 4, .text = "^" },
    .{ .level = 5, .text = "*" },
    .{ .level = 5, .text = "/" },
    .{ .level = 5, .text = "%" },
    .{ .level = 5, .text = "<<" },
    .{ .level = 5, .text = ">>" },
    .{ .level = 5, .text = "&" },
    .{ .level = 5, .text = "&^" },
};

comptime {
    assert(position_restreamed & position_drop == 0);
    assert(position_restreamed & position_free == 0);
    assert(step_max <= brace.mark_steps);
    assert(binary_pending_max <= paren_depth_max);
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

    if (!brace.closed(input.source, input.tokens, false, true)) return true;
    return !brace.balanced(input.source, input.tokens);
}

fn braced(
    input: *const Input,
    source: []const u8,
    tokens: []const Token,
    roles: []const u16,
    marks: []const u8,
) brace.Input {
    assert(roles.len == tokens.len);
    assert(marks.len == tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    return .{
        .added = &.{},
        .gives = &.{},
        .lists = &.{},
        .macros = &.{},
        .marks = marks,
        .nests = &.{},
        .opaques = &.{},
        .operand_ends = &.{},
        .operands = &.{},
        .options = input.options,
        .origin = &.{},
        .origins = &.{},
        .policy = policy,
        .roles = roles,
        .source = source,
        .tokens = tokens,
    };
}

fn unpositioned(tree: *const Tree, raw: []const Kind, held: []u8) void {
    assert(held.len == raw.len);
    assert(raw.len <= std.math.maxInt(u32));

    for (0..tree.count()) |index| {
        const node: u32 = @intCast(index);
        const at = tree.at(node);

        const found = switch (at.kind) {
            .selector_expr, .type_assert_expr => unpositioned_dot(tree, raw, node),
            .type_spec, .value_spec => depthless(raw, at.token_start, at.token_end, .equal),
            .array_type => closes(raw, at.token_start),
            .map_type => unpositioned_map(tree, raw, node, held),
            else => continue,
        };

        if (found) |marked| mark_at(held, marked, position_free);
    }
}

fn unpositioned_dot(tree: *const Tree, raw: []const Kind, node: u32) ?u32 {
    assert(node < std.math.maxInt(u32));

    const at = tree.at(node);

    assert(at.kind == .selector_expr or at.kind == .type_assert_expr);
    assert(at.token_end <= raw.len);

    const child = tree.child_first_of(node) orelse return null;
    const found = meaningful(raw, tree.at(child).token_end, at.token_end) orelse return null;
    if (raw[found] != .dot) return null;
    return found;
}

fn unpositioned_map(tree: *const Tree, raw: []const Kind, node: u32, held: []u8) ?u32 {
    assert(node < std.math.maxInt(u32));

    const at = tree.at(node);

    assert(at.kind == .map_type);
    assert(held.len == raw.len);

    const open = meaningful(raw, at.token_start + 1, at.token_end) orelse return null;
    if (raw[open] != .bracket_open) return null;

    mark_at(held, open, position_free);

    return closes(raw, open);
}

fn dropped(
    tree: *const Tree,
    source: []const u8,
    tokens: []const Token,
    raw: []const Kind,
    held: []u8,
) void {
    assert(tokens.len == raw.len);
    assert(held.len == raw.len);
    assert(source.len <= std.math.maxInt(u32));

    for (0..tree.count()) |index| {
        const node: u32 = @intCast(index);

        switch (tree.kind_at(node)) {
            .paren_expr => dropped_paren(tree, raw, node, held),
            .field_list => dropped_fields(tree, raw, node, held),
            .func_type => drop_result(tree, raw, node, held),
            .select_stmt => join_select(tree, source, tokens, raw, node, held),
            .for_stmt, .if_stmt, .range_stmt, .switch_stmt => dropped_clause(tree, raw, node, held),
            else => {},
        }
    }

    drop_commas(tree, source, tokens, raw, held);

    for (raw, 0..) |kind, index| {
        if (kind != .number) continue;
        if (!number_changes(tokens[index].text(source))) continue;

        mark_at(held, @intCast(index), position_number);
    }
}

fn dropped_paren(tree: *const Tree, raw: []const Kind, node: u32, held: []u8) void {
    assert(tree.kind_at(node) == .paren_expr);
    assert(held.len == raw.len);

    const inner = tree.child_first_of(node) orelse return;
    if (tree.kind_at(inner) != .paren_expr) return;

    drop_parens(tree, raw, node, held);
}

fn dropped_fields(tree: *const Tree, raw: []const Kind, node: u32, held: []u8) void {
    assert(tree.kind_at(node) == .field_list);
    assert(held.len == raw.len);

    const parent = tree.parent_of(node) orelse return;

    switch (tree.kind_at(parent)) {
        .func_type, .type_spec => {},
        else => return,
    }

    var field = tree.child_first_of(node);

    for (0..depth_max * depth_max) |_| {
        const current = field orelse break;

        strip_always(tree, raw, field_type(tree, current), held);

        field = tree.sibling_next_of(current);
    }
}

fn dropped_clause(tree: *const Tree, raw: []const Kind, node: u32, held: []u8) void {
    assert(node < std.math.maxInt(u32));

    const at = tree.at(node);

    assert(held.len == raw.len);
    assert(at.token_end <= raw.len);

    const from = if (at.kind == .range_stmt)
        depthless(raw, at.token_start, at.token_end, .range_keyword) orelse return
    else
        at.token_start;

    var child = tree.child_first_of(node);

    for (0..depth_max) |_| {
        const current = child orelse break;
        const inner = tree.at(current);

        if (inner.kind == .paren_expr) {
            if (inner.token_start > from) strip_clause(tree, raw, current, held);
        }

        child = tree.sibling_next_of(current);
    }
}

fn drop_commas(
    tree: *const Tree,
    source: []const u8,
    tokens: []const Token,
    raw: []const Kind,
    held: []u8,
) void {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len == raw.len);

    const raw_count: u32 = @intCast(raw.len);

    assert(held.len == raw.len);

    for (raw, 0..) |kind, index| {
        const at: u32 = @intCast(index);

        if (kind != .comma) continue;

        const closer = meaningful(raw, at + 1, raw_count) orelse continue;
        if (!is_closer(raw[closer])) continue;

        const start = tokens[at].end();
        const end = tokens[closer].offset;
        if (std.mem.findScalar(u8, source[start..end], '\n') != null) continue;
        if (comma_listed(tree, source, tokens, tokens[closer].offset)) continue;

        drop_at(held, at);
    }
}

fn comma_listed(tree: *const Tree, source: []const u8, tokens: []const Token, offset: u32) bool {
    assert(offset <= source.len);
    assert(tokens.len <= std.math.maxInt(u32));

    const list = tree.innermost_at(Token, tokens, offset) orelse return false;
    if (tree.kind_at(list) != .field_list) return false;
    return comma_kept(tree, source, tokens, list);
}

fn comma_kept(tree: *const Tree, source: []const u8, tokens: []const Token, list: u32) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(list < std.math.maxInt(u32));

    const held = tree.at(list);

    assert(held.kind == .field_list);
    assert(held.token_start < tokens.len);

    if (!tokens[held.token_start].is_punctuation(.bracket_open)) return false;
    if (field_count(tree, list) != 1) return false;

    const field = tree.child_first_of(list) orelse return false;
    var kind = field_type(tree, field);

    for (0..paren_depth_max) |_| {
        const current = kind orelse break;
        if (tree.kind_at(current) != .paren_expr) break;

        kind = tree.child_first_of(current);
    }

    return combines_with_name(tree, source, tokens, kind);
}

fn field_count(tree: *const Tree, list: u32) u32 {
    assert(list < tree.count());
    assert(tree.kind_at(list) == .field_list);

    var fields: u32 = 0;
    var field = tree.child_first_of(list);

    for (0..depth_max * depth_max) |_| {
        const current = field orelse break;

        fields += @max(field_names(tree, current), 1);
        field = tree.sibling_next_of(current);
    }

    return fields;
}

fn field_names(tree: *const Tree, field: u32) u32 {
    assert(field < tree.count());
    assert(tree.parent_of(field) != null);

    var names: u32 = 0;
    var child = tree.child_first_of(field);

    for (0..depth_max + 1) |_| {
        const current = child orelse break;
        const sibling = tree.sibling_next_of(current) orelse break;

        names += 1;
        child = sibling;
    }

    assert(names <= depth_max + 1);

    return names;
}

fn field_type(tree: *const Tree, field: u32) ?u32 {
    assert(field < tree.count());
    assert(tree.parent_of(field) != null);

    var child = tree.child_first_of(field);
    var tail: ?u32 = null;

    for (0..depth_max * depth_max) |_| {
        const current = child orelse break;

        tail = current;
        child = tree.sibling_next_of(current);
    }

    if (tail) |held| assert(held > field);

    return tail;
}

fn combines_with_name(
    tree: *const Tree,
    source: []const u8,
    tokens: []const Token,
    node: ?u32,
) bool {
    assert(tokens.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));
    if (node) |held| assert(held < tokens.len);

    var cursor = node;

    for (0..paren_depth_max) |_| {
        const at = cursor orelse return false;
        const operands = operands_of(tree, at);

        switch (tree.kind_at(at)) {
            .star_expr, .paren_expr => return !type_element(tree, source, tokens, operands.left),
            .binary_expr => {
                if (type_element(tree, source, tokens, operands.right)) return false;

                cursor = operands.left;
            },
            else => return false,
        }
    }

    return false;
}

fn type_element(tree: *const Tree, source: []const u8, tokens: []const Token, node: ?u32) bool {
    assert(tokens.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));
    if (node) |held| assert(held < tokens.len);

    var pending: [paren_depth_max]u32 = undefined;
    var pending_count: u32 = 0;

    pending[0] = node orelse return false;
    pending_count = 1;

    for (0..tree.count()) |_| {
        if (pending_count == 0) break;

        pending_count -= 1;

        const at = pending[pending_count];
        const held = tree.at(at);

        switch (held.kind) {
            .array_type,
            .chan_type,
            .func_type,
            .interface_type,
            .map_type,
            .struct_type,
            => return true,
            .unary_expr => {
                if (walk.text_is(tokens[held.token_start].text(source), "~")) return true;
            },
            .binary_expr, .paren_expr => {
                const operands = operands_of(tree, at);

                pending_count = type_element_pushed(&pending, pending_count, operands.left);
                pending_count = type_element_pushed(&pending, pending_count, operands.right);
            },
            else => {},
        }
    }

    assert(pending_count == 0);

    return false;
}

fn type_element_pushed(pending: *[paren_depth_max]u32, pending_count: u32, child: ?u32) u32 {
    assert(pending_count <= paren_depth_max);
    if (child) |held| assert(held < std.math.maxInt(u32));

    const held = child orelse return pending_count;

    if (pending_count >= paren_depth_max) return pending_count;

    if (pending_count > 0) assert(pending[pending_count - 1] != held);

    pending[pending_count] = held;

    assert(pending_count + 1 < std.math.maxInt(u32));

    return pending_count + 1;
}

fn parenthesized(tree: *const Tree, raw: []const Kind, node: ?u32) bool {
    assert(raw.len <= std.math.maxInt(u32));
    if (node) |held| assert(held < tree.count());

    const held = node orelse return false;
    const at = tree.at(held);
    if (at.kind != .field_list) return false;
    return raw[at.token_start] == .paren_open;
}

fn drop_result(tree: *const Tree, raw: []const Kind, signature: u32, held: []u8) void {
    assert(tree.kind_at(signature) == .func_type);
    assert(held.len == raw.len);

    var child = tree.child_first_of(signature);
    var before: ?u32 = null;

    for (0..depth_max * depth_max) |_| {
        const current = child orelse break;
        const sibling = tree.sibling_next_of(current) orelse break;

        before = current;
        child = sibling;
    }

    const result = child orelse return;
    if (!parenthesized(tree, raw, result)) return;
    if (!parenthesized(tree, raw, before)) return;

    const field = tree.child_first_of(result) orelse return;
    if (tree.sibling_next_of(field) != null) return;

    const kind = tree.child_first_of(field) orelse return;
    if (tree.sibling_next_of(kind) != null) return;

    drop_at(held, tree.at(result).token_start);
    drop_at(held, tail_of(tree, raw, result));
}

fn strip_always(tree: *const Tree, raw: []const Kind, node: ?u32, held: []u8) void {
    assert(held.len == raw.len);
    if (node) |at| assert(at < tree.count());

    var cursor = node;

    for (0..paren_depth_max) |_| {
        const at = cursor orelse return;
        if (tree.kind_at(at) != .paren_expr) return;

        drop_parens(tree, raw, at, held);

        cursor = tree.child_first_of(at);
    }
}

fn strip_clause(tree: *const Tree, raw: []const Kind, node: u32, held: []u8) void {
    assert(tree.kind_at(node) == .paren_expr);
    assert(held.len == raw.len);

    var cursor: ?u32 = node;

    for (0..paren_depth_max) |_| {
        const at = cursor orelse return;
        if (tree.kind_at(at) != .paren_expr) return;

        const inner = tree.child_first_of(at) orelse return;
        if (protects(tree, raw, inner)) return;

        drop_parens(tree, raw, at, held);

        cursor = inner;
    }
}

fn protects(tree: *const Tree, raw: []const Kind, node: u32) bool {
    assert(node < tree.count());

    const end = tree.at(node).token_end;

    assert(end <= raw.len);

    var skipped: u32 = 0;
    var at = node;

    while (at < tree.count()) : (at += 1) {
        const held = tree.at(at);

        if (at != node) {
            if (held.token_start >= end) break;
        }

        if (held.token_start < skipped) continue;

        switch (held.kind) {
            .paren_expr => skipped = held.token_end,
            .composite_lit => {
                const typed = raw[held.token_start] != .brace_open;
                const named = typed and type_named(tree, tree.child_first_of(at));
                if (named) return true;

                skipped = held.token_end;
            },
            else => {},
        }
    }

    return false;
}

fn type_named(tree: *const Tree, node: ?u32) bool {
    assert(tree.count() > 0);
    if (node) |held| assert(held < tree.count());

    var cursor = node;

    for (0..paren_depth_max) |_| {
        const at = cursor orelse return false;

        switch (tree.kind_at(at)) {
            .ident => return true,
            .selector_expr => cursor = tree.child_first_of(at),
            else => return false,
        }
    }

    return false;
}

fn drop_parens(tree: *const Tree, raw: []const Kind, node: u32, held: []u8) void {
    assert(tree.kind_at(node) == .paren_expr);
    assert(held.len == raw.len);

    drop_at(held, tree.at(node).token_start);
    drop_at(held, tail_of(tree, raw, node));
}

fn drop_at(held: []u8, at: u32) void {
    assert(held.len <= std.math.maxInt(u32));
    assert(at <= held.len);

    mark_at(held, at, position_drop);
}

fn join_select(
    tree: *const Tree,
    source: []const u8,
    tokens: []const Token,
    raw: []const Kind,
    node: u32,
    held: []u8,
) void {
    assert(tree.kind_at(node) == .select_stmt);
    assert(held.len == raw.len);
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    const body = block_child(tree, node) orelse return;
    if (tree.child_first_of(body) != null) return;

    const open = tree.at(body).token_start;
    const close = tail_of(tree, raw, body);

    if (raw[open] != .brace_open) return;
    if (raw[close] != .brace_close) return;
    if (commented(raw, open + 1, close)) return;
    if (!lined(source, tokens, open, close)) return;

    mark_at(held, close, position_join);
}

fn broken_braces(
    tree: *const Tree,
    source: []const u8,
    tokens: []const Token,
    raw: []const Kind,
    held: []u8,
) void {
    assert(tokens.len == raw.len);
    assert(held.len == raw.len);
    assert(source.len <= std.math.maxInt(u32));

    for (0..tree.count()) |index| {
        const node: u32 = @intCast(index);
        const opening = broken_braces_opening(tree, source, tokens, raw, node) orelse continue;
        const open = opening.open;
        const close = tail_of(tree, raw, node);
        if (close <= open) continue;
        if (!is_opener(raw[open])) continue;
        if (lined(source, tokens, open, close)) continue;

        if (open + 1 < close) mark_at(held, open + 1, position_break);

        mark_at(held, close, if (opening.blank) position_blank else position_break);
    }
}

fn broken_braces_opening(
    tree: *const Tree,
    source: []const u8,
    tokens: []const Token,
    raw: []const Kind,
    node: u32,
) ?Opening {
    assert(source.len <= std.math.maxInt(u32));
    assert(node < std.math.maxInt(u32));

    const at = tree.at(node);
    const parent_kind = parent_kind_of(tree, node);

    assert(tokens.len == raw.len);
    assert(at.token_end <= raw.len);

    switch (at.kind) {
        .block_stmt => {
            const kind = parent_kind orelse return null;

            switch (kind) {
                .func_decl, .func_lit => {},
                else => return null,
            }

            const fits = one_lined(tree, source, tokens, raw, node) orelse return null;
            if (fits) return null;
            return .{ .blank = false, .open = at.token_start };
        },
        .gen_decl => {
            const open = meaningful(raw, at.token_start + 1, at.token_end) orelse return null;
            if (raw[open] != .paren_open) return null;
            if (tree.child_first_of(node) == null) return null;
            return .{ .blank = false, .open = open };
        },
        .field_list => {
            const parent = tree.parent_of(node) orelse return null;

            switch (tree.kind_at(parent)) {
                .interface_type, .struct_type => {},
                else => return null,
            }

            const keyword = tree.at(parent).token_start;
            if (!commented(raw, keyword + 1, at.token_end)) return null;
            return .{ .blank = tree.child_first_of(node) == null, .open = at.token_start };
        },
        else => return null,
    }
}

fn semicolons(
    tree: *const Tree,
    source: []const u8,
    tokens: []const Token,
    raw: []const Kind,
    stack: *ArrayType(u32),
    held: []u8,
) error{Overflow}!void {
    assert(tokens.len == raw.len);
    assert(held.len == raw.len);
    assert(source.len <= std.math.maxInt(u32));

    var cursor: u32 = 0;

    stack.clear();

    for (raw, 0..) |kind, index| {
        const at: u32 = @intCast(index);

        try enclosing_advance(tree, stack, at, &cursor);

        if (kind != .semicolon) continue;
        if (stack.empty()) continue;

        const innermost = stack.get(stack.count() - 1);

        semicolon_marked(tree, source, tokens, raw, innermost, at, held);
    }
}

fn semicolon_marked(
    tree: *const Tree,
    source: []const u8,
    tokens: []const Token,
    raw: []const Kind,
    innermost: u32,
    at: u32,
    held: []u8,
) void {
    assert(raw[at] == .semicolon);
    assert(held.len == raw.len);
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));
    assert(innermost < std.math.maxInt(u32));

    const emptied = tree.kind_at(innermost) == .empty_stmt;
    const container = if (emptied) tree.parent_of(innermost) orelse innermost else innermost;

    if (emptied) {
        if (tree.kind_at(container) == .labeled_stmt) {
            semicolon_labeled(tree, source, tokens, container, at, held);

            return;
        }
    }

    const following = semicolon_following(raw, at);
    const closing = if (following) |found| is_closer(raw[found]) else false;
    if (semicolon_kept(tree, source, tokens, raw, container, at, closing)) return;

    mark_at(held, at, position_drop);

    const found = following orelse return;

    if (closing) return;
    if (raw[found] == .comment) return;
    if (lined(source, tokens, at, found)) return;

    mark_at(held, found, position_break);
}

fn semicolon_labeled(
    tree: *const Tree,
    source: []const u8,
    tokens: []const Token,
    container: u32,
    at: u32,
    held: []u8,
) void {
    assert(tree.kind_at(container) == .labeled_stmt);
    assert(at < held.len);
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    if (closes_block(tree, container)) {
        mark_at(held, at, position_drop);
    } else if (lined(source, tokens, tree.at(container).token_start, at)) {} else {
        mark_at(held, at, position_break);
    }
}

fn semicolon_following(raw: []const Kind, at: u32) ?u32 {
    assert(at < raw.len);
    assert(raw[at] == .semicolon);

    var scan = at + 1;

    while (scan < raw.len) : (scan += 1) {
        switch (raw[scan]) {
            .newline, .semicolon => {},
            else => {
                assert(scan < raw.len);

                return scan;
            },
        }
    }

    return null;
}

fn semicolon_kept(
    tree: *const Tree,
    source: []const u8,
    tokens: []const Token,
    raw: []const Kind,
    container: u32,
    at: u32,
    closing: bool,
) bool {
    assert(at < raw.len);
    assert(tokens.len == raw.len);
    assert(source.len <= std.math.maxInt(u32));
    assert(container < std.math.maxInt(u32));

    switch (tree.kind_at(container)) {
        .for_stmt, .if_stmt, .switch_stmt, .type_switch_stmt => {
            const block = block_child(tree, container) orelse return true;
            return at < tree.at(block).token_start;
        },
        .block_stmt => {
            const parent = tree.parent_of(container) orelse return false;

            switch (tree.kind_at(parent)) {
                .func_decl, .func_lit => {},
                else => return false,
            }

            const fits = one_lined(tree, source, tokens, raw, container) orelse return false;
            if (!fits) return false;
            return !closing;
        },
        .field_list => return semicolon_kept_fields(tree, source, tokens, raw, container),
        else => return false,
    }
}

fn semicolon_kept_fields(
    tree: *const Tree,
    source: []const u8,
    tokens: []const Token,
    raw: []const Kind,
    container: u32,
) bool {
    assert(raw.len <= std.math.maxInt(u32));
    assert(container < std.math.maxInt(u32));

    const holder = tree.at(container);
    const open = holder.token_start;
    const close = tail_of(tree, raw, container);
    const keyword = if (tree.parent_of(container)) |parent| tree.at(parent).token_start else open;

    assert(holder.kind == .field_list);
    assert(close >= open);

    if (raw[open] != .brace_open) return false;
    if (lined(source, tokens, open, close)) return false;
    return !commented(raw, keyword + 1, close);
}

fn closes_block(tree: *const Tree, node: u32) bool {
    assert(node < tree.count());
    assert(tree.kind_at(node) == .labeled_stmt);

    if (tree.sibling_next_of(node) != null) return false;

    const parent = tree.parent_of(node) orelse return false;
    const holder = tree.at(parent);

    return switch (holder.kind) {
        .block_stmt => true,
        .case_clause, .comm_clause => tree.sibling_next_of(parent) == null,
        else => false,
    };
}

fn block_child(tree: *const Tree, node: u32) ?u32 {
    assert(node < tree.count());
    assert(tree.count() > 0);

    var child = tree.child_first_of(node);

    for (0..tree.count()) |_| {
        const current = child orelse return null;
        if (tree.kind_at(current) == .block_stmt) return current;

        child = tree.sibling_next_of(current);
    }

    return null;
}

fn enclosing_advance(
    tree: *const Tree,
    stack: *ArrayType(u32),
    at: u32,
    cursor: *u32,
) error{Overflow}!void {
    assert(cursor.* <= tree.count());
    if (!stack.empty()) assert(stack.get(stack.count() - 1) < cursor.*);
    assert(at < std.math.maxInt(u32));

    const stacked = stack.count();

    for (0..stacked) |_| {
        const top = stack.get(stack.count() - 1);
        if (tree.at(top).token_end > at) break;

        _ = stack.pop();
    }

    while (cursor.* < tree.count()) : (cursor.* += 1) {
        const node = tree.at(cursor.*);
        if (node.token_start > at) break;
        if (node.token_end <= at) continue;
        if (stack.full()) return error.Overflow;

        stack.push(cursor.*);
    }
}

fn ordered(
    source: []const u8,
    tokens: []const Token,
    raw: []const Kind,
    positions: []const u8,
    order: *ArrayType(u32),
) error{Overflow}!void {
    assert(tokens.len == raw.len);
    assert(positions.len == raw.len);
    assert(source.len <= std.math.maxInt(u32));

    var queue: [queue_max]u32 = undefined;
    var queued: u32 = 0;
    var position: u32 = 0;

    order.clear();

    for (tokens, 0..) |token, index| {
        const at: u32 = @intCast(index);
        if (positions[at] & position_drop != 0) continue;

        const queueable = raw[at] == .comment and queued < queue_max;

        if (queueable) {
            if (queues(source, tokens, raw, at)) {
                queue[queued] = at;
                queued += 1;

                continue;
            }
        }

        const offset_next = if (positions[at] & position_free != 0) position else token.offset;
        const sent = try ordered_sent(tokens, queue[0..queued], offset_next, order);

        @memmove(queue[0 .. queued - sent], queue[sent..queued]);
        queued -= sent;

        if (order.full()) return error.Overflow;

        order.push(at);
        position = offset_next + token.length;
    }

    for (queue[0..queued]) |held| {
        if (order.full()) return error.Overflow;

        order.push(held);
    }
}

fn ordered_sent(
    tokens: []const Token,
    queue: []const u32,
    offset_next: u32,
    order: *ArrayType(u32),
) error{Overflow}!u32 {
    assert(queue.len <= queue_max);
    assert(order.count() <= tokens.len);

    var sent: u32 = 0;

    for (queue) |held| {
        if (tokens[held].offset >= offset_next) break;
        if (order.full()) return error.Overflow;

        order.push(held);
        sent += 1;
    }

    assert(sent <= queue.len);

    return sent;
}

fn queues(source: []const u8, tokens: []const Token, raw: []const Kind, at: u32) bool {
    assert(raw[at] == .comment);
    assert(tokens.len == raw.len);
    assert(source.len <= std.math.maxInt(u32));

    const text = tokens[at].text(source);
    if (!std.mem.startsWith(u8, text, "/*")) return false;
    if (std.mem.findScalar(u8, text, '\n') != null) return false;

    var scan = at;

    while (scan > 0) {
        scan -= 1;

        if (raw[scan] == .comment) continue;
        return raw[scan] != .newline;
    }

    return false;
}

fn restreamed(
    stream: *const Stream,
    out: *Buffer,
    held: *ArrayType(Token),
    placed: *ArrayType(u16),
) error{Overflow}!void {
    assert(stream.tokens.len == stream.positions.len);
    assert(stream.roles.len == stream.tokens.len);

    var end_max: u32 = 0;
    var prior: ?u32 = null;

    out.clear();
    held.clear();
    placed.clear();

    for (stream.order) |at| {
        const token = stream.tokens[at];

        try gapped(stream, prior, at, out);

        const offset = out.count();
        const text = token.text(stream.source);

        if (stream.positions[at] & position_number == 0) {
            try out.push(text);
        } else {
            try push_number(text, out);
        }

        if (held.full()) return error.Overflow;

        held.push(.{ .offset = offset, .length = out.count() - offset, .kind = token.kind });

        if (placed.full()) return error.Overflow;

        placed.push(stream.roles[at]);
        end_max = @max(end_max, token.end());
        prior = at;
    }

    try out.push(stream.source[end_max..]);
}

fn gapped(stream: *const Stream, prior: ?u32, at: u32, out: *Buffer) error{Overflow}!void {
    assert(at < stream.tokens.len);
    if (prior) |held| assert(held < stream.tokens.len);

    const start = out.count();
    const flags = stream.positions[at];
    var joined = false;

    if (prior) |held| {
        joined = try stitched(stream.source, stream.tokens, stream.positions, held, at, out);
    }

    try out.push(gap_of(stream, prior, at, joined or flags & position_join != 0));

    const breaks: u32 = @intFromBool(flags & position_break != 0);
    const wanted: u32 = if (flags & position_blank != 0) 2 else breaks;
    const written = std.mem.count(u8, out.const_slice()[start..], "\n");
    if (written >= wanted) return;

    out.truncate(start);

    for (0..wanted) |_| try out.push("\n");
}

fn gap_of(stream: *const Stream, prior: ?u32, at: u32, joined: bool) []const u8 {
    assert(at < stream.tokens.len);

    const token = stream.tokens[at];

    assert(token.end() <= stream.source.len);
    if (prior) |held| assert(held < stream.tokens.len);

    if (joined) return "";

    const held = prior orelse return stream.source[0..token.offset];
    if (at == held + 1) return stream.source[stream.tokens[held].end()..token.offset];
    if (token.kind == .comment) return " ";
    return "";
}

fn stitched(
    source: []const u8,
    tokens: []const Token,
    positions: []const u8,
    prior: u32,
    at: u32,
    out: *Buffer,
) error{Overflow}!bool {
    assert(prior < tokens.len);
    assert(at < tokens.len);

    if (at <= prior + 1) return false;
    assert(source.len <= std.math.maxInt(u32));
    assert(positions.len <= std.math.maxInt(u32));

    var held = prior + 1;

    while (held < at) : (held += 1) {
        if (positions[held] & position_drop == 0) return false;
    }

    var from = tokens[prior].end();

    held = prior + 1;

    while (held <= at) : (held += 1) {
        const token = tokens[held];

        try out.push(source[from..token.offset]);

        from = token.end();
    }

    return true;
}

fn push_number(text: []const u8, out: *Buffer) error{Overflow}!void {
    assert(text.len > 0);
    assert(out.capacity() > 0);

    if (text.len < 2) return out.push(text);

    const prefix = text[0..2];

    if (one_of(prefix, &.{ "0X", "0x" })) {
        try out.push("0x");

        return lowered_last(text[2..], 'P', out);
    }

    if (walk.text_is(prefix, "0O")) {
        try out.push("0o");

        return out.push(text[2..]);
    }

    if (walk.text_is(prefix, "0B")) {
        try out.push("0b");

        return out.push(text[2..]);
    }

    if (one_of(prefix, &.{ "0b", "0o" })) return out.push(text);
    if (std.mem.findScalar(u8, text, 'E') != null) return lowered_last(text, 'E', out);
    if (!std.mem.endsWith(u8, text, "i")) return out.push(text);
    if (std.mem.findAny(u8, text, ".e") != null) return out.push(text);

    const start = std.mem.findNone(u8, text, "0_") orelse text.len;
    const trimmed = text[start..];
    if (walk.text_is(trimmed, "i")) return out.push("0i");
    return out.push(trimmed);
}

fn lowered_last(digits: []const u8, mark: u8, out: *Buffer) error{Overflow}!void {
    assert(std.ascii.isUpper(mark));
    assert(out.capacity() > 0);
    assert(digits.len <= std.math.maxInt(u32));

    const at = std.mem.findScalarLast(u8, digits, mark) orelse return out.push(digits);

    try out.push(digits[0..at]);
    try out.push_byte(std.ascii.toLower(mark));
    try out.push(digits[at + 1 ..]);
}

fn number_changes(text: []const u8) bool {
    assert(text.len > 0);
    assert(text.len <= std.math.maxInt(u32));

    if (text.len < 2) return false;

    const prefix = text[0..2];
    if (one_of(prefix, &.{ "0B", "0O", "0X" })) return true;
    if (walk.text_is(prefix, "0x")) return std.mem.findScalar(u8, text, 'P') != null;
    if (one_of(prefix, &.{ "0b", "0o" })) return false;
    if (std.mem.findScalar(u8, text, 'E') != null) return true;

    const imaginary = std.mem.endsWith(u8, text, "i");
    const plain = std.mem.findAny(u8, text, ".e") == null;
    const zeroed = text[0] == '0' or text[0] == '_';

    return imaginary and plain and zeroed and !walk.text_is(text, "0i");
}

fn packed_marks(tree: *const Tree, raw: []const Kind, marks: []u8) void {
    assert(marks.len == raw.len);
    assert(raw.len <= std.math.maxInt(u32));

    for (0..tree.count()) |index| {
        const node: u32 = @intCast(index);
        const at = tree.at(node);

        const open: ?Kind = switch (at.kind) {
            .gen_decl => .paren_open,
            .interface_type, .struct_type => .brace_open,
            .call_expr, .composite_lit => null,
            else => continue,
        };

        const close = tail_of(tree, raw, node);

        switch (raw[close]) {
            .brace_close, .paren_close => {},
            else => continue,
        }

        const opened = packed_opened(raw, at.token_start, at.token_end, open);

        if (opened) |found| packed_head(raw, found, close, marks);
        if (packed_tail(raw, at.token_start, close, opened)) marks[close] |= brace.mark_packed;
    }
}

fn packed_opened(raw: []const Kind, start: u32, end: u32, open: ?Kind) ?u32 {
    assert(start <= end);
    assert(end <= raw.len);
    if (open) |held| assert(held.is_token());

    const found = meaningful(raw, start + 1, end) orelse return null;
    const kind = open orelse return null;
    if (raw[found] != kind) return null;
    assert(found < std.math.maxInt(u32));

    return found;
}

fn packed_head(raw: []const Kind, found: u32, close: u32, marks: []u8) void {
    assert(marks.len == raw.len);
    assert(found < raw.len);

    const after = found + 1;
    if (after >= raw.len) return;
    if (raw[after] == .comment) return;
    if (after >= close) return;

    marks[after] |= brace.mark_packed;
}

fn packed_tail(raw: []const Kind, start: u32, close: u32, opened: ?u32) bool {
    assert(close < raw.len);
    assert(start <= close);
    if (opened) |held| assert(held < std.math.maxInt(u32));

    var ended = close;

    while (ended > start) : (ended -= 1) {
        if (raw[ended - 1] != .newline) break;
    }

    if (ended == 0) return false;

    const before = ended - 1;
    if (before <= start) return false;
    if (raw[before] == .comment) return false;

    if (opened) |found| {
        if (found == before) return false;
    }

    return !is_opener(raw[before]);
}

fn leveled(tree: *const Tree, raw: []const Kind, positions: []const u8, marks: []u8) void {
    assert(positions.len == raw.len);
    assert(marks.len == raw.len);

    for (0..tree.count()) |index| {
        const at = tree.at(@intCast(index));
        if (at.kind != .value_spec) continue;

        const equal = depthless(raw, at.token_start, at.token_end, .equal) orelse continue;
        var held = equal + 1;

        while (held < at.token_end) : (held += 1) {
            if (is_filler(raw[held])) continue;
            if (positions[held] & position_drop != 0) continue;

            mark_at(marks, held, brace.mark_flush);

            break;
        }
    }
}

fn one_lined(
    tree: *const Tree,
    source: []const u8,
    tokens: []const Token,
    raw: []const Kind,
    block: u32,
) ?bool {
    assert(tokens.len == raw.len);
    assert(block < std.math.maxInt(u32));

    const held = tree.at(block);
    const open = held.token_start;
    const close = tail_of(tree, raw, block);

    assert(close >= open);

    const parent = tree.parent_of(block) orelse return null;

    if (lined(source, tokens, open, close)) return null;

    const header = tree.at(parent).token_start;

    if (open == 0) return false;

    const header_lined = lined(source, tokens, header, open);
    const declared: u32 = @intFromBool(tree.kind_at(parent) == .func_decl);
    var width: u32 = 0;

    if (!header_lined) width = width_of(tokens, raw, header, open - 1, false) + declared;

    var at = open + 1;

    while (at < close) : (at += 1) {
        if (raw[at] == .comment) width += tokens[at].length;
    }

    var child = tree.child_first_of(block);
    var statement_count: u32 = 0;

    for (0..body_statements_max + 1) |_| {
        const current = child orelse break;

        statement_count += 1;

        if (statement_count > body_statements_max) return false;
        if (multiline(tree, current)) return false;

        if (statement_count > 1) width += 2;

        const statement = tree.at(current);

        width += width_of(tokens, raw, statement.token_start, tail_of(tree, raw, current), true);
        child = tree.sibling_next_of(current);
    }

    return header_lined or width <= body_width_max;
}

fn multiline(tree: *const Tree, node: u32) bool {
    assert(node < tree.count());

    const end = tree.at(node).token_end;

    assert(end >= tree.at(node).token_start);

    var at = node;

    while (at < tree.count()) : (at += 1) {
        if (at != node) {
            if (tree.at(at).token_start >= end) break;
        }

        if (multiline_breaks(tree, at)) return true;
    }

    return false;
}

fn multiline_breaks(tree: *const Tree, node: u32) bool {
    assert(node < tree.count());

    const held = tree.at(node);
    const parent_kind = parent_kind_of(tree, node);

    if (parent_kind != null) assert(node > 0);

    switch (held.kind) {
        .case_clause,
        .comm_clause,
        .for_stmt,
        .if_stmt,
        .labeled_stmt,
        .range_stmt,
        .switch_stmt,
        .type_switch_stmt,
        => return true,
        .block_stmt => {
            const kind = parent_kind orelse return true;

            return switch (kind) {
                .func_lit, .select_stmt => false,
                else => true,
            };
        },
        .field_list => {
            const kind = parent_kind orelse return false;

            switch (kind) {
                .interface_type, .struct_type => {},
                else => return false,
            }

            const child = tree.child_first_of(node) orelse return false;
            return tree.sibling_next_of(child) != null;
        },
        else => return false,
    }
}

fn width_of(tokens: []const Token, raw: []const Kind, from: u32, to: u32, bare: bool) u32 {
    assert(tokens.len == raw.len);
    assert(to < raw.len);
    assert(from < std.math.maxInt(u32));

    var width: u32 = 0;
    var prior: ?u32 = null;
    var before_comment: ?Kind = null;
    var at = from;

    while (at <= to) : (at += 1) {
        const kind = raw[at];
        if (kind == .newline) continue;

        if (bare) {
            if (kind == .comment) continue;
        }

        if (width_spaced(tokens, raw, prior, before_comment, at)) width += 1;
        if (kind == .comment) before_comment = width_comment_before(raw, prior, before_comment);

        width += tokens[at].length;
        prior = at;
    }

    return width;
}

fn width_spaced(
    tokens: []const Token,
    raw: []const Kind,
    prior: ?u32,
    before_comment: ?Kind,
    at: u32,
) bool {
    assert(at < raw.len);
    assert(tokens.len == raw.len);
    if (prior) |held| assert(held < tokens.len);
    if (before_comment) |held| assert(held.is_token());

    const held = prior orelse return false;
    const glued = raw[held] == .comment and width_glued(raw[at], before_comment);
    if (glued) return false;
    return tokens[at].offset > tokens[held].end();
}

fn width_glued(kind: Kind, before_comment: ?Kind) bool {
    assert(kind.is_token());
    if (before_comment) |held| assert(held.is_token());

    return switch (kind) {
        .comma => true,
        .paren_close => !kind_is(before_comment, .paren_open),
        .bracket_close => !kind_is(before_comment, .bracket_open),
        else => false,
    };
}

fn width_comment_before(raw: []const Kind, prior: ?u32, before_comment: ?Kind) ?Kind {
    assert(raw.len <= std.math.maxInt(u32));
    if (prior) |held| assert(held < raw.len);
    if (before_comment) |held| assert(held.is_token());

    const held = prior orelse return null;
    if (raw[held] == .comment) return before_comment;
    return raw[held];
}

fn walk_binary(tree: *const Tree, tokens: []const Token, source: []const u8, node: u32) Levels {
    assert(tree.kind_at(node) == .binary_expr);
    assert(tokens.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));

    var pending: [binary_pending_max]u32 = undefined;
    var pending_count: u32 = 1;
    var levels: Levels = .{ .five = false, .four = false, .problem = 0 };

    pending[0] = node;

    for (0..tree.count()) |_| {
        if (pending_count == 0) break;

        pending_count -= 1;

        const step = walk_binary_step(tree, tokens, source, pending[pending_count]);

        levels = levels.merged(step.levels);

        if (step.left) |left| {
            assert(pending_count < binary_pending_max);

            pending[pending_count] = left;
            pending_count += 1;
        }

        if (step.right) |right| {
            assert(pending_count < binary_pending_max);

            pending[pending_count] = right;
            pending_count += 1;
        }
    }

    assert(pending_count == 0);

    return levels;
}

fn walk_binary_step(
    tree: *const Tree,
    tokens: []const Token,
    source: []const u8,
    node: u32,
) BinaryStep {
    assert(tokens.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));
    assert(tree.kind_at(node) == .binary_expr);

    const precedence = precedence_at(tree, tokens, source, node);
    const operands = operands_of(tree, node);

    assert(precedence <= 5);

    var step: BinaryStep = .{
        .left = null,
        .levels = .{ .five = precedence == 5, .four = precedence == 4, .problem = 0 },
        .right = null,
    };

    if (operands.left) |left| {
        const nested = tree.kind_at(left) == .binary_expr;

        if (nested) {
            if (precedence_at(tree, tokens, source, left) >= precedence) step.left = left;
        }
    }

    const right = operands.right orelse return step;

    if (tree.kind_at(right) == .binary_expr) {
        if (precedence_at(tree, tokens, source, right) > precedence) step.right = right;

        return step;
    }

    const operator = operator_of(tree, tokens, source, node) orelse return step;

    step.levels.problem = problem_of(tokens[operator].text(source), tree, tokens, source, right);

    return step;
}

fn problem_of(
    operator: []const u8,
    tree: *const Tree,
    tokens: []const Token,
    source: []const u8,
    right: u32,
) u32 {
    assert(operator.len > 0);
    assert(right < tree.count());
    assert(tokens.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));

    const kind = tree.kind_at(right);

    if (kind == .star_expr) {
        return if (walk.text_is(operator, "/")) 5 else 0;
    }

    if (kind != .unary_expr) return 0;

    const sign = unary_of(tree, tokens, source, right);
    const divided = walk.text_is(operator, "/") and walk.text_is(sign, "*");
    const masked = one_of(operator, &.{ "&", "&^" }) and walk.text_is(sign, "&");
    const added = walk.text_is(operator, "+") and walk.text_is(sign, "+");
    const subtracted = walk.text_is(operator, "-") and walk.text_is(sign, "-");

    if (divided) return 5;
    if (masked) return 5;
    if (added) return 4;
    if (subtracted) return 4;
    return 0;
}

fn cutoff_of(
    tree: *const Tree,
    tokens: []const Token,
    source: []const u8,
    node: u32,
    depth: u32,
) u32 {
    assert(tree.kind_at(node) == .binary_expr);
    assert(depth > 0);
    assert(tokens.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));

    const levels = walk_binary(tree, tokens, source, node);

    if (levels.problem > 0) {
        assert(levels.problem + 1 < std.math.maxInt(u32));

        return levels.problem + 1;
    }

    if (levels.four) {
        if (levels.five) return if (depth == 1) 5 else 4;
    }

    if (depth == 1) return 6;
    return 4;
}

fn unary_of(tree: *const Tree, tokens: []const Token, source: []const u8, node: u32) []const u8 {
    assert(source.len <= std.math.maxInt(u32));
    assert(node < std.math.maxInt(u32));

    const start = tree.at(node).token_start;

    assert(start < tokens.len);
    assert(tokens.len <= std.math.maxInt(u32));

    const text = tokens[start].text(source);

    for (unary_signs) |sign| {
        if (std.mem.eql(u8, sign, text)) return sign;
    }

    return "";
}

fn precedence_at(tree: *const Tree, tokens: []const Token, source: []const u8, node: u32) u32 {
    assert(node < tree.count());
    assert(tokens.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));

    if (tree.kind_at(node) != .binary_expr) return 0;

    const operator = operator_of(tree, tokens, source, node) orelse return 0;
    return precedence_of(tokens[operator].text(source));
}

fn precedence_of(text: []const u8) u32 {
    assert(text.len <= std.math.maxInt(u32));

    const level = for (precedences) |entry| {
        if (std.mem.eql(u8, entry.text, text)) break entry.level;
    } else 0;

    assert(level <= 5);
    if (level > 0) assert(text.len <= 2);

    return level;
}

fn operator_of(tree: *const Tree, tokens: []const Token, source: []const u8, node: u32) ?u32 {
    assert(node < tree.count());
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    const operands = operands_of(tree, node);
    const left = operands.left orelse return null;

    const end = if (operands.right) |right|
        tree.at(right).token_start
    else
        tree.at(node).token_end;

    var held = tree.at(left).token_end;

    while (held < end) : (held += 1) {
        if (precedence_of(tokens[held].text(source)) > 0) return held;
    }

    return null;
}

fn operands_of(tree: *const Tree, node: u32) Operands {
    assert(node < tree.count());

    const left = tree.child_first_of(node) orelse return .{ .left = null, .right = null };
    const right = tree.sibling_next_of(left);

    assert(left > node);
    if (right) |held| assert(held > left);

    return .{ .left = left, .right = right };
}

fn combines(tokens: []const Token, source: []const u8, position: u32) bool {
    assert(position < tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    const held = tokens[position].text(source);
    const past = combines_past(tokens, source, position) orelse return false;

    if (held.len != 1) return false;

    return switch (held[0]) {
        '&' => past == '&' or past == '^',
        '+' => past == '+',
        '-' => past == '-',
        '/' => past == '*',
        '<' => past == '-' or past == '<',
        else => false,
    };
}

fn combines_past(tokens: []const Token, source: []const u8, position: u32) ?u8 {
    assert(position < tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    for (tokens[position + 1 ..]) |token| {
        if (token.length > 0) return token.text(source)[0];
    }

    return null;
}

fn arguments(tree: *const Tree, node: u32) u32 {
    assert(node < tree.count());
    assert(tree.kind_at(node) == .call_expr);

    var children: u32 = 0;
    var child = tree.child_first_of(node);

    for (0..depth_max + 1) |_| {
        const current = child orelse break;

        children += 1;
        child = tree.sibling_next_of(current);
    }

    assert(children <= depth_max + 1);

    return children -| 1;
}

fn values(tree: *const Tree, tokens: []const Token, source: []const u8, node: u32) u32 {
    assert(node < std.math.maxInt(u32));

    const held = tree.at(node);

    assert(held.token_end <= tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    var assign: ?u32 = null;
    var valued: u32 = 0;
    var child = tree.child_first_of(node);

    for (0..tree.count()) |_| {
        const current = child orelse break;

        if (valued > depth_max) break;

        const bytes = tree.at(current).token_start;

        if (assign == null) assign = values_assign(tokens, source, held.token_start, bytes);

        if (assign) |found| {
            if (bytes > found) valued += 1;
        }

        child = tree.sibling_next_of(current);
    }

    return valued;
}

fn values_assign(tokens: []const Token, source: []const u8, start: u32, bytes: u32) ?u32 {
    assert(bytes <= tokens.len);
    assert(source.len <= std.math.maxInt(u32));
    assert(start < std.math.maxInt(u32));

    var scan = bytes;

    while (scan > start) {
        scan -= 1;

        if (std.mem.endsWith(u8, tokens[scan].text(source), "=")) return scan;
    }

    return null;
}

fn frame_all(child: ?u32, budget: u32, depth: u32) Tightening.Frame {
    assert(budget > 0);
    assert(budget <= depth_max);
    if (child) |held| assert(held < std.math.maxInt(u32));
    assert(depth <= depth_max);

    return .{
        .budget = budget,
        .child = child,
        .depth_head = depth,
        .depth_tail = depth,
        .entered = 0,
        .limit = std.math.maxInt(u32),
    };
}

fn frame_indexed(child: ?u32, budget: u32, depth: u32) Tightening.Frame {
    assert(budget > 0);
    assert(budget <= depth_max);
    if (child) |held| assert(held < std.math.maxInt(u32));
    assert(depth <= depth_max);

    return .{
        .budget = budget,
        .child = child,
        .depth_head = 1,
        .depth_tail = depth + 1,
        .entered = 0,
        .limit = std.math.maxInt(u32),
    };
}

fn paren_depth_of(tree: *const Tree, node: u32, depth: u32) u32 {
    assert(tree.kind_at(node) == .paren_expr);
    assert(depth > 0);

    const inner = tree.child_first_of(node) orelse return reduced(depth);
    if (tree.kind_at(inner) == .paren_expr) return depth;
    return reduced(depth);
}

fn reduced(depth: u32) u32 {
    assert(depth <= depth_max + 1);
    assert(depth > 0);

    return if (depth > 1) depth - 1 else 1;
}

fn stepped_depths(raw: []const Kind, depths: *ArrayType(u32)) error{Overflow}!void {
    assert(depths.empty());
    assert(raw.len <= std.math.maxInt(u32));

    var depth: u32 = 0;

    for (raw) |kind| {
        if (depths.full()) return error.Overflow;

        depths.push(depth);

        if (is_opener(kind)) depth += 1;
        if (is_closer(kind)) depth -|= 1;
    }

    assert(depths.count() == raw.len);
}

fn stepped_step(layout: *const Layout, nodes: []const u32) u32 {
    assert(nodes.len <= layout.tree.count());
    assert(layout.depths.len == layout.raw.len);

    if (nodes.len == 0) return 0;
    const returned = layout.steps(nodes[nodes.len - 1]);

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn restream_needed(positions: []const u8, order: []const u32) bool {
    assert(order.len <= positions.len);
    assert(positions.len <= std.math.maxInt(u32));

    for (positions) |flags| {
        if (flags & position_restreamed != 0) return true;
    }

    for (order, 0..) |held, index| {
        if (held != index) return true;
    }

    return false;
}

fn commented(raw: []const Kind, from: u32, to: u32) bool {
    assert(raw.len <= std.math.maxInt(u32));
    assert(to <= raw.len);
    assert(from < std.math.maxInt(u32));

    var scan = from;

    while (scan < to) : (scan += 1) {
        if (raw[scan] == .comment) return true;
    }

    return false;
}

fn lined(source: []const u8, tokens: []const Token, from: u32, to: u32) bool {
    assert(from < tokens.len);
    assert(to < tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    return newline_in(source, tokens[from].offset, tokens[to].offset);
}

fn newline_in(source: []const u8, start: u32, end: u32) bool {
    assert(start <= source.len);
    assert(end <= source.len);

    if (start >= end) return false;
    return std.mem.findScalar(u8, source[start..end], '\n') != null;
}

fn meaningful(raw: []const Kind, from: u32, to: u32) ?u32 {
    assert(raw.len <= std.math.maxInt(u32));
    assert(from < std.math.maxInt(u32));
    assert(to < std.math.maxInt(u32));

    const end = @min(to, @as(u32, @intCast(raw.len)));

    assert(end <= raw.len);

    var at = from;

    while (at < end) : (at += 1) {
        if (!is_filler(raw[at])) return at;
    }

    return null;
}

fn closes(raw: []const Kind, open: u32) ?u32 {
    assert(raw.len <= std.math.maxInt(u32));
    assert(open <= raw.len);

    var depth: i32 = 0;
    var at = open;

    while (at < raw.len) : (at += 1) {
        if (is_opener(raw[at])) depth += 1;
        if (!is_closer(raw[at])) continue;

        depth -= 1;

        if (depth != 0) continue;
        if (raw[at] == .bracket_close) return at;
        return null;
    }

    return null;
}

fn depthless(raw: []const Kind, from: u32, to: u32, wanted: Kind) ?u32 {
    assert(raw.len <= std.math.maxInt(u32));
    assert(from < std.math.maxInt(u32));
    assert(to < std.math.maxInt(u32));

    const end = @min(to, @as(u32, @intCast(raw.len)));

    assert(end <= raw.len);
    assert(!is_opener(wanted));

    var depth: i32 = 0;
    var at = from;

    while (at < end) : (at += 1) {
        const kind = raw[at];

        if (is_opener(kind)) {
            depth += 1;
        } else if (is_closer(kind)) {
            depth -= 1;
        } else {
            const found = kind == wanted and depth == 0;
            if (found) return at;
        }
    }

    return null;
}

fn tail_of(tree: *const Tree, raw: []const Kind, node: u32) u32 {
    assert(node < std.math.maxInt(u32));

    const held = tree.at(node);

    assert(held.token_end <= raw.len);
    assert(held.token_start <= held.token_end);

    var end = held.token_end;

    while (end > held.token_start + 1) : (end -= 1) {
        if (!is_filler(raw[end - 1])) break;
    }

    const returned = @max(end -| 1, held.token_start);

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn parent_kind_of(tree: *const Tree, node: u32) ?Kind {
    assert(node < tree.count());

    const parent = tree.parent_of(node) orelse return null;

    assert(parent < node);

    return tree.kind_at(parent);
}

fn mark_at(held: []u8, at: u32, flag: u8) void {
    assert(flag != 0);
    assert(at <= held.len);

    if (at < held.len) held[at] |= flag;
}

fn role_at(roles: []u16, at: u32, flag: u16) void {
    assert(flag != 0);
    assert(at <= roles.len);

    if (at < roles.len) roles[at] |= flag;
}

fn kind_is(held: ?Kind, kind: Kind) bool {
    assert(kind.is_token());
    if (held) |value| assert(value.is_token());

    const value = held orelse return false;
    return value == kind;
}

fn one_of(text: []const u8, options: []const []const u8) bool {
    assert(options.len > 0);
    assert(text.len <= std.math.maxInt(u32));

    for (options) |option| {
        if (std.mem.eql(u8, text, option)) return true;
    }

    return false;
}

fn is_assignment(kind: Kind) bool {
    assert(kind.is_token());

    return switch (kind) {
        .ampersand_caret_equal,
        .ampersand_equal,
        .bar_equal,
        .caret_equal,
        .colon_equal,
        .equal,
        .greater_greater_equal,
        .less_less_equal,
        .minus_equal,
        .percent_equal,
        .plus_equal,
        .slash_equal,
        .star_equal,
        => true,
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

fn is_filler(kind: Kind) bool {
    assert(kind.is_token());

    return switch (kind) {
        .comment, .newline => true,
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
